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
		(the gate lock that used to be listed here is gone with the gates
		themselves -- crossing to the beach is the ferry's job now, and
		FerryClient owns the ferryman's panel, the requirement it states and
		the fade across the water)

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
local Debris = game:GetService("Debris")
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
-- The same pink, weakened, for the one place it covers the WHOLE frame. Full
-- BLOSSOM as a screen tint stacked with pink ambient, pink haze and pink sand
-- and left nothing in the picture that was not pink. Everything that IS
-- blossom -- petals, lanterns, the shore glow -- still uses BLOSSOM itself.
local GRADE_TINT = Color3.fromRGB(255, 232, 238)
-- The brief's own pastel turquoise, #AEC6CF = (174,198,207), used to be a
-- constant here and to be the sea's colour. It is gone from both: see the note
-- on COVE_WATER for the measurement that took it out.

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
--
-- WARM IS THE POINT; BRIGHT WAS NOT, AND THIS WAS BOTH. At (198,150,156) the
-- ambient was a flood lamp -- most of the light on most of the cove came from
-- a source with no direction in it, so nothing had a shaded side and the whole
-- island read as one flat wash. Everything the note above argues for is about
-- the HUE, and the hue is kept exactly; only the level comes down.
local COVE_OUT = Color3.fromRGB(150, 124, 132)
local COVE_AMB = Color3.fromRGB(66, 50, 58)

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
--
-- HAZE WAS THE OTHER HALF OF THE WHITE-OUT. At 1.62 the far side of the market
-- plaza -- sixty studs, not a distance -- was already half dissolved into pink
-- milk, and Glare 0.34 put a bloom over the frame on top of it. The sunset
-- work is done by Colour and Decay, exactly as the note above says; those two
-- were only costing legibility. Density, which that note is careful about,
-- barely moves.
--[[
	DECAY IS PULLED OFF MAGENTA -- AND ONLY DECAY.

	Everything the notes above argue for is kept: warm ambient, the blossom tint,
	saturation up rather than down, density barely moved. Those are the island's
	art direction and they are right.

	What was measured on the ground is that the FIELD is hard to read. The cove's
	pink lands on top of a global grade already running Saturation +0.18, and the
	resulting net at the player was tint (1.00, 0.90, 0.90) at Saturation +0.23 --
	so the sand renders a deep dusty rose, and a lot of the cove's own litter
	(paper cups, onigiri wrap, gacha capsules, fans) is pale pink on it. That is
	the worst figure-to-ground pairing of any field in the game, and this is a
	game about spotting small objects on sand.

	Decay is the lever because it is the one that acts at DISTANCE -- it tints the
	whole far half of the frame, which is most of the field you are scanning. At
	(168,122,132) red sat 46 above green and 36 above blue, which is a magenta,
	not a rose. (172,142,146) keeps it unmistakably warm and pink against the
	beach's cold blue-grey (92,124,160) -- the comparison the note above cares
	about -- while taking the violet out of the far sand.

	If this reads as too neutral on a big screen, this line is the one to put
	back; nothing else here was touched.
]]
local COVE_ATMO = {
	Density = 0.28, Haze = 0.75, Glare = 0.12,
	Color = Color3.fromRGB(255, 224, 226),
	Decay = Color3.fromRGB(172, 142, 146),
}

