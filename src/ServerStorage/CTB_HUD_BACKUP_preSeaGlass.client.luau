-- Clean the Beach :: HUD (coins, bag, upgrade button, toasts)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local CTB = ReplicatedStorage:WaitForChild("CTB")
local Config = require(CTB:WaitForChild("Config"))
local Net = CTB:WaitForChild("Net")
local Modules = ReplicatedStorage:WaitForChild("Modules")
local ToastKit = require(Modules:WaitForChild("ToastKit"))
local AudioKit = require(Modules:WaitForChild("AudioKit"))

local INK = Color3.fromRGB(22, 26, 34)
local CREAM = Color3.fromRGB(255, 250, 238)
local GOLD = Color3.fromRGB(255, 200, 62)
local GREEN = Color3.fromRGB(88, 226, 132)
local SKY = Color3.fromRGB(96, 202, 255)
local RED = Color3.fromRGB(255, 104, 96)

----------------------------------------------------------------
-- Builders
----------------------------------------------------------------
local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
	return c
end

local function stroke(parent: Instance, thickness: number, colour: Color3, transparency: number?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = colour
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

-- Outlines the glyphs rather than boxing the label.
local function textStroke(parent: Instance, thickness: number, colour: Color3, transparency: number?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = colour
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.Parent = parent
	return s
end

local function label(parent: Instance, text: string, size: number, colour: Color3, font: Enum.Font?)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Font = font or Enum.Font.FredokaOne
	t.Text = text
	t.TextSize = size
	t.TextColor3 = colour
	t.Size = UDim2.fromScale(1, 1)
	t.Parent = parent
	return t
end

----------------------------------------------------------------
-- Look
--
-- Every icon here is drawn out of Frames rather than typed as an emoji glyph.
-- Emoji render in whatever font the player's device ships, which is why the old
-- HUD looked like a phone keyboard; primitives look the same for everybody and
-- can carry the same outline and gradient treatment as the panels.
----------------------------------------------------------------
-- The same warm ink MenuHud's rail and panels outline everything with (its C.ink).
-- Sharing one outline colour is most of what makes two separately-written HUDs
-- read as one set rather than as two apps stacked on the same screen.
local OUTLINE    = Color3.fromRGB(56, 36, 20)
-- WARM, NOT SLATE.
--
-- These were (68,78,102) over (28,32,48): a cold blue-grey that went near-black
-- at the bottom edge, which is what made the top load bar and the two left
-- pills read as another app's chrome parked over a bright cartoon beach. They
-- are PanelKit's WOOD now, lit along the top -- the same timber the sell shop,
-- the wash bay and every panel's shadow slab are painted in -- so the HUD
-- belongs to the same set of parts the world is built from. The bright colour
-- on this screen is carried by what goes INSIDE the frames (gold coin, sea
-- load fill, lime rake fill), which is the right way round: a chrome that
-- competes with its own contents is what the old blue panels were doing.
local PANEL_TOP  = Color3.fromRGB(196, 140, 84)
local PANEL_BOT  = Color3.fromRGB(122, 74, 38)
local GOLD_LIGHT = Color3.fromRGB(255, 226, 118)
-- GOLD_DEEP and COIN_INK went with the drawn coin: they only ever tinted its
-- disc and its "$", and the art brings its own.

local function roundOff(parent: Instance)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = parent
	return c
end

-- A UIGradient MULTIPLIES against whatever colour is underneath it, so anything
-- gradient-filled has to sit on white or the two tint each other -- that is what
-- turned the panels near-black and made a gold bar over a blue fill come out green.
-- Setting the base to white here means the gradient stops are the colour you get.
local function gradient(parent: Instance, top: Color3, bottom: Color3, rotation: number?)
	if parent:IsA("GuiObject") then
		parent.BackgroundColor3 = Color3.new(1, 1, 1)
	end
	if parent:IsA("TextLabel") then
		parent.TextColor3 = Color3.new(1, 1, 1)
	end
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(top, bottom)
	g.Rotation = rotation or 90
	g.Parent = parent
	return g
end

--[[
	SAND-BLASTED BOARDS, NOT MOULDED PLASTIC.

	The three readouts on this screen -- coins, load, beach raked -- were the
	same lozenge drawn three times: one flat gradient, one white gloss cap, one
	rounded rectangle. Correct, warm, and the exact shape every game's HUD ships
	with, which is what made them read as chrome parked over the beach rather
	than as part of it.

	Three passes fix that, and all three are primitives for the same reason the
	icons on this HUD are: they render identically on every device.

	  weather() -- speckle and long streaks, so a board reads as sun-bleached
	               driftwood with sand blown into the grain. The biggest cue of
	               the three and by far the cheapest.
	  wetline() -- a damp band along the bottom inside edge. Sand is darker where
	               the water has been, and it gives the board a bottom instead of
	               letting the gradient run off the end.
	  rim()     -- a painted sand line inset from the outline, the way the signs
	               out in the world are edged. Drawn OVER the fills, so the
	               border stays continuous as a bar slides underneath it.
]]

-- SEEDED, so a board looks the same every session and no two boards share a
-- pattern. Everything is kept inside 0.06-0.94 of the width: the coin pill does
-- NOT clip its descendants, and a speck sitting on the outside of a rounded end
-- reads as a rendering fault rather than as texture.
local function weather(body: GuiObject, seed: number, count: number)
	local rng = Random.new(seed)

	for _ = 1, count do
		local px = rng:NextInteger(2, 4)
		local dot = Instance.new("Frame")
		dot.Name = "Grain"
		dot.Size = UDim2.fromOffset(px, px)
		dot.Position = UDim2.fromScale(rng:NextNumber(0.07, 0.93), rng:NextNumber(0.18, 0.82))
		-- Mixed light and dark. All-light grain reads as dust on the lens; the
		-- dark specks are what make it look like the surface itself.
		local pale = rng:NextNumber() < 0.55
		dot.BackgroundColor3 = pale and Color3.fromRGB(255, 240, 208) or Color3.fromRGB(78, 44, 18)
		dot.BackgroundTransparency = rng:NextNumber(0.45, 0.74)
		dot.BorderSizePixel = 0
		dot.ZIndex = 2
		dot.Parent = body
		roundOff(dot)
	end

	-- The grain of the plank. Width is chosen FIRST and the position fitted
	-- around it, so a long streak cannot start at 0.4 and run off the end.
	--
	-- Scaled off the speck count, which is itself scaled off area: three streaks
	-- was tuned on the coin pill and left the wide load bar looking sanded
	-- smooth. Half of them are now PALER than the board rather than darker --
	-- real grain is both, and a board with only dark lines in it reads as
	-- scratched rather than grained.
	--
	-- They run the SAME WAY as the grooves. Lying along the bar, they crossed
	-- the grain at right angles and read as scratches on a finished surface
	-- rather than as part of the timber.
	for _ = 1, math.clamp(math.floor(count / 3), 3, 9) do
		local tall = rng:NextNumber(0.28, 0.66)
		local streak = Instance.new("Frame")
		streak.Name = "Grain"
		streak.Size = UDim2.new(0, rng:NextInteger(1, 2), tall, 0)
		streak.Position = UDim2.new(rng:NextNumber(0.07, 0.93), 0, rng:NextNumber(0.14, 0.86 - tall), 0)
		local dark = rng:NextNumber() < 0.5
		streak.BackgroundColor3 = dark and Color3.fromRGB(92, 54, 22) or Color3.fromRGB(214, 166, 112)
		streak.BackgroundTransparency = rng:NextNumber(0.6, 0.82)
		streak.BorderSizePixel = 0
		streak.ZIndex = 2
		streak.Parent = body
		roundOff(streak)
	end
end

--[[
	GROOVES -- ACROSS THE BOARD, NOT ALONG IT.

	These ran the length of the bar to begin with, which made it look like three
	thin boards stacked on each other. It is ONE board, sawn so the grain crosses
	the short way, and what you are looking at is the face of it -- so the
	grooves run top to bottom and step along the length.

	Each is a dark line with a PALE ONE down its right-hand side. The pale one is
	the whole trick: the dark line alone reads as a scratch, and it is the lit
	edge beside it that turns it into a cut with a far wall the sun is catching.
]]
local function grooves(body: GuiObject, radius: number, n: number, seed: number)
	local rng = Random.new(seed * 7 + 13)
	-- Kept clear of the rounded ends so no line is sliced off at an angle.
	local inset = math.max(5, radius * 0.30)
	for i = 1, n do
		-- Jittered off an even division. Evenly spaced grain is a comb, and a
		-- comb is the one pattern that instantly reads as machine-drawn, which
		-- is the thing this whole board treatment exists to avoid.
		local t = math.clamp((i - 0.5) / n + rng:NextNumber(-0.34, 0.34) / n, 0.07, 0.93)
		local w = rng:NextInteger(2, 4)

		local cut = Instance.new("Frame")
		cut.Name = "Groove"
		cut.AnchorPoint = Vector2.new(0.5, 0)
		cut.Size = UDim2.new(0, w, 1, -inset * 2)
		cut.Position = UDim2.new(t, 0, 0, inset)
		cut.BackgroundColor3 = Color3.fromRGB(74, 40, 16)
		cut.BackgroundTransparency = rng:NextNumber(0.40, 0.66)
		cut.BorderSizePixel = 0
		cut.ZIndex = 3
		cut.Parent = body
		corner(cut, 1)

		-- The lit far wall of the cut, down its right-hand side.
		local lip = Instance.new("Frame")
		lip.Name = "GrooveLip"
		lip.AnchorPoint = Vector2.new(0.5, 0)
		lip.Size = UDim2.new(0, 1, 1, -inset * 2)
		lip.Position = UDim2.new(t, w * 0.5 + 1, 0, inset)
		lip.BackgroundColor3 = Color3.fromRGB(255, 236, 198)
		lip.BackgroundTransparency = rng:NextNumber(0.62, 0.8)
		lip.BorderSizePixel = 0
		lip.ZIndex = 3
		lip.Parent = body
	end
end

local function wetline(body: GuiObject, radius: number)
	local wet = Instance.new("Frame")
	wet.Name = "WetSand"
	wet.AnchorPoint = Vector2.new(0.5, 1)
	wet.Position = UDim2.fromScale(0.5, 1)
	wet.Size = UDim2.new(1, -6, 0.36, 0)
	wet.BackgroundColor3 = Color3.fromRGB(58, 32, 12)
	wet.BorderSizePixel = 0
	wet.ZIndex = 2
	wet.Parent = body
	corner(wet, math.max(3, radius - 3))
	-- Faded out UPWARD, so there is no edge where the damp starts -- an actual
	-- line across the middle of the board would just look like a second panel.
	local g = Instance.new("UIGradient")
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.55, 0.84),
		NumberSequenceKeypoint.new(1, 0.62),
	})
	g.Rotation = 90
	g.Parent = wet
	return wet
