--[[
	AudioKit  --  ReplicatedStorage.Modules.AudioKit

	One place that owns how the game SOUNDS, as opposed to which noises it makes.

	WHY THIS EXISTS
	---------------
	The game had six separate copies of the same four lines -- Instance.new a
	Sound, set an id, set a Volume, Debris it -- in CTB_Client, CTB_HUD,
	ToastKit, FeedbackClient, WeightClient, and both bay controllers. Six copies
	means no shared tuning: no bus, no ducking, no consistent loudness, and every
	repeated sound firing the identical sample at the identical pitch forever.

	THE BRIEF IS "ASMR", AND THAT IS MOSTLY NOT ABOUT WHICH CLIP YOU PICK
	---------------------------------------------------------------------
	Four things do the actual work, and all four live here rather than at the
	call sites:

	  1. PITCH JITTER. The single biggest one. A sound that fires hundreds of
	     times a session (a chunk popping, a swing, a piece of litter) is what
	     turns a texture into a machine gun -- because the ear locks onto the
	     fact that it is one recording. A few percent of random pitch either way
	     and the same clip reads as a real repeated event.

	  2. ROUND ROBIN. Where a slot has more than one recording, alternate them.
	     Jitter hides a repeat; two clips hide it completely.

	  3. A SOFT ATTACK. Starting a Sound at its target Volume puts a step edge
	     at sample zero, and a step edge is a click. Ramping in over 20-60ms is
	     inaudible as a fade and removes the tick entirely. This is why nothing
	     here calls :Play() and walks away.

	  4. THE BUS. Everything lands on ONE SoundGroup carrying a gentle EQ and a
	     compressor. The EQ takes a few dB out of the harsh 1-4kHz band and adds
	     a little air on top -- that is the whole difference between "a sound
	     effect" and "something recorded close". The compressor stops any one
	     transient stabbing out of the mix.

	AND IT FIXES A DEAD SETTING ON THE WAY
	--------------------------------------
	MenuHud's Settings panel drives `BeachSFX.Volume = 0` for its Sound Effects
	toggle, and only Island2_Client and Vault_Client had ever assigned anything
	to that group. Turning SFX off silenced the two side areas and left the rake,
	the sift, the wash, the till and every toast running at full volume. Routing
	through here is what makes that switch mean something -- so this module
	ADOPTS the group by name rather than making its own.

	SoundService itself has no Volume property; a SoundGroup is the only master
	fader Roblox offers, and SoundGroups do not nest. So there is exactly one
	SFX group, and per-category shaping happens on the Sound.
]]

local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local AudioKit = {}

----------------------------------------------------------------------
-- THE BUS
----------------------------------------------------------------------
-- These two names are a CONTRACT with MenuHud's settings panel, which looks
-- them up by name and writes .Volume. Renaming either one silently unhooks a
-- toggle rather than breaking it.
local SFX_GROUP = "BeachSFX"
local MUSIC_GROUP = "BeachMusic"
-- A third bus, for the one set of sounds this game does not author: the
-- engine's default character foley. See STEPS below for why it cannot simply
-- live on BeachSFX.
local STEP_GROUP = "BeachSteps"

local function group(name: string): SoundGroup
	local g = SoundService:FindFirstChild(name)
	if not (g and g:IsA("SoundGroup")) then
		if g then
			g:Destroy()
		end
		g = Instance.new("SoundGroup")
		g.Name = name
		g.Volume = 1
		g.Parent = SoundService
	end
	return g
end

-- Idempotent: re-requiring the module, or a second VM getting here first, must
-- not stack a second EQ on the bus. Found by NAME and overwritten in place.
local function effect(parent: Instance, class: string, name: string, props: { [string]: any })
	local e = parent:FindFirstChild(name)
	if not (e and e:IsA(class)) then
		if e then
			e:Destroy()
		end
		e = Instance.new(class)
		e.Name = name
	end
	for k, v in props do
		(e :: any)[k] = v
	end
	e.Parent = parent
	return e
end

local sfxGroup = group(SFX_GROUP)
group(MUSIC_GROUP)

