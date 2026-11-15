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
local SKY = {
	Up = "rbxassetid://679787023", Dn = "rbxassetid://680029379",
	Lf = "rbxassetid://679786679", Rt = "rbxassetid://679786411",
	Ft = "rbxassetid://679786832", Bk = "rbxassetid://679786546",
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
	sky.SunAngularSize = 12
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

	-- tropical haze: thick enough to push the horizon back, cool enough that the
	-- warm sand reads against it
	local atmo = ensure("Atmosphere", "Atmosphere")
	atmo.Density = 0.32
	atmo.Offset = 0.15
	atmo.Glare = 0.25
	atmo.Haze = 1.4
	atmo.Color = Color3.fromRGB(199, 214, 224)
	atmo.Decay = Color3.fromRGB(92, 124, 160)

	local bloom = ensure("BloomEffect", "Bloom")
	bloom.Intensity = 0.55
	bloom.Size = 24
	bloom.Threshold = 1.6

	local rays = ensure("SunRaysEffect", "SunRays")
	rays.Intensity = 0.06
	rays.Spread = 0.9

	-- the sand and sea carry the whole palette, so a little extra saturation and
	-- contrast does more here than any amount of extra brightness
	local cc = ensure("ColorCorrectionEffect", "ColorCorrection")
	cc.Brightness = 0
	cc.Contrast = 0.12
	cc.Saturation = 0.18
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

local function seedItems(isl, g)
	for i = 1, isl.cells do
		-- The island goes in so the roll can honour its encasedScale: how often a
		-- find comes up as a crusted lump is per field, not global.
		g.itemAt[i] = (rng:NextNumber() < isl.itemChance) and Config.pickItem(rng, isl) or false
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
local function baselineField()
	for _, isl in ipairs(ISLANDS) do
		Config.writeField(Terrain, isl, 0, isl.grid - 1, 0, isl.grid - 1, function()
			return false
		end)
	end
end

-- The terrain throttle that used to live here is gone with the server's terrain
-- writes. The equivalent dirty-rectangle batching now runs on the client, in
-- CTB_Client's flushField -- see the note there.

local function cleanIndices(isl, g): { number }
	local out = {}
	for i = 1, isl.cells do
		if g.clean[i] then
			table.insert(out, i)
		end
	end
	return out
end

-- Bag was full when we uncovered something: drop it back into a still-messy cell
-- of THAT PLAYER's grid, on the island it came from, so nothing is ever lost.
local function relocate(isl, g, itemId: string)
	for _ = 1, 60 do
		local j = rng:NextInteger(1, isl.cells)
		if not g.clean[j] and not g.itemAt[j] then
			g.itemAt[j] = itemId
			return
		end
	end
end

----------------------------------------------------------------
-- Player state
----------------------------------------------------------------
-- The sift/sell add-on. Everything CTB-specific about it lives in CTBBridge;
-- these five call sites are the only lines of CTB_Server that know it exists.
local Bridge = require(game:GetService("ServerScriptService"):WaitForChild("CTBBridge"))

local state = {}

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
	state[plr] = { bag = {}, lastRoller = nil, lastSell = 0, lastUpgrade = 0, warnedFull = false,
		grids = newGrids(), lastReset = {} }

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
	plr:SetAttribute("RollerLevel", 1)
	plr:SetAttribute("RollerWidth", Config.LEVELS[1].width)
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
local function sell(plr: Player)
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
	Bridge.sell(plr)
end

----------------------------------------------------------------
-- Main sim: work out which cells the sifter swept this tick
----------------------------------------------------------------
local acc = 0
local TICK = 1 / 24

RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc < TICK then
		return
	end
	acc = 0

	for plr, st in pairs(state) do
		local batch = {}
		local blocked = false      -- tried to rake with a full bag

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

		local lv = hrp.CFrame.LookVector
		local look = Vector3.new(lv.X, 0, lv.Z)
		if look.Magnitude < 1e-3 then
			continue
		end
		look = look.Unit
		local right = Vector3.new(-look.Z, 0, look.X)

		local cur = hrp.Position + look * Config.ROLLER_DIST
		cur = Vector3.new(cur.X, 0, cur.Z)
		local last = st.lastRoller or cur
		st.lastRoller = cur

		-- Which field is under the sifter. Standing on the plaza, in the dunes or
		-- on a dock is a real answer of "none" -- the tool still rides along, it
		-- just has no columns to rake. lastRoller is still updated above so the
		-- first stroke back on sand is not a stripe from wherever they wandered.
		local isl = Config.fieldAt(cur)
		if not isl then
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
		local full = not Bridge.hasRoom(plr)
		if not full then
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

		-- swept rectangle covering last -> cur
		local moved = (cur - last).Magnitude
		if moved > 30 then       -- teleport / respawn, don't carve a stripe across the map
			last = cur
			moved = 0
		end
		local centre = (last + cur) * 0.5
		local hw = plr:GetAttribute("RollerWidth") * 0.5
		local hd = (Config.ROLLER_DEPTH + moved) * 0.5

		local ex = math.abs(right.X) * hw + math.abs(look.X) * hd
		local ez = math.abs(right.Z) * hw + math.abs(look.Z) * hd

		local minX = math.max(0, math.floor((centre.X - ex - isl.x0) / Config.TILE))
		local maxX = math.min(isl.grid - 1, math.floor((centre.X + ex - isl.x0) / Config.TILE))
		local minZ = math.max(0, math.floor((centre.Z - ez - isl.z0) / Config.TILE))
		local maxZ = math.min(isl.grid - 1, math.floor((centre.Z + ez - isl.z0) / Config.TILE))

		for iz = minZ, maxZ do
			for ix = minX, maxX do
				local idx = Config.index(isl, ix, iz)
				if not g.clean[idx] then
					local c = Config.cellCentre(isl, ix, iz)
					local d = c - centre
					local u = d.X * right.X + d.Z * right.Z
					local v = d.X * look.X + d.Z * look.Z
					if math.abs(u) <= hw and math.abs(v) <= hd then
						if full then
							blocked = true
							break
						end
						g.clean[idx] = true
						g.cleanCount += 1
						table.insert(batch, idx)

						local found = g.itemAt[idx]
						if found then
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

		-- Once per full-bag episode, not once per tick: the HUD already carries a
		-- permanent BAG FULL hint, so this is the nudge that they just tried to
		-- rake and nothing happened. Re-arms above as soon as there is room.
		if blocked and not st.warnedFull then
			st.warnedFull = true
			Net:FireClient(plr, "BagFull")
		end

		-- To this player alone, and no server terrain write: the raked columns are
		-- theirs, and their client paints them into its own copy of the sand.
		if #batch > 0 then
			Net:FireClient(plr, "Clean", isl.id, batch)
		end
	end
end)

