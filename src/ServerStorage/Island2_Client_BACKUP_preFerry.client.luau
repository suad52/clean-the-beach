--[[
	Island2_Client  --  StarterPlayer.StarterPlayerScripts.Island2_Client

	Everything about the Dunes that MOVES or is private to one player. The island
	itself -- pyramid, statue, bazaar, the camel's body -- is built once on the
	server by Island2Builder; this is the half that would cost bandwidth or leak
	state if the server did it.

		tumbleweeds     pure decoration, so they are made and rolled locally and
		                never touch the network at all
		camel walk      the model is shared, but the WALK is computed from
		                workspace:GetServerTimeNow(), which every client agrees on
		                to within a few ms. So everyone sees the camel in the same
		                place without the server replicating a moving model.
		heat grade      a colour/atmosphere shift on arrival. Lighting is one
		                shared object, but a client's writes to it do not
		                replicate, so each player gets the grade for the island
		                THEY are standing on.
		gate lock       whether the beach gate works is per player, and a
		                ProximityPrompt is a single shared instance -- so the
		                enable/disable is done here, locally, on top of the
		                server's own check.

	All of it idles when the player is not on the island: the per-frame work is
	behind a zone test that costs one distance check every half second.
]]

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local Config = require(ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Config"))

local DUNES = Config.island(2)
local GROUND = DUNES.cleanY

----------------------------------------------------------------
-- Folders and shared raycast params
----------------------------------------------------------------
local old = workspace:FindFirstChild("Dunes_FX")
if old then
	old:Destroy()
end
local fx = Instance.new("Folder")
fx.Name = "Dunes_FX"
fx.Parent = workspace

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace.Terrain }
groundParams.IgnoreWater = true

local function terrainY(x: number, z: number, fallback: number): number
	local hit = workspace:Raycast(Vector3.new(x, 120, z), Vector3.new(0, -200, 0), groundParams)
	return hit and hit.Position.Y or fallback
end

----------------------------------------------------------------
-- Ambience
--
-- Routed through the BeachSFX SoundGroup, which is what the Settings panel's
-- Sound Effects toggle already drives -- so switching effects off silences the
-- desert too, with no extra wiring. Both ids are from the licensed Pro Sound
-- Effects catalogue and were checked for a non-zero TimeLength before being
-- written in: creator-uploaded audio is private and fails SILENTLY.
----------------------------------------------------------------
local function soundGroup(name: string): SoundGroup
	local g = SoundService:FindFirstChild(name)
	if not g then
		g = Instance.new("SoundGroup")
		g.Name = name
		g.Parent = SoundService
	end
	return g
end

local sfxGroup = soundGroup("BeachSFX")

local function ambience(id: string, speed: number, peak: number): Sound
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Looped = true
	s.Volume = 0
	s.PlaybackSpeed = speed
	s.SoundGroup = sfxGroup
	s.Parent = SoundService
	s:Play()
	s:SetAttribute("Peak", peak)
	return s
end

-- Two layers, because one loop is recognisably one loop within a minute. A
-- steady airy bed plus a slower, quieter howl at a different length means the
-- two drift against each other and the repeat stops being audible.
local windBed = ambience("rbxassetid://9125742262", 0.55, 0.20)
local windHowl = ambience("rbxassetid://9118747853", 0.72, 0.11)

----------------------------------------------------------------
-- The heat grade
--
-- Its OWN ColorCorrectionEffect rather than pushing the shared one around:
-- CTB_Server's applyLook owns that one, and two writers on one effect is how
-- you get a look that depends on boot order. Neutral at home, so on the beach
-- this is a no-op.
----------------------------------------------------------------
local grade = Instance.new("ColorCorrectionEffect")
grade.Name = "DesertGrade"
grade.Brightness = 0
grade.Contrast = 0
grade.Saturation = 0
grade.TintColor = Color3.new(1, 1, 1)
grade.Parent = Lighting

local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
local HOME_ATMO = atmo and {
	Density = atmo.Density, Haze = atmo.Haze, Glare = atmo.Glare,
	Color = atmo.Color, Decay = atmo.Decay,
} or nil

-- Ambient is the one that actually fixes the pyramid.
--
-- The sun sits near vertical here (ClockTime 12, latitude 16 -> ~82 degrees),
-- so the pyramid's south face -- the face with the door, the face every player
-- approaches from -- is permanently in its own shade and lit only by ambient.
-- The beach's ambient is a cool grey picked to keep sand shadows crisp, and
-- under it the landmark renders pale blue-white on top of orange sand.
--
-- Warm ambient is also just true of a desert: the bounce light there is sand
-- reflecting sunlight. Captured from whatever the server set, so this stays a
-- shift rather than a fixed value that would fight applyLook.
local HOME_OUT = Lighting.OutdoorAmbient
local HOME_AMB = Lighting.Ambient
local DESERT_OUT = Color3.fromRGB(176, 142, 96)
local DESERT_AMB = Color3.fromRGB(78, 62, 42)

