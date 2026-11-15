--[[
	Island4_Client  --  StarterPlayer.StarterPlayerScripts.Island4_Client

	Everything about Ashfall Isle that MOVES or is private to one player. The
	island itself -- terrain, volcano, camp, stair, flows -- is built once on the
	server by Island4Builder; this is the half that would cost bandwidth or leak
	state if the server did it.

		the ash grade    Ashfall is a late-afternoon island under a dirty sky and
		                 the beach is noon under a clean one. Lighting is ONE
		                 shared object, but a client's writes to it do not
		                 replicate, so each player gets the hour and the grade for
		                 the island THEY are standing on. Same trick the dunes'
		                 heat grade and the cove's golden hour already run on.
		the sea          Terrain.WaterColor and friends are global PROPERTIES, not
		                 per-region ones. Written here they stay on this machine,
		                 which is the only way this island gets a cold slate sea
		                 without turning the beach's turquoise grey for everybody.
		ashfall          the thing the island is named for: a slow fall of grey
		                 flakes that follows the player, so there is always
		                 something in shot wherever they stand.
		embers           the same idea running upward, and only near the mountain.
		the plume        a smoke column standing off the crater, bound to the lava
		                 lake the builder made rather than to a typed-in position.

	All of it idles when the player is not on the island: the per-frame work is
	behind a zone test that costs one distance check every 0.4 seconds.

	WHAT IS NOT HERE, AND WHY
	-------------------------
	THE TORCHES, THE POOLS AND THE FUMAROLES. Every one of those carries its own
	ParticleEmitter, and they are on the SERVER because an emitter is a saved
	instance rather than a per-frame cost -- it replicates once and then runs on
	its own. What is client-side here is only what has to FOLLOW something (the
	ashfall follows the player) or what would otherwise be two hundred emitters
	instead of one (the plume).

	THE SKY. CTB_Server.applyLook destroys every Sky it did not make and asserts
	six tropical faces, server side, once at boot. The clock, the grade and the
	atmosphere below carry the weather on their own; if the sky itself ever has to
	change it wants to be a swap-and-restore pair captured the way HOME_ATMO is,
	not a new child left lying in Lighting.

	GeographicLatitude, for the reason Island3_Client records: it moves the SUNSET
	TIME as well as the elevation, and this island is already parked at 16.2.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local player = Players.LocalPlayer
local Config = require(ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Config"))
local Motion = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Motion"))

local ASH = Config.island(5)
local GROUND = ASH.cleanY                -- 3.0, shared by every field in the game

----------------------------------------------------------------
-- Folders and shared raycast params
----------------------------------------------------------------
-- Destroyed and rebuilt, so re-running this script in a live session (which is
-- what a Studio script reload does) leaves one set of emitters rather than two
-- stacked ones at double the rate.
local old = workspace:FindFirstChild("Island4_FX")
if old then
	old:Destroy()
end
local fx = Instance.new("Folder")
fx.Name = "Island4_FX"
fx.Parent = workspace

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace.Terrain }
groundParams.IgnoreWater = true

----------------------------------------------------------------
-- THE PALETTE
--
-- One table, so the grade, the sea, the ash and the embers are demonstrably the
-- same set of colours rather than four hand-picked greys that nearly match.
-- Island4Props exports its own PALETTE for the geometry; these are the LIGHT
-- values, which are a different problem -- a part colour is read off the part, a
-- particle colour is read against the sky behind it.
----------------------------------------------------------------
local ASH_PALE = Color3.fromRGB(206, 200, 196)
local ASH_GREY = Color3.fromRGB(128, 122, 124)
local EMBER = Color3.fromRGB(255, 122, 42)
local EMBER_DEEP = Color3.fromRGB(198, 56, 24)

----------------------------------------------------------------
-- Ambience
--
-- Routed through the BeachSFX SoundGroup, which is what the Settings panel's
-- Sound Effects toggle already drives -- so switching effects off silences this
-- island too, with no extra wiring. That line is NOT optional: AudioKit's adopt()
-- safety net only sweeps workspace descendants, and these live under
-- SoundService, so an ungrouped Sound here would ignore the toggle entirely.
--
-- EVERY ID BELOW WAS LOADED IN THIS PLACE AND ITS TimeLength READ BACK BEFORE IT
-- WAS WRITTEN DOWN. A Sound with an id that does not resolve does not throw --
-- it sits there playing nothing -- and silence looks exactly like a feature
-- nobody got to yet. All four are ProSoundEffects, Roblox's own licensed
-- library, so they cannot be moderated out from under the game.
--
-- Measured lengths, in the order they appear below:
--   9112795583  122.50s  Hollow Rumble, deep steady drone, dark, loop
--   9112865013   56.92s  Middle of Ocean Ambience, water movements, waves, loop
--   9120570701   31.51s  Water Lap, small waves, active, slosh
--   9125615158   36.01s  Rumble and roar, bubbling magma, swirling air
--
-- Preloaded ONE AT A TIME when they were checked. Batching them through a single
-- ContentProvider:PreloadAsync reports slow ones as unloaded; do not read a batch
-- result as a verdict.
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
-- that never sails west never decodes four looping tracks for the session. The
-- cove's note records what the other way costs across the whole place.
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
	THE RUMBLE IS THE BED AND IT IS THE LOUDEST THING HERE, which is the opposite
	of how the other two destinations are mixed. The cove leads on surf and the
	dunes on wind; on this island the mountain is the subject, and a volcano you
	cannot hear from the beach is scenery. Run slightly slow so it sits under
	everything rather than droning over it.
]]
ambience("rbxassetid://9112795583", 0.82, 0.16)

-- Two sea layers at different lengths, exactly as the cove does with its surf
-- and the dunes with their wind. 56.92s against 31.51s never line back up inside
-- a session, so the two drift against each other and the repeat stops being
-- audible.
ambience("rbxassetid://9112865013", 0.86, 0.085)
ambience("rbxassetid://9120570701", 0.92, 0.10)

-- The vents. Quietest thing in the mix by a distance and deliberately so: it is
-- a texture on top of the rumble rather than a sound in its own right, and at
-- full level a bubbling-magma take reads as a swimming pool.
ambience("rbxassetid://9125615158", 0.7, 0.045)

----------------------------------------------------------------
-- THE ASH GRADE
--
-- Its OWN ColorCorrectionEffect rather than pushing the shared one around:
-- CTB_Server's applyLook owns "ColorCorrection", and two writers on one effect is
-- how you get a look that depends on boot order. Neutral at home, so on the
-- beach this is a no-op.
----------------------------------------------------------------
local grade = Instance.new("ColorCorrectionEffect")
grade.Name = "AshfallGrade"
grade.Brightness = 0
grade.Contrast = 0
grade.Saturation = 0
grade.TintColor = Color3.new(1, 1, 1)
grade.Parent = Lighting

