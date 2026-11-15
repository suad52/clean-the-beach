-- Clean the Beach :: the sifter, the litter, and all the juice.
-- The sand itself is Terrain and is deformed by the server; this script owns the
-- sifter model, the loose junk lying on the messy sand, and every effect.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer
local CTB = ReplicatedStorage:WaitForChild("CTB")
local Config = require(CTB:WaitForChild("Config"))
-- The cart shows what you are actually carrying, so it needs the one shared
-- inventory the sift/sell add-on replicates. Client.start() is idempotent --
-- ClientMain normally gets there first, and this just removes the ordering
-- dependency between two scripts that otherwise know nothing about each other.
local Modules = ReplicatedStorage:WaitForChild("Modules")
local InventoryController = require(Modules:WaitForChild("InventoryController"))
-- What an item LOOKS like is ItemVisuals' job, not this file's. See buildItem.
local ItemVisuals = require(Modules:WaitForChild("ItemVisuals"))
-- ...and what the SIFTER is made of is SkinConfig's. Every colour, material and
-- reflectance in constructSifter comes out of it, keyed on the SkinActive
-- attribute SkinService publishes. See the note above constructSifter.
local SkinConfig = require(Modules:WaitForChild("SkinConfig"))
local Net = CTB:WaitForChild("Net")

----------------------------------------------------------------
-- Sound
----------------------------------------------------------------
--[[
	The local SND table of eleven `rbxasset://sounds/*` engine clips is gone,
	and so is the hand-rolled play() that fed it. Two reasons, and the second
	matters more than the first:

	  * Those clips are the 2007 core set -- snap, switch, bass, victory, a
	    metal clang. They are bright, short and synthetic, and a beach you are
	    meant to find relaxing cannot be built out of them however good the
	    lighting is.

	  * play() parented every Sound to its own CTB_SFX folder, which is not on
	    any bus. So the Settings panel's Sound Effects toggle -- which works by
	    setting BeachSFX.Volume to 0 -- did nothing to the rake, the dig, the
	    coins or the till. Switching SFX off silenced the two side areas and
	    left the main game at full volume.

	Everything here now goes through AudioKit: real recordings, on the bus, with
	per-shot pitch jitter and an attack ramp. Call sites name a SLOT and, where
	they want one, a relative nudge -- they no longer set absolute levels.
]]
local AudioKit = require(Modules:WaitForChild("AudioKit"))
AudioKit.preload()

-- The rake. Deliberately a DIFFERENT take of the same gravel session the
-- sifting bay pours -- combing sand and sieving sand are the same material and
-- should be recognisably related, but sharing one clip would make the two jobs
-- sound like a single job happening twice.
local drag = AudioKit.loop("RakeDrag")

-- The bed, in two layers. Small waves lapping close, plus a much quieter and
-- slower ocean underneath. Two loops of different lengths (31.5s and 56.9s)
-- never line back up, so the ambience has no period the ear can find -- which
-- is the whole trick to a background that can run for an hour. Set once, with
-- no dt, so they come straight up to level and stay there.
AudioKit.loop("BeachLap"):set(1)
AudioKit.loop("OceanBed"):set(1)

----------------------------------------------------------------
-- Folders
----------------------------------------------------------------
-- CTB_Rake and CTB_Groom are in the sweep but neither is made any more: the
-- raised groove parts and the flat comb tiles that replaced them are both gone.
-- They stay listed so a Studio session still holding either folder gets cleaned.
for _, n in ipairs({ "CTB_Sand", "CTB_Decor", "CTB_Litter", "CTB_Marks", "CTB_Rake", "CTB_Groom", "CTB_Sheen", "CTB_Crust", "CTB_FX", "CTB_Roller", "CTB_Sifter", "CTB_Peers" }) do
	local o = workspace:FindFirstChild(n)
	if o then o:Destroy() end
end
local markFolder = Instance.new("Folder"); markFolder.Name = "CTB_Marks"; markFolder.Parent = workspace
local fxFolder = Instance.new("Folder"); fxFolder.Name = "CTB_FX"; fxFolder.Parent = workspace
-- The loose sand laid over the fields, which is the thing the sifter digs
-- through. Built entirely locally, like the litter and the raked terrain before
-- it, because which columns are cut is this player's business alone.
local crustFolder = Instance.new("Folder"); crustFolder.Name = "CTB_Crust"; crustFolder.Parent = workspace

local function outCubic(x: number): number
	local m = 1 - x
	return 1 - m * m * m
end

----------------------------------------------------------------
-- Surface marks
--
-- Terrain voxels are 4 studs, so nothing footprint-sized can be expressed in the
-- ground itself. Messy sand is therefore covered in flat, soft-edged marks --
-- footprints, drag scuffs, little kicked-up ridges -- in the same sand material,
-- just shaded darker or lighter. The sifter sinks them as it passes, so what the
-- player sees is a churned surface being cleared, not a trench being dug.
----------------------------------------------------------------
-- Keyed by island first, then cell index. A cell index on its own is ambiguous:
-- cell 1 exists on the beach AND on the desert island, and sinking the wrong one
-- would bury a bottle 1500 studs away.
local marksOf = {}                  -- island id -> cell index -> { {part, home}, ... }
local marksBuilt = {}               -- island id -> true once its litter is scattered
for _, isl in ipairs(Config.ISLANDS) do
	marksOf[isl.id] = {}
end
-- Claimed before anything can watch for it: the beach is built by the boot block
-- at the bottom of this script, synchronously, because it is where the player
-- spawns. Without this the arrival watcher would race that and scatter it twice.
marksBuilt[Config.HOME.id] = true

-- Which of each island's columns THIS player has raked, and the dirty rectangle
-- waiting to be written into terrain. Declared up here because the litter
-- scatter below reads `set` to skip cells that are already clean; everything
-- that WRITES it lives in "The sand itself" much further down.
local fields = {}
for _, isl in ipairs(Config.ISLANDS) do
	fields[isl.id] = { set = table.create(isl.cells, false) }
end

--[[
	THE LAYER CAN BE SWITCHED OFF -- MenuHud's Settings -> "Hide Sand Squares",
	off by default.

	The loose sand is drawn as raised squares standing over the ground the tool
	exposes, and some players would rather look at the ground. So the setting
	takes the whole layer out of the picture: the slabs go invisible and this
	lift goes to ZERO with them.

	The lift is the half of it that is easy to miss. Everything that has to sit
	on the SAND rather than on the ground under it reads this one function -- the
	litter scatter, the puff a cut column throws up, the sifter's own wheels --
	so a layer that were merely hidden and still stood half a stud tall would
	leave the entire beach's junk hovering over open ground and the machine
	riding on nothing. Hide it here and all three come down together.

	NOTHING MECHANICAL MOVES. The grid, the finds, the raked percentage and the
	tide are all untouched; this is a view of the field, not a mode of it.
]]
local crustHidden = player:GetAttribute("Set_HideSquares") == true

-- Top of the loose layer, for the things that start AT it rather than on the
-- ground. Config.crustY, minus the setting.
local function crustTop(isl): number
	return crustHidden and Config.surfaceY(isl) or Config.crustY(isl)
end

--[[
	WHETHER RAKING STILL SWAPS THIS ISLAND'S TERRAIN MATERIAL -- which is
	Config.terrainSwapFor, plus the one case Config cannot know about.

	The swap and the crust are alternatives because they FIGHT: the swap paints
	the floor of a channel paler, and paler is what the sand still standing over
	it is supposed to be (see Config.CRUST). But that is a fight between two
	things that are both on screen. Hide the layer and there is nothing left to
	argue with -- and nothing left saying where the player has been either, since
	the walls WERE the record. So the swap comes back exactly when the squares
	go away, and the ground underneath starts carrying the sweep instead.

	With the squares drawn it stays off, and the ground under them is left
	untouched, which is what it has always been.

	DELIBERATELY NOT PUSHED DOWN INTO Config. That module is shared with the
	server, and the server has to go on believing a crusted island writes no
	terrain -- it is the one that lays the all-messy baseline down. This is one
	client's private view of its own copy of the ground, exactly like the raked
	columns themselves.
]]
local function swapFor(isl): boolean
	if Config.terrainSwapFor(isl) then
		return true
	end
	return crustHidden and Config.TERRAIN_DEFORMS
end

-- HOW HIGH THE LOOSE SAND STANDS at one point, measured from the terrain
-- surface. Config.CRUST.rise over an untouched column of a dug field, and zero
-- everywhere else -- off the field, on a field with no crust, on any column
-- this player has already cut, and on every field at once while the layer is
-- hidden.
--
-- Everything that has to sit on the SAND rather than on the ground underneath it
-- adds this: the litter scatter, the puff a cut column throws up, and the
-- sifter's own wheels. Declared up here beside `fields` because the litter
-- scatter is the first thing that needs it and the layer itself is built much
-- further down, in "The loose top layer".
local function crustLift(isl, x: number, z: number): number
	local C = Config.crustFor(isl)
	if not C or crustHidden then
		return 0
	end
	local ix = math.floor((x - isl.x0) / Config.TILE)
	local iz = math.floor((z - isl.z0) / Config.TILE)
	if ix < 0 or iz < 0 or ix >= isl.grid or iz >= isl.grid then
		return 0
	end
	return fields[isl.id].set[Config.index(isl, ix, iz)] and 0 or C.rise
end

local rng = Random.new(Config.SEED)

-- Real junk models (Creator Store trash props) rather than tinted blobs. Each is a
-- single MeshPart, which is what lets the existing sink/raise tweens drive them
-- unchanged -- a Model would need welding to be tweenable as one piece.
-- Per island, and cached on first use. What a field is littered WITH is part of
-- what it is -- washed-up cans on the beaches, spilled gold in the vault -- so
-- the folder name lives on the island row rather than being one global set.
--
-- Every entry must be a single BasePart. That is load-bearing: the sink and
-- raise tweens drive one part directly, and a Model would need welding before
-- it could be moved as a piece.
local templateCache = {}

local function templatesFor(isl): { BasePart }
	local name = isl.litterSet or "Litter"
	if templateCache[name] then
		return templateCache[name]
	end

	local list = {}
	-- The vault's set is built at server boot, so on a fast client this can be
	-- asked for before it has replicated.
	local folder = CTB:WaitForChild(name, 30)
	if folder then
		for _, p in ipairs(folder:GetChildren()) do
			if p:IsA("BasePart") then
				table.insert(list, p)
			end
		end
		table.sort(list, function(a, b) return a.Name < b.Name end)
	end
	if #list == 0 then
		warn(string.format("[CTB] litter set %q is empty -- %s will have a bare floor", name, isl.name))
	end
	templateCache[name] = list
	return list
end

-- Lie a prop flat on the sand and report how tall it ends up. These meshes are
-- modelled Z-up, so anything whose flattest axis is Z has to have that axis turned
-- into the vertical one, or pizza boxes and cartons stand up like billboards.
local function litterRest(size: Vector3): (CFrame, number)
	if size.Z < size.Y then
		return CFrame.Angles(-math.pi / 2, 0, 0), size.Z
	end
	return CFrame.new(), size.Y
end

-- Barely off the terrain sand (196,164,114) on purpose. These are not meant to
-- be seen as coloured marks -- they are bumps, and the shadow each one throws
-- under the low sun is what makes the surface look rough.
local SAND_DARK = Color3.fromRGB(188, 156, 108)
local SAND_LIGHT = Color3.fromRGB(206, 175, 124)

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace.Terrain }
groundParams.IgnoreWater = true

local function terrainY(x: number, z: number): number?
	local hit = workspace:Raycast(Vector3.new(x, 26, z), Vector3.new(0, -60, 0), groundParams)
	return hit and hit.Position.Y or nil
end

local function flatPart(parent: Instance, size: Vector3, cf: CFrame, colour: Color3)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = true
	p.Shape = Enum.PartType.Ball
	p.Size = size
	p.CFrame = cf
	p.Color = colour
	p.Material = Enum.Material.Sand
	p.Parent = parent
	return p
end

local function addMark(islId: number, idx: number, p: BasePart, cf: CFrame)
	local byCell = marksOf[islId]
	local list = byCell[idx]
	if not list then
		list = {}
		byCell[idx] = list
	end
	table.insert(list, { part = p, home = cf })
end

-- Scatter one island's junk. Called for the beach at boot and for every other
-- island the first time the player actually sets foot on it -- see
-- ensureIslandBuilt. Building both up front would put ~900 MeshParts on a phone
-- before it has drawn a frame, most of them 1500 studs from anything the player
-- can see.
local function buildMarks(isl)
	-- terrain streams in after the client starts; marks are placed by raycast so
	-- they sit exactly on the surface rather than floating over the smoothing
	for _ = 1, 200 do
		if terrainY(isl.cx, isl.cz) then break end
		task.wait(0.05)
	end

	local templates = templatesFor(isl)
	if #templates == 0 then
		return 0
	end

	local cleanSet = fields[isl.id].set
	local made, scanned = 0, 0
	for iz = 0, isl.grid - 1 do
		for ix = 0, isl.grid - 1 do
			local idx = Config.index(isl, ix, iz)
			local centre = Config.cellCentre(isl, ix, iz)
			local fallback = Config.surfaceY(isl)

			-- The roll is taken whether or not the cell gets a prop, so an island
			-- built late looks the same as one built at boot: a player who arrives
			-- having already raked some of it sees the junk missing from exactly the
			-- cells they cleared, not a wholly different scatter.
			local roll = rng:NextNumber()
			if roll < isl.litterChance and not cleanSet[idx] then
				local jx = centre.X + rng:NextNumber(-1.5, 1.5)
				local jz = centre.Z + rng:NextNumber(-1.5, 1.5)
				local p = templates[rng:NextInteger(1, #templates)]:Clone()
				local rest, height = litterRest(p.Size)
				-- sit it a little under the surface line rather than balanced on top, so it
				-- reads as dropped and settled into the sand
				--
				-- ON THE LOOSE LAYER, not under it. The raycast finds the TERRAIN, which
				-- on a dug field is the floor of a channel and a good half a bottle below
				-- the sand actually lying there -- so junk placed on it would be buried
				-- from the moment it was scattered, and the smallest pieces would never
				-- be seen at all. crustLift puts it on top of the sand it is lying on;
				-- it returns zero wherever there is no crust, so nothing else changes.
				-- Only untouched cells are scattered into (see the roll above), so this
				-- is always the full rise, and when the tool cuts the column the sand and
				-- the junk standing on it go in the same instant.
				local cf = CFrame.new(jx, (terrainY(jx, jz) or fallback) + crustLift(isl, jx, jz) + height * 0.22, jz)
					* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0)
					* rest
					* CFrame.Angles(rng:NextNumber(-0.12, 0.12), 0, rng:NextNumber(-0.12, 0.12))
				p.CFrame = cf
				p.Parent = markFolder
				addMark(isl.id, idx, p, cf)
				made += 1
			end

			-- YIELD ON CELLS SCANNED, NOT ON PROPS PLACED. This read `made % 400`,
			-- which counts the wrong thing: at Ashfall's 0.0275 litter rate that is
			-- about 14,500 cells, 400 MeshPart clones and 400 raycasts between
			-- yields -- and on a field whose props all fail to place it never fires
			-- at all. The scan is the cost; count the scan.
			scanned += 1
			if scanned % 512 == 0 then
				task.wait()
			end
		end
	end
	return made
end

-- When the tines were last in sand nobody had raked yet. This is what tells
-- cutting from coasting: how hard the tool looks and sounds like it is working
-- all hangs off this timestamp rather than off walking speed, and it is set
-- from the server's Clean batches -- the only thing that actually knows there
-- was sand there to move.
local lastCutAt = -10

-- One epoch per cell, bumped every time its marks are told to sink or rise.
--
-- The tide raises the beach on a DELAY that sweeps up the field (see the Tide
-- branch), so there is a window of nearly two seconds between a cell's raise
-- being scheduled and it actually running. The player is still raking through
-- that window -- the server starts handing out clean columns again the instant
-- the tide resets -- so a cell can be buried by the sifter and then dug straight
-- back up by a raise that was queued before it was ever raked. With Back easing
-- on the way up that reads exactly as trash springing up out of sand the player
-- has just flattened, and nothing sinks it again afterwards, so it stays there
-- until the next tide.
--
-- The epoch is what lets a queued raise notice that the world moved on while it
-- was waiting, and quietly do nothing.
local markEpoch = {}                -- island id -> cell index -> number
for _, isl in ipairs(Config.ISLANDS) do
	markEpoch[isl.id] = {}
end

local function bumpEpoch(islId: number, idx: number): number
	local byCell = markEpoch[islId]
	local e = (byCell[idx] or 0) + 1
	byCell[idx] = e
	return e
end

----------------------------------------------------------------
-- The sheen on raked ground
--
-- IT IS PAINTED NOW, NOT BUILT.
--
-- Every earlier version of this drew the swept ground as PARTS, and every one
-- of them died on the same wall from a different direction. A part is a
-- rectangle. A rectangle cannot be the shape of a curve, so curves came out as
-- rectangles overlapping at angles; and a part's material texture is mapped in
-- the PART's axes, so any two that overlapped showed their grain running two
-- different ways with a seam along the join. Chasing that produced a ledger of
-- covered columns, a lateral clip, a stack of z-offsets and a miter solver --
-- several hundred lines whose entire job was to stop parts from touching each
-- other, because touching is what parts cannot do invisibly.
--
-- So it is a canvas. One image per island, laid over the field, and the sifter
-- draws into it with a round brush. That is the actual shape of what a sifter
-- sweeps -- the set of points within half a tool-width of the path it took --
-- so a curve is curved because it IS the swept region, not an approximation of
-- one built from offcuts.
--
-- And it is exactly idempotent. A pixel the brush covers is written from a
-- value derived from its own coordinates, so the hundredth pass writes the byte
-- the first pass wrote. Measured on a 110-stud lane painted twice: zero bytes
-- different out of 4,194,304. There is nothing left for a ledger to prevent.
--
-- The grain comes from that same per-pixel value, which is why it survived the
-- move: it is anchored to the CANVAS, not to any stroke, so it cannot rotate
-- with anything and cannot break at a join.
--
-- This needs "Allow Mesh & Image APIs" (Game Settings -> Security). If it is
-- ever switched off the API throws on the first draw; canvasFor catches that,
-- says so once, and the sheen simply stops appearing rather than spraying the
-- log with one error per frame.
--
-- ENTIRELY LOCAL AND ENTIRELY COSMETIC. Raked progress is per player, so this
-- is this client's own; the server neither knows nor cares it exists.
----------------------------------------------------------------
local AssetService = game:GetService("AssetService")

local canvasOf = {}                 -- island id -> canvas
local sheenTint = {}
local paintable = true              -- cleared the first time the API refuses

-- Read off the island's own clean material rather than hardcoded, so the band
-- matches whatever ground it is laid on. Cached: GetMaterialColor is global per
-- material and does not change while the place is running.
-- WHICH WAY IT LEANS DEPENDS ON WHETHER THE FIELD IS DUG.
--
-- With no crust the band is laid on raked ground -- matClean -- and lifts a
-- little off it, which is the original behaviour and is what the vault still
-- gets. With a crust, matClean is never painted anywhere on that island and the
-- band is laid on the FLOOR OF A CHANNEL, which is the messy material; there it
-- has to stay DARKER than the loose sand standing beside it, or the swept lane
-- comes out paler than its own walls and reads as filled in rather than dug out.
-- Hence Config.CRUST.sheen_lift, which is negative.
--
-- THAT BRANCH IS CURRENTLY UNREACHABLE, and is kept because it is still the
-- right answer. canvasFor now refuses a canvas altogether on an island whose
-- squares are drawn, so the only crusted field that ever gets a band is one with
-- the layer hidden -- where the swap has already paled the ground and the band
-- leans off matClean the way an undug field's does. Move that gate and this is
-- the arithmetic that has to come back with it.
local function tintFor(isl): Color3
	local t = sheenTint[isl.id]
	if t then
		return t
	end
	local C = Config.crustFor(isl)
	local dug = C ~= nil and not crustHidden
	local mat = dug and isl.matMessy or isl.matClean
	local lift = dug and C.sheen_lift or Config.SHEEN.lift_colour
	local base = Color3.fromRGB(203, 177, 106)
	local ok, c = pcall(function()
		return workspace.Terrain:GetMaterialColor(mat)
	end)
	if ok and c then
		base = c
	end
	t = base:Lerp(lift >= 0 and Color3.new(1, 1, 1) or Color3.new(0, 0, 0), math.abs(lift))
	sheenTint[isl.id] = t
	return t
end

--[[
	THE GRAIN.

	A number near 1 that the tint is multiplied by, built out of the pixel's OWN
	coordinates. Being a pure function of the pixel is the whole point: two
	strokes that cross write the same byte there, so an overlap cannot show and
	no amount of sweeping back and forth builds anything up.

	Two scales. A per-pixel speckle, which is the sand. And a broader variation
	for the cloudiness real flattened sand has -- INTERPOLATED, which is the part
	that had to be fixed: taking one value per 8x8 block made the band a visible
	grid of little squares, which is exactly the "pixelated" look the grain was
	supposed to avoid. Sampling a coarse lattice and smoothstepping between its
	corners gives the same variation with nothing square in it.
]]
local function hash01(x: number, y: number): number
	local n = x * 374761393 + y * 668265263
	n = bit32.bxor(n, bit32.rshift(n, 13))
	n = (n * 1274126177) % 4294967296
	return bit32.band(bit32.bxor(n, bit32.rshift(n, 16)), 0xFF) / 255
end

local function grainAt(x: number, y: number): number
	local S = Config.SHEEN
	local fine = hash01(x, y) - 0.5

	local cell = S.grain_cell
	local fx, fy = x / cell, y / cell
	local ix, iy = math.floor(fx), math.floor(fy)
	local tx, ty = fx - ix, fy - iy
	tx = tx * tx * (3 - 2 * tx)                 -- smoothstep, so no lattice edges
	ty = ty * ty * (3 - 2 * ty)
	local a = hash01(ix, iy)
	local b = hash01(ix + 1, iy)
	local c = hash01(ix, iy + 1)
	local d = hash01(ix + 1, iy + 1)
	local top = a + (b - a) * tx
	local bot = c + (d - c) * tx
	local coarse = top + (bot - top) * ty - 0.5

	return 1 + fine * S.grain_fine + coarse * S.grain_coarse
end

local function canvasFor(isl)
	--[[
		NO POLISH WHILE THE SQUARES ARE UP.

		This band is a REPAINT OF THE GROUND along the path the tool took, and with
		the layer drawn the ground is not the thing that is supposed to be carrying
		the sweep -- the walls are. Owner's call, and the same call as swapFor's:
		with the squares on, walking changes nothing about the surface underneath
		them; with the squares off, the ground records the lot.

		AHEAD OF THE CACHE LOOKUP on purpose. An island that already HAS a canvas
		has to stop painting into it the instant the setting comes back on, not
		carry on because it was handed one earlier.
	]]
	if Config.crustFor(isl) and not crustHidden then
		return nil
	end
	local c = canvasOf[isl.id]
	if c then
		return c
	end
	if not paintable then
		return nil
	end

	local S = Config.SHEEN
	local span = isl.grid * Config.TILE
	-- Same pixels per stud on every island, capped -- a canvas is px*px*4 bytes
	-- and this runs on phones. Sized exactly rather than rounded up to a power
	-- of two: the beach wants 1536 and a power of two would hand it 2048, which
	-- is 16MB instead of 9 for pixels nothing asked for.
	local px = math.clamp(math.round(span * S.px_per_stud), 256, S.px_max)

	local ok, img = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(px, px) })
	end)
	if not ok or not img then
		paintable = false
		warn("[CleanTheBeach] sifted-sand canvas unavailable, the sheen is off: " .. tostring(img))
		return nil
	end

	local plane = Instance.new("Part")
	plane.Name = "Sheen_" .. isl.name
	plane.Anchored = true
	plane.CanCollide = false
	plane.CanQuery = false
	plane.CanTouch = false
	plane.CastShadow = false
	plane.Transparency = 1              -- the decal is the only thing that shows
	plane.Size = Vector3.new(span, S.thickness, span)
	-- Set INTO the sand exactly as the old slabs were: the top face clears the
	-- terrain by `lift` and the rest is buried, so no edge stands proud.
	plane.CFrame = CFrame.new(
		isl.x0 + span * 0.5,
		Config.surfaceY(isl) + S.lift - S.thickness * 0.5,
		isl.z0 + span * 0.5
	)
	plane.Parent = workspace

	local decal = Instance.new("Decal")
	decal.Name = "Canvas"
	decal.Face = Enum.NormalId.Top
	decal.TextureContent = Content.fromObject(img)
	decal.Parent = plane

	local tint = tintFor(isl)
	c = {
		img = img,
		plane = plane,
		px = px,
		pps = px / span,
		-- Our own record of HOW MUCH of each pixel is painted, 0..255, so a write
		-- can rebuild a whole box from scratch without reading the image back.
		-- Coverage rather than a yes/no: a straight edge that lands halfway
		-- across a pixel sets that pixel to half, which is what stops the band
		-- from having a staircase down its side.
		cover = buffer.create(px * px),
		r = math.floor(tint.R * 255 + 0.5),
		g = math.floor(tint.G * 255 + 0.5),
		b = math.floor(tint.B * 255 + 0.5),
	}
	canvasOf[isl.id] = c
	return c