-- Hotter and pushed toward amber, and only a LITTLE hazier than the beach
-- (0.32 / 1.4). The first pass ran this at 0.42 density and 2.4 haze to sell
-- "dust in the air", and it washed the pyramid out to a white silhouette from
-- the bazaar -- 400 studs, which is the main view of the island. The landmark
-- has to survive the weather.
local DESERT_ATMO = {
	Density = 0.335, Haze = 1.75, Glare = 0.42,
	Color = Color3.fromRGB(238, 214, 176),
	Decay = Color3.fromRGB(178, 134, 84),
}

-- WHAT THE STORM DOES TO ALL OF THAT.
--
-- Haze 5.4 against the desert's 1.75. The note above says 2.4 washed the
-- pyramid out to a white silhouette from the bazaar and that the landmark has
-- to survive the weather -- which is exactly right for the weather it normally
-- has, and exactly wrong here. Losing the landmark IS the sandstorm. It is back
-- inside three seconds.
--
-- Saturation goes hard NEGATIVE where the desert's goes up: airborne dust is a
-- grey-brown filter over everything, and a storm that stayed as colourful as a
-- clear noon reads as a fog machine.
local STORM_OUT_C = Color3.fromRGB(118, 88, 54)
local STORM_AMB = Color3.fromRGB(50, 38, 24)
local STORM_ATMO = {
	Density = 0.58, Haze = 5.4, Glare = 0.16,
	Color = Color3.fromRGB(208, 168, 118),
	Decay = Color3.fromRGB(128, 92, 54),
}

local blend = 0            -- 0 = beach, 1 = dunes
local storm = 0            -- 0 = clear, 1 = the front is on top of you
-- Declared up here rather than beside the Heartbeat that maintains it, because
-- the storm section below has to know whether the player is even out here
-- before it agrees to blow.
local onIsland = false

-- The tint is doing more work here than it looks like it should, and it is the
-- right tool for the job rather than a bodge.
--
-- At noon the pyramid's whole front face is in its own shade, lit almost
-- entirely by a bright blue skybox -- so however warm its parts are coloured
-- they render cold, while the flat sand beside them takes the sun directly and
-- reads warm. Chasing that in the part colours does not work (tried); the
-- landmark just gets more saturated in shadow and garish in sun. An amber grade
-- over the whole frame warms the shaded stone and the lit sand together, which
-- is what actually makes the island look like one place.
--
-- Saturation goes UP, not down. The first pass had it negative, which flattened
-- exactly the colour the island needed.
local function lerp(x: number, y: number, t: number): number
	return x + (y - x) * t
end

-- `s` IS SCALED BY `a` INSIDE HERE, deliberately. The storm is a modifier on the
-- desert rather than a weather system of its own, so walking out of the zone
-- mid-storm takes the brown sky with you instead of leaving it painted over the
-- beach -- and there is still exactly ONE writer on Lighting, which is the whole
-- reason this function exists.
local function applyBlend(a: number, s: number)
	s = math.clamp(s, 0, 1) * a

	grade.Brightness = 0.02 * a - 0.10 * s
	grade.Contrast = 0.07 * a + 0.05 * s
	grade.Saturation = 0.06 * a - 0.28 * s
	grade.TintColor = Color3.new(1 - 0.02 * s, 1 - 0.055 * a - 0.06 * s, 1 - 0.14 * a - 0.14 * s)
	Lighting.OutdoorAmbient = HOME_OUT:Lerp(DESERT_OUT, a):Lerp(STORM_OUT_C, s)
	Lighting.Ambient = HOME_AMB:Lerp(DESERT_AMB, a):Lerp(STORM_AMB, s)
	if atmo and HOME_ATMO then
		atmo.Density = lerp(lerp(HOME_ATMO.Density, DESERT_ATMO.Density, a), STORM_ATMO.Density, s)
		atmo.Haze = lerp(lerp(HOME_ATMO.Haze, DESERT_ATMO.Haze, a), STORM_ATMO.Haze, s)
		atmo.Glare = lerp(lerp(HOME_ATMO.Glare, DESERT_ATMO.Glare, a), STORM_ATMO.Glare, s)
		atmo.Color = HOME_ATMO.Color:Lerp(DESERT_ATMO.Color, a):Lerp(STORM_ATMO.Color, s)
		atmo.Decay = HOME_ATMO.Decay:Lerp(DESERT_ATMO.Decay, a):Lerp(STORM_ATMO.Decay, s)
	end
