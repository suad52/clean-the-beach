--[[
	Island5_Client  --  StarterPlayer.StarterPlayerScripts.Island5_Client

	Everything about Penguin Island that MOVES or is private to one player. The
	island itself -- the frozen sea, the colony's rookery, the snowy forest, the
	arctic village, the icebergs and the cliffs -- is built once on the server by
	its builder; this is the half that would cost bandwidth or leak state if the
	server did it.

		the cold grade   Penguin Island is early afternoon under a high white sky
		                 and the beach is noon under a clean blue one. Lighting is
		                 ONE shared object, but a client's writes to it do not
		                 replicate, so each player gets the hour and the grade for
		                 the island THEY are standing on. Same trick the dunes' heat
		                 grade, the cove's golden hour and the ash isle's late
		                 afternoon already run on.
		the still sea    Terrain.WaterColor and friends are global PROPERTIES, not
		                 per-region ones. Written here they stay on this machine,
		                 which is the only way the open leads between the pack ice
		                 get a near-black, near-still, mirror-flat sea without the
		                 beach going arctic for everybody.
		snowfall         the thing the island is named for as much as the birds: a
		                 slow, drifting fall of flakes that follows the player, so
		                 there is always something in shot wherever they stand.
		the aurora       ribbons the builder hangs in the sky as Neon parts; this
		                 file only breathes colour through them.
		the colony       the penguins are anchored server models; this file bobs,
		                 waddles and nods them ON THIS MACHINE only, so sixty birds
		                 cost the network nothing at all.
		the blizzard     the island's reset picture, the way the cove has a hanami
		                 gust and the ash isle an eruption: a second 0..1 factor
		                 layered over the island blend for fourteen seconds.

	All of it idles when the player is not on the island: the per-frame work is
	behind a zone test that costs one circle check every 0.4 seconds.

	WHAT IS NOT HERE, AND WHY
	-------------------------
	THE FROZEN SEA ITSELF. That is terrain -- a Glacier course poured over Water
	by the builder -- and it is walkable, so it has to exist on the server. The
	client only tints whatever open water is left.

	THE SKY. CTB_Server.applyLook destroys every Sky it did not make and asserts
	six tropical faces, server side, once at boot. The clock, the grade and the
	atmosphere below carry the weather on their own; nothing here makes a Sky, an
	Atmosphere, or touches the shared "ColorCorrection" effect.

	THE HOUR. 13.0, barely off noon. A low arctic sun through the clock would be
	the atmospheric choice and it costs exactly what the ash isle's note warned
	about: readability. White ground under a low sun is a white-out with long
	blue shadows, and the player is here to find things in it. The cold comes
	from the grade and the ambient instead, and the hour only nudges the shadows
	off dead vertical so the snow has some shape.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local ProximityPromptService = game:GetService("ProximityPromptService")

local player = Players.LocalPlayer
local Config = require(ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Config"))

local PENGUIN = Config.island(8)
local GROUND = PENGUIN.cleanY              -- 3.0, shared by every field in the game

----------------------------------------------------------------
-- Folders
----------------------------------------------------------------
-- Destroyed and rebuilt, so re-running this script in a live session (which is
-- what a Studio script reload does) leaves one set of emitters rather than two
-- stacked ones at double the rate.
local old = workspace:FindFirstChild("Island5_FX")
if old then
	old:Destroy()
end
local fx = Instance.new("Folder")
fx.Name = "Island5_FX"
fx.Parent = workspace

----------------------------------------------------------------
-- THE PALETTE
--
-- One table, so the grade, the sea, the snow and the aurora are demonstrably
-- the same set of colours rather than a handful of hand-picked blues that
-- nearly match. The island's props export their own PALETTE for the geometry;
-- these are the LIGHT values, which are a different problem -- a part colour is
-- read off the part, a particle colour is read against the sky behind it.
----------------------------------------------------------------
local SNOW_WHITE = Color3.fromRGB(255, 255, 255)
local SNOW_SHADE = Color3.fromRGB(220, 232, 244)
local AURORA_A = Color3.fromRGB(90, 255, 190)     -- the green end
local AURORA_B = Color3.fromRGB(170, 120, 255)    -- the violet end

----------------------------------------------------------------
-- Ambience
--
-- Routed through the BeachSFX SoundGroup, which is what the Settings panel's
-- Sound Effects toggle already drives -- so switching effects off silences this
-- island too, with no extra wiring. That line is NOT optional: AudioKit's adopt()
-- safety net only sweeps workspace descendants, and these live under
-- SoundService, so an ungrouped Sound here would ignore the toggle entirely.
--
-- BOTH IDS BELOW ALREADY PLAY IN THIS PLACE. Nothing new was licensed for this
-- island: the wind bed is the dunes' wind bed and the groan is the ash isle's
-- rumble, both ProSoundEffects, both loaded and measured when THOSE files were
-- written. A Sound with an id that does not resolve does not throw -- it sits
-- there playing nothing -- and silence looks exactly like a feature nobody got
-- to yet, which is why no untested id is allowed in here.
--
--   9125742262  the dunes' wind bed, run at 0.9 rather than their 0.55: faster
--               is thinner and colder, a wind over ice rather than over sand
--   9112795583  Hollow Rumble, 122.50s, at 0.7: slowed until it stops being a
--               volcano and starts being a sea-ice sheet groaning under itself
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
local ambienceSounds = {}

-- NOT PLAYED HERE. Started and paused on the blend crossing instead, so a client
-- that never sails north never decodes two looping tracks for the session.
local function ambience(id: string, speed: number, peak: number): Sound
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Looped = true
	s.Volume = 0
	s.PlaybackSpeed = speed
	s.SoundGroup = sfxGroup       -- mandatory; see the note above
	s.Parent = SoundService
	s:SetAttribute("Peak", peak)
	table.insert(ambienceSounds, s)
	return s
end

--[[
	THE WIND IS THE BED, the way it is on the dunes, and it is quieter than the
	dunes run it. Arctic cold is not loud; a wind that howls reads as a desert
	storm, and what sells a frozen place is the wind being THERE, constant and
	thin, under a silence that the honks and the ice have to break.
]]
ambience("rbxassetid://9125742262", 0.9, 0.14)

-- The ice. Quietest thing in the mix by a distance and deliberately so: at 0.7
-- the rumble's low end stops being a mountain and becomes a sheet of pack ice
-- settling. At full level it would be the volcano again.
ambience("rbxassetid://9112795583", 0.7, 0.06)

----------------------------------------------------------------
-- THE COLD GRADE
--
-- Its OWN ColorCorrectionEffect rather than pushing the shared one around:
-- CTB_Server's applyLook owns "ColorCorrection", and two writers on one effect is
-- how you get a look that depends on boot order. Neutral at home, so on the
-- beach this is a no-op.
----------------------------------------------------------------
local grade = Instance.new("ColorCorrectionEffect")
grade.Name = "PenguinGrade"
grade.Brightness = 0
grade.Contrast = 0
grade.Saturation = 0
grade.TintColor = Color3.new(1, 1, 1)
grade.Parent = Lighting

-- There is exactly one Atmosphere in this place and CTB_Server's `ensure`
-- destroys duplicates of anything it owns. See Island3_Client's note for the bug
-- that rule exists to prevent: two Atmospheres named the same, every script
-- writing the first and the renderer drawing the second. Resolved at runtime,
-- never cached from Edit mode, and never created here.
local atmo = Lighting:FindFirstChildOfClass("Atmosphere")

-- Captured rather than assumed, so this stays a SHIFT away from whatever the
-- server set instead of a fixed value that fights applyLook.
local HOME_ATMO = atmo and {
	Density = atmo.Density, Haze = atmo.Haze, Glare = atmo.Glare,
	Color = atmo.Color, Decay = atmo.Decay,
} or nil
local HOME_OUT = Lighting.OutdoorAmbient
local HOME_AMB = Lighting.Ambient

local Terrain = workspace.Terrain
local HOME_WATER = {
	Color = Terrain.WaterColor,
	Transparency = Terrain.WaterTransparency,
	Reflectance = Terrain.WaterReflectance,
	WaveSize = Terrain.WaterWaveSize,
	WaveSpeed = Terrain.WaterWaveSpeed,
}

----------------------------------------------------------------
-- THE ISLAND'S TARGETS
----------------------------------------------------------------
--[[
	THE AMBIENT GOES UP AND GOES BLUE, which is the one place this island and the
	ash isle agree while wanting opposite things.

	Ashfall lifted OutdoorAmbient because a dark island under a dirty sky had no
	fill light and its shadows went to black. This island lifts it because snow
	BOUNCES: every shaded face on a white field is lit from below by the ground,
	and that bounce is sky-coloured, so shadows on snow are pale blue rather than
	grey. A neutral ambient here makes the snow look like plaster. 150,168,192 is
	well above the beach's 122,126,132 and it is cool by about the same amount,
	and the Ambient (indoor/under-cover) follows it at the usual quarter.
]]
local PENGUIN_OUT = Color3.fromRGB(150, 168, 192)
local PENGUIN_AMB = Color3.fromRGB(56, 64, 78)

--[[
	THE ATMOSPHERE IS THINNER THAN THE ASH ISLE'S, on purpose.

	Ashfall's 0.42 / 1.45 was measured at 150 studs of visibility and its own note
	calls that the ceiling. This island is bigger, its landmarks (the berg field,
	the cliffs, the wreck on the far shore) are the reason to cross it, and a
	haze that hides them at 200 studs turns the biggest map in the game into a
	corridor. 0.34 / 1.6 is a cold, bright, milky sky rather than a fog: the haze
	is higher than Ashfall's because a white sky over white ground WANTS the
	horizon soft, and the density is lower so the far shore still reads.

	The colour is barely off white, and the decay is pale as well: on a frozen
	sea the horizon does not go dark, it goes to the colour of the sky.
]]
local PENGUIN_ATMO = {
	Density = 0.34, Haze = 1.6, Glare = 0.10,
	Color = Color3.fromRGB(228, 238, 248),
	Decay = Color3.fromRGB(150, 170, 196),
}

--[[
	THE SEA IS NEARLY STILL, AND NEARLY BLACK, AND A MIRROR.

	Whatever open water the builder leaves between the ice is a lead: deep, cold,
	sheltered from the wind by the sheet around it, and it does not chop. WaveSize
	0.04 at WaveSpeed 2 is a surface that barely moves -- against the beach's
	0.12 / 6 it is what tells the player this is a different kind of water before
	they have read the colour. Transparency 0.12 so it is dark and opaque (arctic
	water is not clear, it is ink), and Reflectance 0.62 so the sky and the bergs
	sit in it. The cove's note records that 0.30 rendered its bay flat white,
	but that was a pale, bright, high-transparency water; on a dark opaque one
	the reflection is the whole picture.
]]
local PENGUIN_WATER = {
	Color = Color3.fromRGB(52, 110, 140),
	Transparency = 0.12,
	Reflectance = 0.62,
	WaveSize = 0.04,
	WaveSpeed = 2,
}

--[[
	THE CLOCK, THROUGH LIGHTINGLOCK'S ATTRIBUTE AND NEVER THROUGH Lighting.ClockTime.

	LightingLock holds ClockTime at the LocalPlayer's CTB_ClockTarget on the
	changed signal and a 2 s poll; a write to ClockTime directly is put back at
	noon within a frame and the two fight forever. The lock is retargetable
	instead -- one number on the LocalPlayer -- and easing is explicitly the
	CALLER's job, which is why applyBlend writes it every frame the blend moves.

	13.0 rather than the ash isle's 16.2 or the cove's 17: see the header. The
	hour is only here to lean the shadows a touch, so the snow field is not lit
	dead flat from straight overhead.
]]
local CLOCK_ATTR = "CTB_ClockTarget"
local HOUR_HOME = 12
local HOUR_PENGUIN = 13.0

local blend = 0            -- 0 = beach, 1 = Penguin Island
local everTouched = false  -- has this file ever written a shared value?

--[[
	THE BLIZZARD FACTOR, 0..1, and it is the STORM's, not the island's. Declared
	up here because applyBlend has to fold it in and applyBlend is defined before
	the storm is. It is the cove's gust shape rather than the ash isle's flash:
	the storm does not tint or brighten, it THICKENS -- more density, much more
	haze, the ambient washed toward white -- and it multiplies the snow.

	Everything it adds is scaled by `a` as well as by `storm`: a blizzard on an
	island the player is not standing on adds nothing to the beach.
]]
local storm = 0
local STORM_DENSITY = 0.28
local STORM_HAZE = 3.0
local STORM_OUT = Color3.fromRGB(214, 222, 232)
local STORM_SNOW = 5          -- rate becomes DRIFT_RATE * blend * (1 + 5 * storm)

--[[
	SATURATION GOES DOWN AND CONTRAST BARELY MOVES, which is the reverse of the
	ash isle's grade for the reverse reason.

	Ashfall pushed saturation because its palette had none to spare and the lava
	needed all of it. This palette is white, pale blue and slate, and the only
	saturated things in it are the village's painted boards, the penguins' beaks
	and the litter -- which is exactly the set that has to stay legible. Pulling
	saturation by a small amount cools the whole frame (warm tones lose more than
	blues do) and leaves the orange beak and the red can as the only warm things
	in shot, which is the point. -0.08 is the limit: past -0.12 the wood in the
	village goes grey and the whole place starts looking like a photocopy.

	Contrast stays low because a bright overcast IS low-contrast, and on white
	ground added contrast blows the highlights out to a flat sheet with no shape
	in it at all. A hair of brightness keeps the snow reading as white rather
	than the pale grey a cool tint would otherwise leave it.

	THE TINT PULLS RED DOWN, NOT GREEN AND BLUE. Every warm island lerps G and B
	toward a tint with R held at 1; this one holds B at 1 and lerps R and G, so
	the frame goes cold without the blue channel ever clipping. Same arithmetic,
	opposite corner of the cube.
]]
local TINT = Color3.fromRGB(232, 240, 255)

local function applyBlend(a: number)
	grade.Brightness = 0.02 * a
	grade.Contrast = 0.05 * a
	grade.Saturation = -0.08 * a
	grade.TintColor = Color3.new(
		1 - (1 - 0.91) * a,
		1 - (1 - 0.94) * a,
		1
	)

	-- The storm's wash toward white rides on top of the island's ambient, in the
	-- same write: island first, then storm over it, both scaled so that off the
	-- island (a = 0) every term collapses to HOME.
	local out = HOME_OUT:Lerp(PENGUIN_OUT, a)
	if storm > 0 then
		out = out:Lerp(STORM_OUT, storm * a)
	end
	Lighting.OutdoorAmbient = out
	Lighting.Ambient = HOME_AMB:Lerp(PENGUIN_AMB, a)

	if atmo and HOME_ATMO then
		-- The air THICKENS during a blizzard, which is the one atmospheric change
		-- here that is literally true: there is a great deal of snow between the
		-- player and everything else. Haze does most of it; density only a little,
		-- because density is what hides the ground under the player's own feet.
		atmo.Density = HOME_ATMO.Density + (PENGUIN_ATMO.Density - HOME_ATMO.Density) * a
			+ STORM_DENSITY * storm * a
		atmo.Haze = HOME_ATMO.Haze + (PENGUIN_ATMO.Haze - HOME_ATMO.Haze) * a
			+ STORM_HAZE * storm * a
		atmo.Glare = HOME_ATMO.Glare + (PENGUIN_ATMO.Glare - HOME_ATMO.Glare) * a
		atmo.Color = HOME_ATMO.Color:Lerp(PENGUIN_ATMO.Color, a)
		atmo.Decay = HOME_ATMO.Decay:Lerp(PENGUIN_ATMO.Decay, a)
	end

	Terrain.WaterColor = HOME_WATER.Color:Lerp(PENGUIN_WATER.Color, a)
	Terrain.WaterTransparency = HOME_WATER.Transparency
		+ (PENGUIN_WATER.Transparency - HOME_WATER.Transparency) * a
	Terrain.WaterReflectance = HOME_WATER.Reflectance
		+ (PENGUIN_WATER.Reflectance - HOME_WATER.Reflectance) * a
	Terrain.WaterWaveSize = HOME_WATER.WaveSize
		+ (PENGUIN_WATER.WaveSize - HOME_WATER.WaveSize) * a
	Terrain.WaterWaveSpeed = HOME_WATER.WaveSpeed
		+ (PENGUIN_WATER.WaveSpeed - HOME_WATER.WaveSpeed) * a

	player:SetAttribute(CLOCK_ATTR, HOUR_HOME + (HOUR_PENGUIN - HOUR_HOME) * a)

	everTouched = true
end

--[[
	RE-READ THE HOME VALUES WHILE THEY ARE STILL DEMONSTRABLY THE HOME VALUES.

	applyLook runs on the SERVER at boot and its water and lighting writes have to
	replicate down before the snapshot above is worth anything -- and
	StarterPlayerScripts do not wait for that. So the snapshot is refreshed on the
	zone poll for as long as this file has never written a shared value.

	TWO GUARDS, because `everTouched` on its own is not the bound it looks like.
	It only becomes true on this file's first PENGUIN write, so until the player
	has been north at least once it would fire every 0.4 seconds WHEREVER they are
	-- including in the dunes, the vault, the cove and the ash isle, all of which
	are actively writing the very properties being sampled. Sampled there,
	HOME_OUT gets captured as somebody else's graded ambient and this file's own
	final applyBlend(0) stamps it onto the beach permanently.

	  GUARD 1, WHERE.  Sample only where nothing is graded: the spawn beach, or
	    open water between islands. Never inside another island's zone.
	  GUARD 2, WHEN.   A ferry arrival lands the player on a shore while the
	    island they just left is still seconds into its fade out, so guard 1 alone
	    is not enough. The sample has to be STILL: two consecutive polls 0.4s apart
	    have to agree before it is committed. Anything mid-lerp is writing every
	    frame and cannot produce two identical samples.
]]
local BEACH_ID = 1
local homeSample = nil

local function snapshotHome()
	return {
		density = atmo and atmo.Density or 0,
		haze = atmo and atmo.Haze or 0,
		glare = atmo and atmo.Glare or 0,
		atmoColour = atmo and atmo.Color or Color3.new(),
		atmoDecay = atmo and atmo.Decay or Color3.new(),
		out = Lighting.OutdoorAmbient,
		amb = Lighting.Ambient,
		wColour = Terrain.WaterColor,
		wTrans = Terrain.WaterTransparency,
		wRefl = Terrain.WaterReflectance,
		wSize = Terrain.WaterWaveSize,
		wSpeed = Terrain.WaterWaveSpeed,
	}
end

local function sameSample(a, b): boolean
	if not (a and b) then
		return false
	end
	for k, v in pairs(a) do
		local w = b[k]
		if typeof(v) == "Color3" then
			if math.abs(v.R - w.R) > 1e-4 or math.abs(v.G - w.G) > 1e-4 or math.abs(v.B - w.B) > 1e-4 then
				return false
			end
		elseif math.abs(v - w) > 1e-4 then
			return false
		end
	end
	return true
end

local function recaptureHome(zone)
	if everTouched then
		return
	end
	-- GUARD 1: nowhere that another island's client script is grading.
	if zone ~= nil and zone.id ~= BEACH_ID then
		homeSample = nil
		return
	end
	-- GUARD 2: two identical polls in a row.
	local now = snapshotHome()
	if not sameSample(homeSample, now) then
		homeSample = now
		return
	end
	HOME_OUT = now.out
	HOME_AMB = now.amb
	if atmo and HOME_ATMO then
		HOME_ATMO.Density, HOME_ATMO.Haze, HOME_ATMO.Glare = now.density, now.haze, now.glare
		HOME_ATMO.Color, HOME_ATMO.Decay = now.atmoColour, now.atmoDecay
	end
	HOME_WATER.Color = now.wColour
	HOME_WATER.Transparency = now.wTrans
	HOME_WATER.Reflectance = now.wRefl
	HOME_WATER.WaveSize = now.wSize
	HOME_WATER.WaveSpeed = now.wSpeed
end

----------------------------------------------------------------
-- THE SNOWFALL
----------------------------------------------------------------
--[[
	ONE EMITTER, PARKED UPWIND AND OVERHEAD, FOLLOWING THE PLAYER.

	The island is the biggest yet and there is no way to have falling snow
	everywhere on it: covering that area with static emitters is hundreds of
	them, nearly all of them out of shot. One 90-stud slab that moves with the
	player puts the whole budget where the camera is, and because it sits
	forty studs UPWIND, the flakes it sheds have already drifted into the frame
	by the time they reach eye level rather than appearing out of nothing above
	the player's head.

	NOT the same thing as ash, and the difference is in the SIZE ramp and the
	speed: ash burns out, so its flakes shrink to nothing; snow does not, so
	these swell a little as they fall (a flake catching the light) and only
	shrink at the very end where they fade out. They fall SLOWER than ash --
	3-8 against 5-11 -- with less lift against gravity, because a snowflake is
	heavier than a cinder and a slow fall is what reads as cold and still. The
	wind term is smaller too: this is a fall, not a drift, until the blizzard
	turns the rate up sixfold and the same slow flakes become a wall.
]]
local WIND = Vector3.new(0.62, 0, -0.78).Unit   -- off the frozen sea, across the rookery
local DRIFT_BACK = 40
local DRIFT_UP = 32
local DRIFT_RATE = 44

local driftPart = Instance.new("Part")
driftPart.Name = "SnowDrift"
driftPart.Size = Vector3.new(90, 1, 90)
driftPart.Transparency = 1
driftPart.Anchored = true
driftPart.CanCollide = false
driftPart.CanQuery = false
driftPart.CanTouch = false
driftPart.CastShadow = false
driftPart.Parent = fx

local driftEmit = Instance.new("ParticleEmitter")
driftEmit.Name = "Snow"
driftEmit.Texture = "rbxassetid://243098098"
driftEmit.Color = ColorSequence.new(SNOW_WHITE, SNOW_SHADE)
driftEmit.LightEmission = 0.2
driftEmit.LightInfluence = 1
driftEmit.Size = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.35),
	NumberSequenceKeypoint.new(0.6, 0.45),
	NumberSequenceKeypoint.new(1, 0.2),
})
driftEmit.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.1, 0.15),
	NumberSequenceKeypoint.new(0.85, 0.25),
	NumberSequenceKeypoint.new(1, 1),
})
driftEmit.Lifetime = NumberRange.new(6, 10)
driftEmit.Rate = 0
driftEmit.Speed = NumberRange.new(3, 8)
driftEmit.SpreadAngle = Vector2.new(30, 30)
driftEmit.Rotation = NumberRange.new(0, 360)
driftEmit.RotSpeed = NumberRange.new(-60, 60)
driftEmit.Acceleration = WIND * 4 - Vector3.new(0, 4, 0)
driftEmit.EmissionDirection = Enum.NormalId.Bottom
driftEmit.Parent = driftPart

