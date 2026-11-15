--[[
	GameConfig  --  ReplicatedStorage.Modules.GameConfig

	Every tunable number in the cleanup loop. Required by both server and
	client; nothing here is secret, so it is safe to replicate.

	THE LOOP THESE NUMBERS DESCRIBE
	-------------------------------
	Most litter is picked up already clean and sells instantly. A minority
	(the ones ItemConfig marks Encased) comes up as a crusted lump -- identity
	hidden, worth unknown -- and has to be shaken apart on the screen at the
	sifting bay before it can be sold.
]]

local GameConfig = {}

--------------------------------------------------------------------------
-- INVENTORY
--------------------------------------------------------------------------
GameConfig.Inventory = {
	MaxCapacity = 10,  -- matches Clean the Beach's Config.BAG_MAX
	-- ScreenCapacity is gone (2026-08): it belonged to the removed sift bay,
	-- and nothing -- not even the sift files -- ever read it.
}

--------------------------------------------------------------------------
-- SIFTING  (removed 2026-08)
--------------------------------------------------------------------------
-- GameConfig.Sifting (the shake-the-screen tuning: cadence curve, ChunkWork
-- twin, packet limits) and GameConfig.Screen (twelve deck tiers, every cost
-- already 0) are GONE. They were read only by SiftScreen, SiftServer and
-- SiftClientController -- all three parked in
-- ServerStorage.SiftSystem_BACKUP_2026_08_24 -- and the live wash bay never
-- touched either table. Washing (below) owns the one ChunkWork that exists.
--------------------------------------------------------------------------
-- SELLING
--------------------------------------------------------------------------
GameConfig.Selling = {
	CooldownSeconds = 0.75,
	-- The "sift it first" toast needs its OWN, much longer cooldown. Clean the
	-- Beach's sell trigger is a pad you stand on, re-checked every tick, so
	-- gating the refusal on CooldownSeconds alone repeats the message every
	-- 0.75s for as long as the player is stood there.
	RefusalNotifyCooldown = 5,
	-- 2% an item, capped. The cap is what decides how big a bag has to be before
	-- the bonus stops rewarding you for filling it, and at 0.25 it was reached at
	-- TWELVE AND A HALF ITEMS -- fewer than a starting bucket holds even after
	-- BucketSize dropped to 12 lbs (about 21 finds). So every bag in the game was
	-- already at the ceiling and "bring a full one in" paid exactly what "dribble
	-- three small ones in" did.
	--
	-- 0.50 moves the ceiling to 25 items, which is just above a starting bag and
	-- comfortably below every later one -- so the bonus is live for the whole
	-- early game and a full bag is visibly worth walking.
	BatchBonusPerItem = 0.02,
	MaxBatchBonus = 0.50,
}

