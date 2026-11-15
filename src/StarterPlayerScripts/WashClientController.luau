--[[
	WashClientController  --  StarterPlayerScripts.WashClientController

	Everything the player feels while washing: aiming, the jet, the impact
	spray, chunks cracking off, the motor, and the wet reveal underneath.

	It owns none of the truth. It picks a target and renders what the server
	says happened.

	----------------------------------------------------------------------
	AIMING
	----------------------------------------------------------------------
	The camera goes Scriptable and frames the stand, so the lump is a fixed
	target and the mouse is free to move over it. A ray from the cursor is
	filtered to the crust folder ONLY -- chunks are the only CanQuery parts in
	the model, so whatever the ray hits IS the chunk index to report. As chunks
	are destroyed the ray falls through to the ones behind, and the shell
	hollows out from wherever you have been pointing.

	`camera:ViewportPointToRay` is the correct pairing, and the note that used
	to sit here had it exactly backwards -- it cost a bug report that read as
	"the washer will not hit the debris my cursor is on".

	GetMouseLocation DOES include the topbar inset, and that is precisely what
	makes it VIEWPORT space. ScreenPointToRay wants the inset EXCLUDED (what
	Mouse.X/Y gives), so feeding it GetMouseLocation aims the jet a full inset
	BELOW the cursor -- measured here at 58px, which is 5.763 degrees and very
	nearly two clump widths at the wash camera's 7.7-stud framing.

	Measured against the engine's own answer, which is the only tiebreaker
	worth having:
	  Mouse.X/Y                            = GetMouseLocation - GetGuiInset
	  ViewportPointToRay(GetMouseLocation) = mouse.UnitRay to 0.000 degrees
	  ScreenPointToRay(GetMouseLocation)   = mouse.UnitRay off by 5.763 degrees

	The RETICLE was never wrong. WashHud sets IgnoreGuiInset, so drawing it at
	GetMouseLocation puts it exactly on the pointer -- which is why this read as
	"the crosshair is on the clump and nothing happens" rather than as a
	crosshair that was visibly off. Ray and reticle must be measured against the
	OS cursor, never against each other; they agreed with each other while both
	disagreeing with the player.

	----------------------------------------------------------------------
	PREDICTION
	----------------------------------------------------------------------
	Erosion is drawn locally at the same rate the server uses, so the crust
	darkens under the jet with no round-trip. It is capped at 0.99: the actual
	POP is always a server event (WashChunkGone), so a chunk can never appear to
	break on a lie, and the reveal can never fire early.

	----------------------------------------------------------------------
	WHICH REMOTES THIS SPEAKS  --  read before renaming anything
	----------------------------------------------------------------------
	Wash*, not Sift*. This file spent a while wired to the Sift* remotes left
	over from the sifting-bay experiment while ServerMain was running WashServer,
	which fires Wash*. Nothing errored and nothing logged: WashBegin went out,
	no one on the client was listening, and the player got a lump on the stand,
	a washer in their hand, no HUD, no camera and no way to make the jet do
	anything. If the bay ever goes back to being a screen, swap SiftServer in on
	the server AND SiftClientController in on the client -- the two halves are a
	matched pair and either one alone is silent, not loud.

		C -> S   WashAim {chunk = i}, WashEndRequest, WashInstantRequest
		S -> C   WashBegin, WashEnd, WashProgress, WashChunkGone, WashItemCleaned,
		         WashInstant

	----------------------------------------------------------------------
	THE INSTANT WASH PASS
	----------------------------------------------------------------------
	The one Robux button in the bay. This file draws it and asks; it decides
	nothing. WashInstantRequest carries no payload at all, and whether anything
	happens is settled entirely on the server -- see WashServer.onInstantRequest.

	The OwnsInstantWash attribute this reads is the CLIENT'S COPY and is only
	ever good enough to choose between a BUY face and a USE face. A client that
	lies to itself about owning the pass gets a gold button and a refusal.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local MarketplaceService = game:GetService("MarketplaceService")
local Debris = game:GetService("Debris")
local CollectionService = game:GetService("CollectionService")
-- For the bay key: PromptShown/PromptHidden tell us the player is in range
-- without a distance poll of our own, and they fire for a Custom-styled prompt
-- that the engine is no longer drawing.
local ProximityPromptService = game:GetService("ProximityPromptService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local ItemConfig = require(Modules:WaitForChild("ItemConfig"))
local ItemVisuals = require(Modules:WaitForChild("ItemVisuals"))
local Net = require(Modules:WaitForChild("Net"))
local AudioKit = require(Modules:WaitForChild("AudioKit"))
local PassConfig = require(Modules:WaitForChild("PassConfig"))
local ToastKit = require(Modules:WaitForChild("ToastKit"))
-- The onboarding's easier jet, read here for the PREDICTION only. WashServer
-- reads the same module for the erosion that actually counts; the two have to
-- agree or the clump the player watches draining is not the clump the server
-- is draining. See the note over the boost in TutorialConfig.
local TutorialConfig = require(Modules:WaitForChild("TutorialConfig"))

-- Touch targets: see the module. Substituted for MouseButton1Click/Activated so
-- a tap in the margin around a control that renders under 44px on a phone still
-- reaches the same handler. No-ops on desktop and on controls already big enough.
local TouchFit = require(Modules:WaitForChild("TouchFit"))
-- For the bay key below: the house button, so the one control that destroys
-- finds looks like this game rather than like an engine default.
local PanelKit = require(Modules:WaitForChild("PanelKit"))

-- THE BAG, read for ONE thing: how many finds the pass button is about to
-- finish. The tap is the whole bag now (WashServer.bulkWash), so the button has
-- to be able to say so. Read-only mirror -- ClientMain starts it, this file only
-- counts what it holds.
local InventoryController = require(Modules:WaitForChild("InventoryController"))

-- The pass this bay sells. Read from PassConfig rather than typed here: the id
-- is also what GamePassService resolves ownership against, and a pass id
-- written down twice is a pass id that gets corrected once.
local INSTANT = PassConfig.Passes.InstantWash

local CFG = GameConfig.Washing

local player = Players.LocalPlayer

local function cam(): Camera
	return workspace.CurrentCamera
end

local WashClientController = {}

--[[
	THE SILT
	--------
	One chain, and the player can see every link of it:

		chunk blasts off  ->  a beat later its silt lands on the stand  ->  the
		jet and the running water wash it down  ->  the plate loads up anyway  ->
		it SLUICES off the edge into the drain pan  ->  the pan loads up  ->  the
		pan FLUSHES through the grates

	None of it is authoritative. Every gram is downstream of a WashChunkGone the
	server has already confirmed, so the pan can never show material the player
	did not actually blast loose -- and being local, it costs the server nothing
	and replicates nowhere.

	WHY THE STAND AND NOT JUST THE PAN. The drain pan is the obvious place to pile
	this, and it is nearly the wrong one: the wash camera frames the lump at head
	height and the pan sits five studs below it, right at the bottom edge of the
	shot or off it entirely. A player would never see the thing accumulating. The
	STAND PLATE is directly under the rock, dead centre of frame, with a 0.45-stud
	gap between plate and crust to fill -- so the build-up happens where they are
	already looking, and the sluice off its edge is what carries the eye down to
	the pan.

	The drain is a LEVEL, not a percentage. A bed that tracked overall progress
	could only ever grow, and the appeal is watching it wash away. It has to be
	able to go down, and it goes down faster under the jet -- so parking the jet
	on the rock cleans the plate as well as the rock, which is the right lesson.

	SILT_PER_CHUNK against the two drain rates puts a sluice roughly every
	SEVENTH of a lump: about twice a lump. Often enough to be a rhythm, rare
	enough to still be an event.

	THIS NUMBER IS PER CHUNK, SO IT MOVES WHEN THE CHUNK COUNT DOES.
	It was 0.34 when a lump was 14 pieces. At 34 pieces the plate takes the same
	total load from a lump but in two and a half times as many instalments, so
	per-instalment has to fall by the same factor: 0.34 * 14/34 = 0.14. Left at
	0.34 the plate would have filled about every three chunks -- roughly nine
	sluices a lump instead of two -- and the sluice would have stopped being an
	event and become the background state of the bay.
]]
local SILT_PER_CHUNK = 0.14 -- plate load one blasted chunk dumps, on a 0..1 bed
local SILT_DRAIN = 0.22     -- washed off per second by the water that is always running
local SILT_JET_DRAIN = 0.3  -- ...plus this much again while the jet is on the rock
local SILT_HEIGHT = 0.34    -- studs of bed at a full plate (the gap to the crust is 0.45)
local SILT_RESIDUE = 0.1    -- what stays on the plate after it sluices
local PAN_PER_SLUICE = 0.34 -- pan fill bought by one sluice off the plate
local PAN_RESIDUE = 0.12
local LAND_DELAY = 0.16     -- pop -> silt hitting the plate, seconds

--[[
	THE CHAIN
	---------
	Chunks broken without a gap longer than CHAIN_WINDOW, counted, walking up a
	pentatonic ladder one rung per chunk.

	The washer's skill is keeping the jet ON something -- so the chain measures
	exactly that, and measures it in chunks rather than in seconds, because a
	player holding the trigger on bare rock is not doing the thing. The bar
	already says how far through the lump they are, but a bar is a POSITION, and
	a note climbing is a run. It gives staying on target somewhere to go.

	The window is generous on purpose: losing a nine-chain to one slip of the
	mouse does not read as difficulty, it reads as unfairness, and people put the
	game down rather than concentrate harder.
]]
local CHAIN_WINDOW = 2.6
local LADDER = { 1.00, 1.12, 1.26, 1.50, 1.68, 1.89, 2.00, 2.25, 2.52, 2.83, 3.00 }

--------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------

local S = {
	active = false,
	bay = nil,
	stand = nil,
	model = nil,
	crust = nil,
	uid = nil,
	total = 0,
	remaining = 0,
	chunks = {},      -- index -> 0..1 predicted erosion
	chunkWork = 1,

	-- Set by WashItemCleaned and cleared by the next mount. updateHud runs every
	-- frame and rewrites the title, so the reveal has to live in STATE -- writing
	-- the real name straight onto the label lasted exactly one frame before the
	-- render loop put "Crusted Lump" back over it.
	revealName = nil,
	revealColor = nil,

	triggering = false,
	aimIndex = nil,
	aimPoint = nil,
	lastSend = 0,
	spray = 0,        -- smoothed 0..1, drives everything cosmetic

	-- Progress the HUD is DRAWING, chased toward the real figure every frame.
	-- The truth arrives in whole chunks -- 7% of the rock at a time -- and a bar
	-- that teleports in fourteen steps reads as a counter rather than as
	-- something coming apart under the jet. This also drives the slow dolly in,
	-- so the camera creeps closer as the find emerges.
	doneShown = 0,
	fired = false,    -- have they pulled the trigger yet this session?
	missTime = 0,     -- seconds the trigger has been held with nothing under the ray

	tool = nil,
	nozzle = nil,
	muzzle = nil,

	focusCFrame = nil,
	targetFocus = nil,
	prevCameraType = nil,
	prevCameraSubject = nil,
	kick = 0,
	kickVel = 0,

	-- What WalkSpeed was before the bay pinned them. See lockWalking: since
	-- 2026-09-09 this is only the FALLBACK for the restore -- the live
	-- BaseWalkSpeed attribute is asked first -- because BeachLegs means the
	-- number is different for every player AND can change during the wash.
	prevWalkSpeed = nil,

	chain = 0,        -- chunks broken without a gap longer than CHAIN_WINDOW
	chainStep = 0,    -- rung of LADDER the chain has reached
	lastChunk = 0,
	charge = 0,       -- 0..1 erosion on the chunk under the reticle right now
	flash = 0,        -- 0..1, decaying; every "something just happened" pushes it
}

-- How long the trigger may be held off-target before the hint stops being a
-- prompt and starts being a correction. Long enough not to nag someone lining a
-- shot up, short enough that nobody concludes the wash is broken.
local MISS_TELL = 1.1

local fx = { jet = nil, impact = nil, impactPart = nil }
local sounds = { motor = nil, spray = nil }
local hud = {}

-- What is lying on the stand plate right now, 0..1, and the slab that draws it.
local silt = { load = 0, bed = nil, fall = nil }

-- ...and where it ends up. `fill` trails `target` rather than tracking it, which
-- is the whole difference between a pan filling and a number rising.
local pan = { root = nil, mounds = {}, fill = 0, target = 0, impact = 0, drain = nil }

local function pressure(): number
	return player:GetAttribute("WasherPressure") or GameConfig.Washer.Levels[1].pressure
end

-- Whether to draw a BUY face or a USE face, and nothing more than that. The
-- server never asks this question of the client -- see the header.
local function passOwned(): boolean
	return PassConfig.owns(player, INSTANT.key)
end

-- Last time the use button actually sent. The server holds a cooldown of its
-- own and would drop the extras anyway; this stops the button LOOKING broken
-- while it does, which is the part the player experiences.
local passSent = 0

--[[
	THE SAME ANSWER, CACHED, because the render loop asks it every frame.

	Written by refreshPass and by nothing else, so what the JET does and what the
	BUTTON says come from one read of one attribute. They could have been two
	calls to passOwned() and they must not be: a frame where the reticle melts
	clumps under a grape BUY button is a bug report about the pass not working.
]]
local instantOwned = false

--[[
	HOW MANY CRUSTED FINDS ARE IN THE BAG, for the pass button's label.

	CACHED OFF Client.Changed RATHER THAN COUNTED IN updateHud, which runs every
	rendered frame -- and the answer only ever changes when an InventorySync
	lands, which the server already coalesces to at most one a frame.

	It does NOT include the lump on the stand: that record's state is "Washing",
	not "Crusted". The label adds it back, because the tap finishes that one too.
]]
local crustedInBag = 0

--------------------------------------------------------------------------
-- HUD
--------------------------------------------------------------------------

--[[
	THE CARTOON KIT  --  because this panel used to be from a different game.

	Every other surface in Clean the Beach (CTB_HUD's coin pill, MenuHud's rail,
	the sell receipt) is built from the same four things: a SHADOW SLAB offset
	down behind the face, a THICK near-black OUTLINE, a white GLOSS CAP across
	the top, and BACK EASING on every tween. This card was a flat dark rectangle
	with Gotham text and a hairline bar -- against the rest of the screen it read
	as a debug overlay rather than as part of the game. Same kit now.
]]
local C = {
	ink       = Color3.fromRGB(56, 36, 20),
	cream     = Color3.fromRGB(255, 250, 238),
	panelTop  = Color3.fromRGB(72, 100, 128),
	panelBot  = Color3.fromRGB(26, 38, 54),
	track     = Color3.fromRGB(20, 26, 36),
	water     = Color3.fromRGB(126, 216, 255),
	waterDeep = Color3.fromRGB(34, 130, 212),
	foam      = Color3.fromRGB(196, 248, 255),
	gold      = Color3.fromRGB(255, 232, 140),
	-- The pass button's two faces. Grape is what the car showroom paints its
	-- Robux buttons, so "this one costs real money" means the same thing in
	-- both places; gold is the game's own "you own this" colour.
	grape     = Color3.fromRGB(170, 114, 238),
	grapeDeep = Color3.fromRGB(94, 46, 166),
	goldTop   = Color3.fromRGB(255, 214, 120),
	goldDeep  = Color3.fromRGB(198, 132, 22),
}

local function corner(inst: Instance, r: number)
	local x = Instance.new("UICorner")
	x.CornerRadius = UDim.new(0, r)
	x.Parent = inst
	return x
end

local function pill(inst: Instance)
	local x = Instance.new("UICorner")
	x.CornerRadius = UDim.new(1, 0)
	x.Parent = inst
	return x
end

local function outline(inst: Instance, thick: number, col: Color3?)
	local st = Instance.new("UIStroke")
	st.Thickness = thick
	st.Color = col or C.ink
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.LineJoinMode = Enum.LineJoinMode.Round
	st.Parent = inst
	return st
end

-- Outlines the GLYPHS rather than boxing the label. Contextual is what makes
-- LuckiestGuy read as a sticker instead of as text sitting on a dark panel.
local function textOutline(inst: Instance, thick: number, col: Color3?)
	local st = Instance.new("UIStroke")
	st.Thickness = thick
	st.Color = col or C.ink
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	st.LineJoinMode = Enum.LineJoinMode.Round
	st.Parent = inst
	return st
end

-- A UIGradient MULTIPLIES against whatever is underneath, so anything
-- gradient-filled has to sit on white or the two tint each other. Same trap
-- CTB_HUD documents: it is what turned its panels near-black.
local function grad(inst: GuiObject, top: Color3, bottom: Color3, rot: number?)
	inst.BackgroundColor3 = Color3.new(1, 1, 1)
	if inst:IsA("TextLabel") then
		inst.TextColor3 = Color3.new(1, 1, 1)
	end
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(top, bottom)
	g.Rotation = rot or 90
	g.Parent = inst
	return g
end

local function gloss(face: GuiObject, r: number)
	local g = Instance.new("Frame")
	g.Name = "Gloss"
	g.BackgroundColor3 = Color3.new(1, 1, 1)
	g.BorderSizePixel = 0
	g.Size = UDim2.new(1, -12, 0.44, 0)
	g.Position = UDim2.fromOffset(6, 5)
	g.ZIndex = face.ZIndex + 1
	g.Parent = face
	corner(g, math.max(4, r - 4))
	local gg = Instance.new("UIGradient")
	gg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(0.7, 0.88),
		NumberSequenceKeypoint.new(1, 1),
	})
	gg.Rotation = 90
	gg.Parent = g
	return g
end

local function label(parent: Instance, str: string, size: number, font: Enum.Font, col: Color3)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Font = font
	t.Text = str
	t.TextSize = size
	t.TextColor3 = col
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.TextTruncate = Enum.TextTruncate.AtEnd
	t.ZIndex = 4
	t.Parent = parent
	return t
end

local CARD_W, CARD_H = 560, 132

--[[
	THE ROW ABOVE THE CARD IS A FIXED BUDGET, AND IT IS NOW FULL.

	Three things live in the 40px band that sits on top of the card, and 560
	pixels is all there is. Left to right, card-local:

		INSTANT     0..170     the pass button
		chain pip   201..359   centred, and only from a chain of 3
		Q key       382..406   keyboard only
		LEAVE       414..560

	The gaps are 31 and 23. Widening any of these takes the space from a
	neighbour -- there is nowhere else for the row to go. It cannot grow UPWARD
	either: the card was moved down to -24 precisely because a top edge 260px up
	the screen covers the bottom of the rock the player is aiming at, and a
	second row of controls would put itself right back in front of it.
]]
local PASS_W = 170

local function buildHud()
	local gui = Instance.new("ScreenGui")
	gui.Name = "WashHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 9
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	------------------------------------------------------------------
	-- THE CARD
	------------------------------------------------------------------
	local holder = Instance.new("Frame")
	holder.Name = "Root"
	holder.AnchorPoint = Vector2.new(0.5, 1)
	-- Sat at -128, which put a 132-tall card's top edge 260px up the screen --
	-- high enough to cover the bottom of the rock it is reporting on. The lump
	-- is the thing the player is aiming at; the readout has no business in front
	-- of it. Parked at the bottom edge instead.
	--
	-- ToastKit's WASH_CARD_REACH mirrors this HUD's TOP EDGE so the notification
	-- column knows how far to lift while the card is up -- and the top edge is
	-- the PASS/LEAVE row hanging above this card (passHolder, ~50 lines down),
	-- not the card itself. It read 156 (this card's top) until 2026-09-09, which
	-- parked every banner squarely across the INSTANT WASH button. Move this,
	-- the row, or CARD_H, and move ToastKit's number with it.
	holder.Position = UDim2.new(0.5, 0, 1, -24)
	holder.Size = UDim2.fromOffset(CARD_W, CARD_H)
	holder.BackgroundTransparency = 1
	holder.Parent = gui

	local cardScale = Instance.new("UIScale")
	cardScale.Parent = holder

	local shade = Instance.new("Frame")
	shade.Name = "Shade"
	shade.Size = UDim2.fromScale(1, 1)
	shade.Position = UDim2.fromOffset(0, 7)
	shade.BackgroundColor3 = C.ink
	shade.BackgroundTransparency = 0.4
	shade.BorderSizePixel = 0
	shade.ZIndex = 1
	shade.Parent = holder
	corner(shade, 20)

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.fromScale(1, 1)
	body.BorderSizePixel = 0
	body.ZIndex = 2
	body.Parent = holder
	corner(body, 20)
	grad(body, C.panelTop, C.panelBot)
	outline(body, 4)
	gloss(body, 20)

	-- TITLE. "CRUSTED LUMP" until the server says what it actually was.
	local title = label(body, string.upper(ItemConfig.LumpDisplayName), 30,
		Enum.Font.LuckiestGuy, C.cream)
	title.Name = "Title"
	title.Position = UDim2.fromOffset(22, 12)
	title.Size = UDim2.new(1, -200, 0, 36)
	textOutline(title, 3)

	-- PERCENT. Gold, gradient-filled, with its own hard shadow -- it is the one
	-- number the player is actually watching, so it gets the same treatment
	-- CTB_HUD gives the coin count.
	local pctShade = label(body, "0%", 40, Enum.Font.LuckiestGuy, Color3.fromRGB(92, 46, 6))
	pctShade.Name = "PercentShade"
	pctShade.AnchorPoint = Vector2.new(1, 0)
	pctShade.Position = UDim2.new(1, -22, 0, 12)
	pctShade.Size = UDim2.fromOffset(170, 46)
	pctShade.TextXAlignment = Enum.TextXAlignment.Right

	local pct = label(body, "0%", 40, Enum.Font.LuckiestGuy, C.gold)
	pct.Name = "Percent"
	pct.AnchorPoint = Vector2.new(1, 0)
	pct.Position = UDim2.new(1, -22, 0, 9)
	pct.Size = UDim2.fromOffset(170, 46)
	pct.TextXAlignment = Enum.TextXAlignment.Right
	pct.ZIndex = 5
	grad(pct, Color3.fromRGB(255, 246, 186), Color3.fromRGB(255, 186, 42))
	textOutline(pct, 3.5, Color3.fromRGB(64, 28, 2))
	local pctScale = Instance.new("UIScale")
	pctScale.Parent = pct

	------------------------------------------------------------------
	-- THE BAR
	--
	-- One notch per chunk, drawn OVER the fill, so the bar is visibly a rock in
	-- fourteen pieces rather than an abstract percentage. Watching a whole
	-- segment light up is most of why popping a chunk feels like anything.
	------------------------------------------------------------------
	local track = Instance.new("Frame")
	track.Name = "BarBg"
	track.Position = UDim2.fromOffset(22, 58)
	track.Size = UDim2.new(1, -44, 0, 26)
	track.BackgroundColor3 = C.track
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.ZIndex = 4
	track.Parent = body
	pill(track)
	outline(track, 3)

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.Size = UDim2.fromScale(0, 1)
	bar.BorderSizePixel = 0
	bar.ZIndex = 5
	bar.Parent = track
	pill(bar)
	local fillGrad = grad(bar, C.water, C.waterDeep)

	-- A highlight that slides along the wet part of the bar. Cheap, and it is
	-- what stops a static fill reading as a screenshot.
	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.Size = UDim2.fromScale(1, 1)
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
	shine.BorderSizePixel = 0
	shine.ZIndex = 6
	shine.Parent = bar
	local shineGrad = Instance.new("UIGradient")
	shineGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.42, 1),
		NumberSequenceKeypoint.new(0.5, 0.6),
		NumberSequenceKeypoint.new(0.58, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	shineGrad.Parent = shine

	local notches = Instance.new("Folder")
	notches.Name = "Notches"
	notches.Parent = track

	------------------------------------------------------------------
	-- BOTTOM ROW  --  tier pill on the left, contextual line on the right
	------------------------------------------------------------------
	local tier = Instance.new("Frame")
	tier.Name = "Tier"
	tier.Position = UDim2.fromOffset(22, 92)
	tier.Size = UDim2.fromOffset(212, 28)
	tier.BackgroundColor3 = Color3.fromRGB(16, 24, 34)
	tier.BackgroundTransparency = 0.15
	tier.BorderSizePixel = 0
	tier.ZIndex = 4
	tier.Parent = body
	pill(tier)
	outline(tier, 2.5)

	local drop = Instance.new("Frame")
	drop.Name = "Drop"
	drop.AnchorPoint = Vector2.new(0, 0.5)
	drop.Position = UDim2.new(0, 8, 0.5, 0)
	drop.Size = UDim2.fromOffset(14, 14)
	drop.BorderSizePixel = 0
	drop.ZIndex = 5
	drop.Parent = tier
	pill(drop)
	grad(drop, C.foam, C.waterDeep)

	local tierText = label(tier, "Garden Hose", 15, Enum.Font.GothamBold, C.cream)
	tierText.Name = "Label"
	tierText.Position = UDim2.fromOffset(30, 0)
	tierText.Size = UDim2.new(1, -36, 1, 0)
	tierText.ZIndex = 5

	local hint = label(body, "", 16, Enum.Font.GothamBold, C.foam)
	hint.Name = "Hint"
	hint.AnchorPoint = Vector2.new(1, 0)
	hint.Position = UDim2.new(1, -22, 0, 92)
	hint.Size = UDim2.fromOffset(304, 28)
	hint.TextXAlignment = Enum.TextXAlignment.Right
	textOutline(hint, 2, Color3.fromRGB(14, 22, 30))

	------------------------------------------------------------------
	-- RETICLE
	------------------------------------------------------------------
	local ret = Instance.new("Frame")
	ret.Name = "Reticle"
	ret.AnchorPoint = Vector2.new(0.5, 0.5)
	ret.Size = UDim2.fromOffset(46, 46)
	ret.BackgroundTransparency = 1
	ret.BorderSizePixel = 0
	ret.ZIndex = 10
	ret.Parent = gui

	local retScale = Instance.new("UIScale")
	retScale.Parent = ret

	local ring = Instance.new("Frame")
	ring.Name = "Ring"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromScale(0.62, 0.62)
	ring.BackgroundTransparency = 1
	ring.ZIndex = 11
	ring.Parent = ret
	pill(ring)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = C.foam
	stroke.Transparency = 0.3
	stroke.Parent = ring

	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(3, 3)
	dot.BackgroundColor3 = C.foam
	dot.BorderSizePixel = 0
	dot.ZIndex = 12
	dot.Parent = ret
	pill(dot)

	-- THE CHARGE CORE. Fills the reticle as the chunk under it erodes.
	--
	-- Until this existed the player had no idea how close the thing they were
	-- pointing at was to letting go: the crust darkens, but that is a subtle cue
	-- on a small object behind a wall of spray, and the actual pop arrived as a
	-- surprise every time. A dot that swells to fill the ring turns every chunk
	-- into a short countdown the player can feel ending, which is the difference
	-- between holding a trigger down and finishing something.
	local core = Instance.new("Frame")
	core.Name = "Core"
	core.AnchorPoint = Vector2.new(0.5, 0.5)
	core.Position = UDim2.fromScale(0.5, 0.5)
	core.Size = UDim2.fromOffset(0, 0)
	core.BackgroundColor3 = Color3.fromRGB(150, 245, 178)
	core.BackgroundTransparency = 0.2
	core.BorderSizePixel = 0
	core.ZIndex = 11
	core.Parent = ret
	pill(core)

	------------------------------------------------------------------
	-- THE CHAIN CHIP  --  floats above the card, CENTRED
	--
	-- Hidden below 3. A counter reading "x1" on the first chunk of every lump is
	-- wallpaper; it has to APPEAR, as the reward for having already done
	-- something, or it is one more number on a panel of numbers. Above the card
	-- rather than inside it, because the percentage already owns that corner and
	-- two numbers in one corner is how you get neither of them read.
	--
	-- IT USED TO BE ANCHORED TO THE TOP-RIGHT, AND IT SAT ON THE LEAVE BUTTON.
	-- At (1, -8) it spanned card-local 394..552 against LEAVE's 414..560, with a
	-- ZIndex of 6 against LEAVE's 3 -- so from a three-chain onward the only way
	-- out of the bay was a strip of red under a pill saying CHAIN x7, and
	-- clicking the visible part of it did nothing because the chip was on top.
	-- Since the chain climbs all wash and the window is generous, that is most
	-- of a session with no working exit.
	--
	-- Centring it is what fixes it for good rather than for now: the two ends of
	-- this row are the two CONTROLS, and the readout belongs between them where
	-- it cannot be in front of either. See the row budget above CARD_W.
	------------------------------------------------------------------
	local chainChip = Instance.new("Frame")
	chainChip.Name = "ChainChip"
	chainChip.AnchorPoint = Vector2.new(0.5, 1)
	chainChip.Position = UDim2.new(0.5, 0, 0, -10)
	chainChip.Size = UDim2.fromOffset(158, 34)
	chainChip.BackgroundColor3 = Color3.fromRGB(24, 34, 46)
	chainChip.BorderSizePixel = 0
	chainChip.Visible = false
	chainChip.ZIndex = 6
	chainChip.Parent = holder
	pill(chainChip)
	outline(chainChip, 3)

	local chain = label(chainChip, "", 20, Enum.Font.LuckiestGuy, C.gold)
	chain.Name = "Chain"
	chain.Size = UDim2.fromScale(1, 1)
	chain.TextXAlignment = Enum.TextXAlignment.Center
	chain.ZIndex = 7
	textOutline(chain, 3)

	-- Scaled from the CHIP, so a punch grows the whole pill rather than pushing
	-- the glyphs out through its own outline.
	local chainScale = Instance.new("UIScale")
	chainScale.Parent = chainChip

	-- A white sheet over the bar fill, driven by the same decaying S.flash every
	-- other bang uses. ONE number, so two events landing together brighten the
	-- panel once rather than fighting over the same pixels.
	local barFlash = Instance.new("Frame")
	barFlash.Name = "BarFlash"
	barFlash.Size = UDim2.fromScale(1, 1)
	barFlash.BackgroundColor3 = Color3.new(1, 1, 1)
	barFlash.BackgroundTransparency = 1
	barFlash.BorderSizePixel = 0
	barFlash.ZIndex = 7
	barFlash.Parent = bar

	-- The card's own outline IS the reactive edge -- a second UIStroke on the
	-- same frame would simply never render. It brightens and thickens while the
	-- jet is doing work: the only feedback here a player can read WITHOUT
	-- looking away from the rock, and looking away is what costs them the chain.
	local edge = body:FindFirstChildOfClass("UIStroke")

	------------------------------------------------------------------
	-- THE FINISH  --  a full-screen flash and a stamp, both idle at zero
	------------------------------------------------------------------
	local flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = Color3.new(1, 1, 1)
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.ZIndex = 20
	flash.Parent = gui

	local stamp = label(gui, "CLEAN!", 74, Enum.Font.LuckiestGuy, C.cream)
	stamp.Name = "Stamp"
	stamp.AnchorPoint = Vector2.new(0.5, 0.5)
	stamp.Position = UDim2.fromScale(0.5, 0.33)
	stamp.Size = UDim2.fromOffset(760, 96)
	stamp.TextXAlignment = Enum.TextXAlignment.Center
	stamp.TextTransparency = 1
	stamp.ZIndex = 21
	local stampStroke = textOutline(stamp, 6)
	stampStroke.Transparency = 1
	local stampScale = Instance.new("UIScale")
	stampScale.Scale = 0.4
	stampScale.Parent = stamp

	------------------------------------------------------------------
	-- THE WAY OUT
	--
	-- Leaving was Q or Backspace and nothing else -- no affordance anywhere on
	-- screen saying so, and no key at all on touch. Walking out of range does
	-- end the session, but that is a thing you discover by accident rather than
	-- a way out you can see, and it is not available at all once a session locks
	-- the character (see setControls).
	--
	-- ABOVE the card, right-aligned. Every row inside the card is spoken for,
	-- and a control set among the readouts reads as one more readout. Its own
	-- ink outline and the shade slab under it are the card's, so it belongs to
	-- the same object without being part of the layout.
	------------------------------------------------------------------
	local exitShade = Instance.new("Frame")
	exitShade.Name = "ExitShade"
	exitShade.AnchorPoint = Vector2.new(1, 1)
	exitShade.Position = UDim2.new(1, 0, 0, -8)
	exitShade.Size = UDim2.fromOffset(146, 40)
	exitShade.BackgroundColor3 = C.ink
	exitShade.BackgroundTransparency = 0.4
	exitShade.BorderSizePixel = 0
	exitShade.ZIndex = 1
	exitShade.Parent = holder
	corner(exitShade, 12)

	local exit = Instance.new("TextButton")
	exit.Name = "Exit"
	exit.AnchorPoint = Vector2.new(1, 1)
	exit.Position = UDim2.new(1, 0, 0, -14)
	exit.Size = UDim2.fromOffset(146, 40)
	exit.BackgroundColor3 = Color3.fromRGB(178, 62, 54)
	exit.BorderSizePixel = 0
	exit.AutoButtonColor = false
	exit.Font = Enum.Font.LuckiestGuy
	exit.TextSize = 20
	exit.TextColor3 = C.cream
	exit.Text = "\u{2715}  LEAVE"
	exit.ZIndex = 3
	exit.Parent = holder
	corner(exit, 12)
	outline(exit, 4)
	grad(exit, Color3.fromRGB(214, 86, 76), Color3.fromRGB(138, 42, 36))
	textOutline(exit, 3)

	-- The keyboard shortcut still exists and is worth teaching, but it does not
	-- belong ON the button: a touch player cannot use it and would be reading an
	-- instruction that is false for them.
	local exitKey = label(holder, "Q", 15, Enum.Font.GothamBold, C.cream)
	exitKey.Name = "ExitKey"
	exitKey.AnchorPoint = Vector2.new(1, 1)
	exitKey.Position = UDim2.new(1, -154, 0, -22)
	exitKey.Size = UDim2.fromOffset(24, 24)
	exitKey.TextXAlignment = Enum.TextXAlignment.Center
	exitKey.TextTransparency = 0.25
	exitKey.ZIndex = 3
	exitKey.Visible = UserInputService.KeyboardEnabled

	local EXIT_IDLE = Color3.fromRGB(178, 62, 54)
	local EXIT_HOT = Color3.fromRGB(220, 92, 82)
	exit.MouseEnter:Connect(function()
		TweenService:Create(exit, TweenInfo.new(0.12), { BackgroundColor3 = EXIT_HOT }):Play()
	end)
	exit.MouseLeave:Connect(function()
		TweenService:Create(exit, TweenInfo.new(0.12), { BackgroundColor3 = EXIT_IDLE }):Play()
	end)
	exit.MouseButton1Down:Connect(function()
		TweenService:Create(exit, TweenInfo.new(0.06), { Position = UDim2.new(1, 0, 0, -9) }):Play()
	end)
	exit.MouseButton1Up:Connect(function()
		TweenService:Create(exit, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Position = UDim2.new(1, 0, 0, -14) }):Play()
	end)
	-- Activated rather than MouseButton1Click: it fires for a touch tap too,
	-- which is most of the reason this button is here.
	TouchFit.activated(exit, function()
		Net.get("WashEndRequest"):FireServer()
	end)

	------------------------------------------------------------------
	-- INSTANT WASH  --  the game pass, and the only Robux button in the bay
	--
	-- LEFT, at the opposite end of the row from LEAVE, and that is a rule
	-- rather than a layout preference. A purchase button under the thumb of
	-- somebody reaching for the way out is a mis-tap that opens a Robux dialog,
	-- and no amount of styling makes that acceptable. Opposite corners, with
	-- the chain pip between them.
	--
	-- ONE OBJECT, TWO FACES, rather than two buttons swapped. A player who buys
	-- the pass mid-session should watch the thing they just pressed BECOME the
	-- thing they bought; a button that disappears and is replaced by a different
	-- one elsewhere reads as the purchase having gone somewhere. Only the fill
	-- and the price badge change.
	--
	-- THE LABEL IS ITS OWN TEXTLABEL, not the button's Text. A UIGradient tints
	-- the text of the object it sits on as well as the fill, and this fill
	-- changes colour with the state -- so the label would go grape and then
	-- gold with it. A child is outside the gradient's reach and stays cream.
	------------------------------------------------------------------
	local passHolder = Instance.new("Frame")
	passHolder.Name = "PassHolder"
	passHolder.AnchorPoint = Vector2.new(0, 1)
	passHolder.Position = UDim2.new(0, 0, 0, -8)
	passHolder.Size = UDim2.fromOffset(PASS_W, 46)
	passHolder.BackgroundTransparency = 1
	-- Off until a session says otherwise. updateHud owns it from there.
	passHolder.Visible = false
	passHolder.Parent = holder

	-- Its own UIScale so hover can nudge it. The fill is a gradient and a
	-- gradient cannot be tweened, so the usual BackgroundColor3 hover the exit
	-- button uses is not available here.
	local passScale = Instance.new("UIScale")
	passScale.Parent = passHolder

	local passShade = Instance.new("Frame")
	passShade.Name = "PassShade"
	passShade.Position = UDim2.fromOffset(0, 6)
	passShade.Size = UDim2.fromOffset(PASS_W, 40)
	passShade.BackgroundColor3 = C.ink
	passShade.BackgroundTransparency = 0.4
	passShade.BorderSizePixel = 0
	passShade.ZIndex = 1
	passShade.Parent = passHolder
	corner(passShade, 12)

	local pass = Instance.new("TextButton")
	pass.Name = "InstantWash"
	pass.Position = UDim2.fromOffset(0, 0)
	pass.Size = UDim2.fromOffset(PASS_W, 40)
	pass.BorderSizePixel = 0
	pass.AutoButtonColor = false
	pass.Text = ""
	pass.ZIndex = 3
	pass.Parent = passHolder
	corner(pass, 12)
	outline(pass, 4)
	local passGrad = grad(pass, C.grape, C.grapeDeep)
	gloss(pass, 12)

	local passLabel = label(pass, "INSTANT WASH", 17, Enum.Font.LuckiestGuy, C.cream)
	passLabel.Name = "Label"
	passLabel.Size = UDim2.fromScale(1, 1)
	passLabel.TextXAlignment = Enum.TextXAlignment.Center
	passLabel.ZIndex = 5
	textOutline(passLabel, 3)

	-- THE PRICE RIDES THE CORNER, the way the showroom's does. A price on a
	-- button means "this is for sale"; its ABSENCE, on the same button in the
	-- owned colour, means "this is yours, press it". That is the whole state
	-- machine, and it is one badge rather than two labels of wording.
	local passBadge = Instance.new("Frame")
	passBadge.Name = "PriceBadge"
	passBadge.AnchorPoint = Vector2.new(1, 0)
	-- -18, not -11. The label is centred in a 40px face at TextSize 17, so its
	-- glyphs run from about y=11 down; a badge whose bottom edge sat at y=11 cut
	-- the tops off "T WA". At -18 the badge ends at y=4 and clears them.
	passBadge.Position = UDim2.new(1, -6, 0, -18)
	passBadge.Size = UDim2.fromOffset(70, 22)
	passBadge.BackgroundColor3 = C.gold
	passBadge.BorderSizePixel = 0
	passBadge.ZIndex = 6
	passBadge.Parent = pass
	pill(passBadge)
	outline(passBadge, 3)

	local passPrice = label(passBadge, "", 14, Enum.Font.LuckiestGuy, C.ink)
	passPrice.Name = "Price"
	passPrice.Size = UDim2.fromScale(1, 1)
	passPrice.TextXAlignment = Enum.TextXAlignment.Center
	passPrice.ZIndex = 7

	pass.MouseEnter:Connect(function()
		TweenService:Create(passScale, TweenInfo.new(0.12), { Scale = 1.05 }):Play()
	end)
	pass.MouseLeave:Connect(function()
		TweenService:Create(passScale, TweenInfo.new(0.12), { Scale = 1 }):Play()
	end)
	pass.MouseButton1Down:Connect(function()
		TweenService:Create(pass, TweenInfo.new(0.06), { Position = UDim2.fromOffset(0, 5) }):Play()
	end)
	pass.MouseButton1Up:Connect(function()
		TweenService:Create(pass, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Position = UDim2.fromOffset(0, 0) }):Play()
	end)

	-- Activated rather than MouseButton1Click, same as LEAVE: it fires for a
	-- touch tap too, and touch is most of who this button is for.
	TouchFit.activated(pass, function()
		AudioKit.play("UIClick")

		-- The server holds its own cooldown and would drop a flood; this is so a
		-- double-tap does not look like a button that ignored the first press.
		-- ABOVE the ownership branch, not below it: the send below now happens on
		-- an unowned tap too, and that path reaches a yielding web call.
		local now = os.clock()
		if now - passSent < 1 then
			return
		end
		passSent = now

		--[[
			SENT WHETHER OR NOT THIS CLIENT THINKS IT OWNS THE PASS, AND THAT
			ORDERING IS THE WHOLE FIX. Changed 2026-09-09 off a player report:
			"I purchased instant wash and it's not working."

			This used to sit under `if not passOwned() then ... return end` -- a
			read of the replicated OwnsInstantWash attribute. That looks free, and
			PassConfig's own note says getting it wrong "costs a wrong-looking
			button and nothing else". It cost far more than that, because THE ONE
			MESSAGE THAT CAN CORRECT A WRONG ATTRIBUTE WAS THE ONE THE GATE WAS
			SUPPRESSING.

			The chain, end to end. GamePassService writes that attribute from a
			join sweep, and the sweep can be wrong in the player's favour two ways:
			UserOwnsGamePassAsync is cached per server (its own header: "the cache
			is warmed by the join sweep with the answer no"), and a pass bought
			from the Roblox app's Store tab -- one tap off the experience page, and
			a normal way to buy on a phone -- never raises
			PromptGamePassPurchaseFinished on this server at all. The cure the
			server carries is WashServer's `ownsFlat(..., refresh = true)`, which
			re-asks Roblox and rewrites both the record and the attribute. It runs
			on WashInstantRequest. WashInstantRequest is fired from exactly one
			line in the game -- this one -- and it was below the gate.

			So an owner whose attribute was wrong saw a grape BUY button, tapped
			it, got Roblox's "you already own this item" dialog, and came back to
			the same grape button, for the whole session. And the jet was not
			instant either, because WashServer:879 reads the same record -- so on
			Pressure Lv 1 they were washing at 6 psi, the slowest in the game,
			having just paid to never wait again.

			SENDING COSTS NOTHING TO GUARD. The payload is empty and the server
			owns every precondition -- see WashServer's header: "the only thing a
			client can do by sending this is ask" -- and the ask is rationed twice
			over, by `passSent` above and by INSTANT_COOLDOWN there.
		]]
		Net.get("WashInstantRequest"):FireServer()

		if passOwned() then
			return
		end

		--[[
			STRAIGHT TO MARKETPLACESERVICE, not through a remote.

			PromptGamePassPurchase is a CLIENT call -- there is no server-side
			way to open a purchase dialog on somebody's screen -- so a remote
			here would be a hop that changes nothing. It is not a hole either:
			the server hears the result on PromptGamePassPurchaseFinished and
			then goes and ASKS Roblox rather than believing the callback.

			STILL RAISED HERE RATHER THAN ON THE SERVER'S SAY-SO, so a genuine
			buyer gets the dialog on the same frame they tapped instead of waiting
			out a web call. The send above and this are independent: the ask
			repairs a wrong record, the dialog sells to somebody who really has
			not bought it, and a stale-false owner gets both -- Roblox tells them
			they already own it while the server quietly turns their button gold.

			OFF SALE IS A TOAST, NOT A DIALOG. Roblox will not sell a pass
			that is off sale, so prompting would open a modal the player
			cannot complete and leave them thinking the purchase failed. Same
			call AtvClient makes for the machine passes.

			AND IT NO LONGER SWALLOWS THE TAP. `onSale` reads ForSale_<id>, which
			GamePassService publishes once at boot and writes FALSE when that
			GetProductInfo call fails -- so on an unlucky server this branch used
			to be a dead end for an owner as well as for a buyer. The send is
			above it now, so the rescue happens either way.
		]]
		if not PassConfig.onSale(INSTANT.id) then
			ToastKit.toast(INSTANT.name .. " is not on sale yet.", "deny", 2.6)
			return
		end
		MarketplaceService:PromptGamePassPurchase(player, INSTANT.id)
	end)

	hud.gui, hud.root, hud.title, hud.bar, hud.hint = gui, holder, title, bar, hint
	hud.exit, hud.exitKey = exit, exitKey
	hud.passHolder, hud.pass, hud.passGrad = passHolder, pass, passGrad
	hud.passLabel, hud.passBadge, hud.passPrice = passLabel, passBadge, passPrice
	hud.body, hud.cardScale, hud.track, hud.notches = body, cardScale, track, notches
	hud.pct, hud.pctShade, hud.pctScale = pct, pctShade, pctScale
	hud.fillGrad, hud.shineGrad, hud.barFlash = fillGrad, shineGrad, barFlash
	hud.tierText, hud.reticle, hud.retScale = tierText, ret, retScale
	hud.ring, hud.stroke, hud.dot, hud.core = ring, stroke, dot, core
	hud.chainChip, hud.chain, hud.chainScale, hud.edge = chainChip, chain, chainScale, edge
	hud.flash, hud.stamp, hud.stampStroke, hud.stampScale = flash, stamp, stampStroke, stampScale
end

--[[
	WHAT THE PASS BUTTON SAYS. Repainted, never rebuilt -- see its block above.

	Three states, and only one of them is about the player:

		owned          gold, no badge. Pressing it strips the rock.
		on sale        grape, "R$ 99". Pressing it opens Roblox's dialog.
		not on sale    grape, "SOON". Pressing it toasts and buys nothing.

	BOTH INPUTS ARRIVE LATE, WHICH IS WHY THIS IS A FUNCTION AND NOT A BLOCK OF
	SETUP. The price is a web call GamePassService makes at boot and publishes
	into its info folder; ownership is a second web call made when the player
	joins. Either can land after this file has drawn its button, and both can
	land again mid-session -- ownership the moment a purchase goes through, and
	the price if the pass is put on sale while the server is up. So it is hung
	off both signals rather than read once and left wrong.
]]
local function refreshPass()
	if not hud.pass then
		return
	end
	local owned = passOwned()
	instantOwned = owned
	hud.passBadge.Visible = not owned
	if owned then
		hud.passGrad.Color = ColorSequence.new(C.goldTop, C.goldDeep)
	else
		hud.passGrad.Color = ColorSequence.new(C.grape, C.grapeDeep)
		local price = PassConfig.price(INSTANT.id)
		hud.passPrice.Text = price and ("R$ " .. price) or "SOON"
	end
end

-- One notch per chunk, drawn OVER the fill. It is what makes the bar read as a
-- rock in fourteen pieces rather than as an abstract percentage -- watching a
-- whole segment light up is most of why popping a chunk feels like anything.
-- Rebuilt per session, because the count is per item.
local function layoutBar(total: number)
	if not hud.notches then
		return
	end
	hud.notches:ClearAllChildren()
	if total < 2 or total > 40 then
		return
	end
	for i = 1, total - 1 do
		local n = Instance.new("Frame")
		n.Name = "Notch" .. i
		n.AnchorPoint = Vector2.new(0.5, 0.5)
		n.Position = UDim2.fromScale(i / total, 0.5)
		n.Size = UDim2.new(0, 2, 1, -6)
		n.BackgroundColor3 = C.ink
		n.BackgroundTransparency = 0.45
		n.BorderSizePixel = 0
		n.ZIndex = 8
		n.Parent = hud.notches
	end
end

-- A ring that blooms where a chunk just came off. Screen space rather than a
-- world part: it has to read instantly whatever the camera is doing, and it
-- must never be occluded by the rock it just came out of.
local function popRing(worldPos: Vector3?)
	if not (hud.gui and worldPos) then
		return
	end
	local p, onScreen = cam():WorldToScreenPoint(worldPos)
	if not onScreen then
		return
	end
	local ring = Instance.new("Frame")
	ring.Name = "Pop"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromOffset(p.X, p.Y)
	ring.Size = UDim2.fromOffset(16, 16)
	ring.BackgroundTransparency = 1
	ring.BorderSizePixel = 0
	ring.ZIndex = 15
	ring.Parent = hud.gui
	pill(ring)
	local st = Instance.new("UIStroke")
	st.Thickness = 5
	st.Color = C.foam
	st.Parent = ring
	TweenService:Create(ring, TweenInfo.new(0.36, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		Size = UDim2.fromOffset(98, 98),
	}):Play()
	TweenService:Create(st, TweenInfo.new(0.36), { Transparency = 1, Thickness = 1 }):Play()
	Debris:AddItem(ring, 0.45)
end

-- The last chunk is the whole point of the minigame and it used to land with
-- exactly the same pop as the thirteen before it. Rarity decides how loud the
-- room gets: a Common says CLEAN, a Legendary says so by name and holds longer.
local function celebrate(rarity: string)
	if not hud.gui then
		return
	end
	local col = ItemConfig.rarityColor(rarity)
	local info = ItemConfig.rarityInfo(rarity)
	local loud = (rarity ~= "Common" and rarity ~= "Uncommon")

	hud.flash.BackgroundColor3 = Color3.new(1, 1, 1):Lerp(col, 0.4)
	hud.flash.BackgroundTransparency = loud and 0.42 or 0.62
	TweenService:Create(hud.flash,
		TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }):Play()

	hud.stamp.Text = loud and (string.upper(rarity) .. "!") or "CLEAN!"
	hud.stamp.TextColor3 = col
	hud.stamp.TextTransparency = 0
	hud.stampStroke.Transparency = 0
	hud.stampScale.Scale = 0.4
	TweenService:Create(hud.stampScale,
		TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }):Play()

	task.delay(0.75 + (info.hold or 0), function()
		if not hud.stamp then
			return
		end
		TweenService:Create(hud.stamp, TweenInfo.new(0.35), { TextTransparency = 1 }):Play()
		TweenService:Create(hud.stampStroke, TweenInfo.new(0.35), { Transparency = 1 }):Play()
	end)
