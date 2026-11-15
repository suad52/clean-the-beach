--[[
	IntroClient  --  ReplicatedFirst.IntroClient  (LocalScript)

	The first thing that runs on a client, and the only script in ReplicatedFirst.

	WHY IT EXISTS AT ALL
	--------------------
	Almost nothing in this game is authored into the place. The beach is terrain
	written at runtime, the surface marks are ~650 parts built in a loop, the
	dunes are 46 models, the vault chamber is 620 parts, and every HUD in the game
	is drawn in code. Roblox's default loading screen is long gone by the time any
	of that finishes, so a joining player has been watching their world assemble
	around them -- terrain popping in, litter appearing on sand they are already
	standing on.

	This covers that. It is a loading screen first and a title card second.

	DRAWN, NOT IMPORTED
	-------------------
	The sunset, the sun's path on the water, the clouds and the foam line are
	all frames and rounded rectangles -- there is not one image asset on this
	screen. Same reason as everything else in here: ReplicatedFirst runs before
	content has finished streaming, and a decal that has not arrived yet is a
	grey box on the very first thing a player ever sees.

	SELF-CONTAINED ON PURPOSE
	-------------------------
	ReplicatedFirst runs BEFORE ReplicatedStorage is guaranteed to have
	replicated, so this cannot require Modules.AudioKit, MenuHud's UIKit, or any
	of the game's palettes and helpers -- the whole point is to be on screen
	before those exist. Everything here is plain Instance.new against a local
	copy of the palette. Duplication, and worth it.

	WHAT "READY" MEANS
	------------------
	Not a timer. A timer either cuts early on a slow machine (which is the bug
	this is here to fix) or wastes everyone else's time. It waits on the actual
	conditions -- see READY below -- and the interesting one is the marks check:
	rather than hard-coding "649 parts", it waits for the count to STOP CHANGING,
	so it keeps working when the grid is resized. The field went from 32x32 to
	64x64 during development and a magic number would have silently broken.

	There is still a hard ceiling (BUILD_TIMEOUT). A loading screen that can trap
	a player forever because one condition never comes true is worse than the
	problem it solves.
]]

local ReplicatedFirst = game:GetService("ReplicatedFirst")

-- First line of the script, before anything can yield: the default screen is
-- already up, and removing it later means a visible flash of Roblox branding
-- between it going and ours arriving.
pcall(function()
	ReplicatedFirst:RemoveDefaultLoadingScreen()
end)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local T0 = os.clock()
local BUILD_TIMEOUT = 30      -- absolute ceiling on the loading phase
local FADE_TIME = 0.7

-- The reveal is two beats, not one.
--
-- HOLD is a still frame on the wide shot while the splash fades off it, and it
-- is what stops a longer move from merely feeling slow. Fading straight into
-- motion gives the eye nothing to arrive at; a moment of stillness first makes
-- the move that follows read as deliberate camera work rather than as a slow
-- pan you are waiting out.
--
-- MOVE was 5.0, and simply stretching it made the tail crawl: the old ease-out
-- spent most of its travel in the first second and then inched the rest of the
-- way. The curve below is smoothstep instead, which puts the travel in the
-- middle and still settles gently onto the player -- so the extra seconds are
-- spent moving rather than arriving.
local HOLD_TIME = 0.8
local REVEAL_TIME = 6.0

-- The game's own colours, copied rather than required. See the note above.
--
-- Warmer and a great deal brighter than the set this replaces -- but the set
-- this replaces was never the problem. See the note over `gradient` for why
-- that screen rendered nearly black whatever these numbers said.
local C = {
	skyHigh  = Color3.fromRGB(58, 122, 190),
	skyMid   = Color3.fromRGB(124, 184, 226),
	skyWarm  = Color3.fromRGB(255, 178, 122),
	skyGold  = Color3.fromRGB(255, 226, 152),
	sunCore  = Color3.fromRGB(255, 249, 224),
	sun      = Color3.fromRGB(255, 194, 78),
	sunDeep  = Color3.fromRGB(240, 158, 52),
	sea      = Color3.fromRGB(96, 190, 198),
	seaMid   = Color3.fromRGB(44, 138, 168),
	seaDeep  = Color3.fromRGB(20, 88, 126),
	foam     = Color3.fromRGB(238, 253, 255),
	sand     = Color3.fromRGB(252, 228, 178),
	sandDeep = Color3.fromRGB(228, 194, 138),
	sandWet  = Color3.fromRGB(202, 168, 116),
	cream    = Color3.fromRGB(255, 251, 240),
	ink      = Color3.fromRGB(24, 20, 16),
	-- For the two things that sit ON the art -- the progress track and the tip
	-- pill. A neutral ink over a sunset comes out muddy brown; this is cool
	-- enough to stay a shadow and let the gold on top of it look like gold.
	panel    = Color3.fromRGB(32, 52, 72),
	white    = Color3.new(1, 1, 1),
}

-- The horizon, and the waterline below it. Every band on this screen is placed
-- against these two, so the composition can be re-balanced by moving them
-- rather than by chasing nine hard-coded fractions.
local HORIZON = 0.70
local SHORE = 0.865

-- Fredoka One over Luckiest Guy: rounder, wider apertures, and it holds up at
-- the size a wordmark needs to be. Nunito for everything that is read rather
-- than looked at -- Gotham's caps are handsome and slightly cold, and this
-- screen is trying to look like a holiday.
local FONT_TITLE = Font.fromEnum(Enum.Font.FredokaOne)
local function bodyFont(weight: Enum.FontWeight): Font
	local f = Font.fromEnum(Enum.Font.Nunito)
	f.Weight = weight
	return f
end

--------------------------------------------------------------------------
-- SMALL HELPERS
--------------------------------------------------------------------------

