--[[
	FerryClient  --  StarterPlayer.StarterPlayerScripts.FerryClient  (LocalScript)

	Three jobs, all of them the half of the ferry that would cost bandwidth or
	leak state if the server did it.

		the conversation   a dialogue bar along the bottom of the screen. You ask
		                   him where he sails, what he does out here and what is
		                   on the other islands, and he answers. See the long
		                   note over THE CONVERSATION for what replaced the
		                   full-screen panel that used to be here and why.
		the idle           the boat rolling on the swell and the man breathing.
		                   Anchored parts written locally, so none of it
		                   replicates -- the same trick the desert's camel walks
		                   on. Off entirely when nobody is near.
		the crossing       the dark in the middle of the voyage. The boats and
		                   the passenger are the SERVER's now; this is the cut.
		                   Timed off FerryConfig.Trip, which the server reads
		                   too, so the two agree without a handshake.

	NOTHING HERE DECIDES ANYTHING. A locked route is greyed through the same
	FerryConfig.blockedReason the server refuses with, and the row that books a
	crossing sends a destination key and nothing else. A client that edits its
	copy of the config changes what its own screen says and not one thing more.

	WHY THE REFUSAL IS SPOKEN RATHER THAN TOASTED. The player asked a man a
	question; he should answer it where they asked. A locked row clicked puts
	his own words in the speech line above -- which is also the only place the
	requirement is ever stated in a full sentence, and the reason he exists at
	all rather than a sign on a gate saying "SIFTER Lv.5 NEEDED".
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local FerryConfig = require(ReplicatedStorage:WaitForChild("FerryConfig"))
local PanelKit = require(Modules:WaitForChild("PanelKit"))
local ToastKit = require(Modules:WaitForChild("ToastKit"))
local AudioKit = require(Modules:WaitForChild("AudioKit"))

-- Touch targets: see the module. Substituted for MouseButton1Click/Activated so
-- a tap in the margin around a control that renders under 44px on a phone still
-- reaches the same handler. No-ops on desktop and on controls already big enough.
local TouchFit = require(Modules:WaitForChild("TouchFit"))
-- For onChanged only: this gui is absorbed by the global fit like every other,
-- but the board is the one panel that answers a short screen by getting SHORTER
-- rather than smaller, so it has to hear when the scale moves. See fitBoard.
local UiFit = require(Modules:WaitForChild("UiFit"))
-- Read for Motion.shake() alone here: this file is the single most likely place
-- in the game for a player to meet a camera moving without being asked.
local Motion = require(Modules:WaitForChild("Motion"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local C = PanelKit.C
local TRIP = FerryConfig.Trip

-- Resolved below, off ReplicatedStorage, once FerryServer has published them.
-- Everything in this file is built before that happens and guards on it, so a
-- slow server boot costs the panel a few seconds rather than the whole script.
local remotes = nil

----------------------------------------------------------------
-- THE CONVERSATION
----------------------------------------------------------------
--[[
	A DIALOGUE BAR ALONG THE BOTTOM, NOT A MODAL.

	What stood here was a 660 x 486 card in the middle of the screen over a
	dimmed backdrop, with three rows and a SAIL button on each: a shop, in other
	words, that happened to sell journeys. Standing in front of a man on a pier
	and having a storefront open over the top of him is the thing this is
	fixing. So:

	  * it sits at the BOTTOM and it is small. The pier, the boat and the man
	    you are talking to all stay on screen, which is the entire point of
	    having built him.
	  * THERE IS NO BACKDROP. Nothing is dimmed and nothing is blocked; you can
	    walk away mid-sentence and he stops talking, which is what happens when
	    you walk away from somebody.
	  * you ASK him things. Where he sails, what he does out here, what is on
	    the other islands -- and the crossings are one of the four answers
	    rather than the whole of the screen.
	  * he TYPES. One grapheme at a time through MaxVisibleGraphemes, which
	    costs one property write a frame and is most of what makes a wall of
	    text read as somebody speaking.

	NOTHING HERE DECIDES ANYTHING, and that has not changed. A locked route is
	greyed through the same FerryConfig.blockedReason the server refuses with,
	and clicking one puts HIS words in the speech line rather than popping a
	toast -- the player asked a man a question and he should answer it where
	they asked. The SAIL click sends a destination key and nothing else.
]]
--[[
	THE BOARD.

	A destination board, and the shape of it is deliberate: every shore is a
	PICTURE of itself, big enough to recognise from across the screen, with its
	name on it and its state on it. You pick a place, not a line of text.

	WHY THE ART IS A ViewportFrame AND NOT AN UPLOADED IMAGE. A photo of each
	island would be sharper and it is what a card like this usually is -- but
	the cove and the dunes are 1500 studs away and StreamingEnabled means their
	geometry does not exist on this machine most of the time, so nothing here
	can be rendered from the real world on demand. These are small purpose-built
	dioramas instead: twenty-odd parts apiece, built once at boot, living inside
	the viewport and owing nothing to what has streamed in. They also cannot go
	stale the way a screenshot does when somebody moves a pyramid.

	ONE CARD PER PORT, BUILT ONCE. FerryConfig.Ports is static, so card i always
	shows Ports[i] and drawing the panel only ever moves state -- the stroke,
	the dim and the pill. Rebuilding art per open would throw away twenty parts
	and a camera three times a session for no reason.

	ZIndexBehavior IS GLOBAL on this ScreenGui, which means ZIndex does NOT nest
	-- a parent with a higher number draws over its own children. Every layer
	below therefore carries an explicit, increasing ZIndex, and the rotated
	banner sits OUTSIDE the panel rather than inside it, because a rotated child
	is ignored by ClipsDescendants and would be sheared off at the corner.
]]
local BOARD      = Color3.fromRGB(28, 30, 44)
local BOARD_DEEP = Color3.fromRGB(18, 19, 30)
local BOARD_EDGE = Color3.fromRGB(9, 10, 17)
local PILL       = Color3.fromRGB(20, 22, 32)
local TEAL       = Color3.fromRGB(104, 232, 214)
local TEAL_DEEP  = Color3.fromRGB(46, 182, 172)
local GO         = Color3.fromRGB(130, 228, 100)
local GO_DEEP    = Color3.fromRGB(72, 168, 58)
local DIM        = Color3.fromRGB(146, 152, 170)
local RED        = Color3.fromRGB(236, 66, 66)
local RED_DEEP   = Color3.fromRGB(168, 30, 30)
local INK        = Color3.fromRGB(255, 255, 255)
local CREAM      = Color3.fromRGB(252, 242, 216)
local CREAM_DEEP = Color3.fromRGB(238, 220, 182)
local BROWN      = Color3.fromRGB(92, 62, 42)

local PORTS = FerryConfig.Ports
local N = #PORTS

local CARD_W = 660
local PAD = 16
-- 92, DOWN FROM 118, THE DAY THE FIFTH PORT ARRIVED. CARD_H is a sum over N
-- cards, and at five of them 118 came to 800 px against UiFit's 720-px frame
-- -- the board ran off the top and bottom of every 16:9 screen, and UiFit
-- scales by viewport ratio, it never shrinks a panel to fit. 92 keeps five
-- cards at 670, exactly the height four used to be. The photo band maths is
-- fractional and follows; nothing else reads this number.
local SHOT_H = 92                      -- one destination card
local SHOT_GAP = 12
local BAR_H = 78                       -- the ferryman's speech bubble along the bottom
local TOP_IN = 56                      -- clear air under the banner's overhang
local LIST_W = CARD_W - PAD * 2
local CARD_H = TOP_IN + N * SHOT_H + (N - 1) * SHOT_GAP + SHOT_GAP + BAR_H + PAD

--[[
	THE BOARD SHRINKS AND THE LIST SCROLLS.  2026-09-12

	The note on SHOT_H above ends "UiFit scales by viewport ratio, it never
	shrinks a panel to fit", and dropping 118 to 92 was the hand-fix for that the
	day a fifth port arrived. It bought exactly one port of headroom. Reported
	again from a 750x390 phone as "The ui is off the screen": at that viewport a
	centred panel gets a 553-tall canvas and this board is 670, so it hung 58 off
	the top and 48 off the bottom -- the banner and the ferryman both.

	SHRINKING IT IS THE WRONG ANSWER HERE, AND THAT IS WHY THIS IS NOT JUST A
	SCALE. Squeezing the whole board to ~0.825 of an already-0.6 scale is right
	for a panel whose contents are a fixed tableau. This board is a LIST: it can
	give up height without giving up legibility, and shrinking it would make five
	ports unreadable to save scrolling past two.

	So the board takes whatever height it is allowed, and the cards scroll inside
	it at full size. Nothing changes on a screen that already fits -- the list is
	exactly tall enough for all five and never scrolls.

	(This note used to end by naming UiFit.clampPanel as the thing the board
	deliberately opted out of. That function was deleted on 2026-09-18 after it
	turned out never to have applied to any panel at all -- see UiFit's tombstone
	-- so there is nothing left to opt out of. The reasoning above is unchanged
	and is still why this board scrolls rather than scales: PanelKit.card's own
	SafeFit will shrink it if the screen is genuinely too short, and the scroll
	is what keeps that from being the first thing that happens.)

	LIST_BOTTOM is derived rather than typed so it stays exact: the bar is anchored
	to the bottom at PAD + 5 and stands BAR_H tall, and SHOT_GAP is the air above
	it. Subtracting TOP_IN and this from CARD_H leaves precisely the 508 the five
	cards need, which is the arithmetic CARD_H is built from one line up.
]]
local LIST_H = N * SHOT_H + (N - 1) * SHOT_GAP
local LIST_BOTTOM = SHOT_GAP + BAR_H + PAD
-- The slab sits 7 below its holder (see THE CARDS), so the last one reaches
-- 7 past the list's own height and the canvas has to cover it.
local LIST_CANVAS = LIST_H + 7
-- Never squeeze below two cards' worth of list; past that the panel has stopped
-- being a chooser. Nothing shipping is this short -- it is a floor, not a target.
local MIN_BOARD_H = TOP_IN + (SHOT_H * 2 + SHOT_GAP) + LIST_BOTTOM

----------------------------------------------------------------
-- little builders, all explicit so the dark palette is not fighting PanelKit's
----------------------------------------------------------------
local function corner(o, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = o
	return c
end

local function stroke(o, thickness, colour, transparency)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = colour
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = o
	return s
end

local function txt(parent, str, size, font, colour, z)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = str
	l.Font = font
	l.TextSize = size
	l.TextColor3 = colour
	l.ZIndex = z
	l.Parent = parent
	return l
end

-- The chunky cartoon outline every label in this game wears.
local function punch(label, thickness)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or 2
	s.Color = Color3.fromRGB(12, 12, 20)
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = label
	return s
end

--[[
	THE SLAB, and it is most of what makes this kit look drawn rather than
	styled. A widget with a darker copy of itself sitting a few pixels below it
	reads as a thick object with a side to it -- the same trick PanelKit.chunky
	uses on every button in the game, which is why these now sit next to the
	game's own HUD without looking imported.

	It is a CHILD with Size (1, 0, 1, 0) rather than a sibling, so it tracks the
	widget automatically -- including widgets on AutomaticSize, whose size is not
	knowable at build time. Under ZIndexBehavior.Global a child with a lower
	ZIndex draws BENEATH its parent, which is exactly what a slab wants and would
	be impossible under the default Sibling behaviour.

	It must never be given to a widget with ClipsDescendants: the offset is the
	whole point and clipping eats it.
]]
local function slab(widget, dy, colour, z, radius)
	local s = Instance.new("Frame")
	s.Name = "Slab"
	s.Size = UDim2.new(1, 0, 1, 0)
	s.Position = UDim2.fromOffset(0, dy)
	s.BackgroundColor3 = colour
	s.BorderSizePixel = 0
	s.ZIndex = z
	s.Parent = widget
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = s
	return s
end

-- A soft highlight across the top half. Cheap, and it is the difference between
-- a coloured rectangle and something with a curved surface catching the light.
local function gloss(widget, z, strength)
	local g = Instance.new("Frame")
	g.Name = "Gloss"
	g.Size = UDim2.new(1, -8, 0.45, 0)
	g.Position = UDim2.fromOffset(4, 3)
	g.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	g.BackgroundTransparency = strength or 0.72
	g.BorderSizePixel = 0
	g.ZIndex = z
	g.Parent = widget
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 8)
	c.Parent = g
	return g
end

local function grad(o, a, b, rot)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(a, b)
	g.Rotation = rot or 90
	g.Parent = o
	return g
end

----------------------------------------------------------------
-- THE SCREEN
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "FerryTalk"
gui.ResetOnSpawn = false
gui.Enabled = false
gui.DisplayOrder = 50
gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
gui.Parent = playerGui

-- Transparent, and NOT clipped: the banner and the close button both overhang
-- the board's corners and a clipping root would shave them off.
local card = Instance.new("Frame")
card.Name = "Board"
card.AnchorPoint = Vector2.new(0.5, 0.5)
card.Position = UDim2.new(0.5, 0, 0.5, -10)
card.Size = UDim2.fromOffset(CARD_W, CARD_H)
card.BackgroundTransparency = 1
card.Parent = gui

--[[
	TAGGED BY HAND, BECAUSE THIS BOARD IS NOT A PanelKit.card.

	PanelWatch frees the pointer whenever a tagged root is Visible under an
	Enabled ScreenGui -- which is what lets a player in SHIFT LOCK or first
	person move a cursor at all, since the camera pins it to the middle of the
	screen and rewrites MouseBehavior every frame. Every other panel in the game
	gets that tag for free from PanelKit.card. This board is hand-built, so it
	never got one, and PanelWatch has never once fired for the ferry.

	WHAT THAT COST, reported 2026-09-22 from a 2048x1152 desktop:
		"je ne peux choisir qu'une destination au niveau du bateau, la souris ne
		 bouge pas dans l'interface"
	-- one destination selectable, and the mouse will not move. Exactly right:
	the cursor was frozen at the centre of the screen, so the only card that
	could ever be clicked was whichever one happened to sit under it.

	PanelWatch was already written for this panel's shape. Its open test ANDs
	root.Visible with screen.Enabled precisely because, as PanelKit's own Tag
	note says, "the car spawner and the ferry dialogue leave the root Visible
	forever and toggle the ScreenGui instead" -- and FerryTransit is in its
	IGNORE list while FerryTalk deliberately is not. Every part of the mechanism
	expected this board to be tagged. Nothing ever tagged it.
]]
CollectionService:AddTag(card, PanelKit.Tag)

--[[
	WHERE THE CARDS LIVE NOW. See the LIST_BOTTOM note up top.

	Height is SCALE-based on purpose -- 1 minus the two fixed insets -- so it
	tracks whatever height fitBoard lands on without being told. The cards inside
	are offset-positioned and keep their size whatever happens to the board.

	ScrollingFrame clips its descendants by default, which is what keeps a card
	from drawing over the ferryman when the list is longer than the room.
]]
local list = Instance.new("ScrollingFrame")
list.Name = "Ports"
list.Position = UDim2.fromOffset(PAD, TOP_IN)
list.Size = UDim2.new(0, LIST_W, 1, -(TOP_IN + LIST_BOTTOM))
list.BackgroundTransparency = 1
list.BorderSizePixel = 0
list.CanvasSize = UDim2.fromOffset(0, LIST_CANVAS)
list.ScrollingDirection = Enum.ScrollingDirection.Y
list.ScrollBarThickness = 6
list.ScrollBarImageColor3 = TEAL
list.ZIndex = 11
list.Parent = card

--[[
	HOW TALL THE BOARD IS ALLOWED TO BE, RIGHT NOW.

	The FitRoot is sized 1/scale, so its AbsoluteSize is already in the same
	design units CARD_H is written in -- no conversion, and it is the number that
	actually accounts for the topbar this gui does not ignore. Before UiFit has
	absorbed us the parent is the ScreenGui, which is not a GuiObject and has no
	AbsoluteSize; fall back to the natural height and let onChanged correct it.

	The 12 is a margin so the board never sits edge-to-edge against the screen.
]]
local function boardHeight(): number
	local root = card.Parent
	if not (root and root:IsA("GuiObject")) or root.AbsoluteSize.Y <= 0 then
		return CARD_H
	end
	return math.clamp(root.AbsoluteSize.Y - 12, MIN_BOARD_H, CARD_H)
end

local function fitBoard()
	card.Size = UDim2.fromOffset(CARD_W, boardHeight())
end

--[[
	RE-FIT ON THE SCALE *AND* ON THE ROOM, because they are not the same event.

	onChanged fires when the global scale moves, which covers the user's HUD Size
	setting. It does NOT cover a viewport change that leaves the scale where it
	was -- and scaleFor spends most of its range pinned against MIN_SCALE or
	MAX_SCALE, so that is the common case rather than the exotic one. The FitRoot
	is sized 1/scale of the ScreenGui, so its AbsoluteSize follows the viewport
	either way; watching the size itself is what actually catches both.

	Measured in Play before this went in: the board fitted itself to a 600-tall
	root, the window became 239 tall, the scale never moved, and the board kept
	the height it had chosen for a screen that was no longer there.

	RE-BOUND WHEN THE PARENT CHANGES, because the root this measures against is
	not the one it starts under: UiFit absorbs the board into a FitRoot a frame
	after it is built. Same shape as MenuHud's watchJump, and safe to run twice --
	fitBoard is stateless and a second pass over the same inputs writes the same
	answer.
]]
local watchedRoot
local function watchRoom()
	local root = card.Parent
	if root ~= watchedRoot and root and root:IsA("GuiObject") then
		watchedRoot = root
		root:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitBoard)
	end
	fitBoard()
end

UiFit.onChanged(function()
	task.defer(watchRoom)
end)
card:GetPropertyChangedSignal("Parent"):Connect(function()
	task.defer(watchRoom)
end)
task.defer(watchRoom)

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.fromScale(1, 1)
panel.BackgroundColor3 = BOARD
panel.BorderSizePixel = 0
panel.ZIndex = 10
panel.Parent = card
corner(panel, 24)
stroke(panel, 4, BOARD_EDGE)
grad(panel, BOARD, BOARD_DEEP)

----------------------------------------------------------------
-- THE BANNER
--
-- Rotated, so it has to live outside anything that clips -- see the header.
-- It overhangs the top-left corner rather than sitting inside the padding,
-- which is what makes it read as a ribbon pinned to the board instead of a
-- title bar.
----------------------------------------------------------------
local banner = Instance.new("Frame")
banner.Name = "Banner"
banner.AnchorPoint = Vector2.new(0, 0.5)
banner.Position = UDim2.new(0, -10, 0, 8)
banner.Size = UDim2.fromOffset(348, 74)
banner.BackgroundColor3 = TEAL
banner.BorderSizePixel = 0
banner.Rotation = -4.5
banner.ZIndex = 40
banner.Parent = card
corner(banner, 16)
stroke(banner, 5, BOARD_EDGE)
grad(banner, TEAL, TEAL_DEEP)
slab(banner, 7, Color3.fromRGB(24, 118, 116), 39, 16)
gloss(banner, 40.5, 0.78)

local bannerText = txt(banner, "TELEPORT", 42, Enum.Font.LuckiestGuy, INK, 41)
bannerText.Size = UDim2.fromScale(1, 1)
punch(bannerText, 4)

----------------------------------------------------------------
-- THE CLOSE BUTTON
----------------------------------------------------------------
local closeBtn = Instance.new("TextButton")
closeBtn.Name = "Close"
closeBtn.AnchorPoint = Vector2.new(1, 0)
closeBtn.Position = UDim2.new(1, 10, 0, -10)
closeBtn.Size = UDim2.fromOffset(54, 54)
closeBtn.BackgroundColor3 = RED
closeBtn.AutoButtonColor = false
closeBtn.Text = ""
closeBtn.BorderSizePixel = 0
closeBtn.ZIndex = 42
closeBtn.Parent = card
corner(closeBtn, 16)
stroke(closeBtn, 5, BOARD_EDGE)
grad(closeBtn, RED, RED_DEEP)
slab(closeBtn, 6, Color3.fromRGB(122, 18, 18), 41, 16)
gloss(closeBtn, 42.5, 0.76)
local closeX = txt(closeBtn, "\u{00D7}", 36, Enum.Font.LuckiestGuy, INK, 43)
closeX.Size = UDim2.fromScale(1, 1)
punch(closeX, 4)

----------------------------------------------------------------
-- THE DIORAMAS
--
-- REAL ART, NOT PRIMITIVES. The first pass built these out of boxes and balls
-- and they read as exactly that -- a stack of blocks standing in for a tree.
-- ReplicatedStorage.FerryArt carries mesh copies of the props the islands are
-- actually dressed with (the toolbox sakura, the torii, the palms, an
-- umbrella), stripped of collision and scripts, and the scenes are composed out
-- of those. The remaining primitives are only ever LANDFORM -- sea, sand,
-- headlands -- where a big flattened ball reads as a soft dune and a box does
-- not.
--
-- WHY IT IS SAFE TO CLONE THESE ON THE CLIENT. FerryArt is in
-- ReplicatedStorage, so it exists on every machine from join, which is the
-- whole reason the art was copied out of ServerStorage: StreamingEnabled means
-- the real islands are absent most of the time and nothing here may depend on
-- them having streamed in.
--
-- A WorldModel rather than parts parented straight to the viewport: without one
-- a ViewportFrame lights its contents flatly and every scene comes out muddy.
----------------------------------------------------------------
local ART = ReplicatedStorage:FindFirstChild("FerryArt")

--[[
	TEXTURED BY DEFAULT, AND THAT IS MOST OF THE "QUALITY".

	Every part in these dioramas was SmoothPlastic, which is the one material
	with no surface detail whatsoever. At card size a plastic sea, plastic
	dunes and a plastic mountain is precisely what reads as cheap -- the shapes
	were fine, the surfaces were vinyl. Sand carries grain, Slate and Sandstone
	carry rock, and a ViewportFrame renders all three. The caller passes a
	material where it wants something else; landform gets Sand for free.
]]
local function vp(parent, size, cf, colour, shape, mat)
	local p = Instance.new("Part")
	p.Size = size
	p.CFrame = cf
	p.Color = colour
	p.Material = mat or Enum.Material.Sand
	p.Anchored = true
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if shape then
		p.Shape = shape
	end
	p.Parent = parent
	return p
end

local SMOOTH = Enum.Material.SmoothPlastic
local SLATE = Enum.Material.Slate
local SANDSTONE = Enum.Material.Sandstone

--[[
	A CONTACT SHADOW.

	A ViewportFrame casts none -- CastShadow is meaningless in one -- so every
	prop in these scenes was standing on the sand with no join at all, which is
	the other half of why they looked pasted on. A flattened dark ellipsoid laid
	a hair above the ground under each one costs a part and does the whole job:
	the eye reads contact, not geometry.
]]
local function shadow(world, x, z, rx, rz)
	local p = vp(world, Vector3.new(rx, 0.4, rz or rx), CFrame.new(x, 0.06, z),
		Color3.fromRGB(46, 38, 34), Enum.PartType.Ball, SMOOTH)
	p.Transparency = 0.62
	return p
end

local BALL = Enum.PartType.Ball

--[[
	Drop a piece of FerryArt into a scene, standing on the ground.

	SCALE FIRST, THEN SEAT IT. The models are authored at world scale (the
	sakura is 38 studs tall) and these scenes are about 40 across, so everything
	is scaled on the way in -- and a bounding box measured before the scale is
	the wrong height to sit it on. Measured after, then lifted by its own half
	height, every prop stands ON the sand instead of half through it whatever
	scale it is given.

	Yaw is applied through PivotTo rather than baked, so the same template can
	face a different way in each card and none of them look cloned.
]]
local function drop(world, name, x, z, scale, yaw, tilt)
	if not ART then
		return nil
	end
	local template = ART:FindFirstChild(name)
	if not template then
		return nil
	end
	local m = template:Clone()
	m:ScaleTo(scale or 1)
	m.Parent = world
	m:PivotTo(CFrame.new(x, 0, z) * CFrame.Angles(0, yaw or 0, tilt or 0))
	local cf, size = m:GetBoundingBox()
	-- lift so the lowest point of the box rests on y = 0
	m:PivotTo(m:GetPivot() + Vector3.new(0, size.Y * 0.5 - cf.Position.Y, 0))
	-- and lay a contact shadow under it, sized off its own footprint. Done here
	-- rather than at every call site so nothing can be added to a scene later
	-- and float.
	if z > -34 then
		shadow(world, x, z, math.max(3, size.X * 0.62), math.max(3, size.Z * 0.62))
	end
	return m
end

--[[
	THREE PLANES, AND THEIR TOP FACES MUST NOT BE EQUAL.

	Sea, wet sand and dry sand overlap, so coplanar tops z-fight into a
	flickering stripe the length of the card. They are staggered by a tenth of a
	stud each -- invisible at this framing, decisive to the renderer.

	The DRY SAND is the one sitting at exactly y = 0, because `drop` seats every
	prop on that plane. Move it and every tree in every scene floats or sinks.
]]
local function shore(world, seaC, wetC, sandC, foamZ, foamC)
	-- The sea stays smooth: it is the one surface that should not have grain on
	-- it, and a textured one at this size reads as gravel.
	vp(world, Vector3.new(400, 6, 300), CFrame.new(0, -3.15, -150), seaC, nil, SMOOTH) -- top -0.15
	-- A deeper band further out, so the water has some distance in it rather
	-- than being one flat colour to the horizon.
	local deep = vp(world, Vector3.new(400, 6, 150), CFrame.new(0, -3.1, -216),
		seaC:Lerp(Color3.fromRGB(10, 46, 84), 0.42), nil, SMOOTH)               -- top -0.10
	deep.Transparency = 0.12
	vp(world, Vector3.new(400, 6.4, 64), CFrame.new(0, -3.25, foamZ - 26), wetC)  -- top -0.05
	vp(world, Vector3.new(400, 7, 200), CFrame.new(0, -3.5, foamZ + 96), sandC)   -- top  0.00

	--[[
		THE FOAM LINE. Sea met sand on a hard colour boundary the width of the
		card -- the one edge in the picture the eye goes straight to, and it was
		the only one with no detail on it. Two thin bands, the front one broken
		into laps, so the waterline reads as water arriving rather than as two
		rectangles meeting.
	]]
	--[[
		FAINT, AND NOT WHITE. At 0.16 opaque white this was a painted line down
		the middle of every card -- a road marking, not surf. Surf is mostly the
		COLOUR UNDER IT with a little brightness on top, so the default foam is
		the wet sand lifted toward white rather than white itself, and the laps
		are wide and soft enough that the eye reads a ragged edge instead of a
		ruled one. Ashfall passes its own, because white surf on a black beach is
		the brightest thing in a card whose subject is a mountain.
	]]
	local fc = foamC or wetC:Lerp(Color3.fromRGB(255, 255, 255), 0.72)
	local f = vp(world, Vector3.new(400, 6.5, 2.2), CFrame.new(0, -3.2, foamZ - 3),
		fc, nil, SMOOTH)                                                        -- top 0.05
	f.Transparency = 0.52
	for i = -9, 9 do
		local lap = vp(world, Vector3.new(30 + (i % 4) * 12, 6.6, 7 + (i % 3) * 4),
			CFrame.new(i * 23 + (i % 2) * 9, -3.2, foamZ + 1 + (i % 3) * 1.6),
			fc, Enum.PartType.Ball, SMOOTH)
		lap.Transparency = 0.62 + (i % 3) * 0.07
	end
end

local SCENES = {}

--[[
	EVERYTHING BELOW IS SIZED AGAINST THE FRAME, and the frame is not generous.

	The camera is fixed for all four cards -- (-11, 12.5, 43) looking at
	(0, 6.5, -13) at a VERTICAL FOV of 25 -- so the visible band of world is a
	function of depth, and it is narrow:

		z =  20    y   4.8 .. 15.3
		z =   6    y   0.1 .. 16.9
		z = -14    y  -6.6 .. 19.3
		z = -30    y -11.9 .. 21.3
		z = -58    y -21.3 .. 24.6

	Three of the four scenes were built without that table and all three lost
	their subject out of the top of the card: the palms (22.2 tall unscaled) at
	scale 0.95 stood 21 studs at z = 6 against a ceiling of 16.9, the pyramid's
	capstone reached 30 at z = -14 against 19.3, and Ashfall's summit reached 35
	at z = -58 against 24.6. Every height below is checked against this table.
	If you move a prop toward the camera, it must get SHORTER.
]]

--[[
	A CACTUS, BUILT RATHER THAN DROPPED. FerryArt carries no cactus and the
	dunes are covered in them -- a desert card without one is a beach that has
	lost its sea. Trunk, two arms, rounded ends: the same silhouette Island2's
	own scatter has.
]]
local function cactus(w, x, z, h, yaw)
	local G = Color3.fromRGB(78, 152, 98)
	local GD = Color3.fromRGB(60, 126, 80)
	local base = CFrame.new(x, 0, z) * CFrame.Angles(0, yaw or 0, 0)
	vp(w, Vector3.new(2.0, h, 2.0), base * CFrame.new(0, h * 0.5, 0), G)
	vp(w, Vector3.new(2.0, 2.0, 2.0), base * CFrame.new(0, h, 0), G, BALL)
	for _, s in ipairs({ -1, 1 }) do
		local ay = h * (s < 0 and 0.5 or 0.64)
		local al = h * 0.28
		vp(w, Vector3.new(al, 1.4, 1.4), base * CFrame.new(s * al * 0.5, ay, 0), GD)
		vp(w, Vector3.new(1.4, al * 0.85, 1.4), base * CFrame.new(s * al, ay + al * 0.42, 0), G)
		vp(w, Vector3.new(1.4, 1.4, 1.4), base * CFrame.new(s * al, ay + al * 0.85, 0), G, BALL)
	end
end

-- A neon slab running between two points, for lava. CFrame.lookAt puts -Z on
-- the far end, so a part sized along Z spans exactly from a to b.
local function streak(w, a, b, wide, colour)
	local p = vp(w, Vector3.new(wide, 1.2, (b - a).Magnitude), CFrame.lookAt((a + b) * 0.5, b), colour)
	p.Material = Enum.Material.Neon
	return p
end

function SCENES.Beach(w)
	shore(w, Color3.fromRGB(52, 186, 226), Color3.fromRGB(142, 224, 232),
		Color3.fromRGB(246, 222, 164), -6)
	-- headlands closing both sides, so the card has a foreground and a distance
	vp(w, Vector3.new(58, 26, 46), CFrame.new(-46, -4, -18), Color3.fromRGB(234, 208, 152), BALL)
	vp(w, Vector3.new(44, 20, 38), CFrame.new(52, -4, -26), Color3.fromRGB(238, 212, 156), BALL)

	-- Palms scaled to the ceiling at their own depth: 0.7 is 15.5 studs, which
	-- clears at z = 6 (16.9) with a little air. They were 0.95 and lost their
	-- crowns off the top of the card.
	drop(w, "Palm", -22, 4, 0.70, 0.7)
	drop(w, "Palm", -11, 15, 0.56, 2.4)
	drop(w, "Palm", 25, 8, 0.66, 4.1)
	drop(w, "Palm", 37, 18, 0.48, 1.2)
	drop(w, "UmbrellaWide", 5, 2, 0.85, 0.5)
	drop(w, "UmbrellaWide", -15, 10, 0.62, 2.6)
	drop(w, "Deckchair", 13, 5, 1.4, 2.2)
	drop(w, "Deckchair", -20, 8, 1.1, 5.1)
	drop(w, "FloatieFlamingo", 28, -13, 1.2, 1.6)
	drop(w, "Rock", -31, -6, 3.6, 0.4)
	drop(w, "Rock", 30, -4, 2.8, 1.9)
	drop(w, "Rock", 18, -11, 2.0, 3.0)
end

function SCENES.Dunes(w)
	shore(w, Color3.fromRGB(66, 184, 212), Color3.fromRGB(228, 202, 150),
		Color3.fromRGB(234, 186, 114), -10)

	--[[
		THE PYRAMID, MOVED BACK AND DRESSED.

		It stood at z = -14 in seven 3.9 courses, so its capstone reached y 30
		against a ceiling of 19.3 -- the top third of the island's one landmark
		was outside the card. At z = -30 the ceiling is 21.3, and six 2.9
		courses put the capstone at 19.4.

		And it was seven bare tan boxes. The real one carries a blue door under
		a pale lintel, red-blue-teal banding either side and a gold capstone,
		and those four colours are most of why it reads as the Dunes rather
		than as a generic pyramid.
	]]
	local base, top, courses, ch = 36, 6, 6, 2.9
	local STONE = Color3.fromRGB(234, 194, 132)
	local STONE_D = Color3.fromRGB(216, 172, 112)
	for k = 0, courses - 1 do
		local wid = base + (top - base) * (k / courses)
		vp(w, Vector3.new(wid, ch, wid), CFrame.new(0, ch * 0.5 + k * ch, -30),
			(k % 2 == 0) and STONE or STONE_D, nil, SANDSTONE)
	end
	vp(w, Vector3.new(5.5, 3.2, 5.5), CFrame.new(0, courses * ch + 1.6, -30),
		Color3.fromRGB(255, 216, 92))

	-- The front face of the base course sits at z = -30 + 36/2 = -12.
	local F = -11.9
	vp(w, Vector3.new(11.0, 11.5, 0.5), CFrame.new(0, 5.4, F), Color3.fromRGB(246, 228, 182))
	vp(w, Vector3.new(7.6, 9.6, 0.5), CFrame.new(0, 4.8, F + 0.25), Color3.fromRGB(44, 74, 142))
	vp(w, Vector3.new(7.6, 1.0, 0.5), CFrame.new(0, 9.9, F + 0.45), Color3.fromRGB(255, 216, 92))
	for _, s in ipairs({ -1, 1 }) do
		vp(w, Vector3.new(3.0, 1.3, 0.5), CFrame.new(s * 9.0, 7.0, F), Color3.fromRGB(200, 72, 56))
		vp(w, Vector3.new(3.0, 1.3, 0.5), CFrame.new(s * 9.0, 4.6, F), Color3.fromRGB(58, 112, 182))
		vp(w, Vector3.new(3.0, 1.3, 0.5), CFrame.new(s * 9.0, 2.2, F), Color3.fromRGB(62, 178, 170))
	end

	-- The obelisk, the island's other landmark. 15 tall at z = -6, ceiling 17.
	vp(w, Vector3.new(2.9, 1.0, 2.9), CFrame.new(-26, 0.5, -6), STONE_D)
	vp(w, Vector3.new(2.2, 13.5, 2.2), CFrame.new(-26, 7.7, -6), STONE)
	vp(w, Vector3.new(1.4, 2.2, 1.4), CFrame.new(-26, 15.5, -6), Color3.fromRGB(255, 216, 92), BALL)

	for _, d in ipairs({ { -54, -6, 17 }, { 56, -12, 15 }, { -34, 14, 10 }, { 36, 17, 9 }, { 10, 27, 7 } }) do
		vp(w, Vector3.new(d[3] * 3.1, d[3] * 1.15, d[3] * 2.3),
			CFrame.new(d[1], -1.5, d[2]), Color3.fromRGB(228, 178, 110), BALL)
	end
	cactus(w, 17, 7, 7.0, 0.4)
	cactus(w, 26, 15, 5.0, 2.1)
	cactus(w, -15, 13, 5.8, 4.0)
	cactus(w, 35, 3, 4.2, 1.2)
	cactus(w, -32, 20, 4.0, 5.5)
	drop(w, "Palm", -31, 17, 0.5, 1.1)
	drop(w, "Rock", 23, 1, 3.0, 0.9)
	drop(w, "Rock", -19, 4, 2.2, 2.6)
	drop(w, "Rock", 31, 12, 1.8, 1.4)
end

function SCENES.Cove(w)
	--[[
		PALER SAND. It was (228,140,156) -- a hot magenta -- so at card size the
		whole scene went one flat pink and the trees, the lanterns and the gate
		all sank into it. The real cove is pink-GREY: blossom over pale stone.
		The sand is the background here, not the subject.
	]]
	-- Warmer than the last pass. Dropping the ambient from 198 to 146 took the
	-- pink out of the pink-grey and left it simply grey; the sand is lifted to
	-- compensate so it is lit blossom rather than wet slate.
	shore(w, Color3.fromRGB(108, 212, 222), Color3.fromRGB(250, 226, 222),
		Color3.fromRGB(246, 214, 208), -8)
	vp(w, Vector3.new(50, 22, 40), CFrame.new(-48, -4, -20), Color3.fromRGB(236, 200, 202), BALL)
	vp(w, Vector3.new(40, 18, 34), CFrame.new(50, -4, -24), Color3.fromRGB(240, 206, 206), BALL)

	--[[
		THE TORII STANDS IN THE WATER, which is the whole reason this card is
		recognisable at a glance. Pink sand at this size is a colour; the gate is
		a shape nothing else in the game has.

		0.55 puts it at 19 studs at z = -30, where the ceiling is 21.3.
	]]
	local torii = drop(w, "Torii", -3, -30, 0.55, 0.06)
	if torii then
		torii:PivotTo(torii:GetPivot() - Vector3.new(0, 1.4, 0))
	end

	-- SakuraTree is 37.7 unscaled; 0.42 is 15.8, which clears at z = 8 (17.1).
	drop(w, "SakuraTree", -28, 8, 0.42, 0.8)
	drop(w, "SakuraTree", 30, 12, 0.38, 3.4)
	drop(w, "SakuraTreeWide", 18, 21, 1.05, 1.7)
	drop(w, "SakuraTreeWide", -18, 25, 0.9, 4.6)
	-- Stone lanterns only. PaperLantern is a HANGING prop -- it is authored to
	-- swing from an eave -- so seated on the sand by `drop` it is a red box
	-- floating at head height with nothing above it.
	drop(w, "StoneLantern", 8, 5, 1.2, 0.4)
	drop(w, "StoneLantern", -12, 11, 0.95, 2.3)
	drop(w, "FloatieFlamingo", 20, -11, 1.6, 2.1)
	drop(w, "FloatieFlamingo", -17, -15, 1.3, 5.0)
	drop(w, "Rock", -33, -4, 3.4, 1.3)
	drop(w, "Rock", 33, -7, 2.6, 2.8)
end

--[[
	ASHFALL, and it was the card that was actually broken rather than merely
	plain. Three separate faults, all of which made it a dark grey mound:

	  THE CRATER WAS INSIDE THE MOUNTAIN. The neon lake sat at y 34 with a
	  height of 4, and the top course spanned y 21..35 -- so the one bright
	  thing in the scene was buried in the rock around it.

	  BOTH LAVA FLOWS WERE INSIDE IT TOO, at z = -46 against a cone whose front
	  face at that height is z = -31. Not dimmed, not subtle: not drawn.

	  AND THE SUMMIT WAS OUT OF FRAME. y 35 at z = -58, ceiling 24.6.

	So the cone is rebuilt shorter (summit 21), the crater sits ON it, and the
	flows are laid roughly four studs PROUD of the silhouette all the way down,
	which is what puts them in front of the rock instead of in it. The greys
	are all lifted a shade as well -- black sand under an ash sky needs some
	value in it or the whole card is one shape.
]]
function SCENES.Ashfall(w)
	-- Its own foam, a dim ash grey: the default lifts the wet sand 72% toward
	-- white, which on a black beach is the brightest thing in a card whose
	-- subject is a mountain.
	shore(w, Color3.fromRGB(52, 128, 156), Color3.fromRGB(86, 78, 84),
		Color3.fromRGB(72, 65, 70), -6, Color3.fromRGB(150, 146, 150))
	vp(w, Vector3.new(56, 24, 44), CFrame.new(-50, -4, -18), Color3.fromRGB(88, 80, 88), BALL)
	vp(w, Vector3.new(46, 20, 36), CFrame.new(52, -4, -24), Color3.fromRGB(92, 84, 92), BALL)

	-- The cone. Four courses, each narrower and a shade warmer than the last.
	-- Summit at y 21 against a ceiling of 24.6 at this depth.
	local course = {
		{ r = 92, h = 18, y = -2, c = Color3.fromRGB(76, 68, 76) },
		{ r = 66, h = 16, y = 5,  c = Color3.fromRGB(88, 78, 86) },
		{ r = 42, h = 14, y = 11, c = Color3.fromRGB(100, 76, 72) },
		{ r = 26, h = 12, y = 16, c = Color3.fromRGB(120, 70, 56) },
	}
	for _, k in ipairs(course) do
		vp(w, Vector3.new(k.r, k.h, k.r * 0.8), CFrame.new(0, k.y, -58), k.c, BALL, SLATE)
	end

	--[[
		THE CRATER IS A PIT, NOT A LAMP.

		The first pass put a 15-wide neon lake with a 23-wide neon halo on top of
		the summit, and at card size that is a bright orange dish balanced on a
		mountain -- it reads as a saucer, not as a hole with fire in it. What
		sells a crater is the RIM being the widest thing and the glow sitting
		down inside it, so the dark ring is 21 across and the lake is 11, set
		low enough that the rim occludes its edge.
	]]
	vp(w, Vector3.new(21, 5, 17), CFrame.new(0, 20.2, -58), Color3.fromRGB(56, 44, 44), BALL)
	local lake = vp(w, Vector3.new(11, 2.6, 9), CFrame.new(0, 21.4, -58),
		Color3.fromRGB(246, 118, 40), BALL)
	lake.Material = Enum.Material.Neon
	local halo = vp(w, Vector3.new(15, 1.8, 12), CFrame.new(0, 21.7, -58),
		Color3.fromRGB(255, 92, 32), BALL)
	halo.Material = Enum.Material.Neon
	halo.Transparency = 0.72

	-- Smoke, leaving the top of the card, which is where a plume should go.
	for i = 1, 3 do
		local puff = vp(w, Vector3.new(9 + i * 5, 6 + i * 3, 8 + i * 4),
			CFrame.new(i * 1.6, 25 + i * 5, -58), Color3.fromRGB(158, 152, 152), BALL)
		puff.Transparency = 0.4 + i * 0.13
	end

	--[[
		THE FLOWS, ON THE FRONT OF THE MOUNTAIN.

		The silhouette's front face runs from about z = -44 at y 18 down to
		z = -21 at y -2, so each streak is laid on that line and pushed four
		studs toward the camera. Four is enough to clear the rock at every
		height and small enough that they still read as lying on it.
	]]
	--[[
		NARROWER, DEEPER AND STOPPED SHORT.

		They were 3.0 and 2.4 wide in (255,140,48), which at Neon is essentially
		yellow -- two bright straight ribbons laid over the rock rather than
		something running down it. Cooling as they descend is what makes a flow
		read as a flow, so each is drawn in two segments: hot near the vent, dark
		red by the bottom. They stop at y 5 rather than y 1, because a flow that
		reaches the beach turns the foreground into a road sign.
	]]
	--[[
		CLEARANCE IS ABOUT ONE STUD, NOT EIGHT.

		Pushed four studs proud the streaks stopped being ON the mountain and
		floated in front of it -- two bright bars in a symmetrical V that read as
		an arrow rather than as lava. The cone is an ELLIPSOID, so a straight
		segment between two surface points dips behind the bulge in the middle;
		the z here is the surface at each height plus just enough to clear that
		sag (checked: +0.9 at the worst point of each segment).

			y 18 -> surface z -48.2      y 11 -> -40.5      y 5 -> -31.6

		And they are deliberately NOT a matched pair: one long flow to the left
		reaching the foot, a shorter one on the right that stops partway, and a
		thin cooled trickle between them.
	]]
	local HOT = Color3.fromRGB(244, 124, 44)
	local COOL = Color3.fromRGB(186, 58, 26)
	streak(w, Vector3.new(-2, 18, -46.4), Vector3.new(-6, 11, -37.5), 1.8, HOT)
	streak(w, Vector3.new(-6, 11, -37.5), Vector3.new(-11, 5, -27.6), 1.4, COOL)
	streak(w, Vector3.new(4, 17, -45.6), Vector3.new(8, 11, -37.5), 1.5, HOT)
	streak(w, Vector3.new(8, 11, -37.5), Vector3.new(10, 7.5, -32.4), 1.0, COOL)
	streak(w, Vector3.new(-5, 13, -40.0), Vector3.new(-7, 8, -33.0), 0.9, COOL)

	-- Ember cracks in the black sand, so the foreground is not a flat slab.
	for _, c in ipairs({ { -24, 8, 10, 0.5 }, { 12, 12, 8, 2.2 }, { 30, 4, 6, 4.1 }, { -6, 20, 7, 1.3 } }) do
		local p = vp(w, Vector3.new(c[3], 0.5, 1.1),
			CFrame.new(c[1], 0.1, c[2]) * CFrame.Angles(0, c[4], 0), Color3.fromRGB(226, 82, 32))
		p.Material = Enum.Material.Neon
		p.Transparency = 0.25
	end

	drop(w, "Palm", -31, 9, 0.55, 0.7)
	drop(w, "Palm", 32, 15, 0.46, 3.9)
	drop(w, "Rock", -18, 2, 3.0, 1.1)
	drop(w, "Rock", 22, -3, 2.4, 2.7)
	drop(w, "Rock", 4, 18, 1.8, 5.2)
end

--[[
	PENGUIN ISLAND, as a fallback: a frozen sea, a snowfield, a beached liner on
	the far shore and the birds that give the place its name. FerryArt carries
	nothing arctic, so it is all vp() primitives. Every height is checked against
	the band table above: the funnel top at y 17 sits at z -34 (ceiling ~21.8),
	the bergs at z -8..-20 stay under 19.

	The photo in SHOTS supersedes this whenever it is present; this is what the
	card shows the day the island is added and the capture has not been taken.
]]
function SCENES.Penguin(w)
	local SNOW = Color3.fromRGB(232, 238, 246)
	local SNOW_SHADE = Color3.fromRGB(206, 218, 232)
	local ICE = Color3.fromRGB(176, 212, 236)
	local ICE_DEEP = Color3.fromRGB(120, 168, 210)
	local HULL = Color3.fromRGB(122, 46, 40)
	local HULL_DARK = Color3.fromRGB(40, 32, 34)
	local PINE = Color3.fromRGB(46, 92, 72)
	local INK = Color3.fromRGB(30, 34, 44)
	local BELLY = Color3.fromRGB(240, 242, 246)

	-- A still, cold sea and a snow shore; the surf is barely a line of frost.
	shore(w, Color3.fromRGB(58, 112, 142), SNOW_SHADE, SNOW, -6, Color3.fromRGB(240, 246, 252))

	-- Pack ice on the water, in front of the shore line: flat slabs, not balls.
	for _, f in ipairs({ { -38, -4, 16, 0.4 }, { -14, 2, 12, 1.2 }, { 22, -6, 18, 2.6 }, { 44, 0, 11, 0.9 } }) do
		local p = vp(w, Vector3.new(f[3], 1.2, f[3] * 0.72),
			CFrame.new(f[1], -0.2, f[2]) * CFrame.Angles(0, f[4], 0), ICE)
		p.Material = Enum.Material.Ice
	end

	-- Icebergs standing off the shore, sunk so their tops stay under the band.
	vp(w, Vector3.new(40, 26, 32), CFrame.new(-48, -8, -14), ICE, BALL)
	vp(w, Vector3.new(30, 22, 26), CFrame.new(-40, -4, -8), ICE_DEEP, BALL)
	vp(w, Vector3.new(34, 24, 30), CFrame.new(50, -8, -20), ICE, BALL)

	-- The liner, beached on the far shore: a long dark hull, tilted the way a
	-- ship that ran aground and froze there would lie, a white deckhouse and
	-- two funnels with a cap of snow. The whole thing sits at z -34, where the
	-- ceiling is ~21.8; the taller funnel tops out at 17.
	local ship = CFrame.new(6, 0, -34) * CFrame.Angles(0, math.rad(-18), math.rad(6))
	vp(w, Vector3.new(58, 9, 14), ship * CFrame.new(0, 4.5, 0), HULL)
	vp(w, Vector3.new(58, 1.6, 14.6), ship * CFrame.new(0, 9.3, 0), Color3.fromRGB(230, 226, 220))
	vp(w, Vector3.new(30, 4.6, 9), ship * CFrame.new(-2, 12.3, 0), Color3.fromRGB(236, 232, 226))
	for _, fx in ipairs({ -9, 7 }) do
		vp(w, Vector3.new(4, 5.2, 4), ship * CFrame.new(fx, 14.6, 0), HULL, Enum.PartType.Cylinder)
		vp(w, Vector3.new(4.4, 1.1, 4.4), ship * CFrame.new(fx, 17.2, 0), HULL_DARK, Enum.PartType.Cylinder)
	end
	-- rust running down the plates, and snow lying along the deck edge
	vp(w, Vector3.new(58.4, 0.9, 14.4), ship * CFrame.new(0, 10.2, 0), SNOW)

	-- A stand of snow pines on the headland, each a tapered stack.
	for _, t in ipairs({ { -24, 2, 9 }, { -30, 8, 11 }, { -18, 10, 8 }, { 34, 6, 10 }, { 40, 12, 12 } }) do
		local x, z, h = t[1], t[2], t[3]
		vp(w, Vector3.new(1.2, h * 0.4, 1.2), CFrame.new(x, h * 0.2, z), Color3.fromRGB(70, 50, 36))
		for i = 0, 2 do
			local wdt = h * (0.62 - i * 0.16)
			vp(w, Vector3.new(wdt, h * 0.3, wdt), CFrame.new(x, h * (0.34 + i * 0.22), z), PINE)
			vp(w, Vector3.new(wdt * 0.9, 0.5, wdt * 0.9), CFrame.new(x, h * (0.34 + i * 0.22) + h * 0.15, z), SNOW)
		end
	end

	-- The colony: a dozen penguins down the shore, a black ball over a white
	-- one, a beak. Small, and that is the point of them.
	local seed = Random.new(818)
	for i = 1, 12 do
		local x = -26 + i * 4.4 + seed:NextNumber(-1.5, 1.5)
		local z = 2 + seed:NextNumber(-4, 8)
		vp(w, Vector3.new(1.6, 2.2, 1.6), CFrame.new(x, 1.1, z), INK, BALL)
		vp(w, Vector3.new(1.1, 1.5, 0.7), CFrame.new(x, 1.0, z - 0.55), BELLY, BALL)
		vp(w, Vector3.new(0.4, 0.3, 0.6), CFrame.new(x, 1.9, z - 0.9), Color3.fromRGB(250, 172, 52))
		shadow(w, x, z, 1.4, 1.4)
	end
end

-- Sky behind each scene. The viewport's own background, ramped, so the diorama
-- has something to be a silhouette against.
local SKY = {
	Beach = { Color3.fromRGB(126, 208, 246), Color3.fromRGB(214, 240, 252) },
	Dunes = { Color3.fromRGB(126, 196, 236), Color3.fromRGB(250, 226, 178) },
	Cove  = { Color3.fromRGB(150, 200, 240), Color3.fromRGB(255, 214, 226) },
	-- An ash sky rather than a blue one: this is the only card whose weather is
	-- part of what it is selling, and a black beach under a bright blue sky reads
	-- as a rendering fault.
	-- Lifted and warmed: the cone reads as a silhouette against this, and the
	-- old (96,104,124) was within a few values of the rock in front of it.
	Ashfall = { Color3.fromRGB(112, 118, 140), Color3.fromRGB(232, 160, 110) },
	-- A pale, cold sky with the aurora's green low on the horizon.
	Penguin = { Color3.fromRGB(150, 178, 214), Color3.fromRGB(196, 232, 226) },
}

--[[
	LIGHT, PER SHORE.

	Every card was rendered at Ambient (198,200,208) -- so bright that the
	directional light had almost nothing left to do and every form came out
	flat. A ViewportFrame has no shadows and no post, so its ambient/key ratio
	is the ONLY modelling these scenes get; at 3:1 rather than 20:1 the dunes
	have a lit face and a shaded one and the cone has a shape.

	The key is also tinted to the hour each island is meant to be at: white-gold
	on the beach, hot and low over the dunes, cool blossom light in the cove,
	and ember on Ashfall, where the mountain is the light source that matters.
]]
local LIGHT = {
	Beach   = { amb = Color3.fromRGB(124, 140, 168), key = Color3.fromRGB(255, 248, 226),
	            dir = Vector3.new(-0.42, -1, -0.36) },
	Dunes   = { amb = Color3.fromRGB(146, 128, 106), key = Color3.fromRGB(255, 238, 198),
	            dir = Vector3.new(-0.55, -1, -0.28) },
	Cove    = { amb = Color3.fromRGB(158, 144, 158), key = Color3.fromRGB(255, 246, 242),
	            dir = Vector3.new(-0.36, -1, -0.44) },
	Ashfall = { amb = Color3.fromRGB(84, 86, 108),   key = Color3.fromRGB(255, 202, 158),
	            dir = Vector3.new(-0.30, -1, -0.52) },
	-- Blue bounce off snow and a low, white sun.
	Penguin = { amb = Color3.fromRGB(128, 148, 178), key = Color3.fromRGB(255, 252, 244),
	            dir = Vector3.new(-0.50, -1, -0.30) },
}

--[[
	THE AIR: sun, cloud and haze, and all three are PARTS rather than frames.

	This ScreenGui is ZIndexBehavior.Global, so a layer slipped between the sky
	frame and the viewport is a fight nobody wins. A part at z = -250 is simply
	far away, sorts correctly against everything else in the scene for free, and
	picks up the same light.

	`haze` is the one that does the most work: a sky-coloured scrim at z = -170
	puts real aerial perspective between the far water and the near sand, which
	is the difference between a diorama with depth in it and four coloured
	stripes.
]]
--[[
	PHOTOGRAPHS OF THE ISLANDS, captured in Studio at the game's own noon and
	uploaded. `band` is where the top of the card sits as a FRACTION of the
	picture's height, so it chooses how much sky and how much sand shows and
	survives Roblox re-encoding the upload to another resolution.

		Beach    the shop row, the parasols and the palms, sea behind
		Dunes    the pyramid's blue door and the pharaoh, cacti either side
		Cove     the shrine hall on its plinth, the sando and its torii leading in
		Ashfall  the cone with its lava, the black strand and the camp

	A port with no entry here falls back to its diorama, which is why SCENES is
	still below.
]]
--[[
	EACH BAND IS SET SO THE ISLAND'S ATTRACTION IS IN FRAME, which is the whole
	point of the card and is exactly what the first cut got wrong. The card
	shows about 0.31 of the picture's height, so `band` is roughly
	(attraction's centre) - 0.15:

		Beach    0.34  the shop row and the parasols under the palms
		Dunes    0.35  the pyramid, apex to door
		Cove     0.35  the shrine hall, roof finials down to the plinth
		Ashfall  0.39  the cone, summit to foot, lava down the face

	HOW MUCH OF THE PICTURE SHOWS DEPENDS ON THE PICTURE'S SHAPE. The card is
	LIST_W x SHOT_H, so the visible slice is SHOT_H / (LIST_W / aspect): 0.31 of
	a 1758x1080 shot, but 0.38 of the cove's 1609x803 one. The shrine measures
	0.374..0.693 of its own frame, so 0.345 centres it in the slice with nine
	pixels of air above the finials and below the plinth -- the first cut framed
	it nine percent bigger and the chigi sat hard against the card's top edge.
]]
local SHOTS = {
	Beach   = { id = "rbxassetid://96383709208509",  band = 0.34 },
	Dunes   = { id = "rbxassetid://74117451179120",  band = 0.35 },
	-- `aspect` because this one was shot on a differently shaped viewport --
	-- 1609x803, not the 1758x1080 the other three came off. Without it the
	-- picture is laid in too tall and `band` indexes the wrong rows.
	Cove    = { id = "rbxassetid://121436226692660", band = 0.345, aspect = 1609 / 803 },
	Ashfall = { id = "rbxassetid://112430677799389", band = 0.39 },
	-- Shot from the east strand: the colony in the foreground, the liner and
	-- the ice cliffs behind, the aurora over it. 1920x1001, so `aspect` like
	-- the cove's; the birds and the ship sit 0.42..0.78 of the frame.
	Penguin = { id = "rbxassetid://73905884636481", band = 0.43, aspect = 1920 / 1001 },
}

local AIR = {
	Beach   = { sun = Color3.fromRGB(255, 250, 214), sunAt = Vector3.new(96, 46, 6),
	            cloud = Color3.fromRGB(255, 255, 255), haze = Color3.fromRGB(196, 232, 250) },
	Dunes   = { sun = Color3.fromRGB(255, 236, 168), sunAt = Vector3.new(-104, 40, 8),
	            cloud = Color3.fromRGB(255, 246, 226), haze = Color3.fromRGB(238, 216, 172) },
	Cove    = { sun = Color3.fromRGB(255, 236, 240), sunAt = Vector3.new(84, 44, 5),
	            cloud = Color3.fromRGB(255, 244, 248), haze = Color3.fromRGB(240, 214, 226) },
	Ashfall = { cloud = Color3.fromRGB(150, 146, 152), haze = Color3.fromRGB(150, 140, 150) },
	Penguin = { sun = Color3.fromRGB(255, 252, 240), sunAt = Vector3.new(88, 42, 4),
	            cloud = Color3.fromRGB(240, 244, 250), haze = Color3.fromRGB(206, 224, 240) },
}

----------------------------------------------------------------
-- THE CARDS
----------------------------------------------------------------
local cards = {}

for i, port in ipairs(PORTS) do
	-- TOP_IN is the LIST's own offset on the board now, not each card's, so the
	-- first card starts at zero inside it. Adding it here as well would push the
	-- whole list down by 56 and hide the last card under the ferryman.
	local y = (i - 1) * (SHOT_H + SHOT_GAP)

	-- The card sits ON the board rather than being a hole cut in it, which is
	-- the whole difference between this reading as a sticker and as a window.
	-- A SIBLING slab here, not a child: the holder clips its descendants (the
	-- viewport has to be cornered) and a child slab would be clipped away.
	local cardSlab = Instance.new("Frame")
	cardSlab.Name = "CardSlab"
	cardSlab.Position = UDim2.fromOffset(0, y + 7)
	cardSlab.Size = UDim2.fromOffset(LIST_W, SHOT_H)
	cardSlab.BackgroundColor3 = BOARD_EDGE
	cardSlab.BorderSizePixel = 0
	cardSlab.ZIndex = 11
	cardSlab.Parent = list
	corner(cardSlab, 18)

	local holder = Instance.new("TextButton")
	holder.Name = "Card_" .. port.key
	holder.Position = UDim2.fromOffset(0, y)
	holder.Size = UDim2.fromOffset(LIST_W, SHOT_H)
	holder.BackgroundColor3 = BOARD_DEEP
	holder.AutoButtonColor = false
	holder.Text = ""
	holder.BorderSizePixel = 0
	holder.ClipsDescendants = true
	holder.ZIndex = 12
	-- Into the scroller with its slab, not onto the board.
	holder.Parent = list
	corner(holder, 18)
	local edge = stroke(holder, 5, TEAL)

	--[[
		THE SKY IS A FRAME BEHIND THE VIEWPORT, NOT A GRADIENT ON IT.

		A UIGradient parented to a ViewportFrame tints everything the frame
		draws -- the rendered 3D included, not only the background behind it --
		so a sky ramp laid on directly came back over the top of the diorama and
		took every scene down to a flat murk. The viewport is transparent now and
		the ramp sits underneath it, which leaves the parts their own colours.
	]]
	local sky = Instance.new("Frame")
	sky.Name = "Sky"
	sky.Size = UDim2.fromScale(1, 1)
	sky.BackgroundColor3 = SKY[port.key] and SKY[port.key][1] or Color3.fromRGB(140, 200, 240)
	sky.BorderSizePixel = 0
	sky.ZIndex = 12
	sky.Parent = holder
	if SKY[port.key] then
		grad(sky, SKY[port.key][2], SKY[port.key][1], 90)
	end

	--[[
		THE ART IS A PHOTOGRAPH OF THE ACTUAL ISLAND NOW.

		The note at the top of this file argued for dioramas because "the cove and
		the dunes are 1500 studs away and StreamingEnabled means their geometry
		does not exist on this machine most of the time". That is true of anything
		rendered ON DEMAND -- and irrelevant to an image. These were captured in
		Studio with the lighting set to the game's own noon, uploaded, and are now
		just four decals: no parts, no cameras, no viewport scenes, and nothing to
		keep in step with the frame. Whatever the islands look like is what the
		cards look like.

		The dioramas are LEFT IN THE FILE below, unbuilt. They cost nothing while
		SHOTS has an entry for a port, and they are the fallback for a shore added
		later that has not been photographed yet.

		CROPPED BY GEOMETRY, NOT BY ImageRectOffset.

		The first cut used a pixel rect against the 1758x1080 capture and every
		card came out showing the empty sand at the BOTTOM of its photograph --
		not one of the four attractions was in frame. Roblox RE-ENCODES an upload,
		so the asset is not the resolution you handed it and a rect in source
		pixels indexes into an image that no longer has those rows.

		This lays the WHOLE picture in at the card's width, keeping its own
		aspect, and slides it up behind the holder's ClipsDescendants. `band` is
		a FRACTION of the picture's height, so it survives any re-encode and any
		change to LIST_W: 0 puts the top of the card at the top of the sky, 1 at
		the bottom of the sand.
	]]
	local photo = SHOTS[port.key]
	if photo then
		local imgH = LIST_W / (photo.aspect or (1758 / 1080))
		local img = Instance.new("ImageLabel")
		img.Name = "Photo"
		img.Size = UDim2.fromOffset(LIST_W, imgH)
		img.Position = UDim2.fromOffset(0, -(photo.band or 0.4) * imgH)
		img.BackgroundTransparency = 1
		img.BorderSizePixel = 0
		img.Image = photo.id
		img.ScaleType = Enum.ScaleType.Stretch
		img.ZIndex = 13
		img.Parent = holder
	end

	local shot = Instance.new("ViewportFrame")
	shot.Name = "Shot"
	shot.Size = UDim2.fromScale(1, 1)
	shot.Visible = (photo == nil)
	shot.BackgroundTransparency = 1
	shot.BorderSizePixel = 0
	-- Bright, because a viewport borrows nothing from the world's lighting: at
	-- the default ambient these dioramas render as silhouettes.
	local lit = LIGHT[port.key]
	shot.Ambient = lit and lit.amb or Color3.fromRGB(130, 140, 162)
	shot.LightColor = lit and lit.key or Color3.fromRGB(255, 250, 238)
	shot.LightDirection = lit and lit.dir or Vector3.new(-0.4, -1, -0.5)
	shot.ZIndex = 13
	shot.Parent = holder

	local world = Instance.new("WorldModel")
	world.Parent = shot
	local build = (not photo) and SCENES[port.key] or nil
	if build then
		local ok, err = pcall(build, world)
		if not ok then
			warn("[Ferry] diorama for " .. tostring(port.key) .. ": " .. tostring(err))
		end
	end

	-- Sun, cloud and haze. See the note on AIR: parts, not frames.
	local air = (not photo) and AIR[port.key] or nil
	if air then
		if air.sun then
			local sun = vp(world, Vector3.new(26, 26, 3),
				CFrame.new(air.sunAt.X, air.sunAt.Y, -252), air.sun, BALL, SMOOTH)
			sun.Material = Enum.Material.Neon
			sun.Transparency = 0.12
			local glow = vp(world, Vector3.new(52, 52, 3),
				CFrame.new(air.sunAt.X, air.sunAt.Y, -251), air.sun, BALL, SMOOTH)
			glow.Material = Enum.Material.Neon
			glow.Transparency = 0.72
		end
		-- Cloud bank. Deterministic, because art that reshuffles every time the
		-- panel opens reads as flicker rather than as weather.
		local rng = Random.new(7 + i * 31)
		for _ = 1, 9 do
			local wide = rng:NextNumber(30, 74)
			local cl = vp(world, Vector3.new(wide, wide * rng:NextNumber(0.22, 0.34), wide * 0.5),
				CFrame.new(rng:NextNumber(-220, 220), rng:NextNumber(26, 52), -232),
				air.cloud, BALL, SMOOTH)
			cl.Transparency = rng:NextNumber(0.18, 0.42)
		end
		-- 0.72, not 0.6: at 0.6 the scrim was washing the sea out to grey on the
		-- two cards whose water is the second thing you look at.
		local haze = vp(world, Vector3.new(760, 320, 1), CFrame.new(0, 70, -170),
			air.haze, nil, SMOOTH)
		haze.Transparency = 0.72
	end

	--[[
		FieldOfView is VERTICAL. These cards are 628 x 118, which is better than
		five to one, so a framing picked on the vertical shows an enormous amount
		horizontally -- which is exactly what a landscape vista wants and is why
		the dioramas are built wide and shallow.
	]]
	local cam = Instance.new("Camera")
	cam.FieldOfView = 25
	cam.CFrame = CFrame.lookAt(Vector3.new(-11, 12.5, 43), Vector3.new(0, 6.5, -13))
	cam.Parent = shot
	shot.CurrentCamera = cam

	-- Sits over the art and under the pills: a dark wash up from the bottom-left
	-- so white text has something to sit on wherever the scene happens to be pale.
	local shade = Instance.new("Frame")
	shade.Name = "Shade"
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	shade.BorderSizePixel = 0
	shade.ZIndex = 14
	shade.Parent = holder
	local sg = Instance.new("UIGradient")
	sg.Rotation = 12
	-- Only as much as the pills actually need. At 0.35 this was a smoked pane
	-- over the whole card and the art behind it stopped being worth drawing.
	sg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.62),
		NumberSequenceKeypoint.new(0.5, 0.9),
		NumberSequenceKeypoint.new(1, 1),
	})
	sg.Parent = shade

	local pill = Instance.new("Frame")
	pill.Name = "NamePill"
	pill.Position = UDim2.fromOffset(13, 12)
	pill.AutomaticSize = Enum.AutomaticSize.X
	pill.Size = UDim2.fromOffset(0, 38)
	pill.BackgroundColor3 = PILL
	pill.BorderSizePixel = 0
	pill.ZIndex = 16
	pill.Parent = holder
	corner(pill, 13)
	stroke(pill, 3.5, BOARD_EDGE)
	slab(pill, 5, Color3.fromRGB(6, 7, 12), 15, 13)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 15)
	pad.PaddingRight = UDim.new(0, 15)
	pad.Parent = pill
	local nameLabel = txt(pill, port.name, 22, Enum.Font.LuckiestGuy, INK, 17)
	nameLabel.AutomaticSize = Enum.AutomaticSize.X
	nameLabel.Size = UDim2.fromOffset(0, 38)
	punch(nameLabel, 3)

	--[[
		AND WHAT IS ON THAT SHORE THAT THE BOAT DOES NOT GO TO.  2026-09-12

		Four of the nine islands are interiors behind a door on another island and
		the boat serves none of them, so this panel -- the only travel screen in
		the game -- listed five places and left the player to conclude the rest
		were not real. "how can i get to island 3", from somebody eleven rebirths
		deep against a gate of four. See FerryConfig's `inland` note.

		A SECOND PILL RATHER THAN A SECOND LINE IN THE FIRST. The name pill is
		AutomaticSize.X around one word of LuckiestGuy at 22; a second line inside
		it would have to fight that sizing and would widen the pill to whichever
		of the two strings is longer. Its own pill under it costs nothing and sits
		in space the photo was using for sky.

		NOT A BUTTON, and it deliberately does not look like one. The boat cannot
		take you there; the point is only to say which shore to get off at. It
		wears the card's own edge colour rather than the GO green, so nothing on
		it reads as a destination you could pick.
	]]
	local inland = port.inland
	if inland then
		local sub = Instance.new("Frame")
		sub.Name = "InlandPill"
		sub.Position = UDim2.fromOffset(13, 56)
		sub.AutomaticSize = Enum.AutomaticSize.X
		sub.Size = UDim2.fromOffset(0, 28)
		sub.BackgroundColor3 = PILL
		sub.BackgroundTransparency = 0.12
		sub.BorderSizePixel = 0
		sub.ZIndex = 16
		sub.Parent = holder
		corner(sub, 10)
		stroke(sub, 2.5, BOARD_EDGE)
		local subPad = Instance.new("UIPadding")
		subPad.PaddingLeft = UDim.new(0, 11)
		subPad.PaddingRight = UDim.new(0, 11)
		subPad.Parent = sub
		-- "ashore" rather than "inside": the player is being told where to GET OFF
		-- the boat, which is the question they were actually asking.
		-- SEVENTEEN, matching the name label above it. txt's last argument is the
		-- ZIndex, and the card's photo carries a gradient Shade at 14 -- so this
		-- drew correctly at 11 and was painted over by it. The pill showed and the
		-- words did not, which is exactly how it looked in Play.
		local subLabel = txt(sub, string.format("%s \u{2014} ashore here, %d rebirth%s",
			string.upper(inland.name), inland.rebirths, inland.rebirths == 1 and "" or "s"),
			13, Enum.Font.GothamBold, INK, 17)
		subLabel.AutomaticSize = Enum.AutomaticSize.X
		subLabel.Size = UDim2.fromOffset(0, 28)
	end

	-- The state, bottom-right: TAKE ME / YOU ARE HERE / the padlock and level.
	local state = Instance.new("Frame")
	state.Name = "State"
	state.AnchorPoint = Vector2.new(1, 1)
	state.Position = UDim2.new(1, -13, 1, -13)
	state.AutomaticSize = Enum.AutomaticSize.X
	state.Size = UDim2.fromOffset(0, 38)
	state.BackgroundColor3 = GO
	state.BorderSizePixel = 0
	state.ZIndex = 16
	state.Parent = holder
	corner(state, 13)
	local stateEdge = stroke(state, 3.5, BOARD_EDGE)
	local stateSlab = slab(state, 5, Color3.fromRGB(6, 7, 12), 15, 13)
	gloss(state, 16.5, 0.8)
	local statePad = Instance.new("UIPadding")
	statePad.PaddingLeft = UDim.new(0, 13)
	statePad.PaddingRight = UDim.new(0, 15)
	statePad.Parent = state
	--[[
		NO UIListLayout ON THIS PILL, deliberately, and it cost a bug to learn.

		A UIListLayout lays out EVERY visible GuiObject child it has. The slab
		and the gloss are both sized (1, 0, 1, 0) -- 100% of the pill -- so the
		layout treated them as list items and the pill's AutomaticSize.X then
		measured a full-width child. Every state badge stretched the whole width
		of its card.

		The lock and the label are placed by hand instead. AutomaticSize IGNORES
		children with a scale component on the axis it is measuring (that is how
		it avoids a circular dependency), so the slab and gloss are invisible to
		it and the pill sizes to its text -- which is the behaviour that was
		wanted from the layout in the first place.
	]]

	--[[
		A DRAWN PADLOCK, not the emoji. Roblox's font has no fallback for a good
		many glyphs and a missing one renders as a hollow box -- the note at
		ToastKit's KINDS table records the same decision. It is a ring with its
		bottom half hidden behind the body, which is three frames and always
		renders.
	]]
	local lock = Instance.new("Frame")
	lock.Name = "Lock"
	lock.BackgroundTransparency = 1
	lock.Size = UDim2.fromOffset(17, 21)
	lock.AnchorPoint = Vector2.new(0, 0.5)
	lock.Position = UDim2.new(0, 0, 0.5, 0)
	lock.ZIndex = 17
	lock.Parent = state
	local shackle = Instance.new("Frame")
	shackle.BackgroundTransparency = 1
	shackle.AnchorPoint = Vector2.new(0.5, 0)
	shackle.Position = UDim2.new(0.5, 0, 0, 0)
	shackle.Size = UDim2.fromOffset(13, 14)
	shackle.ZIndex = 17
	shackle.Parent = lock
	corner(shackle, 7)
	stroke(shackle, 3, Color3.fromRGB(38, 34, 30))
	local body = Instance.new("Frame")
	body.AnchorPoint = Vector2.new(0.5, 1)
	body.Position = UDim2.new(0.5, 0, 1, 0)
	body.Size = UDim2.fromOffset(17, 13)
	body.BackgroundColor3 = Color3.fromRGB(38, 34, 30)
	body.BorderSizePixel = 0
	body.ZIndex = 18
	body.Parent = lock
	corner(body, 3)

	-- Shifted right by the lock's width when there is a lock, by setCard.
	local stateLabel = txt(state, "", 18, Enum.Font.LuckiestGuy, Color3.fromRGB(24, 40, 18), 17)
	stateLabel.AutomaticSize = Enum.AutomaticSize.X
	stateLabel.Size = UDim2.fromOffset(0, 38)
	stateLabel.Position = UDim2.fromOffset(0, 0)

	-- Dims the whole card when the shore is shut. Over the art AND the pills, so
	-- a locked destination goes quiet as one object rather than a bright badge
	-- floating on a grey picture.
	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.fromRGB(8, 9, 16)
	dim.BackgroundTransparency = 1
	dim.BorderSizePixel = 0
	dim.ZIndex = 20
	dim.Parent = holder

	cards[i] = {
		port = port, holder = holder, edge = edge, dim = dim,
		state = state, stateEdge = stateEdge, stateLabel = stateLabel, lock = lock,
		action = nil,
	}

	TouchFit.press(holder, function()
		local fn = cards[i].action
		if fn then
			fn()
		end
	end)
