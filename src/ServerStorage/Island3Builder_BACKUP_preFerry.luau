--[[
	Island3Builder  --  ServerScriptService.Island3Builder  (ModuleScript)

	SAKURA COVE. The game's third rakeable destination, 1500 studs NORTH of the
	beach: a crescent bay of pink sand opening south toward home, a great torii
	standing out in the shallows, a lantern boardwalk up to a plaza, and the same
	buried-junk loop in between.

	WHAT LIVES WHERE, because this area is split across three scripts and the
	split is a hard rule, not a preference:

	  here                terrain, and every piece of SHARED, CIVIC geometry --
	                      the sea and the plateau, the great torii, the boardwalk,
	                      the plaza and its market, the sell pad, the shop counter
	                      and its ShopPrompt, both travel gates and the server
	                      handlers behind them, and the SCATTER PLACEMENT of the
	                      dressed props. All server-built, so everyone sees the
	                      same cove.
	  Island3Props        the props themselves, as pure builders. It makes the
	                      kakigori stand, the vending machines, the lanterns, the
	                      trees, the beach furniture, the floaties and the rock
	                      formations; it decides nothing about WHERE they go.
	  CTB_Server          the rakeable field itself and who has raked what. To
	                      that script the cove is just Config.ISLANDS[4].
	  Island3_Client      everything that MOVES or is PRIVATE: drifting petals,
	                      sand sparkle, the shore glow, the pastel water, the
	                      golden-hour grade, the ambience, and the per-player
	                      gate lock.

	ORDER. build() must run BEFORE CTB_Server's baselineField(). The plateau is
	filled solid and the rakeable columns are then carved into the top of it; the
	other way round the plateau simply buries them. CTB_Server calls this at the
	bottom of itself, in that order, and nothing else should call it.

	It returns the cove's SellPad so CTB_Server can add it to the list of pads
	that pay out. That is not decoration: without a pad out here a full bag sets
	RollerBlocked and the sifter stops dead, and the only way out of it is a
	1500-stud walk home. A cove with no pad is a cove that bricks itself after
	one bagful.

	It also publishes  root:SetAttribute("UnlockLevel", 5)  for Island3_Client,
	which paints the lock. The lock itself is enforced here, on the server, in
	the beach gate's Triggered handler -- the attribute is presentation only.

	WHAT THIS SCRIPT MAY NOT DO, each learned the hard way somewhere in this
	place:

	  * Nothing may stand inside the rakeable square, x [-96, 96] z [1404, 1596].
	    The player would be raking sand out from under it. openGround() gates
	    every scattered placement and assertClearOfField() re-checks the whole
	    finished island geometrically at the end, because a prop builder written
	    by another script can always hand back a model bigger than advertised.
	  * No part may use Enum.Material.Ground or Enum.Material.Asphalt. Those two
	    are the cove's TERRAIN pair and they are tinted globally by
	    CTB_Server.applyLook; they are spoken for place-wide and nothing else,
	    terrain or prop, may touch them. This is also why the headlands are made
	    of the same Ground sand as everything else and are dressed with PART rock
	    formations instead of a rock TERRAIN material -- every other terrain
	    material in the game already belongs to the beach, the dunes or the vault.
	  * Neon stays at Transparency 0. Above zero it renders near-black under
	    Future lighting, which is the opposite of a glow. Anything that has to be
	    seen through is SmoothPlastic with a little Reflectance, never Glass --
	    Glass culls transparent objects behind it and this island is full of them.
]]

local Island3 = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CTB = ReplicatedStorage:WaitForChild("CTB")
local Config = require(CTB:WaitForChild("Config"))
-- The cove's signs go through the same kit as the beachfront's and the dunes'.
-- This module REBUILDS its island on every boot and SignDresser's world pass
-- runs on ServerMain's schedule, so a sign left for SignDresser would be dressed
-- and then thrown away. These have to be right when they are made.
local SignKit = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("SignKit"))

local Terrain = workspace.Terrain

----------------------------------------------------------------
-- The props module, held at arm's length
----------------------------------------------------------------
--[[
	Island3Props is written by a different script and every one of its builders
	is a place where the cove can fail. CTB_Server already wraps this whole
	module in a pcall so a broken island costs the area rather than the boot --
	that protection is worth nothing if one bad prop takes the terrain, the sell
	pad and both travel gates down with it.

	So: the require is guarded, every call goes through prop() below, and a
	missing or throwing builder costs exactly one prop and a counted warning.
	The island still has its land, its shop, its pad and its way home.
]]
local Props = nil
do
	local ok, mod = pcall(function()
		return require(script.Parent:WaitForChild("Island3Props", 5))
	end)
	if ok and type(mod) == "table" then
		Props = mod
	else
		warn("[Cove] Island3Props did not load -- the cove will be built bare. " .. tostring(mod))
	end
end

local propFails = 0

-- One call into Island3Props. Returns the Model, or nil, and never throws.
local function prop(fnName: string, ...): Model?
	if not Props then
		propFails += 1
		return nil
	end
	local builder = Props[fnName]
	if type(builder) ~= "function" then
		propFails += 1
		if propFails <= 4 then
			warn(string.format("[Cove] Island3Props.%s is missing", fnName))
		end
		return nil
	end
	local ok, m = pcall(builder, ...)
	if not ok then
		propFails += 1
		if propFails <= 4 then
			warn(string.format("[Cove] Island3Props.%s threw: %s", fnName, tostring(m)))
		end
		return nil
	end
	if typeof(m) ~= "Instance" then
		-- A builder that forgets to return is a silent hole in the island: the
		-- model is parented and looks fine, and the caller can no longer place,
		-- scale or count it. Treated as a failure so it shows up in the summary.
		propFails += 1
		return nil
	end
	return m
end

----------------------------------------------------------------
-- Where everything is
----------------------------------------------------------------
local ISL = Config.island(4)
local CX, CZ = ISL.cx, ISL.cz          -- 0, 1500
local GROUND = ISL.cleanY              -- 3.0, the same voxel band as every field
local FIELD_HALF = ISL.half            -- 96: the rakeable square is CX/CZ +- this

--[[
	THE SEA, AND WHY THE RADII ARE WHAT THEY ARE.

	SEA_R is used for the airspace wipe, the seabed AND the water, and those
	three MUST stay equal, so that a rebuild on a running server never clears a
	wider circle than it refills.

	The seabed is laid at -24..-12 and the sea at -12..SEA_TOP, which reproduces
	the beach's own offshore column: measured, the beach at (0, 700) is solid to
	-10 with water over it. (The dunes lay theirs at -20..-8 and do get a
	four-stud shelf out in the haze; it is invisible at that depth and was never
	worth going back for, but there is no reason to inherit it here.)

	The wipe starts at -24 rather than deeper for the same reason: everything
	below -24 is the beach's untouched seabed, and refilling from -24 exactly
	means there is never an air gap sealed under the water.

	THE CLAIM THAT USED TO BE HERE -- "the beach's ocean already covers
	everything from here south to z = 880" -- WAS FALSE, AND IT COST A LIFE.
	Measured with a raycast grid over x [-1050, 1050] z [700, 1250]:

	  z <= 802     beach ocean, full width, surface -0.50
	  z 803..879   NOTHING. No water, no seabed, no part, between y +400 and
	               -500, across the whole middle of the map (|x| up to ~650).
	  z >= 880     the cove's own sea begins.

	A player swimming north out of the beach -- which the UNLOCK_LEVEL note below
	uses as its whole justification for the gate being lockable at all -- leaves
	swim state at z = 803 and free-falls to FallenPartsDestroyHeight (-500). From
	water level a 77-stud gap between two identical seas is invisible until you
	are in it.

	The hole PRE-DATES this file (its outer boundary is a straight line, which no
	cylinder produces -- most likely an earlier revision here wiped wider than it
	refilled). But this island is the one that relies on a continuous ocean, and
	at SEA_R = 620 no future boot could ever heal it. bridgeToBeach() below does.
]]
local SEA_R = 620
local SEA_FLOOR = -12                  -- top of the seabed, matching the beach's

