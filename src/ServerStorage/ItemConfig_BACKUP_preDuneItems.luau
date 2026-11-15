--[[
	ItemConfig  --  the item catalogue

	ONE NUMBER DRIVES EVERYTHING: OneIn
	----------------------------------
	Each item declares how rare it is as a "1 in X" chance. Tier, cash value and
	spawn weight are all DERIVED from that single number, so it is impossible to
	author an item that is rarer than another but worth less -- the thing the
	player would notice instantly and never forgive.

		tier   = bucketed from OneIn      (Common .. Mythic)
		value  = 4 * OneIn^0.62, +/-30%   (monotonic in OneIn by construction)
		spawn  = 1 / OneIn, normalised

	Want a Gold Bar to feel better? Raise its OneIn. Everything follows.

	LOOSE vs ENCASED
	----------------
	Common and Uncommon come up loose: picked off the sand, value rolled on the
	spot, sold instantly. Rare and above come up as a crusted lump with its
	identity hidden until you shake it clean at the sifting bay. That split is what
	makes a better screen worth owning -- it gates every item worth having.

	COMPATIBILITY
	-------------
	The seven original ids (Can, Bottle, Shell, Coin, Glasses, Watch, Phone) are
	kept exactly, because world props and WeightConfig.WeightByItemId reference
	them by name. New ids are additive.

	One id was dropped rather than kept: Wrapper. Nothing outside this file ever
	referenced it and no usable art exists for a crisp packet, so it would have
	been the single entry still drawn as a flat coloured slab.

	ART
	---
	Every id here has a model at ReplicatedStorage.Assets.Items.<ItemId>.Clean --
	see ItemVisuals.authoredClean. The Shape/Size/Color/Material/Reflectance
	columns below are the FALLBACK, used only if that model is missing, and Size
	doubles as what TrashSeeder scales a loose prop to. Keep Size roughly equal
	to the authored art's bounding box or a beach prop will jump size the moment
	an asset fails to load.

	WHY EVERY ENCASED ITEM WEIGHS THE SAME
	--------------------------------------
	ItemConfig already gives every lump the same chunk count and the same outer
	size so neither counting nor eyeballing gives it away. Weight was the third
	tell and it was wide open: TrashSeeder writes def.Weight onto the prop, and
	CrustedWeight is a player attribute the client can read, so a 0.1 lb lump was
	a Coin and an 18 lb lump was a Chest before you touched the screen. One
	number, LUMP_WEIGHT, closes it. Loose finds keep their own real weights --
	nothing about them is secret.
]]

local ItemConfig = {}

--------------------------------------------------------------------------
-- TIERS
--------------------------------------------------------------------------
-- Ordered floors. tierOf walks this backwards and takes the first match.
ItemConfig.Tiers = {
	{ key = "Common",    floor = 1,      color = Color3.fromRGB(196, 204, 212), glow = Color3.fromRGB(236, 242, 248), sparkles = 10, hold = 0 },
	{ key = "Uncommon",  floor = 10,     color = Color3.fromRGB(122, 222, 128), glow = Color3.fromRGB(196, 250, 198), sparkles = 16, hold = 0.1 },
	{ key = "Rare",      floor = 50,     color = Color3.fromRGB(78, 158, 255),  glow = Color3.fromRGB(168, 212, 255), sparkles = 26, hold = 0.25 },
	{ key = "Epic",      floor = 500,    color = Color3.fromRGB(186, 112, 255), glow = Color3.fromRGB(226, 190, 255), sparkles = 40, hold = 0.45 },
	{ key = "Legendary", floor = 5000,   color = Color3.fromRGB(255, 189, 61),  glow = Color3.fromRGB(255, 232, 158), sparkles = 60, hold = 0.75 },
	{ key = "Mythic",    floor = 50000,  color = Color3.fromRGB(255, 92, 132),  glow = Color3.fromRGB(255, 186, 208), sparkles = 90, hold = 1.1 },
}

ItemConfig.TierByKey = {}
for _, t in ItemConfig.Tiers do
	ItemConfig.TierByKey[t.key] = t
end

-- Shown for a lump whose contents the client has not been told.
ItemConfig.TierByKey.Unknown = {
	key = "Unknown", floor = 0,
	color = Color3.fromRGB(126, 112, 94), glow = Color3.fromRGB(168, 152, 128),
	sparkles = 8, hold = 0,
}

