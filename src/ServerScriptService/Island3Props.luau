--[[
	Island3Props -- the kawaii prop library for Sakura Cove (Config.ISLANDS[4]).

	Pure builders. Given a parent and a CFrame, each function dresses a Model and
	hands it back. Nothing in here touches terrain, remotes, player state or the
	shop prompt -- Island3Builder owns all of that and calls in here for the
	furniture, which is what stops a scatter loop from having to know how a
	lantern is assembled.

	THE LOCAL FRAME, and the one thing a caller has to know: y = 0 is the GROUND,
	the prop is centred on x = 0, and it FACES -Z, which is cf.LookVector. So
	`Props.kakigoriStall(props, CFrame.lookAt(spot, spot + toSea))` serves toward
	the sea with no extra maths. Two documented exceptions: paperLantern's cf is
	the HANG POINT (a boardwalk beam gives you the top of the cord, not a floor),
	and floatie's cf is the WATER SURFACE.

	PART COST is stated above every builder. The cove loads in the same client as
	the beach and the dunes and has to survive a phone, so nothing here is allowed
	past 60 parts and most of it is half that.

	This module requires nothing. It is deliberately standalone: it is built at the
	same time as its own caller, and a require() edge between two half-written
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
	One palette for the whole area, exported so the builder's boardwalk and these
	props cannot drift apart. Two rules set the numbers:

	* NOTHING GOES NEAR WHITE. This place runs Brightness 3.1 with
	  ExposureCompensation 0.05 and Bloom(0.55, threshold 1.6) -- the same setup
	  that blew the raked-sand tint to flat featureless white the moment it went
	  past rgb(255,214,222). `cream` is the lightest value here and it is 250,238,219
	  on purpose: a kawaii palette is pale, but a pale value with no grain left in
	  it reads as a hole in the screen rather than as a surface.
	* EVERYTHING STAYS WARM. The cove's Atmosphere is cool (Decay 92,124,160) and
	  it drags pink toward mauve at distance -- the same reason the messy sand tint
	  holds its blue down at 124. Every pink below is biased warm against that.

	`blush` is deliberately the exact clean-sand tint. A towel or a parasol panel
	lying on raked sand then reads as one material family instead of as a prop
	somebody dropped onto a beach.

	Twelve entries and no more. The first pass had nineteen, and the extra seven
	were all near-misses of each other -- which is how an area ends up looking like
	three people painted it.
]]
Props.PALETTE = {
	sakura    = RGB(255, 176, 200),   -- the signature: cherry-blossom pink
	blush     = RGB(255, 214, 222),   -- == the raked-sand clean tint
	rose      = RGB(226, 118, 152),   -- the deeper pink: ribs, stripes, shadow lines
	cream     = RGB(250, 238, 219),   -- the lightest value in the area
	mint      = RGB(178, 232, 208),
	turquoise = RGB(142, 216, 224),   -- pastel turquoise, matched to the cove shallows
	lilac     = RGB(206, 188, 234),
	coral     = RGB(255, 142, 124),   -- the one hot accent; used on single small objects only
	charcoal  = RGB(58, 50, 58),      -- soft charcoal: every outline, every face
	amber     = RGB(255, 190, 118),   -- warm lantern light
	stone     = RGB(224, 210, 216),   -- pale pink-grey: toro, boulders
	timber    = RGB(236, 200, 190),   -- pastel timber for the stall and the posts
}
local C = Props.PALETTE

-- Shades are DERIVED, never named. Adding a thirteenth colour called
-- "timberDark" is how the palette quietly stops being the palette.
local function dk(c, f)
	return c:Lerp(C.charcoal, f or 0.26)
end
local function lt(c, f)
	return c:Lerp(C.cream, f or 0.35)
end

----------------------------------------------------------------
-- Materials and shapes
----------------------------------------------------------------
--[[
	SmoothPlastic is the house material for the cove and everything else is an
	exception. Wood and Sandstone both carry heavy grain that fights a pastel --
	the dunes already learned that part Sandstone reads mauve-grey whatever colour
	sits under it -- and a kawaii prop wants flat colour with the softness coming
	from the SILHOUETTE, because Roblox has no bevel. Concrete is the one grainy
	material allowed in, on the stone lantern and the boulders, where a little
	tooth is the difference between stone and painted foam.

	Ground and Asphalt appear nowhere in this file and must not: they are the
	cove's terrain pair and are spoken for globally.
]]
local SMOOTH = Enum.Material.SmoothPlastic
local FABRIC = Enum.Material.Fabric
local CONCRETE = Enum.Material.Concrete
local NEON = Enum.Material.Neon

-- A Part with Shape = Cylinder runs along its LOCAL X, so every upright cylinder
-- in this file is written as Size(height, dia, dia) and turned by UPRIGHT. Miss
-- this and a lantern post lies down in the sand looking like a dropped log.
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))
-- ...and this points a disc's axis along local Z, for anything painted on a face.
local FACING = CFrame.Angles(0, math.rad(90), 0)

--[[
	A Ball part with a non-uniform Size DRAWS as an ellipsoid but COLLIDES as a
	sphere of its SMALLEST axis. Flattened balls are the whole soft-silhouette
	trick here, so the rule this file follows is: any squashed ball is CanCollide
	false, and anything that has to be solid (the boulders) keeps its three axes
	within about 25% of each other so the collision sphere still fills the shape.
]]
local SOFT = { CanCollide = false }
local BALL = { Shape = Enum.PartType.Ball }
local BALLSOFT = { Shape = Enum.PartType.Ball, CanCollide = false }
local CYL = { Shape = Enum.PartType.Cylinder }
local CYLSOFT = { Shape = Enum.PartType.Cylinder, CanCollide = false }
local GHOST = { Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false }
-- The two sloped shapes, and they exist for exactly one caller: the boulders.
-- A wedge's slope faces a direction you have to look up every single time, which
-- is why nothing else in this file uses one -- but a ROCK does not care which way
-- its slope points, and a sloped face is the one thing a Block cannot give you.
local WEDGE = { Shape = Enum.PartType.Wedge }
local CORNER = { Shape = Enum.PartType.CornerWedge }

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
-- Part construction
----------------------------------------------------------------
local function P(parent, name, size, cf, colour, material, extra)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = colour or C.blush
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

--[[
	Every builder takes one of these and then never writes a world coordinate
	again: b(name, size, offset, colour, material, extra, rot) places a part in the
	model's own frame and applies the caller's scale to BOTH the size and the
	offset. That last part is the whole reason a `scale` argument works. The first
	pass scaled only the sizes, and every lantern came out the right size with its
	ribs and its cord still spaced for scale 1 -- which looks like a modelling
	mistake rather than a maths one, so it survived two reads.
]]
local function frame(model, base, s)
	s = s or 1
	return function(name, size, off, colour, material, extra, rot)
		local cf = base * CFrame.new(off.X * s, off.Y * s, off.Z * s)
		if rot then
			cf = cf * rot
		end
		return P(model, name, size * s, cf, colour, material, extra)
	end
end

--[[
	Every model gets an invisible 0.4-stud Root at its base and that Root is the
	PrimaryPart. It costs one part per prop and it buys the caller a pivot that
	means the same thing across all eight builders: PivotTo(groundCF) seats the
	prop on the ground facing LookVector, every time. Naming some structural part
	as the PrimaryPart instead makes PivotTo mean one thing for a lantern and
	another for a boulder, which is the kind of inconsistency that surfaces later
	as one deckchair floating three studs up.
]]
local function root(model, base)
	local r = P(model, "Root", V3(0.4, 0.4, 0.4), base, C.charcoal, SMOOTH, GHOST)
	model.PrimaryPart = r
	return r
end

local function glow(part, colour, range, brightness)
	local l = Instance.new("PointLight")
	l.Color = colour
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false        -- decorative fill only; a cove full of shadow casters is a slideshow
	l.Parent = part
	return l
end

----------------------------------------------------------------
-- Borrowed geometry
----------------------------------------------------------------
local function coveAsset(name)
	local folder = ServerStorage:FindFirstChild("Cove_AssetTest")
	local src = folder and folder:FindFirstChild(name)
	return src and src:Clone() or nil
end

local function ctbProp(name)
	local folder = ServerStorage:FindFirstChild("CTB_Props")
	local src = folder and folder:FindFirstChild(name)
	return src and src:Clone() or nil
end

--[[
	Free models arrive with luggage. Most of Cove_AssetTest shipped with a
	require(assetId) backdoor that an earlier pass stripped by hand -- but a folder
	is not a contract, and the next person to re-import an asset gets the scripts
	back, so this strips them again on every clone instead of trusting what is
	sitting there today. The post-process effects are junk rather than danger:
	CTB_Props.Rock carries a stray SunRaysEffect and Palm a BloomEffect, and while
	neither does anything parented into Workspace, they replicate to every client
	for no reason and they are exactly what somebody later drags into Lighting to
	see what it does.
]]
local function sanitise(model)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("LuaSourceContainer") or d:IsA("Camera") or d:IsA("Sound") or d:IsA("PostEffect") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
		end
	end
end

