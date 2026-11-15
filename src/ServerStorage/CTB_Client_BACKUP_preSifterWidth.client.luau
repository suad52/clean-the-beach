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
-- CTB_Rake is in the sweep but is no longer made: the raised groove parts it
-- held are gone, replaced by the flat comb tiles in CTB_Groom. It stays listed
-- so a Studio session that still has the old folder lying in it gets cleaned.
for _, n in ipairs({ "CTB_Sand", "CTB_Decor", "CTB_Litter", "CTB_Marks", "CTB_Rake", "CTB_Groom", "CTB_FX", "CTB_Roller", "CTB_Sifter" }) do
	local o = workspace:FindFirstChild(n)
	if o then o:Destroy() end
end
local markFolder = Instance.new("Folder"); markFolder.Name = "CTB_Marks"; markFolder.Parent = workspace
local groomFolder = Instance.new("Folder"); groomFolder.Name = "CTB_Groom"; groomFolder.Parent = workspace
local fxFolder = Instance.new("Folder"); fxFolder.Name = "CTB_FX"; fxFolder.Parent = workspace

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
-- just shaded darker or lighter. The sifter sinks them and lays down grooves, so
-- what the player sees is a churned surface being smoothed, not a trench.
----------------------------------------------------------------
-- Keyed by island first, then cell index. A cell index on its own is ambiguous:
-- cell 1 exists on the beach AND on the desert island, and sinking the wrong one
-- would bury a bottle 1500 studs away.
local marksOf = {}                  -- island id -> cell index -> { {part, home}, ... }
local groomOf = {}                  -- island id -> cell index -> { part, tex, dir }
local marksBuilt = {}               -- island id -> true once its litter is scattered
for _, isl in ipairs(Config.ISLANDS) do
	marksOf[isl.id], groomOf[isl.id] = {}, {}
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
	local made = 0
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
				local cf = CFrame.new(jx, (terrainY(jx, jz) or fallback) + height * 0.22, jz)
					* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0)
					* rest
					* CFrame.Angles(rng:NextNumber(-0.12, 0.12), 0, rng:NextNumber(-0.12, 0.12))
				p.CFrame = cf
				p.Parent = markFolder
				addMark(isl.id, idx, p, cf)
				made += 1
			end

			if made % 400 == 0 then
				task.wait()
			end
		end
	end
	return made
end

----------------------------------------------------------------
-- The comb marks
--
-- One transparent tile per raked column with a groove image on its top face,
-- turned to the direction the sifter was pushed through it. Config.GROOM has
-- the why of sixteen baked images instead of one rotated part.
--
-- ENTIRELY LOCAL AND ENTIRELY COSMETIC. The server does not know these exist,
-- nothing reads them, and a column may be combed as often as the player likes.
-- That last part is deliberate: walking back over finished sand at a new angle
-- re-lays the lane, which is why the footprint that drives this is worked out
-- from the tool down in the render loop rather than taken from the server's
-- raked batch. The batch only ever says a column BECAME clean, once.
----------------------------------------------------------------
-- Which of the sixteen the tool is laying right now. Kept up to date by the
-- render loop and read by the Clean handler, which has to comb a column the
-- instant the server confirms it -- by then the tool has moved on a tick and
-- the column may already have left its own footprint.
local lastGroomDir = Config.groomIndex(0, 1)
-- When the tines were last in sand that had not been raked yet. This is what
-- separates cutting from coasting: everything about how hard the tool looks
-- and sounds like it is working hangs off it.
local lastCutAt = -10

local groomQueue = {}               -- creation order, for the tile ceiling
local groomHead, groomTail = 1, 0   -- inclusive live range; `#` is never used,
                                    -- because popping the head leaves a hole