--[[
	A UIGradient MULTIPLIES against the fill underneath it.

	That one fact is why the screen this replaces looked like a power cut. Its
	background was filled with seaDeep (16, 40, 60) and THEN given a gradient
	running through sea (38, 96, 128) -- and 38/255 * 16/255 lands on 2. Every
	colour in that sequence was being multiplied down to near-black, so no
	amount of retuning the sequence could ever have fixed it; it read as a
	palette problem and was a blending one. The sand band did the same thing to
	itself, which is why it came out the muddy tan in the screenshot rather than
	the bright sand it names.

	So anything wearing a gradient is forced white here and the gradient carries
	the whole colour. There is no longer a call site that can forget.
]]
local function gradient(host: GuiObject, rotation: number, colours: ColorSequence,
		transparency: NumberSequence?): UIGradient
	host.BackgroundColor3 = C.white
	local g = Instance.new("UIGradient")
	g.Rotation = rotation
	g.Color = colours
	if transparency then
		g.Transparency = transparency
	end
	g.Parent = host
	return g
end

local function frame(parent: Instance, name: string, z: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = C.white
	f.BorderSizePixel = 0
	f.ZIndex = z
	f.Parent = parent
	return f
end

-- No radius argument means a pill: UICorner clamps to half the shorter side,
-- so UDim.new(1, 0) is a stadium on a bar and a circle on a square.
local function round(inst: GuiObject, radius: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius and UDim.new(0, radius) or UDim.new(1, 0)
	c.Parent = inst
end

--------------------------------------------------------------------------
-- THE SCREEN
--------------------------------------------------------------------------

local pg = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "IntroScreen"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
-- Above everything. ToastKit is 16 and the reveal card is 20; this has to cover
-- a HUD that may well finish building underneath it.
gui.DisplayOrder = 100
-- Sibling, so a subtree's ZIndex is read against its own parent rather than
-- against the whole screen. The scene below is built as bands -- sky, sun,
-- water, shore, card -- and each band's internals then only have to be
-- ordered against each other, not against everything else on the screen.
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = pg

-- `back` is the sky AND the whole splash. Everything except the skip prompt
-- hangs off it, so the reveal at the bottom fades one subtree and the entire
-- screen goes with it.
local back = frame(gui, "Back", 1)
back.Size = UDim2.fromScale(1, 1)
gradient(back, 90, ColorSequence.new({
	ColorSequenceKeypoint.new(0, C.skyHigh),
	ColorSequenceKeypoint.new(0.34, C.skyMid),
	ColorSequenceKeypoint.new(0.58, C.skyWarm),
	ColorSequenceKeypoint.new(HORIZON, C.skyGold),
	ColorSequenceKeypoint.new(1, C.skyGold),
}))

--[[
	THE SUN, sitting exactly on the horizon so the water cuts it in half.

	The glow is eight stacked translucent discs, biggest and faintest first,
	each adding a little more warmth toward the middle -- a radial falloff
	without an image to load. It is deliberately huge: its outer edge reaches
	the title, which is what stops the wordmark sitting on flat colour.

	The anchor is a zero-size frame. Children hung off it are positioned in
	pixels from its centre, so the whole sun moves (and scales, see MOTION) as
	one object by touching one Position.
]]
local sunAnchor = frame(back, "Sun", 2)
sunAnchor.BackgroundTransparency = 1
sunAnchor.AnchorPoint = Vector2.new(0.5, 0.5)
sunAnchor.Position = UDim2.fromScale(0.5, HORIZON)
sunAnchor.Size = UDim2.fromOffset(0, 0)

local SUN_R = 86
--[[
	Fourteen rings, none of them above a tenth opaque.

	The first go used eight thick ones and the glow BANDED -- you could count
	the edges, and the accumulated middle went so milky it bleached the sky
	behind the wordmark. Composited alpha is 1 - product(1 - a), so a lot of
	faint layers reach the same brightness at the centre while stepping down the
	outside in increments too small for the eye to find.

	Largest first: under Sibling ZIndex behaviour these all share a rank, so
	child order is what stacks them, and creating outward-in would bury the sun.
]]
for i = 14, 1, -1 do
	local r = math.round(SUN_R * (1 + i * 0.17))
	local ring = frame(sunAnchor, "Halo" .. i, 1)
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromOffset(r * 2, r * 2)
	ring.BackgroundColor3 = C.sun
	ring.BackgroundTransparency = 0.87 + i * 0.007
	round(ring)
end

local sunDisc = frame(sunAnchor, "Disc", 1)
sunDisc.AnchorPoint = Vector2.new(0.5, 0.5)
sunDisc.Position = UDim2.fromScale(0.5, 0.5)
sunDisc.Size = UDim2.fromOffset(SUN_R * 2, SUN_R * 2)
round(sunDisc)
gradient(sunDisc, 90, ColorSequence.new(C.sunCore, C.sun))

-- Clouds: three puffs each, drifting at their own speed so the sky is never
-- quite the same twice while somebody waits.
local function cloud(y: number, scale: number, alpha: number): Frame
	local c = frame(back, "Cloud", 3)
	c.BackgroundTransparency = 1
	c.AnchorPoint = Vector2.new(0.5, 0.5)
	c.Position = UDim2.fromScale(-0.2, y)
	c.Size = UDim2.fromOffset(0, 0)
	for _, puff in ipairs({ { -62, 8, 52 }, { 0, -8, 76 }, { 58, 10, 48 } }) do
		local b = frame(c, "Puff", 1)
		b.AnchorPoint = Vector2.new(0.5, 0.5)
		b.Position = UDim2.fromOffset(math.round(puff[1] * scale), math.round(puff[2] * scale))
		b.Size = UDim2.fromOffset(math.round(puff[3] * scale), math.round(puff[3] * scale))
		b.BackgroundColor3 = C.cream
		b.BackgroundTransparency = alpha
		round(b)
	end
	return c
end

--[[
	EVERYTHING THAT DRIFTS IS KEPT OUT OF THE BAND THE CARD OCCUPIES,
	roughly 0.17 to 0.55, which leaves clear sky above the wordmark and clear
	sky below the status line.

	Not fussiness. A cloud parked at 0.45 sailed straight through the progress
	bar, and three pale circles sitting on a loading bar do not read as weather
	-- they read as the bar being broken, on the one screen whose entire job is
	to tell a player that nothing is broken.
]]
local clouds = {
	cloud(0.085, 1.15, 0.14),
	cloud(0.135, 0.7, 0.34),
	cloud(0.585, 0.8, 0.26),
}

-- Gulls, and always in a flock. An empty sky reads as a still image, and a
-- still image reads as a frozen client -- which is the exact fear this screen
-- exists to answer. But ONE chevron alone on a clean sky does not read as a
-- bird, it reads as a stray mark on the player's screen; three at different
-- sizes read as birds instantly, and cost the same.
--
-- birds are { x, y, size } in the flock's own space.
local function flock(scale: number, birds: { { number } }): Frame
	local f = frame(back, "Flock", 4)
	f.BackgroundTransparency = 1
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(-0.1, 0.1)
	f.Size = UDim2.fromOffset(0, 0)
	for _, b in ipairs(birds) do
		local bird = frame(f, "Gull", 1)
		bird.BackgroundTransparency = 1
		bird.AnchorPoint = Vector2.new(0.5, 0.5)
		bird.Position = UDim2.fromOffset(math.round(b[1] * scale), math.round(b[2] * scale))
		bird.Size = UDim2.fromOffset(0, 0)
		local s = b[3] * scale
		for _, side in ipairs({ -1, 1 }) do
			local w = frame(bird, "Wing", 1)
			w.AnchorPoint = Vector2.new(0.5, 0.5)
			w.Position = UDim2.fromOffset(math.round(side * 7 * s), 0)
			w.Size = UDim2.fromOffset(math.round(16 * s), math.max(2, math.round(3 * s)))
			w.Rotation = side * 16
			w.BackgroundColor3 = C.ink
			w.BackgroundTransparency = 0.45
			round(w)
		end
	end
	return f
end

-- The low flock crosses the sunset rather than the sky, so it is read against
-- the brightest thing on the screen instead of against pale blue.
local flocks = {
	flock(1, { { 0, 0, 1 }, { -42, 19, 0.78 }, { 34, 25, 0.64 } }),
	flock(0.82, { { 0, 0, 0.9 }, { 31, 17, 0.68 } }),
}

-- A hairline of lit haze along the horizon. Three pixels, and it is the
-- difference between a sea and a blue rectangle abutting an orange one.
local horizonLine = frame(back, "Horizon", 4)
horizonLine.AnchorPoint = Vector2.new(0.5, 0.5)
horizonLine.Position = UDim2.fromScale(0.5, HORIZON)
horizonLine.Size = UDim2.new(1, 0, 0, 3)
horizonLine.BackgroundColor3 = C.sunCore
horizonLine.BackgroundTransparency = 0.5

local sea = frame(back, "Sea", 5)
sea.AnchorPoint = Vector2.new(0.5, 0)
sea.Position = UDim2.fromScale(0.5, HORIZON)
sea.Size = UDim2.fromScale(1, SHORE - HORIZON)
sea.ClipsDescendants = true
gradient(sea, 90, ColorSequence.new({
	-- The top band is lighter than the sea colour proper: water directly under
	-- the horizon is reflecting the lit sky, and without that the sea abuts the
	-- sunset as a flat teal stripe rather than sitting beneath it.
	ColorSequenceKeypoint.new(0, Color3.fromRGB(154, 214, 202)),
	ColorSequenceKeypoint.new(0.28, C.sea),
	ColorSequenceKeypoint.new(0.62, C.seaMid),
	ColorSequenceKeypoint.new(1, C.seaDeep),
}))

--[[
	THE SUN'S PATH ON THE WATER, and it took three goes to get here.

	First it was dashes jittered a few pixels either side of the axis, which
	read as a scribble -- the eye comes looking for the sun's own axis and
	notices it missing. So the jitter went and the dashes tapered cleanly into
	the distance instead, which read as a LADDER: a triangle of evenly spaced
	rungs is a staircase to the eye whatever it happens to be made of.

	The answer was to stop drawing rungs. The reflection is a soft column that
	fades out at its own edges -- no silhouette to mistake for a shape -- with a
	handful of broken highlights over it for texture, at widths and spacings
	irregular enough that they cannot line up into anything.
]]
local sunPath = frame(sea, "SunPath", 1)
sunPath.AnchorPoint = Vector2.new(0.5, 0)
sunPath.Position = UDim2.fromScale(0.5, 0)
sunPath.Size = UDim2.new(0, 340, 1, 0)
gradient(sunPath, 0, ColorSequence.new(C.sunCore), NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.18, 0.82),
	NumberSequenceKeypoint.new(0.5, 0.42),
	NumberSequenceKeypoint.new(0.82, 0.82),
	NumberSequenceKeypoint.new(1, 1),
}))

