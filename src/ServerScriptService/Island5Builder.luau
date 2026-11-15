--[[
	Island5Builder  --  ServerScriptService.Island5Builder  (ModuleScript)

	PENGUIN ISLAND. The game's fifth rakeable destination and, by a distance, the
	biggest thing in this place: 2800 studs due south of the beach, a snowfield
	768 studs to a side inside a landmass 1488 across, standing on a frozen ocean
	that runs another 340 studs out past the shore before the open water begins.

	WHAT LIVES WHERE, on exactly the split the other islands keep:

	  here                terrain -- the seabed, the sea, the pack ice, the
	                      island, the cliffs and the bergs -- and every piece of
	                      SHARED, CIVIC geometry: the landing and its market, the
	                      sell hall, the trading post and its ShopPrompt, the
	                      village, the colony's placement, the forest's placement,
	                      the aurora, and the SCATTER of the dressed props. All
	                      server-built, so everyone sees the same island.
	  Island5Props        the props themselves, as pure builders. Igloos, cabins,
	                      pines, lamps, fences, sleds, snowmen, floes and the
	                      litter set. It decides nothing about WHERE anything goes.
	  PenguinBuilder      what a penguin is; PenguinService is what petting one
	                      pays. This file decides where each bird stands.
	  FrozenWreckBuilder  the liner beached on the north shore -- its whole
	                      exterior, the breach in its hull that is the door, and
	                      the hold behind it that is Config.ISLANDS[9]. Built AFTER
	                      this file, because this file repours the shore.
	  CTB_Server          the rakeable field itself and who has raked what. To
	                      that script this island is just Config.ISLANDS[8].
	  Island5_Client      everything that MOVES or is PRIVATE: the snowfall, the
	                      cold grade, the still sea, the aurora's shimmer, the
	                      birds bobbing and the blizzard.

	ORDER. build() must run BEFORE CTB_Server's baselineField(). The plateau is
	filled solid and the rakeable columns are then carved into the top of it;
	the other way round the plateau simply buries them. CTB_Server calls this
	at the bottom of itself, after the Magma Chamber and before the wreck, and
	nothing else should call it.

	It returns the island's SellPad so CTB_Server can add it to the list of
	pads that pay out. An island with no pad is an island that bricks itself
	after one bagful (RollerBlocked, and a 2800-stud swim home).

	HAND-EDITING THIS ISLAND. By default build() destroys Workspace.Island5 and
	makes it again, so anything moved in Studio is gone the moment you press
	Play. Set the boolean attribute "HandBuilt" on the folder and that stops --
	see ADOPT OR BUILD, just above build().

	THE FROZEN SEA, because it is the thing everyone will ask about. The ocean
	is still real terrain Water -- SeaWallBuilder fences a shore by raycasting
	terrain with water ignored, the ferry moors its vessel on a water Z, and the
	rebirth landing raycasts for a floor -- and the FREEZE is a one-voxel sheet
	of Ice poured over the top of it out to ICE_R. Solid, walkable, tinted a cold
	blue by applyLook, and bumpy, which is the one place in the game the bumpy
	material is the right one. Past ICE_R the water is open and the floes are
	parts; the fence stands in that ring. The ferry berth stands on the ice: the
	vessel there is a sleigh, and a sleigh does not need a lead cut for it.

	WHAT THIS SCRIPT MAY NOT DO:
	  * Nothing may stand inside the rakeable square, x [-384, 384]
	    z [-3184, -2416]. openGround() gates every scattered placement and
	    assertClearOfField() re-checks the finished island at the end.
	  * No TERRAIN may use Glacier or Ice outside this island and the wreck,
	    and no terrain inside it may use anything else. Both are tinted
	    globally by CTB_Server.applyLook.
	  * Neon stays at Transparency 0. Nothing that glows carries a PointLight
	    by default; lamps take `lit` and about half of them get one.
]]

local Island5 = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CTB = ReplicatedStorage:WaitForChild("CTB")
local Config = require(CTB:WaitForChild("Config"))
local SignKit = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("SignKit"))

local Terrain = workspace.Terrain

----------------------------------------------------------------
-- The props module, held at arm's length
----------------------------------------------------------------
local Props = nil
do
	local ok, mod = pcall(function()
		return require(script.Parent:WaitForChild("Island5Props", 5))
	end)
	if ok and type(mod) == "table" then
		Props = mod
	else
		warn("[Penguin] Island5Props did not load -- the island will be built bare. " .. tostring(mod))
	end
end

local Birds = nil
do
	local ok, mod = pcall(function()
		return require(script.Parent:WaitForChild("PenguinBuilder", 5))
	end)
	if ok and type(mod) == "table" then
		Birds = mod
	else
		warn("[Penguin] PenguinBuilder did not load -- the island will have no colony. " .. tostring(mod))
	end
end

local propFails = 0

-- One call into Island5Props. Returns the Model, or nil, and never throws.
local function prop(fnName: string, ...): Model?
	if not Props then
		propFails += 1
		return nil
	end
	local builder = Props[fnName]
	if type(builder) ~= "function" then
		propFails += 1
		if propFails <= 4 then
			warn(string.format("[Penguin] Island5Props.%s is missing", fnName))
		end
		return nil
	end
	local ok, m = pcall(builder, ...)
	if not ok then
		propFails += 1
		if propFails <= 4 then
			warn(string.format("[Penguin] Island5Props.%s threw: %s", fnName, tostring(m)))
		end
		return nil
	end
	if typeof(m) ~= "Instance" then
		propFails += 1
		return nil
	end
	return m
end

----------------------------------------------------------------
-- Where everything is
----------------------------------------------------------------
local ISL = Config.island(8)
local GROUND = ISL.cleanY              -- 3.0, the same voxel band as every field

--[[
	THE SQUARE AND THE ISLAND ARE TWO DIFFERENT POINTS, Ashfall's arrangement:
	FCX/FCZ are the rakeable square, CX/CZ the anchor the landing hangs off,
	and the landing's distances are written as "the number the layout was drawn
	at, minus 2 * GROW" so the camp slides south with the field and keeps its
	52 studs of clearance from the square's edge whatever the grid is.

	The LANDMASS is centred north of the square (ICZ). Ashfall put its volcano
	there; this island puts the liner, the cliffs and the colony's strand there,
	and it needs 460 studs of shore north of the field for a ship 220 long to
	lie across with its bow on the snow.
]]
local FCX, FCZ = ISL.cx, ISL.cz        -- the square's centre: 0, -2800
local FIELD_HALF = ISL.half            -- 384
local GROW = FIELD_HALF - 160          -- 224: how much bigger the square is than the layout was drawn for
local CX, CZ = FCX, FCZ + GROW         -- THE ISLAND ANCHOR: 0, -2576
local CD = CZ - 2 * GROW               -- the camp datum: -3024. PetConfig derives the same number.

local SAND = ISL.matMessy              -- Glacier, tinted snow: everything flat and white
local ICE = Enum.Material.Ice          -- the frozen sea, tinted a cold blue

local ICZ = FCZ + 100                  -- the landmass centre: 0, -2700

--[[
	THE SEA. The wipe, the seabed, the water and the ice share SEA_R / ICE_R and
	those MUST stay in step, so a rebuild on a running server never clears a
	wider circle than it refills.

	  1300  SEA_R     the water disc; the fence stands ~220 in from its edge
	  1080  ICE_R     the pack ice, a one-voxel Ice sheet over the water
	   924  SLOPE_R   outer slope of the land, renders at -6 (under the ice)
	   834  SHORE_R   the shelf, renders at -2 (under the ice)
	   758  WET_R     the snow beach at the ice's edge, renders at 2, flush
	                  with the sheet
	   744  PLATEAU_R the island proper, lifted to 3.0

	The ice's top renders at ~2 (a full voxel topped at 0), the same as the WET
	ring, so a player walks off the beach onto the sea without a lip.
]]
local SEA_R = 1300
local ICE_R = 1080
local SEA_FLOOR = -12
local WIPE_TOP = 200
local SEA_TOP = -0.5                   -- what the fill is ASKED for
local SLOPE_R = 924
local SHORE_R = 834
local WET_R = 758
local PLATEAU_R = 744

----------------------------------------------------------------
-- The landing (copied from Ashfall's camp, which is the one precinct layout
-- every island keeps: services one flank, eggs the other, all facing the walk)
----------------------------------------------------------------
local DECK_Z0, DECK_Z1 = CZ - 404 - 2 * GROW, CZ - 368 - 2 * GROW   -- the pier's landward planks
local CAMP_Z0, CAMP_Z1 = CZ - 368 - 2 * GROW, CZ - 212 - 2 * GROW   -- the square, south kerb to north gate
local CAMP_HALF = 104                  -- the WEST half: the egg row
local EAST_HALF = 76                   -- the service flank
local LANE_HALF = 13
local LANE_Z1 = CZ - 176 - 2 * GROW    -- the road stops sixteen studs short of the square
local GATE_GAP = 19

local X0, X1 = CX - CAMP_HALF, CX + EAST_HALF

-- One frontage line, CX + 22, the same as Ashfall's.
local HALL = Vector3.new(CX + 32.6, GROUND, CZ - 320 - 2 * GROW)
local WASH = Vector3.new(CX + 30, GROUND, CZ - 240 - 2 * GROW)
local SHOP = Vector3.new(CX + 36, GROUND, CZ - 276 - 2 * GROW)
local CARPAD = Vector3.new(CX + 92, GROUND, CZ - 262 - 2 * GROW)
-- Must equal PetConfig.StationOverrides[8].row
local EGG_X, EGG_Z = CX - 28, CD - 280

