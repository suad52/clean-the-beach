--[[
	RewardsConfig  --  ReplicatedStorage.Modules.RewardsConfig

	What the Rewards panel offers, in one place both sides read. RewardsServer
	owns the clock and the payout; MenuHud draws whatever this says.

	THREE SECTIONS, AND THEY ARE THREE DIFFERENT PROMISES
	-----------------------------------------------------
		DAILY     come back tomorrow. A streak ladder on the UTC day.
		QUESTS    do a thing. Dailies reset with the day; milestones never do.
		PLAYTIME  stay a while. Once per DAY, on seconds played today.

	EVERY QUEST IS A THRESHOLD ON A COUNTER THE GAME ALREADY WRITES, and that is
	the load-bearing decision in this file rather than any particular number.

	The obvious way to build "sell 20 items today" is to hook the sell path and
	count. It was not done, for a reason worth writing down: `SellServer.OnCoinsChanged`
	is a SINGLE-ASSIGNMENT hook that ProgressionServer already owns and SaveService
	already wraps, and SaveService's own header calls that out as a trap it fell
	into once. A third wrapper on a contested hook, to count something no system
	currently counts, is a lot of new failure surface for a quest label.

	So a quest names a STAT, and a stat is read straight off the player:

		earned    TotalEarned   lifetime coins, persisted, only ever goes up
		levels    sum of Lv_*   every upgrade track added together
		rebirths  Rebirths
		vehicle   AtvTier
		playSec   seconds played today, RewardsServer's own accumulator

	All of them are monotonic EXCEPT `vehicle`, which is what makes the daily
	variants work: a daily quest is the SAME threshold measured against a
	baseline stamped when the player's day rolled over. No event plumbing, and a
	new way to earn a coin counts toward "earn 25k today" for free.

	`vehicle` STOPPED BEING MONOTONIC ON 2026-08-24, when a rebirth started
	wiping AtvTier for anyone without the machine's game pass
	(ProgressionServer.onRebirth). The consequence to know about is small but
	real: an "own a vehicle" milestone that is READY and has NOT been claimed can
	go back to un-READY when the player turns the tide, because RewardsServer
	re-reads the live attribute rather than latching the peak. An already-CLAIMED
	one is safe -- claims are persisted separately. If that ever needs fixing,
	latch the high-water mark here rather than making the wipe conditional.

	The cost is honest and worth stating: quests can only ask about things that
	are counted. "Wash ten crusted finds" is a better quest than any of these and
	it is not here, because nothing in the game counts washes yet. When something
	does, add the stat to RewardsServer.statOf and the quest to the table below --
	that is the whole change.

	COINS ARE ALL SCALED BY SellMultiplier at payout AND in the snapshot, the way
	the playtime tiers already are. A flat number in an economy that reaches 705x
	stops being worth reading long before it stops being worth claiming.
]]

local RewardsConfig = {}

