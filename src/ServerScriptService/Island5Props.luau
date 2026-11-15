--[[
	Island5Props  --  the prop kit for PENGUIN ISLAND
	================================================

	A pure builder library, modelled key-for-key on Island4Props (Ashfall).
	It decides NOTHING about where anything goes: Island5Builder owns the map,
	the clearances and the scatter passes, and calls into here for one prop at a
	time. Every builder takes a parent and a CFrame and hands back one Model.

	THE LOCAL FRAME, which every builder below honours:
	  * y = 0 is the GROUND at `cf`. A prop sits on the ground of its own frame;
	    the caller raycasts the terrain and never has to know a prop's height.
	  * x = 0 is the prop's centre.
	  * It faces its own -Z (doors, counters, faces and arrows all point -Z),
	    so a caller aims a prop with CFrame.lookAt and gets what it expects.
	  * Every part is placed as cf * CFrame.new(offset) through lp(), never by
	    PivotTo on the finished model, so a prop is exactly where the caller put
	    it on the very frame it was built.
	Three builders (ropeFence, jetty, stringLights) take two WORLD points instead
	of a frame, because a span between two surveyed points is the natural way to
	ask for a fence or a walkway; they are marked as such.

	THE RULES THAT COST THE OTHER ISLANDS A REBUILD EACH:
	  * Every part is Anchored. P() does it; nothing here can fall.
	  * CanCollide is FALSE by default (decoration) and TRUE only where a player
	    stands or bumps -- the COLLIDE extra marks every such part.
	  * Neon parts stay at Transparency 0. Under Future lighting a translucent
	    Neon part renders near-black; depth is faked with a darker colour.
	  * See-through ice is SmoothPlastic + Reflectance + Transparency, never
	    Glass: Glass hides every transparent thing behind it (the litter, the
	    flakes, the other icicles).
	  * Never Sandstone on a part -- it renders mauve in this place.
	  * PointLight only, Shadows = false, Range <= 32, and ONLY where the
	    builder's `lit` argument says so. Neon carries the look of a lamp; the
	    light is the expensive part and the map builder rations it.
	  * CastShadow is stripped by P() from anything thinner than a stud, anything
	    Neon and anything more than half transparent. Island5Builder's final
	    sweep does the same for anything that slips through.
	  * Nothing may be plain white: on the snowfield a white prop has no
	    silhouette. Every "snow" here is a cool off-white with a shaded twin.
	  * Every builder works with NO mesh kit present. Props.kit() returns nil
	    when ServerStorage.ArcticAssets (or the named child) is absent and every
	    caller draws primitives instead. Nothing here throws for a missing asset.
	  * Where a seed is passed the prop is deterministic: Random.new(seed) and
	    never math.random, so a rebuild puts the same tree in the same pose.

	PART COST is stated above every builder. Nothing here passes 60 parts and
	most are under 30; the map builder multiplies these by the scatter counts,
	so a cheap prop is a real saving.
]]

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Props = {}

----------------------------------------------------------------
-- PALETTE
----------------------------------------------------------------
--[[
	Cold, stylised, and every key a clear step off the snowfield. Island5Builder
	adopts this table key-for-key at require time so a colour tweak here follows
	through to everything on the island. `snow` is deliberately NOT white
	(226/232/240): a white block on near-white terrain vanishes, and `snowShade`
	is the shadow side of the same snow so stacked blocks read as blocks.
]]
Props.PALETTE = {
	snow = Color3.fromRGB(226, 232, 240),
	snowShade = Color3.fromRGB(196, 208, 224),
	ice = Color3.fromRGB(168, 204, 232),
	iceDeep = Color3.fromRGB(78, 122, 168),
	iceGlow = Color3.fromRGB(150, 220, 255),
	timber = Color3.fromRGB(142, 100, 64),
	timberDark = Color3.fromRGB(84, 58, 38),
	rope = Color3.fromRGB(176, 150, 104),
	iron = Color3.fromRGB(62, 64, 70),
	brass = Color3.fromRGB(196, 152, 72),
	red = Color3.fromRGB(176, 44, 40),
	green = Color3.fromRGB(44, 110, 62),
	gold = Color3.fromRGB(222, 176, 60),
	lanternWarm = Color3.fromRGB(255, 196, 120),
	stoneCold = Color3.fromRGB(122, 132, 142),
	stoneDark = Color3.fromRGB(72, 78, 88),
	canvas = Color3.fromRGB(206, 186, 150),
	penguinInk = Color3.fromRGB(30, 32, 40),
	penguinBelly = Color3.fromRGB(236, 230, 214),
	beakOrange = Color3.fromRGB(240, 140, 40),
}
local C = Props.PALETTE

-- Shade helpers: lerp toward black / white by f. Exported so the builder paints
-- its own slabs in the same family.
local function dk(c: Color3, f: number): Color3
	return c:Lerp(Color3.new(0, 0, 0), f)
end
local function lt(c: Color3, f: number): Color3
	return c:Lerp(Color3.new(1, 1, 1), f)
end
Props.dk, Props.lt = dk, lt

----------------------------------------------------------------
-- Constants and small helpers
----------------------------------------------------------------
local V3 = Vector3.new
local SMOOTH = Enum.Material.SmoothPlastic
local NEON = Enum.Material.Neon
local WOOD = Enum.Material.Wood
local SNOW = Enum.Material.Snow
local ICE = Enum.Material.Ice
local METAL = Enum.Material.Metal
local FABRIC = Enum.Material.Fabric
local SLATE = Enum.Material.Slate
local CORRODED = Enum.Material.CorrodedMetal
local CONCRETE = Enum.Material.Concrete
local GRASS = Enum.Material.Grass

-- Roblox cylinders lie along their own X. UP stands one on end (X -> Y) and
-- ALONG_Z lays one along the frame's Z (X -> -Z); a cylinder is symmetric so
-- the sign does not matter. Size is always (length, diameter, diameter).
local UP = CFrame.Angles(0, 0, math.pi * 0.5)
local ALONG_Z = CFrame.Angles(0, math.pi * 0.5, 0)

local CYL = { Shape = Enum.PartType.Cylinder }
local BALL = { Shape = Enum.PartType.Ball }
local COLLIDE = { CanCollide = true }
-- See-through ice: SmoothPlastic with reflectance, never Glass (header).
local ICE_LOOK = { Transparency = 0.42, Reflectance = 0.35 }

local SMOKE_TEX = "rbxasset://textures/particles/smoke_main.dds"

-- Merge any number of "extra" property tables (nil entries skipped) so a part
-- can be a collidable cylinder without a table literal at every call.
local function ext(...)
	local t = {}
	for i = 1, select("#", ...) do
		local src = select(i, ...)
		if src then
			for k, v in pairs(src) do
				t[k] = v
			end
		end
	end
	return t
end

-- The one part factory. Anchored, non-colliding decoration by default, smooth
-- faces, extras applied by key, and the CastShadow rule from the header
-- applied AFTER the extras so a Neon or transparent extra is caught.
local function P(parent, name, size, cf, colour, material, extra)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.Size = size
	p.CFrame = cf
	p.Color = colour or C.stoneCold
	p.Material = material or SMOOTH
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if extra then
		for k, v in pairs(extra) do
			p[k] = v
		end
	end
	if math.min(size.X, size.Y, size.Z) < 1.0 or p.Material == NEON or p.Transparency > 0.5 then
		p.CastShadow = false
	end
	p.Parent = parent
	return p
end

-- A part in some base frame's LOCAL space: base * offset. Every prop is
-- described relative to its own origin so one CFrame moves the whole thing.
local function lp(parent, name, base, size, offset, colour, material, extra)
	return P(parent, name, size, base * offset, colour, material, extra)
end

-- A vertical cylinder in local space: `height` tall, `dia` across, its CENTRE
-- at `offset` (so pass y = height/2 to stand it on the ground).
local function vcyl(parent, name, base, height, dia, offset, colour, material, extra)
	return P(parent, name, V3(height, dia, dia), base * offset * UP, colour, material, ext(CYL, extra))
end

-- A cylinder between two WORLD points (ropes, rods, cords, lines). Returns nil
-- for a degenerate span. Handles the vertical case, where lookAt's default up
-- vector would be parallel to the line.
local function seg(parent, name, p: Vector3, q: Vector3, dia: number, colour, material, extra)
	local d = q - p
	local len = d.Magnitude
	if len < 0.05 then
		return nil
	end
	local mid = (p + q) * 0.5
	local cf
	if math.abs(d.Unit.Y) > 0.99 then
		cf = CFrame.lookAt(mid, q, Vector3.xAxis)
	else
		cf = CFrame.lookAt(mid, q)
	end
	return P(parent, name, V3(len, dia, dia), cf * ALONG_Z, colour, material, ext(CYL, extra))
end

local function model(parent, name): Model
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

-- PointLight, Shadows off ALWAYS (a shadow-casting point light is a whole extra
-- shadow map under Future lighting), range clamped to the header's ceiling.
local function light(part: BasePart, colour: Color3, range: number, brightness: number)
	local l = Instance.new("PointLight")
	l.Color = colour
	l.Range = math.min(range, 32)
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = part
	return l
end
Props.light = light

-- Sign lettering. SignKit is optional here: a missing module or a board the
-- kit dislikes must never take a prop down with it, so both the require and
-- every dress() go through pcall.
local SignKit = nil
do
	local ok, kitOrErr = pcall(function()
		local mods = ReplicatedStorage:WaitForChild("Modules", 5)
		return mods and require(mods:WaitForChild("SignKit", 5))
	end)
	if ok and type(kitOrErr) == "table" then
		SignKit = kitOrErr
	end