end

local TOUCH = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

--[[
	FINGER OR POINTER, and that is the only thing this asks. The camera ladder
	is the one caller -- see the note on SHOTS for why the answer moves the shot.

	The property pair is the same one TOUCH uses above, and `not MouseEnabled` is
	right here where EggClient's and FerryClient's `not KeyboardEnabled` is not:
	those two are choosing between a key to press and a thing to tap, and a
	tablet in a keyboard case HAS a key. It still has no pointer, so it still
	aims with a finger and still wants the nearer shot. A laptop with a
	touchscreen is the opposite case and gets the desktop shot, correctly.

	BUT THAT PAIR ALONE IS DEAD IN STUDIO. The device emulator reports BOTH
	TouchEnabled and MouseEnabled true -- TouchFit's note records the same trap
	from the KeyboardEnabled side -- so the plain test can never be exercised on
	the small screen this shot exists for, and it went unverified for exactly
	that reason.

	GetLastInputType closes that, and it is the more honest question anyway:
	not what the device HAS, but what the player just USED. Read when the camera
	is solved, which is once at the start of a wash, so it cannot flip halfway
	through one. A desktop player who taps a touchscreen gets the touch shot,
	which is correct -- they just aimed with a finger.
]]
local function aimsWithAFinger(): boolean
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		return true
	end
	return UserInputService:GetLastInputType() == Enum.UserInputType.Touch
