-- Clean the Beach :: shared tuning + terrain field maths
--
-- The beach is real Roblox Terrain. The rakeable field is a grid of 4-stud
-- columns (4 studs is the terrain voxel resolution, so one cell == one column).
-- Raking a column drops its surface from a noisy "messy" height down to dead
-- flat and swaps its material from Sand to Limestone.
--
-- Each column owns the vertical band y = -8 .. 8, which is four voxels:
--   [-8,-4)  always solid sand
--   [-4, 0)  always solid, carries the surface material when the column is clean
--   [ 0, 4)  the variable one: occupancy sets how high the messy sand piles up
--   [ 4, 8)  always air
-- So a clean column's surface sits exactly at y = 0 and a messy one bulges above it.

local Config = {}

Config.SEED = 20250818

Config.VOXEL = 4                       -- terrain resolution; don't change
Config.TILE  = 4

----------------------------------------------------------------
-- The islands
----------------------------------------------------------------
-- Every rakeable field in the game is a row in this table. A field is a square
-- grid of 4-stud columns centred on (cx, cz) in world space; which columns
-- exist, where they sit, what they are made of and how much junk is buried in
-- them are all read from here. Adding an island is adding a row -- the server's
-- grids, the client's terrain writes and the litter scatter all iterate it.
--
-- ONE CONSTRAINT WORTH KNOWING. Terrain material colours are GLOBAL:
-- Terrain:SetMaterialColor tints a material everywhere in the world at once, so
-- two islands cannot share a material pair and still have different palettes.
-- That is why the desert rakes Sandstone -> Salt rather than reusing the
-- beach's Sand -> Snow. The pair carries the island's COLOUR, not just its
-- texture, and picking an unused pair is what buys a second palette.
--
-- Both members of a pair still want the same tint as each other (see applyLook):
-- raking is meant to read as the same ground going smooth, not as a paler layer
-- being uncovered.
Config.ISLANDS = {
	{
		id = 1,
		name = "Beach",
		-- Sized for a server, not for one player. This was 32x32 (128 studs across,
		-- 1024 cells); at 64x64 it is 256 studs across and 4096 cells, so four
		-- people can work separate stretches without combing each other's sand.
		grid = 64,
		cx = 0, cz = 0,

		-- Raking swaps the terrain material, not its colour: Sand is rippled and
		-- grainy, Snow is the flattest, most featureless surface Roblox terrain
		-- has. Both are tinted to the SAME sand colour in applyLook, so what
		-- changes underneath the roller is purely texture.
		--
		-- Snow was picked by eye off a side-by-side of eight candidates. Limestone
		-- was the earlier choice and is only slightly smoother than Sand, which is
		-- why the texture-only version read as nothing at first.
		matMessy = Enum.Material.Sand,
		matClean = Enum.Material.Snow,

		-- Raked sand settles at the MIDDLE of the messy range, not the bottom.
		-- Levelling a bumpy surface reads as smoothing; dropping it below every
		-- bump reads as digging a trench, which is what the first terrain pass got
		-- wrong. 3.0 is also the height of the beach outside the field, so a raked
		-- strip is flush with it rather than sunk into it.
		cleanY = 3.0,

		-- Real trash props (ReplicatedStorage.CTB.Litter) rather than tinted blobs,
		-- so the beach can carry more of them before it reads as noise. This is a
		-- PER-CELL chance: 0.15 across 4096 cells lands near 600 props -- dense
		-- enough that any sweep uncovers something, without putting a four-figure
		-- part count on a phone.
		litterChance = 0.15,
		itemChance = 0.05,     -- ~200 finds buried, so a bag fills in ~10s at Lv.1

		-- Which folder under ReplicatedStorage.CTB the loose props are cloned from.
		-- A field's junk is what it is ABOUT, so it belongs on the row rather than
		-- being one global set every island has to share.
		litterSet = "Litter",

		-- How often a find comes up ENCASED. A multiplier on the spawn weight of
		-- every crusted id in Config.ITEMS, so it rebalances against the loose ones
		-- without anybody having to re-derive the table by hand.
		--
		-- The beach was handing out a lump on 27% of finds -- better than one in
		-- four. Lumps are the money AND the wash bay is the only way to cash one,
		-- so at that rate the bay stopped being a treat and became a queue. 0.25
		-- takes it to roughly 8%, about one lump in twelve.
		--
		-- Per island on purpose: this is the main dial on a field's pacing, and the
		-- beach is the one everybody starts on.
		encasedScale = 0.25,

		-- Dropped from 0.9 when the field went 4x. Clearing 90% of 4096 cells with
		-- a 6-16 stud tool is hours of work, which would have quietly retired the
		-- reset event; 0.75 keeps it reachable on a populated server.
		resetAt = 0.75,
		resetBonus = 250,
		resetName = "TIDE",

		-- How far from the centre still counts as being on this island, for
		-- ambience, colour grading and the travel docks. Generous: it only has to
		-- separate islands that are 1500 studs apart.
		zone = 460,
	},
	{
		id = 2,
		name = "Dunes",
		-- Smaller than the beach on purpose. It is the SECOND field a player owns,
		-- not a replacement, and every cell here is a client-side terrain write and
		-- a possible litter prop on top of the 4096 they already carry. 48x48 is
		-- 192 studs across -- big enough to read as a desert once the dunes ring it,
		-- cheap enough to hold both islands live at once.
		grid = 48,
		cx = 1500, cz = 0,

		-- Sandstone is the grainiest warm material left once Sand is spoken for,
		-- and Salt is the flattest. Same grainy -> smooth story as the beach, in a
		-- palette the beach cannot touch.
		matMessy = Enum.Material.Sandstone,
		matClean = Enum.Material.Salt,

		-- Same height as the beach, which keeps every bit of the surface maths
		-- below shared, and lets the island plateau be filled flush at y = 3.
		cleanY = 3.0,

		-- Slightly less litter per cell than the beach but richer finds: a smaller
		-- field that pays better is what makes it worth the trip.
		litterChance = 0.13,
		itemChance = 0.08,
		litterSet = "Litter",         -- the same washed-up junk; it is still a beach

		-- Left alone at 1.0. The dunes are the trip you make FOR the good stuff,
		-- and keeping the dial on the row is what stops retuning the beach from
		-- quietly retuning every field in the game.
		encasedScale = 1.0,

		-- 2304 cells against the beach's 4096, so the same fraction is a much
		-- shorter job -- hence the bigger payout for finishing it.
		resetAt = 0.75,
		resetBonus = 700,
		resetName = "SANDSTORM",

		zone = 460,
	},
	{
		id = 3,
		name = "Vault",
		-- The treasure chamber under the pyramid. Small and dense rather than big
		-- and sparse: it is a room, not a landscape, and the whole point of it is
		-- that the floor is COVERED. 32x32 is 128 studs across, which is about as
		-- large as an interior can be before the far wall stops reading as a wall.
		--
		-- It sits at (3000, 0) on the same y = 3 plane as the other two fields --
		-- not because anything is above or below it, but because Config.Y_MIN/Y_MAX
		-- and occupancyFor are shared, so every field has to live in the same voxel
		-- band. The room is sealed, so being 1500 studs out in open space never
		-- shows.
		grid = 32,
		cx = 3000, cz = 0,

		-- Another unused pair, for the same palette reason as the desert. Terrain
		-- barely shows in here -- the floor is under a carpet, a dais and several
		-- hundred gold props -- but the pair still has to be its own, or tinting it
		-- would repaint one of the beaches.
		matMessy = Enum.Material.Cobblestone,
		matClean = Enum.Material.Pavement,

		cleanY = 3.0,

		-- Two and a half times the beach's density. "Sweep the gold off the floor"
		-- only lands if the floor is actually buried in it: 0.34 across 1024 cells
		-- is ~350 props in a 128-stud room, which reads as a hoard rather than as
		-- litter someone dropped.
		litterChance = 0.34,
		itemChance = 0.14,
		litterSet = "Treasure",

		-- ZERO, and now belt AND braces: the room draws from Config.TOMB_ITEMS
		-- (see itemPool below the item tables), every id in which is authored
		-- uncrusted, so there is nothing left here for this to scale. It stays at
		-- zero because the requirement below is a correctness one and should not
		-- depend on a second file staying tagged the right way.
		--
		-- Nothing in this room comes up crusted, and that is a correctness
		-- requirement rather than a generosity one.
		--
		-- A crusted lump has no value until it is run through the sifting bay --
		-- which is on the BEACH, two islands and a cinematic away. At 0.5 the bag
		-- reliably jammed solid with lumps the vault's own sell pad would not take
		-- (measured: 18 items, BagValue 0, RollerBlocked stuck true), and with a
		-- full bag the sifter stops entirely -- so the room became unclearable
		-- without leaving it. Zero keeps the loop closed: rake, sell at the
		-- Scales, rake on.
		--
		-- It fits the fiction too. This is dressed treasure laid out in a tomb,
		-- not something that has been rolling around in the surf.
		encasedScale = 0,

		-- Clear it properly, not three quarters of it. A 1024-cell room is a short
		-- job, and the payout at the end is what the whole area is for.
		resetAt = 0.9,
		resetBonus = 5000,
		resetName = "VAULT CLEARED",

		-- Tight: the room is 200 studs across including its walls, and nothing else
		-- is anywhere near it.
		zone = 300,
	},
	{
		id = 4,
		name = "Sakura Cove",
		-- The Dunes' size, and for the Dunes' reason. Every cell is a client-side
		-- terrain write and a possible litter prop ON TOP of the 4096 the beach
		-- already costs -- and that bill never goes away, because the beach is
		-- where everybody spawns. 48x48 (192 studs across, 2304 cells) is the one
		-- field size in this file that has already shipped and been measured as
		-- affordable alongside it, so the third destination takes it rather than
		-- guessing a fourth number.
		grid = 48,

		-- Due north of the beach, the same 1500 studs out that the desert sits
		-- east. Two fields 1500 apart cannot be confused by Config.zoneAt at any
		-- radius this file uses (460 + 460 = 920 < 1500), and taking a fresh axis
		-- leaves the cove's water, its torii and its boardwalks empty space to
		-- spread into instead of crowding the corridor the dunes already occupy.
		cx = 0, cz = 1500,

		-- Its own pair, because a pastel island is a MATERIALS problem and not a
		-- lighting one. Terrain material colours are global (see the note above
		-- this table), so the pink has to be painted onto materials no other
		-- island is using: Sand/Snow/Limestone belong to the beach, Sandstone/
		-- Salt/Rock/Slate to the dunes, Cobblestone/Pavement to the vault. Ground
		-- and Asphalt are the cove's now, place-wide -- nothing else in this game,
		-- terrain or prop, may use either.
		--
		-- THE ORDER IS NOT INTERCHANGEABLE, and it is the one thing to know before
		-- touching this. Asphalt dominates Ground in the terrain blend, so a pale
		-- Asphalt cell reads clearly inside a Ground field while a Ground cell
		-- inside an Asphalt field is invisible -- tested in both brightness
		-- directions and it fails both ways round. Ground earns the messy slot on
		-- its own merits too: a fine mottled speckle, which is a good untouched-
		-- sand read.
		--
		-- Several materials that look like obvious candidates are dead ends, and
		-- were measured as such rather than guessed at. Glacier, Grass and Basalt
		-- are swallowed by whatever surrounds them whenever they are the MINORITY
		-- material -- which is exactly what a raked cell is. Concrete renders a
		-- full stud low, Brick and WoodPlanks a full stud proud and Ice bumpy, all
		-- of which break the equal-height rule below. Do not re-pick this pair.
		matMessy = Enum.Material.Ground,
		matClean = Enum.Material.Asphalt,

		-- 3.0, and it is not a free number to change. Config.Y_MIN/Y_MAX,
		-- SURFACE_BASE and occupancyFor are shared by every field, so all four
		-- live in the same four-voxel band -- and Config.surfaceY hands this one
		-- height back for the MESSY state as well as the raked one, which is what
		-- lets raked progress be per player: each client redraws its own columns
		-- into its own copy of the terrain, so the geometry has to be identical or
		-- everyone else's avatar floats or sinks. Whatever Island3Builder fills
		-- the cove's plateau to has to land flush with this.
		cleanY = 3.0,

		-- The dunes' litter density with a step up in finds, on the dunes' logic:
		-- a field a quarter of the beach's size has to pay better per cell to be
		-- worth the crossing, and this is the one that asks for Lv.5 -- so it
		-- takes the same step past the dunes (0.08) that the dunes took past the
		-- beach (0.05).
		litterChance = 0.13,
		itemChance = 0.09,
		litterSet = "Litter",         -- the same washed-up junk; it is still a beach

		-- Left at 1.0 like the dunes. Lumps are only a trap where the way to the
		-- wash bay is closed, which is what forced the vault to zero; the cove's
		-- gate home is deliberately never locked, so a bagful of crust out here is
		-- a trip back rather than a soft-lock.
		encasedScale = 1.0,

		-- Same 2304 cells and the same 0.75 as the dunes, so finishing it is
		-- exactly the same job -- 1728 columns. The premium over the dunes' 700 is
		-- for the GATE and not for the labour: this is the field you need Lv.5 to
		-- stand on, and it should out-earn the one that asked for Lv.3. It stays
		-- nowhere near the vault's 5000, which pays for a 1024-cell room cleared
		-- to 0.9 out of an entirely different item pool.
		resetAt = 0.75,
		resetBonus = 900,
		resetName = "HANAMI",

		-- The beaches' radius, unchanged, and it has to be this generous: almost
		-- everything that makes this place read as the cove -- the torii out in
		-- the water, the boardwalks, the arrival gate on the south shore -- stands
		-- OUTSIDE the 96-stud rakeable square, and all of it should still count as
		-- being in the cove for ambience and the colour grade.
		zone = 460,
	},
}