end
local function dress(board: BasePart?, text: string, faces)
	if not (board and SignKit and type(SignKit.dress) == "function") then
		return
	end
	pcall(SignKit.dress, board, text, faces)
end

----------------------------------------------------------------
-- THE MESH KIT (optional)
----------------------------------------------------------------
--[[
	Resolved once, never assumed. Props.kit clones a MeshPart of that name out of
	ServerStorage.ArcticAssets, scaled so its TALLEST axis equals `height`,
	anchored and recoloured -- and returns nil if the folder or the child is
	missing. Every builder in this file is written primitives-first; the kit is
	a garnish the map can grow into, not a dependency.
]]
local assets = ServerStorage:FindFirstChild("ArcticAssets")

function Props.kit(parent, name: string, height: number, colour: Color3?, material: Enum.Material?): BasePart?
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

-- Sit a kit mesh on the ground of a local frame: a MeshPart's CFrame is its
-- bounding-box centre, so "on the ground" is half its height up, less a sink.
local function seat(p: BasePart, base: CFrame, offset: CFrame, sink: number?)
	p.CFrame = base * offset * CFrame.new(0, p.Size.Y * 0.5 - (sink or 0), 0)
	return p
end
Props.seat = seat

----------------------------------------------------------------
-- SUPPLY CRATE  --  PART COST 8
----------------------------------------------------------------
--[[
	A timber crate with corner battens, a lid plank, a red stencil stripe on its
	-Z face and a cap of snow. The body collides (players hop on crates); the
	rest is dressing. Defined early because researchStation borrows it.
]]
function Props.supplyCrate(parent, cf: CFrame, scale: number?): Model
	local s = scale or 1
	local m = model(parent, "SupplyCrate")
	lp(m, "Body", cf, V3(3.2 * s, 2.6 * s, 3.2 * s), CFrame.new(0, 1.3 * s, 0), C.timber, WOOD, COLLIDE)
	lp(m, "Lid", cf, V3(3.3 * s, 0.25 * s, 3.3 * s), CFrame.new(0, 2.72 * s, 0), dk(C.timber, 0.15), WOOD)
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			lp(m, "Batten", cf, V3(0.3 * s, 2.7 * s, 0.3 * s),
				CFrame.new(sx * 1.55 * s, 1.35 * s, sz * 1.55 * s), C.timberDark, WOOD)
		end
	end
	-- the stencil stripe sits proud of the front face so it is not z-fought
	lp(m, "Stripe", cf, V3(2.0 * s, 0.6 * s, 0.08 * s), CFrame.new(0, 1.5 * s, -1.65 * s), C.red, SMOOTH)
	lp(m, "SnowCap", cf, V3(3.0 * s, 0.7 * s, 3.0 * s), CFrame.new(0.1 * s, 2.98 * s, -0.1 * s), C.snow, SNOW, BALL)
	return m
end

----------------------------------------------------------------
-- FUEL BARREL  --  PART COST 5
----------------------------------------------------------------
--[[
	A red drum with a rust band round its middle, iron rims and a lump of snow
	on the lid. The drum collides.
]]
function Props.fuelBarrel(parent, cf: CFrame): Model
	local m = model(parent, "FuelBarrel")
	vcyl(m, "Drum", cf, 3.4, 2.2, CFrame.new(0, 1.7, 0), C.red, METAL, COLLIDE)
	vcyl(m, "RustBand", cf, 0.5, 2.28, CFrame.new(0, 1.7, 0), Color3.fromRGB(150, 84, 40), CORRODED)
	vcyl(m, "RimBottom", cf, 0.18, 2.3, CFrame.new(0, 0.09, 0), C.iron, METAL)
	vcyl(m, "RimTop", cf, 0.18, 2.3, CFrame.new(0, 3.31, 0), C.iron, METAL)
	lp(m, "SnowCap", cf, V3(2.0, 0.6, 2.0), CFrame.new(0.1, 3.5, 0), C.snow, SNOW, BALL)
	return m
end

----------------------------------------------------------------
-- FLAG POLE  --  PART COST 4
----------------------------------------------------------------
--[[
	An iron pole on a stone foot, a flag in the caller's colour flying off +X,
	and a brass knob. The flag is a plain slab -- at scatter distance a slab
	reads as a flag and a cloth sim would cost more than the whole camp.
]]
function Props.flagPole(parent, cf: CFrame, colour: Color3?): Model
	local m = model(parent, "FlagPole")
	vcyl(m, "Foot", cf, 0.4, 1.2, CFrame.new(0, 0.2, 0), C.stoneCold, SLATE)
	vcyl(m, "Pole", cf, 9, 0.28, CFrame.new(0, 4.5, 0), C.iron, METAL)
	lp(m, "Flag", cf, V3(3.0, 1.8, 0.12), CFrame.new(1.6, 7.9, 0), colour or C.red, FABRIC)
	lp(m, "Knob", cf, V3(0.5, 0.5, 0.5), CFrame.new(0, 9.2, 0), C.brass, METAL, BALL)
	return m
end

----------------------------------------------------------------
-- IGLOO  --  PART COST 34
----------------------------------------------------------------
--[[
	Five rings of snow blocks climbing a dome of radius 5 * scale, a cap block,
	a short entrance tunnel facing -Z and a warm Neon block just inside the
	doorway (NO light -- the glow is the whole point and it costs nothing).

	Ring block counts fall 9/8/7/5/3 so the blocks stay roughly the same size
	as the ring radius shrinks; odd rings are offset half a block so the joints
	stagger like real snow blocks. Rings alternate snow / snowShade because two
	shades of near-white are what makes the dome read as BLOCKS on a white
	field instead of one blob. The blocks in rings 1-2 that face -Z are left
	out for the doorway (one block in ring 1, two in the offset ring 2).
]]
function Props.igloo(parent, cf: CFrame, scale: number?): Model
	local s = scale or 1
	local m = model(parent, "Igloo")
	local R = 5.0 * s
	local RINGS = { 9, 8, 7, 5, 3 }
	local T = 1.32                      -- radians of dome the rings climb (of pi/2)
	local depth = 1.3 * s
	for i, n in ipairs(RINGS) do
		local phi0 = (i - 1) / #RINGS * T
		local phi1 = i / #RINGS * T
		local mid = (phi0 + phi1) * 0.5
		local ringR = R * math.cos(mid)
		local y = R * math.sin(mid)
		local h = R * (phi1 - phi0) * 1.06
		local w = (2 * math.pi * ringR / n) * 0.94
		local tone = (i % 2 == 0) and C.snowShade or C.snow
		for k = 0, n - 1 do
			local a = (k + (i % 2 == 0 and 0.5 or 0)) * (2 * math.pi / n)
			local facing = math.abs(math.atan2(math.sin(a), math.cos(a)))
			if not (i <= 2 and facing < (math.pi / n) + 0.01) then
				local x, z = ringR * math.sin(a), -ringR * math.cos(a)
				-- yaw -a puts the block's X along the ring's tangent; the small
				-- pitch leans its top inward with the dome
				lp(m, "Block", cf, V3(w, h, depth),
					CFrame.new(x, y, z) * CFrame.Angles(0, -a, 0) * CFrame.Angles(mid * 0.5, 0, 0),
					tone, SNOW, COLLIDE)
			end
		end
	end
	lp(m, "Cap", cf, V3(1.0 * R, 0.36 * R, 1.0 * R), CFrame.new(0, 0.86 * R, 0), C.snow, SNOW, ext(BALL, COLLIDE))

	-- the entrance tunnel, hanging off the dome's -Z face
	local L = 3.2 * s
	local zc = -R * 0.92 - L * 0.5
	lp(m, "TunnelWall", cf, V3(0.7 * s, 2.4 * s, L), CFrame.new(-1.75 * s, 1.2 * s, zc), C.snowShade, SNOW, COLLIDE)
	lp(m, "TunnelWall", cf, V3(0.7 * s, 2.4 * s, L), CFrame.new(1.75 * s, 1.2 * s, zc), C.snowShade, SNOW, COLLIDE)
	lp(m, "TunnelRoof", cf, V3(4.2 * s, 0.7 * s, L), CFrame.new(0, 2.75 * s, zc), C.snow, SNOW, COLLIDE)

	-- the hearth glow: Neon at Transparency 0, no light (header)
	lp(m, "Glow", cf, V3(1.6 * s, 0.7 * s, 0.5 * s), CFrame.new(0, 0.35 * s, -(R - 1.2 * s)), C.lanternWarm, NEON)
	return m
end