for _, d in ipairs({ { 0.08, 54 }, { 0.22, 128 }, { 0.34, 72 }, { 0.55, 168 },
		{ 0.72, 104 }, { 0.95, 196 } }) do
	local dash = frame(sea, "Glint", 2)
	dash.AnchorPoint = Vector2.new(0.5, 0.5)
	dash.Position = UDim2.fromScale(0.5, d[1])
	dash.Size = UDim2.fromOffset(d[2], 6)
	dash.BackgroundColor3 = C.sunCore
	dash.BackgroundTransparency = 0.34
	round(dash)
end

-- Water the way a cartoonist draws it: short crests in loose rows, all of them
-- clear of the middle third so nothing crosses the sun's path -- a single long
-- line through the reflection reads as a scratch on the screen. Each row is
-- one frame, so the drift below moves it as a unit.
local swells = {}
for _, row in ipairs({
	{ 0.2, { { 0.11, 96 }, { 0.23, 52 }, { 0.79, 72 }, { 0.91, 40 } } },
	{ 0.44, { { 0.17, 60 }, { 0.29, 104 }, { 0.73, 46 }, { 0.87, 86 } } },
	{ 0.68, { { 0.09, 74 }, { 0.21, 40 }, { 0.81, 98 }, { 0.93, 46 } } },
	{ 0.89, { { 0.15, 102 }, { 0.3, 56 }, { 0.76, 66 }, { 0.89, 44 } } },
}) do
	local holder = frame(sea, "Swell", 2)
	holder.BackgroundTransparency = 1
	holder.Position = UDim2.fromScale(0, row[1])
	holder.Size = UDim2.fromScale(1, 0)
	for _, d in ipairs(row[2]) do
		local crest = frame(holder, "Crest", 1)
		crest.AnchorPoint = Vector2.new(0.5, 0.5)
		crest.Position = UDim2.fromScale(d[1], 0)
		crest.Size = UDim2.fromOffset(d[2], 6)
		crest.BackgroundColor3 = C.foam
		crest.BackgroundTransparency = 0.8
		round(crest)
	end
	table.insert(swells, holder)
