--[[
	FrozenWreckBuilder  --  ServerScriptService.FrozenWreckBuilder  (ModuleScript)

	THE FROZEN WRECK. The game's fourth inner area and the room behind
	Penguin Island: the hold of the S.S. AURORA MERIDIAN, an ocean liner that
	came ashore on the island's north strand a lifetime ago and has been
	freezing solid ever since. Rebirth 40 opens her.

	THIS IS THE MAGMA CHAMBER'S ARCHITECTURE, PIECE FOR PIECE. MagmaBuilder is
	the reference inner area and this file keeps its shape on purpose, so
	that everything the rest of the game already knows about a room keeps
	being true here:

	  * one Config.ISLANDS row (id 9, chamber = true) is the rakeable field;
	  * ONE module owns BOTH ends of the door: Wreck.build() makes the room
	    and returns its SellPad (CTB_Server pushes it into sellPads, which is
	    the only sell registration there is); Wreck.buildEntrance() stands the
	    liner on the host island with the breach that is the door;
	  * the door is two ClickDetectors on two sliding leaves, gated ON THE
	    SERVER off the Rebirths attribute ProgressionServer writes, refusing
	    with "DoorLocked" (Vault_Client draws the SEALED card) and admitting
	    with the same "Cinema" fade the tomb and the shrine use;
	  * Wreck.REBIRTHS is read by FunnelConfig, Wreck.ENTRY_NAME is the root
	    Model Vault_Client repaints the hint on (DOOR_ROOTS), Wreck.returnCF
	    is where leave() lands and ReturnAt mirrors it on the instance.

	ORDER. CTB_Server requires this AFTER Island5Builder (the liner stands on
	ground that module repours every boot) and BEFORE baselineField() (the
	room's floor is poured here and the field is carved into the top of it).

	THE ROOM is a hold, not a cave: iron ribs and deck beams, porthole rows
	along both sides, a purser's office and the ship's stores at the south end
	where the breach lets you out, cabins down the east side, the boiler room
	down the west, and the grand saloon at the north end under its chandeliers,
	with the bridge on a mezzanine above it. Daylight comes in through rents
	in the deck overhead -- the ice over the wreck glows -- and that, plus the
	chandeliers, is the room's lighting. No Lighting folder, no ColorCorrection:
	the only client grade for any room is Vault_Client's, keyed on the vault.

	THE EXTERIOR is the whole liner, lying across the north shore with her bow
	on the snow, and the door is a breach torn in her south side facing the
	snowfield. WreckProps builds her fittings; the hull, the superstructure and
	the breach are built here because they are the door's own geometry.

	THE SHIP IS FICTIONAL. Her name is the AURORA MERIDIAN and no other name
	appears anywhere in this file or on any sign it letters.

	Rules inherited from every island and room before this one:
	  * Nothing collidable may stand inside the rakeable square (resetAt 1.0:
	    one blocked column is a field that never turns over). The sweep at the
	    end of build() MOVES anything that does; buildEntrance() re-checks the
	    HOST island's square the same way.
	  * Every part is Anchored; Neon stays at Transparency 0; lights are
	    PointLights with Shadows off; no Glass in front of anything transparent.
	  * Glacier and Ice are the only terrain materials here (applyLook tints
	    them for the whole place).
]]

local Wreck = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local CTB = ReplicatedStorage:WaitForChild("CTB")
local Config = require(CTB:WaitForChild("Config"))
local Net = CTB:WaitForChild("Net")
local SignKit = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("SignKit"))

local Terrain = workspace.Terrain

----------------------------------------------------------------
-- The two prop kits, both behind pcall: a missing kit makes a barer room,
-- never a missing door.
----------------------------------------------------------------
local WP = nil          -- WreckProps: the liner's fittings, inside and out
do
	local ok, mod = pcall(function()
		return require(ServerScriptService:WaitForChild("WreckProps", 20))
	end)
	if ok and type(mod) == "table" then
		WP = mod
	else
		warn("[Wreck] WreckProps did not load -- the wreck will be built bare. " .. tostring(mod))
	end
end

local IP = nil          -- Island5Props: the host island's kit, for the approach
do
	local ok, mod = pcall(function()
		return require(ServerScriptService:WaitForChild("Island5Props", 20))
	end)
	if ok and type(mod) == "table" then
		IP = mod
	else
		warn("[Wreck] Island5Props did not load -- the approach will be built bare. " .. tostring(mod))
	end
end

local propFails = 0
local function callKit(kit, kitName: string, fnName: string, ...): Model?
	if not kit then
		propFails += 1
		return nil
	end
	local fn = kit[fnName]
	if type(fn) ~= "function" then
		propFails += 1
		if propFails <= 4 then
			warn(string.format("[Wreck] %s.%s is missing", kitName, fnName))
		end
		return nil
	end
	local ok, m = pcall(fn, ...)
	if not ok then
		propFails += 1
		if propFails <= 4 then
			warn(string.format("[Wreck] %s.%s threw: %s", kitName, fnName, tostring(m)))
		end
		return nil
	end
	if typeof(m) ~= "Instance" then
		propFails += 1
		return nil
	end
	return m
end
local function wp(fnName: string, ...): Model?
	return callKit(WP, "WreckProps", fnName, ...)
end
local function ip(fnName: string, ...): Model?
	return callKit(IP, "Island5Props", fnName, ...)
end

----------------------------------------------------------------
-- The room's row and its numbers
----------------------------------------------------------------
local ISL = Config.island(9)
local CX, CZ = ISL.cx, ISL.cz          -- 3000, -3000
local GROUND = ISL.cleanY              -- 3.0, the same voxel band as every field

-- The hull: x +-170, z +-240 about the field's centre (the field is +-112).
local X0, X1 = CX - 170, CX + 170
local Z0, Z1 = CZ - 240, CZ + 240
local CEIL = GROUND + 50

-- Where you arrive: just inside the breach, looking up the hold.
local ENTRY = CFrame.lookAt(
	Vector3.new(CX, GROUND + 3.5, Z0 + 26),
	Vector3.new(CX, GROUND + 3.5, Z0 + 80))

-- The host island, for the fallback return and the field check.
local PEN = Config.island(8)
local FALLBACK_RETURN = CFrame.lookAt(
	Vector3.new(PEN.cx, 8, PEN.cz + PEN.half + 40),
	Vector3.new(PEN.cx, 8, PEN.cz + PEN.half + 90))

-- THE GATE. Read by FunnelConfig via Wreck.REBIRTHS; sent in DoorLocked.
Wreck.REBIRTHS = 40

-- Shared cinematic timings (the client fades on its own clock).
Wreck.BEAT = Config.CINEMA.beat
Wreck.FADE = Config.CINEMA.fade
Wreck.HOLD = Config.CINEMA.hold

local SND_WHOOSH = "rbxassetid://9125742262"

----------------------------------------------------------------
-- Palette: WreckProps' own, key for key, with fallbacks so the file still
-- builds when the kit is missing.
----------------------------------------------------------------
local PALETTE = {
	hullRed = Color3.fromRGB(118, 38, 32),
	hullBlack = Color3.fromRGB(28, 28, 32),
	hullWhite = Color3.fromRGB(196, 192, 178),
	rust = Color3.fromRGB(132, 72, 40),
	iron = Color3.fromRGB(72, 74, 80),
	brass = Color3.fromRGB(176, 136, 62),
	timber = Color3.fromRGB(124, 88, 56),
	timberDark = Color3.fromRGB(74, 50, 34),
	velvet = Color3.fromRGB(96, 22, 30),
	frost = Color3.fromRGB(206, 226, 240),
	ice = Color3.fromRGB(150, 196, 226),
	iceGlow = Color3.fromRGB(178, 226, 255),
	snow = Color3.fromRGB(214, 224, 232),
	glassPale = Color3.fromRGB(190, 214, 228),
	lampWarm = Color3.fromRGB(255, 196, 120),
	coal = Color3.fromRGB(24, 22, 22),
}
if WP and type(WP.PALETTE) == "table" then
	for k, v in pairs(WP.PALETTE) do
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

local IRON_DARK = dk(PALETTE.iron, 0.35)
local PLATE = Enum.Material.Metal
local RUSTY = Enum.Material.CorrodedMetal

----------------------------------------------------------------
-- Small builders
----------------------------------------------------------------
local function P(parent, name, size, cf, colour, material, extra)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = colour or PALETTE.iron
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

local function box(parent, name, x0, x1, y0, y1, z0, z1, colour, material, extra)
	local sx, sy, sz = x1 - x0, y1 - y0, z1 - z0
	if sx < 0.05 or sy < 0.05 or sz < 0.05 then
		return nil
	end
	return P(parent, name, Vector3.new(sx, sy, sz),
		CFrame.new((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5), colour, material, extra)
end

-- Decoration: never collides, never casts.
local NOHIT = { CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false }
local function trim(parent, name, size, cf, colour, material, extra)
	local e = { CanCollide = false, CastShadow = false }
	if extra then
		for k, v in pairs(extra) do
			e[k] = v
		end
	end
	return P(parent, name, size, cf, colour, material, e)
end

-- Neon ice: the room's glowing colour. Transparency stays 0 (Neon above zero
-- renders near-black under Future lighting); `depth` darkens instead.
local function glowIce(parent, name, size, cf, depth: number?)
	return trim(parent, name, size, cf, PALETTE.iceGlow:Lerp(PALETTE.ice, depth or 0), Enum.Material.Neon,
		{ Transparency = 0 })
end

local function glow(part: BasePart, colour: Color3, range: number, brightness: number)
	local l = Instance.new("PointLight")
	l.Color = colour
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = part
	return l
end

-- Translucent rime: SmoothPlastic + reflectance, never Glass.
local function frost(parent, name, size, cf)
	return trim(parent, name, size, cf, PALETTE.frost, Enum.Material.SmoothPlastic,
		{ Transparency = 0.42, Reflectance = 0.3, CanQuery = false })
end

----------------------------------------------------------------
-- THE LITTER SET  --  ReplicatedStorage.CTB.Wreck
--
-- Folder name == ISLANDS[9].litterSet; CTB_Client waits thirty seconds for it.
-- Single BaseParts, every axis under two studs, and the thinnest axis is
-- never X (litterRest lays the thinnest axis vertical).
----------------------------------------------------------------
local WRECK_LITTER = {
	{ "Rivet Head", Vector3.new(0.5, 0.2, 0.5), dk(PALETTE.iron, 0.2), RUSTY },
	{ "Frozen Fork", Vector3.new(0.35, 0.12, 1.4), lt(PALETTE.iron, 0.4), PLATE, { Reflectance = 0.3 } },
	{ "China Shard", Vector3.new(1.0, 0.15, 0.8), PALETTE.glassPale, Enum.Material.SmoothPlastic },
	{ "Curtain Scrap", Vector3.new(1.2, 0.16, 0.9), PALETTE.velvet, Enum.Material.Fabric },
	{ "Rope End", Vector3.new(1.3, 0.4, 0.4), lt(PALETTE.timber, 0.28), Enum.Material.Fabric, { Shape = Enum.PartType.Cylinder } },
	{ "Porthole Ring", Vector3.new(1.1, 0.25, 1.1), PALETTE.brass, PLATE, { Reflectance = 0.25 } },
	{ "Suitcase Latch", Vector3.new(0.7, 0.3, 0.45), PALETTE.brass, PLATE },
	{ "Lantern Glass", Vector3.new(0.7, 0.35, 0.7), PALETTE.glassPale, Enum.Material.SmoothPlastic, { Transparency = 0.2, Reflectance = 0.3 } },
	{ "Gauge Face", Vector3.new(0.9, 0.2, 0.9), lt(PALETTE.hullWhite, 0.2), Enum.Material.SmoothPlastic },
	{ "Teacup", Vector3.new(0.6, 0.5, 0.6), PALETTE.glassPale, Enum.Material.SmoothPlastic },
	{ "Crystal Drop", Vector3.new(0.4, 0.3, 0.4), PALETTE.iceGlow, Enum.Material.Neon, { Transparency = 0 } },
	{ "Deck Splinter", Vector3.new(1.6, 0.2, 0.4), PALETTE.timberDark, Enum.Material.Wood },
	{ "Coal Lump", Vector3.new(0.7, 0.5, 0.7), PALETTE.coal, Enum.Material.Slate, { Shape = Enum.PartType.Ball } },
	{ "Ice Chip", Vector3.new(0.9, 0.2, 0.7), PALETTE.ice, Enum.Material.SmoothPlastic, { Reflectance = 0.35 } },
}

