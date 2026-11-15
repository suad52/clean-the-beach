-- Clean the Beach :: HUD (coins, bag, upgrade button, toasts)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local TextService = game:GetService("TextService")
-- For the QUICK SELL key's purchase dialog, and for nothing else. Opening one
-- is a CLIENT call -- there is no server-side way to put a purchase modal on
-- somebody's screen -- so this HUD has to hold the service itself.
local MarketplaceService = game:GetService("MarketplaceService")

local player = Players.LocalPlayer
local CTB = ReplicatedStorage:WaitForChild("CTB")
local Config = require(CTB:WaitForChild("Config"))
local Net = CTB:WaitForChild("Net")
local Modules = ReplicatedStorage:WaitForChild("Modules")
local ToastKit = require(Modules:WaitForChild("ToastKit"))
local AudioKit = require(Modules:WaitForChild("AudioKit"))
-- The readout chrome -- palette, surfaces and the shared left-hand column.
-- InventoryHud draws its backpack key off the same L table, which is what
-- keeps the two ScreenGuis on one line down the edge of the screen.
local HudKit = require(Modules:WaitForChild("HudKit"))
-- The pass ids, the attribute names and the prices Roblox published at boot.
-- The QUICK SELL key reads all three off here rather than typing any of them:
-- an id typed twice is an id that gets corrected once.
local PassConfig = require(Modules:WaitForChild("PassConfig"))

-- Touch targets: see the module. Substituted for MouseButton1Click/Activated so
-- a tap in the margin around a control that renders under 44px on a phone still
-- reaches the same handler. No-ops on desktop and on controls already big enough.
local TouchFit = require(Modules:WaitForChild("TouchFit"))
--[[
	For PanelKit.compact alone -- the K/M/B/T rounding the panels already use.

	Borrowed rather than reimplemented for the reason its own note gives: two
	copies of a rounding rule is how two screens end up disagreeing about what
	999,999 is called, and this HUD sits on screen beside those panels all the
	time. See the note over setCoins for which figures here take it and which
	deliberately do not.
]]
local PanelKit = require(Modules:WaitForChild("PanelKit"))
--[[
	FOR profileSettled, AND THAT IS THE ONLY THING TAKEN FROM IT.

	The flag means "the server has finished deciding who this player is". It
	lives in TutorialConfig because the tutorial was the first thing that needed
	it; it is not a tutorial concept and three HUDs now wait on it.
]]
local TutorialConfig = require(Modules:WaitForChild("TutorialConfig"))

--[[
	WHAT THE READOUTS SAY BEFORE THE SAVE HAS LANDED.  2026-09-12

	Reported for the THIRD time, and all three from mobile: "is the progress not
	saved? why does it restarted". The player's profile was intact both times we
	checked -- the one that prompted this had MORE banked afterwards than at the
	moment they wrote in -- so nothing was ever lost. What they were reacting to
	was this file.

	The counter was painted at module scope off `GetAttribute("Coins") or 0`, and
	on a phone waiting on a slow DataStore read that `or 0` is several seconds of
	a HUD stating, confidently and in the largest type on the screen, that you
	have nothing. The bag says 0 LBS and the upgrade card offers you Lv.2. To
	somebody with a real save that is not a loading screen, it is a wiped account.

	A DASH IS THE HONEST ANSWER. "$0" is a claim about the player's money and it
	is false; "--" says the game does not know yet, which is exactly true and is
	what every readout here should have said from the start. SaveService already
	gets the hard part right -- a failed load disables saving rather than
	overwriting, "losing a session is recoverable; overwriting a real one is not"
	-- so the data was never at risk. Only the display was lying about it.

	NOT the rake percentage or the hint line: those are about the field you are
	standing on, not about anything that was ever saved, and a dash there would
	be the opposite of informative.
]]
local DASH = "\u{2014}"
local function settled(): boolean
	return TutorialConfig.profileSettled(player)
end
local QUICKSELL = PassConfig.Passes.QuickSell

local INK = Color3.fromRGB(22, 26, 34)
local CREAM = Color3.fromRGB(255, 250, 238)
local GOLD = Color3.fromRGB(255, 200, 62)
local GREEN = Color3.fromRGB(88, 226, 132)
local SKY = Color3.fromRGB(96, 202, 255)
local RED = Color3.fromRGB(255, 104, 96)
-- The wash bay's exact pair. Grape is what a Robux button is in this game --
-- the instant-wash key, every row in the shop -- and the QUICK SELL key wears
-- it for as long as it is something to buy rather than something to press.
local GRAPE = Color3.fromRGB(170, 114, 238)
local GRAPE_DEEP = Color3.fromRGB(94, 46, 166)

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
-- Chrome
--
-- The panel machinery that used to live here is gone: panel(), chip(), and the
-- weather(), grooves(), wetline() and rim() passes that painted sun-bleached
-- driftwood onto every readout. Four texture treatments stacked on three small
-- bars is what made this corner read as busy, and brown boards over bright sand
-- had the least separation of any pairing on the screen. HudKit draws the
-- surfaces now.
--
-- What is left here is the handful of builders the things HudKit does NOT own
-- still need: the gold number, and the superseded upgrade card below it.
----------------------------------------------------------------
-- The warm ink SignKit letters every board with. Still the outline for what
-- belongs to the WORLD -- the hint line, the upgrade card -- where HudKit.C.ink
-- outlines the readout chrome. Two inks on purpose: one for the beach's
-- furniture, one for the glass sitting over it.
local OUTLINE    = Color3.fromRGB(56, 36, 20)
local GOLD_LIGHT = Color3.fromRGB(255, 226, 118)

local function roundOff(parent: Instance)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = parent
	return c
end

-- A UIGradient MULTIPLIES against whatever colour is underneath it, so anything
-- gradient-filled has to sit on white or the two tint each other -- that is what
-- turned the old panels near-black and made a gold bar over a blue fill come out
-- green. Setting the base to white here means the gradient stops are the colour
-- you get.
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