end

----------------------------------------------------------------
-- Tumbleweeds
--
-- Confined to the southern half of the island (z < 105) so they never roll
-- through the pyramid, which starts at z = 118. They blow east, and respawn on
-- the western shore when they run out of island.
----------------------------------------------------------------
-- Studs travelled per full leg cycle. Bigger = longer, lazier strides.
local CAMEL_STRIDE = 5.2

local TUMBLE_COUNT = 9
local TUMBLE_Z0, TUMBLE_Z1 = -262, 102
local TUMBLE_X0, TUMBLE_X1 = DUNES.cx - 288, DUNES.cx + 288
local WEED_COLOUR = Color3.fromRGB(152, 124, 78)

local trng = Random.new(20260819)
local tumbleweeds = {}

local function buildTumbleweed()
	local m = Instance.new("Model")
	m.Name = "Tumbleweed"

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(0.5, 0.5, 0.5)
	root.Transparency = 1
	root.Anchored, root.CanCollide, root.CanQuery, root.CanTouch = true, false, false, false
	root.Parent = m
	m.PrimaryPart = root

	-- half a dozen crossed twigs. Cheaper than any mesh and, tumbling, reads as
	-- a ball of dry scrub from more than about ten studs away.
	for _ = 1, 6 do
		local p = Instance.new("Part")
		p.Size = Vector3.new(0.26, 0.26, trng:NextNumber(3.2, 4.4))
		p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
		p.CastShadow = false
		p.Color = WEED_COLOUR
		p.Material = Enum.Material.Grass
		p.CFrame = root.CFrame * CFrame.Angles(
			trng:NextNumber(0, math.pi), trng:NextNumber(0, math.pi), trng:NextNumber(0, math.pi))
		p.Parent = m
	end

	m.Parent = fx
	return m
end

local function placeUpwind(tw, spread: boolean)
	-- `spread` is only true at startup: dropping all nine on the western edge at
	-- once would send them across in a visible line abreast.
	tw.x = spread and trng:NextNumber(TUMBLE_X0, TUMBLE_X1) or TUMBLE_X0
	tw.z = trng:NextNumber(TUMBLE_Z0, TUMBLE_Z1)
	tw.speed = trng:NextNumber(7, 13)
	tw.drift = trng:NextNumber(-2.2, 2.2)
	tw.wobFreq = trng:NextNumber(0.4, 0.9)
	tw.radius = trng:NextNumber(1.5, 2.2)
	tw.spin = trng:NextNumber(0, 6.28)
end

for _ = 1, TUMBLE_COUNT do
	local tw = { model = buildTumbleweed() }
	placeUpwind(tw, true)
	table.insert(tumbleweeds, tw)
end

local ROLL_AXIS = Vector3.new(0, 0, 1)     -- wind runs along +X, so it rolls about Z

local function stepTumbleweeds(dt: number, t: number, gust: number)
	-- The one thing on this island that was ALREADY blowing, so it is the cheapest
	-- way to say the wind has picked up -- and the weeds are the reason the storm
	-- runs -X to +X in the first place.
	local push = 1 + gust * 2.6
	for _, tw in ipairs(tumbleweeds) do
		tw.x += tw.speed * push * dt
		tw.z += (tw.drift + math.sin(t * tw.wobFreq) * 2.4) * dt

		local dx, dz = tw.x - DUNES.cx, tw.z - DUNES.cz
		if tw.x > TUMBLE_X1 or tw.z < TUMBLE_Z0 or tw.z > TUMBLE_Z1
			or dx * dx + dz * dz > 292 * 292 then
			placeUpwind(tw, false)
		end

		-- Spin is tied to speed over radius, so a fast one visibly rolls faster
		-- instead of skating. The hop is what sells it as bouncing over sand.
		tw.spin += (tw.speed * push / tw.radius) * dt
		local hop = math.abs(math.sin(t * tw.speed * 0.42)) * 0.75
		local y = terrainY(tw.x, tw.z, GROUND) + tw.radius + hop
		tw.model:PivotTo(CFrame.new(tw.x, y, tw.z) * CFrame.fromAxisAngle(ROLL_AXIS, -tw.spin))
	end
end

