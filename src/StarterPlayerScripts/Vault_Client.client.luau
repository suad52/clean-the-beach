--[[
	Vault_Client  --  StarterPlayer.StarterPlayerScripts.Vault_Client

	The treasure chamber's presentation: the black-screen transition, the refusal
	when the tomb is still sealed, the room's light and air, and the feedback for
	sweeping gold off its floor.

	The chamber ITSELF is a normal rakeable field (Config.ISLANDS[3]) -- the
	server grid, the finds, the sell pad and the clear bonus are the same
	machinery the beaches use, and CTB_Client scatters its litter from the
	Treasure set exactly as it scatters cans on the sand. Nothing in this file is
	load-bearing for that; it is all the layer on top.

	THE FADE IS ON A CLOCK, NOT A HANDSHAKE. Both sides read Config.CINEMA and
	run their own half. A dropped message can make the timing slightly wrong; it
	can never leave a player stuck looking at black.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

local player = Players.LocalPlayer
local CTB = ReplicatedStorage:WaitForChild("CTB")
local Config = require(CTB:WaitForChild("Config"))
local Motion = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Motion"))
local Net = CTB:WaitForChild("Net")

local VAULT = Config.island(3)
local CINEMA = Config.CINEMA

local GOLD = Color3.fromRGB(242, 196, 84)
local INK = Color3.fromRGB(56, 36, 20)

----------------------------------------------------------------
-- Screen
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "VaultCinema"
gui.ResetOnSpawn = false          -- a respawn mid-fade must not strand the black frame
gui.IgnoreGuiInset = true
gui.DisplayOrder = 200            -- over the HUD; this is a curtain, not a panel
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = player:WaitForChild("PlayerGui")

local curtain = Instance.new("Frame")
curtain.Name = "Curtain"
curtain.Size = UDim2.fromScale(1, 1)
curtain.BackgroundColor3 = Color3.new(0, 0, 0)
curtain.BackgroundTransparency = 1
curtain.BorderSizePixel = 0
curtain.Visible = false
curtain.ZIndex = 1
curtain.Parent = gui

local caption = Instance.new("TextLabel")
caption.Name = "Caption"
caption.AnchorPoint = Vector2.new(0.5, 0.5)
caption.Position = UDim2.fromScale(0.5, 0.5)
caption.Size = UDim2.fromScale(0.8, 0.16)
caption.BackgroundTransparency = 1
caption.Font = Enum.Font.LuckiestGuy
caption.Text = ""
caption.TextColor3 = GOLD
caption.TextTransparency = 1
caption.TextScaled = true
caption.ZIndex = 7
-- On the GUI, not on the curtain. The curtain no longer merely fades -- it is
-- handed off to two halves that drive off the top and bottom of the screen --
-- and a title parented to it would ride away with them.
caption.Parent = gui

local capSize = Instance.new("UITextSizeConstraint")
capSize.MaxTextSize = 54
capSize.Parent = caption

--[[
	THE TOMB'S OWN SECOND LINE -- and only the DEFAULT, not the only one.

	This whole cinema is reused: ShrineBuilder and MagmaBuilder fire the same
	"Cinema" message for their own doors, so for a while every chamber in the
	game announced itself as sealed for three thousand years. It is true of
	exactly one of them.

	The caption always came from the server; the subtitle does too now, as the
	argument after `kind`. A caller that sends none still gets this one, which
	keeps the tomb's own line where the tomb's own cinema is.
]]
local SUBTITLE = "SEALED FOR THREE THOUSAND YEARS"

-- And the refusal card's HEADLINE, which was the tomb's in the same way and for
-- the same reason. Only the default now -- a door that names its room gets its
-- own line. See showSealed.
local SEALED_TITLE = "THE TOMB IS SEALED"

local subcap = caption:Clone()
subcap.Name = "Subcaption"
subcap.Position = UDim2.fromScale(0.5, 0.605)
subcap.Size = UDim2.fromScale(0.7, 0.05)
subcap.TextColor3 = Color3.fromRGB(226, 208, 178)
subcap.Text = ""
subcap.Parent = gui
subcap:FindFirstChildOfClass("UITextSizeConstraint").MaxTextSize = 22

----------------------------------------------------------------
-- The cut
--
-- Three more pieces of screen, all idle until a transition runs:
--
--   flash    one frame of gold over the whole screen on the cut. What it
--            replaces is a 0.9 second cross-dissolve, which is the correct
--            treatment for going to sleep and the wrong one for a stone door
--            grinding open in front of you.
--   wipeTop  the black, once the curtain has handed it over. These OPEN --
--   wipeBot  driven off the top and bottom edges -- rather than dissolving.
--            A cross-fade reads as "loading finished"; a wipe reads as "look".
--   barTop   letterbox. Cheap, and nothing else says "this is a cutscene, your
--   barBot   hands are off the controls for four seconds" as fast.
----------------------------------------------------------------
local function panel(name: string, anchor: Vector2, pos: UDim2, z: number, colour: Color3?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.AnchorPoint = anchor
	f.Position = pos
	f.Size = UDim2.fromScale(1, 0)
	f.BackgroundColor3 = colour or Color3.new(0, 0, 0)
	f.BorderSizePixel = 0
	f.Visible = false
	f.ZIndex = z
	f.Parent = gui
	return f
end

local wipeTop = panel("WipeTop", Vector2.new(0, 0), UDim2.fromScale(0, 0), 2)
local wipeBot = panel("WipeBot", Vector2.new(0, 1), UDim2.fromScale(0, 1), 2)
local barTop = panel("BarTop", Vector2.new(0, 0), UDim2.fromScale(0, 0), 5)
local barBot = panel("BarBot", Vector2.new(0, 1), UDim2.fromScale(0, 1), 5)

local flash = Instance.new("Frame")
flash.Name = "Flash"
flash.Size = UDim2.fromScale(1, 1)
flash.BackgroundColor3 = Color3.fromRGB(255, 240, 205)
flash.BackgroundTransparency = 1
flash.BorderSizePixel = 0
flash.Visible = false
flash.ZIndex = 3
flash.Parent = gui

local BAR = 0.105

local function showBars(on: boolean)
	local info = TweenInfo.new(on and 0.45 or 0.7, Enum.EasingStyle.Quart,
		on and Enum.EasingDirection.Out or Enum.EasingDirection.InOut)
	barTop.Visible, barBot.Visible = true, true
	local to = UDim2.fromScale(1, on and BAR or 0)
	TweenService:Create(barTop, info, { Size = to }):Play()
	local t = TweenService:Create(barBot, info, { Size = to })
	t.Completed:Connect(function()
		-- Only if they are still shut. A transition starting during the retract
		-- re-opens them, and this completion must not then hide them again.
		if barBot.Size.Y.Scale <= 0.001 then
			barTop.Visible, barBot.Visible = false, false
		end
	end)
	t:Play()
end

----------------------------------------------------------------
-- "The tomb is sealed"
--
-- The door refuses on the server and says why here. A locked thing that gives
-- no reason is indistinguishable from a broken thing, and this one is behind
-- two rebirths -- the player has to know that is what they are looking at.
----------------------------------------------------------------
local notice = Instance.new("Frame")
notice.Name = "SealedNotice"
notice.AnchorPoint = Vector2.new(0.5, 0)
notice.Position = UDim2.new(0.5, 0, 0, 130)
notice.Size = UDim2.new(0, 430, 0, 118)
notice.BackgroundColor3 = Color3.fromRGB(38, 26, 16)
notice.BackgroundTransparency = 1
notice.BorderSizePixel = 0
notice.Visible = false
notice.ZIndex = 4
notice.Parent = gui
local nCorner = Instance.new("UICorner")
nCorner.CornerRadius = UDim.new(0, 16)
nCorner.Parent = notice
local nStroke = Instance.new("UIStroke")
nStroke.Color = GOLD
nStroke.Thickness = 3
nStroke.Transparency = 1
nStroke.Parent = notice

local nTitle = Instance.new("TextLabel")
nTitle.Size = UDim2.new(1, -24, 0, 42)
nTitle.Position = UDim2.new(0, 12, 0, 12)
nTitle.BackgroundTransparency = 1
nTitle.Font = Enum.Font.LuckiestGuy
nTitle.Text = SEALED_TITLE
nTitle.TextColor3 = GOLD
nTitle.TextTransparency = 1
nTitle.TextScaled = true
nTitle.ZIndex = 5
nTitle.Parent = notice

local nBody = Instance.new("TextLabel")
nBody.Size = UDim2.new(1, -24, 0, 52)
nBody.Position = UDim2.new(0, 12, 0, 56)
nBody.BackgroundTransparency = 1
nBody.Font = Enum.Font.GothamMedium
nBody.Text = ""
nBody.TextColor3 = Color3.fromRGB(255, 238, 208)
nBody.TextTransparency = 1
nBody.TextScaled = true
nBody.ZIndex = 5
nBody.Parent = notice
local bodySize = Instance.new("UITextSizeConstraint")
bodySize.MaxTextSize = 20
bodySize.Parent = nBody

local noticeEpoch = 0

local function showSealed(needed: number, have: number, room: string?)
	noticeEpoch += 1
	local mine = noticeEpoch
	--[[
		HEADED WITH THE ROOM THE PLAYER IS ACTUALLY STANDING AT.

		This card read "THE TOMB IS SEALED" at all three doors, because the tomb
		is the door it was written for -- so the Inner Shrine and the Magma
		Chamber both named a room 1500 and 5200 studs away, and at those gates it
		is a room the player cleared long ago. The rebirth line underneath was
		right the whole time; only the headline lied. Fixed 2026-09-09.

		`room` is the door's own Config.ISLANDS name, sent as the argument after
		`have` -- the same split the subtitle above uses, and for the same reason:
		a caller that sends none still gets the tomb's line, which is what
		Island2Builder's door does and what keeps that door reading as it always
		has without a change in a file this one does not own.
	]]
	nTitle.Text = room and string.format("THE %s IS SEALED", string.upper(room))
		or SEALED_TITLE
	nBody.Text = string.format("Reach Rebirth %d to enter.    You have %d of %d.", needed, have, needed)
	notice.Visible = true

	local show = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	notice.Position = UDim2.new(0.5, 0, 0, 104)
	TweenService:Create(notice, show, { BackgroundTransparency = 0.08, Position = UDim2.new(0.5, 0, 0, 130) }):Play()
	TweenService:Create(nStroke, show, { Transparency = 0 }):Play()
	TweenService:Create(nTitle, show, { TextTransparency = 0 }):Play()
	TweenService:Create(nBody, show, { TextTransparency = 0 }):Play()

	task.delay(4.6, function()
		if noticeEpoch ~= mine then
			return
		end
		local hide = TweenInfo.new(0.4)
		TweenService:Create(notice, hide, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(nStroke, hide, { Transparency = 1 }):Play()
		TweenService:Create(nTitle, hide, { TextTransparency = 1 }):Play()
		TweenService:Create(nBody, hide, { TextTransparency = 1 }):Play()
		task.delay(0.45, function()
			if noticeEpoch == mine then
				notice.Visible = false
			end
		end)
	end)
end

----------------------------------------------------------------
-- AND THE SIGN ON THE DOOR ITSELF
--
-- The Inner Shrine's doors and the Magma Chamber's slab both read TAP TO ENTER
-- to every player whatever their rebirth count, so somebody six tides short of
-- the shrine (or ten short of the chamber) was invited to click a door whose
-- only possible answer is to strain and settle back. That is indistinguishable
-- from a broken door and was reported as one. The card above only appears AFTER
-- the click; the sign is what they read before it. Fixed 2026-09-09.
--
-- THE PYRAMID ALREADY SOLVED THIS AND THIS IS ITS ROUTE, not a second one: the
-- builder publishes the gate onto the label, the client repaints it per player,
-- and it is RE-RESOLVED EVERY PASS rather than cached. StreamingEnabled is on
-- and both doors are thousands of studs from the beach, so these labels do not
-- exist on this client at all most of the time and are destroyed and rebuilt
-- every time the player leaves and comes back -- a captured instance would go
-- stale and the door would be back to inviting a click it is going to refuse.
-- (Island2_Client does exactly this for the tomb and records the same finding.)
--
-- WHAT IT SAYS WHEN IT IS OPEN COMES OFF THE LABEL, not out of this file:
-- ShrineBuilder and MagmaBuilder stamp OpenText / OpenTint / OpenEdge on it
-- from the label SignKit has just dressed, so each door keeps its own wording
-- and its own accent -- the shrine's cream, the chamber's ember -- and there is
-- no second copy of either over here to drift.
--
-- A label with no RequireRebirths attribute is not ours and is left alone.
-- That is what keeps this off the tomb's own label, where Island2_Client is
-- already doing the job.
----------------------------------------------------------------
do
	-- The two entrance models, under the names ShrineBuilder.ENTRY_NAME and
	-- MagmaBuilder.ENTRY_NAME give them.
	local DOOR_ROOTS = { "CoveShrine", "AshfallPortal", "PenguinPortal" }

	-- The tomb's locked pair, so all three doors go the same colour when they
	-- refuse. Only these two are constants: the OPEN colours belong to the door.
	local LOCKED_TINT = Color3.fromRGB(255, 168, 146)
	local LOCKED_EDGE = Color3.fromRGB(78, 24, 20)

	local function paintHint(label: TextLabel)
		local needed = label:GetAttribute("RequireRebirths")
		if type(needed) ~= "number" then
			return
		end
		local open = (player:GetAttribute("Rebirths") or 0) >= needed
		local want = open and (label:GetAttribute("OpenText") or "TAP TO ENTER")
			or string.format("SEALED \u{2014} %d REBIRTH%s", needed, needed == 1 and "" or "S")
		-- Written only when it is actually wrong: this runs once a second for the
		-- whole session and a no-op assignment to Text is not free.
		if label.Text ~= want then
			label.Text = want
		end
		label.TextColor3 = open and (label:GetAttribute("OpenTint") or label.TextColor3)
			or LOCKED_TINT
		-- SignKit.floating outlines the glyphs, and the stroke has to move with
		-- the fill or ember letters end up wearing the locked colour's edge.
		local edge = label:FindFirstChildOfClass("UIStroke")
		if edge then
			edge.Color = open and (label:GetAttribute("OpenEdge") or edge.Color) or LOCKED_EDGE
		end
	end

	local function paintDoorHints()
		for _, name in ipairs(DOOR_ROOTS) do
			local doorRoot = workspace:FindFirstChild(name)
			local hint = doorRoot and doorRoot:FindFirstChild("DoorHint", true)
			local label = hint and hint:FindFirstChildWhichIsA("TextLabel")
			if label then
				paintHint(label)
			end
		end
	end

	-- A rebirth is exactly the moment these change, and the player is standing
	-- on a beach hundreds of studs away when it happens -- so without this the
	-- door still reads SEALED when they next walk up to it.
	player:GetAttributeChangedSignal("Rebirths"):Connect(paintDoorHints)

	task.spawn(function()
		while true do
			paintDoorHints()
			task.wait(1)
		end
	end)
end

----------------------------------------------------------------
-- Sound
----------------------------------------------------------------
local function soundGroup(name: string): SoundGroup
	local g = SoundService:FindFirstChild(name)
	if not g then
		g = Instance.new("SoundGroup")
		g.Name = name
		g.Parent = SoundService
	end
	return g
end
local sfxGroup = soundGroup("BeachSFX")

local function mkSound(id: string, vol: number, speed: number, looped: boolean): Sound
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = vol
	s.PlaybackSpeed = speed
	s.Looped = looped or false
	s.SoundGroup = sfxGroup
	s.Parent = SoundService
	return s
end

-- Licensed catalogue only, and both were checked for a non-zero TimeLength
-- before being written in -- creator-uploaded audio is private and fails
-- silently. The chime is an engine asset, which always plays.
local whoosh = mkSound("rbxassetid://9125742262", 0.5, 0.68, false)
local drone = mkSound("rbxassetid://9125602882", 0, 0.8, true)
local chime = mkSound("rbxasset://sounds/electronicpingshort.wav", 0.34, 1.5, false)
local fanfare = mkSound("rbxassetid://9125602882", 0.55, 1.25, false)

-- The descent. A riser that climbs the whole time the door is grinding open, one
-- stone slam on the cut, and a swell under the reveal.
--
-- All three are ids this place has already proven load -- the howl is the
-- desert's own wind bed, the slam is the pyramid door's scrape dropped to 0.42
-- speed. Creator-uploaded audio is private and fails SILENTLY, so nothing new
-- gets guessed at in here; what makes these read as different sounds is the
-- playback speed, and the riser's is tweened live rather than set once.
local riser = mkSound("rbxassetid://9118747853", 0, 0.5, true)
local slam = mkSound("rbxassetid://9116826112", 0.9, 0.42, false)
local swell = mkSound("rbxassetid://9125602882", 0, 0.62, false)
drone:Play()

local DRONE_PEAK = 0.16

----------------------------------------------------------------
-- The camera
--
-- Held Scriptable for the length of a transition and ONLY that, and handed back
-- through one function that every exit runs -- including the watchdog. A camera
-- left Scriptable is a worse failure than a missed fade: the player can still
-- walk, but they cannot look, and nothing else in the game will ever clear it.
--
-- The token is what stops a finished transition tidying up after a newer one
-- that has since taken the camera for itself.
----------------------------------------------------------------
local camDrive: ((number) -> ())? = nil
local camToken = 0
local holding = false
local homeFov = (workspace.CurrentCamera and workspace.CurrentCamera.FieldOfView) or 70
local heldSpeed: number? = nil

local function humanoidOf(): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid") or nil
end

local function releaseCamera(token: number?)
	if token ~= nil and token ~= camToken then
		return                      -- a newer transition owns it now
	end
	if not holding then
		return
	end
	holding = false
	camDrive = nil

	local cam = workspace.CurrentCamera
	if cam then
		cam.FieldOfView = homeFov
		cam.CameraType = Enum.CameraType.Custom
	end
	local hum = humanoidOf()
	if hum then
		if cam then
			cam.CameraSubject = hum
		end
		if heldSpeed then
			hum.WalkSpeed = heldSpeed
		end
	end
	heldSpeed = nil
end

local function seizeCamera(): (Camera?, number)
	local cam = workspace.CurrentCamera
	camToken += 1
	if not cam then
		return nil, camToken
	end
	if not holding then
		homeFov = cam.FieldOfView   -- only before we start moving it ourselves
	end
	holding = true
	cam.CameraType = Enum.CameraType.Scriptable

	-- Stand still for it. Restored by releaseCamera, which the watchdog also
	-- calls, so a dropped fade-in cannot leave anybody rooted to the spot.
	local hum = humanoidOf()
	if hum and heldSpeed == nil then
		heldSpeed = hum.WalkSpeed
		hum.WalkSpeed = 0
	end
	return cam, camToken
end

RunService.RenderStepped:Connect(function(dt)
	local drive = camDrive
	if drive then
		drive(dt)
	end
end)

-- Handheld wobble. math.noise is continuous, so this shakes rather than
-- vibrating -- a per-frame random offset reads as a broken frame buffer.
local function shakeCF(t: number, amp: number): CFrame
	-- The one chokepoint for all three shots in this cinematic, which is why
	-- Set_ScreenShake is read here and not at each of the three call sites.
	if amp <= 0.0001 or not Motion.shake() then
		return CFrame.identity
	end
	return CFrame.new(
		math.noise(t * 13, 1.7) * amp * 1.4,
		math.noise(t * 13, 5.3) * amp * 1.4,
		math.noise(t * 9, 8.9) * amp * 0.7)
		* CFrame.Angles(
			math.noise(t * 11, 12.1) * amp * 0.05,
			math.noise(t * 11, 17.5) * amp * 0.05,
			math.noise(t * 7, 21.3) * amp * 0.09)
end

-- The build: pushing in on whatever the player is looking at, narrowing, with
-- the shake ramping quadratically so it is nothing at all for the first half
-- second and unmissable by the cut.
local function driveApproach(duration: number)
	local cam = seizeCamera()
	if not cam then
		return
	end
	local from = cam.CFrame
	local fov0 = homeFov
	local t = 0
	camDrive = function(dt)
		t = math.min(t + dt, duration)
		local u = (duration > 0) and (t / duration) or 1
		local ease = u * u
		local c = workspace.CurrentCamera
		if not c then
			return
		end
		c.FieldOfView = fov0 + (44 - fov0) * ease
		c.CFrame = (from + from.LookVector * (11 * ease)) * shakeCF(os.clock(), 0.8 * ease * ease)
	end
end

-- The hit. Everything stops moving and rings out instead.
local function driveKick()
	local c = workspace.CurrentCamera
	if not c or not holding then
		return
	end
	local from = c.CFrame
	local t = 0
	camDrive = function(dt)
		t += dt
		local decay = math.max(0, 1 - t / 0.7)
		local cc = workspace.CurrentCamera
		if cc then
			cc.CFrame = from * shakeCF(os.clock(), 1.7 * decay * decay)
		end
	end
end

-- The reveal: a crane down out of the roof of the hall onto the player's
-- shoulder, so the first thing they see is the whole room and the last is
-- themselves standing in it.
--
-- Framed off the character rather than off the room's coordinates, because the
-- room's are VaultBuilder's and this file does not get to know them -- and
-- because that makes the same shot correct if the entry point ever moves.
local REVEAL = 3

local function driveReveal(duration: number)
	local cam, token = seizeCamera()
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not cam or not hrp then
		releaseCamera(token)
		return
	end

	local pos = hrp.Position
	local lv = hrp.CFrame.LookVector
	local flat = Vector3.new(lv.X, 0, lv.Z)
	flat = (flat.Magnitude > 1e-3) and flat.Unit or Vector3.new(0, 0, 1)
	local right = Vector3.new(-flat.Z, 0, flat.X)

	-- 23 up and 9 back is deliberately modest: the hall's ceiling is 43 studs up
	-- and its near wall only a dozen behind the entry point, so a heroic crane
	-- from further out would start the shot inside the masonry.
	local eyeA = pos + Vector3.new(0, 23, 0) - flat * 9 + right * 6
	local eyeB = pos + Vector3.new(0, 3.1, 0) - flat * 8.5
	local aimA = pos + Vector3.new(0, 7, 0) + flat * 74
	local aimB = pos + Vector3.new(0, 2.2, 0) + flat * 16

	local t = 0
	camDrive = function(dt)
		t = math.min(t + dt, duration)
		local u = (duration > 0) and (t / duration) or 1
		local e = 1 - (1 - u) ^ 3          -- arrives gently instead of stopping dead
		local c = workspace.CurrentCamera
		if not c then
			return
		end
		c.FieldOfView = 62 + (homeFov - 62) * e
		c.CFrame = CFrame.lookAt(eyeA:Lerp(eyeB, e), aimA:Lerp(aimB, e))
			* shakeCF(os.clock(), 0.14 * (1 - e))
	end
	task.delay(duration + 0.05, function()
		releaseCamera(token)
	end)
end

----------------------------------------------------------------
-- The transition
----------------------------------------------------------------
local fadeEpoch = 0

-- Assigned once the particle emitters exist, further down the file. A no-op
-- until then, which is only ever true during this script's own boot.
local goldRush = function() end

local function fadeIn(kind: string?)
	fadeEpoch += 1
	local mine = fadeEpoch
	flash.Visible = false

	if kind ~= "enter" then
		-- Leaving, or the watchdog rescuing a transition that never finished.
		-- Get the screen and the controls back, quietly and fast: walking out of
		-- a tomb is not an event and should not be staged like one.
		releaseCamera()
		TweenService:Create(caption, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
		TweenService:Create(subcap, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
		local t = TweenService:Create(curtain,
			TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ BackgroundTransparency = 1 })
		t.Completed:Connect(function()
			if fadeEpoch == mine then
				curtain.Visible = false
				caption.Text, subcap.Text = "", ""
			end
		end)
		t:Play()
		wipeTop.Visible, wipeBot.Visible = false, false
		showBars(false)
		whoosh.PlaybackSpeed = 1.05
		whoosh:Play()
		return
	end

	-- THE REVEAL.
	driveReveal(REVEAL)

	swell.TimePosition = 0
	swell.Volume = 0
	swell:Play()
	TweenService:Create(swell, TweenInfo.new(0.9), { Volume = 0.6 }):Play()
	whoosh.PlaybackSpeed = 1.15
	whoosh:Play()

	-- Hand the black over from the curtain to the two halves in one frame, so
	-- there is never a gap between them for the room to peek through early.
	wipeTop.Size = UDim2.fromScale(1, 0.5)
	wipeBot.Size = UDim2.fromScale(1, 0.5)
	wipeTop.Visible, wipeBot.Visible = true, true
	curtain.Visible = false
	curtain.BackgroundTransparency = 1

	-- A beat of held title on black first. Opening the instant the fade lands
	-- would put the reveal on top of the caption the player is still reading.
	task.delay(0.55, function()
		if fadeEpoch ~= mine then
			return
		end
		TweenService:Create(caption, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
		TweenService:Create(subcap, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()

		local info = TweenInfo.new(1.05, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
		local shut = UDim2.fromScale(1, 0)
		TweenService:Create(wipeTop, info, { Size = shut }):Play()
		local t = TweenService:Create(wipeBot, info, { Size = shut })
		t.Completed:Connect(function()
			if fadeEpoch == mine then
				wipeTop.Visible, wipeBot.Visible = false, false
				caption.Text, subcap.Text = "", ""
			end
		end)
		t:Play()
		goldRush()
	end)

	task.delay(REVEAL - 0.5, function()
		if fadeEpoch == mine then
			showBars(false)
		end
	end)
end

local function fadeOut(text: string?, kind: string?, sub: string?)
	fadeEpoch += 1
	local mine = fadeEpoch
	local grand = (kind ~= "leave")

	curtain.Visible = true
	curtain.BackgroundTransparency = 1
	wipeTop.Visible, wipeBot.Visible = false, false
	flash.Visible = true
	flash.BackgroundTransparency = 1
	caption.Text = text or ""
	caption.TextTransparency = 1
	subcap.Text = grand and (sub or SUBTITLE) or ""
	subcap.TextTransparency = 1
	showBars(true)

	-- Let them watch the door actually start moving first. Cutting on the click
	-- makes the door feel like a button; holding a beat makes what follows feel
	-- like a consequence of it opening. What is different now is what fills the
	-- beat: the camera closes on the doorway, the frame narrows, the ground
	-- starts shaking and a howl climbs under it, so the black is the END of
	-- something rather than the whole of it.
	if grand then
		riser.TimePosition = 0
		riser.Volume = 0
		riser.PlaybackSpeed = 0.5
		riser:Play()
		TweenService:Create(riser,
			TweenInfo.new(CINEMA.beat, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Volume = 0.55, PlaybackSpeed = 1.7 }):Play()
		driveApproach(CINEMA.beat)
	end

	task.delay(CINEMA.beat, function()
		if fadeEpoch ~= mine then
			return
		end

		if not grand then
			whoosh.PlaybackSpeed = 0.68
			whoosh:Play()
			TweenService:Create(curtain,
				TweenInfo.new(CINEMA.fade, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ BackgroundTransparency = 0 }):Play()
		else
			-- THE CUT. A slam and one frame of gold, not a dissolve.
			slam.TimePosition = 0
			slam:Play()
			driveKick()
			TweenService:Create(riser, TweenInfo.new(0.3), { Volume = 0 }):Play()
			task.delay(0.35, function()
				riser:Stop()
			end)

			TweenService:Create(flash,
				TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundTransparency = 0 }):Play()
			task.delay(0.12, function()
				if fadeEpoch ~= mine then
					return
				end
				-- Black lands BEHIND the gold, so the screen is never uncovered
				-- for a frame between the two. The teleport happens inside this.
				curtain.BackgroundTransparency = 0
				TweenService:Create(flash,
					TweenInfo.new(math.max(0.2, CINEMA.fade - 0.12), Enum.EasingStyle.Quad,
						Enum.EasingDirection.Out),
					{ BackgroundTransparency = 1 }):Play()
			end)
		end

		if caption.Text ~= "" then
			task.delay(CINEMA.fade * 0.45, function()
				if fadeEpoch ~= mine then
					return
				end
				TweenService:Create(caption, TweenInfo.new(0.5), { TextTransparency = 0 }):Play()
				if subcap.Text ~= "" then
					task.delay(0.28, function()
						if fadeEpoch == mine then
							TweenService:Create(subcap, TweenInfo.new(0.5),
								{ TextTransparency = 0.15 }):Play()
						end
					end)
				end
			end)
		end
	end)

	-- Watchdog. The fade-in is a separate message, and if it never lands -- the
	-- server erroring mid-teleport, say -- the player is left sitting in front of
	-- a black rectangle with no way to clear it, and now with no camera and no
	-- walk speed either. Nothing is worth that, so this route out ignores the
	-- token and takes the camera back by force.
	task.delay(CINEMA.beat + CINEMA.fade + 10, function()
		if fadeEpoch == mine then
			warn("[Vault] no fade-in arrived within 10s -- lifting the curtain")
			releaseCamera()
			fadeIn("leave")
		end
	end)
end

----------------------------------------------------------------
-- The room's light and air
--
-- Its own ColorCorrection, for the same reason the desert has one: CTB_Server's
-- applyLook owns the shared effect and two writers on one object gives a look
-- that depends on boot order.
----------------------------------------------------------------
local grade = Instance.new("ColorCorrectionEffect")
grade.Name = "VaultGrade"
grade.Brightness = 0
grade.Contrast = 0
grade.Saturation = 0
grade.TintColor = Color3.new(1, 1, 1)
grade.Parent = Lighting

local HOME_OUT = Lighting.OutdoorAmbient
local HOME_AMB = Lighting.Ambient

--[[
	The AIR, which the room did not own and badly needed to.

	The tomb is sealed on all six sides and lit by torches, and it was inheriting
	the sky's atmosphere: pale blue haze at 1.40, decaying to a colder blue still.
	Across a 260-stud hall that put a blue-grey wash over every gold surface in
	the place -- the far end of the room read as underwater, and the reveal shot
	opens on precisely that distance.

	Same handle and the same lerp Island2_Client uses for the desert, so the two
	cannot fight over it: they are 1500 studs apart, only one blend is ever above
	zero, and the one that is writes every frame (see applyBlend) so it wins
	during the couple of seconds the other is still fading out.

	Haze is not taken to nothing. Some is wanted -- it is a dusty room with a
	shaft of light in it -- it just has to be WARM dust rather than cold sky.
]]
local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
local HOME_ATMO = atmo and {
	Density = atmo.Density, Haze = atmo.Haze, Glare = atmo.Glare,
	Color = atmo.Color, Decay = atmo.Decay,
} or nil
local VAULT_ATMO = {
	Density = 0.26,
	Haze = 0.55,
	Glare = 0.06,
	Color = Color3.fromRGB(208, 172, 124),
	Decay = Color3.fromRGB(88, 60, 34),
}
--[[
	Dim and warm. It is a sealed room lit by torches and one shaft of light, so
	the beach's cool grey ambient would flatten every gold surface in it.

	⚠️ AMBIENT IS THE ONLY THING AN UNLIT PART OF THIS ROOM HAS TO BE SEEN BY.
	OutdoorAmbient never reaches a sealed interior, so whatever is out of a
	torch's reach is lit by VAULT_AMB and nothing else. It was 48,38,26 and the
	middle of the chamber -- which had no light over it at all until
	VaultBuilder's AisleFill was added, see its note -- crushed to near black.
	Lifted to 56,45,32: a small lift on purpose, because the fill is what fixes
	the floor and this only stops the corners and the upper walls going to pitch.

	⚠️ DO NOT SOLVE DARKNESS WITH THIS DIAL. Measured: at 74,60,44 (with omni
	fill lights) the tomb photographed as a flat cream room -- ceiling, walls and
	floor all one value, no torch pools, no tomb. Ambient lifts EVERY surface
	including the ceiling, so it is the one lever that destroys the room's
	character fastest. Light the floor with geometry; use this only as a floor
	under the shadows.
]]
local VAULT_OUT = Color3.fromRGB(104, 82, 58)
local VAULT_AMB = Color3.fromRGB(56, 45, 32)

local blend = 0
local owningLight = false

----------------------------------------------------------------
-- THE CARPET IS PART OF THE FIELD
--
-- The runner crosses the rakeable square, and the square records a raked cell
-- by swapping the terrain material under it. A carpet laid over the top hid
-- that record on the six cell columns it covers, so the middle of the room
-- stayed visibly untouched however long you raked it. VaultBuilder now lays
-- that stretch as one tile per cell; this repaints them.
--
-- ⚠️ IT READS THE TERRAIN, IT DOES NOT LISTEN FOR SWEEPS. The terrain IS the
-- record, and CTB_Client already keeps it correct through every path there is:
-- a sweep, the Sync on arrival, a Tide, a Wipe, a rejoin, the settings toggle
-- that hides the squares. Subscribing to "Clean" would catch the first of those
-- and silently miss the rest -- a carpet that was right while you raked and
-- wrong after every reset. One ReadVoxels of a 6 x 32 x 1 voxel strip answers
-- all of them, and a cell is exactly one voxel (4 studs) so it maps 1:1.
----------------------------------------------------------------
local Terrain = workspace.Terrain
-- The two states are VaultBuilder's, read off the model it stamped them on --
-- see the note there. These are only the fallback for a room built by an older
-- copy of the builder that did not publish them yet.
local CARPET_DUSTY = Color3.fromRGB(40, 104, 116)
local CARPET_CLEAN = Color3.fromRGB(96, 210, 226)
local CARPET_IX0, CARPET_COLS = 13, 6
local CELL = VAULT.half * 2 / VAULT.grid

local carpetTiles = nil        -- [ix][iz] -> part, built once the room exists
local carpetClock = 0

--[[
	⚠️ THE SURFACE IS NOT THE FIRST VOXEL LAYER. Config.writeField writes FOUR
	y layers over Y_MIN..Y_MAX, and layer 1 is the bulk underneath -- it is
	`isl.matMessy` at occupancy 1 ALWAYS, whether the cell is raked or not.
	The raked/unraked material goes into layers 2 and 3 (occupancy 1 and 0.25
	here, which is what stands the surface at cleanY 3). Reading layer 1 would
	have reported every cell dirty, forever, and looked exactly like a carpet
	that simply does not work.

	Either of 2 or 3 answers it; both are tested so this does not quietly depend
	on occupancyFor's split staying where it is for this island's cleanY.
]]
local carpetRegion = Region3.new(
	Vector3.new(VAULT.x0 + CARPET_IX0 * CELL, Config.Y_MIN, VAULT.z0),
	Vector3.new(VAULT.x0 + (CARPET_IX0 + CARPET_COLS) * CELL, Config.Y_MAX,
		VAULT.z0 + VAULT.grid * CELL)
):ExpandToGrid(Config.VOXEL)

local function findCarpet()
	local room = workspace:FindFirstChild("Vault")
	local cells = room and room:FindFirstChild("CarpetCells")
	if not cells then
		return nil
	end
	-- Keyed off each tile's own POSITION rather than an attribute the builder
	-- would have to keep in step. There is one source of truth for where a cell
	-- is and it is the same arithmetic both sides already do.
	local map = {}
	for _, p in ipairs(cells:GetChildren()) do
		if p:IsA("BasePart") then
			local ix = math.floor((p.Position.X - VAULT.x0) / CELL)
			local iz = math.floor((p.Position.Z - VAULT.z0) / CELL)
			map[ix] = map[ix] or {}
			map[ix][iz] = p
		end
	end
	local d, c = cells:GetAttribute("Dusty"), cells:GetAttribute("Clean")
	if typeof(d) == "Color3" then CARPET_DUSTY = d end
	if typeof(c) == "Color3" then CARPET_CLEAN = c end
	return map
end

local function repaintCarpet()
	if not carpetTiles then
		carpetTiles = findCarpet()
		if not carpetTiles then
			return
		end
	end
	local ok, mats = pcall(Terrain.ReadVoxels, Terrain, carpetRegion, CELL)
	if not ok or not mats then
		return
	end
	for xi = 1, CARPET_COLS do
		local col = carpetTiles[CARPET_IX0 + xi - 1]
		local mx = mats[xi]
		if col and mx then
			for zi = 1, VAULT.grid do
				local p = col[zi - 1]
				if p then
					local cleaned = (mx[2] and mx[2][zi] == VAULT.matClean)
						or (mx[3] and mx[3][zi] == VAULT.matClean)
					local want = cleaned and CARPET_CLEAN or CARPET_DUSTY
					-- Only on change: 192 writes a tick would dirty the whole model
					-- every frame for nothing.
					if p.Color ~= want then
						p.Color = want
					end
				end
			end
		end
	end
end

-- The room is rebuilt on every server boot, so a remembered lookup would point
-- at 192 destroyed parts after one. Cheap to drop it and find them again.
workspace.ChildRemoved:Connect(function(child)
	if child.Name == "Vault" then
		carpetTiles = nil
	end
end)

local function applyBlend(a: number)
	grade.Brightness = 0.03 * a
	-- 0.09, was 0.11. Contrast deepens the darks, and in a room whose darks were
	-- already the problem it was working against the fill. Still positive: the
	-- gold wants the punch, it just cannot have it at the floor's expense.
	grade.Contrast = 0.09 * a
	grade.Saturation = 0.1 * a
	grade.TintColor = Color3.new(1, 1 - 0.045 * a, 1 - 0.12 * a)

	if a > 0.01 then
		-- Written every frame while the vault is active, not only on change.
		-- Island2_Client drives the same two properties for the desert, and
		-- arriving here from there means its fade is still running for a couple of
		-- seconds. Whoever writes last wins, so the room makes sure that is it.
		owningLight = true
		Lighting.OutdoorAmbient = HOME_OUT:Lerp(VAULT_OUT, a)
		Lighting.Ambient = HOME_AMB:Lerp(VAULT_AMB, a)
		if atmo and HOME_ATMO then
			atmo.Density = HOME_ATMO.Density + (VAULT_ATMO.Density - HOME_ATMO.Density) * a
			atmo.Haze = HOME_ATMO.Haze + (VAULT_ATMO.Haze - HOME_ATMO.Haze) * a
			atmo.Glare = HOME_ATMO.Glare + (VAULT_ATMO.Glare - HOME_ATMO.Glare) * a
			atmo.Color = HOME_ATMO.Color:Lerp(VAULT_ATMO.Color, a)
			atmo.Decay = HOME_ATMO.Decay:Lerp(VAULT_ATMO.Decay, a)
		end
	elseif owningLight then
		-- Hand it back on the way out. Without this the world keeps the tomb's
		-- dim warm ambient for the rest of the session, because nothing else
		-- writes these two unless ITS blend is changing.
		owningLight = false
		Lighting.OutdoorAmbient = HOME_OUT
		Lighting.Ambient = HOME_AMB
		if atmo and HOME_ATMO then
			for k, v in pairs(HOME_ATMO) do
				atmo[k] = v
			end
		end
	end
end
applyBlend(0)

----------------------------------------------------------------
-- Sweeping the gold
--
-- The raking itself is CTB_Client's, unchanged -- this only adds what the
-- chamber needs that a beach does not: gold catching the light as it goes, and
-- a coin note under it. Sand gets a dust puff; a floor of treasure has to
-- sound like it is being cleared.
----------------------------------------------------------------
local fxFolder = workspace:FindFirstChild("Vault_FX")
if fxFolder then
	fxFolder:Destroy()
end
fxFolder = Instance.new("Folder")
fxFolder.Name = "Vault_FX"
fxFolder.Parent = workspace

local function emitterPart(name: string): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = Vector3.new(1, 1, 1)
	p.Transparency = 1
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
	p.Parent = fxFolder
	return p
end

local sparkPart = emitterPart("GoldSpark")
local spark = Instance.new("ParticleEmitter")
spark.Texture = "rbxasset://textures/particles/sparkles_main.dds"
spark.Rate = 0
spark.Lifetime = NumberRange.new(0.35, 0.85)
spark.Speed = NumberRange.new(6, 15)
spark.SpreadAngle = Vector2.new(180, 180)
spark.Color = ColorSequence.new(GOLD)
spark.LightEmission = 0.9
spark.Size = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1.5),
	NumberSequenceKeypoint.new(1, 0),
})
spark.Parent = sparkPart

-- Slow gold dust hanging in the air, following the player around the room.
local motePart = emitterPart("GoldMotes")
motePart.Size = Vector3.new(50, 26, 50)
local motes = Instance.new("ParticleEmitter")
motes.Texture = "rbxasset://textures/particles/sparkles_main.dds"
motes.Rate = 0
motes.Lifetime = NumberRange.new(3.5, 7)
motes.Speed = NumberRange.new(0.4, 1.6)
motes.SpreadAngle = Vector2.new(180, 180)
motes.Acceleration = Vector3.new(0, 0.5, 0)
motes.Color = ColorSequence.new(GOLD)
motes.LightEmission = 0.7
motes.Size = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.3, 0.55),
	NumberSequenceKeypoint.new(1, 0),
})
motes.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.25, 0.45),
	NumberSequenceKeypoint.new(1, 1),
})
motes.Parent = motePart