-- There is exactly one Atmosphere in this place and CTB_Server's `ensure`
-- destroys duplicates of anything it owns. See Island3_Client's note for the bug
-- that rule exists to prevent: two Atmospheres named the same, every script
-- writing the first and the renderer drawing the second.
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

--[[
	AMBIENT IS WHAT MAKES THE BLACK SAND A SURFACE INSTEAD OF A HOLE.

	This island's ground is tinted (56,50,54). At 16:12 the sun is low, so every
	north-facing surface out here -- the shaded half of every boulder, the inside
	of the camp, the whole north flank of the cone -- is lit by ambient alone, and
	under the beach's cool grey ambient all of it renders as one flat black shape
	with no modelling in it at all. That is the same failure the dunes hit with
	their pyramid and the cove with its torii, at the dark end instead of the pale
	one.

	So OUTDOOR goes warm and, unusually, goes UP rather than down: brighter
	ambient on a dark island is what buys back the shading. And it is warm because
	it is true -- the bounce light on this island comes off lava and off a red-brown
	summit, not off a blue sky.
]]
local ASH_OUT = Color3.fromRGB(158, 132, 122)
local ASH_AMB = Color3.fromRGB(62, 48, 46)

--[[
	THICKER THAN ANY OTHER ISLAND'S, AND THAT IS THE WEATHER RATHER THAN THE MOOD.

	The dunes' note warns that piling on density to sell a haze washed their
	landmark out to a white silhouette at the main viewing distance, and the cove
	therefore barely moves it (0.32 -> 0.345). This island moves it a long way
	(0.32 -> 0.46) and gets away with it for one reason: its landmark is 186 studs
	TALL and is lit from inside. A cone with a glowing crater does not disappear
	into haze, it gains from it -- the haze is what puts four hundred studs of air
	between the camp and the mountain and stops a 960-stud island reading flat.

	Decay is the one that matters at distance. The beach's is a cold blue-grey
	(92,124,160) and it drags everything toward slate; pulling it to a warm ash
	brown is what lets the far end of this island stay warm instead of going
	photographic-grey. Glare comes DOWN, not up: a low sun through thick haze with
	high glare blows the whole west half of the frame out.
]]
--[[
	MEASURED, AND THE ARGUMENT ABOVE DID NOT SURVIVE THE NUMBERS.

	The reasoning was that a 186-stud cone lit from inside GAINS from haze rather
	than disappearing into it. That is a good argument and it is why this island
	is still the thickest of the five. But at Density 0.46 / Haze 2.35 it was
	simply not true: standing in the field with the summit 151 STUDS AWAY, the
	cone was not hazy, it was ABSENT -- and so were the sea stacks, the lava
	plates, the plume and all 22 torches. Visibility was about 150 studs on a
	960-stud island, so the entire payoff of the place -- the thing a player
	spends ten rebirths of ferry levels to reach -- rendered as a flat grey wall.

	0.42 / 1.45 keeps this the heaviest air in the game (the beach runs 1.4, the
	cove 0.75) and keeps the warm ash decay doing its job at distance, while
	putting the mountain back on screen. The eruption still thickens it by 1.5
	below, which now reads as the weather closing in rather than as no change to
	an already-opaque sky.
]]
local ASH_ATMO = {
	Density = 0.42, Haze = 1.45, Glare = 0.14,
	Color = Color3.fromRGB(212, 196, 184),
	Decay = Color3.fromRGB(126, 102, 94),
}

--[[
	A COLD, OPAQUE SEA, which is the opposite call to the cove's.

	The cove wants crystal shallows you can see the sand through, so its water goes
	pale and nearly transparent. Here the shelf is BLACK basalt: made transparent
	the sea would show you a dark floor through dark water and the whole coastline
	would read as one flat void. Opaque and cold instead, with real reflectance, so
	the water is the one thing on this island that carries the SKY -- which is what
	separates the shoreline from the land at any distance.

	Waves go up rather than down. This is an exposed volcanic coast on the far side
	of the map, and the ferryman's own line about the water past the point being
	bad should be true when you get there.

	All five are global properties. They are only survivable because a CLIENT write
	to them does not replicate -- and because every one is lerped back to HOME_WATER
	on the way out. Leave any of them written and the entire map's sea is slate for
	the rest of that session.
]]
local ASH_WATER = {
	Color = Color3.fromRGB(30, 92, 116),
	Transparency = 0.20,
	Reflectance = 0.55,
	WaveSize = 0.24,
	WaveSpeed = 9,
}

-- Late afternoon, held through LightingLock rather than by writing ClockTime.
--
-- Writing the clock directly does not work in this place and fails in a way that
-- looks like an engine bug: LightingLock re-asserts its target on the ClockTime
-- signal AND on a 2s Heartbeat poll, so the sky flashes and snaps back to noon
-- forever. The lock is retargetable instead -- one number on the LocalPlayer --
-- and easing is explicitly the CALLER's job.
--
-- 16.2 rather than the cove's 17: this island has to stay READABLE. Seventeen is
-- a gorgeous hour on pink sand and on black sand it is nearly night, and the
-- player is here to find things in it.
local CLOCK_ATTR = "CTB_ClockTarget"
local HOUR_HOME = 12
local HOUR_ASH = 16.2

local blend = 0            -- 0 = beach, 1 = Ashfall
local everTouched = false  -- has this file ever written a shared value?

-- 0..1, and it is the ERUPTION's, not the island's. Declared up here because
-- applyBlend has to fold it in and applyBlend is defined before the eruption is.
local flash = 0
local FLASH_TINT = Color3.fromRGB(255, 176, 96)

--[[
	SATURATION GOES UP AND CONTRAST GOES UP, and both are the opposite of the
	instinct for an ash island.

	The instinct is a desaturated, low-contrast grade -- that is what "volcanic"
	looks like in a photograph. It is wrong here for the same reason the dunes'
	block gives for amber: this palette has almost no saturation to spare. Grey
	sand, grey rock, grey ash and grey sky, minus saturation, is a black and white
	frame with three orange dots in it. Pushing saturation costs the greys nothing
	(there is nothing to push) and buys the lava, the torches and the sulphur
	everything.

	Contrast is the same argument. A low sun through heavy haze is naturally FLAT,
	and flat on a dark island is mud; a step of contrast is what keeps the black
	sand separated from the black rock standing on it.

	The tint is doing real work rather than decoration. Half of what a player looks
	at here is lit by a low sun and half by a dirty sky, and colouring the PARTS
	warm cannot fix that split -- it only makes the sunlit half garish. A warm tint
	over the whole frame pulls the shaded rock and the lit sand together, which is
	what makes the island look like one place.
]]
local TINT = Color3.fromRGB(255, 240, 226)

