--[[
	HudKit  --  ReplicatedStorage.Modules.HudKit

	THE READOUT CHROME: one palette and one set of surfaces for the corner of the
	screen that is up the entire session -- the coin pill, the load bar, the beach
	bar and the backpack key.

	WHY THIS IS NOT PanelKit
	------------------------
	PanelKit paints the world's furniture -- shop cards, rail keys, signboards --
	in sand and timber, and the rail's six keys are what this corner has to sit
	beside without arguing with. So the SILHOUETTE here is PanelKit's, exactly:
	shadow slab, 4px ink outline, gloss cap, Back easing. Only the FILL differs.

	Timber over bright sand was the problem. Brown on gold is the one pairing on
	this screen with no separation in it, and the four texture passes the old
	boards each carried -- speckle grain, cut grooves, a wet line, a painted rim --
	turned three small readouts into the busiest object in the frame. One flat
	cool surface and one gloss cap replaces all of it, and the colour is carried
	by what goes INSIDE the frames: gold coin, sea load, sand rake. A chrome that
	competes with its own contents is what the boards were doing.

	TO CHANGE THE LOOK, CHANGE `THEME` BELOW -- nothing outside this file reads
	these colours, and both palettes are drawn against the same accents, so the
	switch is one word.
]]

local TweenService = game:GetService("TweenService")

-- Only for the column's compact pass at the bottom of THE COLUMN below. HudKit
-- is required from client files only, so this costs the server nothing.
local UiFit = require(script.Parent:WaitForChild("UiFit"))

local HudKit = {}

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

--------------------------------------------------------------------------
-- PALETTE
--------------------------------------------------------------------------
-- "deepsea" | "foam"
HudKit.THEME = "deepsea"

HudKit.PALETTES = {
	-- Deep water. Dark cool surfaces, white type. The highest-contrast option
	-- over bright sand, which is what the HUD spends the session sitting on.
	deepsea = {
		face     = rgb(34, 82, 106),
		faceDark = rgb(18, 48, 66),
		slab     = rgb(10, 28, 40),
		ink      = rgb(9, 26, 36),
		track    = rgb(14, 38, 52),   -- an unfilled bar
		text     = rgb(255, 255, 255),
		textDim  = rgb(168, 204, 222),
		-- Type sitting ON a bar has the FILL behind it as often as the face, so
		-- its outline is what has to carry it over both.
		barText  = rgb(255, 255, 255),
		barEdge  = rgb(9, 26, 36),
		barEdgeT = 0,
		rakeFill = rgb(250, 224, 170),
		rowFace  = rgb(240, 250, 255),
		rowDark  = rgb(206, 230, 242),
		rowText  = rgb(20, 44, 58),
		rowSub   = rgb(108, 140, 158),
		glossAmt = 0.62,
	},
	-- Sea foam. Bright off-white surfaces, deep navy type.
	foam = {
		face     = rgb(250, 253, 255),
		faceDark = rgb(214, 235, 246),
		slab     = rgb(96, 140, 164),
		ink      = rgb(18, 48, 64),
		track    = rgb(198, 223, 236),
		text     = rgb(20, 48, 64),
		textDim  = rgb(96, 132, 152),
		barText  = rgb(18, 48, 64),
		barEdge  = rgb(255, 255, 255),
		barEdgeT = 0.15,
		rakeFill = rgb(248, 196, 104),
		rowFace  = rgb(255, 255, 255),
		rowDark  = rgb(226, 242, 250),
		rowText  = rgb(20, 44, 58),
		rowSub   = rgb(108, 140, 158),
		glossAmt = 0.48,
	},
}

local C = HudKit.PALETTES[HudKit.THEME] or HudKit.PALETTES.deepsea
HudKit.C = C

-- The accents, and they are deliberately OUTSIDE the palette: these are the
-- colours that carry meaning -- money, water, raked sand, a refusal -- and they
-- must read the same whichever chrome is under them. They are PanelKit's own
-- sun / sea / coral, so the HUD and the rail agree about what gold means.
HudKit.A = {
	sea      = rgb(64, 168, 240),
	seaLight = rgb(112, 208, 255),
	seaDeep  = rgb(24, 122, 198),
	sun      = rgb(255, 200, 62),
	sunLight = rgb(255, 236, 150),
	sunDeep  = rgb(255, 162, 32),
	goldHi   = rgb(255, 233, 140),
	goldLo   = rgb(243, 158, 24),
	coral    = rgb(255, 96, 88),
	foam     = rgb(94, 226, 196),
	white    = rgb(255, 255, 255),
}
local A = HudKit.A

