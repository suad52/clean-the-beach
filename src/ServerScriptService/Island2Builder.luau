--[[
	Island2Builder  --  ServerScriptService.Island2Builder  (ModuleScript)

	THE DUNES. The game's second rakeable island, 1500 studs east of the beach:
	a sandstone plateau ringed by dunes, with a pyramid on the north side, a
	bazaar and a dock on the south, and the same buried-junk loop in between.

	WHAT LIVES WHERE, because this island is split across three scripts:

	  here                terrain, and every piece of shared geometry -- pyramid,
	                      statue, bazaar, docks, cactuses, the camel's body. All
	                      server-built, so everyone sees the same island.
	  CTB_Server          the rakeable field itself and who has raked what. It is
	                      just another row in Config.ISLANDS to that script.
	  Island2_Client      everything that MOVES or is private: tumbleweeds, the
	                      camel's walk, blowing sand, the heat grade, ambience.

	ORDER. build() must run BEFORE CTB_Server's baselineField(). The plateau is
	filled solid to y = 3 and the rakeable columns are then carved into the top of
	it; the other way round the plateau simply buries them. CTB_Server calls this
	at the bottom of itself, in that order, and nothing else should call it.

	It returns the island's SellPad so CTB_Server can add it to the list of pads
	that pay out -- a bag filled out here should not have to be carried home.

	HAND-EDITING THIS ISLAND. By default build() destroys Workspace.Island2 and
	makes it again, so anything moved in Studio is gone the moment you press
	Play. Set the boolean attribute "HandBuilt" on the Workspace.Island2 folder
	and that stops: the saved geometry is kept as authored and only the WIRING is
	re-run -- see ADOPT OR BUILD, just above build(), for what that covers and
	for how to freeze the island in the first place.
]]

local Island2 = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local CTB = ReplicatedStorage:WaitForChild("CTB")
local Config = require(CTB:WaitForChild("Config"))
local Net = CTB:WaitForChild("Net")
-- The chamber behind the door owns both halves of the transition; the door only
-- decides whether it is allowed to happen.
local Vault = require(script.Parent:WaitForChild("VaultBuilder"))
-- The desert's signs go through the same kit as the beachfront's. This module
-- REBUILDS its island on every boot, so SignDresser's pass over the world would
-- dress a Bazaar that is about to be thrown away -- these have to be right when
-- they are made, not corrected afterwards.
local SignKit = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("SignKit"))

local Terrain = workspace.Terrain

----------------------------------------------------------------
-- Where everything is
----------------------------------------------------------------
local ISL = Config.island(2)
local CX, CZ = ISL.cx, ISL.cz          -- 1500, 0
local GROUND = ISL.cleanY              -- 3.0, same as the beach
local FIELD_HALF = ISL.half            -- 96: the rakeable square is CX/CZ +- this

-- Nothing built by this script may stand inside the rakeable square, or the
-- player would be raking sand out from under a wall. Everything below is placed
-- outside CX +- FIELD_HALF / CZ +- FIELD_HALF, and clearOfField() enforces it
-- for the scattered decor.
local SEA_Y = 0                        -- water surface
local SHORE_R = 348                    -- outermost sand, just under the water
local PLATEAU_R = 296                  -- where the island is at full height

-- The pyramid. 124 studs across the base and 78 tall is a 53 degree face --
-- Giza is 51.8, and the extra couple of degrees reads better at Roblox scale.
local PZ = 190                         -- pyramid centre on Z
local PY_BASE_HALF = 62
local PY_TOP_HALF = 5
local PY_COURSES = 26
local PY_COURSE_H = 3
local PY_STEP = (PY_BASE_HALF - PY_TOP_HALF) / PY_COURSES

-- The way in. FACE_Z is the pyramid's front face at ground level; the porch
-- stands against it and the corridor runs back from it into the chamber.
local FACE_Z = PZ - PY_BASE_HALF       -- 128
local HALL_HALF = 14                   -- corridor/chamber half-width
local HALL_BACK = PZ + 16              -- 206, the chamber's back wall
local HALL_TOP = GROUND + 21           -- ceiling; courses below this are hollowed
local DOOR_W, DOOR_H = 12, 18
local AUTO_CLOSE = 24                  -- seconds the tomb stays open after a click

-- TRAVEL IS NOT HERE ANY MORE.
--
-- This island used to own half of a gate pair -- GATE_DESERT on the plaza,
-- GATE_BEACH on the beachfront, a Sifter Lv.3 check on the way out and a
-- ProximityPrompt on each pad. All of it has moved to the ferry: FerryConfig
-- holds the route and the requirement, FerryBuilder puts a pier, a boat and a
-- ferryman on the south shore, and FerryServer runs the crossing. The
-- requirement itself is unchanged at Lv.3.
--
-- The one number worth carrying over: the berth's pier runs out to z = -330,
-- which is why the KEEP_OUT box below now reaches -340.

----------------------------------------------------------------
-- Palette
----------------------------------------------------------------
-- These run hotter and more saturated than they look on paper, deliberately.
-- Part materials are lit by the sky as well as the sun, and this place sets
-- EnvironmentDiffuseScale to 0.7 under a bright blue tropical skybox, so a
-- believable "sandstone" value like (196,160,108) comes out reading cool grey
-- next to the terrain -- which does NOT pick up that blue, because it is tinted
-- directly. The first pass had a grey pyramid standing on orange sand.
local SAND_PALE = Color3.fromRGB(242, 210, 148)
local SAND_MID = Color3.fromRGB(226, 180, 112)
local SAND_DEEP = Color3.fromRGB(192, 142, 82)
local STONE = Color3.fromRGB(224, 176, 106)
local STONE_DARK = Color3.fromRGB(176, 128, 72)
local GOLD = Color3.fromRGB(240, 194, 82)
local LAPIS = Color3.fromRGB(40, 78, 150)
local TURQUOISE = Color3.fromRGB(60, 168, 158)
local CARNELIAN = Color3.fromRGB(178, 68, 46)
local GRANITE = Color3.fromRGB(116, 84, 58)
local CACTUS_GREEN = Color3.fromRGB(74, 124, 68)

-- Verified to load before being written in (see the audio note in memory:
-- creator-uploaded audio is private and fails SILENTLY, so only the licensed
-- catalogue can be hardcoded). All three are Pro Sound Effects.
local SND_WIND = "rbxassetid://9125742262"      -- airy whooshing, constant
local SND_HOWL = "rbxassetid://9118747853"      -- distant wind howl, for depth
local SND_DOOR = "rbxassetid://9116826112"      -- deep scrape, pitched down to stone

----------------------------------------------------------------
-- Small builders
----------------------------------------------------------------
local function P(parent, name, size, cf, colour, material, extra)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = colour or STONE
	p.Material = material or Enum.Material.Sandstone
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if extra then
		for k, v in pairs(extra) do
			p[k] = v
		end
	end
	p.Parent = parent
	return p
end