end

----------------------------------------------------------------
-- WHAT HE SAYS -- a speech bubble, and it is meant to be READ
--
-- This was a 12px grey line on a near-black bar, which is the smallest, least
-- noticeable thing on a screen whose whole job is answering the player. It is
-- also the ONLY place a refusal is ever spoken -- "not with that little rake" --
-- so a player who misses it is a player who has been told nothing.
--
-- Cream, because the board is dark and the eye goes to the light thing; and
-- warm brown ink on cream, because white-on-dark at this size needs an outline
-- to survive and outlined body text reads as a shout rather than as speech.
-- The NAME is outlined and the LINE is not, which is the ordinary comic
-- convention and does the hierarchy for free.
----------------------------------------------------------------
local bar = Instance.new("Frame")
bar.Name = "Bar"
bar.AnchorPoint = Vector2.new(0.5, 1)
bar.Position = UDim2.new(0.5, 0, 1, -PAD - 5)
bar.Size = UDim2.fromOffset(LIST_W, BAR_H)
bar.BackgroundColor3 = CREAM
bar.BorderSizePixel = 0
bar.ZIndex = 12
bar.Parent = card
corner(bar, 18)
stroke(bar, 5, BOARD_EDGE)
grad(bar, CREAM, CREAM_DEEP)
slab(bar, 6, Color3.fromRGB(150, 122, 84), 11, 18)

