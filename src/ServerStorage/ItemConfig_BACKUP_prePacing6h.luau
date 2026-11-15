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

--[[
	THE DESERT SET, and how it differs from the tomb's.

	Rows tagged DUNE are what the sand out at the Dunes actually turns up:
	excavation spoil and caravan leavings rather than beach litter. They are
	spawned from Config.DUNE_ITEMS on Config.ISLANDS[2] and are unreachable from
	a beach or from ItemConfig.rollItemId, exactly as the tomb set is.

	They share the tomb's FIRST rule and deliberately not its second.

	1. NOT NORMALISED WITH THE BEACH, same as TOMB. A dune row takes no share of
	   weightSum and gets SpawnWeight = 0, so adding twenty-two of them moved no
	   beach item's odds or price by a hair. Its authored OneIn is its rarity
	   label, which is honest -- the desert's own pool is the only place it can
	   come from.

	2. THEY ARE ENCASED NORMALLY. The tomb's exemption exists because the only
	   sifting bay in the game is on the beach and the vault is behind a locked
	   cinematic, so a bagful of crust in there is a soft-lock. The desert is not
	   locked -- the docks home are always open -- and its island row carries
	   encasedScale = 1.0 precisely because lumps are what makes the trip worth
	   making. Exempting these would have quietly turned that dial to zero and
	   left the field paying out nothing but loose potsherds.

	EVERY ENCASED DUNE ROW WEIGHS LUMP_WEIGHT, for the reason in the header: a
	lump that weighs what it contains has named itself. The loose ones weigh
	their own, and none is under 0.5 lb -- see the note on the tomb block.
]]
local DUNE = "dune"

--[[
	THE ASHFALL SET, and it is the DUNE contract word for word.

	Rows tagged ASH are what the black sand out at Ashfall Isle turns up: what the
	sea throws onto a volcanic beach, what a party of hikers drops on the way up a
	cone, and the minerals the mountain itself makes. They are spawned from
	Config.ASH_ITEMS on Config.ISLANDS[5] and are unreachable from a beach or from
	ItemConfig.rollItemId.

	1. NOT NORMALISED WITH THE BEACH, same as TOMB and DUNE. See the `r[11] == nil`
	   test under weightSum -- it was deliberately written to exclude EVERY tagged
	   pool rather than to name two of them, so this set folded in for free and no
	   beach item's odds or price moved by a hair when it landed.

	2. ENCASED NORMALLY, like the desert's and unlike the tomb's. Ashfall's island
	   row carries encasedScale = 1.0 and its way home is never level-locked, so a
	   bagful of crust out here is a ferry ride rather than a soft-lock -- which is
	   the only thing that ever forced an exemption.

	EVERY ENCASED ASH ROW WEIGHS LUMP_WEIGHT, for the reason in the header, and
	nothing loose is under 0.5 lb -- lightestCollectable takes the MINIMUM across
	the whole catalogue, so one very light pumice chunk would have moved the
	roller's stop threshold on all five fields.
]]
local ASH = "ash"