local function iconHolder(parent: Instance, px: number)
	local h = Instance.new("Frame")
	h.Size = UDim2.fromOffset(px, px)
	h.BackgroundTransparency = 1
	h.ZIndex = 3
	h.Parent = parent
	return h
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
--[[
	ABOVE THE THUMBSTICK, AND IT HAS TO BE.

	This was never set, so it defaulted to 0 -- the same DisplayOrder Roblox's
	own TouchGui uses, which is a TIE and not an ordering. The DynamicThumbstick
	claims x -100..266, y 105..416 on a 666x374 phone, and QUICK SELL's tap pad
	sits at x 44..140, y 87..131. Measured with GetGuiObjectsAtPosition, the
	thumbstick came back ABOVE the button: 26 of the pad's 44 pixels -- the
	bottom 59% -- were dead, and a tap there began a movement drag instead of
	pressing the button. On a control that costs Robux.

	1 rather than something larger, because 1 is the number this HUD's own
	column already uses: NextShoreHud and BoostHud both sit at 1 and both say
	they are matching this file. It clears TouchGui and changes nothing else.

	The pills are not Active, so the thumbstick still works through them -- only
	the buttons take a touch, which is the whole point.
]]
gui.DisplayOrder = 1
gui.Parent = player:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- THE LEFT COLUMN
--
-- Coins, load, beach raked -- one stack, one width, one x, and a backpack key
-- under it that InventoryHud owns. Every position comes out of HudKit.L, which
-- is the only place the column is described: the old version was three
-- different widths (274 pills over a 248 card wearing a 274 signboard, its left
-- edge nudged to 29 by hand to make up the difference) precisely because each
-- file did the arithmetic for itself.
--
-- THE 620px LOAD BAR ACROSS THE TOP OF THE SCREEN IS GONE.
--
-- It was the largest object on the HUD and it drew the SAME two numbers as the
-- CARRYING card's track down the left -- CurrentWeight and MaxWeight, off the
-- same two attributes. One of them had to go, and the one anchored to the
-- middle of the screen is the one that was in the way of the game. The weight
-- is the second row of this stack now.
----------------------------------------------------------------
local L = HudKit.L
local A = HudKit.A
local K = HudKit.C
local ROW_W = L.W

----------------------------------------------------------------
-- COINS
----------------------------------------------------------------
local coinPill, coinFace = HudKit.surface(gui, ROW_W, L.COIN_H, L.COIN_H * 0.5)
coinPill.Name = "CoinPill"
coinPill.Position = UDim2.fromOffset(L.X, L.COIN_Y)
HudKit.gloss(coinFace, L.COIN_H * 0.5)

-- ABOVE the gloss cap. The art carries its own rim, bevel and specular, and a
-- sheet of 40% white laid over the top of it flattens all three.
local coinArt = coinIcon(coinFace, L.COIN_H - 14)
coinArt.Position = UDim2.fromOffset(6, 7)
coinArt.ZIndex = 9
for _, d in coinArt:GetDescendants() do
	if d:IsA("GuiObject") then
		d.ZIndex = 9
	end
end

-- Where the number starts: off the coin's own right edge rather than a guessed
-- pixel count, so the gap survives the pill being resized.
local textX = L.COIN_H - 2
-- The gap left at the far end of the pill, matching the 14 the text width was
-- always inset by. It is the one number that sets how snug the number looks.
local COIN_PAD = 14

local coinText, coinShade = bigNumber(coinFace, 30)
coinText.ZIndex = 9
coinText.Size = UDim2.new(1, -(textX + COIN_PAD), 1, 0)
coinText.Position = UDim2.fromOffset(textX, 0)
coinShade.ZIndex = 8
coinShade.Size = coinText.Size
coinShade.Position = UDim2.fromOffset(textX, 3)

--[[
	THE PILL IS AS WIDE AS THE NUMBER NEEDS -- SIZED FOR THE WIDEST NUMBER OF THAT
	MANY DIGITS, NOT FOR THE NUMBER ITSELF.

	It was a fixed ROW_W of 256, which leaves 190px of text width once the coin and
	the padding are taken off, and the number outgrew it. Measured at TextSize 30:
	"$1,028,242,608" is 205px, so it ran 15px past the end -- and a TextLabel does
	not clip to its own Size, so it simply hangs out over the edge of the pill.

	⚠ MEASURING THE LIVE STRING IS THE OBVIOUS FIX AND IT LOOKS WORSE THAN THE BUG.
	LuckiestGuy's digits are NOT TABULAR -- measured, "1" is 12px and "0" is 20 --
	so two numbers of the same length differ by up to 73px ("$111,111,111" is 133,
	"$000,000,000" is 206). The counter rolls digit by digit on every single
	payment, so a pill sized to what it currently reads would BREATHE in and out
	for the length of every roll-up, several times a minute.

	So it is measured with every digit swapped for the widest one. Same digit count
	-> same width, so the pill changes size once per order of magnitude instead of
	once per frame:

		8 digits and under  256  -- the column's own width, so nothing moves
		9 digits            272        11 digits   318
		10 digits           298        12 digits   338

	THE NUMBER STAYS LEFT ALIGNED off the coin, so the leading digit never moves
	and the slack a narrow number leaves (27px, for the one above) falls at the
	right-hand end where nothing is anchored to it. Font and size are read back off
	the label rather than restated, so this cannot drift from what is drawn.
]]
local COIN_MEASURE = Vector2.new(10000, 100)
local coinW = -1

local function setCoins(str: string)
	coinText.Text = str
	coinShade.Text = str
	local widest = (str:gsub("%d", "0"))
	local need = TextService:GetTextSize(widest, coinText.TextSize, coinText.Font,
		COIN_MEASURE).X
	local want = math.max(ROW_W, textX + math.ceil(need) + COIN_PAD)
	-- Only on a change: this runs every frame while the counter is rolling, and
	-- writing the same Size back would dirty the layout for nothing.
	if want ~= coinW then
		coinW = want
		coinPill.Size = UDim2.fromOffset(want, L.COIN_H)
	end
