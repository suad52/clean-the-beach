--[[
	CodeService  --  ServerScriptService.CodeService

	Owns the RedeemCode remote and nothing else. The codes themselves, what they
	pay and how a typed string becomes a key all live in CodeConfig, which is
	replicated so the panel can tell a player how many they have left to find
	without asking the server.

	WHAT THE CLIENT IS TRUSTED WITH: a string, bounded before it is looked at.
	Everything else -- whether the code exists, whether this account has already
	had it, what it is worth at this player's tide -- is re-derived here.

	THE SAME REFUSAL FOR "NO SUCH CODE" AND FOR RUBBISH, deliberately. A message
	that distinguishes a wrong guess from a malformed one tells somebody
	brute-forcing the table that they are close, which is the only thing that
	makes a code table worth brute-forcing at all.

	ALREADY-REDEEMED IS ITS OWN ANSWER, though, because that one is not a secret
	and a player who forgot they used a code deserves to be told rather than left
	thinking it expired.

	RATE LIMITED, because a text box wired to a remote is the cheapest thing in
	the game to hammer. One attempt a second per player, answered rather than
	dropped -- see the note at the gate.

	PAID THROUGH SellServer.addCoins LIKE EVERYTHING ELSE, tagged "code" so the
	economy report can tell announced giveaways from earned income.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Net = require(Modules:WaitForChild("Net"))
local CodeConfig = require(Modules:WaitForChild("CodeConfig"))

local CodeService = {}

local SellServer = nil    -- resolved in start(); see BuddyService for why not here

local ATTEMPT_GAP = 1.0
local lastTry: { [Player]: number } = {}
local connections: { RBXScriptConnection } = {}
local started = false

local function notify(player: Player, text: string, kind: string)
	Net.get("Notify"):FireClient(player, { text = text, kind = kind })
end

--[[
	Scaled by the run, the same way RewardsServer scales its ladders and for the
	same reason. Read off the attribute the rebirth panel advertises, so a code
	is worth what the player would expect a reward to be worth at their tide.
]]
local function scaled(player: Player, coins: number): number
	local mult = player:GetAttribute("SellMultiplier")
	if type(mult) ~= "number" or mult ~= mult or mult <= 0 then
		mult = 1
	end
	return math.max(1, math.floor(coins * mult + 0.5))
end

local function onRedeem(player: Player, input: any)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end

	-- Bounded BEFORE the contents are looked at: a remote that accepts a string
	-- accepts whatever length the client felt like sending.
	if type(input) ~= "string" or #input > CodeConfig.MaxLength * 4 then
		return
	end

	local now = os.clock()
	if now - (lastTry[player] or -math.huge) < ATTEMPT_GAP then
		-- Answered, not dropped. A silent refusal reads as a broken button, and
		-- the honest hiccup this catches is somebody pressing twice.
		notify(player, "One at a time!", "warn")
		return
	end
	lastTry[player] = now

	local entry, key = CodeConfig.find(input)
	if not entry then
		notify(player, "That code is not valid.", "deny")
		return
	end

	local attr = CodeConfig.AttrPrefix .. key
	if player:GetAttribute(attr) == true then
		notify(player, "You have already used that code.", "warn")
		return
	end

	-- Stamped BEFORE the payout, so a second press that arrives while addCoins
	-- is still running cannot be paid twice. addCoins does not yield today; this
	-- does not depend on that staying true.
	player:SetAttribute(attr, true)

	local coins = scaled(player, entry.coins or 0)
	SellServer.addCoins(player, coins, "code")
	notify(player, string.format("%s  +%s coins", entry.note or "Code redeemed!",
		tostring(coins)), "pickup")
end

function CodeService.start()
	assert(RunService:IsServer(), "[CodeService] server-only")
	if started then
		return
	end
	started = true

	SellServer = require(ServerScriptService:WaitForChild("SellServer"))

	table.insert(connections, Net.get("RedeemCode").OnServerEvent:Connect(onRedeem))
	table.insert(connections, Players.PlayerRemoving:Connect(function(player)
		lastTry[player] = nil
	end))

	print(string.format("[Codes] online -- %d code(s), once per account, scaled by the run",
		#CodeConfig.Codes))
end

function CodeService.stop()
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
	table.clear(lastTry)
	started = false
end

return CodeService