end

-- A decal's top face runs its UVs AGAINST world X and Z. Measured, not assumed:
-- painted with the obvious mapping, a bar drawn from one corner turned up in the
-- opposite one. Both axes flip.
local function toPx(c, isl, x: number, z: number): (number, number)
	return c.px - (x - isl.x0) * c.pps, c.px - (z - isl.z0) * c.pps
end

-- Writes one rectangle of the canvas from `cover`, so anything already painted
-- inside it comes back byte-identical and only genuinely new pixels change.
local function flush(c, x0: number, y0: number, x1: number, y1: number)
	x0, y0 = math.max(0, x0), math.max(0, y0)
	x1, y1 = math.min(c.px - 1, x1), math.min(c.px - 1, y1)
	if x1 < x0 or y1 < y0 then
		return
	end
	local w, h = x1 - x0 + 1, y1 - y0 + 1
	local buf = buffer.create(w * h * 4)
	for py = y0, y1 do
		local row = py * c.px
		local out = (py - y0) * w
		for pxi = x0, x1 do
			local a = buffer.readu8(c.cover, row + pxi)
			if a > 0 then
				local o = (out + (pxi - x0)) * 4
				local k = grainAt(pxi, py)
				buffer.writeu8(buf, o,     math.clamp(math.floor(c.r * k), 0, 255))
				buffer.writeu8(buf, o + 1, math.clamp(math.floor(c.g * k), 0, 255))
				buffer.writeu8(buf, o + 2, math.clamp(math.floor(c.b * k), 0, 255))
				buffer.writeu8(buf, o + 3, a)
			end
		end
	end
	c.img:WritePixelsBuffer(Vector2.new(x0, y0), Vector2.new(w, h), buf)
end

--[[
	THE BRUSH IS A BLADE, NOT A DOT.

	The sifter is a straight bar dragged behind the player, so the ground it
	sweeps between two instants is the RECTANGLE joining the bar's two positions
	-- square across the path at both ends, straight down both sides. It was a
	round stamp before, which rounded off the head and every corner; a blade
	does not leave a rounded mark.

	Curves still come out curved without a curve ever being drawn: a turn is just
	the union of many quads, each a fraction of a stud long and each a degree or
	so off the last. That union IS the swept region, which is why it needs no
	mitering, no joins and no corner cases -- the shape falls out of painting the
	same ground twice being free.

	The edge is ANTIALIASED off a signed distance to the quad rather than being
	in or out, so a lane that does not happen to fall on pixel boundaries still
	reads as a straight line instead of a staircase. Coverage is combined by MAX,
	which is what keeps it exactly idempotent: max(x, x) is x, so a second pass
	over the same ground writes the same byte, edges included.
]]
local function paintStroke(isl, a: Vector3, b: Vector3, halfWidth: number)
	local c = canvasFor(isl)
	if not c then
		return
	end
	local S = Config.SHEEN
	local ax, ay = toPx(c, isl, a.X, a.Z)
	local bx, by = toPx(c, isl, b.X, b.Z)
	local dx, dy = bx - ax, by - ay
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 1e-5 then
		return
	end
	local ux, uy = dx / len, dy / len            -- along the path
	local hl = len * 0.5 + S.join                -- half length, grown to lap the last quad
	local hw = halfWidth * c.pps                 -- half the blade, in pixels
	local cx, cy = (ax + bx) * 0.5, (ay + by) * 0.5

	local reach = math.max(hl, hw) + 2
	local x0 = math.max(0, math.floor(cx - reach))
	local x1 = math.min(c.px - 1, math.ceil(cx + reach))
	local y0 = math.max(0, math.floor(cy - reach))
	local y1 = math.min(c.px - 1, math.ceil(cy + reach))

	local touched = false
	for py = y0, y1 do
		local row = py * c.px
		local ry = py + 0.5 - cy
		for pxi = x0, x1 do
			local rx = pxi + 0.5 - cx
			-- the pixel in the quad's own frame
			local al = rx * ux + ry * uy
			local pe = ry * ux - rx * uy
			-- signed distance to the rectangle: negative inside, positive out
			local qx = math.abs(al) - hl
			local qy = math.abs(pe) - hw
			local ox, oy = math.max(qx, 0), math.max(qy, 0)
			local d = math.sqrt(ox * ox + oy * oy) + math.min(math.max(qx, qy), 0)
			if d < 0.5 then
				local i = row + pxi
				local v = math.floor(math.clamp(0.5 - d, 0, 1) * 255 + 0.5)
				if v > buffer.readu8(c.cover, i) then
					buffer.writeu8(c.cover, i, v)
					touched = true
				end
			end
		end
	end
	if touched then
		flush(c, x0, y0, x1, y1)
	end
end

local function sweepSheenAway(isl)
	local c = canvasOf[isl.id]
	if not c then
		return
	end
	buffer.fill(c.cover, 0, 0)
	c.img:WritePixelsBuffer(Vector2.zero, Vector2.new(c.px, c.px), buffer.create(c.px * c.px * 4))
end

----------------------------------------------------------------
-- Where to paint: the tool's path.
--
-- All that survives from the geometry versions, because the question it answers
-- has nothing to do with how the mark is made: given that the polish always
-- lags the sand -- nothing is drawn until the SERVER confirms a raked column --
-- which stretch of ground has genuinely been sifted and should be filled in.
----------------------------------------------------------------
local function rakedAt(isl, p: Vector3): boolean
	local f = fields[isl.id]
	if not (f and f.set) then
		return false
	end
	local ix = math.floor((p.X - isl.x0) / Config.TILE)
	local iz = math.floor((p.Z - isl.z0) / Config.TILE)
	if ix < 0 or iz < 0 or ix >= isl.grid or iz >= isl.grid then
		return false
	end
	return f.set[Config.index(isl, ix, iz)] == true
end

-- Sampled at half a tile, so no column between the ends can be stepped over.
-- Not every sample has to pass: SHEEN.lead studs of it may be unraked, because
-- the head of the band always overhangs the last confirmed column by the length
-- the tool is held out in front. A real stretch of untouched beach is far longer
-- than that and still fails.
local function rakedBetween(isl, from: Vector3, to: Vector3): boolean
	local stepLen = Config.TILE * 0.5
	local span = to - from
	local steps = math.max(1, math.ceil(span.Magnitude / stepLen))
	local slack = math.ceil(Config.SHEEN.lead / stepLen)
	local miss = 0
	for i = 0, steps do
		if not rakedAt(isl, from + span * (i / steps)) then
			miss += 1
			if miss > slack then
				return false
			end
		end
	end
	return true
end

-- Where a new run should actually begin: not under the tool, but as far back
-- along the way it came as the ground behind it has already been raked. See
-- SHEEN.lookBack -- the polish is always a beat behind the sand because it waits
-- on the server, and this is what pays that beat back. Overshooting into ground
-- that was already painted costs nothing now, which is why this no longer has to
-- know anything about what has been painted.
local function seedFrom(isl, here: Vector3, dir: Vector3?): Vector3
	if not dir then
		return here
	end
	local back = Vector3.new(dir.X, 0, dir.Z)
	if back.Magnitude < 1e-4 then
		return here
	end
	back = back.Unit
	local S = Config.SHEEN
	local stepLen = Config.TILE * 0.5
	local slack = math.ceil(S.lead / stepLen)
	local best, miss = here, 0
	for i = 1, math.floor(S.lookBack / stepLen) do
		local p = here - back * (stepLen * i)
		if rakedAt(isl, p) then
			best, miss = p, 0
		else
			miss += 1
			if miss > slack then
				break
			end
		end
	end
	return best
end

local trail = nil                   -- { islId, at, paused }

local function sheenBreak()
	if trail then
		trail.paused = true
	end
end

local function sheenTrail(isl, at: Vector3, toolWidth: number, dir: Vector3?)
	local S = Config.SHEEN
	if not S.enabled then
		return
	end
	local here = Vector3.new(at.X, 0, at.Z)
	-- Half the blade. SHEEN.spread is 0, so this is the tool's own width.
	local r = (toolWidth + S.spread) * 0.5

	if not trail or trail.islId ~= isl.id then
		trail = { islId = isl.id, at = seedFrom(isl, here, dir) }
		return
	end

	-- Coming back from a pause. Carry straight on if the tool is near enough to
	-- where it stopped, or if what lies between is ground this player raked --
	-- which is the case after a stop, since the columns crossed while the server
	-- caught up are confirmed by the time the first frame may draw. Anything
	-- else and the run starts fresh: sand that was never cut must not be
	-- painted as if it were.
	if trail.paused then
		trail.paused = nil
		local gap = (here - trail.at).Magnitude
		if gap > S.rejoin and not rakedBetween(isl, trail.at, here) then
			trail.at = seedFrom(isl, here, dir)
			return
		end
	end

	local moved = (here - trail.at).Magnitude
	-- A teleport, a respawn or a ferry crossing. Do not drag a 1500-stud stripe
	-- across the ocean to catch up.
	if moved > 24 then
		trail.at = seedFrom(isl, here, dir)
		return
	end
	-- One write per SHEEN.step rather than per frame: a quarter-stud advance
	-- would rewrite almost exactly the same box for nothing. The head lags by at
	-- most this much, which is why it is small.
	if moved < S.step then
		return
	end

	paintStroke(isl, trail.at, here, r)
	trail.at = here
end

----------------------------------------------------------------
-- Ground raked in an EARLIER session.
--
-- A rejoin knows WHICH columns this player raked but nothing about the path
-- walked to do it, so there is no stroke to lay -- only the grid. The columns
-- go straight into the coverage record and the whole canvas is written once,
-- rather than a write per column: it arrives as one batch of thousands, and one
-- pass over the canvas costs less than a thousand overlapping little ones.
----------------------------------------------------------------
local function paintCells(isl, list)
	local S = Config.SHEEN
	if not S.enabled or #list == 0 then
		return
	end
	local c = canvasFor(isl)
	if not c then
		return
	end

	local step = Config.TILE * c.pps
	for _, idx in ipairs(list) do
		local ix, iz = Config.coords(isl, idx)
		local ux = c.px - (ix * Config.TILE) * c.pps
		local uz = c.px - (iz * Config.TILE) * c.pps
		local x0 = math.max(0, math.floor(ux - step))
		local x1 = math.min(c.px - 1, math.ceil(ux) - 1)
		local y0 = math.max(0, math.floor(uz - step))
		local y1 = math.min(c.px - 1, math.ceil(uz) - 1)
		for py = y0, y1 do
			local row = py * c.px
			for pxi = x0, x1 do
				buffer.writeu8(c.cover, row + pxi, 255)
			end
		end
	end
	flush(c, 0, 0, c.px - 1, c.px - 1)
end


-- Straight down in WORLD space, not the part's own space: litter is laid flat by a
-- quarter turn about its local X, so a local-space drop would slide it sideways
-- into the neighbouring cell instead of burying it.
local function sinkMarks(islId: number, idx: number, instant: boolean)
	bumpEpoch(islId, idx)
	local list = marksOf[islId][idx]
	if not list then return end
	for _, d in ipairs(list) do
		-- Drop it out of the shadow map immediately. A moving shadow caster forces a
		-- shadow rebuild every frame of the tween, and these are being removed
		-- anyway, so there is nothing to gain by keeping them casting on the way down.
		d.part.CastShadow = false
		if instant then
			d.part.Transparency = 1
			d.part.CFrame = d.home + Vector3.new(0, -2, 0)
		elseif not (sweepMark and sweepMark(d, islId, idx)) then
			-- The fallback, and still the right answer when too many props are
			-- already in the air: drop it and fade it.
			TweenService:Create(d.part, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				CFrame = d.home + Vector3.new(0, -1.2, 0),
				Transparency = 1,
			}):Play()
		end
	end
end

local function raiseMarks(islId: number, idx: number, delay: number)
	local list = marksOf[islId][idx]
	if not list then return end
	local epoch = bumpEpoch(islId, idx)
	task.delay(delay, function()
		-- Raked again while the tide was still sweeping toward this cell. The
		-- player has already buried this lot, and the server agrees the column is
		-- clean, so leave it buried.
		if markEpoch[islId][idx] ~= epoch then return end
		for _, d in ipairs(list) do
			d.part.CastShadow = true
			TweenService:Create(d.part, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				CFrame = d.home,
				Transparency = 0,
			}):Play()
		end
	end)
end

----------------------------------------------------------------
-- Particles
----------------------------------------------------------------
local SAND_TEX = "rbxasset://textures/particles/smoke_main.dds"
local SPARK_TEX = "rbxasset://textures/particles/sparkles_main.dds"

local function emitterPart(pos: Vector3)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.new(0.2, 0.2, 0.2)
	p.CFrame = CFrame.new(pos)
	p.Parent = fxFolder
	return p
end

local function sandBurst(pos: Vector3, count: number)
	local p = emitterPart(pos)
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = SAND_TEX
	pe.Color = ColorSequence.new(Color3.fromRGB(236, 216, 172), Color3.fromRGB(208, 182, 136))
	pe.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(0.4, 2.0),
		NumberSequenceKeypoint.new(1, 2.8),
	})
	pe.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(0.6, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	pe.Lifetime = NumberRange.new(0.3, 0.7)
	pe.Speed = NumberRange.new(5, 13)
	pe.SpreadAngle = Vector2.new(55, 55)
	pe.Acceleration = Vector3.new(0, -26, 0)
	pe.Rotation = NumberRange.new(0, 360)
	pe.RotSpeed = NumberRange.new(-140, 140)
	pe.Rate = 0
	pe.LightEmission = 0.2
	pe.Parent = p
	pe:Emit(count)
	-- The longest a grain lives is 0.7s, so the old 2s left every holder part
	-- sitting there inert for more than a second after its last particle had
	-- gone. That did not matter when a puff fired on one raked cell in five; now
	-- that every cell throws one it was doubling the live part count for nothing.
	Debris:AddItem(p, 1.2)
end

local function sparkBurst(pos: Vector3, count: number, colour: Color3)
	local p = emitterPart(pos)
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = SPARK_TEX
	pe.Color = ColorSequence.new(colour)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.1), NumberSequenceKeypoint.new(1, 0) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	pe.Lifetime = NumberRange.new(0.5, 1.0)
	pe.Speed = NumberRange.new(9, 20)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Acceleration = Vector3.new(0, -18, 0)
	pe.Rate = 0
	pe.LightEmission = 1
	pe.Parent = p
	pe:Emit(count)
	Debris:AddItem(p, 2.5)
end

----------------------------------------------------------------
-- The sifter
--
-- A dragged sand sifter, not a drum. A wire basket on two small barrow wheels at
-- the end of a long handle: the tines along the leading edge comb through the
-- top of the sand, the sand drops straight back out through the mesh floor, and
-- whatever is too big to fit through stays in the basket. Nothing on the tool
-- turns except those two wheels, and they turn only because they are rolling
-- along -- none of the work is done by anything spinning.
--
-- SIZE. This used to be a 16-stud drum that upgraded to 64. 64 studs is half the
-- width of the entire beach and about thirty times a player's shoulders; even
-- the starting 16 was eight times. It is a hand tool now: level 1 is 6 studs,
-- roughly three shoulder-widths, and the top of the ladder is 16 -- where the
-- old one STARTED. Config.LEVELS is the only place that number lives and the
-- server sweeps exactly the width drawn here, so the two cannot drift apart.
----------------------------------------------------------------
local sifterModel: Model? = nil
-- Where the basket is RIGHT NOW, republished every frame by the render loop.
-- popItem needs it to aim a find into the cart, and it cannot work it out for
-- itself: the cart rides in front of a player who is usually still walking, so
-- anything sampled once lands behind them.
local cartCF: CFrame? = nil
-- Four lists because four things behave differently: the wheels roll, the body
-- judders, the handle stays rigid (the player's hands are IK'd onto it), and the
-- caught grit rattles about on the mesh.
local wheelParts, bodyParts, rigidParts, cartParts, bermParts = {}, {}, {}, {}, {}
local dustEmitter: ParticleEmitter? = nil
local siftEmitter: ParticleEmitter? = nil
local spillEmitters: { ParticleEmitter } = {}
local wheelSpin = 0

--[[
	THE TOOL'S COLOURS LIVE IN SkinConfig NOW, and its `standard` row carries
	the exact five that used to be here -- mesh, frame, blade, rubber and grip.
	constructSifter reads them through `skp`.

	STEEL SURVIVES because four of its users are INVISIBLE: the dust plate, the
	sift-through plate and the two side-spill holders are all Transparency 1 and
	exist only to carry an emitter. Their colour has never been seen and has no
	business changing with a skin.
]]
local STEEL = Color3.fromRGB(196, 200, 206)

-- The basket, in the tool's own frame. Local +Z runs BACK toward the player, so
-- the tines live at -Z. Y is measured from the wheel axle, which rides exactly
-- one wheel radius above the sand -- so anything below -Config.ROLLER_RADIUS is
-- under the surface, and only the blade and the tine tips ever are.
local BASKET_LEN = 2.4
local BASKET_H = 0.95
local FLOOR_Y = -0.3                                  -- mesh floor: skims the sand