--------------------------------------------------------------------------
-- PLAYTIME
--------------------------------------------------------------------------
--[[
	THE COIN VALUES ARE UNCHANGED; WHAT CHANGED IS HOW OFTEN THEY CAN BE TAKEN.

	These five were a per-SESSION bounty, and the ladder totals 10,300 at
	multiplier 1.0 -- more per half hour than tide-0 play actually earns, and
	repeatable by rejoining. RewardsServer now latches them per DAY and measures
	them against `playSec` (seconds played today, across sessions) rather than
	a session clock. Read that file's header before retuning any of this.

	The thresholds are still session-shaped on purpose -- 1, 5, 10, 20 and 30
	minutes is a ladder somebody clears in one sitting -- so a player still gets
	the whole thing on their first proper session of the day. They simply do not
	get it four times.
]]
--[[
	THREE MORE RUNGS, TO NINETY MINUTES.  2026-09-19.

	The ladder stopped at thirty and these are a PER-DAY latch, so somebody who
	put in an hour and a half earned exactly what somebody who stopped at thirty
	did -- from the one mechanic in the game that is explicitly about session
	length.

	ADDING A RUNG USED TO BE TWO EDITS AND IT IS ONE NOW. MenuHud's playtime page
	hardcoded `for i = 1, 5` beside a fixed 116px card, so the first attempt at
	this produced a page drawing five cards above a button reading CLAIM ALL 8 --
	three rungs that paid out, were counted, and were never drawn. That page reads
	the count off this table and scrolls now, so the list below is the only place
	the number lives.

	HELD TO THE EXISTING RATE RATHER THAN ACCELERATED, because the note above is
	right to be careful: the first five rungs already total 10,300 at multiplier
	1.0, which is more per half hour than tide-0 play actually earns. These three
	add 27,000 across an extra hour, bringing the full ladder to 37,300 over
	ninety minutes -- 414 a minute against the first half hour's 343. A fifth
	better per minute for three times the sitting rewards commitment; doubling the
	rate would be a reason to idle.

	STILL SESSION-SHAPED, the way the note above asks: 45, 60 and 90 are numbers
	somebody reaches in one long sitting, not a second login.
]]
RewardsConfig.Playtime = {
	{ at = 60,   coins = 150,   label = "1 MIN" },
	{ at = 300,  coins = 450,   label = "5 MIN" },
	{ at = 600,  coins = 1100,  label = "10 MIN" },
	{ at = 1200, coins = 2600,  label = "20 MIN" },
	{ at = 1800, coins = 6000,  label = "30 MIN" },
	{ at = 2700, coins = 5500,  label = "45 MIN" },
	{ at = 3600, coins = 7500,  label = "60 MIN" },
	{ at = 5400, coins = 14000, label = "90 MIN" },
}

--------------------------------------------------------------------------
-- DAILY  --  the streak ladder
--------------------------------------------------------------------------
--[[
	Seven rungs, then it holds at the top rather than resetting to day 1. A
	ladder that dumps a player back to 500 coins on day 8 punishes the exact
	habit it exists to build.

	A MISSED DAY BREAKS THE STREAK BACK TO 1, not to 0 -- you are on day one
	again, and day one still pays. There is no state in which opening this panel
	on a new day offers nothing.
]]
RewardsConfig.DailyLadder = {
	{ day = 1, coins = 500 },
	{ day = 2, coins = 900 },
	{ day = 3, coins = 1500 },
	{ day = 4, coins = 2400 },
	{ day = 5, coins = 3800 },
	{ day = 6, coins = 6000 },
	{ day = 7, coins = 12000 },
}

--[[
	A FLOOR UNDER THE DAILY LADDER, INDEXED TO THE TIDE RATHER THAN THE
	MULTIPLIER.  2026-09-19.

	The rungs above are scaled by SellMultiplier, which is right as far as it goes
	-- but it does not go far enough, and the gap is measurable rather than a
	matter of taste. Across the authored run SellMultiplier grows 819x while the
	rebirth requirement grows about 9,400,000x, so the day-7 reward as a share of
	the run it is measured against collapses:

		tide  1    needs 3,600        day 7 pays 12,000       333%
		tide 48    needs 33,800,000,000  day 7 pays 9,832,800   0.03%

	The early figure is the outlier, not the late one -- 12,000 coins when a whole
	rebirth costs 3,600 is three runs in a day. But by the back half the ladder is
	no longer a reason to come back tomorrow, which is the only job it has.

	SO A FLOOR, NOT A REPLACEMENT. Whichever of the two is larger wins, so nothing
	gets worse for anybody and the existing curve keeps owning the early game
	where it is already generous. Measured, the floor takes over around tide 22.

	FIVE PER CENT OF THE NEXT TIDE'S REQUIREMENT for the top rung, shared down the
	ladder in proportion to each rung's own coins -- so day 1 is still a seventh of
	day 7 and the shape a player learned does not change. A full week comes to
	roughly 11% of one rebirth at any tide, which is worth logging in for and is
	nowhere near a shortcut.

	IT DOES NOT COMPETE WITH THE COIN PACKS, and that was the thing to check
	before touching this. ProductConfig's own note settles it: the packs are flat
	on purpose and "are EARLY AND MID GAME products" that are "beneath notice by
	tide twenty". This floor only does anything after that point.

	DELIBERATELY NOT APPLIED TO THE PLAYTIME TIERS OR THE QUESTS. Those are
	in-session rewards and their job is done by the multiplier; the retention
	argument -- a reason to come back TOMORROW -- belongs to this ladder alone.
]]
RewardsConfig.DailyFloorPct = 0.05