-- Derived, so no row has to keep two numbers in step by hand.
for _, isl in ipairs(Config.ISLANDS) do
	isl.half = isl.grid * Config.TILE * 0.5
	isl.cells = isl.grid * isl.grid
	isl.x0 = isl.cx - isl.half       -- world X of the field's low edge
	isl.z0 = isl.cz - isl.half
end

Config.HOME = Config.ISLANDS[1]

-- Back-compat aliases. Plenty of code outside this module still says GRID/CELLS
-- meaning "the beach", and there is no value in churning it.
Config.GRID  = Config.HOME.grid
Config.HALF  = Config.HOME.half
Config.CELLS = Config.HOME.cells

Config.Y_MIN = -8
Config.Y_MAX = 8

-- The black-screen transition into and out of the vault.
--
-- Shared numbers, NOT a handshake. The server teleports on its own clock and
-- Vault_Client fades on its own; if the two agreed by message passing, one
-- dropped packet would leave somebody sitting in front of a black screen with
-- no way out. Reading the same constants means the worst case is a fade that
-- lands slightly early.
--   beat  how long the player watches the door before the cut. NOT dead time:
--         the client spends it closing the camera on the doorway, narrowing the
--         frame, ramping a shake and climbing a howl underneath. 1.5 was enough
--         for a dissolve and too short to build anything, so it is 2.0.
--   fade  the cut. Down from 0.9 because it is no longer a dissolve -- one
--         frame of gold, then black behind it -- and 0.9 of that is a wince.
--         The teleport still happens exactly as it completes.
--   hold  black time after the teleport, for the destination to stream in. Up a
--         little: the reveal opens ON the room, so it has to be there.
Config.CINEMA = { beat = 2.0, fade = 0.7, hold = 0.6 }