end

local function rim(body: GuiObject, radius: number)
	local r = Instance.new("Frame")
	r.Name = "Rim"
	r.Size = UDim2.new(1, -10, 1, -10)
	r.Position = UDim2.fromOffset(5, 5)
	r.BackgroundTransparency = 1
	-- Above the fills (3) and the icon chips (4): a painted border that a
	-- progress bar can slide over and erase is not a border.
	r.ZIndex = 5
	r.Parent = body
	corner(r, math.max(3, radius - 5))
	stroke(r, 1.5, Color3.fromRGB(255, 232, 186), 0.55)
	return r
end

-- Three layers: a dark plate offset downwards for weight, the body, and a hairline
-- highlight along the top edge. That plus the near-black outline is what reads as a
-- solid game panel instead of a flat translucent rectangle -- and then the three
-- passes above, which are what stop it reading as everyone else's.
local function panel(parent: Instance, w: number, h: number, radius: number, seed: number?)
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(w, h)
	holder.Parent = parent

	local shade = Instance.new("Frame")
	shade.Size = UDim2.fromScale(1, 1)
	shade.Position = UDim2.fromOffset(0, 5)
	shade.BackgroundColor3 = OUTLINE
	shade.BackgroundTransparency = 0.45
	shade.BorderSizePixel = 0
	shade.ZIndex = 0
	shade.Parent = holder
	corner(shade, radius)

	local body = Instance.new("Frame")
	body.Size = UDim2.fromScale(1, 1)
	body.BackgroundColor3 = PANEL_BOT
	body.BorderSizePixel = 0
	body.ZIndex = 1
	body.Parent = holder
	corner(body, radius)
	gradient(body, PANEL_TOP, PANEL_BOT)
	-- 4px, matching PanelKit.outline. A hairline stroke is the single loudest
	-- "default Roblox UI" tell, and next to the rail's 4px buttons a 2.5 read as
	-- an unfinished version of the same thing.
	local st = stroke(body, 4, OUTLINE)

	-- Gloss cap: white across the top ~46%, faded out downward. Cheap fake specular,
	-- and the same trick the menu rail uses on its buttons.
	local gloss = Instance.new("Frame")
	gloss.Size = UDim2.new(1, -10, 0.46, 0)
	gloss.Position = UDim2.fromOffset(5, 4)
	-- CREAM, not white. A pure-white cap on a warm brown board is the giveaway
	-- that the highlight was added by a UI kit rather than by the sun over a
	-- beach; the same cap in sand light reads as bleached timber.
	gloss.BackgroundColor3 = Color3.fromRGB(255, 246, 224)
	gloss.BorderSizePixel = 0
	gloss.ZIndex = 2
	gloss.Parent = body
	corner(gloss, math.max(4, radius - 4))
	local gg = Instance.new("UIGradient")
	gg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.48),
		NumberSequenceKeypoint.new(0.7, 0.86),
		NumberSequenceKeypoint.new(1, 1),
	})
	gg.Rotation = 90
	gg.Parent = gloss

	-- Grain count off the AREA, so the wide load bar is not the same handful of
	-- specks stretched across three times the timber.
	weather(body, seed or 1, math.clamp(math.floor(w * h / 420), 8, 36))
	-- Count off the WIDTH, since they step along it: a fixed number would leave
	-- the 274-wide pills combed and the short ones nearly bare.
	grooves(body, radius, math.clamp(math.floor(w / 34), 4, 10), seed or 1)
	wetline(body, radius)
	rim(body, radius)

	return holder, body, st
end

local function iconHolder(parent: Instance, px: number)
	local h = Instance.new("Frame")
	h.Size = UDim2.fromOffset(px, px)
	h.BackgroundTransparency = 1
	h.ZIndex = 3
	h.Parent = parent
	return h
end

-- A recessed plate behind an icon. Every stat row starts with one, so the left
-- end of the stack lines up as a column of identical slots whatever is drawn in
-- them -- which is what stops three unrelated icons reading as clutter.
local function chip(parent: Instance, px: number, x: number, y: number)
	local c = Instance.new("Frame")
	c.Size = UDim2.fromOffset(px, px)
	c.Position = UDim2.fromOffset(x, y)
	c.BackgroundColor3 = Color3.fromRGB(84, 50, 24)
	c.BackgroundTransparency = 0.12
	c.BorderSizePixel = 0
	c.ZIndex = 4
	c.Parent = parent
	corner(c, px * 0.3)
	stroke(c, 2, OUTLINE, 0.3)
	return c
end

