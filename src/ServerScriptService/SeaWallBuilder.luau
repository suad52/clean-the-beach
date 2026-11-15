--[[
	SeaWallBuilder  --  ServerScriptService.SeaWallBuilder  (ModuleScript)

	THE EDGE OF EVERY SHORE. An invisible fence standing out in the water round
	each island, so the only way from one to another is the boat.

	WHAT IT IS FOR
	--------------
	The four shores sit in ONE continuous sheet of Terrain water and nothing has
	ever stood between them. Measured, the fences below leave gaps of 644 studs
	(beach to dunes), 514 (beach to cove) and 820 (cove to Ashfall) -- long
	swims, and entirely possible ones. A swim walks straight past every gate the
	ferry enforces, and those gates are not decoration: FerryConfig's ladder
	(Dunes 1, Cove 8, Ashfall 19 rebirths) is the spine of the game's pacing, and
	a player who swims to Ashfall on their first tide has skipped the whole of it.

	The hole was already on the record. FerryServer's header says a player "who
	swam out here" must always be able to get home, and FerryConfig's says the
	same -- which is why sailing home is free and must stay free. THAT RULE IS
	UNCHANGED, and it is now a backstop rather than a load-bearing escape hatch.

	WHY A WALL RATHER THAN A POSITION CHECK. A check that pushes a swimmer back
	has to decide, every frame, whether somebody is cheating or riding a ferry or
	half way through a rebirth; a wall simply does not let them past, costs
	nothing per frame, and is enforced by the client's own physics so there is no
	rubber-band. The position check is still here -- see THE BACKSTOP at the
	bottom -- but only for somebody who got through the wall.

	NOTHING HERE IS AUTHORED
	------------------------
	FerryConfig carries a long note about every Z in its berths having been
	SURVEYED off the terrain the island builders actually make, and about what it
	costs when an island moves and its numbers do not (Ashfall's berth has
	already had to slide 320 studs south once). A hand-written rectangle per
	island would inherit that whole failure mode and would be worse, because a
	fence that is wrong is either an invisible wall across somebody's beach or a
	fence with the sea outside it.

	So every number below is MEASURED at boot, in three passes per island:

	  1. what is standing there   every BasePart in the home seas, filed under
	                              whichever shore centre it is nearest
	  2. what the boat crosses    the mooring and the point out at sea, straight
	                              off FerryConfig, plus a hull's reach either way
	  3. where the land stops     the terrain is marched outward from that box
	                              until it stops coming up above the waterline

	Then MARGIN studs of open water, and that is the fence. Move an island, grow
	one, add a fifth, and this re-measures it; the only thing it cannot invent is
	a shoreline that is not there.

	RUN IT LAST. It reads the finished world, so it wants every island builder,
	the ferry and ServiceClearance to have run first -- Island4Builder repours
	its whole island from source every boot, so anything measured before that
	line is measuring geometry that is about to be thrown away. CTB_Server calls
	it at the very end for exactly that reason.

	STREAMING. StreamingEnabled is on and these walls stand up to a thousand
	studs from anything a player is looking at, so the model is PERSISTENT: a
	wall that streamed out would be a wall the client's physics does not have,
	which is a player swimming clean through it and being dragged back by the
	server. Forty-odd invisible parts is a cheap thing to keep resident.

	PUBLIC API
		SeaWallBuilder.build()   -- survey, build, verify. Returns the fences.
		SeaWallBuilder.start()   -- arms the backstop sweep. Call after build().
		SeaWallBuilder.fences    -- what it measured, for anything that asks.
]]