----------------------------------------------------------------
-- SWEEPING LITTER INTO THE BASKET
--
-- What raking a cell used to look like: every piece of litter on it dropped 1.2
-- studs straight down and faded out. That reads as BURYING, which is the
-- opposite of the verb -- and it is what the player watches most of the time,
-- because a cell is three times more likely to carry decorative litter
-- (litterChance 0.15) than a payable find (itemChance 0.05). Finds already
-- arced up and into the cart; this gives the litter the same move, so the tool
-- looks like it is collecting rather than ploughing things under.
--
-- ONE RenderStepped FOR EVERY FLIGHT IN THE AIR, made when the first one needs
-- it and dropped when the last one lands -- the same shape ItemVisuals uses for
-- knocked-off crust, and for the same reason: a full-width sweep clears several
-- columns in a tick and each column can carry a handful of props, so a
-- connection per prop would be dozens of connections a second.
--
-- THE PART IS NEVER DESTROYED. It is the same prop raiseMarks puts back when
-- the tide (or the sandstorm) turns, so a flight ends by parking it exactly
-- where sinkMarks used to leave it: buried, invisible, not casting a shadow.
----------------------------------------------------------------
local SWEEP_TIME = 0.46
local SWEEP_ARC = 1.6
local SWEEP_RISE = 0.42        -- fraction of the flight spent going up
local SWEEP_MAX = 26           -- concurrent flights before falling back to a sink

local sweeps = {}
local sweepConn: RBXScriptConnection? = nil

local function endSweep(s, park: boolean)
	if s.light then
		s.light:Destroy()
	end
	if park and s.d.part.Parent then
		s.d.part.Size = s.size
		s.d.part.CFrame = s.d.home + Vector3.new(0, -2, 0)
		s.d.part.Transparency = 1
	end
end

local function stepSweeps(dt: number)
	for i = #sweeps, 1, -1 do
		local s = sweeps[i]

		-- The tide came back for this cell while the prop was still in the air, or
		-- the field was rebuilt under it. raiseMarks owns the part now; let go
		-- without touching it again, or the two fight over the same CFrame.
		if markEpoch[s.islId][s.idx] ~= s.epoch or not s.d.part.Parent then
			endSweep(s, false)
			table.remove(sweeps, i)
			continue
		end

		s.t += dt
		local a = math.min(s.t / SWEEP_TIME, 1)

		-- Re-read the basket every frame. It rides in front of a player who is
		-- usually still walking, so a target sampled once lands behind them --
		-- the same note popItem carries, and the same reason.
		local target = cartCF and (cartCF * CFrame.new(0, FLOOR_Y + 0.3, 0)).Position
			or (s.from + Vector3.new(0, 2, 0))

		-- Ground track and height solved separately: eases out toward the basket
		-- horizontally, lofts and then drops in vertically.
		local ease = outCubic(a)
		local apex = math.max(s.from.Y, target.Y) + SWEEP_ARC
		local y
		if a < SWEEP_RISE then
			local r = a / SWEEP_RISE
			y = s.from.Y + (apex - s.from.Y) * (1 - (1 - r) * (1 - r))
		else
			local r = (a - SWEEP_RISE) / (1 - SWEEP_RISE)
			y = apex + (target.Y - apex) * (r * r)
		end

		s.d.part.CFrame = CFrame.new(
			s.from.X + (target.X - s.from.X) * ease,
			y,
			s.from.Z + (target.Z - s.from.Z) * ease) * s.spin * CFrame.Angles(0, a * 7, 0)
		s.d.part.Size = s.size * (1 - 0.55 * a)
		-- Held solid for most of the flight and only faded at the very end, as it
		-- drops past the rim. Fading it early would read as the litter evaporating
		-- on the way rather than going in.
		s.d.part.Transparency = math.max(0, (a - 0.74) / 0.26)
		if s.light then
			-- Brightest at the top of the arc: the glow is the moment it comes OUT
			-- of the sand, not a lamp riding a bottle across the beach.
			s.light.Brightness = 3.2 * math.sin(a * math.pi)
		end

		if a >= 1 then
			endSweep(s, true)
			table.remove(sweeps, i)
		end
	end

	if #sweeps == 0 and sweepConn then
		sweepConn:Disconnect()
		sweepConn = nil
	end
end

sweepMark = function(d, islId: number, idx: number): boolean
	if #sweeps >= SWEEP_MAX then
		return false
	end

	local light = Instance.new("PointLight")
	-- The prop's own colour pulled halfway to white. Its own colour alone barely
	-- reads against lit sand, and pure white would make every piece of litter on
	-- the beach glow the same -- a bottle should come up green.
	light.Color = d.part.Color:Lerp(Color3.new(1, 1, 1), 0.45)
	light.Range = 9
	light.Brightness = 0
	light.Shadows = false
	light.Parent = d.part

	table.insert(sweeps, {
		d = d,
		islId = islId,
		idx = idx,
		-- sinkMarks has already bumped this, so it is the epoch of the sweep that
		-- sent us -- anything later means somebody else has claimed the prop.
		epoch = markEpoch[islId][idx],
		from = d.home.Position,
		spin = d.home.Rotation,
		size = d.part.Size,
		light = light,
		t = 0,
	})

	if not sweepConn then
		sweepConn = RunService.RenderStepped:Connect(stepSweeps)
	end
	return true
end
local BAR = 0.1                                       -- mesh wire thickness
local TINE_LEN = 0.75

--[[
	Where the handlebar sits in the tool's own frame: +Y up from the axle, +Z
	back toward the player. This is a reach budget, not a styling choice.

	GRIP_Y went 1.8 -> 2.85 when the tool shrank, and that is not a retune: the
	model origin dropped from a 1.6-stud drum axle to a 0.55-stud wheel axle, so
	the bar had to come up by exactly that 1.05 to land in the same place in the
	world. What changed is the handle, which is now a long pole running from the
	sand up to chest height -- which is what a tool you drag actually looks like.

	GRIP_Z IS A DEFAULT NOW, NOT THE ANSWER -- see gripZFor below. The note that
	used to live here set it from "an R15 arm only spans about 1.75 studs from
	the shoulder to the middle of the fist", which is ONE avatar's arm and is not
	a constant of the platform.
]]
local GRIP_Y, GRIP_Z = 2.85, 3.15
local HAND_SPAN = 1.15          -- out along the bar from centre, where the rails meet it
local HAND_TILT = CFrame.Angles(math.rad(75), 0, 0)   -- fingers rolled forward over it
local HAND_SINK = 0.12          -- bar in the fingers, not the palm

-- Rebuilt with the tool, held by the IKControls set up at the bottom of the
-- file. `pinHands` is assigned down there too; buildSifter calls it so that
-- upgrading to a wider basket re-hands the player onto the new bar.
local gripAttach: { [number]: Attachment } = {}
local pinHands: (() -> ())? = nil

--[[
	THE REACH BUDGET IS PER-AVATAR, AND THAT IS THE BUG THIS FIXES.

	The budget was authored against an arm "about 1.75 studs" long, which made a
	reach of ~1.4 correct -- 80% extension, a comfortable bend. Measured on the
	account this was reported from, the arm is 3.26 (UpperArm 1.21 + LowerArm
	1.16 + Hand 0.89). At 1.4 that same arm is folded to 43% of its length and
	stays there for the whole session. Avatar scaling, body types and R15
	packages all move that number and nothing else in this file knew about them.

	WHY A FOLDED ARM SHAKES. An IK chain bent that far past its comfortable range
	has a wide circle of elbow positions that all satisfy the target equally, and
	no pole vector to choose between them, so the solver picks a different one
	almost every frame. Measured over 600 frames of hard turns: the elbow crossed
	the shoulder-hand axis 179 times on the left and 183 on the right -- a flip
	every three frames -- with single-frame elbow movement up to 0.72 studs IN
	THE BODY'S OWN FRAME, i.e. with locomotion already divided out. On screen
	that is both arms shaking and the hands leaving the bar on every turn.

	It is NOT the release logic and it is not the solver falling behind: through
	all of it ik.Weight stays 1.00, ik.Enabled stays true, the humanoid never
	leaves Running, the tool's yaw tracks the body to 0.0 degrees, and the target
	is never further than 1.32 studs from a shoulder with 3.26 available. Setting
	an IKControl.Pole changes nothing, because the fault is the fold, not the
	choice of elbow side.

	So the bar is placed off the arm the player is actually wearing.
]]
-- Of the arm's length. Short of straight on purpose: at 1.0 the walk sway
-- yanks a locked elbow, which is the failure at the other end of this axis.
local GRIP_EXTEND = 0.78
-- The bar may travel forward to meet a long arm but never past the axle, and
-- never further back than the authored default.
local GRIP_Z_MIN, GRIP_Z_MAX = 1.5, 3.15

-- Resolved per character by gripZFor and read by BOTH the builder and
-- gripCFrame, which have to agree or the hands aim at a bar that is not there.
local gripZNow = GRIP_Z

local function gripZFor(char: Model?): number
	if not char then
		return GRIP_Z
	end
	local arm = 0
	for _, n in ipairs({ "RightUpperArm", "RightLowerArm", "RightHand" }) do
		local p = char:FindFirstChild(n)
		-- R6, or limbs that have not streamed in yet. Either way there is nothing
		-- to measure, and a tool built around a nil is worse than the default.
		if not (p and p:IsA("BasePart")) then
			return GRIP_Z
		end
		arm += p.Size.Y
	end
	local upper = char:FindFirstChild("RightUpperArm")
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not (upper and hrp and hum) then
		return GRIP_Z
	end

	-- Solve the triangle: the bar has to sit `want` from the shoulder, and its
	-- height above the sand is already fixed by GRIP_Y, so the only free leg is
	-- how far forward it goes.
	local feet = hrp.Position.Y - hrp.Size.Y * 0.5 - hum.HipHeight
	local shoulder = upper.Position.Y + upper.Size.Y * 0.5 - feet
	local dy = shoulder - (Config.ROLLER_RADIUS + GRIP_Y)
	local want = arm * GRIP_EXTEND
	-- A floor under the forward leg, for the avatar so small that the bar is
	-- already further below its shoulder than the whole arm is long: there is no
	-- real solution there, and 0.5 keeps the bar in front of them rather than
	-- collapsing it onto the axle.
	local fwd = math.sqrt(math.max(want * want - dy * dy, 0.25))
	return math.clamp(Config.ROLLER_DIST - fwd, GRIP_Z_MIN, GRIP_Z_MAX)
end

local function rp(model: Model, size: Vector3, colour: Color3, material: Enum.Material, shape: Enum.PartType?)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	if shape then p.Shape = shape end
	p.Size = size
	p.Color = colour
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

-- The mesh is a lot of little bars and every one of them is re-CFramed each
-- frame, so the fine wire does not cast shadow. The rim, the wheels and the
-- blade still do, and that is what puts the tool ON the sand rather than over it.
local function noShadow(p: BasePart): BasePart
	p.CastShadow = false
	return p
end

local sifterWidth = Config.LEVELS[1].width
-- Which skin the model in the player's hands was BUILT in. What syncSkin down
-- in the boot block compares against, so an attribute write that does not
-- actually move the skin never drops the tool out of their hands to rebuild an
-- identical one -- the same guard syncSifterWidth has for the width.
local skinNow = SkinConfig.DefaultKey

