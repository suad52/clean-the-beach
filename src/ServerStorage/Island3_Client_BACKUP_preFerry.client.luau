--[[
	Island3_Client  --  StarterPlayer.StarterPlayerScripts.Island3_Client

	Everything about Sakura Cove that MOVES or is private to one player. The cove
	itself -- terrain, torii, boardwalk, stalls, gates -- is built once on the
	server by Island3Builder; this is the half that would cost bandwidth or leak
	state if the server did it.

		golden hour     the cove is a sunset island and the beach is not. Lighting
		                is ONE shared object, but a client's writes to it do not
		                replicate, so each player gets the hour and the grade for
		                the island THEY are standing on. Same trick the Dunes'
		                heat grade already runs on.
		pastel water    Terrain.WaterColor and friends are global PROPERTIES, not
		                per-region ones. Written here they stay on this machine,
		                which is the only way the cove gets turquoise shallows
		                without repainting the beach's sea for everybody.
		petals          pure decoration in two layers: a drift that follows the
		                player so there is always something in shot, and a fall
		                from every sakura tree the server planted.
		shore glow      surveyed off the terrain the builder actually made rather
		                than off numbers typed in here, because this file is
		                written before that builder exists.
		gate lock       whether the beach gate works is per player, and a
		                ProximityPrompt is a single shared instance -- so the
		                enable/disable is done here, locally, on top of the
		                server's own check.

	All of it idles when the player is not on the island: the per-frame work is
	behind a zone test that costs one distance check every 0.4 seconds.

	WHAT IS NOT HERE, AND WHY
	-------------------------
	THE SKY. CTB_Server.applyLook destroys every Sky it did not make and asserts
	six tropical faces, server side, once at boot. A client-added Sky would
	survive that (it runs before anybody joins) but it would then be a SECOND
	skybox this place has to keep track of, in a Lighting that is already holding
	27 of them and two Atmospheres. The clock, the grade and the atmosphere haze
	below carry golden hour on their own; if the sky itself ever has to change,
	it wants to be a swap-and-restore pair captured the way HOME_ATMO is, not a
	new child left lying in Lighting.

	GeographicLatitude. It is the obvious second dial for sun elevation -- noon
	elevation in this place measures 90 - |lat - 23.5|, so pushing latitude up
	drops the sun without touching the clock. It is deliberately NOT touched.
	Latitude moves the SUNSET TIME as well as the elevation, and this island is
	already parked at 17:00; push latitude far enough to lengthen the shadows and
	the sun can go under the horizon entirely, turning golden hour into night.
	That is not a change anybody should land without looking at it, and the
	camera belonged to another agent this phase. If a later pass wants it: it is
	shared, so capture it at boot and lerp it back in applyBlend exactly the way
	OutdoorAmbient is, or the beach inherits the cove's sun for the session.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local player = Players.LocalPlayer
local Config = require(ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Config"))

local COVE = Config.island(4)
local GROUND = COVE.cleanY               -- 3.0, shared by every field in the game

----------------------------------------------------------------
-- Folders and shared raycast params
----------------------------------------------------------------
-- Destroyed and rebuilt, so re-running this script in a live session (which is
-- what a Studio script reload does) leaves one set of emitters rather than two
-- stacked ones at double the rate.
local old = workspace:FindFirstChild("Island3_FX")
if old then
	old:Destroy()
end
local fx = Instance.new("Folder")
fx.Name = "Island3_FX"
fx.Parent = workspace

-- Solid ground only. Everything that asks "how high is the sand here" wants the
-- sand, not the sea surface lying on top of it.
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace.Terrain }
groundParams.IgnoreWater = true

-- The same ray WITH water, used once, to find where the sea surface actually
-- sits rather than assuming it.
local waterParams = RaycastParams.new()
waterParams.FilterType = Enum.RaycastFilterType.Include
waterParams.FilterDescendantsInstances = { workspace.Terrain }
waterParams.IgnoreWater = false

local function groundHit(x: number, z: number): RaycastResult?
	return workspace:Raycast(Vector3.new(x, 140, z), Vector3.new(0, -260, 0), groundParams)
end

local function terrainY(x: number, z: number, fallback: number): number
	local hit = groundHit(x, z)
	return hit and hit.Position.Y or fallback
end

----------------------------------------------------------------
-- THE PALETTE
--
-- One table, so the grade, the water, the petals and the glow are demonstrably
-- the same set of colours rather than four hand-picked pinks that nearly match.
-- Island3Props exports its own PALETTE for the geometry; these are the LIGHT
-- values, which are a different problem -- a part colour is read off the part,
-- a particle colour is read against the sky behind it.
----------------------------------------------------------------
local BLOSSOM = Color3.fromRGB(255, 209, 220)   -- #FFD1DC, the brief's own pink
local PETAL_PALE = Color3.fromRGB(255, 246, 249)
-- #AEC6CF, the brief's pastel turquoise. Kept as the reference it is, but NOT
-- used for the sea any more: see the note on COVE_WATER for what it did there.
local SHALLOW = Color3.fromRGB(174, 198, 207)
local _ = SHALLOW

----------------------------------------------------------------
-- Ambience
--
-- Routed through the BeachSFX SoundGroup, which is what the Settings panel's
-- Sound Effects toggle already drives -- so switching effects off silences the
-- cove too, with no extra wiring. That line is NOT optional: AudioKit's adopt()
-- safety net only sweeps workspace descendants, and these live under
-- SoundService, so an ungrouped Sound here would ignore the toggle entirely.
--
-- EVERY ID BELOW WAS LOADED IN THIS PLACE AND CHECKED FOR A NON-ZERO TimeLength
-- BEFORE IT WAS WRITTEN DOWN. A Sound with an id that does not resolve does not
-- throw -- it sits there playing nothing -- and silence looks exactly like a
-- feature nobody got to yet. All four are ProSoundEffects, Roblox's own
-- licensed library, so they cannot be moderated out from under the game.
--
-- Measured lengths, in the order they appear below:
--   9120570701  31.51s   Water Lap, Small Waves, Active, Slosh
--   9112865013  56.92s   Middle of Ocean Ambience, Water Movements, Waves, Loop
--   9120750072  31.06s   Wind Chimes, Delicate Tuned Ringing
--   9112810724  65.53s   Jungle Insects Dawn, Ringy Buzz of Cicadas, Loop
--
-- One thing worth knowing if you re-run that check: batching them through a
-- single ContentProvider:PreloadAsync call reported four of them as unloaded
-- when they were merely slow. Preloaded one at a time, all four came back
-- Success. Do not read a batch result as a verdict.
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

--[[
	NOT PLAYED HERE. This used to :Play() at load and hold Volume at 0 until the
	player arrived, which meant every client in the game decoded 31.5 + 56.9 +
	31.1 + 65.5 seconds of looping audio for the whole session whether or not
	anyone ever went north. Across the place that is six silent loops running
	(the Dunes established the pattern with two). Started and paused on the blend
	crossing instead -- see the ambience block in the Heartbeat.
]]
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

-- TWO WAVE LAYERS AT DIFFERENT LENGTHS, exactly as the Dunes does with its
-- wind. 31.51s against 56.92s never line back up inside a session, so the two
-- drift against each other and the repeat stops being audible. One loop is
-- recognisably one loop inside a minute, and a cove is somewhere a player is
-- meant to want to stand still in.
ambience("rbxassetid://9120570701", 0.94, 0.17)   -- lapping shallows, the near layer
ambience("rbxassetid://9112865013", 0.78, 0.075)  -- the open sea behind it, slow and quiet

-- The furin. Delicate tuned ringing rather than one of the library's "very
-- active" glass-and-ceramic takes: a chime that is always going reads as a
-- shop doorway, and this one has to survive being on for an hour. Run slightly
-- slow so the tuning sits under the surf instead of on top of it.
ambience("rbxassetid://9120750072", 0.86, 0.055)

-- Cicadas, the sound of a Japanese summer, and the quietest thing in the mix by
-- a distance. The take is slated "Intense" and it genuinely is at full level --
-- run down to 0.72 speed and 0.045 peak it becomes a distant treeline rather
-- than an insect on the microphone. If the cove ever sounds busy, this is the
-- first number to pull, not the waves.
ambience("rbxassetid://9112810724", 0.72, 0.045)

----------------------------------------------------------------
-- THE GOLDEN-HOUR GRADE
--
-- Its OWN ColorCorrectionEffect rather than pushing the shared one around:
-- CTB_Server's applyLook owns "ColorCorrection", and two writers on one effect
-- is how you get a look that depends on boot order. Neutral at home, so on the
-- beach this is a no-op.
----------------------------------------------------------------
local grade = Instance.new("ColorCorrectionEffect")
grade.Name = "CoveGrade"
grade.Brightness = 0
grade.Contrast = 0
grade.Saturation = 0
grade.TintColor = Color3.new(1, 1, 1)
grade.Parent = Lighting

--[[
	THERE IS EXACTLY ONE ATMOSPHERE NOW, AND THAT WAS A REAL BUG.

	Lighting used to hold TWO, both named "Atmosphere". FindFirstChildOfClass
	returns the FIRST; the RENDERER used the SECOND. Proven both ways -- zeroing
	the second one's Density removed all fog from the frame, while setting the
	first to Density 1.0 with a pure green Decay changed nothing at all. So this
	file's whole golden-hour atmosphere, and the Dunes' and the beach's, were
	being written to an object nothing drew, and the place rendered under a stale
	leftover at Density 0.442 / Haze 0.00 -- pure blue Rayleigh scatter, which is
	why the cove read as a navy silhouette in blue fog from any distance.

	The spare is deleted and CTB_Server's `ensure` now destroys duplicates of
	anything it owns, so this resolves to the one the renderer uses. If a future
	plugin drops another one in, that is the symptom to remember: every grade in
	the game stops working at once and nothing errors.
]]
local atmo = Lighting:FindFirstChildOfClass("Atmosphere")

-- Captured rather than assumed, so this stays a SHIFT away from whatever the
-- server set instead of a fixed value that fights applyLook.
--
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

-- AMBIENT IS WHAT MAKES THE TORII BELONG TO THE GROUND.
--
-- At 17:00 the sun is low and every north-facing surface in the cove -- the
-- back of the torii, the inside of the stalls, the shaded half of every rock --
-- is lit by ambient alone. The beach's ambient is a cool grey chosen to keep
-- sand shadows crisp, and under it a pink island renders blue-white in shadow
-- sitting on top of pink sand, which is the exact failure the Dunes hit with
-- its pyramid. Warm ambient is also just TRUE here: at golden hour the bounce
-- light off pink sand is pink.
local COVE_OUT = Color3.fromRGB(198, 150, 156)
local COVE_AMB = Color3.fromRGB(84, 58, 66)

-- Softer and PINKER than the beach, not thicker. The temptation with a sunset
-- is to pile on density to sell the haze; the Dunes' note above this same block
-- records what that costs -- its landmark washed out to a white silhouette from
-- the main viewing distance. The cove has a torii standing out in the water
-- that has to survive its own weather, so density moves barely at all (0.32 ->
-- 0.345) and the work is done by Colour and Decay instead.
--
-- Decay is the one that matters at distance. The beach's is a cold blue-grey
-- (92,124,160), and that cold is exactly what dragged the pink sand toward
-- mauve in the material tests -- the same reason the messy tint is kept warm at
-- blue 124. Pulling Decay to a dusty rose is what lets the far end of the cove
-- stay pink instead of going violet.
local COVE_ATMO = {
	Density = 0.345, Haze = 1.62, Glare = 0.34,
	Color = Color3.fromRGB(255, 224, 226),
	Decay = Color3.fromRGB(168, 122, 132),
}

-- Crystal-clear shallows want TRANSPARENCY, not colour. The beach's sea is a
-- deep saturated teal at 0.32 transparent, which reads as water you cannot see
-- into -- correct for open ocean, wrong for a cove where the whole point is
-- that you can see the sand under it. So the colour goes pale (#AEC6CF), the
-- transparency nearly doubles, the reflectance comes DOWN (a mirror surface
-- hides the bottom just as effectively as a dark one) and the waves go small
-- and slow.
--
-- All five are global properties. They are only survivable here because a
-- CLIENT write to them does not replicate -- and because every one of them is
-- lerped back to HOME_WATER on the way out. Leave any of them written and the
-- entire map's sea is pink for the rest of that session.
--
-- REFLECTANCE WAS THE BUG, AND 0.05 WAVES WERE THE SECOND ONE.
--
-- At Reflectance 0.30 under this place's Brightness 3.10 + Exposure 0.05 +
-- Bloom(0.55, threshold 1.6) the bay rendered as a flat near-WHITE sheet: no
-- wave motion, no depth, no reflection, and the seabed two studs under it
-- completely hidden. The arrival shot across the bay was half blank page and
-- the great torii appeared to be standing on paper. That is the exact opposite
-- of what the comment above asks for -- and the comment even says why, in its
-- own third clause: a mirror hides the bottom as effectively as a dark colour
-- does. 0.30 is not "down" from the beach's 0.50, it is still a mirror.
--
-- So: reflectance to 0.10, waves back up to something that actually moves, and
-- the colour two steps off white into a real turquoise. #AEC6CF is a lovely
-- pastel on a swatch and it is only 8% saturated, which is nothing once the
-- exposure has had it.
local COVE_WATER = {
	Color = Color3.fromRGB(104, 198, 200),
	Transparency = 0.62,
	Reflectance = 0.10,
	WaveSize = 0.13,
	WaveSpeed = 4.2,
}

-- Golden hour, held through LightingLock rather than by writing ClockTime.
--
-- Writing the clock directly does not work in this place and fails in a way
-- that looks like an engine bug: LightingLock re-asserts its target on the
-- ClockTime signal AND on a 2s Heartbeat poll, so the sky flashes sunset for
-- under a frame and snaps back to noon forever. The lock is retargetable
-- instead -- one number on the LocalPlayer -- and easing is explicitly the
-- CALLER's job, because two easers on one property is the boot-order problem
-- again. So the target is written every frame the blend moves, and the clock
-- tracks it exactly with nothing to fight.
local CLOCK_ATTR = "CTB_ClockTarget"
local HOUR_HOME = 12
local HOUR_COVE = 17

local blend = 0            -- 0 = beach, 1 = cove
local everTouched = false  -- has this file ever written a shared value?

-- SATURATION GOES UP, and the tint goes pink rather than the grade going warm.
--
-- The Dunes' block records the same finding for amber and it is worth repeating
-- because the instinct is the opposite: a sunset grade with NEGATIVE saturation
-- flattens exactly the colour the island is made of. A pastel palette has very
-- little saturation to spare in the first place -- that is what makes it
-- pastel -- so taking any out leaves grey sand with a pink light on it.
--
-- The tint is doing real work, not decoration. The cove's landmarks stand in or
-- beside water and are lit half by a low sun and half by sky; colouring the
-- PARTS pink cannot fix that split, it just makes the sunlit half garish. A
-- blossom tint over the whole frame warms the shaded torii and the lit sand
-- together, which is what makes the cove look like one place.
--
-- Contrast stays low (0.03). Golden hour is a LOW-contrast light -- long soft
-- shadows, not hard ones -- and pushing contrast here is what turns a sunset
-- into an orange filter.
local function applyBlend(a: number)
	grade.Brightness = 0.015 * a
	grade.Contrast = 0.03 * a
	grade.Saturation = 0.09 * a
	-- toward BLOSSOM: full green and blue at a = 0, pulled down to the pink's
	-- own ratios at a = 1.
	grade.TintColor = Color3.new(
		1,
		1 - (1 - BLOSSOM.G) * a,
		1 - (1 - BLOSSOM.B) * a
	)

	Lighting.OutdoorAmbient = HOME_OUT:Lerp(COVE_OUT, a)
	Lighting.Ambient = HOME_AMB:Lerp(COVE_AMB, a)

	if atmo and HOME_ATMO then
		atmo.Density = HOME_ATMO.Density + (COVE_ATMO.Density - HOME_ATMO.Density) * a
		atmo.Haze = HOME_ATMO.Haze + (COVE_ATMO.Haze - HOME_ATMO.Haze) * a
		atmo.Glare = HOME_ATMO.Glare + (COVE_ATMO.Glare - HOME_ATMO.Glare) * a
		atmo.Color = HOME_ATMO.Color:Lerp(COVE_ATMO.Color, a)
		atmo.Decay = HOME_ATMO.Decay:Lerp(COVE_ATMO.Decay, a)
	end

	Terrain.WaterColor = HOME_WATER.Color:Lerp(COVE_WATER.Color, a)
	Terrain.WaterTransparency = HOME_WATER.Transparency
		+ (COVE_WATER.Transparency - HOME_WATER.Transparency) * a
	Terrain.WaterReflectance = HOME_WATER.Reflectance
		+ (COVE_WATER.Reflectance - HOME_WATER.Reflectance) * a
	Terrain.WaterWaveSize = HOME_WATER.WaveSize
		+ (COVE_WATER.WaveSize - HOME_WATER.WaveSize) * a
	Terrain.WaterWaveSpeed = HOME_WATER.WaveSpeed
		+ (COVE_WATER.WaveSpeed - HOME_WATER.WaveSpeed) * a

	player:SetAttribute(CLOCK_ATTR, HOUR_HOME + (HOUR_COVE - HOUR_HOME) * a)

	everTouched = true
end

-- Re-read the home values while they are still demonstrably the home values.
--
-- applyLook runs on the SERVER at boot and its water and lighting writes have
-- to replicate down before the snapshot above is worth anything -- and
-- StarterPlayerScripts do not wait for that. So the snapshot is refreshed on
-- the zone poll for as long as this file has never written a shared value.
--
-- The guard is `everTouched`, not `blend == 0`, and that difference is the
-- whole point: Island2_Client is lerping the SAME Lighting properties from its
-- own captured home, so re-capturing during its 2.4s fade out of the dunes
-- would quietly adopt the desert's graded ambient as "the beach". Stopping
-- forever at the first cove write bounds that to the one window where the
-- player is provably standing on the spawn beach with nothing graded.
--[[
	TWO GUARDS, BECAUSE `everTouched` ON ITS OWN IS NOT THE BOUND THE COMMENT
	ABOVE CLAIMS IT IS.

	`everTouched` only becomes true on this file's first COVE write, so until the
	player has been north at least once this fires every 0.4 seconds WHEREVER
	they are -- including in the Dunes and in the Vault, both of which are
	actively writing the very properties being sampled (Island2_Client.applyBlend
	and Vault_Client.applyBlend write OutdoorAmbient, Ambient and all five
	Atmosphere fields, the latter every frame). Sampled there, HOME_OUT can be
	captured as the desert's (176,142,96) or the tomb's (104,82,58), and this
	file's own final applyBlend(0) on leaving the cove would then stamp that onto
	the beach permanently -- neither of those two files would ever correct it,
	because they only write while THEIR blend is moving.

	It does not fire today, and only by geography: the last poll before entering
	the cove is always on the spawn beach or in open water. That is one teleport
	away from being a session-long leak.

	  GUARD 1, WHERE.  Sample only where nothing is graded: the spawn beach, or
	    open water between islands. Never inside another island's zone.
	  GUARD 2, WHEN.   A gate teleport lands the player ON the beach while the
	    island they just left is still 2.4 seconds into its fade out, so guard 1
	    alone is not enough. So the sample has to be STILL: two consecutive polls
	    0.4s apart have to agree before it is committed. Anything mid-lerp is
	    writing every frame and cannot produce two identical samples.
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
	if zone ~= nil and zone.id ~= BEACH_ID then
		homeSample = nil
		return
	end
	local now = snapshotHome()
	if not sameSample(homeSample, now) then
		homeSample = now
		return
	end
	if atmo and HOME_ATMO then
		HOME_ATMO.Density, HOME_ATMO.Haze, HOME_ATMO.Glare = now.density, now.haze, now.glare
		HOME_ATMO.Color, HOME_ATMO.Decay = now.atmoColour, now.atmoDecay
	end
	HOME_OUT = now.out
	HOME_AMB = now.amb
	HOME_WATER.Color = now.wColour
	HOME_WATER.Transparency = now.wTrans
	HOME_WATER.Reflectance = now.wRefl
	HOME_WATER.WaveSize = now.wSize
	HOME_WATER.WaveSpeed = now.wSpeed
end

----------------------------------------------------------------
-- PARTICLE TEXTURES
--
-- Engine built-ins ONLY, and that is a measured decision rather than laziness.
-- Four sakura-petal decals off the Creator Store were fetched in this place and
-- ALL FOUR came back Enum.AssetFetchStatus.Failure:
--     345151826  "sakura petals w/ transparent background"
--     243344624  "Sakura Petal"
--     12531964905  "Flower petals"
--     119762215293942  "sakura L1"
-- Do not retry them. A failed texture does not throw either -- the emitter
-- silently falls back to a blank sprite -- so this is the image-side version of
-- the private-audio trap the ambience block above is about. Both built-ins
-- below returned Success in the same pass.
--
-- smoke_main is a soft round blob. Squashed flat, tumbled and coloured it
-- reads as a petal at the distance petals are ever seen from; the SILHOUETTE is
-- not what sells a petal, the flutter is. If somebody uploads a real petal
-- sprite to THIS universe later, it is a one-line swap here.
----------------------------------------------------------------
local TEX_PETAL = "rbxasset://textures/particles/smoke_main.dds"
local TEX_SPARK = "rbxasset://textures/particles/sparkles_main.dds"

-- Which way the breeze runs. One vector, shared by the drift emitter's parking
-- spot and by every petal's acceleration, so the two agree -- petals blowing
-- one way out of a cloud that is sitting the other way is instantly readable as
-- wrong even though nobody could say why.
local WIND = Vector3.new(0.82, 0, 0.57).Unit

local PETAL_COLOUR = ColorSequence.new({
	ColorSequenceKeypoint.new(0, BLOSSOM),
	ColorSequenceKeypoint.new(0.55, Color3.fromRGB(255, 226, 234)),
	ColorSequenceKeypoint.new(1, PETAL_PALE),
})

-- Fade in and out, never a hard pop at either end. The long flat middle is what
-- makes a petal read as one object crossing the frame rather than a twinkle.
local PETAL_ALPHA = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.12, 0.1),
	NumberSequenceKeypoint.new(0.82, 0.14),
	NumberSequenceKeypoint.new(1, 1),
})

local function dressPetals(e: ParticleEmitter)
	e.Texture = TEX_PETAL
	e.Color = PETAL_COLOUR
	e.Transparency = PETAL_ALPHA
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.42),
		NumberSequenceKeypoint.new(1, 0.34),
	})
	-- The flatten. A petal is an oval, and Squash is the only thing on an
	-- emitter that can make a round sprite into one.
	e.Squash = NumberSequence.new(0.55)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-95, 95)
	-- FacingCamera, explicitly. VelocityPerpendicular is the tempting one for
	-- anything falling and it is wrong here: it locks the sprite to the
	-- direction of travel, so a squashed particle turns into a streak and the
	-- tumble stops being visible at all.
	e.Orientation = Enum.ParticleOrientation.FacingCamera
	-- Lit, mostly. A petal is not a light source, but at 1.0 the shaded ones
	-- vanish against a dark treeline; a little emission keeps them present.
	e.LightEmission = 0.18
	e.LightInfluence = 0.55
	-- Drag is what turns a fall into a flutter: without it they drop in
	-- straight lines at terminal speed no matter what Acceleration says.
	e.Drag = 1.9
	-- OFF, and it must stay off. The drift emitter's part is moved every frame
	-- to follow the player; with LockedToPart true every live petal would be
	-- dragged along with it, so the whole cloud would slide sideways whenever
	-- the player walked. Set here rather than left to the default so nobody
	-- "tidies" it on later.
	e.LockedToPart = false
	e.Rate = 0