local function applyBlend(a: number)
	grade.Brightness = 0.012 * a
	grade.Contrast = 0.07 * a
	grade.Saturation = 0.12 * a
	grade.TintColor = Color3.new(
		1,
		1 - (1 - TINT.G) * a,
		1 - (1 - TINT.B) * a
	)

	--[[
		THE ERUPTION FLASH RIDES ON TOP OF THE ISLAND'S OWN GRADE, in the same
		effect rather than in a second one.

		A fifth ColorCorrectionEffect in Lighting would be the obvious way to do a
		one-off flash and it is the wrong one twice over: this place has already been
		bitten by two objects of one class both being written (see the Atmosphere
		note above), and effects MULTIPLY -- a flash layered over a grade does not
		land where either one says it will. Folded in here it is one write, it can
		never outlive the island's own fade, and applyBlend recomputes from scratch
		every call so it cannot accumulate.

		It is scaled by `a` as well as by `flash`: an eruption seen from the beach
		2200 studs away should not bleach the beach.
	]]
	if flash > 0 then
		local f = flash * a
		grade.Brightness += 0.11 * f
		grade.Contrast += 0.05 * f
		grade.Saturation += 0.22 * f
		grade.TintColor = grade.TintColor:Lerp(FLASH_TINT, f * 0.8)
	end

	Lighting.OutdoorAmbient = HOME_OUT:Lerp(ASH_OUT, a)
	Lighting.Ambient = HOME_AMB:Lerp(ASH_AMB, a)

	if atmo and HOME_ATMO then
		atmo.Density = HOME_ATMO.Density + (ASH_ATMO.Density - HOME_ATMO.Density) * a
		-- The haze THICKENS during an eruption, which is the one atmospheric change
		-- here that is literally true: the mountain has just put a great deal of ash
		-- into the air between the player and everything else.
		atmo.Haze = HOME_ATMO.Haze + (ASH_ATMO.Haze - HOME_ATMO.Haze) * a + 1.5 * flash * a
		atmo.Glare = HOME_ATMO.Glare + (ASH_ATMO.Glare - HOME_ATMO.Glare) * a + 0.5 * flash * a
		atmo.Color = HOME_ATMO.Color:Lerp(ASH_ATMO.Color, a)
		atmo.Decay = HOME_ATMO.Decay:Lerp(ASH_ATMO.Decay, a)
	end

	Terrain.WaterColor = HOME_WATER.Color:Lerp(ASH_WATER.Color, a)
	Terrain.WaterTransparency = HOME_WATER.Transparency
		+ (ASH_WATER.Transparency - HOME_WATER.Transparency) * a
	Terrain.WaterReflectance = HOME_WATER.Reflectance
		+ (ASH_WATER.Reflectance - HOME_WATER.Reflectance) * a
	Terrain.WaterWaveSize = HOME_WATER.WaveSize
		+ (ASH_WATER.WaveSize - HOME_WATER.WaveSize) * a
	Terrain.WaterWaveSpeed = HOME_WATER.WaveSpeed
		+ (ASH_WATER.WaveSpeed - HOME_WATER.WaveSpeed) * a

	player:SetAttribute(CLOCK_ATTR, HOUR_HOME + (HOUR_ASH - HOUR_HOME) * a)

	everTouched = true
end

--[[
	RE-READ THE HOME VALUES WHILE THEY ARE STILL DEMONSTRABLY THE HOME VALUES.

	applyLook runs on the SERVER at boot and its water and lighting writes have to
	replicate down before the snapshot above is worth anything -- and
	StarterPlayerScripts do not wait for that. So the snapshot is refreshed on the
	zone poll for as long as this file has never written a shared value.

	TWO GUARDS, because `everTouched` on its own is not the bound it looks like.
	It only becomes true on this file's first ASHFALL write, so until the player
	has been west at least once it would fire every 0.4 seconds WHEREVER they are
	-- including in the dunes, the vault and the cove, all three of which are
	actively writing the very properties being sampled. Sampled there, HOME_OUT
	gets captured as somebody else's graded ambient and this file's own final
	applyBlend(0) stamps it onto the beach permanently.

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
-- THE ASHFALL
----------------------------------------------------------------
--[[
	ONE EMITTER, PARKED UPWIND AND OVERHEAD, FOLLOWING THE PLAYER.

	The island is 960 studs across and there is no way to have falling ash
	everywhere on it: covering that area with static emitters is hundreds of them,
	and every one is drawing whether or not anybody is looking at it. So there is
	one, it is a wide flat slab, it sits over the player's shoulder, and the
	particles blow through the frame from there. The cove's drifting petals use
	exactly this and for exactly this reason.

	UPWIND rather than directly overhead, because a particle spawned above your
	head and falling straight down enters the frame at the top edge and reads as a
	screen effect. Spawned back along the wind it enters from the side, travels,
	and reads as weather.

	NOT the same thing as blossom, and the difference is in the SIZE ramp: ash
	flakes do not grow, they burn out. So these start at their size and shrink to
	nothing, which is also what stops a hundred grey specks from turning the frame
	to static.
]]
local WIND = Vector3.new(-0.82, 0, 0.57).Unit   -- out of the north-east, off the cone
local DRIFT_BACK = 46
local DRIFT_UP = 34
local DRIFT_RATE = 34

local driftPart = Instance.new("Part")
driftPart.Name = "AshDrift"
driftPart.Size = Vector3.new(90, 1, 90)
driftPart.Transparency = 1
driftPart.Anchored = true
driftPart.CanCollide = false
driftPart.CanQuery = false
driftPart.CanTouch = false
driftPart.CastShadow = false
driftPart.Parent = fx

local driftEmit = Instance.new("ParticleEmitter")
driftEmit.Name = "Ash"
driftEmit.Texture = "rbxassetid://243098098"
driftEmit.Color = ColorSequence.new(ASH_PALE, ASH_GREY)
driftEmit.LightEmission = 0.15
driftEmit.LightInfluence = 1
driftEmit.Size = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.55),
	NumberSequenceKeypoint.new(0.75, 0.35),
	NumberSequenceKeypoint.new(1, 0),
})
driftEmit.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.12, 0.32),
	NumberSequenceKeypoint.new(0.8, 0.42),
	NumberSequenceKeypoint.new(1, 1),
})
driftEmit.Lifetime = NumberRange.new(7, 12)
driftEmit.Rate = 0
driftEmit.Speed = NumberRange.new(5, 11)
driftEmit.SpreadAngle = Vector2.new(26, 26)
driftEmit.Rotation = NumberRange.new(0, 360)
driftEmit.RotSpeed = NumberRange.new(-45, 45)
driftEmit.Acceleration = WIND * 5 - Vector3.new(0, 5.5, 0)
driftEmit.EmissionDirection = Enum.NormalId.Bottom
driftEmit.Parent = driftPart

