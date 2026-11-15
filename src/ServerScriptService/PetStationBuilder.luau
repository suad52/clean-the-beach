--[[
	PetStationBuilder  --  ServerScriptService.PetStationBuilder

	Puts an egg plaza on every island: one TUBE per egg in a row, each tagged
	PetStation with the EggKey attribute PetServer binds its prompt to.

	THE PEDESTAL IS GONE AND THE TUBE REPLACES ALL OF IT.

	What stood here was a sand plate, a wooden plinth, a rim, and a shell mesh
	hovering a stud over the rim with a neon disc under it -- four hand-built
	parts pretending to be a display case. The eggs are now modelled as real
	display cases: a plinth, a glass tube and the egg suspended inside it, one
	per shelf, escalating from a steel-collared jar to an obsidian reliquary.
	So the pedestal is not dressed any more, it is REPLACED -- the model brings
	its own base and the old parts would only ever have shown through it.

	ADOPTION, not replacement, at the PLAZA level -- the same contract
	BayBuilder and StoreBuilder use. If a plaza already exists this re-dresses
	each station in place rather than building a second plaza beside it.
	dressStation() strips a station to its shell and rebuilds it every time, so
	adoption converges instead of branching on which era a station came from:
	running this twice is a no-op, which is what makes it safe from ServerMain
	on every boot.

	WHERE THEY GO
	-------------
	Derived, not hard-coded. Each island row in CTB.Config carries its centre
	(cx, cz) and its field half-width, so the plaza is placed a fixed setback
	BEYOND the field edge -- outside the rakeable area, because anything inside
	it stands on terrain the player levels flat.

	The ground is found by raycast rather than trusted from the island row:
	cleanY is what the FIELD settles at, and the plaza is deliberately not on
	the field.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local PetConfig = require(Modules:WaitForChild("PetConfig"))

local PetStationBuilder = {}

local FOLDER_NAME = "PetStations"
local SAND = Color3.fromRGB(232, 214, 174)
local WOOD = Color3.fromRGB(146, 96, 54)
local WOOD_DARK = Color3.fromRGB(92, 58, 32)
local CREAM = Color3.fromRGB(255, 252, 242)
local INK = Color3.fromRGB(18, 20, 26)

-- Clear space between two BOOTHS, measured wall to wall. PetConfig.StationSpacing
-- is a CENTRE pitch tuned for 5-stud pedestals; a booth round the Celestial tube
-- is fourteen studs across, so the row derives its pitch from the widest one it
-- actually has and only falls back to the config number when that is bigger.
local TUBE_GAP = 5.0

--[[
	THE BOOTH -- how much building goes round a tube.

	The eggs used to stand on a sunken sand disc, which is what they looked like:
	a prop set down on the beach beside four timber buildings. Everything else a
	player walks up to on this island -- the wash bay, the sell shack, the store,
	the car pad -- is a STRUCTURE with a deck, posts, a roof and a board, and the
	eggs read as unfinished next to them for exactly that reason.

	So each tube gets its own shed, sized off the tube rather than fixed: the
	Basic booth is ten studs across and the Celestial's is fourteen, which keeps
	the shelf escalation the tubes were modelled with instead of hiding it inside
	one standard box.

	The FRONT (+Z, the way every plaza is approached) is left open. Back and
	sides are panelled only across their rear half, so the egg is visible from
	the path and from either side, and the booth still reads as a building rather
	than as four posts and a lid.
]]
local BOOTH_MARGIN = 6.4     -- studs of floor round the tube, total across
local BOOTH_RISE = 3.2       -- head height over the tube before the roof
local ROOF_OVERHANG = 2.6    -- how far the eaves stand out past the walls

-- How far over the tube's own top the bars float.
local BARS_LIFT = 1.5

--------------------------------------------------------------------------
-- CTB's island table, reached the same optional way everything else reaches it
--------------------------------------------------------------------------
local function ctbConfig()
	local ctb = ReplicatedStorage:FindFirstChild("CTB")
	local module = ctb and ctb:FindFirstChild("Config")
	if not (module and module:IsA("ModuleScript")) then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" and type(result.ISLANDS) == "table" then
		return result
	end
	warn("[PetStationBuilder] CTB.Config would not load; stations cannot be placed")
	return nil
end

--------------------------------------------------------------------------
-- THE TUBES
--------------------------------------------------------------------------
--[[
	One staged Model per egg under ReplicatedStorage.Assets.EggTubes, each with
	its foot on its own origin so PivotTo(ground) seats it.

	Egg / Tube / Rig, plus a Glow on the three shelves that have emissive parts.
	They are split rather than joined because a MeshPart carries ONE
	Transparency and ONE Material: the glass has to be a separate part from the
	egg inside it or they go see-through together, and the neon rings have to be
	separate from the plinth or the whole plinth glows.

	STAGED IN ReplicatedStorage, NOT ServerStorage, for the reason the shells
	were: the hatch screen builds its own copy of the egg on the client, and the
	egg that cracks has to be the egg that was in the tube.
]]
local function tubeTemplate(key: string?): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local tubes = assets and assets:FindFirstChild("EggTubes")
	local own = key and tubes and tubes:FindFirstChild(key)
	return (own and own:IsA("Model")) and own or nil
end

--------------------------------------------------------------------------
-- GROUND
--------------------------------------------------------------------------
-- Straight down from well above, ignoring anything we or another builder has
-- already put there, so a re-run does not stack a plaza on top of itself.
local function groundAt(x: number, z: number, fallbackY: number, ignore: { Instance }): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true

	local from = Vector3.new(x, fallbackY + 260, z)
	local hit = workspace:Raycast(from, Vector3.new(0, -600, 0), params)
	if hit then
		return hit.Position.Y
	end
	return fallbackY
end

--------------------------------------------------------------------------
-- PARTS
--------------------------------------------------------------------------
local function part(name: string, size: Vector3, cf: CFrame, color: Color3,
	material: Enum.Material, parent: Instance): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function roundify(inst: Instance, px: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, px)
	c.Parent = inst
	return c
end

local function stroke(inst: Instance, colour: Color3, thickness: number, transparency: number?)
	local s = Instance.new("UIStroke")
	s.Color = colour
	s.Thickness = thickness
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = inst
	return s
end

-- Thousands separators. "$1000000" and "$100000" are the same shape at a
-- glance, and telling those two apart is the entire job of the price bar on a
-- row where the top shelf costs twenty times the one beside it.
local function money(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	out = out:gsub("^,", "")
	return "$" .. out
end

--------------------------------------------------------------------------
-- THE BARS, ON TOP OF THE TUBE
--------------------------------------------------------------------------
--[[
	Two bars, and they are the station's own signage rather than the player's.

		PRICE     the egg's name and what it costs
		RARITY    the five outcomes as one segmented strip, each segment in its
		          TIER's colour and sized by its own odds

	BOTH ARE DRESSED IN THE EGG'S OWN PALETTE. PetConfig gives every shelf a
	`color` (the body) and an `accent`, and those two drive the bar's fill, its
	border, the gem and the lettering -- so the Basic bars are cream and mint,
	the Desert bars sand and amber, Prestige lilac and gold, Celestial ice and
	magenta. A row of four identical white signs would have thrown away the one
	piece of information the player wants at forty studs: which of these is the
	expensive one.

	WHY THE RARITY SEGMENTS ARE NOT DRAWN TO SCALE, quite.

	Straight proportion is unreadable at the only end anybody cares about: the
	Prestige mythic is one in a million, which is a segment 0.000006 of a bar
	wide -- no pixels at all -- while Common eats two thirds of every strip. So
	each segment is floored at MIN_SEG of the bar before the widths are
	normalised. The ORDER and the COLOURS stay honest, the big ones still read
	as big, and the rarest outcome is still a visible sliver on the end, which
	is the thing the bar exists to show.

	SERVER-BUILT, unlike the odds panel. This says the same thing to everybody --
	a price and a set of odds are facts about the egg, not about the player --
	so it can be built once and replicate. EggClient's per-player front (which
	greys out pets you have not discovered and reddens a price you cannot
	afford) stands these down while it is up; see the mute list there.
]]
local MIN_SEG = 0.05

local function tierColour(tierKey: string): Color3
	local info = PetConfig.TierByKey and PetConfig.TierByKey[tierKey]
	if type(info) == "table" and typeof(info.color) == "Color3" then
		return info.color
	end
	return Color3.fromRGB(200, 200, 200)
end

local function buildBars(anchor: BasePart, egg)
	local stale = anchor:FindFirstChild("EggBars")
	if stale then
		stale:Destroy()
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "EggBars"
	-- Wide enough for the worst case on the row, which is "Celestial Egg" beside
	-- "$1,000,000" -- the longest name and the longest price on the same bar.
	gui.Size = UDim2.fromScale(7.4, 2.55)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 0, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 140
	gui.Parent = anchor

	-- The shelf's two colours, pushed to where they read as ink and as light.
	local deep = egg.color:Lerp(INK, 0.78)
	local bright = egg.accent

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Parent = gui

	local stack = Instance.new("UIListLayout")
	stack.FillDirection = Enum.FillDirection.Vertical
	stack.HorizontalAlignment = Enum.HorizontalAlignment.Center
	stack.VerticalAlignment = Enum.VerticalAlignment.Bottom
	stack.SortOrder = Enum.SortOrder.LayoutOrder
	stack.Padding = UDim.new(0.05, 0)
	stack.Parent = root

	------------------------------------------------------------------
	-- BAR 1 -- name and price
	------------------------------------------------------------------
	local price = Instance.new("Frame")
	price.Name = "PriceBar"
	price.LayoutOrder = 1
	price.Size = UDim2.fromScale(1, 0.54)
	price.BackgroundColor3 = deep
	price.BorderSizePixel = 0
	price.Parent = root
	roundify(price, 10)
	stroke(price, bright, 2.5, 0.15)

	-- A diamond in the accent, which is the same gem the price pill uses, so a
	-- station reads as the same object close up and far away.
	local gem = Instance.new("Frame")
	gem.Name = "Gem"
	gem.AnchorPoint = Vector2.new(0, 0.5)
	gem.Position = UDim2.fromScale(0.045, 0.5)
	gem.Size = UDim2.fromScale(0.075, 0.44)
	gem.BackgroundColor3 = bright
	gem.BorderSizePixel = 0
	gem.Rotation = 45
	gem.Parent = price
	roundify(gem, 3)

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0, 0.5)
	-- Title and price are given HARD, NON-OVERLAPPING lanes rather than being
	-- left to TextScaled. Scaling shrinks text to fit its own box; it does not
	-- stop two boxes sitting on top of each other, and at 0.44/0.40 they did --
	-- "Celestial Egg" ran under the first digit of its own price.
	title.Position = UDim2.fromScale(0.135, 0.5)
	title.Size = UDim2.fromScale(0.41, 0.62)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.LuckiestGuy
	title.Text = egg.name
	title.TextColor3 = CREAM
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = price

	local cost = Instance.new("TextLabel")
	cost.Name = "Cost"
	cost.AnchorPoint = Vector2.new(1, 0.5)
	cost.Position = UDim2.fromScale(0.965, 0.5)
	cost.Size = UDim2.fromScale(0.40, 0.66)
	cost.BackgroundTransparency = 1
	cost.Font = Enum.Font.LuckiestGuy
	cost.Text = money(egg.cost)
	cost.TextColor3 = bright
	cost.TextStrokeTransparency = 0.55
	cost.TextStrokeColor3 = INK
	cost.TextScaled = true
	cost.TextXAlignment = Enum.TextXAlignment.Right
	cost.Parent = price

	------------------------------------------------------------------
	-- BAR 2 -- the rarity strip
	------------------------------------------------------------------
	local rarity = Instance.new("Frame")
	rarity.Name = "RarityBar"
	rarity.LayoutOrder = 2
	rarity.Size = UDim2.fromScale(1, 0.30)
	rarity.BackgroundColor3 = deep
	rarity.BorderSizePixel = 0
	rarity.ClipsDescendants = true
	rarity.Parent = root
	roundify(rarity, 8)
	stroke(rarity, bright, 2.5, 0.15)

	local strip = Instance.new("Frame")
	strip.Name = "Strip"
	strip.AnchorPoint = Vector2.new(0.5, 0.5)
	strip.Position = UDim2.fromScale(0.5, 0.5)
	strip.Size = UDim2.fromScale(0.94, 0.52)
	strip.BackgroundTransparency = 1
	strip.ClipsDescendants = true
	strip.Parent = rarity
	roundify(strip, 5)

	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.HorizontalAlignment = Enum.HorizontalAlignment.Left
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Padding = UDim.new(0.006, 0)
	row.Parent = strip

	local pool = egg.pool or egg.pets or {}
	local raw, total = {}, 0
	for i, entry in ipairs(pool) do
		raw[i] = math.max(entry.chance or 0, MIN_SEG)
		total += raw[i]
	end
	if total <= 0 then
		total = 1
	end

	for i, entry in ipairs(pool) do
		local seg = Instance.new("Frame")
		seg.Name = "Seg" .. i
		seg.LayoutOrder = i
		seg.Size = UDim2.fromScale(raw[i] / total, 1)
		seg.BackgroundColor3 = tierColour(entry.tier)
		seg.BorderSizePixel = 0
		seg.Parent = strip
		roundify(seg, 4)

		-- The percentage goes on only where there is room for it. A number
		-- squeezed into a 4%-wide sliver is a smear, and the sliver's COLOUR
		-- has already said the thing that matters.
		if (raw[i] / total) > 0.18 and not entry.secret then
			local pct = Instance.new("TextLabel")
			pct.Name = "Pct"
			pct.Size = UDim2.fromScale(1, 0.92)
			pct.BackgroundTransparency = 1
			pct.Font = Enum.Font.GothamBold
			local c = (entry.chance or 0) * 100
			pct.Text = (c >= 10) and string.format("%d%%", c + 0.5) or string.format("%.1f%%", c)
			pct.TextColor3 = INK
			pct.TextScaled = true
			pct.Parent = seg
		end
	end
	return gui
end

--------------------------------------------------------------------------
-- ONE STATION
--------------------------------------------------------------------------
--[[
	Strips the station to its Model and rebuilds every piece.

	Written as a wipe-and-rebuild rather than as a diff on purpose. The previous
	version tried to work out whether an adopted station was carrying the old
	sphere, the shared mesh, a correctly-sized mesh with kit baggage welded to
	it, or the right thing already -- four states, three of them legacy, each
	with its own branch. Every new era of station added another. This has one
	state: whatever is standing gets replaced by what the current code makes.
]]
--[[
	One booth. Returns its outside width so the row can be spaced off it.

	Built from the tube's own bounding box, so a bigger shelf gets a bigger shed
	without a second table of numbers to keep in step.
]]
local function boothSize(tube: Vector3): (number, number, number)
	return tube.X + BOOTH_MARGIN, tube.Z + BOOTH_MARGIN, tube.Y + BOOTH_RISE
end

local function buildBooth(model: Model, cf: CFrame, egg, tube: Vector3)
	local w, d, h = boothSize(tube)
	local hw, hd = w * 0.5, d * 0.5

	-- The deck, sunk so its top face is the floor the tube stands on rather than
	-- a tile the tube stands ON TOP of.
	part("Deck", Vector3.new(w, 1.1, d), cf * CFrame.new(0, -0.5, 0),
		WOOD_DARK, Enum.Material.WoodPlanks, model)
	part("DeckLip", Vector3.new(w + 1.1, 0.45, d + 1.1), cf * CFrame.new(0, -1.0, 0),
		WOOD, Enum.Material.WoodPlanks, model)

	-- Four corner posts.
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			part("Post", Vector3.new(1.1, h, 1.1),
				cf * CFrame.new(sx * (hw - 0.75), h * 0.5, sz * (hd - 0.75)),
				WOOD, Enum.Material.WoodPlanks, model)
		end
	end

	--[[
		PANELLED ACROSS THE BACK HALF ONLY.

		A fully walled shed with one open face is a box you photograph from one
		angle; the egg inside it disappears from everywhere else on the plaza.
		Half-depth side walls keep the silhouette of a building while leaving the
		glass visible from the path, from the shop and from the sand.
	]]
	part("BackWall", Vector3.new(w, h * 0.62, 0.7),
		cf * CFrame.new(0, h * 0.31, -(hd - 0.35)), WOOD_DARK, Enum.Material.WoodPlanks, model)
	for _, sx in ipairs({ -1, 1 }) do
		part("SideWall", Vector3.new(0.7, h * 0.62, d * 0.42),
			cf * CFrame.new(sx * (hw - 0.35), h * 0.31, -(hd - d * 0.21 - 0.7)),
			WOOD_DARK, Enum.Material.WoodPlanks, model)
	end

	-- The shopfront band, in the egg's own colour: the one piece of the building
	-- that says WHICH egg from the far side of the plaza.
	part("Fascia", Vector3.new(w + 1.6, 1.5, 0.8),
		cf * CFrame.new(0, h - 0.4, hd + 0.2), egg.color, Enum.Material.SmoothPlastic, model)
	part("FasciaTrim", Vector3.new(w + 1.6, 0.35, 0.9),
		cf * CFrame.new(0, h - 1.25, hd + 0.2), egg.accent, Enum.Material.SmoothPlastic, model)

	-- Roof: an overhanging slab and a smaller cap, the same two-tier shape the
	-- tube caps use, so the shed and the case it holds are the same object.
	part("Roof", Vector3.new(w + ROOF_OVERHANG, 0.8, d + ROOF_OVERHANG),
		cf * CFrame.new(0, h + 0.4, 0), egg.color, Enum.Material.SmoothPlastic, model)
	part("RoofCap", Vector3.new(w * 0.66, 0.7, d * 0.66),
		cf * CFrame.new(0, h + 1.15, 0), egg.accent, Enum.Material.SmoothPlastic, model)
	part("Ridge", Vector3.new(w * 0.3, 0.6, d * 0.3),
		cf * CFrame.new(0, h + 1.8, 0), egg.color, Enum.Material.SmoothPlastic, model)

	-- A lamp under the roof, in the shelf's accent. Every other building on the
	-- beach front has one and it is most of why they read as open for business.
	local lamp = part("Lamp", Vector3.new(1.0, 0.5, 1.0),
		cf * CFrame.new(0, h - 0.35, hd - 1.4), egg.accent, Enum.Material.Neon, model)
	lamp.CanCollide = false
	local glow = Instance.new("PointLight")
	glow.Brightness = 1.6
	glow.Range = 16
	glow.Color = egg.accent
	glow.Parent = lamp
end

local function dressStation(model: Model, egg, cf: CFrame)
	local template = tubeTemplate(egg.key)
	if not template then
		warn(string.format("[PetStationBuilder] no tube staged for %s -- station skipped", egg.key))
		return false
	end

	-- Everything goes. Nothing on a station is worth preserving across a
	-- re-dress: the prompt is rebuilt by PetServer off the tag, and the
	-- per-player front is the client's and is rebuilt when it next sees this.
	for _, child in ipairs(model:GetChildren()) do
		child:Destroy()
	end

	local tube = template:Clone()
	local _, size = tube:GetBoundingBox()
	-- The template's pivot is its FOOT, so this stands it on the ground rather
	-- than burying it to its middle.
	tube:PivotTo(cf)

	for _, p in ipairs(tube:GetChildren()) do
		if p:IsA("BasePart") then
			p.Anchored = true
			-- Solid where the player would expect to be stopped, and not solid
			-- where a collision would only ever be a nuisance: you can lean on the
			-- plinth and the glass, and the egg and the light rings are air.
			p.CanCollide = (p.Name == "Rig" or p.Name == "Tube")
			p.CanTouch = false
			p.Massless = true
			p.Parent = model
		end
	end
	tube:Destroy()

	local shell = model:FindFirstChild("Egg")
	if shell and shell:IsA("BasePart") then
		--[[
			THE EGG IS THE PIECE EVERYTHING ELSE TALKS TO.

			EggClient bobs `Egg` every frame and the hatch cracks it, so the name
			is load-bearing and the part has to be a BasePart at the middle of the
			tube. It is left CanQuery = false because the prompt sits behind it.
		]]
		shell.CanQuery = false

		local light = Instance.new("PointLight")
		light.Brightness = 1.35
		light.Range = 13
		light.Color = egg.accent
		light.Parent = shell

		--[[
			SPARKLE, AND THE RATE IS THE PRICE.

			Emitted from the shell's own volume, so it comes off the whole egg
			rather than out of one point inside it, and the rate climbs with the
			shelf's index -- the Basic egg glitters faintly and the Celestial egg
			is unmistakable from the path. That is the one difference between the
			four that still reads at forty studs.

			rbxasset:// -- a texture that SHIPS WITH THE ENGINE. This place has
			been bitten by assets that resolve for the uploader and nobody else,
			and a sparkle that silently fails to load is a station that looks
			broken with nothing in the log.
		]]
		local sparkle = Instance.new("ParticleEmitter")
		sparkle.Name = "Sparkle"
		sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		sparkle.Color = ColorSequence.new(egg.accent)
		sparkle.LightEmission = 0.85
		sparkle.LightInfluence = 0
		sparkle.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.35, 0.34),
			NumberSequenceKeypoint.new(1, 0),
		})
		sparkle.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.25, 0.25),
			NumberSequenceKeypoint.new(1, 1),
		})
		sparkle.Lifetime = NumberRange.new(0.8, 1.5)
		sparkle.Rate = 2 + (egg.index or 1) * 3
		sparkle.Speed = NumberRange.new(0.2, 0.7)
		sparkle.SpreadAngle = Vector2.new(180, 180)
		sparkle.Rotation = NumberRange.new(0, 360)
		sparkle.RotSpeed = NumberRange.new(-60, 60)
		sparkle.Acceleration = Vector3.new(0, 0.8, 0)
		sparkle.Parent = shell
	end

	buildBooth(model, cf, egg, size)

	-- The prompt lives on its own part rather than on the art, so its position
	-- is independent of which tube is standing here. It wraps the tube at
	-- body height, where a walk-up actually points.
	local anchor = part("PromptAnchor", Vector3.new(size.X + 1.4, size.Y * 0.86, size.Z + 1.4),
		cf * CFrame.new(0, size.Y * 0.45, 0), SAND, Enum.Material.SmoothPlastic, model)
	anchor.Transparency = 1
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false

	-- Where the bars hang. Its own part rather than an offset off the egg,
	-- because the egg BOBS -- signage welded to that would breathe with it.
	--[[
		OVER THE RIDGE, not over the tube.

		The booth's roof stacks a slab, a cap and a ridge on top of BOOTH_RISE, so
		the highest timber is about (tube + 5.3). The bars are 2.55 studs tall and
		hang centred on this anchor, so anything under (tube + 6.6) puts their
		bottom edge through the roof -- which is exactly where they sat at first.
	]]
	local signAt = part("SignAnchor", Vector3.new(0.4, 0.4, 0.4),
		cf * CFrame.new(0, size.Y + BOOTH_RISE + BARS_LIFT + 3.4, 0),
		SAND, Enum.Material.SmoothPlastic, model)
	signAt.Transparency = 1
	signAt.CanCollide = false
	signAt.CanQuery = false
	signAt.CanTouch = false

	buildBars(signAt, egg)

	model.PrimaryPart = anchor
	model:SetAttribute("EggKey", egg.key)
	model:SetAttribute("TubeHeight", size.Y)
	CollectionService:AddTag(model, "PetStation")
	return true