end

----------------------------------------------------------------
-- LAYER ONE: the drift that follows the player
--
-- A wide flat slab held above and UPWIND of the player, so petals blow into
-- shot rather than appearing in it. Same idea as the Dunes' blowing sand, and
-- the same reason: an island-wide emitter is either invisible from most of the
-- island or ruinous everywhere, and a cove is somewhere the player is meant to
-- linger and look around.
----------------------------------------------------------------
local driftPart = Instance.new("Part")
driftPart.Name = "PetalDrift"
driftPart.Size = Vector3.new(92, 3, 92)
driftPart.Transparency = 1
driftPart.Anchored, driftPart.CanCollide, driftPart.CanQuery, driftPart.CanTouch = true, false, false, false
driftPart.CastShadow = false
driftPart.Parent = fx

local driftEmit = Instance.new("ParticleEmitter")
dressPetals(driftEmit)
driftEmit.EmissionDirection = Enum.NormalId.Bottom
driftEmit.SpreadAngle = Vector2.new(55, 55)
driftEmit.Speed = NumberRange.new(1.0, 3.2)
-- Long, because the drift is the layer the player watches. 8-14 seconds at this
-- drag crosses most of the cove.
driftEmit.Lifetime = NumberRange.new(8, 14)
driftEmit.Acceleration = WIND * 3.1 + Vector3.new(0, -2.4, 0)
driftEmit.Parent = driftPart

