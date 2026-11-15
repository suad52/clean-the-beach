--[[
	PenguinBuilder  --  ServerScriptService.PenguinBuilder  (ModuleScript)

	THE BIRDS. One builder, one template mesh, many clones: every penguin on
	Penguin Island is the pet library's own Waddle Penguin (a textured MeshPart,
	ReplicatedStorage.Pets.Uncommon.Pet_Uncommon_10_WaddlePenguin) wrapped in a
	Model with an invisible Root, a PromptAnchor for PenguinService to hang its
	"Pet" prompt on, and -- for variety a textured mesh cannot give by colour --
	a size class and an accessory: a scarf, a bow, a knitted hat, or the red one
	with the white brim, because the ferryman here is who he is.

	WHAT IT DOES NOT DO. It does not connect an event, animate anything, or pay
	a coin. PenguinService binds the prompt by tag and pays; Island5_Client bobs
	and nods them on every player's own screen off server time. This file only
	decides what a penguin IS, and the island builder decides where each one
	stands.

	PART COST: 3 parts a bird (Root, Body, PromptAnchor) plus 1-6 for the
	accessory. Nothing carries a light, an emitter or a shadow; the mesh keeps
	its own shadow because it is the one thing here with a silhouette.

	CONTRACT with the island builder: spawn(parent, cf, opts) returns the Model,
	local frame y = 0 at the bird's feet, facing its own -Z. It never throws --
	a missing library mesh falls back to a two-ball bird so the colony is still
	a colony.
]]

local PenguinBuilder = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

-- The tag PenguinService binds. Read off GameConfig if it names one, so the two
-- files cannot disagree; the literal is the fallback for a GameConfig that has
-- not been told yet.
PenguinBuilder.TAG = "Penguin"
do
	local ok, GameConfig = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("GameConfig"))
	end)
	if ok and type(GameConfig) == "table" and type(GameConfig.Tags) == "table"
		and type(GameConfig.Tags.Penguin) == "string" then
		PenguinBuilder.TAG = GameConfig.Tags.Penguin
	end
end

-- The library mesh: 11.44 x 12.69 x 6.36 studs, head at -Z like the whole
-- roster, one baked texture. Resolved once, never assumed.
local MESH_PATH = { "Pets", "Uncommon", "Pet_Uncommon_10_WaddlePenguin" }
local MESH_RAW_HEIGHT = 12.69

local template: BasePart? = nil
do
	local node: Instance? = ReplicatedStorage
	for _, name in ipairs(MESH_PATH) do
		node = node and node:FindFirstChild(name)
	end
	if node and node:IsA("BasePart") then
		template = node
	else
		warn("[Penguin] the Waddle Penguin mesh is not in ReplicatedStorage.Pets; the colony "
			.. "will be built from primitives")
	end
end

local INK = Color3.fromRGB(30, 34, 44)
local BELLY = Color3.fromRGB(240, 242, 246)
local BEAK = Color3.fromRGB(250, 172, 52)
local RED = Color3.fromRGB(206, 44, 48)
local GREEN = Color3.fromRGB(46, 128, 84)
local GOLD = Color3.fromRGB(236, 196, 84)
local BLUE = Color3.fromRGB(70, 130, 210)
local WHITE = Color3.fromRGB(250, 250, 252)

local NOHIT = { CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false }

local function P(parent, name, size, cf, colour, material, extra)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = colour or WHITE
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if extra then
		for k, v in pairs(extra) do
			p[k] = v
		end
	end
	p.Parent = parent
	return p
end

--[[
	SIZE CLASSES. Three, because a colony of one size reads as a row of pins:
	chicks at the feet of the adults, adults everywhere, and a few emperors a
	head taller than anyone -- the biggest penguin on the beach, which is a
	line one of the island's finds makes a joke of.
]]
local CLASS = {
	chick = { height = 2.9, bob = 1.3 },
	adult = { height = 4.6, bob = 1.0 },
	emperor = { height = 5.7, bob = 0.8 },
}

