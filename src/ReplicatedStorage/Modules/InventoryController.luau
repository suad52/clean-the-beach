--[[
	InventoryController  --  ReplicatedStorage.Modules.InventoryController
	(this is the module the design doc calls "InventoryManager")

	THE SHARED STATE CONTRACT
	=========================
	There is exactly ONE array per player: Inventory._items, owned by the server.
	Everything that "holds" items is a view of that array, never a second copy:

		Clean the Beach's bag    -> CTBBridge writes Bag/BagValue/BagMax player
		                            attributes from it; CTB_HUD reads those
		character carried slots  -> InventoryHud renders chips from the mirror
		the wash bay stand       -> WashServer flips a record to state="Washing"
		                            and mounts a lump; the record never leaves
		                            the array

	So "mount a lump on the stand" is one state flip, not a transfer between
	containers, and there is no code path where the bag and the stand can
	disagree. Capacity is likewise one number: inv:Count() vs inv:MaxCapacity().

	REPLICATION
	-----------
	Mutations set a dirty flag. A single Heartbeat flush coalesces every change
	made in a frame into ONE InventorySync per player, then fires Server.Changed.
	That is what makes the two views move simultaneously: they are both driven by
	the same flush.

	WHAT THE CLIENT IS NOT TOLD
	---------------------------
	Snapshot(forClient = true) strips `value` from any record that is not
	Cleaned -- the number does not exist yet, because ValueCalculator has not
	rolled it. For an ENCASED record it also strips `itemId` and `rarity`, so a
	crusted lump is not merely priceless to the client, it is anonymous. See
	publicView.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Modules = script.Parent
local GameConfig = require(Modules.GameConfig)
local ItemConfig = require(Modules.ItemConfig)
local Net = require(Modules.Net)
local Signal = require(Modules.Signal)

local InventoryController = {}

-- "Washing" is what WashServer flips a mounted lump to; "Sifting" is
-- SiftServer's name for the same beat. Only one of those two modules is started
-- (see ServerMain), but both names are legal here so a switch between them is a
-- one-line change rather than a type error waiting in every consumer.
export type ItemState = "Crusted" | "Washing" | "Sifting" | "Cleaned"

export type ItemRecord = {
	uid: string,
	itemId: string,
	state: ItemState,
	progress: number, -- 0..1 crust removed; survives leaving the bay
	value: number?,   -- SERVER ONLY until state == "Cleaned"
	stationId: string?,
	acquiredAt: number,
	-- Server-only, and never copied by publicView, so none of it leaves the
	-- server. interrupted/stalled are condition flags ValueCalculator reads;
	-- washChunks is the half-stripped shell WashServer puts back on the stand
	-- when a lump is re-mounted (one 0..1 entry per crust chunk).
	interrupted: boolean?, -- player walked away part-way through washing it
	stalled: boolean?,     -- reserved; the stand has no idle decay
	washChunks: { number }?,
}

--------------------------------------------------------------------------
-- SHARED
--------------------------------------------------------------------------

--[[
	The one place that decides what a client is allowed to know about a record.

	For an ENCASED item this withholds the IDENTITY, not merely the price. Until
	the crust is off, `itemId` and `rarity` are simply absent from the payload,
	so there is no field anywhere in the client's memory that says which item
	the lump is. The HUD renders it as "Crusted Lump / ???" because that is
	literally all it has been given.

	Loose litter is revealed from the moment it is picked up -- it was never a
	mystery, and hiding it would only make the fast half of the loop feel coy.
]]
local function publicView(rec: ItemRecord)
	local def = ItemConfig.get(rec.itemId)
	local encased = (def ~= nil) and def.Encased == true
	local revealed = (not encased) or rec.state == "Cleaned"

	return {
		uid = rec.uid,
		itemId = revealed and rec.itemId or nil,
		encased = encased,
		-- What the crust is MADE of, for the cart's lump model: packed snow for
		-- the two arctic pools, dirt for everything else. Off the pool flags, so
		-- it says which ISLAND the lump came from and nothing about what is in
		-- it -- every id in an arctic pool wears the same style.
		crust = encased and ((def.Penguin or def.Wreck) and "snow" or "dirt") or nil,
		state = rec.state,
		-- rounded: no reason to burn bandwidth on float noise
		progress = math.floor(rec.progress * 1000 + 0.5) / 1000,
		rarity = revealed and (def and def.Rarity or "Common") or "Unknown",
		-- nil here is what the HUD renders as "???".
		value = (rec.state == "Cleaned") and rec.value or nil,
	}
end
InventoryController.publicView = publicView


--[[
	THE SAME QUESTION publicView ANSWERS, ASKED ABOUT ONE RECORD.

	A discovery is exactly "the client is now allowed to know what this is",
	so this predicate and the `revealed` line inside publicView have to say
	the same thing forever. They are kept a few lines apart for that reason:
	change one and the other is right there.

	Why not record straight out of publicView instead, which already computes
	it: publicView is called once per record per flush and is a pure read that
	the client half of this module calls too. Hanging a profile write off it
	would put a side effect on the snapshot path and fire it on the client.
]]
local function revealedNow(rec: ItemRecord): boolean
	local def = ItemConfig.get(rec.itemId)
	local encased = (def ~= nil) and def.Encased == true
	return (not encased) or rec.state == "Cleaned"
end

--------------------------------------------------------------------------
-- SERVER
--------------------------------------------------------------------------

local Server = {}
InventoryController.Server = Server

--[[
	FIRED THE MOMENT AN ITEM'S IDENTITY BECOMES KNOWABLE. (player, itemId)

	Two things reveal an item and there is no third: loose litter is not
	encased and is known from the moment it is picked up, and a crusted lump
	is known when it is washed to "Cleaned". So this fires from Add and from
	SetState, which are the only two places either can happen.

	It fires per REVEAL, not per flush, because a flush is a poor proxy: an
	item picked up and sold inside one frame would be gone again before the
	next snapshot and would never be counted. It is also allowed to fire more
	than once for the same id -- the listener unions, so a repeat is free.

	SaveService is the subscriber; the Pet Index has had `pets.discovered`
	since it was built and this is the item half of the same idea.
]]
Server.Discovered = Signal.new()

-- Fired once per flush, after replication. (player, inventory)
Server.Changed = Signal.new()

--[[
	FIRED WHILE A LEAVING PLAYER'S BAG STILL EXISTS. (player, inventory)

	CLOSES, 2026-09-09: "leaving destroys the whole bag, including litter that
	already has a rolled sale value". Raked litter is added and flipped straight
	to Cleaned with a value (CTBBridge does it), so every piece in a bag has had a
	price printed on the HUD since the moment it was picked up -- it is money in
	all but name. Server.release then threw the whole array away on
	PlayerRemoving and nothing anywhere banked it first, so one disconnect with a
	full bag lost the lot.

	A SEAM RATHER THAN A SECOND PlayerRemoving HANDLER, because a second handler
	cannot be made to run first. ServerMain starts this module at step 2 and
	SellServer at step 8, so the till's own PlayerRemoving is connected after ours
	and would be told about the leave with the bag already destroyed. This fires
	while inventories[player] is still set, so a claimant can still read the bag
	and sell it. SellServer.start is that claimant.

	A Signal, so handlers are task.spawn'd (see Signal's header): a claimant that
	throws cannot stop the release, and one that yields cannot stall the leave
	path or the profile save running beside it.

	CRUSTED LUMPS ARE STILL DROPPED, deliberately. They have no revealed identity
	and no rolled value -- the same reason SaveService's header gives for not
	persisting carried items at all.
]]
Server.Releasing = Signal.new()

local inventories: { [Player]: any } = {}

local Inventory = {}
Inventory.__index = Inventory

local uidCounter = 0
local function nextUid(): string
	uidCounter += 1
	return string.format("it%08d", uidCounter)
end

function Inventory.new(player: Player)
	return setmetatable({
		player = player,
		_items = {},     -- THE shared state array (ordered)
		_index = {},     -- uid -> record, for O(1) lookup
		_max = GameConfig.Inventory.MaxCapacity,
		_dirty = false,
		_destroyed = false,
	}, Inventory)
end

function Inventory:Count(): number
	return #self._items
end

function Inventory:MaxCapacity(): number
	return self._max
end

function Inventory:SetMaxCapacity(n: number)
	self._max = math.max(1, math.floor(n))
	self:MarkDirty()
end

function Inventory:HasRoom(n: number?): boolean
	return self:Count() + (n or 1) <= self._max
end

function Inventory:Get(uid: string): ItemRecord?
	return self._index[uid]
end

function Inventory:Items(): { ItemRecord }
	return self._items
end

function Inventory:GetByState(state: ItemState): { ItemRecord }
	local out = {}
	for _, rec in self._items do
		if rec.state == state then
			table.insert(out, rec)
		end
	end
	return out
end

function Inventory:CountByState(state: ItemState): number
	local n = 0
	for _, rec in self._items do
		if rec.state == state then
			n += 1
		end
	end
	return n
end

-- Returns the new record, or nil if full / unknown item.
function Inventory:Add(itemId: string): ItemRecord?
	if not ItemConfig.get(itemId) then
		warn("[Inventory] refused unknown itemId:", itemId)
		return nil
	end
	if not self:HasRoom(1) then
		return nil
	end
	local rec: ItemRecord = {
		uid = nextUid(),
		itemId = itemId,
		-- Loose litter is flipped straight to Cleaned by the caller (CTBBridge)
		-- once it has rolled a value. Everything starts here.
		state = "Crusted",
		progress = 0,
		value = nil,
		stationId = nil,
		acquiredAt = os.clock(),
	}
	table.insert(self._items, rec)
	self._index[rec.uid] = rec
	self:MarkDirty()
	if revealedNow(rec) then
		Server.Discovered:Fire(self.player, rec.itemId)
	end
	return rec
end

function Inventory:Remove(uid: string): ItemRecord?
	local rec = self._index[uid]
	if not rec then
		return nil
	end
	local i = table.find(self._items, rec)
	if i then
		table.remove(self._items, i)
	end
	self._index[uid] = nil
	self:MarkDirty()
	return rec
end

-- Removes every record matching the predicate and returns them.
function Inventory:RemoveWhere(predicate: (ItemRecord) -> boolean): { ItemRecord }
	local taken = {}
	for i = #self._items, 1, -1 do
		local rec = self._items[i]
		if predicate(rec) then
			table.remove(self._items, i)
			self._index[rec.uid] = nil
			table.insert(taken, 1, rec)
		end
	end
	if #taken > 0 then
		self:MarkDirty()
	end
	return taken
end

function Inventory:SetState(uid: string, state: ItemState): boolean
	local rec = self._index[uid]
	if not rec or rec.state == state then
		return false
	end
	rec.state = state
	self:MarkDirty()
	if revealedNow(rec) then
		Server.Discovered:Fire(self.player, rec.itemId)
	end
	return true
end

function Inventory:SetProgress(uid: string, progress: number)
	local rec = self._index[uid]
	if not rec then
		return
	end
	rec.progress = math.clamp(progress, 0, 1)
	self:MarkDirty()
end

-- Server-side only. There is deliberately no remote that can reach this.
function Inventory:SetValue(uid: string, value: number)
	local rec = self._index[uid]
	if not rec then
		return
	end
	rec.value = math.max(0, math.floor(value))
	self:MarkDirty()
end

function Inventory:Snapshot(forClient: boolean?)
	local items = {}
	for i, rec in self._items do
		items[i] = forClient and publicView(rec) or rec
	end
	return {
		items = items,
		count = #self._items,
		maxCapacity = self._max,
	}
end

function Inventory:MarkDirty()
	self._dirty = true
end

function Inventory:Replicate()
	if self._destroyed then
		return
	end
	local player = self.player
	if not player.Parent then
		return
	end
	Net.get("InventorySync"):FireClient(player, self:Snapshot(true))
	Server.Changed:Fire(player, self)
end

function Inventory:Destroy()
	self._destroyed = true
	table.clear(self._items)
	table.clear(self._index)
end

--------------------------------------------------------------------------

function Server.get(player: Player)
	local inv = inventories[player]
	if not inv then
		inv = Inventory.new(player)
		inventories[player] = inv
		-- Push an empty snapshot immediately so the HUD has a shape to draw
		-- before the first pickup.
		inv:MarkDirty()
	end
	return inv
end

function Server.find(player: Player)
	return inventories[player]
end

function Server.release(player: Player)
	local inv = inventories[player]
	if inv then
		-- BEFORE Destroy and before the map entry is cleared, which is the whole
		-- point of the seam -- see Server.Releasing above.
		Server.Releasing:Fire(player, inv)
		inv:Destroy()
		inventories[player] = nil
	end
end

function Server.all()
	return inventories
end

local started = false
function Server.start()
	assert(RunService:IsServer(), "InventoryController.Server.start is server-only")
	if started then
		return
	end
	started = true

	local function hook(player: Player)
		Server.get(player)
		-- Re-push on every spawn. The very first sync can land before the
		-- client's OnClientEvent handler exists, and a HUD that has never
		-- received a snapshot has no way to ask for one.
		player.CharacterAdded:Connect(function()
			local inv = inventories[player]
			if inv then
				inv:MarkDirty()
			end
		end)
	end

	Players.PlayerAdded:Connect(hook)
	for _, player in Players:GetPlayers() do
		hook(player)
	end
	Players.PlayerRemoving:Connect(Server.release)

	-- One coalesced flush per frame. Every view moves on the same tick, which
	-- is the whole reason the roller and the backpack can never drift apart.
	RunService.Heartbeat:Connect(function()
		for _, inv in inventories do
			if inv._dirty then
				inv._dirty = false
				inv:Replicate()
			end
		end
	end)
end

--------------------------------------------------------------------------
-- CLIENT (read-only mirror)
--------------------------------------------------------------------------

local Client = {}
InventoryController.Client = Client

Client.Items = {}
Client.Count = 0
Client.MaxCapacity = GameConfig.Inventory.MaxCapacity
Client.Changed = Signal.new()

local clientStarted = false
function Client.start()
	assert(RunService:IsClient(), "InventoryController.Client.start is client-only")
	if clientStarted then
		return
	end
	clientStarted = true

	Net.get("InventorySync").OnClientEvent:Connect(function(snapshot)
		if type(snapshot) ~= "table" then
			return
		end
		Client.Items = snapshot.items or {}
		Client.Count = snapshot.count or #Client.Items
		Client.MaxCapacity = snapshot.maxCapacity or Client.MaxCapacity
		Client.Changed:Fire(Client)
	end)
end

function Client.get(uid: string)
	for _, rec in Client.Items do
		if rec.uid == uid then
			return rec
		end
	end
	return nil
end

function Client.getByState(state: ItemState)
	local out = {}
	for _, rec in Client.Items do
		if rec.state == state then
			table.insert(out, rec)
		end
	end
	return out
end

function Client.countByState(state: ItemState): number
	local n = 0
	for _, rec in Client.Items do
		if rec.state == state then
			n += 1
		end
	end
	return n
end

-- Convenience for the HUD: "$120" for cleaned, "???" for anything else.
function Client.valueText(rec): string
	if rec.state == "Cleaned" and rec.value then
		return "$" .. rec.value
	end
	return "???"
end

return InventoryController