--[[
	THE SINGLE WORST TRAP IN THIS FILE, so it gets its own function.

	PivotTo moves a model's PIVOT, and a model with no PrimaryPart pivots about its
	WorldPivot -- which on a toolbox model is whatever the uploader happened to
	leave there. Every asset in Cove_AssetTest has one parked at y = 200, tens of
	studs from its own geometry. So `PivotTo(ground + halfHeight)` does NOT put the
	base on the ground: it applies the lift on top of an offset that was already
	there, and the vending machine came out four studs in the air. That reads as a
	height calculation being wrong, which is the wrong thing to go looking at.

	Resetting WorldPivot to the bounding-box centre first makes the pivot mean what
	every line after it assumes it means.
]]
local function centrePivot(model)
	local bcf, size = model:GetBoundingBox()
	model.WorldPivot = bcf
	return size
end

--[[
	Seat a cloned model on the ground at `cf`, scaled to stand `targetHeight` tall.

	* Call this BEFORE root(): a PrimaryPart takes over the pivot entirely, and the
	  identical call then means something else again.
	* ScaleTo is ABSOLUTE, not cumulative -- safe on a fresh clone, wrong if
	  anything scaled the model first. Nothing here does.
	* Some of these assets are modelled facing +Z (the vending machine is). `yaw`
	  is how a caller says so, and it is applied AFTER the lift so the model turns
	  about its own base instead of swinging around the caller's origin.
]]
local function seatClone(model, cf, targetHeight, yaw)
	local size = centrePivot(model)
	if targetHeight and size.Y > 0.05 then
		pcall(function()
			model:ScaleTo(targetHeight / size.Y)
		end)
		size = centrePivot(model)
	end
	local place = cf * CFrame.new(0, size.Y * 0.5, 0)
	if yaw then
		place = place * CFrame.Angles(0, yaw, 0)
	end
	model:PivotTo(place)
	return size
end

----------------------------------------------------------------
-- Argument hygiene
----------------------------------------------------------------
-- Every builder is called from a scatter loop, and a scatter loop is exactly
-- where a nil or a stray string turns up. None of these may throw.
local function num(v, default, lo, hi)
	local n = tonumber(v)
	if not n or n ~= n then
		n = default
	end
	return math.clamp(n, lo, hi)
end

local function key(v, default)
	if typeof(v) == "string" then
		return string.lower(v)
	end
	return default
end

--[[
	Deterministic per-position variation. A builder with no seed argument that
	reaches for math.random grows a different rock every boot, which makes two
	screenshots impossible to compare and makes "it moved" un-diagnosable. Keying
	off the placement CFrame means one spot always grows the same rock and no two
	spots match.
]]
local function rngFor(cf, salt)
	local p = cf.Position
	return Random.new(math.floor(p.X * 71.3 + p.Z * 131.7 + p.Y * 17.1) + (salt or 0))
end

----------------------------------------------------------------
-- PAPER LANTERN  --  11 parts, 1 PointLight
----------------------------------------------------------------
--[[
	Props.paperLantern(parent, cf, scale) -> Model

	cf is the HANG POINT, not the ground: the cord starts at cf and the lantern
	hangs beneath it. Every one of these goes under a boardwalk beam, and making
	the caller subtract the drop themselves is how a run of lanterns ends up at
	four different heights.

	PROPORTION. The body is 3.4 wide by 2.9 tall. A real chochin is taller than it
	is wide, and at that ratio a Roblox sphere reads as an egg -- squat and oblate
	is what actually reads as a paper lantern from ten studs away, which is the
	only distance anyone sees it from.

	The body is Neon at Transparency 0, and that is not negotiable: Neon with ANY
	transparency renders near-black under Future lighting, so a softer lantern
	comes from a duller Color3 and never from a transparency. It is amber rather
	than the crimson a real chochin wears -- crimson Neon at this brightness flares
	to a flat orange disc and the ribbing disappears completely.
]]
function Props.paperLantern(parent, cf, scale)
	local s = num(scale, 1, 0.2, 6)
	local m = Instance.new("Model")
	m.Name = "PaperLantern"
	local b = frame(m, cf, s)
	root(m, cf)

	local paper = C.amber
	local trim = dk(C.rose, 0.35)

	b("Cord", V3(0.09, 1.1, 0.09), V3(0, -0.5, 0), C.charcoal, SMOOTH, SOFT)
	b("Cap", V3(0.3, 1.15, 1.15), V3(0, -1.28, 0), trim, SMOOTH, CYLSOFT, UPRIGHT)

	local body = b("Body", V3(3.4, 2.9, 3.4), V3(0, -2.85, 0), paper, NEON, BALLSOFT)

	-- Three ribs, sized to the sphere's own radius at each height so they sit ON
	-- the surface rather than cutting into it. Two ribs read as a beach ball; four
	-- turns the whole thing into a barrel.
	for i, r in ipairs({ { -0.62, 3.13 }, { 0, 3.46 }, { 0.62, 3.13 } }) do
		b("Rib" .. i, V3(0.16, r[2], r[2]), V3(0, -2.85 + r[1], 0), trim, SMOOTH, CYLSOFT, UPRIGHT)
	end

	b("Base", V3(0.28, 1.0, 1.0), V3(0, -4.34, 0), trim, SMOOTH, CYLSOFT, UPRIGHT)

	-- The kanji column. Three dark ticks down the front face -- not real glyphs,
	-- and they must not be: a texture of real characters on a 3-stud sphere is
	-- unreadable at any distance, whereas three marks in a vertical line reads as
	-- writing instantly. They are 0.34 thick so they clear the sphere's surface at
	-- every one of the three heights; at 0.14 the middle one sank inside.
	for i, dy in ipairs({ 0.55, 0, -0.55 }) do
		b("Mark" .. i, V3(0.42, 0.5, 0.34), V3(0, -2.85 + dy, -1.58), C.charcoal, SMOOTH, SOFT)
	end

	glow(body, C.amber, 22 * s, 1.5)

	m.Parent = parent
	return m
end

----------------------------------------------------------------
-- STONE LANTERN  --  15 parts, 1 PointLight
----------------------------------------------------------------
--[[
	Props.stoneLantern(parent, cf, scale) -> Model   (cf is the ground)

	A toro, 9.2 studs tall at scale 1, which is about head-and-a-half on a 5-stud
	avatar -- the toolbox toro in Cove_AssetTest is 6.9 and it vanishes into the
	sand from any distance at all.

	HAND-BUILT RATHER THAN CLONED, on purpose. The vetted StoneLantern asset is a
	perfectly good toro but two of its four meshes carry a SurfaceAppearance, and a
	SurfaceAppearance keeps its own colour no matter what you set Part.Color to --
	so it can never be tinted to the cove's pink-grey and would sit in the sand as
	the one cold blue-grey object in the area. It also has no way to glow.

	THE FIRE BOX IS FOUR POSTS, NOT A BOX WITH HOLES. Roblox has no CSG here worth
	spending on, and the openings between four corner posts are what let the Neon
	core actually show -- a solid box with a light inside is a box.

	The cap is a three-course stepped pyramid rather than a smooth cone. It steps
	visibly up close, and that is fine: everything else in this area is stacked
	primitives too, so a stepped roof reads as style rather than as a shortcut.
]]
function Props.stoneLantern(parent, cf, scale)
	local s = num(scale, 1, 0.2, 6)
	local m = Instance.new("Model")
	m.Name = "StoneLantern"
	local b = frame(m, cf, s)
	root(m, cf)

	-- Pale stone pulled a touch toward sakura. At a straight grey it read as
	-- imported from the dunes; at any more pink than this it read as candy.
	local st = C.stone:Lerp(C.sakura, 0.14)
	local stDark = dk(st, 0.18)

	b("Base", V3(3.5, 1.1, 3.5), V3(0, 0.35, 0), stDark, CONCRETE)          -- sunk 0.2 into the sand
	b("Plinth", V3(2.9, 0.7, 2.9), V3(0, 1.25, 0), st, CONCRETE)
	b("Shaft", V3(2.9, 1.25, 1.25), V3(0, 3.05, 0), st, CONCRETE, CYL, UPRIGHT)
	b("Platform", V3(2.7, 0.6, 2.7), V3(0, 4.8, 0), st, CONCRETE)

	for i, o in ipairs({ V3(-0.85, 0, -0.85), V3(0.85, 0, -0.85), V3(-0.85, 0, 0.85), V3(0.85, 0, 0.85) }) do
		b("BoxPost" .. i, V3(0.45, 2.0, 0.45), V3(o.X, 6.1, o.Z), st, CONCRETE)
	end

	local core = b("Flame", V3(1.35, 1.35, 1.35), V3(0, 6.1, 0), C.amber, NEON, BALLSOFT)

	b("BoxLid", V3(2.5, 0.4, 2.5), V3(0, 7.3, 0), st, CONCRETE)
	b("Cap1", V3(3.6, 0.45, 3.6), V3(0, 7.72, 0), st, CONCRETE)
	b("Cap2", V3(2.75, 0.45, 2.75), V3(0, 8.17, 0), st, CONCRETE)
	b("Cap3", V3(1.85, 0.45, 1.85), V3(0, 8.62, 0), st, CONCRETE)
	b("Finial", V3(0.85, 0.85, 0.85), V3(0, 9.15, 0), lt(st, 0.25), CONCRETE, BALL)

	-- Deliberately shorter range than the paper lanterns. A toro is a marker on a
	-- path, not a light source; at range 26 a line of them washed the whole shore
	-- flat and the paper lanterns stopped being the bright thing.
	glow(core, C.amber, 15 * s, 1.1)

	m.Parent = parent
	return m