end

-- A band of sand across the bottom, so the screen is a beach rather than a
-- gradient. Cheap, and it makes the title feel like it belongs to this game.
local shore = frame(back, "Shore", 6)
shore.AnchorPoint = Vector2.new(0.5, 1)
shore.Position = UDim2.fromScale(0.5, 1)
shore.Size = UDim2.fromScale(1, 1 - SHORE)
gradient(shore, 90, ColorSequence.new({
	ColorSequenceKeypoint.new(0, C.sandWet),
	ColorSequenceKeypoint.new(0.35, C.sand),
	ColorSequenceKeypoint.new(1, C.sandDeep),
}))

--[[
	THE WASH: a straight waterline with a scalloped lower edge, which is the
	difference between a beach and two rectangles stacked on each other.

	NEARLY OPAQUE ON PURPOSE. The first version was a row of stadiums at 0.16
	transparency, and everywhere two of them overlapped the foam blended twice
	and came out brighter -- so what the eye picked out was not a foam line at
	all, it was the overlaps, as a row of bubbles down the beach. Opaque shapes
	union cleanly and translucent ones cannot, and nothing here was worth that.

	The band is what makes the top edge straight: scallops alone scallop BOTH
	edges, and a wavy waterline reads as a mistake rather than as surf.
]]
local FOAM_ALPHA = 0.06
local wash = frame(shore, "Wash", 2)
wash.BackgroundTransparency = 1
wash.AnchorPoint = Vector2.new(0.5, 0)
wash.Position = UDim2.fromScale(0.5, 0)
wash.Size = UDim2.fromScale(1, 0)

local waterline = frame(wash, "Waterline", 1)
waterline.AnchorPoint = Vector2.new(0.5, 0.5)
waterline.Position = UDim2.fromScale(0.5, 0)
waterline.Size = UDim2.new(1, 0, 0, 20)
waterline.BackgroundColor3 = C.foam
waterline.BackgroundTransparency = FOAM_ALPHA

for i = 0, 26 do
	local b = frame(wash, "Scallop", 1)
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.Position = UDim2.new(i / 26, 0, 0, 12)
	b.Size = UDim2.fromOffset(72, 42)
	b.BackgroundColor3 = C.foam
	b.BackgroundTransparency = FOAM_ALPHA
	round(b)
end

-- A handful of ripples on the dry sand. Barely there on purpose, and the
-- difference between sand and a beige rectangle.
for _, r in ipairs({
	{ 0.1, 0.42, 150 }, { 0.28, 0.7, 110 }, { 0.46, 0.34, 90 },
	{ 0.66, 0.6, 170 }, { 0.85, 0.4, 120 }, { 0.94, 0.76, 80 },
}) do
	local rip = frame(shore, "Ripple", 3)
	rip.AnchorPoint = Vector2.new(0.5, 0.5)
	rip.Position = UDim2.fromScale(r[1], r[2])
	rip.Size = UDim2.fromOffset(r[3], 5)
	rip.BackgroundColor3 = C.sandWet
	rip.BackgroundTransparency = 0.72
	round(rip)
end

--[[
	Every label on this screen is ink-outlined, sized by TextScaled inside a box
	measured in SCALE, and capped by a UITextSizeConstraint.

	That is the whole responsive story, and it is a fix rather than a flourish:
	the screen this replaces was laid out in fixed pixels -- a 900px title and a
	420px bar -- which is fine on the monitor it was written on and clips the
	wordmark clean off the sides of a phone. Plenty of players will only ever
	see this game on a 640-wide viewport.
]]
local function label(parent: Instance, text: string, size: UDim2, maxSize: number,
		font: Font, colour: Color3, thickness: number): (TextLabel, UIStroke)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.FontFace = font
	l.Text = text
	l.RichText = true
	l.TextScaled = true
	l.TextColor3 = colour
	l.TextXAlignment = Enum.TextXAlignment.Center
	l.Size = size
	l.ZIndex = 5
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = maxSize
	cap.MinTextSize = 9
	cap.Parent = l
	local st = Instance.new("UIStroke")
	st.Thickness = thickness
	st.Color = C.ink
	st.LineJoinMode = Enum.LineJoinMode.Round
	st.Parent = l
	l.Parent = parent
	return l, st
end

--[[
	FADE THE WHOLE SPLASH, NOT THE PIECES SOMEBODY REMEMBERED.

	Transparency is not inherited in Roblox GUI. A frame at
	BackgroundTransparency 1 still draws every one of its children at full
	opacity, and an ink-outlined label at TextTransparency 1 still draws its
	outline -- on small text the stroke IS most of the glyph, so what is left is
	a hollow black word hanging on screen.

	Both halves of that have already bitten this file once. `local status =
	outlined(...)` took only the first return value, so the status line's stroke
	was never held and never faded, and a black outlined "Ready" sat dead centre
	for the four and a half seconds of camera move between the fade and
	gui:Destroy(). It read as a stray button nobody could dismiss.

	The old fade named four instances by hand. This scene has upwards of eighty,
	so hand-listing them is not a risk so much as a guarantee. Walk the subtree
	and fade whatever each thing happens to have.
]]
local function fadeAll(root: Instance, seconds: number)
	local info = TweenInfo.new(seconds)
	local function one(inst: Instance)
		if inst:IsA("TextLabel") then
			TweenService:Create(inst, info, {
				TextTransparency = 1,
				BackgroundTransparency = 1,
			}):Play()
		elseif inst:IsA("GuiObject") then
			TweenService:Create(inst, info, { BackgroundTransparency = 1 }):Play()
		elseif inst:IsA("UIStroke") then
			TweenService:Create(inst, info, { Transparency = 1 }):Play()
		end
	end
	one(root)
	for _, d in ipairs(root:GetDescendants()) do
		one(d)
	end
