--[[
	SiftClientController  --  StarterPlayerScripts.SiftClientController

	Everything the player feels while sifting: the swing, the deck jolting under
	it, sand pouring through the mesh, crust breaking loose, and the reveal.
	Replaces WashClientController.

	It owns none of the truth. It reports reversals and renders what the server
	says happened.

	----------------------------------------------------------------------
	THE SWING
	----------------------------------------------------------------------
	Hold the trigger and move the mouse side to side. The controller tracks the
	furthest point the cursor has reached in the direction it is currently
	travelling, and calls it a reversal when the cursor comes back from that
	extreme by more than DEADZONE pixels.

	Tracking the EXTREME rather than the per-frame delta is what makes this
	feel like a swing instead of a jitter. A frame-to-frame sign check fires on
	every wobble of the hand, so a player holding still would rack up a cadence
	of thirty and be told they were shaking too fast. Measuring travel from the
	turning point means a reversal costs real distance, exactly as a real one
	would.

	A and D are wired to the same thing, alternating. Swinging a mouse for a
	whole bag of lumps is genuinely tiring, and on a trackpad it is miserable.

	----------------------------------------------------------------------
	PREDICTION
	----------------------------------------------------------------------
	The cadence and vigour maths here are a deliberate mirror of SiftServer's,
	run off the same GameConfig numbers, so the crust darkens under the shake
	with no round trip and the meter agrees with what is actually being
	credited. It is capped at 0.99: the POP is always a server event
	(SiftChunkGone), so a chunk can never appear to break on a lie and the
	reveal can never fire early.

	The player is never told which chunk comes off NEXT beyond the one already
	in progress -- the order is the server's shuffle, and leaking it would let a
	client draw the rock coming apart before it has.

	----------------------------------------------------------------------
	THE DECK
	----------------------------------------------------------------------
	The rig's own parts are shoved about locally to follow the swing. They are
	anchored parts in a replicated model, so this is purely cosmetic and never
	leaves the machine -- which is what we want, since two players cannot share
	a bay anyway. Their home CFrames are captured on the way in and put back on
	the way out, or a bay would stay crooked after somebody walked away.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local ItemConfig = require(Modules:WaitForChild("ItemConfig"))
local ItemVisuals = require(Modules:WaitForChild("ItemVisuals"))
local Net = require(Modules:WaitForChild("Net"))
local AudioKit = require(Modules:WaitForChild("AudioKit"))

local CFG = GameConfig.Sifting

local player = Players.LocalPlayer

local function cam(): Camera
	return workspace.CurrentCamera
end

local SiftClientController = {}

-- Pixels the cursor must travel back from its turning point before that counts
-- as a reversal. Big enough that a resting hand never triggers it, small
-- enough that a brisk rhythm is not hard work.
local DEADZONE = 42

-- Top of the cadence meter. One span past the sweet spot, so "much too fast"
-- is still on the dial rather than pinned off the end of it.
local METER_MAX = CFG.CadenceBest + CFG.CadenceSpan

-- Half-width of the sweet spot, in reversals per second. The meter's lit band,
-- the hint text and the streak all read this one number, so what the player is
-- aiming at, what they are told, and what they are rewarded for cannot drift
-- apart into three slightly different opinions.
local BAND = CFG.CadenceSpan * 0.45

--[[
	THE SAND
	--------
	One chain, four links, and the player can see every one of them:

		chunk breaks  ->  its sand lands on the mesh  ->  the shake drains it
		through  ->  the catch bin fills  ->  the bin goes over

	None of it is authoritative. Every gram is downstream of a SiftChunkGone the
	server has already confirmed, so the bin can never show material the player
	did not actually shake loose -- and because it is all local, it costs the
	server nothing and replicates nowhere.

	Why the mesh load is a LEVEL and not a percentage: a bed that tracked overall
	progress would only ever grow, and the entire appeal of the thing is watching
	it pour off. It has to be able to go down, and it has to go down FASTER when
	the rhythm is good -- which is the meter's lesson told again, in sand, where
	the player is already looking.

	The numbers below are tuned against each other. SAND_PER_CHUNK x a 34-chunk
	lump is ~4.8 units through the mesh, and at BIN_PER_SAND that is ~0.7 of a
	bin -- so a bin goes over somewhere in the middle of the second lump. Often
	enough to be a rhythm of its own, rare enough to still be an event.

	SAND_PER_CHUNK IS PER CHUNK, SO IT MOVES WHEN THE CHUNK COUNT DOES. It was
	0.34 against a 14-chunk lump; ItemConfig.CrustChunkCount is 34 now, so it is
	0.34 * 14/34 = 0.14 and the TOTAL through the mesh per lump is unchanged --
	which is what keeps the bin on its every-other-lump rhythm. Left at 0.34 the
	bin would have gone over more than twice per lump.
]]
local SAND_PER_CHUNK = 0.14 -- mesh load one broken chunk dumps, on a 0..1 bed
local SAND_DRAIN = 0.55     -- bed drained per second at rate 6 and full vigour
local SAND_HEIGHT = 0.22    -- studs of bed at a full mesh
local BIN_PER_SAND = 0.15   -- bin fill bought by one unit through the mesh
local BIN_RESIDUE = 0.14    -- what stays in the bin after it goes over
local LAND_DELAY = 0.18     -- pop -> sand hitting the mesh, seconds

--[[
	THE STREAK
	----------
	Reversals landed inside the band, counted -- counted per SWING rather than
	per second, or a player holding still inside the band would score the same as
	one working.

	Every STREAK_STEP of them walks one rung up a pentatonic ladder. That is the
	whole trick: the meter already tells you the rhythm is right, but a needle
	sitting in a green box is a state, and a note climbing is a JOURNEY. It gives
	holding the rhythm somewhere to go.

	It survives STREAK_GRACE seconds outside the band on purpose. Losing a
	twelve-streak to one twitch of the hand does not read as difficulty, it reads
	as unfairness, and people put the game down rather than concentrate harder.
]]
local STREAK_STEP = 3
local STREAK_GRACE = 0.7
local LADDER = { 1.00, 1.12, 1.26, 1.50, 1.68, 1.89, 2.00, 2.25, 2.52, 2.83, 3.00 }

--------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------

local S = {
	active = false,
	bay = nil,
	screen = nil,
	model = nil,
	crust = nil,
	uid = nil,
	total = 0,
	remaining = 0,
	chunks = {},      -- index -> 0..1 predicted progress
	current = nil,    -- the chunk actually working loose right now
	chunkWork = 1,

	triggering = false,
	dir = 0,          -- which way the swing is travelling: -1, 0, +1
	extreme = 0,      -- furthest cursor X reached in that direction
	reversals = {},   -- timestamps, trimmed to CadenceWindow
	cadence = 0,
	vigour = 0,
	serverVigour = 0,
	shake = 0,        -- smoothed 0..1, drives everything cosmetic
	swing = 0,        -- -1..1, where the deck is in its travel
	jolt = 0,

	streak = 0,       -- reversals landed in the band, unbroken
	streakStep = 0,   -- rung of LADDER the streak has reached
	lastInBand = 0,
	flash = 0,        -- 0..1, decaying; every "something just happened" pushes it

	deckHome = {},    -- [BasePart] = CFrame, so the rig can be put back
	lumpHome = nil,

	focusCFrame = nil,
	targetFocus = nil,
	prevCameraType = nil,
	prevCameraSubject = nil,
	kick = 0,
	kickVel = 0,
}

local fx = { pour = nil, dust = nil, pourPart = nil }
local sounds = { rattle = nil, pour = nil }
local hud = {}

-- What is sitting on the mesh right now, 0..1, and the slab that draws it.
local deck = { load = 0, bed = nil }

-- ...and where it ends up. `fill` trails `target` rather than tracking it,
-- which is the whole difference between a bin filling and a number rising.
local bin = { root = nil, mounds = {}, fill = 0, target = 0, impact = 0, spill = nil }

local function rate(): number
	return player:GetAttribute("WasherPressure") or GameConfig.Screen.Levels[1].rate
end

local function throw(): number
	return player:GetAttribute("WasherSpread") or GameConfig.Screen.Levels[1].throw
end

--------------------------------------------------------------------------
-- CADENCE  (mirrors SiftServer exactly -- same window, same curve)
--------------------------------------------------------------------------

local function cadenceNow(now: number): number
	local rev = S.reversals
	local cut = now - CFG.CadenceWindow
	while #rev > 0 and rev[1] < cut do
		table.remove(rev, 1)
	end
	return #rev / CFG.CadenceWindow
end

local function vigourOf(cadence: number): number
	local off = (cadence - CFG.CadenceBest) / CFG.CadenceSpan
	return math.max(math.clamp(1 - off * off, 0, 1), CFG.VigourFloor)
end

--------------------------------------------------------------------------
-- HUD
--------------------------------------------------------------------------

local function buildHud()
	local gui = Instance.new("ScreenGui")
	gui.Name = "SiftHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 9
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.AnchorPoint = Vector2.new(0.5, 1)
	root.Position = UDim2.new(0.5, 0, 1, -150)
	root.Size = UDim2.fromOffset(440, 138)
	root.BackgroundColor3 = Color3.fromRGB(18, 22, 28)
	root.BackgroundTransparency = 0.18
	root.BorderSizePixel = 0
	root.Parent = gui
	Instance.new("UICorner", root).CornerRadius = UDim.new(0, 14)

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(16, 8)
	title.Size = UDim2.new(1, -32, 0, 26)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 20
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.TextColor3 = ItemConfig.rarityColor("Unknown")
	title.Text = ItemConfig.LumpDisplayName
	title.Parent = root

	local barBg = Instance.new("Frame")
	barBg.Name = "BarBg"
	barBg.Position = UDim2.fromOffset(16, 40)
	barBg.Size = UDim2.new(1, -32, 0, 18)
	barBg.BackgroundColor3 = Color3.fromRGB(8, 10, 14)
	barBg.BorderSizePixel = 0
	barBg.Parent = root
	Instance.new("UICorner", barBg).CornerRadius = UDim.new(1, 0)

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.Size = UDim2.fromScale(0, 1)
	bar.BackgroundColor3 = Color3.fromRGB(214, 176, 96)
	bar.BorderSizePixel = 0
	bar.Parent = barBg
	Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)

	-- THE RHYTHM METER.
	--
	-- Without this the mechanic is unlearnable. Vigour peaks at a cadence the
	-- player cannot see, falls off on BOTH sides, and the only feedback would be
	-- a rock coming apart at a mystery speed -- so a player shaking as hard as
	-- they can would conclude the game was broken. The lit band IS the sweet
	-- spot; the needle is where they actually are.
	local meterBg = Instance.new("Frame")
	meterBg.Name = "MeterBg"
	meterBg.Position = UDim2.fromOffset(16, 66)
	meterBg.Size = UDim2.new(1, -32, 0, 14)
	meterBg.BackgroundColor3 = Color3.fromRGB(8, 10, 14)
	meterBg.BorderSizePixel = 0
	meterBg.Parent = root
	Instance.new("UICorner", meterBg).CornerRadius = UDim.new(1, 0)

	-- The band where vigour is worth having, drawn straight off the same
	-- numbers the server scores with rather than eyeballed to look about right.
	local lo = (CFG.CadenceBest - CFG.CadenceSpan * 0.45) / METER_MAX
	local hi = (CFG.CadenceBest + CFG.CadenceSpan * 0.45) / METER_MAX
	local zone = Instance.new("Frame")
	zone.Name = "Zone"
	zone.Position = UDim2.fromScale(lo, 0)
	zone.Size = UDim2.fromScale(hi - lo, 1)
	zone.BackgroundColor3 = Color3.fromRGB(64, 122, 88)
	zone.BorderSizePixel = 0
	zone.Parent = meterBg
	Instance.new("UICorner", zone).CornerRadius = UDim.new(1, 0)

	local needle = Instance.new("Frame")
	needle.Name = "Needle"
	needle.AnchorPoint = Vector2.new(0.5, 0.5)
	needle.Position = UDim2.fromScale(0, 0.5)
	needle.Size = UDim2.fromOffset(6, 22)
	needle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	needle.BorderSizePixel = 0
	needle.ZIndex = 3
	needle.Parent = meterBg
	Instance.new("UICorner", needle).CornerRadius = UDim.new(1, 0)

	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.BackgroundTransparency = 1
	hint.Position = UDim2.fromOffset(16, 86)
	hint.Size = UDim2.new(1, -32, 0, 22)
	hint.Font = Enum.Font.GothamMedium
	hint.TextSize = 14
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.TextTruncate = Enum.TextTruncate.AtEnd
	hint.TextColor3 = Color3.fromRGB(168, 178, 192)
	hint.Text = "Hold and swing side to side"
	hint.Parent = root

	local tierLine = Instance.new("TextLabel")
	tierLine.Name = "Tier"
	tierLine.BackgroundTransparency = 1
	tierLine.Position = UDim2.fromOffset(16, 108)
	tierLine.Size = UDim2.new(1, -32, 0, 20)
	tierLine.Font = Enum.Font.GothamMedium
	tierLine.TextSize = 13
	tierLine.TextXAlignment = Enum.TextXAlignment.Left
	tierLine.TextTruncate = Enum.TextTruncate.AtEnd
	tierLine.TextColor3 = Color3.fromRGB(126, 136, 150)
	tierLine.Text = ""
	tierLine.Parent = root

	-- THE STREAK COUNTER, right-aligned on the title row.
	--
	-- Hidden below 3. A counter that reads "x1" on the first swing of every
	-- session is wallpaper -- it has to APPEAR, as the reward for having already
	-- done something, or it is just another number on a panel of numbers.
	local streak = Instance.new("TextLabel")
	streak.Name = "Streak"
	streak.AnchorPoint = Vector2.new(1, 0)
	streak.BackgroundTransparency = 1
	streak.Position = UDim2.new(1, -16, 0, 4)
	streak.Size = UDim2.fromOffset(120, 30)
	streak.Font = Enum.Font.GothamBlack
	streak.TextSize = 22
	streak.TextXAlignment = Enum.TextXAlignment.Right
	streak.TextTransparency = 1
	streak.TextColor3 = Color3.fromRGB(255, 214, 130)
	streak.Text = ""
	streak.ZIndex = 2
	streak.Parent = root

	-- Scaled from its own right edge, so a punch on the counter grows it INTO
	-- the panel instead of shoving it off the side.
	local streakScale = Instance.new("UIScale")
	streakScale.Parent = streak

	-- The panel itself answers the rhythm: an edge that lights when the swing is
	-- worth something and dulls when it is not. It is the only piece of feedback
	-- here a player can read WITHOUT looking away from the lump -- everything
	-- else on this panel costs them a glance, and a glance costs them the beat.
	local edge = Instance.new("UIStroke")
	edge.Thickness = 2
	edge.Color = Color3.fromRGB(150, 245, 178)
	edge.Transparency = 1
	edge.Parent = root

	--[[
		THE WAY OUT, and it is not decoration.

		Without it a session can be inescapable. Movement is sunk for the whole
		session (see setControls, which binds the character actions to a Sink), so
		walking out of range is not an option any more -- that used to be the
		informal exit and it no longer exists. That left exactly one way to leave:
		the Q key.

		A player on touch has no Q. They would mount a lump and then hold it
		forever, with the camera locked on a screen deck and no way back to the
		beach. The keyboard hint on the button is there so keyboard players learn
		the shortcut and stop needing to aim at it.

		ABOVE the panel rather than inside it: every row in there is already
		spoken for, and a control tucked between the meter and the tier line reads
		as one more readout rather than as a button.
	--]]
	local exit = Instance.new("TextButton")
	exit.Name = "Exit"
	exit.AnchorPoint = Vector2.new(1, 1)
	exit.Position = UDim2.new(1, 0, 0, -10)
	exit.Size = UDim2.fromOffset(132, 34)
	exit.BackgroundColor3 = Color3.fromRGB(154, 52, 48)
	exit.BorderSizePixel = 0
	exit.AutoButtonColor = false
	exit.Font = Enum.Font.GothamBold
	exit.TextSize = 15
	exit.TextColor3 = Color3.fromRGB(255, 236, 232)
	exit.Text = "\u{2715}  LEAVE  (Q)"
	exit.ZIndex = 4
	exit.Parent = root
	Instance.new("UICorner", exit).CornerRadius = UDim.new(0, 10)

	local exStroke = Instance.new("UIStroke")
	exStroke.Thickness = 2
	exStroke.Color = Color3.fromRGB(26, 12, 12)
	exStroke.Transparency = 0.35
	exStroke.Parent = exit

	local EXIT_IDLE = Color3.fromRGB(154, 52, 48)
	local EXIT_HOT = Color3.fromRGB(198, 74, 68)
	exit.MouseEnter:Connect(function()
		TweenService:Create(exit, TweenInfo.new(0.12), { BackgroundColor3 = EXIT_HOT }):Play()
	end)
	exit.MouseLeave:Connect(function()
		TweenService:Create(exit, TweenInfo.new(0.12), { BackgroundColor3 = EXIT_IDLE }):Play()
	end)
	-- Activated, not MouseButton1Click: it fires for a touch tap too, which is
	-- the entire reason this button exists.
	exit.Activated:Connect(function()
		Net.get("SiftEndRequest"):FireServer()
	end)

	hud.gui, hud.root, hud.title, hud.bar, hud.hint = gui, root, title, bar, hint
	hud.exit = exit
	hud.needle, hud.zone, hud.tier = needle, zone, tierLine
	hud.streak, hud.streakScale, hud.edge = streak, streakScale, edge
end

local function updateHud()
	if not hud.gui then
		return
	end
	local done = (S.total > 0) and (1 - S.remaining / S.total) or 0
	hud.bar.Size = UDim2.fromScale(done, 1)
	hud.bar.BackgroundColor3 = Color3.fromRGB(214, 176, 96)
		:Lerp(Color3.fromRGB(150, 245, 178), done)
	hud.title.Text = string.format("%s  --  %d%% FREE",
		ItemConfig.LumpDisplayName, math.floor(done * 100 + 0.001))

	hud.needle.Position = UDim2.fromScale(math.clamp(S.cadence / METER_MAX, 0, 1), 0.5)
	hud.needle.BackgroundColor3 = Color3.fromRGB(255, 120, 100)
		:Lerp(Color3.fromRGB(150, 245, 178), S.vigour)

	-- Say which way to correct, not just that it is wrong. "Too fast" is the
	-- one a player will never guess on their own, because every other game has
	-- trained them that harder is better.
	if not S.triggering then
		hud.hint.Text = "Hold and swing side to side  --  A / D works too"
		hud.hint.TextColor3 = Color3.fromRGB(168, 178, 192)
	elseif S.cadence < CFG.CadenceBest - CFG.CadenceSpan * 0.45 then
		hud.hint.Text = "Swing faster"
		hud.hint.TextColor3 = Color3.fromRGB(255, 190, 110)
	elseif S.cadence > CFG.CadenceBest + CFG.CadenceSpan * 0.45 then
		hud.hint.Text = "Too fast -- ease off and swing wider"
		hud.hint.TextColor3 = Color3.fromRGB(255, 150, 130)
	else
		hud.hint.Text = "Good rhythm -- hold it there"
		hud.hint.TextColor3 = Color3.fromRGB(150, 245, 178)
	end

	hud.tier.Text = string.format("%s  |  %d chunks left  |  %d%% power",
		player:GetAttribute("WasherLabel") or GameConfig.Screen.Levels[1].label,
		S.remaining, math.floor(S.vigour * 100 + 0.5))

	if S.streak >= 3 then
		hud.streak.Text = "x" .. S.streak
		hud.streak.TextTransparency = 0
		-- Gold at three, green by twenty-four: the colour is the only thing that
		-- tells a long streak from a short one at a glance.
		hud.streak.TextColor3 = Color3.fromRGB(255, 214, 130)
			:Lerp(Color3.fromRGB(150, 245, 178), math.min(S.streak / 24, 1))
	else
		hud.streak.TextTransparency = 1
	end
	hud.streakScale.Scale = 1 + S.flash * 0.22

	-- The edge and the bar flash both come off S.flash, which every event that
	-- deserves a bang pushes: a ladder step, a chunk coming free, a bin going
	-- over. One decaying number, so two events landing together brighten the
	-- panel once rather than fighting over the same pixels.
	hud.edge.Transparency = 1 - math.min(S.vigour * 0.5 + S.flash * 0.5, 1)
	hud.edge.Color = Color3.fromRGB(255, 150, 130):Lerp(Color3.fromRGB(150, 245, 178), S.vigour)
	if S.flash > 0.01 then
		hud.bar.BackgroundColor3 = hud.bar.BackgroundColor3:Lerp(Color3.new(1, 1, 1), S.flash * 0.8)
	end
end

--------------------------------------------------------------------------
-- AUDIO
--------------------------------------------------------------------------

--[[
	THE SIFT IS THE GAME'S CENTREPIECE, AND IT IS TWO LOOPS.

	The frame rattling and the material actually falling through the mesh are
	separate on purpose, and they answer different things -- see updateAudio.
	Both are long recordings (20.7s and 28.0s) so neither has a seam the ear can
	find over a minute of shaking.

	The hand-rolled whoosh and streak pools that used to be built here are gone.
	They existed because a whoosh fires five or six times a second and
	Instance-per-shot would have pushed hundreds of Sounds a minute through
	Debris -- a correct concern, but AudioKit now pools every slot that declares
	a voice count, so the SwingWhoosh slot gets three rotating voices for free
	and this file no longer has to know about it.
]]
local function startAudio(parent: Instance)
	sounds.rattle = AudioKit.loop("ScreenRattle", parent)
	sounds.pour = AudioKit.loop("SiftPour", parent)
	-- Hold the music back for the session. Sifting is the closest, most detailed
	-- thing in the game -- grain through wire, an inch from your face -- and that
	-- texture is the whole point of the minigame. Music at full level does not
	-- drown it so much as flatten it: the ear stops picking out the individual
	-- grains and starts hearing one wash of noise. Paired with the loops above
	-- rather than with beginSession/endSession directly, so the duck cannot
	-- outlive the sound it was making room for.
	AudioKit.duckMusic(0.5, 1.2)
end

local function stopAudio()
	for k, h in sounds do
		if h then
			-- Faded, not destroyed. Cutting a loop dead at the end of a session
			-- leaves a click, which is the same edge the attack ramp removes at
			-- the other end of every one-shot.
			h:stop(0.3)
			sounds[k] = nil
		end
	end
	-- Music back up, and slower than it went down. A duck should arrive quickly
	-- enough to make room and leave slowly enough that nobody catches it going.
	AudioKit.duckMusic(1, 2.2)
end

local function updateAudio(dt: number)
	if sounds.rattle then
		-- The frame answers the SWING, not the score: it rattles because it is
		-- being thrown about, whether or not the rhythm is any good. Tying this
		-- to vigour instead would go quiet exactly when a struggling player is
		-- shaking hardest, which reads as the game ignoring them.
		sounds.rattle:set(S.shake, 1 + math.min(S.cadence / METER_MAX, 1.2) * 0.5, dt)
	end
	if sounds.pour then
		-- The pour is the opposite: it is the sound of material actually coming
		-- off, so it follows vigour and goes quiet when the rhythm is wasted.
		sounds.pour:set(S.shake * S.vigour, 0.9 + (rate() / 15) * 0.4, dt)
	end
end

-- The local playOneShot is gone; AudioKit.play replaces it everywhere below.
-- It built a bare Sound off a raw id, so it had no bus (and so ignored the
-- Settings panel's SFX toggle), no attack ramp, and no variation beyond
-- whatever pitch each call site happened to randomise for itself.

--------------------------------------------------------------------------
-- FX
--------------------------------------------------------------------------

local function ensureFx()
	if fx.pourPart or not S.screen then
		return
	end
	-- Sits just under the mesh, so everything it throws is already below the
	-- screen and falling into the bin. Wide and flat, so it pours off the whole
	-- deck rather than trickling out of a point in the middle.
	local p = Instance.new("Part")
	p.Name = "SiftPourPoint"
	p.Size = Vector3.new(S.screen.Size.X * 0.8, 0.1, S.screen.Size.Z * 0.8)
	p.Transparency = 1
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CFrame = S.screen.CFrame * CFrame.new(0, -0.35, 0)
	p.Parent = workspace
	fx.pourPart = p
	fx.pour = ItemVisuals.makeGritEmitter(p)
	fx.dust = ItemVisuals.makeImpactEmitter(p)
end

local function clearFx()
	if fx.pourPart then
		fx.pourPart:Destroy()
		fx.pourPart = nil
		fx.pour, fx.dust = nil, nil
	end
end

--------------------------------------------------------------------------
-- THE SAND  --  see the chain in the constants at the top of this file
--------------------------------------------------------------------------

local function ensureSand()
	if not S.screen then
		return
	end

	-- The bed on the mesh. Starts at nothing, so an empty screen shows bare wire
	-- and the first chunk to break has something visible to change.
	if not deck.bed then
		local b = Instance.new("Part")
		b.Name = "SiftDeckSand"
		b.Size = Vector3.new(S.screen.Size.X * 0.95, 0.02, S.screen.Size.Z * 0.95)
		b.Color = Color3.fromRGB(198, 176, 138)
		b.Material = Enum.Material.Sand
		b.Anchored = true
		b.CanCollide = false
		b.CanQuery = false
		b.CanTouch = false
		b.CastShadow = false
		b.Transparency = 1
		-- Parented to workspace, not into the bay, for the same reason the pour
		-- point is: the bay is a replicated model the server may tear down, and a
		-- purely local prop hanging inside it would go with it mid-session.
		b.Parent = workspace
		deck.bed = b
	end

	-- The heap in the catch bin.
	--
	-- THREE mounds, not one. A single centred lump growing straight up reads as
	-- a piston; mounds that start at different fills and spread outward read as
	-- something being poured in from above, which is what is actually happening.
	if not bin.root and S.bay then
		local root = S.bay:FindFirstChild("CatchBin", true)
		if root and root:IsA("BasePart") then
			bin.root = root
			local wx, wz = root.Size.X * 0.3, root.Size.Z * 0.3
			local spots = {
				Vector3.new(-0.45, 0, 0.18),
				Vector3.new(0.08, 0, -0.3),
				Vector3.new(0.5, 0, 0.34),
			}
			for i, spot in spots do
				local middle = (i == 2)
				local m = Instance.new("Part")
				m.Name = "SiftHeap" .. i
				m.Size = Vector3.new(0.1, 0.1, 0.1)

				-- A WIDE FLAT DOME, and the mesh is the only way to get one.
				--
				-- `Shape = Enum.PartType.Ball` does NOT give an ellipsoid when the
				-- three Size axes differ -- it draws a sphere of the SMALLEST one.
				-- So a heap sized (2.6, 0.9, 2.2) renders as a 0.9 marble, and a
				-- bin filling with sand looks like a bin collecting pebbles. It is a
				-- silent failure: no warning, no error, the part is simply the wrong
				-- shape, and the bug is invisible until something in the scene gives
				-- you a width to compare against.
				--
				-- A SpecialMesh of MeshType Sphere fills the part's Size on all
				-- three axes and is what actually produces the dome. (BayBuilder's
				-- authored Tailings had the same bug for the same reason; they are
				-- in this very bin, and are fixed to match.)
				local dome = Instance.new("SpecialMesh")
				dome.MeshType = Enum.MeshType.Sphere
				dome.Parent = m
				m.Color = Color3.fromRGB(186, 164, 128)
					:Lerp(Color3.fromRGB(150, 132, 108), i * 0.16)
				m.Material = Enum.Material.Sand
				m.Anchored = true
				m.CanCollide = false
				m.CanQuery = false
				m.CanTouch = false
				m.CastShadow = false
				m.Transparency = 1
				m.Parent = workspace
				table.insert(bin.mounds, {
					part = m,
					-- Fill this mound has to wait for before it starts. The middle
					-- one goes first and is the biggest; the outer two lag it, so
					-- the heap grows out of the centre rather than in lockstep.
					lead = middle and 0 or 0.22,
					width = Vector3.new(wx * (middle and 1.5 or 1.15), 0, wz * (middle and 1.4 or 1.05)),
					spot = Vector3.new(spot.X * root.Size.X * 0.5, 0, spot.Z * root.Size.Z * 0.5),
				})
			end
			bin.spill = ItemVisuals.makeSandFallEmitter(root)
		end
		-- A hand-authored bay is only contracted to provide Screen and
		-- PromptAnchor (see BayBuilder's header), so a missing CatchBin is legal.
		-- Everything below is written to no-op on bin.root == nil rather than to
		-- warn: the mesh still loads and drains, there is simply nowhere to watch
		-- it land, and that is a degraded bay rather than a broken one.
	end
end

local function clearSand()
	if deck.bed then
		deck.bed:Destroy()
		deck.bed = nil
	end
	for _, m in bin.mounds do
		if m.part then
			m.part:Destroy()
		end
	end
	table.clear(bin.mounds)
	if bin.spill then
		bin.spill:Destroy()
		bin.spill = nil
	end
	bin.root = nil
	bin.fill, bin.target, bin.impact = 0, 0, 0
	deck.load = 0
end

--[[
	The bin going over.

	Not a reward for anything in particular, and deliberately not tied to
	finishing a lump -- the reveal already owns that beat and does not need
	company. This fires on volume alone, somewhere in the middle of whichever
	lump happens to top the bin up, which makes it the one thing in the loop the
	player does not see coming.
]]
local function spillBin()
	if not bin.root then
		bin.target = BIN_RESIDUE
		return
	end

	bin.target = BIN_RESIDUE
	bin.impact = 1
	AudioKit.play("BinDump", bin.root, 1.15, 0.9)

	if bin.spill then
		bin.spill.Rate = 90
		bin.spill.Enabled = true
		task.delay(0.7, function()
			if bin.spill then
				bin.spill.Enabled = false
				bin.spill.Rate = 0
			end
		end)
	end

	local lip = bin.root.Size.Y * 0.5
	ItemVisuals.spillSand(
		bin.root.CFrame * CFrame.new(0, lip + 0.7, 0),
		14,
		bin.root.Size.X * 0.9,
		bin.root.Position.Y + lip
	)

	S.kickVel += 2.2
	S.flash = 1
end

local function updateSand(dt: number)
	-- MESH -> BIN. The bed drains at the rate the deck is actually working at,
	-- so a good rhythm visibly clears it and a bad one lets it pile up.
	if deck.load > 0 then
		local drained = math.min(deck.load, SAND_DRAIN * (rate() / 6) * S.shake * S.vigour * dt)
		deck.load -= drained
		bin.target += drained * BIN_PER_SAND
	end

	if deck.bed and S.screen then
		local h = 0.02 + deck.load * SAND_HEIGHT
		deck.bed.Size = Vector3.new(deck.bed.Size.X, h, deck.bed.Size.Z)
		-- Lags the deck and tips with it. Loose sand in a swinging tray does not
		-- travel with the tray, and the lag is most of what sells the weight.
		--
		-- SAND_HEIGHT is set against the crust, not picked by eye. A full bed tops
		-- out 0.16 above the screen's centre; the lowest chunk of a mounted lump
		-- has its centre at 0.09 and already reaches 0.54 BELOW the screen plane.
		-- So the bed laps over the bottom of the rock -- which is what a rock
		-- sitting in sand should look like -- without ever climbing far enough to
		-- hide the one object the camera is framed on.
		deck.bed.CFrame = S.screen.CFrame
			* CFrame.new(S.swing * 0.14, -0.06 + h * 0.5, 0)
			* CFrame.Angles(0, 0, -S.swing * 0.06)
		-- Fades out only over the last quarter, not linearly across the whole
		-- range. Sand does not become see-through as it drains, it becomes
		-- THINNER -- and the height above is already saying that. A bed that
		-- tracked transparency to load in a straight line sat at half transparent
		-- through the entire middle of a lump and read as a haze over the wire
		-- rather than as material lying on it.
		deck.bed.Transparency = 1 - math.clamp(deck.load * 4, 0, 1) * 0.95
	end

	if bin.target > 1 then
		spillBin()
	end
	bin.fill += (bin.target - bin.fill) * (1 - math.exp(-dt * 7))
	bin.impact = math.max(0, bin.impact - dt * 3.5)

	if not bin.root then
		return
	end

	local floor = bin.root.Size.Y * 0.5
	for _, m in bin.mounds do
		local f = math.clamp((bin.fill - m.lead) / (1 - m.lead), 0, 1)
		-- Squash and stretch on a landing: flat and wide for a moment, then back.
		-- Free, and it is most of what makes a heap feel like weight rather than
		-- like a mesh being scaled.
		local squash = 1 - bin.impact * 0.3
		local spread = 1 + bin.impact * 0.12
		local h = (0.12 + f) * squash
		m.part.Size = Vector3.new(
			m.width.X * (0.5 + f * 0.5) * spread,
			h,
			m.width.Z * (0.5 + f * 0.5) * spread
		)
		-- Centre sits a shade under the bin floor, so the ellipsoid reads as a
		-- dome bedded into it rather than a ball resting on it.
		m.part.CFrame = bin.root.CFrame
			* CFrame.new(m.spot.X + S.swing * 0.1 * f, floor + h * 0.42, m.spot.Z)
		m.part.Transparency = (f > 0.01) and 0 or 1
	end
end

--------------------------------------------------------------------------
-- THE DECK
--------------------------------------------------------------------------

-- Everything that should swing with the screen. Captured once per session so a
-- bay is always put back exactly as it was found.
local DECK_PARTS = { ScreenRail = true, Wire = true, Grip = true, Spring = true }

local function captureDeck()
	S.deckHome = {}
	if not S.bay then
		return
	end
	for _, d in ipairs(S.bay:GetDescendants()) do
		if d:IsA("BasePart") and DECK_PARTS[d.Name] then
			S.deckHome[d] = d.CFrame
		end
	end
	if S.screen then
		S.deckHome[S.screen] = S.screen.CFrame
	end
end

local function restoreDeck()
	for p, home in pairs(S.deckHome) do
		if p.Parent then
			p.CFrame = home
		end
	end
	S.deckHome = {}
end

local function driveDeck()
	if not S.screen then
		return
	end
	-- Side to side in the deck's own frame, so a rotated bay still swings across
	-- its own width rather than along some world axis.
	local amp = 0.55 * throw() * S.shake
	local offset = CFrame.new(S.swing * amp, -math.abs(S.swing) * amp * 0.15, 0)
	for p, home in pairs(S.deckHome) do
		if p.Parent then
			p.CFrame = home * offset
		end
	end
	if S.model and S.lumpHome then
		-- The lump rides the deck, and lags it very slightly -- it is loose in
		-- there, not bolted to it.
		S.model:PivotTo(S.lumpHome * CFrame.new(S.swing * amp * 0.85, 0, 0))
	end
end

--------------------------------------------------------------------------
-- SESSION
--------------------------------------------------------------------------

--------------------------------------------------------------------------
-- CLEARING THE SHOT
--------------------------------------------------------------------------
--[[
	Same treatment as WashClientController, and for the same reason: the camera
	sits in front of the screen looking back at it with the player standing in
	between, so the character's head sat over the lump and the sifter came in
	from both sides.

	This controller is not the one ClientMain currently starts -- Wash is -- but
	the two are a matched pair that get switched over together (see ClientMain's
	header), so the fix lives in both or it silently disappears on the day
	somebody flips the switch.

	LocalTransparencyModifier, not Transparency: client-only, leaves the real
	property alone, nothing replicates. Decals have no such property, so those
	are saved and put back.
]]
local shot = { conns = {}, decals = {} }

local function rigRoots(): { Instance }
	local roots = {}
	local char = player.Character
	if char then
		table.insert(roots, char)
	end
	for _, name in { "CTB_Sifter", "CTB_Roller" } do
		local m = workspace:FindFirstChild(name)
		if m then
			table.insert(roots, m)
		end
	end
	return roots
end

local function veil(inst: Instance)
	if inst:IsA("BasePart") then
		inst.LocalTransparencyModifier = 1
	elseif inst:IsA("Decal") or inst:IsA("Texture") then
		if shot.decals[inst] == nil then
			shot.decals[inst] = inst.Transparency
		end
		inst.Transparency = 1
	end
end

local function restoreShot()
	for _, c in shot.conns do
		c:Disconnect()
	end
	table.clear(shot.conns)
	for _, root in rigRoots() do
		for _, d in root:GetDescendants() do
			if d:IsA("BasePart") then
				d.LocalTransparencyModifier = 0
			end
		end
	end
	for decal, t in shot.decals do
		if decal.Parent then
			decal.Transparency = t
		end
	end
	table.clear(shot.decals)
end

local function clearShot()
	restoreShot()   -- idempotent, so a resumed session cannot double up handlers
	for _, root in rigRoots() do
		for _, d in root:GetDescendants() do
			veil(d)
		end
		-- Accessories stream in late and a tool can be handed over AFTER this
		-- runs, so anything arriving mid-session has to be caught as it lands.
		table.insert(shot.conns, root.DescendantAdded:Connect(veil))
	end
end

local function enterCamera(screen: BasePart)
	local c = cam()
	if S.prevCameraType == nil then
		S.prevCameraType = c.CameraType
		S.prevCameraSubject = c.CameraSubject
	end

	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local from = root and root.Position or (screen.Position + Vector3.new(0, 0, 10))
	local flat = from - screen.Position
	flat = Vector3.new(flat.X, 0, flat.Z)
	local dir = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(0, 0, 1)

	-- Framed on the lump, but from higher up and closer in than the washer's
	-- shot: you stand OVER a screen and look down into it, and the bin under
	-- the mesh has to be in frame or the crust falls into nothing.
	local focus = screen.Position + Vector3.new(0, screen.Size.Y * 0.5 + 1.1, 0)
	S.targetFocus = CFrame.lookAt(focus + dir * 6.0 + Vector3.new(0, 3.4, 0), focus)
	S.focusCFrame = c.CFrame
	c.CameraType = Enum.CameraType.Scriptable
end

local function exitCamera()
	local c = cam()
	if S.prevCameraType then
		c.CameraType = S.prevCameraType
		if S.prevCameraSubject then
			c.CameraSubject = S.prevCameraSubject
		end
	else
		c.CameraType = Enum.CameraType.Custom
	end
	S.prevCameraType, S.prevCameraSubject = nil, nil
	S.focusCFrame, S.targetFocus = nil, nil
end

-- Assigned down in the REVERSALS section, because it calls reverse(). Read only
-- from inside a live session, long after the module has finished loading, so it
-- is always populated by the time anything dereferences it.
local shakeAction

local MOVE_LOCK = "BeachCleanupSiftMoveLock"
local SHAKE_KEYS = "BeachCleanupSiftKeys"

--[[
	Freezing the character for the length of a session.

	This used to be PlayerModule:GetControls():Disable(), inside a pcall that
	fell back to nil. There is no PlayerModule in PlayerScripts in this place at
	all, so that fallback was taken every single time and the character was never
	actually frozen -- a silent no-op inherited from the wash controller. It went
	unnoticed for as long as the mechanic was a jet, because the washer bound no
	movement keys. The moment A and D became the swing, the player walked out of
	their own bay while sifting.

	ContextActionService does not care where control lives, so this works whether
	or not the place ever gets a PlayerModule back.

	A and D are bound as REAL actions rather than read off InputBegan, and that is
	the load-bearing part: sunk input still reaches UserInputService, but with
	gameProcessedEvent set -- so an InputBegan handler that (correctly) ignores
	processed input would throw the swing away along with the movement.
--]]
local function setControls(enabled: boolean)
	if enabled then
		ContextActionService:UnbindAction(SHAKE_KEYS)
		ContextActionService:UnbindAction(MOVE_LOCK)
		return
	end

	-- Bound first so the A/D binding lands ON TOP of it: ContextActionService is
	-- a stack, and the most recently bound action sees the input first.
	ContextActionService:BindActionAtPriority(
		MOVE_LOCK,
		function()
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.PlayerActions.CharacterForward,
		Enum.PlayerActions.CharacterBackward,
		Enum.PlayerActions.CharacterLeft,
		Enum.PlayerActions.CharacterRight,
		Enum.PlayerActions.CharacterJump
	)

	ContextActionService:BindActionAtPriority(
		SHAKE_KEYS,
		function(...)
			return shakeAction and shakeAction(...) or Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value + 1,
		Enum.KeyCode.A,
		Enum.KeyCode.D
	)
end

local function beginSession(payload)
	if not (payload and payload.model and payload.screen) then
		return
	end
	local resuming = S.active

	S.active = true
	S.bay = payload.bay
	S.screen = payload.screen
	S.model = payload.model
	S.crust = payload.model:FindFirstChild("Crust")
	S.uid = payload.uid
	-- Via ItemConfig, never a literal -- a lump's identity is hidden from the
	-- client, so it cannot look the count up and this is the one number it must
	-- be told or assume.
	S.total = payload.chunkTotal or ItemConfig.CrustChunkCount
	S.remaining = S.total
	S.current = payload.current
	S.chunks = {}
	for i = 1, S.total do
		S.chunks[i] = 0
	end
	S.chunkWork = CFG.ChunkWork -- Toughness is server-side; prediction is close enough
	S.lumpHome = payload.model:GetPivot()

	-- Auto-advance re-enters here without ever leaving the bay, so the deck is
	-- already captured and already swinging. Recapturing mid-swing would bake
	-- the current offset in as the new home and the rig would drift sideways a
	-- little more with every lump.
	if not resuming then
		captureDeck()
		startAudio(S.screen)
		enterCamera(S.screen)
		setControls(false)
		clearShot()
	end
	ensureFx()
	-- Guarded internally, so auto-advance keeps the bin it has been filling. The
	-- heap surviving from one lump to the next IS the accumulation -- resetting
	-- it per lump would throw away the only thing in the bay that gets bigger.
	ensureSand()

	AudioKit.play("Mount", S.screen, 1.2)
	UserInputService.MouseIconEnabled = true

	if hud.gui then
		hud.gui.Enabled = true
		hud.title.TextColor3 = ItemConfig.rarityColor("Unknown")
	end
end

local function endSession()
	if not S.active then
		return
	end
	S.active = false
	S.triggering = false
	S.shake, S.swing, S.vigour, S.cadence = 0, 0, 0, 0
	S.dir, S.extreme = 0, 0
	S.reversals = {}
	S.current = nil
	S.streak, S.streakStep, S.flash = 0, 0, 0

	if fx.pour then
		fx.pour.Enabled = false
		fx.pour.Rate = 0
	end
	if fx.dust then
		fx.dust.Enabled = false
		fx.dust.Rate = 0
	end
	clearFx()
	clearSand()
	stopAudio()
	restoreDeck()
	exitCamera()
	setControls(true)
	restoreShot()

	S.bay, S.screen, S.model, S.crust, S.uid = nil, nil, nil, nil, nil
	S.lumpHome = nil
	S.total, S.remaining = 0, 0
	S.chunks = {}

	if hud.gui then
		hud.gui.Enabled = false
	end
end

--------------------------------------------------------------------------
-- REVERSALS
--------------------------------------------------------------------------


local function reverse(d: number)
	local now = os.clock()
	-- Same floor the server enforces, applied here too so we never spend a
	-- packet on something that is going to be thrown away at the other end.
	if #S.reversals > 0 and now - S.reversals[#S.reversals] < CFG.MinReversalInterval then
		return
	end
	S.cadence = cadenceNow(now)
	table.insert(S.reversals, now)
	S.vigour = vigourOf(S.cadence)
	S.jolt = 1

	-- Pitched off cadence, so a faster rhythm is audibly faster, and nudged a
	-- few percent by DIRECTION -- a hair up going right, a hair down going left.
	-- That second part is what turns one repeated sample into a back-and-forth
	-- instead of a stutter, and it costs nothing.
	AudioKit.play("SwingWhoosh", S.screen,
		0.62 + S.vigour * 0.9,
		(1.0 + math.min(S.cadence / METER_MAX, 1.2) * 0.5) * (d > 0 and 1.04 or 0.96))

	-- A few grains jumping off the mesh on the beat. Tiny, but it is what makes
	-- the deck look like it is throwing sand rather than sliding under it.
	if fx.dust and S.shake > 0.15 then
		fx.dust:Emit(math.floor(2 + S.vigour * 5))
	end

	-- THE LADDER. Counted per swing, not per second -- see STREAK_STEP.
	if math.abs(S.cadence - CFG.CadenceBest) <= BAND then
		S.streak += 1
		S.lastInBand = now
		if S.streak % STREAK_STEP == 0 then
			S.streakStep = math.min(S.streakStep + 1, #LADDER)
			-- A struck tuning fork, transposed a rung at a time. The slot is
			-- declared with zero pitch jitter for exactly this: the ladder IS
			-- the pitch information, and a few percent of random on top of it
			-- would read as the instrument being out of tune rather than as
			-- texture.
			AudioKit.play("StreakStep", S.screen,
				0.65 + (S.streakStep / #LADDER) * 0.5, LADDER[S.streakStep])
			S.flash = math.min(1, S.flash + 0.4)
		end
	end

	Net.get("SiftShake"):FireServer({ dir = d })
end

-- The keyboard swing. Same alternation rule as the mouse and as the server: a
-- second A without a D in between is not a reversal and does nothing at all.
shakeAction = function(_, state, input)
	if state == Enum.UserInputState.Begin and S.active then
		local d = (input.KeyCode == Enum.KeyCode.D) and 1 or -1
		S.triggering = true
		if S.dir ~= d then
			S.dir = d
			reverse(d)
		end
	end
	return Enum.ContextActionResult.Sink
end

local function trackSwing()
	local mx = UserInputService:GetMouseLocation().X
	if not S.triggering then
		S.dir, S.extreme = 0, mx
		return
	end

	if S.dir == 0 then
		if mx > S.extreme + DEADZONE then
			S.dir, S.extreme = 1, mx
			reverse(1)
		elseif mx < S.extreme - DEADZONE then
			S.dir, S.extreme = -1, mx
			reverse(-1)
		end
	elseif S.dir > 0 then
		if mx > S.extreme then
			S.extreme = mx
		elseif mx < S.extreme - DEADZONE then
			S.dir, S.extreme = -1, mx
			reverse(-1)
		end
	else
		if mx < S.extreme then
			S.extreme = mx
		elseif mx > S.extreme + DEADZONE then
			S.dir, S.extreme = 1, mx
			reverse(1)
		end
	end
end

--------------------------------------------------------------------------
-- FRAME
--------------------------------------------------------------------------

local function onRender(dt: number)
	dt = math.min(dt, 1 / 30)
	if not S.active then
		return
	end

	trackSwing()

	local now = os.clock()
	S.cadence = cadenceNow(now)
	local swinging = S.triggering
		and #S.reversals > 0
		and (now - S.reversals[#S.reversals]) <= CFG.ShakeGrace
	S.vigour = swinging and vigourOf(S.cadence) or 0

	local target = swinging and 1 or 0
	local ease = (target > S.shake) and 22 or 6
	S.shake += (target - S.shake) * (1 - math.exp(-dt * ease))

	-- A streak survives a wobble but not a stall. Checked here rather than in
	-- reverse() because the interesting case is the player who has STOPPED
	-- landing reversals in the band -- there is no reversal left to hang it on.
	if S.streak > 0 and now - S.lastInBand > STREAK_GRACE then
		-- Only mourn a streak that was worth having. A soft tick on every
		-- three-swing fumble would be nagging, not loss.
		if S.streak >= STREAK_STEP * 2 then
			AudioKit.play("StreakBreak", S.screen)
		end
		S.streak, S.streakStep = 0, 0
	end
	S.flash = math.max(0, S.flash - dt * 2.5)

	-- Where the deck sits in its travel. Driven off the jolt rather than the raw
	-- cursor so the rig keeps swinging smoothly between reversals instead of
	-- snapping to wherever the hand happens to be.
	S.jolt = math.max(0, S.jolt - dt * 4)
	local wantSwing = (S.dir ~= 0) and S.dir * (0.35 + S.jolt * 0.65) or 0
	S.swing += (wantSwing - S.swing) * (1 - math.exp(-dt * 16))

	-- Local prediction on the chunk the server says is currently working loose,
	-- capped below 1 so the POP is always the server's call.
	if swinging and S.current then
		local i = S.current
		local gain = rate() * S.vigour * dt / S.chunkWork
		S.chunks[i] = math.min(0.99, (S.chunks[i] or 0) + gain)
		local chunk = ItemVisuals.findChunk(S.model, i)
		if chunk then
			ItemVisuals.setChunkErosion(chunk, S.chunks[i])
		end
	end

	driveDeck()
	updateSand(dt)

	if fx.pourPart and S.screen then
		fx.pourPart.CFrame = S.screen.CFrame * CFrame.new(0, -0.35, 0)
		local on = S.shake > 0.05
		if fx.pour then
			fx.pour.Enabled = on
			-- Vigour, not shake: a wasted rhythm rattles the frame but does not
			-- put much through the mesh, and the pour is the honest readout.
			fx.pour.Rate = on and (20 + S.shake * S.vigour * 110) or 0
		end
		if fx.dust then
			fx.dust.Enabled = on
			fx.dust.Rate = on and (10 + S.shake * S.vigour * 60) or 0
		end
	end

	-- Camera: ease into frame, plus a shove on each reversal.
	if S.focusCFrame and S.targetFocus then
		S.focusCFrame = S.focusCFrame:Lerp(S.targetFocus, 1 - math.exp(-dt * 6))

		local k, c = 120, 14
		local want = S.shake * 0.1
		S.kickVel += (-k * (S.kick - want) - c * S.kickVel) * dt
		S.kick += S.kickVel * dt
		S.kick = math.clamp(S.kick, -0.4, 0.4)

		local jitter = S.shake * 0.02
		-- A touch of ROLL with the swing, not just the sideways shove. Two studs
		-- of translation reads as the camera being nudged; a degree of roll on top
		-- reads as the whole rig having weight, and it is the cheapest thing in
		-- this file. Kept tiny -- past about 0.03 it stops being weight and starts
		-- being motion sickness.
		local offset = CFrame.new(
			(math.random() - 0.5) * jitter - S.swing * 0.12,
			(math.random() - 0.5) * jitter,
			S.kick
		) * CFrame.Angles(0, 0, -S.swing * 0.022)
		-- ALWAYS from focusCFrame, never from the camera's own current frame:
		-- multiplying into itself compounds every frame and drifts into space.
		cam().CFrame = S.focusCFrame * offset
	end

	updateAudio(dt)
	updateHud()
end

--------------------------------------------------------------------------
-- INPUT
--------------------------------------------------------------------------

local function onInputBegan(input: InputObject, processed: boolean)
	if processed or not S.active then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
	then
		S.triggering = true
		S.extreme = UserInputService:GetMouseLocation().X
		S.dir = 0
	elseif input.KeyCode == Enum.KeyCode.Q or input.KeyCode == Enum.KeyCode.Backspace then
		Net.get("SiftEndRequest"):FireServer()
	end
end

local function onInputEnded(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
	then
		S.triggering = false
	end
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

local started = false
function SiftClientController.start()
	if started then
		return
	end
	started = true

	buildHud()

	Net.get("SiftBegin").OnClientEvent:Connect(beginSession)
	Net.get("SiftEnd").OnClientEvent:Connect(endSession)

	Net.get("SiftChunkGone").OnClientEvent:Connect(function(payload)
		if not (S.active and payload and payload.chunk) then
			return
		end
		local i = payload.chunk
		S.chunks[i] = 1
		S.remaining = math.max(0, S.remaining - 1)
		S.current = payload.next

		local chunk = ItemVisuals.findChunk(S.model, i)
		if chunk then
			-- Straight DOWN through the mesh, with a bit of the swing on it. The
			-- washer blew chunks away from the nozzle; here gravity and the bin
			-- underneath are the whole story.
			ItemVisuals.popChunk(chunk, Vector3.new(S.swing * 4, -6, 0))
		end
		-- Rises as the lump empties, so the last flake off a big find is audibly
		-- the top of a run. Gentler than the old 0.9..1.6 sweep: that range was
		-- tuned for a synthetic snap, and a real rock tick starts sounding like
		-- a pebble rather than a crust much before the top of it.
		AudioKit.play("ChunkPop", S.screen, 1.2,
			0.92 + (1 - S.remaining / math.max(S.total, 1)) * 0.45)
		S.kickVel += 1.6
		S.flash = 1

		-- The sand does not teleport onto the mesh. The chunk pops, and a beat
		-- later what is left of it LANDS, with a thud and a puff. That gap is the
		-- whole difference between an object falling and an object being deleted,
		-- and it is one task.delay.
		task.delay(LAND_DELAY, function()
			if not S.active then
				return
			end
			deck.load = math.min(1, deck.load + SAND_PER_CHUNK)
			-- Down low, so the landing has weight the pop above it does not.
			AudioKit.play("SandDrop", S.screen, 1, 0.6)
			if fx.dust then
				fx.dust:Emit(14)
			end
		end)
	end)

	Net.get("SiftProgress").OnClientEvent:Connect(function(payload)
		if not (S.active and payload and payload.chunks) then
			return
		end
		-- Server is authoritative; snap anywhere prediction has drifted low.
		for i, v in payload.chunks do
			if (S.chunks[i] or 0) < v then
				S.chunks[i] = v
			end
		end
		S.remaining = payload.remaining or S.remaining
		S.current = payload.current or S.current
		S.serverVigour = payload.vigour or 0
	end)

	Net.get("SiftItemCleaned").OnClientEvent:Connect(function(payload)
		if not payload then
			return
		end
		S.remaining = 0
		local rarity = payload.rarity or "Common"
		-- 1.15/1.07/1.0, not the old 1.45/1.2/1.0. That spread was set against an
		-- electronic ping, where higher is the only way to say "better"; these
		-- are recorded chimes with their own character, and shifting one up a
		-- fifth just makes it small.
		local pitch = rarity == "Legendary" and 1.15 or (rarity == "Rare" and 1.07 or 1.0)
		local where = S.screen or workspace
		-- A momentary dip UNDER the reveal, so the chime rings into a gap instead
		-- of into the middle of a track. dipMusic returns to whatever standing
		-- duck is in force rather than to full, which is what makes it safe if
		-- the player walks out of the bay before the hold is up.
		AudioKit.dipMusic(0.28, 1.5)
		AudioKit.play("ItemCleaned", where, 1.1, pitch)
		if rarity == "Legendary" then
			-- The shimmer lands a beat behind the chime and rings on past it, so
			-- the rarest moment in the game ends by fading rather than stopping.
			AudioKit.stack("LegendaryHit", "FairyDust", where, 0.18)
		end
		S.kickVel += 5
		S.flash = 1

		-- Clear the mesh for the reveal. The find should come out of bare wire,
		-- not out of a bed of its own crust -- and the last of it has to go
		-- SOMEWHERE, so it goes where the rest of the lump went. Straight into the
		-- bin, which is also what can tip the bin over on the final chunk.
		bin.target += deck.load * BIN_PER_SAND
		deck.load = 0
		if fx.pour then
			fx.pour:Emit(30)
		end

		if S.model then
			local clean = S.model:FindFirstChild("Clean")
			local core = clean and clean:FindFirstChildWhichIsA("BasePart", true)
			if core then
				ItemVisuals.burstSparkle(core, rarity)
			end
		end

		if hud.gui then
			hud.title.Text = string.format("%s  --  FREE", payload.displayName or "Find")
			hud.title.TextColor3 = ItemConfig.rarityColor(rarity)
		end
	end)

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	player.CharacterRemoving:Connect(endSession)

	RunService:BindToRenderStep(
		"BeachCleanupSift",
		Enum.RenderPriority.Camera.Value + 5,
		onRender
	)
end

return SiftClientController