end

----------------------------------------------------------------
-- SAKURA TREE  --  5 parts cloned / 14 hand-built
----------------------------------------------------------------
--[[
	Props.sakuraTree(parent, cf, scale) -> Model   (cf is the ground)

	CLONES ServerStorage.Cove_AssetTest.SakuraTree when it is there, and it should
	be: two parts for a canopy with real blossom detail is not a thing worth
	competing with out of primitives. Normalised to 22 studs at scale 1 -- the raw
	asset is 37.7 tall, which next to a 5-stud avatar is a forest tree, not the
	ornamental cherry a cove wants.

	THE CANOPY CAN ONLY BE DARKENED. Its pink lives in a texture and the only lever
	is SpecialMesh.VertexColor, which MULTIPLIES -- so the sweep below is a nudge,
	not a repaint. Vector3.new(1, 0.94, 0.95) warms it a shade toward the cove's
	pink. Anything stronger takes it to a dusty rose that, sitting on pink sand,
	reads as a dead tree rather than a blossoming one. Do not try to brighten it.

	The trunk is free (MeshPart, no texture) so it takes the palette cleanly, and
	it is a warm pink-brown rather than the asset's cold slate for exactly the
	reason the dunes retint their borrowed boulders: a borrowed prop that keeps its
	original colour reads as borrowed.

	Every tree carries a part named exactly "PetalSource" for Island3_Client to
	hang its drifting-petal emitter on. CanQuery is false on it so it can never eat
	a ground raycast the scatter is using to place the next prop.
]]
local TRUNK_COLOUR = RGB(126, 96, 100)

function Props.sakuraTree(parent, cf, scale)
	local s = num(scale, 1, 0.2, 5)

	local m = coveAsset("SakuraTree")
	if m then
		m.Name = "SakuraTree"
		sanitise(m)
		for _, d in ipairs(m:GetDescendants()) do
			if d:IsA("SpecialMesh") then
				d.VertexColor = Vector3.new(1, 0.94, 0.95)
			elseif d:IsA("BasePart") then
				if d:IsA("MeshPart") then
					d.Color = TRUNK_COLOUR
					d.Material = SMOOTH
					--[[
						THE TRUNK MESH DOES NOT COLLIDE. A HAND-BUILT CYLINDER DOES.

						This MeshPart ships with CollisionFidelity = Box, and Box means
						the WHOLE bounding box is solid at every height -- including the
						part of it the canopy occupies. Measured on the smallest tree in
						the cove: a horizontal probe at y = +2, +3, +5 and +8 hit solid
						geometry at 4.69 studs from the trunk in every direction, against
						a rendered trunk about a stud and a half thick. The biggest trees
						ran to 8.4 studs on the diagonal. Thirty-four of these ring the
						field, so a player working the perimeter bounces off thin air.

						Hull and PreciseConvexDecomposition were both available and both
						rejected: Hull is still a convex wrap of the branches, and
						Precise makes the branch geometry solid at head height, which is
						the same complaint one storey up. What a player should be able to
						feel is the TRUNK, so the trunk is what gets a collider.
					]]
					d.CanCollide = false
				else
					-- The canopy. Never collidable: the scatter puts these near the
					-- boardwalk and a collidable canopy gives the walkway a soft wall
					-- eight studs up that nothing in the scene explains.
					d.CanCollide = false
				end
			end
		end

		local bsz = seatClone(m, cf, 22 * s)
		-- The collider the mesh no longer provides: an invisible cylinder the width
		-- of the drawn trunk, stopping under the canopy. CanQuery stays TRUE -- an
		-- invisible solid that spatial queries cannot see is the exact trap the
		-- beach-gate siting note in Island3Builder is about.
		-- Shape = Cylinder runs along LOCAL X, so the size is (height, dia, dia)
		-- and UPRIGHT stands it up. Get this the intuitive way round and the tree
		-- gets a log lying across the sand instead of a trunk.
		local H = 22 * s
		P(m, "TrunkCollider", V3(H * 0.62, H * 0.10, H * 0.10),
			cf * CFrame.new(0, H * 0.31, 0) * UPRIGHT, TRUNK_COLOUR, SMOOTH,
			{ Transparency = 1, CanCollide = true, CanTouch = false, Shape = Enum.PartType.Cylinder })
		-- Sized off the model footprint rather than the canopy Part: that Part is
		-- 3.3 studs across and carries a SpecialMesh scaled 2.89, so its Size says
		-- nothing at all about how wide the blossom actually renders.
		P(m, "PetalSource", V3(bsz.X * 0.8, 2, bsz.Z * 0.8),
			cf * CFrame.new(0, bsz.Y * 0.72, 0), C.sakura, SMOOTH, GHOST)
		root(m, cf)
		m.Parent = parent
		return m
	end

	-- Hand-built fallback: about 21 studs, same silhouette, 14 parts.
	m = Instance.new("Model")
	m.Name = "SakuraTree"
	local b = frame(m, cf, s)
	root(m, cf)
	local rng = rngFor(cf, 401)

	-- A trunk of three segments each leaning a little further than the last. One
	-- straight cylinder reads as a lamp post; the lean is the entire difference.
	local segs = {
		{ V3(4.6, 2.0, 2.0), V3(0, 2.3, 0), 0 },
		{ V3(4.2, 1.6, 1.6), V3(0.4, 6.4, 0.2), 6 },
		{ V3(3.8, 1.25, 1.25), V3(1.1, 10.2, 0.5), 11 },
	}
	for i, seg in ipairs(segs) do
		b("Trunk" .. i, seg[1], seg[2], TRUNK_COLOUR, SMOOTH, CYL,
			CFrame.Angles(0, 0, math.rad(90 + seg[3])))
	end

	for i = 1, 3 do
		local a = rng:NextNumber(0, math.pi * 2)
		b("Bough" .. i, V3(4.6, 0.8, 0.8), V3(math.cos(a) * 1.6, 12.4, math.sin(a) * 1.6),
			TRUNK_COLOUR, SMOOTH, CYL,
			CFrame.Angles(0, -a, 0) * CFrame.Angles(0, 0, math.rad(52)))
	end

	-- Six flattened balls in three pinks. One ball in one pink is a lollipop; the
	-- overlap plus the tone split is what makes it read as foliage.
	local blobs = {
		{ V3(10.0, 6.4, 10.0), V3(0, 15.2, 0), C.sakura },
		{ V3(7.4, 4.8, 7.4), V3(-3.8, 13.8, 1.5), C.blush },
		{ V3(6.8, 4.4, 6.8), V3(3.6, 14.1, -1.7), lt(C.sakura, 0.3) },
		{ V3(6.0, 4.0, 6.0), V3(0.6, 13.2, 3.8), C.blush },
		{ V3(5.4, 3.8, 5.4), V3(-1.5, 17.0, -1.1), C.sakura },
		{ V3(4.6, 3.4, 4.6), V3(2.8, 16.4, 2.1), lt(C.blush, 0.4) },
	}
	for i, blob in ipairs(blobs) do
		b("Blossom" .. i, blob[1], blob[2], blob[3], SMOOTH, BALLSOFT)
	end

	b("PetalSource", V3(11, 2, 11), V3(0, 15.2, 0), C.sakura, SMOOTH, GHOST)

	m.Parent = parent
	return m
end

----------------------------------------------------------------
-- VENDING MACHINE  --  14 parts, 1 PointLight
----------------------------------------------------------------
--[[
	Props.vendingMachine(parent, cf, flavour) -> Model   (cf is the ground)

	`flavour` picks the tint and is free-form: an unknown string, a nil, or a
	number all fall back to sakura rather than erroring, because this is called
	from a scatter table somebody will edit later.

	HAND-BUILT, AND THE TOOLBOX CLONE IS GONE. This used to prefer
	Cove_AssetTest.VendingMachine and tint its decals, on the theory that two
	parts and some artwork is cheaper than fourteen parts. Measured, that clone
	was the single worst-looking thing in Sakura Cove:

	  * its body is one grey Plastic box carrying the SAME decal on all six
	    faces, and tinting that decal pink rendered as a solid NAVY box -- the
	    only saturated dark value anywhere in a pastel island, and it dominated
	    every view of the plaza;
	  * the front panel is a 0.05-stud plane at Transparency 8.00 (out of legal
	    range) carrying a PHOTOGRAPH of a real navy Asahi machine -- photoreal
	    texture in a hand-modelled cartoon world;
	  * that plane is 9.89 studs wide against a 4.48-stud body, so from any three
	    quarter angle the photo visibly overhangs the box it is bolted to.

	It also accounted for all 21 Decals on the island. The brief asks for "pink
	anime vending machines"; fourteen flat-coloured parts are what actually
	delivers that, and they cost eight parts each over a clone that was wrong.

	`flavour` picks the tint and is free-form: an unknown string, a nil, or a
	number all fall back to sakura rather than erroring.
]]
local VEND_FLAVOURS = {
	sakura = C.sakura,
	peach = C.coral,
	melon = C.mint,
	ramune = C.turquoise,
	grape = C.lilac,
	milk = C.cream,
}