----------------------------------------------------------------
-- The other districts, as centres and radii about the landmass
----------------------------------------------------------------
-- The village: south-west, between the square and the shore.
local VILLAGE = Vector3.new(CX - 520, GROUND, ICZ - 360)
local VILLAGE_R = 150
-- The colony: the whole east strand.
local COLONY = Vector3.new(CX + 560, GROUND, ICZ + 40)
local COLONY_R = 170
-- The fishing ground: east, out on the ice off the colony.
local FISHING = Vector3.new(CX + 900, 2, ICZ - 60)
-- The forest: the west flank, north of the village.
local FOREST = Vector3.new(CX - 560, GROUND, ICZ + 120)
local FOREST_R = 190
-- The frozen pond inside the forest.
local POND = Vector3.new(CX - 600, 0, ICZ + 200)
local POND_R = 46
-- The wreck's ground: the north shore. FrozenWreckBuilder builds there; this
-- file only keeps it clear. Its box is wide because the liner lies across.
local WRECK_X0, WRECK_X1 = CX - 160, CX + 190
local WRECK_Z0, WRECK_Z1 = FCZ + FIELD_HALF + 4, ICZ + PLATEAU_R + 60
-- The cliffs: two glacier walls on the north half, either side of the wreck.
local CLIFF_R0, CLIFF_R1 = 600, 740

----------------------------------------------------------------
-- Palette
----------------------------------------------------------------
local PALETTE = {
	snow = Color3.fromRGB(234, 240, 247),
	snowShade = Color3.fromRGB(208, 220, 234),
	ice = Color3.fromRGB(176, 212, 236),
	iceDeep = Color3.fromRGB(120, 168, 210),
	iceGlow = Color3.fromRGB(150, 226, 255),
	timber = Color3.fromRGB(142, 104, 70),
	timberDark = Color3.fromRGB(92, 66, 44),
	rope = Color3.fromRGB(196, 168, 118),
	iron = Color3.fromRGB(70, 74, 82),
	brass = Color3.fromRGB(196, 158, 78),
	red = Color3.fromRGB(196, 44, 48),
	green = Color3.fromRGB(52, 128, 88),
	gold = Color3.fromRGB(236, 196, 84),
	lanternWarm = Color3.fromRGB(255, 214, 140),
	stoneCold = Color3.fromRGB(126, 136, 150),
	stoneDark = Color3.fromRGB(78, 86, 98),
	canvas = Color3.fromRGB(226, 214, 190),
}
if Props and type(Props.PALETTE) == "table" then
	for k, v in pairs(Props.PALETTE) do
		if PALETTE[k] then
			PALETTE[k] = v
		end
	end
end

local function dk(c: Color3, f: number?): Color3
	return c:Lerp(Color3.new(0, 0, 0), f or 0.25)
end
local function lt(c: Color3, f: number?): Color3
	return c:Lerp(Color3.new(1, 1, 1), f or 0.25)
end

----------------------------------------------------------------
-- Small builders
----------------------------------------------------------------
local function P(parent, name, size, cf, colour, material, extra)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = colour or PALETTE.snow
	p.Material = material or Enum.Material.SmoothPlastic
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