-- his port badge, in the tint of the shore he works
local badge = Instance.new("Frame")
badge.Name = "Badge"
badge.AnchorPoint = Vector2.new(0, 0.5)
badge.Position = UDim2.new(0, 14, 0.5, -2)
badge.Size = UDim2.fromOffset(52, 46)
badge.BackgroundColor3 = TEAL
badge.BorderSizePixel = 0
badge.ZIndex = 14
badge.Parent = bar
corner(badge, 14)
stroke(badge, 4, BOARD_EDGE)
slab(badge, 5, Color3.fromRGB(30, 24, 18), 13, 14)
gloss(badge, 14.5, 0.76)
local badgeCode = txt(badge, "", 19, Enum.Font.LuckiestGuy, INK, 15)
badgeCode.Size = UDim2.fromScale(1, 1)
punch(badgeCode, 3)

local speakerLabel = txt(bar, "", 19, Enum.Font.LuckiestGuy, Color3.fromRGB(212, 96, 52), 14)
speakerLabel.Name = "Speaker"
speakerLabel.Position = UDim2.fromOffset(80, 8)
speakerLabel.Size = UDim2.new(1, -94, 0, 22)
speakerLabel.TextXAlignment = Enum.TextXAlignment.Left
punch(speakerLabel, 3)

