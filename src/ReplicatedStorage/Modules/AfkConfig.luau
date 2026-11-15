--[[
	AfkConfig  --  ReplicatedStorage.Modules.AfkConfig

	The rules of THE LONG SHORE, shared by the three files that run it:
		ServerScriptService.AfkShoreBuilder  the world
		ServerScriptService.AfkService       plots, the door, the wallet
		StarterPlayerScripts.AfkClient       the puppet and the card

	One module rather than three copies of eight numbers, for the reason every
	shared config in this game exists: the pay rate is quoted on the card, used
	by the server that actually pays it, and printed on a sign in the world, and
	those three must never be able to disagree.

	WHAT IT IS. A stretch of empty dawn beach, off the map, cut into eight small
	bays. A player who goes idle is put in one and their character rakes it, up
	and down, for as long as they stay. It pays, slowly.

	WHY IT IS OFF THE MAP RATHER THAN A CORNER OF THE BEACH. Three reasons, all
	of them things that bit Seal A Driveway's version before it moved:
	  * a puppet walking a fixed lap through live geography eventually walks
	    into a player, a dropped tool or a parked ATV;
	  * the rakeable field is per-player terrain state (see CTB_Client) and an
	    idler raking real sand would be raking somebody's progress;
	  * every raycast the game fires -- litter, the sifter, the ferry -- is one
	    more thing that can hit an idler standing in the world.
	Eight thousand studs out, none of that can reach.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--[[
	THE REBIRTH LADDER. Two things are wanted from it and nothing else: the
	multiplier a tide is worth, and how many tides the game HAS (the clamp in
	rebirthsOf). Reading them is what pins the shore's pay to the same curve the
	rest of the economy is pitched against instead of to a copy of it.

	ADDRESSED THROUGH ReplicatedStorage AND NOT THROUGH script.Parent, which is
	not fussiness: ServerStorage.EconomyAudit requires this module off a CLONE
	parented to itself, so `script.Parent` out there is the audit and a
	WaitForChild on it would hang the tool forever.
]]
local ProgressionConfig = require(
	ReplicatedStorage:WaitForChild("Modules"):WaitForChild("ProgressionConfig"))

local AfkConfig = {}

--------------------------------------------------------------------------
-- WHERE
--------------------------------------------------------------------------

-- Far enough that nothing in the live map can touch it. The islands span
-- x -2300..1600 and z -400..1800, so this is roughly six thousand studs clear
-- of the nearest thing on either axis.
AfkConfig.Origin = Vector3.new(8000, 0, 8000)

-- One bay per player. The ninth doubles up rather than being turned away --
-- being told the idle area is full is a worse experience than sharing a beach
-- with somebody, and two puppets raking one bay reads as two people raking one
-- beach, which is exactly what it is.
AfkConfig.PlotCount = 8

-- Bay footprint and the gap between them. The gap is wide enough that a puppet
-- overshooting its lane end by a stud is still in its own bay.
AfkConfig.PlotWidth = 60      -- along X, the direction the lanes run
AfkConfig.PlotDepth = 44      -- along Z, sea at +Z, dune bank at -Z
AfkConfig.PlotGap = 36

AfkConfig.SandY = 0           -- the raked surface, relative to Origin.Y

-- Bay N's origin, N being 1..PlotCount. Laid in a row rather than a grid so
-- every bay faces the same sea and one shoreline serves all eight.
function AfkConfig.plotOrigin(index: number): Vector3
	local pitch = AfkConfig.PlotWidth + AfkConfig.PlotGap
	local span = (AfkConfig.PlotCount - 1) * pitch
	return AfkConfig.Origin + Vector3.new((index - 1) * pitch - span * 0.5, 0, 0)
end

--------------------------------------------------------------------------
-- THE WALK
--------------------------------------------------------------------------

-- A RAKING PACE, fixed, and deliberately not the player's own speed.
--
-- BeachLegs starts at 24 now and runs to 66, and nobody drags a rake at 66 --
-- at the top of that track the puppet reads as a man skating a beach. The card
-- and the pay do not care what this is, so it is free to be whatever looks
-- right, and 10 still looks like work. (The floor was 16 until 2026-08-28; the
-- gap between a stroll and a walk widened, which if anything helps here.)
AfkConfig.WalkSpeed = 10

-- The lap. Lanes run along X (the long axis of the bay) and step toward the
-- sea, so the puppet walks the bay the way a person actually rakes one: out,
-- step over, back, step over.
AfkConfig.LaneCount = 5
AfkConfig.LaneInset = 6       -- how far the first and last lane sit inside the bay

-- What stops the walk reading as a path-follower. Every one of these is free:
-- none of them touch the pay, which is wall-clock (see below).
AfkConfig.TurnFloor = 0.42    -- fraction of WalkSpeed carried through a corner
AfkConfig.TurnRadius = 6      -- studs from the waypoint where the ease begins
AfkConfig.PauseMin = 0.30     -- a beat at each lane end...
AfkConfig.PauseMax = 0.65     -- ...varied, because identical pauses are a tell
AfkConfig.Wander = 0.5        -- studs of drift off the aim
AfkConfig.WanderRate = 0.9    -- rad/sec the drift turns at
AfkConfig.RestHold = 5        -- seconds spent standing at the water's edge

--------------------------------------------------------------------------
-- THE PAY
--------------------------------------------------------------------------

--[[
	PAID FOR WALL-CLOCK SECONDS, NOT FOR RAKED SAND.

	This is the load-bearing decision of the whole feature and it is worth being
	explicit about. The puppet is COSMETIC: it does not call the rake, it does
	not write terrain, it does not add to the beach-raked percentage. It walks,
	and the server pays a rate per second regardless.

	The alternative -- pay for what the puppet actually rakes -- sounds more
	honest and is a trap. It makes income depend on the client's frame rate, so
	a player in a background tab at 2 fps earns a fraction of one watching it,
	which punishes exactly the behaviour the mode is for. It also puts a number
	the server pays out under the client's control.

	So: the walk is a picture of working, and the clock is the wage.
]]

-- Coins per second at multiplier 1.0. The ONE lever -- the card, the sign in
-- the world and the server's payout all read it, so moving this moves all
-- three together.
--
-- WAS 2, CUT TO 1.2 (x0.6) ON 2026-08-26, together with SessionCap, because
-- the shore was paying too much of a tide for standing still: one capped
-- session ran from a fifth to OVER HALF of the rebirth it was earned in
-- (56.6% at tide 2), and a tide-0 idler collected 3,600 against a 10,800
-- first-rebirth gate. The two dials moved by the SAME factor on purpose --
-- see SessionCap for why they are one decision, and why TideGrowth is not
-- part of it.
--
-- The pitch now, measured: an idle minute is worth 34% of a played one on the
-- tutorial tide and 11-21% of one for the rest of the run. Active play must
-- stay clearly better than this; if it ever is not, active play is what wants
-- looking at, not this number.
AfkConfig.BaseRate = 1.2

--[[
	IDLING SCALES WITH THE RUN, AND SellMultiplier ALONE IS NOT THE RUN.

	This used to be `BaseRate * SellMultiplier` and the instinct was right with
	the wrong arithmetic. SellMultiplier is ProgressionServer's rebirth
	multiplier and nothing else -- 1.15^n, written on join and after every
	purchase and rebirth. But a tide's INCOME is five terms compounding, not
	one: that multiplier TIMES the levels the new ceiling lets you afford TIMES
	the island premiums TIMES pets TIMES the batch bonus. Measured across the
	live curve (ServerStorage.EconomyAudit) that product grows about 1.36x a
	tide while SellMultiplier grows 1.15x -- so the shore fell behind by ~1.18x
	EVERY rebirth, and it compounds:

		tide   the shore paid   active play      the shore was worth
		   0        120/min        175/min       68% of playing
		   8        367/min        4.70K/min      7.8%
		  20       1.96K/min     141.80K/min      1.4%
		  39      27.95K/min      25.62M/min      0.1%

	By the Cove it was a rounding error and by Ashfall it was noise. An idle
	mode that stops paying is an idle mode nobody uses, and the players it
	stopped paying were the ones who had played longest -- which is the exact
	failure the old note here claimed to be preventing.

	TideGrowth IS THE OTHER FOUR TERMS, and it is measured rather than guessed:
	income's per-tide growth DIVIDED BY SellMultiplier's own audits at 1.1796
	across the forty-tide run. It is rounded DOWN to 1.17, to the step that
	leaves tide 0 the high-water mark of the whole curve -- so the shore is
	never relatively BETTER than it is on the tutorial tide, and never worse
	than about a ninth of playing:

		tide   the shore is worth   one full session is worth
		   0    34% of playing      10.3 minutes of playing
		   8    12%                  3.5
		  16    12%                  3.5
		  24    13%                  3.8
		  40    21%                  6.4

	⚠️ THIS IS NOT THE NERF DIAL, AND MOVING IT HERE WOULD UNDO ONE. TideGrowth
	is the term that keeps the shore TRACKING the run; the 2026-08-26 cut went
	entirely into BaseRate and SessionCap, which are a vertical scale and leave
	this curve's SHAPE exactly where it was. Raising it to lift the thin middle
	does not work either -- measured, it tilts the TAIL up (at 1.185 the whole
	curve peaks at rb 40 instead of rb 0, which is the first thing EconomyAudit's
	H8 fails) and barely moves the rb 8-16 trough at all. That trough is the
	Dunes premium (2.31x) landing early, and no single exponent tracks a step.

	RETUNE WITH THE AUDIT OPEN. EconomyAudit's AFK block re-derives that table
	from the live config and fails the run if the band drifts; run it after
	touching this, BaseRate, SessionCap, CostGrowth, the rebirth curve or the
	island premiums.
]]
AfkConfig.TideGrowth = 1.17

--[[
	Tides behind this player, CLAMPED TO THE AUTHORED LADDER -- and since the
	tide count itself stopped being capped (2026-09-11,
	ProgressionConfig.Rebirth.LadderTides) this clamp is a real decision rather
	than the corrupt-attribute guard it started as.

	TideGrowth^n IS FROZEN AT THE END OF THE AUTHORED RUN, ON PURPOSE. The
	whole table above is MEASURED across tides 0-40: 1.17 is income's per-tide
	growth divided out by SellMultiplier over that run, and it is only honest
	where the other four terms actually behave that way. Past 40 they do not --
	the ceiling has been flat at MaxLevel since 36 and the last island premium
	landed at 32, so the only term still moving up there IS SellMultiplier.
	Letting 1.17^n run on would be claiming growth that has stopped, and it
	compounds: at tide 80 it would pay the shore ~1,500x what tide 40 does
	against an income that grew ~270x.

	THE SHORE STILL GROWS PAST 40, just not twice. runScale below multiplies
	this by the live SellMultiplier attribute, which goes on compounding at
	1.15 a tide for ever -- so an endless-ladder player keeps being paid more
	for idling, at exactly the rate their sell multiplier says they should be.
]]
function AfkConfig.rebirthsOf(player: Player): number
	local n = player and player:GetAttribute("Rebirths")
	if type(n) ~= "number" or n ~= n then
		return 0
	end
	return math.clamp(math.floor(n), 0, ProgressionConfig.Rebirth.LadderTides)
end

--[[
	WHAT ONE SECOND OF THIS PLAYER'S RUN IS WORTH AGAINST A TIDE-0 SECOND.

	⚠️ THE ONE PLACE THE TWO TERMS ARE MULTIPLIED, and the rate and the cap both
	read it. A rate that scales against a cap that does not is a ceiling the
	player hits in 30/1.17^n minutes -- three seconds of shore by the fortieth
	tide, which is a worse bug than the one this fixes.

	The multiplier is READ OFF THE ATTRIBUTE rather than re-derived from the
	rebirth count, so anything the server ever folds into SellMultiplier (an
	event, a pass) reaches the shore without this file being told.
]]
function AfkConfig.runScale(player: Player): number
	local mult = player and player:GetAttribute("SellMultiplier")
	if type(mult) ~= "number" or mult ~= mult or mult <= 0 then
		mult = 1
	end
	return mult * (AfkConfig.TideGrowth ^ AfkConfig.rebirthsOf(player))
end

--[[
	The same scale for a tide nobody is standing in -- the audit, a panel
	previewing the next rebirth. Identical product with the multiplier taken
	from the ladder instead of from the attribute, so the two agree wherever
	ProgressionServer has run.

	⚠️ ONLY THE TideGrowth EXPONENT IS CLAMPED, and that asymmetry is what keeps
	the two in step now that the ladder is endless. runScale reads the LIVE
	SellMultiplier attribute, which goes on compounding past the authored run,
	and raises TideGrowth to the clamped count from rebirthsOf. Clamping both
	terms here -- which this did until 2026-09-11 -- made scaleAt(50) answer for
	tide 40 while runScale answered honestly for tide 50, so the audit and every
	preview panel would have under-read the shore for exactly the players whose
	tide nobody had authored.
]]
function AfkConfig.scaleAt(rebirths: number): number
	local n = math.max(0, math.floor(tonumber(rebirths) or 0))
	local growthTides = math.min(n, ProgressionConfig.Rebirth.LadderTides)
	return ProgressionConfig.Rebirth.multiplier(n) * (AfkConfig.TideGrowth ^ growthTides)
end

function AfkConfig.rateFor(player: Player): number
	return AfkConfig.BaseRate * AfkConfig.runScale(player)
end

--[[
	HOW MUCH ONE PLAY SESSION MAY EARN OUT HERE IN TOTAL.

	WHY THERE IS A CEILING AT ALL. Measured at tide 0: active play earns about
	262 coins a minute once the walking and the wash bay are counted, and this
	shore pays 120 a minute for nothing at all. That is roughly 46% of playing,
	for a mode that asks the player to not be there -- and now that TideGrowth
	holds that share across the run instead of letting it rot, the ratio no
	longer improves OR decays. An uncapped faucet at half the rate of the game
	is not an idle reward, it is an alternative to the game, and it is a
	permanent one.

	SO THE CEILING IS WHAT MAKES THE SCALING SAFE. Those two changes are one
	decision: the rate is allowed to keep pace with the run precisely because
	the TOTAL is bounded to half an hour of it.

	⚠️ THIS IS THE DIAL THAT SETS HOW STRONG THE MODE IS. BaseRate IS NOT, and
	the arithmetic is worth doing rather than believing: a session's total in
	PLAYED minutes is SessionCap * runScale / income -- BaseRate does not appear
	in it at all. All BaseRate sets is how long you must idle to collect that
	total (SessionCap / BaseRate seconds). Halving BaseRate on its own therefore
	changes nothing about the mode's power; it doubles the wait for the same
	money. Anything that wants the shore to be worth LESS has to come out here.

	2160 WAS 3600, cut 2026-08-26 alongside BaseRate by the same factor so that
	SessionCap / BaseRate is still 1800 seconds and every "thirty minutes" in
	this block stayed true. What the cut bought, measured: a capped session went
	from 18-57% of the rebirth it is earned in to 11-34% of it, and the tide-0
	session from a third of the first rebirth's 10,800 gate to a fifth of it.

	SCALED BY THE RUN, THROUGH THE SAME runScale THE RATE USES -- see the ⚠️ on
	it. A flat cap would be thirty minutes of shore on a first tide and four
	seconds of it by the fortieth, which is the same defect the rate's own
	scaling exists to avoid; a cap scaled by a DIFFERENT term to the rate is
	that defect again, wearing the rate's own numbers.

	Because both terms are the same, this is thirty minutes of shore on every
	tide of the run, and what those thirty minutes are WORTH tracks what a tide
	is worth: 10.3 minutes of active play at tide 0, 3.5 at tide 8, 6.4 at
	tide 40.
]]
AfkConfig.SessionCap = 2160

--[[
	The cap in this player's money, or math.huge if capping is switched off.

	`<= 0` DISABLES IT rather than meaning "pay nothing", because a zero cap is
	far more likely to be somebody turning the feature off than somebody asking
	for an idle shore that never pays. Returning math.huge lets the caller keep
	one code path either way.
]]
function AfkConfig.capFor(player: Player): number
	if type(AfkConfig.SessionCap) ~= "number" or AfkConfig.SessionCap <= 0 then
		return math.huge
	end
	return AfkConfig.SessionCap * AfkConfig.runScale(player)
end

-- How often the server banks what has accrued. Not every frame: addCoins goes
-- through SellServer, which fires OnCoinsChanged and repaints every open panel
-- watching the balance.
AfkConfig.PayInterval = 1.0

--------------------------------------------------------------------------
-- THE CONTRACT WITH EVERYTHING ELSE
--------------------------------------------------------------------------

-- Set on the PLAYER for the length of a visit. Anything that needs to know
-- whether somebody is idle asks this and nothing else -- it is the one fact,
-- and it is on the player rather than the character so it survives a respawn
-- long enough for AfkService to see it and clean up.
AfkConfig.Attr = "AfkPlot"        -- number 1..PlotCount, or nil
AfkConfig.EarnedAttr = "AfkEarned" -- coins banked THIS visit, for the card

function AfkConfig.plotOf(player: Player): number?
	local v = player and player:GetAttribute(AfkConfig.Attr)
	return (type(v) == "number") and v or nil
end

-- The folder the world lives under, and the marker attribute the builder uses
-- to decide whether it has already been built. Same adoption contract as every
-- other builder in this place: geometry saved in the file wins, and the module
-- is the recipe for a place that has lost it.
AfkConfig.FolderName = "AfkShore"

--[[
	WHAT THE RateBoard OUT THERE SAYS.

	A function rather than a string, because the number it quotes is BaseRate
	and the number the server pays is BaseRate times the run. A board reading a
	flat "2 COINS / SEC" at a player being paid 286,000 of them is exactly the
	disagreement the header of this file exists to prevent -- the card, the till
	and the sign are three readings of one number and must never be able to
	diverge.

	AfkShoreBuilder draws it, and re-dresses an ADOPTED board with it on boot:
	the shore is built once and kept, so a place that already has one would
	otherwise keep the old wording forever.
]]
function AfkConfig.signText(): string
	--[[
		⚠️ NOT "%d", AND THE REASON IS NOT STYLE. BaseRate is 1.2 now, and %d
		TRUNCATES a fractional number rather than erroring on it -- so the board
		out on the shore would have read "1 COINS / SEC", a fifth under what the
		till actually pays, silently, which is exactly the sign-vs-card-vs-till
		disagreement this whole file exists to prevent. "%.10g" prints 1.2 as
		"1.2" and an integer rate as "2" rather than as "2.0".
	]]
	return ("%.10g COINS / SEC x YOUR TIDE"):format(AfkConfig.BaseRate)
end
AfkConfig.BuiltAttr = "AfkShoreBuilt"

return AfkConfig
