--[[
	StoreBuilder  --  ServerScriptService.StoreBuilder

	The Beach Shop: an actual building under the shop sign at (26, -173).

	WHAT WAS THERE BEFORE
	---------------------
	Two posts and a billboard, standing on open sand with nothing behind it. It
	was signage for a shop that did not exist -- what it advertised was sold from
	a button on the HUD rail instead, which is the arrangement this replaces. The
	stock list now opens by walking up to the counter and pressing E.

	(The billboard also had its gold trim mounted a tenth of a stud IN FRONT of
	the sign face, so the board read as a blank gold slab from every angle a
	player could stand at. dressSign puts the trim behind, where a frame goes.)

	ADOPTION CONTRACT
	-----------------
	Same deal as BayBuilder: if Beach.Store already exists this does nothing, so
	the moment the shop is hand-edited in Studio and saved, the code stops
	rebuilding it. The shop IS saved into the place -- this module is the record
	of how it was built, and the fallback for a place that has lost it.

	THE SIGN IS MOVED, NOT REPLACED
	-------------------------------
	Beach.UpgradeKiosk keeps its name and its Board. Two things outside this file
	reach in by that exact path and would break if it were rebuilt:

		CTB_Client  writes the live sifter readout into Board.KioskGui.Info
		SiftScreen  anchors its upgrade FX burst at Board

	So the board is resized and lifted onto the shop's roof, in the sell shop's
	sign geometry exactly. Its two ground posts come out: the shop stands where
	they did.

	THE CARPENTRY
	-------------
	Lifted off Beach.SellArea stud for stud -- same 17.5 x 10 footprint, same
	10-stud posts, same counter heights, same flat roof, same awning slats. The
	one thing that differs is the accent: the sell shop bands its awning red, the
	sifting bay sea blue, and the shop takes the gold off its own sign trim. At a
	distance that colour is the only thing telling the three buildings apart, and
	that is deliberate -- they are meant to read as one beachfront row.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local SignKit = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("SignKit"))

local StoreBuilder = {}

-- SellArea's palette, part for part: Post, Back, Counter, Crate, Awning, SignBoard.
local POST = Color3.fromRGB(99, 66, 40)
local PLANK = Color3.fromRGB(151, 104, 64)
local PLANK_LIT = Color3.fromRGB(196, 150, 100)
local CRATE = Color3.fromRGB(168, 124, 78)
local CANVAS = Color3.fromRGB(246, 246, 240)
local SIGN = Color3.fromRGB(38, 42, 48)

-- The shop's own accent, taken off the sign trim that was already there.
local GOLD = Color3.fromRGB(255, 196, 64)
local GOLD_DEEP = Color3.fromRGB(206, 148, 36)

local METAL = Color3.fromRGB(178, 184, 194)
local METAL_DARK = Color3.fromRGB(96, 102, 112)
local SEA = Color3.fromRGB(52, 120, 148)
local ROPE = Color3.fromRGB(214, 190, 146)

local function part(props): BasePart
	local p = Instance.new(props.ClassName or "Part")
	props.ClassName = nil
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		p[k] = v
	end
	return p
end

-- A painted board. Face is a NormalId on the part, not a guess: the shop faces
-- +Z, and a part's Front face is its local -Z, so anything meant to be read
-- from the beach either draws on Back or is turned around first.
-- Through SignKit, so the shop's boards carry the same lettering as the rest of
-- the row. The hand-rolled version here used FredokaOne and gold against the
-- wash bay's LuckiestGuy and cream; SignKit's header lists what the row had
-- drifted into. The wrap and canvas notes that used to live here moved with it.
local function signFace(board: BasePart, face: Enum.NormalId, str: string, colour: Color3?)
	SignKit.dress(board, str, { face }, colour)
end

--------------------------------------------------------------------------
-- THE SHOP
--------------------------------------------------------------------------
function StoreBuilder.buildStore(origin: CFrame): Model
	local model = Instance.new("Model")
	model.Name = "Store"

	local function add(p: BasePart, offset: CFrame)
		p.CFrame = origin * offset
		p.Parent = model
		return p
	end

	-- Everything decorative goes in through here: no collision, and out of every
	-- spatial query. A shopful of clutter around a counter players walk up to
	-- should not be able to catch a ray, a touch or a character.
	local function trim(props, offset)
		props.CanCollide = false
		props.CanQuery = false
		props.CanTouch = false
		return add(part(props), offset)
	end

	local HALF_W = 8.75      -- 17.5 across, the sell shop's width
	local FRONT, BACK = 5, -5
	local DECK = 0.4         -- deck top; everything indoors sits on this
	local COUNTER = 4.2      -- counter slab centre, the sell counter's height
	local ROOF = 10.4

	------------------------------------------------------------------
	-- DECK
	------------------------------------------------------------------
	-- Deeper than it is tall on purpose: the sand here runs about 0.3 below the
	-- origin and dips seaward, and a deck exactly as thick as it stands proud
	-- leaves that gap showing all the way round -- the shop reads as hovering.
	add(part({
		Name = "Deck",
		Size = Vector3.new(HALF_W * 2, 0.9, 12),
		Color = PLANK,
		Material = Enum.Material.WoodPlanks,
	}), CFrame.new(0, -0.05, 0.5))

	for i = -4, 4 do
		trim({
			Name = "Board",
			Size = Vector3.new(1.7, 0.06, 11.8),
			Color = PLANK_LIT,
			Material = Enum.Material.WoodPlanks,
			Transparency = 0.35,
		}, CFrame.new(i * 1.9, DECK + 0.02, 0.5))
	end

	-- Front lip, so the deck has an edge to read against the sand and the step
	-- up to the counter is visible rather than a hidden ledge.
	trim({
		Name = "Threshold",
		Size = Vector3.new(HALF_W * 2, 1.0, 0.5),
		Color = POST,
		Material = Enum.Material.Wood,
	}, CFrame.new(0, 0.05, 6.25))

	------------------------------------------------------------------
	-- FRAME
	------------------------------------------------------------------
	for _, sx in { -1, 1 } do
		for _, sz in { FRONT, BACK } do
			add(part({
				Name = "Post",
				Size = Vector3.new(0.9, 10, 0.9),
				Color = POST,
				Material = Enum.Material.Wood,
			}), CFrame.new(sx * 8, 5, sz))
		end
	end

	add(part({
		Name = "BackWall",
		Size = Vector3.new(HALF_W * 2, 9, 0.6),
		Color = PLANK,
		Material = Enum.Material.WoodPlanks,
	}), CFrame.new(0, 5, BACK))

	-- Mismatched boards over the flat wall, one missing near the top. Cheap, and
	-- it is what stops a 17-stud plank reading as a painted box.
	for i = -7, 7 do
		if i ~= 4 then
			trim({
				Name = "Slat",
				Size = Vector3.new(1.05, (i % 3 == 0) and 8.1 or 8.7, 0.14),
				Color = (i % 2 == 0) and PLANK_LIT or CRATE,
				Material = Enum.Material.WoodPlanks,
				Transparency = 0.25,
			}, CFrame.new(i * 1.14, 5, BACK + 0.38))
		end
	end

	-- Sides stop well short of the front, so the counter stays open to the beach
	-- and the stock behind it is visible on the walk up.
	for _, sx in { -1, 1 } do
		add(part({
			Name = "SideWall",
			Size = Vector3.new(0.5, 9, 6.2),
			Color = PLANK,
			Material = Enum.Material.WoodPlanks,
		}), CFrame.new(sx * (HALF_W - 0.25), 5, BACK + 3.1))

		trim({
			Name = "SideBrace",
			Size = Vector3.new(0.22, 0.5, 6.2),
			Color = POST,
			Material = Enum.Material.Wood,
		}, CFrame.new(sx * (HALF_W - 0.5), 8.4, BACK + 3.1))
	end

	------------------------------------------------------------------
	-- ROOF  --  flat, like the sell shop's. The sign stands on it.
	------------------------------------------------------------------
	add(part({
		Name = "Roof",
		Size = Vector3.new(20, 0.7, 14),
		Color = POST,
		Material = Enum.Material.WoodPlanks,
	}), CFrame.new(0, ROOF, 0.4))

	for i = -2, 2 do
		trim({
			Name = "Rafter",
			Size = Vector3.new(0.35, 0.35, 13.6),
			Color = CRATE,
			Material = Enum.Material.Wood,
		}, CFrame.new(i * 3.4, ROOF - 0.5, 0.4))
	end

	trim({
		Name = "RoofTrim",
		Size = Vector3.new(20, 0.34, 0.5),
		Color = GOLD,
		Material = Enum.Material.SmoothPlastic,
	}, CFrame.new(0, ROOF + 0.5, 7.15))

	-- Awning slats, in the sell shop's exact shape and spacing -- banded gold
	-- and cream where that one is red and cream.
	for i = 0, 8 do
		trim({
			Name = "Awning",
			Size = Vector3.new(2.2, 0.4, 5.4),
			Color = (i % 2 == 0) and GOLD or CANVAS,
			Material = Enum.Material.Fabric,
		}, CFrame.new(-8.8 + i * 2.2, 9.5, 8.6))
	end

	------------------------------------------------------------------
	-- COUNTER  --  the thing you actually walk up to
	------------------------------------------------------------------
	add(part({
		Name = "Counter",
		Size = Vector3.new(HALF_W * 2, 0.7, 2.6),
		Color = PLANK_LIT,
		Material = Enum.Material.WoodPlanks,
	}), CFrame.new(0, COUNTER, FRONT))

	add(part({
		Name = "CounterFront",
		Size = Vector3.new(HALF_W * 2, 4.2, 0.5),
		Color = PLANK,
		Material = Enum.Material.WoodPlanks,
	}), CFrame.new(0, 2.1, FRONT + 1))

	-- Gold lip along the counter edge: the one line of the building the player
	-- is looking straight down at while the stock list is open.
	trim({
		Name = "CounterLip",
		Size = Vector3.new(HALF_W * 2 + 0.3, 0.24, 2.8),
		Color = GOLD,
		Material = Enum.Material.SmoothPlastic,
	}, CFrame.new(0, COUNTER + 0.46, FRONT))

	-- Till. A shop with no till is a shelf.
	trim({
		Name = "Till",
		Size = Vector3.new(2.1, 1.2, 1.5),
		Color = METAL_DARK,
		Material = Enum.Material.Metal,
	}, CFrame.new(5.6, COUNTER + 1.15, FRONT - 0.1))
	trim({
		Name = "TillDrawer",
		Size = Vector3.new(1.9, 0.4, 0.3),
		Color = GOLD_DEEP,
		Material = Enum.Material.Metal,
	}, CFrame.new(5.6, COUNTER + 0.95, FRONT + 0.68))
	for i = 0, 2 do
		trim({
			Name = "TillKey",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.12, 0.34, 0.34),
			Color = CANVAS,
			Material = Enum.Material.SmoothPlastic,
		}, CFrame.new(5.0 + i * 0.6, COUNTER + 1.81, FRONT - 0.1) * CFrame.Angles(0, 0, math.rad(90)))
	end

	-- Scales, for weighing what comes over the counter.
	trim({
		Name = "ScalePost",
		Size = Vector3.new(0.2, 1.1, 0.2),
		Color = METAL,
		Material = Enum.Material.Metal,
	}, CFrame.new(-6.2, COUNTER + 0.9, FRONT - 0.2))
	trim({
		Name = "ScalePan",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.16, 1.9, 1.9),
		Color = METAL,
		Material = Enum.Material.Metal,
		Reflectance = 0.2,
	}, CFrame.new(-6.2, COUNTER + 1.5, FRONT - 0.2) * CFrame.Angles(0, 0, math.rad(90)))

	------------------------------------------------------------------
	-- STOCK  --  three shelves of it, on the wall behind the counter
	------------------------------------------------------------------
	local SHELF_Z = BACK + 0.9
	local SHELVES = { 1.9, 4.3, 6.7 }

	for _, y in SHELVES do
		trim({
			Name = "Shelf",
			Size = Vector3.new(15.2, 0.25, 1.2),
			Color = CRATE,
			Material = Enum.Material.WoodPlanks,
		}, CFrame.new(0, y, SHELF_Z))

		for _, sx in { -1, 0, 1 } do
			trim({
				Name = "ShelfBracket",
				Size = Vector3.new(0.22, 0.5, 1.0),
				Color = METAL_DARK,
				Material = Enum.Material.Metal,
			}, CFrame.new(sx * 6.6, y - 0.35, SHELF_Z))
		end
	end

	-- Stood ON the shelves, never floating near them: each shelf's top face is
	-- y + 0.125, so everything below is that plus its own half height.
	local function shelfTop(i)
		return SHELVES[i] + 0.125
	end

	-- Bottom shelf: buckets, the thing the Bucket Size track sells.
	for i = 0, 3 do
		trim({
			Name = "Bucket",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1.4, 1.25, 1.25),
			Color = ({ SEA, GOLD, Color3.fromRGB(224, 96, 84), SEA })[i + 1],
			Material = Enum.Material.SmoothPlastic,
		}, CFrame.new(-7.0 + i * 1.6, shelfTop(1) + 0.7, SHELF_Z)
			* CFrame.Angles(0, 0, math.rad(90)))
	end
	for i = 0, 2 do
		trim({
			Name = "Carton",
			Size = Vector3.new(1.4, 1.2, 1.0),
			Color = CRATE:Lerp(PLANK_LIT, i * 0.3),
			Material = Enum.Material.WoodPlanks,
		}, CFrame.new(1.6 + i * 1.7, shelfTop(1) + 0.6, SHELF_Z)
			* CFrame.Angles(0, math.rad(-6 + i * 7), 0))
	end
	trim({
		Name = "Coil",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.55, 1.7, 1.7),
		Color = ROPE,
		Material = Enum.Material.Fabric,
	}, CFrame.new(6.6, shelfTop(1) + 0.28, SHELF_Z) * CFrame.Angles(0, 0, math.rad(90)))

	-- Middle shelf: boots (Beach Legs), springs (Shake Power), jars of shells.
	for _, sx in { -1, 1 } do
		trim({
			Name = "BootSole",
			Size = Vector3.new(0.75, 0.3, 1.5),
			Color = Color3.fromRGB(60, 62, 70),
			Material = Enum.Material.Fabric,
		}, CFrame.new(-6.6 + (sx + 1) * 0.5, shelfTop(2) + 0.15, SHELF_Z)
			* CFrame.Angles(0, math.rad(sx * 9), 0))
		trim({
			Name = "BootUpper",
			Size = Vector3.new(0.7, 0.85, 0.8),
			Color = Color3.fromRGB(216, 84, 72),
			Material = Enum.Material.Fabric,
		}, CFrame.new(-6.6 + (sx + 1) * 0.5, shelfTop(2) + 0.7, SHELF_Z - 0.3)
			* CFrame.Angles(0, math.rad(sx * 9), 0))
	end

	for i = 0, 2 do
		trim({
			Name = "Spring",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1.3, 0.5, 0.5),
			Color = METAL,
			Material = Enum.Material.Metal,
			Reflectance = 0.3,
		}, CFrame.new(-3.2 + i * 0.9, shelfTop(2) + 0.65, SHELF_Z)
			* CFrame.Angles(0, 0, math.rad(90)))
	end

	local GRADES = { Color3.fromRGB(240, 216, 176), Color3.fromRGB(206, 158, 255),
		Color3.fromRGB(150, 230, 160), Color3.fromRGB(255, 150, 108) }
	for i, colour in GRADES do
		local height = 1.1 + (i % 2) * 0.3
		trim({
			Name = "Jar",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(height, 0.62, 0.62),
			Color = colour,
			Material = Enum.Material.Glass,
			Transparency = 0.25,
		}, CFrame.new(1.4 + i * 0.85, shelfTop(2) + height * 0.5, SHELF_Z)
			* CFrame.Angles(0, 0, math.rad(90)))
	end

	trim({
		Name = "Crate",
		Size = Vector3.new(1.7, 1.7, 1.1),
		Color = CRATE,
		Material = Enum.Material.WoodPlanks,
	}, CFrame.new(6.4, shelfTop(2) + 0.85, SHELF_Z) * CFrame.Angles(0, math.rad(8), 0))

	-- Top shelf: spare sifter screens in descending mesh grade -- which is also
	-- the Sifter Width ladder, so what the player is saving for is on the wall
	-- in front of them while they read the price.
	for i = 0, 3 do
		local x = -6.8 + i * 1.5
		trim({
			Name = "SpareScreen",
			Size = Vector3.new(1.25, 1.9, 0.12),
			Color = PLANK_LIT,
			Material = Enum.Material.Wood,
		}, CFrame.new(x, shelfTop(3) + 0.95, SHELF_Z - 0.35)
			* CFrame.Angles(0, 0, math.rad(-5 + i * 3)))
		for w = 0, 3 - i do
			trim({
				Name = "SpareWire",
				Size = Vector3.new(0.05, 1.8, 0.05),
				Color = METAL,
				Material = Enum.Material.Metal,
			}, CFrame.new(x - 0.5 + w * (1.0 / math.max(3 - i, 1)), shelfTop(3) + 0.95, SHELF_Z - 0.42)
				* CFrame.Angles(0, 0, math.rad(-5 + i * 3)))
		end
	end

	for i = 0, 4 do
		trim({
			Name = "StockBox",
			Size = Vector3.new(1.15, 1.15, 1.0),
			Color = CRATE:Lerp(CANVAS, (i % 3) * 0.22),
			Material = Enum.Material.WoodPlanks,
		}, CFrame.new(0.4 + i * 1.45, shelfTop(3) + 0.575, SHELF_Z)
			* CFrame.Angles(0, math.rad(-8 + i * 4), 0))
	end

	------------------------------------------------------------------
	-- KIT  --  the things that say somebody works here
	------------------------------------------------------------------
	for i = 0, 1 do
		trim({
			Name = "FloorCrate",
			Size = Vector3.new(2.4 - i * 0.3, 2.4 - i * 0.3, 2.4 - i * 0.3),
			Color = CRATE,
			Material = Enum.Material.WoodPlanks,
		}, CFrame.new(-6.6, DECK + 1.2 + i * 2.25, BACK + 3.4) * CFrame.Angles(0, math.rad(9 - i * 21), 0))
	end

	trim({
		Name = "Barrel",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(3.0, 2.1, 2.1),
		Color = PLANK,
		Material = Enum.Material.WoodPlanks,
	}, CFrame.new(HALF_W + 1.9, 1.5, FRONT - 1.4) * CFrame.Angles(0, 0, math.rad(90)))
	for _, y in { 0.7, 2.3 } do
		trim({
			Name = "BarrelHoop",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.22, 2.24, 2.24),
			Color = METAL_DARK,
			Material = Enum.Material.Metal,
		}, CFrame.new(HALF_W + 1.9, y, FRONT - 1.4) * CFrame.Angles(0, 0, math.rad(90)))
	end

	-- Sifters for sale, stood in the barrel handle-up.
	for i = 0, 2 do
		trim({
			Name = "StockSifter",
			Size = Vector3.new(0.16, 3.4, 0.16),
			Color = PLANK_LIT,
			Material = Enum.Material.Wood,
		}, CFrame.new(HALF_W + 1.6 + i * 0.4, 4.3, FRONT - 1.6 + i * 0.35)
			* CFrame.Angles(math.rad(-6 + i * 5), 0, math.rad(-7 + i * 6)))
	end

	-- Bare bulb under the rafters. Cheap warmth in what is otherwise a shed.
	trim({
		Name = "Flex",
		Size = Vector3.new(0.1, 1.2, 0.1),
		Color = Color3.fromRGB(32, 30, 28),
		Material = Enum.Material.SmoothPlastic,
	}, CFrame.new(0, ROOF - 1.3, 1.0))

	local bulb = trim({
		Name = "Bulb",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(0.6, 0.6, 0.6),
		Color = Color3.fromRGB(255, 236, 190),
		Material = Enum.Material.Neon,
	}, CFrame.new(0, ROOF - 2.0, 1.0))

	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 226, 170)
	glow.Range = 20
	glow.Brightness = 1.2
	glow.Parent = bulb

	------------------------------------------------------------------
	-- SIGNAGE
	------------------------------------------------------------------
	-- Price slate over the counter, hung off the front rafter. Reads on the walk
	-- up, and says what the building is for before the prompt is in range.
	local slate = trim({
		Name = "StockBoard",
		Size = Vector3.new(9.0, 1.8, 0.3),
		Color = SIGN,
		Material = Enum.Material.SmoothPlastic,
	}, CFrame.new(0, ROOF - 1.6, FRONT + 1.2))
	signFace(slate, Enum.NormalId.Back, "SIFTERS  BUCKETS  BOOTS")

	trim({
		Name = "StockBoardTrim",
		Size = Vector3.new(9.4, 0.26, 0.34),
		Color = GOLD,
		Material = Enum.Material.SmoothPlastic,
	}, CFrame.new(0, ROOF - 0.6, FRONT + 1.2))

	for _, sx in { -1, 1 } do
		trim({
			Name = "SlateChain",
			Size = Vector3.new(0.12, 0.9, 0.12),
			Color = METAL_DARK,
			Material = Enum.Material.Metal,
		}, CFrame.new(sx * 3.6, ROOF - 0.25, FRONT + 1.2))
	end

	-- OPEN board propped at the end of the counter.
	local open = trim({
		Name = "OpenSign",
		Size = Vector3.new(2.6, 1.3, 0.22),
		Color = SIGN,
		Material = Enum.Material.SmoothPlastic,
	}, CFrame.new(-7.0, COUNTER + 1.2, FRONT + 0.9) * CFrame.Angles(0, math.rad(16), 0))
	-- Tinted, because green is what "open" looks like on a shop door -- the one
	-- sign in the row whose colour carries meaning rather than decorating. It
	-- keeps the row's face and outline, so it still belongs to the set.
	signFace(open, Enum.NormalId.Back, "OPEN", Color3.fromRGB(150, 230, 160))

	------------------------------------------------------------------
	-- THE PROMPT
	--
	-- Its own anchor rather than the counter slab, so E floats over the middle
	-- of the counter at head height instead of at the centre of a 17-stud plank.
	-- MenuHud picks it up by NAME through ProximityPromptService, so renaming it
	-- silently unhooks the shop.
	------------------------------------------------------------------
	local anchor = add(part({
		Name = "PromptAnchor",
		Size = Vector3.new(1, 1, 1),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
	}), CFrame.new(0, COUNTER + 1.0, FRONT + 1.3))

	StoreBuilder.ensurePrompt(anchor)

	model.PrimaryPart = model:FindFirstChild("Counter")

	local beach = workspace:FindFirstChild("Beach")
	model.Parent = beach or workspace

	StoreBuilder.dressSign(origin)
	return model