----------------------------------------------------------------
-- SNOW CABIN  --  PART COST 46 (+1 emitter, +1 light if lit)
----------------------------------------------------------------
--[[
	A log cabin: seven courses of four logs (cylinders, the front/back pair
	overhanging the corners a log's width so the ends show), gable fills, two
	pitched roof slabs under thick snow caps and a snow ridge, a door on -Z
	flanked by two warm Neon windows, a stone chimney with a slow grey smoke
	emitter on its top ring. The PointLight (Range 26, Brightness 1.2, warm)
	sits behind the left window and only when `lit` -- a village of cabins
	should have a few lit windows, not a light per house.
]]
function Props.snowCabin(parent, cf: CFrame, scale: number?, lit: boolean?): Model
	local s = scale or 1
	local m = model(parent, "SnowCabin")
	local W, D, d = 12 * s, 10 * s, 1.0 * s
	local COURSES = 7
	local wallH = COURSES * d

	for i = 1, COURSES do
		local y = (i - 0.5) * d
		local tone = (i % 2 == 0) and C.timber or dk(C.timber, 0.12)
		lp(m, "Log", cf, V3(W + 2 * d, d, d), CFrame.new(0, y, -D * 0.5), tone, WOOD, ext(CYL, COLLIDE))
		lp(m, "Log", cf, V3(W + 2 * d, d, d), CFrame.new(0, y, D * 0.5), tone, WOOD, ext(CYL, COLLIDE))
		lp(m, "Log", cf, V3(D + 2 * d, d, d), CFrame.new(-W * 0.5, y, 0) * ALONG_Z, tone, WOOD, ext(CYL, COLLIDE))
		lp(m, "Log", cf, V3(D + 2 * d, d, d), CFrame.new(W * 0.5, y, 0) * ALONG_Z, tone, WOOD, ext(CYL, COLLIDE))
	end

	-- gable fills: two stepped blocks per end stand in for a triangle
	local rise = 3.4 * s
	for _, sx in ipairs({ -1, 1 }) do
		lp(m, "Gable", cf, V3(d, 1.8 * s, D * 0.7), CFrame.new(sx * W * 0.5, wallH + 0.9 * s, 0), C.timberDark, WOOD, COLLIDE)
		lp(m, "Gable", cf, V3(d, 1.6 * s, D * 0.36), CFrame.new(sx * W * 0.5, wallH + 2.5 * s, 0), C.timberDark, WOOD, COLLIDE)
	end

	-- roof: two slabs pitched about the X ridge, each under a thicker snow cap
	local hs = D * 0.5 + 1.2 * s
	local slant = math.sqrt(hs * hs + rise * rise)
	local ang = math.atan(rise / hs)
	for _, k in ipairs({ -1, 1 }) do
		local frame = CFrame.new(0, wallH + rise * 0.5, k * hs * 0.5) * CFrame.Angles(k * ang, 0, 0)
		lp(m, "Roof", cf, V3(W + 2.6 * s, 0.5 * s, slant + 0.4 * s), frame, C.timberDark, WOOD, COLLIDE)
		lp(m, "RoofSnow", cf, V3(W + 2.2 * s, 0.9 * s, slant - 0.2 * s), frame * CFrame.new(0, 0.7 * s, 0), C.snow, SNOW, COLLIDE)
	end
	lp(m, "Ridge", cf, V3(W + 2.8 * s, 0.9 * s, 0.9 * s), CFrame.new(0, wallH + rise + 0.3 * s, 0), C.snowShade, SNOW, CYL)

	-- door and step on -Z
	local face = -(D * 0.5 + d * 0.5)
	lp(m, "Door", cf, V3(3.0 * s, 5.4 * s, 0.35 * s), CFrame.new(0, 2.7 * s, face - 0.1 * s), C.timberDark, WOOD)
	lp(m, "Step", cf, V3(4 * s, 0.5 * s, 2 * s), CFrame.new(0, 0.25 * s, face - 1.3 * s), C.stoneCold, SLATE, COLLIDE)

	-- two windows: a dark frame with a warm pane proud of it
	local firstPane = nil
	for _, sx in ipairs({ -1, 1 }) do
		lp(m, "Frame", cf, V3(2.8 * s, 2.6 * s, 0.3 * s), CFrame.new(sx * W * 0.3, 4.3 * s, face - 0.05 * s), C.timberDark, WOOD)
		local pane = lp(m, "Pane", cf, V3(2.2 * s, 2.0 * s, 0.2 * s), CFrame.new(sx * W * 0.3, 4.3 * s, face - 0.22 * s), C.lanternWarm, NEON)
		firstPane = firstPane or pane
	end

	-- chimney: a stack through the roof and a short ring on top that carries the smoke
	local cx, cz = W * 0.28, D * 0.22
	local top = wallH + rise + 1.6 * s
	local stackH = top - (wallH - 1.0 * s)
	lp(m, "ChimneyStack", cf, V3(1.7 * s, stackH, 1.7 * s), CFrame.new(cx, top - stackH * 0.5, cz), C.stoneCold, SLATE)
	local chimney = lp(m, "Chimney", cf, V3(1.9 * s, 0.6 * s, 1.9 * s), CFrame.new(cx, top + 0.3 * s, cz), C.stoneDark, SLATE)
	lp(m, "ChimneySnow", cf, V3(2.1 * s, 0.4 * s, 2.1 * s), CFrame.new(cx, top + 0.8 * s, cz), C.snow, SNOW)

	local smoke = Instance.new("ParticleEmitter")
	smoke.Texture = SMOKE_TEX
	smoke.Rate = 4
	smoke.Lifetime = NumberRange.new(3, 5)
	smoke.Speed = NumberRange.new(1.5, 2.5)
	smoke.Acceleration = Vector3.new(0.4, 1.2, 0)
	smoke.Color = ColorSequence.new(Color3.fromRGB(150, 150, 156), Color3.fromRGB(110, 112, 118))
	smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 3.4) })
	smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) })
	smoke.EmissionDirection = Enum.NormalId.Top
	smoke.LightEmission = 0
	smoke.Rotation = NumberRange.new(-180, 180)
	smoke.RotSpeed = NumberRange.new(-20, 20)
	smoke.Parent = chimney

	if lit and firstPane then
		light(firstPane, C.lanternWarm, 26, 1.2)
	end
	return m
end

----------------------------------------------------------------
-- SNOW PINE  --  PART COST 9-11
----------------------------------------------------------------
--[[
	A stylised conifer: a trunk and four or five stacked, tapering tiers, each
	a block turned a quarter-turn off its neighbour so the silhouette is a star
	from above and a stepped triangle from the side, with a snow slab on every
	tier. Tiers alternate green / dark green so they separate at distance.
	Only the trunk collides -- a player walks through the boughs, which on a
	forest of these is the difference between a stroll and a maze.
]]
function Props.snowPine(parent, cf: CFrame, height: number?, seed: number?): Model
	local rng = Random.new(seed or 1)
	local h = height or 14
	local m = model(parent, "SnowPine")
	local tiers = (h >= 16) and 5 or 4
	local trunkH = h * 0.28
	local trunkD = math.max(0.6, h * 0.06)
	vcyl(m, "Trunk", cf, trunkH + 2, trunkD, CFrame.new(0, (trunkH + 2) * 0.5 - 0.5, 0), C.timberDark, WOOD, COLLIDE)

	local span = h - trunkH
	local step = span / tiers
	local w0 = h * 0.42
	for i = 1, tiers do
		local th = step * 1.15
		local yc = trunkH + (i - 1) * step + th * 0.5 - 0.4
		local w = w0 * (1 - (i - 1) / tiers * 0.72)
		local yaw = (i % 2) * math.pi * 0.25 + rng:NextNumber(-0.15, 0.15)
		local tone = (i % 2 == 1) and C.green or dk(C.green, 0.3)
		lp(m, "Tier", cf, V3(w, th, w), CFrame.new(0, yc, 0) * CFrame.Angles(0, yaw, 0), tone, GRASS)
		lp(m, "TierSnow", cf, V3(w * 0.78, 0.35, w * 0.78),
			CFrame.new(0, yc + th * 0.5 + 0.12, 0) * CFrame.Angles(0, yaw, 0), C.snow, SNOW)
	end
	return m
end

----------------------------------------------------------------
-- DEAD PINE  --  PART COST 9-13
----------------------------------------------------------------
--[[
	A bare trunk with four to six branches reaching up and out at seeded yaws,
	each dusted with a thin snow slab along its top. Branches thin and shorten
	toward the crown.
]]
function Props.deadPine(parent, cf: CFrame, height: number?, seed: number?): Model
	local rng = Random.new(seed or 2)
	local h = height or 12
	local m = model(parent, "DeadPine")
	vcyl(m, "Trunk", cf, h + 0.5, math.max(0.5, h * 0.05), CFrame.new(0, h * 0.5 - 0.25, 0), C.timberDark, WOOD, COLLIDE)
	local n = rng:NextInteger(4, 6)
	for i = 1, n do
		local y = h * (0.35 + 0.55 * (i - 1) / (n - 1))
		local yaw = rng:NextNumber(0, math.pi * 2)
		local pitch = rng:NextNumber(0.25, 0.55)
		local L = rng:NextNumber(0.22, 0.34) * h * (1 - 0.4 * (i - 1) / n)
		local dia = 0.28
		local frame = CFrame.new(0, y, 0) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(0, 0, pitch) * CFrame.new(L * 0.5, 0, 0)
		lp(m, "Branch", cf, V3(L, dia, dia), frame, C.timberDark, WOOD, CYL)
		lp(m, "BranchSnow", cf, V3(L * 0.55, 0.14, dia * 1.3), frame * CFrame.new(0, dia * 0.5 + 0.07, 0), C.snow, SNOW)
	end
	return m
end