-- Accessories, drawn in the bird's own frame at its neck/head. `h` is the
-- bird's height; everything scales off it so a chick's scarf is a chick's.
local ACCESSORY = {}

function ACCESSORY.scarf(m, base: CFrame, h: number, colour: Color3?)
	local c = colour or RED
	local neckY = h * 0.62
	local w = h * 0.36
	-- a band round the neck (a flat cylinder on its side), and a tail that
	-- hangs down the back
	P(m, "Scarf", Vector3.new(w * 1.05, h * 0.08, w * 1.05),
		base * CFrame.new(0, neckY, 0), c, Enum.Material.Fabric,
		{ Shape = Enum.PartType.Cylinder, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
	P(m, "ScarfTail", Vector3.new(h * 0.08, h * 0.22, h * 0.05),
		base * CFrame.new(w * 0.22, neckY - h * 0.1, w * 0.46) * CFrame.Angles(0.15, 0, 0.2),
		c, Enum.Material.Fabric, NOHIT)
end

function ACCESSORY.bow(m, base: CFrame, h: number, colour: Color3?)
	local c = colour or GOLD
	local y = h * 0.96
	for _, s in ipairs({ -1, 1 }) do
		P(m, "BowLoop", Vector3.new(h * 0.12, h * 0.08, h * 0.05),
			base * CFrame.new(s * h * 0.07, y, -h * 0.02) * CFrame.Angles(0, 0, s * 0.5),
			c, Enum.Material.Fabric, NOHIT)
	end
	P(m, "BowKnot", Vector3.new(h * 0.05, h * 0.05, h * 0.05),
		base * CFrame.new(0, y, -h * 0.02), c, Enum.Material.Fabric, NOHIT)
end

function ACCESSORY.beanie(m, base: CFrame, h: number, colour: Color3?)
	local c = colour or BLUE
	local y = h * 0.94
	local w = h * 0.3
	P(m, "Beanie", Vector3.new(w, h * 0.12, w),
		base * CFrame.new(0, y, 0), c, Enum.Material.Fabric,
		{ Shape = Enum.PartType.Ball, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
	P(m, "BeanieBand", Vector3.new(w * 1.06, h * 0.04, w * 1.06),
		base * CFrame.new(0, y - h * 0.04, 0), WHITE, Enum.Material.Fabric,
		{ Shape = Enum.PartType.Cylinder, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
	P(m, "BeanieBobble", Vector3.new(h * 0.09, h * 0.09, h * 0.09),
		base * CFrame.new(0, y + h * 0.08, 0), WHITE, Enum.Material.Fabric,
		{ Shape = Enum.PartType.Ball, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
end

-- The one every child on the island will point at.
function ACCESSORY.santaHat(m, base: CFrame, h: number)
	local y = h * 0.94
	local w = h * 0.3
	-- a cone in three discs, tipped back, with the brim and the bobble
	for i = 0, 2 do
		P(m, "HatCone", Vector3.new(w * (0.95 - i * 0.28), h * 0.07, w * (0.95 - i * 0.28)),
			base * CFrame.new(0, y + h * (0.02 + i * 0.065), h * 0.02 * i) * CFrame.Angles(0.18, 0, 0),
			RED, Enum.Material.Fabric,
			{ Shape = Enum.PartType.Cylinder, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
	end
	P(m, "HatBrim", Vector3.new(w * 1.12, h * 0.05, w * 1.12),
		base * CFrame.new(0, y - h * 0.01, 0), WHITE, Enum.Material.Fabric,
		{ Shape = Enum.PartType.Cylinder, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
	P(m, "HatBobble", Vector3.new(h * 0.1, h * 0.1, h * 0.1),
		base * CFrame.new(0, y + h * 0.2, h * 0.09), WHITE, Enum.Material.Fabric,
		{ Shape = Enum.PartType.Ball, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
end

-- Fix the cylinders: a Part cylinder's axis is X, and every band above wants
-- it vertical. Rotating the CFrame is cleaner than remembering it per call.
local function uprightCylinders(m: Model)
	for _, p in ipairs(m:GetChildren()) do
		if p:IsA("Part") and p.Shape == Enum.PartType.Cylinder then
			p.CFrame = p.CFrame * CFrame.Angles(0, 0, math.pi * 0.5)
			p.Size = Vector3.new(p.Size.Y, p.Size.X, p.Size.Z)
		end
	end
end

--[[
	spawn(parent, cf, opts)
	  opts.class      "chick" | "adult" | "emperor"   (default adult)
	  opts.accessory  "scarf" | "bow" | "beanie" | "santaHat" | nil
	  opts.colour     Color3 for the scarf/bow/beanie
	  opts.seed       number, for the phase the client bobs at and the path it walks
	  opts.roam       studs the bird wanders from its spot (0 = stays put)
	Returns the Model (tagged, PrimaryPart = Root), or nil if parent is nil.
]]
function PenguinBuilder.spawn(parent: Instance, cf: CFrame, opts): Model?
	if not parent then
		return nil
	end
	opts = opts or {}
	local class = CLASS[opts.class or "adult"] or CLASS.adult
	local h = class.height

	local m = Instance.new("Model")
	m.Name = "Penguin"

	local root = P(m, "Root", Vector3.new(1, 1, 1), cf, WHITE, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
	m.PrimaryPart = root

	local body
	if template then
		body = template:Clone()
		body.Name = "Body"
		for _, junk in ipairs(body:GetChildren()) do
			junk:Destroy()
		end
		local f = h / MESH_RAW_HEIGHT
		body.Size = template.Size * f
		-- White, or the texture renders at the importer's 64% grey -- the one
		-- lesson every mesh in this place has taught twice.
		body.Color = Color3.new(1, 1, 1)
		body.Material = Enum.Material.SmoothPlastic
		body.Anchored = true
		body.CanCollide = false
		body.CanQuery = false
		body.CanTouch = false
		body.CastShadow = true
		body.CFrame = cf * CFrame.new(0, h * 0.5, 0)
		body.Parent = m
	else
		-- Primitives: a black ball over a white one, and a beak. It is a
		-- penguin the way the ferry card's are penguins.
		body = P(m, "Body", Vector3.new(h * 0.62, h, h * 0.55), cf * CFrame.new(0, h * 0.5, 0),
			INK, Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Ball, CanCollide = false, CanQuery = false, CanTouch = false })
		P(m, "Belly", Vector3.new(h * 0.42, h * 0.66, h * 0.3), cf * CFrame.new(0, h * 0.42, -h * 0.16),
			BELLY, Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Ball, CanCollide = false, CanQuery = false, CanTouch = false })
		P(m, "Beak", Vector3.new(h * 0.12, h * 0.08, h * 0.2), cf * CFrame.new(0, h * 0.8, -h * 0.34),
			BEAK, Enum.Material.SmoothPlastic, NOHIT)
	end

	-- The prompt hangs on this. Chest height, a little bigger than the bird,
	-- CanQuery off (RequiresLineOfSight is off on the prompt, so nothing needs
	-- to hit it) -- exactly the shop anchors' arrangement.
	P(m, "PromptAnchor", Vector3.new(h * 0.7, h * 0.8, h * 0.6), cf * CFrame.new(0, h * 0.5, 0),
		WHITE, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })

	local dress = opts.accessory and ACCESSORY[opts.accessory]
	if dress then
		dress(m, cf, h, opts.colour)
		uprightCylinders(m)
	end

	m:SetAttribute("Bob", class.bob)
	m:SetAttribute("Phase", ((opts.seed or 0) % 628) / 100)
	m:SetAttribute("Seed", opts.seed or 0)
	m:SetAttribute("Class", opts.class or "adult")
	m:SetAttribute("PromptReach", 12)
	-- How far this bird wanders from where it was stood (Island5_Client walks
	-- it; PenguinService widens the prompt's reach by the same amount). Zero
	-- is a bird that stays put.
	m:SetAttribute("Roam", opts.roam or 0)
	m.Parent = parent
	CollectionService:AddTag(m, PenguinBuilder.TAG)
	return m
end

return PenguinBuilder
