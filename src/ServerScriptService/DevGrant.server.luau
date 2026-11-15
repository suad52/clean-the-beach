--[[
	DevGrant  --  ServerScriptService.DevGrant  (Script)

	A TESTING SCRIPT. Hands every player enough money, rebirths and upgrades to
	reach the top of the car spawner without grinding for it. Press Play and it
	has happened -- there is nothing to type and nothing to get wrong.

	STUDIO ONLY, AND THAT IS ENFORCED, NOT REMEMBERED.
	--------------------------------------------------
	RunService:IsStudio() is false on a live server, so publishing this by
	accident cannot hand real players half a million coins. Set ENABLED = false
	to switch it off inside Studio as well, or delete the script -- nothing else
	in the game refers to it.

	WHY IT WAITS INSTEAD OF GRANTING ON JOIN
	----------------------------------------
	CTB_Server sets Coins to 0 in its OWN PlayerAdded handler. Handlers run in
	connection order, so a grant made from another PlayerAdded is in a race it
	can lose -- and losing looks exactly like the grant never happening, which
	is the least debuggable failure available. GRANT_AFTER puts this behind
	every join handler in the game rather than in a race with them.

	WHY A SCRIPT AND NOT A COMMAND BAR LINE
	---------------------------------------
	The Studio command bar runs in the CLIENT context during Play Solo unless
	you change the dropdown. A client that sets its own Coins attribute changes
	only what its own screen says: the panel draws a balance you appear to have,
	and then the server -- which never saw any of it -- refuses the purchase.
	Setting AtvTier the same way is worse, because the panel switches to SPAWN
	and the server answers "You do not own that one." A Script in
	ServerScriptService is on the server by definition.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

----------------------------------------------------------------
-- WHAT TO HAND OUT
----------------------------------------------------------------
--[[
	OFF. THE GAME IS PLAYED FROM ZERO IN STUDIO, THE SAME WAY IT IS PLAYED LIVE.

	This was ON, handing every Studio joiner a billion coins, forty rebirths,
	both machines and every track at 60 -- which is exactly what a maxed test
	account is for, and exactly what makes the game impossible to LOOK at. With
	it on, nothing is ever bought, no gate is ever met, no price is ever felt and
	no shop row ever says anything but SPAWN. The whole progression -- which is
	the game -- is invisible from the first frame.

	It also silently disarmed the onboarding: TutorialConfig.looksNew reads levels
	and rebirths, and this hook granted both, so no Studio joiner ever looked new
	and the tutorial never armed.

	TURN IT BACK ON FOR ONE TEST AND OFF AGAIN. Everything below is still tuned
	for a maxed account, so flipping this line is the whole switch -- but leave it
	on and the next person to open the place will be testing a game nobody plays.

	The REBIRTHS dial below is the gentler tool for most of what this was used
	for: set it to 0, 1, 4, 8, 13, 19 or 26 with ENABLED on to stand at one
	particular ferry gate, rather than at the top of everything.
]]
local ENABLED = true

-- A BILLION. Ten million already covered every price in the game (the
-- Celestial Egg at 8,000,000 is the dearest single thing), so this is not about
-- affording anything -- it is so that buying the whole shop twice over does not
-- visibly dent the counter while you are testing something else.
--
-- Kept well inside the range the HUD formats cleanly; there is no reason to go
-- looking for where the coin pill starts truncating.
local COINS = 1000000000

--[[
	THE WHOLE AUTHORED LADDER, READ FROM THE CONFIG RATHER THAN TYPED.

	It was hard-coded -- 38 -- and it had already drifted once: the ladder moved
	to 40 and this hook carried on handing out 38, so "everything" quietly meant
	two rebirths short of everything. Reading the number is the only way it
	cannot happen again, and this file has no other reason to require the config.

	⚠️ IT IS NO LONGER A CAP, and a larger value here now WOULD give a larger
	account. Until 2026-09-11 three separate things pinned this number down --
	ProgressionServer refused a rebirth past it, SaveService clamped the field on
	the way in, and the admin panels scaled to it -- so overshooting was free.
	None of that is true any more: the ladder is endless
	(ProgressionConfig.Rebirth.LadderTides) and whatever this says is what a dev
	account joins holding, permanently. LadderTides is the right value precisely
	because it is everything the game was BUILT for; going above it grants tides
	nobody authored and tests nothing that exists.

	It is also genuinely everything. levelCeiling climbs +2 a tide to rebirth
	16 and +1 to rebirth 36 (2026-08 curve), reaching 60 -- the top of every
	track -- with four pure-multiplier tides after it. THE MAP GATES ARE THE
	THING TO WATCH HERE now that the ferry reads this same counter: the Dunes
	want 1, the tomb 4, Sakura Cove 8, the shrine 14, Ashfall 22 and the magma
	chamber 32. (An earlier list here had the tomb, cove and shrine in the
	wrong order.) All well below the cap, so this hook opens the whole map --
	which is the point of it.

	Drop REBIRTHS to 0 to test the early game honestly. That now also RELOCKS
	EVERY ISLAND except the home beach, which it did not used to do: the ports
	used to gate on the Sifter track, so a granted account with maxed tracks
	could sail anywhere at zero rebirths. Testing the ferry gates is a matter of
	setting this to 0, 1, 4, 8, 14, 22 or 32 and rejoining.
]]
local REBIRTHS = require(game:GetService("ReplicatedStorage").Modules.ProgressionConfig).Rebirth.LadderTides

-- 4 OWNS BOTH MACHINES, so every bay reads SPAWN and costs nothing.
--
-- It is a THRESHOLD against AtvConfig.Tiers' `id` field, not an index into that
-- table: the Sandhog is id 3 and the Tidebreaker id 4, and the ids skip 1 and 2
-- on purpose. Setting this to 2 -- the Tidebreaker's position in the table --
-- would own nothing at all.
--
-- 0 = buy them yourself from the pad, which is the thing worth testing.
local OWN_TIER = 4

--[[
	EVERY upgrade track, set to this level. nil leaves them all alone.

	The tracks run to 60 now, and two of them (Beach Legs, Bucket Size) CARRY
	ONTO A MACHINE once they pass its own stats -- see AtvConfig.effectiveStats.
	That crossover is the thing worth testing and it is tedious to reach by hand
	across four tracks, so this sets the lot at once.

	Useful settings, against the Sandhog (speed 26, hold 300) and the Tidebreaker
	(31 / 650). Speed and hold are the only stats that transfer -- a machine's net
	is its own at every level, see AtvConfig.Transfers:

		 1   nothing transfers -- the machines are exactly their own stats
		 8   the zero-rebirth ceiling, and still nothing transfers: 22 speed and
		     23 lb hold are under both machines
		20   speed beats BOTH machines, hold beats neither
		45   speed and hold beat both -- every stat that transfers is yours
		60   the top of the ladder: 66 speed, 2,675 lb hold

	Capped by the tide ceiling at spend time, but NOT here: this writes the
	attributes directly, the same way a save file would, so it can hand out a
	level the shop would currently refuse to sell. That is the point of a test
	hook and is exactly why it is Studio-only.
]]
-- 60, ProgressionConfig.MaxLevel: 66 speed and 2,675 lb hold, and every stat
-- that transfers onto a machine beats both of them.
local ALL_TRACK_LEVEL = 60

-- Bucket Size on its own, applied AFTER ALL_TRACK_LEVEL so it can override it.
-- nil leaves it alone.
--
-- 6 used to be a 100 lb bag, because the old ladder had six rungs and topped
-- out there. The same level is 30 lbs on the sixty-rung one; 20 is about 98 lbs
-- and 37 is where the bag first out-carries the bulldozer's hopper.
local BUCKET_LEVEL = 60

--[[
	THE CAR LADDER, and it needs its own dial because ALL_TRACK_LEVEL above
	CANNOT REACH IT.

	That loop reads ProgressionConfig.Tracks, and its comment promises "a track
	added later is granted without anyone remembering to come back to this file".
	The Beach Rake breaks that promise: it lives in AtvConfig.Upgrades, under a
	CarLv_ prefix, precisely because it obeys different rules -- no tide ceiling,
	and it survives a rebirth. So it needs saying here or it is silently the one
	thing this hook does not hand out.

	0-BASED. 0 is a bare machine and is the state a real player starts in; nil
	leaves whatever is there alone. 25 is the top: a 98.5 stud rake, which is a
	third of the home beach in one pass.

	AND IT IS USELESS WITHOUT OWN_TIER. Every gate on this ladder -- the shop
	tab, the purchase handler, AtvConfig.effectiveStats -- asks whether you own a
	machine first, so granting a rake to a player with AtvTier 0 buys a level
	nothing will read.
]]
local CAR_LEVEL = 25

--[[
	ONE OF EVERY PET, so the index is full and the luck bonus is whatever a
	complete collection is worth.

	Through PetServer.grant rather than by writing the attribute, because the
	pet bag is NOT a player attribute: it is server-side state that
	SaveService reads back out of PetServer, and it has a catalogue check, an
	owned-count cap, a discovered set and an auto-equip that a direct write
	would all miss. 61 pets against PetConfig.MaxOwned of 250 fits with room.

	Only the first PetConfig.MaxEquipped (5) end up worn -- grant auto-equips
	into free slots and then stops, which is the right behaviour and not a
	failure to grant.
]]
local ALL_PETS = true

--[[
	THE ROBUX PASSES, HANDED OVER AS IF BOUGHT.  STUDIO ONLY.

	WITHOUT THIS THE PASSES CANNOT BE TESTED BY THE PEOPLE WHO BUILT THEM.
	Roblox does not sell you an item you are the seller of, and all three passes
	belong to the group that owns this place -- so UserOwnsGamePassAsync answers
	`false` forever for anyone with a stake in it, the shop paints BUY, the
	prompt goes nowhere, and the Starter Pack's whole grant path is unreachable.
	It looked exactly like the pack being broken, and it was not.

	It goes through GamePassService.setOwnedForTesting, which walks the same
	route a real purchase does, so what is exercised is the real flow: the
	attribute flips as it would for a customer and StarterPackService picks it up
	through its own watcher.

	The claimed flag is cleared just before, because the pack is once per account
	and would otherwise fire on the first Play test of a fresh profile and never
	again. With both on, every Play test is a first purchase.
]]
--
-- OFF BY DEFAULT, because ON it takes the BUY button away. Marking the pass
-- owned is what you want when you are testing what the pack DOES; it is exactly
-- what you do not want when you are testing the SHOP, because the button then
-- reads CLAIMED before you have touched it. Turn it on for the former.
--
-- Either way the claimed flag below is cleared on every join, so the pack is
-- always ready to be handed over again.
local GRANT_PASSES = false

-- Seconds after a player joins. Two is comfortably past every join handler in
-- the game; the intro sequence alone runs longer than that.
local GRANT_AFTER = 2

----------------------------------------------------------------

--[[
	TWO WAYS IN, BECAUSE THEY ANSWER DIFFERENT QUESTIONS.

	ENABLED is the MAXED ACCOUNT: a billion coins, every rebirth, both machines,
	every track at 60, one of every pet. Right for testing the top of the game,
	and -- see its own note -- exactly what makes the game impossible to look at.

	GRANT_PASSES is the ROBUX PASSES, and it runs ON ITS OWN now. Testing
	monetisation needs an account that owns the passes; it does not need an account
	that owns everything else, and until this line you could not have the first
	without the second.

	That mattered more than it sounds, because a maxed account cannot SEE most of
	what the passes do: 2x Cash against a x1,469 sell multiplier is invisible, the
	Starter Pack's 20,000 coins land in a billion and do not move the counter, and
	every upgrade row is already at its ceiling so Quick Upgrade has nothing to
	sell. With ENABLED off, every one of those is legible on a clean account.

	Either flag alone is enough to run. Both off and this file does nothing, which
	is the shipped state.
]]
if not (RunService:IsStudio() and (ENABLED or GRANT_PASSES)) then
	return
end

local function grant(player: Player)
	task.wait(GRANT_AFTER)
	if not player.Parent then
		return
	end

	--[[
		NOT OVER AN ONBOARDING RUN.

		The admin panel's ONBOARDING verb blanks an account back to what a new
		player has so the tutorial can be walked from the top, and raises
		TutorialConfig.HoldAttribute to say so. Without this check that wipe lasts
		two seconds into the next join: everything below stamps a billion coins,
		forty tides and four maxed tracks straight back over it, which is the one
		thing that makes the reset untestable across a rejoin.

		RE-CHECKED AFTER THE WAIT, not before it. GRANT_AFTER exists because
		CTB_Server is still setting Coins to 0 in its own PlayerAdded when this
		fires, and the profile this reads is restored inside that same window --
		so the flag is not reliably on the player two seconds ago.

		TutorialServer.finish clears the hold, so the sandbox comes back on the
		join after the tutorial is finished. Nothing here has to be switched off.
	]]
	local okTut, Tutorial = pcall(require,
		game:GetService("ReplicatedStorage").Modules.TutorialConfig)
	if okTut and player:GetAttribute(Tutorial.HoldAttribute) then
		print(("[DevGrant] %s is mid-onboarding -- nothing granted (clears when the "
			.. "tutorial is finished) -- STUDIO ONLY"):format(player.Name))
		return
	end

	-- EVERY WEALTH WRITE BELOW IS ENABLED's, not GRANT_PASSES'. A pass test wants
	-- an ordinary account; see the note on the guard at the top of this section.
	if ENABLED then
		player:SetAttribute("Coins", COINS)
		player:SetAttribute("Rebirths", REBIRTHS)

		-- The two earnings counters, so the Rebirth panel does not read as broken
		-- next to half a million coins. TotalEarned is lifetime and TideEarned is
		-- this run; ProgressionServer gates rebirths on the second one.
		player:SetAttribute("TotalEarned", math.max(player:GetAttribute("TotalEarned") or 0, COINS))
		player:SetAttribute("TideEarned", math.max(player:GetAttribute("TideEarned") or 0, COINS))
	end

	if ENABLED and OWN_TIER > 0 then
		player:SetAttribute("AtvTier", OWN_TIER)
	end
	if ENABLED and ALL_TRACK_LEVEL then
		-- Read off ProgressionConfig rather than listed here, so a track added
		-- later is granted without anyone remembering to come back to this file.
		local ok, Progression = pcall(require,
			game:GetService("ReplicatedStorage").Modules.ProgressionConfig)
		if ok then
			for _, track in Progression.Tracks do
				player:SetAttribute("Lv_" .. track.key,
					math.clamp(ALL_TRACK_LEVEL, 1, Progression.MaxLevel))
			end
		end
	end
	if ENABLED and BUCKET_LEVEL then
		-- WeightService watches this attribute directly, so capacity follows
		-- without ProgressionServer having to be poked as well.
		player:SetAttribute("Lv_BucketSize", BUCKET_LEVEL)
	end
	if ENABLED and CAR_LEVEL then
		-- Off AtvConfig for the same reason the loop above reads ProgressionConfig:
		-- the prefix, the keys and the ceiling all live over there, and a copy of
		-- any of them here would be a copy that goes stale silently.
		local ok, Atv = pcall(require, game:GetService("ReplicatedStorage").AtvConfig)
		if ok then
			for _, track in Atv.Upgrades do
				player:SetAttribute(Atv.CarAttrPrefix .. track.key,
					math.clamp(CAR_LEVEL, 0, Atv.CarMaxLevel))
			end
		end
	end

	--[[
		RE-DERIVE, because writing the attributes is only half of it.

		ProgressionServer.applyAll turns the raw Lv_* / Rebirths numbers into the
		things the game actually reads: SellMultiplier, RollerWidth/RollerLevel,
		WasherSpread, walk speed, and so on. It runs on join, on purchase and on
		rebirth -- and this hook is none of those, so without this line every
		derived stat stays at whatever the profile loaded with.

		It is not theoretical: with 38 rebirths written straight onto the player,
		SellMultiplier still read 4.30 -- the value for the EIGHT rebirths the
		save had -- so a "maxed" account was selling at a two-hundred-and-fiftieth
		of the rate it was supposed to. Everything looked right in the panels and
		the wallet was wrong.
	]]
	do
		local okP, Progression = pcall(require,
			game:GetService("ServerScriptService"):WaitForChild("ProgressionServer", 10))
		if okP and type(Progression) == "table" and Progression.applyAll then
			local okA, err = pcall(Progression.applyAll, player)
			if not okA then
				warn("[DevGrant] applyAll threw: " .. tostring(err))
			end
		else
			warn("[DevGrant] ProgressionServer would not load; derived stats are stale")
		end
	end

	local pets = 0
	if ENABLED and ALL_PETS then
		local okS, PetServer = pcall(require,
			game:GetService("ServerScriptService"):WaitForChild("PetServer", 10))
		local okC, PetConfig = pcall(require,
			game:GetService("ReplicatedStorage").Modules.PetConfig)
		if okS and okC and type(PetServer) == "table" and PetServer.grant then
			-- Sorted, so the five that auto-equip are the same five every run
			-- rather than whatever order pairs() happened to walk today.
			-- EXCLUSIVES ARE SKIPPED. Kingsmane is the Starter Pack's pet and the
			-- only way to get it is to own the pass; handing it out here would mean
			-- every Studio tester already had it before they bought anything, and
			-- the one thing the pack is meant to deliver could not be seen arriving.
			local ids = {}
			for petId, def in PetConfig.Pets do
				if not (type(def) == "table" and def.Exclusive) then
					table.insert(ids, petId)
				end
			end
			table.sort(ids)
			--[[
				ONE OF EACH, NOT ONE MORE OF EACH PER PLAY TEST.

				This used to grant unconditionally, and the profile is SAVED -- so
				sixty-odd pets went in on every single Play, and a Studio account
				that had been tested on for a week arrived at PetConfig.MaxOwned
				(250) and stuck there. A full bag makes PetServer.grant refuse, and
				an all-or-nothing grant that cannot place its pet hands over NOTHING
				-- so the Starter Pack read as broken in Studio, on a test account,
				for a reason that had nothing to do with the Starter Pack.
			]]
			local okOwn, state = pcall(PetServer.get, player)
			local owned = (okOwn and type(state) == "table" and state.owned) or {}
			for _, petId in ipairs(ids) do
				if (owned[petId] or 0) <= 0 then
					local okG, got = pcall(PetServer.grant, player, petId)
					if okG and got then
						pets += 1
					end
				end
			end
		else
			warn("[DevGrant] PetServer would not load; no pets granted")
		end
	end

	--[[
		LAST, and after the coin write above -- otherwise the pack's 20,000 lands
		inside the balance this script then overwrites with COINS, and the whole
		grant is invisible. Here the counter reads COINS + 20,000, which is the
		proof the pack paid.
	]]
	local SSS = game:GetService("ServerScriptService")
	local okP, PassConfig = pcall(require,
		game:GetService("ReplicatedStorage").Modules.PassConfig)

	--[[
		THE CLAIM IS CLEARED ON EVERY JOIN, whether or not the passes are being
		handed over. The pack is once per account, so without this the second Play
		test onwards is a no-op that looks exactly like a bug -- and the shop reads
		CLAIMED before you have pressed anything.
	]]
	if okP then
		local okS, SaveService = pcall(require, SSS:WaitForChild("SaveService", 10))
		if okS and type(SaveService) == "table" and SaveService.clearOneTimeFlag then
			pcall(SaveService.clearOneTimeFlag, player, "starterPackClaimed")
		end
		player:SetAttribute(PassConfig.ClaimedAttribute, nil)
	end

	local passes = 0
	if GRANT_PASSES and okP then
		local okG, GamePassService = pcall(require, SSS:WaitForChild("GamePassService", 10))
		if okG and type(GamePassService) == "table" and GamePassService.setOwnedForTesting then
			for _, entry in PassConfig.all() do
				if GamePassService.setOwnedForTesting(player, entry.id) then
					passes += 1
				end
			end
		else
			warn("[DevGrant] GamePassService would not load; no passes granted")
		end
	end

	print(string.format("[DevGrant] starter pack claim cleared; %d pass(es) marked owned (GRANT_PASSES=%s) -- STUDIO ONLY",
		passes, tostring(GRANT_PASSES)))
	-- Only when there is an account to describe. With ENABLED off this hook has
	-- written no coins, no rebirths and no levels, and printing the dials anyway
	-- would report a maxed account that does not exist.
	if ENABLED then
		print(string.format(
			"[DevGrant] %s: $%d, %d rebirths, AtvTier %s, all tracks %s, Lv_BucketSize %s, car %s, %d pets -- STUDIO ONLY",
			player.Name, COINS, REBIRTHS,
			tostring(player:GetAttribute("AtvTier")), tostring(ALL_TRACK_LEVEL),
			tostring(player:GetAttribute("Lv_BucketSize")), tostring(CAR_LEVEL), pets))
		print(string.format(
			"[DevGrant] derived: SellMultiplier %s, RollerWidth %s, PetLuck %s",
			tostring(player:GetAttribute("SellMultiplier")),
			tostring(player:GetAttribute("RollerWidth")),
			tostring(player:GetAttribute("PetLuck"))))
	else
		print(string.format("[DevGrant] %s: passes only -- account left untouched "
			.. "(ENABLED=false) -- STUDIO ONLY", player.Name))
	end
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(grant, player)
end)

-- Whoever is already here. In Play Solo that is normally the local player, who
-- joins before this script runs.
for _, player in Players:GetPlayers() do
	task.spawn(grant, player)
end