-- THE PARTICLE BUDGET, written down because it is the thing that will get moved
-- without anybody re-deriving it. Live count is roughly rate * lifetime:
--     drift    14 * 11 avg     ~154
--     trees    12 * 1.5 * 7    ~126
--     shore    18 * 1.1 * 3    ~ 59
--     sparkle   4 * 4 * 1.2    ~ 19
-- about 360 live particles at full blend, and every one of them is off the
-- moment the player leaves. Raising any single rate is fine; raising several is
-- how a pastel island becomes the reason a phone drops frames in the beach
-- everybody spawns on, because the beach's own 4096 cells never go away.
local DRIFT_RATE = 14
local DRIFT_BACK = 34      -- studs upwind to park the slab
local DRIFT_UP = 27

----------------------------------------------------------------
-- LAYER TWO: fall from the trees the server planted
--
-- Every sakura tree Island3Builder scatters carries a part named "PetalSource"
-- (the seam names it, and this file may not rename it). Resolved LAZILY and
-- re-resolved, for the reason the Dunes' camel records: StreamingEnabled is on,
-- so when the player spawns on the beach none of the cove's PARTS exist on this
-- client -- only the folders above them. A WaitForChild at boot times out and
-- gives up for the whole session, and the result looks like an effects bug
-- rather than a streaming one.
--
-- So: one full scan when the island folder first resolves, DescendantAdded to
-- catch trees that stream in later, and the whole thing torn down and redone if
-- the folder INSTANCE changes -- which it does, because Island3Builder destroys
-- and rebuilds workspace.Island3 on every server boot.
----------------------------------------------------------------
local TREE_EMITTERS_MAX = 12
local TREE_RATE = 1.5
local TREE_MARK = "CTB_PetalWired"

