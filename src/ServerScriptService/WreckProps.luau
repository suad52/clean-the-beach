--[[
	WreckProps -- the prop kit for THE FROZEN WRECK.

	A beached ocean liner lies frozen into the shore of Penguin Island. Her
	EXTERIOR (funnels, lifeboats, masts, railings, the anchor, cowl vents,
	porthole rows, bollards, rope coils, deck cargo) stands out on the island
	in the open air; her HOLD is a sealed interior room built by
	FrozenWreckBuilder (340 x 480 studs, floor at y 3, ceiling at about 50)
	and dressed with the INTERIOR builders here (bunks, the dining saloon, the
	chandelier, the boiler, pipe runs, cargo, the piano, stairs, wall lamps,
	icicle curtains, collapsed beams, the galley, trunks, portholes, the
	wheel, the captain's desk).

	This module is a PURE BUILDER LIBRARY in the Island4Props mould. It
	requires nothing, touches no terrain, and every builder has the shape

		function WreckProps.<name>(parent: Instance, cf: CFrame, ...): Model

	with ONE local frame convention: y = 0 is the GROUND at cf, x = 0 is the
	prop's centre, and the prop faces its own -Z. Every part is placed as
	cf * CFrame.new(offset) through lp(); nothing calls PivotTo and no
	PrimaryPart is set, because FrozenWreckBuilder places these by cf and
	never moves them afterwards. Builders that take WORLD points instead of
	a cf (railingRun, portholeRow, pipeRun, icicleCurtain, brokenBeam) say
	so in their signature -- a: Vector3, b: Vector3 -- and build straight
	between the two.

	EVERYTHING IS FROST-RIMED. The liner has been on this shore for decades:
	pale ice-blue frost slabs lie on every flat surface, icicles hang under
	every beam, rust runs down every iron face, snow has drifted into the
	corners. The frostSlab() helper is how a builder puts frost on a thing;
	it is a translucent SmoothPlastic slab with a little Reflectance, never
	Glass, because Glass culls every transparent object behind it (the cove
	learned this with its lanterns) -- and under Future lighting the frost
	must be seen THROUGH to the deck under it.

	THE RULES THIS FILE INHERITS FROM EVERY ISLAND BEFORE IT (each one was
	learned the hard way):

	  * Every part is Anchored. P() sets it and nothing unsets it.
	  * CanCollide is FALSE by default: P() ships every part as decoration
	    and only things a player walks on or leans against opt in with the
	    SOLID preset. Treads, table tops, crates, barrels, the boiler body,
	    the piano body -- those collide. Rails, frost, icicles, rope, lamp
	    cages, chandelier arms -- never.
	  * Neon stays at Transparency 0. Above zero it renders near-black under
	    Future lighting. Fake depth with a darker colour, never with alpha.
	  * See-through ice is SmoothPlastic + Reflectance 0.2-0.45 + a
	    Transparency, never Glass (Glass hides transparent objects behind it).
	  * No Sandstone on any part (renders mauve in this place).
	  * Lights are PointLight only, ALWAYS Shadows = false, Range <= 32, and
	    only where a builder argument named `lit` says so. Nothing that glows
	    carries a light by default; the Neon slab IS the look. Two builders
	    take `lit` (chandelier, wallLamp); the captain's lamp and the boiler's
	    ember slit are bare Neon and stay that way.
	  * CastShadow is off on anything thinner than a stud, on every Neon
	    part, on anything more than half transparent and on every invisible
	    collider. P() applies the first three automatically (the same rule
	    Island4Builder's finalSweeps runs) so a sweep finds nothing to trim.
	  * Every prop is <= 60 parts and most are under 30; the PART COST is
	    stated above every builder. The room this kit dresses has no
	    OutdoorAmbient and is lit by a handful of roof lights, so parts are
	    cheap and lights are not.
	  * Where a seed is passed the builder uses Random.new(seed) and never
	    math.random. Builders that take world points and want variety
	    (icicleCurtain) derive a seed from the points, so a rebuild puts the
	    same icicle in the same place.

	PALETTE. Every colour comes from PALETTE below, exported as
	WreckProps.PALETTE so FrozenWreckBuilder can adopt it key-for-key the way
	Island4Builder adopts Island4Props.PALETTE, plus WreckProps.dk(c, f) /
	WreckProps.lt(c, f) which lerp toward black / white by f. The values are
	pitched for a BRIGHT place (Lighting.Brightness 3.1 + Bloom): hull and
	iron sit in the 10-30% luma band, frost and snow in the low 200s with a
	cool cast rather than 255-white, and only lampWarm and iceGlow go above.
]]

local WreckProps = {}

---------------------------------------------------------------------------
-- PALETTE
---------------------------------------------------------------------------

local PALETTE = {
	hullRed    = Color3.fromRGB(118, 38, 32),     -- deep rust red; the boot-topping and funnels
	hullBlack  = Color3.fromRGB(28, 28, 32),      -- the hull's black band and funnel caps
	hullWhite  = Color3.fromRGB(196, 192, 178),   -- frosted cream superstructure
	rust       = Color3.fromRGB(132, 72, 40),     -- runs off every iron edge
	iron       = Color3.fromRGB(72, 74, 80),      -- frames, rails, the boiler
	brass      = Color3.fromRGB(176, 136, 62),    -- portholes, handrails, the chandelier
	timber     = Color3.fromRGB(124, 88, 56),     -- decking, tables, crates
	timberDark = Color3.fromRGB(74, 50, 34),      -- masts, pedestals, the underside of things
	velvet     = Color3.fromRGB(96, 22, 30),      -- blankets, the saloon's deep red
	frost      = Color3.fromRGB(206, 226, 240),   -- the translucent rime on every surface
	ice        = Color3.fromRGB(150, 196, 226),   -- solid ice, deeper than frost
	iceGlow    = Color3.fromRGB(178, 226, 255),   -- Neon ice: icicles, crystal drops, daylight discs
	snow       = Color3.fromRGB(214, 224, 232),   -- drifts and caps (cool, not white)
	glassPale  = Color3.fromRGB(190, 214, 228),   -- frosted porthole glass, plates, cups
	lampWarm   = Color3.fromRGB(255, 196, 120),   -- the one warm colour in the wreck
	coal       = Color3.fromRGB(24, 22, 22),      -- firebox doors, the range, piano black
}
WreckProps.PALETTE = PALETTE

local BLACK = Color3.new(0, 0, 0)
local WHITE = Color3.new(1, 1, 1)

local function dk(c: Color3, f: number): Color3
	return c:Lerp(BLACK, f)
end

local function lt(c: Color3, f: number): Color3
	return c:Lerp(WHITE, f)
end

WreckProps.dk, WreckProps.lt = dk, lt

-- Derived shades used in more than one builder. Rope is bleached timber;
-- the dark iron is what sits under rust.
local ROPE = lt(PALETTE.timber, 0.28)
local IRON_DARK = dk(PALETTE.iron, 0.35)
local CANVAS = lt(PALETTE.hullWhite, 0.12)

---------------------------------------------------------------------------
-- PART HELPERS
---------------------------------------------------------------------------

local M = Enum.Material
local SMOOTH = M.SmoothPlastic

-- Presets passed as the `extra` table. SOLID is the only way a part gets
-- collision; TRIM is for decoration that is thick enough to keep a shadow
-- by the automatic rule but should not (rope, small brass, cage bars).
local SOLID = { CanCollide = true }
local TRIM = { CastShadow = false }
local SOLID_TRIM = { CanCollide = true, CastShadow = false }

-- Rotations used everywhere. A Part cylinder's axis is X; ROLL stands it up
-- (axis -> Y) and YAW90 lays it along Z (axis -> -Z of the frame it is
-- multiplied into).
local ROLL = CFrame.Angles(0, 0, math.pi * 0.5)
local YAW90 = CFrame.Angles(0, math.pi * 0.5, 0)

-- finish(): the body shared by P() and wedge(). Anchored, smooth faces,
-- CanCollide off unless the extras say otherwise, then the three-class
-- CastShadow trim so nothing this kit makes needs a sweep.
local function finish(p: BasePart, parent: Instance, name: string, size: Vector3, cf: CFrame,
	colour: Color3, material: Enum.Material?, extra)
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = colour
	p.Material = material or SMOOTH
	p.Anchored = true
	p.CanCollide = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if extra then
		for k, v in pairs(extra) do
			p[k] = v
		end
	end
	local s = p.Size
	if math.min(s.X, s.Y, s.Z) < 1.0
		or p.Material == M.Neon
		or p.Transparency > 0.5 then
		p.CastShadow = false
	end
	p.Parent = parent
	return p
end

-- P(): an anchored Part in WORLD space.
local function P(parent: Instance, name: string, size: Vector3, cf: CFrame,
	colour: Color3, material: Enum.Material?, extra): Part
	local p = Instance.new("Part")
	finish(p, parent, name, size, cf, colour, material, extra)
	return p
end

-- wedge(): an anchored WedgePart. The tall face is the part's Back (+Z)
-- and the slope runs down toward the Front (-Z) -- so a "splintered end"
-- is a wedge whose +Z face touches the thing it splinters off.
local function wedge(parent: Instance, name: string, size: Vector3, cf: CFrame,
	colour: Color3, material: Enum.Material?, extra): WedgePart
	local w = Instance.new("WedgePart")
	finish(w, parent, name, size, cf, colour, material, extra)
	return w
end

-- lp(): a part in a prop's LOCAL frame: base * offset. Every builder that
-- takes a cf places through this.
local function lp(parent: Instance, name: string, base: CFrame, size: Vector3, offset: CFrame,
	colour: Color3, material: Enum.Material?, extra): Part
	return P(parent, name, size, base * offset, colour, material, extra)
end

-- Cylinders in the local frame. h is the length along the axis, d the
-- diameter. cylY stands up, cylZ lies along the prop's Z, cylX along X.
local function cylY(parent: Instance, name: string, base: CFrame, h: number, d: number, offset: CFrame,
	colour: Color3, material: Enum.Material?, extra): Part
	local p = lp(parent, name, base, Vector3.new(h, d, d), offset * ROLL, colour, material, extra)
	p.Shape = Enum.PartType.Cylinder
	return p
end

local function cylZ(parent: Instance, name: string, base: CFrame, h: number, d: number, offset: CFrame,
	colour: Color3, material: Enum.Material?, extra): Part
	local p = lp(parent, name, base, Vector3.new(h, d, d), offset * YAW90, colour, material, extra)
	p.Shape = Enum.PartType.Cylinder
	return p
end

local function cylX(parent: Instance, name: string, base: CFrame, h: number, d: number, offset: CFrame,
	colour: Color3, material: Enum.Material?, extra): Part
	local p = lp(parent, name, base, Vector3.new(h, d, d), offset, colour, material, extra)
	p.Shape = Enum.PartType.Cylinder
	return p
end

local function ball(parent: Instance, name: string, base: CFrame, d: number, offset: CFrame,
	colour: Color3, material: Enum.Material?, extra): Part
	local p = lp(parent, name, base, Vector3.new(d, d, d), offset, colour, material, extra)
	p.Shape = Enum.PartType.Ball
	return p
end

-- lookAlong(): a CFrame at `from` whose -Z points at `to`, safe for
-- vertical runs (CFrame.lookAt is ill-defined when the look direction is
-- parallel to the up vector, and a pipe run or a rigging line can be
-- straight up).
local function lookAlong(from: Vector3, to: Vector3): CFrame
	local d = to - from
	if d.Magnitude < 1e-4 then
		return CFrame.new(from)
	end
	local up = Vector3.yAxis
	if math.abs(d.Unit.Y) > 0.98 then
		up = Vector3.xAxis
	end
	return CFrame.lookAt(from, to, up)
end

-- spanCyl(): a cylinder of diameter d from WORLD point a to WORLD point b.
-- Returns nil for a span under 0.05 (the same guard Island4Builder's box()
-- keeps: spans that land on 0.05 vanish in float).
local function spanCyl(parent: Instance, name: string, a: Vector3, b: Vector3, d: number,
	colour: Color3, material: Enum.Material?, extra): Part?
	local len = (b - a).Magnitude
	if len < 0.05 then
		return nil
	end
	local mid = (a + b) * 0.5
	local p = P(parent, name, Vector3.new(len, d, d), lookAlong(mid, b) * YAW90, colour, material, extra)
	p.Shape = Enum.PartType.Cylinder
	return p
end

-- spanBox(): a box w wide and h tall from WORLD point a to WORLD point b.
local function spanBox(parent: Instance, name: string, a: Vector3, b: Vector3, w: number, h: number,
	colour: Color3, material: Enum.Material?, extra): Part?
	local len = (b - a).Magnitude
	if len < 0.05 then
		return nil
	end
	local mid = (a + b) * 0.5
	return P(parent, name, Vector3.new(w, h, len), lookAlong(mid, b), colour, material, extra)
end

-- frostSlab(): THE frost. A translucent pale slab, SmoothPlastic with a
-- little reflectance so it catches the roof lights, never Glass. Never
-- collides, never casts (0.45 is under the automatic 0.5 cut, so it is set
-- here by hand). size.Y is honoured so a builder can make a thick rime.
local function frostSlab(parent: Instance, name: string, base: CFrame, size: Vector3, offset: CFrame): Part
	return lp(parent, name, base, size, offset, PALETTE.frost, SMOOTH,
		{ Transparency = 0.45, Reflectance = 0.25, CastShadow = false })
end

-- iceGlass(): frosted see-through pane (portholes, lamp cages, plates).
local function iceGlass(parent: Instance, name: string, base: CFrame, size: Vector3, offset: CFrame,
	transparency: number, reflectance: number): Part
	return lp(parent, name, base, size, offset, PALETTE.glassPale, SMOOTH,
		{ Transparency = transparency, Reflectance = reflectance, CastShadow = false })
end

-- neon(): a glowing part. Transparency 0 ALWAYS; the colour carries the
-- depth. Never collides, never casts.
local function neon(parent: Instance, name: string, base: CFrame, size: Vector3, offset: CFrame, colour: Color3): Part
	return lp(parent, name, base, size, offset, colour, M.Neon,
		{ Transparency = 0, CastShadow = false })
end

-- light(): the ONLY way this kit makes a light. PointLight, Shadows off.
-- Exported so FrozenWreckBuilder can light its own hosts the same way.
local function light(part: BasePart, colour: Color3, range: number, brightness: number): PointLight
	local l = Instance.new("PointLight")
	l.Color = colour
	l.Range = math.min(range, 32)
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = part
	return l
end
WreckProps.light = light

-- model(): every builder starts here. No PrimaryPart.
local function model(parent: Instance, name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

-- hashSeed(): a deterministic seed from two world points, for builders
-- that take points instead of a seed and still want variety that survives
-- a rebuild.
local function hashSeed(a: Vector3, b: Vector3): number
	local h = a.X * 73.856 + a.Y * 19.349 + a.Z * 83.492
		+ b.X * 7.13 + b.Y * 3.7 + b.Z * 11.9
	return math.floor(math.abs(h) * 100) % 2147483647
end

-- chair(): a four-part saloon chair used by diningTable and captainDesk.
-- offset's -Z is where the table is; the back stands at +Z.
-- PART COST: 4.
local function chair(parent: Instance, base: CFrame, offset: CFrame)
	lp(parent, "Seat", base, Vector3.new(1.8, 0.3, 1.8), offset * CFrame.new(0, 1.65, 0),
		PALETTE.timber, M.Wood, SOLID_TRIM)
	lp(parent, "Back", base, Vector3.new(1.8, 2.0, 0.25), offset * CFrame.new(0, 2.8, 0.78),
		PALETTE.timber, M.Wood, TRIM)
	lp(parent, "LegsL", base, Vector3.new(0.25, 1.5, 1.7), offset * CFrame.new(-0.75, 0.75, 0),
		PALETTE.timberDark, M.Wood, TRIM)
	lp(parent, "LegsR", base, Vector3.new(0.25, 1.5, 1.7), offset * CFrame.new(0.75, 0.75, 0),
		PALETTE.timberDark, M.Wood, TRIM)
end

-- crate(): a timber crate of side s with a frost cap. Collides.
-- PART COST: 2.
local function crate(parent: Instance, base: CFrame, offset: CFrame, s: number)
	lp(parent, "Crate", base, Vector3.new(s, s * 0.85, s), offset * CFrame.new(0, s * 0.425, 0),
		PALETTE.timber, M.Wood, SOLID)
	frostSlab(parent, "CrateFrost", base, Vector3.new(s * 0.9, 0.12, s * 0.9),
		offset * CFrame.new(0, s * 0.85 + 0.06, 0))
end

---------------------------------------------------------------------------
-- SMALL SHARED BUILDERS (defined first because bigger ones call them)
---------------------------------------------------------------------------

--[[
	barrel -- a wooden barrel with two iron bands. Collides: it is the kind
	of thing a player climbs on in a hold.
	PART COST: 3.
]]
function WreckProps.barrel(parent: Instance, cf: CFrame): Model
	local m = model(parent, "Barrel")
	cylY(m, "Stave", cf, 3.2, 2.4, CFrame.new(0, 1.6, 0), PALETTE.timber, M.Wood, SOLID)
	cylY(m, "BandLow", cf, 0.3, 2.5, CFrame.new(0, 0.8, 0), IRON_DARK, M.Metal, TRIM)
	cylY(m, "BandHigh", cf, 0.3, 2.5, CFrame.new(0, 2.4, 0), IRON_DARK, M.Metal, TRIM)
	return m
end

--[[
	frostPatch -- one thin translucent frost slab, size.X by 0.12 by size.Z,
	lying on the plane of cf (its underside is at cf's y).
	PART COST: 1.
]]
function WreckProps.frostPatch(parent: Instance, cf: CFrame, size: Vector3): Model
	local m = model(parent, "FrostPatch")
	frostSlab(m, "Frost", cf, Vector3.new(size.X, 0.12, size.Z), CFrame.new(0, 0.06, 0))
	return m
end

--[[
	rustStreak -- a thin dark strip for a hull side. cf is the TOP of the
	streak on the hull surface, facing out along -Z; the strip hangs down
	`length` from there, a hair proud of the plate.
	PART COST: 1.
]]
function WreckProps.rustStreak(parent: Instance, cf: CFrame, length: number): Model
	local m = model(parent, "RustStreak")
	lp(m, "Streak", cf, Vector3.new(0.7, length, 0.1), CFrame.new(0, -length * 0.5, -0.06),
		dk(PALETTE.rust, 0.25), M.Slate, TRIM)
	return m
end

--[[
	snowBank -- three overlapping Snow balls sunk into a floor or corner.
	Part Snow is fine (only TERRAIN Snow is the beach's tinted raked
	material). Never collides: a player walks through a drift.
	PART COST: 3.
]]
function WreckProps.snowBank(parent: Instance, cf: CFrame, scale: number): Model
	local m = model(parent, "SnowBank")
	local s = scale or 1
	local specs = {
		{ x = 0, z = 0, d = 4.2 },
		{ x = 1.6, z = -0.9, d = 3.0 },
		{ x = -1.7, z = 0.8, d = 2.6 },
	}
	for i, b in ipairs(specs) do
		local d = b.d * s
		-- sunk to a third of the radius so it reads as a drift, not a ball
		ball(m, "Drift" .. i, cf, d, CFrame.new(b.x * s, d * 0.5 - d * 0.34, b.z * s),
			PALETTE.snow, M.Snow, TRIM)
	end
	return m
end

---------------------------------------------------------------------------
-- EXTERIOR
---------------------------------------------------------------------------

--[[
	funnel -- a liner funnel. A tall hullRed cylinder with a black cap band,
	a steel rim, rust streaks running down the plate, a snow cap on top and
	three guy-lines to the deck. The diameter follows the height (a liner
	funnel is about 0.38 as wide as it is tall) so one call scales the whole
	thing. Only the body collides.
	PART COST: 11 (body, cap band, rim, snow cap, 4 streaks, 3 guys).
]]
function WreckProps.funnel(parent: Instance, cf: CFrame, height: number, seed: number?): Model
	local m = model(parent, "Funnel")
	local rng = Random.new(seed or 1)
	local h = height
	local d = math.max(4, h * 0.38)
	local r = d * 0.5

	cylY(m, "Body", cf, h, d, CFrame.new(0, h * 0.5, 0), PALETTE.hullRed, M.Metal, SOLID)
	cylY(m, "CapBand", cf, h * 0.18, d + 0.3, CFrame.new(0, h - h * 0.09, 0), PALETTE.hullBlack, M.Metal, TRIM)
	cylY(m, "Rim", cf, 0.6, d + 0.8, CFrame.new(0, h - 0.3, 0), IRON_DARK, M.Metal, TRIM)
	cylY(m, "SnowCap", cf, 0.8, d * 0.85, CFrame.new(0, h + 0.4, 0), PALETTE.snow, M.Snow, TRIM)

	-- Rust streaks: thin strips on the plate, running down from the cap band.
	for i = 1, 4 do
		local a = rng:NextNumber(0, math.pi * 2)
		local len = rng:NextNumber(h * 0.25, h * 0.6)
		local w = rng:NextNumber(0.5, 1.1)
		lp(m, "Streak" .. i, cf, Vector3.new(w, len, 0.1),
			CFrame.Angles(0, a, 0) * CFrame.new(0, h * 0.82 - len * 0.5, -(r + 0.06)),
			dk(PALETTE.rust, 0.2), M.Slate, TRIM)
	end

	-- Guy-lines from just under the rim out to the deck.
	for i = 1, 3 do
		local a = (i - 1) * (math.pi * 2 / 3) + 0.4
		local top = cf:PointToWorldSpace(Vector3.new(math.cos(a) * r, h * 0.86, math.sin(a) * r))
		local foot = cf:PointToWorldSpace(Vector3.new(math.cos(a) * (r + h * 0.45), 0, math.sin(a) * (r + h * 0.45)))
		spanCyl(m, "Guy" .. i, top, foot, 0.22, ROPE, M.Fabric, TRIM)
	end

	return m
end

--[[
	lifeboat -- a small clinker boat hanging on two davits. cf is the deck
	point at the rail: the davits rise from y = 0 at x = +-4 and curve
	outboard (-Z), the boat hangs off their tips with its keel four studs
	above the deck. The hull is three stacked tapered boxes (a clinker
	strake look at three parts), a keel strip, a frosted canvas cover and a
	frost slab on the cover. Nothing collides: it hangs over the side.
	PART COST: 14 (6 davit segments, 2 falls, 3 strakes, keel, cover, frost).
]]
function WreckProps.lifeboat(parent: Instance, cf: CFrame): Model
	local m = model(parent, "Lifeboat")
	local BZ = -3.5      -- how far outboard the boat hangs

	-- Davits: three cylinders each, post / knee / arm.
	for _, sx in ipairs({ -4, 4 }) do
		local p0 = cf:PointToWorldSpace(Vector3.new(sx, 0, 0))
		local p1 = cf:PointToWorldSpace(Vector3.new(sx, 7, 0))
		local p2 = cf:PointToWorldSpace(Vector3.new(sx, 9, -2.2))
		local p3 = cf:PointToWorldSpace(Vector3.new(sx, 9.5, -4.5))
		spanCyl(m, "DavitPost", p0, p1, 0.5, PALETTE.iron, M.Metal, TRIM)
		spanCyl(m, "DavitKnee", p1, p2, 0.5, PALETTE.iron, M.Metal, TRIM)
		spanCyl(m, "DavitArm", p2, p3, 0.5, PALETTE.iron, M.Metal, TRIM)
		-- the fall (rope) from the arm tip down to the gunwale
		local tip = cf:PointToWorldSpace(Vector3.new(sx, 9.4, -4.2))
		local gun = cf:PointToWorldSpace(Vector3.new(sx, 6.7, BZ))
		spanCyl(m, "Fall", tip, gun, 0.16, ROPE, M.Fabric, TRIM)
	end

	-- Hull: three strakes, widest at the top.
	lp(m, "StrakeLow", cf, Vector3.new(10, 0.9, 2.4), CFrame.new(0, 4.45, BZ), dk(PALETTE.hullWhite, 0.18), M.WoodPlanks, TRIM)
	lp(m, "StrakeMid", cf, Vector3.new(12, 0.9, 3.6), CFrame.new(0, 5.35, BZ), dk(PALETTE.hullWhite, 0.08), M.WoodPlanks, TRIM)
	lp(m, "StrakeTop", cf, Vector3.new(13, 0.9, 4.4), CFrame.new(0, 6.25, BZ), PALETTE.hullWhite, M.WoodPlanks, TRIM)
	lp(m, "Keel", cf, Vector3.new(11, 0.3, 0.3), CFrame.new(0, 3.9, BZ), PALETTE.timberDark, M.Wood, TRIM)

	-- Canvas cover, frozen stiff, and its rime.
	lp(m, "Cover", cf, Vector3.new(12.6, 0.3, 4.0), CFrame.new(0, 6.85, BZ), CANVAS, M.Fabric, TRIM)
	frostSlab(m, "CoverFrost", cf, Vector3.new(12.0, 0.12, 3.6), CFrame.new(0, 7.06, BZ))

	return m
end

--[[
	railingRun -- deck railing between two WORLD points: a post every four
	studs (and one at the far end), two iron rails, frost along the top
	rail. Nothing collides; the builder puts its own invisible fence where a
	player must not fall.
	PART COST: floor(len / 4) + 1 posts + 3 rails.
]]
function WreckProps.railingRun(parent: Instance, a: Vector3, b: Vector3): Model
	local m = model(parent, "RailingRun")
	local d = b - a
	local len = d.Magnitude
	if len < 0.05 then
		return m
	end
	local dir = d.Unit
	local n = math.floor(len / 4)
	for i = 0, n do
		local t = math.min(i * 4, len)
		local pos = a + dir * t
		P(m, "Post", Vector3.new(0.3, 3.2, 0.3), lookAlong(pos + Vector3.new(0, 1.6, 0), pos + Vector3.new(0, 1.6, 0) + dir),
			PALETTE.iron, M.Metal, TRIM)
	end
	if n * 4 < len - 0.5 then
		P(m, "Post", Vector3.new(0.3, 3.2, 0.3), lookAlong(b + Vector3.new(0, 1.6, 0), b + Vector3.new(0, 1.6, 0) + dir),
			PALETTE.iron, M.Metal, TRIM)
	end
	local UP_TOP, UP_MID = Vector3.new(0, 3.1, 0), Vector3.new(0, 1.7, 0)
	spanBox(m, "RailTop", a + UP_TOP, b + UP_TOP, 0.28, 0.28, PALETTE.iron, M.Metal, TRIM)
	spanBox(m, "RailMid", a + UP_MID, b + UP_MID, 0.22, 0.22, PALETTE.iron, M.Metal, TRIM)
	local UP_FROST = Vector3.new(0, 3.3, 0)
	spanBox(m, "RailFrost", a + UP_FROST, b + UP_FROST, 0.5, 0.12, PALETTE.frost, SMOOTH,
		{ Transparency = 0.45, Reflectance = 0.25, CastShadow = false })
	return m
end

--[[
	mast -- a mast with a crosstree, a crow's nest ring, three rigging
	lines down to the deck and a frozen pennant. The mast itself collides
	(a player can lean on it); everything else is trim.
	PART COST: 10 (mast, crosstree, crosstree snow, nest ring, 3 rigging,
	pennant, pennant frost, truck).
]]
function WreckProps.mast(parent: Instance, cf: CFrame, height: number): Model
	local m = model(parent, "Mast")
	local h = height
	local ct = h * 0.72     -- crosstree height

	cylY(m, "Pole", cf, h, 1.2, CFrame.new(0, h * 0.5, 0), PALETTE.timberDark, M.Wood, SOLID)
	lp(m, "Crosstree", cf, Vector3.new(8, 0.5, 0.5), CFrame.new(0, ct, 0), PALETTE.timberDark, M.Wood, TRIM)
	lp(m, "CrosstreeSnow", cf, Vector3.new(7.6, 0.3, 0.6), CFrame.new(0, ct + 0.4, 0), PALETTE.snow, M.Snow, TRIM)
	cylY(m, "NestRing", cf, 1.6, 3.6, CFrame.new(0, ct + 1.3, 0), PALETTE.iron, M.Metal, TRIM)
	ball(m, "Truck", cf, 0.9, CFrame.new(0, h + 0.3, 0), PALETTE.brass, M.Metal, TRIM)

	-- Rigging: two shrouds off the crosstree tips, one stay off the head.
	local runs = {
		{ Vector3.new(-4, ct, 0), Vector3.new(-8, 0, 3) },
		{ Vector3.new(4, ct, 0), Vector3.new(8, 0, 3) },
		{ Vector3.new(0, h - 0.5, 0), Vector3.new(0, 0, 9) },
	}
	for i, r in ipairs(runs) do
		spanCyl(m, "Rigging" .. i, cf:PointToWorldSpace(r[1]), cf:PointToWorldSpace(r[2]), 0.16, ROPE, M.Fabric, TRIM)
	end

	-- The pennant froze mid-flutter.
	lp(m, "Pennant", cf, Vector3.new(2.6, 1.0, 0.1), CFrame.new(1.9, h - 1.2, 0) * CFrame.Angles(0, 0.25, 0.18),
		PALETTE.velvet, M.Fabric, TRIM)
	frostSlab(m, "PennantFrost", cf, Vector3.new(2.2, 0.12, 0.3), CFrame.new(1.9, h - 0.6, 0) * CFrame.Angles(0, 0.25, 0.18))

	return m
end

--[[
	anchor -- a ship's anchor standing on its crown: shank, ring, stock,
	two arms with fluke wedges, and six chain links running up and away from
	the ring. scale 1 is an eight-stud shank. Only the shank collides.
	PART COST: 14 (shank, ring, stock, crown, 2 arms, 2 flukes, 6 links).
]]
function WreckProps.anchor(parent: Instance, cf: CFrame, scale: number): Model
	local m = model(parent, "Anchor")
	local s = scale or 1

	cylY(m, "Shank", cf, 8 * s, 0.8 * s, CFrame.new(0, 4 * s, 0), PALETTE.iron, M.Metal, SOLID)
	cylZ(m, "Ring", cf, 0.4 * s, 2.0 * s, CFrame.new(0, 8.6 * s, 0), IRON_DARK, M.Metal, TRIM)
	lp(m, "Stock", cf, Vector3.new(6 * s, 0.7 * s, 0.7 * s), CFrame.new(0, 7.2 * s, 0), PALETTE.rust, M.Metal, TRIM)
	ball(m, "Crown", cf, 1.6 * s, CFrame.new(0, 0.7 * s, 0), PALETTE.iron, M.Metal, TRIM)

	-- Arms run out along +-Z from the crown and rise; the flukes cap them.
	for _, sgn in ipairs({ 1, -1 }) do
		local tilt = CFrame.new(0, 0.7 * s, 0) * CFrame.Angles(-sgn * 0.5, 0, 0)
		lp(m, "Arm", cf, Vector3.new(0.7 * s, 0.7 * s, 4 * s), tilt * CFrame.new(0, 0, sgn * 2 * s),
			PALETTE.iron, M.Metal, TRIM)
		wedge(m, "Fluke", Vector3.new(0.6 * s, 1.5 * s, 2.2 * s),
			cf * tilt * CFrame.new(0, 0.55 * s, sgn * 4.1 * s) * CFrame.Angles(0, (sgn > 0) and 0 or math.pi, 0),
			PALETTE.rust, M.Metal, TRIM)
	end

	-- Chain: six links climbing away from the ring, alternating their roll.
	local dir = Vector3.new(0, 0.7, 0.7).Unit
	for i = 1, 6 do
		local pos = Vector3.new(0, 8.6 * s, 0) + dir * (i * 0.85 * s)
		local roll = (i % 2 == 0) and ROLL or CFrame.new()
		lp(m, "Link" .. i, cf, Vector3.new(0.55 * s, 0.25 * s, 1.0 * s),
			lookAlong(pos, pos + dir) * roll, IRON_DARK, M.Metal, TRIM)
	end

	return m
end

--[[
	ventilator -- a cowl vent: a hullWhite trunk, an iron foot, a ball head
	bent over to -Z with a dark mouth cylinder that reads as the opening,
	and one rust streak. The trunk collides.
	PART COST: 5.
]]
function WreckProps.ventilator(parent: Instance, cf: CFrame): Model
	local m = model(parent, "Ventilator")
	cylY(m, "Trunk", cf, 5, 1.8, CFrame.new(0, 2.5, 0), PALETTE.hullWhite, M.Metal, SOLID)
	cylY(m, "Foot", cf, 0.4, 2.4, CFrame.new(0, 0.2, 0), IRON_DARK, M.Metal, TRIM)
	ball(m, "Cowl", cf, 3.2, CFrame.new(0, 5.6, -0.3), PALETTE.hullWhite, M.Metal, TRIM)
	cylZ(m, "Mouth", cf, 1.0, 2.4, CFrame.new(0, 5.6, -1.7), PALETTE.coal, SMOOTH, TRIM)
	lp(m, "Streak", cf, Vector3.new(0.5, 2.8, 0.1), CFrame.new(0.3, 2.2, -0.96), dk(PALETTE.rust, 0.2), M.Slate, TRIM)
	return m
end

--[[
	portholeRow -- brass porthole rings along a hull side between two WORLD
	points, one every `spacing` studs starting half a spacing in. Each is a
	thin brass cylinder with a frosted glassPale disc inside, both with
	their axis along the horizontal normal of a->b, so the row reads from
	either side of the plate. Nothing collides.
	PART COST: 2 per porthole.
]]
function WreckProps.portholeRow(parent: Instance, a: Vector3, b: Vector3, spacing: number): Model
	local m = model(parent, "PortholeRow")
	local d = b - a
	local len = d.Magnitude
	local gap = math.max(2, spacing or 6)
	if len < gap then
		return m
	end
	local dir = d.Unit
	local normal = dir:Cross(Vector3.yAxis)
	if normal.Magnitude < 1e-3 then
		normal = Vector3.xAxis
	end
	normal = normal.Unit
	local n = math.floor(len / gap)
	for i = 1, n do
		local pos = a + dir * ((i - 0.5) * gap)
		local cf = lookAlong(pos, pos + normal) * YAW90
		local ring = P(m, "Ring", Vector3.new(0.3, 2.2, 2.2), cf, PALETTE.brass, M.Metal, TRIM)
		ring.Shape = Enum.PartType.Cylinder
		local glass = P(m, "Glass", Vector3.new(0.34, 1.6, 1.6), cf, PALETTE.glassPale, SMOOTH,
			{ Transparency = 0.35, Reflectance = 0.3, CastShadow = false })
		glass.Shape = Enum.PartType.Cylinder
	end
	return m
end

--[[
	bollard -- twin iron bollards on a base plate with a rope loop thrown
	over them. The base collides (it is a trip hazard by design).
	PART COST: 6.
]]
function WreckProps.bollard(parent: Instance, cf: CFrame): Model
	local m = model(parent, "Bollard")
	lp(m, "Base", cf, Vector3.new(4.4, 0.5, 2.2), CFrame.new(0, 0.25, 0), IRON_DARK, M.Metal, SOLID)
	for _, sx in ipairs({ -1.3, 1.3 }) do
		cylY(m, "Post", cf, 2.6, 1.1, CFrame.new(sx, 1.8, 0), PALETTE.iron, M.Metal, TRIM)
		cylY(m, "Cap", cf, 0.35, 1.4, CFrame.new(sx, 3.25, 0), PALETTE.rust, M.Metal, TRIM)
	end
	cylY(m, "RopeLoop", cf, 0.45, 4.2, CFrame.new(0, 1.6, 0), ROPE, M.Fabric, TRIM)
	return m
end

--[[
	ropeCoil -- a flat coil on the deck: three stacked rope discs, a dark
	disc for the eye and a frost dusting. Never collides.
	PART COST: 5.
]]
function WreckProps.ropeCoil(parent: Instance, cf: CFrame): Model
	local m = model(parent, "RopeCoil")
	local dias = { 3.4, 3.2, 3.0 }
	for i, d in ipairs(dias) do
		cylY(m, "Turn" .. i, cf, 0.45, d, CFrame.new(0, 0.225 + (i - 1) * 0.45, 0) * CFrame.Angles(0, i * 0.4, 0),
			(i % 2 == 0) and dk(ROPE, 0.08) or ROPE, M.Fabric, TRIM)
	end
	cylY(m, "Eye", cf, 0.1, 1.1, CFrame.new(0, 1.4, 0), PALETTE.timberDark, M.Fabric, TRIM)
	frostSlab(m, "Frost", cf, Vector3.new(2.2, 0.12, 2.2), CFrame.new(0.4, 1.42, -0.3))
	return m
end

--[[
	deckCrateStack -- three to five crates stacked and leaning, one barrel,
	every top frost-dusted. Crates and the barrel collide (deck cargo is
	climbable). The seed decides the count, the sizes and the lean.
	PART COST: <= 13 (5 crates x 2 + barrel 3).
]]
function WreckProps.deckCrateStack(parent: Instance, cf: CFrame, seed: number?): Model
	local m = model(parent, "DeckCrateStack")
	local rng = Random.new(seed or 1)
	local n = rng:NextInteger(3, 5)

	local s1 = rng:NextNumber(2.8, 3.4)
	local s2 = rng:NextNumber(2.4, 3.0)
	local slots = {
		CFrame.new(-1.3, 0, 0.4) * CFrame.Angles(0, rng:NextNumber(-0.15, 0.15), 0),
		CFrame.new(2.2, 0, -0.7) * CFrame.Angles(0, rng:NextNumber(-0.2, 0.2), 0),
		CFrame.new(-1.3, s1 * 0.85, 0.4) * CFrame.Angles(0, rng:NextNumber(-0.35, 0.35), 0),
		CFrame.new(-1.6, 0, -3.2) * CFrame.Angles(0, rng:NextNumber(-0.3, 0.3), 0),
		CFrame.new(2.2, s2 * 0.85, -0.7) * CFrame.Angles(0, rng:NextNumber(-0.3, 0.3), 0),
	}
	local sizes = { s1, s2, s1 * 0.8, rng:NextNumber(1.8, 2.3), s2 * 0.75 }
	for i = 1, n do
		crate(m, cf, slots[i], sizes[i])
	end

	WreckProps.barrel(m, cf * CFrame.new(3.4, 0, 2.6) * CFrame.Angles(0, rng:NextNumber(0, 1), 0))
	return m
end

---------------------------------------------------------------------------
-- INTERIOR
---------------------------------------------------------------------------

--[[
	bunkBed -- a two-tier iron bunk, 6.5 long along X and 3 deep, the open
	side toward -Z. Two mattresses (they collide: players climb bunks), a
	frozen velvet blanket hanging off the top tier, a pillow and frost on
	the lower mattress.
	PART COST: 12 (4 posts, 2 rails, 2 mattresses, blanket 2, pillow, frost).
]]
function WreckProps.bunkBed(parent: Instance, cf: CFrame): Model
	local m = model(parent, "BunkBed")
	for _, sx in ipairs({ -3.1, 3.1 }) do
		for _, sz in ipairs({ -1.4, 1.4 }) do
			lp(m, "Post", cf, Vector3.new(0.35, 6, 0.35), CFrame.new(sx, 3, sz), PALETTE.iron, M.Metal, TRIM)
		end
	end
	for tier, y in ipairs({ 1.4, 4.2 }) do
		lp(m, "Rail" .. tier, cf, Vector3.new(6.4, 0.25, 3.0), CFrame.new(0, y - 0.35, 0), IRON_DARK, M.Metal, TRIM)
		lp(m, "Mattress" .. tier, cf, Vector3.new(6.2, 0.5, 2.8), CFrame.new(0, y, 0),
			dk(PALETTE.hullWhite, 0.15), M.Fabric, SOLID)
	end
	-- The blanket lies across the top mattress and hangs off the open side.
	lp(m, "Blanket", cf, Vector3.new(2.6, 0.2, 3.0), CFrame.new(0.9, 4.55, 0), PALETTE.velvet, M.Fabric, TRIM)
	lp(m, "BlanketFall", cf, Vector3.new(2.6, 2.2, 0.2), CFrame.new(0.9, 3.4, -1.55), PALETTE.velvet, M.Fabric, TRIM)
	lp(m, "Pillow", cf, Vector3.new(1.4, 0.4, 2.2), CFrame.new(-2.3, 1.85, 0), lt(PALETTE.hullWhite, 0.1), M.Fabric, TRIM)
	frostSlab(m, "Frost", cf, Vector3.new(3.6, 0.12, 2.4), CFrame.new(0.9, 1.71, 0))
	return m
end

--[[
	bunkRow -- `count` bunk beds (capped at six) in a row along local X,
	every six studs, centred on cf. Calls bunkBed.
	PART COST: 12 per bunk.
]]
function WreckProps.bunkRow(parent: Instance, cf: CFrame, count: number): Model
	local m = model(parent, "BunkRow")
	local n = math.clamp(math.floor(count or 1), 1, 6)
	for i = 1, n do
		WreckProps.bunkBed(m, cf * CFrame.new((i - (n + 1) * 0.5) * 6, 0, 0))
	end
	return m
end

--[[
	diningTable -- the saloon table. A long timber top on two trestle
	ends with a frost slab across it, a chair every four studs along both
	sides (capped at eight chairs total), and a frozen place setting (plate
	and cup) in front of every chair. Top and trestles collide; chairs'
	seats collide; settings do not.
	PART COST: <= 52 (4 table + 8 chairs x 4 + 8 settings x 2).
]]
function WreckProps.diningTable(parent: Instance, cf: CFrame, length: number): Model
	local m = model(parent, "DiningTable")
	local L = math.max(6, length or 12)

	lp(m, "Top", cf, Vector3.new(L, 0.4, 5), CFrame.new(0, 2.9, 0), PALETTE.timber, M.Wood, SOLID)
	for _, sx in ipairs({ -(L * 0.5 - 1), L * 0.5 - 1 }) do
		lp(m, "Trestle", cf, Vector3.new(0.6, 2.7, 4), CFrame.new(sx, 1.35, 0), PALETTE.timberDark, M.Wood, SOLID)
	end
	frostSlab(m, "TopFrost", cf, Vector3.new(L - 0.6, 0.12, 4.4), CFrame.new(0, 3.16, 0))

	local perSide = math.min(4, math.floor(L / 4))
	local span = (perSide - 1) * 4
	for side = 1, 2 do
		local sz = (side == 1) and 3.9 or -3.9
		-- a chair's -Z faces the table: the +Z side needs no turn, the -Z
		-- side turns about.
		local yaw = (side == 1) and 0 or math.pi
		for i = 1, perSide do
			local sx = -span * 0.5 + (i - 1) * 4
			chair(m, cf, CFrame.new(sx, 0, sz) * CFrame.Angles(0, yaw, 0))
			-- the place setting sits on the table edge in front of the chair
			local pz = (side == 1) and 1.6 or -1.6
			cylY(m, "Plate", cf, 0.1, 1.3, CFrame.new(sx, 3.27, pz), PALETTE.glassPale, SMOOTH, TRIM)
			cylY(m, "Cup", cf, 0.7, 0.6, CFrame.new(sx + 0.9, 3.57, pz + ((side == 1) and 0.3 or -0.3)),
				PALETTE.glassPale, SMOOTH, TRIM)
		end
	end
	return m
end

--[[
	chandelier -- hangs DOWN from cf, which is the CEILING anchor point (the
	one builder in this kit whose y = 0 is not the ground). A chain, a
	brass collar and hub, eight arms, each ending in a Neon lampWarm drop
	with two Neon iceGlow crystal drops under it, and a finial. ONE
	PointLight on the hub if `lit` -- Range 32, Brightness 1.5 -- because
	eight Range-32 volumes overlapping in a sealed room is exactly the
	expensive case the Ashfall pools documented. Nothing collides.
	PART COST: 36 (chain, collar, hub, finial, 8 arms, 8 lamps, 16 crystals)
	+ 1 light if lit.
]]
function WreckProps.chandelier(parent: Instance, cf: CFrame, scale: number, lit: boolean?): Model
	local m = model(parent, "Chandelier")
	local s = scale or 1

	cylY(m, "Chain", cf, 4 * s, 0.3 * s, CFrame.new(0, -2 * s, 0), IRON_DARK, M.Metal, TRIM)
	cylY(m, "Collar", cf, 0.5 * s, 3 * s, CFrame.new(0, -4.3 * s, 0), PALETTE.brass, M.Metal, TRIM)
	local hub = ball(m, "Hub", cf, 1.6 * s, CFrame.new(0, -4.7 * s, 0), PALETTE.brass, M.Metal, TRIM)
	ball(m, "Finial", cf, 0.7 * s, CFrame.new(0, -6.2 * s, 0), PALETTE.brass, M.Metal, TRIM)

	for i = 1, 8 do
		local a = (i - 1) * (math.pi * 0.25)
		local spin = CFrame.Angles(0, a, 0)
		lp(m, "Arm", cf, Vector3.new(2.4 * s, 0.25 * s, 0.25 * s), spin * CFrame.new(1.8 * s, -5 * s, 0),
			PALETTE.brass, M.Metal, TRIM)
		neon(m, "Lamp", cf, Vector3.new(0.6 * s, 0.6 * s, 0.6 * s), spin * CFrame.new(2.9 * s, -4.7 * s, 0), PALETTE.lampWarm)
		for _, sz in ipairs({ -0.35, 0.35 }) do
			neon(m, "Crystal", cf, Vector3.new(0.18 * s, 0.7 * s, 0.18 * s), spin * CFrame.new(2.4 * s, -5.7 * s, sz * s), PALETTE.iceGlow)
		end
	end

	if lit then
		light(hub, PALETTE.lampWarm, 32, 1.5)
	end
	return m
end

--[[
	boiler -- a riveted horizontal boiler on two saddles: the body is a big
	iron cylinder along X, rusted end caps, a coal-black firebox door on
	the -X end with a faint Neon ember slit under it (no light: the slit is
	a glint, not a source), two brass gauges with frosted dials on the
	front face, a stack pipe with a flange rising off the top, a row of
	rivet studs along the front seam and a frost slab on the crown. The body
	and saddles collide.
	PART COST: 23.
]]
function WreckProps.boiler(parent: Instance, cf: CFrame, scale: number): Model
	local m = model(parent, "Boiler")
	local s = scale or 1

	cylX(m, "Body", cf, 14 * s, 7 * s, CFrame.new(0, 4.5 * s, 0), PALETTE.iron, M.Metal, SOLID)
	for _, sx in ipairs({ -4.5, 4.5 }) do
		lp(m, "Saddle", cf, Vector3.new(2 * s, 1.6 * s, 6 * s), CFrame.new(sx * s, 0.8 * s, 0), IRON_DARK, M.Metal, SOLID)
	end
	for _, sx in ipairs({ -7.1, 7.1 }) do
		cylX(m, "EndCap", cf, 0.6 * s, 7.4 * s, CFrame.new(sx * s, 4.5 * s, 0), PALETTE.rust, M.Metal, TRIM)
	end

	-- Firebox on the -X end.
	lp(m, "FireboxDoor", cf, Vector3.new(0.3 * s, 2.4 * s, 2.4 * s), CFrame.new(-7.55 * s, 3.4 * s, 0), PALETTE.coal, M.Metal, TRIM)
	lp(m, "DoorHandle", cf, Vector3.new(0.2 * s, 0.2 * s, 0.9 * s), CFrame.new(-7.8 * s, 3.4 * s, 0.6 * s), PALETTE.brass, M.Metal, TRIM)
	neon(m, "EmberSlit", cf, Vector3.new(0.12 * s, 0.22 * s, 1.6 * s), CFrame.new(-7.75 * s, 2.5 * s, 0), dk(PALETTE.lampWarm, 0.35))

	-- Gauges on the front (-Z) face.
	for _, sx in ipairs({ -2, 2 }) do
		cylZ(m, "Gauge", cf, 0.3 * s, 1.1 * s, CFrame.new(sx * s, 4.5 * s, -3.65 * s), PALETTE.brass, M.Metal, TRIM)
		iceGlass(m, "Dial", cf, Vector3.new(0.12 * s, 0.9 * s, 0.9 * s), CFrame.new(sx * s, 4.5 * s, -3.86 * s) * YAW90, 0.3, 0.3).Shape = Enum.PartType.Cylinder
	end

	-- Stack off the crown, with its flange.
	cylY(m, "Stack", cf, 10 * s, 1.6 * s, CFrame.new(3 * s, 12.6 * s, 0), PALETTE.iron, M.Metal, TRIM)
	cylY(m, "StackFlange", cf, 0.4 * s, 2.2 * s, CFrame.new(3 * s, 8.1 * s, 0), PALETTE.rust, M.Metal, TRIM)

	-- Rivets along the front-top seam (45 degrees round the shell).
	local ry, rz = 4.5 * s + 3.5 * s * 0.707, -3.5 * s * 0.707
	for i = 0, 7 do
		ball(m, "Rivet", cf, 0.4 * s, CFrame.new((-6 + i * 1.7) * s, ry, rz), IRON_DARK, M.Metal, TRIM)
	end

	frostSlab(m, "CrownFrost", cf, Vector3.new(11 * s, 0.14, 2.6 * s), CFrame.new(-1 * s, 8.05 * s, 0))
	return m
end

--[[
	pipeRun -- an iron pipe from WORLD point a to WORLD point b, diameter
	dia, a flange ring at each end and a frost strip along the top. Never
	collides (pipes cross the hold at head height and a player must pass
	under them).
	PART COST: 4.
]]
function WreckProps.pipeRun(parent: Instance, a: Vector3, b: Vector3, dia: number): Model
	local m = model(parent, "PipeRun")
	local d = math.max(0.4, dia or 1)
	local v = b - a
	if v.Magnitude < 0.05 then
		return m
	end
	local dir = v.Unit
	spanCyl(m, "Pipe", a, b, d, PALETTE.iron, M.Metal, TRIM)
	spanCyl(m, "FlangeA", a, a + dir * 0.4, d * 1.5, PALETTE.rust, M.Metal, TRIM)
	spanCyl(m, "FlangeB", b - dir * 0.4, b, d * 1.5, PALETTE.rust, M.Metal, TRIM)
	local up = Vector3.new(0, d * 0.5, 0)
	spanBox(m, "Frost", a + up + dir * 0.6, b + up - dir * 0.6, d * 0.7, 0.12, PALETTE.frost, SMOOTH,
		{ Transparency = 0.45, Reflectance = 0.25, CastShadow = false })
	return m
end

--[[
	cargoStack -- a hold cargo pile: four crates in the bottom tier, two on
	top, three of them frost-capped, two barrels alongside and a rope net
	draped over the pile at an angle with its own rime. Crates and barrels
	collide; the net does not.
	PART COST: 17 (6 crates + 3 frost + 2 barrels x 3 + net + net frost).
]]
function WreckProps.cargoStack(parent: Instance, cf: CFrame, seed: number?): Model
	local m = model(parent, "CargoStack")
	local rng = Random.new(seed or 1)
	local function j(r: number): number
		return rng:NextNumber(-r, r)
	end

	local s = 3.4
	local lift = s * 0.85
	-- bottom tier (bare crates; the net covers them) and top tier (frosted)
	local low = {
		CFrame.new(-1.8, 0, -1.8), CFrame.new(1.8, 0, -1.8),
		CFrame.new(-1.8, 0, 1.8), CFrame.new(1.8, 0, 1.8),
	}
	for i, off in ipairs(low) do
		local o = off * CFrame.Angles(0, j(0.12), 0)
		if i == 4 then
			crate(m, cf, o, s)                      -- the one exposed corner gets frost
		else
			lp(m, "Crate", cf, Vector3.new(s, lift, s), o * CFrame.new(0, lift * 0.5, 0), PALETTE.timber, M.Wood, SOLID)
		end
	end
	crate(m, cf, CFrame.new(-1.7, lift, 0.1) * CFrame.Angles(0, j(0.3), 0), s * 0.92)
	crate(m, cf, CFrame.new(1.9, lift, 0.2) * CFrame.Angles(0, j(0.3), 0), s * 0.8)

	WreckProps.barrel(m, cf * CFrame.new(4.8, 0, -1.0) * CFrame.Angles(0, j(1), 0))
	WreckProps.barrel(m, cf * CFrame.new(4.5, 0, 2.3) * CFrame.Angles(0, j(1), 0))

	-- The net: one Fabric slab pitched over the pile.
	local netCF = CFrame.new(0.4, lift * 2 + 0.9, 0.3) * CFrame.Angles(0.3 + j(0.08), 0.15, -0.22 + j(0.06))
	lp(m, "Net", cf, Vector3.new(7.6, 0.15, 6.6), netCF, ROPE, M.Fabric, { Transparency = 0.3, CastShadow = false })
	frostSlab(m, "NetFrost", cf, Vector3.new(6.4, 0.12, 5.4), netCF * CFrame.new(0, 0.14, 0))
	return m
end

--[[
	pianoFrozen -- a grand piano in the saloon, keys toward -Z. A two-box
	body (front and tail), three legs, the keys strip with eight black
	stubs, the fallboard, a music stand, the lid propped open on its stick
	with a frost slab lying across it, the pedals and a bench. Body boxes
	and the bench seat collide.
	PART COST: 23.
]]
function WreckProps.pianoFrozen(parent: Instance, cf: CFrame): Model
	local m = model(parent, "PianoFrozen")
	local BLACK_LACQUER = dk(PALETTE.coal, 0.2)

	lp(m, "BodyFront", cf, Vector3.new(7, 1.3, 3.0), CFrame.new(0, 2.65, -0.5), BLACK_LACQUER, SMOOTH, SOLID)
	lp(m, "BodyTail", cf, Vector3.new(4.6, 1.3, 3.4), CFrame.new(-1.2, 2.65, 2.7), BLACK_LACQUER, SMOOTH, SOLID)
	for _, leg in ipairs({ Vector3.new(-3.0, 1, -1.4), Vector3.new(3.0, 1, -1.4), Vector3.new(-2.8, 1, 3.8) }) do
		cylY(m, "Leg", cf, 2, 0.5, CFrame.new(leg), BLACK_LACQUER, SMOOTH, TRIM)
	end

	-- Keys.
	lp(m, "Keys", cf, Vector3.new(5.8, 0.3, 1.1), CFrame.new(0, 3.4, -1.55), lt(PALETTE.hullWhite, 0.25), SMOOTH, TRIM)
	for i = 0, 7 do
		lp(m, "Sharp", cf, Vector3.new(0.28, 0.16, 0.6), CFrame.new(-2.45 + i * 0.7, 3.6, -1.75), PALETTE.coal, SMOOTH, TRIM)
	end
	lp(m, "Fallboard", cf, Vector3.new(6.2, 0.5, 0.6), CFrame.new(0, 3.5, -0.85), BLACK_LACQUER, SMOOTH, TRIM)
	lp(m, "MusicStand", cf, Vector3.new(2.2, 1.3, 0.15), CFrame.new(0, 4.2, 0), BLACK_LACQUER, SMOOTH, TRIM)

	-- Lid: hinged along the -X edge, lifted 0.62 rad, the frost lying on it.
	local hinge = CFrame.new(-3.5, 3.3, 1.9) * CFrame.Angles(0, 0, 0.62)
	lp(m, "Lid", cf, Vector3.new(6.6, 0.2, 5.0), hinge * CFrame.new(3.3, 0.1, 0), BLACK_LACQUER, SMOOTH, TRIM)
	frostSlab(m, "LidFrost", cf, Vector3.new(5.8, 0.12, 4.2), hinge * CFrame.new(3.3, 0.27, 0))
	cylY(m, "LidStick", cf, 2.9, 0.2, CFrame.new(0.57, 4.75, 2.6), PALETTE.brass, M.Metal, TRIM)

	lp(m, "Pedals", cf, Vector3.new(1.4, 0.2, 0.5), CFrame.new(0, 0.35, -1.6), PALETTE.brass, M.Metal, TRIM)

	-- Bench.
	lp(m, "BenchSeat", cf, Vector3.new(3.2, 0.3, 1.3), CFrame.new(0, 1.85, -3.4), BLACK_LACQUER, SMOOTH, SOLID_TRIM)
	for _, sx in ipairs({ -1.3, 1.3 }) do
		lp(m, "BenchLeg", cf, Vector3.new(0.3, 1.7, 1.1), CFrame.new(sx, 0.85, -3.4), BLACK_LACQUER, SMOOTH, TRIM)
	end
	return m
end

--[[
	staircase -- a straight stair that rises along +Y as it runs toward
	local -Z, starting at cf's ground. Risers are 1 high and treads 1.2
	deep (as many as `height` needs), every tread a solid timber block
	(CanCollide TRUE), plus an invisible ramp collider lying along the
	nosings so a humanoid walks it smoothly instead of stuttering up the
	steps. Brass handrail with posts every third tread each side. Walkable
	by construction: 1-stud risers are under the humanoid step height.
	PART COST: ceil(height) treads + 1 ramp + posts (about 2 * n/3) + 2 rails.
]]
function WreckProps.staircase(parent: Instance, cf: CFrame, height: number, width: number): Model
	local m = model(parent, "Staircase")
	local RISER, TREAD = 1.0, 1.2
	local w = math.max(3, width or 6)
	local n = math.max(1, math.ceil((height or 4) / RISER))
	local h = n * RISER
	local run = n * TREAD

	for i = 1, n do
		lp(m, "Tread", cf, Vector3.new(w, RISER, TREAD), CFrame.new(0, i - RISER * 0.5, -(i - 0.5) * TREAD),
			(i % 2 == 0) and PALETTE.timber or dk(PALETTE.timber, 0.08), M.WoodPlanks, SOLID)
	end

	-- Ramp collider along the nosings: rotate about X so the box's -Z end
	-- climbs to (h, -run). CanQuery off so raycasts see the treads, not it.
	local L = math.sqrt(h * h + run * run)
	local phi = math.atan2(h, run)
	lp(m, "RampCollider", cf, Vector3.new(w, 0.2, L),
		CFrame.new(0, h * 0.5 + 0.05, -run * 0.5) * CFrame.Angles(phi, 0, 0),
		PALETTE.timber, SMOOTH, { Transparency = 1, CanCollide = true, CanQuery = false, CastShadow = false })

	-- Handrails.
	for _, sx in ipairs({ -(w * 0.5 - 0.3), w * 0.5 - 0.3 }) do
		local first, last = nil, nil
		local i = 1
		while i <= n do
			local top = Vector3.new(sx, i + 3.0, -(i - 0.5) * TREAD)
			lp(m, "RailPost", cf, Vector3.new(0.22, 3.0, 0.22), CFrame.new(sx, i + 1.5, -(i - 0.5) * TREAD),
				PALETTE.brass, M.Metal, TRIM)
			first = first or top
			last = top
			if i == n then
				break
			end
			i = math.min(i + 3, n)
		end
		if first and last then
			spanBox(m, "Handrail", cf:PointToWorldSpace(first), cf:PointToWorldSpace(last), 0.3, 0.3,
				PALETTE.brass, M.Metal, TRIM)
		end
	end
	return m
end

--[[
	wallLamp -- a brass sconce. cf is the MOUNTING POINT on the wall, facing
	out along -Z; the lamp sits around it (the backplate is centred on cf,
	the pane a stud above and a stud and a half out). A Neon lampWarm pane
	inside a frosted SmoothPlastic cage (never Glass: the Neon behind it
	must show), a bracket arm, a cup and a cap. PointLight on the pane if
	`lit`: Range 20, Brightness 1.1.
	PART COST: 6 + 1 light if lit.
]]
function WreckProps.wallLamp(parent: Instance, cf: CFrame, lit: boolean?): Model
	local m = model(parent, "WallLamp")
	lp(m, "Backplate", cf, Vector3.new(1.2, 1.8, 0.2), CFrame.new(0, 0, -0.1), PALETTE.brass, M.Metal, TRIM)
	lp(m, "Arm", cf, Vector3.new(0.4, 0.4, 1.2), CFrame.new(0, -0.2, -0.7), PALETTE.brass, M.Metal, TRIM)
	cylY(m, "Cup", cf, 0.3, 0.9, CFrame.new(0, 0.05, -1.3), PALETTE.brass, M.Metal, TRIM)
	local pane = neon(m, "Pane", cf, Vector3.new(0.8, 1.2, 0.8), CFrame.new(0, 0.85, -1.3), PALETTE.lampWarm)
	iceGlass(m, "Cage", cf, Vector3.new(1.1, 1.5, 1.1), CFrame.new(0, 0.85, -1.3), 0.5, 0.3)
	lp(m, "Cap", cf, Vector3.new(1.3, 0.25, 1.3), CFrame.new(0, 1.7, -1.3), PALETTE.brass, M.Metal, TRIM)
	if lit then
		light(pane, PALETTE.lampWarm, 20, 1.1)
	end
	return m
end

--[[
	icicleCurtain -- icicles hanging under a beam between two WORLD points,
	one every ~1.4 studs, lengths 0.8 to 3.2, seeded from the points so a
	rebuild hangs the same curtain. SmoothPlastic iceGlow at Transparency
	0.25 with Reflectance 0.3 -- not Neon (they would not be translucent)
	and not Glass (they would hide every frost slab behind them). Never
	collides.
	PART COST: floor(len / 1.4) + 1.
]]
function WreckProps.icicleCurtain(parent: Instance, a: Vector3, b: Vector3): Model
	local m = model(parent, "IcicleCurtain")
	local v = b - a
	local len = v.Magnitude
	if len < 0.05 then
		return m
	end
	local dir = v.Unit
	local rng = Random.new(hashSeed(a, b))
	local n = math.max(1, math.floor(len / 1.4))
	local step = len / n
	for i = 0, n do
		local t = math.clamp(i * step + rng:NextNumber(-0.3, 0.3), 0, len)
		local L = rng:NextNumber(0.8, 3.2)
		local w = 0.22 + L * 0.06
		local pos = a + dir * t
		local ic = P(m, "Icicle", Vector3.new(L, w, w), CFrame.new(pos - Vector3.new(0, L * 0.5, 0)) * ROLL,
			PALETTE.iceGlow, SMOOTH, { Transparency = 0.25, Reflectance = 0.3, CastShadow = false })
		ic.Shape = Enum.PartType.Cylinder
	end
	return m
end

--[[
	brokenBeam -- a collapsed beam from WORLD point a to WORLD point b: a
	timber box with an iron strap around its middle, a splintered wedge
	past each end (the wedge's tall face against the beam, its slope
	falling away) and frost along the top. The beam collides: it is a
	thing to climb over in the hold.
	PART COST: 5.
]]
function WreckProps.brokenBeam(parent: Instance, a: Vector3, b: Vector3): Model
	local m = model(parent, "BrokenBeam")
	local v = b - a
	local len = v.Magnitude
	if len < 0.05 then
		return m
	end
	local dir = v.Unit
	local mid = (a + b) * 0.5
	spanBox(m, "Beam", a, b, 1.6, 1.4, PALETTE.timberDark, M.Wood, SOLID)
	spanBox(m, "Strap", mid - dir * (len * 0.15), mid + dir * (len * 0.15), 1.8, 0.2, IRON_DARK, M.Metal, TRIM)
	wedge(m, "SplinterA", Vector3.new(1.6, 1.4, 1.6), lookAlong(a - dir * 0.8, a - dir * 2), PALETTE.timber, M.Wood, TRIM)
	wedge(m, "SplinterB", Vector3.new(1.6, 1.4, 1.6), lookAlong(b + dir * 0.8, b + dir * 2), PALETTE.timber, M.Wood, TRIM)
	-- The frost rides on whichever face is up; the beam's local up is the
	-- lookAlong frame's Y, which is world-up for any non-vertical run.
	local frame = lookAlong(mid, b)
	local up = frame.UpVector * 0.76
	spanBox(m, "Frost", a + dir * (len * 0.05) + up, b - dir * (len * 0.05) + up, 1.2, 0.12, PALETTE.frost, SMOOTH,
		{ Transparency = 0.45, Reflectance = 0.25, CastShadow = false })
	return m
end

--[[
	kitchenRange -- the galley stove, front toward -Z: a coal-black range
	body with an iron top plate, four hob rings, the oven door and its
	brass handle, a backsplash, a brass rail above with two pots and a pan
	hanging off it, frost on the plate and a small drift in the corner
	against the backsplash. The body collides.
	PART COST: 18.
]]
function WreckProps.kitchenRange(parent: Instance, cf: CFrame): Model
	local m = model(parent, "KitchenRange")
	lp(m, "Body", cf, Vector3.new(6, 3, 2.6), CFrame.new(0, 1.5, 0), PALETTE.coal, M.Metal, SOLID)
	lp(m, "TopPlate", cf, Vector3.new(6.2, 0.2, 2.8), CFrame.new(0, 3.1, 0), PALETTE.iron, M.Metal, TRIM)
	for _, hx in ipairs({ -1.6, 1.6 }) do
		for _, hz in ipairs({ -0.6, 0.6 }) do
			cylY(m, "Hob", cf, 0.12, 1.1, CFrame.new(hx, 3.26, hz), IRON_DARK, M.Metal, TRIM)
		end
	end
	lp(m, "OvenDoor", cf, Vector3.new(2.6, 1.8, 0.15), CFrame.new(0, 1.4, -1.38), dk(PALETTE.iron, 0.2), M.Metal, TRIM)
	lp(m, "OvenHandle", cf, Vector3.new(2.0, 0.15, 0.15), CFrame.new(0, 2.05, -1.52), PALETTE.brass, M.Metal, TRIM)
	lp(m, "Backsplash", cf, Vector3.new(6, 2.0, 0.3), CFrame.new(0, 4.1, 1.15), PALETTE.iron, M.Metal, TRIM)

	-- Rail above the range and what hangs from it.
	cylX(m, "Rail", cf, 5.6, 0.2, CFrame.new(0, 5.6, -0.4), PALETTE.brass, M.Metal, TRIM)
	for _, px in ipairs({ -1.8, 1.8 }) do
		cylY(m, "Pot", cf, 1.2, 1.4, CFrame.new(px, 4.7, -0.4), IRON_DARK, M.Metal, TRIM)
		cylY(m, "PotHook", cf, 0.5, 0.12, CFrame.new(px, 5.35, -0.4), PALETTE.brass, M.Metal, TRIM)
	end
	cylZ(m, "Pan", cf, 0.3, 1.6, CFrame.new(0, 4.6, -0.4), IRON_DARK, M.Metal, TRIM)
	lp(m, "PanHandle", cf, Vector3.new(0.18, 0.8, 0.14), CFrame.new(0, 5.2, -0.4), IRON_DARK, M.Metal, TRIM)

	frostSlab(m, "PlateFrost", cf, Vector3.new(5.4, 0.12, 2.2), CFrame.new(0, 3.26, 0.1))
	ball(m, "Drift", cf, 1.4, CFrame.new(-2.4, 3.55, 0.7), PALETTE.snow, M.Snow, TRIM)
	return m
end

--[[
	steamerTrunk -- a domed-lid travel trunk, half open, frost inside.
	Leather-toned body with two dark straps, four brass corners and a lock
	plate; the lid (a slab plus a half-cylinder dome) is hinged along the
	back (+Z) edge and thrown open past vertical; a frost slab and a snow
	drift lie in the open top. The body collides.
	PART COST: 12.
]]
function WreckProps.steamerTrunk(parent: Instance, cf: CFrame): Model
	local m = model(parent, "SteamerTrunk")
	local LEATHER = dk(PALETTE.timber, 0.28)

	lp(m, "Body", cf, Vector3.new(4.4, 2.0, 2.6), CFrame.new(0, 1.0, 0), LEATHER, M.Fabric, SOLID)
	for _, sx in ipairs({ -1.2, 1.2 }) do
		lp(m, "Strap", cf, Vector3.new(0.5, 2.06, 2.66), CFrame.new(sx, 1.0, 0), PALETTE.timberDark, M.Fabric, TRIM)
	end
	for _, sx in ipairs({ -2.2, 2.2 }) do
		for _, sy in ipairs({ 0.3, 1.7 }) do
			lp(m, "Corner", cf, Vector3.new(0.5, 0.5, 0.5), CFrame.new(sx, sy, -1.3), PALETTE.brass, M.Metal, TRIM)
		end
	end
	lp(m, "Lock", cf, Vector3.new(0.8, 0.6, 0.12), CFrame.new(0, 1.6, -1.36), PALETTE.brass, M.Metal, TRIM)

	-- Lid on its back hinge, opened 1.75 rad (past vertical, leaning back).
	local hinge = CFrame.new(0, 2.0, 1.3) * CFrame.Angles(1.75, 0, 0)
	lp(m, "Lid", cf, Vector3.new(4.4, 0.6, 2.6), hinge * CFrame.new(0, 0.3, -1.3), LEATHER, M.Fabric, TRIM)
	cylX(m, "LidDome", cf, 4.2, 2.0, hinge * CFrame.new(0, 0.7, -1.3), LEATHER, M.Fabric, TRIM)

	frostSlab(m, "InsideFrost", cf, Vector3.new(4.0, 0.12, 2.2), CFrame.new(0, 2.06, 0))
	ball(m, "Drift", cf, 1.6, CFrame.new(0.8, 2.2, 0.2), PALETTE.snow, M.Snow, TRIM)
	return m
end

--[[
	portholeWindow -- for interior walls. cf is the window CENTRE on the
	wall, facing into the room along -Z. A brass ring with a darker outer
	rim, a frosted glassPale disc, and BEHIND it (toward the wall, +Z) a
	pale iceGlow Neon disc so it reads as daylight through ice. The glass
	is SmoothPlastic so the Neon shows through. Nothing collides.
	PART COST: 4.
]]
function WreckProps.portholeWindow(parent: Instance, cf: CFrame): Model
	local m = model(parent, "PortholeWindow")
	cylZ(m, "Rim", cf, 0.2, 3.1, CFrame.new(0, 0, 0.15), dk(PALETTE.brass, 0.3), M.Metal, TRIM)
	cylZ(m, "Ring", cf, 0.5, 2.8, CFrame.new(0, 0, 0), PALETTE.brass, M.Metal, TRIM)
	iceGlass(m, "Glass", cf, Vector3.new(0.3, 2.2, 2.2), CFrame.new(0, 0, -0.05) * YAW90, 0.35, 0.3).Shape = Enum.PartType.Cylinder
	local day = neon(m, "Daylight", cf, Vector3.new(0.15, 2.1, 2.1), CFrame.new(0, 0, 0.2) * YAW90, PALETTE.iceGlow)
	day.Shape = Enum.PartType.Cylinder
	return m
end

--[[
	shipWheel -- the wheel on its pedestal, facing -Z: base plate, pedestal,
	head, axle, hub, eight spokes (four boxes through the centre), eight
	handles at the spoke tips and eight rim segments (an octagon of short
	boxes). The pedestal collides.
	PART COST: 25.
]]
function WreckProps.shipWheel(parent: Instance, cf: CFrame): Model
	local m = model(parent, "ShipWheel")
	lp(m, "Base", cf, Vector3.new(2.4, 0.3, 2.0), CFrame.new(0, 0.15, 0.3), PALETTE.timberDark, M.Wood, SOLID_TRIM)
	lp(m, "Pedestal", cf, Vector3.new(1.2, 3.4, 1.2), CFrame.new(0, 1.7, 0.3), PALETTE.timberDark, M.Wood, SOLID)
	lp(m, "Head", cf, Vector3.new(1.4, 1.2, 1.2), CFrame.new(0, 3.9, 0.5), PALETTE.brass, M.Metal, TRIM)

	local centre = CFrame.new(0, 3.9, -0.4)
	cylZ(m, "Axle", cf, 1.6, 0.4, centre * CFrame.new(0, 0, 0.6), PALETTE.brass, M.Metal, TRIM)
	cylZ(m, "Hub", cf, 0.7, 1.0, centre, PALETTE.brass, M.Metal, TRIM)
	for i = 0, 3 do
		lp(m, "Spoke", cf, Vector3.new(0.28, 4.6, 0.28), centre * CFrame.Angles(0, 0, i * math.pi * 0.25),
			PALETTE.timber, M.Wood, TRIM)
	end
	for k = 0, 7 do
		local ang = k * math.pi * 0.25
		cylY(m, "Handle", cf, 0.9, 0.32, centre * CFrame.Angles(0, 0, ang) * CFrame.new(0, 2.75, 0),
			PALETTE.timberDark, M.Wood, TRIM)
		lp(m, "Rim", cf, Vector3.new(1.78, 0.4, 0.4), centre * CFrame.Angles(0, 0, ang + math.pi * 0.125) * CFrame.new(0, 2.15, 0),
			PALETTE.timber, M.Wood, TRIM)
	end
	return m
end

--[[
	captainDesk -- a pedestal desk facing -Z with a chart laid flat on it,
	a brass reading lamp (Neon pane, deliberately NO light: it is a glint
	in a lit cabin, not a source), a sextant standing on its arc, an
	inkwell, a frost slab along the front edge and the captain's chair
	behind it. Top and pedestals collide.
	PART COST: 15.
]]
function WreckProps.captainDesk(parent: Instance, cf: CFrame): Model
	local m = model(parent, "CaptainDesk")
	lp(m, "Top", cf, Vector3.new(6, 0.4, 3.2), CFrame.new(0, 2.7, 0), PALETTE.timber, M.Wood, SOLID)
	for _, sx in ipairs({ -2.1, 2.1 }) do
		lp(m, "Pedestal", cf, Vector3.new(1.6, 2.5, 3.0), CFrame.new(sx, 1.25, 0), PALETTE.timberDark, M.Wood, SOLID)
	end
	lp(m, "Chart", cf, Vector3.new(3.4, 0.08, 2.4), CFrame.new(0.2, 2.94, -0.1) * CFrame.Angles(0, 0.12, 0),
		lt(PALETTE.hullWhite, 0.2), SMOOTH, TRIM)

	-- Lamp.
	cylY(m, "LampPost", cf, 1.4, 0.2, CFrame.new(-2.2, 3.6, 0.6), PALETTE.brass, M.Metal, TRIM)
	lp(m, "LampShade", cf, Vector3.new(1.2, 0.6, 1.2), CFrame.new(-2.2, 4.5, 0.6), PALETTE.brass, M.Metal, TRIM)
	neon(m, "LampPane", cf, Vector3.new(1.0, 0.2, 1.0), CFrame.new(-2.2, 4.1, 0.6), PALETTE.lampWarm)

	-- Sextant: an arc on its edge and an index arm.
	cylZ(m, "SextantArc", cf, 0.2, 1.4, CFrame.new(2.0, 3.6, -0.6), PALETTE.brass, M.Metal, TRIM)
	lp(m, "SextantArm", cf, Vector3.new(0.15, 1.2, 0.15), CFrame.new(2.0, 3.7, -0.6) * CFrame.Angles(0, 0, 0.4),
		PALETTE.brass, M.Metal, TRIM)
	cylY(m, "Inkwell", cf, 0.5, 0.5, CFrame.new(1.2, 3.15, 0.9), PALETTE.coal, SMOOTH, TRIM)

	frostSlab(m, "EdgeFrost", cf, Vector3.new(5.2, 0.12, 0.9), CFrame.new(0, 2.96, -1.1))
	chair(m, cf, CFrame.new(0, 0, 2.6))
	return m
end

return WreckProps