--------------------------------------------------------------------------
-- SOUND
--------------------------------------------------------------------------
--[[
	The engine's built-in `rbxasset://sounds/*` set is GONE from this table.
	It was only ever a stand-in so the game made a noise with zero uploads, and
	it was the wrong noise: those clips are short, bright, compressed 2007-era
	UI blips, and a relaxing beach-cleanup game built out of them reads as
	arcadey no matter how the rest of it looks.

	Everything here is now ProSoundEffects -- Roblox's own licensed library, so
	it is free, cannot be moderated out from under the game the way a random
	catalogue upload can, and is professionally recorded. The picks lean
	close-miked and dry (the library slates those "CU"), because that intimacy
	is what the brief was actually asking for.

	EVERY ID BELOW WAS LOADED IN THIS PLACE AND CHECKED FOR IsLoaded AND A
	NON-ZERO TimeLength BEFORE IT WAS WRITTEN DOWN, and that is not optional
	paranoia -- it is the same check the old comment here asked for, for the
	same reason: a Sound whose id does not resolve DOES NOT THROW. It plays
	nothing, forever, and the feature just quietly has no audio.

	WHERE THE SHAPING LIVES
	-----------------------
	This table is now only the RAW ids, kept so that any call site still passing
	a plain SoundId string sounds correct. How each one is actually voiced --
	level, pitch, per-shot pitch jitter, round-robin across takes, the soft
	attack that stops a one-shot clicking, the bus EQ and compressor -- lives in
	ReplicatedStorage.Modules.AudioKit, keyed by these same names. Prefer
	AudioKit.play("Pickup", part) over reading a string out of here; the string
	path gets the clip but none of the treatment.
]]
GameConfig.Sounds = {
	-- Loops. Long takes on purpose: a short loop repeats often enough for the
	-- ear to learn it, and once you can hear the seam you cannot unhear it.
	ScreenRattle = "rbxassetid://9118063120", -- Rattle, Plastic, Constant (20.7s)
	SiftPour = "rbxassetid://9114034817",     -- Debris Rain, Dirt or Gravel Slide (28.0s)
	WasherMotor = "rbxassetid://9112825161",  -- Machine Room, Hospital Machines Presence (56.0s)
	WasherSpray = "rbxassetid://9116496316",  -- Medium Size Waterfall, Showery White Noise (56.0s)

	-- Grit. ChunkPop fires more often than anything else in the game, so it is
	-- the one slot with four takes to round-robin; AudioKit does the rotating.
	ChunkPop = "rbxassetid://9118624649",     -- Rock Impacts, Light Debris (0.4s)
	SandDrop = "rbxassetid://9118770617",     -- Sand Silt, Soft Falling With Some Clumps (2.4s)
	BinDump = "rbxassetid://9118771547",      -- Sand Slide, Long Skids (5.3s)
	SwingWhoosh = "rbxassetid://9117174394",  -- Organic Airy Whooshes (0.9s) -- air only, no thud

	-- Touch. Close-miked dry foley; this is the ASMR core of the kit.
	Pickup = "rbxassetid://9120085244",       -- Tissue Paper Movement, CU (0.8s)
	Mount = "rbxassetid://9125654847",        -- Marble Table Hit on Wood, Thuddy (0.6s)
	Reject = "rbxassetid://9125654847",       -- the same knock, pitched down to 0.72 by AudioKit
	StreakBreak = "rbxassetid://9114775311",  -- Hanger, Wooden on Wooden Rod (0.35s)

	-- Tone. No pitch jitter on any of these -- a wobble on a tuned sound is not
	-- texture, it is an instrument going out of tune.
	ItemCleaned = "rbxassetid://9116394545",  -- Magic Glow, Soft Cluster of Chiming Hits (1.4s)
	StreakStep = "rbxassetid://9120288444",   -- Tuning Fork, CU, Pitched at A (2.8s)
	LegendaryHit = "rbxassetid://9116394756", -- the longest take of the same chime family (3.3s)
	Upgrade = "rbxassetid://9114132970",      -- Door Chime, Bell Hit With Wood Mallet (8.6s)
	Register = "rbxassetid://9113416142",     -- Bell Hits, Small Bell, Soft (6.9s) -- a till bell
	CoinShower = "rbxassetid://9113580898",   -- Bracelet Movement, Metallic Jingling (2.8s)
}

GameConfig.Textures = {
	Sparkle = "rbxasset://textures/particles/sparkles_main.dds",
	Smoke = "rbxasset://textures/particles/smoke_main.dds",
}

--------------------------------------------------------------------------
-- TAGS  (CollectionService)
--------------------------------------------------------------------------
GameConfig.Tags = {
	-- SiftBay went with the sift system (2026-08); nothing in the place ever
	-- carried the tag.
	SellCounter = "SellCounter",
	-- Every pettable bird on Penguin Island. PenguinBuilder stamps it,
	-- PenguinService binds the "Pet" prompt by it.
	Penguin = "Penguin",
}