local SeaWallBuilder = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FerryConfig = require(ReplicatedStorage:WaitForChild("FerryConfig"))
local Config = require(ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Config"))

local FOLDER_NAME = "SeaWalls"

----------------------------------------------------------------
-- THE DIALS
----------------------------------------------------------------
--[[
	THE HOME SEAS: the water the four shores stand in, and the only place this
	file has any opinion about.

	It exists because most of this game is NOT on an island. The three interiors
	(vault, inner shrine, magma chamber) are parked at x = 3000, the idle shore
	is at (8000, 8000) and the duel arenas at (12000, 12000) -- all of them
	reached by a cinematic or a prompt and none of them reachable by water. A
	sweep that did not know that would file the AFK shore under "nearest island"
	and start correcting idlers eight thousand studs from the sea.

	Generous on every side: it only has to separate four islands from three
	teleport destinations that are thousands of studs outside it.
]]
-- z0 came down from -1600 for Penguin Island (2026-09): its sea is centred at
-- z -2700 and runs out to -4000, and the fence has to reach the whole of it.
local HOME = { x0 = -3600, x1 = 2200, z0 = -4400, z1 = 2600 }

-- Anything the terrain holds above this is land. The sea surface is y = 0 on
-- every one of the four shores (the top water voxel reads -2, so the surface
-- sits at 0); half a stud under it is beach rather than seabed.
local WATERLINE = -0.5

--[[
	HOW MUCH OPEN WATER IS LEFT OUTSIDE AN ISLAND, past the last thing that
	belongs to it and past the far end of its ferry's run.

	150 is a compromise between two ways of getting this wrong. Tight to the
	shore and the sea stops being a sea -- you wade in, take four strokes and hit
	something; the beach is the one island whose whole subject is a tideline. Far
	out and the fences start meeting in the middle, which turns an ocean into a
	corridor and puts the wall exactly where a player is most likely to be
	aiming at another island.

	At 150 the narrowest crossing left between two fences is 514 studs, so no
	wall is ever within sight of another one, and there is still enough water off
	every beach to swim, dive and round the pier head in.
]]
local MARGIN = 150

-- Half a hull plus slack. A ferry is 32 studs long (FerryBuilder.BOAT_LEN) and
-- both her mooring and her point out at sea are given as the position of her
-- MIDDLE, so a fence drawn to those two points alone would cut her bow off.
local BOAT_REACH = 20

-- The march that finds the real shoreline. STEP is how far out each pass
-- looks, SPAN how finely it samples across the side, MAXOUT how far it bothers
-- looking at all, and QUIT how many consecutive empty passes count as "that
-- was the last of the land" -- more than one, because a shoreline can have a
-- rock standing off it with clear water either side.
local STEP, SPAN, MAXOUT, QUIT = 8, 16, 420, 5

-- The wall itself. Six studs thick: a swimmer moves about a stud a frame and
-- the fastest thing in the game is a 66-stud walk, so nothing here can tunnel
-- through six. It runs from well under the seabed (-10 to -14 out here) to
-- well over the volcano's 197-stud summit, because an invisible part costs the
-- same however tall it is and the one thing a fence must never have is a top.
local WALL_T = 6
local WALL_BOTTOM, WALL_TOP = -60, 260

-- Longest single part in a run. Nothing about the walls needs splitting for
-- streaming -- the model is persistent -- but a Part is capped at 2048 studs on
-- an axis and Ashfall's fence is 2064 long, so a run has to be able to come in
-- pieces anyway. 480 keeps every part comfortably inside that.
local SEG_MAX = 480

----------------------------------------------------------------
-- SURVEY
----------------------------------------------------------------
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace.Terrain }
-- Water is not ground. Without this every cast into the sea answers at y = 0
-- and the march never finds a shoreline because it never leaves one.
groundParams.IgnoreWater = true

local function groundY(x: number, z: number): number
	local hit = workspace:Raycast(Vector3.new(x, 500, z), Vector3.new(0, -900, 0), groundParams)
	return hit and hit.Position.Y or -math.huge
end

local function islandById(id: number)
	for _, isl in ipairs(Config.ISLANDS) do
		if isl.id == id then
			return isl
		end
	end
	return nil
end