-- THE ASMR TONE CURVE.
--
-- Roblox's equaliser is three fixed bands, so this is a blunt instrument, but
-- the blunt version is most of the benefit:
--   Low   -1.0  the beach already has plenty of bottom end from the surf bed;
--               a hair off keeps the loops from turning to mud when the pour,
--               the motor and the waves all run at once.
--   Mid   -4.5  the harsh band. Everything that makes a sample sound like a
--               SAMPLE -- the boxy honk of a close mic, the edge on a rock
--               hit -- lives here. This is the line doing the most work.
--   High  +2.5  air. Pulls the crinkle, the grain and the chime tails forward,
--               which is the "recorded six inches away" quality the whole
--               brief is asking for. Any more and sibilant clips get glassy.
effect(sfxGroup, "EqualizerSoundEffect", "AsmrTone", {
	LowGain = -1.0,
	MidGain = -4.5,
	HighGain = 2.5,
	Priority = 0,
	Enabled = true,
})

-- Gentle glue, NOT loudness. A 3.5:1 ratio starting at -18dB with a 20ms
-- attack catches the peak of a chunk pop or a till bell and leaves the quiet
-- granular detail alone -- so the mix keeps its dynamics but nothing ever
-- stabs. GainMakeup returns the few dB the EQ and the compressor took off.
-- Priority is above the EQ so it compresses the already-softened signal.
effect(sfxGroup, "CompressorSoundEffect", "AsmrGlue", {
	Threshold = -18,
	Ratio = 3.5,
	Attack = 0.02,
	Release = 0.18,
	GainMakeup = 3,
	Priority = 1,
	Enabled = true,
})

--[[
	STEPS  --  the engine's own character foley, on its own fader.

	Every character carries a set of Sounds Roblox creates itself -- Running,
	Jumping, Landing, Splash, Climbing, FreeFalling, GettingUp, Died, Swimming
	-- parented to the HumanoidRootPart at Volume 0.65. Running is a LOOP, and
	it is the most-heard sound in any Roblox game by a wide margin.

	0.65 is roughly twice the level of anything in this kit, so left alone the
	default plastic footstep slap would sit on top of the entire mix and undo
	most of the softening below it.

	WHY A SEPARATE GROUP RATHER THAN JUST TURNING THE SOUNDS DOWN
	-------------------------------------------------------------
	Because the volume would not stay down. Roblox's own RbxCharacterSounds
	script owns those instances and rewrites .Volume on every humanoid state
	change, so a one-off assignment survives until the next time the player
	jumps. A SoundGroup is applied on top of whatever that script writes, and
	SoundGroups cannot nest -- hence a third bus rather than a child of the SFX
	one. MenuHud's Sound Effects toggle drives this group alongside BeachSFX so
	the switch still silences everything.

	The clips themselves are left alone deliberately. Roblox's Running sound is
	a looped footstep CADENCE, not a texture, and the licensed library has no
	sand equivalent with a matching loop -- swapping in a granular clip would
	turn walking into a continuous hiss. Level and tone only.
]]
local stepGroup = group(STEP_GROUP)
stepGroup.Volume = 0.45

-- Harder on the mids than the main bus: a footstep's slap lives almost
-- entirely in that band, and it is the one recurring sound here nobody chose.
effect(stepGroup, "EqualizerSoundEffect", "AsmrTone", {
	LowGain = -2.0,
	MidGain = -7.0,
	HighGain = 1.0,
	Priority = 0,
	Enabled = true,
})

--[[
	MUSIC  --  pushed BEHIND the world rather than turned down.

	The soundtrack was already quiet (0.26) and well built -- crossfaded,
	shuffled, slow first fade. What it was not was BACK. Volume alone cannot do
	that: a quiet track with all its presence intact still sits in front of the
	textures, it is just a quiet thing in front of them.

	What puts something behind another thing is losing its top end -- that is
	what distance does to sound in the real world, and the ear reads it as
	distance whatever the level. So:

	  Low   +1.0  a little body back, so it reads as warm rather than thin --
	              rolling off the top without this leaves it weedy.
	  Mid   -2.5  out of the way of the foley, which lives here.
	  High  -4.0  the one that matters. The SFX bus LIFTS its highs by 2.5dB
	              and this drops them by 4, so there is ~6.5dB of separation in
	              the air band between the two. That gap is what lets a paper
	              crinkle or a grain of sand read clearly over a full mix
	              without either one getting louder.
]]
local musicGroup = group(MUSIC_GROUP)

effect(musicGroup, "EqualizerSoundEffect", "AsmrHaze", {
	LowGain = 1.0,
	MidGain = -2.5,
	HighGain = -4.0,
	Priority = 0,
	Enabled = true,
})