local island = nil                -- the workspace.Island3 folder we are bound to
local islandConn = nil
local treeEmitters = {}

local function attachPetals(part: Instance)
	if #treeEmitters >= TREE_EMITTERS_MAX then
		return
	end
	if not part:IsA("BasePart") or part.Name ~= "PetalSource" then
		return
	end
	-- The emitter is a CLIENT instance parented into a replicated part. That is
	-- fine and does not leak -- client-made instances never replicate -- but it
	-- does mean a part that streams out takes ours with it, which is what the
	-- prune in the tick below is for. The attribute stops a second scan from
	-- doubling up on a part that already has one.
	if part:GetAttribute(TREE_MARK) then
		return
	end
	part:SetAttribute(TREE_MARK, true)

	local e = Instance.new("ParticleEmitter")
	dressPetals(e)
	e.EmissionDirection = Enum.NormalId.Bottom
	e.SpreadAngle = Vector2.new(38, 38)
	e.Speed = NumberRange.new(0.4, 1.6)
	e.Lifetime = NumberRange.new(5, 9)
	e.Acceleration = WIND * 2.4 + Vector3.new(0, -3.0, 0)
	e.Parent = part
	table.insert(treeEmitters, e)
end

local function bindIsland(folder: Instance)
	island = folder
	if islandConn then
		islandConn:Disconnect()
	end
	treeEmitters = {}

	-- Prefer the Props folder if the builder has made it: the island root is
	-- going to hold terrain-adjacent geometry, boardwalks and both gates, and
	-- there is no reason to walk all of that to find trees.
	local scope = folder:FindFirstChild("Props") or folder
	for _, d in ipairs(scope:GetDescendants()) do
		attachPetals(d)
	end
	-- Connected to the ROOT rather than to `scope`, because Props itself may not
	-- exist yet when this runs and a connection to a folder that arrives later
	-- is a connection nobody made.
	islandConn = folder.DescendantAdded:Connect(attachPetals)