-- Budgeted, because the sifter reports cleaned cells at 24 Hz and a wide sweep
-- can hand over a dozen at once. Without a cap a good run turns into a wall of
-- particles, which is the opposite of satisfying. (The matching throttle for the
-- SOUND moved to CTB_Client with the sound itself -- see CHAMBER_SWEEP_GAP.)
local sparkBudget = 0

local function goldSwept(batch)
	local surface = Config.surfaceY(VAULT)
	for _, idx in ipairs(batch) do
		if sparkBudget < 1 then
			break
		end
		sparkBudget -= 1
		local ix, iz = Config.coords(VAULT, idx)
		local c = Config.cellCentre(VAULT, ix, iz)
		sparkPart.CFrame = CFrame.new(c.X, surface + 0.9, c.Z)
		spark:Emit(10)
	end

	--[[
		THE SWEEP'S SOUND MOVED TO CTB_Client, AND THE BEEP WENT WITH IT.

		This used to fire `chime` -- the engine's electronicpingshort.wav, at 1.3 to
		1.85x, up to twelve a second -- which is what the tomb sounded like the
		whole time you were working it. It is AudioKit's Pickup slot now, played
		from the shared Clean handler in CTB_Client (see CHAMBER_SWEEP_GAP) so
		that this chamber, the inner shrine and the magma chamber all sound the
		same -- the other two had no sweep sound at all.

		The throttle went with it too, at the same 0.085s. Playing one here as well
		would simply double every sweep.

		The sparks above stay: they are this room's own, and gold coming up out of
		the floor should look different from litter coming out of sand even when it
		sounds the same.
	]]