----------------------------------------------------------------
-- Tide reset: YOUR beach is raked -> the sea messes it up again and you get paid
--
-- Personal now, like the field it resets. It fires off one player's own progress
-- and re-seeds only their grid, so finishing your beach never wipes the work of
-- someone standing next to you. Their sand does not change; only yours does.
----------------------------------------------------------------
task.spawn(function()
	while true do
		task.wait(2)
		for plr, st in pairs(state) do
			for _, isl in ipairs(ISLANDS) do
				local g = st.grids[isl.id]
				if g.cleanCount >= isl.cells * isl.resetAt
					and os.clock() - (st.lastReset[isl.id] or 0) > 6 then
					st.lastReset[isl.id] = os.clock()
					for i = 1, isl.cells do
						g.clean[i] = false
					end
					g.cleanCount = 0
					seedItems(isl, g)
					-- Through the bridge, not straight onto the attribute. Both end
					-- up writing the same number, but only this path fires the one
					-- grant hook -- which is what counts the bonus towards the next
					-- rebirth and repaints the shop's purse. Written directly, the
					-- HUD banner announced a bonus the shop had never heard of and
					-- went on refusing upgrades the player could now afford.
					Bridge.addCoins(plr, isl.resetBonus)
					-- no server terrain write: the client re-messes its own field.
					-- The name rides along because the beach calls this a tide and the
					-- desert calls it a sandstorm -- same event, different weather.
					Net:FireClient(plr, "Tide", isl.id, isl.resetBonus, isl.resetName)
				end
			end
		end
	end
end)

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
		end

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

		Bridge.addCoins(plr, -nxt.cost)
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

baselineField()

for _, isl in ipairs(ISLANDS) do
	print(string.format("[CleanTheBeach] %s: %dx%d columns (%d studs across) centred (%d, %d)",
		isl.name, isl.grid, isl.grid, isl.grid * Config.TILE, isl.cx, isl.cz))
end
print("[CleanTheBeach] per-player state, terrain ready")