end

-- Cheap enough to call every tick. Only does work when the folder identity
-- actually changes.
local function ensureIsland(): Instance?
	local found = workspace:FindFirstChild("Island3")
	if found ~= island then
		if found then
			bindIsland(found)
		else
			island = nil
			if islandConn then
				islandConn:Disconnect()
				islandConn = nil
			end
			treeEmitters = {}
		end
	end
	return island
end

----------------------------------------------------------------
-- SAND SPARKLE
--
-- FOUR wide emitters riding a slow ring around the player, not hundreds of
-- small ones pinned to the field. The field is 2304 cells; one emitter per cell
-- would be 2304 emitters for an effect nobody can see more than ~40 studs of.
-- Four that follow cost the same at every position on the island and are the
-- only version that scales when a second island turns up.
--
-- The ring turns slowly (RING_SPIN) so the glints are not always in the same
-- four spots relative to the camera, which is what would give the trick away.
----------------------------------------------------------------
local SPARK_COUNT = 4
local SPARK_RING = 26
local SPARK_SPIN = 0.21     -- radians per second
local SPARK_RATE = 4

local sparkles = {}
for i = 1, SPARK_COUNT do
	local p = Instance.new("Part")
	p.Name = "SandSparkle" .. i
	-- Wide and flat: the emitter's own volume is what scatters the glints, so a
	-- big thin slab does the scattering for free and no per-particle maths is
	-- needed to spread them over sand.
	p.Size = Vector3.new(22, 0.4, 22)
	p.Transparency = 1
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
	p.CastShadow = false
	p.Parent = fx

	local e = Instance.new("ParticleEmitter")
	e.Texture = TEX_SPARK
	e.Rate = 0
	e.Lifetime = NumberRange.new(0.7, 1.6)
	e.Speed = NumberRange.new(0, 0.4)
	e.SpreadAngle = Vector2.new(180, 180)
	e.EmissionDirection = Enum.NormalId.Top
	e.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, PETAL_PALE),
		ColorSequenceKeypoint.new(1, BLOSSOM),
	})
	-- Unlit and emissive. A glint IS the light; running it through the scene's
	-- shading at golden hour just makes it a small pink dot.
	e.LightEmission = 1
	e.LightInfluence = 0
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.35, 0.85),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.4, 0.28),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Parent = p

	table.insert(sparkles, { part = p, emit = e, phase = (i - 1) * (math.pi * 2 / SPARK_COUNT) })
end