end

----------------------------------------------------------------
-- Clearing the room
----------------------------------------------------------------
local banner = Instance.new("TextLabel")
banner.Name = "Banner"
-- 0.32, up from 0.36, and this is the ONE thing on screen that moved UP.
--
-- Clearing the vault fires this AND CTB_HUD's tide banner through ToastKit, and
-- that column now lives in the bottom third -- with the sale receipt stacked on
-- top of it, which a player standing on the vault's sell pad as the room clears
-- will genuinely see at the same time. Those three needed a ladder, and this is
-- the rare cinematic one, so it gives up the room rather than the two that fire
-- on every run. Its top edge still clears CTB_HUD's load bar (10..64).
banner.AnchorPoint = Vector2.new(0.5, 0.5)
banner.Position = UDim2.fromScale(0.5, 0.32)
banner.Size = UDim2.fromScale(0.7, 0.13)
banner.BackgroundTransparency = 1
banner.Font = Enum.Font.LuckiestGuy
banner.Text = ""
banner.TextColor3 = GOLD
banner.TextStrokeColor3 = INK
banner.TextStrokeTransparency = 1
banner.TextTransparency = 1
banner.TextScaled = true
banner.ZIndex = 6
banner.Parent = gui
local bannerSize = Instance.new("UITextSizeConstraint")
bannerSize.MaxTextSize = 46
bannerSize.Parent = banner

