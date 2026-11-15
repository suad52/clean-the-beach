--[[
	FreeRewardBoard  --  ServerScriptService.FreeRewardBoard

	The free reward's sign, standing on the far side of the beach from the
	leaderboards and built the same way they are.

	DELIBERATELY THE SAME OBJECT AS A LEADERBOARD: shadow slab, ink frame, sand
	face, two wooden posts, one SurfaceGui at 50 pixels per stud. It takes its
	WIDTH, HEIGHT and LIFT straight from LeaderboardConfig rather than declaring
	its own, so the pair cannot drift apart when one of them is retuned -- which is
	the whole point of a matched pair standing at opposite edges of the same field.

	WHAT IT IS NOT: a leaderboard. There is no polling, no OrderedDataStore and no
	rows -- it is a static sign, so it is built once and never written to again.
	The live state (have you joined, have you claimed) belongs on the PANEL, which
	is in front of the player's eyes; a board reading "you have already claimed
	this" from 260 studs away would be telling one player something in a place
	everyone else can read it.

	The prompt is what opens the panel. It is mounted on the face rather than on a
	post so the whole board is the target.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local FreeRewardConfig = require(Modules:WaitForChild("FreeRewardConfig"))
local LeaderboardConfig = require(Modules:WaitForChild("LeaderboardConfig"))

local FreeRewardBoard = {}

-- Lifted from LeaderboardBuilder so the two signs are the same object in two
-- places. Same names, same values.
local INK = Color3.fromRGB(56, 36, 20)
local SAND = Color3.fromRGB(255, 240, 205)
local WOOD = Color3.fromRGB(146, 96, 54)
local WOOD_DARK = Color3.fromRGB(92, 58, 32)
local SUN = Color3.fromRGB(255, 200, 62)
local LIME = Color3.fromRGB(140, 226, 96)
local GRAPE = Color3.fromRGB(186, 128, 255)
local PIXELS_PER_STUD = 50

local FOLDER_NAME = "FreeRewardBoard"
FreeRewardBoard.PromptName = "FreeRewardPrompt"

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame,
	colour: Color3, material: Enum.Material?): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	p.CanCollide = true
	p.Color = colour
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function label(parent: Instance, txt: string, size: number, font: Enum.Font,
	colour: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = font
	l.TextSize = size
	l.TextColor3 = colour
	l.Text = txt
	l.TextXAlignment = Enum.TextXAlignment.Center
	l.TextYAlignment = Enum.TextYAlignment.Center
	l.Parent = parent
	return l
end

local function stroke(gui: GuiObject, thickness: number, colour: Color3?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = colour or INK
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = gui
	return s
end

local function corner(gui: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = gui
	return c
end

--------------------------------------------------------------------------
-- ONE SIGN
--------------------------------------------------------------------------
-- Split out of build() when this stopped being a one-off on the beach.
-- Everything below the raycast is exactly as it was; the only change is that
-- WHERE it stands is an argument now rather than a constant read off the config.
local function buildSign(folder: Instance, base: Vector3, facing: Vector3): Model
	local W = LeaderboardConfig.BoardWidth
	local H = LeaderboardConfig.BoardHeight

	-- Stand it on the sand that is actually there. Same raycast the leaderboards
	-- use, and it ignores what has already been built so the sign cannot come to
	-- rest on a deckchair -- nor, now, on the sign raised for the previous island.
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { folder }
	rp.IgnoreWater = true
	local hit = workspace:Raycast(base + Vector3.new(0, 60, 0), Vector3.new(0, -140, 0), rp)
	local groundY = hit and hit.Position.Y or 3
	local centre = Vector3.new(base.X,
		groundY + LeaderboardConfig.BoardLift + H * 0.5, base.Z)

	local model = Instance.new("Model")
	model.Name = "FreeReward"
	model.Parent = folder

	-- CFrame.lookAt points the FRONT face (-Z) at the target, so the SurfaceGui
	-- goes on Front and the sign reads the right way round with no magic 180.
	local look = CFrame.lookAt(centre, centre + facing)
	local right = Vector3.yAxis:Cross(facing).Unit

	part(model, "Slab", Vector3.new(W + 1.6, H + 1.6, 0.6),
		look * CFrame.new(0, -0.5, 0.9), WOOD_DARK, Enum.Material.Wood)
	part(model, "Frame", Vector3.new(W + 1.1, H + 1.1, 0.6),
		look * CFrame.new(0, 0, 0.45), INK)
	local face = part(model, "Face", Vector3.new(W, H, 0.5), look, SAND)
	model.PrimaryPart = face

	local legHeight = LeaderboardConfig.BoardLift + 1
	for _, side in ipairs({ -1, 1 }) do
		local x = side * (W * 0.5 - 1.6)
		part(model, "Post", Vector3.new(1.4, legHeight, 1.4),
			CFrame.new(centre + right * x - Vector3.new(0, H * 0.5 + legHeight * 0.5 - 0.6, 0))
				* (look - look.Position), WOOD, Enum.Material.Wood)
	end

	----------------------------------------------------------------
	-- THE FACE
	----------------------------------------------------------------
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Board"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = PIXELS_PER_STUD
	-- Not AlwaysOnTop, and LightInfluence 0: a physical sign on the beach, legible
	-- at dusk, but drawn behind the palm in front of it. Same call the
	-- leaderboards make and for the same reason.
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = 420
	gui.Parent = face

	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Parent = gui

	-- BANNER, in the panel's own grape. The only place the colour appears.
	local banner = Instance.new("Frame")
	banner.Name = "Banner"
	banner.Size = UDim2.new(1, -40, 0, 150)
	banner.Position = UDim2.fromOffset(20, 18)
	banner.BackgroundColor3 = GRAPE
	banner.BorderSizePixel = 0
	banner.Parent = root
	corner(banner, 18)
	stroke(banner, 5)
	local title = label(banner, "FREE REWARD", 96, Enum.Font.LuckiestGuy, Color3.new(1, 1, 1))
	title.Size = UDim2.fromScale(1, 1)
	stroke(title, 5)

	-- THE PRIZE
	local prize = label(root, string.format("%s COINS", FreeRewardConfig.Coins >= 1000
		and (tostring(math.floor(FreeRewardConfig.Coins / 1000)) .. ",000")
		or tostring(FreeRewardConfig.Coins)), 120, Enum.Font.LuckiestGuy, SUN)
	prize.Size = UDim2.new(1, -40, 0, 130)
	prize.Position = UDim2.fromOffset(20, 186)
	stroke(prize, 6)

	--[[
		ONE REQUIREMENT, BECAUSE ONE IS ALL THAT CAN BE CHECKED.

		This used to be two chips -- "1. LIKE THE GAME" over "2. JOIN THE ... GROUP".
		The like is gone from the reward entirely (FreeRewardConfig carries the two
		reasons), and it is gone from the SIGN rather than being left up as
		decoration: an advert that lists a requirement the panel no longer asks for
		is an advert that lies, and a board promising coins directly beneath the
		word LIKE is the exact arrangement Roblox's rule on incentivised likes is
		about.

		The chip is taller than either of the two it replaces so the face does not
		read as a sign with a gap in it, and ONE PER ACCOUNT fills the rest -- a true
		thing worth saying before somebody walks over expecting to farm it.
	]]
	local chip = Instance.new("Frame")
	chip.Name = "Req1"
	chip.Size = UDim2.new(1, -80, 0, 92)
	chip.Position = UDim2.fromOffset(40, 340)
	chip.BackgroundColor3 = Color3.fromRGB(255, 170, 54)
	chip.BorderSizePixel = 0
	chip.Parent = root
	corner(chip, 14)
	stroke(chip, 4)
	local chipText = label(chip, string.format("JOIN THE %s GROUP",
		FreeRewardConfig.groupName():upper()), 52, Enum.Font.LuckiestGuy, Color3.new(1, 1, 1))
	chipText.Size = UDim2.fromScale(1, 1)
	stroke(chipText, 4)

	local once = label(root, "ONE PER ACCOUNT", 40, Enum.Font.LuckiestGuy, INK)
	once.Name = "OncePerAccount"
	once.Size = UDim2.new(1, -80, 0, 48)
	once.Position = UDim2.fromOffset(40, 452)

	-- THE CALL TO ACTION
	local cta = Instance.new("Frame")
	cta.Name = "Cta"
	cta.Size = UDim2.new(1, -80, 0, 86)
	cta.Position = UDim2.fromOffset(40, 528)
	cta.BackgroundColor3 = LIME
	cta.BorderSizePixel = 0
	cta.Parent = root
	corner(cta, 16)
	stroke(cta, 5)
	local ctaText = label(cta, "PRESS  E  TO CLAIM", 58, Enum.Font.LuckiestGuy,
		Color3.new(1, 1, 1))
	ctaText.Size = UDim2.fromScale(1, 1)
	stroke(ctaText, 4)

	----------------------------------------------------------------
	-- THE WAY IN
	----------------------------------------------------------------
	-- On the FACE, so the whole sign is the target rather than a post somebody
	-- has to find the side of. Matched BY NAME on the client, so renaming it here
	-- unhooks the panel -- the same contract MenuHud's world prompts keep.
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = FreeRewardBoard.PromptName
	prompt.ActionText = "Free reward"
	prompt.ObjectText = string.format("%d coins", FreeRewardConfig.Coins)
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 18
	prompt.RequiresLineOfSight = false
	prompt.Parent = face

	return model
end

--------------------------------------------------------------------------
-- ONE PER FIELD
--------------------------------------------------------------------------
function FreeRewardBoard.build()
	assert(RunService:IsServer(), "[FreeReward] board is server-built")

	local old = workspace:FindFirstChild(FOLDER_NAME)
	if old then
		-- Rebuilt every boot rather than adopted, exactly as the leaderboards are:
		-- it carries no state, and a half-built sign left by an edit session is
		-- worse than a moment of building.
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = workspace

	--[[
		ONE SIGN PER FIELD, standing opposite that field's row of leaderboards.

		EVERY COPY CARRIES THE SAME PROMPT NAME, which is what lets this ship with
		no client change at all: FreeRewardPanel matches PromptTriggered by NAME
		rather than against one remembered instance, so a fourth sign is simply a
		fourth way into the same panel.

		Placement comes from LeaderboardConfig.boardLine off FreeRewardConfig.Sites,
		the same helper the leaderboards use -- so a sign cannot drift away from the
		row it is supposed to mirror, and a field that is ever resized moves both.
	]]
	local placed = {}
	for _, site in ipairs(FreeRewardConfig.Sites) do
		local x, facing, cz, island = LeaderboardConfig.boardLine(site)
		local model = buildSign(folder, Vector3.new(x, 0, cz + (site.along or 0)), facing.Unit)
		model.Name = "FreeReward_" .. island
		table.insert(placed, string.format("%s x=%d", island, x))
	end

	print(string.format("[FreeReward] %d boards up, mirroring the leaderboards: %s",
		#placed, table.concat(placed, ", ")))
	return folder
end

return FreeRewardBoard
