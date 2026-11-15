--[[
	RebirthUnlockPrompt  --  StarterPlayerScripts.RebirthUnlockPrompt  (ModuleScript)

	THE FIRST TIME REBIRTH IS REACHABLE, AND ONLY THE FIRST TIME. A one-shot
	card that tells a brand new tide-turner what rebirthing actually buys --
	the next shore, not just a multiplier -- and offers to point them at the
	boat that sails there. MenuHud's own rebirth panel already carries "the
	only warning in the game before a rebirth"; this is a single interruption
	before that panel is ever needed, not a second copy of it.

	THE SAME TRUTH THE REBIRTH PANEL READS. ProgressionSync already carries
	`canRebirth` and `rebirths`, computed once on the server in
	ProgressionServer.snapshot -- this listens to the same push MenuHud does
	rather than re-deriving the gate from TideEarned and the cost curve a
	second time.

	ONCE PER ACCOUNT. RebirthPromptConfig.SeenAttribute is stamped by
	RebirthPromptServer the moment this card is dismissed (either button, or
	the X) and persisted through SaveService -- see RebirthPromptServer's
	header for why the stamp waits for that rather than for the gate alone.

	WHY NOT TutorialGuide. That module is a single shared pointer owned and
	driven by TutorialHud's own step loop, which retargets it several times a
	second for as long as the onboarding card is open -- a second caller
	pointing it at the ferry mid-tutorial would just lose the fight every
	frame. A player can plausibly still be mid-onboarding at 1,000 coins, so
	this draws its own small, temporary marker instead of borrowing that one.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Net = require(Modules:WaitForChild("Net"))
local PanelKit = require(Modules:WaitForChild("PanelKit"))
-- For `chevron` only -- the screen-edge arrow's shape. See HudKit.chevron for
-- why that build is not as simple as two rotated bars.
local HudKit = require(Modules:WaitForChild("HudKit"))
-- For the arrow's opt-out and its art scale. See trap 3 on the arrow below.
local UiFit = require(Modules:WaitForChild("UiFit"))
local ToastKit = require(Modules:WaitForChild("ToastKit"))
local RebirthPromptConfig = require(Modules:WaitForChild("RebirthPromptConfig"))

-- Touch targets: see the module. Substituted for MouseButton1Click/Activated so
-- a tap in the margin around a control that renders under 44px on a phone still
-- reaches the same handler. No-ops on desktop and on controls already big enough.
local TouchFit = require(Modules:WaitForChild("TouchFit"))

local C = PanelKit.C
local text = PanelKit.text
local punch = PanelKit.punch
local chunky = PanelKit.chunky

local player = Players.LocalPlayer

local RebirthUnlockPrompt = {}

-- Session guard: once the card has gone up (or is known already seen) there
-- is nothing left for this module to watch for.
local armed = false

-- The other two one-shots in this file. `nudged` is the prompt that fires when
-- a player arrives at the boat without having turned the tide (see nudgeTide);
-- `turned` is "a rebirth has landed this session", which is what tells that
-- arrival apart from the guidance run that follows one.
local nudged = false
local turned = false

----------------------------------------------------------------
-- MID-WASH IS NOT THE MOMENT
----------------------------------------------------------------
-- Same signal TutorialGuide's `busy()` reads off: WashClientController
-- publishes no state of its own, but its ScreenGui being enabled IS the
-- state. A scrim and a modal card dropped over a player mid-wash would fight
-- the bay for the same screen.
local function washing(): boolean
	local pg = player:FindFirstChild("PlayerGui")
	local hud = pg and pg:FindFirstChild("WashHud")
	return hud ~= nil and hud:IsA("ScreenGui") and hud.Enabled
end

----------------------------------------------------------------
-- THE BOAT
----------------------------------------------------------------
-- BeachFerry's TalkAnchor -- the exact part FerryServer hangs its own "Sail"
-- ProximityPrompt on (see FerryBuilder: the model is named `port.key .. "Ferry"`
-- and the ferryman's chest part is `TalkAnchor`). Resolved lazily rather than
-- cached at require time: FerryServer.start() builds workspace.Ferries after
-- this module loads, and re-resolving costs two FindFirstChilds.
local function beachTalkAnchor(): BasePart?
	local ferries = workspace:FindFirstChild("Ferries")
	local beach = ferries and ferries:FindFirstChild("BeachFerry")
	local anchor = beach and beach:FindFirstChild("TalkAnchor", true)
	return (anchor and anchor:IsA("BasePart")) and anchor or nil
end

--[[
	A HIGHLIGHT ON SOMETHING BEHIND YOU IS A HIGHLIGHT NOBODY HAS EVER SEEN.

	This was a glow on the ferryman and a billboard over his head, both gone
	after ten seconds. Both only say anything at all to a player already looking
	at him -- so the card told people the Dunes existed and then left them
	turning on the spot on a 256-stud beach. "It messages them but it never
	tells them to go there."

	So the world marks stay, and an ARROW is added: a chevron pinned to the edge
	of the screen whenever the boat is off it, turned to face him, with the
	distance beside it. That is the half that does the work; the glow is only
	what confirms it once you have turned round.

	IT LASTS UNTIL YOU ARRIVE, not for ten seconds. `WAYPOINT_FOR` is a backstop
	for somebody who wanders off, not the intended end -- `ARRIVED` is.

	STILL NOT TutorialGuide, and now for a sharper reason than the header's.
	That module is a single shared pointer driven by TutorialHud's step loop
	several times a second, and this fires at a moment a player can plausibly
	still be mid-onboarding -- so a second caller would lose the fight every
	frame. What the two DO share is the shape: the chevron moved to
	HudKit.chevron rather than being written twice.

	FOUR TRAPS, ALL OF THEM TutorialGuide'S, ALL OF THEM LIVE HERE TOO:

	1. WorldToViewportPoint, NOT WorldToScreenPoint. This gui is
	   IgnoreGuiInset, so its origin is the top-left of the SCREEN, which is
	   viewport space. WorldToScreenPoint subtracts the topbar and would sit the
	   arrow an inset high for the whole run.
	2. A TARGET BEHIND THE CAMERA PROJECTS TO THE WRONG SIDE -- Roblox returns a
	   negative Z and a point mirrored through the screen centre. Negating the
	   offset is the difference between "turn around" and "go the wrong way".
	3. THE POINTER MUST NOT BE UiFit-SCALED: it is placed in raw viewport pixels
	   and UiFit multiplies everything inside a FitRoot by the screen scale. The
	   opt-out is UiFit's own eligibility rule -- it only absorbs children whose
	   Size is PURE OFFSET on both axes -- so the container below is sized in
	   SCALE and carries a UIScale on its ART instead.
	4. AIMED A LITTLE ABOVE THE ANCHOR. The boatman's chest part is the thing
	   being pointed at, and a point at deck height is still effectively off
	   screen when you are stood on the planks in front of him.
]]
local WAYPOINT_FOR = 240   -- seconds before the arrow gives up on you
local ARRIVED = 24         -- studs; his own prompt reaches 19
local EDGE_MARGIN = 78     -- viewport pixels the arrow keeps off the edge
local EDGE_SIZE = 76

local wayGui, wayHolder, wayPointer, wayDist
local wayConn, wayDeadline, wayAnchor
-- The distance line INSIDE the marker over the boatman, as opposed to `wayDist`
-- which is the one beside the screen-edge arrow. Both are driven from wayStep.
local wayNear
local wayMarks = {}

local function buildWaypoint()
	wayGui = Instance.new("ScreenGui")
	wayGui.Name = "RebirthWaypoint"
	wayGui.ResetOnSpawn = false
	wayGui.IgnoreGuiInset = true
	-- Over the rail (12), so a menu key can never hide the arrow, and under the
	-- card itself (15), which is a modal and outranks its own signpost.
	wayGui.DisplayOrder = 13
	wayGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	wayGui.Parent = player:WaitForChild("PlayerGui")

	-- SIZED IN SCALE ON PURPOSE. See trap 3 -- this is UiFit's opt-out and the
	-- reason the pixel maths in wayStep can be taken at face value.
	wayHolder = Instance.new("Frame")
	wayHolder.Name = "Arrow"
	wayHolder.BackgroundTransparency = 1
	wayHolder.Size = UDim2.fromScale(1, 1)
	wayHolder.Visible = false
	wayHolder.Parent = wayGui

	wayPointer = Instance.new("Frame")
	wayPointer.Name = "Pointer"
	wayPointer.BackgroundTransparency = 1
	wayPointer.AnchorPoint = Vector2.new(0.5, 0.5)
	wayPointer.Size = UDim2.fromOffset(EDGE_SIZE, EDGE_SIZE)
	wayPointer.Parent = wayHolder
	-- The art shrinks with the screen even though the POSITION must not.
	local ps = Instance.new("UIScale")
	ps.Parent = wayPointer
	UiFit.onChanged(function(scale)
		ps.Scale = scale
	end)

	local ch = HudKit.chevron(wayPointer, EDGE_SIZE, C.sun, 4)
	ch.Position = UDim2.fromScale(0.5, 0.5)

	--[[
		A SIBLING OF THE POINTER RATHER THAN A CHILD OF IT.

		The pointer spins to face the boat, and anything parented to it spins
		too -- so a caption inside it is upside down for half the circle.
		Counter-rotating fixes the letters and not the POSITION: the label still
		orbits the arrow and ends up off the side of the screen as often as not.
		Placed independently, a little way back along the same ray, it is always
		inboard of the arrow and always level.
	]]
	wayDist = text(wayHolder, "", 18, Enum.Font.LuckiestGuy, C.white)
	wayDist.Name = "Distance"
	wayDist.AnchorPoint = Vector2.new(0.5, 0.5)
	wayDist.Size = UDim2.fromOffset(90, 22)
	wayDist.ZIndex = 8
	punch(wayDist, 4)
	local ds = Instance.new("UIScale")
	ds.Parent = wayDist
	UiFit.onChanged(function(scale)
		ds.Scale = scale
	end)
end

local function stopWaypoint()
	if wayConn then
		wayConn:Disconnect()
		wayConn = nil
	end
	if wayHolder then
		wayHolder.Visible = false
	end
	wayAnchor = nil
	wayNear = nil
	-- The glow and the billboard go with the arrow: all three are one
	-- instruction, and a label left floating over a boatman the player is
	-- already standing next to is the worst of the three to leave behind.
	for _, inst in ipairs(wayMarks) do
		if inst.Parent then
			inst:Destroy()
		end
	end
	table.clear(wayMarks)
end

--[[
	ARRIVING AT THE BOAT IS NOT THE END OF THE ERRAND, AND IT WAS BEING TREATED
	AS ONE.

	The card offers the boat BEFORE the tide has turned -- that is the shape of
	the whole thing: "a rebirth opens the Dunes, and here is the boat that sails
	there". So a player who presses SHOW ME THE BOAT walks the length of the
	beach, arrives, and finds that Sandy Salt will not take them anywhere: the
	Dunes card in his panel reads "1 REBIRTH", and nothing on the screen says
	where a rebirth is bought. The arrival branch in wayStep then stopped the
	waypoint on the note that "his own prompt takes over" -- true, and not
	enough, because his prompt is the thing refusing them. The errand ended by
	leaving the player standing at a locked boat.

	SO IT FINISHES HERE INSTEAD, with the panel that actually turns the tide put
	in front of them. The panel rather than a second card of our own: it already
	carries the progress bar, the only warning in the game before a rebirth, and
	the button itself, so there is nothing to restate here and nothing to keep in
	step with it later. The toast says why it opened, which is the one thing the
	panel cannot know.

	IT MUST NOT FIRE ON THE OTHER GUIDANCE RUN. `guideToBoat` is called a second
	time on the first LANDING, when the tide HAS turned and the boat genuinely is
	the answer -- so this checks two independent routes to "they have already
	turned it": `turned`, set the moment a rebirth lands, which cannot be beaten
	by a snapshot still in flight; and the Rebirths attribute, which is the one
	that is still right for a client that rejoined and never saw a land event.
]]
local function menuHud()
	local mod = script.Parent:FindFirstChild("MenuHud")
	if not (mod and mod:IsA("ModuleScript")) then
		return nil
	end
	-- Resolved lazily rather than at the top of this file. ClientMain requires
	-- MenuHud before this module either way, so by the time anybody arrives at a
	-- boat this is a cache read -- and a require up there would tie this file's
	-- load order to that one's for no gain.
	local ok, hud = pcall(require, mod)
	return (ok and type(hud) == "table" and type(hud.open) == "function") and hud or nil
end

local function nudgeTide()
	if nudged or turned then
		return
	end
	if (tonumber(player:GetAttribute("Rebirths")) or 0) > 0 then
		return
	end
	nudged = true

	local hud = menuHud()
	if hud then
		hud.open("Rebirth")
		pcall(ToastKit.toast, "Sandy Salt sails to the Dunes once the tide has turned.", "good", 6)
	else
		-- The panel could not be reached, so naming the key IS the instruction --
		-- it cannot be left implied by a panel that never opened.
		pcall(ToastKit.toast,
			"Turn the tide first -- open the Rebirth panel on the right, then sail.", "good", 7)
	end
end

local function wayStep()
	local anchor = wayAnchor
	local cam = workspace.CurrentCamera
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (anchor and anchor.Parent and cam and root and cam.ViewportSize.Y > 1) then
		return
	end
	if os.clock() > wayDeadline then
		stopWaypoint()
		return
	end

	local here, there = root.Position, anchor.Position
	local span = (Vector3.new(here.X, 0, here.Z) - Vector3.new(there.X, 0, there.Z)).Magnitude
	-- Written in BOTH places every frame. The marker over his head is the only
	-- thing on screen once he is in view, so it carries the range too rather
	-- than leaving the player to judge four hundred studs by eye.
	if wayNear then
		wayNear.Text = string.format("%dm", math.max(1, math.floor(span + 0.5)))
	end
	if span <= ARRIVED then
		-- Standing at the boat. The signpost's job is done...
		stopWaypoint()
		-- ...but if the tide has not turned yet, his own prompt is about to
		-- REFUSE them, which is where this errand used to end. See nudgeTide.
		nudgeTide()
		return
	end

	local screen = cam:WorldToViewportPoint(there + Vector3.new(0, 3, 0))  -- traps 1 and 4
	local vp = cam.ViewportSize
	local cx, cy = vp.X * 0.5, vp.Y * 0.5
	local dx, dy = screen.X - cx, screen.Y - cy
	if screen.Z < 0 then
		dx, dy = -dx, -dy                                                   -- trap 2
	end

	--[[
		THE SAFE RECT IS NOT SYMMETRICAL, because the right-hand edge of this
		screen is not empty: the menu rail is parked against it all session, and
		an arrow pinned at the ordinary margin lands squarely on the SHOP key.

		MEASURED OFF THE RAIL RATHER THAN SUBTRACTING A CONSTANT. Its width is
		not fixed -- MenuHud shrinks it to fit a short screen and, since the jump
		button fix, SIDESTEPS it left of the corner on a phone -- so a hard-coded
		92 would be wrong on exactly the devices that have least room to spare.
		Its AbsolutePosition and this pointer's offsets share an x axis (the gui
		inset only moves y), so the two compare directly.
	]]
	local limY = math.max(1, cy - EDGE_MARGIN)
	local limX = math.max(1, cx - EDGE_MARGIN)
	if dx >= 0 then
		local pg = player:FindFirstChild("PlayerGui")
		local menu = pg and pg:FindFirstChild("BeachMenuHud")
		local rail = menu and menu:FindFirstChild("Rail", true)
		if rail and rail:IsA("GuiObject") and rail.AbsoluteSize.X > 0 then
			limX = math.max(1, math.min(limX,
				rail.AbsolutePosition.X - EDGE_SIZE * 0.5 - 10 - cx))
		end
	end
	-- How far along the ray from the centre the screen edge is. Below 1 the
	-- boat is outside the safe rect, which is the whole test.
	local reach = math.min(limX / math.max(math.abs(dx), 1e-3),
		limY / math.max(math.abs(dy), 1e-3))

	if not ((screen.Z < 0) or reach < 1) then
		-- He is on screen, and the glow round him says the rest.
		wayHolder.Visible = false
		return
	end

	wayHolder.Visible = true
	wayPointer.Position = UDim2.fromOffset(cx + dx * reach, cy + dy * reach)
	-- The art points UP at zero, so a target due right (+x) wants a quarter
	-- turn clockwise -- hence the +90.
	wayPointer.Rotation = math.deg(math.atan2(dy, dx)) + 90
	local back = math.max(0, reach - EDGE_SIZE / math.max(math.sqrt(dx * dx + dy * dy), 1e-3))
	wayDist.Position = UDim2.fromOffset(cx + dx * back, cy + dy * back)
	wayDist.Text = string.format("%dm", math.max(1, math.floor(span + 0.5)))
end

--[[
	POINT THEM AT THE BOAT, and keep pointing until they get there.

	The ferry is the target rather than the Dunes themselves, which is the whole
	shape of the trip: the Dunes are 1,500 studs away across open water and the
	only way to them is Sandy Salt's boat.
]]
local function guideToBoat(why: string?)
	local anchor = beachTalkAnchor()
	if not anchor then
		-- FerryServer builds the berths at boot, so this only fails if the beach
		-- berth threw. Say something rather than pointing at nothing.
		pcall(ToastKit.toast, "Turn the tide, then sail from the Beach Ferry.", "good", 5)
		return
	end

	stopWaypoint()   -- idempotent: a second press re-arms rather than stacking
	if not wayGui then
		buildWaypoint()
	end

	local ferryman = anchor.Parent
	local adornee = (ferryman and ferryman:IsA("Model")) and ferryman or anchor

	local hl = Instance.new("Highlight")
	hl.Name = "RebirthPromptHighlight"
	hl.FillColor = C.sun
	hl.FillTransparency = 0.55
	hl.OutlineColor = C.white
	hl.OutlineTransparency = 0
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Adornee = adornee
	hl.Parent = adornee
	table.insert(wayMarks, hl)

	--[[
		A MARKER, NOT A CAPTION.

		This was bare white type with a stroke on it, and measured against what it
		is actually drawn over -- palms, four shopfronts, ninety pieces of litter
		and a bright sea -- 24px of floating text at three hundred studs is
		perfectly legible once found and genuinely hard to FIND. A filled pill in
		the rail's own sun yellow, with the ink outline every other surface in the
		game wears, is what makes it read as a marker at a glance.

		SIZED IN PIXELS RATHER THAN STUDS, so it stays exactly this big at any
		range: the one moment it has to be readable is the moment the boat is far
		enough away to be a speck. TutorialGuide's marker records the same choice
		for the same reason.

		MaxDistance 900, up from 500. The home beach's sea wall measures 769 x 863
		studs (see the [SeaWall] boot line) and the whole job of this thing is to
		be visible from the far corner of it -- at 500 it switched off somewhere
		in the middle of the sand, which is exactly where somebody lost enough to
		need it is standing.
	]]
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "RebirthPromptLabel"
	billboard.Adornee = anchor
	billboard.Size = UDim2.fromOffset(196, 78)
	billboard.StudsOffset = Vector3.new(0, 6.5, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 900
	billboard.Parent = anchor
	table.insert(wayMarks, billboard)

	local pill = Instance.new("Frame")
	pill.Name = "Pill"
	pill.Size = UDim2.fromOffset(196, 74)
	pill.BackgroundColor3 = C.sun
	pill.BorderSizePixel = 0
	pill.Parent = billboard
	PanelKit.corner(pill, 16)
	PanelKit.outline(pill, 4)
	PanelKit.grad(pill, C.sun, PanelKit.darken(C.sun, 0.18))
	PanelKit.gloss(pill, 16)

	local label = text(pill, "SAIL HERE", 22, Enum.Font.LuckiestGuy, C.white)
	label.Position = UDim2.fromOffset(0, 6)
	label.Size = UDim2.new(1, 0, 0, 28)
	label.ZIndex = 6
	punch(label, 3)

	wayNear = text(pill, "", 17, Enum.Font.LuckiestGuy, C.white)
	wayNear.Name = "Range"
	wayNear.Position = UDim2.fromOffset(0, 38)
	wayNear.Size = UDim2.new(1, 0, 0, 26)
	wayNear.ZIndex = 6
	punch(wayNear, 2.5)

	-- Belt and braces on top of stopWaypoint's own destroy: a client that
	-- errors out of the render loop must not leave a glow on the beach forever.
	Debris:AddItem(hl, WAYPOINT_FOR + 15)
	Debris:AddItem(billboard, WAYPOINT_FOR + 15)

	wayAnchor = anchor
	wayDeadline = os.clock() + WAYPOINT_FOR
	if not wayConn then
		-- RenderStepped, not Heartbeat: the arrow is placed off the camera, and a
		-- frame of lag shows up as it swimming behind the view on every turn.
		wayConn = RunService.RenderStepped:Connect(function()
			local ok, err = pcall(wayStep)
			if not ok then
				warn("[CleanTheBeach] rebirth waypoint stopped: " .. tostring(err))
				stopWaypoint()
			end
		end)
	end

	pcall(ToastKit.toast, why or "Sandy Salt is waiting at the Beach Ferry.", "good", 4)
end

----------------------------------------------------------------
-- THE CARD
----------------------------------------------------------------
-- 424 body width (see PanelKit.card: body is `w - 36`) split evenly across
-- two chunky buttons with a 4px gap: 210 + 4 + 210 = 424.
--
-- HEIGHT IS MEASURED OFF THE CONTENT rather than picked: body is `h - 74`, and
-- the tallest thing in it is the blurb (104) plus a gap (16) plus a chunky
-- button (56, and its shadow slab adds 7) = 183, which wants 257. 320 left
-- eighty pixels of empty well between the paragraph and the buttons, which
-- reads as a panel that has not finished loading.
local W, H = 460, 276

local gui, root, closeFace, yesFace, laterFace

local function setScrim(on: boolean)
	local scrim = gui and gui:FindFirstChild("Scrim")
	if not scrim then
		return
	end
	TweenService:Create(scrim, TweenInfo.new(on and 0.18 or 0.14),
		{ BackgroundTransparency = on and 0.5 or 1 }):Play()
end

local function build()
	local g = Instance.new("ScreenGui")
	g.Name = "RebirthUnlockPrompt"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	-- Above the rail (12) and TutorialHud's card (11): this is a one-shot
	-- interrupt, not chrome that lives beside them.
	g.DisplayOrder = 15
	g.ZIndexBehavior = Enum.ZIndexBehavior.Global
	g.Enabled = false
	g.Parent = player:WaitForChild("PlayerGui")

	-- INERT ON PURPOSE, the same contract MenuHud's own scrim keeps: not
	-- Active, not a button, so it dims the beach behind the card without ever
	-- being the thing a click lands on.
	local scrim = Instance.new("Frame")
	scrim.Name = "Scrim"
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.BackgroundColor3 = Color3.new(0, 0, 0)
	scrim.BackgroundTransparency = 1
	scrim.BorderSizePixel = 0
	scrim.ZIndex = 0
	scrim.Parent = g

	local r, body, cFace = PanelKit.card(g, "The Tide Can Turn", W, H, C.sea)
	r.Visible = false

	--[[
		WARM LIGHT SAND, NOT `C.ink`, AND THE DIFFERENCE IS LEGIBILITY RATHER THAN
		TASTE.

		PanelKit.card lays a dark wood WELL under the body -- a gradient running
		(66, 42, 26) to (104, 70, 44) -- and `C.ink` is (56, 36, 20), which is
		DARKER THAN THE BOARD IT IS PRINTED ON. The paragraph came out near-black
		on brown and could not be read at all.

		This is the same colour, for the same reason, that MenuHud's own rebirth
		panel gives its warning paragraph -- and that panel's note is the one that
		spells the trap out: "this whole family of browns was chosen to sit on
		cream and is unreadable on the board -- anything drawn straight onto
		`body` had to come up with it". Every dark ink in PanelKit.C is a cream
		colour scheme's leftover; the well is not cream.
	]]
	local blurb = text(body,
		"You have done enough to rebirth for the first time. Turning the tide "
			.. "resets your coins and every upgrade, leaves a permanent bonus on "
			.. "everything you sell -- and opens The Dunes, reachable by boat from "
			.. "the Beach Ferry.",
		16, Enum.Font.GothamMedium, Color3.fromRGB(226, 206, 176))
	blurb.Position = UDim2.fromOffset(4, 0)
	-- 104, not 150: the copy wraps to four lines at this width (about 64px) and
	-- the old box was most of the empty space above. Still room for six.
	blurb.Size = UDim2.new(1, -8, 0, 104)
	blurb.TextWrapped = true
	blurb.TextYAlignment = Enum.TextYAlignment.Top

	local yesHolder, yFace = chunky(body, 210, 56, C.sun, 18)
	yesHolder.Name = "YesHolder"
	yesHolder.Position = UDim2.fromOffset(0, 120)
	local yesLabel = text(yFace, "SHOW ME THE BOAT", 15, Enum.Font.LuckiestGuy, C.white)
	yesLabel.Size = UDim2.new(1, -6, 1, 0)
	yesLabel.TextWrapped = true
	punch(yesLabel, 2.5)

	local laterHolder, lFace = chunky(body, 210, 56, C.sandDeep, 18)
	laterHolder.Name = "LaterHolder"
	laterHolder.Position = UDim2.fromOffset(214, 120)
	local laterLabel = text(lFace, "MAYBE LATER", 15, Enum.Font.LuckiestGuy, C.white)
	laterLabel.Size = UDim2.new(1, -6, 1, 0)
	laterLabel.TextWrapped = true
	punch(laterLabel, 2.5)

	return g, r, cFace, yFace, lFace
end

local function hide()
	setScrim(false)
	if root then
		root.Visible = false
	end
	local g = gui
	task.delay(0.2, function()
		if g then
			g.Enabled = false
		end
	end)
end

-- Fires on EITHER button, and on the X: "seen" means the card was put in
-- front of the player and answered, not that they said yes to anything.
local function dismiss()
	hide()
	pcall(function()
		Net.get("RebirthPromptSeen"):FireServer()
	end)
end

local function show()
	if not gui then
		gui, root, closeFace, yesFace, laterFace = build()
		TouchFit.press(closeFace, dismiss)
		TouchFit.press(yesFace, function()
			dismiss()
			guideToBoat()
		end)
		TouchFit.press(laterFace, dismiss)
	end
	gui.Enabled = true
	setScrim(true)
	PanelKit.popIn(root, W, H)
end

----------------------------------------------------------------
-- WHEN TO SHOW IT
----------------------------------------------------------------
local function maybeShow(snap)
	if armed then
		return
	end
	if player:GetAttribute(RebirthPromptConfig.SeenAttribute) then
		armed = true
		return
	end
	if type(snap) ~= "table" then
		return
	end
	-- Rebirths > 0 means this is not their FIRST unlock any more, whatever the
	-- gate is currently doing -- the counter only ever increments, so this can
	-- never fire again once it has been true once.
	if (tonumber(snap.rebirths) or 0) > 0 then
		return
	end
	if not snap.canRebirth then
		return
	end
	armed = true

	if washing() then
		-- Polled rather than event-driven: WashHud publishes no signal of its
		-- own for "closed", and this fires at most once per account ever, so a
		-- cheap poll costs nothing worth avoiding.
		task.spawn(function()
			while washing() do
				task.wait(1)
			end
			show()
		end)
		return
	end
	show()
end

--[[
	WAIT OUT THE REBIRTH CINEMATIC.

	RebirthCinema holds full black for `HOLD` and then fades for `LIFT`, and an
	arrow drawn under that is an arrow nobody sees. Those are ITS constants to
	retune though, not this file's to copy -- so this watches its curtain rather
	than running a timer that agrees with it today. Same trick TutorialHud's
	awaitIntro uses on the opening shot, and it cannot drift.

	Bounded, and it falls through rather than giving up: a cinematic that never
	finishes must not also cost the player the one signpost to the new island.
]]
local function awaitCurtain()
	local pg = player:FindFirstChild("PlayerGui")
	local cinema = pg and pg:FindFirstChild("RebirthCinema")
	local curtain = cinema and cinema:FindFirstChild("Curtain")
	if not (curtain and curtain:IsA("GuiObject")) then
		task.wait(2.5)
		return
	end
	local deadline = os.clock() + 12
	while os.clock() < deadline do
		if not curtain.Visible or curtain.BackgroundTransparency >= 0.95 then
			return
		end
		task.wait(0.15)
	end
end

function RebirthUnlockPrompt.start()
	Net.get("ProgressionSync").OnClientEvent:Connect(maybeShow)

	--[[
		THE SECOND MOMENT, AND IT IS THE ONE THAT ACTUALLY MATTERS.

		The card is an OFFER, fired before a rebirth, and a good half of the
		players who see it will press MAYBE LATER. The Dunes open when the
		rebirth actually LANDS -- and until now nothing marked that at all: the
		server's "The tide turns!" toast names a multiplier, the player is set
		down on the spawn pad, and a whole new island has quietly become
		reachable with nothing anywhere saying how.

		So the arrow is drawn again on the first landing, whatever they answered
		to the card and whether or not they ever saw it.

		`rebirths == 1` IS THE WHOLE GUARD, and it needs no flag of its own: the
		counter only ever increments, so this can fire exactly once per account.
		It is deliberately NOT gated on RebirthPromptConfig.SeenAttribute either
		-- somebody who dismissed the card with the X still has to be told where
		the boat is.
	]]
	Net.get("RebirthAscend").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or payload.phase ~= "land" then
			return
		end
		-- ANY landing, and ahead of the first-rebirth guard below on purpose:
		-- from here on the boat is the answer, so the arrival nudge must never
		-- fire again. This is the immediate half of that check -- nudgeTide
		-- carries the other, for a client that rejoined instead.
		turned = true
		if (tonumber(payload.rebirths) or 0) ~= 1 then
			return
		end
		task.spawn(function()
			awaitCurtain()
			-- A breath after the beach is back, so the arrow reads as something
			-- new rather than as the last frame of the cinematic.
			task.wait(0.6)
			guideToBoat("The Dunes are open! Sail from the Beach Ferry.")
		end)
	end)
end

return RebirthUnlockPrompt