-- Materials, heights and litter density all live on the island rows above now.
-- These three are kept because other scripts still read them for the beach.
Config.MAT_MESSY = Config.HOME.matMessy
Config.MAT_CLEAN = Config.HOME.matClean
Config.CLEAN_Y   = Config.HOME.cleanY

--[[
	ON. Raking rewrites the ground under the tool.

	Each raked column's terrain MATERIAL is swapped -- Sand -> Snow on the beach,
	Sandstone -> Salt in the dunes -- at an identical surface height. Grainy sand
	going smooth: that is the whole "sand erasing" look, and it is the one piece
	of feedback that marks WHERE YOU HAVE BEEN rather than just flashing when you
	pass. Particles say "something happened here a second ago"; only the ground
	itself can still be saying it a minute later.

	WHY IT WAS OFF, AND WHY IT WORKS NOW
	------------------------------------
	It was switched off because it read as nothing -- and it genuinely did, but
	the materials were never the problem. CTB_Server was painting Snow the EXACT
	same colour as Sand (both 211,188,118), so the swap changed the surface grain
	and nothing else, which at gameplay distance and a low sun is close to
	invisible. Same for Salt against Sandstone in the dunes. The clean materials
	now carry their own paler tone, so the raked strip differs in colour AND in
	texture. See applyLook in CTB_Server -- the two must be edited together, and
	if the raked ground ever stops reading again, check the COLOURS before
	reaching for the materials.

	WHY THE HEIGHT IS IDENTICAL AND MUST STAY THAT WAY: raked progress is per
	player, and each client writes its own raked columns into its own copy of the
	terrain. Different heights would put every player on a slightly different
	surface and everyone else's avatar would float or sink by up to a stud. Only
	the MATERIAL may be private. See Config.surfaceY.

	NOTHING MECHANICAL RIDES ON THIS. The flag is only read at the two places in
	CTB_Client that write voxels; the client's own record of which columns it has
	raked is set BEFORE that check, and the server's grid, the finds, the raked
	percentage and the tide are all untouched. Set it false and the game still
	plays identically, just without the trail.
]]
Config.TERRAIN_DEFORMS = true