-- Two lines of room, wrapped. GothamBold rather than LuckiestGuy: the display
-- face is lovely for four words and unreadable for a sentence and a half.
local speechLabel = txt(bar, "", 16, Enum.Font.GothamBold, BROWN, 14)
speechLabel.Name = "Line"
speechLabel.Position = UDim2.fromOffset(80, 31)
speechLabel.Size = UDim2.new(1, -94, 0, 40)
speechLabel.TextXAlignment = Enum.TextXAlignment.Left
speechLabel.TextYAlignment = Enum.TextYAlignment.Top
speechLabel.TextWrapped = true
speechLabel.TextTruncate = Enum.TextTruncate.None
speechLabel.RichText = false

-- Kept as a live instance because openTalk writes it; the bar has room for one
-- line of him and one of what he is saying, and what he is saying matters more.
local titleLabel = txt(bar, "", 1, Enum.Font.GothamBold, INK, 14)
titleLabel.Name = "Title"
titleLabel.Visible = false

-- STATE ON A CARD
----------------------------------------------------------------
local STATE = {
	-- `dim` is a TRANSPARENCY, so bigger is lighter. A locked shore is still the
	-- advertisement for getting there, so it is knocked back rather than put
	-- out: at 0.42 the cove was a dark rectangle and the torii -- the one thing
	-- that sells the place -- had gone with it.
	go     = { tint = GO,  ink = Color3.fromRGB(24, 40, 18), edge = TEAL,                         lock = false, dim = 1 },
	here   = { tint = DIM, ink = Color3.fromRGB(30, 32, 44), edge = Color3.fromRGB(96, 102, 120), lock = false, dim = 0.78 },
	locked = { tint = DIM, ink = Color3.fromRGB(30, 32, 44), edge = Color3.fromRGB(70, 74, 92),   lock = true,  dim = 0.76 },
}