-- The one place the emitter rate is written, so the blend and the storm
-- cannot disagree about it. Recomputed from scratch each call.
local function refreshRates()
	driftEmit.Rate = DRIFT_RATE * blend * (1 + STORM_SNOW * storm)
end

----------------------------------------------------------------
-- THE AURORA
----------------------------------------------------------------
--[[
	THE BUILDER HANGS THE RIBBONS; THIS FILE ONLY BREATHES THROUGH THEM.

	Each ribbon is a Neon part named "Aurora" somewhere under the island's Sky
	folder, and each carries an optional "Phase" attribute so neighbouring
	ribbons are never in step. Per frame, while the player is on the island,
	every ribbon's Colour is slid between the green end and the violet end of
	the palette on a slow sine -- 0.35 rad/s is a full breath every eighteen
	seconds, which is slow enough to be noticed only if you watch for it, and
	that is what an aurora does.

	TRANSPARENCY IS NEVER TOUCHED. Neon above Transparency 0 renders near-black
	under this place's lighting (Island3_Client's note), so a ribbon that faded
	would go from glowing to a black streak across the sky. The fade is faked
	by the colour swing alone; the darker violet end reads as the ribbon
	thinning out.

	RE-RESOLVED ON THE POLL, NOT CACHED ONCE. Under streaming the Sky folder may
	not exist when this file boots, may arrive later, and may be a fresh
	instance after a rebuild. So the poll re-finds Island5 and its Sky child
	every 0.4 s and only re-walks the descendants when the folder identity or
	its child count changes -- a walk every poll would be the wrong cost on a
	folder that never changes for a session.
]]
local auroraParts = {}          -- { { part = BasePart, phase = number }, ... }
local auroraFolder = nil        -- the Sky folder the list was built from
local auroraCount = -1          -- its child count at that time