end

----------------------------------------------------------------
-- LOAD
--
-- The bag, as a bar whose fill IS the readout. `bagPanel` and the five handles
-- below keep the names the old top-centre slab had, so refreshBag and the
-- punches further down this file are untouched by the move.
----------------------------------------------------------------
-- bagLevel is the load line, 0..1. HudKit.bar drives the fill and the foam
-- off it, so it is the only handle refreshBag has to move.
local bagPanel, bagFace, barFill, barFoam, bagStroke, bagLevel =
	HudKit.bar(gui, ROW_W, L.LOAD_H, A.seaLight, A.seaDeep)
bagPanel.Name = "LoadPill"
bagPanel.Position = UDim2.fromOffset(L.X, L.LOAD_Y)
local fillGrad = barFill:FindFirstChildOfClass("UIGradient")

local bagGlyph = HudKit.bagGlyph(bagFace, 22)
bagGlyph.Position = UDim2.fromOffset(11, 8)

--[[
	TWO READOUTS SHARING 256 PIXELS, AND THE SPLIT IS MEASURED RATHER THAN EYED.

	The count is left-aligned from x = 40 and the price is right-aligned to
	x = 242, so what matters is that their boxes cannot meet. Measured at
	LuckiestGuy:

	  widest count  "2.7k / 2.7k lbs" 116px at 17 -- see amount() for why a big
	                                  bag is abbreviated. 100 lbs USED to be the
	                                  widest, because WeightConfig.CapacityPerLevel
	                                  topped out there (20, 30, 42, 56, 75, 100).
	                                  Bucket Size runs to 2,745 lbs now, and
	                                  "2,744.5 / 2,745 lbs" measures 148px -- it
	                                  would have clipped for the top quarter of
	                                  the ladder. The vehicle holds are bigger
	                                  still and do NOT show here; they are their
	                                  own prompt.
	  widest price  "$1,234,567"       76px at 16 -- and a full 2,745 lb bag of
	                                  beach litter is worth about $126,000, which
	                                  measures 70. The rebirth multiplier lands
	                                  at the till, not on BagValue, so it does
	                                  not widen this.

	118 and 80 with 4px between the boxes covers both with the count's own 5px
	to spare. At 138/74 -- what this was when the bar came down from 620 to 256 --
	the two boxes overlapped by 10 and a full bag printed its price over its own
	count. Truncation is the backstop, not the plan: it can never fire on the
	strings above, and if a later capacity ladder makes it fire, a clipped number
	is still better than two numbers on top of each other.

	No "LOAD" in front of the count any more, either -- the bag glyph says which
	bar this is, and the word was costing 40 of the pixels this split needs.
]]
local bagTitle = label(bagFace, "0 / 20 lbs", 17, K.barText, Enum.Font.LuckiestGuy)
bagTitle.ZIndex = 10
bagTitle.Size = UDim2.new(1, -138, 1, 0)
bagTitle.Position = UDim2.fromOffset(40, 0)
bagTitle.TextXAlignment = Enum.TextXAlignment.Left
bagTitle.TextTruncate = Enum.TextTruncate.AtEnd
textStroke(bagTitle, 2.5, K.barEdge, K.barEdgeT)

-- What the bag is worth. Small on purpose: it is the number you check before
-- deciding to walk to the pad, not the one you watch while raking.
local bagWorth = label(bagFace, "$0", 16, K.barText, Enum.Font.LuckiestGuy)
bagWorth.ZIndex = 10
bagWorth.AnchorPoint = Vector2.new(1, 0)
bagWorth.Size = UDim2.fromOffset(80, L.LOAD_H)
bagWorth.Position = UDim2.new(1, -14, 0, 0)
bagWorth.TextXAlignment = Enum.TextXAlignment.Right
bagWorth.TextTruncate = Enum.TextTruncate.AtEnd
textStroke(bagWorth, 2.5, K.barEdge, K.barEdgeT)

----------------------------------------------------------------
-- BEACH RAKED
----------------------------------------------------------------
local RAKE_R = L.RAKE_H * 0.5
local progPill, progFace = HudKit.surface(gui, ROW_W, L.RAKE_H, RAKE_R)
progPill.Name = "RakedPill"
progPill.Position = UDim2.fromOffset(L.X, L.RAKE_Y)
-- regrad ONLY -- see HudKit.bar. The base is white so the gradient stops are
-- the colour you get; writing BackgroundColor3 here multiplies the track
-- against itself and the unraked end of the bar comes out near-black.
HudKit.regrad(progFace, K.track, HudKit.darken(K.track, 0.18))
progFace.ClipsDescendants = true
HudKit.gloss(progFace, RAKE_R, math.min(0.85, K.glossAmt + 0.2))

--[[
	THE PILL IS THE BAR -- AND THE BAR IS THE PILL'S OWN SILHOUETTE.

	ClipsDescendants clips to a RECTANGLE. It knows nothing about the UICorner
	that makes this pill a capsule, which is why a fill growing from x = 0 used
	to paint its square corners into the rounded end and back out of it as two
	pale nubs.

	So nothing is clipped into shape. The fill is a frame the EXACT size and
	radius of the pill, and HOW MUCH OF IT YOU CAN SEE is a UIGradient whose
	transparency steps from opaque to clear at the rake line. The silhouette is
	the capsule at 0%, at 100% and everywhere in between, because it is the same
	unchanging frame throughout.
]]
local progFill = Instance.new("Frame")
progFill.Name = "Raked"
progFill.Size = UDim2.fromScale(1, 1)
progFill.BackgroundColor3 = K.rakeFill
progFill.BorderSizePixel = 0
progFill.ZIndex = 7
progFill.Parent = progFace
corner(progFill, RAKE_R)

-- Rotation 0, so the sequence runs left to right across the pill. Its Color is
-- left at the default white, which multiplies to nothing: this gradient carries
-- the fill LINE, not a colour.
local progGrad = Instance.new("UIGradient")
progGrad.Rotation = 0
progGrad.Parent = progFill