----------------------------------------------------------------
-- The camel
--
-- Walked entirely from workspace:GetServerTimeNow(), which is the same clock on
-- every client. No remote, no replication, and everyone still sees it in the
-- same place -- the model is anchored and a client's CFrame writes to anchored
-- parts stay local.
----------------------------------------------------------------
local camel = nil
local camelWired = false

-- Resolved lazily, and RE-resolved if it goes away.
--
-- StreamingEnabled is on in this place. When a player spawns on the beach the
-- camel is 1500 studs away, so none of its PARTS exist on this client yet --
-- only the Folder and Model above them, which always replicate. The first
-- version of this did a WaitForChild at boot, which therefore timed out and gave
-- up for the whole session: the camel stood still forever, and it looked like an
-- animation bug rather than a streaming one.
--
-- Parts can stream back out too, so this checks its own work each time instead
-- of trusting a one-off resolve.
local function ensureCamel(): boolean
	if camel and camel.root.Parent then
		return true
	end
	camel = nil

	local island = workspace:FindFirstChild("Island2")
	local m = island and island:FindFirstChild("Camel")
	local root = m and m:FindFirstChild("Root")
	if not root then
		return false
	end

	-- Offsets are captured off the model as the server built it. After this the
	-- client owns every one of these CFrames.
	local legs, parts = {}, {}
	for _, p in ipairs(m:GetChildren()) do
		if p:IsA("BasePart") and p ~= root then
			local offset = root.CFrame:ToObjectSpace(p.CFrame)
			local entry = { part = p, offset = offset }
			local hip = p:GetAttribute("HipY")
			if hip then
				-- pivot at the TOP of the leg, so a swing reads as coming from the
				-- shoulder rather than the knee
				entry.pivot = (offset * CFrame.new(0, hip, 0)).Position
				-- SAME-SIDE pairs, not diagonal ones. Camels pace: the front and back
				-- leg on one side swing together, which is where their rolling walk
				-- comes from. A diagonal trot is what a horse does.
				entry.phase = (p.Name == "LegFL" or p.Name == "LegBL") and 0 or math.pi
				legs[p.Name] = entry
			end
			table.insert(parts, entry)
		end
	end
	-- hooves swing with the leg they belong to
	for _, entry in ipairs(parts) do
		if not entry.pivot then
			for legName, leg in pairs(legs) do
				if entry.part.Name == legName .. "Hoof" then
					entry.pivot, entry.phase = leg.pivot, leg.phase
					break
				end
			end
		end
		local n = entry.part.Name
		entry.head = (n == "Neck" or n == "Head" or n == "Snout" or n == "Ear" or n == "Eye")
		entry.tail = (n == "Tail")
	end

	-- Bail rather than half-build if the model streamed in without its tuning
	-- attributes yet; the next tick will try again.
	local cx, cz = m:GetAttribute("CentreX"), m:GetAttribute("CentreZ")
	local r, period = m:GetAttribute("Radius"), m:GetAttribute("Period")
	if not (cx and cz and r and period) then
		return false
	end

	camel = { model = m, root = root, parts = parts, cx = cx, cz = cz, r = r, period = period, nod = 0 }

	-- "Pet" is handled here and nowhere else. It changes nothing the server owns,
	-- so there is no reason to spend a remote on it. Wired once -- the prompt
	-- survives streaming even when the parts around it do not.
	if not camelWired then
		local prompt = m:FindFirstChildWhichIsA("ProximityPrompt", true)
		if prompt then
			camelWired = true
			local grunt = Instance.new("Sound")
			grunt.SoundId = "rbxassetid://9116298078"
			grunt.Volume = 0.4
			grunt.PlaybackSpeed = 1.45   -- a big cat's yawning bellow, up into camel range
			grunt.SoundGroup = sfxGroup
			grunt.Parent = prompt.Parent
			prompt.Triggered:Connect(function()
				grunt:Play()
				if camel then
					camel.nod = 1
				end
			end)
		end
	end

	return true
end

