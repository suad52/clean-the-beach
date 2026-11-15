--[[
	FreeRewardService  --  ServerScriptService.FreeRewardService

	Pays the free reward: 1,000 coins, once per account, to a player who is in the
	experience's group.

	WHAT IS ENFORCED IS THE WHOLE OF WHAT IS ADVERTISED, which is the point of the
	2026-08 rewrite:

		GROUP   Player:IsInGroup, asked of Roblox by the SERVER, freshly, at the
		        moment of the claim. A client cannot fake it, cannot skip it, and
		        cannot ask this module to skip it -- the remote carries a verb and
		        nothing else.

	THE LIKE STEP IS GONE. It was a button the player pressed to assert they had
	liked the game, recorded here and then required before a claim -- which is not
	a check, it is a client saying "yes" about itself, and it is exactly why the
	reward looked free to anyone who read the panel honestly. Roblox ships no API
	that could have made it a check, and rewarding an individual for a like is
	against Roblox's rules regardless. See FreeRewardConfig for both halves.

	ONE-TIME, and the shape is StarterPackService's because the hazard is the
	same: group membership, like pass ownership, is true on every future join, so a
	grant hung off it pays out every login. The claim is a SAVED flag and the same
	three rules apply -- nothing grants before the profile has loaded, a session
	guard closes the in-server race, and the write is forced immediately.

	IsInGroup IS A WEB CALL AND IT YIELDS. Every call here is pcall'd and off the
	join thread, and a failure is reported as UNKNOWN rather than as "not in the
	group" -- the same distinction GamePassService draws, and for the same reason:
	a dropped request must not read as "you do not qualify".
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local FreeRewardConfig = require(Modules:WaitForChild("FreeRewardConfig"))
local Net = require(Modules:WaitForChild("Net"))

local SaveService = require(script.Parent:WaitForChild("SaveService"))
-- The ONE grant path -- see CTBBridge's note on what going around it costs.
local SellServer = require(script.Parent:WaitForChild("SellServer"))

local FreeRewardService = {}

local CLAIMED = FreeRewardConfig.ClaimedAttribute
local IN_GROUP = FreeRewardConfig.InGroupAttribute

local LOAD_TIMEOUT = 45
local LOAD_POLL = 0.25
-- IsInGroup is a web call. A player hammering the CHECK button must not be able
-- to make this server hammer Roblox, so re-asks are rate limited per player.
local RECHECK_COOLDOWN = 3
--[[
	A CLAIM ALWAYS GETS A FRESH ANSWER, and it needs its own limit because of it.

	The cooldown above exists so a player leaning on the CHECK button cannot make
	this server lean on Roblox. Applying it to CLAIM as well was measured to be
	wrong: a player who is refused, goes and joins the group, and comes straight
	back is refused a SECOND time off the cached `false` -- the exact moment the
	answer has changed is the one moment the cache is guaranteed to be stale.

	So claiming forces a re-ask and is rate limited on its own, more loosely: one
	web call per player per 2s is a bound the platform is comfortable with, and no
	human presses a claim button faster than that with intent.
]]
local CLAIM_COOLDOWN = 2

local granting: { [Player]: boolean } = {}
local lastCheck: { [Player]: number } = {}
local lastClaim: { [Player]: number } = {}
local watching: { [Player]: RBXScriptConnection } = {}
local connections = {}
local started = false

--[[
	Ask Roblox. Returns true, false, or NIL for "the request failed" -- and the
	third is not the same as the second. Treating a dropped call as "not a member"
	would tell a player who joined the group that they had not.
]]
local function askInGroup(player: Player): boolean?
	if FreeRewardConfig.GroupId <= 0 then
		return nil
	end
	for attempt = 1, 2 do
		local ok, result = pcall(function()
			return player:IsInGroup(FreeRewardConfig.GroupId)
		end)
		if ok then
			return result == true
		end
		if attempt == 2 then
			warn(string.format("[FreeReward] could not read group membership for %s: %s",
				player.Name, tostring(result)))
		else
			task.wait(1)
		end
	end
	return nil
end

local function push(player: Player)
	if not player.Parent then
		return
	end
	-- The resolved name onto the player as well as into the payload: the panel
	-- reads the payload, but TipConfig's group line is a CLIENT string and has
	-- no payload to read. See FreeRewardConfig.GroupNameAttribute.
	player:SetAttribute(FreeRewardConfig.GroupNameAttribute, FreeRewardConfig.groupName())
	Net.get("FreeRewardSync"):FireClient(player, {
		inGroup = player:GetAttribute(IN_GROUP) == true,
		claimed = player:GetAttribute(CLAIMED) == true,
		--[[
			HAS THE PROFILE LANDED, and the pop-up is not allowed to decide anything
			until it has.

			`claimed` above is read off an attribute that SaveService stamps when it
			restores the profile -- which is a DataStore read, and races the group
			lookup this service does on join. Whichever finishes first decides what
			the first sync says, so without this the card was a coin flip for a
			returning player: claimed=false in the payload simply meant "not known
			yet", and the panel could not tell that apart from "go ahead and show
			the offer".
		]]
		loaded = SaveService.isLoaded(player),
		coins = FreeRewardConfig.Coins,
		groupId = FreeRewardConfig.GroupId,
		-- The name Roblox has for the group, not the one this codebase used to
		-- assume it had. See FreeRewardConfig.groupName.
		groupName = FreeRewardConfig.groupName(),
	})
end
FreeRewardService.push = push

--[[
	Re-ask Roblox and publish the answer. `force` skips the cooldown and is passed
	by the join sweep and by claim(), never by a remote.

	IT HANDS BACK THE TRI-STATE, not a boolean, and that is the whole reason
	askInGroup returns one. This used to end `return player:GetAttribute(IN_GROUP)
	== true`, which quietly turned "the request failed" back into THE LAST ANSWER
	WE HAPPENED TO HAVE -- so a player who was in the group at join, left it, and
	then claimed while Roblox was refusing calls was paid off a cached `true`. A
	grant must never be settled by a stale yes.
]]
local function refresh(player: Player, force: boolean?): boolean?
	local now = os.clock()
	if not force and now - (lastCheck[player] or -math.huge) < RECHECK_COOLDOWN then
		local cached = player:GetAttribute(IN_GROUP)
		if type(cached) == "boolean" then
			return cached
		end
		return nil
	end
	lastCheck[player] = now

	local answer = askInGroup(player)      -- YIELDS
	if answer ~= nil and player.Parent then
		player:SetAttribute(IN_GROUP, answer)
	end
	return answer
end

--[[
	The grant. Returns ok, reason -- the reason is for the player, so it says what
	to do rather than what failed.
]]
local function claim(player: Player): (boolean, string)
	if not player.Parent then
		return false, ""
	end
	if granting[player] then
		return false, "Already claiming..."
	end
	if player:GetAttribute(CLAIMED) == true then
		return false, "You have already claimed this reward."
	end

	local now = os.clock()
	if now - (lastClaim[player] or -math.huge) < CLAIM_COOLDOWN then
		return false, "One moment..."
	end
	lastClaim[player] = now

	--[[
		THE GATE, FORCED so it cannot answer off a stale cache -- see the note on
		CLAIM_COOLDOWN. A player who joined the group ten seconds ago must not be
		told they are not in it.

		THREE OUTCOMES, NOT TWO. "We could not reach Roblox" is not "you are not a
		member": paying on it would hand the coins to anybody who could make one web
		call fail, and refusing with the group message would send somebody who is
		standing in the group off to join a group they are already in.
	]]
	local member = refresh(player, true)   -- YIELDS
	if member == nil then
		return false, "Couldn't reach Roblox to check the group -- try again in a moment."
	end
	if not member then
		return false, string.format("Join the %s group first, then press CHECK AGAIN.",
			FreeRewardConfig.GroupName)
	end

	-- Nothing is granted before the profile has loaded: the claimed flag arrives
	-- with it, so a check that runs first reads a player who has already claimed
	-- as unclaimed. See StarterPackService for the same three rules.
	local waited = 0
	while not SaveService.isLoaded(player) do
		if waited >= LOAD_TIMEOUT or not player.Parent then
			warn(string.format("[FreeReward] %s qualified but their profile never loaded "
				.. "after %ds -- granting nothing.", player.Name, LOAD_TIMEOUT))
			return false, "Your save is still loading -- try again in a moment."
		end
		task.wait(LOAD_POLL)
		waited += LOAD_POLL
	end

	if granting[player] or player:GetAttribute(CLAIMED) == true then
		return false, "You have already claimed this reward."
	end
	granting[player] = true

	-- Flag BEFORE the coins move, so nothing running during the grant can read
	-- this player as unclaimed.
	player:SetAttribute(CLAIMED, true)
	SellServer.addCoins(player, FreeRewardConfig.Coins, "group")

	local okSave, wrote = pcall(SaveService.forceSave, player)
	if not (okSave and wrote) then
		warn(string.format("[FreeReward] granted to %s but the forced save did not land "
			.. "-- the profile is dirty and will be written on leave. Not rolled back: a "
			.. "retry would pay twice.", player.Name))
	end
	granting[player] = nil

	push(player)
	print(string.format("[FreeReward] granted %d coins to %s",
		FreeRewardConfig.Coins, player.Name))
	return true, string.format("Claimed! %d coins added.", FreeRewardConfig.Coins)
end
FreeRewardService.claim = claim

local function watch(player: Player)
	lastCheck[player] = nil
	lastClaim[player] = nil
	-- Off the join thread: askInGroup is a web call.
	task.spawn(function()
		refresh(player, true)
		push(player)

		--[[
			AND AGAIN ONCE THE PROFILE IS IN, which is the sync the pop-up actually
			acts on.

			The attribute watcher below only fires when CLAIMED *changes*, so a
			player who has never claimed gets no second push from it -- the exact
			player the card is for would never be told it was safe to appear. This
			is that second push, and it is unconditional.
		]]
		local waited = 0
		while not SaveService.isLoaded(player) and waited < LOAD_TIMEOUT do
			if not player.Parent then
				return
			end
			task.wait(LOAD_POLL)
			waited += LOAD_POLL
		end
		push(player)
	end)

	-- The claimed flag lands with the profile, well after the first push, so the
	-- panel has to be told again when it does.
	if watching[player] then
		watching[player]:Disconnect()
	end
	watching[player] = player:GetAttributeChangedSignal(CLAIMED):Connect(function()
		push(player)
	end)
end

function FreeRewardService.start()
	assert(RunService:IsServer(), "[FreeReward] server-only")
	if started then
		return
	end
	started = true

	if FreeRewardConfig.GroupId <= 0 then
		warn("[FreeReward] no group id -- the reward cannot be gated and is disabled.")
		return
	end

	-- Warm the name lookup off the boot thread, so the first player's push is
	-- never the thing that pays for the round trip. Spawned rather than awaited:
	-- nothing below needs the name, and a slow web call must not hold up the
	-- remote being connected.
	task.spawn(FreeRewardConfig.groupName)

	--[[
		A VERB, AND NOTHING ELSE. The client never sends an amount and never sends
		"I am in the group": every precondition this module cares about, it goes
		and establishes itself. The only thing the payload decides is which of the
		two things to do.
	]]
	connections[#connections + 1] = Net.get("FreeRewardClaim").OnServerEvent
		:Connect(function(player, action)
			--[[
				STUDIO ONLY, and it is the reason this verb is safe to have at all:
				RunService:IsStudio() is false on every live server, so a client that
				sends "reset" in production reaches a branch that does nothing.

				It exists because the one-time flags are held once set (see
				SaveService.clearOneTimeFlag) -- without it, testing this reward once
				burns the tester's account permanently, which is exactly what
				happened while it was being built.
			]]
			if action == "reset" then
				if not RunService:IsStudio() then
					return
				end
				player:SetAttribute(CLAIMED, nil)
				SaveService.clearOneTimeFlag(player, "freeRewardClaimed")
				pcall(SaveService.forceSave, player)
				push(player)
				print("[FreeReward] reset for " .. player.Name .. " (Studio only)")
			elseif action == "check" then
				refresh(player)
				push(player)
			elseif action == "claim" then
				local ok, reason = claim(player)
				if reason ~= "" then
					Net.get("Notify"):FireClient(player, {
						text = reason,
						kind = ok and "pickup" or "warn",
					})
				end
				push(player)
			end
		end)

	connections[#connections + 1] = Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	connections[#connections + 1] = Players.PlayerRemoving:Connect(function(player)
		granting[player] = nil
		lastCheck[player] = nil
		lastClaim[player] = nil
		if watching[player] then
			watching[player]:Disconnect()
			watching[player] = nil
		end
	end)

	print(string.format("[FreeReward] online -- %d coins for joining group %d,"
		.. " checked with Player:IsInGroup at the moment of the claim",
		FreeRewardConfig.Coins, FreeRewardConfig.GroupId))
end

return FreeRewardService