-- The room ARRIVING, fired as the wipe opens. The alternative is that the first
-- frame of the tomb is a still photograph of it, which is a strange thing to
-- have built a two second run-up to.
goldRush = function()
	chime.PlaybackSpeed = 1.1
	chime:Play()
	task.spawn(function()
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local at = hrp and hrp.Position
			or Vector3.new(VAULT.cx, Config.surfaceY(VAULT) + 4, VAULT.cz)
		-- Outward in a spiral rather than all at once: it reads as the room
		-- lighting up ahead of the player instead of as a firework at their feet.
		for i = 1, 12 do
			local a = (i / 12) * math.pi * 2 * 1.6
			local r = 8 + i * 2.4
			sparkPart.CFrame = CFrame.new(at
				+ Vector3.new(math.cos(a) * r, 1 + i * 0.55, math.sin(a) * r))
			spark:Emit(18)
			task.wait(0.045)
		end
	end)
end

local function celebrate(bonus: number)
	banner.Text = string.format("VAULT CLEARED   +$%d", bonus or VAULT.resetBonus)
	banner.TextTransparency = 1
	banner.TextStrokeTransparency = 1
	banner.Position = UDim2.fromScale(0.5, 0.36)
	fanfare.TimePosition = 0
	fanfare:Play()

	TweenService:Create(banner, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		TextTransparency = 0, TextStrokeTransparency = 0.25, Position = UDim2.fromScale(0.5, 0.32),
	}):Play()
	task.delay(3.2, function()
		TweenService:Create(banner, TweenInfo.new(0.7), {
			TextTransparency = 1, TextStrokeTransparency = 1,
		}):Play()
		task.delay(4, function()
			if fanfare.IsPlaying then
				fanfare:Stop()
			end
		end)
	end)

	-- gold going up all over the room, not just where the player is standing
	task.spawn(function()
		for _ = 1, 22 do
			sparkPart.CFrame = CFrame.new(
				VAULT.cx + math.random(-60, 60),
				Config.surfaceY(VAULT) + math.random(1, 12),
				VAULT.cz + math.random(-60, 60))
			spark:Emit(24)
			task.wait(0.06)
		end
	end)