end

--------------------------------------------------------------------------
-- THE CARD  --  everything on the screen that is read rather than looked at
--------------------------------------------------------------------------

local card = frame(back, "Card", 20)
card.BackgroundTransparency = 1
card.Size = UDim2.fromScale(1, 1)

-- TITLE. Two labels in one box: the ink one is a shadow sitting nine pixels
-- low, and it is what gives the wordmark weight. An outline on its own reads
-- flat, which was most of what was wrong with the old one.
local titleWrap = frame(card, "Title", 1)
titleWrap.BackgroundTransparency = 1
titleWrap.AnchorPoint = Vector2.new(0.5, 0.5)
titleWrap.Position = UDim2.fromScale(0.5, 0.245)
titleWrap.Size = UDim2.fromScale(0.84, 0.15)

local titleShadow = label(titleWrap, "CLEAN THE BEACH", UDim2.fromScale(1, 1),
	96, FONT_TITLE, C.ink, 10)
titleShadow.Position = UDim2.fromOffset(0, 9)
titleShadow.TextTransparency = 0.55
titleShadow.ZIndex = 1

local title = label(titleWrap, "CLEAN THE BEACH", UDim2.fromScale(1, 1),
	96, FONT_TITLE, C.white, 9)
title.ZIndex = 2

-- White fill on purpose. The gradient multiplies against it (see `gradient`),
-- so any other TextColor3 here would drag the gold off toward mud.
local titleGrad = Instance.new("UIGradient")
titleGrad.Rotation = 90
titleGrad.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, C.white),
	ColorSequenceKeypoint.new(0.55, C.cream),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 202, 110)),
})
titleGrad.Parent = title

local tagline = label(card, "RAKE IT   ·   WASH IT   ·   SELL IT",
	UDim2.fromScale(0.66, 0.034), 22, bodyFont(Enum.FontWeight.Bold), C.cream, 3)
tagline.AnchorPoint = Vector2.new(0.5, 0.5)
tagline.Position = UDim2.fromScale(0.5, 0.355)
tagline.TextTransparency = 0.08

-- Progress is the fraction of READY checks that have actually passed, not a
-- fake timer. It can therefore sit still for a moment, which is honest -- and
-- is the reason the fill carries a sweeping highlight below: the one thing on
-- screen that keeps moving when the number does not.
local row = frame(card, "Progress", 1)
row.BackgroundTransparency = 1
row.AnchorPoint = Vector2.new(0.5, 0.5)
row.Position = UDim2.fromScale(0.5, 0.455)
-- 32 rather than 26, because the number moved INSIDE the bar. At 26 a 22px
-- readout plus its 3px ink stroke came to about 28 and bled over both edges of
-- the thing it is supposed to be sitting in.
row.Size = UDim2.new(0.46, 0, 0, 32)
local rowFit = Instance.new("UISizeConstraint")
rowFit.MinSize = Vector2.new(300, 0)
rowFit.MaxSize = Vector2.new(600, math.huge)
rowFit.Parent = row

--[[
	THE TRACK FILLS THE ROW, so the bar is centred on the card.

	It used to be `UDim2.new(1, -80, 1, 0)` anchored LEFT, holding eighty pixels
	of the row open on the right for the percentage to stand in. The row was
	centred, so everybody assumed the bar was -- but a bar that gives up eighty
	pixels on one side only is sitting forty pixels left of centre, under a title
	and a tagline that are both centred properly. That is the lean.
]]
local barBg = frame(row, "Track", 1)
barBg.AnchorPoint = Vector2.new(0.5, 0.5)
barBg.Position = UDim2.fromScale(0.5, 0.5)
barBg.Size = UDim2.fromScale(1, 1)
barBg.BackgroundColor3 = C.panel
barBg.BackgroundTransparency = 0.3
barBg.ClipsDescendants = true
round(barBg)
local trackStroke = Instance.new("UIStroke")
trackStroke.Thickness = 2
trackStroke.Color = C.cream
trackStroke.Transparency = 0.6
trackStroke.Parent = barBg

local bar = frame(barBg, "Fill", 1)
bar.Size = UDim2.fromScale(0, 1)
bar.ClipsDescendants = true
round(bar)
gradient(bar, 90, ColorSequence.new({
	ColorSequenceKeypoint.new(0, C.sunCore),
	ColorSequenceKeypoint.new(0.5, C.sun),
	ColorSequenceKeypoint.new(1, C.sunDeep),
}))

local shine = frame(bar, "Shine", 2)
shine.Size = UDim2.fromScale(1, 1)
local shineGrad = gradient(shine, 0, ColorSequence.new(C.white), NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.45, 1),
	NumberSequenceKeypoint.new(0.5, 0.72),
	NumberSequenceKeypoint.new(0.55, 1),
	NumberSequenceKeypoint.new(1, 1),
}))

--[[
	THE READOUT SITS IN THE MIDDLE OF THE BAR.

	PARENTED TO THE ROW, NOT TO THE TRACK, and that is not a detail: `barBg` has
	ClipsDescendants true so the fill cannot round-corner out of it, and a label
	parented in there would be cropped to the track's own 32 pixels the moment
	its stroke reached past them. It is centred over the track instead, which
	looks identical and cannot be clipped.

	It reads over BOTH states -- cream on the dark empty track to the right of
	the fill, cream on gold to the left of it -- because of the ink stroke it
	already carried. That stroke was decoration when the number stood on the
	backdrop; now it is what keeps it legible as the fill passes underneath.

	ZIndex 5 from `label` against the track's 1 and the shine's 2, and the gui is
	ZIndexBehavior.Sibling, so the whole readout draws over the whole track.
]]
local pct = label(row, "0%", UDim2.new(0, 120, 1, 0), 20,
	bodyFont(Enum.FontWeight.ExtraBold), C.cream, 3)
pct.AnchorPoint = Vector2.new(0.5, 0.5)
pct.Position = UDim2.fromScale(0.5, 0.5)
pct.TextXAlignment = Enum.TextXAlignment.Center

local status = label(card, "Building the beach", UDim2.fromScale(0.62, 0.042), 24,
	bodyFont(Enum.FontWeight.Bold), C.cream, 3)
