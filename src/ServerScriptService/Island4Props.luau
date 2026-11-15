--[[
	Island4Props -- the volcanic prop library for Ashfall Isle (Config.ISLANDS[5]).

	Pure builders. Given a parent and a CFrame, each function dresses a Model and
	hands it back. Nothing in here touches terrain, remotes, player state or the
	shop prompt -- Island4Builder owns all of that and calls in here for the
	furniture, which is what stops a scatter loop from having to know how a torch
	is assembled. Same split Island3Props keeps, for the same reason.

	THE LOCAL FRAME, and the one thing a caller has to know: y = 0 is the GROUND,
	the prop is centred on x = 0, and it FACES -Z, which is cf.LookVector. One
	documented exception: lavaPool's cf is the LAVA SURFACE, not the ground under
	it, because a pool is a level thing sitting in a hollow and the hollow's floor
	is nobody's business but the terrain's.

	PART COST is stated above every builder. Ashfall loads in the same client as
	the beach and has to survive a phone, so nothing here is allowed past 60 parts
	and most of it is well under half that.

	THE MESHES COME OUT OF THE TOOLBOX, and they are the reason this island reads
	as rock rather than as boxes. Seven Creator Store meshes -- a boulder, two
	low rocks, two palms, a dead log and a stump -- are stripped of every script,
	GUI and sound their uploads carried and kept in ServerStorage.VolcanoAssets,
	which this file CLONES OUT OF. It never inserts from the marketplace at
	runtime: a toolbox model dropped into a running game is somebody else's code
	executing in yours, which is the lesson FerryBuilder's header already records.

	AND IT ALL STILL WORKS WITHOUT THEM. If the folder is missing -- a place file
	restored from before it existed, an asset that failed to save -- every kit()
	call answers nil and the prop falls back to primitives in the same paint. An
	island built out of boxes beats an island that failed to build.

	THREE RULES THIS FILE INHERITS FROM THE ISLANDS AROUND IT
	---------------------------------------------------------
	  * No part may use Enum.Material.Ground or Enum.Material.Asphalt (Sakura
	    Cove's terrain pair, tinted globally by CTB_Server.applyLook). And nothing
	    here may lay Basalt, Mud or CrackedLava as TERRAIN -- those three are
	    Ashfall's own and Island4Builder owns every voxel of them.
	  * Part Sandstone renders mauve-grey under this place's sky whatever colour
	    it is painted -- Island2Builder measured that and converts its whole
	    pyramid to Concrete at the end of its build. Nothing here uses it.
	  * Neon stays at Transparency 0. Above zero it renders near-black under
	    Future lighting, which is the opposite of a glow -- and this island is
	    lit by glowing things, so it is the rule that matters most here. Every
	    lava surface below is a SOLID Neon slab of a dimmed colour with an
	    optional translucent SmoothPlastic shell over it, never a see-through
	    Neon shell.

	This module requires nothing. It is deliberately standalone: it is built at
	the same time as its own caller, and a require() edge between two half-written
	modules is a load-order argument nobody needs to have.
]]

local Props = {}

local ServerStorage = game:GetService("ServerStorage")

local V3 = Vector3.new
local RGB = Color3.fromRGB

----------------------------------------------------------------
-- PALETTE
----------------------------------------------------------------
--[[
	One palette for the whole area, exported so the builder's camp and these props
	cannot drift apart. Two rules set the numbers, and they are the opposite pair
	to the cove's:

	* NOTHING GOES NEAR BLACK. The instinct on a volcanic island is to paint
	  everything the colour of the sand, and the sand is tinted (56,50,52). A prop
	  at that value standing on it has no silhouette at all -- it is a hole in the
	  frame. `basalt` is the DARKEST thing in this table at (74,68,76), a clear
	  step above the ground it stands on, and every rock in the island is that or
	  lighter. The one exception is `obsidian`, which is allowed to be nearly
	  black because it is glass and reads by its highlight rather than by its tone.
	* THE ONLY SATURATED COLOURS ARE HOT. Ash, rock, timber and canvas are all
	  desaturated greys and browns; ember, sulphur and glow are the only three
	  entries with any chroma in them. That is what makes a torch or a lava seam
	  read from four hundred studs on an island where everything else is grey --
	  and it is why adding a fourth bright colour here would quietly cost the
	  first three most of their punch.

	`frond` is deliberately a dark, blue-leaning green. Tropical vegetation on
	black sand under a warm grade goes acid-yellow if it is painted the friendly
	green a palm wants to be, and sparse planting is the brief -- six dark trees
	read as "this place barely supports life" where six bright ones read as a park.
]]
Props.PALETTE = {
	basalt      = RGB(74, 68, 76),     -- the rock everything is made of
	basaltPale  = RGB(112, 106, 112),  -- sun-bleached rock, upper faces
	obsidian    = RGB(28, 26, 34),     -- volcanic glass: spires, shards, blades
	ash         = RGB(150, 144, 144),  -- ash, pumice, dust
	ashPale     = RGB(196, 190, 186),  -- the lightest value in the area
	ember       = RGB(255, 122, 42),   -- lava, the signature
	emberDeep   = RGB(198, 56, 24),    -- cooling lava, the shadow side of a flow
	glow        = RGB(255, 198, 108),  -- torch and lantern light
	sulphur     = RGB(226, 198, 84),   -- vent crust, warning paint
	frond       = RGB(56, 112, 76),    -- palm and fern green, kept dark
	timber      = RGB(104, 76, 54),    -- the camp's scorched driftwood timber
	canvas      = RGB(206, 190, 164),  -- tent cloth, awnings, sail
	rope        = RGB(172, 144, 100),
	iron        = RGB(104, 104, 112),  -- fittings, braziers, rails
}
local C = Props.PALETTE

-- Shades are DERIVED, never named. Adding a fifteenth colour called
-- "timberDark" is how a palette quietly stops being the palette.
local function dk(c, f)
	return c:Lerp(C.obsidian, f or 0.3)
end
local function lt(c, f)
	return c:Lerp(C.ashPale, f or 0.32)
end
Props.dk, Props.lt = dk, lt

----------------------------------------------------------------
-- Materials and shapes
----------------------------------------------------------------
--[[
	Slate is the house material for Ashfall's rock and SmoothPlastic for
	everything people made. Slate's grain is fine, dark and directionless, which
	is as close as this engine's part materials get to basalt -- and unlike
	terrain Slate (which is the Dunes' and is tinted globally) a PART's Slate is
	untinted and free to be any colour.

	Concrete is the one other grainy material allowed in, on ash and pumice, where
	its coarser tooth is the difference between volcanic grit and painted foam.
]]
local SMOOTH = Enum.Material.SmoothPlastic
local SLATE = Enum.Material.Slate
local CONCRETE = Enum.Material.Concrete
local WOOD = Enum.Material.Wood
local PLANKS = Enum.Material.WoodPlanks
local FABRIC = Enum.Material.Fabric
local METAL = Enum.Material.Metal
local NEON = Enum.Material.Neon
local GLASS = Enum.Material.Glass

-- A Part with Shape = Cylinder runs along its LOCAL X, so every upright cylinder
-- in this file is written as Size(height, dia, dia) and turned by UPRIGHT. Miss
-- this and a torch post lies down in the sand looking like a dropped log.
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))

local SOFT = { CanCollide = false }
local BALL = { Shape = Enum.PartType.Ball }
local BALLSOFT = { Shape = Enum.PartType.Ball, CanCollide = false }
local CYL = { Shape = Enum.PartType.Cylinder }
local CYLSOFT = { Shape = Enum.PartType.Cylinder, CanCollide = false }
local WEDGE = { Shape = Enum.PartType.Wedge, CanCollide = false }
local CORNER = { Shape = Enum.PartType.CornerWedge, CanCollide = false }
local GHOST = { Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false }

local function ex(a, b)
	local t = {}
	for k, v in pairs(a) do
		t[k] = v
	end
	if b then
		for k, v in pairs(b) do
			t[k] = v
		end
	end
	return t
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
	p.Color = colour or C.basalt
	p.Material = material or SMOOTH
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

-- A part placed in some base frame's LOCAL space. Everything about a prop is
-- described relative to its own origin, so the whole thing can be moved or
-- turned by changing one CFrame instead of forty numbers.
local function lp(parent, name, base, size, offset, colour, material, extra)
	return P(parent, name, size, base * offset, colour, material, extra)
end

local function model(parent, name): Model
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

local function light(part: BasePart, colour: Color3, range: number, brightness: number)
	local l = Instance.new("PointLight")
	l.Color = colour
	l.Range = range
	l.Brightness = brightness
	-- Shadows off, always. Under Future lighting a shadow-casting point light is
	-- a whole extra shadow map, and this island wants a lot of small warm lights
	-- rather than a few expensive ones.
	l.Shadows = false
	l.Parent = part
	return l
end
Props.light = light

