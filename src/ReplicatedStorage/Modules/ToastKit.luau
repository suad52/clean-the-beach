--[[
	ToastKit  --  ReplicatedStorage.Modules.ToastKit

	One cartoon notification system for the whole game.

	Before this there were THREE, none of which knew about the others:
	  * FeedbackClient's Notify toast -- a flat dark rectangle, Gotham 15
	  * CTB_HUD's showToast        -- bare text at 0.34 of the screen
	  * WeightClient's showToast   -- bare text at y 118, deliberately parked
	                                  there to dodge CTB_HUD's
	Three looks, three positions, and a standing risk of two of them landing on
	top of each other. All three now call in here.

	TWO TIERS, because two different jobs were being done by one widget:

	  toast(text, kind)   a stacked pill under the load bar. Things you need to
	                      READ: bag full, need more coins, nothing to sell.
	                      Several can be up at once; they queue downward.

	  banner(text, kind)  one big slab across the middle. Things you should
	                      FEEL: a sale, a level, a rebirth, the tide. Only ever
	                      one at a time -- a new one replaces the old.

	  tip(text, kind)     a wide card at the TOP, on its own clock. Things
	                      nobody asked for: the rotating hint band, and the
	                      "join the group" line. Also only ever one at a time.

	THE TIP IS THE ONLY ONE OF THE THREE THE PLAYER DID NOT CAUSE, and every
	difference between it and the other two comes out of that. A toast answers
	something you just did, so it can be small, brief and unclickable. A tip
	interrupts, so it is the only tier that: sits at the TOP, out of the lower
	third where the other two live and where the player is actually working;
	holds for TEN seconds rather than two, because nobody is expecting to read
	it; and CAN BE DISMISSED, because the answer to an interruption has to be
	available immediately rather than in ten seconds' time.

	The look is lifted from MenuHud's rail buttons, which is the game's existing
	cartoon language: a dark slab offset under a coloured face, a heavy ink
	outline, a gloss strip along the top, LuckiestGuy with a thick text stroke.
	So notifications now look like they belong to the same game as the buttons.

	GLYPHS ARE ASCII OR PRE-UNICODE-6 ON PURPOSE. Roblox's font has no fallback
	for newer emoji -- they render as a narrow box, which looks like a bug rather
	than a missing glyph. ! i * $ and the two arrows below are all safe.
]]

local Players = game:GetService("Players")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")

local AudioKit = require(script.Parent:WaitForChild("AudioKit"))

-- Touch targets: see the module. Substituted for MouseButton1Click/Activated so
-- a tap in the margin around a control that renders under 44px on a phone still
-- reaches the same handler. No-ops on desktop and on controls already big enough.
local TouchFit = require(script.Parent:WaitForChild("TouchFit"))
-- Curves, durations, and the player's ReducedMotion answer. Every exit below
-- shares ONE TweenInfo from it, so the transform and the fade cannot drift
-- apart when that setting collapses the duration.
local Motion = require(script.Parent:WaitForChild("Motion"))

local ToastKit = {}

local INK = Color3.fromRGB(26, 20, 34)
local WHITE = Color3.fromRGB(255, 255, 255)

--------------------------------------------------------------------------
-- WHERE NOTIFICATIONS LIVE, AND HOW BIG THEY ARE
--------------------------------------------------------------------------
--[[
	ONE COLUMN, IN THE LOWER THIRD, MEASURED UP FROM THE BOTTOM EDGE.

	These used to sit across the middle of the screen -- the banner centred at
	0.34 of the height and the stack starting at a hard y = 300 -- which is
	exactly where the player is looking while they rake. Everything is now an
	offset from the BOTTOM, so the column keeps its gap from the HUD on any
	viewport instead of drifting into it on a tall one.

	Bottom-up:

		banner   BAND_BOTTOM up, BANNER_H tall     the big transient slab
		stack    above it, growing UPWARD          up to three readable pills

	The stack grows UP on purpose. Growing down was what put a burst of toasts
	through the hint line; growing up means the overflow goes into empty sky.

	BAND_BOTTOM clears CTB_HUD's hint line: 36px tall, anchored 76px off the
	bottom of a gui that respects the inset the same way this one does, so 76
	plus 12 of air.
]]
local BAND_BOTTOM = 88
local BANNER_H = 64
-- A banner drifts up by this much over its hold so it never looks frozen, which
-- means its slab ends the hold BANNER_DRIFT higher than where it was parked --
-- and the gap above it has to be big enough to absorb that, or the drift walks
-- the slab into the bottom toast. Measured: at a 10px gap it clipped by 8.
local BANNER_DRIFT = 10
local BAND_GAP = BANNER_DRIFT + 12
-- TOAST_H IS A FLOOR, NOT A HEIGHT. A one-line pill is exactly this tall and
-- always was; a wrapped one grows downward off its own measured text. See the
-- sizing note in toast().
local TOAST_H = 40
local TOAST_GAP = 8
local STACK_W = 520

--[[
	THE TYPE METRICS, ALL IN ONE PLACE, because the pill's width, its height and
	the stack's own size are all derived from them and drifted apart when they
	were spelled out at the four sites that needed them.

	TOAST_CHROME is the 76 that was written as a bare number in the old size line
	-- 44 of left pad for the badge, 16 of right pad, and 16 of slack so a
	measured string never lands a glyph against the rounded edge.
]]
local TOAST_PAD_L, TOAST_PAD_R = 44, 16
local TOAST_SLACK = 16
local TOAST_CHROME = TOAST_PAD_L + TOAST_PAD_R + TOAST_SLACK
-- 11 either side of an 18px line is the 40 above, so a one-line pill is
-- unchanged to the pixel by everything below.
local TOAST_PAD_Y = 11
local TOAST_TEXT = 18
local TOAST_TEXT_MIN = 15
local TOAST_MIN_W = 190
-- Three lines is the ceiling, and TOAST_MAX_H is what the stack reserves for it.
local TOAST_LINES = 3
local TOAST_MAX_H = TOAST_TEXT * TOAST_LINES + TOAST_PAD_Y * 2

-- Room for three of the TALLEST pill rather than three of the shortest. Nothing
-- clips either way -- the frame is transparent, has no ClipsDescendants and is
-- anchored by its BOTTOM edge, so the extra height only ever reaches upward into
-- empty sky -- but a container that lies about what it holds is how the next
-- person mis-places something against it.
local STACK_H = TOAST_MAX_H * 3 + TOAST_GAP * 2

--[[
	THE BANNER'S METRICS, AND WHY ITS ANSWER TO A LONG MESSAGE IS THE OPPOSITE OF
	THE TOAST'S.

	The toast grows a second row. The banner may not: BANNER_H is load-bearing --
	placeBand() offsets the whole toast stack by it, BAND_GAP is sized off the
	drift on top of it, and CTB_HUD's hint line sits just under it -- so a slab
	that grew a row would push into one or the other, and both of those are
	numbers somebody measured on screen.

	It is also the right answer for what a banner IS. A toast is something to
	read and can afford a second line; a banner is a short shout you FEEL, and a
	shout that needed two rows was never a banner. So the type steps down instead,
	32 -> 24, and at the floor it wraps rather than spilling -- two lines of 24 is
	48, which still stands inside the slab.

	BANNER_CHROME is the 66 that used to be a bare number: 24 of pad either side
	and 18 of slack.
]]
local BANNER_PAD_X = 24
local BANNER_SLACK = 18
local BANNER_CHROME = BANNER_PAD_X * 2 + BANNER_SLACK
local BANNER_MIN_W, BANNER_MAX_W = 260, 820
local BANNER_TEXT = 32
local BANNER_TEXT_MIN = 24
-- The type's room inside the slab: 8 of air top and bottom.
local BANNER_INNER_H = BANNER_H - 16