function Props.vendingMachine(parent, cf, flavour)
	local tint = VEND_FLAVOURS[key(flavour, "sakura")] or C.sakura

	local m = Instance.new("Model")
	m.Name = "VendingMachine"
	local b = frame(m, cf, 1)
	root(m, cf)

	b("Body", V3(4.6, 8.0, 2.8), V3(0, 4.0, 0), tint)
	b("BodyCap", V3(4.85, 0.4, 3.0), V3(0, 8.2, 0), C.charcoal)
	-- A thin warm lip at the foot. At golden hour the machine's front is in its
	-- own shadow and without this it is a dark slab; the lip puts a little spill
	-- on the paving under it, which is what says "this thing is on".
	b("GlowLip", V3(4.4, 0.22, 0.32), V3(0, 0.35, -1.44), C.amber, NEON, SOFT)
	local header = b("HeaderSign", V3(4.2, 1.0, 0.25), V3(0, 7.4, -1.48), lt(tint, 0.2), NEON, SOFT)

	-- SmoothPlastic with Reflectance, NEVER Glass. Material Glass culls any
	-- transparent object BEHIND it in this project, and the whole point of the
	-- window is the cans behind it -- a Glass window here is an empty window.
	b("Window", V3(2.8, 4.2, 0.16), V3(-0.35, 5.2, -1.44), lt(C.turquoise, 0.5), SMOOTH,
		{ Transparency = 0.55, Reflectance = 0.1, CanCollide = false })

	for row = 0, 1 do
		for col = 0, 2 do
			b("Can" .. row .. col, V3(0.85, 0.5, 0.5),
				V3(-1.25 + col * 0.9, 4.3 + row * 1.4, -1.05),
				({ C.sakura, C.mint, C.lilac })[col + 1], SMOOTH, CYLSOFT, UPRIGHT)
		end
	end

	b("SelectPanel", V3(0.9, 2.2, 0.14), V3(1.7, 4.6, -1.44), C.amber, NEON, SOFT)
	b("Slot", V3(2.0, 0.5, 0.18), V3(-0.35, 1.6, -1.44), C.charcoal, SMOOTH, SOFT)
	-- Range 13, not 20. Three of these stand 22 studs apart in a rank on the
	-- plaza's north edge; at 20 their volumes overlap two deep and the plaza
	-- washes out flat, which is the same trade the boardwalk lanterns make.
	glow(header, tint:Lerp(C.amber, 0.45), 13, 1.0)

	m.Parent = parent
	return m
end

----------------------------------------------------------------
-- KAKIGORI STALL  --  54 parts, 2 PointLights
----------------------------------------------------------------
--[[
	Props.kakigoriStall(parent, cf) -> Model   (cf is the ground, counter faces LookVector)

	A shaved-ice yatai: 12 wide, 8 deep, and 16.7 tall to the top of the cherry on
	its roof sign. NO ShopPrompt -- Island3Builder attaches that. What is provided
	instead is a part named "PromptAnchor" hanging in the serving hatch, and the
	counter is named "CounterTop", so the caller has two obvious things to hang a
	prompt on without having to guess at a part index.

	The toolbox yatai in Cove_AssetTest is charming and it is 212 parts -- more
	than four times this whole model and 83% of the entire asset folder's part
	budget. It is also a RAMEN cart, so most of that spend is bowls and bottles
	that would have to be deleted and replaced anyway. Hand-built at 54.

	WHY IT IS SHALLOW. 8 studs deep, not 14. The dunes market learned this the
	hard way: past about 10 studs a stall becomes a cave, everything against the
	back wall stops reading through the awning, and the inside goes to flat shadow.
	A food stall is wide and shallow, and its stock lives ON the counter.

	THE ROOF SIGN IS THE PROP. At 12 studs wide the stall itself is a shed; the
	thing that says "kakigori" from fifty studs out is a 4-stud glowing ice dome on
	a stick above the roofline. A first pass put the sign on the counter face where
	it was invisible behind the awning from every approach angle.
]]
function Props.kakigoriStall(parent, cf)
	local m = Instance.new("Model")
	m.Name = "KakigoriStall"
	local b = frame(m, cf, 1)
	root(m, cf)

	local wood = C.timber
	local woodDark = dk(C.timber, 0.34)

	-- Chassis. A stall standing on its own plinth reads as built; the same stall
	-- standing on bare sand reads as parked, and this one is a CART, so it gets
	-- two wheels proud of the sides to say so at almost no cost.
	b("Plinth", V3(12.8, 0.9, 8.6), V3(0, 0.45, 0), woodDark)
	b("Deck", V3(12.0, 0.35, 8.0), V3(0, 1.07, 0), C.cream)
	for i, sx in ipairs({ -6.55, 6.55 }) do
		-- No rotation: a Cylinder's axis is already local X, which is the axle.
		b("Wheel" .. i, V3(0.5, 2.4, 2.4), V3(sx, 1.2, 1.4), woodDark, SMOOTH, CYL)
	end

	for i, o in ipairs({ V3(-5.5, 0, -3.5), V3(5.5, 0, -3.5), V3(-5.5, 0, 3.5), V3(5.5, 0, 3.5) }) do
		b("Post" .. i, V3(0.55, 7.7, 0.55), V3(o.X, 5.1, o.Z), wood)
	end

	-- Counter and serving hatch. The hatch is an OPENING, made by leaving a
	-- 4.8-stud gap between two boards rather than by cutting anything: the gap is
	-- where the player looks in and where the prompt lives.
	b("CounterTop", V3(12.6, 0.5, 2.3), V3(0, 4.4, -3.25), C.cream)
	b("CounterFace", V3(12.0, 3.0, 0.5), V3(0, 2.7, -4.15), C.sakura)
	b("CounterTrim", V3(12.2, 0.4, 0.62), V3(0, 3.9, -4.19), C.rose, SMOOTH, SOFT)
	for i, sx in ipairs({ -4.15, 4.15 }) do
		b("HatchBoard" .. i, V3(3.5, 1.8, 0.42), V3(sx, 6.5, -3.6), C.cream)
	end

	-- Back wall in two panels, leaving a 5.3-stud doorway for the noren.
	for i, sx in ipairs({ -4.3, 4.3 }) do
		b("BackPanel" .. i, V3(3.3, 5.9, 0.45), V3(sx, 4.2, 3.68), wood)
	end

	-- Noren. Three hanging panels with a cream band across them -- the band is
	-- what makes it a noren instead of three pink rectangles, and it costs three
	-- non-collidable parts.
	b("NorenRail", V3(5.9, 0.35, 0.42), V3(0, 6.7, 3.55), woodDark)
	for i, sx in ipairs({ -1.9, 0, 1.9 }) do
		b("NorenPanel" .. i, V3(1.7, 2.9, 0.18), V3(sx, 5.05, 3.55), C.sakura, FABRIC, SOFT)
		b("NorenBand" .. i, V3(1.7, 0.5, 0.22), V3(sx, 6.0, 3.55), C.cream, FABRIC, SOFT)
	end

	-- Awning: seven slats rather than one sheet, so it reads as cloth, and pitched
	-- forward 10 degrees. Rotating about +X RAISES the -Z end, so the sign on the
	-- angle is negative -- get that backwards and the awning tips away from the
	-- customer and shades the back wall nobody is looking at.
	for i = 1, 7 do
		b("AwningSlat" .. i, V3(1.72, 0.3, 8.6), V3(-6.88 + i * 1.72, 9.15, -0.55),
			(i % 2 == 1) and C.sakura or C.cream, FABRIC, SOFT,
			CFrame.Angles(math.rad(-10), 0, 0))
	end
	for i, sz in ipairs({ -3.4, 3.4 }) do
		b("Beam" .. i, V3(12.9, 0.45, 0.45), V3(0, 9.15, sz), wood)
	end
	b("Ridge", V3(12.9, 0.45, 1.2), V3(0, 10.1, 3.3), C.rose)

	-- The roof sign: a cup of shaved ice, syrup and a cherry.
	b("SignPost", V3(0.55, 1.4, 0.55), V3(0, 10.3, 0.2), woodDark)
	b("SignCup", V3(1.9, 2.8, 2.8), V3(0, 11.95, 0.2), C.turquoise, SMOOTH, CYL, UPRIGHT)
	b("SignRim", V3(0.4, 3.4, 3.4), V3(0, 13.1, 0.2), C.cream, SMOOTH, CYL, UPRIGHT)
	-- Neon at Transparency 0, in cream rather than white: pure white Neon under
	-- this place's bloom is a featureless blob with no dome shape left in it.
	local dome = b("SignIce", V3(3.5, 2.8, 3.5), V3(0, 14.2, 0.2), C.cream, NEON, BALLSOFT)
	local syrups = {
		{ V3(-0.95, 15.0, -0.35), C.sakura },
		{ V3(0.9, 14.95, 0.85), C.mint },
		{ V3(0.15, 15.25, 0.25), C.lilac },
	}
	for i, sy in ipairs(syrups) do
		b("SignSyrup" .. i, V3(1.6, 0.95, 1.6), sy[1], sy[2], SMOOTH, BALLSOFT)
	end
	b("SignStem", V3(0.14, 0.75, 0.14), V3(0, 15.85, 0.2), dk(C.mint, 0.45), SMOOTH, SOFT)
	b("SignCherry", V3(0.8, 0.8, 0.8), V3(0, 16.35, 0.2), C.coral, SMOOTH, BALLSOFT)
	glow(dome, lt(C.sakura, 0.35), 26, 1.2)

	-- Stock on the counter, ARRANGED. A shaver at one end and a row of syrups at
	-- the other, both lined up on the same z: scattering them across the counter
	-- is most of what makes a shop read as unfinished.
	b("ShaverBase", V3(1.9, 0.55, 1.7), V3(-3.7, 4.92, -3.2), C.stone)
	b("ShaverColumn", V3(0.75, 2.4, 0.75), V3(-3.7, 6.4, -3.2), C.stone)
	b("ShaverHead", V3(2.0, 0.75, 1.8), V3(-3.7, 7.75, -3.2), C.turquoise)
	b("ShaverCrank", V3(1.5, 0.24, 0.24), V3(-2.55, 7.75, -3.2), C.rose, SMOOTH, CYL)
	for i, col in ipairs({ C.sakura, C.mint, C.lilac }) do
		local bx = 1.25 + i * 0.95
		b("Syrup" .. i, V3(1.5, 0.55, 0.55), V3(bx, 5.4, -3.2), col, SMOOTH, CYL, UPRIGHT)
		b("SyrupCap" .. i, V3(0.5, 0.5, 0.5), V3(bx, 6.3, -3.2), C.charcoal, SMOOTH, BALLSOFT)
	end

	b("PromptAnchor", V3(1, 1, 1), V3(0, 5.6, -4.6), C.cream, SMOOTH, GHOST)

	-- One warm fill under the awning. Everything worth looking at in this stall is
	-- under a roof, and the cove's low golden-hour sun rakes in almost horizontally
	-- from one side only -- without this the whole interior is a silhouette in a
	-- pink box for half the day.
	-- SmoothPlastic, not Neon, even though it is invisible: a Neon part with any
	-- transparency at all is the single most-repeated bug in this place, and an
	-- invisible Neon anchor is exactly the thing that teaches the next person the
	-- pattern is acceptable. It emits nothing either way -- the PointLight does
	-- the work.
	local fill = b("StallLight", V3(1, 1, 1), V3(0, 7.2, 0.6), C.amber, SMOOTH, GHOST)
	glow(fill, C.amber, 34, 1.15)

	m.Parent = parent
	return m
