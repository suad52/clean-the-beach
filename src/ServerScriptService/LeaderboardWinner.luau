--[[
	LeaderboardWinner  --  ServerScriptService.LeaderboardWinner

	THE PLAYER AT THE TOP OF EACH BOARD, STANDING IN FRONT OF IT AND DANCING.
	One rig per board, on the podium LeaderboardBuilder stood there, rebuilt only
	when the account at rank 1 actually changes.

	SERVER-SIDE, LIKE THE ROWS ARE, and for the same reason LeaderboardService's
	header gives: a leaderboard is public by definition, so a rig built once on
	the server and replicated is three moving parts fewer than a remote, a client
	script and a per-player payload -- and a player who joins mid-poll gets the
	winner already standing there with no late-joiner handling.

	THE FOUR THINGS THAT ARE ACTUALLY AWKWARD:

	1. THE RIG ARRIVES UNASSEMBLED. CreateHumanoidModelFromDescription hands back
	   a model whose parts are scattered over a hundred studs; it assembles on the
	   first Heartbeat AFTER being parented into Workspace. So the root is placed,
	   the assembly is waited out, and only THEN is it placed again and anchored --
	   anchoring first would freeze it mid-scatter.

	2. ONLY THE ROOT IS ANCHORED. The modern avatar rig has no Motor6Ds in it at
	   all: it is AnimationConstraints between Attachments, solved by physics. Pin
	   the root and the animation still drives every limb; anchor the whole rig and
	   it stands there as a statue.

	3. IT MUST BE INERT. This is a decoration standing on a beach full of systems
	   that walk Workspace looking for things to touch, rake, collect or path
	   around, so every part goes CanCollide / CanTouch / CanQuery false. A
	   leaderboard ornament that can be bumped into the sea, or that a raycast
	   mistakes for ground, is worse than no ornament.

	4. TWO POLLS CAN RACE. A rig takes the better part of a second to fetch and
	   build, the poll runs every sixty, and a rebirth can call publishNow in
	   between -- so each board carries a generation counter and a build that finds
	   itself superseded after a yield destroys what it made and stands down.

	NOTHING HERE IS ALLOWED TO THROW INTO A POLL. Every web call is wrapped, and
	a failure leaves the podium empty for the next cycle to retry.
]]

local Players = game:GetService("Players")

local LeaderboardWinner = {}

-- [userId] = HumanoidDescription. Cached for the life of the server, the same
-- trade LeaderboardService's nameCache makes: the fetch is a throttled web
-- call, the board asks for the same account every minute, and an outfit changed
-- mid-session is not worth a request a minute to notice.
local descCache = {}

--[[
	KEYED BY THE BOARD, NOT BY board.def.key, AND THAT IS NOT A STYLE CHOICE.

	These were keyed by the stat name back when one board existed per stat. Every
	field with a row now carries its own copy of all three (LeaderboardConfig.Sites),
	so four separate boards answer to "money" -- and under a shared key they fight:

		the beach's board claims generation 1 and starts fetching an avatar;
		the dunes' board claims generation 2 for the same key;
		the beach's fetch returns, sees builds["money"] ~= 1, concludes it has been
		superseded and DESTROYS the rig it just built.

	Only the last row in the list would ever keep a winner, and the failure is
	silent -- three empty podiums and no error anywhere. Keyed by the board table
	each copy gets its own generation counter and its own claim.

	Weak keys so a rebuilt board set can be collected rather than pinned here for
	the life of the server.
]]
local current = setmetatable({}, { __mode = "k" })   -- [board] = userId on the podium
local builds = setmetatable({}, { __mode = "k" })    -- [board] = generation counter

--------------------------------------------------------------------------
-- MAKING A RIG HARMLESS
--------------------------------------------------------------------------
local function makeInert(rig: Model)
	-- The default Animate LocalScript rides along inside every rig this way. It
	-- would never run -- a LocalScript outside a player's character is dead -- but
	-- it exists to fight over exactly the joints we are about to drive, so it goes
	-- rather than sitting there as a puzzle for whoever reads this next.
	for _, d in ipairs(rig:GetDescendants()) do
		if d:IsA("LuaSourceContainer") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.Massless = true
		end
	end

	local hum = rig:FindFirstChildOfClass("Humanoid")
	if hum then
		-- No name plate and no health bar: the board two studs behind already says
		-- who this is, in bigger letters, next to their score.
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		-- The state machine is what decides a Humanoid is falling, swimming or dead
		-- and plays over the top of whatever else is running. There is no state to
		-- be in on a podium.
		hum.EvaluateStateMachine = false
	end
end

