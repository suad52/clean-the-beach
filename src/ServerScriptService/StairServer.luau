--[[
	SWEEPING THE ASHEN STAIR -- the authoritative half.

	The volcano's road is buried in ash and the player cuts a path up it with the
	same sifter that rakes the sand. This owns the state, the sweep and the payout;
	ReplicatedStorage.CTB.Stair owns the geometry; StairClient draws it.

	========================================================================
	IT IS DELIBERATELY NOT PART OF ASHFALL'S FIELD
	========================================================================

	The stair could not be an entry in Config.ISLANDS -- see the header of
	CTB.Stair for the three reasons -- but even if it could, it should not be, and
	the reason is resetAt.

	Every island turns over at 1.0: the tide fires only when EVERY cell is raked.
	Folding 560 cells spread up a 186-stud mountain into that test would mean one
	unreachable tread -- a lava plate that drifted, a torch scaled up, a cairn
	placed an inch too far in -- permanently and silently killing Ashfall's tide
	for every player who ever visits. So the stair keeps its own counter and pays
	its own bonus, and the worst a broken tread can cost is that one bonus.

	========================================================================
	STATE
	========================================================================

	Per player, never shared, and thrown away when they leave -- exactly the
	contract CTB_Server's grids keep, and for the same reason: raked progress is
	private, so two people on the same stair each cut their own path up it.

	`gen` retires work in flight. A rebirth landing between a sweep and its
	completion payout must not pay, and it is the same latch CTB_Server's
	wipeGen is.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CTB = ReplicatedStorage:WaitForChild("CTB")
local Stair = require(CTB:WaitForChild("Stair"))
local Bridge = require(ServerScriptService:WaitForChild("CTBBridge"))

local StairServer = {}

local Net = nil
local state = {}

-- Cell count is not known until Island4Builder has poured the mountain, so the
-- arrays are grown lazily rather than sized at join.
local function grid(plr)
	local st = state[plr]
	if not st then
		return nil
	end
	local n = Stair.count()
	if n == 0 then
		return nil
	end
	if st.size ~= n then
		-- The stair arrived, or was repoured at a different length. Either way the
		-- old indices mean nothing; start clean rather than reinterpret them.
		st.clean = table.create(n, false)
		st.count = 0
		st.size = n
		st.done = false
	end
	return st
end

function StairServer.attach(plr: Player)
	state[plr] = { clean = {}, count = 0, size = -1, done = false, gen = 0 }
end

function StairServer.detach(plr: Player)
	state[plr] = nil
end

-- Everything the client needs to draw the stair as this player has left it.
-- Fired on their Ready, the same beat CTB_Server syncs the fields.
function StairServer.sync(plr: Player)
	local st = grid(plr)
	if not st or not Net then
		return
	end
	local list = {}
	for i = 1, st.size do
		if st.clean[i] then
			list[#list + 1] = i
		end
	end
	Net:FireClient(plr, "StairSync", st.size, list)
end

--[[
	PUT THE ASH BACK.

	`pay` is false for a rebirth, which takes everything and gives nothing, and
	irrelevant for a tide, which has already paid for the island. Bumping gen
	retires any completion payout still queued.
]]
function StairServer.reset(plr: Player)
	local st = state[plr]
	if not st then
		return
	end
	st.gen += 1
	local had = st.count > 0
	st.clean = table.create(math.max(st.size, 0), false)
	st.count = 0
	st.done = false
	if had and Net then
		Net:FireClient(plr, "StairReset")
	end
end

function StairServer.resetAll()
	for plr in pairs(state) do
		StairServer.reset(plr)
	end
end

--[[
	ONE TICK OF THE SWEEP.

	Handed the tool point WITH ITS HEIGHT INTACT. CTB_Server flattens its own
	copy to y = 0 before it does anything else, which is correct for a flat field
	and catastrophic here -- without the Y term a player at the top of the stair
	would clear the flight they climbed half an hour ago, sixty studs beneath
	their feet, and a player on the sand would clear the stair from the ground.

	Cheap when it is not relevant: Stair.covered culls all 34 treads on their own
	centres before it looks at a single cell.
]]
local scratch = {}

function StairServer.sweep(plr: Player, point: Vector3, look: Vector3, right: Vector3,
	hw: number, hd: number)
	local st = grid(plr)
	if not st or st.done then
		return
	end
	table.clear(scratch)
	Stair.covered(point, look, right, hw, hd, scratch)
	if #scratch == 0 then
		return
	end

	local batch = nil
	for _, idx in ipairs(scratch) do
		if not st.clean[idx] then
			st.clean[idx] = true
			st.count += 1
			batch = batch or {}
			batch[#batch + 1] = idx
		end
	end
	if not batch then
		return
	end
	if Net then
		Net:FireClient(plr, "StairClean", batch)
	end

	if st.count < st.size then
		return
	end

	--[[
		SWEPT. Paid once, then latched -- `done` stops the sweep re-entering this
		branch every tick for a player standing on the top step, which would be a
		payout at 24 Hz. Only reset() clears it.

		Scaled by SellMultiplier, exactly as the tide's bonus is, and paid through
		the bridge rather than straight onto the attribute: that is the path that
		fires the grant hook, which is what counts it toward the next rebirth and
		repaints the shop's purse.
	]]
	st.done = true
	local mult = plr:GetAttribute("SellMultiplier")
	if type(mult) ~= "number" or mult ~= mult or mult <= 0 then
		mult = 1
	end
	local bonus = math.floor(Stair.BONUS * mult + 0.5)
	Bridge.addCoins(plr, bonus, "stair")
	if Net then
		Net:FireClient(plr, "StairDone", bonus)
	end
end

-- How far up the stair this player has got, 0..1, and the raw counts with it.
function StairServer.progress(plr: Player): (number, number, number)
	local st = grid(plr)
	if not st or st.size <= 0 then
		return 0, 0, 0
	end
	return st.count / st.size, st.count, st.size
end

function StairServer.start(net)
	Net = net
	for _, plr in ipairs(Players:GetPlayers()) do
		if not state[plr] then
			StairServer.attach(plr)
		end
	end
	Players.PlayerRemoving:Connect(StairServer.detach)
	local treads, cells = Stair.treads()
	print(string.format("[Stair] the Ashen Stair is sweepable: %d treads, %d cells, %d coins to clear it",
		treads and #treads or 0, cells, Stair.BONUS))
end

return StairServer