-- Scattered bump parts on the messy sand. Zero: at any size big enough to see
-- they read as pebbles strewn on the beach rather than as rough sand.
Config.MARKS_PER_CELL = 0
Config.LITTER_CHANCE = Config.HOME.litterChance

----------------------------------------------------------------
-- The sifter
--
-- The keys keep their ROLLER_ names on purpose. The player attributes they feed
-- (RollerWidth, RollerLevel) are read by the weight system, the progression
-- tracks and both HUDs, so renaming them is a far bigger change than replacing
-- the tool itself was.
----------------------------------------------------------------
Config.ROLLER_DIST   = 4.6             -- studs in front of the player
Config.ROLLER_RADIUS = 0.55            -- wheel radius, and so the ride height
Config.ROLLER_DEPTH  = 3.0             -- front-to-back bite of the basket

-- The width the tool sweeps AND the width it is drawn at -- one number for both,
-- so what gets cleaned is always exactly what the player can see touching sand.
--
-- The old ladder ran 16 -> 64 studs. 64 is half the width of the entire beach
-- and roughly thirty times a player's shoulders; even the starting 16 was eight
-- times. This one starts at a believable hand tool and tops out at what the old
-- one started at.
--
-- The trade is real and deliberate. Terrain columns are 4 studs, so a pass now
-- clears one or two of them instead of four to sixteen: the whole field takes
-- roughly four times as long to clear at max level and the tide turns less
-- often. Raise these if that pacing is too slow -- and raise the matching table
-- in Modules.ProgressionConfig with them, because that is what actually writes
-- the RollerWidth attribute at runtime.
Config.LEVELS = {
	{ width = 6,  cost = 0    },
	{ width = 8,  cost = 70   },
	{ width = 10, cost = 180  },
	{ width = 12, cost = 380  },
	{ width = 14, cost = 750  },
	{ width = 16, cost = 1400 },
}