end

----------------------------------------------------------------
-- BEACH SET  --  30 parts ("heart") / 34 ("panda") / 30 ("pastel")
----------------------------------------------------------------
--[[
	Props.beachSet(parent, cf, variant) -> Model   (cf is the ground, the set faces LookVector)

	variant is "heart", "panda" or "pastel"; anything else falls through to
	"pastel". A cluster, not a single object: parasol, chair, towel, sandals and a
	drink, laid out around cf so a scatter loop places a scene with one call.

	THE PARASOL IS HAND-BUILT AND IT SHOULD NOT BE. CTB_Props.UmbrellaWide is the
	vetted answer -- it retints completely and its wedge canopy would take stripes
	for free -- but it is 48 parts, and with the deckchair's 14 that puts one beach
	set over 70 before anything is on the sand. Three stacked discs and a finial
	cost five. What is lost is the scalloped wedge rim; what is gained is being
	able to put six of these along a shoreline. If the cove ever ends up with only
	two or three sets, swapping UmbrellaWide back in is the better-looking call.

	The deckchair IS cloned: 14 parts for a chair with a working Seat is a fair
	price, and it already faces -Z, so it needs no yaw. It is retinted BY MATERIAL
	rather than wholesale -- Sand becomes the canvas, Wood becomes pastel timber,
	Metal becomes pale stone. Sweeping every part to one colour turned it into a
	single pink blob with no frame visible at all.

	THE LAY-FLAT RULE applies to everything loose here: the towel and the sandals
	are thinnest on Y, so they lie down. Nothing loose is collidable either -- a
	towel you trip over is worse than no towel.
]]
local function parasol(m, base, canopy, ribs, panda)
	local b = frame(m, base, 1)
	b("Pole", V3(9.0, 0.42, 0.42), V3(0, 4.5, 0), lt(C.timber, 0.3), SMOOTH, CYL, UPRIGHT)
	-- Three discs of falling diameter make a shallow cone. A single flat disc read
	-- as a table top from every angle; the step is what says "canopy".
	b("Canopy1", V3(0.4, 11.4, 11.4), V3(0, 8.2, 0), canopy, FABRIC, CYLSOFT, UPRIGHT)
	b("Canopy2", V3(0.4, 7.8, 7.8), V3(0, 8.6, 0), ribs, FABRIC, CYLSOFT, UPRIGHT)
	b("Canopy3", V3(0.45, 4.2, 4.2), V3(0, 9.0, 0), canopy, FABRIC, CYLSOFT, UPRIGHT)
	b("Finial", V3(0.8, 0.8, 0.8), V3(0, 9.45, 0), lt(C.timber, 0.3), SMOOTH, BALLSOFT)

	if not panda then
		return
	end

	--[[
		ROUND EARS ON THE CROWN. THEY WERE TWO BLACK TRIANGLES THROUGH THE CANOPY.

		The old pair were 2.6-stud BOXES TURNED 45 DEGREES, standing at radius 3.6 --
		out on the wide disc a third of the way to its rim, and tall enough to clear
		the finial. Half-buried, a box at 45 degrees shows as a TRIANGLE, so what the
		parasol actually had on it was two black spikes stabbing up through the middle
		of a white canopy. That reads as damage, not as a panda.

		Balls instead, moved IN to the crown beside the finial where they sit on the
		smallest disc: from the ground the top of this parasol is now a little round
		head with two round ears, which is what it was always meant to be.

		RADIUS 2.0 IS THE NUMBER THAT MATTERS. It puts each ear's lower half inside
		Canopy2 and Canopy3, so the ball is cut off by the discs rather than hanging
		below them -- at the old radius a ball would have dangled under the canopy,
		in the one place a player standing beneath it is guaranteed to be looking.
	]]
	for i, sx in ipairs({ -1.9, 1.9 }) do
		b("Ear" .. i, V3(2.0, 2.0, 2.0), V3(sx, 9.25, -0.6), C.charcoal, SMOOTH, BALLSOFT)
	end
	-- ...and the FACE goes on the UNDERSIDE, because a player standing under a
	-- parasol is looking up at it. Painted on top it is a face for the seagulls.
	for i, sx in ipairs({ -1.9, 1.9 }) do
		b("EyePatch" .. i, V3(0.14, 1.9, 1.9), V3(sx, 7.93, -2.4), C.charcoal, SMOOTH, CYLSOFT, UPRIGHT)
	end
	b("Nose", V3(0.14, 0.9, 0.9), V3(0, 7.93, -0.9), C.charcoal, SMOOTH, CYLSOFT, UPRIGHT)
	for i, sx in ipairs({ -0.35, 0.35 }) do
		b("Mouth" .. i, V3(0.75, 0.14, 0.18), V3(sx, 7.93, 0.15), C.charcoal, SMOOTH, SOFT,
			CFrame.Angles(0, math.rad(sx > 0 and -24 or 24), 0))
	end
end