----------------------------------------------------------------
-- THE EMBER DRIFT
----------------------------------------------------------------
-- The same trick again, running the other way and only near the mountain: warm
-- flecks lifting on the heat. Rate is scaled by how close the player is to the
-- cone rather than switched on and off, so it fades in as they climb rather than
-- appearing at a line on the ground.
local EMBER_RATE = 14
local emberPart = Instance.new("Part")
emberPart.Name = "EmberDrift"
emberPart.Size = Vector3.new(70, 1, 70)
emberPart.Transparency = 1
emberPart.Anchored = true
emberPart.CanCollide = false
emberPart.CanQuery = false
emberPart.CanTouch = false
emberPart.CastShadow = false
emberPart.Parent = fx

local emberEmit = Instance.new("ParticleEmitter")
emberEmit.Name = "Embers"
emberEmit.Texture = "rbxassetid://241650934"
emberEmit.Color = ColorSequence.new(EMBER, EMBER_DEEP)
emberEmit.LightEmission = 1
emberEmit.LightInfluence = 0
emberEmit.Size = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.36),
	NumberSequenceKeypoint.new(1, 0),
})
emberEmit.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.15),
	NumberSequenceKeypoint.new(1, 1),
})
emberEmit.Lifetime = NumberRange.new(2.5, 5)
emberEmit.Rate = 0
emberEmit.Speed = NumberRange.new(3, 9)
emberEmit.SpreadAngle = Vector2.new(40, 40)
emberEmit.Acceleration = Vector3.new(WIND.X * 2, 6, WIND.Z * 2)
emberEmit.EmissionDirection = Enum.NormalId.Top
emberEmit.Parent = emberPart

----------------------------------------------------------------
-- THE PLUME
----------------------------------------------------------------
--[[
	The column standing off the crater, and the only thing in this file that is
	pinned to the WORLD rather than to the player.

	BOUND TO THE LAVA LAKE, NOT TO A TYPED-IN POSITION. Island4Builder makes a part
	called LavaLake in the middle of the crater; finding it is how this file learns
	where the summit is without holding a second copy of the volcano's geometry
	that would go stale the day somebody moves it. The cove does the same thing
	with its sakura trees' PetalSource parts.

	AND IT REBINDS, because the folder INSTANCE changes: Island4Builder destroys
	and rebuilds workspace.Island4 on every server boot, and under StreamingEnabled
	the crater is 800 studs from the camp and simply is not on this machine most of
	the time. So the bind is checked, cheaply, on the same poll as everything else.
]]
local plumePart = Instance.new("Part")
plumePart.Name = "Plume"
plumePart.Size = Vector3.new(70, 1, 70)
plumePart.Transparency = 1
plumePart.Anchored = true
plumePart.CanCollide = false
plumePart.CanQuery = false
plumePart.CanTouch = false
plumePart.CastShadow = false
plumePart.Parent = fx

local PLUME_RATE = 9
local plumeEmit = Instance.new("ParticleEmitter")
plumeEmit.Name = "Smoke"
plumeEmit.Texture = "rbxassetid://243132757"
plumeEmit.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(96, 84, 84)),
	ColorSequenceKeypoint.new(0.35, ASH_GREY),
	ColorSequenceKeypoint.new(1, ASH_PALE),
})
plumeEmit.LightEmission = 0.2
plumeEmit.LightInfluence = 1
plumeEmit.Size = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 26),
	NumberSequenceKeypoint.new(0.5, 74),
	NumberSequenceKeypoint.new(1, 132),
})
plumeEmit.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.42),
	NumberSequenceKeypoint.new(0.55, 0.62),
	NumberSequenceKeypoint.new(1, 1),
})
plumeEmit.Lifetime = NumberRange.new(9, 15)
plumeEmit.Rate = 0
plumeEmit.Speed = NumberRange.new(16, 26)
plumeEmit.SpreadAngle = Vector2.new(10, 10)
plumeEmit.RotSpeed = NumberRange.new(-8, 8)
plumeEmit.Acceleration = Vector3.new(WIND.X * 7, 3, WIND.Z * 7)
plumeEmit.EmissionDirection = Enum.NormalId.Top
plumeEmit.Parent = plumePart

-- A second, hotter core low in the column, so the base of the plume is lit from
-- the lake rather than being grey all the way down.
local plumeGlow = Instance.new("ParticleEmitter")
plumeGlow.Name = "PlumeGlow"
plumeGlow.Texture = "rbxassetid://243132757"
plumeGlow.Color = ColorSequence.new(EMBER, EMBER_DEEP)
plumeGlow.LightEmission = 0.85
plumeGlow.LightInfluence = 0
plumeGlow.Size = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 22),
	NumberSequenceKeypoint.new(1, 52),
})
plumeGlow.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.55),
	NumberSequenceKeypoint.new(1, 1),
})
plumeGlow.Lifetime = NumberRange.new(2.2, 3.6)
plumeGlow.Rate = 0
plumeGlow.Speed = NumberRange.new(14, 22)
plumeGlow.SpreadAngle = Vector2.new(8, 8)
plumeGlow.EmissionDirection = Enum.NormalId.Top
plumeGlow.Parent = plumePart

local boundTo = nil            -- the Island4 folder the plume is currently sited from
local plumeSited = false

local function ensurePlume()
	local island = workspace:FindFirstChild("Island4")
	if island ~= boundTo then
		boundTo = island
		plumeSited = false
	end
	if plumeSited or not island then
		return plumeSited
	end
	local caldera = island:FindFirstChild("Caldera")
	local lake = caldera and caldera:FindFirstChild("LavaLake")
	if not lake then
		return false
	end
	-- Four studs over the lake: high enough that the column does not spawn inside
	-- its own Neon slab, low enough that it still reads as coming OUT of the pit.
	plumePart.CFrame = CFrame.new(lake.Position + Vector3.new(0, 4, 0))
	plumeSited = true
	return true
end