--[[
	DUCKING.

	The music group's Volume has exactly ONE owner: this block. It used to be
	written directly by MenuHud's Beach Tunes toggle, which is fine until
	something else wants to move it too -- then the last writer wins and the
	toggle and the duck take turns clobbering each other.

	So the level is a product of two independent things, and both go through
	here: whether the player wants music at all, and how far back it is being
	held right now.

	`sustained` is the standing duck a bay session sets and clears. `dip` is a
	momentary one that restores to whatever `sustained` currently is rather than
	to full -- which is what makes a reveal dip safe if the player walks out of
	the bay while it is still held. Restoring to 1.0 there would have quietly
	undone the session duck.
]]
local musicOn = true
local musicLevel = 1
local sustained = 1
local musicTween: Tween? = nil

local function applyMusic(fade: number?)
	if musicTween then
		musicTween:Cancel()
		musicTween = nil
	end
	local target = musicOn and musicLevel or 0
	if fade and fade > 0 then
		musicTween = TweenService:Create(musicGroup,
			TweenInfo.new(fade, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), { Volume = target })
		musicTween:Play()
	else
		musicGroup.Volume = target
	end
end

-- Called by MenuHud's Beach Tunes toggle instead of it writing .Volume itself.
function AudioKit.setMusicEnabled(on: boolean)
	musicOn = on
	applyMusic(0)
end

-- A standing duck. 1 is full, 0 is silent. Bays hold this for a whole session.
function AudioKit.duckMusic(level: number, fade: number?)
	sustained = math.clamp(level, 0, 1)
	musicLevel = sustained
	applyMusic(fade or 0.8)
end

-- A momentary duck that returns to the standing level, not to full.
function AudioKit.dipMusic(level: number, hold: number?)
	musicLevel = math.clamp(level, 0, 1)
	applyMusic(0.18)
	task.delay(hold or 1.2, function()
		musicLevel = sustained
		applyMusic(1.1)
	end)
end

AudioKit.SfxGroup = sfxGroup
AudioKit.StepGroup = stepGroup
AudioKit.MusicGroup = musicGroup

-- Where 2D (non-positional) one-shots live. A Sound parented anywhere that is
-- not a BasePart or an Attachment plays flat at full volume, which is what a
-- UI tick wants and what a bay loop very much does not.
local flat = SoundService:FindFirstChild("BeachFlatSFX")
if not flat then
	flat = Instance.new("Folder")
	flat.Name = "BeachFlatSFX"
	flat.Parent = SoundService
end

----------------------------------------------------------------------
-- THE LIBRARY
----------------------------------------------------------------------
--[[
	Every id below was loaded in this place and checked for IsLoaded plus a
	non-zero TimeLength before it was written down, and that check is not
	optional paranoia: a Sound with an id that does not resolve DOES NOT THROW.
	It sits there, plays nothing, and the feature just never makes a noise --
	which is the single hardest audio bug to notice, because silence looks
	exactly like "I have not got to that yet".

	All of them are ProSoundEffects, Roblox's own licensed library, so they
	cannot be moderated out from under the game the way a random catalogue
	upload can.

	FIELDS
	  ids     one or more asset ids. More than one = round robin.
	  vol     base volume before the call site's scale
	  pitch   base PlaybackSpeed before jitter and the call site's scale
	  jitter  +/- fraction of pitch applied per shot. 0 for anything tonal.
	  attack  seconds to ramp in from silence. Kills the transient click.
	  minD    studs of full volume around the source (3D only)
	  maxD    studs to silence (3D only)
	  voices  how many pooled Sounds to keep for this slot
	  reverb  optional per-Sound ReverbSoundEffect props, for the chimes
]]
local ROOM = { DecayTime = 1.1, Density = 0.9, Diffusion = 0.85, DryLevel = 0, WetLevel = -11 }