end

local function updateHud()
	if not hud.gui then
		return
	end

	-- Its own clock. onRender calls this with no argument and the smoothing
	-- below needs a dt; clamped so a frame hitch cannot make the bar jump.
	local now = os.clock()
	local dt = math.clamp(now - (hud.lastAt or now), 0, 1 / 15)
	hud.lastAt = now

	if hud.barTotal ~= S.total then
		hud.barTotal = S.total
		layoutBar(S.total)
	end
	if S.triggering then
		S.fired = true
	end

	-- The truth arrives in whole chunks -- a fourteenth of the rock at a time --
	-- and a bar that teleports in fourteen steps reads as a counter rather than
	-- as something coming apart under the jet.
	local done = (S.total > 0) and (1 - S.remaining / S.total) or 0
	S.doneShown += (done - S.doneShown) * (1 - math.exp(-dt * 14))
	if math.abs(done - S.doneShown) < 0.0015 then
		S.doneShown = done
	end

	hud.bar.Size = UDim2.fromScale(S.doneShown, 1)
	hud.fillGrad.Color = ColorSequence.new(
		C.water:Lerp(Color3.fromRGB(170, 255, 214), done),
		C.waterDeep:Lerp(Color3.fromRGB(44, 176, 132), done))
	hud.shineGrad.Offset = Vector2.new((now * 0.5) % 2 - 1, 0)
	hud.barFlash.BackgroundTransparency = 1 - S.flash * 0.7

	local shown = math.floor(S.doneShown * 100 + 0.001)
	hud.pct.Text = shown .. "%"
	hud.pctShade.Text = hud.pct.Text
	hud.pctScale.Scale = 1 + S.flash * 0.16

	hud.title.Text = string.upper(S.revealName or ItemConfig.LumpDisplayName)
	hud.title.TextColor3 = S.revealColor or C.cream
	hud.tierText.Text = player:GetAttribute("WasherLabel") or "Garden Hose"

	local onTarget = S.aimIndex ~= nil
	if S.revealName then
		hud.hint.Text = "Sell it at the green pad"
		hud.hint.TextColor3 = Color3.fromRGB(150, 245, 178)
		hud.hint.TextTransparency = 0
	elseif not S.fired then
		-- Pulsed, and only until the first shot. A player who has never washed
		-- anything needs telling once; after that it is clutter.
		hud.hint.Text = TOUCH and "TAP AND HOLD to blast" or "HOLD LEFT CLICK to blast"
		hud.hint.TextColor3 = C.gold
		hud.hint.TextTransparency = 0.1 + 0.25 * (0.5 + 0.5 * math.sin(now * 5))
	elseif onTarget then
		S.missTime = 0
		hud.hint.Text = string.format("%d chunk%s left", S.remaining, S.remaining == 1 and "" or "s")
		hud.hint.TextColor3 = C.foam
		hud.hint.TextTransparency = 0
	else
		--[[
			BLASTING NOTHING IS ITS OWN STATE, AND IT USED TO LOOK LIKE IDLING.

			Off-target has always drawn this amber line. What it did not do was tell
			"you have not aimed yet" apart from "you are holding the trigger down
			and the bar has not moved in ten seconds" -- and the second one is the
			one that reads as a broken game.

			The bar genuinely does not move. WashServer advances a chunk only on a
			WashAim packet, and the client sends one only when its ray hits crust,
			so a miss is silent the whole way down the stack. Measured on the live
			game: twelve seconds of firing at 59%, then four more at 95%, with the
			number unchanged and nothing on screen saying why.

			So past MISS_TELL the line says what is actually wrong and pulses, which
			is the one gesture this HUD uses to mean "look here". Below it, the
			quiet prompt stays as it was: flashing at somebody who is simply lining
			a shot up is worse than saying nothing.
		]]
		if S.triggering then
			S.missTime += dt
		else
			S.missTime = 0
		end
		if S.missTime >= MISS_TELL then
			hud.hint.Text = TOUCH and "Not on the crust!" or "Not on the crust \u{2014} aim at the rock"
			hud.hint.TextColor3 = Color3.fromRGB(255, 138, 116)
			hud.hint.TextTransparency = 0.05 + 0.3 * (0.5 + 0.5 * math.sin(now * 9))
		else
			hud.hint.Text = TOUCH and "Point at the crust"
		or "Point at the crust   \u{00B7}   jump or Q to leave"
			hud.hint.TextColor3 = Color3.fromRGB(255, 200, 120)
			hud.hint.TextTransparency = 0
		end
	end

	--[[
		THE RETICLE IS DRAWN IN ITS PARENT'S SPACE, NOT THE SCREEN'S.

		GetMouseLocation is in screen pixels, and this used to be written
		straight into Position -- which was right until UiFit arrived. UiFit
		absorbs every pure-offset top-level child of a ScreenGui into a FitRoot
		frame carrying a UIScale, and the reticle is pure offset, so it goes in
		with the rest. An offset inside a container scaled by k lands at k times
		itself on screen: at the 0.82 this fits to on a desktop viewport, a
		cursor 400px across the screen drew its ring at 328 -- up and to the
		left, and further out the further from the corner you got, which is
		exactly how it looked.

		So the screen position is converted into the parent's space by dividing
		the scale back out. Walked up the ancestors rather than asked of UiFit:
		the reticle keeps working the same whether it was absorbed, absorbed into
		something nested, or left alone, and nothing here has to know which.

		Its own UIScale is deliberately not counted -- a UIScale scales what it
		sits on and everything under it, but Position is resolved in the PARENT,
		so retScale's flash-pop must not drag the ring off the pointer.
	]]
	local pos = UserInputService:GetMouseLocation()
	local k = 1
	local node = hud.reticle.Parent
	while node and node:IsA("GuiObject") do
		local us = node:FindFirstChildOfClass("UIScale")
		if us then
			k *= us.Scale
		end
		node = node.Parent
	end
	if k > 1e-4 then
		hud.reticle.Position = UDim2.fromOffset(pos.X / k, pos.Y / k)
	else
		hud.reticle.Position = UDim2.fromOffset(pos.X, pos.Y)
	end
	hud.reticle.Size = UDim2.fromOffset(onTarget and 34 or 46, onTarget and 34 or 46)
	hud.retScale.Scale = 1 + S.flash * 0.3
	hud.stroke.Color = onTarget and C.foam or Color3.fromRGB(226, 236, 244)
	hud.stroke.Transparency = onTarget and 0.05 or 0.4
	hud.dot.BackgroundTransparency = onTarget and 1 or 0.25

	-- Core fills the ring as the chunk gives way, and goes white hot at the top
	-- of its travel -- the last tenth is the "it is about to go" tell.
	local span = onTarget and 20 or 0
	hud.core.Size = UDim2.fromOffset(span * S.charge, span * S.charge)
	hud.core.BackgroundColor3 = Color3.fromRGB(150, 245, 178)
		:Lerp(Color3.new(1, 1, 1), math.max(0, S.charge - 0.6) * 2.5)

	--[[
		THE PASS BUTTON IS A CONTROL FOR A ROCK THAT STILL HAS CRUST ON IT.

		It goes the instant the last chunk does -- before the reveal, not after
		it. There is nothing left to skip by then, and a Robux button sitting
		over somebody's Legendary is the worst moment in the game to ask them
		for money.

		Drawn for owners too, in the owned colour: it is the button that DOES
		the thing they bought, and hiding it from the people who paid would
		leave the pass with no way to use it.
	]]
	hud.passHolder.Visible = (S.revealName == nil) and S.remaining > 0

	--[[
		...AND WHAT IT SAYS IS THE SIZE OF THE JOB.

		One tap finishes the rock on the stand AND every other crusted find in
		the bag (WashServer.bulkWash). That is the whole reason to own the pass,
		and a button reading INSTANT WASH over a bag of twelve tells nobody --
		it is the same six seconds of shell-shattering they already know about.
		So the button counts the job out loud. It counts for a non-owner too:
		the BUY face is where the promise has to be made, not where it is kept.

		WRITTEN ONLY WHEN IT CHANGES. A TextLabel assignment is a property write
		and a re-layout whether or not the string differs, and this is a render
		step.
	]]
	local job = crustedInBag + 1
	local want = job > 1 and ("WASH ALL  (" .. job .. ")") or "INSTANT WASH"
	if hud.passLabel and hud.passLabel.Text ~= want then
		hud.passLabel.Text = want
	end

	if S.chain >= 3 then
		hud.chainChip.Visible = true
		hud.chain.Text = "CHAIN  x" .. S.chain
		-- Gold at three, green by twelve: the colour is the only thing that
		-- tells a long chain from a short one at a glance.
		hud.chain.TextColor3 = Color3.fromRGB(255, 214, 130)
			:Lerp(Color3.fromRGB(150, 245, 178), math.min(S.chain / 12, 1))
		hud.chainScale.Scale = 1 + S.flash * 0.22
	else
		hud.chainChip.Visible = false
	end

	hud.edge.Thickness = 4 + math.min(S.spray * 1.1 + S.flash * 2.4, 3)
	hud.edge.Color = C.ink:Lerp(C.foam, math.min(S.spray * 0.5 + S.flash * 0.75, 1))
	hud.cardScale.Scale = 1 + S.flash * 0.018