----------------------------------------------------------------
-- THE ERUPTION
----------------------------------------------------------------
--[[
	WHAT THE RESET LOOKS LIKE ON THIS ISLAND.

	Every field in this game turns over when the player has raked `resetAt` of it:
	the beach calls it a TIDE, the desert a SANDSTORM, the cove a HANAMI, and this
	one calls it an ERUPTION (Config.ISLANDS[5].resetName). CTB_Server clears the
	grid, pays the bonus and fires one "Tide" message; CTB_Client re-messes the
	sand and CTB_HUD toasts the payout. None of that changes. This is the picture
	that goes over the top of it.

	IT IS BUILT AROUND A NUMBER IN SOMEBODY ELSE'S SCRIPT, and that is the whole
	trick. CTB_Client raises the litter back out of the sand row by row with
	`delay = (grid - 1 - iz) * 0.06` -- north row first, south row last. On an
	80-grid that is 4.74 seconds sweeping from z = +156 to z = -156, and on THIS
	island north is the volcano. So the junk coming back is already a wave rolling
	off the mountain; all this does is put the thing that caused it at the top of
	the wave and an ash front on the front of it. Change ISLANDS[5].grid or that
	0.06 and FRONT_SECONDS below has to move with it, or the ash will arrive
	somewhere the sand is not.

	EVERYTHING HERE IS THIS CLIENT'S OWN. Not one part, sound or emitter belongs to
	the server: the blast lives in Island4_FX, so it cannot be streamed out from
	under itself at the moment it is needed, and it costs no bandwidth on a server
	full of people turning their own fields over.

	THE PLAYER IS ON THE FIELD WHEN THIS FIRES, by construction -- they have just
	raked three quarters of it -- so the crater is 300 to 900 studs away and the
	whole set piece has to read at that range. That is why the shapes are enormous
	(a 420-stud dome, a 620-stud ground wave) and why the sound is 2D.
]]
local CRATER_FALLBACK = Vector3.new(-2200, 186, 470)
-- 4.74 s, and it is READ from the same place CTB_Client's re-mess sweep reads
-- it rather than being the same arithmetic typed twice. That 0.06 was a per-row
-- delay that only meant 4.74 seconds while this island was an 80-grid; at 160 it
-- would have made the front take 9.5 s and arrive long after the sand it is
-- supposed to be leaving behind. Config.remessStep caps the whole sweep.
local FRONT_SECONDS = (ASH.grid - 1) * Config.remessStep(ASH)
local FRONT_FROM, FRONT_TO = ASH.cz + ASH.half + 14, ASH.cz - ASH.half - 14
local ERUPT_LEN = 17

local function craterAt(): Vector3
	local island = workspace:FindFirstChild("Island4")
	local caldera = island and island:FindFirstChild("Caldera")
	local lake = caldera and caldera:FindFirstChild("LavaLake")
	-- The constant is a FALLBACK and not the plan: under StreamingEnabled the
	-- crater simply is not on this machine while the player is at the camp, and an
	-- eruption that does not happen because the mountain has not loaded is worse
	-- than one sited from a number that has been true since the island was poured.
	return lake and (lake.Position + Vector3.new(0, 18, 0)) or CRATER_FALLBACK
end

local function fxPart(name: string, size: Vector3): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Parent = fx
	return p
end

-- The three expanding shapes. Balls rather than anything cleverer: Roblox has no
-- torus and a ring built out of segments comes apart at this scale, whereas a
-- ball scaled up with its transparency ramping to 1 reads as a pressure front
-- from any angle and costs one part.
local blastPart = fxPart("Blast", Vector3.new(6, 6, 6))
local fireBall = fxPart("Fireball", Vector3.new(20, 20, 20))
fireBall.Shape = Enum.PartType.Ball
fireBall.Material = Enum.Material.Neon
fireBall.Color = EMBER
local domeBall = fxPart("ShockDome", Vector3.new(60, 60, 60))
domeBall.Shape = Enum.PartType.Ball
domeBall.Material = Enum.Material.SmoothPlastic
domeBall.Color = ASH_PALE
local ringBall = fxPart("GroundWave", Vector3.new(90, 6, 90))
ringBall.Shape = Enum.PartType.Ball
ringBall.Material = Enum.Material.SmoothPlastic
ringBall.Color = ASH_GREY

-- The column, the ejecta and the muzzle flash all hang off the one blast part.
local function burst(name, texture, colour, sizeSeq, life, speed, spread, accel, light)
	local e = Instance.new("ParticleEmitter")
	e.Name = name
	e.Texture = texture
	e.Color = colour
	e.LightEmission = light
	e.LightInfluence = 1 - light
	e.Size = sizeSeq
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(0.7, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Lifetime = life
	e.Rate = 0                       -- fired with :Emit, never left running
	e.Speed = speed
	e.SpreadAngle = spread
	e.Acceleration = accel
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-30, 30)
	e.EmissionDirection = Enum.NormalId.Top
	e.Parent = blastPart
	return e
end

local columnEmit = burst("Column", "rbxassetid://243132757",
	ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 148, 70)),
		ColorSequenceKeypoint.new(0.25, Color3.fromRGB(120, 100, 96)),
		ColorSequenceKeypoint.new(1, ASH_PALE),
	}),
	NumberSequence.new({
		NumberSequenceKeypoint.new(0, 40),
		NumberSequenceKeypoint.new(0.45, 140),
		NumberSequenceKeypoint.new(1, 260),
	}),
	NumberRange.new(7, 13), NumberRange.new(70, 130), Vector2.new(26, 26),
	Vector3.new(WIND.X * 9, -4, WIND.Z * 9), 0.35)

-- EJECTA IS ONE EMITTER, NOT FOURTEEN PARTS. Given a real downward acceleration
-- the particles fly genuine ballistic arcs out of the crater and fall on the
-- flanks, which is the whole read -- and it costs nothing next to fourteen
-- tweened bombs each with a trail.
local ejectaEmit = burst("Ejecta", "rbxassetid://241650934",
	ColorSequence.new(Color3.fromRGB(255, 214, 130), EMBER_DEEP),
	NumberSequence.new({
		NumberSequenceKeypoint.new(0, 7),
		NumberSequenceKeypoint.new(0.8, 4),
		NumberSequenceKeypoint.new(1, 0),
	}),
	NumberRange.new(2.6, 5.2), NumberRange.new(90, 190), Vector2.new(62, 62),
	Vector3.new(0, -128, 0), 1)

local flashEmit = burst("Flash", "rbxassetid://241650934",
	ColorSequence.new(Color3.fromRGB(255, 236, 190), EMBER),
	NumberSequence.new({
		NumberSequenceKeypoint.new(0, 90),
		NumberSequenceKeypoint.new(1, 210),
	}),
	NumberRange.new(0.5, 0.9), NumberRange.new(30, 60), Vector2.new(180, 180),
	Vector3.new(), 1)

-- A light in the crater for the length of the blast. ONE, and only while it is
-- happening -- see the header on why nothing out here carries a standing light.
local blastLight = Instance.new("PointLight")
blastLight.Color = EMBER
blastLight.Range = 260
blastLight.Brightness = 0
blastLight.Shadows = false
blastLight.Parent = fireBall