end

----------------------------------------------------------------
-- WHAT THE STATUES SAY
--
-- VaultBuilder writes a `Says` line, a `SaysName` and a `SaysAt` point onto each
-- of the eight wall statues. This only draws them: no remote, nothing to keep in
-- sync, and a statue without a line simply never gets a bubble -- which is what
-- the hero on the dais wants, because it is the thing you walk towards rather
-- than a talker.
--
-- ONE AT A TIME, the nearest. Eight bubbles alight at once down a colonnade is
-- not a room full of characters, it is a wall of text -- and the player is
-- walking past them, so the nearest is always the one they mean.
--
-- The anchors are CLIENT-SIDE parts at the published points rather than
-- billboards parented into the statues: StreamingEnabled takes the statues away
-- whenever the player is anywhere else in the world, and a billboard whose
-- adornee has gone is a bubble hanging over nothing.
----------------------------------------------------------------
local PanelKit = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("PanelKit"))
local PC = PanelKit.C

-- Studs, and measured FLAT -- x/z only, ignoring height. The bubbles hang at
-- head height on a thirty-stud statue, so a player standing at its feet is still
-- thirty studs from the thing they are obviously next to, and a straight
-- Magnitude never let a single one of them open.
local SAY_FULL, SAY_GONE = 22, 34      -- solid inside, faded out past