-- The bright lip of freshly turned sand at the leading edge.
local progEdge = Instance.new("Frame")
progEdge.Name = "RakeEdge"
progEdge.AnchorPoint = Vector2.new(1, 0.5)
progEdge.Position = UDim2.fromScale(0, 0.5)
progEdge.Size = UDim2.new(0, 4, 0.74, 0)
progEdge.BackgroundColor3 = Color3.fromRGB(255, 253, 240)
progEdge.BackgroundTransparency = 0.22
progEdge.BorderSizePixel = 0
progEdge.ZIndex = 8
progEdge.Visible = false
progEdge.Parent = progFace
roundOff(progEdge)

--[[
	HOW FAR THE LIP MAY TRAVEL.

	The pill's ends are RAKE_R arcs, so at the lip's own top and bottom corners
	the arc has already pulled in by RAKE_R - sqrt(RAKE_R^2 - half^2). Parked
	flush against either end the lip would be that far OUTSIDE the capsule --
	precisely the escape the old fill used to make.

	Clamped at the far end (the cap is the leading edge by then anyway) and
	hidden at the near one, because a bright lip pinned ahead of a 2px sliver of
	sand reads as a bug rather than as a rake.
]]
local EDGE_W, EDGE_H = 4, 0.74
local edgeHalf = L.RAKE_H * EDGE_H * 0.5
local edgePull = RAKE_R - math.sqrt(math.max(0, RAKE_R * RAKE_R - edgeHalf * edgeHalf))
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
progLevel.Parent = progFace
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

local progGlyph = HudKit.rakeGlyph(progFace, 18)
progGlyph.Position = UDim2.fromOffset(12, 6)

-- A SOLID outline, and thicker than the bar above it wants. This label spends
-- most of a session sitting on pale raked sand -- barText on cream -- and it is
-- the outline, not the letter colour, that has to carry it over both that and
-- the empty track behind it.
local progText = label(progFace, "BEACH RAKED  0%", 15, K.barText, Enum.Font.LuckiestGuy)
progText.ZIndex = 10
--[[
	204px of room, and IT SHRINKS TO FIT RATHER THAN TRUNCATING.

	This used to be a fixed 15px with TextTruncate.AtEnd, budgeted against a
	widest measured string of 191 ("SAKURA COVE RAKED  100%"). Two things were
	wrong with that budget and both of them cut off the number, which is the
	only part of the line the player is reading:

	  the worst case is not the percentage. paintProgress switches to
	  "<NAME> RAKED  N LEFT" inside the last 25 columns, and that form is
	  ~14px wider -- so SAKURA COVE (205) and INNER SHRINE (209) were already
	  over the 204 and clipping, in the endgame, on the message that exists
	  specifically to tell you how many columns are left;

	  and the budget is not a constant. Every island's name goes through here,
	  so it moves whenever Config.ISLANDS gains a row. MAGMA CHAMBER is 236 --
	  32px over -- and truncated to "MAGMA CHAMBER RAKED..." with the figure
	  gone entirely.

	TextScaled with a MAX of 15 keeps every name that already fitted rendering
	at exactly the size it always did, and shrinks only the ones that do not.
	The floor of 11 is what the widest string in the file needs today; below
	that the right answer would be a wider pill, not smaller type. Nothing here
	has to be re-measured when the next island lands.
]]
progText.Size = UDim2.new(1, -52, 1, 0)
progText.Position = UDim2.fromOffset(40, 0)
progText.TextXAlignment = Enum.TextXAlignment.Left
-- TextTruncate is ignored while TextScaled is on; left off deliberately so a
-- string that somehow beats the 11px floor is visibly wrong rather than quietly
-- clipped.
progText.TextTruncate = Enum.TextTruncate.AtEnd

--[[
	FITTING IT, and TextScaled is NOT the way to do this -- that was tried.

	TextScaled forces TextWrapped, so a long line does not shrink, it WRAPS:
	"MAGMA CHAMBER RAKED" over "0%", two rows squeezed into a 30px pill while
	every other island still renders as one. Turning TextWrapped back off stops
	the wrap and also stops the scaling -- the label simply renders at the
	maximum and overflows again (measured: 236px in 204 for MAGMA CHAMBER).

	So the size is chosen here instead: the largest of 15..11 whose measured
	width fits, on one line, always. Islands that already fitted stay at 15 and
	look exactly as they did; only the long ones step down, and only as far as
	they must. TextTruncate stays on underneath as the last resort.
]]
local PROG_MAX, PROG_MIN = 15, 11

local function setProgText(text: string)
	progText.Text = text
	local room = progText.AbsoluteSize.X
	if room <= 1 then
		room = 204            -- before the first layout pass
	end
	for size = PROG_MAX, PROG_MIN, -1 do
		progText.TextSize = size
		local w = TextService:GetTextSize(text, size, progText.Font,
			Vector2.new(math.huge, 100)).X
		if w <= room then
			return
		end
	end
end
textStroke(progText, 3, K.barEdge, K.barEdgeT)

----------------------------------------------------------------
-- QUICK SELL
--
-- Sells the whole bag from wherever the player is standing, which is the one
-- thing the green pad cannot do.
--
-- IT SHARES THE BACKPACK KEY'S ROW rather than taking a row of its own. The
-- key is square and the column is 256 wide, so there were 184 pixels of empty
-- sand beside it; L.SELL_X and L.SELL_W are that leftover, derived in HudKit.L
-- off the same numbers the pills above use. Nothing below moves -- the drawer
-- still opens at L.DRAWER_Y -- so this costs the column no height at all.
--
-- IT SENDS THE CTB REMOTE'S OWN "QuickSell" ACTION, not a new remote.
-- CTB_Server routes that word into the SAME local sell() the pad's Touched
-- calls, so the debounce, the crusted refusal, the batch bonus and the receipt
-- are one code path and this button cannot pay differently from walking up.
--
-- IT IS A GAME PASS, so this one key is TWO controls wearing one shape: a
-- storefront until it is bought and a sell button afterwards. That is on
-- purpose -- the thing being sold is a button, and the honest place to
-- advertise a button is where the button will be. paintQuickSell below owns
-- which of the two it currently is; nothing else may decide.
----------------------------------------------------------------
local sellHolder, sellBtn = HudKit.pressable(gui, L.SELL_W, L.KEY, A.sun, 18)
sellHolder.Name = "QuickSellKey"
sellHolder.Position = UDim2.fromOffset(L.SELL_X, L.KEY_Y)