--------------------------------------------------------------------------
-- WASHING  (restored)
--------------------------------------------------------------------------
-- The client reports only WHICH CHUNK it is aiming at; the server applies
-- pressure * elapsed from its own clock, so there is no quantity to inflate.
GameConfig.Washing = {
	--[[
		PAIRED WITH ItemConfig.CrustChunkCount -- read the note there. Total work
		to clean a lump is chunks * ChunkWork * Toughness.

		THE TARGET PRODUCT IS ~10 NOW. IT HAS BEEN HALVED TWICE, AND BOTH CUTS
		WERE THE SAME COMPLAINT ARRIVING TWICE.

		Every early value of this number was chosen to HOLD the product still
		while the clump count moved, so that wash times never changed:
		    14 * 3.00 = 42.0    34 * 1.25 = 42.5    22 * 1.90 = 41.8
		That invariant was right for what it was defending and it is not what is
		wanted here. A measured playthrough at tide 0 came out at roughly nine
		seconds of raking against ninety seconds of washing for one bag -- the
		fun verb was seven per cent of its own loop, and the bay was the other
		seventy-two. So the product was cut in half:
		    22 * 0.95 = 20.9   <- 2026-08

		And then cut in half again, because it was still too slow:
		    22 * 0.45 =  9.9   <- current (2026-08-27)

		WHY THE FIRST CUT DID NOT LAND, which is the part worth keeping: the
		rebirth-0 LEVEL CEILING is 8. A whole tutorial tide is therefore spent
		between 6.0 and 8.2 psi -- the very bottom of a reciprocal curve -- where
		halving the work still left 11 to 26 REAL seconds a lump. Averages over
		the sixty-rung ladder hid that; the ceiling schedule is where to look.

		WHY THIS LEVER AND NOT THE OTHER TWO. The clump COUNT stays at 22
		because buildCrust sizes each chunk by 1/sqrt(count) -- halving the count
		takes the shell back to the "few big scabs" look the count note explains
		was abandoned at 14. And the Pressure track's base stays at 6.0 psi
		because moving it rescales all sixty rungs and every stat readout in the
		shop. This number touches wash time and nothing else.

		WHAT IT ACTUALLY BUYS. Not the `work / psi` ideal -- that formula is only
		true where the spill has somewhere to go -- but WashServer.onAim REPLAYED
		at the client's 15 packets a second with perfect aim, over the real
		Toughness span, 1.206 (LavaBomb) to 2.159 (Meteorite):

		    level  1 (6.0 psi)   4.40 -> 2.93 s   ..   8.80 -> 4.40 s   (1.5x, 2.0x)
		    level  4 (6.8)       4.40 -> 2.93 s   ..   7.33 -> 4.40 s
		    level  8 (8.2)       3.13 -> 1.47 s   ..   5.53 -> 2.67 s   <- tide-0 ceiling
		    level 20 (14.4)      1.87 -> 1.00 s   ..   3.33 -> 1.60 s
		    level 40 (34.6)      1.00 -> 0.73 s   ..   1.40 -> 0.73 s
		    level 60 (81.0)      0.53 -> 0.53 s   ..   0.60 -> 0.53 s   (1.0x)

		Those are still BEST-CASE: the jet is aimed and the crust shrinks away
		from wherever you were pointing, so a real wash is longer and how much
		longer is a measure of the player. Real time measures about 3.5x the
		ideal, so the tide-0 ceiling went from roughly 11-19 real seconds a lump
		to roughly 5-9.

		⚠️ TWO THINGS IN THAT TABLE ARE NOT THIS NUMBER, AND BOTH ARE
		WasherSpread. onAim's spill loop stops at `touched >= reach`, so a packet
		reaches 1 clump at spread 1.00, 2 from 1.11 and 3 at 2.20:

		  * THE TOP IS CAPPED. 22 clumps at 3 a packet is 0.49s and no psi can
		    beat it. Since this cut, that floor is reached around level 23 for the
		    softest crust and 37 for the hardest -- so cutting this further only
		    speeds up the bottom of the ladder, and the last third of the Pressure
		    track now buys a louder jet and no measurable time. Fixing THAT means
		    raising the spread ladder in GameConfig.Washer.Levels below, which has
		    never moved since the erosion rule started reading it.
		  * THE BOTTOM WASTES SURPLUS, which is why levels 1-6 only got 1.5x while
		    level 8 got 2.1x. At spread EXACTLY 1.00 -- levels 1 to 6, before the
		    stretched ladder reaches its second rung -- the loop breaks after the
		    aimed clump, so anything left in the packet's budget is DISCARDED
		    rather than spilled. Wash time there quantises to whole packets per
		    clump: 0.35 of a clump a packet needed 3, 0.74 needs 2, and it will
		    not reach 1 until the budget clears a whole clump in one packet
		    (ChunkWork ~0.33 for the softest crust, ~0.19 for the hardest). The
		    ideal `work / psi` figure is blind to this and reads 1.99s where the
		    replay measures 2.93s.

		IT MAKES THE GAME PAY FASTER AND NOTHING MODELS THAT. The bay is most of
		the cleanup loop, so 2.1x on wash time is worth roughly 1.5-1.6x on coins
		per minute -- and ServerStorage.EconomyAudit will NOT show it: its income
		model starts from a frozen BASE_RATE of 262 coins/min measured in 2026-08,
		not from this number, so the 40-tide run is now shorter than that audit
		prints. If run length matters more than feel, ProgressionConfig.CostGrowth
		and the rebirth requirement table are the dials for it -- not this one.

		GameConfig.Sifting.ChunkWork used to move with this. The sift bay and
		its config were removed 2026-08, so this number is now the only
		wash-time dial in the game.
	]]
	ChunkWork = 0.45,
	MaxTickDelta = 0.12,
	MinPacketInterval = 0.02,
	MaxPacketsPerSecond = 40,
	BayRange = 18,
	ProgressPushInterval = 0.1,
	JetRange = 26,
	--[[
		HOW LONG A FINISHED ROCK SITS THERE BEFORE IT IS SOLD AND THE NEXT ONE
		GOES UP. 1.3 -> 0.6.

		It is one number doing two jobs, which is why it was the thing to cut: the
		sale, the despawn and the auto-advance all hang off the same task.delay in
		WashServer, so every extra tenth here is a tenth of standing at a bay
		looking at a rock that is already finished, with the money not yet paid.

		THE PER-RARITY BONUS IS UNTOUCHED (ItemConfig's tier `hold`: 0 for a
		Common up to 1.1 for a Mythic). That is the beat that says this one was
		worth something, and it still lands on top of this -- a Common now clears
		in 0.6 and a Mythic in 1.7, so the good ones keep their pause and the
		ordinary ones stop costing a second each.

		The reveal CARD is not on this clock -- RevealPopup holds it for 3s of its
		own and queues them -- so shortening this does not cut the card short, it
		just stops the bay waiting for it.
	]]
	RevealHoldTime = 0.6,
}