local saysFolder = nil
local says = {}                        -- { pos, gui, fades }
local saysBuilt = false

-- Everything a fade has to touch, with the value it started at -- so an element
-- that is meant to be invisible stays invisible at full opacity.
local function fadeList(gui: Instance)
	local list = {}
	for _, d in gui:GetDescendants() do
		if d:IsA("GuiObject") then
			table.insert(list, { d, "BackgroundTransparency", d.BackgroundTransparency })
		end
		if d:IsA("TextLabel") then
			table.insert(list, { d, "TextTransparency", d.TextTransparency })
		end
		if d:IsA("UIStroke") then
			table.insert(list, { d, "Transparency", d.Transparency })
		end
	end
	return list
end

local function buildBubble(parent: BasePart, who: string, line: string)
	local bb = Instance.new("BillboardGui")
	bb.Name = "StatueSays"
	bb.Size = UDim2.fromOffset(320, 128)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 0, 0)
	bb.MaxDistance = SAY_GONE + 6
	bb.LightInfluence = 0
	bb.Parent = parent

	-- The tail sits UNDER the card (ZIndex 1 against 2) so only the half poking
	-- out below shows -- a rotated square with its own outline drawn over the
	-- card would put a diagonal seam across the bottom of every line.
	local tail = Instance.new("Frame")
	tail.AnchorPoint = Vector2.new(0.5, 0.5)
	tail.Position = UDim2.new(0.5, 0, 1, -12)
	tail.Size = UDim2.fromOffset(24, 24)
	tail.Rotation = 45
	tail.BackgroundColor3 = PC.sand
	tail.BorderSizePixel = 0
	tail.ZIndex = 1
	tail.Parent = bb
	PanelKit.outline(tail, 4)

	local slab = Instance.new("Frame")
	slab.Size = UDim2.new(1, 0, 1, -22)
	slab.Position = UDim2.fromOffset(0, 7)
	slab.BackgroundColor3 = PC.woodDark
	slab.BorderSizePixel = 0
	slab.ZIndex = 1
	slab.Parent = bb
	PanelKit.corner(slab, 16)
	PanelKit.outline(slab, 4)

	local card = Instance.new("Frame")
	card.Size = UDim2.new(1, 0, 1, -22)
	card.BackgroundColor3 = PC.white
	card.BorderSizePixel = 0
	card.ZIndex = 2
	card.Parent = bb
	PanelKit.corner(card, 16)
	PanelKit.outline(card, 4)
	PanelKit.grad(card, PC.white, PC.sand)

	local name = PanelKit.text(card, who, 15, Enum.Font.LuckiestGuy, PC.woodDark)
	name.Position = UDim2.fromOffset(14, 6)
	name.Size = UDim2.new(1, -28, 0, 20)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.ZIndex = 4

	local body = PanelKit.text(card, line, 15, Enum.Font.GothamMedium, PC.ink)
	body.Position = UDim2.fromOffset(14, 26)
	body.Size = UDim2.new(1, -28, 1, -34)
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.TextWrapped = true
	body.TextTruncate = Enum.TextTruncate.None
	body.ZIndex = 4

	return bb