----------------------------------------------------------------
-- THE TOOLBOX KIT
----------------------------------------------------------------
-- Resolved once, warned about once, and never assumed. Every caller below
-- checks for nil and builds primitives instead -- see the header.
local assets = ServerStorage:FindFirstChild("VolcanoAssets")
if not assets then
	warn("[Ashfall] ServerStorage.VolcanoAssets is missing -- rocks and trees will be "
		.. "built from primitives. See the header of Island4Props.")
end

-- One clone of a kit mesh, already anchored, sized to `height` on its TALLEST
-- axis and painted. Returns nil if the kit is absent, which is the signal every
-- caller uses to draw its own fallback.
local function kit(parent, name: string, height: number, colour: Color3?, material: Enum.Material?): BasePart?
	local src = assets and assets:FindFirstChild(name)
	if not (src and src:IsA("BasePart")) then
		return nil
	end
	local p = src:Clone()
	local s = p.Size
	local biggest = math.max(s.X, s.Y, s.Z)
	if biggest > 0.001 then
		p.Size = s * (height / biggest)
	end
	p.Anchored = true
	if colour then
		p.Color = colour
	end
	if material then
		p.Material = material
	end
	p.Parent = parent
	return p
end
Props.kit = kit

-- Sit a kit mesh on the ground of a local frame. MeshPart CFrames are their
-- bounding-box centres, so "on the ground" is half its own height up -- measured
-- off the clone rather than assumed, because the kit is scaled per call.
local function seat(p: BasePart, base: CFrame, offset: CFrame, sink: number)
	p.CFrame = base * offset * CFrame.new(0, p.Size.Y * 0.5 - (sink or 0), 0)
	return p
end

----------------------------------------------------------------
-- ROCK  --  1 part with the kit, 4 without
----------------------------------------------------------------
--[[
	One lump of basalt, sat on the ground and turned at random by the caller.

	`kind` picks the silhouette: "boulder" is tall and chunky (cliff dressing,
	arch legs, sea stacks), "rock" is a mid lump (the tideline), "low" is a flat
	slab (scattered lava rock on the sand). They are three different meshes rather
	than three scales of one, because a boulder scaled down still reads as a
	boulder somebody shrank.

	SUNK A QUARTER OF ITS HEIGHT, always. A rock resting exactly on a surface
	reads as a prop set down on the ground; a rock with its bottom quarter buried
	reads as part of it -- and on terrain it also hides the fact that the ground
	under it is not flat.
]]
local ROCK_MESH = { boulder = "Boulder", rock = "Rock", low = "RockLow" }

function Props.rock(parent, cf: CFrame, height: number, kind: string?, tone: Color3?): Model
	local m = model(parent, "Rock")
	local colour = tone or C.basalt
	local mesh = kit(m, ROCK_MESH[kind or "rock"] or "Rock", height, colour, SLATE)
	if mesh then
		mesh.Name = "RockBody"
		mesh.CanCollide = true
		seat(mesh, cf, CFrame.new(), height * 0.25)
		return m
	end

	-- Fallback: three overlapping squashed balls. Not as good and it does not
	-- have to be -- it only ever runs in a place with no VolcanoAssets folder.
	local h = height
	lp(m, "RockBody", cf, V3(h * 1.05, h * 0.8, h * 0.95), CFrame.new(0, h * 0.28, 0),
		colour, SLATE, BALL)
	lp(m, "RockBody", cf, V3(h * 0.7, h * 0.55, h * 0.75),
		CFrame.new(h * 0.32, h * 0.16, -h * 0.2), dk(colour, 0.18), SLATE, BALLSOFT)
	lp(m, "RockBody", cf, V3(h * 0.55, h * 0.5, h * 0.6),
		CFrame.new(-h * 0.3, h * 0.2, h * 0.24), lt(colour, 0.12), SLATE, BALLSOFT)
	return m
end

----------------------------------------------------------------
-- ROCK FORMATION  --  4 to 7 parts
----------------------------------------------------------------
--[[
	A cluster: one big rock with two to four smaller ones fallen around it. The
	single most-used prop on the island, because "dark volcanic rock formations,
	cliffs, boulders and jagged terrain throughout" is most of the brief and a
	lone rock never reads as a formation.

	The hero is placed FIRST and the debris is placed around it on a circle whose
	radius comes off the hero's own height, so the whole thing scales as one shape
	rather than as a big rock with a fixed ring of pebbles.
]]
function Props.rockFormation(parent, cf: CFrame, scale: number, seed: number?): Model
	local m = model(parent, "RockFormation")
	local rng = Random.new(seed or 0)
	local s = scale or 1

	Props.rock(m, cf, 13 * s, "boulder", C.basalt)
	local n = rng:NextInteger(2, 4)
	for i = 1, n do
		local a = rng:NextNumber(0, math.pi * 2)
		local d = (6 + rng:NextNumber(0, 5)) * s
		local h = (3.5 + rng:NextNumber(0, 4)) * s
		local kind = (i % 2 == 0) and "low" or "rock"
		Props.rock(m, cf * CFrame.new(math.cos(a) * d, 0, math.sin(a) * d)
			* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), h, kind,
			(i % 3 == 0) and lt(C.basalt, 0.18) or C.basalt)
	end
	return m
end

----------------------------------------------------------------
-- OBSIDIAN SPIRE  --  5 to 8 parts
----------------------------------------------------------------
--[[
	A fan of black glass blades leaning out of the ground.

	THE ONE PLACE NEAR-BLACK IS ALLOWED, and the reason is in the palette note:
	obsidian reads by its HIGHLIGHT rather than by its tone, so it needs a
	reflective material and a hard edge, not a lighter colour. Glass at
	Reflectance 0.35 against a grey sky gives every blade a bright rim, which is
	what separates a spire from a black hole in the frame.

	Not Neon, and not transparent: see the header. These are solid.
]]
function Props.obsidianSpire(parent, cf: CFrame, scale: number, seed: number?): Model
	local m = model(parent, "ObsidianSpire")
	local rng = Random.new(seed or 0)
	local s = scale or 1

	-- a low rubble skirt, so the blades come OUT of something
	lp(m, "Rubble", cf, V3(7.5 * s, 2.2 * s, 6.6 * s), CFrame.new(0, 0.5 * s, 0),
		dk(C.basalt, 0.2), SLATE, BALLSOFT)

	local blades = rng:NextInteger(4, 6)
	for i = 1, blades do
		local a = (i / blades) * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
		local h = (7 + rng:NextNumber(0, 9)) * s
		local lean = rng:NextNumber(0.08, 0.26)
		local w = (0.9 + rng:NextNumber(0, 0.9)) * s
		--[[
			NOT GLASS AT 0.35, AND THE NOTE ABOVE IS WHY IT LOOKED WRONG.

			That note reasons about "a grey sky". Ashfall's sky is bright blue, and a
			Reflectance of 0.35 does not give a blade a bright RIM against a bright
			sky -- it mirrors the whole sky across the whole face. Every spire on the
			island rendered as a pale blue-grey slab: from any distance a row of
			concrete gravestones standing on black ash.

			Obsidian is glossy, not mirrored. SmoothPlastic at 0.1 keeps the sheen
			that separates it from the matte basalt around it and lets the near-black
			colour actually be near-black.
		]]
		lp(m, "Blade", cf,
			V3(w, h, w * 0.55),
			CFrame.new(math.cos(a) * 2.2 * s, h * 0.45, math.sin(a) * 2.2 * s)
				* CFrame.Angles(math.sin(a) * lean, -a, -math.cos(a) * lean),
			C.obsidian, SMOOTH, { Reflectance = 0.1, CanCollide = false })
	end
	return m
end

----------------------------------------------------------------
-- PALM  --  1 part with the kit, 9 without
----------------------------------------------------------------
--[[
	The island's only real vegetation, and there is deliberately not much of it.

	Two meshes: "tall" is a bare stem with a small crown (the windward shore, the
	ridge line) and "bushy" is a full one (the camp, the sheltered south side).
	Mixing the two at a roughly 1:1 ratio is what stops a grove reading as one
	tree copy-pasted, which four evenly spaced identical palms always does.

	The mesh keeps its own texture -- green fronds over a brown stem -- and is NOT
	repainted. Tinting a MeshPart multiplies its texture, so pulling these toward
	the palette's dark `frond` would have crushed the trunk to black along with
	the leaves. The grade does that job for the whole island at once and does it
	better.
]]
function Props.palm(parent, cf: CFrame, height: number, variant: string?): Model
	local m = model(parent, "Palm")
	local tall = (variant == "tall")
	local mesh = kit(m, tall and "PalmTall" or "PalmBushy", height)
	if mesh then
		mesh.Name = "PalmBody"
		-- The canopy is not something to walk into and the stem is too thin to
		-- collide usefully; a palm you can brush past beats one that stops you
		-- dead ten studs from its trunk because its bounding box is 22 wide.
		mesh.CanCollide = false
		mesh.CastShadow = true
		seat(mesh, cf, CFrame.new(), height * 0.02)
		return m
	end

	-- Fallback: a leaning stem with six fronds.
	local h = height
	local lean = 0.09
	for i = 0, 3 do
		local t = i / 3
		lp(m, "Stem", cf, V3(h * 0.28, h * 0.075 * (1 - t * 0.35), h * 0.28 * (1 - t * 0.3)),
			CFrame.new(math.sin(lean) * h * t * 0.5, h * (0.12 + t * 0.24), 0)
				* CFrame.Angles(0, 0, math.pi * 0.5 + lean),
			(i % 2 == 0) and C.timber or dk(C.timber, 0.2), WOOD, CYLSOFT)
	end
	local topX = math.sin(lean) * h * 0.5
	for i = 1, 6 do
		local a = (i / 6) * math.pi * 2
		lp(m, "Frond", cf, V3(h * 0.42, h * 0.03, h * 0.16),
			CFrame.new(topX + math.cos(a) * h * 0.2, h * 0.86, math.sin(a) * h * 0.2)
				* CFrame.Angles(0, -a, -0.34),
			(i % 2 == 0) and C.frond or dk(C.frond, 0.22), FABRIC, SOFT)
	end
	return m