local function buildWreckSet(): number
	local old = CTB:FindFirstChild("Wreck")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "Wreck"
	local n = 0
	for _, row in ipairs(WRECK_LITTER) do
		local p = Instance.new("Part")
		p.Name = row[1]
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Size = row[2]
		p.Color = row[3]
		p.Material = row[4]
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		if row[5] then
			for k, v in pairs(row[5]) do
				p[k] = v
			end
		end
		local sz = p.Size
		if sz.X < sz.Y - 1e-3 and sz.X < sz.Z - 1e-3 then
			warn(("[Wreck] litter piece %s is thinnest on X"):format(p.Name))
		end
		if math.max(sz.X, sz.Y, sz.Z) >= 2.0 then
			warn(("[Wreck] litter piece %s has an axis of 2 studs or more"):format(p.Name))
		end
		p.Parent = folder
		n += 1
	end
	folder.Parent = CTB
	return n
end

----------------------------------------------------------------
-- THE FLOOR. Air above, Glacier below, and the top voxel row written at
-- occupancyFor(GROUND) so the field carved into it later sits flush.
-- Bounds are multiples of the voxel size.
----------------------------------------------------------------
local function buildFloor()
	local fx0, fx1 = CX - 200, CX + 200
	local fz0, fz1 = CZ - 272, CZ + 272

	for _, v in ipairs({ fx0, fx1, fz0, fz1 }) do
		assert(v % Config.VOXEL == 0, "[Wreck] floor bounds must be multiples of the voxel size")
	end

	Terrain:FillBlock(
		CFrame.new((fx0 + fx1) * 0.5, 60, (fz0 + fz1) * 0.5),
		Vector3.new(fx1 - fx0 + 40, 200, fz1 - fz0 + 40), Enum.Material.Air)
	Terrain:FillBlock(
		CFrame.new((fx0 + fx1) * 0.5, -10, (fz0 + fz1) * 0.5),
		Vector3.new(fx1 - fx0, 20, fz1 - fz0), ISL.matMessy)

	local _, o3 = Config.occupancyFor(GROUND)
	local region = Region3.new(
		Vector3.new(fx0, 0, fz0),
		Vector3.new(fx1, Config.VOXEL, fz1)
	):ExpandToGrid(Config.VOXEL)
	local nx = math.floor(region.Size.X / Config.VOXEL + 0.5)
	local ny = math.floor(region.Size.Y / Config.VOXEL + 0.5)
	local nz = math.floor(region.Size.Z / Config.VOXEL + 0.5)

	local mats, occs = table.create(nx), table.create(nx)
	for xi = 1, nx do
		local mx, ox = table.create(ny), table.create(ny)
		mats[xi], occs[xi] = mx, ox
		for yi = 1, ny do
			mx[yi], ox[yi] = table.create(nz), table.create(nz)
			for zi = 1, nz do
				mx[yi][zi], ox[yi][zi] = ISL.matMessy, o3
			end
		end
	end
	Terrain:WriteVoxels(region, Config.VOXEL, mats, occs)
end

----------------------------------------------------------------
-- A STALL: the shell shared by the purser's office and the ship's stores.
-- A timber counter with a frosted top, hull plating behind it, a bent
-- awning of deck plate over it, and a board the caller letters.
----------------------------------------------------------------
--[[
	THE STALL FACES NORTH, UP THE HALL AT THE FIELD -- the way the Magma
	Chamber's bench and forge do. The player arrives at ENTRY (Z0 + 26) between
	the exit and the stalls, walks north past their plating, and comes back to
	the counters from the field side with a full bag. The first cut had the
	counters facing SOUTH at the exit wall, so both stalls presented their backs
	to everyone coming off the field; fixed 2026-09-11.

	In this frame +Z is the FRONT: counter at sz, its pad and prompt on the +Z
	side, the plating and shelf on the -Z side. A Part's "Front" face is its -Z
	face, so anything lettered for a customer standing north of the counter is
	dressed on Back (the +Z face).
]]
local function stall(parent, name: string, sx: number, sz: number, title: string, strap: string): Model
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	local G = GROUND
	-- the counter
	box(m, "Counter", sx - 11, sx + 11, G, G + 3.4, sz - 1.3, sz + 1.3, PALETTE.timber, Enum.Material.WoodPlanks)
	box(m, "CounterTop", sx - 11.4, sx + 11.4, G + 3.4, G + 3.8, sz - 1.7, sz + 1.7, lt(PALETTE.timber, 0.12), Enum.Material.Wood)
	frost(m, "CounterFrost", Vector3.new(22, 0.12, 3.2), CFrame.new(sx, G + 3.86, sz))
	-- the plating BEHIND the counter (south of it), with rust and a shelf
	box(m, "Back", sx - 13, sx + 13, G, G + 14, sz - 8.4, sz - 7.2, IRON_DARK, PLATE)
	box(m, "Shelf", sx - 12, sx + 12, G + 7, G + 7.4, sz - 7.2, sz - 5.4, PALETTE.timber, Enum.Material.Wood, { CanCollide = false })
	for i = 1, 3 do
		trim(m, "RustRun", Vector3.new(0.7, 9 - i, 0.12), CFrame.new(sx - 9 + i * 5.5, G + 9 - (9 - i) * 0.5, sz - 7.12),
			dk(PALETTE.rust, 0.25), Enum.Material.Slate)
	end
	-- posts at the front corners
	for _, s in ipairs({ -1, 1 }) do
		box(m, "Post", sx + s * 12.4 - 0.5, sx + s * 12.4 + 0.5, G, G + 13, sz + 1.2, sz + 2.2, IRON_DARK, PLATE)
	end
	-- a bent deck plate for an awning, frosted, sloping down toward the front
	local aw = P(m, "Awning", Vector3.new(27, 0.5, 11.6), CFrame.new(sx, G + 13.2, sz - 2.6) * CFrame.Angles(0.12, 0, 0),
		PALETTE.iron, PLATE, { CanCollide = false })
	frost(m, "AwningFrost", Vector3.new(26.4, 0.4, 11), aw.CFrame * CFrame.new(0, 0.45, 0))
	-- the board on the awning's front edge, lettered both ways
	local board = box(m, "Board", sx - 9, sx + 9, G + 9.4, G + 12.4, sz + 3.1, sz + 3.6, dk(PALETTE.hullWhite, 0.35), Enum.Material.Wood)
	if board then
		SignKit.dress(board, title, { Enum.NormalId.Front, Enum.NormalId.Back })
	end
	-- the strap on the counter's front face (+Z, so the Back face)
	local strapPart = box(m, "Strap", sx - 6, sx + 6, G + 4.4, G + 5.4, sz + 1.72, sz + 1.9, PALETTE.velvet, Enum.Material.Fabric)
	if strapPart then
		SignKit.dress(strapPart, strap, { Enum.NormalId.Back })
	end
	-- a lamp on each post, facing north, one lit
	wp("wallLamp", m, CFrame.new(sx - 12.4, G + 10, sz + 2.4) * CFrame.Angles(0, math.pi, 0), true)
	wp("wallLamp", m, CFrame.new(sx + 12.4, G + 10, sz + 2.4) * CFrame.Angles(0, math.pi, 0), false)
	-- goods on the shelf
	for i = -2, 2 do
		trim(m, "Tin", Vector3.new(1.0, 1.3, 1.0), CFrame.new(sx + i * 4.2, G + 8.05, sz - 6.3),
			(i % 2 == 0) and PALETTE.brass or PALETTE.hullRed, PLATE)
	end
	return m
end

