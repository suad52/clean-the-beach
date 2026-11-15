--[[
	WeightConfig  --  ReplicatedStorage.WeightSystem.WeightConfig

	Shared tuning for the weight-based collection + dynamic storage system.

	WHY THIS IS SHARED
	------------------
	The client has to answer "will this fit?" to decide what to walk over and
	what to leave behind, and the server has to answer the same question to
	decide what it actually hands out. Both sides call the SAME function here,
	so the two answers can never disagree and a mispredicting client is
	impossible rather than merely unlikely.

	Nothing in here is secret: it is fine for a client to know a tyre weighs 10
	lbs. What it must not do is decide how much it is carrying -- that number
	lives only in ServerScriptService.WeightSystem.WeightService, and only the
	server ever writes it.

	THIS FILE ADDS NOTHING TO THE EXISTING GAME'S FILES. It is a parallel
	config; ReplicatedStorage.CTB.Config and ReplicatedStorage.Modules.*
	are untouched.
]]

local CollectionService = game:GetService("CollectionService")
-- Only for the optional ProgressionConfig lookup at the bottom of this file.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeightConfig = {}

WeightConfig.Unit = "lbs"

-- Floating point slack for every capacity comparison. Weights are rounded to
-- 3dp on the way in, so anything below this is noise, never a real overflow.
WeightConfig.EPSILON = 1e-4

----------------------------------------------------------------
-- WHERE COLLECTIBLES LIVE
----------------------------------------------------------------
-- Two equivalent ways to mark a piece of trash as collectible:
--   1. put it in Workspace.Trash (directly, or inside any Folder in there)
--   2. tag it with CollectibleTag anywhere in Workspace
-- The folder route is what a builder placing props wants; the tag route is
-- what a spawner wants. TrashCollectionService tags everything it registers
-- either way, so the client only ever has to watch one tag.
--
-- Only the TOP instance counts: a Model in Trash registers as one collectible,
-- its child parts do not. That is what stops a 12-part tyre model being twelve
-- separate pickups.
WeightConfig.TrashFolderName = "Trash"
WeightConfig.CreateTrashFolder = true          -- server makes an empty one on boot
WeightConfig.CollectibleTag = "CollectibleTrash"

WeightConfig.WeightAttribute = "Weight"        -- the number this whole system runs on
WeightConfig.ItemIdAttribute = "ItemId"        -- optional, maps into Modules.ItemConfig
WeightConfig.LabelAttribute = "DisplayName"    -- optional, purely cosmetic

----------------------------------------------------------------
-- CAPACITY  (the "dynamic storage" half)
----------------------------------------------------------------
WeightConfig.CurrentWeightAttribute = "CurrentWeight"
WeightConfig.MaxWeightAttribute = "MaxWeight"
-- How much of the current load is CRUSTED, i.e. cannot be sold until it has
-- been washed. Published so the HUD can explain why standing on the sell pad
-- does not empty you out -- without it, leftover weight reads as a bug.
WeightConfig.CrustedWeightAttribute = "CrustedWeight"

WeightConfig.BaseMaxWeight = 20

-- Dynamic capacity belongs to the BUCKET SIZE upgrade track -- the one whose
-- whole description is "carry more before you have to sell". ProgressionServer
-- calls setMaxWeight on every purchase, respawn and rebirth; this ladder is
-- the same one ProgressionConfig's BucketSize effect returns, so the two agree
-- even before that call lands (a player at level 3 starts at 42, not at 20
-- until they next buy something).
--
-- This used to follow RollerLevel, which double-dipped: a wider roller is a
-- wider roller, not a bigger bucket, and Bucket Size existed to do this job.
WeightConfig.ScaleWithLevel = true
WeightConfig.CapacityLevelAttribute = "Lv_BucketSize"