--[[
	ONE BUILDER, TWO CUSTOMERS.

	The tool in your hands and the tool the player beside you is dragging are the
	SAME MODEL, built here from the same numbers -- because the whole point of
	drawing somebody else's sifter is being able to compare it with your own, and
	two builders would eventually disagree about what a width of 30 looks like.
	See the peer block at the bottom of this file.

	It builds and hands back a RIG. It does not touch any of the module-level
	state the render loop walks, does not parent the model, and does not measure
	anything off the local character -- all three of those belong to whoever
	asked, and there is now more than one asker.

	`gripZ` ARRIVES for that reason: how far forward the handle sits is a
	property of the ARM that will be holding it (gripZFor), and peers have their
	own arms.

	`opts` is what the two customers do not share:

		effects   the dust, the sift-through, the side spill and the windrow.
		          All of it is driven by `load` and `cutting`, which are this
		          client's answer to "did the server just tell ME I raked
		          something" -- so a peer's copy would be sand invented locally.
		detail    density of the mesh floor, the back wall and the tine row,
		          0..1. The SILHOUETTE and the WIDTH never move -- those are the
		          thing being compared -- so this only thins wire, which is what
		          costs parts and is indistinguishable ten studs away.
		shadows   off for peers. Eight tools' worth of fine wire is not worth a
		          shadow map.
		skin      a SkinConfig key. NOT shared, and not for the reason the other
		          three are not: a peer's skin is a real, replicated fact about
		          them (Player attributes reach every client), so their tool is
		          drawn in the skin they actually claimed. It arrives as an
		          option only because THIS client's answer comes off its own
		          Player and a peer's comes off theirs.

	THE SKIN IS A PALETTE, NOT A MODEL. Everything below is the same basket,
	blade and pair of barrow wheels it has always been; a skin changes what each
	piece is MADE OF, plus one charm that could not belong to any other room. One
	build path, so the tool in your hands cannot be a different SHAPE from the
	showpiece you claimed it off.
]]
local function constructSifter(width: number, gripZ: number, opts)
	local effects = not (opts and opts.effects == false)
	local shadows = not (opts and opts.shadows == false)
	local detail = math.clamp((opts and opts.detail) or 1, 0.15, 1)
	local sk = SkinConfig.get((opts and opts.skin) or player:GetAttribute(SkinConfig.ActiveAttribute))

	-- A part in one of the skin's own materials. The single seam between this
	-- file and SkinPlinthBuilder's showpiece. NOT called `sp` -- the sift-through
	-- emitter plate down at the bottom of this function already owns that name.
	local function skp(model: Model, size: Vector3, key: string, shape: Enum.PartType?)
		local pc = sk.pieces[key]
		local p = rp(model, size, pc.c, pc.m, shape)
		if pc.r > 0 then
			p.Reflectance = pc.r
		end
		return p
	end

	local rig = {
		width = width,
		wheelParts = {}, bodyParts = {}, rigidParts = {}, bermParts = {},
		spill = {}, gripAttach = {},
	}

	local R = Config.ROLLER_RADIUS                    -- wheel radius == ride height
	local prng = Random.new(Config.SEED + 7)
	local m = Instance.new("Model")
	m.Name = "CTB_Sifter"

	local halfW = width * 0.5
	local zFront, zBack = -BASKET_LEN * 0.5, BASKET_LEN * 0.5
	local rimY = FLOOR_Y + BASKET_H

	-- Mesh floor: real crossed wire, not a plate with a texture on it. The gaps
	-- are the entire point -- the sand visibly goes straight back through them.
	local ribs = math.max(3, math.floor(BASKET_LEN / 0.5))
	for i = 0, ribs do
		local p = noShadow(skp(m, Vector3.new(width, BAR, BAR), "mesh"))
		table.insert(rig.bodyParts, { part = p, off = CFrame.new(0, FLOOR_Y, zFront + (i / ribs) * BASKET_LEN) })
	end
	local wires = math.max(4, math.floor(width * detail / 0.7))
	for i = 0, wires do
		-- The ember skin lights every third wire, so the floor reads as a grate
		-- with something still glowing under it rather than as dark mesh. Same
		-- rule as the showpiece on the plinth -- see SkinPlinthBuilder.
		local p = noShadow(skp(m, Vector3.new(BAR, BAR, BASKET_LEN),
			(sk.charm == "ember" and i % 3 == 0) and "tine" or "mesh"))
		table.insert(rig.bodyParts, { part = p, off = CFrame.new(-halfW + (i / wires) * width, FLOOR_Y, 0) })
	end

	-- Rim all the way round, four uprights a side, and a wired back wall so what
	-- has been caught cannot simply fall out behind. The sides are left as open
	-- frame rather than full wire: at this size nobody can tell, and it keeps the
	-- part count sane on the widest upgrade.
	for _, z in ipairs({ zFront, zBack }) do
		local p = skp(m, Vector3.new(width, BAR * 1.7, BAR * 1.7), "frame")
		table.insert(rig.bodyParts, { part = p, off = CFrame.new(0, rimY, z) })
	end
	for _, sx in ipairs({ -1, 1 }) do
		local rail = skp(m, Vector3.new(BAR * 1.7, BAR * 1.7, BASKET_LEN), "frame")
		table.insert(rig.bodyParts, { part = rail, off = CFrame.new(sx * halfW, rimY, 0) })
		for i = 0, 3 do
			local p = noShadow(skp(m, Vector3.new(BAR, BASKET_H, BAR), "mesh"))
			table.insert(rig.bodyParts, {
				part = p,
				off = CFrame.new(sx * halfW, FLOOR_Y + BASKET_H * 0.5, zFront + (i / 3) * BASKET_LEN),
			})
		end
	end
	local backBars = math.max(3, math.floor(width * detail / 0.8))
	for i = 0, backBars do
		local p = noShadow(skp(m, Vector3.new(BAR, BASKET_H, BAR), "mesh"))
		table.insert(rig.bodyParts, {
			part = p,
			off = CFrame.new(-halfW + (i / backBars) * width, FLOOR_Y + BASKET_H * 0.5, zBack),
		})
	end

	-- The working edge: a shallow blade riding just under the surface with a row
	-- of tines ahead of it. This is the only part of the tool that ever goes below
	-- the sand line, and everything the basket catches comes up off it.
	-- Depths measured against the terrain rather than eyeballed. The axle rides
	-- exactly R above the sand, so an offset of -R IS the sand line: the blade's
	-- lower edge lands ~0.09 under it and the tine tips ~0.17 under, which is
	-- enough to read as cutting in without burying the basket in the surface.
	local lip = skp(m, Vector3.new(width, 0.34, 0.1), "blade")
	table.insert(rig.bodyParts, {
		part = lip,
		off = CFrame.new(0, FLOOR_Y - 0.2, zFront - 0.1) * CFrame.Angles(math.rad(-32), 0, 0),
	})
	local tines = math.max(4, math.floor(width * detail / 0.8))
	for i = 0, tines do
		local p = noShadow(skp(m, Vector3.new(0.09, 0.09, TINE_LEN), "tine"))
		-- angled down so each tine slopes out of the basket and INTO the sand,
		-- instead of lying flat on top of it like a comb resting on hair
		table.insert(rig.bodyParts, {
			part = p,
			off = CFrame.new(-halfW + (i / tines) * width, FLOOR_Y - 0.28, zFront - TINE_LEN * 0.5 - 0.06)
				* CFrame.Angles(math.rad(-22), 0, 0),
		})
	end

	-- Two small barrow wheels, outboard of the basket and dead on the axle line so
	-- they turn in place rather than orbiting it. The spoke exists to make that
	-- turn visible: a bare cylinder spinning about its own axis looks perfectly
	-- still, which would defeat the point of having wheels at all.
	local hx = halfW + 0.3
	for _, sx in ipairs({ -1, 1 }) do
		local tyre = skp(m, Vector3.new(0.34, R * 2, R * 2), "tyre", Enum.PartType.Cylinder)
		table.insert(rig.wheelParts, { part = tyre, off = CFrame.new(sx * hx, 0, 0) })
		local hub = skp(m, Vector3.new(0.38, R * 0.8, R * 0.8), "hub", Enum.PartType.Cylinder)
		table.insert(rig.wheelParts, { part = hub, off = CFrame.new(sx * hx, 0, 0) })
		local spoke = noShadow(skp(m, Vector3.new(0.4, R * 1.6, 0.08), "spoke"))
		table.insert(rig.wheelParts, { part = spoke, off = CFrame.new(sx * hx, 0, 0) })
		-- The tomb's rim round each hub. In wheelParts so it TURNS with the
		-- wheel -- a gilt ring that stayed still while the tyre rolled under it
		-- would read as a bug rather than as a fitting.
		if sk.charm == "scarab" then
			local ring = noShadow(skp(m, Vector3.new(0.1, R * 2.3, R * 2.3), "spoke", Enum.PartType.Cylinder))
			table.insert(rig.wheelParts, { part = ring, off = CFrame.new(sx * (hx + 0.22), 0, 0) })
		end
	end

	-- Axle and handle, rigid to the tool's frame and deliberately OUTSIDE the
	-- judder applied below: the player's hands are IK'd onto the grip bar, so a
	-- shaking bar reads as a shaking player rather than as a shaking tool.
	local axle = skp(m, Vector3.new(width + 0.7, 0.16, 0.16), "steel", Enum.PartType.Cylinder)
	table.insert(rig.rigidParts, { part = axle, off = CFrame.new() })

	-- gripZ ARRIVES rather than being measured here -- see the header. gripY is
	-- the same for every arm: the bar's height is set by the wheel it is bolted
	-- to, and only the forward reach has to fit the player.
	local gripY = GRIP_Y
	for _, sx in ipairs({ -1, 1 }) do
		local a = Vector3.new(sx * hx, 0, 0)
		local b = Vector3.new(sx * HAND_SPAN, gripY, gripZ)
		local d = b - a
		local p = skp(m, Vector3.new(0.22, 0.22, d.Magnitude), "steel")
		table.insert(rig.rigidParts, { part = p, off = CFrame.lookAt(a + d * 0.5, b) })
	end
	local grip = skp(m, Vector3.new(3.1, 0.36, 0.36), "grip", Enum.PartType.Cylinder)
	table.insert(rig.rigidParts, { part = grip, off = CFrame.new(0, gripY, gripZ) })
	-- Handed back so a caller has somewhere to hang the things that belong ON
	-- the bar: the hands, and the width tag over somebody else's tool.
	rig.grip = grip

	-- What the hands get pinned to. They hang off the bar itself rather than being
	-- worked out alongside it, so they are carried by whatever the render pass does
	-- with the tool and cannot end up a frame behind the thing being held.
	for _, sx in ipairs({ -1, 1 }) do
		local a = Instance.new("Attachment")
		a.Name = sx < 0 and "HandLeft" or "HandRight"
		a.CFrame = CFrame.new(sx * HAND_SPAN, 0, 0) * HAND_TILT * CFrame.new(0, HAND_SINK, 0)
		a.Parent = grip
		rig.gripAttach[sx] = a
	end
	local crossbar = skp(m, Vector3.new(hx + HAND_SPAN, 0.18, 0.18), "steel", Enum.PartType.Cylinder)
	table.insert(rig.rigidParts, { part = crossbar, off = CFrame.new(0, gripY * 0.5, gripZ * 0.5) })

	--[[
		THE CHARM, and on none of the three is it decoration.

		The palettes alone would give three recoloured rakes. What makes each one
		read as an OBJECT OUT OF ITS ROOM is the one fitting nobody would bolt to
		a garden tool -- a cartouche, folded paper, or a basket still cooling.

		Each piece goes in the list that matches how it is attached: anything on
		the BASKET juddes with the basket (bodyParts), anything on the HANDLE is
		rigid, because the player's hands are IK'd onto that bar and a shaking
		bell would read as a shaking player.
	]]
	if sk.charm == "scarab" then
		local cart = skp(m, Vector3.new(1.1, 0.62, 0.12), "frame")
		table.insert(rig.bodyParts, { part = cart, off = CFrame.new(0, rimY + 0.34, zBack + 0.1) })
		local eye = skp(m, Vector3.new(0.44, 0.44, 0.16), "grip")
		table.insert(rig.bodyParts, { part = eye, off = CFrame.new(0, rimY + 0.34, zBack + 0.13) })
		for _, sx in ipairs({ -1, 1 }) do
			for i = 1, 3 do
				-- The winged sun's outstretched half, stepped in three.
				local w = noShadow(skp(m, Vector3.new(0.36, 0.34 - i * 0.07, 0.1), "blade"))
				table.insert(rig.bodyParts, {
					part = w,
					off = CFrame.new(sx * (0.68 + i * 0.36), rimY + 0.34 - i * 0.04, zBack + 0.1),
				})
			end
		end

	elseif sk.charm == "shide" then
		local rope = skp(m, Vector3.new(width * 0.8, 0.24, 0.24), "grip", Enum.PartType.Cylinder)
		table.insert(rig.bodyParts, { part = rope, off = CFrame.new(0, rimY + 0.3, zBack + 0.08) })
		-- Four strips of folded paper, each three stepped tiles: that zigzag IS
		-- what a shide is, and a flat rectangle would just be a label.
		for i = 1, 4 do
			local sx = (i - 2.5) / 2 * width * 0.56
			for j = 0, 2 do
				local s = noShadow(rp(m, Vector3.new(0.3, 0.26, 0.04),
					Color3.fromRGB(248, 246, 240), Enum.Material.SmoothPlastic))
				table.insert(rig.bodyParts, {
					part = s,
					off = CFrame.new(sx + ((j % 2 == 0) and -0.1 or 0.1),
						rimY + 0.12 - j * 0.26, zBack + 0.11),
				})
			end
		end
		-- ...and a suzu under the crossbar, because a shrine object jingles.
		local bell = noShadow(skp(m, Vector3.new(0.34, 0.34, 0.34), "hub", Enum.PartType.Ball))
		table.insert(rig.rigidParts, { part = bell, off = CFrame.new(0, gripY * 0.5 - 0.26, gripZ * 0.5) })

	elseif sk.charm == "ember" then
		-- Three bars of it under the mesh floor. Held at 0.25 rather than solid:
		-- this is heat coming up THROUGH a grate, and an opaque slab under the
		-- wire would close the one gap the whole tool is named for.
		for i = -1, 1 do
			local coal = noShadow(skp(m, Vector3.new(width * 0.7, 0.07, 0.24), "blade"))
			coal.Transparency = 0.25
			table.insert(rig.bodyParts, { part = coal, off = CFrame.new(0, FLOOR_Y - 0.1, i * 0.64) })
		end
	end

	--[[
		AND WHAT IT THROWS ON THE GROUND UNDER IT. One light, on a part that is
		already being carried by the basket, so it rides the tool without a
		second thing to place every frame.

		SHADOWS OFF, ALWAYS. A moving shadow-casting point light in front of the
		player re-rasterises the whole scene every frame it moves, and this one
		moves constantly. Range is the skin's, brightness is halved for peers --
		eight lit sifters on one beach is a lighting bill nobody asked for.
	]]
	if sk.glow then
		local lamp = noShadow(rp(m, Vector3.new(0.2, 0.2, 0.2), STEEL, Enum.Material.SmoothPlastic))
		lamp.Transparency = 1
		table.insert(rig.bodyParts, { part = lamp, off = CFrame.new(0, FLOOR_Y + 0.2, 0) })
		local l = Instance.new("PointLight")
		l.Color = sk.glow.c
		l.Range = sk.glow.range
		l.Brightness = sk.glow.brightness * (effects and 1 or 0.5)
		l.Shadows = false
		l.Parent = lamp
	end

	-- Nothing is placed in the basket here any more. It used to get a fixed
	-- scatter of pebbles at build time, which meant the cart looked identical
	-- whether you were carrying nothing or a full bag -- decorative grit
	-- pretending to be cargo. refreshCart() fills it from the real inventory
	-- instead; see the CART section further down.

	-- Sand kicked up along the cut. Emitted off a part as wide as the tool, so it
	-- comes off the whole tine line rather than out of a point in the middle.
	local dp = noShadow(rp(m, Vector3.new(width * 0.92, 0.1, 0.1), STEEL, Enum.Material.SmoothPlastic))
	dp.Transparency = 1
	table.insert(rig.bodyParts, { part = dp, off = CFrame.new(0, -R + 0.12, zFront - 0.35) })
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = SAND_TEX
	-- Tinted by the skin: the shrine's tool combs blossom out of the boards and
	-- the chamber's throws sparks, and both of those are this emitter.
	pe.Color = ColorSequence.new(sk.dust[1], sk.dust[2])
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1.9) })
	pe.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(0.5, 0.75),
		NumberSequenceKeypoint.new(1, 1),
	})
	pe.Lifetime = NumberRange.new(0.25, 0.6)
	pe.Speed = NumberRange.new(0.5, 3)
	pe.SpreadAngle = Vector2.new(30, 60)
	pe.Acceleration = Vector3.new(0, -12, 0)
	pe.Rate = 0
	pe.Rotation = NumberRange.new(0, 360)
	pe.RotSpeed = NumberRange.new(-60, 60)
	pe.Parent = dp
	rig.dust = pe

	-- ...and the fine stuff dropping straight back out through the mesh floor,
	-- which is the whole difference between a sifter and a scoop.
	local sp = noShadow(rp(m, Vector3.new(width * 0.9, 0.05, BASKET_LEN * 0.8), STEEL, Enum.Material.SmoothPlastic))
	sp.Transparency = 1
	table.insert(rig.bodyParts, { part = sp, off = CFrame.new(0, FLOOR_Y - 0.06, 0) })
	local se = Instance.new("ParticleEmitter")
	se.Texture = SAND_TEX
	se.Color = ColorSequence.new(sk.sift)
	se.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0.85) })
	se.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
	se.Lifetime = NumberRange.new(0.18, 0.35)
	se.Speed = NumberRange.new(0.5, 1.5)
	se.SpreadAngle = Vector2.new(14, 14)
	se.EmissionDirection = Enum.NormalId.Bottom
	se.Acceleration = Vector3.new(0, -34, 0)
	se.Rate = 0
	se.Parent = sp
	rig.sift = se

	-- THE WINDROW THE TINES PUSH AHEAD OF THEMSELVES.
	--
	-- This is the piece that says the tool is moving SAND rather than passing
	-- over the top of it, so it is not decoration and it does not ride on
	-- walking speed. The render loop drives its height and depth off `load`,
	-- which fills only while the tines are in sand nobody has raked and bleeds
	-- away over ground that is already combed -- so a first pass shoves a
	-- visible heap along and a second pass over the same lane shoves nothing.
	--
	-- Authored at the size it reaches when FULL; everything below that is the
	-- loop scaling it down. Still a windrow and not a bulldozer blade: this tool
	-- combs a lane.
	-- SEGMENTS ALONG THE BLADE. NOT ONE TUBE, AND NOT A ROW OF BALLS.
	--
	-- Balls first, because that one is worth keeping written down: a Roblox Ball
	-- IGNORES a non-uniform Size and draws a sphere at the SMALLEST axis, so a
	-- 2.7 x 0.45 x 1.0 heap came out as a 0.45-stud marble, and three of those in
	-- a row is what made the windrow read as pebbles dropped in front of the
	-- tool. A Cylinder does take an elliptical cross-section, which is why the
	-- bank is built out of those. (Measured side by side -- see the shape test in
	-- the session notes.)
	--
	-- One cylinder spanning the whole blade was the next try, and what is wrong
	-- with it is that a bank of loose sand is not an extrusion. It is deepest in
	-- the middle, where the blade has been gathering sand from both sides, and it
	-- thins to nothing at the ends, where sand has been running off all along --
	-- and it never holds the same crest for two seconds together. So it is cut
	-- into segments, each taking its share of the load through `bell`: a sine
	-- across the blade, so the middle stands up and the ends taper away.
	--
	-- A CREST, NOT A ROLL OF CARPET. At its first size it was a 0.7-stud opaque
	-- tube sitting on top of the beach with daylight under its end caps, which
	-- reads as a prop lying in front of the tool. Nearly all of it is buried and
	-- what shows is a couple of inches of translucent crown -- the dust and the
	-- side spill do the shouting, and this only has to be what they come off.
	local span = width * 0.92
	-- NONE AT ALL WITHOUT EFFECTS, and the loop below then builds nothing. The
	-- bank's height is `load`, which only the tool's own owner is told about, so
	-- a peer's copy would be a heap of sand this client made up.
	local segs = effects and math.clamp(math.floor(width / 1.8), 3, 9) or 0
	for i = 1, segs do
		local u = (i - 0.5) / segs
		-- Overlapped by a fifth. Neighbouring segments sit at slightly different
		-- heights, and the overlap is what lets that read as one uneven bank
		-- instead of as a row of sausages with gaps between them.
		local seg = noShadow(rp(m, Vector3.new(span / segs * 1.2, 0.14, 0.85),
			Color3.fromRGB(218, 193, 145), Enum.Material.Sand, Enum.PartType.Cylinder))
		seg.Transparency = 1
		table.insert(rig.bermParts, {
			part = seg,
			len = span / segs * 1.2,
			x = (u - 0.5) * span,
			-- Just clear of the tine tips, which reach zFront - 0.81. Any further
			-- back and the tine row stands in front of the bank and hides it.
			z = zFront - 1.12,
			bell = 0.35 + 0.65 * math.sin(u * math.pi) ^ 0.7,
			phase = i * 2.3,
		})
	end

	-- ...and the sand escaping round the ENDS of that heap. A windrow with
	-- nowhere left to go spills sideways, and seeing it go is most of what makes
	-- a push read as a push. Rate is driven by the same `load`, so it only
	-- happens when there is genuinely a pile being shoved.
	for _, sx in ipairs({ -1, 1 }) do
		local ep = noShadow(rp(m, Vector3.new(0.12, 0.12, 0.12), STEEL, Enum.Material.SmoothPlastic))
		ep.Transparency = 1
		table.insert(rig.bodyParts, { part = ep, off = CFrame.new(sx * (halfW + 0.06), -R + 0.18, zFront - 0.7) })
		local e = Instance.new("ParticleEmitter")
		e.Texture = SAND_TEX
		e.Color = ColorSequence.new(sk.dust[1], sk.dust[2])
		e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1.1) })
		e.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(0.7, 0.6),
			NumberSequenceKeypoint.new(1, 1),
		})
		e.Lifetime = NumberRange.new(0.2, 0.45)
		e.Speed = NumberRange.new(1.5, 4)
		e.SpreadAngle = Vector2.new(22, 18)
		-- Outward, in the tool's own frame: the holder part is carried by the
		-- body, so Left really is the tool's left however the player is facing.
		e.EmissionDirection = sx < 0 and Enum.NormalId.Left or Enum.NormalId.Right
		e.Acceleration = Vector3.new(0, -30, 0)
		e.Rotation = NumberRange.new(0, 360)
		e.RotSpeed = NumberRange.new(-90, 90)
		e.Rate = 0
		e.Parent = ep
		table.insert(rig.spill, e)
	end

	if not shadows then
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				d.CastShadow = false
			end
		end
	end

	rig.model = m
	return rig
end

-- The tool in THIS player's hands: their own Sifter Width, fitted to their own
-- arm, parented where the render loop looks for it, and wired into the four
-- module-level lists that loop walks.
local function buildSifter(width: number)
	if sifterModel then sifterModel:Destroy() end
	sifterWidth = width
	skinNow = SkinConfig.get(player:GetAttribute(SkinConfig.ActiveAttribute)).key
	cartParts = {}
	-- Measured off the character every time the tool is built, so a Sifter Width
	-- upgrade or a respawn onto a different avatar re-fits the handle too.
	gripZNow = gripZFor(player.Character)

	local rig = constructSifter(width, gripZNow)
	wheelParts, bodyParts, rigidParts, bermParts =
		rig.wheelParts, rig.bodyParts, rig.rigidParts, rig.bermParts
	dustEmitter, siftEmitter, spillEmitters = rig.dust, rig.sift, rig.spill
	gripAttach = rig.gripAttach
	-- Re-hands the player onto the new bar. The attachments they were holding
	-- went with the model that was destroyed at the top of this function.
	if pinHands then
		pinHands()
	end

	rig.model.Parent = workspace
	sifterModel = rig.model
	return sifterModel
end

----------------------------------------------------------------
-- Item props
----------------------------------------------------------------
local function ip(model: Model, size: Vector3, cf: CFrame, colour: Color3, material: Enum.Material, shape: Enum.PartType?, transparency: number?)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	if shape then p.Shape = shape end
	p.Size = size
	p.CFrame = cf
	p.Color = colour
	p.Material = material
	p.Transparency = transparency or 0
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

local UP = CFrame.Angles(0, 0, math.rad(90))   -- stand a Cylinder on its end

--[[
	WHAT AN ITEM LOOKS LIKE IS ItemVisuals' JOB.

	This used to hand-assemble every find out of primitive Parts -- a cylinder
	with a lighter band for a can, four cylinders for a bottle -- with an
	`else` at the bottom that drew a flat dark slab. That branch was reached by
	EVERYTHING except the six ids written out above it, so a pizza box, a bin
	bag, a flip flop and a starfish all rode in the cart and popped out of the
	sand as the same phone-shaped rectangle.

	ItemVisuals.buildClean resolves ReplicatedStorage.Assets.Items.<id>.Clean --
	the real modelled art, which every one of the catalogue's 41 entries already
	has and which the Index and the reveal card have been drawing all along. So
	the sand, the cart, the collection screen and the reveal now agree, and a
	new item needs art in exactly one place.

	buildClean already anchors, un-collides and un-queries everything it returns,
	which is what this file's own `ip` helper was doing by hand.
]]
local function buildItem(id: string): Model
	local ok, m = pcall(ItemVisuals.buildClean, id)
	if not ok or not m then
		-- Never nil: popItem and refreshCart both parent the result immediately,
		-- and a find that turns up as nothing at all is worse than a grey box.
		warn("[CTB] no art for item id " .. tostring(id) .. ": " .. tostring(m))
		m = Instance.new("Model")
		local p = ip(m, Vector3.new(1, 1, 1), CFrame.new(),
			Color3.fromRGB(150, 132, 108), Enum.Material.Sandstone)
		m.PrimaryPart = p
	end
	m.Name = id
	local root = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
	if root then
		m.PrimaryPart = root
		m.WorldPivot = root.CFrame
	end
	return m
end

--[[
	Model:ScaleTo IS ABSOLUTE, AND THAT IS WHAT PUT A 173-STUD GOLD WATCH ON THE
	BEACH.

	ScaleTo(0.42) does not mean "draw this at 42% of its size". It sets the
	model's scale factor against the size its parts were AUTHORED at, throwing
	away whatever scale the asset was saved with -- and almost every model in
	ReplicatedStorage.Assets.Items carries one, because saving a scale is how
	they were fitted after import.

	Measured across all 41 of them. Watch was saved at 0.00254, so ScaleTo(0.42)
	redrew it at 165 times its intended size: a torus 173 studs across, standing
	over the whole beach. GoldBar came out at 27 studs and Meteorite at 15. At
	the other end BottleCap was saved at 1.78 and shrank to a tenth of a stud,
	which is its own bug -- an item in the basket that cannot be seen at all.

	WHY IT WENT UNNOTICED THIS LONG: the ids worst affected are all ENCASED.
	They ride in the cart as anonymous lumps and only draw their real art once
	the bay has cleaned them, which is exactly when it was reported -- "the gold
	watch, when you wash it".

	scaleBy MULTIPLIES. The authored scale is stashed on the model the first time
	it is asked for, because popItem's calls below run every frame -- without
	that they would measure against whatever they themselves set last frame and
	the item would shrink geometrically to nothing.
]]
local function scaleBy(m: Model, factor: number)
	local base = m:GetAttribute("AuthoredScale")
	if type(base) ~= "number" then
		base = m:GetScale()
		m:SetAttribute("AuthoredScale", base)
	end
	m:ScaleTo(base * math.max(factor, 0.01))
end

-- Every encased find pops as THIS, and every one of them is identical: same
-- size, same colour, same knobbles in the same places. The whole point of a
-- lump is that you cannot tell a phone from a pair of sunglasses until the
-- crust is off, so anything that varied here -- even the silhouette -- would
-- hand the answer over early. The offsets are hard-coded rather than random
-- for the same reason: two lumps must never be told apart.
local LUMP_ID = "Lump"
local LUMP_ROCK = Color3.fromRGB(150, 132, 108)
local LUMP_KNOB = Color3.fromRGB(134, 116, 92)
local LUMP_TINT = Color3.fromRGB(126, 112, 94)   -- ItemConfig's "Unknown" tone

local LUMP_KNOBS = {
	{ p = Vector3.new(0.42, 0.30, 0.20), s = Vector3.new(0.78, 0.70, 0.74) },
	{ p = Vector3.new(-0.38, 0.16, 0.34), s = Vector3.new(0.70, 0.66, 0.62) },
	{ p = Vector3.new(0.10, -0.34, -0.40), s = Vector3.new(0.82, 0.62, 0.70) },
	{ p = Vector3.new(-0.30, -0.22, -0.18), s = Vector3.new(0.60, 0.58, 0.66) },
	{ p = Vector3.new(0.24, 0.40, -0.30), s = Vector3.new(0.58, 0.54, 0.56) },
}

local function buildLump(): Model
	local m = Instance.new("Model")
	m.Name = LUMP_ID
	local root = ip(m, Vector3.new(1.55, 1.40, 1.48), CFrame.new(),
		LUMP_ROCK, Enum.Material.Sandstone, Enum.PartType.Ball)
	for _, k in ipairs(LUMP_KNOBS) do
		ip(m, k.s, CFrame.new(k.p), LUMP_KNOB, Enum.Material.Sandstone, Enum.PartType.Ball)
	end
	m.PrimaryPart = root
	m.WorldPivot = root.CFrame
	return m
end

----------------------------------------------------------------
-- The cart's contents
--
-- What is in the basket is what is in your bag. Crusted finds ride as lumps
-- (you cannot tell a phone from a pair of sunglasses until it has been sifted,
-- and the cart must not give that away either), everything else rides as
-- itself.
--
-- Rebuilt wholesale on every inventory change rather than diffed. A bag holds
-- ten or so things and changes a few times a minute, so the bookkeeping to
-- add and remove individual models would cost more than it saves -- and a
-- rebuild cannot drift out of sync with the bag, which a diff can.
----------------------------------------------------------------
local CART_MAX = 12          -- past this the basket is visually full anyway

local function clearCart()
	for _, e in ipairs(cartParts) do
		if e.model then
			e.model:Destroy()
		end
	end
	cartParts = {}
end