-- A box from world bounds. Returns nil for a span that would collapse in
-- floating point, and every caller that needs the handle checks for it.
local function box(parent, name, x0, x1, y0, y1, z0, z1, colour, material, extra)
	local sx, sy, sz = x1 - x0, y1 - y0, z1 - z0
	if sx < 0.05 or sy < 0.05 or sz < 0.05 then
		return nil
	end
	return P(parent, name, Vector3.new(sx, sy, sz),
		CFrame.new((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5), colour, material, extra)
end

local function light(part: BasePart, colour: Color3, range: number, brightness: number)
	local l = Instance.new("PointLight")
	l.Color = colour
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = part
	return l
end

-- Terrain-only downcast; the sea is ignored so the shelf under the ice reads
-- as ground rather than as water.
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { Terrain }
groundParams.IgnoreWater = true

local function groundY(x: number, z: number, fallback: number): number
	local hit = workspace:Raycast(Vector3.new(x, 300, z), Vector3.new(0, -560, 0), groundParams)
	return hit and hit.Position.Y or fallback
end

-- Terrain collision lags the voxel write; a landmark placed on a miss floats.
local function groundYWait(x: number, z: number, fallback: number): number
	for _ = 1, 90 do
		local hit = workspace:Raycast(Vector3.new(x, 300, z), Vector3.new(0, -560, 0), groundParams)
		if hit then
			return hit.Position.Y
		end
		task.wait()
	end
	return fallback
end

local function waitForGround(): boolean
	for _ = 1, 240 do
		local a = workspace:Raycast(Vector3.new(CX, 300, CAMP_Z1), Vector3.new(0, -560, 0), groundParams)
		local b = workspace:Raycast(Vector3.new(CX + 500, 300, ICZ), Vector3.new(0, -560, 0), groundParams)
		if a and b then
			return true
		end
		task.wait()
	end
	warn("[Penguin] terrain never became raycastable; props are placed on the fallback height")
	return false
end

----------------------------------------------------------------
-- Clearance
----------------------------------------------------------------
local function clearOfField(x, z, r)
	return math.abs(x - FCX) > FIELD_HALF + r + 10 or math.abs(z - FCZ) > FIELD_HALF + r + 10
end

local function clearOfBox(x, z, r, bx0, bx1, bz0, bz1)
	return x + r + 6 < bx0 or x - r - 6 > bx1 or z + r + 6 < bz0 or z - r - 6 > bz1
end

-- CX-relative boxes nothing scattered may land in.
local KEEP_OUT = {
	{ CX - CAMP_HALF - 10, CX + EAST_HALF + 10, CAMP_Z0 - 10, CAMP_Z1 + 10 },   -- the landing
	{ CX - LANE_HALF - 12, CX + LANE_HALF + 12, DECK_Z0 - 8, LANE_Z1 + 6 },     -- causeway and road
	{ CX - 34, CX + 34, CZ - 500 - 2 * GROW, CZ - 388 - 2 * GROW },             -- the ferry berth and its sleigh
	{ CX + 66, CX + 122, CZ - 290 - 2 * GROW, LANE_Z1 + 6 },                    -- car pad and its drive
	{ WRECK_X0, WRECK_X1, WRECK_Z0, WRECK_Z1 },                                 -- the liner and its approach
	{ FCX - FIELD_HALF - 40, FCX - FIELD_HALF - 2, FCZ - 60, FCZ + 60 },        -- the leaderboard row (west edge)
	{ FCX + FIELD_HALF + 2, FCX + FIELD_HALF + 40, FCZ - 60, FCZ + 60 },        -- the free-reward sign (east edge)
	{ POND.X - POND_R - 8, POND.X + POND_R + 8, POND.Z - POND_R - 8, POND.Z + POND_R + 8 },
}

local function clearOfBuildings(x, z, r)
	for _, b in ipairs(KEEP_OUT) do
		if not clearOfBox(x, z, r, b[1], b[2], b[3], b[4]) then
			return false
		end
	end
	return true
end

local function onCliffs(x, z, margin)
	local dx, dz = x - CX, z - ICZ
	local d = math.sqrt(dx * dx + dz * dz)
	if d < CLIFF_R0 - margin or d > CLIFF_R1 + margin then
		return false
	end
	local a = math.atan2(dz, dx)       -- 0 = east, pi/2 = north (+z)
	-- two arcs, north-west and north-east, leaving the liner's bay between them
	return (a > 1.85 and a < 2.75) or (a > 0.45 and a < 1.25)
end

local function onLand(x, z)
	local dx, dz = x - CX, z - ICZ
	return dx * dx + dz * dz <= PLATEAU_R * PLATEAU_R
end

local function openGround(x, z, r)
	return clearOfField(x, z, r) and clearOfBuildings(x, z, r) and not onCliffs(x, z, r)
end

-- The finished island's real extents against the square, reporting only.
local STANDABLE = 8
local SHADOW = 6
local GROUNDED = 4

local function assertClearOfField(root: Instance): number
	local bad = 0
	local x0, x1 = FCX - FIELD_HALF - 2, FCX + FIELD_HALF + 2
	local z0, z1 = FCZ - FIELD_HALF - 2, FCZ + FIELD_HALF + 2
	for _, p in ipairs(root:GetDescendants()) do
		if p:IsA("BasePart") and p.CanCollide then
			local cf, s = p.CFrame, p.Size * 0.5
			local ex = math.abs(cf.RightVector.X) * s.X + math.abs(cf.UpVector.X) * s.Y + math.abs(cf.LookVector.X) * s.Z
			local ez = math.abs(cf.RightVector.Z) * s.X + math.abs(cf.UpVector.Z) * s.Y + math.abs(cf.LookVector.Z) * s.Z
			local ey = math.abs(cf.RightVector.Y) * s.X + math.abs(cf.UpVector.Y) * s.Y + math.abs(cf.LookVector.Y) * s.Z
			local px, py, pz = cf.Position.X, cf.Position.Y, cf.Position.Z
			local inX = px + ex > x0 and px - ex < x1
			local inZ = pz + ez > z0 and pz - ez < z1
			local low = (py - ey) < GROUND + STANDABLE
			if inX and inZ and low then
				bad += 1
				if bad <= 6 then
					warn(string.format("[Penguin] %s stands inside the rakeable square at (%.0f, %.0f, %.0f)",
						p:GetFullName(), px, py, pz))
				end
			end
		end
	end
	return bad
end

----------------------------------------------------------------
-- Terrain
----------------------------------------------------------------
--[[
	A SWIMMABLE CHANNEL NORTH TO THE BEACH'S OCEAN. The beach's water peters out
	around z -1000 and this sea's north edge is at z -1400; without a channel a
	swimmer who leaves the fence's reach drops off the edge of the world. Water
	bands stepped from -0.5 to 0.0 the way Ashfall's are, and every x/z bound a
	multiple of four.
]]
local CHANNEL_HALF = 360
local CHANNEL_Z0 = ICZ + SEA_R - 60         -- inside this disc
local CHANNEL_Z1 = -960                     -- inside the beach's sheet
local CHANNEL_BANDS = { -0.5, -0.4, -0.3, -0.2, -0.1, 0.0 }

local function bridgeToBeach()
	local zA = math.floor(CHANNEL_Z0 / 4) * 4
	local zB = math.ceil(CHANNEL_Z1 / 4) * 4
	local len = zB - zA
	if len <= 0 then
		return
	end
	local step = len / #CHANNEL_BANDS
	for i, top in ipairs(CHANNEL_BANDS) do
		local z0 = zA + (i - 1) * step
		local z1 = (i == #CHANNEL_BANDS) and zB or (zA + i * step)
		z0 = math.floor(z0 / 4) * 4
		z1 = math.floor(z1 / 4) * 4
		if z1 > z0 then
			Terrain:FillBlock(CFrame.new(CX, (SEA_FLOOR - 24) * 0.5, (z0 + z1) * 0.5),
				Vector3.new(CHANNEL_HALF * 2, SEA_FLOOR + 24, z1 - z0), SAND)
			Terrain:FillBlock(CFrame.new(CX, (top + SEA_FLOOR) * 0.5, (z0 + z1) * 0.5),
				Vector3.new(CHANNEL_HALF * 2, top - SEA_FLOOR, z1 - z0), Enum.Material.Water)
		end
	end
end

local function buildTerrain(): (number, number, number)
	local rng = Random.new(Config.SEED + 11207)

	-- Wipe first, so a rebuild on a running server never stacks a second
	-- island inside the first. Same radius as the sea below, and it must stay so.
	Terrain:FillCylinder(CFrame.new(CX, (WIPE_TOP + -24) * 0.5, ICZ),
		WIPE_TOP + 24, SEA_R, Enum.Material.Air)

	-- Seabed, then sea, reproducing the beach's own offshore column.
	Terrain:FillCylinder(CFrame.new(CX, (SEA_FLOOR - 24) * 0.5, ICZ),
		SEA_FLOOR + 24, SEA_R, SAND)
	Terrain:FillCylinder(CFrame.new(CX, (SEA_TOP + SEA_FLOOR) * 0.5, ICZ),
		SEA_TOP - SEA_FLOOR, SEA_R, Enum.Material.Water)

	bridgeToBeach()

	-- THE PACK ICE: one voxel of Ice over the water, out to ICE_R. Poured after
	-- the water so it replaces the top course rather than being replaced by it.
	Terrain:FillCylinder(CFrame.new(CX, -2, ICZ), 4, ICE_R, ICE)

	-- The island, as three discs from the seabed up, then the lift.
	local BOTTOM = SEA_FLOOR
	for _, ring in ipairs({
		{ r = SLOPE_R, top = -8 },
		{ r = SHORE_R, top = -4 },
		{ r = WET_R, top = 0 },
	}) do
		Terrain:FillCylinder(CFrame.new(CX, (BOTTOM + ring.top) * 0.5, ICZ),
			ring.top - BOTTOM, ring.r, SAND)
	end

	-- Lift the land to exactly the field's surface height. Region bounds are
	-- multiples of four; outside the disc is Air at zero.
	do
		local _, o3 = Config.occupancyFor(GROUND)
		local V = Config.VOXEL
		local LX0, LX1 = CX - (PLATEAU_R + 4), CX + (PLATEAU_R + 4)
		local LZ0, LZ1 = ICZ - (PLATEAU_R + 4), ICZ + (PLATEAU_R + 4)
		local nx = math.floor((LX1 - LX0) / V)
		local nz = math.floor((LZ1 - LZ0) / V)
		local region = Region3.new(Vector3.new(LX0, 0, LZ0), Vector3.new(LX1, V, LZ1)):ExpandToGrid(V)
		local r2 = PLATEAU_R * PLATEAU_R
		local mats, occs = table.create(nx), table.create(nx)
		for xi = 1, nx do
			local mx, ox = { table.create(nz) }, { table.create(nz) }
			mats[xi], occs[xi] = mx, ox
			local wx = LX0 + (xi - 0.5) * V
			local dx = wx - CX
			for zi = 1, nz do
				local wz = LZ0 + (zi - 0.5) * V
				local dz = wz - ICZ
				if dx * dx + dz * dz <= r2 then
					mx[1][zi], ox[1][zi] = SAND, o3
				else
					mx[1][zi], ox[1][zi] = Enum.Material.Air, 0
				end
			end
		end
		Terrain:WriteVoxels(region, V, mats, occs)
	end

	--[[
		THE CLIFFS: two glacier walls on the north half, either side of the bay
		the liner lies in, as stacked four-stud slabs on an arc. Poured in Ice
		rather than Glacier so they read as a wall of blue ice over a white
		beach -- and Ice's bumpiness is a feature on a cliff face.
	]]
	local cliffCourses = 0
	for _, arc in ipairs({ { a0 = 1.9, a1 = 2.7 }, { a0 = 0.5, a1 = 1.2 } }) do
		local steps = 14
		for s = 0, steps do
			local a = arc.a0 + (arc.a1 - arc.a0) * (s / steps)
			local d = (CLIFF_R0 + CLIFF_R1) * 0.5
			local x = CX + math.cos(a) * d
			local z = ICZ + math.sin(a) * d
			local h = 52 + 34 * math.sin((s / steps) * math.pi)      -- 52..86, tallest mid-arc
			local rr = 58 + 14 * math.sin(s * 1.7)
			local y = 2
			while y < h do
				local top = math.min(y + 4, h)
				local taper = 1 - (y / h) * 0.3
				Terrain:FillCylinder(CFrame.new(x, (y + top) * 0.5, z), top - y, rr * taper, ICE)
				y = top
				cliffCourses += 1
			end
			-- a broken crest and a snow cap, so the wall reads as a glacier's
			-- edge rather than a row of drums
			Terrain:FillBall(Vector3.new(x + rr * 0.3, h - 2, z + rr * 0.1), rr * 0.5, ICE)
			Terrain:FillBall(Vector3.new(x - rr * 0.25, h + 4, z - rr * 0.2), rr * 0.36, ICE)
			Terrain:FillCylinder(CFrame.new(x, h + 1, z), 2, rr * 0.66, SAND)
			Terrain:FillBall(Vector3.new(x + rr * 0.3, h + 2, z + rr * 0.1), rr * 0.3, SAND)
		end
	end

	-- The frozen pond in the forest: a disc of Ice let into the plateau.
	Terrain:FillCylinder(CFrame.new(POND.X, 0.5, POND.Z), 5, POND_R, Enum.Material.Air)
	Terrain:FillCylinder(CFrame.new(POND.X, -1, POND.Z), 4, POND_R - 2, ICE)

	-- Relief on the flat: low snow mounds, sunk balls like Ashfall's.
	local mounds = 0
	for _ = 1, 900 do
		if mounds >= 70 then
			break
		end
		local ang = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(FIELD_HALF + 60, PLATEAU_R - 30)
		local r = rng:NextNumber(12, 30)
		local x = CX + math.cos(ang) * dist
		local z = ICZ + math.sin(ang) * dist
		if openGround(x, z, r) then
			local lift = 0.2 + rng:NextNumber(0, 0.14)
			Terrain:FillBall(Vector3.new(x, GROUND - r * (1 - lift), z), r, SAND)
			mounds += 1
		end
	end

	--[[
		SNOW RIDGES, because a disc of flat snow 1500 studs across photographs
		as a plate. Chains of bigger balls on the outer ring in the gaps between
		the districts -- south-east, north-east, and the two flanks of the
		landing -- each ridge a run of six to eight overlapping hills up to
		twenty studs high, with an Ice core showing through the tallest so the
		crest reads as a glacier's back rather than a snowdrift. Terrain only:
		no parts.
	]]
	local ridges = 0
	for _, arc in ipairs({
		{ a0 = -0.95, a1 = -0.35, d = 640 },     -- south-east, between the colony and the landing
		{ a0 = 0.14, a1 = 0.42, d = 660 },       -- north-east, under the cliffs' end
		{ a0 = 3.05, a1 = 3.45, d = 620 },       -- west, between the forest and the village
		{ a0 = 4.15, a1 = 4.55, d = 600 },       -- south-west, the landing's far flank
		{ a0 = 1.32, a1 = 1.5, d = 700 },        -- north-east shore, beside the wreck's bay
	}) do
		local steps = 7
		for s = 0, steps do
			local a = arc.a0 + (arc.a1 - arc.a0) * (s / steps)
			local wobble = rng:NextNumber(-22, 22)
			local x = CX + math.cos(a) * (arc.d + wobble)
			local z = ICZ + math.sin(a) * (arc.d + wobble)
			local r = 26 + 14 * math.sin((s / steps) * math.pi) + rng:NextNumber(-3, 3)
			if openGround(x, z, r) then
				local lift = 0.42 + 0.12 * math.sin((s / steps) * math.pi)
				Terrain:FillBall(Vector3.new(x, GROUND - r * (1 - lift), z), r, SAND)
				if s == math.floor(steps / 2) then
					Terrain:FillBall(Vector3.new(x, GROUND - r * (1 - lift) + r * 0.3, z), r * 0.42, ICE)
				end
				ridges += 1
			end
		end
	end
	mounds += ridges

	--[[
		ICEBERGS, out on the sheet: Ice balls sunk into the pack so a berg is a
		hill of ice rising out of ice, the biggest of them forty studs high. The
		west and north-west get the field; the berth's lane and the liner's bay
		stay clear.
	]]
	local bergs = 0
	for _ = 1, 600 do
		if bergs >= 28 then
			break
		end
		local ang = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(WET_R + 60, ICE_R - 40)
		local x = CX + math.cos(ang) * dist
		local z = ICZ + math.sin(ang) * dist
		-- not across the berth's run (south of the landing), not off the wreck's bay
		local inBerthLane = math.abs(x - CX) < 90 and z < CAMP_Z0
		local inWreckBay = x > WRECK_X0 - 40 and x < WRECK_X1 + 40 and z > WRECK_Z0
		if not inBerthLane and not inWreckBay then
			local big = rng:NextNumber() < 0.35
			local r = big and rng:NextNumber(34, 56) or rng:NextNumber(12, 22)
			Terrain:FillBall(Vector3.new(x, rng:NextNumber(-4, 4) - r * 0.3, z), r, ICE)
			if big then
				-- a second and third lobe and a snow cap, so the big ones read
				-- as bergs and not as marbles; the tallest stand forty studs
				Terrain:FillBall(Vector3.new(x + r * 0.45, r * 0.3, z + r * 0.2), r * 0.62, ICE)
				Terrain:FillBall(Vector3.new(x - r * 0.35, r * 0.15, z - r * 0.3), r * 0.5, ICE)
				Terrain:FillBall(Vector3.new(x, r * 0.66, z), r * 0.48, SAND)
			end
			bergs += 1
		end
	end

	-- Cracks in the sheet: a few open leads, wide enough to read from a hill
	-- and narrow enough to jump. Water cut back into the ice course.
	for i = 1, 5 do
		local ang = i * 1.25 + 0.4
		local d0 = WET_R + 90
		local len = rng:NextNumber(120, 240)
		local x = CX + math.cos(ang) * (d0 + len * 0.5)
		local z = ICZ + math.sin(ang) * (d0 + len * 0.5)
		if not (math.abs(x - CX) < 90 and z < CAMP_Z0) and not (x > WRECK_X0 - 40 and x < WRECK_X1 + 40 and z > WRECK_Z0) then
			Terrain:FillBlock(CFrame.new(x, -2, z) * CFrame.Angles(0, -ang, 0),
				Vector3.new(len, 4, 8), Enum.Material.Water)
		end
	end

	return mounds, bergs, cliffCourses
end

----------------------------------------------------------------
-- THE AURORA. Six ribbons of Neon strung across the sky over the island,
-- each a chain of straight segments on an arc; the client shimmers their
-- colour. No lights, no emitters: at this height the Neon is the whole show.
----------------------------------------------------------------
local function buildAurora(parent): (Model, number)
	local m = Instance.new("Model")
	m.Name = "Sky"
	m.Parent = parent
	local rng = Random.new(Config.SEED + 6060)
	local made = 0
	for i = 1, 6 do
		local y = 250 + i * 12
		local span = 1200 + i * 90
		local x0 = CX - span * 0.5
		local zc = ICZ + 140 - i * 80
		local segs = 9
		local tilt = rng:NextNumber(-0.06, 0.06)
		for s = 0, segs - 1 do
			local t0, t1 = s / segs, (s + 1) / segs
			local a = Vector3.new(x0 + span * t0, y + 40 * math.sin(t0 * math.pi) + 18 * math.sin(t0 * 5 + i), zc + 60 * math.sin(t0 * 2.3))
			local b = Vector3.new(x0 + span * t1, y + 40 * math.sin(t1 * math.pi) + 18 * math.sin(t1 * 5 + i), zc + 60 * math.sin(t1 * 2.3))
			local p = P(m, "Aurora", Vector3.new(24 + 8 * math.sin(s + i), 0.6, (b - a).Magnitude + 2),
				CFrame.lookAt((a + b) * 0.5, b) * CFrame.Angles(0, 0, tilt),
				(i % 2 == 0) and Color3.fromRGB(110, 250, 190) or Color3.fromRGB(150, 130, 250),
				Enum.Material.Neon,
				{ CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
			p:SetAttribute("Phase", i * 0.9 + s * 0.35)
			made += 1
		end
	end
	return m, made
end

----------------------------------------------------------------
-- THE LANDING  --  the precinct, Ashfall's plan on snow
----------------------------------------------------------------
local function buildLanding(parent): (Model, BasePart, number)
	local m = Instance.new("Model")
	m.Name = "Landing"
	m.Parent = parent
	local G = GROUND
	local lamps = 0

	-- A lamp post through the kit, alternately lit; counts the lights.
	local function lamp(cf: CFrame, lit: boolean)
		local made = prop("lampPost", m, cf, 11, lit)
		if made and lit then
			lamps += 1
		end
		return made
	end

	-- The causeway: planks from the pier's landward end up to the square.
	for z = DECK_Z0, DECK_Z1 - 2, 2 do
		box(m, "Plank", CX - 8, CX + 8, G - 0.5, G + 0.12, z + 0.2, z + 1.8, PALETTE.timber, Enum.Material.WoodPlanks)
	end
	box(m, "PlankSnow", CX - 8, CX + 8, G + 0.12, G + 0.24, DECK_Z0, DECK_Z1, PALETTE.snow, Enum.Material.Snow, { CanCollide = false })

	-- The square: packed snow, a step above the plateau, with an ice kerb.
	box(m, "Paving", X0, X1, G - 0.5, G + 0.12, CAMP_Z0, CAMP_Z1, PALETTE.snowShade, Enum.Material.Snow)
	for _, k in ipairs({
		{ X0 - 1.2, X0, CAMP_Z0, CAMP_Z1 },
		{ X1, X1 + 1.2, CAMP_Z0, CARPAD.Z - 26 },        -- broken for the car pad
		{ X1, X1 + 1.2, CARPAD.Z + 26, CAMP_Z1 },
		{ X0 - 1.2, CX - GATE_GAP, CAMP_Z0 - 1.2, CAMP_Z0 },
		{ CX + GATE_GAP, X1 + 1.2, CAMP_Z0 - 1.2, CAMP_Z0 },
		{ X0 - 1.2, CX - GATE_GAP, CAMP_Z1, CAMP_Z1 + 1.2 },
		{ CX + GATE_GAP, X1 + 1.2, CAMP_Z1, CAMP_Z1 + 1.2 },
	}) do
		box(m, "Kerb", k[1], k[2], G - 0.5, G + 0.6, k[3], k[4], PALETTE.ice, Enum.Material.Ice)
	end

	-- The road north to the field: trodden snow, darker, no collision.
	box(m, "SnowRoad", CX - LANE_HALF, CX + LANE_HALF, G + 0.12, G + 0.2, CAMP_Z0, LANE_Z1,
		dk(PALETTE.snowShade, 0.12), Enum.Material.Snow, { CanCollide = false })

	-- Ground under the egg row, which PetStationBuilder places off PetConfig.
	box(m, "EggForecourt", EGG_X - 14, CX - LANE_HALF - 0.6, G - 0.5, G + 0.42, EGG_Z - 58, EGG_Z + 58,
		lt(PALETTE.snowShade, 0.1), Enum.Material.Snow)

	----------------------------------------------------------------
	-- THE WEIGH HOUSE  --  the sell hall, and the pad that pays out
	----------------------------------------------------------------
	local HX0, HX1 = HALL.X - 9, HALL.X + 9
	local HZ0, HZ1 = HALL.Z - 17, HALL.Z + 17
	local DECK_TOP = G + 1.7
	local padX, padZ = HALL.X, HALL.Z
	P(m, "PadFrame", Vector3.new(16.4, 0.3, 23.4), CFrame.new(padX, DECK_TOP + 0.27, padZ),
		PALETTE.iceDeep, Enum.Material.Ice, { CanCollide = false })
	P(m, "PadGlow", Vector3.new(14.4, 0.24, 21.4), CFrame.new(padX, DECK_TOP + 0.42, padZ),
		PALETTE.iceGlow, Enum.Material.Neon, { CanCollide = false })
	local pad = P(m, "SellPad", Vector3.new(13, 0.45, 20),
		CFrame.new(padX, DECK_TOP + 0.52, padZ), lt(PALETTE.ice, 0.2), Enum.Material.Ice)

	for i = 1, 2 do
		box(m, "HallStep", HX0 - 3.4 + (i - 1) * 1.7, HX0 - 1.7 + (i - 1) * 1.7,
			G - 0.5, G + 0.55 * i + 0.6, HZ0 + 5, HZ1 - 5, PALETTE.stoneCold, Enum.Material.Slate)
	end
	box(m, "HallPlinth", HX0 - 1.6, HX1 + 1.6, G - 0.5, G + 1.1, HZ0 - 1.6, HZ1 + 1.6, PALETTE.stoneCold, Enum.Material.Slate)
	box(m, "HallDeck", HX0, HX1, G + 1.1, G + 1.7, HZ0, HZ1, PALETTE.timber, Enum.Material.WoodPlanks)
	box(m, "HallBack", HX1 - 0.8, HX1, G + 1.7, G + 13, HZ0, HZ1, PALETTE.timberDark, Enum.Material.Wood)
	for _, s in ipairs({ -1, 1 }) do
		box(m, "HallWall", HX0, HX1, G + 1.7, G + 13,
			(s < 0) and HZ0 or (HZ1 - 0.8), (s < 0) and (HZ0 + 0.8) or HZ1, PALETTE.timberDark, Enum.Material.Wood)
		box(m, "HallPost", HX0 - 0.4, HX0 + 1.4, G + 1.7, G + 13,
			HALL.Z + s * 15 - 0.9, HALL.Z + s * 15 + 0.9, PALETTE.timber, Enum.Material.Wood)
	end
	for i = 0, 3 do
		box(m, "HallRoof" .. i, HX0 - 4 + i * 2.6, HX1 + 4 - i * 2.6, G + 13 + i * 1.2, G + 14.2 + i * 1.2,
			HZ0 - 3 + i * 0.8, HZ1 + 3 - i * 0.8,
			(i == 0) and PALETTE.timberDark or PALETTE.snow, (i == 0) and Enum.Material.Wood or Enum.Material.Snow,
			{ CanCollide = false })
	end
	local sellBoard = box(m, "SellBoard", HX0 - 0.8, HX0 - 0.3, G + 8.4, G + 12.4,
		HALL.Z - 12, HALL.Z + 12, PALETTE.timberDark, Enum.Material.Wood)
	if sellBoard then
		SignKit.dress(sellBoard, "SELL YOUR FINDS", { Enum.NormalId.Right, Enum.NormalId.Left })
	end
	lamp(CFrame.new(HALL.X - 12, G, HALL.Z - 20), true)
	lamp(CFrame.new(HALL.X - 12, G, HALL.Z + 20), false)

	----------------------------------------------------------------
	-- THE TRADING POST  --  the shop
	----------------------------------------------------------------
	do
		local facing = CFrame.lookAt(Vector3.new(SHOP.X, G, SHOP.Z), Vector3.new(CX, G, SHOP.Z))
		box(m, "ShopPlinth", SHOP.X - 14, SHOP.X + 14, G - 0.5, G + 0.42, SHOP.Z - 13, SHOP.Z + 13,
			PALETTE.stoneCold, Enum.Material.Slate)
		local stall = prop("tradingPost", m, facing * CFrame.new(0, 0.42, 0))
		local board = stall and stall:FindFirstChild("ShopBoard", true)
		if board and board:IsA("BasePart") then
			SignKit.dress(board, "UPGRADES", { Enum.NormalId.Front, Enum.NormalId.Back })
		end

		-- The prompt hangs on a part THIS FILE owns.
		local anchor = P(m, "PromptAnchor", Vector3.new(1, 1, 1),
			facing * CFrame.new(0, 5.2, -9),
			PALETTE.snow, Enum.Material.SmoothPlastic,
			{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
		local shopPrompt = Instance.new("ProximityPrompt")
		shopPrompt.Name = "ShopPrompt"
		shopPrompt.ActionText = "Browse"
		shopPrompt.ObjectText = "Penguin Outfitters"
		shopPrompt.KeyboardKeyCode = Enum.KeyCode.E
		shopPrompt.HoldDuration = 0
		shopPrompt.MaxActivationDistance = 16
		shopPrompt.RequiresLineOfSight = false
		shopPrompt.Parent = anchor

		if not board then
			-- the kit gave no board: a plain one, so the verb is still on the street
			local b = P(m, "ShopBoard", Vector3.new(22, 4.2, 0.5), facing * CFrame.new(0, 12.6, -9.6),
				PALETTE.timberDark, Enum.Material.Wood)
			SignKit.dress(b, "UPGRADES", { Enum.NormalId.Front, Enum.NormalId.Back })
			for _, s in ipairs({ -1, 1 }) do
				P(m, "BoardPost", Vector3.new(0.8, 13, 0.8), facing * CFrame.new(s * 10.6, 6.5, -9.6),
					PALETTE.timber, Enum.Material.Wood)
			end
		end
		lamp(facing * CFrame.new(-14, 0.42, -11), true)
		lamp(facing * CFrame.new(14, 0.42, -11), false)
	end

	----------------------------------------------------------------
	-- THE WASH BAY  --  a clone of the authored beach shack, the way every
	-- island's is: that is the model WashServer knows how to bind.
	----------------------------------------------------------------
	local authored = workspace:FindFirstChild("WashBay")
	if authored and authored:IsA("Model") then
		local rig = authored:Clone()
		rig.Name = "PenguinWashBay"
		rig:PivotTo(CFrame.new(WASH.X, 0, WASH.Z) * CFrame.Angles(0, -math.pi * 0.5, 0))
		local bcf, bsize = rig:GetBoundingBox()
		rig:PivotTo(rig:GetPivot() + Vector3.new(
			WASH.X - bcf.Position.X,
			(G + 0.12) - (bcf.Position.Y - bsize.Y * 0.5),
			WASH.Z - bcf.Position.Z))
		rig.Parent = m
		for _, p in ipairs(rig:GetDescendants()) do
			if p:IsA("BasePart") then
				local n = p.Name:match("^Stripe(%d+)$")
				if n then
					p.Color = (tonumber(n) % 2 == 0) and PALETTE.snow or PALETTE.red
				elseif p.Name == "SignBoard" then
					p.Color = PALETTE.timberDark
				end
			end
		end
		-- A heated trough on the far shoulder, steaming: the one warm thing on
		-- the flank, and the reason the bay is not frozen solid.
		box(m, "Trough", WASH.X + 9, WASH.X + 15, G + 0.12, G + 3.2, WASH.Z + 8, WASH.Z + 16,
			PALETTE.stoneDark, Enum.Material.Slate)
		local water = box(m, "TroughWater", WASH.X + 9.6, WASH.X + 14.4, G + 2.7, G + 3.0, WASH.Z + 8.6, WASH.Z + 15.4,
			Color3.fromRGB(120, 174, 186), Enum.Material.Glass,
			{ CanCollide = false, Transparency = 0.35, Reflectance = 0.25 })
		if water then
			local steam = Instance.new("ParticleEmitter")
			steam.Texture = "rbxasset://textures/particles/smoke_main.dds"
			steam.Color = ColorSequence.new(Color3.fromRGB(240, 246, 250))
			steam.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 1) })
			steam.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 3.4) })
			steam.Lifetime = NumberRange.new(1.6, 2.6)
			steam.Rate = 6
			steam.Speed = NumberRange.new(1, 2)
			steam.Rotation = NumberRange.new(0, 360)
			steam.RotSpeed = NumberRange.new(-20, 20)
			steam.LightEmission = 0.1
			steam.Parent = water
		end
	else
		warn("[Penguin] workspace.WashBay is missing -- the landing has no wash bay")
	end

	----------------------------------------------------------------
	-- THE VEHICLE PAD, outside the east kerb, SpawnPoint facing north
	----------------------------------------------------------------
	local okCar, carErr = pcall(function()
		local CarSpawnerBuilder = require(script.Parent:WaitForChild("CarSpawnerBuilder"))
		local carPad = CarSpawnerBuilder.build(CFrame.new(CARPAD.X, G + 0.2, CARPAD.Z), { sign = "CAR SPAWN" })
		carPad.Name = "PenguinCarSpawner"
		carPad.Parent = m
		for _, p in ipairs(carPad:GetChildren()) do
			if p:IsA("BasePart") and (p.Name == "SignPost" or p.Name == "SignBoard" or p.Name == "SignTrim") then
				p.Position = Vector3.new(2 * CARPAD.X - p.Position.X, p.Position.Y, p.Position.Z)
			end
		end
	end)
	if not okCar then
		warn("[Penguin] no vehicle pad at the landing:", carErr)
	end
	box(m, "CarApron", X1 - 2, CARPAD.X - 10, G - 0.5, G + 0.12, CARPAD.Z - 13, CARPAD.Z + 13,
		PALETTE.snowShade, Enum.Material.Snow)
	box(m, "Drive", CARPAD.X - 9, CARPAD.X + 9, G + 0.02, G + 0.1, CARPAD.Z + 11, LANE_Z1,
		dk(PALETTE.snowShade, 0.14), Enum.Material.Snow, { CanCollide = false })
	for _, s in ipairs({ -1, 1 }) do
		box(m, "DriveRut", CARPAD.X + s * 3.4 - 0.9, CARPAD.X + s * 3.4 + 0.9, G + 0.1, G + 0.16,
			CARPAD.Z + 11, LANE_Z1, dk(PALETTE.snowShade, 0.28), Enum.Material.Snow, { CanCollide = false })
	end

	----------------------------------------------------------------
	-- THE TWO GATES
	----------------------------------------------------------------
	do
		local gateZ = CAMP_Z1
		for _, s in ipairs({ -1, 1 }) do
			box(m, "GatePost", CX + s * GATE_GAP - 3, CX + s * GATE_GAP + 3, G, G + 18, gateZ - 3, gateZ + 3,
				PALETTE.ice, Enum.Material.Ice)
			box(m, "GateFoot", CX + s * GATE_GAP - 4.4, CX + s * GATE_GAP + 4.4, G, G + 2.4, gateZ - 4.4, gateZ + 4.4,
				PALETTE.iceDeep, Enum.Material.Ice)
			lamp(CFrame.new(CX + s * (GATE_GAP + 9), G + 0.12, gateZ), true)
		end
		box(m, "GateLintel", CX - GATE_GAP - 5, CX + GATE_GAP + 5, G + 18, G + 22, gateZ - 3.6, gateZ + 3.6,
			lt(PALETTE.ice, 0.12), Enum.Material.Ice)
		box(m, "GateSnow", CX - GATE_GAP - 5, CX + GATE_GAP + 5, G + 22, G + 23.2, gateZ - 3.8, gateZ + 3.8,
			PALETTE.snow, Enum.Material.Snow, { CanCollide = false })
		local nameBoard = box(m, "NameBoard", CX - 16, CX + 16, G + 22.4, G + 27.2, gateZ - 0.8, gateZ - 0.3,
			PALETTE.timberDark, Enum.Material.Wood)
		if nameBoard then
			SignKit.dress(nameBoard, "PENGUIN LANDING", { Enum.NormalId.Front, Enum.NormalId.Back })
		end
		prop("stringLights", m, Vector3.new(CX - GATE_GAP - 2, G + 17.4, gateZ - 3.8), Vector3.new(CX + GATE_GAP + 2, G + 17.4, gateZ - 3.8), 12)
	end
	do
		local gateZ = CAMP_Z0
		for _, s in ipairs({ -1, 1 }) do
			box(m, "ArrivalPost", CX + s * GATE_GAP - 2.2, CX + s * GATE_GAP + 2.2, G, G + 13, gateZ - 2.2, gateZ + 2.2,
				PALETTE.timber, Enum.Material.Wood)
		end
		box(m, "ArrivalBeam", CX - GATE_GAP - 3, CX + GATE_GAP + 3, G + 13, G + 14.4, gateZ - 1.2, gateZ + 1.2,
			PALETTE.timberDark, Enum.Material.Wood, { CanCollide = false })
		prop("stringLights", m, Vector3.new(CX - GATE_GAP, G + 12.6, gateZ), Vector3.new(CX + GATE_GAP, G + 12.6, gateZ), 10)
		local welcome = box(m, "WelcomeBoard", CX - 9, CX + 9, G + 14.6, G + 17.6, gateZ - 0.5, gateZ + 0.5,
			PALETTE.timberDark, Enum.Material.Wood)
		if welcome then
			SignKit.dress(welcome, "WELCOME TO THE ICE", { Enum.NormalId.Front, Enum.NormalId.Back })
		end
	end

	----------------------------------------------------------------
	-- THE SQUARE'S DRESSING. The tree first: a snow pine in the middle of
	-- the walk's west side hung with lights and presents under it, because
	-- the ferryman on this island is who he is and the landing should say so
	-- before he does.
	----------------------------------------------------------------
	do
		local tx, tz = CX - 60, CD - 214
		local tree = prop("snowPine", m, CFrame.new(tx, G + 0.12, tz), 30, 77)
		if tree then
			for i = 0, 3 do
				local a0, a1 = i * 1.57, (i + 1) * 1.57
				local r = 9 - i * 1.2
				local y = G + 8 + i * 5
				prop("stringLights", m, Vector3.new(tx + math.cos(a0) * r, y, tz + math.sin(a0) * r),
					Vector3.new(tx + math.cos(a1) * r, y + 1.5, tz + math.sin(a1) * r), 7)
			end
		end
		prop("presentStack", m, CFrame.new(tx + 6, G + 0.12, tz + 3) * CFrame.Angles(0, 0.4, 0))
		prop("presentStack", m, CFrame.new(tx - 5, G + 0.12, tz + 5) * CFrame.Angles(0, -1.1, 0))
		prop("snowman", m, CFrame.new(tx + 12, G + 0.12, tz - 8) * CFrame.Angles(0, 2.4, 0), 1.0)
	end

	local dressing = {
		{ "supplyCrate", -70, -300, 1.0 }, { "supplyCrate", -74, -296, 0.8 }, { "fuelBarrel", -66, -304 },
		{ "sled", -88, -270 }, { "supplyCrate", 60, -352, 1.1 }, { "fuelBarrel", 66, -350 },
		{ "snowman", -92, -340, 0.9 }, { "cairn", 62, -220, 5 }, { "campfire", -50, -330, true },
		{ "supplyCrate", -46, -336, 0.9 }, { "sled", 64, -236 }, { "snowDrift", -96, -246, 1.2 },
		{ "snowDrift", 70, -300, 1.0 }, { "signpost", -20, -206, { "SNOWFIELD", "VILLAGE", "COLONY" } },
	}
	local seedR = Random.new(Config.SEED + 4141)
	for _, d in ipairs(dressing) do
		local x, z = CX + d[2], CD + d[3]
		local cf = CFrame.new(x, G + 0.12, z) * CFrame.Angles(0, seedR:NextNumber(0, 6.28), 0)
		if d[1] == "signpost" then
			cf = CFrame.new(x, G + 0.12, z) * CFrame.Angles(0, math.pi, 0)
		end
		local made = prop(d[1], m, cf, d[4])
		if made and d[1] == "campfire" then
			lamps += 1
		end
	end
	-- lamps along both kerbs, every other one lit
	for i = 0, 3 do
		local z = CAMP_Z0 + 20 + i * 38
		lamp(CFrame.new(X0 + 2.5, G + 0.12, z), i % 2 == 0)
		lamp(CFrame.new(X1 - 2.5, G + 0.12, z + 12), i % 2 == 1)
	end
	-- and a fence along the west kerb, north of the egg row
	prop("ropeFence", m, Vector3.new(X0 - 4, G, EGG_Z + 62), Vector3.new(X0 - 4, G, CAMP_Z1 - 6))

	return m, pad, lamps