--[[
	A FALLBACK, NOT THE LADDER -- and it used to be the ladder, which was a bug
	waiting for the track to get longer than six.

	This module WATCHES Lv_BucketSize itself (see WeightService's ledger conns)
	and re-derives capacity whenever it changes. ProgressionServer also calls
	setMaxWeight from applyAll on the same purchase. Attribute signals are
	deferred, so the watcher runs SECOND and wins -- meaning whatever this table
	says is the number the player actually gets, no matter what applyAll passed.

	While both ladders were six long and identical, that was invisible. With
	ProgressionConfig's BucketSize now running to level 60, a clamped six-entry
	table would have quietly capped every bag in the game at 100 lbs -- the
	player buys level 34, applyAll sets 305 lbs, and a deferred signal puts it
	back to 100 a frame later. That is the exact shape of the "full at 13 / 20
	lbs" bug this system was built to end.

	So CapacityCurve below takes over when ProgressionConfig is installed, and
	this table is only what a place WITHOUT it falls back to.
]]
WeightConfig.CapacityPerLevel = { 20, 30, 42, 56, 75, 100 }

--[[
	Set at the bottom of this file if ReplicatedStorage.Modules.ProgressionConfig
	exists. Resolved OPTIONALLY and by search rather than by require-at-the-top,
	so the weight system still drops into a place that has no progression module
	-- the same contract ProgressionServer and VehicleHold keep in the other
	direction when they reach for WeightService.
]]
WeightConfig.CapacityCurve = nil

--[[
	THE VEHICLE HOLD  --  a SECOND storage, not a bigger bag

	Every machine in the car spawner carries its own cargo box. While you are
	sitting in one, everything the net sweeps goes in THERE and not into the bag
	on your back; you then unload the machine into your bag a bagful at a time
	and walk that to the scales.

	So these two are the hold OF THE MACHINE YOU ARE RIDING, and they are 0 when
	you are on foot -- which is exactly what makes them usable as the "which
	store is filling right now" switch that freeFor() below is. A parked
	machine's contents are not published here; they are written on its own
	unload prompt, where the player is looking when they need the number.

	This replaced a HaulBonus attribute that simply ADDED to the player's bag.
	That made a vehicle a bigger rucksack, which is not what a truck is.
]]
WeightConfig.HoldLoadAttribute = "VehicleLoad"
WeightConfig.HoldMaxAttribute = "VehicleMax"

----------------------------------------------------------------
-- WHAT THINGS WEIGH
----------------------------------------------------------------
-- Resolution order, first hit wins:
--   1. the instance's Weight attribute      (authoritative, set per prop)
--   2. WeightByItemId[ItemId attribute]
--   3. WeightByName[instance name]
--   4. DefaultItemWeight
WeightConfig.DefaultItemWeight = 1
WeightConfig.MinItemWeight = 0.01
WeightConfig.MaxItemWeight = 999

-- Keyed to the seven ids in ReplicatedStorage.CTB.Config / Modules.ItemConfig.
-- Encased finds come up as anonymous lumps: ItemConfig withholds their id from
-- the client until the crust is off, so nothing this system draws may name them
-- either. Mirrors ItemConfig's Encased flag; kept as a plain set so WeightConfig
-- stays standalone and does not have to require ItemConfig.
WeightConfig.EncasedItemIds = {
	-- The BEACH set: every id ItemConfig marks Encased, i.e. everything from
	-- Rare up. This list used to read Glasses/Watch/Phone, which had drifted
	-- twice over: Glasses is loose now (1 in 47) and twenty-five ids that DO come
	-- up as lumps were missing, so their billboards named the prize out loud.
	Starfish = true,
	Lure = true,
	Driftwood = true,
	MessageBottle = true,
	Coin = true,
	Keys = true,
	Watch = true,
	Compass = true,
	Headphones = true,
	Snorkel = true,
	Phone = true,
	Wallet = true,
	Boombox = true,
	Binoculars = true,
	GoldRing = true,
	Bracelet = true,
	Anchor = true,
	Camera = true,
	Necklace = true,
	Pearl = true,
	GoldBar = true,
	Skull = true,
	Trident = true,
	Diamond = true,
	Rolex = true,
	Chest = true,
	Crown = true,
	Meteorite = true,

	-- The desert's crusted half. Same masking rule and the same reason: a
	-- billboard reading "Gold Cartouche" over a lump gives away exactly what the
	-- sifting bay exists to reveal.
	PapyrusScrap = true,
	WadjetAmulet = true,
	ScribePalette = true,
	BronzeSickle = true,
	BastetIdol = true,
	ObsidianBlade = true,
	TurquoiseScarab = true,
	GoldCartouche = true,
	FalconPendant = true,
	LapisCollar = true,
	RoyalSealRing = true,
	SolarBarque = true,
	SphinxFragment = true,

	-- Ashfall Isle's crusted half, same masking rule for the third time.
	ObsidianFlake = true,
	HikersCompass = true,
	AshFulgurite = true,
	SulphurCrystal = true,
	ScaldedThermos = true,
	VolcanicBomb = true,
	PelesHair = true,
	PeridotNodule = true,
	LavaTubePearl = true,
	ObsidianMirror = true,
	EmberOpal = true,
	AshcastIdol = true,
	CalderaCrown = true,
	FirebirdPlume = true,
	HeartOfAshfall = true,

	-- Sakura Cove's crusted half, same masking rule for the fourth time.
	Geta = true,
	Furin = true,
	Kokeshi = true,
	Ofuda = true,
	KitsuneMask = true,
	Tenugui = true,
	Netsuke = true,
	RakuBowl = true,
	InroCase = true,
	SuzuBell = true,
	Tsuba = true,
	MakieBox = true,
	Magatama = true,
}
WeightConfig.LumpLabel = "Crusted Lump"

WeightConfig.WeightByItemId = {
	-- Fallbacks for HAND-PLACED beach props only. A prop that TrashSeeder built
	-- carries its own Weight attribute straight off ItemConfig, and resolveWeight
	-- takes the attribute first, so these are what a bare Model dragged into
	-- Workspace.Trash gets.
	--
	-- The rest of the loose beach set is deliberately NOT listed. Its lightest
	-- entries are a 0.05 lb bottle cap and straw, and lightestCollectable takes
	-- the MINIMUM across this table -- so naming them here would drop the roller's
	-- stop threshold from half a pound to a twentieth of one, on all four fields,
	-- and the sifter would keep turning up finds that bounce out of a full bag.
	-- That is the same trap the tomb and desert blocks below are written around.
	Can = 1,
	Bottle = 2,
	Shell = 1,

	-- Every ENCASED find weighs the same, deliberately. ItemConfig already
	-- gives every lump the same chunk count and the same outer size so that
	-- neither counting nor eyeballing gives it away; weight is the third way to
	-- tell them apart and has to be closed too. It is a rock of crust either
	-- way -- and CrustedWeight is a player attribute the client can read, so
	-- distinct weights meant one lump in the bag named itself.
	--
	-- Mirrors ItemConfig's LUMP_WEIGHT; that file is the authority.
	Starfish = 2,
	Lure = 2,
	Driftwood = 2,
	MessageBottle = 2,
	Coin = 2,
	Keys = 2,
	Watch = 2,
	Compass = 2,
	Headphones = 2,
	Snorkel = 2,
	Phone = 2,
	Wallet = 2,
	Boombox = 2,
	Binoculars = 2,
	GoldRing = 2,
	Bracelet = 2,
	Anchor = 2,
	Camera = 2,
	Necklace = 2,
	Pearl = 2,
	GoldBar = 2,
	Skull = 2,
	Trident = 2,
	Diamond = 2,
	Rolex = 2,
	Chest = 2,
	Crown = 2,
	Meteorite = 2,

	-- The tomb set. These are found ONLY on the treasure chamber's floor and are
	-- never crusted, so unlike the three above they are allowed to weigh what
	-- they look like -- a gold mask should be a decision about whether to keep
	-- raking or walk to the Scales, and nothing about them is secret.
	--
	-- Same numbers as ItemConfig's lbs column; that file's TOMB block is the
	-- authority and this mirrors it, the same way EncasedItemIds above does.
	-- Nothing here goes below 0.5: lightestCollectable takes the MINIMUM of this
	-- table, and CTBBridge.hasRoom stops the roller at it, so one very light
	-- vault trinket would move that threshold for both beaches too.
	FaienceBead = 0.5,
	ClayUshabti = 1.5,
	BronzeAnkh = 1,
	ScarabSeal = 0.5,
	AlabasterJar = 3,
	GoldenAnkh = 1.5,
	CanopicJar = 4,
	EyeOfHorus = 0.8,
	PectoralCollar = 2,
	SolarDisc = 3.5,
	PharaohMask = 5,
	SunKingScepter = 4,
	SunKingCrown = 3,

	-- The DESERT set (Config.DUNE_ITEMS). Unlike the tomb's these follow the
	-- normal crusting rule, so the table splits in two the way the beach's does:
	-- the loose ones weigh what they look like, and every CRUSTED one weighs the
	-- same 2 lb for the identity reason spelled out above the beach block.
	--
	-- Same numbers as ItemConfig's lbs column; that file's DUNE block is the
	-- authority and this mirrors it. Nothing here is under 0.5 for the
	-- lightestCollectable reason given on the tomb block -- these are on a field
	-- the roller works, so a 0.2 lb potsherd would have moved the threshold that
	-- stops the sifter on all four.
	Potsherd = 0.5,
	MudBrick = 1.5,
	PalmFrond = 0.5,
	FrayedRope = 0.5,
	BleachedBone = 1,
	ReedBasket = 0.8,
	ClayLamp = 0.7,
	KohlVial = 0.5,
	CopperPin = 0.5,

	PapyrusScrap = 2,
	WadjetAmulet = 2,
	ScribePalette = 2,
	BronzeSickle = 2,
	BastetIdol = 2,
	ObsidianBlade = 2,
	TurquoiseScarab = 2,
	GoldCartouche = 2,
	FalconPendant = 2,
	LapisCollar = 2,
	RoyalSealRing = 2,
	SolarBarque = 2,
	SphinxFragment = 2,

	-- ASHFALL ISLE (Config.ASH_ITEMS). Same split as the desert's above: the
	-- loose ones weigh what they look like, every crusted one weighs the same
	-- 2 lb so a lump in the bag cannot name itself, and nothing is under 0.5 --
	-- lightestCollectable takes the MINIMUM of this table and CTBBridge.hasRoom
	-- stops the roller at it, on all five fields at once.
	--
	-- Same numbers as ItemConfig's lbs column; that file's ASH block is the
	-- authority and this mirrors it.
	PumiceChunk = 0.6,
	ScoriaChunk = 0.6,
	ScorchedPlank = 1.2,
	AshedCan = 0.6,
	CinderClinker = 0.7,
	MeltedVisor = 0.5,
	GlassTear = 0.5,
	BlackSeaGlass = 0.5,
	BasaltChip = 1.4,
	FrayedGuyLine = 0.5,
	TrailWrapper = 0.5,
	VentCap = 0.9,
	BurstFloat = 0.8,
	AshGlazedShard = 0.5,
	CrackedFin = 0.7,

	ObsidianFlake = 2,
	HikersCompass = 2,
	AshFulgurite = 2,
	SulphurCrystal = 2,
	ScaldedThermos = 2,
	VolcanicBomb = 2,
	PelesHair = 2,
	PeridotNodule = 2,
	LavaTubePearl = 2,
	ObsidianMirror = 2,
	EmberOpal = 2,
	AshcastIdol = 2,
	CalderaCrown = 2,
	FirebirdPlume = 2,
	HeartOfAshfall = 2,

	-- Sakura Cove's loose half. Nothing under 0.5: lightestCollectable takes the
	-- MINIMUM across the whole catalogue and CTBBridge.hasRoom stops the roller
	-- at it, so one very light paper fan would retune every field in the game.
	Chopsticks = 0.5,
	PaperCup = 0.5,
	SquidSkewer = 0.5,
	OnigiriWrap = 0.5,
	RamenLid = 0.5,
	GachaCapsule = 0.5,
	PaperFan = 0.5,
	SakeCap = 0.5,
	CharmStrap = 0.5,

	-- ...and its crusted half, all at LUMP_WEIGHT like every other lump.
	Geta = 2,
	Furin = 2,
	Kokeshi = 2,
	Ofuda = 2,
	KitsuneMask = 2,
	Tenugui = 2,
	Netsuke = 2,
	RakuBowl = 2,
	InroCase = 2,
	SuzuBell = 2,
	Tsuba = 2,
	MakieBox = 2,
	Magatama = 2,
}

-- Keyed to the prop names already sitting in ReplicatedStorage.CTB.Litter, so
-- a builder can drag one of those meshes straight into Workspace.Trash and it
-- has a sane weight with no attribute set at all.
WeightConfig.WeightByName = {
	["Crushed Soda Can 1"] = 1,
	["Pop Can 01a"] = 1,
	["Pop Can 02a"] = 1,
	["Pop Can 03a"] = 1,
	["Metal Can 2"] = 1,
	["Plastic Bottle 1"] = 2,
	["Plastic Bottle 2"] = 2,
	["Plastic Bottle 3"] = 2,
	["Glass Bottle 1a"] = 3,
	["Glass Bottle 3"] = 3,
	["Milk Carton 1"] = 2,
	["Milk Carton 2"] = 2,
	["Milk Carton 02a"] = 2,
	["Takeout Carton 1"] = 2,
	["Coffee Cup 1"] = 1,
	["Soda Cup 1"] = 1,
	["French Fry Container"] = 1,
	["Fast Food Container"] = 2,
	["Pizzabox 01a"] = 3,
	["Garbage Bag 1"] = 6,
	["Shoe 1"] = 2,
	["Plastic Bucket 01a"] = 5,
}

----------------------------------------------------------------
-- PICKUP
----------------------------------------------------------------
--[[
	WALKING IS THE ONLY WAY TO COLLECT. There is no pickup key and no pickup
	prompt -- see WeightClient's header for why they went.

	AutoCollect is therefore load-bearing rather than a convenience toggle:
	turning it off does not fall back to a key, it stops collection dead.

	AutoCollectRadius was 8 while the prompt reached 14, and TrashSeeder lays
	90 props over a 105 stud radius -- about 20 studs apart. Most litter
	therefore lived in the 8-to-14 band: close enough to be advertised, too far
	to ever be swept, so it sat on the sand as the player walked past it. One
	number now, and it is the wider one.

	The server needs no change to match: its range gate is
	max(ManualPickupRadius, AutoCollectRadius) + ServerRangeTolerance, which
	was already 20 studs.

	AutoCollectRadius is the walker's reach, flat. Every player on foot sweeps
	the same 14 studs; nothing in the shop widens it.
]]
WeightConfig.AutoCollect = true          -- walking over a piece that fits takes it
WeightConfig.AutoCollectRadius = 14
WeightConfig.ManualPickupRadius = 14     -- kept: the server sizes its range gate off it
WeightConfig.ServerRangeTolerance = 6    -- slack the server allows for latency

-- Riding an ATV widens the sweep to the net's reach. AtvServer writes this
-- attribute and clears it the moment the player gets off; BOTH sides read it
-- through reachFor below, so the client never claims a reach the server has not
-- also granted.
WeightConfig.NetRadiusAttribute = "NetRadius"

WeightConfig.ClientScanInterval = 0.1    -- seconds between proximity sweeps
WeightConfig.ClientRequestSpacing = 0.15 -- min gap between two requests
WeightConfig.ClientRequestTimeout = 1.0  -- give up waiting on a reply after this
WeightConfig.ClientRetryDelay = 2.0      -- retry a refused item after this

-- How many items ONE auto-collect sweep may ask for.
--
-- This was implicitly 1: scan() nominated the nearest eligible item and nothing
-- else, which starves whatever you have already walked past -- its distance
-- grows every tick while the litter ahead of you shrinks, so it never wins
-- "nearest" again and leaves the radius uncollected. On an ATV the net reaches
-- 46 studs at 80 studs/s and one item per sweep could not keep up at all.
--
-- 12 clears any realistic clump in a single sweep. It bounds what one remote
-- fire can ask for; it is NOT a trust boundary, because the server range-checks
-- and weight-checks every item in a batch independently, exactly as it did when
-- a request could only ever name one thing.
WeightConfig.MaxAutoBatch = 12

-- Server-side token bucket. Sized well above what the client above can
-- produce, so honest play never trips it and a spammed remote goes nowhere.
WeightConfig.MaxRequestsPerSecond = 12
WeightConfig.RequestBurst = 8

----------------------------------------------------------------
-- RESPAWNING
----------------------------------------------------------------
-- Collected items are parked in ServerStorage rather than destroyed, so the
-- beach refills itself and a hand-placed prop is never lost. Set
-- RespawnEnabled = false to destroy on pickup instead.
WeightConfig.RespawnEnabled = true
WeightConfig.RespawnDelay = 25

----------------------------------------------------------------
-- INVENTORY LINK  --  WEIGHT REPLACES SLOTS
----------------------------------------------------------------
-- When ReplicatedStorage.Modules.InventoryController is present, every
-- collected item is added to THAT array -- the one the sifting station, the
-- sell pad and CTB_HUD all already read. Weight is then the ONE thing that
-- decides what a player can carry.
--
-- The base game's 10-slot cap is LIFTED at runtime, through the inventory's
-- own public SetMaxCapacity method. GameConfig.Inventory.MaxCapacity is left
-- exactly as it was written, so nothing else that reads it changes meaning and
-- putting the slot cap back is one boolean, not a revert.
--
-- InventorySlotCap is a ceiling that cannot be reached in play rather than a
-- design number: at the default 20 lb capacity and a 0.5 lb lightest item, the
-- most a player could physically hold is 40.
--
-- With the link on, weight is freed automatically when items are sold,
-- because WeightService reconciles against that same array every flush.
WeightConfig.LinkToInventory = true
WeightConfig.OverrideInventorySlots = true
WeightConfig.InventorySlotCap = 9999
WeightConfig.DefaultItemId = "Can"       -- used when a prop carries no ItemId
WeightConfig.RefuseUnknownItems = false  -- true = refuse instead of falling back

----------------------------------------------------------------
-- MESSAGES  (client-side text; the server only ever sends a reason code)
----------------------------------------------------------------
-- The bottom-left LOAD pill this system draws for itself. OFF, because both of
-- the game's existing panels now report the same number: CTB_HUD's bag panel
-- reads "LOAD 15 / 20 lbs" and InventoryHud's header reads "CARRYING 15 / 20
-- lbs", and a third copy in the corner is clutter, not information. Turn it on
-- if you ever point those panels back at slots.
WeightConfig.ShowLoadPill = false

-- Publishes ServerStorage.WeightSystem_Report, a BindableFunction that returns
-- a live breakdown of a player's ledger. Command-bar `require` gets its OWN
-- copy of a ModuleScript, so without this there is no way to inspect the
-- running ledger while the game is playing -- you can only see the totals it
-- has already written to attributes. Cheap, server-only, no remote.
WeightConfig.ExposeDebugReport = true

WeightConfig.NotifyCooldown = 1.8
WeightConfig.Messages = {
	Full = "Too Heavy! Max Weight Reached",
	-- The machine's box, not the player's bag. Named separately because "your
	-- bag is full" over a truck with an empty rucksack on the seat beside you is
	-- a message about the wrong container.
	HoldFull = "Hold Full \u{2014} unload at the machine!",
	Unloaded = "Unloaded %s %s from the %s.",
	HoldEmpty = "Nothing in the hold.",
	BagFullToUnload = "Your bag is full \u{2014} go and sell first.",
	TooHeavy = "Too Heavy! Only %s %s of space left",
	-- Only reachable with OverrideInventorySlots = false, i.e. if you put the
	-- slot cap back. Kept so that switch stays a one-liner.
	BagFull = "Bag Full \u{2014} go sell at the green pad!",
	UnknownItem = "You can't carry that.",
}

----------------------------------------------------------------
-- SHARED HELPERS
----------------------------------------------------------------

function WeightConfig.round(n: number): number
	return math.floor(n * 1000 + 0.5) / 1000
end

-- "2", "0.5", "12.5" -- never "12.500000000001".
function WeightConfig.format(n: number): string
	if type(n) ~= "number" or n ~= n then
		return "0"
	end
	n = WeightConfig.round(n)
	local whole = math.floor(n + 0.5)
	if math.abs(n - whole) < 1e-3 then
		return string.format("%d", whole)
	end
	return string.format("%.1f", n)
end

-- Rejects nil, NaN, infinities, negatives and zero, then clamps. Every weight
-- in the system goes through here, which is why no later maths needs guards.
local function sanitize(value: any): number?
	if type(value) ~= "number" then
		return nil
	end
	if value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	if value <= 0 then
		return nil
	end
	return math.clamp(value, WeightConfig.MinItemWeight, WeightConfig.MaxItemWeight)
end
WeightConfig.sanitizeWeight = sanitize

function WeightConfig.resolveWeight(instance: Instance?): number
	if typeof(instance) ~= "Instance" then
		return WeightConfig.DefaultItemWeight
	end

	local direct = sanitize(instance:GetAttribute(WeightConfig.WeightAttribute))
	if direct then
		return direct
	end

	local itemId = instance:GetAttribute(WeightConfig.ItemIdAttribute)
	if type(itemId) == "string" then
		local byId = sanitize(WeightConfig.WeightByItemId[itemId])
		if byId then
			return byId
		end
	end

	local byName = sanitize(WeightConfig.WeightByName[instance.Name])
	if byName then
		return byName
	end

	return WeightConfig.DefaultItemWeight
end

function WeightConfig.labelOf(instance: Instance?): string
	if typeof(instance) ~= "Instance" then
		return "Item"
	end

	-- An encased find is never named, whatever the prop happens to be called.
	-- A billboard reading "Buried Phone" would give away exactly what the wash
	-- bay exists to reveal.
	local itemId = WeightConfig.itemIdOf(instance)
	if itemId and WeightConfig.EncasedItemIds[itemId] then
		return WeightConfig.LumpLabel
	end

	local label = instance:GetAttribute(WeightConfig.LabelAttribute)
	if type(label) == "string" and label ~= "" then
		return label
	end
	return instance.Name
end

function WeightConfig.itemIdOf(instance: Instance?): string?
	if typeof(instance) ~= "Instance" then
		return nil
	end
	local itemId = instance:GetAttribute(WeightConfig.ItemIdAttribute)
	if type(itemId) == "string" and itemId ~= "" then
		return itemId
	end
	return nil
end

-- The BasePart a prompt hangs off / a billboard adorns to. Models answer with
-- their PrimaryPart when they have one, otherwise any part they own.
function WeightConfig.anchorPart(instance: Instance?): BasePart?
	if typeof(instance) ~= "Instance" then
		return nil
	end
	if instance:IsA("BasePart") then
		return instance
	end
	if instance:IsA("Model") then
		local primary = instance.PrimaryPart
		if primary and primary:IsDescendantOf(instance) then
			return primary
		end
		return instance:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

function WeightConfig.positionOf(instance: Instance?): Vector3?
	local part = WeightConfig.anchorPart(instance)
	if not part then
		return nil
	end
	if instance:IsA("Model") then
		-- pivot, not the part: a model's handle should be its middle
		return instance:GetPivot().Position
	end
	return part.Position
end

function WeightConfig.trashFolder(): Instance?
	local folder = workspace:FindFirstChild(WeightConfig.TrashFolderName)
	if folder and folder:IsA("Folder") then
		return folder
	end
	return nil
end

-- Is this instance one collectible piece of trash? Deliberately strict about
-- nesting: only a direct child of the Trash folder (or of a Folder inside it)
-- qualifies by location, so the parts inside a trash MODEL never register as
-- pickups of their own. Tagging always wins, for spawners that place items
-- somewhere else entirely.
function WeightConfig.isCandidate(instance: Instance?): boolean
	if typeof(instance) ~= "Instance" then
		return false
	end
	if not (instance:IsA("BasePart") or instance:IsA("Model")) then
		return false
	end
	if CollectionService:HasTag(instance, WeightConfig.CollectibleTag) then
		return true
	end

	local folder = WeightConfig.trashFolder()
	if not folder then
		return false
	end
	local parent = instance.Parent
	if not parent then
		return false
	end
	if parent == folder then
		return true
	end
	return parent:IsA("Folder") and parent:IsDescendantOf(folder)
end

-- How far this player can sweep right now: their own reach on foot, or the net
-- on whatever they are riding, whichever is greater. One function, called by the
-- client to decide what to ask for and by the server to decide what to allow, so
-- the two can never disagree about what a net is worth.
function WeightConfig.reachFor(player: Instance?): number
	local base = WeightConfig.AutoCollectRadius
	if typeof(player) ~= "Instance" then
		return base
	end

	--[[
		THE MACHINE'S NET, if it is wider -- and it always is.

		The only thing the net is ever weighed against is the flat 14 stud
		AutoCollectRadius, and both machines out-reach that on their own: the
		Sandhog's blade is 16 studs, the Tidebreaker's scoop 20. So on this axis
		the `>` is a formality rather than a contest, and climbing into anything
		widens your sweep.

		It was briefly a real contest. Reach used to be the Beachcomber Reach
		upgrade track, which wrote a MagnetRange attribute this function took
		over the constant whenever it was larger, so a well-levelled walker
		out-reached the truck. That track was removed and the branch reading its
		attribute came out with it -- left in, it would have had both the client
		and the server testing an attribute nothing writes.

		AtvServer publishes the same net this function reads into the NetRadius
		attribute, so the dashboard and the machine's own stamped attribute
		agree with it.
	]]
	local net = player:GetAttribute(WeightConfig.NetRadiusAttribute)
	if type(net) == "number" and net > base then
		return net
	end
	return base
end

--[[
	A CAPACITY IS NOT AN ITEM WEIGHT, and this function used to sanitise it as
	though it were.

	sanitize() is the guard for a weight read off a prop, so it clamps to
	MaxItemWeight -- 999 -- which is exactly right for "somebody typed 1e9 into a
	Weight attribute" and exactly wrong for a bag. Bucket Size passes 999 lbs
	around level 47 and reaches 2,745, so running the curve through sanitize()
	silently capped every bag in the game at 999 for the last quarter of the
	ladder: thirteen purchases that took the money and moved nothing.

	So capacity gets its own guard. Same rejections (not a number, NaN, infinite,
	non-positive), different ceiling: CapacityCeiling, which exists to stop a
	runaway curve rather than to describe how heavy a bottle can be.
]]
WeightConfig.CapacityCeiling = 1e6

local function sanitizeCapacity(value: any): number?
	if type(value) ~= "number" or value ~= value then
		return nil
	end
	if value == math.huge or value == -math.huge or value <= 0 then
		return nil
	end
	return math.min(value, WeightConfig.CapacityCeiling)
end

function WeightConfig.capacityForLevel(level: any): number
	if not WeightConfig.ScaleWithLevel then
		return WeightConfig.BaseMaxWeight
	end

	local n = 1
	if type(level) == "number" and level == level then
		n = math.max(1, math.floor(level))
	end

	-- The progression track's own curve, when there is one. Not clamped to a
	-- table length here: the curve clamps to ProgressionConfig.MaxLevel itself,
	-- which is the only ceiling that exists.
	local curve = WeightConfig.CapacityCurve
	if type(curve) == "function" then
		local ok, value = pcall(curve, n)
		if ok then
			value = sanitizeCapacity(value)
			if value then
				return value
			end
		end
	end

	local tiers = WeightConfig.CapacityPerLevel
	if type(tiers) ~= "table" or #tiers == 0 then
		return WeightConfig.BaseMaxWeight
	end
	local value = sanitizeCapacity(tiers[math.min(n, #tiers)])
	return value or WeightConfig.BaseMaxWeight
end

local function positiveNumber(value: any): number
	if type(value) ~= "number" or value ~= value or value <= 0 then
		return 0
	end
	return math.min(value, 1e6)
end

-- Is this player currently filling a machine's hold rather than their own bag?
-- True exactly while they are sitting in something, because AtvServer clears
-- the capacity the moment they get off.
function WeightConfig.holdActive(player: Instance?): boolean
	if typeof(player) ~= "Instance" then
		return false
	end
	return positiveNumber(player:GetAttribute(WeightConfig.HoldMaxAttribute)) > 0
end

--[[
	HOW MUCH ROOM IS LEFT IN WHATEVER IS FILLING RIGHT NOW.

	ONE function, called by the client to decide what to ask for and by the
	server to decide what to allow -- the same contract reachFor() has, and for
	the same reason: two answers that can disagree eventually will.

	It matters more here than it looks. The client refuses to even REQUEST a
	piece of litter that it thinks will not fit, so a client still measuring the
	player's bag would go silent the moment that bag was full -- while sitting in
	a truck with four hundred pounds of room going spare.
]]
function WeightConfig.freeFor(player: Instance?): number
	if typeof(player) ~= "Instance" then
		return 0
	end
	if WeightConfig.holdActive(player) then
		local max = positiveNumber(player:GetAttribute(WeightConfig.HoldMaxAttribute))
		local load = math.max(0, tonumber(player:GetAttribute(WeightConfig.HoldLoadAttribute)) or 0)
		return math.max(0, WeightConfig.round(max - load))
	end
	local max = positiveNumber(player:GetAttribute(WeightConfig.MaxWeightAttribute))
	if max <= 0 then
		max = WeightConfig.BaseMaxWeight
	end
	local load = math.max(0, tonumber(player:GetAttribute(WeightConfig.CurrentWeightAttribute)) or 0)
	return math.max(0, WeightConfig.round(max - load))
end

--[[
	WIRING THE BUCKET CURVE  --  last, and deliberately not a require at the top.

	ProgressionConfig is a plain data module with no dependencies of its own, so
	there is no cycle here -- but it is also not guaranteed to exist. Everything
	above works without it; this block only upgrades the capacity ladder from
	the six-entry fallback table to the live sixty-level curve when the game that
	owns the tracks is actually installed.

	FindFirstChild rather than WaitForChild: this module is required during boot
	on both sides, and a yield here would stall whichever one got there first.
]]
do
	local modules = ReplicatedStorage:FindFirstChild("Modules")
	local module = modules and modules:FindFirstChild("ProgressionConfig")
	if module and module:IsA("ModuleScript") then
		local ok, Progression = pcall(require, module)
		local track = ok and type(Progression) == "table"
			and Progression.TrackByKey and Progression.TrackByKey.BucketSize
		if track and type(track.effect) == "function" then
			local top = Progression.MaxLevel or 60
			WeightConfig.CapacityCurve = function(level: number): number
				return track.effect(math.clamp(level, 1, top))
			end
			-- The floor a player with no level attribute yet gets, kept in step
			-- with the track's own level 1 so the bag never starts at a number
			-- the shop does not admit to.
			WeightConfig.BaseMaxWeight = track.effect(1)
		elseif not ok then
			warn("[WeightConfig] ProgressionConfig present but would not load:", Progression)
		end
	end
end

return WeightConfig