end

----------------------------------------------------------------
-- SULPHUR CRUST  --  3 to 5 parts
----------------------------------------------------------------
--[[
	A stain of yellow crust round a vent, laid flat on the ground.

	THIS IS ON THE ISLAND FOR ITS COLOUR AND THE PALETTE ALREADY HELD IT. Ashfall
	runs basalt, ash, obsidian and iron -- four greys -- with ember for the lava
	and frond for the palms, and at any distance from a flow the whole island
	resolves to one flat grey. `sulphur` has been sitting in the palette unused;
	it is the one colour a volcano can put on the ground without inventing
	anything, and a scatter of these is the cheapest way to break the grey.

	FLAT AND OVERLAPPING, never a single disc: a stain has no edge you can trace.
	Each slab is turned to its own angle and sunk so only its top face shows, so
	the patch reads as ground that has changed colour rather than as litter.
]]
function Props.sulphurCrust(parent, cf: CFrame, span: number, seed: number?): Model
	local m = model(parent, "SulphurCrust")
	local rng = Random.new(seed or 0)
	local s = span or 8

	--[[
		PULLED MOST OF THE WAY BACK TO THE ROCK, and the first cut is why.

		At full `sulphur` these were bright flat lemon rectangles lying on black
		basalt -- they read as sticky notes somebody had dropped, not as ground
		that had changed colour. A stain is a SHIFT in the surface under it, so
		each slab starts 55% of the way from sulphur toward ash and moves again
		per-slab: a patch made of one colour is a decal however dull you make it.
	]]
	local base = C.sulphur:Lerp(C.ash, 0.55)
	for i = 1, rng:NextInteger(3, 5) do
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(0, s * 0.34)
		local w = s * rng:NextNumber(0.5, 0.92)
		-- Rustier at the rim, and every slab a little different from its neighbour.
		local tone = base
			:Lerp(C.ember, (d / math.max(s * 0.34, 0.01)) * 0.22)
			:Lerp(C.basalt, rng:NextNumber(0, 0.3))
		lp(m, "Crust", cf, V3(w, 0.26, w * rng:NextNumber(0.6, 1.0)),
			CFrame.new(math.cos(a) * d, -0.02, math.sin(a) * d)
				* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
			tone, CONCRETE, ex(SOFT, { CanQuery = false, CanTouch = false, CastShadow = false }))
	end
	return m
end

----------------------------------------------------------------
-- BASALT COLUMNS  --  5 to 8 parts
----------------------------------------------------------------
--[[
	A cluster of columnar joints -- the stacked hexagonal pillars lava leaves when
	it cools slowly. The most recognisable rock a volcanic island has, and this
	one had none of it.

	SIX SIDES, AND THAT IS WHAT MAKES IT READ. A cylinder cluster is a bundle of
	pipes; the hexagon is the whole tell, so each column is a Part with six faces
	approximated by three crossed blocks -- cheaper than a mesh and, at the size
	these stand, indistinguishable from one.

	HEIGHTS STEP RATHER THAN TAPER. Real columns snap off at different levels, so
	the cluster is sorted tall-to-short from a random centre rather than smoothed
	into a cone, and the tops are paler where the weather has got at them.
]]
function Props.basaltColumns(parent, cf: CFrame, scale: number, seed: number?): Model
	local m = model(parent, "BasaltColumns")
	local rng = Random.new(seed or 0)
	local s = scale or 1
	local n = rng:NextInteger(5, 8)

	for i = 1, n do
		local a = (i / n) * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
		local d = (i == 1) and 0 or rng:NextNumber(1.6, 4.2) * s
		local h = rng:NextNumber(5, 13) * s
		local w = rng:NextNumber(1.5, 2.4) * s
		local lean = rng:NextNumber(-0.06, 0.06)
		local at = CFrame.new(math.cos(a) * d, 0, math.sin(a) * d)
			* CFrame.Angles(lean, rng:NextNumber(0, 6.28), lean)

		-- Three crossed blocks at 60 degrees: a hexagonal prism for the price of
		-- three parts, and only the outer one needs collision.
		for k = 0, 2 do
			lp(m, "Column", cf, V3(w, h, w * 0.58),
				at * CFrame.new(0, h * 0.5 - 1, 0) * CFrame.Angles(0, k * math.pi / 3, 0),
				(i % 3 == 0) and dk(C.basalt, 0.22) or C.basalt, SLATE,
				(k == 0) and nil or ex(SOFT, { CanQuery = false, CanTouch = false }))
		end
		-- The broken top, paler and set a hair proud so the column has a cap
		-- rather than a cut.
		lp(m, "ColumnTop", cf, V3(w * 1.04, 0.5, w * 0.6),
			at * CFrame.new(0, h - 1.1, 0),
			lt(C.basaltPale, 0.18), CONCRETE, ex(SOFT, { CanQuery = false, CanTouch = false }))
	end
	return m
end

----------------------------------------------------------------
-- CHARRED LOG  --  1 part with the kit, 3 without
----------------------------------------------------------------
-- Driftwood that came ashore and then sat in the sun on black sand. Laid flat
-- and half buried, which is the only way a log on a beach ever looks.
function Props.charredLog(parent, cf: CFrame, length: number): Model
	local m = model(parent, "CharredLog")
	local mesh = kit(m, "DeadLog", length, dk(C.timber, 0.55), WOOD)
	if mesh then
		mesh.Name = "LogBody"
		mesh.CanCollide = true
		seat(mesh, cf, CFrame.new(), mesh.Size.Y * 0.35)
		return m
	end
	lp(m, "LogBody", cf, V3(length, length * 0.2, length * 0.2),
		CFrame.new(0, length * 0.06, 0), dk(C.timber, 0.55), WOOD, CYL)
	lp(m, "Branch", cf, V3(length * 0.35, length * 0.09, length * 0.09),
		CFrame.new(length * 0.3, length * 0.12, length * 0.1) * CFrame.Angles(0, 0.6, 0.3),
		dk(C.timber, 0.6), WOOD, CYLSOFT)
	return m
end

-- A burnt stump. 1 part with the kit, 2 without.
-- 0.72 rather than 0.5: at half-way to obsidian this was still a mid-brown, and
-- a mid-brown stump on black ash reads as a fresh cut rather than as something
-- the mountain got to.
function Props.stump(parent, cf: CFrame, height: number): Model
	local m = model(parent, "Stump")
	local char = dk(C.timber, 0.72)
	local mesh = kit(m, "Stump", height, char, WOOD)
	if mesh then
		mesh.Name = "StumpBody"
		seat(mesh, cf, CFrame.new(), height * 0.2)
		return m
	end
	lp(m, "StumpBody", cf, V3(height * 0.9, height, height * 0.9),
		CFrame.new(0, height * 0.45, 0), char, WOOD, CYL)
	return m
end