--[[
	THE COIN IS ART NOW, NOT THREE FRAMES.

	It used to be a disc, a lighter disc inset on top, and a "$" typed over both.
	That reads as a coin at 16px and as three concentric circles the moment it is
	any bigger -- and this HUD draws it at 38. The uploaded art carries its own
	rim, bevel, embossed glyph and specular, none of which are worth rebuilding
	out of primitives.

	The rest of this HUD stays drawn rather than imported, deliberately: the bag
	and rake icons are simple enough that Frames beat a texture fetch, and the
	whole point of drawing them was that they render identically everywhere. A
	coin is the one that was losing that trade.
]]
local COIN_IMAGE = "rbxassetid://92788126897567"

local function coinIcon(parent: Instance, px: number)
	local holder = iconHolder(parent, px)
	local img = Instance.new("ImageLabel")
	img.Name = "Coin"
	img.Size = UDim2.fromScale(1, 1)
	img.BackgroundTransparency = 1
	img.Image = COIN_IMAGE
	-- Fit, not Stretch: the source is square and every slot that uses it is too,
	-- but Fit keeps it round if someone ever hands it a rectangle.
	img.ScaleType = Enum.ScaleType.Fit
	img.ZIndex = 3
	img.Parent = holder
	return holder
end

local function bagIcon(parent: Instance, px: number)
	local holder = iconHolder(parent, px)

	-- the handle is a ring whose lower half the body hides. It has to be lighter than
	-- the bag itself or it disappears into the dark panel behind the icon.
	local handle = Instance.new("Frame")
	handle.Size = UDim2.fromScale(0.56, 0.56)
	handle.Position = UDim2.fromScale(0.22, 0)
	handle.BackgroundTransparency = 1
	handle.ZIndex = 3
	handle.Parent = holder
	roundOff(handle)
	stroke(handle, math.max(2.5, px * 0.11), Color3.fromRGB(206, 142, 62))

	local body = Instance.new("Frame")
	body.Size = UDim2.fromScale(1, 0.62)
	body.Position = UDim2.fromScale(0, 0.38)
	body.BackgroundColor3 = Color3.fromRGB(206, 142, 66)
	body.BorderSizePixel = 0
	body.ZIndex = 4
	body.Parent = holder
	corner(body, px * 0.26)
	gradient(body, Color3.fromRGB(232, 172, 92), Color3.fromRGB(176, 108, 44))
	stroke(body, math.max(2, px * 0.085), Color3.fromRGB(74, 42, 16))

	local flap = Instance.new("Frame")
	flap.Size = UDim2.fromScale(1, 0.32)
	flap.BackgroundColor3 = Color3.fromRGB(150, 92, 36)
	flap.BorderSizePixel = 0
	flap.ZIndex = 5
	flap.Parent = body
	corner(flap, px * 0.16)
	return holder
end

-- the sifter: a long handle running down into a wire basket
local function sifterIcon(parent: Instance, px: number)
	local holder = iconHolder(parent, px)

	local bar = Instance.new("Frame")
	bar.Size = UDim2.fromOffset(math.max(3, px * 0.12), px * 0.66)
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.fromScale(0.74, 0)
	bar.Rotation = 26
	bar.BackgroundColor3 = Color3.fromRGB(198, 204, 216)
	bar.BorderSizePixel = 0
	bar.ZIndex = 3
	bar.Parent = holder
	corner(bar, 3)
	stroke(bar, 2, OUTLINE)

	local basket = Instance.new("Frame")
	basket.Size = UDim2.fromScale(1, 0.42)
	basket.Position = UDim2.fromScale(0, 0.54)
	basket.BackgroundColor3 = Color3.fromRGB(176, 182, 192)
	basket.BorderSizePixel = 0
	basket.ZIndex = 4
	basket.Parent = holder
	corner(basket, px * 0.12)
	gradient(basket, Color3.fromRGB(216, 222, 232), Color3.fromRGB(138, 146, 158))
	stroke(basket, math.max(2, px * 0.085), OUTLINE)

	-- the wire, or the icon is just a grey box
	for i = 1, 3 do
		local wire = Instance.new("Frame")
		wire.Size = UDim2.new(0, math.max(1, px * 0.05), 1, 0)
		wire.Position = UDim2.fromScale(i * 0.25, 0)
		wire.BackgroundColor3 = Color3.fromRGB(92, 98, 108)
		wire.BorderSizePixel = 0
		wire.ZIndex = 5
		wire.Parent = basket
	end
	return holder
end

-- combed sand: three tapering lines
--[[
	A ROUND PLATE, NOT A SQUARE ONE.

	chip() is a rounded SQUARE, which is right for the load bar's icon column --
	square slots line up as a column, and that is what stops three unrelated
	glyphs reading as clutter. The rake badge is not in that column: it is one
	icon on one bar, and a disc reads as a badge stamped INTO the board rather
	than as a tile sitting on it.

	Two rings: the dark outer edge everything here is outlined in, and a warm
	inner one inset from it -- the lit inside face of a hole punched through
	timber. The inner ring is the whole reason it reads as recessed rather than
	as a brown circle drawn on the front.
]]
local function disc(parent: Instance, px: number, x: number, y: number)
	local c = Instance.new("Frame")
	c.Size = UDim2.fromOffset(px, px)
	c.Position = UDim2.fromOffset(x, y)
	c.BackgroundColor3 = Color3.fromRGB(84, 50, 24)
	c.BackgroundTransparency = 0.12
	c.BorderSizePixel = 0
	c.ZIndex = 4
	c.Parent = parent
	roundOff(c)
	stroke(c, 2.5, OUTLINE, 0.15)

	local ring = Instance.new("Frame")
	ring.Name = "Ring"
	ring.Size = UDim2.new(1, -7, 1, -7)
	ring.Position = UDim2.fromOffset(3.5, 3.5)
	ring.BackgroundTransparency = 1
	ring.ZIndex = 4
	ring.Parent = c
	roundOff(ring)
	stroke(ring, 2, Color3.fromRGB(206, 156, 100), 0.32)
	return c
end

--[[
	THREE EQUAL TINES.

	These used to taper and fade down the stack -- each bar shorter and more
	transparent than the one above it. At 20px that reads as a signal-strength
	meter rather than as a rake. Three of the same length and the same weight is
	both what the reference has and what the head of a rake actually looks like.

	Spaced off the height rather than at fixed fractions, so the stack stays
	centred at whatever size it is handed.
]]
local function rakeIcon(parent: Instance, px: number)
	local holder = iconHolder(parent, px)
	local h = math.max(2, math.floor(px * 0.17 + 0.5))
	local gap = (px - h * 3) / 4
	for i = 0, 2 do
		local line = Instance.new("Frame")
		line.Size = UDim2.new(1, 0, 0, h)
		line.Position = UDim2.fromOffset(0, gap + i * (h + gap))
		line.BackgroundColor3 = Color3.fromRGB(255, 228, 172)
		line.BorderSizePixel = 0
		line.ZIndex = 5
		line.Parent = holder
		roundOff(line)
	end
	return holder
end

-- Gold, gradient-filled, heavily outlined, with a hard shadow underneath: the
-- money read has to survive being drawn over bright sand.
--[[
	GOLD, AND WARMER THAN IT WAS.

	This went to cream for a while, on the reasoning that gold text beside a gold
	coin makes the coin read as the first glyph of the number. That is a real
	effect, but it is the ART that fixes it now: the uploaded coin has a rim, a
	bevel and a highlight, so it is plainly an object rather than a letter, and
	the number is free to be gold again.

	Warmer than the original gradient, which ran from near-white to a light
	amber and washed out over bright sand. This one starts at a proper gold and
	ends deep, so the whole glyph is metal rather than only its lower half.

	Drawn three times over: a dark shade dropped 3px for weight, the fill, and a
	heavy outline. That is what keeps it legible over sand, which is the thing
	this readout has to survive.
]]
local function bigNumber(parent: Instance, size: number)
	local shade = label(parent, "", size, Color3.fromRGB(74, 38, 10), Enum.Font.LuckiestGuy)
	shade.ZIndex = 3
	shade.Position = UDim2.fromOffset(0, 3)
	shade.TextXAlignment = Enum.TextXAlignment.Left

	local main = label(parent, "", size, GOLD_LIGHT, Enum.Font.LuckiestGuy)
	main.ZIndex = 4
	main.TextXAlignment = Enum.TextXAlignment.Left
	gradient(main, Color3.fromRGB(255, 233, 140), Color3.fromRGB(243, 158, 24))
	textStroke(main, math.max(3, size * 0.15), Color3.fromRGB(64, 28, 2))
	return main, shade
