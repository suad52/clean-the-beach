--[[
	BoostConfig  --  ReplicatedStorage.Modules.BoostConfig


	A GOLDEN HOUR YOU CAN BUY, and the only thing in the game that sells a
	MULTIPLIER rather than an amount.

	WHY THAT DISTINCTION IS THE WHOLE PRODUCT. ProductConfig's coin ladder note
	already works this out and writes it down: a flat pack is worth progressively
	less as the run goes on -- the Hoard is about 1,800 bags at tide zero and
	under two against a x1,469 multiplier -- so the packs are early and mid game
	products and are priced and described as such. That note closes with "if they
	ever need to matter at forty rebirths the answer is a new top rung, not
	turning scaling back on", because a scaled pack cannot state what it gives
	you and a product that cannot state what it gives you is a terms page.

	A MULTIPLIER ESCAPES BOTH HORNS. "Everything sells for double for fifteen
	minutes" is a fixed, printable promise -- the button can say it, the store
	page can say it, and a player knows exactly what they bought. And it is worth
	proportionally the same at tide 1 and at tide 40, because it multiplies
	whatever the run is already producing. It is the one shape that is honest on
	the shelf AND does not decay.


	WHERE IT LIVES: TWO PLAYER ATTRIBUTES, AND EXPIRY IS TRUE BY READING.

		CTB_BoostMultiplier   what a sale is multiplied by while it runs
		CTB_BoostUntil        os.time() the boost stops being worth anything

	NOTHING SCHEDULED DECIDES WHETHER A BOOST IS LIVE. `multiplierFor` compares
	the stored deadline against the clock every time it is asked, so a boost is
	over the instant it is over -- whatever happened to the tidy-up loop, the
	server's frame rate, or the thread that was supposed to clear it. BoostService
	still runs that loop, but only to wipe the attributes and say so; it is not
	load-bearing, which is deliberate. A timed product whose end depends on a
	scheduled write is a product that occasionally does not end.

	ABSOLUTE TIME, NOT REMAINING TIME, for the same reason EventConfig's timetable
	is arithmetic on os.time(): a deadline survives being written to a datastore
	and read back in another server ten minutes later, and a countdown does not.

	PLAYER ATTRIBUTES REPLICATE, so the HUD needs no remote and a late joiner's
	readout is correct the first time it draws -- the same arrangement, and the
	same reasoning, as the leaderboard's standings attributes. What it costs is
	that other players can see your boost, which is not a secret: they can see the
	gold on your sale toast anyway.


	IT IS A FOURTH NUMBER, NEVER FOLDED INTO THE OTHER THREE. SellServer already
	carries the rebirth multiplier, the 2x Cash pass and the live event, and says
	twice in its own comments why they ride alongside each other instead of being
	multiplied together: each one is advertised by a different screen, and a
	player who saw the rebirth panel's figure change because a boost was running
	would be right to think that panel was lying. This is the fourth promise, and
	it is named on the receipt beside the other three.
]]

local BoostConfig = {}

--------------------------------------------------------------------------
-- THE PRODUCT
--------------------------------------------------------------------------

-- What a sale is multiplied by. TWO, matching GOLDEN HOUR in EventConfig --
-- this is deliberately the same effect a player has already met for free on the
-- ten-minute clock, which is what makes the product explain itself.
BoostConfig.Multiplier = 2

--[[
	HOW LONG ONE PURCHASE BUYS.

	FIFTEEN MINUTES AGAINST GOLDEN HOUR'S SHARE OF THE CLOCK. EventConfig.Cycle
	is 600 seconds and Golden Hour is one of three events in the bag, so the free
	version lands roughly one ten-minute slot in thirty. This is longer than the
	event it copies, on purpose: a paid boost that ran for less time than the free
	one would read as a worse version of something the player already gets.
]]
BoostConfig.Seconds = 900

--------------------------------------------------------------------------
-- WHERE IT IS WRITTEN
--------------------------------------------------------------------------
-- Prefixed the way EventConfig's are, so anything sweeping a player's
-- attributes can tell engine state from this game's.
BoostConfig.MultAttr = "CTB_BoostMultiplier"
BoostConfig.UntilAttr = "CTB_BoostUntil"

--------------------------------------------------------------------------
-- READING IT
--------------------------------------------------------------------------
local function deadlineOf(player: Player?): number
	if not player then
		return 0
	end
	local until_ = player:GetAttribute(BoostConfig.UntilAttr)
	-- NaN fails every comparison including its own, so it is caught by name --
	-- the same guard LeaderboardService.valueOf uses on a stat.
	if type(until_) ~= "number" or until_ ~= until_ then
		return 0
	end
	return until_
end

--[[
	What to multiply a sale by right now: BoostConfig.Multiplier while a boost is
	running, and exactly 1 otherwise.

	ONE IS THE ANSWER TO EVERY BAD STATE -- no attribute, a corrupt one, a
	deadline in the past, a stored multiplier below 1. A boost that cannot be read
	has to be worth nothing rather than worth something odd, because this figure
	is multiplied into money.

	THE STORED MULTIPLIER IS USED, NOT THE CONSTANT ABOVE. A player who paid for
	2x keeps the 2x they paid for even if this file is later retuned to 3 -- the
	value is stamped at the moment of purchase, which is the only reading that
	cannot short-change somebody mid-boost.
]]
function BoostConfig.multiplierFor(player: Player?): number
	if os.time() >= deadlineOf(player) then
		return 1
	end
	local mult = player and player:GetAttribute(BoostConfig.MultAttr)
	if type(mult) ~= "number" or mult ~= mult or mult <= 1 then
		return 1
	end
	return mult
end

-- Seconds left, floored at 0. The HUD's whole input.
function BoostConfig.remainingFor(player: Player?): number
	return math.max(0, deadlineOf(player) - os.time())
end

function BoostConfig.isLive(player: Player?): boolean
	return BoostConfig.multiplierFor(player) > 1
end

return BoostConfig
