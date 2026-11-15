--[[
	ProgressionConfig  --  ReplicatedStorage.Modules.ProgressionConfig

	The upgrade tracks and the rebirth ladder. Replicated: the client needs
	costs and effects to draw the panel, and none of it is secret -- the server
	re-derives every effect from the player's stored LEVEL, never from anything
	the client sends.

	WHY THIS FILE WAS REBUILT
	-------------------------
	It used to be four tracks of six levels with hand-authored cost arrays, and
	the whole tree cost 17,730 coins. A bagful of beach litter is worth about
	920 at the starting bucket, so the ENTIRE game's progression was nineteen
	bags -- roughly fifteen minutes. Worse, the level ceiling at zero rebirths
	was 4, so the real wall was 3,600 coins: four bags, and then nothing left to
	buy on any screen.

	Both problems have the same root. Fixed arrays cannot be long, so the ladder
	was short, so the ladder was cheap. EVERYTHING HERE IS A FORMULA NOW: sixty
	levels per track, four tracks, and one growth constant. Retuning the pace
	of the whole game is one number (CostGrowth) rather than forty.

	THE FOUR TRACKS, AND WHAT EACH ONE IS WIRED TO
	----------------------------------------------
	Every track below ends in a player attribute that some other system reads.
	That is not a style note -- this file previously shipped a fifth track,
	TideLuck, that wrote an attribute NOTHING read, and sold 4,200 coins of
	nothing. The rule now: if you add a track here, name its consumer in the
	comment, or do not add it.

		RollerWidth  RollerWidth attr   CTB_Server's sifter sweep band
		Pressure     WasherPressure     WashServer / WasherTool
		BucketSize   (setMaxWeight)     WeightService's carry ledger
		BeachLegs    Humanoid.WalkSpeed ProgressionServer.applyAll

	FOUR TRACKS WERE REMOVED, AND THEIR CONSUMERS WENT WITH THEM. Beachcomber
	Reach (Magnet), Haggling (Haggle), Prospector's Eye (Prospect) and Lucky
	Charm (GearLuck) are gone, and so is the branch each one fed.
	WeightConfig.reachFor is a flat 14-stud sweep again -- the larger of
	AutoCollectRadius and the net on whatever you are riding, with nothing on
	foot to raise it. SellServer.sellAll applies the rebirth multiplier and
	nothing else -- that one is defined further down this file and is still live.
	CTB_Server takes no second find roll on a cell that came up empty.
	LuckService.luckOf has pets as its only luck source.

	The consumers had to go with the tracks, by the same rule that governs the
	list above: deleting a track on its own leaves an attribute nothing writes,
	and a branch reading an attribute nothing writes does not read as a removed
	feature. It reads as a live feature that is silently broken, and the next
	person through the file has to prove which one it is.

	THE COST CURVE
	--------------
	cost(level) = base * CostGrowth^(level-1), tidied to three significant
	figures so the panel never shows 1,847,293.

	CostGrowth 1.24 is the single pacing dial. Across all four tracks the ladder
	to each ceiling comes out at:

		to level  8       21,044      the rebirth-0 ceiling
		to level 12       57,944
		to level 18      226,404
		to level 28        1.99M
		to level 44       62.41M
		to level 60        1.95B

	The four bases sum to 1,440 (quadrupled 2026-08 -- one early sell used to
	buy three Sifter rungs), so the whole ladder to level C is
	6,000 * (1.24^(C-1) - 1) before tidy() rounding, and that expression is the
	backbone of the rebirth curve at the bottom of this file. Evaluate it rather
	than estimating a total by eye: figures on this line have drifted twice.

	It is deliberately far more than any single early tide can earn: the ladder is
	meant to be climbed across rebirths, and the level CEILING below is what
	actually paces it.

	MEASURED AGAINST THE INCOME MODEL IN ServerStorage.EconomyAudit, a full
	40-rebirth run is a little over eight hours of best-case active play -- call
	it twelve to sixteen real ones -- against about four and a half before the
	2026-08 retune. The shape is deliberate and is the thing to preserve if any
	of this moves again: tide 0 is a twenty-minute Beach-only tutorial tide, the
	Dunes open on the FIRST rebirth, and the destinations then land at roughly
	20 / 40 / 75 / 130 / 210 / 340 minutes of play -- see FerryConfig.Ports and
	the three <Module>.REBIRTHS door constants, which carry the rebirth counts.

	THE FAST OPEN IS GONE, DELIBERATELY (2026-08b). The first tide used to hand
	out the Dunes in about three minutes; requirement(1) is now pitched at
	twenty minutes of tide-0 play (3,250 coins against a 21,044 tide-0 ladder),
	so the Beach is a real tutorial rather than a lobby. Tides 2-4 then run
	quick on purpose -- the Dunes' premium roughly triples income and the gate
	holds nearly still -- and the Vault lands about twenty minutes after the
	Dunes.

	WHY THE EFFECTS ARE FORMULAS TOO
	--------------------------------
	`effect(level)` returns the real gameplay number. A table of sixty values
	per track would be 240 numbers nobody can keep in step, and the server and
	the panel could disagree about what level 41 means. One line each.

	WHAT THE VEHICLES DO WITH THESE
	-------------------------------
	Two of these tracks OUTGROW the machines in the car spawner, and when
	they do, the machine inherits them -- see AtvConfig.effectiveStats. That is
	why the numbers below climb past the ATV shop's own:

		BeachLegs  passes the dozer (26) at level 5, the truck (31) at 12
		BucketSize passes the dozer's hold (300) at 37, the truck's (650) at 45

	THOSE TWO LEGS FIGURES WERE 14 AND 19 until the walking floor moved 16 -> 24
	(BASE_WALK_SPEED below). A higher floor reaches a machine's own speed sooner;
	it does not change what a machine RUNS at, because both are rebirth-14-and-up
	purchases and this track is worth 45+ by that tide either way. What it means
	for the shop is that `speed` is no longer a number to sell a machine on -- the
	hold and the net are.

	The net radius went off this list with Beachcomber Reach. Nothing bought on
	foot reaches further than a machine's net any more, so a machine's net is
	its own number again.

	AND THE TRAFFIC RUNS BOTH WAYS NOW. AtvConfig.Upgrades is a second ladder
	that exists only if you own a machine, and its one track -- the Beach Rake --
	deliberately starts ABOVE this file's RollerWidth ceiling and runs to twice
	it. It is not in Tracks and must not be: it has no tide ceiling and it is not
	wiped by a rebirth, which are two of the three rules everything in this file
	obeys. AtvConfig's own header says why it lives over there instead.

	So a maxed walker does not stop needing their truck (it still carries
	hundreds of pounds and rakes its whole footprint) -- but every level bought
	on foot keeps improving the thing they drive, instead of being wasted the
	moment they buy one.
]]