----------------------------------------------------------------
-- SNOWMAN  --  PART COST 15
----------------------------------------------------------------
--[[
	Three balls, coal eyes and buttons, a carrot nose along -Z, stick arms,
	a red scarf (a flat ring at the neck plus a tail) and a top hat. The balls
	are snow but the bottom one is the shaded snow so it separates from the
	ground it stands on.
]]
function Props.snowman(parent, cf: CFrame, scale: number?): Model
	local s = scale or 1
	local m = model(parent, "Snowman")
	lp(m, "Base", cf, V3(3.2 * s, 3.2 * s, 3.2 * s), CFrame.new(0, 1.4 * s, 0), C.snowShade, SNOW, ext(BALL, COLLIDE))
	lp(m, "Middle", cf, V3(2.4 * s, 2.4 * s, 2.4 * s), CFrame.new(0, 3.9 * s, 0), C.snow, SNOW, ext(BALL, COLLIDE))
	lp(m, "Head", cf, V3(1.8 * s, 1.8 * s, 1.8 * s), CFrame.new(0, 5.7 * s, 0), C.snow, SNOW, BALL)
	for _, sx in ipairs({ -1, 1 }) do
		lp(m, "Eye", cf, V3(0.28 * s, 0.28 * s, 0.28 * s), CFrame.new(sx * 0.32 * s, 5.95 * s, -0.82 * s), C.penguinInk, SMOOTH, BALL)
	end
	for k, dy in ipairs({ 0.6, 0, -0.6 }) do
		local zf = (k == 2) and -1.12 or -1.0
		lp(m, "Button", cf, V3(0.3 * s, 0.3 * s, 0.3 * s), CFrame.new(0, (3.9 + dy) * s, zf * s), C.penguinInk, SMOOTH, BALL)
	end
	lp(m, "Nose", cf, V3(0.95 * s, 0.28 * s, 0.28 * s), CFrame.new(0, 5.6 * s, -1.3 * s) * ALONG_Z, C.beakOrange, SMOOTH, CYL)
	for _, sx in ipairs({ -1, 1 }) do
		lp(m, "Arm", cf, V3(2.2 * s, 0.18 * s, 0.18 * s),
			CFrame.new(sx * 1.0 * s, 4.1 * s, 0) * CFrame.Angles(0, 0, sx * 0.55) * CFrame.new(sx * 1.1 * s, 0, 0),
			C.timberDark, WOOD, CYL)
	end
	vcyl(m, "Scarf", cf, 0.5 * s, 2.0 * s, CFrame.new(0, 4.85 * s, 0), C.red, FABRIC)
	lp(m, "ScarfTail", cf, V3(0.7 * s, 1.6 * s, 0.25 * s), CFrame.new(0.5 * s, 4.2 * s, -1.15 * s), C.red, FABRIC)
	vcyl(m, "HatBrim", cf, 0.2 * s, 2.3 * s, CFrame.new(0, 6.55 * s, 0), C.penguinInk, FABRIC)
	vcyl(m, "HatCrown", cf, 1.4 * s, 1.6 * s, CFrame.new(0, 7.3 * s, 0), C.penguinInk, FABRIC)
	return m
end

----------------------------------------------------------------
-- LAMP POST  --  PART COST 9 (+1 light if lit)
----------------------------------------------------------------
--[[
	An iron post with a four-paned lantern head (warm Neon panes proud of each
	face of an iron box), an iron cap and a snow cap. The PointLight (Range 30,
	Brightness 1.4, lanternWarm) goes inside the head only when `lit`; the
	map builder lights every other post along a street and the Neon panes carry
	the rest.
]]
function Props.lampPost(parent, cf: CFrame, height: number?, lit: boolean?): Model
	local h = height or 12
	local m = model(parent, "LampPost")
	vcyl(m, "Foot", cf, 0.5, 1.6, CFrame.new(0, 0.25, 0), C.iron, METAL, COLLIDE)
	vcyl(m, "Post", cf, h - 2.2, 0.45, CFrame.new(0, (h - 2.2) * 0.5 + 0.5, 0), C.iron, METAL, COLLIDE)
	local head = lp(m, "Head", cf, V3(1.5, 1.7, 1.5), CFrame.new(0, h - 0.85, 0), C.iron, METAL)
	for _, k in ipairs({ -1, 1 }) do
		lp(m, "Pane", cf, V3(1.2, 1.3, 0.16), CFrame.new(0, h - 0.85, k * 0.76), C.lanternWarm, NEON)
		lp(m, "Pane", cf, V3(0.16, 1.3, 1.2), CFrame.new(k * 0.76, h - 0.85, 0), C.lanternWarm, NEON)
	end
	lp(m, "Cap", cf, V3(1.9, 0.3, 1.9), CFrame.new(0, h + 0.15, 0), C.iron, METAL)
	lp(m, "SnowCap", cf, V3(1.7, 0.45, 1.7), CFrame.new(0, h + 0.52, 0), C.snow, SNOW)
	if lit then
		light(head, C.lanternWarm, 30, 1.4)
	end
	return m
end

----------------------------------------------------------------
-- ROPE FENCE  --  WORLD POINTS; PART COST 2 per post + 4 per gap
----------------------------------------------------------------
--[[
	Posts every ~6 studs from a to b (timber, snow-capped) and two rope spans
	between each pair, each span built as two segments meeting at a sagging
	midpoint -- a straight rope between posts reads as a rail, a sagged one as
	rope. Posts collide, ropes do not (a player steps over a fence, never gets
	snagged on one). a and b are WORLD points on the ground; any length.
]]
function Props.ropeFence(parent, a: Vector3, b: Vector3): Model
	local m = model(parent, "RopeFence")
	local d = b - a
	local len = d.Magnitude
	if len < 0.5 then
		return m
	end
	local n = math.max(2, math.floor(len / 6 + 0.5) + 1)
	local pts = {}
	for i = 0, n - 1 do
		local p = a + d * (i / (n - 1))
		pts[i + 1] = p
		P(m, "Post", V3(3.2, 0.5, 0.5), CFrame.new(p + V3(0, 1.3, 0)) * UP, C.timber, WOOD, ext(CYL, COLLIDE))
		P(m, "PostSnow", V3(0.75, 0.35, 0.75), CFrame.new(p + V3(0, 2.95, 0)), C.snow, SNOW, BALL)
	end
	for i = 1, n - 1 do
		local p, q = pts[i], pts[i + 1]
		local mid = (p + q) * 0.5 - V3(0, 0.35, 0)
		for _, h in ipairs({ 2.6, 1.6 }) do
			local lift = V3(0, h, 0)
			seg(m, "Rope", p + lift, mid + lift, 0.16, C.rope, FABRIC)
			seg(m, "Rope", mid + lift, q + lift, 0.16, C.rope, FABRIC)
		end
	end
	return m
end

----------------------------------------------------------------
-- SLED  --  PART COST 18
----------------------------------------------------------------
--[[
	A wooden dog sled facing -Z: two runners with upturned toes, two side rails
	on rear stanchions, five slats, a raked handle (two uprights and a bar) and
	a coiled rope on the front deck. All decoration.
]]
function Props.sled(parent, cf: CFrame): Model
	local m = model(parent, "Sled")
	for _, sx in ipairs({ -1, 1 }) do
		lp(m, "Runner", cf, V3(7, 0.35, 0.35), CFrame.new(sx * 1.2, 0.3, 0.3) * ALONG_Z, C.timberDark, WOOD, CYL)
		-- the toe: a short segment turned up at the front
		lp(m, "RunnerToe", cf, V3(1.9, 0.35, 0.35),
			CFrame.new(sx * 1.2, 0.3, -3.4) * CFrame.Angles(0.7, 0, 0) * CFrame.new(0, 0, -0.9) * ALONG_Z,
			C.timberDark, WOOD, CYL)
		lp(m, "Rail", cf, V3(6.6, 0.3, 0.3), CFrame.new(sx * 1.2, 0.8, 0) * ALONG_Z, C.timber, WOOD, CYL)
		vcyl(m, "Stanchion", cf, 0.6, 0.25, CFrame.new(sx * 1.2, 0.55, 2.3), C.timberDark, WOOD)
		vcyl(m, "HandleUpright", cf, 2.3, 0.28, CFrame.new(sx * 1.2, 2.1, 3.1) * CFrame.Angles(-0.25, 0, 0), C.timber, WOOD)
	end
	for i = 0, 4 do
		lp(m, "Slat", cf, V3(3.0, 0.2, 0.8), CFrame.new(0, 0.98, -2.4 + i * 1.2), (i % 2 == 0) and C.timber or dk(C.timber, 0.12), WOOD)
	end
	lp(m, "HandleBar", cf, V3(2.75, 0.28, 0.28), CFrame.new(0, 3.2, 3.38), C.timber, WOOD, CYL)
	vcyl(m, "RopeCoil", cf, 0.35, 1.4, CFrame.new(0, 1.26, -1.6), C.rope, FABRIC)
	vcyl(m, "RopeCoilEye", cf, 0.36, 0.6, CFrame.new(0, 1.27, -1.6), dk(C.rope, 0.45), FABRIC)
	return m
end