----------------------------------------------------------------
-- BURNT TREE  --  6 to 8 parts
----------------------------------------------------------------
--[[
	A dead trunk with a few broken limbs and no canopy at all.

	IT REPLACES THE PALMS OUT ON THE OPEN ASH, and the reason is the ground they
	stand on. A green tropical palm is the right prop at the LANDING, where people
	live and water things; out on a plain of black volcanic grit it is the one
	object on the island that has obviously not been through what the island has
	been through. A burnt trunk says "something grew here" without contradicting
	the rest of the frame.

	NO FOLIAGE, ON PURPOSE. A dead tree IS its branching, so the whole budget goes
	on three or four limbs at real angles rather than on leaves to hang off them.

	Cylinders, so Size is (LENGTH, diameter, diameter) and the part is stood up by
	rotating pi/2 about Z -- the same idiom the palm fallback uses, and the reason
	it is written that way there is the same reason it is written that way here.
]]
function Props.burntTree(parent, cf: CFrame, height: number, seed: number?): Model
	local m = model(parent, "BurntTree")
	local rng = Random.new(seed or 0)
	local h = height or 14
	local lean = rng:NextNumber(-0.1, 0.1)
	local char = dk(C.timber, 0.68)

	for i = 0, 2 do
		local t = i / 3
		local segH = h / 3
		local dia = h * (0.1 - t * 0.028)
		lp(m, "Trunk", cf, V3(segH * 1.06, dia, dia),
			CFrame.new(math.sin(lean) * segH * i, segH * (i + 0.5), 0)
				* CFrame.Angles(0, 0, math.pi * 0.5 + lean),
			(i == 0) and char or char:Lerp(C.obsidian, 0.2), WOOD, CYLSOFT)
	end

	-- Broken limbs, and they point UP. A branch that came through a fire is a
	-- stub; a stub that droops reads as a dead palm frond, which is the thing
	-- this prop exists to stop looking like.
	local limbs = rng:NextInteger(3, 5)
	for i = 1, limbs do
		local a = (i / limbs) * math.pi * 2 + rng:NextNumber(-0.5, 0.5)
		local up = rng:NextNumber(0.5, 0.85)
		local len = h * rng:NextNumber(0.22, 0.36)
		local y = h * rng:NextNumber(0.5, 0.88)
		lp(m, "Limb", cf, V3(len, h * 0.045, h * 0.045),
			CFrame.new(math.cos(a) * len * 0.3, y, math.sin(a) * len * 0.3)
				* CFrame.Angles(0, -a, 0) * CFrame.Angles(0, 0, math.pi * 0.5 - up),
			char:Lerp(C.obsidian, 0.32), WOOD, CYLSOFT)
	end
	return m
end

----------------------------------------------------------------
-- PUMICE CLUSTER  --  8 or 9 parts
----------------------------------------------------------------
--[[
	The low dressing on the ash plain: a drift of pumice and scoria, angular and
	half-buried, with a leaning shard on about a third of them.

	IT REPLACED A FERN, AND THE FERN WAS THE WRONG OBJECT ENTIRELY. What stood
	here was `emberFern` -- seven flat blades fanned up out of the ground. It was
	painted `frond` green first, which on black volcanic grit read as a piece of
	folded paper somebody had dropped; repainting it rust-brown fixed the COLOUR
	and left the SHAPE, and the shape is a broad-leafed plant. Forty-odd
	broad-leafed plants scattered across an ash field under an active volcano is
	the most out-of-place thing that was on this island, in any paint. A plain
	like this one is not sparsely planted -- it is covered in what the mountain
	threw at it, and that is what this puts there instead.

	NO CHROMA AT ALL, deliberately. Every part is somewhere between `ash` and
	`basaltPale`: lighter than the ground it sits on, which is the silhouette
	rule in the PALETTE note, and completely colourless, which leaves ember and
	sulphur as the only saturated things anywhere on the island. Adding a fourth
	bright colour out here would cost the torches and the lava most of their
	punch, and there are more of these than of anything else.

	ANGULAR, TILTED, AND NOTHING COLLIDABLE. Shattered rock has flat faces meeting
	at edges, so these are turned on all three axes -- a box that is plumb and
	level is furniture, a box that is neither is stone. Non-collidable because they
	sit ankle-height in the middle of the field players RAKE, and rubble you have
	to walk around is worse than no rubble.

	HOW MUCH TILT, AND IT IS MORE THAN IT SOUNDS. The first cut of this used about
	eight degrees on each axis and it came out as a stack of packing crates on a
	concrete pad: at that angle the eye still reads every face as level or plumb
	and quietly corrects the rest away. These run 12 to 25 degrees on BOTH axes on
	top of a free yaw, so no two faces in a pile are parallel and none of them line
	up with the ground. Two of the five are Wedges and one is a CornerWedge, which
	is the only way to get a sloped face and a point into a silhouette that blocks
	alone can only build out of steps.

	AND THERE IS NO PLINTH UNDER IT. The first cut sat the chunks on one 7-stud
	slab of pale ash meant to read as a wind-heaped drift. What it actually read as
	was a poured concrete pad with rubble stacked on it -- a big rectangle lying
	dead level on the ground is the single most artificial shape available. The
	drift is three loose CHIPS lying flat around the base instead: same job, no
	straight edge anywhere.
]]
function Props.pumiceCluster(parent, cf: CFrame, scale: number, seed: number?): Model
	local m = model(parent, "PumiceCluster")
	local rng = Random.new(seed or 0)
	local s = scale or 1

	-- shape, w, h, d, x, z, yaw, tiltX, tiltZ. y is derived rather than listed:
	-- each chunk's centre sits at 0.3 of its own height, so a fifth of it is under
	-- the ash before the tilt drops a corner further, and none of them can show
	-- the flat underside of a box.
	local spec = {
		{ SOFT, 4.0, 3.0, 3.6, 0.0, 0.0, 0.40, 0.30, -0.34 },
		{ WEDGE, 4.2, 2.8, 3.6, -2.0, 1.2, 1.90, -0.30, 0.28 },
		{ CORNER, 3.2, 2.4, 3.2, 2.1, -1.1, 3.10, 0.26, 0.30 },
		{ WEDGE, 2.6, 1.8, 2.4, 0.8, 2.3, 5.00, -0.28, -0.32 },
		{ SOFT, 1.9, 1.3, 1.7, -1.9, -1.9, 2.40, 0.32, 0.22 },
	}
	for i, r in ipairs(spec) do
		local h = r[3] * rng:NextNumber(0.85, 1.15)
		lp(m, "Pumice" .. i, cf, V3(r[2] * s, h * s, r[4] * s),
			CFrame.new((r[5] + rng:NextNumber(-0.4, 0.4)) * s, h * 0.3 * s,
				(r[6] + rng:NextNumber(-0.4, 0.4)) * s)
				* CFrame.Angles(r[8] + rng:NextNumber(-0.12, 0.12),
					r[7] + rng:NextNumber(-0.4, 0.4),
					r[9] + rng:NextNumber(-0.12, 0.12)),
			--[[
				SLATE AT PROPS.ROCK'S OWN TONE, and it took three passes to end up
				there. Pumice is the pale frothy rock, so the obvious build was pale
				Concrete -- `ash` upward on the palette's grainy material, which is
				what the file header reserves Concrete for. Forty of them rendered
				NEAR-WHITE on ground tinted (56,50,52) and the plain looked like a
				quarry spoil heap. Dropping the colour to basaltPale did not fix it,
				because the colour was only half the problem: side by side on one
				swatch strip, Concrete renders PALE AND SMOOTH and Slate renders DARK
				AND ROUGH at the very same Color3.

				So a swatch is no guide here and neither is the Color3 -- which is the
				same lesson Island3Props wrote down for its boulders under this place's
				Brightness 3.10 and bloom. What IS a guide is Props.rock: Slate at
				`basalt`, occasionally `lt(basalt, 0.18)`, on this island since it was
				built and correct at every distance in a live frame. This is exactly
				that material and exactly that range. The label loses -- pumice is the
				pale frothy rock and this is painted the same as the basalt beside it
				-- and the frame wins, which is the right way round.
			]]
			lt(C.basalt, rng:NextNumber(0, 0.18)), SLATE, r[1])
	end

	-- Three chips lying flat around the base -- the debris that came off the pile.
	-- Half-buried and barely tilted, because a chip that stands proud is another
	-- chunk and the pile already has five.
	for i = 1, 3 do
		local a = rng:NextNumber(0, 6.28)
		local d = rng:NextNumber(2.4, 3.8)
		lp(m, "Chip" .. i, cf, V3(rng:NextNumber(1.3, 2.2) * s, 0.7 * s, rng:NextNumber(1.0, 1.7) * s),
			CFrame.new(math.cos(a) * d * s, 0.16 * s, math.sin(a) * d * s)
				* CFrame.Angles(rng:NextNumber(-0.1, 0.1), rng:NextNumber(0, 6.28),
					rng:NextNumber(-0.1, 0.1)),
			lt(C.basalt, rng:NextNumber(0.1, 0.3)), SLATE, SOFT)
	end

	-- One shard on about a third of them, leaning out of the pile -- and it is a
	-- BLADE, thin on one axis, not a post. Everything above is under three studs
	-- tall, and a plain dressed entirely in things below knee height still reads
	-- as flat from any distance.
	if rng:NextNumber() < 0.34 then
		local h = rng:NextNumber(3.6, 5.4)
		lp(m, "Shard", cf, V3(0.8 * s, h * s, 2.2 * s),
			CFrame.new(rng:NextNumber(-1.2, 1.2) * s, h * 0.36 * s, rng:NextNumber(-1.2, 1.2) * s)
				* CFrame.Angles(rng:NextNumber(-0.16, 0.16), rng:NextNumber(0, 6.28),
					rng:NextNumber(0.2, 0.45)),
			-- Darker than the pile it stands in, not lighter. Slate's grain runs warm,
			-- so a shard painted up toward basaltPale photographs BROWN against grey
			-- pumice and reads as a plank someone left there.
			dk(C.basalt, rng:NextNumber(0, 0.25)), SLATE, SOFT)
	end
	return m
