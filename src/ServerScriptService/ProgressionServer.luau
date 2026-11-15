--[[
	ProgressionServer  --  ServerScriptService.ProgressionServer

	Owns upgrade levels, rebirth count, and every effect they produce.

	THE ONE RULE
	------------
	The client sends a track KEY ("BucketSize") and nothing else. It never sends
	a level, a price, or an effect value. The server looks up the player's
	current level, looks up the cost for the NEXT level, checks the balance, and
	only then increments. There is no number in the payload to tamper with, and
	no path where a client-supplied value reaches an effect.

	Rebirth takes no payload at all -- every precondition is server state.

	WHERE THE LEVELS LIVE
	---------------------
	Player attributes (`Lv_BucketSize`, `Rebirths`), mirroring how Clean the
	Beach already stores RollerLevel. That makes them readable by the client for
	free (which is fine -- knowing your own level buys nothing) and trivially
	restorable from a DataStore later: one SetAttribute per track.

	APPLYING EFFECTS
	----------------
	applyAll() is the single place effects reach the game, and it is called
	after every purchase, every rebirth, and every spawn. Nothing else writes
	WalkSpeed, capacity or pressure -- so there is exactly one answer to "why is
	this player fast", and respawning cannot silently drop an upgrade.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Config = require(Modules:WaitForChild("ProgressionConfig"))
-- The SECOND ladder this module sells: AtvConfig.Upgrades, the car rake. It
-- lives over there because it obeys the vehicle's rules rather than this file's
-- -- no tide ceiling, and it survives a rebirth -- and that module's header
-- argues the case. It used to survive "exactly as the machine itself does";
-- since 2026-08-24 the machine does NOT (onRebirth wipes AtvTier unless a game
-- pass backs it), so the rake now outlives the thing it bolts to. Pure data with no server
-- dependencies, so requiring it here is not a cycle: AtvConfig reaches only for
-- ProgressionConfig, and only lazily.
local AtvConfig = require(ReplicatedStorage:WaitForChild("AtvConfig"))
local PassConfig = require(Modules:WaitForChild("PassConfig"))
-- The Quick Upgrade developer product: its id, and whether it is a real product
-- yet. Pure replicated data with no server dependencies, so requiring it here
-- adds nothing to this module's boot order. ProductServer calls BACK into this
-- module to honour a receipt -- see grantQuickUpgrade -- and that direction is
-- the only one: nothing here requires ProductServer.
local ProductConfig = require(Modules:WaitForChild("ProductConfig"))
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local InventoryController = require(Modules:WaitForChild("InventoryController"))
-- For the name of the lifetime litter counter and nothing else. The rebirth
-- gate below is measured off the same attribute the MOST TRASH board ranks, so
-- the two can never disagree about what "picked up" means.
local LeaderboardConfig = require(Modules:WaitForChild("LeaderboardConfig"))
local Net = require(Modules:WaitForChild("Net"))
--[[
	THE ONBOARDING'S ONE-PURCHASE RULE. Pure replicated data with no requires of
	its own, so it adds nothing to this module's boot order -- the same reason
	SaveService is willing to hold it. Its own header carries the argument for
	why the first purchase is steered rather than merely suggested.
]]
local TutorialConfig = require(Modules:WaitForChild("TutorialConfig"))
-- Pure replicated data and arithmetic -- no service, no remote, nothing that
-- starts. Required for liveHoldCap() alone, which applyAll takes as a floor so
-- a purchase cannot cancel a live Scrap Rush. Requiring EventService here
-- instead would invert ServerMain's boot order: that starts at step 15, this at
-- step 8, and the event module already requires SellServer.
local EventConfig = require(Modules:WaitForChild("EventConfig"))

local SellServer = require(script.Parent:WaitForChild("SellServer"))
local GamePassService = require(script.Parent:WaitForChild("GamePassService"))
-- Only to ASK whether a player is out on the Long Shore -- see the gate at the
-- top of onRebirth. The bus requires nothing itself and answers false until
-- AfkService has registered with it, so this cannot tangle the boot order.
local AfkBus = require(script.Parent:WaitForChild("AfkBus"))

local ProgressionServer = {}

local lastAction = {} -- [Player] = os.clock(), a cheap anti-spam gate

--[[
	THE MOST RUNGS ONE PRESS MAY BUY. The shop offers x1, x5, x10 and x25; this
	is the ceiling the server holds whatever the client asks for.

	It is a LOOP BOUND, not a spending limit -- onBuy re-reads the price, the tide
	ceiling and the coin balance on every rung, so a hundred here could not buy
	anything twenty-five could not. Bounded because an unbounded number off the
	wire is a loop somebody else decides the length of.
]]
local BULK_MAX = 25

-- The weight system owns carry capacity. Resolved lazily and optionally, the
-- same way CTBBridge reaches it, so this module still runs in a place where it
-- is not installed.
local weightLoaded = false
local WeightService = nil

local function weightSystem()
	if weightLoaded then
		return WeightService
	end
	weightLoaded = true
	local folder = script.Parent:FindFirstChild("WeightSystem")
	local service = folder and folder:FindFirstChild("WeightService")
	if not (service and service:IsA("ModuleScript")) then
		return nil
	end
	local ok, result = pcall(require, service)
	if ok and type(result) == "table" and type(result.setMaxWeight) == "function" then
		WeightService = result
	elseif not ok then
		warn("[ProgressionServer] weight system present but would not load:", result)
	end
	return WeightService
end

local function attrName(key: string): string
	return "Lv_" .. key
end

function ProgressionServer.levelOf(player: Player, key: string): number
	local v = player:GetAttribute(attrName(key))
	if type(v) ~= "number" then
		return 1
	end
	return math.clamp(math.floor(v), 1, Config.MaxLevel)
end

function ProgressionServer.rebirthsOf(player: Player): number
	local v = player:GetAttribute("Rebirths")
	return (type(v) == "number") and math.max(0, math.floor(v)) or 0
end

--[[
	WHAT THE REBIRTH GATE MEASURES: earnings THIS TIDE, not lifetime.

	It used to be `TotalEarned`, which is never reset -- so the ladder quietly
	discounted itself. Rebirth 1 wants 2,500 and rebirth 2 wants 4,625, but a
	player arriving at rebirth 2 already had 2,500 banked in the same counter, so
	the SECOND tide only cost 2,125 of actual work -- less than the first. By
	rebirth 5 the incremental cost is under half the printed number, and the
	panel's progress bar starts every run most of the way full, which reads as a
	bug on its own.

	`TideEarned` resets to zero on every rebirth, so the number on the panel is
	the number you have to go and earn. `TotalEarned` is kept and still
	accumulates -- it is a genuine lifetime stat, it is just not the gate.
]]
function ProgressionServer.tideEarnedOf(player: Player): number
	local v = player:GetAttribute("TideEarned")
	if type(v) == "number" then
		return math.max(0, v)
	end
	-- Nothing has written one yet: an existing player mid-run should not be sent
	-- back to zero by the introduction of this attribute, so seed it from the
	-- lifetime figure the gate used to read.
	return math.max(0, player:GetAttribute("TotalEarned") or 0)
end

--[[
	PIECES OF LITTER PICKED UP THIS TIDE -- the gate's second counter.

	DERIVED, NOT COUNTED SEPARATELY. `TrashPicked` is already on the player: a
	lifetime total, incremented at the only two places litter changes hands
	(CTBBridge's field pickups and TrashCollectionService's tagged props) and
	saved with everything else. Subtracting a mark laid down at the last rebirth
	gives this tide's figure for free -- and, more usefully, means any pickup
	path added later is counted here the moment it bumps that counter, with
	nothing to remember to wire up.

	THE LIFETIME COUNTER IS UNTOUCHED, which its own note in LeaderboardConfig
	insists on: a rebirth takes back coins, levels and the machine, but not the
	record of work done, and a MOST TRASH board that reset every tide would rank
	nobody but the players who had not rebirthed lately.

	NO MARK MEANS ZERO, NOT "START COUNTING NOW". A player already halfway
	through a tide when this gate arrives has a lifetime figure and no mark, and
	the generous reading credits all of it to the run they are in. That is the
	same call tideEarnedOf makes above and for the same reason: introducing a
	gate must never move somebody backwards on a tide they have already worked.
	It is generous exactly once -- the next rebirth lays the mark down properly.
]]
function ProgressionServer.tideTrashOf(player: Player): number
	local lifetime = tonumber(player:GetAttribute(LeaderboardConfig.TrashAttribute)) or 0
	local mark = tonumber(player:GetAttribute("TideTrashBase")) or 0
	return math.max(0, math.floor(lifetime - mark))
end

-- Ceiling rises with rebirths, so a track is "maxed" relative to your run.
function ProgressionServer.ceilingFor(player: Player): number
	return Config.Rebirth.levelCeiling(ProgressionServer.rebirthsOf(player))
end

function ProgressionServer.effectOf(player: Player, key: string): number
	local track = Config.TrackByKey[key]
	return track.effect(ProgressionServer.levelOf(player, key))
end

--------------------------------------------------------------------------
-- APPLYING EFFECTS
--------------------------------------------------------------------------

function ProgressionServer.applyAll(player: Player)
	-- Bucket -> carry capacity, which is WEIGHT and belongs to WeightService.
	--
	-- This used to write inv:SetMaxCapacity, i.e. a SLOT count. The weight
	-- system lifts that cap to 9999 on purpose so weight is the only limit, and
	-- re-imposing it here put the old limit back -- on join, on every respawn
	-- and after every purchase, whichever ran last. The visible symptom was a
	-- bag reporting full at 13 / 20 lbs, at a different number each time.
	--
	-- Falls back to slots only where the weight system is not installed.
	local bucket = ProgressionServer.effectOf(player, "BucketSize")
	--[[
		THE TUTORIAL'S SMALL BAG, CLAMPED AT THE SOURCE.

		TutorialServer sets the six-pound bag the moment it arms -- but THIS
		function re-derives capacity from the Bucket Size track on every join,
		purchase, respawn and rebirth, and a clamp that lives anywhere else is
		a clamp this line steamrolls at the next of those (measured: the first
		sell put the twelve-pound bag back mid-onboarding). So the armed
		tutorial caps the number HERE, where it is born. The credit attribute
		is the armed flag; finish() clears it, and the next derive -- which the
		finishing purchase itself triggers -- hands the ladder back.
	]]
	if player:GetAttribute(TutorialConfig.LumpsAttribute) ~= nil then
		bucket = math.min(bucket, TutorialConfig.BagCap)
	else
		--[[
			SCRAP RUSH'S LIFTED BAG, RE-ASSERTED RATHER THAN STEAMROLLED.

			This line re-derives capacity from the ladder on every purchase,
			respawn and rebirth -- exactly the property the clamp above exists to
			defend against -- and while the no-limit event is live that derive was
			putting the normal limit BACK. EventService lifts the bag at `start`
			and only restores it at `stop`, so a player who bought a Bucket Size
			rung mid-event lost the event for the rest of its run. Reported from
			the game on 2026-09-09.

			A FLOOR, so it can only ever help: a bag that has genuinely outgrown
			the event cap keeps its own, larger number. That is the same rule
			EventService's restore follows, and it is why buying two rungs during
			an event still leaves you holding both when it ends.

			IN THE `else`, so the tutorial's six-pound bag still wins outright.
			The onboarding's whole first-bag arithmetic is pitched against that
			number (see TutorialConfig.BagCap), and a first-timer whose bag
			silently became forty thousand pounds for a minute would finish the
			tutorial and watch it shrink -- which is the failure EventService's
			header already names as the reason the BANNER is withheld from them.

			WeightService.applyCapacity carries the same floor, because the
			Lv_BucketSize attribute signal re-derives capacity there too and either
			one landing last would undo the other.
		]]
		local lifted = EventConfig.liveHoldCap()
		if lifted then
			bucket = math.max(bucket, lifted)
		end
	end
	local weight = weightSystem()
	if weight then
		weight.setMaxWeight(player, bucket)
	else
		local inv = InventoryController.Server.find(player)
		if inv then
			inv:SetMaxCapacity(bucket)
		end
	end

	--[[
		Legs -> Humanoid. Re-applied on every spawn because a fresh character
		comes back at StarterPlayer.CharacterWalkSpeed -- the level-1 floor, 24 --
		and not at the level this player has bought.

		AND PUBLISHED AS AN ATTRIBUTE, which is the part that is not decoration.
		This module owns WalkSpeed, but it is not the only thing that WRITES it:
		the idle shore's puppet, the duel count-in and the intro camera all drive
		the humanoid down and then have to hand it back, and the number they have
		to hand back is this one. Until now the only way to ask for it was to be
		on the server, so the one that could not -- AfkClient -- guessed, and its
		guess was the shore's own 10. Every player came back off the shore
		permanently slow.

		Written even when there is no character to write it to, so the answer is
		always readable rather than only while somebody is alive.
	]]
	local legs = ProgressionServer.effectOf(player, "BeachLegs")
	player:SetAttribute("BaseWalkSpeed", legs)

	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then
		hum.WalkSpeed = legs
	end

	-- Pressure -> the attributes WashServer and the jet already read.
	--
	-- All FOUR are written, not just the two the maths needs. WasherTool sets the
	-- full set once on join and this used to overwrite only Pressure and Level,
	-- so after any purchase the player's washer got stronger while the HUD went
	-- on calling it a "Garden Hose" for the rest of the run -- the only place the
	-- upgrade is visible while you are actually using it.
	local level = ProgressionServer.levelOf(player, "Pressure")
	local psi = ProgressionServer.effectOf(player, "Pressure")
	player:SetAttribute("WasherPressure", psi)
	player:SetAttribute("WasherLevel", level)

	--[[
		SPREAD ACROSS THE LADDER, not indexed by it.

		This used to be `tiers[clamp(level, 1, #tiers)]`, which was right while
		both ladders had six rungs and is badly wrong now that this one has
		sixty. Clamping would have handed every player from level 12 upward the
		same "Leviathan Cannon" for the remaining forty-eight levels -- the
		name on the tool is the only place the upgrade is visible WHILE YOU ARE
		USING IT, and it would have stopped moving one fifth of the way up.

		So the label list is stretched over MaxLevel instead: twelve names over
		sixty levels is a new one every five. Add or remove a label in
		GameConfig and the spacing re-derives itself; neither file needs to know
		how long the other one is.
	]]
	local tiers = GameConfig.Washer.Levels
	local span = Config.MaxLevel / #tiers
	local tier = tiers[math.clamp(math.ceil(level / span), 1, #tiers)]
	if tier then
		player:SetAttribute("WasherSpread", tier.spread)
		player:SetAttribute("WasherLabel", tier.label)
	end

	-- Sifter width -> CTB's own attributes, so its beach sifter picks it up with
	-- no changes on their side.
	player:SetAttribute("RollerLevel", ProgressionServer.levelOf(player, "RollerWidth"))
	player:SetAttribute("RollerWidth", ProgressionServer.effectOf(player, "RollerWidth"))

	-- Luck + sell multiplier are read where they are used.
	-- TideLuck is gone. The track was removed from ProgressionConfig (see the
	-- note in its header): it wrote this attribute on every apply and nothing
	-- anywhere read it, so it sold up to 4,200 coins of nothing. Luck is a pet
	-- stat now -- PetServer writes PetLuck, LuckService spends it at the bay.
	-- effectOf looks the key up in Config.TrackByKey and calls track.effect
	-- without checking, so the write had to go with the track: left behind for
	-- a key that is gone it is a hard error on apply, not a nil attribute.
	player:SetAttribute("SellMultiplier",
		Config.Rebirth.multiplier(ProgressionServer.rebirthsOf(player)))

	-- Magnet, Haggle, Prospect and GearLuck were removed from
	-- ProgressionConfig, so MagnetRange, HaggleBonus, ProspectBonus and
	-- GearLuck are no longer written here; each consumer is back to the
	-- constant it used before those tracks existed. The writes had to go with
	-- the tracks for the same reason the TideLuck line did: effectOf looks the
	-- key up in Config.TrackByKey and calls track.effect without checking, so a
	-- write left behind for a key that is gone is a hard error on join, on
	-- every purchase, on every respawn and on every rebirth.
	--
	-- The rule those four were added under outlives them. Every track must
	-- write an attribute a NAMED consumer reads; one that does not is a number
	-- the shop charges for and the game ignores.

	--[[
		THE CAR LADDER IS DELIBERATELY NOT APPLIED HERE, and it is the one place
		this module departs from "applyAll is where effects reach the game".

		Its consumer is a MACHINE, and most of the time there is not one -- the
		player is on foot, or has never spawned theirs, or is stood next to it with
		the engine off. There is no attribute on the Player that applyAll could
		write which anything would read.

		What does read it is AtvConfig.effectiveStats, and what re-runs that is
		AtvServer.applyStats -- already watching every attribute
		AtvConfig.transferAttributes() names, and that list now includes the car
		ladder's. So the SetAttribute in onBuyCar IS the apply, and it reaches a
		moving machine on the next frame.

		The rule above still holds, then: the track writes an attribute a named
		consumer reads. The consumer simply is not in this file.
	]]
end

--------------------------------------------------------------------------
-- SNAPSHOT  (what the panel draws)
--------------------------------------------------------------------------

function ProgressionServer.snapshot(player: Player)
	local ceiling = ProgressionServer.ceilingFor(player)
	local tracks = {}
	for _, t in Config.Tracks do
		local lv = ProgressionServer.levelOf(player, t.key)
		local capped = lv >= ceiling

		--[[
			A GAME PASS CAN FINISH A TRACK WITHOUT BUYING A SINGLE RUNG OF IT.

			Instant Wash removes the wash timer outright -- every clump comes off
			on contact whether the player uses the button or the jet -- so every
			rung of Water Pressure is worth exactly nothing to a holder. Left
			alone, the shop would go on selling sixty of them, each one a real
			price for a change the player cannot feel.

			IT IS A THIRD KIND OF DEAD END and the panel draws it as one, because
			it is neither of the other two: not the tide cap (which lifts when you
			rebirth) and not the top of the ladder (which they climbed). `maxed`
			carries it too, so anything that only knows the old field still stops
			offering the row rather than falling through to a price.

			AND THE PLAYER'S LEVEL IS NOT TOUCHED. See PassConfig.supersederOf: a
			pass that stamped Lv_Pressure to the ceiling would be indistinguishable
			in the save file from sixty real purchases, with no way back if the
			track is ever rebalanced or removed. `level` below is still theirs.
		]]
		local pass = PassConfig.supersederOf(t.key)
		local byPass = pass ~= nil and GamePassService.ownsPassId(player, pass.id)
		local sellable = not capped and not byPass

		table.insert(tracks, {
			key = t.key,
			level = lv,
			ceiling = ceiling,
			value = t.effect(lv),
			nextValue = sellable and t.effect(lv + 1) or nil,
			cost = sellable and Config.costFor(t, lv) or nil,
			maxed = capped or byPass,
			-- Both nil for every track no pass covers, which is all of them but one.
			passMaxed = byPass and pass.name or nil,
			passNote = byPass and pass.supersededNote or nil,
		})
	end

	--[[
		THE CAR TAB'S HALF OF THE SNAPSHOT.

		One panel, one snapshot, one push. The Beach Shop's Car tab could have had
		a sync of its own -- it is a different ladder with different rules -- and
		that would have been two copies of the balance, two arrival times and two
		chances for the panel to draw a price the server has already moved past.
		The shop's own header records that exact bug being removed once already
		(the panel drew a COPY of `coins` and painted rows red for prices the
		player could afford).

		`owned` IS THE LOCK, and it is answered here rather than by the client
		reading AtvTier for itself -- not because the client cannot be trusted
		with it (it can: the tab only draws, and onBuyCar re-asks), but because
		the question "do you own a machine" has one definition, in AtvConfig, and
		a second reading of the raw attribute in MenuHud would be the third copy.

		`floor` is the walker's own maxed Sifter Width. The panel needs it to say
		what the first rung is FOR -- a rake that starts where the foot ladder
		ends is the whole pitch, and a row that just says "50.5 studs" does not
		make that argument.
	]]
	local ownedMachine = AtvConfig.ownedTier(player)
	local carTracks = {}
	for _, t in AtvConfig.Upgrades do
		local lv = AtvConfig.carLevelOf(player, t.key)
		-- The TRACK's ceiling, not the ladder's. These two read CarMaxLevel direct
		-- until 2026-09-18, which was the same answer while the rake was the only
		-- track and the wrong one the moment a shorter one was added beside it --
		-- the shop would have drawn LV 20 MAX and this snapshot would have gone on
		-- quoting a price for rung 21. See AtvConfig.carCeiling.
		local ceiling = AtvConfig.carCeiling(t)
		local capped = lv >= ceiling
		table.insert(carTracks, {
			key = t.key,
			level = lv,
			ceiling = ceiling,
			-- NIL at level 0, not the level-0 number: nothing is fitted, and a
			-- width printed for a rake that is not on the machine is a lie the
			-- player would go looking for.
			value = (lv > 0) and t.effect(lv) or nil,
			nextValue = (not capped) and t.effect(lv + 1) or nil,
			cost = (not capped) and AtvConfig.carCostFor(t, lv) or nil,
			maxed = capped,
		})
	end

	local n = ProgressionServer.rebirthsOf(player)
	local earned = ProgressionServer.tideEarnedOf(player)
	local need = Config.Rebirth.requirement(n + 1)
	local trash = ProgressionServer.tideTrashOf(player)
	local trashNeed = Config.Rebirth.litterRequirement(n + 1)
	return {
		tracks = tracks,
		car = {
			owned = ownedMachine ~= nil,
			machine = ownedMachine and ownedMachine.name or nil,
			floor = AtvConfig.walkerSifterCeiling(),
			--[[
				WHAT THE FOOT LADDER IS ALREADY WORTH ON THIS MACHINE.  2026-09-18.

				`floor` above tells the panel what the RAKE is for. This tells it what
				the player's existing Beach Legs and Bucket Size are doing to the
				machine right now, which is the other half of the same argument and was
				nowhere on the tab.

				READ OFF Transfers RATHER THAN NAMING THE TRACKS, so this stays correct
				if a transfer is ever re-pointed at a different track. The machine's OWN
				two numbers travel with them because the panel has to say either "your
				gear is carrying this" or "it will once it passes these", and it cannot
				tell which without both sides of the max().

				The foot values are read straight rather than through effectiveStats on
				purpose: that function's `hold` now carries the Cargo Bed's addition on
				top, and a sentence crediting Bucket Size for a bed the player bought
				separately would be the exact kind of quiet lie this is fixing.
			]]
			lift = ownedMachine and {
				speed = Config.valueOf(player, AtvConfig.Transfers.speed),
				hold = Config.valueOf(player, AtvConfig.Transfers.hold),
				ownSpeed = ownedMachine.speed or 0,
				ownHold = AtvConfig.holdOf(ownedMachine),
			} or nil,
			tracks = carTracks,
		},
		coins = SellServer.getCoins(player),
		rebirths = n,
		multiplier = Config.Rebirth.multiplier(n),
		nextMultiplier = Config.Rebirth.multiplier(n + 1),
		-- THIS TIDE's earnings, not the lifetime figure. The panel draws a
		-- "x / y EARNED" bar off it, and a lifetime number made that bar start
		-- each run already most of the way full.
		totalEarned = earned,
		lifetimeEarned = player:GetAttribute("TotalEarned") or 0,
		rebirthNeed = need,
		-- THE SECOND GATE. Same shape as the pair above it: what this tide has
		-- done, and what it has to do. See ProgressionConfig's litter block for
		-- why a coin gate on its own does not ask anybody to clean a beach.
		tideTrash = trash,
		rebirthTrashNeed = trashNeed,
		-- THE TWO GATES AND NOTHING ELSE. There used to be a third term here,
		-- `n < MaxRebirths`, and the ladder has no top any more -- see
		-- ProgressionConfig.Rebirth.LadderTides. A player who has earned it can
		-- always turn the tide again.
		canRebirth = (earned >= need) and (trash >= trashNeed),
	}
end

function ProgressionServer.push(player: Player)
	Net.get("ProgressionSync"):FireClient(player, ProgressionServer.snapshot(player))
end

--------------------------------------------------------------------------
-- PURCHASE
--------------------------------------------------------------------------

--[[
	`needCoins` IS THE SHORTFALL, and only a genuine affordability refusal ever
	sets it. MenuHud listens on this same remote for it and opens the Robux shop
	at the coin packs; FeedbackClient draws the toast either way, so a message
	carrying it is still an ordinary message. See the long note in MenuHud.start
	for why this is a number on the payload rather than a phrase in the text.
]]
local function notify(player, text, kind, needCoins)
	Net.get("Notify"):FireClient(player, {
		text = text,
		kind = kind or "info",
		needCoins = needCoins,
	})
end

local function onBuy(player: Player, payload)
	if type(payload) ~= "table" then
		return
	end
	local key = payload.track
	-- A key, and only a key. Anything else about the purchase is server state.
	if type(key) ~= "string" then
		return
	end
	local track = Config.TrackByKey[key]
	if not track then
		return
	end

	--[[
		HOW MANY RUNGS. Absent or junk reads as one, so a client from before the
		multiplier existed keeps working exactly as it did.

		CAPPED AT BULK_MAX here rather than trusted: the panel offers 1, 5, 10 and
		25, and this is the only place that decides what a number off the wire may
		mean. The loop below re-reads coins and the ceiling on every rung anyway,
		so a larger number could not overspend -- but it could sit in a loop for a
		while, and that is reason enough to bound it.
	]]
	local want = math.floor(tonumber(payload.count) or 1)
	if want ~= want or want < 1 then
		want = 1
	end
	want = math.min(want, BULK_MAX)

	local now = os.clock()
	if now - (lastAction[player] or -math.huge) < 0.15 then
		return
	end
	lastAction[player] = now

	--[[
		REFUSED WHILE THE TUTORIAL IS STILL ASKING FOR THE FIRST ROW.

		The card's last step names Sifter Width and completes when that track's
		level moves. A player who spends their first bagful on Bucket Size
		instead is left looking at a card pointing at a row they can no longer
		afford, with no way out but earning the money twice -- so the shop sells
		one row until that row is bought. footRefusal says the same thing to the
		Robux path; this is the coin door.
	]]
	if key ~= TutorialConfig.FirstTrack then
		local first = Config.TrackByKey[TutorialConfig.FirstTrack]
		if first and TutorialConfig.locksOtherTracks(player,
			player:GetAttribute(attrName(TutorialConfig.FirstTrack))) then
			notify(player, string.format("Buy %s first \u{2014} the tutorial is showing you how.",
				first.name), "warn")
			return
		end
	end

	--[[
		REFUSED BECAUSE A PASS ALREADY COVERS IT -- and this guard is about the
		player's MONEY, not about trust.

		The shop draws that row dead, so nothing in the panel can send this. What
		can is a panel that was already open across the moment the pass resolved
		(ownership is a web call and lands whenever it lands), and the cost of
		letting it through is taking real coins for a rung the buyer will not be
		able to feel. Checked BEFORE the ceiling, so a holder gets the true reason
		rather than "maxed for this tide".
	]]
	local pass = PassConfig.supersederOf(key)
	if pass and GamePassService.ownsPassId(player, pass.id) then
		notify(player, string.format("%s already covers %s \u{2014} save your coins.",
			pass.name, track.name), "info")
		return
	end

	--[[
		N RUNGS, AND IT IS THE SAME PURCHASE N TIMES.
		Asked for on 2026-09-14: "incremental upgrades (x5, x10, x20, etc)".

		EVERY GATE IS RE-RUN PER RUNG rather than a total being worked out up front
		and charged once, and that is the whole safety argument. The price climbs
		1.24x a level, so a precomputed total is wrong the moment the first one
		lands; the tide ceiling can be reached halfway through the order; and the
		coin balance has to be re-read because a sale can settle mid-loop. Ten rungs
		here is exactly ten presses of the button, so there is no way to spend money
		a single buy did not already have.

		IT STOPS AT THE FIRST REFUSAL rather than skipping past it. Every reason a
		rung can be refused is monotonic -- maxed for this tide, fully upgraded, not
		enough coins -- so if this rung is refused the next one, which is dearer, is
		too. There is nothing to be gained by carrying on and the player keeps the
		coins.

		THE TWO GUARDS ABOVE STAY OUT OF THE LOOP, deliberately. The tutorial lock
		and the pass-supersedes check give the same answer for every rung of one
		track within one call, and re-asking GamePassService per level would put a
		web call inside a loop.
	]]
	local bought, stopped = 0, nil
	for _ = 1, want do
		local level = ProgressionServer.levelOf(player, key)
		if level >= ProgressionServer.ceilingFor(player) then
			stopped = track.name .. " is maxed for this tide."
			break
		end

		local cost = Config.costFor(track, level)
		if not cost then
			stopped = track.name .. " is fully upgraded!"
			break
		end

		local coins = SellServer.getCoins(player)
		if coins < cost then
			stopped = string.format("Need %d more for %s", cost - coins, track.name)
			break
		end

		SellServer.addCoins(player, -cost, "upgrade")
		player:SetAttribute(attrName(key), level + 1)
		bought += 1
	end

	--[[
		APPLIED AND PUSHED ONCE, AFTER THE WHOLE ORDER.

		applyAll re-derives every downstream attribute off the stored levels and
		push rebuilds the panel's snapshot. Both are idempotent and neither needs to
		have run for the rungs in between, so doing them inside the loop bought ten
		full re-derives for a x10 and told the client about nine states nobody saw.

		ONE TOAST, for the same reason. Ten "Sifter Width -> Level 31!" lines in a
		single frame is the interruption complaint this game has already had once.
	]]
	if bought > 0 then
		ProgressionServer.applyAll(player)
		ProgressionServer.push(player)
		local level = ProgressionServer.levelOf(player, key)
		notify(player, (bought == 1)
			and string.format("%s -> Level %d!", track.name, level)
			or string.format("%s x%d -> Level %d!", track.name, bought, level), "pickup")
		-- To the buyer only. An upgrade is personal progress, and this used to fire at
		-- everyone -- so a bystander saw a burst go off for a level they had not bought.
		Net.get("Fx"):FireClient(player, { kind = "Upgrade", part = ProgressionServer.fxAnchor })
	end

	-- Why the order ended early, and only when it actually ended early: an x10
	-- that bought all ten has nothing to explain.
	if stopped and bought < want then
		notify(player, stopped, "warn")
	end
end

--------------------------------------------------------------------------
-- PURCHASE  --  THE CAR LADDER
--------------------------------------------------------------------------
--[[
	SAME CONTRACT AS onBuy: a track KEY and nothing else. The level, the price
	and the ownership are all server state and all re-derived here.

	A SEPARATE HANDLER RATHER THAN A FLAG ON onBuy, because three of its rules
	are different and every one of them is a way to lose money:

		the ladders are 0-BASED vs 1-BASED  -- carLevelOf's own note says why
		there is NO TIDE CEILING here       -- onBuy's first gate does not apply
		the PRICE CURVE is AtvConfig's      -- Config.costFor would sell a rung
		                                       of a two-billion-coin ladder for
		                                       seventy coins

	A handler that branched on the payload would be one `if` away from each of
	those, and the failure is silent in the direction that costs the game money.

	IT SHARES `lastAction` WITH onBuy ON PURPOSE. The gate is anti-spam on the
	player, not on the button, and two separate clocks would let a client
	alternate the two remotes to double the rate through both.
]]
local function onBuyCar(player: Player, payload)
	if type(payload) ~= "table" then
		return
	end
	local key = payload.track
	if type(key) ~= "string" then
		return
	end
	local track = AtvConfig.UpgradeByKey[key]
	if not track then
		return
	end

	local now = os.clock()
	if now - (lastAction[player] or -math.huge) < 0.15 then
		return
	end
	lastAction[player] = now

	--[[
		THE LOCK, AND IT IS ENFORCED HERE RATHER THAN BY THE TAB.

		MenuHud greys the Car tab when you own nothing, and that is a courtesy to
		the player, not a gate -- a client can fire this remote whenever it likes.
		This is the gate. It reads the same AtvConfig.ownsMachine the panel draws
		from, so there is exactly one definition of owning a machine and the tab
		cannot come to a different answer than the till.

		A game pass passes it for free and correctly: a pass writes its tier into
		AtvTier, so anything phrased in terms of that attribute already covers it.
	]]
	if not AtvConfig.ownsMachine(player) then
		notify(player, "Buy a machine at the car pad first.", "warn")
		return
	end

	local level = AtvConfig.carLevelOf(player, key)
	local cost = AtvConfig.carCostFor(track, level)
	if not cost then
		notify(player, track.name .. " is fully upgraded!", "warn")
		return
	end

	local coins = SellServer.getCoins(player)
	if coins < cost then
		notify(player, string.format("Need %d more for %s", cost - coins, track.name), "warn")
		return
	end

	-- Through the one grant path, so lifetime earnings, the panel push and
	-- SaveService's dirty flag all see the spend. A raw attribute write here
	-- would leave a two-billion-coin purchase unsaved until the next heartbeat.
	SellServer.addCoins(player, -cost, "carupgrade")
	--[[
		AND THIS LINE IS THE APPLY. See the note at the foot of applyAll: the
		consumer is a machine that may not exist, and AtvServer.applyStats is
		already watching this exact attribute through
		AtvConfig.transferAttributes(). So a rung bought from the driving seat
		widens the band and re-welds the rake on the next frame, and a rung bought
		on foot is waiting on the machine when it is next spawned.
	]]
	player:SetAttribute(AtvConfig.CarAttrPrefix .. key, level + 1)
	ProgressionServer.push(player)

	notify(player, string.format("%s -> %d studs!", track.name,
		math.floor(track.effect(level + 1) + 0.5)), "pickup")
	Net.get("Fx"):FireClient(player, { kind = "Upgrade", part = ProgressionServer.fxAnchor })
end

--------------------------------------------------------------------------
-- QUICK UPGRADE  --  THE SAME RUNG, PAID FOR IN ROBUX
--------------------------------------------------------------------------
--[[
	AN ALTERNATIVE PAYMENT, NOT A SHORTCUT PAST ANYTHING. That sentence is the
	whole feature and it is the thing to defend if any of this is changed.

	Every refusal onBuy makes, this makes too: the tide ceiling, the top of the
	ladder, the pass that supersedes a track, the machine lock on the car ladder.
	A player stopped at this tide's cap is stopped for Robux exactly as they are
	for coins. The ceiling is what paces the entire game -- ProgressionConfig's
	note on levelCeiling says so at length -- and the one thing that must not be
	sold is the pacing.

	What it removes is the EARNING, which is the part a player is entitled to skip
	with money.

	WHY IT TAKES TWO MESSAGES AND A RECORDED INTENT
	-----------------------------------------------
	A developer product receipt names a PRODUCT and a PLAYER. There is ONE Quick
	Upgrade product for every rung on both ladders, so by the time ProcessReceipt
	runs, nothing in the receipt says which rung was meant. It has to have been
	written down before the Robux moved.

	So the button does not buy anything. QuickUpgrade ASKS; this module re-derives
	the level, the ceiling and every refusal for itself, records the intent only if
	the rung is genuinely for sale, and fires QuickUpgradePrompt back. The client
	opens the dialog on that, and only on that -- so a refusal costs a toast rather
	than a Robux dialog that could not have paid for anything.

	It is the same shape as EggMenu/EggBuy, for the same reason, and Net's own
	note on this pair records it.

	THE INTENT IS NOT PROOF OF ANYTHING AND IS NEVER TRUSTED ON ITS OWN. It is a
	PREFERENCE -- "this is the rung they were looking at" -- and the grant
	re-checks every refusal against live state before it honours it. It has to:
	Roblox delivers a receipt whenever it delivers it, and the player may have
	spent the coins, hit the ceiling or had a pass resolve in between.

	AND IT MUST SURVIVE ARRIVING WITH NO INTENT AT ALL. A receipt Roblox re-sends
	to a later session finds a table that was never populated -- the server it was
	recorded on is gone. Refusing there would take the Robux and hand back nothing
	until the player happened to buy again. So a missing or stale intent falls back
	to the CHEAPEST rung the player can actually buy, which is always something
	they wanted and is deterministic enough to explain in a toast.

	The last resort -- nothing anywhere is upgradeable -- returns false, which does
	NOT consume the receipt. Roblox holds it and re-sends, and the next rebirth
	lifts the ceiling and pays it out by itself. That beats consuming a receipt for
	a grant that could not happen, which is unrecoverable; see ProductServer's note
	on the unknown-product branch, which makes the same trade.
]]

--[[
	HOW LONG A RECORDED INTENT IS STILL WORTH HONOURING.

	The ordinary gap between recording one and the receipt landing is however long
	the player looks at Roblox's dialog -- seconds. Fifteen minutes is not a
	timeout for that; it is the point past which "the rung they were looking at"
	has stopped being a fair guess about a session that has moved on, and the
	cheapest-rung fallback is the better answer. It is deliberately generous, since
	the fallback is a fallback rather than a failure.
]]
local QUICK_TTL = 900

-- [Player] = { ladder = "foot" | "car", key = string, at = os.clock() }
--
-- NOT cleared when a purchase is honoured, only when it is replaced, when it
-- goes stale, or when the player leaves. Two Quick Upgrades in a row on the same
-- row is the ordinary way this gets used, and clearing on the first would send
-- the second down the fallback path -- to a DIFFERENT track, on a button the
-- player pressed twice expecting the same one.
local pendingQuick = {}

local function quickProduct()
	return ProductConfig.live(ProductConfig.QuickUpgradeKey)
end

--[[
	nil when the rung is genuinely for sale; otherwise the sentence to say.

	EVERY GATE onBuy HAS, IN THE SAME ORDER AND FOR THE SAME REASONS -- the pass
	before the ceiling so a holder gets the true reason rather than "maxed for this
	tide". Deliberately phrased as a returned STRING rather than a boolean: the two
	callers want the same words (one to toast them, one to decide), and a boolean
	would have meant writing the sentences twice.
]]
local function footRefusal(player: Player, key: string): string?
	local track = Config.TrackByKey[key]
	if not track then
		return "That upgrade does not exist."
	end

	--[[
		ONE ROW IS ON SALE DURING THE TUTORIAL, AND IT IS THE ONE THE CARD NAMES.

		HERE AS WELL AS IN onBuy, because this is the FOOT LADDER'S SHARED
		REFUSAL and the coin path is not its only caller: refusalFor routes the
		Robux quick-upgrade through it, and the buyable-anything probe paints a
		button off it. A rule enforced only in onBuy would leave the other two
		doors open and the shop offering to sell for Robux what it refuses to
		sell for coins.

		THE RAW ATTRIBUTE, NOT levelOf -- see the warning over locksOtherTracks.
	]]
	if key ~= TutorialConfig.FirstTrack then
		local first = Config.TrackByKey[TutorialConfig.FirstTrack]
		if first and TutorialConfig.locksOtherTracks(player,
			player:GetAttribute(attrName(TutorialConfig.FirstTrack))) then
			return string.format("Buy %s first \u{2014} the tutorial is showing you how.",
				first.name)
		end
	end

	local pass = PassConfig.supersederOf(key)
	if pass and GamePassService.ownsPassId(player, pass.id) then
		return string.format("%s already covers %s \u{2014} save your Robux.",
			pass.name, track.name)
	end

	local level = ProgressionServer.levelOf(player, key)
	if level >= ProgressionServer.ceilingFor(player) then
		-- The ceiling is not for sale. See the header.
		return track.name .. " is maxed for this tide \u{2014} turn the tide to raise it."
	end
	if not Config.costFor(track, level) then
		return track.name .. " is fully upgraded!"
	end
	return nil
end

-- The car ladder's rules, which are onBuyCar's: no tide ceiling, no superseding
-- pass, and a machine or nothing.
local function carRefusal(player: Player, key: string): string?
	local track = AtvConfig.UpgradeByKey[key]
	if not track then
		return "That upgrade does not exist."
	end
	if not AtvConfig.ownsMachine(player) then
		return "Buy a machine at the car pad first."
	end
	if not AtvConfig.carCostFor(track, AtvConfig.carLevelOf(player, key)) then
		return track.name .. " is fully upgraded!"
	end
	return nil
end

local function refusalFor(player: Player, ladder: string, key: string): string?
	if ladder == "car" then
		return carRefusal(player, key)
	end
	return footRefusal(player, key)
end

--[[
	ONE RUNG, on whichever ladder. Returns the track's name and its new level so a
	toast can say what was bought without the caller knowing which ladder it was.

	The foot ladder calls applyAll because its consumers are attributes on the
	PLAYER; the car ladder deliberately does not, because the SetAttribute IS the
	apply over there -- AtvServer.applyStats watches that exact attribute. Both
	arguments are onBuy's and onBuyCar's, written out at the foot of applyAll.
]]
local function raise(player: Player, ladder: string, key: string): (string, number)
	if ladder == "car" then
		local level = AtvConfig.carLevelOf(player, key) + 1
		player:SetAttribute(AtvConfig.CarAttrPrefix .. key, level)
		return AtvConfig.UpgradeByKey[key].name, level
	end
	local level = ProgressionServer.levelOf(player, key) + 1
	player:SetAttribute(attrName(key), level)
	ProgressionServer.applyAll(player)
	return Config.TrackByKey[key].name, level
end

--[[
	WHAT TO UPGRADE WHEN NOBODY SAID -- the cheapest rung the player can actually
	buy, and the car ladder only if the foot ladder has nothing left.

	CHEAPEST rather than first-in-the-table, and it is not an arbitrary tie-break:
	the cheapest rung is the LOWEST track relative to its own curve, which is the
	one a player buying upgrades would have bought next anyway. First-in-the-table
	would pour every orphaned receipt into Sifter Width.

	Foot before car because the foot ladder is wiped by every rebirth and the car
	ladder is not: handing an unattributable purchase to the permanent ladder would
	be worth more than the player paid for, which is the wrong direction to be
	generous in when nobody can say what they meant.
]]
local function fallbackTarget(player: Player): (string?, string?)
	local bestKey, bestCost = nil, nil
	for _, t in Config.Tracks do
		if not footRefusal(player, t.key) then
			local cost = Config.costFor(t, ProgressionServer.levelOf(player, t.key))
			if cost and (bestCost == nil or cost < bestCost) then
				bestKey, bestCost = t.key, cost
			end
		end
	end
	if bestKey then
		return "foot", bestKey
	end
	for _, t in AtvConfig.Upgrades do
		if not carRefusal(player, t.key) then
			return "car", t.key
		end
	end
	return nil, nil
end

--[[
	THE GRANT. ProductServer is the only caller -- this is the "upgrade" branch of
	its grantOf, reached from ProcessReceipt.

	THE RETURN VALUE IS A RECEIPT DECISION IN DISGUISE and is the most expensive
	thing in this function to get wrong. `true` consumes the receipt for good;
	`false` leaves it with Roblox to re-send. So it returns true only after a level
	has ACTUALLY been written, and false in every case where nothing was.

	NOTHING HERE MAY YIELD. It runs inside ProcessReceipt, before the profile
	commit that decides the receipt's fate. ownsPassId is called WITHOUT `refresh`
	for exactly that reason -- it answers off the record rather than going to the
	web -- and every other call in here is an attribute read or write.
]]
function ProgressionServer.grantQuickUpgrade(player: Player, product): boolean
	local levels = math.floor(tonumber(product and product.amount) or 1)
	if levels < 1 then
		levels = 1
	end

	local ladder, key = nil, nil
	local want = pendingQuick[player]
	if want and (os.clock() - want.at) <= QUICK_TTL
		and not refusalFor(player, want.ladder, want.key)
	then
		ladder, key = want.ladder, want.key
	end

	-- No intent, a stale one, or one that is no longer buyable. See the header:
	-- refusing here would take the Robux and hand back nothing.
	local fellBack = false
	if not key then
		ladder, key = fallbackTarget(player)
		fellBack = true
	end
	if not (ladder and key) then
		-- Nothing anywhere can take a level. NOT consumed -- Roblox holds the
		-- receipt and the next rebirth pays it out by itself.
		warn(string.format("[ProgressionServer] Quick Upgrade for %s has nothing to "
			.. "upgrade -- receipt NOT consumed, it will pay out when a rung frees up.",
			player.Name))
		return false
	end

	--[[
		ONE AT A TIME, RE-CHECKED EACH TIME, so `amount` can be raised to a bundle
		without this ever stepping past the ceiling. A loop that trusted the first
		check and then wrote level + amount would sell exactly the thing the header
		says is not for sale.

		A partial grant still consumes the receipt, and that is correct: the player
		has had levels, and the alternative -- refusing the whole purchase because
		the last rung of a bundle hit the cap -- re-sends a receipt that will grant
		the earlier rungs a second time.
	]]
	local name, level, granted = nil, nil, 0
	for _ = 1, levels do
		if refusalFor(player, ladder, key) then
			break
		end
		name, level = raise(player, ladder, key)
		granted += 1
	end
	if granted == 0 or not name then
		return false
	end

	ProgressionServer.push(player)
	notify(player, string.format("%s \u{2014} %s to Level %d!",
		(product and product.name) or "Quick Upgrade", name, level), "pickup")
	if fellBack then
		-- Said out loud rather than hidden. The player pressed one row and got a
		-- level on another; that is the right outcome (they were paid) but it is
		-- not the one they asked for, and an unexplained level is a support ticket.
		notify(player, "The upgrade you picked was not available, so this went to "
			.. "your cheapest one instead.", "info")
	end
	Net.get("Fx"):FireClient(player, { kind = "Upgrade", part = ProgressionServer.fxAnchor })
	return true
end

--[[
	THE ASK. Records the intent and asks the client to open Roblox's dialog; it
	never grants anything and never touches a level.

	SHARES `lastAction` WITH onBuy AND onBuyCar, for the reason onBuyCar's header
	gives: the gate is anti-spam on the PLAYER, and a third clock would let a
	client alternate three remotes to get three times the rate through all of them.

	The payload is a KEY and a LADDER. Not a product id -- that travels the other
	way, on the prompt, so this side cannot name one -- and not a level or a price,
	which are re-derived here and again at the grant.
]]
local function onQuickUpgrade(player: Player, payload)
	if type(payload) ~= "table" then
		return
	end
	local key = payload.track
	if type(key) ~= "string" then
		return
	end
	-- Anything that is not the word "car" is the foot ladder. A client cannot
	-- invent a third ladder, and the two refusal sets are the only branch.
	local ladder = (payload.ladder == "car") and "car" or "foot"

	local now = os.clock()
	if now - (lastAction[player] or -math.huge) < 0.15 then
		return
	end
	lastAction[player] = now

	--[[
		The product has to be REAL before a dialog is opened over it. id 0 is a row
		waiting to be filled in, and PromptProductPurchase on one opens a dialog
		that cannot complete -- the same failure GamePassService's header describes
		for an off-sale pass. The panel already draws SOON in that state; this is
		the gate behind it.
	]]
	local product = quickProduct()
	if not product then
		notify(player, "Quick Upgrade is not on sale yet.", "warn")
		return
	end

	local refusal = refusalFor(player, ladder, key)
	if refusal then
		notify(player, refusal, "warn")
		return
	end

	pendingQuick[player] = { ladder = ladder, key = key, at = now }
	Net.get("QuickUpgradePrompt"):FireClient(player, {
		productId = product.id,
		track = key,
	})
end

--------------------------------------------------------------------------
-- THE ASCENSION
--
-- What a rebirth LOOKS like. The wipe below is instant and always was, which
-- meant the biggest decision in the game -- give up every upgrade, all your
-- money and (since 2026-08-24) your machine unless a game pass backs it --
-- produced a toast and nothing else.
--
-- Run on the SERVER, deliberately. The character is a replicated model, so
-- lifting it here means everyone on the beach watches that player go up in a
-- column of light; a client-side rise would be a private hallucination. The
-- client's own half (RebirthCinema) is only the camera and the curtain, which
-- are the two things that genuinely are per-player.
--------------------------------------------------------------------------

local RISE_TIME = 2.4
local RISE_HEIGHT = 260
local COLUMN_GOLD = Color3.fromRGB(255, 224, 128)
local RING_FOAM = Color3.fromRGB(140, 232, 255)

local ascending = {}

--[[
	SET ON THE PLAYER FOR THE LENGTH OF THE LIFT, and it keeps the same contract
	DuelArena / VaultRun / OnFerry keep: "another system owns this character, do
	not move it". AfkService.enter refuses on it.

	That closes the OTHER half of the race the gate in onRebirth closes. The gate
	stops a rebirth being pressed from the shore; this stops the shore taking a
	player who is already in the air. A player who rebirths while stood on the
	shore's entry pad is anchored and lifted off it, which is a contact change,
	and the pad's Touched handler would happily start a visit under them -- so
	they would land on the spawn pad two seconds later with a live visit still
	sinking their movement keys, which is precisely the state being fixed.
]]
local ASCEND_ATTR = "Rebirthing"

-- THE FALLBACK LANDING: the place's one SpawnLocation, on the home beach.
--
-- No longer where a rebirth normally puts you -- see `landingCFrame` below,
-- which lands the player back on the shore they turned the tide on. This is
-- what is used when there is no body to read a position off (the dead /
-- between-characters branch of `ascend`) or when the position that comes back
-- is not somewhere a character can stand.
--
-- Cached rather than swept for, and re-resolved if it ever goes away --
-- workspace:GetDescendants() here would walk a beach of several thousand parts
-- to find a part whose position has not changed since the place was authored.
local spawnPad = nil
local function spawnCFrame(): CFrame
	if not (spawnPad and spawnPad.Parent) then
		local beach = workspace:FindFirstChild("Beach")
		spawnPad = (beach and beach:FindFirstChildWhichIsA("SpawnLocation", true))
			or workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	end
	if spawnPad then
		-- Stood ON the pad and clear of its own collision box, facing whichever
		-- way the pad does.
		return spawnPad.CFrame * CFrame.new(0, spawnPad.Size.Y * 0.5 + 3.5, 0)
	end
	return CFrame.new(0, 6.5, -139)
end

--[[
	YOU LAND ON THE SHORE YOU TURNED THE TIDE ON. Asked for and put back
	2026-09-08, having been the behaviour once before and reverted on 2026-08-29.

	WHERE, EXACTLY: the spot you took off from, settled onto the ground under it.
	Not the middle of the field -- that is what the 2026-08 version did, off
	CTB.Config's island geometry, and it is why that version needed a `Field`
	require at the top of this file. Reading the body's own CFrame needs no
	config at all, works on the three INTERIORS as well as the four shores (the
	Vault, the Inner Shrine and the Magma Chamber are rooms with no field row and
	no ferry berth, and the old version could not express them), and is the
	honest reading of "put me back where I was".

	THE ARGUMENT AGAINST IT IS STILL TRUE AND IS WORTH LEAVING HERE: A REBIRTH
	TAKES EVERYTHING AWAY. All four tracks go back to level 1, the coins go, and
	the machine goes with them unless a game pass is holding it up. So this does
	not put a player back on "the sand they were working" so much as leave them on
	Ashfall with a level-1 sifter and a 12 lb bucket, which is the poorest kit in
	the game on the field that is priced for the best one. The shop, the scales
	and the wash bay the new tide is about to be spent on are all on the home
	beach, and the walk back to them is now the player's to choose.

	WHAT MAKES THAT SURVIVABLE is the thing that was already true: nothing is
	locked behind the walk. A rebirth only ever RAISES the counter and every gate
	is a minimum (Dunes 1, Vault 4, Cove 8, Shrine 14, Ashfall 22, Magma 32, Penguin 34, Wreck 40), so
	every island the player had is still open, and every shore has a ferryman on
	it whose home run is free by rule (see FerryConfig: "a player who rebirthed,
	or who swam, must always be able to get back to the wash bay").

	THE LONG SHORE IS NOT A CASE HERE. onRebirth refuses outright while a player
	is on an AFK visit, so the takeoff point is always somewhere in the map.

	IT STILL FALLS BACK TO THE PAD FOUR WAYS, and all four are "there is no shore
	to put them back on": no body to read a position off at all (the branch at the
	top of `ascend`), nothing solid within reach underneath them, standing on a
	ferry, and the raycast finding the world empty. Everything else -- the four
	shores, the three interiors, a pier, a rooftop, the sifting kiosk -- is a
	place they were standing, and they get it back.

	To go back to landing everyone on the home beach, this function goes and the
	one call in `ascend` becomes `spawnCFrame()` again. The second call, in the
	no-body branch, is `spawnCFrame()` either way.
]]

-- How far the root part rides above whatever it is standing on. A humanoid's
-- root sits at hip height plus half the root, and 3.5 is the same clearance
-- spawnCFrame uses over the pad.
local STAND_CLEAR = 3.5

-- How far below the root the floor is allowed to be before "the ground under
-- them" stops meaning anything. A player who is STANDING has it 3.5 down; on a
-- machine, five or six; at the top of a jump, ten. Twenty is slack on all three
-- and still short enough that somebody falling off a cliff finds nothing.
local GROUND_REACH = 20
local RAY_UP = 6

local function landingCFrame(char: Model, hrp: BasePart, hum: Humanoid): CFrame
	local pos = hrp.Position

	-- Yaw only. A character that took off leaning down a dune, or seated on a
	-- machine that was itself on a slope, carries pitch and roll in its CFrame,
	-- and PivotTo would set them back down at that angle.
	local look = hrp.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = (flat.Magnitude > 1e-3) and flat.Unit or Vector3.new(0, 0, -1)

	--[[
		SETTLED ONTO THE GROUND RATHER THAN PUT BACK AT THE EXACT TAKEOFF HEIGHT.

		The machine is the reason. `ascend` unseats the rider a few lines below
		this call, and a VehicleSeat stands the player a few studs off the sand --
		so the raw takeoff CFrame is a point in the air above a truck that is, for
		anyone without the pass, about to be despawned by the wipe. Hence the seat
		going into the ignore list: the ray has to reach the ground UNDER the
		machine, not the roof of it.
	]]
	local ignore: { Instance } = { char }
	local seat = hum.SeatPart
	if seat then
		table.insert(ignore, seat:FindFirstAncestorOfClass("Model") or seat)
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true

	-- Started a little ABOVE the root, so a root that has sunk a stud into soft
	-- sand still has the floor below the ray rather than behind it.
	local hit = workspace:Raycast(
		pos + Vector3.new(0, RAY_UP, 0),
		Vector3.new(0, -(RAY_UP + GROUND_REACH), 0),
		params
	)

	--[[
		NOTHING SOLID UNDER THEM -> THE HOME BEACH.

		"Back on the island you were on" only says anything while there is an
		island under you. Falling, or out over open water, the takeoff point is not
		a place a character can be set down, and the pad is the honest answer --
		the same one every rebirth took before 2026-09-08.

		RARELY REACHED, and deliberately so: SeaWallBuilder already puts a swimmer
		who gets outside an island's fence back inside it, so "out over the deep"
		is a state the map does not let anybody hold. This is the backstop under
		that, not the thing carrying it.
	]]
	if not hit then
		return spawnCFrame()
	end

	--[[
		AND A BOAT IS NOT A SHORE.

		A crossing writes the rider's CFrame every Heartbeat for nine seconds
		(FerryServer.run), and the rebirth button is not disabled while it runs --
		so a tide CAN be turned standing on a deck in the middle of the sea. The
		ray finds the hull, which is solid and is genuinely what they are standing
		on, and setting them back down on it would end the ceremony out on open
		water. Moored counts too: the sea is four studs deep under a berthed hull,
		so "were they under way" is not a question worth asking. One rule -- if you
		turned the tide aboard her, you come down on the pad.

		THE BOAT, NOT THE BERTH. `workspace.Ferries` holds each ferry's PIER as
		well as her boat, and a pier is on land: it is the island's own planking,
		it is where every crossing sets you down, and rebirthing on it has to leave
		you on it. So this asks for the `Boat` model by name rather than for
		anything under the folder -- a pier deck reads as Ferries.<X>Ferry.Pier.
	]]
	local ferries = workspace:FindFirstChild("Ferries")
	local boat = ferries and hit.Instance:FindFirstAncestor("Boat")
	if boat and boat:IsDescendantOf(ferries) then
		return spawnCFrame()
	end

	local at = Vector3.new(pos.X, hit.Position.Y + STAND_CLEAR, pos.Z)
	return CFrame.lookAt(at, at + flat)
end

local function ascendFx(hrp: BasePart): Folder
	local holder = Instance.new("Folder")
	holder.Name = "TideAscension"
	holder.Parent = workspace

	-- THE COLUMN. A cylinder's length runs along its X axis, so it has to be
	-- rolled a quarter turn to stand up -- building it without that gives a
	-- gold log lying across the sand, which is a mistake worth only making once.
	local column = Instance.new("Part")
	column.Name = "Column"
	column.Shape = Enum.PartType.Cylinder
	column.Size = Vector3.new(RISE_HEIGHT + 60, 11, 11)
	column.CFrame = CFrame.new(hrp.Position + Vector3.new(0, (RISE_HEIGHT + 60) * 0.5 - 6, 0))
		* CFrame.Angles(0, 0, math.pi * 0.5)
	column.Color = COLUMN_GOLD
	column.Material = Enum.Material.Neon
	column.Transparency = 1
	column.Anchored, column.CanCollide = true, false
	column.CanQuery, column.CanTouch, column.CastShadow = false, false, false
	column.Parent = holder
	TweenService:Create(column, TweenInfo.new(0.45), { Transparency = 0.55 }):Play()
	-- Fades from about two thirds of the way up, so the light is thinning out
	-- as the player leaves rather than snapping off with them still in it.
	task.delay(RISE_TIME * 0.62, function()
		if column.Parent then
			TweenService:Create(column, TweenInfo.new(RISE_TIME * 0.38), { Transparency = 1 }):Play()
		end
	end)

	-- A ring running out across the sand: the launch needs a beat on the ground
	-- or the player simply starts drifting upward.
	local ring = Instance.new("Part")
	ring.Name = "Ring"
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.6, 8, 8)
	ring.CFrame = CFrame.new(hrp.Position - Vector3.new(0, 2.4, 0)) * CFrame.Angles(0, 0, math.pi * 0.5)
	ring.Color = RING_FOAM
	ring.Material = Enum.Material.Neon
	ring.Transparency = 0.25
	ring.Anchored, ring.CanCollide = true, false
	ring.CanQuery, ring.CanTouch, ring.CastShadow = false, false, false
	ring.Parent = holder
	TweenService:Create(ring, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.6, 88, 88),
		Transparency = 1,
	}):Play()

	local glow = Instance.new("PointLight")
	glow.Color = COLUMN_GOLD
	glow.Range = 60
	glow.Brightness = 3
	glow.Shadows = false
	glow.Parent = column

	-- Sparkles off the player themselves, so the light is clearly coming from
	-- THEM rather than being something they walked into.
	local spark = Instance.new("ParticleEmitter")
	spark.Name = "TideSparkle"
	spark.Texture = GameConfig.Textures.Sparkle
	spark.Color = ColorSequence.new(Color3.fromRGB(255, 246, 200), COLUMN_GOLD)
	spark.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.3, 1.4),
		NumberSequenceKeypoint.new(1, 0),
	})
	spark.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	spark.Lifetime = NumberRange.new(0.6, 1.3)
	spark.Speed = NumberRange.new(14, 30)
	spark.SpreadAngle = Vector2.new(26, 26)
	spark.EmissionDirection = Enum.NormalId.Top
	spark.Acceleration = Vector3.new(0, 18, 0)
	spark.Rate = 90
	spark.LightEmission = 0.9
	spark.Parent = hrp
	Debris:AddItem(spark, RISE_TIME + 1)

	Debris:AddItem(holder, RISE_TIME + 2)
	return holder