end

-- Retried rather than resolved once: the vault streams in around the player, so
-- at the moment this script boots there is usually nothing out there to read.
local function ensureSays(): boolean
	if saysBuilt then
		return true
	end
	local vault = workspace:FindFirstChild("Vault")
	local hall = vault and vault:FindFirstChild("Hall")
	if not hall then
		return false
	end

	local found = {}
	for _, m in hall:GetChildren() do
		local line = m:GetAttribute("Says")
		local at = m:GetAttribute("SaysAt")
		if type(line) == "string" and typeof(at) == "Vector3" then
			table.insert(found, { m = m, line = line, at = at })
		end
	end
	if #found == 0 then
		return false
	end

	saysFolder = Instance.new("Folder")
	saysFolder.Name = "Vault_Says"
	saysFolder.Parent = workspace

	for _, e in found do
		local anchor = Instance.new("Part")
		anchor.Name = "SayAnchor"
		anchor.Size = Vector3.new(0.2, 0.2, 0.2)
		anchor.CFrame = CFrame.new(e.at)
		anchor.Transparency = 1
		anchor.Anchored, anchor.CanCollide = true, false
		anchor.CanQuery, anchor.CanTouch, anchor.CastShadow = false, false, false
		anchor.Parent = saysFolder

		local gui = buildBubble(anchor, e.m:GetAttribute("SaysName") or "", e.line)
		local fades = fadeList(gui)
		for _, f in fades do
			f[1][f[2]] = 1
		end
		gui.Enabled = false
		table.insert(says, { pos = e.at, gui = gui, fades = fades, alpha = 0 })
	end

	saysBuilt = true
	return true