--[[
	THE COVE SET, and why it exists at all.

	Rows tagged COVE are what the sand at Sakura Cove turns up: hanami-festival
	leavings at the cheap end, and things washed down from the shrine on the
	hill at the dear end.

	The cove was the ONE destination with no pool of its own. Its row already
	carried its own `litterSet` -- twelve Japanese props strewn on the ground --
	so the field LOOKED right, and then paid out crushed cans and pizza boxes,
	because a row with no `itemPool` falls through to Config.ITEMS. You took a
	ferry and a Lv.5 sifter to a pastel cove to dig up the same litter as the
	pier you left from.

	Same two rules as the desert set:

	1. NOT NORMALISED WITH THE BEACH. A cove row takes no share of weightSum and
	   gets SpawnWeight = 0, so adding twenty-two of them moves no beach item's
	   odds or price. Its authored OneIn is its rarity label, which is honest --
	   the cove's own pool is the only place it can come from.

	2. ENCASED NORMALLY, from OneIn 50 up. The tomb's exemption exists because
	   its sell path is behind a locked cinematic; the cove's gate home is never
	   locked, so a bagful of crust here is a trip back rather than a soft-lock.
	   Its row runs encasedScale = 1.0 and that number has to mean something.

	Every encased row weighs LUMP_WEIGHT and nothing loose is under 0.5 lb, for
	the reasons in the header and in the tomb block above.
]]
local COVE = "cove"

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

	-- ============ THE DUNES : dig spoil and caravan leavings, desert only ============
	-- See the DUNE note above. The eleventh column is what marks these. Unlike the
	-- tomb set these ARE encased from OneIn 50 up, which is what keeps the
	-- desert's encasedScale = 1.0 meaning something -- and every encased row here
	-- therefore weighs LUMP_WEIGHT, or a lump in the bag would name itself.
	-- Nothing loose is under 0.5 lb: lightestCollectable takes the MINIMUM across
	-- the whole catalogue and CTBBridge.hasRoom stops the roller at it, so one
	-- very light potsherd would have moved that threshold on both beaches too.

	-- COMMON : dig spoil, loose, sells on the spot
	{ "Potsherd",       4.5,  0.5, "Wedge",    Vector3.new(1.1,.3,.9),    C3(178,96,62),   M.Slate,        0.02, "Pot Shard",         "Red clay, and a painted line that used to be a border.", DUNE },
	{ "MudBrick",       6.5,  1.5, "Block",    Vector3.new(1.4,.6,.8),    C3(190,148,96),  M.Concrete,     0.00, "Crumbled Mud Brick","Straw still showing through where it split.", DUNE },
	{ "PalmFrond",      8,    0.5, "Block",    Vector3.new(1.9,.12,.55),  C3(158,146,84),  M.Grass,        0.00, "Dry Palm Frond",    "Snapped off in one storm and buried by the next.", DUNE },

	-- UNCOMMON : still loose
	{ "FrayedRope",     13,   0.5, "Cylinder", Vector3.new(.9,.42,.42),   C3(196,168,118), M.Fabric,       0.00, "Frayed Rope",       "Palm fibre. Whatever it was tied to is long gone.", DUNE },
	{ "BleachedBone",   17,   1.0, "Block",    Vector3.new(1.5,.35,.35),  C3(238,230,206), M.Sandstone,    0.02, "Bleached Bone",     "Camel, probably. The caravans did not all make it.", DUNE },
	{ "ReedBasket",     22,   0.8, "Cylinder", Vector3.new(.85,1.05,1.05),C3(206,172,104), M.Fabric,       0.00, "Torn Reed Basket",  "Woven tight enough that it still holds sand.", DUNE },
	{ "ClayLamp",       28,   0.7, "Block",    Vector3.new(1,.4,.65),     C3(198,150,96),  M.Slate,        0.04, "Oil Lamp",          "A thumb of soot round the spout, three thousand years old.", DUNE },
	{ "KohlVial",       36,   0.5, "Cylinder", Vector3.new(.85,.4,.4),    C3(92,120,132),  M.Glass,        0.22, "Kohl Vial",         "Still a smudge of black in the bottom of it.", DUNE },
	{ "CopperPin",      44,   0.5, "Cylinder", Vector3.new(1.1,.14,.14),  C3(176,118,74),  M.CorrodedMetal,0.12, "Copper Pin",        "Green all over. It held somebody's cloak shut.", DUNE },

	-- RARE : encased from here on, at the same threshold the beach uses
	{ "PapyrusScrap",   80,   LUMP_WEIGHT,"Block",   Vector3.new(1.15,.06,.85), C3(226,206,152),M.Fabric,       0.00, "Papyrus Scrap",     "Half a column of accounts. Someone was owed grain.", DUNE },
	{ "WadjetAmulet",   115,  LUMP_WEIGHT,"Block",   Vector3.new(1,.6,.14),     C3(70,164,178), M.SmoothPlastic,0.25, "Wadjet Amulet",     "Faience, the blue barely faded. Worn against the evil eye.", DUNE },
	{ "ScribePalette",  165,  LUMP_WEIGHT,"Block",   Vector3.new(1.3,.16,.5),   C3(206,166,110),M.Wood,         0.05, "Scribe's Palette",  "Two wells, one red and one black, both used up.", DUNE },
	{ "BronzeSickle",   230,  LUMP_WEIGHT,"Block",   Vector3.new(1.25,.9,.1),   C3(150,166,110),M.CorrodedMetal,0.15, "Bronze Sickle",     "Notched along the edge from a harvest nobody remembers.", DUNE },
	{ "BastetIdol",     320,  LUMP_WEIGHT,"Block",   Vector3.new(.55,1.25,.6),  C3(60,62,72),   M.Slate,        0.10, "Bastet Idol",       "A seated cat, ears intact, looking straight past you.", DUNE },
	{ "ObsidianBlade",  430,  LUMP_WEIGHT,"Wedge",   Vector3.new(1.05,.1,.42),  C3(38,34,44),   M.Glass,        0.30, "Obsidian Blade",    "Still sharp enough that you put it down carefully.", DUNE },

	-- EPIC
	{ "TurquoiseScarab",700,  LUMP_WEIGHT,"Block",   Vector3.new(.95,.4,1.2),   C3(60,178,166), M.SmoothPlastic,0.30, "Turquoise Scarab",  "Carved underneath with a name worn down to two signs.", DUNE },
	{ "GoldCartouche",  1200, LUMP_WEIGHT,"Block",   Vector3.new(1.3,.55,.12),  C3(255,206,84), M.Metal,        0.55, "Gold Cartouche",    "An oval, a rope border, and somebody who mattered inside it.", DUNE },
	{ "FalconPendant",  2200, LUMP_WEIGHT,"Block",   Vector3.new(1,1.15,.16),   C3(246,202,90), M.Metal,        0.55, "Falcon Pendant",    "Horus, wings folded, in gold over a lapis chest.", DUNE },
	{ "LapisCollar",    3600, LUMP_WEIGHT,"Cylinder",Vector3.new(.4,1.2,1.05),  C3(40,78,150),  M.SmoothPlastic,0.35, "Lapis Collar",      "Seven rows of beads, and the thread has outlived the wearer.", DUNE },

	-- LEGENDARY
	{ "RoyalSealRing",  7000, LUMP_WEIGHT,"Cylinder",Vector3.new(.1,.72,.62),   C3(255,214,110),M.Metal,        0.65, "Royal Seal Ring",   "Heavy gold, and the seal on it would still bite into wax.", DUNE },
	{ "SolarBarque",    16000,LUMP_WEIGHT,"Block",   Vector3.new(1.5,.7,.35),   C3(255,220,104),M.Metal,        0.60, "Model Solar Barque","A gold boat for a journey the owner never came back from.", DUNE },

	-- MYTHIC
	{ "SphinxFragment",120000,LUMP_WEIGHT,"Block",   Vector3.new(1.1,1.2,.95),  C3(214,178,120),M.Sandstone,    0.05, "Sphinx Fragment",   "Part of a face. Whatever it broke off is still out there somewhere.", DUNE },

	-- ============ ASHFALL ISLE : tideline junk, hikers' leavings, and what the mountain makes ============
	-- See the ASH note above. The eleventh column is what marks these. Encased
	-- from OneIn 50 up like the desert's, so every crusted row weighs LUMP_WEIGHT;
	-- nothing loose is under 0.5 lb for the lightestCollectable reason on the tomb
	-- block. WeightConfig.WeightByItemId carries the same numbers.

	--[[
		THE BOTTOM OF THIS LADDER IS THE MOUNTAIN, NOT THE TOURISTS, AND IT DID NOT
		START THAT WAY.

		The first cut of this pool put every volcanic find at Rare and above --
		obsidian, sulphur, a volcanic bomb, glass thread -- and filled Common and
		Uncommon with a visor, a guy line, a wrapper, a net float, a dive fin. Nine
		of the first thirteen were camping gear, which meant the first several hours
		on a black beach under a live volcano turned up almost nothing volcanic. The
		rare stuff was doing all the theming and by definition hardly anyone saw it.

		Six rows go in at the cheap end to fix that. The tourist leavings STAY -- an
		island people climb should turn up the things they drop, and a pool that is
		nothing but rock is a geology exhibit -- but they are now the minority of
		what comes out of the sand instead of nearly all of it.
	]]

	-- COMMON : what the mountain sheds and the tide leaves, loose, sells on the spot
	{ "PumiceChunk",    4.5,  0.6, "Ball",     Vector3.new(.9,.75,.85),   C3(148,142,140), M.Concrete,     0.00, "Pumice Chunk",      "All holes and no weight. Most of it floated here.", ASH },
	{ "ScoriaChunk",    5.5,  0.6, "Ball",     Vector3.new(.95,.8,.9),    C3(96,52,44),    M.Slate,        0.02, "Scoria Chunk",      "Red-black and full of bubbles. It cooled while it was still boiling.", ASH },
	{ "ScorchedPlank",  6.5,  1.2, "Block",    Vector3.new(1.7,.22,.6),   C3(58,50,48),    M.Wood,         0.00, "Scorched Plank",    "Half a crate. The other half was somebody's firewood.", ASH },
	{ "AshedCan",       8,    0.6, "Cylinder", Vector3.new(1.4,.8,.8),    C3(150,146,142), M.CorrodedMetal,0.08, "Ash-Caked Can",     "Grey right through, and it still rattles.", ASH },
	{ "CinderClinker",  9.5,  0.7, "Block",    Vector3.new(1.0,.55,.85),  C3(74,68,70),    M.Concrete,     0.00, "Cinder Clinker",    "Ash and grit fused into one lump. Rings like a tile when you drop it.", ASH },

	-- UNCOMMON : still loose
	{ "MeltedVisor",    13,   0.5, "Block",    Vector3.new(1.4,.35,.5),   C3(96,88,96),    M.SmoothPlastic,0.18, "Melted Visor",      "Somebody stood a little too close to a vent.", ASH },
	{ "GlassTear",      15,   0.5, "Ball",     Vector3.new(.55,.8,.55),   C3(26,24,32),    M.Glass,        0.42, "Volcano Glass Tear","A droplet of lava that froze in the air on the way down.", ASH },
	{ "BlackSeaGlass",  17,   0.5, "Wedge",    Vector3.new(.9,.28,.8),    C3(34,32,40),    M.Glass,        0.30, "Black Sea Glass",   "Obsidian the surf has spent thirty years rounding off.", ASH },
	{ "BasaltChip",     20,   1.4, "Cylinder", Vector3.new(.5,1.05,1.05), C3(70,66,74),    M.Slate,        0.04, "Basalt Column Chip","Snapped clean off a six-sided column. The mountain cuts its own stone.", ASH },
	{ "FrayedGuyLine",  22,   0.5, "Cylinder", Vector3.new(.95,.4,.4),    C3(206,164,86),  M.Fabric,       0.00, "Frayed Guy Line",   "Whatever tent it held is two islands downwind by now.", ASH },
	{ "TrailWrapper",   28,   0.5, "Block",    Vector3.new(1.1,.08,.5),   C3(214,178,74),  M.Metal,        0.35, "Trail Bar Wrapper", "Foil. Still shiny, still not going anywhere.", ASH },
	{ "VentCap",        32,   0.9, "Cylinder", Vector3.new(.28,1.1,1.1),  C3(170,110,62),  M.CorrodedMetal,0.15, "Vent Cap",          "Brass, bolted over a fumarole by an optimist. The fumarole won.", ASH },
	{ "BurstFloat",     36,   0.8, "Ball",     Vector3.new(1.1,1.1,1.1),  C3(232,112,54),  M.SmoothPlastic,0.10, "Burst Net Float",   "Split down one side and still doing its best.", ASH },
	{ "AshGlazedShard", 40,   0.5, "Wedge",    Vector3.new(1.0,.26,.85),  C3(158,150,140), M.Slate,        0.18, "Ash-Glazed Shard",  "Somebody's plate, glazed a second time by the fall.", ASH },
	{ "CrackedFin",     44,   0.7, "Block",    Vector3.new(.7,.25,1.7),   C3(46,120,150),  M.SmoothPlastic,0.08, "Cracked Dive Fin",  "The strap went first. The strap always goes first.", ASH },

	-- RARE : encased from here on, at the same threshold every field uses
	{ "ObsidianFlake",  80,   LUMP_WEIGHT,"Wedge",   Vector3.new(1.0,.12,.5),   C3(28,26,34),   M.Glass,        0.35, "Obsidian Flake",    "An edge you can see yourself in. Pick it up by the blunt end.", ASH },
	{ "HikersCompass",  115,  LUMP_WEIGHT,"Cylinder",Vector3.new(.5,.95,.95),   C3(188,190,196),M.Metal,        0.30, "Hiker's Compass",   "The needle still swings. Near the crater it swings a great deal.", ASH },
	{ "AshFulgurite",   150,  LUMP_WEIGHT,"Cylinder",Vector3.new(1.5,.35,.35),  C3(88,80,96),   M.Glass,        0.28, "Ash Fulgurite",     "Volcanic lightning went through the plume and left a glass tube behind.", ASH },
	{ "SulphurCrystal", 165,  LUMP_WEIGHT,"Block",   Vector3.new(.8,.75,.8),    C3(232,208,72), M.Marble,       0.20, "Sulphur Crystal",   "Butter yellow, and it smells exactly like the vent it grew in.", ASH },
	{ "ScaldedThermos", 230,  LUMP_WEIGHT,"Cylinder",Vector3.new(1.4,.7,.7),    C3(160,42,40),  M.Metal,        0.25, "Scalded Thermos",   "Blistered down one side, and the seal held anyway.", ASH },
	{ "VolcanicBomb",   320,  LUMP_WEIGHT,"Ball",    Vector3.new(1.15,1.0,1.0), C3(52,44,48),   M.Slate,        0.05, "Volcanic Bomb",     "Thrown out molten, landed spinning, cooled mid-turn.", ASH },
	{ "PelesHair",      430,  LUMP_WEIGHT,"Block",   Vector3.new(1.3,.3,.16),   C3(196,178,120),M.Glass,        0.30, "Volcano Glass Thread","Lava drawn out to a hair. Do not close your hand on it.", ASH },

	-- EPIC
	{ "PeridotNodule",  700,  LUMP_WEIGHT,"Ball",    Vector3.new(1.0,.9,.95),   C3(126,196,88), M.Glass,        0.45, "Peridot Nodule",    "Green crystals grown in the middle of a black stone.", ASH },
	{ "LavaTubePearl",  1000, LUMP_WEIGHT,"Ball",    Vector3.new(.9,.88,.9),    C3(52,46,54),   M.Glass,        0.50, "Lava Tube Pearl",   "Rolled round inside a lava tube for a century. Not one flat spot on it.", ASH },
	{ "ObsidianMirror", 1200, LUMP_WEIGHT,"Cylinder",Vector3.new(.16,1.25,1.25),C3(32,30,38),   M.Glass,        0.65, "Obsidian Mirror",   "Polished on one face. The room in it is darker than this one.", ASH },
	{ "EmberOpal",      2200, LUMP_WEIGHT,"Ball",    Vector3.new(.85,.8,.9),    C3(255,142,68), M.Glass,        0.60, "Ember Opal",        "It holds a fire that is not in it.", ASH },
	{ "AshcastIdol",    3600, LUMP_WEIGHT,"Block",   Vector3.new(.6,1.3,.6),    C3(198,192,182),M.Concrete,     0.02, "Ashcast Idol",      "Ash filled the hollow left by whatever burned away inside it.", ASH },

	-- LEGENDARY
	{ "CalderaCrown",   7000, LUMP_WEIGHT,"Cylinder",Vector3.new(1.1,1.2,1.2),  C3(60,54,58),   M.Slate,        0.30, "Caldera Crown",     "Banded basalt finished in gold. The island made most of it.", ASH },
	{ "FirebirdPlume",  16000,LUMP_WEIGHT,"Block",   Vector3.new(1.5,.65,.12),  C3(255,168,54), M.Glass,        0.70, "Firebird Plume",    "A feather of glass. It should not exist, and here it is.", ASH },

	-- MYTHIC
	{ "HeartOfAshfall", 120000,LUMP_WEIGHT,"Ball",   Vector3.new(1.1,1.05,1.1), C3(255,96,40),  M.Glass,        0.75, "Heart of Ashfall",  "Still warm. It has been still warm for a thousand years.", ASH },

	-- ============ SAKURA COVE : festival leavings and shrine goods ============
	-- See the COVE note above. The eleventh column is what marks these.

	-- COMMON : what a hanami crowd leaves behind, loose, sells on the spot
	{ "Chopsticks",     4.5,  0.5, "Cylinder",Vector3.new(1.5,.12,.12),  C3(226,206,168),M.Wood,         0.00, "Waribashi Chopsticks","Split unevenly, the way they always are.", COVE },
	{ "PaperCup",       6.5,  0.5, "Cylinder",Vector3.new(1.2,.5,.5),    C3(248,226,232),M.SmoothPlastic,0.03, "Sakura Paper Cup",  "A printed blossom, sun-faded to grey.", COVE },
	{ "SquidSkewer",    8,    0.5, "Cylinder",Vector3.new(1.7,.1,.1),    C3(206,178,120),M.Wood,         0.00, "Squid Skewer",      "Bamboo, licked clean, dropped where they stood.", COVE },

	-- UNCOMMON : still loose
	{ "OnigiriWrap",    13,   0.5, "Block",   Vector3.new(.9,.06,.8),    C3(46,54,48),   M.SmoothPlastic,0.08, "Onigiri Wrapper",   "The nori never does stay crisp.", COVE },
	{ "RamenLid",       17,   0.5, "Cylinder",Vector3.new(.1,1,1),       C3(238,232,220),M.SmoothPlastic,0.05, "Instant Ramen Lid", "Peeled back and never re-sealed.", COVE },
	{ "GachaCapsule",   22,   0.5, "Ball",    Vector3.new(.85,.85,.85),  C3(120,196,232),M.Glass,        0.25, "Gacha Capsule",     "Empty. Somebody got the one they wanted.", COVE },
	{ "PaperFan",       28,   0.5, "Block",   Vector3.new(1.4,.05,.9),   C3(240,238,228),M.Fabric,       0.00, "Uchiwa Fan",        "One summer festival's worth of waving.", COVE },
	{ "SakeCap",        36,   0.5, "Cylinder",Vector3.new(.16,.5,.5),    C3(214,206,190),M.Metal,        0.25, "Sake Bottle Cap",   "One cup, on the sand, in August.", COVE },
	{ "CharmStrap",     44,   0.5, "Block",   Vector3.new(.5,.7,.12),    C3(226,86,86),  M.SmoothPlastic,0.15, "Torii Phone Charm", "A little gate. The cord frayed through.", COVE },

	-- RARE : encased from here on, at the same threshold every other field uses
	{ "Geta",           80,   LUMP_WEIGHT,"Block",  Vector3.new(1.6,.7,.75),   C3(178,142,96), M.Wood,         0.05, "Lost Geta",         "One wooden sandal. The thong gave out.", COVE },
	{ "Furin",          115,  LUMP_WEIGHT,"Ball",   Vector3.new(.9,.85,.9),    C3(180,222,230),M.Glass,        0.30, "Furin Wind Chime",  "Glass, still wearing its paper tail.", COVE },
	{ "Kokeshi",        165,  LUMP_WEIGHT,"Cylinder",Vector3.new(1.3,.55,.55), C3(232,198,176),M.Wood,         0.10, "Kokeshi Doll",      "A painted smile worn down to a suggestion.", COVE },
	{ "Ofuda",          230,  LUMP_WEIGHT,"Block",  Vector3.new(1.1,.08,.36),  C3(244,240,226),M.Fabric,       0.00, "Shrine Ofuda",      "A paper ward, its ink run through with seawater.", COVE },
	{ "KitsuneMask",    320,  LUMP_WEIGHT,"Block",  Vector3.new(.95,1.15,.4),  C3(248,242,236),M.Marble,       0.20, "Kitsune Mask",      "Grinning. It has been grinning for a while.", COVE },
	{ "Tenugui",        430,  LUMP_WEIGHT,"Block",  Vector3.new(1.2,.06,.8),   C3(46,86,140),  M.Fabric,       0.00, "Indigo Tenugui",    "Block-printed with waves, hemmed on three sides.", COVE },

	-- EPIC
	{ "Netsuke",        700,  LUMP_WEIGHT,"Block",  Vector3.new(.55,.6,.5),    C3(216,190,140),M.Wood,         0.20, "Netsuke Carp",      "Boxwood the size of a plum, carved all the way round.", COVE },
	{ "RakuBowl",       1200, LUMP_WEIGHT,"Cylinder",Vector3.new(.7,1,1),      C3(72,66,64),   M.Marble,       0.15, "Raku Tea Bowl",     "Broken once and repaired in gold, which made it worth more.", COVE },
	{ "InroCase",       2200, LUMP_WEIGHT,"Block",  Vector3.new(.9,.7,.3),     C3(58,42,36),   M.Wood,         0.35, "Lacquered Inro",    "Five compartments, and the silk cord still holds them shut.", COVE },
	{ "SuzuBell",       3600, LUMP_WEIGHT,"Ball",   Vector3.new(.9,.95,.9),    C3(198,166,86), M.Metal,        0.40, "Suzu Shrine Bell",  "It still rings. Politely.", COVE },

	-- LEGENDARY
	{ "Tsuba",          7000, LUMP_WEIGHT,"Cylinder",Vector3.new(.12,1,1),     C3(70,68,74),   M.Metal,        0.35, "Iron Tsuba",        "A sword guard, pierced through with a wave pattern.", COVE },
	{ "MakieBox",       16000,LUMP_WEIGHT,"Block",  Vector3.new(1.2,.6,.9),    C3(28,24,26),   M.Marble,       0.55, "Maki-e Box",        "Black lacquer and gold dust: a heron standing in reeds.", COVE },

	-- MYTHIC
	{ "Magatama",       120000,LUMP_WEIGHT,"Ball",  Vector3.new(.85,.7,.5),    C3(96,180,140), M.Glass,        0.60, "Jade Magatama",     "Comma-shaped, and older than the shrine on the hill above the cove.", COVE },
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
--[[
	WHAT AN ISLAND'S FINDS ARE WORTH, RELATIVE TO THE HOME BEACH.

	THE PROBLEM THIS FIXES. Value is derived from rarity -- 4 * OneIn^0.62 -- and
	every pool's ladder starts at OneIn 5. So every island's COMMONS were worth
	about eleven coins, and commons are what you actually dig up. Measured
	against the real spawn-weight tables in Config, the expected value of a
	single find came out:

		Beach    29.21      49.6 coins/lb
		Dunes    32.28      35.9 coins/lb     unlocked at 0 rebirths
		Cove     26.83      43.8 coins/lb     unlocked at 3 rebirths
		Ashfall  29.20      35.9 coins/lb     unlocked at 10 rebirths

	The bag is rationed by WEIGHT, so coins-per-pound is the number a player
	actually feels -- and on that axis the STARTING BEACH beat three of the four
	later islands. Ashfall, ten rebirths deep, paid 28% less per bag than the
	sand behind the shop. The Dunes and the Cove were worse than that: their
	rarity ladders are identical character for character despite being eleven
	ferry levels apart, so the Cove was a reskin with a longer boat ride.

	WHY THE MULTIPLIER LIVES HERE AND NOT AT THE SELL PAD. Each of these pools is
	EXCLUSIVE to its island -- see the Tomb/Dune/Ash/Cove contracts above, which
	guarantee a scribe's palette can never turn up in the surf. So the item IS
	the island, and pricing it here means:

	  * it cannot be gamed by carrying a lump home to wash, or by sailing
	    somewhere else to sell -- both of which a position-based multiplier at
	    the wash bay or the till would have let you do;
	  * loose litter and encased finds are priced by one rule rather than two;
	  * the Beach Index and every preview range show the true number, because
	    lo and hi themselves move rather than a bonus being bolted on later;
	  * ValueCalculator.roll's clamp to [lo, hi] stays honest. Multiplying inside
	    that function would have been cancelled by its own clamp.

	THE HOME BEACH IS DELIBERATELY 1.0 AND UNTOUCHED. The early game -- first
	rebirth at 3,000, about nineteen bags -- is tuned and is not what was broken.
	Everything below only changes what the ferry is FOR.

	The resulting ladder, in the order a player actually reaches these places
	(the vault is entered from the desert, so it sits third):

		Beach      49.6 coins/lb      x1.0
		Dunes        86              x2.4
		Vault       141              x1.3
		Cove        201              x4.6
		Ashfall     309              x8.6

	That is roughly a 1.5x step per destination, which is the point: each island
	is worth the trip to the one before it, and none of them is so far ahead that
	the islands behind it become dead ground.
]]
local ISLAND_PREMIUM = {
	[TOMB] = 1.3,
	[DUNE] = 2.4,
	[COVE] = 4.6,
	[ASH]  = 8.6,
}