--[[
	THE ONE THING THE COLUMN HAS TO GET OUT OF THE WAY OF.

	The wash minigame parks a 560x132 card 24px off the bottom of a gui that
	IGNORES the inset. Ours respects it, and the inset cancels out of the
	difference, so that card's top edge lands 156px above the bottom of our
	space whatever the window size. While it is up the whole column lifts to
	clear it, rather than printing over the thing the player is aiming at.

	THIS TRACKS WashClientController's holder.Position. It was 260 while that
	card sat at -128; the card moved down to -24 because it was covering the
	lump, and this had to come with it or the toast column would float a hundred
	pixels higher than it needs to for the rest of the session.

	AND THE CARD IS NOT THE TOP OF THAT HUD, WHICH IS WHY 156 WAS WRONG.

	A CONTROL ROW HANGS ABOVE THE CARD: `passHolder` at AnchorPoint (0, 1),
	Position (0, -8), Size (170, 46) -- the INSTANT WASH button on the left and
	LEAVE on the right (WashClientController ~876). So the wash HUD's real top
	edge is 24 + 132 + 8 + 46 = 210, not 156, and at 156 the band's bottom sat at
	168 with a 64-tall banner on top of it: 168..232 straight across a button
	that lives at 164..210. FORTY-TWO OF ITS FORTY-SIX PIXELS WERE UNDER THE
	SLAB, at every window size, because both numbers are pre-scale.

	That is not a cosmetic overlap. Every sale fires a banner ("SOLD 1 ITEM
	+$4,320") on the same beat the auto-advance mounts the next lump, so a
	player clearing a bag had the button they paid Robux for hidden for 2.2s of
	every lump -- and a player who reported "I purchased instant wash and it's
	not working" is exactly who that happens to. The tide and event banners are
	on world timers and land whatever the player is doing, and a wash session
	pins them in place, so there is no getting out of the way either.

	MEASURE THE ROW, NOT THE CARD. If either number moves again, this is
	24 + CARD_H + 8 + passHolder height.
]]
local WASH_CARD_REACH = 210
local WASH_BAND_BOTTOM = WASH_CARD_REACH + 12

--[[
	AND THE SECOND THING, WHICH NEEDS MEASURING WHERE THE WASH CARD DID NOT.
	(2026-09-09 -- closes "toasts are drawn over open menus and land on their
	buttons".)

	The wash card is ONE card at ONE fixed reach, so a constant answers it. A menu
	panel is nine different cards -- PanelKit builds them between 300 and 640 tall
	-- and every one of them is parked in the MIDDLE of the screen, which is
	exactly where this column was. Measured at 1269x662 with Turn of the Tide up:
	the stack's bottom edge sat at 444 and the panel's primary button at 401..458,
	so 43 of its 57 pixels were under a pill. Buying an upgrade FIRES a toast, so
	the Beach Shop's rows were covering the button that had just been pressed.

	WHY NOT DISPLAYORDER. This gui is 16 and every panel is 12, so sliding under
	them is one line -- and it trades a toast in the way for a toast nobody ever
	sees. A toast is usually the ANSWER to what the player just pressed ("not
	enough coins", "bag full"), so hiding it is the worse of the two bugs.

	THE ARITHMETIC IS ONE SUBTRACTION, because both cards sit in the same band.
	PanelKit's fitToSafeArea centres a panel in the screen MINUS the top bar, and
	this gui respects the inset, so its space IS that band: the room under an open
	card is (our height - the card's) / 2 and nothing else. It is taken in real
	pixels and divided back through UiFit's scale, because everything placeBand
	writes is a pre-scale offset -- the same trap the wash note ends on.

	IT CLAMPS AT BOTH ENDS AND BOTH ENDS MEAN SOMETHING.

	  BAND_BOTTOM at the top: this only ever moves the column DOWN, out of the
	  way. On a window with room to spare the resting place already clears the
	  card, and a column that crept upward to hug every panel would be movement
	  for its own sake.

	  MENU_BAND_MIN at the bottom: THE TALLEST CARDS CANNOT BE CLEARED AT ALL. The
	  Beach Shop is 730x640 and on a 16:9 window that leaves under 20px of screen
	  beneath it -- nothing fits a 64px banner, its air and a 40px pill into that.
	  So the column goes as low as it can and takes what is left of the overlap on
	  the card's bottom rim rather than across its middle. A panel that nearly
	  fills the screen wants its own in-panel receipt, and that is MenuHud's to
	  give, not ours.

	MENU_BAND_MIN is 12 rather than 0 because the banner's slab hangs 6px below
	its holder with a 4px stroke on it, and a shadow clipped off by the screen
	edge reads as a drawing error rather than as a shadow.
]]
local MENU_GUI = "BeachMenuHud"
-- What the column occupies above its own bottom edge: the banner, the air over
-- it, and one pill. Clearing a card means getting ALL of that under it.
local COLUMN_REACH = BANNER_H + BAND_GAP + TOAST_H
local MENU_BAND_MIN = 12

--------------------------------------------------------------------------
-- THE TIP CARD, AT THE OTHER END OF THE SCREEN
--------------------------------------------------------------------------
--[[
	TOP-ANCHORED, AND MEASURED DOWN FROM THE TOP EDGE -- the mirror of the band
	above, and for the mirror of its reason. The stack and the banner keep out of
	the middle because that is where a player looks while they rake; the tip keeps
	out of the LOWER THIRD entirely because that is where the stack and the banner
	are, and a hint that arrives during a sale must not land on the receipt.

	The gui respects the inset, so y = 0 is already under Roblox's own top bar and
	TIP_TOP is clear air below it.

	THE ONE THING DOWN THERE TO KEEP CLEAR OF: DuelClient parks its incoming-
	challenge card at (0.5, 0, 0, 134), top-anchored, same as this. MEASURED, not
	derived: a two-line tip at the sizes above is 60 tall, so at TIP_TOP = 56 it
	bottoms out at 116 and the two miss each other by eighteen. Move either number
	and check the other -- by measuring it, which is the whole lesson of the note
	below.
]]
--[[
	56, NOT 16, AND THE THING ABOVE IT IS WHY.

	EventHud's countdown now sits at the very top centre, y 3..37 -- a PERMANENT
	readout, where this is a card that is up for ten seconds. The ordering rule
	that follows is worth stating: the permanent readout is on top and the
	transient cards queue beneath it. A countdown that is always there should not
	be the thing that gets covered.

	NINETEEN PIXELS OF AIR, NOT FIVE. The first pass tucked the card as close under
	the pill as the arithmetic allowed, and two rounded cards five pixels apart do
	not read as two things -- they read as one badly-drawn thing. The gap has to be
	big enough to say they are unrelated, because they are.

	AND THE NOTE BELOW WAS CHECKED, WHICH IS WHAT IT ASKS FOR -- and checking it
	by MEASUREMENT rather than by re-reading it turned up a small standing bug.
	The old note put a two-line tip at 76px tall and had it bottoming out at 92,
	four pixels clear of DuelClient's card at 96. A real two-line tip measures 87,
	so it actually bottomed out at 103 and overlapped that card by seven. Nobody
	saw it because a hint and a duel invite rarely arrive together.

	So the duel card went to 134 rather than to the 122 that would merely have
	preserved the old spacing. The card has since been made smaller as well, which
	turned that hard-won five pixels into eighteen -- the duel card was left where
	it is, because slack in this direction costs nothing and moving it a third
	time would only invite a fourth.

	There are three numbers in this chain now, not two: EventHud's pill height,
	TIP_TOP, and DuelClient's 134. Move any of them and MEASURE the other two.
]]
local TIP_TOP = 56
--[[
	SMALLER THAN IT WAS, ON PURPOSE AND ALL OF A PIECE.

	The card was drawn when it had the whole top of the screen to itself. It does
	not any more -- the event countdown sits above it now -- and at 620 wide with
	17px type it read as the main thing on screen rather than as an aside nobody
	asked for, which is exactly what a tip is.

	EVERY NUMBER CAME DOWN TOGETHER. Shrinking the type alone would have left a
	small sentence rattling around inside the same chrome: the chip, the dismiss
	key, both pads and the minimum height are all part of how big the card READS,
	so they move as a set or the proportions go wrong.

	520/14 rather than 620/17. The message still gets 402px of line at full width,
	which is a comfortable sixty-odd characters before it wraps.
]]
local TIP_MAX_W = 520
local TIP_MIN_W = 280
local TIP_PAD_X = 12
local TIP_PAD_Y = 11
local TIP_CHIP_W = 44
local TIP_CHIP_H = 22
local TIP_GAP = 12
local TIP_CLOSE = 26
local TIP_TEXT = 14
local TIP_MIN_H = 46
-- The countdown hairline along the bottom, and the room the card has to set
-- aside for it. THE CARD'S HEIGHT MUST INCLUDE THIS. Sizing the card to the
-- text alone and then hanging the bar off the bottom edge is what the first
-- version did, and it left exactly 3px between the last line of a two-line tip
-- and the bar -- measured on screen, not guessed.
local TIP_BAR_H = 4
local TIP_BAR_GAP = 6
local TIP_BAR_ROOM = TIP_BAR_H + TIP_BAR_GAP
-- Everything across the card that is NOT the message: both pads, the TIP chip,
-- the gap either side of the message, and the dismiss key. The message gets what
-- is left over, and the card is then sized off what the message needs -- so this
-- constant is what keeps the two in step when any of them moves.
local TIP_CHROME = TIP_PAD_X * 2 + TIP_CHIP_W + TIP_GAP * 2 + TIP_CLOSE
-- The holder is a fixed, transparent, INERT band -- it is never the thing on
-- screen, it is only the space the card is allowed to occupy. Tall enough for a
-- two-line card. It must stay non-Active or it would eat clicks across the top
-- of the screen for the whole session, tip or no tip.
local TIP_BAND_H = 112

-- tint, badge glyph, and the pitch its pop plays at
local KINDS = {
	info   = { tint = Color3.fromRGB(96, 202, 255), glyph = "i", pitch = 1.15 },
	warn   = { tint = Color3.fromRGB(255, 186, 48), glyph = "!", pitch = 0.85, shake = true },
	pickup = { tint = Color3.fromRGB(124, 226, 104), glyph = "*", pitch = 1.35 },
	money  = { tint = Color3.fromRGB(255, 200, 62), glyph = "$", pitch = 1.25 },
	level  = { tint = Color3.fromRGB(186, 128, 255), glyph = "\u{25B2}", pitch = 1.45 },
	tide   = { tint = Color3.fromRGB(94, 226, 196), glyph = "\u{2248}", pitch = 1.0 },
	-- X, not another !, so a refusal is distinguishable from a caution at a glance
	deny   = { tint = Color3.fromRGB(255, 104, 96), glyph = "X", pitch = 0.7, shake = true },
}

--[[
	PUBLISHED, so nothing else has to keep a second copy of these colours.

	EventHud draws its pill in the same tint as the banner the event announces
	itself with, and a hand-copied palette over there would be one edit away from
	the two disagreeing about what "money" looks like. A kind is this game's whole
	vocabulary for "what sort of news is this" -- colour, badge glyph and pitch --
	and a caller that already speaks it should be able to read it.
]]
ToastKit.KINDS = KINDS

--[[
	Measured, not auto-sized. AutomaticSize grows a frame to contain its children,
	and the sparkle bits ARE children -- so an auto-sized pill inflated itself to
	~550px around a 120px word as the confetti flew outward. Sizing off the text is
	deterministic, needs no frame to settle, and leaves the sparks free to fly
	outside the pill, which is the whole point of them.

	This returns the whole Vector2 rather than just a width, and takes the room it
	is allowed to wrap in. The old width-only version is why long messages ran out
	of their pills: a caller that can only ask "how wide on one line?" has no way
	to find out how TALL the answer would be once it stopped fitting.
]]
local function textBounds(text: string, size: number, room: number): Vector2
	local ok, b = pcall(function()
		return TextService:GetTextSize(text, size, Enum.Font.LuckiestGuy, Vector2.new(room, 10000))
	end)
	if ok and b then
		return b
	end
	-- Guess GENEROUSLY when the measurement fails, the same way the tip card's
	-- does: it should cost a pill with too much air in it, never one with the last
	-- word of the message hanging outside.
	local flat = #text * size * 0.55
	local rows = math.max(1, math.ceil(flat / math.max(room, 1)))
	return Vector2.new(math.min(flat, room), rows * size)
end

-- A notification is a small wooden tick, not a synth ping. The pitch per kind
-- (below, in KINDS) is what tells a level-up from a refusal without looking,
-- and a tick with real grain in it takes that spread far better than the old
-- electronic blip did -- wood blocks genuinely sound like that across an
-- octave, where a sine ping just sounds high.
local TICK = "WoodTick"
local THUD = "Mount"

local function darken(c: Color3, f: number): Color3
	return c:Lerp(Color3.new(0, 0, 0), f)
end

local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
	return c
end

local function outline(inst: Instance, thick: number, colour: Color3?)
	local s = Instance.new("UIStroke")
	s.Thickness = thick
	s.Color = colour or INK
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = inst
	return s
end

-- A UIGradient MULTIPLIES against the fill underneath, so anything gradient-lit
-- has to sit on white or the two tint each other into mud.
local function gradient(inst: GuiObject, top: Color3, bottom: Color3)
	inst.BackgroundColor3 = WHITE
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(top, bottom)
	g.Rotation = 90
	g.Parent = inst
	return g
end

local function textStroke(label: TextLabel, thick: number)
	local s = Instance.new("UIStroke")
	s.Thickness = thick
	s.Color = INK
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = label
	return s
end

local function scaleOf(obj: GuiObject): UIScale
	local s = obj:FindFirstChildOfClass("UIScale")
	if not s then
		s = Instance.new("UIScale")
		s.Parent = obj
	end
	return s
end

--------------------------------------------------------------------------
-- SOUND
--------------------------------------------------------------------------
-- The local `blip` helper that used to sit here is gone. It hand-built a Sound
-- straight onto SoundService, which meant it had its own copy of the Set_SFX
-- check and none of the shaping. AudioKit does both now -- including the mute
-- gate, so the toggle keeps working -- and toasts pass nil for the parent,
-- which routes them flat and non-positional: a notification should sit against
-- the ear rather than somewhere in the world.

--------------------------------------------------------------------------
-- SPARKS  --  the confetti that sells the whole thing
--------------------------------------------------------------------------

-- Little rotated squares thrown out from a point and spun as they go. Frames
-- rather than a ParticleEmitter because ParticleEmitters do not exist in GUI
-- space, and a handful of tweened frames is cheap enough to do per toast.
local function sparkle(parent: GuiObject, count: number, tint: Color3, spread: number)
	for i = 1, count do
		local a = (i / count) * math.pi * 2 + math.random() * 0.6
		-- Scaled down with the pills they burst off. At the old 7..13 the confetti
		-- read as bigger than the badge on a 40px toast.
		local size = math.random(5, 9)
		local bit = Instance.new("Frame")
		bit.AnchorPoint = Vector2.new(0.5, 0.5)
		bit.Position = UDim2.fromScale(0.5, 0.5)
		bit.Size = UDim2.fromOffset(size, size)
		bit.BackgroundColor3 = (i % 3 == 0) and WHITE or tint
		bit.BorderSizePixel = 0
		bit.Rotation = math.random(0, 90)
		bit.ZIndex = 40
		bit.Parent = parent
		corner(bit, math.random(2, 3))
		outline(bit, 1.5)

		local dist = spread * (0.55 + math.random() * 0.65)
		local target = UDim2.new(0.5, math.cos(a) * dist, 0.5, math.sin(a) * dist * 0.7)
		local ti = TweenInfo.new(0.52, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
		TweenService:Create(bit, ti, {
			Position = target,
			Rotation = bit.Rotation + math.random(140, 320),
			Size = UDim2.fromOffset(1, 1),
			BackgroundTransparency = 1,
		}):Play()
		Debris:AddItem(bit, 0.75)
	end
end

--------------------------------------------------------------------------
-- THE GUI
--------------------------------------------------------------------------

local gui, stack, bannerHolder, tipHolder

--------------------------------------------------------------------------
-- PLACING THE COLUMN
--------------------------------------------------------------------------

local function washCardUp(): boolean
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChild("PlayerGui")
	local wash = pg and pg:FindFirstChild("WashHud")
	return wash ~= nil and wash:IsA("ScreenGui") and wash.Enabled
end

--[[
	THE TOPMOST OPEN PANEL'S CARD INSIDE ONE ScreenGui, or nil when nothing in it
	is open. Called with the menu (see MENU_GUI above) by openMenuCard, and with
	each stand-alone modal by screenBusy.

	TWO DEPTHS AND NO MORE. A panel is a top-level child of the menu gui until
	UiFitBoot runs and a grandchild under its FitRoot afterwards, and it is never
	anywhere else -- so this looks at exactly those two levels rather than walking
	a gui that holds thousands of instances, on every notification.

	`Card` IS THE HANDLE, and it is the right one for a reason beyond being the
	only name that identifies a PanelKit shell: popIn animates the ROOT's Size for
	0.3s, so the root's edges are still moving when Visible fires, where the card
	inside it is authored in pure offsets and measures the same all the way
	through. The Index's detail sheet answers to this too, which is correct -- it
	is a modal over the middle of the screen like any other.

	THE TALLEST WINS, because the Index shows that sheet with its own panel still
	lit behind it, and the column has to clear whichever of the two reaches lower.
]]
local function topCard(menu: Instance?): GuiObject?
	--[[
		A DISABLED SCREENGUI OCCLUDES NOTHING, AND ITS PANELS DO NOT CLOSE WHEN IT
		GOES DARK. (2026-09-09 -- the same fix as the note above, finishing it.)

		Four cinemas hide this HUD by name with Enabled = false and put it back
		afterwards -- RebirthCinema, FerryClient, IntroCinema, EggClient -- and not
		one of them touches the panel roots inside it, which stay Visible the whole
		time. Without this test the tallest of them still answers here and the
		column sits parked at MENU_BAND_MIN, 76px out of place, clearing a card
		that is not on the screen at all.

		RebirthCinema is where it shows. It deliberately leaves ToastKit lit so the
		server's "the tide turns" line can be read over the ascension, and the
		REBIRTH button does not close the panel it was pressed on -- so the one
		toast that whole exception exists for is exactly the one that would have
		been drawn in the wrong place.
	]]
	if not (menu and menu:IsA("ScreenGui") and menu.Enabled) then
		return nil
	end
	local tallest = nil
	local function look(inst: Instance)
		if inst:IsA("GuiObject") and inst.Visible then
			local card = inst:FindFirstChild("Card")
			if card and card:IsA("GuiObject") then
				if not tallest or card.AbsoluteSize.Y > tallest.AbsoluteSize.Y then
					tallest = card
				end
			end
		end
	end
	for _, a in ipairs(menu:GetChildren()) do
		look(a)
		for _, b in ipairs(a:GetChildren()) do
			look(b)
		end
	end
	return tallest
end

-- The menu is the caller this was written for and the only one placeBand asks
-- about. screenBusy runs the same walk over the two stand-alone modals, which
-- are PanelKit shells in their own ScreenGuis and so answer it identically.
local function openMenuCard(): GuiObject?
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChild("PlayerGui")
	return topCard(pg and pg:FindFirstChild(MENU_GUI))
end

--[[
	IS SOMETHING ALREADY IN FRONT OF THE PLAYER? (2026-09-11)

	Everything above this line exists so the toast column can MOVE out of an open
	card's way. A tip cannot move -- its band is anchored top-centre, it only ever
	holds one card, and placeBand does not touch tipHolder -- so for tips the same
	question has to be answered the other way round: not "where do I go" but
	"should I draw at all".

	The probes are the two the column already trusts, plus the stand-alone modals
	-- centred PanelKit cards over a scrim of their own, which ARE the screen for
	as long as they are up.

	NOT `gui.Enabled`, AND THIS IS THE WHOLE TRAP. Measured in Play on 2026-09-11:
	FreeRewardGui reports Enabled = true from the moment it is built and stays
	that way for the rest of the session, because close() drops the panel ROOT's
	Visible and fades the scrim rather than putting the gui out. A screenBusy
	built on Enabled answered true for every player forever and would have
	silenced the band completely -- the opposite failure, and a silent one.
	topCard is the correct question and it was already written: it asks whether a
	PanelKit shell is actually Visible, which is exactly what "a card is up" means.

	RevealPopup is deliberately NOT in the list. It is the answer to a hatch the
	player just paid for, it retires by itself in a couple of seconds, and a tip
	that lands after it has interrupted nothing. The rule being enforced is about
	UNPROMPTED things colliding, not about staying quiet forever.

	Asked once per tip slot, so it costs three two-deep walks over guis holding a
	handful of children each -- the same work placeBand already does on every
	single notification.
]]
local MODAL_GUIS = { "FreeRewardGui", "RebirthUnlockPrompt" }

function ToastKit.screenBusy(): boolean
	if washCardUp() then
		return true
	end
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChild("PlayerGui")
	if pg then
		for _, name in ipairs(MODAL_GUIS) do
			if topCard(pg:FindFirstChild(name)) then
				return true
			end
		end
	end
	return openMenuCard() ~= nil
end

-- How far off the bottom of our own space the column has to sit to keep clear of
-- the open panel, or nil when there is none. The scale is read off the FitRoot's
-- own UIScale rather than asked of UiFit: it is the same number, it is already
-- the thing multiplying every offset written below it, and it answers 1 by
-- itself on a client where the fit never ran.
local function menuBandBottom(): number?
	if not gui then
		return nil
	end
	local card = openMenuCard()
	if not card then
		return nil
	end
	local host = stack and stack.Parent
	local fit = host and host:FindFirstChildOfClass("UIScale")
	local s = (fit and fit.Scale > 0) and fit.Scale or 1
	-- THE FITROOT, NOT THE SCREENGUI, because the FitRoot is sized 1/scale and
	-- then scaled back by that same UIScale, so it measures our space exactly as
	-- rendered -- inset and all -- and leaves nothing to assume about how a
	-- ScreenGui reports its own. The gui answers for the frames before the fit has
	-- wrapped us.
	local band = (host and host:IsA("GuiObject")) and host.AbsoluteSize.Y or gui.AbsoluteSize.Y
	if band <= 0 then
		return nil
	end
	local room = (band - card.AbsoluteSize.Y) * 0.5 / s
	return math.clamp(room - COLUMN_REACH, MENU_BAND_MIN, BAND_BOTTOM)
end

local bandAt = nil
-- Remembered alongside `bandAt` so the no-change guard below sees BOTH halves:
-- the band and the stack move independently while a menu card is up.
local stackAt_ = nil
-- Tweened rather than snapped: the wash card fades in, and a notification
-- column that teleported 184px the instant it appeared read as a glitch.
local function placeBand(instant: boolean?)
	if not (stack and stack.Parent and bannerHolder and bannerHolder.Parent) then
		return
	end
	--[[
		THE WASH CARD STILL WINS, AND THE ORDER IS THE POINT. (2026-09-09) It is
		only up during a wash, it carries a button somebody paid Robux for, and the
		lift that clears it is the one figure in here that was measured against a
		real screen -- so a menu opened mid-wash leaves that behaviour exactly as it
		was rather than dropping the column back down through it.
	]]
	local bottom = BAND_BOTTOM
	--[[
		AND THE COLUMN STOPS RESERVING ROOM FOR A BANNER THAT IS NOT THERE.
		(Second pass, 2026-09-09, off a live measurement.)

		The stack normally hangs BANNER_H + BAND_GAP above the band, because the
		banner slab sits between them. Those 86 authored pixels are the whole
		problem when a panel is open: the gutter under a centred card is about 134
		authored pixels on a 662-tall window, two toasts need 88, and the pair fits
		comfortably -- but add the empty banner's reservation and the column is
		shoved 79 real pixels back up into the card. Measured exactly that with the
		Turn of the Tide panel open: the lower toast landed at y 433..470 against a
		button at 401..458, covering 25 of its 57 pixels.

		So while a menu card is up the STACK is parked on its own, at the same
		floor the band uses, and the banner keeps the position it always had. They
		are separate objects and only one of them is in the way.

		A banner and a menu panel almost never coexist -- a sale banner fires from
		the world, not from a panel -- and if they do, the banner is drawn where it
		always was and the toasts sit below it rather than being pushed through the
		card. That is the right way round.
	]]
	local stackBottom = nil
	if washCardUp() then
		bottom = WASH_BAND_BOTTOM
	else
		local menuBottom = menuBandBottom()
		if menuBottom then
			bottom = menuBottom
			stackBottom = MENU_BAND_MIN
		end
	end
	-- Asked far more often than it changes, now that build() re-solves it once per
	-- notification, and two tweens to the place the column is already in are
	-- nothing but churn. `instant` still writes: build() uses it to place a column
	-- that has no position at all yet.
	if bottom == bandAt and stackBottom == stackAt_ and not instant then
		return
	end
	bandAt = bottom
	stackAt_ = stackBottom
	local bannerAt = UDim2.new(0.5, 0, 1, -bottom)
	local stackAt = UDim2.new(0.5, 0, 1, -(stackBottom or (bottom + BANNER_H + BAND_GAP)))
	if instant then
		bannerHolder.Position = bannerAt
		stack.Position = stackAt
		return
	end
	local ti = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(bannerHolder, ti, { Position = bannerAt }):Play()
	TweenService:Create(stack, ti, { Position = stackAt }):Play()
end

--[[
	WATCHING THE MENU, AND WHY IT IS EACH PANEL'S Visible RATHER THAN THE SCRIM.
	(2026-09-09)

	The scrim would have been one connection instead of a handful -- MenuHud
	lights it while anything is open and puts it out on close. But it does NOT
	move when one panel replaces another, and two panels of different heights need
	different clearance, so switching from the Tide card to the Beach Shop would
	have left the column solved for the wrong one. That is the exact case this
	fix exists for.

	Both depths again, and both as they arrive: the panels are built after the gui
	is parented, and UiFit then MOVES them into its FitRoot. The parent test comes
	first because every label and row in the menu passes through DescendantAdded,
	and anything deeper than those two levels is one of those rather than a panel.
]]
local menuSeen = setmetatable({}, { __mode = "k" })
local function adoptMenu(menu: Instance)
	local function adoptPanel(inst: Instance)
		if menuSeen[inst] or not inst:IsA("GuiObject") then
			return
		end
		menuSeen[inst] = true
		inst:GetPropertyChangedSignal("Visible"):Connect(function()
			placeBand()
		end)
	end
	for _, a in ipairs(menu:GetChildren()) do
		adoptPanel(a)
		for _, b in ipairs(a:GetChildren()) do
			adoptPanel(b)
		end
	end
	menu.DescendantAdded:Connect(function(inst)
		local p = inst.Parent
		if p == menu or (p and p.Parent == menu) then
			adoptPanel(inst)
		end
	end)
	placeBand()
end

-- WashHud is built by a different script and may not exist yet -- and may be
-- rebuilt -- so this watches PlayerGui rather than resolving it once. The menu
-- is adopted the same way and for the same reason.
local watching = false
local function ensureBandWatch()
	if watching then
		return
	end
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChild("PlayerGui")
	if not pg then
		return
	end
	watching = true

	local function adopt(inst: Instance)
		if inst.Name == "WashHud" and inst:IsA("ScreenGui") then
			inst:GetPropertyChangedSignal("Enabled"):Connect(function()
				placeBand()
			end)
			placeBand()
		elseif inst.Name == MENU_GUI and inst:IsA("ScreenGui") then
			adoptMenu(inst)
		end
	end
	for _, c in ipairs(pg:GetChildren()) do
		adopt(c)
	end
	pg.ChildAdded:Connect(adopt)
end

--[[
	Self-healing, and it ADOPTS rather than clobbers.

	The first version cached `gui`/`stack` and destroyed any existing ToastKit
	ScreenGui on build. Two things went wrong with that, and the second is the
	real one:

	  * `stack` could outlive the ScreenGui it lived in, and every toast after
	    that went into a destroyed frame -- silently, because parenting to a
	    destroyed instance is not an error.
	  * a second holder of this module (another VM, a re-require, a reload) would
	    build its own GUI and DESTROY the first one, leaving whoever built that
	    one posting into nothing. Caught exactly that way: FeedbackClient and
	    CTB_HUD went quiet the moment anything else required the kit.

	So: verify the cached handles are still parented, and if a ToastKit gui is
	already in PlayerGui, take it over instead of replacing it.
]]
local function build()
	if gui and gui.Parent and stack and stack.Parent and bannerHolder and bannerHolder.Parent then
		-- THE MENU CLEARANCE IS MEASURED, so a window resize can leave it stale with
		-- no panel ever changing Visible to say so. Re-solving it here places every
		-- notification against the window it is actually being drawn in, and the
		-- no-change guard in placeBand makes the usual answer free. (2026-09-09)
		placeBand()
		return
	end
	local player = Players.LocalPlayer
	local pg = player:WaitForChild("PlayerGui")

	local existing = pg:FindFirstChild("ToastKit")
	if existing then
		gui = existing
		--[[
			RECURSIVE, AND IT HAS TO BE.

			UiFit reparents every pure-offset top-level child of every ScreenGui
			into a scaled `FitRoot` frame so the HUDs fit a phone (see
			Modules.UiFit), and all three of these are pure-offset. So the moment
			UiFitBoot has run they are GRANDchildren of the gui, and a plain
			FindFirstChild answers nil for all three.

			Which sent this straight down the "older version of this file" path
			below -- destroy the gui and rebuild it -- and that is EXACTLY the
			clobber the adoption block was written to prevent, just arriving by a
			different route than the one the note above describes.
		]]
		stack = existing:FindFirstChild("Stack", true)
		bannerHolder = existing:FindFirstChild("Banner", true)
		tipHolder = existing:FindFirstChild("Tip", true)
		if stack and bannerHolder and tipHolder then
			ensureBandWatch()
			placeBand(true)
			return
		end
		-- half-built or from an older version of this file: start clean. A gui
		-- with no Tip holder is precisely that -- one built before this tier
		-- existed -- so this is also the upgrade path.
		existing:Destroy()
		gui, stack, bannerHolder, tipHolder = nil, nil, nil, nil
	end

	gui = Instance.new("ScreenGui")
	gui.Name = "ToastKit"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	-- Above every HUD (MenuHud is 12, FeedbackHud 14) but below the reveal card
	-- at 20, which is a full-screen moment and should not be talked over.
	gui.DisplayOrder = 16
	gui.Parent = pg

	-- The stack sits ABOVE the banner and fills from its own bottom edge, so one
	-- toast appears low and a burst of three grows upward into empty screen.
	-- Sized exactly to the three-toast cap, so it can never reach past that.
	-- Centred horizontally, which also misses the CARRYING panel on the left and
	-- the button rail on the right.
	stack = Instance.new("Frame")
	stack.Name = "Stack"
	stack.AnchorPoint = Vector2.new(0.5, 1)
	stack.Size = UDim2.fromOffset(STACK_W, STACK_H)
	stack.BackgroundTransparency = 1
	stack.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	-- Bottom, so the pile hangs off the bottom of the frame and the newest toast
	-- (highest LayoutOrder, so last) is the one nearest the banner.
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, TOAST_GAP)
	layout.Parent = stack

	bannerHolder = Instance.new("Frame")
	bannerHolder.Name = "Banner"
	bannerHolder.AnchorPoint = Vector2.new(0.5, 1)
	bannerHolder.Size = UDim2.fromOffset(840, BANNER_H)
	bannerHolder.BackgroundTransparency = 1
	bannerHolder.Parent = gui

	-- The tip's space at the top. Fixed, so it does not move with the wash card
	-- the way the band below does -- there is nothing at the top of the screen
	-- for it to get out of the way of.
	tipHolder = Instance.new("Frame")
	tipHolder.Name = "Tip"
	tipHolder.AnchorPoint = Vector2.new(0.5, 0)
	tipHolder.Position = UDim2.new(0.5, 0, 0, TIP_TOP)
	tipHolder.Size = UDim2.fromOffset(TIP_MAX_W, TIP_BAND_H)
	tipHolder.BackgroundTransparency = 1
	-- NOT Active: an Active frame is clickable even at full transparency, and
	-- this one spans 620x112 across the top of the screen at all times.
	tipHolder.Active = false
	-- Left at 1 on purpose. UiFit sets its FitRoot's ZIndex to the highest it
	-- absorbs; the card inside carries the real numbers (TIP_Z below).
	tipHolder.ZIndex = 1
	tipHolder.Parent = gui

	ensureBandWatch()
	placeBand(true)
end

--------------------------------------------------------------------------
-- TOAST
--------------------------------------------------------------------------

local order = 0

-- `tint` overrides the kind's colour: a Notify carrying a rarity wants the
-- rarity's colour, not the generic pickup green.
function ToastKit.toast(text: string, kind: string?, hold: number?, tint: Color3?)
	build()
	if type(text) ~= "string" or text == "" then
		return
	end
	local base = KINDS[kind or "info"] or KINDS.info
	local k = tint and { tint = tint, glyph = base.glyph, pitch = base.pitch, shake = base.shake } or base
	hold = hold or 2.4
	order += 1

	-- Three at a time. Without a cap a burst of messages walks the stack down the
	-- screen and through the hint line, and nobody reads the fourth one anyway.
	local live = {}
	for _, c in ipairs(stack:GetChildren()) do
		if c:IsA("Frame") then
			table.insert(live, c)
		end
	end
	if #live >= 3 then
		table.sort(live, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
		for i = 1, #live - 2 do
			live[i]:Destroy()
		end
	end

	--[[
		THE PILL IS SIZED OFF THE MESSAGE IN TWO PASSES, AND IT HAS TO BE TWO.

		IT USED TO BE ONE, AND LONG MESSAGES RAN STRAIGHT OUT OF THE BUBBLE. The
		width was clamp(oneLineWidth + 76, 190, 520) and the label was pinned at
		fromScale(1, 1) inside the 44/16 padding -- so the moment a string wanted
		more than 460px the pill stopped growing, the label did not wrap, and
		nothing in here clips. Measured on the strings that actually ship:

		    "STARTER PACK UNLOCKED -- 20,000 coins and the exclusive Kingsmane pet."
		        638px of type in a 460px label: 178px of it hanging over the sand
		    "Get your own at the Car Spawner -- coins buy one too."   over by 21
		    "Starter Pack claimed -- 20000 coins and Kingsmane!"      over by 4

		So: ask what the message takes on one unbroken line and clamp that into the
		width a pill is allowed; then ask what it needs AT that width, which is
		where the height comes from. One pass cannot do it -- the height of wrapped
		text is not knowable until the width is fixed, so a single measurement
		either sizes to one line and spills the rest, which is the bug, or reserves
		two lines and leaves every short toast half empty.

		THEN IT TIGHTENS, which the tip card does not bother with and a toast
		should: a wrapped message rarely fills its last line, and the starter-pack
		one wraps to a widest line of 406 in a 520 pill. So the pill is re-measured
		at the width of its own widest line and keeps the narrower answer -- but
		only if that did not buy an extra line, because a narrower box can always
		wrap again.

		A ONE-LINE TOAST IS UNCHANGED TO THE PIXEL by all of this: same 76 of
		chrome, and TOAST_PAD_Y * 2 + 18 is exactly the 40 it always was.
	]]
	local size = TOAST_TEXT
	local roomAtMax = STACK_W - TOAST_PAD_L - TOAST_PAD_R
	-- Three lines is the ceiling. Past that a toast has stopped being a toast and
	-- the honest fix is a shorter message -- but a pill left to grow without limit
	-- would cover the HUD it is sitting over, so the type steps down instead.
	while size > TOAST_TEXT_MIN and textBounds(text, size, roomAtMax).Y > size * TOAST_LINES do
		size -= 1
	end

	local w = math.clamp(textBounds(text, size, 10000).X + TOAST_CHROME, TOAST_MIN_W, STACK_W)
	local bounds = textBounds(text, size, w - TOAST_PAD_L - TOAST_PAD_R)
	if bounds.Y > size then
		local tight = math.clamp(bounds.X + TOAST_CHROME, TOAST_MIN_W, w)
		if tight < w then
			local snug = textBounds(text, size, tight - TOAST_PAD_L - TOAST_PAD_R)
			if snug.Y <= bounds.Y then
				w, bounds = tight, snug
			end
		end
	end
	local h = math.max(TOAST_H, bounds.Y + TOAST_PAD_Y * 2)

	local holder = Instance.new("Frame")
	holder.Name = "Toast"
	holder.Size = UDim2.fromOffset(w, h)
	holder.BackgroundTransparency = 1
	holder.LayoutOrder = order
	holder.ZIndex = 20
	holder.Parent = stack
	local scale = scaleOf(holder)

	local slab = Instance.new("Frame")
	slab.Size = UDim2.new(1, 0, 1, 0)
	slab.Position = UDim2.fromOffset(0, 4)
	slab.BackgroundColor3 = darken(k.tint, 0.55)
	slab.BorderSizePixel = 0
	slab.ZIndex = 20
	slab.Parent = holder
	corner(slab, 12)
	outline(slab, 2.5)

	local face = Instance.new("Frame")
	face.Size = UDim2.new(1, 0, 1, 0)
	face.BackgroundColor3 = k.tint
	face.BorderSizePixel = 0
	face.ZIndex = 21
	face.Parent = holder
	corner(face, 12)
	outline(face, 2.5)
	gradient(face, k.tint:Lerp(WHITE, 0.3), darken(k.tint, 0.2))

	local gloss = Instance.new("Frame")
	gloss.Size = UDim2.new(1, -18, 0, 3)
	gloss.Position = UDim2.fromOffset(9, 4)
	gloss.BackgroundColor3 = WHITE
	gloss.BackgroundTransparency = 0.62
	gloss.BorderSizePixel = 0
	gloss.ZIndex = 23
	gloss.Parent = face
	corner(gloss, 2)

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, TOAST_PAD_L)
	pad.PaddingRight = UDim.new(0, TOAST_PAD_R)
	pad.Parent = face

	-- -34 against a 44 left pad leaves the badge a 10px margin off the pill's
	-- edge and a 6px gap before the text. Move either number and move both.
	local badge = Instance.new("Frame")
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.Position = UDim2.new(0, -34, 0.5, 0)
	badge.Size = UDim2.fromOffset(28, 28)
	badge.BackgroundColor3 = WHITE
	badge.BorderSizePixel = 0
	badge.ZIndex = 24
	badge.Parent = face
	corner(badge, 14)
	outline(badge, 2.5)

	local mark = Instance.new("TextLabel")
	mark.BackgroundTransparency = 1
	mark.Size = UDim2.fromScale(1, 1)
	-- FredokaOne, not LuckiestGuy: LuckiestGuy's lowercase i has no tittle, so the
	-- info badge came out as a bare vertical bar.
	mark.Font = Enum.Font.FredokaOne
	mark.Text = k.glyph
	mark.TextSize = 18
	mark.TextColor3 = darken(k.tint, 0.35)
	mark.ZIndex = 25
	mark.Parent = badge

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	-- fromScale(1, 1) of the PADDED face, so the label is exactly the width the
	-- bounds above were measured at and wraps on the same break.
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.LuckiestGuy
	label.Text = text
	label.TextSize = size
	label.TextXAlignment = Enum.TextXAlignment.Left
	-- The other half of the fix, and neither half works alone: the pill can be as
	-- tall as it likes and a label that will not wrap still draws one long line
	-- straight out through the side of it.
	label.TextWrapped = true
	label.TextColor3 = WHITE
	label.ZIndex = 24
	label.Parent = face
	textStroke(label, 2.5)

	-- IN: slams down from above, overshoots, and settles.
	holder.Rotation = (order % 2 == 0) and -7 or 7
	scale.Scale = 0.4
	TweenService:Create(scale, TweenInfo.new(0.34, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }):Play()
	TweenService:Create(holder, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Rotation = 0 }):Play()
	sparkle(holder, 7, k.tint, 90)
	AudioKit.play(TICK, nil, 1, k.pitch)

	-- Warnings wobble. Nothing else does, so a wobble MEANS something is wrong.
	if k.shake then
		task.spawn(function()
			task.wait(0.3)
			for i = 1, 6 do
				if not holder.Parent then return end
				TweenService:Create(holder, TweenInfo.new(0.05), { Rotation = (i % 2 == 0) and 3 or -3 }):Play()
				task.wait(0.05)
			end
			if holder.Parent then
				TweenService:Create(holder, TweenInfo.new(0.1), { Rotation = 0 }):Play()
			end
		end)
	end

	-- OUT: shrinks and lifts away, and the stack closes the gap behind it.
	task.delay(hold, function()
		if not holder.Parent then
			return
		end
		--[[
			OUT ON ease-out, NOT Back/In.  This was Back/In, which on the way OUT
			is an anticipation: the toast swelled slightly before it left. An
			ease-in delays the start of a movement, and the start is the moment the
			player is looking at -- so the toast read as reluctant to go while the
			stack behind it waited on its gap.

			Entering and exiting both want `out`. See Motion.Ease.
		]]
		-- The shrink and the tilt are the motion; the fade is what stands in for
		-- them when it is turned down. See Motion.fade.
		local ti = Motion.info(Motion.Dur.panel, Motion.Ease.out)
		local fade = Motion.fade(Motion.Dur.panel)
		TweenService:Create(scale, ti, { Scale = 0.5 }):Play()
		TweenService:Create(holder, ti, { Rotation = 10 }):Play()
		for _, o in ipairs({ slab, face, gloss, badge }) do
			TweenService:Create(o, fade, { BackgroundTransparency = 1 }):Play()
		end
		for _, o in ipairs({ label, mark }) do
			TweenService:Create(o, fade, { TextTransparency = 1 }):Play()
		end
		for _, o in ipairs({ slab, face, badge, label }) do
			local st = o:FindFirstChildOfClass("UIStroke")
			if st then
				TweenService:Create(st, fade, { Transparency = 1 }):Play()
			end
		end
		Debris:AddItem(holder, 0.34)
	end)
end

--------------------------------------------------------------------------
-- BANNER
--------------------------------------------------------------------------

local bannerToken = 0

function ToastKit.banner(text: string, kind: string?, hold: number?)
	build()
	if type(text) ~= "string" or text == "" then
		return
	end
	local k = KINDS[kind or "money"] or KINDS.money
	hold = hold or 2.2
	bannerToken += 1
	local mine = bannerToken

	-- Only ever one. A second sale landing on the first should replace it, not
	-- stack two slabs across the middle of the screen.
	for _, c in ipairs(bannerHolder:GetChildren()) do
		c:Destroy()
	end

	local holder = Instance.new("Frame")
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	-- Step the type down until the slab can hold it -- see the note by
	-- BANNER_PAD_X. A one-line banner at 32 breaks out of this on the first pass
	-- and is unchanged to the pixel.
	local size = BANNER_TEXT
	local w, bounds
	while true do
		w = math.clamp(textBounds(text, size, 10000).X + BANNER_CHROME, BANNER_MIN_W, BANNER_MAX_W)
		bounds = textBounds(text, size, w - BANNER_PAD_X * 2)
		if size <= BANNER_TEXT_MIN or bounds.Y <= BANNER_INNER_H then
			break
		end
		size -= 1
	end
	holder.Size = UDim2.fromOffset(w, BANNER_H)
	holder.BackgroundTransparency = 1
	holder.ZIndex = 30
	holder.Parent = bannerHolder
	local scale = scaleOf(holder)

	local slab = Instance.new("Frame")
	slab.Size = UDim2.new(1, 0, 1, 0)
	slab.Position = UDim2.fromOffset(0, 6)
	slab.BackgroundColor3 = darken(k.tint, 0.6)
	slab.BorderSizePixel = 0
	slab.ZIndex = 30
	slab.Parent = holder
	corner(slab, 18)
	outline(slab, 4)

	local face = Instance.new("Frame")
	face.Size = UDim2.new(1, 0, 1, 0)
	face.BackgroundColor3 = k.tint
	face.BorderSizePixel = 0
	face.ZIndex = 31
	face.Parent = holder
	corner(face, 18)
	outline(face, 4)
	gradient(face, k.tint:Lerp(WHITE, 0.34), darken(k.tint, 0.24))

	local gloss = Instance.new("Frame")
	gloss.Size = UDim2.new(1, -26, 0, 5)
	gloss.Position = UDim2.fromOffset(13, 6)
	gloss.BackgroundColor3 = WHITE
	gloss.BackgroundTransparency = 0.6
	gloss.BorderSizePixel = 0
	gloss.ZIndex = 33
	gloss.Parent = face
	corner(gloss, 3)

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, BANNER_PAD_X)
	pad.PaddingRight = UDim.new(0, BANNER_PAD_X)
	pad.Parent = face

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.LuckiestGuy
	label.Text = text
	label.TextSize = size
	-- The backstop for a message so long it is still over-wide at the floor size:
	-- it wraps inside the slab rather than drawing out through the side of it.
	label.TextWrapped = true
	label.TextColor3 = WHITE
	label.ZIndex = 34
	label.Parent = face
	textStroke(label, 4)

	-- IN: punches in past full size, wobbles once, settles.
	scale.Scale = 0.25
	holder.Rotation = -5
	TweenService:Create(scale, TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }):Play()
	TweenService:Create(holder, TweenInfo.new(0.5, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
		{ Rotation = 0 }):Play()
	sparkle(holder, 14, k.tint, 210)
	-- A banner is the two-part version of a toast: the knock lands first and the
	-- tick answers it a frame or two later. Same trick as the sell receipt --
	-- the gap is what gives a big moment weight without extra volume.
	AudioKit.play(THUD, nil, 1.1, k.pitch)
	task.delay(0.08, function()
		AudioKit.play(TICK, nil, 0.9, k.pitch * 1.2)
	end)

	-- A slow drift upward while it holds, so it never looks frozen on screen.
	-- Short, and BAND_GAP is sized off it: see the note by the constant.
	TweenService:Create(holder, TweenInfo.new(hold + 0.4, Enum.EasingStyle.Linear),
		{ Position = UDim2.new(0.5, 0, 0.5, -BANNER_DRIFT) }):Play()

	task.delay(hold, function()
		if bannerToken ~= mine or not holder.Parent then
			return
		end
		-- ease-out, and inside the 300ms ceiling rather than 340. Back/In here
		-- wound the banner up before letting it go; see the note on the toast's
		-- own exit above.
		local ti = Motion.info(Motion.Dur.panel, Motion.Ease.out)
		local fade = Motion.fade(Motion.Dur.panel)
		TweenService:Create(scale, ti, { Scale = 1.35 }):Play()
		for _, o in ipairs({ slab, face, gloss }) do
			TweenService:Create(o, fade, { BackgroundTransparency = 1 }):Play()
		end
		TweenService:Create(label, fade, { TextTransparency = 1 }):Play()
		for _, o in ipairs({ slab, face, label }) do
			local st = o:FindFirstChildOfClass("UIStroke")
			if st then
				TweenService:Create(st, fade, { Transparency = 1 }):Play()
			end
		end
		Debris:AddItem(holder, 0.4)
	end)
end

--------------------------------------------------------------------------
-- TIP
--------------------------------------------------------------------------
--[[
	The rotating hint band. TipConfig says what goes in it and TipClient decides
	when; this only draws it.

	IT IS THE ONLY WIDGET IN THIS FILE THE PLAYER CAN ANSWER, which is the whole
	design of it. A toast is over before you could reach it and there is nothing
	to do about a banner; a tip is up for ten seconds and was nobody's idea but
	ours, so it carries a dismiss key AND takes a click anywhere on the card. Both
	do the same thing, because a player who wants it gone does not care which part
	of it they hit -- and the key is there so they can SEE that it will go.

	The draining hairline along the bottom is the other half of that promise: it
	says the card is leaving on its own, so nobody has to sit and guard it.
]]

-- Base of the tip's ZIndex range: above the banner's 30..34 and the stack's
-- 20..25. Under ZIndexBehavior.Global -- which this gui sets -- that is not only
-- about what is drawn on top. It also decides which object takes the CLICK, and
-- this is the one tier where a click has to land.
local TIP_Z = 50

local tipToken = 0

local function tipBounds(text: string, room: number): Vector2
	local ok, b = pcall(function()
		return TextService:GetTextSize(text, TIP_TEXT, Enum.Font.LuckiestGuy,
			Vector2.new(room, 10000))
	end)
	if ok and b then
		return b
	end
	-- The same spirit as textBounds' fallback: guess GENEROUSLY. A measurement
	-- that failed should cost a card with too much air in it, never one with the
	-- last word of the tip cut off.
	local flat = #text * TIP_TEXT * 0.55
	local rows = math.max(1, math.ceil(flat / math.max(room, 1)))
	return Vector2.new(math.min(flat, room), rows * (TIP_TEXT + 5))
end

local function retireTip(card: Frame, fades: { GuiObject }, texts: { TextLabel })
	if card:GetAttribute("Going") then
		return
	end
	card:SetAttribute("Going", true)
	-- Back out the way it came in, rather than shrinking in place: the card
	-- arrived from off the top edge and leaving by the same door is what makes it
	-- read as one object coming and going instead of two events.
	-- The DOOR is right and stays -- it leaves by the edge it arrived through.
	-- The CURVE was not: Quad/In held the card in place before it moved, which
	-- is the opposite of what a card being dismissed should do.
	local ti = Motion.info(Motion.Dur.menu, Motion.Ease.out)
	local fade = Motion.fade(Motion.Dur.menu)
	TweenService:Create(card, ti, {
		Position = UDim2.new(0.5, 0, 0, -(card.Size.Y.Offset + TIP_TOP + 12)),
	}):Play()
	for _, o in ipairs(fades) do
		TweenService:Create(o, fade, { BackgroundTransparency = 1 }):Play()
		local st = o:FindFirstChildOfClass("UIStroke")
		if st then
			TweenService:Create(st, fade, { Transparency = 1 }):Play()
		end
	end
	for _, o in ipairs(texts) do
		TweenService:Create(o, fade, { TextTransparency = 1 }):Play()
		local st = o:FindFirstChildOfClass("UIStroke")
		if st then
			TweenService:Create(st, TweenInfo.new(0.26), { Transparency = 1 }):Play()
		end
	end
	Debris:AddItem(card, 0.32)
end

function ToastKit.tip(text: string, kind: string?, hold: number?)
	build()
	if type(text) ~= "string" or text == "" then
		return
	end
	local k = KINDS[kind or "info"] or KINDS.info
	hold = hold or 10
	tipToken += 1
	local mine = tipToken

	-- Only ever one, the same rule as the banner and for a harder reason: two
	-- cards at one top-anchored position do not stack, they overlap, and the one
	-- underneath is both unreadable and unclickable.
	for _, c in ipairs(tipHolder:GetChildren()) do
		c:Destroy()
	end

	--[[
		THE CARD IS SIZED OFF THE MESSAGE, IN TWO PASSES, AND IT HAS TO BE TWO.

		First ask what the message would take on one unbroken line, and clamp that
		into the width a card is allowed. THEN ask what it needs at that width,
		which is where the height comes from. One pass cannot do it: the height of
		wrapped text is not knowable until the width is fixed, so a single
		measurement either sizes to one line and clips the second, or reserves two
		lines and leaves every short tip half empty.

		Measured rather than TextScaled on purpose -- TextScaled cannot shrink text
		to fit one line, it wraps instead, so it would silently undo all of this.
	]]
	local flat = tipBounds(text, 10000).X
	local w = math.clamp(flat + TIP_CHROME, TIP_MIN_W, TIP_MAX_W)
	local inner = w - TIP_CHROME
	local bounds = tipBounds(text, inner)
	local h = math.max(TIP_MIN_H, bounds.Y + TIP_PAD_Y * 2 + TIP_BAR_ROOM)
	-- The row -- chip, message, dismiss key -- centres on the space ABOVE the
	-- hairline rather than on the whole card. Centring on the card instead pushes
	-- the last line of text down onto the bar; see the note by TIP_BAR_ROOM.
	local mid = (h - TIP_BAR_ROOM) * 0.5

	local card = Instance.new("Frame")
	card.Name = "TipCard"
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Size = UDim2.fromOffset(w, h)
	card.BackgroundTransparency = 1
	card.ZIndex = TIP_Z
	card.Parent = tipHolder
	local scale = scaleOf(card)

	local slab = Instance.new("Frame")
	slab.Size = UDim2.new(1, 0, 1, 0)
	slab.Position = UDim2.fromOffset(0, 5)
	slab.BackgroundColor3 = darken(k.tint, 0.58)
	slab.BorderSizePixel = 0
	slab.ZIndex = TIP_Z
	slab.Parent = card
	corner(slab, 14)
	outline(slab, 3)

	local face = Instance.new("Frame")
	face.Size = UDim2.new(1, 0, 1, 0)
	face.BackgroundColor3 = k.tint
	face.BorderSizePixel = 0
	face.ZIndex = TIP_Z + 1
	face.Parent = card
	corner(face, 14)
	outline(face, 3)
	gradient(face, k.tint:Lerp(WHITE, 0.32), darken(k.tint, 0.22))

	local gloss = Instance.new("Frame")
	gloss.Size = UDim2.new(1, -22, 0, 4)
	gloss.Position = UDim2.fromOffset(11, 5)
	gloss.BackgroundColor3 = WHITE
	gloss.BackgroundTransparency = 0.6
	gloss.BorderSizePixel = 0
	gloss.ZIndex = TIP_Z + 2
	gloss.Parent = face
	corner(gloss, 2)

	-- THE WORD "TIP", which is the point of the chip: the player has to be able
	-- to tell in one glance that this is advice and not something that just
	-- happened to them. White plate rather than tinted, so it reads at the same
	-- strength whichever kind's colour the card is wearing.
	local chip = Instance.new("Frame")
	chip.AnchorPoint = Vector2.new(0, 0.5)
	chip.Position = UDim2.new(0, TIP_PAD_X, 0, mid)
	chip.Size = UDim2.fromOffset(TIP_CHIP_W, TIP_CHIP_H)
	chip.BackgroundColor3 = WHITE
	chip.BorderSizePixel = 0
	chip.ZIndex = TIP_Z + 3
	chip.Parent = face
	corner(chip, 8)
	outline(chip, 2.5)

	local chipText = Instance.new("TextLabel")
	chipText.BackgroundTransparency = 1
	chipText.Size = UDim2.fromScale(1, 1)
	chipText.Font = Enum.Font.LuckiestGuy
	chipText.Text = "TIP"
	chipText.TextSize = 13
	chipText.TextColor3 = darken(k.tint, 0.45)
	chipText.ZIndex = TIP_Z + 4
	chipText.Parent = chip

	local label = Instance.new("TextLabel")
	label.Name = "Message"
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.new(0, TIP_PAD_X + TIP_CHIP_W + TIP_GAP, 0, mid)
	label.Size = UDim2.fromOffset(inner, bounds.Y)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.LuckiestGuy
	label.Text = text
	label.TextSize = TIP_TEXT
	label.TextColor3 = WHITE
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextWrapped = true
	label.ZIndex = TIP_Z + 3
	label.Parent = face
	textStroke(label, 2.5)

	-- THE COUNTDOWN, and it is not decoration. Without it the card is a thing of
	-- unknown duration sitting over the top of the screen, and the only safe
	-- assumption a player can make about one of those is that it needs dealing
	-- with. Draining left tells them it is already leaving.
	local track = Instance.new("Frame")
	track.AnchorPoint = Vector2.new(0.5, 1)
	track.Position = UDim2.new(0.5, 0, 1, -TIP_BAR_GAP)
	track.Size = UDim2.fromOffset(w - 24, TIP_BAR_H)
	track.BackgroundColor3 = darken(k.tint, 0.5)
	track.BackgroundTransparency = 0.4
	track.BorderSizePixel = 0
	track.ZIndex = TIP_Z + 2
	track.Parent = face
	corner(track, 2)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.BackgroundColor3 = WHITE
	fill.BackgroundTransparency = 0.2
	fill.BorderSizePixel = 0
	fill.ZIndex = TIP_Z + 3
	fill.Parent = track
	corner(fill, 2)

	--[[
		TWO WAYS TO SAY NO, ONE ACTION.

		`cover` is an invisible button over the whole card, so a click anywhere
		on it dismisses -- that is the one people will actually use. `close` is
		the visible key, and it sits ABOVE the cover so it takes its own clicks
		and can light up under the pointer. It is not there because the cover
		needs help; it is there so the card LOOKS dismissible before anybody has
		tried.
	]]
	local cover = Instance.new("TextButton")
	cover.Name = "DismissAnywhere"
	cover.Size = UDim2.new(1, 0, 1, 0)
	cover.BackgroundTransparency = 1
	cover.Text = ""
	cover.AutoButtonColor = false
	cover.ZIndex = TIP_Z + 5
	cover.Parent = card

	local close = Instance.new("TextButton")
	close.Name = "Dismiss"
	close.AnchorPoint = Vector2.new(1, 0.5)
	close.Position = UDim2.new(1, -TIP_PAD_X, 0, mid)
	close.Size = UDim2.fromOffset(TIP_CLOSE, TIP_CLOSE)
	close.BackgroundColor3 = darken(k.tint, 0.4)
	close.BorderSizePixel = 0
	close.AutoButtonColor = false
	close.Text = ""
	close.ZIndex = TIP_Z + 6
	close.Parent = face
	corner(close, 8)
	outline(close, 2.5)

	-- The X is its own label rather than the button's Text, because `outline`
	-- and `textStroke` both parent a UIStroke and an instance only honours ONE --
	-- putting both on the button would silently drop one of them.
	local closeMark = Instance.new("TextLabel")
	closeMark.BackgroundTransparency = 1
	closeMark.Size = UDim2.fromScale(1, 1)
	closeMark.Font = Enum.Font.LuckiestGuy
	closeMark.Text = "X"
	closeMark.TextSize = 13
	closeMark.TextColor3 = WHITE
	closeMark.ZIndex = TIP_Z + 7
	closeMark.Parent = close
	textStroke(closeMark, 2)

	local closeScale = scaleOf(close)
	close.MouseEnter:Connect(function()
		TweenService:Create(closeScale, TweenInfo.new(0.12), { Scale = 1.18 }):Play()
	end)
	close.MouseLeave:Connect(function()
		TweenService:Create(closeScale, TweenInfo.new(0.12), { Scale = 1 }):Play()
	end)

	local fades = { slab, face, gloss, chip, track, fill, close }
	local texts = { chipText, label, closeMark }

	-- IN: down from off the top edge, overshooting once. Same Back curve as the
	-- other two tiers, so all three tell you they belong to the same game.
	card.Position = UDim2.new(0.5, 0, 0, -(h + TIP_TOP + 12))
	scale.Scale = 0.92
	local inTi = TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(card, inTi, { Position = UDim2.new(0.5, 0, 0, 0) }):Play()
	TweenService:Create(scale, inTi, { Scale = 1 }):Play()
	-- Softer and lower than a toast's. It is an interruption, and an interruption
	-- that announces itself as loudly as a reward is the thing people turn off.
	AudioKit.play(TICK, nil, 0.75, 0.95)

	-- Started after the entrance so the bar is not already part-drained by the
	-- time the card has finished arriving.
	TweenService:Create(fill, TweenInfo.new(hold, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut,
		0, false, 0.42), { Size = UDim2.new(0, 0, 1, 0) }):Play()

	local function dismiss()
		if tipToken ~= mine then
			return
		end
		-- Burns the token, which is what stops the timer below from firing a
		-- second retire into a card that is already on its way out.
		tipToken += 1
		retireTip(card, fades, texts)
		AudioKit.play(TICK, nil, 0.45, 0.8)
	end
	TouchFit.press(cover, dismiss)
	TouchFit.press(close, dismiss)

	task.delay(hold + 0.42, function()
		if tipToken ~= mine or not card.Parent then
			return
		end
		retireTip(card, fades, texts)
	end)
end

function ToastKit.start()
	if not RunService:IsClient() then
		return
	end
	build()
end

return ToastKit