local function stepCamel(t: number, dt: number)
	if not ensureCamel() then
		return
	end

	local phase = (t % camel.period) / camel.period
	local ang = phase * math.pi * 2
	local px = camel.cx + math.cos(ang) * camel.r
	local pz = camel.cz + math.sin(ang) * camel.r
	-- derivative of the position above: the way it is actually travelling
	local tangent = Vector3.new(-math.sin(ang), 0, math.cos(ang))

	-- Stride frequency comes OUT of the speed rather than being a number picked
	-- to look about right. One full leg cycle per STRIDE studs travelled means
	-- the feet always land at the pace the body is moving; retune the lap time
	-- and the walk retunes itself instead of turning into a scrub or a sprint.
	local speed = (2 * math.pi * camel.r) / camel.period
	local stride = t * (speed / CAMEL_STRIDE) * math.pi * 2
	local bob = math.sin(stride * 2) * 0.2
	local y = terrainY(px, pz, GROUND) + bob

	-- YAW, not CFrame.lookAt. The camel is modelled with its head at local +Z, so
	-- what has to point along the tangent is the frame's Z AXIS -- and lookAt
	-- aims the LookVector, which is MINUS Z. Building it with lookAt therefore
	-- drew the whole animal 180 degrees round: it walked its lap tail-first, legs
	-- pacing correctly but backwards, which reads as a bug in the animation
	-- rather than in the orientation.
	local yaw = math.atan2(tangent.X, tangent.Z)
	local base = CFrame.new(px, y, pz) * CFrame.Angles(0, yaw, 0)

	camel.nod = math.max(0, camel.nod - dt * 1.6)
	local nod = math.sin(camel.nod * math.pi) * 0.5

	for _, e in ipairs(camel.parts) do
		local offset = e.offset
		if e.pivot then
			local swing = math.sin(stride + e.phase) * 0.42
			-- rotate the part's offset about the hip, in root space
			offset = CFrame.new(e.pivot) * CFrame.Angles(swing, 0, 0)
				* CFrame.new(-e.pivot) * offset
		elseif e.head then
			offset = CFrame.new(0, math.sin(stride) * 0.16 - nod * 1.4, 0) * offset
		elseif e.tail then
			offset = CFrame.Angles(0, math.sin(stride * 0.8) * 0.35, 0) * offset
		end
		e.part.CFrame = base * offset
	end
end

----------------------------------------------------------------
-- Blowing sand
----------------------------------------------------------------
local sandPart = Instance.new("Part")
sandPart.Name = "BlowingSand"
sandPart.Size = Vector3.new(4, 14, 70)
sandPart.Transparency = 1
sandPart.Anchored, sandPart.CanCollide, sandPart.CanQuery, sandPart.CanTouch = true, false, false, false
sandPart.Parent = fx

local sandEmit = Instance.new("ParticleEmitter")
sandEmit.Texture = "rbxasset://textures/particles/smoke_main.dds"
sandEmit.Rate = 0
sandEmit.Lifetime = NumberRange.new(1.4, 2.8)
sandEmit.Speed = NumberRange.new(30, 52)
sandEmit.SpreadAngle = Vector2.new(16, 7)
sandEmit.EmissionDirection = Enum.NormalId.Right     -- +X, the same way the weeds roll
sandEmit.Color = ColorSequence.new(Color3.fromRGB(230, 202, 154))
sandEmit.LightEmission = 0.25
sandEmit.Size = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 2),
	NumberSequenceKeypoint.new(1, 9),
})
sandEmit.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.25, 0.82),
	NumberSequenceKeypoint.new(1, 1),
})
sandEmit.Parent = sandPart

----------------------------------------------------------------
-- THE SANDSTORM
--
-- The desert's half of the tide, and the mechanic was already there: CTB_Server
-- resets a player's grid once they have raked `resetAt` of it, re-seeds the
-- litter, pays `resetBonus` and fires "Tide" carrying that island's own
-- `resetName` -- which for the Dunes has always been SANDSTORM. The trash came
-- back and the banner said the right word. What was missing was the WEATHER: a
-- reset you cannot see is just a bag of litter reappearing behind you for no
-- reason.
--
-- So this is presentation and nothing else. It is not networked, it decides
-- nothing, and CTB_Client re-messes the field off the same message whether any
-- of this runs or not.
--
-- THE FRONT RUNS WITH THE ISLAND'S OWN WIND, -X to +X: the same way the
-- tumbleweeds roll and the same way sandEmit blows grit past the camera. A
-- storm crossing at right angles to everything else on the island reads as a
-- prop rather than as weather.
----------------------------------------------------------------
local STORM_IN, STORM_HOLD, STORM_OUT = 0.9, 2.4, 2.6
local STORM_LEN = STORM_IN + STORM_HOLD + STORM_OUT

-- Long enough across Z to cover the whole island, and SAT LOW.
--
-- The first version was 160 tall centred at 0.40 of that, which put the middle
-- of the emitting volume 64 studs up -- so a part-volume emitter spread its dust
-- across 160 studs of sky and the player, standing at y 6, watched a brown smear
-- go past well above their head. A wall you are meant to be swallowed by has to
-- put most of its mass in the bottom thirty studs, which is where the camera is.
local WALL_LEN, WALL_H = 660, 96
local WALL_Y = 0.28             -- fraction of WALL_H above the ground the centre sits
local WALL_TRAVEL = 820

