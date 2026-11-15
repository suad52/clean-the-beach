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
	                      and its ShopPrompt, and the SCATTER PLACEMENT of the
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

	HAND-EDITING THIS COVE. By default build() destroys Workspace.Island3 and
	makes it again, so anything moved in Studio is gone the moment you press Play.
	Set the boolean attribute "HandBuilt" on the Workspace.Island3 folder and that
	stops -- see ADOPT OR BUILD, just above build(). The cove needs no wiring pass
	on the way back in the way the dunes do: nothing in this script connects an
	event, so an adopted cove is the saved geometry plus the final sweeps and
	nothing else.

	IT NO LONGER PUBLISHES AN UnlockLevel. That attribute existed for the gate
	signs, and the gates are gone: the requirement to land here lives in
	FerryConfig.Ports and is checked by FerryServer.

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
local GROUND = ISL.cleanY              -- 3.0, the same voxel band as every field

--[[
	THE ISLAND'S ANCHOR AND THE FIELD'S CENTRE ARE TWO DIFFERENT POINTS.

	Everything in this file -- the four shore radii, the bay, the headland arms,
	the pier, the plaza, the torii, every scatter ring -- is written against
	CX/CZ. That was ISL.cx/ISL.cz, which was fine while the two coincided and
	becomes a trap the moment the rakeable square moves: the whole island would
	follow it, and this island's terrain is HAND-BUILT and frozen in the place
	file, so the code would be describing a coastline that no longer exists.

	So CX/CZ is the LANDMASS, pinned at (0, 1500) by arithmetic, and FCX/FCZ is
	the SQUARE. The square grew from 96 to 192 and moved 96 north with it, which
	is what keeps its SOUTH edge at z = 1404 -- exactly where the market, the
	boardwalk, the wash bay, the car spawner and the ferryman were placed to
	stand clear of. All the growth is northward, into the open shore.

		CZ = FCZ - GROW = 1596 - 96 = 1500, for every value of GROW
]]
local FCX, FCZ = ISL.cx, ISL.cz        -- the RAKEABLE SQUARE's centre: 0, 1596
local FIELD_HALF = ISL.half            -- 192: the square is FCX/FCZ +- this
local GROW = FIELD_HALF - 96           -- how much bigger the square is than this layout was drawn for
local CX, CZ = FCX, FCZ - GROW         -- THE LANDMASS ANCHOR: 0, 1500. Frozen by construction.

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

	A player swimming north out of the beach -- which is the reason the crossing
	is allowed to be gated at all, since anyone determined can simply swim --
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

-- TRAVEL IS NOT HERE ANY MORE.
--
-- This island used to own half of a gate pair: a torii on the shore at
-- z = 1264, a second one sited along the beachfront by siteBeachGate(), and a
-- Sifter Lv.5 check in the beach one's Triggered handler. All of it has moved
-- to the ferry -- FerryConfig holds the route and the requirement (still
-- Lv.5), FerryBuilder puts a pier, a moored boat and a boatman at the foot of
-- the boardwalk, and FerryServer runs the crossing.
--
-- The one number worth carrying over: the berth occupies x +- 34, z 1206
-- .. 1284, which is what the KEEP_OUT box below reserves so the floaties do
-- not spawn inside the boat.

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
	local dx = math.max(0, math.abs(x - FCX) - FIELD_HALF)
	local dz = math.max(0, math.abs(z - FCZ) - FIELD_HALF)
	return dx * dx + dz * dz > (r + 10) * (r + 10)
end

--[[
	THE PLATEAU IS NO LONGER A CIRCLE, and every scatter loop in this file has to
	know it.

	The enlarged square reaches 288 studs north of the landmass anchor and 346 to
	its north corners, which is past the 296-stud disc this island shipped as. So
	the land BULGES NORTH: the boundary is still 296 due south and everywhere in
	the southern half -- where the bay, the arms, the pier and the market are, and
	nothing may move -- and swells to 406 due north to carry the new field with a
	margin. The exponent keeps the join smooth rather than putting a corner where
	the old circle ends.

	THIS FUNCTION IS THE CONTRACT WITH THE TERRAIN. The same curve was used to
	pour the northern land into the place file; if it is ever re-cut, both have to
	move together or the dressing walks into the sea.
]]
local LAND_R0, LAND_BULGE = 296, 110
local function landAt(x, z): (number, number)
	local dx, dz = x - CX, z - CZ
	local d = math.sqrt(dx * dx + dz * dz)
	local s = math.max(0, dz) / math.max(d, 1)
	return LAND_R0 + LAND_BULGE * s ^ 0.8, d
end

-- Is a circle of this radius wholly on dry land, eight studs clear of the surf?
local function onLand(x, z, r)
	local R, d = landAt(x, z)
	return d + (r or 0) <= R - 8
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
	{ CX - 34, CX + 34, 1206, 1284 },                                           -- the ferry pier, its arch and the moored boat
	-- The torii, and the water round it. CENTRED ON TORII_X, not on CX: it used
	-- to be written as CX +- 46 back when the torii stood on the axis, which was
	-- a latent bug the moment anything moved it -- the keep-out box would have
	-- stayed behind and the scatter would have dropped floaties through it.
	{ CX + TORII_X - 50, CX + TORII_X + 50, TORII_Z - 30, TORII_Z + 34 },
	-- The car park and the drive out of it. Both sit OUTSIDE the plaza box above,
	-- and a sakura dropped in either one is a tree in the road.
	{ CX + 68, CX + 106, 1326, 1404 },
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
	return clearOfField(x, z, r) and clearOfBuildings(x, z, r) and onLand(x, z, r)
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
--[[
	WHAT IT ASKS HAS CHANGED, BECAUSE WHAT THE FIELD IS FOR HAS CHANGED.

	It used to warn on ANY part whose extent crossed the square, on the reasoning
	that the square must be bare. That was right while the square was 192 studs
	of empty sand in the middle of the island. It is wrong now: the field is 384
	studs across and deliberately takes in the sakura groves and the rock
	formations, because four hundred studs of unbroken pink nothing is not a place
	to be, and a raked cell under a tree is a better one than a raked cell in a
	void. A test that fires on all of that is a test nobody reads.

	SO IT ASKS THE QUESTION THAT ACTUALLY BRICKS AN ISLAND. resetAt is 1.0, so a
	field turns over only when EVERY cell is raked, and a cell is unrakeable only
	if the player can never bring the tool within half a band-width of its centre.
	The sweep is pure 2D arithmetic on cell centres with NO Y term and NO collision
	query, so:

		a non-collidable part blocks nothing -- you walk through it;
		a part you can JUMP ONTO blocks nothing either -- standing on its roof
		  rakes the cell underneath exactly as standing on the sand does.

	What is left is solid geometry too tall to climb: a wall, a plinth, a shop.
	That is what this counts, and it still only REPORTS -- something genuinely
	standing in the field is a bug to fix where it was placed, and deleting it at
	boot would hide the bug and leave a hole in the island.
]]
--[[
	THREE TERMS, and each one is a different way of NOT costing a cell.

	STANDABLE  a part you can jump onto costs nothing: the sweep has no Y term,
	           so raking from on top of a boulder marks the column under it.
	SHADOW     the band reaches 3 studs either side of a point 4.6 ahead of the
	           character, so anything narrower than about six studs can simply
	           be walked around. A parasol pole is 0.5 across.
	GROUNDED   a roof, a canopy or a torii crossbar is high, wide and completely
	           harmless -- you walk underneath it. Only something whose foot is
	           ON the sand can keep a character away from what is beneath it.

	All three have to hold before this says a word. It remains a HEURISTIC and it
	says so: the authoritative test is whether a character can stand within reach
	of every cell centre, which needs a flood fill over the finished world and is
	not something to run at boot on every server.
]]
local STANDABLE = 8       -- studs above the sand a character can jump onto and stand on
local SHADOW = 6          -- studs of footprint, below which a cell can be reached around
local GROUNDED = 4        -- studs of clearance under it, above which you walk underneath

local function assertClearOfField(root: Instance): number
	local inside, blocking, first = 0, 0, nil
	for _, p in ipairs(root:GetDescendants()) do
		if p:IsA("BasePart") then
			local cf, s = p.CFrame, p.Size
			local rx, ux, lx = cf.RightVector, cf.UpVector, cf.LookVector
			local ex = math.abs(rx.X) * s.X * 0.5 + math.abs(ux.X) * s.Y * 0.5 + math.abs(lx.X) * s.Z * 0.5
			local ez = math.abs(rx.Z) * s.X * 0.5 + math.abs(ux.Z) * s.Y * 0.5 + math.abs(lx.Z) * s.Z * 0.5
			if math.abs(cf.X - FCX) - ex < FIELD_HALF and math.abs(cf.Z - FCZ) - ez < FIELD_HALF then
				inside += 1
				local ey = math.abs(rx.Y) * s.X * 0.5 + math.abs(ux.Y) * s.Y * 0.5 + math.abs(lx.Y) * s.Z * 0.5
				if p.CanCollide and p.Transparency < 1
					and (cf.Y + ey) > GROUND + STANDABLE
					and math.min(ex, ez) * 2 > SHADOW
					and (cf.Y - ey) < GROUND + GROUNDED then
					blocking += 1
					first = first or p:GetFullName()
				end
			end
		end
	end
	if blocking > 0 then
		warn(string.format(
			"[Cove] %d solid part(s) too tall to stand on are INSIDE the rakeable square "
			.. "(%d parts of any kind are) -- a cell nobody can reach never lets this field "
			.. "turn over. First: %s", blocking, inside, first))
	end
	return blocking
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
	--
	-- IT SAYS WHAT THE STALL DOES, NOT WHAT IT IS CALLED. "KAKIGORI" is the
	-- flavour name and it told a player nothing about the one thing this stall
	-- is for. The dune market's two marquees went the same way (SELL and
	-- UPGRADES) and this is the cove's half of that pass -- one word, same word,
	-- so the two islands teach the same vocabulary. The stall is still a shaved
	-- ice cart in every other respect; only the sign is doing a job.
	local board = box(m, "ShopBoard", cx - 11, cx + 11, G + 9.4, G + 13.4, cz - 9.6, cz - 9.2,
		PALETTE.cream, Enum.Material.SmoothPlastic)
	if board then
		SignKit.dress(board, "UPGRADES", { Enum.NormalId.Front, Enum.NormalId.Back })
	end
	for _, s in ipairs({ -1, 1 }) do
		box(m, "BoardPost", cx + s * 11 - 0.5, cx + s * 11 + 0.5, G + 0.42, G + 13.4,
			cz - 9.7, cz - 9.1, PALETTE.timberDeep, Enum.Material.Wood)
	end

	return m
end

