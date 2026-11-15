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

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--[[
	MEASURED, in this game's own font, against the longest string each slot can
	hold:

	  "STARTING SOON" at LuckiestGuy 16 is 118px -- the widest label there is,
	      wider than any event name (GOLDEN HOUR is 102)
	  "10:00"         at LuckiestGuy 18 is  46px

	14 of pad, 124 for the label, 12 of gap, 52 for the clock, 14 of pad = 216.
]]
local W, H = 216, 34
local RADIUS = 17
local PAD = 14
local LABEL_W, CLOCK_W = 124, 52
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
label.Position = UDim2.fromOffset(PAD, 0)
label.Size = UDim2.fromOffset(LABEL_W, H)
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextTruncate = Enum.TextTruncate.AtEnd
label.ZIndex = 12
HudKit.punch(label, 2)

local clock = HudKit.text(face, "", 18, HudKit.C.text)
clock.AnchorPoint = Vector2.new(1, 0)
clock.Position = UDim2.new(1, -PAD, 0, 0)
clock.Size = UDim2.fromOffset(CLOCK_W, H)
clock.TextXAlignment = Enum.TextXAlignment.Right
clock.ZIndex = 12
HudKit.punch(clock, 2)

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

local shown = ""

RunService.RenderStepped:Connect(function()
	if inTutorial() then
		if gui.Enabled then
			gui.Enabled = false
			-- Whatever was up goes with it, so a player who finishes the tutorial
			-- during Golden Hour is not left under a grade nothing explains.
			if lastLive then
				onOver(lastLive)
				lastLive = nil
			end
		end
		return
	end
	gui.Enabled = true

	local st = currentState()

	if st.phase == "live" then
		if not lastLive or lastLive.id ~= st.event.id then
			if lastLive then
				onOver(lastLive)
			end
			lastLive = st.event
			onLive(st.event)
		end
	elseif lastLive then
		onOver(lastLive)
		lastLive = nil
	end

	--[[
		THE NAME IS ONLY EVER WRITTEN WHILE THE EVENT IS RUNNING.

		`st.event` is populated in every phase -- the timetable knows perfectly
		well what is next -- and that is exactly the value this must not print.
		The two waiting states say only that something is coming and when.
	]]
	local text
	if st.phase == "live" then
		text = st.event.name
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