local stormT = -1          -- seconds since the front was released; < 0 = clear

local wall = Instance.new("Part")
wall.Name = "Sandstorm"
wall.Size = Vector3.new(12, WALL_H, WALL_LEN)
wall.Transparency = 1
wall.Anchored, wall.CanCollide, wall.CanQuery, wall.CanTouch = true, false, false, false
wall.CastShadow = false
wall.CFrame = CFrame.new(DUNES.cx - WALL_TRAVEL * 0.5, GROUND + WALL_H * WALL_Y, DUNES.cz)
wall.Parent = fx

-- Emitted in WORLD space off a part that is travelling at ~200 studs/s, so the
-- particles are left behind as the emitter runs on. That trail IS the wall --
-- a stationary emitter this size just looks like a fog bank.
local function wallLayer(props): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/smoke_main.dds"
	e.EmissionDirection = Enum.NormalId.Right    -- +X, downwind
	e.Rate = 0
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-24, 24)
	e.LightEmission = 0.12
	for k, v in props do
		e[k] = v
	end
	e.Parent = wall
	return e
end

-- The body: slow, enormous, and only ever about half opaque. Fully opaque dust
-- reads as a wall someone built rather than as air you cannot see through.
local wallBody = wallLayer({
	Color = ColorSequence.new(Color3.fromRGB(216, 184, 136), Color3.fromRGB(140, 110, 74)),
	Size = NumberSequence.new(38, 104),
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.16, 0.30),
		NumberSequenceKeypoint.new(0.72, 0.46),
		NumberSequenceKeypoint.new(1, 1),
	}),
	Lifetime = NumberRange.new(2.6, 4.4),
	Speed = NumberRange.new(18, 38),
	SpreadAngle = Vector2.new(52, 20),
	Acceleration = Vector3.new(0, 2, 0),
	Drag = 0.5,
	ZOffset = -3,
})

-- The leading edge: smaller, faster, paler. This is the part that arrives
-- BEFORE the body and tells the player something is coming.
local wallEdge = wallLayer({
	Color = ColorSequence.new(Color3.fromRGB(238, 214, 172), Color3.fromRGB(186, 154, 110)),
	Size = NumberSequence.new(14, 52),
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.62),
		NumberSequenceKeypoint.new(1, 1),
	}),
	Lifetime = NumberRange.new(1.1, 2.0),
	Speed = NumberRange.new(70, 130),
	SpreadAngle = Vector2.new(26, 14),
	Drag = 1.6,
	ZOffset = 1,
})

-- A one-shot on its own instance rather than pitching the looping beds: those
-- two are the island's ambience and have to be exactly where they were when the
-- storm is over.
local function gustSound()
	local s = Instance.new("Sound")
	s.SoundId = "rbxassetid://9118747853"
	s.Volume = 0.55
	s.PlaybackSpeed = 0.5                       -- the howl dropped into a roar
	s.SoundGroup = sfxGroup
	s.Parent = SoundService
	s:Play()
	Debris:AddItem(s, 12)
end

-- 0 .. 1 .. 0 across the three phases.
local function stormAmount(t: number): number
	if t < 0 then
		return 0
	elseif t < STORM_IN then
		return t / STORM_IN
	elseif t < STORM_IN + STORM_HOLD then
		return 1
	end
	return math.max(0, 1 - (t - STORM_IN - STORM_HOLD) / STORM_OUT)
end

local function startStorm()
	-- Already blowing: a second reset inside six seconds is not possible (the
	-- server rate-limits it) but restarting the timer would snap the sky back to
	-- clear for a frame if it ever were.
	if stormT >= 0 then
		return
	end
	stormT = 0
	gustSound()
end

-- Same remote CTB_Client listens on. Keyed off the ISLAND rather than off the
-- word "SANDSTORM": this file is the Dunes' weather, and renaming the event in
-- Config should not silently switch its sky off.
local ctbNet = ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Net")
ctbNet.OnClientEvent:Connect(function(action, islandId)
	-- Not out here to see it: the field still gets re-messed and the banner still
	-- fires, but there is no reason to spend a storm on an empty desert -- and
	-- painting the sky brown for someone standing on the beach would be a bug.
	if action == "Tide" and islandId == DUNES.id and onIsland then
		startStorm()
	end
end)