local DAILY_TOP = 0
for _, r in ipairs(RewardsConfig.DailyLadder) do
	DAILY_TOP = math.max(DAILY_TOP, tonumber(r.coins) or 0)
end

--[[
	What this rung is worth as a share of the next rebirth, or 0 when the caller
	has no requirement to hand. Total: a nil or nonsense requirement returns 0,
	which makes the max() at the call site fall back to the scaled figure.
]]
function RewardsConfig.dailyFloor(rung, requirement: number?): number
	local need = tonumber(requirement)
	if not need or need ~= need or need <= 0 or DAILY_TOP <= 0 then
		return 0
	end
	local share = (tonumber(rung and rung.coins) or 0) / DAILY_TOP
	return math.floor(need * RewardsConfig.DailyFloorPct * share)
end

-- Where a streak longer than the ladder sits. Clamped rather than wrapped.
function RewardsConfig.rungFor(streak: number)
	local n = #RewardsConfig.DailyLadder
	local i = math.clamp(math.floor(streak), 1, n)
	return RewardsConfig.DailyLadder[i], i
end

--[[
	THE WARDROBE LADDER  --  the first week, paid in a tool rather than coins

	THE PROBLEM THIS SOLVES, and it is a measured one. The four room skins gate
	on islands 3, 6, 7 and 9; the live funnel reaches those at 4.54%, 0.45%,
	0.01% and never. So ~95% of players never unlock a cosmetic at all, and the
	ladder above pays every one of them in COINS -- which are invisible, fungible
	and wiped at the next rebirth. Day two of that ladder is 900 coins, about
	three minutes of tide-0 income, and a player cannot see it without opening a
	panel they have no reason to open yet.

	These three rungs pay in the one slot the player looks at all session: the
	tool in their hands. See the block above SkinConfig's `driftwood` for why it
	is one tool in three stages rather than three tools.

	WHY THE FIRST RUNG IS PLAYTIME AND THE OTHER TWO ARE DAYS. Rung one has to
	land inside the opening session or it does nothing for the people who leave
	and never come back -- which is the population this whole ladder is aimed at.
	Ten minutes is the existing Playtime rung, so it is a threshold the file
	already tracks rather than a new clock.

	CUMULATIVE DAYS, NOT THE STREAK, and that is a deliberate departure from the
	DailyLadder above. A streak resets to 1 on a single missed day. Taking a
	half-finished cosmetic arc away from somebody because they missed a Tuesday
	is a reason to stop playing, not a reason to come back, and the arc is the
	thing doing the retaining. `daysVisited` only ever goes up.

	THEY ARE MILESTONE QUESTS, and that is the second shape this took. The first
	swept them out automatically the moment the threshold was met, on the
	reasoning that a player who has not found the Rewards panel should not have
	to find it to be given something. The owner's call was that they should be
	CLAIMED, and the milestone rows are where that belongs: they never reset,
	they already draw a progress bar and a claim button, and `rewardsReady`
	already lights the rail badge for them. So there is no Wardrobe table any
	more -- the three rungs live in Quests below, carrying a `skin` field.

	CUMULATIVE DAYS, NOT THE STREAK. A streak resets to 1 on a single missed day.
	Taking a half-finished cosmetic arc away because somebody missed a Tuesday is
	a reason to stop playing, not a reason to come back -- and the arc is the
	thing doing the retaining. `daysVisited` only ever goes up. That is also why
	these could not simply ride the DailyLadder rungs above, which are streak-keyed.

	ADDING A RUNG is a milestone row in Quests below carrying a `skin`, plus the
	skin itself in SkinConfig. claimQuest hands it over; nothing else needs to know.
]]