end

local function comma(n: number): string
	local s = tostring(math.max(0, math.floor(n)))
	local grouped = (s:reverse():gsub("(%d%d%d)", "%1,"):reverse())
	if grouped:sub(1, 1) == "," then
		grouped = grouped:sub(2)
	end
	return grouped
end

local gui = Instance.new("ScreenGui")
gui.Name = "CleanTheBeachHUD"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = player:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- Left stat stack
--
-- Two rows of identical width sharing one left-hand icon column, sized to sit
-- under the platform's own top bar rather than compete with it. Slimmer and
-- flatter than the cards these replaced: at a glance the player should read the
-- number, not the container.
----------------------------------------------------------------
-- 274, MATCHED TO THE CARRYING CARD'S SIGNBOARD BELOW.
--
-- These two pills and InventoryHud's card are one column down the left edge and
-- they were three different widths: 252 here against a 274 banner, so the card
-- stuck 22px out to the right of everything above it.
--
-- The pills moved rather than the card, and that is not the lazy way round. The
-- card's 248 is a measured content floor -- a row has to hold the longest
-- display name beside a 34px art tile, and on the line below the longest state
-- string clear of the widest price, which leaves about eight pixels of slack in
-- the whole row. Narrowing the card to 252 would have truncated the state on
-- every crusted find. Widening two bars costs nothing.
local ROW_W = 274

--[[
	THE MONEY BAR IS ART, NOT A DRAWN PANEL.

	103160041720768 is not a plank texture -- it is the whole bar, coin and all.
	That is why it came out squashed under every scale mode at first: measured
	off the file itself, the artwork is 369x85 sitting in a 369x687 canvas with
	593px of empty space underneath it, so anything told to fit the file was
	fitting mostly nothing.

	So it is cropped to the artwork with ImageRect and drawn at the artwork's own
	aspect. Everything the drawn panel used to supply -- timber, grooves, grain,
	gloss cap, wetline, rim, the coin and its recessed chip -- arrives with the
	picture. Only the number is still drawn on top.

	panel(), chip(), coinIcon(), grooves() and the rest stay: the load bar and
	the rake pill below are still drawn, and they have to keep matching each
	other. This is the one readout that got a painted version.
]]
local BOARD_IMAGE  = "rbxassetid://103160041720768"
-- The opaque bounds of the artwork inside that canvas, read off the pixels.
local BOARD_OFFSET = Vector2.new(0, 9)
local BOARD_SIZE   = Vector2.new(369, 85)
local BOARD_ASPECT = 369 / 85
-- How far across the bar the baked-in coin ends, as a fraction of its width.
-- The number is placed off this rather than off a guessed pixel count, so the
-- gap between coin and text survives the bar being any size.
local BOARD_COIN   = 65 / 369

-- Height comes from the ART, not the other way round: the width is what has to
-- match the bars below it, so the height is whatever that width implies.
local COIN_H = math.floor(ROW_W / BOARD_ASPECT + 0.5)

local coinPill = Instance.new("Frame")
coinPill.Name = "CoinPill"
coinPill.BackgroundTransparency = 1
coinPill.Size = UDim2.fromOffset(ROW_W, COIN_H)
coinPill.Position = UDim2.fromOffset(16, 14)
coinPill.Parent = gui

local board = Instance.new("ImageLabel")
board.Name = "Board"
board.Size = UDim2.fromScale(1, 1)
board.BackgroundTransparency = 1
board.Image = BOARD_IMAGE
board.ImageRectOffset = BOARD_OFFSET
board.ImageRectSize = BOARD_SIZE
-- Stretch, and it costs nothing: the pill is drawn at the artwork's own aspect,
-- so this is a 1:1 blit rather than a stretch.
board.ScaleType = Enum.ScaleType.Stretch
board.ZIndex = 1
board.Parent = coinPill

local coinBody = coinPill
local textX = math.floor(ROW_W * BOARD_COIN) + 12

local coinText, coinShade = bigNumber(coinBody, 32)
coinText.Size = UDim2.new(1, -(textX + 14), 1, 0)
coinText.Position = UDim2.fromOffset(textX, 0)
coinShade.Size = coinText.Size
coinShade.Position = UDim2.fromOffset(textX, 3)

----------------------------------------------------------------
-- Load bar
--
-- One wide capsule sitting flush with the top edge, where the bar IS the fill
-- rather than a card with a little progress strip inside it. The 348x94 panel
-- this replaces floated in the middle of the scene like a window someone left
-- open; a full-width track anchored to the edge reads as part of the frame.
----------------------------------------------------------------
local BAR_W, BAR_H = 620, 54
local bagPanel, bagBody, bagStroke = panel(gui, BAR_W, BAR_H, BAR_H * 0.5, 27)
bagPanel.AnchorPoint = Vector2.new(0.5, 0)
bagPanel.Position = UDim2.new(0.5, 0, 0, 10)
bagBody.ClipsDescendants = true
bagBody.BackgroundTransparency = 0.08

local barFill = Instance.new("Frame")
barFill.Size = UDim2.new(0, 0, 1, 0)
barFill.BorderSizePixel = 0
barFill.ZIndex = 3
barFill.Parent = bagBody
roundOff(barFill)
local fillGrad = gradient(barFill, Color3.fromRGB(168, 236, 255), Color3.fromRGB(46, 152, 214))

--[[
	THE FOAM AT THE FRONT OF THE WAVE.

	A fill that simply stops has a hard vertical edge across it, which is the
	one thing on a beach that never happens. Parented to the FILL rather than
	positioned each frame, so it rides the existing tween for free and there is
	no second thing to keep in step with the first.

	The gradient runs clear-to-white left to right, so the foam gathers at the
	leading edge and dissolves back into the water behind it.
]]
local barFoam = Instance.new("Frame")
barFoam.Name = "Foam"
barFoam.AnchorPoint = Vector2.new(1, 0)
barFoam.Position = UDim2.fromScale(1, 0)
barFoam.Size = UDim2.new(0, 16, 1, 0)
barFoam.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
barFoam.BorderSizePixel = 0
barFoam.ZIndex = 4
barFoam.Parent = barFill
roundOff(barFoam)
local foamGrad = Instance.new("UIGradient")
foamGrad.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.92),
	NumberSequenceKeypoint.new(1, 0.3),
})
foamGrad.Parent = barFoam

local bagChip = chip(bagBody, 40, 7, 7)
local bagGlyph = bagIcon(bagChip, 30)
bagGlyph.Position = UDim2.fromOffset(5, 5)
bagGlyph.ZIndex = 6

local bagTitle = label(bagBody, "LOAD   0 / 20 lbs", 23, CREAM, Enum.Font.LuckiestGuy)
bagTitle.ZIndex = 6
bagTitle.Size = UDim2.new(1, -250, 1, 0)
bagTitle.Position = UDim2.fromOffset(58, 0)
bagTitle.TextXAlignment = Enum.TextXAlignment.Left
textStroke(bagTitle, 2.5, OUTLINE, 0.15)

local bagWorth = label(bagBody, "worth $0", 20, Color3.fromRGB(255, 236, 202), Enum.Font.GothamBold)
bagWorth.ZIndex = 6
bagWorth.Size = UDim2.new(0, 180, 1, 0)
bagWorth.Position = UDim2.new(1, -200, 0, 0)
bagWorth.TextXAlignment = Enum.TextXAlignment.Right
textStroke(bagWorth, 2, OUTLINE, 0.25)