--------------------------------------------------------------------------
-- THE COLUMN
--------------------------------------------------------------------------
--[[
	ONE SOURCE OF TRUTH FOR THE LEFT EDGE.

	The three readouts live in CTB_HUD and the backpack key lives in
	InventoryHud, in a different ScreenGui -- so the column they share cannot be
	arithmetic that each file does for itself. That is exactly how the old stack
	ended up three widths wide: 274 pills above a 248 card wearing a 274
	signboard, with the card's left edge nudged to 29 by hand to make up the
	difference.

	Both ScreenGuis leave IgnoreGuiInset FALSE, so both measure y from the same
	origin and these numbers mean the same thing in each.
]]
local L = {}
L.X      = 16
L.W      = 256
--[[
	THE ONE NUMBER THAT SPACES THE WHOLE COLUMN. Every Y below is derived from
	it and nothing outside this file hardcodes a position, so the coin pill, the
	load bar, the beach bar, the backpack key and the drawer under them all move
	together -- CTB_HUD and InventoryHud both read this table.

	14, up from 8. At 8 a 54-tall pill sat eight pixels off a 38-tall one off a
	30-tall one, and four readouts of three different heights that close together
	read as one clumped block rather than as four things.

	IT COSTS THE DRAWER ABOUT HALF A ROW and that is the only thing it costs:
	InventoryHud derives its row count from `roomY - FOOT - L.DRAWER_Y`, so a
	lower drawer shows one fewer row before it scrolls rather than overflowing.
	MIN_ROWS is the floor, and UiFit keeps `roomY` in authored units, so a phone
	is not a special case here.
]]
L.GAP    = 14
L.COIN_H = 54
L.LOAD_H = 38
L.RAKE_H = 30
L.KEY    = 58    -- the backpack key, square

L.COIN_Y = 14
L.LOAD_Y = L.COIN_Y + L.COIN_H + L.GAP           --  76
L.RAKE_Y = L.LOAD_Y + L.LOAD_H + L.GAP           -- 122
-- An extra 6 above the key: it is the one PRESSABLE thing in the column, and a
-- slightly wider gap is what separates a button from the readouts above it.
-- It grew with the gap so the separation stays proportional rather than
-- shrinking into it.
L.KEY_Y  = L.RAKE_Y + L.RAKE_H + L.GAP + 6
--[[
	THE REST OF THE KEY'S ROW -- where CTB_HUD hangs the QUICK SELL button.

	The backpack key is square, so it leaves 184 of the column's 256 standing
	empty beside it. Describing that leftover here rather than in CTB_HUD is
	the same rule the rest of this table follows: the button ends flush with
	the three pills above it because its width is DERIVED from theirs, so
	retuning L.W or L.KEY moves all four together instead of leaving one
	sticking out.
]]
L.SELL_X = L.X + L.KEY + L.GAP                   --  88
L.SELL_W = L.W - L.KEY - L.GAP                   -- 184

--[[
	THE DRAWER, straight under the backpack/quick-sell row.

	THERE WAS A SANDBOT KEY BETWEEN THEM AND IT IS GONE. It was a full-width
	row, 52 tall, that read BEACH SANDBOT / R$ over a price to anyone who did not
	own the pass and DEPLOY to anyone who did -- a storefront pinned to the
	corner of the screen for the whole session. The drone is now sent out from
	the SANDBOT HOME beside each island's car spawner, which is where every
	other purchase in this game is made, so the column is four readouts and a
	key again.

	THE DRAWER GETS THE 66 PIXELS BACK, which is the one measurable thing this
	change costs anybody -- in the good direction. InventoryHud derives its row
	count from `roomY - FOOT - L.DRAWER_Y` (floored at MIN_ROWS), so the carried
	list shows one MORE row before it scrolls than it did with the key there.

	Nothing outside this file hardcodes a position, so this is the only line
	that had to move.
]]
L.DRAWER_Y = L.KEY_Y + L.KEY + L.GAP             -- 230

HudKit.L = L

