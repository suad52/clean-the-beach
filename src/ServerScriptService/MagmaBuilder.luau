--[[
	MagmaBuilder  --  ServerScriptService.MagmaBuilder  (ModuleScript)

	THE MAGMA CHAMBER. What is behind the door cut into Ashfall's volcano: a
	sealed lava-tube hall with a floor buried in ash and cinder, which the player
	digs out with the same sifter they use on the beaches.

	It is Config.ISLANDS[7] -- a seventh rakeable field, not a special case. The
	server grid, the per-player progress, the finds, the sell pad and the clear
	bonus are all machinery the beaches already use; the only things unique to it
	are the cavern built around the field and the litter set it draws from
	(ReplicatedStorage.CTB.Cinder, built below).

	MODELLED ON THE INNER SHRINE, which was itself modelled on the tomb. If
	anything here reads oddly, check ShrineBuilder first and VaultBuilder after
	that -- it is probably the same decision, already argued out twice.

	ONE FILE, BOTH SIDES, the shrine's arrangement rather than the tomb's split.
	The reason is the same one the shrine had and then some: Island4Builder
	REBUILDS its island from code every boot and destroys workspace.Island4 on
	the way in, so geometry parented under there would not survive to the second
	boot -- and terrain poured into the cone would be poured over. The portal is
	therefore its own root model in workspace, built AFTER Island4Builder has
	finished with the mountain.

	WHERE THE ROOM IS. At (3000, -1500), on the same y = 3 plane as every other
	field, because Config.Y_MIN/Y_MAX and occupancyFor are shared and all seven
	fields have to sit in the same voxel band. It is nowhere near the volcano it
	is supposedly inside -- but it is sealed on all six sides and the only way in
	is the cinematic, so that never shows. Verified empty before it was claimed:
	no parts within 400 studs and not one solid voxel in a 49-point probe.

	TWO THINGS THIS ROOM DOES DIFFERENTLY FROM THE OTHER TWO INTERIORS, and both
	are the same argument turned around rather than a departure for its own sake.

	  IT IS DUG, NOT SWEPT (crust = true). The tomb and the shrine both set
	  crust = false with the same sentence -- "there is no loose layer on a
	  temple floor". There is one on the floor of a lava tube: ash and cinder
	  fall out of the air here, which is the entire premise of the island
	  outside. So the crust stays on, and the tool cuts a channel through it
	  exactly as it does on the black strand 2200 studs west.

	  IT SHARES ASHFALL'S TERRAIN PAIR (Mud / Basalt) RATHER THAN CLAIMING ONE.
	  Terrain material colours are global, so every island so far has bought its
	  palette by taking a pair nothing else uses -- and after five islands and
	  the shrine there is essentially nothing left worth having (Grass, Glacier
	  and Basalt are swallowed as a minority strip and cannot be a raked state;
	  Brick and WoodPlanks render a full stud proud of the rest; Ice is bumpy).
	  That constraint does not apply here, because this room is INSIDE the island
	  whose pair it would be sharing. Ash is meant to look like Ashfall's ash.
	  Sharing is the correct answer, not the affordable one.

	  The two decisions also cover for each other: Config.terrainSwapFor returns
	  false for any island with a crust, so matClean is never written to a voxel
	  in here and the pair is only ever spending ONE tint -- the one that is
	  already correct.
]]

local Magma = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local CTB = ReplicatedStorage:WaitForChild("CTB")
local Config = require(CTB:WaitForChild("Config"))
local Net = CTB:WaitForChild("Net")

local Terrain = workspace.Terrain

--[[
	Ashfall's own prop library, borrowed rather than re-typed.

	Island4Props already knows how to make a brazier, a lava seam, an obsidian
	spire and a cairn, and they are the visual language of the island this door
	is on -- the approach should be built out of the same kit as the camp and
	the crater lookout, or it reads as somebody else's building bolted to the
	mountain.

	Behind a pcall and every call guarded, because this module must be able to
	come up on its own. Island4Props is a big file with its own asset lookups;
	if it will not load, the portal loses its dressing and keeps its door.
]]
local Props do
	local ok, mod = pcall(function()
		return require(ServerScriptService:WaitForChild("Island4Props", 20))
	end)
	Props = (ok and type(mod) == "table") and mod or nil
	if not Props then
		warn("[Magma] Island4Props would not load; the approach goes up undressed")
	end
end

local function prop(fnName: string, ...): Instance?
	if not Props or type(Props[fnName]) ~= "function" then
		return nil
	end
	local ok, made = pcall(Props[fnName], ...)
	if not ok then
		warn(("[Magma] Island4Props.%s threw: %s"):format(fnName, tostring(made)))
		return nil
	end
	return made
end

----------------------------------------------------------------
-- Dimensions: the chamber
----------------------------------------------------------------
local ISL = Config.island(7)
local CX, CZ = ISL.cx, ISL.cz
local GROUND = ISL.cleanY

--[[
	The rakeable field is CX/CZ +- 80. The room is wider and much longer than
	that, and every stud of the difference is asked for:

	  36 studs of clear rock EACH SIDE for the colonnade and the two fissures
	  that light the hall, none of it on floor the player has to dig;
	  60 studs at the SOUTH for the arrival ledge, the way out and the bench
	  they sell at;
	  60 studs at the NORTH for the vent bay -- the fall, the well and the
	  thing the hall points at.

	46 studs of headroom rather than the shrine's 36. This is a hall inside a
	mountain and the shaft above the vent bay carries the eye a further 34 up;
	a room whose ceiling you can reach with a jump would throw all of that away.
]]
local X0, X1 = CX - 116, CX + 116
local Z0, Z1 = CZ - 140, CZ + 140
local CEIL = GROUND + 46
local WALL = 6

-- The vent bay lifts, the same trick the tomb's alcove and the shrine's altar
-- end both use: the thing the hall points at has to be bigger than the things
-- lining it, and a hall sized for the columns is not tall enough for the Heart.
local VENT_Z = CZ + 88
local VENT_CEIL = CEIL + 24

--[[
	The aisles, and the ORDER of these two was wrong the first time round.

	The fissures started OUTSIDE the columns at +-108, tight against the wall,
	on the reasoning that a light source belongs at the edge of a room. Seen
	from where the player actually stands -- eye height, out on the field --
	that put both of them at the extreme edges of frame with a colonnade in
	front of them, so the one thing lighting the hall was the one thing you
	could not see.

	Swapped. The fissures are INBOARD at +-90, between the field and the
	columns, and the columns moved out to +-104 to make room. The crack is the
	first thing in the aisle now, it lights the columns from the field side
	rather than from behind them, and its widest lip is still 4.9 studs clear
	of the rakeable square.
]]
local COL_X = 104
local FISSURE_X = 90

-- Where the cinematic puts you down: just inside the south end, looking up the
-- length of the hall at the fall.
local ENTRY = CFrame.lookAt(
	Vector3.new(CX, GROUND + 3.5, Z0 + 24),
	Vector3.new(CX, GROUND + 3.5, Z0 + 56))

-- Where leaving puts you. Set by Magma.buildEntrance once the portal exists, so
-- the two ends cannot disagree about where the door is.
--
-- Applied at CALL time rather than assigned as a default, so a load-order
-- accident can never overwrite the real portal with it. Nobody may be sealed in
-- a room with no way out, so leave() always has an answer -- and this one is
-- the Ashfall camp, not the home beach, because a player dropped on the wrong
-- island entirely is a worse failure than a slightly wrong spawn on the right
-- one.
--
-- MEASURED, not picked off the map. The first value here was (-2200, 8, -240),
-- which a raycast says is the top of a prop Handle at y 8.86 -- so the one
-- player this constant exists to rescue would have been set down balancing on
-- a piece of camp furniture. (-2200, -290) is the LANDING's cinder road:
-- terrain at y 3.20, a character-sized box above it clear of everything, and
-- it faces north up the road toward the gate and the field, which is where
-- somebody who has just been ejected from a room wants to be pointed.
--
-- DERIVED NOW, NOT TYPED. Ashfall's camp slides south whenever its rakeable
-- square grows (Island4Builder takes all of that growth out of the south side so
-- the cone -- and this door in it -- never move). ACD is that island's camp
-- datum: field south edge plus 160, which is the CZ the camp's own layout is
-- written against. A bare -290 was the cinder road at grid 80 and would be open
-- sand, or worse the middle of the rakeable field, at any other size.
local ASH_ISL_FOR_RETURN = Config.island(5)
local ACD = ASH_ISL_FOR_RETURN.cz - ASH_ISL_FOR_RETURN.half + 160
local FALLBACK_RETURN = CFrame.lookAt(
	Vector3.new(ASH_ISL_FOR_RETURN.cx, 5.2, ACD - 290),
	Vector3.new(ASH_ISL_FOR_RETURN.cx, 5.2, ACD - 240))

