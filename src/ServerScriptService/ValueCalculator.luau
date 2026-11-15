--[[
	ValueCalculator  --  ServerScriptService.ValueCalculator

	The ONLY place in the codebase where an item's worth comes into existence.

	Deliberate properties:
	  * Server-only. Requiring this from a LocalScript is impossible (it lives
	    in ServerScriptService) and the assert below makes a mistaken
	    server-module-copied-to-ReplicatedStorage refactor fail loudly.
	  * Lazy. A dirty item has no value -- not a hidden value, NO value. There is
	    nothing on the server for an exploiter to read early, because the number
	    is not computed until sifting hits 100%.
	  * Skewed low. A flat uniform roll makes every find feel the same. The
	    curve below puts most rolls in the bottom third of the range and leaves
	    the top end genuinely rare, so a near-max roll is a story.

	The distribution, for a range [lo, hi]:
	      3% of rolls  -> "pristine" band, top 10% of the range
	     97% of rolls  -> lo + (hi-lo) * u^1.7, u uniform in [0,1)
	  plus a small condition multiplier for a clean, uninterrupted sift.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

assert(RunService:IsServer(), "[ValueCalculator] server-only module")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local ItemConfig = require(Modules:WaitForChild("ItemConfig"))

-- Equipped pets bend the curve below. Required rather than read off the player
-- attribute directly so the clamping and the shape of the bend live in one
-- file -- see LuckService.
local LuckService = require(script.Parent:WaitForChild("LuckService"))

local ValueCalculator = {}

-- One generator for the whole server. Random.new() is seeded per-instance and
-- is not the global math.random state, so nothing else can perturb our stream.
local rng = Random.new()

-- The luck = 1.0 case. LuckService.valueCurve returns exactly these for a
-- player with no pets out, so an unequipped player's rolls are byte-for-byte
-- what they were before pets existed.
-- 0.03 -> 0.05. The pristine band is the only per-item "!" a piece of LOOSE
-- litter can produce -- luck is spent at the wash bay and a can you bent down
-- and picked up was never cleaned -- so at one in thirty-three it was a moment
-- most players never had. One in twenty is still rare and now actually happens.
--
-- LuckService.BASE_PRISTINE IS THE SAME NUMBER and moved with it. It is the
-- luck = 1.0 case for this constant, and the two drifting apart would mean an
-- unequipped player rolled differently depending on which file was asked.
local PRISTINE_CHANCE = 0.05
local SKEW = 1.7

-- Bonuses are small on purpose: they are a nudge for playing well, not a
-- second economy the player has to optimise.
local CONDITION = {
	Uninterrupted = 0.06, -- cleaned in one session without walking away
	NoStalling = 0.04,    -- never sat idle long enough to start decaying
}

export type RollContext = {
	uninterrupted: boolean?,
	stalled: boolean?,
	player: Player?,
}

--[[
	Roll the value for one item. Returns an integer inside [min, max].

	`context` is optional and purely for the condition bonus; passing nothing
	yields a plain roll -- which is what CTBBridge does for loose litter at
	pickup. SiftServer passes one, built from facts the SERVER observed, never
	from anything the client asserted.
]]
function ValueCalculator.roll(itemId: string, context: RollContext?): number
	local def = ItemConfig.expect(itemId)
	local lo, hi = def.ValueRange[1], def.ValueRange[2]
	if hi <= lo then
		return math.floor(lo)
	end

	local span = hi - lo
	local value

	-- LUCK BENDS THE CURVE, IT DOES NOT MOVE THE RANGE.
	--
	-- lo and hi still come from ItemConfig, so a lucky player can never be paid
	-- more than the item is worth -- what changes is WHERE in its range the roll
	-- lands. u^1.7 puts most rolls in the bottom third; u^0.85 puts them in the
	-- top half. The pristine band widens on the same dial.
	--
	-- `context` is nil for loose litter picked off the sand (CTBBridge rolls it
	-- at pickup), and that is deliberate: luck is spent on CLEANING, and a can
	-- you bent down and picked up was never cleaned.
	local skew, pristine = SKEW, PRISTINE_CHANCE
	if context and context.player then
		skew, pristine = LuckService.valueCurve(context.player)
	end

	if rng:NextNumber() < pristine then
		-- Pristine: somewhere in the top decile.
		value = lo + span * (0.9 + 0.1 * rng:NextNumber())
	else
		value = lo + span * (rng:NextNumber() ^ skew)
	end

	if context then
		local mult = 1
		if context.uninterrupted then
			mult += CONDITION.Uninterrupted
		end
		if not context.stalled then
			mult += CONDITION.NoStalling
		end
		value *= mult
	end

	return math.clamp(math.floor(value + 0.5), math.floor(lo), math.floor(hi))
end

-- What the UI is allowed to show BEFORE a roll exists. The range is public
-- information; the roll is not.
function ValueCalculator.previewRange(itemId: string): (number, number)
	local def = ItemConfig.expect(itemId)
	return def.ValueRange[1], def.ValueRange[2]
end

-- Used by SellServer. Kept here so every number that turns into cash comes
-- out of one file.
function ValueCalculator.sumCleaned(records): number
	local total = 0
	for _, rec in records do
		if rec.state == "Cleaned" and type(rec.value) == "number" then
			total += rec.value
		end
	end
	return total
end

return ValueCalculator