local function refreshAurora()
	local island = workspace:FindFirstChild("Island5")
	local sky = island and island:FindFirstChild("Sky") or nil
	if sky and not sky:IsA("Folder") then
		sky = nil
	end
	local count = sky and #sky:GetChildren() or -1
	if sky == auroraFolder and count == auroraCount then
		return
	end
	auroraFolder = sky
	auroraCount = count
	table.clear(auroraParts)
	if not sky then
		return
	end
	for _, d in ipairs(sky:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == "Aurora" and d.Material == Enum.Material.Neon then
			local phase = d:GetAttribute("Phase")
			if type(phase) ~= "number" then
				phase = 0
			end
			table.insert(auroraParts, { part = d, phase = phase })
		end
	end
end

local function tickAurora(t: number)
	for _, e in ipairs(auroraParts) do
		local part = e.part
		if part.Parent then
			part.Color = AURORA_A:Lerp(AURORA_B, 0.5 + 0.5 * math.sin(t * 0.35 + e.phase))
		end
	end
end

----------------------------------------------------------------
-- THE COLONY
----------------------------------------------------------------
--[[
	SIXTY ANCHORED BIRDS, ANIMATED ON THIS MACHINE ONLY.

	Each penguin is a server Model: an invisible anchored "Root" as its
	PrimaryPart, a textured "Body" MeshPart, whatever accessories the builder
	gave it, and two attributes -- Bob (how much this bird moves, default 1)
	and Phase (so the rookery does not bob in unison). The server never moves
	them. This file captures each bird's resting CFrame the first time it sees
	it and then, every frame the player is on the island, PivotTo()s the model
	to rest * bob * waddle * nod. Anchored parts moved on the client stay
	moved on the client and nothing replicates, so this costs the network
	nothing whether there are six birds or six hundred.

	THREE MOTIONS, and each is a sine so the birds never snap:
	  bob      the whole bird rising and settling, 0.12 studs at 2.2 rad/s, the
	           breathing shuffle of a bird standing in the cold
	  waddle   a roll about the facing axis, 0.06 rad at 3.1 rad/s, the side
	           to side shift of weight from foot to foot
	  nod      a one-shot hop-and-bow when the player pets it: `nod` is set to 1
	           on the prompt and decays at 1.6/s; the hop is 0.9 studs at the
	           peak of sin(nod * pi) and the bow is 0.35 rad forward, both back
	           to nothing by the time nod reaches zero -- so a bird cannot be
	           left mid-hop.

	ONLY BIRDS WITHIN 180 STUDS ARE MOVED. A PivotTo on a six-part model is not
	free, and a bird two hundred studs away is two pixels; those are left at
	rest, and a bird that WAS moving and drifts out of range is put back at rest
	once, so the range boundary never freezes one mid-bob.

	THE CACHE IS KEYED BY MODEL. Under streaming the Penguins folder arrives and
	leaves, and a bird that streams out and back is a new instance with the same
	name; keying on the instance means the resting CFrame is captured from the
	fresh copy rather than stamped from a stale one. Entries whose model has
	lost its Parent are dropped on the poll.
]]
local PENGUIN_RANGE = 180
local BOB_AMP = 0.12
local BOB_RATE = 2.2
local WADDLE_AMP = 0.06
local WADDLE_RATE = 3.1
local NOD_DECAY = 1.6
local HOP_AMP = 0.9
local BOW_AMP = 0.35

--[[
	AND THEY ROAM (2026-09-12). A colony that stands still is a row of pins.
	Every bird with a Roam attribute (the builder sets it per district: a few
	studs at the landing, a dozen on the colony's strand) walks a random path
	round its resting spot in LEGS of ROAM_SEG seconds -- the first ROAM_WALK
	of each leg waddling from one point to the next, the rest standing where it
	got to. The points are drawn from a generator seeded by the BIRD and the
	LEG NUMBER, and the leg number comes off the server clock, so every client
	draws the same path for the same bird at the same moment without a byte of
	replication: two players see the same penguin arrive at the same spot.

	Walking is the standing waddle turned up -- a faster, wider roll and a
	little foot-to-foot bounce -- and the bird faces the way it is going, with
	a short blend at the start of each leg so it turns rather than snaps. The
	prompt travels with the model (PivotTo moves every descendant), and the
	server widened each prompt's reach by the roam radius so a pet at the far
	end of a walk still counts.
]]
local ROAM_SEG = 7.0            -- seconds per leg: a walk and then a stand
local ROAM_WALK = 0.58          -- the fraction of a leg spent walking
local ROAM_ROCK_RATE = 7.5      -- the waddle while walking, rad/s
local ROAM_ROCK_AMP = 0.14      -- and its roll
local ROAM_STEP = 0.07          -- foot-to-foot bounce while walking, studs
local ROAM_TURN = 0.08          -- the fraction of a leg spent turning to face it

local birds = {}        -- [Model] = { base = CFrame, bob, phase, nod, moved, body, roam, seed, leg, p0, p1, dir, prevDir }
local birdsFolder = nil

local function smoothstep(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

-- Where a bird stands at the start of leg k: its resting spot plus an offset
-- drawn from a generator seeded by the bird and the leg. Pure in X and Z, so
-- every client and every call agrees; the height is read off the terrain
-- under the point (once per leg, not per frame) so a bird stood on a snow
-- mound walks DOWN the mound instead of floating off it. Terrain only, water
-- ignored: the fishing birds stand on the sheet and the sheet is Ice.
local legGround = RaycastParams.new()
legGround.FilterType = Enum.RaycastFilterType.Include
legGround.FilterDescendantsInstances = { workspace.Terrain }
legGround.IgnoreWater = true

local function legPoint(e, k: number): Vector3
	local r = Random.new(e.seed * 7919 + k * 104729)
	local dist = e.roam * math.sqrt(r:NextNumber(0.12, 1))
	local ang = r:NextNumber(0, math.pi * 2)
	local home = e.base.Position
	local x, z = home.X + math.cos(ang) * dist, home.Z + math.sin(ang) * dist
	local y = home.Y
	local hit = workspace:Raycast(Vector3.new(x, home.Y + 24, z), Vector3.new(0, -60, 0), legGround)
	if hit then
		-- the builder stood every bird a hair above the ground; keep that
		y = hit.Position.Y + 0.02
	end
	return Vector3.new(x, y, z)
end

-- Adds a bird to the cache if it is one and is not already there. Returns the
-- entry, or nil if the model does not have a Root to pivot from yet (it may be
-- still streaming in; the next poll will see it whole).
local function adoptBird(model: Instance)
	if not model:IsA("Model") then
		return nil
	end
	local e = birds[model]
	if e then
		return e
	end
	local root = model.PrimaryPart or model:FindFirstChild("Root")
	if not (root and root:IsA("BasePart")) then
		return nil
	end
	local bob = model:GetAttribute("Bob")
	if type(bob) ~= "number" then
		bob = 1
	end
	local phase = model:GetAttribute("Phase")
	if type(phase) ~= "number" then
		phase = 0
	end
	local roam = model:GetAttribute("Roam")
	if type(roam) ~= "number" or roam < 0.5 then
		roam = 0
	end
	local seed = model:GetAttribute("Seed")
	if type(seed) ~= "number" then
		seed = math.floor(phase * 100 + 0.5)
	end
	local body = model:FindFirstChild("Body")
	e = {
		base = root.CFrame,
		bob = bob,
		phase = phase,
		nod = 0,
		moved = false,
		body = (body and body:IsA("BasePart")) and body or root,
		roam = roam,
		seed = seed,
		leg = nil,
		p0 = nil,
		p1 = nil,
		dir = root.CFrame.LookVector,
		prevDir = root.CFrame.LookVector,
	}
	birds[model] = e
	return e
end

local function refreshBirds()
	-- Drop anything that streamed out or was destroyed.
	for model, _ in pairs(birds) do
		if model.Parent == nil then
			birds[model] = nil
		end
	end
	local island = workspace:FindFirstChild("Island5")
	local folder = island and island:FindFirstChild("Penguins") or nil
	birdsFolder = folder
	if not folder then
		return
	end
	for _, child in ipairs(folder:GetChildren()) do
		adoptBird(child)
	end
end

-- Every cached bird back to its resting frame, once. Called on the way off the
-- island so nobody sails away leaving the rookery frozen mid-hop.
local function restBirds()
	for model, e in pairs(birds) do
		if e.moved and model.Parent then
			model:PivotTo(e.base)
			e.moved = false
		end
	end
end

local function tickBirds(dt: number, t: number, here: Vector3)
	for model, e in pairs(birds) do
		if model.Parent == nil then
			birds[model] = nil
		else
			-- The nod decays whether or not the bird is in range, so a petted bird
			-- that the player immediately walks away from does not keep its hop
			-- banked for the next visit.
			if e.nod > 0 then
				e.nod = math.max(0, e.nod - dt * NOD_DECAY)
			end
			local basePos = e.base.Position
			local d = (Vector3.new(basePos.X, 0, basePos.Z) - Vector3.new(here.X, 0, here.Z)).Magnitude
			if d <= PENGUIN_RANGE then
				local y = e.bob * BOB_AMP * math.sin(t * BOB_RATE + e.phase)
				local roll = WADDLE_AMP * math.sin(t * WADDLE_RATE + e.phase)
				local hop = 0
				local tilt = 0
				if e.nod > 0 then
					local s = math.sin(e.nod * math.pi)
					hop = HOP_AMP * s
					tilt = BOW_AMP * s
				end
				-- Where the bird is on its walk, if it has one.
				local frame = e.base
				if e.roam > 0 then
					local k = math.floor(t / ROAM_SEG)
					if k ~= e.leg then
						e.leg = k
						e.p0 = legPoint(e, k)
						e.p1 = legPoint(e, k + 1)
						e.prevDir = e.dir
						local step = e.p1 - e.p0
						if step.Magnitude > 0.05 then
							e.dir = step.Unit
						end
					end
					local u = (t - k * ROAM_SEG) / ROAM_SEG
					local walking = u < ROAM_WALK
					local along = walking and smoothstep(u / ROAM_WALK) or 1
					local pos = e.p0:Lerp(e.p1, along)
					-- a short turn into the new leg rather than a snap
					local face = e.dir
					if u < ROAM_TURN then
						local blended = e.prevDir:Lerp(e.dir, smoothstep(u / ROAM_TURN))
						if blended.Magnitude > 0.05 then
							face = blended.Unit
						end
					end
					frame = CFrame.lookAt(pos, pos + face)
					if walking then
						-- the waddle turned up, and a foot-to-foot bounce
						roll = ROAM_ROCK_AMP * math.sin(t * ROAM_ROCK_RATE + e.phase)
						y += ROAM_STEP * math.abs(math.sin(t * ROAM_ROCK_RATE * 0.5 + e.phase))
					end
				end
				-- The model faces its own -Z, so a NEGATIVE pitch about X drops the
				-- beak: that is the bow. Positive would throw the head back.
				model:PivotTo(frame * CFrame.new(0, y + hop, 0) * CFrame.Angles(-tilt, 0, roll))
				e.moved = true
			elseif e.moved then
				model:PivotTo(e.base)
				e.moved = false
			end
		end
	end
end

--[[
	PETTING. The builder puts a ProximityPrompt named "PenguinPrompt" on each
	bird (on the Body or an attachment under it); the server may or may not do
	anything with it. Here it only has to find which bird it belongs to -- walk
	up from the prompt until a cached Model is found -- set that bird's nod to
	1, and honk.

	The honk goes through AudioKit so it sits in the same group as every other
	effect and obeys the toggle; the "PenguinHonk" slot may not exist in
	AudioKit yet when this lands, and AudioKit raises on an unknown name, so
	the call is wrapped. A missing honk is a silent pet, never an error in the
	output.
]]
local AudioKit = nil
local audioKitTried = false

local function getAudioKit()
	if audioKitTried then
		return AudioKit
	end
	audioKitTried = true
	pcall(function()
		local mods = ReplicatedStorage:FindFirstChild("Modules")
		local mod = mods and mods:FindFirstChild("AudioKit")
		if mod and mod:IsA("ModuleScript") then
			AudioKit = require(mod)
		end
	end)
	return AudioKit
end

local function birdFromPrompt(prompt: Instance)
	local node = prompt.Parent
	while node and node ~= workspace do
		if node:IsA("Model") then
			local e = birds[node] or adoptBird(node)
			if e then
				return node, e
			end
		end
		node = node.Parent
	end
	return nil, nil
end

ProximityPromptService.PromptTriggered:Connect(function(prompt, plr)
	if plr ~= player or prompt.Name ~= "PenguinPrompt" then
		return
	end
	local model, e = birdFromPrompt(prompt)
	if not (model and e) then
		return
	end
	e.nod = 1
	local kit = getAudioKit()
	if kit and type(kit.play) == "function" then
		pcall(function()
			kit.play("PenguinHonk", e.body)
		end)
	end
end)

----------------------------------------------------------------
-- THE BLIZZARD
----------------------------------------------------------------
--[[
	THE RESET PICTURE. Every island shows the player its field coming back --
	the beach's tide, the cove's hanami gust, the ash isle's eruption -- and
	this island's is a blizzard: fourteen seconds where the wind gets up, the
	snow goes from a fall to a wall, the horizon closes in and the camera
	shivers.

	It is the cove's GUST shape, not the ash isle's flash: a second 0..1 factor
	(`storm`) that applyBlend folds in on top of `a`. Two seconds up, eight
	seconds held, four seconds down. The ease out is twice the ease in because
	a storm arriving is an event and a storm leaving is a relief, and a relief
	that snaps off feels like a bug.

	It is triggered by the same Net message every other reset picture keys on
	-- action "Tide", islandId this island's -- and by a LocalPlayer attribute
	for testing from the command bar:

		game.Players.LocalPlayer:SetAttribute("PenguinTestStorm", os.clock())

	An attribute rather than a remote or a global: it is client-only, it cannot
	be fired by anybody else's machine, and it leaves nothing behind in the
	datamodel that a player could find.
]]
local STORM_LEN = 14
local STORM_IN = 2
local STORM_OUT_LEN = 4
local stormAt = nil     -- os.clock() at the start, nil when there is no storm

local function startStorm()
	stormAt = os.clock()
	-- The gust of wind at the front of it. Through AudioKit's "Wave" slot rather
	-- than a new id: pitched up and loud, the beach's wave take is a squall.
	local kit = getAudioKit()
	if kit and type(kit.play) == "function" then
		pcall(function()
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			kit.play("Wave", hrp, 0.9, 1.35)
		end)
	end
end

-- Moves `storm` for this frame. Returns true while the storm still has
-- anything to say; on the frame it ends it leaves storm at exactly 0.
local function tickStorm(now: number): boolean
	if not stormAt then
		storm = 0
		return false
	end
	local t = now - stormAt
	if t >= STORM_LEN then
		stormAt = nil
		storm = 0
		return false
	end
	if t < STORM_IN then
		storm = t / STORM_IN
	elseif t < STORM_LEN - STORM_OUT_LEN then
		storm = 1
	else
		storm = (STORM_LEN - t) / STORM_OUT_LEN
	end
	-- Eased rather than linear at both ends, so the first and last frames of
	-- snow do not arrive as a step.
	storm = storm * storm * (3 - 2 * storm)
	return true
end

--[[
	THE SHIVER, through Humanoid.CameraOffset rather than by taking the camera:
	the default camera module applies that for us, so nothing here has to own
	CameraType, and a player who walks out of it mid-storm simply stops being
	shaken.

	IT IS A SHARED CHANNEL AND FerryClient IS THE OTHER WRITER -- it rides the
	boat on the swell through the same property and zeroes it when the crossing
	ends. So this must DECAY TO ZERO and never park a value: the amplitude is
	the storm factor times the island blend, both of which go to zero on their
	own, and the moment the product is below noise the offset is written to
	exactly zero once and then left alone.

	0.22 studs at the peak. The ash isle's note records that a quarter of a stud
	is already a lot of movement and its eruption runs 0.7 on the field; this is
	a shiver from cold, not the ground moving, and it runs for fourteen seconds
	rather than six. Kept small enough to be felt and forgotten.
]]
local SHAKE_AMP = 0.22

local function tickShake(now: number)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	local amp = SHAKE_AMP * storm * blend
	if amp < 0.002 then
		if hum.CameraOffset.Magnitude > 0.001 then
			hum.CameraOffset = Vector3.zero
		end
		return
	end
	hum.CameraOffset = Vector3.new(
		(math.sin(now * 37.1) * 0.6 + math.sin(now * 5.3) * 0.4) * amp,
		(math.sin(now * 29.7) * 0.6 + math.sin(now * 4.1) * 0.4) * amp * 0.7,
		0)
end

local Net = ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Net")
Net.OnClientEvent:Connect(function(action, islandId)
	if action == "Tide" and islandId == PENGUIN.id then
		startStorm()
	end
end)
player:GetAttributeChangedSignal("PenguinTestStorm"):Connect(startStorm)

----------------------------------------------------------------
-- Drive it
--
-- One connection, and everything inside it is behind the blend value: off the
-- island that is zero, and this costs a circle check every 0.4s and nothing
-- else. No emitter ticks, no bird pivots, no aurora writes where nobody can
-- see them.
----------------------------------------------------------------
local FADE = 2.4

local onIsland = false
local zoneTimer = 0
local ambienceOn = false

applyBlend(0)
refreshRates()
-- applyBlend sets everTouched, which is only meant to mean "has written a
-- PENGUIN value". Cleared straight back, so the home snapshot can still be
-- refreshed once replication settles. The clock attribute written by that call
-- is 12, which is LightingLock's own default, so it changes nothing for a
-- player who never comes here.
everTouched = false

RunService.Heartbeat:Connect(function(dt)
	zoneTimer -= dt
	if zoneTimer <= 0 then
		zoneTimer = 0.4
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local zone = hrp and Config.zoneAt(hrp.Position) or nil
		onIsland = (zone ~= nil and zone.id == PENGUIN.id)
		if not onIsland then
			recaptureHome(zone)
		end
		-- The sky and the colony are re-resolved on the same poll: both may be
		-- nil under streaming, both may be fresh instances after a rebuild, and
		-- neither is worth a per-frame FindFirstChild.
		if onIsland or blend > 0.01 then
			refreshAurora()
			refreshBirds()
		end
	end

	local target = onIsland and 1 or 0
	if blend ~= target then
		blend += math.clamp(target - blend, -dt / FADE, dt / FADE)
		-- Snapping the last sliver matters more than it looks: it is what guarantees
		-- a FINAL write at exactly 0, which is the write that hands the beach back
		-- its own water, atmosphere, ambient and clock. Without it the lerp
		-- asymptotes and the sea stays very slightly arctic forever.
		if math.abs(blend - target) < 0.002 then
			blend = target
		end
		applyBlend(blend)

		-- Volume tracks the blend, but the DECODER only runs while there is
		-- something to hear.
		local audible = blend > 0.01
		if audible ~= ambienceOn then
			ambienceOn = audible
			for _, s in ipairs(ambienceSounds) do
				if audible then
					-- Resume, not Play, once it has been started: Play restarts the loop
					-- from zero, so every arrival would begin on the same wind.
					if s:GetAttribute("Started") then
						s:Resume()
					else
						s:SetAttribute("Started", true)
						s:Play()
					end
				else
					s:Pause()
				end
			end
			-- Same crossing, other direction: the rookery goes back to rest as
			-- the island fades out, so nothing is left mid-hop behind the player.
			if not audible then
				restBirds()
			end
		end
		for _, s in ipairs(ambienceSounds) do
			s.Volume = s:GetAttribute("Peak") * blend
		end
		refreshRates()
	end

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local now = os.clock()

	--[[
		THE STORM AND THE SHIVER TICK AHEAD OF THE BLEND GATE, not behind it.

		Everything else in this loop is allowed to idle when the player is not on
		the island; these are not, because they own two things that must be put
		back. The storm holds `storm`, which is folded into the atmosphere and the
		ambient, and the shiver holds Humanoid.CameraOffset, which FerryClient also
		writes. Skipped on the frame somebody sails away mid-blizzard, both would
		be parked at whatever value they happened to have -- a permanently hazed
		sky and a permanently offset camera, for the rest of the session.

		applyBlend is re-called every frame the storm runs because the storm factor
		moves every frame. It recomputes from scratch, so this cannot accumulate.
		It is only re-called while the blend is above noise: at a = 0 every storm
		term is multiplied to nothing and the drive block above has already made
		the final home write, which must not be repeated (it would set
		everTouched on a client that has never actually been here).
	]]
	if stormAt then
		local alive = tickStorm(now)
		if blend > 0.01 then
			applyBlend(blend)
			refreshRates()
		elseif not alive then
			refreshRates()
		end
	end
	tickShake(now)

	if blend <= 0.01 or not hrp then
		return
	end
	local here = hrp.Position

	-- The snow slab, parked upwind and overhead.
	driftPart.CFrame = CFrame.new(here - WIND * DRIFT_BACK + Vector3.new(0, DRIFT_UP, 0))

	-- The sky breathes and the colony shuffles, on the server clock so two
	-- players standing together see the same ribbon at the same colour and the
	-- same bird on the same foot.
	local t = workspace:GetServerTimeNow()
	tickAurora(t)
	tickBirds(dt, t, here)
end)

print("[Penguin] client ready -- cold grade, still sea, snowfall, aurora, the colony and the blizzard armed")