-- Retire one queued tile, IF the cell is still holding the tile that entry was
-- made for.
--
-- The identity check is load-bearing, not a guard against nothing. A tide
-- destroys tiles without touching the queue, so every entry from before it is
-- stale -- and the player then rakes the same ground again, which puts a NEW
-- tile in a cell an old entry still names. Retiring by cell alone would take
-- that new tile out, punching holes in combing laid seconds ago, and the entry
-- for it would come up later and find nothing.
local function retireGroom(e)
	local tile = groomOf[e.isl][e.idx]
	if tile ~= e.tile then
		return
	end
	groomOf[e.isl][e.idx] = nil
	tile.part:Destroy()
end

-- Bring the field back under the tile ceiling, oldest first. Stale entries pop
-- for free, which just makes the cap conservative -- the safe direction.
local function trimGroom()
	while groomTail - groomHead + 1 > Config.GROOM.maxTiles do
		local e = groomQueue[groomHead]
		groomQueue[groomHead] = nil
		groomHead += 1
		if e then
			retireGroom(e)
		end
	end
	if groomHead > 8192 then
		local live = groomTail - groomHead + 1
		table.move(groomQueue, groomHead, groomTail, 1)
		for i = live + 1, groomTail do
			groomQueue[i] = nil
		end
		groomHead, groomTail = 1, live
	end
end

local function groomCell(isl, idx: number, dir: number, instant: boolean)
	local G = Config.GROOM
	if not G.enabled or not isl.groom then
		return
	end

	local tile = groomOf[isl.id][idx]
	if tile then
		if tile.dir ~= dir then
			tile.dir = dir
			tile.tex.Texture = G.ids[dir]
		end
		return
	end

	local ix, iz = Config.coords(isl, idx)
	local c = Config.cellCentre(isl, ix, iz)

	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Locked = true
	-- EXACTLY one cell wide. Tiles have to butt together for a lane to run
	-- unbroken across them; anything larger overlaps its neighbour and doubles
	-- the shading wherever two cross.
	p.Size = Vector3.new(Config.TILE, G.thickness, Config.TILE)
	p.CFrame = CFrame.new(c.X, Config.surfaceY(isl) + G.lift - G.thickness * 0.5, c.Z)
	-- The part is never drawn -- only the image on its top face is. That is what
	-- lets the terrain underneath keep carrying the sand's own colour while this
	-- carries nothing but the grooves cut into it.
	p.Transparency = 1
	p.Parent = groomFolder

	local tex = Instance.new("Texture")
	tex.Texture = G.ids[dir]
	tex.Face = Enum.NormalId.Top
	-- One image per cell exactly, which is what makes the pattern continuous:
	-- a tile's right edge is the next tile's left edge and the images are drawn
	-- to meet there.
	tex.StudsPerTileU, tex.StudsPerTileV = Config.TILE, Config.TILE
	tex.Transparency = instant and G.transparency or 1
	tex.Parent = p

	if not instant then
		TweenService:Create(tex, TweenInfo.new(G.fade, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Transparency = G.transparency,
		}):Play()
	end

	local made = { part = p, tex = tex, dir = dir }
	groomOf[isl.id][idx] = made
	groomTail += 1
	groomQueue[groomTail] = { isl = isl.id, idx = idx, tile = made }
	trimGroom()
end

-- The tide takes the combing back with the sand. Swept row by row on the same
-- clock as the litter coming back up (see the Tide branch), so the beach
-- un-rakes as one wave instead of blinking.
local function sweepGroomAway(isl)
	local byCell = groomOf[isl.id]
	groomOf[isl.id] = {}
	for iz = isl.grid - 1, 0, -1 do
		local row = {}
		for ix = 0, isl.grid - 1 do
			local tile = byCell[Config.index(isl, ix, iz)]
			if tile then
				table.insert(row, tile.part)
			end
		end
		if #row > 0 then
			task.delay((isl.grid - 1 - iz) * 0.06, function()
				for _, p in ipairs(row) do
					p:Destroy()
				end
			end)
		end
	end
end

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
		else
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