--[[
	TWELVE NAMES, AND THEY ARE NAMES -- NOT LEVELS.

	This list is no longer indexed by the player's Pressure level. That worked
	while both ladders were six long; ProgressionConfig's is sixty now, and
	indexing (even clamped) would freeze the tool's name at the top entry one
	fifth of the way up and leave it there for the remaining forty-eight
	purchases. ProgressionServer.applyAll STRETCHES this list over MaxLevel
	instead -- twelve names over sixty levels, so the thing in your hands gets a
	new name every five levels for the whole climb.

	WHAT IS AND IS NOT LIVE HERE:

		label    LIVE. The one place the upgrade is visible while you are using
		         it, so it is the one field that has to keep moving.
		spread   LIVE. How wide the jet reads; ramped to match the names.
		pressure DEAD, and kept only as documentation of roughly where each name
		         sits on the curve. The real number is ProgressionConfig's
		         Pressure effect, written to the WasherPressure attribute, and
		         WasherTool.pressureFor reads that attribute in preference to
		         this -- one ladder, not two that can drift.
		cost     DEAD. The kiosk prompt that used to spend it is disabled (see
		         WasherTool.attachKioskPrompt); the Beach Shop's Pressure track
		         is the only place this ladder is bought.
]]
GameConfig.Washer = {
	Levels = {
		{ pressure = 6.0, cost = 0, spread = 1.00, label = "Garden Hose" },
		{ pressure = 8.2, cost = 0, spread = 1.11, label = "Pressure Washer" },
		{ pressure = 11.2, cost = 0, spread = 1.22, label = "Industrial Jet" },
		{ pressure = 15.3, cost = 0, spread = 1.33, label = "Hydro Lance" },
		{ pressure = 20.9, cost = 0, spread = 1.44, label = "Turbo Lance" },
		{ pressure = 28.6, cost = 0, spread = 1.55, label = "Hydro Cannon" },
		{ pressure = 39.0, cost = 0, spread = 1.66, label = "Surge Cannon" },
		{ pressure = 47.5, cost = 0, spread = 1.77, label = "Tidal Ram" },
		{ pressure = 57.9, cost = 0, spread = 1.88, label = "Riptide Lance" },
		{ pressure = 66.2, cost = 0, spread = 1.99, label = "Maelstrom Jet" },
		{ pressure = 73.5, cost = 0, spread = 2.10, label = "Abyssal Cannon" },
		{ pressure = 80.5, cost = 0, spread = 2.20, label = "Leviathan Lance" },
	},
	DefaultLevel = 1,
}

-- FINAL TAG GUARD -- set last so no earlier reassignment of GameConfig.Tags
-- can drop it. WashServer does CollectionService:GetTagged(Tags.WashBay), and
-- a nil there throws "Argument 1 missing or nil" at boot.
GameConfig.Tags = GameConfig.Tags or {}
GameConfig.Tags.WashBay = "WashBay"
GameConfig.Tags.SellCounter = GameConfig.Tags.SellCounter or "SellCounter"

return GameConfig