--[[
	AfkShoreBuilder  --  ServerScriptService.AfkShoreBuilder

	Builds THE LONG SHORE: eight small bays of empty beach at AfkConfig.Origin,
	eight thousand studs off the map, one per idling player.

	ADOPTION CONTRACT, the same one BayBuilder / StoreBuilder / CarSpawnerBuilder
	keep: this is a FALLBACK, not an owner. If workspace.AfkShore already exists
	carrying the built marker, this does nothing at all, so the moment somebody
	dresses the shore by hand in Studio the code stops running and the authored
	version stands.

	⚠️ THAT CUTS BOTH WAYS. Once the shore is saved into the place file, editing
	this module changes nothing a player sees -- the same trap that cost real
	time on Seal A Driveway's yard. An art fix has to be applied TWICE: here (the
	recipe, for a place that has lost the area) and to the live instances.

	EVERYTHING IS PARTS, NOT TERRAIN. Terrain is one global object and the
	rakeable beach is per-player state written into it; a sand floor out here
	made of terrain would be the same terrain the game rakes. Parts cost nothing
	at this size and cannot collide with that system at all.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local AfkConfig = require(Modules:WaitForChild("AfkConfig"))
local SignKit = require(Modules:WaitForChild("SignKit"))

local AfkShoreBuilder = {}

--------------------------------------------------------------------------
-- PALETTE
--
-- A CARTOON POSTCARD, not a naturalistic beach.
--
-- The first pass was muted sand and driftwood -- accurate, and it read as a
-- grey-box with a sand texture on it. What makes this game's islands look the
-- way they do is saturation plus hard tonal steps: the cove is vivid pink
-- against near-black slate, the dunes are gold against lapis. So the shore
-- borrows the palette the game already brands itself with -- PanelKit's UI
-- colours, the ones on every button the player has been looking at all
-- session -- and uses them at full strength on the props.
--
-- THE ONE RULE THAT SURVIVES FROM THE FIRST PASS: big areas stay off the top
-- of the range; see the sakura plaza note for what a 94% floor does under
-- Brightness 3.1 and a 1.6 bloom threshold. Props are small, so they are free
-- to be loud.
--
--[[
	THE SAND PAIR IS WIDENED FROM BOTH ENDS, and that is the whole reason a
	raked lane can be seen at all.

	It shipped as 78% dry against 86% raked: eight points of separation, with
	BOTH of them up where Brightness 3.1 is already flattening everything. On
	screen the strips read as a faint sheen you had to know was there, so a
	puppet that raked a lane appeared to do nothing to it.

	The game's own beach runs Sand 203,177,106 against raked Snow 240,226,187 --
	68% to 88%, TWENTY points -- and the note on that pair records the rule this
	one had broken: widening from ONE end does not work, you have to move both.
	69% and 90% here, for 21.

	Dropping the dry tone is not a cost, it is the second half of the fix: the
	shore was a very pale beach under a very bright sun and had nowhere left to
	go upward. Everything sand-coloured moves with it (the ground plane, the
	bank mounds, the dune ridge), which is why they are all one constant.
]]
--------------------------------------------------------------------------
local SAND       = Color3.fromRGB(212, 178, 116)   -- 69%
local SAND_RAKED = Color3.fromRGB(246, 231, 192)   -- 90%, thin strips only
-- Kept a clear step BELOW the new dry sand. At its old value it was 67% against
-- a 69% beach, so the tide line would have vanished the moment the sand moved.
local SAND_WET   = Color3.fromRGB(184, 152, 100)
-- The cartoon outline trick: a darker slab a shade larger, sitting just under
-- the sand, so every bay is drawn with a line round it instead of fading into
-- the beach behind it. Cheaper than an actual outline and it reads at distance.
local SAND_TRIM  = Color3.fromRGB(176, 140, 88)
local SEA_SHALLOW = Color3.fromRGB(108, 226, 226)
local SEA_DEEP   = Color3.fromRGB(48, 150, 226)
local FOAM       = Color3.fromRGB(255, 255, 255)
local TIMBER     = Color3.fromRGB(168, 118, 66)
local TIMBER_DARK = Color3.fromRGB(108, 72, 40)
local ROPE       = Color3.fromRGB(222, 196, 148)
local LEAF       = Color3.fromRGB(86, 196, 96)
local LEAF_DARK  = Color3.fromRGB(52, 148, 72)
local ROCK       = Color3.fromRGB(150, 146, 152)
local COCONUT    = Color3.fromRGB(120, 84, 52)
-- The shelter's awning on the live beach. Coral, matching bay 1's accent, so
-- the door and the place it leads to are obviously the same attraction.
local CANVAS     = Color3.fromRGB(255, 118, 104)

--[[
	ONE ACCENT PER BAY, and it is the whole reason the row does not read as
	eight copies of the same slab.

	Parasol, towel, beach ball, bunting and the bay post's cap all take the bay's
	colour, so from the air the shore is a row of eight differently-coloured
	pitches rather than a repeated asset. Straight out of PanelKit.C, so a player
	arriving in bay 4 is standing under the same blue as the rail key they pressed.
]]
local ACCENTS = {
	Color3.fromRGB(255, 118, 104),   -- coral
	Color3.fromRGB(255, 200,  62),   -- sun
	Color3.fromRGB( 94, 226, 196),   -- foam
	Color3.fromRGB( 64, 168, 240),   -- sea
	Color3.fromRGB(140, 226,  96),   -- lime
	Color3.fromRGB(186, 128, 255),   -- grape
	Color3.fromRGB(255, 150, 190),   -- blossom
	Color3.fromRGB(255, 152,  66),   -- tangerine
}
local CREAM = Color3.fromRGB(255, 248, 232)

local function accentFor(index: number): Color3
	return ACCENTS[((index - 1) % #ACCENTS) + 1]
end

--------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame,
	colour: Color3, material: Enum.Material, props: {[string]: any}?): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = colour
	p.Material = material
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props or {} do
		p[k] = v
	end
	p.Parent = parent
	return p
end

-- Decoration: out of every spatial query, and never in the way of a puppet
-- that has to walk this bay for hours.
local function trim(parent, name, size, cf, colour, material, props)
	props = props or {}
	props.CanCollide = false
	props.CanQuery = false
	props.CanTouch = false
	return part(parent, name, size, cf, colour, material, props)
end

--[[
	A BOARD STANDS PROUD OF WHAT HOLDS IT UP.

	Straight out of the Seal A Driveway yard's sign audit: put a 0.4-thick board
	on the centre line of a 0.6 post and the post comes out 0.1 in FRONT of the
	readable face, running up through the middle of the lettering. The board is
	offset forward by a quarter stud here rather than being trusted to the eye,
	and it is unconditional so a board cannot be added later without it.
]]
local PROUD = 0.25

local function board(parent, name, size, cf, text, faces)
	local b = part(parent, name, size, cf * CFrame.new(0, 0, -PROUD), Color3.fromRGB(56, 46, 38),
		Enum.Material.SmoothPlastic, { CanCollide = false, CanQuery = false })
	local ok, err = pcall(SignKit.dress, b, text, faces or { Enum.NormalId.Front })
	if not ok then
		warn("[AfkShore] SignKit refused a board: " .. tostring(err))
	end
	return b
end

--------------------------------------------------------------------------
-- ONE BAY
--------------------------------------------------------------------------

--[[
	THE PROPS.

	Every one of these is `trim` -- non-collidable and out of every spatial
	query. The puppet walks this bay for hours and must never be able to catch
	on the furniture, and a raycast from the live map cannot reach out here but
	a future one from something ON the shore could.
]]

-- A cylinder's LENGTH is its Size.X and the other two are the cross-section,
-- so a flat disc is (thickness, diameter, diameter). Getting that the wrong
-- way round builds a blade standing on its end, which is exactly what the
-- first version of the parasol was.
local function disc(m, name, o, pos, dia, thick, colour, material)
	return trim(m, name, Vector3.new(thick, dia, dia), CFrame.new(o + pos), colour,
		material or Enum.Material.SmoothPlastic,
		{ Shape = Enum.PartType.Cylinder, Orientation = Vector3.new(0, 0, 90) })
end

-- `Shape = Ball` is CORRECT here and nowhere else on this shore: a finial, a
-- coconut and a beach ball are authored round, so the min-axis rule below costs
-- them nothing.
local function ball(m, name, o, pos, dia, colour, material)
	return trim(m, name, Vector3.new(dia, dia, dia), CFrame.new(o + pos), colour,
		material or Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Ball })
end

--[[
	A WIDE, FLAT DOME -- and it is a SpecialMesh rather than `Shape = Ball`,
	which is the entire point of it.

	`Part.Shape = Ball` draws a sphere of the part's SMALLEST axis and throws
	the other two away. Every squashed dome on this shore was authored that way:
	the dune ridge asked for 80-230 studs wide and DREW at 9-30, so it came out
	as a line of golf balls on a plain, and the rock clusters came out as
	marbles. A `SpecialMesh` of MeshType Sphere fills the part's BOX instead, so
	a (40, 8, 40) part renders as the 40-wide, 8-tall ellipsoid it says it is.

	Verified rather than assumed -- the two were built side by side against a
	dark backdrop and photographed, because a raycast cannot tell them apart:
	the mesh is visual only and COLLISION still follows the box either way.
	That is also why everything built with this is `trim` (CanCollide off) and
	nothing on the shore stands on one.
]]
local function dome(m, name, cf: CFrame, size: Vector3, colour: Color3, material)
	local p = trim(m, name, size, cf, colour, material or Enum.Material.Sand)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	return p
end

-- A BULLSEYE PARASOL. Three concentric discs rather than radial wedge
-- segments: a fraction of the parts, and at the size a player sees it from it
-- reads as a striped parasol anyway. The finial is what stops the top looking
-- like a dropped plate.
local function parasol(m, o, pos: Vector3, accent: Color3)
	trim(m, "ParasolPole", Vector3.new(0.4, 9, 0.4),
		CFrame.new(o + pos + Vector3.new(0, 4.5, 0)), TIMBER, Enum.Material.Wood)
	disc(m, "ParasolTop", o, pos + Vector3.new(0, 8.7, 0), 11.0, 0.55, accent, Enum.Material.Fabric)
	disc(m, "ParasolRing", o, pos + Vector3.new(0, 9.0, 0), 7.4, 0.5, CREAM, Enum.Material.Fabric)
	disc(m, "ParasolHub", o, pos + Vector3.new(0, 9.3, 0), 3.6, 0.45, accent, Enum.Material.Fabric)
	ball(m, "ParasolFinial", o, pos + Vector3.new(0, 9.9, 0), 1.1, CREAM)
end

-- A PALM, which is the single biggest thing the first pass was missing: every
-- silhouette on the shore was under nine studs, so the whole area read flat.
local function palm(m, o, pos: Vector3, lean: number, height: number)
	-- CYLINDERS, and five of them rather than three. Boxes made a palm look
	-- like a fence post with leaves on: at player height the flat faces catch
	-- the light as three hard planes and the whole tree reads as a column. More
	-- segments also mean the lean can curve instead of kinking twice.
	--
	-- A cylinder's length is its Size.X, so standing one up is Orientation
	-- (0, 0, 90) and the lean has to be applied AFTER that -- the two rotations
	-- do not commute, and doing them the other way lays the trunk on its side.
	local tiers = 5
	local seg = height / tiers
	for i = 0, tiers - 1 do
		local t = (i + 0.5) / tiers
		local w = 2.0 - t * 0.85
		trim(m, "PalmTrunk", Vector3.new(seg + 0.5, w, w),
			CFrame.new(o + pos + Vector3.new(math.sin(lean) * t * t * height * 0.5, seg * (i + 0.5), 0))
				* CFrame.Angles(0, 0, math.rad(90) - lean * t * 1.1),
			TIMBER:Lerp(Color3.fromRGB(198, 150, 96), t * 0.35), Enum.Material.Wood,
			{ Shape = Enum.PartType.Cylinder })
	end
	local top = pos + Vector3.new(math.sin(lean) * height * 0.5, height, 0)
	-- Six fronds, alternating two greens so the crown has some depth in it
	-- rather than reading as one flat green star.
	for i = 0, 5 do
		trim(m, "PalmFrond", Vector3.new(2.2, 0.35, 9),
			CFrame.new(o + top)
				* CFrame.Angles(0, math.rad(i * 60 + 12), 0)
				* CFrame.Angles(math.rad(-24), 0, 0)
				* CFrame.new(0, 0, -4.6),
			(i % 2 == 0) and LEAF or LEAF_DARK, Enum.Material.Grass)
	end
	for _, dx in ipairs({ -0.9, 0.9 }) do
		ball(m, "Coconut", o, top + Vector3.new(dx, -0.9, 0.4), 1.3, COCONUT)
	end
end

local function beachBall(m, o, pos: Vector3, accent: Color3)
	ball(m, "BeachBall", o, pos + Vector3.new(0, 1.6, 0), 3.2, CREAM)
	disc(m, "BallBand", o, pos + Vector3.new(0, 1.6, 0), 3.24, 0.9, accent)
end

local function towel(m, o, pos: Vector3, accent: Color3, yaw: number)
	local base = CFrame.new(o + pos) * CFrame.Angles(0, yaw, 0)
	trim(m, "Towel", Vector3.new(8, 0.12, 4.6), base, accent, Enum.Material.Fabric)
	for _, dz in ipairs({ -1.3, 1.3 }) do
		trim(m, "TowelStripe", Vector3.new(8.05, 0.14, 0.9),
			base * CFrame.new(0, 0.01, dz), CREAM, Enum.Material.Fabric)
	end
end

local function rocks(m, o, pos: Vector3, seed: number)
	local rng = Random.new(seed)
	for i = 1, 3 do
		local d = rng:NextNumber(1.8, 3.6)
		dome(m, "Rock",
			CFrame.new(o + pos + Vector3.new(rng:NextNumber(-3, 3), d * 0.28, rng:NextNumber(-2.4, 2.4)))
				* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
			Vector3.new(d, d * 0.7, d * 0.9), ROCK, Enum.Material.Slate)
	end
end

-- BUNTING between two posts. A sagging cord and a row of little flags -- the
-- cheapest thing on this list and the one that most says "somebody set this up".
local function bunting(m, o, a: Vector3, b: Vector3, accent: Color3)
	local steps = 7
	for i = 0, steps do
		local t = i / steps
		local sag = math.sin(t * math.pi) * 1.6
		local p = a:Lerp(b, t) - Vector3.new(0, sag, 0)
		if i < steps then
			local q = a:Lerp(b, (i + 1) / steps) - Vector3.new(0, math.sin((i + 1) / steps * math.pi) * 1.6, 0)
			local mid = (p + q) * 0.5
			trim(m, "BuntingCord", Vector3.new(0.12, 0.12, (q - p).Magnitude),
				CFrame.lookAt(o + mid, o + q), ROPE, Enum.Material.SmoothPlastic)
		end
		if i > 0 and i < steps then
			trim(m, "BuntingFlag", Vector3.new(1.1, 1.4, 0.1),
				CFrame.new(o + p - Vector3.new(0, 0.8, 0)),
				(i % 2 == 0) and accent or CREAM, Enum.Material.Fabric)
		end
	end
end

local function buildBay(parent: Instance, index: number): Model
	local m = Instance.new("Model")
	m.Name = ("Bay_%d"):format(index)
	m.Parent = parent

	local o = AfkConfig.plotOrigin(index)
	local W, D = AfkConfig.PlotWidth, AfkConfig.PlotDepth

	local accent = accentFor(index)

	-- THE OUTLINE, under everything. See the note on SAND_TRIM: a slab three
	-- studs proud on each side and half a stud lower, so the bay is drawn with a
	-- dark line round it and reads as a distinct pitch from the air.
	-- ...and the outline takes the BAY'S COLOUR, not one flat brown. Sand lerped
	-- 40% toward the accent: still obviously beach, but from the air the row is
	-- eight differently-edged pitches instead of eight identical rectangles.
	-- This is the read that carries at distance -- the parasol is four studs
	-- across and the outline is sixty-six.
	part(m, "SandTrim", Vector3.new(W + 6, 2, D + 6),
		CFrame.new(o + Vector3.new(0, -1.5, 0)), SAND_TRIM:Lerp(accent, 0.40),
		Enum.Material.Sand)

	-- THE SAND. One slab, 2 studs thick, its TOP at the origin's Y so every
	-- other number in the bay can be written as a height above zero.
	part(m, "Sand", Vector3.new(W, 2, D), CFrame.new(o + Vector3.new(0, -1, 0)),
		SAND, Enum.Material.Sand)

	--[[
		THE RAKE LANES, AND THEY ARE NOW EMPTY WHEN THE BAY IS EMPTY.

		These used to be five full-length pale strips painted on at build time
		and never touched again -- a bay permanently frozen halfway through
		being raked, with a man walking up and down it changing nothing. Read
		exactly as what it was: some lines of sand and some lines of no sand,
		and raking them did nothing.

		So each lane is authored COLLAPSED (0.05 wide, fully transparent) and
		AfkService grows it behind the puppet as it walks, from the end that
		lane starts at. See the rake block in AfkService for the sweep itself
		and for why the SERVER drives it rather than the client that owns the
		walk.

		The pay does NOT come from these -- it is still wall-clock, see the note
		in AfkConfig. This is the picture of the work, not the meter for it.

		Each lane carries its own index as an attribute rather than relying on
		child order, because `GetChildren` is not ordered and lane 2 growing
		from lane 5's end is a silent, very confusing bug.
	]]
	local lanes = AfkConfig.LaneCount
	local usable = D - AfkConfig.LaneInset * 2
	local laneHalfX = W * 0.5 - AfkConfig.LaneInset
	for i = 1, lanes do
		local t = (lanes == 1) and 0.5 or ((i - 1) / (lanes - 1))
		local z = -usable * 0.5 + usable * t
		-- Odd lanes are walked +X and even lanes -X (lapFor in AfkClient), so
		-- the strip has to be anchored at the end the puppet sets off from.
		local startX = (i % 2 == 1) and -laneHalfX or laneHalfX
		local lane = trim(m, "RakeLane", Vector3.new(0.05, 0.06, 3.2),
			CFrame.new(o + Vector3.new(startX, 0.03, z)), SAND_RAKED, Enum.Material.Sand,
			{ Transparency = 1 })
		lane:SetAttribute("Lane", i)
	end

	-- THE SEA at +Z, and the wet band the tide leaves in front of it. The water
	-- is a part and not terrain water: it is scenery, nobody swims in it, and
	-- terrain water out here would be the same water plane as the live map's.
	trim(m, "WetSand", Vector3.new(W, 0.08, 7),
		CFrame.new(o + Vector3.new(0, 0.04, D * 0.5 - 3)), SAND_WET, Enum.Material.Sand)
	trim(m, "Foam", Vector3.new(W, 0.10, 1.6),
		CFrame.new(o + Vector3.new(0, 0.06, D * 0.5 + 0.4)), FOAM, Enum.Material.SmoothPlastic)
	-- The sea is NOT built per bay. One translucent slab each would overlap its
	-- neighbours across the gaps, and two 0.35-transparent parts stacked read as
	-- one much darker one -- a visible seam every 96 studs. It is a single part
	-- for the whole shore, laid in build() below.

	--[[
		THE BANK at -Z, so the bay is enclosed on the land side and the puppet
		has something to turn in front of rather than open nothing.

		IT WAS ONE BOX AND IT READ AS A RETAINING WALL. A 68 x 5 x 8 slab tilted
		twelve degrees about X gives a hard vertical face, two square ends that
		stop in mid-air a stud outside the bay's own outline, and a flat top
		catching the light as a separate grey plane -- so the back of every bay
		looked like a kerb somebody had poured across the beach, with the palms
		planted against it and the bunting hanging in front of it.

		A bank of sand is not a box. It is a row of low overlapping mounds, and
		the two rules that make those read (both learned on the dune ridge in
		build(), both restated here because this is the one a player stands
		three studs from): they have to be much WIDER than they are tall, and
		their neighbours have to run INTO each other -- eight separate domes is
		eight domes, six overlapping ones is a ridge.

		Sunk by a third so the sand meets it in a curve rather than at a seam,
		and tinted with the bay's own SandTrim lerp so the shoulder belongs to
		the pitch it stands behind rather than to the ground beyond it.
	]]
	--[[
		HOW DEEP TO SINK ONE, and the first pass got this badly wrong in a way
		that is worth writing down because the same number appears on the dune
		ridge in build().

		Sinking a dome "by a third of its height" puts its CENTRE at -0.34h,
		which leaves 0.5h - 0.34h = 0.16h standing above the sand. Sixteen per
		cent. A seven-stud mound showed one stud and change, so the bank went
		from reading as a wall to reading as nothing at all.

		An ellipsoid is WIDEST at its centre, so a centre at y = 0 is the one
		that meets the ground at its full width and reads as a clean half-dome.
		Just under that -- -0.12h, leaving 0.38h proud -- hides the seam without
		throwing the mound away.
	]]
	local bankZ = -D * 0.5 - 6
	local brng = Random.new(index * 7717 + 13)
	local bank = Instance.new("Model")
	bank.Name = "Bank"
	bank.Parent = m
	local mounds = 6
	for i = 1, mounds do
		local t = (i - 1) / (mounds - 1)
		local bx = -34 + t * 68 + brng:NextNumber(-3.5, 3.5)
		local bh = brng:NextNumber(9, 15)
		local bw = brng:NextNumber(28, 42)
		-- Depth is CAPPED, not just proportioned. Lane 1 runs at z = -16 and its
		-- strip is 3.2 wide, so a mound reaching past about z = -19 would have
		-- the bank visibly lying across the first thing the puppet rakes.
		local bd = math.min(bw * brng:NextNumber(0.45, 0.62), 18)
		dome(bank, "BankMound",
			CFrame.new(o + Vector3.new(bx, -bh * 0.12, bankZ + brng:NextNumber(-5, 0)))
				* CFrame.Angles(0, brng:NextNumber(-0.3, 0.3), 0),
			Vector3.new(bw, bh, bd),
			SAND:Lerp(SAND_TRIM:Lerp(accent, 0.40), brng:NextNumber(0.10, 0.32)),
			Enum.Material.Sand)
	end

	--[[
		MARRAM ON THE CREST, not floating in front of it.

		The old tufts were three single blades at a fixed y = 3.4, which was the
		top of the slab they were standing on and is nowhere in particular now.
		Each one is a small fan of blades leaning apart, raycast-free: the crest
		height is known analytically because this file just drew the mounds.
	]]
	for i = -1, 1 do
		local gx = i * 16 + brng:NextNumber(-3, 3)
		-- 0.38 of the mound height, which is what the sink above leaves proud.
		local crest = 4.4 + brng:NextNumber(-0.8, 1.2)
		for blade = 1, 4 do
			local lean = math.rad(brng:NextNumber(-16, 16))
			local hgt = brng:NextNumber(2.4, 3.8)
			trim(m, "Marram", Vector3.new(0.28, hgt, 0.28),
				CFrame.new(o + Vector3.new(gx + brng:NextNumber(-1.2, 1.2), crest + hgt * 0.4,
					bankZ + brng:NextNumber(-1.6, 1.6)))
					* CFrame.Angles(0, 0, lean),
				Color3.fromRGB(160, 176, 120):Lerp(Color3.fromRGB(196, 204, 148),
					brng:NextNumber(0, 0.5)),
				Enum.Material.Grass)
		end
	end

	-- THE BAY MARKER. A driftwood post with the number on it, at the landward
	-- end of the first lane, so a player dropped in knows which one is theirs.
	local postX = -W * 0.5 + 4
	part(m, "BayPost", Vector3.new(0.6, 7, 0.6),
		CFrame.new(o + Vector3.new(postX, 3.5, -usable * 0.5 - 3)), TIMBER, Enum.Material.Wood)
	board(m, "BayBoard", Vector3.new(7, 2.4, 0.4),
		CFrame.new(o + Vector3.new(postX, 7.6, -usable * 0.5 - 3)),
		("BAY %d"):format(index), { Enum.NormalId.Front, Enum.NormalId.Back })

	--[[
		THE WAY OUT. A post at the landward corner carrying the prompt.

		The PART only -- AfkService puts the ProximityPrompt on it. A prompt is
		behaviour and it belongs with the code that handles being triggered, not
		with the code that decides where a post stands; and a prompt built here
		would be a button that exists before anything answers it.
	]]
	local leave = part(m, "LeavePost", Vector3.new(0.7, 8, 0.7),
		CFrame.new(o + Vector3.new(W * 0.5 - 4, 4, -usable * 0.5 - 3)), TIMBER_DARK,
		Enum.Material.Wood)
	leave:SetAttribute("Bay", index)
	board(m, "LeaveBoard", Vector3.new(8, 2.4, 0.4),
		CFrame.new(o + Vector3.new(W * 0.5 - 4, 8.6, -usable * 0.5 - 3)),
		"GO BACK", { Enum.NormalId.Front, Enum.NormalId.Back })

	--[[
		THE PITCH.

		All of it in the bay's accent and all of it clear of the lanes: the
		puppet works the middle of the bay, so the furniture lives in the two
		landward corners and on the strip behind the last lane. Nothing here is
		collidable and nothing here is queryable.
	]]
	local px, pz = W * 0.5 - 13, -usable * 0.5 - 3
	parasol(m, o, Vector3.new(px, 0, pz), accent)
	towel(m, o, Vector3.new(px - 7.5, 0.06, pz + 1.5), accent, math.rad(12))
	beachBall(m, o, Vector3.new(px + 5.5, 0, pz + 3.5), accent)

	-- Two palms, both landward and well outside the lanes, at different heights
	-- and leaning different ways -- a matched pair reads as wallpaper.
	palm(m, o, Vector3.new(-W * 0.5 + 7, 0, -D * 0.5 - 1), math.rad(14), 20)
	palm(m, o, Vector3.new(W * 0.5 - 3, 0, -D * 0.5 - 2), math.rad(-9), 15)

	-- Rock clusters at the water line, seeded off the bay index so no two bays
	-- get the same scatter.
	rocks(m, o, Vector3.new(-W * 0.5 + 9, 0, D * 0.5 - 2), index * 4111 + 7)
	rocks(m, o, Vector3.new(W * 0.5 - 8, 0, D * 0.5 - 3), index * 9173 + 31)

	-- Bunting from the bay post across to the parasol.
	bunting(m, o, Vector3.new(postX, 7.2, -usable * 0.5 - 3),
		Vector3.new(px, 9.2, pz), accent)

	-- The bay post gets a cap in the bay's colour, so the number and the pitch
	-- under it are obviously the same bay.
	ball(m, "PostCap", o, Vector3.new(postX, 9.1, -usable * 0.5 - 3), 1.4, accent)

	--[[
		THE STAND POINT -- where AfkService puts the character, and the one part
		in the bay anything else reads by name. Invisible, off every query. At
		the landward end of the middle lane, facing the sea, so the first thing a
		player sees on arriving is the water rather than the bank.
	]]
	local stand = part(m, "StandPoint", Vector3.new(1, 1, 1),
		CFrame.lookAt(o + Vector3.new(-W * 0.5 + AfkConfig.LaneInset, 3, -usable * 0.5),
			o + Vector3.new(-W * 0.5 + AfkConfig.LaneInset, 3, 0)),
		ROPE, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
	stand:SetAttribute("Bay", index)

	m.PrimaryPart = m:FindFirstChild("Sand")
	return m
end

--------------------------------------------------------------------------
-- THE SHORE
--------------------------------------------------------------------------

function AfkShoreBuilder.build(): Folder
	local root = Instance.new("Folder")
	root.Name = AfkConfig.FolderName
	root.Parent = workspace

	for i = 1, AfkConfig.PlotCount do
		buildBay(root, i)
	end

	-- THE BEACH THE BAYS ARE CUT OUT OF.
	--
	-- Without it the bays are eight slabs floating over nothing and the gaps
	-- between them are sky, which reads as an unfinished level from any angle
	-- below the horizontal. One plane a stud and a half down turns the same
	-- eight slabs into raked patches on a continuous shore.
	local pitch = AfkConfig.PlotWidth + AfkConfig.PlotGap
	local span = AfkConfig.PlotCount * pitch + 80
	part(root, "Ground", Vector3.new(span, 3, 260),
		CFrame.new(AfkConfig.Origin + Vector3.new(0, -1.5, -40)), SAND, Enum.Material.Sand)

	--[[
		THE SEA, IN TWO TONES.

		One flat plane of water is the flattest thing a beach can have behind it.
		A bright turquoise shallow band along the sand with the deep blue starting
		twenty studs out gives the horizon a hard colour step, which is what a
		cartoon sea actually is -- the same trick the game's own islands use
		between their raked and unraked sand.

		Both are ONE part each for the whole row, not one per bay: two translucent
		parts overlapping read as one much darker one, and per-bay slabs put a
		visible seam every 96 studs.
	]]
	local seaZ = AfkConfig.PlotDepth * 0.5
	part(root, "SeaShallow", Vector3.new(span, 1.2, 26),
		CFrame.new(AfkConfig.Origin + Vector3.new(0, -0.30, seaZ + 13)),
		SEA_SHALLOW, Enum.Material.Glass,
		{ Transparency = 0.28, CanCollide = false, CanQuery = false })
	part(root, "Sea", Vector3.new(span, 1.2, 220),
		CFrame.new(AfkConfig.Origin + Vector3.new(0, -0.40, seaZ + 136)),
		SEA_DEEP, Enum.Material.Glass,
		{ Transparency = 0.22, CanCollide = false, CanQuery = false })

	-- SOMETHING ON THE HORIZON. Six rock stacks out in the deep, so the sea has
	-- a far edge and the shore has a view rather than a blue wall.
	local stacks = Instance.new("Model")
	stacks.Name = "Stacks"
	stacks.Parent = root
	--
	-- TAPERED, in three tiers. The first pass was one box each and they read as
	-- exactly that: grey crates parked on the sea. Three decreasing tiers with a
	-- little rotation on each gives a silhouette that narrows toward the top,
	-- which is the whole difference between a crate and a rock.
	local rng = Random.new(20260820)
	for i = 1, 9 do
		local sx = (i - 5) / 4 * span * 0.46 + rng:NextNumber(-34, 34)
		local sz = seaZ + rng:NextNumber(80, 210)
		local h = rng:NextNumber(12, 32)
		local w = h * rng:NextNumber(0.55, 0.9)
		local yaw = rng:NextNumber(0, 6.28)
		local base = -2   -- sunk, so it grows out of the water rather than onto it
		for tier = 0, 2 do
			local th = h * (0.5 - tier * 0.13)
			local tw = w * (1 - tier * 0.24)
			local ty = base + th * 0.5 + h * (0.42 * tier)
			trim(stacks, "Stack", Vector3.new(tw, th, tw * 0.9),
				CFrame.new(AfkConfig.Origin + Vector3.new(sx, ty, sz))
					* CFrame.Angles(0, yaw + tier * 0.4, 0),
				ROCK:Lerp(Color3.fromRGB(90, 96, 108), tier * 0.18), Enum.Material.Slate)
		end
		-- A green cap, so the stacks belong to the same cartoon as the palms.
		trim(stacks, "StackCap", Vector3.new(w * 0.62, 2.4, w * 0.58),
			CFrame.new(AfkConfig.Origin + Vector3.new(sx, base + h * 0.84 + 1.2, sz))
				* CFrame.Angles(0, yaw, 0),
			LEAF, Enum.Material.Grass)
	end

	--[[
		A DUNE RIDGE ALONG THE BACK.

		The ground plane behind the bays was 848 by 260 studs of dead flat sand
		running to the skyline, which is the one thing that made the shore still
		read as a diorama on a table. A line of big squashed domes gives the land
		side a horizon of its own, and being spheres they cost nothing to make
		look soft.
	]]
	local dunes = Instance.new("Model")
	dunes.Name = "Dunes"
	dunes.Parent = root
	--
	-- WIDE, FLAT AND OVERLAPPING. The first attempt was 22 separate domes and
	-- they read as golf balls dropped on a plain: a sphere only looks like a
	-- dune when it is much wider than it is tall AND its neighbours run into it,
	-- so the eye joins them into one ridge instead of counting them. Sunk by
	-- a third of their height for the same reason.
	--
	-- TWO ROWS, the back one bigger, paler and further out -- cheap aerial
	-- perspective, and it stops the horizon being a single hard line of bumps.
	local drng = Random.new(9981)
	for row = 1, 2 do
		local count = (row == 1) and 30 or 20
		for i = 1, count do
			local dx = (i - (count + 1) * 0.5) / (count * 0.5) * span * 0.55
				+ drng:NextNumber(-14, 14)
			local dw = (row == 1) and drng:NextNumber(80, 150) or drng:NextNumber(130, 230)
			-- Taller than they were, AND sunk far less. See the note on the
			-- bank's mounds in buildBay: -0.34h leaves only 16% of a dome above
			-- the sand, so this ridge was 9-30 studs of dune showing 1.5-4.7 and
			-- the horizon it exists to draw was a faint swell. -0.12h leaves 38%.
			local dh = (row == 1) and drng:NextNumber(14, 24) or drng:NextNumber(26, 44)
			local back = (row == 1) and drng:NextNumber(30, 60) or drng:NextNumber(85, 135)
			dome(dunes, "Dune",
				CFrame.new(AfkConfig.Origin + Vector3.new(dx, -dh * 0.12,
					-AfkConfig.PlotDepth * 0.5 - back)),
				Vector3.new(dw, dh, dw * drng:NextNumber(0.6, 0.85)),
				SAND:Lerp(SAND_TRIM, drng:NextNumber(0.05, 0.3) + (row - 1) * -0.05),
				Enum.Material.Sand)
		end
	end

	-- One board for the whole shore, standing behind the middle bays, carrying
	-- the rate. Quoted from AfkConfig rather than typed, so a sign in the world
	-- cannot end up promising a number the server does not pay.
	local o = AfkConfig.Origin
	local signs = Instance.new("Model")
	signs.Name = "ShoreSign"
	signs.Parent = root
	for _, s in ipairs({ -1, 1 }) do
		part(signs, "SignPost", Vector3.new(1, 16, 1),
			CFrame.new(o + Vector3.new(s * 22, 8, -AfkConfig.PlotDepth * 0.5 - 14)),
			TIMBER_DARK, Enum.Material.Wood)
	end
	board(signs, "ShoreBoard", Vector3.new(48, 8, 0.5),
		CFrame.new(o + Vector3.new(0, 13, -AfkConfig.PlotDepth * 0.5 - 14)),
		"THE LONG SHORE", { Enum.NormalId.Front, Enum.NormalId.Back })
	board(signs, "RateBoard", Vector3.new(30, 3.2, 0.4),
		CFrame.new(o + Vector3.new(0, 7.4, -AfkConfig.PlotDepth * 0.5 - 14)),
		AfkConfig.signText(), { Enum.NormalId.Front })

	root:SetAttribute(AfkConfig.BuiltAttr, true)
	return root
end

--[[
	THE ONE THING ADOPTION MUST NOT KEEP: A STALE RATE.

	Everything else about a saved shore is geometry and the saved copy wins, by
	the rule below. The rate board is not geometry -- it is a QUOTE of a number
	this server pays, and AfkConfig's header is explicit that the card, the till
	and the sign are three readings of one figure that must never diverge. A
	shore built before the wording changed would otherwise stand there promising
	the old one for the life of the place.

	Re-dressed rather than rebuilt: SignKit.dress reuses the SurfaceGui and the
	label that are already on the board, so a hand-tinted sign keeps its dressing
	and only the words move. pcall'd for the same reason build() pcalls it -- a
	board somebody has since deleted must not take the whole shore down with it.
]]
local function refreshRateBoard(root: Instance)
	local signs = root:FindFirstChild("ShoreSign")
	local rate = signs and signs:FindFirstChild("RateBoard")
	if not (rate and rate:IsA("BasePart")) then
		return
	end
	local ok, err = pcall(SignKit.dress, rate, AfkConfig.signText(), { Enum.NormalId.Front })
	if not ok then
		warn("[AfkShore] could not refresh the rate board: " .. tostring(err))
	end
end

--[[
	The adoption question, asked once. Anything already sitting in the place
	under that name wins -- including a hand-dressed one that has lost the
	marker attribute, which is why the test is the FOLDER and not the marker.
]]
function AfkShoreBuilder.ensureWorld(): Folder
	local existing = workspace:FindFirstChild(AfkConfig.FolderName)
	if existing then
		refreshRateBoard(existing)
		return existing
	end
	return AfkShoreBuilder.build()
end

--------------------------------------------------------------------------
-- THE WAY IN
--------------------------------------------------------------------------

--[[
	A BEACH SHELTER AT THE BACK OF THE BEACH, and a prompt on it.

	A door in the world rather than a key on the HUD rail, which is what the
	same feature uses in Seal A Driveway. The reason is local: everything a
	player does in THIS game is a walk-up prompt -- the wash bay, the shop, the
	egg stations, the car spawner, the sell counter -- and a rail key would be
	the only way to reach a place in the game that is not somewhere you walk to.
	It also keeps a 2,265-line MenuHud out of the diff.

	(A rail key is still the better answer for a player already deep in a run
	who wants out NOW. That is a later pass, and it is additive: the remote and
	the service do not care which of the two fires "enter".)

	The row it joins runs along z = -172: car spawner at -69, wash bay at -30,
	sell counter at -3, shop at 26, index terminal at 50. This continues it east
	at 66, which is the last clear ground before the rocks at 81.
]]
AfkShoreBuilder.EntryName = "AfkEntry"
AfkShoreBuilder.EntrySpot = Vector3.new(66, 3.1, -169)

--[[
	THE PORTAL'S COLOURS, and the reason they are not the parasol's.

	Everything else on this beach is coral, sun and sand, so a TEAL pad is the
	one thing in the shop row that cannot be mistaken for scenery -- which is
	the entire job of a door.

	NEON STAYS AT TRANSPARENCY 0. A neon part with any transparency at all
	renders near-black, so depth here is faked by darkening the colour and
	never by fading it.

	AND IT IS TWO-THIRDS STRENGTH, not the full-value foam the bays use. This
	place runs Brightness 3.1 with a bloom threshold of 0.8: a 255-valued neon
	ring at that exposure is a white blob with no ring left in it. Same reason
	the twelve dial marks are painted cream rather than a third emissive.
]]
local PORTAL      = Color3.fromRGB( 72, 196, 178)
local PORTAL_DEEP = Color3.fromRGB( 22,  74,  84)
local PORTAL_PALE = Color3.fromRGB(186, 246, 236)

-- A cylinder lies along its LOCAL X, so a rope between two points is a lookAt
-- given a quarter turn about Y -- the same trap as the parasol discs, one axis
-- along instead of across.
local function rope(m, name, a: Vector3, b: Vector3, thick: number, colour: Color3)
	local mid = (a + b) * 0.5
	return trim(m, name, Vector3.new((b - a).Magnitude, thick, thick),
		CFrame.lookAt(mid, b) * CFrame.Angles(0, math.rad(90), 0),
		colour, Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Cylinder })
end

--[[
	THE HUT.

	WHAT THIS REPLACES, and why. The first version was a plank deck, four
	posts, one flat tilted sheet of canvas and a deckchair made of two white
	slabs -- and the thing it was FOR was invisible: the door was a
	ProximityPrompt hanging on a one-stud transparent cube, so the whole
	attraction read as an empty table somebody had left on the sand. A player
	who never walked within fourteen studs never learned the place existed.

	So the pad is now the building. A ringed teal disc in the middle of the
	floor, motes coming off it, a STEP ON board hung over it on two ropes, and
	a hut built round it that reads as a hut from outside: gable roof, back
	wall, rope rails, a step up. The prompt still works and still says the same
	two words -- it is now the fallback rather than the only way in.
]]
function AfkShoreBuilder.buildEntry(): Model
	local m = Instance.new("Model")
	m.Name = AfkShoreBuilder.EntryName
	m.Parent = workspace

	local o = AfkShoreBuilder.EntrySpot
	local DECK_TOP = 0.7            -- the floor, as a height above o
	local W, D = 15, 13             -- deck footprint
	local POST_X, POST_Z = 6.9, 5.9
	local RIDGE = 10.1              -- roof ridge, above o
	local TILT = 15                 -- roof pitch, degrees

	----------------------------------------------------------------
	-- THE DECK
	----------------------------------------------------------------
	-- The outline trick the bays use: a darker slab a shade larger sitting
	-- just under the boards, so the hut is drawn with a line round its foot
	-- rather than dissolving into the sand it stands on.
	part(m, "DeckTrim", Vector3.new(W + 1.4, 0.9, D + 1.4),
		CFrame.new(o + Vector3.new(0, 0.08, 0)), TIMBER_DARK, Enum.Material.Wood)
	part(m, "Deck", Vector3.new(W, 0.8, D),
		CFrame.new(o + Vector3.new(0, DECK_TOP - 0.4, 0)), TIMBER, Enum.Material.WoodPlanks)
	-- One step at the front. A 0.7 lip reads as a kerb; a step reads as a way in.
	part(m, "Step", Vector3.new(8, 0.55, 1.8),
		CFrame.new(o + Vector3.new(0, -0.02, D * 0.5 + 1.2)), TIMBER, Enum.Material.WoodPlanks)

	----------------------------------------------------------------
	-- POSTS
	----------------------------------------------------------------
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			part(m, "Post", Vector3.new(0.8, 7.9, 0.8),
				CFrame.new(o + Vector3.new(sx * POST_X, DECK_TOP + 3.95, sz * POST_Z)),
				TIMBER_DARK, Enum.Material.Wood)
			-- Rope whipping at the head of each post: the cheapest detail that
			-- says somebody built this out of what washed up.
			for i = 0, 2 do
				disc(m, "PostRope", o,
					Vector3.new(sx * POST_X, DECK_TOP + 6.5 + i * 0.34, sz * POST_Z),
					1.15, 0.3, ROPE)
			end
		end
	end

	----------------------------------------------------------------
	-- THE ROOF
	--
	-- A GABLE, not the flat tilted sheet this was. One sloped slab has a
	-- silhouette from the front that is a straight line, and the hut read as a
	-- table with a lid on it; two slopes meeting at a ridge give it a roof
	-- shape from every angle, which is most of what makes a shape a building.
	--
	-- Rotation about X maps a local +Z offset to y = -d*sin(a), so the sign of
	-- the tilt has to follow the side or the far slope climbs instead of
	-- falling. Hence `sz` on BOTH the angle and the offset.
	----------------------------------------------------------------
	local BAND, BANDS = 1.6, 5
	for _, sz in ipairs({ -1, 1 }) do
		local base = CFrame.new(o + Vector3.new(0, RIDGE, 0))
			* CFrame.Angles(math.rad(sz * TILT), 0, 0)
		for i = 0, BANDS - 1 do
			trim(m, "Canvas", Vector3.new(W + 1.6, 0.36, BAND + 0.06),
				base * CFrame.new(0, 0, sz * (i + 0.5) * BAND),
				(i % 2 == 0) and CANVAS or CREAM, Enum.Material.Fabric)
		end
	end
	part(m, "Ridge", Vector3.new(W + 2.2, 0.55, 0.8),
		CFrame.new(o + Vector3.new(0, RIDGE + 0.34, 0)), TIMBER_DARK, Enum.Material.Wood)

	-- The scalloped valance on both eaves, which is the beach-hut tell.
	--
	-- SMALL AND MANY. At 2.1 studs across and seven a side these read as a row
	-- of beach balls parked on the roof, and the front row sat straight across
	-- the top half of the name board. A frill is only a frill when each scallop
	-- is small against the thing it hangs off.
	for _, sz in ipairs({ -1, 1 }) do
		for i = -5, 5 do
			ball(m, "Scallop", o, Vector3.new(i * 1.42, RIDGE - 2.32, sz * 7.55), 1.3, CREAM)
		end
	end

	----------------------------------------------------------------
	-- THE BACK WALL, which is what turns a canopy into a hut. Planks in two
	-- shades so the wall has grain in it at distance instead of reading as one
	-- brown rectangle, and stopping well short of the roof so the inside still
	-- gets light and the pad is visible from behind.
	----------------------------------------------------------------
	for i = 0, 9 do
		trim(m, "Plank", Vector3.new(1.32, 5.4, 0.36),
			CFrame.new(o + Vector3.new(-6.3 + i * 1.4, DECK_TOP + 2.7, -POST_Z)),
			(i % 2 == 0) and TIMBER or TIMBER:Lerp(TIMBER_DARK, 0.35), Enum.Material.WoodPlanks)
	end
	trim(m, "WallCap", Vector3.new(W - 0.6, 0.4, 0.62),
		CFrame.new(o + Vector3.new(0, DECK_TOP + 5.55, -POST_Z)), TIMBER_DARK, Enum.Material.Wood)

	--[[
		A rope rail down each side, front left open. It frames the pad and stops
		the deck reading as a plank floating on the sand.

		ONE, LOW, THIN AND DARK. Two rails at 0.22 in the pale ROPE cream read
		as scaffolding poles from any angle off the front: they were the
		brightest thing on the build after the pad, they crossed the whole
		elevation, and at rail height they cut straight across the STEP ON
		board behind them. A single cord below the board's bottom edge does the
		framing without joining the composition.
	]]
	local CORD = Color3.fromRGB(150, 118, 78)
	for _, sx in ipairs({ -1, 1 }) do
		rope(m, "Rail",
			o + Vector3.new(sx * POST_X, DECK_TOP + 1.5, -POST_Z),
			o + Vector3.new(sx * POST_X, DECK_TOP + 1.5, POST_Z), 0.15, CORD)
	end

	----------------------------------------------------------------
	-- THE PAD
	--
	-- Concentric discs, each a hair higher and a size smaller than the last,
	-- which draws a set of rings without a single union: the ring you see is
	-- the strip of the disc below that the disc above does not cover.
	--
	-- ALL OF IT IS `trim`. The player walks a flat deck and the pad is paint --
	-- seven stacked discs that were collidable would be a 0.4-stud kerb round
	-- the one part of this build everybody has to stand on.
	----------------------------------------------------------------
	local RINGS = {
		{ 9.8, 0.00, TIMBER_DARK, Enum.Material.Wood  },
		{ 8.9, 0.05, PORTAL_DEEP, Enum.Material.Slate },
		{ 8.1, 0.10, PORTAL,      Enum.Material.Neon  },
		{ 6.5, 0.15, PORTAL_DEEP, Enum.Material.Slate },
		{ 4.3, 0.20, PORTAL,      Enum.Material.Neon  },
		{ 2.6, 0.25, PORTAL_DEEP, Enum.Material.Slate },
		{ 1.3, 0.30, PORTAL_PALE, Enum.Material.Neon  },
	}
	for i, r in ipairs(RINGS) do
		disc(m, ("PadRing%d"):format(i), o,
			Vector3.new(0, DECK_TOP - 0.18 + r[2], 0), r[1], 0.5, r[3], r[4])
	end

	-- Twelve marks round the dial. A cylinder's length is Size.X, but these are
	-- boxes, so the long axis is put on Z and the yaw carries it round -- with
	-- the length on X they would all lie tangential and read as a dashed circle
	-- rather than as a dial.
	for i = 0, 11 do
		local a = math.rad(i * 30)
		trim(m, "PadTick", Vector3.new(0.26, 0.14, 0.8),
			CFrame.new(o + Vector3.new(math.sin(a) * 2.7, DECK_TOP + 0.3, math.cos(a) * 2.7))
				* CFrame.Angles(0, a, 0),
			CREAM, Enum.Material.SmoothPlastic)
	end

	--[[
		WHAT ACTUALLY SAYS "TELEPORTER".

		Rings on the floor read as a painted target; the motes rising out of
		them read as a door, and they cost one instance.

		THE EMITTER HANGS ON ITS OWN FLAT HOST, not on a disc. Every disc here
		is a cylinder standing on Orientation (0, 0, 90), so its local Top
		points sideways in world space -- an emitter parented to one with
		EmissionDirection = Top sprays the motes horizontally off the edge of
		the deck. This host is an ordinary unrotated box, so Top is up.

		LightEmission is low on purpose: see the note on PORTAL. Self-lit
		particles at 1 turn the pad into a white column from thirty studs out.
	]]
	local fxHost = part(m, "PadFx", Vector3.new(4.2, 0.2, 4.2),
		CFrame.new(o + Vector3.new(0, DECK_TOP + 0.4, 0)), PORTAL, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })

	local motes = Instance.new("ParticleEmitter")
	motes.Name = "PortalMotes"
	motes.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	motes.Color = ColorSequence.new(PORTAL_PALE, PORTAL)
	motes.LightEmission = 0.35
	motes.Rate = 16
	motes.Lifetime = NumberRange.new(1.1, 1.9)
	motes.Speed = NumberRange.new(3.5, 6.5)
	motes.SpreadAngle = Vector2.new(9, 9)
	motes.EmissionDirection = Enum.NormalId.Top
	motes.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.25, 0.95),
		NumberSequenceKeypoint.new(1, 0),
	})
	motes.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.18, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	motes.Parent = fxHost

	local glow = Instance.new("PointLight")
	glow.Name = "PortalLight"
	glow.Color = PORTAL
	glow.Brightness = 1.6
	glow.Range = 16
	glow.Shadows = false
	glow.Parent = fxHost

	----------------------------------------------------------------
	-- THE SIGNS
	----------------------------------------------------------------
	--[[
		THE NAME, STANDING ON THE ROOF, which is where every other shop in this
		row puts its own -- the upgrades counter twenty studs west is the
		reference.

		It was hung under the front eave first, which is where the old shelter
		had it, and that is wrong for a building you walk INTO rather than up
		to: at eave height a board across the front is either in the doorway at
		head height or behind the valance from any angle low enough to be a
		player's. Above the roofline it is unobstructed from the whole beach and
		nothing has to duck.
	]]
	board(m, "EntryBoard", Vector3.new(12.5, 2.8, 0.4),
		CFrame.new(o + Vector3.new(0, 10.3, 3.0)), "THE LONG SHORE",
		{ Enum.NormalId.Front, Enum.NormalId.Back })

	--[[
		AND WHAT TO DO WITH IT, on the back wall -- which is the only surface in
		this hut a player can read from OUTSIDE it.

		Two other places were tried and both are worse. Hung from the ridge over
		the pad, the front eave hides it from anybody standing on the sand, and
		the player's own head hides it from anybody standing on the deck. Lying
		flat on the boards in front of the pad it renders, but a floor at eye
		height is thirty degrees off edge-on and the word came out a white
		smear. The back wall is straight down the middle of the doorway, above
		the pad and below the wall cap, and the approach is dead on it.
	]]
	board(m, "PadBoard", Vector3.new(7.6, 2.2, 0.36),
		CFrame.new(o + Vector3.new(0, DECK_TOP + 2.9, -POST_Z + 0.7)), "STEP ON",
		{ Enum.NormalId.Front, Enum.NormalId.Back })

	----------------------------------------------------------------
	-- THE PROPS
	----------------------------------------------------------------
	-- A DECKCHAIR, which is the whole idea of the place in one object. The old
	-- one was two white slabs and read as a dropped door; a frame and stripes
	-- is all a deckchair actually is.
	-- Off to the side and clear of the pad: at x -4.7 the sling overlapped the
	-- outer ring by two studs and put a striped board across the one thing in
	-- the hut the eye is supposed to land on.
	local chair = CFrame.new(o + Vector3.new(-5.6, DECK_TOP, 2.6)) * CFrame.Angles(0, math.rad(-24), 0)
	local sling = chair * CFrame.new(0, 1.5, -0.2) * CFrame.Angles(math.rad(38), 0, 0)
	for _, sx in ipairs({ -1, 1 }) do
		trim(m, "ChairRail", Vector3.new(0.26, 0.26, 5.2), sling * CFrame.new(sx * 1.9, 0, 0),
			TIMBER, Enum.Material.Wood)
		trim(m, "ChairLeg", Vector3.new(0.26, 0.26, 3.4),
			chair * CFrame.new(sx * 1.9, 0.85, 0.7) * CFrame.Angles(math.rad(-52), 0, 0),
			TIMBER, Enum.Material.Wood)
	end
	for i = -2, 2 do
		trim(m, "ChairCanvas", Vector3.new(3.6, 0.16, 0.94), sling * CFrame.new(0, 0, i * 0.98),
			(i % 2 == 0) and CANVAS or CREAM, Enum.Material.Fabric)
	end

	--[[
		A SURFBOARD stood against the west post -- tapered BLOCKS, and the
		reason is a genuine engine trap worth the paragraph.

		This was built first as one Ball part sized (2.6, 8.4, 0.42), on the
		assumption that a Part with Shape = Ball and three different extents
		draws an ellipsoid. IT DOES NOT. Roblox renders a Ball at the SMALLEST
		of its three Size components, so an 8.4-stud board came out as a coral
		marble under half a stud across -- the Size in the data model reads
		back exactly as written the whole time, which is what made it look like
		an occlusion problem for two passes. Verified against a Block and a
		Cylinder of the identical Size: only Ball collapses.

		(The same trap is sitting in buildBay's `rocks` and in the dune ridge,
		both of which ask a Ball for a squashed dome. Not touched here.)

		Five tiers rather than three: the taper IS the surfboard, and three
		steps read as a staircase. The cream band is the middle tier, which is
		free -- a stripe laid on top would have to float off a flat face.

		WEST post, because that is the corner the beach path arrives at; on the
		east it stood behind a palm and the egg plaza.
	]]
	-- Short enough to stand UNDER the eave and out at the front corner. At 8.6
	-- tall against the middle of the west side it broke the roofline and put a
	-- coral stripe straight through the name board from the whole west
	-- approach -- a leaning prop must not out-top the building it leans on.
	local bd = CFrame.new(o + Vector3.new(-POST_X - 0.95, DECK_TOP + 2.6, POST_Z + 0.5))
		* CFrame.Angles(0, math.rad(14), math.rad(-20))
	local BOARD = { { 0.9, 1.15 }, { 1.5, 1.3 }, { 1.9, 1.65 }, { 1.6, 1.45 }, { 1.0, 1.0 } }
	local by = -3.3
	for k, t in ipairs(BOARD) do
		trim(m, "Surfboard", Vector3.new(t[1], t[2], 0.42),
			bd * CFrame.new(0, by + t[2] * 0.5, 0),
			(k == 3) and CREAM or CANVAS, Enum.Material.SmoothPlastic)
		by += t[2]
	end

	-- A COOLER, because the one thing a shelter on a beach should have is a
	-- reason to stop at it.
	local cool = CFrame.new(o + Vector3.new(4.9, DECK_TOP + 0.85, -3.4)) * CFrame.Angles(0, math.rad(12), 0)
	trim(m, "Cooler", Vector3.new(3.4, 1.7, 2.2), cool, Color3.fromRGB(72, 168, 214), Enum.Material.SmoothPlastic)
	trim(m, "CoolerBand", Vector3.new(3.46, 0.32, 2.26), cool * CFrame.new(0, 0.35, 0), CREAM, Enum.Material.SmoothPlastic)
	trim(m, "CoolerLid", Vector3.new(3.6, 0.4, 2.4), cool * CFrame.new(0, 1.0, 0), CREAM, Enum.Material.SmoothPlastic)

	-- A LANTERN inside the front-left eave. Warm, small, and NOT neon: the pad
	-- is the only thing in this hut allowed to glow, or it stops being the
	-- thing the eye goes to.
	--
	-- CAP AND BASE, both dark. A bare pale box on a thin cord read as a sticky
	-- note floating under the roof -- it is the two dark bands top and bottom
	-- that make the same box read as a glass lantern.
	local lz = Vector3.new(-POST_X + 1.5, RIDGE - 3.9, POST_Z - 1.4)
	rope(m, "LanternCord", o + lz + Vector3.new(0, 0.8, 0), o + lz + Vector3.new(0, 2.6, 0), 0.12, CORD)
	trim(m, "LanternBody", Vector3.new(1.15, 1.4, 1.15), CFrame.new(o + lz),
		Color3.fromRGB(246, 208, 128), Enum.Material.SmoothPlastic)
	trim(m, "LanternCap", Vector3.new(1.45, 0.32, 1.45), CFrame.new(o + lz + Vector3.new(0, 0.82, 0)),
		TIMBER_DARK, Enum.Material.Wood)
	trim(m, "LanternBase", Vector3.new(1.35, 0.28, 1.35), CFrame.new(o + lz - Vector3.new(0, 0.79, 0)),
		TIMBER_DARK, Enum.Material.Wood)

	-- A towel over the left rail and a pair of sandals kicked off by the step:
	-- somebody is here, and they are not in a hurry.
	--
	-- INSIDE the rail, not on the post line. Hung flush with the post it read
	-- as a yellow flag on a pole from outside, because there was nothing
	-- visibly holding it up -- moved a half stud in, the rail passes through it
	-- and it reads as cloth over a rope.
	local tw = Vector3.new(-POST_X + 0.55, DECK_TOP + 2.7, -1.2)
	trim(m, "Towel", Vector3.new(0.22, 2.2, 2.8), CFrame.new(o + tw),
		Color3.fromRGB(242, 176, 74), Enum.Material.Fabric)
	trim(m, "TowelStripe", Vector3.new(0.26, 0.5, 2.84),
		CFrame.new(o + tw - Vector3.new(0, 0.7, 0)), CREAM, Enum.Material.Fabric)
	for i, sx in ipairs({ -1, 1 }) do
		trim(m, "Sandal", Vector3.new(0.85, 0.14, 1.9),
			CFrame.new(o + Vector3.new(sx * 0.62 - 5.3, DECK_TOP + 0.08, 4.7))
				* CFrame.Angles(0, math.rad(i * 15), 0),
			Color3.fromRGB(158, 116, 210), Enum.Material.SmoothPlastic)
	end

	----------------------------------------------------------------
	-- THE WIRING PARTS
	--
	-- Geometry only. AfkService hangs the prompt and the touch handler on
	-- these, for the same reason the bays' LeavePost carries no prompt of its
	-- own: a button that exists before anything answers it is a bug waiting to
	-- be found by a player.
	----------------------------------------------------------------
	local anchor = part(m, "PromptAnchor", Vector3.new(1, 1, 1),
		CFrame.new(o + Vector3.new(0, DECK_TOP + 3.2, 2.6)), ROPE, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
	anchor:SetAttribute("AfkEntry", true)

	--[[
		THE PAD'S TRIGGER, and it is a VOLUME rather than any of the discs.

		The rings are `trim`, and `trim` turns CanTouch OFF -- a part that
		cannot be touched can never fire Touched, so the pretty part of the pad
		is physically incapable of being the trigger. This is the one piece
		here that is not decoration.

		FIVE STUDS TALL so it catches a leg or a torso rather than only the
		exact frame a foot clips a disc a third of a stud thick, and a shade
		wider than the outer ring so stepping on the edge counts.
	]]
	local pad = part(m, "EntryPad", Vector3.new(9.2, 5, 9.2),
		CFrame.new(o + Vector3.new(0, DECK_TOP + 2.5, 0)), PORTAL, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = true })
	pad:SetAttribute("AfkEntryPad", true)

	--[[
		WHERE A VISIT PUTS THEM BACK, and it is deliberately NOT the pad.

		`enter` records where the player was standing as the way home, and for
		anybody who arrived by walking onto the pad that IS the pad -- so
		"GO BACK" would drop them onto the trigger they had just used and bounce
		them straight out to the shore again, forever. Standing them in front of
		the hut facing it breaks that loop in geometry rather than in a timer,
		which is the version that cannot drift.

		Four studs clear of the step and five short of the egg station behind
		the camera: the only gap on this stretch of back-beach.
	]]
	local ret = part(m, "ReturnSpot", Vector3.new(1, 1, 1),
		CFrame.lookAt(o + Vector3.new(0, 3.1, 10.4), o + Vector3.new(0, 3.1, 0)),
		ROPE, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
	ret:SetAttribute("AfkReturn", true)

	m.PrimaryPart = m:FindFirstChild("Deck")
	return m
end

function AfkShoreBuilder.ensureEntry(): Model
	local existing = workspace:FindFirstChild(AfkShoreBuilder.EntryName)
	if existing and existing:IsA("Model") then
		return existing
	end
	return AfkShoreBuilder.buildEntry()
end

return AfkShoreBuilder