status.AnchorPoint = Vector2.new(0.5, 0.5)
status.Position = UDim2.fromScale(0.5, 0.515)
status.TextTransparency = 0.1
local statusScale = Instance.new("UIScale")
statusScale.Parent = status

--[[
	THE TIP LINE.

	A loading screen is the only moment this game has a player's undivided
	attention, so it is worth spending on something other than a spinner.

	Every line here is a rule the game actually enforces -- the bucket really is
	rationed by weight rather than by slot count (ProgressionConfig.BucketSize),
	pet luck really is the only luck in the game and it really is spent at the
	wash bay on what a lump turns out to hold (LuckService, and the note in
	ProgressionConfig about the upgrade track that did neither). A tip that
	turns out to be wrong is worse than no tip: it is the first thing the player
	learns and it teaches them the game lies to them.
]]
local TIP_PREFIX = '<font color="#FFC24E">TIP</font>   '
local TIPS = {
	"Lumps are not litter. Wash one at the bay to see what is inside.",
	"Your bucket fills by WEIGHT, not by count. Gold is heavy.",
	"Pets carry Luck, and Luck decides what a washed lump turns out to hold.",
	"A wider sifter combs more sand per pass. It pays for itself quickly.",
	"The tideline hides better things than the dry sand does.",
	"Turn of the Tide costs you everything and pays you back on every sale.",
	"This is not the only beach. Take the ferry.",
}

local tipPill = frame(card, "Tip", 1)
tipPill.AnchorPoint = Vector2.new(0.5, 0.5)
tipPill.Position = UDim2.fromScale(0.5, 0.925)
tipPill.Size = UDim2.new(0.56, 0, 0, 44)
tipPill.BackgroundColor3 = C.panel
tipPill.BackgroundTransparency = 0.28
round(tipPill, 14)
local pillFit = Instance.new("UISizeConstraint")
pillFit.MinSize = Vector2.new(300, 0)
pillFit.MaxSize = Vector2.new(720, math.huge)
pillFit.Parent = tipPill
local pillStroke = Instance.new("UIStroke")
pillStroke.Thickness = 2
pillStroke.Color = C.cream
pillStroke.Transparency = 0.72
pillStroke.Parent = tipPill

local tipLabel = label(tipPill, TIP_PREFIX .. TIPS[1], UDim2.new(1, -28, 0, 22), 18,
	bodyFont(Enum.FontWeight.Bold), C.cream, 2)
tipLabel.AnchorPoint = Vector2.new(0.5, 0.5)
tipLabel.Position = UDim2.fromScale(0.5, 0.5)
tipLabel.TextTransparency = 0.06

-- NOT a child of `back`, and that is the point: the reveal fades `back` as one
-- subtree, and this prompt has to outlive the splash it was drawn on because
-- the camera move stays skippable for its whole length. It goes with
-- gui:Destroy() at the bottom instead.
local skipHint = label(gui, "", UDim2.new(0, 320, 0, 20), 17,
	bodyFont(Enum.FontWeight.Bold), C.cream, 3)
skipHint.AnchorPoint = Vector2.new(1, 1)
skipHint.Position = UDim2.new(1, -26, 1, -20)
skipHint.TextXAlignment = Enum.TextXAlignment.Right
skipHint.TextTransparency = 0.2
skipHint.ZIndex = 40

--------------------------------------------------------------------------
-- MOTION
--
-- All of it TweenService rather than a RenderStepped loop, because the whole
-- reason this screen is up is that the machine behind it is busy building a
-- beach, and asking it to also run our animation every frame is a poor trade.
--
-- Everything registers in `ambient` so the reveal can cancel the lot in one
-- call. Without that, a tip crossfade caught mid-flight fights the fade-out
-- and the pill comes BACK while the camera is already moving.
--------------------------------------------------------------------------

local alive = true
local ambient: { Tween } = {}

local function ambientTween(inst: Instance, info: TweenInfo, goal: { [string]: any }): Tween
	local tw = TweenService:Create(inst, info, goal)
	table.insert(ambient, tw)
	tw:Play()
	return tw
end

local function stopAmbient()
	alive = false
	for _, tw in ipairs(ambient) do
		tw:Cancel()
	end
	table.clear(ambient)
end

local function forever(seconds: number): TweenInfo
	return TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
end

-- Title: pop in, then breathe. The breathe is delayed rather than played on
-- top, because two tweens on one UIScale fight and the pop loses.
local titleScale = Instance.new("UIScale")
titleScale.Scale = 0.86
titleScale.Parent = titleWrap
ambientTween(titleScale, TweenInfo.new(0.75, Enum.EasingStyle.Back,
	Enum.EasingDirection.Out), { Scale = 1 })
task.delay(0.85, function()
	if alive then
		ambientTween(titleScale, forever(2.6), { Scale = 1.022 })
	end
end)

local sunScale = Instance.new("UIScale")
sunScale.Parent = sunAnchor
ambientTween(sunScale, forever(3.4), { Scale = 1.05 })

for i, line in ipairs(swells) do
	ambientTween(line, forever(4 + i * 0.7),
		{ Position = line.Position + UDim2.fromScale((i % 2 == 0) and -0.025 or 0.025, 0) })
end

shineGrad.Offset = Vector2.new(-1.1, 0)
ambientTween(shineGrad, TweenInfo.new(1.5, Enum.EasingStyle.Linear,
	Enum.EasingDirection.Out, -1, false, 0.6), { Offset = Vector2.new(1.1, 0) })

-- Crossings restart rather than reversing, so nothing ever slides backwards.
-- `startFrac` drops each one in part-way through its first pass; without it
-- the sky is empty for the first thirty seconds, which is the entire time
-- anybody is looking at it.
local function crossSky(inst: Frame, seconds: number, y: number, startFrac: number)
	task.spawn(function()
		local f = startFrac
		while alive do
			inst.Position = UDim2.fromScale(-0.18 + 1.36 * f, y)
			local tw = ambientTween(inst, TweenInfo.new(seconds * (1 - f),
				Enum.EasingStyle.Linear), { Position = UDim2.fromScale(1.18, y) })
			tw.Completed:Wait()
			f = 0
		end
	end)