local function setCard(i: number, kind: string, note: string, action)
	local ui = cards[i]
	if not ui then
		return
	end
	local s = STATE[kind] or STATE.locked
	ui.stateLabel.Text = note or ""
	ui.stateLabel.TextColor3 = s.ink
	-- makes room for the padlock, which is placed at x = 0
	ui.stateLabel.Position = UDim2.fromOffset(s.lock and 24 or 0, 0)
	ui.state.BackgroundColor3 = s.tint
	ui.lock.Visible = s.lock
	ui.edge.Color = s.edge
	ui.edge.Thickness = (kind == "go") and 3.5 or 2.5
	ui.dim.BackgroundTransparency = s.dim
	ui.action = action
end


----------------------------------------------------------------
-- DRAWING IT
----------------------------------------------------------------
-- Which berth the bar is standing at. Set from the server's menu message,
-- which carries this and nothing else.
local here = nil
local hereAt = nil                     -- where the man is standing, from the server

-- A token, so a line that arrives while an older one is still typing cancels
-- it rather than the two interleaving a character at a time.
local sayToken = 0

local function say(line: string, tint: Color3?)
	sayToken += 1
	local mine = sayToken
	speechLabel.Text = "\"" .. line .. "\""
	speechLabel.TextColor3 = tint or Color3.fromRGB(104, 82, 60)
	speechLabel.MaxVisibleGraphemes = 0

	task.spawn(function()
		-- Fast enough to read at a normal pace and never so slow that a long
		-- answer feels like it is being withheld. Whole sentences are still one
		-- click away: clicking anything sets a new line and this stops.
		local n = utf8.len(speechLabel.Text) or #speechLabel.Text
		for k = 1, n do
			if sayToken ~= mine or not gui.Enabled then
				return
			end
			speechLabel.MaxVisibleGraphemes = k
			task.wait(0.014)
		end
		if sayToken == mine then
			speechLabel.MaxVisibleGraphemes = -1
		end
	end)
end

local closeTalk

--[[
	THE PANEL IS THE DESTINATION LIST, AND NOTHING ELSE.

	It used to open on a four-topic conversation -- where can you take me / what
	is it you do / what's on the other islands / nothing for now -- with the
	routes one level down behind the first of those. That is one press and one
	read before you can see the only thing anybody opens a ferryman for, on a
	crossing players make repeatedly to empty a bag. The prompt now opens
	STRAIGHT onto the shores, every one of them on screen at once, each showing
	whether it is open to you or what it wants.

	`drawRoutes` is therefore the whole panel. It is called again whenever
	anything it drew could have changed -- a level bought while the bar is open,
	a refusal answered -- so nothing on screen can be a snapshot of a moment
	that has passed. The ATV showroom learned the same lesson about pushed state.

	The ferryman is not gone: his name and title are still the panel's header and
	he still speaks the refusals. What went is having to ask him twice. His
	`job` and `tale` lines, and Ask.job / Ask.isles / Ask.back with them, are
	left in FerryConfig unused rather than deleted -- see the note there.
]]