--[[
	How many rebirths the chamber asks for.

	THIRTY-TWO, and FerryConfig.Ports is finally a table this can be read
	against: its requireLevel values are REBIRTH COUNTS now rather than Sifter
	levels, so the whole map is one ladder on one counter.

		Dunes 1 -> Vault 4 -> Cove 8 -> Shrine 14 -> Ashfall 22 -> MAGMA 32

	(An earlier revision of this very list had the Vault and the Cove swapped
	into the wrong order -- the ladder above matches FerryConfig and the three
	door constants as they actually are.)

	THE LAST RUNG, and the only one that has to stay last. This is the richest
	field in the game -- Config.CINDER_ITEMS pays about 563 a find against
	Ashfall's 252 -- so it is the end of the map in payout as well as in
	geography, and every gate below it pays less than the one above.

	Ten tides after Ashfall, the island it is cut into -- the widest of the
	three island-to-interior gaps (tomb three, shrine six, chamber ten), which
	is right for the last one. It lands at 32 of the 40 AUTHORED rebirths --
	late enough to be a genuine goal, early enough that a player who reaches it
	still has eight tides to enjoy it (and under the 2026-08 curve those eight
	tides are the longest in the game, a good third of a full run's playtime).
	Lengthening the authored ladder without raising this would strand the room
	at the very end of it, which is the one thing this number must not do.

	THE UNCAPPING DID NOT TOUCH THAT ARGUMENT (2026-09-11). Tides past 40 open
	nothing and are pure multiplier, so "eight tides to enjoy it" is still the
	honest count of what is left to SEE after this door -- it is
	ProgressionConfig.Rebirth.LadderTides this wants to stay clear of, not the
	highest tide anybody has ridden.

	The argument that set it at ten was wrong on its own terms: it read the Ports
	table as rebirth counts when those were Sifter levels, and concluded the door
	was "open to everyone who can reach the island". It was shut for five tides
	after they got there. The shrine's own REBIRTHS is not an argument for this
	number either -- that room is small, early and modest on purpose.

	IT IS STILL A REAL GATE, wired like the tomb's and the shrine's: checked on
	the server inside the click handler, refused with the same strain-and-settle
	and the same "DoorLocked" message the client already draws. Raise this one
	number and the door locks properly, with no other line to move.
]]
Magma.REBIRTHS = 32

-- Cinematic timings live in Config so the client fades on exactly the numbers
-- the server teleports on. Shared constants, NOT a handshake -- see Config.CINEMA.
Magma.BEAT = Config.CINEMA.beat
Magma.FADE = Config.CINEMA.fade
Magma.HOLD = Config.CINEMA.hold

----------------------------------------------------------------
-- Palette
--
-- Black rock and one hot colour, which is the whole of it. The tomb is gold on
-- sandstone and the shrine is vermilion on timber; if this room reaches for a
-- second accent it stops being a hole in a volcano.
--
-- EVERY VALUE IS PITCHED FOR A BRIGHT PLACE. Lighting.Brightness is 3.1 here
-- with Bloom at 0.55/1.60, and a palette tuned in a dark scene blows out badly
-- under that -- the cove's stall and wash bay both had to be brought down for
-- exactly this reason. The rock therefore sits at 11-29% Rec.709 luma and the
-- hot colours are the ONLY things above 50%, so the eye goes to the lava
-- because nothing else is competing for it.
----------------------------------------------------------------
local BASALT = Color3.fromRGB(52, 49, 58)
local BASALT_DEEP = Color3.fromRGB(34, 32, 40)
local BASALT_LIGHT = Color3.fromRGB(78, 74, 84)
local OBSIDIAN = Color3.fromRGB(22, 20, 28)
local ASH_PALE = Color3.fromRGB(148, 142, 138)
local SCORIA = Color3.fromRGB(92, 50, 42)
local LAVA = Color3.fromRGB(255, 104, 34)
local LAVA_DEEP = Color3.fromRGB(196, 54, 18)
local EMBER = Color3.fromRGB(255, 152, 58)
local SULPHUR = Color3.fromRGB(214, 186, 66)
-- Brass at the cove's corrected value, not the one that turned every handrail
-- in Endless Rails into a glowing bar: fittings are detail, not light sources.
local BRASS = Color3.fromRGB(146, 112, 54)
local IRON = Color3.fromRGB(64, 62, 66)

-- Both verified to load in this place; the same two the tomb and the shrine use.
local SND_AMBIENCE = "rbxassetid://9125602882"
local SND_WHOOSH = "rbxassetid://9125742262"

----------------------------------------------------------------
-- Builders
----------------------------------------------------------------
local function P(parent, name, size, cf, colour, material, extra)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = colour
	p.Material = material
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
	return P(parent, name,
		Vector3.new(x1 - x0, y1 - y0, z1 - z0),
		CFrame.new((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5),
		colour, material, extra)
end

local function trim(parent, name, size, cf, colour, material, extra)
	local e = { CanCollide = false, CastShadow = false }
	if extra then
		for k, v in pairs(extra) do
			e[k] = v
		end
	end
	return P(parent, name, size, cf, colour, material, e)
end

--[[
	MOLTEN ROCK, AND IT IS NEVER TRANSPARENT.

	Neon carrying ANY transparency above zero renders near-black under Future
	lighting -- a facade at 0.08 came back pure black through a window and had
	to be forced to exactly 0. So depth in a lava surface is faked by DARKENING
	the colour (LAVA -> LAVA_DEEP toward the edges and the cold end), never by
	fading it, and every Neon part this file makes is opaque.

	It is also CanCollide = false everywhere. There is no damage model in this
	game and there is not going to be one for a decorative pool; a player who
	walks into the fissure should walk over it, not be shoved off it.
]]
local function molten(parent, name, size, cf, hot: number?)
	local h = hot or 1
	return P(parent, name, size, cf, LAVA_DEEP:Lerp(LAVA, h), Enum.Material.Neon,
		{ Transparency = 0, CanCollide = false, CastShadow = false })
end

--[[
	A light on a hot surface, and the numbers are the point.

	Shadows OFF, because a shadow-casting light is the kind Future lighting
	actually rations, and a sealed room with a dozen of them starts dropping the
	ones furthest from the camera. Unshadowed lights pass through walls, which
	is why the Range figures below are all short enough to die inside this room
	-- the chamber is 1500 studs from anything, but the fissures run within 8
	studs of the shell and a 60-stud range would spill out of it.
]]
local function glow(part: BasePart, colour: Color3, range: number, brightness: number)
	local l = Instance.new("PointLight")
	l.Color = colour
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = part
	return l
end

----------------------------------------------------------------
-- The litter set
--
-- ReplicatedStorage.CTB.Cinder, and CTB_Client finds it because ISLANDS[7]
-- names it. What is lying on the floor of a lava tube is not seaweed and it is
-- not somebody's picnic: it is what fell out of the roof and what the last
-- party down here dropped and left.
--
-- TWO CONTRACTS, both inherited from Island4Props.buildLitterSet and both
-- enforced at the bottom of this function rather than trusted:
--
--   EVERY ENTRY IS A SINGLE BasePart. The sink and raise tweens in CTB_Client
--   drive one part directly; a Model would need welding before it could move
--   as a piece.
--
--   THE THINNEST AXIS MUST NOT BE X. CTB_Client.litterRest lies a piece flat
--   by turning it a quarter turn about X when its Z is smaller than its Y, so
--   it handles "already flat" and "modelled standing up" -- and a piece whose
--   smallest axis is X falls through both branches and comes out balanced on
--   its edge like a plate in a rack.
--
-- Sizes are all under two studs, to match every other set. A find the player
-- has to walk round is not litter, it is scenery.
----------------------------------------------------------------
local CINDER = {
	-- name, size, colour, material, extra
	{ "Cinder Clinker", Vector3.new(1.05, 0.85, 1.0), SCORIA, Enum.Material.Slate,
		{ Shape = Enum.PartType.Ball } },
	{ "Pumice Nodule", Vector3.new(1.0, 0.8, 0.95), ASH_PALE, Enum.Material.Concrete,
		{ Shape = Enum.PartType.Ball } },
	{ "Obsidian Flake", Vector3.new(1.15, 0.22, 0.9), OBSIDIAN, Enum.Material.Slate,
		{ Reflectance = 0.22 } },
	{ "Slag Crust", Vector3.new(1.3, 0.3, 1.1), Color3.fromRGB(74, 64, 62), Enum.Material.Slate },
	{ "Sulphur Crust", Vector3.new(0.95, 0.32, 0.9), SULPHUR, Enum.Material.Sand,
		{ Reflectance = 0.05 } },
	{ "Cooled Ribbon", Vector3.new(0.6, 0.26, 1.7), Color3.fromRGB(58, 44, 44),
		Enum.Material.Slate },
	-- A Cylinder's Size is (length, dia, dia) along its LOCAL X, so a flask
	-- LYING DOWN is the long axis first -- which also keeps Z equal to Y, which
	-- is what stops litterRest from standing it on end.
	{ "Scalded Flask", Vector3.new(1.2, 0.62, 0.62), Color3.fromRGB(132, 44, 40),
		Enum.Material.Metal, { Shape = Enum.PartType.Cylinder } },
	{ "Bent Pick Head", Vector3.new(1.45, 0.28, 0.42), IRON, Enum.Material.CorrodedMetal },
	{ "Spent Torch", Vector3.new(1.55, 0.3, 0.3), Color3.fromRGB(70, 52, 38),
		Enum.Material.Wood, { Shape = Enum.PartType.Cylinder } },
	{ "Ash Glass Tear", Vector3.new(0.7, 0.7, 0.7), Color3.fromRGB(120, 116, 128),
		Enum.Material.Slate, { Shape = Enum.PartType.Ball, Reflectance = 0.3 } },
	{ "Cracked Crucible", Vector3.new(1.1, 0.55, 1.05), Color3.fromRGB(96, 88, 82),
		Enum.Material.Concrete },
	{ "Peridot Grit", Vector3.new(0.8, 0.3, 0.75), Color3.fromRGB(96, 148, 70),
		Enum.Material.Slate, { Reflectance = 0.12 } },
}

local function buildCinderSet(): number
	local old = CTB:FindFirstChild("Cinder")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "Cinder"

	for _, t in ipairs(CINDER) do
		local p = Instance.new("Part")
		p.Name = t[1]
		p.Size = t[2]
		p.Color = t[3]
		p.Material = t[4]
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		if t[5] then
			for k, v in pairs(t[5]) do
				p[k] = v
			end
		end
		p.Parent = folder
	end

	-- The resting-axis contract, checked rather than assumed. Stated as the
	-- thing that actually matters (is the thinnest axis X?) rather than as the
	-- proxy "is X < Z", which cries wolf on any piece whose X and Z are equal
	-- in intent and unequal in float.
	local n = 0
	for _, p in ipairs(folder:GetChildren()) do
		if p:IsA("BasePart") then
			n += 1
			local sz = p.Size
			if sz.X < sz.Y - 1e-3 and sz.X < sz.Z - 1e-3 then
				warn(("[Magma] %s is thinnest in X and will rest on its edge"):format(p.Name))
			end
		end
	end
	folder.Parent = CTB
	return n
end

----------------------------------------------------------------
-- The floor
--
-- Same two-step every field write in this game uses: fill to a whole voxel
-- boundary, then write the top layer at the field's own occupancy. Fill*
-- rounds to whole voxels and smooth terrain renders its surface at the CENTRE
-- of the first non-full voxel, so filling "to y = 3" actually lands at y = 6
-- and leaves the rakeable square sitting in a pit.
--
-- EVERY BOUND IS A MULTIPLE OF FOUR. Region3:ExpandToGrid pushes a region out
-- to whole voxels, and a bound that needed expanding would leave the mats/occs
-- arrays a row short of the region -- which WriteVoxels rejects outright with
-- "NxMxK array expected". The shrine's site prep hit exactly that and now
-- reads its array size back off the expanded region; here the bounds are clean
-- to begin with, and the assert below is what keeps them that way.
----------------------------------------------------------------
local function buildFloor()
	local fx0, fx1 = CX - 148, CX + 148
	local fz0, fz1 = CZ - 172, CZ + 172

	for _, v in ipairs({ fx0, fx1, fz0, fz1 }) do
		assert(v % Config.VOXEL == 0, "[Magma] floor bounds must be multiples of the voxel size")
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
-- Pieces of the hall
----------------------------------------------------------------

--[[
	A COLUMN, and it is a lava tube's column rather than a temple's: a fat
	basalt pier with a cooled dribble down it and a crack still glowing at the
	base. Nothing here was carved by anybody.

	The glow is a seam PART rather than a light. A light per column is twelve
	more of them in one room, and the fissures either side already do the
	lighting -- these only have to read as hot from across the hall.
]]
local function column(parent, x: number, z: number, seed: number)
	local rng = Random.new(seed)
	local m = Instance.new("Model")
	m.Name = "Column"
	m.Parent = parent

	local h = CEIL - GROUND
	box(m, "Base", x - 6.2, x + 6.2, GROUND, GROUND + 3.2, z - 6.2, z + 6.2,
		BASALT_DEEP, Enum.Material.Slate)
	box(m, "Shaft", x - 4.6, x + 4.6, GROUND + 3.2, GROUND + h - 5, z - 4.6, z + 4.6,
		BASALT, Enum.Material.Slate)
	box(m, "Neck", x - 5.4, x + 5.4, GROUND + h - 5, GROUND + h - 2.6, z - 5.4, z + 5.4,
		BASALT_LIGHT, Enum.Material.Slate)
	box(m, "Capital", x - 7, x + 7, GROUND + h - 2.6, GROUND + h, z - 7, z + 7,
		BASALT_DEEP, Enum.Material.Slate)

	-- Three cooled dribbles down the shaft, at random bearings so no two
	-- columns are the same piece of furniture seen twice.
	for i = 1, 3 do
		local th = rng:NextNumber(0, math.pi * 2)
		local dx, dz = math.cos(th) * 4.7, math.sin(th) * 4.7
		local top = GROUND + rng:NextNumber(h * 0.45, h * 0.8)
		trim(m, "Dribble", Vector3.new(1.1, top - GROUND - 2, 1.1),
			CFrame.new(x + dx, GROUND + 1 + (top - GROUND - 2) * 0.5, z + dz),
			SCORIA, Enum.Material.Slate)
		if i == 1 then
			molten(m, "Seam", Vector3.new(1.2, 3.4, 1.2),
				CFrame.new(x + dx, GROUND + 2.4, z + dz), 0.55)
		end
	end
end

--[[
	A FISSURE: a crack in the floor with lava standing in it, running the length
	of an aisle. This is the hall's LIGHTING, not its decoration -- the room has
	no sky and no torches on stands, so a player has to be able to read the far
	wall by what is coming out of the ground.

	Built at floor level rather than sunk, because the floor is TERRAIN and a
	trench in it is a voxel edit that would have to dodge the rakeable square.
	Kerbs of upthrust rock either side sell the depth for nothing.
]]
local function fissure(parent, x: number, z0: number, z1: number, seed: number)
	local rng = Random.new(seed)
	local m = Instance.new("Model")
	m.Name = "Fissure"
	m.Parent = parent

	-- STANDING PROUD, and this is the difference between a fissure and a line
	-- of rubble. At 0.5 thick sitting on the floor its top was y 3.41 while the
	-- lips beside it reached 4.73, so from standing eye height the near lip hid
	-- the lava completely and the crack photographed as a row of stones. The
	-- molten rock has to be the TALLEST thing in the crack.
	molten(m, "Lava", Vector3.new(9, 1.2, z1 - z0),
		CFrame.new(x, GROUND + 0.35, (z0 + z1) * 0.5), 0.92)
	-- One light every 34 studs rather than one per fissure. A single light in
	-- the middle of a 200-stud crack lights the middle of a 200-stud crack.
	for z = z0 + 17, z1 - 10, 34 do
		local host = P(m, "Glow", Vector3.new(1, 1, 1), CFrame.new(x, GROUND + 1.2, z),
			LAVA, Enum.Material.Neon,
			{ Transparency = 0, CanCollide = false, CanQuery = false, CastShadow = false })
		glow(host, EMBER, 58, 1.5)
	end

	-- Broken rock along both lips, in irregular lengths. A crack with two
	-- straight kerbs is a gutter.
	for _, sx in ipairs({ -1, 1 }) do
		local z = z0
		while z < z1 do
			local run = math.min(rng:NextNumber(6, 16), z1 - z)
			local w = rng:NextNumber(1.6, 3.2)
			-- Capped just under the lava's own top (3.95). See the note on the
			-- Lava part: taller lips are what hid it.
			local hgt = rng:NextNumber(0.35, 0.95)
			trim(m, "Lip", Vector3.new(w, hgt, run),
				CFrame.new(x + sx * (3.5 + w * 0.5), GROUND + hgt * 0.5 - 0.15, z + run * 0.5)
					* CFrame.Angles(0, rng:NextNumber(-0.06, 0.06), 0),
				BASALT_DEEP, Enum.Material.Slate, { CanCollide = true })
			z += run + rng:NextNumber(0.4, 2.2)
		end
	end
end

--[[
	THE FALL, on the north wall of the vent bay: molten rock coming over a lip
	high up and dropping into the well below it.

	IT IS A STACK OF PLATES, NOT ONE TALL PART. A single 40-stud neon slab reads
	as a painted wall -- there is nothing in it for the eye to travel down. Each
	plate is a shade cooler than the one above and half a stud proud of it, so
	the fall has a front face that catches the room and an edge every few studs.
]]
local function lavafall(parent, x: number, z: number, top: number, bottom: number, w: number)
	local m = Instance.new("Model")
	m.Name = "Fall"
	m.Parent = parent

	local plates = 9
	for i = 0, plates - 1 do
		local t = i / (plates - 1)
		local y0 = top - (top - bottom) * (i + 1) / plates
		local y1 = top - (top - bottom) * i / plates
		local pw = w * (1 - 0.16 * t)
		-- 0.82 at the lip rather than a flat 1.0. At full LAVA the whole sheet
		-- crossed this place's bloom threshold (0.55 at 1.60) and rendered as one
		-- featureless yellow rectangle -- every plate edge this function exists
		-- to create was blown away. Backed off, the plates read again AND the
		-- fall is still the brightest thing in the room.
		molten(m, "Plate", Vector3.new(pw, y1 - y0 + 0.6, 1.8 + 1.2 * t),
			CFrame.new(x, (y0 + y1) * 0.5, z + 0.6 * t), 0.82 - 0.38 * t)
	end
	local lip = box(m, "Lip", x - w * 0.62, x + w * 0.62, top, top + 3.2, z - 2.6, z + 1.6,
		BASALT_DEEP, Enum.Material.Slate)
	trim(m, "LipHot", Vector3.new(w * 1.1, 0.5, 3.6), CFrame.new(x, top + 0.1, z - 0.5),
		LAVA_DEEP:Lerp(LAVA, 0.88), Enum.Material.Neon, { Transparency = 0 })
	glow(lip, EMBER, 55, 1.6)

	-- The spatter where it lands, and the steam off it.
	local pool = molten(m, "Splash", Vector3.new(w + 14, 0.5, 16),
		CFrame.new(x, bottom + 0.2, z + 7), 0.9)
	glow(pool, LAVA, 48, 1.4)

	local steam = Instance.new("ParticleEmitter")
	steam.Name = "Steam"
	steam.Texture = "rbxasset://textures/particles/smoke_main.dds"
	steam.Color = ColorSequence.new(Color3.fromRGB(96, 82, 78), Color3.fromRGB(56, 50, 50))
	steam.LightEmission = 0.1
	steam.Rate = 14
	steam.Lifetime = NumberRange.new(2.4, 4.4)
	steam.Speed = NumberRange.new(6, 11)
	steam.SpreadAngle = Vector2.new(26, 26)
	steam.Acceleration = Vector3.new(0, 5, 0)
	steam.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 4),
		NumberSequenceKeypoint.new(1, 16),
	})
	steam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(0.4, 0.72),
		NumberSequenceKeypoint.new(1, 1),
	})
	steam.EmissionDirection = Enum.NormalId.Top
	steam.Parent = pool
	return m