-- Axis-aligned box from world bounds. Most of this island is stone laid in
-- rectangles, and bounds are far easier to reason about than centre+size when
-- the thing you are building has to line up with a face 60 studs away.
local function box(parent, name, x0, x1, y0, y1, z0, z1, colour, material, extra)
	if x1 - x0 < 0.05 or y1 - y0 < 0.05 or z1 - z0 < 0.05 then
		return nil
	end
	return P(parent, name,
		Vector3.new(x1 - x0, y1 - y0, z1 - z0),
		CFrame.new((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5),
		colour, material, extra)
end

-- r minus v, as up to four rectangles. This is how the pyramid gets a hollow
-- inside without any CSG: each solid course is a rectangle, the corridor and
-- chamber are one rectangle punched through it, and what comes back out is the
-- stone that is actually there.
local function subtractRect(r, v)
	if v.x1 <= r.x0 or v.x0 >= r.x1 or v.z1 <= r.z0 or v.z0 >= r.z1 then
		return { r }
	end
	local out = {}
	if r.z0 < v.z0 then
		table.insert(out, { x0 = r.x0, x1 = r.x1, z0 = r.z0, z1 = v.z0 })
	end
	if v.z1 < r.z1 then
		table.insert(out, { x0 = r.x0, x1 = r.x1, z0 = v.z1, z1 = r.z1 })
	end
	local zz0, zz1 = math.max(r.z0, v.z0), math.min(r.z1, v.z1)
	if r.x0 < v.x0 then
		table.insert(out, { x0 = r.x0, x1 = v.x0, z0 = zz0, z1 = zz1 })
	end
	if v.x1 < r.x1 then
		table.insert(out, { x0 = v.x1, x1 = r.x1, z0 = zz0, z1 = zz1 })
	end
	return out
end

-- Would a circle of this radius reach into the rakeable square? Used to keep
-- dunes, cactuses and boulders off the field -- terrain written outside the
-- field's y band would survive the field write and leave a dune floating over
-- sand the player is trying to rake.
local function clearOfField(x, z, r)
	local dx = math.max(0, math.abs(x - CX) - FIELD_HALF)
	local dz = math.max(0, math.abs(z - CZ) - FIELD_HALF)
	return dx * dx + dz * dz > (r + 10) * (r + 10)
end

local function clearOfBox(x, z, r, bx0, bx1, bz0, bz1)
	local dx = math.max(0, math.max(bx0 - x, x - bx1))
	local dz = math.max(0, math.max(bz0 - z, z - bz1))
	return dx * dx + dz * dz > (r + 6) * (r + 6)
end

-- Everything the scattered decor has to stay out of: the buildings, and the
-- walking line from the gate up to the pyramid. A dune across the only path
-- off the dock is the kind of thing that is invisible until someone arrives.
local KEEP_OUT = {
	{ CX - 70, CX + 70, 118, 262 },       -- pyramid and its footings
	{ CX - 44, CX + 44, 96, 126 },        -- the statue plaza in front of it
	{ CX - 62, CX + 62, -340, -96 },      -- the approach up from the ferry pier
	{ 1424, 1576, -186, -96 },            -- the market street and both stalls
	{ 1256, 1346, 106, 196 },             -- the oasis
	{ 1350, 1450, -200, -100 },           -- the camel's patrol circle
	-- The car pad, now inside the market opposite the wash house. Redundant
	-- with the market box above and kept anyway: a cactus growing through a
	-- parking bay is exactly what the first placement of it got, and this list
	-- is the one thing every scatter asks.
	{ 1520, 1552, -120, -94 },            -- the desert car spawner
}

local function clearOfBuildings(x, z, r)
	for _, b in ipairs(KEEP_OUT) do
		if not clearOfBox(x, z, r, b[1], b[2], b[3], b[4]) then
			return false
		end
	end
	return true
end

--[[
	THE TWO MARKET COUNTERS, AS A SEPARATE LIST FROM KEEP_OUT ABOVE.

	The souk cannot ask clearOfBuildings: that list's approach-corridor box
	(CX +- 62, -340..-96) contains the entire souk BY DESIGN -- the souk IS that
	corridor -- so it would refuse every stall in the street.

	And KEEP_OUT's own market box, { 1424, 1576, -186, -96 }, stops at z = -186.
	The Bazaar sits inside it; the OUTFITTERS does not -- that building runs
	-187..-238, entirely south of the box -- so nothing was keeping anything off
	the upgrades counter. What that cost: the souk's east row starts at x = 1531
	(CX + SOUK_X) with its first two rungs at z -208 and -230, which is inside
	the Outfitters on both axes, so a stall was dropped squarely on the shop.
	Measured on a live boot: Island2.Dressing.Stall_Green at (1535, 8, -213),
	ten studs from the "Browse / Dune Outfitters" prompt, standing over the
	counter the player is trying to reach.

	X-BOUNDED TIGHTLY, which is the whole reason this is not just a wider box in
	KEEP_OUT. The west row stands at x = 1469 and fouls nothing; a box wide
	enough to catch the east row would delete the west one too and leave the
	street with a hole in it.
]]
local MARKET_BLOCKS = {
	-- -240 rather than -242, and the two studs matter: at -242 the clearance
	-- reached far enough south that the stall at z -252 was refused or allowed
	-- depending on which way its +-1.6 jitter fell. A stall that shows up half
	-- the time is worse than either answer. The building's real south face is
	-- -238.5, so this is still a pad rather than a squeeze.
	{ 1512, 1562, -240, -184 },           -- Dune Outfitters, the upgrades counter
	{ 1512, 1562, -174, -114 },           -- the Bazaar, the sell counter
}

local function clearOfMarket(x, z, r)
	for _, b in ipairs(MARKET_BLOCKS) do
		if not clearOfBox(x, z, r, b[1], b[2], b[3], b[4]) then
			return false
		end
	end
	return true
end

local function openGround(x, z, r)
	return clearOfField(x, z, r) and clearOfBuildings(x, z, r)
end

----------------------------------------------------------------
-- Terrain: sea, plateau, dunes, outcrops, oasis
----------------------------------------------------------------
local function buildTerrain()
	local rng = Random.new(Config.SEED + 2202)

	-- Wipe the airspace first so a rebuild on a running server does not stack
	-- dunes on top of the dunes it made last time. The radius here is the SAME as
	-- the sea's below, deliberately: this island's ocean overlaps the beach's
	-- (the beach's water reaches x ~= 975 and this reaches back to x = 880), and
	-- clearing a wider circle than we refill would punch a hole in it.
	-- Stops at y = -22, not at the bottom of the world: the overlap with the
	-- beach's ocean is deeper than that, and clearing all the way down would
	-- leave a void under the water for anyone who swam out that far.
	Terrain:FillCylinder(CFrame.new(CX, 99, CZ), 242, 620, Enum.Material.Air)

	-- Seabed, then sea. The water's top is set at y = -0.5 rather than a whole
	-- voxel boundary on purpose: that is where the beach's sea surface sits
	-- (occupancy 0.875 of the -4..0 voxel), and the two oceans meet out in the
	-- haze somewhere around x = 900. Fill* computes fractional occupancy from
	-- volume overlap, so asking for -0.5 actually gets -0.5.
	Terrain:FillCylinder(CFrame.new(CX, -14, CZ), 12, 620, Enum.Material.Sandstone)
	Terrain:FillCylinder(CFrame.new(CX, -4.25, CZ), 7.5, 620, Enum.Material.Water)

	-- The island, as a short stack of discs.
	--
	-- THE HEIGHTS HERE ARE NOT THE HEIGHTS YOU GET. Fill* rounds to whole
	-- voxels, and smooth terrain renders its surface at the CENTRE of the first
	-- non-full voxel -- so a cylinder filled to y = 0 comes out rendering at
	-- y = 2, and one filled to y = 3 comes out at y = 6. The rakeable field
	-- renders at exactly 3.0 (occupancy 0.25 of the 0..4 voxel, from
	-- Config.occupancyFor), so filling the plateau "to 3" would leave the field
	-- sitting in a three-stud pit with a wall round it.
	--
	-- So the plateau is filled to y = 0 and flattenTop() below writes the 0..4
	-- layer explicitly, at the same occupancy the field uses. Only whole-voxel
	-- heights are used here; anything finer has to go through WriteVoxels.
	for _, ring in ipairs({
		{ r = SHORE_R, top = -4 },        -- submerged shelf, renders at -2
		{ r = 320, top = 0 },             -- wet sand at the waterline, renders at 2
		{ r = PLATEAU_R, top = 0 },       -- the island proper, lifted to 3.0 below
	}) do
		local bottom = -20
		Terrain:FillCylinder(CFrame.new(CX, (bottom + ring.top) * 0.5, CZ),
			ring.top - bottom, ring.r, Enum.Material.Sandstone)
	end

	-- Lift the plateau to exactly the field's surface height, one voxel layer,
	-- with the same occupancy split the field is written at. This is what makes
	-- the rakeable square flush with the sand around it.
	do
		local _, o3 = Config.occupancyFor(GROUND)
		local R = PLATEAU_R
		local x0, z0 = CX - R - 4, CZ - R - 4
		local n = math.ceil((R + 4) * 2 / Config.VOXEL)
		local region = Region3.new(
			Vector3.new(x0, 0, z0),
			Vector3.new(x0 + n * Config.VOXEL, Config.VOXEL, z0 + n * Config.VOXEL)
		):ExpandToGrid(Config.VOXEL)

		local mats, occs = table.create(n), table.create(n)
		for xi = 1, n do
			local mx, ox = { table.create(n) }, { table.create(n) }
			mats[xi], occs[xi] = mx, ox
			local wx = x0 + (xi - 0.5) * Config.VOXEL
			for zi = 1, n do
				local wz = z0 + (zi - 0.5) * Config.VOXEL
				local dx, dz = wx - CX, wz - CZ
				if dx * dx + dz * dz <= R * R then
					mx[1][zi], ox[1][zi] = ISL.matMessy, o3
				else
					-- outside the plateau this layer is already empty (the rings are
					-- filled to y = 0), so writing Air here changes nothing
					mx[1][zi], ox[1][zi] = Enum.Material.Air, 0
				end
			end
		end
		Terrain:WriteVoxels(region, Config.VOXEL, mats, occs)
	end

	-- Dunes. Balls sunk to just under half their radius, so each shows a little
	-- over half of itself and the overlaps run together into a ridge rather than
	-- a row of bubbles. They ring the plateau, which walls the island in without
	-- needing an invisible barrier and gives the flat field something to sit in.
	local dunes = 0
	for i = 1, 260 do
		local ang = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(196, 288)
		local r = rng:NextNumber(34, 74)
		local x = CX + math.cos(ang) * dist
		local z = CZ + math.sin(ang) * dist
		if openGround(x, z, r) and dunes < 46 then
			-- taller the further out, so the ring rises toward the shoreline and
			-- closes the horizon off. A ball sunk to (1 - lift) of its radius shows
			-- lift * r above the sand: at 0.55-0.72 the big ones top out around 50
			-- studs, which is what it takes to read as a dune WALL rather than as
			-- the gentle mounds the first pass produced.
			local lift = 0.55 + (dist - 196) / 92 * 0.17
			Terrain:FillBall(Vector3.new(x, GROUND - r * (1 - lift), z), r, Enum.Material.Sandstone)
			dunes += 1
		end
	end

	-- A few smaller drifts inside the ring, to break up the walk out to the field
	for i = 1, 120 do
		local ang = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(120, 200)
		local r = rng:NextNumber(14, 26)
		local x = CX + math.cos(ang) * dist
		local z = CZ + math.sin(ang) * dist
		if openGround(x, z, r) then
			Terrain:FillBall(Vector3.new(x, GROUND - r * 0.72, z), r, Enum.Material.Sandstone)
		end
	end

	-- Rock outcrops. A different terrain material, so they carry their own tint
	-- (see applyLook in CTB_Server) and read as bedrock poking through the sand
	-- rather than as more sand.
	local rocks = 0
	for i = 1, 160 do
		local ang = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(130, 270)
		local r = rng:NextNumber(9, 22)
		local x = CX + math.cos(ang) * dist
		local z = CZ + math.sin(ang) * dist
		if openGround(x, z, r) and rocks < 22 then
			Terrain:FillBall(Vector3.new(x, GROUND - r * 0.42, z), r, Enum.Material.Rock)
			-- a smaller cap of the darker stone, so the outcrop has an edge
			Terrain:FillBall(Vector3.new(x + rng:NextNumber(-4, 4), GROUND + r * 0.28, z + rng:NextNumber(-4, 4)),
				r * 0.45, Enum.Material.Slate)
			rocks += 1
		end
	end

	-- The oasis: carve a bowl out of the plateau, floor it, then pour. Whole
	-- voxel heights again -- the pool renders at y = 2, a stud under the sand,
	-- so it reads as sunk into the ground rather than sitting on it.
	Terrain:FillCylinder(CFrame.new(1301, 4, 151), 24, 34, Enum.Material.Air)
	Terrain:FillCylinder(CFrame.new(1301, -10, 151), 8, 38, Enum.Material.Sandstone)
	Terrain:FillCylinder(CFrame.new(1301, -3, 151), 6, 30, Enum.Material.Water)

	return dunes, rocks
end

----------------------------------------------------------------
-- The pyramid
--
-- 26 courses of solid stone, each one PY_STEP narrower per side than the one
-- under it. The bottom seven are not solid: the corridor and burial chamber are
-- a single rectangle punched through them by subtractRect, which is how the
-- inside gets hollowed without any CSG. Above HALL_TOP the courses close over
-- and become the chamber's ceiling.
----------------------------------------------------------------
local function buildPyramid(parent)
	local pyr = Instance.new("Model")
	pyr.Name = "Pyramid"
	pyr.Parent = parent

	local void = { x0 = CX - HALL_HALF, x1 = CX + HALL_HALF, z0 = FACE_Z, z1 = HALL_BACK }

	for k = 0, PY_COURSES - 1 do
		local half = PY_BASE_HALF - k * PY_STEP
		local y0 = GROUND + k * PY_COURSE_H
		local y1 = y0 + PY_COURSE_H
		local rect = { x0 = CX - half, x1 = CX + half, z0 = PZ - half, z1 = PZ + half }
		local pieces = (y0 < HALL_TOP) and subtractRect(rect, void) or { rect }
		-- Alternating tones so the courses still read as separate blocks from a
		-- distance where the 3-stud step itself is too small to see.
		local tone = (k % 2 == 0) and STONE or Color3.fromRGB(236, 192, 124)
		for i, r in ipairs(pieces) do
			box(pyr, string.format("Course%02d_%d", k, i), r.x0, r.x1, y0, y1, r.z0, r.z1,
				tone, Enum.Material.Sandstone)
		end
	end

	-- Gold capstone. Stacked shrinking blocks rather than wedges, so it is the
	-- same silhouette language as the courses underneath and cannot come out
	-- mis-rotated the way a four-wedge pyramidion can.
	local apexY = GROUND + PY_COURSES * PY_COURSE_H
	local capHalf = PY_TOP_HALF + 1.6
	for i = 0, 5 do
		local h = capHalf * (1 - i / 6)
		box(pyr, "Cap" .. i, CX - h, CX + h, apexY + i * 1.5, apexY + (i + 1) * 1.5,
			PZ - h, PZ + h, GOLD, Enum.Material.Metal, { Reflectance = 0.28 })
	end
	local glow = P(pyr, "ApexGlow", Vector3.new(2.4, 2.4, 2.4),
		CFrame.new(CX, apexY + 9.6, PZ), GOLD, Enum.Material.Neon, { CanCollide = false })
	local pl = Instance.new("PointLight")
	pl.Color = Color3.fromRGB(255, 216, 140)
	pl.Range = 46
	pl.Brightness = 2.2
	pl.Parent = glow

	return pyr
end

----------------------------------------------------------------
-- The entrance porch, and the door
--
-- The porch is not decoration. The pyramid's face slopes back as it rises, so
-- by the time the corridor is 21 studs tall the stone in front of it has
-- receded 13 studs -- the hall would be open to the sky at the front. The porch
-- walls and roof close that off, and give the door something to sit in.
----------------------------------------------------------------
local function buildPorch(parent)
	local porch = Instance.new("Model")
	porch.Name = "Entrance"
	porch.Parent = parent

	local PZ0, PZ1 = 126, 146           -- the porch's own depth
	local top = GROUND + 30

	-- flanking pylon towers, flush with the corridor walls
	box(porch, "PylonL", CX - 24, CX - HALL_HALF, GROUND, top, PZ0, PZ1, STONE, Enum.Material.Sandstone)
	box(porch, "PylonR", CX + HALL_HALF, CX + 24, GROUND, top, PZ0, PZ1, STONE, Enum.Material.Sandstone)
	-- roof, which is also the lid over the front of the corridor
	box(porch, "PorchRoof", CX - 24, CX + 24, GROUND + 24, top, PZ0, PZ1, STONE_DARK, Enum.Material.Sandstone)
	-- cornice, so the roofline has an edge rather than stopping dead
	box(porch, "Cornice", CX - 26, CX + 26, top, top + 2.2, PZ0 - 1.4, PZ1, SAND_PALE, Enum.Material.Sandstone)

	-- the doorway itself, in a 4-stud-thick front wall
	local hw = DOOR_W * 0.5
	box(porch, "JambL", CX - HALL_HALF, CX - hw, GROUND, GROUND + DOOR_H, PZ0, PZ0 + 4, SAND_PALE)
	box(porch, "JambR", CX + hw, CX + HALL_HALF, GROUND, GROUND + DOOR_H, PZ0, PZ0 + 4, SAND_PALE)
	box(porch, "Lintel", CX - HALL_HALF, CX + HALL_HALF, GROUND + DOOR_H, GROUND + 24, PZ0, PZ0 + 4, SAND_PALE)

	-- painted bands: cheap, and they are what stops the facade reading as a
	-- blank wall with a hole in it
	box(porch, "BandLapis", CX - HALL_HALF, CX + HALL_HALF, GROUND + 22.4, GROUND + 23.4,
		PZ0 - 0.35, PZ0, LAPIS, Enum.Material.SmoothPlastic)
	box(porch, "BandGold", CX - HALL_HALF, CX + HALL_HALF, GROUND + 21.2, GROUND + 22.2,
		PZ0 - 0.35, PZ0, GOLD, Enum.Material.Metal)
	for i = 0, 5 do
		local c = ({ CARNELIAN, TURQUOISE, LAPIS, GOLD, TURQUOISE, CARNELIAN })[i + 1]
		box(porch, "Glyph" .. i, CX - 22.6 + i * 1.2, CX - 21.8 + i * 1.2,
			GROUND + 4 + i * 2.6, GROUND + 6 + i * 2.6, PZ0 - 0.35, PZ0, c, Enum.Material.SmoothPlastic)
		box(porch, "GlyphR" .. i, CX + 21.8 - i * 1.2, CX + 22.6 - i * 1.2,
			GROUND + 4 + i * 2.6, GROUND + 6 + i * 2.6, PZ0 - 0.35, PZ0, c, Enum.Material.SmoothPlastic)
	end

	-- Paved forecourt. Wide enough to run out past the obelisks and only a shade
	-- off the sand -- the first pass was narrow and dark and read as a rug thrown
	-- down in front of the door.
	box(porch, "Forecourt", CX - 42, CX + 42, GROUND - 0.1, GROUND + 0.22, 96, PZ0,
		Color3.fromRGB(214, 172, 112), Enum.Material.Slate, { CanCollide = false })
	for i = -3, 3 do
		box(porch, "Flag" .. i, CX + i * 12 - 0.25, CX + i * 12 + 0.25, GROUND + 0.22, GROUND + 0.3,
			96, PZ0, Color3.fromRGB(188, 146, 92), Enum.Material.Slate, { CanCollide = false })
	end

	-- THE DOOR. A slab in the opening, and nothing else touches it.
	local door = P(porch, "Door", Vector3.new(DOOR_W, DOOR_H, 2.8),
		CFrame.new(CX, GROUND + DOOR_H * 0.5, PZ0 + 2),
		GRANITE, Enum.Material.Slate)
	door.CanCollide = true

	-- a seal on the face of it, so the thing you click looks clickable
	local seal = P(porch, "DoorSeal", Vector3.new(4.6, 4.6, 0.4),
		CFrame.new(CX, GROUND + DOOR_H * 0.55, PZ0 + 0.5),
		GOLD, Enum.Material.Metal, { CanCollide = false, Reflectance = 0.25 })
	local ring = P(porch, "DoorRing", Vector3.new(2.4, 2.4, 0.5),
		CFrame.new(CX, GROUND + DOOR_H * 0.55, PZ0 + 0.35),
		LAPIS, Enum.Material.SmoothPlastic, { CanCollide = false, Shape = Enum.PartType.Cylinder })
	ring.CFrame = ring.CFrame * CFrame.Angles(0, math.rad(90), 0)

	return porch, door, seal
end

----------------------------------------------------------------
-- Inside: corridor and burial chamber
----------------------------------------------------------------
local function buildChamber(parent)
	local room = Instance.new("Model")
	room.Name = "Chamber"
	room.Parent = parent

	local x0, x1 = CX - HALL_HALF, CX + HALL_HALF

	-- Floor, laid over the terrain so the inside is not raw sand. It starts two
	-- studs back from the face so the door -- which sinks into the ground to open
	-- -- does not have to pass through it.
	box(room, "Floor", x0, x1, GROUND - 0.05, GROUND + 0.35, FACE_Z + 2, HALL_BACK,
		GRANITE, Enum.Material.Slate)

	-- pilasters down both walls, and a painted dado between them
	-- Interior stone runs darker than the outside. It is lit by torchlight at
	-- close range rather than by the sun at 80 studs, so the same value that
	-- reads as pale limestone outdoors reads as blown-out white in here.
	local WALL = Color3.fromRGB(196, 158, 104)
	for i = 0, 5 do
		local z = FACE_Z + 14 + i * 12
		for _, side in ipairs({ -1, 1 }) do
			local wx = CX + side * HALL_HALF
			box(room, "Pilaster", math.min(wx, wx - side * 1.2), math.max(wx, wx - side * 1.2),
				GROUND, GROUND + 16, z - 1.6, z + 1.6, WALL, Enum.Material.Sandstone,
				{ CanCollide = false })
			box(room, "PilasterCap", math.min(wx, wx - side * 1.6), math.max(wx, wx - side * 1.6),
				GROUND + 16, GROUND + 17.4, z - 2.2, z + 2.2, GOLD, Enum.Material.Metal,
				{ CanCollide = false })
		end
	end
	for _, side in ipairs({ -1, 1 }) do
		local wx = CX + side * HALL_HALF
		box(room, "Dado", math.min(wx, wx - side * 0.5), math.max(wx, wx - side * 0.5),
			GROUND + 8.4, GROUND + 9.6, FACE_Z + 4, HALL_BACK - 2, LAPIS,
			Enum.Material.SmoothPlastic, { CanCollide = false })
	end

	-- braziers. Fire plus a PointLight each: without them the inside is a black
	-- hole, because the only opening is a 12x18 door under an overhang.
	for _, side in ipairs({ -1, 1 }) do
		for _, z in ipairs({ FACE_Z + 26, FACE_Z + 56 }) do
			local bx = CX + side * 9
			local bowl = P(room, "Brazier", Vector3.new(3.4, 1.6, 3.4),
				CFrame.new(bx, GROUND + 6.2, z), Color3.fromRGB(120, 92, 58), Enum.Material.Metal,
				{ Shape = Enum.PartType.Cylinder, CanCollide = false })
			bowl.CFrame = bowl.CFrame * CFrame.Angles(0, 0, math.rad(90))
			P(room, "BrazierStem", Vector3.new(0.9, 6, 0.9), CFrame.new(bx, GROUND + 3, z),
				Color3.fromRGB(102, 78, 50), Enum.Material.Metal, { CanCollide = false })
			local fire = Instance.new("Fire")
			fire.Heat = 3
			fire.Size = 4.5
			fire.Color = Color3.fromRGB(255, 186, 90)
			fire.SecondaryColor = Color3.fromRGB(190, 96, 30)
			fire.Parent = bowl
			-- Four of these in a 28x78 stone box, on top of the warm ambient the
			-- client fades in on arrival. At the 34 range and 2.6 brightness this
			-- started at, the chamber blew out to flat yellow and none of the
			-- detail in it -- sarcophagus, urns, the painted dado -- was readable.
			-- They want to pick out the walls, not light the room.
			local light = Instance.new("PointLight")
			light.Color = Color3.fromRGB(255, 178, 96)
			light.Range = 24
			light.Brightness = 1
			light.Shadows = true
			light.Parent = bowl
		end
	end

	-- the sarcophagus, at the far end facing the door
	local sz = HALL_BACK - 12
	box(room, "Dais", CX - 9, CX + 9, GROUND + 0.35, GROUND + 1.6, sz - 8, sz + 8,
		STONE_DARK, Enum.Material.Slate)
	box(room, "Sarcophagus", CX - 3.6, CX + 3.6, GROUND + 1.6, GROUND + 6.4, sz - 6, sz + 6,
		GRANITE, Enum.Material.Slate)
	box(room, "Lid", CX - 4.1, CX + 4.1, GROUND + 6.4, GROUND + 7.2, sz - 6.4, sz + 6.4,
		GOLD, Enum.Material.Metal, { Reflectance = 0.22 })
	-- a mask on the lid, so it is obviously a coffin and not a crate
	box(room, "Mask", CX - 2.2, CX + 2.2, GROUND + 7.2, GROUND + 8.1, sz - 5.2, sz - 0.6,
		GOLD, Enum.Material.Metal, { Reflectance = 0.3 })
	box(room, "MaskStripe", CX - 2.4, CX + 2.4, GROUND + 7.3, GROUND + 8.2, sz - 3.4, sz - 2.6,
		LAPIS, Enum.Material.SmoothPlastic, { CanCollide = false })

	-- treasure. Cheap parts, but the payoff for opening the door has to be
	-- something rather than an empty room.
	local rng = Random.new(Config.SEED + 77)
	for i = 1, 14 do
		local a = rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(3, 11)
		local px = CX + math.cos(a) * r
		local pz = sz + math.sin(a) * r * 0.8
		local s = rng:NextNumber(1.1, 2.4)
		P(room, "Treasure", Vector3.new(s, s * 0.7, s),
			CFrame.new(px, GROUND + 1.9, pz) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
			GOLD, Enum.Material.Metal, { CanCollide = false, Reflectance = 0.3 })
	end
	for i = 1, 4 do
		local side = (i % 2 == 0) and 1 or -1
		local urn = P(room, "Urn", Vector3.new(2.6, 4.2, 2.6),
			CFrame.new(CX + side * 11, GROUND + 2.4, sz - 9 + math.floor((i - 1) / 2) * 15),
			WALL, Enum.Material.Sandstone, { CanCollide = false })
		P(room, "UrnLid", Vector3.new(1.4, 1.6, 1.4),
			urn.CFrame * CFrame.new(0, 2.9, 0), GOLD, Enum.Material.Metal, { CanCollide = false })
	end

	return room
end

----------------------------------------------------------------
-- The statue at the entrance
--
-- A pharaoh on a plinth, standing on the approach axis about 15 studs clear of
-- the porch, facing OUT -- so the first thing a player walking up from the dock
-- sees is the statue looking back at them, with the pyramid behind it.
--
-- Built from bounds rather than a rotated local frame because it faces -Z,
-- which is a principal axis; every number below is a world coordinate.
----------------------------------------------------------------
local SZ = 112

local function buildStatue(parent)
	local m = Instance.new("Model")
	m.Name = "PharaohStatue"
	m.Parent = parent

	local G = GROUND
	local SANDSTONE = Enum.Material.Sandstone
	local BODY = Color3.fromRGB(214, 178, 122)

	-- plinth
	box(m, "Step", CX - 12, CX + 12, G, G + 1.2, SZ - 9, SZ + 9, STONE_DARK, Enum.Material.Slate)
	box(m, "Plinth", CX - 10, CX + 10, G + 1.2, G + 6, SZ - 7.5, SZ + 7.5, STONE, SANDSTONE)
	box(m, "PlinthBand", CX - 8, CX + 8, G + 2.6, G + 4.4, SZ - 7.7, SZ - 7.4, LAPIS,
		Enum.Material.SmoothPlastic, { CanCollide = false })
	for i = 0, 4 do
		box(m, "PlinthGlyph" .. i, CX - 6.6 + i * 3, CX - 5.4 + i * 3, G + 2.9, G + 4.1,
			SZ - 7.85, SZ - 7.65, GOLD, Enum.Material.Metal, { CanCollide = false })
	end

	-- legs, kilt, torso
	box(m, "Legs", CX - 5.5, CX + 5.5, G + 6, G + 19, SZ - 4, SZ + 4, BODY, SANDSTONE)
	box(m, "LegSplit", CX - 0.35, CX + 0.35, G + 6, G + 14, SZ - 4.1, SZ - 3.2, STONE_DARK,
		SANDSTONE, { CanCollide = false })
	box(m, "Kilt", CX - 5.9, CX + 5.9, G + 13, G + 18.4, SZ - 4.7, SZ - 3.5, GOLD,
		Enum.Material.Metal, { CanCollide = false })
	box(m, "Belt", CX - 6, CX + 6, G + 18.4, G + 19.6, SZ - 4.2, SZ + 4.2, CARNELIAN,
		Enum.Material.SmoothPlastic, { CanCollide = false })
	box(m, "Torso", CX - 6, CX + 6, G + 19, G + 31, SZ - 3.7, SZ + 3.7, BODY, SANDSTONE)
	box(m, "Shoulders", CX - 7.8, CX + 7.8, G + 28.8, G + 32.5, SZ - 4, SZ + 4, BODY, SANDSTONE)

	-- arms held down at the sides, fists forward, the standing-colossus pose
	for _, side in ipairs({ -1, 1 }) do
		local ax = CX + side * 6.9
		box(m, "Arm", ax - 1.3, ax + 1.3, G + 19, G + 30, SZ - 3.4, SZ + 2.6, BODY, SANDSTONE)
		box(m, "Fist", ax - 1.5, ax + 1.5, G + 17.4, G + 20, SZ - 4.4, SZ - 1.4, BODY, SANDSTONE)
	end

	-- broad collar
	box(m, "Collar", CX - 5.8, CX + 5.8, G + 27.4, G + 30.2, SZ - 4.1, SZ - 3.3, GOLD,
		Enum.Material.Metal, { CanCollide = false })
	box(m, "CollarInlay", CX - 4.4, CX + 4.4, G + 28.1, G + 29.3, SZ - 4.25, SZ - 4.05,
		TURQUOISE, Enum.Material.SmoothPlastic, { CanCollide = false })

	-- head, and the nemes headdress that does most of the work of saying Egypt
	box(m, "Neck", CX - 1.9, CX + 1.9, G + 32.5, G + 34.8, SZ - 1.8, SZ + 1.8, BODY, SANDSTONE)
	box(m, "Head", CX - 3.3, CX + 3.3, G + 34.8, G + 41, SZ - 3.2, SZ + 2.6, BODY, SANDSTONE)
	box(m, "NemesBack", CX - 4.1, CX + 4.1, G + 31.5, G + 41.4, SZ + 2, SZ + 4.6, GOLD,
		Enum.Material.Metal)
	for _, side in ipairs({ -1, 1 }) do
		local lx = CX + side * 4.5
		box(m, "Lappet", lx - 1.4, lx + 1.4, G + 30, G + 41.4, SZ - 3.4, SZ + 1.6, GOLD,
			Enum.Material.Metal)
		box(m, "LappetStripe", lx - 1.5, lx + 1.5, G + 33.4, G + 34.6, SZ - 3.5, SZ + 1.7,
			LAPIS, Enum.Material.SmoothPlastic, { CanCollide = false })
	end
	box(m, "NemesCap", CX - 4.5, CX + 4.5, G + 40.4, G + 44, SZ - 3.5, SZ + 3.6, GOLD,
		Enum.Material.Metal)
	box(m, "BrowBand", CX - 4.6, CX + 4.6, G + 39.4, G + 40.9, SZ - 3.6, SZ - 3.1, LAPIS,
		Enum.Material.SmoothPlastic, { CanCollide = false })
	-- uraeus: the cobra on the brow, and the single clearest signifier on the whole
	-- statue, so it gets its own two parts
	box(m, "Uraeus", CX - 0.8, CX + 0.8, G + 40.6, G + 43.2, SZ - 3.7, SZ - 3.1, GOLD,
		Enum.Material.Metal, { CanCollide = false })
	box(m, "UraeusHood", CX - 1.3, CX + 1.3, G + 42.4, G + 43.6, SZ - 3.9, SZ - 3.2, CARNELIAN,
		Enum.Material.SmoothPlastic, { CanCollide = false })

	-- face
	for _, side in ipairs({ -1, 1 }) do
		local ex = CX + side * 1.55
		box(m, "Eye", ex - 0.75, ex + 0.75, G + 37.6, G + 38.5, SZ - 3.4, SZ - 3.15, GRANITE,
			Enum.Material.SmoothPlastic, { CanCollide = false })
		box(m, "EyeLine", ex - 1.1, ex + 1.1, G + 38.5, G + 38.9, SZ - 3.4, SZ - 3.15, LAPIS,
			Enum.Material.SmoothPlastic, { CanCollide = false })
	end
	box(m, "Beard", CX - 1.3, CX + 1.3, G + 31.2, G + 35.2, SZ - 3.7, SZ - 2.5, GOLD,
		Enum.Material.Metal, { CanCollide = false })

	-- Built on the centre line for readable coordinates, then stepped aside.
	--
	-- It CANNOT stay on the axis: 44 studs of pharaoh standing 14 studs in front
	-- of a 12x18 doorway hides the door completely from the whole approach, and
	-- the door is the one thing on this island the player has to find and click.
	-- Off to the left it still reads as guarding the entrance, and the obelisks
	-- keep the doorway itself framed.
	m:PivotTo(m:GetPivot() + Vector3.new(-42, 0, -4))

	return m
end

local function buildObelisk(parent, x, z)
	local m = Instance.new("Model")
	m.Name = "Obelisk"
	m.Parent = parent
	local G = GROUND
	box(m, "Base", x - 3.6, x + 3.6, G, G + 2.4, z - 3.6, z + 3.6, STONE_DARK, Enum.Material.Slate)
	-- a taper in five steps: a straight column reads as a pillar, and the taper is
	-- what makes it an obelisk
	for i = 0, 4 do
		local h = 2.4 - i * 0.24
		box(m, "Shaft" .. i, x - h, x + h, G + 2.4 + i * 6.4, G + 2.4 + (i + 1) * 6.4,
			z - h, z + h, STONE, Enum.Material.Sandstone)
		box(m, "ShaftGlyph" .. i, x - 0.7, x + 0.7, G + 5 + i * 6.4, G + 7.4 + i * 6.4,
			z - h - 0.16, z - h, CARNELIAN, Enum.Material.SmoothPlastic, { CanCollide = false })
	end
	for i = 0, 2 do
		local h = 1.2 * (1 - i / 3)
		box(m, "Cap" .. i, x - h, x + h, G + 34.4 + i * 1.1, G + 34.4 + (i + 1) * 1.1,
			z - h, z + h, GOLD, Enum.Material.Metal, { Reflectance = 0.3 })
	end
	return m
end

----------------------------------------------------------------
-- Cactuses
----------------------------------------------------------------
local function buildCactus(parent, x, z, scale, yaw)
	local m = Instance.new("Model")
	m.Name = "Cactus"
	m.Parent = parent
	local G = GROUND
	local r = 1.5 * scale
	local h = 13 * scale

	local function limb(name, len, cf)
		local p = P(m, name, Vector3.new(len, r * 2, r * 2), cf, CACTUS_GREEN,
			Enum.Material.Grass, { Shape = Enum.PartType.Cylinder })
		return p
	end
	local function cap(name, pos, rad)
		P(m, name, Vector3.new(rad * 2, rad * 2, rad * 2), CFrame.new(pos), CACTUS_GREEN,
			Enum.Material.Grass, { Shape = Enum.PartType.Ball, CanCollide = false })
	end

	local base = CFrame.new(x, G, z) * CFrame.Angles(0, yaw, 0)
	-- Part shape Cylinder runs along its LOCAL X, so every limb below is turned a
	-- quarter turn about Z to stand it up (or left flat, for the arms).
	limb("Trunk", h, base * CFrame.new(0, h * 0.5, 0) * CFrame.Angles(0, 0, math.rad(90)))
	cap("TrunkTop", (base * CFrame.new(0, h, 0)).Position, r)

	for _, side in ipairs({ -1, 1 }) do
		local armY = h * (side < 0 and 0.5 or 0.62)
		local reach = 3.4 * scale
		local up = 4.4 * scale
		limb("ArmOut", reach, base * CFrame.new(side * reach * 0.5, armY, 0))
		limb("ArmUp", up, base * CFrame.new(side * reach, armY + up * 0.5 - r, 0)
			* CFrame.Angles(0, 0, math.rad(90)))
		cap("ArmTop", (base * CFrame.new(side * reach, armY + up - r, 0)).Position, r)
	end
	return m
end

----------------------------------------------------------------
-- The camel
--
-- Built here so every player has one in the same place, but WALKED on the
-- client (see Island2_Client). The patrol is a closed loop driven off
-- workspace:GetServerTimeNow(), which every client agrees on, so all of them
-- draw the camel in the same spot without a single byte crossing the network.
--
-- CanCollide is off on every part. It is an anchored model being re-CFramed
-- every frame, and a collidable one of those shoves players around and can wedge
-- them into terrain.
----------------------------------------------------------------
local CAMEL_CENTRE = Vector3.new(1400, GROUND, -150)
local CAMEL_R = 38

local function buildCamel(parent)
	local m = Instance.new("Model")
	m.Name = "Camel"
	m.Parent = parent

	local HIDE = Color3.fromRGB(198, 156, 102)
	local HIDE_DARK = Color3.fromRGB(172, 130, 80)
	local base = CFrame.new(CAMEL_CENTRE + Vector3.new(CAMEL_R, 0, 0))

	local root = P(m, "Root", Vector3.new(1, 1, 1), base, HIDE, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
	m.PrimaryPart = root

	local function piece(name, size, offset, colour, material)
		return P(m, name, size, base * offset, colour or HIDE, material or Enum.Material.SmoothPlastic,
			{ CanCollide = false, CanQuery = false })
	end

	piece("Body", Vector3.new(4.2, 4.6, 10), CFrame.new(0, 7.5, 0))
	piece("HumpA", Vector3.new(3.4, 3.2, 3.8), CFrame.new(0, 10.6, -1.2), HIDE_DARK)
	piece("HumpB", Vector3.new(3.0, 2.6, 3.2), CFrame.new(0, 10.2, 2.2), HIDE_DARK)
	piece("Blanket", Vector3.new(4.5, 0.5, 5.4), CFrame.new(0, 9.9, 0.4), CARNELIAN)
	piece("BlanketTrim", Vector3.new(4.6, 0.3, 1.0), CFrame.new(0, 10.05, -1.9), TURQUOISE)

	-- neck leans forward; the head sits on the end of it
	piece("Neck", Vector3.new(2.2, 7.0, 2.4), CFrame.new(0, 11.6, 4.2) * CFrame.Angles(math.rad(24), 0, 0))
	piece("Head", Vector3.new(1.9, 2.2, 3.6), CFrame.new(0, 14.9, 6.4) * CFrame.Angles(math.rad(-8), 0, 0))
	piece("Snout", Vector3.new(1.5, 1.4, 2.0), CFrame.new(0, 14.2, 7.9), HIDE_DARK)
	for _, side in ipairs({ -1, 1 }) do
		piece("Ear", Vector3.new(0.4, 1.0, 0.8), CFrame.new(side * 0.9, 16.1, 5.6), HIDE_DARK)
		piece("Eye", Vector3.new(0.35, 0.4, 0.4), CFrame.new(side * 0.95, 15.4, 6.9), GRANITE)
	end
	piece("Tail", Vector3.new(0.55, 3.6, 0.55), CFrame.new(0, 8.4, -5.3) * CFrame.Angles(math.rad(18), 0, 0), HIDE_DARK)

	-- Legs. HipY is where the client pivots them from -- the top of the leg, not
	-- its centre -- so a swing looks like it comes from the shoulder.
	local LEG_H = 6.6
	for _, spec in ipairs({
		{ "LegFL", -1.5, 3.4 }, { "LegFR", 1.5, 3.4 },
		{ "LegBL", -1.5, -3.4 }, { "LegBR", 1.5, -3.4 },
	}) do
		local leg = piece(spec[1], Vector3.new(1.2, LEG_H, 1.2), CFrame.new(spec[2], LEG_H * 0.5, spec[3]))
		leg:SetAttribute("HipY", LEG_H * 0.5)
		piece(spec[1] .. "Hoof", Vector3.new(1.45, 0.7, 1.6), CFrame.new(spec[2], 0.35, spec[3]), HIDE_DARK)
	end

	-- Patrol parameters, read by the client so the two never disagree about
	-- where the loop is.
	m:SetAttribute("CentreX", CAMEL_CENTRE.X)
	m:SetAttribute("CentreZ", CAMEL_CENTRE.Z)
	m:SetAttribute("Radius", CAMEL_R)
	m:SetAttribute("Period", 96)          -- seconds for one lap

	local body = m:FindFirstChild("Body")
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Pet"
	prompt.ObjectText = "Camel"
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = body

	return m
end

----------------------------------------------------------------
-- The bazaar (this island's sell pad) and the two travel gates
----------------------------------------------------------------
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace.Terrain }
groundParams.IgnoreWater = true

local function groundY(x: number, z: number, fallback: number): number
	local hit = workspace:Raycast(Vector3.new(x, 120, z), Vector3.new(0, -220, 0), groundParams)
	return hit and hit.Position.Y or fallback
end

-- The LOWEST ground under a prop's own footprint, not the ground under its
-- centre pin.
--
-- One sample is enough for a cactus and wrong for a mesa. The plateau meshes
-- are 30 to 66 studs across and they are scattered on the dune RING, where the
-- sand falls away twenty studs from one side of a rock to the other -- so a
-- mesh seated on its centre sample stands with half of itself hanging in open
-- air. From the field it reads as a slab of rock floating over the dunes, which
-- is what this island actually looked like: the placement was never off, the
-- SAMPLE was.
--
-- Ringed rather than gridded because these meshes are cliffs: the geometry that
-- overhangs is at the edges, and the edges are what has to have sand under it.
-- 0.55 of the footprint rather than the full width, because a bounding box on a
-- cliff mesh is mostly empty and sampling the corners would seat every rock in
-- whatever hollow happens to lie beside it.
--
-- The clamp is the other half of the trade. Seating to the lowest sample buries
-- a prop on a slope deeper than seating to its centre would, and buried rock
-- still reads as rock -- but only down to a point, and a whole mesa lost inside
-- a dune is no better than one floating over it.
--
-- It is measured against the footprint as well as the height, because the flat
-- ground slabs are two studs thick and thirty across: a clamp off the height
-- alone stops them a long way short of the sand on a slope, which is the one
-- shape this pass would otherwise still leave hanging. What keeps a wide slab
-- visible is its LENGTH -- there is always some of it out on the low side.
local function groundUnder(x: number, z: number, footprint: number, height: number,
	fallback: number): number

	local centre = groundY(x, z, fallback)
	if footprint <= 6 then
		return centre
	end
	local r = footprint * 0.55
	local lowest = centre
	for i = 1, 8 do
		local a = (i / 8) * math.pi * 2
		local h = groundY(x + math.cos(a) * r, z + math.sin(a) * r, fallback)
		if h < lowest then
			lowest = h
		end
	end
	return math.max(lowest, centre - math.max(height, footprint * 0.25) * 0.6)
end

-- Terrain COLLISION is rebuilt a frame or so behind the voxel write, so a
-- raycast fired in the same tick as a Fill* misses and reports nothing there.
-- Everything scattered below is placed by raycast, so without this every cactus,
-- boulder and palm silently lands at the fallback height and floats over the
-- dunes -- which looks like a placement bug rather than a timing one.
local function waitForGround(): boolean
	for _ = 1, 240 do
		if workspace:Raycast(Vector3.new(CX, 120, CZ - 150), Vector3.new(0, -220, 0), groundParams) then
			return true
		end
		task.wait()
	end
	warn("[Dunes] terrain never became raycastable; scattered props will sit at ground level")
	return false
end

--[[
	THE MARKET

	Two stalls facing each other across a paved street, under an arch: the sell
	counter on the west, the upgrade counter on the east, and the walk up from the
	dock running between them.

	WHAT THIS REPLACES. One back wall, four bare posts and a run of awning slats
	standing on open sand, with seven crates and five urns dropped at random
	inside the footprint. The concept was right -- a counter under a striped
	awning is exactly what this island's shop should be -- but there was no
	building behind the counter, no floor under the player's feet, and nothing to
	walk along. Randomly placed stock is the specific thing that made it read as
	unfinished rather than as busy: a real stall stacks its crates.

	SYMMETRY IS THE POINT. Both stalls are one function called twice with `side`
	flipped, so the street cannot go lopsided and the accent colour is the only
	thing telling them apart -- carnelian sells, lapis upgrades. The local `a`
	coordinates below are measured OUTWARD from the street's centre line and
	mirrored by `side`, which is why none of this geometry is written twice.

	THE UPGRADE SHOP IS NOT A SECOND SHOP, and deliberately so. MenuHud opens the
	stock panel from any ProximityPrompt named "ShopPrompt", wherever it is in the
	world, and the purchase behind it re-derives level, cost and balance on the
	server. A desert counter carrying that prompt therefore sells the same five
	tracks the beach shop does, under the same rules, with not one line of stock
	list, pricing or purchase logic duplicated out here to drift.
]]
--[[
	THE MARKET IS A STREET, NOT A ROOM.

	It used to be a closed box: the arch across the south end, the water house
	square across the north end, and two stalls whose counters were 26 studs from
	the centre line -- a 34-stud lane with the sell pad, two floor mats and both
	awnings overhanging into it. A player who had just sold and upgraded then had
	to walk all the way back out through the arch and round the outside of the
	whole market to reach the sand again, which is the opposite of the loop this
	place exists to serve: sell, upgrade, straight back to sifting.

	So: the stalls stand further apart and further south, the lane runs all the
	way through to the field, and the water house steps off the centre line (see
	the pivot at the end of buildWashHouse). The three numbers below are the
	whole change; everything in the stalls is measured off them.
]]
local MKT_Z0, MKT_Z1 = -166, -122      -- a stall's footprint in z
local MKT_FRONT = 32                   -- centre line to a counter face
-- 46, not 60. At 34 studs deep the stalls were caves: everything against the
-- back wall sat too far in to read through the awning, and the inside went to
-- flat shadow -- which is most of what made the OLD bazaar look unfinished too.
-- A market stall is wide and shallow.
local MKT_BACK = 52                    -- centre line to a back wall
-- Moved south with the stalls. At -172 against a stall front of -166 the
-- gateway stood six studs off the first awning, which reads as a doorway rather
-- than as the head of a street.
local MKT_ARCH_Z = -180                -- the street's gateway
local MKT_APRON = MKT_FRONT - 9        -- how far the paved apron reaches in

local function buildStall(parent, name: string, side: number, accent: Color3, title: string,
	strap: string)

	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent

	local G = GROUND
	local F, B = MKT_FRONT, MKT_BACK
	local Z0, Z1 = MKT_Z0, MKT_Z1

	-- `a` runs OUTWARD from the street's centre line. This mirrors it onto
	-- whichever side the stall is on and hands `box` the sorted world bounds, so
	-- every number below reads the same for both stalls.
	local function bx(n, a0, a1, y0, y1, z0, z1, colour, material, extra)
		local w0, w1 = CX + side * a0, CX + side * a1
		if w0 > w1 then
			w0, w1 = w1, w0
		end
		return box(m, n, w0, w1, y0, y1, z0, z1, colour, material, extra)
	end

	-- Plinth and floor. A shop standing on its own step reads as built; the same
	-- shop standing on sand reads as parked. The apron carries out past the
	-- counter so the awning poles have something to stand on.
	bx("Plinth", MKT_APRON, B + 1.6, G - 0.8, G + 0.55, Z0 - 3, Z1 + 3, STONE_DARK, Enum.Material.Slate)
	bx("PlinthTrim", MKT_APRON - 0.6, B + 2.2, G - 0.2, G + 0.2, Z0 - 3.6, Z1 + 3.6, STONE,
		Enum.Material.Sandstone)
	bx("Floor", MKT_APRON, B, G + 0.55, G + 0.8, Z0, Z1, SAND_PALE, Enum.Material.Sandstone)

	-- Shell: back and two ends. The front stays open, because being able to see
	-- into a shop is most of the reason to build one.
	bx("BackWall", B - 2.4, B, G, G + 14, Z0, Z1, STONE, Enum.Material.Sandstone)
	bx("BackDado", B - 2.7, B - 2.4, G + 4.6, G + 6, Z0 + 0.4, Z1 - 0.4, accent,
		Enum.Material.SmoothPlastic, { CanCollide = false })
	for _, ez in ipairs({ { Z0, Z0 + 2.4 }, { Z1 - 2.4, Z1 } }) do
		bx("EndWall", F, B, G, G + 14, ez[1], ez[2], STONE, Enum.Material.Sandstone)
	end

	-- Pilasters across the front, three bays between them.
	for _, pz in ipairs({ Z0 + 3.4, Z0 + 17, Z1 - 17, Z1 - 3.4 }) do
		bx("Pilaster", F - 1.6, F + 1.6, G + 0.55, G + 14, pz - 1.7, pz + 1.7, STONE,
			Enum.Material.Sandstone)
		bx("PilasterBase", F - 2.1, F + 2.1, G + 0.55, G + 1.9, pz - 2.2, pz + 2.2, STONE_DARK,
			Enum.Material.Slate)
		bx("PilasterCap", F - 2.2, F + 2.2, G + 12.6, G + 14, pz - 2.3, pz + 2.3, SAND_PALE,
			Enum.Material.Sandstone)
		bx("PilasterBand", F - 1.9, F - 1.55, G + 7.4, G + 8.6, pz - 1.7, pz + 1.7, accent,
			Enum.Material.SmoothPlastic, { CanCollide = false })
	end

	-- Lintel, then a three-course cavetto cornice. The flare is what stops a
	-- rectangular building reading as a garage and starts it reading as Egyptian,
	-- and it costs three boxes.
	bx("Lintel", F - 2.4, B, G + 14, G + 16, Z0, Z1, STONE, Enum.Material.Sandstone)

	-- A glyph band across the lintel's face. Forty studs of blank sandstone at
	-- eye-line above the counter is the one surface on this building big enough
	-- to look unfinished -- and it is the surface a player spends the whole
	-- transaction looking at.
	local grng = Random.new(Config.SEED + 707 + (side > 0 and 31 or 0))
	local glyphInk = { GOLD, LAPIS, CARNELIAN, TURQUOISE }
	local gz = Z0 + 2.5
	while gz < Z1 - 4 do
		local w = grng:NextNumber(1.1, 2.6)
		bx("Glyph", F - 2.75, F - 2.4, G + 14.4, G + 15.6, gz, gz + w,
			glyphInk[grng:NextInteger(1, #glyphInk)], Enum.Material.SmoothPlastic,
			{ CanCollide = false })
		gz += w + grng:NextNumber(0.7, 1.6)
	end

	for i = 0, 2 do
		bx("Cornice" .. i, F - 2.4 - i * 0.8, B + 0.4 + i * 0.5,
			G + 16 + i * 0.75, G + 16.75 + i * 0.75,
			Z0 - i * 0.7, Z1 + i * 0.7,
			(i == 1) and GOLD or SAND_PALE,
			(i == 1) and Enum.Material.Metal or Enum.Material.Sandstone)
	end
	bx("Roof", F - 4.5, B + 2, G + 18.25, G + 19.1, Z0 - 2.1, Z1 + 2.1, STONE_DARK,
		Enum.Material.Slate)
	for i = 0, 8 do
		local tz = Z0 + 1 + (i + 0.5) * ((Z1 - Z0 - 2) / 9)
		bx("Merlon", F - 4.5, F - 2.8, G + 19.1, G + 20.6, tz - 1.5, tz + 1.5, SAND_PALE,
			Enum.Material.Sandstone)
	end

	-- Counter, with a dressed board on its front. The board is what tells you at
	-- a glance which of the two you are standing at.
	bx("CounterFront", F - 3.2, F - 2.2, G + 0.55, G + 4.4, Z0 + 4.6, Z1 - 4.6, STONE,
		Enum.Material.Sandstone)
	for _, iz in ipairs({ { Z0 + 5.4, Z0 + 13 }, { Z1 - 13, Z1 - 5.4 } }) do
		bx("CounterInlay", F - 3.4, F - 3.2, G + 2.1, G + 3.1, iz[1], iz[2], accent,
			Enum.Material.SmoothPlastic, { CanCollide = false })
	end
	bx("CounterTop", F - 4, F + 0.6, G + 4.4, G + 5.2, Z0 + 3.8, Z1 - 3.8, SAND_PALE,
		Enum.Material.Sandstone)
	bx("CounterLip", F - 4.35, F - 4, G + 4.4, G + 5.2, Z0 + 3.8, Z1 - 3.8, GOLD,
		Enum.Material.Metal)

	-- Awning: slats rather than one sheet, so it reads as cloth, and SLOPED,
	-- which the flat one was not. `box` only makes axis-aligned bricks, so these
	-- go through `P` with a roll about Z. The tilt is signed by `side` because
	-- the two stalls slope opposite ways in world space while sloping the same
	-- way in their own.
	local AW_RUN, AW_DROP = 8, 2.7
	local awLen = math.sqrt(AW_RUN * AW_RUN + AW_DROP * AW_DROP)
	local awTilt = side * math.atan2(AW_DROP, AW_RUN)
	local awMidX = CX + side * (F + 0.2 - AW_RUN * 0.5)
	local awMidY = G + 13.6 - AW_DROP * 0.5
	local slats = 15
	local pitch = (Z1 - Z0 - 4) / slats
	for i = 0, slats - 1 do
		local sz = Z0 + 2 + (i + 0.5) * pitch
		local warm = (i % 2 == 0)
		P(m, "AwningSlat", Vector3.new(awLen, 0.32, pitch * 0.88),
			CFrame.new(awMidX, awMidY, sz) * CFrame.Angles(0, 0, awTilt),
			warm and accent or SAND_PALE, Enum.Material.Fabric, { CanCollide = false })
		-- scalloped valance on the lip, offset a slat so the stripes alternate
		bx("Valance", F - 8.5, F - 7.5, G + 9.5, G + 10.95, sz - pitch * 0.44, sz + pitch * 0.44,
			warm and SAND_PALE or accent, Enum.Material.Fabric, { CanCollide = false })
	end
	for _, pz in ipairs({ Z0 + 2.6, Z1 - 2.6 }) do
		bx("AwningPole", F - 8.4, F - 7.6, G + 0.55, G + 10.95, pz - 0.45, pz + 0.45,
			Color3.fromRGB(122, 92, 58), Enum.Material.Wood)
		bx("PoleCap", F - 8.9, F - 7.1, G + 10.95, G + 11.6, pz - 0.8, pz + 0.8, GOLD,
			Enum.Material.Metal)
	end

	-- Lanterns under the lintel. They do almost nothing by day and are most of
	-- what the market is after sundown.
	for _, lz in ipairs({ Z0 + 13, Z1 - 13 }) do
		bx("LanternChain", F - 1.15, F - 0.85, G + 11.6, G + 14, lz - 0.15, lz + 0.15, GRANITE,
			Enum.Material.Metal, { CanCollide = false })
		local body = bx("LanternBody", F - 1.9, F - 0.1, G + 9.9, G + 11.6, lz - 0.9, lz + 0.9, GOLD,
			Enum.Material.Metal, { CanCollide = false, Reflectance = 0.3 })
		bx("LanternGlow", F - 1.55, F - 0.45, G + 10.1, G + 11.4, lz - 0.6, lz + 0.6,
			Color3.fromRGB(255, 216, 148), Enum.Material.Neon, { CanCollide = false })
		if body then
			--[[
				TURNED DOWN 2026-08. There are THREE lights in each of these stalls --
				two lanterns and the fill below -- and they add: the counter you read
				the prices off was sitting under 3.35 of brightness against the
				beach shop's single 1.0 bulb, which is what made the upgrades and
				sell stalls read as blown out next to every other shop in the game.
				The lantern is still the warm thing hanging under the lintel; it just
				no longer lights the whole street.
			]]
			local pl = Instance.new("PointLight")
			pl.Color = Color3.fromRGB(255, 198, 128)
			pl.Range = 20
			pl.Brightness = 0.75
			pl.Shadows = false
			pl.Parent = body
		end
	end

	-- Stock, ARRANGED. Same props the old bazaar had; the difference is entirely
	-- that they are stacked, lined up and leant against something.
	for col = 0, 1 do
		for row = 0, 1 do
			local cz = Z0 + 6.4 + col * 3.6
			local cy = G + 0.8 + row * 3.3
			bx("Crate", B - 6.4 + col * 0.5, B - 3.2 + col * 0.5, cy, cy + 3.2, cz, cz + 3.2,
				Color3.fromRGB(146, 110, 66), Enum.Material.Wood)
			bx("CrateBand", B - 6.55 + col * 0.5, B - 3.05 + col * 0.5, cy + 1.4, cy + 1.9,
				cz - 0.15, cz + 3.35, Color3.fromRGB(112, 84, 50), Enum.Material.Wood,
				{ CanCollide = false })
		end
	end
	for i = 0, 4 do
		local uz = Z1 - 21 + i * 3.5
		local h = (i % 2 == 0) and 3.6 or 2.8
		P(m, "Urn", Vector3.new(2.2, h, 2.2),
			CFrame.new(CX + side * (B - 4.4), G + 0.8 + h * 0.5, uz), SAND_PALE,
			Enum.Material.Sandstone)
		P(m, "UrnNeck", Vector3.new(1.15, 0.9, 1.15),
			CFrame.new(CX + side * (B - 4.4), G + 1.25 + h, uz), accent, Enum.Material.Sandstone,
			{ CanCollide = false })
	end
	for i = 0, 2 do
		P(m, "RolledRug", Vector3.new(1.6, 7.4, 1.6),
			CFrame.new(CX + side * (B - 5.2 - i * 1.9), G + 4.4, Z1 - 5.6)
				* CFrame.Angles(math.rad(-8), 0, 0),
			(i % 2 == 0) and accent or CARNELIAN, Enum.Material.Fabric, { CanCollide = false })
	end

	-- One warm fill at the back of each stall. Everything worth looking at in
	-- here is under a roof and behind an awning, and this island's sun comes in
	-- nearly vertically -- without it the stock is a silhouette in a black box.
	local glow = P(m, "StallLight", Vector3.new(1, 1, 1),
		CFrame.new(CX + side * (B - 8), G + 9.5, (Z0 + Z1) * 0.5), GOLD, Enum.Material.Neon,
		{ Transparency = 1, CanCollide = false, CanQuery = false })
	--[[
		RANGE 26, NOT 40, AND THAT IS THE HALF THAT MATTERED. Brightness sets how
		hard the fill is; RANGE sets how much of the island it covers, and at 40
		studs this one light reached well past its own stall and out into the
		street -- so the two counters were each washing the other's approach on top
		of their own lanterns. 26 keeps the stock lit, which is the whole job this
		light was added for (see the note above it), and stops at the awning.
	]]
	local fill = Instance.new("PointLight")
	fill.Color = Color3.fromRGB(255, 214, 158)
	fill.Range = 26
	fill.Brightness = 0.8
	fill.Shadows = false
	fill.Parent = glow

	-- Two mats out on the paving, split around the middle of the street so
	-- neither ends up underneath the sell pad. Bordered and striped rather than
	-- a flat rectangle of colour, which at this size reads as a sheet of paper
	-- somebody dropped.
	for _, mz in ipairs({ { Z0 + 5, Z0 + 14 }, { Z1 - 14, Z1 - 5 } }) do
		bx("MatEdge", MKT_APRON - 7.8, MKT_APRON + 0.4, G + 0.13, G + 0.2, mz[1] - 0.7, mz[2] + 0.7,
			SAND_DEEP, Enum.Material.Fabric, { CanCollide = false })
		bx("Mat", MKT_APRON - 7.2, MKT_APRON - 0.2, G + 0.2, G + 0.26, mz[1], mz[2],
			accent:Lerp(SAND_DEEP, 0.3), Enum.Material.Fabric, { CanCollide = false })
		for k = 0, 2 do
			local sz = mz[1] + 1.6 + k * ((mz[2] - mz[1] - 3.2) * 0.5)
			bx("MatStripe", MKT_APRON - 6.6, MKT_APRON - 0.8, G + 0.26, G + 0.31,
				sz - 0.45, sz + 0.45, SAND_PALE, Enum.Material.Fabric, { CanCollide = false })
		end
	end

	--[[
		The name board, standing on the parapet.

		It reads off a SIDE face, not the Front one the beachfront's boards use: a
		`box` part is axis-aligned, so a board whose readable face looks into the
		street presents its Right face on the west stall and its Left on the east.
		SignKit.faceStuds already measures a side face as Z by Y, so the fitting
		needs nothing special -- but the wrong NormalId here paints the lettering
		on the 0.8-stud edge, where it is invisible from everywhere.

		Pale sandstone board, so SignKit's contrast rule comes out ink-on-cream
		here where the beachfront's near-black boards come out cream-on-ink. Same
		rule, inverted -- which is what keeps a desert sign legible without
		breaking the set.
	]]
	local face = (side < 0) and Enum.NormalId.Right or Enum.NormalId.Left
	bx("SignTrim", F - 3.7, F - 3.05, G + 19.9, G + 26.7, Z0 + 5, Z1 - 5, GOLD, Enum.Material.Metal)
	local board = bx("SignBoard", F - 4.4, F - 3.7, G + 20.6, G + 26, Z0 + 6, Z1 - 6, SAND_PALE,
		Enum.Material.Sandstone)
	if board then
		SignKit.dress(board, title, { face })
	end

	-- and the strapline on the counter, which is what you actually read from
	-- twenty studs away with the awning over the name board
	local strapBoard = bx("StrapBoard", F - 3.45, F - 3.25, G + 1.5, G + 3.7, Z0 + 15, Z1 - 15,
		STONE_DARK, Enum.Material.Slate)
	if strapBoard then
		SignKit.dress(strapBoard, strap, { face })
	end

	return m
end

-- The street: paving, kerbs and the gateway at the south end of it.
local function buildMarketStreet(parent)
	local m = Instance.new("Model")
	m.Name = "MarketStreet"
	m.Parent = parent
	local G, AZ = GROUND, MKT_ARCH_Z
	-- The paving runs PAST the stalls now, right up to the edge of the rakeable
	-- field at z = -96. It used to stop six studs beyond the last stall, so the
	-- walk back out to the sand left the street and crossed bare ground -- which
	-- is exactly the stretch the player covers most often.
	local SZ0, SZ1 = AZ - 2, -98
	local HALF = MKT_APRON

	-- Collidable and 0.12 proud: the player walks ON the paving rather than
	-- through a decal of it, and 0.12 is under any step height that would ever
	-- catch a foot.
	box(m, "Paving", CX - HALF, CX + HALF, G - 0.5, G + 0.12, SZ0, SZ1, STONE,
		Enum.Material.Sandstone)
	for i = 1, 9 do
		local jz = SZ0 + i * ((SZ1 - SZ0) / 10)
		box(m, "Joint", CX - HALF, CX + HALF, G + 0.12, G + 0.18, jz - 0.3, jz + 0.3, STONE_DARK,
			Enum.Material.Slate, { CanCollide = false })
	end
	for _, s in ipairs({ -1, 1 }) do
		box(m, "Kerb", CX + s * HALF - 1.3, CX + s * HALF + 1.3, G + 0.12, G + 0.8, SZ0, SZ1,
			STONE_DARK, Enum.Material.Slate)
	end

	-- The gateway. Same pylon-and-lintel shape as the travel gates and the
	-- pyramid's porch, so the whole island reads as one mason's work.
	for _, s in ipairs({ -1, 1 }) do
		local gx = CX + s * (HALF + 5)
		box(m, "Pylon", gx - 5, gx + 5, G, G + 21, AZ - 3.4, AZ + 3.4, STONE, Enum.Material.Sandstone)
		box(m, "PylonCap", gx - 6, gx + 6, G + 21, G + 23, AZ - 4.2, AZ + 4.2, SAND_PALE,
			Enum.Material.Sandstone)
		box(m, "PylonBand", gx - 5.2, gx + 5.2, G + 12, G + 13.6, AZ - 3.7, AZ - 3.35, LAPIS,
			Enum.Material.SmoothPlastic, { CanCollide = false })
		box(m, "PylonBand2", gx - 5.2, gx + 5.2, G + 8, G + 9.6, AZ - 3.7, AZ - 3.35, CARNELIAN,
			Enum.Material.SmoothPlastic, { CanCollide = false })
	end
	box(m, "Lintel", CX - HALF - 10, CX + HALF + 10, G + 21, G + 26, AZ - 3.4, AZ + 3.4, STONE,
		Enum.Material.Sandstone)
	box(m, "LintelTrim", CX - HALF - 11, CX + HALF + 11, G + 26, G + 27.6, AZ - 4.2, AZ + 4.2, GOLD,
		Enum.Material.Metal)
	local board = box(m, "ArchBoard", CX - 22, CX + 22, G + 21.6, G + 25.4, AZ - 3.75, AZ - 3.4,
		SAND_PALE, Enum.Material.Sandstone)
	if board then
		-- Front is -Z, and -Z is where the dock is: this is read on the way in.
		SignKit.dress(board, "DUNE MARKET", { Enum.NormalId.Front })
	end
	return m
end

--[[
	THE WATER HOUSE -- this island's wash bay.

	WHY IT IS HERE AT ALL. The dunes run encasedScale = 1.0, so this is the field
	that turns up crusted lumps most often -- and until now the only wash bay in
	the game was on the beach, which meant every good find made out here had to be
	carried back through a travel gate before it was worth a penny. That is the
	one trip in the game with no gameplay in it.

	THE RIG IS BAYBUILDER'S, NOT A COPY. WashServer binds to any Model tagged
	"WashBay" that carries a `Stand` part, and it binds them by tag as they
	appear -- so this is buildWashBay's own geometry, reparented under Island2 and
	repainted. None of the mechanism is duplicated out here, which matters: a
	second hand-written rig would be a second thing to keep in step with whatever
	the washer expects to find.

	WHAT IS REPAINTED, AND WHY IT IS A LOOKUP RATHER THAN AN ARGUMENT. The bay's
	colours are literals inside BayBuilder and the beach owns that palette. Adding
	a palette parameter would mean editing a file this island does not own for a
	reason that is entirely this island's; a rename-map applied after the fact
	keeps the change where it belongs.
]]
--[[
	THE SHELL COMES OVER TOO, IN THE ISLAND'S DARK STONE.

	This used to stop at the fittings, on the reasoning recorded below the
	Stripe branch: the timber matched the sell shop's, and sandstone would sink
	the shack into the dune. Half of that has stopped being true and the other
	half was the right worry about the wrong colour.

	The sell shop is not a timber building and neither is the upgrades stall --
	measured, the only wood either of them wears is awning poles, crates and
	crate bands. Their walls are stone. That left this shack as the one building
	on the street with plank walls, a plank roof and plank cladding, which is
	exactly what reads as imported from the beach.

	The dune worry is real and it decides the VALUES rather than the material.
	Measured: the sand behind is Rec.709 luma 67%, and this pavilion's own stone
	runs 71-83% -- so a shack in STONE or SAND_PALE really would disappear into
	the slope. Everything here is 41-53% instead: darker than the sand, darker
	than the canopy around it, so the shack still reads as a shaded volume
	standing inside a pale frame. That is the same figure-and-ground the timber
	was doing, in the island's own palette instead of the beach's.

	POLES, CRATES AND THE TOOL BOARD STAY TIMBER on purpose -- the stalls either
	side carry exactly the same ones, so those are what the market is made of
	rather than what this building is made of.
]]
local STONE_SHADE = Color3.fromRGB(150, 108, 62)   -- 45%, the recessed wall
local STONE_ROOF  = Color3.fromRGB(134, 100, 68)   -- 41%, matches terrain Slate

local WASH_SKIN = {
	DrainPan = { STONE_DARK, Enum.Material.Slate },
	Column = { STONE, Enum.Material.Sandstone },
	StandVisual = { GOLD, Enum.Material.Metal },
	SignBoard = { LAPIS, Enum.Material.SmoothPlastic },
	SignPost = { Color3.fromRGB(122, 92, 58), Enum.Material.Wood },

	-- the shell
	SideWall = { STONE_SHADE, Enum.Material.Slate },
	BackWall = { STONE_SHADE, Enum.Material.Slate },
	Cladding = { STONE_DARK, Enum.Material.Concrete },
	Roof = { STONE_ROOF, Enum.Material.Slate },
	Deck = { STONE_DARK, Enum.Material.Slate },
	Post = { Color3.fromRGB(162, 120, 70), Enum.Material.Concrete },
	-- NOT Stand: it is WashServer's mount marker at Transparency 1, and the
	-- visible face beside it is StandVisual, which is gold above.
}

local function buildWashHouse(parent)
	local m = Instance.new("Model")
	m.Name = "WaterHouse"
	m.Parent = parent

	local G = GROUND
	local WZ = -105                      -- the rig's origin, closing the street

	-- Plinth. Its north edge stops at z = -98: the rakeable field begins at -96,
	-- and a building standing in it would be sitting on ground the player rakes.
	box(m, "Plinth", CX - 15, CX + 15, G - 0.8, G + 0.55, -115, -98, STONE_DARK,
		Enum.Material.Slate)
	box(m, "PlinthTrim", CX - 15.6, CX + 15.6, G - 0.2, G + 0.2, -115.6, -97.4, STONE,
		Enum.Material.Sandstone)
	box(m, "Floor", CX - 14, CX + 14, G + 0.55, G + 0.8, -114, -99, SAND_PALE,
		Enum.Material.Sandstone)

	-- A four-post canopy, so the rig stands under something rather than out in
	-- the open at the head of a built street.
	for _, px in ipairs({ CX - 12, CX + 12 }) do
		for _, pz in ipairs({ -113, -100 }) do
			box(m, "Post", px - 1.1, px + 1.1, G + 0.55, G + 15, pz - 1.1, pz + 1.1, STONE,
				Enum.Material.Sandstone)
			box(m, "PostBase", px - 1.6, px + 1.6, G + 0.55, G + 1.8, pz - 1.6, pz + 1.6,
				STONE_DARK, Enum.Material.Slate)
			box(m, "PostBand", px - 1.3, px + 1.3, G + 8.4, G + 9.6, pz - 1.3, pz + 1.3, TURQUOISE,
				Enum.Material.SmoothPlastic, { CanCollide = false })
		end
	end
	box(m, "Architrave", CX - 14, CX + 14, G + 15, G + 17, -114.4, -99, STONE,
		Enum.Material.Sandstone)

	--[[
		THE NAME, ON THE TWO FACES ANYBODY APPROACHES FROM.

		The bay's own board is BayBuilder's and it hangs inside this canopy on the
		short axis, which means the roof and the bay's own gable are between it and
		anyone outside -- you have to already be standing in the building to read
		the sign telling you what the building is.

		So the frieze carries it as well, north and south: north is the rakeable
		field, which is where a player raking their way down the island arrives
		from, and south is the market street. Those are the broad faces (28 studs
		against the ends' 15) and they are the two directions anybody walks in on.

		The interior one stays. This is an addition, not a move -- the sign is
		wanted at the counter as well as on the roofline.
	]]
	for _, sign in ipairs({
		{ z0 = -114.9, z1 = -114.5, face = Enum.NormalId.Front },   -- reads from the market
		{ z0 = -99.0,  z1 = -98.6,  face = Enum.NormalId.Back },    -- reads from the field
	}) do
		local board = box(m, "SignBoardOutside", CX - 5.5, CX + 5.5, G + 15, G + 17.2,
			sign.z0, sign.z1, SAND_PALE, Enum.Material.Sandstone, { CanCollide = false })
		if board then
			SignKit.dress(board, "WASH BAY", { sign.face })
		end
	end
	for i = 0, 2 do
		box(m, "Cornice" .. i, CX - 14 - i * 0.8, CX + 14 + i * 0.8,
			G + 17 + i * 0.75, G + 17.75 + i * 0.75, -114.4 - i * 0.7, -99 + i * 0.7,
			(i == 1) and GOLD or SAND_PALE,
			(i == 1) and Enum.Material.Metal or Enum.Material.Sandstone)
	end
	box(m, "Roof", CX - 16, CX + 16, G + 19.25, G + 20.1, -116.5, -97, STONE_DARK,
		Enum.Material.Slate)

	-- Cloth between the posts on the two long sides, in the market's stripes, so
	-- it reads as belonging to the row it stands at the end of.
	for i = 0, 8 do
		local sz = -113.4 + i * 1.55
		for _, px in ipairs({ CX - 13.4, CX + 12.6 }) do
			box(m, "Drape", px, px + 0.8, G + 11.4, G + 15, sz, sz + 1.2,
				(i % 2 == 0) and TURQUOISE or SAND_PALE, Enum.Material.Fabric,
				{ CanCollide = false })
		end
	end

	-- Water. A basin either side of the rig -- this is a WASH bay on an island
	-- whose only other water is an oasis, and a stone trough says so instantly.
	--
	-- OUTBOARD OF THE SHACK, at s * 13. At the original 9 they ran a stud and a
	-- half into the side walls of the 15.5-wide shack that stands here now; at 17
	-- -- which is where they went first -- the eastern one reached x 1480 once the
	-- whole building stepped 40 studs west, which put a stone trough sitting on
	-- the market street's kerb. 13 clears the shack's 7.75 half-width and stays
	-- inside the plinth it is standing on.
	for _, s in ipairs({ -1, 1 }) do
		local bx0 = CX + s * 13 - 3
		box(m, "Trough", bx0, bx0 + 6, G + 0.8, G + 3.4, -112, -107, STONE,
			Enum.Material.Sandstone)
		box(m, "TroughWater", bx0 + 0.5, bx0 + 5.5, G + 2.9, G + 3.2, -111.5, -107.5,
			Color3.fromRGB(96, 172, 196), Enum.Material.Glass,
			{ CanCollide = false, Transparency = 0.35, Reflectance = 0.25 })
		box(m, "Spout", bx0 + 2.6, bx0 + 3.4, G + 3.4, G + 6.2, -108.4, -107.6, GOLD,
			Enum.Material.Metal)
	end

	local lamp = P(m, "HouseLight", Vector3.new(1, 1, 1),
		CFrame.new(CX, G + 12, -106), GOLD, Enum.Material.Neon,
		{ Transparency = 1, CanCollide = false, CanQuery = false })
	local pl = Instance.new("PointLight")
	pl.Color = Color3.fromRGB(255, 214, 158)
	pl.Range = 38
	pl.Brightness = 1.1
	pl.Shadows = false
	pl.Parent = lamp

	--[[
		THE RIG: A CLONE OF THE BEACH'S SHACK, not BayBuilder.buildWashBay's.

		buildWashBay is a FALLBACK and always was -- ServerMain's ensureWashBay
		adopts the hand-authored Workspace.WashBay and never calls it. So the
		beach has a 95-part timber shack (deck, roof, hose reel, bucket, rags,
		tool board, lamps, sign) and this island was getting the 25-part bare rig:
		a stand, a drain pan and two sheets of splash guard. Skinned turquoise
		glass, that read as a green box under a canopy -- which is exactly why
		nobody could tell there was a wash bay on this island at all.

		Cloning is also what keeps the two in step: edit the beach shack in Studio
		and the desert one follows, with no second copy of the geometry to
		maintain. The CollectionService tag rides along on the clone, so WashServer
		binds it through the same GetInstanceAddedSignal every other bay uses.

		PLACED BY ITS BOUNDING BOX, NOT BY ITS PIVOT. The authored model's pivot
		sits 2.2 studs above its own underside, which is a fact about how somebody
		happened to save it rather than anything to build against. This measures
		the clone AFTER rotating it and sits the box on the floor, centred on the
		plinth -- so it stays put if the shack is ever rebuilt a different size.
	]]
	local FLOOR_TOP = G + 0.8
	local BAY_Z = -106.5              -- centred on the plinth, which runs -115 .. -98

	local rig
	local authored = workspace:FindFirstChild("WashBay")
	if authored and authored:IsA("Model") then
		rig = authored:Clone()
		--[[
			TURNED TO FACE +X -- THE MARKET STREET.

			It used to face -Z, back down the street, which was right when this
			building stood square across the street's north end. It does not any
			more: the whole water house steps 40 studs west (see the pivot at the
			end of this function) so the lane out to the field is open, and that
			puts the paving -- x 1477 to 1523 -- entirely to its EAST. Facing south
			from there presents the shack's blind side wall to every player walking
			past, and the doorway to open desert nobody crosses.

			The authored model faces +Z at rest, and a yaw of a is +Z -> (sin a, 0,
			cos a), so half pi turns the mouth to +X. It also fits the canopy
			better this way round: 16.55 across a 28-wide floor rather than 16.55
			deep in a 15-deep one.
		]]
		rig:PivotTo(CFrame.new(CX, 0, WZ) * CFrame.Angles(0, math.pi * 0.5, 0))
		local cf, size = rig:GetBoundingBox()
		rig:PivotTo(rig:GetPivot() + Vector3.new(
			CX - cf.Position.X,
			FLOOR_TOP - (cf.Position.Y - size.Y * 0.5),
			BAY_Z - cf.Position.Z))
		rig.Parent = m
	else
		local okRig, built = pcall(function()
			local BayBuilder = require(script.Parent:WaitForChild("BayBuilder"))
			return BayBuilder.buildWashBay(
				CFrame.new(CX, FLOOR_TOP, WZ) * CFrame.Angles(0, math.pi * 0.5, 0))
		end)
		if not okRig or not built then
			warn("[Dunes] no wash bay to clone and BayBuilder would not build one:", built)
			return m
		end
		rig = built
		rig.Parent = m
	end

	-- OFF THE STREET'S CENTRE LINE.
	--
	-- This building used to stand square across the mouth of the market: a plinth
	-- spanning CX +- 15.6 in a lane 34 studs wide, leaving about a stud and a half
	-- of walkable sand at either edge. That is what made the market a dead end.
	--
	-- Moved 40 studs west it still closes the view up the street and is still the
	-- first thing you meet coming off the field, but the lane out to the sand is
	-- open. Done as one pivot on the finished model rather than by threading an x
	-- offset through forty box() calls -- and the rig is parented in below, so it
	-- has to happen after that or the shack stays behind.
	local WASH_X = -40

	rig.Name = "DuneWashBay"
	for _, p in ipairs(rig:GetDescendants()) do
		if p:IsA("BasePart") then
			local skin = WASH_SKIN[p.Name]
			if skin then
				p.Color, p.Material = skin[1], skin[2]
			elseif p.Name:match("^Grate") then
				p.Color, p.Material = GOLD, Enum.Material.Metal
			elseif p.Name:match("^Guard") then
				p.Color, p.Material = TURQUOISE, Enum.Material.Glass
				p.Transparency = 0.4
			else
				-- The awning only. Its slats are banded cream and SEA on the beach,
				-- which is the one part of the shack that would look imported here;
				-- rebanded turquoise it belongs to the same market as the stalls
				-- either side of it. The shell is no longer left alone -- see the
				-- note on WASH_SKIN for what changed and why the values are dark.
				local n = p.Name:match("^Stripe(%d+)$")
				if n then
					p.Color = (tonumber(n) % 2 == 0) and SAND_PALE or TURQUOISE
				end
			end
		end
	end

	m:PivotTo(m:GetPivot() + Vector3.new(WASH_X, 0, 0))
	return m
end

local function buildMarket(parent)
	local m = Instance.new("Model")
	m.Name = "Market"
	m.Parent = parent

	buildMarketStreet(m)
	buildWashHouse(m)
	--[[
		THE MARQUEES SAY WHAT THE SHOP DOES, NOT WHAT IT IS CALLED.

		"DUNE BAZAAR" and "DUNE OUTFITTERS" are the names a signwriter would
		paint and they told a player nothing: both read as generic desert shop
		from across the street, and the only thing separating them was the strap
		board down at counter height, which you cannot read until you are already
		standing at one of them. The marquee is the sign you read at fifty studs
		while deciding which way to walk, so it carries the verb now. The strap
		boards keep the detail ("SELL YOUR FINDS", "SIFTER UPGRADES").
	]]
	buildStall(m, "Bazaar", -1, CARNELIAN, "SELL", "SELL YOUR FINDS")
	local outfitters = buildStall(m, "Outfitters", 1, LAPIS, "UPGRADES", "SIFTER UPGRADES")

	-- THE SELL PAD. Same shape and behaviour as the beach's -- CTB_Server checks
	-- every pad in its list against the player's position, so standing on this
	-- one sells exactly as that one does.
	--
	-- Set against the bazaar's apron rather than in the middle of the street, so
	-- it belongs to a counter instead of floating between two. It rides 0.34
	-- above ground rather than 0.22 because the paving under it is 0.12 proud
	-- and the glow beneath has to clear the joint lines, which are the one thing
	-- here thin enough to z-fight.
	-- Three courses, not one slab. Gold sitting on pale desert paving is nearly
	-- the same VALUE as the paving, so out here the pad needs a dark frame under
	-- it to have an edge at all -- on the beach the sand is cool enough that it
	-- did not, which is why the beach's is one part and this is three.
	-- 12 x 8, down from 15 x 10 and from the beach's 20 x 13. The beach's pad
	-- stands on open sand with nothing near it; this one sits in a 34-stud street
	-- between two buildings, and every size above this took up most of the paving
	-- and read as the floor rather than as a marked spot on it. The sim loop's
	-- own check adds 1.5 studs of slack on each axis, so the sell box is really
	-- 15 x 11 -- still several times wider than a player standing on it, and the
	-- frame and glow courses below add another 3.4 of visible target.
	local PAD_W, PAD_D = 12, 8
	local padX = CX - MKT_APRON + PAD_W * 0.5
	P(m, "PadFrame", Vector3.new(PAD_W + 3.4, 0.3, PAD_D + 3.4),
		CFrame.new(padX, GROUND + 0.27, -136), STONE_DARK, Enum.Material.Slate,
		{ CanCollide = false })
	P(m, "PadGlow", Vector3.new(PAD_W + 1.4, 0.24, PAD_D + 1.4),
		CFrame.new(padX, GROUND + 0.42, -136), Color3.fromRGB(255, 214, 120), Enum.Material.Neon,
		{ CanCollide = false, Transparency = 0.3 })
	local pad = P(m, "SellPad", Vector3.new(PAD_W, 0.45, PAD_D),
		CFrame.new(padX, GROUND + 0.52, -136), GOLD, Enum.Material.Sandstone)

	--[[
		THE UPGRADE COUNTER.

		One invisible anchor on the outfitters' counter with a prompt named
		"ShopPrompt" on it, which is the entire integration: MenuHud listens on
		ProximityPromptService for that NAME, anywhere in the world, and opens its
		stock panel. Renaming it here unhooks the shop, exactly as StoreBuilder's
		copy of this comment says on the beach.

		RequiresLineOfSight off for the same reason it is off there: the counter
		stands between the player and the anchor, so the test would hide the prompt
		from precisely where you are meant to be standing.
	]]
	local anchor = P(outfitters, "PromptAnchor", Vector3.new(1, 1, 1),
		CFrame.new(CX + MKT_FRONT - 4.2, GROUND + 6, -135), GOLD, Enum.Material.Neon,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ShopPrompt"
	prompt.ActionText = "Browse"
	prompt.ObjectText = "Dune Outfitters"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 16
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor

	return m, pad
end

----------------------------------------------------------------
-- Build
----------------------------------------------------------------
----------------------------------------------------------------
-- THE DESERT LITTER SET
--
-- ReplicatedStorage.CTB.Dunes, cloned by CTB_Client for island 2 exactly the
-- way it clones the trash meshes for the beaches and the gold for the vault.
--
-- WHAT THIS REPLACES. The row used to say litterSet = "Litter" -- the beach's
-- set -- so the desert floor was strewn with plastic bottles, milk cartons,
-- pizza boxes and a bin bag, two hundred studs from a pyramid, on the one field
-- in the game with no sea anywhere near it. Nothing had ever washed up here.
--
-- Every entry is a single BasePart, because the sink and raise tweens in
-- CTB_Client drive one part directly and a Model would need welding first.
--
-- Block and Ball only, for the reason VaultBuilder's set records: a Part
-- cylinder's axis runs along its LOCAL X and the scatter overwrites each prop's
-- CFrame outright, so every cylinder comes out lying on its side however the
-- template was saved.
--
-- Y IS THE FLAT AXIS ON EVERY ROW. CTB_Client's litterRest turns a prop onto
-- its side when size.Z < size.Y -- it exists for the beach's Z-up meshes -- so
-- anything authored here with Z smaller than Y would be stood up on end like a
-- billboard. Keep Z >= Y.
----------------------------------------------------------------
local TERRACOTTA = Color3.fromRGB(178, 96, 62)
local TERRACOTTA_PALE = Color3.fromRGB(198, 128, 90)
local MUDBRICK = Color3.fromRGB(190, 148, 96)
local DESERT_STONE = Color3.fromRGB(206, 176, 126)
local BONE = Color3.fromRGB(238, 230, 206)
local REED = Color3.fromRGB(206, 172, 104)
local PALM_DRY = Color3.fromRGB(158, 146, 84)
local LINEN = Color3.fromRGB(222, 208, 178)
local VERDIGRIS = Color3.fromRGB(150, 166, 110)

local DUNE_LITTER = {
	-- Broken pottery, which is what a desert dig site is mostly made of
	{ "PotSherd",       Vector3.new(1.2, 0.25, 0.9),  TERRACOTTA,      Enum.Material.Slate,        0.02, Enum.PartType.Block },
	{ "PotRim",         Vector3.new(0.9, 0.3, 1.1),   TERRACOTTA_PALE, Enum.Material.Slate,        0.02, Enum.PartType.Block },
	{ "PotNeck",        Vector3.new(0.8, 0.65, 0.8),  TERRACOTTA,      Enum.Material.Slate,        0.02, Enum.PartType.Ball },
	{ "AmphoraBase",    Vector3.new(1.1, 0.6, 1.1),   TERRACOTTA_PALE, Enum.Material.Slate,        0.02, Enum.PartType.Ball },

	-- Collapsed mud brick and dressed stone off whatever stood here
	{ "BrickHalf",      Vector3.new(1.6, 0.7, 0.9),   MUDBRICK,        Enum.Material.Concrete,     0.00, Enum.PartType.Block },
	{ "BrickRubble",    Vector3.new(1.0, 0.5, 1.1),   MUDBRICK,        Enum.Material.Concrete,     0.00, Enum.PartType.Block },
	{ "StoneChip",      Vector3.new(1.1, 0.4, 0.85),  DESERT_STONE,    Enum.Material.Sandstone,    0.00, Enum.PartType.Block },
	{ "StoneBlock",     Vector3.new(1.3, 0.6, 1.2),   DESERT_STONE,    Enum.Material.Sandstone,    0.00, Enum.PartType.Block },

	-- Caravan leavings
	{ "PalmFrondDry",   Vector3.new(2.4, 0.15, 0.7),  PALM_DRY,        Enum.Material.Grass,        0.00, Enum.PartType.Block },
	{ "ReedBundle",     Vector3.new(1.8, 0.35, 0.5),  REED,            Enum.Material.Fabric,       0.00, Enum.PartType.Block },
	{ "RopeCoil",       Vector3.new(1.1, 0.3, 1.1),   REED,            Enum.Material.Fabric,       0.00, Enum.PartType.Ball },
	{ "BasketRemains",  Vector3.new(1.3, 0.45, 1.2),  REED,            Enum.Material.Fabric,       0.00, Enum.PartType.Ball },
	{ "ClothScrap",     Vector3.new(1.2, 0.12, 1.0),  LINEN,           Enum.Material.Fabric,       0.00, Enum.PartType.Block },

	-- and what the caravans left behind that was never going home
	{ "BoneRib",        Vector3.new(1.7, 0.28, 0.32), BONE,            Enum.Material.Sandstone,    0.02, Enum.PartType.Block },
	{ "BoneFragment",   Vector3.new(0.9, 0.5, 0.8),   BONE,            Enum.Material.Sandstone,    0.02, Enum.PartType.Ball },
	{ "CopperScrap",    Vector3.new(0.8, 0.2, 0.6),   VERDIGRIS,       Enum.Material.CorrodedMetal,0.10, Enum.PartType.Block },
}

local function buildDuneLitterSet(): number
	local old = CTB:FindFirstChild("Dunes")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "Dunes"
	folder.Parent = CTB

	for _, t in ipairs(DUNE_LITTER) do
		local p = Instance.new("Part")
		p.Name = t[1]
		p.Size = t[2]
		p.Color = t[3]
		p.Material = t[4]
		p.Reflectance = t[5]
		p.Shape = t[6]
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = folder
	end
	return #DUNE_LITTER
end

----------------------------------------------------------------
-- ADOPT OR BUILD
--
-- HAND_BUILT is the switch. A Workspace.Island2 folder carrying this attribute
-- is treated as authored geometry: build() keeps it exactly as saved and re-runs
-- only the WIRING below -- the door's sounds, spill light, dust, hint and click
-- handler, the plaza CFrame and the tomb's rebirth attribute. None of that
-- survives in a place file, because it is behaviour and connections rather than
-- parts, which is why the script still has to run at all.
--
-- The bazaar's ShopPrompt is the exception that needs no help: a ProximityPrompt
-- IS a saved instance, and MenuHud finds it by NAME anywhere in the world, so it
-- goes on working on an adopted island without being remade. Renaming it still
-- unhooks the shop, exactly as buildMarket's note says.
--
-- Without the attribute nothing changes: the folder is destroyed and rebuilt from
-- scratch exactly as it always was, which is what a fresh place wants and what
-- makes "throw my edits away and give me the code's island back" a one-click
-- undo rather than a code change.
--
-- TO FREEZE THE ISLAND, once: run Island2.build() from the command bar in Edit
-- mode so the place holds the CURRENT geometry, set the attribute on the folder
-- it leaves behind, and save. From then on the island in the place file IS the
-- island, and anything moved by hand stays moved.
----------------------------------------------------------------
local HAND_BUILT = "HandBuilt"

-- What the wiring pass hangs off the door and the porch. On an adopted island the
-- copies saved by the Edit-mode build are still sitting there, so they are cleared
-- before the pass runs again -- otherwise the slab would collect another three
-- Sounds and another ClickDetector on every boot since the place was saved, and
-- open with four grinds at once on a click that registered four times.
--
-- Behaviour instances only. The door's own geometry, and any part a hand edit has
-- added under it, is left alone.
local function clearWiring(porchModel: Instance, door: Instance)
	for _, n in ipairs({ "DoorDust", "DoorSpill" }) do
		local p = porchModel:FindFirstChild(n)
		if p then
			p:Destroy()
		end
	end
	for _, c in ipairs(door:GetChildren()) do
		if c:IsA("Sound") or c:IsA("ClickDetector") or c:IsA("BillboardGui") then
			c:Destroy()
		end
	end
end

-- The parts the wiring pass cannot do without, found by name on a saved island.
-- It reports WHICH one is missing rather than handing back a nil for the caller
-- to index thirty lines later, because the useful thing to say about a renamed
-- door is its name.
local function adoptIsland(root: Instance)
	local porchModel = root:FindFirstChild("Entrance")
	local door = porchModel and porchModel:FindFirstChild("Door")
	local seal = porchModel and porchModel:FindFirstChild("DoorSeal")
	local market = root:FindFirstChild("Market")
	local sellPad = market and market:FindFirstChild("SellPad")

	local missing
	if not porchModel then
		missing = "Entrance"
	elseif not door then
		missing = "Entrance.Door"
	elseif not seal then
		missing = "Entrance.DoorSeal"
	elseif not market then
		missing = "Market"
	elseif not sellPad then
		missing = "Market.SellPad"
	end
	return porchModel, door, seal, sellPad, missing
end

----------------------------------------------------------------
-- THE DRESSING PASS  --  Creator Store props over the built island
----------------------------------------------------------------
--[[
	WHY THIS IS A SEPARATE PASS AND NOT PART OF THE BUILD.

	Workspace.Island2 in this place is HAND-BUILT and adopted: build() takes the
	saved island and returns before it ever reaches its own scatter code. So
	anything added down there would never appear in this place at all. This runs
	on BOTH paths, out of its own folder, and replaces that folder every boot --
	so it is safe over an adopted island, over a code-built one, and twice.

	EVERYTHING HERE IS A CREATOR STORE ASSET, staged and stripped in
	ServerStorage.DuneAssets: a PBR plateau pack for the rock and the dead
	trees, a palm pack, a market stall set, and the pottery, barrels and carts
	to fill the stalls with. The island's own props are untouched -- the
	pyramid, the statue, the two counters carrying the sell pad and the shop
	prompt -- and this is dressing laid around and between them.

	NOTHING HERE IS LOAD-BEARING except the car spawner, which is why that one
	is built outside the kit check. No prompt, no pad and nothing anybody has
	to stand on is in the folder. With ServerStorage.DuneAssets missing the
	island is exactly what it was, minus the dressing, and says so once.
]]
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local DUNE_ASSETS = ServerStorage:FindFirstChild("DuneAssets")

local function asset(name: string): Instance?
	local src = DUNE_ASSETS and DUNE_ASSETS:FindFirstChild(name)
	return src and src:Clone() or nil
end

--[[
	Put a staged asset on the ground at (x, z), turned to `yaw`, scaled, and
	sunk by `sink` studs so a rock sits IN the sand rather than on top of it.

	TURNED FIRST, THEN MEASURED. The drop height comes off the bounding box and
	a bounding box changes when a model turns, so the yaw goes on before
	anything is measured -- otherwise half the scatter floats and the other
	half is buried, in proportion to how square each mesh happens to be.

	CanQuery IS OFF ON EVERYTHING, collidable or not, and that is not tidiness.
	Every prop after this one is placed by raycasting the ground, so a prop
	left queryable becomes the ground for the next one and the scatter climbs
	itself.
]]
local function drop(parent, name: string, x: number, z: number, yaw: number,
	scale: number?, sink: number?, collide: boolean?)

	local m = asset(name)
	if not m then
		return nil
	end

	if scale and scale ~= 1 then
		if m:IsA("Model") then
			pcall(function()
				m:ScaleTo(scale)
			end)
		elseif m:IsA("BasePart") then
			m.Size = m.Size * scale
		end
	end

	local turn = CFrame.Angles(0, yaw, 0)
	if m:IsA("Model") then
		m:PivotTo(turn)
	elseif m:IsA("BasePart") then
		m.CFrame = turn
	end

	local cf, size
	if m:IsA("Model") then
		cf, size = m:GetBoundingBox()
	else
		cf, size = m.CFrame, m.Size
	end
	local pivotY = (m:IsA("Model") and m:GetPivot() or m.CFrame).Position.Y
	local lift = pivotY - (cf.Position.Y - size.Y * 0.5)

	local seat = groundUnder(x, z, math.max(size.X, size.Z), size.Y, GROUND)
	local target = CFrame.new(x, seat + lift - (sink or 0), z) * turn
	if m:IsA("Model") then
		m:PivotTo(target)
	else
		m.CFrame = target
	end

	local list = m:IsA("Model") and m:GetDescendants() or { m }
	for _, p in ipairs(list) do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanTouch = false
			p.CanQuery = false
			p.CanCollide = (collide == true)
			if collide == true and p:IsA("MeshPart") then
				-- A convex hull, never the default. The default collision on a
				-- thirty-stud rock mesh is a thirty-stud invisible CUBE, and a
				-- player who drives into one has hit nothing they can see.
				pcall(function()
					p.CollisionFidelity = Enum.CollisionFidelity.Hull
				end)
			end
		end
	end

	m.Parent = parent
	return m
end

-- The kit, by role. Names are ServerStorage.DuneAssets children; a missing one
-- costs that prop and nothing else, because `drop` returns nil on a miss.
local MESAS = { "Plateau1", "Plateau2", "Plateau3", "PlateauEnd1", "PlateauPillar",
	"PlateauStatue1", "PlateauStatue2", "PlateauStatue3", "PlateauStatue4" }
local SLABS = { "PlateauGround1", "PlateauGround2", "PlateauGround3", "PlateauGround4",
	"PlateauGround5", "PlateauGround6", "PlateauGround7" }
local PEBBLES = { "PlateauRock1", "PlateauRock2", "PlateauRock3" }
-- Scale per palm, because the pack is authored at 30 to 67 studs tall and a
-- 67-stud palm on a 3-stud plateau reads as a redwood.
local PALMS = {
	{ "Palm_A", 0.40 }, { "Palm_B", 0.44 }, { "Palm_E", 0.60 },
	{ "Palm_F", 0.48 }, { "Palm_G", 0.72 }, { "Palm_Tall", 0.40 }, { "Palm_Slim", 0.48 },
}
local STALLS = { "Stall_Red", "Stall_Blue", "Stall_Purple", "Stall_Green", "Stall_Orange" }
-- "Rack" is in the kit and is deliberately NOT in here. It is a shelving unit
-- whose back is one blank 7-stud board, and dropped at a random yaw it comes up
-- showing that board about half the time -- which at ground level in a street
-- reads as a sheet of plywood leaning on a stall.
local CLUTTER = { "Barrel", "Crate", "Urn_L", "Urn_M", "Urn_S", "Cart" }

--[[
	THE ROCK, and it is what the desert was actually short of.

	The island had cactuses, boulders off the beach's grey rock and dunes, and
	nothing in it taller than a cactus outside the pyramid. Nine plateau and
	pillar meshes at 150 to 292 studs out give the horizon something to break
	it up, seven ground slabs lie flat and sunk to read as bedrock coming
	through the sand, and the pebbles fill in between.

	SUNK, ALL OF IT. A rock resting exactly on a raycast hit sits ON the desert
	like a dropped prop; two to six studs into it and it belongs there.
]]
local function scatterRock(f, rng): number
	local mesas = 0
	for _ = 1, 300 do
		if mesas >= 22 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(150, 292)
		local x, z = CX + math.cos(a) * d, CZ + math.sin(a) * d
		if openGround(x, z, 34) and groundY(x, z, GROUND) > SEA_Y + 2 then
			drop(f, MESAS[rng:NextInteger(1, #MESAS)], x, z, rng:NextNumber(0, 6.28),
				rng:NextNumber(0.7, 1.4), rng:NextNumber(2.5, 6.5), true)
			mesas += 1
		end
	end

	--[[
		BEDROCK COMING THROUGH THE SAND, and the sink on these is the whole of
		whether it reads as that or as a stain.

		They were sunk 4 to 8 first, which on a slab that is only 4 to 12 studs
		tall buries nearly all of it: from the air the desert had flat brown
		patches lying on it that looked painted rather than modelled. One and a
		half to three and a half leaves a real edge standing proud, which is what
		casts the shadow that says it is rock.

		Eight rather than twelve for the same reason. These are the biggest
		pieces in the kit -- one of them is 63 studs across -- and a desert with
		twelve of them lying about has a floor made of rock rather than sand.
	]]
	local slabs = 0
	for _ = 1, 240 do
		if slabs >= 8 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(130, 286)
		local x, z = CX + math.cos(a) * d, CZ + math.sin(a) * d
		if openGround(x, z, 32) and groundY(x, z, GROUND) > SEA_Y + 1 then
			drop(f, SLABS[rng:NextInteger(1, #SLABS)], x, z, rng:NextNumber(0, 6.28),
				rng:NextNumber(0.6, 1.0), rng:NextNumber(1.5, 3.5), true)
			slabs += 1
		end
	end

	for _ = 1, 300 do
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(104, 300)
		local x, z = CX + math.cos(a) * d, CZ + math.sin(a) * d
		if openGround(x, z, 9) and groundY(x, z, GROUND) > SEA_Y + 1 then
			drop(f, PEBBLES[rng:NextInteger(1, #PEBBLES)], x, z, rng:NextNumber(0, 6.28),
				rng:NextNumber(0.5, 1.5), rng:NextNumber(0.5, 2), false)
		end
	end

	-- Dead trees. Six of them, because the one thing a desert needs more than
	-- rock is something that used to be alive.
	local trees = 0
	for _ = 1, 160 do
		if trees >= 7 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(120, 280)
		local x, z = CX + math.cos(a) * d, CZ + math.sin(a) * d
		if openGround(x, z, 14) and groundY(x, z, GROUND) > SEA_Y + 2 then
			drop(f, "TreeDead1", x, z, rng:NextNumber(0, 6.28),
				rng:NextNumber(0.6, 1.0), 1.2, false)
			trees += 1
		end
	end

	-- The oasis, which is the one green thing on this island and the only
	-- reason to walk to the middle of it. The code-built island rings it with
	-- six of CTB_Props' small palms; these are the real ones, standing behind.
	for i = 1, 9 do
		local a = (i / 9) * math.pi * 2 + 0.7
		local d = rng:NextNumber(38, 50)
		local x, z = 1301 + math.cos(a) * d, 151 + math.sin(a) * d
		local pick = PALMS[rng:NextInteger(1, #PALMS)]
		drop(f, pick[1], x, z, rng:NextNumber(0, 6.28),
			pick[2] * rng:NextNumber(0.85, 1.2), 0.6, false)
	end

	return mesas
end

--[[
	THE SOUK: the walk up from the ferry, turned into a street.

	This is the stretch KEEP_OUT already protects as "the approach up from the
	ferry pier" -- a hundred studs of bare sand between the pier head at
	z = -282 and the market's own arch at -180, which every player crossing to
	this island walks the whole length of and which had nothing on it.

	Two rows of stalls at CX +- 26 leave a 46-stud lane down the middle, so the
	street is dressed on both sides and nothing is ever in the way of the walk.
	They are Creator Store stalls with their own awnings and their own stock;
	the two counters that MATTER -- the sell pad and the shop prompt -- are
	still the island's own, up through the arch, and nothing here competes with
	them or carries a prompt.

	THE STALLS STAND OFF THE PAVING, NOT ON IT, and that is what the six studs
	between SOUK_X and SOUK_PAVE buy. A stall's awning reaches about four studs
	out over its own counter; set flush with the kerb it overhangs the walking
	lane, and from the pier end the street stopped reading as a street at all --
	you were looking down a tunnel of canvas with the market arch hidden behind
	it. Out on the sand, the awnings frame the arch instead of covering it.
]]
local SOUK_X = 31                      -- stall centre line, either side of CX
local SOUK_PAVE = 25                   -- the paved lane's own half-width
local SOUK_Z = { -208, -230, -252, -274 }

local function buildSouk(f, rng): number
	-- The paving is what turns a row of props into a street. Half a stud proud
	-- of the sand and not collidable: the walking surface stays the terrain,
	-- so nobody can catch a foot on the edge of it.
	box(f, "SoukPaving", CX - SOUK_PAVE, CX + SOUK_PAVE, GROUND - 0.5, GROUND + 0.1,
		-288, -192, SAND_PALE, Enum.Material.Slate,
		{ CanCollide = false, CanQuery = false })
	for _, s in ipairs({ -1, 1 }) do
		box(f, "SoukKerb", CX + s * SOUK_PAVE - 0.9, CX + s * SOUK_PAVE + 0.9,
			GROUND - 0.4, GROUND + 0.45, -288, -192, STONE_DARK, Enum.Material.Slate,
			{ CanQuery = false })
	end

	local stalls = 0
	for i, z in ipairs(SOUK_Z) do
		for _, s in ipairs({ -1, 1 }) do
			--[[
				FRONTS TURNED IN TOWARD THE LANE.

				A stall runs along its own Z with the counter and the awning on
				its -X, so the WEST row is the one that needs turning about. The
				first pass had this the other way and the whole street showed its
				back: two rows of trestle legs facing the walk and eight counters
				serving the empty desert.

				The stalls' own baked yaw (90 degrees on one, 180 on another --
				they were saved at whatever angle they were built at) is not a
				factor: `drop` sets the pivot's rotation outright rather than
				turning it by an offset, so every stall lands in the same frame.
			]]
			local yaw = (s < 0) and math.pi or 0
			local pick = STALLS[((i * 2 + (s > 0 and 1 or 0)) % #STALLS) + 1]
			--[[
				NOT INSIDE A COUNTER. The rows are laid out on a grid and the grid
				runs straight through the Outfitters, so the first two rungs of the
				east row are skipped rather than nudged -- see MARKET_BLOCKS.

				THREE, NOT A STALL'S HALF-DEPTH. clearOfBox adds a flat six studs of
				its own and the boxes are already drawn a few studs proud of the real
				walls, so passing 7 here asked for about thirteen studs of clearance
				from a padded box -- which also refused the stall at z -252, fourteen
				studs clear of the building and fouling nothing. At 3 the total is
				nine or so from the box, comfortably more than a stall's half-depth
				from the actual wall, and it takes exactly the two that overlap.

				SKIPPED, NOT MOVED, and that is deliberate: shifting a stall far
				enough to clear the shop puts it out of its row, and a street whose
				stalls do not line up reads worse than a street with a shop in it.
				The Outfitters stands where those two would have been, which is the
				honest picture -- the market street runs past a building.
			]]
			local sx, sz = CX + s * SOUK_X, z + rng:NextNumber(-1.6, 1.6)
			if clearOfMarket(sx, sz, 3)
				and drop(f, pick, sx, sz, yaw + rng:NextNumber(-0.05, 0.05), 1, 0, false) then
				stalls += 1
			end
			-- What a stall keeps beside it: one lot out at the kerb where a
			-- customer would trip over it, one lot round the back where the
			-- stock lives. Both clear of the paving, so the lane stays walkable --
			-- and both off the counters, for the same reason the stall above is.
			local kx, kz = CX + s * (SOUK_PAVE + 2), z + rng:NextNumber(6, 10)
			if clearOfMarket(kx, kz, 2) then
				drop(f, CLUTTER[rng:NextInteger(1, #CLUTTER)], kx, kz,
					rng:NextNumber(0, 6.28), rng:NextNumber(0.8, 1.15), 0, false)
			end
			local bx2, bz = CX + s * (SOUK_X + 7), z - rng:NextNumber(4, 8)
			if clearOfMarket(bx2, bz, 2) then
				drop(f, CLUTTER[rng:NextInteger(1, #CLUTTER)], bx2, bz,
					rng:NextNumber(0, 6.28), rng:NextNumber(0.8, 1.15), 0, false)
			end
		end
	end

	-- Two caravan tents behind the rows, so the souk has depth to it rather
	-- than being two lines of stalls on open sand.
	drop(f, "Tent", CX - 57, -226, 0.4, 0.72, 0, false)
	drop(f, "Tent", CX + 59, -256, -0.7, 0.66, 0, false)

	-- and everything the caravans came in with, dumped behind the stalls.
	for _ = 1, 16 do
		local s = (rng:NextNumber() < 0.5) and -1 or 1
		drop(f, CLUTTER[rng:NextInteger(1, #CLUTTER)],
			CX + s * rng:NextNumber(44, 66), rng:NextNumber(-278, -200),
			rng:NextNumber(0, 6.28), rng:NextNumber(0.8, 1.3), 0, false)
	end

	-- The car pad's own yard, so it reads as part of the street rather than as
	-- a slab dropped on open sand. Every one of these is OUTSIDE the pad's
	-- KEEP_OUT box (1402..1438, -212..-180), which is why they are placed by
	-- hand rather than scattered.
	drop(f, "Barrel", 1399, -184, 0.6, 1.1, 0, false)
	drop(f, "Crate", 1395, -189, -0.4, 1.15, 0, false)
	drop(f, "Urn_M", 1443, -215, 1.2, 1.0, 0, false)
	do
		local pick = PALMS[rng:NextInteger(1, #PALMS)]
		drop(f, pick[1], 1394, -215, rng:NextNumber(0, 6.28), pick[2] * 0.9, 0.5, false)
	end

	-- Four palms give the street shade and something tall at either end of it.
	for _, spot in ipairs({ { CX - 42, -196 }, { CX + 42, -196 },
		{ CX - 44, -282 }, { CX + 44, -282 } }) do
		local pick = PALMS[rng:NextInteger(1, #PALMS)]
		drop(f, pick[1], spot[1], spot[2], rng:NextNumber(0, 6.28), pick[2] * 0.95, 0.5, false)
	end

	return stalls
end

--[[
	AND THE BAZAAR ITSELF, which was two beautifully built counters with
	nothing on the floor in front of them.

	Pottery and crates set along both stall fronts, clear of the sell pad's own
	footprint on the west side -- the pad is 12 x 8 at (1483, -136) and the sim
	loop gives it another 1.5 studs of slack on each axis, so nothing goes
	inside x 1475..1491. CX +- 30 is inside the pilaster line and outside that.
]]
local function dressMarket(f, rng)
	for _, s in ipairs({ -1, 1 }) do
		for _, z in ipairs({ MKT_Z0 + 8, MKT_Z0 + 17, MKT_Z1 - 17, MKT_Z1 - 8 }) do
			drop(f, CLUTTER[rng:NextInteger(1, #CLUTTER)],
				CX + s * 30 + rng:NextNumber(-1.2, 1.2), z + rng:NextNumber(-2, 2),
				rng:NextNumber(0, 6.28), rng:NextNumber(0.75, 1.1), 0, false)
		end
	end
	-- a pair of urns either side of the gateway, which is the one thing on the
	-- arch that says somebody keeps this street
	for _, s in ipairs({ -1, 1 }) do
		drop(f, "Urn_L", CX + s * 13, MKT_ARCH_Z + 4, rng:NextNumber(0, 6.28), 1.15, 0, false)
	end
end

--[[
	THE DESERT'S CAR SPAWNER.

	(1536, -107): IN the market, on the east side of the street, directly across
	from the wash house and immediately north of the upgrades stall. Turned to
	face -X, so the bay opens onto the street's paving and a car drives straight
	out of it into the roadway.

	It was at (1420, -196) before -- west of the market's arch, out on open dune.
	That was defensible as scenery (a car drove away from the buildings rather
	than at them) and wrong as gameplay: the three things a player actually uses
	on this island are the sell counter, the sifter upgrades and the wash bay,
	all of them on this one street, and the vehicle bay was a two-hundred-stud
	walk away round the outside of the market. Putting it opposite the wash bay
	closes the loop -- rake, wash, sell, upgrade, drive -- inside one square.

	THE SPOT IS MEASURED, same as the old one was. Terrain across the pad's full
	22 x 16 is flat 3.00 with nothing of the island's own on it: the upgrades
	stall's plinth stops at z -119 and its roof at -120, four studs clear of the
	bay's -115 edge, and the street kerb is cut back to -115 so the exit is a
	dropped kerb rather than a lip. It is in KEEP_OUT as well, so no future
	scatter can put a cactus back on top of it -- which is what the FIRST
	placement of this pad, at (1585, -230), actually got.

	Its own name rather than the bare tag, because CarSpawnerBuilder.ensureWorld
	stands down the moment any pad exists anywhere and the beach's is built
	first -- see the note on ensureAt.

	AtvServer needs nothing told to it: it binds to every tagged pad and to
	every one that turns up later, and it already hands a player the NEAREST
	pad, so this is a working second car spawner the moment it is tagged.
]]
local CAR_PAD_X, CAR_PAD_Z = 1536, -107

local function buildCarPad()
	local CarSpawnerBuilder = require(ServerScriptService:WaitForChild("CarSpawnerBuilder"))
	CarSpawnerBuilder.ensureAt("DuneCarSpawner",
		CFrame.new(CAR_PAD_X, groundY(CAR_PAD_X, CAR_PAD_Z, GROUND), CAR_PAD_Z)
			* CFrame.Angles(0, -math.pi * 0.5, 0),
		{ palette = "desert", sign = "CAR SPAWN" })
end

local function dressDunes(root: Instance)
	-- Outside the kit check on purpose: the pad is the one thing in this
	-- section that is gameplay rather than scenery, and it goes up whether or
	-- not the Creator Store assets are staged.
	local okCar, errCar = pcall(buildCarPad)
	if not okCar then
		warn("[Dunes] the car spawner failed to build: " .. tostring(errCar))
	end

	local old = root:FindFirstChild("Dressing")
	if old then
		old:Destroy()
	end
	local f = Instance.new("Folder")
	f.Name = "Dressing"
	f.Parent = root

	if not DUNE_ASSETS then
		warn("[Dunes] ServerStorage.DuneAssets is missing -- the island keeps its "
			.. "code-built props and gets none of the Creator Store dressing.")
		return
	end

	-- Same reason the island's own scatter waits: terrain collision is rebuilt
	-- a frame behind the voxel write, and every prop here is placed by raycast.
	waitForGround()

	local rng = Random.new(Config.SEED + 8317)
	local mesas = scatterRock(f, rng)
	local stalls = buildSouk(f, rng)
	dressMarket(f, rng)

	local parts = 0
	for _, d in ipairs(f:GetDescendants()) do
		if d:IsA("BasePart") then
			parts += 1
		end
	end
	print(string.format("[Dunes] dressing: %d rock formations, %d souk stalls, %d parts",
		mesas, stalls, parts))
end

function Island2.build()
	-- ALWAYS, adopted or not. This folder lives in ReplicatedStorage rather than
	-- under the island, CTB_Client asks for it with a 30-second WaitForChild the
	-- moment it starts scattering the desert's props, and buildDuneLitterSet
	-- replaces its own folder -- so running it every boot costs nothing, and
	-- skipping it on an adopted island would strand the client.
	local litterKinds = buildDuneLitterSet()

	local existing = workspace:FindFirstChild("Island2")
	local adopting = existing ~= nil and existing:GetAttribute(HAND_BUILT) == true

	local root, props, porchModel, door, seal, sellPad
	local dunes, rocks

	if adopting then
		local missing
		porchModel, door, seal, sellPad, missing = adoptIsland(existing)
		if missing then
			-- Self-healing rather than a dead island. Left to run, the wiring pass
			-- would tween a nil seal and hand CTB_Server a nil pad, and what the
			-- player would see is a door that cannot be clicked and a bazaar that
			-- pays nothing, with nothing in the log to connect either to a rename.
			warn(string.format(
				"[Dunes] Workspace.Island2 is marked %s but has no %s -- rebuilding it from "
				.. "code, which will lose any hand edits. Rename that part back, or clear "
				.. "the %s attribute if the island is meant to be code-built.",
				HAND_BUILT, missing, HAND_BUILT))
			adopting = false
		else
			root = existing
			props = root:FindFirstChild("Props")
			clearWiring(porchModel, door)
		end
	end

	if not adopting then
		-- Idempotent: a second call replaces the island rather than doubling it.
		if existing then
			existing:Destroy()
		end

		root = Instance.new("Folder")
		root.Name = "Island2"
		root.Parent = workspace

		dunes, rocks = buildTerrain()
		waitForGround()

		props = Instance.new("Folder")
		props.Name = "Props"
		props.Parent = root

		buildPyramid(root)
		porchModel, door, seal = buildPorch(root)
		buildChamber(root)
		buildStatue(root)
		-- tight either side of the doorway, forward of the pyramid's face at z = 128
		buildObelisk(root, CX - 22, 118)
		buildObelisk(root, CX + 22, 118)
		buildCamel(root)

		sellPad = select(2, buildMarket(root))
	end

	----------------------------------------------------------------
	-- THE DOOR. Click only.
	--
	-- This is the whole of the door's behaviour, and there is deliberately no
	-- Touched connection and no ProximityPrompt anywhere on it. Walking into the
	-- slab does what walking into any anchored collidable part does: nothing.
	-- It opens when, and only when, someone clicks or taps it -- a ClickDetector
	-- covers both, since a tap on a touchscreen raises MouseClick too.
	----------------------------------------------------------------
	local grind = Instance.new("Sound")
	grind.SoundId = SND_DOOR
	grind.Volume = 0.55
	grind.PlaybackSpeed = 0.45          -- a metal scrape pitched down into stone
	grind.RollOffMaxDistance = 180
	grind.Parent = door

	-- The lock letting go, a beat before the stone actually moves. Same source
	-- pitched right down: one clean thud rather than a scrape.
	local clunk = Instance.new("Sound")
	clunk.SoundId = SND_DOOR
	clunk.Volume = 0.75
	clunk.PlaybackSpeed = 0.22
	clunk.RollOffMaxDistance = 220
	clunk.Parent = door

	-- The refusal. Deliberately dull and short -- it has to sound like nothing
	-- happening, not like something breaking.
	local refuseSnd = Instance.new("Sound")
	refuseSnd.SoundId = SND_DOOR
	refuseSnd.Volume = 0.4
	refuseSnd.PlaybackSpeed = 0.9
	refuseSnd.RollOffMaxDistance = 90
	refuseSnd.Parent = door

	-- Dust shaken out of the lintel as the slab moves.
	local dustAnchor = P(porchModel, "DoorDust", Vector3.new(DOOR_W, 1, 1),
		CFrame.new(CX, GROUND + 0.6, FACE_Z - 1.4), STONE, Enum.Material.Sandstone,
		{ Transparency = 1, CanCollide = false, CanQuery = false })
	local dust = Instance.new("ParticleEmitter")
	dust.Texture = "rbxasset://textures/particles/smoke_main.dds"
	dust.Rate = 0
	dust.Lifetime = NumberRange.new(1.1, 2.4)
	dust.Speed = NumberRange.new(2, 7)
	dust.SpreadAngle = Vector2.new(40, 12)
	dust.Color = ColorSequence.new(Color3.fromRGB(226, 198, 152))
	dust.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.4),
		NumberSequenceKeypoint.new(1, 7),
	})
	dust.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	dust.Parent = dustAnchor

	-- Warm light spilling out of the opening, tweened up with the slab. This is
	-- what sells the door as leading SOMEWHERE rather than into a black slot.
	local spillPart = P(porchModel, "DoorSpill", Vector3.new(1, 1, 1),
		CFrame.new(CX, GROUND + 8, FACE_Z + 6), GOLD, Enum.Material.Neon,
		{ Transparency = 1, CanCollide = false, CanQuery = false })
	local spill = Instance.new("PointLight")
	spill.Color = Color3.fromRGB(255, 206, 128)
	-- 34/2.0, down from 42/3.4. The cutscene camera now closes ON the doorway
	-- instead of dollying blindly forward, so it ends up looking straight into
	-- this lamp -- and at the old values that filled the entire frame with white
	-- for the last second of the door's travel. The player was watching a lit
	-- rectangle, not a door.
	spill.Range = 34
	spill.Brightness = 0
	spill.Parent = spillPart

	-- A hint over the door, because "click this" is not otherwise discoverable on
	-- a slab of stone -- especially on a phone, where there is no hover cursor.
	local hint = Instance.new("BillboardGui")
	hint.Name = "DoorHint"
	hint.Size = UDim2.new(0, 240, 0, 56)
	-- IN FRONT OF THE PORCH, not tucked under the lintel.
	--
	-- This was (0, 11.4, -1.5), which lands at world (1500, 23.4, 126.5) --
	-- INSIDE the Lintel, which is solid stone from y 21 to 27 across z 126..130.
	-- A BillboardGui is depth-tested like anything else, so the hint has been
	-- buried in the masonry since the porch was built and has never once been
	-- seen: the door's only instruction, on the one object on this island a
	-- player has to be told to touch.
	--
	-- 7 studs proud of the face (z 121) clears the lintel, the two painted bands
	-- at z 125.6 and the jambs, and there is nothing in front of the porch but
	-- the forecourt paving at y 3.
	hint.StudsOffsetWorldSpace = Vector3.new(0, DOOR_H * 0.5 + 3, -7)
	hint.MaxDistance = 90
	hint.Parent = door
	local hintLabel = Instance.new("TextLabel")
	hintLabel.Size = UDim2.fromScale(1, 1)
	hintLabel.Text = "TAP TO OPEN"
	hintLabel.Parent = hint
	-- Gold kept: it is the pyramid's own metal, and the door is the one thing on
	-- the plaza the player is being told to touch.
	SignKit.floating(hintLabel, Color3.fromRGB(255, 226, 150))

	--[[
		EVERYTHING THAT TRAVELS WITH THE SLAB.

		The seal and its ring are separate parts standing proud of the door's
		face, and they were NOT in the tween -- so the door sank cleanly to y =
		-6.4 and left a lit gold disc hanging in the middle of an empty doorway.
		From the plaza that reads exactly like a door that has not opened, which
		is precisely how it was reported.
	]]
	local movers = { door }
	for _, n in ipairs({ "DoorSeal", "DoorRing" }) do
		local p = porchModel:FindFirstChild(n)
		if p then
			table.insert(movers, p)
		end
	end
	local homeCF = {}
	for _, p in ipairs(movers) do
		homeCF[p] = p.CFrame
	end

	-- Moves the whole assembly by one offset and hands back the last tween, so
	-- there is one place that knows the door is more than a single part.
	local function moveAll(offset: Vector3, info: TweenInfo)
		local last
		for _, p in ipairs(movers) do
			last = TweenService:Create(p, info, { CFrame = homeCF[p] + offset })
			last:Play()
		end
		return last
	end

	local closedCF = door.CFrame

	-- SINKS into the floor to open, rather than rising into the lintel.
	--
	-- Rising is the obvious choice for a slab like this and was the first
	-- version, but the door is 18 studs tall and the porch it sits in is only 28,
	-- so an open door stood seven studs proud of the porch roof -- clearly wrong
	-- from anywhere on the plaza, and it put the slab where the roof was in front
	-- of it so you could no longer click the thing. Downward there is unlimited
	-- room: the island is solid sandstone to y = -20.
	local DROP = Vector3.new(0, DOOR_H + 0.4, 0)

	--[[
		1.7 seconds, Quart, and OUT rather than InOut.

		The old 2.4s Quint InOut spent its first 0.6s covering five hundredths of
		a stud -- measured -- so between that and a 0.45s pre-wait the slab did not
		visibly move for a second after the click, then dropped most of its travel
		in a rush. Out-easing starts on the beat and settles at the bottom, which
		is also how a very heavy thing actually falls.

		IT MUST FINISH BEFORE THE CUT. Vault.enter is called when slide() returns,
		so the screen goes white at LEAD + Config.CINEMA.beat. 0.3 + 1.7 = 2.0
		against a 2.0 beat: the door is down, and the last thing the player sees is
		the opening rather than a slab still moving.
	]]
	local DOOR_LEAD = 0.3
	local DOOR_TIME = 1.7

	local openCF = closedCF - DROP
	local isOpen, moving = false, false
	local epoch = 0

	local function slide(open: boolean)
		moving = true
		isOpen = open
		hint.Enabled = not open

		if open then
			-- the mechanism releasing, then the stone. The gap between the two is
			-- most of what makes the door feel heavy rather than motorised.
			clunk:Play()
			TweenService:Create(seal, TweenInfo.new(0.6), {
				Color = Color3.fromRGB(255, 244, 198),
				Reflectance = 0.6,
			}):Play()
			task.wait(DOOR_LEAD)
			dust:Emit(70)
			TweenService:Create(spill, TweenInfo.new(1.6), { Brightness = 2.0 }):Play()
		else
			TweenService:Create(spill, TweenInfo.new(1.4), { Brightness = 0 }):Play()
			TweenService:Create(seal, TweenInfo.new(1), {
				Color = GOLD,
				Reflectance = 0.25,
			}):Play()
		end

		grind.TimePosition = 0
		grind:Play()
		local tween = moveAll(open and -DROP or Vector3.zero,
			TweenInfo.new(DOOR_TIME, Enum.EasingStyle.Quart,
				open and Enum.EasingDirection.Out or Enum.EasingDirection.InOut))
		tween.Completed:Connect(function()
			moving = false
			if not open then
				dust:Emit(30)
			end
		end)

		-- A tween that never completes latches `moving` true and the door is dead
		-- for the rest of the session -- and TweenService genuinely does stall
		-- (every tween in the game stops while the window is minimised). One
		-- unconditional release, well after the tween should have landed.
		task.delay(DOOR_TIME + 2, function()
			moving = false
		end)
	end

	-- Refused. The slab strains against whatever is holding it and settles back:
	-- a door that simply does nothing when clicked reads as a bug, and the player
	-- has to be able to tell the difference between "locked" and "broken".
	local function refuse()
		if moving then
			return
		end
		moving = true
		refuseSnd:Play()
		dust:Emit(14)
		local strain = moveAll(Vector3.new(0, -0.35, 0),
			TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out))
		strain.Completed:Connect(function()
			local back = moveAll(Vector3.zero,
				TweenInfo.new(0.5, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out))
			back.Completed:Connect(function()
				moving = false
			end)
		end)
		task.delay(2.5, function()
			moving = false
		end)
	end

	-- Nobody standing in the opening. The slab sinks through the ground, so
	-- closing it under someone would take them down with it.
	local function doorwayClear(): boolean
		for _, plr in ipairs(Players:GetPlayers()) do
			local char = plr.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp then
				local d = hrp.Position - Vector3.new(CX, GROUND + 6, FACE_Z + 2)
				if math.abs(d.X) < 11 and math.abs(d.Z) < 11 and math.abs(d.Y) < 14 then
					return false
				end
			end
		end
		return true
	end

	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = 36
	click.Parent = door

	-- THE ONLY thing that opens this door. A ClickDetector covers mouse and touch
	-- alike, since a tap raises MouseClick too.
	click.MouseClick:Connect(function(plr)
		if moving or isOpen then
			return
		end

		-- THE TOMB IS GATED. Checked here, on the server, off the same Rebirths
		-- attribute ProgressionServer writes -- a client cannot talk its way in by
		-- re-enabling anything, because the click is the only entry point and this
		-- is the only place it is answered.
		local have = plr:GetAttribute("Rebirths") or 0
		if have < Vault.REBIRTHS then
			Net:FireClient(plr, "DoorLocked", Vault.REBIRTHS, have)
			refuse()
			return
		end

		slide(true)
		-- and away: the fade, the teleport and the fade back all live in
		-- VaultBuilder so both directions are written once.
		--
		-- The doorway is handed over as the shot's SUBJECT. Without it the client
		-- had nothing to frame and simply dollied 11 studs along wherever the
		-- player happened to be looking -- which, standing in front of the door,
		-- walked the camera into the opening and filled the screen with the spill
		-- light. A fixed point, not the door part: the door is sinking.
		Vault.enter(plr, Vector3.new(CX, GROUND + 9, FACE_Z))

		-- Reseals itself, so the door is always back to being a clickable slab --
		-- sunk in the floor there is nothing left to click.
		epoch += 1
		local mine = epoch
		task.spawn(function()
			task.wait(AUTO_CLOSE)
			while epoch == mine and not doorwayClear() do
				task.wait(2)
			end
			if epoch == mine and isOpen and not moving then
				slide(false)
			end
		end)
	end)

	-- Where the tomb should send people back to: the plaza, facing the door they
	-- came out of.
	--
	-- PUBLISHED, NOT PUSHED. This module and VaultBuilder each own one side of
	-- the same door, and neither should have to load first to be correct -- so
	-- this only states where its plaza is, and CTB_Server joins the two together
	-- once both builds have finished.
	Island2.plazaCF = CFrame.lookAt(
		Vector3.new(CX, GROUND + 3.5, FACE_Z - 26),
		Vector3.new(CX, GROUND + 3.5, FACE_Z))

	----------------------------------------------------------------
	-- Travel
	--
	-- Nothing, and that is the change. The two gateways that used to stand
	-- here -- one on the plaza at z = -232, one on the beachfront at x = 62 --
	-- are gone with the level check behind them. Crossing between islands is
	-- the FERRY now: a pier, a moored boat and a man to talk to at the end of
	-- every map, built by FerryBuilder and run by FerryServer into a folder of
	-- its own. The dunes' requirement, Sifter Lv.3, moved to FerryConfig.Ports
	-- unchanged; nothing in this file needs to know about any of it.
	----------------------------------------------------------------
	-- PUBLISHED so the client can say what the door wants BEFORE it is clicked.
	-- The number lives in VaultBuilder, which is server-only, and the hint over
	-- the slab read "TAP TO OPEN" for everybody -- so a player under the gate was
	-- invited to click a door whose only possible answer was to refuse. The
	-- refusal is per player and a BillboardGui is one shared instance, so
	-- Island2_Client rewrites the label locally, exactly as it does the gate
	-- signs.
	root:SetAttribute("TombRebirths", Vault.REBIRTHS)

	-- DONE, on an adopted island.
	--
	-- Everything below this line MAKES geometry -- the scatter, and the masonry
	-- pass over what it made -- and on a hand-built island every bit of it is
	-- already saved in the place file. Running it again would stand a second
	-- cactus in each of the first pass's positions (the seed is fixed, so they
	-- land in exactly the same spots) and would overwrite any material picked by
	-- hand. Everything the door, the shop and the vault need has already run.
	if adopting then
		print(string.format("[Dunes] litter set: %d desert prop types", litterKinds))
		print("[Dunes] adopted the hand-built island saved in the place file")
		-- ...and dressed anyway. This is the path this place actually takes, so
		-- a dressing pass that only ran on the code-built branch would never run
		-- at all. Its own pcall: a prop kit that fails to place must not cost
		-- the caller the sell pad it is waiting for.
		local okDress, errDress = pcall(dressDunes, root)
		if not okDress then
			warn("[Dunes] the dressing pass failed: " .. tostring(errDress))
		end
		return sellPad
	end

	----------------------------------------------------------------
	-- Scatter: cactuses, boulders, palms round the oasis
	----------------------------------------------------------------
	local rng = Random.new(Config.SEED + 5150)
	local propLib = game:GetService("ServerStorage"):FindFirstChild("CTB_Props")

	local cactuses = 0
	for _ = 1, 220 do
		if cactuses >= 26 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(112, 268)
		local x, z = CX + math.cos(a) * d, CZ + math.sin(a) * d
		if openGround(x, z, 6) then
			local y = groundY(x, z, GROUND)
			-- skip anything that landed on a dune flank steep enough that the
			-- cactus would stick out of it sideways
			if math.abs(y - GROUND) < 7 then
				buildCactus(props, x, z, rng:NextNumber(0.7, 1.35), rng:NextNumber(0, 6.28))
				cactuses += 1
			end
		end
	end

	local boulders = 0
	local rockTemplate = propLib and propLib:FindFirstChild("Rock")
	if rockTemplate then
		for _ = 1, 200 do
			if boulders >= 30 then
				break
			end
			local a = rng:NextNumber(0, math.pi * 2)
			local d = rng:NextNumber(108, 280)
			local x, z = CX + math.cos(a) * d, CZ + math.sin(a) * d
			if openGround(x, z, 7) then
				local y = groundY(x, z, GROUND)
				local r = rockTemplate:Clone()
				r:ScaleTo(rng:NextNumber(0.7, 1.9))
				r:PivotTo(CFrame.new(x, y - 0.6, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0))
				-- retint off the beach's grey, so they belong to this island
				for _, p in ipairs(r:GetDescendants()) do
					if p:IsA("BasePart") then
						p.Color = STONE_DARK
						p.Material = Enum.Material.Sandstone
					end
				end
				r.Parent = props
				boulders += 1
			end
		end
	end

	-- the oasis: palms and a ring of reeds, so the one green thing on the island
	-- is worth walking over to
	local palmTemplate = propLib and propLib:FindFirstChild("Palm")
	if palmTemplate then
		for i = 1, 6 do
			local a = (i / 6) * math.pi * 2 + 0.4
			local x, z = 1301 + math.cos(a) * 34, 151 + math.sin(a) * 34
			local palm = palmTemplate:Clone()
			palm:ScaleTo(rng:NextNumber(0.85, 1.25))
			palm:PivotTo(CFrame.new(x, groundY(x, z, GROUND) - 0.4, z) * CFrame.Angles(0, a, 0))
			palm.Parent = props
		end
	end
	for i = 1, 40 do
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(29, 33)
		local x, z = 1301 + math.cos(a) * d, 151 + math.sin(a) * d
		P(props, "Reed", Vector3.new(0.35, rng:NextNumber(3, 6.5), 0.35),
			CFrame.new(x, GROUND + 1.6, z) * CFrame.Angles(rng:NextNumber(-0.2, 0.2), 0, rng:NextNumber(-0.2, 0.2)),
			Color3.fromRGB(112, 138, 72), Enum.Material.Grass, { CanCollide = false })
	end

	-- Masonry material, in one pass at the end rather than as an argument on
	-- every one of the two hundred calls above.
	--
	-- Roblox's Sandstone PART material is heavy dark horizontal banding, and
	-- under this place's sky (EnvironmentDiffuseScale 0.7, bright blue skybox) it
	-- reads mauve-grey however warm the colour underneath it is -- so a pyramid
	-- built in it stands on orange sand looking like it was imported from another
	-- island. Concrete's fine grain takes the warm colour cleanly. Picked off an
	-- eight-way side-by-side of materials and tints staged on the plaza.
	--
	-- TERRAIN Sandstone is untouched and must stay that way: it is tinted
	-- directly by SetMaterialColor and already reads warm.
	for _, p in ipairs(root:GetDescendants()) do
		if p:IsA("BasePart") and p.Material == Enum.Material.Sandstone then
			p.Material = Enum.Material.Concrete
		end
	end

	-- AFTER the Sandstone -> Concrete pass above, deliberately. The dressing is
	-- Creator Store meshes carrying their own PBR materials and it has no
	-- business being swept up by a rule written for this file's own masonry.
	local okDress, errDress = pcall(dressDunes, root)
	if not okDress then
		warn("[Dunes] the dressing pass failed: " .. tostring(errDress))
	end

	print(string.format("[Dunes] litter set: %d desert prop types", litterKinds))
	print(string.format("[Dunes] island built: %d dunes, %d outcrops, %d cactuses, %d boulders",
		dunes, rocks, cactuses, boulders))

	return sellPad
end

return Island2