local ProgressionConfig = {}

--------------------------------------------------------------------------
-- THE DIALS
--------------------------------------------------------------------------

-- Sixty rungs per track. The ceiling below is what a player can actually
-- reach on any given tide; this is the top of the ladder itself.
ProgressionConfig.MaxLevel = 60

--[[
	Per-level price multiplier. THE pacing dial for the whole economy.

	1.24, UP FROM 1.20, AND IT IS ONE OF SEVERAL NUMBERS THAT MOVED TOGETHER.
	The full ladder to level 60 goes from 84.5M to 487.5M, and -- far more
	importantly -- the ladder now grows FASTER than income does per tide,
	which is the only way tides get longer as you climb.

	THE ARITHMETIC THAT USED TO SIT HERE WAS HALF THE STORY. It compared the
	ladder's growth (CostGrowth^2 = 1.5376 a tide) against the sell multiplier
	times the new levels (~1.39) and concluded tides lengthen ~1.10x a tide.
	But real income also compounds the island premiums and whatever pets have
	been bought, which brings its growth to ~1.5x a tide: dead level with the
	old gate, which is why every tide from rebirth 2 to 26 measured the same
	three to five minutes. The gate is now pitched against the FULL income
	model -- see the Rebirth block at the bottom of this file.

	Raise it to make the late game longer; lower it to make it faster. The
	first five Sifter rungs cost 2,254 at the 2026-08 bases -- they were 561,
	one early sell bought three of them, and upgrades outran selling entirely,
	which is what the base quadrupling fixed.

	IT WENT 1.24 -> 1.25 -> 1.24 ACROSS TWO LATER CHANGES, and both are worth
	knowing because they pull in opposite directions. Fixing the washer (see
	WashServer's erosion note) removed a hard floor on wash time and took about a
	quarter off the run, which 1.25 bought back. Then the ferry moved onto
	rebirth gates, which keeps a player on the poorer early fields for far longer
	and added more time than the washer fix removed -- so this came back down and
	the tide ladder got longer instead. Length now comes from the GATES as much as
	from this number, which is the healthier place for it to come from.
]]
ProgressionConfig.CostGrowth = 1.24

-- Where levels are stored. ProgressionServer writes `Lv_<key>`; the client and
-- AtvConfig read the same names through levelOf() below, so the string exists
-- exactly once.
ProgressionConfig.AttrPrefix = "Lv_"

--[[
	THE WALKING FLOOR: what Beach Legs level 1 is worth, and therefore the speed
	every brand-new player moves at.

	24, UP FROM ROBLOX'S DEFAULT 16 (2026-08-28), and it is a PLAYABILITY fix
	rather than a balance one -- the argument is on the BeachLegs track below.

	IT IS A NAMED DIAL BECAUSE THE FLOOR HAD FOUR COPIES. Three scripts carried a
	literal 16 as the fallback for "I cannot reach this player's real speed right
	now" -- AfkClient.restoreSpeed, AfkService.leave and DuelService's count-in --
	and a constant that lives in four files drifts the first time it moves. They
	read this now.

	THE FOURTH COPY IS NOT A SCRIPT: StarterPlayer.CharacterWalkSpeed. A fresh
	character spawns at that property and applyAll writes this over it a moment
	later, so the two disagreeing is a visible speed change on every single
	respawn. It was authored at 19 against a floor of 16, i.e. every player sped
	up on spawn and was then slowed down. It is set to 24 in the place to match:
	move both or neither.
]]
local BASE_WALK_SPEED = 24
ProgressionConfig.BaseWalkSpeed = BASE_WALK_SPEED

--[[
	Prices are rounded to three significant figures.

	Not cosmetic. A geometric curve produces numbers like 1,847,293 by level 40,
	and a shop button reading "$1,847,293" is both unreadable at a glance and
	impossible for a player to plan against. Rounded, the same button reads
	"$1,850,000" and the curve is unchanged to within a fifth of a percent.
]]
local function tidy(n: number): number
	if n < 100 then
		return math.max(5, math.floor(n / 5 + 0.5) * 5)
	end
	local mag = 10 ^ (math.floor(math.log10(n)) - 2)
	return math.floor(n / mag + 0.5) * mag
end

-- Published, because there is a second price ladder in the game now --
-- AtvConfig.Upgrades, the car rake -- and it has to round its prices the same
-- way this one does. Borrowing it is one line; a copy over there would be a
-- second rounding rule quietly shaping numbers on the same shop panel.
ProgressionConfig.tidy = tidy

--[[
	Rounds to the nearest `step`, and then rounds AGAIN through a power of ten.

	The second pass is not belt-and-braces, it is the whole point. `units * step`
	puts the dust straight back for any step that is not a binary fraction: at
	Pressure level 2 the maths is 63 * 0.1, which in IEEE doubles is
	6.300000000000001. The shop formats to one decimal and hides it, but the
	RAW number is what reaches the WasherPressure attribute, the snapshot the
	panel receives, and anything that ever prints a stat without a format string
	-- and "6.300000000000001 psi" in a toast is the kind of thing that gets
	screenshotted.

	Three decimals is far finer than any curve here moves (the smallest step is
	0.1, on Pressure) and is exactly representable after the divide for every
	value they produce.
]]
local function snap(n: number, step: number): number
	local units = math.floor(n / step + 0.5)
	return math.floor(units * step * 1000 + 0.5) / 1000
end

--------------------------------------------------------------------------
-- THE TRACKS
--------------------------------------------------------------------------
--[[
	`base` is the price of the FIRST purchase (level 1 -> 2). QUADRUPLED
	2026-08 (70/120/90/80 -> 280/480/360/320): at the old bases one tutorial
	sell bought Sifter level THREE, so upgrades fell like confetti and the shop
	was finished before the loop had been learned. At 4x, one early bag is
	roughly one rung -- an upgrade is a decision again. The ceiling paces WHICH
	rungs exist; these bases pace how often one gets bought.
]]
ProgressionConfig.Tracks = {
	{
		key = "RollerWidth",
		name = "Sifter Width",
		blurb = "Comb a wider strip of sand each pass.",
		icon = "RollerIcon",
		tint = Color3.fromRGB(255, 196, 92),
		base = 280,
		--[[
			HALF A STUD A LEVEL, and that is a deliberate slow-down.

			The old ladder moved 2 studs a level and ran out at 16 after five
			purchases. This one starts at the same 6 and ends at 48.5 -- eight
			times the sand per pass -- but no single purchase ever feels like
			the beach changed shape, which is what makes sixty of them bearable.

			48.5 is also about as wide as the sweep loop should get ON FOOT: it
			is twelve grid cells either side of the player, and CTB_Server walks
			every cell in the band on every tick.

			IT IS NO LONGER THE WIDEST BAND IN THE GAME. AtvConfig.Upgrades sells
			a towed rake that starts where this track ends and runs to 98.5, and
			it takes the cost of that loop with it -- see that track's own note,
			which measures it. That ladder is bought against a MACHINE and this
			one is not, so the two do not compete: whichever is wider wins while
			you are riding, and only this one exists on foot.

			THIS is the table that ends up in the RollerWidth attribute --
			applyAll() overwrites whatever CTB_Server set on join -- so the
			sifter's drawn width and this have to move together.
		]]
		effect = function(level)
			return 6 + snap((level - 1) * 0.72, 0.5)
		end,
		suffix = " studs",
		decimals = 1,
	},
	{
		key = "Pressure",
		-- Named for the mechanic that is actually live. The bay is a pressure
		-- washer (ServerMain starts WashServer, not SiftServer), so "Shake
		-- Power" was selling an upgrade to a machine that is not in the game.
		name = "Water Pressure",
		blurb = "Blast crust off your finds faster.",
		icon = "PressureIcon",
		tint = Color3.fromRGB(96, 200, 235),
		base = 480,
		--[[
			GEOMETRIC, not linear, because wash TIME is work/pressure -- a
			reciprocal. Linear pressure gains feel enormous at the bottom and
			invisible at the top: 6 -> 8.5 halves the wait, 78 -> 80.5 is three
			hundredths of a second. 4.5% a level keeps every purchase worth the
			same fraction of a wash.

			6.0 to 81 psi.

			THE OLD FIGURE HERE -- "7.0 seconds a lump at level 1" -- WAS NOT
			REACHABLE BY ANY ITEM IN THE GAME. It was derived at Toughness 1.0,
			and ItemConfig gives every encased find a Toughness of
			0.8 + log10(OneIn) * 0.22 clamped to [0.8, 2.2) -- which for the
			cheapest thing that is encased at all (OneIn 50) is already 1.213.
			Nothing on any beach is under that, so 7.0s described a lump that
			cannot be dug up.

			The real span, measured across every encased row in the game at
			chunks * ChunkWork * Toughness / psi:

				level  1 (6.0 psi)    2.9s  LavaBomb  ..   4.4s  Meteorite
				level  8 (8.2 psi)    1.5s            ..   2.7s   <- the tide-0 ceiling
				level 60 (81 psi)     0.53s           ..   0.53s

			(Level 1 reads WORSE than work/psi predicts -- 2.9s against 2.0s -- and
			that gap is real: at spread exactly 1.00 onAim discards a packet's
			leftover budget instead of spilling it, so the bottom six levels
			quantise to whole packets per clump. See GameConfig.Washing.ChunkWork.)
				(HALVED TWICE: GameConfig.Washing.ChunkWork went 1.90 -> 0.95 in
				2026-08 and -> 0.45 on 2026-08-27. The figures on this line have
				been restated at each cut; 4.1/7.7 described the 0.95.)

			Those are still BEST-CASE times: they assume the jet is on crust for
			every one of those seconds. It is aimed, and the crust shrinks away
			from wherever you were pointing, so a real wash is longer than this
			and how much longer is a measure of the player rather than of the
			upgrade. Worth timing by hand before this curve is retuned.

			⚠️ THE TOP OF THIS TRACK IS NO LONGER PRESSURE-BOUND, and whoever
			retunes it next should know before they price it. WashServer's spill
			loop stops at `touched >= reach` (WasherSpread), so one packet clears
			at most 1-3 clumps and a 22-clump lump cannot go below 0.73s from
			level 2 or 0.49s at the top, whatever the psi. Since the 2026-08-27
			ChunkWork cut that floor is reached around level 23 for the softest
			crust and level 37 for the hardest -- so the last third of this ladder
			now buys a louder jet and no measurable time. That is the same defect
			the removed TideLuck track had, and the fix is NOT here: it is the
			spread ladder in GameConfig.Washer.Levels, which has never been raised
			since the erosion rule started reading it.
		]]
		effect = function(level)
			return snap(6.0 * (1.045 ^ (level - 1)), 0.1)
		end,
		suffix = " psi",
		decimals = 1,
	},
	{
		key = "BucketSize",
		name = "Bucket Size",
		blurb = "Carry more before you have to sell.",
		icon = "BucketIcon",
		tint = Color3.fromRGB(255, 150, 108),
		base = 360,
		--[[
			POUNDS, not slots. Carrying is rationed by WEIGHT (see
			ServerScriptService.WeightSystem) and the slot count is deliberately
			lifted out of the way, so a slot number here could only ever be a
			second, competing limit -- and it was the one that bit first. A
			bucket of "10 slots" filled after ten soda cans and after ten gold
			watches alike, which is why a full bag arrived at a different weight
			every time (13 / 20 lbs, and so on).

			12 lbs to 2,675, and the STARTING figure is the interesting one.

			It was 20, which at an average beach find of 0.58 lb is 34 pieces a
			trip -- about two and a half minutes between one sale and the next.
			That is a long time to go without the game paying you anything, and
			the sell pop is the loudest feedback in the whole loop. 12 lbs is 21
			pieces and about ninety seconds, which is the single biggest lever on
			how FAST the game feels that does not touch what it pays.

			The growth goes 1.087 -> 1.096 to land the top in the same place
			(2,675 against 2,740), so nothing downstream shifts by more than a
			level or two. It is still what the bulldozer's 300 lb hold and the
			truck's 650 are measured against: past level 37 and 45 respectively --
			was 34 and 43 -- YOUR bag is the bigger container and the machine
			inherits it. AtvConfig.Transfers carries the same pair; move both.
		]]
		effect = function(level)
			return math.floor(12 * (1.096 ^ (level - 1)) + 0.5)
		end,
		suffix = " lbs",
	},
	{
		key = "BeachLegs",
		name = "Beach Legs",
		blurb = "Move quicker across the sand.",
		icon = "LegsIcon",
		tint = Color3.fromRGB(150, 230, 160),
		base = 320,
		--[[
			24 to 66. THE FLOOR WAS 16 -- Roblox's own default -- AND IT WAS THE
			SINGLE BIGGEST REASON THIS GAME FELT SLOW TO PLAY (2026-08-28).

			A new player spends their entire first tide between levels 1 and 8,
			and at 16 studs/s the home beach (256 studs corner to corner) is a
			sixteen-second walk. The rake lanes, the wash bay and the scales sit
			at opposite ends of it, so WALKING BETWEEN THE THINGS YOU DO was most
			of every minute of the one tide that decides whether anybody plays a
			second. 24 is a brisk walk that still reads as a person on a beach:
			the same trip is now ten seconds.

			WHAT IT IS NOT IS A FLATTENED TRACK, and that is the part to preserve
			if this moves again. A PURCHASE STILL BUYS EXACTLY WHAT IT USED TO:
			half a stud or a whole one, the same steps the old 0.85 curve made
			(that is snap()'s doing, not the multiplier's), and the ladder still
			runs 42 studs from floor to ceiling -- most of a trebling. What the
			player lost is the part of the old ladder that was spent climbing OUT
			OF a default character, which was never content.

			THE PER-LEVEL GAIN CAME DOWN 0.85 -> 0.71 TO HOLD THE CEILING. 66 is
			not a rounding: past about 70 the character overshoots the sifter's
			own sweep and outruns terrain streaming, and two other files measure
			themselves against this exact number -- CTB_Server's MAX_SWEEP_SPEED
			calls 66 the real maximum a tool can honestly move at, and
			SandbotConfig keeps the drone catchable at every level of it. Raising
			the floor without lowering the step would have pushed the top to 74
			and quietly falsified all three.

			It passes the bulldozer at level 5 and the sweeper truck at 12 (was
			14 and 19), after which the machine you are driving moves at YOUR
			speed -- see AtvConfig.Transfers, which carries the same pair.

			HALF-STUD STEPS. Rounded to whole numbers, a per-level gain under 1.0
			lands on the same integer twice, and a shop row reading "27 speed >
			27 speed" for real money is the same defect the removed TideLuck
			track was: an upgrade that visibly does nothing. THE RULE FOR EVERY
			CURVE IN THIS FILE IS THAT snap()'s STEP MUST BE NO LARGER THAN THE
			PER-LEVEL GAIN -- 0.5 <= 0.71 here -- or some purchases silently buy
			nothing.
		]]
		effect = function(level)
			return BASE_WALK_SPEED + snap((level - 1) * 0.71, 0.5)
		end,
		suffix = " speed",
		decimals = 1,
	},
}

ProgressionConfig.TrackByKey = {}
for _, t in ProgressionConfig.Tracks do
	ProgressionConfig.TrackByKey[t.key] = t
end

--------------------------------------------------------------------------
-- COST
--------------------------------------------------------------------------

--[[
	What it costs to go from `level` to `level + 1`. nil once the track is at
	MaxLevel -- callers use that nil as "fully upgraded", so it must stay nil
	rather than becoming a huge number.
]]
function ProgressionConfig.costFor(track, level: number): number?
	if type(level) ~= "number" or level >= ProgressionConfig.MaxLevel then
		return nil
	end
	local base = track.base or 100
	return tidy(base * (ProgressionConfig.CostGrowth ^ math.max(0, level - 1)))
end

--------------------------------------------------------------------------
-- READING A PLAYER'S LEVELS  (both sides)
--------------------------------------------------------------------------
--[[
	The server owns these attributes and is the only writer. Everyone else --
	the shop panel, the car spawner's showroom, AtvConfig's stat transfer --
	reads them through here so the "Lv_" prefix and the clamp exist once.

	Knowing your own level buys nothing, which is why this is safe to replicate:
	every purchase is re-derived server-side from the stored level, and the
	client never sends one.
]]
function ProgressionConfig.levelOf(player: Instance?, key: string): number
	if typeof(player) ~= "Instance" then
		return 1
	end
	local v = player:GetAttribute(ProgressionConfig.AttrPrefix .. key)
	if type(v) ~= "number" or v ~= v then
		return 1
	end
	return math.clamp(math.floor(v), 1, ProgressionConfig.MaxLevel)
end

-- The gameplay number this player's level is worth right now, or nil for a
-- key that is not a track (so a stale key cannot silently read as zero).
function ProgressionConfig.valueOf(player: Instance?, key: string): number?
	local track = ProgressionConfig.TrackByKey[key]
	if not track then
		return nil
	end
	return track.effect(ProgressionConfig.levelOf(player, key))
end

--------------------------------------------------------------------------
-- REBIRTH  --  "Turn of the Tide"
--------------------------------------------------------------------------
--[[
	Rebirthing wipes coins, every upgrade track back to level 1, and THE PLAYER'S
	MACHINE, and grants a permanent stacking multiplier on everything you sell.

	THE MACHINE IS THE EXPENSIVE PART OF THE WIPE AND THE NEWEST (2026-08-24). A
	coin-bought Sandhog is 1,600,000 and a Tidebreaker is 20,000,000 -- about an
	hour of farming at the tide each unlocks on -- and unless the player owns
	that machine's GAME PASS they re-pay it every tide.
	ProgressionServer.onRebirth owns the rule; AtvConfig's header carries the
	pricing argument, re-pitched 2026-08b in TIME for the recurring cost.

	NOT wiped: pets, and the car rake ladder (AtvConfig.Upgrades, `CarLv_`),
	which is permanent and priced as such.

	The gate is TIDE EARNED, not coins held and not lifetime earnings.
	Gating on the balance would let a player sit on the exact number and
	rebirth instantly; gating on lifetime earnings quietly discounted every
	rebirth after the first, because the counter was never reset (see
	ProgressionServer.tideEarnedOf).

	THE GATE IS PITCHED AGAINST INCOME NOW, NOT AGAINST THE LADDER
	--------------------------------------------------------------
	The previous curve grew the gate at exactly the ladder's own rate
	(CostGrowth^2 = 1.5376 a tide), derived from it so the two could never
	drift apart. That invariant sounded right and measured wrong: a tide's
	INCOME grows by the sell multiplier times the new ceiling levels times the
	island premiums times whatever pets have been bought -- about 1.5x a tide
	all in, the same 1.5x the gate grew by. The two cancelled, and every tide
	from rebirth 2 to 26 took the same three to five minutes; then the ceiling
	froze, the tail switched to 1.40 against a 1.20 multiplier, and the last
	fourteen tides compounded into a wall with nothing new inside it. The game
	was "40 rebirths long", four and a half hours short, and 99% of its coins
	sat in the broken tail.

	So the gate is AUTHORED TO TIME NOW (2026-08b). The first eight gates are a
	hand-written table pitched in minutes -- twenty to the Dunes, about twenty
	more to the Vault, thirty-five more to the Cove -- and past eight it is
	geometric, a step faster than income at every stage:

		tides  1-8    authored table      the unlock pacing below
		tides  9-22   gate x1.38 a tide   income grows ~1.31x
		tides 23-32   gate x1.35 a tide   income grows ~1.27x
		tides 33-40   gate x1.42 a tide   income grows ~1.30x

	INCOME INCLUDES AFFORDABILITY NOW. The 2026-08 base quadrupling means a
	player owns the levels they can PAY for, not the ceiling -- around level 40
	of a 56 ceiling at rebirth 32 -- so income keeps growing even after the
	ceiling caps at rebirth 36, which is why the tail's 1.42 is the LARGEST
	constant rather than the smallest. EconomyAudit models exactly this.

		unlock      rb   requirement    ~cumulative play (measured pace)
		Dunes        1         3,600     ~3 min   (was 10,800 / 10 min)
		Vault        4        11,800    ~13 min
		Cove         8        67,700    ~31 min
		Shrine      14       468,000    ~1.0 h
		Ashfall     22         6.15M    ~1.7 h
		Magma       32       123.70M    ~2.7 h
		Penguin     34       249.4M    ~3.1 h
		Wreck       40         2.04B    ~4.0 h best-case, 6-8 real
		(authored)  48        33.6B    the tail, eight tides past the last room

	AND THE LADDER DOES NOT STOP AT 40 -- it stops being AUTHORED at 40. The
	tide counter has no cap (see LadderTides below), so tide 41 and everything
	above it runs on the tail constants this table ends with: the gate keeps its
	1.42 and the multiplier keeps its 1.15, so each tide is ~1.09x longer than
	the one before it, for ever. Nothing new unlocks up there -- the ceiling has
	been at MaxLevel since 36 and the map opened its last room at 32 -- so it is
	a pure multiplier climb, which is exactly what an endless ladder should be
	and is why it needed no second curve.

	THE SHOP IS NEVER FINISHED, ON PURPOSE. At 4x bases the full level-60
	ladder is 1.95B against about 6.9B of total gates, and the affordable
	level tops out around 59 on the last tide -- so there is a rung worth
	buying on every track on every tide of the entire run. The other sinks
	carry the rest: the machines (re-bought every tide since the wipe above),
	their permanent rake ladder (fifty rungs, ~1.73B end to end) and Celestial
	eggs.

	VERIFY, DON'T EYEBALL. ServerStorage.EconomyAudit re-derives this whole
	table from the live config plus a measured income model, prints it, and
	flags any stage where the gate outruns income by more than ~12% a tide or
	falls behind it. Run it after touching ANY of: the constants below,
	CostGrowth, the ceiling schedule, ItemConfig.ISLAND_PREMIUM, the ferry and
	door gates, or the pet luck curve.
]]

-- The ceiling's two gear changes, shared by levelCeiling and requirement so
-- the two curves cannot disagree about where income changes speed:
--   +2 a tide through CEIL_STEP2_END (level 40 at rebirth 16),
--   +1 a tide through CEIL_CAP      (level 60 -- MaxLevel -- at rebirth 36),
--   frozen for the last four tides.
local CEIL_STEP2_END = 16
local CEIL_CAP = 36

--------------------------------------------------------------------------
-- THE SECOND GATE  --  litter picked up this tide
--------------------------------------------------------------------------
--[[
	THE COIN GATE ALONE DOES NOT ASK YOU TO CLEAN THE BEACH.

	`requirement` is coins earned this tide, and coins arrive from more places
	than raking: the Long Shore pays while you are away, and the dailies, the
	playtime bounties and the quests all scale themselves off the sell multiplier
	so they hold their share of a tide at every stage. A player who never touched
	a rake could ride the tide ladder on faucets alone. So there is a second gate
	in PIECES, and it is the one that says the beach actually got cleaned.

	IT IS PITCHED SO THAT ANYONE EARNING THEIR COINS BY RAKING NEVER MEETS IT.
	That is the whole design. A gate in pieces that binds before the coin gate
	would quietly re-time the entire run, and the coin ladder is authored to
	MINUTES against a measured income model (see the note above and
	ServerStorage.EconomyAudit) -- the tides 2-4 dip especially, which is
	deliberate and is what makes those tides quick.

	SO IT IS DERIVED FROM THAT LADDER RATHER THAN AUTHORED BESIDE IT. For each
	tide, the coin gate divided by what one find is worth on the field in use is
	the number of finds a raking player must ALREADY have made:

		tide   coin gate    x mult   per find    finds implied
		   1       3,600      1.00       29.2             123   Beach
		   4      11,800      1.52       78.0             100   Dunes
		   8      67,700      2.66      100.0             255   Vault
		  22       6.15M     18.82      190.0           1,720   Shrine
		  40       2.04B    232.92      563.0          15,557   Magma

	The gate is a SHARE of that, so the headroom is what a player may take from
	the faucets -- and it is the one dial here. Raise LITTER_SHARE to make the
	rake matter more; at 1.0 the two gates land together and every coin would
	have to come out of the sand.

	AND IT NEVER GOES DOWN, which the implied curve does: an island premium
	makes each find worth more, so the same coin gate needs FEWER of them (tide 1
	asks 370 on the home beach, tide 4 only 100 on the Dunes). A requirement that
	fell after a good tide would read as a bug, so each entry is capped by the
	smallest implied count still ahead of it. That is what makes the published
	ladder monotonic AND keeps every rung under the coin gate's own pace.

	The per-find values are ItemConfig's own measurements -- its header derives
	them from the real spawn-weight tables ("COINS PER FIND at the values below:
	Dunes 78, Vault 100, Cove 190, Shrine 190, Ashfall 280, Magma 563", and
	29.21 for the home beach). They are repeated rather than required so this
	file stays free of a dependency on the item tables; if that block is retuned,
	these move with it.
]]
local FIND_VALUE = {
	{ 0,  29.21 },   -- the home beach
	{ 1,  78    },   -- Dunes
	{ 4,  100   },   -- Vault
	{ 8,  190   },   -- Sakura Cove
	{ 14, 190   },   -- Shrine
	{ 22, 280   },   -- Ashfall
	{ 32, 563   },   -- Magma Chamber
	-- Penguin Island unlocks AFTER the Magma Chamber on the ladder (34 against
	-- 32), so it is pitched against 563 and not against Ashfall's 280 -- the
	-- premium contract in ItemConfig says every field beats the one opened
	-- before it, and the biggest map in the game arriving as a step DOWN from
	-- a lava tube is the exact fault the 2026-08 Ashfall lift was fixing.
	{ 34, 700   },   -- Penguin Island
	{ 40, 870   },   -- The Frozen Wreck
}

-- The share of a tide's coins that has to have come out of the sand. The rest
-- is the player's to take from the shore, the dailies and the quests.
local LITTER_SHARE = 0.6

local function findValueAt(rebirths: number): number
	local v = FIND_VALUE[1][2]
	for _, row in FIND_VALUE do
		if rebirths >= row[1] then
			v = row[2]
		end
	end
	return v
end

-- HOW MANY FINDS A RAKING PLAYER MUST ALREADY HAVE MADE to be standing at the
-- coin gate for tide k -- the derivation the whole block above describes. Split
-- out of litterTable because litterRequirement runs it directly for the tides
-- past the authored ladder, where there is no table to look in.
local function impliedFinds(k: number): number
	local R = ProgressionConfig.Rebirth
	-- The rebirths HELD while playing tide k, which is what decides both the
	-- field they are on and the multiplier their finds sell at.
	local held = k - 1
	return R.requirement(k) / (findValueAt(held) * R.multiplier(held))
end

-- Built once, on first ask rather than at require time: it reads `requirement`
-- and `multiplier` off the table below, which does not exist yet up here.
local litterLadder: { number }? = nil

local function litterTable(): { number }
	if litterLadder then
		return litterLadder
	end
	local R = ProgressionConfig.Rebirth
	local implied = {}
	for k = 1, R.LadderTides do
		implied[k] = impliedFinds(k)
	end
	litterLadder = {}
	local smallestAhead = math.huge
	for k = R.LadderTides, 1, -1 do
		smallestAhead = math.min(smallestAhead, implied[k])
		-- 20 is a floor for the earliest tides, so the gate is never a rounding
		-- artefact -- twenty pieces is a couple of minutes with the starting rake.
		litterLadder[k] = math.max(20, tidy(smallestAhead * LITTER_SHARE))
	end
	return litterLadder
end

ProgressionConfig.Rebirth = {
	Name = "Turn of the Tide",

	--[[
		THIS IS NOT A CAP, AND IT USED TO BE ONE (`MaxRebirths`, removed
		2026-09-11). A player may turn the tide as many times as they can afford
		to: nothing in the game refuses a 41st, nothing clamps the counter, and
		`multiplier` below goes on compounding at the same 1.15 a tide for ever.

		WHAT IT STILL MEANS IS "WHERE THE AUTHORED PACING ENDS". Everything above
		it EXTRAPOLATES off the last stretch of the curve, and every curve in this
		table is already written to do that without a special case:
		`requirement` keeps its 1.42 tail, `litterRequirement` keeps deriving
		itself from `requirement`, `levelCeiling` has been flat at MaxLevel since
		rebirth 36, and the map opened its last room at 32. So tide 41 upwards is
		a pure multiplier climb against a gate that outgrows income -- each tide
		longer than the last, for ever.

		IT IS STILL THE TOP OF THE MAP LADDER: FerryConfig.Ports and the four
		door constants gate on this same counter, and the last of them (the Frozen
		Wreck) asks for 40 -- so this has to stay comfortably above that or the
		final room would open on the last authored tide and never be played.

		48, NOT 40, SINCE PENGUIN ISLAND. The wreck opens at 40 -- the number the
		owner asked for -- and 40 was this constant, so the last room would have
		landed exactly on the sentence above. Eight tides of tail after the last
		door is the same headroom the Magma Chamber had at 32 under a 40 ladder;
		the curve below already extrapolates (G_TAIL), so nothing else moved.

		IT IS ALSO A CLICK BUDGET, and the uncapping made that worse rather than
		better. Every tide rebuilds four tracks one level per purchase, and the
		authored run alone is about 6,200 separate purchases; a player past 40
		goes on paying that per tide with no new rung to show for it.
		ProgressionServer.onBuy having no bulk path is the thing to fix here.

		WHAT STILL READS THIS NUMBER, and why each is right to:
		  * ServerStorage.EconomyAudit and FunnelConfig's last rung -- the
		    AUTHORED run is what they measure and chart, and a tide nobody tuned
		    is not a pacing failure to flag.
		  * AfkConfig.rebirthsOf -- the Long Shore's TideGrowth^n curve is tuned
		    across this run and is deliberately FROZEN at its end rather than
		    compounding for ever. See the note over there.
		  * DevGrant, which hands out "everything the game was built for".
		Nothing clamps a live player's count to it. SaveService used to, and the
		only clamp left there is SanityCap below.
	]]
	LadderTides = 48,

	--[[
		A CORRUPTION GUARD, NOT A GAME CAP, and the only upper bound left on the
		counter anywhere. With the real cap gone, SaveService.migrate had nothing
		to stop a mangled profile loading as `rebirths = 1e9` -- and every curve
		here is exponential in n, so that is not a wrong number, it is `inf`
		reaching SellMultiplier and coins. A thousand keeps the arithmetic finite
		and is unreachable by play by an enormous margin: the gate at tide 1,000
		is ~1e156, against ~2e9 at tide 40. If a real player ever meets this, the
		game has a duplication bug, not a ceiling.
	]]
	SanityCap = 1000,

	--[[
		Coins earned THIS TIDE required for rebirth N (1-indexed).

		THE FIRST EIGHT ARE A TABLE, AND THE UNIT THEY WERE WRITTEN IN IS
		MINUTES. Authored against the pace measured over seven live playtests
		(2026-08c; the 08b income model ran ~6.7x slow against real play, so
		that table was rescaled x10/3 wholesale).

		TIDE 1 IS 3,600 AND WAS 10,800 (2026-09-13). That x10/3 rescale went on
		WHOLESALE, and tide 1 is the one rung it should not have: it is the only
		tide played with no sell multiplier, no island premium (29.2 a find on
		the home beach against the Dunes' 78) and a level-8 ceiling, so a gate
		that reads as ten minutes from tide 2 onwards read as 21-41 MINUTES on
		live player data -- two and a half times its own neighbours, and the
		longest tide in the first ten. A first rebirth is the one conversion
		event retention is actually made of, and the games this one is measured
		against land it at 10-16 minutes, so it is pitched THERE now rather than
		at the ladder's convenience: 3,600 is ~123 finds, 8-17 minutes against
		that same data.

		THE OTHER SEVEN DID NOT MOVE, AND MEASURING THEM IS WHY. Scaled off the
		same live data, tides 2-8 already run 6-16 minutes each -- inside the
		band -- so the spike was tide 1 alone and cutting the rest would have
		bought nothing but a cheaper game. EARLY[8] especially is untouched on
		purpose: the geometric branch below anchors on it, so every tide from 9
		up is bit-for-bit the curve it was.

		The next three are nearly flat because the Dunes premium roughly triples
		income the moment it lands, and holding the gate still is what turns
		that into the quick, satisfying tides 2-4. The jump at five is the
		Vault: its wash-free field more than doubles a tide again.

		EconomyAudit's ABSOLUTE minutes still run slow against real play here --
		it models tide 1 at 53 best-case where live play measured 21-41 -- so
		retune tide 1 against its RATIOS and against player data, never its
		clock. The ratios are honest; the calibration constant is not.

		PAST EIGHT IT IS GEOMETRIC, one constant per stretch of map, each a
		step above measured income growth so tides lengthen seven to nine per
		cent each -- and each boundary is a destination (Ashfall at 22, Magma
		at 32), because a new field is where income changes gear.

		THE TAIL IS OPEN-ENDED, which is what makes the uncapped ladder work:
		the last branch has no upper bound on `n`, so it answers tide 41, tide
		400 and anything else the same way it answers tide 40. See LadderTides.
		Retune with
		ServerStorage.EconomyAudit open: these constants are honest against
		its income model (which includes what a player can actually AFFORD to
		own of the 4x ladder), not against the ladder's own growth.
	]]
	requirement = function(n: number): number
		local EARLY = { 3600, 11200, 11500, 11800, 25000, 35300, 49000, 67700 }
		local G_MID = 1.38  -- rebirths 9-22, out to Ashfall
		local G_LATE = 1.35 -- rebirths 23-32, out to the Magma Chamber
		local G_TAIL = 1.42 -- rebirths 33-40; income still grows ~1.30x here
		                    -- (affordable levels keep climbing), so this is
		                    -- not the wall the old 1.40 tail was
		n = math.max(1, math.floor(n))
		if n <= #EARLY then
			return EARLY[n]
		end
		local a = EARLY[#EARLY]
		if n <= 22 then
			return tidy(a * (G_MID ^ (n - 8)))
		end
		local atAshfall = a * (G_MID ^ 14)
		if n <= 32 then
			return tidy(atAshfall * (G_LATE ^ (n - 22)))
		end
		return tidy(atAshfall * (G_LATE ^ 10) * (G_TAIL ^ (n - 32)))
	end,

	--[[
		Pieces of litter picked up THIS TIDE required for rebirth N, the second
		half of the gate. The derivation, the one dial and the reason the ladder is
		monotonic are all in the block above this table.

		Counted where litter changes hands, not where it is sold -- the same rule
		and the same counter the MOST TRASH board ranks
		(LeaderboardConfig.TrashAttribute), so a find that goes into the bag counts
		whatever happens to it afterwards.
	]]
	litterRequirement = function(n: number): number
		n = math.max(1, math.floor(n))
		local ladder = litterTable()
		if n <= #ladder then
			return ladder[n] or 20
		end
		--[[
			PAST THE AUTHORED LADDER the same derivation runs directly, and it does
			NOT need the backward "smallest ahead" pass the table is built with.
			That pass exists because an island premium can make a later tide ask for
			fewer finds than an earlier one; the last premium lands at rebirth 40
			(the Frozen Wreck), which is INSIDE the authored ladder now that it runs
			to 48, so findValueAt is constant from tide 41 on and the implied count
			simply grows by the gate over the multiplier -- 1.42 / 1.15, about 1.23x
			a tide, monotonic for ever. It also joins the table cleanly: tide 49 is
			that same 1.23x above the tide-48 rung the loop wrote.
		]]
		return math.max(20, tidy(impliedFinds(n) * LITTER_SHARE))
	end,

	--[[
		Permanent sell multiplier after N rebirths. 1.0 at zero.

		1.15 A TIDE, DOWN FROM 1.20, AND IT IS HALF OF THE SAME FIX AS THE
		REQUIREMENT ABOVE. Income per tide is this number times the new levels
		times the island premiums times pets, and at 1.20 that product matched
		the gate's growth almost exactly -- which is why every tide took the
		same three to five minutes. Trimming it is what lets a gate the player
		can feel exist without the gate having to grow absurdly.

		THE FINISHED ACCOUNT: 1.15^40 is x267.9 against 1.20^40's x1,469.8.
		The endpoint came down and the JOURNEY got longer, which is the point:
		nothing in the game is priced against x1,469 -- the biggest single
		purchase (the rake's last rung, ~191M) clears comfortably at x268.

		AND IT IS UNCAPPED, AT THE SAME 1.15. The ladder no longer ends at 40
		(see LadderTides), and this deliberately gained no ceiling and no second,
		flatter rate above one: tide 41 is worth exactly the 1.15 tide 40 was.
		It is safe because it is not the term that runs away -- the gate above
		grows at 1.42 against this 1.15, so every tide past the authored run
		COSTS more than it PAYS, and a player who keeps climbing is buying a
		slower and slower number rather than escaping the economy.

		EVERY REWARD FAUCET RE-PACES ITSELF WITH THIS. The daily ladder, the
		playtime bounties, the quests and the AFK shore all scale off the
		SellMultiplier attribute this writes, so they hold their share
		of a tide at every stage. FLAT prices (eggs, machines, rake rungs) land
		later in the run than they did at 1.20 -- rechecked deliberately, see
		EconomyAudit's affordability table.
	]]
	multiplier = function(n: number): number
		return math.floor((1.15 ^ n) * 100 + 0.5) / 100
	end,

	--[[
		The ceiling: 8 at zero rebirths, +2 a tide to level 40 (rebirth 16),
		then +1 a tide to level 60 (rebirth 36), then frozen for the last four.

		TWO GEARS INSTEAD OF ONE, and the second gear is what fixes the dead
		endgame. At a flat +2 the ceiling hit MaxLevel at rebirth 26 and the
		last FOURTEEN tides ran on a frozen shop. Stretching the last twenty
		levels to one per tide keeps a new rung on every track until rebirth
		36, so "what do I do now" keeps its answer -- go and finish this tide
		-- for ninety per cent of the run.

		Eight at zero rebirths is unchanged, and so is the whole first-sixteen
		schedule: the early and mid game keep the shape they were tuned to.

		IT STILL DOES NOT MOVE THE MAP GATES. FerryConfig.Ports and the four
		door constants read the Rebirths counter directly (Dunes 1, Vault 4,
		Cove 8, Shrine 14, Ashfall 22, Magma 32, Penguin 34, Wreck 40); island
		pacing is stated over there and nowhere else.
	]]
	levelCeiling = function(n: number): number
		n = math.max(0, math.floor(n))
		local c
		if n <= CEIL_STEP2_END then
			c = 8 + n * 2
		else
			c = 8 + CEIL_STEP2_END * 2 + (n - CEIL_STEP2_END)
		end
		return math.min(ProgressionConfig.MaxLevel, c)
	end,
}

return ProgressionConfig