local STEEL = Color3.fromRGB(196, 200, 206)
local MESH = Color3.fromRGB(178, 184, 192)
local FRAME = Color3.fromRGB(146, 152, 160)
local BLADE = Color3.fromRGB(222, 226, 232)
local RUBBER = Color3.fromRGB(98, 108, 98)            -- grey-green barrow tyres
local GRIP = Color3.fromRGB(46, 48, 54)

-- The basket, in the tool's own frame. Local +Z runs BACK toward the player, so
-- the tines live at -Z. Y is measured from the wheel axle, which rides exactly
-- one wheel radius above the sand -- so anything below -Config.ROLLER_RADIUS is
-- under the surface, and only the blade and the tine tips ever are.
local BASKET_LEN = 2.4
local BASKET_H = 0.95
local FLOOR_Y = -0.3                                  -- mesh floor: skims the sand
local BAR = 0.1                                       -- mesh wire thickness
local TINE_LEN = 0.75

-- Where the handlebar sits in the tool's own frame: +Y up from the axle, +Z
-- back toward the player. This is a reach budget, not a styling choice. An R15
-- arm only spans about 1.75 studs from the shoulder to the middle of the fist,
-- and the shoulder itself sits ~0.6 up and level with the chest, so the bar has
-- to land inside that. The reach works out at ~1.4 -- enough of a bend left in
-- the elbow that the walk sway never straightens the arms out.
--
-- GRIP_Y went 1.8 -> 2.85 when the tool shrank, and that is not a retune: the
-- model origin dropped from a 1.6-stud drum axle to a 0.55-stud wheel axle, so
-- the bar had to come up by exactly that 1.05 to land in the same place in the
-- world. Same hands, same reach, same measurements. What changed is the handle,
-- which is now a long pole running from the sand up to chest height -- which is
-- what a tool you drag actually looks like.
local GRIP_Y, GRIP_Z = 2.85, 3.15
local HAND_SPAN = 1.15          -- out along the bar from centre, where the rails meet it
local HAND_TILT = CFrame.Angles(math.rad(75), 0, 0)   -- fingers rolled forward over it
local HAND_SINK = 0.12          -- bar in the fingers, not the palm

-- Rebuilt with the tool, held by the IKControls set up at the bottom of the
-- file. `pinHands` is assigned down there too; buildSifter calls it so that
-- upgrading to a wider basket re-hands the player onto the new bar.
local gripAttach: { [number]: Attachment } = {}
local pinHands: (() -> ())? = nil

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