----------------------------------------------------------------
-- FISHING HOLE  --  PART COST 15
----------------------------------------------------------------
--[[
	A dark disc set flush in the ice (the hole, non-colliding so a player is
	not tripped by a disc), a ring of chipped ice chunks, a rod resting in a
	forked stick and angled out over the hole with a line dropped in, and a
	bucket. The caller places cf on the frozen sea or a floe top.
]]
function Props.fishingHole(parent, cf: CFrame): Model
	local m = model(parent, "FishingHole")
	vcyl(m, "Hole", cf, 0.2, 4.2, CFrame.new(0, -0.02, 0), Color3.fromRGB(14, 26, 44), SMOOTH)
	for k = 0, 7 do
		local a = k * math.pi * 0.25 + 0.2
		local r = 2.6 + (k % 2) * 0.3
		lp(m, "IceChunk", cf, V3(1.1 + (k % 3) * 0.2, 0.5, 0.8),
			CFrame.new(r * math.sin(a), 0.25, -r * math.cos(a)) * CFrame.Angles(0, a + 0.4, 0), C.ice, ICE)
	end
	-- the forked stick and its tine
	lp(m, "Stick", cf, V3(1.9, 0.2, 0.2), CFrame.new(2.6, 0.9, 2.6) * CFrame.Angles(0, 0, math.pi * 0.5 - 0.15), C.timberDark, WOOD, CYL)
	lp(m, "Tine", cf, V3(0.7, 0.14, 0.14), CFrame.new(2.5, 1.85, 2.5) * CFrame.Angles(0, 0.6, 0.9), C.timberDark, WOOD, CYL)
	-- the rod, in world space so the line can drop straight down from its tip
	local butt = cf:PointToWorldSpace(V3(2.9, 0.6, 2.9))
	local tip = cf:PointToWorldSpace(V3(-0.4, 2.6, -0.3))
	seg(m, "Rod", butt, tip, 0.14, C.timber, WOOD)
	seg(m, "Line", tip, cf:PointToWorldSpace(V3(-0.4, 0.1, -0.3)), 0.05, Color3.fromRGB(200, 206, 216), SMOOTH)
	vcyl(m, "Bucket", cf, 1.2, 1.1, CFrame.new(-2.4, 0.6, 2.0), C.iron, METAL)
	vcyl(m, "BucketRim", cf, 0.15, 1.2, CFrame.new(-2.4, 1.2, 2.0), lt(C.iron, 0.25), METAL)
	return m
end

----------------------------------------------------------------
-- ICE SCULPTURE  --  PART COST 10-12
----------------------------------------------------------------
--[[
	A translucent figure on a plinth of crossed snow blocks. `seed` picks the
	silhouette: 1 penguin, 2 fish, 3 star. The figure is SmoothPlastic at
	Transparency 0.42 / Reflectance 0.35 in iceGlow -- see the header for why
	it is not Glass. Only the plinth collides.
]]
function Props.iceSculpture(parent, cf: CFrame, seed: number?): Model
	local rng = Random.new(seed or 3)
	local m = model(parent, "IceSculpture")
	for _, sx in ipairs({ -1, 1 }) do
		lp(m, "Plinth", cf, V3(1.7, 1.0, 3.2), CFrame.new(sx * 0.87, 0.5, 0), C.snowShade, SNOW, COLLIDE)
		lp(m, "Plinth", cf, V3(3.4, 1.0, 1.55), CFrame.new(0, 1.5, sx * 0.8), C.snow, SNOW, COLLIDE)
	end
	lp(m, "PlinthCap", cf, V3(3.6, 0.3, 3.6), CFrame.new(0, 2.15, 0), C.snowShade, SNOW, COLLIDE)

	local B = 2.3                        -- the figure's ground
	local pick = rng:NextInteger(1, 3)
	if pick == 1 then
		lp(m, "Body", cf, V3(2.0, 2.8, 1.8), CFrame.new(0, B + 1.4, 0), C.iceGlow, SMOOTH, ext(BALL, ICE_LOOK))
		lp(m, "Head", cf, V3(1.3, 1.3, 1.3), CFrame.new(0, B + 3.2, 0), C.iceGlow, SMOOTH, ext(BALL, ICE_LOOK))
		for _, sx in ipairs({ -1, 1 }) do
			lp(m, "Wing", cf, V3(0.35, 1.7, 0.9), CFrame.new(sx * 1.05, B + 1.6, 0) * CFrame.Angles(0, 0, sx * 0.3), C.iceGlow, SMOOTH, ICE_LOOK)
			lp(m, "Foot", cf, V3(0.7, 0.25, 1.0), CFrame.new(sx * 0.45, B + 0.12, -0.3), C.iceGlow, SMOOTH, ICE_LOOK)
		end
		lp(m, "Beak", cf, V3(0.3, 0.25, 0.6), CFrame.new(0, B + 3.15, -0.85), C.iceGlow, SMOOTH, ICE_LOOK)
	elseif pick == 2 then
		vcyl(m, "Stem", cf, 1.6, 0.5, CFrame.new(0, B + 0.8, 0), C.iceGlow, SMOOTH, ICE_LOOK)
		lp(m, "Body", cf, V3(1.4, 1.5, 3.2), CFrame.new(0, B + 1.6, 0), C.iceGlow, SMOOTH, ext(BALL, ICE_LOOK))
		for _, k in ipairs({ -1, 1 }) do
			lp(m, "Tail", cf, V3(0.25, 1.2, 1.1), CFrame.new(0, B + 1.6 + k * 0.4, 1.9) * CFrame.Angles(k * 0.6, 0, 0), C.iceGlow, SMOOTH, ICE_LOOK)
		end
		lp(m, "Fin", cf, V3(0.25, 0.8, 1.2), CFrame.new(0, B + 2.55, -0.2), C.iceGlow, SMOOTH, ICE_LOOK)
	else
		vcyl(m, "Stem", cf, 0.9, 0.5, CFrame.new(0, B + 0.45, 0), C.iceGlow, SMOOTH, ICE_LOOK)
		lp(m, "Core", cf, V3(1.2, 1.2, 1.0), CFrame.new(0, B + 1.9, 0), C.iceGlow, SMOOTH, ext(BALL, ICE_LOOK))
		for k = 0, 4 do
			local a = k * math.pi * 2 / 5
			lp(m, "Arm", cf, V3(0.7, 2.2, 0.5),
				CFrame.new(0, B + 1.9, 0) * CFrame.Angles(0, 0, a) * CFrame.new(0, 1.0, 0), C.iceGlow, SMOOTH, ICE_LOOK)
		end
	end
	return m
end

----------------------------------------------------------------
-- ICE FLOE  --  PART COST 5-8
----------------------------------------------------------------
--[[
	A flat jagged floe: four to six overlapping slabs of Ice, 1.2 thick, at
	seeded yaws and offsets, with their top at local y 0.6 (so the caller puts
	cf at the water line and the floe rides 0.6 proud of it), plus one or two
	snow lumps on top. Slabs collide -- a player crosses a floe -- but
	CanQuery = false so the field's floor raycasts pass straight through them
	to the terrain.
]]
function Props.iceFloe(parent, cf: CFrame, radius: number?, seed: number?): Model
	local rng = Random.new(seed or 4)
	local r = radius or 8
	local m = model(parent, "IceFloe")
	local n = rng:NextInteger(4, 6)
	for _ = 1, n do
		local yaw = rng:NextNumber(0, math.pi)
		local sx = r * rng:NextNumber(1.2, 2.0)
		local sz = r * rng:NextNumber(0.9, 1.6)
		local ox = rng:NextNumber(-0.25, 0.25) * r
		local oz = rng:NextNumber(-0.25, 0.25) * r
		lp(m, "Slab", cf, V3(sx, 1.2, sz), CFrame.new(ox, 0, oz) * CFrame.Angles(0, yaw, 0),
			C.ice, ICE, { CanCollide = true, CanQuery = false })
	end
	for _ = 1, rng:NextInteger(1, 2) do
		local lx = rng:NextNumber(-0.5, 0.5) * r
		local lz = rng:NextNumber(-0.5, 0.5) * r
		lp(m, "SnowLump", cf, V3(r * 0.5, r * 0.22, r * 0.45), CFrame.new(lx, 0.62, lz), C.snow, SNOW, BALL)
	end
	return m
end

----------------------------------------------------------------
-- ICICLES  --  PART COST 2-3 per icicle, at most 24
----------------------------------------------------------------
--[[
	A row of tapered icicles hanging DOWN from y 0 along `width` studs of local
	X -- the caller puts cf on an eave or a cliff lip. Each is two or three
	stacked cylinders of shrinking diameter (Roblox has no cone), iceGlow at
	Transparency 0.25 / Reflectance 0.3. Never more than eight icicles so the
	cost stays under 24; a long eave gets two calls. Non-colliding.
]]
function Props.icicles(parent, cf: CFrame, width: number?): Model
	local w = width or 6
	local rng = Random.new(math.floor(w * 7) + 11)
	local m = model(parent, "Icicles")
	local n = math.clamp(math.floor(w / 1.5), 1, 8)
	local look = { Transparency = 0.25, Reflectance = 0.3 }
	for i = 1, n do
		local x = (n == 1) and 0 or (-w * 0.5 + (i - 0.5) * (w / n)) + rng:NextNumber(-0.2, 0.2)
		local L1 = rng:NextNumber(0.9, 1.6)
		local L2 = L1 * 0.8
		local L3 = L1 * 0.5
		vcyl(m, "Icicle", cf, L1, 0.5, CFrame.new(x, -L1 * 0.5, 0), C.iceGlow, SMOOTH, look)
		vcyl(m, "Icicle", cf, L2, 0.3, CFrame.new(x, -L1 - L2 * 0.5 + 0.05, 0), C.iceGlow, SMOOTH, look)
		if rng:NextNumber() < 0.6 then
			vcyl(m, "Icicle", cf, L3, 0.14, CFrame.new(x, -L1 - L2 - L3 * 0.5 + 0.1, 0), C.iceGlow, SMOOTH, look)
		end
	end
	return m
end