end

--------------------------------------------------------------------------
-- THE PROMPT
--------------------------------------------------------------------------
function StoreBuilder.ensurePrompt(anchor: BasePart): ProximityPrompt
	local existing = anchor:FindFirstChild("ShopPrompt")
	if existing and existing:IsA("ProximityPrompt") then
		return existing
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ShopPrompt"
	prompt.ActionText = "Browse"
	prompt.ObjectText = "Beach Shop"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 14
	-- The counter itself stands between the player and the anchor, so a line of
	-- sight test would hide the prompt from exactly where you are meant to shop.
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor
	return prompt
end

--------------------------------------------------------------------------
-- THE SIGN
--------------------------------------------------------------------------
--[[
	Lifts Beach.UpgradeKiosk's billboard onto the shop roof, in the sell shop's
	sign geometry (15 x 3.6 at y + 12.9, board face turned to the beach).

	The model, the Board and its KioskGui all keep their names -- CTB_Client and
	SiftScreen both reach in by that path. What goes is the two ground posts: the
	shop stands where they did.
]]
function StoreBuilder.dressSign(origin: CFrame)
	local beach = workspace:FindFirstChild("Beach")
	local kiosk = beach and beach:FindFirstChild("UpgradeKiosk")
	if not kiosk then
		warn("[StoreBuilder] no Beach.UpgradeKiosk -- the shop has no sign")
		return
	end

	local board = kiosk:FindFirstChild("Board")
	if board and board:IsA("BasePart") then
		board.Size = Vector3.new(15, 4.4, 0.4)
		-- Turned about Y so the SurfaceGui's Front face (local -Z) reads from +Z,
		-- which is the side the beach and the counter are on.
		board.CFrame = origin * CFrame.new(0, 12.9, 0.2) * CFrame.Angles(0, math.pi, 0)
		board.Color = SIGN

		local gui = board:FindFirstChild("KioskGui")
		local title = gui and gui:FindFirstChild("TextLabel")
		if title and title:IsA("TextLabel") then
			-- It sold one track when it was a roller kiosk; it sells all five now,
			-- and the board says what it DOES rather than what it is called -- same
			-- pass that made the dune market's marquees read SELL and UPGRADES.
			-- SignDresser re-asserts this on every boot; both must agree.
			title.Text = "UPGRADES"
		end
	end

	-- The trim was mounted 0.1 studs in FRONT of the board and 0.4 larger on
	-- every side, which is not a frame -- it is a lid. It covered the sign face
	-- completely, which is why the billboard read as a blank gold slab. Behind
	-- the board it does the job it was drawn for: a gold border round a dark
	-- sign, exactly like the sell shop's.
	local trimPart = kiosk:FindFirstChild("BoardTrim")
	if trimPart and trimPart:IsA("BasePart") then
		trimPart.Size = Vector3.new(15.7, 5.1, 0.3)
		trimPart.CFrame = origin * CFrame.new(0, 12.9, -0.1)
		trimPart.Color = GOLD
	end

	-- The billboard's own legs. The shop occupies the sand they stood in.
	for _, child in kiosk:GetChildren() do
		if child.Name == "Post" then
			child:Destroy()
		end
	end
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------
function StoreBuilder.ensureWorld(origin: CFrame): Model?
	assert(RunService:IsServer(), "[StoreBuilder] server-only")

	local beach = workspace:FindFirstChild("Beach")
	local existing = beach and beach:FindFirstChild("Store")
	if existing then
		-- Adopted, not rebuilt. The one thing worth re-checking is the prompt:
		-- without it the shop is a very handsome building you cannot buy from.
		local anchor = existing:FindFirstChild("PromptAnchor")
		if anchor and anchor:IsA("BasePart") then
			StoreBuilder.ensurePrompt(anchor)
		else
			warn("[StoreBuilder] Beach.Store has no PromptAnchor -- nothing opens the shop")
		end
		return existing
	end

	return StoreBuilder.buildStore(origin)
end

return StoreBuilder