----------------------------------------------------------------
-- Beach progress
----------------------------------------------------------------
local progPill, progBody = panel(gui, ROW_W, 46, 23, 43)
-- Follows the money bar rather than a hardcoded 80: its height is now set by
-- the artwork's aspect, so anything below it has to be told where that ends.
progPill.Position = UDim2.fromOffset(16, 14 + COIN_H + 8)
progBody.ClipsDescendants = true

--[[
	THE PILL IS THE BAR -- AND THE BAR IS THE PILL'S OWN SILHOUETTE.

	ClipsDescendants clips to a RECTANGLE. It knows nothing about the UICorner
	that makes this pill a capsule, and that is the whole of what was wrong here:
	the fill was a square frame growing from x = 0, so its corners painted into
	the 23px rounded end and came back out of the dark cap as two pale square
	nubs -- and did the same at the far end the moment the beach was finished.
	Setting ClipsDescendants was never going to catch it, and neither would
	rounding the fill, because a rounded rect narrower than 46 has a cap of its
	own radius and not the pill's.

	So nothing is clipped into shape any more. The fill is a frame the EXACT size
	and radius of the pill, and HOW MUCH OF IT YOU CAN SEE is a UIGradient whose
	transparency steps from opaque to clear at the rake line. The silhouette is
	the capsule at 0%, at 100% and at every point in between, because it is the
	same unchanging frame throughout.

	ZIndex 1 -- UNDER the board's gloss cap and wet line (both 2) rather than
	over them. The fill used to carry its own top-to-bottom gradient and sit on
	top of both; letting the board's own lighting fall on it instead is one
	fewer thing to keep in step, and it means the raked sand is lit by the same
	sun as the timber it is filling.
]]
-- CLEAN SAND, not lime.
--
-- The fill was green because the two left pills sit one above the other and
-- both are bars, so sharing the load bar's blue made the beach's progress read
-- as a second copy of the bag. That reasoning still holds -- but the thing this
-- bar measures is how much of the BEACH has been combed flat, and the honest
-- colour for that is the sand it leaves behind. Pale cream against the dark
-- timber is at least as separable from sea-blue as lime was, and it means the
-- bar fills with the thing it is counting.
--
-- One flat mid-sand rather than the old 255,242,202 -> 232,190,116 ramp: the
-- gloss above and the wet line below supply that ramp now, and starting from
-- the pale end of it as well would blow the top of the bar out to white.
local progFill = Instance.new("Frame")
progFill.Name = "Raked"
progFill.Size = UDim2.fromScale(1, 1)
progFill.BackgroundColor3 = Color3.fromRGB(244, 216, 159)
progFill.BorderSizePixel = 0
progFill.ZIndex = 1
progFill.Parent = progBody
corner(progFill, 23)

-- Rotation 0, so the sequence below runs left to right across the pill. Its
-- Color is left at the default white, which multiplies to nothing: this
-- gradient is carrying the fill LINE, not a colour.
local progGrad = Instance.new("UIGradient")
progGrad.Rotation = 0
progGrad.Parent = progFill

-- The last pass of the rake: the bright lip of freshly turned sand at the
-- leading edge. A SIBLING of the fill now rather than a child of it -- the fill
-- no longer changes width, so there is no right-hand edge on it left to ride.
local progEdge = Instance.new("Frame")
progEdge.Name = "RakeEdge"
progEdge.AnchorPoint = Vector2.new(1, 0.5)
progEdge.Position = UDim2.fromScale(0, 0.5)
progEdge.Size = UDim2.new(0, 4, 0.74, 0)
progEdge.BackgroundColor3 = Color3.fromRGB(255, 253, 240)
progEdge.BackgroundTransparency = 0.22
progEdge.BorderSizePixel = 0
-- Over the fill (1), under the grooves (4): the comb marks are cut INTO the
-- fresh sand, not laid behind it.
progEdge.ZIndex = 3
progEdge.Visible = false
progEdge.Parent = progBody
roundOff(progEdge)

--[[
	HOW FAR THE LIP MAY TRAVEL.

	It is 4 wide and 34 tall, and the pill's ends are 23-radius arcs -- so 17px
	above and below the centre line, which is where the lip's own corners are,
	the arc has already pulled in by 23 - sqrt(23^2 - 17^2) = 7.5px. Parked flush
	against either end the lip would therefore be 7px outside the capsule at its
	own top and bottom, which is precisely the escape the fill used to make.

	Clamped rather than hidden at the far end: at 100% it parks just inside the
	cap, and the cap is the leading edge at that point anyway. Hidden rather than
	clamped at the near end, because a bright lip pinned 11px ahead of a 2px
	sliver of sand reads as a bug, not as a rake.
]]
local EDGE_W, EDGE_H = 4, 0.74
local edgeHalf = 46 * EDGE_H * 0.5
local edgePull = 23 - math.sqrt(math.max(0, 23 * 23 - edgeHalf * edgeHalf))
local EDGE_MIN = (edgePull + EDGE_W) / ROW_W
local EDGE_MAX = (ROW_W - edgePull) / ROW_W

-- Two pixels of softness on the rake line. One is a stair that crawls as the
-- bar tweens; two reads as the same hard edge and holds still. In SCALE,
-- because that is the space a UIGradient's keypoints live in.
local RAKE_SOFT = 2 / ROW_W

local function setRaked(t: number)
	t = math.clamp(t, 0, 1)
	progEdge.Visible = t >= EDGE_MIN
	progEdge.Position = UDim2.fromScale(math.clamp(t, EDGE_MIN, EDGE_MAX), 0.5)

	-- The flat ends are their own case: a NumberSequence may not repeat a
	-- keypoint time, and a rake line sitting exactly on 0 or 1 has no room for
	-- the pair of keypoints that make it a step.
	if t <= 0 then
		progGrad.Transparency = NumberSequence.new(1)
		return
	elseif t >= 1 then
		progGrad.Transparency = NumberSequence.new(0)
		return
	end
	local a = math.clamp(t, 0.002, 1 - RAKE_SOFT - 0.002)
	progGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(a, 0),
		NumberSequenceKeypoint.new(a + RAKE_SOFT, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
end

-- What paintProgress moves. TweenService cannot interpolate a NumberSequence,
-- so the tween runs on a plain number and setRaked rebuilds the sequence from
-- it -- which also makes setRaked the ONLY place the rake line is decided, so
-- the lip and the sand behind it cannot drift apart.
local progLevel = Instance.new("NumberValue")
progLevel.Name = "RakedLevel"
progLevel.Parent = progBody
progLevel.Changed:Connect(setRaked)
setRaked(0)

local rakeTween
local function tweenRaked(frac: number, instant: boolean?)
	if rakeTween then
		rakeTween:Cancel()
		rakeTween = nil
	end
	if instant then
		-- Changed does not fire when the value is already what it is being set
		-- to, and the tide reset can land on a bar that is already empty.
		progLevel.Value = frac
		setRaked(frac)
		return
	end
	rakeTween = TweenService:Create(progLevel,
		TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = frac })
	rakeTween:Play()
end

