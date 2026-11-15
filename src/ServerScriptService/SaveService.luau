--[[
	SaveService  --  ServerScriptService.SaveService

	The place's persistence. Until this existed the ONLY DataStore in the game was
	FeedbackServer's: coins, every Lv_ track, Rebirths, TideEarned, the pet
	collection and the vehicle you had bought were all plain player attributes,
	and every one of them was wiped when the server shut down. A twenty-five rung
	rebirth ladder that resets on a restart is not a ladder.

	IT WRITES NOTHING OF ITS OWN. Every field below is read and restored through
	the seam the owning system already published for exactly this -- see the
	PERSISTENCE SEAM note at the bottom of ServerMain, which asked for this module
	by name. Nothing here reaches past an owner into its private state.

		coins        SellServer.getCoins / addCoins  (the one grant path)
		levels       ProgressionServer.levelOf, then SetAttribute + applyAll
		carLevels    AtvConfig.carLevelOf -- the car rake ladder, which is NOT
		             wiped by a rebirth, so unlike `levels` this one is a
		             permanent record rather than a snapshot of the current tide
		rebirths     "
		tide/total   "
		atvTier      AtvConfig.OwnedAttribute. WIPED BY A REBIRTH unless the player
		             owns that machine's game pass, so for a coin buyer this is a
		             snapshot of the current tide and for a pass holder it is a
		             permanent record -- the only row here that is both. Written by
		             AtvServer (purchase), GamePassService (entitlement floor) and
		             ProgressionServer.onRebirth (the wipe); it was "a plain
		             attribute AtvServer owns" until 2026-08-24
		pets         PetServer.OnPetsChanged (out) / PetServer.restore (in)
		trashPicked  LeaderboardConfig.TrashAttribute, the lifetime counter both
		             collection paths increment and the boards rank
		rewards      RewardsServer.exportFor (out) / RewardsServer.restore (in)
		tutorialDone TutorialConfig.DoneAttribute, stamped by TutorialServer
		skins        SkinService.exportFor (out) / SkinService.restore (in). Which
		             sifter skins this account has claimed and which one it wears
		             outside the rooms. NOT wiped by a rebirth -- you walked into
		             a tomb for it -- so, like carLevels, this is a permanent
		             record rather than a snapshot of the current tide.
		receipts     ProductServer.exportFor (out) / ProductServer.restore (in).
		             The developer-product receipt log, and it is in THIS record
		             rather than a store of its own for one reason: it has to be
		             committed by the same write as the coins it paid for. Split
		             them and there is a window in which a player has been charged
		             and not credited, or credited twice -- see ProductServer.

	CARRIED ITEMS ARE DELIBERATELY NOT SAVED, and ServerMain's note is the reason:
	a crusted lump has no rolled value and no revealed identity, so there is
	nothing meaningful to write down until it has been through a wash bay.

	FOUR THINGS THAT ARE EASY TO GET WRONG HERE, and all four bit during the build
	---------------------------------------------------------------------------

	1. RESTORING COINS MUST NOT GO THROUGH THE EARNING PATH. SellServer.addCoins
	   fires OnCoinsChanged, and ProgressionServer's handler there adds the delta
	   to BOTH TotalEarned and TideEarned. A restore through it would therefore
	   credit a returning player's whole balance as fresh earnings on every join --
	   and TideEarned is the rebirth gate, so the ladder would open itself. The
	   `restoring` flag below is what stops it, and it is why this module WRAPS
	   OnCoinsChanged rather than assigning it.

	2. OnCoinsChanged IS ALREADY CLAIMED. ProgressionServer.start() assigns it, and
	   ServerMain starts that module specifically so it can be "the final owner of
	   that hook". Overwriting it kills lifetime earnings and every panel push in
	   the game, silently. installCoinHook captures the existing function and calls
	   it. Same contract for PetServer.OnPetsChanged.

	3. PlayerRemoving ORDER. PetServer's own PlayerRemoving clears data[player],
	   and it is connected BEFORE this module's, so by the time we are told a
	   player is leaving, PetServer.get() would hand back an empty collection. So
	   pets are cached HERE, updated on every OnPetsChanged, and the leave-save
	   reads the cache. Attributes have no such problem -- the Player instance is
	   still alive in PlayerRemoving -- which is why only pets need it.

	4. `discovered` IS NOT IN THE OnPetsChanged PAYLOAD. It is what the Pet Index
	   draws and releasing a pet must not un-discover it, so it is accumulated
	   here: every id ever seen owned is unioned in, starting from whatever the
	   profile loaded with. That needs no change to PetServer.

	   `locked` IS in the payload, and it is the one pet field that is REPLACED
	   rather than unioned. The two are opposite by design: `discovered` is a
	   record of what has happened and can only grow, where `locked` is a live
	   instruction the player edits in both directions -- and a lock that could
	   not be lifted would be a second way to lose a pet rather than a safeguard.

	THE SESSION LOCK
	----------------
	Every read and write is an UpdateAsync that checks a {jobId, at} stamp. A
	server will not load a profile another server still holds, and will not
	overwrite one that has since been claimed elsewhere -- which is what stops a
	fast rejoin, or a soft shutdown mid-migration, from duplicating a balance.
	LOCK_STALE is what breaks a lock left behind by a crashed server.

	There is no separate lock-refresh write stream: the ordinary save refreshes the
	stamp, so the write budget is one request per player per SAVE_INTERVAL against
	a budget of 60 + 10 per player per minute.

	WHY THERE IS NO "WAIT FOR LOAD" GATE ON SPENDING. A player who buys something
	in the window between joining and their profile landing can only spend the
	balance they have, and that balance starts at zero -- the attributes have not
	been written yet. The default state is empty, so the race cannot pay out.

	IN STUDIO this needs Game Settings -> Security -> Enable Studio Access to API
	Services, exactly as FeedbackServer's header records. Without it the module
	loads, warns once, and runs as a no-op rather than throwing.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local ProgressionConfig = require(Modules:WaitForChild("ProgressionConfig"))
-- For ClaimedAttribute only -- the name of the Starter Pack's "already given"
-- flag. Named there rather than typed here for the reason the TutorialConfig
-- require below gives: a string spelled twice is a string that gets corrected
-- once. Plain replicated data, no server dependency.
local PassConfig = require(Modules:WaitForChild("PassConfig"))
-- For ClaimedAttribute only, same as PassConfig above: a flag's NAME lives with
-- the feature that owns it rather than being spelled a second time here.
local FreeRewardConfig = require(Modules:WaitForChild("FreeRewardConfig"))
-- The car rake ladder, for its keys, its ceiling and its attribute prefix --
-- the same reason TutorialConfig is required below. Plain replicated data with
-- no server dependencies, so it adds nothing to this module's boot order.
local AtvConfig = require(ReplicatedStorage:WaitForChild("AtvConfig"))
local PetConfig = require(Modules:WaitForChild("PetConfig"))
-- For `itemsFound`: the catalogue every stored id is checked against, and the
-- bag that says when one has been revealed.
local ItemConfig = require(Modules:WaitForChild("ItemConfig"))
local InventoryController = require(Modules:WaitForChild("InventoryController"))
local Net = require(Modules:WaitForChild("Net"))
-- For the attribute NAME only. Plain data with no dependencies of its own, and
-- naming the string here rather than typing "TutorialDone" a second time is what
-- stops this field and the module that writes it from drifting apart.
local TutorialConfig = require(Modules:WaitForChild("TutorialConfig"))
-- Same deal, for the first-rebirth nudge's "already shown" flag -- one more
-- account-lifetime boolean stamped by its own server module, RebirthPromptServer.
local RebirthPromptConfig = require(Modules:WaitForChild("RebirthPromptConfig"))
-- Same deal, for the lifetime trash counter's attribute name. The counter is
-- incremented by the two collection paths and ranked by the world leaderboards;
-- this file is only the thing that remembers it between sessions.
local LeaderboardConfig = require(Modules:WaitForChild("LeaderboardConfig"))
-- For DefaultKey only, same as PassConfig and FreeRewardConfig above: plain
-- replicated data with no dependencies, named here rather than typed twice.
local SkinConfig = require(Modules:WaitForChild("SkinConfig"))
-- Redeemable codes. Needed here for the KEY LIST, not for the rewards: the
-- sanitiser carries forward only codes that still exist, and the capture only
-- looks for attributes it knows the names of.
local CodeConfig = require(Modules:WaitForChild("CodeConfig"))

local SellServer = require(script.Parent:WaitForChild("SellServer"))
local ProgressionServer = require(script.Parent:WaitForChild("ProgressionServer"))
local PetServer = require(script.Parent:WaitForChild("PetServer"))
-- Safe to require: RewardsServer reaches for SellServer and ProgressionServer,
-- both of which are already above it here, and never reaches back for this
-- module -- so the persistence seam runs one way and there is no cycle.
local RewardsServer = require(script.Parent:WaitForChild("RewardsServer"))
-- Safe for the same reason RewardsServer is: it reaches for SellServer, which
-- is already above it here, and never reaches back for this module -- it takes
-- `CommitProfile` by injection instead, down in start(). One direction only.
local ProductServer = require(script.Parent:WaitForChild("ProductServer"))
-- Safe for the same reason RewardsServer and ProductServer are: it reaches for
-- Config and SkinConfig and never back for this module. One direction only.
local SkinService = require(script.Parent:WaitForChild("SkinService"))
-- Safest of the four: BoostService reaches for BoostConfig and Net only. It is
-- already required by ProductServer above, so this costs nothing.
local BoostService = require(script.Parent:WaitForChild("BoostService"))
-- Safe on the same terms as the four above: it reaches for Net and UiFit, both
-- of which are replicated data modules, and never back for this one.
local SettingsServer = require(script.Parent:WaitForChild("SettingsServer"))

local SaveService = {}

--------------------------------------------------------------------------
-- DIALS
--------------------------------------------------------------------------

--[[
	The store name carries the schema. Bumping SCHEMA alone migrates in place
	(see `migrate`); bumping the NAME abandons every profile in the game and is a
	last resort, not a retune.

	AND STUDIO GETS ITS OWN STORE, which is not tidiness -- it is the difference
	between a test session and a player's account.

	ServerScriptService.DevGrant hands every Studio joiner $500,000, three
	rebirths and a stocked bucket, and says "STUDIO ONLY" in its own print. It is
	only Studio-only for as long as nothing writes it down. Sharing one store
	would mean every Play-test overwrote the tester's REAL profile with dev money,
	and there is no undo for that -- the live game would read it back on the next
	join.

	So Studio round-trips fully (save, restart, reload all work and are worth
	testing) against a key no live server ever reads.
]]
local STORE_NAME = RunService:IsStudio()
	and "CleanTheBeach_Profile_v1_studio"
	or "CleanTheBeach_Profile_v1"
local KEY_PREFIX = "p_"
-- v2 (2026-08): the car rake ladder went 25 rungs of two studs -> 50 rungs of
-- one stud, so a v1 rake LEVEL means half the width it used to. migrate doubles
-- a v1 profile's rake level once; everything else is unchanged.
local SCHEMA = 2

-- 90s against a budget of 60 + 10 per player per minute, and only when something
-- has actually changed. A busy player marks dirty on every sale; a player stood
-- still writes nothing at all.
local SAVE_INTERVAL = 90

-- How long a lock stamp stands before another server may take it. Has to be
-- comfortably longer than LOCK_REFRESH or a live server would steal from itself
-- between its own writes.
local LOCK_STALE = 240

-- ...and a player who is not earning still has to refresh the stamp, or an idle
-- session would silently lose its own lock and then be refused its leave-save.
-- This is the only write that happens without a change behind it: one per player
-- per two minutes, against a budget of 60 + 10 per player per minute.
local LOCK_REFRESH = 120

-- Most clients ask once, at boot. This is only here so that one that asks in a
-- loop is answered at a rate of its own choosing rather than ours.
local INDEX_ASK_EVERY = 3

local LOAD_RETRIES = 5

--------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------

local profiles = {}   -- [Player] = { data, loaded, dirty, saving, failed, wroteAt }
local restoring = {}  -- [Player] = true while apply() is writing. See note 1.

local store, storeTried

local function jobKey(): string
	-- JobId is empty in Studio, and an empty string would make every Studio
	-- session look like the same holder -- which is right, because it IS the same
	-- machine, and it means a Play-test never locks itself out.
	return (game.JobId ~= "" and game.JobId) or "studio"
end

local function dataStore()
	if storeTried then
		return store
	end
	storeTried = true
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		warn("[Save] no DataStore (" .. tostring(result) .. "). In Studio this needs "
			.. "Game Settings -> Security -> Enable Studio Access to API Services. "
			.. "Nothing will persist this session.")
	end
	return store
end

--------------------------------------------------------------------------
-- THE PROFILE
--------------------------------------------------------------------------

local function blank()
	return {
		schema = SCHEMA,
		coins = 0,
		levels = {},
		-- The car rake ladder, AtvConfig.Upgrades. A SEPARATE field from `levels`
		-- rather than more keys in it, because the two are validated against
		-- different ceilings and a car key clamped to ProgressionConfig.MaxLevel
		-- (60) would silently accept four times the rungs that ladder has.
		--
		-- Empty is the honest default and needs no migration: a profile written
		-- before this existed loads with no rake fitted, which is what its owner
		-- had. Levels are 0-BASED here -- see AtvConfig.carLevelOf.
		carLevels = {},
		-- Which redeemable codes this account has already used, as a set keyed by
		-- the NORMALISED code (CodeConfig.normalise). Empty is the honest default
		-- and needs no migration: a profile written before codes existed loads with
		-- none used, which is true.
		--
		-- Kept as a set rather than a list so a retired code simply stops being
		-- looked up -- nothing has to be pruned, and a player who used it keeps
		-- what it paid, because the payout happened once at redemption.
		codes = {},
		rebirths = 0,
		tideEarned = 0,
		totalEarned = 0,
		-- Every piece of litter this account has ever picked up, by either of the
		-- two collection paths. Ranked by the MOST TRASH board. Lifetime: a
		-- rebirth does not clear it -- see LeaderboardConfig.TrashAttribute.
		trashPicked = 0,
		-- What trashPicked read at the last rebirth. The litter half of the rebirth
		-- gate is the difference between the two, so this is the only part of it
		-- that has to be stored -- see ProgressionServer.tideTrashOf.
		tideTrashBase = 0,
		-- "An admin blanked this account to walk the onboarding; nothing may
		-- re-fill it until the tutorial is finished." Saved because the whole
		-- point of it is to survive a rejoin -- see TutorialConfig.HoldAttribute.
		tutorialHold = false,
		atvTier = 0,
		-- `locked` is the player's "do not destroy this" list, and it is saved for
		-- the same reason tutorialDone is: a session-only flag is a fresh empty
		-- table on every server they ever join, which would make the padlock a
		-- decoration that protects nothing past a rejoin.
		pets = { owned = {}, equipped = {}, discovered = {}, locked = {} },
		--[[
			EVERY ITEM ID THIS ACCOUNT HAS EVER HAD THE IDENTITY OF.

			The item half of `pets.discovered` above, and saved for exactly the
			same reason: the Index draws a permanent collection log with an
			"N / total FOUND" bar on it, and until this field existed the set
			behind that bar was session state that nothing persisted -- so it
			read empty on every join and filled only from what was found while
			online. Two players reported it as the index resetting, which is
			exactly what it was doing.

			GROWS ONLY, like `pets.discovered`: selling the thing does not
			un-find it, and a rebirth does not either. An empty table is the
			honest default for a profile written before this existed -- that
			account's board starts filling from its next session rather than
			claiming finds this module cannot actually vouch for.
		]]
		itemsFound = {},
		-- The daily streak, today's quest progress and the milestone board.
		-- Shape is RewardsServer's business, not this module's -- see migrate.
		rewards = {},
		-- Has this account been through the onboarding? One boolean, and the
		-- reason the tutorial is a once-per-account event rather than a
		-- once-per-session one. TutorialServer stamps it off a purchase it can
		-- see for itself -- see its header for why no client is asked.
		tutorialDone = false,
		-- Has the first-rebirth card been shown -- RebirthPromptConfig.SeenAttribute,
		-- stamped by RebirthPromptServer once the client reports it was dismissed.
		-- False is the honest default: a profile written before this field existed
		-- has not been shown it, which is exactly the account this feature is for.
		rebirthPromptSeen = false,
		--[[
			Has the Starter Pack been HANDED OVER -- which is a different question
			from whether they own the pass.

			Owning the pass is Roblox's answer and is true forever once bought, so
			it is re-resolved on every join; paying the pack out on it would pay
			20,000 coins a login. This is the one-off, and it is saved for exactly
			the reason `tutorialDone` above is saved: a session flag is a fresh
			false on every server the player ever joins.

			False is the honest default and needs no migration -- a profile written
			before this field existed has not been given the pack, which is true.
		]]
		starterPackClaimed = false,
		-- VIP's pet, once per account. Same hazard as the flag above it -- the pass
		-- is permanent, so a grant hung off ownership alone would hand over a
		-- Legendary on every single join.
		vipPetClaimed = false,
		-- The "like and join the group" reward, once per account. Same hazard as the
		-- flag above it: group membership is true on every future join, so a grant
		-- gated on membership alone would pay out on every login forever.
		freeRewardClaimed = false,
		-- Developer-product receipts already paid out, oldest first. An ARRAY
		-- rather than a set, because ProductServer prunes it by age and a set
		-- carries no order to prune by. Empty is the honest default and needs no
		-- migration: a profile written before this existed has bought nothing.
		receipts = {},
		--[[
			A BOUGHT GOLDEN HOUR STILL RUNNING -- an absolute os.time() deadline and
			the multiplier it was sold at, or nil when nothing is live.

			Saved because Roblox restarts servers constantly, and fifteen paid
			minutes that die with the instance is a product that sometimes delivers
			two. Stored as a DEADLINE rather than a remaining time on purpose: a
			deadline keeps counting across the gap, where a remaining time would hand
			the full window back on every rejoin and make restarts free minutes.

			Empty is the honest default and needs no migration: a profile written
			before this existed had no boost running, which is true.

			⚠️ AND IT MUST NOT BE `nil`, WHICH IS WHAT IT WAS FIRST WRITTEN AS.
			`buildPayload` iterates `for key, default in blank()` -- so this table is
			not just the defaults, it is the KEY LIST of everything that gets written.
			A nil default is an absent key, an absent key is never visited by that
			loop, and the field is silently dropped at write time however carefully
			`collect` filled it in. It saves and restores cleanly, logs nothing, and
			simply never persists. Any new field here needs a non-nil default.
		]]
		boost = {},
		--[[
			The personal settings that are worth keeping -- today just HUD Size. Most
			of that panel is deliberately unsaved and stays that way; SettingsServer's
			header says which and why.

			Empty is the honest default and needs no migration: a profile written
			before this existed has never changed one, and every value is validated
			against the whitelist on the way back in anyway. Non-nil for the reason
			spelled out on `boost` above -- this table is the payload's key list.
		]]
		settings = {},
		--[[
			THE WARDROBE. `owned` is a set of SkinConfig keys, `chosen` is the
			one worn outside the three rooms.

			Empty is the honest default and needs no migration: a profile
			written before this existed has claimed nothing, which is true, and
			SkinService.restore resolves an empty `chosen` to the stock sifter
			everybody starts with.
		]]
		skins = { owned = {}, chosen = SkinConfig.DefaultKey },
	}
end

--[[
	Everything is validated on the way IN rather than trusted, the same way
	PetServer.restore validates against the catalogue: a profile written by an
	older build must degrade to a sane player, never to an error three lines into
	a join. A field that is the wrong type is simply not restored.
]]
local function migrate(d)
	if type(d) ~= "table" then
		return blank()
	end
	local out = blank()
	out.coins = (type(d.coins) == "number" and d.coins == d.coins) and math.max(0, math.floor(d.coins)) or 0
	--[[
		NO LONGER CLAMPED TO THE LADDER. The tide count has no cap since
		2026-09-11 (ProgressionConfig.Rebirth.LadderTides), and clamping to 40 on
		the way in would have silently deleted every tide a player rode past it --
		the worst shape of save bug there is, because it only shows up on the
		NEXT join and reads as the server stealing progress.

		SanityCap IS STILL HERE and is doing the job the old clamp was actually
		for. Every rebirth curve is exponential in this number, so a mangled
		profile carrying 1e9 does not load as a wrong multiplier, it loads as
		`inf` in SellMultiplier and in the coin counter. A thousand cannot be
		reached by play (the tide-1,000 gate is ~1e156) and keeps the arithmetic
		finite, which is exactly this function's contract: degrade to a sane
		player, never to an error three lines into a join.
	]]
	out.rebirths = (type(d.rebirths) == "number" and d.rebirths == d.rebirths)
		and math.clamp(math.floor(d.rebirths), 0, ProgressionConfig.Rebirth.SanityCap) or 0
	out.tideEarned = (type(d.tideEarned) == "number") and math.max(0, math.floor(d.tideEarned)) or 0
	out.totalEarned = (type(d.totalEarned) == "number") and math.max(0, math.floor(d.totalEarned)) or 0
	-- A profile written before the counter existed has no field here and loads as
	-- zero, which is the honest answer: the game was not counting.
	out.trashPicked = (type(d.trashPicked) == "number" and d.trashPicked == d.trashPicked)
		and math.max(0, math.floor(d.trashPicked)) or 0
	-- Zero for a profile written before the litter gate existed, which credits
	-- that player's whole lifetime count to the tide they are on. Deliberate and
	-- one-time -- ProgressionServer.tideTrashOf's note argues it.
	out.tideTrashBase = (type(d.tideTrashBase) == "number" and d.tideTrashBase == d.tideTrashBase)
		and math.max(0, math.floor(d.tideTrashBase)) or 0
	-- `== true`, the same guard tutorialDone uses below: a profile written by a
	-- build that stored something else in this key degrades to "not held", which
	-- costs a tester one button press and never strands an account blank.
	out.tutorialHold = (d.tutorialHold == true)
	out.atvTier = (type(d.atvTier) == "number") and math.max(0, math.floor(d.atvTier)) or 0
	-- `== true` rather than a truthiness test: a profile written by a build that
	-- stored something else in this key degrades to "not done", which costs a
	-- returning player one dismissable card and never the other way round.
	out.tutorialDone = (d.tutorialDone == true)
	out.rebirthPromptSeen = (d.rebirthPromptSeen == true)
	out.starterPackClaimed = (d.starterPackClaimed == true)
	-- Only keys that still exist in CodeConfig are carried forward, and only as
	-- `true`. A profile cannot therefore grow a code table of its own, and a code
	-- deleted from the config stops costing anything to store.
	if type(d.codes) == "table" then
		for key in pairs(d.codes) do
			if type(key) == "string" and CodeConfig.ByCode[key] and d.codes[key] == true then
				out.codes[key] = true
			end
		end
	end
	out.vipPetClaimed = (d.vipPetClaimed == true)
	out.freeRewardClaimed = (d.freeRewardClaimed == true)

	if type(d.levels) == "table" then
		for _, t in ProgressionConfig.Tracks do
			local lv = d.levels[t.key]
			if type(lv) == "number" and lv == lv then
				out.levels[t.key] = math.clamp(math.floor(lv), 1, ProgressionConfig.MaxLevel)
			end
		end
	end

	-- Same shape, its own ceiling, and clamped from ZERO rather than one: level 0
	-- is "no rake fitted" and is a real state, not a missing value.
	--
	-- A v1 RAKE LEVEL IS DOUBLED, ONCE. The ladder went 25 rungs of two studs
	-- -> 50 rungs of one stud with schema 2 (see AtvConfig.Upgrades), so rung 7
	-- of the old bar and rung 14 of the new one are the same 62.5 studs -- the
	-- doubling is what keeps a paid-for width from silently narrowing. It keys
	-- off the INCOMING schema and the clamp uses the live CarMaxLevel, so it
	-- can never run twice and never exceed the ladder.
	local v1Rake = (tonumber(d.schema) or 1) < 2
	if type(d.carLevels) == "table" then
		for _, t in AtvConfig.Upgrades do
			local lv = d.carLevels[t.key]
			if type(lv) == "number" and lv == lv then
				lv = math.floor(lv)
				if v1Rake and t.key == "Rake" then
					lv *= 2
				end
				-- The TRACK's own ceiling since 2026-09-18 -- the car ladder's tracks
				-- no longer all run to fifty, and a save clamped to the longest one
				-- would let a short track load above its own top and stay there.
				out.carLevels[t.key] = math.clamp(lv, 0, AtvConfig.carCeiling(t))
			end
		end
	end

	local pets = (type(d.pets) == "table") and d.pets or {}
	if type(pets.owned) == "table" then
		for petId, count in pets.owned do
			if PetConfig.get(petId) and type(count) == "number" and count > 0 then
				out.pets.owned[petId] = math.floor(count)
			end
		end
	end
	if type(pets.equipped) == "table" then
		for _, petId in ipairs(pets.equipped) do
			if PetConfig.get(petId) then
				table.insert(out.pets.equipped, petId)
			end
		end
	end
	if type(pets.discovered) == "table" then
		for petId in pets.discovered do
			if PetConfig.get(petId) then
				out.pets.discovered[petId] = true
			end
		end
	end
	-- Validated against the catalogue like the three above it, and NOT against
	-- `owned`: PetServer.setLocked allows a lock to run ahead of the pet, so a
	-- flag with no copy behind it is a legitimate state rather than a stale one.
	if type(pets.locked) == "table" then
		for petId in pets.locked do
			if PetConfig.get(petId) then
				out.pets.locked[petId] = true
			end
		end
	end

	-- Checked against the catalogue the same way the four above are, which is
	-- also what quietly drops an id retired from ItemConfig since it was saved.
	if type(d.itemsFound) == "table" then
		for itemId in d.itemsFound do
			if type(itemId) == "string" and ItemConfig.get(itemId) then
				out.itemsFound[itemId] = true
			end
		end
	end

	--[[
		THE ONE FIELD THIS MODULE DOES NOT VALIDATE FIELD BY FIELD, and that is
		deliberate rather than lazy. Everything above is checked here because
		this module knows what a level or a pet id is; it does not know what a
		streak or a quest key is, and a copy of those rules here would be a
		second place to update every time a quest is added.

		`RewardsServer.restore` does the deep validation instead -- it drops
		unknown quest keys, clamps the streak and survives garbage -- so all
		that is owed here is "a table or nothing", which is what stops a
		corrupt profile from reaching it as a string.
	]]
	if type(d.rewards) == "table" then
		out.rewards = d.rewards
	end

	-- Same contract as `rewards` above and for the same reason: this module
	-- does not know what a skin key is, and a copy of that rule here would be a
	-- second place to update every time a room is added. SkinService.restore
	-- does the deep validation -- it drops keys this build has retired and
	-- falls back to the stock sifter -- so all that is owed here is "a table or
	-- nothing", which is what stops a corrupt profile reaching it as a string.
	if type(d.skins) == "table" then
		out.skins = d.skins
	end

	-- Same contract as `rewards` and `skins` above. BoostService.restore checks
	-- the deadline against the clock and drops one already past, so all that is
	-- owed here is "a table or nothing".
	if type(d.boost) == "table" then
		out.boost = d.boost
	end

	-- Same again: SettingsServer.restore checks every key and value against its
	-- whitelist, so a retired setting or a value this build no longer draws is
	-- dropped there rather than described twice.
	if type(d.settings) == "table" then
		out.settings = d.settings
	end

	-- Strings only, and rebuilt rather than aliased. ProductServer.restore bounds
	-- the length and drops anything else; all that is owed here is that it reaches
	-- that function as a list rather than as something it would try to index.
	if type(d.receipts) == "table" then
		for _, id in ipairs(d.receipts) do
			if type(id) == "string" and #id > 0 then
				table.insert(out.receipts, id)
			end
		end
	end

	return out
end

-- What this player looks like RIGHT NOW. Pets are excluded on purpose: they are
-- kept live in prof.data.pets by the OnPetsChanged hook, because by the time a
-- leave-save runs PetServer has already forgotten them. See note 3.
local function collect(player: Player)
	local prof = profiles[player]
	if not prof then
		return nil
	end
	local d = prof.data
	d.schema = SCHEMA
	d.coins = math.max(0, math.floor(SellServer.getCoins(player)))
	d.levels = {}
	for _, t in ProgressionConfig.Tracks do
		d.levels[t.key] = ProgressionServer.levelOf(player, t.key)
	end
	d.carLevels = {}
	for _, t in AtvConfig.Upgrades do
		d.carLevels[t.key] = AtvConfig.carLevelOf(player, t.key)
	end
	d.rebirths = ProgressionServer.rebirthsOf(player)
	d.tideEarned = math.max(0, math.floor(ProgressionServer.tideEarnedOf(player)))
	d.totalEarned = math.max(0, math.floor(tonumber(player:GetAttribute("TotalEarned")) or 0))
	-- `or d.trashPicked` for the reason tutorialDone has the same guard below: a
	-- save that races a join reads an attribute that is not on the player yet,
	-- and a plain read would write a lifetime counter back down to nothing.
	d.trashPicked = math.max(
		math.floor(tonumber(player:GetAttribute(LeaderboardConfig.TrashAttribute)) or 0),
		math.floor(tonumber(d.trashPicked) or 0))
	-- Same guard, and `max` is right for a second reason here: the mark only ever
	-- moves FORWARD, at a rebirth. A save racing a join that read nil would
	-- otherwise hand the player a free tide's worth of the gate.
	d.tideTrashBase = math.max(
		math.floor(tonumber(player:GetAttribute("TideTrashBase")) or 0),
		math.floor(tonumber(d.tideTrashBase) or 0))
	-- NOT held once set, unlike tutorialDone: this flag has to be able to go
	-- FALSE again -- that is the whole of its end condition -- so it is captured
	-- straight off the player. A save racing a join reads nil and writes false,
	-- which un-holds an account that was mid-onboarding; the cost of that is one
	-- press of the panel button, against an `or` that could stick an account
	-- blank with no way out.
	d.tutorialHold = player:GetAttribute(TutorialConfig.HoldAttribute) == true
	d.atvTier = math.max(0, math.floor(tonumber(player:GetAttribute("AtvTier")) or 0))
	-- HELD ONCE SET, never cleared: `or d.tutorialDone` means a save that races a
	-- join -- attributes not applied yet -- cannot un-retire a tutorial the
	-- player has already been through.
	d.tutorialDone = (player:GetAttribute(TutorialConfig.DoneAttribute) == true)
		or (d.tutorialDone == true)
	-- Held once set, same shape and same reason: a save that races a join --
	-- attribute not restored yet -- must not write a false over a true and make
	-- the card reappear for an account that has already seen it.
	d.rebirthPromptSeen = (player:GetAttribute(RebirthPromptConfig.SeenAttribute) == true)
		or (d.rebirthPromptSeen == true)
	-- Held once set, for the same reason and by the same shape. This is the flag
	-- that stops the Starter Pack paying out twice, so a capture that could write
	-- a `false` over a `true` -- a save racing a join, before the attribute has
	-- been put back on the player -- would be worth 20,000 coins each time it
	-- happened.
	d.starterPackClaimed = (player:GetAttribute(PassConfig.ClaimedAttribute) == true)
		or (d.starterPackClaimed == true)
	--[[
		HELD ONCE SET, the same shape as the three flags around it and for the same
		reason: a capture that wrote a redemption back out as absent -- a save racing
		a join, before the attributes have been put back on the player -- would let
		the same code be redeemed twice.

		Unioned rather than replaced, so whichever of the two sources knows about a
		code wins. The live attribute is the truth during a session; the stored set
		is the truth across one.
	]]
	d.codes = (type(d.codes) == "table") and d.codes or {}
	for key in pairs(CodeConfig.ByCode) do
		if player:GetAttribute(CodeConfig.AttrPrefix .. key) == true then
			d.codes[key] = true
		end
	end
	d.vipPetClaimed = (player:GetAttribute(PassConfig.VipClaimedAttribute) == true)
		or (d.vipPetClaimed == true)
	-- Same held-once-set shape, same reason: a capture that wrote false over true
	-- would be worth another 1,000 coins every time it happened.
	d.freeRewardClaimed = (player:GetAttribute(FreeRewardConfig.ClaimedAttribute) == true)
		or (d.freeRewardClaimed == true)
	-- Held rather than overwritten if the export comes back nil: that means the
	-- player has no rewards state yet (a save racing a join), and writing nil
	-- over a good profile would wipe a streak the player had earned.
	d.rewards = RewardsServer.exportFor(player) or d.rewards or {}
	-- Held rather than overwritten on nil, exactly like `rewards` above -- and
	-- here the cost of getting it wrong is the highest in the file: forgetting a
	-- receipt that has already been paid is what lets the same purchase pay out a
	-- second time.
	d.receipts = ProductServer.exportFor(player) or d.receipts or {}
	-- Held rather than overwritten on nil, exactly like `rewards` and
	-- `receipts`: a nil here means the player has no skin state yet (a save
	-- racing a join), and writing that over a good profile would take back a
	-- skin somebody walked the length of a tomb for.
	d.skins = SkinService.exportFor(player) or d.skins or {}
	--[[
		NOT the `or d.boost` shape the three above use, because here a nil MEANS
		something. "No boost is running" is the ordinary state and has to be able to
		clear the field, or an expired boost would sit in the profile for good.

		But nil is ALSO what a save racing a join reads, before apply has put the
		attributes back -- and that one must not wipe paid time. The stored DEADLINE
		is what tells the two apart: still in the future means the export was early,
		already past means the boost is genuinely over.
	]]
	local liveBoost = BoostService.exportFor(player)
	if liveBoost then
		d.boost = liveBoost
	elseif not (type(d.boost) == "table" and (tonumber(d.boost.until_) or 0) > os.time()) then
		d.boost = nil
	end
	-- Held on empty, like `rewards` and `skins`: an export with nothing in it is
	-- what a save racing a join reads, before restore has put the attributes back,
	-- and writing that over a good profile would forget a setting the player had
	-- chosen. A setting is only ever cleared by being changed to another value.
	local liveSettings = SettingsServer.exportFor(player)
	if liveSettings and next(liveSettings) ~= nil then
		d.settings = liveSettings
	end
	return d
end

-- Put a loaded profile back onto the player. Order matters: attributes first,
-- then ONE applyAll (which is the only thing that turns a level into a walk
-- speed, a bag size or a washer), then one push, then pets.
--[[
	THE ITEM INDEX, SENT WHOLE.

	An ARRAY of ids rather than the set itself: this crosses a remote, and N
	strings is a good deal less wire than N key/true pairs. The client turns
	it back into a set on arrival.

	Sent on two occasions, answering two different problems. Once at the end
	of `apply` below, which covers the ordinary join; and again whenever the
	client asks, which covers the race where the Index board finished building
	after that first send had already gone out. Both are safe to repeat -- the
	client unions what it is given.

	Declared HERE, above `apply`, rather than down with the install hooks it
	otherwise belongs beside: `apply` calls it, and a local declared after its
	caller is not an upvalue at all -- the name would read as a nil global.
]]
local function pushIndex(player: Player)
	local prof = profiles[player]
	if not (prof and prof.data and prof.data.itemsFound) then
		return
	end
	local ids = {}
	for itemId in prof.data.itemsFound do
		table.insert(ids, itemId)
	end
	Net.get("IndexSync"):FireClient(player, ids)
end


local function apply(player: Player, d)
	restoring[player] = true

	-- Through the one grant path, but with the earning counters suppressed. See
	-- note 1 -- this is the line that would otherwise hand every returning player
	-- their whole balance as this tide's earnings.
	--[[
		A CREDIT, NOT A SET -- bug fixed 2026-09-09.

		This used to add `d.coins - have`, which lands the balance ON the saved
		figure however much was earned while the profile was in flight -- so a sale
		made in the load window was simply erased when the profile arrived. That
		window is ordinary rather than exotic: nothing gates earning or spending on
		the load, deliberately, and WHY THERE IS NO "WAIT FOR LOAD" GATE at the top
		of this file argues why it stays that way.

		The saved balance is money the account already had, so it is paid ON TOP of
		whatever the window earned. On an ordinary join the live balance is zero
		(SellServer starts every session's counter at 0), so this reads exactly the
		same as the old line for everybody who was not in that race.
	]]
	if d.coins > 0 then
		SellServer.addCoins(player, d.coins)
	end

	for _, t in ProgressionConfig.Tracks do
		local lv = d.levels[t.key]
		if lv then
			player:SetAttribute(ProgressionConfig.AttrPrefix .. t.key, lv)
		end
	end
	-- BEFORE applyAll below, with the rest of the raw attributes. The rake is not
	-- an input to applyAll -- its consumer is AtvServer, not this file -- but it
	-- belongs inside the `restoring` window with everything else, so a save that
	-- races a join cannot catch the player half restored.
	for _, t in AtvConfig.Upgrades do
		local lv = d.carLevels[t.key]
		if lv then
			player:SetAttribute(AtvConfig.CarAttrPrefix .. t.key, lv)
		end
	end
	player:SetAttribute("Rebirths", d.rebirths)
	-- BOTH `max` RATHER THAN A PLAIN SET -- bug fixed 2026-09-09, the same load
	-- window as the coin credit above. A sale or a piece of litter picked before
	-- the profile landed has already moved these two, and writing the saved
	-- figure over the live one took that back off the lifetime earnings and off
	-- the MOST TRASH board the second counter is ranked by. `collect` guards the
	-- same pair in the other direction -- a save racing a join must not write a
	-- live zero over a saved total -- and this is that reasoning pointed the
	-- other way. Both only ever move forward, so `max` cannot invent progress:
	-- on an ordinary join the live value is 0 and the saved one wins.
	player:SetAttribute("TotalEarned", math.max(d.totalEarned,
		math.floor(tonumber(player:GetAttribute("TotalEarned")) or 0)))
	player:SetAttribute(LeaderboardConfig.TrashAttribute, math.max(d.trashPicked,
		math.floor(tonumber(player:GetAttribute(LeaderboardConfig.TrashAttribute)) or 0)))
	player:SetAttribute("TideTrashBase", d.tideTrashBase)
	-- Only when TRUE, so an ordinary account carries no attribute at all and
	-- DevGrant's check is a plain nil test.
	if d.tutorialHold then
		player:SetAttribute(TutorialConfig.HoldAttribute, true)
	end
	player:SetAttribute("TideEarned", d.tideEarned)
	if d.atvTier > 0 then
		player:SetAttribute("AtvTier", d.atvTier)
	end
	-- Only when TRUE, so a player who has not been through it carries no
	-- attribute at all -- which is what TutorialConfig.looksNew reads as "new"
	-- and what TutorialServer clears back to when it is not wanted.
	if d.tutorialDone then
		player:SetAttribute(TutorialConfig.DoneAttribute, true)
	end
	-- Same shape: absent is what RebirthUnlockPrompt reads as "never shown".
	if d.rebirthPromptSeen then
		player:SetAttribute(RebirthPromptConfig.SeenAttribute, true)
	end
	-- Same shape again, one attribute per redeemed code: absent is what
	-- CodeService reads as "not used yet". Only codes still in the config are put
	-- back, so retiring one stops it costing an attribute on every join.
	if type(d.codes) == "table" then
		for key in pairs(d.codes) do
			if CodeConfig.ByCode[key] then
				player:SetAttribute(CodeConfig.AttrPrefix .. key, true)
			end
		end
	end
	-- Only ever stamped TRUE, never cleared to false: absent is what
	-- StarterPackService reads as "not given yet", and writing an explicit false
	-- here would be indistinguishable from it anyway.
	if d.starterPackClaimed then
		player:SetAttribute(PassConfig.ClaimedAttribute, true)
	end
	if d.vipPetClaimed then
		player:SetAttribute(PassConfig.VipClaimedAttribute, true)
	end
	if d.freeRewardClaimed then
		player:SetAttribute(FreeRewardConfig.ClaimedAttribute, true)
	end

	restoring[player] = nil

	ProgressionServer.applyAll(player)
	ProgressionServer.push(player)
	PetServer.restore(player, d.pets.owned, d.pets.equipped, d.pets.discovered, d.pets.locked)
	-- Order-independent -- it depends on nothing and nothing depends on it. What
	-- matters is only that it runs on EVERY join, so a receipt Roblox re-sends is
	-- recognised as one that has already been paid.
	ProductServer.restore(player, d.receipts)
	-- Order-independent: it depends on nothing above it and nothing below it
	-- reads a skin. It writes the SkinOwn_/SkinChosen/SkinActive attributes,
	-- and CTB_Client re-forges the tool off the last of those on its own.
	SkinService.restore(player, d.skins)
	-- Order-independent, and the board on the other end is built to be told
	-- this more than once -- see pushIndex.
	pushIndex(player)

	--[[
		AND SAY THAT THE ANSWER IS IN. Last line of the restore, after every
		attribute this function writes, because the whole value of the flag is that
		anything reading it afterwards sees the finished player rather than a
		half-written one.

		IN apply() RATHER THAN IN onJoin, because there are TWO ways to get here:
		the ordinary join, and retryLoad a minute after a load that failed. Stamping
		at the call sites would mean remembering to do it at both, and the retry is
		exactly the path somebody would forget. onJoin's failure exits stamp it
		themselves -- for those there is no profile coming and what is already on
		the player IS the answer.

		STAMPING IT TWICE IS FINE: a retry re-writes true over true, which changes
		nothing and fires no signal.
	]]
	if player.Parent then
		player:SetAttribute(TutorialConfig.ProfileAttribute, true)
	end
	-- Order-independent, and it must run on every join or a boost bought in the
	-- last server would be gone. It writes the two CTB_Boost attributes, drops a
	-- deadline that has already passed, and the till reads them at the next sale.
	BoostService.restore(player, d.boost)
	-- Order-independent, and it must run on every join or the setting it saves is
	-- pointless. It writes `Set_<key>` attributes; MenuHud's Settings panel watches
	-- for them and re-applies, which is what covers the panel being built before
	-- the profile has landed.
	SettingsServer.restore(player, d.settings)
	-- LAST, and after the attributes above are on the player: restore() rolls
	-- the day, and rolling the day stamps the baselines that today's quests
	-- measure against. Stamped before TotalEarned was restored, every daily
	-- quest would open already complete on the returning player's first join.
	RewardsServer.restore(player, d.rewards)
end

--------------------------------------------------------------------------
-- THE STORE
--------------------------------------------------------------------------

--[[
	HAND BACK A LOCK WE STAMPED AND THEN NEVER USED -- bug fixed 2026-09-09.

	loadProfile CLAIMS the profile inside the same UpdateAsync that reads it, so
	the stamp is on disk before anything downstream can go wrong. Two paths then
	threw the profile away without clearing it: the player leaving mid-load, and
	onLeave for a session whose profile never landed. Neither could reach
	saveProfile, which is the only other thing that releases a lock -- it refuses
	on the spot for a profile that is not `loaded`.

	WHAT THAT COST. The stamp stood for the full LOCK_STALE (240s), so the
	player's NEXT join was refused its own profile, ran the whole session with
	prof.failed set -- every stat reading as a brand-new account -- and wrote
	nothing at all on the way out. A rejoin inside four minutes is the ordinary
	case for somebody bouncing off a full server, not an exotic one.

	ONLY WHEN THE STAMP IS STILL OURS. Returning nil from the transform aborts
	the write, so a lock another server has since taken is left exactly where it
	is -- stomping one is the duplication this lock exists to prevent.
]]
local function releaseLock(userId: number): boolean
	local s = dataStore()
	if not s then
		return false
	end
	local mine = jobKey()
	local ok, err = pcall(function()
		s:UpdateAsync(KEY_PREFIX .. userId, function(old)
			if type(old) ~= "table" or type(old.lock) ~= "table" or old.lock.jobId ~= mine then
				return nil   -- not ours, or nothing there: leave it alone
			end
			old.lock = nil
			return old
		end)
	end)
	if not ok then
		warn("[Save] lock release failed for " .. tostring(userId) .. ": " .. tostring(err))
	end
	return ok
end

--[[
	Load AND claim, in one UpdateAsync.

	Splitting them -- GetAsync to read, SetAsync to lock -- leaves a window in
	which two servers both read the same profile and both believe they own it,
	which is precisely the duplication a lock exists to prevent. The transform
	returning nil aborts the write, so a profile held elsewhere is left untouched.
]]
local function loadProfile(player: Player)
	local s = dataStore()
	if not s then
		return nil, "nostore"
	end
	local key = KEY_PREFIX .. player.UserId
	local mine = jobKey()

	for attempt = 1, LOAD_RETRIES do
		local ok, result = pcall(function()
			return s:UpdateAsync(key, function(old)
				local d = (type(old) == "table") and old or blank()
				local lock = d.lock
				if type(lock) == "table" and lock.jobId ~= mine
					and (os.time() - (tonumber(lock.at) or 0)) < LOCK_STALE
				then
					return nil   -- still held; do not read it and do not stamp it
				end
				d.lock = { jobId = mine, at = os.time() }
				return d
			end)
		end)

		if not player.Parent then
			-- ABANDONED WITH OUR STAMP ON IT -- bug fixed 2026-09-09. `ok` with a
			-- table back means the transform committed, which means the lock on
			-- disk is ours; dropping the profile here without clearing it shut the
			-- player out of their own save for LOCK_STALE. See releaseLock.
			if ok and type(result) == "table" then
				releaseLock(player.UserId)
			end
			return nil, "left"
		end
		if ok and type(result) == "table" then
			return migrate(result)
		end
		if not ok then
			warn(string.format("[Save] load attempt %d failed for %s: %s",
				attempt, player.Name, tostring(result)))
		end
		-- Backoff. A held lock usually clears within a few seconds -- it is the
		-- previous server finishing its own leave-save.
		task.wait(attempt * 2)
	end
	return nil, "locked"
end

--[[
	DEEP, where the payload literal this replaces used `table.clone`.

	The rule being kept is the old comment's: the transform below can run more
	than once and must not be reading a table something else is mutating
	meanwhile. One level of copying was enough for `levels` and `pets.owned` and
	is NOT enough for `rewards` -- `RewardsServer.exportFor` hands back its LIVE
	`base`, `questDone` and `lifeDone` tables rather than copies of them, so a
	quest claimed or a day rolled mid-write would be reaching into the payload's
	own contents between retries.
]]
local function deepCopy(v)
	if type(v) ~= "table" then
		return v
	end
	local out = table.clone(v)
	for k, val in v do
		if type(val) == "table" then
			out[k] = deepCopy(val)
		end
	end
	return out
end

--[[
	THE WHOLE RECORD, built from `blank()` rather than typed out by hand.

	saveProfile's transform returns this table AS the entire DataStore value, so
	a field this does not produce is a field ERASED from the store on every
	write, however carefully blank/migrate/collect/apply handle it. The
	hand-written literal that used to sit inside saveProfile was missing three,
	and every one of them was invisible at the write and only surfaced a session
	later as something that would not stick:

		tutorialDone  the onboarding replayed on every join, against a
		              TutorialServer header promising that it would not
		rewards       the daily streak, today's quest progress and the
		              milestone board, all back to nothing overnight
		trashPicked   the lifetime counter the MOST TRASH board ranks, zeroed

	So the shape is taken from the one place that already declares what a
	profile IS. `blank()` is what migrate builds into and what apply reads out
	of, so a field added there now reaches the store without anyone having to
	remember this function exists. THAT is the fix -- adding the three back to a
	literal would only have left the next field to be dropped the same way.

	`lock` is deliberately not one of blank()'s keys and so is not copied here:
	it belongs to the transform, which stamps or clears it per write.
]]
local function buildPayload(snap)
	local payload = {}
	for key, default in blank() do
		local v = snap[key]
		-- blank()'s value stands in for a field the live profile has not got
		-- yet, so a save racing a join still writes a complete record rather
		-- than a hole for migrate to read back as a default.
		if v == nil then
			v = default
		end
		payload[key] = deepCopy(v)
	end
	-- Stamped at the write rather than carried through from the snapshot, which
	-- is what the literal did: this IS a schema-SCHEMA record whatever the
	-- profile happened to be loaded as.
	payload.schema = SCHEMA
	return payload
end

--[[
	Write, refusing to trample a profile another server has since claimed.

	`release` clears the lock, and is passed on the way out (leaving, or a server
	shutting down) so the next server can pick the profile up immediately rather
	than waiting LOCK_STALE out.
]]
local function saveProfile(player: Player, release: boolean?): boolean
	local prof = profiles[player]
	if not (prof and prof.loaded) or prof.saving or prof.failed then
		return false
	end
	local s = dataStore()
	if not s then
		return false
	end

	local snap = collect(player)
	if not snap then
		return false
	end

	-- Copied out of the live profile: the transform below can run more than once
	-- and must not be reading a table something else is mutating meanwhile.
	local payload = buildPayload(snap)

	local mine = jobKey()
	prof.saving = true
	local ok, err = pcall(function()
		s:UpdateAsync(KEY_PREFIX .. player.UserId, function(old)
			if type(old) == "table" and type(old.lock) == "table"
				and old.lock.jobId ~= mine
				and (os.time() - (tonumber(old.lock.at) or 0)) < LOCK_STALE
			then
				-- Taken over while we were playing. Ours is the stale copy now.
				return nil
			end
			payload.lock = (not release) and { jobId = mine, at = os.time() } or nil
			return payload
		end)
	end)
	prof.saving = false

	if ok then
		prof.dirty = false
		prof.wroteAt = os.clock()
		return true
	end
	warn("[Save] write failed for " .. player.Name .. ": " .. tostring(err))
	return false
end

--------------------------------------------------------------------------
-- THE HOOKS  --  wrapped, never assigned. See note 2.
--------------------------------------------------------------------------

local function installCoinHook()
	local previous = SellServer.OnCoinsChanged
	SellServer.OnCoinsChanged = function(player, total, delta)
		if restoring[player] then
			-- A restore is not an earning: ProgressionServer's handler would add
			-- this delta to TideEarned, which is the rebirth gate. The real
			-- counters are written from the profile two lines later.
			return
		end
		if previous then
			previous(player, total, delta)
		end
		local prof = profiles[player]
		if prof then
			prof.dirty = true
		end
	end
end

local function installSkinHook()
	local previous = SkinService.OnSkinsChanged
	SkinService.OnSkinsChanged = function(player, owned, chosen)
		if previous then
			previous(player, owned, chosen)
		end
		local prof = profiles[player]
		if prof then
			prof.dirty = true
		end
	end
end

--[[
	RECORD, AND ONLY RECORD.

	The live board needs nothing from here: MenuHud has marked its own finds
	off WashItemCleaned, SellResult and InventorySync since it was written,
	and those still do that job. What was missing was only that none of it
	survived the session, so this writes and does not re-broadcast.

	The `already known` early-out is what keeps this off the dirty flag: a
	player raking the same Common for an hour would otherwise mark the
	profile dirty on every single piece and buy a save every SAVE_INTERVAL
	for no change at all.
]]
local function installItemIndexHook()
	InventoryController.Server.Discovered:Connect(function(player, itemId)
		if type(itemId) ~= "string" or not ItemConfig.get(itemId) then
			return
		end
		local prof = profiles[player]
		if not (prof and prof.data and prof.data.itemsFound) then
			return
		end
		if prof.data.itemsFound[itemId] then
			return
		end
		prof.data.itemsFound[itemId] = true
		prof.dirty = true
	end)
end


local function installPetHook()
	local previous = PetServer.OnPetsChanged
	PetServer.OnPetsChanged = function(player, owned, equipped, locked)
		if previous then
			previous(player, owned, equipped, locked)
		end
		local prof = profiles[player]
		if not prof then
			return
		end
		local pets = prof.data.pets
		-- These are already clones (PetServer.push copies before it calls us).
		pets.owned = owned
		pets.equipped = equipped
		-- REPLACED, not merged, because unlike `discovered` this one has to be able
		-- to SHRINK: unlocking is half the feature, and a merge would make a lock
		-- permanent the moment it was first taken.
		--
		-- Guarded because this hook is also reachable from a PetServer old enough
		-- not to send the field -- a nil here would blank the list rather than
		-- leave it alone.
		if locked then
			pets.locked = locked
		end
		-- `discovered` only grows and is not in the payload. See note 4.
		for petId in owned do
			pets.discovered[petId] = true
		end
		prof.dirty = true
	end
end

--------------------------------------------------------------------------
-- JOIN / LEAVE
--------------------------------------------------------------------------

local function notify(player: Player, text: string, kind: string?)
	local ok = pcall(function()
		Net.get("Notify"):FireClient(player, { text = text, kind = kind or "info" })
	end)
	return ok
end

--[[
	ONE MORE GO AT A LOAD THAT FAILED -- bug fixed 2026-09-09.

	A failed load used to be final for the whole session: prof.failed stands,
	every stat reads as a brand-new account and nothing is written on the way
	out. But the commonest cause of one is not a broken DataStore, it is a lock
	the PREVIOUS server left behind -- and that clears itself with time. Asking a
	second time turns most of these back into an ordinary load.

	ONE retry, a minute later. Not a loop: a profile that is genuinely unreadable
	would cost the whole server's request budget to keep asking, and the honest
	answer to the player is the toast they already have.

	WHAT MAKES A LATE APPLY SAFE. The session has been running for a minute by
	the time this lands, so the player may have earned coins, bought levels and
	hatched pets the loaded profile knows nothing about -- and apply() would
	otherwise write the saved figures straight over them. So the live session is
	folded into the profile FIRST, by the rule collect() already uses in the
	other direction: a counter takes the higher of the two, a collection takes
	both. Coins and the two lifetime counters need no help here -- apply()
	credits and maxes them itself, for exactly this reason.
]]
local RETRY_AFTER = 60

local function foldLiveInto(player: Player, d)
	local live = collect(player)
	if not live then
		return
	end
	-- Levels and rake rungs were bought with coins earned this session, so the
	-- higher of the two is the one the player actually paid for.
	for _, t in ProgressionConfig.Tracks do
		local lv = live.levels[t.key]
		if type(lv) == "number" then
			d.levels[t.key] = math.max(d.levels[t.key] or 0, lv)
		end
	end
	for _, t in AtvConfig.Upgrades do
		local lv = live.carLevels[t.key]
		if type(lv) == "number" then
			d.carLevels[t.key] = math.max(d.carLevels[t.key] or 0, lv)
		end
	end
	d.rebirths = math.max(d.rebirths, tonumber(live.rebirths) or 0)
	d.tideEarned = math.max(d.tideEarned, tonumber(live.tideEarned) or 0)
	d.tideTrashBase = math.max(d.tideTrashBase, tonumber(live.tideTrashBase) or 0)
	d.atvTier = math.max(d.atvTier, tonumber(live.atvTier) or 0)
	-- Pets ADD rather than take the higher count: this session's collection
	-- started empty (nothing was restored into it), so every copy in it was
	-- hatched in the window and is one the saved profile has never seen.
	-- PetServer.restore caps the total against PetConfig.MaxOwned.
	for petId, count in live.pets.owned do
		if type(count) == "number" and count > 0 then
			d.pets.owned[petId] = (d.pets.owned[petId] or 0) + math.floor(count)
			d.pets.discovered[petId] = true
		end
	end
	-- Unioned, never replaced: both sides are records of what has happened and
	-- neither is allowed to shrink the other. Same rule as `pets.discovered`.
	for itemId in live.itemsFound do
		d.itemsFound[itemId] = true
	end
	--[[
		RECEIPTS ARE UNIONED, AND LEAVING THEM OUT PAYS A PURCHASE TWICE -- bug
		fixed 2026-09-09, alongside the retry this function serves.

		ProductServer.restore is the one restore apply() calls that RESETS its live
		state before it rebuilds -- `l.durable, l.session, l.order = {}, {}, {}`.
		On an ordinary join that is correct, because the log is empty. On this path
		it is not. A product bought inside the failed window was GRANTED and then
		recorded as `session`, which is ProductServer's note to itself that the
		coins are already on the player and it must never grant again; its commit
		then returned false because saving was off, so Roblox still holds the
		receipt and goes on re-sending it. Wiping that note makes the next re-send
		look like a brand-new purchase, and grantOf hands over a SECOND Quick
		Upgrade, coin pack or Golden Hour for one charge -- ProductServer's own
		"GRANT TOO OFTEN" failure, in the one path where it costs real money.

		`live.receipts` is ProductServer.exportFor's list, session ids included,
		which is exactly how those ids are meant to become durable. APPENDED
		rather than merged in place, so the log stays oldest-first for the pruning
		ProductServer does by age.
	]]
	local seen = {}
	for _, id in ipairs(d.receipts) do
		seen[id] = true
	end
	for _, id in ipairs(live.receipts or {}) do
		if type(id) == "string" and #id > 0 and not seen[id] then
			seen[id] = true
			table.insert(d.receipts, id)
		end
	end
end

local function retryLoad(player: Player)
	task.wait(RETRY_AFTER)
	local prof = profiles[player]
	if not (player.Parent and prof and prof.failed and not prof.loaded) then
		return
	end

	local d, reason = loadProfile(player)
	if not d then
		warn(string.format("[Save] retry could not load %s (%s) -- saving stays OFF",
			player.Name, tostring(reason)))
		return
	end

	prof = profiles[player]
	if not (player.Parent and prof and prof.failed and not prof.loaded) then
		-- Loaded it and cannot use it -- hand the stamp straight back rather than
		-- sit on it for LOCK_STALE. Same bug as the one releaseLock documents.
		releaseLock(player.UserId)
		return
	end

	foldLiveInto(player, d)
	prof.data = d
	prof.loaded = true
	prof.failed = false
	-- Dirty on purpose: the folded record has to reach the store even if the
	-- player does nothing else for the rest of the session.
	prof.dirty = true
	apply(player, d)
	print(string.format("[Save] %s loaded on retry -- saving is ON for the rest of "
		.. "the session", player.Name))
	notify(player, "Your save loaded. Your progress WILL be kept after all.", "info")
end

local function onJoin(player: Player)
	if profiles[player] then
		return
	end
	profiles[player] = {
		data = blank(), loaded = false, dirty = false,
		saving = false, failed = false, wroteAt = os.clock(),
	}

	--[[
		SAY SO WHEN WE ARE DONE, WHATEVER THE ANSWER IS.

		TutorialConfig.ProfileAttribute is "the server has finished deciding who
		this player is" -- see its note for the two mobile reports that made it
		necessary. It is stamped on EVERY outcome below that leaves the player in
		the game, including the ones where nothing loaded: a client that waits for
		this must not wait for ever in a place with no API access.

		LOCAL, and called at each exit rather than deferred, so a path added later
		has to walk past it.
	]]
	local function settled()
		if player.Parent then
			player:SetAttribute(TutorialConfig.ProfileAttribute, true)
		end
	end

	local d, reason = loadProfile(player)
	if not player.Parent then
		-- The same abandonment loadProfile guards against, caught one line later --
		-- bug fixed 2026-09-09. A profile in hand means the lock on disk is ours,
		-- and dropping it here without clearing it shuts the player out of their
		-- own save for LOCK_STALE. See releaseLock.
		if d then
			releaseLock(player.UserId)
		end
		profiles[player] = nil
		return
	end

	if not d then
		-- SAVING IS DISABLED FOR THE SESSION rather than starting from blank and
		-- writing over a profile we simply could not read. Losing a session is
		-- recoverable; overwriting a real one is not.
		local prof = profiles[player]
		prof.failed = true
		if reason == "nostore" then
			-- Already warned once, at the top. Studio without API access is the
			-- normal case for this one and does not deserve a toast per player.
			--
			-- SETTLED ANYWAY: there is no profile coming, so what is on the player
			-- now is the final answer. Without this a Studio session would hold the
			-- onboarding card back for ever, which is the one place it is most
			-- often tested.
			settled()
			return
		end
		warn(string.format("[Save] could not load %s (%s) -- saving is OFF this session",
			player.Name, tostring(reason)))
		notify(player, "Could not load your save. Progress will NOT be kept this session.", "warn")
		-- ...and one more attempt in a minute rather than writing the whole session
		-- off on the first answer -- bug fixed 2026-09-09. See retryLoad.
		task.spawn(retryLoad, player)
		-- Settled on what we have, which for a failed load is whatever the join
		-- hooks stamped. If retryLoad succeeds a minute later it goes through
		-- apply(), which stamps this again over the top -- harmless, and the honest
		-- ordering: the client is told the answer it would have acted on, and then
		-- handed the better one.
		settled()
		return
	end

	local prof = profiles[player]
	prof.data = d
	prof.loaded = true
	apply(player, d)
end

local function onLeave(player: Player)
	local prof = profiles[player]
	-- THE LEAVE-SAVE IS ALSO THE LOCK RELEASE, and it refuses outright for a
	-- profile that never landed -- `prof.loaded` is still false, so saveProfile
	-- returns on its first line -- bug fixed 2026-09-09. loadProfile had already
	-- stamped the lock by then, so the one session that could NOT use the profile
	-- was the session holding it shut for LOCK_STALE, and the player's next join
	-- read as a brand-new account with saving switched off. See releaseLock.
	if not saveProfile(player, true) and prof and not prof.loaded then
		releaseLock(player.UserId)
	end
	profiles[player] = nil
	restoring[player] = nil
end

--------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------

--[[
	For testing, and for anything that wants a write at a known moment.

	IT WAITS OUT A WRITE THAT IS ALREADY IN FLIGHT, and that is the whole reason
	this is more than one line.

	saveProfile refuses outright while `prof.saving` is set -- correctly, because
	two UpdateAsync calls on one key would race. But every caller of THIS function
	has just handed over a one-time, paid grant (the Starter Pack, the VIP pet, the
	free reward) and is asking for the one thing that closes the duplicate-payout
	window: the claim on disk before the server can die. Answering "no" because
	another save happened to be mid-flight leaves that window open for the whole
	autosave interval.

	OBSERVED, not theorised: a player whose VIP pet and Starter Pack both resolved
	in the same second had the second grant's forced write refused, and the log
	read "granted the pet but the forced save did not land". Nothing was lost --
	the profile stays dirty and the leave handler writes it -- but the guarantee
	those three rules are built on was quietly not there.

	ONE extra attempt, after the in-flight write finishes. Not a loop: if the
	second try fails too, the profile is still dirty and the ordinary periodic and
	leave saves are still the backstop, exactly as before.

	IT YIELDS, up to WAIT_FOR_INFLIGHT. Every caller is already on a spawned thread
	that has just waited on the profile loading, so this costs nothing anybody is
	watching.
]]
local WAIT_FOR_INFLIGHT = 3

function SaveService.forceSave(player: Player): boolean
	if saveProfile(player, false) then
		return true
	end

	-- Anything a retry cannot fix -- never loaded, load failed, gone -- is final.
	local prof = profiles[player]
	if not (prof and prof.loaded and not prof.failed and player.Parent) then
		return false
	end

	local waited = 0
	while prof.saving and waited < WAIT_FOR_INFLIGHT and player.Parent do
		task.wait(0.1)
		waited += 0.1
	end
	if not player.Parent then
		return false
	end
	return saveProfile(player, false)
end

function SaveService.isLoaded(player: Player): boolean
	local prof = profiles[player]
	return (prof ~= nil) and prof.loaded == true
end

--[[
	CLEAR ONE OF THE ONE-TIME FLAGS, so a reward can be tested more than once.

	THIS EXISTS BECAUSE THE FLAGS ARE HELD ONCE SET AND THAT IS DELIBERATE. Every
	one of them guards a payout -- the tutorial, the starter pack, the free reward
	-- and the capture path ORs the attribute with the stored value precisely so a
	save racing a join cannot write a false over a true. That is the right rule for
	players and it makes a flag impossible to clear from outside, including for the
	developer testing their own feature. Clearing the attribute alone does nothing:
	the profile still holds true and apply() stamps it straight back on the next
	join.

	WHITELISTED, not general. It takes a KEY from a fixed list rather than any
	field name, so it can never be pointed at coins, levels or pets -- the whole
	class of bug this module exists to prevent.

	It marks the profile dirty and leaves the write to the normal path, so a reset
	follows exactly the same route as any other change.
]]
local CLEARABLE = {
	tutorialDone = true,
	starterPackClaimed = true,
	freeRewardClaimed = true,
	vipPetClaimed = true,
	rebirthPromptSeen = true,
}

function SaveService.clearOneTimeFlag(player: Player, key: string): boolean
	if not CLEARABLE[key] then
		warn("[Save] clearOneTimeFlag refused: '" .. tostring(key)
			.. "' is not a one-time flag. Allowed: tutorialDone, starterPackClaimed, "
			.. "freeRewardClaimed, vipPetClaimed, rebirthPromptSeen.")
		return false
	end
	local prof = profiles[player]
	if not (prof and prof.loaded) then
		warn("[Save] clearOneTimeFlag: " .. player.Name .. " has no loaded profile.")
		return false
	end
	prof.data[key] = false
	prof.dirty = true
	print(string.format("[Save] cleared %s for %s", key, player.Name))
	return true
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

local started = false
function SaveService.start()
	assert(RunService:IsServer(), "[SaveService] server-only")
	if started then
		return
	end
	started = true

	-- Before any player is hooked, so no change can land unrecorded.
	installCoinHook()
	installPetHook()
	installSkinHook()
	installItemIndexHook()

	--[[
		THE CLIENT ASKING FOR ITS OWN INDEX, which is the whole payload: there
		is nothing to validate because there is nothing to send.

		Debounced per player rather than trusted. The reply is built from a
		table this server already holds -- no DataStore call -- so the cost of
		a flood is bandwidth rather than budget, but a client that can ask for
		an unbounded string array as fast as it likes is still a client that
		can be told no.
	]]
	local askedAt: { [Player]: number } = {}
	Net.get("IndexSync").OnServerEvent:Connect(function(player)
		local now = os.clock()
		if now - (askedAt[player] or -math.huge) < INDEX_ASK_EVERY then
			return
		end
		askedAt[player] = now
		pushIndex(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		askedAt[player] = nil
	end)

	--[[
		THE COMMIT HOOK ProductServer WAITS FOR.

		It cannot require this module -- this one requires IT -- so it publishes a
		nil field and this fills it in, the same injected-hook shape as the two
		installs above. Until this line runs every receipt is answered
		NotProcessedYet and Roblox holds on to it, which is the correct behaviour
		for a server whose persistence is not up yet.

		`false` for release: a commit is a checkpoint mid-session, not a handover,
		and clearing the session lock here would invite another server to take the
		profile out from under a player who is still holding it.
	]]
	ProductServer.CommitProfile = function(player: Player): boolean
		return saveProfile(player, false)
	end

	Players.PlayerAdded:Connect(function(player)
		task.spawn(onJoin, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(onJoin, player)
	end
	Players.PlayerRemoving:Connect(onLeave)

	-- Dirty first, then the lock refresh. A player who is not earning writes only
	-- as often as LOCK_REFRESH demands.
	task.spawn(function()
		while true do
			task.wait(SAVE_INTERVAL)
			local now = os.clock()
			for _, player in Players:GetPlayers() do
				local prof = profiles[player]
				if prof and prof.loaded
					and (prof.dirty or now - (prof.wroteAt or 0) >= LOCK_REFRESH)
				then
					saveProfile(player, false)
				end
			end
		end
	end)

	--[[
		THE SHUTDOWN FLUSH, and it is the one that matters most: a soft shutdown
		or a server migration is where a player is most likely to lose the last
		two minutes of their run.

		Spawned in parallel rather than in a loop -- Roblox allows about 30
		seconds here and a serial pass over a full server would not finish.
	]]
	game:BindToClose(function()
		local pending = 0
		for _, player in Players:GetPlayers() do
			pending += 1
			task.spawn(function()
				pcall(saveProfile, player, true)
				pending -= 1
			end)
		end
		local deadline = os.clock() + 20
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)

	print("[Save] profile store online (" .. STORE_NAME .. ")")
end

return SaveService