end

----------------------------------------------------------------
-- THE VILLAGE  --  igloos and cabins between the square and the west shore
----------------------------------------------------------------
local function buildVillage(parent, rng: Random): (Model, number)
	local m = Instance.new("Model")
	m.Name = "Village"
	m.Parent = parent
	local lights = 0
	local vx, vz = VILLAGE.X, VILLAGE.Z
	local G = GROUND

	local function at(dx, dz, yaw)
		local x, z = vx + dx, vz + dz
		return CFrame.new(x, groundY(x, z, G) + 0.05, z) * CFrame.Angles(0, yaw or 0, 0), x, z
	end

	-- a ring of homes round a fire, doors to the middle
	local homes = {
		{ "igloo", 0, -70, 0, 1.2 }, { "igloo", 62, -44, -0.9, 1.0 }, { "igloo", -66, -40, 0.9, 1.1 },
		{ "snowCabin", 74, 24, -1.9, 1.0, true }, { "snowCabin", -78, 30, 1.9, 1.0, false },
		{ "snowCabin", 8, 78, 3.14, 1.15, true }, { "igloo", -30, 74, 2.6, 0.9 }, { "igloo", 48, 66, -2.6, 1.3 },
	}
	for _, h in ipairs(homes) do
		local cf, x, z = at(h[2], h[3], h[4])
		if openGround(x, z, 16) then
			local made = prop(h[1], m, cf, h[5], h[6])
			if made and h[6] then
				lights += 1
			end
		end
	end

	-- the fire in the middle, and the things a camp keeps round it
	local cf = at(0, 0, 0)
	if prop("campfire", m, cf, true) then
		lights += 1
	end
	prop("supplyCrate", m, at(9, 6, 0.6), 1.0)
	prop("supplyCrate", m, at(11, 9, 1.4), 0.8)
	prop("fuelBarrel", m, at(-10, 7, 0))
	prop("sled", m, at(-12, -8, 2.2))
	prop("presentStack", m, at(12, -6, 0.3))

	-- the research station on the shore side of the ring
	prop("researchStation", m, at(-20, -130, 0.4))
	prop("flagPole", m, at(-42, -122, 0), PALETTE.red)
	prop("flagPole", m, at(4, -140, 0), PALETTE.green)

	-- lamps on the paths, alternately lit; a fence round the north side
	for i, o in ipairs({ { 30, -20 }, { -34, -16 }, { 36, 40 }, { -40, 46 }, { 0, -100 }, { 0, 44 } }) do
		local lcf = at(o[1], o[2], 0)
		local lit = i % 2 == 1
		if prop("lampPost", m, lcf, 11, lit) and lit then
			lights += 1
		end
	end
	prop("ropeFence", m, Vector3.new(vx - 96, G, vz + 60), Vector3.new(vx + 96, G, vz + 60))
	prop("stringLights", m, Vector3.new(vx + 74, G + 12, vz + 24), Vector3.new(vx + 8, G + 12, vz + 78), 14)
	prop("stringLights", m, Vector3.new(vx - 78, G + 12, vz + 30), Vector3.new(vx + 8, G + 12, vz + 78), 14)

	-- snowmen and sculptures the village has made of its winter
	for _, s in ipairs({ { 24, -58, 0.9 }, { -50, 10, 1.1 }, { 58, 4, 1.0 } }) do
		prop("snowman", m, at(s[1], s[2], rng:NextNumber(0, 6.28)), s[3])
	end
	for i = 1, 4 do
		prop("iceSculpture", m, at(-64 + i * 32, -96, 0), 300 + i)
	end
	prop("signpost", m, at(0, -22, 0), { "LANDING", "FOREST", "THE WRECK" })

	for _ = 1, 5 do
		local dx, dz = rng:NextNumber(-130, 130), rng:NextNumber(-140, 110)
		local x, z = vx + dx, vz + dz
		if openGround(x, z, 8) then
			prop("snowDrift", m, CFrame.new(x, groundY(x, z, G), z), rng:NextNumber(0.9, 1.5))
		end
	end

	return m, lights