--[[
	THE COLUMN GIVES A PHONE SOME OF ITS CORNER BACK.

	UiFit already shrinks this whole HUD, but it stops at 0.6 and the column is
	still 154 x 138 real pixels of a 685 x 280 landscape phone -- the largest
	object on the screen, in the corner the player is trying to look past.

	A FLAT MULTIPLIER, and that is the point. Narrowing L.W instead is the
	obvious move and it is a trap: every readout on this column has a MEASURED
	text budget against 256 (the load bar's 118/80 split, QUICK SELL's 111px in
	126, the raked label's TextScaled floor), so taking width away truncates
	something in every one of them. Scaling keeps every one of those ratios
	exactly as it was authored -- nothing can clip that did not clip before.

	WHAT IT COSTS is type size, which is why it is 0.86 and not lower: the coin
	number, the one that is actually watched, lands at 15px and stays plainly
	readable. The two bar captions go to 9 and 8, which is small -- and
	survivable only because those two readouts are BARS. The fill carries the
	meaning and the text is the precise version of it. Below about 0.8 that
	stops being true and the right answer becomes a compact LAYOUT (dropping the
	bag's secondary $ readout, say) rather than more shrinking.

	CHANGE THE ONE NUMBER; nothing outside this file reads it.
]]
HudKit.COMPACT_COLUMN = 0.86

function HudKit.columnMult(): number
	return UiFit.compact() and HudKit.COMPACT_COLUMN or 1
end

--[[
	WHERE A PIECE RESTS, for anything that ANIMATES its scale.

	CTB_HUD punches the coin pill and the load bar on every payment -- UIScale
	up to 1.14, tween back. Back to WHAT is the question, and 1 is the right
	answer only on a desktop: on a phone the punch would tween the pill out to
	full size on the first coin the player picked up and leave it there, which
	is the compact pass silently undone by its own liveliness.

	An ATTRIBUTE rather than a second UIScale, because an object honours exactly
	one -- the same rule that makes UiFit wrap rather than scale in place. It is
	absent on everything that is not on this column, so `1` is what the punched
	upgrade button and every other caller keeps getting.
]]
HudKit.REST_SCALE = "HudKitRestScale"

function HudKit.restScale(inst: Instance): number
	local v = inst:GetAttribute(HudKit.REST_SCALE)
	return (typeof(v) == "number" and v > 0) and v or 1
end

--[[
	Shrink one piece of the column, and move it by the same amount.

	BOTH HALVES ARE NEEDED. A UIScale scales the object about its AnchorPoint --
	top-left here -- and leaves its Position alone, so scaling the four pieces
	and nothing else would shrink each one in place and leave the gaps between
	them at full size. The stack has to travel with its own scale, which is what
	rewriting the offsets does.

	REACTIVE, not read once at build time. UiFit.onChanged fires immediately
	with the current scale as well as on every later change, so this needs no
	opinion about whether UiFitBoot has run yet -- which matters, because
	CTB_HUD lays the column out the moment it is required.

	`base` is captured, so this may only be given a piece whose Position is
	fixed. Every piece on this column is (the drawer animates its SIZE), and a
	piece that moved would fight this on every scale change.
]]
function HudKit.fitColumn(piece: GuiObject)
	local us = piece:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	us.Parent = piece
	local base = piece.Position
	UiFit.onChanged(function()
		local m = HudKit.columnMult()
		-- Written BEFORE the scale, so a punch that starts on this frame reads
		-- the new resting size rather than the one being replaced. A punch
		-- already in flight across a resize still lands on the old rest and
		-- corrects itself on the next one; a quarter second, once, on a device
		-- rotation.
		piece:SetAttribute(HudKit.REST_SCALE, m)
		us.Scale = m
		piece.Position = UDim2.new(base.X.Scale, base.X.Offset * m,
			base.Y.Scale, base.Y.Offset * m)
	end)
end

--------------------------------------------------------------------------
-- PRIMITIVES
--------------------------------------------------------------------------
function HudKit.darken(c: Color3, f: number?): Color3
	return c:Lerp(Color3.new(0, 0, 0), f or 0.35)
end
local darken = HudKit.darken

function HudKit.corner(inst: GuiObject, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
	return c
end
local corner = HudKit.corner

-- A capsule end: half the SHORT side, whatever the frame turns out to be.
function HudKit.roundOff(inst: GuiObject)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = inst
	return c
end
local roundOff = HudKit.roundOff

function HudKit.outline(inst: GuiObject, thick: number?, col: Color3?, tr: number?)
	local s = Instance.new("UIStroke")
	s.Thickness = thick or 4
	s.Color = col or C.ink
	s.Transparency = tr or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = inst
	return s
end
local outline = HudKit.outline

-- Outlines the glyphs rather than boxing the label.
--[[
	A V POINTING UP, AND IT IS DRAWN TWICE.

	Lifted out of TutorialGuide, which had it as a local, the day a SECOND
	pointer wanted one -- RebirthUnlockPrompt's arrow to the ferry. It is the
	only shape in the HUD whose construction is genuinely subtle, so a second
	copy of the trigonometry below is exactly the kind of thing this file exists
	to prevent.

	The obvious build -- two bars with a UIStroke each -- draws the seam where
	the bars overlap straight across the middle of the arrowhead, because a
	stroke is per-object and knows nothing about the silhouette its neighbour is
	part of. So the dark pass is the same capsule a few pixels fatter on every
	side, drawn underneath: one continuous outline, no internal lines. Both
	passes share a CENTRE and differ only in size, which is what makes that
	border an even thickness all the way round rather than a wedge.

	ROTATION IS ABOUT THE OBJECT'S CENTRE, NOT ITS ANCHOR POINT -- measured in
	this place, not assumed, because the documentation reads the other way and
	the obvious build follows the documentation.

	Anchoring both limbs at their TOP ends and dropping them on a shared apex
	draws an X: each one then swings about its own middle, the two top ends
	travel apart in opposite directions, and the bars cross. It is a convincing
	X, too -- it looks deliberate, which is why it survived a screenshot.

	So the trigonometry is here instead. Each limb's CENTRE is placed where the
	rotation will leave its top end sitting on the apex:

		centre = apex + R(theta) * (0, length/2)

	with y running down the screen, which is why the x term is negated.

	The caller retints it by walking the children: the FACE pass is the one at
	the higher ZIndex, the outline stays ink.
]]
local CHEVRON_SPREAD = 42      -- degrees each limb is splayed off vertical
local CHEVRON_OUTLINE = 3.5    -- pixels of ink around the face pass

function HudKit.chevron(parent: Instance, size: number, tint: Color3, z: number): Frame
	local group = Instance.new("Frame")
	group.Name = "Chevron"
	group.BackgroundTransparency = 1
	group.AnchorPoint = Vector2.new(0.5, 0.5)
	group.Size = UDim2.fromOffset(size, size)
	group.Parent = parent

	local thick = math.max(7, size * 0.22)
	local length = size * 0.6
	local apexY = size * 0.25   -- leaves the whole V sitting centred in the box

	-- `pad` grows the capsule about that shared centre, so the ink pass is a
	-- border rather than a second, differently-shaped chevron.
	local function limbs(col: Color3, pad: number, zi: number)
		for _, sign in ipairs({ -1, 1 }) do
			local th = math.rad(sign * CHEVRON_SPREAD)
			local cx = size * 0.5 - (length * 0.5) * math.sin(th)
			local cy = apexY + (length * 0.5) * math.cos(th)
			local w = thick + pad * 2
			local limb = Instance.new("Frame")
			limb.Name = "Limb"
			limb.AnchorPoint = Vector2.new(0.5, 0.5)
			limb.Position = UDim2.fromOffset(cx, cy)
			limb.Size = UDim2.fromOffset(w, length + pad * 2)
			limb.BackgroundColor3 = col
			limb.BorderSizePixel = 0
			limb.Rotation = sign * CHEVRON_SPREAD
			limb.ZIndex = zi
			limb.Parent = group
			HudKit.corner(limb, w * 0.5)
		end
	end

	limbs(HudKit.C.ink, CHEVRON_OUTLINE, z)   -- the outline pass, underneath
	limbs(tint, 0, z + 1)                     -- the face
	return group
end

-- Repaint a chevron's face without touching its outline. The face pass is the
-- one at the higher ZIndex; see the note above.
function HudKit.rechevron(group: Instance, tint: Color3, faceZ: number)
	for _, limb in ipairs(group:GetChildren()) do
		if limb:IsA("Frame") and limb.ZIndex >= faceZ then
			limb.BackgroundColor3 = tint
		end
	end
end

function HudKit.punch(l: TextLabel, thick: number?, col: Color3?, tr: number?)
	local s = Instance.new("UIStroke")
	s.Thickness = thick or 2.5
	s.Color = col or C.ink
	s.Transparency = tr or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = l
	return s
end
local punch = HudKit.punch

-- A UIGradient MULTIPLIES against the fill underneath, so anything gradient-lit
-- has to sit on white or the two tint each other into mud.
function HudKit.grad(inst: GuiObject, top: Color3, bottom: Color3, rot: number?)
	if inst:IsA("TextLabel") then
		inst.TextColor3 = A.white
	else
		inst.BackgroundColor3 = A.white
	end
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(top, bottom)
	g.Rotation = rot or 90
	g.Parent = inst
	return g
end
local grad = HudKit.grad

-- Repaint a gradient-lit fill. Writing BackgroundColor3 alone gives mud, for
-- the reason above; both stops have to move with it.
function HudKit.regrad(inst: GuiObject, top: Color3, bottom: Color3)
	local g = inst:FindFirstChildOfClass("UIGradient")
	if g then
		g.Color = ColorSequence.new(top, bottom)
	end
end

-- The gloss cap: white across the top of the face, faded out downward. Cheap
-- fake specular, and the single biggest "toy plastic" cue.
function HudKit.gloss(face: GuiObject, r: number, amount: number?)
	local g = Instance.new("Frame")
	g.Name = "Gloss"
	g.BackgroundColor3 = A.white
	g.BorderSizePixel = 0
	g.Size = UDim2.new(1, -8, 0.44, 0)
	g.Position = UDim2.fromOffset(4, 3)
	g.ZIndex = 6
	g.Parent = face
	corner(g, math.max(3, r - 4))
	local gg = Instance.new("UIGradient")
	gg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, amount or C.glossAmt),
		NumberSequenceKeypoint.new(0.72, 0.9),
		NumberSequenceKeypoint.new(1, 1),
	})
	gg.Rotation = 90
	gg.Parent = g
	return g