local function inHome(p: Vector3): boolean
	return p.X >= HOME.x0 and p.X <= HOME.x1 and p.Z >= HOME.z0 and p.Z <= HOME.z1
end

-- The XZ half-extents of a part in world axes, which is the only part of a
-- bounding box a fence cares about. Taken off the CFrame rather than off
-- Size alone so a rotated prop is measured by what it actually covers.
local function halfXZ(part: BasePart): Vector3
	local cf, s = part.CFrame, part.Size
	return Vector3.new(
		math.abs(cf.RightVector.X) * s.X / 2
			+ math.abs(cf.UpVector.X) * s.Y / 2
			+ math.abs(cf.LookVector.X) * s.Z / 2,
		0,
		math.abs(cf.RightVector.Z) * s.X / 2
			+ math.abs(cf.UpVector.Z) * s.Y / 2
			+ math.abs(cf.LookVector.Z) * s.Z / 2)
end

--[[
	ONE SHORE PER FERRY PORT, and the ports are the right list rather than
	Config.ISLANDS.

	Config.ISLANDS holds seven rows and three of them are ROOMS -- the vault, the
	inner shrine and the magma chamber. Those are sealed on all six sides,
	parked out at x = 3000, and reached by a door and a cinematic; fencing one
	would draw a wall round a box. FerryConfig.Ports is exactly the set of places
	a boat ties up at, which is exactly the set of places a swimmer could be
	trying to reach. (FerryConfig's header makes the same distinction, in the
	same words, about why the vault is not a port.)
]]
local function newShores()
	local shores = {}
	for _, port in ipairs(FerryConfig.Ports) do
		local isl = islandById(port.island)
		if isl then
			table.insert(shores, {
				key = port.key,
				name = port.name,
				port = port,
				cx = isl.cx,
				cz = isl.cz,
				x0 = math.huge, x1 = -math.huge,
				z0 = math.huge, z1 = -math.huge,
				parts = 0,
			})
		else
			warn(string.format("[SeaWall] the %s port names island %s, which is not in Config.ISLANDS;"
				.. " that shore gets no fence", port.key, tostring(port.island)))
		end
	end
	return shores
end

-- Which shore a point belongs to. CHEBYSHEV rather than Euclidean, because
-- what is being built is a rectangle: the thing that decides whether a prop
-- pulls a fence outward is how far it is along an AXIS, not along a diagonal.
local function nearestShore(shores, p: Vector3)
	local best, bestD
	for _, s in ipairs(shores) do
		local d = math.max(math.abs(p.X - s.cx), math.abs(p.Z - s.cz))
		if not bestD or d < bestD then
			best, bestD = s, d
		end
	end
	return best
end

local function grow(s, lo: Vector3, hi: Vector3)
	s.x0 = math.min(s.x0, lo.X)
	s.x1 = math.max(s.x1, hi.X)
	s.z0 = math.min(s.z0, lo.Z)
	s.z1 = math.max(s.z1, hi.Z)
end

--[[
	PASS 1 -- WHAT IS STANDING THERE.

	One walk of the workspace, every BasePart inside the home seas filed under
	the shore whose centre it is nearest. This is what makes the fence follow
	the island rather than the island's terrain alone: the beach's furthest
	thing is a BUOY moored 54 studs past the last of the sand, and a fence drawn
	off the shoreline would have stood between a player and it.

	The walls themselves are excluded, so a rebuild measures the world rather
	than measuring its own last answer and drifting outward 150 studs a boot.

	⚠️ AND SO IS TERRAIN, WHICH IS A BasePart. This is the one trap in the file
	and it does not look like one: workspace.Terrain answers true to IsA
	("BasePart"), its Position is the origin and its Size is the bounding box of
	every voxel in the world. Left in, it files itself under whichever shore is
	nearest the origin -- the beach -- and hands that island a 2,344-stud fence
	swallowing two of the other three. It is caught by verify() rather than
	silently shipped, which is what that pass is for, but the fix belongs here.
]]
local function surveyParts(shores)
	local old = workspace:FindFirstChild(FOLDER_NAME)
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("BasePart") and not d:IsA("Terrain")
			and not (old and d:IsDescendantOf(old)) then
			local p = d.Position
			if inHome(p) then
				local s = nearestShore(shores, p)
				if s then
					local r = halfXZ(d)
					grow(s, p - r, p + r)
					s.parts += 1
				end
			end
		end
	end
