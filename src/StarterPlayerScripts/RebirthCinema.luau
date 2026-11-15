--[[
	RebirthCinema  --  StarterPlayerScripts.RebirthCinema

	The client half of a rebirth: the camera, the curtain and the card. The
	player's body is lifted by the SERVER (ProgressionServer.ascend) because a
	character is a replicated model and everyone on the beach should see them
	go -- this is only the two things that genuinely are per-player.

	TWO BEATS, BOTH FROM THE SERVER, AND THE SECOND ONE IS THE IMPORTANT ONE.

		rise   they have just been anchored and are on their way up
		land   they have BEEN SET DOWN and have control back -- since 2026-09-08
		       that is on the shore they turned the tide on rather than on the
		       home spawn pad (ProgressionServer.landingCFrame)

	`land` is not a timer. The server owns when the teleport actually happens,
	so the curtain has to be lifted by the thing that did the moving -- a
	client-side countdown that agreed with it today would drift the first time
	the rise duration was retuned, and the player would watch themselves pop
	across the map. There is still a hard fallback below, because a curtain
	that never lifts is the worst failure this file can have.

	NOTHING HERE IS AUTHORITATIVE. Skip every line of it and the rebirth still
	happens, the player is still set down with control back, and they still get
	their upgrades wiped -- see the unconditional task.delay in ascend().
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Net = require(Modules:WaitForChild("Net"))
local PanelKit = require(Modules:WaitForChild("PanelKit"))
local AudioKit = require(Modules:WaitForChild("AudioKit"))
-- The card quotes the sell bonus, so it has to READ the sell bonus. It used to
-- carry its own formula (`1 + n * 0.25`) and was wrong at every tide but the
-- first: at rebirth 2 the cinematic promised 1.50x and the Turn of the Tide
-- panel behind it said 1.32x, for the same player on the same frame.
local ProgressionConfig = require(Modules:WaitForChild("ProgressionConfig"))

local C = PanelKit.C
local player = Players.LocalPlayer

local RebirthCinema = {}

-- The HUDs that get out of the way. ToastKit is NOT in this list: the server's
-- "the tide turns" message fires on the same frame and is worth reading.
-- EventHud goes, though, and the distinction is the same one: the countdown is
-- a READOUT with nothing to say, where the toast is somebody saying something.
local HIDE = { "CleanTheBeachHUD", "InventoryHud", "BeachMenuHud", "WeightHUD", "EventHud",
	-- The bought golden hour's countdown. It survives the rebirth wipe -- a boost
	-- is paid for and a tide does not take it -- so it would otherwise be the one
	-- readout still lit over the ascension.
	"BoostHud" }

-- BLACK, NOT WHITE.
--
-- The first pass took the screen to white, which is the same beat the vault's
-- own cut uses and reads as a flash -- something happening TO you, over in an
-- instant. A rebirth is the player deliberately giving up everything they own,
-- and the honest shape for that is a blackout: the world goes away, there is a
-- pause where nothing is happening at all, and then a different world fades up.
-- The pause is the point, so DARK_HOLD below is long enough to feel like one.
local CURTAIN = Color3.fromRGB(8, 6, 12)

local FADE_START = 0.55        -- fraction of the rise before the dark begins
-- 0.7, up from 0.28. The card arrives at 94% of the rise, so at 0.28 it was on
-- a clean white screen for barely a third of a second before the curtain
-- started lifting under it -- long enough to notice, nowhere near long enough
-- to read "REBIRTH 3" and the line under it.
--
-- Both of these are also how long the player is walking blind: the server hands
-- movement back the instant it has moved them, which is the honest contract but
-- means every frame of curtain after that is a frame they could be walking
-- through. Under a second and a half total, stood wherever they came down.
-- 1.4s of full black around the teleport, up from 0.7. At 0.7 the card was on
-- screen for about a third of a second before the curtain started lifting under
-- it -- long enough to notice, nowhere near long enough to read. It is also the
-- beat that makes the landing feel like arriving somewhere rather than being
-- shoved sideways.
local HOLD = 1.4               -- full black either side of the teleport
local LIFT = 0.9               -- how long the curtain takes to come back off

local gui, curtain, card, title, tide, sub
local camConn, active, hidden = nil, false, {}
local guard = 0

--[[
	THE SOUND, WHICH IS FOUR BEATS AND ONE SUSTAINED ONE.

		launch   a low whump and a whoosh -- the ground letting go
		riser    a loop dragged from pitch 0.6 to 2.0 across the climb
		boom     lands on the blackout, with a chime a fifth of a second behind
		arrive   a soft swell as the beach fades back up

	The riser is the one that does the work. The other three are punctuation; a
	rise with only punctuation is three noises and 2.4 seconds of silence between
	them, which is what this had before -- one bell at the start and nothing else
	until the player was already back on the ground.

	All of it is FLAT (nil parent): this is the player's own moment, not
	something happening out in the world with a rolloff on it. AudioKit's own
	enable check means the Settings panel's Sound Effects toggle silences the lot
	with no extra wiring here.
]]
local riser = nil

--------------------------------------------------------------------------
-- BUILD
--------------------------------------------------------------------------

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "RebirthCinema"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	-- Above everything, the vault's own curtain (200) included: a rebirth can
	-- physically not happen inside the tomb, but "above everything" is one less
	-- thing to be wrong about later.
	gui.DisplayOrder = 240
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	curtain = Instance.new("Frame")
	curtain.Name = "Curtain"
	curtain.Size = UDim2.fromScale(1, 1)
	curtain.BackgroundColor3 = CURTAIN
	curtain.BackgroundTransparency = 1
	curtain.BorderSizePixel = 0
	curtain.Visible = false
	curtain.Parent = gui

	-- The card rides ON the white rather than under it, so it arrives as the
	-- screen peaks instead of being something the fade covers up.
	card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.44)
	card.Size = UDim2.fromOffset(560, 190)
	card.BackgroundTransparency = 1
	card.Visible = false
	card.Parent = gui

	-- Repainted for a BLACK curtain. The old set was mixed against white --
	-- seaDark on white and a white outline round the title -- and every one of
	-- those choices inverts here: the title now needs to be light, and the ink
	-- outline that made gold letters pop on white does the same job on black.
	title = PanelKit.text(card, "TURN OF THE TIDE", 34, Enum.Font.LuckiestGuy, C.foam)
	title.Position = UDim2.fromOffset(0, 0)
	title.Size = UDim2.new(1, 0, 0, 44)
	PanelKit.punch(title, 4, C.ink)

	tide = PanelKit.text(card, "REBIRTH 1", 68, Enum.Font.LuckiestGuy, C.sun)
	tide.Position = UDim2.fromOffset(0, 44)
	tide.Size = UDim2.new(1, 0, 0, 84)
	PanelKit.punch(tide, 5, C.ink)

	sub = PanelKit.text(card, "", 20, Enum.Font.GothamBold, C.sandMid)
	sub.Position = UDim2.fromOffset(0, 132)
	sub.Size = UDim2.new(1, 0, 0, 30)
end

--------------------------------------------------------------------------
-- THE SHOT
--
-- Starts BELOW them and swings up and out. Rising past a camera that is
-- already above you reads as the camera falling, which is the opposite feeling
-- to the one this moment wants.
--------------------------------------------------------------------------

local function startCamera(seconds: number)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	cam.CameraType = Enum.CameraType.Scriptable

	-- Kept off the character's own facing: whichever way they happened to be
	-- looking when they clicked the button is not a shot.
	local angle = math.rad(38)
	local elapsed = 0

	if camConn then
		camConn:Disconnect()
	end
	camConn = RunService.RenderStepped:Connect(function(dt)
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not hrp then
			return
		end
		elapsed += dt
		local a = math.clamp(elapsed / math.max(seconds, 0.1), 0, 1)

		-- THE RISER, dragged upward with the player. Pitch is linear in `a` rather
		-- than in the eased curve the camera uses: the camera is describing the
		-- shot and the riser is describing the climb, and the climb is what the ear
		-- is following. It fades in over the first quarter so the launch whump has
		-- the downbeat to itself.
		if riser then
			riser:set(math.min(a * 4, 1), 1 + a * 2.3, dt)
		end
		-- Eased, so the pull-back is slowest at the start where the player is
		-- still reading what happened.
		local e = 1 - (1 - a) * (1 - a)
		local dist = 20 + e * 30
		local height = -7 + e * 16
		local ang = angle + e * 1.15
		local eye = hrp.Position + Vector3.new(math.cos(ang) * dist, height, math.sin(ang) * dist)
		cam.CFrame = CFrame.lookAt(eye, hrp.Position + Vector3.new(0, 1.5, 0))
	end)
end

local function stopCamera()
	if camConn then
		camConn:Disconnect()
		camConn = nil
	end
	local cam = workspace.CurrentCamera
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if cam then
		if hum then
			cam.CameraSubject = hum
		end
		cam.CameraType = Enum.CameraType.Custom
	end
end

--------------------------------------------------------------------------
-- HUD
--------------------------------------------------------------------------

local function hideHud()
	table.clear(hidden)
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return
	end
	for _, name in HIDE do
		local g = pg:FindFirstChild(name)
		if g and g:IsA("ScreenGui") and g.Enabled then
			g.Enabled = false
			table.insert(hidden, g)
		end
	end
end

local function showHud()
	for _, g in hidden do
		if g.Parent then
			g.Enabled = true
		end
	end
	table.clear(hidden)
end

--------------------------------------------------------------------------
-- THE SEQUENCE
--------------------------------------------------------------------------

-- One place that puts everything back, called by `land` AND by the guard timer,
-- so there is no path that leaves the player behind a white screen.
local function restore(token: number)
	if guard ~= token or not active then
		return
	end
	active = false
	stopCamera()

	-- Belt and braces: the guard timer can reach here without the card beat ever
	-- having run, and a riser left playing would climb to pitch 2 and sit there
	-- for the rest of the session.
	if riser then
		riser:stop(0.4)
		riser = nil
	end
	-- The world coming back. Quiet and a touch bright -- an arrival, not a
	-- second impact; the blackout already had the impact.
	AudioKit.play("Wave", nil, 0.65, 1.06)

	local out = TweenService:Create(curtain, TweenInfo.new(LIFT, Enum.EasingStyle.Quad),
		{ BackgroundTransparency = 1 })
	out:Play()
	TweenService:Create(card, TweenInfo.new(LIFT * 0.6), { Position = UDim2.fromScale(0.5, 0.40) }):Play()
	for _, l in { title, tide, sub } do
		TweenService:Create(l, TweenInfo.new(LIFT * 0.5), { TextTransparency = 1 }):Play()
		local st = l:FindFirstChildOfClass("UIStroke")
		if st then
			TweenService:Create(st, TweenInfo.new(LIFT * 0.5), { Transparency = 1 }):Play()
		end
	end

	showHud()
	task.delay(LIFT, function()
		if not active then
			curtain.Visible = false
			card.Visible = false
		end
	end)
end

local function rise(payload)
	if active then
		return
	end
	active = true
	guard += 1
	local token = guard

	local seconds = tonumber(payload and payload.seconds) or 2.4
	local n = math.max(1, math.floor(tonumber(payload and payload.rebirths) or 1))

	hideHud()
	startCamera(seconds)

	-- THE DOWNBEAT. Two layers on one hit -- a low whump under a whoosh -- which
	-- is how the kit gets weight out of a moment without simply getting louder.
	AudioKit.play("TideLaunch")
	AudioKit.play("SwingWhoosh", nil, 1.8, 0.62)
	riser = AudioKit.loop("TideRiser")

	-- Under the whole thing, and back up on its own. The music is a beach loop
	-- and this is the player leaving the beach; holding it at full through a
	-- blackout is the one thing that would stop the blackout reading as a pause.
	AudioKit.dipMusic(0.12, seconds + HOLD)

	curtain.Visible = true
	curtain.BackgroundTransparency = 1
	card.Visible = false

	title.TextTransparency = 0
	tide.TextTransparency = 0
	sub.TextTransparency = 0
	for _, l in { title, tide, sub } do
		local st = l:FindFirstChildOfClass("UIStroke")
		if st then
			st.Transparency = 0
		end
	end
	tide.Text = "REBIRTH " .. n
	-- ProgressionConfig.Rebirth.multiplier IS the number -- the same function
	-- ProgressionServer writes into the SellMultiplier attribute and the same one
	-- MenuHud's panel draws. It is 1.15^n, and no linear approximation of it is
	-- right anywhere: they agree at n=1 by coincidence and diverge immediately.
	sub.Text = string.format("every upgrade reset  \u{00B7}  %.2fx on everything you sell",
		ProgressionConfig.Rebirth.multiplier(n))

	-- The white comes in over the LAST part of the climb, so most of the rise
	-- is watched rather than fogged.
	local white = seconds * (1 - FADE_START)
	task.delay(seconds * FADE_START, function()
		if guard ~= token then
			return
		end
		TweenService:Create(curtain, TweenInfo.new(white, Enum.EasingStyle.Quad,
			Enum.EasingDirection.In), { BackgroundTransparency = 0 }):Play()
	end)

	task.delay(seconds * 0.94, function()
		if guard ~= token then
			return
		end
		-- The impact lands with the card, on a screen that is already black, and
		-- the chime comes a fifth of a second behind it so the moment has a tail
		-- rather than a stop.
		AudioKit.stack("TideBoom", "TideArrive", nil, 0.2)
		if riser then
			riser:stop(0.3)
			riser = nil
		end
		card.Visible = true
		card.Position = UDim2.fromScale(0.5, 0.48)
		TweenService:Create(card, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Position = UDim2.fromScale(0.5, 0.44) }):Play()
	end)

	-- THE FALLBACK. If `land` never arrives -- the server died, the remote was
	-- dropped -- the screen comes back anyway. Generous, because arriving early
	-- would cut the teleport in half on a slow frame.
	task.delay(seconds + 6, function()
		restore(token)
	end)
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

local started = false
function RebirthCinema.start()
	if started then
		return
	end
	started = true

	build()

	Net.get("RebirthAscend").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		if payload.phase == "rise" then
			rise(payload)
		elseif payload.phase == "land" then
			-- Held a beat at full white so the card is read on a clean screen
			-- rather than over the beach sliding in behind it.
			local token = guard
			task.delay(HOLD, function()
				restore(token)
			end)
		end
	end)

	-- A respawn during the sequence -- rare, but it detaches the camera from a
	-- character that no longer exists and would leave the shot pointing at
	-- nothing forever.
	player.CharacterAdded:Connect(function()
		if not active then
			stopCamera()
		end
	end)
end

return RebirthCinema