end

--------------------------------------------------------------------------
-- AUDIO
--------------------------------------------------------------------------

--[[
	THE WASH IS TWO LOOPS AND THEY MUST NOT COMPETE.

	The motor sits UNDER the spray, and the two clips are chosen so they occupy
	different ground: a flat plant-room drone with nothing moving in it, and a
	showery white-noise waterfall on top. The motor is deliberately not a real
	pump recording -- every one of those has a rhythmic whine, and a whine held
	for a whole session is the definition of fatiguing. This one is featureless
	on purpose, so the spray has somewhere to sit.

	The hand-built chain ping that used to be created here is gone; AudioKit's
	StreakStep slot is fired directly at the call site instead.
]]
--[[
	HOW LOUD THE RIG IS ALLOWED TO BE -- Settings -> "Wash Bay Sounds", on by
	default.

	Reported 2026-09-17: "The water gun sounds is too loud. Maybe giving us
	options to turn it off or lower it down would be cool."

	AND THE EXISTING TOGGLE WAS NOT THE ANSWER, which is why this is its own row
	rather than a reply pointing at Sound Effects. Their own settings snapshot
	shows what happened: SFX was OFF when they sent it, and ON again thirteen
	minutes later in their next message. They tried the blunt instrument, lost
	every other sound in the game with it, and came back. AudioKit's header
	explains why it is blunt -- SoundGroups do not nest, so there is exactly one
	SFX bus and per-category shaping has to happen on the Sound.

	SO IT IS APPLIED ON THE TWO LOOPS THIS RIG OWNS. The motor and the spray are
	the broadband noise sitting under the whole session; the one-shots -- the
	chunk pops, the reveal, the bin dump -- are events and are left alone,
	because "the water gun is too loud" is not a complaint about the rock
	breaking.

	READ PER CALL rather than cached: updateAudio runs every frame, and a switch
	that only took effect on the next session would look broken to somebody
	flipping it while standing in the bay.

	DECLARED ABOVE startAudio, which is the one thing that is not a preference:
	startAudio pushes the motor to idle with no dt so it arrives immediately, and
	that call needs the gain too or the rig blares for a frame before updateAudio
	takes it back down.
]]
local function rigGain(): number
	return (player:GetAttribute("Set_WashSounds") == false) and 0 or 1
end

local function startAudio(parent: Instance)
	sounds.motor = AudioKit.loop("WasherMotor", parent)
	sounds.spray = AudioKit.loop("WasherSpray", parent)
	-- The motor is on the moment the rig is, at idle; only the spray waits for
	-- the trigger. Pushed with no dt so it arrives at idle level immediately
	-- rather than winding up over the first second of a session.
	-- Gained here too, or the motor arrives at full idle volume for one frame
	-- before updateAudio's first pass takes it back down.
	sounds.motor:set(rigGain())
	-- Hold the music back for the session -- same reasoning as the sifting bay.
	-- The wash needs it slightly more, because the spray is broadband noise and
	-- music competing with noise is what turns both into mush. Paired with the
	-- loops above rather than with the session functions, so the duck cannot
	-- outlive the sound it was making room for.
	AudioKit.duckMusic(0.45, 1.2)
end

local function stopAudio()
	for k, h in sounds do
		if h then
			-- Faded rather than destroyed: cutting a loop dead leaves a click.
			h:stop(0.3)
			sounds[k] = nil
		end
	end
	-- Music back up, and slower than it went down.
	AudioKit.duckMusic(1, 2.2)
end

local function updateAudio(dt: number)
	local p = pressure()
	local gain = rigGain()
	if sounds.motor then
		-- Motor leans on the trigger: it bogs down slightly under load, which is
		-- the cue that the jet is actually doing work.
		sounds.motor:set((1 + S.spray * 0.7) * gain, 0.83 + S.spray * 0.31, dt)
	end
	if sounds.spray then
		-- Higher tiers hiss higher. Cheap, and instantly legible as "stronger".
		--
		-- ...and the hiss tightens as the chunk under the jet gives way. That last
		-- term is a TELEGRAPH: the pop is a server event and arrives whenever it
		-- arrives, so without something rising ahead of it the break is a surprise
		-- every single time. A note bending up over the half-second before it lets
		-- go turns each chunk into an ending the player can hear coming.
		--
		-- The old per-frame (random - 0.5) * 0.03 on this pitch is gone. Random
		-- applied to a LOOP every frame is not texture, it is tape wow: the clip
		-- is a real 56-second waterfall now and it has all the internal movement
		-- it needs, so wobbling it on top only made it sound unstable. Jitter
		-- belongs on one-shots, where it varies between events rather than
		-- inside one.
		sounds.spray:set(S.spray * 1.3 * gain, 0.88 + (p / 15) * 0.30 + S.charge * 0.14, dt)
	end
end

