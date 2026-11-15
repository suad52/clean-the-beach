--[[
	VaultBuilder  --  ServerScriptService.VaultBuilder  (ModuleScript)

	THE TREASURE CHAMBER. What is behind the pyramid door: a sealed Egyptian hall
	with a floor buried in gold, which the player sweeps clean with the same
	sifter they use on the beaches.

	It is Config.ISLANDS[3] -- a third rakeable field, not a special case. The
	server grid, the per-player progress, the finds, the sell pad and the clear
	bonus are all the machinery the beaches already use; the only things unique to
	it are the room built around the field and the litter set it draws from
	(ReplicatedStorage.CTB.Treasure, built below, instead of the washed-up cans).

	WHERE IT IS. At (3000, 0) on the same y = 3 plane as the other two fields,
	because Config.Y_MIN/Y_MAX and occupancyFor are shared and every field has to
	sit in the same voxel band. It is nowhere near the pyramid it is supposedly
	under -- but it is sealed on all six sides and the only way in is the
	cinematic, so that never shows.

	THE TRANSITION lives here too (Vault.enter / Vault.leave), rather than in
	Island2Builder with the door, so that both directions of the same fade are
	written once, in one place.
]]

local Vault = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local CTB = ReplicatedStorage:WaitForChild("CTB")
local Config = require(CTB:WaitForChild("Config"))
local Net = CTB:WaitForChild("Net")

local Terrain = workspace.Terrain

----------------------------------------------------------------
-- Dimensions
----------------------------------------------------------------
local ISL = Config.island(3)
local CX, CZ = ISL.cx, ISL.cz
local GROUND = ISL.cleanY

-- Interior. The rakeable field is CX/CZ +- 64, so there is a clear 36 studs of
-- floor on each side and 66 front and back for the columns, statues and dais to
-- stand on without any of them being inside sand the player has to sweep.
local X0, X1 = CX - 100, CX + 100
local Z0, Z1 = CZ - 130, CZ + 130
local CEIL = GROUND + 43
local WALL = 6

-- The far end lifts into a shrine. See the shell in Vault.build for why.
local ALCOVE_Z = 100                     -- where the ceiling steps up
local ALCOVE_CEIL = CEIL + 22

-- The skylight, and therefore the hole the ceiling soffit has to leave for it.
-- Declared up here because the shell leaves the opening and the light itself is
-- built two hundred lines further down: two literals that far apart is exactly
-- how you end up with a soffit laid over the only window in the room.
local SHAFT_Z, SHAFT_HALF = 46, 13

-- Where the cinematic puts you down, facing the length of the hall.
local ENTRY = CFrame.lookAt(Vector3.new(CX, GROUND + 3.5, Z0 + 18), Vector3.new(CX, GROUND + 3.5, Z0 + 40))

-- Where leaving the tomb puts you. CTB_Server sets Vault.returnCF once both
-- builders have run (see the wiring block at the bottom of that script).
--
-- The fallback is applied at CALL time rather than as a default assigned here,
-- so that whichever of these two modules loads first cannot overwrite the real
-- plaza with it. Nobody may be sealed in a room with no way out, so leave()
-- always has an answer even if that wiring is ever missed.
local FALLBACK_RETURN = CFrame.new(0, 6, -150)