end

local function ascend(player: Player, tide: number)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not (hrp and hrp:IsA("BasePart") and hum and hum.Health > 0) then
		-- Nothing to lift -- dead, or between characters. The rebirth itself has
		-- already happened; just make sure they are not left standing in the
		-- desert with a level-1 sifter.
		if char then
			-- PivotTo rather than a root-part CFrame: the root part is the thing
			-- that is missing in this branch.
			char:PivotTo(spawnCFrame())
		end
		return
	end

	-- WHERE THEY TOOK OFF FROM -- see the note above landingCFrame.
	--
	-- RESOLVED HERE AND NOT IN THE LANDING CLOSURE, and that is now load-bearing
	-- rather than incidental: the lift below anchors the character and raises it
	-- 260 studs out of the world, so by the time the landing runs `hrp.Position`
	-- is up in the sky and says nothing about which shore anybody was standing
	-- on. It also has to be read BEFORE the unseat a few lines down, while
	-- `hum.SeatPart` still names the machine the ray needs to ignore.
	local landing = landingCFrame(char, hrp, hum)
	if ascending[player] then
		return
	end
	ascending[player] = true
	player:SetAttribute(ASCEND_ATTR, true)

	Net.get("RebirthAscend"):FireClient(player, {
		phase = "rise",
		rebirths = tide,
		seconds = RISE_TIME,
	})

