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

	CostGrowth 1.20 is the single pacing dial. What it produces per track, at
	the cheapest base (RollerWidth, 70):

		to level 10      1,456        a few bags -- about where the OLD game ended
		to level 20     10,815
		to level 30     68,880
		to level 40    428,000
		to level 50      2.66M
		to level 60     16.4M

	Across all four tracks a full level-60 build is about 84.5M coins -- the four
	bases sum to 360, so the whole ladder to level C is 1,800 * (1.2^(C-1) - 1)
	and that one expression is the backbone of the rebirth curve at the bottom of
	this file. Evaluate it rather than estimating a total by eye: an earlier
	figure here was out by a sixth because 1.2^59 is 46,960 and the number it
	quoted implied 56,347.

	It is deliberately far more than any single early tide can earn: the ladder is
	meant to be climbed across rebirths, and the level CEILING below is what
	actually paces it.

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

		BeachLegs  passes the dozer (26) at level 14, the truck (31) at 19
		BucketSize passes the dozer's hold (300) at 37, the truck's (650) at 45

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

-- Per-level price multiplier. THE pacing dial for the whole economy.
-- Raise it to make the late game longer; lower it to make it faster. Nothing
-- else needs to move with it.
ProgressionConfig.CostGrowth = 1.20

-- Where levels are stored. ProgressionServer writes `Lv_<key>`; the client and
-- AtvConfig read the same names through levelOf() below, so the string exists
-- exactly once.
ProgressionConfig.AttrPrefix = "Lv_"

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
	`base` is the price of the FIRST purchase (level 1 -> 2), and every track's
	base is the number the old hand-authored array started with -- so the first
	few minutes of the game cost exactly what they always did. Everything past
	that is new ladder.
]]
ProgressionConfig.Tracks = {
	{
		key = "RollerWidth",
		name = "Sifter Width",
		blurb = "Comb a wider strip of sand each pass.",
		icon = "RollerIcon",
		tint = Color3.fromRGB(255, 196, 92),
		base = 70,
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
		base = 120,
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

			The real span, measured across the beach's encased rows at
			chunks * ChunkWork * Toughness / psi:

				level  1 (6.0 psi)    8.4s  Starfish  ..  15.0s  Meteorite
				level 60 (81 psi)     0.63s           ..   1.11s

			Those are still BEST-CASE times: they assume the jet is on crust for
			every one of those seconds. It is aimed, and the crust shrinks away
			from wherever you were pointing, so a real wash is longer than this
			and how much longer is a measure of the player rather than of the
			upgrade. Worth timing by hand before this curve is retuned.
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
		base = 90,
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
		base = 80,
		--[[
			16 (Roblox's default) to 66. Kept LINEAR and kept modest: walking
			speed is the one stat that changes how the game feels to control
			rather than how fast it pays, and past about 70 the character
			overshoots the sifter's own sweep and outruns terrain streaming.

			It passes the bulldozer at level 14 and the sweeper truck at 19,
			after which the machine you are driving moves at YOUR speed.

			HALF-STUD STEPS. Rounded to whole numbers, 0.85 a level lands on the
			same integer twice roughly every sixth purchase (levels 4 and 5 both
			gave 19), and a shop row reading "19 speed > 19 speed" for real money
			is the same defect the removed TideLuck track was: an upgrade that
			visibly does nothing. THE RULE FOR EVERY CURVE IN THIS FILE IS THAT
			snap()'s STEP MUST BE NO LARGER THAN THE PER-LEVEL GAIN -- 0.5 <= 0.85
			here -- or some purchases silently buy nothing.
		]]
		effect = function(level)
			return 16 + snap((level - 1) * 0.85, 0.5)
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
	Rebirthing wipes coins and every upgrade track back to level 1, and grants a
	permanent stacking multiplier on everything you sell.

	The gate is TIDE EARNED, not coins held and not lifetime earnings.
	Gating on the balance would let a player sit on the exact number and
	rebirth instantly; gating on lifetime earnings quietly discounted every
	rebirth after the first, because the counter was never reset (see
	ProgressionServer.tideEarnedOf).

	THE THREE CURVES HAVE TO BE READ TOGETHER
	-----------------------------------------
	Each rebirth multiplies income by roughly 1.7x: 1.3x directly from the sell
	multiplier, and about 1.3x again from the three extra levels the ceiling
	grants on all four tracks. THE REQUIREMENT GROWS AT THE SAME RATE THE LADDER
	DOES (1.728x, see `requirement`), so the two never pull apart -- though they no
	longer start together, which is the note under the table.

	`ladder` below is what rebuilding all four tracks costs on THAT tide -- the
	previous rebirth's ceiling -- and it is the number the gate is pitched against.
	The design goal is a gate at roughly a fifth of the ladder, which is what keeps
	the shop alive on every tide rather than only on the early ones.

		n      requirement       ladder    ratio   sell mult   ceiling after
		 1           3,000        4,650     0.65     1.30x         11
		 5          30,100       55,700     0.54     3.71x         23
		10         538,000      884,000     0.61    13.79x         38
		15       9,620,000       13.65M     0.70    51.19x         53
		18      54,200,000        70.5M     0.77   112.46x         60
		21     183,000,000        84.5M     2.16   247.06x         60
		25     927,000,000        84.5M    10.96   705.64x         60

	THAT RATIO COLUMN IS NOT A FIFTH ANY MORE, AND IT IS NOT MEANT TO LOOK LIKE
	ONE. Removing four tracks took the ladder's base sum from 1,060 to 360 and the
	requirement curve was not touched, so the gate now sits at about two thirds of
	the ladder for the whole climb instead of a fifth. The two curves still grow at
	the same rate, so the shape of a tide is unchanged; there is simply more earning
	after the shopping than the design called for. The curve was left alone on
	purpose -- this was a removal, not a rebalance. Restoring the documented fifth
	is ONE number: `requirement`'s 3000 base down to about 1000. Nothing else here
	moves with it.

	PAST 18 THE RATIO HAS TO CLIMB and there is nothing to be done about it: the
	ceiling is capped, so the ladder is a fixed 84.5M while income keeps growing at
	1.30x a tide. It climbs from 0.77 rather than from a fifth, so it gets away
	faster than it used to -- 2.16 by rebirth 21. The 1.50 branch is what keeps
	those last seven tides at roughly a quarter of an hour each instead of letting
	them run away.

	THE CEILING IS THE REAL PACING FOR THE FIRST EIGHTEEN, NOT THE PRICE. A player
	at rebirth 3 cannot buy level 21 at any price, so the coins are never the thing
	they are waiting on. That is deliberate: it means the answer to "what do I do
	now" is always "go and finish this tide", never "go and grind".
]]
ProgressionConfig.Rebirth = {
	Name = "Turn of the Tide",
	MaxRebirths = 25,

	--[[
		Coins earned THIS TIDE required for rebirth N (1-indexed).

		IT TRACKS THE LADDER NOW INSTEAD OF DIVERGING FROM IT. It was a flat
		2500 * 2.0^(n-1), and the divergence was the single worst thing about the
		late game.

		Rebuilding all four tracks to the tide's ceiling grows at CostGrowth^3 =
		1.728 per rebirth, because the ceiling rises by three. A gate growing at
		2.0 pulls away from that, and the two crossed around rebirth 7-8: before it
		the ladder was the bigger number, after it the gate ran to three, thirty,
		five hundred times the ladder. Rebirth 25 asked for 41.9 BILLION in one
		tide against an 84.5M ladder -- four minutes of shopping followed by half
		an hour with nothing left to buy, which is the shape of a wall.

		1.78 matches the ladder's own growth, so the gate holds a steady ratio to it
		for the whole climb instead of pulling away, and every tide has one shape:
		rebuild the shop, then earn a fixed fraction as much again to turn the tide.
		That fraction is about two thirds today rather than the fifth this base was
		chosen for -- four tracks came out of the ladder and this number was
		deliberately left where it was. The header says what it would take to move it.

		1.50 PAST REBIRTH 18, because that is where levelCeiling caps at 60 and the
		ladder stops growing at all. Holding 1.78 there would leave the gate as the
		only thing still moving and stretch the last seven tides out again -- the
		exact failure this curve exists to remove.

		tidy() rather than math.floor: this figure is drawn on the rebirth panel's
		progress bar, and 1,564,283 is not a number anybody can plan against.
	]]
	--[[
		THE BASE IS 1000 NOW, AND THE HEADER ABOVE IS WHAT ASKED FOR IT.

		It was 3000, and the note under the table says exactly why that stopped
		being right: removing four upgrade tracks took the ladder's base sum from
		1,060 to 360 and this number was deliberately left alone, because that
		change was a removal rather than a rebalance. The consequence was a gate
		sitting at about two thirds of the ladder for the whole climb instead of
		the fifth it was chosen for -- which is a tide that ends with the shop
		finished and a long stretch of earning with nothing left to buy.

		The header also says what to do about it and that nothing else moves with
		it: "requirement's 3000 base down to about 1000". This is that. The growth
		rates are untouched, so the SHAPE of every tide is the same as it was --
		only the length of its second half changes.

		The ratio column in the table above now reads about 0.22 rather than 0.65
		at n=1, which is the design target. The absolute figures in that table are
		now three times what this returns; they are left as written because the
		column that matters there is the ratio, and dividing every row by three
		would not change a word of the argument.
	]]
	requirement = function(n: number): number
		local CAP = 18
		local BASE = 1000
		if n <= CAP then
			return tidy(BASE * (1.78 ^ (n - 1)))
		end
		return tidy(BASE * (1.78 ^ (CAP - 1)) * (1.50 ^ (n - CAP)))
	end,

	-- Permanent sell multiplier after N rebirths. 1.0 at zero.
	multiplier = function(n: number): number
		return math.floor((1.3 ^ n) * 100 + 0.5) / 100
	end,

	--[[
		Each rebirth lifts every track's ceiling by three, so the ladder does
		not simply repeat -- the second run reaches numbers the first could not.

		8 at zero rebirths, and that is up from 4. Four was low enough that a
		new player hit the wall on every track inside ten minutes and the shop
		went dead before they had seen the rest of the game; eight is about
		4,650 coins across all four tracks, or roughly ten minutes, which is
		past the first rebirth at 3,000 but no longer comfortably so.

		Reaches MaxLevel at rebirth 18, leaving the last seven rebirths as pure
		multiplier -- there has to be somewhere to go after the ladder is done.
	]]
	levelCeiling = function(n: number): number
		return math.min(ProgressionConfig.MaxLevel, 8 + math.max(0, math.floor(n)) * 3)
	end,
}

return ProgressionConfig
