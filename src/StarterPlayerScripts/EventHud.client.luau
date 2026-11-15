--[[
	EventHud  --  StarterPlayer.StarterPlayerScripts.EventHud  (LocalScript)

	THE COUNTDOWN, WHICH IS THE POINT OF THE WHOLE SYSTEM -- AND NOT WHAT IT IS
	COUNTING DOWN TO, WHICH IS THE POINT OF THIS FILE.

	A player who can see "something in 3:41" has a reason to still be here in
	three minutes and forty-one seconds. Telling them WHICH thing spends the
	surprise for nothing: the reveal is the moment the event is worth anything,
	and a pill that has been announcing GOLDEN HOUR for nine minutes has already
	had it. So the name, the colour and the badge all arrive together, at zero.

	The schedule is arithmetic on a replicated module, so a determined player can
	read the next event out of EventConfig. That is true of every number in every
	Roblox game and is not worth engineering against -- what matters is that
	nothing on screen gives it away in normal play.

	IT COUNTS DOWN OFF ITS OWN CLOCK. EventConfig is replicated and the timetable
	is arithmetic on os.time(), so every number here is worked out locally, every
	frame, and never waits on a message. The EventState remote is used for two
	things: it carries the server's `now` -- measured once, subtracted forever, so
	the pill hits 0:00 exactly as the banner lands -- and it can name an event
	that is not on the timetable at all, which the schedule alone cannot know
	about.

	WHERE IT SITS, AND WHAT HAD TO MOVE
	-----------------------------------
	Top centre, in the strip above everything else, measured against the live HUD
	rather than guessed. That strip was NOT free: ToastKit's tip card was parked
	at y = 16 and DuelClient's challenge card at y = 96, four pixels below where a
	two-line tip bottoms out -- a gap ToastKit's own note says to check whenever
	either number moves.

	So both moved down by 22, in that order, and the reason is an ordering rule
	worth keeping: THE PERMANENT READOUT IS ON TOP AND THE TRANSIENT CARDS QUEUE
	BENEATH IT. A countdown that is always there should not be the thing that
	gets covered, and a card that is up for ten seconds can afford the pixels.

	It is ONE LINE, which the surprise paid for. With the name hidden there is
	nothing to stack, so the pill is 30px tall instead of 54 -- small enough to
	live in that strip without crowding the cards under it.

	DisplayOrder 11, UNDER MenuHud's 12. At the top right that hardly mattered;
	dead centre it does, because every panel in the game opens right underneath
	this. A readout must never draw over a panel the player has opened.

	NOTHING DURING THE TUTORIAL, and this is where that gate lives rather than on
	the server. The MECHANICAL half of every event is silently good for you -- a
	bigger bag, a better price, a can you may walk into -- so there is nothing to
	withhold from a new player. What they must not get is a countdown and a second
	thing to understand while they are being taught the first one.

	TAPPING IT IS HOW YOU ASK WHAT IT IS. The pill holds three words and a clock,
	which answers "how long" and -- while an event is live -- "what have I got".
	It cannot answer "what IS this". So it is a button, and the card under it is
	the long answer. It still refuses to name what is COMING: see the note over
	the card itself.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local EventConfig = require(Modules:WaitForChild("EventConfig"))
local ToastKit = require(Modules:WaitForChild("ToastKit"))
local HudKit = require(Modules:WaitForChild("HudKit"))
local Net = require(Modules:WaitForChild("Net"))
local TutorialConfig = require(Modules:WaitForChild("TutorialConfig"))

-- Touch targets: see the module. Substituted for MouseButton1Click/Activated so
-- a tap in the margin around a control that renders under 44px on a phone still
-- reaches the same handler. No-ops on desktop and on controls already big enough.
local TouchFit = require(Modules:WaitForChild("TouchFit"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--[[
	MEASURED, in this game's own font, against the longest string each slot can
	hold:

	  "STARTING SOON" at LuckiestGuy 16 is 118px -- the widest label there is,
	      wider than any event name (GOLDEN HOUR is 102)
	  "10:00"         at LuckiestGuy 18 is  46px

	The pill is the sum of its parts rather than a number typed at the top, so
	adding the clock face and the dismiss button re-measured it instead of
	squashing them into the room the old 216 had:

		12 pad + 22 icon + 8 gap + 124 label + 10 gap
		+ 52 clock + 4 gap + 28 close + 6 pad  =  266
]]
local H = 34
local RADIUS = 17
local PAD = 12
local ICON_W = 22
local GAP = 8
local LABEL_W, CLOCK_W = 124, 52
-- Wider than the X drawn on it. 28 is not a comfortable touch target and this
-- pill has no room to make it one, but a hit area bigger than the glyph is the
-- part that can be had for free.
local CLOSE_W = 28
--[[
	WHAT THE X CATCHES, as opposed to the slot it occupies in the sum above.

	28 x 34 is under the 30 x 30 a press target is held to here, and the SLOT
	cannot grow: CLOSE_W feeds both W and the clock's right edge, so widening it
	would shove the countdown left. What CAN grow is the catchment. There are 4
	dead pixels between the button and the clock and 6 more out to the pill's
	edge, and a 36 box centred on the glyph claims the 4 and four of the 6
	without touching the layout or moving the X by a pixel. The 2 it overhangs
	top and bottom cost nothing either -- the surface does not clip, and the
	button has no fill to show. 2026-09-09.
]]
local CLOSE_TAP = 36
local W = PAD + ICON_W + GAP + LABEL_W + 10 + CLOCK_W + 4 + CLOSE_W + 6
local TOP = 3

-- The quiet state wears the readouts' own colour. Only a LIVE event is allowed
-- to be one of the bright ones, which is what makes the pill changing colour
-- mean something.
local IDLE_TINT = HudKit.C.face

local gui = Instance.new("ScreenGui")
gui.Name = "EventHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
gui.DisplayOrder = 11
gui.Enabled = false
gui.Parent = playerGui

local root = Instance.new("Frame")
root.Name = "EventPill"
root.AnchorPoint = Vector2.new(0.5, 0)
root.Position = UDim2.new(0.5, 0, 0, TOP)
root.Size = UDim2.fromOffset(W, H)
root.BackgroundTransparency = 1
root.Parent = gui

--[[
	THE GLOW, and it is the whole of what "lit" means here.

	Three rounded frames behind the pill, tinted with the event's own colour and
	each one fainter and larger than the last -- the same three PanelKit.card
	puts behind every panel in the game. A hard-edged pill on a bright sky reads
	as a sticker laid on the screen; light spilling from behind its edges is what
	makes it read as sitting ABOVE the world.

	They are INVISIBLE while nothing is running and fade up with the event, so
	the reveal is a light coming on rather than a label changing.

	TUNED AGAINST THE SKY, NOT AGAINST AN EDITOR BACKGROUND. The first pass sat
	them at 0.83 to 0.93 transparency, which is a perfectly good halo on a dark
	backdrop and completely invisible over a bright beach at midday -- which is
	where this pill actually lives. 0.61 to 0.79 reads on sand, on sky and on
	water without becoming a smear.
]]
local glows = {}
for i = 3, 1, -1 do
	local g = Instance.new("Frame")
	g.Name = "Glow" .. i
	g.AnchorPoint = Vector2.new(0.5, 0.5)
	g.Position = UDim2.new(0.5, 0, 0.5, 2)
	g.Size = UDim2.fromOffset(W + i * 20, H + i * 16)
	g.BackgroundColor3 = IDLE_TINT
	g.BackgroundTransparency = 1
	g.BorderSizePixel = 0
	g.ZIndex = 0
	g.Parent = root
	HudKit.corner(g, RADIUS + i * 8)
	table.insert(glows, { frame = g, rest = 0.52 + i * 0.09 })
end

local holder, face, slab = HudKit.surface(root, W, H, RADIUS, IDLE_TINT)
holder.Name = "Pill"
HudKit.gloss(face, RADIUS)

--[[
	SCALED THE WAY THE LEFT-HAND COLUMN IS.

	HudKit.fitColumn cannot be used: it rewrites Position from a captured base and
	assumes a pure-offset one. This pill is centred in SCALE, so its offset never
	needs rewriting -- the anchor already does that -- and all it wants is the
	same multiplier on a UIScale.
]]
local fit = Instance.new("UIScale")
fit.Parent = root
local function refit()
	fit.Scale = HudKit.columnMult()
end
refit()

local label = HudKit.text(face, "", 16, HudKit.C.text)
label.Position = UDim2.fromOffset(PAD + ICON_W + GAP, 0)
label.Size = UDim2.fromOffset(LABEL_W, H)
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextTruncate = Enum.TextTruncate.AtEnd
label.ZIndex = 12
HudKit.punch(label, 2)

local clock = HudKit.text(face, "", 18, HudKit.C.text)
clock.AnchorPoint = Vector2.new(1, 0)
clock.Position = UDim2.new(1, -(6 + CLOSE_W + 4), 0, 0)
clock.Size = UDim2.fromOffset(CLOCK_W, H)
clock.TextXAlignment = Enum.TextXAlignment.Right
clock.ZIndex = 12
HudKit.punch(clock, 2)

--[[
	THE CLOCK FACE.

	A sprite, where this was a ring and two hands drawn from Frames. Full-bleed
	square art -- 300x300 with the face touching all four edges -- so Fit draws it
	at the box's full 22px with no margin correction, unlike the crusted lump,
	whose art sits in a wide canvas and needs the box oversized to compensate.

	THE SWEEPING HAND WENT WITH THE DRAWN VERSION, and it is the one thing lost
	here. It turned once a minute off the countdown's own number, so the icon was
	showing the same fact the digits were rather than decorating them. A sprite
	has its hands baked in at a fixed time, and a third hand drawn over them would
	read as clutter rather than as motion.

	PUTTING IT BACK is a slim second hand parented over this label -- the tick
	still holds st.left at exactly the point the rotation used to be written, so
	nothing else would need to change.
]]
local icon = Instance.new("ImageLabel")
icon.Name = "Clock"
icon.Position = UDim2.fromOffset(PAD, (H - ICON_W) * 0.5)
icon.Size = UDim2.fromOffset(ICON_W, ICON_W)
icon.BackgroundTransparency = 1
icon.Image = "rbxassetid://98887333549310"
icon.ScaleType = Enum.ScaleType.Fit
icon.ZIndex = 12
icon.Parent = face

--[[
	THE X, AND WHAT DISMISSING ACTUALLY MEANS.

	It hides the COUNTDOWN, not the event. Something actually starting un-hides
	it -- see the live transition in the tick -- because a player who tidied away
	a clock has not asked to be kept in the dark about Golden Hour, and a buff
	nobody knows they have is a buff that changes nobody's afternoon.

	The bars are drawn rather than typed for the same reason the clock face is,
	and this is the second X in the game built this way: LuckiestGuy has no
	multiplication sign at all, so the alternative is whatever the device picks.
]]
--[[
	IT SORTS ABOVE THE PILL'S OWN TAP AREA, AND IT HAS TO.

	`hit` -- the invisible pad further down this file that opens the info card --
	is the whole pill plus a margin, so it lies over this button completely. It
	used to carry the HIGHER ZIndex (15 against 13) and this ScreenGui sorts
	globally, so every press aimed at the X was swallowed by the card toggle
	instead: the countdown could not be dismissed on any device at any
	resolution, and all the X did was open and shut the little card. The X is now
	the topmost interactive thing over its own rect; `hit` still takes every
	other pixel of the pill, so a tap anywhere else opens the card as before.

	TouchFit is deliberately NOT used on this one. Its pad is 44 REAL pixels,
	which at this HUD's column multiplier reaches back across the clock, and a
	tap on the countdown that dismisses the countdown is a worse bug than the one
	being closed here. CLOSE_TAP does the same job within the pill. 2026-09-09.
]]
local close = Instance.new("TextButton")
close.Name = "Close"
-- Centred rather than right-anchored, so CLOSE_TAP can grow into the dead space
-- on BOTH sides while the drawn X stays on the centre it was laid out on: the
-- old right edge minus half the slot is the same point this lands on.
close.AnchorPoint = Vector2.new(0.5, 0.5)
close.Position = UDim2.new(1, -(6 + CLOSE_W * 0.5), 0.5, 0)
close.Size = UDim2.fromOffset(CLOSE_TAP, CLOSE_TAP)
close.BackgroundTransparency = 1
close.AutoButtonColor = false
close.Text = ""
close.ZIndex = 17
close.Parent = face

local closeBars = {}
for _, rot in { 45, -45 } do
	local bar = Instance.new("Frame")
	bar.AnchorPoint = Vector2.new(0.5, 0.5)
	bar.Position = UDim2.fromScale(0.5, 0.5)
	bar.Size = UDim2.fromOffset(12, 2.4)
	bar.Rotation = rot
	bar.BackgroundColor3 = HudKit.C.text
	-- Quieter than the type beside it. This is the one thing on the pill that is
	-- not information, and it should be findable without competing with the
	-- countdown it sits next to.
	bar.BackgroundTransparency = 0.3
	bar.BorderSizePixel = 0
	bar.ZIndex = 18
	bar.Parent = close
	HudKit.roundOff(bar)
	closeBars[#closeBars + 1] = bar
end

local function paintClose(t: number)
	for _, bar in closeBars do
		bar.BackgroundTransparency = t
	end
end
close.MouseEnter:Connect(function()
	paintClose(0)
end)
close.MouseLeave:Connect(function()
	paintClose(0.3)
end)

--------------------------------------------------------------------------
-- THE SERVER'S CLOCK
--------------------------------------------------------------------------
local offset = 0
local lastLive = nil

--[[
	THE SERVER GETS THE LAST WORD, AND IT HAS TO.

	The first cut of this file read the timetable and nothing else, on the
	reasoning that both ends compute the same arithmetic so a message could only
	ever be a clock correction. That is true of the ROTATION and false of the
	SERVER: EventService can also run an event that is not on the timetable at all
	-- forceNow does -- and a HUD that can only read the schedule sits there
	counting down to the next slot while an event is live around the player.

	So the schedule is the DEFAULT and a live broadcast is an OVERRIDE, held only
	for as long as its own window.
]]
local override = nil

Net.get("EventState").OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then
		return
	end
	if type(payload.now) == "number" then
		offset = payload.now - os.time()
	end
	if payload.phase == "live" and type(payload.id) == "string" and type(payload.endsAt) == "number" then
		override = { id = payload.id, startsAt = payload.startsAt or payload.endsAt, endsAt = payload.endsAt }
	else
		override = nil
	end
end)

local function now(): number
	return os.time() + offset
end

local function currentState()
	local t = now()
	if override then
		local def = EventConfig.ById[override.id]
		if def and t < override.endsAt then
			return {
				phase = "live",
				event = def,
				startsAt = override.startsAt,
				endsAt = override.endsAt,
				left = override.endsAt - t,
			}
		end
		override = nil
	end
	return EventConfig.stateAt(t)
end

--------------------------------------------------------------------------
-- GOLDEN HOUR'S LIGHT
--------------------------------------------------------------------------
--[[
	ITS OWN ColorCorrection, NOT THE CLOCK.

	The obvious move is LightingLock's CTB_ClockTarget -- push the hour to 17 and
	the sky warms. It is the wrong move here: Island3_Client already holds that
	attribute at 17 for as long as you are in Sakura Cove and hands it back when
	you leave, so an event writing it too would make two writers of one value, and
	leaving the cove mid-event would snap the light back to noon. LightingLock's
	own header warns about exactly that shape.

	A ColorCorrection composites over whatever grade an island has already put up
	instead of arguing with it, is per-client (Lighting writes made here never
	replicate), and comes off cleanly. Gentle on purpose: this should read as the
	sun going low, not as a filter.
]]
local grade = nil

local function gradeIn()
	if grade then
		return
	end
	grade = Instance.new("ColorCorrectionEffect")
	grade.Name = "CTB_EventGrade"
	grade.Brightness = 0
	grade.Contrast = 0
	grade.Saturation = 0
	grade.TintColor = Color3.new(1, 1, 1)
	grade.Parent = Lighting
	TweenService:Create(grade, TweenInfo.new(2.2), {
		Brightness = 0.03,
		Contrast = 0.08,
		Saturation = 0.12,
		TintColor = Color3.fromRGB(255, 232, 196),
	}):Play()
end

local function gradeOut()
	if not grade then
		return
	end
	local going = grade
	grade = nil
	local t = TweenService:Create(going, TweenInfo.new(1.6), {
		Brightness = 0,
		Contrast = 0,
		Saturation = 0,
		TintColor = Color3.new(1, 1, 1),
	})
	t.Completed:Connect(function()
		going:Destroy()
	end)
	t:Play()
end

--------------------------------------------------------------------------
-- ARRIVING AND LEAVING
--------------------------------------------------------------------------
local TINT_TIME = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function paint(colour: Color3, lit: boolean)
	face.BackgroundColor3 = colour
	HudKit.regrad(face, colour, HudKit.darken(colour, 0.24))
	slab.BackgroundColor3 = HudKit.darken(colour, 0.5)
	--[[
		THE TYPE HAS TO TURN WITH THE FACE.

		HudKit.C.text is white, which is right on the dark readout blue and wrong
		on gold and lime -- the two brightest kinds in the roster. So live type is
		the tint's own colour taken most of the way to black: it stays legible on
		every kind without needing a per-kind decision, and it keeps the pill
		reading as one object rather than white text sitting on a colour.
	]]
	local ink = lit and HudKit.darken(colour, 0.62) or HudKit.C.text
	for _, l in ipairs({ label, clock }) do
		l.TextColor3 = ink
		local st = l:FindFirstChildOfClass("UIStroke")
		if st then
			st.Color = lit and colour:Lerp(Color3.new(1, 1, 1), 0.55) or HudKit.C.ink
		end
	end
	for _, g in ipairs(glows) do
		g.frame.BackgroundColor3 = colour:Lerp(Color3.new(1, 1, 1), 0.3)
		TweenService:Create(g.frame, TINT_TIME,
			{ BackgroundTransparency = lit and g.rest or 1 }):Play()
	end
end

local function pop()
	local s = face:FindFirstChild("Punch")
	if not s then
		s = Instance.new("UIScale")
		s.Name = "Punch"
		s.Parent = face
	end
	s.Scale = 0.82
	TweenService:Create(s, TweenInfo.new(0.46, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }):Play()
end

--------------------------------------------------------------------------
-- "WHAT IS IT?"  --  THE TAP CARD
--------------------------------------------------------------------------
--[[
	A COUNTDOWN NOBODY CAN ASK ABOUT IS A RIDDLE.

	The pill answers how long, and while an event is live it answers what you
	have got -- both in the two or three words a glanceable readout can hold.
	The questions it has no room for are the ones a player actually stops to
	ask: what IS this, and what happens when it lands. So the pill takes a tap
	and this opens underneath it.

	IT STILL DOES NOT NAME WHAT IS COMING, and that is this file's whole rule
	rather than an oversight in the card. Tapping during the quiet says WHEN,
	and says what an event is in general -- never which one. The reveal is the
	only surprise an event has and a tap must not be a way to buy it early.
	Same reason the waiting card wears the idle colour: the roster's tints are
	one per event, so colouring it would name the event without printing it.

	IT IS A READOUT, NOT A PANEL. No scrim, no close key, nothing modal. It
	opens under the pill, a second tap puts it away, and it closes itself after
	LINGER seconds so it can never be left sitting over the game.
]]

local CARD_W, CARD_H = 286, 116
local CARD_R = 18
local PADX = 18
-- Long enough to read twice, short enough that a tap taken on the way past is
-- never something the player has to go back and undo.
local LINGER = 8

--[[
	THE HIT AREA IS BIGGER THAN THE PILL. On a phone the pill is 34 authored
	pixels tall against a column multiplier that can take it under twenty, and a
	target that small is a target you miss. This is the pill plus six pixels of
	margin, invisible, and it stops well clear of the tip card at y = 38 and the
	duel challenge at y = 118 -- so it steals nobody else's taps.

	The label and the clock are TextLabels and do not take input, so sitting
	over them costs nothing.
]]
local hit = Instance.new("TextButton")
hit.Name = "Tap"
hit.AnchorPoint = Vector2.new(0.5, 0.5)
hit.Position = UDim2.new(0.5, 0, 0.5, 0)
hit.Size = UDim2.fromOffset(W + 16, H + 12)
hit.BackgroundTransparency = 1
hit.AutoButtonColor = false
hit.Text = ""
hit.ZIndex = 15
hit.Parent = root

local cardHolder, cardFace, cardSlab = HudKit.surface(root, CARD_W, CARD_H, CARD_R, IDLE_TINT)
cardHolder.Name = "Detail"
cardHolder.AnchorPoint = Vector2.new(0.5, 0)
cardHolder.Position = UDim2.new(0.5, 0, 1, 12)
cardHolder.Visible = false
HudKit.gloss(cardFace, CARD_R)

local cardScale = Instance.new("UIScale")
cardScale.Parent = cardHolder

local cardTitle = HudKit.text(cardFace, "", 13, HudKit.C.textDim, Enum.Font.GothamBold)
cardTitle.Position = UDim2.fromOffset(PADX, 12)
cardTitle.Size = UDim2.fromOffset(CARD_W - PADX * 2, 16)
cardTitle.TextXAlignment = Enum.TextXAlignment.Left

local cardHero = HudKit.text(cardFace, "", 32, HudKit.C.text)
cardHero.Position = UDim2.fromOffset(PADX, 30)
cardHero.Size = UDim2.fromOffset(CARD_W - PADX * 2, 38)
cardHero.TextXAlignment = Enum.TextXAlignment.Left
cardHero.TextScaled = false
HudKit.punch(cardHero, 2)

local cardFoot = HudKit.text(cardFace, "", 13, HudKit.C.textDim, Enum.Font.GothamBold)
cardFoot.Position = UDim2.fromOffset(PADX, 70)
cardFoot.Size = UDim2.fromOffset(CARD_W - PADX * 2, 36)
cardFoot.TextXAlignment = Enum.TextXAlignment.Left
cardFoot.TextYAlignment = Enum.TextYAlignment.Top
cardFoot.TextWrapped = true

-- The same rule paint() follows for the pill: type turns with the face, because
-- white on gold is not type. See the note there.
local function paintCard(colour: Color3, lit: boolean)
	cardFace.BackgroundColor3 = colour
	HudKit.regrad(cardFace, colour, HudKit.darken(colour, 0.24))
	cardSlab.BackgroundColor3 = HudKit.darken(colour, 0.5)
	local ink = lit and HudKit.darken(colour, 0.62) or HudKit.C.text
	--[[
		THE SMALL TYPE TAKES THE SAME INK AS THE BIG TYPE, and that is a
		correction rather than an oversight. Dimming it 0.44 the way a dim line
		is dimmed everywhere else in this HUD reads fine on the dark idle face
		and vanished on a lit one: the gloss cap lightens the top half of the
		card, the face is already a bright colour, and 13px of GothamBold at
		half-contrast on top of that was not a sentence anybody was going to
		read. Hierarchy on a lit card comes from SIZE, which it has plenty of.
	]]
	local dim = lit and HudKit.darken(colour, 0.62) or HudKit.C.textDim
	cardHero.TextColor3 = ink
	cardTitle.TextColor3 = dim
	cardFoot.TextColor3 = dim
	local st = cardHero:FindFirstChildOfClass("UIStroke")
	if st then
		st.Color = lit and colour:Lerp(Color3.new(1, 1, 1), 0.55) or HudKit.C.ink
	end
end

--[[
	WHAT IT SAYS, and the two states are deliberately different shapes.

	LIVE names the thing, says what it does and when it stops. The banner and
	the toast said all three at zero and were gone four seconds later; this is
	where a player goes when they have faded and the buff is still on.

	WAITING leads with the sentence the player opened it to ask -- "the next
	event will happen in:" -- and gives the clock the whole middle of the card,
	because WHEN is the entire answer. The line under it says what an event is
	in general, which is the part a first-timer is actually missing. It does not
	say which one is next, and it must not start.
]]
local WAIT_TITLE = "THE NEXT EVENT WILL HAPPEN IN:"
local WAIT_FOOT = "Every ten minutes the whole beach gets a bonus for a minute. Everyone on the server gets it at once."

local cardOpen = false
local cardUntil = 0
-- What the card is currently saying. Rebuilt only when that changes, so an open
-- card is not rewriting six properties sixty times a second to say the same
-- thing -- the clock is the only part that moves, and only once a second.
local cardSays = ""

local function fillCard(st)
	local live = st.phase == "live" and st.event ~= nil
	local key = (live and ("live/" .. st.event.id .. "/") or "wait/") .. EventConfig.clock(st.left)
	if key == cardSays then
		return
	end
	cardSays = key

	if live then
		local def = st.event
		local k = ToastKit.KINDS[def.kind] or ToastKit.KINDS.info
		paintCard(k.tint, true)
		cardTitle.Text = "HAPPENING NOW"
		cardHero.Text = def.name
		cardHero.TextSize = 28
		cardFoot.Text = def.blurb .. "\nEnds in " .. EventConfig.clock(st.left) .. "."
	else
		paintCard(IDLE_TINT, false)
		cardTitle.Text = WAIT_TITLE
		cardHero.Text = EventConfig.clock(st.left)
		cardHero.TextSize = 36
		cardFoot.Text = WAIT_FOOT
	end
end

local function closeCard()
	cardOpen = false
	cardHolder.Visible = false
end

local function openCard()
	cardOpen = true
	cardUntil = os.clock() + LINGER
	cardSays = ""            -- whatever it said last time is a tick out of date
	fillCard(currentState())
	cardHolder.Visible = true
	cardScale.Scale = 0.86
	TweenService:Create(cardScale, TweenInfo.new(0.28, Enum.EasingStyle.Back,
		Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

-- A press, reusing the arrival punch's OWN UIScale rather than adding a second
-- one: two tweens on two scales over one face fight, and the loser is whichever
-- finished first.
local function nudge()
	local sc = face:FindFirstChild("Punch")
	if not sc then
		sc = Instance.new("UIScale")
		sc.Name = "Punch"
		sc.Parent = face
	end
	sc.Scale = 0.93
	TweenService:Create(sc, TweenInfo.new(0.22, Enum.EasingStyle.Back,
		Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

-- Activated rather than MouseButton1Click: it is the one that also fires for a
-- tap and for a gamepad, and this is a phone control before it is a mouse one.
TouchFit.activated(hit, function()
	if cardOpen then
		closeCard()
	else
		openCard()
	end
	-- Felt on the PILL either way. A tap that turns something off still has to
	-- acknowledge that it was a tap.
	nudge()
end)

local function tickCard(st)
	if not cardOpen then
		return
	end
	if os.clock() >= cardUntil then
		closeCard()
		return
	end
	fillCard(st)
end

local function onLive(def)
	-- The kind's own tint, straight off ToastKit, so the pill and the banner it
	-- arrives with are the same colour by construction rather than by agreement.
	local k = ToastKit.KINDS[def.kind] or ToastKit.KINDS.info
	paint(k.tint, true)
	pop()
	ToastKit.banner(def.name, def.kind, 2.6)
	ToastKit.toast(def.blurb, def.kind, 4)
	if def.id == "golden_hour" then
		gradeIn()
	end
end

local function onOver(def)
	paint(IDLE_TINT, false)
	if def and def.id == "golden_hour" then
		gradeOut()
	end
end

paint(IDLE_TINT, false)

--------------------------------------------------------------------------
-- THE TICK
--------------------------------------------------------------------------
local function inTutorial(): boolean
	return player:GetAttribute(TutorialConfig.DoneAttribute) ~= true
end

--[[
	THIS SCRIPT WRITES gui.Enabled ONLY WHEN ITS OWN ANSWER CHANGES, AND THAT IS
	WHAT MAKES THE PILL HIDEABLE AT ALL.

	It used to write `gui.Enabled = true` unconditionally, every frame, from the
	tick below. Every cinematic in this game hides HUDs the same way -- IntroCinema,
	EggClient's hatch, the ferry crossing and the rest each keep a list of ScreenGui
	names, record which were on, switch them off and put them back afterwards --
	and against a script that re-asserts itself sixty times a second that does
	nothing at all. The pill would have blinked straight back on inside one frame,
	over the title card, over the hatch, over the crossing.

	So `want` is what THIS script has decided, and `gui.Enabled` is only touched
	when that decision moves. Anyone else's hide now sticks until they restore it,
	which is the contract those lists are already written to.

	The tick keeps running while hidden on purpose: event transitions still need to
	be noticed, so Golden Hour's warm grade comes up during a cutscene the same as
	it would outside one, and the pill is showing the right thing the instant the
	cinematic hands the screen back.
]]
local want = nil

local function setVisible(v: boolean)
	if want == v then
		return
	end
	want = v
	gui.Enabled = v
	-- A card left open behind a cinematic would be waiting there when the screen
	-- came back, explaining an event that had since ended.
	if not v then
		closeCard()
	end
end

local shown = ""

-- Set by the X, cleared when an event actually starts. See the note on `close`.
-- Activated rather than MouseButton1Click, for the same reason given where
-- `hit` is wired: it is the one that also fires for a tap and for a gamepad,
-- and the X is a phone control before it is a mouse one. Raising it above `hit`
-- gets the press as far as this button; this is what turns the press into a
-- dismissal on the device the bug was worst on. 2026-09-09.
local dismissed = false
close.Activated:Connect(function()
	dismissed = true
end)

RunService.RenderStepped:Connect(function()
	if inTutorial() then
		setVisible(false)
		-- Whatever was up goes with it, so a player who finishes the tutorial
		-- during Golden Hour is not left under a grade nothing explains.
		if lastLive then
			onOver(lastLive)
			lastLive = nil
		end
		return
	end
	setVisible(not dismissed)

	local st = currentState()

	if st.phase == "live" then
		if not lastLive or lastLive.id ~= st.event.id then
			if lastLive then
				onOver(lastLive)
			end
			-- A dismissal is of the countdown, not of the event: something starting
			-- is news, and news outranks a clock the player tidied away.
			dismissed = false
			lastLive = st.event
			onLive(st.event)
		end
	elseif lastLive then
		onOver(lastLive)
		lastLive = nil
	end

	--[[
		WHAT IS RUNNING IS ONLY EVER WRITTEN WHILE THE EVENT IS RUNNING.

		`st.event` is populated in every phase -- the timetable knows perfectly
		well what is next -- and that is exactly the value this must not print.
		The two waiting states say only that something is coming and when.

		AND WHILE IT IS LIVE THE PILL NAMES THE BUFF, NOT THE EVENT.

		The name has already been shouted and cannot be missed: onLive puts it
		across the middle of the screen on a banner with the blurb on a toast
		under it, and someone who joins mid-event gets both, because `lastLive`
		starts nil and the first live tick counts as a transition.

		Both of those are gone after four seconds. The pill is up for the whole
		window -- three minutes of Golden Hour -- so the question it should be
		answering by then is WHAT HAVE I GOT RIGHT NOW, not what it was called.
		A countdown next to a name you can no longer act on is a clock, not a
		buff indicator. `short` has been in the roster all along for exactly
		this and nothing has ever read it.

		MEASURED, the way the rest of this file is. LuckiestGuy 16 against the
		124px label: 2x SALES 67, NO LIMIT 66, FIRST TOUCH 95 -- the widest buff
		is still narrower than GOLDEN CANS at 104, which the slot already held.
		Nothing here needs more room than the names it replaces.

		Falls back to the name so an event added later without a `short` still
		prints something rather than going blank.
	]]
	local text
	if st.phase == "live" then
		text = st.event.short or st.event.name
	elseif st.phase == "soon" then
		text = "STARTING SOON"
	else
		text = "NEXT EVENT"
	end
	if text ~= shown then
		shown = text
		label.Text = text
	end
	clock.Text = EventConfig.clock(st.left)

	-- Off the SAME state the pill just drew, so the card's countdown and the
	-- pill's are the same number rather than two reads a frame apart.
	tickCard(st)
end)

-- UiFit fires immediately with the current scale as well as on every later
-- change, so this needs no opinion about whether UiFitBoot has run yet.
local okFit = pcall(function()
	local UiFit = require(Modules:WaitForChild("UiFit"))
	UiFit.onChanged(refit)
end)
if not okFit then
	refit()
end