----------------------------------------------------------------
-- build
----------------------------------------------------------------
function Wreck.build()
	local old = workspace:FindFirstChild("FrozenWreck")
	if old then
		old:Destroy()
	end
	local root = Instance.new("Folder")
	root.Name = "FrozenWreck"
	root.Parent = workspace

	local kinds = buildWreckSet()
	local rng = Random.new(Config.SEED + 9931)
	local G = GROUND

	buildFloor()

	local lights = 0
	local function lit(part, colour, range, brightness)
		lights += 1
		return glow(part, colour, range, brightness)
	end

	----------------------------------------------------------------
	-- THE SHELL: deck planks round the field, plating for walls, the deck
	-- above for a ceiling, ribs and beams -- a hold, not a cave.
	----------------------------------------------------------------
	local shell = Instance.new("Model")
	shell.Name = "Hull"
	shell.Parent = root

	local FX0, FX1 = CX - ISL.half - 2, CX + ISL.half + 2
	local FZ0, FZ1 = CZ - ISL.half - 2, CZ + ISL.half + 2
	local DECK_TOP = G + 0.05
	box(shell, "DeckS", X0, X1, G - 0.6, DECK_TOP, Z0, FZ0, PALETTE.timber, Enum.Material.WoodPlanks)
	box(shell, "DeckN", X0, X1, G - 0.6, DECK_TOP, FZ1, Z1, PALETTE.timber, Enum.Material.WoodPlanks)
	box(shell, "DeckW", X0, FX0, G - 0.6, DECK_TOP, FZ0, FZ1, PALETTE.timber, Enum.Material.WoodPlanks)
	box(shell, "DeckE", FX1, X1, G - 0.6, DECK_TOP, FZ0, FZ1, PALETTE.timber, Enum.Material.WoodPlanks)
	-- the field's own edge: a low brass strip so the square reads as a hatch
	for _, e in ipairs({
		{ FX0 - 0.4, FX1 + 0.4, FZ0 - 0.4, FZ0 }, { FX0 - 0.4, FX1 + 0.4, FZ1, FZ1 + 0.4 },
		{ FX0 - 0.4, FX0, FZ0, FZ1 }, { FX1, FX1 + 0.4, FZ0, FZ1 },
	}) do
		box(shell, "HatchCoaming", e[1], e[2], G - 0.3, G + 0.08, e[3], e[4], PALETTE.brass, PLATE, { CanCollide = false })
	end

	-- walls: plating, with a rust band low down and a frost band high up
	box(shell, "WallW", X0 - 2, X0, G - 1, CEIL + 4, Z0 - 2, Z1 + 2, PALETTE.iron, PLATE)
	box(shell, "WallE", X1, X1 + 2, G - 1, CEIL + 4, Z0 - 2, Z1 + 2, PALETTE.iron, PLATE)
	box(shell, "WallS", X0 - 2, X1 + 2, G - 1, CEIL + 4, Z0 - 2, Z0, PALETTE.iron, PLATE)
	box(shell, "WallN", X0 - 2, X1 + 2, G - 1, CEIL + 4, Z1, Z1 + 2, PALETTE.iron, PLATE)
	trim(shell, "RustBandW", Vector3.new(0.2, 6, Z1 - Z0), CFrame.new(X0 + 0.1, G + 3, CZ), dk(PALETTE.rust, 0.15), RUSTY)
	trim(shell, "RustBandE", Vector3.new(0.2, 6, Z1 - Z0), CFrame.new(X1 - 0.1, G + 3, CZ), dk(PALETTE.rust, 0.15), RUSTY)
	frost(shell, "FrostBandW", Vector3.new(0.3, 10, Z1 - Z0), CFrame.new(X0 + 0.15, CEIL - 6, CZ))
	frost(shell, "FrostBandE", Vector3.new(0.3, 10, Z1 - Z0), CFrame.new(X1 - 0.15, CEIL - 6, CZ))
	-- the tumblehome: the plating leans in as it meets the deck above
	for _, s in ipairs({ -1, 1 }) do
		local x = (s < 0) and (X0 + 5) or (X1 - 5)
		P(shell, "Knee", Vector3.new(12, 1.6, Z1 - Z0), CFrame.new(x, CEIL - 3.6, CZ) * CFrame.Angles(0, 0, -s * 0.55),
			IRON_DARK, PLATE, { CanCollide = true })
	end
	-- the deck overhead
	box(shell, "Overhead", X0 - 2, X1 + 2, CEIL, CEIL + 2, Z0 - 2, Z1 + 2, PALETTE.timberDark, Enum.Material.WoodPlanks)

	-- ribs every 24 studs down both sides, beams across the overhead to match
	local ribs, beams = 0, 0
	for z = Z0 + 12, Z1 - 12, 24 do
		for _, s in ipairs({ -1, 1 }) do
			local x0 = (s < 0) and X0 or (X1 - 2.2)
			box(shell, "Rib", x0, x0 + 2.2, G, CEIL, z - 1.2, z + 1.2, IRON_DARK, PLATE)
			ribs += 1
			if ribs % 3 == 0 then
				wp("rustStreak", shell, CFrame.new(x0 + ((s < 0) and 2.3 or -0.1), G + 22 + rng:NextNumber(-6, 6), z + 2.6)
					* CFrame.Angles(0, (s < 0) and (-math.pi * 0.5) or (math.pi * 0.5), 0), 10)
			end
		end
		box(shell, "Beam", X0, X1, CEIL - 2.6, CEIL, z - 1.3, z + 1.3, PALETTE.timberDark, Enum.Material.Wood, { CanCollide = false })
		beams += 1
		if beams % 2 == 0 then
			-- an icicle curtain under every other beam, over the aisles only
			wp("icicleCurtain", shell, Vector3.new(X0 + 6, CEIL - 2.6, z), Vector3.new(FX0 - 8, CEIL - 2.6, z))
			wp("icicleCurtain", shell, Vector3.new(FX1 + 8, CEIL - 2.6, z), Vector3.new(X1 - 6, CEIL - 2.6, z))
		end
	end

	-- porthole rows down both sides, eye height and high
	for _, y in ipairs({ G + 12, G + 30 }) do
		wp("portholeRow", shell, Vector3.new(X0 + 0.4, y, Z0 + 20), Vector3.new(X0 + 0.4, y, Z1 - 20), 14)
		wp("portholeRow", shell, Vector3.new(X1 - 0.4, y, Z0 + 20), Vector3.new(X1 - 0.4, y, Z1 - 20), 14)
	end

	----------------------------------------------------------------
	-- DAYLIGHT: rents in the deck above, with the ice over them glowing.
	-- Six of them, each a Neon slab in the overhead plus the room's real light,
	-- plus a faint shaft down to the floor. This is the room's lighting.
	----------------------------------------------------------------
	local rents = Instance.new("Model")
	rents.Name = "DeckRents"
	rents.Parent = root
	for i, o in ipairs({ { -80, -100 }, { 80, -100 }, { 0, 0 }, { -84, 100 }, { 84, 100 }, { 0, 190 }, { -70, -196 }, { 70, -196 } }) do
		local x, z = CX + o[1], CZ + o[2]
		local yaw = i * 0.7
		local slab = glowIce(rents, "Rent", Vector3.new(16, 0.8, 9), CFrame.new(x, CEIL - 0.3, z) * CFrame.Angles(0, yaw, 0), 0.1)
		glowIce(rents, "RentEdge", Vector3.new(9, 0.8, 6), CFrame.new(x + 6, CEIL - 0.3, z - 3) * CFrame.Angles(0, yaw + 0.6, 0), 0.3)
		glowIce(rents, "RentEdge", Vector3.new(7, 0.8, 5), CFrame.new(x - 7, CEIL - 0.3, z + 2) * CFrame.Angles(0, yaw - 0.5, 0), 0.3)
		-- splintered deck round the tear
		for k = 1, 4 do
			trim(rents, "Splinter", Vector3.new(2.2, 0.6, 7 + k), CFrame.new(x + math.cos(k * 1.6 + yaw) * 9, CEIL - 1.2, z + math.sin(k * 1.6 + yaw) * 6)
				* CFrame.Angles(0.2, k * 1.6 + yaw, 0), PALETTE.timberDark, Enum.Material.Wood)
		end
		lit(slab, PALETTE.iceGlow, 130, 3.0)
		-- the shaft: a tall translucent column, no collision, faintly blue
		trim(rents, "Shaft", Vector3.new(14, CEIL - G - 1, 8), CFrame.new(x, (CEIL + G) * 0.5, z) * CFrame.Angles(0, yaw, 0),
			PALETTE.iceGlow, Enum.Material.SmoothPlastic, { Transparency = 0.86, CanQuery = false, CanTouch = false })
		-- and a pool of it on the deck under the rent, lit from the floor
		local pool = trim(rents, "Pool", Vector3.new(18, 0.1, 11), CFrame.new(x, G + 0.09, z) * CFrame.Angles(0, yaw, 0),
			PALETTE.iceGlow, Enum.Material.SmoothPlastic, { Transparency = 0.55, CanQuery = false, CanTouch = false })
		lit(pool, PALETTE.iceGlow, 40, 1.2)
	end

	-- snow sifting down through the rents
	do
		local host = P(root, "SnowHost", Vector3.new(X1 - X0 - 20, 1, Z1 - Z0 - 20),
			CFrame.new(CX, CEIL - 3, CZ), PALETTE.snow, Enum.Material.SmoothPlastic,
			{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
		local flakes = Instance.new("ParticleEmitter")
		flakes.Name = "Snow"
		flakes.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		flakes.Color = ColorSequence.new(Color3.fromRGB(240, 248, 255))
		flakes.LightEmission = 0.35
		flakes.Rate = 26
		flakes.Lifetime = NumberRange.new(7, 12)
		flakes.Speed = NumberRange.new(1.5, 3.5)
		flakes.SpreadAngle = Vector2.new(14, 14)
		flakes.Acceleration = Vector3.new(0.3, -0.9, 0)
		flakes.Rotation = NumberRange.new(0, 360)
		flakes.RotSpeed = NumberRange.new(-40, 40)
		flakes.EmissionDirection = Enum.NormalId.Bottom
		flakes.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.25),
			NumberSequenceKeypoint.new(0.5, 0.5),
			NumberSequenceKeypoint.new(1, 0.15),
		})
		flakes.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(0.6, 0.4),
			NumberSequenceKeypoint.new(1, 1),
		})
		flakes.Parent = host
	end

	----------------------------------------------------------------
	-- THE SOUTH END: the breach out, the purser's office (sell), the ship's
	-- stores (upgrades) and the wash bay. Everything south of Z0 + 90; the
	-- field starts at Z0 + 128 and the skin plinth stands at Z0 + 112.
	----------------------------------------------------------------
	local STALL_X = 50
	local STALL_Z = Z0 + 42

	-- THE WAY OUT: the breach in the south bulkhead, an arch of torn plate
	local exitM = Instance.new("Model")
	exitM.Name = "Exit"
	exitM.Parent = root
	local EZ = Z0 + 12
	for _, sx in ipairs({ -1, 1 }) do
		local x0 = CX + math.min(sx * 13, sx * 19)
		local x1 = CX + math.max(sx * 13, sx * 19)
		box(exitM, "ArchPier", x0, x1, G, G + 19, EZ - 3.4, EZ + 3.4, IRON_DARK, PLATE)
		trim(exitM, "PierRust", Vector3.new(4, 12, 0.14), CFrame.new(CX + sx * 16, G + 10, EZ - 3.5), dk(PALETTE.rust, 0.2), RUSTY)
	end
	box(exitM, "ArchHead", CX - 20, CX + 20, G + 19, G + 24.5, EZ - 4.2, EZ + 4.2, IRON_DARK, PLATE)
	for i = -2, 2 do
		trim(exitM, "TornPlate", Vector3.new(4.4, 3.6 + math.abs(i) * 1.1, 5),
			CFrame.new(CX + i * 6.6, G + 17.6, EZ) * CFrame.Angles(0, 0, i * 0.12), dk(PALETTE.iron, 0.5), RUSTY)
	end
	local lintel = glowIce(exitM, "ArchIce", Vector3.new(38, 0.45, 4.6), CFrame.new(CX, G + 19.1, EZ), 0.15)
	lit(lintel, PALETTE.iceGlow, 30, 1.1)
	wp("icicleCurtain", exitM, Vector3.new(CX - 18, G + 19, EZ - 3), Vector3.new(CX + 18, G + 19, EZ - 3))
	-- daylight in the wall behind the arch: the way out reads as light
	glowIce(exitM, "Daylight", Vector3.new(24, 16, 0.6), CFrame.new(CX, G + 9, Z0 + 0.4), 0.05)
	P(exitM, "Pad", Vector3.new(14, 0.5, 10),
		CFrame.new(CX, G + 0.25, EZ - 6), PALETTE.ice, Enum.Material.Ice, { CanCollide = true, Reflectance = 0.2 })
	-- THE PROMPT GOES ON AN ANCHOR AT HEAD HEIGHT, NOT ON THE PAD (see MagmaBuilder).
	local promptAt = P(exitM, "PromptAnchor", Vector3.new(1, 1, 1),
		CFrame.new(CX, G + 6, EZ - 6), PALETTE.ice, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
	local leave = Instance.new("ProximityPrompt")
	leave.Name = "LeavePrompt"
	leave.ActionText = "Leave"
	leave.ObjectText = "The Frozen Wreck"
	leave.HoldDuration = 0.5
	leave.MaxActivationDistance = 16
	leave.RequiresLineOfSight = false
	leave.Parent = promptAt
	leave.Triggered:Connect(function(plr)
		Wreck.leave(plr)
	end)

	-- THE PURSER'S OFFICE: the sell bench, left of the way out. The pad lies
	-- NORTH of the counter -- the customer's side -- and the trunks flank it.
	local bench = stall(root, "PursersOffice", CX - STALL_X, STALL_Z, "SELL", "SELL YOUR FINDS")
	P(bench, "PadFrame", Vector3.new(24, 0.3, 15), CFrame.new(CX - STALL_X, G + 0.3, STALL_Z + 10),
		PALETTE.brass, PLATE, { CanCollide = false })
	local pad = P(bench, "SellPad", Vector3.new(22, 0.45, 13),
		CFrame.new(CX - STALL_X, G + 0.52, STALL_Z + 10), PALETTE.ice, Enum.Material.Ice, { Reflectance = 0.18 })
	frost(bench, "PadFrost", Vector3.new(21, 0.12, 12), CFrame.new(CX - STALL_X, G + 0.8, STALL_Z + 10))
	wp("steamerTrunk", bench, CFrame.new(CX - STALL_X - 16, G, STALL_Z + 2) * CFrame.Angles(0, 0.4, 0))
	wp("steamerTrunk", bench, CFrame.new(CX - STALL_X + 16, G, STALL_Z + 1) * CFrame.Angles(0, -0.3, 0))

	-- THE SHIP'S STORES: the upgrade stall, right of the way out; the prompt
	-- hangs over the customer's side of the counter
	local shopM = stall(root, "ShipsStores", CX + STALL_X, STALL_Z, "UPGRADES", "SPEND YOUR COINS")
	local shopAnchor = P(shopM, "PromptAnchor", Vector3.new(1, 1, 1),
		CFrame.new(CX + STALL_X, G + 5.2, STALL_Z + 5), PALETTE.ice, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
	local shopPrompt = Instance.new("ProximityPrompt")
	shopPrompt.Name = "ShopPrompt"
	shopPrompt.ActionText = "Browse"
	shopPrompt.ObjectText = "Ship's Stores"
	shopPrompt.KeyboardKeyCode = Enum.KeyCode.E
	shopPrompt.HoldDuration = 0
	shopPrompt.MaxActivationDistance = 16
	shopPrompt.RequiresLineOfSight = false
	shopPrompt.Parent = shopAnchor
	wp("deckCrateStack", shopM, CFrame.new(CX + STALL_X + 18, G, STALL_Z + 4) * CFrame.Angles(0, 0.3, 0), 41)
	wp("barrel", shopM, CFrame.new(CX + STALL_X - 17, G, STALL_Z + 3))
	wp("barrel", shopM, CFrame.new(CX + STALL_X - 20, G, STALL_Z + 7))

	-- THE WASH BAY: a clone of the authored beach shack (tag WashBay + part
	-- Stand is what WashServer binds); BayBuilder is the fallback.
	do
		local WASH_X = 108
		local WASH_Z = Z0 + 16
		local rig
		local authored = workspace:FindFirstChild("WashBay")
		if authored and authored:IsA("Model") then
			rig = authored:Clone()
		else
			local okRig, built = pcall(function()
				local BayBuilder = require(script.Parent:WaitForChild("BayBuilder"))
				return BayBuilder.buildWashBay(CFrame.new(CX - WASH_X, G + 0.12, WASH_Z))
			end)
			if okRig and built then
				rig = built
			else
				warn("[Wreck] no wash bay to clone and BayBuilder would not build one:", built)
			end
		end
		if rig then
			rig.Name = "WreckWashBay"
			local bcf, bsize = rig:GetBoundingBox()
			rig:PivotTo(rig:GetPivot() + Vector3.new(
				(CX - WASH_X) - bcf.Position.X,
				(G + 0.12) - (bcf.Position.Y - bsize.Y * 0.5),
				WASH_Z - bcf.Position.Z))
			for _, p in ipairs(rig:GetDescendants()) do
				if p:IsA("BasePart") then
					local n = p.Name:match("^Stripe(%d+)$")
					if n then
						p.Color = (tonumber(n) % 2 == 0) and PALETTE.hullWhite or PALETTE.hullRed
					elseif p.Name == "SignBoard" then
						p.Color = dk(PALETTE.hullWhite, 0.35)
					end
				end
			end
			rig.Parent = root
		end
	end

	----------------------------------------------------------------
	-- THE WEST AISLE: the boiler room and the galley
	----------------------------------------------------------------
	local westM = Instance.new("Model")
	westM.Name = "BoilerRoom"
	westM.Parent = root
	local WX = X0 + 26
	wp("boiler", westM, CFrame.new(WX, G, CZ - 50) * CFrame.Angles(0, math.pi * 0.5, 0), 1.0)
	wp("boiler", westM, CFrame.new(WX, G, CZ + 10) * CFrame.Angles(0, math.pi * 0.5, 0), 0.9)
	wp("pipeRun", westM, Vector3.new(X0 + 4, G + 22, Z0 + 60), Vector3.new(X0 + 4, G + 22, Z1 - 60), 1.4)
	wp("pipeRun", westM, Vector3.new(X0 + 4, G + 18, Z0 + 90), Vector3.new(X0 + 4, G + 18, Z1 - 90), 0.9)
	wp("pipeRun", westM, Vector3.new(X0 + 4, G + 20, CZ - 20), Vector3.new(X0 + 40, G + 20, CZ - 20), 1.1)
	for i, z in ipairs({ CZ + 50, CZ + 62, CZ + 74 }) do
		wp("barrel", westM, CFrame.new(WX - 8 + (i % 2) * 6, G, z))
	end
	wp("cargoStack", westM, CFrame.new(WX, G, CZ + 110) * CFrame.Angles(0, 0.2, 0), 7)
	wp("cargoStack", westM, CFrame.new(WX + 4, G, Z1 - 150) * CFrame.Angles(0, -0.5, 0), 8)
	wp("kitchenRange", westM, CFrame.new(WX - 6, G, Z0 + 92) * CFrame.Angles(0, math.pi * 0.5, 0))
	wp("diningTable", westM, CFrame.new(WX + 12, G, Z0 + 112) * CFrame.Angles(0, math.pi * 0.5, 0), 12)
	wp("brokenBeam", westM, Vector3.new(X0 + 2, G + 30, CZ - 120), Vector3.new(X0 + 34, G + 2, CZ - 96))
	wp("brokenBeam", westM, Vector3.new(X0 + 2, G + 34, Z1 - 96), Vector3.new(X0 + 30, G + 1, Z1 - 120))
	for i = 0, 5 do
		local made = wp("wallLamp", westM, CFrame.new(X0 + 2.4, G + 11, Z0 + 46 + i * 76) * CFrame.Angles(0, -math.pi * 0.5, 0), i % 2 == 0)
		if made and i % 2 == 0 then
			lights += 1
		end
	end

	----------------------------------------------------------------
	-- THE EAST AISLE: cabins
	----------------------------------------------------------------
	local eastM = Instance.new("Model")
	eastM.Name = "Cabins"
	eastM.Parent = root
	local EX = X1 - 16
	for i, z in ipairs({ Z0 + 70, Z0 + 150, CZ + 20, CZ + 100, Z1 - 120 }) do
		wp("bunkRow", eastM, CFrame.new(EX, G, z) * CFrame.Angles(0, math.pi * 0.5, 0), 3)
		wp("steamerTrunk", eastM, CFrame.new(EX - 14, G, z + 12 + (i % 2) * 4) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0))
		wp("portholeWindow", eastM, CFrame.new(X1 - 0.6, G + 9, z - 22) * CFrame.Angles(0, math.pi * 0.5, 0))
	end
	wp("pianoFrozen", eastM, CFrame.new(EX - 4, G, Z1 - 60) * CFrame.Angles(0, math.pi * 0.7, 0))
	wp("brokenBeam", eastM, Vector3.new(X1 - 2, G + 32, CZ - 40), Vector3.new(X1 - 36, G + 1.5, CZ - 12))
	for i = 0, 5 do
		local made = wp("wallLamp", eastM, CFrame.new(X1 - 2.4, G + 11, Z0 + 84 + i * 76) * CFrame.Angles(0, math.pi * 0.5, 0), i % 2 == 1)
		if made and i % 2 == 1 then
			lights += 1
		end
	end

	----------------------------------------------------------------
	-- THE NORTH END: the grand saloon, and the bridge on the mezzanine above
	----------------------------------------------------------------
	local saloon = Instance.new("Model")
	saloon.Name = "Saloon"
	saloon.Parent = root
	-- a strip of the saloon's red carpet, frozen
	box(saloon, "Carpet", CX - 100, CX + 100, DECK_TOP, DECK_TOP + 0.08, Z1 - 126, Z1 - 44, PALETTE.velvet, Enum.Material.Fabric, { CanCollide = false })
	frost(saloon, "CarpetFrost", Vector3.new(196, 0.1, 80), CFrame.new(CX, DECK_TOP + 0.14, Z1 - 85))
	for i, x in ipairs({ CX - 66, CX, CX + 66 }) do
		wp("diningTable", saloon, CFrame.new(x, G, Z1 - 96), 22)
		local ch = wp("chandelier", saloon, CFrame.new(x, CEIL - 2.6, Z1 - 96), 1.0, true)
		if ch then
			lights += 1
		end
	end
	wp("chandelier", saloon, CFrame.new(CX, CEIL - 2.6, Z1 - 20), 0.8, true)
	lights += 1

	-- the mezzanine: the bridge deck along the north wall
	local MEZ = G + 14
	box(saloon, "MezzDeck", X0 + 10, X1 - 10, MEZ - 1.2, MEZ, Z1 - 42, Z1, PALETTE.timber, Enum.Material.WoodPlanks)
	box(saloon, "MezzFascia", X0 + 10, X1 - 10, MEZ - 3.2, MEZ - 1.2, Z1 - 42, Z1 - 41.2, PALETTE.hullWhite, Enum.Material.Wood, { CanCollide = false })
	for _, x in ipairs({ X0 + 40, CX - 60, CX + 60, X1 - 40 }) do
		box(saloon, "MezzPost", x - 1.2, x + 1.2, G, MEZ - 1.2, Z1 - 41.6, Z1 - 39.2, IRON_DARK, PLATE)
	end
	wp("railingRun", saloon, Vector3.new(X0 + 10, MEZ, Z1 - 41.6), Vector3.new(CX - 8, MEZ, Z1 - 41.6))
	wp("railingRun", saloon, Vector3.new(CX + 8, MEZ, Z1 - 41.6), Vector3.new(X1 - 10, MEZ, Z1 - 41.6))
	-- the grand staircase up to it, rising north
	wp("staircase", saloon, CFrame.lookAt(Vector3.new(CX, G, Z1 - 59), Vector3.new(CX, G, Z1)), MEZ - G, 14)
	-- the bridge
	wp("shipWheel", saloon, CFrame.new(CX, MEZ, Z1 - 14) * CFrame.Angles(0, math.pi, 0))
	wp("captainDesk", saloon, CFrame.new(CX + 44, MEZ, Z1 - 20) * CFrame.Angles(0, math.pi, 0))
	wp("steamerTrunk", saloon, CFrame.new(CX - 50, MEZ, Z1 - 18) * CFrame.Angles(0, 0.4, 0))
	wp("bunkBed", saloon, CFrame.new(X1 - 30, MEZ, Z1 - 24) * CFrame.Angles(0, math.pi * 0.5, 0))
	for i = 0, 3 do
		local made = wp("wallLamp", saloon, CFrame.new(X0 + 30 + i * 90, MEZ + 8, Z1 - 2.4), i % 2 == 0)
		if made and i % 2 == 0 then
			lights += 1
		end
	end
	-- a plate over the saloon: the ship's name, the one place it is written inside
	local plate = box(saloon, "SaloonPlate", CX - 22, CX + 22, MEZ + 12, MEZ + 16, Z1 - 0.6, Z1 - 0.1, dk(PALETTE.hullWhite, 0.4), Enum.Material.Wood)
	if plate then
		SignKit.dress(plate, "S.S. AURORA MERIDIAN", { Enum.NormalId.Front })
	end

	----------------------------------------------------------------
	-- FROST, SNOW AND WRECKAGE on the aisles (never on the field)
	----------------------------------------------------------------
	local dressing = Instance.new("Model")
	dressing.Name = "Dressing"
	dressing.Parent = root
	local banks, patches = 0, 0
	for _, c in ipairs({ { X0 + 8, Z0 + 8 }, { X1 - 8, Z0 + 8 }, { X0 + 8, Z1 - 8 }, { X1 - 8, Z1 - 8 },
		{ X0 + 6, CZ - 150 }, { X1 - 6, CZ + 150 }, { X0 + 6, CZ + 60 }, { X1 - 6, CZ - 60 }, { CX - 30, Z0 + 6 }, { CX + 30, Z0 + 6 } }) do
		if wp("snowBank", dressing, CFrame.new(c[1], G, c[2]) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), rng:NextNumber(1.4, 2.6)) then
			banks += 1
		end
	end
	for _ = 1, 40 do
		local side = rng:NextInteger(1, 4)
		local x, z
		if side == 1 then
			x, z = rng:NextNumber(X0 + 6, FX0 - 6), rng:NextNumber(Z0 + 6, Z1 - 6)
		elseif side == 2 then
			x, z = rng:NextNumber(FX1 + 6, X1 - 6), rng:NextNumber(Z0 + 6, Z1 - 6)
		elseif side == 3 then
			x, z = rng:NextNumber(X0 + 6, X1 - 6), rng:NextNumber(Z0 + 60, FZ0 - 6)
		else
			x, z = rng:NextNumber(X0 + 6, X1 - 6), rng:NextNumber(FZ1 + 6, Z1 - 60)
		end
		if wp("frostPatch", dressing, CFrame.new(x, DECK_TOP, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
			Vector3.new(rng:NextNumber(5, 12), 0.12, rng:NextNumber(4, 9))) then
			patches += 1
		end
	end
	for i = 1, 6 do
		wp("ropeCoil", dressing, CFrame.new((i % 2 == 0) and (X0 + 14 + i * 3) or (X1 - 14 - i * 3), G, Z0 + 40 + i * 60))
	end

	----------------------------------------------------------------
	-- PROVE NOTHING STANDS ON THE FIELD. One collidable part on one column
	-- is a field that never turns over (resetAt 1.0). Half-extents come off
	-- the part's own basis because several of these are yawed.
	----------------------------------------------------------------
	do
		local fx0, fx1 = ISL.cx - ISL.half - 2, ISL.cx + ISL.half + 2
		local fz0, fz1 = ISL.cz - ISL.half - 2, ISL.cz + ISL.half + 2
		local moved = 0
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("BasePart") and d.CanCollide then
				local p, cf, sz = d.Position, d.CFrame, d.Size
				local hx = 0.5 * (math.abs(cf.RightVector.X) * sz.X
					+ math.abs(cf.UpVector.X) * sz.Y + math.abs(cf.LookVector.X) * sz.Z)
				local hz = 0.5 * (math.abs(cf.RightVector.Z) * sz.X
					+ math.abs(cf.UpVector.Z) * sz.Y + math.abs(cf.LookVector.Z) * sz.Z)
				local hy = 0.5 * (math.abs(cf.RightVector.Y) * sz.X
					+ math.abs(cf.UpVector.Y) * sz.Y + math.abs(cf.LookVector.Y) * sz.Z)
				if p.X + hx > fx0 and p.X - hx < fx1
					and p.Z + hz > fz0 and p.Z - hz < fz1
					and p.Y - hy < GROUND + 12 then
					local side = (p.X < ISL.cx) and -1 or 1
					d.CFrame = d.CFrame + Vector3.new(ISL.cx + side * 150 - p.X, 0, 0)
					moved += 1
				end
			end
		end
		if moved > 0 then
			warn(("[Wreck] %d parts were standing on the rakeable field and were pushed clear"):format(moved))
		end
	end

	-- every part anchored, every light unshadowed, thin/neon/clear parts not casting
	local partCount, shadowsOff = 0, 0
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			partCount += 1
			d.Anchored = true
			if d.CastShadow and (math.min(d.Size.X, d.Size.Y, d.Size.Z) < 1.0
				or d.Material == Enum.Material.Neon or d.Transparency > 0.5) then
				d.CastShadow = false
				shadowsOff += 1
			end
		elseif d:IsA("Light") then
			d.Shadows = false
		end
	end

	Wreck.sellPad = pad
	print(string.format("[Wreck] wreck built: %d parts, %d lights, %d shadow casters trimmed, %d ribs, %d beams, "
		.. "%d snow banks, %d frost patches, %d litter kinds, %d prop failures",
		partCount, lights, shadowsOff, ribs, beams, banks, patches, kinds, propFails))
	return pad
end

----------------------------------------------------------------
-- THE ENTRANCE: the liner herself, on Penguin Island's north shore
----------------------------------------------------------------
Wreck.ENTRY_NAME = "PenguinPortal"

-- The hull lies along X across the north strand, bow to the west on the snow.
local HX = PEN.cx + 20                 -- hull centre x
local HZ = PEN.cz + 670                -- hull centre z: -2130, 286 north of the field
local HALF_L = 130                     -- half the parallel length; bow and stern add 22 and 16
local BEAM = 30                        -- half the beam
local KEEL_Y = -6
local DECK_Y = 30                      -- the main deck's top
local FACE_Z = HZ - BEAM               -- the south hull face: the door's plane

-- The door in that face.
local DX = HX - 20                     -- the breach's x
local DECK = 3                         -- the ground the door stands on
local DOOR_TOP = DECK + 16
local DOOR_HX = 9                      -- one leaf's width; the opening is twice this

-- The approach, from the field's edge up to the breach.
local FIELD_N = PEN.cz + PEN.half      -- -2416
local MOUTH_Z = FIELD_N + 40           -- the gate at the mouth of the approach
local APPROACH_HX = 40

--[[
	THE APPROACH FLOOR IS PINNED. Island5Builder's mounds and scatter keep out
	of the wreck's box already, but the ground under the door is written here
	all the same -- Air above, Glacier below, the top row at the field's own
	occupancy -- so nothing that module changes later can bury the threshold.
	Bounds are multiples of four.
]]
local function pinApproach()
	local x0, x1 = DX - APPROACH_HX, DX + APPROACH_HX
	local z0, z1 = MOUTH_Z - 12, FACE_Z - 4
	x0, x1 = math.floor(x0 / 4) * 4, math.ceil(x1 / 4) * 4
	z0, z1 = math.floor(z0 / 4) * 4, math.floor(z1 / 4) * 4
	Terrain:FillBlock(CFrame.new((x0 + x1) * 0.5, (Config.VOXEL + 60) * 0.5, (z0 + z1) * 0.5),
		Vector3.new(x1 - x0, 60 - Config.VOXEL, z1 - z0), Enum.Material.Air)
	Terrain:FillBlock(CFrame.new((x0 + x1) * 0.5, -15, (z0 + z1) * 0.5),
		Vector3.new(x1 - x0, 30, z1 - z0), PEN.matMessy)
	local _, o3 = Config.occupancyFor(DECK)
	local region = Region3.new(Vector3.new(x0, 0, z0), Vector3.new(x1, Config.VOXEL, z1)):ExpandToGrid(Config.VOXEL)
	local nx = math.floor(region.Size.X / Config.VOXEL + 0.5)
	local ny = math.floor(region.Size.Y / Config.VOXEL + 0.5)
	local nz = math.floor(region.Size.Z / Config.VOXEL + 0.5)
	local mats, occs = table.create(nx), table.create(nx)
	for xi = 1, nx do
		local mx, ox = table.create(ny), table.create(ny)
		mats[xi], occs[xi] = mx, ox
		for yi = 1, ny do
			mx[yi], ox[yi] = table.create(nz), table.create(nz)
			for zi = 1, nz do
				mx[yi][zi], ox[yi][zi] = PEN.matMessy, o3
			end
		end
	end
	Terrain:WriteVoxels(region, Config.VOXEL, mats, occs)
end

-- Anything the island scattered on the approach is MOVED, never deleted.
local function clearApproach(): number
	local moved = 0
	local i5 = workspace:FindFirstChild("Island5")
	local props = i5 and i5:FindFirstChild("Props")
	if not props then
		return 0
	end
	for _, child in ipairs(props:GetChildren()) do
		local ok, pivot = pcall(function()
			return child:GetPivot().Position
		end)
		if ok and math.abs(pivot.X - DX) <= APPROACH_HX + 6
			and pivot.Z >= MOUTH_Z - 16 and pivot.Z <= HZ + BEAM + 20 then
			local push = (pivot.X < DX) and -1 or 1
			local target = Vector3.new(DX + push * (APPROACH_HX + 30), pivot.Y, pivot.Z)
			pcall(function()
				child:PivotTo(child:GetPivot() + (target - pivot))
			end)
			warn(("[Wreck] moved %s off the approach: %s -> %s"):format(child.Name, tostring(pivot), tostring(target)))
			moved += 1
		end
	end
	return moved
end

-- One hull plate between two world points: a box whose Z runs a to b.
local function plate(parent, name, a: Vector3, b: Vector3, height: number, thick: number, colour, material, extra)
	local d = b - a
	local len = d.Magnitude
	if len < 0.1 then
		return nil
	end
	local mid = (a + b) * 0.5
	return P(parent, name, Vector3.new(thick, height, len + thick),
		CFrame.lookAt(mid, b) * CFrame.new(0, 0, 0), colour, material, extra)
end

function Wreck.buildEntrance()
	local existing = workspace:FindFirstChild(Wreck.ENTRY_NAME)
	if existing then
		existing:Destroy()
	end

	pinApproach()
	local moved = clearApproach()

	local root = Instance.new("Model")
	root.Name = Wreck.ENTRY_NAME
	root.Parent = workspace

	local rng = Random.new(Config.SEED + 8813)

	----------------------------------------------------------------
	-- THE HULL. Faces, not a solid: the south face carries the breach and is
	-- built in pieces round it; the north face, the bow, the stern and the
	-- deck close the shell. Three bands: red boot-topping, black hull, white
	-- bulwark, and the deck's planks on top.
	----------------------------------------------------------------
	local hull = Instance.new("Model")
	hull.Name = "Hull"
	hull.Parent = root
	local XW, XE = HX - HALF_L, HX + HALF_L
	local bands = {
		{ y0 = KEEL_Y, y1 = 12, c = PALETTE.hullRed, m = RUSTY },
		{ y0 = 12, y1 = 26, c = PALETTE.hullBlack, m = PLATE },
		{ y0 = 26, y1 = DECK_Y, c = PALETTE.hullWhite, m = PLATE },
	}
	local GAP0, GAP1 = DX - DOOR_HX - 6, DX + DOOR_HX + 6
	for _, b in ipairs(bands) do
		-- north face: whole
		box(hull, "PlateN", XW, XE, b.y0, b.y1, HZ + BEAM - 2, HZ + BEAM, b.c, b.m)
		-- south face: split round the breach where the band meets the opening
		if b.y1 <= DECK or b.y0 >= DOOR_TOP + 3 then
			box(hull, "PlateS", XW, XE, b.y0, b.y1, FACE_Z, FACE_Z + 2, b.c, b.m)
		else
			box(hull, "PlateS", XW, GAP0, b.y0, b.y1, FACE_Z, FACE_Z + 2, b.c, b.m)
			box(hull, "PlateS", GAP1, XE, b.y0, b.y1, FACE_Z, FACE_Z + 2, b.c, b.m)
			-- the band below the sill and above the head, across the gap
			if b.y0 < DECK then
				box(hull, "PlateS", GAP0, GAP1, b.y0, DECK, FACE_Z, FACE_Z + 2, b.c, b.m)
			end
			if b.y1 > DOOR_TOP + 3 then
				box(hull, "PlateS", GAP0, GAP1, DOOR_TOP + 3, b.y1, FACE_Z, FACE_Z + 2, b.c, b.m)
			end
		end
		-- the bow: two plates meeting 22 studs past the parallel body
		plate(hull, "Bow", Vector3.new(XW, (b.y0 + b.y1) * 0.5, HZ - BEAM + 1), Vector3.new(XW - 22, (b.y0 + b.y1) * 0.5, HZ), b.y1 - b.y0, 2, b.c, b.m)
		plate(hull, "Bow", Vector3.new(XW, (b.y0 + b.y1) * 0.5, HZ + BEAM - 1), Vector3.new(XW - 22, (b.y0 + b.y1) * 0.5, HZ), b.y1 - b.y0, 2, b.c, b.m)
		-- the stern: two short plates and a transom
		plate(hull, "Stern", Vector3.new(XE, (b.y0 + b.y1) * 0.5, HZ - BEAM + 1), Vector3.new(XE + 16, (b.y0 + b.y1) * 0.5, HZ - 12), b.y1 - b.y0, 2, b.c, b.m)
		plate(hull, "Stern", Vector3.new(XE, (b.y0 + b.y1) * 0.5, HZ + BEAM - 1), Vector3.new(XE + 16, (b.y0 + b.y1) * 0.5, HZ + 12), b.y1 - b.y0, 2, b.c, b.m)
		box(hull, "Transom", XE + 15, XE + 17, b.y0, b.y1, HZ - 12, HZ + 12, b.c, b.m)
	end
	-- the main deck, and the bow and stern decks as narrowing slabs
	box(hull, "MainDeck", XW, XE, DECK_Y - 1, DECK_Y, HZ - BEAM, HZ + BEAM, PALETTE.timber, Enum.Material.WoodPlanks)
	for i = 0, 3 do
		local t = i / 4
		box(hull, "BowDeck", XW - 22 * (t + 0.25), XW - 22 * t + 0.5, DECK_Y - 1, DECK_Y, HZ - BEAM * (1 - t - 0.25) - 1, HZ + BEAM * (1 - t - 0.25) + 1,
			PALETTE.timber, Enum.Material.WoodPlanks)
	end
	box(hull, "SternDeck", XE - 0.5, XE + 16, DECK_Y - 1, DECK_Y, HZ - 12, HZ + 12, PALETTE.timber, Enum.Material.WoodPlanks)
	box(hull, "SternDeck", XE - 0.5, XE + 8, DECK_Y - 1, DECK_Y, HZ - 22, HZ + 22, PALETTE.timber, Enum.Material.WoodPlanks)
	-- frost on the deck, rust down the sides, snow banked against the hull
	for i = 1, 8 do
		wp("frostPatch", hull, CFrame.new(HX + rng:NextNumber(-120, 120), DECK_Y, HZ + rng:NextNumber(-24, 24)) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
			Vector3.new(rng:NextNumber(8, 18), 0.12, rng:NextNumber(6, 14)))
	end
	for i = 1, 12 do
		local x = HX + rng:NextNumber(-125, 125)
		if math.abs(x - DX) > 20 then
			wp("rustStreak", hull, CFrame.new(x, 26 - rng:NextNumber(0, 4), FACE_Z - 0.1) * CFrame.Angles(0, 0, 0), rng:NextNumber(6, 16))
		end
	end
	for i = 1, 14 do
		local x = HX + rng:NextNumber(-140, 140)
		if math.abs(x - DX) > 24 then
			wp("snowBank", hull, CFrame.new(x, DECK, FACE_Z - 3) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), rng:NextNumber(2.4, 4.2))
		end
		wp("snowBank", hull, CFrame.new(HX + rng:NextNumber(-140, 140), DECK, HZ + BEAM + 3) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), rng:NextNumber(2.0, 3.6))
	end
	-- the name, on the bow's south side and the transom
	local namePlate = box(hull, "NamePlate", XW + 6, XW + 46, 19, 23.4, FACE_Z - 0.55, FACE_Z - 0.05, PALETTE.hullBlack, PLATE, { CanCollide = false })
	if namePlate then
		SignKit.dress(namePlate, "AURORA MERIDIAN", { Enum.NormalId.Front })
	end
	local sternPlate = box(hull, "NamePlate", XE + 17.05, XE + 17.55, 19, 23.4, HZ - 14, HZ + 14, PALETTE.hullBlack, PLATE, { CanCollide = false })
	if sternPlate then
		SignKit.dress(sternPlate, "AURORA MERIDIAN", { Enum.NormalId.Right })
	end
	-- portholes along the black band, both sides; the anchor at the bow
	wp("portholeRow", hull, Vector3.new(XW + 8, 19, FACE_Z - 0.2), Vector3.new(GAP0 - 6, 19, FACE_Z - 0.2), 10)
	wp("portholeRow", hull, Vector3.new(GAP1 + 6, 19, FACE_Z - 0.2), Vector3.new(XE - 8, 19, FACE_Z - 0.2), 10)
	wp("portholeRow", hull, Vector3.new(XW + 8, 19, HZ + BEAM + 0.2), Vector3.new(XE - 8, 19, HZ + BEAM + 0.2), 10)
	wp("anchor", hull, CFrame.new(XW - 6, 14, FACE_Z - 1.5), 1.2)

	----------------------------------------------------------------
	-- THE SUPERSTRUCTURE: two decks of cabins, the bridge forward, the
	-- funnels, the masts, the boats on their davits, the rails.
	----------------------------------------------------------------
	local upper = Instance.new("Model")
	upper.Name = "Superstructure"
	upper.Parent = root
	local D1_X0, D1_X1 = HX - 74, HX + 84
	local D2_X0, D2_X1 = HX - 62, HX + 62
	box(upper, "DeckhouseA", D1_X0, D1_X1, DECK_Y, DECK_Y + 10, HZ - 22, HZ + 22, PALETTE.hullWhite, PLATE)
	box(upper, "DeckhouseB", D2_X0, D2_X1, DECK_Y + 10, DECK_Y + 19, HZ - 18, HZ + 18, PALETTE.hullWhite, PLATE)
	box(upper, "BoatDeck", D1_X0 - 2, D1_X1 + 2, DECK_Y + 10, DECK_Y + 10.6, HZ - 24, HZ + 24, PALETTE.timber, Enum.Material.WoodPlanks)
	box(upper, "TopDeck", D2_X0 - 2, D2_X1 + 2, DECK_Y + 19, DECK_Y + 19.6, HZ - 20, HZ + 20, PALETTE.timber, Enum.Material.WoodPlanks)
	-- the bridge, forward, with its window band
	box(upper, "Bridge", HX - 74, HX - 46, DECK_Y + 19, DECK_Y + 27, HZ - 17, HZ + 17, PALETTE.hullWhite, PLATE)
	box(upper, "BridgeWindows", HX - 74.2, HX - 45.8, DECK_Y + 22, DECK_Y + 25, HZ - 17.2, HZ + 17.2, dk(PALETTE.glassPale, 0.55), Enum.Material.SmoothPlastic,
		{ CanCollide = false, Reflectance = 0.25 })
	box(upper, "BridgeRoof", HX - 76, HX - 44, DECK_Y + 27, DECK_Y + 27.8, HZ - 19, HZ + 19, PALETTE.timberDark, Enum.Material.Wood)
	-- rows of cabin windows on the south faces of both deckhouses
	for x = D1_X0 + 6, D1_X1 - 6, 8 do
		trim(upper, "Window", Vector3.new(3, 3, 0.3), CFrame.new(x, DECK_Y + 5.5, HZ - 22.15), dk(PALETTE.glassPale, 0.5), Enum.Material.SmoothPlastic, { Reflectance = 0.2 })
	end
	for x = D2_X0 + 6, D2_X1 - 6, 8 do
		trim(upper, "Window", Vector3.new(3, 3, 0.3), CFrame.new(x, DECK_Y + 14.5, HZ - 18.15), dk(PALETTE.glassPale, 0.5), Enum.Material.SmoothPlastic, { Reflectance = 0.2 })
	end
	-- frost on the deckhouse roofs and icicles under their eaves
	frost(upper, "RoofFrost", Vector3.new(D1_X1 - D1_X0 - 4, 0.3, 40), CFrame.new((D1_X0 + D1_X1) * 0.5, DECK_Y + 10.8, HZ))
	frost(upper, "RoofFrost", Vector3.new(D2_X1 - D2_X0 - 4, 0.3, 34), CFrame.new((D2_X0 + D2_X1) * 0.5, DECK_Y + 19.8, HZ))
	wp("icicleCurtain", upper, Vector3.new(D1_X0, DECK_Y + 10, HZ - 24), Vector3.new(D1_X1, DECK_Y + 10, HZ - 24))
	wp("icicleCurtain", upper, Vector3.new(D2_X0, DECK_Y + 19, HZ - 20), Vector3.new(D2_X1, DECK_Y + 19, HZ - 20))
	-- funnels, one leaning; masts fore and aft
	wp("funnel", upper, CFrame.new(HX - 22, DECK_Y + 19.6, HZ), 34, 1)
	wp("funnel", upper, CFrame.new(HX + 28, DECK_Y + 19.6, HZ) * CFrame.Angles(0, 0, 0.1), 32, 2)
	wp("mast", upper, CFrame.new(HX - 104, DECK_Y, HZ), 52)
	wp("mast", upper, CFrame.new(HX + 108, DECK_Y, HZ) * CFrame.Angles(0.06, 0, 0), 44)
	-- lifeboats on davits along the boat deck, both sides
	for _, x in ipairs({ HX - 56, HX - 20, HX + 16, HX + 52 }) do
		wp("lifeboat", upper, CFrame.new(x, DECK_Y + 10.6, HZ - 21))
		wp("lifeboat", upper, CFrame.new(x, DECK_Y + 10.6, HZ + 21) * CFrame.Angles(0, math.pi, 0))
	end
	-- rails round the main deck and the boat deck
	wp("railingRun", upper, Vector3.new(XW + 2, DECK_Y, HZ - BEAM + 1), Vector3.new(D1_X0 - 3, DECK_Y, HZ - BEAM + 1))
	wp("railingRun", upper, Vector3.new(D1_X1 + 3, DECK_Y, HZ - BEAM + 1), Vector3.new(XE - 2, DECK_Y, HZ - BEAM + 1))
	wp("railingRun", upper, Vector3.new(XW + 2, DECK_Y, HZ + BEAM - 1), Vector3.new(XE - 2, DECK_Y, HZ + BEAM - 1))
	wp("railingRun", upper, Vector3.new(D1_X0 - 1, DECK_Y + 10.6, HZ - 23), Vector3.new(D1_X1 + 1, DECK_Y + 10.6, HZ - 23))
	wp("railingRun", upper, Vector3.new(D1_X0 - 1, DECK_Y + 10.6, HZ + 23), Vector3.new(D1_X1 + 1, DECK_Y + 10.6, HZ + 23))
	-- deck fittings
	for i, o in ipairs({ { -118, -10 }, { -112, 12 }, { 100, -8 }, { 112, 10 } }) do
		wp("ventilator", upper, CFrame.new(HX + o[1], DECK_Y, HZ + o[2]) * CFrame.Angles(0, i * 1.3, 0))
	end
	for i, o in ipairs({ { -124, -24 }, { -124, 24 }, { 122, -20 }, { 122, 20 }, { -90, -26 }, { 96, 26 } }) do
		wp("bollard", upper, CFrame.new(HX + o[1], DECK_Y, HZ + o[2]))
		if i % 2 == 0 then
			wp("ropeCoil", upper, CFrame.new(HX + o[1] + 4, DECK_Y, HZ + o[2] * 0.8))
		end
	end
	wp("deckCrateStack", upper, CFrame.new(HX + 108, DECK_Y, HZ + 2) * CFrame.Angles(0, 0.4, 0), 21)
	wp("deckCrateStack", upper, CFrame.new(HX - 96, DECK_Y, HZ - 6) * CFrame.Angles(0, -0.7, 0), 22)

	----------------------------------------------------------------
	-- THE APPROACH: the walk from the field's edge up to the breach.
	----------------------------------------------------------------
	local approach = Instance.new("Model")
	approach.Name = "Approach"
	approach.Parent = root
	-- the trodden path
	box(approach, "Path", DX - 9, DX + 9, DECK + 0.05, DECK + 0.14, MOUTH_Z - 6, FACE_Z - 8,
		dk(PALETTE.snow, 0.14), Enum.Material.Snow, { CanCollide = false })
	-- the gate at the mouth: two iron posts with a bent beam and the name
	for _, s in ipairs({ -1, 1 }) do
		box(approach, "GatePost", DX + s * 16 - 1.4, DX + s * 16 + 1.4, DECK, DECK + 15, MOUTH_Z - 1.4, MOUTH_Z + 1.4, IRON_DARK, PLATE)
		trim(approach, "GateRust", Vector3.new(1.2, 9, 0.12), CFrame.new(DX + s * 16, DECK + 6, MOUTH_Z - 1.5), dk(PALETTE.rust, 0.2), RUSTY)
		wp("bollard", approach, CFrame.new(DX + s * 22, DECK, MOUTH_Z + 6))
	end
	P(approach, "GateBeam", Vector3.new(38, 1.6, 1.6), CFrame.new(DX, DECK + 15.6, MOUTH_Z) * CFrame.Angles(0, 0, 0.03), IRON_DARK, PLATE, { CanCollide = false })
	local gateBoard = box(approach, "NameBoard", DX - 15, DX + 15, DECK + 16.6, DECK + 21, MOUTH_Z - 0.6, MOUTH_Z - 0.1, dk(PALETTE.hullWhite, 0.4), Enum.Material.Wood)
	if gateBoard then
		SignKit.dress(gateBoard, "THE FROZEN WRECK", { Enum.NormalId.Front, Enum.NormalId.Back })
	end
	wp("icicleCurtain", approach, Vector3.new(DX - 17, DECK + 14.8, MOUTH_Z), Vector3.new(DX + 17, DECK + 14.8, MOUTH_Z))
	ip("stringLights", approach, Vector3.new(DX - 15, DECK + 14.4, MOUTH_Z - 1.6), Vector3.new(DX + 15, DECK + 14.4, MOUTH_Z - 1.6), 10)
	-- lamps up both sides, alternately lit; fences behind them
	local litLamps = 0
	for i = 0, 4 do
		local z = MOUTH_Z + 14 + i * 40
		if z < FACE_Z - 14 then
			if ip("lampPost", approach, CFrame.new(DX - 14, DECK, z), 11, i % 2 == 0) and i % 2 == 0 then
				litLamps += 1
			end
			if ip("lampPost", approach, CFrame.new(DX + 14, DECK, z), 11, i % 2 == 1) and i % 2 == 1 then
				litLamps += 1
			end
		end
	end
	ip("ropeFence", approach, Vector3.new(DX - 20, DECK, MOUTH_Z + 6), Vector3.new(DX - 20, DECK, FACE_Z - 16))
	ip("ropeFence", approach, Vector3.new(DX + 20, DECK, MOUTH_Z + 6), Vector3.new(DX + 20, DECK, FACE_Z - 16))
	ip("signpost", approach, CFrame.new(DX + 26, DECK, MOUTH_Z - 10) * CFrame.Angles(0, -0.4, 0), { "THE WRECK", "SNOWFIELD" })
	-- wreckage that came off her: a boat on the snow, crates, a barrel
	wp("lifeboat", approach, CFrame.new(DX - 44, DECK + 1, MOUTH_Z + 70) * CFrame.Angles(0.2, 0.9, 0.5))
	wp("deckCrateStack", approach, CFrame.new(DX + 36, DECK, MOUTH_Z + 96) * CFrame.Angles(0, 0.5, 0), 23)
	wp("barrel", approach, CFrame.new(DX + 30, DECK, MOUTH_Z + 84))
	wp("barrel", approach, CFrame.new(DX - 32, DECK, MOUTH_Z + 120))
	for i = 1, 6 do
		ip("snowDrift", approach, CFrame.new(DX + (i % 2 == 0 and 30 or -30) + rng:NextNumber(-4, 4), DECK, MOUTH_Z + 20 + i * 34)
			* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), rng:NextNumber(1.0, 1.6))
	end

	----------------------------------------------------------------
	-- THE BREACH: the door, in the south hull face. Two hull plates that
	-- slide apart behind torn jambs -- the Magma Chamber's door in iron.
	----------------------------------------------------------------
	local door = Instance.new("Model")
	door.Name = "Door"
	door.Parent = root

	box(door, "Threshold", DX - 16, DX + 16, DECK - 0.6, DECK + 0.6, FACE_Z - 8, FACE_Z, PALETTE.iron, PLATE)
	frost(door, "ThresholdFrost", Vector3.new(31, 0.12, 7.4), CFrame.new(DX, DECK + 0.66, FACE_Z - 4))
	box(door, "Step", DX - 18, DX + 18, DECK - 0.6, DECK + 0.2, FACE_Z - 10.4, FACE_Z - 8, IRON_DARK, PLATE)

	-- the recess behind the leaves: the hold's own dark, with light down the back
	local recess = Instance.new("Model")
	recess.Name = "Recess"
	recess.Parent = door
	local R_Z0, R_Z1 = FACE_Z + 0.9, FACE_Z + 6.5
	box(recess, "Floor", DX - 13, DX + 13, DECK - 0.6, DECK + 0.15, R_Z0, R_Z1, dk(PALETTE.timber, 0.4), Enum.Material.WoodPlanks)
	for _, sx in ipairs({ -1, 1 }) do
		local x0 = DX + math.min(sx * 13, sx * 15.4)
		local x1 = DX + math.max(sx * 13, sx * 15.4)
		box(recess, "Side", x0, x1, DECK, DOOR_TOP + 2, R_Z0, R_Z1, IRON_DARK, PLATE)
	end
	box(recess, "Head", DX - 15.4, DX + 15.4, DOOR_TOP, DOOR_TOP + 2.4, R_Z0, R_Z1, IRON_DARK, PLATE)
	box(recess, "Back", DX - 13, DX + 13, DECK - 0.6, DOOR_TOP + 2, R_Z1, R_Z1 + 0.8, dk(PALETTE.iron, 0.6), PLATE)
	glowIce(recess, "Crack", Vector3.new(1.6, DOOR_TOP - DECK - 2, 0.4), CFrame.new(DX, DECK + (DOOR_TOP - DECK) * 0.5, R_Z1 - 0.25), 0.2)
	local throat = glowIce(recess, "Floorlight", Vector3.new(22, 0.3, R_Z1 - R_Z0 - 1), CFrame.new(DX, DECK + 0.2, (R_Z0 + R_Z1) * 0.5), 0.3)
	glow(throat, PALETTE.iceGlow, 34, 1.3)

	-- the torn jambs: plating peeled outward, just SOUTH of the leaves' plane,
	-- so an open leaf hides behind one
	local JZ0, JZ1 = FACE_Z - 2.9, FACE_Z - 1.1
	for _, sx in ipairs({ -1, 1 }) do
		local x0 = DX + math.min(sx * 13, sx * 27)
		local x1 = DX + math.max(sx * 13, sx * 27)
		box(door, "Jamb", x0, x1, DECK, DOOR_TOP + 3, JZ0, JZ1, PALETTE.iron, PLATE)
		box(door, "JambFace", x0 + 0.4, x1 - 0.4, DECK + 1.2, DOOR_TOP + 1.6, JZ0 - 0.5, JZ0, dk(PALETTE.rust, 0.1), RUSTY)
		for k = 1, 3 do
			trim(door, "Tear", Vector3.new(2.6, 4 + k * 1.2, 1.2), CFrame.new(DX + sx * (13 + k * 0.6), DECK + 2 + k * 4.4, JZ0 - 0.3)
				* CFrame.Angles(0, 0, sx * (0.25 + k * 0.1)), dk(PALETTE.iron, 0.4), RUSTY)
		end
		glowIce(door, "JambSeam", Vector3.new(0.8, DOOR_TOP - DECK - 4, 0.35), CFrame.new(DX + sx * 14.6, DECK + (DOOR_TOP - DECK) * 0.5, JZ0 - 0.55), 0.35)
	end
	box(door, "Lintel", DX - 29, DX + 29, DOOR_TOP + 3, DOOR_TOP + 8, JZ0 - 0.4, FACE_Z + 0.9, PALETTE.iron, PLATE)
	box(door, "LintelCap", DX - 30.6, DX + 30.6, DOOR_TOP + 8, DOOR_TOP + 9.6, JZ0 - 1, FACE_Z + 1.2, IRON_DARK, PLATE)
	frost(door, "LintelFrost", Vector3.new(61, 0.4, 5), CFrame.new(DX, DOOR_TOP + 9.85, (JZ0 + FACE_Z) * 0.5))
	wp("icicleCurtain", door, Vector3.new(DX - 28, DOOR_TOP + 3, JZ0 - 0.6), Vector3.new(DX + 28, DOOR_TOP + 3, JZ0 - 0.6))
	local brow = glowIce(door, "LintelSeam", Vector3.new(56, 0.5, 1), CFrame.new(DX, DOOR_TOP + 3.1, JZ0 - 0.3), 0.15)
	glow(brow, PALETTE.iceGlow, 30, 1.0)

	-- the leaves, and everything bolted to them slides with them
	local leaves = {}
	local panel = {}
	for k, sx in ipairs({ -1, 1 }) do
		local l = P(door, "Leaf" .. (k == 1 and "W" or "E"),
			Vector3.new(DOOR_HX, DOOR_TOP - DECK, 1.8),
			CFrame.new(DX + sx * DOOR_HX * 0.5, DECK + (DOOR_TOP - DECK) * 0.5, FACE_Z),
			dk(PALETTE.iron, 0.15), RUSTY, { Reflectance = 0.08 })
		leaves[k] = l
		table.insert(panel, { part = l, dir = sx })
		-- rivet lines and a rust run on each face
		for i = 1, 3 do
			local t = (i - 0.5) / 3
			local row = trim(door, "RivetRow", Vector3.new(DOOR_HX * 0.8, 0.5, 0.25),
				CFrame.new(DX + sx * DOOR_HX * 0.5, DECK + (DOOR_TOP - DECK) * t, FACE_Z - 0.95), IRON_DARK, PLATE)
			table.insert(panel, { part = row, dir = sx })
		end
		local run = trim(door, "LeafRust", Vector3.new(1.1, (DOOR_TOP - DECK) * 0.7, 0.12),
			CFrame.new(DX + sx * (DOOR_HX * 0.5 + 1.6), DECK + (DOOR_TOP - DECK) * 0.42, FACE_Z - 0.97), dk(PALETTE.rust, 0.2), RUSTY)
		table.insert(panel, { part = run, dir = sx })
		-- half a frozen seam each, so the seal leaves with the leaves
		local seam = glowIce(door, "Seal", Vector3.new(0.25, DOOR_TOP - DECK - 1.4, 0.3),
			CFrame.new(DX + sx * 0.125, DECK + (DOOR_TOP - DECK) * 0.5, FACE_Z - 0.95), 0.3)
		table.insert(panel, { part = seam, dir = sx })
	end

	-- the plate over the door: what you read once you are standing at it
	do
		local b = trim(door, "DoorPlate", Vector3.new(26, 3.2, 0.5),
			CFrame.new(DX, DOOR_TOP + 5.4, JZ0 - 0.9), dk(PALETTE.hullWhite, 0.45), Enum.Material.Wood, { CanQuery = false })
		SignKit.dress(b, "HOLD No. 3", { Enum.NormalId.Front })
	end

	----------------------------------------------------------------
	-- Working the door
	----------------------------------------------------------------
	-- cold breathes out when it opens
	local mistHost = P(door, "MistHost", Vector3.new(DOOR_HX * 2, 1, 1),
		CFrame.new(DX, DECK + 1, FACE_Z - 1.4), PALETTE.frost, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false })
	local mist = Instance.new("ParticleEmitter")
	mist.Name = "Breath"
	mist.Texture = "rbxasset://textures/particles/smoke_main.dds"
	mist.Color = ColorSequence.new(Color3.fromRGB(224, 238, 248), Color3.fromRGB(180, 206, 226))
	mist.LightEmission = 0.15
	mist.Rate = 0
	mist.Lifetime = NumberRange.new(2.2, 4.0)
	mist.Speed = NumberRange.new(3, 7)
	mist.SpreadAngle = Vector2.new(30, 12)
	mist.Acceleration = Vector3.new(0, 0.6, -2.5)
	mist.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 12) })
	mist.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(0.45, 0.75), NumberSequenceKeypoint.new(1, 1),
	})
	mist.EmissionDirection = Enum.NormalId.Front
	mist.Parent = mistHost

	-- the light that comes OUT when it opens; zero until then
	local spillHost = P(door, "SpillHost", Vector3.new(1, 1, 1),
		CFrame.new(DX, DECK + 8, FACE_Z - 3), PALETTE.iceGlow, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false })
	local spill = glow(spillHost, PALETTE.iceGlow, 60, 0)

	local grind = Instance.new("Sound")
	grind.SoundId = SND_WHOOSH
	grind.Volume = 0.55
	grind.PlaybackSpeed = 0.55      -- iron on ice: lower again than the rock
	grind.RollOffMaxDistance = 150
	grind.Parent = leaves[1]
	local refuseSnd = Instance.new("Sound")
	refuseSnd.SoundId = SND_WHOOSH
	refuseSnd.Volume = 0.4
	refuseSnd.PlaybackSpeed = 0.42
	refuseSnd.RollOffMaxDistance = 110
	refuseSnd.Parent = leaves[1]

	-- the hint, repainted per player by Vault_Client off the attributes below
	local hint = Instance.new("BillboardGui")
	hint.Name = "DoorHint"
	hint.Size = UDim2.new(0, 250, 0, 58)
	hint.StudsOffsetWorldSpace = Vector3.new(0, 5, -7)
	hint.MaxDistance = 110
	hint.Parent = leaves[1]
	local hintLabel = Instance.new("TextLabel")
	hintLabel.Size = UDim2.fromScale(1, 1)
	hintLabel.Text = "TAP TO ENTER"
	hintLabel.Parent = hint
	pcall(function()
		SignKit.floating(hintLabel, PALETTE.iceGlow)
	end)
	hintLabel:SetAttribute("RequireRebirths", Wreck.REBIRTHS)
	hintLabel:SetAttribute("OpenText", hintLabel.Text)
	hintLabel:SetAttribute("OpenTint", hintLabel.TextColor3)
	local hintEdge = hintLabel:FindFirstChildOfClass("UIStroke")
	if hintEdge then
		hintLabel:SetAttribute("OpenEdge", hintEdge.Color)
	end

	local homeCF = {}
	for _, e in ipairs(panel) do
		homeCF[e.part] = e.part.CFrame
	end
	local SLIDE = DOOR_HX - 0.4
	local DOOR_TIME, DOOR_LEAD, AUTO_CLOSE = 1.8, 0.3, 9
	local isOpen, moving, epoch = false, false, 0

	local function moveAll(open: boolean, info: TweenInfo)
		local last
		for _, e in ipairs(panel) do
			last = TweenService:Create(e.part, info,
				{ CFrame = homeCF[e.part] + Vector3.new(open and e.dir * SLIDE or 0, 0, 0) })
			last:Play()
		end
		return last
	end

	local function slide(open: boolean)
		moving = true
		isOpen = open
		hint.Enabled = not open
		if open then
			task.wait(DOOR_LEAD)
			mist:Emit(40)
			mist.Rate = 6
			TweenService:Create(spill, TweenInfo.new(1.6), { Brightness = 2.4 }):Play()
		else
			mist.Rate = 0
			TweenService:Create(spill, TweenInfo.new(1.2), { Brightness = 0 }):Play()
		end
		grind.TimePosition = 0
		grind:Play()
		local tw = moveAll(open, TweenInfo.new(DOOR_TIME, Enum.EasingStyle.Quart,
			open and Enum.EasingDirection.Out or Enum.EasingDirection.InOut))
		tw.Completed:Connect(function()
			moving = false
		end)
		-- one unconditional release, in case a tween never completes
		task.delay(DOOR_TIME + 2, function()
			moving = false
		end)
	end

	-- refused: the leaves strain against the ice and settle back
	local function refuse()
		if moving then
			return
		end
		moving = true
		refuseSnd:Play()
		local strain
		for _, e in ipairs(panel) do
			strain = TweenService:Create(e.part, TweenInfo.new(0.13, Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out), { CFrame = homeCF[e.part] + Vector3.new(e.dir * 0.5, 0, 0) })
			strain:Play()
		end
		strain.Completed:Connect(function()
			local back = moveAll(false, TweenInfo.new(0.55, Enum.EasingStyle.Elastic,
				Enum.EasingDirection.Out))
			back.Completed:Connect(function()
				moving = false
			end)
		end)
		task.delay(2.5, function()
			moving = false
		end)
	end

	local function doorwayClear(): boolean
		for _, plr in ipairs(Players:GetPlayers()) do
			local char = plr.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp then
				local d = hrp.Position - Vector3.new(DX, DECK + 5, FACE_Z)
				if math.abs(d.X) < DOOR_HX + 3 and math.abs(d.Z) < 9 and math.abs(d.Y) < 14 then
					return false
				end
			end
		end
		return true
	end

	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = 44
	click.Parent = leaves[1]
	local click2 = Instance.new("ClickDetector")
	click2.MaxActivationDistance = 44
	click2.Parent = leaves[2]

	local function onClick(plr)
		if moving or isOpen then
			return
		end
		-- GATED HERE, on the server, off the Rebirths attribute ProgressionServer writes.
		local have = plr:GetAttribute("Rebirths") or 0
		if have < Wreck.REBIRTHS then
			Net:FireClient(plr, "DoorLocked", Wreck.REBIRTHS, have, ISL.name)
			refuse()
			return
		end
		slide(true)
		Wreck.enter(plr, Vector3.new(DX, DECK + 8, FACE_Z))

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
	end
	click.MouseClick:Connect(onClick)
	click2.MouseClick:Connect(onClick)

	-- WHERE LEAVING PUTS THEM: at the mouth of the approach, looking up it at the door.
	Wreck.returnCF = CFrame.lookAt(
		Vector3.new(DX, DECK + 3.5, MOUTH_Z - 6),
		Vector3.new(DX, DECK + 3.5, MOUTH_Z + 26))
	root:SetAttribute("ReturnAt", Wreck.returnCF)

	-- turn the approach's lights down (the kit's lamps are sized for open snow)
	do
		local dimmed = 0
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("PointLight") or d:IsA("SpotLight") or d:IsA("SurfaceLight") then
				d.Brightness *= 0.55
				d.Range *= 0.7
				d.Shadows = false
				dimmed += 1
			end
		end
		local sp = root:FindFirstChild("Door")
		sp = sp and sp:FindFirstChild("SpillHost")
		sp = sp and sp:FindFirstChildOfClass("PointLight")
		if sp then
			sp.Range = 60
		end
		print(("[Wreck] approach lighting: %d sources trimmed to 55%%/70%%"):format(dimmed))
	end

	-- and prove the approach never reached the host island's field
	do
		local fz1 = PEN.cz + PEN.half + 2
		local fx0, fx1 = PEN.cx - PEN.half - 2, PEN.cx + PEN.half + 2
		local bad = {}
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("BasePart") and d.CanCollide then
				local p, cf, sz = d.Position, d.CFrame, d.Size
				local halfZ = 0.5 * (math.abs(cf.RightVector.Z) * sz.X
					+ math.abs(cf.UpVector.Z) * sz.Y
					+ math.abs(cf.LookVector.Z) * sz.Z)
				if p.Z - halfZ < fz1 and p.X > fx0 and p.X < fx1 then
					table.insert(bad, d)
				end
			end
		end
		for _, d in ipairs(bad) do
			d.CFrame = d.CFrame + Vector3.new(0, 0, 6)
			warn(("[Wreck] %s overhung Penguin Island's rakeable field and was pushed north"):format(d:GetFullName()))
		end
	end

	-- every part anchored, thin/neon/clear parts not casting
	local partCount = 0
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			partCount += 1
			d.Anchored = true
			if d.CastShadow and (math.min(d.Size.X, d.Size.Y, d.Size.Z) < 1.0
				or d.Material == Enum.Material.Neon or d.Transparency > 0.5) then
				d.CastShadow = false
			end
		end
	end

	print(string.format("[Wreck] penguin portal built: %d parts, %d lamps lit, %d props moved off the approach, %d prop failures",
		partCount, litLamps, moved, propFails))
	return root
