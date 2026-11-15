--[[
	AfkService  --  ServerScriptService.AfkService

	Owns THE LONG SHORE: who is on it, which bay they have, what they are paid,
	and getting them home again.

	THE CHARACTER GOES, NOT A COPY. A visit moves the player's own character to
	their bay; AfkClient drives it up and down the lanes. A cloned puppet would
	need its own appearance load and would leave the real character standing in
	the world for other players to walk into.

	THREE THINGS THIS FILE IS CAREFUL ABOUT, all of them bugs that shipped in the
	same feature in Seal A Driveway before they were found:

	 1. ALLOCATE AND CLAIM ARE ADJACENT. Two `enter` calls that both run
	    `allocate()` before either writes `occupant` both get bay 1. There must
	    be nothing -- no yield, no logging, no attribute write -- between the two
	    lines marked below.

	 2. AFTER A YIELD, CHECK IDENTITY AND NOT A FLAG. `enter` yields (the seat
	    unwind, the stream request). Cross either with the visit ending and a new
	    one starting and the stale call will happily stamp its OLD bay over the
	    live visit, or release the bay the NEW visit is standing in. Asking "is
	    there a visit?" cannot tell two visits apart -- the second is usually
	    allocated the same bay, since allocate() returns the lowest free index.
	    So each visit is a TABLE and the test is `visits[plr] ~= visit`.

	 3. RELEASE IS BY PLAYER, NOT BY INDEX. `releaseFor` sweeps `occupant` for
	    the player rather than trusting a remembered index, which also heals a
	    ghost bay on the next leave or disconnect. Eight ghosts and allocate()
	    falls through and starts handing out beaches somebody is standing on.

	PAY IS WALL-CLOCK. See the long note in AfkConfig: the walk is cosmetic and
	the clock is the wage, so a player in a background tab earns exactly what one
	watching every stroke earns.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local AfkConfig = require(Modules:WaitForChild("AfkConfig"))
local Net = require(Modules:WaitForChild("Net"))
-- Only for the walking floor, and only on the one path below that cannot reach
-- ProgressionServer. It was a literal 16 -- see ProgressionConfig.BaseWalkSpeed.
local ProgressionConfig = require(Modules:WaitForChild("ProgressionConfig"))

local AfkShoreBuilder = require(script.Parent:WaitForChild("AfkShoreBuilder"))
local AfkBus = require(script.Parent:WaitForChild("AfkBus"))

local AfkService = {}

local shore: Folder? = nil
local occupant: {[number]: Player?} = {}   -- bay index -> who holds it
local visits: {[Player]: any} = {}         -- player -> the live visit table
local started = false

--[[
	COINS THIS PLAYER HAS BEEN PAID BY THE SHORE THIS SESSION, and the one-shot
	flag for having told them the tap is closed. See AfkConfig.capFor.

	KEYED BY PLAYER AND NOT HELD ON THE VISIT, which is the entire reason the
	cap works. A tally on `visit` would reset every time somebody stepped off
	the shore and back on -- and the entry pad is a few seconds' walk from the
	leave post, so that is not a cap, it is a pause. Cleared only in
	PlayerRemoving, alongside every other per-player table in this file.
]]
local sessionPaid: {[Player]: number} = {}
local cappedTold: {[Player]: boolean} = {}

--[[
	WHEN THE ENTRY PAD MAY FIRE AGAIN FOR A PLAYER.

	Belt to the ReturnSpot's braces. The hut's geometry stands a returning
	player in FRONT of the pad rather than on it, which is what stops the
	obvious loop; this covers every other way a character can end up on the
	trigger without having chosen to -- a respawn, an AfkBus wake, a duel that
	dumps them there -- any of which would otherwise be a pad you cannot walk
	out of.
]]
local padArmedAt: {[Player]: number} = {}

--------------------------------------------------------------------------
-- BAYS
--------------------------------------------------------------------------

local function bayModel(index: number): Model?
	local root = shore or workspace:FindFirstChild(AfkConfig.FolderName)
	local m = root and root:FindFirstChild(("Bay_%d"):format(index))
	return (m and m:IsA("Model")) and m or nil
end

local function standCFrame(index: number): CFrame
	local m = bayModel(index)
	local stand = m and m:FindFirstChild("StandPoint")
	if stand and stand:IsA("BasePart") then
		return stand.CFrame + Vector3.new(0, 2, 0)
	end
	-- The bay exists in the config even if its geometry has been deleted, and
	-- dropping somebody at 0,0,0 because a part is missing is worse than
	-- dropping them on bare coordinates.
	return CFrame.new(AfkConfig.plotOrigin(index) + Vector3.new(0, 5, 0))
end

-- Lowest free index; nil when every bay is held. Callers must claim the
-- returned index IMMEDIATELY -- see note 1 at the top of the file.
local function allocate(): number?
	for i = 1, AfkConfig.PlotCount do
		if occupant[i] == nil then
			return i
		end
	end
	return nil
end

-- By player, never by index. Returns how many were freed, which is only ever
-- interesting when it is more than one -- that means a ghost was healed.
local function releaseFor(plr: Player): number
	local freed = 0
	for i = 1, AfkConfig.PlotCount do
		if occupant[i] == plr then
			occupant[i] = nil
			freed += 1
		end
	end
	return freed
end

--------------------------------------------------------------------------
-- THE RAKE MARKS
--------------------------------------------------------------------------

--[[
	WHAT THE PUPPET LEAVES BEHIND IT.

	The bay's five RakeLane strips are authored collapsed and invisible (see
	AfkShoreBuilder) and this grows one behind the character as it walks that
	lane, so the sand fills in pale from the end the lap started at. When the
	puppet comes round to lane one again the bay clears and it starts over.

	WHAT THIS REPLACES: five full-length pale strips painted on at build time
	and never touched. The bay was permanently frozen halfway through being
	raked, and walking a lane changed nothing -- some lines of sand and some
	lines of no sand, forever.

	IT RUNS ON THE SERVER, off the character's replicated position, and the
	reason is not authority: these are decoration and nothing pays out on them.
	It is that the bays are 96 studs apart and an idler can see three of their
	neighbours. Marks drawn on each client would leave everyone else's beach
	permanently blank with a man walking up and down it -- which is the bug
	being fixed here, wearing a different hat.

	IT IS NOT THE WAGE AND MUST NOT BECOME IT. Pay is still wall-clock (see the
	long note in AfkConfig): a player in a background tab whose client has
	stopped stepping the walk earns exactly the same, and simply leaves the
	sand where the puppet stopped. This is the picture of the work; the clock
	is the meter.
]]
local RAKE_TICK = 1 / 12
-- How near a lane's centre line counts as walking it. Wider than the strip so
-- the wander cannot drop the puppet off its own lane; narrower than half the
-- 8-stud lane spacing so it can never claim two at once.
local LANE_GRAB = 3.6

local laneCache: { [number]: { [number]: BasePart } } = {}

local function laneStrips(index: number): { [number]: BasePart }
	local hit = laneCache[index]
	if hit then
		return hit
	end
	local m = bayModel(index)
	local out = {}
	local n = 0
	if m then
		for _, d in ipairs(m:GetChildren()) do
			-- BY ATTRIBUTE, not by child order: GetChildren is unordered, and
			-- lane 2 growing from lane 5's end is a silent and very confusing
			-- bug to look at.
			if d:IsA("BasePart") and d.Name == "RakeLane" then
				local k = d:GetAttribute("Lane")
				if type(k) == "number" then
					out[k] = d
					n += 1
				end
			end
		end
	end
	-- Only cached once the bay is fully streamed in, so a half-built lookup
	-- cannot be remembered for the life of the server.
	if n >= AfkConfig.LaneCount then
		laneCache[index] = out
	end
	return out
end

local function laneZ(i: number): number
	local usable = AfkConfig.PlotDepth - AfkConfig.LaneInset * 2
	local lanes = AfkConfig.LaneCount
	local t = (lanes == 1) and 0.5 or ((i - 1) / (lanes - 1))
	return -usable * 0.5 + usable * t
end

-- The x the lane is walked FROM and TO. Odd lanes run +X and even lanes -X,
-- which is AfkClient.lapFor's rule -- the puppet turns and comes home down the
-- next lane rather than teleporting back to the start of one.
local function laneEnds(i: number): (number, number)
	local halfX = AfkConfig.PlotWidth * 0.5 - AfkConfig.LaneInset
	if i % 2 == 1 then
		return -halfX, halfX
	end
	return halfX, -halfX
end

local function drawLane(strip: BasePart, o: Vector3, i: number, p: number)
	local a, b = laneEnds(i)
	local covered = (b - a) * p
	strip.Size = Vector3.new(math.max(0.05, math.abs(covered)), 0.06, 3.2)
	strip.CFrame = CFrame.new(o + Vector3.new(a + covered * 0.5, 0.03, laneZ(i)))
	strip.Transparency = (p > 0.001) and 0 or 1
end

local function clearRake(index: number?, visit)
	if visit then
		visit.rake = {}
	end
	if not index then
		return
	end
	local o = AfkConfig.plotOrigin(index)
	for i, strip in pairs(laneStrips(index)) do
		drawLane(strip, o, i, 0)
	end
end

local function stepRake(plr: Player, visit)
	local char = plr.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end
	local index = visit.bay
	local o = AfkConfig.plotOrigin(index)
	local rel = hrp.Position - o

	-- Which lane is it on, if any? Only within LANE_GRAB, so the walk back
	-- across the bay to lane one does not paint every lane it crosses.
	local nearest, bestD = nil, LANE_GRAB
	for i = 1, AfkConfig.LaneCount do
		local d = math.abs(rel.Z - laneZ(i))
		if d < bestD then
			nearest, bestD = i, d
		end
	end
	if not nearest then
		return
	end

	local a, b = laneEnds(nearest)
	local p = math.clamp((rel.X - a) / (b - a), 0, 1)
	visit.rake = visit.rake or {}

	--[[
		THE LAP RESET, AND IT NEEDS NO TIMER.

		Standing at the START of lane one having already FINISHED lane one can
		only be the puppet having gone out to the water and walked home to begin
		again. Turning the sand over on that rather than on a clock means it
		happens exactly when the walk comes round, however long the rest beat or
		a throttled client made the lap take.
	]]
	if nearest == 1 and (visit.rake[1] or 0) > 0.95 and p < 0.5 then
		clearRake(index, visit)
	end

	local strip = laneStrips(index)[nearest]
	if not strip then
		return
	end
	--[[
		PROGRESS ONLY EVER GOES UP within a lap. The walk carries a deliberate
		wander (AfkConfig.Wander) and eases through its corners, so a puppet at
		a lane end drifts backwards a little; without this the strip would
		visibly breathe in and out at every turn.
	]]
	if p <= (visit.rake[nearest] or 0) then
		return
	end
	visit.rake[nearest] = p
	drawLane(strip, o, nearest, p)
end

--------------------------------------------------------------------------
-- WHERE HOME IS
--------------------------------------------------------------------------

-- Where a visit sends the player back to. Recorded on the way IN, because by
-- the time they leave their character is standing on a beach eight thousand
-- studs from anywhere.
local function homeOf(visit): CFrame
	if visit and typeof(visit.home) == "CFrame" then
		return visit.home
	end
	local spawn = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	if spawn then
		return spawn.CFrame + Vector3.new(0, 4, 0)
	end
	return CFrame.new(0, 8, -139)
end

--------------------------------------------------------------------------
-- THE VISIT
--------------------------------------------------------------------------

local function pushState(plr: Player)
	local visit = visits[plr]
	-- `cap` and `paid` are additive fields: AfkClient ignores what it does not
	-- read, so an old client keeps working and a card that wants to draw the
	-- ceiling has the numbers without another round trip.
	local cap = AfkConfig.capFor(plr)
	local paid = sessionPaid[plr] or 0
	Net.get("AfkSync"):FireClient(plr, visit and {
		bay = visit.bay,
		rate = AfkConfig.rateFor(plr),
		earned = plr:GetAttribute(AfkConfig.EarnedAttr) or 0,
		walkSpeed = AfkConfig.WalkSpeed,
		-- math.huge does not survive the wire as a number the client can format,
		-- so "no cap" is sent as nil rather than as infinity.
		cap = (cap ~= math.huge) and math.floor(cap) or nil,
		paid = math.floor(paid),
		capped = (cap - paid) < 1,
	} or nil)
end

function AfkService.isIdle(plr: Player): boolean
	return visits[plr] ~= nil
end

--[[
	`home` overrides where leaving sends them, and it exists for the entry pad.

	By default a visit remembers the spot the player was standing on when it
	started, which is right for a walk-up prompt and wrong for a pad: it would
	record the pad itself and turn "GO BACK" into a round trip. The pad passes
	the hut's ReturnSpot instead. Every other caller passes one argument and
	gets exactly the old behaviour.
]]
function AfkService.enter(plr: Player, home: CFrame?): boolean
	if not plr or not plr.Parent then
		return false
	end
	if visits[plr] then
		return true       -- already on the shore; the door is idempotent
	end

	local char = plr.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hrp or not hum or hum.Health <= 0 then
		return false
	end

	-- REFUSED while another system owns the character -- and one now does. A
	-- duellist mid-race can still reach the shelter prompt if their opponent
	-- walks them past it, and honouring it would have two systems moving one
	-- character between them: the shore would take them out of the arena and
	-- the match would go on scoring an empty pitch. DuelArena is the duel's own
	-- "this player is spoken for" attribute.
	--
	-- `Rebirthing` is ProgressionServer's ascension (its ASCEND_ATTR). It reads
	-- oddly here -- a rebirth cannot START on the shore, ProgressionServer
	-- refuses that outright -- but it can start ON THE ENTRY PAD, and being
	-- anchored and lifted off a pad is a contact change the Touched handler
	-- below would answer by opening a visit under a player already in the air.
	-- They would land on the spawn pad with that visit live, which is the exact
	-- state both guards exist to prevent.
	if plr:GetAttribute("DuelArena") ~= nil
		or plr:GetAttribute("VaultRun") ~= nil
		or plr:GetAttribute("OnFerry") ~= nil
		or plr:GetAttribute("Rebirthing") ~= nil then
		return false
	end

	local index = allocate()
		-- ⚠️ NOTHING BETWEEN THESE TWO LINES. See note 1 at the top.
	if not index then
		-- Every bay held: double up on the lowest rather than turn them away.
		index = 1
	end
	local visit = { bay = index, since = os.clock(), owed = 0,
		home = (typeof(home) == "CFrame") and home or hrp.CFrame }
	occupant[index] = plr
	visits[plr] = visit

	plr:SetAttribute(AfkConfig.Attr, index)
	plr:SetAttribute(AfkConfig.EarnedAttr, 0)

	-- Unseat before moving: a seated character ignores CFrame writes, and the
	-- unwind is one of the two yields this function has to survive.
	if hum.SeatPart then
		hum.Sit = false
		task.wait(0.2)
		if visits[plr] ~= visit then
			return false   -- a different visit owns this player now; leave it alone
		end
	end

	char:PivotTo(standCFrame(index))
	hum.WalkSpeed = AfkConfig.WalkSpeed

	-- A fresh bay for a fresh visit. Without this the next occupant inherits
	-- however far the last one got, which reads as somebody else's half-raked
	-- beach handed over mid-job.
	clearRake(index, visit)

	pushState(plr)
	return true
end

--[[
	END A VISIT.

	`move` false is the AfkBus path: the caller is doing the teleport itself and
	only needs the visit torn down. Everything else sends them home.
]]
function AfkService.leave(plr: Player, move: boolean?): CFrame?
	local visit = visits[plr]
	if not visit then
		return nil
	end
	visits[plr] = nil
	releaseFor(plr)
	-- Left as it was found. A bay standing empty with a half-raked beach on it
	-- is a bay that looks occupied from three bays away.
	clearRake(visit.bay, visit)

	plr:SetAttribute(AfkConfig.Attr, nil)
	-- Whatever put them back, do not let the pad grab them on the way down.
	padArmedAt[plr] = os.clock() + 1.5

	local home = homeOf(visit)
	local char = plr.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")

	if move ~= false and char then
		char:PivotTo(home)
	end

	--[[
		SPEED IS RESTORED FROM THE SOURCE OF TRUTH, NOT FROM A REMEMBERED NUMBER.

		ProgressionServer owns WalkSpeed -- it writes BeachLegs' effect on join,
		on every spawn and after every purchase. Putting back whatever the
		humanoid happened to be reading when the visit started would rob a player
		who bought the upgrade WHILE idling, which is a thing the shop panel lets
		them do. applyAll re-derives the lot.
	]]
	if hum and hum.Health > 0 then
		local ok, Progression = pcall(function()
			return require(script.Parent:WaitForChild("ProgressionServer", 5))
		end)
		if ok and Progression and Progression.applyAll then
			pcall(Progression.applyAll, plr)
		else
			hum.WalkSpeed = ProgressionConfig.BaseWalkSpeed
		end
	end

	--[[
		CANCEL THE WALK THE PUPPET LEFT IN FLIGHT.

		`Humanoid:MoveTo` is a STANDING ORDER, not a per-frame command. AfkClient
		steers the puppet with it, and cancelling the coroutine that issued one
		does nothing to the order itself: the humanoid goes on walking at that
		target until it arrives or eight seconds pass. The target is a lane end
		eight thousand studs away, so a player who left mid-lane landed on the
		real beach and immediately set off walking across it on their own.

		IT READ AS INTERMITTENT for a precise reason, and the reason is worth
		knowing before anyone "fixes" it again: the default control module calls
		Humanoid:Move every frame the player is steering, and Move CANCELS a
		MoveTo. Anybody who touched a key on the way back cleared it themselves
		and never saw it. Anybody who had let go of the keyboard to go idle --
		which is every user of this feature -- did.

		AfkClient cancels it as well, and both are wanted rather than one being
		belt to the other's braces. THIS one is what covers a client that is
		dead, throttled in a background tab, or simply a frame late; MoveTo
		writes WalkToPoint and WalkToPoint replicates, so the server's cancel
		still lands on a client that is not running its own.

		AT THE CHARACTER'S OWN FEET, read AFTER the pivot above -- an order to
		walk to where you already are is the documented way to clear one, and
		reading the position before the pivot would re-issue the walk it is
		meant to cancel, aimed back at the bay.
	]]
	local hrpNow = char and char:FindFirstChild("HumanoidRootPart")
	if hum and hrpNow and hum.Health > 0 then
		hum:MoveTo(hrpNow.Position)
	end

	pushState(plr)
	return home
end

--------------------------------------------------------------------------
-- THE WAGE
--------------------------------------------------------------------------

--[[
	Paid in whole coins, with the fraction carried.

	`owed` is what makes a slow rate work: at 2/sec times a 1.25 multiplier the
	tick owes 2.5, banks 2 and carries 0.5, so the next tick banks 3. Rounding
	each tick on its own would quietly pay 2 forever and lose a fifth of the
	wage to the floor.
]]
--[[
	THE SESSION CEILING lives here rather than in the wage clock, so that every
	route into a payment goes through it -- there is one today and adding a
	second should not mean remembering this.

	WITHIN A COIN OF THE CAP COUNTS AS AT IT. A remainder smaller than one coin
	can never be banked (`whole` is floored), so treating it as "still has room"
	would leave `owed` climbing for the rest of the session against a payment
	that can never happen.
]]
local function payTick(plr: Player, visit, dt: number, addCoins)
	local cap = AfkConfig.capFor(plr)
	local paid = sessionPaid[plr] or 0
	if (cap - paid) < 1 then
		-- Told ONCE per session, at the moment it bites. A shore that quietly
		-- stops paying reads as a bug, and the player is by definition not
		-- watching it closely.
		if not cappedTold[plr] then
			cappedTold[plr] = true
			pcall(function()
				Net.get("Notify"):FireClient(plr, {
					text = "The Long Shore has paid all it will this session.",
					kind = "warn",
				})
			end)
			pushState(plr)
		end
		return
	end

	visit.owed += AfkConfig.rateFor(plr) * dt
	local whole = math.floor(visit.owed)
	if whole < 1 then
		return
	end
	-- The last tick pays the remainder and not a coin more.
	whole = math.min(whole, math.floor(cap - paid))
	visit.owed -= whole

	local ok = pcall(addCoins, plr, whole)
	if not ok then
		return
	end
	sessionPaid[plr] = paid + whole
	plr:SetAttribute(AfkConfig.EarnedAttr,
		(plr:GetAttribute(AfkConfig.EarnedAttr) or 0) + whole)
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

function AfkService.start()
	assert(RunService:IsServer(), "[AfkService] server-only")
	if started then
		return
	end
	started = true

	shore = AfkShoreBuilder.ensureWorld()
	local entry = AfkShoreBuilder.ensureEntry()

	-- The money API. Resolved once here rather than per tick, and through
	-- CTBBridge rather than the Coins attribute directly: that is the one grant
	-- path, and going around it is what stopped lifetime earnings counting a
	-- tide bonus (see the note in CTBBridge).
	local CTBBridge = require(script.Parent:WaitForChild("CTBBridge"))
	local addCoins = CTBBridge.addCoins

	-- THE WAY OUT. One prompt per bay, put on the post the builder stood there.
	local root = shore
	for i = 1, AfkConfig.PlotCount do
		local m = bayModel(i)
		local post = m and m:FindFirstChild("LeavePost")
		if post and post:IsA("BasePart") and not post:FindFirstChildOfClass("ProximityPrompt") then
			local prompt = Instance.new("ProximityPrompt")
			prompt.ActionText = "Back to the beach"
			prompt.ObjectText = ("Bay %d"):format(i)
			prompt.HoldDuration = 0.35
			prompt.MaxActivationDistance = 12
			prompt.RequiresLineOfSight = false
			prompt.Parent = post
			prompt.Triggered:Connect(function(plr)
				-- Only the player standing in THIS bay, so an idler in bay 3 who
				-- wanders cannot pull bay 4's occupant home.
				if AfkConfig.plotOf(plr) == i then
					AfkService.leave(plr)
				end
			end)
		end
	end

	-- THE DOOR ITSELF: the prompt on the beach shelter. Connected on the SERVER,
	-- so the engine validates that the player is actually standing at it -- a
	-- remote could only ever be a claim that they were.
	local anchor = entry and entry:FindFirstChild("PromptAnchor")
	if anchor and anchor:IsA("BasePart") and not anchor:FindFirstChildOfClass("ProximityPrompt") then
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "AfkPrompt"
		prompt.ActionText = "Take a break"
		prompt.ObjectText = "The Long Shore"
		prompt.HoldDuration = 0.5
		prompt.MaxActivationDistance = 14
		prompt.RequiresLineOfSight = false
		prompt.Parent = anchor
		prompt.Triggered:Connect(function(plr)
			AfkService.enter(plr)
		end)
	end

	--[[
		THE PAD: step on it and you go, which is what the board over it says.

		TOUCHED, not a region poll. The pad is one part the engine already
		reports contacts with, and a per-frame overlap query for a door used a
		few times an hour would be the more expensive of the two by a wide
		margin.

		THE HANDLER IS DELIBERATELY DULL. Touched fires over and over for as
		long as a character is standing there, so every early return below is
		load-bearing, and the padArmedAt stamp is what stops a player parked on
		the pad from being taken again the instant they walk back out.

		Ancestor lookup rather than hit.Parent, because a hat's Handle sits
		under an Accessory and would otherwise never resolve to its owner.
	]]
	local pad = entry and entry:FindFirstChild("EntryPad")
	local retSpot = entry and entry:FindFirstChild("ReturnSpot")
	if pad and pad:IsA("BasePart") then
		local padHome = (retSpot and retSpot:IsA("BasePart")) and retSpot.CFrame or nil
		if not padHome then
			warn("[AfkShore] no ReturnSpot on the entry -- the pad would send a "
				.. "player home to the pad, which is a loop")
		end
		pad.Touched:Connect(function(hit: BasePart)
			local model = hit and hit:FindFirstAncestorWhichIsA("Model")
			local plr = model and Players:GetPlayerFromCharacter(model)
			if not plr then
				return                        -- scenery, a dropped tool, a pet
			end
			if visits[plr] then
				return                        -- already out there; the door is idempotent
			end
			local now = os.clock()
			if (padArmedAt[plr] or 0) > now then
				return                        -- came back through it a moment ago
			end
			padArmedAt[plr] = now + 1
			-- enter() does the refusing: dead, seated, mid-duel, on the ferry.
			AfkService.enter(plr, padHome)
		end)
	end

	-- The same door as a remote, for anything that is not a walk-up: a HUD key,
	-- a settings toggle, a test. Same two words either way.
	Net.get("AfkControl").OnServerEvent:Connect(function(plr, action)
		if action == "enter" then
			AfkService.enter(plr)
		elseif action == "leave" then
			AfkService.leave(plr)
		end
	end)

	--[[
		DEATH ENDS A VISIT.

		A fresh character spawns at the SpawnLocation with none of the bay's
		state on it, so a visit that survived would leave the bay held, the
		attribute set and the client still sinking the player's movement keys on
		a beach they are no longer standing on. `move = false` because the engine
		has already placed them.
	]]
	local function watch(plr: Player)
		plr.CharacterAdded:Connect(function()
			if visits[plr] then
				AfkService.leave(plr, false)
			end
		end)
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		watch(plr)
	end
	Players.PlayerAdded:Connect(watch)

	Players.PlayerRemoving:Connect(function(plr)
		visits[plr] = nil
		padArmedAt[plr] = nil
		-- THE SESSION ENDS HERE, and so does the cap. Leaving the GAME resets
		-- the tally; leaving the SHORE does not.
		sessionPaid[plr] = nil
		cappedTold[plr] = nil
		releaseFor(plr)
	end)

	-- THE WAGE CLOCK. One loop for everybody rather than a thread per visit.
	task.spawn(function()
		while true do
			local dt = task.wait(AfkConfig.PayInterval)
			for plr, visit in pairs(visits) do
				if plr.Parent then
					payTick(plr, visit, dt, addCoins)
				else
					visits[plr] = nil
					releaseFor(plr)
				end
			end
		end
	end)

	--[[
		THE RAKE CLOCK, and it is a SEPARATE loop from the wage on purpose.

		The wage banks once a second because addCoins goes through SellServer
		and repaints every open panel watching the balance. A strip that only
		moved on that beat would jump forward in ten-stud steps and read as a
		progress bar rather than as a rake, so this runs twelve times a second
		-- which it can afford to, because it is one position read and at most
		one Size/CFrame write per idler.
	]]
	task.spawn(function()
		while true do
			task.wait(RAKE_TICK)
			for plr, visit in pairs(visits) do
				if plr.Parent then
					stepRake(plr, visit)
				end
			end
		end
	end)

	-- Register with the bus LAST, so nothing can ask for a wake before the
	-- service can answer one.
	AfkBus.provide({
		isIdle = AfkService.isIdle,
		wake = function(plr: Player): CFrame?
			return AfkService.leave(plr, false)
		end,
	})

	-- BOTH FIGURES ARE THE TIDE-0 ONES. What a player is actually paid, and
	-- actually capped at, is these times AfkConfig.runScale -- which by the
	-- fortieth tide is about x143,000. Said here because a boot line quoting a
	-- flat "2 coins/sec" is the same misreading the shore's own sign had.
	-- "%.10g" AND NOT "%d" FOR THE RATE: BaseRate is 1.2 and %d truncates a
	-- fraction instead of erroring, so this line used to boot-log "1 coins/sec"
	-- for a shore paying 1.2. Same trap as AfkConfig.signText -- see its note.
	print(("[AfkShore] open: %d bays at %s, %.10g coins/sec and a %s session cap at "
		.. "tide 0, both scaled by the run")
		:format(AfkConfig.PlotCount, tostring(AfkConfig.Origin), AfkConfig.BaseRate,
			(type(AfkConfig.SessionCap) == "number" and AfkConfig.SessionCap > 0)
				and tostring(AfkConfig.SessionCap) or "no"))
end

return AfkService