--[[
	THE SHRINE PRECINCT, RE-PLANNED AROUND HOW THE LOOP ACTUALLY MOVES.

	The cove's four services still map onto a real jinja almost one for one, and
	that is still the reason to lay it out this way rather than only dress it:

		temizuya    the roofed basin you purify at       ->  the WASH BAY
		juyosho     the counter that sells charms        ->  the UPGRADE shop
		kagura-den  the open stage offerings are made on ->  the CAR pad
		haiden      the hall you make an offering at     ->  the SELL pad

	THE FIRST CUT PUT THE HAIDEN AT THE HEAD OF THE SANDO. That is correct for a
	shrine and wrong for this island, and the reason is one sentence: A REAL
	PRECINCT IS A DEAD END. You walk in, you make the offering, you walk back out
	the way you came. The cove is not a dead end -- the rakeable field is on the
	FAR SIDE of this square, at z >= 1404 -- so the hall's back wall stood square
	across the only route between the sand and the scales. Coming off the field
	with a full bag you could see the pad over the roof and had to walk around
	thirty-eight studs of building to reach it.

	The car pad had the mirror image of the same bug, and it is the one that made
	somebody say something: it pointed +Z with the wash bay twenty-three studs
	dead ahead, so the first thing a new quad did was drive into a shed.

	SO THE AXIS IS A THROUGH-ROUTE NOW AND THE SERVICES ARE ON THE FLANKS.

		* The SANDO runs unbroken from the market gate at z = 1330 out onto the sand
		  at SANDO_Z1, through a new back gate at z = 1390, with the north kerb
		  broken to let it out. Nothing may stand in x [-15, 15] over that whole run:
		  it is the walk home, the sifter lane and the drive line at once.
		* The HAIDEN turns to face EAST and moves to the west flank with the sell pad
		  in front of it. Off the field you see the pad the moment you clear the back
		  gate; up the sando you turn left at the komainu. A sando that doglegs
		  before the hall is ordinary at a real shrine, and it is what buys the
		  through-route here.
		* TEMIZUYA and JUYOSHO share the east flank -- wash to the NORTH where the
		  field traffic is, shop to the SOUTH where the arriving traffic is -- both
		  facing west across the sando at the hall.
		* The KAGURA-DEN and its pad move OUTSIDE the east kerb and turn to face the
		  field. From the bay mouth there are forty studs of open sand in front of
		  them and nothing in it. That is the whole of the fix: spawn, hold W, you
		  are on the beach.

	THE CENTRE OF THE SANDO STAYS EMPTY. Same shrine rule as before, now carrying
	more weight, so every lantern, banner and rack sits at |x| >= 19.

	NOTHING REACHES z = 1404. assertClearOfField measures real extents, so the two
	thin things that run that far north -- the sando slab and the car park's drive
	-- both stop at SANDO_Z1 and clear the square by four studs rather than by
	luck. Move either one north and the island reports itself broken at boot.
]]
--[[
	THE EAST FLANK IS TWO BUILDINGS ON A SIXTY-FOUR STUD STRIP, AND THE GAP
	BETWEEN THEM IS A ROUTE, NOT A LEFTOVER.

	The stall is 31 studs deep in z and the wash bay 16, which leaves seventeen
	for the lane between them and the two margins either side. Sited by eye they
	came out 4.6 apart, and the only way from the sando to the car park was to
	walk the length of the plaza, round the far side of the wash bay and back
	down -- eighty studs to cross twenty. So the three z values below are set
	AGAINST EACH OTHER rather than one at a time:

	  stall  1330.4 .. 1361.6      hard against the south kerb
	  LANE   1361.6 .. 1371.2      9.6 clear studs, sando to kerb gap
	  bay    1371.2 .. 1386.8      seven clear of the north kerb

	and CARPARK_Z0/Z1 brackets the lane so the break in the kerb is at the end
	of it. Move any one of the three and re-derive the other two.
]]
local TEMIZUYA = Vector3.new(CX + 54, GROUND, 1379)
-- 44 rather than 48: the stall is 31 studs deep in z and 23 across, so where it
-- sits decides the width of the ALLEY between it and the east kerb, which is the
-- walk out to the car park. Four studs west turns a 13-stud gap into a 17-stud
-- one and costs nothing on the sando side, which had 23 to spare.
local JUYOSHO = Vector3.new(CX + 44, GROUND, 1346)
local KAGURA = Vector3.new(CX + 86, GROUND, 1365)
local HAIDEN = Vector3.new(CX - 58, GROUND, 1362)
-- No SELL any more. The pad used to be its own place in the plaza and needed a
-- coordinate; it is the haiden's floor now, so everything about it -- the mat,
-- the steps, the branch that leads to them and the plaque over the opening --
-- is measured off HAIDEN and the hall's own HX/HZ bounds. A second constant
-- naming "where the pad is" would be a second answer to a question that now
-- has one.
-- The spine, and the two breaks in the kerb that let it and the car park out.
local SANDO_Z1 = 1400                       -- the sando runs on out over the sand
local NORTH_GAP = 17                        -- break in the north kerb, either side of CX
local CARPARK_Z0, CARPARK_Z1 = 1352, 1378   -- break in the east kerb, on the lane

-- A lion-dog. Cute rather than fierce, because everything else in this cove is:
-- a round head, a stub snout and two big ears on a plinth reads as a guardian at
-- ten studs and as a cat at three, which is the note the island is written in.
-- CURRENTLY UNCALLED -- see the note where the pair used to be placed, just past
-- the market gate. Kept for the same reason emaRack is.
local function komainu(parent, x: number, z: number, facing: number, mouthOpen: boolean)
	local m = Instance.new("Model")
	m.Name = "Komainu"
	m.Parent = parent
	local base = CFrame.new(x, GROUND, z) * CFrame.Angles(0, facing, 0)
	local function b(name, sx, sy, sz, ox, oy, oz, colour, mat, extra)
		return lp(m, name, base, Vector3.new(sx, sy, sz), CFrame.new(ox, oy, oz),
			colour, mat or Enum.Material.Concrete, extra)
	end
	b("Plinth", 4.4, 2.6, 4.0, 0, 1.3, 0, PALETTE.stoneDeep)
	b("PlinthCap", 5.0, 0.5, 4.6, 0, 2.75, 0, PALETTE.cream)
	b("Haunch", 2.9, 2.4, 3.4, 0, 4.2, 0.3, PALETTE.stone)
	b("Chest", 2.6, 2.2, 2.2, 0, 5.1, -1.1, PALETTE.stone)
	b("Head", 2.6, 2.4, 2.4, 0, 6.9, -1.3, PALETTE.stone)
	b("Snout", 1.3, 1.0, 1.1, 0, 6.5, -2.6, PALETTE.cream)
	-- The pair is a-gyo and un-gyo -- mouth open, mouth shut, the first and last
	-- sounds. It is the one detail that says these two are not the same statue.
	if mouthOpen then
		b("Mouth", 0.9, 0.5, 0.4, 0, 6.15, -3.0, PALETTE.plum, Enum.Material.SmoothPlastic,
			{ CanCollide = false })
	end
	for _, s in ipairs({ -1, 1 }) do
		b("Ear", 0.9, 1.5, 0.7, s * 1.0, 8.2, -1.1, PALETTE.stone)
		b("Eye", 0.42, 0.42, 0.3, s * 0.72, 7.1, -2.45, PALETTE.plum,
			Enum.Material.SmoothPlastic, { CanCollide = false })
		b("Paw", 1.0, 1.1, 1.8, s * 0.85, 3.55, -1.9, PALETTE.stone)
	end
	b("Tail", 1.0, 3.0, 1.0, 0, 5.6, 1.9, PALETTE.stone)
	-- The red bib half the guardian statues in Japan are wearing.
	b("Bib", 2.4, 1.4, 0.4, 0, 5.2, -2.3, PALETTE.vermilion, Enum.Material.SmoothPlastic,
		{ CanCollide = false })
	return m
end

-- Sacred rope and its folded paper streamers, hung across anything that wants
-- marking as the far side of a boundary.
local function shimenawa(parent, x0: number, x1: number, y: number, z: number, shides: number)
	box(parent, "Shimenawa", x0, x1, y, y + 1.4, z - 0.7, z + 0.7,
		Color3.fromRGB(238, 226, 196), Enum.Material.Fabric, { CanCollide = false })
	for i = 1, shides do
		local sx = x0 + (x1 - x0) * (i / (shides + 1))
		-- shide are folded zigzags; three offset tabs is the readable version of
		-- that at this size
		for k = 0, 2 do
			box(parent, "Shide", sx - 0.7 + k * 0.25, sx + 0.5 + k * 0.25,
				y - 0.7 - k * 0.7, y - k * 0.7, z - 0.12, z + 0.12,
				PALETTE.cream, Enum.Material.SmoothPlastic, { CanCollide = false })
		end
	end
end

-- The same rope, hung across a face that runs along Z rather than X. The haiden
-- turned ninety degrees when the precinct was re-planned and its opening faces
-- east now; threading an axis argument through the X version would have made
-- every existing call site read worse than a second five-line helper does.
local function shimenawaZ(parent, z0: number, z1: number, y: number, x: number, shides: number)
	box(parent, "Shimenawa", x - 0.7, x + 0.7, y, y + 1.4, z0, z1,
		Color3.fromRGB(238, 226, 196), Enum.Material.Fabric, { CanCollide = false })
	for i = 1, shides do
		local sz = z0 + (z1 - z0) * (i / (shides + 1))
		for k = 0, 2 do
			box(parent, "Shide", x - 0.12, x + 0.12,
				y - 0.7 - k * 0.7, y - k * 0.7, sz - 0.7 + k * 0.25, sz + 0.5 + k * 0.25,
				PALETTE.cream, Enum.Material.SmoothPlastic, { CanCollide = false })
		end
	end
end

-- A nobori: the tall narrow banner shrines line their approaches with, held out
-- flat by a cross-rod so the field always faces you.
local function nobori(parent, x: number, z: number, colour: Color3)
	local G = GROUND
	box(parent, "NoboriPole", x - 0.22, x + 0.22, G, G + 13, z - 0.22, z + 0.22,
		PALETTE.timberDeep, Enum.Material.Wood)
	box(parent, "NoboriArm", x - 0.2, x + 4.2, G + 12.3, G + 12.7, z - 0.18, z + 0.18,
		PALETTE.timberDeep, Enum.Material.Wood, { CanCollide = false })
	box(parent, "NoboriCloth", x + 0.3, x + 4.1, G + 4.2, G + 12.3, z - 0.1, z + 0.1,
		colour, Enum.Material.Fabric, { CanCollide = false })
	box(parent, "NoboriBand", x + 0.3, x + 4.1, G + 10.9, G + 11.5, z - 0.14, z + 0.14,
		PALETTE.cream, Enum.Material.Fabric, { CanCollide = false })
end

