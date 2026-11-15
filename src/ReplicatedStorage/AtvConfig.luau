--[[
	AtvConfig  --  ReplicatedStorage.AtvConfig

	The car spawner's stock: a bulldozer and a sweeper truck.

	THE QUAD AND THE PICKUP ARE GONE, and this time they are gone properly. They
	were taken out of the shop once before by deleting two entries from the table
	below and leaving everything behind them standing -- their rigs in
	AtvBuilder.RIGS, their shells in ServerStorage.Vehicles, the quad drive
	profile in AtvServer -- which is why they came back a second time, and why
	half the comments in these files went on describing a four-machine showroom
	for as long as they were away. The rigs, the shells and the profile have gone
	with them now, so putting either back is a real piece of work rather than two
	lines in this table.

	THE IDS START AT 3, AND THAT GAP IS DELIBERATE. `AtvTier` is persisted
	(SaveService.atvTier) and holds the highest id owned, which every ownership
	check compares with `>=`. Renumbering these to 1 and 2 would hand every
	player who once bought the 6,000 coin quad a 250,000 coin bulldozer, and
	everyone who bought the pickup the 1,500,000 coin truck. Leaving the gap
	costs nothing -- nothing in the game indexes Tiers by id, only through
	ByTier -- and a stale save of 1 or 2 correctly owns neither machine.

	The shop opens at FOURTEEN rebirths now, not two: 1,600,000 at the Inner
	Shrine (Sakura Cove's room, the second map), 20,000,000 at Ashfall Isle
	(the third and last map). Moved out from two and four rebirths so a car is
	no longer a first-ten-minutes purchase -- the beach and the sifter carry
	the whole early game on their own, and owning a truck now marks having
	reached the back half of the map rather than the start of it. Both prices
	are still pitched the same way: as a number of REBUILDS OF THE WHOLE
	UPGRADE LADDER at the tide the machine unlocks on.

	PITCHED IN TIME NOW, NOT IN REBUILDS (2026-08b). The rebuild multiple made
	sense for a once-ever purchase; the tide wipe made these recurring, and the
	4x base quadrupling moved what a rebuild even costs. Measured against
	ServerStorage.EconomyAudit's income model instead: the Sandhog is about an
	hour of farming at its gate tide (1.6M at rebirth 14), fading to a routine
	re-buy by the early twenties; the Tidebreaker is a little over an hour at
	its own (20M at rebirth 22), routine around twenty-six. A real save the
	tide you unlock one, a habit a handful of tides later -- the shape a
	recurring cost has to have.

	THAT MULTIPLE USED TO BE ABOUT ONE AND A HALF, and it moved without either
	price moving: the upgrade shop lost four of its eight tracks, and two thirds
	of what a rebuild costs went with them. Repricing a machine is a rebalance
	rather than part of removing a track, so both prices stand where they were.

	⚠ A REBIRTH WIPES `AtvTier` (2026-08-24) unless the player owns that
	machine's game pass, so a coin buyer RE-PAYS these prices every tide. The
	prices WERE re-pitched for that on 2026-08b -- the once-ever 7.8M and 108M
	figures would have been a seven-hour toll at the gate tide under the
	quadrupled shop -- but the deeper question stands: the ONE route to
	permanence, the game passes below, is unreachable while both are off sale.

	OR REAL MONEY. Each machine also has a GAME PASS, and a pass unlocks it
	OUTRIGHT -- past the price, past the rebirth gate, AND past the tide, which
	is what somebody paying Robux expects and is the whole reason the pass
	converts. ServerScriptService.GamePassService owns that; all this table
	carries is the id, because the panel needs to know which pass belongs to
	which bay.

	THAT THIRD ONE IS NEW AND IT IS NOW THE PASS'S BIGGEST SELLING POINT. Since
	2026-08-24 a coin-bought machine is WIPED BY EVERY REBIRTH like the four
	upgrade tracks are (ProgressionServer.onRebirth), so the pass is no longer a
	shortcut to a thing coins also buy permanently -- it is the only way to own
	one permanently. A coin buyer re-pays the price every tide they want to drive.

	What they cost, what they do, and what they look like.
	Replicated, because the spawner panel draws prices and stats straight off
	this table -- and none of it is secret. The SERVER re-reads every number
	here when it takes the money and when it spawns, so a client that edits its
	copy changes only what its own screen says.

	WHAT IS NOT IN HERE
	-------------------
	How any of them DRIVES (AtvServer.PROFILES, keyed on `kind`) and how any of
	them is BUILT (AtvBuilder.RIGS, same key). Driving is server-only and the
	panel has no use for a spool rate; geometry is server-only and the panel
	has no use for a seat offset. `kind` is the seam that ties all three.

	THE LADDER IS ABOUT WHAT YOU CARRY, NOT HOW FAST YOU GO
	------------------------------------------------------
	Every machine has its own HOLD -- a cargo box that fills as the net sweeps,
	completely separate from the bag on your back. You drive until the hold is
	full, then unload it into your own bag a bagful at a time and walk that to
	the scales. So the thing that actually improves up the ladder is `hold`,
	which climbs 300 -> 650, and `netRadius`, which decides how fast it fills.

	Speed deliberately does NOT climb in step. The bulldozer keeps the best turn
	in the game -- it pivots on the spot, which the truck cannot -- and the
	sweeper truck above it beats the dozer on net, hold and speed while losing on
	turn. So the second purchase is an upgrade rather than a replacement, and the
	cheaper machine stays worth owning at any upgrade level.

		netRadius   studs of trash the net sweeps while you drive. The
		            WeightSystem reads this off the player and its server range
		            check widens to match, so it is a real reach and not a
		            client-side claim.
		speed       studs/second flat out.
		turn        radians/second of yaw at full lock.
		hold        POUNDS the machine carries for you. Nothing to do with your
		            own Bucket Size, which is what limits a single unload.
		kind        picks the builder and the drive profile.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AtvConfig = {}

AtvConfig.SpawnerTag = "CarSpawner"

--[[
	A MACHINE SOMEBODY IS DRIVING, AS OPPOSED TO ONE STANDING ON A PLINTH.

	The showroom stock and the panel's previews come out of the same builders as
	the real thing, so nothing about the MODEL tells the two apart. This tag is
	put on by AtvServer.spawn and by nothing else, which makes it the definition
	of "a live machine with an owner" -- and the client needs that definition,
	because it has to find every one of them without walking Workspace.

	The two attributes go on the model beside it:

		OwnerUserId  whose it is. A UserId rather than a name: names change, and
	                 the client compares it against LocalPlayer.UserId.
		Concealed    true while it is still in the yard it spawned in. Everyone
	                 EXCEPT its owner draws it invisible until this goes false,
	                 which AtvServer does once the machine has been driven clear
	                 of the pad -- see the reveal block in its Heartbeat.

	BOTH ARE PUBLIC BY NATURE. Whose truck it is and whether it has left the pad
	are things you learn by looking at the beach; there is nothing here a client
	could lie about to its own advantage, and the server does not read either of
	them back.
]]
AtvConfig.VehicleTag = "AtvVehicle"
AtvConfig.OwnerAttribute = "OwnerUserId"
AtvConfig.ConcealedAttribute = "Concealed"

-- Player attributes the rest of the game reads.
--
-- `AtvTier` has THREE writers, not one: AtvServer (a coin purchase),
-- GamePassService (the entitlement floor) and ProgressionServer.onRebirth (the
-- tide wipe, since 2026-08-24). It reads "the highest tier owned RIGHT NOW",
-- which for a coin buyer resets every tide -- it was "highest tier bought", a
-- number that only ever went up, and code written against that assumption is
-- the thing to look for when this misbehaves.
AtvConfig.OwnedAttribute = "AtvTier"       -- highest tier owned now, 0 = none
AtvConfig.NetRadiusAttribute = "NetRadius" -- 0 when not riding
-- The hold, published for the HUD. These belong to the MACHINE, so they stay
-- up while you stand next to it with the engine off -- that is the whole point
-- of a separate storage, and it is why they are not cleared on dismount the
-- way NetRadius is.
AtvConfig.HoldLoadAttribute = "VehicleLoad"
AtvConfig.HoldMaxAttribute = "VehicleMax"

AtvConfig.Tiers = {
	{
		id = 3,
		key = "Sandhog",
		name = "Sandhog D10",
		blurb = "Tracked, with a blade the width of a beach hut. Turns on the spot.",
		--[[
			FOURTEEN REBIRTHS NOW, UP FROM TWO -- gated on the Inner Shrine, the
			room on Sakura Cove, the SECOND map, rather than an early tide. The
			old gate let a player drive off the beach in the first ten minutes;
			the beach and the sifter are meant to carry the whole first map on
			their own, and a 75,000 coin truck did not hold that line. (It was
			13 for a day; the Shrine's own door moved 13 -> 14 in the 2026-08
			curve retune and this moved with it.)

			1,600,000 IS ABOUT AN HOUR OF FARMING at rebirth fourteen -- the
			gate tide -- fading to a routine re-buy by the early twenties
			(EconomyAudit's income model; it was 7,800,000, a once-ever price
			from before the tide wipe and the 4x shop). A player who has just
			reached the Inner Shrine can afford this as a real save and not
			much past it; the Tidebreaker below is still a long way off.
		]]
		price = 1600000,
		minRebirths = 14,
		-- The "Bulldozer" pass. OFF SALE as this is written, which is not
		-- something the code can fix -- see GamePassService's header.
		gamePass = 1953498888,

		kind = "dozer",
		--[[
			BOTH MACHINES HERE ARE END GAME and nothing is for sale before
			thirteen rebirths. That is deliberate -- the beach is walkable and the sifter
			works on foot; these are what you graduate to.

			Speeds are half what they were. 26 studs/s is slow, and it should be:
			this was 100 at one point, which crossed the whole 256 stud beach in
			under three seconds and drove past litter faster than the net could
			ask for it.

			It keeps the best TURN in the game, and that is the one number the
			Tidebreaker does not beat. Skid steer is this machine's whole
			character -- it pivots on the spot where the truck has to swing round
			-- so being outclassed on cargo does not make it pointless.
		]]
		speed = 26,
		turn = 2.6,
		--[[
			THE REACH IS THE BLADE, not a vacuum.

			This was 42 and the truck's was 55, which is most of a beach. Even
			with the collected piece thrown to the scoop rather than blinked out,
			what that produced was litter FLYING AT YOU from forty studs away --
			a machine hoovering the horizon, while the rubbish you actually drove
			into was long gone before you reached it.

			16 is about the blade's own width (14.2), so what the machine
			collects is what the machine drives into. It also makes the short
			toss into the scoop read as scooping rather than as magnetism.
		]]
		netRadius = 16,
		-- Sized in bagfuls: a maxed Bucket Size bag is 100 lbs and one unload
		-- moves one bagful, so 300 is three trips to the scales and 650 is six
		-- and a half. The real ceiling is how much litter is ON the beach --
		-- TrashSeeder lays 90 pieces and they return 25s after collection.
		hold = 300,

		-- The dozer's livery is a baked mesh texture, so unlike the others
		-- these describe it rather than decide it. What they DO decide is the
		-- operator's station and the showroom plinth.
		body = Color3.fromRGB(232, 176, 44),
		accent = Color3.fromRGB(38, 42, 48),
		netColour = Color3.fromRGB(250, 232, 190),
	},
	{
		id = 4,
		key = "Tidebreaker",
		name = "Tidebreaker 900",
		blurb = "Thirty studs of dump truck. The biggest net and the biggest bed in the shop.",
		--[[
			TWENTY-TWO REBIRTHS -- Ashfall Isle, the last map, rather than the
			fourth rebirth. The truck used to be a mid-game purchase sitting
			just two rebirths past the dozer; it is the END of the shop now,
			matching the end of the map. (It was 19; Ashfall's ferry gate moved
			19 -> 22 in the 2026-08 curve retune and this moved with it.)

			20,000,000 IS A LITTLE OVER AN HOUR OF FARMING at rebirth
			twenty-two -- the gate tide -- becoming a routine re-buy around
			twenty-six (EconomyAudit's model; it was 108,000,000 from before
			the tide wipe and the 4x shop re-pitched every machine price in
			time rather than rebuilds). Not reachable a tide early: a player
			has to actually be working Ashfall's fields before this is in
			range.
		]]
		price = 20000000,
		minRebirths = 22,
		-- The "Truck" pass. OFF SALE as this is written -- see GamePassService.
		gamePass = 1953742878,

		kind = "sweeper",
		-- THE TOP OF THE SHOP. It beats the bulldozer on the three stats that
		-- decide how much beach you clear -- net, hold and speed -- and loses
		-- only on turn, which is the dozer's one trick and worth leaving it.
		speed = 31,
		turn = 1.6,
		-- 20 against a 13.5 stud scoop: a little more than the machine's own
		-- width, so the sweeper genuinely reaches wider than the dozer without
		-- either of them pulling litter in from off-screen. See the dozer's note.
		netRadius = 20,
		hold = 650,

		body = Color3.fromRGB(196, 92, 44),
		accent = Color3.fromRGB(236, 196, 120),
		netColour = Color3.fromRGB(248, 226, 178),
	},
}

AtvConfig.ByTier = {}
for _, tier in ipairs(AtvConfig.Tiers) do
	AtvConfig.ByTier[tier.id] = tier
end

function AtvConfig.tier(id: any)
	if type(id) ~= "number" then
		return nil
	end
	return AtvConfig.ByTier[id]
end

-- Defaulted rather than required, so a tier written without one still builds
-- and still drives. The builder table and the drive profile table both come
-- here, so the default has to be a key BOTH of them actually carry -- it was
-- "quad", which stopped being one of them the moment the quad left the shop.
function AtvConfig.kindOf(tier): string
	return (tier and type(tier.kind) == "string") and tier.kind or "sweeper"
end

function AtvConfig.holdOf(tier): number
	local n = tier and tier.hold
	return (type(n) == "number" and n > 0) and n or 0
end

----------------------------------------------------------------
-- THE GAME PASSES
----------------------------------------------------------------
--[[
	Each machine can be bought with Robux instead of coins, and a pass unlocks
	its machine OUTRIGHT -- past the price, past the rebirth gate, and past the
	tide wipe.

	HOW THAT IS ACTUALLY IMPLEMENTED IS THE PART WORTH KNOWING: owning a pass
	does not add a second ownership rule anywhere. GamePassService writes the
	tier's id straight into `AtvTier`, the same attribute a coin purchase writes,
	so every check downstream -- AtvServer.spawn, AtvServer.buy, the showroom's
	SPAWN/BUY state, RewardsConfig's "Own a vehicle" quest -- keeps working
	unchanged and there is exactly one definition of what a player owns.

	It bypasses the rebirth gate for free as a consequence: spawn() has never
	checked rebirths, only ownership. blockedReason is the BUYING gate and a pass
	holder never reaches it.

	SURVIVING THE TIDE IS THE ONE PLACE THAT SINGLE-DEFINITION TRICK DOES NOT
	CARRY ITSELF, and it is worth knowing why. Everything above works because a
	pass RAISES `AtvTier` and every reader just asks that attribute. The rebirth
	wipe LOWERS it, so "is this player exempt" is a question the attribute cannot
	answer about itself -- by the time you read it, it has already been written.
	ProgressionServer.onRebirth therefore asks GamePassService directly and
	writes the entitled floor rather than zero. GamePassService's own
	GetAttributeChangedSignal watcher would also put the floor back, but it fires
	deferred; the explicit write is what makes the value correct on the same
	frame. See the note at that call site.

	WHY THE ID LIVES IN A REPLICATED CONFIG. The panel has to draw a Robux button
	per bay and prompt the right purchase, and PromptGamePassPurchase is a client
	call. None of it is secret: the pass id is public the moment the button is
	drawn, and the SERVER is still the only thing that decides ownership -- it
	asks Roblox, not the client.
]]

-- Where GamePassService publishes "this player owns pass N", for the panel to
-- read. One attribute per pass; the prefix lives here so it exists once.
AtvConfig.PassAttrPrefix = "Pass_"

--[[
	THE PROMPT THE STOCK ITSELF CARRIES.

	AtvServer hangs one of these on every machine standing on a showroom plinth
	and AtvClient puts the purchase dialog up when it is triggered -- the two
	halves of "walk up to the bulldozer, get offered the bulldozer's pass". The
	names live here for the same reason the pass id above does: the client cannot
	require anything in ServerScriptService, and a tag spelled twice is a tag
	that gets corrected once.

	A TAG RATHER THAN A NAME OR A PATH. The stock is rebuilt from scratch into a
	Workspace folder at every boot and it streams like anything else out there,
	so a client looking by path is racing a model that may legitimately arrive
	minutes later. GetTagged answers about whatever exists right now, which is
	what a sweep on a timer needs.
]]
AtvConfig.PassPromptTag = "AtvPassPrompt"
-- Which machine the prompt is standing next to. The same attribute name a
-- showroom DisplayPoint carries, and for the same reason CarSpawnerBuilder
-- gives there: the tier is looked up rather than parsed out of an instance
-- name, so a renamed machine cannot orphan its own price tag.
AtvConfig.PassPromptTierAttribute = "Tier"

function AtvConfig.passOf(tier): number?
	local id = tier and tier.gamePass
	return (type(id) == "number" and id > 0) and id or nil
end

function AtvConfig.passAttribute(tier): string?
	local id = AtvConfig.passOf(tier)
	return id and (AtvConfig.PassAttrPrefix .. tostring(id)) or nil
end

-- Safe on both sides, and TRUE ONLY AS AN ANSWER, never as a permission: the
-- panel uses it to paint a button, the server uses its own MarketplaceService
-- check. A client that sets its own Pass_ attribute changes what its screen
-- says and nothing else.
function AtvConfig.ownsPass(player: Instance?, tier): boolean
	local attr = AtvConfig.passAttribute(tier)
	if not attr or typeof(player) ~= "Instance" then
		return false
	end
	return player:GetAttribute(attr) == true
end

-- Every pass in the shop, for GamePassService to sweep on join.
function AtvConfig.allPasses(): { { id: number, tier: any } }
	local list = {}
	for _, tier in AtvConfig.Tiers do
		local id = AtvConfig.passOf(tier)
		if id then
			table.insert(list, { id = id, tier = tier })
		end
	end
	return list
end

-- Highest tier this player has bought, as a definition. 0 / nil -> nil.
function AtvConfig.ownedTier(player: Player)
	return AtvConfig.tier(player:GetAttribute(AtvConfig.OwnedAttribute))
end

----------------------------------------------------------------
-- WHAT YOUR OWN UPGRADES DO TO THE MACHINE
----------------------------------------------------------------
--[[
	THE PROBLEM THIS SOLVES.

	The shop's two machines are fixed lumps of stats bought once for 75,000 and
	250,000 coins. The upgrade tracks in the Beach Shop run to level 60. So
	without this, every coin a player spent on Beach Legs or Bucket Size was
	thrown away the moment they climbed into a truck -- the truck's 31 studs/s
	replaced their 66, its 650 lb bed replaced their 2,700 lb bag. Buying an
	upgrade made the thing you drive no better, and eventually made getting IN
	one a downgrade.

	THE RULE: for each transferable stat, the machine gets the BETTER of its own
	number and yours. Nothing is ever worse than it was -- a fresh player's
	level-1 stats never drag a 250,000 coin truck down, because max() only ever
	points one way -- and past the crossover the machine keeps improving for as
	long as you keep buying levels.

	WHERE EACH ONE CROSSES OVER (Sandhog / Tidebreaker):

		speed     <- BeachLegs   26 / 31    passed at Legs    5 / 12
		hold      <- BucketSize 300 / 650   passed at Bucket 37 / 45

	THE SPEED PAIR CAME IN FROM 14 / 19 when the walking floor moved 16 -> 24
	(ProgressionConfig.BaseWalkSpeed, 2026-08-28), and it is worth knowing what
	that does and does not mean. It does NOT change what either machine runs at
	for anybody who owns one: both are rebirth-14-and-up purchases and Beach Legs
	is worth 49 by that tide, so the transfer was already carrying the speed of
	both machines long before the floor moved. What it means is that a machine's
	OWN speed is now barely a walking pace, so `speed` is not a number to sell one
	on -- the hold and the net are, and they are what climb.

	THE NET IS NOT ONE OF THEM ANY MORE. It used to transfer from the Beachcomber
	Reach track, and that track has been removed from the game -- so a machine's
	net is its own number again and there is no walker's reach to take the larger
	of. Both nets are set by art anyway (16 is the bulldozer's blade width, 20 the
	tipper's scoop), so neither was ever free to move to stay ahead of a player.

	The Bucket Size figures moved with that track's rebase (12 lbs at level 1
	rather than 20, growth 1.096 rather than 1.087) -- Sandhog was 34 and
	Tidebreaker 43. ProgressionConfig's BucketSize note carries the same pair.

	Staggered on purpose. Each machine gets two separate "my truck just got
	better" moments spread across the whole ladder, rather than one cliff.

	TURN IS NOT IN THE TABLE EITHER, and unlike the net it never was. Nothing a
	player wears or carries is a yaw rate, so there is no honest source to take
	the max of -- and turn is the one number the bulldozer beats the truck on.
	It is the Sandhog's entire character (skid steer: it pivots on the spot where
	the truck has to swing round), so leaving it alone is also what keeps the
	cheaper machine worth owning at any upgrade level.

	TURN IS BUYABLE NOW, AND THAT PARAGRAPH IS WHY IT IS BUYABLE THE WAY IT IS.
	The car ladder's Steering Rack (2026-09-18) ADDS to a machine's yaw rate
	instead of replacing it, precisely so the sentence above stays true at every
	rung: both machines gain the same 1.0 rad/s across the bar and the Sandhog is
	still ahead at the top. It is not a Transfer and it does not belong in this
	table -- there is still nothing a player WEARS that is a yaw rate. See the
	note over STEER_STEP.
]]
AtvConfig.Transfers = {
	speed = "BeachLegs",
	hold = "BucketSize",
}

--[[
	Resolved lazily, optionally, and WITHOUT latching a failure.

	This module is required by AtvServer during server boot and by AtvClient
	before the client's own Modules folder is guaranteed to have replicated, so a
	require at the top of the file would be a yield in one case and a nil index
	in the other. Retrying on each call rather than caching "not found" is what
	makes the client case work at all: the first call may genuinely be too early.

	FindFirstChild, never WaitForChild -- see above, this must not yield.
]]
local Progression = nil
local function progression()
	if Progression then
		return Progression
	end
	local modules = ReplicatedStorage:FindFirstChild("Modules")
	local module = modules and modules:FindFirstChild("ProgressionConfig")
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" and type(result.valueOf) == "function" then
			Progression = result
		elseif not ok then
			warn("[AtvConfig] ProgressionConfig present but would not load:", result)
		end
	end
	return Progression
end

----------------------------------------------------------------
-- THE CAR UPGRADE LADDER  --  bought on the machine, not on foot
----------------------------------------------------------------
--[[
	A SECOND LADDER, AND IT IS A DIFFERENT KIND OF THING FROM THE FOUR ABOVE.

	The Beach Shop's four tracks are bought on foot, capped by the tide's level
	ceiling, and WIPED BY EVERY REBIRTH. This one is none of those. It is bought
	against the machine you own, it has no tide cap, and it SURVIVES THE TIDE.

	IT NO LONGER SURVIVES FOR THE REASON IT USED TO. This paragraph read "it is
	the rule the vehicle itself already follows: `AtvTier` appears nowhere in
	ProgressionServer.onRebirth, so you keep your truck across a rebirth" -- and
	since 2026-08-24 that is FALSE. The tide wipes `AtvTier` for anybody without
	the machine's game pass; a coin-bought truck is now a per-tide purchase like
	everything else in the shop.

	What did NOT change is the argument the price is pitched on, which never
	depended on the machine: a rung here is permanent and the four-track ladder
	is rebuilt every tide, so a rung is worth many rungs of a ladder that is not.
	The rake outliving the machine it bolts to is untidy rather than wrong -- it
	is inert without one (effectiveStats only reads it for a tier being ridden)
	and it costs up to 1.73 BILLION coins, so wiping it on top of the machine
	would turn the same numbers into a wall. It waits for the next machine.

	WHY IT LIVES IN THIS FILE. Everything it needs is already here: `ownedTier`
	is the definition of owning a machine, `effectiveStats` is the one place a
	player's numbers reach a machine, and this module is replicated so the shop
	panel can draw prices off it. Putting it in ProgressionConfig instead would
	have handed it that file's three rules -- tide ceiling, rebirth wipe, `Lv_`
	prefix -- silently and by default, and all three are wrong for it. The wipe
	especially: ProgressionServer.onRebirth is an unconditional
	`for _, t in Config.Tracks`, with no exclusion list to opt out of.

	THE PREFIX IS DIFFERENT ON PURPOSE. `CarLv_`, not `Lv_`. ProgressionServer's
	applyAll and its rebirth wipe both sweep by track table rather than by prefix,
	so a shared prefix would not actually break anything today -- but the two
	ladders answer to different rules, and one grep for "Lv_" that quietly
	includes a track it should not is the kind of mistake that is invisible until
	a player loses something they paid for.

		key       what the level is stored under: CarLv_<key>
		base      the price of the FIRST rung, level 0 -> 1
		growth    per-rung multiplier. Its own dial, NOT ProgressionConfig's
		          CostGrowth: that one paces a ladder rebuilt every tide, this
		          one paces a ladder bought once and kept.
		effect    the gameplay number at a level >= 1. NEVER called with 0 --
		          see carValueOf.
]]

-- Where car levels are stored. AtvServer/ProgressionServer write `CarLv_<key>`;
-- the panel and effectiveStats read the same names through carLevelOf below, so
-- the string exists exactly once.
AtvConfig.CarAttrPrefix = "CarLv_"

--[[
	FIFTY RUNGS, UP FROM TWENTY-FIVE (2026-08), each half the old width -- the
	same bar, twice the cuts. The old ladder moved in six-million-coin,
	two-stud JUMPS: its first rung cost nearly a second Sandhog, so between
	the dozer at rebirth 14 and the truck at 22 this panel had almost nothing
	a player could actually buy, and then everything landed at once. Fifty
	one-stud rungs at 1.125 growth self-pace to a purchase roughly every
	quarter-hour of farming from rebirth 14 to the end of the run -- a rung
	or two a tide across the whole back half of the game, which is what a
	permanent ladder is for. The ENDPOINT did not move: rung 50 is the same 98.5-stud
	perf ceiling rung 25 was (see the width note below).

	SAVED LEVELS FROM THE 25-RUNG ERA ARE DOUBLED ON LOAD. SaveService's
	SCHEMA went 1 -> 2 with this change and its migrate doubles a v1 rake
	level, so a player who owned rung 7 (62.5 studs) loads as rung 14 -- the
	identical 62.5 studs. Nobody's bar narrows.
]]
AtvConfig.CarMaxLevel = 50

--[[
	HOW MANY RUNGS ONE TRACK HAS, which is no longer one number for the ladder.
	2026-09-18.

	CarMaxLevel is still the default and still the rake's own fifty. But the two
	tracks added beside it are shorter -- a steering rack stretched over fifty
	rungs would have to move a yaw rate by a fiftieth of nothing per purchase --
	so a track may name its own `ceiling`, and this is where that is read.

	MenuHud's car row ALREADY read `t.ceiling or AtvConfig.CarMaxLevel` before any
	second track existed, so the convention was half-established and honoured in
	exactly one place: the panel drew a per-track ceiling that the price curve, the
	purchase handler and the save clamp all ignored. A short track would have shown
	LV 20 MAX in the shop and gone on selling rung 21. All four go through here now.
]]
function AtvConfig.carCeiling(track): number
	local n = track and tonumber(track.ceiling)
	if n and n == n and n >= 1 then
		return math.floor(n)
	end
	return AtvConfig.CarMaxLevel
end

--[[
	LEVEL 0 IS "NOTHING FITTED", not "level one".

	Every other ladder in this game is 1-based and a missing attribute reads as
	level 1 -- which is right there, because level 1 is the tool you start the
	game holding. Here it would mean every player who buys a truck is handed the
	first rung of a six-million-coin ladder for free the moment they do. So this
	one is 0-based: 0 is a bare machine raking its own blade, and the number is
	how many rungs you have actually bought.
]]
function AtvConfig.carLevelOf(player: Instance?, key: string): number
	if typeof(player) ~= "Instance" then
		return 0
	end
	local v = player:GetAttribute(AtvConfig.CarAttrPrefix .. key)
	if type(v) ~= "number" or v ~= v then
		return 0
	end
	-- Clamped per TRACK, not per ladder -- see carCeiling. An attribute is the
	-- one input here that is not this file's own, so it is held to the track's
	-- real top rather than to the longest track's.
	return math.clamp(math.floor(v), 0, AtvConfig.carCeiling(AtvConfig.UpgradeByKey[key]))
end

--[[
	THE WIDEST SIFTER A PLAYER CAN REACH ON FOOT, read off ProgressionConfig's
	own RollerWidth curve rather than typed here as 48.5.

	This number is the whole point of the track below -- the brief was a car rake
	that goes PAST what the player's own maxed Sifter Width reaches -- so a copy
	of it in this file would be a copy of exactly the number that must not drift.
	Retune RollerWidth's curve and the rake's floor follows it.

	The fallback is for the one case progression() cannot answer: the client,
	in the window before ReplicatedStorage.Modules has replicated. It affects
	what a panel DRAWS for a few frames and never what the server charges or
	applies -- the server has had ProgressionConfig since boot.
]]
local WALKER_CEILING_FALLBACK = 48.5
function AtvConfig.walkerSifterCeiling(): number
	local config = progression()
	local track = config and config.TrackByKey and config.TrackByKey.RollerWidth
	if track and type(track.effect) == "function" and type(config.MaxLevel) == "number" then
		local ok, v = pcall(track.effect, config.MaxLevel)
		if ok and type(v) == "number" and v == v and v > 0 then
			return v
		end
	end
	return WALKER_CEILING_FALLBACK
end

-- One stud a rung, fifty rungs: 49.5 studs at the first and 98.5 at the last,
-- which is a shade over twice what a maxed walker sweeps. Halved from two studs
-- when the ladder doubled to fifty rungs (2026-08), so every purchase is a
-- visible +1 stud and the endpoint stays on the measured perf ceiling. See the
-- track's own note for why the top is where it is.
local RAKE_STEP = 1.0

--[[
	THE TWO TRACKS BELOW ARE ADDITIVE, AND THE RAKE IS NOT. 2026-09-18.

	Asked for by a rebirth-29 player: "ooo and more vehicle upgrades!
	speed/capacity/turning radius, etc." Speed already climbs -- Beach Legs
	transfers into it and is worth 66 against the best machine's 31 -- so the two
	that had nowhere to go were TURN and the hold.

	WHY NOT A THIRD ABSOLUTE LADDER LIKE THE RAKE. Because of the note over
	Transfers, which is the design this would have quietly undone:

		"turn is the one number the bulldozer beats the truck on. It is the
		Sandhog's entire character (skid steer: it pivots on the spot where the
		truck has to swing round), so leaving it alone is also what keeps the
		cheaper machine worth owning at any upgrade level."

	An absolute track starting above the best machine hands rung 1 to a
	Tidebreaker owner as a jump from 1.6 to 2.65 -- it erases the gap that note
	exists to protect, and it does it on the FIRST purchase. Adding instead keeps
	every machine's own character intact at every rung: both gain the same amount,
	the Sandhog stays exactly 1.0 rad/s ahead, and a fully-kitted Tidebreaker
	arrives at 2.6 -- which is a stock Sandhog. That is the ladder saying what the
	shop already says, rather than contradicting it.

	The rake stays absolute because it replaces a thing the machine HAS (a blade
	of a width the model decides) rather than improving a number this file owns.
	See the note over effectiveStats' loop.
]]

-- A twentieth of a radian a rung, twenty rungs: +1.0 rad/s over the bar. That
-- takes the Sandhog 2.6 -> 3.6 (149 -> 206 deg/s) and the Tidebreaker 1.6 -> 2.6
-- (92 -> 149). The top is chosen rather than measured, and honestly: there is no
-- equivalent of the rake's sweep-loop arithmetic here, because turn costs nothing
-- to compute. What bounds it is the machine staying drivable -- past about 200
-- deg/s the nimbler machine spins faster than the camera settles -- and the gap
-- above staying a gap.
local STEER_STEP = 0.05

-- 260 lbs a rung, twenty-five rungs: +6,500 lbs over the bar. Against a bare
-- Sandhog that is 300 -> 6,800; against a maxed walker's bucket (2,679, which
-- already wins the max() below by Bucket 37) it is 2,679 -> 9,179. Sized off
-- the walker rather than the machine on purpose: the bed is worth buying to
-- somebody who has levelled Bucket Size, which the machine's own 300/650 is not.
local BED_STEP = 260