end

----------------------------------------------------------------
-- LAVA POOL  --  8 parts, 1 light, 1 emitter
----------------------------------------------------------------
--[[
	A pond of molten rock in a rock rim. `cf` is the LAVA SURFACE, not the ground
	-- see the header.

	THREE COURSES AND THE MIDDLE ONE IS THE WHOLE TRICK. A single bright Neon disc
	reads as a sticker: flat, edgeless, and exactly as bright in its middle as at
	its rim, which nothing hot ever is. So it is

	  crust   a dark, nearly-cooled slab a hair PROUD of the lava, broken into a
	          few plates with gaps between them
	  lava    solid Neon at Transparency 0 (see the header), the dimmed ember
	          rather than the bright one, filling the gaps
	  rim     a ring of rock a stud above the surface, so the pool sits IN
	          something

	The light is what actually lights the ground around it, and it is the reason
	the pool count on this island is capped: a PointLight per pool at Range 60 is
	cheap, forty of them overlapping is not.
]]
function Props.lavaPool(parent, cf: CFrame, radius: number, seed: number?): Model
	local m = model(parent, "LavaPool")
	local rng = Random.new(seed or 0)
	local r = radius

	--[[
		The molten body. Named so Island4_Client can find every pool on the island
		without the builder having to publish a list.

		A Part cylinder runs along its LOCAL X, so a horizontal disc is Size
		(thickness, diameter, diameter) turned by UPRIGHT -- written in one
		expression rather than made flat and then corrected, because a builder that
		overwrites its own CFrame twice is a builder somebody will half-edit later.
	]]
	local lava = lp(m, "LavaSurface", cf, V3(0.6, r * 2, r * 2),
		CFrame.new(0, -0.3, 0) * UPRIGHT, C.emberDeep, NEON, ex(CYLSOFT, { CanQuery = false }))

	-- Cooled plates floating on it. Four to six, each a squashed slab turned at
	-- its own angle so the gaps between them are irregular.
	for i = 1, rng:NextInteger(4, 6) do
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(0, r * 0.55)
		local w = r * rng:NextNumber(0.5, 0.9)
		lp(m, "Crust", cf, V3(w, 0.34, w * rng:NextNumber(0.6, 1.0)),
			CFrame.new(math.cos(a) * d, 0.12, math.sin(a) * d)
				* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
			dk(C.basalt, 0.35), SLATE, SOFT)
	end

	-- The rim: eight rocks round the edge rather than a torus, so it is broken.
	for i = 1, 8 do
		local a = (i / 8) * math.pi * 2 + rng:NextNumber(-0.18, 0.18)
		local h = rng:NextNumber(1.6, 3.2)
		lp(m, "Rim", cf, V3(r * 0.5, h, r * 0.42),
			CFrame.new(math.cos(a) * (r + r * 0.12), h * 0.18, math.sin(a) * (r + r * 0.12))
				* CFrame.Angles(0, -a, 0),
			dk(C.basalt, 0.15), SLATE, BALLSOFT)
	end

	light(lava, C.ember, math.clamp(r * 3.2, 22, 60), 1.6)

	--[[
		Model:GetBoundingBox() with no PrimaryPart orients itself off whichever part
		it happens to find first, and the first part here is the disc -- which is
		turned on its side, because that is how a Part cylinder is made horizontal.
		Measured through that frame a fifteen-stud pool comes back as thirty-six
		studs tall and three wide, which is how an island audit ends up reporting a
		pool buried seventeen studs in ground it is sitting a stud and a half over.

		So the frame is named, and it is named as a part that is only ever YAWED --
		one of the crust plates -- so the box comes out upright.
	]]
	m.PrimaryPart = m:FindFirstChild("Crust") or lava

	-- Embers off the surface. Server-side because an emitter is a saved instance
	-- rather than a per-frame cost -- the moving weather that DOES cost something
	-- (the ash fall, the plume, the heat shimmer) is Island4_Client's.
	local e = Instance.new("ParticleEmitter")
	e.Name = "Embers"
	e.Texture = "rbxassetid://241650934"
	e.Color = ColorSequence.new(C.ember, C.emberDeep)
	e.LightEmission = 1
	e.LightInfluence = 0
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Lifetime = NumberRange.new(1.6, 3.4)
	e.Rate = math.clamp(r * 0.8, 3, 14)
	e.Speed = NumberRange.new(4, 11)
	e.SpreadAngle = Vector2.new(22, 22)
	e.Acceleration = Vector3.new(0, 5, 0)
	e.EmissionDirection = Enum.NormalId.Right   -- the disc's own axis, after UPRIGHT
	e.Parent = lava

	return m
end

----------------------------------------------------------------
-- LAVA SEAM  --  1 part
----------------------------------------------------------------
--[[
	ONE DISC OF A FLOW'S RIBBON, laid flat against the slope it runs down. Given
	as a separate builder rather than a thin lavaPool because a stream is a
	HUNDRED of these and none of them may carry a light or an emitter -- see the
	note on the stream loop in Island4Builder.

	IT WAS A BOX, AND A CHAIN OF BOXES IS WHAT MADE THE STREAMS LOOK PAINTED ON.
	V3(width, 0.5, length), one per path segment, turned to face down the flow.
	Three faults, all of them visible from the camp:

	  A BOX HAS CORNERS TO MITRE. At every bend the outer pair opened a wedge of
	  bare rock and the inner pair stacked into a lump, so a flow read as a row of
	  separate orange polygons with kinks between them rather than as one stream.

	  A BOX HAS SQUARE ENDS. The last one in a chain stopped dead. So did the
	  first. Lava does neither.

	  A BOX LAID BY lookAt() BANKS ON WORLD UP. On a forty-degree face every slab
	  stood on an edge and stepped down the hill instead of lying along it.

	A DISC HAS NO CORNERS. Spaced at less than half its own diameter the chain is
	one continuous stroke with a rounded edge; at a bend it simply follows, because
	there is no join to open up. The BUILDER conforms each one to the terrain
	normal and tapers the width at both ends -- see the ribbon note over there.

	Cylinder, so the axis is local X: Size is (thickness, diameter, diameter) and
	the caller's CFrame must put its RightVector along the surface normal.
]]
function Props.lavaSeam(parent, cf: CFrame, width: number, thickness: number, hot: number): BasePart
	local tone = C.emberDeep:Lerp(C.ember, math.clamp(hot or 0.5, 0, 1))
	return P(parent, "LavaSeam", V3(thickness or 0.5, width, width), cf, tone, NEON,
		ex(CYLSOFT, { CanQuery = false, CanTouch = false, CastShadow = false }))
end

----------------------------------------------------------------
-- FUMAROLE  --  4 parts, 1 emitter
----------------------------------------------------------------
-- A steam vent: a ring of sulphur-crusted rock with nothing in the middle and a
-- slow plume out of it. The cheapest thing on this island that says "the
-- mountain is awake", which is why they are scattered across the terraces where
-- there is no lava to carry it.
function Props.fumarole(parent, cf: CFrame, scale: number, seed: number?): Model
	local m = model(parent, "Fumarole")
	local rng = Random.new(seed or 0)
	local s = scale or 1

	for i = 1, 3 do
		local a = (i / 3) * math.pi * 2 + rng:NextNumber(-0.2, 0.2)
		lp(m, "VentLip", cf, V3(3.4 * s, 1.5 * s, 2.8 * s),
			CFrame.new(math.cos(a) * 1.9 * s, 0.4 * s, math.sin(a) * 1.9 * s)
				* CFrame.Angles(0, -a, 0),
			(i == 2) and C.sulphur:Lerp(C.basalt, 0.45) or dk(C.basalt, 0.1), SLATE, BALLSOFT)
	end

	local vent = lp(m, "VentSource", cf, V3(1.6 * s, 0.4, 1.6 * s), CFrame.new(0, 0.2, 0),
		dk(C.obsidian, 0.2), SLATE,
		{ CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })

	local e = Instance.new("ParticleEmitter")
	e.Name = "Steam"
	e.Texture = "rbxassetid://243132757"
	e.Color = ColorSequence.new(C.ashPale, C.ash)
	e.LightEmission = 0.35
	e.LightInfluence = 1
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.4 * s),
		NumberSequenceKeypoint.new(1, 7 * s),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.25, 0.62),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Lifetime = NumberRange.new(2.6, 4.4)
	e.Rate = 4
	e.Speed = NumberRange.new(5, 9)
	e.SpreadAngle = Vector2.new(14, 14)
	e.EmissionDirection = Enum.NormalId.Top
	e.Parent = vent

	return m
end