local function refreshCart()
	clearCart()
	if not sifterModel then
		return
	end

	local items = InventoryController.Client.Items or {}
	local n = math.min(#items, CART_MAX)
	if n == 0 then
		return
	end

	-- Laid out on the mesh floor in rows across the basket, so a wider screen
	-- genuinely holds more across rather than stacking everything up a tower.
	local perRow = math.max(2, math.floor(sifterWidth / 1.3))
	local rows = math.ceil(n / perRow)
	local prng = Random.new(Config.SEED + 31)

	for i = 1, n do
		local rec = items[i]
		-- rec.itemId is nil for anything still crusted: publicView withholds it
		-- until the sifting bay flips the record to Cleaned.
		local m = rec.itemId and buildItem(rec.itemId) or buildLump()
		scaleBy(m, 0.42)

		local row = math.floor((i - 1) / perRow)
		local col = (i - 1) % perRow
		local inRow = math.min(perRow, n - row * perRow)
		local _, size = m:GetBoundingBox()

		local x = ((col + 0.5) / inRow - 0.5) * (sifterWidth - 1.1)
		local z = (rows > 1 and ((row + 0.5) / rows - 0.5) or 0) * (BASKET_LEN - 0.8)
		local off = CFrame.new(x, FLOOR_Y + size.Y * 0.5 + 0.04, z)
			* CFrame.Angles(0, prng:NextNumber(0, 6.28), 0)

		m.Parent = sifterModel
		table.insert(cartParts, { model = m, off = off, phase = i * 1.9 })
	end
end


local function floatLabel(pos: Vector3, text: string, colour: Color3, size: number)
	local p = emitterPart(pos)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromScale(14, 2.8)
	bb.AlwaysOnTop = false   -- AlwaysOnTop billboards do not render in this place
	bb.Parent = p

	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.fromScale(1, 1)
	tl.BackgroundTransparency = 1
	tl.Font = Enum.Font.FredokaOne
	tl.Text = text
	tl.TextColor3 = colour
	tl.TextSize = size
	tl.Parent = bb

	local st = Instance.new("UIStroke")
	st.Thickness = 2.5
	st.Color = Color3.fromRGB(24, 20, 16)
	st.Parent = tl

	task.spawn(function()
		local t = 0
		while t < 1.15 do
			local dt = RunService.RenderStepped:Wait()
			t += dt
			local a = t / 1.15
			p.CFrame = CFrame.new(pos + Vector3.new(0, outCubic(a) * 2.3, 0))
			tl.TextTransparency = math.max(0, (a - 0.55) / 0.45)
			st.Transparency = tl.TextTransparency
		end
		p:Destroy()
	end)
end

----------------------------------------------------------------
-- Pop an uncovered item out of the sand
----------------------------------------------------------------
local function popItem(isl, idx: number, itemId: string, userId: number)
	-- The server sends the lump sentinel in place of the real id for anything
	-- encased, so this machine is never told which find it is until the sifting bay
	-- reveals it. No name, no price, no giveaway model.
	local encased = (itemId == LUMP_ID)
	local def = (not encased) and Config.item(itemId) or nil
	if not encased and not def then return end
	local ix, iz = Config.coords(isl, idx)
	local centre = Config.cellCentre(isl, ix, iz)
	local ground = Vector3.new(centre.X, Config.surfaceY(isl) + 0.3, centre.Z)
	local mine = (userId == player.UserId)
	-- A lump always gets the big treatment -- it is always one of the good ones.
	-- Loose litter still has to earn it on price.
	local rare = encased or (def.value >= Config.RARE_VALUE)

	sandBurst(ground, rare and 34 or 20)
	-- THE GRIT, AND ONLY THE GRIT. The sand moving IS the pickup now.
	--
	-- What used to land on top of this was a shimmering chime -- ItemCleaned for
	-- an ordinary find, LegendaryHit for a rare one -- and it had to go. Both are
	-- takes from the same "Magic Glow, ringing, shimmering" cluster, both carry a
	-- reverb halo, and both were played FLAT (nil parent, so no rolloff and no
	-- distance at all) on every single thing lifted off the beach.
	--
	-- One find, that is a nice sparkle. But raking is CONTINUOUS -- a pass
	-- through a line of litter pops several in a couple of seconds -- so the
	-- chime was never heard as one sparkle. It was a ringing chord that never
	-- stopped, sitting right at the front of the mix on top of the very texture
	-- it was decorating, and at 1.4s (3.3s for the legendary take) each one was
	-- still ringing when the next two arrived. Loud, bright and constant is the
	-- opposite of what this game is for.
	--
	-- Picking something up is a TOUCH event, not a tuned one. The sand burst
	-- above and this granular drop are the whole sound of it, and WeightClient's
	-- paper-crinkle Pickup slot covers the litter swept on foot.
	--
	-- The chime slots themselves are UNTOUCHED and still fire where a shimmer is
	-- actually the point: the wash and sift bays' reveal, which happens once per
	-- lump rather than once per step.
	AudioKit.play("SandDrop", nil, 0.9, 1.05)
	if rare then
		-- muddy, not the item's own colour: gold sparks would say "watch"
		sparkBurst(ground + Vector3.new(0, 1.5, 0), 26, encased and LUMP_TINT or def.color)
	end

	local m = encased and buildLump() or buildItem(itemId)
	m.Parent = fxFolder

	-- The same glow the swept litter gets, brighter -- this one is worth money.
	-- On a part rather than the model, because a PointLight needs somewhere with
	-- a position; it goes when the model does.
	local glowHost = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
	local glow = nil
	if glowHost then
		glow = Instance.new("PointLight")
		glow.Color = (encased and LUMP_TINT or def.color):Lerp(Color3.new(1, 1, 1), 0.4)
		glow.Range = rare and 16 or 11
		glow.Brightness = 0
		glow.Shadows = false
		glow.Parent = glowHost
	end

	task.spawn(function()
		--[[
			ONE yaw, and nothing on X or Z.

			What this replaces was tumbling the find on all three axes at once --
			roughly two full turns of X, two of Y and three of Z inside a second,
			measured -- from a random starting angle on each. So a bottle came out
			of the sand upside down and cartwheeling, which is what read as things
			flipping rather than as an item being collected.

			The random start is kept, but only as a yaw: two of the same item still
			do not come up facing identically, and both stay the right way up.
		--]]
		local yaw = math.random() * math.pi * 2
		local TILT = math.rad(14)     -- a lean, so it reads as a solid object and not a decal
		local function spun(pos: Vector3): CFrame
			return CFrame.new(pos) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(TILT, 0, 0)
		end

		-- Starts ON the sand, not 0.9 studs under it. The dip was meant to read as
		-- the find being dug out, but `ground` is only 0.3 above the surface, so
		-- the model spent the first frames of every pickup genuinely below the
		-- terrain -- and on a raked dip or a shallow camera angle you can see it
		-- down there. The sand burst fired at `ground` already sells the dig.
		local from = ground

		-- Somebody else's find. There is no cart of ours for it to go into, so it
		-- surfaces where it was and fades: a busy beach still reads as busy,
		-- without a stranger's pickup flying off across the sand toward nothing.
		if not mine then
			local t = 0
			while t < 0.5 do
				local dt = RunService.RenderStepped:Wait()
				t += dt
				yaw += dt * 3.2
				local a = math.min(t / 0.5, 1)
				m:PivotTo(spun(from:Lerp(ground + Vector3.new(0, 1.1, 0), outCubic(a))))
				scaleBy(m, math.max(0.06, 0.9 * (1 - a * a)))
			end
			m:Destroy()
			return
		end

		--[[
			STRAIGHT INTO THE CART.

			This used to rise, hover at the top of its arc, put a name and a price
			on a floating label, and only then fly to the player -- three separate
			beats and a readout, for every single piece of litter on a beach that
			has hundreds of them.

			The label had to go with the rest of it. The cart already shows what you
			are carrying, and the sell pad is what tells you what it came to;
			announcing a price at pickup made the number the event, and then said it
			again for the next can, and the next.

			OVER THE RIM AND DOWN IN.

			The real bug was the START, not the shape: `from` was `ground - 0.9`,
			and `ground` is only 0.3 above the surface, so every pickup began 0.6
			studs INSIDE the terrain and climbed out. That is what reads as the find
			going underground. It is fixed above, at `from`.

			The height curve is rebuilt as well, and more modestly than the note here
			once claimed -- the old `sin(a * pi)` hump did arrive descending (about
			1.23 -> 0.55 over the last fifth), it was just shallow. Measured against
			the real tool, whose rim sits 1.20 above the sand:

			    old   apex ~1.87, and it started under the ground
			    now   apex  2.53, starts at 0.30, arrives 1.49 -> 0.55

			Solving height as its own curve rather than as a bump added to a lerp is
			what buys that: a rise to an apex well above the rim, then an
			accelerating fall into the tray. It arrives moving downward and from over
			the top, which is the approach that reads as going IN to an open
			container rather than at it.

			It still finishes at the same 0.42 scale refreshCart lays items out at,
			so at the instant this model is destroyed the real one is already sitting
			there at exactly the size this one left off -- the handover is invisible.
		--]]
		local TOSS = 0.42
		-- Apex, over the higher of the two ends. The rim sits 0.65 above the
		-- basket floor, so 2.0 clears it comfortably and the drop is worth seeing.
		local TOSS_ARC = 2.0
		-- Fraction of the flight spent rising. Under a half means it is falling
		-- for most of the throw, which is what makes the landing the beat.
		local TOSS_RISE = 0.45
		local t = 0
		while t < TOSS do
			local dt = RunService.RenderStepped:Wait()
			t += dt
			yaw += dt * 5
			local a = math.min(t / TOSS, 1)

			-- Re-read the basket every frame. It rides in front of a player who is
			-- usually still walking, so a target sampled once lands behind them.
			local target = cartCF and (cartCF * CFrame.new(0, FLOOR_Y + 0.3, 0)).Position
				or (ground + Vector3.new(0, 2, 0))

			-- Ground track and height are solved separately. Horizontally it eases
			-- out toward the basket; vertically it lofts and then drops in.
			local ease = outCubic(a)
			local x = from.X + (target.X - from.X) * ease
			local z = from.Z + (target.Z - from.Z) * ease

			local apex = math.max(from.Y, target.Y) + TOSS_ARC
			local y
			if a < TOSS_RISE then
				-- Out of the sand fast, easing off as it reaches the top.
				local r = a / TOSS_RISE
				y = from.Y + (apex - from.Y) * (1 - (1 - r) * (1 - r))
			else
				-- Then falls, accelerating, so it lands rather than settles.
				local r = (a - TOSS_RISE) / (1 - TOSS_RISE)
				y = apex + (target.Y - apex) * (r * r)
			end

			m:PivotTo(spun(Vector3.new(x, y, z)))
			scaleBy(m, 0.9 - 0.48 * a)
			if glow then
				glow.Brightness = (rare and 5.5 or 3.8) * math.sin(a * math.pi)
			end
		end
		AudioKit.play("Pickup")
		m:Destroy()
	end)
end

----------------------------------------------------------------
-- Sell payout: a shower of coins
----------------------------------------------------------------
local function coinBurst(origin: Vector3, count: number)
	for i = 1, count do
		task.delay(i * 0.035, function()
			local c = Instance.new("Part")
			c.Anchored = true
			c.CanCollide = false
			c.CanQuery = false
			c.CanTouch = false
			c.Shape = Enum.PartType.Cylinder
			c.Size = Vector3.new(0.18, 1.1, 1.1)
			c.Color = Color3.fromRGB(255, 198, 62)
			c.Material = Enum.Material.Metal
			c.Parent = fxFolder

			local dir = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5).Unit
			local vel = dir * (7 + math.random() * 9) + Vector3.new(0, 17 + math.random() * 9, 0)
			local pos = origin
			local spinA = math.random() * 6
			AudioKit.play("CoinShower", nil, 0.8)

			local t = 0
			while t < 1.1 do
				local dt = RunService.RenderStepped:Wait()
				t += dt
				vel -= Vector3.new(0, 52 * dt, 0)
				pos += vel * dt
				spinA += dt * 16
				c.CFrame = CFrame.new(pos) * CFrame.Angles(0, spinA, math.rad(90))
				c.Transparency = math.max(0, (t - 0.7) / 0.4)
			end
			c:Destroy()
		end)
	end
end

----------------------------------------------------------------
-- Net
----------------------------------------------------------------
local puffBudget = 0

--[[
	THE UNDERGROUND CHAMBERS GET A SOUND PER SWEEP. THE OPEN ISLANDS DO NOT, AND
	THAT ASYMMETRY IS THE POINT.

	On the beach, the dunes, the cove and Ashfall you rake to UNCOVER things, and
	what you hear is the tool working (the RakeDrag loop) and then each find coming
	out of the sand (popItem's SandDrop, then WeightClient's Pickup when it goes in
	the bag). Sweeping bare ground there is not an event and must not make a noise
	-- see the long note in popItem about what a per-find chime did to this game.

	In the three CHAMBERS -- the tomb under the dunes, the inner shrine behind the
	cove, and the magma chamber -- the sweep IS the reward. There is no litter
	lying about to pop: you clear the floor and what is under it is the payout, so
	the swept cell is the moment and it is owed a sound.

	Only the tomb had one, and it was `rbxasset://sounds/electronicpingshort.wav`
	-- an engine beep, at 1.3-1.85x, up to twelve a second. The other two chambers
	had nothing at all. All three now use AudioKit's Pickup slot: two takes of
	close-miked paper crinkle, rotated round-robin with pitch jitter, which is the
	sound the rest of the game already uses for taking something and is built to
	fire this often (see the note on it in WeightClient).

	IT LIVES HERE, in the one handler that already receives Clean for every island,
	rather than in three per-chamber clients -- the shrine and the magma chamber do
	not have client modules at all, and adding two just to play one sound would be
	two more files to keep in step.

	The gap is the tomb's own 0.085s, kept rather than re-picked: a wide sifter
	reports several columns in a single tick, and without a throttle a good run is
	a machine-gun rather than a rhythm. That number was already tuned against this
	exact loop.

	WHICH FIELDS COUNT IS READ OFF THE ISLAND ROW (`isl.chamber`), not off a list
	of ids kept here. The list was the first version of this and it was quietly
	fragile: it sat in a different file from the rooms it described, so a fourth
	chamber would be silent until somebody remembered this table, and a room whose
	id ever moved would go silent without anything failing. The flag travels with
	the room. See ISLANDS[3].chamber in Config for the reasoning behind it.

	AND IT IS TESTED INLINE, with no helper of its own. THIS FILE IS AT LUAU'S
	200-REGISTER CEILING for the main chunk -- a single extra top-level `local`
	here, even a one-line function, fails the whole script to compile with "Out of
	local registers", and a client script that does not compile takes the raking,
	the litter and the HUD's feed down with it. Measured, not guessed: adding one
	did exactly that. Anything new in here has to go inside a function or replace
	something.
]]
local CHAMBER_SWEEP_GAP = 0.085
local lastChamberSweep = 0