-- The rack wish-plaques hang on, and the one fortunes get knotted to.
-- CURRENTLY UNCALLED, and deliberately so -- see the note at the north gate for
-- where the pair used to stand and why it cannot stand there. Kept because the
-- prop is fine and only its address was wrong.
local function emaRack(parent, x: number, z: number, tie: boolean)
	local G = GROUND
	local m = Instance.new("Model")
	m.Name = tie and "OmikujiRack" or "EmaKake"
	m.Parent = parent
	for _, s in ipairs({ -1, 1 }) do
		box(m, "Post", x + s * 4.2 - 0.35, x + s * 4.2 + 0.35, G, G + 6.2,
			z - 0.35, z + 0.35, PALETTE.timberDeep, Enum.Material.Wood)
	end
	box(m, "Rail", x - 4.8, x + 4.8, G + 5.4, G + 5.9, z - 0.3, z + 0.3,
		PALETTE.timberDeep, Enum.Material.Wood)
	box(m, "Roof", x - 5.4, x + 5.4, G + 6.2, G + 6.7, z - 1.5, z + 1.5,
		PALETTE.vermilionDeep, Enum.Material.SmoothPlastic, { CanCollide = false })
	if tie then
		-- omikuji: folded paper strips knotted to the rail in a white row, which is
		-- what a fortune rack looks like from any distance at all
		for i = 0, 11 do
			local px = x - 4.4 + i * 0.8
			box(m, "Fortune", px - 0.13, px + 0.13, G + 4.0, G + 5.4, z - 0.1, z + 0.1,
				PALETTE.cream, Enum.Material.SmoothPlastic, { CanCollide = false })
		end
	else
		-- ema: little wooden wish-plaques, hung in two ranks
		local tints = { PALETTE.blossom, PALETTE.cream, PALETTE.mint, PALETTE.lantern }
		for i = 0, 7 do
			local px = x - 4.0 + i * 1.15
			local row = (i % 2 == 0) and 0 or 1.5
			box(m, "Ema", px - 0.5, px + 0.5, G + 3.4 - row, G + 4.6 - row, z - 0.12, z + 0.12,
				tints[(i % #tints) + 1], Enum.Material.SmoothPlastic, { CanCollide = false })
			box(m, "EmaCord", px - 0.06, px + 0.06, G + 4.6 - row, G + 5.4, z - 0.08, z + 0.08,
				PALETTE.vermilion, Enum.Material.SmoothPlastic, { CanCollide = false })
		end
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
	-- The WEST kerb runs the whole depth. The EAST one is BROKEN over the car
	-- park, so walking out to the machines is a gap in an edge rather than a step
	-- over one -- the same call the boardwalk break below makes, for the same
	-- reason and with the same shape of code.
	box(m, "Kerb", X0 - 1.3, X0 + 1.3, G + 0.12, G + 0.8, PLAZA_Z0, PLAZA_Z1,
		PALETTE.blossomDeep, Enum.Material.Concrete)
	for _, run in ipairs({ { PLAZA_Z0, CARPARK_Z0 }, { CARPARK_Z1, PLAZA_Z1 } }) do
		box(m, "Kerb", X1 - 1.3, X1 + 1.3, G + 0.12, G + 0.8, run[1], run[2],
			PALETTE.blossomDeep, Enum.Material.Concrete)
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
	--
	-- IT IS BROKEN ON THE AXIS NOW. The sando runs out through here to the field,
	-- and a 0.68 lip across the one lane a machine drives is exactly the thing
	-- the boardwalk's own note swore off.
	for _, run in ipairs({ { X0, CX - NORTH_GAP }, { CX + NORTH_GAP, X1 } }) do
		box(m, "KerbNorth", run[1], run[2], G + 0.12, G + 0.8, PLAZA_Z1 - 1.3, PLAZA_Z1 + 1.3,
			PALETTE.blossomDeep, Enum.Material.Concrete)
	end

	--[[
		THE HAIDEN, AND THE SELL PAD ON ITS FLOOR.

		A haiden is a hall you stand AT and make an offering in. Until now this one
		was a hall you stood NEXT TO, with the offering happening on the paving
		outside it: the pad sat in the forecourt under a notice board and the hall
		behind was scenery -- thirty-four studs of vermilion and slate the player
		never had a reason to walk into. The saisenbako, the bell and the rope were
		all up there being used by nobody.

		SO THE PAD IS THE HALL FLOOR NOW. You climb the steps, duck under the
		shimenawa, ring the suzu and stand on the mat with the offertory box in
		front of you -- which is the sequence a real visitor performs, and it is
		also, exactly, "walk onto the pad and sell". The two were always the same
		gesture; they were just twenty-five studs apart.

		CTB_Server DOES NOT CARE THAT THE PAD IS 1.7 STUDS UP, and that is the
		property that made this a geometry change and nothing else. Its test is
		`pad.CFrame:PointToObjectSpace(hrp.Position)` against the pad's own Size
		with a nine-stud vertical tolerance, so a pad on a deck, on a slope or on
		its side would all still pay out.

		HX IS THE DEPTH (15) AND HZ THE WIDTH (34) -- the building faces EAST, and
		anything added here has to be read in those terms or it comes out lying on
		its side. The open front is HX1.
	]]
	local HX0, HX1 = HAIDEN.X - 7, HAIDEN.X + 8
	local HZ0, HZ1 = HAIDEN.Z - 17, HAIDEN.Z + 17
	-- The hall floor. The pad, the offertory box and the top step are all measured
	-- from this one number rather than from G, so raising the deck moves them all.
	local DECK = G + 1.7

	box(m, "HaidenPlinth", HX0 - 1.6, HX1 + 1.6, G - 0.5, G + 1.1, HZ0 - 1.6, HZ1 + 1.6,
		PALETTE.stoneDeep, Enum.Material.Concrete)
	box(m, "HaidenDeck", HX0, HX1, G + 1.1, DECK, HZ0, HZ1,
		PALETTE.timber, Enum.Material.WoodPlanks)
	box(m, "HaidenBack", HX0, HX0 + 0.7, DECK, G + 12, HZ0, HZ1,
		PALETTE.vermilion, Enum.Material.SmoothPlastic)
	for _, s in ipairs({ -1, 1 }) do
		box(m, "HaidenWall", HX0, HX1, DECK, G + 12,
			(s < 0) and HZ0 or (HZ1 - 0.7), (s < 0) and (HZ0 + 0.7) or HZ1,
			PALETTE.vermilion, Enum.Material.SmoothPlastic)
		box(m, "HaidenPost", HX1 - 1.3, HX1 + 0.3, DECK, G + 12,
			HAIDEN.Z + s * 15 - 0.8, HAIDEN.Z + s * 15 + 0.8,
			PALETTE.vermilionDeep, Enum.Material.SmoothPlastic)
	end
	-- A gabled roof in two rakes, deep-eaved and dark, which is the silhouette
	-- that says shrine from across the plaza. The ridge runs along the WIDTH, so
	-- with the building turned it is the DEPTH that takes the 3.1 rake and the
	-- width that takes the 0.5 step.
	for i = 0, 4 do
		local inset = i * 3.1
		box(m, "HaidenRoof" .. i, HX0 - 4 + inset, HX1 + 4 - inset,
			G + 12 + i * 1.25, G + 13.25 + i * 1.25,
			HZ0 - 4 + i * 0.5, HZ1 + 4 - i * 0.5,
			(i == 0) and PALETTE.plum or PALETTE.stoneDeep, Enum.Material.Slate,
			{ CanCollide = false })
	end
	box(m, "HaidenRidge", HAIDEN.X - 1.2, HAIDEN.X + 1.2, G + 17.9, G + 19,
		HZ0 - 3, HZ1 + 3, PALETTE.vermilionDeep, Enum.Material.SmoothPlastic,
		{ CanCollide = false })
	-- katsuogi: the short billets laid across a shrine ridge
	for i = -2, 2 do
		box(m, "Katsuogi", HAIDEN.X - 2.2, HAIDEN.X + 2.2, G + 19, G + 20.3,
			HAIDEN.Z + i * 6 - 0.9, HAIDEN.Z + i * 6 + 0.9, PALETTE.lantern,
			Enum.Material.Wood, { CanCollide = false })
	end

	shimenawaZ(m, HZ0 + 2, HZ1 - 2, G + 9.6, HX1 - 0.2, 4)
	--[[
		THE BELL, and it is 0.45 SQUARE rather than 0.8.

		The suzuo used to run the full height of the opening at 0.8 square in
		vermilionDeep, which from the forecourt is a red bar from the roof to the
		deck straight down the middle of the hall -- it read as a structural post
		holding the building up, and the bell was lost above the plaque. Thinner,
		and stopped where the bell is, it reads as a cord with a bell on the end,
		which is what it is.
	]]
	box(m, "SuzuRope", HX1 - 0.72, HX1 - 0.27, G + 3.4, G + 8.0,
		HAIDEN.Z - 0.22, HAIDEN.Z + 0.22, PALETTE.vermilionDeep, Enum.Material.Fabric,
		{ CanCollide = false })
	P(m, "Suzu", Vector3.new(2.0, 2.2, 2.0), CFrame.new(HX1 - 0.5, G + 8.0, HAIDEN.Z),
		PALETTE.lantern, Enum.Material.Metal, { CanCollide = false })

	--[[
		THE SAISENBAKO, MOVED TO THE BACK WALL.

		It used to straddle the front lip, which is where you drop a coin in from
		the path -- correct for a hall nobody goes into, and directly in the way of
		one you walk into. Against the back wall it becomes what you FACE while
		stood on the mat, which is what an offertory box is for, and the front of
		the hall is left open to walk through.
	]]
	box(m, "Saisenbako", HX0 + 0.7, HX0 + 3.7, DECK, DECK + 2.5,
		HAIDEN.Z - 5, HAIDEN.Z + 5, PALETTE.timberDeep, Enum.Material.Wood)
	for i = 0, 6 do
		local sz = HAIDEN.Z - 4.4 + i * 1.5
		box(m, "SaisenSlat", HX0 + 0.7, HX0 + 3.7, DECK + 2.5, DECK + 2.75,
			sz - 0.45, sz + 0.45, PALETTE.plum, Enum.Material.Wood, { CanCollide = false })
	end

	--[[
		THE STEPS, which the hall did without for as long as nothing up there
		mattered. The plinth already lifts to G + 1.1 and the deck to G + 1.7, so
		from the paving that was one 1.1 riser and one 0.6 -- walkable, and walkable
		is not the same as READS AS A WAY IN. One stone tread at G + 0.6 makes it
		three even risers and, more to the point, a flight pointing at the opening.
	]]
	box(m, "HaidenStep", HX1 + 1.6, HX1 + 4.6, G - 0.5, G + 0.6,
		HAIDEN.Z - 7, HAIDEN.Z + 7, PALETTE.stoneDeep, Enum.Material.Concrete)
	box(m, "HaidenStepCap", HX1 + 1.4, HX1 + 4.8, G + 0.55, G + 0.68,
		HAIDEN.Z - 7.2, HAIDEN.Z + 7.2, PALETTE.stone, Enum.Material.Concrete,
		{ CanCollide = false })

	--[[
		THE SELL PAD. Three courses, not one slab.

		Same behaviour as the beach's -- CTB_Server tests every pad in its list
		against the player's position, so standing on this one sells exactly as that
		one does, and this is the part that must come back out of build().

		It keeps the dark frame the dunes' has, for the same reason: a warm mat on a
		warm timber deck is the same VALUE as the deck and disappears without an
		edge under it.

		THINNER THAN THE OTHER TWO, because it is on a floor rather than in one.
		0.22 / 0.18 / 0.30 comes to 0.57 above the deck -- a mat you step onto, not
		a kerb you climb. The three courses overlap by a couple of hundredths so
		there is no hairline of deck showing between them at a grazing angle.

		SET 0.9 TOWARD THE FRONT of the hall's centre line, which is what leaves the
		offertory box its own strip of floor against the back wall.
	]]
	local padX, padZ = HAIDEN.X + 0.9, HAIDEN.Z
	P(m, "PadFrame", Vector3.new(11.4, 0.22, 23.4),
		CFrame.new(padX, DECK + 0.11, padZ), PALETTE.plum, Enum.Material.Concrete,
		{ CanCollide = false })
	-- Neon at Transparency 0 (see the header). The glow course is a solid slab
	-- of a dimmed colour rather than a translucent bright one, which is the
	-- only way Neon reads as light under Future lighting.
	P(m, "PadGlow", Vector3.new(10.0, 0.18, 21.4),
		CFrame.new(padX, DECK + 0.26, padZ), Color3.fromRGB(255, 176, 198), Enum.Material.Neon,
		{ CanCollide = false })
	local pad = P(m, "SellPad", Vector3.new(9, 0.30, 20),
		CFrame.new(padX, DECK + 0.42, padZ), PALETTE.blossom, Enum.Material.SmoothPlastic)

	--[[
		THE LETTERING IS A GAKU NOW, NOT A BOARD IN THE FORECOURT.

		A name plaque hung on the frame is how a real hall is labelled, and here it
		is also the only place the lettering can go. Both freestanding positions
		were tried and both failed the same way: a fifteen-stud board at the foot of
		the steps stands square across the opening from anywhere on the branch and
		hides the pad, the box and the bell -- which is EXACTLY the fault the old
		20 x 3.2 board was shrunk to fix, walked straight back into the moment the
		pad went indoors and there was something behind it worth seeing.

		Hung under the roof's overhang it sits above the head of the opening: it
		labels the hall from the whole plaza and blocks nothing, because there is
		nothing to block up there.
	]]
	local padSign = box(m, "PadBoard", HX1 + 2.6, HX1 + 3.0, G + 9.8, G + 12.0,
		HAIDEN.Z - 7, HAIDEN.Z + 7, PALETTE.cream, Enum.Material.SmoothPlastic,
		{ CanCollide = false })
	if padSign then
		SignKit.dress(padSign, "SELL YOUR FINDS", { Enum.NormalId.Right, Enum.NormalId.Left })
	end
	box(m, "PadBoardTrim", HX1 + 2.5, HX1 + 3.1, G + 12.0, G + 12.45,
		HAIDEN.Z - 7.4, HAIDEN.Z + 7.4, PALETTE.vermilionDeep, Enum.Material.SmoothPlastic,
		{ CanCollide = false })
	for _, s in ipairs({ -1, 1 }) do
		box(m, "PadBoardHanger", HX1 + 2.7, HX1 + 2.9, G + 12.0, G + 13.6,
			HAIDEN.Z + s * 5.4 - 0.16, HAIDEN.Z + s * 5.4 + 0.16,
			PALETTE.timberDeep, Enum.Material.Wood, { CanCollide = false })
	end

	-- Chochin INSIDE. The roof shades the whole interior and the pad's own glow
	-- was the only light in the thing the player now walks into.
	for _, s in ipairs({ -1, 1 }) do
		prop("paperLantern", m, CFrame.new(HAIDEN.X + 3.5, G + 10.6, HAIDEN.Z + s * 9), 1)
	end
	--[[
		NO TORO ON THE FLIGHT. A pair either side of the steps is what a shrine
		puts there, and it was the right instinct for the wrong ten studs: HX1 + 7
		is x = -22 and the branch runs out to x = -13, so the two of them stood ON
		the lane rather than beside it and took six studs each off the only way in
		to the pad. Measured with a character-sized probe the walk-in was nine
		studs clear at its worst and is twenty-three without them.

		The paper pair on the same steps (below) does the lighting job from the
		eaves, where there is nothing to stand in.
	]]

	--[[
		THE JUYOSHO -- the counter that hands things out, which on this island is
		the kakigori pitch and its ShopPrompt.
	
		It moved to the EAST flank when the haiden took the west one, and it sits at
		the SOUTH end of that flank on purpose: the shop is the one service nobody
		is ever in a hurry for, so it goes where the ARRIVING traffic is rather than
		where the field traffic is. It still faces across the sando at the other
		flank, which is the arrangement that stops two buildings both staring down
		the path -- just mirrored.
	
		Rotated as one pivot on the finished model: buildKakigoriPitch bakes a south
		facing into forty box() calls and threading a yaw through all of them to turn
		one stall would be the wrong trade. +90 where the old west-side placement
		used -90, which is what puts the counter, its board and its prompt on the
		sando side rather than against the kerb.
	]]
	local shop = buildKakigoriPitch(m, JUYOSHO.X, JUYOSHO.Z)
	if shop then
		shop:PivotTo(CFrame.new(JUYOSHO.X, GROUND, JUYOSHO.Z)
			* CFrame.Angles(0, math.pi * 0.5, 0)
			* CFrame.new(-JUYOSHO.X, -GROUND, -JUYOSHO.Z)
			* shop:GetPivot())
	end

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
	-- Moved off the north edge and down onto the APPROACH. They used to stand in
	-- a rank at z = 1386, which is now the middle of the haiden -- and a vending
	-- corner belongs outside the gate anyway, where you pass it on the way in.
	local vends = 0
	for _, v in ipairs({
		{ CX - 52, 1320, "sakura" },
		{ CX - 44, 1320, "melon" },
		{ CX - 36, 1320, "ramune" },
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

	----------------------------------------------------------------
	-- THE APPROACH, outside the gate
	----------------------------------------------------------------
	-- Apron paving so the walk from the boardwalk to the torii is a made path
	-- rather than a stretch of sand with a gate at the end of it.
	box(m, "Apron", CX - 34, CX + 34, G - 0.5, G + 0.12, 1300, PLAZA_Z0,
		PALETTE.stone, Enum.Material.Concrete)

	-- The OUTER torii. Smaller than the plaza's own gate, which is smaller again
	-- than the great torii on the shore -- sanctity rises as you walk in, and a
	-- shrine says so by making each gate grander than the last.
	buildTorii(m, "OuterTorii", CFrame.new(CX, G + 0.12, 1308),
		{ h = 11, span = 21, dia = 1.5, over = 4, lean = 0.03, rise = 1.6, segs = 7 })

	for _, z in ipairs({ 1316, 1326 }) do
		nobori(m, CX - 30, z, PALETTE.vermilion)
		nobori(m, CX + 26, z, PALETTE.vermilion)
	end

	----------------------------------------------------------------
	-- THE SANDO, and the branch that doglegs west to the hall
	----------------------------------------------------------------
	-- A paler lane straight up the middle. IT NOW RUNS THE WHOLE DEPTH of the
	-- plaza and six studs out onto the sand past the back gate, where it used to
	-- stop dead at the sell pad. It is the one piece of paving nothing is allowed
	-- to stand on, and that rule is now doing three jobs at once: the shrine one
	-- (the middle of the path belongs to the kami and people walk up the sides),
	-- the clear lane for a player dragging a sixteen-stud sifter, and the line a
	-- machine takes off the pad. Same twenty-six studs, three reasons.
	box(m, "Sando", CX - 13, CX + 13, G + 0.12, G + 0.2, PLAZA_Z0, SANDO_Z1,
		PALETTE.cream, Enum.Material.Concrete, { CanCollide = false })
	for _, s in ipairs({ -1, 1 }) do
		box(m, "SandoEdge", CX + s * 13 - 0.5, CX + s * 13 + 0.5, G + 0.12, G + 0.32,
			PLAZA_Z0, SANDO_Z1, PALETTE.blossomDeep, Enum.Material.Concrete,
			{ CanCollide = false })
	end
	-- THE BRANCH -- the dogleg west to the hall and its pad. Nine studs of the
	-- same cream, which is what makes the turn read as part of the approach
	-- rather than as stepping off it.
	-- It runs all the way to the bottom step now rather than stopping where the
	-- pad used to be: with the pad indoors the branch's job is to deliver you to
	-- the flight, and paving that gives up nine studs short of it reads as having
	-- forgotten what it was for.
	box(m, "SandoBranch", HAIDEN.X + 12.6, CX - 13, G + 0.12, G + 0.2,
		HAIDEN.Z - 10, HAIDEN.Z + 10,
		PALETTE.cream, Enum.Material.Concrete, { CanCollide = false })
	for _, s in ipairs({ -1, 1 }) do
		box(m, "SandoBranchEdge", HAIDEN.X + 12.6, CX - 13, G + 0.12, G + 0.32,
			HAIDEN.Z + s * 10 - 0.5, HAIDEN.Z + s * 10 + 0.5, PALETTE.blossomDeep,
			Enum.Material.Concrete, { CanCollide = false })
	end
	
	--[[
		NO KOMAINU. |x| = 20, z = 1344 is the sando's shoulder, which is why they
		went there -- but it is only a shoulder if you are walking the sando. It is
		a DOORWAY if you are doing either of the things this plaza is for: the west
		one blocked x -24..-16 square across the branch to the sell hall, and the
		east one stood between the sando and the kakigori counter you walk to it to
		reach. One footprint, two services, both approaches.

		ServiceClearance had already softened the east one to walk-through, which
		is the worse of the two states rather than a fix: the statue still hides
		the counter, and now you clip through it getting there.
	]]
	
	--[[
		Stone lanterns BRACKETING the sando instead of marching up it. Two ranks at
		|x| = 21 was right when the lane was thirty studs long and empty either
		side; the branch and the pad frame now reach x = -21.8, so half the west
		rank would have been standing in the road.

		ONE RANK, NOT TWO, and the surviving one is the SOUTH one. z = 1386 is
		level with the wash bay's door and with the car pad's mouth, so at |x| = 19
		that pair pinched both of those approaches at once -- the walk in to the
		car pad measured thirteen studs with it standing and eighteen without.
		z = 1336 is level with nothing but the gate, so it stays, and one rank
		inside the gate says "approach" as clearly as two did.
	]]
	for _, z in ipairs({ 1336 }) do
		for _, s in ipairs({ -1, 1 }) do
			prop("stoneLantern", m, CFrame.new(CX + s * 19, G + 0.12, z), 1)
		end
	end
	-- and a pair of paper ones on the haiden's own steps, which is where the warm
	-- light wants to be at golden hour
	for _, s in ipairs({ -1, 1 }) do
		prop("paperLantern", m, CFrame.new(HAIDEN.X + 8.4, G + 7.5, HAIDEN.Z + s * 13), 1)
	end
	
	nobori(m, CX - 30, 1340, PALETTE.blossomDeep)
	nobori(m, CX + 26, 1340, PALETTE.blossomDeep)
	
	--[[
		THE BACK GATE. An ura-torii: the second approach a shrine keeps for the
		people who come at it from behind, which on this island is everybody, every
		trip, with a full bag.
	
		Smaller than the market gate it answers, because sanctity rises INWARD and a
		back approach is the humbler one -- and because it has a job the other two
		gates do not. From out on the field the plaza is a low pink line with three
		roofs on it; this is the one shape that says WHERE IT OPENS. The north kerb
		is broken either side of it for the same reason the south one is broken for
		the boardwalk.
	]]
	buildTorii(m, "NorthTorii", CFrame.new(CX, G + 0.12, 1390),
		{ h = 12, span = 28, dia = 1.6, over = 4.2, lean = 0.03, rise = 1.8, segs = 8 })
	
	--[[
		NO EMA OR OMIKUJI RACKS ON THIS LINE. Wishes west and fortunes east at
		z = 1390 got them off the sell pad, which is what that move was for, and
		set them down on the other two services instead: z = 1390 is also the wash
		bay's north wall and the car bay's MOUTH.

		The omikuji rack was the bad one, and it is worth writing down what it
		actually was rather than that it "was in the way". A rack is two posts and
		a rail: posts at x 25.8 and 34.2, inside a bay whose kerbs are at 28.3 and
		43.7, with the rail across them at y 8.4. That is a gate-bar hung over the
		lane a quad drives out of, and it left eight studs of a sixteen-stud
		opening. Its west twin was the same shape against the temizuya.

		emaRack() is kept below on purpose -- it is a good prop and the plaza may
		want it back. Wherever it goes it has to be clear of a service apron, and
		ServiceClearance names whatever is standing in one at every boot.
	]]

	----------------------------------------------------------------
	-- THE TEMIZUYA  --  the wash bay, east flank, NORTH end
	----------------------------------------------------------------
	--[[
		A CLONE OF THE AUTHORED BEACH SHACK, the same way the dunes' is: that model
		is the one WashServer knows how to bind (it carries the tag and a part named
		Stand), and cloning it means all three islands stay one building rather than
		three that drift.
	
		Turned to face -X, across the sando. Placed by its BOUNDING BOX rather than
		its pivot -- the authored model's pivot sits above its own underside, which
		is a fact about how somebody saved it rather than anything to build against.
	
		AT THE NORTH END OF ITS FLANK, and that is a traffic decision rather than a
		shrine one. Purification belongs near the entrance at a real jinja; here the
		entrance that matters is the FIELD, because a crusted find arrives from the
		sand and not from the ferry. So the wash bay takes the corner nearest the
		sand and the shop, which nobody is ever in a hurry for, takes the far end.
	]]
	local authored = workspace:FindFirstChild("WashBay")
	if authored and authored:IsA("Model") then
		local rig = authored:Clone()
		rig.Name = "CoveWashBay"
		rig:PivotTo(CFrame.new(TEMIZUYA.X, 0, TEMIZUYA.Z) * CFrame.Angles(0, -math.pi * 0.5, 0))
		local bcf, bsize = rig:GetBoundingBox()
		rig:PivotTo(rig:GetPivot() + Vector3.new(
			TEMIZUYA.X - bcf.Position.X,
			(G + 0.12) - (bcf.Position.Y - bsize.Y * 0.5),
			TEMIZUYA.Z - bcf.Position.Z))
		rig.Parent = m

		--[[
			REPAINTED BY ROLE, NOT PART BY PART.

			The first cut recoloured the awning slats and the signboard and left the
			rest as the beach carpenter built it, on the argument that the timber
			"looks right here". Measured, it does not. The shack is (72,48,30) posts
			under (104,70,44) walls on a (132,92,58) deck with galvanised grey
			plumbing: a dark hardwood building. Standing on pink sand beside a
			vermilion torii that does not read as restraint, it reads as THE DUNES'
			SHACK -- because it IS, right down to the paint.

			So every part goes through a role table. Roles rather than a name-for-name
			list, because the rig is fifty-odd parts across twenty-five names and a
			table with twenty-five rows is a table that is wrong the first time
			somebody adds a bucket; anything unlisted keeps what it had, which is the
			safe direction to be wrong in.

			WHAT THIS LOOP MAY NOT TOUCH: Stand, PromptAnchor and the Mounted folder.
			WashServer binds the first two by NAME and parents washed finds into the
			third; colour is the only thing this pass is allowed an opinion about.
		]]
		local Mt = Enum.Material
		local COAT = {
			-- the frame, in the colour of the gates
			Post = { PALETTE.vermilion, Mt.SmoothPlastic },
			Column = { PALETTE.vermilion, Mt.SmoothPlastic },
			ShelfBracket = { PALETTE.vermilionDeep, Mt.SmoothPlastic },
			-- The walls: cream, and SMOOTHPLASTIC rather than WoodPlanks. That
			-- texture is a dark brown grain and Roblox multiplies it against the
			-- fill, so cream boards came out khaki and the shack looked repainted
			-- olive rather than cream. Flat panels also read as shoji, which is
			-- what a wall between shrine posts should look like.
			BackWall = { PALETTE.cream, Mt.SmoothPlastic },
			SideWall = { PALETTE.cream, Mt.SmoothPlastic },
			Cladding = { PALETTE.cream, Mt.SmoothPlastic },
			SpareScreen = { PALETTE.stone, Mt.SmoothPlastic },
			-- roof and board: the plum slate the whole precinct is roofed in
			Roof = { PALETTE.plum, Mt.Slate },
			SignBoard = { PALETTE.plum, Mt.SmoothPlastic },
			-- deck and joinery
			Deck = { PALETTE.timber, Mt.WoodPlanks },
			Shelf = { PALETTE.timber, Mt.WoodPlanks },
			Crate = { PALETTE.timber, Mt.WoodPlanks },
			CrateBand = { PALETTE.timberDeep, Mt.Wood },
			ToolBoard = { PALETTE.timberDeep, Mt.Wood },
			BrushHandle = { PALETTE.timberDeep, Mt.Wood },
			BrushHead = { PALETTE.cream, Mt.Fabric },
			-- the water: stone and turquoise, which is the pair the chozubachi
			-- standing outside is already made of
			Butt = { PALETTE.stoneDeep, Mt.Rock },
			ButtBand = { PALETTE.stone, Mt.Metal },
			DrainPan = { PALETTE.stoneDeep, Mt.Rock },
			Feed = { PALETTE.stone, Mt.Metal },
			FeedRise = { PALETTE.stone, Mt.Metal },
			Tap = { PALETTE.vermilionDeep, Mt.Metal },
			Reel = { PALETTE.stoneDeep, Mt.Metal },
			Hose = { PALETTE.turquoise, Mt.SmoothPlastic },
			Bucket = { PALETTE.turquoise, Mt.SmoothPlastic },
			Jar = { PALETTE.mint, Mt.Glass },
			StandVisual = { PALETTE.stone, Mt.Metal },
			-- the lights, and the cloth
			LampShade = { PALETTE.vermilionDeep, Mt.SmoothPlastic },
			WallLampHood = { PALETTE.vermilionDeep, Mt.SmoothPlastic },
			LampFlex = { PALETTE.plum, Mt.SmoothPlastic },
			RagLine = { PALETTE.cream, Mt.SmoothPlastic },
			Rag = { PALETTE.blossom, Mt.Fabric },
		}

		local signBoard, flatRoof
		for _, p in ipairs(rig:GetDescendants()) do
			if p:IsA("BasePart") then
				if p.Name:match("^Stripe%d+$") then
					--[[
						ONE COLOUR, NOT TEN ALTERNATING ONES.

						Kohaku -- the red-and-white that means celebration in Japan -- is the
						right reference and it does not survive this island. Island3_Client
						grades the whole cove to golden hour, which takes the vermilion to
						orange, and ten orange-and-white slats under an eave read as a
						seaside stall. It was the loudest thing left saying "not a shrine".
						A plain valance is what a shrine hangs there.

						vermilionDeep, AND NOT PLUM, which was the first answer. Plum is
						(66,42,62) -- near black -- and the eave and the roof slab above
						this are already plum, so it came out as the third dark band in a
						row and the whole roof read as one heavy slab. The island's own
						grade hid that; the Edit viewport did not.
					]]
					p.Color = PALETTE.vermilionDeep
					p.Material = Mt.Fabric
				elseif p.Name:match("^Grate%d+$") then
					p.Color = PALETTE.stoneDeep
				else
					local coat = COAT[p.Name]
					if coat then
						p.Color = coat[1]
						p.Material = coat[2]
					end
				end
				if p.Name == "SignBoard" then
					signBoard = p
				elseif p.Name == "Roof" then
					flatRoof = p
				end
			elseif p:IsA("PointLight") or p:IsA("SpotLight") then
				p.Color = PALETTE.glowWarm
			end
		end

		--[[
			THE SIGN COMES DOWN OFF THE ROOF, and it has to before a gable can go on.

			Measured on the placed rig it sat at y 13.37 .. 15.57 -- flat on TOP of the
			shack, which is where a trade sign goes on a beach frontage and exactly
			where the first gable course wants to be. Hung under the eave it is lower,
			nearer, readable from the lane, and out of the roof's way. Non-collidable
			because at this height it is over the doorway a player walks through.
		]]
		if signBoard then
			signBoard.Position = Vector3.new(TEMIZUYA.X - 5.4, G + 6.6, TEMIZUYA.Z)
			signBoard.CanCollide = false
		end

		--[[
			THE GABLE. One flat slab is a shed; stepped courses under a ridge is the
			silhouette the haiden and the kagura-den already have, and silhouette is
			how the eye sorts buildings out from across a plaza.

			BUILT OFF THE FLAT ROOF'S OWN WORLD EXTENT, not off TEMIZUYA. The rig is
			placed by its BOUNDING BOX and its roof is not centred inside that box --
			measured, the slab runs 6.07 west of the nominal centre and 8.28 east of
			it -- so a gable centred on the building's nominal position comes out two
			studs proud of one eave and two short of the other.
		]]
		if flatRoof then
			local rcf, rs = flatRoof.CFrame, flatRoof.Size
			local rv, uv, lv = rcf.RightVector, rcf.UpVector, rcf.LookVector
			local ex = math.abs(rv.X) * rs.X * 0.5 + math.abs(uv.X) * rs.Y * 0.5 + math.abs(lv.X) * rs.Z * 0.5
			local ez = math.abs(rv.Z) * rs.X * 0.5 + math.abs(uv.Z) * rs.Y * 0.5 + math.abs(lv.Z) * rs.Z * 0.5
			local rx0, rx1 = rcf.X - ex, rcf.X + ex
			local rz0, rz1 = rcf.Z - ez, rcf.Z + ez
			local ry = rcf.Y + rs.Y * 0.5

			-- The eave: one course WIDER than the roof and tucked under it, which is
			-- the overhang a tiled roof has and the cheapest single thing that stops a
			-- box reading as a box.
			box(m, "TemizuyaEave", rx0 - 2.1, rx1 + 2.1, ry - rs.Y - 0.7, ry - rs.Y,
				rz0 - 2.1, rz1 + 2.1, PALETTE.plum, Enum.Material.Slate,
				{ CanCollide = false })
			-- ALL FOUR COURSES IN STONE, where the haiden's bottom one is plum.
			-- The haiden's dark course IS its eave; this building already has a
			-- plum eave and a plum roof slab beneath the gable, so a plum first
			-- course would be a third dark band and the steps above it would stop
			-- reading as steps.
			for i = 0, 3 do
				box(m, "TemizuyaRoof" .. i,
					rx0 - 1.2 + i * 2.4, rx1 + 1.2 - i * 2.4,
					ry + i * 0.95, ry + 0.95 + i * 0.95,
					rz0 - 1.2 + i * 0.35, rz1 + 1.2 - i * 0.35,
					PALETTE.stoneDeep, Enum.Material.Slate, { CanCollide = false })
			end
			box(m, "TemizuyaRidge", rcf.X - 0.9, rcf.X + 0.9, ry + 3.8, ry + 4.6,
				rz0 - 0.8, rz1 + 0.8, PALETTE.vermilionDeep, Enum.Material.SmoothPlastic,
				{ CanCollide = false })
		end

		--[[
			THE ROPE ACROSS THE MOUTH, which is what says the water in here is for
			purifying rather than for washing a car down.

			AT G + 7.6 AND NO HIGHER. The awning slats sit at 12.2 .. 12.6 and the
			rope is 1.4 deep: hung anywhere above this it is threaded straight through
			them and disappears, which is exactly what the first attempt did.
		]]
		shimenawaZ(m, TEMIZUYA.Z - 5.5, TEMIZUYA.Z + 5.5, G + 7.6, TEMIZUYA.X - 4.2, 3)
		-- Chochin at the corners of the opening, off the centre line so nobody walks
		-- into one on the way to the stand. Clear of the front posts, which stand at
		-- x -3.8 and z +-6.4 of the nominal centre.
		for _, sz in ipairs({ -1, 1 }) do
			prop("paperLantern", m, CFrame.new(TEMIZUYA.X - 5.0, G + 9.6, TEMIZUYA.Z + sz * 4.5), 1)
		end

		--[[
			THE CHOZUBACHI, which is what actually makes this read as a temizuya rather
			than as a shed with a sign on it -- but only once it reads as a VESSEL. At
			the first sizes the water sat half a stud below the rim of a solid 6 x 6
			block and the whole thing was a boulder. It is hollowed now: a sunken well,
			a cream rim proud of it, and the water raised into the hollow where it can
			be seen.

			ON THE NORTH SHOULDER. South of the bay is the LANE (see the note on
			TEMIZUYA), and six studs of solid rock 3.4 high standing in a 9.6-stud
			route is the same mistake the whole re-plan undid, at one twentieth the
			scale. North of it is dead corner, and a real chozubachi stands beside the
			path anyway rather than across it.
		]]
		local bx, bz = TEMIZUYA.X - 12, TEMIZUYA.Z + 10
		box(m, "Chozubachi", bx - 3, bx + 3, G + 0.12, G + 3.4, bz - 3, bz + 3,
			PALETTE.stoneDeep, Enum.Material.Rock)
		box(m, "ChozuWell", bx - 2.3, bx + 2.3, G + 3.15, G + 3.42, bz - 2.3, bz + 2.3,
			PALETTE.stoneDeep, Enum.Material.Rock, { CanCollide = false })
		box(m, "ChozuRim", bx - 3.2, bx + 3.2, G + 3.28, G + 3.56, bz - 3.2, bz + 3.2,
			PALETTE.cream, Enum.Material.Rock, { CanCollide = false })
		box(m, "ChozuWater", bx - 2.1, bx + 2.1, G + 3.25, G + 3.51, bz - 2.1, bz + 2.1,
			PALETTE.turquoise, Enum.Material.Glass,
			{ CanCollide = false, Transparency = 0.28, Reflectance = 0.25 })
		box(m, "Hishaku", bx - 1.6, bx + 1.6, G + 3.5, G + 3.9, bz - 0.25, bz + 0.25,
			PALETTE.timberDeep, Enum.Material.Wood, { CanCollide = false })
	end

	----------------------------------------------------------------
	-- THE KAGURA-DEN  --  the car pad, outside the precinct entirely
	----------------------------------------------------------------
	--[[
		An open roofed stage is what a kagura-den IS, and it happens to be exactly
		the right shape to shelter a vehicle pad. The pad builds at ground level and
		the pavilion goes up around it rather than under it, so nothing here has to
		know the pad's own geometry beyond its 16 x 22 footprint.
	
		IT MOVED OUT THROUGH THE EAST KERB, and that is the fix for the complaint
		this whole re-plan started from.
	
		It used to stand on the apron at (48, 1312) pointing +Z, with the wash bay
		twenty-three studs dead ahead. CarSpawnerBuilder builds its bay CLOSED at
		the back and OPEN at the front because a bay is a thing you drive out of,
		and its SpawnPoint faces +Z so a machine is already pointing down the drive
		-- so the pad was doing exactly what it says on the tin and what it pointed
		at was a shed. There is no rotation of that pad that helps: south is the
		sea, west is the sando, and the only two hundred studs of open ground on
		this island are NORTH, on the other side of the plaza.
	
		So the pad goes outside the kerb instead, where north is a straight line.
		The bay mouth is at z = 1359 and the next thing in front of it is the
		rakeable field at 1404: forty studs of clear sand, with a drive laid on it
		so the line is obvious before you take it.
	
		Still outside the gate, which is where vehicles belong at a shrine, and now
		outside the kerb as well.
	]]
	local okCar, carErr = pcall(function()
		local CarSpawnerBuilder = require(script.Parent:WaitForChild("CarSpawnerBuilder"))
		local carPad = CarSpawnerBuilder.build(CFrame.new(KAGURA.X, G + 0.2, KAGURA.Z))
		carPad.Name = "CoveCarSpawner"
		carPad.Parent = m
		-- The builder hangs its board off the pad's +X side, because on the beach
		-- that is the side the whole row of frontages is walked up from. Here +X is
		-- open sand and the plaza is on the other side, so the three sign parts are
		-- reflected across the pad's own centre line. SignKit already dressed BOTH
		-- faces of that board -- the wash bay taught it that lesson -- so the
		-- reflection costs nothing and reads the same from either side.
		for _, p in ipairs(carPad:GetChildren()) do
			if p:IsA("BasePart") and (p.Name == "SignPost" or p.Name == "SignBoard"
				or p.Name == "SignTrim") then
				p.Position = Vector3.new(2 * KAGURA.X - p.Position.X, p.Position.Y, p.Position.Z)
			end
		end
	end)
	if not okCar then
		warn("[Cove] no car pad on the kagura-den:", carErr)
	end
	
	-- A spur of plaza paving out through the break in the kerb, so the walk to
	-- the machines is a made path and not four studs of loose sand.
	box(m, "CarApron", X1 - 2, KAGURA.X - 8, G - 0.5, G + 0.12,
		KAGURA.Z - 12, KAGURA.Z + 12, PALETTE.stone, Enum.Material.Concrete)

	-- ...and a banner either side of the break, because the pad's own board is
	-- four studs of lettering eighty-six studs east of the sando and nobody is
	-- reading that from the gate. A 13-stud nobori in the car pad's own amber is
	-- the only thing at this range that says SOMETHING IS OVER HERE, and the
	-- approach is already lined with them, so it costs no new vocabulary.
	--
	-- ON THE STUBS, NOT IN THE GAP. Set inside the break they stood in the one
	-- place a machine has to pass and read on top of the pad's own board from the
	-- driving seat; two studs outside each end of it they bracket the opening
	-- instead, which is what a pair of banners is for.
	for _, z in ipairs({ CARPARK_Z0 - 2, CARPARK_Z1 + 2 }) do
		nobori(m, X1 - 5, z, PALETTE.lantern)
	end
	
	--[[
		THE DRIVE. Packed sand from the bay mouth to the edge of the field, and the
		one piece of this island whose whole job is to be READ rather than walked
		on: somebody who has just spent six thousand on a quad should be able to
		see where it goes before they touch a key.
	
		IT STOPS AT SANDO_Z1, NOT AT THE FIELD EDGE. assertClearOfField measures a
		part's real extent, and a slab centred at 1379.5 reaching 20.5 studs clears
		the square's south edge by four. Run it the last four studs to 1404 and the
		island reports itself broken at every boot.
	]]
	box(m, "Drive", KAGURA.X - 8, KAGURA.X + 8, G + 0.02, G + 0.1,
		KAGURA.Z + 11, SANDO_Z1, PALETTE.sandDeep, Enum.Material.Concrete,
		{ CanCollide = false })
	for _, s in ipairs({ -1, 1 }) do
		box(m, "DriveRut", KAGURA.X + s * 3.2 - 0.9, KAGURA.X + s * 3.2 + 0.9,
			G + 0.1, G + 0.16, KAGURA.Z + 11, SANDO_Z1,
			PALETTE.sand, Enum.Material.Concrete, { CanCollide = false })
	end
	
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			box(m, "KaguraPost", KAGURA.X + sx * 12 - 0.9, KAGURA.X + sx * 12 + 0.9,
				G, G + 15, KAGURA.Z + sz * 14 - 0.9, KAGURA.Z + sz * 14 + 0.9,
				PALETTE.vermilion, Enum.Material.SmoothPlastic)
		end
	end
	for i = 0, 3 do
		box(m, "KaguraRoof" .. i, KAGURA.X - 16 + i * 0.6, KAGURA.X + 16 - i * 0.6,
			G + 15 + i * 1.1, G + 16.1 + i * 1.1,
			KAGURA.Z - 18 + i * 2.4, KAGURA.Z + 18 - i * 2.4,
			(i == 0) and PALETTE.plum or PALETTE.stoneDeep, Enum.Material.Slate,
			{ CanCollide = false })
	end
	shimenawa(m, KAGURA.X - 10, KAGURA.X + 10, G + 12.4, KAGURA.Z - 14, 3)

	-- Blossom over the whole precinct. Sakura is the island's own note and the
	-- one thing that makes a red gate on pink sand read as a shrine in spring
	-- rather than as a red gate. RE-SITED WITH THE BUILDINGS: the old west pair
	-- at (-62, 1338) and (-66, 1376) are inside the haiden now, and the old east
	-- pair at (64, 1340) and (66, 1372) are inside the shop and the wash bay.
	-- All four move out past the kerb line, where a 22-stud tree is a skyline
	-- rather than something to walk round.
	for _, t in ipairs({
		{ CX - 68, 1320 }, { CX - 68, 1388 },
		{ CX + 68, 1320 }, { CX + 68, 1388 },
		{ CX - 30, 1302 }, { CX + 32, 1300 },
	}) do
		prop("sakuraTree", m, CFrame.new(t[1], G, t[2]), 1)
	end

	return m, pad, vends
end

----------------------------------------------------------------
-- ADOPT OR BUILD
--
-- The same switch the dunes use: a Workspace.Island3 folder carrying the
-- HandBuilt attribute is authored geometry, and build() leaves it exactly as
-- saved. Without the attribute nothing changes and the cove is generated from
-- scratch as it always was.
--
-- The cove needs far less on the way back in than the dunes did. Island2Builder
-- has to re-run a whole wiring pass because its door owns sounds, a spill light,
-- a dust emitter and a ClickDetector handler, none of which survive in a place
-- file. NOTHING in this script connects an event: the plaza's ShopPrompt and the
-- vending machines are ProximityPrompts, which ARE saved instances, and
-- everything that moves out here belongs to Island3_Client. So adopting is three
-- things -- find the sell pad, publish it, and run the sweeps below.
--
-- TO FREEZE THE COVE, once: run Island3.build() from the command bar in Edit
-- mode so the place holds the CURRENT geometry, set the attribute on the folder
-- it leaves behind, and save.
----------------------------------------------------------------
local HAND_BUILT = "HandBuilt"

--[[
	FINAL SWEEPS, run over the finished cove whether it was generated or adopted.

	All three are idempotent and cost one descendant walk between them, and each
	is worth MORE on a hand-built island than on a generated one: a generated cove
	has just been through them, so on an adopted one what they are really checking
	is whatever a person has added since.

	ANCHOR. Island3Props' contract says every BasePart it returns is anchored, and
	this is not a substitute for that -- it is the net under it. An unanchored part
	in a server-built island does not fail visibly at boot; it falls over some time
	in the next few minutes on a live server, on somebody else's screen, with
	nothing in the log. A part dragged in by hand is the worse case: Studio makes
	new parts unanchored by default and Edit runs no physics at all, so it looks
	perfect right up until it is on a server.

	SHADOW CASTERS. Every one of the ~1000 parts out here shipped with CastShadow
	on, and under Future lighting each one is a draw into the shadow map whether or
	not it puts anything on the ground. Three classes never do:

	  * anything under a stud on its smallest axis -- rails, joints, whiskers,
	    straps, lantern marks. At the sun angle this island is lit at, their
	    shadow is thinner than a pixel from anywhere a player stands.
	  * Neon. A part that is supposed to be emitting light casting a hard black
	    shadow is wrong as well as expensive.
	  * anything more than half transparent -- the veils, the boba cup walls,
	    the invisible roots and prompt anchors. Roblox shadows them as solid.

	The blossom canopies KEEP theirs on purpose: dappled shade under a cherry tree
	at a low sun is the single best thing the lighting does here.

	THE FIELD ASSERTION. Nothing may stand inside the rakeable square, and dragging
	a tree into it is precisely the mistake hand-editing invites -- the player would
	be raking sand out from under it.
]]
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
--[[
	THE DRESSING PASS -- and the cove is the island that most needed one.

	WHY IT EXISTS AT ALL. Island3 in this place is HAND-BUILT and adopted, so
	build() returns at the top and every scatter loop below it has never run on
	this place, not once. The Dunes hit exactly this and solved it the same way:
	a dressing pass called from BOTH branches, so the path the place actually
	takes is the path that gets dressed. What was in the cove was the precinct,
	the boardwalk and the shrine -- all of it clustered round the middle -- with a
	hundred and ninety studs of bare pink sand between that and the water.

	IT IS ADDITIVE AND IT IS IDEMPOTENT. Everything lands in its own `Dressing`
	folder, which is destroyed and remade at the top, so running it twice leaves
	one set rather than two -- and nothing it does touches the hand-authored
	geometry it is laid around.

	WHAT IT PLANTS, and each is for a different lack:
	  sakura       the signature, and there were nine on the whole island
	  bamboo       HEIGHT. See the note on the prop: everything else here is
	               either flat or a soft dome
	  stone toro   punctuation along the ground, and the one cool grey in the mix
	  rock         the shoreline had nothing on it at all
	  beach sets   people were here; the cove is a resort, not a wilderness
	  shore ring   a SECOND pass of sakura, walking the coastline rather than
	               sampling the island -- see the note on it. The scatter above
	               fills the cove; this is what surrounds it.
]]
local function dressCove(root: Instance)
	local old = root:FindFirstChild("Dressing")
	if old then
		old:Destroy()
	end
	local f = Instance.new("Folder")
	f.Name = "Dressing"
	f.Parent = root

	-- Terrain collision is rebuilt a frame behind the voxel write and every prop
	-- here is seated by raycast, the same reason the Dunes' pass waits.
	waitForGround()

	local rng = Random.new(Config.SEED + 5171)

	-- One shared list, so the collisions between categories are caught as well as
	-- those within them. Island4Builder's scatter states the argument at length.
	local placed = {}
	local function spaced(x, z, r)
		for _, q in ipairs(placed) do
			local dx, dz = x - q[1], z - q[2]
			local reach = r + q[3]
			if dx * dx + dz * dz < reach * reach then
				return false
			end
		end
		return true
	end
	local function claim(x, z, r)
		table.insert(placed, { x, z, r })
	end

	--[[
		The band: outside the rakeable square, inside the plateau, and never in the
		bay. 118 clears the field's 96 with a margin the props' own footprints eat
		into; 276 stops short of the 296 shoreline so nothing stands in the surf.
	]]
	--[[
		BANDS ARE QUOTED AGAINST THE FIELD, NOT AS WORLD RADII.

		minR used to be 118 -- "96 plus a margin the props' own footprints eat
		into". Written that way it silently dies when the square grows: at
		FIELD_HALF 192 a draw at radius 118 is inside the field on every bearing,
		openGround rejects all of them, and the pass places nothing while
		reporting success. So minR is offered as an offset past the square's own
		half-width and maxR as a reach into the plateau, which now bulges north
		(see landAt) -- and onLand inside openGround is what keeps the outer draws
		out of the surf on the bearings where the land did NOT grow.
	]]
	local function pick(overField, maxR)
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(FIELD_HALF + overField, maxR)
		return CX + math.cos(a) * d, CZ + math.sin(a) * d
	end

	--[[
		THE SHRINE'S GROUND IS SPOKEN FOR, AND THIS PASS RUNS BEFORE THE SHRINE.

		CTB_Server calls Island3.build well ahead of SShrine.build, so there is
		nothing up there to collide with yet -- and the scatter happily planted a
		sakura in the middle of the sando and a rock formation on the paving.

		ShrineBuilder HAS a sweep for exactly this (clearSite), and it did not
		catch them for two reasons: it only ever looks in `Props`, the authored
		folder, and everything this pass makes goes into `Dressing`. That sweep is
		fixed too, but it is a backstop -- not planting on the site in the first
		place is the actual fix, because a prop shoved sideways at boot lands
		wherever the push happens to put it.

		THE FOOTPRINT IS ShrineBuilder'S OWN, derived off the field's north edge
		the same way that file derives it, so the two cannot drift. Deliberately
		NARROW -- the paved approach and the hall, not a wide exclusion box:
		sakura standing close either side of the sando is the whole point of
		framing it, and only what would grow THROUGH the paving is refused.
	]]
	local function onShrineSite(x, z, r)
		local SANDO_Z0 = FCZ + FIELD_HALF + 32
		local SANDO_Z1 = SANDO_Z0 + 80
		local HALL_Z0, HALL_Z1 = SANDO_Z1 + 4, SANDO_Z1 + 78
		if z >= SANDO_Z0 - 6 - r and z <= SANDO_Z1 + 4 + r and math.abs(x) <= 18 + r then
			return true
		end
		return z > HALL_Z0 - 6 - r and z <= HALL_Z1 + 8 + r and math.abs(x) <= 56 + r
	end

	--[[
		nil ON A MISS, WHICH groundY CANNOT SAY.

		groundY returns its `fallback` when the ray hits nothing, so passing GROUND
		makes open sea read as flat sand at exactly the height a placement is
		looking for, and any pass that trusts it plants trees in the water. Both of
		the passes at the bottom of this function stand on ground the landAt curve
		is not authoritative about -- the shrine precinct is past its reach, the
		shore ring sits right on its edge -- so both probe for real, and both have
		to be able to tell a miss from a hit.
	]]
	local function solidGround(x, z): number?
		local hit = workspace:Raycast(Vector3.new(x, 160, z), Vector3.new(0, -300, 0), groundParams)
		return hit and hit.Position.Y or nil
	end

	local function place(kind, tries, want, minR, maxR, radius, scaleLo, scaleHi)
		local made = 0
		for _ = 1, tries do
			if made >= want then
				break
			end
			local x, z = pick(minR, maxR)
			if openGround(x, z, radius) and spaced(x, z, radius) and not inBay(x, z, 12)
				and not onShrineSite(x, z, radius) then
				local y = groundY(x, z, GROUND)
				-- On the flat, not on the shelf that falls away to the water.
				if math.abs(y - GROUND) < 3.5 then
					local cf = CFrame.new(x, y, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0)
					if prop(kind, f, cf, rng:NextNumber(scaleLo, scaleHi)) then
						made += 1
						claim(x, z, radius)
					end
				end
			end
		end
		return made
	end

	-- Order matters: the things that want the most room go first, or the small
	-- scatter fills the island and the trees have nowhere left to stand.
	--[==[
		NO BAMBOO, AND THAT IS THE SECOND THING I TRIED RATHER THAN THE FIRST.

		A clump of culms was in here for HEIGHT, which this island genuinely
		lacks. It came out as a row of teal poles with a flat plate angled off
		the top of each -- street lights, exactly as reported. Tightening the
		lean and darkening the tone fixed the splay and not the reading.

		The cause is the palette and it is not going to move: this cove runs
		pink, blush, rose, cream, lilac and a pastel TURQUOISE, and `mint` is the
		nearest thing to a green in it. Bamboo lerped out of a mint is a grey-
		teal pole whatever is done to it, and a pole with a leaf blade on top is
		a lamp post. Height on this island has to come from something that is
		allowed to be pink.

		So the twenty slots went to the props that already read correctly here.
	]==]
	local trees = place("sakuraTree", 3000, 40, 22, 380, 17, 0.85, 1.45)
	local rocks = place("rockFormation", 2200, 24, 54, 384, 13, 0.7, 1.5)
	local toro = place("stoneLantern", 2200, 22, 22, 358, 9, 0.8, 1.2)

	-- Beach sets face the water, so they are picked on the outer band only and
	-- turned to look back at the middle of the island.
	local sets = 0
	for _ = 1, 800 do
		if sets >= 6 then
			break
		end
		local x, z = pick(114, 380)
		if openGround(x, z, 14) and spaced(x, z, 14) and not inBay(x, z, 12)
			and not onShrineSite(x, z, 14) then
			local y = groundY(x, z, GROUND)
			if math.abs(y - GROUND) < 3 then
				local facing = math.atan2(x - CX, z - CZ)
				if prop("beachSet", f, CFrame.new(x, y, z) * CFrame.Angles(0, facing, 0)) then
					sets += 1
					claim(x, z, 14)
				end
			end
		end
	end

	--[[
		THE SHRINE HAS TO BE FRAMED, and the scatter above cannot do it.

		Every band above is quoted as an offset past the RAKEABLE SQUARE and drawn
		on a bearing from the island centre, so it thins out to nothing by the time
		it reaches the north shore -- and the shrine stands thirty-two studs past
		the square's north edge, on the one part of the island that scatter never
		reaches. It was left standing on bare sand.

		So this is a second, RECTANGULAR pass around the precinct rather than a
		wider radius on the first one: a round band centred on the island would
		have to reach ~500 studs to touch the hall, and everything it planted on
		the way would land in the sea on every other bearing.

		THE FOOTPRINT IS DERIVED THE WAY ShrineBuilder DERIVES IT -- off the
		field's north edge -- rather than typed. That file computes
		SANDO_Z0 = cz + half + 32 and levels terrain out to HALL_HX + 8 either
		side; if the square is ever resized again both move together, and these
		trees move with them. Typing 1820 here is exactly the bug that put the old
		props inside the enlarged square.

		DRESSING RUNS BEFORE ShrineBuilder (CTB_Server calls Island3.build well
		ahead of SShrine.build), so nothing of the shrine exists to test against
		yet -- which is why the precinct is excluded geometrically instead of by
		looking. ShrineBuilder's own "props moved off the site" sweep is the
		backstop if anything still lands inside it.

		IT DOES NOT USE openGround(), AND THAT IS THE WHOLE REASON THIS PASS
		PLACED NOTHING THE FIRST TIME. openGround() calls onLand(), and onLand()
		asks landAt() -- a curve that tops out at 406 studs from the landmass
		anchor, i.e. z = 1906. The shrine's own precinct reaches z 1990 and the
		terrain actually poured up here runs to about z 2120, so onLand() rejects
		the entire northern half of the site while standing on solid sand. The
		curve is stale for this bearing; the ground is the truth.

		So the land test here is a REAL PROBE, and it has to distinguish a miss
		from a hit -- which groundY() cannot, because it returns its `fallback` on
		a miss. Passing GROUND as that fallback makes open sea read as flat sand
		at exactly the height we are looking for, and the pass would plant the
		whole ring in the water. solidGround() below returns nil instead.
	]]
	local shrine = 0
	do
		local SANDO_Z0 = FCZ + FIELD_HALF + 32
		local PX, PZ0, PZ1 = 56, SANDO_Z0 - 6, SANDO_Z0 + 170
		local REACH = 66           -- no further out than this, or it is not a frame

		-- Only the paving itself is refused, not a wide box round the precinct: a
		-- sakura standing close beside the sando is what frames the approach, and
		-- holding them all 79 studs off left the walk up to the hall bare.
		local function outsidePrecinct(x, z, r)
			return not onShrineSite(x, z, r)
		end
		local function nearPrecinct(x, z)
			local dx = math.max(0, math.max(-PX - x, x - PX))
			local dz = math.max(0, math.max(PZ0 - z, z - PZ1))
			return math.max(dx, dz) <= REACH
		end
		for _ = 1, 2600 do
			if shrine >= 20 then
				break
			end
			local x = rng:NextNumber(-PX - REACH, PX + REACH)
			local z = rng:NextNumber(PZ0 - REACH, PZ1 + REACH)
			if outsidePrecinct(x, z, 8) and nearPrecinct(x, z)
				and clearOfField(x, z, 15) and clearOfBuildings(x, z, 15) and spaced(x, z, 15) then
				local y = solidGround(x, z)
				if y and math.abs(y - GROUND) < 3.5 then
					local cf = CFrame.new(x, y, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0)
					if prop("sakuraTree", f, cf, rng:NextNumber(0.85, 1.35)) then
						shrine += 1
						claim(x, z, 15)
					end
				end
			end
		end
	end

	--[[
		THE SHORE RING -- blossom the whole way round the cove.

		WHAT WAS HERE WAS A DISC, NOT A BORDER. `place` draws a random bearing and
		a distance uniformly in [FIELD_HALF + over, maxR], which spreads its forty
		trees evenly through a band 166 studs deep -- and then onLand throws most
		of the outer draws away, because the curve it asks says the land stops 296
		studs due south against a maxR of 380. What came out reads as a field with
		trees dotted round it. The cove was meant to be RINGED.

		AND THE CURVE IS NOT WHERE THE COAST IS. landAt calls itself "THE CONTRACT
		WITH THE TERRAIN" and it is out of date: this island's sand is hand-built
		and frozen in the place file, and it has been cut and re-poured since.
		Measured with a raycast fan, the outermost column of flat rake-height sand
		on each bearing against what landAt claims:

		    bearing      0    45    90   135   180   225   270   315
		    landAt     296   379   406   379   296   296   296   296
		    real       344   400   636   400   344   392   248   392

		Every bearing is short, most by about fifty studs and due north by two
		hundred and thirty. The first cut of this pass used the curve in closed
		form -- along a bearing the dz/d it wants IS sin(a) -- and planted TWO
		trees out of forty-four, because onLand refuses the real coastline
		everywhere.

		SO THIS ONE MARCHES. Per bearing it steps outward from just past the square
		until the column stops being flat sand and keeps the last one that was: the
		ground is the truth, which is the same conclusion the shrine block above
		came to about its own site. About 3,300 rays, once, at boot -- against the
		6,202 the sea wall already spends.

		INSET, NOT RADIUS. Each tree stands 20..64 studs in from its OWN bearing's
		water line, so the ring is a band hugging whatever shape the coast is
		rather than a circle that happens to touch it in four places. The band is
		deep because it has to weave: the scatter above has already claimed a lot
		of this ground, and `spaced` is what rejects most draws.

		BEARINGS ARE WALKED, NOT SAMPLED. 144 slots, shuffled, eight goes each, so
		the ring covers the whole compass instead of clumping wherever the random
		draws fell -- and still lands nowhere near regular enough to read as rows.

		THE SOUTH ARC IS MEANT TO BE THIN. The bay is 148 studs of water centred at
		z 1104 and the march stops dead at its edge, so due south plants a handful
		against the north's twenty-odd. That is the cove's mouth: it is supposed to
		be open water, and a tree line drawn across it would close the one view the
		island is named for.

		SHORE_MAX CAPS THE NORTH at 470 instead of following the sand out to 636.
		Everything past that is the levelled ground BEHIND the shrine hall, which
		is a dead end -- trees there are paid for and never seen, and the shrine's
		own framing pass already dresses that precinct.

		IT RUNS LAST, AFTER EVERY OTHER PASS, DELIBERATELY. `rng` and `placed` are
		both shared, so moving it earlier would move every rock, lantern and beach
		set already standing on this island -- and LeaderboardConfig's own -36
		shift and ServiceClearance's aprons are sited against where those are now.
	]]
	local ring = 0
	do
		local TAU = math.pi * 2
		local SLOTS, PER_SLOT, WANT = 144, 8, 56
		local R_TREE = 11              -- tighter than the scatter's 17: a treeline, not scatter
		local INSET_LO, INSET_HI = 20, 64
		local SHORE_MAX = 470
		local STEP = 6

		--[[
			IS ANYTHING ALREADY STANDING HERE? KEEP_OUT is a hand-kept list of the
			five things that mattered on the day it was written, and this ring runs
			out where the leaderboard boards, the reward boards, the sandbot dock
			and the ferry furniture are -- none of which are on it. So this asks the
			world instead of the list.

			Our own dressing is excluded: `spaced` already owns those, and by their
			real radii rather than by a box. Terrain is excluded explicitly -- it is
			a BasePart, the whole island is made of it, and one behaviour change in
			what a spatial query returns would otherwise silently place nothing.
		]]
		local occupancy = OverlapParams.new()
		occupancy.FilterType = Enum.RaycastFilterType.Exclude
		occupancy.FilterDescendantsInstances = { f, workspace.Terrain }
		occupancy.MaxParts = 1
		local function occupied(x, z)
			return #workspace:GetPartBoundsInBox(
				CFrame.new(x, GROUND + 7, z), Vector3.new(12, 14, 12), occupancy) > 0
		end

		local function flatSand(x, z): number?
			local y = solidGround(x, z)
			return (y and math.abs(y - GROUND) < 3.5) and y or nil
		end

		local function shoreOn(a): number?
			local ca, sa = math.cos(a), math.sin(a)
			local last = nil
			for d = FIELD_HALF + 20, SHORE_MAX, STEP do
				if flatSand(CX + ca * d, CZ + sa * d) then
					last = d
				elseif last then
					break
				end
			end
			return last
		end

		local order = {}
		for i = 0, SLOTS - 1 do
			order[i + 1] = i
		end
		for i = SLOTS, 2, -1 do
			local j = rng:NextInteger(1, i)
			order[i], order[j] = order[j], order[i]
		end

		for _, slot in ipairs(order) do
			if ring >= WANT then
				break
			end
			-- Marched once per slot and reused for all eight goes: the jitter below
			-- is two and a half degrees, and no coastline moves that fast.
			local shore = shoreOn(slot * TAU / SLOTS)
			if shore then
				for _ = 1, PER_SLOT do
					if ring >= WANT then
						break
					end
					local a = (slot + rng:NextNumber(0, 1)) * TAU / SLOTS
					local d = shore - rng:NextNumber(INSET_LO, INSET_HI)
					local x, z = CX + math.cos(a) * d, CZ + math.sin(a) * d
					if clearOfField(x, z, R_TREE) and clearOfBuildings(x, z, R_TREE)
						and not inBay(x, z, 12) and not onShrineSite(x, z, R_TREE)
						and spaced(x, z, R_TREE) and not occupied(x, z) then
						local y = flatSand(x, z)
						if y then
							local cf = CFrame.new(x, y, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0)
							-- Bigger than the scatter's range on purpose: this is a
							-- treeline read from across the island, not something a
							-- player walks past.
							if prop("sakuraTree", f, cf, rng:NextNumber(0.95, 1.55)) then
								ring += 1
								claim(x, z, R_TREE)
							end
						end
					end
				end
			end
		end
	end

	--[[
		THE DRESSING GETS THE ISLAND'S OWN SWEEPS, WHICH IT NEVER USED TO.

		finalSweeps runs on the adopted cove BEFORE this pass is called, so every
		prop planted here has been skipping all three of its checks since the pass
		was written. The one that shows is CastShadow: every sakura carries an
		invisible TrunkCollider and an invisible PetalSource, and Roblox shadows a
		fully transparent part exactly as if it were solid -- so each tree out here
		has been laying a hard bar of shade on the sand from a part nobody can see.

		Same three classes the rest of the island is held to, and it re-asserts the
		rakeable square over the one set of props that is placed by arithmetic
		rather than by hand -- which is the set worth asserting over.
	]]
	local _, shadowsOff, intruders, parts = finalSweeps(f)
	print(string.format(
		"[Cove] dressing: %d sakura (+%d framing the shrine, +%d ringing the shore), %d rocks, "
		.. "%d toro, %d beach sets, %d parts, %d shadow casters trimmed, %d field intruders",
		trees, shrine, ring, rocks, toro, sets, parts, shadowsOff, intruders))
end

function Island3.build()
	--[[
		ADOPTED? Then the cove in the place file IS the cove, and build() returns
		here before it can touch any of it. See ADOPT OR BUILD, above.

		This is the FIRST thing build() does, ahead of the terrain note below,
		because the wipe that note is about is exactly what is being skipped: on an
		adopted cove buildTerrain never runs, so no player's raked progress is ever
		at risk and calling build() twice is simply safe.
	]]
	local existing = workspace:FindFirstChild("Island3")
	if existing and existing:GetAttribute(HAND_BUILT) == true then
		local market = existing:FindFirstChild("Market")
		local pad = market and market:FindFirstChild("SellPad")
		if pad then
			-- Published here for the reason the generated path publishes it early:
			-- CTB_Server picks the pad off the module if anything throws.
			Island3.sellPad = pad
			-- Recorded even though no terrain was written, so that a later call which
			-- WOULD run buildTerrain -- somebody clearing the attribute mid-session --
			-- still gets the wipe warning below.
			Island3.built = true

			local unanchored, shadowsOff, intruders, partCount, lightCount = finalSweeps(existing)
			if unanchored > 0 then
				warn(string.format(
					"[Cove] anchored %d hand-placed part(s) that were left loose. Edit runs no "
					.. "physics, so they look right in Studio and fall over on a live server.",
					unanchored))
			end
			print(string.format(
				"[Cove] adopted the hand-built cove saved in the place file: %d parts, %d lights, "
				.. "%d shadow casters trimmed, %d field intruders",
				partCount, lightCount, shadowsOff, intruders))

			-- ...and dressed anyway. This is the branch this place actually takes,
			-- so a dressing pass that only ran on the generated one would never run
			-- at all. Its own pcall: a prop kit that fails to place must not cost
			-- the caller the sell pad it is waiting for.
			local okDress, errDress = pcall(dressCove, existing)
			if not okDress then
				warn("[Cove] the dressing pass failed: " .. tostring(errDress))
			end
			return pad
		end
		warn(string.format(
			"[Cove] Workspace.Island3 is marked %s but has no Market.SellPad -- rebuilding it from "
			.. "code, which loses any hand edits AND wipes raked progress. Rename that part back, "
			.. "or clear the %s attribute if the cove is meant to be code-built.",
			HAND_BUILT, HAND_BUILT))
	end

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
		THE GREAT TORII, standing in the water off the cove's west shoulder.

		Its Y comes off a raycast and not off a constant. The bay floor at this
		point is the result of four disc fills, a voxel lift and a carve, and the
		one thing that must be true of this gate is that its feet are UNDER the
		water -- a torii resting on the surface is a prop, a torii wading is a
		landmark. The base is set a stud into the sand so the footings are buried
		rather than balanced, which puts about 2.5 studs of pillar under water.

		WHERE it stands, and why it is not on the axis any more, is the note on
		TORII_X near the top of this file -- it is the composition decision this
		island turns on, and it has been wrong once already. Read it before moving
		this, and re-check the footings against the bay radius afterwards.
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
	--
	-- Nothing, and that is the change. The cove's two travel gates -- the
	-- torii on the shore at z = 1264 and its twin sited along the beachfront --
	-- are gone, and so is the Lv.5 check that sat in the beach one's Triggered
	-- handler. Crossing is the FERRY now: FerryBuilder moors a boat off a pier
	-- at the foot of the boardwalk with a man on the deck to ask, FerryServer
	-- runs the crossing, and FerryConfig.Ports carries the same Sifter Lv.5
	-- this island has always asked for. It builds into a folder of its own, so
	-- the assertion below still only ever measures the cove's own geometry.
	----------------------------------------------------------------

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
		local d = rng:NextNumber(FIELD_HALF + 26, 376)
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
		local d = rng:NextNumber(FIELD_HALF + 22, FIELD_HALF + 94)
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
		-- Behind the FIELD's north edge, not 120 studs behind the island's centre:
		-- the square's far side is what the grove is meant to close off.
		local x = CX + rng:NextNumber(-150, 150)
		local z = FCZ + FIELD_HALF + rng:NextNumber(24, 96)
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
	--
	-- Shared with the adopt path at the top of this function; the prose on why
	-- each one exists lives on finalSweeps itself.
	----------------------------------------------------------------
	local unanchored, shadowsOff, intruders, partCount, lightCount = finalSweeps(root)
	if unanchored > 0 then
		warn(string.format("[Cove] anchored %d part(s) that arrived loose from Island3Props", unanchored))
	end

	print(string.format(
		"[Cove] island built: %d mounds, %d headland rises, %d sakura, %d rock formations, %d beach sets, %d floaties, %d lanterns (+%d toro), %d vending; torii top y=%.1f at x=%.0f; %d prop failures, %d field intruders",
		mounds, headlands, trees, rocks, sets, floats, lanterns, stoneLanterns, vends,
		(floorY - 1) + toriiTop, CX + TORII_X, propFails, intruders))
	print(string.format("[Cove] cost: %d parts, %d lights, %d shadow casters trimmed",
		partCount, lightCount, shadowsOff))

	return sellPad
end

return Island3
