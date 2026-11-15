--[[
	PetConfig  --  ReplicatedStorage.Modules.PetConfig

	The pet catalogue, the egg tables, and the luck maths. Replicated: the
	client needs names, tiers, costs and odds to draw the station board and the
	hatch reveal, and none of it is secret -- the SERVER re-rolls every hatch
	from this same table and never takes a pet id from a client.

	ONE NUMBER DRIVES A PET: its position in its tier
	------------------------------------------------
	A pet declares only a tier and a name. Its luck is interpolated across the
	tier's authored band, so the 17th Common is meaningfully better than the
	1st without anybody hand-tuning sixty numbers that then drift apart. This
	is the same shape as ItemConfig, where OneIn drives tier, value and spawn.

		Common     1.05 .. 1.10     (+5% .. +10% luck)
		Uncommon   1.10 .. 1.30
		Rare       1.30 .. 1.75
		Epic       1.75 .. 2.50
		Legendary  2.50 .. 3.40
		Mythic     4.00            (one pet, so there is no band to sit on)

	Override a single pet with a `luck` field on its row if it needs to be an
	outlier; nothing else has to move.

	WHAT LUCK DOES  --  and the one place it does it
	------------------------------------------------
	Luck is spent at the WASH BAY, at the moment a crusted lump comes clean.
	It does NOT change how often a lump spawns: what is buried in a field is
	decided once, when the field is generated, and is shared by everybody on
	the server -- a per-player multiplier there would either be a lie or would
	have one player's pets rewriting another player's sand.

	The reveal is the opposite: it is per-player, it is server-side, and the
	client has never been told what is inside (InventoryController.publicView
	strips itemId and rarity from a crusted record). So both halves of "better
	items" can happen there, invisibly and honestly:

		1. LADDER  -- a chance to step the revealed item UP its own pool's
		              encased ladder, one or more rungs.
		2. SKEW    -- the value roll inside that item's range leans high.

	See LuckService (server) for the implementation of both.
]]

local PetConfig = {}

--------------------------------------------------------------------------
-- TIERS
--------------------------------------------------------------------------
-- Ordered worst-first. The colours match ItemConfig.Tiers so a Legendary pet
-- and a Legendary find read as the same word in the same gold.
PetConfig.Tiers = {
	{ key = "Common",    luck = { 1.05, 1.10 }, color = Color3.fromRGB(196, 204, 212), glow = Color3.fromRGB(236, 242, 248) },
	{ key = "Uncommon",  luck = { 1.10, 1.30 }, color = Color3.fromRGB(122, 222, 128), glow = Color3.fromRGB(196, 250, 198) },
	{ key = "Rare",      luck = { 1.30, 1.75 }, color = Color3.fromRGB(78, 158, 255),  glow = Color3.fromRGB(168, 212, 255) },
	{ key = "Epic",      luck = { 1.75, 2.50 }, color = Color3.fromRGB(186, 112, 255), glow = Color3.fromRGB(226, 190, 255) },
	{ key = "Legendary", luck = { 2.50, 3.40 }, color = Color3.fromRGB(255, 189, 61),  glow = Color3.fromRGB(255, 232, 158) },
	-- MYTHIC holds exactly one animal and is not a tier a roll can wander into:
	-- the only way to it is the last line of the Prestige shelf, at one in a
	-- million. The colour is ItemConfig's Mythic, unchanged, so the rarest pet
	-- and the rarest find are the same rose.
	-- A BAND SINCE PENGUIN ISLAND. Four Mythics now (the Jade Wish Dragon and
	-- the three arctic ones), interpolated like every other tier: the dragon
	-- keeps 4.00 by staying first in the roster, the arctic three sit at 4.10,
	-- 4.20 and 4.30 in the order the Arctic Egg makes them rarer. Kept narrow
	-- on purpose -- LuckService's rung ladder saturates near luck 18.9, and
	-- the best five-slot loadout (VIP + four at 4.30) is 17.7, still under it.
	{ key = "Mythic",    luck = { 4.00, 4.30 }, color = Color3.fromRGB(255, 92, 132),  glow = Color3.fromRGB(255, 186, 208) },
}

--[[
	VIP -- A TIER OF ITS OWN, ABOVE EVERYTHING, AND NOT A TIER A ROLL CAN REACH.

	It is appended here rather than written into the list above because ITS LUCK
	IS DERIVED FROM THE LIST: five percent above the best number any other tier
	can produce. Typing 4.20 in would work today and quietly stop being true the
	day somebody raises Mythic or adds a tier under it -- and a tier whose whole
	promise is "the best in the game" cannot be allowed to stop being that
	silently. Raise Mythic to 5.00 and this becomes 5.25 on the next boot.

	FIVE PERCENT, NOT FIVE POINTS. 4.00 x 1.05 = 4.20, which the HUD shows as
	+320% against Mythic's +300%.

	THE COLOUR IS PALE GOLD WITH A WHITE-HOT GLOW, deliberately not Legendary's
	saturated amber -- the two sit next to each other in the index and a second
	gold would read as the same tier twice. Pale-and-glowing reads as "off the
	top of the chart", which is what it is.
]]
local VIP_EDGE = 1.05
do
	local best = 0
	for _, t in PetConfig.Tiers do
		best = math.max(best, t.luck[2])
	end
	local vip = math.floor(best * VIP_EDGE * 100 + 0.5) / 100
	table.insert(PetConfig.Tiers, {
		key = "VIP", luck = { vip, vip },
		color = Color3.fromRGB(255, 226, 140), glow = Color3.fromRGB(255, 252, 232),
	})
end

PetConfig.TierByKey = {}
PetConfig.TierOrder = {}
for i, t in PetConfig.Tiers do
	t.index = i
	PetConfig.TierByKey[t.key] = t
	PetConfig.TierOrder[t.key] = i
end

function PetConfig.tierInfo(tierKey)
	return PetConfig.TierByKey[tierKey] or PetConfig.TierByKey.Common
end

function PetConfig.tierColor(tierKey): Color3
	return PetConfig.tierInfo(tierKey).color
end

--------------------------------------------------------------------------
-- FUSING DUPLICATES
--------------------------------------------------------------------------
--[[
	FIVE COPIES OF ONE PET BECOME ONE OF THE TIER ABOVE.

	Asked for on 2026-09-21, four hours into a session: "Was ist mit einer
	Maschine um die doppelten tiere zu multiplizieren?" -- what about a machine
	to multiply duplicate pets. Read as a FUSION rather than literally, which is
	the decision behind the whole shape of this: the bag caps at 250, the game
	refuses to hatch at the cap and sends you to the Pets tab to clear space, so
	a machine that made MORE pets would sharpen the exact problem the person
	asking had spent four hours walking into.

	A SINK, THEN. It takes five and returns one, so every fuse frees four slots
	and duplicates finally have somewhere to go that is not the release button.
	Trading already treats them as a good; this gives the player who has nobody
	to trade with the same exit.

	FIVE, AND THE LADDER IS STEEP ON PURPOSE. Five of a kind per rung compounds:
	25 Commons for a Rare, 125 for an Epic, 625 for a Legendary, 3,125 for a
	Mythic. Nothing about that competes with hatching for the good tiers -- it is
	a floor under bad luck, not a route around the eggs.

	VIP IS NOT A FUSION OUTCOME AND MYTHIC IS THE CEILING. Tier 7 holds exactly
	one pet, the Gilded Unicorn, and it arrives with a game pass. A ladder that
	ended there would hand out a paid exclusive for grinding, so it stops one
	rung short -- fusing a Mythic is refused rather than silently doing nothing.
]]
PetConfig.FuseCount = 5