end
local gloss = HudKit.gloss

function HudKit.text(parent: Instance, str: string, size: number, col: Color3?, font: Enum.Font?)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Font = font or Enum.Font.LuckiestGuy
	t.Text = str
	t.TextSize = size
	t.TextColor3 = col or C.text
	t.Size = UDim2.fromScale(1, 1)
	t.ZIndex = 10
	t.Parent = parent
	return t
end
local text = HudKit.text

--------------------------------------------------------------------------
-- SURFACES
--------------------------------------------------------------------------
--[[
	THREE LAYERS AND NOTHING ELSE -- a shadow slab offset down for weight, the
	face, and a gloss cap. The slab plus the 4px outline is what reads as a solid
	game object rather than a translucent rectangle, and it is the same recipe
	PanelKit.chunky uses, so a readout here and a key on the rail are plainly
	parts of the same set.

	`tint` paints a surface in a colour of its own -- which the readouts never do
	and the backpack key always does. See `key` below for why.
]]
function HudKit.surface(parent: Instance, w: number, h: number, r: number,
	tint: Color3?, className: string?)

	local top   = tint or C.face
	local bot   = tint and darken(tint, 0.24) or C.faceDark
	local shade = tint and darken(tint, 0.5) or C.slab

	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(w, h)
	holder.Parent = parent

	local slab = Instance.new("Frame")
	slab.Name = "Slab"
	slab.Size = UDim2.fromScale(1, 1)
	slab.Position = UDim2.fromOffset(0, 5)
	slab.BackgroundColor3 = shade
	slab.BorderSizePixel = 0
	slab.ZIndex = 1
	slab.Parent = holder
	corner(slab, r)
	outline(slab, 4)

	local face = Instance.new(className or "Frame")
	face.Name = "Face"
	face.Size = UDim2.fromScale(1, 1)
	face.BackgroundColor3 = top
	face.BorderSizePixel = 0
	face.ZIndex = 2
	face.Parent = holder
	if face:IsA("TextButton") then
		face.AutoButtonColor = false
		face.Text = ""
	end
	corner(face, r)
	local st = outline(face, 4)
	grad(face, top, bot)

	return holder, face, slab, st