function ItemConfig.tierOf(oneIn: number): string
	local key = "Common"
	for _, t in ItemConfig.Tiers do
		if oneIn >= t.floor then key = t.key end
	end
	return key
end

function ItemConfig.rarityInfo(tierKey)
	return ItemConfig.TierByKey[tierKey] or ItemConfig.TierByKey.Common
end

function ItemConfig.rarityColor(tierKey): Color3
	return ItemConfig.rarityInfo(tierKey).color
end

-- "1 in 12,500"
function ItemConfig.oddsText(oneIn: number): string
	local s = tostring(math.floor(oneIn))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return "1 in " .. (out:gsub("^,", ""))
end

--------------------------------------------------------------------------
-- VALUE  (derived, so rarer is ALWAYS worth more)
--------------------------------------------------------------------------
local VALUE_COEFF, VALUE_POWER, VALUE_SPREAD = 4, 0.62, 0.3

function ItemConfig.baseValue(oneIn: number): number
	return math.max(1, math.floor(VALUE_COEFF * (oneIn ^ VALUE_POWER) + 0.5))
end

function ItemConfig.valueRange(oneIn: number): (number, number)
	local b = ItemConfig.baseValue(oneIn)
	return math.max(1, math.floor(b * (1 - VALUE_SPREAD))), math.max(2, math.floor(b * (1 + VALUE_SPREAD)))
end

--------------------------------------------------------------------------
-- THE CATALOGUE
--------------------------------------------------------------------------
local M = Enum.Material
local function C3(r, g, b) return Color3.fromRGB(r, g, b) end

-- Every encased find weighs this. See the header. Change it here and nowhere
-- else; WeightConfig.WeightByItemId is generated from this file's Encased flag.
local LUMP_WEIGHT = 2.0