----------------------------------------------------------------
-- THE SHORE GLOW
--
-- SURVEYED, not typed in. This file is being written before Island3Builder
-- exists, so there is no crescent to hardcode -- and hardcoding one would be
-- wrong later anyway, the moment somebody reshapes the bay. Instead: march rays
-- outward from the cove centre on a fan of bearings, find the radius on each
-- bearing where the ground drops under the sea surface, and hang the glow
-- there. Bearings that never cross water (inland, or terrain that has not
-- streamed in) simply contribute no segment.
--
-- NOT NEON, and that is deliberate. A Neon part has to sit at Transparency 0 in
-- this place -- above 0 it renders near-black under Future lighting -- so a
-- neon waterline is necessarily an OPAQUE band, which reads as a painted stripe
-- on the sand rather than as light coming off the water. Emitters plus a few
-- real PointLights give the spill onto the sand that is what actually sells
-- bioluminescence, and neither one has a transparency trap.
--
-- The pulse TRAVELS along the arc rather than blinking in unison: a phase
-- offset per segment, so it reads as a swell running down the beach. In unison
-- it reads as a light switch.
----------------------------------------------------------------
local SHORE_RAYS = 36        -- bearings sampled by the survey
local SHORE_MAX = 18         -- glow segments actually built
local SHORE_LIGHTS = 6       -- how many of them also carry a real light
local SHORE_RATE = 1.1
local SEA_FALLBACK = -0.5    -- measured off the beach's own waterline

local shoreFolder = Instance.new("Folder")
shoreFolder.Name = "ShoreGlow"
shoreFolder.Parent = fx

local shoreSegs = {}
local shoreBoundTo = nil     -- island folder identity the survey was run against
local surveying = false
local surveyCooldown = 0

local function seaLevel(): number
	-- Eight bearings, well outside anything the field could occupy. The first
	-- ray that comes back Water gives the surface height directly -- much safer
	-- than assuming the beach's -0.5 carries north, since nothing stops the
	-- builder from sitting the cove's sea somewhere else.
	for i = 0, 7 do
		local a = i * math.pi * 0.25
		local hit = workspace:Raycast(
			Vector3.new(COVE.cx + math.cos(a) * 380, 140, COVE.cz + math.sin(a) * 380),
			Vector3.new(0, -260, 0), waterParams)
		if hit and hit.Material == Enum.Material.Water then
			return hit.Position.Y
		end
	end
	return SEA_FALLBACK
end

local function clearShore()
	for _, seg in ipairs(shoreSegs) do
		if seg.part.Parent then
			seg.part:Destroy()
		end
	end
	shoreSegs = {}
end

local function buildShoreSegment(a: number, r: number, sea: number, index: number)
	local pos = Vector3.new(COVE.cx + math.cos(a) * r, sea + 0.2, COVE.cz + math.sin(a) * r)
	local p = Instance.new("Part")
	p.Name = "Glow" .. index
	-- Long along the shore, thin across it. Built with CFrame.new(from, to)
	-- pointing OUT to sea, which puts the part's Z on the radial and therefore
	-- its X on the tangent -- so the 16 studs of length lie ALONG the waterline
	-- rather than across it.
	p.Size = Vector3.new(16, 0.4, 4)
	p.CFrame = CFrame.new(pos, pos + Vector3.new(math.cos(a), 0, math.sin(a)))
	p.Transparency = 1
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
	p.CastShadow = false
	p.Parent = shoreFolder

	local e = Instance.new("ParticleEmitter")
	e.Texture = TEX_PETAL          -- the soft blob, which is what a haze wants
	e.Rate = 0
	e.Lifetime = NumberRange.new(2.2, 3.8)
	e.Speed = NumberRange.new(0.2, 0.9)
	e.SpreadAngle = Vector2.new(30, 12)
	e.EmissionDirection = Enum.NormalId.Top
	e.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, PETAL_PALE),
		ColorSequenceKeypoint.new(1, BLOSSOM),
	})
	e.LightEmission = 0.9
	e.LightInfluence = 0
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 3),
		NumberSequenceKeypoint.new(1, 9),
	})
	-- Very transparent throughout. This layer is meant to be felt and not
	-- looked at; at anything under about 0.75 it stops being a glow on the
	-- water and becomes visible smoke sitting on the beach.
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.3, 0.8),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Parent = p

	-- Only every few segments gets a real light. Roblox's per-frame light budget
	-- is small and shadowed lights are the expensive kind, so these are
	-- Shadows-off fill: they exist to put pink ON THE SAND, which is the half of
	-- "glow" that a particle can never do.
	local light = nil
	if SHORE_LIGHTS > 0 and (index - 1) % math.max(1, math.floor(SHORE_MAX / SHORE_LIGHTS)) == 0 then
		light = Instance.new("PointLight")
		light.Color = BLOSSOM
		light.Range = 30
		light.Brightness = 0
		light.Shadows = false
		light.Parent = p
	end

	table.insert(shoreSegs, { part = p, emit = e, light = light, phase = index * 0.42 })
end