-- The local playOneShot is gone; AudioKit.play replaces it at every call site
-- below. It made a bare Sound off a raw id, so it sat outside the bus (and so
-- ignored the Settings panel's Sound Effects toggle) and had no attack ramp.

--------------------------------------------------------------------------
-- TOOL / JET
--------------------------------------------------------------------------

local function findTool()
	local char = player.Character
	local tool = char and char:FindFirstChild("Power Washer")
	if not tool then
		S.tool, S.nozzle, S.muzzle = nil, nil, nil
		return false
	end
	S.tool = tool
	S.nozzle = tool:FindFirstChild("Nozzle")
	S.muzzle = S.nozzle and S.nozzle:FindFirstChild("Muzzle")
	return S.nozzle ~= nil
end

--------------------------------------------------------------------------
-- THE VIEWMODEL  --  the washer, drawn as if it were in your right hand
--------------------------------------------------------------------------
--[[
	WHY THERE HAS TO BE ONE.

	The real washer IS in the player's hand for the whole session -- but
	clearShot() below veils the entire character, tool included, because the wash
	camera looks back THROUGH where the player is standing and their head sat
	dead centre over the lump. So the one thing the minigame is about was
	visible and the thing doing it was not: the jet left a nozzle nobody could
	see, arriving from empty air.

	This is a local, anchored COPY of that tool, pinned to the camera low and to
	the right the way a held wand sits, and rotated every frame so the lance
	points wherever the player is aiming. The real one stays veiled and stays
	authoritative -- it is still the thing WashServer lent out, and nothing here
	touches it.

	CLONED, NOT REBUILT. Every stud of this is WasherTool's geometry read back off
	the live tool, offsets included, so retiring the hose stub or repainting the
	lance over there changes what the player sees here with no second edit. The
	one thing not read back is the WELDS: the copy is anchored and every part is
	driven from its own baked offset, because a welded assembly hanging off an
	anchored handle is physics, and physics one stud from the camera jitters.

	CanQuery = false on every part, which is what keeps it out of the aim ray, out
	of the camera's own clearance rays, and out of anything else that ever casts
	through this space. (The aim ray is Include-filtered to the crust folder and
	could not hit it anyway; the next raycast someone adds might not be.)
]]

--[[
	SCALE AND GRIP ARE SOLVED AGAINST THE SHOT, NOT EYEBALLED.

	The wash camera always frames the lump the same way, so where the wand lands
	on screen is predictable -- and the bottom half of that frame is crowded. Five
	rectangles are live during a session, measured off the running HUD:

		wash card    376..936 x 491..623      the progress panel
		INSTANT      376..546 x 437..477      the game pass button
		chain pip    577..735 x 447..481      centred now -- see its own note
		LEAVE        790..936 x 437..477      its exit button
		rail        1201..1293 x 112..639     MenuHud's buttons
		hint         296..1016 x 675..711     CTB_HUD's bottom line

	SIX now rather than five, and the figures above are the CURRENT ones. Two
	changed with the pass button: the chain pip moved off LEAVE (it was at
	770..928, on top of it), and INSTANT is new on the left. THE SWEEP BELOW HAS
	NOT BEEN RE-RUN against them -- if the wand starts crossing a button, this
	table is the input to re-run it with.

	These were found by sweeping grip and scale and projecting the whole lance
	axis -- hose tail to muzzle tip, not just the part centres -- through
	WorldToViewportPoint against all five.

	THE RULE IS NOT "CLEAR OF EVERYTHING". Only 7 placements manage that, and
	every one of them floats the wand at eye level in the middle of the screen,
	which is not a held tool -- it is a wand hanging in the air. What actually
	matters is that the FRONT of the lance is clear, because that is where the
	jet leaves: a nozzle behind the card takes the spray with it. The grip and
	hose end may pass behind the panel, the way a viewmodel always does.

	So: front 45% clear of all five, whole thing on screen with margin. And swept
	over EVERY chunk on the rock, not one aim point -- the lance swings as the
	player tracks across the lump, and the low-right chunks are the ones that push
	the heel off the bottom edge. That leaves the heel in the bottom-right corner
	and the muzzle above the card pointing into frame, with the trigger and hose
	free to pass behind the panel the way a viewmodel always does.

	EARLIER PASSES, and what each one taught:
	  (0.95, -0.82, -1.45) @ 0.55   trigger and hose hung off the bottom edge,
	                                barrel ran behind the card
	  (1.30, -0.55, -2.10) @ 0.45   cleared the card, muzzle inside LEAVE
	  (0.75, -0.50, -3.10) @ 0.46   clean at three sample aim points, 111px off
	                                the bottom once the whole rock was swept
	and the one that mattered: the sweep was measuring a lance in RAW tool studs
	while the model is scaled, so it was solving for a wand 2.3x longer than the
	one on screen -- which is why it kept pushing the grip out to 3 studs and
	ended up with a 150px sliver. Sample the axis in SCALED units.

	SIZE IS scale/depth, NOT scale. (0.70, -0.25, -2.50) @ 0.80 finally spanned a
	readable 337px, and looked absurd: at 2.5 studs out that scale turns the hose
	stub into a black slab across a quarter of the frame. What the eye reads is
	apparent size -- so the last pass targets an on-screen SPAN of ~250px with the
	heel kept back near 2 studs, which is a wand at arm's length rather than one
	pressed against the lens.

	If the wash HUD moves or resizes, re-solve rather than nudge.
]]
local VIEW_SCALE = 0.65
-- Right, down and forward of the camera. Forward enough that the hose stub
-- behind the grip stays clear of the near clip plane.
local VIEW_GRIP = Vector3.new(0.85, -0.40, -2.80)
local VIEW_AIM_SMOOTH = 16     -- how fast the lance chases the reticle
local VIEW_BOB_RATE = 2.1
local VIEW_BOB = 0.018
local VIEW_KICK = 0.34         -- studs of recoil back along the barrel, at full spray

-- How long a water particle lives. The jet's SPEED is then solved per frame from
-- how far away the player is actually aiming, so the stream ends on the target
-- instead of flying a fixed distance past it -- see the block that sets it.
local JET_LIFETIME = 0.16

-- The reach the droplet sizes in ItemVisuals.makeJetEmitter were drawn for, and
-- the floor they may shrink to. See the size block below: a stream that stops at
-- its target has to thin down with it or it stops reading as a stream.
local JET_SIZE_REACH = 12
local JET_SIZE_MIN = 0.22
local VIEW_SHAKE = 0.022

local view = {
	model = nil,
	parts = {},   -- { part = clone, offset = CFrame relative to the handle }
	handle = nil,
	nozzle = nil,
	muzzle = nil,
	aimAt = nil,  -- smoothed, so the lance does not snap between chunks
	kick = 0,
	kickVel = 0,
	bob = 0,
}

local function clearViewModel()
	if view.model then
		view.model:Destroy()
	end
	view.model, view.handle, view.nozzle, view.muzzle = nil, nil, nil, nil
	table.clear(view.parts)
	view.aimAt, view.kick, view.kickVel, view.bob = nil, 0, 0, 0
end

local function buildViewModel()
	if view.model or not S.tool then
		return
	end
	local realHandle = S.tool:FindFirstChild("Handle")
	if not realHandle then
		return
	end

	local model = Instance.new("Model")
	model.Name = "WashViewModel"

	for _, p in ipairs(S.tool:GetChildren()) do
		if p:IsA("BasePart") then
			local clone = p:Clone()
			-- Welds and attachments go: this copy is driven, not simulated.
			clone:ClearAllChildren()
			clone.Anchored = true
			clone.CanCollide = false
			clone.CanQuery = false
			clone.CanTouch = false
			clone.CastShadow = false
			clone.Massless = true
			clone.LocalTransparencyModifier = 0
			clone.Size = p.Size * VIEW_SCALE
			clone.Parent = model

			-- Offset baked in the handle's frame. The POSITION scales with the
			-- model; the ROTATION must not, or the nozzle stops pointing down the
			-- barrel and the jet leaves sideways.
			local off = realHandle.CFrame:ToObjectSpace(p.CFrame)
			table.insert(view.parts, {
				part = clone,
				offset = CFrame.new(off.Position * VIEW_SCALE) * (off - off.Position),
			})

			if p == realHandle then
				view.handle = clone
			elseif p.Name == "Nozzle" then
				view.nozzle = clone
			end
		end
	end

	if not view.handle then
		model:Destroy()
		table.clear(view.parts)
		return
	end

	--[[
		NO HAND, AND THAT WAS TRIED PROPERLY.

		Cloning RightHand and RightLowerArm in beside the tool is the obvious way
		to sell "held", and the offsets are even exact and free: an equipped
		tool's Handle is welded to the hand's grip attachment, so
		realHandle.CFrame:ToObjectSpace(hand.CFrame) IS the Grip and does not
		move while the arm animates.

		It looks wrong. WasherTool's Grip is CFrame.Angles(rad(-90), 0, 0), which
		puts the hand ABOVE the lance rather than behind it, and the forearm then
		runs up and to the right instead of trailing off the bottom corner. At
		viewmodel framing that is a pale detached blob hovering over the rock,
		not a fist on a grip -- and there is no elbow or shoulder to carry it,
		because the character it belongs to is veiled three studs behind.

		The lance alone reads as held: it pivots from a grip point pinned low and
		right, which is the whole cue. Adding an arm would mean authoring a pose
		here rather than reading the rig, and keeping that pose in step with a
		Grip it no longer follows.
	]]

	-- The muzzle, read off the real one rather than written down again, so the
	-- jet keeps leaving the tip if WasherTool ever moves it.
	if view.nozzle then
		local realNozzle = S.tool:FindFirstChild("Nozzle")
		local realMuzzle = realNozzle and realNozzle:FindFirstChild("Muzzle")
		local m = Instance.new("Attachment")
		m.Name = "Muzzle"
		m.Position = (realMuzzle and realMuzzle.Position or Vector3.new(0, -0.3, 0)) * VIEW_SCALE
		m.Parent = view.nozzle
		view.muzzle = m
	end

	model.Parent = workspace
	view.model = model
end

--[[
	Called from onRender AFTER the camera has been written, never before: the
	grip is camera-relative, and placing it against last frame's camera is what a
	viewmodel that swims behind the shot looks like.
]]
local function updateViewModel(dt: number, firing: boolean)
	if not (view.model and view.handle) then
		return
	end
	local c = cam().CFrame

	-- Idle bob, so a wand nobody is firing still reads as held rather than
	-- welded to the lens.
	view.bob += dt
	local breathe = math.sin(view.bob * VIEW_BOB_RATE) * VIEW_BOB

	-- Recoil, on the same spring shape the camera kick uses so the two agree.
	local wantKick = S.spray * VIEW_KICK
	view.kickVel += (-120 * (view.kick - wantKick) - 14 * view.kickVel) * dt
	view.kick = math.clamp(view.kick + view.kickVel * dt, -0.5, 0.9)

	local shake = S.spray * VIEW_SHAKE
	local grip = c * CFrame.new(
		VIEW_GRIP.X + (math.random() - 0.5) * shake,
		VIEW_GRIP.Y + breathe + (math.random() - 0.5) * shake,
		VIEW_GRIP.Z
	)

	-- Where it points. With nothing under the reticle it falls back to the ROCK,
	-- not to a point far down the shot: a distant target barely deflects the
	-- lance off the camera axis, so the wand straightened out and slid to the
	-- middle of the screen every time the cursor left the crust. Aiming at the
	-- lump keeps the resting pose the same one the placement was solved for.
	local target = S.aimPoint
		or (S.model and S.model.Parent and S.model:GetPivot().Position)
		or (S.stand and S.stand.Position)
		or (c.Position + c.LookVector * 7)
	view.aimAt = view.aimAt and view.aimAt:Lerp(target, 1 - math.exp(-dt * VIEW_AIM_SMOOTH))
		or target

	-- lookAt puts the frame's -Z on the target, and the tool is BUILT down its
	-- own -Z (barrel at z -2.2, nozzle at -3.6), so this aims the lance. World
	-- up keeps it from rolling as the aim sweeps across the rock.
	local base = CFrame.lookAt(grip.Position, view.aimAt) * CFrame.new(0, 0, view.kick)
	for _, entry in ipairs(view.parts) do
		entry.part.CFrame = base * entry.offset
	end
end

local function ensureFx()
	-- The viewmodel first: the jet has to leave the nozzle the player can SEE,
	-- not the veiled one at the character's hip.
	buildViewModel()
	if view.nozzle and not fx.jet then
		fx.jet = ItemVisuals.makeJetEmitter(view.nozzle)
	end
	if not fx.impactPart then
		local p = Instance.new("Part")
		p.Name = "WashImpact"
		p.Size = Vector3.new(0.2, 0.2, 0.2)
		p.Transparency = 1
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Parent = workspace
		fx.impactPart = p
		fx.impact = ItemVisuals.makeImpactEmitter(p)
		-- Tinted for the lump on the stand, if there is one yet -- see WashBegin,
		-- which rebuilds this when the next lump turns out to be a different stuff.
		fx.grit = ItemVisuals.makeGritEmitter(p, S.crustStyle)
	end
end

local function clearFx()
	if fx.jet then
		fx.jet:Destroy()
		fx.jet = nil
		-- or the next session opens with the last one's droplet size
		fx.jetSize = nil
	end
	-- After the jet, which lives on one of its parts.
	clearViewModel()
	if fx.impactPart then
		fx.impactPart:Destroy()
		fx.impactPart = nil
		fx.impact, fx.grit = nil, nil
	end
end

--------------------------------------------------------------------------
-- THE SILT  --  see the chain in the constants at the top of this file
--------------------------------------------------------------------------

local function ensureSilt()
	-- The bed on the stand plate. Starts at nothing, so a clean plate shows bare
	-- metal and the first chunk to break has something visible to change.
	if S.stand and not silt.bed then
		local b = Instance.new("Part")
		b.Name = "WashSilt"
		b.Size = Vector3.new(S.stand.Size.X * 0.96, 0.02, S.stand.Size.Z * 0.96)
		b.Color = Color3.fromRGB(126, 112, 92)
		b.Material = Enum.Material.Sand
		b.Anchored = true
		b.CanCollide = false
		b.CanQuery = false
		b.CanTouch = false
		b.CastShadow = false
		b.Transparency = 1
		-- Parented to workspace, not into the bay: the bay is a replicated model
		-- the server may tear down, and a purely local prop hanging inside it
		-- would go with it mid-session.
		b.Parent = workspace
		silt.bed = b
		-- Runs off the plate edge while it is sluicing.
		silt.fall = ItemVisuals.makeSandFallEmitter(b)
	end

	-- The heap in the drain pan.
	--
	-- THREE mounds, not one. A single centred lump growing straight up reads as
	-- a piston; mounds that start at different fills and spread outward read as
	-- something being washed in from above, which is what is happening.
	if not pan.root and S.bay then
		local root = S.bay:FindFirstChild("DrainPan", true)
		if root and root:IsA("BasePart") then
			pan.root = root
			local wx, wz = root.Size.X * 0.28, root.Size.Z * 0.28
			local spots = {
				Vector3.new(-0.42, 0, 0.2),
				Vector3.new(0.05, 0, -0.26),
				Vector3.new(0.44, 0, 0.3),
			}
			for i, spot in spots do
				local middle = (i == 2)
				local m = Instance.new("Part")
				m.Name = "WashHeap" .. i
				m.Size = Vector3.new(0.1, 0.1, 0.1)
				m.Color = Color3.fromRGB(132, 118, 96)
					:Lerp(Color3.fromRGB(98, 88, 72), i * 0.16)
				m.Material = Enum.Material.Sand
				m.Anchored = true
				m.CanCollide = false
				m.CanQuery = false
				m.CanTouch = false
				m.CastShadow = false
				m.Transparency = 1
				m.Parent = workspace

				-- A WIDE FLAT DOME, and the mesh is the only way to get one.
				--
				-- `Shape = Enum.PartType.Ball` does NOT give an ellipsoid when the
				-- three Size axes differ -- it draws a sphere of the SMALLEST one.
				-- A heap sized (2.5, 0.5, 2.0) would render as a half-stud marble,
				-- and a pan filling with silt would look like a pan collecting
				-- pebbles. Silent failure: no warning, no error, just the wrong
				-- shape. A SpecialMesh of MeshType Sphere fills all three axes.
				local dome = Instance.new("SpecialMesh")
				dome.MeshType = Enum.MeshType.Sphere
				dome.Parent = m

				table.insert(pan.mounds, {
					part = m,
					-- Fill this mound waits for before it starts. The middle one
					-- goes first and is the biggest; the outer two lag it, so the
					-- heap grows out of the centre rather than in lockstep.
					lead = middle and 0 or 0.22,
					width = Vector3.new(wx * (middle and 1.4 or 1.1), 0, wz * (middle and 1.4 or 1.05)),
					spot = Vector3.new(spot.X * root.Size.X * 0.5, 0, spot.Z * root.Size.Z * 0.5),
				})
			end
			pan.drain = ItemVisuals.makeSandFallEmitter(root)
		end
		-- A hand-authored bay is only contracted to provide Stand and PromptAnchor,
		-- so a missing DrainPan is legal. Everything below no-ops on pan.root == nil
		-- rather than warning: the plate still loads and still sluices, there is
		-- simply nowhere for it to collect, which is a plainer bay and not a broken
		-- one.
	end
end

local function clearSilt()
	if silt.bed then
		silt.bed:Destroy()  -- takes the fall emitter parented to it
		silt.bed, silt.fall = nil, nil
	end
	for _, m in pan.mounds do
		if m.part then
			m.part:Destroy()
		end
	end
	table.clear(pan.mounds)
	if pan.drain then
		pan.drain:Destroy()
		pan.drain = nil
	end
	pan.root = nil
	pan.fill, pan.target, pan.impact = 0, 0, 0
	silt.load = 0
end

local function burst(emitter: ParticleEmitter?, rate: number, seconds: number)
	if not emitter then
		return
	end
	emitter.Rate = rate
	emitter.Enabled = true
	task.delay(seconds, function()
		if emitter and emitter.Parent then
			emitter.Enabled = false
			emitter.Rate = 0
		end
	end)
end

-- The plate going over: silt sheeting off the edge and down into the pan.
local function sluice()
	silt.load = SILT_RESIDUE
	pan.target += PAN_PER_SLUICE
	pan.impact = 1
	S.flash = 1
	AudioKit.play("BinDump", S.stand, 0.85, 0.95)
	burst(silt.fall, 70, 0.55)
	if S.stand then
		-- Thrown from the plate's edge, landing on the pan floor below. Actual
		-- parts, because a particle puff reads as DUST, and dust is not what the
		-- player has been watching pile up.
		ItemVisuals.spillSand(
			S.stand.CFrame * CFrame.new(0, S.stand.Size.Y * 0.5 + 0.2, 0),
			10,
			S.stand.Size.X * 1.1,
			pan.root and (pan.root.Position.Y + pan.root.Size.Y * 0.5)
				or (S.stand.Position.Y - 3),
			S.crustStyle
		)
	end
end

-- ...and the pan going over, one stage further down: straight through the
-- grates. Nothing is thrown here -- an open pan has no lip to go over, and
-- sideways spray would read as a burst pipe rather than as a drain clearing.
local function flushPan()
	pan.target = PAN_RESIDUE
	pan.impact = 1
	S.flash = 1
	if pan.root then
		AudioKit.play("BinDump", pan.root, 1.1, 0.8)
		burst(pan.drain, 110, 0.8)
	end
	S.kickVel += 1.2
end

local function updateSilt(dt: number, firing: boolean)
	-- PLATE. Always draining, because the water never stops running -- and
	-- draining harder under the jet, so parking the lance on the rock cleans the
	-- plate as well as the rock.
	if silt.load > 0 then
		local rate = SILT_DRAIN + (firing and SILT_JET_DRAIN or 0)
		silt.load = math.max(0, silt.load - rate * dt)
	end
	if silt.load > 1 then
		sluice()
	end

	if silt.bed and S.stand then
		local h = 0.02 + math.min(silt.load, 1) * SILT_HEIGHT
		silt.bed.Size = Vector3.new(silt.bed.Size.X, h, silt.bed.Size.Z)
		silt.bed.CFrame = S.stand.CFrame * CFrame.new(0, S.stand.Size.Y * 0.5 + h * 0.5, 0)
		-- Fades out only over the last quarter, not linearly across the range.
		-- Silt does not become see-through as it washes away, it becomes THINNER,
		-- and the height above is already saying that. Tracking transparency to
		-- load in a straight line leaves it half transparent through the whole
		-- middle of a lump, where it reads as a haze on the plate rather than as
		-- material lying on it.
		silt.bed.Transparency = 1 - math.clamp(silt.load * 4, 0, 1) * 0.95
	end

	-- PAN.
	if pan.target > 1 then
		flushPan()
	end
	pan.fill += (pan.target - pan.fill) * (1 - math.exp(-dt * 6))
	pan.impact = math.max(0, pan.impact - dt * 3.5)

	if not pan.root then
		return
	end

	local floor = pan.root.Size.Y * 0.5
	for _, m in pan.mounds do
		local f = math.clamp((pan.fill - m.lead) / (1 - m.lead), 0, 1)
		-- Squash and stretch on a landing: flat and wide for a moment, then back.
		-- Free, and it is most of what makes a heap feel like weight rather than
		-- like a mesh being scaled.
		local squash = 1 - pan.impact * 0.3
		local spread = 1 + pan.impact * 0.12
		local h = (0.08 + f * 0.45) * squash
		m.part.Size = Vector3.new(
			m.width.X * (0.5 + f * 0.5) * spread,
			h,
			m.width.Z * (0.5 + f * 0.5) * spread
		)
		-- Centre sits a shade under the pan floor, so the ellipsoid reads as a
		-- dome bedded into it rather than a ball resting on it. Deep enough to
		-- swallow the grate bars as it grows, which is the pan visibly needing
		-- the flush it is about to get.
		m.part.CFrame = pan.root.CFrame * CFrame.new(m.spot.X, floor + h * 0.42, m.spot.Z)
		m.part.Transparency = (f > 0.01) and 0 or 1
	end
end

--------------------------------------------------------------------------
-- OTHER PEOPLE'S LUMPS
--------------------------------------------------------------------------

--[[
	A WASH BAY IS A PERSONAL STATION, AND THIS IS THE HALF THAT MAKES IT ONE.

	A mounted lump is a real server-side model parented into the bay's `Mounted`
	folder, so it replicates to EVERYBODY. With more than one washer at a bay
	that meant looking straight through your own rock at somebody else's:
	WashServer was dropping the slot argument that was supposed to fan them
	apart, so every lump in the bay pivoted to the same point and came apart
	inside the others. The offsets are gone now -- WashServer's note says why
	they could never have worked -- and each client is shown its OWN lump and
	nobody else's instead.

	LocalTransparencyModifier, NOT Transparency. Same choice clearShot makes
	below, but for a harder reason here: THE SERVER WRITES Transparency ON
	THESE PARTS CONTINUOUSLY. setChunkErosion darkens each clump as it is
	worked and setUncovered fades in the find underneath, and either one
	replicates straight over a client-side Transparency -- so a stranger's rock
	would pop back into the middle of the shot the moment they touched it.
	Nothing on the server ever writes LocalTransparencyModifier, so this holds
	for the whole wash.

	CanQuery GOES OFF WITH IT, and that is not decoration. An invisible part
	still answers raycasts, and this bay casts two that would find one: the
	camera's clearance ladder, which would read every good shot as blocked and
	settle for the worst one on its list, and the splash ray, which would throw
	the jet's impact spray off a rock that is not there. Clearing CanQuery is
	enough ONLY because every part of a lump is already CanCollide = false in
	ItemVisuals -- a solid part answers a ray whatever CanQuery says. Both ray
	filters exclude these models explicitly as well, because a silent failure
	in either one reads as "the camera is broken in this bay" and not as
	anything to do with another player.
]]

local foreign = {}       -- [Model] = true, every mounted lump that is not ours
local foreignList = {}   -- the same set as an array, for RaycastParams

local function rebuildForeignList()
	table.clear(foreignList)
	for model in foreign do
		table.insert(foreignList, model)
	end
end

-- Appends the veiled lumps to a filter list that is being built. Cheaper than
-- rebuilding a combined table per frame, and it keeps the two call sites below
-- from drifting apart.
local function alsoIgnoreForeign(ignore: { Instance })
	table.move(foreignList, 1, #foreignList, #ignore + 1, ignore)
end

local function veilPart(d: Instance)
	if d:IsA("BasePart") then
		d.LocalTransparencyModifier = 1
		d.CanQuery = false
	elseif d:IsA("Decal") or d:IsA("Texture") then
		d.Transparency = 1
	end
end

local function veilLump(model: Model)
	if foreign[model] then
		return
	end
	foreign[model] = true
	rebuildForeignList()
	for _, d in model:GetDescendants() do
		veilPart(d)
	end
	-- The Crust folder and its chunks can land a frame or two after the model
	-- itself does -- the same race updateAim re-resolves S.crust for.
	model.DescendantAdded:Connect(veilPart)
end

local function forgetLump(model: Instance)
	if foreign[model] then
		foreign[model] = nil
		rebuildForeignList()
	end
end

local function considerLump(model: Instance)
	if not model:IsA("Model") then
		return
	end
	local owner = model:GetAttribute("WashOwner")
	if owner == nil then
		-- WashServer stamps this BEFORE it parents the model, so it is normally
		-- already here. Waiting rather than assuming, because guessing wrong in
		-- this direction hides the player's OWN rock -- the one failure in this
		-- block there is no recovering from without a remount.
		local conn
		conn = model:GetAttributeChangedSignal("WashOwner"):Connect(function()
			conn:Disconnect()
			considerLump(model)
		end)
		return
	end
	if owner ~= player.UserId then
		veilLump(model)
	end
end

local function watchBay(bayModel: Instance)
	-- Its own thread: registerBay creates the folder on the server, so on a bay
	-- that streams in late this would otherwise hold up start().
	task.spawn(function()
		local mounted = bayModel:WaitForChild("Mounted", 30)
		if not mounted then
			return
		end
		mounted.ChildAdded:Connect(considerLump)
		mounted.ChildRemoved:Connect(forgetLump)
		-- Anything already on a stand when we joined.
		for _, child in mounted:GetChildren() do
			considerLump(child)
		end
	end)
end

local function startForeignVeil()
	local tag = GameConfig.Tags.WashBay
	for _, bayModel in CollectionService:GetTagged(tag) do
		watchBay(bayModel)
	end
	-- The island builders clone their bays in after boot and the tag rides along
	-- on the clone, so the bays on islands 2-4 arrive by this signal, not the
	-- sweep above.
	CollectionService:GetInstanceAddedSignal(tag):Connect(watchBay)
end

--------------------------------------------------------------------------
-- AIM
--------------------------------------------------------------------------

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include

-- The second ray, for where the water lands when the cursor is NOT on crust.
-- Excludes rather than includes: it wants the bay, the deck, the wall -- the
-- whole world minus the lump and the player stood in front of it.
local splashParams = RaycastParams.new()
splashParams.FilterType = Enum.RaycastFilterType.Exclude
splashParams.IgnoreWater = true

local function updateAim()
	S.aimIndex, S.aimPoint = nil, nil
	if not S.active then
		return
	end

	-- Re-resolved every frame rather than cached once in beginSession. The lump
	-- is built and parented on the SERVER, so the Crust folder can arrive a
	-- frame or two after the WashBegin payload that references the model -- and
	-- a single lookup that lost that race left aiming dead for the whole
	-- session with nothing on screen to say why.
	if not (S.crust and S.crust.Parent) then
		S.crust = S.model and S.model.Parent and S.model:FindFirstChild("Crust") or nil
	end
	if not (S.crust and S.crust.Parent) then
		return
	end

	--[[
		ONE RAY FROM THE CURSOR. NOTHING ELSE PICKS THE TARGET.

		There were two assists here and both are gone, because between them they
		took the aiming off the player:

		  * a LATCH that, once the trigger was down, kept feeding whichever clump
		    it started on while the cursor drifted within about a clump's width
		  * a NEAR-MISS snap that, when the cursor was not over crust at all,
		    grabbed the closest clump on screen anyway

		The second one is what reads as the washer locking onto the next piece by
		itself: a clump pops, the cursor is briefly over the hole it left, and the
		jet jumps to a neighbour the player never pointed at. The first compounds
		it by then refusing to let go.

		They were put in to stop work smearing across neighbours when an unsteady
		hand crossed several clumps -- work accumulates PER CLUMP on the server,
		so a wandering cursor finishes none of them. That is a real effect, but
		the cure was worse than the disease: a tool that decides what it is
		pointing at is not a tool the player is using. The clump count came down
		from 34 to 22 in the same pass, which makes each one a bigger target and
		is the honest way to buy that back.

		So: whatever the ray hits is what gets washed, and if it hits nothing then
		nothing gets washed.
	]]
	rayParams.FilterDescendantsInstances = { S.crust }

	local mouse = UserInputService:GetMouseLocation()
	-- ViewportPointToRay, NOT ScreenPointToRay. GetMouseLocation includes the
	-- topbar inset, which makes it viewport space; ScreenPointToRay wants the
	-- inset excluded and so aims one whole inset (58px here) BELOW the cursor.
	-- See the AIMING note in the header for the measurement. Do not "fix" this
	-- back -- it has been wrong in that direction once already.
	local ray = cam():ViewportPointToRay(mouse.X, mouse.Y)
	local hit = workspace:Raycast(ray.Origin, ray.Direction * CFG.JetRange * 2, rayParams)
	if hit then
		local index = hit.Instance:GetAttribute("ChunkIndex")
		if type(index) == "number" then
			S.aimIndex = index
			S.aimPoint = hit.Position
			return
		end
	end

	--[[
		No clump under the cursor -- but the jet still runs, so the water has to
		land SOMEWHERE. Without this the impact spray was pinned to wherever it
		last hit crust, so hosing the wall threw a splash off a rock the player
		was no longer pointing at.

		S.aimIndex stays nil, which is what keeps the work, the packets, the grit
		and the silt off. This only moves the splash.
	]]
	local ignore = { S.model }
	if player.Character then
		table.insert(ignore, player.Character)
	end
	alsoIgnoreForeign(ignore)
	splashParams.FilterDescendantsInstances = ignore
	local reach = CFG.JetRange
	local splash = workspace:Raycast(ray.Origin, ray.Direction * reach, splashParams)
	-- Falls back to a point out along the ray so the jet always has a target;
	-- spraying into open sky should still throw mist, just nowhere in particular.
	S.aimPoint = splash and splash.Position or (ray.Origin + ray.Direction * reach)
end

--------------------------------------------------------------------------
-- SESSION
--------------------------------------------------------------------------

--------------------------------------------------------------------------
-- CLEARING THE SHOT
--------------------------------------------------------------------------
--[[
	The wash camera sits ~7 studs in front of the stand looking back at it, and
	the player is standing between the two. So the character's HEAD sat dead
	centre over the lump and their hair filled the bottom of the frame, and the
	sifter -- which rides in front of the player -- came in from both sides.
	The one thing the minigame is about was the one thing you could not see.

	Everything belonging to the player is hidden for the length of a session:
	body, accessories, whatever tool is in hand, and the sifter rig. What is left
	is the bay, the lump and the jet, which are the only things being acted on.
	The jet still draws -- a ParticleEmitter renders even when the part carrying
	it does not.

	LocalTransparencyModifier, NOT Transparency: it is a client-only display
	override that leaves the real property alone, so none of this replicates to
	anyone else and nothing is left mangled if the character respawns mid-wash.
	Decals (the face) have no such property, so those are saved and put back.
]]
local shot = { conns = {}, decals = {}, flags = {} }

-- "<Username>_", the prefix PetServer gives every pet body it spawns.
local function petPrefix(): string
	return player.Name .. "_"
end

local function rigRoots(): { Instance }
	local roots = {}
	local char = player.Character
	if char then
		table.insert(roots, char)
	end
	-- Both names: the rig was CTB_Roller before it became the sifter, and this
	-- should keep working whichever one is in the workspace.
	for _, name in { "CTB_Sifter", "CTB_Roller" } do
		local m = workspace:FindFirstChild(name)
		if m then
			table.insert(roots, m)
		end
	end
	--[[
		AND THE PLAYER'S OWN PETS, which walking the character could never have
		found. PetServer does not parent a pet under its owner -- it drops each
		body straight into Workspace as "<Username>_<PetId>" and flies it with an
		AlignPosition -- so five of them orbit the player at the exact moment the
		player is standing still in front of the stand, which is to say they orbit
		the shot.

		Matched by PREFIX rather than by splitting on the underscore: a Roblox
		username may contain one, so "the part before the first _" is not reliably
		the owner's name.
	]]
	local prefix = petPrefix()
	for _, m in workspace:GetChildren() do
		if m:IsA("Model") and m.Name:sub(1, #prefix) == prefix then
			table.insert(roots, m)
		end
	end
	return roots
end

--[[
	A PET IS NOT A PILE OF PARTS, and that is why this grew a third branch.

	LocalTransparencyModifier exists ONLY on BasePart. A pet is a mesh plus a
	ParticleEmitter, a Beam, a Trail and a PointLight (see PetVisuals.decorate),
	so veiling only the parts left the aura, the ribbon and the glow hanging in
	the middle of the frame with nothing underneath them -- which reads worse
	than the pet did. Each class goes off by its own property.

	The original is recorded rather than assumed, because `false` is a real
	resting value here: a rarity aura is off for a common pet, and switching
	everything back ON at the end of a session would light up effects that were
	never running. BaseParts still restore to a flat 0 -- see restoreShot.

	NONE OF THE WASH FX ARE IN REACH OF THIS. The jet hangs off the VIEWMODEL's
	nozzle and the impact and grit emitters off Workspace.WashImpact, none of
	which is a root -- checked, because switching the jet off would take the
	water out of a game about spraying water.
]]
local function veil(inst: Instance)
	if inst:IsA("BasePart") then
		inst.LocalTransparencyModifier = 1
	elseif inst:IsA("Decal") or inst:IsA("Texture") then
		if shot.decals[inst] == nil then
			shot.decals[inst] = inst.Transparency
		end
		inst.Transparency = 1
	elseif inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam")
		or inst:IsA("Smoke") or inst:IsA("Fire") or inst:IsA("Sparkles")
		or inst:IsA("Light") or inst:IsA("BillboardGui") or inst:IsA("SurfaceGui")
		or inst:IsA("Highlight") then
		if shot.flags[inst] == nil then
			shot.flags[inst] = inst.Enabled
		end
		inst.Enabled = false
	end
end

local function restoreShot()
	for _, c in shot.conns do
		c:Disconnect()
	end
	table.clear(shot.conns)
	for _, root in rigRoots() do
		for _, d in root:GetDescendants() do
			if d:IsA("BasePart") then
				d.LocalTransparencyModifier = 0
			end
		end
	end
	for decal, t in shot.decals do
		if decal.Parent then
			decal.Transparency = t
		end
	end
	table.clear(shot.decals)
	for inst, was in shot.flags do
		if inst.Parent then
			inst.Enabled = was
		end
	end
	table.clear(shot.flags)
end

local function veilRoot(root: Instance)
	for _, d in root:GetDescendants() do
		veil(d)
	end
	-- Accessories stream in late, and the washer is LENT at mount -- i.e. it
	-- can arrive AFTER this runs -- so anything appearing mid-session has to
	-- be caught as it lands or it pops into shot on its own.
	table.insert(shot.conns, root.DescendantAdded:Connect(veil))
end

local function clearShot()
	restoreShot()   -- idempotent, so a resumed session cannot double up handlers
	for _, root in rigRoots() do
		veilRoot(root)
	end

	-- A pet equipped, unequipped or re-rolled mid-session comes back as a WHOLE
	-- NEW Workspace model (PetServer.rebuildBodies destroys the set and spawns
	-- it again), not as a new descendant of anything already veiled -- so the
	-- per-root hooks above cannot see it and it would arrive at full brightness
	-- in the middle of the shot.
	local prefix = petPrefix()
	table.insert(shot.conns, workspace.ChildAdded:Connect(function(child)
		if child:IsA("Model") and child.Name:sub(1, #prefix) == prefix then
			veilRoot(child)
		end
	end))
end

local function enterCamera(stand: BasePart)
	local c = cam()
	if S.prevCameraType == nil then
		S.prevCameraType = c.CameraType
		S.prevCameraSubject = c.CameraSubject
	end

	--[[
		THE SHOT IS THE BAY'S FRONT, NOT THE PLAYER'S APPROACH.

		This used to aim the camera down the line from the stand out to wherever the
		player happened to be standing at the moment they pressed E. Reach a bay from
		the side -- which is the ordinary way to arrive at most of them, because the
		path runs PAST a bay rather than at it -- and the entire wash was played
		side-on, with a side wall down half the frame and the lump lit off its edge.
		Worse than any one bad angle: the framing was different every time. Two
		players at the same stand got two different shots of the same rock, and the
		same player got a new one on every mount. This is a fixed-camera minigame and
		the one thing a fixed camera owes the player is the SAME shot every time,
		because the aim they learned last wash is the aim they bring to this one.

		A BAY HAS A FRONT. It is a three-walled shed with the stand set against the
		back of it, and the open side is the side you walk in through. Three
		independent things name that direction, and measured across all four bays in
		the place -- beach, dune, cove and ashfall, which sit at four different yaws
		-- all three agree exactly (dot product 1.000 in every case):

		  the PROMPT ANCHOR   the spot the player is invited to stand on to mount,
		                      3.4 studs out in front of the stand
		  the BACK WALL       the shed opens away from it
		  the STAND itself    its own -LookVector

		The anchor LEADS because it is the cue that exists by contract -- WashServer
		looks for PromptAnchor on every bay it registers -- and because its meaning
		is "the front" rather than "a wall that happens to be behind". The back wall
		then holds a VETO: a direction that points INTO the wall the shed is built
		against cannot be the way out of it, whatever named it.

		The approach line is kept as the floor, for a bay that is a bare stand with
		no shed around it at all. That is the shape this whole block used to assume.

		TURNS below is untouched and is still the escape: if the front is genuinely
		blocked -- an awning, a hand-built bay backed into a corner -- the ladder
		turns off it exactly as it did. It just starts from the right place now.
	]]
	local function flatten(v: Vector3): Vector3?
		local f = Vector3.new(v.X, 0, v.Z)
		return f.Magnitude > 0.1 and f.Unit or nil
	end

	local bay = S.bay or stand.Parent
	local dir

	local anchor = bay and bay:FindFirstChild("PromptAnchor", true)
	if anchor and anchor:IsA("BasePart") then
		dir = flatten(anchor.Position - stand.Position)
	end
	if not dir then
		dir = flatten(-stand.CFrame.LookVector)
	end

	local back = bay and bay:FindFirstChild("BackWall", true)
	if back and back:IsA("BasePart") then
		local away = flatten(stand.Position - back.Position)
		if away and (not dir or dir:Dot(away) <= 0) then
			dir = away
		end
	end

	if not dir then
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		local from = root and root.Position or (stand.Position + Vector3.new(0, 0, 10))
		dir = flatten(from - stand.Position) or Vector3.new(0, 0, 1)
	end

	local focus = stand.Position + Vector3.new(0, stand.Size.Y * 0.5 + 1.9, 0)

	--[[
		FIND A SHOT THAT IS NOT THROUGH THE BAY.

		BayBuilder states the rule as "nothing may sit between the stand and the
		player", but that is a rule for the bay it builds itself -- a bay authored
		by hand in Studio has never read it. The one in the place file hangs its
		awning across exactly where this camera wants to sit, and a red stripe of
		it ran down the middle of the screen for the whole wash.

		DISTANCE IS THE LAST THING TO GIVE UP. Pulling straight in to whatever the
		ray hits clears the awning by parking two studs off the rock -- the lump
		then fills the frame and the chunks on its far side are off-screen, which
		is worse than the stripe was. So the ladder keeps the full standoff and
		buys clearance with HEIGHT first, and only starts closing in when no angle
		from back there works.

		And clearance is tested against FIVE points, not one. A single ray to the
		centre of the lump says nothing about the rest of it: an awning edge-on can
		miss the middle and still lie across the bottom half of the rock, which is
		half the chunks the player has to hit.

		Excludes the lump (its chunks are the only CanQuery parts in the model and
		they are the thing being looked AT) and the character, who is stood
		roughly where the camera is going.
	]]
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	local ignore = { S.model }
	if player.Character then
		table.insert(ignore, player.Character)
	end
	-- And any lump belonging to somebody else sharing the bay. It is invisible
	-- and non-queryable already, but a shot silently rejected here costs the
	-- player the good camera angle for a whole wash, so it is stated twice.
	alsoIgnoreForeign(ignore)
	params.FilterDescendantsInstances = ignore

	--[[
		A NEARER LADDER ON TOUCH, AND THE REASON IS THE SIZE OF A FINGER.

		MEASURED, by projecting the real shell geometry at FOV 70 and scaling to
		the 384-tall viewport this game actually reports from phones:

		  standoff 7.0 (eye 7.18 out)   chunk 41 px wide
		  standoff 5.4 (eye 5.63 out)   chunk 54 px wide

		and those are FULL CUBE WIDTHS. The clumps overlap at about 1.25x
		coverage -- that overlap is what hides the prize -- so the patch actually
		exposed to a tap is nearer 37 px and 48 px. Touch-target guidance is 44,
		and a fingertip contact patch is 45 to 57.

		So at the current standoff the touch player is aiming at something about
		the size of their own fingertip, and it is underneath it while they do.
		A MOUSE POINTING AT A 37-PIXEL TARGET IS POINTING AT SOMETHING ENORMOUS,
		which is why this ladder has always been fine on desktop and why the wash
		is the measured drop-off step of the onboarding funnel.

		5.4 clears the guidance with room to spare and is about 1.7x the area.
		This is the same remedy the clump count already applied once (34 down to
		22, "the honest way to buy that back"): make the target bigger rather
		than have the tool guess what was meant. The aiming itself stays exactly
		as honest as it is on desktop -- see the ONE RAY FROM THE CURSOR note.

		Still a ladder, still filtered through eyeInOpenAir and seesWholeLump,
		so a cramped bay degrades exactly as it did. The heights come down with
		the standoffs to hold the original shot's angle (1.6/7.0 is 0.23; 1.3/5.4
		is 0.24) rather than tipping into a top-down view of the lump.

		If the wash step's churn does not move after this ships, the next lever
		is the near-miss snap the header describes -- but bounded to a fingertip
		and touch-only, which is a far narrower thing than the unbounded one that
		was removed.
	]]
	local SHOTS = aimsWithAFinger() and {
		{ 5.4, 1.3 },   -- the shot we actually want on a phone
		{ 5.4, 2.6 },   -- same standoff, over a low awning
		{ 5.0, 1.8 },
		{ 6.2, 1.6 },
		{ 6.2, 2.4 },
		{ 4.8, 1.2 },   -- inside a shallower shelter
		{ 7.0, 1.6 },   -- the desktop shot, as the last resort rather than none
	} or {
		{ 7.0, 1.6 },   -- the shot we actually want
		{ 7.0, 3.2 },   -- same standoff, over a low awning
		{ 6.2, 2.4 },
		{ 6.2, 1.6 },
		{ 5.4, 1.6 },   -- inside a shallower shelter
		{ 5.4, 3.4 },
		{ 4.8, 1.4 },
	}

	-- Radius of the crust shell plus a chunk, so the corner rays land on the
	-- outside of the rock rather than inside it.
	local SPAN = 1.7

	local function seesWholeLump(eye: Vector3): boolean
		local toward = focus - eye
		local flat = Vector3.new(-toward.Z, 0, toward.X)
		flat = flat.Magnitude > 0.01 and flat.Unit or Vector3.new(1, 0, 0)
		for _, offset in
			{ Vector3.zero, flat * SPAN, -flat * SPAN, Vector3.yAxis * SPAN, -Vector3.yAxis * SPAN }
		do
			local target = focus + offset
			if workspace:Raycast(eye, target - eye, params) then
				return false
			end
		end
		return true
	end

	--[[
		AND THE EYE ITSELF HAS TO BE STANDING IN OPEN AIR.

		seesWholeLump tests the LINE from the eye to the rock and nothing else. It
		says nothing about where the eye is, and a raycast whose origin is already
		inside a part does not report that part -- so a camera placed INSIDE the
		bay's side wall passes all five sightline rays and then renders from within
		the wall. That is the shot that had a slab of wall filling the screen.

		Cast the other way to catch it: from the focus, which is the lump and is
		known to be in open air, out to the candidate. Anything hit on the way means
		the candidate is behind it.

		CLEAR_BEHIND is the room the jet's recoil needs. The shove is small -- 0.4
		studs at full spray, see the kick spring in onRender -- but it moves the
		camera BACKWARD, and a position that was validated flush against a wall is
		exactly the one that ends up inside it the moment the trigger goes down.
		Which is why this only ever went wrong while actually washing.
	]]
	local CLEAR_BEHIND = 0.9

	local function eyeInOpenAir(eye: Vector3): boolean
		local toEye = eye - focus
		if toEye.Magnitude < 0.01 then
			return false
		end
		return workspace:Raycast(focus, toEye.Unit * (toEye.Magnitude + CLEAR_BEHIND), params) == nil
	end

	--[[
		AND IF NO FRAMING ON THIS AXIS WORKS, TURN.

		Every shot in the ladder above sits on ONE line: the one from the lump out
		toward wherever the player happened to be standing when they mounted.
		Approach the bay from the side and that line runs into a side wall, and no
		amount of standoff or height along it will ever be clear -- there was
		nothing in the ladder that could say so.

		The direction is a ladder too, then, but a SECOND one: every framing on the
		player's own axis is tried before any of it turns. Their approach is still
		what the shot wants to use, and turning is only what it does when that is
		impossible -- so a bay that was already framing correctly is untouched.
	]]
	local TURNS = { 0, 40, -40, 80, -80, 130, -130, 180 }

	local eye
	for _, turn in TURNS do
		local facing = (turn == 0) and dir or (CFrame.Angles(0, math.rad(turn), 0) * dir)
		for _, shot in SHOTS do
			local candidate = focus + facing * shot[1] + Vector3.new(0, shot[2], 0)
			if eyeInOpenAir(candidate) and seesWholeLump(candidate) then
				eye = candidate
				break
			end
		end
		if eye then
			break
		end
	end

	if not eye then
		-- Boxed in at every angle we are willing to take. Take the intended shot
		-- and stop just short of whatever is in the way -- never closer than 3.9,
		-- inside which the lump is wider than the frame.
		local want = focus + dir * SHOTS[1][1] + Vector3.new(0, SHOTS[1][2], 0)
		local blocked = workspace:Raycast(focus, want - focus, params)
		local reach = blocked and math.max((blocked.Position - focus).Magnitude - 0.6, 3.9)
			or (want - focus).Magnitude
		eye = focus + (want - focus).Unit * reach
	end

	--[[
		AND THE TOUCH SHOT AIMS A LITTLE BELOW THE LUMP, which lifts it in frame.

		MEASURED on a 397-tall viewport, rock bottom edge against the card's top
		row at y=273:

		  desktop 7.0            rock 131 px tall, bottom y=261   12 px clear
		  touch 5.4, no drop     rock 170 px tall, bottom y=277   -4 px OVERLAP
		  touch 5.4, drop 0.43   rock 171 px tall, bottom y=255   18 px clear

		That twelve-pixel gap is the entire reason the card was parked at the
		bottom in the first place -- see the note by holder.Position. Zooming in
		without compensating eats it and four pixels more, and that does not
		merely HIDE the lowest clumps: onInputBegan bails on `processed`, so a
		clump behind the card cannot be tapped at all. It would have traded a
		bigger target for a dead zone.

		0.43 studs is 5.5% of the 7.77-stud frame at this standoff, so it lifts
		the rock 22 px and ends up with MORE clearance than the shot it replaces,
		while the clumps stay 1.31x bigger. There is ample headroom above (the
		rock's top edge lands at y=84), so nothing is lost at the other end.

		Desktop drops nothing and is byte-for-byte the shot it always was.
	]]
	local aimDrop = aimsWithAFinger() and 0.43 or 0
	S.targetFocus = CFrame.lookAt(eye, focus - Vector3.new(0, aimDrop, 0))
	S.focusCFrame = c.CFrame
	c.CameraType = Enum.CameraType.Scriptable
end

local function exitCamera()
	local c = cam()
	if S.prevCameraType then
		c.CameraType = S.prevCameraType
		if S.prevCameraSubject then
			c.CameraSubject = S.prevCameraSubject
		end
	else
		c.CameraType = Enum.CameraType.Custom
	end
	S.prevCameraType, S.prevCameraSubject = nil, nil
	S.focusCFrame, S.targetFocus = nil, nil
end

--[[
	WALKING CONTROL  --  and why this is spawned rather than called inline

	Resolving PlayerModule the first time YIELDS (two WaitForChilds). beginSession
	and endSession are RemoteEvent handlers, and a yield inside one of them lets
	the other run to completion in the middle of it. That is not theoretical: walk
	away from the bay and come straight back and you get

		endSession   ... exitCamera, setControls(true) -- YIELDS here
		beginSession S.active = true, S.total = 14, ... enterCamera, hud on
		endSession   ...resumes... S.model = nil, S.total = 0, hud off
		beginSession ...resumes... hud on

	and the bay opens for real -- camera framed, washer in hand, HUD up -- on a
	session whose model and totals have just been wiped by the previous one. The
	jet has nothing to hit, the bar is pinned at 0%, and nothing the player does
	moves it. That is the "I'm at the washing station and there is no way to wash
	anything" bug.

	So the handlers must never yield. Everything they touch is now synchronous;
	this is the one call that was not, and it hands the work to its own thread.
	`wanted` is read at APPLY time rather than captured, so if the two states
	flip while the module is still resolving, the last intent is the one that
	lands -- there is no ordering to lose.
]]
local controlsModule
local controlsWanted = true

local function setControls(enabled: boolean)
	controlsWanted = enabled
	task.spawn(function()
		if not controlsModule then
			local ok, res = pcall(function()
				local ps = player:WaitForChild("PlayerScripts", 10)
				return require(ps:WaitForChild("PlayerModule", 10)):GetControls()
			end)
			controlsModule = ok and res or nil
		end
		if not controlsModule then
			return
		end
		if controlsWanted then
			controlsModule:Enable()
		else
			controlsModule:Disable()
		end
	end)
end

--[[
	AND THE CHARACTER IS PINNED WHILE THE BAY HAS THEM.

	Disabling the control module stops the player DRIVING the character, which is
	most of it but not a promise the character cannot move: anything else that
	writes a move direction, or any control path that slips back on, walks them
	out of a shot the camera is still framing.

	WALKSPEED RATHER THAN ANCHORING THE ROOT. Anchoring fights physics and the
	respawn path, and leaves a character hanging in the air if the ground streams
	out from under it. Zero speed is reversible and costs nothing.

	RESTORED FROM WHAT WAS THERE, not from 16: ProgressionServer writes WalkSpeed
	off the BeachLegs track, so the right value to put back is per player and per
	upgrade level, and this session is the only thing that knows it.

	ASKED FOR AGAIN ON THE WAY OUT, NOT HANDED BACK FROM THE CAPTURE. (2026-09-09:
	"an upgrade bought while pinned in the wash bay is undone when the session
	ends".) The store counter and the home bay are 26 studs apart in the same
	plaza and the shop panel is still usable while the bay has you, so a player
	CAN buy Beach Legs mid-wash. Their coins went, ProgressionServer wrote the new
	speed, the per-frame pin at the tail of the render step put it straight back
	to 0 -- and then this restore handed them the number captured BEFORE the
	purchase. They walked away at the old speed with the shop showing a level they
	were not getting, until something else happened to re-apply.

	BaseWalkSpeed is ProgressionServer publishing what it last derived -- the same
	attribute AfkClient restores from, for the same reason -- so reading it here
	means the bay hands back whatever is true NOW rather than what was true on
	entry. The capture stays as the fallback for the window before the server has
	written an attribute at all; it is still the best answer this client has on
	its own. Nothing about how the bay PINS the player changed.
]]
local function lockWalking(on: boolean)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	if on then
		-- Only the FIRST lock records it. beginSession runs again on a resume, and
		-- capturing then would save the zero this already wrote.
		if S.prevWalkSpeed == nil then
			S.prevWalkSpeed = hum.WalkSpeed
		end
		hum.WalkSpeed = 0
	elseif S.prevWalkSpeed ~= nil then
		-- Guarded rather than a plain `or`: a missing, zero or non-number attribute
		-- would leave them pinned for good, and the capture is a speed we KNOW
		-- walked, so it is the safe thing to fall back to.
		local live = player:GetAttribute("BaseWalkSpeed")
		if typeof(live) ~= "number" or live <= 0 then
			live = S.prevWalkSpeed
		end
		hum.WalkSpeed = live
		S.prevWalkSpeed = nil
	end
end

--[[
	THE BAY'S OWN "MOUNT CRUSTED FIND" PROMPT, PUT AWAY FOR THE SESSION.

	It hangs off PromptAnchor, a stud or two in front of the stand -- which is
	exactly where the camera is pointed for the whole wash. So the invitation to
	mount a rock floated over the rock you are already scrubbing, offering to
	start the thing you are in the middle of.

	LOCALLY, AND THAT IS THE WHOLE TRICK. There is ONE prompt per bay, built and
	owned by WashServer and shared by everybody stood near it, so switching it off
	on the server would take it away from the player waiting their turn as well. A
	property written on the client is not replicated, so this hides it on THIS
	screen and nowhere else. Safe because WashServer never writes Enabled after
	creating the prompt -- it would otherwise stamp on this the next time it did.

	The instance is remembered rather than looked up again on the way out, and the
	previous value is honoured, so a prompt that was already disabled by something
	else is not switched ON by us when the session ends.
]]
local hiddenPrompt: ProximityPrompt? = nil

local function hideBayPrompt(bay: Instance?)
	-- beginSession runs again on a resume; the first call is the one that counts.
	if hiddenPrompt or not bay then
		return
	end
	local p = bay:FindFirstChildWhichIsA("ProximityPrompt", true)
	if p and p.Enabled then
		p.Enabled = false
		hiddenPrompt = p
	end
end

local function showBayPrompt()
	if hiddenPrompt then
		if hiddenPrompt.Parent then
			hiddenPrompt.Enabled = true
		end
		hiddenPrompt = nil
	end
end

local function beginSession(payload)
	if not (payload and payload.model and payload.stand) then
		return
	end
	local resuming = S.active

	S.active = true
	S.bay = payload.bay
	hideBayPrompt(payload.bay)
	--[[
		AND EVERYBODY ELSE OUT OF THE FRAME, which is asked for rather than done
		here.

		clearShot below veils what belongs to THIS player -- their body, their
		tool, their sifter and their pets. Other beachgoers wander through the
		same seven studs the camera is looking down, and they need the identical
		treatment across their character, their pets and the rake replica drawn
		for them: exactly the sweep MenuHud already runs for the "Hide Other
		Beachgoers" setting.

		SO IT IS THE SAME SWEEP, not a second one. Two systems writing
		LocalTransparencyModifier on one part, each recording what it believes the
		"original" was, is how somebody ends up permanently invisible: whichever
		one records second captures the other's 1 as the resting value and hands
		it back on release. One owner, one record. MenuHud watches this attribute
		and ORs it with the player's own setting, so a session hides everyone for
		its length and leaving puts back whatever the setting actually says.
	]]
	player:SetAttribute("WashInBay", true)
	S.stand = payload.stand
	S.model = payload.model
	S.crust = payload.model:FindFirstChild("Crust")
	-- What this lump is made of -- dirt, or packed snow off Penguin Island. The
	-- server stamps it on the mount (ItemVisuals.buildEncased) and it survives
	-- the id being stripped; it decides the erosion tones, the grit that blasts
	-- off and the clumps that tip off the plate, so the grit emitter is
	-- re-made here whenever the stuff changes.
	S.crustStyle = payload.model:GetAttribute("CrustStyle") or "dirt"
	if fx.impactPart then
		if fx.grit then
			fx.grit:Destroy()
		end
		fx.grit = ItemVisuals.makeGritEmitter(fx.impactPart, S.crustStyle)
	end
	S.uid = payload.uid
	-- Fallback via ItemConfig, never a literal. The client cannot look a lump's
	-- chunk count up by item id -- the whole point of a lump is that its
	-- identity is hidden -- so this is the one number it has to be told or
	-- assume, and an assumption that drifts from the real crust draws a bar
	-- that finishes at the wrong chunk.
	S.total = payload.chunkTotal or ItemConfig.CrustChunkCount
	-- Seeded from the server's own array when there is one. A lump the player
	-- walked away from half-washed comes back with its chunks already eroded and
	-- the finished ones already destroyed, so starting the local prediction at
	-- all-zeros would draw a full rock over a hollow one for a tenth of a second.
	local seed = (type(payload.chunks) == "table") and payload.chunks or nil
	S.chunks = {}
	for i = 1, S.total do
		local v = seed and seed[i]
		S.chunks[i] = (type(v) == "number") and math.clamp(v, 0, 1) or 0
	end
	S.remaining = tonumber(payload.remaining) or S.total
	S.chunkWork = CFG.ChunkWork -- Toughness is server-side; prediction is close enough
	S.revealName, S.revealColor = nil, nil

	-- Paint the part-worn chunks. Only the partial ones exist to paint: anything
	-- at 1 was destroyed server-side and has already replicated away.
	if seed then
		for i = 1, S.total do
			local t = S.chunks[i]
			if t > 0 and t < 1 then
				local chunk = ItemVisuals.findChunk(payload.model, i)
				if chunk then
					ItemVisuals.setChunkErosion(chunk, t, S.crustStyle)
				end
			end
		end
	end

	findTool()
	ensureFx()
	-- Guarded internally, so auto-advance keeps the plate and pan it has been
	-- filling. The heap surviving from one lump to the next IS the accumulation;
	-- resetting it per lump would throw away the only thing in the bay that gets
	-- bigger.
	ensureSilt()

	-- The washer is lent out by the bay at the moment the session opens, so it
	-- can replicate a frame or two AFTER this message arrives. findTool only
	-- runs once, and ensureFx only builds the jet emitter if it found a nozzle,
	-- so losing that race used to mean a whole wash with no spray leaving the
	-- lance. Wait for the tool instead of assuming it beat the message here.
	if not S.nozzle then
		task.spawn(function()
			local deadline = os.clock() + 5
			while S.active and not S.nozzle and os.clock() < deadline do
				task.wait(0.05)
				findTool()
			end
			if S.active and S.nozzle then
				ensureFx()
			end
		end)
	end

	if not resuming then
		startAudio(S.nozzle or S.stand)
		enterCamera(S.stand)
		setControls(false)
		lockWalking(true)
		clearShot()
	end

	AudioKit.play("Mount", S.stand, 1.2)
	UserInputService.MouseIconEnabled = true

	if hud.gui then
		hud.gui.Enabled = true
	end
end

local function endSession()
	if not S.active then
		return
	end
	S.active = false
	S.triggering = false
	S.spray = 0
	S.aimIndex, S.aimPoint = nil, nil
	S.chain, S.chainStep, S.charge, S.flash = 0, 0, 0, 0

	if fx.jet then
		fx.jet.Enabled = false
		fx.jet.Rate = 0
	end
	if fx.impact then
		fx.impact.Enabled = false
		fx.impact.Rate = 0
	end
	if fx.grit then
		fx.grit.Enabled = false
		fx.grit.Rate = 0
	end
	clearFx()
	clearSilt()
	stopAudio()
	exitCamera()
	setControls(true)
	lockWalking(false)
	showBayPrompt()
	player:SetAttribute("WashInBay", false)
	restoreShot()

	S.bay, S.stand, S.model, S.crust, S.uid = nil, nil, nil, nil, nil
	S.total, S.remaining = 0, 0
	S.chunks = {}
	S.revealName, S.revealColor = nil, nil

	if hud.gui then
		hud.gui.Enabled = false
	end
end

--------------------------------------------------------------------------
-- FRAME
--------------------------------------------------------------------------

local function onRender(dt: number)
	dt = math.min(dt, 1 / 30)
	if not S.active then
		return
	end

	updateAim()

	--[[
		THE JET IS ON WHENEVER THE TRIGGER IS DOWN. CLEANING IS A SEPARATE
		QUESTION.

		These used to be the same flag, and the tool read as broken because of
		it: point slightly off the rock, hold the trigger, and NOTHING happened.
		No water, no motor, no sound, no recoil -- a dead prop in your hands. A
		pressure washer that only turns on when it is already aimed at something
		is not a tool the player is operating, it is a switch the game is
		flipping for them.

		`jetting` drives everything about the tool RUNNING: spray, motor, sound,
		view kick, and the splash where the water lands.
		`firing` stays the narrow question -- is that water on crust right now --
		and still gates work, packets, grit and silt. So you can hose the shack
		wall all day and clean exactly nothing, which is correct.
	]]
	local jetting = S.triggering
	local firing = jetting and S.aimIndex ~= nil
	local target = jetting and 1 or 0
	local rate = (target > S.spray) and 22 or 8
	S.spray += (target - S.spray) * (1 - math.exp(-dt * rate))

	-- How far gone the chunk under the reticle is. Eased rather than read raw:
	-- the aim ray flicks between chunks as the mouse moves, and a charge that
	-- snapped to each new one would strobe the reticle and the spray pitch
	-- together every time the player drifted a few pixels.
	local want = S.aimIndex and math.min(S.chunks[S.aimIndex] or 0, 1) or 0
	S.charge += (want - S.charge) * (1 - math.exp(-dt * 12))

	-- A chain survives a slip but not a stall. Checked here rather than at the
	-- pop, because the interesting case is the player who has STOPPED breaking
	-- chunks -- there is no pop left to hang it on.
	local now = os.clock()
	if S.chain > 0 and now - S.lastChunk > CHAIN_WINDOW then
		-- Only mourn a chain that was worth having. A tick on every two-chunk
		-- fumble would be nagging, not loss.
		if S.chain >= 4 then
			AudioKit.play("StreakBreak", S.stand)
		end
		S.chain, S.chainStep = 0, 0
	end
	S.flash = math.max(0, S.flash - dt * 2.5)

	updateSilt(dt, firing)

	-- Local prediction, capped below 1 so the POP is always the server's call.
	if firing then
		local i = S.aimIndex
		-- Instant Wash: the clump is spent the moment the jet lands on it, so the
		-- prediction goes straight to the cap instead of easing there. Still the
		-- CAP and not 1 -- the pop is a server event either way, and a client that
		-- drew the break itself would be drawing it on a lie.
		if instantOwned then
			S.chunks[i] = 0.99
		else
			--[[
				THE TUTORIAL'S BOOST RIDES HERE TOO, and only the pressure half
				of it does. The server's other two favours -- the reach floor and
				the redirect off a dead clump -- both land as WashChunkGone
				messages, which this file already draws; predicting them as well
				would be predicting the same break twice.
			]]
			local boost = TutorialConfig.washIsEasy(player)
				and TutorialConfig.WashBoostPressure or 1
			S.chunks[i] = math.min(0.99,
				(S.chunks[i] or 0) + boost * pressure() * dt / S.chunkWork)
		end
		local chunk = ItemVisuals.findChunk(S.model, i)
		if chunk then
			ItemVisuals.setChunkErosion(chunk, S.chunks[i], S.crustStyle)
		end

		-- The whole client -> server payload: WHICH chunk, ~15x a second. No
		-- amount, no duration -- WashServer times the gap on its own clock and
		-- multiplies by the pressure tier it already knows, so there is nothing
		-- here to inflate. Without this line the crust darkens locally and never
		-- actually comes off, which is exactly how it read for players.
		--[[
			FOR A PASS HOLDER THE PACKET RATE IS THE WASH SPEED.

			WashServer spends one packet on one whole clump for them, so fifteen a
			second would put a 22-piece lump at a second and a half -- fast, but
			visibly a countdown rather than the rock giving way. Thirty clears it
			in about three quarters of a second.

			Thirty and not more because the SERVER decides what it will accept:
			GameConfig.Washing.MaxPacketsPerSecond is 40 and MinPacketInterval is
			0.02. Sending faster than the cap does not wash faster, it just gets
			packets dropped, and asking for a rate this file cannot see the limit
			of is how a client ends up throttled by its own game. Retune the two
			together or not at all.
		]]
		local now = os.clock()
		local every = instantOwned and (1 / 30) or (1 / 15)
		if now - S.lastSend >= every then
			S.lastSend = now
			Net.get("WashAim"):FireServer({ chunk = i })
		end
	end

	-- Jet + impact placement
	if fx.jet then
		fx.jet.Enabled = S.spray > 0.05
		fx.jet.Rate = S.spray * 260

		--[[
			AND IT HAS TO STOP WHERE IT IS AIMED.

			Speed and Lifetime were fixed, so the water flew the same 11 to 24
			studs whatever it was pointed at -- past a lump five studs away and
			on into the sky behind it. The splash landed in the right place, the
			stream did not, and what the player sees is the stream.

			So the speed is solved from the actual distance to the aim point:
			cross it in one lifetime and the particles die exactly where they
			land. The small spread either side of that is what keeps it looking
			like water rather than a solid rod.
		]]
		local from = view.muzzle or S.muzzle
		if from and S.aimPoint then
			local reach = (S.aimPoint - from.WorldPosition).Magnitude
			local life = JET_LIFETIME
			fx.jet.Lifetime = NumberRange.new(life * 0.86, life)
			local v = reach / life
			fx.jet.Speed = NumberRange.new(v * 0.94, v * 1.10)

			--[[
				AND THE DROPLETS THIN DOWN WITH IT.

				The sizes in makeJetEmitter were drawn against the old fixed
				throw of 11 to 24 studs. Stopping the stream at its target
				without touching them left the wash bay -- which frames the lump
				about two studs off the muzzle -- putting 0.9-stud droplets along
				a 2.3-stud stream. Measured, that is 2.5:1, barely longer than it
				is wide: a blob sitting on the nozzle rather than a jet.

				Scaling with reach holds the stream's length-to-width near what
				it was drawn at -- 11.5:1 at the bay's range -- so it reads the
				same close up as far out. The floor stops a very short shot
				vanishing: here it lands near 0.2 studs, about the bore of the
				nozzle it comes out of, which is what a jet should be.

				Rate is deliberately untouched. Smaller droplets at the same rate
				pack closer together, and a short stream wants to be dense;
				thinning both would have made it a dotted line.
			]]
			local k = math.clamp(reach / JET_SIZE_REACH, JET_SIZE_MIN, 1)
			-- Rebuilt only when it actually moves: this runs every frame of a
			-- wash, and a NumberSequence is a fresh allocation each time.
			if not fx.jetSize or math.abs(k - fx.jetSize) > 0.02 then
				fx.jetSize = k
				fx.jet.Size = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.12 * k),
					NumberSequenceKeypoint.new(0.6, 0.5 * k),
					NumberSequenceKeypoint.new(1, 0.9 * k),
				})
			end
		end
	end
	if fx.impactPart then
		if S.aimPoint then
			fx.impactPart.Position = S.aimPoint
		end
		-- Water splashes wherever it lands, crust or not -- updateAim keeps
		-- S.aimPoint pointed at the world when there is no clump under the
		-- cursor. GRIT is the one that stays honest: nothing comes off a wall.
		local wet = jetting and S.aimPoint ~= nil
		local on = firing and S.aimPoint ~= nil
		if fx.impact then
			fx.impact.Enabled = wet
			fx.impact.Rate = wet and 150 or 0
		end
		if fx.grit then
			fx.grit.Enabled = on
			fx.grit.Rate = on and 70 or 0
		end
	end

	-- Camera: ease into frame, plus a small shove back while the jet is on.
	if S.focusCFrame and S.targetFocus then
		S.focusCFrame = S.focusCFrame:Lerp(S.targetFocus, 1 - math.exp(-dt * 6))

		local k, c = 120, 14
		local want = S.spray * 0.16
		S.kickVel += (-k * (S.kick - want) - c * S.kickVel) * dt
		S.kick += S.kickVel * dt
		S.kick = math.clamp(S.kick, -0.4, 0.4)

		local jitter = S.spray * 0.012
		local offset = CFrame.new(
			(math.random() - 0.5) * jitter,
			(math.random() - 0.5) * jitter,
			S.kick
		)
		-- ALWAYS from focusCFrame, never from the camera's own current frame:
		-- multiplying into itself compounds every frame and drifts into space.
		cam().CFrame = S.focusCFrame * offset
	end

	-- AFTER the camera, always: the wand is pinned to it, and hanging it off
	-- last frame's camera is what makes a viewmodel swim behind the shot.
	updateViewModel(dt, firing)

	updateAudio(dt)
	updateHud()

	-- RE-ASSERT THE PIN. ProgressionServer rewrites WalkSpeed from the BeachLegs
	-- track whenever it re-applies, and a respawn or a purchase landing during a
	-- session would otherwise hand movement back with nothing noticing. A
	-- comparison every frame, a write only when something has moved it.
	if S.active then
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum and hum.WalkSpeed ~= 0 then
			hum.WalkSpeed = 0
		end
	end
end

--------------------------------------------------------------------------
-- INPUT
--------------------------------------------------------------------------

--[[
	ONE DOOR OUT, ASKED FOR AT MOST TWICE A SECOND.

	JumpRequest REPEATS while the key is held, and the server answers a leave with
	a WashEnd that takes a round trip to come back -- so a held space would fire a
	dozen requests for one exit, and the bay would spend the trip answering all of
	them. Every way out goes through here.
]]
local lastLeaveAsk = 0

local function requestLeave()
	if not S.active then
		return
	end
	local now = os.clock()
	if now - lastLeaveAsk < 0.5 then
		return
	end
	lastLeaveAsk = now
	Net.get("WashEndRequest"):FireServer()
end

local function onInputBegan(input: InputObject, processed: boolean)
	if processed or not S.active then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
	then
		S.triggering = true
	elseif input.KeyCode == Enum.KeyCode.Q or input.KeyCode == Enum.KeyCode.Backspace
		or input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA
	then
		-- Space and A as well as JumpRequest below. JumpRequest is the tidy hook
		-- but it is raised by the control module, which this session has just
		-- switched off -- so the raw key is what actually guarantees the exit.
		requestLeave()
	end
end

local function onInputEnded(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
	then
		S.triggering = false
	end
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

----------------------------------------------------------------
-- THE BAY KEY  --  ONE STOCK PROMPT AND ONE HOUSE BUTTON, ON TOUCH
----------------------------------------------------------------
--[[
	THE WASH BAY IS THE ONLY PLACE IN THIS GAME THAT HANGS TWO STOCK PROMPTS OFF
	ONE ANCHOR, AND ON A PHONE THAT IS THE WHOLE BUG.

	E and R make Mount and Throw Away unmistakable on a desktop. On touch there is
	no key: Roblox draws one tappable box per prompt, both 72px tall, both hanging
	on the same PromptAnchor, both grey, both talking about the same crusted rock.
	The gap between them has now been 0px, then 16px of overlap, then 12px -- three
	passes at the same control -- and Yipyap0081 has reported it three times.

	SO ON TOUCH THERE IS ONLY ONE PROMPT LEFT. The mount prompt stays exactly as
	it is: the engine's own, which is designed to be tapped. The BIN prompt stops
	being drawn at all and becomes the button below, in a ScreenGui this game owns
	-- house colours, a real 44px target, and nowhere near the other one.

	WHY NOT DRAW BOTH OURSELVES. EggClient already tried that and wrote up what it
	cost: Style = Custom with a BillboardGui holding "three things, none of them
	clickable" meant "a touch player could stand on top of any of the ten stations
	and never open one". Its conclusion is the rule this follows -- touch keeps the
	engine's prompt for the way IN, and the game draws only the extra.

	THE BUTTON DRIVES THE PROMPT, NOT A REMOTE. InputHoldBegin/End on the real bin
	prompt makes the server see an engine-validated Triggered, so WashServer's
	proof that the player is standing at the bay is untouched. That is EggClient's
	pattern too, and it is the reason this adds no remote and no server change.

	SHOWN OFF PromptShown/PromptHidden rather than a distance poll: the engine
	already knows when the player is in range, and a Custom-styled prompt fires
	both signals without drawing anything.
]]
local bayKey = { gui = nil, face = nil, prompt = nil }

local function buildBayKey()
	local gui = Instance.new("ScreenGui")
	gui.Name = "WashBayKey"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	-- Above Roblox's TouchGui (0) for the reason CTB_HUD writes out at length --
	-- a tie is not an ordering and the thumbstick wins it. 10 sits beside the
	-- wash HUD's own 9 and still under every panel.
	gui.DisplayOrder = 10
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	--[[
		RIGHT OF CENTRE, AND THAT IS MEASURED. Roblox's DynamicThumbstick claims
		x -100..266 on a 666-wide phone, so a 200-wide button centred on the screen
		would put its left third under the moving thumb. At 0.62 of the width it
		spans about x 323..503 and clears the region outright.
	]]
	local holder = Instance.new("Frame")
	holder.Name = "Key"
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.new(0.62, 0, 1, -104)
	holder.Size = UDim2.fromOffset(200, 56)
	holder.BackgroundTransparency = 1
	holder.Parent = gui

	-- Coral, which is this game's colour for the destructive key: TAKE OFF in the
	-- pets panel wears it for the same reason.
	local face = PanelKit.chunky(holder, 200, 56, PanelKit.C.coral, 16)
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.5, 0.5)

	local lbl = PanelKit.text(face, "THROW AWAY", 20, Enum.Font.LuckiestGuy, PanelKit.C.white)
	lbl.AnchorPoint = Vector2.new(0.5, 0)
	lbl.Position = UDim2.new(0.5, 0, 0, 6)
	lbl.Size = UDim2.new(1, 0, 0, 24)
	lbl.ZIndex = 8
	PanelKit.punch(lbl, 2)

	-- Says WHAT it throws away, which is the correction the prompt's own copy
	-- already carries: three players read "throw away" as a bin for their litter.
	local sub = PanelKit.text(face, "crusted finds only", 13, Enum.Font.GothamBold, PanelKit.C.white)
	sub.AnchorPoint = Vector2.new(0.5, 1)
	sub.Position = UDim2.new(0.5, 0, 1, -6)
	sub.Size = UDim2.new(1, 0, 0, 16)
	sub.ZIndex = 8
	sub.TextTransparency = 0.15

	-- chunky returns a Frame, so the press needs a real button laid over it --
	-- see the same correction in TravelHud.
	local hit = Instance.new("TextButton")
	hit.Name = "Hit"
	hit.Size = UDim2.fromScale(1, 1)
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.AutoButtonColor = false
	hit.ZIndex = 20
	hit.Parent = face
	TouchFit.press(hit, function()
		local p = bayKey.prompt
		if not (p and p.Parent) then
			return
		end
		-- The engine's own door, so the server still sees a validated Triggered.
		p:InputHoldBegin()
		task.wait(0.05)
		p:InputHoldEnd()
	end)

	bayKey.gui = gui
	bayKey.face = face
end

local function wireBayKey()
	--[[
		TouchEnabled, NOT aimsWithAFinger(), AND THE DIFFERENCE IS A RACE THIS
		FEATURE LOST EVERY TIME ON THE DEVICE IT WAS WRITTEN FOR.

		This used to read `if not aimsWithAFinger() then return end`. That helper is
		right for its other two callers and wrong for this one, and its own note
		says why without quite noticing: "Read when the camera is solved, which is
		ONCE AT THE START OF A WASH, so it cannot flip halfway through one." Both
		camera callers honour that. This one does not -- `wireBayKey` runs from
		`start()`, at client boot, before the player has touched anything.

		So walk the helper at boot on a phone:

		  TouchEnabled and not MouseEnabled -> the note directly above the helper
		    records that Roblox reports BOTH true on plenty of touch devices, so
		    this branch cannot be relied on to fire.
		  GetLastInputType() == Touch     -> MEASURED at boot, 2026-09-23: the
		    engine reports Enum.UserInputType.FOCUS. Not Touch, not Mouse, not
		    Keyboard -- Focus, because nothing has been input yet. It is never
		    Touch at this moment on ANY device, so this branch is not a race that
		    is sometimes lost. It is dead on arrival, every boot, everywhere.

		Which means the old gate reduced to its FIRST branch alone, and the note
		directly above the helper is what that branch runs into: Roblox reports
		TouchEnabled AND MouseEnabled true on plenty of touch devices. On every one
		of those, the gate returned false and this entire section did nothing.

		Both branches fail, wireBayKey returns, and the phone gets NEITHER half of
		the fix: the bin prompt is never hushed AND the house button is never
		built. What is left is the original defect exactly -- two stock prompts,
		both 72px, both grey, both about the same rock, on one anchor. Which is the
		bug this whole section was written to remove, and which Yipyap0081 has now
		reported three times from a 750x390 phone.

		TouchEnabled IS settled at boot, because it is a property of the device
		rather than of what the player has done yet. It is the right question here
		for the same reason GetLastInputType is the right one for the camera: this
		decides whether a CONTROL can be reached, not which shot to frame.

		AND IT COSTS A DESKTOP-WITH-A-TOUCHSCREEN NOTHING, which is the case the
		old gate was protecting. Style = Custom stops the engine DRAWING a prompt;
		it does not stop it accepting input, so R keeps working exactly as it did.
		The button is an ordinary TextButton, so a mouse click drives it too. Such a
		player gains a second way to bin and loses none.

		A PURE DESKTOP IS STILL LEFT ALONE: TouchEnabled is false there, this
		returns, and E and R go on telling the two actions apart.
	]]
	if not UserInputService.TouchEnabled then
		return
	end

	buildBayKey()

	-- Stop the engine drawing the bin prompt. Local only -- a client write to a
	-- replicated instance does not travel -- so the server's prompt is untouched
	-- and every desktop player still sees it.
	local function hush(model: Instance)
		for _, d in model:GetDescendants() do
			if d:IsA("ProximityPrompt") and d.Name == "BinPrompt" then
				d.Style = Enum.ProximityPromptStyle.Custom
			end
		end
	end
	for _, m in CollectionService:GetTagged("WashBay") do
		hush(m)
	end
	CollectionService:GetInstanceAddedSignal("WashBay"):Connect(hush)

	ProximityPromptService.PromptShown:Connect(function(prompt)
		if prompt.Name ~= "BinPrompt" then
			return
		end
		bayKey.prompt = prompt
		if bayKey.gui then
			bayKey.gui.Enabled = true
		end
	end)
	ProximityPromptService.PromptHidden:Connect(function(prompt)
		if prompt.Name ~= "BinPrompt" then
			return
		end
		if bayKey.prompt == prompt then
			bayKey.prompt = nil
		end
		if bayKey.gui then
			bayKey.gui.Enabled = false
		end
	end)
end

local started = false
function WashClientController.start()
	if started then
		return
	end
	started = true

	buildHud()
	wireBayKey()

	Net.get("WashBegin").OnClientEvent:Connect(beginSession)
	Net.get("WashEnd").OnClientEvent:Connect(endSession)

	Net.get("WashChunkGone").OnClientEvent:Connect(function(payload)
		if not (S.active and payload and payload.chunk) then
			return
		end
		local i = payload.chunk
		S.chunks[i] = 1
		S.remaining = math.max(0, S.remaining - 1)

		local chunk = ItemVisuals.findChunk(S.model, i)
		local dir = Vector3.new(0, 1, 0)
		-- Off the VIEWMODEL's muzzle where there is one, so flakes fly away from
		-- the lance the player can see rather than from the veiled one at their
		-- hip -- which is a different direction, and the wrong one on screen.
		local from = view.muzzle or S.muzzle
		if S.aimPoint and from then
			dir = (S.aimPoint - from.WorldPosition)
		end
		if chunk then
			-- The stand plate, for the clumps that happen to come down over it.
			-- It is only 2.4 studs square against a 3.5-stud rock, so the rock
			-- overhangs its own stand and most clumps miss -- popChunk tests the
			-- radius and lets the rest fall past, which is right: the drain pan
			-- is five studs lower and below the bottom of the shot, so there is
			-- nothing further down the player can see them land on.
			local land = S.stand and {
				y = S.stand.Position.Y + S.stand.Size.Y * 0.5,
				centre = S.stand.Position,
				radius = math.min(S.stand.Size.X, S.stand.Size.Z) * 0.5,
			} or nil
			ItemVisuals.popChunk(chunk, dir, land)
		end
		-- Rises as the lump empties, so the last chunk off a big find is audibly
		-- the top of a run. Gentler than the old 0.9..1.6: that sweep was set
		-- against a synthetic snap, and a real rock tick starts reading as a
		-- pebble rather than a crust well before the top of it.
		--
		-- QUIETER AND A TOUCH HIGHER than it was, because the clumps are now a
		-- third of the size and there are two and a half times as many of them.
		-- At the top pressure tier they come off about twelve a second: at the
		-- old level that is a drum roll, and small things should sound small
		-- anyway. The kit rotates four takes with 8% jitter underneath, so what
		-- this turns into at speed is a crackle rather than a repeated tick.
		AudioKit.play("ChunkPop", S.stand, 0.62,
			1.06 + (1 - S.remaining / math.max(S.total, 1)) * 0.45)
		S.kickVel += 1.6
		S.flash = 1
		-- Bloom a ring where it let go. The flake and the grit are world objects
		-- and read as debris; this is the HIT, and it has to be unmissable even
		-- when the rock is behind a wall of spray.
		popRing(S.aimPoint or (S.stand and S.stand.Position))
		-- The reticle emptying is the reset for the next chunk. Snapped, not
		-- eased: the core has just been spent.
		S.charge = 0

		-- THE CHAIN.
		local now = os.clock()
		S.chain = (now - S.lastChunk <= CHAIN_WINDOW) and (S.chain + 1) or 1
		S.lastChunk = now
		--[[
			ONE RUNG PER TWO CHUNKS, AND ONLY WHEN THE RUNG ACTUALLY CHANGES.

			This used to be a rung per chunk, fired every chunk. That was right
			when a lump was 14 pieces: the ladder climbed most of its length over
			a whole lump and topped out near the end. At 34 pieces the same code
			is wrong twice over -- it would hit rung 11 by the twelfth chunk and
			then play the top note twenty-two more times, and at the highest
			pressure tier chunks come off about twelve a second, so that is a
			stream of 3x-speed pings rather than a melody.

			The divisor spreads the ladder's eleven rungs across a whole lump, so
			it tops out at the end rather than a third of the way in -- at 22
			clumps that is one rung per two. Sounding it only on a CHANGE means
			eleven deliberate steps across a wash rather than one per chunk. The
			rung means what it always did; it just costs two chunks to earn.
			Retune this alongside ItemConfig.CrustChunkCount.
		]]
		if S.chain >= 2 then
			local step = math.min(math.floor((S.chain - 1) / 2) + 1, #LADDER)
			if step ~= S.chainStep then
				S.chainStep = step
				-- A struck tuning fork, transposed a rung at a time. That slot is
				-- declared with ZERO pitch jitter for exactly this reason: the
				-- ladder IS the pitch information, and random on top of it would
				-- read as the instrument being out of tune rather than as texture.
				AudioKit.play("StreakStep", S.stand,
					0.6 + (S.chainStep / #LADDER) * 0.5, LADDER[S.chainStep])
			end
		end

		-- The silt does not teleport onto the plate. The chunk blows off, and a
		-- beat later what is left of it LANDS, with a thud and a puff. That gap
		-- is the whole difference between debris falling and an object being
		-- deleted, and it is one task.delay.
		task.delay(LAND_DELAY, function()
			if not S.active then
				return
			end
			silt.load += SILT_PER_CHUNK
			-- Down low, so the landing has weight the pop above it does not.
			AudioKit.play("SandDrop", S.stand, 0.95, 0.6)
			if fx.grit and fx.impactPart then
				fx.grit:Emit(12)
			end
		end)
	end)

	--[[
		THE WHOLE SHELL AT ONCE  --  the instant wash pass landing.

		Deliberately NOT a loop over the WashChunkGone handler above. That one
		is written for a single chunk arriving in a rhythm: it climbs the chain,
		blooms a ring, plays a pop and schedules a silt drop. Twenty-two of those
		in one frame is twenty-two rings, a chain that jumps straight to x22, and
		a machine-gun of pops in front of a reveal that is about to fire anyway.

		So the burst is its own gesture: every clump thrown OUTWARD from the
		middle of the rock rather than along the jet -- the jet is not what took
		them off, and firing thirty clumps down one vector reads as a spray
		rather than as a shell coming apart -- one shatter, one ring, and the
		whole lump's silt landing together.

		EVERY LOOKUP IS ALLOWED TO MISS. The server destroyed these parts before
		it sent this message, so their removal is already on its way here; a
		chunk that has beaten the message simply is not popped. In practice the
		message wins, exactly as it does for WashChunkGone.
	]]
	Net.get("WashInstant").OnClientEvent:Connect(function(payload)
		if not (S.active and type(payload) == "table" and type(payload.chunks) == "table") then
			return
		end

		local centre = (S.model and S.model:GetPivot().Position)
			or (S.stand and S.stand.Position)
		if not centre then
			return
		end

		-- Same plate test the single-chunk path uses: the stand is 2.4 studs
		-- square under a 3.5-stud rock, so most of these fall past it and
		-- popChunk lets them.
		local land = S.stand and {
			y = S.stand.Position.Y + S.stand.Size.Y * 0.5,
			centre = S.stand.Position,
			radius = math.min(S.stand.Size.X, S.stand.Size.Z) * 0.5,
		} or nil

		local popped = 0
		for _, i in payload.chunks do
			if type(i) == "number" then
				S.chunks[i] = 1
				local chunk = ItemVisuals.findChunk(S.model, i)
				if chunk then
					ItemVisuals.popChunk(chunk, chunk.Position - centre, land)
					popped += 1
				end
			end
		end

		S.remaining = 0
		S.charge = 0
		S.flash = 1
		S.kickVel += 4

		-- ONE ring and ONE break, both at the rock. EggShatter is the kit's big
		-- version of the same four takes ChunkPop rotates -- an octave down and
		-- wider -- which is what a whole shell going at once should sound like.
		popRing(centre)
		AudioKit.play("EggShatter", S.stand, 1, 0.95)

		-- ...and the lump's whole silt load lands together, capped at a full
		-- plate. The reveal sluices it a beat later, so the plate fills and
		-- empties in one gesture rather than never appearing at all.
		task.delay(LAND_DELAY, function()
			if not S.active then
				return
			end
			silt.load = math.min(1, silt.load + popped * SILT_PER_CHUNK)
			AudioKit.play("SandDrop", S.stand, 1.1, 0.55)
			if fx.grit and fx.impactPart then
				fx.grit:Emit(26)
			end
		end)
	end)

	Net.get("WashProgress").OnClientEvent:Connect(function(payload)
		if not (S.active and payload and payload.chunks) then
			return
		end
		-- Server is authoritative; snap anywhere prediction has drifted low.
		for i, v in payload.chunks do
			if (S.chunks[i] or 0) < v then
				S.chunks[i] = v
			end
		end
		S.remaining = payload.remaining or S.remaining
	end)

	Net.get("WashItemCleaned").OnClientEvent:Connect(function(payload)
		if not payload then
			return
		end
		S.remaining = 0
		local rarity = payload.rarity or "Common"
		-- 1.15/1.07/1.0, not the old 1.45/1.2/1.0. That spread was set against an
		-- electronic ping, where higher is the only way to say "better"; these are
		-- recorded chimes with their own character, and shifting one up a fifth
		-- just makes it small.
		local pitch = rarity == "Legendary" and 1.15 or (rarity == "Rare" and 1.07 or 1.0)
		local where = S.stand or workspace
		-- A momentary dip UNDER the reveal, so the chime rings into a gap rather
		-- than into the middle of a track. dipMusic returns to the standing duck,
		-- not to full, so leaving the bay mid-hold cannot undo the session duck.
		AudioKit.dipMusic(0.28, 1.5)
		AudioKit.play("ItemCleaned", where, 1.1, pitch)
		if rarity == "Legendary" then
			-- The shimmer lands a beat behind the chime and rings on past it, so
			-- the rarest moment in the game ends by fading rather than stopping.
			AudioKit.stack("LegendaryHit", "FairyDust", where, 0.18)
		end
		S.kickVel += 5
		S.flash = 1
		S.charge = 0
		S.revealName = payload.displayName or "Find"
		S.revealColor = ItemConfig.rarityColor(rarity)
		celebrate(rarity)

		-- Clear the plate for the reveal. The find should come out of bare metal,
		-- not out of a bed of its own crust -- and the last of it has to go
		-- SOMEWHERE, so it goes where the rest of the lump went.
		if silt.load > 0.05 then
			sluice()
		else
			silt.load = 0
		end

		if S.model then
			local clean = S.model:FindFirstChild("Clean")
			local core = clean and clean:FindFirstChildWhichIsA("BasePart", true)
			if core then
				ItemVisuals.burstSparkle(core, rarity)
			end
		end
	end)

	--[[
		THE TWO THINGS THE PASS BUTTON IS DRAWN FROM, and both land whenever
		they land. See refreshPass.

		The folder is waited for on its own thread rather than inline: this is
		start(), ClientMain calls it in a fixed order, and a WaitForChild here
		would hold every start() below it hostage to a server that has not
		published its prices yet.
	]]
	refreshPass()
	player:GetAttributeChangedSignal(INSTANT.attribute):Connect(refreshPass)

	-- The other half of the button's face: how big the job is. One count per
	-- InventorySync, never per frame -- see crustedInBag.
	local function refreshCrusted()
		crustedInBag = InventoryController.Client.countByState("Crusted")
	end
	refreshCrusted()
	InventoryController.Client.Changed:Connect(refreshCrusted)
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild(PassConfig.InfoFolder, 30)
		if folder then
			folder.AttributeChanged:Connect(refreshPass)
			refreshPass()
		end
	end)

	-- Runs for the whole session, not just while washing: a lump on a stand has
	-- to be veiled from the moment it replicates, which is well before this
	-- player mounts anything of their own.
	startForeignVeil()

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	-- The gesture, wherever it comes from -- gamepad, and the touch jump button on
	-- the devices that still show one. requestLeave is a no-op outside a session.
	UserInputService.JumpRequest:Connect(requestLeave)
	player.CharacterRemoving:Connect(endSession)

	RunService:BindToRenderStep(
		"BeachCleanupWash",
		Enum.RenderPriority.Camera.Value + 5,
		onRender
	)
end

return WashClientController