--[[
		OUT OF THE DRIVING SEAT FIRST, AND THIS HAS TO HAPPEN BEFORE THE ANCHOR.

		A seated humanoid is WELDED to the seat (SeatWeld), and a weld outranks
		everything this function does afterwards: the tween moves the root, the
		physics solver puts it back at the seat, and `char:PivotTo(spawnCFrame())`
		in the landing re-solves the same way the instant `Anchored` goes false --
		because PivotTo moves the CHARACTER model and the machine is not in it. The
		player ends the cinematic sitting in their truck wherever they left it,
		with the spawn-pad teleport silently undone and a WalkSpeed they cannot use.

		It was latent until 2026-08-24 and is now reachable two ways. A player
		without the game pass is saved by accident -- onRebirth wipes their
		`AtvTier`, AtvServer's ownership watcher despawns the machine, and the weld
		dies with the model. A PASS HOLDER is not: their tier is deliberately left
		standing, so the seat is still there and still welded. Fixing it here rather
		than in that watcher is what covers both, and it covers the pre-existing
		case too (before the wipe existed, EVERY seated rebirth did this).

		`Sit = false` rather than destroying the weld by hand: it is the supported
		way out and it lets the VehicleSeat's own Occupant handler run, which is
		what clears the rider's NetRadius and closes the hold (see AtvServer).
	]]
	if hum.SeatPart then
		hum.Sit = false
		-- One frame for the weld to actually go. Anchoring the root while the
		-- SeatWeld is still live re-parents a joint mid-solve, and the character
		-- can come back at the seat's position rather than at the tween's.
		task.wait()
		if not (hrp.Parent and hum.Parent and hum.Health > 0) then
			ascending[player] = nil
			player:SetAttribute(ASCEND_ATTR, nil)
			return
		end
	end

	-- FROZEN BY ANCHORING THE ROOT, not by WalkSpeed alone. Every other limb
	-- hangs off HumanoidRootPart through Motor6Ds, so anchoring it carries the
	-- whole assembly and the tween stops arguing with the physics solver. The
	-- Physics state is what keeps the humanoid's own state machine from trying
	-- to "fall" the entire way up.
	hum.WalkSpeed = 0
	hum:ChangeState(Enum.HumanoidStateType.Physics)
	hrp.Anchored = true

	ascendFx(hrp)

	TweenService:Create(hrp, TweenInfo.new(RISE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		CFrame = hrp.CFrame + Vector3.new(0, RISE_HEIGHT, 0),
	}):Play()

	-- UNCONDITIONAL, and it is the thing that sets them down. A client that
	-- never plays the cinematic, or closes the window half way up, still comes
	-- down on solid ground with control returned -- the curtain is decoration,
	-- the teleport is the mechanic.
	task.delay(RISE_TIME, function()
		ascending[player] = nil
		-- UNCONDITIONAL, alongside the flag and for the same reason the teleport
		-- below is: a lock that outlived its lift would shut the player out of
		-- the shore for the rest of the session.
		player:SetAttribute(ASCEND_ATTR, nil)
		if char.Parent and hrp.Parent then
			char:PivotTo(landing)
			hrp.Anchored = false
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
		-- applyAll owns WalkSpeed, so this is what hands movement back -- and it
		-- hands it back at the RESET Beach Legs level, not the one they had
		-- before the wipe.
		ProgressionServer.applyAll(player)
		Net.get("RebirthAscend"):FireClient(player, { phase = "land", rebirths = tide })
	end)