--[[
	WHAT A BLOSSOM STORM DOES TO THE LIGHT, and it is the half of the hanami that
	was missing.

	MEASURED AGAINST THE DUNES, which is the stated bar. Its storm is not mostly
	particles at all -- STORM_ATMO runs Density 0.58 and HAZE 5.4, and its note
	says the point out loud: "Losing the landmark IS the sandstorm." The pyramid
	goes. That wall of brown across the frame is weather, not dust sprites.

	The cove's gust was adding 0.06 of density and NOTHING to haze, on the
	argument (see applyBlend) that "the petals themselves are doing the work".
	Photographed at the design peak, they were not: the bay read as a handful of
	specks against a clear blue sky.

	So the cove loses its landmark too, for three seconds -- but in the opposite
	direction. Airborne dust is a grey-brown filter and these values go DOWN in
	value; airborne blossom is a pale pink one and these go UP. Density lands on
	the same 0.58 the desert storm uses; haze stops well short of its 5.4, because
	pink saturates far faster than brown (the long note above records 1.62 reading
	as "pink milk" as a RESTING value -- which is what makes it right for a peak
	that lasts three seconds and wrong for a look you stand in).
]]
local GUST_OUT = Color3.fromRGB(238, 198, 210)
local GUST_AMB = Color3.fromRGB(152, 118, 132)
local GUST_DENSITY = 0.30      -- added on top of COVE_ATMO's 0.28 -> 0.58
local GUST_HAZE = 2.60         -- 0.75 -> 3.35

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
-- CONTRAST GOES UP, which reverses what this block used to say. The old
-- argument -- golden hour is a low-contrast light, so do not push contrast --
-- is true of the LIGHT and was being applied on top of an ambient flood and a
-- 1.62 haze that had already taken out what contrast the scene had. With those
-- two at honest values the grade is no longer propping up a wash, and a little
-- contrast is what separates the plaza from the sand behind it. Brightness
-- goes slightly negative for the same reason: the frame does not need lifting.
--[[
	`gust` IS THE HANAMI: 0 at rest, 1 at the peak of a blossom storm. A second
	PARAMETER rather than a second writer, for the reason this file gives about
	everything else it touches -- two things writing one ColorCorrection is how
	you get a look that depends on which of them ran last.
]]
local function applyBlend(a: number, gust: number?)
	local g = gust or 0
	grade.Brightness = -0.02 * a + 0.030 * g
	grade.Contrast = 0.06 * a - 0.020 * g
	grade.Saturation = 0.05 * a + 0.100 * g
	-- toward GRADE_TINT: full green and blue at a = 0, pulled down to the pale
	-- pink's own ratios at a = 1. See the note on GRADE_TINT for why this is not
	-- BLOSSOM any more.
	local tg = 1 - (1 - GRADE_TINT.G) * a
	local tb = 1 - (1 - GRADE_TINT.B) * a
	-- AND IN A GUST IT GOES THE REST OF THE WAY TO BLOSSOM -- which that same
	-- note rules out as a RESTING grade precisely because it puts pink over the
	-- whole frame and leaves nothing in the picture that is not pink. For three
	-- seconds, with the air full of petals, that is the correct picture.
	grade.TintColor = Color3.new(
		1,
		tg + (BLOSSOM.G - tg) * g,
		tb + (BLOSSOM.B - tb) * g
	)

	-- The gust takes the LIGHT as well as the air -- see GUST_OUT. Lerped last so
	-- it rides on top of whatever the island blend has already decided, exactly as
	-- the Dunes layers STORM_OUT_C over DESERT_OUT.
	Lighting.OutdoorAmbient = HOME_OUT:Lerp(COVE_OUT, a):Lerp(GUST_OUT, g)
	Lighting.Ambient = HOME_AMB:Lerp(COVE_AMB, a):Lerp(GUST_AMB, g)

	if atmo and HOME_ATMO then
		-- A GUST THICKENS THE AIR, AND IT HAS TO DO IT PROPERLY. This used to add
		-- 0.06 of density and no haze at all, on the argument that "the petals
		-- themselves are doing the work here" -- which a screenshot at the design
		-- peak disproved. Both numbers are argued at GUST_DENSITY / GUST_HAZE.
		--
		-- SCALED BY `a` AS WELL AS `g`, which the old line was not. Without it a
		-- player who walks off the cove mid-gust takes 0.3 of pink density with
		-- them onto the beach -- the same trap the Dunes' own note about `s` being
		-- scaled by `a` records, and it is a real one here because the gust runs
		-- for 7.5s and the island fade is 2.4s.
		local g2 = g * a
		atmo.Density = HOME_ATMO.Density + (COVE_ATMO.Density - HOME_ATMO.Density) * a
			+ GUST_DENSITY * g2
		atmo.Haze = HOME_ATMO.Haze + (COVE_ATMO.Haze - HOME_ATMO.Haze) * a
			+ GUST_HAZE * g2
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