function Props.beachSet(parent, cf, variant)
	local v = key(variant, "pastel")
	if v ~= "heart" and v ~= "panda" then
		v = "pastel"
	end

	local m = Instance.new("Model")
	m.Name = "BeachSet"
	local b = frame(m, cf, 1)
	root(m, cf)

	local canvas = (v == "panda") and C.cream or C.blush
	local accent = (v == "heart") and C.sakura or C.turquoise

	----------------------------------------------------------------
	-- parasol
	----------------------------------------------------------------
	if v == "panda" then
		parasol(m, cf * CFrame.new(-1.4, 0, -0.4), C.cream, lt(C.stone, 0.4), true)
	elseif v == "heart" then
		parasol(m, cf * CFrame.new(-1.4, 0, -0.4), C.blush, C.sakura, false)
	else
		parasol(m, cf * CFrame.new(-1.4, 0, -0.4), C.blush, C.mint, false)
	end

	----------------------------------------------------------------
	-- towel
	----------------------------------------------------------------
	-- Given its own rotated frame rather than a yaw on every part: a towel laid
	-- exactly square to the parasol looks placed by a machine.
	local tb = frame(m, cf * CFrame.new(-5.0, 0, 2.8) * CFrame.Angles(0, math.rad(18), 0), 1)
	if v == "heart" then
		-- A heart is a square turned 45 degrees with a disc on each of its two upper
		-- edges, the discs' diameter equal to the square's side. Three parts, and
		-- the only construction that comes out symmetric without a mesh.
		tb("TowelBody", V3(5.0, 0.2, 5.0), V3(0, 0.11, 0), C.sakura, FABRIC, SOFT,
			CFrame.Angles(0, math.rad(45), 0))
		for i, sx in ipairs({ -1.77, 1.77 }) do
			tb("TowelLobe" .. i, V3(0.2, 5.0, 5.0), V3(sx, 0.11, -1.77), C.sakura, FABRIC, CYLSOFT, UPRIGHT)
		end
	else
		tb("TowelBody", V3(5.2, 0.2, 8.4), V3(0, 0.11, 0), canvas, FABRIC, SOFT)
		for i, sz in ipairs({ -4.2, 4.2 }) do
			tb("TowelEnd" .. i, V3(0.2, 5.2, 5.2), V3(0, 0.11, sz), canvas, FABRIC, CYLSOFT, UPRIGHT)
		end
	end

	----------------------------------------------------------------
	-- chair
	----------------------------------------------------------------
	local chair = ctbProp("Deckchair")
	if chair then
		chair.Name = "Deckchair"
		sanitise(chair)
		seatClone(chair, cf * CFrame.new(2.9, 0, -0.2) * CFrame.Angles(0, math.rad(-12), 0), 5.0)
		--[[
			THREE THINGS THE CLONE ARRIVES WRONG, all of them invisible in a
			screenshot and all of them obvious the moment somebody walks into one.

			1. IT HAS A Seat, AND THE Seat CANNOT WORK. It ships CanTouch = false,
			   and a Seat with no Touched event can never seat anybody -- so what is
			   standing on the sand is an affordance that does nothing. It is
			   deleted rather than repaired: an auto-seating Touched volume in the
			   middle of a rakeable beach grabs a player who was walking past with a
			   sifter, which is worse than no lounger to sit on.
			2. NOT ONE OF ITS FOURTEEN PARTS IS COLLIDABLE, so the whole lounger is
			   a ghost you stroll through.
			3. Its parts are named "Part" and "Union", eight and five of them, which
			   across seven beach sets is 91 anonymous instances in a world where
			   everything else is named.
		]]
		local frames, panels = 0, 0
		for _, d in ipairs(chair:GetDescendants()) do
			if d:IsA("Seat") or d:IsA("VehicleSeat") then
				d:Destroy()
			elseif d:IsA("BasePart") then
				if d.Material == Enum.Material.Sand then
					d.Color, d.Material = canvas, FABRIC
				elseif d.Material == Enum.Material.Wood then
					d.Color, d.Material = lt(C.timber, 0.2), SMOOTH
				elseif d.Material == Enum.Material.Metal then
					d.Color, d.Material = C.stone, SMOOTH
				else
					d.Color, d.Material = canvas, SMOOTH
				end
				d.CanCollide = true
				if d.Name == "Part" then
					frames += 1
					d.Name = "Frame" .. frames
				elseif d.Name == "Union" then
					panels += 1
					d.Name = "Panel" .. panels
				end
			end
		end
		chair.Parent = m
	else
		-- 6-part lounger. Rotating about +X lifts the -Z end, so the backrest's
		-- recline angle is NEGATIVE to lean the +Z end back; positive built a chair
		-- that tipped forward onto the sitter's face.
		local lb = frame(m, cf * CFrame.new(2.9, 0, -0.2), 1)
		lb("LoungerSeat", V3(3.2, 0.3, 4.6), V3(0, 1.5, 0), canvas, FABRIC)
		lb("LoungerBack", V3(3.2, 0.3, 3.2), V3(0, 2.35, 2.2), canvas, FABRIC, nil,
			CFrame.Angles(math.rad(-38), 0, 0))
		for i, o in ipairs({ V3(-1.3, 0, -1.9), V3(1.3, 0, -1.9), V3(-1.3, 0, 1.9), V3(1.3, 0, 1.9) }) do
			lb("LoungerLeg" .. i, V3(1.4, 0.28, 0.28), V3(o.X, 0.7, o.Z), lt(C.timber, 0.2), SMOOTH, CYL, UPRIGHT)
		end
	end

	----------------------------------------------------------------
	-- litter that makes it look lived in
	----------------------------------------------------------------
	for i, sx in ipairs({ -0.75, 0.75 }) do
		b("Sandal" .. i, V3(1.5, 0.16, 3.4), V3(1.0 + sx, 0.09, 4.6), accent, SMOOTH, SOFT,
			CFrame.Angles(0, math.rad(sx > 0 and 22 or -14), 0))
		b("SandalStrap" .. i, V3(1.3, 0.16, 0.5), V3(1.0 + sx, 0.2, 3.9), dk(accent, 0.2), SMOOTH, SOFT,
			CFrame.Angles(0, math.rad(sx > 0 and 22 or -14), 0))
	end
	b("Cup", V3(1.9, 1.2, 1.2), V3(4.6, 0.95, 2.2), C.cream, SMOOTH, CYL, UPRIGHT)
	b("CupLid", V3(0.2, 1.35, 1.35), V3(4.6, 2.0, 2.2), C.sakura, SMOOTH, CYLSOFT, UPRIGHT)
	b("CupStraw", V3(2.0, 0.22, 0.22), V3(4.95, 2.7, 2.2), C.mint, SMOOTH, CYLSOFT,
		CFrame.Angles(0, 0, math.rad(74)))

	m.Parent = parent
	return m
end

----------------------------------------------------------------
-- FLOATIE  --  2 parts cloned / 21 (flamingo), 20 (boba), 26 (cat)
----------------------------------------------------------------
--[[
	Props.floatie(parent, cf, kind) -> Model   kind is "flamingo", "boba" or "cat"

	cf is the WATER SURFACE, not the seabed. Every floatie here is built with y = 0
	on the waterline and its hull straddling it, so the caller passes the sea top
	and gets something that looks like it is floating rather than resting on a
	sheet of glass.

	EVERYTHING IS CanCollide FALSE. These are 13-16 studs across and they sit in
	the swimmable shallows; a solid one is a wall in the water that the player can
	see straight through, which is far more confusing than swimming through a
	flamingo.

	Scaled GIANT on purpose -- 15 studs, three times an avatar. At a believable
	real-world 5 studs they read as litter floating in the bay.

	"flamingo" clones Cove_AssetTest.FloatieFlamingo, which is one MeshPart with a
	sculpted head, beak and eye already in the right pastel pink. Nothing built out
	of primitives competes with that for one part.
]]
local function floatieFlamingoBuilt(m, cf)
	local b = frame(m, cf, 1)
	for i = 1, 10 do
		local a = (i - 1) * math.pi / 5
		b("Ring" .. i, V3(4.4, 4.4, 4.4), V3(math.cos(a) * 5.3, 1.1, math.sin(a) * 5.3),
			C.sakura, SMOOTH, BALLSOFT)
	end
	local neck = {
		{ 2.6, V3(0, 3.2, -5.0) }, { 2.4, V3(0, 4.6, -5.6) }, { 2.2, V3(0, 6.0, -5.6) },
		{ 2.1, V3(0, 7.2, -5.0) }, { 2.0, V3(0, 8.1, -4.2) },
	}
	for i, n in ipairs(neck) do
		b("Neck" .. i, V3(n[1], n[1], n[1]), n[2], C.sakura, SMOOTH, BALLSOFT)
	end
	b("Head", V3(3.0, 3.0, 3.0), V3(0, 9.0, -3.4), C.blush, SMOOTH, BALLSOFT)
	b("Beak", V3(0.7, 0.7, 2.2), V3(0, 8.8, -5.2), C.coral, SMOOTH, SOFT, CFrame.Angles(math.rad(-18), 0, 0))
	b("BeakTip", V3(0.5, 0.5, 0.75), V3(0, 8.5, -6.25), C.charcoal, SMOOTH, SOFT)
	for i, sx in ipairs({ -1.05, 1.05 }) do
		b("Eye" .. i, V3(0.55, 0.55, 0.55), V3(sx, 9.4, -4.3), C.charcoal, SMOOTH, BALLSOFT)
	end
end