----------------------------------------------------------------
-- TIKI TORCH  --  6 parts, 1 light, 1 emitter
----------------------------------------------------------------
--[[
	The camp's lighting, and the trail markers up the mountain.

	HALF OF THEM GET A LIGHT AND ALL OF THEM GET A FLAME. Same call the cove's
	boardwalk makes for its lanterns and for the same measured reason: under
	Future lighting, overlapping point-light volumes are the expensive case, and
	the GLOW is carried by the Neon core, which costs nothing. `lit` is the
	caller's switch.
]]
function Props.tikiTorch(parent, cf: CFrame, height: number, lit: boolean?): Model
	local m = model(parent, "TikiTorch")
	local h = height or 9

	lp(m, "Post", cf, V3(h, 0.85, 0.85), CFrame.new(0, h * 0.5, 0) * UPRIGHT,
		C.timber, WOOD, CYL)
	for i = 1, 3 do
		lp(m, "Binding", cf, V3(0.3, 1.0, 1.0),
			CFrame.new(0, h * (0.5 + i * 0.11), 0) * UPRIGHT,
			C.rope, FABRIC, CYLSOFT)
	end
	-- the bowl the flame sits in
	lp(m, "Bowl", cf, V3(1.1, 2.3, 2.3), CFrame.new(0, h + 0.5, 0) * UPRIGHT,
		dk(C.iron, 0.25), METAL, CYLSOFT)

	-- Solid Neon at Transparency 0, and a bigger translucent shell would be
	-- wrong here: a flame has no shell. See the header.
	local flame = lp(m, "FlameSource", cf, V3(1.3, 2.0, 1.3), CFrame.new(0, h + 1.7, 0),
		C.glow, NEON, { CanCollide = false, CanQuery = false, CanTouch = false,
			CastShadow = false, Shape = Enum.PartType.Ball })

	local e = Instance.new("ParticleEmitter")
	e.Name = "Flame"
	e.Texture = "rbxassetid://241650934"
	e.Color = ColorSequence.new(C.glow, C.emberDeep)
	e.LightEmission = 1
	e.LightInfluence = 0
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.8),
		NumberSequenceKeypoint.new(0.4, 1.2),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Lifetime = NumberRange.new(0.5, 0.9)
	e.Rate = 16
	e.Speed = NumberRange.new(3, 6)
	e.SpreadAngle = Vector2.new(12, 12)
	e.Acceleration = Vector3.new(0, 8, 0)
	e.EmissionDirection = Enum.NormalId.Top
	e.Parent = flame

	if lit ~= false then
		light(flame, C.glow, 30, 1.5)
	end
	return m
end

----------------------------------------------------------------
-- BRAZIER  --  9 parts, 1 light
----------------------------------------------------------------
-- The bigger, standing version, for the camp square and the crater lookout. A
-- basalt bowl on three legs with coals in it rather than a flame, so the two
-- read as different objects at a distance and not as one at two scales.
function Props.brazier(parent, cf: CFrame, scale: number): Model
	local m = model(parent, "Brazier")
	local s = scale or 1
	for i = 1, 3 do
		local a = (i / 3) * math.pi * 2
		lp(m, "Leg", cf, V3(0.55 * s, 4.2 * s, 0.55 * s),
			CFrame.new(math.cos(a) * 1.5 * s, 2.1 * s, math.sin(a) * 1.5 * s)
				* CFrame.Angles(math.sin(a) * 0.12, 0, -math.cos(a) * 0.12),
			C.iron, METAL, SOFT)
	end
	lp(m, "Bowl", cf, V3(1.5 * s, 6.2 * s, 6.2 * s), CFrame.new(0, 4.5 * s, 0) * UPRIGHT,
		dk(C.basalt, 0.2), SLATE, CYL)
	lp(m, "BowlLip", cf, V3(0.5 * s, 7 * s, 7 * s), CFrame.new(0, 5.3 * s, 0) * UPRIGHT,
		C.basalt, SLATE, CYLSOFT)
	--[[
		A DISC, BECAUSE THE BOWL IT SITS IN IS ROUND.

		This was a 5.2 square BLOCK inside a 6.2 cylinder, so the four corners of
		a bright ember Neon slab stuck out past the stone all the way round and
		the brazier read as a rock bowl with a red square balanced on it. The
		tiki torch's flame was already a Ball and the lava pool a Cylinder --
		this was the last square flame on the island.

		4.9 rather than 5.2 across, and dropped to 5.2 high: the coals now sit
		DOWN IN the bowl with half a stud of lip showing round them, instead of
		level with the rim. UPRIGHT because a Part with Shape = Cylinder runs
		along its LOCAL X -- see the note at the top of this file.
	]]
	local coals = lp(m, "FlameSource", cf, V3(1.0 * s, 4.9 * s, 4.9 * s),
		CFrame.new(0, 5.2 * s, 0) * UPRIGHT, C.ember, NEON,
		ex(CYLSOFT, { CanQuery = false, CanTouch = false, CastShadow = false }))

	-- A softer, wider ring of heat just under the rim, so the edge of the glow
	-- fades into the stone rather than ending on a hard bright line.
	lp(m, "FlameGlow", cf, V3(0.5 * s, 6.0 * s, 6.0 * s),
		CFrame.new(0, 4.9 * s, 0) * UPRIGHT, C.emberDeep, NEON,
		ex(CYLSOFT, { CanQuery = false, CanTouch = false, CastShadow = false,
			Transparency = 0.45 }))
	for i = 1, 3 do
		local a = i * 2.1
		lp(m, "Coal", cf, V3(1.7 * s, 1.2 * s, 1.7 * s),
			CFrame.new(math.cos(a) * 1.5 * s, 5.7 * s, math.sin(a) * 1.5 * s),
			dk(C.basalt, 0.4), SLATE, BALLSOFT)
	end
	light(coals, C.ember, 34 * s, 1.7)
	return m
end

----------------------------------------------------------------
-- CAIRN  --  5 parts
----------------------------------------------------------------
-- Stacked stones. The oldest trail marker there is, and the cheapest way to say
-- "somebody has been up here before you" on a mountain with no path signs.
function Props.cairn(parent, cf: CFrame, height: number, seed: number?): Model
	local m = model(parent, "Cairn")
	local rng = Random.new(seed or 0)
	local h = height or 6
	local y = 0
	for i = 1, 5 do
		local t = (i - 1) / 4
		local w = h * (0.46 - t * 0.26)
		local th = h * 0.2
		lp(m, "Stone", cf, V3(w * 2, th, w * 1.7),
			CFrame.new(rng:NextNumber(-0.2, 0.2) * h * 0.1, y + th * 0.5, rng:NextNumber(-0.2, 0.2) * h * 0.1)
				* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
			(i % 2 == 0) and lt(C.basalt, 0.16) or C.basalt, SLATE, i > 2 and SOFT or nil)
		y += th * 0.9
	end
	return m
end

----------------------------------------------------------------
-- CAMP CRATE  --  5 to 9 parts
----------------------------------------------------------------
-- The camp's dressing, in four flavours so a corner of it never reads as one
-- object repeated. `variant` is "crate", "barrel", "sacks" or "nets".
function Props.campCrate(parent, cf: CFrame, variant: string?, seed: number?): Model
	local m = model(parent, "CampCrate")
	local rng = Random.new(seed or 0)
	variant = variant or "crate"

	if variant == "barrel" then
		lp(m, "Barrel", cf, V3(4.4, 3.0, 3.0), CFrame.new(0, 2.2, 0) * UPRIGHT,
			C.timber, PLANKS, CYL)
		for _, y in ipairs({ 1.0, 3.4 }) do
			lp(m, "Hoop", cf, V3(0.4, 3.3, 3.3), CFrame.new(0, y, 0) * UPRIGHT,
				C.iron, METAL, CYLSOFT)
		end
		lp(m, "Lid", cf, V3(0.3, 3.1, 3.1), CFrame.new(0, 4.45, 0) * UPRIGHT,
			dk(C.timber, 0.25), PLANKS, CYLSOFT)

	elseif variant == "sacks" then
		for i = 1, 4 do
			local a = rng:NextNumber(0, 6.28)
			local d = rng:NextNumber(0, 1.6)
			lp(m, "Sack", cf, V3(2.6, 2.1, 2.2),
				CFrame.new(math.cos(a) * d, 1.0 + (i > 2 and 1.7 or 0), math.sin(a) * d)
					* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
				(i % 2 == 0) and C.canvas or dk(C.canvas, 0.2), FABRIC, BALL)
		end
		lp(m, "Tie", cf, V3(2.0, 0.35, 2.0), CFrame.new(0, 2.9, 0), C.rope, FABRIC, SOFT)

	elseif variant == "nets" then
		lp(m, "NetPile", cf, V3(5.2, 1.8, 4.4), CFrame.new(0, 0.8, 0),
			dk(C.rope, 0.3), FABRIC, BALL)
		for i = 1, 3 do
			local a = rng:NextNumber(0, 6.28)
			lp(m, "Float", cf, V3(1.2, 1.2, 1.2),
				CFrame.new(math.cos(a) * 1.8, 1.5, math.sin(a) * 1.8),
				C.ember, SMOOTH, BALLSOFT)
		end
		lp(m, "Buoy", cf, V3(1.6, 2.4, 1.6), CFrame.new(2.6, 1.0, -1.2) * CFrame.Angles(0, 0, 0.7),
			C.canvas, SMOOTH, ex(CYLSOFT, {}))
		lp(m, "Oar", cf, V3(0.35, 7.0, 0.9), CFrame.new(-2.4, 2.0, 0.6) * CFrame.Angles(0.5, 0.3, 0.25),
			C.timber, WOOD, SOFT)

	else
		local h = 3.4
		lp(m, "Crate", cf, V3(4.0, h, 4.0), CFrame.new(0, h * 0.5, 0), C.timber, PLANKS)
		for _, s in ipairs({ -1, 1 }) do
			lp(m, "Batten", cf, V3(4.2, 0.4, 0.4), CFrame.new(0, h * 0.5 + s * 1.1, 2.05),
				dk(C.timber, 0.3), PLANKS, SOFT)
			lp(m, "Batten", cf, V3(0.4, 0.4, 4.2), CFrame.new(s * 2.05, h * 0.5 + 1.1, 0),
				dk(C.timber, 0.3), PLANKS, SOFT)
		end
		-- a second, smaller crate at an angle: two boxes stacked square is furniture,
		-- two boxes at an angle is somebody's cargo
		lp(m, "Crate", cf, V3(2.6, 2.2, 2.6),
			CFrame.new(0.5, h + 1.1, -0.4) * CFrame.Angles(0, 0.5, 0),
			lt(C.timber, 0.15), PLANKS, SOFT)
	end
	return m