-- The rung above this one, or nil at the top. Nil for Mythic (the ceiling) and
-- nil for VIP, which is not on this ladder at all.
function PetConfig.nextTier(tierKey: string): string?
	local here = PetConfig.TierByKey[tierKey]
	if not here then
		return nil
	end
	local up = PetConfig.Tiers[here.index + 1]
	if not up or up.key == "VIP" then
		return nil
	end
	return up.key
end

-- Every pet on one rung, in table order. Built on each call rather than cached
-- because it is asked for once per fuse, which is a player action.
function PetConfig.petsOfTier(tierKey: string): { string }
	local out = {}
	for _, p in PetConfig.Pets do
		if p.Tier == tierKey then
			table.insert(out, p.PetId)
		end
	end
	return out
end

--[[
	WHAT FIVE OF `petId` TURN INTO, or nil if they cannot turn into anything.

	UNIFORM ACROSS THE RUNG, deliberately, and not weighted by luck the way an
	egg roll is. An egg is a purchase and its odds are the product; this is a
	consolation for duplicates, and a player who has just given up five pets
	should not then lose a second roll inside the reward. Every pet on the next
	rung is equally likely, and the WORST pet up there still beats the five that
	went in.
]]
function PetConfig.fuseOutcome(petId: string, rng: Random): string?
	local def = PetConfig.get(petId)
	if not def then
		return nil
	end
	local up = PetConfig.nextTier(def.Tier)
	if not up then
		return nil
	end
	local pool = PetConfig.petsOfTier(up)
	if #pool == 0 then
		return nil
	end
	return pool[rng:NextInteger(1, #pool)]
end

--------------------------------------------------------------------------
-- EQUIPPING
--------------------------------------------------------------------------
-- Five out at once. The number lives here rather than in PetServer because the
-- Pets panel draws exactly this many slots, and a HUD with its own idea of the
-- cap lies to the player about what is possible.
PetConfig.MaxEquipped = 5

--[[
	THE RUCKSACK CEILING.

	TWO HUNDRED AND FIFTY, up from a hundred.

	A hundred was sized against a 100-coin Basic egg and a ten-pack bulk button:
	that is a few minutes of a first tide, so the cap arrived long before
	duplicates stopped being interesting and read as a wall rather than as
	tidying. At 500 a Basic egg it bites around the time it was always meant to.

	Which is the point -- a cap with no way out is a soft-lock, so the Pets panel
	carries a Release button and PetServer.release is the way back under it. The
	cap and the escape hatch have to ship together or the hundredth egg is the
	last one a player can ever buy.
]]
PetConfig.MaxOwned = 250

--[[
	HOW MANY PETS THIS PLAYER OWNS, PUBLISHED AS AN ATTRIBUTE.

	The pets panel is handed a whole snapshot and needs no such thing. Two files
	OUTSIDE this system do, and neither one can take a snapshot:

		TutorialHud   runs on the CLIENT, and every card it draws completes off an
		              attribute it can watch. It cannot require PetServer.
		FunnelServer  derives every onboarding step from the server's own
		              attributes on purpose -- see its header on why being told by
		              another module is not the same guarantee.

	So: one number, written by PetServer's `push`, which is the single place
	every ownership change in the game already lands. Read-only to everybody
	else, and a client that writes it anyway changes nothing -- an attribute set
	on the client does not replicate upward.
]]
PetConfig.OwnedAttribute = "PetsOwned"

--------------------------------------------------------------------------
-- THE CATALOGUE
--------------------------------------------------------------------------
--[[
	The names are the MODEL names, minus the `Pet_<Tier>_<NN>_` prefix the
	Blender export carries. PetServer looks a pet's art up at

		ReplicatedStorage.Pets.<Tier>.<anything ending in the pet's name>

	so both `Pet_Common_01_PebblePup` and a hand-renamed `PebblePup` resolve.
	A pet with no model still works -- it hatches, it equips, it grants luck,
	and it follows you as a tinted placeholder. Art is not load-bearing.
]]
local ROSTER = {
	Common = {
		"PebblePup", "MittenKit", "CloverBun", "AcornSquirrel", "PuddleDuckling",
		"MeadowLamb", "SpeckleHen", "CinderPiglet", "BrambleHedgehog",
		"SandyCrablet", "DuneGecko", "TideMinnow", "PocketMole", "BuckleBeetle",
		"FuzzChick", "CobbleToad", "NibbleMouse",
	},
	Uncommon = {
		"TidalTerrapin", "LongearLop", "BoulderArmadillo", "CoilSnail",
		"FanfinBetta", "TusklingBoar", "AntlerFawn", "BanditRaccoon",
		"PufferNimbus", "WaddlePenguin", "PerchOwlet", "SnorkelOtter",
		"SprigSloth",
	},
	Rare = {
		"LunarKit", "EmberwispFennec", "GlimmerMoth", "RuneGolemite",
		"FrostCubling", "ThornwoodSprout", "MistailSerpent", "PrismJelly",
		"StarfleckDeer", "CinderImp", "AuroraAxolotl", "GrimoireBat",
		"SandwhisperDjinn",
	},
	Epic = {
		"Rustclaw", "MagmaColossus", "VoltaicWolf", "Gearhawk",
		"TidebreakerKraken", "CryoRhino", "ScrapheapSentinel",
		"EmberforgeSalamander", "TempestRay", "ChronoBeetle",
	},
	Legendary = {
		"Trihedron", "AegisWarden", "VoidSerpentEmperor", "SolarisPhoenix",
		"TitanCorebreaker", "CelestialKirin", "AbyssalLeviathan",
	},
	Mythic = {
		"JadeWishDragon",
		-- Penguin Island's three, in the Arctic Egg's rarity order (see the
		-- Arctic shelf): the chase animal is last, so it is the luckiest.
		"FrostfangWolf", "AuroraPhoenix", "BorealisWyrm",
	},
	-- EMPTY ON PURPOSE, and it has to exist: the build loop below asserts every
	-- tier has a roster, and VIP's one animal is an EXCLUSIVE -- appended after
	-- that loop with a stated luck rather than interpolated across a band. An
	-- empty list here is the honest way to say "nothing rolls into this tier".
	VIP = {},
}

-- "PebblePup" -> "Pebble Pup". Authored once here so the HUD, the reveal card
-- and the station board cannot disagree about what a pet is called.
local function spaced(name: string): string
	local out = name:gsub("(%l)(%u)", "%1 %2")
	return out
end

PetConfig.Pets = {}    -- [petId] = def
PetConfig.Order = {}   -- petId, worst tier first, then roster order
PetConfig.ByTier = {}  -- [tierKey] = { petId, ... }

for _, tier in PetConfig.Tiers do
	local list = ROSTER[tier.key]
	assert(list, "[PetConfig] no roster for tier " .. tier.key)
	PetConfig.ByTier[tier.key] = {}

	local lo, hi = tier.luck[1], tier.luck[2]
	local span = math.max(#list - 1, 1)

	for i, name in list do
		local id = name
		assert(not PetConfig.Pets[id], "[PetConfig] duplicate pet id: " .. id)

		-- Linear across the tier's band. The first pet in a tier sits on the
		-- floor, the last on the ceiling, so a tier's best is always its last
		-- row and reordering the list retunes it deliberately rather than by
		-- accident.
		local luck = lo + (hi - lo) * ((i - 1) / span)

		PetConfig.Pets[id] = {
			PetId = id,
			DisplayName = spaced(name),
			Tier = tier.key,
			TierIndex = tier.index,
			-- Rounded to whole percent: a luck readout of "+27%" is a number a
			-- player can hold, "+27.3184%" is noise.
			Luck = math.floor(luck * 100 + 0.5) / 100,
			Index = i,
			ModelName = string.format("Pet_%s_%02d_%s", tier.key, i, name),
		}
		table.insert(PetConfig.Order, id)
		table.insert(PetConfig.ByTier[tier.key], id)
	end
end

--------------------------------------------------------------------------
-- THE EXCLUSIVE PETS
--------------------------------------------------------------------------
--[[
	Pets that are NOT in the ROSTER and are NOT in any egg. They are bought, or
	awarded, and there is no other way to get one.

	WHY THEY ARE NOT JUST ANOTHER NAME IN THE ROSTER, which is the obvious build:
	a tier's luck is INTERPOLATED across its list, `lo + (hi-lo) * (i-1)/span`.
	Adding a fourteenth name to Rare would therefore re-space all thirteen pets
	already in it -- every existing player's Lunar Kit and Glimmer Moth would
	quietly change value to make room for a pass. A tier's band is a promise to
	the pets already standing in it.

	So these are appended AFTER the roster loop with an explicit Luck, which also
	means the number is stated rather than derived and cannot drift when the tier
	is re-ordered.

	THEY CANNOT LEAK INTO AN EGG. Egg shelves list pets by explicit id and assert
	each one exists (see the pool build below) -- nothing sweeps ByTier to fill a
	shelf -- so an exclusive pet is unrollable by construction rather than by a
	flag somebody has to remember to check.

	They ARE in Order and ByTier, deliberately: those are what the Pets panel and
	the index draw from, and a pet you own that does not appear in your own
	collection would read as a bug.
]]
local EXCLUSIVE = {
	{
		id = "Kingsmane",
		tier = "Rare",
		-- THE MIDDLE OF THE RARE BAND. Rare runs 1.30 to 1.75, so 1.53 is what an
		-- average Rare pet is worth -- which is what "the same luck the rare pets
		-- give" asks for. Deliberately not 1.75: a pet nobody can roll should sit
		-- among its tier rather than on top of it, or the pass stops being a head
		-- start and becomes the best Rare in the game.
		luck = 1.53,
		-- 00, not 14: 01..13 are the roster's Rare pets and this is not the
		-- fourteenth of a list it is not in. PetVisuals resolves art by ModelName
		-- first, so the number is free.
		model = "Pet_Rare_00_Kingsmane",
	},
	{
		id = "GildedUnicorn",
		tier = "VIP",
		--[[
			READ OFF ITS OWN TIER, not typed. The VIP tier's band is derived (see
			VIP_EDGE above) and this is the only pet in it, so quoting the number
			here as well would be the same fact in two places -- and the one that
			drifts is always the copy.

			Note this breaks the Kingsmane rule directly above, which says an
			unrollable pet should sit AMONG its tier rather than on top of it. That
			rule exists to stop a pass outclassing the pets people are chasing
			inside a shared band. This pet is not in a shared band -- it is alone in
			its own tier, by design and by the owner's call, and being the best in
			the game is the thing being sold.
		]]
		luck = PetConfig.TierByKey.VIP.luck[2],
		-- Lives in ReplicatedStorage.Pets.VIP: PetServer.findArt looks in the
		-- folder NAMED FOR THE TIER, so a new tier needs a new folder or every
		-- pet in it draws the placeholder lozenge.
		model = "Pet_VIP_00_GildedUnicorn",
	},
	{
		--[[
			THIRTY DISTINCT DAYS. The longest reward in the game and the only one
			that cannot be bought, rushed or rolled -- it is bought with a month
			of showing up, which is the one currency no pass sells.

			LEGENDARY, MID-BAND, AND THAT IS THE WHOLE ARGUMENT. Kingsmane's rule
			applies here rather than GildedUnicorn's: this pet shares a band with
			seven pets people are actively chasing, so it sits among them at 2.95
			rather than on top of them at 3.40. Legendary also leaves Mythic and
			the VIP pass untouched -- a FREE pet that outclassed the thing being
			sold would quietly cost more than the retention it buys.
		]]
		id = "Tidewarden",
		tier = "Legendary",
		luck = 2.95,
		-- 00 for the same reason Kingsmane is 00: 01..07 are the roster's
		-- Legendary pets and this is not the eighth of a list it is not in.
		--
		-- ART IS NOT REQUIRED FOR THIS TO SHIP. findArt falls through to
		-- buildPlaceholder, which draws a lozenge in the tier colour and grants
		-- the full 2.95 -- see the note above buildPlaceholder, which argues
		-- that case is a finished state rather than a broken one. Drop a model
		-- of this name into ReplicatedStorage.Pets.Legendary and it is picked
		-- up with no code change.
		model = "Pet_Legendary_00_Tidewarden",
	},
}

for _, ex in EXCLUSIVE do
	local tier = PetConfig.TierByKey[ex.tier]
	assert(tier, "[PetConfig] exclusive pet '" .. ex.id .. "' names an unknown tier: " .. tostring(ex.tier))
	assert(not PetConfig.Pets[ex.id], "[PetConfig] duplicate pet id: " .. ex.id)

	PetConfig.Pets[ex.id] = {
		PetId = ex.id,
		DisplayName = spaced(ex.id),
		Tier = ex.tier,
		TierIndex = tier.index,
		Luck = ex.luck,
		-- Index 0 marks it as outside the tier's numbering. Anything that sorts on
		-- Index puts it first within its tier, which is right: it is the one Rare
		-- that was never on the shelf.
		Index = 0,
		ModelName = ex.model,
		-- Read by the Pets panel and by anything that wants to say where a pet came
		-- from. Nothing gates on it -- the egg tables already cannot reach this pet.
		Exclusive = true,
	}
	table.insert(PetConfig.Order, ex.id)
	table.insert(PetConfig.ByTier[ex.tier], ex.id)
end

PetConfig.Count = #PetConfig.Order

--------------------------------------------------------------------------
-- AUTO-RELEASE  --  the rarity floor
--------------------------------------------------------------------------
--[[
	RELEASE ANYTHING THAT HATCHES BELOW THIS TIER, WITHOUT ASKING.

	Asked for on 2026-09-09: "if there were a pet acceptance filter (rank
	setting: discard below Legendary, etc.) I could keep rolling continuously".
	That is the whole feature -- not a convenience but a SESSION LENGTH one. The
	bag caps at MaxOwned, the game refuses to hatch into a full one, and the
	player who asked was sitting at exactly 250 doing nothing but clearing space
	by hand between pulls.

	THE VALUE IS A TIER INDEX, and 0 is off. Stored as a plain number because it
	goes through SettingsServer's whitelist, which compares values by equality --
	a table or a string key would work equally well there and be worse here,
	where the comparison against a pet's own TierIndex is the entire rule.

	IT STOPS AT LEGENDARY ON PURPOSE. The obvious next rungs -- release anything
	below Mythic, or below VIP -- would auto-destroy Legendaries, which are the
	rarest thing most accounts will ever hold, on a setting the player might have
	chosen once and forgotten. There is no undo and no sell value to soften it.
	The manual TIDY card already covers "I really do want to cut deeper", with a
	count in front of the player before anything happens; this one runs unattended
	and is deliberately the more timid of the two.

	A LOCKED PET IS NEVER AUTO-RELEASED, and that rule is not here -- it is in
	PetServer, which is the only side that knows what is locked. This module
	answers the tier question and nothing else.
]]
PetConfig.AutoReleaseAttribute = "Set_PetAutoRelease"

-- Built from the tier table rather than typed, so a tier inserted in the middle
-- cannot leave this list naming the wrong rungs. OFF first; the ladder runs from
-- Uncommon (release Commons) to Legendary and stops -- see the note above.
PetConfig.AutoReleaseSteps = { { index = 0, label = "OFF" } }
for _, key in ipairs({ "Uncommon", "Rare", "Epic", "Legendary" }) do
	local tier = PetConfig.TierByKey[key]
	if tier then
		table.insert(PetConfig.AutoReleaseSteps,
			{ index = tier.index, label = string.upper(key) })
	end
end

-- The floor this player has chosen, or 0. Clamped to a step that actually
-- exists: a value from an older build, or one a tier rename left stranded, must
-- read as OFF rather than as "release everything".
function PetConfig.autoReleaseFloor(player: Instance?): number
	if typeof(player) ~= "Instance" then
		return 0
	end
	local v = tonumber(player:GetAttribute(PetConfig.AutoReleaseAttribute)) or 0
	for _, step in ipairs(PetConfig.AutoReleaseSteps) do
		if step.index == v then
			return v
		end
	end
	return 0
end

-- Would this pet be thrown back, on tier alone? The lock is PetServer's to add.
function PetConfig.belowFloor(petId: string, floor: number): boolean
	if type(floor) ~= "number" or floor <= 0 then
		return false
	end
	local def = PetConfig.Pets[petId]
	return def ~= nil and (def.TierIndex or 1) < floor
end

-- What the shop row and the toast call the current setting.
function PetConfig.autoReleaseLabel(floor: number): string
	for _, step in ipairs(PetConfig.AutoReleaseSteps) do
		if step.index == floor then
			return step.label
		end
	end
	return "OFF"
end

function PetConfig.get(petId: string)
	return PetConfig.Pets[petId]
end

function PetConfig.expect(petId: string)
	local d = PetConfig.Pets[petId]
	assert(d, "[PetConfig] unknown PetId: " .. tostring(petId))
	return d
end

--------------------------------------------------------------------------
-- LUCK MATHS
--------------------------------------------------------------------------
--[[
	BONUSES ADD; THEY DO NOT COMPOUND.

	Three Legendaries compounding is 2.5^3 = 15.6x, which is not a pet loadout,
	it is a different game. Summing what each pet contributes ABOVE 1.0 gives
	1 + 1.5 + 1.5 + 1.5 = 5.5x for the same three -- still a colossal reward for
	a colossal roll, and it keeps the third slot worth filling with whatever you
	have rather than being worthless unless it matches the other two.
]]
function PetConfig.luckOf(petIds: { string }): number
	local total = 1.0
	for _, id in petIds do
		local def = PetConfig.Pets[id]
		if def then
			total += (def.Luck - 1.0)
		end
	end
	return math.max(1.0, total)
end

-- "+35%" -- what the HUD puts next to the paw icon.
function PetConfig.luckText(luck: number): string
	return string.format("+%d%%", math.floor((luck - 1) * 100 + 0.5))
end

--[[
	THE BEST LOADOUT -- what the panel's "Equip Best" button asks for.

	Shared rather than written on either side, because the server has to be the
	one that decides and the client has to draw the same answer before the sync
	comes back. Two implementations of "best" is two answers that disagree for
	a frame every time you press it.

	Deterministic on purpose: luck descending, then tier, then id. A tie broken
	arbitrarily would make the button reshuffle your pets every press, and
	pressing it twice has to be a no-op.

	Duplicates are collapsed -- the same pet cannot fill two slots (see
	PetServer.setEquipped), so offering it twice would silently waste one.
]]
--[[
	ONE POOL ENTRY PER COPY, NOT PER SPECIES.

	This used to push each owned petId in once however many you held, so the
	pool could never be longer than the number of DIFFERENT pets owned -- and
	a player who opened a ten-pull and got eleven pets across three species got
	a three-pet loadout out of a five-slot bag, with no way to fill the other
	two and no message saying why.

	Capped at `limit` copies each, because a player holding two hundred of one
	pet does not need a two-hundred-long pool to pick five from.
]]
function PetConfig.bestOf(owned, limit: number?): { string }
	limit = limit or PetConfig.MaxEquipped
	local pool = {}
	for petId, count in owned do
		local def = PetConfig.Pets[petId]
		if def and type(count) == "number" and count > 0 then
			for _ = 1, math.min(count, limit) do
				table.insert(pool, def)
			end
		end
	end
	table.sort(pool, function(a, b)
		if a.Luck ~= b.Luck then
			return a.Luck > b.Luck
		end
		if a.TierIndex ~= b.TierIndex then
			return a.TierIndex > b.TierIndex
		end
		return a.PetId < b.PetId
	end)
	local out = {}
	for i = 1, math.min(limit, #pool) do
		table.insert(out, pool[i].PetId)
	end
	return out
end

--------------------------------------------------------------------------
-- EGGS
--------------------------------------------------------------------------
--[[
	Three eggs, and what is actually inside one.

	AN EGG IS A HAND-PICKED SHELF OF FIVE ANIMALS, not a tier lottery. It used
	to roll a TIER off a weights row and then pick uniformly inside that tier,
	which meant every egg could hand you any of the sixty pets and the station
	board could only ever advertise a RARITY -- any one Common was really a
	fiftieth of a seventeenth, a number too small to print next to a picture of
	an animal without reading as a lie. Five named pets on a shelf is the thing
	a player can shop for: you walk up, you see exactly what is in this egg, and
	the number under each animal is that animal's own chance.

	WHAT SEPARATES THE THREE is the shelf, not the price tag:

		* the FLOOR rises      Basic starts at a Common, Desert at an Uncommon,
		                       Prestige at a Rare. Prestige cannot hand you a
		                       Common at all.
		* the MASS moves up    Basic pays an Epic 2.6% of the time; Prestige pays
		                       one 38% of the time.
		* the CHASE gets rarer the last animal on each shelf is 0.4%, 0.3%, 0.2%.
		                       A grander egg is a better floor AND a longer shot
		                       at its own top prize; those are not in tension,
		                       together they are the whole product.

	AND ONE PET IS NOT ADVERTISED. The last line of the Prestige shelf is the
	Jade Wish Dragon -- the only Mythic in the game, +300% luck, one roll in a
	million. Its chance prints as "???" on the station board rather than as a
	number (see `secret` below, and EggClient's pct): a figure that small reads
	as a typo, and the rumour is worth more than the decimal.

	Weights are relative, not percentages -- they are normalised on load, so
	editing one row cannot silently make a shelf stop summing to 100. They are
	WRITTEN as percentages anyway, because a shelf that adds to 100 by hand is a
	shelf a person can check at a glance.
]]
PetConfig.Eggs = {
	{
		key = "Basic",
		name = "Basic Egg",
		blurb = "Something in here likes shiny things.",
		-- THE FOUR PRICES ARE ANCHORED TO THE TIDE EACH SHELF IS WORTH WANTING,
		-- rather than to round numbers. Rebuilding all four tracks costs
		-- 6,000 * (1.24^(C-1) - 1) at ceiling C (bases quadrupled 2026-08), and
		-- the rebirth gate is authored in MINUTES against the income model --
		-- see ProgressionConfig.Rebirth.requirement. Tide anchors below were
		-- re-derived 2026-08b against that curve.
		--
		-- THE PRICES DID NOT MOVE WHEN FOUR TRACKS WERE REMOVED. That took the
		-- ladder's base sum from 1,060 to 360, so every rebuild quoted below is
		-- about a third of what it was and each shelf now costs roughly three
		-- times the rebuild it was pitched against: Desert was a third of one and
		-- is most of one, Celestial was one and is three. Left alone on purpose --
		-- that was a removal, not a rebalance. An egg is a want, not a gate, so a
		-- shelf landing a tide or two later than it reads shuts nobody out of
		-- anything; repricing them would be a separate decision.
		--
		-- 100 was about thirteen seconds of a first tide, so the bag hit its cap
		-- inside one session and the egg ladder was over before the second. 500 is
		-- a couple of minutes of the twenty-minute tutorial tide at the 2026-08b
		-- income -- still the impulse buy of the four, which is right for the
		-- FIRST egg in the game. Everything above it is a real decision.
		cost = 500,
		color = Color3.fromRGB(240, 236, 224),
		accent = Color3.fromRGB(126, 205, 158),
		pets = {
			-- One animal per tier, and deliberately the FIRST of each: the Basic
			-- shelf is the bottom of every ladder, so a Basic Legendary is still
			-- the weakest Legendary and there is somewhere to go from here.
			{ id = "PebblePup",     weight = 62 },
			{ id = "TidalTerrapin", weight = 26 },
			{ id = "LunarKit",      weight = 9 },
			{ id = "Rustclaw",      weight = 2.6 },
			{ id = "Trihedron",     weight = 0.4 },
		},
	},
	{
		key = "Desert",
		name = "Desert Egg",
		blurb = "Dug out of somewhere hot and dry.",
		-- Tides 5-8 under the 2026-08b curve: one tide's gate passes 15,000
		-- between rebirths 7 and 8, so this is a real save at 5 and routine by
		-- 9. Was 2,500: a minute and a half of a FIRST tide, for a shelf whose
		-- whole product is an Uncommon floor you are not meant to reach yet.
		cost = 15000,
		color = Color3.fromRGB(238, 206, 140),
		accent = Color3.fromRGB(214, 150, 62),
		-- No Commons. The floor moves up a whole tier, which is the actual
		-- product being sold at 25x the Basic price -- and the shelf is dressed
		-- to match the name: a boar, a djinn, a salamander, a phoenix.
		pets = {
			{ id = "TusklingBoar",         weight = 46 },
			{ id = "SandwhisperDjinn",     weight = 34 },
			{ id = "EmberforgeSalamander", weight = 13 },
			{ id = "SolarisPhoenix",       weight = 6.7 },
			-- Rarer than the phoenix above it AND luckier than it. A chase pet
			-- that is a long shot without also being the best thing on the shelf
			-- is a punishment for good luck.
			{ id = "TitanCorebreaker",     weight = 0.3 },
		},
	},
	{
		key = "Prestige",
		name = "Prestige Egg",
		blurb = "For people who have already turned the tide.",
		-- Tides 16-18 under the 2026-08b curve: one tide's gate passes 400,000
		-- between rebirths 17 and 18. The name says "already turned the tide"
		-- and at 50,000 it was affordable on the first one.
		cost = 400000,
		color = Color3.fromRGB(206, 158, 255),
		accent = Color3.fromRGB(255, 189, 61),
		-- A Rare floor, an Epic more often than not, two Legendaries... and the
		-- one Mythic in the game on the bottom line.
		pets = {
			{ id = "AuroraAxolotl",     weight = 46 },
			{ id = "TidebreakerKraken", weight = 38 },
			{ id = "CelestialKirin",    weight = 15.7999 },
			{ id = "AbyssalLeviathan",  weight = 0.2 },
			-- One in a million. `secret` is what tells the station board to print
			-- "???" here instead of a percentage -- it changes NOTHING about the
			-- roll, which is this weight and nothing else.
			{ id = "JadeWishDragon",    weight = 0.0001, secret = true },
		},
	},
	{
		key = "Celestial",
		name = "Celestial Egg",
		blurb = "Pulled out of the dark between the stars.",
		-- Tides 24-27 under the 2026-08b curve: one tide's gate passes 8M
		-- between rebirths 26 and 27, so saving for this alongside the shop is
		-- a several-session project -- which is why it reads as the last thing
		-- you buy rather than the next one. Was 1,000,000, reachable around
		-- tide 8.
		cost = 8000000,
		color = Color3.fromRGB(140, 219, 255),
		accent = Color3.fromRGB(255, 51, 179),
		--[[
			THE TOP OF THE LADDER, and it follows the same three rules as the
			three shelves above rather than inventing a fourth idea.

				floor   Prestige's worst line is a Rare; this one's is an Epic.
				        Celestial cannot hand you anything below Epic at all.
				mass    Prestige pays a Legendary 15.8% of the time. This pays
				        one 58.9% -- a Legendary is the EXPECTED outcome here,
				        which is what 20x the Prestige price is buying.
				chase   0.4 -> 0.3 -> 0.2 -> 0.1. Each egg's chase is rarer than
				        the last AND is the luckiest animal on its own shelf.

			ITS OWN TOP PRIZE IS THE MYTHIC, and it has to be: the rule above
			says a grander egg needs a grander chase, and there is nothing above
			AbyssalLeviathan except the Jade Wish Dragon. Prestige's secret
			one-in-a-million line is untouched and still means what it meant --
			that is the miracle story. THIS is the purchase. Paying 20x for a
			thousandfold better shot at the same animal is the whole product.

			THE NUMBERS ARE A FIRST PASS. The shape is argued for; the exact
			weights and the 8,000,000 price are not playtested against your
			economy. Retune freely -- the shelf normalises on load, so nothing
			breaks if these stop summing to 100.
		]]
		pets = {
			{ id = "AegisWarden",        weight = 35 },
			{ id = "TempestRay",         weight = 24 },
			{ id = "VoidSerpentEmperor", weight = 23.9 },
			{ id = "ChronoBeetle",       weight = 17 },
			{ id = "JadeWishDragon",     weight = 0.1 },
		},
	},
	--[[
		THE ARCTIC EGG -- Penguin Island's shelf, rebirth 34, and the point of
		sailing there for anyone who already owns the Celestial's animals.

		THE SAME FIVE ANIMALS AS THE CELESTIAL, PLUS THREE. Nothing is taken
		away: the two Legendaries and two Epics and the dragon are all still in
		here, at BETTER odds -- Legendary 64% against the Celestial's 58.9 --
		and the three arctic Mythics sit under them. Mythic as a tier is 4.2%
		here against 0.1% on the Celestial, which is forty-two times likelier
		and still one hatch in twenty-four: rare enough to stay a Mythic, common
		enough that a player who came for one is not paying for a lottery.

		The chase line keeps the ladder's shape -- 0.4, 0.3, 0.2, 0.1 -- and		
		the Borealis Wyrm is the luckiest animal on the shelf (roster index 4).

		160M was the x20 step the Celestial took over the Prestige: one tide's
		gate at rebirth 34 is ~249M, so it cleared inside the first tide here.

		--------------------------------------------------------------
		CUT TO 40M, 2026-09-28. THE PRICE WAS THE WALL, NOT THE ODDS.
		--------------------------------------------------------------
		Two reports on 2026-09-27, both at 35 rebirths:

		  proutesaledu91  "pas assez de chance d'avoir les oeuf super fort ...
		                   j'ai ouvert plus de 50 (le plus chere)"
		  jldraco922      "le pourcentage des oeuf son trop faible"

		NEITHER WAS OPENING THIS EGG. Their profiles say 1.44B and 1.99B lifetime
		earned, which is 9 and 12 Arctic eggs across their ENTIRE history -- so
		"50" and "100" were Celestials or Prestiges, and "the most expensive"
		meant the most expensive they could reach.

		The odds were never the problem and are unchanged. Coins per Mythic:

		  Prestige  $400B   Celestial  $8B   Arctic  $3.81B

		The ladder is ordered correctly -- the dear egg IS the efficient one. What
		is wrong is how few pulls a player at this depth ever gets. At a realistic
		30% of lifetime earnings spent on eggs, those two get 2.7 and 3.7 pulls
		EVER: E[Mythic] 0.11 and 0.16. A one-in-eight chance of seeing the top of
		the ladder, after thirty-five tides.

		At 40M the same budget buys 10.8 and 14.9 pulls -- E[Mythic] 0.45 and 0.63,
		a coin flip rather than a lottery. The Legendary count is the larger and
		quieter win: 1.7 -> 6.9 expected, so the shelf stops being one
		disappointing pull and starts being an event.

		⚠️ WHAT THIS BREAKS, STATED SO IT IS NOT REDISCOVERED AS A BUG: the x20
		step above, and the tide relationship with it. At 40M this is ~16% of the
		rebirth-34 gate rather than ~64%, and only a x5 step over the Celestial.
		That was a deliberate trade, made with the numbers above in front of us --
		not a number somebody rounded. If the ladder is ever re-tuned, restore the
		relationship by moving the CELESTIAL rather than by putting this back.

		SCOPE, ALSO STATED: measured over 566 live profiles, 97.7% of players are
		under 10 rebirths and 0.2% can reach this egg at all; 0.35% have ever held
		a Mythic. This is a change for the deep tail, and it is not expected to
		move D1 for anybody else.
	]]
	{
		key = "Arctic",
		name = "Arctic Egg",
		blurb = "Chipped out of the pack ice at the top of the world.",
		-- 160000000 until 2026-09-28; see the note above for the measurement.
		cost = 40000000,
		color = Color3.fromRGB(214, 236, 255),
		accent = Color3.fromRGB(90, 200, 255),
		pets = {
			{ id = "AegisWarden",        weight = 34 },
			{ id = "VoidSerpentEmperor", weight = 30 },
			{ id = "TempestRay",         weight = 18 },
			{ id = "ChronoBeetle",       weight = 13.8 },
			{ id = "JadeWishDragon",     weight = 2.0 },
			{ id = "FrostfangWolf",      weight = 1.5 },
			{ id = "AuroraPhoenix",      weight = 0.6 },
			{ id = "BorealisWyrm",       weight = 0.1 },
		},
	},
}

PetConfig.EggByKey = {}
for i, egg in PetConfig.Eggs do
	egg.index = i

	--[[
		Normalise once, on load, and build the two views of a shelf the rest of
		the game reads:

			egg.pool     the five animals, likeliest first -- what the station
			             board draws and what rollPet walks.
			egg.weights  the per-TIER totals, and egg.odds their shares. Kept
			             because the reveal and the HUD still talk in rarities,
			             but DERIVED from the shelf now rather than being the
			             thing the shelf was derived from, so the two can no
			             longer drift apart.
	]]
	local total = 0
	for _, row in ipairs(egg.pets) do
		assert(PetConfig.Pets[row.id],
			"[PetConfig] egg '" .. egg.key .. "' lists a pet that does not exist: " .. tostring(row.id))
		row.weight = math.max(0, row.weight or 0)
		total += row.weight
	end
	assert(total > 0, "[PetConfig] egg '" .. egg.key .. "' has no weight anywhere")
	egg.weightTotal = total

	egg.weights = {}
	egg.odds = {}
	for _, tier in PetConfig.Tiers do
		egg.weights[tier.key] = 0
		egg.odds[tier.key] = 0
	end

	egg.pool = {}
	for _, row in ipairs(egg.pets) do
		local def = PetConfig.Pets[row.id]
		table.insert(egg.pool, {
			petId = row.id,
			tier = def.Tier,
			weight = row.weight,
			chance = row.weight / total,
			secret = row.secret == true,
		})
		egg.weights[def.Tier] += row.weight
		egg.odds[def.Tier] += row.weight / total
	end

	-- Likeliest first, deterministically. The board draws the shelf in this
	-- order and rollPet walks it in this order, so the long shot is the last
	-- thing either of them reaches -- which is what makes the fallback in
	-- rollPet safe to point at pool[1].
	table.sort(egg.pool, function(a, b)
		if a.weight ~= b.weight then
			return a.weight > b.weight
		end
		return a.petId < b.petId
	end)

	PetConfig.EggByKey[egg.key] = egg
end

function PetConfig.eggFor(key: string)
	return PetConfig.EggByKey[key]
end

--[[
	THE ROLL. One stage now, straight down the egg's own shelf.

	It used to be two -- a tier by weight, then a pet uniformly inside that
	tier -- and the second stage is exactly what made the advertised numbers
	and the delivered pet two different subjects. A shelf of five removes it:
	the weight written beside an animal in the table above IS that animal's
	chance, it is what the board prints, and it is what this function rolls.

	`rng` is required rather than optional: the server owns the stream, and a
	roll that silently falls back to a shared generator is a roll two players
	can be made to share.
]]
function PetConfig.rollPet(eggKey: string, rng: Random): (string, string)
	local egg = PetConfig.EggByKey[eggKey]
	assert(egg, "[PetConfig] unknown egg: " .. tostring(eggKey))
	assert(typeof(rng) == "Random", "[PetConfig] rollPet needs a Random")

	local roll = rng:NextNumber() * egg.weightTotal
	local acc = 0
	for _, row in ipairs(egg.pool) do
		acc += row.weight
		if roll < acc then
			return row.petId, row.tier
		end
	end

	--[[
		Float error at the very top of the range only -- and the fallback goes to
		the COMMONEST pet on the shelf, which is a reversal.

		The old one reached for the best tier the egg could produce, so that a
		Prestige egg could never wobble into paying out a Common. That was a safe
		trade while the top of a shelf was one roll in six. It is not safe now:
		the bottom line of the Prestige shelf is one in a million, and a fallback
		that hands out the jackpot whenever the arithmetic wobbles would pay it
		far more often than the shelf advertises -- which is the one number in
		this file that has to be true. pool is sorted likeliest-first, so pool[1]
		is the animal the player was overwhelmingly likely to get anyway.
	]]
	local first = egg.pool[1]
	return first.petId, first.tier
end

--------------------------------------------------------------------------
-- WHERE THE STATIONS STAND
--------------------------------------------------------------------------
--[[
	One plaza per island, every egg on it. "Desert Egg" is a name, not a
	location: gating an egg behind a map would mean a player who has not
	unlocked the ferry cannot spend past 100 coins, and the price already does
	all the gating that is wanted.

	`islandId` matches CTB.Config.ISLANDS. `offset` is measured from the middle
	of that island's rakeable field, and PetStationBuilder raycasts for the
	ground rather than trusting a Y here -- islands are terrain and terrain
	moves.
]]
--[[
	EVERY ISLAND GETS ONE, AND THIS TABLE DOES NOT DECIDE WHICH ISLANDS EXIST.

	It was a list of four, written the same afternoon a fifth island (Ashfall
	Isle) was added to CTB.Config by somebody else -- so the list was wrong
	before it ever ran, and silently: four plazas came up, the print said "4
	egg plazas", and the new island simply had no pets on it.

	So PetStationBuilder walks Config.ISLANDS itself and this is only a table of
	EXCEPTIONS, keyed by island id. An island with no row here gets the default
	placement, which means adding an island to the game adds a plaza to it.
]]
--[[
	WHICH SHELVES STAND ON WHICH ISLAND.

	The row used to be all four eggs on all five islands, which threw the whole
	progression away at the first plaza: a brand new player standing on the
	starter beach could see -- and, with enough saved up, buy -- the same
	Celestial egg as somebody who had earned their way to the volcano. The eggs
	had tiers and the WORLD did not.

	So the shelf list grows by one island:

		Beach        Basic                                  the starter egg, alone
		Dunes        Basic, Desert
		Vault        Basic, Desert                           see below
		Sakura Cove  Basic, Desert, Prestige
		Ashfall      Basic, Desert, Prestige, Celestial      all four

	The ferry already gates travel on Sifter level (Beach 1, Dunes 3, Cove 5,
	Ashfall 6), so this makes the egg you can reach a function of how far you
	have actually got rather than of how patient you are with a coin counter.

	THE VAULT GETS NO PLAZA AT ALL, and that is measured rather than taste. It is
	not a ferry stop -- it is the tomb behind the pyramid door, a 32-cell treasure
	room with `crust = false` -- and the default plaza position for it, twenty
	studs beyond its own field edge, has NOTHING UNDER IT: a downcast anywhere
	within a hundred and forty studs of (3000, 0) finds no part and no terrain,
	because the room is poured at runtime and does not extend that far. Two egg
	sheds would have stood in the void outside it.

	`plaza = false` is how an island opts out. It is deliberately NOT the same as
	an empty `eggs` list, which is a typo and falls back to the full shelf.

	An island with no `eggs` row gets EVERY shelf, which is the old behaviour and
	the right default: a new island added by somebody else should come up with a
	full plaza rather than an empty one.
]]
--[[
	THE ROW FRAME. Every precinct in the game is now laid out to one plan --
	the services (wash bay, sell, outfitters, car pad) together on ONE flank of
	the island's walk, and the egg row ALONE on the opposite flank, every
	frontage turned to face the walk. A `lateral` cannot say any of that: it
	could slide the default south-of-field line but never turn it to stand
	beside a road, so the exception rows carry a full frame instead.

	  row.x, row.z   the row's CENTRE on the ground (Y is still raycast)
	  row.yaw        degrees. The stations are laid along the frame's own X
	                 axis and every booth's OPEN FACE is the frame's +Z, so:
	                   yaw 0     row along +X, booths face +Z (the old default)
	                   yaw 90    row along -Z, booths face +X (east)
	                   yaw -90   row along +Z, booths face -X (west)
	                   yaw 180   row along -X, booths face -Z (south)

	An island with no `row` still gets the derived south-of-field placement,
	so a new island added by somebody else still comes up with a plaza.
]]
--[[
	ASHFALL'S CAMP DATUM.

	Island4Builder writes that island's whole southern layout -- the causeway, the
	camp square, the Cinder Road, the four services and the pier -- as offsets
	from this one number, so that the camp slides south when the rakeable square
	grows and the volcano at the north end never moves. The egg row below stands
	inside that square and has to slide with it.

	It is the field's south edge plus 160, which is 0 at the 80-grid the layout
	was drawn for. Read from Config rather than copied, because a number that
	lives in two files is a number that will be changed in one of them.
]]
local ASHFALL_CAMP = 0
-- Penguin Island's camp datum, the identical arithmetic: Island5Builder lays
-- its landing out against the same shipped-at-80 layout Ashfall's does, so the
-- egg row sits 280 south of `cz - half + 160` there too.
local PENGUIN_CAMP = 0
do
	local ok, CTBConfig = pcall(function()
		return require(game:GetService("ReplicatedStorage"):WaitForChild("CTB"):WaitForChild("Config"))
	end)
	if ok and type(CTBConfig) == "table" then
		local ash = CTBConfig.island and CTBConfig.island(5)
		if ash then
			ASHFALL_CAMP = ash.cz - ash.half + 160
		end
		local pen = CTBConfig.ISLANDS and CTBConfig.ISLANDS[8]
		if pen then
			PENGUIN_CAMP = pen.cz - pen.half + 160
		end
	end
end

PetConfig.StationOverrides = {
	--[[
		THE BEACH IS THE ONE ISLAND WHERE THE EGG STANDS IN THE SERVICE ROW, and
		it is a deliberate exception to the plan above rather than a miss.

		It used to sit north of the promenade at (40, -137) facing south across it,
		which is the pattern every other precinct keeps. On a starter island it
		read as a mistake instead of a plan: one booth alone on the far side of the
		sidewalk, opposite a row of five frontages, with nothing else on its flank
		to make the second rank legible as a rank. The other islands each have two
		to four booths, which is enough to read as a row of its own.

		So it joins the row at its east end, past the Long Shore: x 87.5 puts the
		roof at 80.7..94.3, which is the 6.50-stud gap every other frontage keeps
		(the Long Shore's ridge ends at 74.2), and z -168.6 lands the canopy front
		on -161.8 with the rest of them. yaw 0 so it faces +Z at the beach, the way
		the whole row does.
	]]
	[1] = { row = { x = 87.5, z = -168.6, yaw = 0 }, eggs = { "Basic" } },

	-- The WEST flank of the market street, SET BACK off it. At x 1476 the booth
	-- fronts landed on x 1483 -- six studs INSIDE the street's own paving (which
	-- runs x 1477..1523), so the row stood in the road rather than beside it.
	-- x 1464 puts the fronts on 1471 and leaves a forecourt: the Forecourt model
	-- in the Market carries the apron under them out to the paving's west edge,
	-- and the dune decor stands behind them on the sand at x < 1450.
	[2] = { row = { x = 1464, z = -144, yaw = 90 }, eggs = { "Basic", "Desert" } },

	-- The tomb. See THE VAULT GETS NO PLAZA above.
	[3] = { plaza = false },

	-- The EAST flank of the sando: the whole right-hand side of the walk is this
	-- one row and nothing else, every booth turned to face it. The shrine owns
	-- the west flank and does not move, so this is the one precinct where the
	-- eggs take the right-hand side.
	--
	-- x 30 rather than 34 brings the fronts onto x 23, seven studs off the sando
	-- edge -- a shopfront on a pavement instead of a plaza set back behind one.
	-- It cannot come further in than that: the market gate is 44 across, so its
	-- east post ends at x 22.
	--
	-- z 1348 is the middle of the LENGTHENED walk. The sando used to stop at
	-- z 1330 and the paving with it, which gave three booths 64 studs to stand
	-- in and left them shouldering the gate at one end and the north kerb at the
	-- other. Both now run to z 1310 -- south, to the outer torii, because north
	-- is the rakeable field and its size is not up for negotiation.
	[4] = { row = { x = 30, z = 1348, yaw = -90 }, eggs = { "Basic", "Desert", "Prestige" } },

	-- The WEST flank of the Cinder Road, INSIDE the camp square -- the left
	-- hand walking in from the pier, and empty since the weighhouse crossed to
	-- the east with the other services. Fronts face east; the row spans
	-- z -248..-312, clear of both kerbs and of the tents on the flank behind it.
	--
	-- SEVEN STUDS OFF THE ROAD EDGE, not twenty. This entry said "~20 studs of
	-- paving to the road edge at x -2213" and meant it: at x -2240 the deepest
	-- booth (Celestial, 16.4 through) put its front on -2231.8, nineteen studs
	-- back, with ninety more studs of empty flank behind it. It read as four sheds
	-- parked on a plaza rather than as the shopfront the cove's row at x 30 is --
	-- and the cove's own note above says exactly why seven is the number.
	--
	-- x -2228 brings the fronts onto -2219.8. It cannot come in much further: the
	-- Cinder Road is the one piece of paving on that island nothing may stand on,
	-- and its west edge is -2213.
	--
	-- ISLAND4BUILDER DRAWS THE APRON UNDER THIS ROW AND IT READS THIS NUMBER OFF
	-- THIS NOTE, not off the config -- PetStationBuilder parents the row into
	-- Workspace.PetStations, so the ground it stands on has to be laid by the
	-- island. Its EggForecourt is quoted as CX-28, which IS this x. Move one and
	-- move the other; see the block comment on it, which points back here.
	--
	-- THE Z IS DERIVED, AND IT HAS TO BE. Ashfall's rakeable square is the one in
	-- this game that grows southward: Island4Builder takes all of a size change
	-- out of the south side so the volcano -- and the stair, the streams, the
	-- caldera and the Magma Chamber's door on it -- never has to move. The camp
	-- goes with it, and this row stands INSIDE the camp, so a typed -280 stops
	-- being the west flank of the Cinder Road the moment the field changes size
	-- and becomes a shed standing in the middle of the sand.
	--
	-- ASHFALL_CAMP is that island's camp datum -- the z its whole layout is
	-- written against -- and -280 is this row's offset along it, unchanged.
	[5] = { row = { x = -2228, z = ASHFALL_CAMP - 280, yaw = 90 }, eggs = { "Basic", "Desert", "Prestige", "Celestial" } },
	--[[
		The inner shrine, and it is THE VAULT'S CASE EXACTLY -- see the note above.

		An interior room with crust = false, poured at runtime, whose default
		plaza position twenty studs beyond its own field edge has nothing under
		it: the hall's floor is only written out to CX/CZ +- 128 and the shed
		would stand in the void past the wall. It also has no walk to stand
		beside and no service row to be the opposite flank of, which is what the
		row frames above are for.

		Caught the first time this island booted -- "Inner Shrine (4)" in the
		plaza log, 83 parts at y 12.3 inside a sealed hall.
	]]
	[6] = { plaza = false },
	--[[
		The magma chamber, and it is the SAME CASE AGAIN -- the third interior,
		the third opt-out.

		One difference worth writing down, because it makes the usual test the
		wrong test: this room runs crust = TRUE, unlike the vault and the
		shrine, so "interiors are the crustless ones" no longer identifies them.
		What actually disqualifies a plaza is that the room is SEALED and its
		floor stops at the wall. MagmaBuilder writes terrain out to CX/CZ +-
		148/172 and the shell stands inside that, so a shed at the default plaza
		offset would be in the void past the rock -- and there is no walk for it
		to stand beside and no service row for it to flank.
	]]
	[7] = { plaza = false },

	-- Penguin Island: the whole shelf plus the Arctic Egg, on the west flank of
	-- the landing exactly where Ashfall's row stands (x = CX - 28, yaw 90 -- the
	-- row runs along -Z and every booth opens east onto the walk). Five booths
	-- pitch off the Arctic tube, the widest, so Island5Builder gives the row
	-- 110 studs of flank.
	[8] = { row = { x = -28, z = PENGUIN_CAMP - 280, yaw = 90 },
		eggs = { "Basic", "Desert", "Prestige", "Celestial", "Arctic" } },

	-- The Frozen Wreck is a hold, not a shore. See [7].
	[9] = { plaza = false },

}

--[[
	The shelves standing on one island, in shelf order, as egg definitions.

	Named keys are validated against the catalogue rather than trusted: a typo in
	the table above would otherwise drop a shelf silently, which is exactly the
	failure the note on StationOverrides is about.
]]
function PetConfig.eggsForIsland(islandId: number)
	local row = PetConfig.StationOverrides[islandId]
	-- Opted out entirely. Returns empty, which the builder reads as "tear down
	-- anything standing here" rather than as "use the default".
	if row and row.plaza == false then
		return {}
	end
	local keys = row and row.eggs
	if type(keys) ~= "table" then
		return PetConfig.Eggs
	end
	local list = {}
	for _, key in ipairs(keys) do
		local egg = PetConfig.EggByKey[key]
		if egg then
			table.insert(list, egg)
		else
			warn(string.format("[PetConfig] island %d names an egg that does not exist: %s",
				islandId, tostring(key)))
		end
	end
	-- Never an empty plaza. A row that resolved to nothing is a typo, not a
	-- design, and a station-less island is harder to notice than a wrong one.
	if #list == 0 then
		return PetConfig.Eggs
	end
	table.sort(list, function(a, b)
		return (a.index or 0) < (b.index or 0)
	end)
	return list
end

-- How far beyond the rakeable field's edge the plaza stands. Outside it on
-- purpose: anything inside is standing on terrain the player rakes flat.
PetConfig.StationSetback = 20

-- Studs between the three pedestals.
PetConfig.StationSpacing = 11

return PetConfig
