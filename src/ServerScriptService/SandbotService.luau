--[[
	SandbotService  --  ServerScriptService.SandbotService

	THE SANDBOT: one autonomous sifter per player, sent out from the SANDBOT
	HOME at the end of each island's egg row, working the owner's own field on its
	own until it is recalled or the bag fills.

	IT LEAVES AND RETURNS UNDER ITS OWN POWER. A deploy starts ON THAT KENNEL'S
	CHARGING PLATE, in the display machine's own pose, and drives out through the
	mouth; a recall drives back to the apron, turns in, settles on the plate and
	hands over to the display. Neither end of that is a spawn or a Destroy that the
	player can see. See DOCK_STATES.

	WHAT THIS FILE OWNS AND WHAT IT EMPHATICALLY DOES NOT
	----------------------------------------------------
	It owns WHERE THE DRONE IS. That is the whole job: a target, a heading, a
	position written every tick, and the small state machine that decides which
	of those it wants.

	It owns NOTHING ABOUT MONEY. There is not a coin, a weight, an item id or a
	cell index anywhere below. Raking goes through CTBBridge.sweepDrone, which
	is CTB_Server's own rake handed over as a function -- the same rakeRect the
	player's sifter runs through -- so a column the drone clears pays what a
	column the player clears pays, a find goes into the same bag through the
	same tryAdd, and a full bag stops it with the same refusal. Two rakes would
	be two things to balance against each other forever; there is one.

	WHY IT IS ANCHORED AND NOT A PHYSICS BODY
	-----------------------------------------
	AtvServer drives real bodies because a player is sitting in them and steering.
	Nobody steers this. A free-rolling body on a beach full of deckchairs, kerbs
	and a sea to fall into is a long list of ways for a paid feature to end up
	stuck or gone, none of which buys anything -- so the hull is anchored, its
	CFrame is written, and the rest of the drone is welded to it and comes along
	for free. One replicated part per drone per tick.

	It is also CanCollide false throughout, which is not laziness either: a solid
	drone would shove the player who bought it off their own rake line.

	THE SECURITY SHAPE
	------------------
	THE CLIENT SENDS NOTHING AT ALL. Deploy and recall are the two things one
	ProximityPrompt on the dock does, and its Triggered fires on the SERVER --
	so the engine itself vouches that the player was standing in front of the
	machine, where the remote this replaced could only ever claim they were.
	There is no verb to forge and no payload to tamper with. Same argument the
	egg station and the upgrade kiosk are built on; see Net's own header.

	Where the drone goes, how fast, what it rakes, what it picks up and when it
	comes home are all decided below, because every one of them is worth money.

	Ownership is re-asked of GamePassService (which asks Roblox) behind a
	cooldown, exactly the way CTB_Server's QuickSell branch does and for the same
	reason: without the ration, a prompt anyone can lean on is a way to make this
	server hammer UserOwnsGamePassAsync. The replicated attribute is never the
	answer -- see PassConfig's note on `owns`.

	The one thing that travels the other way is SandbotOffer, and it grants
	nothing: it names a pass id so SandbotClient can open Roblox's own purchase
	dialog, which is a call a server cannot make.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Net = require(Modules:WaitForChild("Net"))
local SandbotConfig = require(Modules:WaitForChild("SandbotConfig"))
local PassConfig = require(Modules:WaitForChild("PassConfig"))
local Config = require(ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Config"))

local SandbotBuilder = require(ServerScriptService:WaitForChild("SandbotBuilder"))
local SandbotDockBuilder = require(ServerScriptService:WaitForChild("SandbotDockBuilder"))
local Bridge = require(ServerScriptService:WaitForChild("CTBBridge"))
local Passes = require(ServerScriptService:WaitForChild("GamePassService"))

local SandbotService = {}

local FOLDER_NAME = "Sandbots"

-- Seconds between two re-asks of Roblox for one player's pass. See the header.
local PASS_REASK = 6

--[[
	HOW FAR IS "THAT IS NOT WALKING".

	Past this from its owner the drone is TELEPORTED home rather than driven --
	the owner took a ferry, finished a duel, rebirthed, came back from the idle
	shore. Driving would send it swimming across an ocean at 22 studs a second
	for over two minutes.

	400 is comfortably outside any one island's field (the largest is 640 across
	but the leash is 180) and far inside the distance to the next one.
]]
local SNAP_HOME = 400

--[[
	HOW FAR OFF THE SAND YOU MAY STILL SEND IT OUT.

	The first version of this gated deploy on Config.fieldAt -- "are you standing
	on a rakeable field" -- and that refused on the very first press, because the
	spawn point is not on one. The beach's field is 256 studs square centred on
	the origin and the shop row is BEHIND it: a fresh character stands at
	z = -139, eleven studs outside the sand they are looking at.

	So the test is "is there sand within reach" instead, and the drone is put
	down on the nearest bit of it. 60 covers the shop row, the sell pad, the wash
	bay and the spawn, and is nowhere near far enough to reach one island's sand
	from another's -- the closest two fields in the game are the beach and the
	cove, 1,596 studs apart.

	IT DOES NOT COVER ALL FOUR KENNELS and is not asked to: the dunes apron is
	82.6 studs off its own field and Ashfall's is 177.7. A dock is somewhere to
	put a drone down whatever is around it, so `spawn` skips this gate entirely
	whenever it has a berth -- see the block above berthFor. `pickTarget` used to
	borrow this number as the distance a drone would DRIVE to find work, which
	was the same mistake one step along; it asks the leash now.

	The refusal is kept for genuinely being nowhere near a beach (the idle shore,
	a duel arena, the vault), because there really is nothing for a drone to do
	there and a purchase that spawns something useless is worse than one that
	says why not.
]]
local DEPLOY_REACH = 60

-- How far inside the field's own edge a drone is placed when it is being put
-- down from outside. Two studs, so the first sweep is unambiguously on the
-- field rather than balanced on a boundary that `fieldAt` treats as inclusive
-- and the cell arithmetic then has to clamp.
local EDGE_INSET = 2

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------
--[[
	One record per player with a drone out. A player with no drone has NO ENTRY
	-- not an entry with `out = false` -- so the tick loop iterates only drones
	that exist rather than every player on the server.
]]
type Drone = {
	model: Model,
	hull: BasePart,
	lamp: BasePart?,
	dust: ParticleEmitter?,
	pos: Vector3,          -- where it is, in full 3D
	yaw: number,           -- heading, radians about Y
	last: Vector3,         -- last swept band centre, FLATTENED (y = 0)
	target: Vector3?,
	state: string,
	nextTarget: number,
	nextRoom: number,
	raked: number,         -- columns cleared this deployment
	orbit: number,
	lampAt: string?,       -- which state the lamp is currently painted for
	dustOn: boolean,
	-- THE KENNEL IT BELONGS TO, held for the whole deployment rather than looked
	-- up again on recall: the building can be destroyed under it (Island4 rebuilds
	-- its island wholesale), and a pose is a value where a model is a reference.
	berth: CFrame?,        -- where it parks at home, facing out; nil with no dock
	mouth: Vector3?,       -- the apron point it leaves through and lines up on
	parkAt: number,        -- when the park beat is up and the display takes over
}

local drones: { [Player]: Drone } = {}
local lastAsk: { [Player]: number } = {}
local connections = {}
local folder: Folder
local started = false

----------------------------------------------------------------
-- OWNERSHIP
----------------------------------------------------------------
--[[
	THE SERVER'S ANSWER, and the only one anything here acts on.

	Never the replicated attribute -- that is the client's copy and exists so a
	key can decide whether to say BUY or DEPLOY. See PassConfig's note on `owns`.

	`mayAsk` is rationed by the caller. GamePassService.ownsFlat with refresh
	true YIELDS on a web call, and it is what rescues a player whose join sweep
	hit a network blip -- without it they would be refused the pass they paid
	for until they rejoined.
]]
local function ownsSandbot(player: Player, mayAsk: boolean): boolean
	if SandbotConfig.devUnlocked() then
		return true
	end
	return Passes.ownsFlat(player, SandbotConfig.PassKey, mayAsk)
end

local function mayAskNow(player: Player): boolean
	local now = os.clock()
	if now - (lastAsk[player] or -math.huge) < PASS_REASK then
		return false
	end
	lastAsk[player] = now
	return true
end

local function tell(player: Player, text: string, kind: string?)
	Net.get("Notify"):FireClient(player, { text = text, kind = kind or "info" })
end

--[[
	THERE IS NO CARD TO KEEP FED.

	This file used to fire a SandbotSync at 2.5 Hz per deployed drone, carrying
	the state, its label and the running raked count, to draw a second line on
	the HUD key. The key is gone (see the header) and the sync went with it --
	remote, config dial and all.

	What says what the drone is doing now is `paint` below: the lamp on its lid,
	one replicated Color written on the CROSSING only, which everybody who can
	see the drone reads rather than only its owner. The two things worth
	interrupting somebody for -- a full bag, a refused deploy -- are toasts.
]]

-- Written on the CROSSING only. Both of these are replicated properties, and a
-- Color or an Enabled rewritten every tick is a stream of network traffic
-- saying exactly what the previous tick said. AtvServer's spray does the same.
local function paint(d: Drone)
	if d.lampAt ~= d.state then
		d.lampAt = d.state
		if d.lamp and d.lamp.Parent then
			d.lamp.Color = SandbotConfig.Lamps[d.state] or SandbotConfig.Lamps.docked
		end
	end
	-- Dust while it is actually working a field, not while it is crossing one or
	-- parked beside its owner.
	local want = (d.state == "hunting" or d.state == "litter")
	if d.dustOn ~= want then
		d.dustOn = want
		if d.dust and d.dust.Parent then
			d.dust.Enabled = want
		end
	end
end

----------------------------------------------------------------
-- SPAWN / DESPAWN
----------------------------------------------------------------
local function rootOf(player: Player): BasePart?
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hrp and hrp:IsA("BasePart") and hum and hum.Health > 0 then
		return hrp
	end
	return nil
end

--[[
	THE HEIGHT THE DRONE RIDES AT.

	On a field this is exact and needs no raycast: Config.surfaceY is one flat
	number per island, because raked and unraked columns are deliberately the
	same height (only the MATERIAL changes -- see the long note on
	Config.surfaceY about why). So the sand under the drone is never a surprise.

	OFF a field there is no such promise -- a plaza, a dock, a shop floor -- so
	it falls back to the owner's own feet, which is the one height that is
	certainly ground. An R15 HumanoidRootPart sits 2 studs over them.
]]
local function rideY(at: Vector3, hrp: BasePart?): number
	local lift = SandbotConfig.Height * 0.5 + SandbotConfig.Hover
	local isl = Config.fieldAt(at)
	if isl then
		return Config.surfaceY(isl) + lift
	end
	if hrp then
		return hrp.Position.Y - 2 + lift
	end
	return at.Y
end

local function despawn(player: Player, quiet: boolean?)
	local d = drones[player]
	if not d then
		return
	end
	drones[player] = nil
	if d.model then
		d.model:Destroy()
	end
	if player.Parent then
		player:SetAttribute(SandbotConfig.OutAttribute, false)
		-- Cleared with it, always. It is the client's answer to "whose kennel is
		-- standing empty", and an empty kennel with no drone anywhere in the world is
		-- worse than no effect at all.
		player:SetAttribute(SandbotConfig.HomeAttribute, nil)
		if not quiet then
			tell(player, "Sandbot packed away.")
		end
	end
end

--[[
	IT COMES OUT OF THE BUILDING IT LIVES IN.

	`dock` is where the press came from, and with one there is nothing else to work
	out: the drone is placed on that kennel's charging plate, in the display
	machine's own pose, facing the mouth, and drives out under its own power.
	Nothing about the owner is consulted -- not their position, not their facing,
	and not whether there is sand within reach of them.

	THAT LAST ONE WAS A BUG ON HALF THE ISLANDS, and it was a bug BECAUSE the drone
	used to be put down beside the PLAYER. Somewhere to stand it had to be found
	within DEPLOY_REACH -- and MEASURED from the four docks, the nearest field is
	42.6 studs away at the beach and 13.8 at the cove, but 82.6 at the dunes and
	177.7 on Ashfall, against a reach of 60. So pressing E at two of the four docks
	answered "there is nothing to rake here" to somebody standing in front of the
	machine's own house. A dock IS somewhere to stand it, so the question no longer
	arises there.

	WITHOUT a dock -- the command bar, or a hand-built one this file can read no
	berth off -- it falls back to the old rule, gate, refusal and all. Which is
	right: with nowhere to drive out OF, "is there anywhere to drive out ONTO" is a
	real question again.
]]
--[[
	THE TWO POINTS A DOCK GIVES A DRONE: where it parks, and the apron point it
	comes and goes through.

	Solved together because the second is derived from the first, and kept as
	VALUES rather than as the model they came off: the building can be destroyed
	under a drone that is out (Island4 rebuilds its whole island), and a pose that
	no longer has a building round it still gets the machine home.
]]
local function berthFor(dock: Model?): (CFrame?, Vector3?)
	local berth = SandbotDockBuilder.berth(dock)
	if not berth then
		return nil, nil
	end
	return berth, (berth * CFrame.new(0, 0,
		SandbotDockBuilder.MouthGap + SandbotConfig.DockApron)).Position
end

local function spawn(player: Player, dock: Model?): boolean
	local berth, mouth = berthFor(dock)
	local hrp = rootOf(player)

	local at: Vector3
	local yaw: number

	if berth then
		at = berth.Position
		-- The berth's +Z is the mouth, and Roblox's LookVector is the NEGATIVE Z
		-- axis -- so this points the machine the way it is about to drive, on the
		-- same +Z-is-the-nose convention the whole file steers by.
		local out = -berth.LookVector
		yaw = math.atan2(out.X, out.Z)
	else
		if not hrp then
			tell(player, "You need to be on your feet to send the sandbot out.")
			return false
		end

		-- Which way the owner is facing, flattened. Used both to place the drone and
		-- to point it, so it starts out looking the same way they are.
		local look = hrp.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		flat = flat.Magnitude > 1e-3 and flat.Unit or Vector3.new(0, 0, 1)
		local side = Vector3.new(-flat.Z, 0, flat.X)
		yaw = math.atan2(flat.X, flat.Z)

		--[[
			IT GOES DOWN ON SAND, WHEREVER THE PLAYER IS STANDING.

			On a field: beside them, so it drives off from where they are working.
			Off one but within DEPLOY_REACH: on the nearest sand.

			Further than that is a real refusal. There is nothing for a drone to do on
			the idle shore, in a duel arena or inside the vault, and putting one down
			with no work to do reads as a broken feature. This also takes all three of
			those out of scope without this file knowing they exist.
		]]
		if Config.fieldAt(hrp.Position) then
			-- Beside the owner and slightly behind: it drives off ahead of them rather
			-- than materialising in their face.
			at = hrp.Position + side * 4 - flat * 2
		else
			local _, spot, dist = Config.nearestField(hrp.Position, EDGE_INSET)
			if not spot or dist > DEPLOY_REACH then
				tell(player, "Get closer to a beach to send the sandbot out \u{2014} there is nothing to rake here.")
				return false
			end
			at = spot
		end
	end

	local model = SandbotBuilder.template():Clone()
	local hull = model.PrimaryPart
	if not hull then
		model:Destroy()
		warn("[SandbotService] template has no PrimaryPart")
		return false
	end

	-- A BERTH ALREADY CARRIES ITS HEIGHT -- it is the plate, measured. Only the
	-- beside-the-owner placement has to look one up, and rideY is what knows how.
	if not berth then
		at = Vector3.new(at.X, rideY(at, hrp), at.Z)
	end

	model.Name = "Sandbot_" .. player.UserId
	model:SetAttribute("OwnerUserId", player.UserId)

	--[[
		PivotTo THE MODEL. NEVER hull.CFrame, AND NOT ON THIS LINE.

		This was `hull.CFrame = ...` and it tore the drone to pieces on the first
		deploy, in a way worth writing down because nothing errors and it looks
		like a rendering bug:

		  * every part except the hull is UNANCHORED and held by a WeldConstraint
		  * a WeldConstraint locks the offset its two parts have WHEN IT BECOMES
		    ACTIVE, which is when the model enters the workspace
		  * writing hull.CFrame while the clone is still parentless moves ONLY the
		    hull -- there is no live weld yet to drag anything with it

		So the welds activated with the hull beside the player and the entire body
		still at the template's origin, and locked it that way: a bare invisible
		hull driving off across the beach, a blue drone standing 126 studs behind
		it, and the brush blades (welded to a hub the Motor6D had moved) falling
		through the floor forever, because CanCollide is false on all of it.

		PivotTo moves every part together, so the offsets the welds are about to
		capture are the ones the builder authored. After this the hull IS the whole
		machine and step() can write its CFrame every tick, which is the ordinary
		anchored-root-plus-welded-shell arrangement AtvBuilder uses.
	]]
	model:PivotTo(CFrame.new(at) * CFrame.Angles(0, yaw, 0))
	model.Parent = folder

	drones[player] = {
		model = model,
		hull = hull,
		lamp = model:FindFirstChild("Lamp"),
		dust = hull:FindFirstChild("Dust"),
		pos = at,
		yaw = yaw,
		-- Seeded to where it IS, never left nil: the band is built from last -> now
		-- and a nil first sample would rake a stripe from the world origin.
		last = Vector3.new(at.X, 0, at.Z),
		target = nil,
		-- OUT OF THE KENNEL FIRST, when it is in one: `leaving` runs dockStep rather
		-- than the ordinary machinery until it has cleared the mouth. See DOCK_STATES.
		state = berth and "leaving" or "docked",
		berth = berth,
		mouth = mouth,
		-- WHICH ISLAND IT BELONGS TO, captured once at deploy. step() packs the drone
		-- away the moment its owner is somewhere else; the long note there says why
		-- this is the ZONE and not the field. nil (a hand-placed drone somewhere with
		-- no zone at all) switches that rule off rather than firing it every tick.
		zone = Config.zoneAt(at),
		-- When the owner was FIRST seen somewhere the drone cannot work, or nil when
		-- they are somewhere it can. A timestamp and not a flag, because a teleport in
		-- flight looks exactly like a ferry for a frame or two -- see step().
		awayAt = nil,
		parkAt = 0,
		nextTarget = 0,
		nextRoom = 0,
		raked = 0,
		orbit = 0,
		lampAt = nil,
		dustOn = false,
	}

	-- BEFORE the OutAttribute, which is the edge SandbotClient repaints on -- it
	-- reads this one in the same pass to decide whose kennel to empty.
	if dock then
		player:SetAttribute(SandbotConfig.HomeAttribute, dock.Name)
	end
	player:SetAttribute(SandbotConfig.OutAttribute, true)
	paint(drones[player])
	return true
end

----------------------------------------------------------------
-- WHERE TO GO NEXT
----------------------------------------------------------------
--[[
	LITTER FIRST, THEN SAND, THEN HOME -- and every candidate is checked against
	THE OWNER'S position, not the drone's.

	That is what makes the leash a leash. Checking the target against the drone
	would let it walk itself across the island one 90-stud hop at a time, each
	one legal, and end up exactly where the leash exists to stop it being.
]]
local function pickTarget(player: Player, d: Drone, home: Vector3): (Vector3?, string)
	local function inReach(spot: Vector3): boolean
		local dx, dz = spot.X - home.X, spot.Z - home.Z
		return dx * dx + dz * dz <= SandbotConfig.Leash * SandbotConfig.Leash
	end

	local nose = Vector3.new(math.sin(d.yaw), 0, math.cos(d.yaw))

	--[[
		BOTH SEARCHES NEED A POINT THAT IS ON A FIELD, and neither the drone nor
		its owner is reliably standing on one.

		The sell counter, the shop, the wash deck and the spawn are all just OFF
		the beach's square -- eleven studs, in the spawn's case -- and that is
		where a player spends a good part of the session. Searching from their
		feet answers nothing at all there, so the drone parked at their ankles
		with a whole dirty beach a few studs away and did nothing until they
		walked back onto it. Same defect deploy had, and the same fix: pull an
		off-field origin to the nearest sand.

		THE MAXIMUM IS THE LEASH, AND IT WAS DEPLOY_REACH -- WHICH WAS A BUG AT
		TWO OF THE FOUR KENNELS. Apron to its own field, measured: beach 29.6,
		cove 13.8, DUNES 82.6, ASHFALL 177.7. Against a reach of 60 that meant a
		drone deployed at the dunes drove out of the building, found no sand
		within reach of itself OR of the owner standing beside it, and orbited
		them at DockRadius for ever -- the machine you had just paid for, doing
		nothing, in front of its own house. Ashfall was the same and worse.

		DEPLOY_REACH IS A QUESTION ABOUT A PLAYER: is this person near enough to
		sand that putting a drone down is worth doing. How far a drone will DRIVE
		to reach work is a different question, and the leash already answers it --
		`inReach` is the rule for which sand this drone may stand on, so asking it
		here means the search cannot offer a target the caller is about to refuse.
		One rule rather than two numbers that have to be kept in step.

		(Config.nearestField never answers nil; its own header says every caller
		has to impose a maximum of its own. This is ours.)
	]]
	local function onSand(p: Vector3): Vector3?
		if Config.fieldAt(p) then
			return p
		end
		local _, spot = Config.nearestField(p, EDGE_INSET)
		return (spot and inReach(spot)) and spot or nil
	end

	local from = onSand(d.pos)
	if from then
		--[[
			THE LANE PROBE, AND IT IS FIRST FOR A REASON.

			Everything below this block answers "what is NEAREST", which is the
			right question for finding work and the wrong one for driving to it:
			after a pass the nearest unraked cell is four or five studs off the
			drone's SHOULDER, never in front of it, so a drone steered by it turns
			ninety degrees every few studs and never goes anywhere. That is what
			made the movement read as glitchy -- 78 of 171 moving ticks were
			turning more than ten degrees.

			So before asking what is nearest, ask how far the CURRENT heading can
			keep paying: sample forward every LaneStep studs and keep the furthest
			sample that still has unraked sand under it. A hit at 60 studs is a
			sixty-stud straight pass that sweeps everything on the way.

			FURTHEST, not first-gap. A clean patch part way along is driven
			straight through: the band is 8.4 studs wide, the trip past costs
			nothing, and stopping at every gap would reintroduce the jinking one
			step removed.

			`dirtyNear(..., 1)` is a one-ring search, so a sample counts as long as
			the cell it lands in OR one of its neighbours is unraked -- which keeps
			a lane alive across the odd already-swept column instead of ending it.
		]]
		local lane
		for k = SandbotConfig.LaneStep, SandbotConfig.LaneLength, SandbotConfig.LaneStep do
			local at = onSand(d.pos + nose * k)
			if at then
				local hit = Bridge.dirtyNear(player, at, 1)
				if hit and inReach(hit) then
					lane = hit
				end
			end
		end
		-- Short lanes are the jinking wearing a different name: below MinLane the
		-- drone is better off taking one proper turn than a dozen small ones.
		if lane and (Vector3.new(lane.X, 0, lane.Z)
			- Vector3.new(d.pos.X, 0, d.pos.Z)).Magnitude >= SandbotConfig.MinLane then
			return lane, "hunting"
		end

		--[[
			LITTER IS WORTH A DETOUR, and it is checked only HERE -- at the point
			where the drone needs a new target anyway -- rather than every time it
			is asked. A bottle that interrupts a lane is a bottle that turns the
			drone round mid-pass, and the band collects whatever it drives over in
			any case (CTBBridge.rakeCell), so hunting one is a bonus rather than
			the only way it gets picked up.
		]]
		local _, litterAt = Bridge.trashNear(from, SandbotConfig.LitterRange)
		if litterAt and inReach(litterAt) then
			return litterAt, "litter"
		end

		local sandAt = Bridge.dirtyNear(player, from, SandbotConfig.SandRings)
		if sandAt and inReach(sandAt) then
			return sandAt, "hunting"
		end
	end

	--[[
		NOTHING IN RANGE OF THE DRONE, BUT MAYBE SOMETHING IN RANGE OF THE OWNER.

		This is the case where the drone has finished its own corner and the work
		left is back the other way. Without it the drone parks the moment its
		immediate surroundings are clean and never moves again, which on a big
		field is most of the session.

		Asking from the OWNER's position rather than the drone's is what turns
		"nothing near me" into "go and stand where the work is": it is the same
		search, re-centred.
	]]
	local anchor = onSand(home)
	if anchor then
		local farSand = Bridge.dirtyNear(player, anchor, SandbotConfig.SandRings)
		if farSand and inReach(farSand) then
			return farSand, "hunting"
		end
	end

	return nil, "docked"
end

----------------------------------------------------------------
-- ONE STEP TOWARDS A POINT
----------------------------------------------------------------
--[[
	THE STEERING, LIFTED OUT OF step() SO THE KENNEL CAN USE IT TOO.

	It was inline until the drone had to drive itself out of a building and back
	into one. The choice then was to have those journeys share this, or to grow a
	second simpler steering loop beside it -- and two would have been two turning
	FEELS: the one the drone has out on the sand, and a worse one at the single
	moment a player is standing four studs away watching it manoeuvre.

	`floor` OVERRIDES the height rideY would answer with. The dock states pass the
	charging plate's, because inside a kennel there is no field to read and the
	off-field fallback is the owner's feet. See SandbotConfig.DockBlend.

	It answers with the distance that was left BEFORE the step, which is what
	every caller's arrival test wants: a drone that arrives on this frame has
	already covered the ground on it.
]]
local function drive(d: Drone, goal: Vector3, dt: number, hrp: BasePart?, floor: number?): number
	local toGoal = Vector3.new(goal.X - d.pos.X, 0, goal.Z - d.pos.Z)
	local dist = toGoal.Magnitude

	if dist > 1e-3 then
		local want = math.atan2(toGoal.X, toGoal.Z)
		--[[
			TURN THE SHORT WAY ROUND.

			Yaw is an angle and angles wrap: lerping from 3.0 to -3.0 without this
			takes the drone the long way through zero -- a full spin on the spot to
			turn six degrees, which is the single most obvious "this is a script"
			tell there is. Wrapping the DIFFERENCE into (-pi, pi] and stepping along
			it is the fix.
		]]
		local diff = (want - d.yaw + math.pi) % (math.pi * 2) - math.pi
		--[[
			TIGHTER STEERING WHEN IT IS ALMOST THERE.

			TurnRate was slowed to 3.4 rad/s so corners read as arcs rather than
			snaps, and at 22 studs/s that is a turning circle of about six studs.
			A target inside that circle cannot be reached by driving at it: the
			drone orbits it, which looks far worse than the snap did.

			So the rate lifts as the target gets close. It is the same trick a
			vehicle uses in reverse -- AtvServer's `bite` gives a machine MORE
			steering authority the faster it is going -- and it costs nothing,
			because a tight turn at arrival is over in a fraction of a second.
		]]
		local rate = SandbotConfig.TurnRate * (dist < 12 and 2.2 or 1)
		local turn = math.clamp(diff, -rate * dt, rate * dt)
		d.yaw += turn

		--[[
			IT DRIVES ALONG ITS NOSE, NOT STRAIGHT AT THE TARGET.

			Moving along the goal vector while the body turns separately is what
			makes a driven prop crab sideways -- it arrives facing the wrong way and
			the brushes sweep a band the drone never drove down. Going where it
			points means a tight corner costs it a small arc, which is what a thing
			with wheels does.

			THE NOSE IS +Z. Every model in this game is built that way (see
			AtvServer's long note) and Roblox's LookVector is the NEGATIVE Z axis,
			so driving on LookVector would send the drone out through its own back
			end with the brushes trailing behind it.
		]]
		local nose = Vector3.new(math.sin(d.yaw), 0, math.cos(d.yaw))
		-- Slower through a hard turn, so it does not describe a wide arc round a
		-- target three studs to its side and have to come back for it.
		local bite = math.clamp(1 - math.abs(diff) / math.pi * 1.4, SandbotConfig.TurnBrake, 1)
		local travel = math.min(SandbotConfig.Speed * bite * dt, dist)
		local at = d.pos + nose * travel
		d.pos = Vector3.new(at.X, floor or rideY(at, hrp), at.Z)
	end

	return dist
end

----------------------------------------------------------------
-- IN AND OUT OF THE KENNEL
----------------------------------------------------------------
--[[
	THE FOUR STATES THAT BELONG TO THE BUILDING, AND WHY THEY BYPASS EVERYTHING.

	Between the charging plate and the apron the drone is not working a field, not
	on a lead and not waiting on anybody -- it is driving fifteen studs down a
	corridor with one destination. So none of step()'s machinery applies to it,
	and all of it would get in the way:

		NO LEASH      its owner may walk off while it is still coming home, and it
		              has to finish coming home rather than turn round and follow
		NO SNAP_HOME  they may take the ferry mid-recall; it still parks
		NO TARGETS    there is exactly one place it is going
		NO CHARACTER  it drives itself in with its owner dead or respawning

	FOUR STATES AND NOT TWO, BECAUSE THE KENNEL HAS THREE WALLS. A drone driving
	straight at the plate from wherever it happens to be standing enters through a
	side wall -- so `returning` takes it to the APRON POINT square in front of the
	mouth, and `docking` turns in from there. That is the approach a car makes of
	a garage, and it is not optional here: the mouth is 8.4 studs between the
	posts and the machine is 8.4 across its brushes.

	`parked` is the beat at the end -- sitting on the plate, turning to face out,
	before the display model takes over. See SandbotConfig.ParkHold.
]]
local DOCK_STATES = {
	leaving = true, returning = true, docking = true, parked = true,
}

-- Close enough to the plate to call it parked, and far tighter than Arrive's
-- 3.0: that one is a target on open sand, this one is a machine settling onto a
-- 6.3 stud dish in the pose a display model is about to take over from it.
local BERTH_ARRIVE = 0.8

--[[
	HOW SQUARE THE APPROACH HAS TO BE BEFORE IT TURNS IN.

	Reaching the apron point is not enough on its own: the drone arrives on
	whatever heading it was travelling, and a right-angle turn taken from there is
	a six-stud arc (TurnRate 3.4 at Speed 22) into a mouth 8.4 studs wide -- which
	is exactly as wide as the machine is across its brushes. MEASURED before this
	existed: a drone coming home along the shore entered 2.0 studs off the axis,
	which puts a brush tip 6.2 studs out through a post.

	SO IT PIVOTS ON ITS OWN DOORSTEP FIRST. The first version instead kept driving
	at the apron point until the heading came good, on the argument that it would
	overshoot and come back round -- and that was WRONG, in a way worth writing
	down: a drone standing ON its goal has a goal distance of zero, so drive()'s
	`dist > 1e-3` gate skips the whole body and it neither turns nor moves. It sat
	perfectly still facing the wrong way for 1.8 seconds, which is what a broken
	feature looks like. Turning in place converges by construction -- the clamped
	step shrinks the difference every frame and nothing pushes back.

	EIGHT DEGREES, because a pivot is cheap (half a turn is 0.92s) and the last
	thirteen studs are then dead straight. It does not need slack: drive() keeps
	steering all the way in.
]]
local DOCK_ALIGN = math.rad(8)

local function dockStep(player: Player, d: Drone, dt: number, now: number)
	local berth, mouth = d.berth, d.mouth
	if not (berth and mouth) then
		-- Nothing to drive to. Only reachable if a drone reached one of these
		-- states without a berth, and a machine frozen mid-journey for the rest of
		-- the session is the one outcome worse than a sudden despawn.
		despawn(player)
		return
	end

	local plate = berth.Position
	-- The berth's +Z, which is the way out of the building. See spawn().
	local facing = -berth.LookVector

	if d.state == "parked" then
		--[[
			ON THE PLATE, TURNING TO FACE OUT.

			It arrived NOSE FIRST, looking at the back wall, and every display
			machine in the game faces its mouth -- so without a beat to turn round
			in, the handover at the end of this window is a visible 180 degree flip.

			The position is written rather than driven: it is already there, and
			handing drive() a zero-length goal only re-runs the arithmetic.
		]]
		local want = math.atan2(facing.X, facing.Z)
		local diff = (want - d.yaw + math.pi) % (math.pi * 2) - math.pi
		d.yaw += math.clamp(diff, -SandbotConfig.TurnRate * dt, SandbotConfig.TurnRate * dt)
		d.pos = plate
		d.hull.CFrame = CFrame.new(d.pos) * CFrame.Angles(0, d.yaw, 0)
		paint(d)
		if now >= d.parkAt then
			despawn(player)
		end
		return
	end

	--[[
		THE RIDE HEIGHT, AND IT IS THE ONE THING THAT CANNOT COME FROM rideY.

		A kennel stands on a plaza, not on a field, so Config.surfaceY has no
		answer here and rideY falls back to THE OWNER'S FEET -- which is the wrong
		ground the moment they walk off the apron, and no ground at all while they
		are respawning. Near the plate it rides the plate; DockBlend studs out it
		is riding whatever rideY says; in between it is a straight lerp of the two.
		No raycast, and nothing that can be surprised.

		Measured off d.pos BEFORE the step rather than after it. One frame at Speed
		is under 0.4 studs, which is a fortieth of the blend.
	]]
	local away = (Vector3.new(d.pos.X, 0, d.pos.Z) - Vector3.new(plate.X, 0, plate.Z)).Magnitude
	local t = math.clamp(away / SandbotConfig.DockBlend, 0, 1)
	local floor = plate.Y + (rideY(d.pos, rootOf(player)) - plate.Y) * t

	local goal = (d.state == "docking") and plate or mouth
	local dist = drive(d, goal, dt, nil, floor)

	if d.state == "docking" then
		if dist <= BERTH_ARRIVE then
			-- SNAPPED, not eased. The display is about to be made visible in exactly
			-- this pose, and "nearly" is the one thing a handover cannot be.
			d.pos = plate
			d.state = "parked"
			d.parkAt = now + SandbotConfig.ParkHold
		end
	elseif d.state == "returning" then
		if dist <= SandbotConfig.Arrive then
			-- On the doorstep. Square up, then go in -- see DOCK_ALIGN. The angle is
			-- taken against the PLATE rather than against the apron point it is
			-- standing on, because the plate is where it is about to drive.
			local toPlate = Vector3.new(plate.X - d.pos.X, 0, plate.Z - d.pos.Z)
			local diff = 0
			if toPlate.Magnitude > 1e-3 then
				diff = (math.atan2(toPlate.X, toPlate.Z) - d.yaw + math.pi)
					% (math.pi * 2) - math.pi
			end
			if math.abs(diff) <= DOCK_ALIGN then
				d.state = "docking"
			else
				d.yaw += math.clamp(diff,
					-SandbotConfig.TurnRate * dt, SandbotConfig.TurnRate * dt)
			end
		end
	elseif dist <= SandbotConfig.Arrive then
		--[[
			OUT -- `docked` RATHER THAN `hunting`, AND THE BERTH IS KEPT.

			docked is where the ordinary machinery starts from: on the next frame it
			takes a target of its own or parks beside its owner, which is one branch
			deciding that rather than a guess made from in here.

			The berth stays on the record for the whole deployment, because it is what
			a recall drives back to. Reading it off the dock again at that point would
			be reading a model Island4 may have destroyed and rebuilt in the meantime.
		]]
		d.state = "docked"
		d.target = nil
		d.nextTarget = 0
	end

	d.hull.CFrame = CFrame.new(d.pos) * CFrame.Angles(0, d.yaw, 0)
	paint(d)
end

----------------------------------------------------------------
-- THE TICK
----------------------------------------------------------------
local function step(player: Player, d: Drone, dt: number, now: number)
	--[[
		THE KENNEL'S OWN JOURNEYS COME FIRST, AND ANSWER TO NONE OF WHAT FOLLOWS.

		Driving out of the building, or back into it, is a fixed fifteen studs with
		exactly one destination. See DOCK_STATES for why every guard below it --
		the leash, the snap home, the target search, even needing a character --
		would be in the way rather than any help.
	]]
	if DOCK_STATES[d.state] then
		dockStep(player, d, dt, now)
		return
	end

	local hrp = rootOf(player)

	--[[
		NO CHARACTER: THE DRONE WAITS WHERE IT IS. It is not recalled.

		Respawning is a few seconds and the drone is a thing the player paid for;
		packing it away on every death would mean re-deploying it constantly, and
		a feature that undoes itself is worse than one that pauses. `last` is
		cleared so the first tick after they come back sweeps from where the drone
		stands rather than carving a stripe out of the gap.
	]]
	if not hrp then
		d.state = "docked"
		-- Re-seeded to where it stands. It does not move on this branch, so this is
		-- belt and braces -- but a `last` left over from before a respawn is
		-- exactly the kind of stale sample that carves a stripe when the loop picks
		-- back up, and re-seeding costs one Vector3.
		d.last = Vector3.new(d.pos.X, 0, d.pos.Z)
		paint(d)
		return
	end

	local home = hrp.Position
	local gap = (Vector3.new(home.X, 0, home.Z) - Vector3.new(d.pos.X, 0, d.pos.Z)).Magnitude

	--[[
		THE OWNER HAS GONE SOMEWHERE THE DRONE CANNOT WORK: IT PACKS ITSELF AWAY.

		WITHOUT THIS IT RIDES THE FERRY WITH YOU, and TWO separate rules were doing
		the dragging, one after the other, which is why fixing either alone fixed one
		island and not the next:

		  the LEASH   past 180 studs it goes `homing`, and a homing drone steers at
		              its owner (section 2 orbits `home`) -- so it walks off the sand
		              and out to sea after the boat at 22 studs a second
		  SNAP_HOME   past 400 it stops driving and teleports beside them outright,
		              which is how it used to ARRIVE on the far island

		TWO QUESTIONS, BECAUSE ONE DOES NOT COVER IT.

		1. IS THIS STILL MY ISLAND? `Config.zoneAt` is the island a point is anywhere
		   NEAR -- shops, docks, car pads and all. Measured, every place a player
		   stands in ordinary play is inside one: all four kennels, all four ferry
		   berths, every wash bay, sell pad, market and spawn. The only NONE answers
		   in the place are the duel arenas (11310, 12000) and the idle shore
		   (8000, 7964), both off-map. This is what catches a MENU teleport to another
		   island, where the drone would otherwise snap to you and carry on as if
		   nothing had happened.

		2. IS THERE ANY SAND WITHIN THE LEASH OF THEM? The same question `inReach`
		   asks of every target pickTarget takes. A zone is drawn round the ISLAND --
		   460 studs, 980 on Ashfall -- so it reaches a long way out over the water,
		   and question 1 alone leaves the whole of that reach for the chase to happen
		   in. Measured leaving Ashfall: the ferry berth is ALREADY 316 studs off that
		   island's sand, and the zone does not end until 980, so the drone spent
		   hundreds of studs following the boat while still nominally at home.

		   The furthest any real landmark sits from its own island's sand is 177.7
		   studs (the Ashfall kennel), inside the leash -- so this never fires on land.
		   What fails it is open water.

		A CHAMBER IS A ROOM, NOT ANOTHER ISLAND. The Vault, the Inner Shrine and the
		Magma Chamber are their own zones at (3000, 0/±1500) and question 1 would pack
		the drone away the moment you stepped through a door -- and there is NO KENNEL
		inside any of them, so you could not get it back until you came out again.
		They carry `chamber = true` in Config.ISLANDS and are exempted for it. They
		still have to pass question 2, which they do trivially: you are standing on
		their field. `here` may be nil (mid-sea, a duel, the idle shore) and nil is not
		a chamber, so that case still packs away -- which is why the test reads round
		this way.

		⚠ A LONG TELEPORT IS REPLICATED AS A SWEEP THROUGH EVERYTHING IN BETWEEN, AND
		THAT IS WHY THERE IS A TIMER HERE. Measured going from the beach to the Magma
		Chamber: 0.2s after the jump the owner's HumanoidRootPart read (403, -297) --
		exactly 8.9% along the straight line between them, 326 studs from any sand and
		in no zone at all. One frame of that is indistinguishable from being on a boat,
		and it packed the drone away every time before it had arrived anywhere. So the
		answer has to HOLD for LeaveGrace before it counts. A crossing holds it for
		ever; a teleport's transit was over inside 0.4s.

		PACKED AWAY, NOT DRIVEN HOME. Recall's whole argument for the journey is that
		the owner is standing at the building watching it come in; here they have their
		back to it on a boat, so the drive buys nothing and costs a real bug -- a drone
		still `returning` when they land answers deploy with "already out", and the
		press does nothing. The kennel restocks either way, which is the part they see.
	]]
	local away = false
	if d.zone then
		local here = Config.zoneAt(home)
		away = here ~= d.zone and not (here and here.chamber)
	end
	-- Guarded by the leash so the field sweep is only paid for by a drone already
	-- out of range of its owner. It is free on every ordinary tick.
	if not away and gap > SandbotConfig.Leash then
		local _, _, sand = Config.nearestField(home, EDGE_INSET)
		away = (sand == nil) or (sand > SandbotConfig.Leash)
	end

	if away then
		d.awayAt = d.awayAt or now
		if now - d.awayAt >= SandbotConfig.LeaveGrace then
			tell(player, "Sandbot went home — deploy it again at any Sandbot Home.")
			despawn(player, true)
			return
		end
	else
		d.awayAt = nil
	end

	-- Rebirthed, pulled somewhere by a menu, or a car across Ashfall, whose island
	-- is 640 studs of field alone. The drone can never open a 400-stud gap itself --
	-- the leash is 180 -- so getting here always means the OWNER moved, and driving
	-- after them would be a minute and a half of swimming.
	--
	-- NOT WHILE `away` IS PENDING. Those are the frames of a teleport still in
	-- flight, and snapping into one plants the drone on open water for as long as
	-- the grace lasts -- the very thing the block above exists to stop.
	if not away and gap > SNAP_HOME then
		local at = home + Vector3.new(SandbotConfig.DockRadius, 0, 0)
		d.pos = Vector3.new(at.X, rideY(at, hrp), at.Z)
		d.last = Vector3.new(d.pos.X, 0, d.pos.Z)
		d.target = nil
		d.state = "docked"
		d.hull.CFrame = CFrame.new(d.pos) * CFrame.Angles(0, d.yaw, 0)
		paint(d)
		return
	end

	----------------------------------------------------------------
	-- 1. WHAT IS IT DOING
	----------------------------------------------------------------
	--[[
		(a) LEAVING "full". THE BAG IS THE ONLY THING THAT ENDS IT, AND IT IS
		ASKED HERE RATHER THAN INFERRED FROM THE SWEEP.

			The sweep does answer it -- any verdict other than "full" means there
			was room -- and reading it from there DEADLOCKS. Found by playing it:

			  1. bag fills, the drone goes "full" and stops taking targets
			  2. with no target it parks beside its owner
			  3. its owner has walked off the field to the sell counter, because
			     that is what you do when your bag is full
			  4. off a field the sweep answers "nofield" for ever, so the drone
			     never learns it was emptied and never works again

			The first version also cleared `full` on "nofield", which swapped the
			deadlock for a lie: the key went back to STANDING BY while the bag was
			still over capacity.

		hasRoom is the same call droneSweep makes on the other side of the
		bridge, so this cannot disagree with it.

		SO: THE SWEEP IS THE ONLY THING THAT ENTERS `full` AND THIS IS THE ONLY
		THING THAT LEAVES IT.

		It has a clock of its OWN rather than sharing the retarget watchdog, which
		is now 2.5s: that would be two and a half seconds of a drone sitting there
		saying BAG FULL after the player had already sold. One weight lookup at
		1.3 Hz per drone is nothing.
	]]
	if d.state == "full" then
		d.target = nil
		if now >= d.nextRoom then
			d.nextRoom = now + SandbotConfig.RoomCheckEvery
			if Bridge.hasRoom(player) then
				d.state = "docked"
			end
		end
	end

	-- (b) THE LEASH.
	if d.state ~= "full" then
		if gap > SandbotConfig.Leash then
			d.target = nil
			d.state = "homing"
		elseif d.state == "homing" then
			-- Back inside the lead: drop `homing` so (c) goes looking for work on
			-- this very frame. Leaving it set until the watchdog lapsed meant up to
			-- RetargetEvery seconds of a drone orbiting its owner with a dirty
			-- beach under it.
			d.state = "docked"
		end
	end

	--[[
		(c) TAKING A TARGET -- AND THEN COMMITTING TO IT. This is the other half
		of the smoothness fix.

		This block used to run every RetargetEvery seconds unconditionally, at 0.6s
		-- every eighteen studs -- and overwrite whatever the drone was driving to.
		Combined with "nearest dirty cell", which after a pass is off the shoulder
		and never ahead, that handed it a fresh near-right-angle turn several times
		a second, for ever. It did not drive anywhere; it vibrated up the beach.

		Now `nextTarget` is the ONLY gate, and exactly two things open it:

		  ARRIVAL      sets it to 0, so the next frame picks the next lane. This
		               is the ordinary path and it costs no delay.
		  THE WATCHDOG RetargetEvery, for a target that can never be reached --
		               another player raked it, or the tide turned the field over
		               underneath it.

		It is deliberately NOT `d.target == nil or ...`: a search that comes back
		empty (a finished field) leaves the target nil, and that condition would
		then re-run a full grid search every single frame for as long as the drone
		stood parked. Setting the timer on every attempt -- found or not -- is what
		makes a fruitless search back off.
	]]
	if d.state ~= "full" and gap <= SandbotConfig.Leash and now >= d.nextTarget then
		local spot, kind = pickTarget(player, d, home)
		d.target = spot
		d.state = kind
		d.nextTarget = now + SandbotConfig.RetargetEvery
	end

	----------------------------------------------------------------
	-- 2. WHERE IS IT HEADED
	----------------------------------------------------------------
	local goal
	if d.target and d.state ~= "full" and d.state ~= "homing" then
		goal = d.target
	else
		--[[
			PARKED: A SLOW ORBIT, NOT A STOP.

			A drone frozen dead still beside its owner reads as broken -- it is the
			same silhouette a despawned one leaves behind. Circling says "waiting",
			which is what it is doing, and it costs one cosine.
		]]
		d.orbit += SandbotConfig.DockSpin * dt
		goal = home + Vector3.new(
			math.cos(d.orbit) * SandbotConfig.DockRadius,
			0,
			math.sin(d.orbit) * SandbotConfig.DockRadius)
	end

	----------------------------------------------------------------
	-- 3. STEER AND MOVE
	----------------------------------------------------------------
	local dist = drive(d, goal, dt, hrp)

	-- Arrived. Clearing the target is what asks for a new one on the next frame
	-- (see the commitment block above); the watchdog timer is reset with it so a
	-- long lane just completed does not leave the next one on a short fuse.
	if d.target and dist <= SandbotConfig.Arrive then
		d.target = nil
		d.nextTarget = 0
	end

	d.hull.CFrame = CFrame.new(d.pos) * CFrame.Angles(0, d.yaw, 0)

	paint(d)
end

----------------------------------------------------------------
-- THE RAKE
----------------------------------------------------------------
--[[
	RAKE THE BAND THE DRONE HAS DRIVEN SINCE THE LAST TIME THIS RAN.

	SPLIT OUT OF step(), WHICH RUNS EVERY FRAME NOW. They used to be one
	function on one 20 Hz clock, and that is what made the drone look like a
	prop being teleported: the hull's CFrame changed twenty times a second and
	sat perfectly still in between -- measured on the server, no movement at all
	on 72% of frames.

	Separating them costs the rake nothing. The band has always been built from
	the LAST RAKE POINT to the current one, so where the drone was in between was
	never part of the arithmetic -- it just gets there in smaller steps now.

	`since` is the time since the previous RAKE, not the frame delta. The speed
	gate below measures a distance against the interval it was travelled in, and
	handing it a frame delta would read every rake as twenty times too fast and
	refuse to rake anything at all.
]]
local function rake(player: Player, d: Drone, since: number)
	local cur = Vector3.new(d.pos.X, 0, d.pos.Z)
	local moved = (cur - d.last).Magnitude
	local wasLast = d.last
	d.last = cur

	--[[
		A STEP TOO LONG TO BE DRIVING RAKES NOTHING, and `last` is updated above
		regardless so the next tick sweeps normally from where the drone actually
		is. Same shape as CTB_Server's MAX_SWEEP_SPEED and the same reasoning: the
		band is built from last -> now, so one oversized step carves a stripe
		across everything in between. A server hitch is the ordinary cause.
	]]
	if since > 1e-3 and moved / since > SandbotConfig.MaxSweepSpeed then
		return
	end

	local nose = Vector3.new(math.sin(d.yaw), 0, math.cos(d.yaw))
	local verdict, cleared = Bridge.sweepDrone(player, cur, wasLast, nose,
		SandbotConfig.Sweep * 0.5,
		(SandbotConfig.SweepDepth + moved) * 0.5)

	d.raked += (type(cleared) == "number" and cleared or 0)

	--[[
		NOT WHILE IT IS IN THE KENNEL'S HANDS. The apron of the cove's dock is 13.8
		studs off that field, which is inside the drive out -- so a drone leaving or
		RETURNING with a full bag can clip the sand and be told so. Taking the state
		here would strand it: `full` is not a DOCK_STATE, so a recall pressed on a
		full bag would stop halfway home and go back to orbiting its owner.

		The sweep above still runs and still pays. It is only the state that the
		journey owns.
	]]
	if verdict == "full" and not DOCK_STATES[d.state] then
		--[[
			BAG FULL. IT COMES BACK AND WAITS, rather than carrying on.

			Carrying on is the worse of the two and CTB_Server records why: raking
			with no room clears the sand and reburies (or refuses) what was under
			it, and a raked column is raked for good until the tide. The drone would
			be spending the field's finds on nobody's behalf.

			The player is told ONCE per episode -- not per tick -- and the state
			clears itself below the moment the sweep stops saying full, which is as
			soon as they sell.
		]]
		if d.state ~= "full" then
			d.state = "full"
			d.target = nil
			tell(player, "Sandbot is waiting \u{2014} your bag is full.", "warn")
		end
	end
end

----------------------------------------------------------------
-- API
----------------------------------------------------------------
function SandbotService.deploy(player: Player, dock: Model?): boolean
	if drones[player] then
		return true
	end
	if not ownsSandbot(player, mayAskNow(player)) then
		--[[
			THE STOREFRONT, AND IT IS THE WHOLE OF THIS BRANCH.

			The dock is the only door into this function, so somebody reaching here has
			walked up to a sandbot sitting in a lit kennel and pressed E on it -- which
			is the best moment this game is ever going to get to offer them the pass.
			So the refusal IS the offer, and there is no toast in front of it competing
			with the dialog.

			THE ID AND NOTHING ELSE. PromptGamePassPurchase is a CLIENT call, and
			the price and the on-sale flag live in the replicated info folder where
			SandbotClient can read them and this file would be guessing -- so the
			client owns the wording as well as the dialog. Nothing is granted at
			either end: GamePassService hears the outcome on
			PromptGamePassPurchaseFinished and goes and asks Roblox.

			WHATEVER ID THE ROW HOLDS IS SENT, INCLUDING 0. The Sandbot's is live
			now (1955383241), but a pass nobody has created yet carries 0 and this
			branch must not special-case it: the client's on-sale test is false for
			such an id and the player is told it is not on sale yet, which is the
			honest answer and the same one an off-sale pass gets.
		]]
		local entry = PassConfig.get(SandbotConfig.PassKey)
		Net.get("SandbotOffer"):FireClient(player, (entry and entry.id) or 0)
		return false
	end
	return spawn(player, dock)
end

--[[
	IT DRIVES HOME. THIS FUNCTION NO LONGER MAKES ANYTHING DISAPPEAR.

	A recall used to be a Destroy: the machine the player had been watching work
	blinked out of the world from wherever it stood. Now it turns round, drives
	back to the apron of the kennel it came out of, turns in, settles on the
	charging plate and hands over to the display model -- which is the deploy in
	reverse, and the reason a dock has a berth at all.

	THE ONLY DOOR INTO THIS IS THE DOCK'S OWN PROMPT, so the owner is standing at
	the building watching it come in -- and the drone is never further off than the
	leash (180 studs), which is eight seconds at Speed.

	IDEMPOTENT ONCE IT IS ON ITS WAY. Pressing E again mid-return changes nothing:
	it is already coming home, and there is nothing a second press could mean that
	the first one did not. Pressing it mid-DEPARTURE does turn it round, which is
	the one case where the player has changed their mind about something that has
	not happened yet.

	NO BERTH, NO JOURNEY. A drone deployed from the command bar, or one whose
	kennel was destroyed under it, is packed away where it stands -- the old
	behaviour, and the right fallback, because there is nowhere to drive to.
]]
function SandbotService.recall(player: Player, dock: Model?)
	local d = drones[player]
	if not d then
		return
	end
	if d.state == "returning" or d.state == "docking" or d.state == "parked" then
		return
	end

	--[[
		IT COMES INTO THE KENNEL YOU ARE STANDING AT, NOT THE ONE IT LEFT.

		Usually the same building, and it matters on the day it is not: the drone
		leashes to its owner and SNAPS to them over any distance (SNAP_HOME), so
		somebody who deployed at the beach and took the ferry to the cove has their
		machine standing beside them at the cove. Sending it back to the berth it
		remembered would be a 1,596 stud drive across open sea at 22 studs a second --
		over a minute of a drone swimming home to a building nobody is watching.

		REWRITING THE HOME ATTRIBUTE WITH IT is what keeps the handover honest: the
		kennel it is about to park in has to stand empty for its owner, and the one it
		left has to be stocked again. SandbotClient reads that one name.

		No dock (the command bar) or one with no readable berth: it keeps whatever it
		left with, which is the best answer available.
	]]
	local berth, mouth = berthFor(dock)
	if berth and dock then
		d.berth, d.mouth = berth, mouth
		player:SetAttribute(SandbotConfig.HomeAttribute, dock.Name)
	end

	if not (d.berth and d.mouth) then
		despawn(player)
		return
	end
	d.target = nil
	d.state = "returning"
	paint(d)
end

-- Useful from the command bar, and the one thing a caller outside this file
-- might legitimately want to know.
function SandbotService.isOut(player: Player): boolean
	return drones[player] ~= nil
end

----------------------------------------------------------------
-- BOOT
----------------------------------------------------------------
local function onPlayerAdded(player: Player)
	player:SetAttribute(SandbotConfig.OutAttribute, false)

	--[[
		THE STUDIO-ONLY UNLOCK, WRITTEN ONTO THE PLAYER.

		SandbotConfig.owns already ORs devUnlocked() on both sides, so the dock
		would deploy without this. Writing the attribute as well is what makes the
		SHOP agree with it -- MenuHud paints its rows off the attribute and nothing
		else -- so a Studio test sees one consistent story instead of a dock that
		works next to a shop row that says the pass is unowned.

		IT IS OFF BY DEFAULT NOW. SandbotConfig.DevUnlock is false, so this branch
		does not run and a Studio session sees exactly what a live one sees: a dock
		that offers the pass. Turn it back on there to drive one.

		devUnlocked() is `DevUnlock and RunService:IsStudio()`, checked here rather
		than trusted from the constant, so publishing with the flag left on cannot
		hand the drone to a live player. GamePassService deliberately does not
		write `false` over an unmade pass, which is what lets this stick.
	]]
	if SandbotConfig.devUnlocked() then
		local entry = PassConfig.get(SandbotConfig.PassKey)
		if entry then
			player:SetAttribute(entry.attribute, true)
		end
	end
end

--[[
	ONE PROMPT PER DOCK, CONNECTED ON THE SERVER.

	It is a TOGGLE and it says so: press it with the drone stowed and it goes
	out, press it with the drone out and it comes back. There is no second
	control anywhere, which is the whole reason the drone can be recalled from a
	fixed point in the world rather than from a key -- it leashes to its owner
	and snaps home to them from any distance, so walking to the dock brings it
	with you.

	THE TEXT SET HERE IS THE FALLBACK, NOT WHAT PEOPLE READ.

	A ProximityPrompt is ONE instance shown to every player in range, so on the
	face of it it cannot say DEPLOY to one person and a price to another --
	which is the arrangement AtvServer settles for with its static "Car Spawner"
	over a per-player panel.

	It does not have to. A CLIENT's write to a property of a server-owned
	instance applies on that machine and replicates NOWHERE -- the same fact
	SandbotClient's brush spin is built on -- so each player repaints these two
	strings for themselves, and the storefront, DEPLOY and RECALL all land on the
	one prompt. See SandbotClient.paintPrompts.

	So what is written here is what somebody whose client never got that far
	would read, and it is deliberately NEUTRAL: it names the building and says
	what lives in it, which is true whoever is standing in front of it. Nothing
	depends on the repaint -- the press does the same thing either way.

	Guarded on an existing prompt, so a re-bind (the tag firing twice, a hand
	placed dock) cannot hang two prompts on one anchor.
]]
--[[
	WHAT A PRESS DOES.

	ONE decision, and `drones[player]` -- the SERVER's own record of whether that
	player's drone is out -- is the whole of it. Nothing the client says is
	consulted, because there is nothing it could usefully say: the prompt fires
	here.

	No precondition and no early-out. Every refusal lives inside deploy/recall and
	owns its own words, including the un-owned case, which owns the purchase
	dialog.

	`dock` is the building the press came from, and BOTH sides want it: deploy puts
	the drone on that kennel's plate, and recall brings it into that kennel rather
	than the one it happens to remember leaving.
]]
local function act(player: Player, dock: Model?)
	if drones[player] then
		SandbotService.recall(player, dock)
	else
		SandbotService.deploy(player, dock)
	end
end

local function bindDock(dock: Model)
	local anchor = dock:FindFirstChild("PromptAnchor") or dock:FindFirstChild("Floor")
	if not (anchor and anchor:IsA("BasePart")) then
		warn("[SandbotService] " .. dock.Name .. " has no PromptAnchor -- no prompt bound")
		return
	end
	if anchor:FindFirstChildWhichIsA("ProximityPrompt") then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "SandbotPrompt"
	prompt.ActionText = "Sandbot Home"
	prompt.ObjectText = "Beach cleaning drone"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	-- Off the dock, because only the dock knows how big it is. 12 covers its own
	-- footprint and the apron in front of it, and is well short of the car pad's
	-- own prompt -- measured on all four: the nearest the two anchors come is 18
	-- studs, at the dunes, against a plain pad's reach of 9.
	prompt.MaxActivationDistance = tonumber(dock:GetAttribute("PromptReach")) or 12
	-- The machine sits inside a kennel with a roof and three walls, so line of
	-- sight from the apron is not something to make the player hunt for.
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor

	-- Straight through to act(), carrying the building it was pressed on -- which
	-- is what a deploy is placed in. The engine rate-limits a prompt, so there is
	-- no debounce here to write.
	connections[#connections + 1] = prompt.Triggered:Connect(function(player: Player)
		act(player, dock)
	end)
end

function SandbotService.start()
	assert(RunService:IsServer(), "[SandbotService] server-only")
	if started then
		return
	end
	started = true

	local existing = workspace:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		folder = existing
		-- A drone left behind by a previous run of this service (a Studio session
		-- restarted without a rejoin) has no record in `drones` and would never be
		-- driven or cleaned up by anything.
		folder:ClearAllChildren()
	else
		local f = Instance.new("Folder")
		f.Name = FOLDER_NAME
		f.Parent = workspace
		folder = f
	end

	-- Built once, cloned per deploy. See SandbotBuilder.template.
	SandbotBuilder.template()

	connections[#connections + 1] = Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	connections[#connections + 1] = Players.PlayerRemoving:Connect(function(player)
		despawn(player, true)
		lastAsk[player] = nil
	end)

	--[[
		THE DOCKS, AND THE ONE PROMPT ON EACH.

		ensureAll stands a SANDBOT HOME at the end of every egg row in the game --
		one per CAR SPAWNER still, because that tag is what makes the timing work;
		see SandbotDockBuilder's header -- and then keeps watching the tag, because
		the pads are not all standing yet when
		this runs: Island4 destroys and rebuilds its whole island after ServerMain
		has finished, taking its car pad and its dock with it.

		bindDock is wired to the DOCK tag rather than to what ensureAll returns,
		for the same reason -- the dock that matters on Ashfall is the one that
		does not exist yet.
	]]
	local docks, pads = SandbotDockBuilder.ensureAll()

	for _, dock in CollectionService:GetTagged(SandbotDockBuilder.TAG) do
		bindDock(dock)
	end
	connections[#connections + 1] =
		CollectionService:GetInstanceAddedSignal(SandbotDockBuilder.TAG):Connect(bindDock)

	--[[
		ONE LOOP FOR EVERY DRONE, ON TWO CLOCKS.

		TWO CLOCKS, AND THAT SPLIT IS THE WHOLE SMOOTHNESS FIX.

		MOVEMENT runs every frame. It used to share the rake's 20 Hz clock, which
		meant the hull's CFrame changed twenty times a second and held perfectly
		still in between -- 72% of server frames had no movement at all, and the
		drone advanced in ~1.5 stud hops. That is what "static-like" was.

		THE RAKE stays throttled, because the sweep it drives is CTB_Server's and
		that is itself a throttled loop -- running it at 240 Hz on a fast machine
		would be ten sweeps per useful one. `since` carries the real interval so
		the band and its speed gate still measure over the time actually elapsed.

		The body is pcall'd PER DRONE, per phase. One player's drone throwing must
		not take the Heartbeat connection down and strand everybody else's
		mid-beach -- and a throw inside the rake must not stop the thing moving.
	]]
	local acc = 0
	connections[#connections + 1] = RunService.Heartbeat:Connect(function(dt)
		acc += dt
		local doRake = acc >= SandbotConfig.RakeTick
		local since = acc
		if doRake then
			acc = 0
		end

		local now = os.clock()
		for player, d in drones do
			if not (player.Parent and d.model.Parent and d.hull.Parent) then
				despawn(player, true)
			else
				local ok, err = pcall(step, player, d, dt, now)
				if not ok then
					warn("[SandbotService] step failed for " .. player.Name .. ": " .. tostring(err))
				end
				-- `drones[player]` again: step() can END a deployment (a drone that has
				-- finished parking is destroyed inside it), and raking with a destroyed
				-- drone lays one last band across the dock's own paving.
				if doRake and drones[player] then
					ok, err = pcall(rake, player, d, since)
					if not ok then
						warn("[SandbotService] rake failed for " .. player.Name .. ": " .. tostring(err))
					end
				end
			end
		end
	end)

	-- "beside %d egg row(s)" would be a lie on an island that has a car pad and no
	-- plaza: the dock falls back to the pad's flank there. `pads` is what the sweep
	-- actually counted, so that is what it reports.
	print(string.format("[SandbotService] online -- %d dock(s) over %d car spawner tag(s)",
		docks, pads))
end

return SandbotService
