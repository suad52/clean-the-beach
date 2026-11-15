--[[
	CarSpawnerBuilder  --  ServerScriptService.CarSpawnerBuilder

	Builds the car spawner pad beside the wash bay.

	TWO PADS IN ONE BUILDER, and the difference is `opts.showroom`:

		plain      one bay, 16 x 22. Somewhere for YOUR machine to appear. This
		           is what the dune, cove and ashfall pads are, and it is exactly
		           the pad this file has always built.
		showroom   one bay per machine in the shop, plus one in the middle to
		           deliver yours into. 53 x 36 for the two machines currently on
		           sale. The beach pad is this one.

	A SHOWROOM PAD STANDS THE STOCK ON IT. The display bays get a plinth and a
	DisplayPoint, and AtvServer parks an inert copy of the real machine on each
	one at boot -- so somebody who owns nothing still walks up to a bulldozer and
	a thirty-stud truck rather than to an empty rectangle with a sign over it.
	Nothing below counts to three: the bay row is measured off AtvConfig.Tiers,
	so a third machine widens the pad on its own.

	WHY THE COVE PAD IS NOT ONE. It sits inside the kagura-den, boxed in by four
	pillars 12 studs off centre. A showroom row needs about 26 either side, so
	the pavilion would have to move -- and a shrine is a worse thing to demolish
	than a showroom is to do without.

	ADOPTION CONTRACT
	-----------------
	Same as BayBuilder: a fallback, not an owner. If a Model already carries the
	CarSpawner tag this does nothing, so the moment a nicer pad is hand-built in
	Studio and tagged, this code stops running and the authored one stands.

	WHAT A LATER SPAWNER WILL READ OFF IT
	-------------------------------------
		CarSpawner (Model)
			SpawnPoint   : BasePart  -- invisible. A vehicle's PrimaryPart goes
			                            HERE, at this CFrame. Its +Z faces out
			                            toward the beach, so a car placed on it
			                            is already pointing down the drive.
			PromptAnchor : BasePart  -- invisible. Where the E prompt belongs
			                            once there is something to summon.

	Deliberately NO ProximityPrompt. A prompt with nothing behind it is a button
	that lies to the player -- it would read as "press E for a car" and do
	nothing at all. The anchor is there; the prompt is one line whenever the
	first vehicle exists.

	WHERE IT SITS
	-------------
	(-52, 3.2, -171), which is:
	  * immediately left of the wash bay (-30.02), continuing the row outward
	    with a ~9 stud alley, the same gap the other three buildings keep;
	  * on flat sand at y = 3.20 (probed), the same floor height as the bay;
	  * OUTSIDE Clean the Beach's rakeable field, which spans -128..128 on both
	    axes -- anything inside it would sit on terrain the player rakes.
	The pad faces +Z, out toward the beach, like every other frontage in the row.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local SignKit = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("SignKit"))
-- For the BAY COUNT only. A showroom pad is one bay per machine on sale plus
-- one, so the shop's own table is what decides how wide the slab is.
local AtvConfig = require(ReplicatedStorage:WaitForChild("AtvConfig"))

local CarSpawnerBuilder = {}

CarSpawnerBuilder.TAG = "CarSpawner"

--[[
	TWO PADS, TWO PALETTES.

	Concrete and asphalt on the beach, because a vehicle pad is the one thing
	on that sand that would actually be paved -- amber is its accent the way
	the wash bay has sea blue, and the sign keeps the row's timber post and
	dark board so it still reads as the same little frontage.

	The dunes get the same pad in the desert's own stone and gold. It is one
	palette swap and not a second builder, for the reason the ferry berths give
	for their three skins: a second copy of two hundred studs of kerb, hatching
	and bay marking is a second copy to keep in step.

	NO Sandstone PART MATERIAL in either. It renders mauve-grey under this
	sky whatever colour is underneath it -- Island2Builder converts its whole
	island to Concrete at the end of its build for exactly this reason -- so
	the desert pad is Slate and Concrete wearing warm colours.
]]
local PALETTES = {
	beach = {
		pad = Color3.fromRGB(62, 64, 70),
		padLit = Color3.fromRGB(78, 80, 88),
		padMat = Enum.Material.Asphalt,
		kerb = Color3.fromRGB(150, 148, 142),
		kerbMat = Enum.Material.Concrete,
		line = Color3.fromRGB(238, 232, 212),
		post = Color3.fromRGB(99, 66, 40),
		postMat = Enum.Material.Wood,
		sign = Color3.fromRGB(38, 42, 48),
		accent = Color3.fromRGB(226, 168, 52),
	},
	desert = {
		pad = Color3.fromRGB(122, 92, 62),
		padLit = Color3.fromRGB(146, 112, 76),
		padMat = Enum.Material.Slate,
		kerb = Color3.fromRGB(206, 176, 126),
		kerbMat = Enum.Material.Concrete,
		line = Color3.fromRGB(238, 230, 206),
		post = Color3.fromRGB(160, 114, 64),
		postMat = Enum.Material.Concrete,
		sign = Color3.fromRGB(40, 78, 150),
		accent = Color3.fromRGB(240, 194, 82),
	},
}

local PLAIN_W, PLAIN_D = 16, 22  -- the one-bay pad: across, and front-to-back
local PAD_TOP = 0.4              -- pad surface, relative to origin

--[[
	BAY PITCH, and it is set by the widest thing that has to stand in one.

	The bulldozer is 14.2 across the blade and the tipper 13.8, so 17 leaves
	about a stud and a half of air either side -- enough that a machine reads as
	parked in a bay rather than wedged into one, and enough that a machine
	SPAWNING into the middle bay cannot arrive intersecting the stock beside it.
]]
local BAY_PITCH = 17
local BAY_HALF_PLAIN = 4.6       -- the original pad's painted lane
local BAY_HALF_SHOW = 7.6        -- a 15.2 lane for a 14.2 machine

--[[
	The row of bays, measured out from the middle.

	The LIVE bay -- the one a player's own machine is delivered into -- is the
	centre of the row, so the stock flanks it and a spawned machine arrives in
	the middle of the showroom rather than tacked onto one end. Everything else
	is a display bay, filled from the shop's table in order.

	A plain pad is the degenerate case of the same thing: one bay, and it is the
	live one. That is deliberate -- it means there is no second code path to
	keep in step, and the plain pad's numbers below come out byte-identical to
	the ones this file used before the showroom existed.
]]
local function layoutFor(showroom: boolean?)
	if not showroom then
		return {
			width = PLAIN_W, depth = PLAIN_D, thick = 1.6, bayHalf = BAY_HALF_PLAIN,
			bays = { { x = 0, live = true } },
		}
	end

	local tiers = AtvConfig.Tiers
	local total = #tiers + 1
	local liveAt = math.ceil(total / 2)
	local bays, nextTier = {}, 1
	for i = 1, total do
		local x = (i - (total + 1) * 0.5) * BAY_PITCH
		if i == liveAt then
			bays[i] = { x = x, live = true }
		else
			bays[i] = { x = x, tier = tiers[nextTier] }
			nextTier += 1
		end
	end

	return {
		-- 3.0 thick, not 1.6. The ground under the wide pad falls 0.93 studs
		-- across it (probed 2.52 at the west end, 3.45 at the east); a slab cut
		-- for the old 16 stud footprint would have shown daylight under one end.
		width = total * BAY_PITCH + 2, depth = 36, thick = 3.0,
		bayHalf = BAY_HALF_SHOW, bays = bays,
	}
end

--[[
	`opts` is optional and every field of it is: { name, palette, sign }.
	Omitted, this builds exactly the beach pad it always did.
]]
function CarSpawnerBuilder.build(origin: CFrame, opts): Model
	opts = opts or {}
	local skin = PALETTES[opts.palette or "beach"] or PALETTES.beach
	local L = layoutFor(opts.showroom)
	-- Shadowing the old module-level names on purpose: every measurement below
	-- this line was written against PAD_W and PAD_D and is correct for either
	-- pad once those two mean "this pad" rather than "the only pad there was".
	local PAD_W, PAD_D = L.width, L.depth

	local model = Instance.new("Model")
	model.Name = opts.name or "CarSpawner"

	local function part(props): BasePart
		local p = Instance.new("Part")
		p.Anchored = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		local offset = props.Offset
		for k, v in props do
			if k ~= "Offset" then
				p[k] = v
			end
		end
		p.CFrame = origin * offset
		p.Parent = model
		return p
	end

	-- Decoration: out of every spatial query, and never in the way of a vehicle
	-- that has to drive off this thing.
	local function trim(props)
		props.CanCollide = false
		props.CanQuery = false
		props.CanTouch = false
		return part(props)
	end

	------------------------------------------------------------------
	-- THE PAD
	------------------------------------------------------------------
	-- Sunk so its top face sits at PAD_TOP and the slab's own depth is buried.
	-- The ground under either of these is not perfectly level (the beach strip
	-- probed 3.02 - 3.33), so a thin slab laid flat would show daylight under
	-- one corner.
	part({
		Name = "Pad",
		Size = Vector3.new(PAD_W, L.thick, PAD_D),
		Color = skin.pad,
		Material = skin.padMat,
		Offset = CFrame.new(0, PAD_TOP - L.thick * 0.5, 0),
	})

	-- Worn patches, so it is not one flat rectangle of colour. Spread across
	-- whatever width this pad is, or three scuffs sit huddled in the middle of
	-- a fifty stud slab.
	local spread = PAD_W / PLAIN_W
	for _, raw in { Vector3.new(-3.4, 0, 4.2), Vector3.new(2.8, 0, -2.6), Vector3.new(4.1, 0, 6.9) } do
		local spot = Vector3.new(raw.X * spread, 0, raw.Z)
		trim({
			Name = "Wear",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(5.5 + spot.X * 0.3, 0.06, 4.2 + spot.Z * 0.2),
			Color = skin.padLit,
			Material = skin.padMat,
			Transparency = 0.3,
			Offset = CFrame.new(spot.X, PAD_TOP + 0.03, spot.Z),
		})
	end

	------------------------------------------------------------------
	-- BAY MARKINGS  --  what says "a vehicle goes here" without a vehicle
	------------------------------------------------------------------
	-- Two side lines and a stop bar at the back of EVERY bay, open at the front
	-- so a bay reads as something you drive OUT of.
	--
	-- The line runs from the stop bar forward to 3.5 studs shy of the mouth,
	-- which puts its centre at -1.5 whatever the pad's depth is -- the same
	-- number the single-bay pad has always used, arrived at rather than copied.
	local lineLen = PAD_D - 7
	local stopZ = -PAD_D * 0.5 + 2
	local mouthZ = PAD_D * 0.5 - 1.8

	for _, bay in L.bays do
		for _, sx in { -1, 1 } do
			trim({
				Name = "BayLine",
				Size = Vector3.new(0.4, 0.06, lineLen),
				Color = skin.line,
				Material = Enum.Material.SmoothPlastic,
				Offset = CFrame.new(bay.x + sx * L.bayHalf, PAD_TOP + 0.05, -1.5),
			})
		end
		trim({
			Name = "StopBar",
			Size = Vector3.new(L.bayHalf * 2 + 0.4, 0.06, 0.5),
			Color = skin.line,
			Material = Enum.Material.SmoothPlastic,
			Offset = CFrame.new(bay.x, PAD_TOP + 0.05, stopZ),
		})

		if bay.live then
			-- Hatched apron across the mouth of the bay a machine DRIVES out of.
			-- On a showroom pad this is also what marks the empty middle bay as
			-- reserved rather than as missing stock.
			for i = 0, 5 do
				trim({
					Name = "Hatch",
					Size = Vector3.new(0.35, 0.06, 3.4),
					Color = skin.accent,
					Material = Enum.Material.SmoothPlastic,
					Transparency = 0.15,
					Offset = CFrame.new(bay.x - 5.6 + i * 2.25, PAD_TOP + 0.05, mouthZ)
						* CFrame.Angles(0, math.rad(38), 0),
				})
			end
		else
			-- A low dais under the stock, so a display bay reads as a showroom
			-- plinth and not as a bay somebody has parked in.
			trim({
				Name = "Plinth",
				Size = Vector3.new(L.bayHalf * 2 - 1, 0.3, PAD_D - 8),
				Color = skin.kerb,
				Material = skin.kerbMat,
				Offset = CFrame.new(bay.x, PAD_TOP + 0.15, -1.5),
			})
			trim({
				Name = "PlinthEdge",
				Size = Vector3.new(L.bayHalf * 2 - 1, 0.08, 0.4),
				Color = skin.accent,
				Material = Enum.Material.Metal,
				Offset = CFrame.new(bay.x, PAD_TOP + 0.32, -1.5 + (PAD_D - 8) * 0.5),
			})
		end
	end

	------------------------------------------------------------------
	-- KERB  --  back and sides. The front stays open to drive out of.
	------------------------------------------------------------------
	trim({
		Name = "KerbBack",
		Size = Vector3.new(PAD_W, 0.7, 0.7),
		Color = skin.kerb,
		Material = skin.kerbMat,
		Offset = CFrame.new(0, PAD_TOP + 0.35, -PAD_D * 0.5 + 0.35),
	})
	for _, sx in { -1, 1 } do
		trim({
			Name = "KerbSide",
			Size = Vector3.new(0.7, 0.7, PAD_D - 1.4),
			Color = skin.kerb,
			Material = skin.kerbMat,
			Offset = CFrame.new(sx * (PAD_W * 0.5 - 0.35), PAD_TOP + 0.35, 0),
		})
	end

	-- Bollards at the mouth, so the open end still has an edge.
	for _, sx in { -1, 1 } do
		trim({
			Name = "Bollard",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(2.6, 0.55, 0.55),
			Color = skin.accent,
			Material = Enum.Material.Metal,
			Offset = CFrame.new(sx * (PAD_W * 0.5 - 0.5), PAD_TOP + 1.3, PAD_D * 0.5 - 0.8)
				* CFrame.Angles(0, 0, math.rad(90)),
		})
		trim({
			Name = "BollardBand",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.35, 0.62, 0.62),
			Color = skin.line,
			Material = Enum.Material.SmoothPlastic,
			Offset = CFrame.new(sx * (PAD_W * 0.5 - 0.5), PAD_TOP + 2.15, PAD_D * 0.5 - 0.8)
				* CFrame.Angles(0, 0, math.rad(90)),
		})
	end

	------------------------------------------------------------------
	-- THE PARTS A SPAWNER ACTUALLY READS
	------------------------------------------------------------------
	local marker = {
		Size = Vector3.new(1, 1, 1),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
	}
	local function markerAt(name: string, offset: CFrame): BasePart
		local props = table.clone(marker)
		props.Name = name
		props.Offset = offset
		return part(props)
	end

	for _, bay in L.bays do
		if bay.live then
			-- Where a vehicle's PrimaryPart goes. Lifted clear of the pad so a
			-- car pivoted onto it drops onto its wheels rather than starting
			-- inside the surface, and facing +Z so it is already pointed down
			-- the drive.
			markerAt("SpawnPoint", CFrame.new(bay.x, PAD_TOP + 2.5, -1))
		else
			--[[
				Where AtvServer stands the stock.

				ON THE PLINTH, NOT 2.5 STUDS OVER IT. A display machine is
				anchored and never falls, so the drop height the live bay needs
				would leave a bulldozer hovering -- the builders put y = 0 at the
				sand under the tracks, so the marker IS where the ground should be.

				The tier is carried as an attribute rather than baked into the
				name: AtvServer looks these up without having to parse anything,
				and a renamed machine cannot orphan its own plinth.
			]]
			local point = markerAt("DisplayPoint", CFrame.new(bay.x, PAD_TOP + 0.3, -1))
			point:SetAttribute("Tier", bay.tier.id)
		end
	end

	-- Where AtvServer hangs its E prompt.
	markerAt("PromptAnchor", CFrame.new(0, PAD_TOP + 3.2, PAD_D * 0.5 - 2))

	------------------------------------------------------------------
	-- SIGN
	------------------------------------------------------------------
	-- On the side people walk up from, not the outer one. A board on the far
	-- edge faces nothing and is edge-on from the only direction anyone comes.
	trim({
		Name = "SignPost",
		Size = Vector3.new(0.4, 9.0, 0.4),
		Color = skin.post,
		Material = skin.postMat,
		Offset = CFrame.new(PAD_W * 0.5 + 0.8, 4.5, PAD_D * 0.5 - 2.5),
	})

	local board = trim({
		Name = "SignBoard",
		Size = Vector3.new(0.3, 1.9, 4.6),
		Color = skin.sign,
		Material = Enum.Material.SmoothPlastic,
		Offset = CFrame.new(PAD_W * 0.5 + 0.95, 8.2, PAD_D * 0.5 - 2.5),
	})

	-- BOTH faces. A thin board has two readable sides and signing only one is a
	-- coin flip you lose half the time -- the lesson the wash bay's own board
	-- records after it read as an unlabelled shed from the side people walk up.
	-- SignKit takes a face list for exactly this reason.
	SignKit.dress(board, opts.sign or "CAR SPAWN", { Enum.NormalId.Left, Enum.NormalId.Right })

	trim({
		Name = "SignTrim",
		Size = Vector3.new(0.34, 0.3, 5.0),
		Color = skin.accent,
		Material = Enum.Material.Metal,
		Offset = CFrame.new(PAD_W * 0.5 + 0.95, 9.3, PAD_D * 0.5 - 2.5),
	})

	model.PrimaryPart = model:FindFirstChild("Pad")
	model:SetAttribute("Showroom", opts.showroom == true)
	--[[
		HOW FAR THE PAD'S OWN PROMPT REACHES, stamped here because the pad is the
		only thing that knows how wide it is.

		9 was measured against a 16 stud pad: far enough to cover it, close
		enough not to swallow the driver's door of a machine standing 6.6 studs
		away (see the Enter prompt in AtvServer.spawn for what that cost). A 53
		stud frontage with stock at either end needs 20, or somebody walking up to
		the bulldozer at the left-hand bay is stood in front of the shop with no
		way to open it.

		That is safe now in a way it would not have been then: the machine's own
		Enter prompt is Exclusivity.AlwaysShow, so the two no longer compete for E.
	]]
	model:SetAttribute("PromptReach", opts.showroom and 20 or 9)
	model.Parent = workspace
	CollectionService:AddTag(model, CarSpawnerBuilder.TAG)
	return model