local function floatieBoba(m, cf)
	-- Dropped a stud below the waterline before anything is placed, so the cup
	-- sits as low in the water as the ring floaties do. Built flush it drew a
	-- 13-stud cup balanced on the surface with only its rim wet, which reads as
	-- standing on the sea rather than floating in it.
	local b = frame(m, cf * CFrame.new(0, -1.0, 0), 1)
	local cup = { Transparency = 0.35, Reflectance = 0.06, CanCollide = false, Shape = Enum.PartType.Cylinder }
	-- The cup walls are see-through so the tapioca in the bottom actually reads.
	-- SmoothPlastic + Reflectance, never Glass: Glass culls transparent objects
	-- behind it, and behind this one there are seven of them.
	b("CupLower", V3(2.2, 10.0, 10.0), V3(0, 0.9, 0), C.cream, SMOOTH, cup, UPRIGHT)
	b("CupUpper", V3(2.6, 13.0, 13.0), V3(0, 3.3, 0), C.cream, SMOOTH, cup, UPRIGHT)
	b("Tea", V3(2.6, 9.4, 9.4), V3(0, 1.4, 0), C.timber:Lerp(C.charcoal, 0.22), SMOOTH, CYLSOFT, UPRIGHT)
	for i = 1, 7 do
		local a = (i - 1) * math.pi * 2 / 7
		b("Pearl" .. i, V3(1.5, 1.5, 1.5), V3(math.cos(a) * 3.0, 0.75, math.sin(a) * 3.0),
			C.charcoal, SMOOTH, BALLSOFT)
	end
	b("Lid", V3(13.4, 3.4, 13.4), V3(0, 5.4, 0), C.sakura, SMOOTH, BALLSOFT)
	b("LidRim", V3(0.6, 13.6, 13.6), V3(0, 4.7, 0), C.rose, SMOOTH, CYLSOFT, UPRIGHT)
	b("Straw", V3(9.0, 1.5, 1.5), V3(1.9, 8.0, -0.4), C.mint, SMOOTH, CYLSOFT,
		CFrame.Angles(0, 0, math.rad(72)))
	-- Face on the cup's front wall. Every feature is a BALL half-buried in the
	-- surface rather than a disc laid on it: a disc has to be aimed at the local
	-- normal, and on a curved wall that is four rotations to get wrong.
	for i, sx in ipairs({ -2.0, 2.0 }) do
		b("Eye" .. i, V3(1.3, 1.3, 1.3), V3(sx, 3.5, -6.2), C.charcoal, SMOOTH, BALLSOFT)
		b("Cheek" .. i, V3(1.5, 1.5, 1.5), V3(sx * 1.8, 2.7, -5.4), C.sakura, SMOOTH, BALLSOFT)
		b("Mouth" .. i, V3(1.0, 0.24, 0.3), V3(sx * 0.275, 2.6, -6.42), C.charcoal, SMOOTH, SOFT,
			CFrame.Angles(0, 0, math.rad(sx > 0 and -22 or 22)))
	end
end

local function floatieCat(m, cf)
	local b = frame(m, cf, 1)
	-- Ten balls at radius 5.6 with a 5.0 diameter: the arc between centres is 3.5,
	-- so they overlap into a continuous ring while still bulging visibly at each
	-- ball -- which is what an inflatable ring's segments look like. At sixteen
	-- balls it went smooth and started reading as a solid rubber donut.
	for i = 1, 10 do
		local a = math.rad(90 + (i - 1) * 36)
		b("Ring" .. i, V3(5.0, 5.0, 5.0), V3(math.cos(a) * 5.6, 1.1, math.sin(a) * 5.6),
			C.cream, SMOOTH, BALLSOFT)
	end
	for i, sx in ipairs({ -2.5, 2.5 }) do
		-- A box turned 45 degrees, half-buried in the ring: the half that shows is a
		-- triangle. Cheaper and more reliable than a WedgePart, whose slope faces a
		-- direction you have to look up every single time.
		b("Ear" .. i, V3(2.6, 2.6, 0.9), V3(sx, 4.4, -5.0), C.cream, SMOOTH, SOFT,
			CFrame.Angles(0, 0, math.rad(45)))
		b("EarInner" .. i, V3(1.5, 1.5, 0.5), V3(sx, 4.7, -5.45), C.sakura, SMOOTH, SOFT,
			CFrame.Angles(0, 0, math.rad(45)))
		b("Eye" .. i, V3(1.15, 1.15, 1.15), V3(sx * 0.54, 2.7, -6.85), C.charcoal, SMOOTH, BALLSOFT)
		b("Whisker" .. i .. "a", V3(2.8, 0.16, 0.16), V3(sx * 0.76, 2.2, -6.9), C.charcoal, SMOOTH, SOFT,
			CFrame.Angles(0, math.rad(sx > 0 and -18 or 18), 0))
		b("Whisker" .. i .. "b", V3(2.8, 0.16, 0.16), V3(sx * 0.8, 1.7, -7.0), C.charcoal, SMOOTH, SOFT,
			CFrame.Angles(0, math.rad(sx > 0 and -4 or 4), 0))
	end
	b("Nose", V3(0.75, 0.75, 0.75), V3(0, 2.05, -7.8), C.sakura, SMOOTH, BALLSOFT)
	local tail = {
		{ 2.2, V3(0.8, 2.4, 6.4) }, { 1.9, V3(2.0, 3.0, 7.4) },
		{ 1.6, V3(3.2, 3.8, 7.8) }, { 1.3, V3(4.0, 4.6, 7.4) },
	}
	for i, t in ipairs(tail) do
		b("Tail" .. i, V3(t[1], t[1], t[1]), t[2], C.cream, SMOOTH, BALLSOFT)
	end
end

function Props.floatie(parent, cf, kind)
	-- Normalised up front rather than in the fallback chain, so an unrecognised
	-- kind takes exactly the same path as "flamingo" -- otherwise a typo in the
	-- caller's scatter table silently swaps a 2-part clone for a 21-part rebuild
	-- of the same bird, and the only symptom is the part budget.
	local k = key(kind, "flamingo")
	if k ~= "boba" and k ~= "cat" then
		k = "flamingo"
	end

	if k == "flamingo" then
		local m = coveAsset("FloatieFlamingo")
		if m then
			m.Name = "Floatie"
			sanitise(m)
			-- Scaled on FOOTPRINT, not height: the flamingo's height is nearly all
			-- neck, so normalising by height gives a 15-stud-tall bird sitting in a
			-- 9-stud ring.
			local sz = centrePivot(m)
			local span = math.max(sz.X, sz.Z)
			if span > 0.05 then
				pcall(function()
					m:ScaleTo(15 / span)
				end)
			end
			local sz2 = centrePivot(m)
			-- sunk 1.2 studs, not sitting on the waterline: a floatie whose hull
			-- exactly touches the surface reads as resting on a sheet of glass.
			m:PivotTo(cf * CFrame.new(0, sz2.Y * 0.5 - 1.2, 0))
			for _, d in ipairs(m:GetDescendants()) do
				if d:IsA("BasePart") then
					d.CanCollide = false
					-- The asset ships its one MeshPart named "Meshes/flMINGOhEAD3 (2)".
					-- Everything else in this island is named for what it is.
					if d:IsA("MeshPart") then
						d.Name = "Hull"
					end
				end
			end
			root(m, cf)
			m.Parent = parent
			return m
		end
	end

	local m = Instance.new("Model")
	m.Name = "Floatie"
	root(m, cf)
	if k == "boba" then
		floatieBoba(m, cf)
	elseif k == "cat" then
		floatieCat(m, cf)
	else
		floatieFlamingoBuilt(m, cf)
	end
	m.Parent = parent
	return m
end