local Lib = {
	----------------------------------------------------------------
	-- LOOPS
	----------------------------------------------------------------
	-- "Rattle, Plastic, Constant" (20.7s). Constant is the operative word --
	-- it is the only rattle in the library with no events in it, so it loops
	-- without a seam to notice. Run down at 0.72 it stops reading as plastic
	-- and turns into a wooden deck being shaken.
	ScreenRattle = { ids = { 9118063120 }, vol = 0.20, pitch = 0.72, loop = true, minD = 6, maxD = 42 },

	-- "Debris Rain, Dirt or Gravel Slide, Loose, Crunchy" (28s). The granular
	-- bed the whole sift rides on, and the longest continuous one available --
	-- length matters for a loop, because a short clip repeats often enough for
	-- the ear to learn it.
	SiftPour = { ids = { 9114034817 }, vol = 0.34, pitch = 1.00, loop = true, minD = 6, maxD = 50 },

	-- "Medium Size Waterfall, Constant Showery White Noise" (56s). A soft
	-- shower rather than a pressure blast: the jet reads as pressure through
	-- its volume and the motor under it, not through hiss.
	WasherSpray = { ids = { 9116496316 }, vol = 0.30, pitch = 1.05, loop = true, minD = 6, maxD = 48 },

	-- "Machine Room, Hospital Machines Presence, Loop" (56s). Chosen over every
	-- literal pump because a real pump has a rhythmic whine in it, and a whine
	-- repeated for a whole session is the definition of fatiguing. This is a
	-- flat warm drone with nothing moving in it.
	WasherMotor = { ids = { 9112825161 }, vol = 0.16, pitch = 0.90, loop = true, minD = 6, maxD = 40 },

	-- A DIFFERENT take from the same gravel session as SiftPour, on purpose:
	-- the rake and the sift are both granular, and the same clip on both makes
	-- the two jobs sound like one job.
	RakeDrag = { ids = { 9114034724 }, vol = 0.22, pitch = 0.78, loop = true },

	-- "Water Lap, Small Waves, Active, Slosh" (31.5s). Lapping, not crashing.
	-- Surf that breaks has a transient in it every few seconds and that is the
	-- opposite of a bed you can leave running for an hour.
	BeachLap = { ids = { 9120570701 }, vol = 0.085, pitch = 0.92, loop = true },

	-- "Middle of Ocean Ambience, Water Movements, Waves, Loop" (56.9s), run
	-- slow and very quiet UNDER the lapping. Two beds at different lengths
	-- never line back up, so the ambience has no audible period at all.
	OceanBed = { ids = { 9112865013 }, vol = 0.055, pitch = 0.80, loop = true },

	----------------------------------------------------------------
	-- GRIT AND IMPACT
	----------------------------------------------------------------
	-- FOUR takes for the one sound that fires most often in the game. Rock
	-- Impacts and Handling Stones, all 0.4-0.5s, all "light" rather than
	-- struck. Round robin across four plus 8% jitter means a player can shell
	-- a whole lump without hearing the same tick twice.
	--
	-- EIGHT voices, not four. A lump is 34 chunks now, and the clip is 0.4s, so
	-- the number sounding at once is 0.4 * the chunks-per-second rate:
	--     Lv1  4.8/s -> ~2 voices      Lv4 12.0/s -> ~5
	--     Lv3  9.2/s -> ~4 voices      Lv6 19.2/s -> ~8
	-- Undersize the pool and the round robin comes back to a voice that is
	-- still playing and cuts it off mid-sample. Eight covers the top tier, and
	-- eight parked Sounds cost nothing.
	ChunkPop = {
		ids = { 9118624649, 9114767957, 9118623491, 9118626273 },
		vol = 0.30, pitch = 1.00, jitter = 0.08, attack = 0.012, voices = 8, minD = 8, maxD = 55,
	},

	-- "Sand Silt, Soft Falling With Some Clumps". Grains landing on wire.
	SandDrop = { ids = { 9118770617 }, vol = 0.26, pitch = 1.05, jitter = 0.10, attack = 0.02, voices = 3, minD = 8, maxD = 50 },

	-- "Sand Slide, Long Skids" (5.3s) -- the heavy pour when the bin goes over.
	BinDump = { ids = { 9118771547 }, vol = 0.42, pitch = 0.88, jitter = 0.05, attack = 0.03, minD = 8, maxD = 60 },

	-- "organic Airy Whooshes, Air Whoosh Bys" (0.94s). Deliberately NOT one of
	-- the racket or dowel swishes -- those all have a thud on the end, and a
	-- thud five times a second for a minute is a drum track. This is air only.
	SwingWhoosh = { ids = { 9117174394 }, vol = 0.16, pitch = 1.00, jitter = 0.06, attack = 0.015, voices = 3, minD = 6, maxD = 38 },

	----------------------------------------------------------------
	-- TOUCH
	----------------------------------------------------------------
	-- "Tissue Paper Movement ... CU". CU is the library's slate for close-up,
	-- and it is audibly that: dry paper crinkle with no room on it, which is
	-- the exact texture the request is asking for. Two lengths, alternated.
	Pickup = { ids = { 9120085244, 9120085398 }, vol = 0.30, pitch = 1.06, jitter = 0.07, attack = 0.02, voices = 3, minD = 8, maxD = 45 },

	-- "Marble Table Hit on Wood, Thuddy Hits". Damped, so there is body
	-- without a crack.
	Mount = { ids = { 9125654847 }, vol = 0.30, pitch = 0.95, jitter = 0.04, attack = 0.015, minD = 8, maxD = 45 },
	-- A penguin, petted. The camel's grunt (already proven to load in this
	-- place) run up nearly an octave, which is what a honk is.
	PenguinHonk = { ids = { 9116298078 }, vol = 0.32, pitch = 1.90, jitter = 0.06, attack = 0.02, minD = 8, maxD = 45 },

	-- The same knock run down to 0.72: a soft closed "no" instead of a buzzer.
	-- A refusal is the one sound a player hears when they are already
	-- frustrated, so it is the last one that should be sharp.
	Reject = { ids = { 9125654847 }, vol = 0.26, pitch = 0.72, jitter = 0.03, attack = 0.02 },

	-- "Hanger, Wooden ... on Wooden Closet Rod" (0.35s). A warm hollow tick.
	WoodTick = { ids = { 9114775311 }, vol = 0.22, pitch = 1.00, jitter = 0.06, attack = 0.01, voices = 3 },

	-- The streak ending is the wood tick pitched down -- the same object, lower,
	-- so it is recognisably the ladder's own sound going the other way.
	StreakBreak = { ids = { 9114775311 }, vol = 0.22, pitch = 0.68, jitter = 0.03, attack = 0.015 },

	--[[
		THE EGG, and both of these are ChunkPop rather than a new upload.

		ChunkPop is already "a hard shell struck and coming away in pieces" -- it
		is what the sifter plays shelling a crusted lump -- which is the same
		physical event a hatching egg is. Run down to 0.72 it gains the size a
		shell the height of a player should have; the round robin across its four
		samples means three knocks in a row are three different cracks.

		NO NEW ASSET ID, and that is deliberate rather than lazy: creator-uploaded
		audio is PRIVATE to the uploading account and fails SILENTLY in a live
		game -- no error, no sound, and a hatch that looks broken. Every id in this
		file is from the licensed catalogue and verified playing in this place, so
		a new sound made out of an old one is the only kind that cannot regress.

		FLAT, no minD/maxD: the hatch is a full-screen sequence played with a nil
		parent, so it is the player's own moment and not something happening at a
		distance out in the world.
	]]
	EggCrack = { ids = { 9118624649, 9114767957, 9118623491, 9118626273 },
		vol = 0.46, pitch = 0.72, jitter = 0.07, attack = 0.008, voices = 4 },

	-- The shell finally going, an octave under the crack and wider. Stacked
	-- under LegendaryHit/FairyDust at the reveal rather than replacing them:
	-- this is the SHELL breaking, those two are the pet arriving.
	EggShatter = { ids = { 9118624649, 9114767957, 9118623491, 9118626273 },
		vol = 0.60, pitch = 0.52, jitter = 0.04, attack = 0.006, voices = 4 },

	-- "Switch, Click On or Off, Toggle Button" (0.23s). The one deliberate
	-- transient in the kit: a UI tap has to be a tap, and softening its attack
	-- makes a button feel unresponsive. Kept quiet instead.
	UIClick = { ids = { 9119717523 }, vol = 0.16, pitch = 1.00, jitter = 0.05, attack = 0, voices = 3 },

	----------------------------------------------------------------
	-- TONE  --  jitter 0, because a wobbling pitch on a tuned sound is
	-- not texture, it is an out-of-tune instrument.
	----------------------------------------------------------------
	-- "Magic Glow, Soft Cluster of Chiming Hits, Ringing, Shimmering" (1.4s).
	ItemCleaned = { ids = { 9116394545 }, vol = 0.34, pitch = 1.00, jitter = 0, attack = 0.03, reverb = ROOM, minD = 10, maxD = 60 },

	-- "Tuning Fork, CU, Pitched at A, Clean Ringing Tone, Minimal Sustain".
	-- Picked specifically BECAUSE it is a single clean partial: the streak
	-- ladder transposes this up a rung at a time, and anything with a cluster
	-- of tones in it turns into a chord when you shift it.
	StreakStep = { ids = { 9120288444 }, vol = 0.24, pitch = 1.00, jitter = 0, attack = 0.02, reverb = ROOM, minD = 10, maxD = 60 },

	-- "Door Chime, Xylophone-Like Single Chime Tone, Bell Hit With Wood
	-- Mallet". A mallet, so it is warm rather than electronic.
	Upgrade = { ids = { 9114132970 }, vol = 0.34, pitch = 1.00, jitter = 0, attack = 0.03, reverb = ROOM },

	-- The big one. Same shimmering-cluster family as ItemCleaned but the
	-- longest take, so a rare find is recognisably the SAME sound the game
	-- always makes, just more of it.
	LegendaryHit = { ids = { 9116394756 }, vol = 0.48, pitch = 1.00, jitter = 0, attack = 0.04, reverb = ROOM, minD = 12, maxD = 80 },

	-- "Fairy Dust, Constant, Light Ringing Clinks" -- layered a beat behind
	-- LegendaryHit so the moment has a tail instead of a stop.
	FairyDust = { ids = { 9114369623 }, vol = 0.24, pitch = 1.00, jitter = 0, attack = 0.06, reverb = ROOM },

	-- "Bell Hits, Small Bell, Single Hits, Soft". A till bell. Chosen over the
	-- library's actual cash registers and slot machines, which all carry a
	-- servo whirr and a lever clack that belong in an arcade.
	Register = { ids = { 9113416142 }, vol = 0.34, pitch = 1.00, jitter = 0, attack = 0.02, reverb = ROOM },

	-- "Bracelet Movement, Shaking, Metallic Jingling, Clinking". Small metal
	-- moving close to a mic. Every literal coin-drop recording in the library
	-- is coins HITTING something, which is percussive; this is the money
	-- sound with the impact taken out of it.
	CoinShower = { ids = { 9113580898 }, vol = 0.26, pitch = 1.15, jitter = 0.05, attack = 0.02, voices = 2 },

	-- "Surf Sweeteners, High Pitch Water Sprays" -- the tide turning.
	Wave = { ids = { 9119678284 }, vol = 0.34, pitch = 0.90, jitter = 0.04, attack = 0.05 },

	--[[
		THE REBIRTH, which is four slots because it is four beats: the ground
		lets go, the climb, the blackout, and the world coming back.

		EVERY ID HERE IS ALREADY IN THIS TABLE ABOVE. That is deliberate and it is
		the whole reason these are named slots rather than four new asset ids: the
		header's warning is that an id which does not resolve makes no noise and
		throws nothing, and the only ids in this place known to survive that check
		are the ones that already passed it. So the rebirth borrows the takes and
		owns its own MIX -- different level, different pitch, different attack --
		which is what a slot is for.
	]]

	-- BinDump's granular whump, dropped to a groan. The ground letting go.
	TideLaunch = { ids = { 9118771547 }, vol = 0.46, pitch = 0.42, jitter = 0.02, attack = 0.01, reverb = ROOM },

	-- WasherMotor's hum, LOOPED and pitch-ramped by the caller from about 0.6 to
	-- 2.0 across the climb. A riser is not a sample, it is a sustained tone
	-- someone drags upward -- and this is the only steady-state take in the kit
	-- long enough to drag.
	TideRiser = { ids = { 9112825161 }, vol = 0.30, pitch = 0.60, loop = true },

	-- LegendaryHit an octave down: the same shimmering cluster the game already
	-- uses for a big moment, made into an impact rather than a sparkle. Lands on
	-- the blackout.
	TideBoom = { ids = { 9116394756 }, vol = 0.52, pitch = 0.50, jitter = 0, attack = 0.005, reverb = ROOM },

	-- The door chime, up a fifth and soft, under the REBIRTH card. Pitched above
	-- Upgrade's own so a rebirth is audibly not just another purchase.
	TideArrive = { ids = { 9114132970 }, vol = 0.30, pitch = 1.50, jitter = 0, attack = 0.05, reverb = ROOM },
}