--------------------------------------------------------------------------
-- QUESTS
--------------------------------------------------------------------------
--[[
	`stat`   which counter to read (see the header)
	`need`   the threshold
	`daily`  measured against the day's baseline, and re-offered every day

	The daily three are deliberately reachable in one sitting -- a daily quest
	you cannot finish today is a milestone wearing the wrong hat.
]]
RewardsConfig.Quests = {
	--[[
		THE DAILY POOL. Eight of these, of which DailyPerDay are live on any
		given day -- see dailyToday at the foot of this file. The order is not
		cosmetic: the rotation takes a sliding window of three, so the entries
		are interleaved easy/hard rather than grouped, and every window it can
		land on carries something a first-day player can finish.

		Thresholds are flat while the payouts are scaled by rebirth (see
		RewardsServer.scaled), which means a deep player clears these quickly.
		That is the pre-existing bargain and this change does not alter it.
	]]
	{
		key = "d_earn", daily = true, stat = "earned", need = 25000, coins = 1200,
		label = "BEACHCOMBER", blurb = "Earn 25,000 coins today",
	},
	{
		key = "d_trash2", daily = true, stat = "trash", need = 350, coins = 2400,
		label = "SPRING CLEAN", blurb = "Pick up 350 pieces of litter today",
	},
	{
		key = "d_play", daily = true, stat = "playSec", need = 900, coins = 1000,
		label = "LONG SHIFT", blurb = "Spend 15 minutes on the beach today",
	},
	{
		key = "d_earn2", daily = true, stat = "earned", need = 120000, coins = 3000,
		label = "DEEP POCKETS", blurb = "Earn 120,000 coins today",
	},
	{
		key = "d_levels", daily = true, stat = "levels", need = 2, coins = 1500,
		label = "KITTED OUT", blurb = "Buy 2 upgrade levels today",
	},
	{
		key = "d_play2", daily = true, stat = "playSec", need = 1800, coins = 2200,
		label = "DOUBLE SHIFT", blurb = "Spend 30 minutes on the beach today",
	},
	{
		key = "d_trash", daily = true, stat = "trash", need = 120, coins = 1100,
		label = "LITTER PATROL", blurb = "Pick up 120 pieces of litter today",
	},
	{
		key = "d_levels2", daily = true, stat = "levels", need = 5, coins = 3200,
		label = "GEARED UP", blurb = "Buy 5 upgrade levels today",
	},

	-- Milestones. Never reset, and ordered so the first one lands early enough
	-- to teach the player that this tab pays out at all.
	{
		key = "m_earn1", stat = "earned", need = 10000, coins = 2000,
		label = "FIRST HAUL", blurb = "Earn 10,000 coins",
	},
	{
		key = "m_kit", stat = "levels", need = 25, coins = 5000,
		label = "WELL EQUIPPED", blurb = "Reach 25 upgrade levels",
	},
	{
		key = "m_wheels", stat = "vehicle", need = 1, coins = 4000,
		label = "MOTOR POOL", blurb = "Own a vehicle",
	},
	{
		key = "m_tide1", stat = "rebirths", need = 1, coins = 8000,
		label = "TIDE TURNER", blurb = "Turn the tide once",
	},
	{
		key = "m_earn2", stat = "earned", need = 1000000, coins = 20000,
		label = "DEEP POCKETS", blurb = "Earn 1,000,000 coins",
	},
	{
		key = "m_tide5", stat = "rebirths", need = 5, coins = 40000,
		label = "OLD SALT", blurb = "Reach 5 rebirths",
	},

	--[[
		THE WARDROBE RUNGS -- see the block above DailyLadder for why these exist
		and why they count days rather than a streak.

		`skin` is the payout and `coins` is deliberately 0: the tool IS the
		reward, and a coin figure beside it would only invite the player to
		compare the two. claimQuest skips the payment entirely when coins is 0 so
		nothing announces "+0 coins".

		THE FIRST ONE IS PLAYTIME, THE OTHER TWO ARE DAYS, and the mix is the
		point rather than an inconsistency. Rung one has to land inside the
		opening session or it does nothing for the people who leave and never come
		back -- which is the population this ladder exists for. Ten minutes is
		already a Playtime threshold, so it is a clock the file keeps anyway.

		`playSec` IS TODAY'S SECONDS, and as a milestone that reads "ten minutes
		in any one day" rather than ten minutes ever. That is the intended
		meaning: it latches in `lifeDone` the first time it is claimed and never
		comes back.
	]]
	{
		key = "w_rake1", stat = "playSec", need = 600, coins = 0, skin = "driftwood",
		label = "DRIFTWOOD RAKE", blurb = "Spend 10 minutes on the beach",
	},
	{
		key = "w_rake2", stat = "daysVisited", need = 3, coins = 0, skin = "beachcomber",
		label = "BEACHCOMBER'S RAKE", blurb = "Come back on 3 different days",
	},
	{
		key = "w_rake3", stat = "daysVisited", need = 7, coins = 0, skin = "longshore",
		label = "LONG SHORE RAKE", blurb = "Come back on 7 different days",
	},
	--[[
		PAST THE FIRST WEEK. The ladder used to stop at seven, which meant the
		player who had come back every day for a week was handed the last thing
		this tab would ever offer them for coming back at all.

		These two count DISTINCT DAYS, not a streak: they cannot be lost, only
		slowed. That is the point of hanging the longest rewards off daysVisited
		rather than off `streak` -- a month-long goal that a single missed day
		could reset is a month-long goal nobody sane pursues.
	]]
	{
		key = "w_rake4", stat = "daysVisited", need = 14, coins = 0, skin = "stormglass",
		label = "STORMGLASS RAKE", blurb = "Come back on 14 different days",
	},
	{
		-- The only pet in the game that is not bought, rolled or traded for.
		-- RewardsServer.claimQuest hands it over through PetServer.grant, the
		-- same seam `skin` uses for SkinService.grant.
		key = "w_pet", stat = "daysVisited", need = 30, coins = 0, pet = "Tidewarden",
		label = "TIDEWARDEN", blurb = "Come back on 30 different days",
	},
}