--[[
	THE COMB GROOVES.

	Drawn across the whole raked span and left standing while the rake line moves
	under them. Inside the fill they would stretch with it -- a comb whose teeth
	get further apart the more of the beach you have raked -- and they would
	vanish the moment the tide reset the bar.

	They are dark and half-transparent, which means they only show up against the
	pale sand: grooves appear in the part of the beach you have actually raked
	and the bare timber ahead of them stays smooth. That falls out of the drawing
	order rather than being maintained anywhere.

	AND THEY STOP SHORT OF BOTH CAPS, for the same reason the fill is no longer a
	growing rectangle. progBody clips to a rectangle, not to the capsule, so the
	old span -- which ran to 0.977 of the width -- drove the last two grooves
	straight through the rounded right-hand end and out into the sky.
]]
local GROOVE_LEAN, GROOVE_W = -16, 3
-- How far one groove's ink sits from its own centre line at the pill's top and
-- bottom edges: the lean throws it 23 * tan(16) sideways over half the pill's
-- height, and the bar's own half-width covers 1.5 / cos(16) more at any given
-- height. About 8px, and it is that, not the 3px width, that has to clear the
-- caps.
local lean = math.rad(math.abs(GROOVE_LEAN))
local grooveReach = 23 * math.tan(lean) + (GROOVE_W * 0.5) / math.cos(lean)
-- Inside both 23px caps, and clear of the rake icon's chip -- which ends at
-- x = 39 and shares their ZIndex. The extra pixel is antialiasing margin: the
-- arithmetic above lands the outermost groove exactly ON the cap's tangent
-- point, and an exact tangent still fringes.
local grooveLo = math.max(23, 39 + 4) + grooveReach + 1
local grooveHi = ROW_W - 23 - grooveReach - 1
for i = 1, 9 do
	local groove = Instance.new("Frame")
	groove.Name = "Groove"
	groove.AnchorPoint = Vector2.new(0.5, 0.5)
	groove.Position = UDim2.fromScale(
		(grooveLo + (i - 1) / 8 * (grooveHi - grooveLo)) / ROW_W, 0.5)
	-- Taller than the pill and leaned over: a rotated frame has to overhang or
	-- its corners pull away from the top and bottom edges. progBody clips that
	-- overhang off -- it is only the SIDES that clipping cannot help with.
	groove.Size = UDim2.new(0, GROOVE_W, 1.7, 0)
	groove.Rotation = GROOVE_LEAN
	groove.BackgroundColor3 = Color3.fromRGB(112, 68, 30)
	groove.BackgroundTransparency = 0.6
	groove.BorderSizePixel = 0
	groove.ZIndex = 4
	groove.Parent = progBody
end

-- 36 in a 46-tall pill: 5px of board above and below, so the badge reads as set
-- into the bar rather than floating in the middle of it.
local progChip = disc(progBody, 36, 5, 5)
local progGlyph = rakeIcon(progChip, 20)
progGlyph.Position = UDim2.fromOffset(8, 8)
progGlyph.ZIndex = 5

local progText = label(progBody, "BEACH RAKED  0%", 16, CREAM, Enum.Font.LuckiestGuy)
progText.ZIndex = 6
progText.Size = UDim2.new(1, -62, 1, 0)
progText.Position = UDim2.fromOffset(50, 0)
progText.TextXAlignment = Enum.TextXAlignment.Left
-- SOLID, and thicker than the 2 / 0.3 it was. That was sized for cream letters
-- on dark timber, which is the ONLY background this label used to have. It now
-- spends most of a session sitting on pale raked sand -- cream on cream -- and a
-- thin 30%-transparent outline is not enough separation to read at a glance.
-- The letters stay cream so the two left pills still match; the outline is what
-- carries them over both backgrounds.
textStroke(progText, 3, OUTLINE)

----------------------------------------------------------------
-- Upgrade button
----------------------------------------------------------------
local upPanel = Instance.new("Frame")
upPanel.Size = UDim2.fromOffset(316, 116)
upPanel.AnchorPoint = Vector2.new(0.5, 0.5)
upPanel.Position = UDim2.new(1, -184, 0.62, 0)
upPanel.BackgroundTransparency = 1
upPanel.Parent = gui

-- Superseded by the Beach Shop's stock list (BeachMenuHud), which sells the same Sifter
-- Width levels at the same costs. Hidden rather than deleted so refreshUpgrade
-- and the Upgraded-shake at the bottom of this file keep operating on a live
-- frame instead of erroring on nil. To bring the card back, delete this line.
upPanel.Visible = false

local upScale = Instance.new("UIScale")
upScale.Parent = upPanel

local upShade = Instance.new("Frame")
upShade.Size = UDim2.fromScale(1, 1)
upShade.Position = UDim2.fromOffset(0, 6)
upShade.BackgroundColor3 = OUTLINE
upShade.BackgroundTransparency = 0.45
upShade.BorderSizePixel = 0
upShade.ZIndex = 0
upShade.Parent = upPanel
corner(upShade, 22)

local upBtn = Instance.new("TextButton")
upBtn.Size = UDim2.fromScale(1, 1)
upBtn.BackgroundColor3 = Color3.fromRGB(38, 132, 78)
upBtn.AutoButtonColor = false
upBtn.Text = ""
upBtn.ZIndex = 1
upBtn.Parent = upPanel
corner(upBtn, 22)
stroke(upBtn, 3, OUTLINE)
local upGrad = gradient(upBtn, Color3.fromRGB(86, 214, 130), Color3.fromRGB(24, 104, 62))

local upGloss = Instance.new("Frame")
upGloss.Size = UDim2.new(1, -22, 0, 2)
upGloss.Position = UDim2.fromOffset(11, 3)
upGloss.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
upGloss.BackgroundTransparency = 0.78
upGloss.BorderSizePixel = 0
upGloss.ZIndex = 2
upGloss.Parent = upBtn
corner(upGloss, 2)

local upGlyph = sifterIcon(upBtn, 36)
upGlyph.Position = UDim2.fromOffset(16, 12)

local upTitle = label(upBtn, "WIDER SIFTER", 23, CREAM)
upTitle.ZIndex = 3
upTitle.Size = UDim2.new(1, -72, 0, 30)
upTitle.Position = UDim2.fromOffset(62, 11)
upTitle.TextXAlignment = Enum.TextXAlignment.Left
textStroke(upTitle, 2.5, OUTLINE, 0.2)

local upSub = label(upBtn, "9 \u{2192} 13 studs wide", 17, Color3.fromRGB(214, 255, 228), Enum.Font.GothamBold)
upSub.ZIndex = 3
upSub.Size = UDim2.new(1, -38, 0, 22)
upSub.Position = UDim2.fromOffset(19, 46)
upSub.TextXAlignment = Enum.TextXAlignment.Left

local upCoin = coinIcon(upBtn, 28)
upCoin.Position = UDim2.fromOffset(19, 76)

local upCost = label(upBtn, "70", 24, GOLD_LIGHT)
upCost.ZIndex = 3
upCost.Size = UDim2.new(1, -62, 0, 30)
upCost.Position = UDim2.fromOffset(55, 74)
upCost.TextXAlignment = Enum.TextXAlignment.Left
textStroke(upCost, 2.5, Color3.fromRGB(74, 34, 4), 0.15)

----------------------------------------------------------------
-- Hint + toast
----------------------------------------------------------------
local hint = label(gui, "", 24, CREAM, Enum.Font.GothamBold)
hint.Size = UDim2.new(0, 720, 0, 36)
hint.Position = UDim2.new(0.5, -360, 1, -76)
-- The warm ink every panel and every sign in the game is outlined with, not
-- the cold near-black INK this file opens with. One outline colour is most of
-- what makes separately-written screens read as one set.
textStroke(hint, 3, OUTLINE, 0.15)

-- Bare drop-shadowed text at 0.34 height is gone; ToastKit draws these now. The
-- split is by JOB, not by colour: a sale or a level is a thing you should FEEL,
-- so it gets the big slab across the middle (banner). A refusal is a thing you
-- need to READ, so it joins the stack under the load bar (toast) where it can sit
-- alongside whatever else is talking.
local function showBanner(text: string, kind: string, hold: number)
	ToastKit.banner(text, kind, hold)
end

local function showToast(text: string, kind: string, hold: number)
	ToastKit.toast(text, kind, hold)
end