end
local surface = HudKit.surface

--[[
	A PRESSABLE KEY -- the same surface, with the face dropping onto its slab on
	the way down. That drop is most of why a button feels like a button.

	TINTED, where the readouts above it are not. The column is chrome; this is
	the one thing on it you can press, and colour is what says so -- the same way
	every key on the rail is tinted by what it opens.
]]
function HudKit.pressable(parent: Instance, w: number, h: number, tint: Color3, r: number?)
	r = r or math.floor(math.min(w, h) * 0.31)
	local holder, face, slab = surface(parent, w, h, r, tint, "TextButton")
	gloss(face, r, 0.5)

	local up, down = UDim2.fromOffset(0, 0), UDim2.fromOffset(0, 5)
	face.Position = up
	face.MouseButton1Down:Connect(function()
		TweenService:Create(face, TweenInfo.new(0.06), { Position = down }):Play()
	end)
	face.MouseButton1Up:Connect(function()
		TweenService:Create(face, TweenInfo.new(0.16, Enum.EasingStyle.Back,
			Enum.EasingDirection.Out), { Position = up }):Play()
	end)
	face.MouseLeave:Connect(function()
		TweenService:Create(face, TweenInfo.new(0.12), { Position = up }):Play()
	end)
	return holder, face, slab
end