AtvConfig.Upgrades = {
	{
		key = "Rake",
		-- WHICH effectiveStats FIELD THIS TRACK FEEDS. Named rather than assumed:
		-- the loop down there used to write `sweepWidth` for whatever it found in
		-- this table, so the first track added beside the rake would have silently
		-- overwritten the rake's width with a yaw rate.
		stat = "sweepWidth",
		name = "Beach Rake",
		blurb = "A towed sifter bar, far wider than the machine that pulls it.",
		tint = Color3.fromRGB(255, 196, 92),   -- Sifter Width's colour: same job, bigger
		suffix = " studs",
		decimals = 1,
		--[[
			SIX HUNDRED THOUSAND FOR THE FIRST RUNG, growing at 1.125 to 191M
			for the last, and 1.73 BILLION for the whole bar -- re-pitched
			2026-08b when the 4x shop and the time-authored gates moved every
			income figure in the game.

			THE OLD SHAPE WAS SIX-MILLION-COIN JUMPS. Rung 1 cost nearly a
			second machine, so this panel sat dead from the dozer's gate until
			deep in the twenties, then paid out all at once. Fifty rungs at
			1.125 self-pace instead -- measured against EconomyAudit's income
			model (the one that knows what a player can actually afford of the
			4x foot ladder), a rung costs roughly a quarter-hour of farming
			from the dozer's gate to the last tide:

				rung        price      ~minutes of farming, at rebirth
				   1      600,000      22 at 14, 13 by 16
				  10    1,740,000      16 at 20
				  20    5,630,000      20 at 23
				  30   18,300,000      15 at 29
				  40   59,600,000      14 at 33
				  50  191,000,000      16 at 37

			-- a rung or two a tide across the entire back half of the game.

			COINS ARE WIPED BY A REBIRTH, and that is the gate rather than any
			rebirth check written here: a rung has to be affordable out of ONE
			tide's earnings or it cannot be bought at all. Growth must stay
			BELOW income's own growth per tide (~1.27-1.31x for the whole back
			half) or the ladder gets further out of reach with every rung
			bought -- 1.125 clears that everywhere. It is deliberately the
			shallowest price curve in the game: this ladder's job is a steady
			drip of buyable things, not a wall.
		]]
		base = 600000,
		growth = 1.125,
		--[[
			WHERE THE TOP IS, AND WHY IT IS NOT HIGHER.

			98.5 studs is 24 grid cells of a 64-cell beach -- a bit over a third of
			it in one pass. Two things set that ceiling and both are measured:

			THE SWEEP LOOP. CTB_Server walks an AXIS-ALIGNED box around a ROTATED
			band, so its cost is quadratic in width while what it actually rakes
			grows only linearly. Cell tests per tick, worst heading, run against
			that loop's own arithmetic on the beach grid (Tidebreaker footprint,
			24 Hz, per DRIVING player):

				walker on foot, Sifter Width 60      120
				machine on its bare blade            100
				machine + a maxed walker, TODAY      256
				machine + rake L1  (50.5)            256   <- costs nothing new
				machine + rake L13 (74.5)            440
				machine + rake L25 (98.5)            624

			So the finished bar is 2.4x a path the game ALREADY runs for any
			well-levelled player who climbs into a truck, and the first rung is
			free: at half a cell either side it lands in the same span. 624 a tick
			is 15,000 a second against 6,100 today, and `g.clean[idx]` throws most
			of them out on its first line.

			The grid clamp bounds the absolute worst case at the field itself
			(4,096 cells on the beach, 6,400 on Ashfall). Doubling the width again
			would roughly quadruple the count, and by about 320 studs the loop
			scans a whole island every tick however little is under the machine.

			THE PICTURE. AtvBuilder draws the bar at exactly this width, and a rake
			sticking forty-two studs out of each side of a thirty-stud truck is
			already at the edge of reading as a machine rather than as a bug.

			The rung SIZE is the other half of this. Two studs is half a grid cell,
			so a single rung does not always add a column of cells on a given pass
			-- what it buys is about 4% more sand at the bottom of the bar and 2% at
			the top, in expectation, which is real but is not a step you can see.
			Bigger rungs would be more legible and there would be fewer of them;
			twenty-five is chosen for the pacing (see `base`) rather than for that.
		]]
		effect = function(level: number): number
			return AtvConfig.walkerSifterCeiling() + level * RAKE_STEP
		end,
	},

	{
		key = "Steering",
		stat = "turn",
		-- ADDED to the machine's own yaw rate, never substituted for it. See the
		-- note over STEER_STEP for why this one cannot be absolute.
		combine = "add",
		-- So the shop draws "+0.25 turn" rather than "0.25 turn", which would read
		-- as the whole of a number that is in fact a bonus on top of two different
		-- machines' very different ones.
		plus = true,
		name = "Steering Rack",
		-- Kept to the length of the rake's, which is what the row can actually
		-- draw: the blurb label is 368px at 13pt and TextTruncate is AtEnd, so a
		-- longer line does not wrap, it just stops with an ellipsis.
		blurb = "Bites harder at full lock. Adds to your machine's own turn.",
		-- The Sandhog's own colour: this is the stat that IS the bulldozer, and the
		-- track exists to sell more of it rather than to hand it to the truck.
		tint = Color3.fromRGB(232, 176, 44),
		suffix = " turn",
		decimals = 2,
		--[[
			TWENTY RUNGS, NOT FIFTY. The rake's fifty exist because a stud is a
			visible thing to be handed and there are a hundred of them to give away;
			turn has one radian a second of room in total, and split fifty ways that
			is 0.02 a purchase -- a rung nobody could feel. Twenty at 0.05 is the
			coarsest this can be while still being a ladder rather than a switch.

			900,000 AT 1.17 puts the first rung a little above the rake's and the
			last at 17,800,000, with 117,000,000 for the whole bar -- a fifteenth of
			the rake, which is right: this is a handling upgrade beside the thing
			that decides how much beach you clear. Growth stays well under income's
			own ~1.27-1.31x per tide, which is the constraint the rake's price note
			sets out and the only hard rule on this ladder.
		]]
		base = 900000,
		growth = 1.17,
		ceiling = 20,
		effect = function(level: number): number
			return level * STEER_STEP
		end,
	},

	{
		key = "Bed",
		stat = "hold",
		-- ADDED, on top of whatever already won the max() in effectiveStats -- the
		-- machine's own bed or the player's Bucket Size, whichever is larger. An
		-- absolute track here would be worth nothing to a maxed walker until it
		-- passed 2,679 and a cliff to everybody else the rung it did.
		combine = "add",
		plus = true,
		name = "Cargo Bed",
		blurb = "Raises the sides. Carries more between trips to the scales.",
		-- Bucket Size's colour, for the same reason the rake wears Sifter Width's:
		-- same job, past where the foot ladder stops.
		tint = Color3.fromRGB(255, 150, 108),
		suffix = " lbs",
		--[[
			TWENTY-FIVE RUNGS AT 1,200,000 AND 1.15, so the last is 34,400,000 and
			the bar is 255,000,000 -- between the steering rack and the rake, which
			is where it belongs: hold is the stat this whole ladder is built around
			("THE LADDER IS ABOUT WHAT YOU CARRY, NOT HOW FAST YOU GO", at the top of
			this file) but the rake is what earns the load in the first place.

			IT DOES NOT UNDERCUT BUCKET SIZE, which was the thing to check. The
			vehicle hold only exists while you are in the seat -- VehicleHold clears
			HoldMaxAttribute on dismount -- so the bag on your back is still the only
			thing that moves a load to the scales, and Bucket Size is still what
			sizes a single unload.
		]]
		base = 1200000,
		growth = 1.15,
		ceiling = 25,
		effect = function(level: number): number
			return level * BED_STEP
		end,
	},
}