----------------------------------------------------------------
-- RESEARCH STATION  --  PART COST 48
----------------------------------------------------------------
--[[
	An expedition hut on a timber skid: canvas walls between timber corner
	posts, a flat roof under a thick snow cap, a door and one warm window on
	-Z (Neon, no light); a dish antenna on an iron post to the east, a weather
	mast with three cross-arms to the west, two crates and a fuel barrel beside
	it and a small red flag. The crates, barrel and flag are the builders above,
	parented into this model, so their costs (8 + 8 + 5 + 4) are in the total.
]]
function Props.researchStation(parent, cf: CFrame): Model
	local m = model(parent, "ResearchStation")
	local W, D, H = 12, 9, 6.5
	lp(m, "Skid", cf, V3(13, 0.5, 10), CFrame.new(0, 0.25, 0), C.timberDark, WOOD, COLLIDE)
	lp(m, "Wall", cf, V3(W, H, 0.4), CFrame.new(0, 0.5 + H * 0.5, -D * 0.5), C.canvas, FABRIC, COLLIDE)
	lp(m, "Wall", cf, V3(W, H, 0.4), CFrame.new(0, 0.5 + H * 0.5, D * 0.5), C.canvas, FABRIC, COLLIDE)
	lp(m, "Wall", cf, V3(0.4, H, D), CFrame.new(-W * 0.5, 0.5 + H * 0.5, 0), dk(C.canvas, 0.08), FABRIC, COLLIDE)
	lp(m, "Wall", cf, V3(0.4, H, D), CFrame.new(W * 0.5, 0.5 + H * 0.5, 0), dk(C.canvas, 0.08), FABRIC, COLLIDE)
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			vcyl(m, "Post", cf, H + 0.6, 0.5, CFrame.new(sx * (W * 0.5 + 0.1), 0.5 + (H + 0.6) * 0.5, sz * (D * 0.5 + 0.1)), C.timber, WOOD)
		end
	end
	lp(m, "Roof", cf, V3(W + 1.2, 0.4, D + 1.2), CFrame.new(0, 0.5 + H + 0.2, 0), C.timberDark, WOOD, COLLIDE)
	lp(m, "RoofSnow", cf, V3(W + 0.8, 0.7, D + 0.8), CFrame.new(0, 0.5 + H + 0.75, 0), C.snow, SNOW, COLLIDE)
	lp(m, "Door", cf, V3(2.8, 5.0, 0.25), CFrame.new(-2.5, 3.0, -D * 0.5 - 0.25), C.timberDark, WOOD)
	lp(m, "Window", cf, V3(2.0, 1.6, 0.25), CFrame.new(3.2, 4.4, -D * 0.5 - 0.25), C.lanternWarm, NEON)

	-- dish antenna: an iron post, a tilted disc, a feed stub along its normal
	vcyl(m, "DishPost", cf, 5, 0.35, CFrame.new(9.5, 2.5, 1), C.iron, METAL)
	local dishFrame = CFrame.new(9.5, 5.4, 1) * CFrame.Angles(0, 0, 0.9)
	lp(m, "Dish", cf, V3(0.3, 3.2, 3.2), dishFrame, C.snowShade, METAL, CYL)
	lp(m, "DishFeed", cf, V3(1.2, 0.15, 0.15), dishFrame * CFrame.new(0.6, 0, 0), C.iron, METAL, CYL)

	-- weather mast: three cross-arms at three heights, each tipped with a cup
	vcyl(m, "Mast", cf, 11, 0.3, CFrame.new(-9.5, 5.5, 2), C.iron, METAL)
	for k, y in ipairs({ 9.5, 8.0, 6.5 }) do
		local armFrame = CFrame.new(-9.5, y, 2) * CFrame.Angles(0, k * 0.7, 0)
		lp(m, "Arm", cf, V3(2.8, 0.14, 0.14), armFrame, C.iron, METAL)
		lp(m, "Cup", cf, V3(0.36, 0.36, 0.36), armFrame * CFrame.new(1.4, 0, 0), (k == 1) and C.red or C.brass, SMOOTH, BALL)
	end

	Props.supplyCrate(m, cf * CFrame.new(-8.5, 0, -3.5) * CFrame.Angles(0, 0.3, 0), 1.0)
	Props.supplyCrate(m, cf * CFrame.new(-8.6, 0, -0.2) * CFrame.Angles(0, -0.2, 0), 0.8)
	Props.fuelBarrel(m, cf * CFrame.new(8.8, 0, -4.2))
	Props.flagPole(m, cf * CFrame.new(5.5, 0, -7.2), C.red)
	return m
end

----------------------------------------------------------------
-- JETTY  --  WORLD POINTS; PART COST ~1 per 2 studs + posts
----------------------------------------------------------------
--[[
	A plank walkway from a to b, 8 wide: planks every 2 studs (timber, walkable),
	a snow dusting per 8-stud run, and posts every 8 studs down both sides
	reaching 12 below the deck so they show through clear ice or water. Y is
	interpolated from a to b so a jetty can run gently down to the sea. The
	deck top is at a.Y + 0.4; the caller passes the deck line, not the ground.
]]
function Props.jetty(parent, a: Vector3, b: Vector3): Model
	local m = model(parent, "Jetty")
	local d = b - a
	local flat = V3(d.X, 0, d.Z)
	local len = flat.Magnitude
	if len < 1 then
		return m
	end
	local dir = flat.Unit
	local function at(t: number): Vector3
		return a + d * t
	end
	local function frameAt(t: number): CFrame
		local p = at(t)
		return CFrame.lookAt(p, p + dir)
	end

	local n = math.max(1, math.floor(len / 2))
	local step = len / n
	for i = 1, n do
		P(m, "Plank", V3(8, 0.4, step * 0.92), frameAt((i - 0.5) / n) * CFrame.new(0, 0.2, 0),
			(i % 2 == 0) and C.timber or dk(C.timber, 0.1), WOOD, COLLIDE)
	end

	local runs = math.max(1, math.floor(len / 8))
	local runLen = len / runs
	for i = 1, runs do
		P(m, "SnowDust", V3(7.0, 0.22, runLen * 0.9),
			frameAt((i - 0.5) / runs) * CFrame.new(0.4 * ((i % 2 == 0) and 1 or -1), 0.5, 0), C.snow, SNOW)
	end

	local posts = math.floor(len / 8) + 1
	for i = 0, posts - 1 do
		local t = math.clamp(i * 8 / len, 0, 1)
		local p = at(t)
		local top, bottom = p.Y + 1.0, p.Y - 12
		local h = top - bottom
		for _, side in ipairs({ -1, 1 }) do
			P(m, "Post", V3(h, 0.8, 0.8),
				frameAt(t) * CFrame.new(side * 3.8, (top + bottom) * 0.5 - p.Y, 0) * UP,
				dk(C.timber, 0.25), WOOD, ext(CYL, COLLIDE))
		end
	end
	return m
end

----------------------------------------------------------------
-- CAMPFIRE  --  PART COST 12 unlit, 15 lit (+1 emitter, +1 light)
----------------------------------------------------------------
--[[
	A ring of eight stones round three crossed logs on an ember bed. When `lit`
	the bed goes Neon, three tapering Neon flames (red -> orange -> yellow, all
	at Transparency 0) stack over the logs, a fire emitter (Rate 12) rides the
	middle flame and a PointLight (Range 26, Brightness 1.3) warms the ground.
	Unlit it is a cold fire pit: grey ash, no glow, no light.
]]
function Props.campfire(parent, cf: CFrame, lit: boolean?): Model
	local m = model(parent, "Campfire")
	for k = 0, 7 do
		local a = k * math.pi * 0.25
		lp(m, "Stone", cf, V3(1.1, 0.8, 1.0), CFrame.new(2.2 * math.sin(a), 0.3, -2.2 * math.cos(a)) * CFrame.Angles(0, a, 0),
			(k % 2 == 0) and C.stoneCold or C.stoneDark, SLATE, BALL)
	end
	for k = 0, 2 do
		lp(m, "Log", cf, V3(3.4, 0.55, 0.55),
			CFrame.new(0, 0.5, 0) * CFrame.Angles(0, k * math.pi / 3, 0) * CFrame.Angles(0, 0, 0.25),
			C.timberDark, WOOD, CYL)
	end
	if lit then
		vcyl(m, "Embers", cf, 0.15, 2.6, CFrame.new(0, 0.08, 0), dk(C.red, 0.15), NEON)
		lp(m, "Flame", cf, V3(1.7, 1.5, 1.7), CFrame.new(0, 1.0, 0), C.red, NEON, BALL)
		local mid = lp(m, "Flame", cf, V3(1.1, 1.6, 1.1), CFrame.new(0, 1.6, 0), Color3.fromRGB(255, 140, 40), NEON, BALL)
		lp(m, "Flame", cf, V3(0.6, 1.3, 0.6), CFrame.new(0, 2.2, 0), C.gold, NEON, BALL)

		local fire = Instance.new("ParticleEmitter")
		fire.Texture = SMOKE_TEX
		fire.Rate = 12
		fire.Lifetime = NumberRange.new(0.6, 1.1)
		fire.Speed = NumberRange.new(2.5, 4)
		fire.Acceleration = Vector3.new(0, 3, 0)
		fire.Color = ColorSequence.new(Color3.fromRGB(255, 200, 90), Color3.fromRGB(200, 60, 20))
		fire.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.1), NumberSequenceKeypoint.new(1, 0.2) })
		fire.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
		fire.LightEmission = 1
		fire.EmissionDirection = Enum.NormalId.Top
		fire.Parent = mid

		light(mid, Color3.fromRGB(255, 170, 90), 26, 1.3)
	else
		vcyl(m, "Ash", cf, 0.15, 2.6, CFrame.new(0, 0.08, 0), C.stoneDark, SLATE)
	end
	return m
end