--[[
	GROW A PETAL SPRITE WITH THE GUST, and this is the single change that made the
	hanami read as a storm rather than as dust on the lens.

	Every petal in this file was pinned under 0.6 studs -- drift 0.42, front body
	0.58, front edge 0.36. A 0.6-stud sprite sixty studs away is smaller than a
	pixel, so at the design peak of 250 particles a second the bay photographed as
	a scattering of specks. THERE IS NO RATE THAT FIXES THAT. The Dunes ramps its
	sand 2..9 -> 9..31 for exactly this reason and its front is a third denser.

	Two keypoints in, two out, so the taper the resting sequence carries survives
	rather than being flattened to a single size.
]]
local function petalSize(head: number, tail: number, g: number, mul: number): NumberSequence
	local k = 1 + g * (mul - 1)
	return NumberSequence.new(head * k, tail * k)
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
-- HANAMI
--
-- The cove's half of the tide, and the mechanic was already there: CTB_Server
-- clears the grid once the player has raked it, re-seeds the litter, pays
-- `resetBonus` and fires "Tide" carrying this island's own resetName -- which
-- for the cove has always been HANAMI, blossom viewing. The word shipped with
-- the island and nothing ever happened when it landed. The Dunes got its
-- sandstorm and Ashfall its eruption; the cove got a banner.
--
-- SO THE TREES LET GO ALL AT ONCE. Deliberately not a new effect standing
-- beside the petals: it is the three layers this file already draws -- the
-- drift overhead, the fall from every PetalSource the builder planted, the glow
-- on the waterline -- opened right up together, with a front of blossom
-- crossing the bay on top of them. Same event as the desert's storm and the
-- same three-phase shape. What makes it the cove's is that a sandstorm is
-- weather you shelter from, and this is the thing people travel to stand in.
--
-- IT RUNS WITH THE ISLAND'S OWN WIND, the same rule the Dunes states. WIND is
-- what the drift already blows along and what every petal already accelerates
-- down; a front crossing at any other angle reads as a prop, not as weather.
--
-- THE BUDGET, in the same terms as the resting one written down further up.
-- Live count is roughly rate * lifetime, at the peak of a gust:
--     drift    14 * 6.5 * 4.5 avg   ~410   (rate up, LIFETIME DOWN -- see the
--                                           note at the drift write)
--     trees   1.5 * 6 * 12 * 7      ~756
--     front    220 * 3.6 + 150 * 1.7 ~1,047
-- about 2,200 live for three seconds against ~360 at rest -- the same order as
-- the Dunes' storm, and like it only ever on an island the player has travelled
-- to. It is off entirely the moment they leave.
--
-- THE COUNT BARELY MOVED WHEN THIS WAS MADE VISIBLE, which is the point worth
-- keeping: the old numbers were ~1,950 live and photographed as nothing. What
-- was wrong was SIZE, not volume -- see petalSize. Raising the rates further
-- would have cost frames and bought no more picture.
----------------------------------------------------------------
local HANAMI_IN, HANAMI_HOLD, HANAMI_OUT = 1.1, 3.0, 3.4
local HANAMI_LEN = HANAMI_IN + HANAMI_HOLD + HANAMI_OUT

local GUST_LEN, GUST_H = 420, 60
local GUST_Y = 0.34            -- fraction of GUST_H above the ground the centre sits
local GUST_TRAVEL = 620

local hanamiT = -1             -- seconds since the gust was released; < 0 = still
local gust = 0                 -- 0 .. 1 .. 0 across the three phases

--[[
	THE BAY IS MEASURED ON EVERY RELEASE, never captured once at file scope.

	An island row is DERIVED -- Config computes half, cells, x0 and z0 off grid
	and centre -- and this one demonstrably moves: the cove's grid went 48 -> 96
	and its centre 1500 -> 1596 underneath a running session while this was being
	written. A front that had cached the old bay would have blown across open
	water a hundred studs south of the island, which reads as a broken effect
	rather than as a stale number.
]]
local function gustOrigin(): Vector3
	return Vector3.new(COVE.cx, GROUND + GUST_H * GUST_Y, COVE.cz)
		- WIND * (GUST_TRAVEL * 0.5)
end

local gustFrom = gustOrigin()

local function gustCFrame(p: number): CFrame
	local at = gustFrom + WIND * (GUST_TRAVEL * p)
	return CFrame.lookAt(at, at + WIND)
end

local gustFront = Instance.new("Part")
gustFront.Name = "Hanami"
gustFront.Size = Vector3.new(GUST_LEN, GUST_H, 14)   -- really sized on release, below
gustFront.Transparency = 1
gustFront.Anchored, gustFront.CanCollide, gustFront.CanQuery, gustFront.CanTouch = true, false, false, false
gustFront.CastShadow = false
gustFront.CFrame = gustCFrame(0)
gustFront.Parent = fx

