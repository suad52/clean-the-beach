--[[
	EventService  --  ServerScriptService.EventService

	THE TEN-MINUTE CLOCK. One server event every EventConfig.Cycle seconds, and
	the three that are on it today.

	ONE OWNER, ONE LOOP. Every event in this game goes through here. Two
	independent timers is how a game ends up running two events at once, each
	unaware of the other, both writing the same multiplier -- and the first
	symptom is a receipt nobody can explain.

	IT IS A RECONCILER, NOT A SEQUENCE, and that is the whole reason it is
	trustworthy. It does not "wait 10 minutes, run an event, wait again": once a
	second it asks EventConfig what SHOULD be happening and makes that true. So a
	server that boots four minutes into Golden Hour joins Golden Hour already in
	progress; a hitch that eats three seconds costs three seconds and not the
	rotation; and there is no accumulated drift to correct because nothing is
	accumulating. The timetable is arithmetic on os.time() and this is the only
	thing that reads it.

	WHAT IT TOUCHES, AND WHAT IT REFUSES TO
	---------------------------------------
	  Golden Hour  writes ONE attribute. SellServer reads it. This module does
	               not know how a sale is priced and must not learn.
	  Scrap Rush   WeightService.setMaxWeight, which is the same call
	               ProgressionServer makes on every purchase -- and the restore
	               puts the bag back on the upgrade ladder rather than on a
	               remembered number, so a level bought mid-event survives.
	  Golden Cans  its own parts in its own folder, paying through
	               SellServer.addCoins. Deliberately NOT routed through the
	               trash/inventory/Index systems: a can is a race, not a find,
	               and giving it an ItemId would put it in the collection nobody
	               can ever complete.

	THE TUTORIAL IS NOT INTERRUPTED. The BANNER half of that is decided on the
	client, in EventHud: what a first-time player must not get is a countdown and
	a second thing to understand while they are still being told the first.

	THE MECHANICAL HALF IS WITHHELD TOO -- BUT ONLY FOR SCRAP RUSH. This header
	used to say the mechanical half of every event was silently good for you and
	so there was nothing to withhold, and for two of the three that is still
	true: a better price and a can you may happen to walk into cost a first-timer
	nothing to receive without understanding. A bigger BAG is different, because
	the onboarding's first step measures itself against the size of the bag --
	see the long note over `lift`, which is where that gate now lives. Withholding
	it does not reintroduce the shrink this paragraph used to warn about: a
	first-timer never receives the lift, so there is nothing to take back off them
	and nothing to shrink. What a finisher does NOT get is the lift on the very
	purchase that ends the onboarding -- read the last paragraph of the note over
	`lift` before you assume otherwise.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local EventConfig = require(Modules:WaitForChild("EventConfig"))
local Net = require(Modules:WaitForChild("Net"))
-- READ-ONLY, AND FOR ONE ATTRIBUTE NAME -- see `tutorialArmed` below. Pure
-- replicated data with no requires of its own, which is the same reason
-- ProgressionServer is willing to hold it at step 8, so it adds nothing to this
-- module's boot order and cannot tangle it.
local TutorialConfig = require(Modules:WaitForChild("TutorialConfig"))
local Config = require(ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Config"))
local WeightConfig = require(ReplicatedStorage:WaitForChild("WeightSystem"):WaitForChild("WeightConfig"))

local SellServer = require(script.Parent:WaitForChild("SellServer"))
local WeightService = require(script.Parent:WaitForChild("WeightSystem"):WaitForChild("WeightService"))

local EventService = {}

local live = nil          -- the event table currently running, or nil
local liveEndsAt = 0
local sentKey = nil       -- what the clients were last told
local started = false

--[[
	AN EVENT THAT IS NOT ON THE TIMETABLE, AND WHY THE LOOP HAS TO KNOW ABOUT ONE.

	The reconciler makes the schedule true once a second, which is exactly what
	makes it trustworthy -- and it also meant it UNDID anything started by hand a
	second later. forceNow looked like it worked because a screenshot taken inside
	that second showed the event; the tick then quietly stopped it, and Scrap Rush
	lifting nobody's bag is how that surfaced.

	So a forced run is a WINDOW the reconciler is told to respect rather than a
	one-off call it cannot see. While the window is open the forced event is what
	"should be happening"; when it closes, the timetable takes back over on the
	next tick with no special case to unwind.

	It is deliberately not a way to change the ROTATION. The schedule stays pure
	arithmetic on the wall clock -- which is the property that lets every server
	and every client agree without talking -- and this only ever overlays it.
]]
local forcedDef = nil
local forcedUntil = 0

--------------------------------------------------------------------------
-- TELLING THE CLIENTS
--------------------------------------------------------------------------
--[[
	THE CLIENT ALREADY KNOWS. It holds the same EventConfig and can read its own
	os.time(), so the countdown on screen is computed locally every frame and
	never stutters when the network does.

	What this message is actually for is the OFFSET. Two machines' clocks agree
	to within a second or so and not exactly, and a countdown that says 0:00 for
	two seconds looks broken. Sending `now` lets the client measure the gap once
	and subtract it forever after -- so the pill hits zero at the same instant
	the event starts, on every machine.
]]
-- What SHOULD be happening, forced window included. The one answer both the
-- reconciler and the broadcast work from, so a forced event cannot be running
-- while the clients are being told about the next scheduled one.
local function desired()
	local now = os.time()
	if forcedDef and now < forcedUntil then
		return {
			phase = "live",
			event = forcedDef,
			startsAt = forcedUntil - forcedDef.duration,
			endsAt = forcedUntil,
			left = forcedUntil - now,
		}
	end
	return EventConfig.stateAt(now)
end

local function broadcast()
	local st = desired()
	Net.get("EventState"):FireAllClients({
		phase = st.phase,
		id = st.event and st.event.id or nil,
		startsAt = st.startsAt,
		endsAt = st.endsAt,
		now = os.time(),
	})
end

--------------------------------------------------------------------------
-- GOLDEN HOUR
--------------------------------------------------------------------------
-- One attribute, on ReplicatedStorage, written only here. See the note on
-- EventConfig.liveSellMultiplier for why this is not a require.
local function goldenHourStart(def)
	ReplicatedStorage:SetAttribute(EventConfig.SellMultAttr, def.sellMultiplier)
end

local function goldenHourStop()
	ReplicatedStorage:SetAttribute(EventConfig.SellMultAttr, nil)
end

--------------------------------------------------------------------------
-- SCRAP RUSH
--------------------------------------------------------------------------
--[[
	THE RESTORE READS THE LADDER, IT DOES NOT REMEMBER A NUMBER.

	WeightService.setMaxWeight takes the bag off the Bucket Size curve until that
	level next moves, which is exactly the hook this wants. Putting it back by
	recomputing capacityForLevel -- rather than by storing what it was at the
	start -- means a player who buys two bag upgrades during the event keeps
	them. Remembering the old figure would silently refund them.

	NOBODY IS STRANDED. The bag can end the event holding far more than it can
	normally carry, and that is intended: what you grabbed is yours and the walk
	to the till is the whole shape of the event. WeightService already tolerates
	a load over its own max (it refuses the next pickup rather than dropping
	anything), so the only cost is that you must sell before you can collect
	again -- which is what `warnAt` exists to say out loud.
]]
--[[
	AND NOT FOR A PLAYER WHOSE TUTORIAL IS STILL ARMED. This closes the report
	of 2026-09-09 that Scrap Rush makes the onboarding's FIRST instruction
	impossible to carry out.

	"FILL YOUR BAG" IS A COMPARISON, NOT A NUMBER. TutorialHud passes that step
	when CurrentWeight >= MaxWeight - 0.75, so lifting a first-timer's bag to
	def.holdCap turns the step into a demand for 39,999 lb and it can never pass.
	Its RollerBlocked escape hatch cannot rescue them either -- that one wants a
	FULL bag, and the bag can no longer fill. The meter reads "2 lbs / 40000 lbs"
	pinned at zero, the pill that would at least name the cause is withheld from
	tutorial players by EventHud, and a brand-new player is stuck on the very
	first thing this game asks them to do with nothing on screen explaining why.
	About one new player in ten arrives inside a Scrap Rush window.

	GATED IN `lift` RATHER THAN IN scrapRushStart, because there are two ways in:
	the start sweep, and onPlayer for somebody who joins mid-event -- and a
	brand-new account joining mid-event is precisely the case being fixed.

	THE RESTORE IS GATED THE SAME WAY, DELIBERATELY. `drop` puts the bag back on
	the Bucket Size ladder; it reads WeightConfig and knows nothing of
	TutorialConfig.BagCap, so running it over an armed tutorial would hand a
	first-timer the full-size bag the onboarding's arithmetic is pitched against
	-- off the back of an event they never received. Nothing was lifted for them,
	so there is nothing to put back, and skipping is what leaves no stale cap.

	FINISHING MID-EVENT DOES NOT HAND THE LIFT STRAIGHT OVER, AND THE ORDER IS
	WHY. Signals in this place are deferred, so on the finishing purchase
	ProgressionServer.applyAll runs FIRST -- while the credit attribute is still
	standing, so it takes the tutorial clamp and never reaches the floor in its
	`else` -- and only then does TutorialServer's AttributeChanged fire finish(),
	whose disengage() writes the Bucket Size ladder with no floor of its own. So
	a player who finishes mid-Scrap-Rush carries the ordinary 12 lb bag until the
	next applyAll -- a respawn, another purchase, a rebirth -- picks the floor up.

	That is a missed minute of event, NOT a break: nobody is stuck, and because
	the ladder is what was written there is no stale cap for `drop` to clear. It
	is recorded rather than fixed because the losing write is in TutorialServer,
	not in this module: disengage() would have to take EventConfig.liveHoldCap()
	as a floor, exactly the way WeightService.applyCapacity already does. Noted
	2026-09-09, replacing a claim here that asserted the opposite.
]]
local function tutorialArmed(player: Player): boolean
	return player:GetAttribute(TutorialConfig.LumpsAttribute) ~= nil
end

local function lift(player: Player, def)
	if tutorialArmed(player) then
		return
	end
	WeightService.setMaxWeight(player, def.holdCap)
end

local function drop(player: Player)
	if tutorialArmed(player) then
		return
	end
	WeightService.setMaxWeight(player,
		WeightConfig.capacityForLevel(player:GetAttribute(WeightConfig.CapacityLevelAttribute)))
end

local function scrapRushStart(def)
	for _, p in ipairs(Players:GetPlayers()) do
		lift(p, def)
	end
end

local function scrapRushStop()
	for _, p in ipairs(Players:GetPlayers()) do
		drop(p)
	end
end

--------------------------------------------------------------------------
-- GOLDEN CANS
--------------------------------------------------------------------------
--[[
	FOURTEEN CANS, SPREAD OVER THE FOUR OPEN-AIR ISLANDS, FIRST TOUCH TAKES ONE.

	NOT ON ONE ISLAND. The point of the event is the choice of where to sweep --
	drop them all on the beach and it is a lap of the field everyone is standing
	on anyway. The three CHAMBER islands (the Vault, the Inner Shrine, the Magma
	Chamber) are left out: they are small sealed rooms behind deep rebirth gates,
	so a can in one is a can most of the server cannot reach.

	SEATED BY RAYCAST, like every other thing this game puts on the ground.
	A draw that lands off the island, in the sea or on a roof simply fails the
	height test and the next draw is taken -- which is cheaper and far more
	robust than trying to describe where each island's sand is.

	CLAIMED ON THE SERVER, ONCE. `Touched` fires here because the parts are
	anchored and the character is not; the `taken` flag is what makes it a race
	rather than a payout for everyone who walks past afterwards.
]]
local CAN_ISLANDS = { 1, 2, 4, 5, 8 }
local CAN_TAG = "CTB_GoldenCan"

local canFolder = nil
local canConns = {}
local canSpin = nil

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace.Terrain }
groundParams.IgnoreWater = true

-- Returns the spot AND the island it was drawn on. The island is what prices
-- the can (EventConfig.canCoinsByIsland), and it is far cheaper to keep the
-- draw's own answer than to work backwards from a position later.
local function seat(rng: Random): (Vector3?, number?)
	local islandId = CAN_ISLANDS[rng:NextInteger(1, #CAN_ISLANDS)]
	local isl = Config.island(islandId)
	if not isl then
		return nil
	end
	-- A shade wider than the rakeable square, so the hunt reaches the dressing
	-- and the shoreline instead of pacing the grid.
	local reach = isl.half * 1.15
	local x = isl.cx + rng:NextNumber(-reach, reach)
	local z = isl.cz + rng:NextNumber(-reach, reach)
	local hit = workspace:Raycast(Vector3.new(x, 220, z), Vector3.new(0, -400, 0), groundParams)
	if not hit then
		return nil
	end
	-- On the flat, not on a dune shoulder or the shelf into the water.
	if math.abs(hit.Position.Y - (isl.cleanY or 3)) > 6 then
		return nil
	end
	-- Hovering a stud over the sand, which the bob below swings about.
	return Vector3.new(x, hit.Position.Y + 1.4, z), islandId
end

local function payCan(player: Player, def, can: BasePart)
	if can:GetAttribute("Taken") then
		return
	end
	can:SetAttribute("Taken", true)

	-- PRICED BY THE ISLAND IT IS STANDING ON -- see EventConfig's note on
	-- canCoinsByIsland. Read off the can rather than recomputed: the draw that
	-- placed it happened up to a minute ago and is long gone.
	local coins = EventConfig.canCoinsFor(def, can:GetAttribute("Island"))
	SellServer.addCoins(player, coins, "event")
	Net.get("Notify"):FireClient(player, {
		text = string.format("Golden can! +%d coins", coins),
		kind = "money",
	})
	--[[
		EVERYBODY SEES WHERE IT WENT. A race nobody can watch is not a race.

		Through the Fx remote's OWN vocabulary rather than a fifth one invented
		here: "Upgrade" is the kind FeedbackClient already answers with a rare
		sparkle burst and a chime, and it takes a PART, not a position.

		Which is why the can is hidden rather than destroyed on this line. The
		burst is parented to the part it is given, so taking that part away in
		the same frame takes the sparkle with it -- the can goes invisible and
		inert now, and is cleaned up once the effect it is anchoring has played.
	]]
	can.CanTouch = false
	can.CanCollide = false
	can.Transparency = 1
	local light = can:FindFirstChildOfClass("PointLight")
	if light then
		light.Enabled = false
	end
	local billboard = can:FindFirstChildOfClass("BillboardGui")
	if billboard then
		billboard:Destroy()
	end
	local beacon = can:FindFirstChild("Beacon")
	if beacon then
		beacon:Destroy()
	end
	Net.get("Fx"):FireAllClients({ kind = "Upgrade", part = can })
	Debris:AddItem(can, 1.6)
end

local function buildCan(def, at: Vector3, islandId: number?)
	local can = Instance.new("Part")
	can.Name = "GoldenCan"
	-- Stamped here, at the top, and not down beside the Touched connection: a
	-- player already standing on the draw spot claims the can on the first
	-- frame it is touchable, and an unpriced can is worth the fallback rate
	-- rather than the island's.
	can:SetAttribute("Island", islandId)
	can.Shape = Enum.PartType.Cylinder
	--[[
		LYING ON ITS SIDE, AND THAT IS WHAT MAKES THE SPIN VISIBLE.

		A Roblox cylinder runs along its LOCAL X. The first cut rolled it 90 degrees
		to stand it on end and then turned it about Y -- which is spinning a
		cylinder around its own axis of symmetry, i.e. an animation that renders as
		absolutely nothing. On screen it was a yellow blob sitting perfectly still.

		Unrolled, the axis lies along world X and the same Y turn sweeps it through
		the horizontal: you see the round end, then the side, then the end. That is
		the silhouette every collectible in every game has, and it costs one fewer
		rotation than the version that did not work.
	]]
	can.Size = Vector3.new(3.2, 1.9, 1.9)
	can.CFrame = CFrame.new(at)
	can.Anchored = true
	can.CanCollide = false
	can.CanTouch = true
	can.CanQuery = false
	can.Color = Color3.fromRGB(255, 200, 62)
	can.Material = Enum.Material.Neon
	can.TopSurface = Enum.SurfaceType.Smooth
	can.BottomSurface = Enum.SurfaceType.Smooth
	can.CastShadow = false
	can.Parent = canFolder

	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 214, 120)
	glow.Brightness = 3.2
	glow.Range = 22
	glow.Shadows = false
	glow.Parent = can

	--[[
		THE BEACON, AND IT IS THE ONE THAT ACTUALLY DOES THE JOB.

		Fourteen cans nobody can find is not a race, it is a chore, so a can has to
		read from across a field. The obvious marker is the BillboardGui below and
		it is NOT load-bearing here: not one BillboardGui in this place -- mine, a
		control probe, or the three the game already had -- would show up in a
		Studio screen capture, so there is no way to confirm from here that a player
		would see it. (SurfaceGuis capture fine, which is the same split this
		place's notes already record for Edit-mode captures.)

		So findability is bought with GEOMETRY, which can be checked: a tall soft
		shaft of light standing in the sand. It is the treasure-marker every game
		uses, it reads at a distance the can never could on its own, and it cannot
		be undone by anything to do with GUI rendering.

		A CHILD OF THE CAN, so the cleanup that takes the can takes this with it.
		It is not in the spin loop -- that walks the FOLDER -- so it stands still
		while the can turns underneath it, which is what a beacon should do.
	]]
	local beacon = Instance.new("Part")
	beacon.Name = "Beacon"
	beacon.Shape = Enum.PartType.Cylinder
	-- Cylinders run along LOCAL X, so this is (height, width, width) stood upright.
	beacon.Size = Vector3.new(30, 2.6, 2.6)
	beacon.CFrame = CFrame.new(at + Vector3.new(0, 14, 0)) * CFrame.Angles(0, 0, math.rad(90))
	beacon.Anchored = true
	beacon.CanCollide = false
	beacon.CanTouch = false
	beacon.CanQuery = false
	beacon.CastShadow = false
	beacon.Color = Color3.fromRGB(255, 214, 120)
	beacon.Material = Enum.Material.Neon
	beacon.Transparency = 0.62
	beacon.Parent = can

	-- Kept as well, because it costs nothing and is very probably fine for a real
	-- player -- it simply cannot be verified from here. See the note above.
	local board = Instance.new("BillboardGui")
	board.Name = "CanMark"
	board.Size = UDim2.fromOffset(64, 64)
	-- Just over the can rather than five studs up: high enough to clear it, low
	-- enough that the mark and the thing it marks read as one object.
	board.StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0)
	board.AlwaysOnTop = true
	board.MaxDistance = 420
	board.LightInfluence = 0
	board.Parent = can

	local pip = Instance.new("TextLabel")
	pip.Size = UDim2.fromScale(1, 1)
	pip.BackgroundTransparency = 1
	pip.Font = Enum.Font.LuckiestGuy
	pip.Text = "$"
	pip.TextSize = 40
	pip.TextColor3 = Color3.fromRGB(255, 246, 205)
	pip.Parent = board
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(56, 36, 20)
	stroke.Parent = pip

	table.insert(canConns, can.Touched:Connect(function(hit)
		local character = hit and hit.Parent
		local player = character and Players:GetPlayerFromCharacter(character)
		if player then
			payCan(player, def, can)
		end
	end))
	return can
end

local function goldenCansStart(def)
	if canFolder then
		canFolder:Destroy()
	end
	canFolder = Instance.new("Folder")
	canFolder.Name = "GoldenCans"
	canFolder.Parent = workspace

	local rng = Random.new(os.time())
	local made, tries = 0, 0
	while made < def.cans and tries < def.cans * 60 do
		tries += 1
		local at, islandId = seat(rng)
		if at then
			buildCan(def, at, islandId)
			made += 1
		end
	end

	-- One loop for all fourteen rather than a tween each: a can that turns is a
	-- can the eye catches at the edge of the screen, and this is the cheapest
	-- way to buy that.
	local t = 0
	canSpin = RunService.Heartbeat:Connect(function(dt)
		t += dt
		if not canFolder or not canFolder.Parent then
			return
		end
		for _, can in ipairs(canFolder:GetChildren()) do
			if can:IsA("BasePart") and not can:GetAttribute("Taken") then
				local base = can:GetAttribute("BaseY")
				if not base then
					base = can.Position.Y
					can:SetAttribute("BaseY", base)
				end
				can.CFrame = CFrame.new(can.Position.X, base + math.sin(t * 2.2) * 0.35, can.Position.Z)
					* CFrame.Angles(0, t * 1.9, 0)
			end
		end
	end)

	print(string.format("[Events] %d golden cans out over %d islands", made, #CAN_ISLANDS))
end

local function goldenCansStop()
	if canSpin then
		canSpin:Disconnect()
		canSpin = nil
	end
	for _, c in ipairs(canConns) do
		c:Disconnect()
	end
	table.clear(canConns)
	if canFolder then
		canFolder:Destroy()
		canFolder = nil
	end
end

--------------------------------------------------------------------------
-- THE SWITCHBOARD
--------------------------------------------------------------------------
local HANDLERS = {
	golden_hour = { start = goldenHourStart, stop = goldenHourStop },
	scrap_rush  = { start = scrapRushStart,  stop = scrapRushStop },
	golden_cans = { start = goldenCansStart, stop = goldenCansStop },
}

local warned = false

local function startEvent(def, endsAt: number)
	live, liveEndsAt, warned = def, endsAt, false
	ReplicatedStorage:SetAttribute(EventConfig.LiveAttr, def.id)
	local h = HANDLERS[def.id]
	if h and h.start then
		local ok, err = pcall(h.start, def)
		if not ok then
			warn("[Events] " .. def.id .. " failed to start: " .. tostring(err))
		end
	end
	print(string.format("[Events] %s is live for %ds", def.name, def.duration))
end

local function stopEvent()
	if not live then
		return
	end
	local def = live
	live = nil
	ReplicatedStorage:SetAttribute(EventConfig.LiveAttr, nil)
	local h = HANDLERS[def.id]
	if h and h.stop then
		local ok, err = pcall(h.stop, def)
		if not ok then
			warn("[Events] " .. def.id .. " failed to stop: " .. tostring(err))
		end
	end
	print(string.format("[Events] %s over", def.name))
end

--------------------------------------------------------------------------
-- THE TICK
--------------------------------------------------------------------------
local function tick()
	-- Closed the moment it expires, so `desired` below is already back on the
	-- timetable for the rest of this same tick.
	if forcedDef and os.time() >= forcedUntil then
		forcedDef = nil
	end

	local st = desired()

	if st.phase == "live" then
		if not live or live.id ~= st.event.id then
			stopEvent()
			startEvent(st.event, st.endsAt)
		end
	elseif live then
		stopEvent()
	end

	-- The last-call shout, for an event that ends with the player holding
	-- something they have to do something about.
	if live and live.warnAt and not warned and (liveEndsAt - os.time()) <= live.warnAt then
		warned = true
		for _, p in ipairs(Players:GetPlayers()) do
			Net.get("Notify"):FireClient(p, {
				text = string.format("%s ends in %d -- get to the till!", live.name, live.warnAt),
				kind = "warn",
			})
		end
	end

	local key = st.phase .. "/" .. tostring(st.event and st.event.id)
	if key ~= sentKey then
		sentKey = key
		broadcast()
	end
end

--------------------------------------------------------------------------
-- JOINERS
--------------------------------------------------------------------------
-- Somebody arriving mid-event gets the event, not the next one. The bag lift is
-- the only one that needs doing by hand -- the multiplier is global and the cans
-- are already standing in the world.
local function onPlayer(player: Player)
	task.defer(function()
		if live and live.id == "scrap_rush" then
			lift(player, live)
		end
		broadcast()
	end)
end

--------------------------------------------------------------------------
-- THE CONTROL HOOK
--------------------------------------------------------------------------
--[[
	A BindableFunction IN ServerStorage, AND IT IS NOT DECORATION.

	REQUIRING THIS MODULE FROM OUTSIDE THE RUNNING GAME GIVES YOU A DIFFERENT
	COPY OF IT. A require made from the command bar or a plugin has its own
	module cache, so `require(EventService).forceNow(...)` builds a SECOND service
	with its own `live`, its own forced window and -- worse -- its own
	WeightService, whose ledgers are empty. Everything that goes through shared
	state still appears to work (Golden Hour writes an attribute, the pill lights
	up) and everything that needs the real server's memory silently does nothing.
	Scrap Rush lifting nobody's bag is exactly how that surfaced here, and it cost
	an hour of looking for a bug in the wrong file.

	So the way in is an INSTANCE rather than a require, which is the same shape
	WeightService already uses for its report hook.

		local c = game.ServerStorage.EventService_Control
		c:Invoke("force", "scrap_rush", 30)
		c:Invoke("stop")
		c:Invoke("state")

	ServerStorage, so it does not replicate: a client cannot see it, let alone
	call it.
]]
local CONTROL_NAME = "EventService_Control"

local function exposeControl()
	local ServerStorage = game:GetService("ServerStorage")
	local existing = ServerStorage:FindFirstChild(CONTROL_NAME)
	if existing then
		existing:Destroy()
	end
	local hook = Instance.new("BindableFunction")
	hook.Name = CONTROL_NAME
	hook.OnInvoke = function(verb, a, b)
		if verb == "force" then
			return EventService.forceNow(a, b)
		elseif verb == "stop" then
			return EventService.stopNow()
		end
		local st = desired()
		return string.format("%s  %s  %s left", st.phase,
			st.event and st.event.id or "-", EventConfig.clock(st.left))
	end
	hook.Parent = ServerStorage
end

--------------------------------------------------------------------------
function EventService.start()
	if started then
		return
	end
	started = true

	ReplicatedStorage:SetAttribute(EventConfig.SellMultAttr, nil)
	ReplicatedStorage:SetAttribute(EventConfig.LiveAttr, nil)

	Players.PlayerAdded:Connect(onPlayer)
	for _, p in ipairs(Players:GetPlayers()) do
		onPlayer(p)
	end

	task.spawn(function()
		while true do
			local ok, err = pcall(tick)
			if not ok then
				warn("[Events] tick: " .. tostring(err))
			end
			task.wait(1)
		end
	end)

	exposeControl()

	local st = EventConfig.stateAt()
	print(string.format("[Events] clock online -- %d event(s), %ds cycle; next up %s in %s",
		#EventConfig.Events, EventConfig.Cycle,
		st.event and st.event.name or "nothing", EventConfig.clock(st.left)))
end

--[[
	FOR TESTING, and it is honest about what it is: it runs an event NOW,
	outside the rotation, and the next tick puts the timetable back. The
	schedule is arithmetic on the wall clock and nothing can change that from
	in here -- which is the property that makes the rotation trustworthy, so
	this deliberately does not try.
]]
function EventService.forceNow(id: string, seconds: number?)
	local def = EventConfig.ById[id]
	if not def then
		return "no such event: " .. tostring(id)
	end
	forcedDef = def
	forcedUntil = os.time() + (seconds or def.duration)
	-- Run the reconciler now rather than waiting up to a second for it: the
	-- caller is a person watching, and the tick is what does the work either way.
	sentKey = nil
	tick()
	return string.format("%s forced for %ds", def.name, forcedUntil - os.time())
end

function EventService.stopNow()
	forcedDef = nil
	forcedUntil = 0
	stopEvent()
	sentKey = nil
	broadcast()
	return "stopped"
end

return EventService
