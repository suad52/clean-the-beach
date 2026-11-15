-- Clean the Beach :: authoritative sand field, bag, selling and upgrades.
--
-- The beach is real Terrain, and everyone shares one physical beach -- but each
-- player has their OWN raked state on it. Someone who has cleared half the map
-- does not hand the next person to join a half-finished one; every player sees a
-- full unraked field and works it down themselves.
--
-- See the grid-state block below for how that is done and what it costs.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CTB = ReplicatedStorage:WaitForChild("CTB")
local Config = require(CTB:WaitForChild("Config"))
local Net = CTB:WaitForChild("Net")

local Lighting = game:GetService("Lighting")
local Terrain = workspace.Terrain
local beach = workspace:WaitForChild("Beach")

-- Own the look at runtime. A Studio weather plugin in this place keeps dropping a
-- hazy skybox into Lighting, which washes the sand out to sepia; re-applying on
-- start means the running game always looks the same regardless.
--
-- This used to defend against that by destroying every Sky on start, which also
-- destroyed the tropical one the place is built around. Instead the intended
-- skybox ids are re-asserted, so whichever Sky is present ends up being the right
-- one and a stray second copy is dropped.
-- Anime sky: towering illustrated cumulus over a deep saturated blue.
--
-- These six faces were ALREADY in this place, sitting in Lighting as a Sky named
-- "Stylized" -- applyLook was overwriting them with the photographic tropical ids
-- on every server start, which is why Edit mode and a running server disagreed
-- about what the sky looked like. The table is the single source of truth; editing
-- Lighting alone looks right until you press Play.
local SKY = {
	Up = "rbxassetid://18351377189", Dn = "rbxassetid://18351374919",
	Lf = "rbxassetid://18351376469", Rt = "rbxassetid://18351376457",
	Ft = "rbxassetid://18351376800", Bk = "rbxassetid://18351376859",
}