-- Dressed as petals FIRST and then overridden, so the flatten, the tumble, the
-- drag and the FacingCamera orientation are demonstrably the same ones the
-- drift and the trees use. A gust made of subtly different petals would read as
-- a second, worse effect playing over the first.
local function gustLayer(props): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	dressPetals(e)
	-- gustCFrame points the part's -Z downwind, and Front IS -Z.
	e.EmissionDirection = Enum.NormalId.Front
	for k, v in props do
		e[k] = v
	end
	e.Parent = gustFront
	return e
end

-- The body: big, slow, and the layer the player ends up standing inside.
local gustBody = gustLayer({
	Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.58),
		NumberSequenceKeypoint.new(1, 0.46),
	}),
	Lifetime = NumberRange.new(2.6, 4.6),
	Speed = NumberRange.new(16, 40),
	SpreadAngle = Vector2.new(46, 24),
	Acceleration = WIND * 5.0 + Vector3.new(0, -3.4, 0),
	Drag = 1.5,
	ZOffset = -2,
})

-- The leading flurry: smaller, quicker, and PALE INTO BLOSSOM rather than the
-- other way round, so the edge arriving first reads lighter than the mass
-- behind it.
local gustEdge = gustLayer({
	Color = ColorSequence.new(PETAL_PALE, BLOSSOM),
	Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.36),
		NumberSequenceKeypoint.new(1, 0.28),
	}),
	Lifetime = NumberRange.new(1.2, 2.2),
	Speed = NumberRange.new(52, 96),
	SpreadAngle = Vector2.new(24, 12),
	Acceleration = WIND * 8.0 + Vector3.new(0, -2.0, 0),
	Drag = 2.4,
	ZOffset = 1,
})

--[[
	TWO ONE-SHOTS ON THEIR OWN INSTANCES, never the looping beds -- those four
	are the cove's ambience and have to be exactly where they were when it is
	over.

	Both ids are already resolving and playing in this place: the furin is this
	file's own chime bed and the wind is the one Island2_Client's sandstorm
	uses, so they are covered by the check the ambience block above describes and
	do not need re-verifying. The chime runs at FULL speed rather than the bed's
	0.86 -- a furin sitting under the surf is what makes it ambience, and a gust
	is the one moment it is allowed on top of it.
]]
local function gustSound(id: string, speed: number, volume: number)
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.PlaybackSpeed = speed
	s.SoundGroup = sfxGroup
	s.Parent = SoundService
	s:Play()
	Debris:AddItem(s, 14)
end

-- 0 .. 1 .. 0 across the three phases, the same shape the Dunes' storm uses.
local function hanamiAmount(t: number): number
	if t < 0 then
		return 0
	elseif t < HANAMI_IN then
		return t / HANAMI_IN
	elseif t < HANAMI_IN + HANAMI_HOLD then
		return 1
	end
	return math.max(0, 1 - (t - HANAMI_IN - HANAMI_HOLD) / HANAMI_OUT)
end

-- One expression, two callers: the blend write and the per-frame prune below
-- both set this and they must not be able to disagree.
local function treeRate(): number
	return TREE_RATE * blend * (1 + gust * 6)
end

local function startHanami()
	-- Already blowing. The server rate-limits a reset to one per six seconds so
	-- this cannot happen today, but restarting the timer would snap the blossom
	-- back to nothing for a frame if it ever could.
	if hanamiT >= 0 then
		return
	end
	-- Re-measured, and the front re-sized to whatever the bay is now: long enough
	-- across the wind to cover the whole field with room at each end, because a
	-- gust you can see the end of is a prop.
	gustFrom = gustOrigin()
	gustFront.Size = Vector3.new(math.max(GUST_LEN, COVE.half * 2 + 90), GUST_H, 14)
	gustFront.CFrame = gustCFrame(0)
	hanamiT = 0
	gustSound("rbxassetid://9118747853", 1.15, 0.30)   -- the breeze getting up
	gustSound("rbxassetid://9120750072", 1.00, 0.22)   -- and the furin answering it
end

