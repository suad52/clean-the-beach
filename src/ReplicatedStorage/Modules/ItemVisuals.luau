--[[
	ItemVisuals  --  ReplicatedStorage.Modules.ItemVisuals

	Builds the item models and the crust shell that shakes off at the screen.
	Shared: the SERVER builds and mounts the lump (so everyone sees it) and owns
	chunk destruction; the CLIENT owns the jet, the impact spray and the flying
	debris.

	THE ENCASED MODEL
	-----------------
		Lump_<itemId>  (Model, PrimaryPart = Clean.Core)
			Clean  (Model)   -- the real item, sitting inside, CanQuery = false
			Crust  (Folder)  -- Chunk1..ChunkN, CanQuery = TRUE

	Chunks are the only queryable parts, which is what makes aiming work: the
	client raycasts from the camera and whatever it hits IS the chunk index it
	reports. Once a chunk is destroyed the ray passes through to the next one
	behind it, so the shell hollows out naturally as you work.

	WHY EVERY LUMP LOOKS IDENTICAL
	------------------------------
	Fixed chunk count, fixed outer radius, colour jittered from one palette.
	A player who counts chunks or eyeballs the rock must learn nothing about
	what is inside -- the reveal is the whole point of the mechanic.

	TRAPS AVOIDED HERE
	------------------
	* Chunks are CanQuery = true and CanCollide = false. Query and collision are
	  separate flags; a non-collidable part is still perfectly raycastable, and
	  that is what we want -- you should never bump into a lump.
	* Never Neon on anything that fades: Neon ignores transparency the way you
	  expect and reads as a glowing block at 0.5.
	* PrimaryPart is assigned explicitly. An unset PrimaryPart makes PivotTo
	  discard the model's rotation; a set one silently overrides WorldPivot.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")

local Modules = script.Parent
local GameConfig = require(Modules.GameConfig)
local ItemConfig = require(Modules.ItemConfig)

local ItemVisuals = {}

-- Every lump is this big, whatever is inside it.
local LUMP_RADIUS = 1.45

local CRUST_PALETTE = {
	Color3.fromRGB(122, 106, 82),
	Color3.fromRGB(104, 90, 70),
	Color3.fromRGB(139, 121, 95),
	Color3.fromRGB(92, 82, 66),
}
local CRUST_MATERIALS = {
	Enum.Material.Sandstone,
	Enum.Material.Slate,
	Enum.Material.Mud,
	Enum.Material.Concrete,
}

--[[
	CRUST STYLES, since Penguin Island (2026-09-11).

	Every lump in the game used to be the same four browns, which was right when
	every field was sand or ash. A find dug out of a snowfield is a lump of PACKED
	SNOW, and a lump that came up brown out of white ground would say more about
	where the game was made than about where the player is. So the crust has a
	style now, and the style is decided by the item's POOL -- every id in the two
	arctic pools is snow, everything else is dirt -- because the server-side
	build, the cart and the wash bay all know the item and none of them knows
	the island. (The sand pop is the one place that knows the island and not the
	item; CTB_Client reads the row's lumpStyle there, which agrees by
	construction.)

	Four things carry the look and all four are in the table, because changing
	the palette alone gave snow chunks that turned muddy brown as they were
	worked: the chunk colours and materials, the two erosion targets, the grit
	that blasts off it and the clumps that spill off the plate.
]]
local CRUST_STYLES = {
	dirt = {
		palette = CRUST_PALETTE,
		materials = CRUST_MATERIALS,
		wet = Color3.fromRGB(58, 50, 40),
		pale = Color3.fromRGB(196, 186, 168),
		grit = { Color3.fromRGB(126, 106, 78), Color3.fromRGB(74, 62, 48) },
		spill = { Color3.fromRGB(190, 168, 132), Color3.fromRGB(148, 130, 106) },
		spillMat = Enum.Material.Sand,
	},
	snow = {
		-- Kept a step under white so the chunks still shade against each other;
		-- a lump of 255s is a white disc with no form under Brightness 3.1.
		palette = {
			Color3.fromRGB(232, 238, 246),
			Color3.fromRGB(216, 226, 238),
			Color3.fromRGB(240, 244, 250),
			Color3.fromRGB(202, 216, 232),
		},
		-- Ice first: the clumps ARE ice, and the snow on a frozen find is the
		-- caps frostChunk lays on top of them, not the clumps themselves.
		materials = {
			Enum.Material.Ice,
			Enum.Material.Ice,
			Enum.Material.Glacier,
			Enum.Material.Snow,
		},
		-- Worked snow goes BLUE and translucent-looking, not dark: meltwater.
		wet = Color3.fromRGB(150, 178, 206),
		pale = Color3.fromRGB(250, 252, 255),
		grit = { Color3.fromRGB(230, 238, 248), Color3.fromRGB(176, 198, 220) },
		spill = { Color3.fromRGB(238, 243, 249), Color3.fromRGB(198, 212, 230) },
		spillMat = Enum.Material.Snow,
		-- The clumps are cut as shards and dressed with weather -- see frostChunk.
		frosted = true,
	},
}

-- Which style an item's lump wears. Off the pool flags ItemConfig sets, so the
-- answer is the same on the server that builds the crust and the client that
-- draws the cart; nothing has to be threaded through the inventory.
function ItemVisuals.crustStyleFor(itemId: string?): string
	local def = itemId and ItemConfig.get(itemId)
	if def and (def.Penguin or def.Wreck) then
		return "snow"
	end
	return "dirt"
end

local function styleTable(style: string?)
	return CRUST_STYLES[style or "dirt"] or CRUST_STYLES.dirt
end

--------------------------------------------------------------------------
-- ASSET RESOLUTION
--------------------------------------------------------------------------

-- Optional authored art: ReplicatedStorage.Assets.Items.<ItemId>.Clean
local function authoredClean(itemId: string): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local items = assets and assets:FindFirstChild("Items")
	local entry = items and items:FindFirstChild(itemId)
	return entry and entry:FindFirstChild("Clean") or nil
end

local SHAPE_TO_PART = {
	Block = function()
		return Instance.new("Part")
	end,
	Ball = function()
		local p = Instance.new("Part")
		p.Shape = Enum.PartType.Ball
		return p
	end,
	Cylinder = function()
		local p = Instance.new("Part")
		p.Shape = Enum.PartType.Cylinder
		return p
	end,
	Wedge = function()
		return Instance.new("WedgePart")
	end,
}

local function proceduralClean(def): Model
	local model = Instance.new("Model")
	model.Name = "Clean"

	local core = (SHAPE_TO_PART[def.Shape] or SHAPE_TO_PART.Block)()
	core.Name = "Core"
	core.Size = def.Size
	core.Color = def.Color
	core.Material = def.Material
	core.Reflectance = def.Reflectance or 0
	core.Anchored = true
	core.CanCollide = false
	core.CanQuery = false
	core.CanTouch = false
	core.CastShadow = false
	core.TopSurface = Enum.SurfaceType.Smooth
	core.BottomSurface = Enum.SurfaceType.Smooth
	core.Parent = model

	model.PrimaryPart = core
	return model
end

-- The real item, clean, no crust. Used for the reveal card and as the thing
-- sitting inside a lump.
function ItemVisuals.buildClean(itemId: string): Model
	local def = ItemConfig.expect(itemId)

	local src = authoredClean(itemId)
	local model
	if src then
		if src:IsA("Model") then
			model = src:Clone()
		else
			model = Instance.new("Model")
			local p = src:Clone()
			p.Parent = model
			model.PrimaryPart = p:IsA("BasePart") and p or nil
		end
		model.Name = "Clean"
		if not model.PrimaryPart then
			model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart", true)
		end
	else
		model = proceduralClean(def)
	end

	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			-- Not queryable: the aim ray must reach the CRUST, never the prize.
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
			d:SetAttribute("BaseReflectance", d.Reflectance)
		end
	end

	model:SetAttribute("ItemId", itemId)
	model:SetAttribute("Rarity", def.Rarity)
	return model
end

--------------------------------------------------------------------------
-- THE CRUST SHELL
--------------------------------------------------------------------------

--[[
	Chunks are placed on a Fibonacci sphere, which spreads N points over a
	sphere far more evenly than nested latitude/longitude loops -- those bunch
	up hard at the poles, and a lump with a bald equator and a scab on top
	reads as broken rather than as rock.
]]
local function fibonacciDirection(i: number, n: number): Vector3
	local golden = math.pi * (3 - math.sqrt(5))
	local y = 1 - (i - 0.5) / n * 2
	local r = math.sqrt(math.max(0, 1 - y * y))
	local theta = golden * (i - 1)
	return Vector3.new(math.cos(theta) * r, y, math.sin(theta) * r)
end

--[[
	A FROZEN LUMP IS NOT A DIRTY LUMP PAINTED WHITE (remodelled 2026-09-11).

	The snow style dresses each clump as a shard of ice with the weather on it:
	a cap of snow on the outward face of about half of them, an icicle or two
	hanging off the ones on the underside, and here and there a frost crystal
	catching the light. Every fitting is a CHILD OF THE CLUMP it sits on, so it
	leaves the lump the instant that clump is popped and thins with it while
	it is worked (setChunkErosion), and every one is CanQuery false so the aim
	ray still lands on the clump itself. The shell is exactly as washable as
	the dirt one: same chunk count, same names, same attributes, same overlap.

	Positions here are relative to the clump's own pre-centring frame;
	buildEncased carries every descendant onto the item together.
]]
local function frostChunk(chunk: BasePart, dir: Vector3, rng: Random, chunkSize: number)
	local up = dir.Unit
	local function fitting(name: string, size: Vector3, cf: CFrame, colour: Color3, material: Enum.Material, extra)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		p.Color = colour
		p.Material = material
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		if extra then
			for k, v in extra do
				(p :: any)[k] = v
			end
		end
		p:SetAttribute("BaseTransparency", p.Transparency)
		p.Parent = chunk
		return p
	end

	-- 0.55 of a clump out from its centre: a randomly turned clump's half-extent
	-- along `dir` runs 0.42-1.2 of chunkSize, so any lower and the cap is buried
	-- inside the ice it is meant to sit on.
	local outer = chunk.Position + up * (chunkSize * 0.55)
	-- a cap of snow on the outward face of about half the clumps that face up
	if up.Y > -0.1 and rng:NextNumber() < 0.6 then
		fitting("SnowCap", Vector3.one * (chunkSize * rng:NextNumber(0.8, 1.05)),
			CFrame.new(outer + Vector3.new(0, chunkSize * 0.08, 0)),
			Color3.fromRGB(240, 244, 250), Enum.Material.Snow, { Shape = Enum.PartType.Ball })
	end
	-- icicles under the clumps on the underside
	if up.Y < -0.15 and rng:NextNumber() < 0.7 then
		for _ = 1, rng:NextInteger(1, 2) do
			local len = chunkSize * rng:NextNumber(0.5, 1.1)
			local at = chunk.Position + Vector3.new(rng:NextNumber(-0.3, 0.3) * chunkSize, -chunkSize * 0.45 - len * 0.5 + chunkSize * 0.15, rng:NextNumber(-0.3, 0.3) * chunkSize)
			fitting("Icicle", Vector3.new(0.12, len, 0.12), CFrame.new(at),
				Color3.fromRGB(206, 232, 250), Enum.Material.SmoothPlastic, { Transparency = 0.25, Reflectance = 0.35 })
		end
	end
	-- and one frost crystal on a fifth of them, Neon at zero transparency
	if rng:NextNumber() < 0.2 then
		fitting("Frost", Vector3.one * (chunkSize * 0.22),
			CFrame.new(outer) * CFrame.Angles(rng:NextNumber(0, 3), rng:NextNumber(0, 3), 0),
			Color3.fromRGB(178, 226, 255), Enum.Material.Neon, { Transparency = 0 })
	end
end

local function buildCrust(count: number, rng: Random, style): Folder
	style = style or CRUST_STYLES.dirt
	local crust = Instance.new("Folder")
	crust.Name = "Crust"

	-- Sized so neighbours overlap: the shell must read as one solid rock, and a
	-- gap between chunks would let the player see the prize before sifting.
	--
	-- The 1/sqrt(count) keeps coverage constant as the count changes -- chunk
	-- area falls as 1/count, so the shell hides the prize equally well at 14
	-- clumps or 34. The 2.6 is the OVERLAP, raised from the original 2.35: at
	-- 2.35 the coverage ratio is 1.02x, i.e. "just barely enough IF PERFECTLY
	-- TILED", and these are randomly rotated cubes with 1.05-1.45 size jitter
	-- rather than tiles. 2.6 puts it near 1.25x so neighbours genuinely overlap,
	-- which is what keeps the prize hidden once the shell starts hollowing out.
	local chunkSize = LUMP_RADIUS * 2.6 / math.sqrt(count)

	for i = 1, count do
		local dir = fibonacciDirection(i, count)
		local chunk = Instance.new("Part")
		chunk.Name = "Chunk" .. i
		chunk.Size = Vector3.new(
			chunkSize * rng:NextNumber(1.05, 1.45),
			chunkSize * rng:NextNumber(1.05, 1.45),
			chunkSize * rng:NextNumber(1.05, 1.45)
		)
		chunk.CFrame = CFrame.new(dir * LUMP_RADIUS * 0.82)
			* CFrame.Angles(
				rng:NextNumber(0, math.pi * 2),
				rng:NextNumber(0, math.pi * 2),
				rng:NextNumber(0, math.pi * 2)
			)
		chunk.Color = style.palette[rng:NextInteger(1, #style.palette)]
		chunk.Material = style.materials[rng:NextInteger(1, #style.materials)]
		chunk.Anchored = true
		chunk.CanCollide = false
		chunk.CanQuery = true -- THE aim target
		chunk.CanTouch = false
		chunk.CastShadow = false
		chunk.TopSurface = Enum.SurfaceType.Smooth
		chunk.BottomSurface = Enum.SurfaceType.Smooth
		if style.frosted then
			-- cut as a shard: one axis drawn out, and the ice ones catch the light
			local axis = rng:NextInteger(1, 3)
			local s = chunk.Size
			local stretch = rng:NextNumber(1.15, 1.6)
			chunk.Size = Vector3.new(
				axis == 1 and s.X * stretch or s.X,
				axis == 2 and s.Y * stretch or s.Y,
				axis == 3 and s.Z * stretch or s.Z)
			if chunk.Material == Enum.Material.Ice or chunk.Material == Enum.Material.Glacier then
				chunk.Reflectance = 0.12
			end
		end
		chunk:SetAttribute("ChunkIndex", i)
		chunk:SetAttribute("BaseColor", chunk.Color)
		-- Recorded so setChunkErosion can eat the clump away as it is worked and
		-- popChunk can throw a full-size one. Read off the part rather than
		-- recomputed, because the size carries per-chunk jitter.
		chunk:SetAttribute("BaseSize", chunk.Size)
		chunk.Parent = crust
		if style.frosted then
			frostChunk(chunk, dir, rng, chunkSize)
		end
	end

	return crust
end

-- A crusted lump. Identical on the outside whatever is inside it.
function ItemVisuals.buildEncased(itemId: string, seed: number?): Model
	local rng = Random.new(seed or 0)

	local model = Instance.new("Model")
	model.Name = "Lump_" .. itemId

	local clean = ItemVisuals.buildClean(itemId)
	clean.Parent = model
	model.PrimaryPart = clean.PrimaryPart

	local styleKey = ItemVisuals.crustStyleFor(itemId)
	local crust = buildCrust(ItemConfig.chunkCount(itemId), rng, CRUST_STYLES[styleKey])
	crust.Parent = model

	-- Move the shell onto the item, not the other way round: PivotTo on the
	-- whole model would carry the crust with it and undo the centring.
	local origin = clean:GetPivot().Position
	-- Descendants, not children: a frosted clump carries its cap and icicles
	-- as children, and they have to travel with it.
	for _, part in crust:GetDescendants() do
		if part:IsA("BasePart") then
			part.CFrame = part.CFrame + origin
		end
	end

	model:SetAttribute("ItemId", itemId)
	model:SetAttribute("ChunkTotal", ItemConfig.chunkCount(itemId))
	-- Survives WashServer stripping the id off the mount, and the client reads
	-- it to erode, blast and spill the right stuff. Not a tell: the player dug
	-- this lump on the island whose whole pool wears the style.
	model:SetAttribute("CrustStyle", styleKey)
	ItemVisuals.setUncovered(model, 0)
	return model
end

function ItemVisuals.chunksRemaining(model: Model): number
	local crust = model:FindFirstChild("Crust")
	return crust and #crust:GetChildren() or 0
end

function ItemVisuals.findChunk(model: Model, index: number): BasePart?
	local crust = model:FindFirstChild("Crust")
	return crust and crust:FindFirstChild("Chunk" .. index) or nil
end

--------------------------------------------------------------------------
-- EROSION LOOK
--------------------------------------------------------------------------

--[[
	A chunk part-way gone. Purely cosmetic; the authoritative number is on the
	server.

	THE CLUMP DOES NOT CHANGE SIZE, AND IT MUST NOT. Read this before adding
	anything that touches chunk.Size or chunk.CFrame here.

	An earlier version of this shrank the clump as it was worked -- 100% down to
	84% -- on the theory that a lump of sand being blasted should visibly wear
	away. It broke the wash, and not subtly:

	  THE AIM RAY IS THE ONLY THING THAT PICKS A TARGET. WashClientController
	  casts one ray from the cursor with an Include filter set to the Crust
	  folder, and whatever it hits IS the chunk that receives the jet. A chunk
	  that shrinks pulls its own outer face inward and away from that ray, so a
	  neighbour -- still at full radius -- becomes the nearest thing along the
	  line. Measured over a grid of 169 cursor positions: 20% of them handed the
	  jet to a different clump partway through, WITH THE CURSOR PERFECTLY STILL.

	  It is self-reinforcing, too. The clump that steals the aim starts shrinking
	  in its turn and hands it on again, so the work smears across the shell and
	  nothing finishes. What that feels like to play is a jet that only works if
	  you find one of the spots where it does -- which is precisely how it was
	  reported.

	So the work is shown by COLOUR and by THINNING: it darkens as it soaks, then
	pales as the sand gives up, and the clump itself goes translucent as it is
	worked. The clump stays a solid object AT A FIXED SIZE for its whole life, and
	then popChunk throws it off. Coming off is still the end of the animation.

	⚠️ SIZE IS THE THING THAT MUST NOT MOVE, NOT OPACITY. Everything measured
	above is about GEOMETRY: a chunk that shrinks pulls its outer face away from
	the aim ray and hands the jet to a neighbour. Transparency does not move a
	surface -- a transparent part with CanQuery true is hit by a raycast exactly
	as a solid one is -- so the ceiling below is free of that whole failure. Do
	not "finish the effect" by scaling the part.
]]
--[[
	THE CEILING WENT 0.10 -> 0.55 (2026-09-10), AND IT IS A DELIBERATE TRADE.

	buildCrust overlaps its chunks to about 1.25x coverage under a note saying the
	shell "keeps the prize hidden once the shell starts hollowing out" -- hiding
	the find is an explicit goal of the shape. This walks part of that back on
	purpose, because a player asked for the opposite on 2026-09-09: that a lump
	should resolve into what it is as you work it, rather than staying an opaque
	rock until the last clump pops and a card announces the answer.

	WHAT IT ACTUALLY BUYS: a clump you have been holding the jet on thins toward
	half-transparent before it comes off, so the SILHOUETTE underneath starts to
	read through the worked patch while the rest of the shell is still solid. The
	find emerges over the wash instead of arriving at the end of it.

	WHAT IT DOES NOT GIVE AWAY: nothing that was not already there. The clean item
	model is inside the lump from the moment buildEncased runs, and the model
	carries an ItemId attribute -- the lump on the stand has always been fully
	known to the client. What publicView protects is the item in the BAG, which is
	untouched by this.

	0.55 RATHER THAN HIGHER: past about 0.6 a worked clump stops reading as rock
	and starts reading as a rendering fault, and the aimed clump has to stay
	obviously THERE -- it is the thing the player is pointing at.
]]
function ItemVisuals.setChunkErosion(chunk: BasePart, t: number, style: string?)
	t = math.clamp(t, 0, 1)
	local S = styleTable(style)
	local base = chunk:GetAttribute("BaseColor")
	if typeof(base) == "Color3" then
		local wet = base:Lerp(S.wet, math.min(t * 2, 1) * 0.45)
		chunk.Color = wet:Lerp(S.pale, math.max(0, t - 0.5) * 2 * 0.6)
	end
	-- Held flat for the first fifth so a clump that has only just been touched
	-- still looks solid; the thinning belongs to work actually done.
	chunk.Transparency = math.max(0, (t - 0.2) / 0.8) * 0.55
	-- The weather on a frosted clump thins with it (a dirt clump has no
	-- children). NOT the Neon frost crystal: Neon above zero renders as a dark
	-- block (see the head of this file), so it stays lit and goes with the clump.
	for _, f in chunk:GetChildren() do
		if f:IsA("BasePart") and f.Material ~= Enum.Material.Neon then
			local base = f:GetAttribute("BaseTransparency")
			f.Transparency = math.max(type(base) == "number" and base or 0, chunk.Transparency)
		end
	end
end

-- Revealed surface picks up a wet sheen as the shell comes off.
-- 0 = fully encased, 1 = bare.
-- How far the find underneath has been uncovered, 0..1. It was called
-- setWetness when the crust came off with water; the fade it drives is the
-- same either way, but nothing gets wet at a sifting screen.
function ItemVisuals.setUncovered(model: Model, t: number)
	t = math.clamp(t, 0, 1)
	local clean = model:FindFirstChild("Clean")
	if not clean then
		return
	end
	for _, d in clean:GetDescendants() do
		if d:IsA("BasePart") then
			local base = d:GetAttribute("BaseReflectance")
			if type(base) == "number" then
				-- Overshoots the item's dry reflectance on purpose: soaking wet
				-- is shinier than clean, and it dries off on the reveal card.
				d.Reflectance = base * (0.35 + t * 0.95)
			end
		end
	end
	model:SetAttribute("Wetness", t)
end

--------------------------------------------------------------------------
-- PARTICLES
--------------------------------------------------------------------------

local function attachEmitter(parent: BasePart, props): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	for k, v in props do
		e[k] = v
	end
	e.Parent = parent
	return e
end
ItemVisuals.attachEmitter = attachEmitter

--[[
	The jet itself: a tight fast cone from the nozzle.

	EMISSIONDIRECTION IS NOT OPTIONAL HERE. It defaults to Top, and a
	ParticleEmitter fires along the face it is given -- so with the default the
	water left the SIDE of the nozzle, ninety degrees off the barrel, no matter
	where the lance was pointing. Measured against WasherTool's own geometry: of
	the six faces, Front is 0.0 degrees off the barrel and every other one is 90
	or 180. That is why the spray never went where the reticle was.

	(The comment on the Muzzle attachment used to claim a rotated cylinder's
	local +Y runs along the barrel. It does not -- the rotation is about Z, which
	leaves Z alone. Front it is.)
]]
function ItemVisuals.makeJetEmitter(parent: BasePart): ParticleEmitter
	return attachEmitter(parent, {
		Name = "Jet",
		EmissionDirection = Enum.NormalId.Front,
		Texture = GameConfig.Textures.Smoke,
		Color = ColorSequence.new(Color3.fromRGB(236, 250, 255), Color3.fromRGB(176, 216, 236)),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.12),
			NumberSequenceKeypoint.new(0.6, 0.5),
			NumberSequenceKeypoint.new(1, 0.9),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.25),
			NumberSequenceKeypoint.new(0.7, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Lifetime = NumberRange.new(0.12, 0.2),
		Speed = NumberRange.new(90, 120),
		SpreadAngle = Vector2.new(2.5, 2.5),
		Acceleration = Vector3.new(0, -22, 0),
		Rate = 0,
		Enabled = false,
		LightEmission = 0.35,
		ZOffset = 0.2,
	})
end

-- Where the jet lands: spray kicking back off the surface.
function ItemVisuals.makeImpactEmitter(parent: BasePart): ParticleEmitter
	return attachEmitter(parent, {
		Name = "Impact",
		Texture = GameConfig.Textures.Smoke,
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(186, 214, 226)),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.25),
			NumberSequenceKeypoint.new(0.45, 1.0),
			NumberSequenceKeypoint.new(1, 0.1),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Lifetime = NumberRange.new(0.2, 0.45),
		Speed = NumberRange.new(10, 26),
		SpreadAngle = Vector2.new(75, 75),
		Acceleration = Vector3.new(0, -46, 0),
		Drag = 4,
		Rate = 0,
		Enabled = false,
		LightEmission = 0.5,
		ZOffset = 0.35,
	})
end

-- Grit blasted off the crust: brown, heavy, falls fast.
function ItemVisuals.makeGritEmitter(parent: BasePart, style: string?): ParticleEmitter
	local S = styleTable(style)
	return attachEmitter(parent, {
		Name = "Grit",
		Texture = GameConfig.Textures.Smoke,
		Color = ColorSequence.new(S.grit[1], S.grit[2]),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(0.5, 0.55),
			NumberSequenceKeypoint.new(1, 0.05),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Lifetime = NumberRange.new(0.35, 0.8),
		Speed = NumberRange.new(6, 18),
		SpreadAngle = Vector2.new(55, 55),
		Acceleration = Vector3.new(0, -58, 0),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-220, 220),
		Rate = 0,
		Enabled = false,
		ZOffset = 0.15,
	})
end

-- A catch bin going over: a wide, slow, pale fall of material.
--
-- Deliberately the grit emitter's opposite in every parameter that matters --
-- slow where grit is fast, wide where grit is tight, pale where grit is dark.
-- Grit is something being knocked OFF a rock; this is a quantity of sand being
-- poured, and if the two read the same the bin tipping is just more of the
-- noise the player has been watching for the last minute.
function ItemVisuals.makeSandFallEmitter(parent: BasePart): ParticleEmitter
	return attachEmitter(parent, {
		Name = "SandFall",
		Texture = GameConfig.Textures.Smoke,
		Color = ColorSequence.new(Color3.fromRGB(206, 184, 146), Color3.fromRGB(150, 132, 108)),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(0.4, 1.1),
			NumberSequenceKeypoint.new(1, 0.2),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(0.75, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Lifetime = NumberRange.new(0.5, 1.1),
		Speed = NumberRange.new(1, 6),
		SpreadAngle = Vector2.new(32, 32),
		Acceleration = Vector3.new(0, -40, 0),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-90, 90),
		Drag = 1.5,
		Rate = 0,
		Enabled = false,
		ZOffset = 0.1,
	})
end

function ItemVisuals.makeSparkleEmitter(parent: BasePart, rarity: string): ParticleEmitter
	local info = ItemConfig.rarityInfo(rarity)
	return attachEmitter(parent, {
		Name = "Sparkle",
		Texture = GameConfig.Textures.Sparkle,
		Color = ColorSequence.new(info.glow, info.color),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.25, 0.6),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Lifetime = NumberRange.new(0.5, 1.2),
		Speed = NumberRange.new(2, 7),
		SpreadAngle = Vector2.new(180, 180),
		Acceleration = Vector3.new(0, -6, 0),
		Drag = 2,
		LightEmission = 0.9,
		Rate = 0,
		Enabled = false,
		ZOffset = 0.5,
	})
end

function ItemVisuals.burstSparkle(part: BasePart, rarity: string)
	local e = ItemVisuals.makeSparkleEmitter(part, rarity)
	e:Emit(ItemConfig.rarityInfo(rarity).sparkles)
	Debris:AddItem(e, 2.5)
end

--------------------------------------------------------------------------
-- DEBRIS  --  the hand-animated arc every knocked-off clump flies
--------------------------------------------------------------------------

--[[
	WHY THIS IS ANIMATED BY HAND AND NOT HANDED TO PHYSICS.

	spillSand below already made this argument for the catch bin; popChunk has
	now learned it the hard way too, so it is worth stating once for both.

	  * NOTHING IN A BAY COLLIDES. BayBuilder's `trim` clears CanCollide on
	    every prop, so an unanchored clump has nothing to land on -- it falls
	    through the shack floor and out of the world. Turning collision on is
	    worse: the player is frozen in place for the length of a session
	    (ContextActionService holds their movement keys), so a bouncing part
	    that shoves them is a shove they cannot walk out of.

	  * PHYSICS TUNES TO THE WORLD; THIS HAS TO TUNE TO THE SHOT. The wash
	    camera sits 7 studs off the lump, which makes the frame roughly 16
	    studs wide and 10 tall. Real gravity (196 studs/s^2) plus any launch
	    speed that reads as "blasted" puts the clump outside that box in a
	    handful of frames. Measured, with an honest physics throw at 66
	    studs/s: ONE FRAME on screen out of a 0.7 second life. The clump was
	    not failing to fly -- it was flying so hard it may as well have been
	    deleted.

	So: a quarter of real gravity, horizontal drag, and a hand-rolled tumble.
	The clump snaps off the rock, slows as it arcs, drops onto the stand plate
	-- dead centre of frame, the one place the player is already looking --
	skids, and fades. About 0.9s end to end, all of it in shot.

	ONE Heartbeat connection for ALL live debris, made when the first clump
	needs it and dropped when the last one dies. A lump is 34 chunks and the top
	pressure tier takes one off every 0.08s, so at peak there are eight or nine
	of these in the air; that is one table walk per frame, not thirty-four
	coroutines each sitting on their own task.wait().
]]

local DEBRIS_GRAVITY = 52    -- a quarter of the engine's, so the arc fits the shot
local DEBRIS_DRAG = 2.6      -- horizontal only; vertical drag just fights the arc

local live = {}
local liveConn = nil

local function stepDebris(dt: number)
	-- A frame hitch must not teleport a clump across the bay.
	dt = math.min(dt, 1 / 30)

	for i = #live, 1, -1 do
		local d = live[i]
		if not d.part.Parent then
			table.remove(live, i)
		else
			d.age += dt

			-- Drag on the horizontal only: that is what turns a hard launch into
			-- "snapped off, then slowed" rather than a flat line out of frame.
			local decay = math.exp(-DEBRIS_DRAG * dt)
			d.vel = Vector3.new(d.vel.X * decay, d.vel.Y - DEBRIS_GRAVITY * dt, d.vel.Z * decay)
			d.pos += d.vel * dt

			-- The stand plate, if this clump happens to come down over it. The
			-- plate is only 2.4 studs square and the rock above it is 3.5 across,
			-- so the rock OVERHANGS its own stand and most clumps start outside
			-- the footprint -- landing is the exception, not the rule. Hence the
			-- radius test: without it a clump would stop dead in mid-air on an
			-- invisible plane a stud past the plate edge.
			--
			-- Whatever misses simply keeps falling and fades on the way down,
			-- which is correct: the drain pan is five studs lower and below the
			-- bottom of the shot, so there is nothing down there to land on that
			-- the player can see anyway.
			local land = d.land
			if land and d.pos.Y <= land.y and d.vel.Y < 0 then
				local dx, dz = d.pos.X - land.centre.X, d.pos.Z - land.centre.Z
				if dx * dx + dz * dz <= land.radius * land.radius then
					d.pos = Vector3.new(d.pos.X, land.y, d.pos.Z)
					-- A dead stop looks like a bug and a full bounce looks like
					-- rubber; wet sand keeps about a quarter of it and skids.
					d.vel = Vector3.new(d.vel.X * 0.35, -d.vel.Y * 0.28, d.vel.Z * 0.35)
					d.spin *= 0.35
				end
			end

			d.rot = d.rot * CFrame.Angles(d.axis.X * d.spin * dt,
				d.axis.Y * d.spin * dt, d.axis.Z * d.spin * dt)
			d.part.CFrame = CFrame.new(d.pos) * d.rot

			if d.age > d.hold then
				d.part.Transparency = math.clamp((d.age - d.hold) / d.fade, 0, 1)
			end
			if d.age > d.hold + d.fade then
				d.part:Destroy()
				table.remove(live, i)
			end
		end
	end

	if #live == 0 and liveConn then
		liveConn:Disconnect()
		liveConn = nil
	end
end

local function trackDebris(entry)
	table.insert(live, entry)
	if not liveConn then
		liveConn = RunService.Heartbeat:Connect(stepDebris)
	end
end

--------------------------------------------------------------------------
-- CHUNK POP  (client-side flourish)
--------------------------------------------------------------------------

--[[
	The server destroys the real chunk; this throws a short-lived copy of it
	away from the jet so the crust visibly comes OFF rather than blinking out.

	The copy is unanchored and collides with nothing: it is pure decoration, it
	never touches physics the server cares about, and Debris takes it either
	way if the fade coroutine is interrupted.

	THE ARC IS AUTHORED, NOT SIMULATED -- see the DEBRIS block above for why,
	and for the measurements that got it there.

	The launch is deliberately fast (18-30 studs/s) because a pressure washer
	should snap a clump off rather than lob it, but DEBRIS_DRAG bleeds most of
	that off inside the first quarter second, so it travels about four studs
	rather than the twenty a constant-velocity throw would cover. Fast start,
	short distance: that is the whole trick, and it is the thing real physics
	cannot give you here without a drag constant it does not have.

	THE LAUNCH IS FLATTENED, AND THAT IS THE LOAD-BEARING PART.

	The wash shot is about 23 studs wide and only 9.8 TALL, so horizontal room
	is nearly free and vertical room is the scarce resource -- there are roughly
	five studs of visible fall between the rock and the bottom of frame. Firing
	a clump straight along the jet does not respect that: the jet points at
	whatever the cursor is on, so a chunk on top of the rock gets launched
	nearly straight up. Measured, before this was flattened, a top chunk left
	the frame through the CEILING at 11.4 studs and was never seen again.

	So the jet only supplies a DIRECTION ON THE GROUND PLANE. Lift is a small
	fixed loft plus a damped share of however much the jet was pointing upward,
	which together cap the apex at about 1.6 studs -- enough to read as knocked
	loose, never enough to leave the shot upward.

	`land` is optional: { y, centre, radius } for the stand plate. Clumps that
	come down inside it land, skid and settle in view; everything else keeps
	falling and fades on the way down. Pass nil where there is no plate.

	Size is restored from BaseSize defensively. Nothing shrinks chunks today
	(see setChunkErosion for why that must stay true), but a clump should be
	full size whatever the shell was doing when it came free.
]]
function ItemVisuals.popChunk(template: BasePart, jetDirection: Vector3, land: { y: number, centre: Vector3, radius: number }?)
	local flake = template:Clone()
	flake.Name = "Flake"
	flake:ClearAllChildren()
	local baseSize = template:GetAttribute("BaseSize")
	if typeof(baseSize) == "Vector3" then
		flake.Size = baseSize
	end
	flake.Transparency = 0
	-- ANCHORED. stepDebris owns this part's CFrame from here on; leaving it to
	-- physics is what put it through the shack floor and out of the shot.
	flake.Anchored = true
	flake.CanCollide = false
	flake.CanQuery = false
	flake.CanTouch = false
	flake.CastShadow = false
	flake.Parent = workspace

	local dir = (jetDirection.Magnitude > 0.01) and jetDirection.Unit or Vector3.new(0, 1, 0)

	-- Ground-plane direction only. A degenerate flat vector means the jet was
	-- pointing straight up or down the rock, so pick any heading rather than
	-- dropping the clump on the spot.
	local flat = Vector3.new(dir.X, 0, dir.Z)
	if flat.Magnitude < 0.05 then
		local a = math.random() * math.pi * 2
		flat = Vector3.new(math.cos(a), 0, math.sin(a))
	end
	flat = flat.Unit

	-- Small fixed loft, plus a damped share of whatever upward angle the jet
	-- had. Worst case is about 13 studs/s, which tops out 1.6 studs up.
	local lift = math.random(30, 70) / 10 + math.max(0, dir.Y) * 6

	trackDebris({
		part = flake,
		pos = flake.Position,
		rot = flake.CFrame.Rotation,
		vel = flat * (math.random(140, 240) / 10)
			+ Vector3.new((math.random() - 0.5) * 5, lift, (math.random() - 0.5) * 5),
		-- One random axis per clump, so thirty-four of them do not all tumble
		-- the same way down the same plane.
		axis = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5).Unit,
		spin = math.random(60, 140) / 10,
		age = 0,
		hold = 0.55,   -- solid while it flies and lands
		fade = 0.35,   -- then it goes, roughly as it reaches the bottom of frame
		land = land,
	})
	-- Backstop, exactly as spillSand does it: if stepDebris is ever interrupted
	-- the part still goes.
	Debris:AddItem(flake, 2)

	--[[
		The grit puff gets its OWN anchored part rather than hanging off the
		chunk.

		It used to parent straight to `template`, which is the real chunk -- and
		the server destroys that within a frame or two of sending the message
		that got us here. Destroying an emitter's parent takes its live particles
		with it, so the puff was being cut off part-way through almost every
		time: emitted, then deleted before it had played. On a lump that now
		comes apart in 34 pieces that is 34 half-burst puffs.

		Eight particles rather than the old sixteen, because there are two and a
		half times as many chunks now; the total grit in the air over a wash is
		roughly what it always was.
	]]
	local puff = Instance.new("Part")
	puff.Name = "GritPuff"
	puff.Size = Vector3.new(0.2, 0.2, 0.2)
	puff.CFrame = template.CFrame
	puff.Transparency = 1
	puff.Anchored = true
	puff.CanCollide = false
	puff.CanQuery = false
	puff.CanTouch = false
	puff.CastShadow = false
	puff.Parent = workspace

	local grit = ItemVisuals.makeGritEmitter(puff)
	grit:Emit(8)
	Debris:AddItem(puff, 2)
