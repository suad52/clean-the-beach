--[[
	LeaderboardBuilder  --  ServerScriptService.LeaderboardBuilder

	The three boards as OBJECTS: posts, a slab, a face, a SurfaceGui with ten
	empty rows on it, and an empty podium standing in front. It knows nothing
	about scores -- LeaderboardService fills the rows in and LeaderboardWinner
	puts somebody on the podium -- so this file runs once at boot and is then
	only ever read.

	BUILT IN CODE RATHER THAN PLACED BY HAND, like every other fixture in this
	game (the store, the sell area, the egg plazas, the duel arenas). The reason
	is the same one the other builders give: a board placed by hand is a board
	that has to be found and re-placed by hand the day the spawn moves, and the
	one thing all three of these need is to be exactly where the player lands.

	THE LOOK IS THE PANEL LOOK, in wood: a shadow slab behind, a thick dark
	frame, a cream face and a tinted banner across the top. Same recipe as
	PanelKit's card and the same palette, so a board read from the sand belongs
	to the same set of objects as the panels read from the HUD.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LeaderboardConfig = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("LeaderboardConfig"))

local LeaderboardBuilder = {}

-- PanelKit's palette. See LeaderboardConfig.Boards for why these are written
-- out rather than required.
local INK       = Color3.fromRGB(56, 36, 20)
local SAND      = Color3.fromRGB(255, 240, 205)
local SAND_MID  = Color3.fromRGB(246, 219, 165)
local WHITE     = Color3.fromRGB(255, 255, 255)
local WOOD      = Color3.fromRGB(146, 96, 54)
local WOOD_DARK = Color3.fromRGB(92, 58, 32)

-- The three podium colours. Only the top three rows wear one; every row below
-- them is plain, which is what makes the top three read as a podium at all.
local MEDALS = {
	Color3.fromRGB(255, 200, 62),
	Color3.fromRGB(214, 218, 226),
	Color3.fromRGB(214, 143, 84),
}

local PIXELS_PER_STUD = 50

--------------------------------------------------------------------------
-- SMALL PARTS
--------------------------------------------------------------------------
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

local function label(parent: Instance, text: string, size: number, font: Enum.Font, colour: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = font
	l.TextSize = size
	l.TextColor3 = colour
	l.Text = text
	l.TextXAlignment = Enum.TextXAlignment.Left
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

local function disc(parent: Instance, name: string, diameter: number, height: number,
	centre: Vector3, colour: Color3, material: Enum.Material?): BasePart
	-- A cylinder Part's axis runs along its LOCAL X, so a disc lying flat is one
	-- rolled a quarter turn about Z and sized (height, diameter, diameter).
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(height, diameter, diameter)
	p.CFrame = CFrame.new(centre) * CFrame.Angles(0, 0, math.rad(90))
	p.Anchored = true
	p.CanCollide = true
	p.Color = colour
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function corner(gui: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = gui
	return c
end

--------------------------------------------------------------------------
-- ONE ROW
--------------------------------------------------------------------------
--[[
	RANK | FACE | NAME .................. VALUE

	The name is the only elastic column and it is the one that has to give:
	Roblox display names run to twenty characters and a top-ten score can run to
	six, so the value gets a fixed right-hand column and the name is truncated
	into whatever is left. Truncating the SCORE would be absurd, and letting the
	name push it off the board is the same bug with extra steps.

	THE FACE IS A THUMBNAIL URL, NOT A WEB CALL. `rbxthumb://` is resolved by
	the CLIENT when it draws the image, so ten headshots per board cost the
	server nothing -- no GetUserThumbnailAsync, no yield inside the poll, and no
	third per-minute web throttle to share with the name lookups. The service
	hands this label a user id and the picture arrives on its own.
]]
local function buildRow(parent: Instance, index: number, rowHeight: number)
	local row = Instance.new("Frame")
	row.Name = "Row" .. index
	row.Size = UDim2.new(1, 0, 0, rowHeight)
	row.BackgroundColor3 = (index % 2 == 0) and SAND_MID or SAND
	row.BorderSizePixel = 0
	row.LayoutOrder = index
	row.Parent = parent
	corner(row, 10)

	-- The rank disc.
	local medal = MEDALS[index]
	local rank = Instance.new("Frame")
	rank.Name = "Rank"
	rank.Size = UDim2.fromOffset(rowHeight - 10, rowHeight - 10)
	rank.Position = UDim2.fromOffset(7, 5)
	rank.BackgroundColor3 = medal or Color3.fromRGB(206, 190, 164)
	rank.BorderSizePixel = 0
	rank.Parent = row
	corner(rank, math.floor((rowHeight - 10) * 0.5))
	stroke(rank, 3)

	local rankText = label(rank, tostring(index), math.floor(rowHeight * 0.5),
		Enum.Font.LuckiestGuy, medal and INK or Color3.fromRGB(90, 74, 56))
	rankText.Size = UDim2.fromScale(1, 1)
	rankText.TextXAlignment = Enum.TextXAlignment.Center

	-- The headshot, sitting in the gap the rank disc leaves. STARTS HIDDEN
	-- rather than blank: an empty circle on every unfilled row would read as ten
	-- pictures that failed to load, which is the one thing a picture must never
	-- look like. The service shows it the moment it has a user id for the row.
	-- MEASURED FROM THE OUTSIDE OF THE STROKES, not from the frames. A UIStroke
	-- is drawn OUTSIDE the element it is on, so two discs laid out to touch at
	-- their edges overlap by twice the stroke -- which on a 38px row is the
	-- difference between a rank badge beside a face and the two of them welded
	-- together.
	local faceSize = rowHeight - 6
	local face = Instance.new("ImageLabel")
	face.Name = "Face"
	face.Size = UDim2.fromOffset(faceSize, faceSize)
	face.Position = UDim2.fromOffset(rowHeight + 7, 3)
	face.BackgroundColor3 = SAND
	face.BorderSizePixel = 0
	face.Image = ""
	face.Visible = false
	face.Parent = row
	corner(face, math.floor(faceSize * 0.5))
	-- Wearing the rank's own colour on the podium three, so the medal reads twice
	-- and the face is framed rather than cut out.
	stroke(face, 2, medal or INK)

	-- The name. Left-aligned, truncated, and it starts blank: the service writes
	-- every row on the first poll and an empty board says "loading" honestly.
	local nameX = rowHeight + 7 + faceSize + 8
	local name = label(row, "", math.floor(rowHeight * 0.5), Enum.Font.GothamBold, INK)
	name.Name = "PlayerName"
	name.Position = UDim2.fromOffset(nameX, 0)
	name.Size = UDim2.new(1, -nameX - 250, 1, 0)
	name.TextTruncate = Enum.TextTruncate.AtEnd

	local value = label(row, "", math.floor(rowHeight * 0.56), Enum.Font.LuckiestGuy, INK)
	value.Name = "Value"
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.new(1, -14, 0, 0)
	value.Size = UDim2.fromOffset(236, rowHeight)
	value.TextXAlignment = Enum.TextXAlignment.Right

	return { frame = row, name = name, value = value, face = face }
end

--------------------------------------------------------------------------
-- THE WINNER'S PODIUM
--------------------------------------------------------------------------
--[[
	A three-tier disc standing in front of the board, for the account at the top
	of it to dance on. LeaderboardWinner puts somebody on it; this only stands it
	up, and it STAYS STANDING WHEN IT IS EMPTY. An empty podium in front of a
	board nobody has topped yet says exactly that, where a podium that appears
	and disappears with its occupant reads as scenery failing to load.

	It wears the BOARD'S OWN TINT, so which board a winner belongs to is answered
	by what they are standing on rather than by counting along the row -- and the
	cap is sand, because a figure needs to stand on something lighter than itself
	to read from thirty studs away.
]]
local function buildPodium(parent: Instance, def, centre: Vector3, facing: Vector3, groundY: number)
	local model = Instance.new("Model")
	model.Name = "Podium"
	model.Parent = parent

	local at = Vector3.new(centre.X, groundY, centre.Z) + facing * LeaderboardConfig.PodiumStandoff
	local W = LeaderboardConfig.PodiumWidth
	local H = LeaderboardConfig.PodiumHeight

	-- Plinth, drum, cap: the same shadow / frame / face stack the board itself is
	-- built from, rolled round.
	local plinth = disc(model, "Plinth", W, H * 0.25,
		at + Vector3.new(0, H * 0.125, 0), WOOD_DARK, Enum.Material.Wood)
	disc(model, "Drum", W - 1, H * 0.6, at + Vector3.new(0, H * 0.55, 0), def.tint)
	disc(model, "Cap", W - 0.6, H * 0.15, at + Vector3.new(0, H * 0.925, 0), SAND)
	model.PrimaryPart = plinth

	return { model = model, top = at + Vector3.new(0, H, 0), facing = facing }
end

--------------------------------------------------------------------------
-- ONE BOARD
--------------------------------------------------------------------------
local function buildBoard(parent: Instance, def, centre: Vector3, facing: Vector3)
	local W, H = LeaderboardConfig.BoardWidth, LeaderboardConfig.BoardHeight

	local model = Instance.new("Model")
	model.Name = "Leaderboard_" .. def.key
	model.Parent = parent

	-- CFrame.lookAt points the FRONT face (-Z, which is Enum.NormalId.Front) at
	-- the target, so the SurfaceGui below goes on Front and the board reads the
	-- right way round without a magic 180 anywhere.
	local look = CFrame.lookAt(centre, centre + facing)
	local right = Vector3.yAxis:Cross(facing).Unit

	-- Shadow slab, then frame, then face: three planes a few tenths apart, which
	-- is the same trick PanelKit's card does in 2D. Any less separation and they
	-- z-fight from across the beach.
	part(model, "Slab", Vector3.new(W + 1.6, H + 1.6, 0.6),
		look * CFrame.new(0, -0.5, 0.9), WOOD_DARK, Enum.Material.Wood)
	part(model, "Frame", Vector3.new(W + 1.1, H + 1.1, 0.6),
		look * CFrame.new(0, 0, 0.45), INK)
	local face = part(model, "Face", Vector3.new(W, H, 0.5), look, SAND)
	model.PrimaryPart = face

	-- Two legs, from the bottom edge down to the sand.
	local legHeight = LeaderboardConfig.BoardLift + 1
	for _, side in ipairs({ -1, 1 }) do
		local x = side * (W * 0.5 - 1.6)
		part(model, "Post", Vector3.new(1.4, legHeight, 1.4),
			CFrame.new(centre + right * x - Vector3.new(0, H * 0.5 + legHeight * 0.5 - 0.6, 0))
				* (look - look.Position), WOOD, Enum.Material.Wood)
	end

	--------------------------------------------------------------------
	-- THE FACE
	--------------------------------------------------------------------
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Board"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = PIXELS_PER_STUD
	-- ALWAYS ON TOP IS WRONG HERE. This is a physical object in the world, not a
	-- HUD: drawn through the palm in front of it, it would stop reading as a
	-- board standing on the beach and start reading as a screen bolted to the
	-- camera. LightInfluence 0 keeps it legible at dusk without that.
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	-- Wide enough to cover the whole field. Standing at the beach's far edge puts
	-- 266 studs between the player and these, and a board that blinks out while
	-- you are looking straight at it reads as a bug rather than as a draw limit.
	gui.MaxDistance = 420
	gui.Parent = face

	local px, py = W * PIXELS_PER_STUD, H * PIXELS_PER_STUD

	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Parent = gui

	-- BANNER. The board's own colour, and the only place it appears -- a whole
	-- face in grape would fight every row drawn on it.
	local banner = Instance.new("Frame")
	banner.Name = "Banner"
	banner.Size = UDim2.new(1, -24, 0, 178)
	banner.Position = UDim2.fromOffset(12, 12)
	banner.BackgroundColor3 = def.tint
	banner.BorderSizePixel = 0
	banner.Parent = root
	corner(banner, 18)
	stroke(banner, 5)

	local title = label(banner, def.title, 74, Enum.Font.LuckiestGuy, WHITE)
	title.Size = UDim2.new(1, -20, 0, 88)
	title.Position = UDim2.fromOffset(10, 6)
	title.TextXAlignment = Enum.TextXAlignment.Center
	stroke(title, 5)

	local blurb = label(banner, def.blurb, 30, Enum.Font.GothamBold, INK)
	blurb.Size = UDim2.new(1, -20, 0, 40)
	blurb.Position = UDim2.fromOffset(10, 96)
	blurb.TextXAlignment = Enum.TextXAlignment.Center
	blurb.TextTransparency = 0.15

	-- The line the service stamps with how fresh the board is. IT USED TO SIT ON
	-- THE BOTTOM EDGE OF THE FACE, and that strip now belongs to the winner: a
	-- 5.5-stud avatar on the podium reaches a couple of studs above the board's
	-- bottom edge and cut the sentence clean in half. Up here it is out of the
	-- way, and it groups with the other two lines that describe the BOARD rather
	-- than a rank on it -- which is where it belonged anyway.
	local stamp = label(banner, "", 26, Enum.Font.GothamBold, INK)
	stamp.Name = "Stamp"
	stamp.Size = UDim2.new(1, -20, 0, 32)
	stamp.Position = UDim2.fromOffset(10, 138)
	stamp.TextXAlignment = Enum.TextXAlignment.Center
	stamp.TextTransparency = 0.35

	-- THE WELL the rows sit in, dark for the reason the panels went dark: a
	-- cream row on a cream face is three tones within a few percent of each
	-- other, and no amount of aligning fixes a surface with no darks in it.
	local well = Instance.new("Frame")
	well.Name = "Well"
	well.Position = UDim2.fromOffset(12, 200)
	-- STOPS WELL SHORT OF THE BOTTOM EDGE, and the margin is load-bearing now: it
	-- is the strip the winner's head passes through. Shrink it and the podium
	-- starts eating rows 9 and 10.
	well.Size = UDim2.new(1, -24, 1, -252)
	well.BackgroundColor3 = Color3.fromRGB(84, 56, 34)
	well.BorderSizePixel = 0
	well.ClipsDescendants = true
	well.Parent = root
	corner(well, 14)
	stroke(well, 4)

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = well

	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 5)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = well

	-- Rows sized to fill the well exactly, so ten of them reach the bottom edge
	-- whatever the board height is set to.
	local wellPx = (py - 252) - 16
	local n = LeaderboardConfig.TopN
	local rowHeight = math.floor((wellPx - (n - 1) * 5) / n)

	local rows = {}
	for i = 1, n do
		rows[i] = buildRow(well, i, rowHeight)
	end

	local podium = buildPodium(model, def, centre, facing,
		centre.Y - H * 0.5 - LeaderboardConfig.BoardLift)

	return { def = def, model = model, gui = gui, rows = rows, stamp = stamp, podium = podium }
end

--------------------------------------------------------------------------
-- ALL THREE
--------------------------------------------------------------------------
function LeaderboardBuilder.build()
	local folder = workspace:FindFirstChild("Leaderboards")
	if folder then
		-- Rebuilt from scratch on every boot rather than adopted. These carry no
		-- state worth keeping -- every row is rewritten within a minute anyway --
		-- and a half-built set left behind by an edit session is worse than a
		-- second of building.
		folder:Destroy()
	end
	folder = Instance.new("Folder")
	folder.Name = "Leaderboards"
	folder.Parent = workspace

	--[[
		A LIST PER KEY, NOT ONE BOARD PER KEY.

		Every field with a row carries the SAME three boards showing the SAME
		global ranking, so `built.money` is now every money board in the world
		rather than the one on the beach.

		LeaderboardService fetches each store ONCE and paints the whole list --
		see its pollOne. Polling per board instead would multiply this feature's
		DataStore read budget by the number of islands, which is exactly what the
		cadence note in LeaderboardConfig exists to protect.
	]]
	local built = {}
	for _, def in ipairs(LeaderboardConfig.Boards) do
		built[def.key] = {}
	end

	-- Hoisted out of the loop: it excludes only what this builder is making, and
	-- that is the same set for every board.
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { folder }
	rp.IgnoreWater = true

	local placed = {}
	for _, site in ipairs(LeaderboardConfig.Sites) do
		local x, facing, cz, island = LeaderboardConfig.boardLine(site)
		facing = facing.Unit

		-- One folder per island, so the world tree reads as four rows rather than
		-- twelve models sharing three names.
		local siteFolder = Instance.new("Folder")
		siteFolder.Name = island
		siteFolder.Parent = folder

		-- Centred on the field, so the row sits broadside to whoever is working it
		-- however many boards the row happens to carry.
		local step = LeaderboardConfig.RowStep.Z
		local firstZ = cz + (site.along or 0) - step * (#LeaderboardConfig.Boards - 1) * 0.5

		for i, def in ipairs(LeaderboardConfig.Boards) do
			local base = Vector3.new(x, 0, firstZ + step * (i - 1))

			--[[
				STAND IT ON THE GROUND THAT IS ACTUALLY THERE.

				The sand here is terrain and terrain is not flat, so a Y baked into the
				config would bury one board and float the next. Dropped from well above
				head height and ignoring anything already built, so a board cannot come
				to rest on a deckchair. It matters more now than it did on one beach:
				the cove's left-hand line stands on ground at y 10.5 while its right is
				at 3, and neither is a number anybody typed.
			]]
			local hit = workspace:Raycast(base + Vector3.new(0, 60, 0), Vector3.new(0, -140, 0), rp)
			local groundY = hit and hit.Position.Y or 3

			local centre = Vector3.new(base.X,
				groundY + LeaderboardConfig.BoardLift + LeaderboardConfig.BoardHeight * 0.5,
				base.Z)
			local board = buildBoard(siteFolder, def, centre, facing)
			-- Carried so a warning can name WHICH money board went wrong, now that
			-- def.key alone no longer identifies one.
			board.island = island
			table.insert(built[def.key], board)
		end
		table.insert(placed, string.format("%s x=%d", island, x))
	end

	print(string.format("[Leaderboard] %d boards up -- %d rows of %d: %s",
		#LeaderboardConfig.Sites * #LeaderboardConfig.Boards,
		#LeaderboardConfig.Sites, #LeaderboardConfig.Boards, table.concat(placed, ", ")))
	return built
end

return LeaderboardBuilder