end

local function buildStation(parent: Instance, cf: CFrame, egg): Model
	local model = Instance.new("Model")
	model.Name = "EggStation_" .. egg.key
	model.Parent = parent
	dressStation(model, egg, cf)
	return model
end

--------------------------------------------------------------------------
-- ONE PLAZA
--------------------------------------------------------------------------
-- Pitch from the widest tube ON THIS ROW, so a future shelf with a bigger
-- case spreads the row instead of overlapping its neighbour. Per island, not
-- global: the cove's three-booth row has 46 studs of flank between the gate
-- kerb and the kagura posts, and pitching it off the Celestial tube -- a
-- shelf that island does not carry -- was 4.8 studs of spread it cannot fit.
local function rowPitch(eggs): number
	local widest = 0
	for _, egg in (eggs or PetConfig.Eggs) do
		local t = tubeTemplate(egg.key)
		if t then
			local _, s = t:GetBoundingBox()
			-- The booth's OUTSIDE width, roof included. Pitching off the glass
			-- overlapped every roof on the row; pitching off the walls left the
			-- Ashfall row with 2.7 studs between eaves, which is a gap you notice
			-- because you cannot walk down it.
			local bw = boothSize(s)
			widest = math.max(widest, bw + ROOF_OVERHANG)
		end
	end
	return math.max(PetConfig.StationSpacing or 11, widest + TUBE_GAP)