----------------------------------------------------------------
-- The gate lock
--
-- Per player, and done here rather than on the server, because a
-- ProximityPrompt is ONE instance shared by everybody -- disabling it server
-- side would lock out every player the moment one of them was short a level.
-- Client writes to it stay local. The server checks the level again on trigger,
-- so this is presentation, not security.
----------------------------------------------------------------
-- Both gates, and it keeps trying rather than giving up. Same streaming reason
-- as the camel: the DESERT gate's parts do not exist on this client until the
-- player is out there, and a one-shot resolve at boot would leave its sign
-- reading whatever the server stamped on it for everybody.
local gateRefreshers = {}

local function wireGate(island: Instance, name: string, lockable: boolean): boolean
	local gate = island:FindFirstChild("Gates") and island.Gates:FindFirstChild(name)
	local pad = gate and gate:FindFirstChild("Pad")
	local prompt = pad and pad:FindFirstChild("TravelPrompt")
	local board = gate and gate:FindFirstChild("Board")
	local gui = board and board:FindFirstChild("GateGui")
	local info = gui and gui:FindFirstChild("Info")
	if not (prompt and info) then
		return false
	end
	local veil = gate:FindFirstChild("Veil")
	local unlock = island:GetAttribute("UnlockLevel") or 3
	local label = info.Text

	local function refresh()
		-- The way home is never locked -- see the note on the server's handler.
		local open = (not lockable) or (player:GetAttribute("RollerLevel") or 1) >= unlock
		prompt.Enabled = open
		info.Text = open and label or string.format("SIFTER Lv.%d NEEDED", unlock)
		info.TextColor3 = open and Color3.fromRGB(255, 244, 214) or Color3.fromRGB(255, 172, 148)
		if veil then
			veil.Transparency = open and 0.62 or 0.9
			veil.Color = open and Color3.fromRGB(60, 168, 158) or Color3.fromRGB(96, 96, 104)
		end
	end

	table.insert(gateRefreshers, refresh)
	refresh()
	return true
end

--[[
	THE TOMB DOOR'S HINT, for the same reason and by the same route.

	The pyramid door is gated on REBIRTHS (VaultBuilder.REBIRTHS, published onto
	the island root as TombRebirths), and its billboard read "TAP TO OPEN" for
	everybody -- so a player under the gate was invited to click a door whose
	only possible answer was to strain and settle back. That reads as a broken
	door, and was reported as one. The slab is fine; it was the sign in front of
	it that was lying.

	Presentation only: the server re-checks Rebirths on the click, which is the
	same split as the gate prompts above.
]]
--[[
	RE-RESOLVED EVERY TIME, and never latched "done".

	StreamingEnabled is on. A player standing on the beach is 1500 studs from the
	pyramid, so the door's parts -- and this label with them -- do not exist on
	this client at all, and they stream back OUT again whenever the player leaves.
	Capturing the instance once (which is what the gate wiring above does, and
	gets away with because a wrong gate sign is cosmetic) would leave a stale
	reference pointing at a destroyed label, and the door would go back to
	inviting a click it is going to refuse.

	So: no cached instance, and the poll below runs for the whole session. It
	costs one FindFirstChild chain a second and writes nothing unless the text is
	actually wrong.
]]
local DOOR_OPEN_TEXT = "TAP TO OPEN"     -- what Island2Builder stamps on the label

local function doorLabel(island: Instance)
	local entrance = island:FindFirstChild("Entrance")
	local door = entrance and entrance:FindFirstChild("Door")
	local hint = door and door:FindFirstChild("DoorHint")
	return hint and hint:FindFirstChildWhichIsA("TextLabel")
end

local function paintDoorHint(island: Instance)
	local label = doorLabel(island)
	if not label then
		return
	end
	local needed = island:GetAttribute("TombRebirths") or 2
	local open = (player:GetAttribute("Rebirths") or 0) >= needed
	local want = open and DOOR_OPEN_TEXT
		or string.format("SEALED \u{2014} %d REBIRTH%s", needed, needed == 1 and "" or "S")
	if label.Text ~= want then
		label.Text = want
	end
	label.TextColor3 = open and Color3.fromRGB(255, 226, 150) or Color3.fromRGB(255, 168, 146)
	-- SignKit.floating outlines the glyphs; the stroke has to move with the fill
	-- or gold letters end up wearing the locked colour's edge.
	local stroke = label:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = open and Color3.fromRGB(74, 44, 12) or Color3.fromRGB(78, 24, 20)
	end
end

