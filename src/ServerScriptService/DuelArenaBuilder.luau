--[[
	DuelArenaBuilder  --  ServerScriptService.DuelArenaBuilder

	The four clean-off arenas, at DuelConfig.Origin.

	EACH ONE IS TWO IDENTICAL PITCHES AND A WALL BETWEEN THEM. That is the whole
	shape, and the identical part is load-bearing: this is a race, so anything
	that is true of one pitch has to be true of the other. The two are mirrored
	across the divider rather than copied along it, so neither player is the one
	facing the sun or the one with the longer run to the far corner.

	The THEME is the only thing that changes between arenas -- floor, trim,
	accent, wall and a handful of props. Every colour comes off the island it
	names (see DuelConfig.Arenas) so an arena reads as a corner of a place the
	player has been, not as a recolour of a box.

	ADOPTION CONTRACT, same as every builder here: if the folder already exists
	this does nothing, so a hand-dressed arena wins. And the twice-rule that goes
	with it -- once these are saved in the place, an art fix has to go into this
	file AND the live instances.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage:WaitForChild("Modules")
local DuelConfig = require(Modules:WaitForChild("DuelConfig"))
local SignKit = require(Modules:WaitForChild("SignKit"))

local DuelArenaBuilder = {}

--------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------

local function part(parent, name, size, cf, colour, material, props)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = colour
	p.Material = material
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props or {} do p[k] = v end
	p.Parent = parent
	return p
end

-- Dressing: out of every spatial query. Two players are sprinting round this
-- pitch and must never catch on the scenery.
local function trim(parent, name, size, cf, colour, material, props)
	props = props or {}
	props.CanCollide = false
	props.CanQuery = false
	props.CanTouch = false
	return part(parent, name, size, cf, colour, material, props)
end

-- A board stands proud of its post; see the same note in AfkShoreBuilder.
local PROUD = 0.25
local function board(parent, name, size, cf, text, faces)
	local b = part(parent, name, size, cf * CFrame.new(0, 0, -PROUD),
		Color3.fromRGB(38, 42, 48), Enum.Material.SmoothPlastic,
		{ CanCollide = false, CanQuery = false })
	local ok, err = pcall(SignKit.dress, b, text, faces or { Enum.NormalId.Front })
	if not ok then warn("[DuelArenas] SignKit refused a board: " .. tostring(err)) end
	return b
end

--------------------------------------------------------------------------
-- THEME DRESSING
--
-- Each is a handful of props that say which island this corner belongs to.
-- All non-collidable, all outside the run of the pitch.
--------------------------------------------------------------------------

local function dressTidePools(m, o, W, D, t)
	for i = 1, 5 do
		local a = (i / 5) * math.pi * 2
		local r = D * 0.42
		local p = o + Vector3.new(math.cos(a) * W * 0.42, 0, math.sin(a) * r)
		trim(m, "Pool", Vector3.new(11 - i, 0.3, 8 + i), CFrame.new(p + Vector3.new(0, 0.14, 0)),
			t.sky, Enum.Material.Glass, { Transparency = 0.35, Shape = Enum.PartType.Cylinder,
			Orientation = Vector3.new(0, 0, 90) })
		trim(m, "Rock", Vector3.new(4 + i * 0.6, 3, 4), CFrame.new(p + Vector3.new(7, 1.1, 4)),
			t.wall, Enum.Material.Slate, { Shape = Enum.PartType.Ball })
	end
end

local function dressSunkenSouk(m, o, W, D, t)
	for i = -1, 1, 2 do
		for j = 1, 3 do
			local h = 8 + j * 3
			trim(m, "BrokenColumn", Vector3.new(3.4, h, 3.4),
				CFrame.new(o + Vector3.new(i * W * 0.36, h * 0.5, (j - 2) * D * 0.3))
					* CFrame.Angles(0, math.rad(j * 20), math.rad(i * 3)),
				t.wall, Enum.Material.Concrete, { Shape = Enum.PartType.Cylinder,
				Orientation = Vector3.new(0, 0, 90) })
			trim(m, "ColumnCap", Vector3.new(4.4, 1, 4.4),
				CFrame.new(o + Vector3.new(i * W * 0.36, h + 0.4, (j - 2) * D * 0.3)),
				t.accent, Enum.Material.Concrete)
		end
	end
end

local function dressBlossomCourt(m, o, W, D, t)
	for i = -1, 1, 2 do
		for j = -1, 1 do
			local p = o + Vector3.new(i * W * 0.38, 0, j * D * 0.3)
			trim(m, "LanternBase", Vector3.new(2.6, 1.2, 2.6), CFrame.new(p + Vector3.new(0, 0.6, 0)),
				t.floor, Enum.Material.Concrete)
			trim(m, "LanternPost", Vector3.new(1.1, 4, 1.1), CFrame.new(p + Vector3.new(0, 3.2, 0)),
				t.floor, Enum.Material.Concrete)
			trim(m, "LanternBox", Vector3.new(3.2, 2.4, 3.2), CFrame.new(p + Vector3.new(0, 6.2, 0)),
				t.accent, Enum.Material.Neon)
			trim(m, "LanternCap", Vector3.new(4.4, 0.8, 4.4), CFrame.new(p + Vector3.new(0, 7.7, 0)),
				t.wall, Enum.Material.Slate)
		end
	end
end

local function dressCinderPit(m, o, W, D, t)
	local rng = Random.new(4242)
	for i = 1, 9 do
		local h = rng:NextNumber(5, 14)
		local p = o + Vector3.new(rng:NextNumber(-W * 0.42, W * 0.42), 0,
			rng:NextNumber(-D * 0.44, D * 0.44))
		trim(m, "Basalt", Vector3.new(rng:NextNumber(2, 5), h, rng:NextNumber(2, 5)),
			CFrame.new(p + Vector3.new(0, h * 0.4, 0)) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
			t.wall, Enum.Material.Slate)
		trim(m, "Ember", Vector3.new(1.4, 0.3, 1.4), CFrame.new(p + Vector3.new(0, 0.16, 0)),
			t.accent, Enum.Material.Neon)
	end
end

local DRESS = {
	TidePools = dressTidePools,
	SunkenSouk = dressSunkenSouk,
	BlossomCourt = dressBlossomCourt,
	CinderPit = dressCinderPit,
}

--------------------------------------------------------------------------
-- ONE ARENA
--------------------------------------------------------------------------

local function buildArena(parent, index: number): Model
	local t = DuelConfig.Arenas[index]
	local m = Instance.new("Model")
	m.Name = ("Arena_%d"):format(index)
	m:SetAttribute("ArenaKey", t.key)
	m.Parent = parent

	local o = DuelConfig.arenaOrigin(index)
	local W, D, DIV = DuelConfig.PitchWidth, DuelConfig.PitchDepth, DuelConfig.Divider
	local full = W * 2 + DIV

	-- THE TRIM, under everything: the arena drawn with a line round it.
	part(m, "Trim", Vector3.new(full + 12, 2, D + 12),
		CFrame.new(o + Vector3.new(0, -1.5, 0)), t.trim, Enum.Material.Slate)

	-- THE TWO PITCHES. Named, because DuelService scatters litter inside their
	-- bounds and needs to ask each one how big it is.
	for side = 1, 2 do
		local c = DuelConfig.pitchCentre(index, side)
		local floor = part(m, ("Pitch_%d"):format(side), Vector3.new(W, 2, D),
			CFrame.new(c + Vector3.new(0, -1, 0)), t.floor, Enum.Material.Sand)
		floor:SetAttribute("Side", side)

		-- Where the player stands at GO, facing up their own pitch.
		local spawn = part(m, ("Spawn_%d"):format(side), Vector3.new(1, 1, 1),
			CFrame.lookAt(c + Vector3.new(0, 3, -D * 0.5 + 6), c + Vector3.new(0, 3, 0)),
			t.accent, Enum.Material.SmoothPlastic,
			{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
		spawn:SetAttribute("Side", side)

		-- A start stripe, so GO has somewhere to happen.
		trim(m, "StartLine", Vector3.new(W - 6, 0.08, 1.6),
			CFrame.new(c + Vector3.new(0, 0.05, -D * 0.5 + 10)), t.accent, Enum.Material.Neon)
	end

	-- THE DIVIDER. Solid and chest-high: you can see your opponent losing, and
	-- you cannot wander onto their pitch and pick up their litter.
	part(m, "Divider", Vector3.new(DIV, 9, D),
		CFrame.new(o + Vector3.new(0, 4.5, 0)), t.wall, Enum.Material.Concrete)
	trim(m, "DividerCap", Vector3.new(DIV + 1.4, 0.9, D + 1.4),
		CFrame.new(o + Vector3.new(0, 9.3, 0)), t.accent, Enum.Material.SmoothPlastic)

	-- THE BOUNDARY, so nobody runs off into the void. Low at the front (the
	-- camera looks over it), tall at the back.
	part(m, "WallBack", Vector3.new(full + 12, 14, 3),
		CFrame.new(o + Vector3.new(0, 7, D * 0.5 + 6)), t.wall, Enum.Material.Concrete)
	part(m, "WallFront", Vector3.new(full + 12, 4, 3),
		CFrame.new(o + Vector3.new(0, 2, -D * 0.5 - 6)), t.wall, Enum.Material.Concrete)
	for _, s in ipairs({ -1, 1 }) do
		part(m, "WallSide", Vector3.new(3, 12, D + 12),
			CFrame.new(o + Vector3.new(s * (full * 0.5 + 6), 6, 0)), t.wall, Enum.Material.Concrete)
	end

	--[[
		THE SCOREBOARD, on the back wall where both players face it.

		The live score is a per-player HUD, not this -- two racers need their own
		numbers in their own corner of the screen. This board carries the arena's
		NAME, which is the thing that wants to be readable from the pitch: it is
		how a player learns the four arenas apart.
	]]
	for _, s in ipairs({ -1, 1 }) do
		part(m, "BoardPost", Vector3.new(1.4, 16, 1.4),
			CFrame.new(o + Vector3.new(s * 26, 8, D * 0.5 + 4)), t.trim, Enum.Material.Concrete)
	end
	board(m, "ArenaBoard", Vector3.new(58, 9, 0.6),
		CFrame.new(o + Vector3.new(0, 17, D * 0.5 + 4)) * CFrame.Angles(0, math.pi, 0),
		t.name, { Enum.NormalId.Front })

	local dress = DRESS[t.key]
	if dress then
		dress(m, o, full, D, t)
	end

	m.PrimaryPart = m:FindFirstChild("Trim")
	return m
end

--------------------------------------------------------------------------
-- THE SET
--------------------------------------------------------------------------

function DuelArenaBuilder.build(): Folder
	local root = Instance.new("Folder")
	root.Name = DuelConfig.FolderName
	root.Parent = workspace
	for i = 1, #DuelConfig.Arenas do
		buildArena(root, i)
	end
	root:SetAttribute("Built", true)
	return root
end

function DuelArenaBuilder.ensureWorld(): Folder
	local existing = workspace:FindFirstChild(DuelConfig.FolderName)
	if existing then
		return existing
	end
	return DuelArenaBuilder.build()
end

return DuelArenaBuilder