AudioKit.Lib = Lib

----------------------------------------------------------------------
-- PLUMBING
----------------------------------------------------------------------

local function enabled(): boolean
	local p = Players.LocalPlayer
	-- Absent attribute means "not set yet", which is ON. Only an explicit false
	-- from the settings panel silences anything.
	return not (p and p:GetAttribute("Set_SFX") == false)
end

local function idOf(n: number): string
	return "rbxassetid://" .. n
end

-- Shapes a Sound to a slot. Everything that makes a Sound in this module goes
-- through here, so there is one definition of what a slot sounds like.
local function dress(s: Sound, def, assetId: number)
	s.SoundId = idOf(assetId)
	s.SoundGroup = sfxGroup
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = def.minD or 8
	s.RollOffMaxDistance = def.maxD or 45
	if def.reverb then
		effect(s, "ReverbSoundEffect", "Halo", def.reverb)
	end
	return s
end

-- Voice pools, keyed by slot. A pool is rebuilt when its parent changes, which
-- in practice happens once per bay a player walks up to.
local pools: { [string]: any } = {}

local function poolFor(name: string, def, parent: Instance)
	local p = pools[name]
	if p and p.parent == parent and parent.Parent then
		return p
	end
	if p then
		for _, s in p.voices do
			if s and s.Parent then
				s:Destroy()
			end
		end
	end
	local n = def.voices or 2
	p = { parent = parent, turn = 0, voices = table.create(n) }
	for i = 1, n do
		local s = Instance.new("Sound")
		s.Name = "AK_" .. name .. i
		s.Volume = 0
		dress(s, def, def.ids[1])
		s.Parent = parent
		p.voices[i] = s
	end
	pools[name] = p
	return p