AtvConfig.UpgradeByKey = {}
for _, t in AtvConfig.Upgrades do
	AtvConfig.UpgradeByKey[t.key] = t
end

--[[
	What it costs to go from `level` to `level + 1`. nil at the top of the ladder,
	and callers use that nil as "fully upgraded" -- so it must stay nil rather than
	becoming a very large number.

	Rounded to three significant figures through ProgressionConfig's own `tidy`,
	for the reason that file gives: a geometric curve produces 319,428,117 and a
	shop button reading that is neither readable at a glance nor plannable
	against. Borrowed rather than copied -- a second rounding rule here would be a
	second place for prices to be shaped differently. math.floor is the fallback
	for the pre-replication window only; see walkerSifterCeiling.
]]
function AtvConfig.carCostFor(track, level: number): number?
	if type(track) ~= "table" or type(level) ~= "number" or level ~= level then
		return nil
	end
	if level >= AtvConfig.carCeiling(track) then
		return nil
	end
	local config = progression()
	local round = (config and type(config.tidy) == "function") and config.tidy or math.floor
	return round((track.base or 1e6) * ((track.growth or 1.2) ^ math.max(0, level)))
end

-- The gameplay number this player's car level is worth right now, or NIL if they
-- have not fitted this one -- which is not the same as zero and must not read as
-- it. Nil is "the machine's own number stands"; every caller takes the larger of
-- the two, and a zero would win a max() against nothing.
function AtvConfig.carValueOf(player: Instance?, key: string): number?
	local track = AtvConfig.UpgradeByKey[key]
	if not track then
		return nil
	end
	local level = AtvConfig.carLevelOf(player, key)
	if level <= 0 then
		return nil
	end
	return track.effect(level)
