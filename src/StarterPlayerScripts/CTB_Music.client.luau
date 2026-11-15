--[[
	CTB_Music  --  StarterPlayerScripts.CTB_Music

	The soundtrack. Quiet, gapless, and never the same order twice.

	WHY THESE TRACK IDS WORK
	------------------------
	Since Roblox's 2022 audio privacy change, audio uploaded by an ordinary
	creator is PRIVATE to that creator and will not play in anyone else's
	experience -- it fails silently, which is the worst possible failure for a
	background track nobody is listening for. Every id below is from Roblox's own
	licensed catalogue (APM Music and Distrokid), which is cleared for use in any
	experience. All six were loaded in this place and their durations measured
	before the list was cut to them; do not add an id here without checking it
	reports a TimeLength greater than zero.

	WHAT MAKES IT SOOTHING RATHER THAN JUST PRESENT
	-----------------------------------------------
	Six things, and the volume is still the least of them. The two newest live
	in AudioKit rather than in this file, because they are mix decisions rather
	than playlist ones:

	  * A TONE CURVE ON THE BUS. AudioKit hangs an equaliser on the BeachMusic
	    group that takes 4dB off the top end, while the SFX bus LIFTS its own by
	    2.5 -- about 6.5dB of separation in the air band. Losing its highs is
	    what makes something sound FAR AWAY; that is what distance does to sound
	    in the real world, and the ear reads it that way whatever the level. So
	    the music now sits BEHIND the beach rather than being a quiet thing in
	    front of it, which is a distinction volume alone cannot buy.

	  * DUCKING at the sifting and wash bays, and a momentary dip under a find
	    being revealed. Those are the closest, most detailed moments in the
	    game, and music at full level does not drown the grain so much as
	    FLATTEN it -- the ear stops picking out individual grains and hears one
	    wash of noise instead. See AudioKit.duckMusic / dipMusic.

	Note that the group's Volume is no longer written here or by MenuHud: it has
	two independent inputs now (the Beach Tunes toggle and the bay duck) and
	AudioKit owns the multiply, because with two writers the last one to touch
	it wins and each would keep cancelling the other.

	And the four this file has always had:

	  * CROSSFADES, not cuts. The next track is already rising before the last
	    one has gone, so the music never stops and never restarts -- there is no
	    moment of silence to notice, and noticing is what breaks the spell.
	  * A SHUFFLE BAG, not random choice. Every track plays once before any plays
	    twice, and a reshuffle can never repeat the track that just ended. Plain
	    randomness clusters, and hearing the same piece twice in five minutes is
	    what makes a loop feel small.
	  * A SLOW FIRST FADE. Music that slams in on spawn reads as an event. Eight
	    seconds in from silence and it feels like it was always there.
	  * SITTING UNDER THE WORLD. At 0.26 it is below the sea ambience and well
	    below the sifter, so it colours the beach rather than competing with it.

	The Settings panel's Beach Tunes toggle already drives a SoundGroup called
	"BeachMusic" (see MenuHud.applySetting), so everything here is parented to
	that group and the existing switch works with no changes on its side.
]]

local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