end

--------------------------------------------------------------------------
-- REBIRTH
--------------------------------------------------------------------------

--[[
	WHAT `AtvTier` SHOULD BE AFTER THE TIDE: the highest machine this player's
	GAME PASSES entitle them to, or 0 -- except when we cannot safely say.

	THE SERVER'S ANSWER, NEVER THE ATTRIBUTE. `Pass_<id>` and `AtvTier` are both
	replicated statements on a Player instance -- they exist so a panel can paint
	a button -- and reading either one here would mean a rebirth wipe could be
	skipped by whatever last wrote them. GamePassService.owns answers off the
	entitlement IT resolved from Roblox, which is the only source that is not
	downstream of this wipe.

	The max is taken rather than the first hit because the ladder is inclusive:
	owning the tier-4 pass entitles a player to the tier-3 machine as well (the
	id is a floor, see GamePassService), so the highest id that answers true is
	the whole entitlement.

	"WE COULD NOT ASK" IS NOT "THEY DO NOT OWN IT", AND CONFLATING THE TWO HERE
	DESTROYS A ROBUX PURCHASE PERMANENTLY.

	`GamePassService.owns` has two answers and its data source has three:
	UserOwnsGamePassAsync can fail, in which case the join sweep leaves the
	entitlement floor at the 0 it was seeded with. Every other reader in the game
	treats that 0 harmlessly -- it merely fails to GRANT something, and the next
	sweep tries again, which is what GamePassService's own `ownsPass` note
	promises: "a dropped request must not become 'you do not own the thing you
	paid for'". This function is the first destructive reader ever written
	against it, so here that same 0 would wipe the machine and SaveService would
	persist the loss on the next commit. There is no in-session recovery: the
	floor watcher only ever RAISES toward the entitlement, and an entitlement of
	0 raises nothing.

	So an unresolved entitlement means DO NOT WIPE. We re-ask Roblox first --
	this is a rebirth, once a tide, and it can afford the yield -- and if it
	still will not answer, the player keeps whatever they had. The cost of being
	wrong that way is one free tide with a machine; the cost of being wrong the
	other way is somebody's money.
]]
local function passFloorFor(player: Player): number
	local current = math.max(0, math.floor(tonumber(player:GetAttribute(AtvConfig.OwnedAttribute)) or 0))

	if not GamePassService.tiersKnown(player) then
		-- Yields. Only reachable on a rebirth, and only when the join sweep did
		-- not get an answer -- so it costs nothing on the normal path.
		if not GamePassService.refreshTiers(player) then
			warn(string.format(
				"[ProgressionServer] %s rebirthed while their game-pass entitlement "
				.. "was unresolved -- keeping AtvTier %d rather than wiping a machine "
				.. "they may have paid for.", player.Name, current))
			return current
		end
	end

	local floor = 0
	for _, tier in AtvConfig.Tiers do
		if tier.id > floor and GamePassService.owns(player, tier) then
			floor = tier.id
		end
	end
	return floor