end

----------------------------------------------------------------
-- THE FOREST  --  the west flank, and the pond inside it
----------------------------------------------------------------
local function buildForest(parent, rng: Random, spaced, claim): (Model, number)
	local m = Instance.new("Model")
	m.Name = "Forest"
	m.Parent = parent
	local G = GROUND
	local trees = 0
	for _ = 1, 1400 do
		if trees >= 84 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(0, FOREST_R)
		local x, z = FOREST.X + math.cos(a) * d, FOREST.Z + math.sin(a) * d
		if onLand(x, z) and openGround(x, z, 9) and spaced(x, z, 8) then
			local y = groundY(x, z, G)
			if math.abs(y - G) < 5 then
				local h = rng:NextNumber(14, 27)
				local made
				if rng:NextNumber() < 0.84 then
					made = prop("snowPine", m, CFrame.new(x, y, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), h, trees)
				else
					made = prop("deadPine", m, CFrame.new(x, y, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), h * 0.8, trees)
				end
				if made then
					trees += 1
					claim(x, z, 8)
				end
			end
		end
	end

	-- a lamplit trail from the village into the trees, and a jetty on the pond
	for i = 0, 4 do
		local t = i / 4
		local x = VILLAGE.X + (POND.X - VILLAGE.X) * t
		local z = (VILLAGE.Z + 70) + ((POND.Z - 60) - (VILLAGE.Z + 70)) * t
		if openGround(x, z, 3) then
			prop("lampPost", m, CFrame.new(x + 6, groundY(x + 6, z, G), z), 10, false)
			claim(x + 6, z, 3)
		end
	end
	prop("jetty", m, Vector3.new(POND.X - POND_R - 6, G, POND.Z - 4), Vector3.new(POND.X - 8, G, POND.Z - 4))
	prop("dockLantern", m, CFrame.new(POND.X - 10, G, POND.Z + 1), true)
	prop("fishingHole", m, CFrame.new(POND.X + 8, 2.4, POND.Z + 10) * CFrame.Angles(0, 0.7, 0))
	prop("signpost", m, CFrame.new(FOREST.X + 40, G, FOREST.Z - 150) * CFrame.Angles(0, 0.5, 0), { "THE POND", "VILLAGE" })

	-- cairns and drifts under the trees
	for _ = 1, 10 do
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(20, FOREST_R)
		local x, z = FOREST.X + math.cos(a) * d, FOREST.Z + math.sin(a) * d
		if onLand(x, z) and openGround(x, z, 5) and spaced(x, z, 5) then
			if rng:NextNumber() < 0.5 then
				prop("cairn", m, CFrame.new(x, groundY(x, z, G), z), rng:NextNumber(4, 7))
			else
				prop("snowDrift", m, CFrame.new(x, groundY(x, z, G), z), rng:NextNumber(0.9, 1.6))
			end
			claim(x, z, 5)
		end
	end
	return m, trees