end

local saysRetry = 0

local function stepSays(dt: number, hrp: BasePart?)
	if not saysBuilt then
		saysRetry -= dt
		if saysRetry <= 0 then
			saysRetry = 1
			ensureSays()
		end
		return
	end

	-- The nearest one inside the band wins; everything else fades out.
	local best, bestD = nil, math.huge
	if hrp then
		local here = hrp.Position
		for _, s in says do
			local dx, dz = s.pos.X - here.X, s.pos.Z - here.Z
			local d = math.sqrt(dx * dx + dz * dz)
			if d < bestD and d <= SAY_GONE then
				best, bestD = s, d
			end
		end
	end

	for _, s in says do
		local want = 0
		if s == best then
			want = math.clamp((SAY_GONE - bestD) / (SAY_GONE - SAY_FULL), 0, 1)
		end
		if s.alpha ~= want then
			s.alpha += math.clamp(want - s.alpha, -dt * 3.5, dt * 3.5)
			if math.abs(want - s.alpha) < 0.01 then
				s.alpha = want
			end
			s.gui.Enabled = s.alpha > 0.01
			for _, f in s.fades do
				f[1][f[2]] = 1 - (1 - f[3]) * s.alpha
			end
		end
	end
end

----------------------------------------------------------------
-- Wiring
----------------------------------------------------------------
Net.OnClientEvent:Connect(function(action, a, b, c, d)
	if action == "Cinema" then
		-- out: (caption, kind, subtitle).  in: (kind).  "enter" gets the full
		-- treatment, "leave" gets a plain fade -- walking back out to the plaza
		-- should not cost the player four seconds and a title card every time.
		--
		-- The subtitle is optional and falls back to the tomb's; see SUBTITLE.
		if a == "out" then
			fadeOut(b, c, d)
		else
			fadeIn(b)
		end

	elseif action == "DoorLocked" then
		-- out: (needed, have, room).  The room name is optional and falls back to
		-- the tomb's headline; see SEALED_TITLE.
		showSealed(a, b, c)

	elseif action == "Clean" and a == VAULT.id then
		goldSwept(b)

	elseif action == "Tide" and a == VAULT.id then
		celebrate(b)
	end
end)

local FADE_SPEED = 1.8
local zoneTimer = 0
local inVault = false

RunService.Heartbeat:Connect(function(dt)
	sparkBudget = math.min(sparkBudget + dt * 16, 6)

	zoneTimer -= dt
	if zoneTimer <= 0 then
		zoneTimer = 0.35
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local zone = hrp and Config.zoneAt(hrp.Position) or nil
		inVault = (zone ~= nil and zone.id == VAULT.id)
	end

	local target = inVault and 1 or 0
	if blend ~= target then
		blend += math.clamp(target - blend, -dt / FADE_SPEED, dt / FADE_SPEED)
		if math.abs(blend - target) < 0.002 then
			blend = target
		end
		drone.Volume = DRONE_PEAK * blend
		motes.Rate = 20 * blend
		-- on change, INCLUDING the change down to zero that hands the lighting back
		applyBlend(blend)
	end
	if blend > 0.01 then
		applyBlend(blend)
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp then
			motePart.CFrame = CFrame.new(hrp.Position + Vector3.new(0, 6, 0))
		end
		stepSays(dt, hrp)

		--[[
			THE CARPET, ONLY WHILE SOMEBODY IS IN THE ROOM TO SEE IT.

			Gated on the same blend as everything else in this loop: the tomb is
			3,000 studs from the beach and there is no reason to read its terrain
			while a player is standing on the sand. Throttled to ~7 Hz because it
			is a picture and not a mechanic -- the terrain under it flushes on
			Heartbeat and a seventh of a second behind that is invisible, while a
			per-frame ReadVoxels for a decoration is not worth having.
		]]
		carpetClock = (carpetClock or 0) + dt
		if carpetClock >= 0.14 then
			carpetClock = 0
			repaintCarpet()
		end
	elseif saysBuilt then
		-- Out of the room: make sure nothing is left talking to an empty hall.
		stepSays(dt, nil)
	end
end)

print("[Vault] client ready \u{2014} cinematic, chamber grade and gold feedback armed")