ItemConfig.Items = {}
local weightSum = 0
for _, r in RAW do
	-- Tomb rows sit outside this sum: they are not in the draw it normalises, so
	-- taking a share of it would have quietly made every beach item rarer and
	-- cheaper the day the vault was stocked. See the TOMB note above.
	-- `== nil`, not `~= TOMB`. Both off-beach pools have to be excluded here, and
	-- naming one of them is what would silently fold the next pool somebody adds
	-- back into the beach's odds.
	if r[11] == nil then
		weightSum += 1 / r[2]
	end
end

for _, r in RAW do
	local id, authored, lbs, shape, size, colour, mat, refl, name, desc =
		r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10]
	local tomb = (r[11] == TOMB)
	local dune = (r[11] == DUNE)
	local ash = (r[11] == ASH)
	local cove = (r[11] == COVE)
	-- Spawned from its own island's table rather than from the beach's draw.
	local offBeach = tomb or dune or ash or cove

	-- An off-beach item has no share of the beach's probability mass, so there is
	-- no normalised odds to derive: its authored number IS its rarity label, and
	-- tier and value follow from that exactly as they do for everything else.
	local spawn = offBeach and 0 or (1 / authored) / weightSum  -- true probability
	local oneIn = offBeach and math.max(1, math.floor(authored + 0.5))
		or math.max(1, math.floor(1 / spawn + 0.5))             -- what we show
	local lo, hi = ItemConfig.valueRange(oneIn)

	-- The island premium. See ISLAND_PREMIUM above. Applied to the RANGE rather
	-- than to a rolled value, so everything downstream -- the roll, its clamp,
	-- the index, the preview, the sell pad -- agrees without knowing this exists.
	-- nil for the beach, which is the 1.0 case and must not be touched.
	local premium = r[11] and ISLAND_PREMIUM[r[11]] or nil
	if premium then
		lo = math.max(1, math.floor(lo * premium + 0.5))
		-- hi is floored to at least lo + 1: valueRange guarantees a real span, and
		-- a premium that rounded the two together would turn a random roll into a
		-- constant for the cheapest rows on the richest island.
		hi = math.max(lo + 1, math.floor(hi * premium + 0.5))
	end

	local encased = (not tomb) and oneIn >= ItemConfig.EncasedFromOneIn

	ItemConfig.Items[id] = {
		ItemId = id,
		-- Found only on the vault floor. Read by rollItemId, which must never
		-- scatter grave goods across a beach.
		Tomb = tomb or nil,
		-- Found only on the desert field, under the same contract: a scribe's
		-- palette must never turn up in the surf.
		Dune = dune or nil,
		-- Found only on Ashfall Isle's black sand, same contract again: a lump of
		-- volcano glass must never come out of the home beach.
		Ash = ash or nil,
		-- Found only in Sakura Cove, same contract a fourth time: a shrine bell
		-- must never wash up on the home beach.
		Cove = cove or nil,
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
-- And the desert's, on the same terms. CTB's Config builds ISLANDS[2]'s pick
-- table from Config.DUNE_ITEMS rather than from this, but the list is exported
-- for the Index and for anything that wants to ask what a field can produce.
ItemConfig.DuneIds = {}
-- ...and Ashfall's, on exactly the same terms.
ItemConfig.AshIds = {}
-- ...and Sakura Cove's.
ItemConfig.CoveIds = {}
for _, id in ItemConfig.Order do
	if ItemConfig.Items[id].Tomb then
		table.insert(ItemConfig.TombIds, id)
	elseif ItemConfig.Items[id].Dune then
		table.insert(ItemConfig.DuneIds, id)
	elseif ItemConfig.Items[id].Ash then
		table.insert(ItemConfig.AshIds, id)
	elseif ItemConfig.Items[id].Cove then
		table.insert(ItemConfig.CoveIds, id)
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
		-- `or d.Cove` was missing, and the comment above is the reason it matters:
		-- a cove row's SpawnWeight is zero so it could not in practice be drawn,
		-- but "it cannot be picked, its weight is zero" is precisely the guarantee
		-- this belt-and-braces check exists because it quietly stops being true.
		-- Naming three of the four pools is how the fourth gets forgotten.
		if not (d.Tomb or d.Dune or d.Ash or d.Cove) then
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