-- Over the gloss cap, for the reason the coin pill's art is: the sheet of white
-- flattens the rim and bevel the art carries. Every descendant, because
-- coinIcon hangs the image inside a holder.
local sellCoin = coinIcon(sellBtn, 30)
sellCoin.Position = UDim2.fromOffset(11, 14)
for _, d in sellCoin:GetDescendants() do
	if d:IsA("GuiObject") then
		d.ZIndex = 9
	end
end
sellCoin.ZIndex = 9
local sellCoinArt = sellCoin:FindFirstChild("Coin")

-- 22, and the size is measured rather than eyed: "QUICK SELL" at LuckiestGuy 22
-- is 111px against the 126 left of the coin, so the label has 15px of slack and
-- can never truncate. At 24 it is 120 and the slack is gone.
local sellText = label(sellBtn, "QUICK SELL", 22, CREAM, Enum.Font.LuckiestGuy)
sellText.ZIndex = 9
sellText.Size = UDim2.new(1, -58, 1, 0)
sellText.Position = UDim2.fromOffset(48, 0)
sellText.TextXAlignment = Enum.TextXAlignment.Left
sellText.TextTruncate = Enum.TextTruncate.AtEnd
textStroke(sellText, 2.5, OUTLINE, 0.1)

-- The price line, and it exists ONLY while the pass is unbought. Owned, the
-- title takes the whole button back and this is hidden: a key that keeps a
-- blank second line reads as a readout that failed to fill in.
local sellPrice = label(sellBtn, "", 15, Color3.fromRGB(240, 230, 255), Enum.Font.GothamBold)
sellPrice.ZIndex = 9
sellPrice.Size = UDim2.new(1, -58, 0, 20)
sellPrice.Position = UDim2.fromOffset(48, 31)
sellPrice.TextXAlignment = Enum.TextXAlignment.Left
sellPrice.Visible = false
textStroke(sellPrice, 2, OUTLINE, 0.2)

--[[
	THREE STATES, AND ONLY ONE OF THEM IS A PURCHASE.

		R$ 99    grape, live   -- opens Roblox's own dialog and nothing else
		SOON     grape, inert  -- the pass is OFF SALE, which NO AMOUNT OF CODE
		                         CAN FIX. A price here would be a figure for
		                         something Roblox will refuse to sell.
		bought   gold when there is something to sell, grey when there is not

	The same three the Robux shop's rows use, in the same colours, so a player
	who has seen one recognises the other.

	OWNERSHIP IS THE CLIENT'S COPY and is only ever good enough to decide what
	this button SAYS. A press still has to get past GamePassService on the
	server, which asks Roblox rather than reading this attribute. Being wrong
	here costs a wrong-looking button and one refused tap -- nothing more.

	BOTH HALVES ARRIVE LATE AND NEITHER CAN BE READ ONCE. Ownership lands when
	GamePassService finishes a web call; the price lands on a folder that does
	not exist during the first second of a session. So this is wired to both
	signals at the bottom of the file rather than run off a snapshot.
]]
local function paintQuickSell()
	local owned = PassConfig.owns(player, QUICKSELL.key)
	sellPrice.Visible = not owned

	if not owned then
		-- Two lines: the name over what it costs. The title steps down to 19 to
		-- make room, which measures 96px against the same 126 the 22 had.
		HudKit.regrad(sellBtn, GRAPE, GRAPE_DEEP)
		sellText.TextSize = 19
		sellText.Size = UDim2.new(1, -58, 0, 24)
		sellText.Position = UDim2.fromOffset(48, 5)
		sellText.TextColor3 = CREAM
		local price = PassConfig.price(QUICKSELL.id)
		sellPrice.Text = (price and PassConfig.onSale(QUICKSELL.id))
			and ("R$ " .. comma(price)) or "SOON"
		if sellCoinArt then
			sellCoinArt.ImageTransparency = 0
		end
		return
	end

	-- Bought. One line again, centred in the whole key.
	sellText.TextSize = 22
	sellText.Size = UDim2.new(1, -58, 1, 0)
	sellText.Position = UDim2.fromOffset(48, 0)

	--[[
		GREY WHEN THE TILL WOULD REFUSE -- and still PRESSABLE.

		BagValue counts CLEANED items only, so worth == 0 covers two different
		situations: an empty bag, and a bag holding nothing but crusted finds.
		Only the server can tell those apart, and it already says which in words
		("Wash the crust off those first!" against "You have nothing to sell.").
		A disabled button would swallow both answers and leave the player
		pressing a dead key wondering which one they were in, so the grey is
		advice rather than a gate.

		The same two greys the upgrade card dims to, for the same reason it does:
		one "not yet" colour across the HUD.
	]]
	local worth = player:GetAttribute("BagValue") or 0
	if worth > 0 then
		HudKit.regrad(sellBtn, A.sunLight, A.sunDeep)
		sellText.TextColor3 = CREAM
		if sellCoinArt then
			sellCoinArt.ImageTransparency = 0
		end
	else
		HudKit.regrad(sellBtn, Color3.fromRGB(96, 102, 116), Color3.fromRGB(42, 46, 58))
		sellText.TextColor3 = Color3.fromRGB(198, 204, 214)
		if sellCoinArt then
			sellCoinArt.ImageTransparency = 0.55
		end
	end
end
paintQuickSell()

