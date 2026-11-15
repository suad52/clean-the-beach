--[[
	BayBuilder  --  ServerScriptService.BayBuilder

	Builds the sifting bay IF one is not already authored. Replaces the old
	StationBuilder (which built a sifting table, a beach and a sell counter --
	none of which this game needs, since Clean the Beach supplies the beach and
	the sell pad, and sifting is gone).

	ADOPTION CONTRACT
	-----------------
	A fallback, not an owner. If a Model already carries the SiftBay tag this
	does nothing, so the moment you hand-build a nicer bay in Studio and tag it,
	this code stops running and SiftServer binds to yours instead.

	What a hand-authored bay must provide:
		SiftBay (Model)
			Screen       : BasePart  -- REQUIRED. the lump sits just above its top
			PromptAnchor : BasePart  -- optional, where E appears (defaults Screen)

	THE ONE GEOMETRY RULE
	---------------------
	Nothing may sit between the screen and the player. There is no aim ray to
	block any more -- shaking does not point at anything -- but there is still
	a CAMERA. The client frames the deck and holds it there for the whole
	session, and the reveal happens right there at the end of it, so anything
	standing in front of the rig is in shot the entire time. Everything here is
	behind, to the side, or overhead: the front of the shack is a doorway and
	stays empty.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local SignKit = require(Modules:WaitForChild("SignKit"))

local BayBuilder = {}

-- Lifted off Beach.SellArea part for part, so the shack is visibly the same
-- carpenter: POST/PLANK/PLANK_LIT/CRATE/CANVAS/SIGN are that shop's Post, Back,
-- Counter, Crate, Awning and SignBoard colours exactly. SEA is the sifting bay's
-- own accent -- the one thing that tells the two buildings apart at a distance.
local POST = Color3.fromRGB(99, 66, 40)
local PLANK = Color3.fromRGB(151, 104, 64)
local PLANK_LIT = Color3.fromRGB(196, 150, 100)
local CRATE = Color3.fromRGB(168, 124, 78)
local CANVAS = Color3.fromRGB(246, 246, 240)
local SIGN = Color3.fromRGB(38, 42, 48)

local SEA = Color3.fromRGB(52, 120, 148)
local SEA_DEEP = Color3.fromRGB(32, 84, 108)
local WATER = Color3.fromRGB(96, 172, 196)

local METAL = Color3.fromRGB(178, 184, 194)
local METAL_DARK = Color3.fromRGB(96, 102, 112)

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

--[[
	THE SIFT BAY BUILDER IS GONE (2026-08). buildSiftBay and ensureWorld built
	and tagged the shake-the-screen bay for the sift minigame, which was fully
	removed -- its three modules are parked in
	ServerStorage.SiftSystem_BACKUP_2026_08_24. Nothing ever called ensureWorld
	(ServerMain calls ensureWashBay only) and nothing in the place carried the
	SiftBay tag. The wash bay below is the live bay and, per its own header,
	shared no helpers with the removed builder.
]]

--------------------------------------------------------------------------
-- WASH BAY  (restored)
--------------------------------------------------------------------------
--[[
	Self-contained on purpose: it shares no helpers with buildSiftBay, so the
	two can be edited independently and neither can break the other.

	THE ONE GEOMETRY RULE: nothing may sit between the stand and the player.
	The washer aims with a raycast filtered to the crust, so stray parts cannot
	block the shot -- but they can block the CAMERA, and a splash guard in front
	of the lump would make half the chunks unreachable. Guard is rear and sides.
]]
function BayBuilder.buildWashBay(origin: CFrame): Model
	local CS = game:GetService("CollectionService")
	local model = Instance.new("Model")
	model.Name = "WashBay"

	local function part(props)
		local p = Instance.new("Part")
		p.Anchored = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		for k, v in props do
			if k ~= "Offset" then p[k] = v end
		end
		p.CFrame = origin * props.Offset
		p.Parent = model
		return p
	end
	local function round(p, r)
		local m2 = Instance.new("SpecialMesh")
		m2.MeshType = Enum.MeshType.Brick
		m2.Parent = p
	end

	part({ Name = "DrainPan", Size = Vector3.new(9, 0.3, 7),
		Color = Color3.fromRGB(96, 102, 112), Material = Enum.Material.DiamondPlate,
		Offset = CFrame.new(0, 0.15, 0) })

	for i = 1, 7 do
		part({ Name = "Grate" .. i, Size = Vector3.new(7.6, 0.12, 0.22),
			Color = Color3.fromRGB(64, 68, 76), Material = Enum.Material.Metal,
			CanCollide = false, CanQuery = false,
			Offset = CFrame.new(0, 0.33, -1.8 + (i - 1) * 0.6) })
	end

	part({ Name = "Column", Size = Vector3.new(1.1, 3.0, 1.1),
		Color = Color3.fromRGB(96, 102, 112), Material = Enum.Material.Metal,
		Offset = CFrame.new(0, 1.65, 0) })

	part({ Name = "StandVisual", Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.4, 2.6, 2.6), Color = Color3.fromRGB(178, 184, 194),
		Material = Enum.Material.Metal, Reflectance = 0.15,
		Offset = CFrame.new(0, 3.3, 0) * CFrame.Angles(0, 0, math.rad(90)) })

	-- A rotated cylinder's local +Y points sideways, which would send the mount
	-- offset through the pedestal. A flat plate carries the real name.
	part({ Name = "Stand", Size = Vector3.new(2.4, 0.18, 2.4), Transparency = 1,
		CanCollide = false, CanQuery = false, CanTouch = false,
		Offset = CFrame.new(0, 3.45, 0) })

	part({ Name = "GuardBack", Size = Vector3.new(9, 7, 0.3),
		Color = Color3.fromRGB(126, 138, 150), Material = Enum.Material.Metal,
		Transparency = 0.25, Reflectance = 0.08, Offset = CFrame.new(0, 3.6, -3.4) })
	for _, sx in { -1, 1 } do
		part({ Name = "GuardSide", Size = Vector3.new(0.3, 7, 6.8),
			Color = Color3.fromRGB(126, 138, 150), Material = Enum.Material.Metal,
			Transparency = 0.25, Reflectance = 0.08,
			Offset = CFrame.new(sx * 4.35, 3.6, 0) })
	end

	part({ Name = "PromptAnchor", Size = Vector3.new(1, 1, 1), Transparency = 1,
		CanCollide = false, CanQuery = false, CanTouch = false,
		Offset = CFrame.new(0, 3.2, 3.2) })

	part({ Name = "SignPost", Size = Vector3.new(0.3, 3.6, 0.3),
		Color = Color3.fromRGB(92, 58, 32), Material = Enum.Material.Wood,
		Offset = CFrame.new(-4.7, 8.2, 0) })
	local board = part({ Name = "SignBoard", Size = Vector3.new(0.25, 1.6, 4.0),
		Color = Color3.fromRGB(52, 120, 148), Material = Enum.Material.Metal,
		Offset = CFrame.new(-4.85, 9.6, 0) })

	-- BOTH faces, the way Beach.SellArea's board is built. A thin board has two
	-- readable sides and signing only one is a coin flip you lose half the time:
	-- the authored bay in the place file had exactly this problem and read as an
	-- unlabelled shed from the only direction anyone walks up from.
	SignKit.dress(board, "WASH BAY", { Enum.NormalId.Left, Enum.NormalId.Right })

	model.PrimaryPart = model:FindFirstChild("Column")
	model.Parent = workspace
	CS:AddTag(model, "WashBay")
	return model
end

function BayBuilder.ensureWashBay(origin: CFrame)
	local CS = game:GetService("CollectionService")
	if #CS:GetTagged("WashBay") > 0 then return end
	BayBuilder.buildWashBay(origin)
end

return BayBuilder