--[[
	Roblox licensed catalogue only -- see the header before adding to this list.

	SIX TRACKS, AND THEY WERE PICKED BY EAR
	---------------------------------------
	That is the important thing about this list, and the reason it is half the
	length it used to be.

	It used to be eleven, and not one of them had been listened to. Eight were
	chosen on their TITLES alone -- "Quiet Flow" was on the list because it is
	called Quiet Flow -- and the other three on the publisher's written blurb.
	Both of those are guesses. These six are what survived somebody actually
	sitting in the game and hearing the pool, which is worth more than every
	description in the catalogue put together.

	SO DO NOT "RESTORE" THE OTHER FIVE. They were not lost, they were cut:

	  * "Dawn" (1838792473), "Deeper Meaning" (1836903824) and "For I Have"
	    (1837977637) -- the three oldest APM entries, all title-only picks.
	  * "In Depth" (9044722661) -- APM's copy calls it "pulsing", and the note
	    on the old list already flagged it as the one of the three most likely
	    to read as ACTIVE rather than as a bed. It did.
	  * "Neutral Flow" (9039600440) -- "ethereal glassy pads".

	All five still load and still play; none of this is a technical failure. They
	are simply not the feel this game is going for, and re-adding one because its
	description reads well is exactly how the list gets back to eleven tracks
	nobody has heard.

	WHAT THE CUT COSTS, ON THE RECORD
	---------------------------------
	The rotation is now about TWELVE minutes before anything repeats, down from
	about twenty-four. The longer the cycle, the less the music reads as a loop
	at all -- so this is a real trade and it was made deliberately: six tracks
	that suit the game beat eleven that half suit it. If twelve minutes starts to
	feel tight, the fix is to widen the pool with MORE OF THIS CHARACTER -- warm,
	slow, no pulse -- and not to put the cut ones back.

	WHAT WAS DELIBERATELY LEFT OUT of the original search, and why, so it is not
	re-run:
	  * "Eternal Ice" (9042042581) -- same album as Comfort and structurally
	    ideal, but the copy says "Icy ... heavenly HIGH string drones". A cold,
	    bright, upper-register pad is the wrong palette for a sunny beach and
	    would fight the close-miked SFX for the same air.
	  * "Adorning Solitude" -- the (a) mixes of this cue are described as having
	    "ethereal VOCALS" and only the (b) mix says "instrumental". One word
	    apart, same album, same title. Not worth the trap.
	  * Anything from DistrokidOfficial's pink/brown-noise line. Those are
	    synthesised noise beds, and the beach already has two layers of surf --
	    which IS broadband noise. Stacking more on top is mud, not calm.
	  * Every "(x 60)" cut. That suffix is APM's convention for a 60-second
	    edit; at this game's session lengths a 60s bed loops about sixty times
	    an hour and even a neutral pad starts announcing itself at that rate.
]]
local TRACKS = {
	{ id = "132443056605170", name = "Inner Shoreline" },         -- 2:49
	{ id = "78836304954780",  name = "Whispers of Tranquility" }, -- 2:14
	{ id = "76778885834949",  name = "Quiet Flow" },              -- 1:42
	{ id = "124863098514015", name = "Dreaming Glow" },           -- 1:55
	{ id = "80500027961716",  name = "Silent Meadow" },           -- 1:57

	-- The one APM cue that made the cut, and so the only track here with
	-- published copy behind it as well as a listen: "Warm, earthy cello and bass
	-- drones create a comforting atmosphere." Album: Neutral Atmospheres. Low,
	-- warm and earthy is the right register for this game -- it sits under the
	-- surf instead of over it.
	{ id = "9042042999",      name = "Comfort" },                 -- 2:07
}

local VOLUME     = 0.26   -- under the sea ambience, deliberately
local FIRST_FADE = 8      -- the very first track eases in from nothing
local CROSSFADE  = 7      -- overlap between one track and the next
local START_WAIT = 2.5    -- let the place finish streaming before the first note

-- Same find-or-create MenuHud uses, so it does not matter which of us runs
-- first: whoever gets there makes the group and the other one finds it.
local group = SoundService:FindFirstChild("BeachMusic")
if not group then
	group = Instance.new("SoundGroup")
	group.Name = "BeachMusic"
	group.Volume = 1
	group.Parent = SoundService
end

local rng = Random.new(os.clock() * 1e6 + player.UserId)

----------------------------------------------------------------
-- Shuffle bag
----------------------------------------------------------------
local bag = {}
local lastPlayed = nil

local function nextTrack()
	if #bag == 0 then
		for i, t in ipairs(TRACKS) do
			bag[i] = t
		end
		for i = #bag, 2, -1 do
			local j = rng:NextInteger(1, i)
			bag[i], bag[j] = bag[j], bag[i]
		end
		-- A refill must not hand back the track that just finished: that is the one
		-- repeat a listener always notices, because it happens across the seam.
		if #bag > 1 and bag[1] == lastPlayed then
			bag[1], bag[#bag] = bag[#bag], bag[1]
		end
	end
	local t = table.remove(bag, 1)
	lastPlayed = t
	return t
end

----------------------------------------------------------------
-- Playback
----------------------------------------------------------------
local function newSound(track)
	local s = Instance.new("Sound")
	s.Name = "Music_" .. track.name
	s.SoundId = "rbxassetid://" .. track.id
	s.Volume = 0
	s.Looped = false
	s.SoundGroup = group
	s.Parent = SoundService
	return s
end

task.spawn(function()
	task.wait(START_WAIT)
	local first = true

	while true do
		local track = nextTrack()
		local sound = newSound(track)
		sound:Play()

		-- TimeLength is 0 until the asset resolves, and a track whose length we
		-- never learn would otherwise hand over instantly and stack sounds forever.
		local deadline = os.clock() + 10
		while sound.TimeLength <= 0 and os.clock() < deadline do
			task.wait(0.1)
		end
		local length = sound.TimeLength > 0 and sound.TimeLength or 120

		local fadeIn = first and FIRST_FADE or CROSSFADE
		first = false
		TweenService:Create(sound, TweenInfo.new(fadeIn, Enum.EasingStyle.Sine), {
			Volume = VOLUME,
		}):Play()

		-- Hand over CROSSFADE seconds early. The loop then starts the next track
		-- immediately, so its fade-in overlaps this fade-out and the music never
		-- actually stops.
		task.wait(math.max(length - CROSSFADE, 1))

		TweenService:Create(sound, TweenInfo.new(CROSSFADE, Enum.EasingStyle.Sine), {
			Volume = 0,
		}):Play()
		task.delay(CROSSFADE + 1, function()
			sound:Destroy()
		end)
	end
end)