end

local function onRebirth(player: Player)
	local now = os.clock()
	if now - (lastAction[player] or -math.huge) < 0.4 then
		return
	end
	lastAction[player] = now

	--[[
		NOT FROM THE LONG SHORE.

		`ascend` below anchors the player, lifts them and sets them down again, and
		moving a body out of a LIVE VISIT that way is exactly the bug AfkBus's
		header exists to describe: the bay stays held, AfkPlot stays set, and
		AfkClient goes on sinking the player's movement keys -- so they land unable
		to move. The only way out was the card's GO BACK button, which then
		teleported them a second time, back to the shore entry they had come from.

		STILL TRUE NOW THAT THE LANDING IS WHERE THEY TOOK OFF (2026-09-08), and if
		anything less obvious: the lift alone breaks contact with the shore's entry
		pad, which is the contact change that starts a visit under them. Setting
		them back down on the same spot does not undo that.

		REFUSED RATHER THAN WOKEN, and that is a decision. AfkBus.wake would end
		the visit and let the rebirth run, and it would not be stuck -- but a tide
		is the most destructive button in the game (coins, finds, machine, every
		track) and it would be pressed from a screen showing a beach the player is
		not standing on, eight thousand studs from the map. Sending them back and
		letting them press it there is the honest reading of turning the tide.

		FIRST, ahead of the two gates below, because it is the only one of the
		three that is about WHERE they are: a player out on the shore should be
		told to come back whether or not they have earned it yet.
	]]
	if AfkBus.isIdle(player) then
		notify(player, "You cannot turn the tide out on the Long Shore — head back to the beach first.", "warn")
		return
	end

	-- NO CEILING CHECK. This used to refuse at MaxRebirths with "You have
	-- ridden every tide there is!"; the ladder is endless now and the two gates
	-- below are the whole of it. ProgressionConfig.Rebirth.LadderTides has the
	-- argument for why the curves need no special case above the authored run.
	local n = ProgressionServer.rebirthsOf(player)

	local earned = ProgressionServer.tideEarnedOf(player)
	local need = Config.Rebirth.requirement(n + 1)
	if earned < need then
		notify(player, string.format("Earn %d more this tide first", need - earned), "warn")
		return
	end

	-- AND THE BEACH HAS TO HAVE BEEN CLEANED, not just the money made. Stated
	-- second because it is the one that almost never refuses: the ladder is
	-- pitched under what raking your own coins already picks up, so anybody who
	-- earned this tide out of the sand is past it before they read it.
	local trash = ProgressionServer.tideTrashOf(player)
	local trashNeed = Config.Rebirth.litterRequirement(n + 1)
	if trash < trashNeed then
		notify(player, string.format("Pick up %d more pieces of litter this tide first",
			trashNeed - trash), "warn")
		return
	end

	-- Wipe: coins to zero, every track back to 1, and the TIDE's earnings back
	-- to zero so the next requirement has to be earned in full rather than part
	-- paid for by the run that just ended (see tideEarnedOf). `TotalEarned` is
	-- deliberately left alone -- it is a lifetime stat and nothing gates on it.
	local coins = SellServer.getCoins(player)
	if coins > 0 then
		-- The tide takes the balance rather than buying anything with it, but a
		-- coin that leaves has to land somewhere on the report or sources and sinks
		-- stop adding up. See SellServer's ECONOMY table.
		SellServer.addCoins(player, -coins, "rebirth")
	end
	--[[
		THE TRACKS DROP TO A FLOOR, NOT TO 1 -- see Config.Rebirth.KeptRungs for
		the measurement that chose the number and for why the request behind it
		("can we keep the coins") was built as rungs instead.

		math.min, NOT a straight write, and that is the whole guard: a player who
		never got past level 2 on a row keeps the 2 they had rather than being
		HANDED a third. This can only ever take levels away or leave them alone, so
		it cannot be farmed by rebirthing early on a row nobody bought.

		levelOf rather than a raw read, because ProgressionServer writes no
		attribute at all until the first purchase on a track -- it returns the
		floor of 1 for an absent one, which is what an untouched row is worth.
	]]
	local keepTo = 1 + math.max(0, tonumber(Config.Rebirth.KeptRungs) or 0)
	for _, t in Config.Tracks do
		player:SetAttribute(attrName(t.key),
			math.min(ProgressionServer.levelOf(player, t.key), keepTo))
	end
	--[[
		THE MACHINE GOES WITH THE TIDE UNLESS IT WAS PAID FOR IN ROBUX.

		Coins bought it, coins are wiped, so it is wiped -- the same rule every
		track above follows. A GAME PASS is the exception, and it is the only one:
		somebody who paid real money for a machine keeps it forever, which is what
		paying real money for a machine has to mean.

		WRITTEN AS THE PASS FLOOR RATHER THAN AS ZERO, and that is deliberate.
		GamePassService watches this attribute and re-raises anything written
		below a pass holder's entitlement, so `SetAttribute(..., 0)` would also
		arrive at the right answer -- eventually. Attribute-changed signals are
		deferred, so between this line and that watcher there is a window in which
		a pass holder reads as owning nothing. `ProgressionServer.push` below is
		inside it: push -> snapshot -> AtvConfig.ownedTier reads this attribute
		directly, so a deferred correction would send the panel a snapshot saying
		the machine is gone. (`applyAll` is NOT a reader -- it touches the four
		tracks and the sell multiplier only -- so nothing between here and there
		depends on this ordering.) Writing the final value closes the window; the
		watcher stays as the backstop it was built to be.

		THE CAR LADDER IS STILL NOT IN THIS WIPE, but the reason has changed and
		the old one is now false. It used to be "the rake survives because the
		machine does"; the machine no longer does. What survives it now is the
		PRICE ARGUMENT, which never depended on the machine: the whole bar
		costs about 1.73B -- most of a full level-60 ladder rebuild (1.95B at
		the 2026-08 quadrupled bases) -- precisely because it is bought ONCE
		and that ladder is bought every tide. Wiping it would make the same
		numbers a wall. A rake with no machine under it is inert rather than
		broken -- AtvConfig.effectiveStats only ever reads it for a tier that is
		actually being ridden -- so it simply waits for the next machine.
	]]
	player:SetAttribute(AtvConfig.OwnedAttribute, passFloorFor(player))

	player:SetAttribute("TideEarned", 0)
	-- The litter gate's zero. Not a counter reset: the lifetime total is what the
	-- MOST TRASH board ranks and it keeps running -- this is the mark the next
	-- tide is measured from. See tideTrashOf.
	player:SetAttribute("TideTrashBase",
		tonumber(player:GetAttribute(LeaderboardConfig.TrashAttribute)) or 0)
	player:SetAttribute("Rebirths", n + 1)

	-- Carried items go too: they were earned under the old tide.
	local inv = InventoryController.Server.find(player)
	if inv then
		inv:RemoveWhere(function()
			return true
		end)
	end

	ProgressionServer.applyAll(player)
	ProgressionServer.push(player)

	notify(player, string.format("The tide turns! Rebirth %d -- %.2fx forever.",
		n + 1, Config.Rebirth.multiplier(n + 1)), "pickup")
	-- Likewise personal: your rebirth, your fireworks.
	Net.get("Fx"):FireClient(player, {
		kind = "Rebirth",
		part = ProgressionServer.fxAnchor,
		rebirths = n + 1,
	})

	--[[
		PUT THE NEW COUNT ON THE WORLD BOARD NOW, rather than at the next publish
		cycle ninety seconds from here.

		This is the one stat worth the interruption. A rebirth is rare and
		deliberate, and the MOST REBIRTHS board is the first thing a player goes to
		look at afterwards -- a board still showing the old number is the one
		moment they would catch it being stale. It used to be unmissable, because
		ascend set everyone down on the home beach with the boards right there;
		since 2026-09-08 they land on the shore they turned the tide on, so the
		look may come a boat ride later. Publishing now is if anything worth more
		for that -- the walk over is no longer the thing that hides the delay.

		Required here rather than at the top of the file: LeaderboardService boots
		last (see ServerMain step 13) and this is a rebirth, not a hot path. The
		call is a no-op before that service has started and never yields.
	]]
	local okLb, Leaderboard = pcall(require, script.Parent:FindFirstChild("LeaderboardService"))
	if okLb and Leaderboard then
		Leaderboard.publishNow(player)
	end

	-- Up, and back down on the shore they pressed it on. Last, so the wipe is
	-- fully applied before the player is lifted -- ascend's landing calls applyAll
	-- again to hand movement back, and it must be handing back the RESET numbers.
	ascend(player, n + 1)