-- The square case, and the only one the rail and the backpack key want. Kept
-- as its own name because "key" is what every caller and every comment in this
-- HUD calls that shape; `pressable` above is the same button given a width.
function HudKit.key(parent: Instance, size: number, tint: Color3, r: number?)
	return HudKit.pressable(parent, size, size, tint, r or math.floor(size * 0.31))
end

-- A count, overhanging the outward corner the way a notification does.
function HudKit.badge(face: GuiObject, px: number?)
	px = px or 26
	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0.5, 0.5)
	badge.Position = UDim2.fromScale(0.94, 0.08)
	badge.Size = UDim2.fromOffset(px, px)
	badge.BackgroundColor3 = A.coral
	badge.BorderSizePixel = 0
	badge.ZIndex = 12
	badge.Parent = face
	roundOff(badge)
	outline(badge, 3)

	local t = text(badge, "", math.floor(px * 0.58), A.white)
	t.ZIndex = 13
	punch(t, 2)
	return badge, t
end

--------------------------------------------------------------------------
-- GLYPHS
--------------------------------------------------------------------------
-- Drawn from Frames, never typed as emoji: an emoji is at the mercy of
-- whatever glyph the player's device ships, and half of them ship these as
-- something else entirely.

-- The bag on the load bar: a handle ring the body hides the bottom of.
function HudKit.bagGlyph(parent: Instance, px: number)
	local g = Instance.new("Frame")
	g.Name = "Bag"
	g.Size = UDim2.fromOffset(px, px)
	g.BackgroundTransparency = 1
	g.ZIndex = 10
	g.Parent = parent

	local handle = Instance.new("Frame")
	handle.Size = UDim2.fromScale(0.54, 0.5)
	handle.Position = UDim2.fromScale(0.23, 0.02)
	handle.BackgroundTransparency = 1
	handle.ZIndex = 10
	handle.Parent = g
	roundOff(handle)
	outline(handle, math.max(2, px * 0.11), C.barText)

	local body = Instance.new("Frame")
	body.Size = UDim2.fromScale(1, 0.64)
	body.Position = UDim2.fromScale(0, 0.36)
	body.BackgroundColor3 = C.barText
	body.BorderSizePixel = 0
	body.ZIndex = 10
	body.Parent = g
	corner(body, math.max(3, px * 0.22))
	return g
end

-- Combed sand: three tapering lines.
function HudKit.rakeGlyph(parent: Instance, px: number)
	local g = Instance.new("Frame")
	g.Name = "Rake"
	g.Size = UDim2.fromOffset(px, px)
	g.BackgroundTransparency = 1
	g.ZIndex = 10
	g.Parent = parent
	for i = 0, 2 do
		local line = Instance.new("Frame")
		line.Size = UDim2.new(1, -i * px * 0.2, 0, math.max(2, px * 0.16))
		line.Position = UDim2.fromOffset(i * px * 0.1, px * (0.16 + i * 0.28))
		line.BackgroundColor3 = C.barText
		line.BackgroundTransparency = i * 0.22
		line.BorderSizePixel = 0
		line.ZIndex = 10
		line.Parent = g
		roundOff(line)
	end
	return g
end