end

----------------------------------------------------------------
-- CANVAS TENT  --  12 parts
----------------------------------------------------------------
-- An A-frame in weathered canvas. The camp is an expedition camp rather than a
-- village, and a tent is the one silhouette that says so without a sign.
function Props.canvasTent(parent, cf: CFrame, scale: number): Model
	local m = model(parent, "CanvasTent")
	local s = scale or 1
	local len, halfW, h = 12 * s, 4.6 * s, 6.4 * s

	for _, side in ipairs({ -1, 1 }) do
		lp(m, "Fly", cf, V3(0.34 * s, math.sqrt(halfW * halfW + h * h) * 2 * 0.52, len),
			CFrame.new(side * halfW * 0.5, h * 0.5, 0)
				* CFrame.Angles(0, 0, side * math.atan2(halfW, h)),
			C.canvas, FABRIC)
		lp(m, "Guy", cf, V3(0.16 * s, 0.16 * s, 5.4 * s),
			CFrame.new(side * (halfW + 2.2 * s), h * 0.28, len * 0.42)
				* CFrame.Angles(-0.9, side * 0.5, 0), C.rope, FABRIC, SOFT)
	end
	lp(m, "Ridge", cf, V3(0.5 * s, 0.5 * s, len + 1.2 * s), CFrame.new(0, h, 0),
		C.timber, WOOD, SOFT)
	--[[
		THE ENDS ARE STEPPED TO THE ROOF LINE. THEY WERE RECTANGLES.

		The back wall was ONE slab halfW*2 wide by h tall, and the two door flaps
		were rectangles as well. This is an A-FRAME: its profile is a triangle, so
		all four top corners of every one of those panels stuck out past the canvas
		into open air. From any angle but dead-on the tent read as a white box with
		square panels stapled to its front and its back, which is precisely what it
		was.

		Three courses, each only as wide as the roof is at that height -- halfW
		times (1 - y/h) is the A-frame's own half-width -- so the end fills the
		triangle and stops at it. The front carries the same taper split into two
		flaps with the doorway down the middle.
	]]
	local COURSES = 3
	for i = 0, COURSES - 1 do
		local y0 = (i / COURSES) * h
		local y1 = ((i + 1) / COURSES) * h
		local mid = (y0 + y1) * 0.5
		local w = halfW * 2 * (1 - mid / h)
		lp(m, "Back", cf, V3(w, (y1 - y0) * 0.98, 0.3 * s),
			CFrame.new(0, mid, len * 0.5), dk(C.canvas, 0.16), FABRIC, SOFT)
		for _, side in ipairs({ -1, 1 }) do
			lp(m, "Flap", cf, V3(w * 0.42, (y1 - y0) * 0.98, 0.26 * s),
				CFrame.new(side * w * 0.29, mid, -len * 0.5),
				lt(C.canvas, 0.1), FABRIC, SOFT)
		end
	end
	for _, side in ipairs({ -1, 1 }) do
		lp(m, "Pole", cf, V3(0.4 * s, h, 0.4 * s),
			CFrame.new(0, h * 0.5, side * len * 0.5), C.timber, WOOD, SOFT)
	end
	lp(m, "Groundsheet", cf, V3(halfW * 2 + 1.4 * s, 0.24, len + 1.0 * s),
		CFrame.new(0, 0.12, 0), dk(C.canvas, 0.34), FABRIC, SOFT)
	return m
end

----------------------------------------------------------------
-- OUTFITTER STALL  --  27 parts
----------------------------------------------------------------
--[[
	The shop counter. NO ShopPrompt -- Island4Builder attaches that to a part it
	owns outright, so a failure in here can never take the shop with it. What is
	provided is a counter to stand at, a roof over it, and enough stock on the
	shelves that it reads as a place that sells things.

	FACES -Z like everything else in this file, so a caller points it at the
	arriving traffic with CFrame.lookAt and nothing else.
]]
function Props.outfitterStall(parent, cf: CFrame): Model
	local m = model(parent, "OutfitterStall")
	local W, D, H = 20, 11, 9.5

	-- counter
	lp(m, "Counter", cf, V3(W, 3.4, 2.6), CFrame.new(0, 1.7, -D * 0.5 + 1.3), C.timber, PLANKS)
	lp(m, "CounterTop", cf, V3(W + 1.6, 0.5, 3.6), CFrame.new(0, 3.6, -D * 0.5 + 1.1),
		lt(C.timber, 0.2), PLANKS)
	lp(m, "Kick", cf, V3(W - 1, 0.6, 0.4), CFrame.new(0, 0.3, -D * 0.5 + 0.1),
		dk(C.timber, 0.35), PLANKS, SOFT)

	-- back wall and shelving
	lp(m, "Back", cf, V3(W, H * 0.78, 0.5), CFrame.new(0, H * 0.39, D * 0.5 - 0.3),
		dk(C.timber, 0.2), PLANKS)
	for i = 1, 3 do
		lp(m, "Shelf", cf, V3(W - 2, 0.4, 1.6), CFrame.new(0, 1.9 + i * 1.9, D * 0.5 - 1.2),
			C.timber, PLANKS, SOFT)
	end
	-- stock: coils of rope, lamp glass, a row of canvas packs
	for i = -3, 3 do
		local x = i * 2.4
		local row = (i + 4) % 3
		if row == 0 then
			lp(m, "Coil", cf, V3(1.1, 1.7, 1.7), CFrame.new(x, 4.6, D * 0.5 - 1.2) * UPRIGHT,
				C.rope, FABRIC, CYLSOFT)
		elseif row == 1 then
			lp(m, "Lamp", cf, V3(1.3, 1.9, 1.3), CFrame.new(x, 6.6, D * 0.5 - 1.2),
				C.glow, SMOOTH, ex(SOFT, { Transparency = 0.35, Reflectance = 0.2 }))
		else
			lp(m, "Pack", cf, V3(1.6, 2.0, 1.2), CFrame.new(x, 8.5, D * 0.5 - 1.2),
				C.canvas, FABRIC, SOFT)
		end
	end

	-- posts and an awning that overhangs the counter, so there is somewhere to
	-- stand out of the ash
	for _, sx in ipairs({ -1, 1 }) do
		lp(m, "Post", cf, V3(0.8, H, 0.8), CFrame.new(sx * (W * 0.5 - 0.4), H * 0.5, -D * 0.5),
			C.timber, WOOD)
		lp(m, "Post", cf, V3(0.8, H, 0.8), CFrame.new(sx * (W * 0.5 - 0.4), H * 0.5, D * 0.5 - 0.4),
			dk(C.timber, 0.2), WOOD)
	end
	for i = 0, 3 do
		lp(m, "Awning", cf, V3(W + 3 - i * 0.4, 0.4, 3.4),
			CFrame.new(0, H + i * 0.55, -D * 0.5 - 1.6 + i * 1.5),
			(i % 2 == 0) and C.canvas or dk(C.canvas, 0.22), FABRIC, SOFT)
	end
	lp(m, "Roof", cf, V3(W + 2, 0.55, D + 2), CFrame.new(0, H + 1.9, 0.6),
		dk(C.canvas, 0.3), FABRIC, SOFT)
	return m
end