----------------------------------------------------------------
-- THE COLUMN ON A PHONE
--
-- One call per piece, in one place, AFTER every Position above has been set --
-- fitColumn captures the offset it is given and rescales it from there, so a
-- piece handed over before it has been placed would be pinned at the origin.
--
-- The backpack key and the drawer are the same column and get the same
-- treatment from InventoryHud; HudKit.COMPACT_COLUMN is the single number all
-- six of them move by, which is what keeps the two ScreenGuis on one line.
----------------------------------------------------------------
HudKit.fitColumn(coinPill)
HudKit.fitColumn(bagPanel)
HudKit.fitColumn(progPill)
HudKit.fitColumn(sellHolder)

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
--
-- IT PUNCHES AROUND THE ELEMENT'S RESTING SCALE, NOT AROUND 1. The coin pill
-- and the load bar are both on the compact column, which parks them below full
-- size on a phone -- and both of them are punched on every payment. Tweening
-- back to a hardcoded 1 would grow them to desktop size on the first coin and
-- leave them there, undoing the compact pass with the HUD's own liveliness.
-- HudKit.restScale is 1 for everything not on that column, so the upgrade
-- button below is unaffected.
local punchTweens = {}
local function punch(obj: GuiObject, amount: number)
	local sc = obj:FindFirstChildOfClass("UIScale")
	if not sc then
		sc = Instance.new("UIScale")
		sc.Parent = obj
	end
	local running = punchTweens[obj]
	if running then running:Cancel() end
	local rest = HudKit.restScale(obj)
	sc.Scale = rest * (1 + amount)
	local t = TweenService:Create(sc, TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = rest })
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

--[[
	"2", not "2.0" -- but 0.5 stays 0.5. comma() floors, which is right for cash
	and wrong for a half-pound coin.

	PRECISION FALLS AWAY AS THE NUMBER GROWS, and that is the fix for a readout
	sized around a 100 lb bag. Bucket Size reaches 2,745 lbs, and the honest
	string for a nearly-full one -- "2,744.5 / 2,745 lbs" -- measures 148px in a
	118px box, so it truncated. Three bands, each measured at LuckiestGuy 17
	against the split documented above:

		under 100    half pounds kept       "99.5 / 100 lbs"    113px
		100 .. 999   whole pounds only      "928 / 928 lbs"     108px
		1,000 up     thousands, one decimal "2.7k / 2.7k lbs"   116px

	Nothing is lost that a player can act on: half a pound out of 928 is below
	the weight of the lightest thing on the beach (a bottle cap, 0.05 lb) times
	ten, and the exact capacity is on the Beach Shop's Bucket Size row anyway.
]]
local function amount(n: number): string
	local magnitude = math.abs(n)
	if magnitude >= 1000 then
		return string.format("%.1fk", n / 1000)
	end
	if magnitude >= 100 then
		return comma(math.floor(n + 0.5))
	end
	local whole = math.floor(n + 0.5)
	if math.abs(n - whole) < 1e-3 then
		return comma(whole)
	end
	return string.format("%.1f", n)
end

local bagTween: Tween?
local function refreshBag()
	local carried, limit, unit = storage()
	local worth = player:GetAttribute("BagValue") or 0
	local full = carried >= limit - 1e-4

	bagTitle.Text = settled()
		and string.format("%s / %s%s", amount(carried), amount(limit), unit)
		or DASH
	-- COMPACT, like the coin counter above it and for the same reason: this is a
	-- readout of what is in the bag right now, not a price anybody is deciding
	-- against. At a x268 multiplier a full bag is eight figures.
	bagWorth.Text = settled() and ("$" .. PanelKit.compact(worth)) or DASH

	-- The key dims with the bag it empties. It reads BagValue itself rather than
	-- taking this function's copy, because ownership can repaint it from three
	-- other signals where no bag figure is to hand.
	paintQuickSell()
	--[[
		Clamped: adoption prices a find AFTER it lands, so the load can sit a
		shade over the limit for the instant before the sifter stops.

		Tweened on bagLevel rather than on the fill's Size, because the fill no
		longer has a width to tween -- it is the whole pill, and the load line
		is a gradient step inside it. Whether there is a wave at all is HudKit's
		call now, not a Visible written from here.

		Cancelled first: a bag filling in quick handfuls used to leave two Size
		tweens fighting over the same frame, and the loser's easing curve won
		whenever it happened to finish last.
	]]
	if bagTween then
		bagTween:Cancel()
	end
	bagTween = TweenService:Create(bagLevel,
		TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Value = math.clamp(carried / limit, 0, 1) })
	bagTween:Play()

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
		bagTitle.TextColor3 = K.barText
		fillGrad.Color = ColorSequence.new(Color3.fromRGB(255, 236, 150), Color3.fromRGB(255, 162, 32))
	else
		bagStroke.Color = OUTLINE
		bagStroke.Thickness = 4
		bagTitle.TextColor3 = K.barText
		fillGrad.Color = ColorSequence.new(Color3.fromRGB(168, 236, 255), Color3.fromRGB(46, 152, 214))
	end
end

local function refreshUpgrade()
	--[[
		THE CARD SAYS NOTHING UNTIL IT KNOWS SOMETHING. See the note over DASH.

		This one is the quietest of the three and the most convincing: unsettled,
		`RollerLevel or 1` offers the player "WIDER SIFTER Lv.2" at the opening
		price. Somebody who left at Lv.31 reads that as the ladder having been
		reset to the bottom -- and unlike the coin counter it stays plausible,
		because a real Lv.1 card looks exactly the same.

		The title keeps its name so the button is still recognisably the upgrade
		key; only the two claims about THIS player -- which rung and what it costs
		-- go to a dash. The coin sprite goes with the price it belonged to.
	]]
	if not settled() then
		upTitle.Text = "WIDER SIFTER"
		upSub.Text = DASH
		upCost.Text = DASH
		upCost.TextColor3 = GOLD_LIGHT
		upCoin.Visible = false
		upCost.Position = UDim2.fromOffset(19, 74)
		return
	end

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
--[[
	THE QUICK SELL PASS, and both halves of its state arrive late.

	Ownership lands on the Player when GamePassService finishes asking Roblox --
	a web call, late by design, and again the instant a purchase completes. The
	PRICE lands on a folder that is published on a thread at boot, so a client
	that joins in the first second has no figure at all and must not be left
	showing SOON for the session.

	WaitForChild with a TIMEOUT rather than an indefinite wait, the same way the
	shop panel does it: if the folder never arrives the key still draws, it just
	draws honestly.
]]
player:GetAttributeChangedSignal(QUICKSELL.attribute):Connect(paintQuickSell)
task.spawn(function()
	local folder = ReplicatedStorage:WaitForChild(PassConfig.InfoFolder, 30)
	if folder then
		folder.AttributeChanged:Connect(paintQuickSell)
		paintQuickSell()
	end
end)
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