----------------------------------------------------------------
-- Bag / economy
----------------------------------------------------------------
Config.BAG_MAX     = 10
Config.ITEM_CHANCE = Config.HOME.itemChance
Config.TIDE_AT     = Config.HOME.resetAt
Config.TIDE_BONUS  = Config.HOME.resetBonus

Config.ITEMS = {
	{ id = "Can",     label = "Soda Can",   value = 6,  weight = 24, color = Color3.fromRGB(214, 68, 58),  icon = "\u{1F964}" },
	{ id = "Bottle",  label = "Bottle",     value = 9,  weight = 22, color = Color3.fromRGB(126, 205, 158), icon = "\u{1F376}" },
	{ id = "Shell",   label = "Seashell",   value = 13, weight = 16, color = Color3.fromRGB(248, 206, 196), icon = "\u{1F41A}" },
	{ id = "Coin",    label = "Lost Coin",  value = 19, weight = 13, color = Color3.fromRGB(255, 196, 60),  icon = "\u{1FA99}" },
	{ id = "Glasses", label = "Sunglasses", value = 30, weight = 11, color = Color3.fromRGB(46, 46, 56),    icon = "\u{1F576}" },
	{ id = "Watch",   label = "Gold Watch", value = 55, weight = 8,  color = Color3.fromRGB(244, 204, 92),  icon = "\u{231A}" },
	{ id = "Phone",   label = "Lost Phone", value = 95, weight = 6,  color = Color3.fromRGB(44, 48, 64),    icon = "\u{1F4F1}" },
}
Config.RARE_VALUE = 30