----------------------------------------------------------------
-- SAND RIPPLES  --  `rows` parts
----------------------------------------------------------------
--[[
	The wind-and-tide texture on black sand, as a run of low ridges lying across
	the local X.

	THIN AND FLAT AND NOT COLLIDABLE. These are 0.22 studs proud, which is under
	half the crust's own rise and well under any step height -- a ripple you can
	trip on is a bug, and a ripple that casts a shadow at this sun angle would
	have to be tall enough to read as a kerb.

	The tone is a LIFT off whatever the caller passes rather than a colour of its
	own, so the same builder works on wet sand, dry sand and ash.
]]
function Props.sandRipples(parent, cf: CFrame, span: number, rows: number, tone: Color3, seed: number?): Model
	local m = model(parent, "SandRipples")
	local rng = Random.new(seed or 0)
	local step = span / math.max(1, rows)
	for i = 0, rows - 1 do
		local z = -span * 0.5 + (i + 0.5) * step
		local w = span * rng:NextNumber(0.5, 1.0)
		lp(m, "Ripple", cf, V3(w, 0.22, step * rng:NextNumber(0.3, 0.5)),
			CFrame.new(rng:NextNumber(-span * 0.15, span * 0.15), 0.06, z)
				* CFrame.Angles(0, rng:NextNumber(-0.09, 0.09), 0),
			lt(tone, rng:NextNumber(0.1, 0.22)), SLATE,
			{ CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
	end
	return m
end

----------------------------------------------------------------
-- FOOTPRINTS  --  2 * count parts
----------------------------------------------------------------
--[[
	A line of prints across the sand between two world points.

	PRESSED IN, NOT LAID ON. A footprint is a hole, and the only way to draw a
	hole on flat ground without touching the terrain is to draw its SHADOW: a
	flush, slightly darker patch. So these are 0.14 proud, DARKER than the sand
	rather than lighter (which is the opposite of the ripples above, and is the
	whole reason the two read as different things), and shadow-free.

	The stride alternates side to side off the path's own perpendicular, so it is
	a walk rather than two parallel dotted lines.
]]
function Props.footprints(parent, a: Vector3, b: Vector3, count: number, tone: Color3, seed: number?): Model
	local m = model(parent, "Footprints")
	local rng = Random.new(seed or 0)
	local dir = (b - a)
	local len = dir.Magnitude
	if len < 1 then
		return m
	end
	dir = dir.Unit
	local side = Vector3.new(-dir.Z, 0, dir.X)
	local yaw = math.atan2(dir.X, dir.Z)
	for i = 0, count - 1 do
		local t = (i + 0.5) / count
		local s = (i % 2 == 0) and 1 or -1
		local at = a:Lerp(b, t) + side * (s * 0.9)
		P(m, "Print", V3(0.75, 0.14, 1.5),
			CFrame.new(at) * CFrame.Angles(0, yaw + rng:NextNumber(-0.12, 0.12), 0),
			dk(tone, 0.34), SLATE,
			{ CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
	end
	return m
end

----------------------------------------------------------------
-- THE LITTER SET
----------------------------------------------------------------
--[[
	ReplicatedStorage.CTB.Volcano, built at boot, exactly the way Island2Builder
	builds the desert's set. Twelve pieces, and every one a SINGLE BasePart --
	that is the contract, not a style: CTB_Client's sink and raise tweens drive
	one part directly and a Model would need welding first.

	THE OTHER CONTRACT IS THE RESTING AXIS, and it is the one that is easy to get
	wrong because it looks like it has no rule. CTB_Client.litterRest lies a piece
	flat by turning it a quarter turn about X when its Z is smaller than its Y --
	so it handles exactly two authorings:

	  smallest axis is Y   already flat; no rotation, and it stays as authored
	  smallest axis is Z   modelled standing up; turned onto its face

	A piece whose smallest axis is X falls through BOTH branches and comes out
	balanced on its edge like a plate in a rack. The sweep at the end of this
	function is what catches that -- the primitives below are hand-sized and
	obvious, but a mesh's proportions come off somebody else's upload.

	SIZES ARE ALL UNDER TWO STUDS, to match the beach's and the cove's. A find
	the player has to walk round is not litter, it is scenery.

	HALF MESH AND HALF PRIMITIVE, which is the two ways this game already makes a
	set: the cove's Sakura folder is twelve Creator Store meshes saved in the
	place file, the dunes' is sixteen code-built parts. Ashfall takes both --
	meshes where a real object beats anything a box can do (the bottle, the torch,
	the pack, the driftwood) and primitives where the thing IS a simple shape
	(pumice, a plank, a fin, a wrapper). The mesh half is skipped without
	complaint if VolcanoAssets is missing; the set is simply eight pieces then.
]]
local function litterPart(folder, name, size, colour, material, extra): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.Color = colour
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if extra then
		for k, v in pairs(extra) do
			p[k] = v
		end
	end
	p.Parent = folder
	return p
end

function Props.buildLitterSet(parent: Instance): (Instance, number)
	local old = parent:FindFirstChild("Volcano")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "Volcano"

	-- ---- primitives ----
	litterPart(folder, "Pumice Lump", V3(1.1, 0.8, 1.0), C.ashPale, CONCRETE,
		{ Shape = Enum.PartType.Ball })
	litterPart(folder, "Scorched Plank", V3(0.7, 0.22, 1.9), dk(C.timber, 0.55), WOOD)
	-- Size on a Cylinder is (length, dia, dia) along its LOCAL X, so a can LYING
	-- DOWN is the long axis first -- and that also keeps Z equal to Y, which is
	-- what stops litterRest from standing it on end.
	litterPart(folder, "Ash Can", V3(1.15, 0.66, 0.66), C.ash, Enum.Material.CorrodedMetal,
		{ Shape = Enum.PartType.Cylinder })
	litterPart(folder, "Net Float", V3(1.0, 0.9, 1.0), C.ember, SMOOTH,
		{ Shape = Enum.PartType.Ball })
	litterPart(folder, "Dive Fin", V3(0.72, 0.2, 1.8), RGB(46, 120, 150), SMOOTH)
	litterPart(folder, "Foil Wrapper", V3(0.9, 0.1, 0.95), RGB(214, 178, 74), METAL,
		{ Reflectance = 0.3 })
	litterPart(folder, "Guy Line", V3(0.9, 0.28, 0.95), C.rope, FABRIC,
		{ Shape = Enum.PartType.Ball })
	litterPart(folder, "Melted Visor", V3(1.25, 0.3, 0.55), RGB(96, 88, 96), SMOOTH,
		{ Reflectance = 0.18 })
	-- Two rocks in with the rubbish, deliberately. What is lying loose on a black
	-- beach under a live cone is not all somebody's litter -- half of it fell out
	-- of the sky -- and the FINDS pool was corrected the same way (see the note on
	-- the ASH block in Modules.ItemConfig). The two sets should agree about what
	-- this island is covered in.
	litterPart(folder, "Scoria Lump", V3(1.0, 0.8, 0.95), RGB(96, 52, 44), SLATE,
		{ Shape = Enum.PartType.Ball })
	litterPart(folder, "Basalt Chip", V3(1.0, 0.3, 0.9), RGB(70, 66, 74), SLATE)

	-- ---- meshes ----
	local function meshPiece(kitName, display, height, colour, material)
		local p = kit(folder, kitName, height, colour, material)
		if not p then
			return
		end
		p.Name = display
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
	end
	meshPiece("Bottle", "Water Bottle", 1.5, RGB(212, 224, 228), SMOOTH)
	meshPiece("Torch", "Dropped Torch", 1.4, RGB(184, 188, 194), METAL)
	meshPiece("Pack", "Lost Pack", 1.7, nil, nil)
	meshPiece("DeadLog", "Charred Driftwood", 1.9, dk(C.timber, 0.6), WOOD)

	local n = 0
	for _, p in ipairs(folder:GetChildren()) do
		if p:IsA("BasePart") then
			n += 1
			--[[
				The resting-axis contract, enforced rather than trusted -- and stated as
				the thing that actually matters rather than as a proxy for it.

				The first version of this test asked "is X the smallest axis", which is
				ALMOST the rule and cried wolf on the very first mesh it met: the water
				bottle is (0.55, 1.50, 0.55), its X and Z are equal to two decimals and
				unequal in float, so a strict `X < Z` flagged a piece that lies down
				perfectly. A boot warning that is wrong the first time it fires is worse
				than no warning at all.

				So it asks the real question instead: work out which axis litterRest is
				going to leave pointing UP, and complain only if that is not the piece's
				thinnest -- with enough tolerance that two nominally equal axes cannot
				disagree about it.
			]]
			local s = p.Size
			local upright = (s.Z < s.Y) and s.Z or s.Y   -- what litterRest leaves vertical
			if upright > math.min(s.X, s.Y, s.Z) + 0.05 then
				warn(string.format("[Ashfall] litter piece %q rests %.2f studs tall on its "
					.. "thinnest side of %.2f -- CTB_Client.litterRest cannot lie this one "
					.. "flat, so it will stand on its edge. Author it thinnest on Y or Z.",
					p.Name, upright, math.min(s.X, s.Y, s.Z)))
			end
		end
	end

	folder.Parent = parent
	return folder, n
end

return Props