end

--[[
	PASS 2 -- WHAT THE BOAT CROSSES.

	The crossing runs SAIL_OUT (78) studs out from the mooring and back, with the
	player standing on the deck, and this has to be inside the fence.

	Not because the wall would stop her -- the passenger's root is anchored and
	written by CFrame for the whole voyage (FerryServer's `run`), so both boat
	and rider pass through anything. It is because of where a crossing can be
	INTERRUPTED. Somebody who dies, resets or is dropped by a frame-late check
	out at sea is released wherever the run had got to, and being released
	outside your own island's fence is the one state this file must never create.
]]
local function surveyFerry(shores)
	local reach = Vector3.new(BOAT_REACH, 0, BOAT_REACH)
	for _, s in ipairs(shores) do
		for _, p in ipairs({ FerryConfig.moorPos(s.port), FerryConfig.seaPos(s.port) }) do
			grow(s, p - reach, p + reach)
		end
	end
end

--[[
	PASS 3 -- WHERE THE LAND ACTUALLY STOPS.

	Terrain does not have to end where the props do, and on two of the four
	shores it does not: Sakura Cove's sand runs 144 studs past its outermost
	part and the dunes' plateau 56 past theirs. A fence drawn off pass 1 alone
	would have crossed both of those beaches.

	So each side is marched outward in STEP-stud passes, sampling across the
	full width of that side, until QUIT passes in a row come back with nothing
	above the waterline. The samples run WIDER than the box by however far the
	march has got -- otherwise a headland that leans out diagonally is walked
	straight past, because the pass looking for it is only sampling the width
	the island had before the march started.
]]
local SIDES = {
	{ axis = "x0", sign = -1, along = "z", name = "West" },
	{ axis = "x1", sign = 1, along = "z", name = "East" },
	{ axis = "z0", sign = -1, along = "x", name = "South" },
	{ axis = "z1", sign = 1, along = "x", name = "North" },
}

local function surveyShoreline(s): number
	local casts = 0
	for _, side in ipairs(SIDES) do
		local base = s[side.axis]
		local reach, empty, out = 0, 0, STEP
		while out <= MAXOUT and empty < QUIT do
			local at = base + side.sign * out
			local lo = (side.along == "z") and (s.z0 - out) or (s.x0 - out)
			local hi = (side.along == "z") and (s.z1 + out) or (s.x1 + out)
			local found = false
			for t = lo, hi, SPAN do
				casts += 1
				local y = (side.along == "z") and groundY(at, t) or groundY(t, at)
				if y > WATERLINE then
					found = true
					break
				end
			end
			if found then
				reach, empty = out, 0
			else
				empty += 1
			end
			out += STEP
		end
		if reach >= MAXOUT then
			-- The march ran out of road with land still under it. Not fatal --
			-- the fence is simply drawn at the limit -- but it means an island
			-- has outgrown what this file expects, and the fence may cross it.
			warn(string.format("[SeaWall] %s still has land %d studs off its %s side,"
				.. " which is as far as the survey looks; raise MAXOUT",
				s.key, reach, side.name))
		end
		s[side.axis] = base + side.sign * (reach + MARGIN)
		s["reach" .. side.axis] = reach
	end
	return casts
end

----------------------------------------------------------------
-- BUILD
----------------------------------------------------------------
--[[
	One wall part. Invisible, solid, and deaf to everything else.

	CanQuery IS OFF and that matters more than it looks. Half the world in this
	game finds its floor by raycasting -- the ferry's deck height, the pet
	plazas, the reward board, the skin plinths, the sandbot -- and a query-able
	part standing in the sea is a thing one of those casts can hit one day. It
	blocks a body, not a ray. CanTouch is off for the same reason: there is
	exactly one Touched connection in the game (AfkService's entry pad) and
	nothing here should ever be able to add a second.

	CastShadow is off because a transparent part still shadows in Roblox, and a
	300-stud slab shadowing the sea would be the most visible invisible wall
	ever built.
]]
local function wall(parent: Instance, name: string, cf: CFrame, size: Vector3): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	p.CanCollide = true
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	-- So a fence is never picked up by a drag in Studio. It is invisible, it is
	-- 300 studs tall, and it is standing where somebody building a boat would
	-- be marquee-selecting.
	p.Locked = true
	p.Parent = parent
	return p
end

-- A run of wall along one axis, cut into parts no longer than SEG_MAX. The
-- pieces are even rather than "as many SEG_MAX as fit plus a stub": a run of
-- equal parts is one number to read in the explorer instead of two.
local function runOfWall(parent: Instance, name: string, from: Vector3, to: Vector3, sideways: boolean)
	local span = (to - from).Magnitude
	local n = math.max(1, math.ceil(span / SEG_MAX))
	local each = span / n
	local height = WALL_TOP - WALL_BOTTOM
	local y = (WALL_TOP + WALL_BOTTOM) * 0.5
	local dir = (to - from).Unit
	local built = 0
	for i = 1, n do
		local mid = from + dir * (each * (i - 0.5))
		local size = sideways
			and Vector3.new(each, height, WALL_T)
			or Vector3.new(WALL_T, height, each)
		wall(parent, string.format("%s_%d", name, i), CFrame.new(mid.X, y, mid.Z), size)
		built += 1
	end
	return built
end

--[[
	The four sides of one fence.

	The two North/South runs span the FULL x range and the East/West runs are
	extended by a thickness at each end, so the four overlap at the corners
	rather than meeting at them. A corner that merely meets leaves a 6 x 6 stud
	notch, and a 6 x 6 notch in an invisible wall is the kind of hole that gets
	a video made about it.
]]
local function buildFence(parent: Instance, s): number
	local m = Instance.new("Model")
	m.Name = s.key
	m.Parent = parent
	local n = 0
	n += runOfWall(m, "South", Vector3.new(s.x0, 0, s.z0), Vector3.new(s.x1, 0, s.z0), true)
	n += runOfWall(m, "North", Vector3.new(s.x0, 0, s.z1), Vector3.new(s.x1, 0, s.z1), true)
	n += runOfWall(m, "West",
		Vector3.new(s.x0, 0, s.z0 - WALL_T), Vector3.new(s.x0, 0, s.z1 + WALL_T), false)
	n += runOfWall(m, "East",
		Vector3.new(s.x1, 0, s.z0 - WALL_T), Vector3.new(s.x1, 0, s.z1 + WALL_T), false)
	return n
end

----------------------------------------------------------------
-- VERIFY
----------------------------------------------------------------
--[[
	TWO THINGS THAT MUST BE TRUE OF A FINISHED FENCE, both checked out loud.

	1. IT STANDS IN WATER. A fence line that crosses dry land is an invisible
	   wall across somebody's beach -- the single worst thing this file could
	   ship, and the one a hand-written rectangle would eventually produce. The
	   perimeter is sampled every four studs and the highest ground under it is
	   reported; anything above the waterline is named, with the coordinates,
	   because "a wall is on the sand" is not something to leave to a bug report.

	2. NO TWO FENCES TOUCH. Two overlapping fences are one enclosure with two
	   islands in it, which is the thing this file exists to prevent, and it
	   would be completely invisible in play -- everything would look right and
	   the swim would still work.
]]
local function verify(shores)
	for _, s in ipairs(shores) do
		local worst, wx, wz = -math.huge, 0, 0
		local function probe(x, z)
			local y = groundY(x, z)
			if y > worst then
				worst, wx, wz = y, x, z
			end
		end
		for x = s.x0, s.x1, 4 do
			probe(x, s.z0)
			probe(x, s.z1)
		end
		for z = s.z0, s.z1, 4 do
			probe(s.x0, z)
			probe(s.x1, z)
		end
		s.deepest = worst
		if worst > WATERLINE then
			warn(string.format("[SeaWall] the %s fence crosses dry land: ground reads %.1f at (%.0f, %.0f)."
				.. " That is a wall on a beach -- raise MARGIN or check what has been built there.",
				s.key, worst, wx, wz))
		end
	end

	for i = 1, #shores do
		for j = i + 1, #shores do
			local a, b = shores[i], shores[j]
			if a.x0 < b.x1 and b.x0 < a.x1 and a.z0 < b.z1 and b.z0 < a.z1 then
				warn(string.format("[SeaWall] the %s and %s fences overlap, so the two are one enclosure"
					.. " and the swim between them is still open. Lower MARGIN.", a.key, b.key))
			end
		end
	end
end

----------------------------------------------------------------
-- THE ONE ENTRY POINT
----------------------------------------------------------------
function SeaWallBuilder.build()
	local t0 = os.clock()
	local shores = newShores()

	surveyParts(shores)
	surveyFerry(shores)

	-- A shore with nothing on it is an island whose builder threw. Fencing the
	-- ferry route alone would draw a 190-stud box round a boat in open water,
	-- which is worse than no fence, so it is dropped with a word about why.
	local live = {}
	for _, s in ipairs(shores) do
		if s.parts > 0 then
			table.insert(live, s)
		else
			warn(string.format("[SeaWall] nothing is standing at %s, so it gets no fence."
				.. " Did its island builder fail?", s.key))
		end
	end

	local casts = 0
	for _, s in ipairs(live) do
		casts += surveyShoreline(s)
	end

	-- Idempotent, the same contract every island builder keeps with its own
	-- folder: a second boot replaces the fences rather than standing a second
	-- set inside the first.
	local old = workspace:FindFirstChild(FOLDER_NAME)
	if old then
		old:Destroy()
	end

	local root = Instance.new("Model")
	root.Name = FOLDER_NAME
	-- Set BEFORE it is parented: this is read when the model enters the
	-- workspace, and a wall the client has not been sent is not a wall.
	root.ModelStreamingMode = Enum.ModelStreamingMode.Persistent

	local parts = 0
	for _, s in ipairs(live) do
		parts += buildFence(root, s)
	end
	root.Parent = workspace

	verify(live)

	SeaWallBuilder.fences = live
	for _, s in ipairs(live) do
		print(string.format("[SeaWall] %-8s x[%.0f..%.0f] z[%.0f..%.0f]  %.0f x %.0f"
			.. "  (shoreline reach W%d E%d S%d N%d, +%d margin, %.1f under the line)",
			s.key, s.x0, s.x1, s.z0, s.z1, s.x1 - s.x0, s.z1 - s.z0,
			s.reachx0, s.reachx1, s.reachz0, s.reachz1, MARGIN, s.deepest or 0))
	end
	print(string.format("[SeaWall] %d fences, %d parts, %d casts, %.2fs",
		#live, parts, casts, os.clock() - t0))

	return live
end

----------------------------------------------------------------
-- THE BACKSTOP
----------------------------------------------------------------
--[[
	FOR SOMEBODY WHO IS ALREADY OUTSIDE, and nothing else.

	The wall is the mechanism. This is the answer to the one question the wall
	cannot answer -- what happens to a player who is on the wrong side of it --
	and there are ordinary ways to end up there without cheating at all: a fence
	goes up around a player who was already out swimming when the server booted,
	a ferry crossing dies out at sea, a fling sends somebody over the top.

	IT PUTS THEM BACK IN THE WATER, TEN STUDS INSIDE THEIR OWN FENCE. Not on the
	pier, not at spawn: the smallest correction that ends the state, and one that
	never moves a player between islands. Sailing home stays the way home.

	FOUR THINGS IT WILL NOT TOUCH, and each is a real state this would otherwise
	break:

	  an anchored root      the ferry anchors the passenger for the whole
	                        crossing (FerryServer.seize) and the rebirth
	                        ascension anchors them to lift them
	                        (ProgressionServer). Both are legitimate, both put a
	                        character somewhere physics did not, and neither is
	                        cheating.
	  anywhere but home     the interiors are at x = 3000, the idle shore at
	                        (8000, 8000), the arenas at (12000, 12000). All of
	                        them are outside every fence and all of them are
	                        meant to be.
	  one bad reading       a correction needs two consecutive strikes a second
	                        apart. A single frame in the wrong place is a
	                        streaming hitch or a teleport landing, not a swim.
	  no fences at all      if build() failed there is nothing to be outside OF,
	                        and a backstop with no fence to measure against would
	                        be free to decide everybody is cheating.
]]
local SWEEP_PERIOD = 1
local SWEEP_STRIKES = 2
local INSET = 10

local strikes = {}
local armed = false

local function holds(s, p: Vector3): boolean
	return p.X >= s.x0 and p.X <= s.x1 and p.Z >= s.z0 and p.Z <= s.z1
end

-- Distance from a point to a rectangle, zero inside it. What decides which
-- island somebody who is out at sea was last standing on.
local function distToFence(s, p: Vector3): number
	local dx = math.max(s.x0 - p.X, 0, p.X - s.x1)
	local dz = math.max(s.z0 - p.Z, 0, p.Z - s.z1)
	return math.sqrt(dx * dx + dz * dz)
end

local function putBack(player: Player, hrp: BasePart, s)
	local p = hrp.Position
	local x = math.clamp(p.X, s.x0 + INSET, s.x1 - INSET)
	local z = math.clamp(p.Z, s.z0 + INSET, s.z1 - INSET)
	-- At the surface, not at whatever depth they had got to. The seabed out
	-- here is ten to fourteen studs down, so keeping their Y would post some of
	-- them into it.
	local y = math.max(p.Y, 4)
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.CFrame = CFrame.new(x, y, z) * hrp.CFrame.Rotation
	warn(string.format("[SeaWall] %s was outside the %s fence at (%.0f, %.0f, %.0f);"
		.. " put back inside at (%.0f, %.0f, %.0f)",
		player.Name, s.key, p.X, p.Y, p.Z, x, y, z))
end

local function sweep()
	local fences = SeaWallBuilder.fences
	if not fences or #fences == 0 then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") and not hrp.Anchored and inHome(hrp.Position) then
			local p = hrp.Position
			local inside, nearest, nearestD = false, nil, nil
			for _, s in ipairs(fences) do
				if holds(s, p) then
					inside = true
					break
				end
				local d = distToFence(s, p)
				if not nearestD or d < nearestD then
					nearest, nearestD = s, d
				end
			end
			if inside then
				strikes[player] = nil
			else
				local n = (strikes[player] or 0) + 1
				strikes[player] = n
				if n >= SWEEP_STRIKES and nearest then
					strikes[player] = nil
					putBack(player, hrp, nearest)
				end
			end
		else
			strikes[player] = nil
		end
	end
end

function SeaWallBuilder.start()
	if armed then
		return
	end
	armed = true

	Players.PlayerRemoving:Connect(function(player)
		strikes[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(SWEEP_PERIOD)
			-- Wrapped, because this runs forever: one throw with no pcall round it
			-- and the backstop is silently gone for the life of the server.
			local ok, err = pcall(sweep)
			if not ok then
				warn("[SeaWall] the backstop sweep threw: " .. tostring(err))
			end
		end
	end)
end

return SeaWallBuilder