--[[
	THE WATER SURFACE, AND A Fill* TRAP WORTH THE PARAGRAPH.

	SEA_TOP asks for -0.5 and DOES NOT GET IT. Measured, in this place:

	  Terrain:FillBlock    water top -0.5 -> surface -0.500   (exact)
	  Terrain:FillCylinder water top -0.5 -> surface  0.000
	  Terrain:FillCylinder water top -2.0 -> surface  0.000

	FillCylinder rounds a water top UP to the voxel boundary; FillBlock honours
	the fraction. So the cove's sea -- poured with FillCylinder -- actually sits
	at 0.00, half a stud above the beach's -0.50, and so does the dunes' for the
	same reason. SEA_SURFACE is the number that is TRUE, and everything that has
	to meet the water (the floaties, the client's shore glow) uses that one.

	The corridor in bridgeToBeach() is FillBlock, so it CAN hit a fraction, and
	it ramps from the beach's -0.50 up to the cove's 0.00 in five 0.125-stud
	steps rather than meeting either one on a lip.
]]
local SEA_TOP = -0.5                   -- what the fill is ASKED for
local SEA_SURFACE = 0.0                -- what FillCylinder actually renders

--[[
	THE ISLAND, AS FOUR DISCS. The heights here are NOT the heights you get:
	Fill* rounds to whole voxels and smooth terrain renders its surface at the
	CENTRE of the first non-full voxel, so a disc filled to y = 0 comes out
	rendering at y = 2. The rakeable field renders at exactly 3.0, so filling the
	plateau "to 3" would leave the field sitting in a three-stud pit with a wall
	round it. The plateau is filled to 0 and lifted to 3.0 by an explicit 0..4
	voxel layer further down.

	  520  outer slope        renders at -6
	  460  the shallow shelf  renders at -2, so 1.5 studs of water over it
	  344  wet sand           renders at  2, a stud under the dry sand
	  296  the island proper  lifted to  3.0, flush with the field
]]
local SLOPE_R = 520
local SHORE_R = 460                    -- the wide shallow shelf the brief asks for
local WET_R = 344
local PLATEAU_R = 296

--[[
	THE BAY. A circle bitten out of the south side, so the shoreline bulges
	NORTH in the middle and the land reaches south either side of it -- which is
	what makes a crescent rather than a plateau with a puddle.

	  centre (CX, 1104), radius 148  ->  the waterline on the cove's axis is
	  z = 1252, and at x = +-100 it is z = 1213.

	1252 is not a free number. The arrival gate stands at z = 1264 and the
	boardwalk runs from 1274, so twelve studs of dry sand sit between the gate
	pad and the water: enough that the gate reads as standing ON the shore, and
	not so much that the walk out of it is a hike.
]]
local BAY_CZ = 1104
local BAY_R = 148

--[[
	THE ARMS. The plateau's own southern lobes are only about thirteen studs
	further south than the middle of the bay, which is not a crescent, it is a
	dent. So each arm gets a headland disc of its own, plus a smaller bridging
	disc inboard of it.

	The bridge is not decoration. Without it there is a 25-stud channel of open
	water at about z = 1200 between the bay's edge and the headland, and the
	headland reads as a separate island floating off the shore. The bridge
	overlaps the bay circle deliberately -- the bay carve runs afterwards and
	eats its seaward half, which is what puts a shoreline on it.
]]
local ARM_X, ARM_Z = 190, 1268
local ARM_R, ARM_SKIRT = 86, 104
local BRIDGE_X, BRIDGE_Z = 132, 1226
local BRIDGE_R, BRIDGE_SKIRT = 52, 70

--[[
	The great torii, out in the water. Its Y is NOT set here; build() raycasts
	the bay floor for it, because the floor is the product of four fills and a
	carve and guessing at it is how you get a landmark floating two studs over
	its own reflection.

	OFF THE AXIS, AND THAT IS THE FIX FOR THE WHOLE COMPOSITION.

	This stood at x = 0 to line up with the arrival gate and the market gate, so
	that from the plaza you looked down the boardwalk through both of them and
	the great torii stood beyond. It does not work, because all three are the
	same SHAPE: from the field the market gate subtends 13.4 degrees of half-
	width and the great torii 11.2, so the landmark sits ENTIRELY inside the near
	gate's silhouette and reads as a third, smaller copy of it. Measured from the
	play camera it was not visible from anywhere on the island -- only from out
	in the bay, where the player never goes.

	A 48-stud hero landmark has to be framed BESIDE the gate line, not through
	it. WHAT DECIDES HOW FAR OFF IS THE ECLIPSE LINE -- the line through the
	market gate and the torii, extended north across the field. Anyone standing
	on it sees one shape behind the other, and the further off-axis the torii
	goes, the sooner that line leaves the rakeable square. At x = -70 it still
	ran up the middle of the field (measured from the play camera: the great
	torii's kasagi came out directly above the market gate's). At (-104, 1112)
	the line crosses the field's south-west corner and exits by z = 1539, so
	most of the field sees the two apart, and from the boardwalk the torii sits
	just outside the arrival gate's silhouette rather than inside it.

	BOTH FOOTINGS MUST STAY IN THE BAY, AND THAT IS THE HARD LIMIT ON TORII_X.
	The bay is a circle of radius 148 about (CX, 1104) and the footings sit at
	TORII_X +- 28.7 on the TORII_Z line, so the centre can never be further out
	than about 119 even on the bay's own centre line. At (-104, 1112) the outer
	footing is 133 studs from the bay centre -- 15 clear of the waterline. Move
	this and re-check that number, or the torii wades ashore.
]]
local TORII_X, TORII_Z = -104, 1112

-- The plaza, and the boardwalk that leads to it. Everything here is south of
-- z = 1404 by at least ten studs -- see the note on assertClearOfField.
local PLAZA_Z0, PLAZA_Z1 = 1330, 1394
-- 74, down from 104. At 104 the plaza was 208 x 64 = 13,312 square studs holding
-- one stall, one pad and three vending machines, and its whole western half was
-- bare paving -- from the field it read as a car park with a shop on it. The
-- content actually spans x -63.7 (the pad's frame) to +61.6 (the stall's plinth
-- trim), so 74 leaves about ten studs of margin either side and nothing had to
-- move except the vending machines, which were outside the new kerb.
local PLAZA_HALF = 74
local WALK_HALF = 12                   -- the boardwalk deck's half-width
local WALK_Z0, WALK_Z1 = 1274, 1330    -- meets the plaza edge-to-edge, no overlap
local WALK_GAP = 20                    -- the break in the plaza's south kerb

-- Travel. Two gates, and the cove one is the arrival point.
local GATE_COVE = CFrame.new(CX, GROUND, 1264)
-- The beach end is a STARTING POINT, not an address: see siteBeachGate(). The
-- dunes already own (62, ground, -170) at the east end of the beachfront, so the
-- cove takes the same z line at the west end and the two gates bookend it.
local GATE_BEACH_NOMINAL = Vector3.new(-62, 3.2, -170)

--[[
	What it takes to unlock the way north. The dunes ask 3; this is the later
	area and asks 5. Note the ocean is continuous -- the cove's shelf reaches to
	z = 1148 and the beach's ocean covers everything up to about z = 1350, so
	the two are one body of water and a determined player can always just swim.
	The gate is a convenience, not a wall, which is the only reason it is
	allowed to be locked at all.
]]
local UNLOCK_LEVEL = 5

----------------------------------------------------------------
-- Palette
----------------------------------------------------------------
--[[
	PUBLISHED, NOT PUSHED. Island3Props exports Props.PALETTE so the two scripts
	agree on one set of pastels, and neither of them should have to load first to
	be correct -- so this file states a complete palette of its own and then lets
	the props module overwrite any key it defines. If Island3Props is missing
	entirely the cove still comes out the right colour.

	These run hotter and more saturated than "pastel" suggests, for the same
	reason the dunes' palette does: parts are lit by the sky as well as the sun,
	this place sets EnvironmentDiffuseScale 0.7 under a bright skybox, and the
	terrain does NOT pick that up because it is tinted directly by
	SetMaterialColor. A believable blush like (250, 226, 232) comes out reading
	as cold white paint standing on sand tinted (206, 104, 124).

	VERMILION IS THE ONE COLOUR HERE THAT IS NOT PASTEL, AND THAT IS THE POINT.
	The torii is the landmark of the area and it is standing in front of pink
	sand, pink water and a pink sky; a pink torii is a torii you cannot see. The
	traditional warm coral-red is the only thing in the palette with enough
	distance from the ground to read as a silhouette from the plaza.
]]
local PALETTE = {
	sand = Color3.fromRGB(247, 205, 214),
	sandDeep = Color3.fromRGB(214, 148, 166),
	blossom = Color3.fromRGB(255, 209, 220),
	blossomDeep = Color3.fromRGB(236, 152, 180),
	cream = Color3.fromRGB(255, 246, 238),
	vermilion = Color3.fromRGB(228, 78, 58),
	vermilionDeep = Color3.fromRGB(186, 52, 40),
	plum = Color3.fromRGB(66, 42, 62),
	mint = Color3.fromRGB(168, 232, 218),
	turquoise = Color3.fromRGB(104, 206, 208),
	lantern = Color3.fromRGB(255, 196, 148),
	glowWarm = Color3.fromRGB(255, 214, 168),
	timber = Color3.fromRGB(240, 208, 206),
	timberDeep = Color3.fromRGB(196, 152, 158),
	stone = Color3.fromRGB(226, 208, 214),
	stoneDeep = Color3.fromRGB(172, 152, 164),
}
--[[
	AND THE TWO SCRIPTS DID NOT PICK THE SAME KEY NAMES, which is what an alias
	table is doing in the middle of a palette.

	Measured against the shipped Island3Props: it exports sakura / rose / blush /
	coral / charcoal / amber / lilac alongside cream, mint, turquoise, stone and
	timber. Only those last five collide with the names here, so a plain
	name-for-name adoption would have agreed on five colours out of twelve and
	quietly built the cove out of two palettes -- the plaza one grey, the vending
	machines standing on it another. The tones themselves are within a few points
	of each other; it was only ever the labels that differed, so the labels are
	what gets translated.

	THE PROPS SIDE WINS every key it names, deliberately. Most of what a player
	looks at in the cove is a prop, so the props module is the better authority
	on the cove's pastels, and anything it does not name falls back to the values
	above.

	ONE EXCEPTION, AND IT IS THE LANDMARK. Island3Props' `coral` is (255,142,124),
	a salmon pink -- correct for an awning or a floatie, and wrong for the torii,
	which is standing in front of pink sand under a pink sky and has to be the
	one thing in frame that is NOT pastel or it stops being a silhouette. There
	is no key on that side that means "the loud red", so vermilion is not aliased
	to anything and stays local. If a future palette grows a proper vermilion,
	add the alias here rather than re-tinting the torii at its call site.
]]
local PALETTE_ALIAS = {
	sakura = "blossom",
	rose = "blossomDeep",
	blush = "sand",
	charcoal = "plum",
	amber = "lantern",
}
if Props and type(Props.PALETTE) == "table" then
	for k, v in pairs(Props.PALETTE) do
		local target = PALETTE_ALIAS[k] or k
		if typeof(v) == "Color3" and PALETTE[target] ~= nil then
			PALETTE[target] = v
		end
	end
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
	p.Color = colour or PALETTE.stone
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

-- Axis-aligned box from world bounds. The plaza, the decking and the kerbs are
-- all laid out against each other's faces, and bounds are far easier to keep
-- flush than centre+size when the thing you are lining up is sixty studs away.
--
-- Returns nil on a degenerate extent, so every caller that needs the handle has
-- to check it -- SignKit.dress on a nil board is a crash at boot.
local function box(parent, name, x0, x1, y0, y1, z0, z1, colour, material, extra)
	if x1 - x0 < 0.05 or y1 - y0 < 0.05 or z1 - z0 < 0.05 then
		return nil
	end
	return P(parent, name,
		Vector3.new(x1 - x0, y1 - y0, z1 - z0),
		CFrame.new((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5),
		colour, material, extra)
end

-- Local-space part: build around a CFrame so a torii can be placed and turned
-- without every number in it being rewritten. box() only makes axis-aligned
-- bricks; anything leaning, sloping or swept has to come through here.
local function lp(parent, name, base, size, offset, colour, material, extra)
	return P(parent, name, size, base * offset, colour, material, extra)
end

-- An upright cylinder, leaning by `lean` radians (positive leans the TOP toward
-- -X in the base's local frame).
--
-- Part shape Cylinder runs along its LOCAL X, which is the single most reliable
-- way to get a pillar lying on its side in this engine. Size is (length, dia,
-- dia) and the upright rotation is a quarter turn about Z; the lean is simply
-- added to that quarter turn, which is why it reads as one number here.
local function pillar(parent, name, base, offset, height, dia, lean, colour, material, extra)
	local e = { Shape = Enum.PartType.Cylinder }
	if extra then
		for k, v in pairs(extra) do
			e[k] = v
		end
	end
	return P(parent, name, Vector3.new(height, dia, dia),
		base * offset * CFrame.Angles(0, 0, math.pi * 0.5 + lean),
		colour, material, e)
end

--[[
	A SWEPT RAIL -- the kasagi, the curved top of a torii with its upturned ends.

	Built as a run of straight segments laid along a parabola y = a * x^2, each
	one turned to the local tangent, because there is no curved primitive and a
	chain of blocks stepped up in Y without turning reads as a staircase from
	twenty studs away.

	`rise` is how far the ENDS lift above the centre. Segments overlap by 18% so
	the outside of each joint does not open up as the tilt increases -- at 5.5
	studs of rise over a 43-stud half-span the end segments sit about 15 degrees
	off horizontal, which is enough for a butt joint to show daylight.
]]
local function sweptRail(parent, name, base, length, rise, thick, depth, segs, colour, material, extra)
	local halfLen = length * 0.5
	local a = rise / (halfLen * halfLen)
	local step = length / segs
	for i = 0, segs - 1 do
		local x = -halfLen + (i + 0.5) * step
		local y = a * x * x
		local ang = math.atan(2 * a * x)
		lp(parent, name, base, Vector3.new(step * 1.18, thick, depth),
			CFrame.new(x, y, 0) * CFrame.Angles(0, 0, ang), colour, material, extra)
	end
end

----------------------------------------------------------------
-- Raycast placement
----------------------------------------------------------------
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { Terrain }
groundParams.IgnoreWater = true

-- The solid floor at (x, z), water ignored. Under the bay this is the sand
-- shelf, not the surface, which is exactly what a torii footing wants.
local function groundY(x: number, z: number, fallback: number): number
	local hit = workspace:Raycast(Vector3.new(x, 160, z), Vector3.new(0, -300, 0), groundParams)
	return hit and hit.Position.Y or fallback
end

--[[
	The same, but it WAITS for that particular column's collision to exist.

	waitForGround() below proves the terrain is raycastable somewhere, and for
	the scatter that is enough -- a tree that misses lands at GROUND, which is
	where it was going anyway. It is NOT enough for the great torii. Collision is
	rebuilt per chunk, and the torii reads the bay floor 300+ studs from the
	probe point in different chunks, so it can miss while the plaza is already
	solid.

	The symptom was in the log the whole time and looked like nothing: the very
	first build printed `torii top y=40.9` and the next six printed `48.9`. The
	miss falls back to -2, and the settled bay floor happens to BE exactly
	-2.000 -- so the fallback was right by coincidence of the constant, and the
	day somebody changes the bay's depth the landmark silently detaches from it.

	90 frames, not 240: waitForGround has already returned by the time anything
	calls this, so a single chunk is at most a frame or two behind.
]]
local function groundYWait(x: number, z: number, fallback: number): number
	for _ = 1, 90 do
		local hit = workspace:Raycast(Vector3.new(x, 160, z), Vector3.new(0, -300, 0), groundParams)
		if hit then
			return hit.Position.Y
		end
		task.wait()
	end
	warn(string.format("[Cove] no terrain under (%.0f, %.0f) after 90 frames; using the fallback %.1f", x, z, fallback))
	return fallback
end

--[[
	Terrain COLLISION is rebuilt a frame or so behind the voxel write, so a
	raycast fired in the same tick as a Fill* misses and reports nothing there.
	Everything scattered below is placed by raycast, so without this every tree,
	rock and lounger silently lands at its fallback height and floats -- which
	looks like a placement bug rather than the timing one it is, and cost the
	dunes real time to find.

	The probe points have to be somewhere the terrain actually exists AND far
	enough apart to be in different chunks: the plaza, which is solid plateau and
	is also the first thing this script builds on, and the bay floor under the
	great torii, which is 190 studs away and was the one that used to be late.
]]
local function waitForGround(): boolean
	for _ = 1, 240 do
		if workspace:Raycast(Vector3.new(CX, 160, CZ - 140), Vector3.new(0, -300, 0), groundParams)
			and workspace:Raycast(Vector3.new(CX + TORII_X, 160, TORII_Z), Vector3.new(0, -300, 0), groundParams) then
			return true
		end
		task.wait()
	end
	warn("[Cove] terrain never became raycastable; scattered props will sit at ground level")
	return false
end

----------------------------------------------------------------
-- Clearance
----------------------------------------------------------------
-- Would a circle of this radius reach into the rakeable square? Terrain written
-- outside the field's y band survives the field write, so a mound placed over
-- the square would leave sand hanging above the very columns the player is
-- trying to rake.
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

--[[
	Everything the scattered decor has to stay out of. Written CX/CZ-relative on
	purpose: the dunes' equivalent table is absolute world numbers that happen to
	be CX-relative, and the first person to move that island would have found out
	the hard way. { x0, x1, z0, z1 }.
]]
local KEEP_OUT = {
	{ CX - PLAZA_HALF - 8, CX + PLAZA_HALF + 8, PLAZA_Z0 - 8, PLAZA_Z1 + 8 },   -- plaza and market
	{ CX - WALK_HALF - 12, CX + WALK_HALF + 12, WALK_Z0 - 10, WALK_Z1 },        -- boardwalk and its rails
	{ CX - 30, CX + 30, GATE_COVE.Z - 22, GATE_COVE.Z + 16 },                   -- the arrival gate and its step
	-- The torii, and the water round it. CENTRED ON TORII_X, not on CX: it used
	-- to be written as CX +- 46 back when the torii stood on the axis, which was
	-- a latent bug the moment anything moved it -- the keep-out box would have
	-- stayed behind and the scatter would have dropped floaties through it.
	{ CX + TORII_X - 50, CX + TORII_X + 50, TORII_Z - 30, TORII_Z + 34 },
}

local function clearOfBuildings(x, z, r)
	for _, b in ipairs(KEEP_OUT) do
		if not clearOfBox(x, z, r, b[1], b[2], b[3], b[4]) then
			return false
		end
	end
	return true
end

local function openGround(x, z, r)
	return clearOfField(x, z, r) and clearOfBuildings(x, z, r)
end

-- Inside the bay circle, i.e. water rather than sand. Trees and loungers test
-- this before they commit; floaties test the opposite.
local function inBay(x, z, margin)
	local dx, dz = x - CX, z - BAY_CZ
	local r = BAY_R + (margin or 0)
	return dx * dx + dz * dz <= r * r
end

--[[
	THE LAST WORD ON THE RAKEABLE SQUARE, and it is deliberately not the same
	test as openGround().

	openGround() gates a placement by its intended radius; this measures what
	actually got built. A prop builder in another script can hand back a model
	four times the size it advertises, a scale can be fat-fingered, and a
	hand-built box can be typed with the wrong sign -- none of which openGround()
	can see. So every BasePart under the finished island is checked against the
	square by its real world-axis-aligned extent, including rotation.

	It reports rather than deletes. Something standing in the field is a bug to
	go and fix in the code that put it there; quietly destroying it at boot would
	hide the bug and leave a hole in the island instead.
]]
local function assertClearOfField(root: Instance): number
	local bad, first = 0, nil
	for _, p in ipairs(root:GetDescendants()) do
		if p:IsA("BasePart") then
			local cf, s = p.CFrame, p.Size
			local rx, ux, lx = cf.RightVector, cf.UpVector, cf.LookVector
			local ex = math.abs(rx.X) * s.X * 0.5 + math.abs(ux.X) * s.Y * 0.5 + math.abs(lx.X) * s.Z * 0.5
			local ez = math.abs(rx.Z) * s.X * 0.5 + math.abs(ux.Z) * s.Y * 0.5 + math.abs(lx.Z) * s.Z * 0.5
			if math.abs(cf.X - CX) - ex < FIELD_HALF and math.abs(cf.Z - CZ) - ez < FIELD_HALF then
				bad += 1
				first = first or p:GetFullName()
			end
		end
	end
	if bad > 0 then
		warn(string.format("[Cove] %d part(s) stand INSIDE the rakeable square -- first: %s", bad, first))
	end
	return bad
end

----------------------------------------------------------------
-- The corridor home
----------------------------------------------------------------
--[[
	THE FIX FOR THE HOLE IN THE OCEAN (see the SEA_R note above for the survey).

	A 1000-stud-wide channel of water and seabed laid down the cove's axis, from
	well inside the beach's own ocean at z = 780 up to z = 1140, where it is
	comfortably inside the cove's sea disc (which reaches |x| = 505 by z = 1140).
	It joins the two bodies of water into one thing you can swim across.

	PURELY ADDITIVE, and that is the whole reason it is a separate pass rather
	than a bigger SEA_R. Every voxel it writes is either VOID (measured) or
	already exactly what it writes:

	  * the seabed course is -24..-12, and the beach's offshore column is solid
	    to a rendered -10, which is the same fill;
	  * the water course meets the beach at its own -0.50 surface.

	Growing SEA_R instead would have had to WIPE before it refilled, and the wipe
	is what did the original damage. Nothing here removes anything.

	THE RAMP IS WHY THE WATER GOES DOWN IN BANDS. The beach's sea surface is
	-0.50 and the cove's is 0.00 (see SEA_SURFACE -- FillCylinder rounds a water
	top up and FillBlock does not), so a single flat channel would meet one ocean
	or the other on a half-stud lip. Instead it climbs in five 0.1-stud steps
	across 170 studs of open water and is flat at 0.00 from z = 950 north, which
	is south of everything the cove pours afterwards -- so no later fill can land
	a step on it either.

	AND IT IS LAID COLUMN BY COLUMN, WHICH IS THE WHOLE REASON IT IS A LOOP.
	A rectangle would end on a straight north-facing edge, and past the middle of
	it that edge has VOID on the far side -- so closing the hole down the axis
	would have opened a new one 500 studs out, which is the same bug with better
	manners. Each 40-stud column instead stops where the cove's own sea disc
	takes over at that x, so the channel's far boundary IS the disc and no part
	of it ends in nothing.

	WHAT IS STILL HOLED, honestly: the pre-existing void survives at roughly
	|x| 620..700 (between this channel's edge, which cannot exceed SEA_R, and an
	old north-south ribbon of water at |x| 700..800) and everywhere beyond about
	|x| 850. Neither is on any path out of the beach -- the beach island is 256
	studs across, so a swimmer leaving it is inside |x| = 400 and lands in the
	channel. Fixing the rest means repairing the beach's ocean, which is a
	different island's job.
]]
--[[
	EVERY z BOUNDARY BELOW IS A MULTIPLE OF FOUR, AND THAT IS NOT COSMETIC.

	Terrain voxels are 4 studs and aligned to multiples of 4 in world space. A
	fill whose edge lands mid-voxel writes that voxel at PARTIAL occupancy, and
	a partially-filled water voxel renders as a dip. Measured with the first cut
	of this channel, whose bands broke at 814 / 882 / 950: the surface fell to
	-1.215 at z = 814 and -1.141 at z = 880, so the 0.1-stud ramp the bands were
	designed to make had a ONE-STUD trench across it at every band edge -- worse
	than the half-stud lip the ramp exists to avoid.

	The same rule is why zEnd is rounded UP to a multiple of 4 below. Its raw
	value comes off a square root, and left fractional it re-cut the cove's own
	full-occupancy water down to a partial voxel along the whole join.

	The Y values stay fractional on purpose -- that is the ramp, and FillBlock
	honours a fractional water top exactly (FillCylinder does not; see SEA_TOP).
]]
local CHANNEL_HALF = 620          -- == SEA_R; the disc is what the far edge lands on
local CHANNEL_STEP = 40
local CHANNEL_Z0 = 780
local CHANNEL_BANDS = {
	{ 780, 812, -0.5 }, { 812, 848, -0.4 }, { 848, 884, -0.3 },
	{ 884, 916, -0.2 }, { 916, 948, -0.1 }, { 948, CZ + 40, SEA_SURFACE },
}

local function bridgeToBeach()
	for x0 = -CHANNEL_HALF, CHANNEL_HALF - CHANNEL_STEP, CHANNEL_STEP do
		local x1 = x0 + CHANNEL_STEP
		-- the column's WIDEST |x| decides where the disc takes over, so both of
		-- its edges are covered rather than just its centre line
		local xm = math.max(math.abs(x0), math.abs(x1))
		-- Clamped at zero rather than skipped. The outermost column has xm == SEA_R
		-- exactly, so an unclamped `reach > 0` test dropped it and left a 40-stud
		-- void stripe down each side of the finished channel.
		local reach = math.max(SEA_R * SEA_R - xm * xm, 0)
		-- +8 so the join overlaps the disc rather than meeting it on a seam, then
		-- rounded up to the voxel grid so the join is not a partial-occupancy dip
		local zEnd = math.ceil((CZ - math.sqrt(reach) + 8) / 4) * 4
		if zEnd > CHANNEL_Z0 + 1 then
			local cx = CX + (x0 + x1) * 0.5
			Terrain:FillBlock(
				CFrame.new(cx, (-24 + SEA_FLOOR) * 0.5, (CHANNEL_Z0 + zEnd) * 0.5),
				Vector3.new(CHANNEL_STEP, SEA_FLOOR - (-24), zEnd - CHANNEL_Z0),
				ISL.matMessy)
			for _, band in ipairs(CHANNEL_BANDS) do
				local z0 = band[1]
				local z1 = math.min(band[2], zEnd)
				if z1 > z0 + 0.5 then
					Terrain:FillBlock(
						CFrame.new(cx, (SEA_FLOOR + band[3]) * 0.5, (z0 + z1) * 0.5),
						Vector3.new(CHANNEL_STEP, band[3] - SEA_FLOOR, z1 - z0),
						Enum.Material.Water)
				end
			end
		end
	end
end

----------------------------------------------------------------
-- Terrain
----------------------------------------------------------------
local function buildTerrain()
	local rng = Random.new(Config.SEED + 4104)

	-- Wipe the airspace first, so a rebuild on a running server does not stack
	-- headlands on top of the headlands it made last time. The radius is the
	-- SAME as the sea's below and must stay that way -- this island's ocean
	-- overlaps the beach's, and clearing a wider circle than we refill would
	-- punch a hole in it. It stops at -24 rather than at the bottom of the
	-- world because -24 is where the beach's untouched seabed begins.
	Terrain:FillCylinder(CFrame.new(CX, 98, CZ), 244, SEA_R, Enum.Material.Air)

	-- Seabed, then sea, laid to reproduce the beach's own column exactly (see
	-- the note on SEA_R). The water's top is -0.5 rather than a whole voxel
	-- boundary on purpose: Fill* computes fractional occupancy from volume
	-- overlap, so asking for -0.5 actually gets -0.5, and -0.5 is where every
	-- other sea surface in this game sits.
	Terrain:FillCylinder(CFrame.new(CX, (SEA_FLOOR - 24) * 0.5, CZ), SEA_FLOOR + 24, SEA_R, ISL.matMessy)
	Terrain:FillCylinder(CFrame.new(CX, (SEA_TOP + SEA_FLOOR) * 0.5, CZ), SEA_TOP - SEA_FLOOR, SEA_R,
		Enum.Material.Water)

	-- Join it to the beach's ocean. Runs BEFORE the island discs so that if the
	-- channel ever grows far enough north to reach land, the land wins.
	bridgeToBeach()

	-- The island, as a short stack of discs. Only whole-voxel tops here;
	-- anything finer has to go through WriteVoxels, and the 0..4 lift below is
	-- the one place that happens.
	local BOTTOM = -24
	for _, ring in ipairs({
		{ r = SLOPE_R, top = -8 },        -- outer slope, renders at -6
		{ r = SHORE_R, top = -4 },        -- the shallow shelf, renders at -2
		{ r = WET_R, top = 0 },           -- wet sand at the waterline, renders at 2
		{ r = PLATEAU_R, top = 0 },       -- the island proper, lifted to 3.0 below
	}) do
		Terrain:FillCylinder(CFrame.new(CX, (BOTTOM + ring.top) * 0.5, CZ),
			ring.top - BOTTOM, ring.r, ISL.matMessy)
	end

	-- The two arms, each a headland disc and a bridging disc, mirrored. Every
	-- one gets a skirt filled a voxel lower so the drop to the shelf is two
	-- steps rather than one five-stud cliff -- this is a soft pastel cove, and
	-- the dunes' wall-of-sand trick would be wrong here even where it would work.
	for _, side in ipairs({ -1, 1 }) do
		Terrain:FillCylinder(CFrame.new(CX + side * ARM_X, (BOTTOM + 0) * 0.5, ARM_Z),
			0 - BOTTOM, ARM_SKIRT, ISL.matMessy)
		Terrain:FillCylinder(CFrame.new(CX + side * BRIDGE_X, (BOTTOM + 0) * 0.5, BRIDGE_Z),
			0 - BOTTOM, BRIDGE_SKIRT, ISL.matMessy)
	end

	--[[
		Lift the land to exactly the field's surface height, one voxel layer,
		at the same occupancy the field is written at. This is what makes the
		rakeable square flush with the sand around it -- and flush is not a
		nicety, it is constraint: raked progress is per player and each client
		redraws its own columns, so a messy column and a raked column must be
		the SAME height or other people's avatars float and sink.

		The shape is (plateau OR either arm OR either bridge) AND NOT the bay.
		The bay exclusion is belt and braces: the carve below removes this band
		again anyway, and either alone would do. Two independent guarantees on
		the one piece of geometry that decides whether the water has a floor.
	]]
	do
		local _, o3 = Config.occupancyFor(GROUND)
		local V = Config.VOXEL

		-- Explicit bounds rather than a square around the plateau: the arms and
		-- bridges reach 22 studs further south than the plateau does, and a
		-- region that misses them leaves them rendering a stud low with a lip
		-- along the join.
		local LX0, LX1 = CX - 304, CX + 304
		local LZ0, LZ1 = CZ - 332, CZ + 304
		local nx = math.floor((LX1 - LX0) / V)
		local nz = math.floor((LZ1 - LZ0) / V)

		local function within(wx, wz)
			if inBay(wx, wz, 0) then
				return false
			end
			local dx, dz = wx - CX, wz - CZ
			if dx * dx + dz * dz <= PLATEAU_R * PLATEAU_R then
				return true
			end
			for _, side in ipairs({ -1, 1 }) do
				local ax, az = wx - (CX + side * ARM_X), wz - ARM_Z
				if ax * ax + az * az <= ARM_R * ARM_R then
					return true
				end
				local bx, bz = wx - (CX + side * BRIDGE_X), wz - BRIDGE_Z
				if bx * bx + bz * bz <= BRIDGE_R * BRIDGE_R then
					return true
				end
			end
			return false
		end

		local region = Region3.new(
			Vector3.new(LX0, 0, LZ0),
			Vector3.new(LX1, V, LZ1)
		):ExpandToGrid(V)

		local mats, occs = table.create(nx), table.create(nx)
		for xi = 1, nx do
			local mx, ox = { table.create(nz) }, { table.create(nz) }
			mats[xi], occs[xi] = mx, ox
			local wx = LX0 + (xi - 0.5) * V
			for zi = 1, nz do
				local wz = LZ0 + (zi - 0.5) * V
				if within(wx, wz) then
					mx[1][zi], ox[1][zi] = ISL.matMessy, o3
				else
					-- Outside the land this band is already empty, so this is a
					-- no-op -- but it has to be written as AIR at zero, because
					-- WriteVoxels rejects a real material at occupancy 0.
					mx[1][zi], ox[1][zi] = Enum.Material.Air, 0
				end
			end
		end
		Terrain:WriteVoxels(region, V, mats, occs)
	end

	--[[
		THE BAY, carved and then filled back with water.

		The carve starts at -4 and not lower: -4 is the top of the shallow shelf,
		and the shelf is the whole point of the bay. Left in place it renders at
		-2 with the water surface at -0.5, so the bay is 1.5 studs deep -- ankle
		deep, sand visible through it, which is the "shallow crystal-clear" the
		area is supposed to read as.

		AND 1.5 IS THE ONLY SHALLOW DEPTH AVAILABLE, which is worth knowing
		before somebody tries to deepen it. The next whole voxel down puts the
		floor at -6 and the water at 5.5 studs, and 5.5 studs is over a
		character's head -- the bay stops being waded and starts being swum, the
		torii's footings disappear, and the floor you could see through the water
		is gone. There is no depth in between, because a voxel holds one material
		at one occupancy and half-carving the sand then pouring water into the
		same voxel simply replaces the sand. So: 1.5, deliberately.

		The water is poured only over the -4..-0.5 band. Outside the shelf the
		bay circle runs over ground that is already below -4 and already under
		the sea poured at the top of this function, so the pour is a harmless
		no-op there rather than a bubble of air under the water.
	]]
	Terrain:FillCylinder(CFrame.new(CX, 20, BAY_CZ), 48, BAY_R, Enum.Material.Air)
	Terrain:FillCylinder(CFrame.new(CX, (SEA_TOP + -4) * 0.5, BAY_CZ), SEA_TOP - (-4), BAY_R,
		Enum.Material.Water)

	--[[
		THE RIM TRENCH, AND WHY IT NEEDS A THIRD FILL.

		A CYLINDER's edge is curved and the voxel grid is not, so every voxel the
		bay's rim passes through comes out at PARTIAL occupancy -- and a partly
		filled water voxel renders low. Measured on the axis: the sea sat at 0.000
		either side and dropped to -0.984 across z = 954..962, an eight-stud, one-
		stud-deep trench following the whole rim arc.

		This paves it over with a square of full-occupancy water. THE Y BAND IS THE
		WHOLE TRICK and it is -4..0 and nothing wider: the bay's FLOOR is the
		shallow shelf filled solid at -8..-4, so a fill that reached below -4 would
		dissolve the floor the player wades on and turn the bay into a 12-stud pit.

		And it is a SQUARE, sized so that every point in it is either inside the
		bay or over open shelf. The bay's north rim runs along the actual
		shoreline, where the -4..0 voxel is solid wet sand -- a fill that reached
		there would cut a moat between the beach and the sea. Checked at the
		corners: the worst case inside this square is 362 studs from the island
		centre, against the wet-sand ring's 344.
	]]
	Terrain:FillBlock(CFrame.new(CX, -2, 1050), Vector3.new(336, 4, 228), Enum.Material.Water)

	--[[
		Relief. Low mounds, not dunes: a ball sunk to (1 - lift) of its radius
		shows lift * r above the sand, and at 0.26-0.38 with radii in the teens
		and twenties these top out around eight studs. The dunes deliberately
		run 0.55-0.72 with radii up to 74 because that island needs a WALL to
		close its horizon; this one is a soft bay that has headlands and a sea to
		close it, and the same numbers here would bury it.
	]]
	local mounds = 0
	for _ = 1, 260 do
		if mounds >= 34 then
			break
		end
		local ang = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(150, 286)
		local r = rng:NextNumber(14, 30)
		local x = CX + math.cos(ang) * dist
		local z = CZ + math.sin(ang) * dist
		if openGround(x, z, r) and not inBay(x, z, r) then
			local lift = 0.26 + (dist - 150) / 136 * 0.12
			Terrain:FillBall(Vector3.new(x, GROUND - r * (1 - lift), z), r, ISL.matMessy)
			mounds += 1
		end
	end

	-- and a handful along the arms, so the headlands have some shape of their
	-- own instead of reading as two flat pucks
	local headlands = 0
	for _ = 1, 90 do
		if headlands >= 14 then
			break
		end
		local side = (rng:NextInteger(0, 1) == 0) and -1 or 1
		local ang = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(10, 62)
		local x = CX + side * ARM_X + math.cos(ang) * dist
		local z = ARM_Z + math.sin(ang) * dist
		local r = rng:NextNumber(16, 32)
		if openGround(x, z, r) and not inBay(x, z, r) then
			Terrain:FillBall(Vector3.new(x, GROUND - r * 0.62, z), r, ISL.matMessy)
			headlands += 1
		end
	end

	return mounds, headlands
end

----------------------------------------------------------------
-- The torii
----------------------------------------------------------------
--[[
	One torii, at any size. Three of them are built from this: the great one in
	the water, the frame of each travel gate, and the little name gate at the
	mouth of the boardwalk. That is a motif and not an accident -- a torii marks
	a threshold, and the cove has three of them in descending order of
	importance, so the same shape at three scales says what each threshold is
	worth without a word of signage.

	PROPORTIONS, which are the whole job. Real torii are wide: the span between
	the pillars is about 1.4 times the pillar height, the top rail overhangs the
	pillars generously at both ends, and the pillars lean very slightly inward.
	Get any one of those wrong and it reads as a swing set. The defaults below
	are h = 40 / span = 56, which is exactly 1.4.

	Pieces, bottom to top: the nemaki footings, the two hashira pillars, the
	nuki tie beam through them, the kusabi wedges where it passes through, the
	straight shimaki on the pillar tops, the swept kasagi over that, and the
	gakuzuka strut standing between nuki and shimaki.
]]
local function buildTorii(parent, name, base, o)
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent

	local h = o.h
	local span = o.span
	local dia = o.dia
	local over = o.over                 -- how far the shimaki runs past a pillar
	local lean = o.lean or 0.035
	local rise = o.rise or (h * 0.135)
	local warm = o.warm or PALETTE.vermilion
	local deep = o.deepColour or PALETTE.vermilionDeep
	local cap = o.cap or PALETTE.plum

	local half = span * 0.5
	local footSpread = math.sin(lean) * h * 0.5

	-- footings first, so the pillars sit into them rather than on them
	for _, side in ipairs({ -1, 1 }) do
		local fx = side * (half + footSpread)
		lp(m, "Nemaki", base, Vector3.new(dia * 1.55, h * 0.09, dia * 1.55),
			CFrame.new(fx, h * 0.03, 0), PALETTE.stoneDeep, Enum.Material.Concrete)
		pillar(m, "Hashira", base, CFrame.new(side * half, h * 0.5, 0), h, dia, side * lean,
			warm, Enum.Material.SmoothPlastic)
		-- a darker collar just above the footing: it is what stops a plain
		-- cylinder reading as a plastic tube, and it costs one part
		pillar(m, "Kamebara", base, CFrame.new(side * (half + footSpread * 0.7), h * 0.115, 0),
			h * 0.055, dia * 1.14, side * lean, deep, Enum.Material.SmoothPlastic,
			{ CanCollide = false })
	end

	-- the nuki, run through the pillars and out the far side, which is the
	-- myojin style and the reason a torii does not read as a doorframe
	local nukiY = h * 0.72
	lp(m, "Nuki", base, Vector3.new(span + over * 0.9, h * 0.075, dia * 0.78),
		CFrame.new(0, nukiY, 0), warm, Enum.Material.SmoothPlastic)
	for _, side in ipairs({ -1, 1 }) do
		lp(m, "Kusabi", base, Vector3.new(dia * 0.34, h * 0.105, dia * 0.9),
			CFrame.new(side * half, nukiY, 0), deep, Enum.Material.SmoothPlastic,
			{ CanCollide = false })
	end

	-- gakuzuka: the short strut on the centre line
	lp(m, "Gakuzuka", base, Vector3.new(dia * 0.7, h - nukiY - h * 0.02, dia * 0.62),
		CFrame.new(0, (nukiY + h) * 0.5, 0), warm, Enum.Material.SmoothPlastic,
		{ CanCollide = false })

	-- shimaki, straight, sitting on the pillar tops
	local shimakiH = h * 0.085
	lp(m, "Shimaki", base, Vector3.new(span + over * 2, shimakiH, dia * 1.16),
		CFrame.new(0, h + shimakiH * 0.5, 0), warm, Enum.Material.SmoothPlastic)

	-- kasagi, swept, sitting on the shimaki and running a little further again
	local kasagiH = h * 0.075
	local kasagiBase = base * CFrame.new(0, h + shimakiH + kasagiH * 0.5, 0)
	sweptRail(m, "Kasagi", kasagiBase, span + over * 2 + h * 0.12, rise, kasagiH, dia * 1.34,
		o.segs or 13, cap, Enum.Material.SmoothPlastic)

	local pp = m:FindFirstChild("Shimaki")
	if pp then
		m.PrimaryPart = pp
	end
	return m, h + shimakiH + kasagiH + rise
end

----------------------------------------------------------------
-- The boardwalk
----------------------------------------------------------------
--[[
	Pastel decking from the arrival gate up to the plaza.

	IT IS 0.12 PROUD AND NOT AN INCH MORE. "Raised boardwalk" is a look, not a
	height: anything a player can trip on between the only way into this area and
	the only place to sell is a bug, and the dunes settled on 0.12 for its paving
	as the largest lip that no step height can catch. What makes it READ as
	raised is the skirt -- a stringer dropped nearly a stud below the deck along
	both sides, which casts the shadow line a raised deck has without ever being
	something to walk up.

	The lantern posts are the reason this walk exists at all: the brief's
	"pastel boardwalks strung with glowing paper lanterns" is the one piece of
	the cove that has to be walked through rather than looked at.
]]
local function buildBoardwalk(parent)
	local m = Instance.new("Model")
	m.Name = "Boardwalk"
	m.Parent = parent

	local G = GROUND
	local x0, x1 = CX - WALK_HALF, CX + WALK_HALF

	-- planks across the run, two tones alternating. Cross-laid rather than
	-- lengthways because the grain then points at the plaza and does the same
	-- job an arrow would.
	local plank = 2.4
	local n = math.floor((WALK_Z1 - WALK_Z0) / plank)
	for i = 0, n - 1 do
		local z = WALK_Z0 + i * plank
		box(m, "Plank", x0, x1, G - 0.5, G + 0.12, z + 0.08, z + plank - 0.08,
			(i % 2 == 0) and PALETTE.timber or PALETTE.blossom, Enum.Material.WoodPlanks)
	end
	-- stringers: the shadow line that sells the "raised" without being a step
	for _, s in ipairs({ -1, 1 }) do
		box(m, "Stringer", CX + s * WALK_HALF - 0.9, CX + s * WALK_HALF + 0.9,
			G - 0.9, G + 0.16, WALK_Z0, WALK_Z1, PALETTE.timberDeep, Enum.Material.WoodPlanks)
	end

	-- posts, rails and lanterns. Posts stand OUTSIDE the deck so the walkable
	-- width is the full 24 studs and nobody clips a corner in a doorway.
	local postX = WALK_HALF + 1.6
	local lanterns, stones = 0, 0
	local zs = {}
	for z = WALK_Z0 + 5, WALK_Z1 - 3, 13 do
		table.insert(zs, z)
	end
	for i, z in ipairs(zs) do
		for si, s in ipairs({ -1, 1 }) do
			local px = CX + s * postX
			box(m, "Post", px - 0.75, px + 0.75, G - 0.6, G + 6.2, z - 0.75, z + 0.75,
				PALETTE.timberDeep, Enum.Material.Wood)
			box(m, "PostCap", px - 1.1, px + 1.1, G + 6.2, G + 6.7, z - 1.1, z + 1.1,
				PALETTE.cream, Enum.Material.SmoothPlastic, { CanCollide = false })

			-- the rail, drawn back to the previous post
			if i > 1 then
				local prev = zs[i - 1]
				box(m, "Rail", px - 0.45, px + 0.45, G + 3.1, G + 3.7, prev, z,
					PALETTE.cream, Enum.Material.Wood, { CanCollide = false })
				box(m, "RailLow", px - 0.35, px + 0.35, G + 1.5, G + 1.9, prev, z,
					PALETTE.blossomDeep, Enum.Material.Wood, { CanCollide = false })
			end

			-- a chochin at every post top, and a hand-built stand-in if the
			-- props module could not make one. The lanterns are structural to
			-- how this walk looks after sundown, so this is the one prop in the
			-- cove that gets a fallback rather than simply going missing.
			local hung = prop("paperLantern", m, CFrame.new(px, G + 8.4, z), 1.0)
			if hung then
				lanterns += 1
				--[[
					EVERY POST GETS A LANTERN. EVERY OTHER ONE GETS A LIGHT.

					Eight chochin down 56 studs of boardwalk is the right LOOK and
					the wrong cost: at Range 22 their volumes overlap almost
					completely, which is the expensive case under Future lighting --
					every fragment in the overlap is shaded once per light. The
					glow itself is carried by the Neon bodies, which cost nothing,
					so half the PointLights buy almost no picture.

					Dropped diagonally (i + si), not by side: killing one whole side
					lights the walk from the left and leaves the right rail dark.
				]]
				for _, d in ipairs(hung:GetDescendants()) do
					if d:IsA("PointLight") then
						if (i + si) % 2 == 0 then
							d.Range = 15
							d.Brightness = 1.35
						else
							d:Destroy()
						end
					end
				end
			else
				box(m, "LanternCord", px - 0.08, px + 0.08, G + 6.7, G + 9.6, z - 0.08, z + 0.08,
					PALETTE.plum, Enum.Material.SmoothPlastic, { CanCollide = false })
				local body = P(m, "LanternBody", Vector3.new(2.6, 3.4, 2.6),
					CFrame.new(px, G + 7.9, z), PALETTE.vermilion, Enum.Material.SmoothPlastic,
					{ CanCollide = false })
				-- Neon at Transparency 0. Above zero it renders near-black under
				-- Future lighting, so the glow is a solid core inside a slightly
				-- larger translucent shade rather than a see-through Neon shell.
				P(m, "LanternGlow", Vector3.new(1.7, 2.4, 1.7),
					CFrame.new(px, G + 7.9, z), PALETTE.glowWarm, Enum.Material.Neon,
					{ CanCollide = false })
				body.Transparency = 0.35
				local pl = Instance.new("PointLight")
				pl.Color = PALETTE.lantern
				pl.Range = 26
				pl.Brightness = 1.2
				pl.Shadows = false
				pl.Parent = body
			end
		end

		-- a toro standing off the walk every other bay, on alternating sides
		if i % 2 == 0 then
			local s = (i % 4 == 0) and 1 or -1
			if prop("stoneLantern", m, CFrame.new(CX + s * (postX + 7), G, z), 1.5) then
				stones += 1
			end
		end
	end

	return m, lanterns, stones
end

----------------------------------------------------------------
-- The plaza and the market
----------------------------------------------------------------
--[[
	THE KAKIGORI PITCH -- the cove's shop.

	The shaved-ice stand IS the shop, which is the whole reason it is here: the
	brief wants an interactive stall, and this place already has a working
	upgrade panel that opens on a ProximityPrompt named "ShopPrompt" anywhere in
	the world. Building the stand as a second economy would have been a week of
	work to arrive somewhere worse.

	The pitch -- the plinth, the back board, the sign and the prompt anchor -- is
	built here because it is civic geometry with a mechanic hanging off it. The
	STAND is Island3Props' job, and if it fails to arrive the counter is still
	standing and the shop still opens.

	The prompt's name is the entire integration and renaming it unhooks the shop,
	exactly as StoreBuilder's and Island2Builder's copies of this comment say.
	RequiresLineOfSight is off for the same reason it is off there: the counter
	stands between the player and the anchor, so the test would hide the prompt
	from precisely where you are meant to be standing. ObjectText is not
	cosmetic either -- MenuHud retitles its panel from it, and left blank the
	header reads BEACH SHOP while you are standing in Sakura Cove.
]]
local function buildKakigoriPitch(parent, cx, cz)
	local m = Instance.new("Model")
	m.Name = "Kakigori"
	m.Parent = parent

	local G = GROUND
	box(m, "Plinth", cx - 15, cx + 15, G - 0.5, G + 0.42, cz - 11, cz + 11,
		PALETTE.stoneDeep, Enum.Material.Concrete)
	box(m, "PlinthTrim", cx - 15.6, cx + 15.6, G + 0.18, G + 0.5, cz - 11.6, cz + 11.6,
		PALETTE.cream, Enum.Material.Concrete, { CanCollide = false })

	-- the stand itself, facing SOUTH down the boardwalk so the queue forms where
	-- the players arrive from
	prop("kakigoriStall", m, CFrame.lookAt(Vector3.new(cx, G + 0.42, cz + 1),
		Vector3.new(cx, G + 0.42, cz - 40)))

	--[[
		The anchor is INVISIBLE and stands in front of the counter, not on it.
		A ProximityPrompt parented to a prop that another script builds would
		vanish the moment that prop failed, and the shop would be gone with it --
		this way the prompt's parent is a part this file owns outright.
	]]
	local anchor = P(m, "PromptAnchor", Vector3.new(1, 1, 1),
		CFrame.new(cx, G + 5.2, cz - 9), PALETTE.cream, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
	local shopPrompt = Instance.new("ProximityPrompt")
	shopPrompt.Name = "ShopPrompt"
	shopPrompt.ActionText = "Browse"
	shopPrompt.ObjectText = "Kakigori Stand"
	shopPrompt.KeyboardKeyCode = Enum.KeyCode.E
	shopPrompt.HoldDuration = 0
	shopPrompt.MaxActivationDistance = 16
	shopPrompt.RequiresLineOfSight = false
	shopPrompt.Parent = anchor

	-- The name board, read from the boardwalk. Both faces: a thin board has two
	-- readable sides and signing only one is a coin flip you lose half the time
	-- -- and here the far side is what you read walking back down to the gate.
	local board = box(m, "ShopBoard", cx - 11, cx + 11, G + 9.4, G + 13.4, cz - 9.6, cz - 9.2,
		PALETTE.cream, Enum.Material.SmoothPlastic)
	if board then
		SignKit.dress(board, "KAKIGORI", { Enum.NormalId.Front, Enum.NormalId.Back })
	end
	for _, s in ipairs({ -1, 1 }) do
		box(m, "BoardPost", cx + s * 11 - 0.5, cx + s * 11 + 0.5, G + 0.42, G + 13.4,
			cz - 9.7, cz - 9.1, PALETTE.timberDeep, Enum.Material.Wood)
	end

	return m
end

local function buildPlaza(parent)
	local m = Instance.new("Model")
	m.Name = "Market"
	m.Parent = parent

	local G = GROUND
	local X0, X1 = CX - PLAZA_HALF, CX + PLAZA_HALF

	-- Collidable and 0.12 proud, so the player walks ON the paving rather than
	-- through a decal of it, and 0.12 is under any step height that would catch
	-- a foot. Same number as the boardwalk, and they meet edge to edge at
	-- z = PLAZA_Z0 with no overlap, so there is no coplanar strip to z-fight.
	box(m, "Paving", X0, X1, G - 0.5, G + 0.12, PLAZA_Z0, PLAZA_Z1,
		PALETTE.stone, Enum.Material.Concrete)
	for i = 1, 7 do
		local jx = X0 + i * ((X1 - X0) / 8)
		box(m, "Joint", jx - 0.3, jx + 0.3, G + 0.12, G + 0.17, PLAZA_Z0, PLAZA_Z1,
			PALETTE.stoneDeep, Enum.Material.Concrete, { CanCollide = false })
	end
	for _, s in ipairs({ -1, 1 }) do
		box(m, "Kerb", CX + s * PLAZA_HALF - 1.3, CX + s * PLAZA_HALF + 1.3,
			G + 0.12, G + 0.8, PLAZA_Z0, PLAZA_Z1, PALETTE.blossomDeep, Enum.Material.Concrete)
	end
	-- the south kerb, broken for the boardwalk. The gap is wider than the deck
	-- so the little name gate's posts stand in it rather than on the decking.
	for _, run in ipairs({ { X0, CX - WALK_GAP }, { CX + WALK_GAP, X1 } }) do
		box(m, "KerbSouth", run[1], run[2], G + 0.12, G + 0.8, PLAZA_Z0 - 1.3, PLAZA_Z0 + 1.3,
			PALETTE.blossomDeep, Enum.Material.Concrete)
	end
	-- ...and the north one, which the plaza used to do without. Cream paving met
	-- raspberry sand along a dead-straight sixty-stud line with the biggest value
	-- jump anywhere in the cove across it, and it read as a seam in the world
	-- rather than as the edge of a plaza. A kerb is what an edge looks like; it
	-- costs one part and it puts a mid tone between the two extremes.
	box(m, "KerbNorth", X0, X1, G + 0.12, G + 0.8, PLAZA_Z1 - 1.3, PLAZA_Z1 + 1.3,
		PALETTE.blossomDeep, Enum.Material.Concrete)

	--[[
		THE SELL PAD. Three courses, not one slab.

		Same shape and behaviour as the beach's -- CTB_Server tests every pad in
		its list against the player's position, so standing on this one sells
		exactly as that one does, and this is the part that must come back out
		of build().

		The beach gets away with a single part because its sand is cool enough
		to hold an edge against gold. Pink sand is not: a warm pad on a warm
		pale plaza is nearly the same VALUE as the plaza and disappears. So it
		gets a dark frame under it to have an edge at all, exactly as the dunes'
		does, and it rides 0.34 above ground rather than 0.22 because the paving
		is 0.12 proud and the glow beneath has to clear the joint lines -- which
		are the one thing here thin enough to z-fight.
	]]
	local padX, padZ = CX - 52, 1358
	P(m, "PadFrame", Vector3.new(23.4, 0.3, 16.4),
		CFrame.new(padX, G + 0.27, padZ), PALETTE.plum, Enum.Material.Concrete,
		{ CanCollide = false })
	-- Neon at Transparency 0 (see the header). The glow course is a solid slab
	-- of a dimmed colour rather than a translucent bright one, which is the
	-- only way Neon reads as light under Future lighting.
	P(m, "PadGlow", Vector3.new(21.4, 0.24, 14.4),
		CFrame.new(padX, G + 0.42, padZ), Color3.fromRGB(255, 176, 198), Enum.Material.Neon,
		{ CanCollide = false })
	local pad = P(m, "SellPad", Vector3.new(20, 0.45, 13),
		CFrame.new(padX, G + 0.52, padZ), PALETTE.blossom, Enum.Material.SmoothPlastic)

	local padSign = box(m, "PadBoard", padX - 10, padX + 10, G + 5.4, G + 8.6,
		padZ + 7.2, padZ + 7.6, PALETTE.cream, Enum.Material.SmoothPlastic)
	if padSign then
		SignKit.dress(padSign, "SELL YOUR FINDS", { Enum.NormalId.Front, Enum.NormalId.Back })
	end
	for _, s in ipairs({ -1, 1 }) do
		box(m, "PadPost", padX + s * 10 - 0.45, padX + s * 10 + 0.45, G + 0.12, G + 8.6,
			padZ + 7.1, padZ + 7.7, PALETTE.timberDeep, Enum.Material.Wood)
	end

	-- the shop
	buildKakigoriPitch(m, CX + 46, 1364)

	--[[
		The vending machines, IN A ROW along the plaza's north edge.

		They used to be spread one per third of a 208-stud plaza, which is how a
		street fixture ends up reading as three lonely boxes. A rank of three
		shoulder to shoulder is what a Japanese vending corner actually looks like,
		and it fills the one part of the plaza that had nothing on it -- the gap
		between the sell pad and the kakigori pitch.

		Flavours are passed through rather than tinted here: the machine's colour
		is decided on the props side, and a sweep of BaseParts from out here would
		do nothing at all.
	]]
	local vends = 0
	for _, v in ipairs({
		{ CX - 22, 1386, "sakura" },
		{ CX, 1386, "melon" },
		{ CX + 22, 1386, "ramune" },
	}) do
		if prop("vendingMachine", m,
			CFrame.lookAt(Vector3.new(v[1], GROUND + 0.12, v[2]),
				Vector3.new(v[1], GROUND + 0.12, v[2] - 40)), v[3]) then
			vends += 1
		end
	end

	--[[
		The little name gate at the mouth of the boardwalk, and the third torii
		in the set. Its board is read on the way IN from the arrival gate (Front
		is -Z, and -Z is where the gate is) and on the way back out, so both
		faces are dressed.

		A pale board inverts SignKit's contrast rule to ink-on-cream where the
		beachfront's near-black boards come out cream-on-ink. Same rule, and it
		is what keeps a light-palette sign legible without breaking the set.
	]]
	local gateZ = PLAZA_Z0 + 4
	local nameGate = buildTorii(m, "MarketGate",
		CFrame.new(CX, GROUND + 0.12, gateZ),
		{ h = 15, span = 30, dia = 2.0, over = 5.5, lean = 0.03, rise = 2.2, segs = 9 })
	-- Hung as a GAKU: the name plaque on a real torii sits on the gakuzuka,
	-- between the nuki and the shimaki, and that is the one band of this frame
	-- with nothing else in it. Standing it above the kasagi instead would put
	-- the lettering behind the swept rail from anywhere but dead ahead.
	local nameBoard = box(nameGate, "NameBoard", CX - 8.5, CX + 8.5, GROUND + 11.4, GROUND + 14.6,
		gateZ + 0.78, gateZ + 1.34, PALETTE.cream, Enum.Material.SmoothPlastic)
	if nameBoard then
		SignKit.dress(nameBoard, "SAKURA COVE", { Enum.NormalId.Front, Enum.NormalId.Back })
	end

	return m, pad, vends
end

----------------------------------------------------------------
-- Travel gates
----------------------------------------------------------------
--[[
	One gateway, as a torii rather than the dunes' Egyptian pylons, and with the
	dunes' internals to the letter: Pad > TravelPrompt, Board > GateGui > Info,
	and Veil. Island3_Client wires the lock by exactly those names and renaming
	any one of them silently unhooks it.

	`label` is what the sign says when it is UNLOCKED. The locked text is written
	per player by Island3_Client, because a ProximityPrompt and a BillboardGui
	are single shared objects -- writing "needs Lv.5" on the server would show it
	to a player who had already earned their way through, and disabling the
	prompt on the server would lock out everyone the moment one person was short.

	THE VEIL IS NOT NEON, and that is a departure from the dunes on purpose.
	Neon above Transparency 0 renders near-black under Future lighting, so the
	dunes' translucent turquoise sheet is doing nothing for it that a dark part
	would not. Here the veil is SmoothPlastic with a little Reflectance -- the
	house rule for anything see-through, and specifically not Glass, which culls
	transparent objects behind it and would punch a hole in the petals drifting
	past. The glow comes from solid Neon jambs at Transparency 0 either side.
]]
local function buildGate(parent, name, cf, label)
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent

	local x, y, z = cf.X, cf.Y, cf.Z
	local function b(n, x0, x1, y0, y1, z0, z1, c, mat, extra)
		return box(m, n, x + x0, x + x1, y + y0, y + y1, z + z0, z + z1, c, mat, extra)
	end

	buildTorii(m, "Frame", CFrame.new(x, y, z),
		{ h = 20, span = 22, dia = 2.6, over = 6, lean = 0.032, rise = 2.6, segs = 11 })

	b("Step", -16, 16, -0.3, 0.3, -7, 7, PALETTE.stoneDeep, Enum.Material.Concrete)

	-- the shimmer in the opening. Non-collidable: this is a sign that something
	-- happens here, not the thing that makes it happen.
	-- Starts nearly clear, which is the OPEN reading. Island3_Client owns this
	-- value from its first refresh; the number here is only what a client that
	-- has not wired yet sees, and "open" is the safer thing for it to be.
	b("Veil", -6.5, 6.5, 0.4, 18.4, -0.3, 0.3, PALETTE.blossom, Enum.Material.SmoothPlastic,
		{ CanCollide = false, Transparency = 0.88, Reflectance = 0.08 })
	for _, s in ipairs({ -1, 1 }) do
		-- Darkened from (255,168,196). Neon has no exposure headroom under this
		-- place's Brightness 3.10 + Bloom(0.55, 1.6): a pale pink Neon jamb blows
		-- straight to flat white and reads as a strip light, not as a pink glow.
		-- The house rule for Neon in this project is to darken the Color3 rather
		-- than reach for Transparency, which renders near-black instead.
		b("VeilJamb", s * 6.5 - 0.35, s * 6.5 + 0.35, 0.4, 18.4, -0.24, 0.24,
			Color3.fromRGB(214, 96, 140), Enum.Material.Neon, { CanCollide = false })
	end

	--[[
		THE NAME BOARD, PAINTED ON THE BOARD.

		This was a BillboardGui sized { 0, 300 } x { 0, 78 } -- PIXELS, not studs --
		floating 3.4 studs above an 18 x 4.2 board it was supposed to belong to. A
		pixel-sized billboard does not shrink with distance, so the lettering ended
		up two to three times the width of its own board and hung in the sky above
		it. Measured consequences: from the bay, "THE BEACH" rendered INSIDE the
		great torii's opening, and from the field it was the largest, loudest
		object in Sakura Cove -- an area whose entire palette is soft pink.

		A SurfaceGui instead, through the same SignKit every other board in the
		game goes through, so the gate agrees with the market gate standing sixty
		studs from it rather than contradicting it.

		BOTH FACES, and the back one matters MORE: the beach gate is walked up to
		from +Z and so is the cove gate on the way home, and +Z is Back.

		SIZED FOR THE LONGEST STRING IT WILL EVER HOLD, not for the one it is being
		given. Island3_Client swaps in "SIFTER Lv.5 NEEDED" when the gate is
		locked, which is longer than either label, and a SurfaceGui label's
		TextSize is computed ONCE at dress time -- fit to "THE BEACH" it would
		render the locked text straight off both ends of the board. (Lv.99 rather
		than Lv.5 so the fit survives the day somebody raises UNLOCK_LEVEL.)

		NAMED "GateGui" ON BOTH, deliberately. Island3_Client's contract is
		Board > GateGui > Info and it walks every child of that name, so the two
		faces lock and unlock together.
	]]
	local infoLabel = nil
	local board = b("Board", -9, 9, 25.4, 29.6, -0.4, 0.4, PALETTE.cream,
		Enum.Material.SmoothPlastic)
	if board then
		for _, face in ipairs({ Enum.NormalId.Front, Enum.NormalId.Back }) do
			local sg = SignKit.surface(board, face)
			sg.Name = "GateGui"
			sg.MaxDistance = 400
			local info = sg:FindFirstChild("Info")
			if not info then
				info = Instance.new("TextLabel")
				info.Name = "Info"
				info.Parent = sg
			end
			info.Text = label
			-- No tint passed: Island3_Client re-colours this label as the gate
			-- locks and unlocks. What the kit is here for is the face, the
			-- outline and the fit.
			SignKit.name(info, board, face)
			local canvas = SignKit.canvasFor(board, face)
			SignKit.fitOneLine(info, Vector2.new(canvas.X * 0.92, canvas.Y * 0.74),
				"SIFTER Lv.99 NEEDED")
			infoLabel = infoLabel or info
		end
	end

	-- The pad you stand on, and the prompt. Not Neon: see the veil note. A
	-- pastel slab with a solid Neon inlay reads as lit; a translucent Neon slab
	-- reads as a dark stain.
	local pad = P(m, "Pad", Vector3.new(13, 0.5, 13), CFrame.new(x, y + 0.25, z),
		PALETTE.blossom, Enum.Material.SmoothPlastic)
	P(m, "PadInlay", Vector3.new(9.4, 0.16, 9.4), CFrame.new(x, y + 0.54, z),
		Color3.fromRGB(222, 112, 150), Enum.Material.Neon, { CanCollide = false })

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TravelPrompt"
	prompt.ActionText = "Travel"
	prompt.ObjectText = label
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = pad

	return m, prompt, infoLabel
end

--[[
	WHERE THE BEACH GATE ACTUALLY GOES.

	(-62, ground, -170) mirrors the dunes' gate at (62, ground, -170) and that is
	where this started -- but measured, it is 2.6 studs from the car spawner's
	west kerb and a gate built there straddles the whole bay. The brief's number
	was a sketch, so this searches rather than trusts it: step west along the
	same z line, and take the first spot where the gate's real FOOTPRINT is free
	of anything belonging to the beach, the dunes, the wash bay or the car
	spawner.

	It is a VOLUME test and not a distance-to-nearest-part test, deliberately.
	The beachfront's west end is thick with scattered loungers and umbrellas, so
	no point out there has 25 clear studs around it and a radius rule rejects the
	entire beach. What matters is whether anything is standing where the gate
	goes, which is what an overlap query answers.

	Measured at the time of writing: the first clear step is x = -86, ground
	about 2.85. It is not hardcoded, because the beach gets redressed.
]]
local function siteBeachGate(): CFrame
	local blockers = {}
	for _, n in ipairs({ "Beach", "Island2", "WashBay", "CarSpawner" }) do
		local inst = workspace:FindFirstChild(n)
		if inst then
			table.insert(blockers, inst)
		end
	end

	--[[
		CLEARANCE IS ARITHMETIC HERE, NOT A SPATIAL QUERY, AND THAT IS THE POINT.

		This asked workspace:GetPartBoundsInBox() first, and the answer it gave was
		worthless. Measured on the very beach it is meant to protect: of the 2609
		BaseParts under Beach / Island2 / WashBay / CarSpawner, 2005 -- 77% -- carry
		CanQuery = false, and ALL 186 of the parts standing within 60 studs of the
		nominal gate site do. Spatial queries skip those, so the test was blind to
		essentially everything it was pointed at: it reported "clear" at sites where
		a palm canopy sits through where the lintel goes, and the only reason it
		moved the gate at all was the one CanQuery = true part in range.

		A clearance test that answers "clear" for solid geometry is worse than no
		test, because the fallback below then never fires and nobody looks again.
		So the sweep walks the real parts and compares boxes by hand -- a few
		thousand comparisons, once, at build time -- and cannot be lied to by a
		rendering or query flag.

		SOLID ONLY DISQUALIFIES. A CanCollide part inside the footprint is a gate
		in a wall or a pad nobody can walk onto, and that site is refused. Non-
		collidable dressing is allowed to overlap: on this beachfront the palm
		canopies are 25-stud bounding boxes hanging 30 studs up, and refusing every
		site one of them touches walks the gate off the west end of the sand.
	]]
	local boxes = {}
	for _, inst in ipairs(blockers) do
		for _, q in ipairs(inst:GetDescendants()) do
			if q:IsA("BasePart") and q.CanCollide then
				-- World half-extents of a part that may be rotated: Size is measured
				-- in the part's OWN frame, so every world axis takes a contribution
				-- from all three local ones. Using Size.Y as world height is the
				-- classic way to get this wrong.
				local cf, s = q.CFrame, q.Size
				local R, U, L = cf.RightVector, cf.UpVector, cf.LookVector
				table.insert(boxes, {
					c = cf.Position,
					h = Vector3.new(
						0.5 * (math.abs(R.X) * s.X + math.abs(U.X) * s.Y + math.abs(L.X) * s.Z),
						0.5 * (math.abs(R.Y) * s.X + math.abs(U.Y) * s.Y + math.abs(L.Y) * s.Z),
						0.5 * (math.abs(R.Z) * s.X + math.abs(U.Z) * s.Y + math.abs(L.Z) * s.Z)),
				})
			end
		end
	end

	local function solidIntrusions(centre: Vector3, foot: Vector3): number
		local fmin, fmax = centre - foot * 0.5, centre + foot * 0.5
		local n = 0
		for _, b in ipairs(boxes) do
			if fmin.X < b.c.X + b.h.X and fmax.X > b.c.X - b.h.X
				and fmin.Y < b.c.Y + b.h.Y and fmax.Y > b.c.Y - b.h.Y
				and fmin.Z < b.c.Z + b.h.Z and fmax.Z > b.c.Z - b.h.Z then
				n += 1
			end
		end
		return n
	end

	-- the gate's own extent, plus a stud of margin: 38 wide (pylons at +-11 and
	-- a 32-stud step), 28 deep, 30 tall
	local FOOT = Vector3.new(38, 30, 28)
	local z = GATE_BEACH_NOMINAL.Z

	for i = 0, 16 do
		local x = GATE_BEACH_NOMINAL.X - i * 8
		local hit = workspace:Raycast(Vector3.new(x, 160, z), Vector3.new(0, -300, 0), groundParams)
		if hit then
			local y = hit.Position.Y
			-- and it has to be flat enough to stand a gate on: a pad half buried
			-- in a rise is worse than a pad eight studs further along
			local lo, hi = y, y
			for dx = -16, 16, 8 do
				local h2 = workspace:Raycast(Vector3.new(x + dx, 160, z), Vector3.new(0, -300, 0), groundParams)
				if h2 then
					lo = math.min(lo, h2.Position.Y)
					hi = math.max(hi, h2.Position.Y)
				end
			end
			if hi - lo < 1.5 and solidIntrusions(Vector3.new(x, y + 13, z), FOOT) == 0 then
				if i > 0 then
					print(string.format("[Cove] beach gate moved %d studs west of the nominal site to clear the beachfront", i * 8))
				end
				return CFrame.new(x, y, z)
			end
		end
	end

	-- Nothing clear anywhere along the line. Take the nominal site rather than
	-- refusing to build one: a gate inside a car park is ugly, and no gate home
	-- from the cove is a player who cannot get back.
	warn("[Cove] no clear beach-gate site found along z = " .. z .. "; using the nominal one")
	local y = groundY(GATE_BEACH_NOMINAL.X, z, GATE_BEACH_NOMINAL.Y)
	return CFrame.new(GATE_BEACH_NOMINAL.X, y, z)
end

----------------------------------------------------------------
-- build
----------------------------------------------------------------
function Island3.build()
	--[[
		ONCE, EVER, AND BEFORE baselineField(). NOT "idempotent", which is what
		this used to claim.

		The GEOMETRY half is idempotent -- the folder is destroyed and remade. The
		TERRAIN half is not, in one specific and unrecoverable way: buildTerrain
		opens with a 620-radius Air wipe that covers the whole rakeable square, so
		a second call erases every column every player in the server has raked in
		Sakura Cove, with no warning and no way back. At boot that is exactly
		right, because CTB_Server lays the baseline down immediately afterwards.
		At any other time -- a hot reload, a maintenance re-run, a future "rebuild
		the island" admin command -- it is a wipe.
	]]
	if Island3.built then
		warn("[Cove] build() called again. The terrain wipe covers the whole rakeable square, "
			.. "so every player's raked progress in Sakura Cove has just been erased. This is only "
			.. "safe once, at boot, before CTB_Server's baselineField().")
	end
	Island3.built = true

	local old = workspace:FindFirstChild("Island3")
	if old then
		old:Destroy()
	end

	local root = Instance.new("Folder")
	root.Name = "Island3"
	root.Parent = workspace

	local mounds, headlands = buildTerrain()
	waitForGround()

	local props = Instance.new("Folder")
	props.Name = "Props"
	props.Parent = root

	----------------------------------------------------------------
	-- The landmark
	----------------------------------------------------------------
	--[[
		THE GREAT TORII, standing in the water on the cove's axis.

		Its Y comes off a raycast and not off a constant. The bay floor at this
		point is the result of four disc fills, a voxel lift and a carve, and the
		one thing that must be true of this gate is that its feet are UNDER the
		water -- a torii resting on the surface is a prop, a torii wading is a
		landmark. The base is set a stud into the sand so the footings are buried
		rather than balanced, which puts about 2.5 studs of pillar under water.

		On the cove's axis and 76 studs south of the arrival gate, so from the
		plaza you look down the boardwalk, through the arrival gate, and the
		great torii stands beyond it -- the opening frames its base and its top
		clears the lintel. That receding line of three thresholds is the shot the
		whole area is laid out around, which is also why the KEEP_OUT table
		reserves a wide box here that nothing scattered may enter.
	]]
	-- groundYWait, not groundY: this column is 300 studs from the probe point in
	-- different chunks, and a miss here silently drops the landmark onto a
	-- fallback constant. See the note on groundYWait.
	local floorY = groundYWait(CX + TORII_X, TORII_Z, -2)
	local _, toriiTop = buildTorii(root, "GreatTorii",
		CFrame.new(CX + TORII_X, floorY - 1, TORII_Z),
		{ h = 40, span = 56, dia = 5.8, over = 15, lean = 0.035, rise = 5.5, segs = 13 })

	----------------------------------------------------------------
	-- The walk in
	----------------------------------------------------------------
	local _, lanterns, stoneLanterns = buildBoardwalk(root)
	local _, sellPad, vends = buildPlaza(root)
	--[[
		PUBLISHED THE MOMENT IT EXISTS, not staked on the rest of build() finishing.

		CTB_Server only learns about this pad from build()'s return value, and that
		is two hundred lines away: both gates, the whole scatter, the anchor sweep
		and the field assertion all sit in between. Anything that throws in there
		leaves the pad PHYSICALLY STANDING in the world, glowing, under its "SELL
		YOUR FINDS" board -- and unregistered, so it does nothing. The player fills
		a bag on it, gets RollerBlocked, and the only way out is the 1500-stud walk
		home. Publishing it here costs one line and CTB_Server picks it up off the
		module if the pcall round build() catches anything.
	]]
	Island3.sellPad = sellPad

	----------------------------------------------------------------
	-- Travel
	----------------------------------------------------------------
	local gates = Instance.new("Folder")
	gates.Name = "Gates"
	gates.Parent = root

	local beachCF = siteBeachGate()
	-- and the cove end goes wherever the ground actually is, rather than
	-- wherever the shoreline was last time somebody moved the bay
	local coveCF = CFrame.new(GATE_COVE.X, groundY(GATE_COVE.X, GATE_COVE.Z, GROUND), GATE_COVE.Z)

	local _, beachPrompt = buildGate(gates, "BeachGate", beachCF, "SAKURA COVE")
	local _, covePrompt = buildGate(gates, "CoveGate", coveCF, "THE BEACH")

	local function arrive(plr, pos)
		local char = plr.Character
		if not char or not char.PrimaryPart then
			return
		end
		char:PivotTo(CFrame.lookAt(pos, pos + Vector3.new(0, 0, 1)))
	end

	beachPrompt.Triggered:Connect(function(plr)
		-- Checked HERE, on the server, off the same RollerLevel attribute
		-- ProgressionServer writes. Island3_Client greys the prompt out, but
		-- that is presentation: this is the check.
		if (plr:GetAttribute("RollerLevel") or 1) < UNLOCK_LEVEL then
			return
		end
		-- twelve studs to +Z of the pad, which is onto the boardwalk and facing
		-- up it into the cove
		arrive(plr, Vector3.new(coveCF.X, coveCF.Y + 4, coveCF.Z + 12))
	end)

	-- No level check coming BACK. Stranding a player who somehow got here under
	-- the requirement -- by swimming the continuous ocean, or by losing a level
	-- to a rebirth -- would be a much worse bug than letting them ride home.
	covePrompt.Triggered:Connect(function(plr)
		arrive(plr, Vector3.new(beachCF.X, beachCF.Y + 4, beachCF.Z + 12))
	end)

	root:SetAttribute("UnlockLevel", UNLOCK_LEVEL)

	----------------------------------------------------------------
	-- Scatter
	----------------------------------------------------------------
	-- A fresh seed offset, so the cove's layout is stable across boots but is
	-- not correlated with the dunes' (+5150) or the vault's (+3141).
	local rng = Random.new(Config.SEED + 6188)

	--[[
		PROP-TO-PROP SPACING, which openGround() does not and cannot do.

		openGround() answers "is this spot clear of the rakeable field and of the
		civic geometry". It knows nothing about the props this same loop has
		already dropped, and measured on the shipped island that showed:

		  * a sakura trunk at (143, 1411) overlapping a panda parasol's Canopy1 by
		    7.46 studs, with the panda's black face parts left hanging detached in
		    mid-air beside the tree;
		  * trunk pairs 3.5, 7.8 and 9.2 studs apart;
		  * rock formations overlapping each other by up to 21.8 studs.

		ONE list shared by every scatter below, because the collisions were between
		categories as often as within them. The radius each claim reserves is the
		prop's real footprint, not its trunk: a cherry tree is its canopy.
	]]
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

	local trees = 0
	for _ = 1, 460 do
		if trees >= 24 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(122, 268)
		local x, z = CX + math.cos(a) * d, CZ + math.sin(a) * d
		local s = rng:NextNumber(0.8, 1.35)
		if openGround(x, z, 14) and not inBay(x, z, 14) and spaced(x, z, 11 * s) then
			local y = groundY(x, z, GROUND)
			-- skip anything that landed on the flank of a mound steep enough
			-- that the trunk would come out of it sideways
			if math.abs(y - GROUND) < 5 then
				if prop("sakuraTree", props, CFrame.new(x, y, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), s) then
					trees += 1
					claim(x, z, 11 * s)
				end
			end
		end
	end

	--[[
		Rocks at the water's edge, which is where the terrain cannot help. The
		cove owns exactly two terrain materials and both are the raked pair, so
		"pastel rock" cannot be a terrain material the way the dunes' outcrops
		are -- everything else in the game is already spoken for by the beach,
		the dunes or the vault. Out here rock is a PROP, and it is placed by
		height rather than by radius so it lands on the tideline instead of
		somewhere on the flat.
	]]
	local rocks = 0
	for _ = 1, 520 do
		if rocks >= 18 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(250, 352)
		local x, z = CX + math.cos(a) * d, CZ + math.sin(a) * d
		local s = rng:NextNumber(1.1, 2.4)
		if openGround(x, z, 10) and spaced(x, z, 5.2 * s) then
			local y = groundY(x, z, GROUND)
			-- the tideline, and only the tideline: the wet-sand ring renders a
			-- stud under the dry sand and the shelf two under the water, so this
			-- window picks the shore without needing a radius that would have to
			-- be re-derived every time a mound moves
			if y > -1.2 and y < GROUND - 0.15 then
				if prop("rockFormation", props, CFrame.new(x, y, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), s) then
					rocks += 1
					claim(x, z, 5.2 * s)
				end
			end
		end
	end
	-- and a few big ones out on the headlands, which is what makes them read as
	-- headlands rather than as two sandbars
	for _, side in ipairs({ -1, 1 }) do
		for i = 1, 3 do
			local a = rng:NextNumber(0, math.pi * 2)
			local d = rng:NextNumber(26, 74)
			local x = CX + side * ARM_X + math.cos(a) * d
			local z = ARM_Z + math.sin(a) * d
			local s = rng:NextNumber(2.2, 3.6)
			if openGround(x, z, 12) and not inBay(x, z, 8) and spaced(x, z, 5.2 * s) then
				local y = groundY(x, z, GROUND)
				if y > -1.0 then
					if prop("rockFormation", props, CFrame.new(x, y, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), s) then
						rocks += 1
						claim(x, z, 5.2 * s)
					end
				end
			end
		end
	end

	-- Beach furniture on the dry sand outside the field, cycling the three
	-- variants so no two neighbouring clusters are the same set.
	local VARIANTS = { "heart", "panda", "pastel" }
	local sets = 0
	for _ = 1, 420 do
		if sets >= 7 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(118, 190)
		local x, z = CX + math.cos(a) * d, CZ + math.sin(a) * d
		-- 13, the widest thing in the set: the parasol canopy is 11.4 across and
		-- it hangs off the cluster's -X side, so the whole group reaches about 12
		-- studs from its origin at the worst yaw.
		if openGround(x, z, 14) and not inBay(x, z, 20) and spaced(x, z, 13) then
			local y = groundY(x, z, GROUND)
			if math.abs(y - GROUND) < 1.4 then
				if prop("beachSet", props,
					CFrame.new(x, y, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
					VARIANTS[(sets % 3) + 1]) then
					sets += 1
					claim(x, z, 13)
				end
			end
		end
	end

	--[[
		Floaties, sitting ON the water rather than on the floor. Their Y is the
		sea surface and not a raycast: the raycast under the bay returns the sand
		shelf a stud and a half down, and a flamingo half sunk in the seabed is
		exactly the sort of thing that looks like a physics bug in a game where
		physics is not running.

		They are anchored like everything else here. Nothing on this island is
		simulated -- Edit does not run physics at all, so an unanchored float
		would look fine in Studio and drift out to sea on the first live server.
	]]
	local FLOATIES = { "flamingo", "boba", "cat", "flamingo", "boba", "cat", "flamingo" }
	local floats = 0
	for _ = 1, 300 do
		if floats >= #FLOATIES then
			break
		end
		local a = rng:NextNumber(math.pi * 0.15, math.pi * 0.85)
		local d = rng:NextNumber(44, 128)
		local x = CX + math.cos(a) * d
		local z = BAY_CZ + math.sin(a) * d
		-- inside the bay, off the torii, and not so far out that it is bobbing
		-- in the open sea
		if inBay(x, z, -18) and clearOfBuildings(x, z, 8) and spaced(x, z, 10) then
			-- SEA_SURFACE, not SEA_TOP: the fill asks for -0.5 and FillCylinder
			-- gives 0.00 (see the SEA_TOP note). Placed at SEA_TOP + 0.2 these were
			-- 0.3 studs UNDER the waterline rather than 0.2 above it.
			if prop("floatie", props,
				CFrame.new(x, SEA_SURFACE + 0.2, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
				FLOATIES[floats + 1]) then
				floats += 1
				claim(x, z, 10)
			end
		end
	end

	-- a grove behind the field, so the north horizon is blossom rather than
	-- empty sand
	for _ = 1, 200 do
		if trees >= 34 then
			break
		end
		local x = CX + rng:NextNumber(-150, 150)
		local z = CZ + rng:NextNumber(120, 240)
		local s = rng:NextNumber(0.9, 1.4)
		if openGround(x, z, 12) and spaced(x, z, 11 * s) then
			local y = groundY(x, z, GROUND)
			if math.abs(y - GROUND) < 5 then
				if prop("sakuraTree", props, CFrame.new(x, y, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), s) then
					trees += 1
					claim(x, z, 11 * s)
				end
			end
		end
	end

	----------------------------------------------------------------
	-- Final sweeps
	----------------------------------------------------------------
	--[[
		Anchor everything, once, at the end. Island3Props' contract says every
		BasePart it returns is anchored, and this is not a substitute for that --
		it is the net under it. An unanchored part in a server-built island does
		not fail visibly at boot; it falls over some time in the next few minutes
		on a live server, on somebody else's screen, with nothing in the log.
	]]
	local unanchored = 0
	for _, p in ipairs(root:GetDescendants()) do
		if p:IsA("BasePart") and not p.Anchored then
			p.Anchored = true
			unanchored += 1
		end
	end
	if unanchored > 0 then
		warn(string.format("[Cove] anchored %d part(s) that arrived loose from Island3Props", unanchored))
	end

	--[[
		SHADOW CASTERS, TRIMMED.

		Every one of the ~1000 parts out here shipped with CastShadow on, and under
		Future lighting each one is a draw into the shadow map whether or not it
		puts anything on the ground. Three classes never do:

		  * anything under a stud on its smallest axis -- rails, joints, whiskers,
		    straps, lantern marks. At the sun angle this island is lit at, their
		    shadow is thinner than a pixel from anywhere a player stands.
		  * Neon. A part that is supposed to be emitting light casting a hard black
		    shadow is wrong as well as expensive.
		  * anything more than half transparent -- the veils, the boba cup walls,
		    the invisible roots and prompt anchors. Roblox shadows them as solid.

		The blossom canopies KEEP theirs on purpose: dappled shade under a cherry
		tree at a low sun is the single best thing the lighting does here.
	]]
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

	print(string.format(
		"[Cove] island built: %d mounds, %d headland rises, %d sakura, %d rock formations, %d beach sets, %d floaties, %d lanterns (+%d toro), %d vending; torii top y=%.1f at x=%.0f; beach gate at (%.0f, %.1f, %.0f); %d prop failures, %d field intruders",
		mounds, headlands, trees, rocks, sets, floats, lanterns, stoneLanterns, vends,
		(floorY - 1) + toriiTop, CX + TORII_X, beachCF.X, beachCF.Y, beachCF.Z, propFails, intruders))
	print(string.format("[Cove] cost: %d parts, %d lights, %d shadow casters trimmed",
		partCount, lightCount, shadowsOff))

	return sellPad
end

return Island3
