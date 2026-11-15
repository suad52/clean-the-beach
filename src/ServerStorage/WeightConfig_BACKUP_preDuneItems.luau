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
WeightConfig.CapacityPerLevel = { 20, 30, 42, 56, 75, 100 }

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
	Glasses = true,
	Watch = true,
	Phone = true,
}
WeightConfig.LumpLabel = "Crusted Lump"

WeightConfig.WeightByItemId = {
	Can = 1,
	Bottle = 2,
	Shell = 1,
	Coin = 0.5,

	-- Every ENCASED find weighs the same, deliberately. ItemConfig already
	-- gives every lump the same chunk count and the same outer size so that
	-- neither counting nor eyeballing gives it away; weight is the third way to
	-- tell them apart and has to be closed too. It is a rock of crust either
	-- way -- and CrustedWeight is a player attribute the client can read, so
	-- distinct weights meant one lump in the bag named itself.
	Glasses = 2,
	Watch = 2,
	Phone = 2,

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
WeightConfig.AutoCollect = true          -- walking over a piece that fits takes it
WeightConfig.AutoCollectRadius = 8
WeightConfig.ManualPickupRadius = 14     -- how far the key/tap can reach
WeightConfig.ServerRangeTolerance = 6    -- slack the server allows for latency

WeightConfig.PickupKey = Enum.KeyCode.E
WeightConfig.GamepadPickupKey = Enum.KeyCode.ButtonX
WeightConfig.ShowTouchButton = true

-- Riding an ATV widens the sweep to the net's reach. AtvServer writes this
-- attribute and clears it the moment the player gets off; BOTH sides read it
-- through reachFor below, so the client never claims a reach the server has not
-- also granted.
WeightConfig.NetRadiusAttribute = "NetRadius"

WeightConfig.ClientScanInterval = 0.1    -- seconds between proximity sweeps
WeightConfig.ClientRequestSpacing = 0.15 -- min gap between two requests
WeightConfig.ClientRequestTimeout = 1.0  -- give up waiting on a reply after this
WeightConfig.ClientRetryDelay = 2.0      -- retry a refused item after this

-- Server-side token bucket. Sized well above what the client above can
-- produce, so honest play never trips it and a spammed remote goes nowhere.
WeightConfig.MaxRequestsPerSecond = 12
WeightConfig.RequestBurst = 8

-- Optional engine-validated trigger. Off by default because the RemoteEvent
-- path plus auto-collect already covers keyboard, gamepad and touch; turn it
-- on if you would rather have a Roblox prompt on every piece of litter.
WeightConfig.UseProximityPrompts = false
WeightConfig.PromptHoldDuration = 0
WeightConfig.PromptMaxDistance = 12

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
	local net = player:GetAttribute(WeightConfig.NetRadiusAttribute)
	if type(net) == "number" and net > base then
		return net
	end
	return base
end

function WeightConfig.capacityForLevel(level: any): number
	local tiers = WeightConfig.CapacityPerLevel
	if not WeightConfig.ScaleWithLevel or type(tiers) ~= "table" or #tiers == 0 then
		return WeightConfig.BaseMaxWeight
	end
	local n = 1
	if type(level) == "number" and level == level then
		n = math.clamp(math.floor(level), 1, #tiers)
	end
	local value = sanitize(tiers[n])
	return value or WeightConfig.BaseMaxWeight
end

return WeightConfig