--[[
	The three shores, through FerryConfig.blockedReason -- the SAME function the
	server refuses with, called with the same three arguments. Not a
	reimplementation of it: a row that is greyed here for one reason and refused
	there for another is the bug this shares a function to make impossible.

	And it is asked TWICE: once to draw the row and once again inside the click,
	because the level can move between the two. Buy the upgrade that opens the
	cove with the bar still open and the second read comes back clean, so the
	rows are redrawn instead of a refusal being spoken for a crossing that is no
	longer blocked.
]]
local function drawRoutes()
	local level = FerryConfig.levelOf(player)
	for i, port in ipairs(PORTS) do
		local blocked = FerryConfig.blockedReason(port, level, here and here.key)
		if not blocked then
			setCard(i, "go", "TAKE ME", function()
				if not remotes then
					return
				end
				AudioKit.play("UIClick", nil, 1, 1)
				remotes.FerrySail:FireServer(port.key)
				closeTalk()
			end)
		elseif here and port.key == here.key then
			setCard(i, "here", "YOU ARE HERE", function()
				say(here.ferryman.here)
			end)
		else
			-- "Lv.%d" until the ports moved off Sifter levels onto the Rebirths
			-- counter. The card is the ONLY place a player reads the requirement
			-- before talking to the ferryman, so a stale unit here is a player
			-- hunting the shop for a level that is not what the boat wants.
			--
			-- The unit is SPELLED OUT, not the ↻ glyph it used to be.
			-- LuckiestGuy has no arrow for it, so the badge read as a bare
			-- number -- 8, 22 -- next to a padlock, which says nothing about
			-- WHAT eight of. Same singular/plural split FerryConfig's refusal
			-- uses, so the badge and the ferryman never disagree on the word.
			setCard(i, "locked", string.format("%d REBIRTH%s", port.requireLevel,
				port.requireLevel == 1 and "" or "S"), function()
				local why = FerryConfig.blockedReason(port,
					FerryConfig.levelOf(player), here and here.key)
				if not why then
					drawRoutes()
					return
				end
				AudioKit.play("Reject", nil, 1, 1)
				say(here.ferryman.refuse .. "  (" .. why .. ")")
			end)
		end
	end
end

function closeTalk()
	gui.Enabled = false
	sayToken += 1
	here = nil
	hereAt = nil
end

TouchFit.press(closeBtn, closeTalk)

local function openTalk(port, near: Vector3?)
	here = port
	hereAt = near
	badgeCode.Text = port.code
	badge.BackgroundColor3 = port.tint
	speakerLabel.Text = string.upper(port.ferryman.name)
	titleLabel.Text = string.upper(port.ferryman.title)
	drawRoutes()

	--[[
		ENABLED BEFORE THE LINE IS SPOKEN, AND THAT ORDER IS LOAD-BEARING.

		`say` reveals the text a grapheme at a time from a `task.spawn`, and
		task.spawn runs its body IMMEDIATELY, synchronously, up to the first
		yield -- so the loop's first iteration happens before the next line of
		this function does. Its guard bails on `not gui.Enabled`, so with the
		enable underneath it the typewriter returned on k = 1 every single time
		and left MaxVisibleGraphemes at 0.

		The greeting was therefore NEVER ONCE VISIBLE on open -- the label had
		the right text the whole time, with none of it revealed, which is why it
		read as an empty band under his name rather than as a broken line. Only
		lines said while the panel was already up (a refusal, "this pier") ever
		showed. Do not reorder these two.
	]]
	gui.Enabled = true

	-- One line, and it is the only thing he says unprompted. Every greeting in
	-- FerryConfig already ends by asking where you are going, which is exactly
	-- the question the rows underneath answer.
	say(port.ferryman.greeting)
	AudioKit.play("UIClick", nil, 1, 1.05)
	-- Punches up from 70%, the way every card in the game arrives. It grows out
	-- of the bottom edge rather than out of its own middle, because the anchor
	-- point is already (0.5, 1) and popIn only touches Size.
	-- The height it is ALLOWED right now, not the natural one. popIn animates
	-- Size to whatever it is handed, so passing CARD_H here would tween the
	-- board straight back to 670 on every open and undo the fit.
	PanelKit.popIn(card, CARD_W, boardHeight())
end

-- The level can move while the bar is open -- buy the upgrade that opens the
-- cove and the row behind you should stop refusing.
player:GetAttributeChangedSignal(FerryConfig.LevelAttribute):Connect(function()
	if gui.Enabled and here then
		drawRoutes()
	end
end)

--[[
	WALK AWAY AND HE STOPS TALKING.

	Measured from where the SERVER says he is standing, which arrives with the
	menu message. Measured from the pier head instead -- the obvious thing, and
	the first thing tried -- the bar shut itself the instant somebody stepped
	ashore off a crossing, because the landing spot on the dunes is forty-two
	studs from the head and the man is twelve.

	A little past the server's own TalkRange, so the bar never shuts on somebody
	the server would still have carried. No anchor sent means no auto-close: an
	open bar the player has to shut by hand is a far smaller problem than one
	that closes mid-sentence.
]]
local WALK_OFF = FerryConfig.TalkRange + 14
task.spawn(function()
	while true do
		task.wait(0.4)
		if gui.Enabled and hereAt then
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp and (hereAt - hrp.Position).Magnitude > WALK_OFF then
				closeTalk()
			end
		end
	end
end)

----------------------------------------------------------------
-- THE CROSSING
----------------------------------------------------------------
--[[
	The veil, and it is a good deal less of the crossing than it used to be.

	Eight beats now (FerryConfig.Trip) and the screen is only dark for two of
	them: the boat leaves with the player standing on her, fights her way out
	past the point, the dark covers the teleport, and it lifts on the far boat
	already in the worst of it. So this file is not the journey any more -- the
	SERVER is, and this is the cut in the middle of it.

	THE CAMERA IS NOT DRIVEN HERE, BUT IT IS SHAKEN. The player's root is moved
	by the server for all four runs and the default camera follows their root,
	so the framing takes care of itself: the pier goes behind you, the island
	goes small, and you are looking over the bow. A scripted camera would have
	to fight the one thing already doing the right thing. What the default
	camera cannot do is FEEL the sea, so the one thing written here is
	Humanoid.CameraOffset -- which the default camera module applies for us,
	which is why this needs no camera of its own and cannot fight one.

	Sized in SCALE, deliberately: UiFit wraps and shrinks every top-level child
	whose size is pure offset, and a full-screen veil at 60% stops covering the
	screen and leaves a border of live game around the fade.
]]
local transit = Instance.new("ScreenGui")
transit.Name = "FerryTransit"
transit.ResetOnSpawn = false
transit.IgnoreGuiInset = true
-- Above the bar (50) and above the toast column (16). A crossing is a
-- full-screen moment and nothing should be drawing over it.
transit.DisplayOrder = 60
transit.Enabled = false
transit.Parent = playerGui

local veil = Instance.new("Frame")
veil.Name = "Veil"
veil.Size = UDim2.fromScale(1, 1)
veil.BackgroundColor3 = Color3.new(0, 0, 0)
veil.BackgroundTransparency = 1
veil.BorderSizePixel = 0
-- Over the bars below, so the cut in the middle covers the whole frame and not
-- just the picture between them.
veil.ZIndex = 5
veil.Parent = transit

--[[
	THE BARS.

	What turns a screen effect into a CUT. Three things have to happen together
	or the crossing goes on reading as gameplay you have temporarily lost the
	controls to: the HUD goes, the camera is taken, and the frame changes SHAPE.
	The bars are the third and they are the cheapest by a distance.

	On `transit` rather than on the veil, because the veil is transparent for
	six of the eight beats and the bars have to be there for all of them.
]]
local function transitBar(name: string, anchor: Vector2, pos: UDim2): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.AnchorPoint = anchor
	f.Position = pos
	f.Size = UDim2.fromScale(1, 0)
	f.BackgroundColor3 = Color3.new(0, 0, 0)
	f.BorderSizePixel = 0
	f.ZIndex = 2
	f.Parent = transit
	return f
end

local barTop = transitBar("BarTop", Vector2.new(0, 0), UDim2.fromScale(0, 0))
local barBottom = transitBar("BarBottom", Vector2.new(0, 1), UDim2.fromScale(0, 1))

-- No UIStroke on this one. White LuckiestGuy on black needs no outline, and a
-- stroke would have to be tweened in step with the label or the letters fade
-- out and leave their own edges behind.
local caption = Instance.new("TextLabel")
caption.Name = "Caption"
caption.AnchorPoint = Vector2.new(0.5, 0.5)
caption.Position = UDim2.fromScale(0.5, 0.5)
caption.Size = UDim2.fromScale(0.8, 0.16)
caption.BackgroundTransparency = 1
caption.Font = Enum.Font.LuckiestGuy
caption.TextScaled = true
caption.TextColor3 = Color3.fromRGB(255, 250, 238)
caption.TextTransparency = 1
caption.Text = ""
caption.Parent = veil

--[[
	THE SKIP CHIP.

	Nine seconds is the right length for a crossing you make twice and the wrong
	one for a crossing you make forty times, and the difference is entirely
	whether the player is allowed to say so. So there is a way out, and it is
	ADVERTISED -- an unadvertised skip is a skip nobody finds.

	IN THE BOTTOM BAR, which is the one part of the frame the shot has already
	given up. It costs the picture nothing, it is where every game that has ever
	let you skip a cutscene puts it, and white on the letterbox needs no plate
	behind it to be legible.

	PIXEL-SIZED ON PURPOSE, unlike the veil and the bars beside it. UiFit only
	absorbs a top-level child whose size is pure offset on both axes -- which is
	wrong for a full-screen veil and exactly right for a line of small type that
	has to stay readable on a phone. So this one wants to be swallowed and the
	other two must not be, and the size is what says which.
]]
local skipChip = Instance.new("TextButton")
skipChip.Name = "SkipChip"
skipChip.AnchorPoint = Vector2.new(1, 1)
skipChip.Position = UDim2.new(1, -26, 1, -20)
skipChip.Size = UDim2.fromOffset(214, 36)
skipChip.BackgroundColor3 = Color3.fromRGB(16, 17, 26)
skipChip.BackgroundTransparency = 1
skipChip.BorderSizePixel = 0
skipChip.AutoButtonColor = false
skipChip.Text = ""
skipChip.Visible = false
skipChip.ZIndex = 8
skipChip.Parent = transit
corner(skipChip, 10)
local skipEdge = stroke(skipChip, 2, Color3.fromRGB(128, 140, 166), 1)

-- A tap target as well as a caption, because on a phone "any key" is not a
-- thing. The global handler below catches a screen tap anywhere the thumbstick
-- has not already eaten; this catches the one place a player will actually aim.
local skipLabel = txt(skipChip, "PRESS ANY KEY TO SKIP", 15, Enum.Font.GothamBold,
	Color3.fromRGB(230, 236, 248), 9)
skipLabel.Size = UDim2.fromScale(1, 1)
skipLabel.TextTransparency = 1
if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
	skipLabel.Text = "TAP TO SKIP"
end

local tripToken = 0

-- Forward-declared: endCrossing is written above the skip block because three
-- other things already call it, and it has to be able to put the chip away.
local disarmSkip = function() end

--[[
	THE SEA, ON THE CAMERA.

	The server owns the sea state and never sends it: the beats are shared
	constants, so this file can work out the roughness for itself from nothing
	but a stopwatch started when the "out" message landed. That is the same
	bargain the veil already makes, and for the same reason -- a dropped message
	must never be able to leave a camera shaking after the boat has tied up.

	`roughAt` MIRRORS FerryServer's four legs and has to stay in step with them.
	If a beat is added or the roughness at a handover changes, it changes in two
	places. That is a real cost and it was taken knowingly, over the alternative
	of a per-frame remote carrying a number.

	ZERO WHILE THE SCREEN IS BLACK. Shaking a camera nobody can see costs a
	property write a frame and buys nothing, and the two dark beats are exactly
	where a player would otherwise notice the shake having no picture to move.
]]
local CUT_AT = TRIP.board + TRIP.cast + TRIP.fight
local LIFT_AT = CUT_AT + TRIP.fade + TRIP.hold
local END_AT = LIFT_AT + TRIP.surge + TRIP.come + TRIP.land

local function roughAt(e: number): number
	if e < 0 or e < TRIP.board then
		return 0
	end
	e -= TRIP.board
	if e < TRIP.cast then
		return (e / TRIP.cast) * 0.35            -- still in the lee, building
	end
	e -= TRIP.cast
	if e < TRIP.fight then
		return 0.35 + (e / TRIP.fight) * 0.65    -- out past the point
	end
	e -= TRIP.fight
	if e < TRIP.fade + TRIP.hold then
		return 0                                  -- black
	end
	e -= TRIP.fade + TRIP.hold
	if e < TRIP.surge then
		return 1 - (e / TRIP.surge) * 0.6        -- running in on a following sea
	end
	e -= TRIP.surge
	if e < TRIP.come then
		return 0.4 * (1 - e / TRIP.come)         -- into the far island's lee
	end
	return 0
end

local shakeFrom, shakeUntil = 0, 0
local shaking = false

-- Whether the crossing is holding the camera. Declared up here because the
-- shake below has to read it, and the shake is connected before the block that
-- writes it.
local camActive = false

-- Three periods on each axis, none of them a multiple of another, so a long
-- rough beat never settles into a rhythm the eye can predict. Small numbers:
-- CameraOffset is in studs and a quarter of one is already a lot of movement
-- on a camera this close in.
RunService.RenderStepped:Connect(function()
	local now = os.clock()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")

	-- STOOD DOWN WHILE THE CROSSING OWNS THE CAMERA. CameraOffset is applied by
	-- the DEFAULT camera module and does nothing at all to a scriptable one, so
	-- this would be writing a property with no effect for eight seconds -- and
	-- leaving a value in it that jolts the shot the instant the camera is handed
	-- back. The cinematic rolls its own camera off the same roughAt curve.
	if camActive then
		if shaking then
			shaking = false
			if hum then
				hum.CameraOffset = Vector3.zero
			end
		end
		return
	end

	if now > shakeUntil then
		if shaking then
			shaking = false
			if hum then
				hum.CameraOffset = Vector3.zero
			end
		end
		return
	end
	if not hum then
		return
	end

	-- AND THE PLAYER MAY HAVE TURNED THE SEA OFF. Read per frame rather than at
	-- the crossing's start, so the switch lands on the frame it is thrown
	-- instead of at the next island.
	if not Motion.shake() then
		if shaking then
			shaking = false
			hum.CameraOffset = Vector3.zero
		end
		return
	end

	local rough = roughAt(now - shakeFrom)
	if rough <= 0.001 then
		if shaking then
			shaking = false
			hum.CameraOffset = Vector3.zero
		end
		return
	end

	shaking = true
	hum.CameraOffset = Vector3.new(
		(math.sin(now * 9.3) * 0.18 + math.sin(now * 4.1 + 0.7) * 0.12) * rough,
		(math.sin(now * 7.1 + 1.3) * 0.26 + math.sin(now * 2.4) * 0.34) * rough,
		(math.sin(now * 5.6 + 2.1) * 0.10) * rough)
end)

-- Put the camera straight, whatever beat we were on. Called when a crossing
-- ends by any route at all, including the watchdog.
local function stopShake()
	shakeUntil = 0
end

