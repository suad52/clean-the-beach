--[[
	FunnelServer  --  ServerScriptService.FunnelServer

	The half that watches players and fires the events. What the events MEAN --
	the funnel names, the step numbers, the map ladder -- is FunnelConfig's, and
	this file never invents one of its own.

	IT IS THE ONLY PLACE IN THE GAME THAT TOUCHES AnalyticsService. Every call
	is wrapped, so a throttle, an outage or an unpublished place can cost a
	statistic and can never cost a join.

	WHY THE ONBOARDING FUNNEL IS RE-DERIVED HERE RATHER THAN REPORTED BY THE CARD
	-----------------------------------------------------------------------------
	The obvious build is a remote: TutorialHud already runs this exact state
	machine on the client and knows the moment each card is satisfied, so it
	could simply say so. Three reasons it does not.

	1. ANALYTICS EVENTS ONLY SEND FROM THE SERVER. Roblox says so plainly. A
	   client report would therefore be a remote whose only purpose is to ask
	   the server to log something on the client's word -- and a client that can
	   name its own funnel step can flatten the chart for everyone.

	2. THE FEATURE HAS NO REMOTE AND IS BETTER FOR IT. TutorialServer's header
	   makes the argument at length: every step of this onboarding is something
	   the SERVER CAN SEE FOR ITSELF, which is why the done-stamp needed no
	   remote either. Every attribute the five cards test -- CurrentWeight,
	   MaxWeight, RollerBlocked, CrustedWeight, TotalEarned, Lv_RollerWidth --
	   is written by a server module and merely replicated to the card. The
	   client is not the authority on any of them; it is a second reader.

	3. IT KEEPS WORKING WHEN THE CARD DOES NOT. A player who dismisses the card
	   with the X is still playing the loop, and TutorialServer will still
	   retire their tutorial when they buy something. A funnel wired to the card
	   would record them as having abandoned onboarding at step two.

	THE ONE THING THIS TAKES ON TRUST, and it is worth writing down: the server
	decides a player is new and the CARD decides whether to draw itself, at two
	different moments -- this one waits on the profile, TutorialHud waits out
	fifteen seconds of IntroCinema and re-tests on the far side. Both ask
	TutorialConfig.looksNew, which is the whole reason that test lives in one
	file, so they cannot disagree about WHO. They can still disagree about
	WHETHER: a player who quits during the opening shot is armed here and never
	saw a card. They are a drop-off at step one either way, which is the honest
	place for them, but they are counted as having been shown something they
	were not.

	WHAT THE THREE FUNNELS COST
	---------------------------
	One attribute read per armed player per second, and armed players are new
	accounts only -- typically none. The ladder is a single attribute signal per
	player, and it fires on rebirths.

	POLLED RATHER THAN SIGNALLED, and that is deliberate rather than lazy. The
	WASH step ends when the player walks away from the bay, which is not an
	attribute change and raises no signal at all -- TutorialHud has a per-frame
	tick for exactly this reason. A second of latency on an analytics timestamp
	is not a quantity anybody can measure, and one shared loop over a table that
	is usually empty is cheaper than six connections per new player.

	IN STUDIO NOTHING IS SENT. Roblox: "Events can only be sent from the server
	and in published games." So Trace below defaults on in Studio and prints
	every event that WOULD have gone -- which is how the logic in this file gets
	verified at all, because the dashboard cannot verify it.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local AnalyticsService = game:GetService("AnalyticsService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local ProgressionConfig = require(Modules:WaitForChild("ProgressionConfig"))
local TutorialConfig = require(Modules:WaitForChild("TutorialConfig"))
-- For OwnedAttribute only -- the pet count PetServer publishes. Named rather
-- than typed, so a rename there cannot quietly kill step 7.
local PetConfig = require(Modules:WaitForChild("PetConfig"))
local WeightConfig = require(ReplicatedStorage:WaitForChild("WeightSystem"):WaitForChild("WeightConfig"))
local FunnelConfig = require(ServerScriptService:WaitForChild("FunnelConfig"))

local FunnelServer = {}

-- Print every event instead of (as well as) sending it. On in Studio, where
-- nothing is sent and the print is the only evidence the logic ran.
FunnelServer.Trace = RunService:IsStudio()

-- The master switch, for turning the whole thing off without unpicking
-- ServerMain. Nothing else in the game reads it.
FunnelServer.Enabled = true

local O = FunnelConfig.Onboarding
local SIFTER_ATTR = ProgressionConfig.AttrPrefix .. "RollerWidth"
-- The AUTHORED run, not a ceiling -- the tide ladder is endless (see
-- ProgressionConfig.Rebirth.LadderTides). Only the boot line reads it, to say
-- how far the charted pacing goes.
local LADDER_TIDES = ProgressionConfig.Rebirth.LadderTides

local onboarding: { [Player]: any } = {}
local conns: { [Player]: { RBXScriptConnection } } = {}
local started = false

--------------------------------------------------------------------------
-- SENDING
--------------------------------------------------------------------------
--[[
	EVERY CALL GOES THROUGH HERE AND EVERY CALL IS WRAPPED.

	Analytics is the lowest-priority thing this server does. It is called from
	a join path and from a rebirth, both of which have a player waiting on them,
	and there is no failure mode of a dashboard that is worth one of those.

	THE WARN IS CAPPED. An unpublished place, a revoked permission or a
	throttle fails on EVERY event, not one -- so an uncapped warn turns a
	misconfiguration into an output window nobody can read past, which is how
	the actual error in a session gets lost. Three, then silence.
]]
local FAIL_WARN_CAP = 3
local failures = 0

local function send(label: string, fn): boolean
	if not FunnelServer.Enabled then
		return false
	end
	local ok, err = pcall(fn)
	if not ok then
		failures += 1
		if failures <= FAIL_WARN_CAP then
			warn(string.format("[Funnel] %s failed: %s", label, tostring(err)))
			if failures == FAIL_WARN_CAP then
				warn("[Funnel] further analytics failures this session will be silent.")
			end
		end
		return false
	end
	return true
end

local function trace(fmt: string, ...)
	if FunnelServer.Trace then
		print("[Funnel] " .. string.format(fmt, ...))
	end
end

--[[
	THE THREE CALL SITES. One per API, so an argument order is written once.

	The orders below are Roblox's published ones, and the progression call is
	the one to re-check if this file is ever ported: it takes `level` and
	`levelName` DIRECTLY, with no statistics table between the status and the
	level. Getting that wrong does not raise -- it files every event under a
	level nobody can read -- which is why it is here once rather than inline.
]]
local function logOnboarding(player: Player, step: number, name: string)
	trace("onboarding  %-18s step %d  %s", player.Name, step, name)
	send("LogOnboardingFunnelStepEvent", function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step, name)
	end)
end

local function logFunnel(player: Player, funnelName: string, sessionId: string, step: number, name: string)
	trace("funnel      %-18s %s step %d  %s", player.Name, funnelName, step, name)
	send("LogFunnelStepEvent", function()
		AnalyticsService:LogFunnelStepEvent(player, funnelName, sessionId, step, name)
	end)
end

local function logProgression(player: Player, status: Enum.AnalyticsProgressionType, level: number, levelName: string)
	trace("progression %-18s %-8s level %d  %s", player.Name, status.Name, level, levelName)
	send("LogProgressionEvent", function()
		AnalyticsService:LogProgressionEvent(player, FunnelConfig.Tide.Path, status, level, levelName)
	end)
end

--------------------------------------------------------------------------
-- WAITING FOR THE PROFILE
--------------------------------------------------------------------------
--[[
	The same wait TutorialServer does, for the same reason and with the same
	bound: every attribute either driver reads -- Rebirths, TotalEarned,
	TutorialDone -- is written by SaveService's restore, which lands after the
	join. Asking early reports a thirty-rebirth veteran as a brand new account
	and opens an onboarding funnel on them.

	Resolved LAZILY AND OPTIONALLY rather than required at the top, which is the
	contract TutorialServer keeps with the same module: a place with no save
	module still reports funnels, it just falls back to a fixed wait.

	BOUNDED, and it falls through rather than giving up. A profile that never
	loads -- Studio with API services off, a store outage -- must not silence
	the funnels; the cost of being wrong here is a mis-filed event, and the cost
	of waiting forever is a whole session of no data at all.
]]
local saveLoaded, SaveService = false, nil
local function saveService()
	if saveLoaded then
		return SaveService
	end
	saveLoaded = true
	local moduleScript = ServerScriptService:FindFirstChild("SaveService")
	if moduleScript and moduleScript:IsA("ModuleScript") then
		local ok, result = pcall(require, moduleScript)
		if ok and type(result) == "table" and type(result.isLoaded) == "function" then
			SaveService = result
		end
	end
	return SaveService
end

local PROFILE_WAIT = 12
local function awaitProfile(player: Player)
	local service = saveService()
	if not service then
		task.wait(3)
		return
	end
	local deadline = os.clock() + PROFILE_WAIT
	while os.clock() < deadline do
		if not player.Parent then
			return
		end
		if service.isLoaded(player) then
			-- One frame past the load, for the reason TutorialServer names: apply
			-- writes Rebirths and TotalEarned inside the same call that flips the
			-- flag, and reading between the two is the bug this wait exists for.
			task.wait(0.2)
			return
		end
		task.wait(0.25)
	end
end

-- The wash bay, resolved the same lazy optional way: a place with no bays still
-- reports a funnel, its WASH step simply ends on "the bag came clean".
local washLoaded, WashServer = false, nil
local function isWashing(player: Player): boolean
	if not washLoaded then
		washLoaded = true
		local moduleScript = ServerScriptService:FindFirstChild("WashServer")
		if moduleScript and moduleScript:IsA("ModuleScript") then
			local ok, result = pcall(require, moduleScript)
			if ok and type(result) == "table" and type(result.isWashing) == "function" then
				WashServer = result
			end
		end
	end
	if not WashServer then
		return false
	end
	local ok, result = pcall(WashServer.isWashing, player)
	return ok and result == true
end

--------------------------------------------------------------------------
-- THE ONBOARDING FLOW
--------------------------------------------------------------------------
local function num(player: Player, name: string): number
	return tonumber(player:GetAttribute(name)) or 0
end

-- RollerBlocked FIRST, because it is the game's own answer to "is this bag
-- full" -- CTBBridge.hasRoom, the same function that stops the sifter. Copied
-- from TutorialHud's step 1 along with its 0.75 slack, and it has to stay
-- copied: a bag holding 11.4 of 12 lbs with only 2 lb lumps left to find is
-- full in every sense that matters, and the arithmetic alone would wait for a
-- find that can never fit.
local function bagFull(player: Player): boolean
	if player:GetAttribute("RollerBlocked") == true then
		return true
	end
	local max = num(player, WeightConfig.MaxWeightAttribute)
	return max > 0 and num(player, WeightConfig.CurrentWeightAttribute) >= max - 0.75
end

--[[
	SIX NODES. NOT A COPY OF TutorialHud's CARD LIST, though most of them line up
	with one -- SOLD_AGAIN has never had a card, and HATCHED's card sits fourth
	over there while its node is last here. Both orders are deliberate and they
	are explained where they are chosen; what matters in THIS table is that the
	step numbers only ever ascend, because Roblox auto-completes skipped earlier
	steps within a funnel session and logging 7 before 6 would silently complete
	6 for a player who never did it.

	`arm` takes this node's baseline and may answer "skip"; `done` answers "has
	it happened SINCE arm". Both contracts are that file's, and the tests below
	are its tests against the server's copy of the same attributes.

	EVERY TEST IS A DELTA FROM THE MOMENT ITS OWN STEP BEGAN, which is the one
	structural note TutorialHud asks the next person to keep: this sequence
	SELLS TWICE, and against a single baseline the first sale would satisfy the
	second sale's step before the player had washed anything -- collapsing two
	funnel steps into one and reporting a wash rate of a hundred per cent.
]]
local FLOW = {
	{
		step = O.FILLED,
		arm = function() end,
		done = function(player)
			return bagFull(player)
		end,
	},
	{
		step = O.SOLD,
		arm = function(player, mem)
			mem.earned = num(player, "TotalEarned")
		end,
		done = function(player, mem)
			return num(player, "TotalEarned") > mem.earned + 0.5
		end,
	},
	{
		step = O.WASHED,
		arm = function(player, mem)
			mem.crust = num(player, WeightConfig.CrustedWeightAttribute)
			-- NOTHING TO WASH IS AN ANSWER, NOT A FAILURE -- and for a funnel that
			-- distinction is the whole of it. TutorialHud stands this step down
			-- when the bag has no crust in it, because the server can only
			-- guarantee a lump to a player it saw as new. Recording that as a
			-- drop-off would put a cliff in the chart at the wash bay that is
			-- made entirely of players who were never sent to one.
			if mem.crust <= 0.001 then
				mem.washSkipped = true
				return "skip"
			end
			return nil
		end,
		done = function(player, mem)
			local crust = num(player, WeightConfig.CrustedWeightAttribute)
			if crust > mem.crust - 0.001 then
				return false
			end
			-- All of it, or as much as they meant to do -- the bay auto-advances
			-- to the next lump, so "the first rock is clean" is the middle of the
			-- job. Leaving the bay ends it, which is what isWashing answers.
			return crust <= 0.001 or not isWashing(player)
		end,
	},
	{
		step = O.SOLD_AGAIN,
		arm = function(player, mem)
			-- Nothing was washed, so there is nothing new in the bag and this is
			-- the same sale already counted at step 3.
			if mem.washSkipped then
				return "skip"
			end
			mem.earned = num(player, "TotalEarned")
			return nil
		end,
		done = function(player, mem)
			return num(player, "TotalEarned") > mem.earned + 0.5
		end,
	},
	{
		step = O.UPGRADED,
		-- `or 1` on BOTH sides. ProgressionServer writes no attribute at all
		-- until the first purchase on a track, and treating a missing baseline as
		-- zero would complete this step off the level 1 every track starts at.
		arm = function(player, mem)
			mem.sifter = tonumber(player:GetAttribute(SIFTER_ATTR)) or 1
		end,
		--[[
			THE CARD ASKS FOR ONE TRACK AND THIS ACCEPTS ANY, exactly as
			TutorialServer's done-stamp does, and for its reason: the card is
			telling a beginner WHICH ROW, the funnel is asking DID THEY FIND THE
			SHOP. Somebody who bought a bigger bucket has plainly found it.

			Without the second clause this step is also unreachable for them:
			TutorialServer retires the tutorial on any track moving, so a player
			who buys the "wrong" row would sit at step five for the rest of the
			account's life and be counted as having abandoned onboarding one
			purchase from the end of it.

			Safe to read here and nowhere earlier: `done` is only ever called for
			the step the flow is standing on, so the loose test cannot reach back
			and complete the four steps below it.
		]]
		done = function(player, mem)
			if player:GetAttribute(TutorialConfig.DoneAttribute) == true then
				return true
			end
			return (tonumber(player:GetAttribute(SIFTER_ATTR)) or 1) > mem.sifter
		end,
	},
	{
		step = O.HATCHED,
		--[[
			ABSOLUTE, AND THE ONE NODE IN THIS TABLE THAT IS.

			The header says every test is a delta from the moment its own step began,
			and gives the reason: this sequence sells twice, and a shared baseline
			would let the first sale complete the second sale's step. Neither half of
			that reaches here. There is no second hatch -- and TutorialHud asks for
			the pet on the card BEFORE the shop, so by the time this node arms a
			player who followed the card already owns one. A delta would report every
			single one of them as having refused it, which is the exact opposite of
			the truth.

			So 6 -> 7 measures the question worth asking: of the players who finished
			onboarding, how many came out of it owning a pet. A player who bought the
			sifter and skipped the egg completes 6 and sits here, which is the
			drop-off this step was added to find.
		]]
		arm = function() end,
		done = function(player)
			return num(player, PetConfig.OwnedAttribute) > 0
		end,
	},
}

local function stepName(step: number): string
	for _, row in ipairs(FunnelConfig.OnboardingSteps) do
		if row.step == step then
			return row.name
		end
	end
	return "Step " .. tostring(step)
end

--[[
	ADVANCE AS FAR AS THE PLAYER HAS ACTUALLY GOT, not one step per tick.

	A skipped step arms the next one immediately, and a player can genuinely
	satisfy two in one second -- selling a bag is one attribute write that ends
	step 3 and starts step 4. Advancing once per tick would spread a wash-free
	run over four seconds of wall clock for no reason.

	The loop cannot run away: every node past the first takes its baseline in
	`arm` and compares against it, so a freshly armed step is false by
	construction until something new happens.
]]
local function advance(player: Player, st)
	while st.index <= #FLOW do
		local node = FLOW[st.index]
		if not st.armed then
			st.armed = true
			if node.arm(player, st.mem) == "skip" then
				logOnboarding(player, node.step, stepName(node.step))
				st.index += 1
				st.armed = false
				continue
			end
		end
		if not node.done(player, st.mem) then
			return
		end
		logOnboarding(player, node.step, stepName(node.step))
		st.index += 1
		st.armed = false
	end
	-- Through all seven. Nothing more to watch on this account, ever: the flag
	-- TutorialServer stamps is persisted, so the next join does not re-arm.
	--
	-- WHICH IS ALSO STEP 7'S ONE LIMIT, STATED PLAINLY: a player who finishes the
	-- tutorial and leaves without a pet is still standing on node 7 when they go,
	-- and `looksNew` is false by their next join, so they are never re-armed. The
	-- step therefore measures pets hatched DURING onboarding, not pets ever
	-- hatched. That is the honest reading of the chart and it is the one worth
	-- having -- the population-wide number is a profile-store question, not a
	-- funnel one.
	onboarding[player] = nil
	trace("onboarding  %-18s COMPLETE", player.Name)
end

local function armOnboarding(player: Player)
	if onboarding[player] then
		return
	end
	onboarding[player] = { index = 1, armed = false, mem = {} }
	-- STEP ONE IS THE ARRIVAL ITSELF and is logged here rather than earned.
	-- It is the denominator -- see FunnelConfig's header.
	logOnboarding(player, O.ARRIVED, stepName(O.ARRIVED))
	advance(player, onboarding[player])
end

--------------------------------------------------------------------------
-- THE MAP LADDER AND THE TIDE
--------------------------------------------------------------------------
local function logRung(player: Player, rung)
	logFunnel(player, FunnelConfig.Map.Name, FunnelConfig.Map.sessionFor(player), rung.step, rung.name)
end

--[[
	OPENED ON THE PLAYER'S CURRENT RUNG AND NOTHING BELOW IT.

	Roblox ignores a repeated funnel step and auto-completes skipped earlier
	ones, so one event for a rebirth-22 player fills in all six rungs beneath
	it. That single documented behaviour is what lets this funnel be correct for
	the accounts that already exist on the day it ships -- no migration, no
	stored high-water mark, no eight events per login -- and it is the reason
	there is no new field in SaveService anywhere in this feature.

	THE TIDE LADDER IS FORWARD-ONLY AND THAT IS THE DELIBERATE ASYMMETRY. A
	Start is logged as the successor of a Complete and never on a join, so every
	tide carries exactly one Start and one Complete per account no matter how
	often the player logs in. The price is that tide 1 has completions and no
	starts -- nobody "starts" the tide they arrive on. Its denominator is the
	onboarding funnel's step one, which is a better count of new accounts than a
	progression event would have been.
]]
local function startLadder(player: Player)
	local rebirths = num(player, "Rebirths")
	local rung = FunnelConfig.rungFor(rebirths)
	if rung then
		logRung(player, rung)
	end

	local prev = rebirths
	local conn = player:GetAttributeChangedSignal("Rebirths"):Connect(function()
		local now = num(player, "Rebirths")
		if now <= prev then
			-- Nothing in normal play moves this backwards. FeedbackServer's admin
			-- tool can set it to anything; a correction is not a tide anybody rode.
			prev = now
			return
		end

		--[[
			ONE AT A TIME IS A REBIRTH. ANYTHING ELSE IS SOMEBODY SETTING A NUMBER.

			ProgressionServer.onRebirth writes exactly n + 1, so a genuine tide is
			always a delta of one. The admin path in FeedbackServer writes whatever
			it is given, and a jump from 4 to 30 is not twenty-six tides that were
			played -- filing it as such would put twenty-six completions into the
			chart from one click. The map rung below still moves, because the
			player really can walk into Ashfall now.
		]]
		if now - prev == 1 then
			logProgression(player, Enum.AnalyticsProgressionType.Complete, now, FunnelConfig.Tide.levelName(now))
			-- ALWAYS A SUCCESSOR NOW. This used to be held back at the last tide,
			-- because a Start for a tide the game would refuse is a step that can
			-- never complete and a permanent drop-off at the end of the chart. The
			-- ladder has no last tide any more, so every Complete has a real next
			-- one to open.
			logProgression(player, Enum.AnalyticsProgressionType.Start, now + 1, FunnelConfig.Tide.levelName(now + 1))
		end

		local before = FunnelConfig.rungFor(prev)
		local after = FunnelConfig.rungFor(now)
		if after and (not before or after.step > before.step) then
			logRung(player, after)
		end
		prev = now
	end)

	local list = conns[player]
	if not list then
		list = {}
		conns[player] = list
	end
	table.insert(list, conn)
end

--------------------------------------------------------------------------
-- JOIN AND LEAVE
--------------------------------------------------------------------------
local function onJoin(player: Player)
	task.spawn(function()
		-- Wrapped, for the reason TutorialServer wraps its own arm: this is
		-- telemetry, and it is not allowed to be the reason a join fails.
		local ok, err = pcall(function()
			awaitProfile(player)
			if not player.Parent then
				return
			end
			startLadder(player)
			-- The same question TutorialServer asks before it grants lumps and
			-- TutorialHud asks before it draws, asked of the one file that owns it.
			if TutorialConfig.looksNew(player) then
				armOnboarding(player)
			end
		end)
		if not ok then
			warn("[Funnel] did not arm for " .. player.Name .. ": " .. tostring(err))
		end
	end)
end

local function onLeave(player: Player)
	onboarding[player] = nil
	local list = conns[player]
	if list then
		for _, conn in ipairs(list) do
			conn:Disconnect()
		end
		conns[player] = nil
	end
end

--------------------------------------------------------------------------
-- THE LOOP
--------------------------------------------------------------------------
local POLL = 1

local function pump()
	--[[
		THE LIST IS SNAPSHOT BEFORE THE WALK, and not because `advance` removes
		the player it has just finished -- clearing the CURRENT key during a
		traversal is explicitly allowed, and that one is fine.

		It is the other direction. `armOnboarding` ADDS a key, it runs from a
		spawned join task, and adding a key mid-traversal is precisely the
		mutation Lua leaves undefined. The two cannot interleave today, because
		nothing between here and there yields -- but the only reason the
		analytics calls do not yield is that Roblox's API does not, which is
		somebody else's promise about somebody else's code. A table walk over
		something that is empty on almost every tick is not a price worth
		haggling over to keep depending on it.
	]]
	local live = {}
	for player in pairs(onboarding) do
		table.insert(live, player)
	end

	for _, player in ipairs(live) do
		local st = onboarding[player]
		if st then
			if not player.Parent then
				onboarding[player] = nil
			else
				-- Per player, so one account's odd state cannot stop the others
				-- being measured, and so a mistake in a `done` test above is a
				-- warn rather than a dead loop.
				local ok, err = pcall(advance, player, st)
				if not ok then
					warn("[Funnel] onboarding step failed for " .. player.Name .. ": " .. tostring(err))
					onboarding[player] = nil
				end
			end
		end
	end
end

--------------------------------------------------------------------------
-- THE WASH BAY FUNNEL
--------------------------------------------------------------------------
--[[
	WashServer CALLS THIS; NOTHING HERE POLLS FOR IT, and that is the one place
	this file departs from its own header.

	The other two funnels are re-derived from the server's own attributes because
	the client must not be able to claim progress it has not made. That reasoning
	does not reach these four: every one of them is a thing the SERVER did --
	it decided the player was in range, it mounted the lump, it removed the chunk,
	it completed the wash. WashServer is not reporting the client's opinion, it is
	reporting its own. A poll here would be this file guessing at state another
	file already holds exactly.

	ONCE PER PLAYER PER STEP, PER SERVER. Roblox already ignores a repeated step
	within a session id, so this is not correctness -- it is not spending an API
	call on every chunk of every wash for the rest of a player's session. `seen`
	is keyed weakly so a leaver is not kept alive by it.

	SILENT ON A BAD KEY rather than throwing. This is instrumentation on the hot
	path of a live feature: a typo here should cost a missing chart, not a wash.
]]
local washSeen: { [Player]: { [string]: boolean } } = setmetatable({}, { __mode = "k" })

function FunnelServer.wash(player: Player, key: string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	local row = FunnelConfig.WashByKey[key]
	if not row then
		return
	end
	local seen = washSeen[player]
	if not seen then
		seen = {}
		washSeen[player] = seen
	end
	if seen[key] then
		return
	end
	seen[key] = true
	logFunnel(player, FunnelConfig.Wash.Name, FunnelConfig.Wash.sessionFor(player),
		row.step, row.name)
end

--------------------------------------------------------------------------
-- DEV
--------------------------------------------------------------------------
-- Where a player stands in all three funnels, for a command bar during a Play
-- session. The dashboard is hours behind and blind in Studio; this is not.
function FunnelServer.report(player: Player): string
	local st = onboarding[player]
	local rebirths = num(player, "Rebirths")
	local rung = FunnelConfig.rungFor(rebirths)
	return string.format(
		"%s | onboarding: %s | map: step %d %s | tide %d",
		player.Name,
		st and string.format("at funnel step %d (%s)", FLOW[st.index].step, stepName(FLOW[st.index].step))
			or (player:GetAttribute(TutorialConfig.DoneAttribute) and "done" or "not armed"),
		rung and rung.step or 0,
		rung and rung.name or "-",
		rebirths + 1
	)
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------
function FunnelServer.start()
	assert(RunService:IsServer(), "[FunnelServer] server-only")
	if started then
		return
	end
	started = true

	-- Drift, once, at boot. See FunnelConfig.audit: this is not an error and
	-- does not stop anything -- the funnel is already using the live number --
	-- it is how whoever re-paced a gate finds out a chart moved with it.
	for _, row in ipairs(FunnelConfig.audit()) do
		warn(string.format(
			"[Funnel] map rung %d (%s) is gated at %d rebirths, but FunnelConfig still "
				.. "witnesses %d. The funnel is using %d; update the witness column.",
			row.rung.step, row.rung.name, row.live, row.rung.gate, row.live))
	end

	Players.PlayerAdded:Connect(onJoin)
	Players.PlayerRemoving:Connect(onLeave)
	-- Anyone already in. This starts late in ServerMain and a fast joiner on a
	-- fresh server can beat it -- and that player is precisely the new one.
	for _, player in ipairs(Players:GetPlayers()) do
		onJoin(player)
	end

	task.spawn(function()
		while true do
			task.wait(POLL)
			pump()
		end
	end)

	print(string.format("[Funnel] online -- onboarding %d steps, map %d rungs, tide authored to %d (uncapped)%s",
		#FunnelConfig.OnboardingSteps, #FunnelConfig.MapRungs, LADDER_TIDES,
		FunnelServer.Trace and " (Studio: tracing, nothing sent)" or ""))
end

return FunnelServer
