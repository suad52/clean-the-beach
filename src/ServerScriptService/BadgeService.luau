--[[
	BadgeService  --  ServerScriptService.BadgeService

	Awards the badges in BadgeConfig. Nothing else.

	IT WATCHES ATTRIBUTES RATHER THAN HOOKING THE THINGS THAT MOVE THEM.
	`Rebirths` and `AtvTier` are both written by exactly one place already
	(ProgressionServer.onRebirth and AtvServer/GamePassService), they replicate,
	and they are the definition of the thing each badge is about. Hooking the
	rebirth handler instead would put badge logic inside the most delicate
	function in the game for no gain.

	EVERY AWARD IS pcall'd AND SPAWNED. AwardBadge is a web call: it yields, it
	throws when the badge service is having a moment, and it throws outright on a
	badge id that does not exist. None of that may ever be allowed to interrupt a
	rebirth, which is what would happen if this ran inline on the attribute
	signal.

	ROBLOX DEDUPLICATES FOR US. AwardBadge is idempotent -- a player who already
	holds a badge is not re-awarded and nothing errors -- so this keeps no record
	of who has what and needs no save data. The only bookkeeping here is a
	per-session set to avoid spamming the web call on an attribute that changes
	often.

	CHECKED ON JOIN AS WELL AS ON CHANGE, because the attribute a returning
	player arrives with is not a change -- SaveService writes it during the load
	and a listener wired afterwards would never see it. A player who earned tide
	48 before these badges existed gets them the next time they log in.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local BadgeService_ = game:GetService("BadgeService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local BadgeConfig = require(Modules:WaitForChild("BadgeConfig"))

local BadgeService = {}

-- [Player] = { [badgeKey] = true } -- one session, see the header.
local awarded: { [Player]: { [string]: boolean } } = {}
local connections: { RBXScriptConnection } = {}
local started = false

local function earned(player: Player, entry): boolean
	if entry.needsCar then
		local tier = player:GetAttribute("AtvTier")
		return type(tier) == "number" and tier > 0
	end
	local n = player:GetAttribute("Rebirths")
	return type(n) == "number" and n >= (entry.rebirths or math.huge)
end

local function sweep(player: Player)
	if not player.Parent then
		return
	end
	local mine = awarded[player]
	if not mine then
		return
	end
	for _, entry in BadgeConfig.Badges do
		if BadgeConfig.isLive(entry) and not mine[entry.key] and earned(player, entry) then
			-- Marked before the call, not after: AwardBadge yields, and a second
			-- attribute change arriving mid-flight would otherwise fire a second
			-- request for the same badge.
			mine[entry.key] = true
			task.spawn(function()
				local ok, err = pcall(function()
					BadgeService_:AwardBadge(player.UserId, entry.id)
				end)
				if not ok then
					-- Un-marked so a later sweep can retry: a failure here is
					-- usually the service being briefly unavailable, and the
					-- player has genuinely earned the thing.
					mine[entry.key] = nil
					warn(string.format("[Badges] could not award %s (%d): %s",
						entry.name, entry.id, tostring(err)))
				end
			end)
		end
	end
end

local function watch(player: Player)
	awarded[player] = {}
	for _, attr in ipairs({ "Rebirths", "AtvTier" }) do
		table.insert(connections, player:GetAttributeChangedSignal(attr):Connect(function()
			sweep(player)
		end))
	end
	-- See the header: the load writes these before anything here is listening.
	task.delay(8, function()
		sweep(player)
	end)
end

function BadgeService.start()
	assert(RunService:IsServer(), "[BadgeService] server-only")
	if started then
		return
	end
	started = true

	for _, player in ipairs(Players:GetPlayers()) do
		watch(player)
	end
	table.insert(connections, Players.PlayerAdded:Connect(watch))
	table.insert(connections, Players.PlayerRemoving:Connect(function(player)
		awarded[player] = nil
	end))

	--[[
		THE SAME WARNING ProductServer GIVES, for the same reason: a badge that
		has not been created on the Dashboard cannot be awarded, and the failure
		is silent -- AwardBadge on id 0 simply throws into a pcall and nobody
		ever sees it. Named individually so the fix is a copy and a paste.
	]]
	local pending = BadgeConfig.pending()
	local live = BadgeConfig.live()
	if #pending > 0 then
		local names = {}
		for _, entry in pending do
			table.insert(names, string.format("%s (%s)", entry.name, entry.key))
		end
		warn(string.format(
			"[Badges] %d badge(s) are written but not yet created on the Creator "
			.. "Dashboard, so they cannot be awarded: %s. Create each one "
			.. "(Communication -> Badges, 100 Robux each), paste its id into "
			.. "BadgeConfig -- no code change is needed after that.",
			#pending, table.concat(names, ", ")))
	end
	print(string.format("[Badges] online -- %d live, %d awaiting an id", #live, #pending))
end

function BadgeService.stop()
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
	table.clear(awarded)
	started = false
end

return BadgeService