----------------------------------------------------------------
-- STRING LIGHTS  --  WORLD POINTS; PART COST count bulbs + count+1 cord segments
----------------------------------------------------------------
--[[
	A thin sagging cord from a to b with `count` small Neon bulbs hung along it,
	colours cycling red / green / gold / iceGlow. NO lights: a string of forty
	bulbs is forty Neon balls and nothing else. The sag is a parabola scaled to
	the span and capped at two studs. Non-colliding throughout.
]]
function Props.stringLights(parent, a: Vector3, b: Vector3, count: number?): Model
	local m = model(parent, "StringLights")
	local n = math.max(1, math.floor(count or 8))
	local span = (b - a).Magnitude
	if span < 0.5 then
		return m
	end
	local sag = math.min(span * 0.06, 2.0)
	local function at(t: number): Vector3
		return a:Lerp(b, t) - V3(0, 4 * sag * t * (1 - t), 0)
	end
	local cycle = { C.red, C.green, C.gold, C.iceGlow }
	local prev = at(0)
	for i = 1, n + 1 do
		local t = i / (n + 1)
		local p = at(t)
		seg(m, "Cord", prev, p, 0.08, C.iron, SMOOTH)
		if i <= n then
			P(m, "Bulb", V3(0.36, 0.36, 0.36), CFrame.new(p - V3(0, 0.26, 0)), cycle[(i - 1) % 4 + 1], NEON, BALL)
		end
		prev = p
	end
	return m
end

----------------------------------------------------------------
-- PRESENT STACK  --  PART COST 15
----------------------------------------------------------------
--[[
	Four wrapped boxes (red, green, gold, ice blue) with two crossing ribbon
	bands each, and a bow on the top box. Two on the ground, one on each.
]]
function Props.presentStack(parent, cf: CFrame): Model
	local m = model(parent, "PresentStack")
	local function gift(size: Vector3, offset: CFrame, colour: Color3, ribbon: Color3)
		lp(m, "Box", cf, size, offset, colour, FABRIC)
		lp(m, "Ribbon", cf, V3(0.3, size.Y + 0.08, size.Z + 0.08), offset, ribbon, SMOOTH)
		lp(m, "Ribbon", cf, V3(size.X + 0.08, size.Y + 0.08, 0.3), offset, ribbon, SMOOTH)
	end
	gift(V3(2.6, 2.0, 2.4), CFrame.new(-1.2, 1.0, 0.2), C.red, C.gold)
	gift(V3(2.0, 1.6, 2.0), CFrame.new(1.6, 0.8, -0.4) * CFrame.Angles(0, 0.3, 0), C.green, C.red)
	gift(V3(1.8, 1.4, 1.8), CFrame.new(-1.0, 2.7, 0.0) * CFrame.Angles(0, -0.2, 0), C.gold, C.red)
	gift(V3(1.3, 1.1, 1.3), CFrame.new(1.7, 2.15, -0.3) * CFrame.Angles(0, 0.5, 0), C.iceDeep, C.snow)
	-- the bow: two loops and a knot on the gold box
	local bowAt = CFrame.new(-1.0, 3.55, 0.0)
	lp(m, "BowLoop", cf, V3(0.9, 0.35, 0.45), bowAt * CFrame.Angles(0, 0.7, 0) * CFrame.new(0.4, 0, 0), C.red, FABRIC, BALL)
	lp(m, "BowLoop", cf, V3(0.9, 0.35, 0.45), bowAt * CFrame.Angles(0, 0.7, 0) * CFrame.new(-0.4, 0, 0), C.red, FABRIC, BALL)
	lp(m, "BowKnot", cf, V3(0.35, 0.35, 0.35), bowAt, dk(C.red, 0.2), FABRIC, BALL)
	return m
end

----------------------------------------------------------------
-- PENGUIN NEST  --  PART COST 13
----------------------------------------------------------------
--[[
	A low disc of shaded snow, a ring of ten grey pebbles and two pale eggs in
	the middle. The eggs are penguinBelly ivory -- pale enough to read as eggs,
	not white enough to vanish. Non-colliding; the colony is walked through.
]]
function Props.penguinNest(parent, cf: CFrame): Model
	local m = model(parent, "PenguinNest")
	vcyl(m, "Mound", cf, 0.4, 4.4, CFrame.new(0, 0.18, 0), C.snowShade, SNOW)
	for k = 0, 9 do
		local a = k * math.pi * 0.2 + 0.1
		local r = 1.5 + (k % 2) * 0.15
		lp(m, "Pebble", cf, V3(0.6, 0.4, 0.55), CFrame.new(r * math.sin(a), 0.5, -r * math.cos(a)) * CFrame.Angles(0, a, 0),
			(k % 3 == 0) and C.stoneDark or C.stoneCold, SLATE, BALL)
	end
	lp(m, "Egg", cf, V3(0.75, 0.95, 0.75), CFrame.new(-0.42, 0.8, 0.1) * CFrame.Angles(0.15, 0, 0.2), C.penguinBelly, SMOOTH, BALL)
	lp(m, "Egg", cf, V3(0.7, 0.9, 0.7), CFrame.new(0.4, 0.78, -0.15) * CFrame.Angles(-0.1, 0, -0.25), C.penguinBelly, SMOOTH, BALL)
	return m
end

----------------------------------------------------------------
-- TRADING POST  --  PART COST 32
----------------------------------------------------------------
--[[
	THE SHOP COUNTER for the upgrade prompt. A timber counter facing -Z under a
	snow-capped awning on two posts, a shelf wall behind it stocked with tins,
	a rope coil and a lantern (Neon pane, no light), a hanging sign board part
	named "ShopBoard" -- the caller letters it -- and a string of Neon bulbs
	along the awning's front edge (no lights).

	NO ProximityPrompt lives in here. Island5Builder owns a PromptAnchor part
	that carries the ShopPrompt, exactly as Island4Builder does for the
	outfitters, so the shop integration is never tangled with a prop rebuild.
	The counter, its sides, the posts and the shelf wall collide; a player
	stands at a counter, not inside it.
]]
function Props.tradingPost(parent, cf: CFrame): Model
	local m = model(parent, "TradingPost")
	-- counter
	lp(m, "CounterTop", cf, V3(14, 0.4, 2.6), CFrame.new(0, 3.2, -1.5), lt(C.timber, 0.1), WOOD, COLLIDE)
	lp(m, "CounterFront", cf, V3(14, 3.0, 0.4), CFrame.new(0, 1.5, -2.6), C.timber, WOOD, COLLIDE)
	for _, sx in ipairs({ -1, 1 }) do
		lp(m, "CounterSide", cf, V3(0.4, 3.0, 2.6), CFrame.new(sx * 6.8, 1.5, -1.5), C.timberDark, WOOD, COLLIDE)
		vcyl(m, "AwningPost", cf, 9, 0.6, CFrame.new(sx * 7.2, 4.5, -4.5), C.timberDark, WOOD, COLLIDE)
	end
	-- awning: a slab sloping down toward -Z, its snow, and the front beam
	local aw = CFrame.new(0, 9.0, -1.5) * CFrame.Angles(-0.15, 0, 0)
	lp(m, "Awning", cf, V3(16, 0.4, 8.2), aw, C.canvas, FABRIC)
	lp(m, "AwningSnow", cf, V3(15.6, 0.7, 7.8), aw * CFrame.new(0, 0.5, 0), C.snow, SNOW)
	lp(m, "AwningBeam", cf, V3(16, 0.5, 0.5), CFrame.new(0, 8.3, -5.5), C.timberDark, WOOD)
	-- shelf wall with three shelves
	lp(m, "BackWall", cf, V3(14, 8, 0.4), CFrame.new(0, 4, 3.0), dk(C.timber, 0.2), WOOD, COLLIDE)
	for _, y in ipairs({ 2.2, 4.4, 6.4 }) do
		lp(m, "Shelf", cf, V3(13, 0.25, 1.4), CFrame.new(0, y, 2.2), C.timber, WOOD)
	end
	-- goods: tins, a rope coil, a lantern
	for i, x in ipairs({ -5.2, -3.9, 3.6, 5.0 }) do
		vcyl(m, "Tin", cf, 0.9, 0.7, CFrame.new(x, 4.4 + 0.58, 2.2), (i % 2 == 0) and C.brass or C.red, METAL)
	end
	vcyl(m, "RopeCoil", cf, 0.4, 1.6, CFrame.new(0.5, 2.2 + 0.33, 2.2), C.rope, FABRIC)
	lp(m, "Lantern", cf, V3(0.9, 1.2, 0.9), CFrame.new(-4.6, 6.4 + 0.73, 2.2), C.brass, METAL)
	lp(m, "LanternPane", cf, V3(0.6, 0.8, 0.95), CFrame.new(-4.6, 6.4 + 0.73, 2.2), C.lanternWarm, NEON)
	-- the sign board, hung from the beam on two chains; the caller letters it
	lp(m, "ShopBoard", cf, V3(9, 2.2, 0.35), CFrame.new(0, 6.9, -5.5), C.timberDark, WOOD)
	for _, sx in ipairs({ -1, 1 }) do
		vcyl(m, "Chain", cf, 0.9, 0.1, CFrame.new(sx * 3.8, 7.6, -5.5), C.iron, METAL)
	end
	-- string lights along the front edge of the awning: one cord, eight bulbs
	lp(m, "Cord", cf, V3(15, 0.08, 0.08), CFrame.new(0, 7.95, -5.75), C.iron, SMOOTH, CYL)
	local cycle = { C.red, C.green, C.gold, C.iceGlow }
	for i = 0, 7 do
		lp(m, "Bulb", cf, V3(0.36, 0.36, 0.36), CFrame.new(-7 + i * 2, 7.72, -5.75), cycle[i % 4 + 1], NEON, BALL)
	end
	return m
end