-- Scales via a UIScale rather than Size, so repeated punches can never eat into
-- the element's real size and it never fights the hover tween.
local punchTweens = {}
local function punch(obj: GuiObject, amount: number)
	local sc = obj:FindFirstChildOfClass("UIScale")
	if not sc then
		sc = Instance.new("UIScale")
		sc.Parent = obj
	end
	local running = punchTweens[obj]
	if running then running:Cancel() end
	sc.Scale = 1 + amount
	local t = TweenService:Create(sc, TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
	punchTweens[obj] = t
	t:Play()
end

----------------------------------------------------------------
-- State -> UI
----------------------------------------------------------------
local shownCoins = 0
local targetCoins = 0

-- What this panel actually measures. The weight system rations by LOAD and
-- lifts the slot cap to 9999, so counting slots here would draw "3 / 9999"
-- against a bar that never moves. Falls back to the old slot readout when the
-- weight attributes are absent, so the panel still reads correctly in a place
-- with the weight system removed.
local function storage(): (number, number, string)
	local load = player:GetAttribute("CurrentWeight")
	local maxLoad = player:GetAttribute("MaxWeight")
	if type(load) == "number" and type(maxLoad) == "number" and maxLoad > 0 then
		return load, maxLoad, " lbs"
	end
	return player:GetAttribute("Bag") or 0, player:GetAttribute("BagMax") or Config.BAG_MAX, ""
end

-- "2", not "2.0" -- but 0.5 stays 0.5. comma() floors, which is right for cash
-- and wrong for a half-pound coin.
local function amount(n: number): string
	local whole = math.floor(n + 0.5)
	if math.abs(n - whole) < 1e-3 then
		return comma(whole)
	end
	return string.format("%.1f", n)
end

local function refreshBag()
	local carried, limit, unit = storage()
	local worth = player:GetAttribute("BagValue") or 0
	local full = carried >= limit - 1e-4

	bagTitle.Text = string.format("LOAD   %s / %s%s", amount(carried), amount(limit), unit)
	bagWorth.Text = string.format("worth $%s", comma(worth))
	-- An empty bar still has a fill frame, 0 wide, with the foam anchored to its
	-- right edge -- i.e. a 16px curl of surf sitting on the far left of an empty
	-- track. There is no wave until there is water.
	barFoam.Visible = carried > 1e-4
	-- Clamped: adoption prices a find AFTER it lands, so the load can sit a
	-- shade over the limit for the instant before the sifter stops.
	TweenService:Create(barFill, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.new(math.clamp(carried / limit, 0, 1), 0, 1, 0),
	}):Play()

	-- the outline is normally the near-black that every panel shares; going gold is
	-- the one loud state, so a full bag is unmissable without adding another widget
	if full then
		bagStroke.Color = GOLD
		bagStroke.Thickness = 5
		-- CREAM, not GOLD_LIGHT. Gold lettering was the emphasis when the bar
		-- behind it was sea-blue; once the fill goes gold too it is gold on gold,
		-- and the one moment the player most needs to read this line is the one
		-- where it washes out. The gold fill and the gold outline already say
		-- FULL twice over -- the text's job here is to stay legible.
		bagTitle.TextColor3 = CREAM
		fillGrad.Color = ColorSequence.new(Color3.fromRGB(255, 236, 150), Color3.fromRGB(255, 162, 32))
	else
		bagStroke.Color = OUTLINE
		bagStroke.Thickness = 4
		bagTitle.TextColor3 = CREAM
		fillGrad.Color = ColorSequence.new(Color3.fromRGB(168, 236, 255), Color3.fromRGB(46, 152, 214))
	end
end

local function refreshUpgrade()
	local level = player:GetAttribute("RollerLevel") or 1
	local width = player:GetAttribute("RollerWidth") or Config.LEVELS[1].width
	local coins = player:GetAttribute("Coins") or 0
	local nxt = Config.LEVELS[level + 1]

	if not nxt then
		upTitle.Text = "MAX SIFTER"
		upSub.Text = string.format("%d studs wide", width)
		upCost.Text = "Lv." .. level
		upCost.TextColor3 = Color3.fromRGB(232, 220, 255)
		upCoin.Visible = false
		upCost.Position = UDim2.fromOffset(19, 74)
		upGrad.Color = ColorSequence.new(Color3.fromRGB(178, 152, 240), Color3.fromRGB(78, 62, 132))
		return
	end

	upCoin.Visible = true
	upCost.Position = UDim2.fromOffset(55, 74)
	upTitle.Text = string.format("WIDER SIFTER  Lv.%d", level + 1)
	upSub.Text = string.format("%d \u{2192} %d studs wide", width, nxt.width)
	upCost.Text = comma(nxt.cost)

	if coins >= nxt.cost then
		upGrad.Color = ColorSequence.new(Color3.fromRGB(86, 214, 130), Color3.fromRGB(24, 104, 62))
		upCost.TextColor3 = GOLD_LIGHT
	else
		upGrad.Color = ColorSequence.new(Color3.fromRGB(96, 102, 116), Color3.fromRGB(42, 46, 58))
		upCost.TextColor3 = Color3.fromRGB(198, 204, 214)
	end
end

--[[
	IS THE PLAYER INSIDE THE WASH MINIGAME?

	The same test ToastKit uses to lift its notification column: WashHud is the
	ScreenGui WashClientController enables for the length of a session. Keyed off
	that rather than a new attribute so there is one source of truth for "a bay
	has the screen", and nothing to keep in sync.
]]
local function inBay(): boolean
	local pg = player:FindFirstChild("PlayerGui")
	local wash = pg and pg:FindFirstChild("WashHud")
	return wash ~= nil and wash:IsA("ScreenGui") and wash.Enabled
end

local function refreshHint()
	-- Nothing this line has to say applies while the player is at a bay. It
	-- advises where to take crusted finds -- and they are AT the wash bay,
	-- washing one -- so it was printing "WASH BAY to sell them" across the
	-- bottom of the minigame that does exactly that.
	hint.Visible = not inBay()
	if not hint.Visible then
		return
	end

	local carried = storage()
	local worth = player:GetAttribute("BagValue") or 0
	-- Off the server's flag, not off bag >= maxBag: the weight system lifted the
	-- slot cap to 9999, so that comparison is never true any more and the limit
	-- that actually bites is weight, which lives on the server.
	if player:GetAttribute("RollerBlocked") then
		-- The sifter genuinely stops now, so the hint has to say so rather than
		-- just suggest selling. BagValue counts CLEANED items only, so a full bag
		-- worth nothing is all crusted finds -- the sell pad would refuse those,
		-- and the sifting bay is the only way out of it.
		hint.Text = worth > 0
			and "BAG FULL \u{2014} the sifter stops until you sell!"
			or "BAG FULL of crusted finds \u{2014} wash them at the WASH BAY!"
		hint.TextColor3 = GOLD
	elseif (player:GetAttribute("CrustedWeight") or 0) > 0 then
		-- The sell pad will not take these, so after a sale they are ALL that is
		-- left on the weight bar. Saying so is the difference between "the game
		-- is broken" and "I have to go and sift these".
		local crusted = player:GetAttribute("CrustedWeight") or 0
		hint.Text = string.format("%s lbs of crusted finds \u{2014} WASH BAY to sell them", amount(crusted))
		hint.TextColor3 = Color3.fromRGB(255, 214, 140)
	elseif carried > 0 then
		hint.Text = "Keep raking \u{2014} or sell early at the green pad"
		hint.TextColor3 = Color3.fromRGB(252, 240, 218)
	else
		hint.Text = "Walk forward to drag the sifter and comb the sand flat"
		hint.TextColor3 = Color3.fromRGB(252, 240, 218)
	end
end

-- WashHud is built by another script and may not exist yet, so watch PlayerGui
-- rather than resolving it once. Same shape as ToastKit's band watcher.
task.spawn(function()
	local pg = player:WaitForChild("PlayerGui")
	local function adopt(inst: Instance)
		if inst.Name == "WashHud" and inst:IsA("ScreenGui") then
			inst:GetPropertyChangedSignal("Enabled"):Connect(refreshHint)
			refreshHint()
		end
	end
	for _, c in ipairs(pg:GetChildren()) do
		adopt(c)
	end
	pg.ChildAdded:Connect(adopt)
end)