end

ProgressionServer.fxAnchor = nil

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

local started = false
function ProgressionServer.start()
	assert(RunService:IsServer(), "[ProgressionServer] server-only")
	if started then
		return
	end
	started = true

	-- Every sale runs through here, so this is the one place lifetime earnings
	-- and the rebirth multiplier can be applied without a second code path.
	SellServer.OnCoinsChanged = function(player, total, delta)
		if delta > 0 then
			player:SetAttribute("TotalEarned", (player:GetAttribute("TotalEarned") or 0) + delta)
			-- The gate's counter. Read through tideEarnedOf so a player who has
			-- never had one seeds from their lifetime figure rather than dropping
			-- to zero the first time they sell.
			player:SetAttribute("TideEarned", ProgressionServer.tideEarnedOf(player) + delta)
		end
		ProgressionServer.push(player)
	end

	local function hook(player: Player)
		for _, t in Config.Tracks do
			if player:GetAttribute(attrName(t.key)) == nil then
				player:SetAttribute(attrName(t.key), 1)
			end
		end
		-- ZERO, not one. carLevelOf already reads a missing attribute as 0, so
		-- this buys nothing at runtime -- it is so the ladder is visible in
		-- Studio's property panel next to the Lv_ tracks, which is where anybody
		-- debugging a rake will look for it first.
		for _, t in AtvConfig.Upgrades do
			if player:GetAttribute(AtvConfig.CarAttrPrefix .. t.key) == nil then
				player:SetAttribute(AtvConfig.CarAttrPrefix .. t.key, 0)
			end
		end
		if player:GetAttribute("Rebirths") == nil then
			player:SetAttribute("Rebirths", 0)
		end
		if player:GetAttribute("TotalEarned") == nil then
			player:SetAttribute("TotalEarned", 0)
		end
		if player:GetAttribute("TideEarned") == nil then
			player:SetAttribute("TideEarned", ProgressionServer.tideEarnedOf(player))
		end
		-- Zero for anybody who has never rebirthed since the gate arrived, which
		-- is what tideTrashOf reads a missing mark as anyway. Written so the
		-- number is visible next to TideEarned in Studio's property panel.
		if player:GetAttribute("TideTrashBase") == nil then
			player:SetAttribute("TideTrashBase", 0)
		end
		ProgressionServer.applyAll(player)
		ProgressionServer.push(player)

		-- ...and again once the client has had time to boot.
		--
		-- The push above routinely lands BEFORE MenuHud has connected its
		-- ProgressionSync handler, and a RemoteEvent has no backlog -- a message
		-- sent to a client that is not listening yet is simply gone. The panel
		-- then sits on its placeholder text forever: every row reads "BUY" with
		-- no price and no stat line, because refresh() early-outs while the
		-- snapshot is nil. It only came alive if something else happened to
		-- trigger a push later (a sale, an inventory change, a respawn).
		--
		-- Worse than looking empty: the rows still LOOK buyable, so a player at
		-- the tide's level ceiling clicks a green button with a price on it and
		-- gets nothing, with no way to tell why.
		task.delay(3, function()
			if player.Parent then
				ProgressionServer.push(player)
			end
		end)

		--[[
			THE CAR TAB'S LOCK IS IN THE SNAPSHOT, so the snapshot has to move when
			the lock does.

			A coin purchase already pushes -- addCoins fires OnCoinsChanged, which
			is this module's own handler -- but two of the three ways to come to own
			a machine move NO coins at all: GamePassService writes AtvTier straight
			in for a pass holder, and SaveService writes it on a returning player.
			Without this, a pass holder stands at the counter reading LOCKED on
			something they have paid Robux for.

			On the attribute rather than on any of those three, because that is the
			one thing all three do -- which is the same argument AtvConfig's game
			pass note makes for writing the tier id there in the first place.
		]]
		player:GetAttributeChangedSignal(AtvConfig.OwnedAttribute):Connect(function()
			ProgressionServer.push(player)
		end)

		-- The same argument, for a pass that finishes an UPGRADE track rather
		-- than unlocking a machine. Ownership resolves on a web call that lands
		-- whenever it lands -- usually after this player's first snapshot has
		-- already gone out -- and without this the shop keeps offering, at full
		-- price, a rung the server has just decided not to sell.
		for _, entry in PassConfig.all() do
			if entry.supersedesTrack then
				player:GetAttributeChangedSignal(entry.attribute):Connect(function()
					ProgressionServer.push(player)
				end)
			end
		end

		player.CharacterAdded:Connect(function()
			-- A fresh Humanoid comes back at StarterPlayer.CharacterWalkSpeed (the
			-- level-1 floor, 24), not at this player's level; re-apply or Beach
			-- Legs silently evaporates on every death.
			task.wait(0.2)
			ProgressionServer.applyAll(player)
			ProgressionServer.push(player)
		end)
	end

	Players.PlayerAdded:Connect(hook)
	for _, player in Players:GetPlayers() do
		hook(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastAction[player] = nil
		ascending[player] = nil
		-- A receipt that outlives the session is answered by the fallback in
		-- grantQuickUpgrade, not by a stale row pointing at a track whose level
		-- this server no longer knows.
		pendingQuick[player] = nil
	end)

	Net.get("BuyUpgrade").OnServerEvent:Connect(onBuy)
	Net.get("BuyCarUpgrade").OnServerEvent:Connect(onBuyCar)
	Net.get("QuickUpgrade").OnServerEvent:Connect(onQuickUpgrade)
	Net.get("DoRebirth").OnServerEvent:Connect(onRebirth)

	-- Capacity changes must reach the panel too.
	InventoryController.Server.Changed:Connect(function(player)
		ProgressionServer.push(player)
	end)
end

return ProgressionServer