----------------------------------------------------------------
-- SNOW DRIFT  --  PART COST 3
----------------------------------------------------------------
--[[
	Three overlapping soft Snow balls sunk into the ground. The only thing a
	drift has to do is break the flat field with a shadow, so it is shaded
	snow with a lighter crest. Non-colliding.
]]
function Props.snowDrift(parent, cf: CFrame, scale: number?): Model
	local s = scale or 1
	local m = model(parent, "SnowDrift")
	lp(m, "Drift", cf, V3(6 * s, 2.4 * s, 4 * s), CFrame.new(0, 0.7 * s, 0) * CFrame.Angles(0, 0.3, 0), C.snowShade, SNOW, BALL)
	lp(m, "Drift", cf, V3(4.6 * s, 2.0 * s, 3.4 * s), CFrame.new(2.2 * s, 0.55 * s, 0.8 * s) * CFrame.Angles(0, -0.5, 0), C.snowShade, SNOW, BALL)
	lp(m, "Crest", cf, V3(3.8 * s, 1.9 * s, 2.8 * s), CFrame.new(-1.4 * s, 1.0 * s, -0.6 * s) * CFrame.Angles(0, 0.8, 0), C.snow, SNOW, BALL)
	return m
end

----------------------------------------------------------------
-- CAIRN  --  PART COST 6-8
----------------------------------------------------------------
--[[
	Five to seven flat stones stacked to `height`, each turned a little off
	the one below and narrowing toward the top, with a lump of snow on the
	last. Non-colliding: a cairn is a waymark, not a step.
]]
function Props.cairn(parent, cf: CFrame, height: number?): Model
	local h = height or 5
	local m = model(parent, "Cairn")
	local n = math.clamp(math.floor(h / 0.9 + 0.5), 5, 7)
	local sh = h / n
	for i = 1, n do
		local w = 2.6 - (i - 1) * (1.4 / (n - 1))
		local tone = (i % 2 == 0) and C.stoneCold or dk(C.stoneCold, 0.18)
		lp(m, "Stone", cf, V3(w, sh, w * 0.85), CFrame.new(0, (i - 0.5) * sh, 0) * CFrame.Angles(0, i * 0.5, 0), tone, SLATE)
	end
	lp(m, "SnowCap", cf, V3(1.4, 0.5, 1.3), CFrame.new(0, h + 0.15, 0), C.snow, SNOW, BALL)
	return m
end

----------------------------------------------------------------
-- SIGNPOST  --  PART COST 2 + 2 per label (max 8)
----------------------------------------------------------------
--[[
	A timber post with one angled arrow board per label (up to three), each
	board part named "Board1".."Board3" and lettered on its Front and Back
	faces through SignKit.dress inside pcall. The arrow point is a small
	diamond block on the board's far end. Boards alternate the side of the
	post they lean toward so three of them read as three directions.
]]
function Props.signpost(parent, cf: CFrame, labels: { string }?): Model
	local m = model(parent, "Signpost")
	vcyl(m, "Post", cf, 7, 0.5, CFrame.new(0, 3.5, 0), C.timber, WOOD, COLLIDE)
	lp(m, "PostSnow", cf, V3(0.8, 0.4, 0.8), CFrame.new(0, 7.1, 0), C.snow, SNOW, BALL)
	local yaws = { -0.55, 0.65, -0.25 }
	for i, text in ipairs(labels or {}) do
		if i > 3 then
			break
		end
		local y = 6.2 - (i - 1) * 1.1
		local frame = CFrame.new(0, y, 0) * CFrame.Angles(0, yaws[i], 0)
		local board = lp(m, "Board" .. i, cf, V3(4.2, 0.9, 0.25), frame * CFrame.new(1.9, 0, 0), C.timberDark, WOOD)
		lp(m, "Tip" .. i, cf, V3(0.64, 0.64, 0.24), frame * CFrame.new(4.15, 0, 0) * CFrame.Angles(0, 0, math.pi * 0.25), C.timberDark, WOOD)
		dress(board, tostring(text), { Enum.NormalId.Front, Enum.NormalId.Back })
	end
	return m
end

----------------------------------------------------------------
-- DOCK LANTERN  --  PART COST 6 (+1 light if lit)
----------------------------------------------------------------
--[[
	A short bollard lantern for jetty ends: a stone foot, a brass post, a
	brass plate, a warm Neon pane, a brass cap and snow. The PointLight (Range
	22) goes in the pane only when `lit`.
]]
function Props.dockLantern(parent, cf: CFrame, lit: boolean?): Model
	local m = model(parent, "DockLantern")
	vcyl(m, "Foot", cf, 0.4, 1.6, CFrame.new(0, 0.2, 0), C.stoneDark, SLATE, COLLIDE)
	vcyl(m, "Post", cf, 2.4, 0.5, CFrame.new(0, 1.6, 0), C.brass, METAL, COLLIDE)
	lp(m, "Plate", cf, V3(1.3, 0.2, 1.3), CFrame.new(0, 2.9, 0), C.brass, METAL)
	local pane = lp(m, "Pane", cf, V3(0.95, 1.1, 0.95), CFrame.new(0, 3.55, 0), C.lanternWarm, NEON)
	lp(m, "Cap", cf, V3(1.4, 0.25, 1.4), CFrame.new(0, 4.22, 0), C.brass, METAL)
	lp(m, "SnowCap", cf, V3(1.3, 0.5, 1.3), CFrame.new(0, 4.5, 0), C.snow, SNOW, BALL)
	if lit then
		light(pane, C.lanternWarm, 22, 1.2)
	end
	return m
end

----------------------------------------------------------------
-- THE ARCTIC LITTER SET
----------------------------------------------------------------
--[[
	Builds ReplicatedStorage.CTB.Arctic -- the folder CTB_Client.templatesFor
	loads by the island row's litterSet name and scatters over the field.

	The contracts, every one inherited:
	  * direct children only, single BaseParts (a Model is silently ignored);
	  * every axis under 2.0 studs;
	  * the THINNEST axis is Y or Z, never X -- litterRest only lays a piece
	    flat when Z < Y, so an X-thin piece stands on edge. Cylinders are
	    authored as Size(length, dia, dia) so Y == Z;
	  * colours a clear step off white snow (ice blues, kelp green, rust,
	    orange plastic, dark timber, red fabric, brass) -- the inverse of
	    Ashfall's "nothing near black";
	  * anchored, no collide / query / touch / shadow, smooth faces;
	  * any old folder destroyed first, the finished folder parented LAST.
	The sweep at the end warns about any piece that breaks the axis rule with
	the same 0.05 tolerance Island4Props uses, because two float-equal axes
	(0.5501 vs 0.5502) cry wolf under a strict comparison.
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
	local old = parent:FindFirstChild("Arctic")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "Arctic"

	litterPart(folder, "Ice Shard", V3(1.15, 0.22, 0.9), Color3.fromRGB(186, 214, 240), SMOOTH, { Reflectance = 0.3 })
	litterPart(folder, "Frozen Fish", V3(0.5, 0.25, 1.6), Color3.fromRGB(128, 152, 168), SMOOTH)
	litterPart(folder, "Kelp Frond", V3(1.8, 0.12, 0.55), Color3.fromRGB(36, 84, 52), GRASS)
	litterPart(folder, "Rusted Tin", V3(1.15, 0.66, 0.66), Color3.fromRGB(150, 88, 44), CORRODED, CYL)
	litterPart(folder, "Buoy Float", V3(1.0, 0.9, 1.0), Color3.fromRGB(240, 120, 30), SMOOTH, BALL)
	litterPart(folder, "Snow Clod", V3(1.05, 0.85, 1.0), Color3.fromRGB(232, 238, 246), SNOW, BALL)
	litterPart(folder, "Bone Fragment", V3(0.9, 0.5, 0.8), Color3.fromRGB(208, 196, 170), CONCRETE)
	litterPart(folder, "Net Scrap", V3(0.9, 0.28, 0.95), Color3.fromRGB(60, 110, 96), FABRIC, BALL)
	litterPart(folder, "Lost Mitten", V3(0.9, 0.4, 1.1), C.red, FABRIC)
	litterPart(folder, "Cracked Goggles", V3(1.3, 0.4, 0.5), Color3.fromRGB(236, 128, 36), SMOOTH)
	litterPart(folder, "Frozen Bottle", V3(1.4, 0.5, 0.5), Color3.fromRGB(176, 206, 226), Enum.Material.Glass, CYL)
	litterPart(folder, "Fuel Can", V3(1.0, 1.2, 0.6), C.red, CORRODED)
	litterPart(folder, "Fish Crate Slat", V3(1.7, 0.2, 0.6), C.timberDark, WOOD)
	litterPart(folder, "Brass Lure", V3(0.6, 0.6, 0.6), C.brass, METAL, ext(BALL, { Reflectance = 0.5 }))
	litterPart(folder, "Rope Scrap", V3(1.2, 0.35, 0.35), C.rope, FABRIC, CYL)

	-- the resting-axis sweep: what litterRest leaves vertical must be the thinnest axis
	local n = 0
	for _, p in ipairs(folder:GetChildren()) do
		if p:IsA("BasePart") then
			n += 1
			local s = p.Size
			local upright = (s.Z < s.Y) and s.Z or s.Y
			if upright > math.min(s.X, s.Y, s.Z) + 0.05 then
				warn(("[Penguin] litter piece %s is thinnest on X"):format(p.Name))
			end
			if math.max(s.X, s.Y, s.Z) >= 2.0 then
				warn(("[Penguin] litter piece %s has an axis of 2 studs or more"):format(p.Name))
			end
		end
	end

	folder.Parent = parent
	return folder, n
end

return Props