----------------------------------------------------------------
-- THE CROSSING AS A CUT
--
-- WHAT THIS REPLACES, AND WHY.
--
-- The crossing used to be played on the DEFAULT camera: the server moved the
-- player's root along the boat's path, the ordinary third-person camera
-- followed it, and the only thing written here was Humanoid.CameraOffset to
-- make the sea felt. That was a deliberate choice and it had a real argument
-- behind it -- the default camera was already framing the shot correctly, and a
-- scripted one would have to fight it.
--
-- But it meant the crossing was still GAMEPLAY. HUD up, load bar, carried
-- panel, the same over-the-shoulder framing as walking around the beach, and
-- the player's own mouse still swinging the camera about. Eight seconds of
-- standing on a moving platform looking at your own back is not a voyage, and
-- nothing about it says a journey happened.
--
-- So it is a cut now. HUD off, bars in, camera taken, and the shot changes four
-- times across the beats -- and the one thing the old version had right is kept
-- and made better: the sea is still FELT, but now the camera rolls with the hull
-- instead of nudging a follow-cam.
--
-- EVERYTHING HANGS OFF THE PLAYER'S OWN ROOT, which is the trick that makes
-- this cheap. FerryServer anchors the rider and writes `hrp.CFrame = boatCF *
-- riderOffset` every frame, so the root already carries the boat's position,
-- her heading AND her roll in the swell. There is no need to find the boat
-- model on the client, no need for the server to send a single extra byte, and
-- nothing to go looking for under StreamingEnabled.
--
-- STILL NOT AUTHORITATIVE. The server sails the boat and lands the player
-- whatever this does; every exit path below hands the camera and the HUD back,
-- and the watchdog that already existed for the veil now covers the camera too.
----------------------------------------------------------------

-- Beat boundaries, off the same shared constants as the veil and the roughness.
local B_BOARD = TRIP.board
local B_CAST = B_BOARD + TRIP.cast
local B_SURGE = LIFT_AT + TRIP.surge
local B_COME = B_SURGE + TRIP.come

local HIDE_FOR_CROSSING = {
	"CleanTheBeachHUD", "InventoryHud", "BeachMenuHud", "WeightHUD",
	"SiftHud", "DriveHud", "FeedbackHud", "RevealPopup",
	-- The event countdown. ToastKit stays for the ferryman's line (see below);
	-- this is a readout with nothing to say, and the crossing is the one shot in
	-- the game the player is meant to just watch.
	"EventHud",
	"BoostHud",
	-- OUR OWN PANEL, which was the one thing on screen nobody thought to hide.
	-- You sail BY pressing its button, so it is open at the exact moment the
	-- crossing starts and it stayed up for the whole voyage -- a menu with a
	-- SAIL button on it, sitting over a cinematic about sailing.
	"FerryTalk",
}
-- ToastKit is deliberately NOT in that list, the same call RebirthCinema makes:
-- the ferryman's parting line is fired as a toast on the same frame the boat
-- casts off, and it is the one thing anybody says during the crossing.

local hiddenForCrossing = {}

--[[
	AND EVERYTHING THE WORLD ITSELF IS SAYING.

	Switching off the ScreenGuis above leaves the crossing looking like gameplay
	with the HUD turned off, because the loudest text on screen is not on the HUD
	at all -- it is in the world. Counted on the live place:

	  21 proximity prompts   "Browse / Beach Shop", "Car Spawner / ATVs
	                         & Dozers", "Mount Crusted Find / Wash Bay"
	  13 billboards          "STEP HERE TO SELL", "TAP TO OPEN", three eggs per
	                         plaza -- and a nameplate over each ferryman's head,
	                         which is standing next to you the whole voyage
	  33 surface guis        "SELL HERE", "OPEN", "SIFTERS BUCKETS BOOTS"

	Three of those go and one stays.

	PROMPTS go through ProximityPromptService.Enabled -- one switch rather than
	21, and nothing aboard needs a prompt because the skip is a screen button.

	BILLBOARDS go. They are UI wearing a world costume: they face the camera,
	they scale with distance, and they are the "press to interact" furniture the
	shot is trying to get away from.

	NAMETAGS go, for every character rather than just the local one -- on a busy
	server the boat is full, and hiding your own tag while six others float past
	the lens is worse than leaving them all on. Roblox's own humanoid tags, so it
	is DisplayDistanceType; there is no custom nametag in this place. The
	PREVIOUS value is stored per humanoid rather than assumed to be Viewer, so
	anything that sets it for its own reasons gets it back as it left it.

	SURFACE GUIS STAY. They are painted signs on physical boards, and a camera
	panning past a beach would see those, because they are objects. Blanking them
	leaves every shopfront looking unfinished, which is less cinematic, not more.

	The workspace sweep costs 1.8ms over 9,471 descendants, once per crossing,
	behind the fade.
]]
local ProximityPromptService = game:GetService("ProximityPromptService")
local promptsWere = nil
local billboardsHidden = {}
local tagsHidden = {}

local function hideWorldChrome()
	if promptsWere == nil then
		promptsWere = ProximityPromptService.Enabled
	end
	ProximityPromptService.Enabled = false

	table.clear(billboardsHidden)
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("BillboardGui") and d.Enabled then
			d.Enabled = false
			table.insert(billboardsHidden, d)
		end
	end

	table.clear(tagsHidden)
	for _, plr in ipairs(Players:GetPlayers()) do
		local ch = plr.Character
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		if hum and hum.DisplayDistanceType ~= Enum.HumanoidDisplayDistanceType.None then
			table.insert(tagsHidden, { hum = hum, was = hum.DisplayDistanceType })
			hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	end
end

local function showWorldChrome()
	if promptsWere ~= nil then
		ProximityPromptService.Enabled = promptsWere
		promptsWere = nil
	end
	for _, b in ipairs(billboardsHidden) do
		if b.Parent then
			b.Enabled = true
		end
	end
	table.clear(billboardsHidden)
	for _, e in ipairs(tagsHidden) do
		if e.hum.Parent then
			e.hum.DisplayDistanceType = e.was
		end
	end
	table.clear(tagsHidden)
end

local function hideCrossingHud()
	table.clear(hiddenForCrossing)
	for _, name in ipairs(HIDE_FOR_CROSSING) do
		local g = playerGui:FindFirstChild(name)
		if g and g:IsA("ScreenGui") and g.Enabled then
			g.Enabled = false
			table.insert(hiddenForCrossing, g)
		end
	end
	hideWorldChrome()
end

local function showCrossingHud()
	for _, g in ipairs(hiddenForCrossing) do
		if g.Parent then
			g.Enabled = true
		end
	end
	table.clear(hiddenForCrossing)
	-- Hung off the same pair the HUD uses, so every way a crossing can end --
	-- arrival, skip, death, respawn -- puts the world back without a second
	-- list of exit points to keep in step. endCrossing is idempotent and calls
	-- this, so a doubled call is free.
	showWorldChrome()
end

