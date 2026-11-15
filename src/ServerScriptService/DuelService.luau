--[[
	DuelService  --  ServerScriptService.DuelService

	Owns THE CLEAN-OFF: who challenged whom, which arena they got, the race
	itself, who won, and getting both of them home again.

	THE SERVER OWNS EVERY FACT THAT DECIDES THE MATCH. The client sends exactly
	two things -- "I challenge that player" and "I accept / decline" -- and both
	are re-validated here. It never sends a pickup, a score or a finish: a race
	where the client reports its own progress is a race won by whoever edits
	their client. Pickups are a server-side proximity test on the server's own
	litter, exactly like the sell pad's.

	THE ARENA IS CLAIMED BEFORE ANYTHING CAN YIELD -- same rule as the idle
	shore's bays, and for the same reason: two accepts landing in the same frame
	both allocate arena 1 unless the claim is adjacent to the search. There is a
	marked pair of lines below that nothing may go between.

	A MATCH IS A TABLE AND CHECKS ARE ON ITS IDENTITY, never on a flag. `enter`
	and the phases yield repeatedly; asking "is this player in a duel?" after a
	yield cannot tell THIS match from the next one they started.

	NOTHING HERE PAYS OUT. The clean-off is purely competitive: no coins for a
	win, none for a draw, and nothing for turning up. This file deliberately
	holds NO reference to CTBBridge or any other coin path, so a payout cannot be
	added here by accident -- see WHAT A WIN IS WORTH in DuelConfig, which owns
	the argument. A win increments DuelConfig.WinsAttr and that is the whole
	ledger.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local DuelConfig = require(Modules:WaitForChild("DuelConfig"))
local Net = require(Modules:WaitForChild("Net"))
-- Only for the walking floor, and only as the fallback when ProgressionServer
-- cannot be reached. It was a literal 16 -- see ProgressionConfig.BaseWalkSpeed.
local ProgressionConfig = require(Modules:WaitForChild("ProgressionConfig"))

local DuelArenaBuilder = require(script.Parent:WaitForChild("DuelArenaBuilder"))

local DuelService = {}

local arenaFolder: Folder? = nil
local occupant = {}          -- arena index -> match
local matches = {}           -- player -> match
local invites = {}           -- target player -> { from, expires }
local started = false

--------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------

local function arenaModel(i: number): Model?
	local root = arenaFolder or workspace:FindFirstChild(DuelConfig.FolderName)
	local m = root and root:FindFirstChild(("Arena_%d"):format(i))
	return (m and m:IsA("Model")) and m or nil
end

local function spawnCFrame(i: number, side: number): CFrame
	local m = arenaModel(i)
	local s = m and m:FindFirstChild(("Spawn_%d"):format(side))
	if s and s:IsA("BasePart") then
		return s.CFrame + Vector3.new(0, 2, 0)
	end
	return CFrame.new(DuelConfig.pitchCentre(i, side) + Vector3.new(0, 6, 0))
end

local function homeOf(match, plr): CFrame
	local h = match and match.home and match.home[plr]
	if typeof(h) == "CFrame" then return h end
	local spawn = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	return spawn and (spawn.CFrame + Vector3.new(0, 4, 0)) or CFrame.new(0, 8, -135)
end

local function pushState(plr: Player, payload)
	Net.get("DuelState"):FireClient(plr, payload)
end

--[[
	ONE LINE OF FEEDBACK, ON THE CHANNEL THE REST OF THE GAME ALREADY USES.

	Notify is the game-wide toast remote and FeedbackClient is what draws it.
	It DROPS any payload that is not a table carrying a `text` string, which is
	why the two calls in the reply handler that passed a bare string have never
	put anything on screen. Every refusal the duel door hands out goes through
	here instead, so pressing CHALLENGE can no longer be answered with silence --
	success and five different refusals used to look identical from the
	challenger's side. Added 2026-09-09.
]]
local function notify(plr: Player, text: string, kind: string?)
	if not (plr and plr.Parent) then return end
	Net.get("Notify"):FireClient(plr, { text = text, kind = kind or "info" })
end

function DuelService.isDuelling(plr: Player): boolean
	return matches[plr] ~= nil
end

--------------------------------------------------------------------------
-- THE LITTER
--------------------------------------------------------------------------

--[[
	SEEDED AND MIRRORED.

	One Random per match drives BOTH pitches, and side 2's x is the negation of
	side 1's about the arena centre -- so the two players are given the same
	problem rotated, not two different scatters. A race on unequal boards is not
	a race.

	The props are the arena's own and are destroyed with the match. Nothing here
	touches the inventory, the sell pad or the rakeable field; see the long note
	in DuelConfig for why.
]]
local function spawnLitter(match)
	local t = DuelConfig.Arenas[match.arena]
	local W, D = DuelConfig.PitchWidth, DuelConfig.PitchDepth
	local rng = Random.new(match.seed)
	local folder = Instance.new("Folder")
	folder.Name = "Litter"
	folder.Parent = arenaModel(match.arena)
	match.litterFolder = folder
	match.litter = { {}, {} }

	for n = 1, DuelConfig.LitterCount do
		-- Kept off the very edge so nothing spawns inside a wall.
		local lx = rng:NextNumber(-W * 0.40, W * 0.40)
		local lz = rng:NextNumber(-D * 0.42, D * 0.42)
		local spin = rng:NextNumber(0, 6.28)
		local kind = rng:NextInteger(1, 3)
		for side = 1, 2 do
			local c = DuelConfig.pitchCentre(match.arena, side)
			-- MIRRORED: side 2 gets the same layout flipped across the divider.
			local x = (side == 1) and lx or -lx
			local p = Instance.new("Part")
			p.Name = "Litter"
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.Material = Enum.Material.SmoothPlastic
			p.Color = t.accent
			if kind == 1 then
				p.Size = Vector3.new(1.6, 2.2, 1.6)
			elseif kind == 2 then
				p.Size = Vector3.new(2.4, 0.8, 1.6)
			else
				p.Size = Vector3.new(1.8, 1.8, 1.8)
				p.Shape = Enum.PartType.Ball
			end
			p.CFrame = CFrame.new(c + Vector3.new(x, 1.4, lz)) * CFrame.Angles(0, spin, 0)
			p.Parent = folder
			-- A glow ring, so a piece reads at a distance across a 76-stud pitch.
			local ring = Instance.new("Part")
			ring.Name = "Ring"
			ring.Size = Vector3.new(0.3, 3.4, 3.4)
			ring.Shape = Enum.PartType.Cylinder
			ring.Orientation = Vector3.new(0, 0, 90)
			ring.Anchored, ring.CanCollide, ring.CanQuery = true, false, false
			ring.Material = Enum.Material.Neon
			ring.Color = t.accent
			ring.Transparency = 0.35
			ring.CFrame = CFrame.new(c + Vector3.new(x, 0.2, lz))
			ring.Parent = p
			table.insert(match.litter[side], p)
		end
	end
end

local function clearLitter(match)
	if match.litterFolder then
		match.litterFolder:Destroy()
		match.litterFolder = nil
	end
	match.litter = nil
end

--------------------------------------------------------------------------
-- THE MATCH
--------------------------------------------------------------------------

local function snapshotFor(match, plr)
	local side = match.side[plr]
	local other = (side == 1) and 2 or 1
	local t = DuelConfig.Arenas[match.arena]
	return {
		phase = match.phase,
		arenaKey = t.key,
		arenaName = t.name,
		blurb = t.blurb,
		youLeft = match.left[side],
		theyLeft = match.left[other],
		total = DuelConfig.LitterCount,
		oppName = match.names[other],
		seconds = match.seconds,
		result = match.resultFor and match.resultFor[plr] or nil,
		-- The only thing a win is worth. Sent rather than read off the attribute
		-- client-side so the result card and the score come from one push.
		wins = plr:GetAttribute(DuelConfig.WinsAttr) or 0,
	}
end

local function broadcast(match)
	for _, plr in ipairs(match.players) do
		if plr.Parent then
			pushState(plr, snapshotFor(match, plr))
		end
	end
end

-- Ends a match from any phase and puts both players back. Safe to call twice.
local function finish(match, reason: string)
	if match.over then return end
	match.over = true
	match.phase = "done"

	for _, plr in ipairs(match.players) do
		matches[plr] = nil
		if plr.Parent then
			plr:SetAttribute(DuelConfig.Attr, nil)
			plr:SetAttribute(DuelConfig.SideAttr, nil)
			local char = plr.Character
			if char then
				char:PivotTo(homeOf(match, plr))
				--[[
					AND THEY GET THEIR LEGS BACK HERE, because this is the one
					exit every ending of a match funnels through.

					runMatch freezes both players at WalkSpeed 0 for the count-in
					and hands movement back on the line after it. A match that
					ends DURING the count-in -- the opponent quit, died, or the
					pcall around runMatch blew up -- returns out of that loop
					before ever reaching it, and finish() cleared the attributes
					and teleported the survivor home without touching WalkSpeed.
					They stood frozen where they landed until they reset their
					character: nothing else re-derives it, since
					ProgressionServer.applyAll only runs on join, respawn,
					purchase, rebirth and save restore. Fixed 2026-09-09.

					BaseWalkSpeed is ProgressionServer publishing what it just
					wrote -- that module owns WalkSpeed and this is the number it
					says to hand back. ProgressionConfig.BaseWalkSpeed is only the
					fallback for the window before it has been written.

					The restore in runMatch stays: it is correct for the normal
					path, where the race has to start the moment the count hits 0
					and not when the match ends.
				]]
				local hum = char:FindFirstChildOfClass("Humanoid")
				if hum and hum.Health > 0 then
					hum.WalkSpeed = plr:GetAttribute("BaseWalkSpeed") or ProgressionConfig.BaseWalkSpeed
				end
			end
			pushState(plr, nil)
		end
	end
	clearLitter(match)
	if occupant[match.arena] == match then
		occupant[match.arena] = nil
	end
	print(("[Duel] arena %d released (%s)"):format(match.arena, reason))
end

-- Lowest free arena; nil when all four are running.
local function allocate(): number?
	for i = 1, #DuelConfig.Arenas do
		if occupant[i] == nil then return i end
	end
	return nil
end

local function runMatch(match)
	local cfg = DuelConfig

	-- PLACE THEM. Both characters to their own pitch, frozen for the count-in
	-- so neither can steal a start.
	for _, plr in ipairs(match.players) do
		local side = match.side[plr]
		plr:SetAttribute(cfg.Attr, match.arena)
		plr:SetAttribute(cfg.SideAttr, side)
		local char = plr.Character
		if char then
			char:PivotTo(spawnCFrame(match.arena, side))
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum then hum.WalkSpeed = 0 end
		end
	end

	spawnLitter(match)
	match.left = { cfg.LitterCount, cfg.LitterCount }

	-- COUNT IN
	match.phase = "countdown"
	for s = cfg.CountdownSeconds, 1, -1 do
		if match.over then return end
		match.seconds = s
		broadcast(match)
		task.wait(1)
	end
	if match.over then return end

	-- GO
	match.phase = "race"
	match.seconds = cfg.RoundSeconds
	for _, plr in ipairs(match.players) do
		local char = plr.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum then
			-- Back to whatever their run has earned them, not a flat number.
			local ok, Progression = pcall(function()
				return require(script.Parent:WaitForChild("ProgressionServer", 5))
			end)
			hum.WalkSpeed = (ok and Progression and Progression.effectOf(plr, "BeachLegs"))
				or ProgressionConfig.BaseWalkSpeed
		end
	end
	broadcast(match)

	local deadline = os.clock() + cfg.RoundSeconds
	local lastPush = 0
	while not match.over do
		task.wait(0.1)
		if match.over then return end

		-- PICKUPS, tested on the server against the server's own props.
		for _, plr in ipairs(match.players) do
			local side = match.side[plr]
			local char = plr.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp and match.litter then
				local bag = match.litter[side]
				for i = #bag, 1, -1 do
					local p = bag[i]
					if not p.Parent then
						table.remove(bag, i)
					elseif (p.Position - hrp.Position).Magnitude <= cfg.PickupRadius then
						p:Destroy()
						table.remove(bag, i)
						match.left[side] = #bag
					end
				end
			end
		end

		local remaining = math.max(0, math.ceil(deadline - os.clock()))
		match.seconds = remaining

		-- Pushed at 5 Hz rather than 10: the HUD is a two-digit counter and a
		-- clock, and neither needs a packet every tick.
		if os.clock() - lastPush > 0.2 then
			lastPush = os.clock()
			broadcast(match)
		end

		if match.left[1] <= 0 or match.left[2] <= 0 or remaining <= 0 then
			break
		end
	end
	if match.over then return end

	-- RESULT. One answer, from one function, for both end conditions.
	local winner = DuelConfig.winnerOf(match.left[1], match.left[2])
	match.phase = "result"
	match.resultFor = {}
	for _, plr in ipairs(match.players) do
		local side = match.side[plr]
		local res = (winner == 0) and "draw" or ((winner == side) and "win" or "lose")
		match.resultFor[plr] = res
		-- The win counter is the ONLY thing this hands out. No coins here, by
		-- design; DuelConfig says why.
		if res == "win" then
			plr:SetAttribute(DuelConfig.WinsAttr, (plr:GetAttribute(DuelConfig.WinsAttr) or 0) + 1)
		end
	end
	match.seconds = DuelConfig.ResultSeconds
	broadcast(match)

	task.wait(DuelConfig.ResultSeconds)
	finish(match, "played out")
end

--------------------------------------------------------------------------
-- THE DOOR
--------------------------------------------------------------------------

local function canDuel(plr: Player): (boolean, string?)
	if not plr or not plr.Parent then return false, "gone" end
	if matches[plr] then return false, "already duelling" end
	local char = plr.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return false, "not alive" end
	return true
end

local function beginMatch(a: Player, b: Player)
	-- Anyone idling on the shore is woken FIRST and without being moved -- the
	-- duel is about to move them. Straight out of AfkBus's note: a visit that
	-- outlives the teleport leaves the bay held and the player's keys sunk.
	local okBus, AfkBus = pcall(function()
		return require(script.Parent:WaitForChild("AfkBus", 5))
	end)
	if okBus and AfkBus then
		for _, plr in ipairs({ a, b }) do
			pcall(AfkBus.wake, plr)
		end
	end

	local index = allocate()
		-- NOTHING BETWEEN THESE TWO LINES. See the note at the top of the file.
	if not index then return false, "every arena is busy" end
	local match = {
		arena = index,
		players = { a, b },
		side = { [a] = 1, [b] = 2 },
		names = { a.DisplayName, b.DisplayName },
		home = {},
		left = { DuelConfig.LitterCount, DuelConfig.LitterCount },
		seed = os.clock() * 1000 % 2147483647,
		phase = "countdown",
		seconds = DuelConfig.CountdownSeconds,
	}
	occupant[index] = match
	matches[a], matches[b] = match, match

	for _, plr in ipairs(match.players) do
		local char = plr.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		match.home[plr] = hrp and hrp.CFrame or nil
	end

	task.spawn(function()
		local ok, err = pcall(runMatch, match)
		if not ok then
			warn("[Duel] match failed: " .. tostring(err))
			finish(match, "errored")
		end
	end)
	return true
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

function DuelService.start()
	assert(RunService:IsServer(), "[DuelService] server-only")
	if started then return end
	started = true

	arenaFolder = DuelArenaBuilder.ensureWorld()

	--[[
		A CHALLENGE. Re-validated here in full; the client's claim that the two
		of them are standing together is not evidence of anything.

		EVERY BRANCH ANSWERS THE CHALLENGER. It used to answer none of them: a
		sent invite, a busy opponent, a duel you are already in, a target out of
		range and a target who is not on their feet all produced exactly the same
		nothing, so the button read as broken and players pressed it again and
		again. The validation is unchanged -- the only thing added is the reason
		going back down the wire. Fixed 2026-09-09.
	]]
	Net.get("DuelChallenge").OnServerEvent:Connect(function(plr, targetId)
		if type(targetId) ~= "number" then return end
		local target = Players:GetPlayerByUserId(targetId)
		-- Silent on purpose, and the only branch that is: challenging yourself
		-- cannot come from the real button, so a toast here would only ever be
		-- feedback for a tampered client. Same for the non-number above.
		if target == plr then return end
		if not target then
			notify(plr, "They have left the beach", "deny")
			return
		end

		local okA, whyA = canDuel(plr)
		if not okA then
			if whyA == "already duelling" then
				notify(plr, "You are already in a clean-off", "deny")
			else
				notify(plr, "Not while you are down", "deny")
			end
			return
		end

		local okB, whyB = canDuel(target)
		if not okB then
			if whyB == "already duelling" then
				notify(plr, target.DisplayName .. " is already in a clean-off", "deny")
			elseif whyB == "not alive" then
				notify(plr, target.DisplayName .. " is not on their feet", "deny")
			else
				notify(plr, "They have left the beach", "deny")
			end
			return
		end

		if invites[target] then   -- one invite at a time
			notify(plr, target.DisplayName .. " already has a challenge waiting", "deny")
			return
		end

		-- RANGE IS CHECKED ON THE SERVER, off the characters' real positions.
		local ha = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
		local hb = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
		if not ha or not hb then
			notify(plr, "Can't reach them right now", "deny")
			return
		end
		if (ha.Position - hb.Position).Magnitude > DuelConfig.ChallengeRange then
			notify(plr, "Too far away -- get closer and try again", "deny")
			return
		end

		invites[target] = { from = plr, expires = os.clock() + DuelConfig.InviteSeconds }
		Net.get("DuelInvite"):FireClient(target, {
			fromName = plr.DisplayName,
			fromUserId = plr.UserId,
			seconds = DuelConfig.InviteSeconds,
		})
		notify(plr, "Challenge sent to " .. target.DisplayName, "info")
	end)

	Net.get("DuelReply").OnServerEvent:Connect(function(plr, accept)
		local inv = invites[plr]
		if not inv then return end
		invites[plr] = nil
		Net.get("DuelInvite"):FireClient(plr, nil)

		local from = inv.from
		if accept ~= true then
			-- THE CHALLENGER IS THE ONE WAITING ON THIS ANSWER, so they are the
			-- one who has to hear it. A decline closed the card on the target's
			-- screen and told the person who asked nothing at all -- the same
			-- silence as the challenge branches above. Fixed 2026-09-09.
			notify(from, plr.DisplayName .. " passed on the clean-off", "deny")
			return
		end

		if not canDuel(plr) or not canDuel(from) then
			-- Something changed between the invite and the accept: one of them
			-- died, left, or got into another match while the card was up.
			notify(plr, "That clean-off can't start now", "deny")
			notify(from, "That clean-off can't start now", "deny")
			return
		end
		local ok, why = beginMatch(from, plr)
		if not ok then
			-- A BARE STRING NEVER REACHED ANYBODY: FeedbackClient drops any
			-- Notify payload that is not a table carrying a `text` string, so
			-- this refusal has been invisible since it was written. Routed
			-- through notify() with the rest, 2026-09-09.
			notify(plr, "No arena free -- try again in a moment", "deny")
			notify(from, "No arena free -- try again in a moment", "deny")
			print("[Duel] refused: " .. tostring(why))
		end
	end)

	-- Invites time out on their own, so a player who alt-tabs does not hold
	-- their challenger hostage.
	task.spawn(function()
		while true do
			task.wait(1)
			for target, inv in pairs(invites) do
				if os.clock() > inv.expires or not target.Parent then
					invites[target] = nil
					if target.Parent then Net.get("DuelInvite"):FireClient(target, nil) end
					-- An expiry IS a refusal from where the challenger is standing,
					-- and it was every bit as silent as one -- they were left
					-- waiting on an invite that had already been thrown away.
					-- Fixed 2026-09-09.
					notify(inv.from, target.DisplayName .. " did not answer", "deny")
				end
			end
		end
	end)

	-- DEATH OR DISCONNECT ENDS THE MATCH for both. A duel with one runner is
	-- not a duel, and leaving the survivor in the arena with no opponent and no
	-- way out is worse than ending it.
	local function watch(plr: Player)
		plr.CharacterAdded:Connect(function()
			local m = matches[plr]
			if m and m.phase ~= "done" then
				finish(m, "a runner died")
			end
		end)
	end
	for _, plr in ipairs(Players:GetPlayers()) do watch(plr) end
	Players.PlayerAdded:Connect(watch)

	Players.PlayerRemoving:Connect(function(plr)
		invites[plr] = nil
		local m = matches[plr]
		if m then finish(m, "a runner left") end
	end)

	print(("[Duel] %d arenas ready at %s"):format(#DuelConfig.Arenas, tostring(DuelConfig.Origin)))
end

return DuelService