end

--[[
	Does this player own a machine at all -- the one gate on the whole ladder.

	Defined HERE, next to OwnedAttribute and ownedTier, because it is the same
	question those two answer and there was no exported form of it: AtvServer's
	`ownedTierId` is a file-local, so the shop panel and the purchase handler
	would otherwise each have grown their own copy of the attribute read.

	TRUE FROM A GAME PASS TOO, for free and without a second rule: a pass writes
	its tier's id straight into AtvTier (see THE GAME PASSES above), so anything
	phrased in terms of that attribute already covers both ways of owning one.
]]
function AtvConfig.ownsMachine(player: Instance?): boolean
	if typeof(player) ~= "Instance" then
		return false
	end
	local n = player:GetAttribute(AtvConfig.OwnedAttribute)
	return type(n) == "number" and n > 0 and AtvConfig.tier(math.floor(n)) ~= nil
end

--[[
	The numbers this machine should actually run at for this player.

	Returns a fresh table every call -- callers hold on to it (AtvServer keeps
	one per ride) and a shared table would have one player's truck re-tuned by
	another player's purchase.

	`upgraded` marks which fields came from the player rather than the machine,
	so the showroom and the dashboard can say so. That flag is the whole reason
	the feature is visible: a stat that silently got better is a stat the player
	never learns they are being rewarded for.

	Safe on both sides. It reads only replicated player attributes and pure
	config, and the SERVER calls it again for itself before anything is applied
	-- a client that lies to its own copy changes only what its own screen says.
]]
function AtvConfig.effectiveStats(player: Instance?, tier)
	local stats = {
		netRadius = (tier and tier.netRadius) or 0,
		speed = (tier and tier.speed) or 0,
		turn = (tier and tier.turn) or 0,
		hold = AtvConfig.holdOf(tier),
		upgraded = {},
		-- Which fields came off the CAR ladder specifically. `upgraded` already
		-- says "the player, not the machine" and stays true for these too -- a
		-- bought rake is as much the player's as a bought Beach Legs -- but the two
		-- ladders answer to different rules and a caller that needs to tell them
		-- apart had no way to.
		fitted = {},
	}
	if not tier or typeof(player) ~= "Instance" then
		return stats
	end

	local config = progression()
	if not config then
		return stats
	end

	for field, trackKey in AtvConfig.Transfers do
		local personal = config.valueOf(player, trackKey)
		if type(personal) == "number" and personal == personal and personal > stats[field] then
			stats[field] = personal
			stats.upgraded[field] = true
		end
	end

	--[[
		THE RAKE, AND IT IS NOT A TRANSFER.

		Everything above takes the LARGER of the machine's number and one the
		player bought on foot. This is the other direction: a track that exists
		only because you own a machine, whose whole purpose is to go past what
		anything on foot can reach. So it is read straight rather than through
		Transfers, and it is left NIL when nothing is fitted.

		Nil, not the machine's own width, because this function does not know
		what that is -- SweepWidth is measured off the model the builders
		actually built (a mesh blade, a drawn scoop mouth) and is stamped on the
		model, not tabled per tier. Repeating it here would be a second copy of
		a number nobody would remember to move. AtvServer takes the max against
		the built figure it captured at spawn.
	]]
	--[[
		TWO WAYS A CAR TRACK COMBINES, AND THE TRACK SAYS WHICH.  2026-09-18.

		This loop used to write `stats.sweepWidth` for every entry in Upgrades,
		which was correct while the rake was the only one and silently wrong the
		moment it was not: a steering rack would have overwritten the rake's width
		with a yaw rate, and which of them survived would have fallen to table
		order. Each track names its `stat` now.

		REPLACE (the rake) is for a track that stands in for something the MACHINE
		has -- a blade of a width the model decides -- so the larger of the two
		wins and nothing is claimed when the fitted one is smaller.

		ADD (steering, bed) is for a track that improves a number this file owns.
		It goes on top of whatever already won above, which for `hold` is the max
		of the machine's bed and the player's Bucket Size. That ordering is why
		this loop runs AFTER the Transfers loop and not before it.
	]]
	for _, track in AtvConfig.Upgrades do
		local fitted = AtvConfig.carValueOf(player, track.key)
		if type(fitted) == "number" and fitted == fitted and fitted > 0 then
			local field = track.stat or "sweepWidth"
			local applied = false
			if track.combine == "add" then
				stats[field] = (tonumber(stats[field]) or 0) + fitted
				applied = true
			elseif type(stats[field]) ~= "number" or fitted > stats[field] then
				stats[field] = fitted
				applied = true
			end
			if applied then
				stats.upgraded[field] = true
				stats.fitted[field] = true
			end
		end
	end

	return stats