end

--------------------------------------------------------------------------
-- SAND SPILL  (client-side flourish)
--------------------------------------------------------------------------

--[[
	Clumps of sand thrown over the lip when a full catch bin goes over.

	Particles alone will not carry this moment. A puff of smoke-textured sprites
	reads as DUST, and dust is not what the player has spent the last minute
	watching accumulate -- they want to see the stuff itself leave. So: actual
	parts, with size and shadowless weight, arcing out and landing.

	ANCHORED, and integrated by hand rather than handed to physics, for two
	reasons that are both about the bay specifically:

	* Nothing decorative in a sifting bay collides (BayBuilder's `trim` clears
	  CanCollide on every prop), so unanchored debris would drop straight through
	  the shack floor and out of the world.
	* Turning collision ON instead is worse. The player is frozen in place for the
	  length of a session -- ContextActionService has their movement keys -- so a
	  bouncing part that shoves them is a shove they cannot walk out of.

	The arc is nine lines. The engine doing it for us is not worth either problem.
]]
function ItemVisuals.spillSand(origin: CFrame, count: number, spread: number, floorY: number, style: string?)
	local S = styleTable(style)
	for _ = 1, count do
		local g = Instance.new("Part")
		g.Name = "SandSpill"
		local r = math.random(18, 42) / 100
		-- Wider than tall: a clump of damp sand, not a marble.
		--
		-- Via a sphere MESH, because `Shape = Enum.PartType.Ball` ignores unequal
		-- Size axes and draws a sphere of the smallest one -- which would have
		-- turned every one of these back into exactly the marble the line above
		-- says it is not.
		g.Size = Vector3.new(r * 1.6, r, r * 1.4)
		local clump = Instance.new("SpecialMesh")
		clump.MeshType = Enum.MeshType.Sphere
		clump.Parent = g
		g.Color = S.spill[1]:Lerp(S.spill[2], math.random())
		g.Material = S.spillMat
		g.Anchored = true
		g.CanCollide = false
		g.CanQuery = false
		g.CanTouch = false
		g.CastShadow = false
		g.CFrame = origin
			* CFrame.new((math.random() - 0.5) * spread, 0, (math.random() - 0.5) * spread)
		g.Parent = workspace

		local pos = g.Position
		local vel = Vector3.new(
			(math.random() - 0.5) * 10,
			math.random(2, 7),
			(math.random() - 0.5) * 10
		)

		task.spawn(function()
			local t0 = os.clock()
			while g.Parent do
				local dt = task.wait()
				vel += Vector3.new(0, -52 * dt, 0)
				pos += vel * dt
				if pos.Y <= floorY then
					-- A dead stop looks like a bug; a full bounce looks like
					-- rubber. Sand keeps a quarter of it and skids.
					pos = Vector3.new(pos.X, floorY, pos.Z)
					vel = Vector3.new(vel.X * 0.4, -vel.Y * 0.25, vel.Z * 0.4)
				end
				g.CFrame = CFrame.new(pos)

				local age = os.clock() - t0
				if age > 0.85 then
					g.Transparency = math.min(1, (age - 0.85) / 0.5)
				end
				if age > 1.4 then
					break
				end
			end
			if g.Parent then
				g:Destroy()
			end
		end)
		-- Belt and braces, exactly as popChunk does it: if the loop above is ever
		-- interrupted, the part still goes.
		Debris:AddItem(g, 2)
	end
end

return ItemVisuals
