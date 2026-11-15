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
		--
		-- Still true of the TERRAIN, and it has to stay true. What is dug now is a
		-- layer laid over the top of it -- see Config.CRUST -- and the terrain below
		-- that layer never moves.
		cleanY = 3.0,

		-- The beach is dug rather than repainted: a loose sand layer over the field
		-- that the sifter cuts a channel through. See Config.CRUST.
		crust = true,

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
		-- 0.25 WAS TUNED AGAINST A DIFFERENT TABLE and would be badly wrong now.
		--
		-- The seven-row pool this island used to draw from carried 27% of its
		-- weight in crusted ids -- a lump on better than one find in four, which
		-- turned the wash bay from a treat into a queue -- and 0.25 took that to
		-- about 8%. Config.ITEMS is the full forty-one row catalogue now (see the
		-- note on it), and only 7.9% of THAT table's weight is crusted. The same
		-- 0.25 would take the beach to one lump in fifty and starve the bay instead.
		--
		-- 0.90 holds the rate at about 7.4%, near where it has been -- and those
		-- lumps now have Epics, Legendaries and a Mythic above them rather than
		-- topping out at a lost phone.
		--
		-- Per island on purpose: this is the main dial on a field's pacing, and the
		-- beach is the one everybody starts on.
		encasedScale = 0.90,

		--[[
			THE WHOLE FIELD. Not three quarters of it.

			This row read 0.75, on this reasoning: "Dropped from 0.9 when the field
			went 4x. Clearing 90% of 4096 cells with a 6-16 stud tool is hours of
			work, which would have quietly retired the reset event."

			THAT ARITHMETIC IS STALE, and it is the only thing that ever argued for a
			fraction. Config.LEVELS' 6-16 stud ladder is not what anybody rakes with
			any more -- ProgressionServer.applyAll stamps ProgressionConfig's
			RollerWidth track over it on join, after every purchase and on every
			respawn, and that track runs 6 -> 48.5 studs with walk speed going 16 ->
			66 alongside it. Sweeping the whole 256-stud square is about eleven
			minutes at level 1 and under four by level 10, against eight and a half
			at 0.75. The "hours" this comment was defending do not exist.

			What the fraction DID cost was the point of the thing: the tide rolled in
			with a quarter of the beach still under crust, which reads as the sea
			resetting a job you had not finished. It also left the HUD bar -- which is
			raw count/cells, not normalised to this dial -- vanishing with a quarter
			of it still empty. At 1.0 the bar fills exactly as the tide fires.

			SAFE TO SIT AT 1.0 BECAUSE THE FIELD WAS MEASURED, not argued about. All
			4096 cell centres were probed: every one lands on flat dry Sand at
			cleanY, no water, no hole, no step. Of 8,515 BaseParts in the place only
			21 have an XZ box touching this square -- all palm fronds and trunks, all
			CanCollide = false, none intercepting a cell centre. The service row
			(shop, sell pad, wash bay, spawn) sits south of z = -132, outside the
			z = -128 edge, and ServerMain's placement note keeps it there on purpose.

			THE STANDING RULE THIS CREATES: at 0.75 the field tolerated 1024 blocked
			cells. At 1.0 it tolerates NONE -- one solid part parked on one cell and
			this beach never turns over again. Anything new that lands on the square
			has to be gated by clearOfField, and assertClearOfField's boot warning is
			now load-bearing rather than advisory.
		]]
		resetAt = 1.0,
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

		-- Dug, like the beach. Blown sand is if anything MORE obviously a loose
		-- layer over something firmer than a tideline is.
		crust = true,

		-- Slightly less litter per cell than the beach but richer finds: a smaller
		-- field that pays better is what makes it worth the trip.
		litterChance = 0.13,
		itemChance = 0.08,

		-- ITS OWN SET, built by Island2Builder. This was "Litter" -- the beach's
		-- washed-up plastic bottles, milk cartons and pizza boxes, strewn across a
		-- desert two hundred studs from a pyramid. Nothing had ever washed up out
		-- here; it is the one field in the game with no sea anywhere near it.
		litterSet = "Dunes",

		-- Left alone at 1.0. The dunes are the trip you make FOR the good stuff,
		-- and keeping the dial on the row is what stops retuning the beach from
		-- quietly retuning every field in the game.
		--
		-- It is also why the desert's own item pool (Config.DUNE_ITEMS, set below
		-- the item tables) is encased normally rather than exempted the way the
		-- tomb's is: with nothing in the pool crusted this dial would scale
		-- nothing, and the field would pay out loose potsherds forever.
		encasedScale = 1.0,

		-- 2304 cells against the beach's 4096, so this is a much shorter job --
		-- hence the bigger payout for finishing it. 1.0 like the beach: see the long
		-- note on ISLANDS[1].resetAt for why the fraction went and what it costs to
		-- keep 1.0 honest. This field was measured the same way -- all 2304 cell
		-- centres on flat dry ground, nothing colliding standing on the square.
		resetAt = 1.0,
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

		-- NO CRUST, and this is the row that says why the flag is per island rather
		-- than global. The other three fields are sand and are dug through; this is
		-- a flagstone floor under a carpet, a dais and several hundred gold props,
		-- and a layer of loose sand to shovel out of a sealed tomb would be absurd.
		-- The vault therefore keeps the terrain material swap (see
		-- Config.terrainSwapFor), which is what sweeping a floor should look like.
		crust = false,

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

		--[[
			CLEAR IT PROPERLY -- ALL OF IT. This row said 0.9 and "not three quarters
			of it", which was the right instinct aimed at the wrong number: it still
			left 102 cells of a room whose whole premise is that the floor is COVERED.

			The 0.9 was also doing quiet double duty as a hedge. This is the only
			field in the game that does not exist until a server boots -- VaultBuilder
			pours the room, so there is nothing to measure in Edit -- and it is the
			one island whose clearance could not be probed cell by cell the way the
			other four were.

			SO IT WAS MEASURED A DIFFERENT WAY: the builder's own source was run in a
			sandbox with Instance.new and Terrain stubbed out, which yields the 602
			parts it would really create with their true CFrames, sizes and CanCollide
			flags -- the builder's arithmetic rather than somebody's reading of it.
			Exactly 21 of those touch the rakeable square in XZ, and every one of them
			is ceiling: the slab, the soffit panels, the skylight kerbs and two ribs.
			The lowest colliding surface anywhere over this field is a kerb underside
			at y = 43.6, which is 40.6 studs above a floor at y = 3.

			The floor-level margins are wide, not lucky. Nearest solid in X is a
			column base 8.7 studs outside the square; the dais begins at z = 88, 24
			studs clear of the z = +64 edge; the Scales' table top 19.4 clear at the
			other end. The four chests were bounded over EVERY rng outcome rather than
			one seed and still stop 2.4 studs short. Everything that does cross the
			square -- the carpet, the treasure litter, the light beams -- is
			CanCollide = false. VaultBuilder's own note at its Dimensions block is
			accurate: the furniture stands in the 36/66 stud reserved margin.

			Tool width never binds here, which is why the gate level does not matter:
			the floor is flat uniform terrain with crust = false, so every one of the
			1024 cell centres is directly stand-on-able and the reach required is nil.

			WHAT THIS ROOM STILL LACKS, and it is the one thing to fix next: the other
			builders assert at boot that nothing stands in their field. VaultBuilder
			does not. At 0.9 that was survivable -- the room carried 102 cells of
			slack. At 1.0 there is none, so a statue or a crate dropped in here later
			makes the field uncompletable with nothing said at boot.
		]]
		resetAt = 1.0,
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

		-- Dug, like the other two beaches. The pale pink pair below is still what
		-- the crust and the channel floor are TINTED from, so the cove keeps its
		-- palette -- it just gets depth as well now.
		crust = true,

		-- The dunes' litter density with a step up in finds, on the dunes' logic:
		-- a field a quarter of the beach's size has to pay better per cell to be
		-- worth the crossing, and this is the one that asks for Lv.5 -- so it
		-- takes the same step past the dunes (0.08) that the dunes took past the
		-- beach (0.05).
		litterChance = 0.13,
		itemChance = 0.09,
		-- ITS OWN SET, ReplicatedStorage.CTB.Sakura. This row said "Litter" -- the
		-- beach's -- so the one field you take a ferry and a Lv.5 sifter to reach
		-- was strewn with the same plastic bottles, milk cartons and pizza boxes as
		-- the pier you left from. "It is still a beach" was the old reason here, and
		-- it is true, but it made raking the cove feel like raking the beach again.
		--
		-- Twelve Creator Store meshes, and every one a single BasePart, because
		-- CTB_Client's sink and raise tweens drive one part directly and a Model
		-- would need welding first -- the same rule the beach's set keeps and the
		-- same one buildDuneLitterSet records. What a hanami festival leaves on the
		-- sand: a boba cup, a fox mask, a paper lantern, nigiri and a tray of rolls,
		-- two ice creams, a folded crane, a celadon teapot, and the bowls somebody
		-- ate out of.
		--
		-- Unlike the dunes' set this one is NOT rebuilt at boot. It is a static
		-- folder in the place file, exactly as the beach's Litter is, because these
		-- are meshes to be saved rather than primitives to be re-made every time.
		litterSet = "Sakura",

		-- Left at 1.0 like the dunes. Lumps are only a trap where the way to the
		-- wash bay is closed, which is what forced the vault to zero; the cove's
		-- gate home is deliberately never locked, so a bagful of crust out here is
		-- a trip back rather than a soft-lock.
		encasedScale = 1.0,

		-- Same 2304 cells and the same 1.0 as the dunes, so finishing it is exactly
		-- the same job -- the full field either way. The premium over the dunes' 700
		-- is for the GATE and not for the labour: this is the field you need a ferry
		-- and a tall sifter to stand on, and it should out-earn the one below it. It
		-- stays nowhere near the vault's 5000, which pays for a 1024-cell room out of
		-- an entirely different item pool.
		--
		-- See ISLANDS[1].resetAt for why the 0.75 went. One cove-specific warning:
		-- assertClearOfField ALREADY warns on this island at boot (the Market's Drive
		-- and its two DriveRut parts poke about a stud into the square). They are
		-- CanCollide-irrelevant to the sweep, which is pure 2D arithmetic on cell
		-- centres -- but that warning is now the alarm for a field that can never
		-- reset, and it should be cleared so a real intruder is not lost in it.
		resetAt = 1.0,
		resetBonus = 900,
		resetName = "HANAMI",

		-- Pastel or not it is sand, and sand takes a groove.
		--
		-- DEAD FOR NOW, AND DELIBERATELY WRITTEN ANYWAY. The comb-mark layer that
		-- read this was taken out of CTB_Client -- the folder is still in that
		-- script's boot sweep ("CTB_Groom") but nothing makes a tile any more, and
		-- no other row here carries the key. So today it changes nothing. It is
		-- written because CTB_Server.applyLook's cove block already cites
		-- ISLANDS[4].groom as the reason its two tints may be narrowed, and a
		-- comment pointing at a field that does not exist is worse than a field
		-- nothing reads. If the comb marks ever come back, the cove is the field
		-- they were meant for.
		groom = true,

		-- The beaches' radius, unchanged, and it has to be this generous: almost
		-- everything that makes this place read as the cove -- the torii out in
		-- the water, the boardwalks, the arrival gate on the south shore -- stands
		-- OUTSIDE the 96-stud rakeable square, and all of it should still count as
		-- being in the cove for ambience and the colour grade.
		zone = 460,
	},
	{
		id = 5,
		name = "Ashfall Isle",
		--[[
			THE BIGGEST FIELD IN THE GAME, and the only row that is allowed past the
			beach's 64.

			80x80 is 320 studs across and 6400 cells -- 56% more than the beach and
			nearly three times the two 48-grid destinations. That is the point: this
			is the last island and the one the whole ladder is climbing toward, so
			it has to be visibly the biggest job as well as the best-paying one.

			WHY THAT IS AFFORDABLE HERE WHEN THE DUNES' NOTE SAYS IT IS NOT. That
			note is about cells held live ON TOP OF the beach's 4096, and it was
			written before the litter scatter became lazy. It is not: CTB_Client's
			ensureIslandBuilt only scatters an island's junk the first time the
			player actually stands in its zone, so a player who never sails here
			never pays for one prop of it. What IS paid up front is the server's
			baseline terrain write and one grid per player -- 6400 booleans and
			6400 rolls, which is arithmetic, not framerate.

			The crust is the other bill and it is the cheap kind: one part per
			unbroken run of untouched columns per row, so an untouched Ashfall is 80
			parts, not 6400.
		]]
		grid = 80,

		--[[
			DUE WEST, and 2200 out rather than the 1500 the other three use.

			The +X corridor is spoken for twice over (dunes at 1500, vault at 3000)
			and +Z once (the cove at 1500), so -X is the only axis with nothing on
			it -- surveyed rather than assumed: a raycast grid over the whole
			negative quadrant found the beach's own ocean petering out at x = -900
			and VOID from there to -2400 in every direction.

			2200 rather than 1500 because this island is far bigger than any of
			them. Its sea disc reaches 800 studs and its zone 760; at 1500 the zone
			would have come within 280 studs of the beach's own 460 and Config.zoneAt
			-- which returns the FIRST row that matches -- would have started calling
			the west end of the home beach "Ashfall". At 2200 the two are 980 studs
			apart with both radii allowed for.
		]]
		cx = -2200, cz = 0,

		--[[
			MUD AND BASALT, IN THAT ORDER, AND THE ORDER IS THE POINT.

			This row shipped the other way round -- Basalt as the field -- on the
			reasoning that the material NAMED after volcanic rock must be the right
			one for a volcanic island. It is the right one for the VOLCANO and it is
			the wrong one for a BEACH, and the difference is not a matter of taste:

				filled to an identical top, twenty-five probes per disc
				  Basalt       mean 1.81   range 1.31 .. 2.00   spread 0.69
				  CrackedLava  mean 1.90   range 1.63 .. 2.00   spread 0.37
				  Mud          mean 2.00   range 2.00 .. 2.00   spread 0.00
				  Ground       mean 2.00   range 2.00 .. 2.00   spread 0.00
				  Sand         mean 2.00   range 2.00 .. 2.00   spread 0.00

			Basalt does not merely LOOK chunky, it DISPLACES: it renders its surface
			up to seven tenths of a stud below the fill and never twice the same,
			which is boulders in the ground rather than a texture on it. Across a
			6400-cell field that reads as rock everywhere, which is exactly what it
			looked like. Mud is dead flat to three decimal places -- the same as the
			Sand the beach rakes and the Ground the cove does -- and its grain is a
			fine damp speckle, which is what black volcanic sand actually is.

			That spread is also why Basalt keeps a job here rather than being dropped:
			a surface that will not lie flat is perfect for the CONE, and
			Island4Builder pours the mountain, the west terrace and the sea stacks in
			it for that reason. Bumpy is a defect on a beach and a feature on a
			mountainside.

			If a field material is ever re-picked here, POUR A TEST DISC AND MEASURE
			THE SPREAD before trusting it. Anything above about 0.1 is geometry, not
			texture, and geometry breaks the flush rule below.
		]]
		--[[
			AND WHY THESE TWO ARE THIS ISLAND'S TO SPEND.

			Terrain material colours are GLOBAL (see the note above this table), so
			an island's palette is bought by claiming a pair nothing else uses.
			Sand/Snow/Limestone are the beach's, Sandstone/Salt/Rock/Slate the
			dunes', Cobblestone/Pavement the vault's, Ground/Asphalt the cove's.
			Basalt and Mud are Ashfall's now, place-wide, along with CrackedLava --
			which is not a field material but is tinted alongside them in
			CTB_Server.applyLook for the volcano's own flows. Nothing else in this
			game, on any island, may use those three as TERRAIN.

			Mud is also the material the CRUST parts are built from (see Config.CRUST),
			so the loose top layer the sifter cuts through inherits the same fine
			grain for free -- which is the half of this the player is actually walking
			in.

			BASALT IS DORMANT AS A FIELD MATERIAL AND BUSY AS A LANDSCAPE ONE. This
			field is dug rather than repainted, and Config.terrainSwapFor returns
			false for any island with a crust, so matClean is never written to a voxel
			here. It is still named and still unique, because the flag is per island
			and a future variant with the crust off has to have somewhere to go -- and
			if that day comes, a raked cell coming up as the mountain's own rock is a
			perfectly good fiction for sand swept off bedrock. Its TINT is spent on
			the cone rather than on a narrow step off the sand, for the same reason.
		]]
		matMessy = Enum.Material.Mud,
		matClean = Enum.Material.Basalt,

		-- 3.0, like every other field, and for the reason spelled out on the cove's
		-- row: Y_MIN/Y_MAX, SURFACE_BASE and occupancyFor are shared, so all five
		-- live in the same four-voxel band. Island4Builder fills its plateau flush
		-- with this. Nothing about the volcano changes it -- the cone starts fifteen
		-- studs clear of the field's north edge and rises outside this band entirely.
		cleanY = 3.0,

		-- Dug, like the other three beaches. Black sand is if anything the most
		-- obviously loose surface in the game -- volcanic grit sits on top of packed
		-- ash exactly the way the crust models it.
		crust = true,

		--[[
			A LOWER PER-CELL RATE THAN ANY OTHER FIELD, AND MORE JUNK THAN ANY OTHER
			FIELD. Those are the same sentence: 0.11 across 6400 cells is ~700 props
			against the beach's ~600 over 4096 at 0.15.

			Keeping the COUNT near the beach's is what matters -- that number is the
			one that has been measured as survivable on a phone -- and spreading it
			over half again as much ground is what makes a huge black strand read as
			open rather than as a landfill. Raise the count, not the rate, if it ever
			feels bare.
		]]
		litterChance = 0.11,
		itemChance = 0.10,

		-- ITS OWN SET, ReplicatedStorage.CTB.Volcano: half Creator Store meshes and
		-- half primitives built by Island4Props at boot, which is the two ways this
		-- game already makes a litter set (the cove's Sakura meshes, the dunes'
		-- code-built parts). What washes up on a black beach under a live volcano:
		-- pumice, scorched planks, ash-caked cans, a burst net float, and whatever
		-- the last party up the mountain dropped on the way.
		litterSet = "Volcano",

		-- 1.0, like the dunes and the cove. Lumps are only a trap where the way to
		-- the wash bay is shut, which is what forced the vault to zero; the ferry
		-- home from here is never level-locked, so a bagful of crust is a crossing
		-- rather than a soft-lock.
		encasedScale = 1.0,

		--[[
			6400 COLUMNS TO TURN THE TIDE -- the longest job in the game by half
			again, against the beach's 4096 and the two destinations' 2304.

			The bonus is set per COLUMN rather than per field, which is the only way
			the ladder stays honest: at 1.0 the beach pays 0.06 a column, the dunes
			0.30 and the cove 0.39. 3200 over 6400 is 0.50, the next step up, and it
			lands under the vault's 5000 -- which buys a much smaller room out of an
			entirely different item pool and should stay the biggest single number in
			the file.

			EVERY FIGURE ABOVE MOVED WHEN THE FRACTION WENT. This row read 0.75 and
			counted 4800 columns; see the long note on ISLANDS[1].resetAt for why a
			field now has to be finished rather than three-quarters done. The per
			column rates fell because the columns went up and the bonuses did not --
			if this ladder is ever re-priced, that is the honest place to start.
		]]
		resetAt = 1.0,
		resetBonus = 3200,
		resetName = "ERUPTION",

		--[[
			760, the widest zone in the file, and every stud of it is asked for.

			zoneAt is what decides whether the ambience, the colour grade and the
			litter scatter think you are here. On this island the things that make it
			read as Ashfall are almost all OUTSIDE the 160-stud rakeable square: the
			camp is 300 south of centre, the ferry berth 520 south, and the crater is
			470 north with its own flanks running out to 760. A player standing on
			the rim looking down into the lava has to still be on the island.

			It is only affordable because nothing is near: 760 + the beach's 460 is
			1220, and the two centres are 2200 apart.
		]]
		zone = 760,
	},
	{
		id = 6,
		name = "Inner Shrine",

		--[[
			THE ROOM BEHIND THE COVE'S SHRINE DOOR, and the second interior in the
			game after the tomb.

			32 for the same reason ISLANDS[3] is 32: an interior is a ROOM, and a
			room you can see the far wall of is worth more than a big one. 128 studs
			across is four sweeps at a mid roller width and it fits inside a hall
			whose ceiling the player can actually see.

			Sited at (3000, 1500) -- the empty quadrant. The tomb is (3000, 0) and
			the cove itself is (0, 1500), so this is 1500 from each of them and
			further from everything else. Verified empty before it was claimed: no
			parts within 400 studs and no terrain.
		]]
		grid = 32,
		cx = 3000, cz = 1500,

		--[[
			WOODPLANKS -> CONCRETE, and both were free.

			Every other pair in this file was already spoken for: Sand/Snow the
			beach, Sandstone/Salt the dunes, Cobblestone/Pavement the tomb,
			Ground/Asphalt the cove, Mud/Basalt Ashfall -- plus Limestone, Rock,
			Slate and CrackedLava tinted for scenery. That left Grass, Concrete,
			Brick, WoodPlanks, Glacier, Ice and LeafyGrass, and a temple floor is
			boards.

			MEASURED, not assumed. The rule this file cares about is which material
			WINS the terrain blend -- see the cove's note, where Asphalt beating
			Ground is the only reason its raked cells are visible at all. A dark
			WoodPlanks slab with pale 20-stud bands of Concrete, Glacier, Ice and
			LeafyGrass cut into it was photographed: all four beat WoodPlanks
			comfortably, enough that the wood between the bands was the thing that
			struggled. Concrete of the four, because it is the flattest and this is
			meant to read as boards worn smooth rather than as ice on a floor.
		]]
		matMessy = Enum.Material.WoodPlanks,
		matClean = Enum.Material.Concrete,

		-- The same floor height as every other field, so the sifter, the props and
		-- the HUD all keep the one number they have always had.
		cleanY = 3.0,

		-- SWEPT, NOT DUG -- the tomb's rule, for the tomb's reason. Config.CRUST
		-- lays a loose layer for a sifter to cut a channel through, and there is no
		-- loose layer on a temple floor. What is on these boards is litter lying on
		-- top of them.
		crust = false,

		-- Denser than the cove outside it and a shade under the tomb. A room is
		-- small, and a small room with a beach's scatter in it reads as empty.
		litterChance = 0.28,
		itemChance = 0.12,

		-- Its own set: offerings, not seaweed. Built by ShrineBuilder alongside the
		-- hall, the same way the tomb builds "Treasure".
		litterSet = "Shrine",

		-- Nothing indoors has been in the sea, so nothing here comes up encased --
		-- exactly the tomb's argument, and the wash bay is a beach machine.
		encasedScale = 0,

		resetAt = 1.0,
		resetBonus = 1800,
		resetName = "PURIFIED",

		-- 300, the tomb's number. A zone only has to be big enough to hold the room
		-- and its porch, and this one is 1500 studs from its nearest neighbour, so
		-- there is nothing for it to overlap.
		zone = 300,
	},
	{
		id = 7,
		name = "Magma Chamber",

		--[[
			THE ROOM BEHIND THE DOOR CUT INTO ASHFALL'S VOLCANO, and the third
			interior in the game after the tomb and the shrine.

			40 rather than the 32 both of those use. An interior is a ROOM and a
			room you can see the far wall of is worth more than a big one -- but
			those two are a burial chamber and a timber hall, and this is a cave
			under a mountain. 160 studs across is still one screen at the play
			camera, and it is the largest a room can be while a player standing
			at the door can still read the far end by nothing but what is coming
			out of the floor.

			Sited at (3000, -1500) -- the last empty quadrant. The tomb is
			(3000, 0) and the shrine is (3000, 1500), so this is 1500 studs from
			the nearer of them and 2100 from the dunes, and a zone of 300 has
			nothing to overlap. Verified empty before it was claimed: no parts
			within 400 studs and not one solid voxel in a 49-point probe across
			600 studs of ground.
		]]
		grid = 40,
		cx = 3000, cz = -1500,

		--[[
			MUD -> BASALT: ASHFALL'S OWN PAIR, SHARED ON PURPOSE.

			Terrain material colours are GLOBAL (see the note above this table),
			so every island so far has bought its palette by claiming a pair
			nothing else uses -- Sand/Snow the beach, Sandstone/Salt the dunes,
			Cobblestone/Pavement the tomb, Ground/Asphalt the cove, Mud/Basalt
			Ashfall, WoodPlanks/Concrete the shrine. What is left is Grass,
			Brick, Glacier, Ice and LeafyGrass, and the shrine's own note
			records why most of that is unusable: Grass and Glacier are
			SWALLOWED as a minority strip and cannot be a raked state at all,
			Brick renders a full stud proud of every other field, and Ice is
			bumpy.

			None of which matters, because this room is INSIDE the island whose
			pair it is sharing. The ash on this floor is meant to look exactly
			like the ash on the strand outside; a seventh tint would be a
			seventh tint spent making them differ. Sharing is the RIGHT answer
			here and would be the wrong answer anywhere else in this file.

			It is also only ever spending one of the two. crust = true below,
			and Config.terrainSwapFor returns false for any island with a crust,
			so matClean is never written to a voxel in this room. Basalt is
			still named, for the same reason Ashfall names it: the flag is per
			island and a future variant with the crust off has to have somewhere
			to go.
		]]
		matMessy = Enum.Material.Mud,
		matClean = Enum.Material.Basalt,

		-- 3.0, like every other field, and for the reason spelled out on the
		-- cove's row: Y_MIN/Y_MAX, SURFACE_BASE and occupancyFor are shared, so
		-- all seven fields live in the same four-voxel band.
		cleanY = 3.0,

		--[[
			DUG, NOT SWEPT -- the one place this row disagrees with the two
			interiors it is otherwise copying.

			ISLANDS[3] and ISLANDS[6] both set crust = false with the same
			sentence: Config.CRUST lays a loose layer for a sifter to cut a
			channel through, and there is no loose layer on a temple floor.
			True of a tomb, true of a shrine hall. There IS one on the floor of
			a lava tube -- ash and cinder falling out of the air is the whole
			premise of the island this room is under -- so the argument that
			switched the crust off over there is the argument that keeps it on
			here.
		]]
		crust = true,

		-- Denser than the strand outside (0.11) and a shade under the shrine's
		-- 0.28. A room is small, and a small room with a beach's scatter in it
		-- reads as empty -- but this one is 1600 cells against the shrine's
		-- 1024, so the shrine's rate would be half again as much clutter.
		litterChance = 0.24,
		itemChance = 0.12,

		-- Its own set, ReplicatedStorage.CTB.Cinder, built by MagmaBuilder
		-- alongside the room -- the same way the tomb builds "Treasure" and the
		-- shrine builds "Shrine".
		litterSet = "Cinder",

		--[[
			Nothing indoors has been in the sea, so nothing here comes up
			encased -- exactly the tomb's and the shrine's argument.

			Worth flagging that this is the FIRST row in the file to run
			crust = true WITH encasedScale = 0, so nothing is being leaned on
			that has been leaned on before. The two are independent by
			construction: Config.weightsFor multiplies the crusted half of the
			table by this scale, so zero simply means every lump the sifter
			turns up in here comes out as a bare find.
		]]
		encasedScale = 0,

		--[[
			1600 COLUMNS, AND 4000 FOR THE LOT.

			The bonus is set per COLUMN, which is the only way the ladder stays
			honest: at resetAt 1.0 the beach pays 0.06 a column, the dunes 0.30,
			the cove 0.39, Ashfall 0.50 and the shrine 1.76. This is 2.50 --
			above all of them, and below the vault's 4.88, which the tomb's own
			row says should stay the biggest number in this file.

			2.50 rather than something nearer the shrine's because of what it
			costs to be standing here at all: ten rebirths for the ferry, a
			Lv.6 sifter, and then the walk up the cutting. The shrine sits
			behind three rebirths on an island most players already own.
		]]
		resetAt = 1.0,
		resetBonus = 4000,
		resetName = "DORMANT",

		-- 300, the tomb's and the shrine's number. A zone only has to be big
		-- enough to hold the room, and this one is 1500 studs from its nearest
		-- neighbour.
		zone = 300,
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

--[[
	THE SHEEN LEFT ON RAKED GROUND

	Raked and unraked ground are the same HEIGHT, and always must be -- raked
	progress is per player, so differing heights would have players standing at
	different levels on the same spot. That leaves the material swap as the only
	difference, and on a dead flat plane a material swap reads as a change of
	colour rather than as sand somebody has run a machine over.

	This is the third attempt at that problem and the first that does not walk
	into a constraint the other two hit:

	  * RAISED GROOVE PARTS cast shadows, and at any size big enough to see they
	    read as wooden decking rather than as combed sand.
	  * A GROOVE-TEXTURED MaterialVariant is capped by its own colour map's tone,
	    so raked ground could only ever come out DARKER than the sand around it --
	    the wrong direction, and the reason no variant is bound to Snow.

	A flush, shadowless, translucent tile has neither problem. It LIGHTENS what
	is under it, which is the direction compacted sand actually goes, and with no
	thickness there is no edge for light to catch, so it cannot read as a plank.
	It is also tone-free in the sense that matters: it does not replace the
	ground's colour, it sits over it, so every island keeps its own palette.

	`tint` is per island because the three fields deliberately share no colours
	(the beach's sand, the dunes' ochre, the vault's stone) and one warm white
	across all of them would grey out whichever is furthest from it.
]]
Config.SHEEN = {
	enabled = true,

	--[=[
		IT IS PAINTED, NOT BUILT.

		Four versions of this drew the swept ground as PARTS and each one died on
		the same wall from a different direction. A part is a rectangle: it
		cannot be the shape of a curve, so curves came out as rectangles
		overlapping at angles. And a part's material texture is mapped in the
		PART's axes, so any two that overlapped showed their grain running two
		ways with a seam along the join -- measured, three Sand slabs crossing at
		0/45/90 degrees render as three plainly different shades.

		Chasing that produced a ledger of covered columns, a lateral clip, a
		ladder of z-offsets and a miter solver: several hundred lines whose whole
		job was stopping parts from touching, because touching is the thing parts
		cannot do invisibly.

		So it is a canvas now -- one image per island, and the sifter draws into
		it with a round brush. That is the true shape of what a sifter sweeps:
		the set of points within half a tool-width of the path taken. A curve is
		curved because it IS the swept region rather than an approximation of one
		assembled from offcuts, and the part count per island went from hundreds,
		capped and thrown away oldest-first, to exactly one that never expires.

		It is also exactly idempotent. Each covered pixel is written from a value
		derived from its own coordinates, so the hundredth pass writes the byte
		the first one wrote: a 110-stud lane painted twice came back zero bytes
		different out of 4,194,304.

		REQUIRES "Allow Mesh & Image APIs" (Game Settings -> Security). With it
		off the API throws on the first draw, which is caught once and the sheen
		simply does not appear.
	]=]

	-- How much lighter than the island's own clean terrain material. Read at
	-- runtime rather than hardcoded, so the band matches whatever ground it is
	-- laid on -- a fixed sand tone would sit on the vault's stone like a sticker.
	lift_colour = 0.05,

	-- Canvas resolution, as pixels per stud, capped. A canvas costs px*px*4
	-- bytes and this runs on phones: at 6 the beach's 256 studs come to 1536px
	-- and 9MB, and a pixel is a sixth of a stud -- twenty-four times finer than
	-- the 4-stud columns the terrain records the same ground in. The band's edge
	-- is antialiased on top of that, so what sets how straight it looks is the
	-- coverage maths rather than this number.
	px_per_stud = 6,
	-- 1024 IS AN ENGINE LIMIT, NOT A TASTE CHOICE.
	--
	-- AssetService:CreateEditableImage refuses anything above 1024 on either
	-- axis. At 2048 this asked for 1536 (Beach), 1152 (Dunes), 1152 (Cove) and
	-- 1920 (Ashfall) -- four of the five islands -- and every one of them threw.
	--
	-- That was not four islands losing the sheen, it was ALL FIVE: canvasFor
	-- sets `paintable = false` on the first failure, which is a module-wide
	-- latch, so the Vault's own 768 (which fits) never got asked for either.
	-- The visible symptom was the raked band rendering as hard-edged material
	-- rectangles rather than as swept sand.
	--
	-- The clamp below already does the right thing once this is honest: the
	-- Beach lands at 4 px/stud and Ashfall at 3.2, which is softer than the
	-- nominal 6 but is a sheen that EXISTS.
	px_max = 1024,

	-- The grain, as the fraction either side of the tint. Fine is per pixel, for
	-- sand; coarse is per eight pixels, for the cloudier variation real flattened
	-- sand has. Both are functions of the PIXEL, never of the stroke, which is
	-- what stops a join or an overlap from ever showing.
	grain_fine = 0.09,
	grain_coarse = 0.16,

	-- The lattice the coarse variation is sampled on, in pixels, smoothstepped
	-- between its corners. It was one flat value per 8x8 block, which drew the
	-- band as a grid of little squares -- the "pixelated" look the grain exists
	-- to prevent. At 6 px/stud this is about two studs between samples.
	grain_cell = 12,

	-- FLUSH WITH THE SAND. The canvas is not laid ON the ground, it is set INTO
	-- it: only `lift` of the plane clears the terrain and the rest of the
	-- thickness is buried, so no edge stands proud and there is no lip to catch
	-- the light. The terrain is dead flat -- probed at exactly surfaceY across
	-- the whole field, zero spread -- so `lift` only has to beat depth
	-- precision, not a bumpy surface, and can be this small.
	lift = 0.03,
	thickness = 0.12,

	--[=[
		HOW MUCH WIDER THAN THE TOOL, AND WHY IT IS NOW NOTHING.

		This was a whole tile, to cover ground the SERVER rakes but the tool does
		not literally pass over: a column flips when its centre falls under the
		tool, and a column is TILE across, so the terrain corridor comes out 8
		studs wide against a 6-stud tool (measured off the voxel grid).

		But a band wider than the sifter looks wrong, because it IS wrong -- the
		mark belongs where the blade went and nowhere else. So the polish is the
		tool's width exactly, and the terrain is left to be up to half a tile out
		either side. That is the terrain's own coarseness rather than something
		the polish should paper over. Raise it if that fringe ever starts reading
		as a third tone again.
	]=]
	spread = 0,

	-- Studs of travel between writes. Small, because the band now ends in a
	-- straight edge square across the path rather than a round cap: the head is
	-- a visible line, so it wants to advance smoothly rather than in jumps.
	step = 0.5,

	-- Pixels each swept quad is grown along its own travel, so consecutive ones
	-- overlap rather than butt up. Two edges that merely touch each land on the
	-- shared pixel at half coverage, and the greater of two halves is still a
	-- half -- which would draw a faint seam every single step. Overlapping puts
	-- the join well inside both.
	join = 2,

	--[=[
		HOW FAR A NEW RUN REACHES BACK.

		Nothing is drawn until `cutting` says the tool is genuinely biting, and
		that only rises once the SERVER confirms a raked column -- a tick plus a
		round trip after the tines went in. Measured in a stop/start test: the
		band began 7.8 studs after the raked terrain did, and a stop-and-go left
		a 6.5-stud hole in a lane the terrain underneath had raked straight
		through.

		So a run does not start under the tool. It walks BACK the way the tool
		came, up to this far, stopping the moment it reaches ground this player
		has not raked -- so it can only ever fill in sand genuinely sifted.
	]=]
	lookBack = 12,

	--[=[
		HOW MUCH UNRAKED GROUND TO FORGIVE.

		The polish is drawn at the TOOL, but the ground is raked around the
		PLAYER, and the tool is held out in front -- so the head always sits a
		couple of studs past the last confirmed column. Without an allowance the
		look-back tests the first point behind the tool, finds it not yet raked
		and gives up: measured, that left the band starting 7.5 studs into a lane
		whose terrain was raked from the first step.
	]=]
	lead = 8,

	-- A break shorter than this rejoins without even checking the ground.
	-- `cutting` dips under its threshold constantly and players stand still all
	-- the time; neither should leave a seam across a lane.
	rejoin = 4,
}

-- Materials, heights and litter density all live on the island rows above now.
-- These three are kept because other scripts still read them for the beach.
Config.MAT_MESSY = Config.HOME.matMessy
Config.MAT_CLEAN = Config.HOME.matClean
Config.CLEAN_Y   = Config.HOME.cleanY

--[[
	ON, BUT ONLY WHERE NOTHING IS DUG. Raking rewrites the ground under the tool.

	Each raked column's terrain MATERIAL is swapped -- Cobblestone -> Pavement in
	the vault -- at an identical surface height. Grainy going smooth: that was the
	whole "sand erasing" look, and it is the one piece of feedback that marks
	WHERE YOU HAVE BEEN rather than just flashing when you pass. Particles say
	"something happened here a second ago"; only the ground itself can still be
	saying it a minute later.

	THE THREE SAND FIELDS DO NOT USE IT ANY MORE. They carry a loose top layer
	that is cut away instead (Config.CRUST), which says the same thing with a
	channel and two walls rather than with a change of tone. Ask
	Config.terrainSwapFor rather than reading this flag directly -- it is the one
	that knows an island cannot do both.

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

--[[
	THE LOOSE TOP LAYER -- the sand the sifter actually digs through.

	A second sand surface laid OVER the field's terrain and deleted column by
	column as the tool passes, so a swept lane is a CHANNEL with two walls rather
	than a patch of ground that has changed colour. Untouched sand stands `rise`
	proud of the ground the tool exposes, and those walls are the whole effect:
	the sun here is 82 degrees up (see the latitude note in CTB_Server's
	applyLook) so a lip this small throws no shadow worth having -- but a vertical
	face under an overhead sun takes almost no direct light at all, and that is
	what draws the edge.

	IT REPLACES THE MATERIAL SWAP RATHER THAN JOINING IT. An island with a crust
	writes no terrain at all (Config.terrainSwapFor), and the ground under the
	layer stays messy forever. Running both would have them fight: the swap paints
	the FLOOR of the channel paler, and paler is what the sand still standing over
	it is meant to be.

	WHY IT DOES NOT COLLIDE, which is the first thing anyone will want to change.
	Raked progress is private (see the grid-state block in CTB_Server) and the
	crust is built per client, so a solid one would stand two players who had
	raked different columns on two different floors -- exactly the divergence
	Config.surfaceY exists to prevent -- and it would drop the ground out from
	under the player's own feet every four studs while they rake, because the
	server rakes the column they are STANDING on. It is a skin: the player, the
	litter and the sifter all still stand on the terrain plane at
	Config.surfaceY, and only what they are standing IN changes.

	WHAT IT COSTS. One part per unbroken run of untouched columns per row -- an
	untouched beach is 64 parts, not 4096, and only rows that have actually been
	cut into ever split. A row is rebuilt whole when any column in it changes,
	batched onto Heartbeat beside the terrain flush it replaces.
]]
Config.CRUST = {
	enabled = true,

	-- How far untouched sand stands over the ground the tool exposes. This is the
	-- depth of the channel and the biggest single dial on whether the effect reads
	-- at all -- but it is ALSO how deep the player wades in sand they have not
	-- cleared, because the layer does not collide, and an R15 foot is only about
	-- 0.4 studs tall.
	--
	-- 0.4, 0.5 and 0.7 were all looked at in play, from the gameplay camera and
	-- from 30 studs up. 0.4 reads at head height and nearly vanishes from above:
	-- the sun is 82 degrees up, so there is no shadow to help and the WALL is the
	-- entire effect. 0.7 is unmistakable from any angle and swallows the shoe.
	-- 0.5 is the one where a channel still reads looking down at the field and the
	-- feet still read as sunk into loose sand rather than clipped through a slab.
	rise = 0.5,

	-- How far the same slab carries on BELOW the terrain surface. Nothing ever
	-- sees it; it is there so the underside never lands exactly on the terrain
	-- plane and z-fights along every join in the field.
	bury = 0.3,

	-- Toward white, off the island's own MESSY terrain tint (the crust is built
	-- from that same material, so it inherits each island's palette for free, and
	-- a PART's tone comes from Color rather than from the global terrain tints --
	-- which is why none of this can repaint anybody else's island). Dry loose sand
	-- over damper packed sand: it is what makes the floor of a channel read a step
	-- darker than the layer still standing beside it.
	--
	-- 0.11 takes the beach's 203,177,106 to 209,186,122 -- about where the raked
	-- terrain tone sits, and nowhere near the 240,226,187 that once turned the
	-- sand white (see applyLook in CTB_Server). It cannot go much further, because
	-- this tone is the WHOLE rakeable square seen from the shore outside it: too
	-- much lift and it stops being a top layer and becomes a paler rectangle of
	-- beach.
	--
	-- It carries more weight than it looks like it should, because the polish that
	-- would otherwise separate the two (Config.SHEEN) is the first thing to go
	-- missing -- it needs EditableImage, and where that is unavailable the depth
	-- and this step of tone are all that is left saying a lane has been cut.
	lighten = 0.11,

	-- Where the polish the sifter paints along its path (Config.SHEEN) is aimed
	-- once a crust is over the field. It has to land UNDER the crust's own tone,
	-- or the floor of a cut channel comes out paler than the sand standing over
	-- it and the channel reads as filled rather than dug. Negative is toward
	-- black; SHEEN.lift_colour is ignored on a crusted island.
	sheen_lift = -0.04,

	-- The piece that falls away at the instant a column is cut: one cell-sized
	-- slab dropped and faded where the crust just was, so the layer crumbles
	-- instead of blinking out. Inset from the full tile so its sides never land
	-- exactly on the faces of the crust it is falling out of.
	crumb = true,
	crumb_inset = 0.25,
	crumb_life = 0.24,
}

-- The crust settings for one island, or nil if this field is not dug.
function Config.crustFor(isl)
	if not (Config.CRUST.enabled and isl.crust) then
		return nil
	end
	return Config.CRUST
end

-- Whether raking still swaps this island's terrain material. False wherever a
-- crust is doing that job instead: the two are alternatives, not layers. Read
-- this rather than Config.TERRAIN_DEFORMS.
function Config.terrainSwapFor(isl): boolean
	return Config.TERRAIN_DEFORMS and Config.crustFor(isl) == nil
end

-- Top of the loose layer over one island, in world Y -- what an untouched cell
-- LOOKS like the surface is. Equal to the terrain surface where there is no
-- crust, so callers can add it unconditionally.
function Config.crustY(isl): number
	local C = Config.crustFor(isl)
	return Config.surfaceY(isl) + (C and C.rise or 0)
end

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

--[[
	THE BEACH'S OWN POOL, and it is the last of the five to get a real one.

	It was SEVEN ROWS -- Can, Bottle, Shell, Coin, Glasses, Watch, Phone -- while
	the dunes had twenty-two, Ashfall thirty and the cove twenty-two. Three things
	followed from that, and every one of them was invisible in the code:

	1. THE HOME BEACH COULD NOT PRODUCE ANYTHING ABOVE RARE. Phone tops out at
	   OneIn 400 and the Epic floor is 500, so the island every player starts on
	   and spends most of their time on had no Epic, no Legendary and no Mythic in
	   it at all. There was nothing on it to chase.

	2. IT MADE PETS NEARLY WORTHLESS AT HOME. LuckService steps a revealed item UP
	   its pool's encased ladder, and the beach's encased ladder was three rungs
	   long: Coin, Watch, Phone. The best loadout in the game could turn a Coin
	   into a Phone and then stop. Twenty-six rungs is what makes a maxed pet
	   team worth buying.

	3. THE PRICES ON SCREEN WERE WRONG. The `value` column here was hand-written
	   (Can 6, Watch 55, Phone 95) while the till pays ItemConfig's derived figure
	   (11, 112, 164). resolvePools fills label and value from the catalogue for
	   every other pool and skipped this one, so the beach quietly under-quoted
	   every find it showed you. This table is in that list now, which is why the
	   two hand-kept columns are gone from these rows.

	WEIGHTS RUN AS 135/OneIn AND FLATTEN AT THE TOP, which is the curve the other
	three pools already use -- so the ladder still feels like a ladder and the last
	three pieces are an event rather than a rounding error. Straight 1/OneIn would
	put the Meteorite at one find in 148,000, which is not a chase, it is a rumour.

	WHAT THIS DOES NOT DO IS MAKE THE BEACH RICHER. Measured against the same
	model: mean value per find moves 27.2 -> 26.4 and mean weight 0.46 -> 0.58 lb,
	which is ItemConfig's own stated figure for a beach find. That is deliberate --
	the opening cadence (first purchase around nine seconds, a full round of all
	four tracks -- 360 coins of bases -- in about fifty seconds) is already right
	and must not move. What changes is the CEILING and the VARIANCE.

	The crusted half is additionally multiplied by the island's encasedScale in
	weightsFor, so these are the numbers BEFORE that 0.90.
]]
Config.ITEMS = {
	-- COMMON : washed-up litter, loose, sells on the spot
	{ id = "Can",           weight = 30,    color = Color3.fromRGB(214, 68, 58) },
	{ id = "Bottle",        weight = 21,    color = Color3.fromRGB(126, 205, 158) },
	{ id = "Cup",           weight = 17,    color = Color3.fromRGB(250, 250, 245) },

	-- UNCOMMON : still loose
	{ id = "FryBox",        weight = 11,    color = Color3.fromRGB(214, 86, 66) },
	{ id = "MilkCarton",    weight = 9,     color = Color3.fromRGB(238, 238, 230) },
	{ id = "BottleCap",     weight = 7.5,   color = Color3.fromRGB(200, 44, 44) },
	{ id = "Straw",         weight = 6,     color = Color3.fromRGB(240, 120, 140) },
	{ id = "PizzaBox",      weight = 5.2,   color = Color3.fromRGB(206, 178, 132) },
	{ id = "Shoe",          weight = 4.5,   color = Color3.fromRGB(64, 66, 74) },
	{ id = "TrashBag",      weight = 4,     color = Color3.fromRGB(38, 38, 42) },
	{ id = "Shell",         weight = 3.5,   color = Color3.fromRGB(248, 206, 196) },
	{ id = "FlipFlop",      weight = 3.1,   color = Color3.fromRGB(80, 190, 220) },
	{ id = "Glasses",       weight = 2.9,   color = Color3.fromRGB(46, 46, 56) },

	-- RARE : encased from here on, at the same OneIn 50 threshold every field uses
	{ id = "Starfish",      weight = 1.8,   color = Color3.fromRGB(226, 140, 58) },
	{ id = "Lure",          weight = 1.5,   color = Color3.fromRGB(232, 178, 60) },
	{ id = "Driftwood",     weight = 1.25,  color = Color3.fromRGB(150, 124, 96) },
	{ id = "MessageBottle", weight = 1.05,  color = Color3.fromRGB(150, 196, 168) },
	{ id = "Coin",          weight = 0.9,   color = Color3.fromRGB(255, 196, 60) },
	{ id = "Keys",          weight = 0.75,  color = Color3.fromRGB(180, 180, 190) },
	{ id = "Watch",         weight = 0.65,  color = Color3.fromRGB(244, 204, 92) },
	{ id = "Compass",       weight = 0.55,  color = Color3.fromRGB(212, 178, 96) },
	{ id = "Headphones",    weight = 0.48,  color = Color3.fromRGB(48, 52, 64) },
	{ id = "Snorkel",       weight = 0.42,  color = Color3.fromRGB(60, 150, 220) },
	{ id = "Phone",         weight = 0.35,  color = Color3.fromRGB(44, 48, 64) },
	{ id = "Wallet",        weight = 0.30,  color = Color3.fromRGB(96, 60, 40) },

	-- EPIC
	{ id = "Boombox",       weight = 0.24,  color = Color3.fromRGB(38, 42, 52) },
	{ id = "Binoculars",    weight = 0.19,  color = Color3.fromRGB(34, 38, 50) },
	{ id = "GoldRing",      weight = 0.15,  color = Color3.fromRGB(255, 206, 84) },
	{ id = "Bracelet",      weight = 0.12,  color = Color3.fromRGB(226, 232, 240) },
	{ id = "Anchor",        weight = 0.095, color = Color3.fromRGB(122, 110, 96) },
	{ id = "Camera",        weight = 0.075, color = Color3.fromRGB(38, 40, 48) },
	{ id = "Necklace",      weight = 0.060, color = Color3.fromRGB(240, 238, 228) },
	{ id = "Pearl",         weight = 0.048, color = Color3.fromRGB(248, 242, 232) },

	-- LEGENDARY : the flattening starts here. 135/OneIn would put GoldBar at
	-- 0.0225 and the Meteorite at 0.00009; these are lifted so the top of the
	-- beach is reachable in a session rather than in a hundred hours.
	{ id = "GoldBar",       weight = 0.036, color = Color3.fromRGB(255, 196, 42) },
	{ id = "Skull",         weight = 0.026, color = Color3.fromRGB(226, 216, 196) },
	{ id = "Trident",       weight = 0.019, color = Color3.fromRGB(255, 214, 92) },
	{ id = "Diamond",       weight = 0.014, color = Color3.fromRGB(196, 240, 255) },
	{ id = "Rolex",         weight = 0.010, color = Color3.fromRGB(255, 220, 120) },

	-- MYTHIC : about one find in seven thousand, which against Ashfall's own
	-- Mythic (one in eleven thousand) makes the home beach the KINDEST place to
	-- chase one. That is on purpose -- it is the one field a player can always
	-- reach, on any tide, without a ferry.
	{ id = "Chest",         weight = 0.012, color = Color3.fromRGB(120, 80, 44) },
	{ id = "Crown",         weight = 0.006, color = Color3.fromRGB(255, 214, 92) },
	{ id = "Meteorite",     weight = 0.003, color = Color3.fromRGB(74, 66, 84) },
}

-- What CTB_Client treats as worth a bigger pop at pickup (`def.value >= this`).
--
-- 30 was measured against the seven-row table's HAND-WRITTEN values, where only
-- Glasses, Watch and Phone cleared it. Against the catalogue's real prices it
-- would fire on a seashell, a flip-flop and everything above -- roughly one find
-- in ten, which is not a moment, it is a texture. 60 puts it back where it was:
-- the crusted set and nothing else, about one find in fourteen.
Config.RARE_VALUE = 60

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

----------------------------------------------------------------
-- THE DESERT'S OWN POOL
--
-- The dunes had exactly the vault's problem, one island earlier and less
-- obviously: raking a desert at the foot of a pyramid turned up soda cans,
-- plastic bottles, sunglasses and a lost phone, because every field without an
-- itemPool falls through to Config.ITEMS -- which is beach litter, and is named
-- for a beach.
--
-- What comes out of the sand out here is dig spoil and caravan leavings:
-- potsherds and mud brick at the bottom, and buried relics from Rare up. The
-- ids live in Modules.ItemConfig tagged DUNE -- see the note on that block for
-- why they ARE crusted where the tomb's are not, and why every crusted one
-- weighs the same.
--
-- THE ONLY NUMBERS THIS TABLE OWNS ARE THE PICK WEIGHTS, exactly as with the
-- tomb's. Value, tier and display name are read off the catalogue by
-- resolvePools below; a second hand-kept copy of a price is the drift this file
-- already warns about twice.
--
-- The weights run roughly as 1/OneIn and flatten at the top, so the ladder
-- still feels like a ladder and the best three pieces are an event. Note the
-- crusted half of this table is additionally multiplied by the island's
-- encasedScale in weightsFor, so these are the numbers BEFORE that 1.0.
----------------------------------------------------------------
Config.DUNE_ITEMS = {
	{ id = "Potsherd",        weight = 30,   color = Color3.fromRGB(178, 96, 62) },
	{ id = "MudBrick",        weight = 24,   color = Color3.fromRGB(190, 148, 96) },
	{ id = "PalmFrond",       weight = 20,   color = Color3.fromRGB(158, 146, 84) },
	{ id = "FrayedRope",      weight = 15,   color = Color3.fromRGB(196, 168, 118) },
	{ id = "BleachedBone",    weight = 12,   color = Color3.fromRGB(238, 230, 206) },
	{ id = "ReedBasket",      weight = 10,   color = Color3.fromRGB(206, 172, 104) },
	{ id = "ClayLamp",        weight = 8,    color = Color3.fromRGB(198, 150, 96) },
	{ id = "KohlVial",        weight = 6,    color = Color3.fromRGB(92, 120, 132) },
	{ id = "CopperPin",       weight = 5,    color = Color3.fromRGB(176, 118, 74) },
	{ id = "PapyrusScrap",    weight = 4,    color = Color3.fromRGB(226, 206, 152) },
	{ id = "WadjetAmulet",    weight = 3,    color = Color3.fromRGB(70, 164, 178) },
	{ id = "ScribePalette",   weight = 2.4,  color = Color3.fromRGB(206, 166, 110) },
	{ id = "BronzeSickle",    weight = 1.8,  color = Color3.fromRGB(150, 166, 110) },
	{ id = "BastetIdol",      weight = 1.4,  color = Color3.fromRGB(60, 62, 72) },
	{ id = "ObsidianBlade",   weight = 1.1,  color = Color3.fromRGB(38, 34, 44) },
	{ id = "TurquoiseScarab", weight = 0.8,  color = Color3.fromRGB(60, 178, 166) },
	{ id = "GoldCartouche",   weight = 0.55, color = Color3.fromRGB(255, 206, 84) },
	{ id = "FalconPendant",   weight = 0.35, color = Color3.fromRGB(246, 202, 90) },
	{ id = "LapisCollar",     weight = 0.22, color = Color3.fromRGB(40, 78, 150) },
	{ id = "RoyalSealRing",   weight = 0.12, color = Color3.fromRGB(255, 214, 110) },
	{ id = "SolarBarque",     weight = 0.06, color = Color3.fromRGB(255, 220, 104) },
	{ id = "SphinxFragment",  weight = 0.02, color = Color3.fromRGB(214, 178, 120) },
}

Config.ISLANDS[2].itemPool = Config.DUNE_ITEMS

----------------------------------------------------------------
-- ASHFALL ISLE'S OWN POOL
--
-- The third field to get one, for the third time for the same reason: without
-- an itemPool a field falls through to Config.ITEMS, and Config.ITEMS is beach
-- litter named for a beach. Raking black volcanic sand at the foot of a live
-- cone should not turn up a pizza box.
--
-- What this island produces is three things at once, which is what makes it the
-- last one: the tideline junk any beach has, the leavings of people who come
-- here to climb something, and the minerals the mountain itself manufactures --
-- pumice, obsidian, sulphur, peridot. The ids live in Modules.ItemConfig tagged
-- ASH; see the note on that block for why they are crusted where the tomb's are
-- not.
--
-- THE ONLY NUMBERS THIS TABLE OWNS ARE THE PICK WEIGHTS, exactly as with the
-- other two. Value, tier and display name are read off the catalogue by
-- resolvePools below.
--
-- Weights run roughly as 1/OneIn and flatten at the top, the same curve the
-- desert's uses, so the ladder still feels like a ladder and the last three
-- pieces are an event rather than a rounding error. The crusted half is
-- additionally multiplied by the island's encasedScale in weightsFor, so these
-- are the numbers BEFORE that 1.0.
----------------------------------------------------------------
--[[
	SIX OF THESE ARE NEW AND ALL SIX ARE AT THE CHEAP END, which is the correction
	rather than the addition. See the note on the ASH block in Modules.ItemConfig:
	the pool shipped with every volcanic find at Rare and above and the first
	thirteen rows made up mostly of camping gear, so the island's own theme was
	carried entirely by items hardly anybody saw.

	WEIGHTS STILL RUN ROUGHLY AS 1/OneIn and still flatten at the top, so the
	ladder is unchanged in shape -- there is simply more in the first two rungs of
	it. Note these are RELATIVE within this pool: pickItem normalises by the total,
	so adding six rows dilutes every other row in proportion and no single item's
	share had to be re-typed.
]]
Config.ASH_ITEMS = {
	{ id = "PumiceChunk",    weight = 30,   color = Color3.fromRGB(148, 142, 140) },
	{ id = "ScoriaChunk",    weight = 27,   color = Color3.fromRGB(96, 52, 44) },
	{ id = "ScorchedPlank",  weight = 24,   color = Color3.fromRGB(58, 50, 48) },
	{ id = "AshedCan",       weight = 20,   color = Color3.fromRGB(150, 146, 142) },
	{ id = "CinderClinker",  weight = 18,   color = Color3.fromRGB(74, 68, 70) },
	{ id = "MeltedVisor",    weight = 15,   color = Color3.fromRGB(96, 88, 96) },
	{ id = "GlassTear",      weight = 13,   color = Color3.fromRGB(26, 24, 32) },
	{ id = "BlackSeaGlass",  weight = 12,   color = Color3.fromRGB(34, 32, 40) },
	{ id = "BasaltChip",     weight = 11,   color = Color3.fromRGB(70, 66, 74) },
	{ id = "FrayedGuyLine",  weight = 10,   color = Color3.fromRGB(206, 164, 86) },
	{ id = "TrailWrapper",   weight = 8,    color = Color3.fromRGB(214, 178, 74) },
	{ id = "VentCap",        weight = 7,    color = Color3.fromRGB(170, 110, 62) },
	{ id = "BurstFloat",     weight = 6,    color = Color3.fromRGB(232, 112, 54) },
	{ id = "AshGlazedShard", weight = 5.5,  color = Color3.fromRGB(158, 150, 140) },
	{ id = "CrackedFin",     weight = 5,    color = Color3.fromRGB(46, 120, 150) },
	{ id = "ObsidianFlake",  weight = 4,    color = Color3.fromRGB(28, 26, 34) },
	{ id = "HikersCompass",  weight = 3,    color = Color3.fromRGB(188, 190, 196) },
	{ id = "AshFulgurite",   weight = 2.7,  color = Color3.fromRGB(88, 80, 96) },
	{ id = "SulphurCrystal", weight = 2.4,  color = Color3.fromRGB(232, 208, 72) },
	{ id = "ScaldedThermos", weight = 1.8,  color = Color3.fromRGB(160, 42, 40) },
	{ id = "VolcanicBomb",   weight = 1.4,  color = Color3.fromRGB(52, 44, 48) },
	{ id = "PelesHair",      weight = 1.1,  color = Color3.fromRGB(196, 178, 120) },
	{ id = "PeridotNodule",  weight = 0.8,  color = Color3.fromRGB(126, 196, 88) },
	{ id = "LavaTubePearl",  weight = 0.65, color = Color3.fromRGB(52, 46, 54) },
	{ id = "ObsidianMirror", weight = 0.55, color = Color3.fromRGB(32, 30, 38) },
	{ id = "EmberOpal",      weight = 0.35, color = Color3.fromRGB(255, 142, 68) },
	{ id = "AshcastIdol",    weight = 0.22, color = Color3.fromRGB(198, 192, 182) },
	{ id = "CalderaCrown",   weight = 0.12, color = Color3.fromRGB(60, 54, 58) },
	{ id = "FirebirdPlume",  weight = 0.06, color = Color3.fromRGB(255, 168, 54) },
	{ id = "HeartOfAshfall", weight = 0.02, color = Color3.fromRGB(255, 96, 40) },
}

Config.ISLANDS[5].itemPool = Config.ASH_ITEMS

--[[
	AND THE CHAMBER UNDER IT RAKES THE SAME TABLE, which is the point rather
	than a saving.

	The finds in a lava tube should be the finds on the black strand thirty
	studs above it: it is the same geology, and the rarest row in this table --
	HeartOfAshfall, weight 0.02 -- is the thing hanging over the well at the far
	end of that room, which is where it got its name. A pool of its own would
	have to invent a second set of volcanic junk that meant nothing, and would
	quietly halve how often anybody ever sees the Heart.
]]
Config.ISLANDS[7].itemPool = Config.ASH_ITEMS

--[[
	SAKURA COVE'S POOL.

	The cove was the one destination still raking the BEACH's table: its row set
	a litterSet and never an itemPool, so the props on the ground were Japanese
	and everything the sifter turned up was a crushed can. Twelve hand-picked
	meshes of ramen bowls and fox masks, and then a pizza box out of the sand.

	Weights are relative and are the numbers BEFORE the row's encasedScale of
	1.0 is applied in weightsFor, exactly as the desert's and Ashfall's are.
	The curve is the ash set's, so the cove paces like the island it sits
	beside rather than needing its own tuning pass.
]]
Config.COVE_ITEMS = {
	{ id = "Chopsticks",   weight = 30,    color = Color3.fromRGB(226, 206, 168) },
	{ id = "PaperCup",     weight = 24,    color = Color3.fromRGB(248, 226, 232) },
	{ id = "SquidSkewer",  weight = 19,    color = Color3.fromRGB(206, 178, 120) },
	{ id = "OnigiriWrap",  weight = 13,    color = Color3.fromRGB(46, 54, 48) },
	{ id = "RamenLid",     weight = 10,    color = Color3.fromRGB(238, 232, 220) },
	{ id = "GachaCapsule", weight = 8,     color = Color3.fromRGB(120, 196, 232) },
	{ id = "PaperFan",     weight = 6.5,   color = Color3.fromRGB(240, 238, 228) },
	{ id = "SakeCap",      weight = 5,     color = Color3.fromRGB(214, 206, 190) },
	{ id = "CharmStrap",   weight = 4,     color = Color3.fromRGB(226, 86, 86) },
	{ id = "Geta",         weight = 2.6,   color = Color3.fromRGB(178, 142, 96) },
	{ id = "Furin",        weight = 2.0,   color = Color3.fromRGB(180, 222, 230) },
	{ id = "Kokeshi",      weight = 1.5,   color = Color3.fromRGB(232, 198, 176) },
	{ id = "Ofuda",        weight = 1.1,   color = Color3.fromRGB(244, 240, 226) },
	{ id = "KitsuneMask",  weight = 0.8,   color = Color3.fromRGB(248, 242, 236) },
	{ id = "Tenugui",      weight = 0.6,   color = Color3.fromRGB(46, 86, 140) },
	{ id = "Netsuke",      weight = 0.4,   color = Color3.fromRGB(216, 190, 140) },
	{ id = "RakuBowl",     weight = 0.28,  color = Color3.fromRGB(72, 66, 64) },
	{ id = "InroCase",     weight = 0.18,  color = Color3.fromRGB(58, 42, 36) },
	{ id = "SuzuBell",     weight = 0.11,  color = Color3.fromRGB(198, 166, 86) },
	{ id = "Tsuba",        weight = 0.06,  color = Color3.fromRGB(70, 68, 74) },
	{ id = "MakieBox",     weight = 0.03,  color = Color3.fromRGB(28, 24, 26) },
	{ id = "Magatama",     weight = 0.015, color = Color3.fromRGB(96, 180, 140) },
}

Config.ISLANDS[4].itemPool = Config.COVE_ITEMS

local byId, totalWeight = {}, 0
for _, it in ipairs(Config.ITEMS) do
	byId[it.id] = it
	totalWeight += it.weight
end

-- Forward-declared: it needs the lazy catalogue handle further down, and these
-- two lookups need it. Not a global -- a stray global in a shared module is one
-- typo away from being someone else's.
local resolvePools

-- Both go through resolveTomb (below) so a vault find is a known item to every
-- caller -- CTB_Client's pop effect reads `def.color` and `def.value` off this
-- and bails out entirely on an id it does not recognise, which would have made
-- every treasure come out of the floor in total silence.
function Config.item(id)
	resolvePools()
	return byId[id]
end

function Config.value(id)
	resolvePools()
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
-- One lazy handle on the catalogue, shared by `encased` and `resolvePools`.
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

-- Names and prices for every off-beach pool, filled in from the catalogue on
-- first ask for the same reason `encased` is lazy: a place without
-- Modules.ItemConfig has to still load, and it does -- it just gets the id as
-- the name and a floor price, rather than an error three lines into a rake.
--
-- Both pools go through here rather than the tomb's alone. Config.item and
-- Config.value are what CTB_Client's pop effect reads to colour and price a
-- find, and it BAILS OUT ENTIRELY on an id it does not recognise -- so a dune
-- pool left out of this would have every desert find come out of the sand in
-- total silence, which is exactly the bug the tomb pool was added here to fix.
local poolsResolved = false
function resolvePools()   -- forward-declared above
	if poolsResolved then
		return
	end
	poolsResolved = true
	local ItemConfig = itemCatalogue()
	-- Config.ITEMS IS IN THIS LIST NOW, and its absence was a live bug rather than
	-- an omission: the beach's rows carried hand-written label and value columns
	-- that had drifted from the catalogue the till actually pays out of (Can was
	-- quoted at 6 and sold for 11, Watch at 55 and sold for 112). Every other pool
	-- reads its names and prices from ItemConfig for exactly that reason; the
	-- beach was the one still keeping a second copy.
	for _, pool in ipairs({ Config.ITEMS, Config.TOMB_ITEMS, Config.DUNE_ITEMS, Config.ASH_ITEMS, Config.COVE_ITEMS }) do
		for _, it in ipairs(pool) do
			local def = ItemConfig and ItemConfig.get(it.id)
			if def then
				it.label = def.DisplayName
				-- The midpoint of the roll band. Only ever a DISPLAY figure -- what
				-- a find is actually worth is rolled once, by ValueCalculator, on
				-- the server, and nothing here may be a second opinion on it.
				it.value = math.floor((def.ValueRange[1] + def.ValueRange[2]) * 0.5 + 0.5)
			else
				warn(string.format("[CTB] pooled item %q is not in ItemConfig", tostring(it.id)))
				it.label = it.id
				it.value = Config.RARE_VALUE
			end
			byId[it.id] = it
		end
	end
end

local encasedById
local function encased(id: string): boolean
	if not encasedById then
		encasedById = {}
		local ItemConfig = itemCatalogue()
		if ItemConfig then
			for _, pool in ipairs({ Config.ITEMS, Config.TOMB_ITEMS, Config.DUNE_ITEMS, Config.ASH_ITEMS, Config.COVE_ITEMS }) do
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