--[[
	THE ASH FRONT -- the curtain that rolls down the island behind the blast.

	It is the piece that ties the picture to the mechanic: it travels at exactly
	the speed CTB_Client raises the litter back out of the sand, so the junk
	appears UNDER it rather than near it. Wide enough to cover the whole field and
	then some, low enough that the player is inside it rather than watching it.
]]
local frontPart = fxPart("AshFront", Vector3.new(ASH.half * 2 + 140, 2, 30))
local frontEmit = Instance.new("ParticleEmitter")
frontEmit.Name = "Fall"
frontEmit.Texture = "rbxassetid://243098098"
frontEmit.Color = ColorSequence.new(ASH_PALE, ASH_GREY)
frontEmit.LightEmission = 0.1
frontEmit.LightInfluence = 1
frontEmit.Size = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 7),
	NumberSequenceKeypoint.new(1, 18),
})
frontEmit.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.18, 0.28),
	NumberSequenceKeypoint.new(0.85, 0.42),
	NumberSequenceKeypoint.new(1, 1),
})
-- Shorter than it was (3.5-6). The curtain and the fallout now overlap for the
-- whole five seconds it takes to cross the field, and live particle count is
-- rate x lifetime -- so trimming the life of the layer being seen at a DISTANCE
-- is the cheapest 240 particles on the island to give back.
frontEmit.Lifetime = NumberRange.new(2.8, 4.5)
frontEmit.Rate = 0
frontEmit.Speed = NumberRange.new(10, 24)
frontEmit.SpreadAngle = Vector2.new(40, 12)
frontEmit.Acceleration = Vector3.new(WIND.X * 4, -22, WIND.Z * 4)
frontEmit.EmissionDirection = Enum.NormalId.Bottom
frontEmit.Parent = frontPart

--[[
	THE FALLOUT -- the layer that actually covers the screen.

	The ambient ashfall was already being run at six times its normal rate during
	an eruption and it was the wrong thing to turn up: those flakes are half a stud
	across, they are parked forty-six studs UPWIND so they enter frame from the
	side, and they fall at 5.5 studs per second squared. That is weather in the
	distance. Multiplying it gets you more distance.

	What covers a screen is particles that pass THROUGH the camera, so this layer
	is built the opposite way round on all four counts:

		OVERHEAD, not upwind -- the slab is centred on the player, so the fall goes
		  down the front of the lens instead of across it
		CLOSE -- forty studs up rather than thirty-four and a diagonal, which is
		  about one second of fall, so what spawns is what you are about to be under
		BIG -- two and a half studs growing to five, against the drift's half stud
		HEAVY -- accelerating at 34, so they streak rather than float

	They spawn at Transparency 1 and ramp in over the first eighth of their life,
	which is what hides forty studs of pop-in directly above the camera.

	THE AMBIENT DRIFT STAYS, at its normal rate. It is the haze between this and
	the horizon, and without it the fallout reads as a effect bolted onto a clear
	day rather than as the worst of a storm that is going on everywhere.
]]
local FALLOUT_UP = 40
local FALLOUT_RATE = 230
local falloutPart = fxPart("Fallout", Vector3.new(120, 2, 120))

local falloutEmit = Instance.new("ParticleEmitter")
falloutEmit.Name = "Ashfall"
falloutEmit.Texture = "rbxassetid://243098098"
falloutEmit.Color = ColorSequence.new(ASH_PALE, ASH_GREY)
falloutEmit.LightEmission = 0.12
falloutEmit.LightInfluence = 1
falloutEmit.Size = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 2.5),
	NumberSequenceKeypoint.new(0.7, 4.4),
	NumberSequenceKeypoint.new(1, 5.2),
})
falloutEmit.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.12, 0.18),
	NumberSequenceKeypoint.new(0.82, 0.3),
	NumberSequenceKeypoint.new(1, 1),
})
falloutEmit.Lifetime = NumberRange.new(1.7, 2.8)
falloutEmit.Rate = 0
falloutEmit.Speed = NumberRange.new(14, 30)
falloutEmit.SpreadAngle = Vector2.new(22, 22)
falloutEmit.Rotation = NumberRange.new(0, 360)
falloutEmit.RotSpeed = NumberRange.new(-70, 70)
falloutEmit.Acceleration = Vector3.new(WIND.X * 6, -34, WIND.Z * 6)
falloutEmit.EmissionDirection = Enum.NormalId.Bottom
falloutEmit.Parent = falloutPart

--[[
	...AND THE THINGS YOU CAN SEE COMING DOWN.

	Ash is a texture; falling DEBRIS is an event, and it is the half that makes a
	player look up. Same slab, a tenth of the rate, three times the size and
	glowing -- so a couple of hot chunks are in shot at any moment rather than a
	curtain of them.

	Kept deliberately sparse. At the drift's rate this stops being an eruption
	dropping bombs on a beach and becomes orange snow.
]]
local DEBRIS_RATE = 24
local debrisEmit = Instance.new("ParticleEmitter")
debrisEmit.Name = "Fallingdebris"
debrisEmit.Texture = "rbxassetid://241650934"
debrisEmit.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 206, 130)),
	ColorSequenceKeypoint.new(0.4, EMBER),
	ColorSequenceKeypoint.new(1, EMBER_DEEP),
})
debrisEmit.LightEmission = 1
debrisEmit.LightInfluence = 0
debrisEmit.Size = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1.8),
	NumberSequenceKeypoint.new(0.75, 2.6),
	NumberSequenceKeypoint.new(1, 0),
})
debrisEmit.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.9),
	NumberSequenceKeypoint.new(0.1, 0.05),
	NumberSequenceKeypoint.new(0.9, 0.2),
	NumberSequenceKeypoint.new(1, 1),
})
debrisEmit.Lifetime = NumberRange.new(1.5, 2.4)
debrisEmit.Rate = 0
debrisEmit.Speed = NumberRange.new(22, 42)
debrisEmit.SpreadAngle = Vector2.new(18, 18)
debrisEmit.Acceleration = Vector3.new(WIND.X * 3, -46, WIND.Z * 3)
debrisEmit.EmissionDirection = Enum.NormalId.Bottom
debrisEmit.Parent = falloutPart

--[[
	TWO CLIPS AND BOTH ARE 2D, which is a deliberate break from how everything
	else in this game is mixed.

	A volcano going off is not a sound with a position -- it is the loudest thing
	that has ever happened to you, wherever on the island you are standing. Given
	a 3D Sound at the crater the player raking the south end of the field, 900
	studs away, gets a polite thump.

	Measured lengths, checked in this place one id at a time:
	  9114224354   7.39s  Earthquake Explosion, hard impact, cracking booms, long decay
	  9113220485  12.36s  Avalanche, massive rumbling constant, rocky burst, debris

	The roar starts a quarter of a second AFTER the boom rather than with it: two
	big clips landing on the same frame is one loud noise, and staggered it is a
	blast followed by the mountain still coming apart.
]]
local function oneShot(id: string, volume: number, speed: number): Sound
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.PlaybackSpeed = speed
	s.SoundGroup = sfxGroup       -- so the Sound Effects toggle silences it too
	s.Parent = SoundService
	return s