player:GetAttributeChangedSignal("Bag"):Connect(function()
	refreshBag(); refreshHint(); punch(bagPanel, 0.06)
end)
player:GetAttributeChangedSignal("BagValue"):Connect(function()
	refreshBag(); refreshHint()
end)
player:GetAttributeChangedSignal("BagMax"):Connect(function()
	refreshBag(); refreshHint()
end)
-- The two the panel now actually draws. CurrentWeight moves on every pickup and
-- every sale; MaxWeight moves on a sifter upgrade, which the Bag attributes
-- above would never report.
player:GetAttributeChangedSignal("CurrentWeight"):Connect(function()
	refreshBag(); refreshHint(); punch(bagPanel, 0.06)
end)
player:GetAttributeChangedSignal("MaxWeight"):Connect(function()
	refreshBag(); refreshHint()
end)
player:GetAttributeChangedSignal("CrustedWeight"):Connect(refreshHint)
player:GetAttributeChangedSignal("RollerLevel"):Connect(refreshUpgrade)
player:GetAttributeChangedSignal("RollerBlocked"):Connect(refreshHint)
player:GetAttributeChangedSignal("Coins"):Connect(function()
	targetCoins = player:GetAttribute("Coins") or 0
	refreshUpgrade()
end)

----------------------------------------------------------------
-- Beach progress (mirrors the server's clean set)
----------------------------------------------------------------
-- PER ISLAND, because "Clean" and "Sync" both carry (islandId, indices) now.
-- This used to be one flat set fed `bumpProgress(a)` -- i.e. the island ID, a
-- NUMBER -- which threw "invalid argument #1 to 'ipairs'" on the first message
-- of every session and again on every rake batch, so the bar never moved and
-- the output window filled with the same stack.
--
-- Cell index 1 exists on every island, so the sets cannot be merged: two
-- islands' indices would alias and the beach would read as partly raked the
-- moment you swept the desert.
local fields = {}
for _, isl in ipairs(Config.ISLANDS) do
	fields[isl.id] = { set = {}, count = 0 }
end

-- Which island's number the bar is showing. Follows the player rather than
-- whichever island last sent a message: raking the desert should not repaint
-- the bar with the beach's percentage the instant you stop.
local shownIsland = Config.HOME

local function paintProgress(isl)
	local f = fields[isl.id]
	local frac = math.clamp(f.count / isl.cells, 0, 1)
	progText.Text = string.format("%s RAKED  %d%%", string.upper(isl.name), math.floor(frac * 100 + 0.5))
	-- The lip rides along inside setRaked, off the same number, rather than being
	-- switched on here a third of a second before the sand arrives under it.
	tweenRaked(frac)
end

local function bumpProgress(islandId, list)
	if type(list) ~= "table" then
		return
	end
	local isl = Config.island(islandId)
	local f = fields[isl.id]
	for _, idx in ipairs(list) do
		if not f.set[idx] then
			f.set[idx] = true
			f.count += 1
		end
	end
	if isl == shownIsland then
		paintProgress(isl)
	end
end

-- Retitles the bar when the player crosses to the other island. Half a second
-- is plenty: the islands are 1500 studs apart, so this can never flicker.
task.spawn(function()
	while true do
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local isl = hrp and Config.zoneAt(hrp.Position)
		if isl and isl ~= shownIsland then
			shownIsland = isl
			paintProgress(isl)
		end
		task.wait(0.5)
	end
end)

----------------------------------------------------------------
-- Button
----------------------------------------------------------------
-- hover scales the whole panel (shadow included) via its own UIScale; punch() uses
-- the button's, so a click never fights the hover tween
upBtn.MouseEnter:Connect(function()
	TweenService:Create(upScale, TweenInfo.new(0.12), { Scale = 1.04 }):Play()
end)
upBtn.MouseLeave:Connect(function()
	TweenService:Create(upScale, TweenInfo.new(0.12), { Scale = 1 }):Play()
end)
upBtn.Activated:Connect(function()
	-- The local clickSound helper is gone: it hand-built a Sound on SoundService,
	-- so it sat outside the bus and kept playing after the player switched Sound
	-- Effects off in Settings. AudioKit's UIClick is a real switch detent rather
	-- than the engine's clickfast blip -- and it is the one slot in the kit with
	-- NO attack ramp, because softening a button's transient is exactly what
	-- makes a button feel unresponsive.
	AudioKit.play("UIClick", nil, 1, 1.1)
	punch(upBtn, -0.06)
	Net:FireServer("Upgrade")
end)

----------------------------------------------------------------
-- Net feedback
----------------------------------------------------------------
local bagFullCooldown = 0

Net.OnClientEvent:Connect(function(action, a, b, c)
	if action == "Clean" then
		bumpProgress(a, b)

	elseif action == "Sync" then
		bumpProgress(a, b)

	elseif action == "Sold" then
		showBanner(string.format("SOLD %d ITEMS   +$%s", b, comma(a)), "money", 2.2)
		punch(coinPill, 0.14)

	elseif action == "Upgraded" then
		showBanner(string.format("SIFTER Lv.%d   \u{2014}   %d STUDS WIDE", a, b), "level", 2.4)
		refreshUpgrade()
		punch(upBtn, 0.12)

	elseif action == "Deny" then
		showToast(a, "deny", 2.0)
		local p = upPanel.Position
		for i = 1, 6 do
			task.delay(i * 0.045, function()
				upPanel.Position = p + UDim2.new(0, (i % 2 == 0) and 9 or -9, 0, 0)
			end)
		end
		task.delay(0.32, function() upPanel.Position = p end)

	elseif action == "BagFull" then
		if os.clock() - bagFullCooldown > 2.5 then
			bagFullCooldown = os.clock()
			showToast("BAG FULL \u{2014} GO SELL!", "warn", 2.2)
			punch(bagPanel, 0.12)
		end

	elseif action == "Tide" then
		-- (islandId, bonus, resetName) -- the same three the server sends CTB_Client.
		-- This read `a` as the bonus, so the toast announced "+$1 BONUS" for the
		-- beach and "+$2" for the desert, and it wiped the bar whichever island had
		-- actually reset.
		local isl = Config.island(a)
		fields[isl.id] = { set = {}, count = 0 }
		if isl == shownIsland then
			progText.Text = string.format("%s RAKED  0%%", string.upper(isl.name))
			-- Instant, and it cancels whatever tween was mid-flight: the tide has
			-- already taken the sand back, so watching the bar ease down to nothing
			-- over a third of a second would be describing something that is over.
			tweenRaked(0, true)
		end
		showBanner(string.format("THE %s ROLLED IN!   +$%s BONUS",
			c or isl.resetName or "TIDE", comma(b or 0)), "tide", 3)
	end
end)

----------------------------------------------------------------
-- Coin counter roll-up
----------------------------------------------------------------
RunService.RenderStepped:Connect(function(dt)
	if shownCoins ~= targetCoins then
		local diff = targetCoins - shownCoins
		local stepSize = math.max(1, math.abs(diff) * math.min(dt * 9, 1))
		if math.abs(diff) <= stepSize then
			shownCoins = targetCoins
		else
			shownCoins += (diff > 0 and stepSize or -stepSize)
		end
		local shown = "$" .. comma(shownCoins + 0.5)
		coinText.Text = shown
		coinShade.Text = shown
	end
end)

----------------------------------------------------------------
targetCoins = player:GetAttribute("Coins") or 0
shownCoins = targetCoins
coinText.Text = "$" .. comma(targetCoins)
coinShade.Text = coinText.Text
refreshBag()
refreshUpgrade()
refreshHint()

task.delay(1, function()
	showBanner("CLEAN THE BEACH", "tide", 3)
end)