end

----------------------------------------------------------------
-- THE COLONY  --  the east strand, and the fishing ground on the ice off it
----------------------------------------------------------------
local function buildColony(parent, rng: Random, spaced, claim): (Model, number, number)
	local m = Instance.new("Model")
	m.Name = "Colony"
	m.Parent = parent
	local birdsFolder = Instance.new("Folder")
	birdsFolder.Name = "Penguins"
	birdsFolder.Parent = parent
	local G = GROUND
	local birds, lights = 0, 0

	local function bird(x, z, yaw, opts)
		if not Birds then
			return nil
		end
		local y = groundY(x, z, G)
		local ok, made = pcall(Birds.spawn, birdsFolder, CFrame.new(x, y + 0.02, z) * CFrame.Angles(0, yaw, 0), opts)
		if ok and made then
			birds += 1
			return made
		end
		return nil
	end

	-- THE ROOKERY: a dense huddle round the colony's centre, facing in, with
	-- chicks in the middle and a few emperors on the edge.
	local cx, cz = COLONY.X, COLONY.Z
	for _ = 1, 900 do
		if birds >= 48 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(6, COLONY_R * 0.55)
		local x, z = cx + math.cos(a) * d, cz + math.sin(a) * d
		if onLand(x, z) and openGround(x, z, 3) and spaced(x, z, 3.2) then
			local class = (d < 26) and ((rng:NextNumber() < 0.6) and "chick" or "adult")
				or ((rng:NextNumber() < 0.12) and "emperor" or "adult")
			local acc = nil
			local roll = rng:NextNumber()
			if roll < 0.08 then acc = "scarf" elseif roll < 0.13 then acc = "beanie" elseif roll < 0.16 then acc = "bow" end
			-- faces the middle of the huddle, more or less
			local yaw = math.atan2(cx - x, -(cz - z)) + rng:NextNumber(-0.6, 0.6)
			if bird(x, z, yaw, { class = class, accessory = acc, colour = (roll < 0.04) and PALETTE.green or nil, seed = birds * 37, roam = 10 }) then
				claim(x, z, 3.2)
			end
		end
	end
	-- nests among them
	for _ = 1, 200 do
		local made = 0
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(10, COLONY_R * 0.6)
		local x, z = cx + math.cos(a) * d, cz + math.sin(a) * d
		if onLand(x, z) and openGround(x, z, 3) and spaced(x, z, 3.5) then
			if prop("penguinNest", m, CFrame.new(x, groundY(x, z, G), z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0)) then
				claim(x, z, 3.5)
				made += 1
			end
		end
		if made >= 14 then
			break
		end
	end

	-- The viewing fence and a signboard, on the field side of the strand.
	prop("ropeFence", m, Vector3.new(cx - 120, G, cz - 110), Vector3.new(cx - 120, G, cz + 110))
	prop("signpost", m, CFrame.new(cx - 126, G, cz - 118) * CFrame.Angles(0, -math.pi * 0.5, 0), { "THE COLONY", "FISHING" })
	for i = 0, 3 do
		local lit = i % 2 == 0
		if prop("lampPost", m, CFrame.new(cx - 124, G, cz - 90 + i * 60), 10, lit) and lit then
			lights += 1
		end
	end

	-- Stragglers on the strand, every one of them a coin.
	for _ = 1, 400 do
		if birds >= 66 then
			break
		end
		local a = rng:NextNumber(-1.2, 1.2)
		local d = rng:NextNumber(FIELD_HALF + 70, PLATEAU_R - 20)
		local x, z = CX + math.cos(a) * d, ICZ + math.sin(a) * d
		if onLand(x, z) and openGround(x, z, 3) and spaced(x, z, 4) then
			if bird(x, z, rng:NextNumber(0, 6.28), { class = "adult", seed = birds * 53, roam = 14 }) then
				claim(x, z, 4)
			end
		end
	end

	-- THE FISHING GROUND, out on the ice: a jetty from the beach, holes cut in
	-- the sheet, lanterns at the jetty's end, and birds where the fish are.
	local fx, fz = FISHING.X, FISHING.Z
	prop("jetty", m, Vector3.new(WET_R - 30 + CX, G, fz), Vector3.new(fx - 40, 2.2, fz))
	for i, o in ipairs({ { 0, 0 }, { 26, 18 }, { -6, 34 }, { 30, -22 }, { -26, -20 }, { 52, 4 } }) do
		prop("fishingHole", m, CFrame.new(fx + o[1], 2.2, fz + o[2]) * CFrame.Angles(0, i * 1.1, 0))
	end
	if prop("dockLantern", m, CFrame.new(fx - 44, 2.2, fz - 5), true) then
		lights += 1
	end
	prop("dockLantern", m, CFrame.new(fx - 44, 2.2, fz + 5), false)
	prop("supplyCrate", m, CFrame.new(fx - 36, 2.2, fz + 8) * CFrame.Angles(0, 0.3, 0), 0.9)
	prop("sled", m, CFrame.new(fx + 14, 2.2, fz - 40) * CFrame.Angles(0, 1.2, 0))
	for i = 1, 10 do
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(8, 46)
		bird(fx + math.cos(a) * d, fz + math.sin(a) * d, rng:NextNumber(0, 6.28),
			{ class = (i % 4 == 0) and "chick" or "adult", accessory = (i == 3) and "scarf" or nil, seed = 900 + i, roam = 7 })
	end

	-- A few round the landing and the village, so the first thing off the
	-- sleigh is a bird, and the last thing before the trees is a bird.
	for i, o in ipairs({ { -60, CD - 258 }, { -54, CD - 250 }, { 46, CD - 380 }, { -100, CD - 296 }, { 40, CD - 210 }, { -44, CD - 396 } }) do
		local x, z = CX + o[1], o[2]
		if openGround(x, z, 2) then
			bird(x, z, rng:NextNumber(0, 6.28), { class = (i % 3 == 0) and "chick" or "adult",
				accessory = (i == 1) and "santaHat" or ((i == 4) and "scarf" or nil), seed = 700 + i, roam = 4 })
		end
	end
	for i = 1, 6 do
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(30, VILLAGE_R * 0.7)
		local x, z = VILLAGE.X + math.cos(a) * d, VILLAGE.Z + math.sin(a) * d
		if openGround(x, z, 3) and spaced(x, z, 3) then
			bird(x, z, rng:NextNumber(0, 6.28), { class = "adult", accessory = (i == 2) and "beanie" or nil, colour = PALETTE.gold, seed = 800 + i, roam = 5 })
			claim(x, z, 3)
		end
	end

	return m, birds, lights