--[[
	THE TOMB SET, and the two rules it breaks on purpose.

	Rows tagged TOMB are grave goods: they are found ONLY on the floor of the
	treasure chamber (Config.ISLANDS[3] draws from its own pool -- see
	Config.TOMB_ITEMS), never on a beach and never from ItemConfig.rollItemId.

	1. THEY ARE NOT NORMALISED WITH THE BEACH. A tomb row takes no share of
	   weightSum and gets SpawnWeight = 0, so adding thirteen of them moved not
	   one beach item's odds or price. Its authored OneIn is used directly as its
	   rarity label, which is honest: its real odds come from the vault's pool,
	   and that pool is the only place it can come from.

	2. THEY ARE NOT ENCASED, at any rarity. Everything Rare and above on a beach
	   comes up as a crusted lump because it has been rolling in surf for a
	   decade -- but the only sifting bay in the game is on the beach, two islands
	   and a cinematic away, and a lump is worth nothing until it has been through
	   one. Legendary grave goods that had to be carried home to be cashed would
	   jam the bag solid and make the room unclearable from inside it (this was
	   measured, before the vault's encasedScale went to zero). Laid out dressed
	   in a tomb, they were never buried in anything to begin with.
]]
local TOMB = "tomb"

-- The tier comments below are the AUTHORED intent. The tier a player actually
-- sees is computed from the normalised odds further down, so if you retune a
-- number, re-read the printed table rather than trusting the heading.
--
--  id            OneIn      lbs        shape       size                       colour           material        refl
local RAW = {
	-- ============ COMMON : litter, loose, sells instantly ============
	{ "Can",         4.5,     0.2,        "Cylinder", Vector3.new(1.5,.85,.85),  C3(214,68,58),   M.Metal,        0.12, "Crushed Can",       "Sun-bleached and full of sand." },
	{ "Bottle",      6.5,     0.5,        "Cylinder", Vector3.new(2,1.14,1.14),  C3(126,205,158), M.Glass,        0.20, "Plastic Bottle",    "The label came off years ago." },
	{ "Cup",         8,       0.3,        "Cylinder", Vector3.new(1.3,.54,.54),  C3(250,250,245), M.SmoothPlastic,0.05, "Soda Cup",          "Somebody's afternoon, half melted." },

	-- ============ UNCOMMON : still loose ============
	{ "FryBox",      12,      0.15,       "Block",    Vector3.new(.6,1.2,1.05),  C3(214,86,66),   M.SmoothPlastic,0.05, "Fry Carton",        "Grease spots and a long walk home." },
	{ "MilkCarton",  15,      0.4,        "Block",    Vector3.new(1.03,.96,1.4), C3(238,238,230), M.SmoothPlastic,0.05, "Milk Carton",       "Swollen with seawater." },
	{ "BottleCap",   18,      0.05,       "Cylinder", Vector3.new(.18,.5,.5),    C3(200,44,44),   M.Metal,        0.20, "Bottle Cap",        "Rusted right around the crimp." },
	{ "Straw",       22,      0.05,       "Cylinder", Vector3.new(1.6,.18,.18),  C3(240,120,140), M.SmoothPlastic,0.05, "Straw",             "The ocean thanks you." },
	{ "PizzaBox",    26,      1.2,        "Block",    Vector3.new(1.81,.25,2),   C3(206,178,132), M.SmoothPlastic,0.02, "Pizza Box",         "Still smells faintly of pepperoni." },
	{ "Shoe",        30,      1.0,        "Block",    Vector3.new(1.8,.9,1.41),  C3(64,66,74),    M.Fabric,       0.05, "Lost Trainer",      "Left foot. It is always the left foot." },
	{ "TrashBag",    34,      4.0,        "Block",    Vector3.new(2.2,1.6,1.2),  C3(38,38,42),    M.SmoothPlastic,0.10, "Split Bin Bag",     "Someone's whole weekend, torn open." },
	{ "Shell",       38,      0.3,        "Wedge",    Vector3.new(1.2,.5,1.1),   C3(248,206,196), M.Sandstone,    0.05, "Seashell",          "Ridged, pale pink, packed with grit." },
	{ "FlipFlop",    43,      0.6,        "Block",    Vector3.new(.68,1.68,1.8), C3(80,190,220),  M.SmoothPlastic,0.05, "Lost Flip Flop",    "Somewhere out there is its twin." },
	{ "Glasses",     47,      0.2,        "Block",    Vector3.new(1.5,.3,.5),    C3(46,46,56),    M.SmoothPlastic,0.30, "Sunglasses",        "One lens gone, the other spotless." },

	-- ============ RARE : encased from here on ============
	{ "Starfish",    75,      LUMP_WEIGHT,"Wedge",    Vector3.new(1.25,.19,1.25),C3(226,140,58),  M.Sandstone,    0.05, "Dried Starfish",    "Five arms. Four and a half, really." },
	{ "Lure",        90,      LUMP_WEIGHT,"Block",    Vector3.new(.59,1,.1),     C3(232,178,60),  M.Metal,        0.25, "Fishing Lure",      "Still sharp. Mind your fingers." },
	{ "Driftwood",   110,     LUMP_WEIGHT,"Block",    Vector3.new(.78,.38,1.3),  C3(150,124,96),  M.Wood,         0.00, "Driftwood",         "Smoothed by a decade of surf." },
	{ "MessageBottle",130,    LUMP_WEIGHT,"Cylinder", Vector3.new(1.25,.69,.39), C3(150,196,168), M.Glass,        0.25, "Message in a Bottle","The cork held. The ink did not." },
	{ "Coin",        155,     LUMP_WEIGHT,"Cylinder", Vector3.new(.16,.85,.85),  C3(255,196,60),  M.Metal,        0.35, "Lost Coin",         "Green with corrosion, still stamped." },
	{ "Keys",        185,     LUMP_WEIGHT,"Block",    Vector3.new(.31,.93,1),    C3(180,180,190), M.Metal,        0.30, "Ring of Keys",      "Four doors nobody remembers." },
	{ "Watch",       215,     LUMP_WEIGHT,"Cylinder", Vector3.new(.59,1.05,1.05),C3(244,204,92),  M.Metal,        0.45, "Gold Watch",        "Stopped at 4:11. Case still snaps." },
	{ "Compass",     250,     LUMP_WEIGHT,"Cylinder", Vector3.new(.68,1,.91),    C3(212,178,96),  M.Metal,        0.35, "Brass Compass",     "Still points north. Mostly." },
	{ "Headphones",  290,     LUMP_WEIGHT,"Block",    Vector3.new(1.15,1.2,.59), C3(48,52,64),    M.SmoothPlastic,0.20, "Headphones",        "One ear still works, remarkably." },
	{ "Snorkel",     330,     LUMP_WEIGHT,"Block",    Vector3.new(.51,.61,1.25), C3(60,150,220),  M.SmoothPlastic,0.15, "Snorkel Set",       "Someone swam back without it." },
	{ "Phone",       400,     LUMP_WEIGHT,"Block",    Vector3.new(1.25,.11,.62), C3(44,48,64),    M.SmoothPlastic,0.40, "Lost Phone",        "Screen isn't even cracked." },
	{ "Wallet",      470,     LUMP_WEIGHT,"Block",    Vector3.new(.57,1.15,1.15),C3(96,60,40),    M.Fabric,       0.05, "Fat Wallet",        "Notes inside are somehow dry." },

	-- ============ EPIC ============
	{ "Boombox",     620,     LUMP_WEIGHT,"Block",    Vector3.new(1.3,.65,.33),  C3(38,42,52),    M.SmoothPlastic,0.15, "Beach Boombox",     "Sand in the tape deck. Still plays." },
	{ "Binoculars",  800,     LUMP_WEIGHT,"Block",    Vector3.new(1.2,.55,1.17), C3(34,38,50),    M.Metal,        0.20, "Binoculars",        "Focused on something out at sea." },
	{ "GoldRing",    1050,    LUMP_WEIGHT,"Cylinder", Vector3.new(.05,.7,.58),   C3(255,206,84),  M.Metal,        0.55, "Gold Ring",         "An inscription worn to three letters." },
	{ "Bracelet",    1400,    LUMP_WEIGHT,"Cylinder", Vector3.new(.08,1,.73),    C3(226,232,240), M.Metal,        0.55, "Silver Chain",      "Heavier than it looks." },
	{ "Anchor",      1850,    LUMP_WEIGHT,"Block",    Vector3.new(1.29,1.3,.09), C3(122,110,96),  M.CorrodedMetal,0.10, "Dinghy Anchor",     "Cut loose in a storm, by the look of it." },
	{ "Camera",      2450,    LUMP_WEIGHT,"Block",    Vector3.new(1.2,.59,.68),  C3(38,40,48),    M.SmoothPlastic,0.25, "Old Camera",        "There is still film in it." },
	{ "Necklace",    3200,    LUMP_WEIGHT,"Cylinder", Vector3.new(.42,1.2,1.05), C3(240,238,228), M.SmoothPlastic,0.45, "Pearl Necklace",    "The clasp gave out. Every pearl stayed." },
	{ "Pearl",       4200,    LUMP_WEIGHT,"Ball",     Vector3.new(.8,.8,.8),     C3(248,242,232), M.SmoothPlastic,0.60, "Black Pearl",       "Impossibly smooth." },

	-- ============ LEGENDARY ============
	{ "GoldBar",     6000,    LUMP_WEIGHT,"Block",    Vector3.new(1.25,.22,.98), C3(255,196,42),  M.Metal,        0.65, "Gold Bar",          "Stamped, numbered, extremely heavy." },
	{ "Skull",       9000,    LUMP_WEIGHT,"Block",    Vector3.new(.84,1.2,1.02), C3(226,216,196), M.Sandstone,    0.05, "Pirate Skull",      "Someone's very bad day, a long time ago." },
	{ "Trident",     13500,   LUMP_WEIGHT,"Block",    Vector3.new(.96,1.3,.1),   C3(255,214,92),  M.Metal,        0.70, "Golden Trident",    "Too heavy to be decorative." },
	{ "Diamond",     20000,   LUMP_WEIGHT,"Ball",     Vector3.new(.87,.7,1),     C3(196,240,255), M.Glass,        0.80, "Raw Diamond",       "Catches the light from every angle." },
	{ "Rolex",       32000,   LUMP_WEIGHT,"Cylinder", Vector3.new(.84,1.15,1.1), C3(255,220,120), M.Metal,        0.70, "Diver's Rolex",     "Still ticking. Of course it is." },

	-- ============ MYTHIC ============
	{ "Chest",       90000,   LUMP_WEIGHT,"Block",    Vector3.new(1.3,1.03,1.03),C3(120,80,44),   M.Wood,         0.15, "Treasure Chest",    "Iron-banded and heavier than you." },
	{ "Crown",       350000,  LUMP_WEIGHT,"Cylinder", Vector3.new(1.2,.48,1.2),  C3(255,214,92),  M.Metal,        0.75, "Ancient Crown",     "Someone important lost this." },
	{ "Meteorite",   1500000, LUMP_WEIGHT,"Block",    Vector3.new(1.05,1.15,.88),C3(74,66,84),    M.Basalt,       0.30, "Meteorite",         "Older than the beach. Faintly warm." },

	-- ============ THE TOMB : grave goods, vault only, never crusted ============
	-- See the TOMB note above. The eleventh column is what marks these.
	-- Nothing here is lighter than 0.5 lb on purpose: CTBBridge.hasRoom stops the
	-- roller when the LIGHTEST collectable in the game would no longer fit, so a
	-- 0.2 lb bead in the vault would have quietly loosened that threshold on both
	-- beaches as well. WeightConfig.WeightByItemId carries the same numbers.
	{ "FaienceBead",    60,   0.5, "Ball",     Vector3.new(.5,.5,.5),     C3(74,168,190),  M.Glass,        0.30, "Faience Bead",      "Blue glaze, still bright after three thousand years.", TOMB },
	{ "ClayUshabti",    95,   1.5, "Block",    Vector3.new(.55,1.3,.45),  C3(198,150,96),  M.Slate,        0.02, "Clay Ushabti",      "A servant figurine. They were packed in by the hundred.", TOMB },
	{ "BronzeAnkh",     150,  1.0, "Block",    Vector3.new(.75,1.2,.14),  C3(150,166,110), M.CorrodedMetal,0.15, "Bronze Ankh",       "Green with age. The loop is worn smooth by handling.", TOMB },
	{ "ScarabSeal",     240,  0.5, "Block",    Vector3.new(.9,.35,1.1),   C3(40,78,150),   M.SmoothPlastic,0.25, "Scarab Seal",       "Lapis, carved underneath with somebody's name.", TOMB },
	{ "AlabasterJar",   380,  3.0, "Cylinder", Vector3.new(1.4,.85,.85),  C3(238,226,204), M.Marble,       0.20, "Alabaster Jar",     "Translucent at the rim. Sealed, and staying that way.", TOMB },
	{ "GoldenAnkh",     600,  1.5, "Block",    Vector3.new(.8,1.3,.16),   C3(255,206,84),  M.Metal,        0.55, "Golden Ankh",       "Solid, not plated. Heavier than it has any right to be.", TOMB },
	{ "CanopicJar",     950,  4.0, "Cylinder", Vector3.new(1.6,.95,.95),  C3(226,196,140), M.Sandstone,    0.10, "Canopic Jar",       "Jackal-headed lid. Best not to ask what is in it.", TOMB },
	{ "EyeOfHorus",     1500, 0.8, "Block",    Vector3.new(1.2,.7,.16),   C3(255,214,110), M.Metal,        0.60, "Eye of Horus",      "Gold and lapis inlay, and not one chip missing.", TOMB },
	{ "PectoralCollar", 2400, 2.0, "Block",    Vector3.new(1.3,1.05,.2),  C3(246,202,90),  M.Metal,        0.60, "Pectoral Collar",   "Nine rows of beadwork on a gold frame.", TOMB },
	{ "SolarDisc",      4000, 3.5, "Cylinder", Vector3.new(.14,1.3,1.3),  C3(255,198,60),  M.Metal,        0.70, "Solar Disc",        "Beaten gold. It throws the torchlight all round the room.", TOMB },
	{ "PharaohMask",    7000, 5.0, "Block",    Vector3.new(1.05,1.3,.85), C3(255,208,72),  M.Metal,        0.72, "Pharaoh's Mask",    "It is looking at you. It has been for a while.", TOMB },
	{ "SunKingScepter", 14000,4.0, "Block",    Vector3.new(.22,1.4,.22),  C3(255,220,104), M.Metal,        0.70, "Sun King's Sceptre","Gold over cedar, and the cedar has not moved.", TOMB },
	{ "SunKingCrown",   60000,3.0, "Cylinder", Vector3.new(1.15,1.2,1.2), C3(255,226,132), M.Metal,        0.78, "Sun King's Crown",  "The reason somebody sealed the door.", TOMB },
}

-- Rare and above must be sifted. One threshold, so the rule cannot drift.
ItemConfig.EncasedFromOneIn = 50

--[[
	How many clumps of crust a lump wears. EVERY encased item gets the same
	number -- see the header: a player who counts chunks must learn nothing
	about what is inside.

	Exported as a named constant rather than left as a literal because the
	CLIENT needs it too and cannot derive it. The wash and sift controllers take
	the real total from the server's WashBegin/SiftBegin payload, but both need a
	fallback for the frame before that lands -- and the identity of a lump is
	hidden from the client by design, so they cannot look it up by item id. Those
	fallbacks used to be a bare `or 14` in two files, which is exactly the sort
	of number that silently stops matching: raise the count here and a client
	that missed the payload would draw a 34-piece rock with a progress bar that
	hits 100% at chunk 14 and then goes negative.
]]
--[[
	22, and this has been both higher and lower.

		14  the original. A few big scabs; each took most of a second to shift,
		    so most of a wash was spent watching one slab sit there.
		34  too far. buildCrust divides by sqrt(count), so the clumps came out
		    around 0.6-0.9 studs -- small enough that the shell reads as gravel,
		    and it hollows into a colander early in every wash.
		22  clumps around 0.8-1.1 studs. Visibly more and smaller than 14,
		    without the rock turning to grit.

	Coverage does not depend on the count (chunk area falls as 1/count), so the
	prize stays hidden at any of these.

	GameConfig.Washing.ChunkWork AND GameConfig.Sifting.ChunkWork MOVE WITH THIS,
	the opposite way. Total work is chunks * ChunkWork * Toughness:
		14 * 3.00 = 42.0
		34 * 1.25 = 42.5
		22 * 1.90 = 41.8   <- current
	So a lump takes the same time to clean at every pressure tier whatever this
	is set to. Change one without the other and every wash in the game rescales
	silently, with nothing on screen to explain why.
]]
ItemConfig.CrustChunkCount = 22

-- AUTHORED ODDS vs REAL ODDS -- and why the shown number is the real one.
--
-- The obvious build is SpawnWeight = 1/OneIn, then display the authored OneIn.
-- That number is a lie unless the weights happen to sum to exactly 1, and
-- hand-authored ones never do -- these summed to 1.33, so every item was a
-- third rarer than its label claimed. A "1 in 3" that is really 1 in 4 is the
-- kind of thing players datamine and post about.
--
-- So the authored OneIn is a RELATIVE knob, and the effective odds are derived
-- from the normalised table. Tier, value and the label are then all computed
-- from the effective number, so what the player is shown is what the roll
-- actually does. Raising one item's rarity now correctly makes everything else
-- slightly more common, and every label follows automatically.
ItemConfig.Items = {}
local weightSum = 0
for _, r in RAW do
	-- Tomb rows sit outside this sum: they are not in the draw it normalises, so
	-- taking a share of it would have quietly made every beach item rarer and
	-- cheaper the day the vault was stocked. See the TOMB note above.
	if r[11] ~= TOMB then
		weightSum += 1 / r[2]
	end
end

for _, r in RAW do
	local id, authored, lbs, shape, size, colour, mat, refl, name, desc =
		r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10]
	local tomb = (r[11] == TOMB)

	-- A tomb item has no share of the beach's probability mass, so there is no
	-- normalised odds to derive: its authored number IS its rarity label, and
	-- tier and value follow from that exactly as they do for everything else.
	local spawn = tomb and 0 or (1 / authored) / weightSum  -- true probability
	local oneIn = tomb and math.max(1, math.floor(authored + 0.5))
		or math.max(1, math.floor(1 / spawn + 0.5))         -- what we show
	local lo, hi = ItemConfig.valueRange(oneIn)
	local encased = (not tomb) and oneIn >= ItemConfig.EncasedFromOneIn

	ItemConfig.Items[id] = {
		ItemId = id,
		-- Found only on the vault floor. Read by rollItemId, which must never
		-- scatter grave goods across a beach.
		Tomb = tomb or nil,
		DisplayName = name,
		Description = desc,
		AuthoredOneIn = authored,
		OneIn = oneIn,
		Chance = spawn,
		Rarity = ItemConfig.tierOf(oneIn),
		Encased = encased,
		-- MANY SMALL CLUMPS, NOT A FEW BIG SCABS.
		--
		-- Was 14. At that count buildCrust sizes each chunk to about 1.0-1.3
		-- studs on a lump only 2.9 across, so the shell read as four or five
		-- boulders stuck to a ball -- and because each one took the better part
		-- of a second to shift, most of what the player watched was a big slab
		-- sitting there getting darker. The washing looked like erasing.
		--
		-- 34 (ItemConfig.CrustChunkCount) is a bit under two and a half times as
		-- many, and buildCrust divides
		-- by sqrt(count), so they come out roughly 0.6-0.9 studs: clumps of wet
		-- sand rather than rocks. Coverage is unchanged (chunk area falls as
		-- 1/count, so the shell hides the prize exactly as well as it did).
		--
		-- THE PACING IS DELIBERATELY NOT CHANGED. Total work is
		-- chunks * ChunkWork * Toughness, so GameConfig's ChunkWork dropped from
		-- 3.0 to 1.25 in the same edit: 14 * 3.0 = 42 became 34 * 1.25 = 42.5.
		-- A lump still takes the same time to clean at every tier -- it just
		-- comes apart in a lot more pieces. Change one of those two numbers
		-- without the other and every wash time moves by a factor of 2.4.
		CrustChunks = encased and ItemConfig.CrustChunkCount or nil,
		Toughness = encased and math.clamp(0.8 + math.log10(oneIn) * 0.22, 0.8, 2.2) or nil,
		ValueRange = { lo, hi },
		Weight = lbs,
		SpawnWeight = spawn,
		Shape = shape,
		Size = size,
		Color = colour,
		Material = mat,
		Reflectance = refl,
	}
