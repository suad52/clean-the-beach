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
local GOLD_DEEP  = Color3.fromRGB(240, 150, 20)
local COIN_INK   = Color3.fromRGB(122, 62, 8)

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

-- Three layers: a dark plate offset downwards for weight, the body, and a hairline
-- highlight along the top edge. That plus the near-black outline is what reads as a
-- solid game panel instead of a flat translucent rectangle.
local function panel(parent: Instance, w: number, h: number, radius: number)
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
	gloss.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
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

local function coinIcon(parent: Instance, px: number)
	local holder = iconHolder(parent, px)

	local disc = Instance.new("Frame")
	disc.Size = UDim2.fromScale(1, 1)
	disc.BackgroundColor3 = GOLD_DEEP
	disc.BorderSizePixel = 0
	disc.ZIndex = 3
	disc.Parent = holder
	roundOff(disc)
	gradient(disc, Color3.fromRGB(255, 206, 74), Color3.fromRGB(226, 126, 14))
	stroke(disc, math.max(2, px * 0.085), COIN_INK)

	local face = Instance.new("Frame")
	face.Size = UDim2.fromScale(0.7, 0.7)
	face.Position = UDim2.fromScale(0.15, 0.15)
	face.BackgroundColor3 = GOLD_LIGHT
	face.BorderSizePixel = 0
	face.ZIndex = 4
	face.Parent = disc
	roundOff(face)
	gradient(face, Color3.fromRGB(255, 240, 178), Color3.fromRGB(250, 186, 52))

	local sign = label(face, "$", px * 0.5, COIN_INK)
	sign.ZIndex = 5
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
local function rakeIcon(parent: Instance, px: number)
	local holder = iconHolder(parent, px)
	for i = 0, 2 do
		local line = Instance.new("Frame")
		line.Size = UDim2.new(1, -i * px * 0.18, 0, math.max(2, px * 0.15))
		line.Position = UDim2.fromOffset(i * px * 0.09, px * (0.18 + i * 0.26))
		line.BackgroundColor3 = Color3.fromRGB(255, 214, 140)
		line.BackgroundTransparency = i * 0.2
		line.BorderSizePixel = 0
		line.ZIndex = 3
		line.Parent = holder
		roundOff(line)
	end
	return holder
end

-- Gold, gradient-filled, heavily outlined, with a hard shadow underneath: the
-- money read has to survive being drawn over bright sand.
local function bigNumber(parent: Instance, size: number)
	local shade = label(parent, "", size, Color3.fromRGB(92, 46, 6), Enum.Font.LuckiestGuy)
	shade.ZIndex = 3
	shade.Position = UDim2.fromOffset(0, 3)
	shade.TextXAlignment = Enum.TextXAlignment.Left

	local main = label(parent, "", size, GOLD_LIGHT, Enum.Font.LuckiestGuy)
	main.ZIndex = 4
	main.TextXAlignment = Enum.TextXAlignment.Left
	gradient(main, Color3.fromRGB(255, 246, 186), Color3.fromRGB(255, 186, 42))
	textStroke(main, math.max(3, size * 0.14), Color3.fromRGB(64, 28, 2))
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
local ROW_W = 252

local coinPill, coinBody = panel(gui, ROW_W, 58, 29)
coinPill.Position = UDim2.fromOffset(16, 14)

local coinChip = chip(coinBody, 42, 8, 8)
local coinDisc = coinIcon(coinChip, 32)
coinDisc.Position = UDim2.fromOffset(5, 5)
coinDisc.ZIndex = 5

local coinText, coinShade = bigNumber(coinBody, 32)
coinText.Size = UDim2.new(1, -70, 1, 0)
coinText.Position = UDim2.fromOffset(60, 0)
coinShade.Size = coinText.Size
coinShade.Position = UDim2.fromOffset(60, 3)

----------------------------------------------------------------
-- Load bar
--
-- One wide capsule sitting flush with the top edge, where the bar IS the fill
-- rather than a card with a little progress strip inside it. The 348x94 panel
-- this replaces floated in the middle of the scene like a window someone left
-- open; a full-width track anchored to the edge reads as part of the frame.
----------------------------------------------------------------
local BAR_W, BAR_H = 620, 54
local bagPanel, bagBody, bagStroke = panel(gui, BAR_W, BAR_H, BAR_H * 0.5)
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
local fillGrad = gradient(barFill, Color3.fromRGB(140, 226, 255), Color3.fromRGB(56, 146, 250))

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
local progPill, progBody = panel(gui, ROW_W, 46, 23)
progPill.Position = UDim2.fromOffset(16, 80)
progBody.ClipsDescendants = true

-- the pill doubles as the fill bar for the beach as a whole
local progFill = Instance.new("Frame")
progFill.Size = UDim2.new(0, 0, 1, 0)
progFill.BorderSizePixel = 0
progFill.ZIndex = 3
progFill.Parent = progBody
-- LIME, and gradient-filled like the load bar rather than a flat 62%-alpha
-- wash. These two pills sit one above the other and both are bars, so sharing
-- the load bar's blue made the beach's progress read as a second copy of the
-- bag -- and at 0.62 transparency over a dark body it barely read as a fill at
-- all.
gradient(progFill, Color3.fromRGB(180, 248, 128), Color3.fromRGB(94, 184, 54))

local progChip = chip(progBody, 32, 7, 7)
local progGlyph = rakeIcon(progChip, 22)
progGlyph.Position = UDim2.fromOffset(5, 5)
progGlyph.ZIndex = 5

local progText = label(progBody, "BEACH RAKED  0%", 16, CREAM, Enum.Font.LuckiestGuy)
progText.ZIndex = 6
progText.Size = UDim2.new(1, -58, 1, 0)
progText.Position = UDim2.fromOffset(48, 0)
progText.TextXAlignment = Enum.TextXAlignment.Left
textStroke(progText, 2, OUTLINE, 0.3)

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
		bagTitle.TextColor3 = GOLD_LIGHT
		fillGrad.Color = ColorSequence.new(Color3.fromRGB(255, 236, 150), Color3.fromRGB(255, 162, 32))
	else
		bagStroke.Color = OUTLINE
		bagStroke.Thickness = 4
		bagTitle.TextColor3 = CREAM
		fillGrad.Color = ColorSequence.new(Color3.fromRGB(140, 226, 255), Color3.fromRGB(56, 146, 250))
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
	TweenService:Create(progFill, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.new(frac, 0, 1, 0),
	}):Play()
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
			progFill.Size = UDim2.new(0, 0, 1, 0)
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