end

--[[
	The player attributes a machine has to watch to stay current.

	Handed out from here rather than assembled at the call site so the "Lv_"
	prefix lives in exactly one file -- ProgressionConfig's -- and a rename there
	cannot leave AtvServer silently listening to attributes that no longer exist.
	Silently: an attribute that is never written fires no signal and throws no
	error, so the failure mode is "upgrades stopped reaching my truck" with
	nothing in the output.
]]
function AtvConfig.transferAttributes(): { string }
	local config = progression()
	local prefix = (config and config.AttrPrefix) or "Lv_"
	local names = {}
	for _, trackKey in AtvConfig.Transfers do
		table.insert(names, prefix .. trackKey)
	end
	-- The car ladder goes in the SAME list, and that is what makes a rake bought
	-- from the driving seat appear on the machine without AtvServer knowing this
	-- ladder exists. Its watcher loop is written against this function precisely
	-- so the set of things worth watching stays a property of the config.
	for _, track in AtvConfig.Upgrades do
		table.insert(names, AtvConfig.CarAttrPrefix .. track.key)
	end
	return names
end

-- Everything standing between a player and this tier, or nil if nothing is.
function AtvConfig.blockedReason(player: Player, tier, coins: number, rebirths: number): string?
	if not tier then
		return "No such machine."
	end
	if rebirths < tier.minRebirths then
		return string.format("Needs %d rebirth%s.", tier.minRebirths,
			tier.minRebirths == 1 and "" or "s")
	end
	if coins < tier.price then
		return string.format("Need %d more coins.", tier.price - coins)
	end
	return nil
end

return AtvConfig