-- Built once rather than searched: the claim path looks a key up per press.
RewardsConfig.QuestByKey = {}
for _, q in ipairs(RewardsConfig.Quests) do
	RewardsConfig.QuestByKey[q.key] = q
end

--[[
	THE DAY KEY IS UTC, and it is a string rather than a number on purpose: it
	goes into a DataStore, it gets compared for equality, and it has to mean the
	same thing when read back by a server in another region. `os.date("!...")`
	is the UTC form -- without the bang this would roll over at the whim of
	whichever machine happened to hold the session.
]]
function RewardsConfig.dayKey(at: number?): string
	return os.date("!%Y-%m-%d", at or os.time())
end

--[[
	HOW MANY DAYS A DATE IS FROM THE EPOCH, computed rather than round-tripped
	through `os.time`.

	The obvious version parses the date into a table, adds 86400 and formats it
	back -- and it rests on `os.time(table)` being read as UTC. Roblox does read
	it that way and standard Lua does NOT (it uses local time), which makes the
	obvious version correct here and quietly wrong the moment this file is read
	outside Roblox or the engine changes its mind. A streak is not worth that
	kind of dependency, so the arithmetic is done in full below.

	This is the civil-from-days algorithm run backwards: March is treated as the
	start of the year so that the leap day lands at the END, which is what makes
	the month-length series repeat cleanly and removes the February special case
	entirely.
]]
local function daysFromCivil(y: number, m: number, d: number): number
	y = (m <= 2) and (y - 1) or y
	local era = math.floor(y / 400)
	local yoe = y - era * 400                                  -- 0..399
	local doy = math.floor((153 * ((m > 2) and (m - 3) or (m + 9)) + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

local function dayNumber(key: string): number?
	if type(key) ~= "string" then
		return nil
	end
	local y, m, d = key:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if not y then
		return nil
	end
	return daysFromCivil(tonumber(y), tonumber(m), tonumber(d))
end
RewardsConfig.dayNumber = dayNumber

-- Whether `today` is the calendar day straight after `prev`. A calendar
-- question, not an elapsed-time one: somebody who plays at 23:50 and again at
-- 00:10 has come back the next day, eleven hours short of twenty-four.
function RewardsConfig.isNextDay(prev: string, today: string): boolean
	local a, b = dayNumber(prev), dayNumber(today)
	return (a ~= nil and b ~= nil) and (b - a == 1) or false
end

-- Whole days between two dayKeys, or nil if either will not parse. isNextDay is
-- the gap == 1 case; the grace below is the one caller that needs to tell a
-- gap of 2 from a gap of 9.
function RewardsConfig.dayGap(prev: string, today: string): number?
	local a, b = dayNumber(prev), dayNumber(today)
	if a == nil or b == nil then
		return nil
	end
	return b - a
end

--[[
	ONE MISSED DAY IS FORGIVEN, once per full turn of the ladder.

	A streak that resets on the first slip punishes the ordinary shape of a
	life -- a shift, a holiday, a flat battery -- and the player who loses six
	days on the seventh is the player who stops opening this panel at all. The
	save is worth more than the coins it protects: it is a reason to come back
	on the day AFTER the one you missed, which is precisely the day the old
	rule told you not to bother.

	IT CANNOT BE FARMED INTO EVERY-OTHER-DAY PLAY. The forgiveness is spent
	when used and only returns after a full ladder of consecutive days, so an
	alternating player burns it once and then resets -- they oscillate on the
	bottom rung and never climb. rollDay in RewardsServer has that walk.

	The streak HOLDS rather than advances when it is spent. They did not play
	that day, and the rung label should not claim they did.
]]
RewardsConfig.GraceDays = 1

--------------------------------------------------------------------------
-- DAILY ROTATION
--------------------------------------------------------------------------
--[[
	Three of the eight dailies are live on any given day, picked from the day
	number so that nothing has to be stored: every server works out the same
	three for the same date, whether it is asked at a boot, on a join, or on
	the tick that crosses midnight. Rotating them is the point -- a fixed
	three stop being a reason to come back once you have seen them.

	The window slides by its own width, so no quest appears two days running.
	gcd(DailyPerDay, #pool) = gcd(3, 8) = 1 is what makes the walk visit every
	entry rather than settling into a short orbit; change either number and
	check that still holds, or part of the pool will never be dealt.

	NOTE FOR RewardsServer: rotation decides what is OFFERED, never what is
	measured. rollDay still stamps a baseline for every daily stat in the
	pool, including the rotated-out ones, because progressFor treats a missing
	baseline as zero -- which would read a lifetime total as one day's work and
	hand the quest over the instant it rotated back in.
]]
RewardsConfig.DailyPerDay = 3

function RewardsConfig.dailyPool(): { any }
	local pool = {}
	for _, q in ipairs(RewardsConfig.Quests) do
		if q.daily then
			pool[#pool + 1] = q
		end
	end
	return pool
end

-- The keys live on `at` (a dayKey string; defaults to today). A set rather
-- than a list because every caller asks "is this one live", never "what is
-- the third one".
function RewardsConfig.dailyToday(at: string?): { [string]: boolean }
	local pool = RewardsConfig.dailyPool()
	local live = {}
	local count = #pool
	if count == 0 then
		return live
	end

	local per = math.clamp(math.floor(RewardsConfig.DailyPerDay), 1, count)
	if per >= count then
		for _, q in ipairs(pool) do
			live[q.key] = true
		end
		return live
	end

	-- A blank or unparseable date rotates to the first window rather than to
	-- none: a fresh session whose day has not rolled yet should still find
	-- three quests in the tab, not an empty one.
	local stamp = (type(at) == "string" and at ~= "") and at or RewardsConfig.dayKey()
	local day = dayNumber(stamp) or 0
	for i = 0, per - 1 do
		live[pool[((day * per + i) % count) + 1].key] = true
	end
	return live
end

function RewardsConfig.isDailyToday(key: string, at: string?): boolean
	return RewardsConfig.dailyToday(at)[key] == true
end

return RewardsConfig