end

--------------------------------------------------------------------------
-- LOOKUP
--------------------------------------------------------------------------
ItemConfig.Order = {}
for id in ItemConfig.Items do
	table.insert(ItemConfig.Order, id)
end
table.sort(ItemConfig.Order, function(a, b)
	return ItemConfig.Items[a].OneIn < ItemConfig.Items[b].OneIn
end)

local totalSpawn = 0
for _, d in ItemConfig.Items do
	totalSpawn += d.SpawnWeight
end

-- Every id the treasure chamber can turn up, rarest last. CTB's Config builds
-- the vault's pick table from this, so the two cannot drift: tag a row TOMB
-- above and it is in the vault, untag it and it is out.
-- Order is already sorted by OneIn, so this comes out rarest-last for free.
ItemConfig.TombIds = {}
for _, id in ItemConfig.Order do
	if ItemConfig.Items[id].Tomb then
		table.insert(ItemConfig.TombIds, id)
	end
end

function ItemConfig.get(id) return ItemConfig.Items[id] end

function ItemConfig.expect(id)
	local d = ItemConfig.Items[id]
	assert(d, "[ItemConfig] unknown ItemId: " .. tostring(id))
	return d
end

function ItemConfig.isEncased(id): boolean
	local d = ItemConfig.Items[id]
	return (d ~= nil) and d.Encased == true