end

-- The beach's, and the original contract: ANY tagged pad anywhere means this
-- does nothing, so a hand-built one in Studio takes over completely.
function CarSpawnerBuilder.ensureWorld(origin: CFrame, opts)
	assert(RunService:IsServer(), "[CarSpawnerBuilder] server-only")
	if #CollectionService:GetTagged(CarSpawnerBuilder.TAG) > 0 then
		return
	end
	CarSpawnerBuilder.build(origin, opts)
end

--[[
	A SECOND PAD, ON ANOTHER ISLAND.

	`ensureWorld` cannot be used for this: it stands down the moment ANY tagged
	pad exists anywhere, and the beach's is built first, so the dunes would
	never get one. This asks the narrower question -- is there a pad by THIS
	name -- which keeps the same "a hand-built one wins" contract per pad.

	AtvServer needs nothing told to it. It binds a prompt to every pad carrying
	the tag and to every one that appears later, and `spawnerModel` already
	picks the NEAREST pad to whoever is asking, so a second one is a working
	second car spawner the moment it is tagged.
]]
function CarSpawnerBuilder.ensureAt(name: string, origin: CFrame, opts): Model?
	assert(RunService:IsServer(), "[CarSpawnerBuilder] server-only")
	for _, pad in CollectionService:GetTagged(CarSpawnerBuilder.TAG) do
		if pad.Name == name then
			return pad
		end
	end
	opts = opts or {}
	opts.name = name
	return CarSpawnerBuilder.build(origin, opts)
end

return CarSpawnerBuilder