end

----------------------------------------------------------------
-- Build: the chamber
----------------------------------------------------------------
function Magma.build()
	local old = workspace:FindFirstChild("MagmaChamber")
	if old then
		old:Destroy()
	end
	local root = Instance.new("Folder")
	root.Name = "MagmaChamber"
	root.Parent = workspace

	local kinds = buildCinderSet()
	buildFloor()

	local rng = Random.new(Config.SEED + 7719)

	----------------------------------------------------------------
	-- Shell: six sealed sides, with the vent bay raised.
	--
	-- Nobody is meant to know this room is standing on its own 1500 studs south
	-- of the tomb. Every wall runs to the ceiling above it, the two ceiling
	-- slabs meet the walls at their own heights, and the only opening anywhere
	-- is the vertical face at VENT_Z between the two -- which is interior, and
	-- is the mouth of the vent bay.
	----------------------------------------------------------------
	local shell = Instance.new("Model")
	shell.Name = "Shell"
	shell.Parent = root

	local TOP = CEIL + WALL
	local VENT_TOP = VENT_CEIL + WALL

	box(shell, "WallS", X0 - WALL, X1 + WALL, GROUND, CEIL, Z0 - WALL, Z0,
		BASALT_DEEP, Enum.Material.Slate)
	box(shell, "WallN", X0 - WALL, X1 + WALL, GROUND, VENT_CEIL, Z1, Z1 + WALL,
		BASALT_DEEP, Enum.Material.Slate)
	for _, w in ipairs({ { X0 - WALL, X0, "W" }, { X1, X1 + WALL, "E" } }) do
		box(shell, "Wall" .. w[3], w[1], w[2], GROUND, CEIL, Z0, VENT_Z,
			BASALT_DEEP, Enum.Material.Slate)
		box(shell, "Wall" .. w[3] .. "Vent", w[1], w[2], GROUND, VENT_CEIL, VENT_Z, Z1,
			BASALT_DEEP, Enum.Material.Slate)
	end
	box(shell, "Ceiling", X0 - WALL, X1 + WALL, CEIL, TOP, Z0 - WALL, VENT_Z,
		BASALT_DEEP, Enum.Material.Slate)
	-- The bay's own ceiling is NOT built here. It is four pieces laid around
	-- the vent shaft further down, because a single slab across this end would
	-- seal the shaft the moment it was poured.

	--[[
		THE RIBS, and they are doing more work than they look like.

		A sealed box of one colour has no scale: a 232-stud wall reads the same
		from ten studs away as from a hundred, so the room has no size. Ribs
		every 28 studs give the eye something to count, and they are what turns
		the shell from a container into a tube somebody could believe rock
		formed. Same job the shrine's dado does, in the material this room is
		made of.

		They stop 14 studs short of the ceiling on purpose. A rib that reaches
		all the way up closes the wall off as a frame, which is architecture;
		stopping short leaves the top of the wall reading as raw rock, which is
		a cave.
	]]
	local ribs = Instance.new("Model")
	ribs.Name = "Ribs"
	ribs.Parent = root
	for z = Z0 + 14, Z1 - 14, 28 do
		for _, sx in ipairs({ -1, 1 }) do
			local x = CX + sx * (X1 - CX)
			local inward = -sx * 2.6
			local h = (z >= VENT_Z) and (VENT_CEIL - 14) or (CEIL - 14)
			box(ribs, "Rib", math.min(x, x + inward), math.max(x, x + inward),
				GROUND, h, z - 3.2, z + 3.2, BASALT, Enum.Material.Slate)
			box(ribs, "RibFoot", math.min(x, x + inward * 1.7), math.max(x, x + inward * 1.7),
				GROUND, GROUND + 3.4, z - 4.4, z + 4.4, BASALT_DEEP, Enum.Material.Slate)
		end
	end
	-- The south wall gets the same treatment, so the end of the hall does not
	-- read as a flat backdrop when the player turns round on the way out.
	for x = CX - 84, CX + 84, 28 do
		box(ribs, "RibS", x - 3.2, x + 3.2, GROUND, CEIL - 14, Z0, Z0 + 2.6,
			BASALT, Enum.Material.Slate)
	end

	--[[
		THE ROOF, AND IT IS THIS ROOM'S REAL LIGHTING.

		The first build lit the hall from two cracks in the FLOOR and nothing
		else, and photographed at standing eye height it was unplayable: the ash
		within ten studs of the camera was pure black -- which is the ash the
		player is there to dig.

		The cause is not a shortage of lamps, it is that an interior in this
		game gets no ambient. Lighting.OutdoorAmbient (122,126,132) never
		reaches a sealed room and Lighting.Ambient is (44,45,50), so a hall of
		8-20% luma rock has nothing to be seen by. The tomb answers that with a
		CLIENT-side grade -- Vault_Client's VAULT_OUT / VAULT_AMB, keyed on its
		own island id -- and this answers it with GEOMETRY, because a cooling
		lava tube glows from its roof and light from above is exactly what a
		floor you have to read wants. No client file, nothing global touched,
		and it is the same fiction as everything else in here.

		A grade of its own would still be an improvement on top of this and is
		the obvious next pass -- the same sentence the shrine's notes carry.

		Seven lights, not seventy, and Shadows off on every one: see glow().
	]]
	local roofM = Instance.new("Model")
	roofM.Name = "RoofCracks"
	roofM.Parent = root
	for iz = 0, 6 do
		local z = Z0 + 24 + iz * ((VENT_Z - Z0 - 40) / 6)
		local off = ((iz % 2 == 0) and -1 or 1) * 34
		molten(roofM, "RoofCrack", Vector3.new(rng:NextNumber(2.4, 4.4), 0.5,
			rng:NextNumber(28, 46)),
			CFrame.new(CX + off + rng:NextNumber(-10, 10), CEIL - 0.3, z), 0.75)
		local host = P(roofM, "RoofGlow", Vector3.new(1, 1, 1),
			CFrame.new(CX + off, CEIL - 4, z), LAVA, Enum.Material.Neon,
			{ Transparency = 0, CanCollide = false, CanQuery = false, CastShadow = false })
		glow(host, EMBER, 78, 1.5)
	end

	----------------------------------------------------------------
	-- The colonnade and the two fissures that light the hall
	----------------------------------------------------------------
	local aisles = Instance.new("Model")
	aisles.Name = "Aisles"
	aisles.Parent = root

	local seed = 400
	for _, sx in ipairs({ -1, 1 }) do
		for z = CZ - 70, CZ + 70, 28 do
			seed += 1
			column(aisles, CX + sx * COL_X, z, seed)
		end
		fissure(aisles, CX + sx * FISSURE_X, Z0 + 22, Z1 - 22, seed + 900)
	end

	----------------------------------------------------------------
	-- The vent bay: the fall, the well and the Heart
	--
	-- The one part of the room that is not about the floor. Everything the
	-- player has to DO happens on the 160-stud square behind them; this end
	-- exists so that the square has somewhere to point at, which is the tomb's
	-- alcove argument and the shrine's altar argument restated in rock.
	----------------------------------------------------------------
	local bay = Instance.new("Model")
	bay.Name = "VentBay"
	bay.Parent = root

	-- The step up into the bay, so it reads as a place rather than as more hall.
	box(bay, "BayStep", X0, X1, GROUND, GROUND + 1.2, VENT_Z, VENT_Z + 4,
		BASALT, Enum.Material.Slate)
	box(bay, "BayFloor", X0, X1, GROUND, GROUND + 1.2, VENT_Z + 4, Z1,
		BASALT_DEEP, Enum.Material.Slate)
	local BAY_Y = GROUND + 1.2

	lavafall(bay, CX, Z1 - 6, VENT_CEIL - 6, BAY_Y + 1, 34)

	--[[
		THE WELL. A ring of upthrust rock with molten rock standing in it, and
		the Heart hanging over the middle.

		A RING OF SEGMENTS RATHER THAN A CYLINDER PART, because Part.Shape =
		Ball draws a sphere of min(Size) and a Cylinder can only be a right
		cylinder about its own X -- neither of which is a rim you can see the
		thickness of. Sixteen tapered blocks on a circle costs sixteen parts and
		reads as rock that cracked open.
	]]
	local WELL_Z = Z1 - 34
	local WELL_R = 21
	for i = 0, 15 do
		local th = (i / 16) * math.pi * 2
		local hgt = 2.2 + math.abs(math.sin(th * 3)) * 1.6
		trim(bay, "WellRim", Vector3.new(9.4, hgt, 4.6),
			CFrame.new(CX + math.cos(th) * WELL_R, BAY_Y + hgt * 0.5 - 0.3,
				WELL_Z + math.sin(th) * WELL_R) * CFrame.Angles(0, -th, 0),
			BASALT_DEEP, Enum.Material.Slate, { CanCollide = true })
	end
	local well = molten(bay, "WellLava", Vector3.new(WELL_R * 2 - 2, 0.6, WELL_R * 2 - 2),
		CFrame.new(CX, BAY_Y + 0.25, WELL_Z), 0.88)
	glow(well, LAVA, 64, 1.8)

	--[[
		THE HEART OF ASHFALL, hanging over the well on four chains.

		It is the rarest thing in this island's find table (ItemConfig's ASH
		block, weight 0.02) and this is where the name comes from -- which is
		the same trick the tomb plays with its statues and costs nothing but
		the decision to be consistent.

		Lit FROM UNDERNEATH by the well and by nothing else, so it is a dark
		mass with a hot underside rather than a glowing prop. That is the whole
		read: the room's one light source is below it.
	]]
	local heart = Instance.new("Model")
	heart.Name = "Heart"
	heart.Parent = bay
	local HEART_Y = BAY_Y + 21
	for i = 0, 7 do
		local th = (i / 8) * math.pi * 2 + 0.2
		local r = 6.4 - math.abs(math.cos(th * 2)) * 1.5
		-- SIZES AND HEIGHTS VARY PER FACET. Eight identical boxes on a small
		-- circle merge into one cube, and hung in front of a lava fall that is
		-- exactly what it photographed as: a black square floating in the air.
		-- Nothing in this room lights the Heart from the front, so the
		-- SILHOUETTE is the whole of the read and it has to be irregular.
		local w = 4.2 + (i % 3) * 1.6
		local h = 7.4 + ((i * 5) % 4) * 1.9
		trim(heart, "Facet", Vector3.new(w, h, w),
			CFrame.new(CX + math.cos(th) * r * 0.78,
				HEART_Y + ((i % 2 == 0) and 1.1 or -1.4),
				WELL_Z + math.sin(th) * r * 0.78)
				* CFrame.Angles(0.26 * math.sin(th), -th, 0.26 * math.cos(th)),
			OBSIDIAN, Enum.Material.Slate, { Reflectance = 0.28 })
	end
	-- Low enough to hang BELOW the facets. At HEART_Y - 4.4 it sat just inside
	-- them and the whole thing photographed as a black box hanging in a black
	-- room; the hot underside is the only thing saying it is a mass rather than
	-- a hole.
	local core = trim(heart, "Core", Vector3.new(8.6, 2.6, 8.6),
		CFrame.new(CX, HEART_Y - 5.8, WELL_Z), LAVA_DEEP, Enum.Material.Neon,
		{ Transparency = 0 })
	glow(core, LAVA, 34, 1.2)
	for i = 0, 3 do
		local th = (i / 4) * math.pi * 2 + math.pi / 4
		local ax, az = CX + math.cos(th) * 8.5, WELL_Z + math.sin(th) * 8.5
		local topY = VENT_CEIL - 2
		trim(heart, "Chain", Vector3.new(0.55, topY - (HEART_Y + 3), 0.55),
			CFrame.new(ax, (topY + HEART_Y + 3) * 0.5, az), IRON, Enum.Material.Metal)
		trim(heart, "Hook", Vector3.new(1.4, 1.1, 1.4), CFrame.new(ax, HEART_Y + 3.2, az),
			IRON, Enum.Material.Metal)
	end

	--[[
		THE SHAFT, straight up out of the bay, and it is what makes the fiction
		hold together: this room is inside the mountain the player just climbed,
		and the shaft is the throat that says so.

		IT IS CAPPED. There is nothing above it -- the chamber is at (3000,
		-1500) and the volcano is 5200 studs away -- so a shaft open to the sky
		would show flat blue at the top of it. Capped, filled with rising
		embers and lit from below, it reads as going up forever.
	]]
	local shaft = Instance.new("Model")
	shaft.Name = "Shaft"
	shaft.Parent = bay
	local SH_HX, SH_HZ = 26, 20
	local SH_TOP = VENT_CEIL + 34
	for _, sg in ipairs({
		{ CX - SH_HX - 4, CX - SH_HX, WELL_Z - SH_HZ - 4, WELL_Z + SH_HZ + 4 },
		{ CX + SH_HX, CX + SH_HX + 4, WELL_Z - SH_HZ - 4, WELL_Z + SH_HZ + 4 },
		{ CX - SH_HX, CX + SH_HX, WELL_Z - SH_HZ - 4, WELL_Z - SH_HZ },
		{ CX - SH_HX, CX + SH_HX, WELL_Z + SH_HZ, WELL_Z + SH_HZ + 4 },
	}) do
		box(shaft, "ShaftWall", sg[1], sg[2], VENT_CEIL, SH_TOP, sg[3], sg[4],
			BASALT_DEEP, Enum.Material.Slate)
	end
	box(shaft, "ShaftCap", CX - SH_HX - 4, CX + SH_HX + 4, SH_TOP, SH_TOP + 4,
		WELL_Z - SH_HZ - 4, WELL_Z + SH_HZ + 4, BASALT_DEEP, Enum.Material.Slate)
	-- The bay's ceiling, as four pieces laid AROUND the shaft's opening.
	for _, sg in ipairs({
		{ X0 - WALL, CX - SH_HX, VENT_Z, Z1 + WALL },
		{ CX + SH_HX, X1 + WALL, VENT_Z, Z1 + WALL },
		{ CX - SH_HX, CX + SH_HX, VENT_Z, WELL_Z - SH_HZ },
		{ CX - SH_HX, CX + SH_HX, WELL_Z + SH_HZ, Z1 + WALL },
	}) do
		box(shaft, "BayCeiling", sg[1], sg[2], VENT_CEIL, VENT_TOP, sg[3], sg[4],
			BASALT_DEEP, Enum.Material.Slate)
	end

	--[[
		THE TWO STALLS, ONE EITHER SIDE OF THE WAY OUT.

		THE SAME ARRANGEMENT THE INNER SHRINE ENDED UP WITH, and for the same
		reason it had to change there. The assay bench used to stand alone at
		(CX - 62, Z0 + 38) with its counter NORTH of its mat, so it faced SOUTH
		-- at the arrival point. Nobody sells on the way in: a player is dropped
		here, walks north up the hall, digs the ash, and comes back south with a
		full bag. Approached from the field that bench showed its back, and you
		had to walk past it, turn round and come back to use it.

		Both stalls face NORTH now, up the hall at the field, and they flank the
		arch: sell on the LEFT of the way out, upgrades on the RIGHT. Left and
		right are as seen looking AT the arch from inside the hall -- measured
		rather than assumed, a CFrame.lookAt from the hall to the arch has
		RightVector (1, 0, 0), so the viewer's right is +X and their left is -X.

		AXIS-ALIGNED, like the shrine's pair and for a plainer reason: every box()
		call in this file reads as x0..x1 / z0..z1, and turning a stall inward to
		face the centre line would mean rebuilding it around a CFrame for a
		read the player never gets -- they walk down the axis toward the arch and
		see both counters front-on either way.

		ONE SHELL, TWO SETS OF FITTINGS. Writing the building twice is how the
		two of them drift apart.
	]]
	local STALL_Z = Z0 + 10          -- the counters' centre line, level with the arch
	local STALL_X = 48               -- how far off the hall's axis each one stands

	local function stall(name: string, sx: number, title: string, strapText: string)
		local m = Instance.new("Model")
		m.Name = name
		m.Parent = root
		local cz = STALL_Z

		box(m, "Plinth", sx - 13, sx + 13, GROUND, GROUND + 4.4, cz - 3, cz + 3,
			BASALT, Enum.Material.Slate)
		box(m, "Top", sx - 14, sx + 14, GROUND + 4.4, GROUND + 5.2, cz - 3.6, cz + 3.6,
			BASALT_LIGHT, Enum.Material.Slate)
		for _, s in ipairs({ -1, 1 }) do
			box(m, "Post", sx + s * 13 - 0.8, sx + s * 13 + 0.8, GROUND + 5.2, GROUND + 19,
				cz - 0.8, cz + 0.8, IRON, Enum.Material.Metal)
		end
		box(m, "Hood", sx - 14.5, sx + 14.5, GROUND + 17.6, GROUND + 19.8,
			cz - 1.6, cz + 1.6, BASALT_DEEP, Enum.Material.Slate)

		-- A seam of lava along the hood's front edge. This is the volcano's
		-- answer to the shrine hanging a paper lantern on each post: it is the
		-- only light either stall makes for itself, and without it a black
		-- basalt counter in a room lit from the ceiling is a silhouette.
		local seam = trim(m, "HoodSeam", Vector3.new(29, 0.4, 0.8),
			CFrame.new(sx, GROUND + 17.7, cz + 1.7), LAVA, Enum.Material.Neon,
			{ Transparency = 0 })
		glow(seam, EMBER, 26, 0.9)

		--[[
			BOTH BOARDS ON THE NORTH FACE OF WHAT THEY HANG ON, which is the
			trap the shrine's pair hit: flip a sign's Face for a new orientation
			but leave its POSITION and it renders into the back of whatever now
			stands in front of it. The GUI exists, is Enabled, has the right
			text and the right Face, and shows nothing.

			Sightlines checked rather than eyeballed. From a player's head at
			z = cz + 13 the ray to the name board passes y 13.8 at the hood's
			front face, which is 3.8 studs under it; the strap sits below the
			counter top's overhang and the ray reaches it under that too.
		]]
		pcall(function()
			local SignKit = require(ReplicatedStorage.Modules:WaitForChild("SignKit", 15))
			local top = P(m, "NameBoard", Vector3.new(24, 3.4, 0.5),
				CFrame.new(sx, GROUND + 13.6, cz + 1.9), Color3.fromRGB(30, 27, 32),
				Enum.Material.SmoothPlastic, { CanCollide = false, CanQuery = false })
			SignKit.dress(top, title, { Enum.NormalId.Back })

			local strap = P(m, "StrapBoard", Vector3.new(24, 1.9, 0.35),
				CFrame.new(sx, GROUND + 2.6, cz + 3.18), SCORIA,
				Enum.Material.SmoothPlastic, { CanCollide = false, CanQuery = false })
			SignKit.dress(strap, strapText, { Enum.NormalId.Back })
		end)
		return m, cz
	end

	----------------------------------------------------------------
	-- LEFT OF THE ARCH: the assay bench, this room's sell point, so a bag
	-- filled in here does not have to be carried back out through the cinematic
	-- to be worth anything. The tomb's scales and the shrine's juyosho,
	-- restated in iron and rock.
	----------------------------------------------------------------
	local bench = stall("AssayBench", CX - STALL_X, "SELL", "SELL YOUR FINDS")
	local SX = CX - STALL_X
	local SZ = STALL_Z + 10          -- the PAD's centre, ten studs out in front

	-- The scale beam and the counterweight: the one place brass is spent.
	trim(bench, "Beam", Vector3.new(9, 0.4, 0.4),
		CFrame.new(SX + 8, GROUND + 8.6, STALL_Z), BRASS, Enum.Material.Metal)
	trim(bench, "Pan", Vector3.new(4.2, 0.3, 4.2),
		CFrame.new(SX + 4.4, GROUND + 7.2, STALL_Z), BRASS, Enum.Material.Metal)
	trim(bench, "Weight", Vector3.new(1.6, 1.6, 1.6),
		CFrame.new(SX + 11.6, GROUND + 7.9, STALL_Z), IRON, Enum.Material.Metal)
	-- A crucible of the stuff, so the bench looks like it is used.
	local pot = trim(bench, "Crucible", Vector3.new(3.4, 2.2, 3.4),
		CFrame.new(SX - 8, GROUND + 6.3, STALL_Z), IRON, Enum.Material.Metal)
	molten(bench, "CruciblePour", Vector3.new(2.6, 0.4, 2.6),
		CFrame.new(SX - 8, GROUND + 7.3, STALL_Z), 1)
	glow(pot, EMBER, 22, 0.8)

	--[[
		THE PAD. CTB_Server's sell test is an object-space box read off this
		part every heartbeat, so its 22 x 13 footprint IS the reach and where it
		sits is where the game pays out.

		Pale slate on the ash floor, which is the contrast rule every pad in the
		game obeys and each one answers differently -- the tomb's is gold on
		grey stone, the shrine's straw on dark boards.
	]]
	local pad = P(bench, "SellPad", Vector3.new(22, 0.45, 13),
		CFrame.new(SX, GROUND + 0.22, SZ), BASALT_LIGHT, Enum.Material.Slate)

	-- The glow is an OUTLINE laid on the pad, not a slab under it: a lit
	-- rectangle reads as a floor panel and a lit outline reads as a marked
	-- place. Transparency 0, because Neon above it renders near-black here.
	for _, e in ipairs({
		{ Vector3.new(20.4, 0.12, 0.35), Vector3.new(0, 0, -5.2) },
		{ Vector3.new(20.4, 0.12, 0.35), Vector3.new(0, 0, 5.2) },
		{ Vector3.new(0.35, 0.12, 10.8), Vector3.new(-9.9, 0, 0) },
		{ Vector3.new(0.35, 0.12, 10.8), Vector3.new(9.9, 0, 0) },
	}) do
		trim(bench, "PadGlow", e[1],
			CFrame.new(SX + e[2].X, GROUND + 0.50, SZ + e[2].Z), EMBER, Enum.Material.Neon,
			{ Transparency = 0 })
	end
	----------------------------------------------------------------
	-- RIGHT OF THE ARCH: the upgrade stall.
	--
	-- THE WHOLE INTEGRATION IS THE PROMPT'S NAME. MenuHud opens the upgrade
	-- panel on a ProximityPrompt called "ShopPrompt" ANYWHERE in the world, and
	-- renaming it unhooks the shop with nothing to show for it. ObjectText is
	-- not cosmetic either: MenuHud retitles its panel from it, and left blank
	-- the header reads BEACH SHOP while you are standing inside a volcano.
	----------------------------------------------------------------
	local shopM = stall("UpgradeStall", CX + STALL_X, "UPGRADES", "SPEND YOUR COINS")
	local UX = CX + STALL_X

	-- The anchor is a part this file owns, five studs in front of the counter at
	-- head height. Line of sight off for the reason every other shop in the game
	-- has it off: the counter stands between the player and the anchor, so the
	-- test would hide the prompt from exactly where you are meant to stand.
	local shopAnchor = P(shopM, "PromptAnchor", Vector3.new(1, 1, 1),
		CFrame.new(UX, GROUND + 5.2, STALL_Z + 5), ASH_PALE, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
	local shopPrompt = Instance.new("ProximityPrompt")
	shopPrompt.Name = "ShopPrompt"
	shopPrompt.ActionText = "Browse"
	shopPrompt.ObjectText = "Ashfall Deep Forge"
	shopPrompt.KeyboardKeyCode = Enum.KeyCode.E
	shopPrompt.HoldDuration = 0
	shopPrompt.MaxActivationDistance = 16
	shopPrompt.RequiresLineOfSight = false
	shopPrompt.Parent = shopAnchor

	--[[
		WHAT IS ON THE COUNTER, because a stall with nothing on it is a desk.

		A FORGE, which is the one thing that could not belong to the assay bench
		opposite -- the two are the same shell in the same rock, so the fittings
		are all that tell them apart at a glance. The shrine solves the same
		problem with a rail of charms; down here it is a grinding wheel, a small
		anvil and a rack of spare tines, all at STANDING height rather than hung
		up high, because that is where the player's eye is when they walk up.
	]]
	-- The grinding wheel: a cylinder on its edge, so Size is (thickness, dia, dia)
	-- and it has to be turned upright afterwards -- a cylinder's length is its X.
	trim(shopM, "WheelFrame", Vector3.new(0.6, 3.4, 0.6),
		CFrame.new(UX - 8.4, GROUND + 6.9, STALL_Z), IRON, Enum.Material.Metal)
	trim(shopM, "WheelFrame", Vector3.new(0.6, 3.4, 0.6),
		CFrame.new(UX - 5.6, GROUND + 6.9, STALL_Z), IRON, Enum.Material.Metal)
	trim(shopM, "Grindstone", Vector3.new(0.9, 4.2, 4.2),
		CFrame.new(UX - 7, GROUND + 7.9, STALL_Z) * CFrame.Angles(0, math.rad(90), 0),
		ASH_PALE, Enum.Material.Concrete, { Shape = Enum.PartType.Cylinder })
	local spark = trim(shopM, "WheelSpark", Vector3.new(3.6, 0.3, 0.5),
		CFrame.new(UX - 7, GROUND + 9.9, STALL_Z), LAVA, Enum.Material.Neon,
		{ Transparency = 0 })
	glow(spark, EMBER, 16, 0.7)

	-- A small anvil, and the horn is what stops a stepped block reading as a box.
	trim(shopM, "AnvilBase", Vector3.new(3.6, 1.1, 2.4),
		CFrame.new(UX + 6, GROUND + 5.75, STALL_Z), IRON, Enum.Material.Metal)
	trim(shopM, "AnvilWaist", Vector3.new(2.2, 0.9, 1.6),
		CFrame.new(UX + 6, GROUND + 6.75, STALL_Z), IRON, Enum.Material.Metal)
	trim(shopM, "AnvilFace", Vector3.new(4.6, 0.8, 2.2),
		CFrame.new(UX + 6, GROUND + 7.6, STALL_Z), BASALT_LIGHT, Enum.Material.Metal)
	trim(shopM, "AnvilHorn", Vector3.new(2.2, 0.7, 1.1),
		CFrame.new(UX + 8.9, GROUND + 7.6, STALL_Z), BASALT_LIGHT, Enum.Material.Metal)

	-- Spare tines in a rack, leaning, so the counter reads as stocked.
	for i = -2, 2 do
		trim(shopM, "SpareTine", Vector3.new(0.3, 4.6, 0.3),
			CFrame.new(UX + i * 0.9 + 0.6, GROUND + 7.6, STALL_Z - 2)
				* CFrame.Angles(math.rad(-14), 0, math.rad(i * 3)),
			BASALT_LIGHT, Enum.Material.Metal)
	end
	trim(shopM, "TineRail", Vector3.new(6.4, 0.35, 0.35),
		CFrame.new(UX + 0.6, GROUND + 6.2, STALL_Z - 2), IRON, Enum.Material.Metal)

	-- Two braziers out front, mirroring the sell pad's lit outline opposite, so
	-- the pair reads as one arrangement rather than two buildings that happen to
	-- stand near each other.
	for _, s in ipairs({ -1, 1 }) do
		if not prop("brazier", shopM, CFrame.new(UX + s * 13.5, GROUND, STALL_Z + 10), 1.0) then
			local fire = trim(shopM, "Brazier", Vector3.new(3.4, 3, 3.4),
				CFrame.new(UX + s * 13.5, GROUND + 1.5, STALL_Z + 10), IRON,
				Enum.Material.Metal)
			molten(shopM, "BrazierFire", Vector3.new(2.6, 0.5, 2.6),
				CFrame.new(UX + s * 13.5, GROUND + 3.1, STALL_Z + 10), 1)
			glow(fire, EMBER, 24, 1.0)
		end
	end


	----------------------------------------------------------------
	-- The way out
	--
	-- A basalt arch over a lit pad. The tomb uses a doorway with a neon veil
	-- and the shrine uses a torii; here it is the mouth of a smaller tube, cut
	-- by the same rock, because this room has no carpenters in its story.
	----------------------------------------------------------------
	local exitM = Instance.new("Model")
	exitM.Name = "Exit"
	exitM.Parent = root
	local EZ = Z0 + 12

	for _, sx in ipairs({ -1, 1 }) do
		local x0 = CX + math.min(sx * 13, sx * 19)
		local x1 = CX + math.max(sx * 13, sx * 19)
		box(exitM, "ArchPier", x0, x1, GROUND, GROUND + 19, EZ - 3.4, EZ + 3.4,
			BASALT, Enum.Material.Slate)
	end
	box(exitM, "ArchHead", CX - 20, CX + 20, GROUND + 19, GROUND + 24.5,
		EZ - 4.2, EZ + 4.2, BASALT_DEEP, Enum.Material.Slate)
	for i = -2, 2 do
		trim(exitM, "ArchTooth", Vector3.new(4.4, 3.6 + math.abs(i) * 1.1, 5),
			CFrame.new(CX + i * 6.6, GROUND + 17.6, EZ), BASALT_DEEP, Enum.Material.Slate)
	end
	local lintel = trim(exitM, "ArchHot", Vector3.new(38, 0.45, 4.6),
		CFrame.new(CX, GROUND + 19.1, EZ), LAVA, Enum.Material.Neon, { Transparency = 0 })
	glow(lintel, EMBER, 30, 1.1)

	P(exitM, "Pad", Vector3.new(14, 0.5, 10),
		CFrame.new(CX, GROUND + 0.25, EZ - 6), EMBER, Enum.Material.Neon,
		{ Transparency = 0, CanCollide = true })

	--[[
		THE PROMPT GOES ON AN ANCHOR AT HEAD HEIGHT, NOT ON THE PAD.

		Not tidiness. The shrine's exit prompt at GROUND + 0.25 never rendered
		at all -- ProximityPromptService.PromptShown never fired from five studs
		away with line-of-sight off and no competing prompt within 120 studs,
		and a prompt built client-side on the same part did not show either. The
		identical thing nine studs higher showed instantly. The cause is still
		unknown (the TOMB's prompt sits at the same height over the same y = 3
		terrain and works), so the fix is to do what the pyramid porch and the
		AFK shelter already do and never put one on the floor again.
	]]
	local promptAt = P(exitM, "PromptAnchor", Vector3.new(1, 1, 1),
		CFrame.new(CX, GROUND + 6, EZ - 6), EMBER, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
	local leave = Instance.new("ProximityPrompt")
	leave.Name = "LeavePrompt"
	leave.ActionText = "Leave"
	leave.ObjectText = "The Magma Chamber"
	leave.HoldDuration = 0.5
	leave.MaxActivationDistance = 16
	leave.RequiresLineOfSight = false
	leave.Parent = promptAt
	leave.Triggered:Connect(function(plr)
		Magma.leave(plr)
	end)

	----------------------------------------------------------------
	-- THE WASH BAY, and this room is the one that most needed one
	--
	-- ISLANDS[7] is CRUSTED -- crust is true and encasedScale is 1 -- so every
	-- find in here comes up inside a lump, and until now the nearest stand to
	-- break one on was back through the door, down the cutting and across
	-- Ashfall. A player farming the richest field in the game filled up with
	-- rock they could not process and had to leave the room to empty the bag,
	-- which is the endgame field asking them to stop playing it. All four
	-- open-air islands have a bay; the last room in the game did not. Fixed
	-- 2026-09-09.
	--
	-- A CLONE OF THE AUTHORED BEACH SHACK, the way the dunes', the cove's and
	-- Ashfall's all are: that model is the one WashServer knows how to bind (it
	-- carries the WashBay tag and a part named Stand) and cloning keeps all five
	-- bays one building rather than five that drift. BayBuilder.buildWashBay is
	-- the fallback if it is ever missing, which is Island2Builder's order
	-- exactly. ensureWashBay is NOT the call to make here and never was: it
	-- adopts the FIRST tagged bay anywhere in the place and returns, which by
	-- this point in the boot is the beach's.
	--
	-- WHERE, and every number is measured rather than eyeballed. It stands in
	-- the south service end beside the assay bench, facing NORTH up the hall at
	-- the field the way both stalls do, in the pocket between the west fissure's
	-- lip (x CX - 95.1) and the bench's west face (CX - 62.5): 15.5 studs of
	-- shack in 22.4 studs of gap, centred, with about 3.4 clear either side. It
	-- is 35 studs SOUTH of the rakeable square and 4 north of the south wall's
	-- ribs, so the sweep at the end of this function -- the one that pushes
	-- anything standing on the field clear -- has nothing to say about it.
	--
	-- THE SCREE IS THE ONE NEIGHBOUR THIS DOES NOT CLEAR BY CONSTRUCTION, and
	-- saying it does would be exactly the mistake the boulder note further down
	-- was written about. That scatter runs Z0 + 18 .. Z0 + 54 across the whole
	-- west aisle and the shack reaches Z0 + 23.3, so the front five studs of the
	-- mouth are inside its band: onAStall turns rock away only out to 68 studs
	-- off the axis and the shack stands at 66.3 .. 81.8. At Config.SEED nothing
	-- lands within 15.7 studs of it -- measured in the built room, not argued
	-- from the loop -- which is why this is a note and not a guard. Change the
	-- seed or that scatter and measure the mouth again. Noted 2026-09-09.
	----------------------------------------------------------------
	do
		local WASH_X = 74            -- how far off the hall's axis, west of the bench
		local WASH_Z = Z0 + 15       -- clear of the south ribs, clear of the field

		local rig
		local authored = workspace:FindFirstChild("WashBay")
		if authored and authored:IsA("Model") then
			rig = authored:Clone()
		else
			local okRig, built = pcall(function()
				local BayBuilder = require(script.Parent:WaitForChild("BayBuilder"))
				return BayBuilder.buildWashBay(CFrame.new(CX - WASH_X, GROUND + 0.12, WASH_Z))
			end)
			if okRig and built then
				rig = built
			else
				warn("[Magma] no wash bay to clone and BayBuilder would not build one:", built)
			end
		end

		if rig then
			rig.Name = "MagmaWashBay"
			-- PLACED BY ITS BOUNDING BOX, NOT BY ITS PIVOT. The authored model's
			-- pivot sits above its own underside, which is a fact about how
			-- somebody happened to save it rather than anything to build against --
			-- the same note the other three islands' bays carry.
			local bcf, bsize = rig:GetBoundingBox()
			rig:PivotTo(rig:GetPivot() + Vector3.new(
				(CX - WASH_X) - bcf.Position.X,
				(GROUND + 0.12) - (bcf.Position.Y - bsize.Y * 0.5),
				WASH_Z - bcf.Position.Z))
			-- Only the awning slats and the signboard are repainted, which is the
			-- same light touch Ashfall's clone gets. The timber is the same
			-- carpenter as the beach's and reads fine under the roof cracks;
			-- cream-and-sea stripes are the one part that would look imported.
			for _, p in ipairs(rig:GetDescendants()) do
				if p:IsA("BasePart") then
					local n = p.Name:match("^Stripe(%d+)$")
					if n then
						p.Color = (tonumber(n) % 2 == 0) and ASH_PALE or SCORIA
					elseif p.Name == "SignBoard" then
						p.Color = BASALT
					end
				end
			end
			rig.Parent = root
		end
	end

	----------------------------------------------------------------
	-- Loose rock, so the floor is not a swept stage with a job drawn on it
	--
	-- All of it OUTSIDE the rakeable square. resetAt is 1.0 here, so a single
	-- prop standing on a cell the player cannot reach is a field that can never
	-- be finished -- the same trap Island4Builder's assertClearOfField exists
	-- to catch on the island outside, and the sweep below is this file's.
	----------------------------------------------------------------
	local scree = Instance.new("Model")
	scree.Name = "Scree"
	scree.Parent = root

	--[[
		WHERE LOOSE ROCK CAN ACTUALLY GO, measured rather than eyeballed.

		The aisle is 36 studs from the field's edge to the wall and nearly all of
		it is spoken for: the fissure's lips run 84.9..95.1 from the centreline
		and the column bases 97.8..110.2. That leaves 80..84.9 against the field
		and 110.2..113.4 against the wall -- and a boulder of the size this used
		to scatter (4.6 tall, so 6.4 across) does not FIT in either. The first
		build put six of them overhanging the rakeable square, and the sweep at
		the end of this function then "fixed" them by shoving them sideways into
		the lava.

		So the aisles get small CHIPS against the wall, sized so their full width
		fits the 3.2-stud band, and the big pieces go where there is actually
		room for them: the sixty studs of clear floor at the south end, and the
		narrow strip between the field and the vent bay's step.

		The sweep below still runs, and is now width-aware. It should find
		nothing -- that is the point of it.
	]]
	local function rock(x: number, z: number, h: number, wide: number)
		local yaw = rng:NextNumber(0, 6.28)
		if prop("rock", scree, CFrame.new(x, GROUND, z) * CFrame.Angles(0, yaw, 0),
				h, nil, BASALT_DEEP) then
			return
		end
		trim(scree, "Rock", Vector3.new(h * wide, h, h * (wide - 0.2)),
			CFrame.new(x, GROUND + h * 0.4, z) * CFrame.Angles(0, yaw, 0),
			BASALT_DEEP, Enum.Material.Slate, { CanCollide = true })
	end

	-- Chips at the foot of the wall. h <= 2.3 keeps the widest at 3.2.
	for i = 1, 24 do
		local side = (i % 2 == 0) and 1 or -1
		rock(CX + side * rng:NextNumber(111, 112.4), rng:NextNumber(Z0 + 10, Z1 - 12),
			rng:NextNumber(1.1, 2.3), 1.4)
	end
	--[[
		The fissure's lane, off the centreline. Anything landing between these
		two runs the length of the hall (the crack starts at Z0 + 22 and ends at
		Z1 - 22) and comes to rest half-sunk in a Neon slab, which z-fights along
		every face it shares with it. Five rocks did exactly that before this.
	]]
	local LANE_IN, LANE_OUT = 84, 96
	local function offLane(x: number): number
		if x > LANE_IN and x < LANE_OUT then
			return (x < (LANE_IN + LANE_OUT) * 0.5) and LANE_IN - 2 or LANE_OUT + 2
		end
		return x
	end

	--[[
		AND OFF THE TWO STALLS.

		They stand at CX +- STALL_X between z STALL_Z - 6 and STALL_Z + 19 --
		counter, hood and pad -- which is inside the band this loop scatters
		across, so without the test below a boulder lands on the sell pad or
		inside the upgrade counter. The old per-z `lo` rule was doing this job
		for the single bench that used to sit out at CX - 62; it is gone, because
		a rule that names one x range silently stops covering anything that
		moves.

		The centre aisle between the stalls is deliberately NOT excluded: that
		is the walk to the way out and it should carry rock like the rest of the
		floor. Anything that does land on a stall is pushed north past the pad
		rather than dropped, so the count stays what the loop says it is.
	]]
	local function onAStall(x: number, z: number): boolean
		if z < STALL_Z - 6 or z > STALL_Z + 19 then
			return false
		end
		return math.abs(math.abs(x - CX) - STALL_X) < 20
	end

	-- The south end, which is the only part of this room with real space in it.
	for i = 1, 24 do
		local z = rng:NextNumber(Z0 + 18, Z0 + 54)
		local side = (i % 2 == 0) and 1 or -1
		local x = CX + side * offLane(rng:NextNumber(30, 108))
		if onAStall(x, z) then
			z = STALL_Z + 21 + rng:NextNumber(0, 10)
		end
		rock(x, z, rng:NextNumber(1.4, 4.8), 1.4)
	end
	-- The eight studs between the field's north edge and the vent bay's step.
	for i = 1, 10 do
		local side = (i % 2 == 0) and 1 or -1
		rock(CX + side * offLane(rng:NextNumber(24, 106)),
			rng:NextNumber(CZ + 82, CZ + 86), rng:NextNumber(1.0, 2.0), 1.3)
	end

	--[[
		AND THEN PROVE IT. A build that puts one part on the field is a field
		nobody can ever clear, and "I placed them outside" is a claim about the
		code rather than about the world -- Island4Builder learned this the
		expensive way and wrote assertClearOfField for it.

		Checked against the field's real bounds read off the island row, with a
		one-tile margin, and anything that fails is MOVED rather than left with
		a warning nobody reads.
	]]
	do
		local fx0, fx1 = ISL.cx - ISL.half - 2, ISL.cx + ISL.half + 2
		local fz0, fz1 = ISL.cz - ISL.half - 2, ISL.cz + ISL.half + 2
		local moved = 0
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("BasePart") and d.CanCollide then
				-- Half-extents off the part's own basis, not off Size: several
				-- of these are yawed and Size.X is not their world width. A
				-- centre-only test is what let six rocks overhang the field
				-- while reading as clear.
				local p, cf, sz = d.Position, d.CFrame, d.Size
				local hx = 0.5 * (math.abs(cf.RightVector.X) * sz.X
					+ math.abs(cf.UpVector.X) * sz.Y + math.abs(cf.LookVector.X) * sz.Z)
				local hz = 0.5 * (math.abs(cf.RightVector.Z) * sz.X
					+ math.abs(cf.UpVector.Z) * sz.Y + math.abs(cf.LookVector.Z) * sz.Z)
				if p.X + hx > fx0 and p.X - hx < fx1
					and p.Z + hz > fz0 and p.Z - hz < fz1
					and p.Y < GROUND + 12 then
					-- Out to the wall band, which is the one place in the aisle
					-- that is known clear -- NOT a computed offset from the
					-- field edge, which is the fissure.
					local side = (p.X < ISL.cx) and -1 or 1
					d.CFrame = d.CFrame + Vector3.new(ISL.cx + side * 112 - p.X, 0, 0)
					moved += 1
				end
			end
		end
		if moved > 0 then
			warn(("[Magma] %d parts were standing on the rakeable field and were pushed clear")
				:format(moved))
		end
	end

	----------------------------------------------------------------
	-- Embers rising, and the room's own ambience.
	--
	-- The shrine drifts petals DOWN because it is nominally under sakura trees.
	-- This one drives them UP, which is what hot air does and what the shaft
	-- overhead is for -- the two rooms should not be the same effect in
	-- different colours.
	----------------------------------------------------------------
	local fx = P(root, "EmberRise", Vector3.new(200, 1, 250),
		CFrame.new(CX, GROUND + 1.5, (Z0 + VENT_Z) * 0.5), EMBER, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false })
	local motes = Instance.new("ParticleEmitter")
	motes.Name = "Embers"
	motes.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	motes.Color = ColorSequence.new(EMBER, Color3.fromRGB(196, 62, 30))
	motes.LightEmission = 0.85
	motes.Rate = 30
	motes.Lifetime = NumberRange.new(5, 10)
	motes.Speed = NumberRange.new(2.5, 6)
	motes.SpreadAngle = Vector2.new(22, 22)
	motes.Acceleration = Vector3.new(0.6, 2.2, 0)
	motes.Rotation = NumberRange.new(0, 360)
	motes.RotSpeed = NumberRange.new(-60, 60)
	motes.EmissionDirection = Enum.NormalId.Top
	motes.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.7),
		NumberSequenceKeypoint.new(1, 0.15),
	})
	motes.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.1, 0.2),
		NumberSequenceKeypoint.new(0.8, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	motes.Parent = fx

	local amb = Instance.new("Sound")
	amb.Name = "MagmaAmbience"
	amb.SoundId = SND_AMBIENCE
	amb.Looped = true
	amb.Volume = 0.2
	amb.PlaybackSpeed = 0.72     -- the tomb's drone, dropped a fifth into a rumble
	amb.RollOffMaxDistance = 320
	amb.RollOffMode = Enum.RollOffMode.Linear
	amb.Parent = fx
	amb:Play()

	print(string.format("[Magma] chamber built: %d cinder types, %d parts",
		kinds, #root:GetDescendants()))

	return pad
end

----------------------------------------------------------------
-- The portal, on the volcano
----------------------------------------------------------------
Magma.ENTRY_NAME = "AshfallPortal"

--[[
	WHERE THE DOOR IS, AND WHY IT IS NOT ON THE SUMMIT.

	The obvious place for a volcano's door is the crater, and the crater is
	wrong. Ashfall's rim is at y = 186 and AshenStair climbs 188 studs to reach
	it; putting the only way in up there charges every visit the price of the
	whole mountain. The tomb's door is on the desert plaza and the shrine's is
	on the cove's north shore -- both a short walk from the field they belong
	to -- and this one should cost what those cost.

	So it is at the FOOT of the cone, dead on its axis (x = -2200, which is also
	the rakeable field's centreline) and facing south down the field. A player
	standing anywhere on the black strand is looking straight at it.

	THE APPROACH IS A CUTTING, not a building. The desert has a pyramid and the
	cove has a shrine, and both of those are things somebody built and put a
	door in. Nobody built a volcano. So the way in is a level bay cut back into
	the slope, which starts as an open trench on the plateau and closes over
	into rock about two thirds of the way up -- because that is what the terrain
	does, not because a roof was placed there. Measured on the real cone before
	a stud of it was cut: the surface is y = 3.0 at z = 168 and y = 63.4 at
	z = 252, so a cut with its ceiling at y = 36 is open to the sky as far as
	z = 219 and roofed from there to the door.

	EVERY BOUND IS A MULTIPLE OF FOUR -- see the note on buildFloor.
]]
local PX = -2200                    -- the cone's axis, and the field's centreline
local DECK = 3                      -- the plateau, and the cut's floor
local CUT_HX = 36
local CUT_Z0, CUT_Z1 = 168, 252
local CUT_TOP = 36
local FACE_Z = 245.5                -- the plane the door leaves stand in
local DOOR_HX = 12
local DOOR_TOP = DECK + 24
local MOUTH_Z = 180                 -- the gate at the open end of the cutting

--[[
	CUTTING THE BAY.

	Three steps, and the order matters:

	  1  AIR from the floor UP. Not from above the mountain down -- the shrine's
	     site prep cleared y 8..80 over a mound whose top was 15 and left the
	     bottom four studs of it standing as a stump, because a hard cut has to
	     start AT the surface it is making. Here that means starting at the top
	     of the voxel row the floor's occupancy lives in.
	  2  SOLID underneath, so the bay has a floor rather than a hole through the
	     island into the sea.
	  3  The top voxel row written at the field's own occupancy, so the bay
	     renders at exactly y = 3 -- flush with the plateau outside it and with
	     every other surface in this game. Fill* alone would land it at 6.

	IT MUST RUN AFTER Island4Builder. That module repours the whole cone every
	boot from a FillCylinder that covers this ground, so a bay cut before it is
	simply filled back in. CTB_Server orders the two.
]]
local function carveBay()
	for _, v in ipairs({ PX - CUT_HX, PX + CUT_HX, CUT_Z0, CUT_Z1, CUT_TOP }) do
		assert(v % Config.VOXEL == 0,
			"[Magma] the bay's bounds must be multiples of the voxel size")
	end

	local ASH_ISL = Config.island(5)
	local cx, cz = PX, (CUT_Z0 + CUT_Z1) * 0.5
	local sx, sz = CUT_HX * 2, CUT_Z1 - CUT_Z0

	Terrain:FillBlock(CFrame.new(cx, (Config.VOXEL + CUT_TOP) * 0.5, cz),
		Vector3.new(sx, CUT_TOP - Config.VOXEL, sz), Enum.Material.Air)
	Terrain:FillBlock(CFrame.new(cx, -15, cz),
		Vector3.new(sx, 30, sz), ASH_ISL.matMessy)

	local _, o3 = Config.occupancyFor(DECK)
	local region = Region3.new(
		Vector3.new(PX - CUT_HX, 0, CUT_Z0),
		Vector3.new(PX + CUT_HX, Config.VOXEL, CUT_Z1)
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
				mx[yi][zi], ox[yi][zi] = ASH_ISL.matMessy, o3
			end
		end
	end
	Terrain:WriteVoxels(region, Config.VOXEL, mats, occs)
end

--[[
	ANYTHING ALREADY STANDING HERE IS MOVED, NEVER DELETED -- the shrine's rule.

	Ashfall is rebuilt from code rather than adopted, so in practice its own
	scatter never lands in the bay (Island4Builder's openGround test keeps props
	off the cone's steep flank, and the site surveyed clear of all seven hundred
	of them). This is here for the case that matters: somebody hand-places a
	prop on the approach later, and a silent Destroy would eat it with nothing
	to show for it.
]]
local function clearBay(): number
	local moved = 0
	local i4 = workspace:FindFirstChild("Island4")
	local props = i4 and i4:FindFirstChild("Props")
	if not props then
		return 0
	end
	for _, child in ipairs(props:GetChildren()) do
		local ok, pivot = pcall(function()
			return child:GetPivot().Position
		end)
		if ok and math.abs(pivot.X - PX) <= CUT_HX + 6
			and pivot.Z >= CUT_Z0 - 6 and pivot.Z <= CUT_Z1 + 6 then
			local push = (pivot.X < PX) and -1 or 1
			local target = Vector3.new(PX + push * (CUT_HX + 30), pivot.Y, pivot.Z)
			pcall(function()
				child:PivotTo(child:GetPivot() + (target - pivot))
			end)
			warn(("[Magma] moved %s off the portal approach: %s -> %s")
				:format(child.Name, tostring(pivot), tostring(target)))
			moved += 1
		end
	end
	return moved
end

function Magma.buildEntrance()
	local existing = workspace:FindFirstChild(Magma.ENTRY_NAME)
	if existing then
		existing:Destroy()
	end

	carveBay()
	local moved = clearBay()

	local root = Instance.new("Model")
	root.Name = Magma.ENTRY_NAME
	root.Parent = workspace

	local rng = Random.new(Config.SEED + 5501)

	----------------------------------------------------------------
	-- The approach
	----------------------------------------------------------------
	local app = Instance.new("Model")
	app.Name = "Approach"
	app.Parent = root

	--[[
		The causeway. It stops at z = 164 rather than running down onto the sand,
		because Ashfall's rakeable square ends at z = 160 and ISLANDS[5].resetAt
		is 1.0 -- a slab overhanging that line by one tile is a field nobody can
		finish and an ERUPTION bonus nobody can claim. Four studs of margin, and
		the sweep at the end of this function is what proves it stayed there.
	]]
	local CW_HX = 15
	box(app, "Causeway", PX - CW_HX, PX + CW_HX, DECK - 0.6, DECK + 0.35, 164, 242,
		BASALT, Enum.Material.Slate)
	for _, sx in ipairs({ -1, 1 }) do
		box(app, "CausewayKerb", PX + sx * CW_HX - 1.4, PX + sx * CW_HX + 1.4,
			DECK - 0.6, DECK + 1.1, 164, 242, BASALT_DEEP, Enum.Material.Slate)
	end
	-- A joint every ten studs, which is what stops eighty studs of one part
	-- reading as a road.
	for z = 174, 236, 10 do
		trim(app, "CausewayJoint", Vector3.new(CW_HX * 2, 0.12, 0.6),
			CFrame.new(PX, DECK + 0.42, z), BASALT_DEEP, Enum.Material.Slate)
	end

	--[[
		TWO SEAMS OF LAVA IN THE FLOOR, one either side of the causeway, running
		the length of the cut.

		They are the reason to build a cutting rather than a tunnel: an open
		trench in a black mountain under a noon sun has no light of its own and
		reads as a grey slot. Two glowing lines converging on the door give the
		approach a direction, and they get hotter as they near it -- the bright
		end is the end you are walking towards.
	]]
	for _, sx in ipairs({ -1, 1 }) do
		local x = PX + sx * 24
		local z = 176
		while z < 240 do
			local run = math.min(rng:NextNumber(9, 17), 240 - z)
			local hot = 0.35 + 0.6 * ((z - 176) / 64)
			molten(app, "Seam", Vector3.new(rng:NextNumber(2.2, 4.2), 0.35, run),
				CFrame.new(x + rng:NextNumber(-1.6, 1.6), DECK + 0.14, z + run * 0.5), hot)
			z += run + rng:NextNumber(3, 8)
		end
		-- NO LIGHTS ON THE SEAMS. There were six, and they were the difference
		-- between a black cutting and a warm sandstone corridor: Neon is
		-- self-lit, so a seam is visible whether or not anything is shining on
		-- it, and six 40-stud sources added to twelve torches inside a 72-stud
		-- trench is what actually blew the exposure. The torches light this
		-- place; the seams only have to BE lit.
	end

	--[[
		THE GATE AT THE MOUTH -- two piers and a lintel, standing where the cut
		is still open to the sky.

		It carries the NAME, and that is why it is here rather than on the door.
		The door is seventy studs up a trench and nothing on it can be read from
		the field; the gate stands at the edge of the plateau where a player
		raking the north rows is looking straight at it. Same reasoning as the
		landing's arrival gate, which is the piece of signage this one is meant
		to rhyme with.
	]]
	local gate = Instance.new("Model")
	gate.Name = "Gate"
	gate.Parent = root
	for _, sx in ipairs({ -1, 1 }) do
		local x = PX + sx * 26
		box(gate, "GatePost", x - 5, x + 5, DECK, DECK + 20, MOUTH_Z - 5, MOUTH_Z + 5,
			BASALT, Enum.Material.Slate)
		box(gate, "GatePostFoot", x - 6.6, x + 6.6, DECK, DECK + 3, MOUTH_Z - 6.6, MOUTH_Z + 6.6,
			BASALT_DEEP, Enum.Material.Slate)
		local cap = box(gate, "GatePostCap", x - 6, x + 6, DECK + 20, DECK + 22.4,
			MOUTH_Z - 6, MOUTH_Z + 6, BASALT_DEEP, Enum.Material.Slate)
		molten(gate, "PostSeam", Vector3.new(10.4, 0.5, 1.2),
			CFrame.new(x, DECK + 20.1, MOUTH_Z - 5.2), 0.9)
		glow(cap, EMBER, 26, 0.8)
		if not prop("brazier", gate, CFrame.new(x, DECK + 22.4, MOUTH_Z), 1.25) then
			molten(gate, "PostFire", Vector3.new(5, 2.4, 5),
				CFrame.new(x, DECK + 23.6, MOUTH_Z), 1)
		end
	end
	box(gate, "GateLintel", PX - 33, PX + 33, DECK + 22.4, DECK + 29,
		MOUTH_Z - 4.4, MOUTH_Z + 4.4, BASALT, Enum.Material.Slate)
	box(gate, "GateLintelCap", PX - 34.5, PX + 34.5, DECK + 29, DECK + 30.6,
		MOUTH_Z - 5.4, MOUTH_Z + 5.4, BASALT_DEEP, Enum.Material.Slate)
	pcall(function()
		local SignKit = require(ReplicatedStorage.Modules:WaitForChild("SignKit", 15))
		local b = trim(gate, "GateBoard", Vector3.new(58, 4.6, 0.5),
			CFrame.new(PX, DECK + 25.5, MOUTH_Z - 4.7), Color3.fromRGB(28, 25, 30),
			Enum.Material.SmoothPlastic, { CanQuery = false })
		SignKit.dress(b, "MAGMA CHAMBER", { Enum.NormalId.Front, Enum.NormalId.Back })
	end)

	----------------------------------------------------------------
	-- Dressing along the cut, in Ashfall's own kit
	----------------------------------------------------------------
	for _, sx in ipairs({ -1, 1 }) do
		for _, z in ipairs({ 196, 214, 232 }) do
			prop("tikiTorch", app, CFrame.new(PX + sx * 17.8, DECK, z), 12, true)
		end
		for _, z in ipairs({ 204, 226 }) do
			prop("brazier", app, CFrame.new(PX + sx * 30, DECK, z), 1.0)
		end
		for i = 1, 5 do
			local z = rng:NextNumber(184, 240)
			prop("obsidianSpire", app, CFrame.new(PX + sx * rng:NextNumber(30, 34), DECK, z)
				* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), rng:NextNumber(0.7, 1.5),
				rng:NextInteger(1, 9999))
		end
		prop("cairn", app, CFrame.new(PX + sx * 20, DECK, 186), 5)
		prop("fumarole", app, CFrame.new(PX + sx * 31, DECK, rng:NextNumber(200, 232)),
			rng:NextNumber(0.8, 1.3), rng:NextInteger(1, 9999))
	end
	-- Rubble against both cut walls, so the trench looks cut rather than moulded.
	for i = 1, 26 do
		local sx = (i % 2 == 0) and 1 or -1
		local x = PX + sx * rng:NextNumber(27, 35)
		local z = rng:NextNumber(172, 246)
		local h = rng:NextNumber(1.6, 5)
		if not prop("rock", app, CFrame.new(x, DECK, z)
				* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), h, nil, BASALT_DEEP) then
			trim(app, "Rubble", Vector3.new(h * 1.4, h, h * 1.2),
				CFrame.new(x, DECK + h * 0.4, z), BASALT_DEEP, Enum.Material.Slate,
				{ CanCollide = true })
		end
	end

	----------------------------------------------------------------
	-- The doorway, at the back of the cut
	----------------------------------------------------------------
	local door = Instance.new("Model")
	door.Name = "Door"
	door.Parent = root

	-- Threshold, and a step up to it, so the door has a floor of its own rather
	-- than standing on the trench.
	box(door, "Threshold", PX - 16, PX + 16, DECK - 0.6, DECK + 0.6, 240, 248,
		BASALT_LIGHT, Enum.Material.Slate)
	box(door, "Step", PX - 18, PX + 18, DECK - 0.6, DECK + 0.2, 237.6, 240,
		BASALT, Enum.Material.Slate)

	--[[
		THE RECESS BEHIND THE LEAVES.

		A door that opens onto flat rock reads as a fake. Five studs of black
		throat with a crack of light down the back of it costs eight parts and
		makes the same door read as an opening -- and it is what the shot is
		looking at for the two seconds before the fade takes the screen.

		Built in the air the carve left, between the leaves at z = 245.5 and the
		terrain face at z = 252.
	]]
	local recess = Instance.new("Model")
	recess.Name = "Recess"
	recess.Parent = door
	local R_Z0, R_Z1 = 246.4, 251.6
	box(recess, "Floor", PX - 13, PX + 13, DECK - 0.6, DECK + 0.15, R_Z0, R_Z1,
		OBSIDIAN, Enum.Material.Slate)
	for _, sx in ipairs({ -1, 1 }) do
		local x0 = PX + math.min(sx * 13, sx * 15.4)
		local x1 = PX + math.max(sx * 13, sx * 15.4)
		box(recess, "Side", x0, x1, DECK, DOOR_TOP + 2, R_Z0, R_Z1,
			OBSIDIAN, Enum.Material.Slate)
	end
	box(recess, "Head", PX - 15.4, PX + 15.4, DOOR_TOP, DOOR_TOP + 2.4, R_Z0, R_Z1,
		OBSIDIAN, Enum.Material.Slate)
	box(recess, "Back", PX - 13, PX + 13, DECK - 0.6, DOOR_TOP + 2, R_Z1, R_Z1 + 0.8,
		OBSIDIAN, Enum.Material.Slate)
	molten(recess, "Crack", Vector3.new(1.6, DOOR_TOP - DECK - 2, 0.4),
		CFrame.new(PX, DECK + (DOOR_TOP - DECK) * 0.5, R_Z1 - 0.25), 0.8)
	local throat = molten(recess, "Floorlight", Vector3.new(22, 0.3, R_Z1 - R_Z0 - 1),
		CFrame.new(PX, DECK + 0.2, (R_Z0 + R_Z1) * 0.5), 0.7)
	glow(throat, EMBER, 34, 1.3)

	--[[
		THE FRAME, and the jambs are load-bearing in the only sense this build
		cares about: they are where the leaves GO.

		Each leaf slides sideways by very nearly its own width. The jambs stand
		just SOUTH of the leaves' plane (z 242.6..244.4 against the leaves'
		244.6..246.4), so an open leaf is hidden behind one instead of standing
		out in the trench like a slab somebody left leaning on the mountain --
		and because the two z ranges do not overlap, nothing can foul on the way
		across.
	]]
	for _, sx in ipairs({ -1, 1 }) do
		local x0 = PX + math.min(sx * 13, sx * 27)
		local x1 = PX + math.max(sx * 13, sx * 27)
		box(door, "Jamb", x0, x1, DECK, DOOR_TOP + 3, 242.6, 244.4,
			BASALT, Enum.Material.Slate)
		box(door, "JambFace", x0 + 0.4, x1 - 0.4, DECK + 1.2, DOOR_TOP + 1.6, 242.2, 242.7,
			BASALT_DEEP, Enum.Material.Slate)
		molten(door, "JambSeam", Vector3.new(0.8, DOOR_TOP - DECK - 4, 0.35),
			CFrame.new(PX + sx * 14.6, DECK + (DOOR_TOP - DECK) * 0.5, 242.1), 0.55)
	end
	box(door, "Lintel", PX - 29, PX + 29, DOOR_TOP + 3, DOOR_TOP + 8,
		242.2, 246.6, BASALT, Enum.Material.Slate)
	box(door, "LintelCap", PX - 30.6, PX + 30.6, DOOR_TOP + 8, DOOR_TOP + 9.6,
		241.6, 247, BASALT_DEEP, Enum.Material.Slate)
	local brow = molten(door, "LintelSeam", Vector3.new(56, 0.5, 1),
		CFrame.new(PX, DOOR_TOP + 3.1, 242.3), 0.85)
	glow(brow, EMBER, 30, 1.0)

	--[[
		THE LEAVES. Obsidian, because it is the one rock on this island that
		could plausibly have been worked into a flat face -- and because a black
		glassy slab against basalt is the only contrast this door needs.

		Reflectance on Slate rather than Material.Glass: Glass does not render
		ANY transparent object behind it, and there is a lava seam, a light and
		a particle emitter standing right there.
	]]
	local leaves = {}
	--[[
		AND EVERY FITTING ON A LEAF SLIDES WITH IT.

		`leaves` stays the two slabs and nothing else: the grind and refuse
		sounds, the hint billboard and both ClickDetectors hang off leaves[1] and
		leaves[2] BY INDEX further down, so widening it would silently reparent
		all five onto a lava vein.

		What actually moves is `panel`: each leaf plus the five pieces bolted to
		its face, every entry carrying the direction of the leaf it belongs to.
		That direction used to be read off the position in the list -- fine for a
		list that was exactly two slabs, wrong the moment it is not.

		THE VEINS AND THE SEAM WERE BUILT INTO `door` AND LEFT OUT OF THE TWEEN.
		Opening slid the two obsidian slabs away behind the jambs and left eight
		lava chevrons and a glowing bar hanging in mid-air across an empty
		doorway, which is what a player standing on the deck sees. They are
		fittings ON the door, not decoration near it. This is the shrine's gold
		studs bug exactly, recorded at length in ShrineBuilder, and it is the
		same fix in the same shape.

		Parenting them to the leaf is not the other answer, for the reason that
		file records too: these tweens drive ONE PART directly, and every part
		this one makes is Anchored -- an anchored part does not follow a weld.

		The smoke and spill hosts stay out of it on purpose. Both are invisible
		markers for what the opening REVEALS, and neither is bolted to a leaf.
	]]
	local panel = {}
	for k, sx in ipairs({ -1, 1 }) do
		local l = P(door, "Leaf" .. (k == 1 and "W" or "E"),
			Vector3.new(DOOR_HX, DOOR_TOP - DECK, 1.8),
			CFrame.new(PX + sx * DOOR_HX * 0.5, DECK + (DOOR_TOP - DECK) * 0.5, FACE_Z),
			OBSIDIAN, Enum.Material.Slate, { Reflectance = 0.24 })
		leaves[k] = l
		table.insert(panel, { part = l, dir = sx })
		-- Veins on the face, tilted toward the seam so the two leaves only make
		-- sense shut. Dark lava rather than bright: a door that glows before it
		-- opens has nothing left to do when it does.
		for i = 1, 4 do
			local t = (i - 0.5) / 4
			local vein = trim(door, "LeafVein", Vector3.new(DOOR_HX * 0.62, 0.55, 0.25),
				CFrame.new(PX + sx * DOOR_HX * 0.5,
					DECK + (DOOR_TOP - DECK) * t, FACE_Z - 0.95)
					* CFrame.Angles(0, 0, sx * 0.42),
				LAVA_DEEP, Enum.Material.Neon, { Transparency = 0 })
			table.insert(panel, { part = vein, dir = sx })
		end
		-- HALF A SEAM EACH rather than one bar down the middle, because the seam
		-- has to leave with the leaves and there is no other way to send it. Shut,
		-- the two halves abut into exactly the 0.5-wide line this always was; open,
		-- each leaf carries its own glowing inner edge away. Fading it out instead
		-- is not on offer -- see `molten`: Neon at any transparency above zero
		-- renders near-black under Future lighting.
		local seam = molten(door, "Seal", Vector3.new(0.25, DOOR_TOP - DECK - 1.4, 0.3),
			CFrame.new(PX + sx * 0.125, DECK + (DOOR_TOP - DECK) * 0.5, FACE_Z - 0.95), 0.7)
		table.insert(panel, { part = seam, dir = sx })
	end

	-- A small plate on the door head. The NAME is on the gate at the mouth where
	-- it can actually be read (see the note there); this is the line you get
	-- once you are standing at the door.
	pcall(function()
		local SignKit = require(ReplicatedStorage.Modules:WaitForChild("SignKit", 15))
		local b = trim(door, "DoorPlate", Vector3.new(26, 3.2, 0.5),
			CFrame.new(PX, DOOR_TOP + 5.4, 242.0), Color3.fromRGB(28, 25, 30),
			Enum.Material.SmoothPlastic, { CanQuery = false })
		SignKit.dress(b, "THE MOUNTAIN'S HEART", { Enum.NormalId.Front })
	end)

	----------------------------------------------------------------
	-- Working the door
	----------------------------------------------------------------
	local smokeHost = P(door, "SmokeHost", Vector3.new(DOOR_HX * 2, 1, 1),
		CFrame.new(PX, DECK + 1, FACE_Z - 1.4), OBSIDIAN, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false })
	local smoke = Instance.new("ParticleEmitter")
	smoke.Name = "Vent"
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Color = ColorSequence.new(Color3.fromRGB(88, 76, 72), Color3.fromRGB(44, 40, 40))
	smoke.LightEmission = 0.18
	smoke.Rate = 0
	smoke.Lifetime = NumberRange.new(2.2, 4.2)
	smoke.Speed = NumberRange.new(4, 9)
	smoke.SpreadAngle = Vector2.new(30, 12)
	smoke.Acceleration = Vector3.new(0, 3.5, -2)
	smoke.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 3),
		NumberSequenceKeypoint.new(1, 13),
	})
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(0.45, 0.7),
		NumberSequenceKeypoint.new(1, 1),
	})
	smoke.EmissionDirection = Enum.NormalId.Top
	smoke.Parent = smokeHost

	-- The light that comes OUT when it opens. Zero brightness until then, so a
	-- shut door is a shut door.
	local spillHost = P(door, "SpillHost", Vector3.new(1, 1, 1),
		CFrame.new(PX, DECK + 8, FACE_Z - 3), LAVA, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false })
	local spill = glow(spillHost, LAVA, 60, 0)

	local grind = Instance.new("Sound")
	grind.SoundId = SND_WHOOSH
	grind.Volume = 0.55
	grind.PlaybackSpeed = 0.62      -- rock, not paper: the shrine's door an octave down
	grind.RollOffMaxDistance = 150
	grind.Parent = leaves[1]
	local refuseSnd = Instance.new("Sound")
	refuseSnd.SoundId = SND_WHOOSH
	refuseSnd.Volume = 0.4
	refuseSnd.PlaybackSpeed = 0.45
	refuseSnd.RollOffMaxDistance = 110
	refuseSnd.Parent = leaves[1]

	-- "Click this" is not discoverable on a slab of rock, least of all on a
	-- phone where there is no hover cursor. Stood well proud of the face for the
	-- reason the pyramid's hint records: flush with it, it is inside the stone.
	local hint = Instance.new("BillboardGui")
	hint.Name = "DoorHint"
	hint.Size = UDim2.new(0, 250, 0, 58)
	-- Over the middle of the LEAF, not above its head. The shrine's offset
	-- (half the door's height, plus 3.5) puts the label at y 30.5 here, and the
	-- name plate on the lintel is at 32.4 -- in play the two overlapped and read
	-- as one line of nonsense. Measured off the capture, not guessed.
	hint.StudsOffsetWorldSpace = Vector3.new(0, 5, -7)
	hint.MaxDistance = 110
	hint.Parent = leaves[1]
	local hintLabel = Instance.new("TextLabel")
	hintLabel.Size = UDim2.fromScale(1, 1)
	hintLabel.Text = "TAP TO ENTER"
	hintLabel.Parent = hint
	pcall(function()
		local SignKit = require(ReplicatedStorage.Modules:WaitForChild("SignKit", 15))
		SignKit.floating(hintLabel, EMBER)
	end)

	--[[
		AND IT MUST NOT SAY "TAP TO ENTER" TO SOMEBODY IT IS GOING TO REFUSE.

		This label read TAP TO ENTER at every rebirth count, so a player short of
		the gate was invited to click a slab whose only possible answer is to
		strain and settle back. That reads as a broken door and was reported as
		one -- and this is the widest gap on the whole ladder, ten tides between
		arriving on Ashfall at 22 and this room's 32, with nothing anywhere
		telling them which it was. The pyramid's slab had exactly this complaint
		and answered it by PUBLISHING ITS GATE and letting the client repaint the
		sign per player (Island2Builder's TombRebirths, Island2_Client's
		paintDoorHint); this is that same route, and Vault_Client does the
		painting for this door and the shrine's both. Fixed 2026-09-09.

		It has to be per player and so it cannot be done here: one server-set
		string is seen by everybody standing in front of the door at once.

		The OPEN look is read back off the label SignKit has just dressed rather
		than typed again, so there is no second copy of the wording or of EMBER
		over on the client to drift from these.
	]]
	hintLabel:SetAttribute("RequireRebirths", Magma.REBIRTHS)
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
			smoke:Emit(46)
			smoke.Rate = 7
			TweenService:Create(spill, TweenInfo.new(1.6), { Brightness = 2.4 }):Play()
		else
			smoke.Rate = 0
			TweenService:Create(spill, TweenInfo.new(1.2), { Brightness = 0 }):Play()
		end
		grind.TimePosition = 0
		grind:Play()
		local tw = moveAll(open, TweenInfo.new(DOOR_TIME, Enum.EasingStyle.Quart,
			open and Enum.EasingDirection.Out or Enum.EasingDirection.InOut))
		tw.Completed:Connect(function()
			moving = false
		end)
		-- A tween that never completes latches `moving` true and the door is
		-- dead for the session -- and TweenService genuinely does stall while
		-- the window is minimised. One unconditional release, well after it
		-- should have landed. Straight out of the pyramid door's notes.
		task.delay(DOOR_TIME + 2, function()
			moving = false
		end)
	end

	-- Refused: the leaves strain against the rock and settle back. A door that
	-- simply does nothing reads as broken, and the player has to be able to tell
	-- "locked" from "bug".
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

	-- Nobody standing in the opening when it closes.
	local function doorwayClear(): boolean
		for _, plr in ipairs(Players:GetPlayers()) do
			local char = plr.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp then
				local d = hrp.Position - Vector3.new(PX, DECK + 5, FACE_Z)
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
		-- GATED, and checked here on the server off the same Rebirths attribute
		-- ProgressionServer writes. The click is the only entry point and this
		-- is the only place it is answered, so a client cannot talk its way in.
		local have = plr:GetAttribute("Rebirths") or 0
		if have < Magma.REBIRTHS then
			-- THE ROOM'S OWN NAME GOES WITH IT (2026-09-09). The refusal card was
			-- headed "THE TOMB IS SEALED" at all three doors, because the tomb is
			-- where it was written -- so this door named a room five thousand studs
			-- away that anybody standing here cleared twenty-eight tides ago.
			-- Config's name for ISLANDS[7], not a string typed here, and the client
			-- falls back to the tomb's line for a door that sends none.
			Net:FireClient(plr, "DoorLocked", Magma.REBIRTHS, have, ISL.name)
			refuse()
			return
		end
		slide(true)
		-- The doorway is handed over as the shot's SUBJECT: without it the
		-- client has nothing to frame and dollies along wherever the player
		-- happens to be looking. A fixed point, not the leaf -- the leaves are
		-- moving.
		Magma.enter(plr, Vector3.new(PX, DECK + 8, FACE_Z))

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

	--[[
		WHERE LEAVING PUTS THEM: at the mouth of the cutting, looking back up it
		at the door -- the tomb's plaza rule and the shrine's steps rule.

		Set here rather than published for CTB_Server to join up, because both
		ends of this door live in one module and there is no load-order problem
		to design around.
	]]
	Magma.returnCF = CFrame.lookAt(
		Vector3.new(PX, DECK + 3.5, MOUTH_Z - 6),
		Vector3.new(PX, DECK + 3.5, MOUTH_Z + 26))

	-- Also stamped on the model, which is not redundant. A module required from
	-- anywhere other than the running server gets its OWN copy of this table
	-- with returnCF still nil (that is how the assistant console sees it, and
	-- it is why a console test of leave() lands on the fallback and looks like
	-- a bug). An attribute is on the INSTANCE, so it reports what the real
	-- server actually published.
	root:SetAttribute("ReturnAt", Magma.returnCF)

	--[[
		AND THEN TURN THE LIGHTS DOWN, because the first build of this cutting
		was unreadable.

		Island4Props' torches and braziers each carry a PointLight sized for
		standing ALONE on an open black strand -- 1.5 to 1.7 brightness at 30 to
		42 studs of range. Six torches, four braziers and two gate fires inside
		a 72-stud trench is twelve of those overlapping, and Future lighting
		simply adds them: the finished approach photographed as warm SANDSTONE
		with the causeway reading as floorboards. The paint was never the
		problem -- every surface in here measures 8-30% Rec.709 luma, which is
		the black rock it is supposed to be.

		55% brightness and 70% range, applied to the INSTANCES here and never to
		Island4Props' own numbers -- that kit is shared with the camp, the
		crater lookout and the landing, all of which are lit correctly by it.

		Done by sweeping the finished model rather than by passing arguments,
		because prop() deliberately knows nothing about what it built.
	]]
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
		-- The door's spill light is tweened to a fixed brightness when the
		-- leaves part, so the scaling above only ever touched its range -- which
		-- is what we wanted anyway. Put it back to full so the opening still
		-- reads as light coming OUT.
		local sp = root:FindFirstChild("Door")
		sp = sp and sp:FindFirstChild("SpillHost")
		sp = sp and sp:FindFirstChildOfClass("PointLight")
		if sp then
			sp.Range = 60
		end
		print(("[Magma] approach lighting: %d sources trimmed to 55%%/70%%"):format(dimmed))
	end

	--[[
		AND PROVE THE APPROACH NEVER REACHED THE FIELD.

		ISLANDS[5].resetAt is 1.0: one collidable part standing on one of
		Ashfall's 6400 columns is a field that can never be finished. Island4
		Builder has assertClearOfField for exactly this and it does not see
		anything this module builds, so the check is repeated here against the
		same island row rather than assumed from the constants above.

		The half-extent is computed from the part's own basis rather than from
		Size.Z, because several of these are rotated and Size.Z is not world
		depth for any of them.
	]]
	do
		local ASH_ISL = Config.island(5)
		local fz1 = ASH_ISL.cz + ASH_ISL.half + 2
		local fx0, fx1 = ASH_ISL.cx - ASH_ISL.half - 2, ASH_ISL.cx + ASH_ISL.half + 2
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
			warn(("[Magma] %s overhung Ashfall's rakeable field and was pushed north")
				:format(d:GetFullName()))
		end
	end

	print(string.format("[Magma] volcano portal built: %d parts, %d props moved off the cut",
		#root:GetDescendants(), moved))

	return root
end

----------------------------------------------------------------
-- The transition
--
-- Both directions of the same fade, written once. The timings are constants
-- shared with the client rather than a handshake: the client fades on its own
-- clock and the server teleports on its own, so a dropped acknowledgement can
-- never leave somebody staring at a black screen.
--
-- IT REUSES THE TOMB'S "Cinema" MESSAGE, exactly as the shrine does.
-- Vault_Client's handler is generic -- it takes ("out", caption, kind,
-- subtitle) / ("in", kind) and knows nothing about which room it is fading
-- into -- so this door gets the push-in, the title card and the fade back for
-- nothing. The only vault-specific things over there are its colour grade and
-- its drone, both keyed on ISLANDS[3].id, and neither fires for this one. A
-- grade of its own is the obvious next pass and needs no change on this side.
--
-- THE SUBTITLE IS OURS TO SEND, and has to be: the client's default is the
-- tomb's "sealed for three thousand years", which is a sentence about a
-- different room. See SUBTITLE in Vault_Client.
----------------------------------------------------------------
local function travel(plr: Player, target: CFrame, caption: string, kind: string, sub: string?)
	local char = plr.Character
	if not char or not char.PrimaryPart then
		return
	end

	Net:FireClient(plr, "Cinema", "out", caption, kind, sub)

	-- Ask for the destination to stream in WHILE the screen is still fading.
	-- StreamingEnabled is on and these two places are 5200 studs apart -- the
	-- longest hop in the game by a factor of three -- so without this the fade
	-- lifts on an empty void for a second or two.
	task.spawn(function()
		pcall(function()
			plr:RequestStreamAroundAsync(target.Position, 10)
		end)
	end)

	task.delay(Magma.BEAT + Magma.FADE, function()
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
		task.wait(Magma.HOLD)
		Net:FireClient(plr, "Cinema", "in", kind)
	end)
end

-- `subject` is the doorway, handed over as the shot's subject for the client to
-- frame. Not consumed today -- the tomb and the shrine both pass one and
-- Vault_Client's fade ignores it -- but it is the right thing for the call site
-- to know and costs nothing to keep until the camera work wants it.
function Magma.enter(plr: Player, subject: Vector3?)
	-- Nothing sealed this one either, and nothing is safely over: the room's
	-- whole threat is that it is still live. "Dormant" is what clearing it earns
	-- (see resetName), so the door has to promise the opposite.
	travel(plr, ENTRY, "THE MAGMA CHAMBER", "enter", "THE MOUNTAIN IS ONLY SLEEPING")
end

function Magma.leave(plr: Player)
	-- Resolved now, not at load: see the note on FALLBACK_RETURN. Nobody may be
	-- left sealed in a room with no exit, so this always has an answer even if
	-- buildEntrance never ran.
	travel(plr, Magma.returnCF or FALLBACK_RETURN, "", "leave")
end

return Magma