end

function ItemConfig.chunkCount(id): number
	-- See CrustChunkCount above before changing either, and remember
	-- GameConfig.Washing/Sifting.ChunkWork has to move the other way to keep
	-- wash times where they are.
	return ItemConfig.expect(id).CrustChunks or ItemConfig.CrustChunkCount
end

function ItemConfig.chunkWorkFor(id, base: number): number
	return base * (ItemConfig.expect(id).Toughness or 1)
end

function ItemConfig.oddsTextFor(id): string
	return ItemConfig.oddsText(ItemConfig.expect(id).OneIn)
end

local fallbackRng = Random.new()
-- The BEACH's draw. Tomb items are skipped explicitly as well as carrying a
-- zero weight, because "it cannot be picked, its weight is zero" is the kind of
-- guarantee that quietly stops being true the first time somebody gives one a
-- spawn weight to test something.
function ItemConfig.rollItemId(rng: Random?): string
	rng = rng or fallbackRng
	local roll = rng:NextNumber() * totalSpawn
	for _, id in ItemConfig.Order do
		local d = ItemConfig.Items[id]
		if not d.Tomb then
			roll -= d.SpawnWeight
			if roll <= 0 then return id end
		end
	end
	return ItemConfig.Order[1]
end

-- Every id of a given tier, rarest last. For the Index panel.
function ItemConfig.byTier(tierKey)
	local out = {}
	for _, id in ItemConfig.Order do
		if ItemConfig.Items[id].Rarity == tierKey then
			table.insert(out, id)
		end
	end
	return out
end

-- Back-compat: older callers said ItemConfig.LumpDisplayName.
ItemConfig.LumpDisplayName = "Crusted Lump"
ItemConfig.LumpDescription = "Something is under all that. No telling what."
ItemConfig.Rarities = ItemConfig.TierByKey

return ItemConfig