local function applyLook()
	local sky = Lighting:FindFirstChildOfClass("Sky")
	if not sky then
		sky = Instance.new("Sky")
		sky.Parent = Lighting
	end
	sky.Name = "Sky"
	sky.SkyboxUp, sky.SkyboxDn = SKY.Up, SKY.Dn
	sky.SkyboxLf, sky.SkyboxRt = SKY.Lf, SKY.Rt
	sky.SkyboxFt, sky.SkyboxBk = SKY.Ft, SKY.Bk
	sky.SunAngularSize = 15
	sky.MoonAngularSize = 9
	sky.StarCount = 0
	for _, o in ipairs(Lighting:GetChildren()) do
		if o:IsA("Sky") and o ~= sky then o:Destroy() end
	end

	-- Noon, and locked there -- see the guard under applyLook.
	--
	-- Worth knowing what that costs, because this used to sit at 16.4 on purpose:
	-- a LOW sun is what made the sand read. Every bump on the messy surface threw
	-- a long shadow across it, so unraked sand looked visibly rough while a raked
	-- strip had nothing left to cast one and went flat. An overhead sun shortens
	-- every one of those shadows and flattens the difference.
	--
	-- Ambient stays low and ShadowSoftness stays crisp to keep hold of what
	-- shadow is left. If the rough/smooth contrast ever reads too weak, the dial
	-- to reach for is GeographicLatitude, NOT the clock: a higher latitude drops
	-- the sun down the sky while the time stays exactly 12:00.
	Lighting.ClockTime = 12
	-- Left at 16. Dropping the sun to sharpen the rough/smooth contrast was tried
	-- properly and does not work, so it is not worth the warmer, longer-shadowed
	-- look it costs elsewhere.
	--
	-- Two things worth recording. Latitude does NOT map to elevation one for one:
	-- Roblox holds a fixed ~23.5 degree declination, so noon elevation is
	-- 90 - |lat - 23.5|. Latitude 50 is still 63 degrees up and it takes 78 to
	-- reach 35 (measured). And even at 35 the sand does not shade itself, because
	-- the messy field only varies ~1.2 studs across 4-stud voxels -- about a 17
	-- degree slope, far too shallow to cast a shadow at any sun angle. Terrain
	-- resolution, not lighting, is the limit on how rough the sand can look.
	Lighting.GeographicLatitude = 16
	Lighting.Brightness = 3.1
	Lighting.ExposureCompensation = 0.05
	Lighting.OutdoorAmbient = Color3.fromRGB(122, 126, 132)
	Lighting.Ambient = Color3.fromRGB(44, 45, 50)
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.12       -- crisp, so small bumps still read
	Lighting.EnvironmentDiffuseScale = 0.7
	Lighting.EnvironmentSpecularScale = 0.8

	--[[
		ONE OF EACH, and the prune loop is not tidiness -- it is the fix for a bug
		that silently disabled every atmospheric grade in this game.

		Lighting was holding TWO Atmosphere children, both named "Atmosphere".
		Every script in the place resolves it with FindFirstChildOfClass, which
		returns the FIRST -- this function, Island2_Client, Vault_Client and
		Island3_Client all wrote that one. The RENDERER used the second. Proven
		both ways: zeroing the second one's Density removed all fog, while setting
		the first to Density 1.0 with a pure green Decay changed nothing at all.

		So the beach's tropical haze, the dunes' heat shimmer and the cove's golden
		hour were all being written to an object nothing drew, and the place
		rendered under a stale leftover (Density 0.442, Haze 0.00) for months.
		FindFirstChildOfClass cannot detect that. Only destroying the spares can,
		and the Sky block above has been doing exactly this for the same reason.
	]]
	local function ensure(class: string, name: string)
		local o = Lighting:FindFirstChildOfClass(class)
		if not o then
			o = Instance.new(class)
			o.Parent = Lighting
		end
		o.Name = name
		for _, spare in ipairs(Lighting:GetChildren()) do
			if spare ~= o and spare.ClassName == class then
				spare:Destroy()
			end
		end
		return o
	end

	-- Thinner air than the tropical haze this replaces. Density 0.32 / Haze 1.4 was
	-- tuned to push a PHOTOGRAPHIC horizon back, and it does painted cumulus no
	-- favours -- illustrated clouds live or die on their edges, so the haze comes
	-- down and Glare comes up to keep the sun reading as a source, not a flat disc.
	--
	-- Note what this moves downstream. Island2/3/4_Client and Vault_Client all sample
	-- these values LIVE at boot as HOME_ATMO and lerp away from them, so the baseline
	-- carries into every island grade. Their own targets are absolute and unchanged,
	-- which means the steps get re-proportioned: the cove is now a SMALLER move from
	-- home than it was (0.24/0.9 -> 0.28/0.75, where it used to be 0.32/1.4 -> the
	-- same place), and the dunes and ash are bigger ones. If the cove stops reading
	-- as its own place, COVE_ATMO in Island3_Client is the dial, not this.
	local atmo = ensure("Atmosphere", "Atmosphere")
	atmo.Density = 0.24
	atmo.Offset = 0.25
	atmo.Glare = 0.35
	atmo.Haze = 0.9
	atmo.Color = Color3.fromRGB(208, 226, 240)
	atmo.Decay = Color3.fromRGB(78, 128, 190)

	local bloom = ensure("BloomEffect", "Bloom")
	bloom.Intensity = 0.70
	bloom.Size = 24
	bloom.Threshold = 1.5

	local rays = ensure("SunRaysEffect", "SunRays")
	rays.Intensity = 0.14
	rays.Spread = 0.9

	-- the sand and sea carry the whole palette, so a little extra saturation and
	-- contrast does more here than any amount of extra brightness
	local cc = ensure("ColorCorrectionEffect", "ColorCorrection")
	cc.Brightness = 0
	cc.Contrast = 0.14
	cc.Saturation = 0.26
	cc.TintColor = Color3.fromRGB(255, 252, 246)

	Terrain.WaterColor = Color3.fromRGB(28, 152, 180)
	Terrain.WaterReflectance = 0.5
	Terrain.WaterTransparency = 0.32
	Terrain.WaterWaveSize = 0.12
	Terrain.WaterWaveSpeed = 6

	-- These tints DO still apply if a custom MaterialVariant is bound to either
	-- material (verified: tinting Snow red turns a bound variant red). But a tint
	-- can only ever darken, so it cannot lift a dark ColorMap up to match the sand.
	--[[
		TWO SANDS: the beach you have not touched, and the beach you have.

		Sand is the untouched material and Snow is what a raked column is swapped
		to (Config.TERRAIN_DEFORMS, matMessy/matClean). Both are painted a sand
		colour, and RAKED is only one step off untouched -- combed and level, so
		it catches the light a little more evenly. It is meant to read as the
		SAME BEACH, worked.

		IT USED TO BE 240,226,187, WHICH IS ALMOST WHITE, and a cleared block
		looked like snow or bleached ground sitting in the middle of the sand.
		That was the right call when the tone was the only thing marking a raked
		lane: the two materials had been painted identically, the swap changed
		nothing but the surface grain, and grain alone does not read at gameplay
		distance -- so the feature got switched off for looking like nothing and
		came back by being pulled far apart in colour instead.

		WHAT MARKS A WORKED LANE NOW is this step of tone, the smoother surface
		Snow gives it, and -- mostly -- the litter simply not being there any
		more. That last one does more work than it sounds like: a cleared block
		reads as cleared from right across the beach because the junk stops.

		A directional comb-mark layer was built to carry this instead, which is
		what let the tone come in. It was taken out again for looking wrong on
		the beach. The narrow gap stayed, because a near-white beach was the
		worse of the two problems. If raked ground ever reads too weakly, this
		pair is the dial -- but open it a step at a time and look at it, because
		wide is exactly what made the sand turn white before.

		LIFTING AT ALL IS ONLY POSSIBLE BECAUSE OF WHICH MATERIAL IS WHICH. A
		material tint can only DARKEN (see the note above), so a paler raked tone
		works solely because Snow's base is near-white and has the headroom. Swap
		the roles -- clean on a dark base -- and the raked strip cannot be made to
		lift, only to go muddier.

		THAT RULE IS ALSO WHY NO MaterialVariant IS BOUND TO Snow. A groove-
		textured variant was built and tried here (parallel comb lines, to match
		photo reference of a real beach groomer) and it worked -- but every
		colour map's own tone becomes the ceiling, so raked ground could only
		ever come out DARKER than the sand around it. The comb marks are drawn on
		top of the terrain instead, one transparent tile per column, which is what
		lets them be directional as well as tone-free.
	]]
	local SAND = Color3.fromRGB(203, 177, 106)
	local RAKED = Color3.fromRGB(213, 189, 124)
	Terrain:SetMaterialColor(Enum.Material.Sand, SAND)
	Terrain:SetMaterialColor(Enum.Material.Snow, RAKED)
	Terrain:SetMaterialColor(Enum.Material.Limestone, SAND)

	-- The desert island's pair, same rule and the same narrow gap. Terrain
	-- material colours are global, so Sandstone/Salt being tinted here is exactly
	-- what gives the Dunes a palette the beach cannot reach.
	--
	-- Pulled in from 246,214,165 alongside the beach, and for the same reason: a
	-- raked stretch does not have to be bleached to read as raked. Kept to the
	-- same step off untouched that the beach uses, so the two fields agree about
	-- how much a worked lane is supposed to lift.
	local DESERT = Color3.fromRGB(219, 165, 94)
	local DESERT_RAKED = Color3.fromRGB(229, 177, 112)
	Terrain:SetMaterialColor(Enum.Material.Sandstone, DESERT)
	Terrain:SetMaterialColor(Enum.Material.Salt, DESERT_RAKED)
	-- The outcrops and the pyramid's bedrock, warm enough to belong to the same
	-- desert but dark enough to read as stone against it.
	Terrain:SetMaterialColor(Enum.Material.Rock, Color3.fromRGB(158, 118, 76))
	Terrain:SetMaterialColor(Enum.Material.Slate, Color3.fromRGB(134, 100, 68))

	-- Sakura Cove's pair, and the same global-tint rule for the third time:
	-- Ground and Asphalt are tinted here because that is the ONLY way the cove
	-- gets a pink the beach and the dunes cannot reach. Both are spoken for
	-- place-wide now -- nothing else in this game, terrain or prop, may use
	-- either one for anything.
	--
	-- WIDER APART THAN THE TWO PAIRS ABOVE, and knowingly so. These tones were
	-- measured on a test rig against the beach's EARLIER, wider split
	-- (203,177,106 -> 240,226,187) and beat it at the play camera.
	--
	-- The beach and the dunes have since been pulled in, because near-white sand
	-- read as snow lying on the beach. This pair was LEFT WIDE rather than moved
	-- with them: the cove is a pink, deliberately stylised palette and nobody has
	-- said it reads bleached, so there was nothing here to fix. If it ever does,
	-- narrowing COVE_RAKED toward COVE is the move -- read the beach block above
	-- first, it is the same argument.
	--
	-- PALER WHEN RAKED, but NOT for the reason the beach block gives. Snow works
	-- up there because its base is near-white; Asphalt's base is nearly black
	-- (80,84,84) and it lifts to a blush anyway. Measured: a material tint
	-- REPLACES the albedo rather than multiplying it -- eight materials given one
	-- identical tint all rendered the same tone, and Mud, the darkest of them,
	-- took a pure green. What actually buys a legible raked cell is which
	-- material wins the terrain blend, and Asphalt beats Ground. Swap the two
	-- and the raked cells vanish entirely; THAT is the constraint here, not the
	-- base colour.
	--
	-- Do not lighten COVE_RAKED any further. At 255,232,238 Asphalt blew out to
	-- featureless white under the Brightness 3.1 + Bloom(0.55, 1.6) set above and
	-- lost the grain the smooth-against-grainy read depends on. And keep COVE
	-- warm: blue much above 130 drags the sand toward mauve at distance under
	-- this atmosphere's cool Decay (92,124,160), which is why it is 124.
	local COVE = Color3.fromRGB(206, 104, 124)
	local COVE_RAKED = Color3.fromRGB(255, 214, 222)
	Terrain:SetMaterialColor(Enum.Material.Ground, COVE)
	Terrain:SetMaterialColor(Enum.Material.Asphalt, COVE_RAKED)

	--[[
		ASHFALL ISLE'S THREE, and the same global-tint rule for the fourth time:
		Basalt and Mud are tinted here because that is the ONLY way the west island
		gets a black the other four cannot reach. Both are spoken for place-wide now,
		and so is CrackedLava -- nothing else in this game may lay any of the three
		as TERRAIN.

		THIS IS THE ONE PAIR IN THE FILE THAT RUNS DARK, AND IT HAS THE OPPOSITE
		FAILURE MODE TO EVERY OTHER ONE. The beach, the dunes and the cove all had to
		be pulled BACK from near-white, because a bleached field reads as snow. Black
		sand's danger is the other end: at anything under about (40,36,40) the field
		stops being a surface and becomes a hole in the frame -- no grain, no shading,
		and every prop standing on it loses its silhouette because the prop is the
		only thing with a tone. 56,50,54 is dark enough to read as basalt sand at
		midday under Brightness 3.1 and light enough to still show the sifter's
		channel walls.

		BASALT IS THE MOUNTAIN, NOT THE BEACH, AND THAT IS A CORRECTION.

		This block had them the other way round: Basalt as the sand and Mud as its
		dormant raked partner. Poured and measured, Basalt renders its surface up
		to 0.69 studs below the fill and never twice the same -- it DISPLACES, so
		a field made of it is lumpy rock rather than sand with a rocky texture,
		and 6400 cells of it read exactly as "rock everywhere". Mud measured dead
		flat (spread 0.00, identical to the Sand the beach rakes). The full table
		is on ISLANDS[5] in CTB.Config.

		So Mud takes the black-sand tone and Basalt takes a paler grey-brown and
		goes to the cone, the west terrace and the sea stacks -- where a surface
		that refuses to lie flat is worth having.

		MUD IS ALSO WHAT THE CRUST IS MADE OF (Config.CRUST builds the loose layer
		out of the island's matMessy), so this tint is doing double duty: the sand
		you look at and the sand you wade in are the same colour, one step apart.

		BASALT'S TINT IS NOT A RAKED-PARTNER STEP. Ashfall is a DUG field
		(crust = true) and Config.terrainSwapFor returns false for any island with
		a crust, so matClean is never written to a voxel out there. Its colour is
		free to be the mountain's, and it is -- deliberately well clear of the
		sand, because the cone needs a silhouette against the beach it stands on.

		CRACKEDLAVA is the top quarter of the cone and the three flows. Tinted a
		scorched red-brown rather than the hot orange it ships as: the tint
		REPLACES the albedo (measured -- see the cove block above), so a bright
		tint would flatten the whole summit to one glowing tone and leave nothing
		for the actual molten parts to be brighter than. What glows out there is
		Neon; this is the rock it cooled into.
	]]
	local ASH = Color3.fromRGB(56, 50, 54)
	local ASH_ROCK = Color3.fromRGB(84, 76, 78)
	Terrain:SetMaterialColor(Enum.Material.Mud, ASH)
	Terrain:SetMaterialColor(Enum.Material.Basalt, ASH_ROCK)
	Terrain:SetMaterialColor(Enum.Material.CrackedLava, Color3.fromRGB(108, 52, 38))

	--[[
		THE INNER SHRINE'S PAIR, and the same global-tint rule for the fifth time:
		WoodPlanks and Concrete are tinted here because that is the only way the
		room behind the cove's shrine door gets a floor the other five cannot
		reach. Both are spoken for place-wide now as TERRAIN -- a prop may still
		use either material, since a terrain tint does not touch parts.

		BOTH WARM AND CLOSE TOGETHER, because this pair is the one that is only
		ever seen INDOORS. The beach, the dunes and the cove all had to be pulled
		back from near-white after reading as snow at midday; a hall lit by its own
		lanterns has the opposite exposure and can afford a narrower step. The
		swept tone is a lift of about a third, which is what a mopped board looks
		like next to a dusty one.

		KEPT OFF THE TOP OF THE RANGE anyway, per the rule at the head of this
		function -- 168 is about 55% luma, well clear of the ceiling that turned
		the sakura plaza to white paper.
	]]
	local SHRINE_BOARD = Color3.fromRGB(122, 86, 58)
	local SHRINE_SWEPT = Color3.fromRGB(168, 126, 88)
	Terrain:SetMaterialColor(Enum.Material.WoodPlanks, SHRINE_BOARD)
	-- BRICK, NOT CONCRETE, AND IT MOVED WITH Config's matClean. The shrine's raked
	-- material changed because WoodPlanks -> Concrete measured as a 2.00-stud step
	-- in the floor -- see the long note on that pair in Config -- and Brick is flush
	-- with WoodPlanks. A tint replaces the albedo, so the swept COLOUR is unchanged.
	-- THIS LINE AND THAT ONE MOVE TOGETHER: disagree and the shrine's raked cells go
	-- untinted brick red while its unraked ones stay board brown.
	Terrain:SetMaterialColor(Enum.Material.Brick, SHRINE_SWEPT)

	--[[
		PENGUIN ISLAND'S PAIR, and the same global-tint rule for the sixth time:
		Glacier and Ice are tinted here because that is the ONLY way the arctic
		island gets a white the other five cannot reach. Both are spoken for
		place-wide now -- nothing else may lay either as TERRAIN. (The Frozen
		Wreck shares them, the way the Magma Chamber shares Ashfall's.)

		GLACIER IS THE SNOW, and it is the one pair in the file that WANTS to be
		pale -- so the ceiling every other block backs away from is the thing to
		watch here. 214,226,238 is about 88% luma with a cool cast: white enough
		to read as snow at noon under Brightness 3.1, and still short of the
		255-level that blew the cove's raked cells out to paper. The crust parts
		are NOT tinted from this (they are real Snow, see Config's crustMat) so
		the channel walls keep their own edge whatever this reads.

		ICE IS THE FROZEN SEA, poured as pack ice out past the shore. Measured
		bumpy (0.35 of displacement), which on a field would be a defect and on
		a frozen ocean is the whole texture. Tinted a pale cold blue so the sheet
		reads as ice against the snow rather than as more snow.
	]]
	local ARCTIC_SNOW = Color3.fromRGB(214, 226, 238)
	local ARCTIC_ICE = Color3.fromRGB(150, 196, 226)
	Terrain:SetMaterialColor(Enum.Material.Glacier, ARCTIC_SNOW)
	Terrain:SetMaterialColor(Enum.Material.Ice, ARCTIC_ICE)
end
applyLook()

-- LOCKED, not just set once. Nothing in the game runs a day/night cycle today,
-- so a single assignment would hold -- but locked is the requirement, and this
-- place already has a Studio plugin writing into Lighting behind the game's back
-- (see the skybox note at the top of applyLook), plus a saved ClockTime of 21:00
-- that disagrees with what the server sets. Re-asserting costs nothing:
-- assigning a property its current value does not re-fire Changed, so this
-- cannot feed itself.
local NOON = 12
Lighting:GetPropertyChangedSignal("ClockTime"):Connect(function()
	if Lighting.ClockTime ~= NOON then
		Lighting.ClockTime = NOON
	end
end)

-- One pad per island. The desert island's is appended once Island2Builder has
-- built it, at the bottom of this script; the sim loop reads the list every tick
-- so a pad arriving late is picked up on its own.
local sellPads = { beach:WaitForChild("SellArea"):WaitForChild("SellPad") }

-- The kiosk board is NOT written here any more. It is one shared sign in the
-- world, so a server-side write stamped whoever upgraded last onto everyone's
-- copy of it -- the player next to you could read your sifter level straight off
-- the board. CTB_Client writes it locally from its own attributes instead.

local ISLANDS = Config.ISLANDS

----------------------------------------------------------------
-- Grid state
----------------------------------------------------------------
-- PER PLAYER, not per server.
--
-- Two things make a shared beach with private progress possible:
--
--   * The litter props were never shared. CTB_Client builds them locally, so
--     each player already had their own copy of every bottle and can sink them
--     on their own schedule.
--   * The raked LOOK is a material swap (Sand -> Snow) at an identical surface
--     height, and a client can write terrain locally without it replicating.
--     So the server lays down the all-messy baseline once at boot and never
--     touches the field again; every raked column after that is drawn by the
--     client that raked it, in its own copy of the terrain.
--
-- The height part is load-bearing. If messy and raked columns had different
-- heights, each player would be standing on a different surface and everyone
-- else's avatar would float or sink by up to a stud. Config.surfaceY returns
-- one height for both states precisely so the GEOMETRY stays shared and only
-- the MATERIAL is private.
--
-- What this costs: the server no longer owns how the sand looks, so a modified
-- client could paint itself a clean beach. It cannot pay itself for one. Finds,
-- weight, coins and the sell pad are all still server-authoritative, and the
-- server only ever credits a column it has not already marked raked for that
-- player -- so the exploit is a cosmetic lie told to nobody but yourself.
--
-- And it is now per player PER ISLAND. Each island in Config.ISLANDS gets its
-- own grid, so raking the beach flat leaves the desert exactly as untouched as
-- it was -- the two fields never share a cell, a find or a reset.
local rng = Random.new(Config.SEED + 991)

--[[
	ONE ROLL PER CELL, AND THE CELL COUNTS ARE NO LONGER SMALL.

	This runs per player per island on join, again on every tide turnover and
	again on every rebirth -- and a rebirth runs it for ALL SEVEN islands in one
	go. The cove is 9,216 cells now and Ashfall 25,600, so a rebirth is ~44,000
	draws where it used to be ~19,000.

	`yield` is false on the paths that cannot afford to be interrupted. A join and
	a rebirth can: nothing reads the grid until the client sends Ready. A tide
	turnover happens inside a task.delay that has already checked its generation
	counter, so it yields too -- but the CALLER re-checks after it returns.
]]
local SEED_YIELD_EVERY = 4096

local function seedItems(isl, g, yield: boolean?)
	for i = 1, isl.cells do
		-- The island goes in so the roll can honour its encasedScale: how often a
		-- find comes up as a crusted lump is per field, not global.
		g.itemAt[i] = (rng:NextNumber() < isl.itemChance) and Config.pickItem(rng, isl) or false
		if yield and i % SEED_YIELD_EVERY == 0 then
			task.wait()
		end
	end
end

local function newGrid(isl)
	local g = {
		clean = table.create(isl.cells, false),
		itemAt = table.create(isl.cells, false),   -- item id string, or false
		cleanCount = 0,
	}
	seedItems(isl, g)
	return g
end

local function newGrids()
	local t = {}
	for _, isl in ipairs(ISLANDS) do
		t[isl.id] = newGrid(isl)
	end
	return t
end

-- The shared starting point: every column of every field messy. Written once, at
-- boot. Anything the server writes here replicates to everybody and would wipe
-- out the private raked state each client has drawn on top of it, so nothing
-- else may call this.
--
-- Must run AFTER the islands' landmass terrain is filled, or the plateau fill
-- would bury the field it is supposed to sit flush with. See the bottom of this
-- script for the ordering.
--[[
	AND THE CAP, WHICH IS THE OTHER HALF OF WRITING A FIELD.

	Config.writeField rewrites the four voxel rows from Y_MIN = -8 to Y_MAX = +8
	and nothing else. That is fine for a square poured on flat ground and wrong
	for one poured over anything with a top above +8: the rewrite airs out y 4..8
	under it and leaves the rest of it HANGING over the columns the player is
	supposed to be raking, which is the exact failure both builders' clearOfField
	tests exist to prevent at placement time.

	The cove is where this became load-bearing. Its square went from 192 studs to
	384 and swallowed a dozen of the thirty-four decorative relief mounds that
	were poured, quite correctly, OUTSIDE the old one -- mounds whose tops reach
	y = 15. Nothing in the code knows where they are: they came out of a seeded
	scatter in a builder that no longer runs, and the island's terrain is frozen
	in the place file.

	So the fix is a blunt one, and blunt is right here: clear the airspace over
	the square, from Y_MAX up to the island's own capTo. It is one FillBlock, it
	is idempotent, it cannot reach below Y_MAX (so it can never touch a raked
	column or a field write), and it removes the CAUSE rather than papering over
	it.

	IT IS OPT-IN PER ISLAND, and that is not timidity. The three interiors are
	ROOMS: the vault, the shrine and the magma chamber all have rock CEILINGS
	sitting directly over their fields, and an unconditional cap would open every
	one of them to the sky. Only islands that carry `capTo` get it -- the cove and
	Ashfall, the two that were enlarged.
]]
local function capField(isl)
	local top = isl.capTo
	if type(top) ~= "number" or top <= Config.Y_MAX then
		return
	end
	Terrain:FillBlock(
		CFrame.new(isl.cx, (Config.Y_MAX + top) * 0.5, isl.cz),
		Vector3.new(isl.half * 2, top - Config.Y_MAX, isl.half * 2),
		Enum.Material.Air)
end

local function baselineField()
	for _, isl in ipairs(ISLANDS) do
		capField(isl)
		Config.writeField(Terrain, isl, 0, isl.grid - 1, 0, isl.grid - 1, function()
			return false
		end)
	end
end

-- The terrain throttle that used to live here is gone with the server's terrain
-- writes. The equivalent dirty-rectangle batching now runs on the client, in
-- CTB_Client's flushField -- see the note there.

--[[
	`messy` flips it: the columns still to DO rather than the ones already done.

	One function with a flag rather than two, and that is not only tidiness --
	this chunk is close enough to Luau's 200-locals-per-function ceiling that a
	second `local function` here is a real risk, and CTB_Client's remessField note
	records what going over it costs (the whole script stops compiling, not just
	the new line). A parameter is free.

	The messy half is only ever asked for when the answer is already known to be
	short -- see Config.LAST_FEW -- so its O(cells) walk runs a handful of times
	at the very end of a field, against the once-per-join the clean half costs.
]]
local function cleanIndices(isl, g, messy: boolean?): { number }
	local out = {}
	local want = not messy
	for i = 1, isl.cells do
		if (g.clean[i] == true) == want then
			table.insert(out, i)
		end
	end
	return out
end

-- Bag was full when we uncovered something: drop it back into a still-messy cell
-- of THAT PLAYER's grid, on the island it came from, so nothing is ever lost.
local function relocate(isl, g, itemId: string)
	-- The cheap path, and the one that answers almost every time: pick a cell at
	-- random, which keeps a reburied find scattered instead of always dropping it
	-- into the lowest free index -- i.e. the corner the player started from.
	for _ = 1, 60 do
		local j = rng:NextInteger(1, isl.cells)
		if not g.clean[j] and not g.itemAt[j] then
			g.itemAt[j] = itemId
			return
		end
	end

	--[[
		THE DETERMINISTIC FALLBACK, AND IT STOPPED BEING OPTIONAL WHEN THE FIELDS
		WENT TO 1.0.

		Sixty random draws used to be a formality. A field turned over at 0.75, so
		there were never fewer than a quarter of its cells still messy when this
		could run -- sixty misses in a row is 0.75^60, about three in a hundred
		million, and the bare `end` below was a fair place to give up.

		Every field is raked to its LAST column now (Config.ISLANDS[n].resetAt), so
		the interesting case is the one that never used to happen: a player five
		cells from finishing a 4,096 cell beach. Five messy cells in 4,096 makes a
		single draw a 1-in-819 shot and sixty of them still miss about 93% of the
		time -- and a miss here does not retry or warn, it drops the item on the
		floor. That is a find deleted out of the player's hands at exactly the
		moment they are most invested in the field.

		So when the dice fail, look properly. It is one pass over the grid, on a
		path that is already rare, and it cannot miss a cell that exists.

		If the scan comes back empty the item really is homeless -- every cell is
		either raked or already holding something -- and there is nothing to be
		done with it. That is the one true dead end, and it needs the field to be
		completely full rather than merely nearly finished.
	]]
	local candidates = {}
	for j = 1, isl.cells do
		if not g.clean[j] and not g.itemAt[j] then
			table.insert(candidates, j)
		end
	end
	if #candidates > 0 then
		g.itemAt[candidates[rng:NextInteger(1, #candidates)]] = itemId
	end
end

----------------------------------------------------------------
-- Player state
----------------------------------------------------------------
-- The sift/sell add-on. Everything CTB-specific about it lives in CTBBridge;
-- these five call sites are the only lines of CTB_Server that know it exists.
local Bridge = require(game:GetService("ServerScriptService"):WaitForChild("CTBBridge"))

-- The volcano's road, which is rakeable but is not a FIELD -- it is 34 rotated
-- parts climbing 186 studs, and Config's grid is flat, single-height and XZ-only.
-- It keeps its own state and its own bonus; see the header of that module for why
-- folding it into Ashfall's resetAt would be a way to brick the island.
local StairSrv = require(game:GetService("ServerScriptService"):WaitForChild("StairServer"))
-- Which field's tide puts the ash back. Read from the same module the stair's
-- geometry comes from, so the two can never disagree about which island it is on.
local StairIsland = require(CTB:WaitForChild("Stair")).ISLAND_ID

-- WHO OWNS THE QUICK SELL PASS, and the only answer this file is allowed to
-- act on. There is a replicated `OwnsQuickSell` attribute saying the same
-- thing and it is emphatically NOT what gets read here -- that one exists so
-- CTB_HUD can decide whether to draw a price or a sell button, and a client
-- cannot be asked to vouch for its own purchase.
local Passes = require(game:GetService("ServerScriptService"):WaitForChild("GamePassService"))

-- The onboarding's crusted-find guarantee, and its ONE call site is in the
-- sweep below. Everything about who is new, how many lumps they are owed and
-- which id to substitute lives in TutorialServer; this script only knows that
-- a find goes through it on the way out of the sand.
local Tutorial = require(game:GetService("ServerScriptService"):WaitForChild("TutorialServer"))

local state = {}

--[[
	WHERE A COLLECTED PIECE OF LITTER IS ALLOWED TO COME BACK.

	CTBBridge asks this before it re-seats one of TrashSeeder's props, so a piece
	can never respawn onto sand somebody has just raked clean -- which is the
	"but we already walked over that" half of a beach that would not stay
	finished. See the note beside setRakedQuery over there.

	THE GRIDS ARE PRIVATE, so there is no single answer to "is this cell clean".
	Your raked columns are yours, and the same square is still untouched sand for
	the person standing next to you. This gives the conservative one: a spot is
	refused only when EVERY player with work on that field has already cleared
	it, so nobody watches rubbish reappear on ground they cleaned, and one player
	finishing their beach cannot starve everyone else's.

	MEASURED BY PROGRESS, NOT BY WHERE THEY ARE STANDING. Asking who is on the
	field right now would count nobody during the walk to the sell pad -- which
	is exactly when a respawn lands -- and the player would come back to litter
	sitting on the lane they had just cleared. cleanCount goes back to zero on
	the tide, so a turned-over field is open ground again.
]]
Bridge.setRakedQuery(function(islId: number, idx: number): boolean
	local anyone = false
	for _, st in pairs(state) do
		local g = st.grids[islId]
		if g and g.cleanCount > 0 then
			anyone = true
			if not g.clean[idx] then
				return false
			end
		end
	end
	return anyone
end)

-- The old kiosk's upgrade counter. OFF: see the note in the "Upgrade" branch at
-- the bottom of this script for what has to be merged before it can come back.
local CTB_KIOSK_SELLS_UPGRADES = false

local function bagValue(bag: { string }): number
	local v = 0
	for _, id in ipairs(bag) do
		v += Config.value(id)
	end
	return v
end

local function pushBag(plr: Player)
	-- Bag / BagValue / BagMax now come from the one shared inventory array.
	-- CTB_HUD is completely unchanged: it still just reads those attributes.
	-- BagValue counts CLEANED items only, so it climbs instantly for loose
	-- litter and only after a sift for a crusted lump.
	Bridge.pushAttributes(plr)
end

Players.PlayerAdded:Connect(function(plr)
	-- grid is this player's private copy of the beach: their own raked columns and
	-- their own buried finds, seeded fresh however long the server has been up
	state[plr] = { bag = {}, lastRoller = nil, lastSweepAt = nil, lastSell = 0, lastUpgrade = 0,
		-- Distance travelled over the last SWEEP_WINDOW seconds, decayed. It is what
		-- the teleport guard is measured against; see the block over SWEEP_WINDOW for
		-- why a single tick cannot be.
		sweepRun = 0,
		-- When this player last made the server ask Roblox about their pass. See
		-- the QuickSell branch: that ask is a web call, so it is rationed.
		lastPassAsk = 0,
		warnedFull = false,
		-- Last tick's sweep refused a piece of tagged litter for want of room. A
		-- separate latch from warnedFull because the two ask different questions;
		-- see where it is read, below the bag check in the sweep.
		rakeStuck = false,
		grids = newGrids(), lastReset = {}, pendingReset = {}, wipeGen = {} }

	-- The Ashen Stair keeps its own private ash, on the same terms: fresh on
	-- join, thrown away on leave, never shared with anybody else on the mountain.
	StairSrv.attach(plr)

	-- INITIALISE, do not reset. Every other join hook in the game guards on nil
	-- for exactly this reason: PlayerAdded handlers run in no guaranteed order,
	-- so an unconditional zero here is a handler that can wipe a balance
	-- somebody else just put there. Nothing restores coins today; the day a save
	-- module does, this line is the one that would eat it.
	if plr:GetAttribute("Coins") == nil then
		plr:SetAttribute("Coins", 0)
	end
	plr:SetAttribute("Bag", 0)
	plr:SetAttribute("BagValue", 0)
	plr:SetAttribute("BagMax", Config.BAG_MAX)
	--[[
		THE SAME GUARD THE COINS LINE ABOVE HAS, AND FOR A WORSE REASON.

		These two were unconditional writes, and RollerLevel is not this script's
		any more -- ProgressionServer owns it and rewrites it from the RollerWidth
		track. PlayerAdded handlers run in no guaranteed order, so on any join
		where this one ran second it stamped a level-38 sifter back down to 1.

		That is the attribute FerryConfig gates every crossing on. The symptom is
		a player who has earned an island being told "Needs Sifter Lv.24" at the
		boat, which then fixes itself on the next respawn when applyAll runs
		again -- an intermittent lockout, which is the hardest kind to report.

		Initialise, do not reset: only write these if nothing has yet.
	]]
	if plr:GetAttribute("RollerLevel") == nil then
		plr:SetAttribute("RollerLevel", 1)
	end
	if plr:GetAttribute("RollerWidth") == nil then
		plr:SetAttribute("RollerWidth", Config.LEVELS[1].width)
	end
	plr:SetAttribute("RollerBlocked", false)

	plr.CharacterAdded:Connect(function()
		local st = state[plr]
		if st then
			st.lastRoller = nil
		end
	end)
end)

Players.PlayerRemoving:Connect(function(plr)
	state[plr] = nil
end)

----------------------------------------------------------------
-- Selling
----------------------------------------------------------------
-- How long a player must wait before another press can make the server re-ask
-- Roblox about their Quick Sell pass. Long enough that a held button cannot
-- turn into a web-call flood, short enough that somebody whose join sweep
-- failed is not stuck for the session.
local PASS_REASK_SECONDS = 8

--[[
	TWO DOORS, ONE TILL. The pad's Touched calls this and so does the HUD's
	QUICK SELL key, and they arrive at the same debounce, the same refusal and
	the same receipt -- which is the point of routing the button through here
	rather than giving it a sell path of its own.

	`anchor` is the ONLY thing the two doors may differ about: where the coin
	shower plays. Nil means the pad, which is right when the player is standing
	on it and wrong -- possibly an island away -- when they pressed a button
	from the dunes, and an effect nobody can see reads as a sale that did not
	happen.
]]
local function sell(plr: Player, anchor: BasePart?)
	local st = state[plr]
	if not st then
		return
	end
	if os.clock() - st.lastSell < 0.4 then
		return
	end
	st.lastSell = os.clock()

	-- The payout, the batch bonus, the "sift the crust off" refusal and the
	-- receipt all live in SellServer now, and it still fires CTB's own "Sold"
	-- message so this HUD animates exactly as before.
	--
	-- The old `#st.bag == 0` early-out is deliberately GONE: stepping on the pad
	-- carrying only crusted lumps has to produce the refusal, not silence.
	Bridge.sell(plr, anchor)
end

----------------------------------------------------------------
-- Main sim: work out which cells the sifter swept this tick
----------------------------------------------------------------
local acc = 0
local TICK = 1 / 24

--[[
	THE FASTEST THE TOOL CAN HONESTLY BE MOVING, in studs per second.

	Not a tuning knob -- it is a lie detector, and it is set off the game's own
	ceiling with room to spare. BeachLegs tops out at 66 (ProgressionConfig says
	so, and says why it stops there), and every machine ends up moving at the
	driver's speed once the track passes it. So 66 is the real maximum and this
	is nearly double it.

	WHAT IT IS ACTUALLY FOR: a character that is TELEPORTED does not arrive on
	the server as one jump. It arrives as a SLIDE -- replication plays the move
	out over a handful of frames -- and a join measured here ran 240 studs in
	0.17s as twelve steps of 9 to 35 studs. At 24 Hz that is four sifter ticks,
	each one landing somewhere over the beach at about 1400 studs/second, and
	each one raking the tool's footprint where it landed. That is where the
	scattered pre-cut squares on a brand-new join came from.
]]
local MAX_SWEEP_SPEED = 120

--[[
	AND IT IS MEASURED OVER THIS MANY SECONDS, NOT OVER ONE TICK.

	⚠ THE SINGLE-TICK VERSION ACCUSED HONEST PLAYERS AND PUNCHED STRIPES IN THE
	BEACH. A character's position does not arrive on the server smoothly: it
	arrives in BURSTS. Measured over three seconds of a straight run at BeachLegs
	speed (66 studs/s), sampled on this very clock -- 60 ticks, of which NINE saw
	the character not move at all, and the per-tick distances ran:

		0.00 0.86 1.01 0.45 0.85 1.18 10.99 3.23 4.48 0.76 1.64 1.53 ... 6.84 ... 6.49

	The average is exactly the 66 it should be. The PEAKS are 125 to 264 studs/s,
	because a burst delivers several ticks' worth of travel on one tick -- so the
	single-tick test threw those ticks away. And the throw-away is total: it
	`continue`s AFTER `lastRoller` has already advanced, so that stretch of sand
	is never swept by that tick or any later one.

	What the player sees is a clean full-width band across the trail, four studs
	of it, that they cannot rake out however many times they walk over it -- the
	server believes it is already behind them. Two of those in a three-second run.

	IT SHOWS UP WITH A WIDE ROLLER AND AT SPEED, and both for the same reason:
	a 48-stud roller clears its ground in ONE pass, so nothing ever comes back
	over the stripe, and the faster the run the more studs each burst is worth.
	At the starting roller the gap is a couple of cells and gets swept up by the
	next pass, which is why this went unseen for so long.

	SO IT IS A ROLLING WINDOW. `sweepRun` is the distance travelled over the last
	SWEEP_WINDOW seconds, decayed exponentially, and the test is against what that
	window COULD hold: MAX_SWEEP_SPEED * SWEEP_WINDOW = 42 studs. A run at 66
	fills 23 of it however bursty the delivery, and a teleport slide of 240 studs
	blows through it on the first or second step.

	0.35s: long enough to swallow the longest bunching measured (about 0.2s of
	ticks arriving together), short enough that a slide is still caught inside its
	own 0.17s. It is a smoothing window and NOT patience -- nothing waits on it,
	and a tick that passes rakes its whole band on the spot.

	⚠ ONE STEP OF A TELEPORT CAN STILL GET THROUGH, and only one: a player who was
	STANDING STILL has an empty window, so the slide's first step may fit inside
	the 42 before the rest of it does not. That is one band at the destination
	rather than the twelve scattered squares the guard was written for, and the
	join case -- the one that prompted it -- never reaches here at all, because
	CharacterAdded clears lastRoller and the first tick after a spawn sweeps
	nothing but the tool's own footprint.
]]
local SWEEP_WINDOW = 0.35

----------------------------------------------------------------
-- THE RAKE, LIFTED OUT OF THE SWEEP LOOP
--
-- Nothing about raking changed when this moved. It is the same code, one
-- indent shallower, called from the same place with the same values -- lifted
-- out for ONE reason: the sandbot (SandbotService) sweeps a band across a
-- field too, and it had to be THIS rake rather than a second one.
--
-- A drone with a rake of its own would be a second definition of what a column
-- pays, what a full bag does to it, what happens to the litter standing on it
-- and what the client is told afterwards -- and the two drifting apart is a
-- drone that clears sand nobody was paid for. See the note over CTBBridge's
-- sweepDrone, which is how it reaches this.
----------------------------------------------------------------

--[[
	Rake every unraked cell of the band from `last` to `cur`, `hw` either side.

	Hands back the three things the caller has to act on:

	  batch    the cell indices that went clean, for the client to paint
	  blocked  the sweep stopped early -- the bag would not take something
	  stuck    ...and specifically it was the LITTER lying there, not a find.
	           The caller reads this back on its next tick to decide whether the
	           full-bag nudge may re-arm; see the block that does.

	`full` is passed IN rather than asked for here, because the caller has to
	know it before this runs anyway (it publishes RollerBlocked off it) and two
	hasRoom calls a tick would be two answers that can disagree.
]]
local function rakeRect(plr, isl, g, cur: Vector3, last: Vector3, look: Vector3,
	right: Vector3, hw: number, hd: number, full: boolean)
	local batch = {}
	local blocked = false      -- tried to rake with a full bag
	local stuck = false        -- ...specifically: could not take the litter lying there
	local centre = (last + cur) * 0.5

	local ex = math.abs(right.X) * hw + math.abs(look.X) * hd
	local ez = math.abs(right.Z) * hw + math.abs(look.Z) * hd

	local minX = math.max(0, math.floor((centre.X - ex - isl.x0) / Config.TILE))
	local maxX = math.min(isl.grid - 1, math.floor((centre.X + ex - isl.x0) / Config.TILE))
	local minZ = math.max(0, math.floor((centre.Z - ez - isl.z0) / Config.TILE))
	local maxZ = math.min(isl.grid - 1, math.floor((centre.Z + ez - isl.z0) / Config.TILE))

	--[[
		IS THIS CELL UNDER THE BAND?

		Two passes below ask it -- the sand, and the litter standing on that sand,
		which is now asked about whether or not the sand is still there. They have
		to agree exactly on what the tool covered, so the test is written once.
	]]
	local function underBand(ix: number, iz: number): boolean
		local d = Config.cellCentre(isl, ix, iz) - centre
		local u = d.X * right.X + d.Z * right.Z
		local v = d.X * look.X + d.Z * look.Z
		return math.abs(u) <= hw and math.abs(v) <= hd
	end

	for iz = minZ, maxZ do
		for ix = minX, maxX do
			local idx = Config.index(isl, ix, iz)

			--[[
				LITTER LYING ON SAND THAT IS ALREADY CLEAN.

				The pass below only visits a cell while it still HAS sand, which
				quietly made the collection hook one-shot: sweep a cell once and
				the tool crosses that ground for ever after without asking what is
				standing on it again. So anything that puts a piece back onto
				cleared sand left litter the rake could not pick up for the rest of
				the tide -- and a respawn IS allowed onto a cell that only SOME of
				the players on the field have cleared (see setRakedQuery), which
				makes this the ordinary case on a busy server rather than an edge
				one. The piece could still be WALKED over, so from the outside it
				looked like the rake paying for litter sometimes and not others.

				Nothing here touches the sand: the cell is clean and stays clean,
				`batch` does not grow and no find is dug. It is the same collect
				the dirty branch does, and a refusal for want of room stops the
				roller the same way -- a bag that will not take this piece will not
				take the next one either.
			]]
			if g.clean[idx] and not full and Bridge.hasLitter(isl.id, idx)
				and underBand(ix, iz) then
				local took = Bridge.rakeCell(plr, isl.id, idx)
				if took == "Full" then
					stuck = true
					blocked = true
					break
				elseif took == "Taken" and not Bridge.hasRoom(plr) then
					full = true
				end
			end

			if not g.clean[idx] then
				if underBand(ix, iz) then
					if full then
						blocked = true
						break
					end

					--[[
						THE SAND AND THE RUBBISH ON IT GO TOGETHER.

						Everything else in this loop is about what is BURIED in a
						cell. This is about what is STANDING on it: TrashSeeder's
						tagged props, which for a long time nothing in CTB knew
						existed. The tool cleared the sand out from under them and
						left them lying on the bare channel, so a field could read
						100 percent raked with ninety pieces of litter on it. See
						the long note over rakeCell in CTBBridge.

						It COLLECTS rather than deletes -- the player is paid for
						the piece exactly as if they had walked over it -- so this
						takes nothing out of the run.

						A refusal for want of room leaves the cell DIRTY, which is
						the same answer the full-bag branch above gives and the
						same one tryAdd gives for a find: the sand stays over the
						piece, the roller stops here, and the player goes and
						sells. Clearing the ground out from under something they
						cannot pick up is the exact bug this hook exists to end.
					]]
					if Bridge.rakeCell(plr, isl.id, idx) == "Full" then
						stuck = true
						blocked = true
						break
					end

					g.clean[idx] = true
					g.cleanCount += 1
					table.insert(batch, idx)

					-- The field's own seeding is the only thing that buries a find.
					-- The Prospector's Eye track used to take a second roll here on
					-- a cell that came up empty; the track is gone and the roll went
					-- with it, rather than leaving a branch reading an attribute that
					-- nothing writes. A cell the field seeded empty stays empty.
					local found = g.itemAt[idx]
					if found then
						--[[
							THE ONBOARDING'S GUARANTEE, and it sits HERE rather
							than inside tryAdd for one reason: the pop below
							broadcasts this find's public id to the finder, so a
							swap made after the bank would put a lump in the bag
							while the sand threw up a bottle. Substituting before
							both is what keeps them telling one story.

							Costs one attribute read per find, and hands back what
							it was given for everybody who is not two finds into
							their first session. See TutorialServer's header.
						]]
						found = Tutorial.biasFind(plr, found, isl)
						g.itemAt[idx] = false
						-- tryAdd does the capacity check against the shared array and
						-- returns false when full, so `relocate` below still buries
						-- the item again exactly as it used to. No pushBag call: the
						-- inventory flush fires the attribute update itself.
						if Bridge.tryAdd(plr, found) then
							-- The island id rides with every cell index. An index on
							-- its own is ambiguous: cell 1 exists on both fields.
							-- Not `found`: an encased find goes out as a lump id, so
							-- no client is ever told what is inside the rock before
							-- the sifting bay reveals it.
							--
							-- To the finder only. The cell is dug up in THEIR field;
							-- broadcasting would make an item pop out of sand that,
							-- to everyone else, is still untouched.
							Net:FireClient(plr, "Pop", isl.id, idx, Bridge.popIdFor(found), plr.UserId)
						else
							-- Belt and braces. The check below stops the sweep the
							-- instant the bag fills, so this should no longer be
							-- reachable -- but if it ever is, nothing is lost.
							relocate(isl, g, found)
							blocked = true
						end
					end

					-- Stop the moment the bag fills rather than at the end of the
					-- tick, so one last swipe can never rake a few more columns
					-- past the point where it stopped paying.
					if not Bridge.hasRoom(plr) then
						full = true
					end
				end
			end
		end
		if blocked then
			break
		end
	end
	return batch, blocked, stuck
end

-- Assigned down with the turnover itself, once everything it needs exists.
-- Declared here so the rake can call it: a field is finished BY a rake, and
-- waiting for the next sweep of the poll to notice is dead time the player
-- spends standing on a field with nothing left to do.
local queueReset

-- What the player's client is told about a rake: which columns went clean, and,
-- near the end of a field, where the stragglers are. Lifted out with the
-- rake above and for the same reason: the sandbot's rake has to say the same
-- thing to the same client, or the sand it clears never turns white.
local function announceRake(plr, isl, g, batch)
	-- To this player alone, and no server terrain write: the raked columns are
	-- theirs, and their client paints them into its own copy of the sand.
	if #batch > 0 then
		Net:FireClient(plr, "Clean", isl.id, batch)

		--[[
			THE LAST FEW. Near the end of a field, hand the client where the
			stragglers actually are so it can stand a marker on each -- the whole
			argument is over Config.LAST_FEW.

			SENT FROM HERE RATHER THAN WORKED OUT ON THE CLIENT, because the
			server is the only thing that knows. The client is told which columns
			go CLEAN and never which stay messy, so it would have to keep a
			shadow copy of a 25,600-cell grid and hope the two never drifted --
			and a marker standing on a square the player has already raked is
			worse than no marker at all. At fifteen or fewer the payload is
			fifteen integers.

			And it goes out EMPTY on the last rake, so the markers leave with the
			final column instead of hanging over a finished field for the beat
			before the tide takes it back.
		]]
		if isl.cells - g.cleanCount <= Config.LAST_FEW then
			Net:FireClient(plr, "LastFew", isl.id,
				g.cleanCount < isl.cells and cleanIndices(isl, g, true) or {})
		end

		--[[
			AND THE TURNOVER IS QUEUED FROM THE RAKE THAT FINISHED IT.

			The poll below used to be the only thing that noticed, and it comes
			round every two seconds -- so a player who raked the last column a
			tenth of a second after a sweep stood on a finished field for very
			nearly two seconds before the countdown even STARTED. That is dead
			time on top of the beat, it is invisible (nothing on screen says the
			field is done yet), and it is different every time, which is the
			part that makes it read as the game being slow rather than as a
			pause somebody chose.

			Both rakes come through here -- the player's sifter and the
			sandbot's -- so this one call site covers both. The poll stays as
			the backstop for any route that fills a grid without raking it.
		]]
		if queueReset then
			queueReset(plr, isl, g)
		end
	end
end

----------------------------------------------------------------
-- THE SANDBOT'S HALF OF THE RAKE
----------------------------------------------------------------
--[[
	TWO ANSWERS HANDED TO CTBBridge, and not one line of raking of their own.

	The drone lives in SandbotService and knows nothing about grids, cells, tides
	or payouts. It drives; then it says "I have just been from here to here,
	this wide" and this file rakes it -- through rakeRect, the same function the
	player's own sifter goes through, so a column the drone clears is worth what
	a column the player clears is worth and there is no second economy to keep
	balanced.

	INSTALLED RATHER THAN FETCHED, because this is a Script and cannot be
	required. Exactly the arrangement Bridge.setRakedQuery already uses, and the
	reason is the same: the dependency runs one way (this file requires the
	bridge), so the answer has to travel back the other way as a function.

	WHOSE FIELD? The owner's, always. CTB's fields are per player, and the drone
	rakes into the grid of the player who deployed it wherever it happens to be
	standing -- so two players' drones working the same sand are each clearing
	their own copy of it, exactly as the two players themselves would be.
]]
local function droneSweep(plr: Player, cur: Vector3, last: Vector3, look: Vector3,
	hw: number, hd: number): (string, number)
	local st = state[plr]
	if not st then
		return "nofield", 0
	end
	local isl = Config.fieldAt(cur)
	if not isl then
		return "nofield", 0
	end
	local g = st.grids[isl.id]
	if not g then
		return "nofield", 0
	end

	-- The same question the player's own tick asks before it sweeps, and asked
	-- once for the same reason: two hasRoom calls in one pass are two answers
	-- that can disagree with each other.
	local full = not Bridge.hasRoom(plr)
	local right = Vector3.new(-look.Z, 0, look.X)
	local batch, blocked = rakeRect(plr, isl, g, cur, last, look, right, hw, hd, full)
	announceRake(plr, isl, g, batch)

	--[[
		FULL IS REPORTED WHETHER OR NOT THE SWEEP WAS BLOCKED.

		`blocked` only goes true if the band actually contained an unraked cell,
		so a drone crossing ground it has already cleared with a full bag would
		come back "clean" and carry on hunting forever. The bag is the drone's
		reason to come home, not the cell it happens to be over.

		The player's own tick does not need this distinction: a player with a full
		bag is standing there reading a permanent BAG FULL hint on the HUD.
	]]
	if full or blocked then
		return "full", #batch
	end
	return (#batch > 0 and "raked" or "clean"), #batch
end
Bridge.setDroneSweep(droneSweep)

--[[
	WHERE THE DRONE SHOULD GO NEXT: the nearest column its owner has not raked.

	ONLY THIS FILE CAN ANSWER IT. The grids are per player and they are private
	to this script -- there is no replicated copy, deliberately (see the note on
	the LastFew message about what a shadow copy of a 25,600-cell grid would
	cost). So the search runs here and hands back a world point.

	RING ORDER, OUTWARD FROM THE DRONE. On a messy field the answer is one of
	the first few cells looked at; the ceiling only costs anything on a field
	that is nearly finished, which is exactly the case a linear scan is hopeless
	at -- the last column of a 160x160 grid can be 25,600 cells into it.

	The y it hands back is the island's own surface rather than cellCentre's 0,
	so the caller does not have to know where the sand is.
]]
local function droneDirty(plr: Player, from: Vector3, rings: number): Vector3?
	local st = state[plr]
	if not st then
		return nil
	end
	local isl, cx, cz = Config.cellAt(from)
	if not isl then
		return nil
	end
	local g = st.grids[isl.id]
	-- A finished field has no answer, and saying so is what sends the drone home
	-- rather than having it walk every ring to the edge of the grid.
	if not g or g.cleanCount >= isl.cells then
		return nil
	end

	local hit
	for r = 0, math.max(0, rings) do
		Config.eachRing(isl, cx, cz, r, function(ix, iz)
			if g.clean[Config.index(isl, ix, iz)] then
				return nil
			end
			hit = Config.cellCentre(isl, ix, iz)
			return true
		end)
		if hit then
			return Vector3.new(hit.X, Config.surfaceY(isl), hit.Z)
		end
	end
	return nil
end
Bridge.setDroneDirty(droneDirty)

RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc < TICK then
		return
	end
	acc = 0

	for plr, st in pairs(state) do
		local batch = {}
		local blocked = false      -- tried to rake with a full bag
		local stuck = false        -- ...specifically: could not take the litter lying there

		local char = plr.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not hrp or not hum or hum.Health <= 0 then
			st.lastRoller = nil
			continue
		end

		-- sell pad check -- every island's pad, so the desert can be worked without
		-- sailing a bagful home
		for _, pad in ipairs(sellPads) do
			local rel = pad.CFrame:PointToObjectSpace(hrp.Position)
			if math.abs(rel.X) <= pad.Size.X * 0.5 + 1.5
				and math.abs(rel.Z) <= pad.Size.Z * 0.5 + 1.5
				and math.abs(rel.Y) <= 9 then
				sell(plr)
				break
			end
		end

		--[[
			SEATED: THE SIFTER IS STOWED, BUT THE MACHINE SWEEPS.

			This loop is what actually collects the beach. Most of the litter on
			the sand is CTB's own buried field, not the ninety tagged props the
			vehicle net picks up -- so a version that simply skipped seated
			players meant you drove over the whole beach and nothing happened.
			That is what "some things you drive over don't get picked up" was.

			So while riding it still rakes, but as the MACHINE rather than as the
			person: off the chassis, along the chassis's nose, and a band as wide
			as the net rather than as the hand tool. Its finds go to the hold,
			because CTBBridge.tryAdd routes them there while riding.

			THE NOSE IS +Z, NOT LookVector. Every vehicle in this game is built
			nose-at-+Z and Roblox's LookVector is the negative Z axis, so a rake
			band taken off LookVector would trail out behind the machine. The
			character on foot is the opposite -- LookVector is genuinely where
			they face -- which is why this picks the axis per case.

			Sitting on anything that is NOT one of ours (a deck chair) rakes
			nothing, and clears lastRoller so the first stroke after standing up
			is not a stripe drawn from wherever they were sitting.
		]]
		local seatPart = hum.SeatPart
		local ride = seatPart and seatPart.Parent
		local netRadius = ride and ride:GetAttribute("NetRadius")
		local rideRoot = (type(netRadius) == "number" and netRadius > 0)
			and (ride.PrimaryPart or seatPart) or nil
		if seatPart and not rideRoot then
			st.lastRoller = nil
			continue
		end

		local source = rideRoot or hrp
		-- +Z for a machine, LookVector for a person. See the block above.
		local lv = rideRoot and source.CFrame.ZVector or source.CFrame.LookVector
		local look = Vector3.new(lv.X, 0, lv.Z)
		if look.Magnitude < 1e-3 then
			continue
		end
		look = look.Unit
		local right = Vector3.new(-look.Z, 0, look.X)

		--[[
			WHERE THE BAND SITS, AND HOW LONG IT IS.

			The hand tool rides 4.6 studs out in front of the player and bites
			ROLLER_DEPTH of sand, so its band is a short rectangle out at the
			basket. That is unchanged.

			A MACHINE RAKES ITS WHOLE FOOTPRINT. This used to be that same short
			rectangle centred on the CHASSIS -- the middle of the machine, which on
			a thirty-stud tipper is sixteen studs behind the scoop. So the sand in
			front of it stood while the blade went through it, while the bumper
			went through it, while the cab went over it, and only gave way once the
			middle of the truck arrived -- about half a second late at road speed,
			and from the default camera (behind the driver) it read as the beach
			vanishing somewhere under the back axle. That was the reported delay.

			The band now runs SweepBack .. SweepAhead, both stamped by the builders
			off the model they actually built, so ITS LEADING EDGE IS THE CUTTING
			EDGE. Sand goes where the blade is, which is the only place a player
			can be told it goes.

			The whole footprint rather than just the blade's own path, for the
			dozer's one trick: skid steer pivots it on the spot, and a band that
			only followed the blade round left a plug of uncut sand standing under
			the tracks with a clean ring drawn around it.
		]]
		local aheadOf, backOf = 0, 0
		if rideRoot then
			aheadOf = tonumber(ride:GetAttribute("SweepAhead")) or 0
			backOf = tonumber(ride:GetAttribute("SweepBack")) or 0
			if aheadOf <= 0 and backOf <= 0 then
				-- A machine spawned before the builders stamped these still has to
				-- rake something it covers rather than nothing at all.
				aheadOf, backOf = 8, 8
			end
		end
		-- ONE point, still: the swept rectangle below is built from last -> cur and
		-- the distance between them, so the machine's footprint is carried as its
		-- centre plus a depth rather than as two ends to keep in step.
		--
		-- KEPT IN BOTH FORMS. Everything about a FIELD is 2D -- one height per
		-- island, no Y term anywhere in the rectangle or the clamp -- so `cur` is
		-- flattened, as it always was. The Ashen Stair is not a field and cannot
		-- be swept without a height: the road doubles back on itself twice, so a
		-- player at the rim stands directly over a flight they climbed twenty
		-- minutes ago. `cur3` is the same point before it loses its Y.
		local cur3 = source.Position
			+ look * (rideRoot and (aheadOf - backOf) * 0.5 or Config.ROLLER_DIST)
		local cur = Vector3.new(cur3.X, 0, cur3.Z)

		-- GETTING IN OR OUT MOVES THAT POINT BY HALF A MACHINE. The sweep is built
		-- from last -> cur, so a `last` left over from the other case carves a
		-- stripe between where the person was standing and where the scoop now is.
		local rideKey = rideRoot or false
		if st.lastRide ~= rideKey then
			st.lastRide = rideKey
			st.lastRoller = nil
		end
		local last = st.lastRoller or cur
		st.lastRoller = cur

		--[[
			RAKE NOTHING THIS TICK IF THE TOOL DID NOT GET HERE BY MOVING.

			MEASURED AS A SPEED, NOT A DISTANCE, and the distinction is the whole
			fix. The old test was `moved > 30`, further down at the rectangle, and
			it failed twice over:

			  * TOO LOOSE. A teleport reaches the server as a slide of sub-30-stud
			    steps (see MAX_SWEEP_SPEED), every one of which read as ordinary
			    walking and raked. A fresh join arrived with a handful of squares
			    already cut out of the beach, scattered along the line between the
			    spawn point and wherever the player was put down.
			  * TOO TIGHT, on the tick it did catch. It clamped `moved` to 0 and
			    carried on, so the tool still raked its own footprint at the far
			    end. It stopped the stripe and kept the divot.

			A distance cannot tell the two apart, because a fixed cap is also wrong
			about a SERVER HITCH: one tick covering 0.3s of a legitimate 66-stud
			sprint is 20 studs of honest movement, and clipping it would punch a
			gap in the trail behind a player who did nothing wrong. Dividing by the
			time actually elapsed gets both cases right -- the hitch is 66 studs/s
			and passes, the slide is ~1400 and does not.

			IT SITS HERE, WITH lastRoller, RATHER THAN DOWN AT THE RECTANGLE, and
			that placement is load-bearing. Everything below the `fieldAt` early-out
			only runs while the tool is over a field, so a clock kept down there
			stops while the player is on the plaza -- and the first tick of an
			arrival, which is the one that does the damage, would find no previous
			sample to measure against and wave itself through. Up here it ticks for
			every player every tick, on or off the sand.

			And it SKIPS rather than clamping. lastRoller is already updated to
			`cur` above, so the next tick sweeps normally from where the player
			actually is; all that is given up is one 24th of a second of raking
			after a teleport, which is not a thing anybody can see.
		]]
		local now = os.clock()
		local since = st.lastSweepAt and (now - st.lastSweepAt) or 0
		st.lastSweepAt = now
		--[[
			Distance over the last SWEEP_WINDOW seconds, not over this tick. See the
			block over SWEEP_WINDOW for the measurements -- a single tick of an
			honest 66-stud/s run reads anywhere from 0 to 264 studs/s, so testing one
			in isolation is testing the network, not the player.

			The decay makes this a fixed-length window with no history to keep: for a
			steady speed v the sum settles at v * SWEEP_WINDOW, which is what it is
			compared against.
		]]
		if since > 1e-3 then
			st.sweepRun = (st.sweepRun or 0) * math.exp(-since / SWEEP_WINDOW)
				+ (cur - last).Magnitude
			if st.sweepRun > MAX_SWEEP_SPEED * SWEEP_WINDOW then
				continue
			end
		end

		--[[
			THE BAND, AND IT IS MEASURED HERE RATHER THAN BELOW THE FIELD TEST.

			HOW WIDE IT IS: exactly as wide as the thing doing the sweeping. The
			hand tool's is the RollerWidth upgrade. A machine's is its SweepWidth --
			the scoop's DRAWN mouth, or the bulldozer's blade -- and not its
			netRadius, which is a reach and is far bigger.

			That distinction is the whole point. An earlier version took the band
			from the net's reach capped at 20, which on a 13.5 stud sweeper meant
			three studs of beach either side being raked clean by a machine that
			visibly never went near it -- litter disappearing off to the side for
			no reason a player could see. One stud of slack, so the very edge of
			the scoop still counts.

			HOW DEEP: the machine's own length, or the hand tool's bite, plus how
			far it travelled this tick, which is what makes the sweep continuous.

			IT MOVED UP FROM THE RECTANGLE because the Ashen Stair needs the same
			two numbers and is NOT on a field -- Config.fieldAt returns nothing for
			any point on the mountain, so the early-out below is taken on every
			single tick a player spends up there.
		]]
		local moved = (cur - last).Magnitude
		local hw = (tonumber(plr:GetAttribute("RollerWidth")) or Config.LEVELS[1].width) * 0.5
		if rideRoot then
			local sweep = ride:GetAttribute("SweepWidth")
			if type(sweep) ~= "number" or sweep <= 0 then
				sweep = 12
			end
			hw = math.max(hw, sweep * 0.5 + 1)
		end
		local hd = ((rideRoot and (aheadOf + backOf) or Config.ROLLER_DEPTH) + moved) * 0.5

		-- THE ASHEN STAIR. Its own surface, its own counter, its own bonus, and
		-- the one place in this loop that is handed a height.
		StairSrv.sweep(plr, cur3, look, right, hw, hd)

		-- Which field is under the sifter. Standing on the plaza, in the dunes or
		-- on a dock is a real answer of "none" -- the tool still rides along, it
		-- just has no columns to rake. lastRoller is still updated above so the
		-- first stroke back on sand is not a stripe from wherever they wandered.
		local isl = Config.fieldAt(cur)
		if not isl then
			-- Walked off the sand: whatever the roller was stuck against is behind
			-- them and is no longer the reason anything is not being raked.
			st.rakeStuck = false
			continue
		end
		local g = st.grids[isl.id]

		-- A FULL BAG STOPS THE SIFTER.
		--
		-- It used to rake on regardless and rebury anything it turned up, which
		-- is the worst of both worlds: the player watches the beach go clean,
		-- gets none of it, and cannot go back for it either -- a raked column is
		-- raked for good, so every find in it is gone until the next tide.
		-- Nothing is spent now until there is somewhere to put it.
		--
		-- Note this sits AFTER `st.lastRoller = cur`, deliberately. The swept
		-- rectangle is built from last -> cur, so if the position stopped being
		-- updated while full, the walk to the sell pad and back would come out as
		-- one enormous sweep and carve a stripe across everything in between the
		-- moment the bag had room again.
		--[[
			TWO WAYS TO BE OUT OF ROOM, and only one of them is this question.

			hasRoom asks whether the LIGHTEST thing on the beach would still fit,
			which is the right gate for the buried finds -- their weight is not
			known until the cell is opened. A piece of tagged litter LYING on a
			cell has a real weight the sweep can be refused over, so a bag with a
			pound of headroom answers `true` here and still cannot take the two
			pound lump the tool is standing over.

			That is why the nudge does not re-arm off `full` alone. It used to, and
			with the rake-collect hook below that is a toast every single tick:
			hasRoom keeps saying there is room, so warnedFull kept being cleared
			while the thing actually stopping the roller went on stopping it.
			rakeStuck is last tick's answer to the other question, read here before
			the sweep overwrites it.
		]]
		local full = not Bridge.hasRoom(plr)
		if not full and not st.rakeStuck then
			st.warnedFull = false
		end

		-- Published so the HUD and the sifter's own effects agree with the server
		-- rather than each working it out for themselves -- what actually limits
		-- the bag is the weight ledger, which neither of them can see, and the Bag
		-- / BagMax attributes they used to read now say "n / 9999". Written only on
		-- a change, so this is not an attribute write at 24 Hz.
		if plr:GetAttribute("RollerBlocked") ~= full then
			plr:SetAttribute("RollerBlocked", full)
		end

		-- swept rectangle covering last -> cur. No teleport test here any more --
		-- it moved up next to lastRoller, which is the only place it can see the
		-- ticks spent off the sand. See the block there.
		-- moved, hw and hd are measured above the field test now -- see the note
		-- there. Only the rectangle's own centre is local to this block.
		batch, blocked, stuck = rakeRect(plr, isl, g, cur, last, look, right, hw, hd, full)
		st.rakeStuck = stuck

		-- Once per full-bag episode, not once per tick: the HUD already carries a
		-- permanent BAG FULL hint, so this is the nudge that they just tried to
		-- rake and nothing happened. Re-arms above as soon as there is room.
		if blocked and not st.warnedFull then
			st.warnedFull = true
			Net:FireClient(plr, "BagFull")
		end

		announceRake(plr, isl, g, batch)
	end
end)

----------------------------------------------------------------
-- Tide reset: YOUR beach is raked -> the sea messes it up again and you get paid
--
-- Personal now, like the field it resets. It fires off one player's own progress
-- and re-seeds only their grid, so finishing your beach never wipes the work of
-- someone standing next to you. Their sand does not change; only yours does.
--
-- A BEAT BEFORE THE TURNOVER. The field is not wiped the instant the last column
-- is raked -- RESET_DELAY seconds pass first, so the player gets to stand on the
-- beach they just finished before the sea takes it back. The whole reset still
-- moves as one: the wipe, the re-seed, the bonus and the "Tide" message all land
-- together at the far end of the wait, so the banner is never announcing coins
-- that have not been paid or a field that has not turned over yet.
--
-- Nothing is frozen during it -- the player keeps the sifter and keeps moving,
-- there is simply nothing left to rake. That is new: this note used to say the
-- five seconds were "five more seconds of rakeable sand", which was true while
-- the fields turned over at 75% and stopped being true when they went to 1.0.
-- Four of the five now fire on the LAST column (Config.ISLANDS[n].resetAt), so
-- the wait is a beat to look at a finished beach and nothing else.
----------------------------------------------------------------
--[[
	THE BEAT, AND IT IS SHORTER THAN IT WAS.

	Five seconds was picked when this was the ONLY thing standing between a
	finished field and its turnover. It was not: the poll below found the
	finished field up to two seconds after the rake that finished it, so the real
	wait was five to seven and varied by a factor no player could see. `queueReset`
	is called straight from the rake now, so what is left here is the whole wait
	and all of it is deliberate.

	Two seconds is a beat to look at a finished beach. It is not the whole
	turnover the player watches -- the litter rolls back in over Config.REMESS_SWEEP
	(4.74s) afterwards -- but the field is rakeable again the instant this fires,
	so that sweep is scenery and not waiting.
]]
local RESET_DELAY = 2      -- seconds between finishing a field and it turning over

--[[
	QUEUE ONE TURNOVER, FROM EITHER OF THE TWO THINGS THAT CAN NOTICE.

	IDEMPOTENT BY CONSTRUCTION, because both callers can fire on the same field in
	the same second: the rake calls it the moment the grid fills, and the poll
	comes round two seconds later and sees the same full grid. `pendingReset` is
	what makes the second call a no-op while the beat runs, and the six-second
	rate limit covers the window after it.

	It looks `st` up rather than taking it, so the rake -- which has the player,
	the island and the grid but not the state table -- can call it with what it
	already has.
]]
queueReset = function(plr, isl, g)
	local st = state[plr]
	if st and g.cleanCount >= isl.cells * isl.resetAt
		and not st.pendingReset[isl.id]
		and os.clock() - (st.lastReset[isl.id] or 0) > 6 then
		-- Queued, not done. This flag is what stops the SECOND caller
		-- stacking another turnover on top of this one while the beat
		-- runs -- and there is always a second caller now, because the
		-- backstop poll comes round two seconds after the rake that
		-- already queued it and finds the same full grid. The six-second
		-- rate limit above cannot do that job on its own, because
		-- lastReset is stamped at the END of the wait so that the
		-- cooldown measures from the real turnover.
		st.pendingReset[isl.id] = true
		-- Stamped now, checked at the far end. A rebirth during the wait
		-- bumps this, and a turnover whose field has already been taken
		-- must not still pay out: without it, finishing a beach and then
		-- rebirthing inside the beat hands the player a tide bonus
		-- moments after a wipe that just zeroed their coins -- money for a
		-- field that no longer exists, on the new multiplier.
		local gen = st.wipeGen[isl.id] or 0
		task.delay(RESET_DELAY, function()
			st.pendingReset[isl.id] = false
			-- They left during the wait -- or left and rejoined onto a
			-- fresh state table, which is why this compares identity and
			-- not just nil. Paying a departed player and firing at their
			-- client are both pointless, and re-seeding an orphaned grid
			-- does nothing for anybody.
			if state[plr] ~= st then
				return
			end
			if (st.wipeGen[isl.id] or 0) ~= gen then
				return
			end
			st.lastReset[isl.id] = os.clock()
			for i = 1, isl.cells do
				g.clean[i] = false
			end
			g.cleanCount = 0
			seedItems(isl, g)
			-- Through the bridge, not straight onto the attribute. Both
			-- end up writing the same number, but only this path fires
			-- the one grant hook -- which is what counts the bonus
			-- towards the next rebirth and repaints the shop's purse.
			-- Written directly, the HUD banner announced a bonus the
			-- shop had never heard of and went on refusing upgrades the
			-- player could now afford.
			--[[
				SCALED BY THE RUN, like the playtime bounties and the idle
				shore (RewardsServer.scaled, AfkConfig.rateFor).

				The per-island ladder is well argued and does not move --
				the bonus is set per COLUMN, so the beach pays 0.08 a
				column, the dunes 0.41, Ashfall 0.67 and the vault most of
				all. What was missing is that all five were FLAT, and
				clearing three quarters of a 4,096 column beach for 250
				coins stops being an event the moment a sale is worth more
				than that. Against a sell multiplier that reaches 705x it
				was invisible by the third rebirth.

				The multiplier rides out to the client too, or the banner
				would announce a number the till never paid.
			]]
			local mult = plr:GetAttribute("SellMultiplier")
			if type(mult) ~= "number" or mult ~= mult or mult <= 0 then
				mult = 1
			end
			local bonus = math.floor(isl.resetBonus * mult + 0.5)
			Bridge.addCoins(plr, bonus, "bonus")
			-- no server terrain write: the client re-messes its own
			-- field. The name rides along because the beach calls this a
			-- tide and the desert calls it a sandstorm -- same event,
			-- different weather.
			Net:FireClient(plr, "Tide", isl.id, bonus, isl.resetName)

			-- An eruption that re-buries the whole black strand has
			-- obviously re-buried the road up the mountain with it. It
			-- also gives the stair a cadence -- one sweep per tide --
			-- rather than making it something you do once, ever.
			if isl.id == StairIsland then
				StairSrv.reset(plr)
			end
		end)
	end
end

--[[
	THE BACKSTOP, and it is no longer the thing that finds a finished field --
	the rake that finished it is. This sweep exists for the routes that can fill
	a grid without going through announceRake, and for a grid that was already
	full when a queue attempt was refused by the rate limit above. Two seconds is
	fine for that job; it was never fine as the only way in.
]]
task.spawn(function()
	while true do
		task.wait(2)
		for plr, st in pairs(state) do
			for _, isl in ipairs(ISLANDS) do
				queueReset(plr, isl, st.grids[isl.id])
			end
		end
	end
end)

----------------------------------------------------------------
-- A REBIRTH TAKES THE SAND BACK TOO
--
-- Giving up every upgrade, every coin and the whole bag, and then landing back
-- on the spawn pad in front of a beach you had already raked flat, was the one
-- thing a rebirth did not reset. The new run started with its work done.
--
-- It also made the tide bonus farmable ACROSS a rebirth: rake a field to its
-- reset threshold, rebirth, and the finished field is still sitting there
-- waiting to turn over and pay out -- on the new, larger multiplier.
--
-- DRIVEN OFF THE ATTRIBUTE, NOT OFF A CALL. ProgressionServer owns rebirth and
-- writes `Rebirths`; this script owns the grids. This is a Script rather than a
-- ModuleScript, so ProgressionServer cannot require it and call in -- and it
-- should not have to. Every other system in the game already reacts to a
-- rebirth by watching that same attribute (Island2_Client's tomb door,
-- TradeClient's gate, AtvClient's shop), so this is the established seam and it
-- leaves the two files independent of each other.
--
-- INCREASES ONLY. `Rebirths` is also written on join (nil -> 0), and would be
-- written again by any save module that restores it. A bare "it changed" would
-- wipe the field of a player whose rebirth count was merely being LOADED.
----------------------------------------------------------------
local function wipeFieldsFor(plr: Player)
	local st = state[plr]
	if not st then
		return
	end
	for _, isl in ipairs(ISLANDS) do
		local g = st.grids[isl.id]
		if g then
			-- Anything raked here has to be un-raked on the client too. A field
			-- they have never touched gets no message: there is nothing drawn on
			-- it to put back, and the client would be re-messing sand that is
			-- already messy.
			local hadRaked = g.cleanCount > 0
			-- Retires any tide turnover queued for this island (see the guard in
			-- the reset poll above) and starts its cooldown from now.
			st.wipeGen[isl.id] = (st.wipeGen[isl.id] or 0) + 1
			st.lastReset[isl.id] = os.clock()
			for i = 1, isl.cells do
				g.clean[i] = false
			end
			g.cleanCount = 0
			-- Re-rolled, the way a tide does it: the new run gets its own finds
			-- rather than inheriting the last run's map of where things are buried.
			--
			-- YIELDING, unlike everywhere else this is called. A rebirth re-rolls
			-- ALL SEVEN fields in one go -- ~45,000 draws now that the cove is
			-- 9,216 cells and Ashfall 25,600 -- and it is the one path that can
			-- afford to: it is driven off an attribute change, nothing is waiting
			-- on a return value, and the client is told island by island below.
			-- The player can leave across the yield, hence the guard.
			seedItems(isl, g, true)
			if state[plr] ~= st then
				return
			end
			if hadRaked then
				Net:FireClient(plr, "Wipe", isl.id)
			end
		end
	end
	-- A rebirth takes the stair back too. It pays nothing for it, which is the
	-- difference between this and a tide.
	StairSrv.reset(plr)
end

local function watchRebirths(plr: Player)
	local seen = plr:GetAttribute("Rebirths")
	if type(seen) ~= "number" then
		seen = 0
	end
	plr:GetAttributeChangedSignal("Rebirths"):Connect(function()
		local now = plr:GetAttribute("Rebirths")
		if type(now) ~= "number" then
			return
		end
		if now > seen then
			wipeFieldsFor(plr)
		end
		seen = now
	end)
end

Players.PlayerAdded:Connect(watchRebirths)
for _, plr in ipairs(Players:GetPlayers()) do
	watchRebirths(plr)
end

----------------------------------------------------------------
-- Client requests
----------------------------------------------------------------
Net.OnServerEvent:Connect(function(plr, action)
	local st = state[plr]
	if not st then
		return
	end

	if action == "Ready" then
		-- Their own raked columns, which for a fresh join is an empty list -- so a
		-- player entering a long-running server still gets a whole unraked beach.
		-- One message per island: the client keeps a separate field per island and
		-- has to know which one each list belongs to.
		for _, isl in ipairs(ISLANDS) do
			Net:FireClient(plr, "Sync", isl.id, cleanIndices(isl, st.grids[isl.id]))
			-- A player who leaves with three columns to go and comes back to them
			-- has exactly the problem the markers exist for, so the join answers it
			-- too rather than waiting for their next rake to trigger it.
			local g = st.grids[isl.id]
			local left = isl.cells - g.cleanCount
			if left > 0 and left <= Config.LAST_FEW then
				Net:FireClient(plr, "LastFew", isl.id, cleanIndices(isl, g, true))
			end
		end
		-- ...and the stair, which is not in that table and has to say so itself.
		StairSrv.sync(plr)

	elseif action == "QuickSell" then
		--[[
			CTB_HUD's QUICK SELL key, and it is a GAME PASS.

			The payload is the word and nothing else: the bag, its worth and
			whether any of it may be sold are all read server-side, so there is no
			field here worth tampering with. It is deliberately NOT
			position-checked -- selling without the walk is the entire thing that
			was bought -- and sell()'s own 0.4s debounce plus SellServer's cooldown
			are what stop a held-down button from hammering the till.

			THE REFRESH IS RATIONED, and the ration is the point rather than the
			politeness. `refresh` makes GamePassService go and ASK Roblox when its
			record is not already yes, which yields on a web call -- so without a
			cooldown this remote is a way for one client to make the server hammer
			UserOwnsGamePassAsync. With it, a player whose join sweep hit a network
			blip still gets one re-ask every few seconds instead of being refused
			the pass they paid for until they rejoin.
		]]
		local now = os.clock()
		local mayAsk = now - st.lastPassAsk >= PASS_REASK_SECONDS
		if mayAsk then
			st.lastPassAsk = now
		end
		if not Passes.ownsFlat(plr, "QuickSell", mayAsk) then
			-- Through Deny, which CTB_HUD already draws as a toast. The client
			-- normally opens the purchase dialog itself rather than sending at
			-- all, so reaching this means either a forged message or an ownership
			-- attribute that has not landed yet -- and the second one deserves a
			-- sentence rather than a button that silently does nothing.
			Net:FireClient(plr, "Deny", "Quick Sell is a game pass \u{2014} get it to sell from anywhere!")
			return
		end

		local char = plr.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		sell(plr, hrp)

	elseif action == "Upgrade" then
		if os.clock() - st.lastUpgrade < 0.25 then
			return
		end
		st.lastUpgrade = os.clock()

		-- RETIRED, AND IT HAS TO REFUSE RATHER THAN QUIETLY CHARGE.
		--
		-- The sifter ladder belongs to ProgressionServer's RollerWidth track now,
		-- and its applyAll rewrites RollerLevel / RollerWidth off that track on
		-- join, after every purchase and on every respawn. So what this branch did
		-- was take the coins, grant a level, and have it overwritten the next time
		-- the player died -- money paid for nothing that lasts. CTB_HUD's own
		-- upgrade card is already hidden (upPanel.Visible = false) so no button
		-- reaches this, but the remote is still live and a charge the player
		-- cannot keep is worse than a refusal that tells them where to go.
		--
		-- To bring the kiosk back, the two ladders have to be merged first: this
		-- branch would spend through ProgressionServer's RollerWidth track rather
		-- than reimplementing it against Config.LEVELS at its own prices.
		if not CTB_KIOSK_SELLS_UPGRADES then
			Net:FireClient(plr, "Deny", "Buy sifter upgrades at the Beach Shop!")
			return
		end

		local level = plr:GetAttribute("RollerLevel")
		local nxt = Config.LEVELS[level + 1]
		if not nxt then
			Net:FireClient(plr, "Deny", "Roller is already maxed out!")
			return
		end
		-- Same one balance the sell pad and the shop use, read and spent through
		-- the same function they use. (`or 0` is gone with it: Bridge.coins always
		-- answers a number, where the raw attribute could still be nil.)
		local coins = Bridge.coins(plr)
		if coins < nxt.cost then
			Net:FireClient(plr, "Deny", string.format("Need %d more coins", nxt.cost - coins))
			return
		end

		Bridge.addCoins(plr, -nxt.cost, "plot")
		plr:SetAttribute("RollerLevel", level + 1)
		plr:SetAttribute("RollerWidth", nxt.width)
		Net:FireClient(plr, "Upgraded", level + 1, nxt.width)
	end
end)

----------------------------------------------------------------
-- World build, then the sand
----------------------------------------------------------------
-- ORDER MATTERS. Island2Builder fills the desert island's landmass -- a solid
-- plateau up to y = 3 -- and the field write below carves the rakeable columns
-- into the top of it. Run in the other order the plateau simply buries them.
local ok, err = pcall(function()
	local Island2 = require(game:GetService("ServerScriptService"):WaitForChild("Island2Builder"))
	local pad = Island2.build()
	if pad then
		table.insert(sellPads, pad)
	end
end)
if not ok then
	-- The beach must still come up if the desert fails to build. A broken second
	-- island is a missing area; a broken boot is a dead game.
	warn("[CleanTheBeach] Island 2 failed to build: " .. tostring(err))
end

-- The treasure chamber behind the pyramid door. Same deal: its own pcall, so a
-- failure in there costs the vault and nothing else.
local okVault, errVault = pcall(function()
	local Vault = require(game:GetService("ServerScriptService"):WaitForChild("VaultBuilder"))
	local pad = Vault.build()
	if pad then
		table.insert(sellPads, pad)
	end
end)
if not okVault then
	warn("[CleanTheBeach] the vault failed to build: " .. tostring(errVault))
end

-- Wire the tomb's exit to the pyramid's plaza, now that both builders have run.
--
-- The two builders each own one side of the door -- Island2Builder the door,
-- VaultBuilder the room behind it -- and neither should have to load before the
-- other to be correct. So Island2Builder PUBLISHES where its plaza is and this,
-- the one place that already sequences both builds, joins them up.
--
-- The print is not decoration: module state is not inspectable from outside the
-- game's own script VM, so a line in the log is the only way to see at a glance
-- that the tomb's exit actually points at the pyramid and not at its fallback.
local okWire, errWire = pcall(function()
	local SSS = game:GetService("ServerScriptService")
	local Island2 = require(SSS:WaitForChild("Island2Builder"))
	local Vault = require(SSS:WaitForChild("VaultBuilder"))
	if Island2.plazaCF then
		Vault.returnCF = Island2.plazaCF
		print(string.format("[CleanTheBeach] vault exit -> %s",
			tostring(Vault.returnCF.Position)))
	else
		warn("[CleanTheBeach] no pyramid plaza to return to; the vault exit will use its fallback")
	end
end)
if not okWire then
	warn("[CleanTheBeach] could not wire the vault exit: " .. tostring(errWire))
end

-- Sakura Cove, north of the beach. Same ordering rule as the desert and for the
-- identical reason: Island3Builder fills a solid plateau up to y = 3 and the
-- field write below carves the cove's rakeable columns into the top of it, so
-- building it after baselineField() would simply bury them.
--
-- Its own pcall, like the two above. The cove owns the third destination, both
-- of its travel gates and its own sell pad, and none of that is worth the beach
-- failing to come up for -- a broken island is a missing area, a broken boot is
-- a dead game.
--
-- The pad matters more here than it does for the dunes. The cove's way home is
-- deliberately never level-locked, but a player who fills a bag out there with
-- no pad to sell at has to walk the whole way back to the beach to empty it --
-- so if the build half-fails, the missing pad is the part that shows.
local okCove, errCove = pcall(function()
	local Island3 = require(game:GetService("ServerScriptService"):WaitForChild("Island3Builder"))
	local pad = Island3.build()
	if pad then
		table.insert(sellPads, pad)
	end
end)
if not okCove then
	warn("[CleanTheBeach] Sakura Cove failed to build: " .. tostring(errCove))
	-- The pad is built two thirds of the way through build() and published on
	-- the module the moment it exists, precisely so a throw in the last third
	-- does not leave a glowing, fully-signed sell pad standing in the world that
	-- nothing pays out for. Recover it if it got that far.
	local okPad, mod = pcall(function()
		return require(game:GetService("ServerScriptService"):WaitForChild("Island3Builder"))
	end)
	if okPad and type(mod) == "table" and typeof(mod.sellPad) == "Instance" and mod.sellPad:IsA("BasePart") then
		table.insert(sellPads, mod.sellPad)
		warn("[CleanTheBeach] ...but the cove's sell pad was built before it failed, so it still pays out")
	end
end

--[[
	ASHFALL ISLE, 2200 studs west. Same ordering rule as the other three and for
	the identical reason: Island4Builder fills a solid plateau up to y = 3 and the
	field write below carves this island's rakeable columns into the top of it, so
	building it after baselineField() would simply bury them.

	Its own pcall, like the three above. This is the biggest area in the game -- a
	480-stud plateau, a 186-stud volcano, a camp, a stair, three lava flows and
	seven hundred scattered props -- and none of it is worth the beach failing to
	come up for.

	The pad matters as much here as it does at the cove and for a harder reason:
	the way home is a ferry, and a player who fills a bag on the far side of the
	map with no pad to sell at is 2200 studs of open water from the nearest one.
]]
local okAsh, errAsh = pcall(function()
	local Island4 = require(game:GetService("ServerScriptService"):WaitForChild("Island4Builder"))
	local pad = Island4.build()
	if pad then
		table.insert(sellPads, pad)
	end
end)
if not okAsh then
	warn("[CleanTheBeach] Ashfall Isle failed to build: " .. tostring(errAsh))
	-- The pad is built a third of the way through that build() and published on the
	-- module the moment it exists, precisely so a throw in the two thirds that
	-- follow does not leave a glowing, fully-signed sell pad standing in the world
	-- that nothing pays out for. Recover it if it got that far.
	local okPad, mod = pcall(function()
		return require(game:GetService("ServerScriptService"):WaitForChild("Island4Builder"))
	end)
	if okPad and type(mod) == "table" and typeof(mod.sellPad) == "Instance"
		and mod.sellPad:IsA("BasePart") then
		table.insert(sellPads, mod.sellPad)
		warn("[CleanTheBeach] ...but Ashfall's sell pad was built before it failed, so it still pays out")
	end
end

--[[
	THE INNER SHRINE, behind the cove's shrine door. The tomb's arrangement,
	restated for Sakura Cove: a clickable door on the island, a cinematic, and a
	sealed hall 1500 studs away that is Config.ISLANDS[6] and rakes like anywhere
	else.

	AFTER THE COVE, not before, and for a reason the other builders do not have:
	ShrineBuilder.buildEntrance levels a patch of the cove's north shore and
	shifts two of its props off the site. Run before Island3Builder it would do
	both to terrain and props that are about to be replaced.

	BEFORE baselineField(), like every other island: buildFloor fills the hall's
	landmass up to y = 3 and the field write below carves the rakeable columns
	into the top of it. The other way round the fill simply buries them.

	ONE pcall around BOTH halves, unlike the tomb's two. There is no useful state
	where the room exists and the door does not, or the reverse -- a door that
	opens onto nothing is worse than no door -- so if either end throws the whole
	feature is skipped and the rest of the game comes up regardless.
]]
local okShrine, errShrine = pcall(function()
	local SShrine = require(game:GetService("ServerScriptService"):WaitForChild("ShrineBuilder"))
	local pad = SShrine.build()
	if pad then
		table.insert(sellPads, pad)
	end
	SShrine.buildEntrance()
end)
if not okShrine then
	warn("[CleanTheBeach] the inner shrine failed to build: " .. tostring(errShrine))
end

--[[
	THE MAGMA CHAMBER, behind the door cut into Ashfall's volcano. The shrine's
	arrangement, restated for the mountain: a clickable door on the island, a
	cinematic, and a sealed lava-tube hall 5200 studs away that is
	Config.ISLANDS[7] and digs like the black strand outside it.

	AFTER ASHFALL, and this one is not a preference -- it is the only order that
	works. MagmaBuilder.buildEntrance CUTS A BAY into the cone's south face, and
	Island4Builder repours that entire mountain from a FillCylinder every boot.
	Run first, the bay is simply filled back in and the door is left standing
	buried in rock with no approach to it.

	BEFORE baselineField(), like every other island: buildFloor fills the hall's
	landmass up to y = 3 and the field write below carves the rakeable columns
	into the top of it. The other way round the fill just buries them.

	ONE pcall around BOTH halves, the shrine's arrangement rather than the
	tomb's two. There is no useful state where the room exists and the door does
	not, or the reverse. The pad is NOT recovered on failure the way Ashfall's
	is, and deliberately: Ashfall's pad stands on an island players are already
	walking around, so a live pad with a dead builder still pays out for them --
	this one is inside a sealed room that can only be reached through the door
	that just failed to build, so there is nobody to pay.
]]
local okMagma, errMagma = pcall(function()
	local Magma = require(game:GetService("ServerScriptService"):WaitForChild("MagmaBuilder"))
	local pad = Magma.build()
	if pad then
		table.insert(sellPads, pad)
	end
	Magma.buildEntrance()
end)
if not okMagma then
	warn("[CleanTheBeach] the magma chamber failed to build: " .. tostring(errMagma))
end

--[[
	PENGUIN ISLAND (ISLANDS[8]) and THE FROZEN WRECK (ISLANDS[9]), 2026-09.

	The island first, because the wreck's hull stands on ground Island5Builder
	repours every boot; both before baselineField() for the same reason every
	builder above is. The island's block carries the sellPad recovery the
	Ashfall block has -- Island5Builder publishes .sellPad the moment the
	landing exists, so a failure further down the build still leaves a pad that
	pays out. The wreck's does not, for the reason the magma block gives.

	Both wrapped in do ... end: this script sits close to the 200-local ceiling
	and four more top-level locals would have tipped it over.
]]
do
	local okPenguin, errPenguin = pcall(function()
		local Island5 = require(game:GetService("ServerScriptService"):WaitForChild("Island5Builder"))
		local pad = Island5.build()
		if pad then
			table.insert(sellPads, pad)
		end
	end)
	if not okPenguin then
		warn("[CleanTheBeach] Penguin Island failed to build: " .. tostring(errPenguin))
		pcall(function()
			local Island5 = require(game:GetService("ServerScriptService"):WaitForChild("Island5Builder"))
			if Island5.sellPad and not table.find(sellPads, Island5.sellPad) then
				table.insert(sellPads, Island5.sellPad)
				warn("[CleanTheBeach] Penguin Island's sell pad was recovered from the partial build")
			end
		end)
	end
end

do
	local okWreck, errWreck = pcall(function()
		local FrozenWreck = require(game:GetService("ServerScriptService"):WaitForChild("FrozenWreckBuilder"))
		local pad = FrozenWreck.build()
		if pad then
			table.insert(sellPads, pad)
		end
		FrozenWreck.buildEntrance()
	end)
	if not okWreck then
		warn("[CleanTheBeach] the frozen wreck failed to build: " .. tostring(errWreck))
	end
end

baselineField()

--[[
	THE SKIN CENTREPIECES, one in each of the three interiors.

	AFTER all three rooms and AFTER baselineField(), and both halves of that
	matter. The rooms because each stand is parented into its own room's folder
	and a room that failed to build simply gets no stand; baselineField because
	the stands find their floor by RAYCASTING the finished terrain rather than
	trusting cleanY -- the shrine's boards render a full stud proud of the
	number its field is written at, which is the trap ShrineBuilder's BOARD_Y
	note records.

	They stand OUTSIDE every rakeable square by construction (the Z of each is
	derived from its own field's south edge) and the builder re-checks the
	finished model's real extents against that square before it registers it.
	One unreachable cell and an island never turns over again, so that check is
	load-bearing rather than advisory.

	Its own pcall, like every builder above: three missing display stands is a
	missing feature, and a throw here would take the whole boot with it.
]]
local okSkins, errSkins = pcall(function()
	local Plinths = require(game:GetService("ServerScriptService"):WaitForChild("SkinPlinthBuilder"))
	Plinths.buildAll()
end)
if not okSkins then
	warn("[CleanTheBeach] the skin centrepieces failed to build: " .. tostring(errSkins))
end

-- The Ashen Stair, once the mountain it climbs actually exists. It is not a
-- field and takes no part in baselineField; this only wires up its state and
-- prints what it found, so a stair that failed to build says so at boot instead
-- of being silently unsweepable.
local okStair, errStair = pcall(function()
	StairSrv.start(Net)
end)
if not okStair then
	warn("[Stair] the Ashen Stair could not be armed: " .. tostring(errStair))
end

----------------------------------------------------------------
-- THE FERRY
--
-- The only way between the four islands. It replaced the pair-of-gateways scheme
-- (one arch per route, so the beach was growing a row of them and a fourth
-- island would have needed three more -- which is exactly what Ashfall would
-- have cost); FerryConfig carries the routes and the Sifter level each landing
-- asks for: Beach Lv.1, Dunes Lv.3, Cove Lv.5, Ashfall Lv.6. The first three are
-- the numbers the gates used, so nothing about the old progression moved; the
-- fourth is the top of the ladder, which is the point of it.
--
-- AFTER baselineField(), NOT BEFORE, and that is the whole reason this block
-- sits down here rather than up with the island builders. A berth is placed by
-- RAYCASTING the finished terrain of the island it belongs to (see the survey
-- note in FerryConfig, which records the measured waterline on each axis), so
-- it has to run once the fields have actually been carved. Built earlier it
-- reads the plateau before the rakeable columns exist and moors the boat at the
-- wrong height.
--
-- Its own pcall, like the three builders above: no ferry is a game you cannot
-- travel in, but a throw here would take the whole boot down with it.
local okFerry, errFerry = pcall(function()
	local Ferry = require(game:GetService("ServerScriptService"):WaitForChild("FerryServer"))
	Ferry.start()
end)
if not okFerry then
	warn("[CleanTheBeach] the ferry failed to start: " .. tostring(errFerry))
end

----------------------------------------------------------------
-- THE WALKABLE GROUND ROUND EVERY SHOP, BAY AND CAR PAD
--
-- LAST OF THE WORLD PASSES, and that ordering is the whole reason it is a pass
-- rather than a fix in each builder. Island4Builder REBUILDS its island from
-- source on every boot, so anything done to Ashfall's geometry before this line
-- is thrown away; Island2 and Island3 carry HandBuilt and ADOPT the place file,
-- so their builders' own layout code never runs at all. Softening the dressing
-- once, after everything is standing, is the only fix that reaches all three.
--
-- It moves and deletes nothing -- it clears CanCollide on plaza dressing that
-- has ended up inside a service's apron, and names anything it left solid.
--
-- Its own pcall, like the builders above: catching on a lantern is a nuisance,
-- and a nuisance must not be able to take the boot down with it.
local okClear, errClear = pcall(function()
	local ServiceClearance = require(
		game:GetService("ServerScriptService"):WaitForChild("ServiceClearance"))
	ServiceClearance.apply()
end)
if not okClear then
	warn("[CleanTheBeach] service clearance failed: " .. tostring(errClear))
end

----------------------------------------------------------------
-- THE SEA WALLS
--
-- An invisible fence in the water round every shore, so the only way between
-- the islands is the boat. The gaps are 500 to 900 studs of open water and the
-- ferry gates are the whole of the game's pacing (Dunes 1, Cove 8, Ashfall 19
-- rebirths), so a swim is not a shortcut -- it is the ladder skipped.
--
-- TRULY LAST, after the ferry AND after service clearance, and that is a hard
-- requirement rather than tidiness. Every number in a fence is MEASURED off the
-- finished world: what is standing on each island, how far out its boat runs,
-- and where its terrain stops coming up above the waterline. Island4Builder
-- repours the whole of Ashfall from source every boot, so a survey taken before
-- that line is a survey of geometry that no longer exists.
--
-- Its own pcall, like every builder above. No fence is the game exactly as it
-- was last week; a throw here would take the whole boot down with it.
local okWalls, errWalls = pcall(function()
	local SeaWall = require(game:GetService("ServerScriptService"):WaitForChild("SeaWallBuilder"))
	SeaWall.build()
	SeaWall.start()
end)
if not okWalls then
	warn("[CleanTheBeach] the sea walls failed to build: " .. tostring(errWalls))
end

for _, isl in ipairs(ISLANDS) do
	print(string.format("[CleanTheBeach] %s: %dx%d columns (%d studs across) centred (%d, %d)",
		isl.name, isl.grid, isl.grid, isl.grid * Config.TILE, isl.cx, isl.cz))
end
print("[CleanTheBeach] per-player state, terrain ready")