end

----------------------------------------------------------------
-- THE ICE  --  floes on the open water past the sheet, sculptures and
-- icicled bergs near the shore, and the shore's own dressing
----------------------------------------------------------------
local function buildIce(parent, rng: Random): (Model, number)
	local m = Instance.new("Model")
	m.Name = "Ice"
	m.Parent = parent
	local floes = 0
	for _ = 1, 400 do
		if floes >= 42 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(ICE_R + 12, SEA_R - 90)
		local x, z = CX + math.cos(a) * d, ICZ + math.sin(a) * d
		-- not down the channel to the beach
		if not (math.abs(x - CX) < CHANNEL_HALF + 20 and z > CHANNEL_Z0 - 40) then
			local r = rng:NextNumber(6, 16)
			if prop("iceFloe", m, CFrame.new(x, 0.0, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), r, floes) then
				floes += 1
			end
		end
	end
	-- and a handful on the leads and near the shore where a player can reach
	for i = 1, 8 do
		local a = i * 0.78
		local d = WET_R + 40 + (i % 3) * 90
		local x, z = CX + math.cos(a) * d, ICZ + math.sin(a) * d
		if not (x > WRECK_X0 - 40 and x < WRECK_X1 + 40 and z > WRECK_Z0) and not (math.abs(x - CX) < 80 and z < CAMP_Z0) then
			prop("iceSculpture", m, CFrame.new(x, groundY(x, z, 2), z) * CFrame.Angles(0, a, 0), 500 + i)
		end
	end
	return m, floes