local function ease(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

local function lerpV(a: Vector3, b: Vector3, t: number): Vector3
	return a + (b - a) * t
end

local V = Vector3.new

--[[
	WHERE THE CAMERA IS, IN THE BOAT'S OWN SPACE.

	Returned as (eye, aim), both relative to a yaw-only frame sitting on the
	rider. +Z is BEHIND her and -Z is ahead of the bow, because a CFrame's
	LookVector is its -Z.

	Four shots and a hold:

	  board   off her starboard quarter, low, close -- you are on a boat
	  cast    pulling out and up as she leaves, so the pier goes small behind
	  fight   AHEAD OF THE BOW AT WATER LEVEL, looking back at her. This is the
	          shot the whole thing is for: she is coming AT the camera with the
	          sea running under her, and it is the only angle where fighting the
	          water reads as fighting rather than as bobbing.
	  (black) the fight framing is held rather than reset, so the veil lifts on a
	          camera that is already somewhere sensible instead of whipping.
	  surge   ABOVE THE MASTHEAD, out on the quarter and well astern, aimed
	          past the bow so the far island is what you are looking at
	  come    craning down and in to a three-quarter as she makes the lee
	  land    eased back to where the default camera will be standing, so the
	          handover at the end is not a jump

	THE ARRIVAL SHOTS CLEAR THE SAIL BY GOING OVER IT, AND THAT IS ARITHMETIC
	RATHER THAN TASTE. These offsets were written for the hand-built punt this
	berth used to launch, whose sail was 7 studs across and 9 tall. She is a
	mesh boat now, and FerryBuilder's kit sail measures 22.2 x 17.9 and stands
	as a WALL ACROSS her, dead centre on the rider -- in this frame it fills
	ox [-11.1, 11.0], oy [1.3, 19.2], oz [-2.8, 2.3]. A camera astern of that at
	the old height of four or five studs is pointed straight into cloth: the sail
	covered 52-67% of the frame for the whole run in and blocked every sightline
	to the island ahead, so the one beat that exists to show you where you are
	sailing showed a red wall instead (2026-09-09).

	OVER THE TOP IS THE ONLY CLEARANCE THAT SURVIVES THE SWELL. The sail's foot
	is 1.3 studs above the rider's root and it is 22 wide, so from astern there
	is no gap to shoot through at any height between her waist and 19 studs up,
	and no quarter inside 11 studs that gets round it. Going high is the one
	answer the sea cannot take back: roll and pitch swing the masthead SIDEWAYS
	and FORE-AND-AFT, never higher. Measured at every swell phase, `surge` -- the
	one beat that exists to show you the island -- now reads 10-15% of frame with
	EVERY horizontal sightline to the horizon clear, against 54-68% and none of
	them clear before. Do not read that as the figure for the whole arrival:
	`come` and `land` climb back to roughly half a frame of cloth as the camera
	descends out of the sky and into the sail's height band, and that is meant --
	by then you have arrived and the subject is the boat coming alongside, not the
	sea ahead. Both still measure at or below what they measured before this
	change, so neither is a regression, but neither is clear either. The rider
	stays in frame the whole way, at her smallest about four fifths of the way
	down it and 41 studs out.

	THE QUARTER IS +X ON PURPOSE. A berth's heading is a pure yaw and the rider
	offset is fixed in the boat's frame, so the sail sits in exactly these
	numbers at all four berths -- but `dir` flips which side the pier lies on,
	and on an ARRIVAL the pier is to starboard at every island and to port at
	the Beach. Shooting from +X puts the pier you are running for in shot at the
	three islands somebody sails to for the first time, and costs only the
	Beach: the one arrival whose destination is the place you already live.
]]
local function shotAt(e: number): (Vector3, Vector3)
	if e < B_BOARD then
		return V(7.0, 2.4, 5.0), V(0, 2.2, 0)

	elseif e < B_CAST then
		local a = ease((e - B_BOARD) / math.max(TRIP.cast, 0.01))
		return lerpV(V(7.0, 2.4, 5.0), V(14.0, 5.2, 2.0), a),
			lerpV(V(0, 2.2, 0), V(0, 2.0, -2), a)

	elseif e < CUT_AT then
		local a = ease((e - B_CAST) / math.max(TRIP.fight, 0.01))
		return lerpV(V(14.0, 5.2, 2.0), V(3.4, 1.5, -11.5), a),
			lerpV(V(0, 2.0, -2), V(0, 2.4, 0), a)

	elseif e < LIFT_AT then
		return V(3.4, 1.5, -11.5), V(0, 2.4, 0)

	elseif e < B_SURGE then
		local a = ease((e - LIFT_AT) / math.max(TRIP.surge, 0.01))
		return lerpV(V(14.0, 24.0, 30.0), V(13.0, 21.0, 25.0), a),
			lerpV(V(0, 8.0, -34), V(0, 7.0, -28), a)

	elseif e < B_COME then
		local a = ease((e - B_SURGE) / math.max(TRIP.come, 0.01))
		return lerpV(V(13.0, 21.0, 25.0), V(13.0, 7.0, 7.0), a),
			lerpV(V(0, 7.0, -28), V(0, 2.2, -2), a)
	end

	local a = ease((e - B_COME) / math.max(TRIP.land, 0.01))
	return lerpV(V(13.0, 7.0, 7.0), V(0, 3.2, 12.5), a),
		lerpV(V(0, 2.2, -2), V(0, 1.5, 0), a)
end

local camConn: RBXScriptConnection? = nil

local function releaseCamera()
	if camConn then
		camConn:Disconnect()
		camConn = nil
	end
	if not camActive then
		return
	end
	camActive = false
	local cam = workspace.CurrentCamera
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.CameraOffset = Vector3.zero
	end
	if cam then
		if hum then
			cam.CameraSubject = hum
		end
		cam.CameraType = Enum.CameraType.Custom
	end
end

local function takeCamera(startedAt: number, mine: number)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	if camConn then
		camConn:Disconnect()
	end
	camActive = true
	cam.CameraType = Enum.CameraType.Scriptable

	camConn = RunService.RenderStepped:Connect(function()
		if tripToken ~= mine then
			return
		end
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not (hrp and hrp:IsA("BasePart")) then
			return
		end

		local e = os.clock() - startedAt
		local root = hrp.CFrame

		-- A YAW-ONLY FRAME to hang the shot off. Using the root's own CFrame
		-- directly would put the boat's full pitch and roll into the camera's
		-- POSITION as well as its attitude, and a camera whose eye is swung
		-- bodily through a couple of studs every swell is unwatchable. The roll
		-- comes back in below, on the attitude only, where it belongs.
		local look = root.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		flat = (flat.Magnitude > 0.01) and flat.Unit or Vector3.new(0, 0, 1)
		local base = CFrame.lookAt(root.Position, root.Position + flat)

		local off, aim = shotAt(e)
		local now = os.clock()

		-- THE SAME SWITCH, ON THE CINEMATIC'S OWN CAMERA. This path does not go
		-- through CameraOffset -- it writes the camera directly -- so gating the
		-- block above and stopping there would have left the crossing, the one
		-- place every player is guaranteed to meet a shaking camera, shaking.
		local steady = not Motion.shake()
		local rough = steady and 0 or roughAt(e)

		-- The hand-held, in the boat's own axes so a pitch reads as a pitch
		-- rather than as a slide across the screen.
		local jitter = Vector3.new(
			math.sin(now * 9.3) * 0.20 + math.sin(now * 4.1 + 0.7) * 0.14,
			math.sin(now * 7.1 + 1.3) * 0.26 + math.sin(now * 2.4) * 0.34,
			math.sin(now * 5.6 + 2.1) * 0.12) * rough

		local eye = base:PointToWorldSpace(off + jitter)
		local focus = base:PointToWorldSpace(aim)

		-- THE ROLL, TAKEN OFF THE HULL ITSELF rather than invented. The server's
		-- swell() is already rolling the boat and therefore the rider's root, so
		-- the horizon can be tipped by the real thing: RightVector.Y is the sine
		-- of that roll. Amplified a little, because a camera mounted on a boat
		-- sees more tilt than a rider standing on her does, and scaled by the
		-- sea state so the calm beats at either end sit level.
		--
		-- LEVELLED OUTRIGHT when the switch is off. Zeroing `rough` alone leaves
		-- the base 0.9 of real hull roll still tipping the horizon, and that is
		-- the half of this shot that actually swings the picture about.
		local roll = steady and 0
			or math.asin(math.clamp(root.RightVector.Y, -1, 1)) * (0.9 + rough * 0.8)

		workspace.CurrentCamera.CFrame =
			CFrame.lookAt(eye, focus) * CFrame.Angles(0, 0, roll)
	end)
end

-- One way out, used by the scheduled end, by the server's "done", by the
-- watchdog and by a respawn. Idempotent on purpose: three of those four can
-- arrive for the same crossing.
local function endCrossing()
	local wasActive = camActive
	releaseCamera()
	stopShake()
	showCrossingHud()
	disarmSkip()
	for _, f in ipairs({ barTop, barBottom }) do
		TweenService:Create(f, TweenInfo.new(0.45, Enum.EasingStyle.Quad),
			{ Size = UDim2.fromScale(1, 0) }):Play()
	end
	if wasActive then
		local mine = tripToken
		task.delay(0.6, function()
			-- Only if another crossing has not started in the meantime, and only
			-- once the veil is out of the way -- a player who casts off again
			-- inside half a second must not have the new crossing's gui switched
			-- off by the old one's tail.
			if tripToken == mine and not camActive and veil.BackgroundTransparency >= 0.99 then
				transit.Enabled = false
			end
		end)
	end
end

--[[
	SKIPPING, AND WHAT IT CAN AND CANNOT SKIP.

	It ends the CINEMATIC -- the shot, the bars, the veil -- and nothing else.
	It cannot end the crossing: FerryServer owns that, it is flying an anchored
	character on its own clock, and the teleport between the two seas happens at
	a fixed moment whether anybody is watching or not. There is no client message
	that could bring it forward and inventing one would put the shape of the trip
	in two places.

	SO A SKIP BEFORE THE CUT GOES DARK FIRST. The teleport is covered by the
	veil, and handing the camera back early without it would show the world
	change around a stationary player -- which is the one thing the black beat
	exists to hide. The lift that was already scheduled takes the veil away again
	on time, so what the player actually buys is the rest of the crossing in
	normal view instead of in a letterbox, which is what "skip" means here.

	After the lift there is nothing to hide and it is simply an early out.
]]
local skipArmed = false

local function setSkipVisible(on: boolean)
	if on then
		skipChip.Visible = true
		TweenService:Create(skipChip, TweenInfo.new(0.3), { BackgroundTransparency = 0.25 }):Play()
		TweenService:Create(skipLabel, TweenInfo.new(0.3), { TextTransparency = 0 }):Play()
		TweenService:Create(skipEdge, TweenInfo.new(0.3), { Transparency = 0.45 }):Play()
	else
		TweenService:Create(skipChip, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play()
		TweenService:Create(skipLabel, TweenInfo.new(0.2), { TextTransparency = 1 }):Play()
		TweenService:Create(skipEdge, TweenInfo.new(0.2), { Transparency = 1 }):Play()
		task.delay(0.25, function()
			if not skipArmed then
				skipChip.Visible = false
			end
		end)
	end
end

-- Assigning the forward declaration made above endCrossing, which is written
-- before this block because three other things already call it.
disarmSkip = function()
	skipArmed = false
	setSkipVisible(false)
end

local function skipCrossing()
	if not skipArmed or not camActive then
		return
	end
	disarmSkip()

	-- Before the lift the teleport either has not happened yet or is happening
	-- now, so the veil goes down before the camera comes back. `liftIn` is
	-- already scheduled at LIFT_AT and will take it away again.
	if os.clock() - shakeFrom < LIFT_AT then
		TweenService:Create(veil, TweenInfo.new(0.2), { BackgroundTransparency = 0 }):Play()
		TweenService:Create(caption, TweenInfo.new(0.2), { TextTransparency = 0 }):Play()
	end

	AudioKit.play("UIClick", nil, 0.8, 0.9)
	endCrossing()
end

--[[
	ANY KEY, and `processed` is what keeps that honest: an input the chat box or
	a button has already consumed is not the player asking to skip. Movement keys
	are NOT consumed -- the control module does not claim them -- so W skips,
	which is what "any key" has to mean or it is a lie.

	Connected once, at load. `skipArmed` is false outside a crossing, so this is
	inert for the entire rest of the session.
]]
UserInputService.InputBegan:Connect(function(input, processed)
	if processed or not skipArmed then
		return
	end
	local t = input.UserInputType
	if t == Enum.UserInputType.Keyboard
		or t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Touch
		or t == Enum.UserInputType.MouseButton1 then
		skipCrossing()
	end
end)

TouchFit.activated(skipChip, skipCrossing)

-- A death or a respawn mid-crossing detaches everything the shot is driving,
-- and the server has already stopped flying the corpse (see `run`). There is
-- nothing left to film.
player.CharacterAdded:Connect(function()
	if camActive then
		endCrossing()
	end
end)

local function liftIn(mine: number)
	if tripToken ~= mine then
		return
	end
	TweenService:Create(veil, TweenInfo.new(TRIP.fade), { BackgroundTransparency = 1 }):Play()
	TweenService:Create(caption, TweenInfo.new(TRIP.fade * 0.6), { TextTransparency = 1 }):Play()
	task.delay(TRIP.fade + 0.15, function()
		-- NOT WHILE THE SHOT IS STILL RUNNING. The veil lifts in the MIDDLE of the
		-- crossing -- there are three beats of sailing after it -- and the
		-- letterbox bars live on this same gui. Switching it off here took the
		-- bars away with the veil and handed the last four seconds back to a
		-- full-frame picture, halfway through a cut. endCrossing owns it now.
		if tripToken == mine and not camActive then
			transit.Enabled = false
		end
	end)
end

local function castOff(payload)
	tripToken += 1
	local mine = tripToken

	closeTalk()

	transit.Enabled = true
	veil.BackgroundTransparency = 1
	caption.Text = tostring(payload.caption or "")
	caption.TextTransparency = 1

	-- THE CUT, and all three parts of it land on the same frame the boat casts
	-- off. Bars in fast -- 0.45s, Quint out -- because a leisurely letterbox is
	-- a title sequence and this is a hard cut away from play.
	hideCrossingHud()
	barTop.Size = UDim2.fromScale(1, 0)
	barBottom.Size = UDim2.fromScale(1, 0)
	for _, f in ipairs({ barTop, barBottom }) do
		TweenService:Create(f, TweenInfo.new(0.45, Enum.EasingStyle.Quint,
			Enum.EasingDirection.Out), { Size = UDim2.fromScale(1, 0.105) }):Play()
	end

	-- The surf sweetener the tide already uses, run a little low. Every id in
	-- this game goes through AudioKit's library on purpose: an asset id that
	-- does not resolve throws nothing and plays nothing, and silence looks
	-- exactly like a feature nobody got round to.
	AudioKit.play("Wave", nil, 0.9, 0.82)
	if type(payload.line) == "string" and payload.line ~= "" then
		ToastKit.toast(payload.line, "info", 2.4)
	end

	-- The stopwatch the roughness runs off. Given a second of slack past the
	-- last beat so a slow frame at the end cannot leave the camera mid-shake.
	shakeFrom = os.clock()
	shakeUntil = shakeFrom + END_AT + 1

	-- Off the SAME stopwatch as the roughness and the veil, so the shot, the sea
	-- and the fade cannot drift apart on a slow frame.
	takeCamera(shakeFrom, mine)

	-- ARMED A BEAT LATE, and the delay is not politeness. The crossing is booked
	-- by clicking GO on the ferryman's board, and a mouse button released on the
	-- same frame the bars come in would skip the whole thing before the player
	-- had seen a single shot of it. It also has to land after takeCamera, which
	-- is what sets the `camActive` this reads.
	task.delay(0.9, function()
		if tripToken == mine and camActive then
			skipArmed = true
			setSkipVisible(true)
		end
	end)

	-- The shot runs a quarter second past the last beat so the land ease settles
	-- before the default camera takes it back. The server's "done" normally beats
	-- this by a fraction; endCrossing is idempotent, so whichever wins is fine.
	task.delay(END_AT + 0.25, function()
		if tripToken == mine then
			endCrossing()
		end
	end)

	-- She is out past the point by board + cast + fight, and the server cuts at
	-- the same moment off the same constants.
	task.delay(CUT_AT, function()
		if tripToken ~= mine then
			return
		end
		TweenService:Create(veil, TweenInfo.new(TRIP.fade), { BackgroundTransparency = 0 }):Play()
		TweenService:Create(caption, TweenInfo.new(TRIP.fade), { TextTransparency = 0 }):Play()
	end)

	-- The lift, scheduled LOCALLY as well as being sent. The server fires
	-- "in" the moment the far boat is under them, and whichever arrives first
	-- wins by token.
	task.delay(LIFT_AT, function()
		if tripToken == mine and transit.Enabled then
			liftIn(mine)
		end
	end)

	--[[
		THE WATCHDOG, and it is the reason this is safe to run without a
		handshake at all.

		If every message is lost -- or the server errors between the cut and the
		landing -- the player is left looking at a black screen with no way out,
		which is the single worst failure this feature can have. So the lift is
		also scheduled well past the point where it should already have
		happened, and whichever fires first wins by token.
	]]
	task.delay(END_AT + 4, function()
		if tripToken ~= mine then
			return
		end
		endCrossing()
		if transit.Enabled then
			liftIn(mine)
		end
	end)
end

----------------------------------------------------------------
-- IDLE MOTION
----------------------------------------------------------------
--[[
	The boat rolls; the man breathes. Both are anchored parts written LOCALLY,
	so nothing here replicates and nothing costs the server a byte -- the same
	arrangement the desert's camel walks on.

	CAPTURED ON APPROACH, NOT AT BOOT. StreamingEnabled is on and two of these
	berths are 1500 studs from wherever the player is standing, so their parts
	genuinely do not exist on this client most of the time. A one-shot resolve at
	boot would capture an empty model and animate nothing for the session, which
	is precisely how the camel stood still before it learned to re-resolve. So a
	rig is captured when the player comes into range and dropped -- and put back
	exactly where the server left it -- when they leave.

	THE SWELL RIDES ON WHEREVER THE SERVER HAS PUT HER, and that is the one
	thing this had to learn when the boats started moving. It used to capture
	the root's CFrame once, at the moment the rig came into range, and drive
	everything off that stored `base` for as long as the player stayed near.
	That was correct while a boat was a permanent fixture of the pier. It is not
	any more: the server drives the whole model out to sea during a crossing, so
	a stored base means this file drags the hull, the sail and the deck back to
	the mooring every frame while the root sails off without them -- the boat
	comes apart. Read live off the root instead, which is the only part the
	server writes that this file never does.

	The amplitudes are small on purpose. The deck is collidable and a passenger
	stands on it, and a player on a deck that heaves is a player being shoved
	around by a decoration; a tenth of a stud reads as afloat and moves nobody.
]]
local RIG_RANGE = 120
local BOAT_BOB, BOAT_ROLL, BOAT_PITCH = 0.12, 0.022, 0.014
local MAN_BOB, MAN_SWAY = 0.055, 0.035

local rigs = {}          -- [Model] = { root, base, parts, kind, phase }

local function capture(model: Instance?, kind: string, phase: number)
	if not model then
		return nil
	end
	local rootPart = model:FindFirstChild("Root")
	if not (rootPart and rootPart:IsA("BasePart")) then
		return nil
	end
	local parts = {}
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") and p ~= rootPart then
			table.insert(parts, { part = p, offset = rootPart.CFrame:ToObjectSpace(p.CFrame) })
		end
	end
	if #parts == 0 then
		return nil
	end
	return { root = rootPart, parts = parts, kind = kind, phase = phase }
end

local function releaseRig(rig)
	-- Put every part back where the server has it, so a rig that streams out
	-- mid-swell is not left frozen a tenth of a stud off true. Off the root's
	-- CURRENT frame, not a stored one -- see the note above.
	if not rig.root.Parent then
		return
	end
	local base = rig.root.CFrame
	for _, e in ipairs(rig.parts) do
		if e.part.Parent then
			e.part.CFrame = base * e.offset
		end
	end
end

local function stepRig(rig, t: number)
	local anim
	if rig.kind == "boat" then
		local ph = t + rig.phase
		-- Roll is about X because the beam runs along Z on every one of these
		-- hulls, and pitch is about Z for the same reason. Getting the two the
		-- wrong way round gives a boat that see-saws end over end.
		anim = CFrame.new(0, math.sin(ph * 0.75) * BOAT_BOB, 0)
			* CFrame.Angles(math.sin(ph * 0.62 + 0.7) * BOAT_ROLL, 0,
				math.sin(ph * 0.50 + 1.9) * BOAT_PITCH)
	else
		local ph = t + rig.phase
		anim = CFrame.new(0, math.sin(ph * 1.15) * MAN_BOB, 0)
			* CFrame.Angles(0, math.sin(ph * 0.47) * MAN_SWAY, 0)
	end
	local base = rig.root.CFrame * anim
	for _, e in ipairs(rig.parts) do
		if e.part.Parent then
			e.part.CFrame = base * e.offset
		end
	end
end

local ferries = nil
local scanTimer = 0
local live = {}          -- the rigs currently being driven

local function rescan()
	-- Re-resolved rather than held. The folder is destroyed and rebuilt on every
	-- server boot, and a cached handle to a destroyed one would silently stop
	-- every boat in the game with nothing in the log to say so.
	if ferries and not ferries.Parent then
		ferries = nil
		rigs = {}
		table.clear(live)
	end
	ferries = ferries or workspace:FindFirstChild("Ferries")
	if not ferries then
		return
	end
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		for _, rig in ipairs(live) do
			releaseRig(rig)
		end
		table.clear(live)
		return
	end

	local wanted = {}
	for i, berth in ipairs(ferries:GetChildren()) do
		local boat = berth:FindFirstChild("Boat")
		local anchorPart = boat and boat:FindFirstChild("Root")
		if anchorPart and (anchorPart.Position - hrp.Position).Magnitude <= RIG_RANGE then
			wanted[berth] = i
		end
	end

	-- Drop anything that has gone out of range or out of the world.
	for idx = #live, 1, -1 do
		local rig = live[idx]
		if not (rig.root.Parent and wanted[rig.berth]) then
			releaseRig(rig)
			rigs[rig.model] = nil
			table.remove(live, idx)
		end
	end

	-- and pick up anything new that has come into it.
	--
	-- ONE RIG A BERTH NOW, not two. The ferryman used to be a sibling of the
	-- boat with a rig of his own; he stands ON her, so he is a descendant of
	-- the boat model and `capture` sweeps him up with the planks he is standing
	-- on. He therefore rolls with her, for free, and there is no second rig to
	-- keep in phase with the first.
	for berth, i in pairs(wanted) do
		for _, spec in ipairs({ { "Boat", "boat" } }) do
			local model = berth:FindFirstChild(spec[1])
			if model and not rigs[model] then
				local rig = capture(model, spec[2], i * 1.7)
				if rig then
					rig.model = model
					rig.berth = berth
					rigs[model] = rig
					table.insert(live, rig)
				end
			end
		end
	end
end

RunService.Heartbeat:Connect(function(dt)
	scanTimer -= dt
	if scanTimer <= 0 then
		scanTimer = 0.7
		-- Cheap: three distance checks, and it is the only thing that runs at
		-- all when the player is nowhere near a pier.
		local ok, err = pcall(rescan)
		if not ok then
			warn("[Ferry] rig scan: " .. tostring(err))
		end
	end
	if #live == 0 then
		return
	end
	local t = workspace:GetServerTimeNow()
	for _, rig in ipairs(live) do
		if rig.root.Parent then
			stepRig(rig, t)
		end
	end
end)

-- The folder is rebuilt on every server boot, so the handle is re-resolved
-- rather than held: a cached reference to a destroyed folder would silently
-- stop every boat in the game.
workspace.ChildAdded:Connect(function(child)
	if child.Name == "Ferries" then
		ferries = child
		rigs = {}
		table.clear(live)
	end
end)

----------------------------------------------------------------
-- WIRING
----------------------------------------------------------------
task.spawn(function()
	local folder = ReplicatedStorage:WaitForChild(FerryConfig.RemoteFolder, 120)
	if not folder then
		warn("[Ferry] FerryRemotes never appeared -- is FerryServer started? "
			.. "The boats are still there; the ferrymen will not answer.")
		return
	end
	remotes = folder

	folder.FerryMenu.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		local port = FerryConfig.port(payload.at)
		if not port then
			return
		end
		--[[
			NOT WHILE THE SHOT IS RUNNING.

			This is the actual reason the SAIL button was still on screen during
			a crossing, and closing the panel at cast-off was never going to fix
			it: the server offers the board whenever the player is near a
			ferryman, and for the whole voyage she is standing next to one. So
			castOff closed the panel and the very next FerryMenu re-opened it,
			over the cinematic, sail button and all.

			The server is not wrong to keep offering -- it has no idea a shot is
			playing. This is the one place that does.
		]]
		if camActive then
			return
		end
		openTalk(port, typeof(payload.near) == "Vector3" and payload.near or nil)
	end)

	folder.FerryTrip.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		if payload.phase == "out" then
			castOff(payload)
		elseif payload.phase == "in" then
			-- The far boat is under them. Scheduled locally too, off the same
			-- constants; whichever gets there first wins by token.
			liftIn(tripToken)
		elseif payload.phase == "done" then
			-- Ashore. A no-op on a crossing that went to plan, and the last
			-- chance to lift -- and to put the camera straight -- on one that
			-- did not. The shake has its own deadline as well; this just means
			-- a crossing that ended early does not keep rolling for the rest of
			-- the beats it never sailed.
			endCrossing()
			liftIn(tripToken)
		end
	end)

	-- Refusals the SERVER makes -- walking away from the pier with the panel
	-- open, mostly. Through ToastKit rather than the speech line, because by
	-- then the panel is shut and the man is behind you.
	folder.FerryResult.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		ToastKit.toast(tostring(payload.message), payload.ok and "info" or "deny", 2.6)
	end)
end)

print("[Ferry] client ready \u{2014} panel, idle swell and the crossing armed")