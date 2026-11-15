--[[
	BuddyService  --  ServerScriptService.BuddyService

	Keeps BuddyConfig.Attribute current on every player: how many of the people
	on this server are on their Roblox friends list.

	THE ONLY HARD PART IS THAT IsFriendsWith IS A WEB CALL. It yields, it can
	throw, and it is rate limited. A naive sweep is O(n^2) calls on every join,
	which on a thirty-player server is nine hundred requests for one arrival.

	SO EVERY PAIR IS ASKED ABOUT ONCE, EVER. The answer is cached under an
	unordered key for the life of the server, which is correct for the thing
	being asked: two people either are friends or they are not, and somebody
	befriending a stranger mid-session is not worth nine hundred requests to
	notice. A join therefore costs at most one call per player already here, and
	a rejoin costs none.

	A FAILURE READS AS "NOT FRIENDS", never as "sure". The call is pcall'd and a
	thrown request is cached as false -- the same way FeedbackServer's admin
	check treats a GetRankInGroup outage. Paying a bonus on a failed lookup would
	be the wrong direction to be wrong in.

	RECOUNTS ARE DEBOUNCED, because joins arrive in bursts when a server fills
	and each one would otherwise walk the whole roster. One pass settles whatever
	happened during the wait.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local BuddyConfig = require(Modules:WaitForChild("BuddyConfig"))

local BuddyService = {}

-- How long to let joins pile up before recounting. Long enough that filling a
-- server is one pass rather than thirty, short enough that a friend arriving
-- feels immediate.
local SETTLE = 1.5

local friendsWith: { [string]: boolean } = {}
local connections: { RBXScriptConnection } = {}
local started = false
local pending = false

local function pairKey(a: number, b: number): string
	return (a < b) and (a .. "_" .. b) or (b .. "_" .. a)
end

local function areFriends(p1: Player, p2: Player): boolean
	local key = pairKey(p1.UserId, p2.UserId)
	local known = friendsWith[key]
	if known ~= nil then
		return known
	end
	local ok, verdict = pcall(function()
		return p1:IsFriendsWith(p2.UserId)
	end)
	local answer = (ok and verdict == true)
	friendsWith[key] = answer
	return answer
end

--[[
	One pass over the roster. Yields -- see areFriends -- so it is only ever
	called from a spawned thread, and it re-reads Players at the top rather than
	taking a list from the caller: anything that happened during the settle
	window should be in this count, not the next one.
]]
local function recount()
	local players = Players:GetPlayers()
	local count: { [Player]: number } = {}
	for _, p in ipairs(players) do
		count[p] = 0
	end
	for i = 1, #players - 1 do
		for j = i + 1, #players do
			local a, b = players[i], players[j]
			-- Both may have left during an earlier yield in this same pass.
			if a.Parent and b.Parent and areFriends(a, b) then
				count[a] += 1
				count[b] += 1
			end
		end
	end
	for player, n in pairs(count) do
		if player.Parent then
			player:SetAttribute(BuddyConfig.Attribute, math.min(n, BuddyConfig.MaxBuddies))
		end
	end
end

local function schedule()
	if pending then
		return
	end
	pending = true
	task.delay(SETTLE, function()
		pending = false
		local ok, err = pcall(recount)
		if not ok then
			warn("[BuddyService] recount failed: " .. tostring(err))
		end
	end)
end

function BuddyService.start()
	assert(RunService:IsServer(), "[BuddyService] server-only")
	if started then
		return
	end
	started = true

	-- Zeroed on arrival so the attribute always exists: BuddyConfig.countFor
	-- copes with nil, but a HUD that binds to an attribute change never sees the
	-- first value if the attribute was not there to change.
	table.insert(connections, Players.PlayerAdded:Connect(function(player)
		player:SetAttribute(BuddyConfig.Attribute, 0)
		schedule()
	end))
	for _, player in ipairs(Players:GetPlayers()) do
		if player:GetAttribute(BuddyConfig.Attribute) == nil then
			player:SetAttribute(BuddyConfig.Attribute, 0)
		end
	end

	-- A leaver lowers everybody else's count, so this matters as much as a join.
	table.insert(connections, Players.PlayerRemoving:Connect(function()
		schedule()
	end))

	schedule()
	print(string.format("[Buddies] online -- +%d%% a friend on your server, up to %d (x%.2f)",
		math.floor(BuddyConfig.PerBuddy * 100 + 0.5), BuddyConfig.MaxBuddies,
		1 + BuddyConfig.MaxBuddies * BuddyConfig.PerBuddy))
end

function BuddyService.stop()
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
	table.clear(friendsWith)
	started = false
end

return BuddyService