task.spawn(function()
	local island = workspace:WaitForChild("Island2", 90)
	if not island then
		warn("[Dunes] island folder never replicated -- gate signs will not update")
		return
	end
	player:GetAttributeChangedSignal("RollerLevel"):Connect(function()
		for _, fn in ipairs(gateRefreshers) do
			fn()
		end
	end)
	-- A rebirth is exactly the moment this changes, and the player is standing
	-- on the beach when it happens -- so without this the door still reads
	-- SEALED when they next walk up to it.
	player:GetAttributeChangedSignal("Rebirths"):Connect(function()
		paintDoorHint(island)
	end)

	local beachDone, desertDone = false, false
	while true do
		beachDone = beachDone or wireGate(island, "BeachGate", true)
		desertDone = desertDone or wireGate(island, "DesertGate", false)
		-- Not latched: see the note on paintDoorHint. The gates are, because that
		-- is what they already did and a stale gate sign is only cosmetic.
		paintDoorHint(island)
		task.wait(1)
	end
end)

----------------------------------------------------------------
-- Drive it
--
-- One connection, and everything inside it is behind the blend value: off the
-- island that is zero, and this costs a distance check every 0.4s and nothing
-- else. Tumbleweeds and the camel do not tick where nobody can see them.
----------------------------------------------------------------
local WIND_BACK = Vector3.new(-40, 5, 0)     -- where to sit the emitter, upwind of the player
local FADE = 2.4

local zoneTimer = 0
local lastBlend, lastStorm = -1, -1

applyBlend(0, 0)

RunService.Heartbeat:Connect(function(dt)
	local t = workspace:GetServerTimeNow()

	zoneTimer -= dt
	if zoneTimer <= 0 then
		zoneTimer = 0.4
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local zone = hrp and Config.zoneAt(hrp.Position) or nil
		onIsland = (zone ~= nil and zone.id == DUNES.id)
	end

	local target = onIsland and 1 or 0
	if blend ~= target then
		blend += math.clamp(target - blend, -dt / FADE, dt / FADE)
		if math.abs(blend - target) < 0.002 then
			blend = target
		end
	end

	-- THE FRONT
	if stormT >= 0 then
		stormT += dt
		if stormT >= STORM_LEN then
			stormT = -1
			storm = 0
		else
			storm = stormAmount(stormT)
			-- Straight across the island at about 200 studs a second, and it keeps
			-- going through the clearing phase -- a front that stopped dead over
			-- the player and faded on the spot would read as a fog machine
			-- switching off.
			local p = stormT / STORM_LEN
			wall.CFrame = CFrame.new(
				DUNES.cx - WALL_TRAVEL * 0.5 + WALL_TRAVEL * p,
				GROUND + WALL_H * WALL_Y,
				DUNES.cz)
			wallBody.Rate = 210 * storm
			wallEdge.Rate = 150 * storm
		end
		if storm <= 0 then
			wallBody.Rate, wallEdge.Rate = 0, 0
		end
	end

	-- ONE write per changed frame, and it now covers the wind as well. The
	-- volumes used to be set only inside the `blend ~= target` branch, so they
	-- were correct on arrival and then frozen -- which meant a storm could not
	-- have made itself heard however loud it asked to be.
	if blend ~= lastBlend or storm ~= lastStorm then
		lastBlend, lastStorm = blend, storm
		applyBlend(blend, storm)
		windBed.Volume = windBed:GetAttribute("Peak") * blend * (1 + storm * 2.6)
		windHowl.Volume = windHowl:GetAttribute("Peak") * blend * (1 + storm * 3.4)
		windBed.PlaybackSpeed = 0.55 + storm * 0.30
		windHowl.PlaybackSpeed = 0.72 + storm * 0.24
		-- The grit that blows past the camera: this is the whole screen-space half
		-- of the effect, and at the storm's peak it is what stops the player being
		-- able to see their own sifter.
		sandEmit.Rate = (24 + storm * 420) * blend
		sandEmit.Speed = NumberRange.new(30 + storm * 46, 52 + storm * 78)
		-- The grains get BIGGER as well as more numerous. Rate alone just makes a
		-- denser field of the same specks, which reads as static rather than as
		-- sand -- the size is what turns them into airborne material.
		sandEmit.Size = NumberSequence.new(2 + storm * 7, 9 + storm * 22)
		sandEmit.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.25, 0.82 - storm * 0.34),
			NumberSequenceKeypoint.new(1, 1),
		})
	end

	if blend > 0.01 then
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp then
			sandPart.CFrame = CFrame.new(hrp.Position + WIND_BACK)
		end
		stepTumbleweeds(dt, t, storm)
		stepCamel(t, dt)
	end
end)

print("[Dunes] client ready \u{2014} tumbleweeds, camel, heat grade and wind armed")
