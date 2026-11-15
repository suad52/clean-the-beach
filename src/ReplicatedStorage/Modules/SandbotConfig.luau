--[[
	SandbotConfig  --  ReplicatedStorage.Modules.SandbotConfig

	THE SANDBOT: a little autonomous sifter you send out to work a field
	on its own while you work another part of it.

	Every number the drone runs on, in one file, read by all five of the pieces
	that make it up -- SandbotBuilder (what it looks like), SandbotDockBuilder
	(where it lives), SandbotService (what it does), SandbotClient (the brush
	spin and the purchase dialog) and PassConfig (what it costs). It is
	replicated because one of those five is on the client.

	THERE IS NO HUD KEY. It is sent out and put away at the SANDBOT HOME -- the
	little charging kennel SandbotDockBuilder stands beside the car spawner on
	every island that has one. A walk-up ProximityPrompt, which the engine
	validates, so it PROVES the player was standing there where the remote it
	replaced proved nothing. A player who does not own the pass is offered it
	off the same press.

	WHY IT IS NOT A VEHICLE
	-----------------------
	It is the same JOB as a machine off the car pad -- rake a band of sand,
	collect what is standing on it -- and deliberately not the same THING. A
	machine is a seat you sit in and steer, so AtvServer is a physics rig with a
	VehicleSeat, a throttle and a set of wheel motors. Nobody rides this: it is
	anchored and its CFrame is written every tick, which is how AfkClient walks
	its puppet and how PetVisuals fly the pets. That removes every failure mode
	a free-rolling body has on a beach -- no cartwheeling into the sea, no
	wedging against a deckchair, no network ownership to hand anywhere.

	WHAT IT IS NOT ALLOWED TO BE
	---------------------------
	A SECOND ECONOMY. It rakes through the SAME sweep CTB_Server runs for the
	player's own sifter (CTBBridge.sweepFor, installed by CTB_Server), so a
	column it clears is worth exactly what a column the player clears is worth,
	a find it turns up goes into the same bag through the same tryAdd, and a
	full bag stops it for the same reason and with the same refusal. There is no
	payout in this file and no coins anywhere in SandbotService, on purpose: the
	moment a drone can pay differently from a player, the two have to be
	balanced against each other forever.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PassConfig = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("PassConfig"))

local SandbotConfig = {}

--------------------------------------------------------------------------
-- WHAT IT COSTS
--------------------------------------------------------------------------
-- The pass lives in PassConfig with every other one; this is only the KEY, so
-- that a file wanting to ask "do they own the sandbot" names it once. See
-- PassConfig.Passes.Sandbot for the id and the attribute.
SandbotConfig.PassKey = "Sandbot"

--[[
	THE STUDIO-ONLY UNLOCK, AND IT IS OFF.

	It was ON while the pass did not exist, so that the drone could be driven at
	all -- and the cost of that was that every Studio joiner already owned it, so
	the one thing most worth looking at (walking up to the dock WITHOUT the pass
	and being offered it) could not be seen.

	THE PASS IS LIVE NOW: 1955383241, R$ 99, on sale. So off is not a compromise
	any more -- it is simply what a player sees, and Studio now sees the same.

	AND IT IS NO LONGER NEEDED TO TEST THE DRONE. Measured with this flag off:
	Roblox answers UserOwnsGamePassAsync TRUE for the creator account, so the
	dock deploys and recalls through the real pass with no hook in the way.
	See the note in PassConfig.Passes.Sandbot -- it is the opposite of what the
	two car passes do, so ask Roblox rather than assuming either way.

	What is hard to see now is the STOREFRONT, not the drone. Turning this ON
	would not help with that; a second account is the honest way, and a
	client-side write of OwnsSandbot = false paints the un-owned prompt locally
	for a quick look. (GamePassService.setOwnedForTesting is still the other door
	into ownership, and walks the same route a real purchase does.)

	RunService:IsStudio() is checked at the point of use as well as here, so
	publishing with it left on cannot hand the drone to live players -- but it
	can and did hide the storefront from the people building it.
]]
SandbotConfig.DevUnlock = false

function SandbotConfig.devUnlocked(): boolean
	return SandbotConfig.DevUnlock == true and RunService:IsStudio()
end

--[[
	THE CLIENT'S COPY, and it is only ever good enough to decide what the key
	says -- exactly the rule PassConfig.owns is written under. SandbotService
	asks GamePassService, which asks Roblox.
]]
function SandbotConfig.owns(player: Player): boolean
	return PassConfig.owns(player, SandbotConfig.PassKey) or SandbotConfig.devUnlocked()
end

--------------------------------------------------------------------------
-- WHAT THE PLAYER CARRIES
--------------------------------------------------------------------------
--[[
	ONE ATTRIBUTE, WRITTEN BY THE SERVER.

	It says whether this player's drone is out, and nothing else -- no target, no
	progress, no count. Those change several times a second and belonged on a
	remote; the remote is gone with the HUD key it fed, and the drone's own lamp
	says what it is doing to everybody who can see it.

	THIS ONE IS WRITTEN TWICE PER DEPLOYMENT and it has exactly one reader:
	SandbotClient.paintPrompts, which is what makes the dock's prompt say DEPLOY
	SANDBOT before you press it and RECALL SANDBOT after. That is a per-player
	string on an instance everybody shares, and it works because a client's write
	to a server-owned property replicates nowhere.

	Do not confuse it with PassConfig.Passes.Sandbot.attribute ("OwnsSandbot"),
	which is what the shop paints its row off and what the same repaint uses to
	choose the storefront. This one is about the machine being OUT; that one is
	about the pass being OWNED.
]]
SandbotConfig.OutAttribute = "SandbotOut"

--[[
	WHICH KENNEL THIS PLAYER'S DRONE CAME OUT OF, by name, while it is out.

	Written beside the one above and cleared with it, and it exists for exactly one
	reader: SandbotClient hides the DISPLAY machine parked in THAT dock, for THIS
	player alone, so the drone driving out of it reads as the machine leaving
	rather than as a second one budding off it.

	A NAME RATHER THAN THE MODEL. An ObjectValue would replicate the instance
	itself, which is a reference that can dangle -- Island4 destroys and rebuilds
	its whole island, dock included -- where a name is just a string that stops
	matching anything, which is the failure that costs nothing.
]]
SandbotConfig.HomeAttribute = "SandbotHome"

--------------------------------------------------------------------------
-- THE MACHINE
--------------------------------------------------------------------------
--[[
	SIZE. The hull is 5.2 across and the brushes reach past it to about 8.4,
	which is the number Sweep below is derived from.

	A Roblox character is 5 studs tall and chunky, and everything in this game is
	drawn to that -- a realistically-scaled 13 inch vacuum would be a coin on the
	sand. At 5.2 it reads as knee-high next to a player, which is the size a
	thing you send out to work needs to be to be worth watching.
]]
SandbotConfig.Hull = 5.2          -- diameter of the body disc
SandbotConfig.Height = 1.5        -- how tall the body is
-- How far the hull's underside floats over the sand. Tuned against the brushes:
-- their blades hang 0.025 below the hull's own floor, so this is what decides
-- whether they skim the surface or plough it.
SandbotConfig.Hover = 0.30

--[[
	HOW WIDE A BAND IT RAKES, AND WHY IT IS THE BRUSHES' REACH AND NOT MORE.

	CTB_Server records exactly what getting this wrong costs: an earlier version
	took a machine's rake band from its NET's reach, which on a 13.5 stud sweeper
	meant three studs either side going clean under a machine that visibly never
	went near it -- "litter disappearing off to the side for no reason a player
	could see".

	So this is the drawn width of the widest thing on the drone, which is the
	two side brushes, plus the one stud of slack the hand tool gets. Make the
	brushes bigger in SandbotBuilder and this number moves with them; do not move
	it on its own.
]]
SandbotConfig.Sweep = 8.4         -- what the brushes actually span
SandbotConfig.SweepDepth = 5.0    -- front-to-back bite, ~the hull's own footprint

--------------------------------------------------------------------------
-- HOW IT DRIVES
--------------------------------------------------------------------------
--[[
	SPEED IS DELIBERATELY UNDER A LEVELLED PLAYER'S WALK.

	Beach Legs tops out at 66 walk speed. A drone that outran the person who
	bought it would spend the session off in the distance, and the fantasy being
	sold is a second worker on your beach -- not a thing you chase.

	22, DOWN FROM 30, AND IT BUYS SMOOTHNESS AS WELL AS CALM. An anchored part's
	CFrame replicates at about 30 Hz however fast the server drives it, so what a
	client actually sees is one position every ~33ms: at 30 studs/s that is a
	one-stud hop between frames, and at 22 it is 0.73. Slower is literally
	smoother here, which is not usually true of anything.

	IT NOW SITS JUST UNDER THE WALKING FLOOR rather than well over it: the floor
	went 16 -> 24 on 2026-08-28 (ProgressionConfig.BaseWalkSpeed) and this stayed
	at 22. That is the correct side of the line to be on and it is the reason the
	number did not move with it -- "catchable at every level of Beach Legs" has to
	be true at the FIRST level, which is the one it was closest to failing at.
	Against a 24-stud walk it still reads as brisk and purposeful rather than as a
	thing plodding about, and it no longer risks pulling away from a new player.
]]
SandbotConfig.Speed = 22

--[[
	How fast the nose swings round to a new heading, in radians/second.

	3.4, DOWN FROM 5.2, and it is a smoothness fix rather than a handling one.
	5.2 rad/s is 300 degrees a second -- fast enough that a turn is over inside
	two frames, so every heading change read as a SNAP rather than as steering.
	Measured on the first build: 78 of 171 moving ticks turned more than ten
	degrees, i.e. the drone spent half its life jinking.

	The turn rate was never the real cause of that (see LaneLength below -- it
	was being handed a new target every few studs), but slowing it is what turns
	the remaining corners into visible arcs. A drone that leans into a turn reads
	as a machine; one that snaps reads as a script.
]]
SandbotConfig.TurnRate = 3.4

--[[
	HOW MUCH SPEED A HARD TURN COSTS -- the floor, as a fraction of full speed.

	Some braking is right: it stops the drone describing a wide arc round a
	target just off its shoulder. Too much and the turn reads as a STALL, which
	is half of what "glitchy and static" means -- the eye reads stop-start as
	broken far more readily than it reads a wide corner as wrong.

	0.45, up from 0.25. At 22 studs/s that is still 9.9 through the tightest
	corner, which is visibly moving.
]]
SandbotConfig.TurnBrake = 0.45

-- Close enough to a target to call it reached and pick the next one. Under half
-- the sweep width, so it cannot declare arrival at something its band has not
-- actually covered.
SandbotConfig.Arrive = 3.0

--[[
	THE LEASH, and it is the whole reason this cannot become an idle-farm.

	The drone works the field around its OWNER. Past this it stops hunting and
	comes back, so it can never be parked on the far side of an island and left
	to clear it while the player is somewhere else entirely -- the pass buys a
	second pair of hands beside you, not an unattended one.

	180 studs is about two and a half screens at the default camera: comfortably
	out of the way, still somewhere you can see it working.
]]
SandbotConfig.Leash = 180

--[[
	HOW LONG THE OWNER HAS TO BE SOMEWHERE THE DRONE CANNOT WORK BEFORE IT PACKS
	ITSELF AWAY.

	Leaving an island -- by ferry, by menu, into a duel or out to the idle shore --
	puts the machine back in its kennel rather than dragging it along; SandbotService
	step() has the whole argument and both tests.

	⚠ THIS IS NOT PATIENCE, IT IS A TELEPORT FILTER, and without it the feature does
	not work at all. A long teleport REPLICATES AS A SWEEP: 0.2s after a jump from
	the beach to the Magma Chamber the owner's root part was measured at (403, -297),
	8.9% of the way along the straight line between them -- open sea, no zone, 326
	studs from any sand. One frame of that reads exactly like a ferry, and it packed
	the drone away before the player had arrived anywhere.

	0.75s: comfortably past a transit that was over inside 0.4s, and far short of any
	real crossing, which never comes back. What it costs a genuine departure is about
	sixteen studs of boat.
]]
SandbotConfig.LeaveGrace = 0.75

-- Where it parks when there is nothing to do: a slow orbit at this radius
-- behind the owner, high enough not to be walked through.
SandbotConfig.DockRadius = 7.5
SandbotConfig.DockSpin = 0.6      -- radians/second round the owner while docked

--------------------------------------------------------------------------
-- GOING OUT AND COMING BACK
--------------------------------------------------------------------------
--[[
	THE MACHINE LEAVES AND RE-ENTERS THE BUILDING IT LIVES IN.

	It used to be PUT DOWN beside its owner and PICKED UP from wherever it stood:
	one frame a drone appeared on the sand, one frame later it was gone. That reads
	as a spawn rather than as a vehicle -- and it left the SANDBOT HOME as a shed
	with a permanent display model in it that the thing you actually drove had no
	relationship to at all.

	So a deploy now starts ON THE CHARGING PLATE, in the display's own pose, facing
	out, and drives through the mouth under its own power; a recall drives back to
	the apron, turns in, settles on the plate and hands over to the display. The
	three numbers below are about that fifteen-stud journey and nothing else.
]]
-- How far past the mouth it drives before it is "out" -- and the point it lines
-- up on before turning in on the way back, so it enters BETWEEN THE POSTS rather
-- than cutting the corner through a side wall. The mouth is 8.4 studs wide and
-- the machine is 8.4 across the brushes, so the approach has to be square.
SandbotConfig.DockApron = 8

--[[
	OVER HOW MANY STUDS THE RIDE HEIGHT CROSSES FROM THE PLATE TO THE GROUND.

	Inside a kennel there is no field to read, and rideY's off-field fallback is
	THE OWNER'S FEET -- which is the wrong ground the moment they walk off the
	apron, and no ground at all while they are respawning. So the dock states ride
	the plate's own height near the plate and blend to rideY's answer as they
	leave. No raycast, and nothing to be surprised by.

	14 is a stud over the whole trip (5.4 to the mouth plus DockApron), so the
	blend finishes exactly where the drone stops being the dock's business.
]]
SandbotConfig.DockBlend = 14

--[[
	HOW LONG IT SITS ON THE PLATE BEFORE THE DISPLAY TAKES OVER.

	It arrives NOSE FIRST, facing the back wall, and every parked display machine
	faces the mouth -- so without a beat to turn round in, the handover at the end
	of this window is a visible 180 degree flip. It turns at TurnRate, and half a
	turn at 3.4 rad/s is 0.92s, so 1.2 covers it with a beat to spare.

	The handover itself is invisible because the two poses are identical:
	SandbotService parks on the berth SandbotDockBuilder computes FROM the display's
	own pivot.
]]
SandbotConfig.ParkHold = 1.2

--------------------------------------------------------------------------
-- WHAT IT GOES FOR
--------------------------------------------------------------------------
--[[
	LITTER FIRST, THEN SAND, and the two radii are not the same number.

	A tagged prop is worth going out of the way for -- it is a whole item with a
	weight and a value, where a cell of sand is a fraction of one. So the drone
	looks for litter over a WIDER circle than it looks for dirty sand, and
	prefers it whenever both are in range.

	Both are capped well inside the leash so that hunting can never be what
	takes the drone off its lead.
]]
SandbotConfig.LitterRange = 90
SandbotConfig.SandRange = 130

--[[
	A SAFETY RE-ASK, NOT THE THING THAT PICKS TARGETS.

	This was 0.6 and it was the single biggest cause of the drone looking
	broken. Re-picking every 0.6 seconds meant re-picking every ~18 studs, and
	since the target is the NEAREST unraked cell -- which after a pass is four
	or five studs off the shoulder, never ahead -- the drone was handed a
	near-right-angle turn several times a second, for ever. It never drove
	anywhere; it vibrated up the beach.

	Targets are COMMITTED to now (see SandbotService: a new one is taken on
	arrival, or when the one it holds stops being worth driving to). This is
	only the watchdog for a target that can never be reached -- another player
	raked it, the tide turned it over -- and 2.5s at 22 studs/s is 55 studs of
	patience before it asks again.
]]
SandbotConfig.RetargetEvery = 2.5

--[[
	THE LANE PROBE -- what actually makes it drive in straight lines.

	Rather than "where is the nearest dirty cell" (which points sideways), the
	drone asks "how far can I keep going the way I am already pointed and still
	be doing useful work", by sampling forward along its own nose every LaneStep
	studs out to LaneLength and taking the FURTHEST point that still has unraked
	sand at it. That is a target tens of studs ahead, so it drives a long
	straight pass and sweeps everything on the way -- which is both smoother to
	watch and a better way to clear a field than nearest-first.

	The furthest, not the nearest-gap: a clean patch part way along is swept
	through rather than turned around, because the band is 8.4 wide and the trip
	past it costs nothing.

	MinLane is the shortest run worth committing to. Under it, a "lane" is just
	the jinking above wearing a different name, so the drone falls back to the
	ring search and takes one proper turn instead.

	72 studs is a bit over a quarter of the home beach and half of the smallest
	field, so a lane crosses a useful amount of ground without aiming at sand
	that will be raked before it arrives.
]]
SandbotConfig.LaneLength = 72
SandbotConfig.LaneStep = 6
SandbotConfig.MinLane = 14

-- How often a drone that is waiting on a full bag re-asks whether there is room
-- again. Its own clock rather than the retarget watchdog above, which is 2.5s --
-- that would be two and a half seconds of BAG FULL on the key after the player
-- had already sold. One weight lookup at 1.3 Hz per drone costs nothing.
SandbotConfig.RoomCheckEvery = 0.75

--[[
	HOW MANY CELLS OUT THE SAND SEARCH WALKS BEFORE GIVING UP.

	The search is a square ring walk out from the drone's own cell, so the work
	is proportional to the ring it finds something on -- next to nothing on a
	messy field, and this ceiling only on a field that is nearly finished. At
	TILE = 4 studs, 33 rings is 132 studs, which is SandRange rounded up to a
	cell.

	A nearly-clean field is exactly when this matters: the last few columns of a
	160x160 grid are 25,600 cells away from being findable by a linear scan, and
	the ring walk finds them in the order the drone would actually want to drive
	to them.
]]
SandbotConfig.SandRings = 33

--------------------------------------------------------------------------
-- THE TICK
--------------------------------------------------------------------------
--[[
	THE RAKE TICK, AND IT IS NO LONGER THE MOVEMENT TICK.

	20 Hz. The sweep it drives is CTB_Server's, which runs its own loop at 24 --
	close enough that the two lay down comparable bands, and slow enough that a
	server with eight drones out is doing eight sweeps a tick rather than eight
	per frame.

	MOVEMENT RUNS EVERY FRAME NOW. Driving on this clock meant the hull's CFrame
	changed 20 times a second and sat perfectly still in between: measured on the
	server, 72% of frames had no movement at all, so the drone advanced in ~1.5
	stud hops. On a 60 fps client that is two dead frames out of every three,
	which is exactly what "static-like" describes.

	Separating them costs nothing -- the band is built from the last RAKE point
	to the current one, so where the drone was in between was never part of the
	arithmetic.
]]
SandbotConfig.RakeTick = 1 / 20

--[[
	A SPEED GATE OF ITS OWN, copied from CTB_Server's MAX_SWEEP_SPEED and for
	the same reason.

	The rake band is built from last -> now, so any single step much longer than
	one tick's travel would carve a stripe across everything between the two
	points. The drone can be MOVED rather than driven -- a recall, a respawn, an
	island change, a server hitch -- and every one of those arrives here as one
	enormous step. Anything faster than double its own top speed is not driving
	and rakes nothing.
]]
SandbotConfig.MaxSweepSpeed = SandbotConfig.Speed * 2

--------------------------------------------------------------------------
-- WHAT IT LOOKS LIKE IT IS DOING
--------------------------------------------------------------------------
--[[
	THE LAMP IS THE WHOLE READOUT NOW.

	There used to be a Labels table beside this one -- SWEEPING, COLLECTING, BAG
	FULL -- printed on a second line of the HUD key, kept fed by a SandbotSync
	remote firing at 2.5 Hz per deployed drone. The key is gone (see the header)
	and both went with it.

	The lamp is the better readout in any case: it says the same six things to
	everybody who can see the drone rather than to its owner's corner of the
	screen, and it costs one replicated Color written on the CROSSING only. The
	two things worth interrupting somebody for -- a full bag, a refused deploy --
	are toasts.

	The keys ARE SandbotService's own `state` field, so this table is also the
	list of states the machine has.
]]
SandbotConfig.Lamps = {
	hunting = Color3.fromRGB(94, 226, 196),    -- foam: working
	litter  = Color3.fromRGB(255, 200, 62),    -- sun: it has seen something
	homing  = Color3.fromRGB(64, 168, 240),    -- sea: coming back
	docked  = Color3.fromRGB(140, 226, 96),    -- lime: idle, nothing wrong
	full    = Color3.fromRGB(255, 96, 88),     -- coral: it needs you

	-- THE KENNEL'S OWN STATES. Sea, the same as homing, because that is what all
	-- three of them are: the machine is travelling rather than working. `parked`
	-- is lime, which is the last anybody sees of it before the display takes over.
	leaving   = Color3.fromRGB(64, 168, 240),
	returning = Color3.fromRGB(64, 168, 240),
	docking   = Color3.fromRGB(64, 168, 240),
	parked    = Color3.fromRGB(140, 226, 96),
}

return SandbotConfig