--[[
	TRUNCATED, NOT ROUNDED, AND THE LAST FEW COLUMNS ARE COUNTED OUT.

	This line used to round -- math.floor(frac * 100 + 0.5) -- which prints 100%
	from 99.5% up: twenty columns still under crust on the beach, thirty-two on
	Ashfall. That was unreachable while the fields reset at 0.75, because the tide
	fired long before the bar could get there.

	Every field resets at 1.0 now (see ISLANDS[1].resetAt in Config), so 99.5% is
	exactly where a player ends up, and a HUD reading "BEACH RAKED 100%" over a
	beach that will not turn over is the worst thing this bar could say. It reads
	as the tide being broken when the truth is that there are nineteen columns left
	somewhere.

	Truncating fixes the lie; it does not fix the hunt. So inside the last handful
	of columns the bar stops being a percentage -- which has no resolution left --
	and names the actual number outstanding. 25 is about where a percent stops
	moving on the smallest field in the game.

	The FRACTION handed to tweenRaked is untouched and stays the true one: the bar
	is raw count/cells and is not normalised to resetAt, so at 1.0 it now fills
	exactly as the tide fires. At 0.75 it used to vanish with a quarter still
	empty, which is the other half of why the reset read as arriving early.
]]
local function paintProgress(isl)
	local f = fields[isl.id]
	local frac = math.clamp(f.count / isl.cells, 0, 1)
	local left = isl.cells - f.count
	-- A COUNT, NOT A FRACTION -- but the count has to scale with the field or it
	-- stops being the endgame message it exists to be. 25 was one percent of the
	-- 2,304-cell cove and is a tenth of a percent of the 25,600-cell Ashfall,
	-- where "99%" would sit there for four hundred columns and then jump straight
	-- to the banner. One percent, floored at the 25 that was tuned by eye.
	local switchAt = math.max(25, math.ceil(isl.cells / 100))
	if left > 0 and left <= switchAt then
		setProgText(string.format("%s RAKED  %d LEFT", string.upper(isl.name), left))
	else
		setProgText(string.format("%s RAKED  %d%%", string.upper(isl.name), math.floor(frac * 100)))
	end
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
TouchFit.activated(upBtn, function()
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

--[[
	Activated rather than MouseButton1Click: it fires for a touch tap too, and
	touch is most of who a top-left key is for.

	No punch(): HudKit.pressable already drops the face onto its slab on the way
	down, and a UIScale pulse over the top of that reads as two presses.
]]
TouchFit.activated(sellBtn, function()
	AudioKit.play("UIClick", nil, 1, 1.1)

	--[[
		SENT WHETHER OR NOT THIS CLIENT THINKS IT OWNS THE PASS. Changed
		2026-09-09, alongside the identical fix on the wash bay's INSTANT WASH
		button, which is where the bug was actually reported.

		This used to sit under `if not PassConfig.owns(...) then ... return end`.
		CTB_Server's own note beside the refusal already recorded the assumption
		-- "the client normally opens the purchase dialog itself rather than
		sending at all, so reaching this means either a forged message or an
		ownership attribute that has not landed yet" -- and the second half of
		that sentence is the whole problem: THE SELF-HEAL FOR A WRONG ATTRIBUTE
		WAS BEHIND THE ATTRIBUTE.

		CTB_Server rations a `refresh` re-ask for exactly this case (PASS_REASK,
		"a player whose join sweep hit a network blip still gets one re-ask every
		few seconds instead of being refused the pass they paid for until they
		rejoin"). It runs on this message. This message was the one the gate
		refused to send, so the ration protected a door nobody could reach.

		An attribute can be wrong two ways that have nothing to do with forgery:
		UserOwnsGamePassAsync is cached per server and the join sweep warms it
		with "no", and a pass bought from the Roblox app's Store tab never raises
		PromptGamePassPurchaseFinished on this server at all.

		The payload is the word and nothing else -- the bag, its worth and
		whether any of it may be sold are all read server-side -- so there is no
		field here worth tampering with, and no client-side early-out either. An
		empty bag still sends, because the refusal it comes back with is the
		whole point of pressing a grey button.
	]]
	Net:FireServer("QuickSell")

	if PassConfig.owns(player, QUICKSELL.key) then
		return
	end

	--[[
		STRAIGHT TO MARKETPLACESERVICE, not through a remote.

		PromptGamePassPurchase is a CLIENT call -- there is no server-side way
		to open a purchase dialog on somebody's screen -- so a remote here
		would be a hop that changes nothing. It is not a hole either: the
		server hears the result on PromptGamePassPurchaseFinished and then goes
		and ASKS Roblox rather than believing the callback.

		STILL RAISED HERE rather than on the server's say-so, so a genuine buyer
		gets the dialog on the frame they tapped instead of waiting out a web
		call. The two are independent: the send above repairs a wrong record,
		this sells to somebody who really has not bought it, and a stale-false
		owner gets both -- Roblox tells them they already own it while the
		server quietly corrects the attribute behind the dialog.

		OFF SALE IS A TOAST, NOT A DIALOG. Roblox will not sell a pass that is
		off sale, so prompting would open a modal the player cannot complete
		and leave them thinking the purchase failed. Same call the wash bay's
		pass button and the shop's rows make.
	]]
	if not PassConfig.onSale(QUICKSELL.id) then
		showToast(QUICKSELL.name .. " is not on sale yet.", "deny", 2.6)
		return
	end
	MarketplaceService:PromptGamePassPurchase(player, QUICKSELL.id)
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
		-- "SOLD 1 ITEMS" was always possible and is now the COMMON case: a washed
		-- find sells itself the moment it is revealed, one at a time (see
		-- WashServer.sellFinished), so an unconditional plural is a typo on most
		-- sales rather than on the occasional small one.
		showBanner(string.format("SOLD %d ITEM%s   +$%s",
			b, (b == 1) and "" or "S", comma(a)), "money", 2.2)
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
			setProgText(string.format("%s RAKED  0%%", string.upper(isl.name)))
			-- Instant, and it cancels whatever tween was mid-flight: the tide has
			-- already taken the sand back, so watching the bar ease down to nothing
			-- over a third of a second would be describing something that is over.
			tweenRaked(0, true)
		end
		showBanner(string.format("THE %s ROLLED IN!   +$%s BONUS",
			c or isl.resetName or "TIDE", comma(b or 0)), "tide", 3)

	elseif action == "Wipe" then
		--[[
			A REBIRTH TAKING THE SAND BACK -- the same grid clear as a tide, with
			none of the celebration. CTB_Server fires this per island from
			wipeFieldsFor; CTB_Client has always handled it and re-messed its own
			terrain, and this bar never did, so the HUD went on showing progress
			against a field that had just been taken away.

			IT USED TO BE SURVIVABLE AND IS NOT ANY MORE. While the fields turned
			over at 0.75 the stranded number could only ever read up to 75%, which
			looks like progress. Every field resets at 1.0 now, so the bar a rebirth
			strands can read 99% -- or "3 LEFT" -- over a beach that is completely
			untouched, which reads as the tide being broken rather than as a stale
			bar.

			No banner and no audio, deliberately: a rebirth already has its own
			cinematic (RebirthCinema), and a second "+$0 BONUS" style announcement
			over the top of it would be claiming something happened that did not.
			The bar simply tells the truth again.
		]]
		local isl = Config.island(a)
		if isl then
			fields[isl.id] = { set = {}, count = 0 }
			if isl == shownIsland then
				paintProgress(isl)
				-- Instant, for the tide's reason: the sand is already gone.
				tweenRaked(0, true)
			end
		end
	end
end)

----------------------------------------------------------------
-- Coin counter roll-up
----------------------------------------------------------------
RunService.RenderStepped:Connect(function(dt)
	-- The roll-up is the other writer of this label and it has to respect the
	-- dash too, or the first Coins attribute to arrive -- including the 0 a join
	-- hook may stamp before the profile does -- animates the dash away again.
	if not settled() then
		return
	end
	if shownCoins ~= targetCoins then
		local diff = targetCoins - shownCoins
		local stepSize = math.max(1, math.abs(diff) * math.min(dt * 9, 1))
		if math.abs(diff) <= stepSize then
			shownCoins = targetCoins
		else
			shownCoins += (diff > 0 and stepSize or -stepSize)
		end
		-- NO `+ 0.5`. It used to be there to round the animating figure to the
		-- nearest whole coin before compact floored it -- which is the same
		-- round-half-up that made the counter read 15K on a 14,600 balance, just
		-- applied a step earlier. `shownCoins` is a float mid-roll and compact
		-- floors it on the way in, so the counter now only ever understates the
		-- money in flight, and lands exactly on target when the roll finishes.
		setCoins("$" .. PanelKit.compact(shownCoins))
	end
end)

----------------------------------------------------------------
--[[
	THE COIN COUNTER IS COMPACT NOW, AND THE PRICES ARE NOT.

	Asked for on 2026-09-09 -- "I'd like the number displays to be easier to read
	overall" -- by a player holding 1,185,131,541 coins. That is fourteen
	characters in a slot sized for four, ticking every frame while the counter
	animates, and no part of it is information: nobody reads the units digit of a
	billion.

	THE LINE IS PanelKit.compact's OWN, restated here because this is the file
	that has to hold it: comma grouping is right for A PRICE STANDING ON ITS OWN,
	where the player is deciding whether to spend and the exact figure is the
	decision -- and wrong for a running readout. So the counter, the bag's worth
	and the rebirth gauge take compact; the upgrade cost, the R$ prices and every
	reward amount keep their commas.

	IT COSTS NEW PLAYERS NOTHING. compact returns anything under a thousand
	untouched, so a first-timer still sees "$847" to the coin; the shortening only
	starts where the digits stopped meaning anything.
]]
targetCoins = player:GetAttribute("Coins") or 0
shownCoins = targetCoins
setCoins(settled() and ("$" .. PanelKit.compact(targetCoins)) or DASH)
refreshBag()
refreshUpgrade()
refreshHint()

--[[
	AND THE MOMENT THE ANSWER ARRIVES, PAINT IT.

	SNAPPED, not rolled. The roll-up exists so a sale reads as money arriving;
	the profile landing is not a sale, and animating from 0 to a billion would
	take the better part of a minute and look like exactly the thing this whole
	change exists to stop -- a counter climbing back from nothing.

	The bag and the upgrade card are repainted off the same signal rather than
	waiting for their own: both already read the dash out of settled(), so they
	need telling once that the answer changed.
]]
player:GetAttributeChangedSignal(TutorialConfig.ProfileAttribute):Connect(function()
	targetCoins = player:GetAttribute("Coins") or 0
	shownCoins = targetCoins
	setCoins(settled() and ("$" .. PanelKit.compact(targetCoins)) or DASH)
	refreshBag()
	refreshUpgrade()
	refreshHint()
end)

task.delay(1, function()
	showBanner("CLEAN THE BEACH", "tide", 3)
end)