--[[
	WeightService  --  ServerScriptService.WeightSystem.WeightService

	THE AUTHORITY. Every gram a player is carrying is decided here, on the
	server, and nowhere else. No remote reaches into this module; the only way
	in is a server-side call from TrashCollectionService (or from your own code
	via the public API at the bottom of this header).

	THE LEDGER
	----------
	One record per collected item:  { uid, weight, itemId, invUid, label }
	CurrentWeight is the sum of those records -- it is never incremented
	blind. Every removal recomputes the sum from the array, so a rounding
	error cannot accumulate over a session and strand a player at 19.97 / 20.

	HOW WEIGHT GETS FREED  (the bit that makes this safe to bolt on)
	---------------------------------------------------------------
	With WeightConfig.LinkToInventory on, a collected item is also added to
	ReplicatedStorage.Modules.InventoryController -- the ONE array the sifting
	station, SellServer and CTB_HUD already share -- and the ledger record
	remembers that item's uid. InventoryController fires Server.Changed once
	per flush; on every one of those we drop any ledger record whose inventory
	item no longer exists.

	So selling frees weight automatically, with no hook into SellServer, no
	edit to CTBBridge and no second copy of anything. The inventory array stays
	the single source of truth for WHAT you carry; this ledger only answers HOW
	HEAVY it is.

	That reconcile runs BOTH ways. Items this system did not collect -- the
	roller's finds, arriving through CTBBridge.tryAdd -- are adopted into the
	ledger and priced from WeightConfig.WeightByItemId, so raking costs weight
	too. Weight is therefore a property of the whole inventory, not just of the
	part this system happened to put there, and there is no route into the bag
	that escapes it.

	One consequence to know: adoption is after the fact, so a find that arrives
	with less headroom than it weighs can push the load slightly past MaxWeight.
	It self-corrects -- CTBBridge.hasRoom stops the roller the moment the
	lightest possible find no longer fits -- and every bar in the game clamps.

	With the link off, the ledger stands alone and you free weight yourself
	with WeightService.dropAll(player).

	CAPACITY  --  WEIGHT REPLACES SLOTS
	-----------------------------------
	MaxWeight follows the BUCKET SIZE upgrade track (Lv_BucketSize) through
	WeightConfig.CapacityPerLevel. ProgressionServer applies it on join, on
	every respawn, after every purchase and after rebirth; this module also
	watches the attribute directly, so the two can never disagree.

	WHAT THIS DELIBERATELY DOES NOT DO ANY MORE: grow for a vehicle. A machine
	in the car spawner carries its own separate hold (ServerScriptService.
	VehicleHold) and the player unloads it into this bag a bagful at a time. An
	earlier pass had vehicles ADD to the number here, which made a truck a
	bigger rucksack rather than a truck.

	The old 10-SLOT cap is lifted on join by calling the inventory's own
	SetMaxCapacity, so weight is the only limit a player ever meets. That is a
	runtime call on a public method, not an edit to GameConfig: the base file
	still reads 10, and WeightConfig.OverrideInventorySlots = false puts the
	slot cap straight back with nothing to undo.

	PUBLIC API
	----------
		WeightService.start()
		WeightService.getLoad(player)      -> number
		WeightService.getMax(player)       -> number
		WeightService.getFree(player)      -> number
		WeightService.canCarry(player, w)  -> boolean, reason
		WeightService.collect(player, w, info) -> record?, reason
		WeightService.release(player, record)  -> boolean
		WeightService.dropAll(player)
		WeightService.setMaxWeight(player, n)
		WeightService.addMaxWeight(player, delta)
		WeightService.snapshot(player)     -> { load, max, free, count }
		WeightService.stop()

	Reason codes: "Ok" | "Full" | "TooHeavy" | "BagFull" | "UnknownItem" | "NoData"
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local WeightSystem = ReplicatedStorage:WaitForChild("WeightSystem", 30)
assert(WeightSystem, "[WeightService] ReplicatedStorage.WeightSystem is missing")
local WeightConfig = require(WeightSystem:WaitForChild("WeightConfig"))
-- Pure replicated data and arithmetic -- no service, no remote, nothing that
-- starts, so this adds no ordering constraint to a module that boots early.
-- Required for liveHoldCap() alone; see applyCapacity.
local EventConfig = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("EventConfig"))

local EPS = WeightConfig.EPSILON

local WeightService = {}

----------------------------------------------------------------
-- OPTIONAL LINK TO THE BASE GAME'S INVENTORY
--
-- Resolved defensively: if the modules are not there (or fail to load) this
-- system carries on standalone instead of throwing. That is what lets the
-- same code drop into a place that has no sift/sell system at all.
----------------------------------------------------------------
local InventoryController = nil
local ItemConfig = nil

local function tryRequire(parent: Instance?, name: string)
	if not parent then
		return nil
	end
	local moduleScript = parent:FindFirstChild(name)
	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		return nil
	end
	local ok, result = pcall(require, moduleScript)
	if not ok then
		warn(string.format("[WeightService] could not require %s: %s", name, tostring(result)))
		return nil
	end
	return result
end

if WeightConfig.LinkToInventory then
	local modules = ReplicatedStorage:FindFirstChild("Modules")
	local inventory = tryRequire(modules, "InventoryController")
	if type(inventory) == "table" and type(inventory.Server) == "table" then
		InventoryController = inventory
	else
		warn("[WeightService] InventoryController not found -- running the ledger standalone")
	end
	local items = tryRequire(modules, "ItemConfig")
	if type(items) == "table" and type(items.get) == "function" then
		ItemConfig = items
	end
end

local function linked(): boolean
	return InventoryController ~= nil
end

----------------------------------------------------------------
-- HOW AN ITEM ENTERS THE BAG
----------------------------------------------------------------
-- Putting the record in the array is only half of it. The game's rule is that
-- LOOSE litter is revealed and priced the moment it is picked up, and only
-- ENCASED finds arrive as anonymous crusted lumps that must be sifted first.
-- That rule lives in CTBBridge.tryAdd, and Inventory:Add says so in its own
-- comment: everything it creates starts "Crusted", and the CALLER flips it.
--
-- So this delegates instead of calling Add directly. Calling Add on its own is
-- what left every single pickup Crusted -- and SellServer only ever removes
-- Cleaned records, so those items could not be sold and their weight stayed on
-- the ledger after a sale. That was the "selling leaves me at 9 lbs" bug.
-- Copying the rule into this file instead would only have waited to drift.
--
-- Lazy and optional: a place with no CTBBridge falls back to the plain Add,
-- which is correct for a standalone install with no sift/sell loop at all.
local bridgeLoaded = false
local CTBBridge = nil

local function ctbBridge()
	if bridgeLoaded then
		return CTBBridge
	end
	bridgeLoaded = true

	local moduleScript = ServerScriptService:FindFirstChild("CTBBridge")
	if not (moduleScript and moduleScript:IsA("ModuleScript")) then
		return nil
	end
	local ok, result = pcall(require, moduleScript)
	if not ok then
		warn("[WeightService] CTBBridge is present but would not load:", result)
		return nil
	end
	if type(result) == "table" and type(result.tryAdd) == "function" then
		CTBBridge = result
	end
	return CTBBridge
end

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------
export type Record = {
	uid: string,
	weight: number,
	itemId: string?,
	invUid: string?,
	label: string?,
	at: number,
}

type Ledger = {
	load: number,
	max: number,
	manualMax: boolean,
	records: { Record },
	byInvUid: { [string]: Record },
	conns: { any },
}

local ledgers: { [Player]: Ledger } = {}
local connections: { any } = {}
local started = false

local uidCounter = 0
local function nextUid(): string
	uidCounter += 1
	return string.format("w%08d", uidCounter)
end

local function push(player: Player, ledger: Ledger)
	if not player.Parent then
		return
	end
	player:SetAttribute(WeightConfig.CurrentWeightAttribute, WeightConfig.round(ledger.load))
	player:SetAttribute(WeightConfig.MaxWeightAttribute, WeightConfig.round(ledger.max))

	-- The part of the load the sell pad will not take. A crusted lump has no
	-- rolled value yet, so SellServer skips it and its weight stays behind --
	-- correct, but invisible, and invisible weight that never clears is
	-- indistinguishable from a bug. The HUD says so out loud instead.
	local crusted = 0
	if linked() then
		local inventory = InventoryController.Server.find(player)
		if inventory then
			for _, record in ledger.records do
				if record.invUid then
					local item = inventory:Get(record.invUid)
					if item and item.state ~= "Cleaned" then
						crusted += record.weight
					end
				end
			end
		end
	end
	player:SetAttribute(WeightConfig.CrustedWeightAttribute, WeightConfig.round(crusted))
end

-- Always recomputed from the array rather than decremented, so removals can
-- never drift the running total.
local function recompute(player: Player, ledger: Ledger)
	local total = 0
	for _, record in ledger.records do
		total += record.weight
	end
	ledger.load = WeightConfig.round(total)
	push(player, ledger)
end

----------------------------------------------------------------
-- CAPACITY
----------------------------------------------------------------
-- The upgrade level is the source of truth. A manual setMaxWeight overrides it
-- until the level next moves, at which point the ladder takes back over -- so a
-- one-off override can never strand a player at a capacity their upgrades say
-- they have outgrown.
--
-- This is the BAG only. What a vehicle carries is not capacity at all -- it is
-- a separate container, and it lives in ServerScriptService.VehicleHold.
local function applyCapacity(player: Player, ledger: Ledger)
	local target = WeightConfig.capacityForLevel(player:GetAttribute(WeightConfig.CapacityLevelAttribute))
	--[[
		...BUT NEVER BELOW WHAT A LIVE EVENT HAS LIFTED IT TO.

		This function is the "the ladder takes back over" half of the note above,
		and it fires off the Lv_BucketSize attribute signal -- so BUYING A BAG
		UPGRADE DURING SCRAP RUSH used to hand the normal limit straight back and
		clear manualMax with it. EventService lifts at `start` and restores at
		`stop`; there is nothing in between that would ever lift it again, so the
		player lost the event for the rest of its run. Reported from the game on
		2026-09-09.

		A FLOOR, taken against the ladder rather than replacing it: a bag that has
		outgrown the event cap keeps its own number, which is the same rule
		EventService's restore follows so that a rung bought mid-event survives.

		ProgressionServer.applyAll carries the same floor. It has to: that is the
		other place capacity is re-derived from this ladder, and whichever of the
		two landed last would otherwise undo the other. THE MODULE HEADER'S CLAIM
		THAT "THE TWO CAN NEVER DISAGREE" IS WHAT BOTH COPIES ARE DEFENDING -- if
		one of them moves, move the other.
	]]
	local lifted = EventConfig.liveHoldCap()
	if lifted and lifted > target then
		target = lifted
	end
	if ledger.max ~= target then
		ledger.max = target
		ledger.manualMax = false
		push(player, ledger)
	end
end

----------------------------------------------------------------
-- ITEM ID RESOLUTION (only used when the inventory link is live)
----------------------------------------------------------------
local warnedIds: { [string]: boolean } = {}

local function resolveItemId(raw: string?): string?
	local wanted = (type(raw) == "string" and raw ~= "") and raw or nil

	if not ItemConfig then
		return wanted or WeightConfig.DefaultItemId
	end
	if wanted and ItemConfig.get(wanted) then
		return wanted
	end
	if wanted and not warnedIds[wanted] then
		warnedIds[wanted] = true
		warn(string.format(
			"[WeightService] ItemConfig has no entry for ItemId %q -- falling back to %q",
			wanted, tostring(WeightConfig.DefaultItemId)))
	end
	if wanted and WeightConfig.RefuseUnknownItems then
		return nil
	end

	local fallback = WeightConfig.DefaultItemId
	if type(fallback) == "string" and ItemConfig.get(fallback) then
		return fallback
	end
	return nil
end

----------------------------------------------------------------
-- RECONCILE  (inventory array -> ledger)
----------------------------------------------------------------
-- Runs on every inventory flush for that player. One direction only: an item
-- leaving the inventory (sold, consumed, cleared) drops its ledger record and
-- frees the weight. The ledger never removes anything from the inventory.
local function reconcile(player: Player)
	if not linked() then
		return
	end
	local ledger = ledgers[player]
	if not ledger then
		return
	end
	local inventory = InventoryController.Server.find(player)
	if not inventory then
		return
	end

	local alive: { [string]: boolean } = {}
	for _, item in inventory:Items() do
		if type(item) == "table" and type(item.uid) == "string" then
			alive[item.uid] = true
		end
	end

	local dropped = false
	for i = #ledger.records, 1, -1 do
		local record = ledger.records[i]
		if record.invUid and not alive[record.invUid] then
			table.remove(ledger.records, i)
			ledger.byInvUid[record.invUid] = nil
			dropped = true
		end
	end

	-- ADOPTION, the other half of the same idea. Anything that reached the
	-- inventory by a route other than this system -- the roller, via
	-- CTBBridge.tryAdd -- gets a ledger record here, priced off WeightConfig.
	--
	-- Without this the roller is unlimited. Lifting the slot cap took away the
	-- only thing that used to stop it, and weight would never rise to replace
	-- it, so a player could rake the entire beach on one empty bag.
	--
	-- Records this system created are already in byInvUid and are skipped, so
	-- they keep the weight of the actual prop that was collected: a 10 lb tyre
	-- stays 10 lb even though its ItemId prices at 1.
	local adopted = false
	for _, item in inventory:Items() do
		if type(item) == "table" and type(item.uid) == "string" and not ledger.byInvUid[item.uid] then
			local priced = WeightConfig.sanitizeWeight(WeightConfig.WeightByItemId[item.itemId])
			local record: Record = {
				uid = nextUid(),
				weight = WeightConfig.round(priced or WeightConfig.DefaultItemWeight),
				itemId = item.itemId,
				invUid = item.uid,
				label = nil,
				at = os.clock(),
			}
			table.insert(ledger.records, record)
			ledger.byInvUid[item.uid] = record
			adopted = true
		end
	end

	if dropped or adopted then
		recompute(player, ledger)
	else
		-- Nothing entered or left, but a STATE may have moved: sifting a lump
		-- flips it Crusted -> Sifting -> Cleaned without touching the ledger at
		-- all. CrustedWeight is derived from those states, so it has to be
		-- re-derived on every flush or the HUD goes on claiming "6 lbs of
		-- crusted finds" after you have just sifted them clean.
		push(player, ledger)
	end
end

----------------------------------------------------------------
-- LIFECYCLE
----------------------------------------------------------------
local function onPlayerAdded(player: Player)
	if ledgers[player] then
		return
	end

	local ledger: Ledger = {
		load = 0,
		max = WeightConfig.capacityForLevel(player:GetAttribute(WeightConfig.CapacityLevelAttribute)),
		manualMax = false,
		records = {},
		byInvUid = {},
		conns = {},
	}
	ledgers[player] = ledger
	push(player, ledger)

	-- Weight replaces slots. Server.get() is the same call CTBBridge makes, and
	-- it is idempotent, so whichever of us reaches the player first the other
	-- finds the identical inventory.
	if linked() and WeightConfig.OverrideInventorySlots then
		local inventory = InventoryController.Server.get(player)
		if inventory and inventory:MaxCapacity() < WeightConfig.InventorySlotCap then
			inventory:SetMaxCapacity(WeightConfig.InventorySlotCap)
		end
	end

	if WeightConfig.ScaleWithLevel then
		-- ProgressionServer sets Lv_BucketSize in its own PlayerAdded and again
		-- on every purchase. Whichever handler runs first, this signal lands on
		-- the value that ends up on the player.
		table.insert(ledger.conns, player:GetAttributeChangedSignal(WeightConfig.CapacityLevelAttribute)
			:Connect(function()
				local live = ledgers[player]
				if live then
					applyCapacity(player, live)
				end
			end))
	end
end

local function onPlayerRemoving(player: Player)
	local ledger = ledgers[player]
	if not ledger then
		return
	end
	for _, conn in ledger.conns do
		conn:Disconnect()
	end
	table.clear(ledger.conns)
	table.clear(ledger.records)
	table.clear(ledger.byInvUid)
	ledgers[player] = nil
end

----------------------------------------------------------------
-- PUBLIC API
----------------------------------------------------------------

function WeightService.getLoad(player: Player): number
	local ledger = ledgers[player]
	return ledger and ledger.load or 0
end

function WeightService.getMax(player: Player): number
	local ledger = ledgers[player]
	return ledger and ledger.max or WeightConfig.BaseMaxWeight
end

function WeightService.getFree(player: Player): number
	local ledger = ledgers[player]
	if not ledger then
		return 0
	end
	return math.max(0, WeightConfig.round(ledger.max - ledger.load))
end

function WeightService.snapshot(player: Player)
	local ledger = ledgers[player]
	if not ledger then
		return { load = 0, max = WeightConfig.BaseMaxWeight, free = 0, count = 0 }
	end
	return {
		load = ledger.load,
		max = ledger.max,
		free = math.max(0, WeightConfig.round(ledger.max - ledger.load)),
		count = #ledger.records,
	}
end

-- The one comparison the whole feature rests on.
--   "Full"     -- there is no usable space left at all
--   "TooHeavy" -- there IS space, just not enough for THIS item, so a lighter
--                 one is still perfectly collectable
function WeightService.canCarry(player: Player, weight: number): (boolean, string)
	local ledger = ledgers[player]
	if not ledger then
		return false, "NoData"
	end
	local clean = WeightConfig.sanitizeWeight(weight)
	if not clean then
		return false, "UnknownItem"
	end

	local free = ledger.max - ledger.load
	if clean <= free + EPS then
		return true, "Ok"
	end
	if free <= EPS then
		return false, "Full"
	end
	return false, "TooHeavy"
end

--[[
	Commit a pickup. Returns (record, "Ok") or (nil, reason).

	Nothing in here yields, which is what makes the check-then-commit safe:
	two requests for the same item in the same frame cannot interleave.
]]
function WeightService.collect(player: Player, weight: number, info: { itemId: string?, label: string? }?): (Record?, string)
	local ledger = ledgers[player]
	if not ledger then
		return nil, "NoData"
	end

	local clean = WeightConfig.sanitizeWeight(weight)
	if not clean then
		return nil, "UnknownItem"
	end

	local fits, reason = WeightService.canCarry(player, clean)
	if not fits then
		return nil, reason
	end

	local itemId: string? = nil
	local invUid: string? = nil

	if linked() then
		local inventory = InventoryController.Server.get(player)
		if not inventory then
			return nil, "NoData"
		end
		itemId = resolveItemId(info and info.itemId or nil)
		if not itemId then
			return nil, "UnknownItem"
		end
		-- Unreachable while OverrideInventorySlots is on (the cap is 9999). It
		-- stays because turning the slot cap back on must not need a code change.
		if not inventory:HasRoom(1) then
			return nil, "BagFull"
		end

		local bridge = ctbBridge()
		if bridge then
			-- tryAdd answers yes/no, not "which record", so the new one is
			-- identified as the uid that was not in the array a moment ago.
			local before = {}
			for _, item in inventory:Items() do
				before[item.uid] = true
			end

			if not bridge.tryAdd(player, itemId) then
				-- Room was checked above and resolveItemId guarantees an id
				-- ItemConfig knows, so a refusal here is capacity.
				return nil, "BagFull"
			end

			for _, item in inventory:Items() do
				if not before[item.uid] then
					invUid = item.uid
					break
				end
			end
			if not invUid then
				-- Said yes, added nothing. Charge nobody for a pickup that did
				-- not happen.
				warn("[WeightService] CTBBridge.tryAdd reported success but no record appeared")
				return nil, "UnknownItem"
			end
		else
			local added = inventory:Add(itemId)
			if not added then
				return nil, "BagFull"
			end
			invUid = added.uid
		end
	end

	local record: Record = {
		uid = nextUid(),
		weight = WeightConfig.round(clean),
		itemId = itemId,
		invUid = invUid,
		label = info and info.label or nil,
		at = os.clock(),
	}
	table.insert(ledger.records, record)
	if invUid then
		ledger.byInvUid[invUid] = record
	end
	ledger.load = WeightConfig.round(ledger.load + record.weight)
	push(player, ledger)

	return record, "Ok"
end

-- Frees one record's weight. Does NOT remove the matching inventory item --
-- the inventory owns that decision, and reconcile() will notice if it goes.
function WeightService.release(player: Player, record: Record?): boolean
	local ledger = ledgers[player]
	if not ledger or type(record) ~= "table" then
		return false
	end
	local i = table.find(ledger.records, record)
	if not i then
		return false
	end
	table.remove(ledger.records, i)
	if record.invUid then
		ledger.byInvUid[record.invUid] = nil
	end
	recompute(player, ledger)
	return true
end

function WeightService.dropAll(player: Player)
	local ledger = ledgers[player]
	if not ledger then
		return
	end
	table.clear(ledger.records)
	table.clear(ledger.byInvUid)
	recompute(player, ledger)
end

-- Takes bag capacity off the Bucket Size curve for this player until that level
-- next moves. ProgressionServer calls it with the track's effect on every
-- purchase, respawn and rebirth.
function WeightService.setMaxWeight(player: Player, value: number)
	local ledger = ledgers[player]
	if not ledger then
		return
	end
	if type(value) ~= "number" or value ~= value then
		return
	end
	ledger.manualMax = true
	ledger.max = WeightConfig.round(math.max(WeightConfig.MinItemWeight, value))
	push(player, ledger)
end

function WeightService.addMaxWeight(player: Player, delta: number)
	local ledger = ledgers[player]
	if not ledger or type(delta) ~= "number" or delta ~= delta then
		return
	end
	WeightService.setMaxWeight(player, ledger.max + delta)
end

----------------------------------------------------------------
-- DIAGNOSTICS
----------------------------------------------------------------
-- Every record, its price, and whether the inventory item it is tied to still
-- exists. A record whose inventory item is GONE but which is still here is the
-- signature of weight that will never come back.
function WeightService.report(player: Player): string
	local ledger = ledgers[player]
	if not ledger then
		return "no ledger for " .. player.Name
	end

	local alive = {}
	if linked() then
		local inventory = InventoryController.Server.find(player)
		if inventory then
			for _, item in inventory:Items() do
				alive[item.uid] = item.state or "?"
			end
		end
	end

	local lines = {
		string.format("%s  load=%s  max=%s  free=%s  records=%d",
			player.Name, tostring(ledger.load), tostring(ledger.max),
			tostring(WeightConfig.round(ledger.max - ledger.load)), #ledger.records),
	}
	local orphans, sum = 0, 0
	for i, record in ledger.records do
		sum += record.weight
		local state = record.invUid and alive[record.invUid] or nil
		if record.invUid and not state then
			orphans += 1
		end
		table.insert(lines, string.format("  %2d. %-8s %5s lb  inv=%s  %s",
			i, tostring(record.itemId), tostring(record.weight),
			tostring(record.invUid),
			record.invUid and (state and ("state=" .. state) or "*** ORPHAN: inventory item gone ***")
				or "(unlinked)"))
	end
	table.insert(lines, string.format("  sum of records=%s  (load says %s)  orphans=%d  inventory items=%d",
		tostring(WeightConfig.round(sum)), tostring(ledger.load), orphans, (function()
			local n = 0
			for _ in alive do n += 1 end
			return n
		end)()))
	return table.concat(lines, "\n")
end

----------------------------------------------------------------
-- BOOT
----------------------------------------------------------------
function WeightService.start()
	assert(RunService:IsServer(), "[WeightService] server-only")
	if started then
		return
	end
	started = true

	table.insert(connections, Players.PlayerAdded:Connect(onPlayerAdded))
	table.insert(connections, Players.PlayerRemoving:Connect(onPlayerRemoving))
	-- Players already in (Studio play solo joins before scripts finish).
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	if linked() then
		table.insert(connections, InventoryController.Server.Changed:Connect(reconcile))
	end

	if WeightConfig.ExposeDebugReport then
		local ServerStorage = game:GetService("ServerStorage")
		local existing = ServerStorage:FindFirstChild("WeightSystem_Report")
		if existing then
			existing:Destroy()
		end
		local hook = Instance.new("BindableFunction")
		hook.Name = "WeightSystem_Report"
		hook.OnInvoke = function(player)
			if typeof(player) ~= "Instance" or not player:IsA("Player") then
				local out = {}
				for each in ledgers do
					table.insert(out, WeightService.report(each))
				end
				return #out > 0 and table.concat(out, "\n\n") or "no ledgers"
			end
			return WeightService.report(player)
		end
		hook.Parent = ServerStorage
	end
end

-- Not used in normal play; here so a soft restart in Studio leaves nothing
-- connected behind it.
function WeightService.stop()
	for _, conn in connections do
		conn:Disconnect()
	end
	table.clear(connections)
	for player in ledgers do
		onPlayerRemoving(player)
	end
	started = false
end

return WeightService