end
local boomSound = oneShot("rbxassetid://9114224354", 0.85, 0.78)
local roarSound = oneShot("rbxassetid://9113220485", 0.5, 0.85)

----------------------------------------------------------------
-- Eruption state
----------------------------------------------------------------
local eruptAt = nil        -- os.clock() of the blast, or nil
local ashSurge = 0         -- 0..1, how much extra ash is in the air
local shake = 0            -- 0..1, the ground still moving
local roarQueued = false

-- ONE PLACE that decides what every emitter is doing, because the blend and the
-- eruption both move them and two writers on one Rate is the boot-order problem
-- in miniature.
local function refreshRates()
	-- THE DRIFT STAYS AT ITS NORMAL RATE during an eruption. It used to be run at
	-- six times, which was the wrong dial: those flakes are half a stud across and
	-- parked upwind, so multiplying them thickened the middle distance and did
	-- nothing at all to the foreground. The fallout layer covers the screen now and
	-- this stays what it always was -- the haze behind it.
	driftEmit.Rate = DRIFT_RATE * blend
	plumeEmit.Rate = PLUME_RATE * blend * (1 + ashSurge * 3)
	plumeGlow.Rate = PLUME_RATE * 0.6 * blend * (1 + ashSurge * 4)
	-- Both eruption-only: ashSurge is zero at every other moment, so these cost a
	-- multiply per frame and nothing else.
	falloutEmit.Rate = FALLOUT_RATE * ashSurge * blend
	-- SQUARED, so the hot debris stops falling well before the ash does. Chunks
	-- raining out of a clear sky fourteen seconds later is the tell that a set
	-- piece is on a timer rather than settling.
	debrisEmit.Rate = DEBRIS_RATE * ashSurge * ashSurge * blend
end

local function erupt()
	-- Re-entrant on purpose: a second reset inside seventeen seconds restarts the
	-- picture rather than queueing a second one on top of it. The server already
	-- rate-limits resets to one per island every six seconds.
	eruptAt = os.clock()
	roarQueued = true

	local at = craterAt()
	blastPart.CFrame = CFrame.new(at)
	fireBall.CFrame = CFrame.new(at)
	domeBall.CFrame = CFrame.new(at)
	ringBall.CFrame = CFrame.new(at.X, ASH.cleanY + 6, at.Z)

	flashEmit:Emit(26)
	columnEmit:Emit(190)
	ejectaEmit:Emit(110)
	boomSound.TimePosition = 0
	boomSound:Play()

	flash = 1
	ashSurge = 1
	shake = 1
	refreshRates()
end

--[[
	HOW HARD THE GROUND SHAKES WHERE THE PLAYER IS STANDING.

	Through Humanoid.CameraOffset rather than by taking the camera: the default
	camera module applies that for us, so nothing here has to own CameraType and a
	player who walks out of it mid-shake simply stops being shaken.

	IT IS A SHARED CHANNEL AND FerryClient IS THE OTHER WRITER -- it rides the boat
	on the swell through the same property and zeroes it when the crossing ends.
	The two cannot overlap in practice (this fires the instant a field crosses 75%
	raked, and you cannot be aboard a ferry while raking), and both decay to zero
	rather than parking a value, so the worst case is one frame of somebody else's
	offset. Note it before adding a third writer.

	ATTENUATED BY DISTANCE, not switched on and off. The crater is 300 studs from
	the north of the field and 900 from the camp, and a shake that is full strength
	at both is a rumble pack rather than a mountain.
]]
local function applyShake(here: Vector3, now: number)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	-- The eruption still erupts, the ash still falls and the sound still lands;
	-- the only thing this switch takes away is the ground moving the camera.
	if shake <= 0.001 or not Motion.shake() then
		if hum.CameraOffset.Magnitude > 0.001 then
			hum.CameraOffset = Vector3.zero
		end
		return
	end
	local d = (Vector3.new(here.X, 0, here.Z) - Vector3.new(CRATER_FALLBACK.X, 0, CRATER_FALLBACK.Z)).Magnitude
	local atten = math.clamp(1 - d / 1100, 0.3, 1)
	--[[
		Two frequencies: a slow roll under a fast rattle. One alone reads as a camera
		bug rather than as ground.

		AND THE AMPLITUDE IS SMALL, WHICH IS NOT WHAT IT LOOKS LIKE ON PAPER. The two
		sine terms are weighted 0.6 and 0.4, so `amp` IS the peak displacement in
		studs -- and FerryClient, the only other thing in this game that writes
		CameraOffset, records that a quarter of a stud is already a lot of movement.
		The first cut of this used 2.6, which works out at 1.5 studs where the player
		is actually standing: six times "a lot", every frame, for six seconds. That is
		not a big eruption, it is motion sickness.

		1.2 puts it at about 0.70 studs on the field, 1.20 on the crater rim and 0.36
		at the camp, and the square on `shake` means it is most of the way gone inside
		two seconds. That is roughly five times the boat's swell at the closest a
		player can be to the vent, which is about right for standing on one, and it
		is still well under the 1.5 that made the first cut unwatchable.
	]]
	local amp = shake * shake * atten * 1.2
	hum.CameraOffset = Vector3.new(
		(math.sin(now * 41.3) * 0.6 + math.sin(now * 7.9) * 0.4) * amp,
		(math.sin(now * 33.7) * 0.6 + math.sin(now * 6.1) * 0.4) * amp * 0.8,
		0)
end