-- Spread over frames on purpose. A full survey is roughly 2,400 raycasts; done
-- in one go that is a visible hitch on arrival, which is the worst possible
-- moment for one.
local function surveyShore(folder: Instance)
	surveying = true
	clearShore()

	local sea = seaLevel()
	local found = {}
	local STEP = 6

	for i = 0, SHORE_RAYS - 1 do
		local a = (i / SHORE_RAYS) * math.pi * 2
		local ux, uz = math.cos(a), math.sin(a)
		local lastLand, crossed = nil, false
		local r = 32
		while r <= 400 do
			local h = groundHit(COVE.cx + ux * r, COVE.cz + uz * r)
			if h and h.Position.Y > sea + 0.25 then
				lastLand = r
			elseif lastLand then
				-- We were on land and now we are not: the waterline is behind us.
				crossed = true
				break
			end
			r += STEP
		end

		-- `crossed` and not merely `lastLand`: a bearing that runs off the end of
		-- the search without ever meeting water is inland, or terrain that has
		-- not streamed in, and putting a segment at r = 400 there would hang a
		-- glowing patch in mid-air.
		if crossed then
			-- Bisect the last 6 studs down to under half a stud. Cheap, and worth
			-- it: a glow that is 6 studs inland of the water reads as a stripe on
			-- dry sand, which is the exact failure this effect is trying to avoid.
			local lo, hi = lastLand, lastLand + STEP
			for _ = 1, 4 do
				local mid = (lo + hi) * 0.5
				local h = groundHit(COVE.cx + ux * mid, COVE.cz + uz * mid)
				if h and h.Position.Y > sea + 0.25 then
					lo = mid
				else
					hi = mid
				end
			end
			table.insert(found, { a = a, r = (lo + hi) * 0.5 })
		end

		if i % 6 == 5 then
			task.wait()
		end
	end

	-- The folder can be torn down and rebuilt under us mid-survey (the builder
	-- reruns on every server boot), so the result is only committed if the world
	-- we measured is still the world we are looking at.
	if workspace:FindFirstChild("Island3") ~= folder then
		surveying = false
		return
	end

	local step = math.max(1, math.floor(#found / SHORE_MAX))
	local made = 0
	for i = 1, #found, step do
		if made >= SHORE_MAX then
			break
		end
		made += 1
		buildShoreSegment(found[i].a, found[i].r, sea, made)
	end

	shoreBoundTo = folder
	surveying = false
end

----------------------------------------------------------------
-- THE GATE LOCK
--
-- Per player, and done here rather than on the server, because a
-- ProximityPrompt is ONE instance shared by everybody -- disabling it server
-- side would lock out every player the moment one of them was short a level.
-- Client writes to it stay local. The server checks the level again on trigger,
-- so this is presentation, not security.
--
-- BeachGate is lockable and CoveGate is NOT, and that asymmetry is a
-- correctness requirement rather than a kindness: the way home is what stops a
-- player who rebirthed, or who arrived before a level check settled, from being
-- stranded 1500 studs from the wash bay with a full bag.
----------------------------------------------------------------
--[[
	RE-RESOLVED, NOT LATCHED, and that is the fix for a lie the beach gate told.

	This used to wire each gate ONCE and hold its ProximityPrompt, its label and
	its veil in a closure forever. Those are INSTANCES, and the beach gate stands
	1449 studs from the cove's arrival point -- well past the distance at which
	this codebase's own streaming notes say "none of its PARTS exist on this
	client". So every cove round trip destroyed and re-replicated the beach gate
	and the closure went on painting the corpse.

	The failure a player actually hits: visit the cove, rebirth (ProgressionServer
	resets RollerLevel to 1, from a bare remote with no location check, so it can
	be done while standing out here), walk home. The Sakura Cove gate is waiting
	with the unlocked sign, an un-greyed prompt and an open veil, because the
	fresh replica came back at the server's build-time defaults and nothing
	repainted it. They hold E for the full half second and NOTHING HAPPENS -- the
	server's own level check refuses in silence. No message, no log, no clue.

	So the poll below never stops. It re-resolves workspace.Island3 by IDENTITY
	(build() destroys and recreates that folder), notices when a wired gate's
	prompt has lost its Parent, and wires it again. The petal code does exactly
	this and says why; the gates were the one path that did not.
]]
local gateWired = {}          -- name -> { root, prompt, info, refresh }
local gateLabel = {}          -- name -> the UNLOCKED text, captured once ever

local function refreshGates()
	for _, w in pairs(gateWired) do
		w.refresh()
	end
end

local function wireGate(root: Instance, name: string, lockable: boolean): boolean
	local gate = root:FindFirstChild("Gates") and root.Gates:FindFirstChild(name)
	local pad = gate and gate:FindFirstChild("Pad")
	local prompt = pad and pad:FindFirstChild("TravelPrompt")
	local board = gate and gate:FindFirstChild("Board")
	if not (prompt and board) then
		return false
	end
	-- Board > GateGui > Info is the shared contract, and the board now carries
	-- one of those per readable FACE -- these gates are walked up to from both
	-- sides, and on both of them the BACK is the side you arrive at. Every one
	-- gets repainted, or the far face goes on advertising SAKURA COVE to a player
	-- who cannot use it.
	local infos = {}
	for _, gui in ipairs(board:GetChildren()) do
		if gui.Name == "GateGui" then
			local found = gui:FindFirstChild("Info")
			if found then
				table.insert(infos, found)
			end
		end
	end
	if #infos == 0 then
		return false
	end
	local veil = gate:FindFirstChild("Veil")
	-- Captured ONCE, and remembered across re-wires. Read fresh off the label
	-- every time, a re-wire that happened to catch a locked sign would adopt
	-- "SIFTER Lv.5 NEEDED" as the gate's name for the rest of the session.
	local label = gateLabel[name]
	if not label then
		label = infos[1].Text
		gateLabel[name] = label
	end

	local function refresh()
		-- 5 for the cove, and read INSIDE the refresh rather than captured next to
		-- `label` above. The gates can be wired before the root has published its
		-- attribute -- the builder makes the folder, then the gates, then stamps
		-- the level -- so a captured copy would freeze the fallback and the
		-- UnlockLevel change signal below would repaint the sign with the number
		-- it was already showing. The literal is only the fallback for a root that
		-- has not published one at all; the server stays the authority.
		local unlock = root:GetAttribute("UnlockLevel") or 5
		local open = (not lockable) or (player:GetAttribute("RollerLevel") or 1) >= unlock
		prompt.Enabled = open
		for _, info in ipairs(infos) do
			info.Text = open and label or string.format("SIFTER Lv.%d NEEDED", unlock)
			-- INK ON CREAM, both states. The sign is painted on the board now
			-- rather than floating over it, so the old near-white "open" colour
			-- would be cream lettering on a cream board. The LOCKED state is
			-- deliberately drained rather than a brighter pink: in a palette made
			-- entirely of soft pinks, "locked" cannot be another soft pink, and
			-- the only reading that survives is the colour going out of it.
			info.TextColor3 = open and Color3.fromRGB(74, 46, 64) or Color3.fromRGB(170, 148, 158)
		end
		if veil then
			--[[
				THESE TWO NUMBERS WERE THE WRONG WAY ROUND, and it read exactly
				backwards: the gate you could WALK THROUGH carried a solid pink
				membrane at 0.62 (which on the beach blew out to pure white and
				looked like a shut door), while the LOCKED one was 0.9 and nearly
				invisible. And because CoveGate is never lockable, the way home
				wore that film permanently -- it is what hid the sea and the great
				torii from anyone looking south through the arch.

				Open is a shimmer you can see straight through. Locked is a barrier.
			]]
			veil.Transparency = open and 0.9 or 0.5
			veil.Color = open and Color3.fromRGB(255, 190, 208) or Color3.fromRGB(148, 142, 152)
		end
	end

	gateWired[name] = { root = root, prompt = prompt, info = infos, refresh = refresh }
	refresh()
	return true
end

local GATES = { { "BeachGate", true }, { "CoveGate", false } }

task.spawn(function()
	-- One second forever, not until it succeeds. Island3Builder runs from
	-- CTB_Server on its own schedule so "not there yet" is the normal state at
	-- client boot rather than an error -- and the cove gate's parts do not exist
	-- on this client until the player is out there, nor the beach gate's once
	-- they are. Both directions have to be survivable.
	local boundRoot = nil
	local unlockConn = nil
	local missing = 0

	player:GetAttributeChangedSignal("RollerLevel"):Connect(refreshGates)

	while true do
		local root = workspace:FindFirstChild("Island3")
		if root then
			missing = 0
			if root ~= boundRoot then
				-- A rebuild makes a NEW folder. Drop everything bound to the old one
				-- rather than repainting instances that have left the world.
				boundRoot = root
				table.clear(gateWired)
				if unlockConn then
					unlockConn:Disconnect()
				end
				-- The root can publish UnlockLevel after the gates exist, so a change
				-- there has to repaint too -- otherwise a gate wired one tick early
				-- keeps the fallback 5 even when the server meant something else.
				unlockConn = root:GetAttributeChangedSignal("UnlockLevel"):Connect(refreshGates)
			end
			for _, g in ipairs(GATES) do
				local w = gateWired[g[1]]
				-- Parent going nil is how a streamed-out gate announces itself.
				if not (w and w.prompt.Parent and w.info[1].Parent) then
					wireGate(root, g[1], g[2])
				end
			end
		else
			boundRoot = nil
			table.clear(gateWired)
			missing += 1
			if missing == 90 then
				warn("[Cove] workspace.Island3 has not replicated after 90s -- still waiting; gate signs will not update until it does")
			end
		end
		task.wait(1)
	end
end)

----------------------------------------------------------------
-- Drive it
--
-- One connection, and everything inside it is behind the blend value: off the
-- island that is zero, and this costs a distance check every 0.4s and nothing
-- else. No petal ticks, no survey, no raycasts where nobody can see them.
----------------------------------------------------------------
local FADE = 2.4

local onIsland = false
local zoneTimer = 0
local ambienceOn = false

applyBlend(0)
-- applyBlend sets everTouched, which is only meant to mean "has written a COVE
-- value". Cleared straight back, so the home snapshot can still be refreshed
-- once replication settles. The clock attribute written by that call is 12,
-- which is LightingLock's own default, so it changes nothing for a player who
-- never comes here.
everTouched = false

RunService.Heartbeat:Connect(function(dt)
	local t = workspace:GetServerTimeNow()

	zoneTimer -= dt
	if zoneTimer <= 0 then
		zoneTimer = 0.4
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local zone = hrp and Config.zoneAt(hrp.Position) or nil
		onIsland = (zone ~= nil and zone.id == COVE.id)
		if not onIsland then
			recaptureHome(zone)
		end
	end

	local target = onIsland and 1 or 0
	if blend ~= target then
		blend += math.clamp(target - blend, -dt / FADE, dt / FADE)
		-- Snapping the last sliver matters more than it looks: it is what
		-- guarantees a FINAL write at exactly 0, which is the write that hands the
		-- beach back its own water, atmosphere, ambient and clock. Without it the
		-- lerp asymptotes and the sea stays very slightly pink forever.
		if math.abs(blend - target) < 0.002 then
			blend = target
		end
		applyBlend(blend)

		-- Volume tracks the blend, but the DECODER only runs while there is
		-- something to hear. Four looping tracks -- 31.5s, 56.9s, 31.1s and 65.5s
		-- -- used to be started at load and held at zero for the whole session,
		-- on every client, including the ones that never come north.
		local audible = blend > 0.01
		if audible ~= ambienceOn then
			ambienceOn = audible
			for _, s in ipairs(ambienceSounds) do
				if audible then
					-- Resume, not Play, once it has been started: Play restarts the
					-- loop from zero, so every arrival would begin on the same wave.
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
		driftEmit.Rate = DRIFT_RATE * blend
		for _, e in ipairs(treeEmitters) do
			if e.Parent then
				e.Rate = TREE_RATE * blend
			end
		end
		for _, sp in ipairs(sparkles) do
			sp.emit.Rate = SPARK_RATE * blend
		end
	end

	if blend <= 0.01 then
		return
	end

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end
	local here = hrp.Position

	-- The drift slab, parked upwind and overhead.
	driftPart.CFrame = CFrame.new(here - WIND * DRIFT_BACK + Vector3.new(0, DRIFT_UP, 0))

	-- Sparkle ring. Each emitter is dropped onto whatever the ground actually is
	-- under it -- the cove has boardwalks and rocks in it, and glints floating a
	-- stud above a deck would be the tell.
	for _, sp in ipairs(sparkles) do
		local a = t * SPARK_SPIN + sp.phase
		local x = here.X + math.cos(a) * SPARK_RING
		local z = here.Z + math.sin(a) * SPARK_RING
		sp.part.CFrame = CFrame.new(x, terrainY(x, z, GROUND) + 0.35, z)
	end

	-- Trees: bind or rebind to the island folder, prune emitters whose part has
	-- streamed out from under them, and top the rate up on anything that has
	-- arrived since the last blend change.
	local root = ensureIsland()
	for i = #treeEmitters, 1, -1 do
		local e = treeEmitters[i]
		if not e.Parent then
			table.remove(treeEmitters, i)
		else
			e.Rate = TREE_RATE * blend
		end
	end

	-- The shore survey. Run once per island-folder identity, and retried on a
	-- cooldown while it comes back empty -- which it will, every time, until the
	-- cove's terrain has actually streamed in around the player.
	surveyCooldown -= dt
	if root and not surveying and (shoreBoundTo ~= root or #shoreSegs == 0) and surveyCooldown <= 0 then
		surveyCooldown = 6
		task.spawn(surveyShore, root)
	end

	-- The pulse, travelling along the arc. Rate rather than Transparency,
	-- because changing a live particle's alpha is not something an emitter can
	-- do -- only how many new ones it makes.
	for _, seg in ipairs(shoreSegs) do
		local pulse = 0.55 + 0.45 * math.sin(t * 0.8 - seg.phase)
		seg.emit.Rate = SHORE_RATE * pulse * blend
		if seg.light then
			seg.light.Brightness = 0.85 * pulse * blend
		end
	end
end)

print("[Cove] client ready -- golden hour, pastel water, petals, sparkle, shore glow and gates armed")