----------------------------------------------------------------
-- ROCK FORMATION  --  11 parts
----------------------------------------------------------------
--[[
	Props.rockFormation(parent, cf, scale) -> Model

	PrimaryPart sits at the formation's BASE, at cf, so the caller seats it with a
	single PivotTo onto a ground raycast.

	CTB_Props.Rock is 2.1 studs across -- a pebble, not a formation -- and scaling
	it eight times gives one lumpy grey mesh eight times. So this is built.

	IT IS BUILT OUT OF ANGULAR CHUNKS, AND IT USED TO BE BUILT OUT OF BALLS.
	Five overlapping spheres is a cauliflower: there is no edge anywhere on it, so
	at every distance it read as a purple blob -- closer to a bath sponge or a pile
	of bubbles than to stone. "Soft and picture-book" was the intent and softness
	is the wrong axis for the one object on this beach whose whole job is to look
	HEAVY. Rock is what gives a pastel shoreline any weight at all, and rock reads
	as rock because it has FLAT FACES MEETING AT EDGES.

	TWO THINGS DO THE WORK, AND THE FIRST ONE ALONE WAS NOT ENOUGH. The first cut
	of this was five Blocks tilted about eight degrees on x and z, and it came out
	as a stack of crates: eight degrees is small enough that the eye still reads
	every face as level or plumb and corrects the rest away. The tilts here are 10
	to 20 degrees on BOTH axes, on top of a yaw, so no two faces in the pile are
	parallel and none of them line up with the ground.

	The second is SHAPE. Two of the five chunks are Wedges and one is a
	CornerWedge, which is what puts sloped faces and a point into a silhouette
	that Blocks alone can only make out of steps. Two cap slabs lie across the top
	at their own angles as well, because what stops a heap of boxes reading as a
	heap of boxes is one plane cutting across the others.

	BLOCKS ALSO DELETE THE CONSTRAINT THE BALL VERSION WAS FIGHTING. A Ball part
	with a non-uniform Size DRAWS as an ellipsoid but COLLIDES as a sphere of its
	SMALLEST axis, so the old spec had to hold all three axes within about 12% of
	each other or a player could walk into the middle of a boulder. A rotated Block
	collides as the box it draws. These are free to be as slabby as real rock is,
	and the sizes below use that.
]]
function Props.rockFormation(parent, cf, scale)
	local s = num(scale, 1, 0.2, 6)
	local m = Instance.new("Model")
	m.Name = "RockFormation"
	local b = frame(m, cf, s)
	root(m, cf)

	local rng = rngFor(cf, 909)
	--[[
		DARKENED, AND IT IS THE DIFFERENCE BETWEEN ROCK AND FOAM.

		This was C.stone lerped a third toward lilac, which comes out about
		(218, 202, 222) -- pale lilac, near enough the same VALUE as the pastel sea
		and the sky behind it. All twenty-four formations rendered as white
		cauliflower clumps that could not be told apart from cloud or sea foam, at
		every distance.

		Rock is the one thing in a pastel palette that is allowed to be dark: it is
		what gives the shoreline any weight at all.

		HOW DARK WAS SETTLED BY A THREE-WAY SWATCH IN ONE FRAME, because the eye is
		no use here and neither is the Color3. This place lights the cove with
		OutdoorAmbient (198,150,156) at Brightness 3.10 under a pink grade, and a
		part renders VASTLY paler than the colour it is given: (154,141,156) still
		photographed as a pale pink dome, and so did (120,106,119). Three
		formations were set to (120,106,119), (95,84,96) and (72,64,74) in the same
		shot; only the last one read as rock.

		The number to keep in step is Rec.709 LUMA AGAINST THE SAND. The messy sand
		tint (206,104,124) is luma 127. The base below is (82,72,86) -> luma 75,
		and the per-boulder lerp toward sakura tops out around luma 95, so every
		boulder at every variation is clearly darker than the sand it sits on.
		Re-run that comparison if this is ever re-tinted; do not trust a swatch.
	]]
	local base = C.charcoal:Lerp(C.lilac, 0.16)

	-- shape, w, h, d, x, y, z, yaw, tiltX, tiltZ. Every y seats the chunk's centre
	-- low enough that its bottom face is a stud or so UNDER the sand before the
	-- tilt is applied -- and the tilt drops one corner half a stud further still,
	-- so no chunk can show the flat underside of a box where it meets the beach.
	local spec = {
		{ nil, 7.6, 5.2, 6.6, 0.0, 1.7, 0.0, 0.35, 0.20, -0.27 },
		{ WEDGE, 6.4, 5.0, 5.8, -2.9, 1.6, 1.4, 1.15, -0.28, 0.30 },
		{ WEDGE, 5.2, 5.8, 4.6, 3.0, 1.8, -1.7, 2.30, 0.28, 0.24 },
		{ nil, 4.4, 3.4, 3.8, 1.5, 1.1, 3.0, 0.70, -0.32, -0.28 },
		{ CORNER, 3.8, 3.6, 3.8, -2.7, 1.0, -2.7, 1.90, 0.20, 0.27 },
	}
	for i, r in ipairs(spec) do
		b("Boulder" .. i,
			V3(r[2] * rng:NextNumber(0.9, 1.1), r[3], r[4] * rng:NextNumber(0.9, 1.1)),
			V3(r[5] + rng:NextNumber(-0.5, 0.5), r[6], r[7] + rng:NextNumber(-0.5, 0.5)),
			base:Lerp(C.sakura, rng:NextNumber(0.04, 0.16)), CONCRETE, r[1],
			CFrame.Angles(r[9] + rng:NextNumber(-0.1, 0.1),
				r[8] + rng:NextNumber(-0.35, 0.35),
				r[10] + rng:NextNumber(-0.1, 0.1)))
	end

	-- The two cap slabs. CanCollide false, both of them: they overhang the chunks
	-- under them on purpose, and a player who can stand on a 1.4-stud lip four
	-- studs up is a player standing on top of the scenery.
	b("Cap1", V3(5.0, 1.2, 4.2), V3(-0.4, 4.2, 0.5), base:Lerp(C.lilac, 0.12), CONCRETE, SOFT,
		CFrame.Angles(rng:NextNumber(-0.42, -0.26), 0.9, rng:NextNumber(0.20, 0.38)))
	b("Cap2", V3(3.2, 0.9, 2.6), V3(1.8, 3.4, -1.4), base:Lerp(C.lilac, 0.05), CONCRETE, SOFT,
		CFrame.Angles(rng:NextNumber(0.18, 0.34), 2.2, rng:NextNumber(-0.36, -0.18)))

	--[[
		One patch of moss and one shell. Five identical balls is a pile; the two
		odd small things are what make it a place.

		BOTH ARE HELD AT A FIXED WORLD SIZE by dividing out the scale, and both are
		knocked down from the raw palette. They are ACCENTS on a rock, and the
		formations run to scale 3.6 out on the headlands -- at that size a full-
		brightness mint disc and a cream ball became a 12-stud lily pad with an egg
		on it, and from any distance the bright cap was the only part of the
		formation you could see. The offsets still scale, so they still land on the
		pile.
	]]
	-- Bedded INTO the cap slab, not balanced on the summit. At 5.45 it cleared the
	-- highest chunk on every formation and read as a green pea sitting on a rock;
	-- it is non-collidable, so letting the slab cut through its lower half is free
	-- and is what makes it look grown rather than placed.
	b("Moss", V3(3.4, 0.9, 3.0) / s, V3(0.4, 4.75, -0.3), C.mint:Lerp(C.charcoal, 0.58), SMOOTH, BALLSOFT)
	b("Shell", V3(1.4, 0.55, 1.4) / s, V3(2.5, 0.28, 2.7), C.cream:Lerp(C.charcoal, 0.28), SMOOTH, BALLSOFT)
	b("ShellDot", V3(0.6, 0.32, 0.6) / s, V3(2.5, 0.45, 2.7), C.coral:Lerp(C.charcoal, 0.2), SMOOTH, BALLSOFT)

	m.Parent = parent
	return m
end

----------------------------------------------------------------
-- BAMBOO CLUMP  --  8 to 12 parts
----------------------------------------------------------------
--[[
	Props.bambooClump(parent, cf, scale) -> Model

	A stand of five to eight culms of different heights with a leaf spray over
	the top of them. `cf` is the GROUND, and the clump grows up from it.

	IT IS HERE FOR HEIGHT, WHICH THIS COVE HAS ALMOST NONE OF. Everything else
	in the kit is either flat on the ground -- kerbs, mats, stepping stones, the
	lanterns' bases -- or a cherry tree, and a cherry tree is a wide soft dome.
	Bamboo is the one thing in this palette that is thin and VERTICAL, so a clump
	of it breaks up a flat middle distance in a way nothing else here can.

	ONE PART PER CULM. The obvious build is a stack of segments with a paler node
	band between each -- and at five to eight culms a clump that is fifty parts
	for a piece of background scatter. The node reads at arm's length and this
	island is looked at from thirty studs, so the culms are single tapered boxes
	and the variation is in their colour instead.

	THEY LEAN OUT FROM THE CENTRE, each by its own amount -- but only barely. The
	first cut leaned them up to 0.14 radians over a sixteen-stud culm, which is
	over two studs of splay at the tip, and a clump of those reads as a broken
	umbrella or a pile of bones rather than as bamboo. Bamboo is the straightest
	thing that grows. 0.02..0.06 is enough to say "not a fence" and no more.

	AND IT IS DARK. `mint` is a pastel TEAL, and mint lerped a third toward
	charcoal comes out about (128,155,145) -- a pale grey-green that, under this
	island's pink grade and low ambient, rendered as bare white sticks. Taken most
	of the way to charcoal it is a deep sage instead, which is the darkest thing
	on the island after the rocks and reads as foliage at any distance.
]]
function Props.bambooClump(parent, cf, scale)
	local s = num(scale, 1, 0.3, 4)
	local m = Instance.new("Model")
	m.Name = "BambooClump"
	local b = frame(m, cf, s)
	root(m, cf)

	local rng = rngFor(cf, 731)
	local n = rng:NextInteger(5, 8)
	local stalk = C.mint:Lerp(C.charcoal, 0.62)
	local tallest = 0

	for i = 1, n do
		local a = (i / n) * math.pi * 2 + rng:NextNumber(-0.5, 0.5)
		local d = rng:NextNumber(0.2, 1.3)
		local h = rng:NextNumber(10, 16)
		local lean = rng:NextNumber(0.02, 0.06)
		local w = rng:NextNumber(0.34, 0.5)
		tallest = math.max(tallest, h)
		-- Every third culm a shade lighter, so the clump has depth without paying
		-- for a node band on every segment.
		local tone = (i % 3 == 0) and stalk:Lerp(C.cream, 0.16) or stalk
		b("Culm", V3(w, h, w),
			V3(math.cos(a) * d, h * 0.5, math.sin(a) * d),
			tone, SMOOTH, SOFT,
			CFrame.Angles(math.sin(a) * lean, rng:NextNumber(0, 6.28), -math.cos(a) * lean))
	end

	--[[
		FOUR BLADES IN A CANOPY AT THE TOP, not sprays hung off each culm.

		They sit in the top fifth of the tallest culm and tilt DOWN, which is the
		way a bamboo leaf hangs. The first cut scattered them from ten studs up to
		fourteen at any roll it liked, so half of them floated in clear air below
		the tips and the rest stuck out sideways like signposts.
	]]
	for k = 1, 4 do
		local la = (k / 4) * math.pi * 2 + rng:NextNumber(-0.4, 0.4)
		b("Leaf", V3(rng:NextNumber(3.2, 4.6), 0.16, rng:NextNumber(0.9, 1.4)),
			V3(math.cos(la) * 1.5, tallest - rng:NextNumber(0.6, 2.6), math.sin(la) * 1.5),
			C.mint:Lerp(C.charcoal, 0.5), SMOOTH, SOFT,
			CFrame.Angles(0, -la, rng:NextNumber(-0.34, -0.12)))
	end

	m.Parent = parent
	return m
end

return Props