end

--[[
	play(name, parent, volScale, pitchScale)

	parent nil  -> flat 2D, for UI and anything that should sit against the ear
	parent part -> positional, rolled off by the slot's own distances

	The two scales multiply the slot's base, so a call site says "a bit louder
	than usual" rather than restating an absolute number the kit is trying to
	own. Returns the Sound so a caller can chain something off .Ended.
]]
function AudioKit.play(name: string, parent: Instance?, volScale: number?, pitchScale: number?): Sound?
	local def = Lib[name]
	if not def or not enabled() then
		return nil
	end

	-- Round robin across however many takes the slot has.
	local ids = def.ids
	local assetId = ids[1]
	if #ids > 1 then
		def._turn = ((def._turn or 0) % #ids) + 1
		assetId = ids[def._turn]
	end

	-- +/- jitter, so the same clip is never the same twice.
	local j = def.jitter or 0
	local pitch = (def.pitch or 1) * (pitchScale or 1)
	if j > 0 then
		pitch *= 1 + (math.random() * 2 - 1) * j
	end
	local vol = (def.vol or 0.3) * (volScale or 1)

	local s: Sound
	if parent and (parent:IsA("BasePart") or parent:IsA("Attachment")) then
		-- Hot positional slots keep a pool; the rest are cheap enough to spawn.
		if def.voices then
			local p = poolFor(name, def, parent)
			p.turn += 1
			s = p.voices[(p.turn % #p.voices) + 1]
			s.SoundId = idOf(assetId)
			s.TimePosition = 0
		else
			s = dress(Instance.new("Sound"), def, assetId)
			s.Parent = parent
			Debris:AddItem(s, math.min(s.TimeLength / math.max(pitch, 0.1) + 1, 12))
		end
	else
		s = dress(Instance.new("Sound"), def, assetId)
		s.Parent = flat
		Debris:AddItem(s, math.min(s.TimeLength / math.max(pitch, 0.1) + 1, 12))
	end

	s.PlaybackSpeed = pitch

	-- THE SOFT ATTACK. Starting at the target volume puts a step edge at sample
	-- zero and a step edge is a click -- audible on every single shot, and the
	-- reason untreated one-shots sound brittle no matter how good the clip is.
	local attack = def.attack or 0
	if attack > 0 then
		s.Volume = 0
		s:Play()
		TweenService:Create(s, TweenInfo.new(attack, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
			{ Volume = vol }):Play()
	else
		s.Volume = vol
		s:Play()
	end
	return s
end

--[[
	loop(name, parent) -> handle

	Starts silent and playing. The caller drives it every frame:

		h:set(volScale, pitchScale, dt)

	Volume is SMOOTHED toward the target rather than assigned, because a loop
	whose gain is written raw off a per-frame gameplay number chatters -- the
	very thing that makes a mix sound cheap. Pitch is assigned directly; pitch
	is a texture here, not a level, and lag on it feels like latency.
]]
function AudioKit.loop(name: string, parent: Instance?)
	local def = Lib[name]
	if not def then
		return nil
	end
	local s = dress(Instance.new("Sound"), def, def.ids[1])
	s.Name = "AK_" .. name
	s.Looped = true
	s.Volume = 0
	s.PlaybackSpeed = def.pitch or 1
	s.Parent = (parent and (parent:IsA("BasePart") or parent:IsA("Attachment"))) and parent or flat
	s:Play()

	local h = { sound = s, target = 0 }

	function h:set(volScale: number, pitchScale: number?, dt: number?)
		if not s.Parent then
			return
		end
		self.target = (def.vol or 0.3) * volScale * (enabled() and 1 or 0)
		local k = dt and math.min(dt * 9, 1) or 1
		s.Volume += (self.target - s.Volume) * k
		if pitchScale then
			s.PlaybackSpeed = (def.pitch or 1) * pitchScale
		end
	end

	-- Fade, then destroy. Cutting a loop dead leaves the same click at the tail
	-- that the soft attack removes at the head.
	function h:stop(fade: number?)
		if not s.Parent then
			return
		end
		local f = fade or 0.25
		TweenService:Create(s, TweenInfo.new(f), { Volume = 0 }):Play()
		Debris:AddItem(s, f + 0.1)
	end

	return h
end

-- Two clips on one beat, the second a touch behind. Layering is how a reward
-- gets weight without just getting louder.
function AudioKit.stack(a: string, b: string, parent: Instance?, gap: number?, volScale: number?)
	AudioKit.play(a, parent, volScale)
	task.delay(gap or 0.09, function()
		AudioKit.play(b, parent, volScale)
	end)
end

--[[
	ADOPTION  --  the sounds this module did not make.

	Not everything audible is built through here. Island2Builder creates the
	stone door's grind, clunk and refusal on the SERVER, and there is a Sound
	baked into Workspace.Island2.Entrance.Door in the place file itself. A
	server-made Sound cannot be given a SoundGroup by the server, because the
	bus is created per-client -- so all of those replicate down with no group at
	all, which means they miss the tone curve AND, more importantly, ignore the
	Settings panel's Sound Effects toggle exactly the way the whole main game
	used to.

	So the client sweeps them up: anything in the world that is a Sound and has
	no group of its own gets put on the SFX bus. Only ever nil -> BeachSFX, so
	a Sound that has deliberately chosen a group (the music, everything built
	above) is left alone.
]]
-- The engine's character foley, by name. Matching on the name set rather than
-- on the parent is deliberate: these are the exact instances RbxCharacterSounds
-- owns, and anything else sitting on a HumanoidRootPart belongs to this game.
local CHARACTER_SOUNDS = {
	Running = true, Jumping = true, Landing = true, Splash = true, Climbing = true,
	FreeFalling = true, GettingUp = true, Died = true, Swimming = true,
}

local function adopt(d: Instance)
	if d:IsA("Sound") and d.SoundGroup == nil then
		local parent = d.Parent
		if CHARACTER_SOUNDS[d.Name] and parent and parent.Name == "HumanoidRootPart" then
			d.SoundGroup = stepGroup
		else
			d.SoundGroup = sfxGroup
		end
	end
end

if RunService:IsClient() then
	for _, d in workspace:GetDescendants() do
		adopt(d)
	end
	workspace.DescendantAdded:Connect(adopt)
end

-- Warms the whole library so the first pop of a session is not a silent one --
-- an unloaded Sound plays nothing rather than waiting. Safe to call twice.
function AudioKit.preload()
	task.spawn(function()
		local holder = Instance.new("Folder")
		holder.Parent = flat
		for _, def in Lib do
			for _, id in def.ids do
				local s = Instance.new("Sound")
				s.SoundId = idOf(id)
				s.Parent = holder
			end
		end
		pcall(function()
			game:GetService("ContentProvider"):PreloadAsync({ holder })
		end)
		holder:Destroy()
	end)
end

return AudioKit