--[[
	THE PACK ON THE KEY.

	Sand-coloured against a teal key, so the pack is the OBJECT and the plastic
	behind it is the button -- a teal pack on a teal key is a silhouette you have
	to hunt for.

	A lid band and a buckle, not a plain rounded box: at 36px the two bands are
	what make it read as a backpack rather than as a lunchbox.
]]
function HudKit.backpackGlyph(parent: Instance, px: number)
	local INK = C.ink
	local LINE = math.max(2, px * 0.07)

	local g = Instance.new("Frame")
	g.Name = "Backpack"
	g.Size = UDim2.fromOffset(px, px)
	g.BackgroundTransparency = 1
	g.ZIndex = 7
	g.Parent = parent

	-- The grab loop, above the body.
	local loop = Instance.new("Frame")
	loop.Size = UDim2.fromScale(0.3, 0.26)
	loop.Position = UDim2.fromScale(0.35, 0.02)
	loop.BackgroundTransparency = 1
	loop.ZIndex = 7
	loop.Parent = g
	roundOff(loop)
	outline(loop, LINE, INK)

	local body = Instance.new("Frame")
	body.Size = UDim2.fromScale(0.92, 0.8)
	body.Position = UDim2.fromScale(0.04, 0.2)
	body.BackgroundColor3 = rgb(255, 238, 202)
	body.BorderSizePixel = 0
	body.ZIndex = 8
	body.Parent = g
	corner(body, math.max(4, px * 0.26))
	grad(body, rgb(255, 246, 222), rgb(232, 194, 136))
	outline(body, LINE, INK)

	local lid = Instance.new("Frame")
	lid.Size = UDim2.fromScale(1, 0.42)
	lid.BackgroundColor3 = rgb(255, 158, 88)
	lid.BorderSizePixel = 0
	lid.ZIndex = 9
	lid.Parent = body
	corner(lid, math.max(4, px * 0.26))
	grad(lid, rgb(255, 186, 122), rgb(232, 122, 56))
	outline(lid, LINE, INK)

	local buckle = Instance.new("Frame")
	buckle.AnchorPoint = Vector2.new(0.5, 0)
	buckle.Size = UDim2.fromScale(0.26, 0.3)
	buckle.Position = UDim2.fromScale(0.5, 0.46)
	buckle.BackgroundColor3 = rgb(255, 158, 88)
	buckle.BorderSizePixel = 0
	buckle.ZIndex = 10
	buckle.Parent = body
	corner(buckle, math.max(2, px * 0.06))
	outline(buckle, LINE * 0.8, INK)

	return g
end