end

crossSky(clouds[1], 95, 0.085, 0.25)
crossSky(clouds[2], 130, 0.135, 0.7)
crossSky(clouds[3], 78, 0.585, 0.05)
crossSky(flocks[1], 46, 0.115, 0.35)
crossSky(flocks[2], 62, 0.645, 0.8)

-- Status text pops on change rather than swapping silently, so a step that
-- takes eight seconds still shows the player something happened.
local lastStage = ""
local function setStatus(text: string)
	if text == lastStage then
		return
	end
	lastStage = text
	status.Text = text
	statusScale.Scale = 0.92
	TweenService:Create(statusScale, TweenInfo.new(0.3, Enum.EasingStyle.Back,
		Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

-- The percentage follows the BAR rather than the poll, so it inherits the
-- 0.35s smoothing already on the fill instead of jumping in fifths.
task.spawn(function()
	while alive do
		local w = barBg.AbsoluteSize.X
		pct.Text = string.format("%d%%", math.round((w > 0 and bar.AbsoluteSize.X / w or 0) * 100))
		task.wait(0.06)
	end
end)

task.spawn(function()
	local function tipTo(alpha: number, seconds: number): Tween
		local info = TweenInfo.new(seconds)
		for _, d in ipairs(tipLabel:GetChildren()) do
			if d:IsA("UIStroke") then
				ambientTween(d, info, { Transparency = alpha })
			end
		end
		return ambientTween(tipLabel, info, { TextTransparency = alpha })
	end
	local i = 1
	while alive do
		-- Waited in short slices so the reveal never has to sit through the
		-- remainder of a five second hold before the screen can come down.
		for _ = 1, 50 do
			if not alive then
				return
			end
			task.wait(0.1)
		end
		tipTo(1, 0.25).Completed:Wait()
		if not alive then
			return
		end
		i = i % #TIPS + 1
		tipLabel.Text = TIP_PREFIX .. TIPS[i]
		tipTo(0.06, 0.3)
	end
end)

--------------------------------------------------------------------------
-- READY
--------------------------------------------------------------------------

-- The marks folder grows over several frames as CTB_Client lays it out. Waiting
-- for it to STOP growing is grid-size independent; a hard-coded count is not.
local markCount, markStable = -1, 0
local function marksSettled(): boolean
	local f = workspace:FindFirstChild("CTB_Marks")
	if not f then
		return false
	end
	local n = #f:GetChildren()
	if n ~= markCount then
		markCount, markStable = n, os.clock()
		return false
	end
	return n > 0 and (os.clock() - markStable) > 0.6
end

local READY = {
	{ "Reticulating splines", function()
		return game:IsLoaded()
	end },
	{ "Waiting for your character", function()
		local ch = player.Character
		return ch ~= nil and ch:FindFirstChild("HumanoidRootPart") ~= nil
	end },
	{ "Laying out the beach", function()
		return workspace:FindFirstChild("Beach") ~= nil
	end },
	{ "Opening the bay", function()
		-- Either system may be the live one; see ClientMain's note that the wash
		-- and sift halves are switched together.
		return workspace:FindFirstChild("WashBay") ~= nil
			or workspace:FindFirstChild("SiftBay") ~= nil
	end },
	{ "Scattering the litter", marksSettled },
}

local function poll(): (number, string)
	local passed, label = 0, "Almost there"
	local found = false
	for _, check in ipairs(READY) do
		local ok = false
		pcall(function()
			ok = check[2]() == true
		end)
		if ok then
			passed += 1
		elseif not found then
			found, label = true, check[1]
		end
	end
	return passed / #READY, label
end

--------------------------------------------------------------------------
-- LOADING PHASE
--------------------------------------------------------------------------

local deadline = os.clock() + BUILD_TIMEOUT
local timedOut = false

while true do
	local frac, stage = poll()
	TweenService:Create(bar, TweenInfo.new(0.35), { Size = UDim2.fromScale(frac, 1) }):Play()
	setStatus(stage)
	if frac >= 1 then
		break
	end
	if os.clock() > deadline then
		-- Never trap anybody. Whatever did not finish, the game is more usable
		-- than this screen is.
		timedOut = true
		warn(string.format("[Intro] gave up waiting after %ds at %d%% -- stuck on: %s",
			BUILD_TIMEOUT, math.floor(frac * 100), stage))
		break
	end
	task.wait(0.15)
end

print(string.format("[Intro] world ready after %.1fs", os.clock() - T0))
TweenService:Create(bar, TweenInfo.new(0.25), { Size = UDim2.fromScale(1, 1) }):Play()
setStatus(timedOut and "Ready (mostly)" or "Ready")
task.wait(0.35)

--------------------------------------------------------------------------
-- HANDING OVER TO THE OPENING SHOT
--
-- StarterPlayerScripts.IntroCinema plays the actual opening -- the player's
-- own avatar working the tideline, the find in the sand, the title card -- and
-- it cannot start until the world exists, for exactly the reason this screen
-- exists at all. So the two talk through a pair of attributes on the
-- LocalPlayer, which is how every other cross-script signal in this place is
-- passed (CTB_ClockTarget, RollerWidth, CurrentWeight):
--
--   CTB_WorldReady    set here   -- the beach is built, you may start
--   CTB_IntroCovered  set there  -- my black is up, you may take yours down
--
-- The second one is what makes the join seamless. This screen is not torn down
-- on a timer and hoped over; it waits to be told it is behind something
-- opaque, so there is never a frame of half-dressed beach between the two.
--
-- IT IS A WAIT WITH A CEILING, NOT A DEPENDENCY. With IntroCinema removed,
-- disabled or thrown, nothing ever sets CTB_IntroCovered, this falls through
-- in about a second, and the file goes on to do exactly what it always did --
-- its own camera reveal, below. That fallback is the reason the reveal code is
-- still here rather than deleted.
--------------------------------------------------------------------------
player:SetAttribute("CTB_WorldReady", true)

local covered = false
local coverDeadline = os.clock() + 1.5
while os.clock() < coverDeadline do
	if player:GetAttribute("CTB_IntroCovered") == true then
		covered = true
		break
	end
	task.wait(0.05)
end

--------------------------------------------------------------------------
-- REVEAL
--------------------------------------------------------------------------

local skipped = false
local conns = {}

-- Only armed now, which is what "skippable once the world is ready" means: a
-- player who mashes a key during the build does not skip into a half-built
-- beach, which is the exact thing this screen exists to prevent.
local function arm()
	skipHint.Text = UserInputService.TouchEnabled and "tap to skip" or "press any key to skip"
	table.insert(conns, UserInputService.InputBegan:Connect(function(_, processed)
		if not processed then
			skipped = true
		end
	end))
end

local function disarm()
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	conns = {}
end

-- Freeze the character for the length of the move. The camera is scriptable, so
-- without this a player walking on spawn wanders off-screen during their own
-- establishing shot and arrives somewhere they did not choose.
local MOVE_LOCK = "IntroMoveLock"
local function freeze(on: boolean)
	if on then
		ContextActionService:BindActionAtPriority(MOVE_LOCK, function(_, state)
			-- TRYING TO WALK IS A SKIP.
			--
			-- Not a nicety -- without it the skip is broken for the keys people
			-- actually press. Sunk input still reaches UserInputService, but with
			-- gameProcessedEvent set, and the InputBegan handler above (correctly)
			-- ignores processed input. That means WASD and jump -- the first things
			-- an impatient player reaches for -- would be swallowed here and never
			-- reach the skip. Only a stray click or an unrelated key would work,
			-- which is a skip that appears not to work at all.
			if state == Enum.UserInputState.Begin then
				skipped = true
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.ContextActionPriority.High.Value,
			Enum.PlayerActions.CharacterForward, Enum.PlayerActions.CharacterBackward,
			Enum.PlayerActions.CharacterLeft, Enum.PlayerActions.CharacterRight,
			Enum.PlayerActions.CharacterJump)
	else
		ContextActionService:UnbindAction(MOVE_LOCK)
	end
end

-- Where the default camera will be standing when we hand back, so the cut to
-- Custom at the end is invisible rather than a jump.
local function restingPose(hrp: BasePart): CFrame
	local lv = hrp.CFrame.LookVector
	local flat = Vector3.new(lv.X, 0, lv.Z)
	flat = flat.Magnitude > 0.01 and flat.Unit or Vector3.new(0, 0, 1)
	local focus = hrp.Position + Vector3.new(0, 1.5, 0)
	return CFrame.lookAt(focus - flat * 12.5 + Vector3.new(0, 3.2, 0), focus)
end

local function quadratic(a: Vector3, b: Vector3, c: Vector3, t: number): Vector3
	return a:Lerp(b, t):Lerp(b:Lerp(c, t), t)
end

local character = player.Character or player.CharacterAdded:Wait()
local hrp = character:FindFirstChild("HumanoidRootPart")
	 or character:WaitForChild("HumanoidRootPart", 10)

if covered then
	-- The opening shot has the screen and the camera. Get out of its way without
	-- touching either: no reveal, no fade (there is opaque black over this gui
	-- already), and the freeze released because IntroCinema runs its own.
	disarm()
	freeze(false)

elseif hrp then
	freeze(true)
	camera.CameraType = Enum.CameraType.Scriptable

	-- Anchored on the spawn rather than the origin, so the shot still frames the
	-- playable beach if the field is ever recentred.
	local spawnPart = workspace:FindFirstChild("Beach")
	spawnPart = spawnPart and spawnPart:FindFirstChildWhichIsA("SpawnLocation", true)
	local anchor = spawnPart and spawnPart.Position or Vector3.new(0, 6, 0)

	local finish = restingPose(hrp)
	local p0 = anchor + Vector3.new(-105, 92, 118)
	local p1 = anchor + Vector3.new(-38, 40, 62)
	local p2 = finish.Position

	local focus0 = anchor + Vector3.new(0, 4, 0)
	camera.CFrame = CFrame.lookAt(p0, focus0)

	arm()

	-- The splash fades while the camera is already moving, so the first thing a
	-- player sees is a beach in motion rather than a static frame. One call for
	-- the whole scene; skipHint is not in it, and see its note above for why.
	stopAmbient()
	fadeAll(back, FADE_TIME)

	-- Beat one: hold the wide shot while the splash comes off it. Skippable like
	-- the rest -- the world is already built by the time we are here, which is
	-- the only thing skipping was ever gated on.
	local held = 0
	while held < HOLD_TIME and not skipped do
		held += RunService.RenderStepped:Wait()
		camera.CFrame = CFrame.lookAt(p0, focus0)
	end

	-- Beat two: the move.
	local t = 0
	while t < REVEAL_TIME and not skipped do
		local dt = RunService.RenderStepped:Wait()
		t += dt
		local a = math.min(t / REVEAL_TIME, 1)
		-- smoothstep: eases in AND out, so the travel sits in the middle of the
		-- shot rather than being spent in the first second
		local e = a * a * (3 - 2 * a)
		-- re-read the finish every frame; the character can still be settling onto
		-- the spawn under us, and a stale target lands the camera in the sand
		if hrp.Parent then
			finish = restingPose(hrp)
			p2 = finish.Position
		end
		local focus = focus0:Lerp(hrp.Position + Vector3.new(0, 1.5, 0), e)
		camera.CFrame = CFrame.lookAt(quadratic(p0, p1, p2, e), focus)
	end

	if skipped and hrp.Parent then
		-- Snap the rest of the way rather than cutting from wherever it was: the
		-- handover below only looks seamless from the resting pose.
		camera.CFrame = restingPose(hrp)
	end

	disarm()
	freeze(false)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	camera.CameraType = Enum.CameraType.Custom
	if humanoid then
		camera.CameraSubject = humanoid
	end
else
	warn("[Intro] no character to reveal onto -- skipping the camera move")
	disarm()
	freeze(false)
end

-- Idempotent, and needed on the paths that never reached the fade: the drift
-- loops are `while alive` around a task.wait, so without this they spin on
-- destroyed instances for the rest of the session.
stopAmbient()
gui:Destroy()
print(string.format("[Intro] done after %.1fs%s", os.clock() - T0, skipped and " (skipped)" or ""))
