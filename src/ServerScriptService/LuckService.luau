--[[
	LuckService  --  ServerScriptService.LuckService

	The only consumer of the PetLuck attribute, and the only place luck turns
	into a better outcome. Server-only, like ValueCalculator, for the same
	reason: nothing a client can require may know how a reveal is decided.

	WHERE LUCK IS SPENT
	-------------------
	At the wash bay, on the frame a lump comes clean. Nowhere else.

	It is NOT spent on what the field buries. `CTB_Server` rolls `g.itemAt` once
	per island when the grid is generated, long before anyone digs, and that
	array is shared by every player on the server. A per-player multiplier there
	could only be one of two things: a lie (roll it per player, ignore the
	field) or theft (roll it per player, rewrite the field, and change what the
	person digging next to you finds). The reveal has neither problem -- it
	happens per player, on the server, at a moment when the client has never
	been told what is inside the rock.

	TWO EFFECTS, and they compound naturally
	----------------------------------------
		LADDER   a chance to step the revealed item up its pool's encased
		         ladder. This is "better items" literally: a Driftwood becomes
		         a Coin becomes a Watch.
		SKEW     the value roll inside whatever item you end up with leans
		         high, and the pristine band widens.

	A lucky player therefore gets a better thing AND a better example of it,
	which is what "luck" reads as. Both are bounded (see the constants) so no
	loadout can turn every lump into a Meteorite.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

assert(RunService:IsServer(), "[LuckService] server-only module")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local ItemConfig = require(Modules:WaitForChild("ItemConfig"))

local LuckService = {}

-- The player attribute PetServer writes. Named here so the two files cannot
-- drift on a string literal.
LuckService.ATTRIBUTE = "PetLuck"

--------------------------------------------------------------------------
-- TUNING
--------------------------------------------------------------------------
--[[
	TWELVE INDEPENDENT RUNGS, not a decaying chain.

	The first shape of this was "roll for one rung, then roll again at 45% of
	that" -- and it measured terribly. Expected steps topped out near 1.1 no
	matter how good the loadout was, because a decaying chain converges: three
	Legendaries moved a Driftwood to a Message in a Bottle and the revealed
	TIER never changed at all. Luck you cannot see is luck that is not there.

	So: twelve rungs are on the table, and each is an independent flip weighted
	by luck. That is a binomial, which scales smoothly and has no saturation
	cliff -- the difference between three Epics and three Legendaries is still
	visible, which a chain hitting its cap could not give.

		luck 1.05  (one Common)      q = 0.008   ~0.2 rungs   -- noise, correctly
		luck 1.85  (three Uncommon)  q = 0.128   ~3.3 rungs
		luck 3.14  (three Rares)     q = 0.32    ~8.3 rungs
		luck 5.25  (three Epics)     q = 0.64    ~16 rungs
		luck 7.75  (three Legendary) q = 0.85    ~22 rungs

	HOW MANY RUNGS ARE ON THE TABLE IS A FRACTION OF THE LADDER, NOT A NUMBER.

	It was a number -- twelve -- and that was already wrong by the time it was
	measured: twelve rungs could not climb out of the Rare band (which is a dozen
	rungs long on its own), so the best loadout in the game moved a Starfish to a
	Thermos and the revealed TIER never changed at any luck.

	As a fraction it retunes itself: add ten more items to a pool and the reach
	grows with the ladder instead of quietly shrinking against it. That property
	is what just paid for itself -- the beach's ladder went from 3 rungs to 28
	in one change to CTB.Config and this constant did not have to move.

	0.62 of 28 is 17 flips on a beach lump: a maxed loadout climbs out of Rare
	into Legendary, and three Epics reach Epic from mid-Rare, without ever
	reaching Mythic from the bottom of the pool.

	The ladder's own top is still a hard stop, so nothing is ever upgraded past
	the rarest thing its pool contains.
]]
local RUNG_FRACTION = 0.62

--[[
	HOW FAST LUCK BUYS RUNGS, AND WHY IT IS 0.045 RATHER THAN 0.15.

	The cap below is 0.85, so this constant alone decides what luck SATURATES
	the whole system. At 0.15 that was luck 6.667 -- and the cheapest route to
	luck 6.667 is about sixteen Desert eggs, roughly 240,000 coins, reachable
	inside the first hour. Every loadout above it was byte-for-byte identical,
	which made the rarest pets in the game buy nothing at all: five Mythics
	(luck 16, and about forty billion coins' worth of Celestial eggs) rolled
	exactly the same table as the sixteen cheap ones.

	It also broke the pacing outright. Saturating luck multiplies value per find
	by about 7x on Ashfall, so the tide it landed on cut every later tide to a
	quarter of its length and the back half of the game collapsed.

	0.85 / 0.045 saturates at luck ~19.9, and the highest loadout the game can
	actually assemble is luck 16.0 (five Mythics -- see PetConfig.luckOf). So the
	ceiling is now UNREACHABLE by construction: every pet upgrade is worth
	something, all the way to the last one, and there is always a better loadout
	to chase. That is the property to preserve if this is ever retuned --
	RUNG_CHANCE_PER_LUCK * 15.0 must stay below MAX_RUNG_CHANCE.
]]
local RUNG_CHANCE_PER_LUCK = 0.045
local MAX_RUNG_CHANCE = 0.85

-- Value curve. ValueCalculator's own numbers are the luck = 1.0 case; these
-- describe how far they may bend.
local BASE_SKEW = 1.7
-- 0.09, DOWN FROM 0.30, FOR THE RUNG CONSTANT'S REASON AND ON THE SAME TERMS.
-- MIN_SKEW is reached when (luck - 1) * this = 1.4286, which at 0.30 was luck
-- 5.76 -- so the value curve, like the ladder, was fully bought out by a
-- first-hour pet loadout. At 0.09 it bottoms at luck ~16.9, just past the best
-- loadout the game can build, so this half of luck also keeps paying to the end.
local SKEW_PER_LUCK = 0.09
local MIN_SKEW = 0.70          -- above 0.5 on purpose: a flat-topped curve
-- HELD EQUAL TO ValueCalculator.PRISTINE_CHANCE, which is the luck = 1.0 case:
-- an unequipped player's rolls have to be byte-for-byte what they were before
-- pets existed, and two constants that mean the same thing in two files is
-- exactly how that stops being true. Both moved 0.03 -> 0.05 together.
local BASE_PRISTINE = 0.05
-- The cap now binds at luck 5 rather than luck 8.3. That is deliberate: past
-- there, luck's remaining value is all in the LADDER climb above, which is the
-- half a player can actually see happening.
local MAX_PRISTINE = 0.25

--------------------------------------------------------------------------
-- READING THE ATTRIBUTE
--------------------------------------------------------------------------
--[[
	Anything not a sane number reads as 1.0 rather than throwing.

	This is deliberately forgiving: it runs inside the wash completion path, and
	a player with a corrupt attribute should get an ordinary reveal, not a
	half-finished wash and a red error. PetServer is the only writer and it
	writes a clamped number, so the fallback should never fire.
]]
local function readLuck(player: Player, attribute: string): number
	local ok, raw = pcall(function()
		return player:GetAttribute(attribute)
	end)
	if not ok or type(raw) ~= "number" or raw ~= raw then
		return 1.0
	end
	-- Floored at 1, never at 0: an attribute that is missing or corrupt has to
	-- read as NO BONUS rather than as no luck, or one bad write would hand a
	-- fully kitted player a worse reveal than a new one.
	return math.max(1.0, raw)
end

--[[
	PETS ONLY, then clamped once.

	There was briefly a second source: the "Lucky Charm" track wrote its own
	attribute and this function returned the product of the two. The track is
	gone from the shop, so the read is gone from here as well -- a branch left
	multiplying in an attribute nothing writes reads as 1.0 forever, and looks
	like a working feature to everyone who greps for it.

	THE CLAMP STAYS AT 25. It is the ceiling a maxed pet loadout was measured
	against rather than an artefact of combining two sources, and it is what
	stops the best loadout in the game turning every lump into a Meteorite.
]]
function LuckService.luckOf(player: Player?): number
	if not player then
		return 1.0
	end
	local pets = readLuck(player, LuckService.ATTRIBUTE)
	return math.clamp(pets, 1.0, 25.0)
end

--------------------------------------------------------------------------
-- THE LADDERS
--------------------------------------------------------------------------
--[[
	One ladder per pool, encased rows only, rarest last.

	ItemConfig.Order is already sorted by OneIn ascending, so filtering it keeps
	that order for free -- and because tier and value are both derived from
	OneIn, "one rung up" is guaranteed to be both rarer AND worth more. There is
	no way to author a step that is a downgrade.

	Built on first use, not at require time: ItemConfig is a big module and this
	one is loaded by ValueCalculator, which SellServer pulls in during boot.
]]
local ladders = nil

--[[
	ONE LADDER PER POOL. There used to be TWO, and that was a real bug.

	The line was `def.Dune and ladders.dune or ladders.beach`, which splits out the
	desert and nothing else -- so every ASHFALL row and every SAKURA COVE row fell
	through into the BEACH's ladder. Washing a Coin picked up on the home beach
	could therefore reveal a Kitsune Mask or an Obsidian Mirror: loot out of pools
	that ItemConfig, CTB.Config and every island builder in this place all
	guarantee are unreachable from a beach, handed to a player who may not have
	unlocked the island it belongs to.

	IT ALSO FLATTERED THIS WHOLE SYSTEM. The beach's real ladder was three rungs
	long -- Coin, Watch, Phone -- and the accidental merge made it forty-eight, so
	pets LOOKED like they worked at home. They only worked by paying out other
	islands' items. Repairing this on its own would have left a maxed pet team
	nearly worthless on the starting beach, which is why it lands in the same
	change as Config.ITEMS becoming the full forty-one row catalogue.

	AND THEN THE PREDICTED FAILURE HAPPENED ANYWAY (fixed 2026-08). The Magma
	Chamber's CINDER pool landed in ItemConfig with eleven encased rows and no
	line here, so every one of them -- LavaBomb up to the Core of the Forge,
	the richest item in the game -- quietly joined the BEACH's ladder. A
	high-luck player washing a home-beach Coin could have it revealed as a
	Magma Chamber exclusive, thirty-one rebirths and two premiums early, and a
	chamber lump climbed a merged ladder instead of its own. `poolOf` below now
	names five pools.

	The seven ladders as they stand: beach 28 rungs, ashfall 15, cove 13,
	dune 13, cinder 11, penguin 15, wreck 11. (Shrine and Tomb rows are never
	encased, so neither pool has or needs a ladder.)

	`poolOf` reads the same flags ItemConfig sets, so an EIGHTH pool added
	there needs one line here rather than silently joining the beach's.
]]
local function poolOf(def): string
	if def.Dune then
		return "dune"
	end
	if def.Ash then
		return "ash"
	end
	if def.Cove then
		return "cove"
	end
	-- The Magma Chamber's pool. Missing until 2026-08 -- see the header note on
	-- the predicted failure -- so its encased rows rode the beach's ladder.
	if def.Cinder then
		return "cinder"
	end
	-- Penguin Island and the Frozen Wreck, added 2026-09-11 with their pools,
	-- so neither could ever have the chamber's month of riding the beach's
	-- ladder.
	if def.Penguin then
		return "penguin"
	end
	if def.Wreck then
		return "wreck"
	end
	return "beach"
end

local function buildLadders()
	if ladders then
		return ladders
	end
	ladders = { beach = {}, dune = {}, ash = {}, cove = {}, cinder = {}, penguin = {}, wreck = {} }
	for _, id in ItemConfig.Order do
		local def = ItemConfig.Items[id]
		-- Tomb rows are never encased (see the TOMB note in ItemConfig), so
		-- they can never reach a wash bay and have no ladder at all.
		if def and def.Encased and not def.Tomb then
			table.insert(ladders[poolOf(def)], id)
		end
	end
	return ladders
end

local function ladderFor(itemId: string)
	local def = ItemConfig.Items[itemId]
	if not def or not def.Encased or def.Tomb then
		return nil
	end
	return buildLadders()[poolOf(def)]
end

--[[
	Roll the upgrade. Returns the item to actually reveal and how many rungs it
	moved (0 when luck did nothing, which is the common case at low luck).

	Called with the record's CURRENT itemId, so a lump that was buried as a
	Driftwood is revealed as whatever this returns -- and since the client was
	never told it was a Driftwood, nothing on screen contradicts it.
]]
function LuckService.upgradeItem(player: Player?, itemId: string, rng: Random): (string, number)
	local luck = LuckService.luckOf(player)
	if luck <= 1.0 then
		return itemId, 0
	end

	local ladder = ladderFor(itemId)
	if not ladder then
		return itemId, 0
	end

	local index = table.find(ladder, itemId)
	if not index or index >= #ladder then
		return itemId, 0  -- unknown, or already the best thing in its pool
	end

	local chance = math.min((luck - 1.0) * RUNG_CHANCE_PER_LUCK, MAX_RUNG_CHANCE)
	local rungs = math.ceil(#ladder * RUNG_FRACTION)
	local steps = 0
	for _ = 1, rungs do
		if index >= #ladder then
			break   -- already the rarest thing this pool can produce
		end
		if rng:NextNumber() < chance then
			index += 1
			steps += 1
		end
	end

	if steps == 0 then
		return itemId, 0
	end
	return ladder[index], steps
end

--------------------------------------------------------------------------
-- THE VALUE CURVE
--------------------------------------------------------------------------
--[[
	What ValueCalculator should use for THIS player instead of its own
	constants. Returns (skew, pristineChance).

	The exponent falls as luck rises: u^1.7 puts most rolls in the bottom third
	of an item's range, u^0.85 puts them in the top half. It is clamped above
	0.5 so the curve never inverts into "low rolls are the rare ones" -- a
	distribution where the floor is the surprise feels broken rather than lucky.
]]
function LuckService.valueCurve(player: Player?): (number, number)
	local luck = LuckService.luckOf(player)
	if luck <= 1.0 then
		return BASE_SKEW, BASE_PRISTINE
	end
	local skew = math.max(MIN_SKEW, BASE_SKEW / (1 + (luck - 1.0) * SKEW_PER_LUCK))
	local pristine = math.min(MAX_PRISTINE, BASE_PRISTINE * luck)
	return skew, pristine
end

return LuckService