----------------------------------------------------------------
-- The kiosk board
--
-- IT CARRIES A NAME AND NOTHING ELSE NOW (2026-08-21, owner's call). There used
-- to be a second line under it -- "Lv.1  *  9 studs", written from here on a
-- 30-second WaitForChild("Info") and rewritten on every RollerLevel and
-- RollerWidth change. The label is gone from the board and SignDresser no
-- longer lays a slot out for it, so the code that fed it is gone too: left in,
-- it would sit on that WaitForChild for half a minute every join and then warn
-- about a board that is working exactly as intended.
--
-- The reason it was written on the CLIENT is worth keeping even though the
-- feature is not: it is a single shared sign, so a server-side write put
-- whoever upgraded last on everyone's board -- you could read the sifter level
-- of the player next to you off it. Anything per-player that goes on this board
-- in future has to be written client-side for that reason.
----------------------------------------------------------------

----------------------------------------------------------------
-- The sand itself
--
-- Raked progress is private (see the grid-state block in CTB_Server), so the
-- server writes only the all-messy baseline at boot and every raked column after
-- that is written HERE, locally. Terrain edits made on a client do not
-- replicate, which is the whole trick: my raked strip is mine, and the player
-- next to me still sees untouched sand.
--
-- Batched into one dirty rectangle and flushed on Heartbeat rather than written
-- per cell: WriteVoxels costs about the same whether it touches one column or
-- fifty, so a sweep that rakes twenty of them wants to be one call, not twenty.
----------------------------------------------------------------
-- `fields` itself is declared up in the surface-marks section, because the
-- litter scatter needs to read it. Everything that writes it is here.
--
-- One dirty rectangle per island rather than one shared one: the two fields are
-- 1500 studs apart, so a rectangle spanning both would hand WriteVoxels an area
-- the size of the map every time a player who had raked on each moved an inch.
local function cleanReader(isl)
	local set = fields[isl.id].set
	return function(index: number): boolean
		return set[index]
	end
end

for _, isl in ipairs(Config.ISLANDS) do
	fields[isl.id].reader = cleanReader(isl)
end

----------------------------------------------------------------
-- The loose top layer
--
-- The sand the sifter digs THROUGH, as opposed to the ground it exposes. Config
-- .CRUST says what it is, why it replaces the material swap on the three sand
-- fields rather than joining it, and why it is a skin you cannot stand on. This
-- is only how it gets built.
--
-- ONE PART PER RUN, NOT ONE PER COLUMN, which is what makes it affordable. The
-- beach is 4096 columns; drawn a column at a time it would be four thousand
-- parts standing over one island before the player had touched anything. Each
-- row is drawn instead as its unbroken runs of UNCUT columns, so an untouched
-- row is a single 256-stud slab and a row cut through once is two. The count
-- tracks how much has actually been carved rather than how big the field is --
-- and it comes back down as a row is finished off, because a fully cut row is
-- no parts at all.
--
-- Runs merge along X only. Merging in both axes would pack better, but a
-- rectangle can only grow while its neighbours agree in BOTH directions, so a
-- single cut column would tear up several rows' worth of parts instead of one
-- row's -- and the rebuild happens under the tool, every tick.
--
-- Sizes may differ freely because nothing here is ever ROTATED: a part's
-- material texture is projected in world space, so an axis-aligned 256-stud slab
-- and a 4-stud one beside it carry one continuous grain with no seam at the
-- join. Rotation is what breaks that -- see the sheen block above, where slabs
-- crossing at 0/45/90 degrees came out as three plainly different shades.
----------------------------------------------------------------
local crustRows = {}                -- island id -> row index -> { Part, ... }
local crustDirtyRows = {}           -- island id -> row index -> true
local crustTintOf = {}

for _, isl in ipairs(Config.ISLANDS) do
	crustRows[isl.id] = {}
	crustDirtyRows[isl.id] = {}
end

-- Off the island's own MESSY terrain tint, lifted by Config.CRUST.lighten. The
-- crust is made of that same material, so each island keeps its palette for
-- free -- the beach's sand, the dunes' ochre, the cove's pink -- and the one
-- thing that separates the layer from the floor it is standing on is the lift.
local function crustTint(isl): Color3
	local t = crustTintOf[isl.id]
	if t then
		return t
	end
	local base = Color3.fromRGB(203, 177, 106)
	local ok, c = pcall(function()
		return workspace.Terrain:GetMaterialColor(isl.matMessy)
	end)
	if ok and c then
		base = c
	end
	t = base:Lerp(Color3.new(1, 1, 1), Config.CRUST.lighten)
	crustTintOf[isl.id] = t
	return t
end

local function buildCrustRow(isl, iz: number)
	local C = Config.crustFor(isl)
	if not C then
		return
	end
	local rows = crustRows[isl.id]
	local old = rows[iz]
	if old then
		for _, p in ipairs(old) do
			p:Destroy()
		end
	end

	local made = {}
	rows[iz] = made

	local set = fields[isl.id].set
	local tint = crustTint(isl)
	-- The slab runs from `bury` under the terrain surface to `rise` over it, so
	-- its centre sits half the difference above the surface. The buried part is
	-- never seen; it is there so the underside never lands exactly on the terrain
	-- plane and z-fight along every join in the field.
	local y = Config.surfaceY(isl) + (C.rise - C.bury) * 0.5
	-- First column of the run currently open, or nil between runs.
	local z = isl.z0 + (iz + 0.5) * Config.TILE
	local from: number? = nil

	local function close(lastIx: number)
		local a = from :: number
		local n = lastIx - a + 1
		local p = Instance.new("Part")
		p.Name = "Crust"
		p.Anchored = true
		-- All three off, and the first is load-bearing: see Config.CRUST for why
		-- this cannot be something the player stands on. CanQuery matters too --
		-- the litter scatter and the sifter both find the ground by raycast, and
		-- both want the TERRAIN, adding the rise themselves through crustLift.
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		-- Nothing to gain. The sun here is 82 degrees up, so a 0.4-stud lip casts
		-- about a twentieth of a stud of shadow -- while a slab this long is a real
		-- shadow caster to rebuild every time a column is cut under it. What draws
		-- the edge of a channel is the WALL, which takes almost no direct light at
		-- this sun angle whether or not it is casting anything.
		p.CastShadow = false
		p.Material = isl.matMessy
		p.Color = tint
		-- Invisible rather than unbuilt when the layer is switched off. The runs
		-- still have to be kept: the setting can come back on at any moment, and
		-- this row structure is the only record of where the channels are.
		p.Transparency = crustHidden and 1 or 0
		p.Size = Vector3.new(n * Config.TILE, C.rise + C.bury, Config.TILE)
		p.CFrame = CFrame.new(isl.x0 + (a + n * 0.5) * Config.TILE, y, z)
		p.Parent = crustFolder
		table.insert(made, p)
		from = nil
	end

	for ix = 0, isl.grid - 1 do
		if set[Config.index(isl, ix, iz)] then
			if from then
				close(ix - 1)
			end
		elseif not from then
			from = ix
		end
	end
	if from then
		close(isl.grid - 1)
	end
end

-- Batched exactly as the terrain writes it replaces were, and for the same
-- reason: one sweep cuts several columns across two or three rows in a tick, and
-- a row costs the same to redraw whether one column of it changed or twenty.
local function markCrustRow(isl, iz: number)
	if Config.crustFor(isl) then
		crustDirtyRows[isl.id][iz] = true
	end
end

local function flushCrust()
	for _, isl in ipairs(Config.ISLANDS) do
		local dirty = crustDirtyRows[isl.id]
		if next(dirty) then
			for iz in pairs(dirty) do
				buildCrustRow(isl, iz)
			end
			table.clear(dirty)
		end
	end
end

local function rebuildCrust(isl)
	if not Config.crustFor(isl) then
		return
	end
	table.clear(crustDirtyRows[isl.id])
	for iz = 0, isl.grid - 1 do
		buildCrustRow(isl, iz)
	end
end

-- THE PIECE THAT FALLS AWAY where a column has just been cut, and it is most of
-- what stops this reading as a part being deleted. Without it a four-stud square
-- of sand is simply not there on the next frame; with it the square drops into
-- the channel it is making and fades on the way down. Inset from the full tile
-- so its sides never land exactly on the faces of the crust it is falling out
-- of, which would z-fight for the quarter second it is alive.
local function crustCrumb(isl, ix: number, iz: number)
	local C = Config.crustFor(isl)
	-- Nothing falls off a layer that is not being drawn.
	if not C or not C.crumb or crustHidden then
		return
	end
	local centre = Config.cellCentre(isl, ix, iz)
	local span = Config.TILE - C.crumb_inset * 2
	local p = Instance.new("Part")
	p.Name = "Crumb"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = isl.matMessy
	p.Color = crustTint(isl)
	p.Size = Vector3.new(span, C.rise, span)
	p.CFrame = CFrame.new(centre.X, Config.surfaceY(isl) + C.rise * 0.5, centre.Z)
	p.Parent = crustFolder
	TweenService:Create(p, TweenInfo.new(C.crumb_life, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		CFrame = p.CFrame - Vector3.new(0, C.rise, 0),
		Transparency = 1,
	}):Play()
	task.delay(C.crumb_life + 0.05, function()
		p:Destroy()
	end)
end

-- Terrain material colours are written by the server's applyLook, and in a
-- Studio playtest the client can get this far before that has replicated -- in
-- which case the whole layer is built and CACHED in stock Roblox sand rather
-- than in the island's own tint. Called once from the boot block, after
-- buildMarks has waited for the terrain to actually stream in. Recolours in
-- place; there is nothing to rebuild, only to repaint.
local function refreshCrustTint()
	table.clear(crustTintOf)
	for _, isl in ipairs(Config.ISLANDS) do
		if Config.crustFor(isl) then
			local tint = crustTint(isl)
			for _, row in pairs(crustRows[isl.id]) do
				for _, p in ipairs(row) do
					p.Color = tint
				end
			end
		end
	end
end

-- Every dug field, laid down whole before anything else runs. Cheap enough to do
-- for islands the player may never visit -- an untouched field is one part per
-- row, so all three together are 160 -- and doing it here rather than on arrival
-- means there is no frame in which a field exists with no sand on it.
for _, isl in ipairs(Config.ISLANDS) do
	rebuildCrust(isl)
end

--[[
	SWITCHING THE LAYER OFF -- see crustLift for what the setting is for.

	It is a client attribute (`Set_HideSquares`) and nothing else, exactly like
	the rest of the settings panel: personal, unsaved, and never near the server.
	MenuHud writes it, this is the only thing that reads it, and the attribute
	name is the whole of the contract between the two.

	TWO THINGS MOVE, NOT ONE. The slabs go transparent, and every prop already
	lying on top of them comes down by `rise`. The junk was scattered ON the
	sand, so leaving it where it was would hang the beach's entire litter half a
	stud over open ground -- a worse artefact than the one the setting was asked
	for, and the one thing about this that is not simply a Transparency.

	`home` IS THE AUTHORITY, not the prop's current CFrame. A prop on a cell the
	player has raked is buried out of sight and will be put back at `home` by the
	next tide, so home has to move whether or not the prop is standing; only one
	that IS standing gets its own CFrame moved with it.

	No yield anywhere in the walk, which is what makes it safe to run while an
	island is still being scattered: buildMarks can only add to these tables
	across a task.wait, and anything it adds afterwards is placed by a crustLift
	that already knows the layer is gone.
]]
local function relevelMarks(dy: number)
	for _, isl in ipairs(Config.ISLANDS) do
		if Config.crustFor(isl) then
			local set = fields[isl.id].set
			for idx, list in pairs(marksOf[isl.id]) do
				local standing = not set[idx]
				for _, d in ipairs(list) do
					d.home = d.home + Vector3.new(0, dy, 0)
					if standing then
						d.part.CFrame = d.part.CFrame + Vector3.new(0, dy, 0)
					end
				end
			end
		end
	end
end

-- Every column messy, for putting a field back the way the server laid it down.
local function allMessy(): boolean
	return false
end

local function applyCrustHidden(hidden)
	hidden = hidden and true or false
	if hidden == crustHidden then
		return
	end
	crustHidden = hidden
	for _, isl in ipairs(Config.ISLANDS) do
		if Config.crustFor(isl) then
			for _, row in pairs(crustRows[isl.id]) do
				for _, p in ipairs(row) do
					p.Transparency = hidden and 1 or 0
				end
			end
		end
	end
	relevelMarks(hidden and -Config.CRUST.rise or Config.CRUST.rise)

	--[[
		AND THE GROUND UNDERNEATH FOLLOWS IT -- the other half of the setting; see
		swapFor for why the two can only ever be on one at a time.

		One pass over the whole field either way, which is what a tide already
		costs: going in, `reader` paints this player's raked columns in the clean
		material; coming back out, every column returns to messy, because the layer
		is about to stand there saying it again.

		ONLY THE MATERIAL MOVES. writeField puts every column at Config.surfaceY
		whichever state it is written in, so nobody on this beach ends up standing
		a stud above or below anybody else -- which is the rule the whole per-player
		terrain trick rests on.
	]]
	table.clear(sheenTint)
	for _, isl in ipairs(Config.ISLANDS) do
		-- NOTHING RAKED HERE MEANS NOTHING TO SAY: both states write the same
		-- all-messy field, because `reader` over an empty set IS allMessy. Worth the
		-- scan -- it is a walk over booleans against a whole-field WriteVoxels per
		-- island, and much the commonest use of this setting is a player flipping it
		-- on the way in, who has raked nothing anywhere yet.
		--
		-- Safe because the reverse holds too: a field is only ever written with the
		-- swap while its set had something in it, and everything that empties the set
		-- (a tide, a rebirth) goes through remessField, which writes it back to messy
		-- on the way out.
		local raked = nil
		if Config.crustFor(isl) then
			local set = fields[isl.id].set
			for idx = 1, isl.cells do
				if set[idx] then
					raked = raked or {}
					raked[#raked + 1] = idx
				end
			end
		end
		if raked then
			if Config.TERRAIN_DEFORMS then
				local f = fields[isl.id]
				-- Whatever was waiting in the dirty rectangle is inside this write.
				f.x0, f.x1, f.z0, f.z1 = nil, nil, nil, nil
				Config.writeField(workspace.Terrain, isl, 0, isl.grid - 1, 0, isl.grid - 1,
					hidden and f.reader or allMessy)
			end

			-- AND THE POLISH GOES THE SAME WAY, because it is the other half of what
			-- "the ground remembers" means. Coming out of hidden it has to be WIPED,
			-- not just stopped: canvasFor refuses to paint any more, but every pixel
			-- already down would sit there on ground that is meant to be untouched.
			--
			-- Going the other way it is laid down from the GRID, exactly as a rejoin
			-- does -- the curves of the original strokes are gone, the coverage is
			-- not, and without this the field would come back with nothing on it
			-- until the player walked it again.
			if hidden then
				paintCells(isl, raked)
			else
				sweepSheenAway(isl)
			end
		end
	end
end

player:GetAttributeChangedSignal("Set_HideSquares"):Connect(function()
	applyCrustHidden(player:GetAttribute("Set_HideSquares"))
end)
-- Read once more here as well as at the declaration. The panel is built after
-- this script runs, but only usually -- and a value already standing when the
-- crust was laid down would otherwise never reach the parts.
applyCrustHidden(player:GetAttribute("Set_HideSquares"))

----------------------------------------------------------------
-- Writing a cut column down
----------------------------------------------------------------
local function flushField()
	for _, isl in ipairs(Config.ISLANDS) do
		local f = fields[isl.id]
		if f.x0 then
			Config.writeField(workspace.Terrain, isl, f.x0, f.x1, f.z0, f.z1, f.reader)
			f.x0, f.x1, f.z0, f.z1 = nil, nil, nil, nil
		end
	end
	flushCrust()
end
RunService.Heartbeat:Connect(flushField)

local function setClean(isl, idx: number, value: boolean)
	local f = fields[isl.id]
	if f.set[idx] == value then
		return
	end
	f.set[idx] = value

	-- The row has to be redrawn whichever way the flag went: cutting a column
	-- splits a run in two and a tide putting one back joins two into one. Marked
	-- before the terrain check below, because on a dug field there IS no terrain
	-- write and this is the entire record of the sweep.
	local ix, iz = Config.coords(isl, idx)
	markCrustRow(isl, iz)

	if not swapFor(isl) then
		return
	end
	if f.x0 then
		if ix < f.x0 then f.x0 = ix end
		if ix > f.x1 then f.x1 = ix end
		if iz < f.z0 then f.z0 = iz end
		if iz > f.z1 then f.z1 = iz end
	else
		f.x0, f.x1, f.z0, f.z1 = ix, ix, iz, iz
	end
end

-- One island's whole surface in one call, for the two moments that change every
-- column of it at once -- a join, and a tide. Does whichever of the two the
-- island is actually using: the crust on the sand fields, the terrain material
-- in the vault -- and BOTH on a sand field whose squares the player has hidden,
-- where the layer still has to be kept in step even though nothing draws it.
local function redrawField(isl)
	rebuildCrust(isl)
	if not swapFor(isl) then
		return
	end
	local f = fields[isl.id]
	f.x0, f.x1, f.z0, f.z1 = nil, nil, nil, nil
	Config.writeField(workspace.Terrain, isl, 0, isl.grid - 1, 0, isl.grid - 1, f.reader)
end

----------------------------------------------------------------
-- Building an island's junk on arrival
--
-- The beach is scattered at boot because that is where the player spawns.
-- Everywhere else waits until they are actually standing on it: the desert is
-- ~300 more MeshParts, and a player who never sails there should never pay for
-- them. Once built it stays built -- rebuilding on every visit would cost a
-- second of hitching each way for no gain.
----------------------------------------------------------------
local function ensureIslandBuilt(isl)
	if marksBuilt[isl.id] then
		return
	end
	marksBuilt[isl.id] = true
	task.spawn(function()
		local n = buildMarks(isl)
		print(string.format("[CleanTheBeach] %s: %d pieces of junk scattered", isl.name, n))
	end)
end

task.spawn(function()
	while true do
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp then
			local isl = Config.zoneAt(hrp.Position)
			if isl then
				ensureIslandBuilt(isl)
			end
		end
		task.wait(0.5)
	end
end)

----------------------------------------------------------------
-- Putting a field back to messy
--
-- Shared by the two things that do it, because it is the same physical change
-- and they differ only in what it MEANS. "Tide" is the sea taking back a beach
-- you finished, and it pays you for it. "Wipe" is a rebirth taking back
-- everything you own, and it does not.
--
-- The stagger runs from the far edge of the grid toward the near one, so the
-- junk comes back as something rolling in rather than the whole field popping
-- into existence on one frame.
----------------------------------------------------------------
--[[
	SECONDS BETWEEN ONE ROW OF THE GRID COMING BACK AND THE NEXT. The tide's wave
	front below is locked to it: the sea has to be over a row at the instant that
	row's litter reappears, and a number typed into two places is a number that
	will be changed in one of them.

	PER ISLAND NOW, AND IT HAD TO BECOME SO. A flat 0.06 a row is a DURATION only
	if every grid is the same size, and they no longer are: at 0.06 the cove's 96
	rows would take 5.7 seconds and Ashfall's 160 would take 9.5, against the 3.78
	the beach was tuned at. That is not merely slow -- Island4_Client's ash front
	is timed off this same sweep, and it would have arrived five seconds before
	the sand it is supposed to be leaving behind.

	Config.remessStep caps the TOTAL sweep at Config.REMESS_SWEEP (4.74 s, which
	is what an 80-grid Ashfall took at 0.06) and leaves any grid small enough to
	finish inside that at exactly the 0.06 it shipped with -- so the beach and the
	dunes are untouched, and nothing anywhere takes longer than 4.74 s.

	CALLED THROUGH Config, NOT ALIASED TO A LOCAL HERE. This chunk sits one
	statement under Luau's 200-locals-per-function ceiling, and a `local function
	remessStep` wrapper -- which is what this was for an hour -- puts it over and
	the whole script stops compiling.
]]

local function remessField(isl)
	local f = fields[isl.id]
	table.clear(f.set)
	sweepSheenAway(isl)
	redrawField(isl)
	local step = Config.remessStep(isl)
	for iz = isl.grid - 1, 0, -1 do
		local delay = (isl.grid - 1 - iz) * step
		for ix = 0, isl.grid - 1 do
			raiseMarks(isl.id, Config.index(isl, ix, iz), delay)
		end
		-- One yield every 24 rows. This walk is O(cells) and the two biggest
		-- fields are 9,216 and 25,600 cells -- a fifth of a second of solid work
		-- on the one frame a tide lands, which is the frame the player is
		-- watching. The delays are absolute, so staggering the work does not
		-- stagger the result.
		if iz % 24 == 0 then
			task.wait()
		end
	end
end

Net.OnClientEvent:Connect(function(action, a, b, c, d)
	if action == "Clean" then
		local isl = Config.island(a)
		-- The tines are in sand nobody has touched. Everything that makes the tool
		-- look and sound like it is doing work hangs off this timestamp rather
		-- than off walking speed -- see `cutting` in the render loop.
		lastCutAt = os.clock()
		for _, idx in ipairs(b) do
			setClean(isl, idx, true)
			sinkMarks(isl.id, idx, false)
			-- A puff on EVERY raked cell, not one in five.
			--
			-- The ground swap under the tool is back (Config.TERRAIN_DEFORMS), so
			-- this is no longer the only thing saying a cell was raked -- but the
			-- two are doing different jobs and both are wanted. The swap is the
			-- RECORD: it is still there a minute later and it is what shows you the
			-- shape of where you have been. The puff is the MOMENT: sand actually
			-- moving, at the instant the tines pass. Take it back to one in five and
			-- the tool stops feeling like it is biting, even with the trail behind
			-- it; take away the swap and the beach forgets.
			--
			-- Still spent out of the budget below rather than fired unconditionally:
			-- a sweep at full width rakes several columns in one tick, and the point
			-- of the budget is that a wide tool cannot spike the particle count.
			if puffBudget > 0 then
				puffBudget -= 1
				local ix, iz = Config.coords(isl, idx)
				local p = Config.cellCentre(isl, ix, iz)
				-- At the height the sand WAS, not the floor it has just left behind:
				-- this puff is the top layer coming off, so it starts at the top of
				-- that layer. crustTop is the plain terrain surface on a field with no
				-- crust -- so the vault is unchanged -- and on a field whose layer the
				-- player has hidden.
				sandBurst(Vector3.new(p.X, crustTop(isl), p.Z), 9)
				-- and the sand itself gives way, out of the same budget: a wide sifter
				-- takes several columns in one tick and neither effect may spike
				crustCrumb(isl, ix, iz)
			end
		end

		-- ...and in the chambers, the sweep itself is the payout. See the note on
		-- CHAMBER_SWEEP_GAP, and ISLANDS[3].chamber in Config.
		-- Flat (nil parent) like every other take in this game: it is the player's
		-- own hands, not something happening out in the room.
		if isl.chamber and #b > 0 then
			local now = os.clock()
			if now - lastChamberSweep > CHAMBER_SWEEP_GAP then
				lastChamberSweep = now
				AudioKit.play("Pickup")
			end
		end

	elseif action == "Sync" then
		-- This player's own raked columns on one island, which on a fresh join is
		-- an empty list -- so joining a long-running server still hands you a whole
		-- unraked beach. Arrives once per island.
		local isl = Config.island(a)
		local set = fields[isl.id].set
		for _, idx in ipairs(b) do
			set[idx] = true
			sinkMarks(isl.id, idx, true)
		end
		paintCells(isl, b)
		if #b > 0 then
			redrawField(isl)
		end

	elseif action == "Pop" then
		popItem(Config.island(a), b, c, d)

	elseif action == "BagFull" then
		-- Was a metal clang. A bag being full is a limit, not an alarm.
		AudioKit.play("Reject", nil, 1, 0.92)

	elseif action == "Sold" then
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		-- fallback is the sell pad's own position, for the rare frame where the sale
		-- lands with no character to burst coins over
		local origin = hrp and (hrp.Position + Vector3.new(0, 2, 0)) or Vector3.new(-24, 4, -160)
		coinBurst(origin, math.clamp(b or 8, 6, 16))
		sparkBurst(origin, 30, Color3.fromRGB(255, 214, 90))
		-- Till bell, then the coins. Same two-part shape FeedbackClient uses for
		-- the receipt, so a sale sounds the same wherever it is reported from.
		AudioKit.stack("Register", "CoinShower", nil, 0.12)
		floatLabel(origin + Vector3.new(0, 2.4, 0), string.format("+$%d", a), Color3.fromRGB(120, 255, 160), 42)

	elseif action == "Upgraded" then
		-- GUARDED, because the rebuild is the ATTRIBUTE's job now (see
		-- syncSifterWidth down in the boot block) and the message and the attribute
		-- replicate independently. Whichever of the two lands first builds the new
		-- basket; the other finds the width already correct and leaves the tool
		-- alone, rather than dropping it out of the player's hands for a frame to
		-- rebuild an identical one.
		if type(b) == "number" and b ~= sifterWidth then
			buildSifter(b)
			refreshCart()
		end
		-- The knock is the new part arriving; the mallet chime a beat later is
		-- the confirmation. Two clips, not one clip twice.
		AudioKit.stack("Mount", "Upgrade", nil, 0.1)
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp then
			sparkBurst(hrp.Position + Vector3.new(0, 1, 0), 40, Color3.fromRGB(120, 220, 255))
			floatLabel(hrp.Position + Vector3.new(0, 5.5, 0), string.format("SIFTER Lv.%d  \u{2192}  %d studs", a, b),
				Color3.fromRGB(140, 226, 255), 32)
		end

	elseif action == "Deny" then
		AudioKit.play("Reject")

	elseif action == "Tide" then
		-- The beach calls it a tide and the desert calls it a sandstorm; the server
		-- sends which, so the sea wash is not played over a dune.
		local isl = Config.island(a)
		local storm = (c == "SANDSTORM")
		-- A sandstorm is the same water sweetener run fast and thin so it reads
		-- as blown grit rather than surf; the tide gets it slow and full.
		AudioKit.play("Wave", nil, storm and 0.85 or 1, storm and 1.45 or 0.95)
		AudioKit.play("Register", nil, 0.8, 0.9)
		-- this island only: the server reset that grid, so I re-mess that sand and
		-- leave whatever I have raked on the other one exactly where it is
		remessField(isl)

	elseif action == "Wipe" then
		--[[
			A REBIRTH TOOK THE SAND BACK, and this is deliberately NOT "Tide".

			Same field reset, none of the announcement. A tide is a REWARD: it pays
			a bonus, CTB_HUD pops a "+N coins" banner off it, and three separate
			island scripts (Island2_Client, Island4_Client and Vault_Client) listen
			for it to run their own weather. A rebirth is the opposite transaction
			-- the player has just given up their coins, their upgrades and their
			whole bag, and nothing was paid for this sand going back.

			Reusing "Tide" here would have rung the till, announced money that was
			never granted, and set off a sandstorm on every island at once,
			underneath the rebirth cinematic that is already playing. So the sand
			change is its own message with nothing hanging off it.

			The server only sends this for islands the player had actually raked,
			so there is no work here for a field they have never stood on.
		]]
		local isl = Config.island(a)
		if isl then
			remessField(isl)
		end
	end
end)

----------------------------------------------------------------
-- Boot
----------------------------------------------------------------
local markCount = buildMarks(Config.HOME)
refreshCrustTint()

--[[
	THE TOOL'S WIDTH COMES OFF THE ATTRIBUTE, NOT OFF A MESSAGE.

	This used to be built once here and rebuilt only by CTB's own "Upgraded"
	message -- and that message has not been sent since the kiosk was retired.
	CTB_Server's Upgrade branch is switched off (CTB_KIOSK_SELLS_UPGRADES =
	false, it answers with a Deny pointing at the shop) and the sifter ladder
	belongs to ProgressionServer's RollerWidth track, which grants a level by
	WRITING THE ATTRIBUTE and nothing else.

	So buying a wider sifter at the Beach Shop widened the SWEEP -- CTB_Server
	reads RollerWidth live, every tick, when it works out which columns were
	raked -- while the basket in the player's hands stayed the size it was built
	at on join. The sand cleared in a strip wider than the tool supposedly
	clearing it, and the upgrade just paid for was invisible until the next
	rejoin.

	Keyed off the attribute, every route that can move the width is covered at
	once: the shop, a rebirth's re-apply, a respawn, and the kiosk if it is ever
	switched back on.
]]
local function syncSifterWidth()
	local width = player:GetAttribute("RollerWidth") or Config.LEVELS[1].width
	-- ProgressionServer's applyAll rewrites this attribute after a purchase on
	-- ANY track, and again on every respawn. Rebuilding the tool because somebody
	-- bought a bigger bucket would drop it out of their hands for a frame, so
	-- nothing happens here unless the number actually moved.
	if sifterModel and width == sifterWidth then
		return
	end
	buildSifter(width)
	refreshCart()
end

buildSifter(player:GetAttribute("RollerWidth") or Config.LEVELS[1].width)
player:GetAttributeChangedSignal("RollerWidth"):Connect(syncSifterWidth)

--[[
	THE RE-FORGE.

	SkinService writes SkinActive: on arriving in a chamber whose skin you own,
	on leaving one, and -- the one that matters -- exactly
	SkinConfig.Ceremony.handoff seconds after you walk up to a plinth, which is
	the frame the comet SkinClient threw across the room lands on you.

	So the tool does not simply pop into a new colour. It comes back WHITE HOT
	and cools into the palette over 0.45s, which is the only treatment that
	reads as the thing that just hit you having done something.

	COLOUR ONLY, NEVER TRANSPARENCY. Half of what is in the model is fine wire
	and the ember skin's coals are deliberately held at 0.25; fading the lot in
	would lose both. Snapshotting Color and lerping back leaves every other
	property exactly as constructSifter left it.
]]
local function reforge()
	local m = sifterModel
	if not m then
		return
	end
	local snap = {}
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 1 then
			table.insert(snap, { p = d, c = d.Color })
			d.Color = Color3.new(1, 1, 1)
		end
	end

	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if hrp then
		sparkBurst(hrp.Position + Vector3.new(0, 1, 0), 34, Color3.fromRGB(255, 244, 214))
	end
	AudioKit.stack("Mount", "Upgrade", nil, 0.08)

	local t = 0
	local conn
	conn = RunService.RenderStepped:Connect(function(dt)
		t += dt
		local a = math.min(t / 0.45, 1)
		for _, e in snap do
			if e.p.Parent then
				e.p.Color = Color3.new(1, 1, 1):Lerp(e.c, a)
			end
		end
		if a >= 1 then
			conn:Disconnect()
		end
	end)
end

local function syncSkin()
	local want = SkinConfig.get(player:GetAttribute(SkinConfig.ActiveAttribute)).key
	-- Guarded exactly as the width is. SkinService republishes on a tick and
	-- most of those are not a change at all.
	if not sifterModel or want == skinNow then
		return
	end
	buildSifter(sifterWidth)
	refreshCart()
	reforge()
end

player:GetAttributeChangedSignal(SkinConfig.ActiveAttribute):Connect(syncSkin)

-- Fill it from whatever is already in the bag, then keep it in step. start()
-- guards against a second call, so it does not matter who wins the race with
-- ClientMain.
InventoryController.Client.start()
InventoryController.Client.Changed:Connect(refreshCart)
refreshCart()
Net:FireServer("Ready")

-- the sifter rides on whatever height the terrain currently is
local groundRay = RaycastParams.new()
groundRay.FilterType = Enum.RaycastFilterType.Include
groundRay.FilterDescendantsInstances = { workspace.Terrain }
groundRay.IgnoreWater = true

local lastFlat: Vector3? = nil
local lastLook = Vector3.new(0, 0, 1)
local sifterY = Config.ROLLER_RADIUS   -- ride height == wheel radius now
local speed = 0

-- A full bag stops the server raking anything at all (see CTB_Server), so the
-- sifter has to stop LOOKING like it is working -- otherwise it throws up dust
-- and shoves a berm along over sand that visibly stays churned, which reads as
-- a broken game rather than a full bag.
--
-- Taken from the server's own flag rather than worked out here: what limits the
-- bag is the weight ledger, which the client cannot see, and Bag / BagMax now
-- read "n / 9999" because the weight system lifted the slot cap.
local bagFull = false
local function refreshBagFull()
	bagFull = player:GetAttribute("RollerBlocked") == true
end
player:GetAttributeChangedSignal("RollerBlocked"):Connect(refreshBagFull)
refreshBagFull()

-- Is the tool in sand nobody has raked (1) or coasting over its own work (0),
-- and how much of a heap has it pushed up in front of itself. Both are driven
-- in the render loop; both are read by everything that says "this is work".
local cutting = 0
local load = 0
local lastSpill = 0
-- The frame the heap of sand rides in, chasing the blade's rather than being
-- fixed to it. See the windrow block in the render loop.
local bermCF: CFrame? = nil

-- Yaw only: the sifter rides flat on the sand whatever the root is doing.
local function flatLook(hrp: BasePart): Vector3
	local lv = hrp.CFrame.LookVector
	local v = Vector3.new(lv.X, 0, lv.Z)
	if v.Magnitude < 1e-3 then
		return lastLook
	end
	lastLook = v.Unit
	return lastLook
end

-- Where the grip bar is right now, worked out from the root rather than read off
-- the part, so anything asking mid-frame gets the same answer the render pass
-- will arrive at.
local function gripCFrame(hrp: BasePart): CFrame
	local look = flatLook(hrp)
	local p = hrp.Position
	local centre = Vector3.new(p.X, sifterY, p.Z) + look * Config.ROLLER_DIST
	return CFrame.lookAt(centre, centre + look) * CFrame.new(0, GRIP_Y, gripZNow)
end

--[[
	STOWING THE TOOL WHILE THE PLAYER IS RIDING SOMETHING

	The hands already let go the moment they sit down -- Seated is in LET_GO, and
	has been. But letting go only stopped the ARMS reaching: the sifter itself is
	placed off the character's ROOT every frame by the loop below, so it went on
	riding along at arm's length in front of a seated player with nobody holding
	it. On a quad it trailed beside the rider; on the bulldozer it sat out in
	front of the blade.

	LocalTransparencyModifier, NOT Transparency: it is a client-only display
	override, so this replicates to nobody and nothing is left mangled if the
	character respawns mid-ride. It is the same override the wash bay's cutaway
	already uses on this same model.
]]
local stowed = false
local stowTick = 0               -- see the re-apply note in the loop below

local function stowSifter(hide: boolean)
	if not sifterModel then
		return
	end
	local m = hide and 1 or 0
	for _, d in sifterModel:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = m
		elseif d:IsA("ParticleEmitter") or d:IsA("Trail") then
			d.Enabled = not hide
		end
	end
end

RunService.RenderStepped:Connect(function(dt)
	-- Refill and ceiling both raised: every raked cell now wants a puff rather
	-- than one in five, so the old budget would have throttled a normal sweep
	-- and left gaps in the only feedback there is. Still a ceiling, so a wide
	-- tool moving fast cannot run away with the particle count.
	puffBudget = math.min(puffBudget + dt * 22, 14)

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")

	--[[
		ANY SEAT -- AND ANYTHING ELSE THAT HAS TAKEN THE BODY OVER.

		A seat was the first case and it was never the only one. LET_GO further
		down -- which decides whether the ARMS reach for the bar -- has listed
		PlatformStanding since it was written, so on a ferry crossing the hands
		already let go. What nobody had told THIS loop is that the sifter is
		placed off the character's ROOT every frame regardless, so it went on
		riding at arm's length in front of a passenger being flown across the
		sea -- square in the middle of the one shot the crossing exists for, and
		held by nobody.

		The three tests are the three ways this game takes a character off its
		own feet, and each has exactly one author:

		  SeatPart        a quad, a dozer, a deck chair
		  PlatformStand   FerryServer.seize, for the whole crossing
		  root Anchored   that same seize, and ProgressionServer's ascension

		All three mean "not walking, not raking". This is a display-only stow
		on LocalTransparencyModifier, so a false positive costs a hidden tool
		nobody was using and replicates to no one.
	]]
	local riding = humanoid ~= nil
		and (humanoid.SeatPart ~= nil
			or humanoid.PlatformStand
			or (hrp ~= nil and hrp.Anchored))
	if riding then
		-- RE-APPLIED ON A SLOW TICK, not once when they sit down. Two things
		-- reach this model AFTER it has been stowed, and a one-shot hide misses
		-- both: a Sifter Width upgrade rebuilds the whole tool, and every piece
		-- of litter the net sweeps up while you drive is parented in as a fresh
		-- set of parts. Measured on the bulldozer -- twelve parts of collected
		-- rubbish riding along in mid-air beside a machine whose tool was
		-- otherwise invisible.
		--
		-- A fifth of a second is well under noticing, and the work is a few dozen
		-- client-only property writes that replicate to nobody.
		stowTick -= dt
		if not stowed or stowTick <= 0 then
			stowed, stowTick = true, 0.2
			stowSifter(true)
		end
	elseif stowed then
		stowed = false
		stowSifter(false)
	end

	if not hrp or not sifterModel or riding then
		cartCF = nil
		drag:set(0, nil, dt)
		if dustEmitter then dustEmitter.Rate = 0 end
		if siftEmitter then siftEmitter.Rate = 0 end
		for _, e in ipairs(spillEmitters) do e.Rate = 0 end
		cutting, load = 0, 0
		bermCF = nil
		lastFlat = nil
		return
	end

	local look = flatLook(hrp)

	local R = Config.ROLLER_RADIUS
	local pos = hrp.Position + look * Config.ROLLER_DIST
	local flat = Vector3.new(pos.X, 0, pos.Z)
	lastFlat = lastFlat or flat

	local delta = flat - lastFlat
	local forward = delta.X * look.X + delta.Z * look.Z
	speed = delta.Magnitude / math.max(dt, 1e-4)
	-- The WHEELS roll; nothing else on the tool turns. This is still just
	-- distance over radius -- it is only that what it drives is a pair of
	-- 0.55-stud barrow wheels instead of the entire body of the thing.
	wheelSpin -= forward / R
	lastFlat = flat

	-- sit the wheels on the terrain surface, eased so it doesn't snap between voxels
	local hit = workspace:Raycast(Vector3.new(flat.X, 14, flat.Z), Vector3.new(0, -30, 0), groundRay)
	-- ...but never far under whatever the player is actually standing on. The ray
	-- only sees Terrain, so on the built strip by the sell area the tool would drop
	-- to the sand underneath the strip and take the handlebar out of arm's reach
	-- along with it.
	local feet = humanoid and (hrp.Position.Y - hrp.Size.Y * 0.5 - humanoid.HipHeight) or -math.huge
	-- THE LOOSE LAYER IS NOT IN THAT RAYCAST -- nothing about the crust is
	-- queryable -- so the wheels are told about it directly. They ride up ON sand
	-- that has not been cut and settle into the channel once it has, which is the
	-- machine nosing down into its own lane. Eased at the same 12/s as the rest of
	-- this, so meeting fresh sand is a climb rather than a step, and it is zero on
	-- every field that has no crust.
	local overField = Config.fieldAt(flat)
	local lift = overField and crustLift(overField, flat.X, flat.Z) or 0
	local targetY = math.max((hit and hit.Position.Y or 0) + lift, feet) + R
	sifterY += (targetY - sifterY) * math.min(dt * 12, 1)

	local base = CFrame.lookAt(Vector3.new(flat.X, sifterY, flat.Z), Vector3.new(flat.X, sifterY, flat.Z) + look)

	-- `moving` drives everything that says the tool is doing work; a full bag
	-- zeroes it, for the reason set out where bagFull is declared.
	local moving = bagFull and 0 or math.clamp(speed / 19, 0, 1)

	-- CUTTING vs COASTING. `moving` only knows how fast the tool is travelling;
	-- this knows whether there is anything under it left to move. The server
	-- says so implicitly -- a Clean batch means columns were genuinely raked --
	-- and it is smoothed so one quiet tick between batches is not a stutter.
	local fresh = (os.clock() - lastCutAt < 0.35) and 1 or 0
	if bagFull then
		fresh = 0
	end
	cutting += (fresh - cutting) * math.min(dt * 7, 1)

	-- Polish laid along the path while the tool is genuinely cutting. Gated on
	-- `cutting` rather than on movement, so walking back down a lane you have
	-- already done does not stack a second layer of quads over the first.
	-- Fed every frame rather than every N studs: the stroke is stretched to
	-- wherever the tool has got to, so its length is continuous no matter what
	-- the frame rate is and there is no accumulator to leave a gap.
	if cutting > 0.3 and delta.Magnitude > 1e-4 then
		-- `overField` above is the same question asked one block earlier (fieldAt
		-- ignores Y), so it is reused rather than asked twice a frame.
		if overField then
			sheenTrail(overField, flat, sifterWidth, delta.Unit)
		else
			sheenBreak()
		end
	else
		sheenBreak()
	end

	-- How much sand is heaped in front of the blade. Fills only where the tool is
	-- both moving AND cutting, and bleeds faster than it fills -- so a first pass
	-- shoves a visible windrow along and a second pass down the same lane finds
	-- nothing left to shove.
	local want = cutting * moving
	local prevLoad = load
	load += (want - load) * math.min(dt * (want > load and 1.9 or 3.1), 1)

	-- The heap dropping when the push ends. One shot rather than a fade: sand
	-- held up by a blade collapses the moment the blade stops holding it, and
	-- that collapse is the beat that makes stopping feel like putting something
	-- down instead of like a switch turning off.
	if prevLoad > 0.3 and want < 0.08 and os.clock() - lastSpill > 0.55 then
		lastSpill = os.clock()
		-- Along the blade, not out of a point in the middle of it. What gives way
		-- is a bank as wide as the tool, and one puff in the centre reads as the
		-- sifter sneezing rather than as a heap letting go.
		local right = Vector3.new(-look.Z, 0, look.X)
		local at = Vector3.new(flat.X, sifterY - R, flat.Z) + look * (Config.ROLLER_DEPTH * 0.4)
		local puffs = math.clamp(math.floor(sifterWidth / 4), 2, 4)
		for i = 1, puffs do
			sandBurst(at + right * (((i - 0.5) / puffs - 0.5) * sifterWidth * 0.85),
				math.floor(3 + prevLoad * 8))
		end
	end

	-- Dragged, not rolled: the body never turns, it JUDDERS. A little pitch and
	-- roll as the tines catch and let go, and a shallow bob as the wheels ride the
	-- sand. All of it scales with walking speed, so a stopped tool sits dead still
	-- -- which is the tell that this is something being pulled rather than
	-- something with a motor in it.
	local t = os.clock()
	local shake = moving * 0.035
	local bodyCF = base
		* CFrame.new(0, math.sin(t * 21) * shake * 0.8, 0)
		* CFrame.Angles(math.sin(t * 17) * shake, 0, math.sin(t * 11.5) * shake * 1.7)
	cartCF = bodyCF

	local wheelCF = base * CFrame.Angles(wheelSpin, 0, 0)
	for _, e in ipairs(wheelParts) do
		e.part.CFrame = wheelCF * e.off
	end
	for _, e in ipairs(bodyParts) do
		e.part.CFrame = bodyCF * e.off
	end
	-- The handle sits outside the judder on purpose: the hands are IK'd onto the
	-- grip bar, so shaking the bar shakes the player's arms.
	for _, e in ipairs(rigidParts) do
		e.part.CFrame = base * e.off
	end

	-- what you are carrying, rattling around on the mesh
	for _, e in ipairs(cartParts) do
		local j = moving * 0.07
		if e.model.Parent then
			e.model:PivotTo(bodyCF * (e.off * CFrame.new(
				math.sin(t * 12 + e.phase) * j,
				math.abs(math.sin(t * 17 + e.phase)) * j * 1.3,
				math.cos(t * 10 + e.phase) * j)))
		end
	end

	-- The windrow. Its height and depth are the LOAD, not the speed: this is a
	-- heap of sand in front of a blade, and it is only there while there is sand
	-- being heaped.
	--
	-- IT IS NOT BOLTED TO THE BLADE. Loose material being shoved does not corner
	-- with the tool -- it carries on the way it was already going and gets caught
	-- again a moment later -- so the bank rides its own frame, chasing the
	-- blade's. The lag is about a twelfth of a second and does nothing visible in
	-- a straight line; on a turn it swings the heap wide of the blade, and that
	-- is most of what stops it reading as another part of the model.
	local bladeCF = bodyCF
	if not bermCF or (bermCF.Position - bladeCF.Position).Magnitude > 12 then
		bermCF = bladeCF            -- first frame, a respawn, or a teleport
	else
		bermCF = bermCF:Lerp(bladeCF, math.min(dt * 12, 1))
	end

	-- Sand stops piling at its angle of repose however hard it is pushed, and
	-- what will not stay on the heap has to leave round the ends instead -- which
	-- is what the side spill below is. So the height SATURATES rather than
	-- tracking load straight up: past about half load the bank stops growing and
	-- the spill takes over, which is the difference between a heap of sand and a
	-- bar chart of how hard you are working.
	local heaped = 1 - math.exp(-2.6 * load)
	for _, e in ipairs(bermParts) do
		-- Taller than it is deep, on purpose. A wide shallow slice of a wide
		-- ellipse comes out as a flat-topped plateau -- a plank laid in front of
		-- the blade. What shows has to be the CROWN of a rounded section, so the
		-- depth stays under a stud and the height carries the load instead.
		--
		-- `churn` is per segment and slow. Sand shifting on a bank does not
		-- vibrate, it slumps, so this is two long periods rather than the single
		-- fast wobble the one-piece ridge used -- that read as the heap shivering.
		local churn = 0.9 + 0.1 * math.sin(t * 2.7 + e.phase) + 0.06 * math.sin(t * 1.3 + e.phase * 1.7)
		local h = (0.20 + heaped * 0.72 * e.bell) * churn
		local d = 0.60 + heaped * 0.50 * e.bell
		e.part.Size = Vector3.new(e.len, h, d)
		-- Each segment is BURIED to a fixed depth and grows out of the top of the
		-- sand, so an empty tool has nothing showing at all (every crown sits under
		-- the surface at load 0) and a full one has a couple of inches of bank in
		-- front of it. Growing about the centre instead would swell it down into
		-- the beach as much as up out of it.
		e.part.CFrame = bermCF * CFrame.new(e.x, -R - 0.34 + h * 0.5, e.z - heaped * 0.34 * e.bell)
		-- Never anywhere near opaque. Loose sand caught mid-push has to stay hazy;
		-- solid is what made this read first as a boulder and then as a log. The
		-- thin ends fade sooner than the middle, so the bank has no hard edge where
		-- it stops.
		e.part.Transparency = 1 - math.clamp(load * 1.7, 0, 1) * 0.70 * (0.5 + 0.5 * e.bell)
	end

	-- Smoothed inside the kit rather than assigned raw. `moving` is a per-frame
	-- gameplay number and writing a loop's gain straight off one of those makes
	-- it chatter on every stutter -- which is most of what made the old drag
	-- read as a sound effect being switched on and off rather than a tool
	-- actually biting into sand.
	--
	-- Weighted by the CUT now, not by travel alone. Dragging the tool down a
	-- lane it has already combed is a light hiss; sand nobody has touched is the
	-- full grind, and a little lower with it. A tool that tells you whether there
	-- is work under it is most of what makes a pass worth making -- before this
	-- it ground away identically over finished ground.
	local bite = 0.28 + cutting * 0.72
	drag:set(moving * bite, 0.80 + moving * 0.26 + cutting * 0.10, dt)
	if dustEmitter then
		dustEmitter.Rate = moving > 0.1 and (5 + moving * (9 + cutting * 44)) or 0
	end
	if siftEmitter then
		-- What falls back through the mesh is what the tines just lifted, so this
		-- one is almost entirely the cut rather than the travel.
		siftEmitter.Rate = moving > 0.1 and (4 + cutting * moving * 105) or 0
	end
	-- Once the bank is at its repose the blade keeps gathering sand that has
	-- nowhere to go but round the ends, so this climbs much faster than the heap
	-- does. Seeing sand leave is what says the tool is full of it.
	local over = math.clamp((load - 0.45) / 0.55, 0, 1)
	for _, e in ipairs(spillEmitters) do
		e.Rate = load * 20 + over * over * 62
	end
end)

----------------------------------------------------------------
-- Hands on the bars
--
-- The sifter is a client-side model that rides in front of the character, so the
-- rig knows nothing about it and the default Animate script swings both arms as
-- if the player were strolling along empty handed. Two IKControls pin the hands
-- onto the grip bar instead, and the walk, the idle sway and the turn all still
-- play underneath -- IK is a correction on top of the animation, not a pose that
-- replaces it.
--
-- IKControl rather than posing the joints by hand, because this place runs the
-- upgraded avatar rig: shoulder, elbow and wrist are AnimationConstraints driven
-- by physics, not Motor6Ds, so there is no joint Transform to overwrite. (Even
-- on a Motor6D rig there is nowhere in the frame to overwrite it from except
-- RunService.Stepped -- RenderStepped writes, at every BindToRenderStep
-- priority, are thrown away by the animation pass that follows them.) IKControl
-- is evaluated inside that pass and drives either rig, so this keeps working if
-- the place is ever moved back.
--
-- Type is Transform, not Position. Position leaves the wrist to the animation
-- and settles with the hand about a third of a stud off the bar and rotated at
-- random; Transform lands the hand centre within four hundredths of a stud and
-- points the fingers over the bar. Measured both ways in this place, at rest and
-- at a run.
----------------------------------------------------------------
local ikHumanoid: Humanoid? = nil
local ikControls: { [number]: IKControl } = {}
local handWeight = 0

-- Anything that takes the character off the sand or out of the push hands the
-- arms back to the animator rather than leaving them reaching at a bar that
-- stayed behind: the sifter rides the terrain height, not the player's, so a
-- jump would otherwise stretch the player away from their own handle.
local LET_GO = {
	[Enum.HumanoidStateType.Freefall] = true,
	[Enum.HumanoidStateType.Jumping] = true,
	[Enum.HumanoidStateType.Swimming] = true,
	[Enum.HumanoidStateType.Climbing] = true,
	[Enum.HumanoidStateType.Seated] = true,
	[Enum.HumanoidStateType.Dead] = true,
	[Enum.HumanoidStateType.FallingDown] = true,
	[Enum.HumanoidStateType.Ragdoll] = true,
	[Enum.HumanoidStateType.PlatformStanding] = true,
}

pinHands = function()
	for _, sx in ipairs({ -1, 1 }) do
		local ik = ikControls[sx]
		if ik then
			ik.Target = gripAttach[sx]
		end
	end
end

local function buildHandIK(char: Model): boolean
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	-- R6 is one rigid limb per side with a single joint, which is not a chain and
	-- so not something IKControl can solve. Leave those arms to the animator.
	if not humanoid or humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		return false
	end

	local made = {}
	for _, sx in ipairs({ -1, 1 }) do
		local side = sx < 0 and "Left" or "Right"
		local upper = char:FindFirstChild(side .. "UpperArm")
		local hand = char:FindFirstChild(side .. "Hand")
		if not (upper and hand) then
			return false
		end

		local ik = Instance.new("IKControl")
		ik.Name = "CTB_Hand" .. side
		ik.Type = Enum.IKControlType.Transform
		ik.ChainRoot = upper
		ik.EndEffector = hand
		-- No damping. SmoothTime is a lag on the target, and the bar is 4.6 studs
		-- out in front of the player, so a turn sweeps it through a wide arc very
		-- fast: at the default 0.05 the hands visibly trail it round the corner.
		-- Measured over four hard 90s -- 0.08: 0.117 avg error, 0.03: 0.085, 0: 0.055.
		ik.SmoothTime = 0
		ik.Weight = 0                   -- faded in below, so a fresh spawn eases on
		ik.Parent = humanoid
		made[sx] = ik
	end

	ikControls, ikHumanoid = made, humanoid
	if pinHands then
		pinHands()
	end
	return true
end

RunService.Heartbeat:Connect(function(dt)
	local humanoid = ikHumanoid
	if not humanoid then
		return
	end

	local holding = humanoid.Health > 0
		and sifterModel ~= nil
		and not LET_GO[humanoid:GetState()]

	handWeight += ((holding and 1 or 0) - handWeight) * math.min(dt * 10, 1)
	for _, ik in pairs(ikControls) do
		ik.Weight = handWeight
		ik.Enabled = handWeight > 0.004
	end
end)

local function onCharacter(char: Model)
	ikControls, ikHumanoid, handWeight = {}, nil, 0
	task.spawn(function()
		-- Limbs stream in a beat behind the Humanoid on some avatars, so keep
		-- looking rather than giving up on the first miss.
		local deadline = os.clock() + 8
		repeat
			if buildHandIK(char) then
				return
			end
			task.wait(0.1)
		until os.clock() > deadline or char.Parent == nil
	end)
end

if player.Character then
	onCharacter(player.Character)
end
player.CharacterAdded:Connect(onCharacter)

----------------------------------------------------------------
-- WHAT EVERYBODY ELSE IS DRAGGING
--
-- THE TOOL WAS INVISIBLE TO EVERYONE BUT ITS OWNER, and that is a consequence
-- of how it is built rather than an oversight. buildSifter makes a model out of
-- anchored parts on THIS client, and the render loop puts it in front of THIS
-- character every frame; none of it replicates. So on somebody else's screen a
-- player raking the beach was a player walking along swinging their arms at
-- nothing -- and Sifter Width, the longest and most expensive ladder there is
-- on foot, was invisible to the only people worth showing it to.
--
-- So every client draws every OTHER player's sifter as well, off the one thing
-- that does replicate: the RollerWidth attribute ProgressionServer writes onto
-- the Player. Same builder, same width, same ride height, same hands on the
-- bar. There is no second model of the tool and nothing new on the wire.
--
-- AND A TAG OVER THE BAR SAYING HOW BIG IT IS, because "wider than mine" is not
-- something you can read off two wire baskets four studs apart at a glance: the
-- ladder runs 6 studs to 48.5 over fifty-nine rungs, and most neighbouring
-- rungs are less than a stud apart. The number and the difference from your own
-- are both on it, and the difference is colour-coded so the answer lands before
-- the number is read.
--
-- WHAT A PEER'S COPY DELIBERATELY LACKS is set out in constructSifter's header:
-- no dust, no windrow, no cart, and a bit under half the wire. What it never
-- lacks is the WIDTH, which is the whole point of drawing it.
--
-- WHAT IT COSTS. At most MAX tools are placed on any frame, nearest first, and
-- nothing past RANGE is drawn at all -- so a busy beach costs a bounded number
-- of CFrame writes rather than one tool's worth per player logged in.
--
-- IT IS ALL ONE FUNCTION because this file already carries 174 top-level locals
-- against Luau's limit of 200, and a block this size at file scope would spend a
-- quarter of what is left on names nothing else can use.
----------------------------------------------------------------
local function startPeerSifters()
	local peerFolder = Instance.new("Folder")
	peerFolder.Name = "CTB_Peers"
	peerFolder.Parent = workspace

	local RANGE = 260          -- studs from the camera; past this, nothing is drawn
	local MAX = 8              -- tools placed per frame, nearest first
	local DETAIL = 0.45        -- wire density -- see constructSifter
	local LABEL_RANGE = 110    -- studs the width tag stays up to
	local RETRY = 0.4          -- seconds between attempts to build a missing rig
	local TELEPORT = 12        -- studs in one frame that mean "not walking"

	local WIDER = Color3.fromRGB(255, 196, 92)      -- Sifter Width's own colour
	local NARROWER = Color3.fromRGB(150, 200, 235)
	local LEVEL = Color3.fromRGB(232, 238, 244)

	local peers = {}      -- [Player] = record
	local pending = {}    -- [Player] = clock time before which not to retry a build
	local order = {}      -- scratch: this frame's visible peers, nearest first

	local function widthOf(p: Player): number
		local w = p:GetAttribute("RollerWidth")
		return (type(w) == "number" and w == w and w > 0) and w or Config.LEVELS[1].width
	end

	------------------------------------------------------------------
	-- THE TAG
	------------------------------------------------------------------
	local function writeTag(rec)
		local theirs, mine = rec.width, widthOf(player)
		local d = theirs - mine
		local colour, note
		if math.abs(d) < 0.05 then
			colour, note = LEVEL, "same as yours"
		elseif d > 0 then
			colour, note = WIDER, string.format("%.1f wider than yours", d)
		else
			colour, note = NARROWER, string.format("%.1f narrower than yours", -d)
		end
		rec.size.Text = string.format("%.1f studs", theirs)
		rec.size.TextColor3 = colour
		rec.note.Text = string.format("%s \u{2014} %s", rec.player.DisplayName, note)
	end

	local function makeTag(rec)
		local bar = rec.rig.grip
		if not bar then
			return
		end

		local bb = Instance.new("BillboardGui")
		bb.Name = "CTB_WidthTag"
		bb.Size = UDim2.fromOffset(260, 46)
		bb.StudsOffsetWorldSpace = Vector3.new(0, 1.7, 0)
		bb.MaxDistance = LABEL_RANGE
		bb.LightInfluence = 0
		-- AlwaysOnTop billboards do not render in this place -- see floatLabel.
		bb.AlwaysOnTop = false
		bb.Parent = bar

		local size = Instance.new("TextLabel")
		size.BackgroundTransparency = 1
		size.Size = UDim2.new(1, 0, 0, 25)
		size.Font = Enum.Font.LuckiestGuy
		size.TextSize = 20
		size.Text = ""
		size.Parent = bb
		local edge = Instance.new("UIStroke")
		edge.Thickness = 2.5
		edge.Color = Color3.fromRGB(24, 20, 16)
		edge.Parent = size

		local note = Instance.new("TextLabel")
		note.BackgroundTransparency = 1
		note.Position = UDim2.new(0, 0, 0, 24)
		note.Size = UDim2.new(1, 0, 0, 18)
		note.Font = Enum.Font.GothamMedium
		note.TextSize = 13
		note.TextColor3 = Color3.fromRGB(208, 216, 226)
		note.Text = ""
		note.Parent = bb
		local noteEdge = Instance.new("UIStroke")
		noteEdge.Thickness = 2
		noteEdge.Color = Color3.fromRGB(24, 20, 16)
		noteEdge.Parent = note

		rec.tag, rec.size, rec.note = bb, size, note
		writeTag(rec)
	end

	------------------------------------------------------------------
	-- THEIR HANDS ON THEIR BAR
	--
	-- The same two IKControls the local player gets, made on THEIR humanoid from
	-- THIS client. That is legitimate and invisible to everyone else -- an
	-- instance a client creates is its own, and their arms are already being
	-- animated here off replicated state.
	--
	-- Without it the tool is held by nobody: their walk animation swings both
	-- arms freely, which is exactly the "raking at nothing" this block exists to
	-- fix, only now with a wire basket in front of it.
	------------------------------------------------------------------
	local function dropHands(rec)
		for _, ik in rec.ik do
			ik:Destroy()
		end
		rec.ik = {}
	end

	local function makeHands(rec)
		local humanoid = rec.humanoid
		-- R6 is one rigid limb per side with a single joint, which is not a chain
		-- and so not something IKControl can solve. Same rule as buildHandIK.
		if humanoid.RigType ~= Enum.HumanoidRigType.R15 then
			return
		end
		for _, sx in ipairs({ -1, 1 }) do
			local side = sx < 0 and "Left" or "Right"
			local upper = rec.char:FindFirstChild(side .. "UpperArm")
			local hand = rec.char:FindFirstChild(side .. "Hand")
			local target = rec.rig.gripAttach[sx]
			if not (upper and hand and target) then
				dropHands(rec)
				return
			end
			local ik = Instance.new("IKControl")
			ik.Name = "CTB_PeerHand" .. side
			ik.Type = Enum.IKControlType.Transform
			ik.ChainRoot = upper
			ik.EndEffector = hand
			ik.Target = target
			ik.SmoothTime = 0
			ik.Weight = 0
			ik.Enabled = false
			ik.Parent = humanoid
			rec.ik[sx] = ik
		end
	end

	------------------------------------------------------------------
	-- SHOWING AND HIDING
	--
	-- HIDDEN IS UNPARENTED, not transparent. This model is ours -- built here,
	-- owned here, replicated nowhere -- so taking it out of Workspace is ONE
	-- property write instead of a hundred LocalTransparencyModifiers, and it
	-- takes the wire and the tag out of the render pass entirely rather than
	-- drawing them at zero alpha.
	--
	-- The IK goes off with it. Its targets are attachments inside that model, and
	-- a solver reaching for something that is not in the world is a pair of arms
	-- doing something nobody chose.
	------------------------------------------------------------------
	local function show(rec, on: boolean)
		if rec.shown == on then
			return
		end
		rec.shown = on
		rec.rig.model.Parent = on and peerFolder or nil
		if not on then
			rec.weight = 0
			rec.lastFlat = nil
			for _, ik in rec.ik do
				ik.Weight = 0
				ik.Enabled = false
			end
		end
	end

	------------------------------------------------------------------
	-- BUILDING ONE
	------------------------------------------------------------------
	local function drop(p: Player)
		local rec = peers[p]
		if not rec then
			return
		end
		peers[p] = nil
		dropHands(rec)
		rec.rig.model:Destroy()
	end

	local function build(p: Player)
		drop(p)
		local char = p.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local humanoid = char and char:FindFirstChildOfClass("Humanoid")
		if not (hrp and humanoid) then
			return
		end

		local width = widthOf(p)
		-- THEIR skin, not this client's. Player attributes replicate to every
		-- client, so somebody who has claimed the tomb's sifter is genuinely
		-- carrying a gold one on everybody's screen -- which is most of what
		-- makes a skin worth walking down a tomb for.
		local skin = p:GetAttribute(SkinConfig.ActiveAttribute)
		local rig = constructSifter(width, gripZFor(char), {
			effects = false, detail = DETAIL, shadows = false, skin = skin,
		})
		rig.model.Name = "CTB_Sifter_" .. p.Name

		local rec = {
			player = p,
			char = char,
			hrp = hrp,
			humanoid = humanoid,
			rig = rig,
			width = width,
			skin = SkinConfig.get(skin).key,
			ik = {},
			look = Vector3.new(0, 0, 1),
			y = hrp.Position.Y,
			spin = 0,
			weight = 0,
			dist = 0,
			-- The model stays out of Workspace until the first placement frame:
			-- parenting it here would put a sifter at the world origin for a frame.
			shown = false,
		}
		peers[p] = rec
		makeTag(rec)
		makeHands(rec)
	end

	------------------------------------------------------------------
	-- PLACING ONE
	------------------------------------------------------------------
	local function step(rec, dt: number)
		local hrp, humanoid = rec.hrp, rec.humanoid
		-- THE SAME THREE TESTS THE LOCAL TOOL IS STOWED ON, and for the same
		-- reason: a sifter placed off the ROOT every frame goes on riding at arm's
		-- length in front of a seated player with nobody holding it. See the stow
		-- block in the render loop for what each of the three catches.
		if humanoid.Health <= 0 or humanoid.SeatPart ~= nil
			or humanoid.PlatformStand or hrp.Anchored then
			show(rec, false)
			return
		end
		show(rec, true)

		local lv = hrp.CFrame.LookVector
		local look = Vector3.new(lv.X, 0, lv.Z)
		look = (look.Magnitude < 1e-3) and rec.look or look.Unit
		rec.look = look

		local pos = hrp.Position + look * Config.ROLLER_DIST
		local flat = Vector3.new(pos.X, 0, pos.Z)
		-- A ferry crossing, an island gate or a rebirth moves a player further in
		-- one frame than any walk ever will. Treated as an ARRIVAL rather than as
		-- motion: no wheel spin, no judder, and the ride height snapped rather than
		-- eased across fifteen hundred studs of sea on the way.
		local jumped = (rec.lastFlat == nil) or ((flat - rec.lastFlat).Magnitude > TELEPORT)
		local delta = jumped and Vector3.zero or (flat - rec.lastFlat)
		rec.lastFlat = flat

		local speed = delta.Magnitude / math.max(dt, 1e-4)
		rec.spin -= (delta.X * look.X + delta.Z * look.Z) / Config.ROLLER_RADIUS
		rec.spin %= math.pi * 2

		-- Terrain, then the loose layer THIS client has laid over it. A peer's
		-- wheels have to ride the sand that is on screen HERE: which columns are
		-- raked is per-player, and their own client's answer is not drawn here.
		local hit = workspace:Raycast(Vector3.new(flat.X, 14, flat.Z), Vector3.new(0, -30, 0), groundRay)
		local feet = hrp.Position.Y - hrp.Size.Y * 0.5 - humanoid.HipHeight
		local overField = Config.fieldAt(flat)
		local lift = overField and crustLift(overField, flat.X, flat.Z) or 0
		local targetY = math.max((hit and hit.Position.Y or 0) + lift, feet) + Config.ROLLER_RADIUS
		if jumped then
			rec.y = targetY
		else
			rec.y += (targetY - rec.y) * math.min(dt * 12, 1)
		end

		local at = Vector3.new(flat.X, rec.y, flat.Z)
		local base = CFrame.lookAt(at, at + look)
		local moving = math.clamp(speed / 19, 0, 1)
		local t = os.clock()
		local shake = moving * 0.035
		local bodyCF = base
			* CFrame.new(0, math.sin(t * 21) * shake * 0.8, 0)
			* CFrame.Angles(math.sin(t * 17) * shake, 0, math.sin(t * 11.5) * shake * 1.7)
		local wheelCF = base * CFrame.Angles(rec.spin, 0, 0)

		local rig = rec.rig
		for _, e in ipairs(rig.wheelParts) do
			e.part.CFrame = wheelCF * e.off
		end
		for _, e in ipairs(rig.bodyParts) do
			e.part.CFrame = bodyCF * e.off
		end
		-- The handle stays outside the judder, exactly as on the local tool: their
		-- hands are pinned to it, and a shaking bar reads as a shaking player.
		for _, e in ipairs(rig.rigidParts) do
			e.part.CFrame = base * e.off
		end

		local holding = not LET_GO[humanoid:GetState()]
		rec.weight += ((holding and 1 or 0) - rec.weight) * math.min(dt * 10, 1)
		for _, ik in rec.ik do
			ik.Weight = rec.weight
			ik.Enabled = rec.weight > 0.004
		end
	end

	------------------------------------------------------------------
	-- WIRING
	------------------------------------------------------------------
	local function watch(p: Player)
		if p == player then
			return
		end
		p.CharacterAdded:Connect(function()
			drop(p)
			-- The limbs gripZFor measures stream in a beat behind the character,
			-- and a handle fitted to an arm that is not there yet falls back to the
			-- authored default. The lazy build below picks it up a moment later.
			pending[p] = os.clock() + 0.6
		end)
		p.CharacterRemoving:Connect(function()
			drop(p)
		end)
		p:GetAttributeChangedSignal("RollerWidth"):Connect(function()
			-- ProgressionServer's applyAll rewrites every track's attribute after a
			-- purchase on ANY of them, so most of these are not a change at all --
			-- and rebuilding would drop the tool out of their hands for a frame.
			local rec = peers[p]
			if rec and rec.width == widthOf(p) then
				return
			end
			build(p)
		end)
		-- Same guard, same reason: SkinService republishes on a tick and only a
		-- real change is worth rebuilding eight tools for.
		p:GetAttributeChangedSignal(SkinConfig.ActiveAttribute):Connect(function()
			local rec = peers[p]
			local want = SkinConfig.get(p:GetAttribute(SkinConfig.ActiveAttribute)).key
			if rec and rec.skin == want then
				return
			end
			build(p)
		end)
	end

	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(p)
		drop(p)
		pending[p] = nil
	end)
	for _, p in Players:GetPlayers() do
		watch(p)
	end

	-- MY OWN WIDTH IS HALF OF EVERY TAG, so buying a rung re-reads all of them
	-- rather than leaving a beach full of comparisons against the tool I had
	-- before I paid for a wider one.
	player:GetAttributeChangedSignal("RollerWidth"):Connect(function()
		for _, rec in peers do
			writeTag(rec)
		end
	end)

	RunService.RenderStepped:Connect(function(dt)
		local now = os.clock()
		local camera = workspace.CurrentCamera
		local eye = camera and camera.CFrame.Position or Vector3.zero

		--[[
			BUILT LAZILY AND RETRIED, rather than only off CharacterAdded.

			A character is not finished when it arrives -- the root and the arms
			stream in over the following frames -- and this client may well have
			been loading while half the server spawned, so there are joins whose
			signal was never heard. One cheap pass over the player list is
			self-healing where a pile of one-shot signals is not.
		]]
		for _, p in Players:GetPlayers() do
			if p ~= player and not peers[p] and (pending[p] or 0) <= now then
				pending[p] = now + RETRY
				build(p)
			end
		end

		table.clear(order)
		for p, rec in peers do
			if p.Character ~= rec.char or rec.hrp.Parent == nil then
				show(rec, false)
			else
				local d = (rec.hrp.Position - eye).Magnitude
				if d > RANGE then
					show(rec, false)
				else
					rec.dist = d
					table.insert(order, rec)
				end
			end
		end

		table.sort(order, function(a, b)
			return a.dist < b.dist
		end)
		for i, rec in ipairs(order) do
			if i > MAX then
				show(rec, false)
			else
				step(rec, dt)
			end
		end
	end)
end

startPeerSifters()

print(string.format("[CleanTheBeach] client ready \u{2014} terrain beach, %d surface marks", markCount))