end

----------------------------------------------------------------
-- The transition: the tomb's "Cinema" message, both directions.
----------------------------------------------------------------
local function travel(plr: Player, target: CFrame, caption: string, kind: string, sub: string?)
	local char = plr.Character
	if not char or not char.PrimaryPart then
		return
	end

	Net:FireClient(plr, "Cinema", "out", caption, kind, sub)

	-- ask for the destination to stream in while the screen is still fading
	task.spawn(function()
		pcall(function()
			plr:RequestStreamAroundAsync(target.Position, 10)
		end)
	end)

	task.delay(Wreck.BEAT + Wreck.FADE, function()
		local c = plr.Character
		if not c or not c.PrimaryPart then
			Net:FireClient(plr, "Cinema", "in", "leave")
			return
		end
		c:PivotTo(target)
		pcall(function()
			plr:RequestStreamAroundAsync(target.Position, 6)
		end)
		task.wait(Wreck.HOLD)
		Net:FireClient(plr, "Cinema", "in", kind)
	end)
end

function Wreck.enter(plr: Player, subject: Vector3?)
	travel(plr, ENTRY, "THE FROZEN WRECK", "enter", "SHE HAS BEEN WAITING A LONG WINTER")
end

function Wreck.leave(plr: Player)
	travel(plr, Wreck.returnCF or FALLBACK_RETURN, "", "leave")
end

return Wreck