-- Returns true while the eruption still has anything to say.
local function tickEruption(dt: number, now: number, here: Vector3?): boolean
	if not eruptAt then
		return false
	end
	local t = now - eruptAt

	if roarQueued and t >= 0.25 then
		roarQueued = false
		roarSound.TimePosition = 0
		roarSound:Play()
	end

	-- the fireball: brief, and the only thing here that is Neon
	local fb = math.clamp(t / 0.32, 0, 1)
	fireBall.Size = Vector3.one * (20 + 128 * fb)
	fireBall.Transparency = fb >= 1 and 1 or (fb * 0.9)
	blastLight.Brightness = 5 * (1 - math.clamp(t / 1.6, 0, 1)) ^ 2

	-- the pressure dome, and the ground wave running out from under it
	local dm = math.clamp(t / 1.35, 0, 1)
	domeBall.Size = Vector3.one * (60 + 380 * dm)
	domeBall.Transparency = 0.55 + 0.45 * dm
	local rg = math.clamp(t / 1.7, 0, 1)
	local rw = 90 + 540 * rg
	ringBall.Size = Vector3.new(rw, 6 + 10 * rg, rw)
	ringBall.Transparency = 0.45 + 0.55 * rg

	--[[
		THE FRONT, TRAVELLING AT CTB_Client's OWN SWEEP SPEED.

		It starts a third of a second late so the blast is seen before its
		consequence, and it is placed in Z only -- the field is 320 studs wide and
		the curtain is wider, so there is nothing to gain from moving it in X.
	]]
	local ft = (t - 0.35) / FRONT_SECONDS
	if ft >= 0 and ft <= 1.15 then
		local z = FRONT_FROM + (FRONT_TO - FRONT_FROM) * math.min(ft, 1)
		frontPart.CFrame = CFrame.new(ASH.cx, ASH.cleanY + 46, z)
		frontEmit.Rate = 150 * (1 - math.max(0, ft - 1) / 0.15)
	else
		frontEmit.Rate = 0
	end

	--[[
		THE AIR CLEARS SLOWLY, and that is most of what makes it feel like weather
		rather than an effect. The flash is gone in three seconds, the ash hangs
		about for seventeen -- so the bang is over long before the island stops
		looking like something happened to it.
	]]
	flash = math.max(0, 1 - t / 3.0) ^ 1.6
	ashSurge = (t < 1.5) and (t / 1.5) or math.max(0, 1 - (t - 1.5) / (ERUPT_LEN - 1.5))
	shake = math.max(0, 1 - t / 6.0) ^ 1.4
	if here then
		applyShake(here, now)
		-- The fallout slab rides DIRECTLY over the player -- not upwind of them, the
		-- way the ambient drift is parked. See the note on FALLOUT_UP: overhead is
		-- the whole difference between ash you watch and ash you are under.
		falloutPart.CFrame = CFrame.new(here + Vector3.new(0, FALLOUT_UP, 0))
	end
	refreshRates()

	if t > ERUPT_LEN then
		eruptAt, ashSurge, shake, flash = nil, 0, 0, 0
		frontEmit.Rate = 0
		blastLight.Brightness = 0
		fireBall.Transparency = 1
		domeBall.Transparency = 1
		ringBall.Transparency = 1
		applyShake(here or Vector3.zero, now)
		refreshRates()
		return false
	end
	return true
end

--[[
	WHAT SETS IT OFF.

	The SAME message CTB_Client and CTB_HUD already listen for -- the server sends
	one "Tide" per reset carrying (islandId, bonus, resetName) -- so there is no
	new remote, no new server code and nothing that can disagree with the sand
	about whether a reset happened. A third connection on one RemoteEvent is free.

	And a TEST HOOK, because the honest way to see this otherwise is to rake 4800
	columns. From the client console in a running session:

		game.Players.LocalPlayer:SetAttribute("AshfallTestErupt", os.clock())

	An attribute rather than a remote or a global: it is client-only, it cannot be
	fired by anybody else's machine, and it leaves nothing behind in the datamodel
	that a player could find.
]]
local Net = ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Net")
Net.OnClientEvent:Connect(function(action, islandId)
	if action == "Tide" and islandId == ASH.id then
		erupt()
	end
end)
player:GetAttributeChangedSignal("AshfallTestErupt"):Connect(erupt)

----------------------------------------------------------------
-- Drive it
--
-- One connection, and everything inside it is behind the blend value: off the
-- island that is zero, and this costs a distance check every 0.4s and nothing
-- else. No emitter ticks, no raycasts, no rebinding where nobody can see them.
----------------------------------------------------------------
local FADE = 2.4

local onIsland = false
local zoneTimer = 0
local ambienceOn = false

applyBlend(0)
refreshRates()
-- applyBlend sets everTouched, which is only meant to mean "has written an
-- ASHFALL value". Cleared straight back, so the home snapshot can still be
-- refreshed once replication settles. The clock attribute written by that call is
-- 12, which is LightingLock's own default, so it changes nothing for a player who
-- never comes here.
everTouched = false

RunService.Heartbeat:Connect(function(dt)
	zoneTimer -= dt
	if zoneTimer <= 0 then
		zoneTimer = 0.4
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local zone = hrp and Config.zoneAt(hrp.Position) or nil
		onIsland = (zone ~= nil and zone.id == ASH.id)
		if not onIsland then
			recaptureHome(zone)
		end
	end

	local target = onIsland and 1 or 0
	if blend ~= target then
		blend += math.clamp(target - blend, -dt / FADE, dt / FADE)
		-- Snapping the last sliver matters more than it looks: it is what guarantees
		-- a FINAL write at exactly 0, which is the write that hands the beach back
		-- its own water, atmosphere, ambient and clock. Without it the lerp
		-- asymptotes and the sea stays very slightly slate forever.
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
					-- from zero, so every arrival would begin on the same wave.
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
		end
		for _, s in ipairs(ambienceSounds) do
			s.Volume = s:GetAttribute("Peak") * blend
		end
		refreshRates()
	end

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")

	--[[
		THE ERUPTION TICKS AHEAD OF THE BLEND GATE, not behind it.

		Everything else in this loop is allowed to idle when the player is not on the
		island; this is not, because it owns two things that must be put back. It
		holds `flash`, which is folded into the shared ColorCorrection, and it holds
		Humanoid.CameraOffset, which FerryClient also writes. Skipped on the frame
		somebody sails away mid-eruption, both would be parked at whatever value they
		happened to have -- a permanently warm screen and a permanently offset camera,
		for the rest of the session.

		applyBlend is re-called every frame it runs because the flash decays every
		frame. It recomputes from scratch, so this cannot accumulate.
	]]
	if eruptAt then
		tickEruption(dt, os.clock(), hrp and hrp.Position or nil)
		applyBlend(blend)
	end

	if blend <= 0.01 or not hrp then
		return
	end
	local here = hrp.Position

	-- The ash slab, parked upwind and overhead.
	driftPart.CFrame = CFrame.new(here - WIND * DRIFT_BACK + Vector3.new(0, DRIFT_UP, 0))

	--[[
		The ember slab, and its rate is a FUNCTION OF HEIGHT rather than of distance
		to the cone.

		Distance was the obvious test and it is the wrong one: the cone's foot is
		twenty studs from the rakeable field, so anybody raking the north half of the
		the strand is "near the volcano" and would rake in a shower of sparks. What
		actually correlates with being somewhere hot is being UP -- on the stair, on
		the rim, on the terrace -- so the ramp runs from nothing at sand level to full
		at the crater.
	]]
	local heat = math.clamp((here.Y - GROUND) / 150, 0, 1)
	emberPart.CFrame = CFrame.new(here - WIND * 22 - Vector3.new(0, 6, 0))
	emberEmit.Rate = EMBER_RATE * heat * blend

	-- The plume. Sited once per island-folder identity, and retried cheaply while
	-- the crater has not streamed in -- which it has not, every time, until the
	-- player has been within a few hundred studs of it.
	if not plumeSited then
		ensurePlume()
	elseif boundTo ~= workspace:FindFirstChild("Island4") then
		plumeSited = false
	end
end)

print("[Ashfall] client ready -- ash grade, slate sea, ashfall, embers and the plume armed")