----------------------------------------------------------------
-- THE TOMB'S OWN POOL
--
-- The treasure chamber does NOT draw from the table above, and this is the
-- single biggest thing wrong with it before now: sweeping a sealed pharaoh's
-- tomb turned up soda cans, plastic bottles and the occasional pair of
-- sunglasses. Worse than it sounds, too -- island 3 runs encasedScale = 0,
-- which strips every crusted id out of the draw, so those four were LITERALLY
-- all the room could produce. The player crossed two islands and a locked door
-- to rake up litter worth six.
--
-- These ids live in Modules.ItemConfig tagged TOMB: Rare through Mythic, never
-- crusted (so the Scales in the room can actually pay for them), and
-- unreachable from any beach or from ItemConfig.rollItemId.
--
-- THE ONLY NUMBERS THIS TABLE OWNS ARE THE PICK WEIGHTS. Value, tier and
-- display name are read off that catalogue below rather than written again
-- here -- a second hand-kept copy of a price is exactly the drift the `encased`
-- note further down exists to avoid, and these prices are derived there
-- (4 * OneIn^0.62) by a rule nobody should be re-typing by hand.
--
-- The weights run roughly as 1/OneIn so the ladder still feels like a ladder,
-- flattened at the top so the best three pieces are an event rather than a
-- rounding error. That works out around 140 a find against the beach's 15 --
-- which is the whole point of a room you need two rebirths to stand in. Turn
-- the top weights down if the tomb ever starts paying for everything at once;
-- they are the dial, and nothing else here has to move with them.
--
-- No `icon` column: nothing reads Config.ITEMS' icons, and Roblox's font has no
-- fallback for newer emoji (see MenuHud's TRACK_EMOJI note), so authoring
-- thirteen unread glyphs is thirteen chances to ship a row of boxes.
----------------------------------------------------------------
Config.TOMB_ITEMS = {
	{ id = "FaienceBead",    weight = 34,  color = Color3.fromRGB(74, 168, 190) },
	{ id = "ClayUshabti",    weight = 26,  color = Color3.fromRGB(198, 150, 96) },
	{ id = "BronzeAnkh",     weight = 20,  color = Color3.fromRGB(150, 166, 110) },
	{ id = "ScarabSeal",     weight = 15,  color = Color3.fromRGB(40, 78, 150) },
	{ id = "AlabasterJar",   weight = 11,  color = Color3.fromRGB(238, 226, 204) },
	{ id = "GoldenAnkh",     weight = 8,   color = Color3.fromRGB(255, 206, 84) },
	{ id = "CanopicJar",     weight = 6,   color = Color3.fromRGB(226, 196, 140) },
	{ id = "EyeOfHorus",     weight = 4,   color = Color3.fromRGB(255, 214, 110) },
	{ id = "PectoralCollar", weight = 3,   color = Color3.fromRGB(246, 202, 90) },
	{ id = "SolarDisc",      weight = 2,   color = Color3.fromRGB(255, 198, 60) },
	{ id = "PharaohMask",    weight = 1.2, color = Color3.fromRGB(255, 208, 72) },
	{ id = "SunKingScepter", weight = 0.6, color = Color3.fromRGB(255, 220, 104) },
	{ id = "SunKingCrown",   weight = 0.2, color = Color3.fromRGB(255, 226, 132) },
}

-- The vault draws from it. Set on the row rather than special-cased in
-- pickItem, so "which items does this field turn up" stays one field on one
-- table beside every other thing that makes a field what it is.
Config.ISLANDS[3].itemPool = Config.TOMB_ITEMS

local byId, totalWeight = {}, 0
for _, it in ipairs(Config.ITEMS) do
	byId[it.id] = it
	totalWeight += it.weight
end

-- Forward-declared: it needs the lazy catalogue handle further down, and these
-- two lookups need it. Not a global -- a stray global in a shared module is one
-- typo away from being someone else's.
local resolveTomb

-- Both go through resolveTomb (below) so a vault find is a known item to every
-- caller -- CTB_Client's pop effect reads `def.color` and `def.value` off this
-- and bails out entirely on an id it does not recognise, which would have made
-- every treasure come out of the floor in total silence.
function Config.item(id)
	resolveTomb()
	return byId[id]
end

function Config.value(id)
	resolveTomb()
	local it = byId[id]
	return it and it.value or 0
end

-- WHICH IDS COME UP AS LUMPS IS NOT DECIDED HERE.
--
-- Modules.ItemConfig owns the Encased flag and this table is documented as
-- mirroring it, so a second hand-kept list of "the crusted ones" in this file is
-- exactly the drift both files warn about. It would already be wrong, too: Coin
-- is encased now and Glasses is not, which is not what either name suggests.
--
-- Resolved once, lazily -- the flag is read at spawn time, long after both
-- modules are loaded -- and a place without Modules.ItemConfig simply gets no
-- scaling rather than an error.
-- One lazy handle on the catalogue, shared by `encased` and `resolveTomb`.
local catalogue, catalogueTried
local function itemCatalogue()
	if catalogueTried then
		return catalogue
	end
	catalogueTried = true
	local modules = game:GetService("ReplicatedStorage"):FindFirstChild("Modules")
	local moduleScript = modules and modules:FindFirstChild("ItemConfig")
	if moduleScript and moduleScript:IsA("ModuleScript") then
		local ok, mod = pcall(require, moduleScript)
		if ok and type(mod) == "table" and type(mod.isEncased) == "function" then
			catalogue = mod
		end
	end
	if not catalogue then
		warn("[CTB] ItemConfig would not load; item prices and encasedScale fall back")
	end
	return catalogue
end

-- Names and prices for the tomb pool, filled in from the catalogue on first ask
-- for the same reason `encased` is lazy: a place without Modules.ItemConfig has
-- to still load, and it does -- it just gets the id as the name and a floor
-- price, rather than an error three lines into a rake.
local tombResolved = false
function resolveTomb()   -- forward-declared above
	if tombResolved then
		return
	end
	tombResolved = true
	local ItemConfig = itemCatalogue()
	for _, it in ipairs(Config.TOMB_ITEMS) do
		local def = ItemConfig and ItemConfig.get(it.id)
		if def then
			it.label = def.DisplayName
			-- The midpoint of the roll band. Only ever a DISPLAY figure -- what a
			-- find is actually worth is rolled once, by ValueCalculator, on the
			-- server, and nothing here is allowed to be a second opinion on it.
			it.value = math.floor((def.ValueRange[1] + def.ValueRange[2]) * 0.5 + 0.5)
		else
			warn(string.format("[CTB] tomb item %q is not in ItemConfig", tostring(it.id)))
			it.label = it.id
			it.value = Config.RARE_VALUE
		end
		byId[it.id] = it
	end
end

local encasedById
local function encased(id: string): boolean
	if not encasedById then
		encasedById = {}
		local ItemConfig = itemCatalogue()
		if ItemConfig then
			for _, pool in ipairs({ Config.ITEMS, Config.TOMB_ITEMS }) do
				for _, it in ipairs(pool) do
					encasedById[it.id] = ItemConfig.isEncased(it.id) and true or false
				end
			end
		end
	end
	return encasedById[id] == true
end

-- Which table a field draws from. Everything without its own pool draws from
-- the shared litter -- which is every beach, and is what any caller predating
-- the vault expects.
local function poolFor(isl)
	return isl.itemPool or Config.ITEMS
end

-- One island's scaled weight table, built on first use and kept on the row.
local function weightsFor(isl)
	if isl.pickWeights then
		return isl.pickWeights, isl.pickTotal
	end
	local pool = poolFor(isl)
	local scale = (type(isl.encasedScale) == "number") and math.max(0, isl.encasedScale) or 1
	local weights, total = table.create(#pool), 0
	for i, it in ipairs(pool) do
		local w = encased(it.id) and it.weight * scale or it.weight
		weights[i] = w
		total += w
	end
	isl.pickWeights, isl.pickTotal = weights, total
	return weights, total
end

-- `isl` is optional. Without it the table is used exactly as written, which is
-- what any caller predating per-island rarity expects.
function Config.pickItem(rng: Random, isl): string
	if not isl then
		local roll = rng:NextNumber() * totalWeight
		for _, it in ipairs(Config.ITEMS) do
			roll -= it.weight
			if roll <= 0 then return it.id end
		end
		return Config.ITEMS[1].id
	end

	local pool = poolFor(isl)
	local weights, total = weightsFor(isl)
	if total <= 0 then
		return pool[1].id
	end
	local roll = rng:NextNumber() * total
	for i, it in ipairs(pool) do
		roll -= weights[i]
		if roll <= 0 then return it.id end
	end
	return pool[1].id
end

----------------------------------------------------------------
-- Grid maths (1-based flat index; ix/iz are 0-based column coords)
----------------------------------------------------------------
-- A cell index is only meaningful together with the island it belongs to --
-- index 1 exists on every island -- so every one of these takes the island row
-- as its first argument. Anything that stores or sends an index has to carry the
-- island id beside it, which is why the network messages below do.
-- Islands are stored in id order, so this is a plain lookup -- but going through
-- a function means the network handlers read `Config.island(id)` and fail loudly
-- on an id that does not exist, rather than indexing nil three lines later.
function Config.island(id: number)
	local isl = Config.ISLANDS[id]
	if not isl then
		error(string.format("[CTB] no island with id %s", tostring(id)), 2)
	end
	return isl
end

function Config.index(isl, ix: number, iz: number): number
	return iz * isl.grid + ix + 1
end

function Config.coords(isl, index: number): (number, number)
	local i = index - 1
	return i % isl.grid, i // isl.grid
end

function Config.cellCentre(isl, ix: number, iz: number): Vector3
	return Vector3.new(
		isl.x0 + (ix + 0.5) * Config.TILE,
		0,
		isl.z0 + (iz + 0.5) * Config.TILE
	)
end

function Config.centreOf(isl, index: number): Vector3
	local ix, iz = Config.coords(isl, index)
	return Config.cellCentre(isl, ix, iz)
end

-- The island whose rakeable FIELD this point stands on, or nil between them.
-- This is what the sifter asks: it decides which grid a sweep is allowed to
-- rake, so it deliberately stops at the field edge rather than the island edge.
function Config.fieldAt(pos: Vector3)
	for _, isl in ipairs(Config.ISLANDS) do
		if math.abs(pos.X - isl.cx) <= isl.half and math.abs(pos.Z - isl.cz) <= isl.half then
			return isl
		end
	end
	return nil
end

-- The island this point is anywhere NEAR -- dunes, docks, pyramid and all.
-- Ambience, colour grading and the travel docks use this, because standing in
-- the shade of the pyramid should still feel like being on the desert island
-- even though it is well outside the rakeable square.
function Config.zoneAt(pos: Vector3)
	for _, isl in ipairs(Config.ISLANDS) do
		local dx, dz = pos.X - isl.cx, pos.Z - isl.cz
		if dx * dx + dz * dz <= isl.zone * isl.zone then
			return isl
		end
	end
	return nil
end

----------------------------------------------------------------
-- Surface heights
----------------------------------------------------------------

-- Occupancy of the y 0..4 voxel. Surface height above y=0 is roughly 4 * occupancy.
-- Two octaves of noise so the mess rolls like real disturbed sand instead of
-- flickering cell to cell, and so every client agrees without any replication.
-- Messy surface height in world Y, swinging either side of CLEAN_Y. Mostly
-- high-frequency noise so neighbouring columns disagree and the surface reads as
-- churned up rather than as smooth dunes. Terrain smoothing averages neighbours
-- and eats roughly 40% of the written range, so this is wider than it looks.
-- The ground is dead flat in both states; raking changes the MATERIAL only,
-- Sand -> Snow, which is what the player reads as grainy sand going smooth.
--
-- Keeping the height identical is also what makes the sand keep up with the
-- roller. When the two states differed, every write rebuilt terrain geometry and
-- had to be throttled to stay playable, which left the sand visibly lagging a
-- couple of studs behind the drum. Same-height writes only swap material, so
-- they are cheap enough to do every tick with no lag at all.
function Config.messyY(isl): number
	return isl.cleanY
end

-- Split a target surface height across the two variable voxels. Below
-- SURFACE_BASE the [-4,0) voxel goes partial; above it that one is full and
-- [0,4) carries the remainder.
function Config.occupancyFor(h: number): (number, number)
	if h >= Config.SURFACE_BASE then
		return 1, math.clamp((h - Config.SURFACE_BASE) / Config.VOXEL, 0, 1)
	end
	return math.clamp((h - Config.SURFACE_BASE + Config.VOXEL) / Config.VOXEL, 0, 1), 0
end

-- Smooth terrain puts its surface at the CENTRE of the first non-full voxel, not
-- at the top of the last full one, so an occupancy of 0 still renders 2 studs up.
-- Measured directly: surfaceY = 2.0 + 4 * occupancy, dead linear.
Config.SURFACE_BASE = 2

-- ONE height for both states, deliberately.
--
-- Raked progress is per player now (see the grid-state block in CTB_Server) and
-- each client draws its own raked columns into its own copy of the terrain. If
-- messy and raked columns had different heights, every player would be standing
-- on a slightly different surface and everyone else's avatar would float or sink
-- by up to a stud. Holding the GEOMETRY identical means only the MATERIAL is
-- private -- which is the difference the look was already built on: grainy Sand
-- becoming smooth Snow at the same level.
--
-- The height variation this gives up was doing very little anyway. At ~1.2 studs
-- across 4-stud voxels it is roughly a 17 degree slope, too shallow to shade
-- itself at any sun angle (measured -- see the latitude note in CTB_Server's
-- applyLook). messyY is kept for anyone who wants a taller, bumpier field on a
-- single-player variant, where per-client terrain is not a constraint.
function Config.surfaceY(isl): number
	return isl.cleanY
end

----------------------------------------------------------------
-- Terrain writing (server + edit-time only)
----------------------------------------------------------------
local AIR = Enum.Material.Air

-- Rewrites every column in the given inclusive cell range. `isClean(index)`
-- decides which state each column is written in.
function Config.writeField(terrain: Terrain, isl, minCx: number, maxCx: number, minCz: number, maxCz: number, isClean)
	minCx = math.max(0, minCx)
	minCz = math.max(0, minCz)
	maxCx = math.min(isl.grid - 1, maxCx)
	maxCz = math.min(isl.grid - 1, maxCz)
	if minCx > maxCx or minCz > maxCz then return end

	local nx = maxCx - minCx + 1
	local nz = maxCz - minCz + 1
	local x0 = isl.x0 + minCx * Config.TILE
	local z0 = isl.z0 + minCz * Config.TILE
	local region = Region3.new(
		Vector3.new(x0, Config.Y_MIN, z0),
		Vector3.new(x0 + nx * Config.TILE, Config.Y_MAX, z0 + nz * Config.TILE)
	)

	local mats, occs = table.create(nx), table.create(nx)
	for xi = 1, nx do
		local mx, ox = table.create(4), table.create(4)
		mats[xi], occs[xi] = mx, ox
		for yi = 1, 4 do
			mx[yi] = table.create(nz)
			ox[yi] = table.create(nz)
		end

		local cx = minCx + xi - 1
		for zi = 1, nz do
			local cz = minCz + zi - 1
			local cleaned = isClean(Config.index(isl, cx, cz))
			local surface = cleaned and isl.matClean or isl.matMessy
			local o2, o3 = Config.occupancyFor(Config.surfaceY(isl))

			mx[1][zi], ox[1][zi] = isl.matMessy, 1
			-- a zero-occupancy voxel must be Air, or WriteVoxels rejects it
			if o2 > 0.001 then
				mx[2][zi], ox[2][zi] = surface, o2
			else
				mx[2][zi], ox[2][zi] = AIR, 0
			end
			if o3 > 0.001 then
				mx[3][zi], ox[3][zi] = surface, o3
			else
				mx[3][zi], ox[3][zi] = AIR, 0
			end
			mx[4][zi], ox[4][zi] = AIR, 0
		end
	end

	terrain:WriteVoxels(region, Config.VOXEL, mats, occs)
end

return Config