--------------------------------------------------------------------------
-- BUILDING ONE
--------------------------------------------------------------------------
local function buildRig(board, userId: number, generation: number): Model?
	-- Names the COPY, not just the stat: with a row on every island "money" alone
	-- no longer says which board a warning is about.
	local where = board.def.key .. " @ " .. tostring(board.island or "?")
	local desc = descCache[userId]
	if not desc then
		local ok, fetched = pcall(function()
			return Players:GetHumanoidDescriptionFromUserIdAsync(userId)
		end)
		-- NOT CACHED ON FAILURE, so a throttled minute does not pin an empty podium
		-- in place until the server restarts.
		if not ok or not fetched then
			warn("[Leaderboard] no avatar for " .. tostring(userId) .. " (" .. where .. "): "
				.. tostring(fetched))
			return nil
		end
		desc = fetched
		descCache[userId] = desc
	end

	local ok, rig = pcall(function()
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
	if not ok or not rig then
		warn("[Leaderboard] could not build " .. tostring(userId) .. " (" .. where .. "): "
			.. tostring(rig))
		return nil
	end

	rig.Name = "Winner"
	makeInert(rig)

	local hum = rig:FindFirstChildOfClass("Humanoid")
	local hrp = rig:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp then
		rig:Destroy()
		return nil
	end

	-- Standing on the cap, looking out the way the board looks: at the beach, and
	-- so at whoever has walked over to read it.
	local function stand()
		local foot = board.podium.top
		local at = foot + Vector3.new(0, hum.HipHeight + hrp.Size.Y * 0.5, 0)
		hrp.CFrame = CFrame.lookAt(at, at + board.podium.facing)
	end

	-- CHECKED BEFORE PARENTING, not only after. Both web calls above can take a
	-- second between them, and a rig that gets as far as Workspace under a stale
	-- generation is a second of two winners standing in each other.
	if builds[board] ~= generation then
		rig:Destroy()
		return nil
	end

	-- See note 1. Parent, place, let it assemble, place again, and only then pin.
	rig.Parent = board.model
	stand()
	task.wait(0.25)
	if not rig.Parent then
		return nil
	end
	stand()
	hrp.Anchored = true

	local animator = hum:FindFirstChildOfClass("Animator")
	if animator and board.def.dance then
		local anim = Instance.new("Animation")
		anim.AnimationId = "rbxassetid://" .. tostring(board.def.dance)
		local okAnim, track = pcall(function()
			return animator:LoadAnimation(anim)
		end)
		if okAnim and track then
			track.Looped = true
			-- Action, not Idle: nothing else is running on this rig, but the priority
			-- is what stops the Humanoid's own default idle from surfacing if the
			-- state machine is ever turned back on.
			track.Priority = Enum.AnimationPriority.Action
			pcall(function()
				track:Play()
			end)
		else
			warn("[Leaderboard] dance failed on " .. where .. ": " .. tostring(track))
		end
	end

	return rig
end

--------------------------------------------------------------------------
-- THE ONE THING THIS MODULE DOES
--------------------------------------------------------------------------
--[[
	Put `userId` on this board's podium, or clear it with nil. Returns straight
	away: the fetch and the assembly happen on their own thread so a slow web call
	cannot hold up the poll that asked for it.
]]
function LeaderboardWinner.set(board, userId: number?)
	local where = board.def.key .. " @ " .. tostring(board.island or "?")
	local standing = board.model:FindFirstChild("Winner")

	-- NOTHING TO DO IS THE COMMON CASE. The top of a board changes rarely and the
	-- poll runs every minute, so the cheap check has to come first -- rebuilding
	-- the same avatar sixty times an hour would be a web call and a twenty-part
	-- model each time, for a rig nobody can tell apart from the one already there.
	if current[board] == userId and (userId == nil or standing) then
		return
	end

	-- See note 4: claim this board, so any build already in flight for it knows to
	-- throw away what it has made. Per BOARD, so claiming the dunes' money board
	-- cannot cancel the beach's -- see the note over `current`.
	local generation = (builds[board] or 0) + 1
	builds[board] = generation
	current[board] = userId

	if standing then
		standing:Destroy()
	end
	if not userId then
		return
	end

	task.spawn(function()
		local ok, rig = pcall(buildRig, board, userId, generation)
		if not ok then
			warn("[Leaderboard] winner failed on " .. where .. ": " .. tostring(rig))
			-- Left unclaimed so the next poll tries again rather than believing this
			-- account is already standing there.
			if builds[board] == generation then
				current[board] = nil
			end
			return
		end
		if builds[board] ~= generation then
			-- Superseded while we were fetching. Whoever bumped the counter has
			-- already destroyed the old rig and is building its replacement.
			if rig then
				rig:Destroy()
			end
			return
		end
		if not rig then
			current[board] = nil
		end
	end)
end

return LeaderboardWinner