--------------------------------------------------------------------------
-- A BAR
--------------------------------------------------------------------------
--[[
	A capsule whose FILL is the readout.

	The fill sits ABOVE the gloss cap, which looks backwards and is not. A
	30%-white sheet laid over a sea-blue fill is what turns it into a pale band
	you have to look for; the fill carries its own top-light through its own
	gradient instead, and the gloss is left to do the empty end of the track.

	Returns (holder, face, fill, foam, stroke).
]]
function HudKit.bar(parent: Instance, w: number, h: number, top: Color3, bottom: Color3)
	local r = h * 0.5
	local FOAM_W = 14
	local holder, face, _, st = surface(parent, w, h, r)
	-- regrad ONLY. surface has already been through grad(), which sets the base
	-- to white precisely so the gradient stops are the colour you get -- writing
	-- BackgroundColor3 here instead would multiply the track against itself and
	-- an empty bar would come out near-black.
	HudKit.regrad(face, C.track, darken(C.track, 0.18))
	face.ClipsDescendants = true
	gloss(face, r, math.min(0.85, C.glossAmt + 0.2))

	--[=[
		THE FILL IS THE WHOLE PILL, AND HOW MUCH YOU SEE IS A GRADIENT.

		ClipsDescendants clips to a RECTANGLE. It knows nothing about the
		UICorner that makes this a capsule, so a fill GROWING from x = 0 paints
		its own square corners into the rounded end and back out of it: at 4 of
		98 lbs the fill is 10px wide against a 19px cap, and the two nubs that
		escape are the whole of the bug.

		Nor can the fill simply round itself off out of trouble. UICorner is
		clamped to half the SHORT side, so a 10px-wide fill gets a 5px radius,
		not the pill's 19 -- the narrower it gets the further outside the arc it
		reaches. There is no width below h at which a growing fill fits.

		So nothing grows. The fill is a frame the exact size and radius of the
		pill, and the READOUT is a UIGradient whose transparency steps from
		opaque to clear at the load line. The silhouette is the same capsule at
		0%, at 100% and everywhere between, because it is the same unchanging
		frame. This is what CTB_HUD's beach bar already does, for the same
		reason -- these two now behave identically.

		ROTATION 0, which is the one real cost. A gradient has ONE rotation, and
		the cutoff has to run along the bar, so the colour stops run along it
		too rather than top-to-bottom. `top` and `bottom` are now the near end
		and the far end of the fill.
	]=]
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BorderSizePixel = 0
	fill.ZIndex = 7
	fill.Parent = face
	corner(fill, r)
	local fillGrad = grad(fill, top, bottom, 0)

	--[=[
		THE FOAM AT THE FRONT OF THE WAVE.

		A fill that simply stops has a hard vertical edge across it, which is the
		one thing on a beach that never happens.

		It used to hang off the FILL's right edge, which rode the fill's tween
		for free and was the loudest half of the bug above: 14px of white curl
		anchored to the right of a 10px fill starts at x = -4. It sat outside
		the pill entirely, on the far left of the track, every time the bag was
		nearly empty.

		Now it is the FACE's child and `apply` puts it where the load line is,
		which also means it can be held back from the two ends -- see below.
	]=]
	local foam = Instance.new("Frame")
	foam.Name = "Foam"
	foam.AnchorPoint = Vector2.new(1, 0)
	foam.Position = UDim2.fromScale(0, 0)
	foam.Size = UDim2.new(0, FOAM_W, 1, 0)
	foam.BackgroundColor3 = A.white
	foam.BorderSizePixel = 0
	foam.ZIndex = 8
	foam.Parent = face
	roundOff(foam)
	local fg = Instance.new("UIGradient")
	fg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.92),
		NumberSequenceKeypoint.new(1, 0.34),
	})
	fg.Parent = foam

	--[=[
		WHERE THE LOAD LINE IS ALLOWED TO BE.

		The foam is full height, so it only fits where the pill is full height:
		the straight middle, between the two r-radius caps. Held to that span it
		is provably inside the capsule and no arc arithmetic is needed -- and
		below the near limit there is no foam at all, because a curl of surf
		pinned in front of a sliver of water reads as a bug rather than a wave.

		Two pixels of softness on the load line. One is a stair that crawls as
		the bar tweens; two reads as the same hard edge and holds still. In
		SCALE, because that is the space a UIGradient's keypoints live in.
	]=]
	local SOFT = 2 / w
	local FOAM_MIN = (r + FOAM_W) / w
	local FOAM_MAX = (w - r) / w

	--[=[
		THE WAVE FADES AT BOTH ENDS RATHER THAN POPPING OR PARKING.

		The foam cannot travel past FOAM_MAX -- 19px from the end on a 38px-tall
		bar -- so a full bag left it stranded there, a hard white curl inside a
		full bar that never moved again. It reads exactly like a fill that has
		stopped short, which is what it was mistaken for. There is no front once
		the bar is full: the pill's own cap is the leading edge by then.

		The near end had the mirror of the same fault, less visibly: the curl
		appeared out of nothing the instant the load crossed FOAM_MIN.

		So the two clamps now fade instead of switching. `t` still drives the
		position, and the visibility is a ramp: in over the first stretch it is
		allowed to move through, out over the last one.
	]=]
	local FADE_IN = math.max(1e-3, FOAM_MIN * 0.5)
	local FADE_OUT = math.max(1e-3, 1 - FOAM_MAX)

	local function apply(t: number)
		t = math.clamp(t, 0, 1)

		local hideNear = 1 - math.clamp((t - FOAM_MIN) / FADE_IN, 0, 1)
		local hideFar = math.clamp((t - FOAM_MAX) / FADE_OUT, 0, 1)
		local hide = math.max(hideNear, hideFar)
		foam.Visible = hide < 1
		foam.BackgroundTransparency = hide
		foam.Position = UDim2.fromScale(math.clamp(t, FOAM_MIN, FOAM_MAX), 0)

		-- The flat ends are their own case: a NumberSequence may not repeat a
		-- keypoint time, and a load line sitting exactly on 0 or 1 has no room
		-- for the pair of keypoints that make it a step.
		if t <= 0 then
			fillGrad.Transparency = NumberSequence.new(1)
			return
		elseif t >= 1 then
			fillGrad.Transparency = NumberSequence.new(0)
			return
		end
		local a = math.clamp(t, 0.002, 1 - SOFT - 0.002)
		fillGrad.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(a, 0),
			NumberSequenceKeypoint.new(a + SOFT, 1),
			NumberSequenceKeypoint.new(1, 1),
		})
	end

	--[=[
		WHAT THE CALLER MOVES. TweenService cannot interpolate a NumberSequence,
		so the tween runs on a plain number and `apply` rebuilds the sequence
		from it -- which also makes `apply` the ONLY place the load line is
		decided, so the foam and the water behind it cannot drift apart.

		Returned LAST, so the five handles callers already unpack are untouched.
	]=]
	local level = Instance.new("NumberValue")
	level.Name = "Level"
	level.Parent = face
	level.Changed:Connect(apply)
	apply(0)

	return holder, face, fill, foam, st, level
end

return HudKit