local function stepHanami(dt: number)
	if hanamiT < 0 then
		return
	end
	hanamiT += dt
	if hanamiT >= HANAMI_LEN then
		hanamiT = -1
		gust = 0
		gustBody.Rate, gustEdge.Rate = 0, 0
		return
	end
	gust = hanamiAmount(hanamiT)
	-- Straight across the bay, and it KEEPS GOING through the clearing phase --
	-- see the Dunes' note on the same line: a front that stops dead over the
	-- player and fades on the spot reads as a machine being switched off.
	gustFront.CFrame = gustCFrame(hanamiT / HANAMI_LEN)
	gustBody.Rate = 220 * gust
	gustEdge.Rate = 150 * gust
	-- AND THE PETALS THEMSELVES GROW. See petalSize -- ramping rate alone is what
	-- made a 250-a-second front invisible from across the bay.
	gustBody.Size = petalSize(0.58, 0.46, gust, 5.6)
	gustEdge.Size = petalSize(0.36, 0.28, gust, 4.8)
end

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
local lastBlend, lastGust = -1, -1

-- Same remote CTB_Client listens on, and keyed off the ISLAND rather than off
-- the word "HANAMI" exactly as the Dunes keys off DUNES.id: this file is the
-- cove's weather, and renaming the event in Config should not silently switch
-- the blossom off. Gated on being here, because a petal storm nobody is
-- standing in is two thousand particles spent on an empty bay.
local ctbNet = ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Net")
ctbNet.OnClientEvent:Connect(function(action, islandId)
	if action == "Tide" and islandId == COVE.id and onIsland then
		startHanami()
	end
end)

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
	end

	-- THE FRONT, advanced before the write below so a gust that has just ended
	-- gets its final gust = 0 in the same frame rather than one frame late.
	stepHanami(dt)

	-- ONE write per changed frame, and it covers the GUST as well as the blend.
	-- Everything below used to sit inside the `blend ~= target` branch, so it was
	-- correct on arrival and then frozen -- which meant a hanami could not have
	-- opened the trees up however hard it asked.
	if blend ~= lastBlend or gust ~= lastGust then
		lastBlend, lastGust = blend, gust
		applyBlend(blend, gust)

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
		-- EVERYTHING THIS FILE ALREADY DRAWS, OPENED UP AT ONCE. A hanami is not a
		-- new effect bolted on beside the petals; it IS the petals, several times
		-- over, for a few seconds.
		--[[
		THE NEAR LAYER IS WHAT FILLS THE SCREEN, so the gust takes all four of its
		dials rather than only the rate.

		The Dunes' equivalent is `sandEmit`, and it is worth quoting because it is the
		bar: rate (24 + storm * 420), size 2..9 -> 9..31, speed 30..52 -> 76..130. This
		one was rate 14 -> 70 and nothing else, with 0.42-stud petals.

		LIFETIME COMES DOWN AS THE RATE GOES UP, and that is not a detail. At the
		resting 8..14 seconds a rate of 90 would put roughly a THOUSAND live petals in
		this one layer -- and it would be wrong anyway: a petal ripped off a tree in a
		gust does not hang in the air for fourteen seconds. Shortened, the peak lands
		near 400, which is the same order as the front.
	]]
	driftEmit.Rate = DRIFT_RATE * blend * (1 + gust * 5.5)
	driftEmit.Size = petalSize(0.42, 0.34, gust, 6.2)
	driftEmit.Speed = NumberRange.new(1.0 + gust * 11, 3.2 + gust * 31)
	driftEmit.Lifetime = NumberRange.new(8 - gust * 5, 14 - gust * 8)
		for _, e in ipairs(treeEmitters) do
			if e.Parent then
				e.Rate = treeRate()
			end
		end
		for _, sp in ipairs(sparkles) do
			sp.emit.Rate = SPARK_RATE * blend * (1 + gust * 2)
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
			e.Rate = treeRate()
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
		-- The gust reaches the waterline too. A blossom storm that left the one
		-- lit edge of the island at its resting brightness would read as weather
		-- happening in front of a photograph.
		seg.emit.Rate = SHORE_RATE * pulse * blend * (1 + gust * 1.8)
		if seg.light then
			seg.light.Brightness = 0.85 * pulse * blend * (1 + gust * 1.4)
		end
	end
end)

print("[Cove] client ready -- golden hour, pastel water, petals, sparkle, shore glow and hanami armed")