end

----------------------------------------------------------------
-- ADOPT OR BUILD
----------------------------------------------------------------
local HAND_BUILT = "HandBuilt"

local function finalSweeps(root: Instance): (number, number, number, number, number)
	local unanchored = 0
	for _, p in ipairs(root:GetDescendants()) do
		if p:IsA("BasePart") and not p.Anchored then
			p.Anchored = true
			unanchored += 1
		end
	end

	local shadowsOff = 0
	for _, p in ipairs(root:GetDescendants()) do
		if p:IsA("BasePart") and p.CastShadow then
			local s = p.Size
			if math.min(s.X, s.Y, s.Z) < 1.0
				or p.Material == Enum.Material.Neon
				or p.Transparency > 0.5 then
				p.CastShadow = false
				shadowsOff += 1
			end
		end
	end

	local intruders = assertClearOfField(root)

	local partCount, lightCount = 0, 0
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			partCount += 1
		elseif d:IsA("Light") then
			lightCount += 1
		end
	end

	return unanchored, shadowsOff, intruders, partCount, lightCount
end

----------------------------------------------------------------
-- build
----------------------------------------------------------------
function Island5.build()
	local existing = workspace:FindFirstChild("Island5")
	if existing and existing:GetAttribute(HAND_BUILT) == true then
		local landing = existing:FindFirstChild("Landing")
		local pad = landing and landing:FindFirstChild("SellPad")
		if pad then
			Island5.sellPad = pad
			Island5.built = true
			local unanchored, shadowsOff, intruders, partCount, lightCount = finalSweeps(existing)
			if unanchored > 0 then
				warn(string.format("[Penguin] anchored %d hand-placed part(s) that were left loose.", unanchored))
			end
			print(string.format(
				"[Penguin] adopted the hand-built island saved in the place file: %d parts, "
				.. "%d lights, %d shadow casters trimmed, %d field intruders",
				partCount, lightCount, shadowsOff, intruders))
			return pad
		end
		warn(string.format("[Penguin] Workspace.Island5 is marked %s but has no Landing.SellPad -- "
			.. "rebuilding it from code, which loses any hand edits AND wipes raked progress.", HAND_BUILT))
	end

	-- ONCE, EVER, AND BEFORE baselineField(): the terrain wipe covers the whole
	-- rakeable square, so a second call erases every player's raked progress.
	if Island5.built then
		warn("[Penguin] build() called again. The terrain wipe covers the rakeable square, so every "
			.. "player's raked progress on Penguin Island has just been erased.")
	end
	Island5.built = true

	local old = workspace:FindFirstChild("Island5")
	if old then
		old:Destroy()
	end

	local root = Instance.new("Folder")
	root.Name = "Island5"
	root.Parent = workspace

	-- The litter set first: CTB_Client waits thirty seconds for it.
	local litterCount = 0
	do
		-- NOT `Props and Props.buildLitterSet(CTB)`: `and` truncates the kit's
		-- two returns to one and the count reads as zero in the boot line.
		local ok, folder, n = pcall(function()
			if not Props then
				return nil
			end
			return Props.buildLitterSet(CTB)
		end)
		if ok and folder then
			litterCount = n or 0
		else
			warn("[Penguin] the Arctic litter set could not be built: " .. tostring(folder))
		end
	end

	local mounds, bergs, cliffCourses = buildTerrain()
	waitForGround()

	local props = Instance.new("Folder")
	props.Name = "Props"
	props.Parent = root

	-- The landing, and the pad that must come out of it, PUBLISHED THE MOMENT
	-- IT EXISTS so CTB_Server's recovery path finds it if anything below throws.
	local _, sellPad, campLights = buildLanding(root)
	Island5.sellPad = sellPad

	local _, auroraParts = buildAurora(root)

	-- One spacing list shared by every scatter, so a tree and a bird cannot
	-- be stood inside each other.
	local placed = {}
	local function spaced(x: number, z: number, r: number): boolean
		for _, q in ipairs(placed) do
			local dx, dz = x - q[1], z - q[2]
			local reach = r + q[3]
			if dx * dx + dz * dz < reach * reach then
				return false
			end
		end
		return true
	end
	local function claim(x: number, z: number, r: number)
		table.insert(placed, { x, z, r })
	end

	local rng = Random.new(Config.SEED + 12030)
	local _, villageLights = buildVillage(root, rng)
	local _, trees = buildForest(root, rng, spaced, claim)
	local _, birds, colonyLights = buildColony(root, rng, spaced, claim)
	local _, floes = buildIce(root, rng)

	-- Scatter on the open snow: drifts, cairns, the odd sculpture and sled,
	-- everywhere the districts are not.
	local scatter = 0
	for _ = 1, 1600 do
		if scatter >= 118 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(FIELD_HALF + 40, PLATEAU_R - 24)
		local x, z = CX + math.cos(a) * d, ICZ + math.sin(a) * d
		if onLand(x, z) and openGround(x, z, 8) and spaced(x, z, 7) then
			local y = groundY(x, z, GROUND)
			if math.abs(y - GROUND) < 6 then
				local roll = rng:NextNumber()
				local cf = CFrame.new(x, y, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0)
				local made
				if roll < 0.42 then
					made = prop("snowDrift", props, cf, rng:NextNumber(0.9, 1.8))
				elseif roll < 0.6 then
					made = prop("cairn", props, cf, rng:NextNumber(4, 8))
				elseif roll < 0.86 then
					made = prop("snowPine", props, cf, rng:NextNumber(12, 22), scatter)
				elseif roll < 0.94 then
					made = prop("supplyCrate", props, cf, rng:NextNumber(0.8, 1.1))
				else
					made = prop("iceSculpture", props, cf, scatter)
				end
				if made then
					scatter += 1
					claim(x, z, 7)
				end
			end
		end
	end

	local unanchored, shadowsOff, intruders, partCount, lightCount = finalSweeps(root)
	if unanchored > 0 then
		warn(string.format("[Penguin] anchored %d part(s) that arrived loose from the kit", unanchored))
	end

	print(string.format(
		"[Penguin] island built: %d mounds, %d bergs, %d cliff courses, %d trees, %d birds, %d floes, "
		.. "%d scattered props, %d aurora ribbons; %d lamps lit; %d litter pieces; %d prop failures, %d field intruders",
		mounds, bergs, cliffCourses, trees, birds, floes, scatter, auroraParts,
		campLights + villageLights + colonyLights, litterCount, propFails, intruders))
	print(string.format("[Penguin] cost: %d parts, %d lights, %d shadow casters trimmed; plateau r=%d, ice r=%d, sea r=%d",
		partCount, lightCount, shadowsOff, PLATEAU_R, ICE_R, SEA_R))

	return sellPad
end

-- Published for FrozenWreckBuilder, which stands its liner on this shore and
-- needs the same numbers this file laid the shore out with.
Island5.ICZ = ICZ
Island5.PLATEAU_R = PLATEAU_R
Island5.WET_R = WET_R
Island5.ICE_R = ICE_R
Island5.WRECK_BOX = { WRECK_X0, WRECK_X1, WRECK_Z0, WRECK_Z1 }

return Island5