end

--[[
	RECONCILED, NOT ADOPTED-OR-BUILT.

	This used to branch: an existing plaza had its stations re-dressed WHERE THEY
	STOOD and a new one was laid out from scratch. That was fine while every
	island carried the same four shelves -- and wrong the moment they stopped,
	because an island whose list had just shrunk from four eggs to one kept the
	other three standing, re-dressed and fully working, on a plaza the code
	believed had one egg on it.

	So there is one path now and it converges on the list: anything not on it is
	removed, anything missing is built, and everything is re-seated to the row's
	current spacing -- which itself moves when the count changes, because the row
	is centred. Running it twice is still a no-op.
]]
local function buildPlaza(root: Folder, isl, override): Model?
	override = override or {}
	local eggs = PetConfig.eggsForIsland(isl.id or 0)

	--[[
		AN ISLAND CAN OPT OUT, and opting out has to REMOVE rather than skip.

		The plazas are saved in the place, so a row that gets `plaza = false`
		after one has already been built would otherwise leave it standing --
		tagged, prompted and selling eggs on an island the config says has none.
	]]
	if #eggs == 0 then
		local stale = root:FindFirstChild("Plaza_" .. isl.name)
		if stale then
			for _, child in ipairs(stale:GetChildren()) do
				if child:IsA("Model") and child:GetAttribute("EggKey") then
					CollectionService:RemoveTag(child, "PetStation")
				end
			end
			stale:Destroy()
		end
		return nil
	end

	local plaza = root:FindFirstChild("Plaza_" .. isl.name)
	if not plaza then
		local made = Instance.new("Model")
		made.Name = "Plaza_" .. isl.name
		made.Parent = root
		plaza = made
	end

	-- What is standing, by egg. A duplicate (two Basic stations, somehow) leaves
	-- the first and the second falls through to the sweep below.
	local standing = {}
	for _, child in ipairs(plaza:GetChildren()) do
		local key = child:IsA("Model") and child:GetAttribute("EggKey")
		if type(key) == "string" and not standing[key] then
			standing[key] = child
		end
	end

	local half = (type(isl.half) == "number") and isl.half or 128
	local cx = (type(isl.cx) == "number") and isl.cx or 0
	local cz = (type(isl.cz) == "number") and isl.cz or 0
	local fallbackY = (type(isl.cleanY) == "number") and isl.cleanY or 3

	local spacing = rowPitch(eggs)
	local span = (#eggs - 1) * spacing

	--[[
		THE ROW FRAME -- see the note on PetConfig.StationOverrides.

		With a `row` override the stations are laid along that frame's X axis,
		open faces down its +Z, which is how a row stands BESIDE a road and
		faces it. Without one, the old derived line: along world X, a fixed
		setback south of the field, facing north -- still the right default
		for an island nobody has planned a precinct for yet.
	]]
	local base
	local rowSpec = override.row
	if type(rowSpec) == "table" and type(rowSpec.x) == "number" and type(rowSpec.z) == "number" then
		base = CFrame.new(rowSpec.x, 0, rowSpec.z)
			* CFrame.Angles(0, math.rad(rowSpec.yaw or 0), 0)
	else
		local lateral = (type(override.lateral) == "number") and override.lateral or 0
		base = CFrame.new(cx + lateral, 0, cz - (half + PetConfig.StationSetback))
	end

	-- The stations this run OWNS. Membership is by instance, not by egg key:
	-- keying the sweep on the key destroyed every station that had just been
	-- built, because a newly built one is not in `standing` and so failed a
	-- `standing[key] == child` test it was never going to pass.
	local keep = {}
	for i, egg in ipairs(eggs) do
		local flat = base * CFrame.new((i - 1) * spacing - span * 0.5, 0, 0)
		local y = groundAt(flat.X, flat.Z, fallbackY, { plaza, root })
		-- The frame's rotation with the raycast ground under it: booths stand
		-- plumb on their own footing, they do not inherit a lean from the row.
		local at = CFrame.new(flat.X, y, flat.Z) * (flat - flat.Position)

		local st = standing[egg.key]
		if st then
			dressStation(st, egg, at)
		else
			st = buildStation(plaza, at, egg)
		end
		st.Name = "EggStation_" .. egg.key
		st:SetAttribute("FootY", y)
		keep[st] = true
	end

	-- The sweep. An island that lost a shelf loses the station with it, tag and
	-- all -- PetServer binds its prompt off the tag, so a station left standing
	-- here is one that still sells the egg this island is no longer meant to have.
	for _, child in ipairs(plaza:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("EggKey") and not keep[child] then
			CollectionService:RemoveTag(child, "PetStation")
			child:Destroy()
		end
	end

	return plaza
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------
local built = false

function PetStationBuilder.ensureWorld()
	assert(RunService:IsServer(), "[PetStationBuilder] server-only")
	if built then
		return
	end
	built = true

	local Config = ctbConfig()
	if not Config then
		return
	end

	local root = workspace:FindFirstChild(FOLDER_NAME)
	if not root then
		local f = Instance.new("Folder")
		f.Name = FOLDER_NAME
		f.Parent = workspace
		root = f
	end

	-- Named, not counted. A shelf with no staged tube is the one failure that
	-- leaves a plaza with a hole in it, and "4 plazas up" would not say so.
	local missing = {}
	for _, egg in PetConfig.Eggs do
		if not tubeTemplate(egg.key) then
			table.insert(missing, egg.key)
		end
	end
	if #missing > 0 then
		warn("[PetStationBuilder] no tube staged for: " .. table.concat(missing, ", ")
			.. " -- check ReplicatedStorage.Assets.EggTubes")
	end

	-- EVERY island, not a list of them. A hand-written list of islands was
	-- already missing one the day it was written.
	local placed, names = 0, {}
	for id, isl in Config.ISLANDS do
		local override = PetConfig.StationOverrides[id] or {}
		local ok, res = pcall(buildPlaza, root, isl, override)
		if ok and res then
			placed += 1
			table.insert(names, string.format("%s (%d)", isl.name or ("island " .. tostring(id)),
				#PetConfig.eggsForIsland(isl.id or id)))
		elseif ok then
			-- Opted out. Said out loud, because an island silently having no eggs on
			-- it is the exact failure the note on StationOverrides is about.
			table.insert(names, string.format("%s (none)", isl.name or ("island " .. tostring(id))))
		else
			warn("[PetStationBuilder] could not place plaza on island", id, res)
		end
	end

	-- Counted per island, not once: the whole point of the shelf lists is that
	-- the number differs, and "4 tubes each" would be a line that stopped being
	-- true the day they were introduced and said so to nobody.
	print(string.format("[PetStationBuilder] %d egg plazas up -- %s",
		placed, table.concat(names, ", ")))
end

return PetStationBuilder