local function buildSifter(width: number)
	if sifterModel then sifterModel:Destroy() end
	sifterWidth = width
	wheelParts, bodyParts, rigidParts, cartParts, bermParts = {}, {}, {}, {}, {}

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
		local p = noShadow(rp(m, Vector3.new(width, BAR, BAR), MESH, Enum.Material.Metal))
		table.insert(bodyParts, { part = p, off = CFrame.new(0, FLOOR_Y, zFront + (i / ribs) * BASKET_LEN) })
	end
	local wires = math.max(4, math.floor(width / 0.7))
	for i = 0, wires do
		local p = noShadow(rp(m, Vector3.new(BAR, BAR, BASKET_LEN), MESH, Enum.Material.Metal))
		table.insert(bodyParts, { part = p, off = CFrame.new(-halfW + (i / wires) * width, FLOOR_Y, 0) })
	end

	-- Rim all the way round, four uprights a side, and a wired back wall so what
	-- has been caught cannot simply fall out behind. The sides are left as open
	-- frame rather than full wire: at this size nobody can tell, and it keeps the
	-- part count sane on the widest upgrade.
	for _, z in ipairs({ zFront, zBack }) do
		local p = rp(m, Vector3.new(width, BAR * 1.7, BAR * 1.7), FRAME, Enum.Material.Metal)
		table.insert(bodyParts, { part = p, off = CFrame.new(0, rimY, z) })
	end
	for _, sx in ipairs({ -1, 1 }) do
		local rail = rp(m, Vector3.new(BAR * 1.7, BAR * 1.7, BASKET_LEN), FRAME, Enum.Material.Metal)
		table.insert(bodyParts, { part = rail, off = CFrame.new(sx * halfW, rimY, 0) })
		for i = 0, 3 do
			local p = noShadow(rp(m, Vector3.new(BAR, BASKET_H, BAR), MESH, Enum.Material.Metal))
			table.insert(bodyParts, {
				part = p,
				off = CFrame.new(sx * halfW, FLOOR_Y + BASKET_H * 0.5, zFront + (i / 3) * BASKET_LEN),
			})
		end
	end
	local backBars = math.max(3, math.floor(width / 0.8))
	for i = 0, backBars do
		local p = noShadow(rp(m, Vector3.new(BAR, BASKET_H, BAR), MESH, Enum.Material.Metal))
		table.insert(bodyParts, {
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
	local lip = rp(m, Vector3.new(width, 0.34, 0.1), BLADE, Enum.Material.Metal)
	table.insert(bodyParts, {
		part = lip,
		off = CFrame.new(0, FLOOR_Y - 0.2, zFront - 0.1) * CFrame.Angles(math.rad(-32), 0, 0),
	})
	local tines = math.max(4, math.floor(width / 0.8))
	for i = 0, tines do
		local p = noShadow(rp(m, Vector3.new(0.09, 0.09, TINE_LEN), BLADE, Enum.Material.Metal))
		-- angled down so each tine slopes out of the basket and INTO the sand,
		-- instead of lying flat on top of it like a comb resting on hair
		table.insert(bodyParts, {
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
		local tyre = rp(m, Vector3.new(0.34, R * 2, R * 2), RUBBER, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		table.insert(wheelParts, { part = tyre, off = CFrame.new(sx * hx, 0, 0) })
		local hub = rp(m, Vector3.new(0.38, R * 0.8, R * 0.8), STEEL, Enum.Material.Metal, Enum.PartType.Cylinder)
		table.insert(wheelParts, { part = hub, off = CFrame.new(sx * hx, 0, 0) })
		local spoke = noShadow(rp(m, Vector3.new(0.4, R * 1.6, 0.08), Color3.fromRGB(74, 82, 76), Enum.Material.SmoothPlastic))
		table.insert(wheelParts, { part = spoke, off = CFrame.new(sx * hx, 0, 0) })
	end

	-- Axle and handle, rigid to the tool's frame and deliberately OUTSIDE the
	-- judder applied below: the player's hands are IK'd onto the grip bar, so a
	-- shaking bar reads as a shaking player rather than as a shaking tool.
	local axle = rp(m, Vector3.new(width + 0.7, 0.16, 0.16), STEEL, Enum.Material.Metal, Enum.PartType.Cylinder)
	table.insert(rigidParts, { part = axle, off = CFrame.new() })

	local gripY, gripZ = GRIP_Y, GRIP_Z
	for _, sx in ipairs({ -1, 1 }) do
		local a = Vector3.new(sx * hx, 0, 0)
		local b = Vector3.new(sx * HAND_SPAN, gripY, gripZ)
		local d = b - a
		local p = rp(m, Vector3.new(0.22, 0.22, d.Magnitude), STEEL, Enum.Material.Metal)
		table.insert(rigidParts, { part = p, off = CFrame.lookAt(a + d * 0.5, b) })
	end
	local grip = rp(m, Vector3.new(3.1, 0.36, 0.36), GRIP, Enum.Material.Fabric, Enum.PartType.Cylinder)
	table.insert(rigidParts, { part = grip, off = CFrame.new(0, gripY, gripZ) })

	-- What the hands get pinned to. They hang off the bar itself rather than being
	-- worked out alongside it, so they are carried by whatever the render pass does
	-- with the tool and cannot end up a frame behind the thing being held.
	gripAttach = {}
	for _, sx in ipairs({ -1, 1 }) do
		local a = Instance.new("Attachment")
		a.Name = sx < 0 and "HandLeft" or "HandRight"
		a.CFrame = CFrame.new(sx * HAND_SPAN, 0, 0) * HAND_TILT * CFrame.new(0, HAND_SINK, 0)
		a.Parent = grip
		gripAttach[sx] = a
	end
	if pinHands then
		pinHands()
	end
	local crossbar = rp(m, Vector3.new(hx + HAND_SPAN, 0.18, 0.18), STEEL, Enum.Material.Metal, Enum.PartType.Cylinder)
	table.insert(rigidParts, { part = crossbar, off = CFrame.new(0, gripY * 0.5, gripZ * 0.5) })

	-- Nothing is placed in the basket here any more. It used to get a fixed
	-- scatter of pebbles at build time, which meant the cart looked identical
	-- whether you were carrying nothing or a full bag -- decorative grit
	-- pretending to be cargo. refreshCart() fills it from the real inventory
	-- instead; see the CART section further down.

	-- Sand kicked up along the cut. Emitted off a part as wide as the tool, so it
	-- comes off the whole tine line rather than out of a point in the middle.
	local dp = noShadow(rp(m, Vector3.new(width * 0.92, 0.1, 0.1), STEEL, Enum.Material.SmoothPlastic))
	dp.Transparency = 1
	table.insert(bodyParts, { part = dp, off = CFrame.new(0, -R + 0.12, zFront - 0.35) })
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = SAND_TEX
	pe.Color = ColorSequence.new(Color3.fromRGB(238, 220, 180), Color3.fromRGB(212, 190, 148))
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
	dustEmitter = pe

	-- ...and the fine stuff dropping straight back out through the mesh floor,
	-- which is the whole difference between a sifter and a scoop.
	local sp = noShadow(rp(m, Vector3.new(width * 0.9, 0.05, BASKET_LEN * 0.8), STEEL, Enum.Material.SmoothPlastic))
	sp.Transparency = 1
	table.insert(bodyParts, { part = sp, off = CFrame.new(0, FLOOR_Y - 0.06, 0) })
	local se = Instance.new("ParticleEmitter")
	se.Texture = SAND_TEX
	se.Color = ColorSequence.new(Color3.fromRGB(228, 206, 164))
	se.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0.85) })
	se.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
	se.Lifetime = NumberRange.new(0.18, 0.35)
	se.Speed = NumberRange.new(0.5, 1.5)
	se.SpreadAngle = Vector2.new(14, 14)
	se.EmissionDirection = Enum.NormalId.Bottom
	se.Acceleration = Vector3.new(0, -34, 0)
	se.Rate = 0
	se.Parent = sp
	siftEmitter = se

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
	-- ONE CYLINDER, NOT A ROW OF BALLS.
	--
	-- This wanted to be a few flat ellipsoids overlapping into a ridge, and that
	-- cannot be built out of Ball parts: a Roblox Ball IGNORES a non-uniform Size
	-- and draws a sphere at the SMALLEST axis, so a 2.7 x 0.45 x 1.0 heap came
	-- out as a 0.45-stud marble. Three of those in a row is what made the windrow
	-- read as pebbles dropped in front of the tool. (Measured against a Cylinder
	-- of the same Size side by side -- see the shape test in the session notes.)
	--
	-- A Cylinder does take an elliptical cross-section, so one laid along the
	-- blade and sunk to its crown is a continuous ridge of the right shape at
	-- every width the tool upgrades to, with no overlap to sort and no gaps.
	-- Paler and flatter than the old lumps for the same reason: a windrow is
	-- loose material an inch or two proud of the beach, not a rock.
	-- A CREST, NOT A ROLL OF CARPET. At its first size it was a 0.7-stud opaque
	-- tube sitting on top of the beach with daylight under its end caps, which
	-- reads as a prop lying in front of the tool. Nearly all of it is buried now
	-- and what shows is a couple of inches of translucent crown -- the dust and
	-- the side spill do the shouting, and this only has to be the thing they are
	-- coming off.
	local ridge = noShadow(rp(m, Vector3.new(width * 0.92, 0.14, 0.85),
		Color3.fromRGB(222, 198, 150), Enum.Material.Sand, Enum.PartType.Cylinder))
	ridge.Transparency = 1
	table.insert(bermParts, { part = ridge, len = width * 0.92, x = 0, z = zFront - 1.0, phase = 0 })

	-- ...and the sand escaping round the ENDS of that heap. A windrow with
	-- nowhere left to go spills sideways, and seeing it go is most of what makes
	-- a push read as a push. Rate is driven by the same `load`, so it only
	-- happens when there is genuinely a pile being shoved.
	spillEmitters = {}
	for _, sx in ipairs({ -1, 1 }) do
		local ep = noShadow(rp(m, Vector3.new(0.12, 0.12, 0.12), STEEL, Enum.Material.SmoothPlastic))
		ep.Transparency = 1
		table.insert(bodyParts, { part = ep, off = CFrame.new(sx * (halfW + 0.06), -R + 0.18, zFront - 0.7) })
		local e = Instance.new("ParticleEmitter")
		e.Texture = SAND_TEX
		e.Color = ColorSequence.new(Color3.fromRGB(232, 210, 166), Color3.fromRGB(204, 176, 130))
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
		table.insert(spillEmitters, e)
	end

	m.Parent = workspace
	sifterModel = m
	return m
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
		m:ScaleTo(0.42)

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
	-- Grit first, then the tone -- the sand moving, then the thing that was in
	-- it. Both are jittered by the kit, so the old explicit 0.95 + random*0.2
	-- pitch roll is gone from here.
	AudioKit.play("SandDrop", nil, 0.9, 1.05)
	-- A rare find gets a different CLIP rather than the same one louder and
	-- higher. The old version pushed one ping to 1.35 speed to say "special",
	-- which mostly says "small"; the legendary take is the longest of the same
	-- chime family, so it reads as more of the same sound rather than a
	-- squeakier one.
	AudioKit.play(rare and "LegendaryHit" or "ItemCleaned", nil, rare and 1 or 0.8)
	if rare then
		-- muddy, not the item's own colour: gold sparks would say "watch"
		sparkBurst(ground + Vector3.new(0, 1.5, 0), 26, encased and LUMP_TINT or def.color)
	end

	local m = encased and buildLump() or buildItem(itemId)
	m.Parent = fxFolder

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
				m:ScaleTo(math.max(0.06, 0.9 * (1 - a * a)))
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
			m:ScaleTo(0.9 - 0.48 * a)
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

----------------------------------------------------------------
-- The kiosk board
--
-- Written here rather than on the server. It is a single shared sign, so a
-- server-side write put whoever upgraded last on everyone's board -- you could
-- read the sifter level of the player standing next to you off it. GUI writes
-- made on a client do not replicate, so each player now sees only their own.
----------------------------------------------------------------
local kioskInfo = nil

local function refreshKiosk()
	if not kioskInfo then
		return
	end
	kioskInfo.Text = string.format("Lv.%d  \u{2022}  %d studs",
		player:GetAttribute("RollerLevel") or 1,
		player:GetAttribute("RollerWidth") or Config.LEVELS[1].width)
end

-- Resolved with WaitForChild on its own thread. A FindFirstChild chain here runs
-- before the beach has finished replicating, silently resolves to nil, and
-- leaves the board frozen on whatever text the place file was saved with -- which
-- looks exactly like the feature working, because the saved text is a plausible
-- level readout.
task.spawn(function()
	local beach = workspace:WaitForChild("Beach", 30)
	local kiosk = beach and beach:WaitForChild("UpgradeKiosk", 30)
	local board = kiosk and kiosk:WaitForChild("Board", 30)
	local gui = board and board:WaitForChild("KioskGui", 30)
	kioskInfo = gui and gui:WaitForChild("Info", 30)
	if not kioskInfo then
		warn("[CleanTheBeach] kiosk board not found -- its level readout will not update")
		return
	end
	refreshKiosk()
end)

player:GetAttributeChangedSignal("RollerLevel"):Connect(refreshKiosk)
player:GetAttributeChangedSignal("RollerWidth"):Connect(refreshKiosk)

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

local function flushField()
	for _, isl in ipairs(Config.ISLANDS) do
		local f = fields[isl.id]
		if f.x0 then
			Config.writeField(workspace.Terrain, isl, f.x0, f.x1, f.z0, f.z1, f.reader)
			f.x0, f.x1, f.z0, f.z1 = nil, nil, nil, nil
		end
	end
end
RunService.Heartbeat:Connect(flushField)

local function setClean(isl, idx: number, value: boolean)
	local f = fields[isl.id]
	if f.set[idx] == value then
		return
	end
	f.set[idx] = value
	if not Config.TERRAIN_DEFORMS then
		return
	end
	local ix, iz = Config.coords(isl, idx)
	if f.x0 then
		if ix < f.x0 then f.x0 = ix end
		if ix > f.x1 then f.x1 = ix end
		if iz < f.z0 then f.z0 = iz end
		if iz > f.z1 then f.z1 = iz end
	else
		f.x0, f.x1, f.z0, f.z1 = ix, ix, iz, iz
	end
end

-- One island's whole field in one call, for the two moments that change every
-- column of it at once.
local function rewriteWholeField(isl)
	if not Config.TERRAIN_DEFORMS then
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
			-- Combed here rather than left to the footprint pass: this batch is a
			-- tick old by the time it lands, and a column raked at the leading
			-- edge can already have fallen out from under the tool.
			groomCell(isl, idx, lastGroomDir, false)
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
				sandBurst(Vector3.new(p.X, Config.surfaceY(isl), p.Z), 9)
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
		if #b > 0 then
			rewriteWholeField(isl)
			-- Combing arrives after the sand, and spread over several frames: a
			-- restored field can be thousands of columns, and building that many
			-- tiles inside the handler would hitch the join. No direction survives
			-- a rejoin, so it all lies one way -- the beach was groomed along Z.
			local dir = Config.groomIndex(0, 1)
			task.spawn(function()
				for i, idx in ipairs(b) do
					groomCell(isl, idx, dir, true)
					if i % 250 == 0 then
						task.wait()
					end
				end
			end)
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
		buildSifter(b)
		refreshCart()
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
		local f = fields[isl.id]
		table.clear(f.set)
		rewriteWholeField(isl)
		sweepGroomAway(isl)
		for iz = isl.grid - 1, 0, -1 do
			local delay = (isl.grid - 1 - iz) * 0.06
			for ix = 0, isl.grid - 1 do
				raiseMarks(isl.id, Config.index(isl, ix, iz), delay)
			end
		end
	end
end)

----------------------------------------------------------------
-- Boot
----------------------------------------------------------------
local markCount = buildMarks(Config.HOME)
buildSifter(player:GetAttribute("RollerWidth") or Config.LEVELS[1].width)

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

-- WHAT THE TOOL IS COMBING RIGHT NOW.
--
-- The same swept rectangle CTB_Server tests against, worked out a second time
-- here, and deliberately so. The server's version answers "which columns just
-- BECAME clean" and fires once per column ever; this answers "which columns is
-- the tool passing over", and fires as often as the player cares to walk. That
-- difference is the feature: going back over finished sand at a new angle
-- re-lays the lane, and no server round trip should be involved in a mark that
-- nothing mechanical reads.
--
-- Only CLEAN columns are combed here. Messy sand gets its first lane from the
-- Clean handler, at the moment the server confirms the rake.
local function groomFootprint(centre: Vector3, look: Vector3, width: number, dir: number)
	local isl = Config.fieldAt(centre)
	if not isl or not isl.groom then
		return
	end
	local set = fields[isl.id].set
	local right = Vector3.new(-look.Z, 0, look.X)
	local hw, hd = width * 0.5, Config.ROLLER_DEPTH * 0.5

	local ex = math.abs(right.X) * hw + math.abs(look.X) * hd
	local ez = math.abs(right.Z) * hw + math.abs(look.Z) * hd
	local minX = math.max(0, math.floor((centre.X - ex - isl.x0) / Config.TILE))
	local maxX = math.min(isl.grid - 1, math.floor((centre.X + ex - isl.x0) / Config.TILE))
	local minZ = math.max(0, math.floor((centre.Z - ez - isl.z0) / Config.TILE))
	local maxZ = math.min(isl.grid - 1, math.floor((centre.Z + ez - isl.z0) / Config.TILE))

	for iz = minZ, maxZ do
		for ix = minX, maxX do
			local idx = Config.index(isl, ix, iz)
			if set[idx] then
				local d = Config.cellCentre(isl, ix, iz) - centre
				local u = d.X * right.X + d.Z * right.Z
				local v = d.X * look.X + d.Z * look.Z
				if math.abs(u) <= hw and math.abs(v) <= hd then
					groomCell(isl, idx, dir, false)
				end
			end
		end
	end
end

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
	return CFrame.lookAt(centre, centre + look) * CFrame.new(0, GRIP_Y, GRIP_Z)
end

RunService.RenderStepped:Connect(function(dt)
	-- Refill and ceiling both raised: every raked cell now wants a puff rather
	-- than one in five, so the old budget would have throttled a normal sweep
	-- and left gaps in the only feedback there is. Still a ceiling, so a wide
	-- tool moving fast cannot run away with the particle count.
	puffBudget = math.min(puffBudget + dt * 22, 14)

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not sifterModel then
		cartCF = nil
		drag:set(0, nil, dt)
		if dustEmitter then dustEmitter.Rate = 0 end
		if siftEmitter then siftEmitter.Rate = 0 end
		for _, e in ipairs(spillEmitters) do e.Rate = 0 end
		cutting, load = 0, 0
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
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	local feet = humanoid and (hrp.Position.Y - hrp.Size.Y * 0.5 - humanoid.HipHeight) or -math.huge
	local targetY = math.max(hit and hit.Position.Y or 0, feet) + R
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
		sandBurst(Vector3.new(flat.X, sifterY - R, flat.Z) + look * (Config.ROLLER_DEPTH * 0.4),
			math.floor(5 + prevLoad * 13))
	end

	-- Comb the lane under the tool. Speed-gated so standing still does not sit
	-- there repainting the same sand, and off entirely with a full bag, like
	-- everything else the tool does.
	if not bagFull and speed > 1.5 then
		lastGroomDir = Config.groomIndex(look.X, look.Z)
		groomFootprint(flat, look, sifterWidth, lastGroomDir)
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
	for _, e in ipairs(bermParts) do
		-- Taller than it is deep, on purpose. A wide shallow slice of a wide
		-- ellipse comes out as a flat-topped plateau -- a plank laid in front of
		-- the blade. What shows has to be the CROWN of a rounded section, so the
		-- depth stays under a stud and the height carries the load instead.
		local h = 0.20 + load * 0.55
		local d = 0.55 + load * 0.45
		e.part.Size = Vector3.new(e.len, h, d)
		local wobble = math.sin(t * 9 + e.phase) * 0.035 * (0.3 + load)
		-- The ridge is BURIED to a fixed depth and grows out of the top of the
		-- sand, so an empty tool has nothing showing at all (the crown sits under
		-- the surface at load 0) and a full one has a couple of inches of bank in
		-- front of it. Growing about its centre instead would swell it down into
		-- the beach as much as up out of it.
		e.part.CFrame = bodyCF * CFrame.new(e.x, -R - 0.34 + h * 0.5 + wobble, e.z - load * 0.35)
		-- Never anywhere near opaque. Loose sand caught mid-push has to stay hazy;
		-- solid is what made this read first as a boulder and then as a log.
		e.part.Transparency = 1 - math.clamp(load * 1.6, 0, 1) * 0.65
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
	for _, e in ipairs(spillEmitters) do
		e.Rate = load * 46
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

print(string.format("[CleanTheBeach] client ready \u{2014} terrain beach, %d surface marks", markCount))