--[[
	How many rebirths the tomb asks for. Read by Island2Builder for the door and
	published onto the island root as TombRebirths, which is what Island2_Client
	and Vault_Client draw the lock state from -- so this one number is the whole
	gate and nothing else has to move with it.

	FIVE, up from two. Two put the richest room in the game (resetBonus 5,000, a
	pool that pays about 140 a find against the beach's 26) alongside the Dunes,
	which open before the first rebirth -- so the tomb was effectively the second
	destination and its payout was a step change arriving far too early.

	Pitched between the two shores either side of it now: Sakura Cove asks three
	and Ashfall asks ten (FerryConfig.Ports), so the tomb sits in the gap that
	opens up between them.
]]
Vault.REBIRTHS = 5

-- Cinematic timings live in Config so the client fades on exactly the numbers
-- the server teleports on. See the note there for why this is not a handshake.
Vault.BEAT = Config.CINEMA.beat
Vault.FADE = Config.CINEMA.fade
Vault.HOLD = Config.CINEMA.hold

----------------------------------------------------------------
-- Palette, taken off the reference: deep teal walls, gold everything,
-- lapis and carnelian inlay, sandstone for the plain stone.
----------------------------------------------------------------
local TEAL = Color3.fromRGB(26, 84, 102)
local TEAL_DEEP = Color3.fromRGB(17, 58, 72)
local TEAL_LIGHT = Color3.fromRGB(42, 122, 138)
local GOLD = Color3.fromRGB(242, 196, 84)
local GOLD_DEEP = Color3.fromRGB(198, 148, 46)
local SANDSTONE = Color3.fromRGB(226, 180, 112)
local SAND_DARK = Color3.fromRGB(180, 136, 78)
local LAPIS = Color3.fromRGB(40, 78, 150)
local CARNELIAN = Color3.fromRGB(178, 68, 46)
local TURQUOISE = Color3.fromRGB(60, 168, 158)
local OBSIDIAN = Color3.fromRGB(34, 32, 40)

local SND_AMBIENCE = "rbxassetid://9125602882"   -- eerie choral tones, verified to load
local SND_WHOOSH = "rbxassetid://9125742262"     -- airy whoosh, for the transition

----------------------------------------------------------------
-- Builders
----------------------------------------------------------------
local function P(parent, name, size, cf, colour, material, extra)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = colour or SANDSTONE
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

local function box(parent, name, x0, x1, y0, y1, z0, z1, colour, material, extra)
	if x1 - x0 < 0.05 or y1 - y0 < 0.05 or z1 - z0 < 0.05 then
		return nil
	end
	return P(parent, name,
		Vector3.new(x1 - x0, y1 - y0, z1 - z0),
		CFrame.new((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5),
		colour, material, extra)
end

-- Local-space helper: build around a CFrame so statues and columns can be
-- placed and turned without every number being rewritten.
local function lp(parent, name, base, size, offset, colour, material, extra)
	return P(parent, name, size, base * offset, colour, material, extra)
end

----------------------------------------------------------------
-- The treasure litter set
--
-- ReplicatedStorage.CTB.Treasure, cloned by CTB_Client for island 3 the same
-- way it clones the trash meshes for the beaches. Every entry is a single
-- BasePart, because the sink and raise tweens drive one part directly.
--
-- Only Block and Ball shapes. Cylinder was the obvious choice for a stack of
-- coins, but a Part cylinder's axis runs along its LOCAL X and the litter
-- scatter overwrites each prop's CFrame outright -- so every cylinder would
-- come out lying on its side no matter how the template was saved. Squashed
-- balls read as heaped coins at this size anyway.
----------------------------------------------------------------
local TREASURE = {
	{ "CoinPileSmall", Vector3.new(1.5, 0.5, 1.5), GOLD, Enum.Material.Metal, 0.25, Enum.PartType.Ball },
	{ "CoinPileLarge", Vector3.new(2.3, 0.75, 2.3), GOLD, Enum.Material.Metal, 0.25, Enum.PartType.Ball },
	{ "CoinPileWide", Vector3.new(2.9, 0.55, 2.2), GOLD_DEEP, Enum.Material.Metal, 0.22, Enum.PartType.Ball },
	{ "GoldNugget", Vector3.new(0.9, 0.75, 0.9), GOLD, Enum.Material.Metal, 0.3, Enum.PartType.Ball },
	{ "Ingot", Vector3.new(1.7, 0.45, 0.95), GOLD, Enum.Material.Metal, 0.28, Enum.PartType.Block },
	{ "IngotStack", Vector3.new(1.5, 0.75, 0.9), GOLD_DEEP, Enum.Material.Metal, 0.28, Enum.PartType.Block },
	{ "GemLapis", Vector3.new(0.85, 0.8, 0.85), LAPIS, Enum.Material.Glass, 0.35, Enum.PartType.Ball },
	{ "GemCarnelian", Vector3.new(0.8, 0.75, 0.8), CARNELIAN, Enum.Material.Glass, 0.35, Enum.PartType.Ball },
	{ "GemTurquoise", Vector3.new(0.9, 0.8, 0.9), TURQUOISE, Enum.Material.Glass, 0.35, Enum.PartType.Ball },
	{ "Scarab", Vector3.new(1.1, 0.45, 1.4), LAPIS, Enum.Material.SmoothPlastic, 0.1, Enum.PartType.Block },
	{ "Amulet", Vector3.new(1.2, 0.25, 1.2), GOLD, Enum.Material.Metal, 0.3, Enum.PartType.Block },
	{ "Potsherd", Vector3.new(1.0, 0.35, 1.3), SAND_DARK, Enum.Material.Slate, 0, Enum.PartType.Block },

	-- The showpieces. Rarer on the floor only in the sense that there are four of
	-- them against twelve, but they are what the eye lands on: a floor of nothing
	-- but coin heaps reads as one texture, and a tomb should look looted-rich
	-- rather than tiled.
	{ "Diadem", Vector3.new(1.7, 0.5, 1.7), GOLD, Enum.Material.Metal, 0.45, Enum.PartType.Block },
	{ "Chalice", Vector3.new(1.0, 1.5, 1.0), GOLD_DEEP, Enum.Material.Metal, 0.4, Enum.PartType.Ball },
	{ "MaskShard", Vector3.new(1.35, 1.5, 0.5), GOLD, Enum.Material.Metal, 0.5, Enum.PartType.Block },
	{ "GemRuby", Vector3.new(0.85, 0.85, 0.85), Color3.fromRGB(196, 44, 58), Enum.Material.Glass, 0.4, Enum.PartType.Ball },
}

local function buildTreasureSet()
	local old = CTB:FindFirstChild("Treasure")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "Treasure"
	folder.Parent = CTB

	for _, t in ipairs(TREASURE) do
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
		p.Parent = folder
	end
	return #TREASURE
end

----------------------------------------------------------------
-- Statues
--
-- One body, two heads. The pharaoh and the jackal-headed Anubis share
-- everything from the neck down, which is both how Egyptian statuary actually
-- works and how six of these get built without six times the code.
--
-- `scale` multiplies every size and offset, so the hero on the dais is the same
-- statue as the ones against the wall rather than a second copy of the code.
----------------------------------------------------------------
local function statue(parent, base: CFrame, kind: string, scale: number)
	local m = Instance.new("Model")
	m.Name = (kind == "anubis") and "AnubisStatue" or "PharaohStatue"
	m.Parent = parent

	local skin = (kind == "anubis") and OBSIDIAN or GOLD_DEEP
	local function b(name, sx, sy, sz, ox, oy, oz, colour, material, extra)
		return lp(m, name, base,
			Vector3.new(sx, sy, sz) * scale,
			CFrame.new(ox * scale, oy * scale, oz * scale),
			colour, material, extra)
	end
	local SHINE = { Reflectance = 0.18 }
	local BRIGHT = { Reflectance = 0.3 }

	b("Plinth", 8, 2.4, 6, 0, 1.2, 0, SAND_DARK, Enum.Material.Slate)
	b("PlinthTop", 7, 0.6, 5.2, 0, 2.7, 0, SANDSTONE)
	b("PlinthGlyph", 5, 1.1, 0.3, 0, 1.5, -3.05, GOLD, Enum.Material.Metal)

	b("Legs", 4.2, 12, 3.2, 0, 9, 0, skin, Enum.Material.Metal, SHINE)
	b("LegSplit", 0.35, 7, 0.4, 0, 7, -1.7, TEAL_DEEP, Enum.Material.SmoothPlastic)
	b("Kilt", 4.5, 4.4, 3.5, 0, 12.8, 0.15, GOLD, Enum.Material.Metal, BRIGHT)
	b("KiltBand", 4.7, 0.9, 3.7, 0, 15.2, 0.15, LAPIS, Enum.Material.SmoothPlastic)

	b("Torso", 4.6, 9, 3.2, 0, 19.6, 0, skin, Enum.Material.Metal, SHINE)
	b("Collar", 4.9, 2.3, 3.4, 0, 23.1, 0, GOLD, Enum.Material.Metal, BRIGHT)
	b("CollarInlay", 3.4, 0.9, 3.5, 0, 23.1, 0.06, TURQUOISE, Enum.Material.SmoothPlastic)
	for _, s in ipairs({ -1, 1 }) do
		b("Arm", 1.3, 8.6, 2.2, s * 2.9, 19.2, 0, skin, Enum.Material.Metal, SHINE)
		b("Fist", 1.5, 1.8, 2.6, s * 2.9, 15.2, -0.7, skin, Enum.Material.Metal, SHINE)
	end
	b("Neck", 1.7, 1.6, 1.7, 0, 24.9, 0, skin, Enum.Material.Metal)

	if kind == "anubis" then
		-- jackal: a narrow head pulled forward into a snout, and tall flat ears.
		-- The ears are what makes it read as Anubis rather than as a dog.
		b("Head", 2.6, 3.4, 3.2, 0, 27.4, 0.2, skin, Enum.Material.Metal, SHINE)
		b("Snout", 1.5, 1.5, 3.2, 0, 26.9, -2.6, skin, Enum.Material.Metal, SHINE)
		b("Nose", 0.9, 0.7, 0.6, 0, 27.2, -4.1, OBSIDIAN, Enum.Material.SmoothPlastic)
		for _, s in ipairs({ -1, 1 }) do
			b("Ear", 0.7, 4.6, 1.7, s * 1.1, 31.2, 0.6, skin, Enum.Material.Metal, SHINE)
			b("EarInner", 0.4, 3.2, 1.1, s * 1.05, 30.8, 0.2, LAPIS, Enum.Material.SmoothPlastic)
			b("Eye", 0.5, 0.5, 0.3, s * 0.8, 27.9, -1.5, GOLD, Enum.Material.Metal, BRIGHT)
		end
		b("NemesBack", 3.4, 5, 1.6, 0, 26.5, 2.2, GOLD, Enum.Material.Metal, BRIGHT)
	else
		b("Head", 2.8, 3.6, 2.8, 0, 27.4, 0, skin, Enum.Material.Metal, SHINE)
		b("NemesBack", 3.6, 6, 1.8, 0, 26.6, 1.9, GOLD, Enum.Material.Metal, BRIGHT)
		for _, s in ipairs({ -1, 1 }) do
			b("Lappet", 1.2, 5.6, 2.6, s * 2, 26.4, -0.4, GOLD, Enum.Material.Metal, BRIGHT)
			b("LappetStripe", 1.3, 0.8, 2.7, s * 2, 27.6, -0.4, LAPIS, Enum.Material.SmoothPlastic)
			b("Eye", 0.6, 0.5, 0.3, s * 0.75, 27.9, -1.45, OBSIDIAN, Enum.Material.SmoothPlastic)
		end
		b("NemesCap", 3.6, 2.2, 3.2, 0, 29.8, 0, GOLD, Enum.Material.Metal, BRIGHT)
		b("BrowBand", 3.7, 1, 0.4, 0, 28.9, -1.45, LAPIS, Enum.Material.SmoothPlastic)
		b("Uraeus", 0.7, 2, 0.6, 0, 29.8, -1.55, GOLD, Enum.Material.Metal, BRIGHT)
		b("Beard", 1, 3, 1, 0, 24.6, -1.5, GOLD, Enum.Material.Metal, BRIGHT)
	end

	return m
end

----------------------------------------------------------------
-- Columns and torches
----------------------------------------------------------------
local function column(parent, x: number, z: number)
	local m = Instance.new("Model")
	m.Name = "Column"
	m.Parent = parent
	local base = CFrame.new(x, GROUND, z)
	local function b(name, size, offset, colour, material, extra)
		return lp(m, name, base, size, offset, colour, material, extra)
	end

	b("Base", Vector3.new(9.4, 2, 9.4), CFrame.new(0, 1, 0), SAND_DARK, Enum.Material.Slate)
	b("Plinth", Vector3.new(8.2, 1.2, 8.2), CFrame.new(0, 2.6, 0), SANDSTONE)
	b("Shaft", Vector3.new(6.4, 33, 6.4), CFrame.new(0, 19.7, 0), SANDSTONE)
	-- painted bands, the way real Egyptian columns are banded rather than fluted
	for i = 0, 2 do
		b("Band", Vector3.new(6.6, 1.2, 6.6), CFrame.new(0, 9 + i * 9, 0),
			(i % 2 == 0) and LAPIS or CARNELIAN, Enum.Material.SmoothPlastic)
	end
	b("GoldRing", Vector3.new(6.8, 1, 6.8), CFrame.new(0, 34.8, 0), GOLD, Enum.Material.Metal,
		{ Reflectance = 0.28 })
	-- lotus capital
	b("Capital", Vector3.new(9.6, 4, 9.6), CFrame.new(0, 37.3, 0), SANDSTONE)
	b("Abacus", Vector3.new(10.6, 1.6, 10.6), CFrame.new(0, 40.1, 0), GOLD_DEEP, Enum.Material.Metal,
		{ Reflectance = 0.2 })
	return m
end

local function torch(parent, cf: CFrame)
	local m = Instance.new("Model")
	m.Name = "Torch"
	m.Parent = parent
	lp(m, "Bracket", cf, Vector3.new(0.8, 0.8, 2.2), CFrame.new(0, -1.4, -0.9), GOLD_DEEP, Enum.Material.Metal)
	local bowl = lp(m, "Bowl", cf, Vector3.new(2.6, 1.5, 2.6), CFrame.new(0, 0, -1.8), GOLD,
		Enum.Material.Metal, { Reflectance = 0.25 })

	local fire = Instance.new("Fire")
	fire.Heat = 3
	fire.Size = 4
	fire.Color = Color3.fromRGB(255, 192, 96)
	fire.SecondaryColor = Color3.fromRGB(196, 100, 32)
	fire.Parent = bowl

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 184, 108)
	light.Range = 30
	light.Brightness = 1.4
	light.Shadows = false      -- a dozen shadow-casting lights in one room is not worth it
	light.Parent = bowl
	return m
end

----------------------------------------------------------------
-- Floor
--
-- Same two-step as the desert plateau: fill to a whole voxel boundary, then
-- write the top layer at the field's own occupancy. Fill* rounds to whole
-- voxels and smooth terrain renders its surface at the centre of the first
-- non-full voxel, so filling "to y = 3" would actually come out at y = 6 and
-- leave the rakeable square in a pit.
----------------------------------------------------------------
local function buildFloor()
	local fx0, fx1 = 2872, 3128
	local fz0, fz1 = -156, 156

	Terrain:FillBlock(
		CFrame.new((fx0 + fx1) * 0.5, 40, (fz0 + fz1) * 0.5),
		Vector3.new(fx1 - fx0 + 40, 160, fz1 - fz0 + 40), Enum.Material.Air)
	Terrain:FillBlock(
		CFrame.new((fx0 + fx1) * 0.5, -10, (fz0 + fz1) * 0.5),
		Vector3.new(fx1 - fx0, 20, fz1 - fz0), ISL.matMessy)

	local _, o3 = Config.occupancyFor(GROUND)
	local nx = (fx1 - fx0) // Config.VOXEL
	local nz = (fz1 - fz0) // Config.VOXEL
	local region = Region3.new(
		Vector3.new(fx0, 0, fz0),
		Vector3.new(fx1, Config.VOXEL, fz1)
	):ExpandToGrid(Config.VOXEL)

	local mats, occs = table.create(nx), table.create(nx)
	for xi = 1, nx do
		local mx, ox = { table.create(nz) }, { table.create(nz) }
		mats[xi], occs[xi] = mx, ox
		for zi = 1, nz do
			mx[1][zi], ox[1][zi] = ISL.matMessy, o3
		end
	end
	Terrain:WriteVoxels(region, Config.VOXEL, mats, occs)
end

----------------------------------------------------------------
-- Build
----------------------------------------------------------------
function Vault.build()
	local old = workspace:FindFirstChild("Vault")
	if old then
		old:Destroy()
	end
	local root = Instance.new("Folder")
	root.Name = "Vault"
	root.Parent = workspace

	local props = buildTreasureSet()
	buildFloor()

	----------------------------------------------------------------
	-- Shell: six sealed sides. Nobody is meant to know this room is standing
	-- on its own 1500 studs east of the desert.
	----------------------------------------------------------------
	local shell = Instance.new("Model")
	shell.Name = "Shell"
	shell.Parent = root

	--[[
		Six sealed sides -- with the far end raised into an alcove.

		WHY. The hero statue is what the entire hall points at, and at 1.75 scale
		on a nine-stud platform its head stood at y = 64 in a room whose ceiling is
		at 46: eighteen studs of pharaoh standing outside the building, in open
		void. It never showed, because the light shaft used to sit directly on top
		of it and blow that whole end of the room to white -- and it showed the
		instant the shaft moved and the statue was turned round to face the player.

		Shrinking it to fit would have made the hero exactly the size of the eight
		statues lining the walls, which is the one thing it must not be. So the
		room opens up instead: past z = 100 the ceiling lifts by 22 and the
		colonnade's architrave stops, which reads as walking out of a hall and into
		a shrine at the end of it.

		SEALED IS STILL SEALED. Every side wall runs to ALCOVE_CEIL over the bay's
		z range and to CEIL over the hall's, the two ceiling slabs meet the walls
		at their own heights, and the only opening is the vertical face at z = 100
		between the two -- which is interior, and is the mouth of the alcove.
	]]
	local TOP = CEIL + WALL
	local ALCOVE_TOP = ALCOVE_CEIL + WALL

	box(shell, "WallN", X0 - WALL, X1 + WALL, GROUND, ALCOVE_CEIL, Z1, Z1 + WALL, TEAL,
		Enum.Material.Slate)
	box(shell, "WallS", X0 - WALL, X1 + WALL, GROUND, CEIL, Z0 - WALL, Z0, TEAL, Enum.Material.Slate)
	for _, w in ipairs({ { X0 - WALL, X0, "W" }, { X1, X1 + WALL, "E" } }) do
		box(shell, "Wall" .. w[3], w[1], w[2], GROUND, CEIL, Z0, ALCOVE_Z, TEAL, Enum.Material.Slate)
		box(shell, "Wall" .. w[3] .. "Alcove", w[1], w[2], GROUND, ALCOVE_CEIL, ALCOVE_Z, Z1, TEAL,
			Enum.Material.Slate)
	end
	box(shell, "Ceiling", X0 - WALL, X1 + WALL, CEIL, TOP, Z0 - WALL, ALCOVE_Z, TEAL_DEEP,
		Enum.Material.Slate)
	box(shell, "CeilingAlcove", X0 - WALL, X1 + WALL, ALCOVE_CEIL, ALCOVE_TOP, ALCOVE_Z, Z1 + WALL,
		TEAL_DEEP, Enum.Material.Slate)

	--[[
		A STONE SOFFIT UNDER BOTH CEILINGS, AND THE ONLY HOLE IN IT IS THE SKYLIGHT.

		The shell's ceiling slabs are TEAL_DEEP -- (17,58,72), a dark blue-green --
		and seen from the hall, through the arch and over the hero statue's head,
		thirty studs of that colour reads as open night sky. The room is genuinely
		sealed: two thousand rays cast straight up from every part of both floors
		hit stone, and none reach the world. But it does not LOOK sealed, and that
		is the same bug from where the player is standing -- it was reported as an
		opening you can see the sky through, next to the statue's head.

		So the underside of the roof is sandstone with gold ribs, and the one place
		it opens is kerbed, which is what makes a hole read as a hole rather than as
		a lamp stuck to a ceiling.
	]]
	local SOFFIT = 0.7
	local function soffit(name, x0, x1, z0, z1)
		box(shell, name, x0, x1, CEIL - SOFFIT, CEIL, z0, z1, SANDSTONE, Enum.Material.Sandstone)
	end
	-- Four panels around the shaft's square rather than one slab with a hole in
	-- it: there is no CSG here and there does not need to be.
	soffit("Soffit", X0, X1, Z0, SHAFT_Z - SHAFT_HALF)
	soffit("Soffit", X0, X1, SHAFT_Z + SHAFT_HALF, ALCOVE_Z)
	soffit("Soffit", X0, CX - SHAFT_HALF, SHAFT_Z - SHAFT_HALF, SHAFT_Z + SHAFT_HALF)
	soffit("Soffit", CX + SHAFT_HALF, X1, SHAFT_Z - SHAFT_HALF, SHAFT_Z + SHAFT_HALF)
	-- The alcove's own. THIS is the panel that was reading as sky.
	box(shell, "SoffitAlcove", X0, X1, ALCOVE_CEIL - SOFFIT, ALCOVE_CEIL, ALCOVE_Z, Z1,
		SANDSTONE, Enum.Material.Sandstone)

	--[[
		AND THE BAY'S WALLS WITH IT.

		Ceiling alone was not enough. Standing on the carpet you look THROUGH the
		arch, and what fills the frame around the hero's head is the alcove's back
		and upper side walls -- all of them TEAL, all of them unlit, and between the
		two raised light sources the bay reads as a dark opening rather than as the
		inside of a shrine. Facing them in the same sandstone as the roof is what
		finally closes it: the statue now stands against a wall you can see is a
		wall.

		Facings rather than repainting the shell: the shell is the sealed box and
		has one job, and the hall's own teal is still correct everywhere the eye
		actually reaches it.
	]]
	box(shell, "AlcoveBack", X0, X1, GROUND, ALCOVE_CEIL - SOFFIT, Z1 - 0.7, Z1,
		SANDSTONE, Enum.Material.Sandstone)
	box(shell, "AlcoveFace", X0, X0 + 0.7, GROUND, ALCOVE_CEIL - SOFFIT,
		ALCOVE_Z, Z1, SANDSTONE, Enum.Material.Sandstone)
	box(shell, "AlcoveFace", X1 - 0.7, X1, GROUND, ALCOVE_CEIL - SOFFIT,
		ALCOVE_Z, Z1, SANDSTONE, Enum.Material.Sandstone)
	-- Gold pilaster strips either side of where the statue stands, so the back of
	-- the shrine has a centre and the figure is standing IN something.
	for _, s in ipairs({ -1, 1 }) do
		box(shell, "AlcovePilaster", CX + s * 26 - 2.2, CX + s * 26 + 2.2, GROUND,
			ALCOVE_CEIL - SOFFIT, Z1 - 1.5, Z1 - 0.7, GOLD_DEEP, Enum.Material.Metal,
			{ Reflectance = 0.2 })
	end
	box(shell, "AlcoveLintel", CX - 30, CX + 30, ALCOVE_CEIL - SOFFIT - 3.2,
		ALCOVE_CEIL - SOFFIT, Z1 - 1.5, Z1 - 0.7, LAPIS, Enum.Material.SmoothPlastic)

	-- Ribs, so two hundred studs of ceiling is not one flat plane. None of them
	-- fall between z 33 and 59, which is the shaft's own square.
	for _, rz in ipairs({ -104, -68, -32, 4, 76 }) do
		box(shell, "Rib", X0, X1, CEIL - SOFFIT - 0.9, CEIL - SOFFIT, rz - 1.4, rz + 1.4,
			GOLD_DEEP, Enum.Material.Metal, { Reflectance = 0.2 })
	end
	for _, rz in ipairs({ 109, 121 }) do
		box(shell, "RibAlcove", X0, X1, ALCOVE_CEIL - SOFFIT - 0.9, ALCOVE_CEIL - SOFFIT,
			rz - 1.4, rz + 1.4, GOLD_DEEP, Enum.Material.Metal, { Reflectance = 0.2 })
	end

	-- The kerb. Gives the opening a thickness you can see the edge of.
	for _, k in ipairs({
		{ CX - SHAFT_HALF - 1.3, CX - SHAFT_HALF, SHAFT_Z - SHAFT_HALF - 1.3, SHAFT_Z + SHAFT_HALF + 1.3 },
		{ CX + SHAFT_HALF, CX + SHAFT_HALF + 1.3, SHAFT_Z - SHAFT_HALF - 1.3, SHAFT_Z + SHAFT_HALF + 1.3 },
		{ CX - SHAFT_HALF, CX + SHAFT_HALF, SHAFT_Z - SHAFT_HALF - 1.3, SHAFT_Z - SHAFT_HALF },
		{ CX - SHAFT_HALF, CX + SHAFT_HALF, SHAFT_Z + SHAFT_HALF, SHAFT_Z + SHAFT_HALF + 1.3 },
	}) do
		box(shell, "SkylightKerb", k[1], k[2], CEIL - SOFFIT - 1.7, CEIL, k[3], k[4],
			SAND_DARK, Enum.Material.Sandstone)
	end

	-- The mouth, framed. A ceiling that simply stops reads as a hole; a header
	-- across it reads as an arch you are walking under.
	box(shell, "AlcoveArch", X0 - 0.5, X1 + 0.5, CEIL, CEIL + 3.4, ALCOVE_Z - 1.6, ALCOVE_Z + 1.6,
		SAND_DARK, Enum.Material.Sandstone)
	box(shell, "AlcoveArchGold", X0 - 1, X1 + 1, CEIL + 3.4, CEIL + 4.6, ALCOVE_Z - 2.2,
		ALCOVE_Z + 2.2, GOLD_DEEP, Enum.Material.Metal, { Reflectance = 0.2 })

	-- a dado of darker teal and a gold rail, so 43 studs of wall is not one flat
	-- colour from floor to ceiling
	for _, w in ipairs({
		{ X0 - 0.4, X0 + 0.4, Z0, Z1 }, { X1 - 0.4, X1 + 0.4, Z0, Z1 },
	}) do
		box(shell, "Dado", w[1], w[2], GROUND, GROUND + 7, w[3], w[4], TEAL_DEEP, Enum.Material.Slate)
		box(shell, "Rail", w[1] - 0.2, w[2] + 0.2, GROUND + 7, GROUND + 8, w[3], w[4], GOLD_DEEP,
			Enum.Material.Metal, { Reflectance = 0.2 })
		box(shell, "Frieze", w[1] - 0.2, w[2] + 0.2, CEIL - 4, CEIL - 2.6, w[3], w[4], GOLD_DEEP,
			Enum.Material.Metal, { Reflectance = 0.2 })
	end
	for _, w in ipairs({
		{ Z0 - 0.4, Z0 + 0.4 }, { Z1 - 0.4, Z1 + 0.4 },
	}) do
		box(shell, "Dado", X0, X1, GROUND, GROUND + 7, w[1], w[2], TEAL_DEEP, Enum.Material.Slate)
		box(shell, "Rail", X0, X1, GROUND + 7, GROUND + 8, w[1] - 0.2, w[2] + 0.2, GOLD_DEEP,
			Enum.Material.Metal, { Reflectance = 0.2 })
	end

	----------------------------------------------------------------
	-- Hieroglyph panels
	----------------------------------------------------------------
	local glyphs = Instance.new("Model")
	glyphs.Name = "Hieroglyphs"
	glyphs.Parent = root
	local grng = Random.new(Config.SEED + 8801)
	local GLYPH_COLOURS = { GOLD, LAPIS, CARNELIAN, TURQUOISE, SANDSTONE }

	for _, side in ipairs({ -1, 1 }) do
		local wx = (side < 0) and X0 or X1
		for _, cz in ipairs({ -108, -76, -44, -12, 20, 52, 84, 116 }) do
			box(glyphs, "Panel", wx - 0.5 * side - 0.35, wx - 0.5 * side + 0.35,
				GROUND + 9, GROUND + 24, cz - 6, cz + 6, SANDSTONE, Enum.Material.Sandstone,
				{ CanCollide = false })
			for row = 0, 4 do
				local c = GLYPH_COLOURS[grng:NextInteger(1, #GLYPH_COLOURS)]
				local w = grng:NextNumber(1.6, 4.4)
				box(glyphs, "Glyph", wx - 0.5 * side - 0.55, wx - 0.5 * side + 0.55,
					GROUND + 10.4 + row * 2.7, GROUND + 12.2 + row * 2.7,
					cz - w * 0.5, cz + w * 0.5, c, Enum.Material.SmoothPlastic, { CanCollide = false })
			end
		end
	end

	----------------------------------------------------------------
	-- Columns, torches, wall statues
	----------------------------------------------------------------
	local hall = Instance.new("Model")
	hall.Name = "Hall"
	hall.Parent = root

	local COL_X = { CX - 78, CX + 78 }
	local COL_Z = { -96, -48, 0, 48, 96 }
	for _, x in ipairs(COL_X) do
		for _, z in ipairs(COL_Z) do
			column(hall, x, z)
			-- torch on the inward face, at eye-catching height
			local facing = (x < CX) and 1 or -1
			torch(hall, CFrame.new(x + facing * 3.4, GROUND + 20, z)
				* CFrame.Angles(0, facing > 0 and 0 or math.pi, 0))
		end
	end

	-- Architrave across the tops of each colonnade. It stops at the alcove
	-- mouth: running on into the bay would leave two beams crossing open air
	-- twenty studs below its ceiling.
	for _, x in ipairs(COL_X) do
		box(hall, "Architrave", x - 5.6, x + 5.6, GROUND + 41, CEIL, -112, ALCOVE_Z,
			SAND_DARK, Enum.Material.Sandstone)
	end

	-- Statues between the columns, alternating pharaoh and jackal -- and every
	-- one of them TURNED IN, square onto the centre line.
	--
	-- They used to face ALONG the hall: one rank toward the door, the other
	-- toward the dais. That is the arrangement that reads worst from the only
	-- place anybody actually stands. Walking the carpet you never saw a face --
	-- eight statues showed you eight shoulders, in profile, the whole way up.
	--
	-- Squared onto the walkway they are head-on for its entire length, and the
	-- spots below sit BETWEEN the COL_Z values on purpose, so each one sights
	-- clean through a gap in the colonnade rather than into a column's back.
	--
	-- The body is modelled facing local -Z, so -pi/2 turns the west rank to face
	-- +X and +pi/2 turns the east rank to face -X. One expression, both inward.
	--[[
		AND WHAT THEY SAY.

		Eight guardians standing in silence are scenery. Eight with a line each are
		a reason to walk down the side of the hall instead of straight up the middle
		of the carpet -- which, with the treasure scattered across the whole floor,
		is where the player should be going anyway.

		The words ride on the model as an ATTRIBUTE. The server owns them and
		Vault_Client only draws them, so there is no remote, nothing to keep in
		sync, and a statue with no line simply gets no bubble -- which is what the
		hero on the dais wants: it is the thing you walk towards, not a talker.
	]]
	local VOICES = {
		"The scales weigh what you carry. Do not arrive light.",
		"Three thousand years sealed in here, and you brought a rake.",
		"Everything buried here was somebody's. Now it is the desert's.",
		"Take the gold. Leave the sand tidy.",
		"I have counted every grain in this room. You are behind.",
		"The tide never reached us. The sandstorm always does.",
		"Nothing leaves this hall uncleaned.",
		"Even kings end up under litter. Ours was better made.",
	}

	local voiceN = 0
	local statueSpots = { -72, -24, 24, 72 }
	for _, side in ipairs({ -1, 1 }) do
		local sx = CX + side * 91
		for i, z in ipairs(statueSpots) do
			local kind = ((i + (side > 0 and 1 or 0)) % 2 == 0) and "anubis" or "pharaoh"
			local m = statue(hall, CFrame.new(sx, GROUND, z) * CFrame.Angles(0, side * math.pi * 0.5, 0),
				kind, 1)
			voiceN += 1
			m:SetAttribute("Says", VOICES[voiceN])
			m:SetAttribute("SaysName", (kind == "anubis") and "ANUBIS" or "THE KING")
			-- Where the bubble hangs. Built from the BASE this statue was placed at,
			-- not from m:GetPivot() -- these models have no PrimaryPart, so GetPivot
			-- hands back the bounding-box CENTRE, which for a 31-stud figure standing
			-- on the floor is halfway up its own chest. Adding a head's height to that
			-- put every bubble at y 46, in the ceiling.
			--
			-- The body is modelled facing local -Z and the rank is turned inward, so
			-- -side is the way it is looking: the bubble goes in FRONT of the face,
			-- over the walkway the player is actually on.
			m:SetAttribute("SaysAt", Vector3.new(sx - side * 6, GROUND + 33, z))
		end
	end

	----------------------------------------------------------------
	-- The dais at the far end, and what stands on it
	----------------------------------------------------------------
	local dais = Instance.new("Model")
	dais.Name = "Dais"
	dais.Parent = root

	for i = 0, 3 do
		box(dais, "Step" .. i, CX - 40 + i * 2, CX + 40 - i * 2,
			GROUND + i * 1.8, GROUND + (i + 1) * 1.8, 88 + i * 3, 130, SANDSTONE)
	end
	box(dais, "Platform", CX - 34, CX + 34, GROUND + 7.2, GROUND + 8.4, 100, 130, SAND_DARK,
		Enum.Material.Slate)
	box(dais, "PlatformTrim", CX - 35, CX + 35, GROUND + 8.4, GROUND + 9, 100, 130, GOLD_DEEP,
		Enum.Material.Metal, { Reflectance = 0.2 })

	-- The hero: the same statue, nearly twice the size, and the thing every
	-- sightline in the room ends on. It faces the DOOR.
	--
	-- The statue is modelled facing local -Z and the entrance is at -Z from here,
	-- so facing the player is no rotation at all. It used to carry a pi turn,
	-- which stood fifty studs of pharaoh with its back to the room: the player
	-- crossed the whole hall to be ignored by the one figure that was supposed to
	-- be waiting for them.
	-- 1.6, which is what the alcove will take: the statue is ~31 studs tall at
	-- scale 1, it stands on a platform at GROUND + 9, and ALCOVE_CEIL is 68. That
	-- puts its crown at 61 with six studs of shadow above it. Raise the scale and
	-- it goes through the roof again -- literally, and invisibly, because nothing
	-- in here reports it.
	statue(dais, CFrame.new(CX, GROUND + 9, 116), "pharaoh", 1.6)

	-- One soft light high in the bay, so the head is modelled rather than lost:
	-- the uplights below throw everything upward and leave the face in its own
	-- shadow, which on the one statue meant to be looking at you is backwards.
	local crownLight = P(dais, "AlcoveLight", Vector3.new(1, 1, 1),
		CFrame.new(CX, CEIL + 6, 108), Color3.new(1, 1, 1), Enum.Material.Neon,
		{ Transparency = 1, CanCollide = false, CanQuery = false })
	local cl = Instance.new("PointLight")
	cl.Color = Color3.fromRGB(255, 222, 168)
	cl.Range = 46
	cl.Brightness = 1.1
	cl.Shadows = false
	cl.Parent = crownLight

	-- A second, higher fill for the bay's ROOF. The crown light above is aimed at
	-- the statue's face and dies well short of ALCOVE_CEIL, so the new sandstone
	-- soffit up there would have read as an unlit slab -- which is most of the way
	-- back to reading as a hole again. A ceiling has to be visibly a ceiling.
	local bayLight = P(dais, "AlcoveRoofLight", Vector3.new(1, 1, 1),
		CFrame.new(CX, ALCOVE_CEIL - 9, 116), Color3.new(1, 1, 1), Enum.Material.Neon,
		{ Transparency = 1, CanCollide = false, CanQuery = false })
	local bl = Instance.new("PointLight")
	bl.Color = Color3.fromRGB(255, 214, 158)
	bl.Range = 40
	bl.Brightness = 1.4
	bl.Shadows = false
	bl.Parent = bayLight
	-- flanking braziers on the platform
	for _, s in ipairs({ -1, 1 }) do
		torch(dais, CFrame.new(CX + s * 24, GROUND + 13, 106))
		box(dais, "BrazierStem", CX + s * 24 - 0.7, CX + s * 24 + 0.7, GROUND + 9, GROUND + 13,
			104.2, 105.6, GOLD_DEEP, Enum.Material.Metal)
	end

	-- Two uplights at the front of the platform, low and warm, aimed up the
	-- statue. With the skylight moved off the dais this is what MODELS it --
	-- gold picking out the collar, the nemes and the face -- instead of the flat
	-- overhead blast that used to erase all three.
	for _, s in ipairs({ -1, 1 }) do
		local up = P(dais, "StatueUplight", Vector3.new(1.6, 0.5, 1.6),
			CFrame.new(CX + s * 9, GROUND + 9.3, 108), Color3.fromRGB(255, 206, 132),
			Enum.Material.Neon, { CanCollide = false, CanQuery = false, Transparency = 0.35 })
		local l = Instance.new("PointLight")
		l.Color = Color3.fromRGB(255, 198, 126)
		l.Range = 34
		l.Brightness = 1.5
		l.Shadows = false
		l.Parent = up
	end

	----------------------------------------------------------------
	-- Carpet, and the shaft of light down the middle of it
	----------------------------------------------------------------
	box(root, "Carpet", CX - 13, CX + 13, GROUND, GROUND + 0.22, Z0 + 2, 92, TEAL_LIGHT,
		Enum.Material.Fabric, { CanCollide = false })
	for _, s in ipairs({ -1, 1 }) do
		box(root, "CarpetTrim", CX + s * 11.4, CX + s * 12.6, GROUND, GROUND + 0.26, Z0 + 2, 92,
			GOLD_DEEP, Enum.Material.Metal, { CanCollide = false })
	end

	--[[
		Skylight. NOT an actual opening -- there is nothing above this room but
		empty world -- so it is an emissive grille with a beam faked underneath.

		IT IS OVER THE CARPET NOW, NOT OVER THE DAIS. At z = 112 it stood four
		studs off the hero statue and pointed thirty studs of white Neon straight
		down onto it: the far end of the hall was a blown-out white wall and the
		statue in front of it was a silhouette with no face. That was survivable
		while the statue faced away, and stopped being survivable the moment it
		was turned round to look at the player -- the one thing it is FOR is the
		face. Moved to z = 46 it lights the walk instead, the statue is modelled
		by its own braziers and the uplights below, and the shaft is something the
		player walks THROUGH on the way to it.

		The beams are also thinner and far more transparent than they were.
		Neon ignores lighting, so a "0.88 transparent" slab 40 studs wide still
		reads as solid white paint over whatever is behind it.
	]]
	local shaftZ = SHAFT_Z
	box(root, "Skylight", CX - SHAFT_HALF, CX + SHAFT_HALF, CEIL - 0.4, CEIL, shaftZ - SHAFT_HALF, shaftZ + SHAFT_HALF,
		Color3.fromRGB(236, 214, 172), Enum.Material.Neon, { CanCollide = false })
	for i = 0, 5 do
		local spread = 1 + i * 0.13
		box(root, "Beam" .. i, CX - 11 * spread, CX + 11 * spread,
			CEIL - (i + 1) * 6.4, CEIL - i * 6.4,
			shaftZ - 11 * spread, shaftZ + 11 * spread,
			Color3.fromRGB(255, 240, 200), Enum.Material.Neon,
			{ CanCollide = false, CanQuery = false, Transparency = 0.945 + i * 0.009 })
	end
	local shaftLight = P(root, "ShaftLight", Vector3.new(1, 1, 1),
		CFrame.new(CX, GROUND + 22, shaftZ), Color3.new(1, 1, 1), Enum.Material.Neon,
		{ Transparency = 1, CanCollide = false })
	local sl = Instance.new("PointLight")
	sl.Color = Color3.fromRGB(255, 234, 194)
	sl.Range = 54
	sl.Brightness = 1.5
	sl.Parent = shaftLight

	----------------------------------------------------------------
	-- Hoard: the big set pieces. The RAKEABLE gold is scattered by the client
	-- from the Treasure set; these are the immovable piles and chests that make
	-- the room look like a hoard even once the floor has been swept.
	----------------------------------------------------------------
	local hoard = Instance.new("Model")
	hoard.Name = "Hoard"
	hoard.Parent = root
	local hrng = Random.new(Config.SEED + 3141)

	local function chest(cf)
		lp(hoard, "ChestBody", cf, Vector3.new(6, 3.4, 4), CFrame.new(0, 1.7, 0),
			Color3.fromRGB(122, 82, 44), Enum.Material.Wood)
		lp(hoard, "ChestLid", cf, Vector3.new(6.3, 1.4, 4.3), CFrame.new(0, 3.9, -0.9),
			Color3.fromRGB(138, 94, 52), Enum.Material.Wood, { CanCollide = false })
		lp(hoard, "ChestBand", cf, Vector3.new(6.4, 0.7, 4.4), CFrame.new(0, 2.4, 0), GOLD_DEEP,
			Enum.Material.Metal, { Reflectance = 0.25, CanCollide = false })
		lp(hoard, "ChestSpill", cf, Vector3.new(5.2, 1.6, 5.2), CFrame.new(0, 3.5, 1.4), GOLD,
			Enum.Material.Metal, { Reflectance = 0.3, Shape = Enum.PartType.Ball, CanCollide = false })
	end

	-- along the two side aisles, clear of the rakeable square (x 2936..3064)
	for _, side in ipairs({ -1, 1 }) do
		for _, z in ipairs({ -96, -48, 0, 48, 96 }) do
			local x = CX + side * (hrng:NextNumber(70, 84))
			if hrng:NextNumber() < 0.45 then
				chest(CFrame.new(x, GROUND, z + hrng:NextNumber(-9, 9))
					* CFrame.Angles(0, hrng:NextNumber(0, 6.28), 0))
			else
				local r = hrng:NextNumber(4, 7.5)
				P(hoard, "GoldHeap", Vector3.new(r * 2, r * 0.75, r * 1.7),
					CFrame.new(x, GROUND + r * 0.2, z + hrng:NextNumber(-10, 10)),
					hrng:NextNumber() < 0.5 and GOLD or GOLD_DEEP, Enum.Material.Metal,
					{ Reflectance = 0.28, Shape = Enum.PartType.Ball, CanCollide = false })
			end
		end
	end
	-- and a drift of it spilling down the dais steps
	for i = 1, 10 do
		local r = hrng:NextNumber(2.4, 5)
		P(hoard, "GoldHeap", Vector3.new(r * 2, r * 0.7, r * 1.6),
			CFrame.new(CX + hrng:NextNumber(-32, 32), GROUND + r * 0.18, hrng:NextNumber(84, 100)),
			GOLD, Enum.Material.Metal, { Reflectance = 0.3, Shape = Enum.PartType.Ball, CanCollide = false })
	end

	----------------------------------------------------------------
	-- The scales: this room's sell pad, so a bag filled in here does not have to
	-- be carried back out through the cinematic to be worth anything.
	----------------------------------------------------------------
	local scales = Instance.new("Model")
	scales.Name = "ScalesOfAnubis"
	scales.Parent = root
	local SZ = -96

	box(scales, "Table", CX - 11, CX + 11, GROUND, GROUND + 4.6, SZ + 5, SZ + 12, SAND_DARK,
		Enum.Material.Slate)
	box(scales, "TableTop", CX - 12, CX + 12, GROUND + 4.6, GROUND + 5.4, SZ + 4.4, SZ + 12.6,
		SANDSTONE)
	box(scales, "Post", CX - 0.5, CX + 0.5, GROUND + 5.4, GROUND + 16, SZ + 8, SZ + 9, GOLD_DEEP,
		Enum.Material.Metal, { Reflectance = 0.2 })
	box(scales, "Beam", CX - 8, CX + 8, GROUND + 15.4, GROUND + 16.2, SZ + 8, SZ + 9, GOLD,
		Enum.Material.Metal, { Reflectance = 0.3 })
	for _, s in ipairs({ -1, 1 }) do
		box(scales, "Chain", CX + s * 7 - 0.15, CX + s * 7 + 0.15, GROUND + 11.5, GROUND + 15.4,
			SZ + 8.2, SZ + 8.8, GOLD_DEEP, Enum.Material.Metal)
		P(scales, "Pan", Vector3.new(5, 0.9, 5),
			CFrame.new(CX + s * 7, GROUND + 11.2, SZ + 8.5), GOLD, Enum.Material.Metal,
			{ Reflectance = 0.3, Shape = Enum.PartType.Ball, CanCollide = false })
	end
	-- Turned to face the pad rather than the wall behind it -- the weigher of
	-- hearts should be looking at whoever is putting something on the scales.
	statue(scales, CFrame.new(CX - 22, GROUND, SZ + 8) * CFrame.Angles(0, -math.pi * 0.5, 0), "anubis", 0.8)

	local pad = P(scales, "SellPad", Vector3.new(20, 0.45, 13),
		CFrame.new(CX, GROUND + 0.22, SZ), GOLD, Enum.Material.Sandstone)
	P(scales, "PadGlow", Vector3.new(20.7, 0.2, 13.7),
		CFrame.new(CX, GROUND + 0.06, SZ), Color3.fromRGB(255, 226, 140), Enum.Material.Neon,
		{ CanCollide = false, Transparency = 0.35 })

	----------------------------------------------------------------
	-- The way out
	----------------------------------------------------------------
	local exitM = Instance.new("Model")
	exitM.Name = "Exit"
	exitM.Parent = root
	local EZ = Z0 + 6

	for _, s in ipairs({ -1, 1 }) do
		box(exitM, "Jamb", CX + s * 9 - 3, CX + s * 9 + 3, GROUND, GROUND + 20, EZ - 2, EZ + 2,
			SANDSTONE)
		box(exitM, "JambBand", CX + s * 9 - 3.2, CX + s * 9 + 3.2, GROUND + 12, GROUND + 13.4,
			EZ - 2.2, EZ + 2.2, LAPIS, Enum.Material.SmoothPlastic)
	end
	box(exitM, "Lintel", CX - 14, CX + 14, GROUND + 20, GROUND + 24, EZ - 2.4, EZ + 2.4, SAND_DARK)
	box(exitM, "LintelGold", CX - 15, CX + 15, GROUND + 24, GROUND + 25.4, EZ - 3, EZ + 3, GOLD_DEEP,
		Enum.Material.Metal, { Reflectance = 0.2 })
	box(exitM, "Veil", CX - 6, CX + 6, GROUND + 0.4, GROUND + 19.6, EZ - 0.3, EZ + 0.3,
		TURQUOISE, Enum.Material.Neon, { CanCollide = false, Transparency = 0.62 })

	local exitPad = P(exitM, "Pad", Vector3.new(13, 0.5, 10),
		CFrame.new(CX, GROUND + 0.25, EZ + 7), TURQUOISE, Enum.Material.Neon, { Transparency = 0.5 })
	local leave = Instance.new("ProximityPrompt")
	leave.Name = "LeavePrompt"
	leave.ActionText = "Leave"
	leave.ObjectText = "The Tomb"
	leave.HoldDuration = 0.5
	leave.MaxActivationDistance = 14
	leave.RequiresLineOfSight = false
	leave.Parent = exitPad
	leave.Triggered:Connect(function(plr)
		Vault.leave(plr)
	end)

	print(string.format("[Vault] treasure chamber built: %d treasure types, %d parts",
		props, #root:GetDescendants()))

	return pad
end

----------------------------------------------------------------
-- The transition
--
-- Both directions of the same fade, written once. The timings are constants
-- shared with Vault_Client rather than a handshake: the client fades on its own
-- clock and the server teleports on its own, so a dropped acknowledgement can
-- never leave somebody staring at a black screen.
----------------------------------------------------------------
-- `kind` is "enter" or "leave", and it is the client's cue for how much of a
-- production to make of it: the way in gets the push-in, the slam, the title and
-- the crane, the way out gets a plain fade. Passed rather than inferred from the
-- caption, because "there is no caption" is a thin thing to hang a cutscene on.
local function travel(plr: Player, target: CFrame, caption: string, kind: string)
	local char = plr.Character
	if not char or not char.PrimaryPart then
		return
	end

	Net:FireClient(plr, "Cinema", "out", caption, kind)

	-- Ask for the destination to stream in WHILE the screen is still fading.
	-- StreamingEnabled is on and these two places are 1500+ studs apart, so
	-- without this the fade lifts on an empty void for a second or two.
	task.spawn(function()
		pcall(function()
			plr:RequestStreamAroundAsync(target.Position, 10)
		end)
	end)

	task.delay(Vault.BEAT + Vault.FADE, function()
		local c = plr.Character
		if not c or not c.PrimaryPart then
			-- Died or left mid-fade. Lift the screen so they are not stuck in
			-- black -- and as "leave", because there is no arrival to reveal and
			-- the plain fade is the one that also hands the camera straight back.
			Net:FireClient(plr, "Cinema", "in", "leave")
			return
		end
		c:PivotTo(target)
		pcall(function()
			plr:RequestStreamAroundAsync(target.Position, 6)
		end)
		task.wait(Vault.HOLD)
		Net:FireClient(plr, "Cinema", "in", kind)
	end)
end

function Vault.enter(plr: Player)
	travel(plr, ENTRY, "THE TOMB OF THE SUN KING", "enter")
end

function Vault.leave(plr: Player)
	-- Resolved now, not at load: see the note on FALLBACK_RETURN. Nobody may be
	-- left sealed in a room with no exit, so this always has an answer.
	travel(plr, Vault.returnCF or FALLBACK_RETURN, "", "leave")
end

return Vault
