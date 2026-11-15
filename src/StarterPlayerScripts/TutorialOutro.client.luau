--[[
	TutorialOutro  --  StarterPlayerScripts.TutorialOutro  (LocalScript)

	THE SEND-OFF, IN TWO ACTS. The card's last step completes, the shop
	unlocks, and then:

	  ACT ONE   a close-up of Sandy Salt at the tiller and his pitch. The eye
	            is not authored -- it is CHOSEN at runtime from a ring of
	            candidates by raycast, because the boat's own sail sat square
	            between the first authored eye and the man it was framing, and
	            geometry that is rebuilt each boot cannot be trusted to keep
	            any fixed line of sight open.
	  ACT TWO   the islands he is selling, one scenic orbit each -- The Dunes,
	            Sakura Cove, Ashfall Isle -- named in their own ferry tints,
	            cut together through a black curtain.

	STREAMING IS THE INVISIBLE ACTOR. This place runs StreamingEnabled, and
	every island in act two is a thousand-plus studs from the character -- a
	camera cut there lands on unstreamed nothing. So each shot is preceded by
	RequestStreamAroundAsync on its eye, under the curtain, with a bounded
	timeout: a shot that could not stream still plays (sea and sky beat a
	stall), but in practice the curtain beat is exactly the loading window.

	TRIGGERED BY AN ATTRIBUTE, NOT A REMOTE -- the tutorial's design
	(TutorialConfig's header: the two halves never speak). The server ticks
	CelebrateAttribute only for a finish that ended a tutorial the player
	actually ran; a restored veteran's join-time retirement never fires it.

	A PRESS MOVES IT ON. IT DOES NOT END IT. Any input after the opening beat
	asks for the NEXT beat: it finishes the boatman's line if that is still
	typing itself out, and otherwise cuts straight to the next island. Only a
	HELD input ends the whole show, and the hint bottom-right names both
	gestures. The handler this replaces ended everything on the first click --
	so the one gesture a curious player makes during the opening line threw
	away the three islands the send-off exists to show them.

	AND IT IS PACED FOR A PLAYER WHO CAN DO THAT. Every hold in here came down
	when the presses went in: a shot the player can end themselves does not
	have to be long enough for the slowest reader in the game.

	EVERYTHING IS PUT BACK in ONE shared cleanup however the show ends --
	played out, skipped, or errored: camera type, CFrame and field of view,
	every swept ScreenGui, the parked walk speed, every instance this made.
	A cinematic is never allowed to be the reason somebody cannot play.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local TutorialConfig = require(Modules:WaitForChild("TutorialConfig"))
local AudioKit = require(Modules:WaitForChild("AudioKit"))
local FerryConfig = require(ReplicatedStorage:WaitForChild("FerryConfig"))
local Net = require(Modules:WaitForChild("Net"))

local player = Players.LocalPlayer

local SKIP_AFTER = 0.7    -- input guard: the click that closed the last card is not a press
local HOLD_SKIP = 0.55    -- keep an input DOWN this long and the whole show ends
local ACT1_PUSH = 0.7     -- the swoop onto the boatman
local ACT1_TYPE = 1.5     -- his line, typed a character at a time
local ACT1_TAIL = 1.4     -- and how long the finished line sits before the tour
local ISLE_HOLD = 2.4
local CURTAIN = 0.18
local ZOOM_FOV = 52
local WIDE_FOV = 57       -- every shot OPENS here and pushes in to ZOOM_FOV
local TITLE_Y = -62       -- both cards ride the lower letterbox bar
local BLURB_Y = -34

local LINE = "Oi, nice rakework! Turn this beach's tide and you an' me will sail \u{2014} whole world out past the break, mate!"

--[[
	ONE LINE OF PITCH PER ISLAND, keyed by FERRY PORT so a re-ordered tour
	cannot mis-caption a shot.

	THEY LIVE HERE AND NOT IN TutorialConfig.OutroStops because that table is
	shared with the SERVER's streaming escort -- it is a list of PLACES, and a
	place does not have ad copy. A stop with no entry simply shows its name,
	which is what every stop did before these existed.
]]
local KICKERS = {
	[2] = "Sun-bleached dunes, and gold under every drift.",
	[3] = "Festival petals on the water, shrine treasure in the sand.",
	[4] = "Black sand, hot ash, and the richest finds in the sea.",
	[5] = "A frozen sea, a lost liner, and a colony that wants to say hello.",
}

local SWEEP = { "BeachMenuHud", "CleanTheBeachHUD", "InventoryHud", "EventHud", "WeightHUD", "TutorialHud",
	"BoostHud" }

-- The shot list lives in TutorialConfig.OutroStops -- one table for this tour
-- AND for the server's streaming escort, so they cannot disagree about where
-- the stops are. See the note there.
local ISLES = TutorialConfig.OutroStops

local playing = false

local function findFerryman()
	local folder = workspace:FindFirstChild("Ferries")
	local berth = folder and folder:FindFirstChild("BeachFerry")
	return berth and berth:FindFirstChild("Ferryman", true)
end

-- The ring of candidate eyes for the close-up, tried in order of preference:
-- low and half-front first, because a portrait wants a face, not a mast.
local function pickCloseUp(man: Model): (CFrame?, Vector3?)
	local head = man:FindFirstChild("Head", true) or man.PrimaryPart
		or man:FindFirstChildWhichIsA("BasePart", true)
	if not head then
		return nil, nil
	end
	local focus = head.Position + Vector3.new(0, 0.4, 0)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { man, player.Character }
	for _, spec in ipairs({
		{ 210, 8.5, 2.2 }, { 250, 8.5, 2.2 }, { 170, 8.5, 2.2 }, { 290, 9.5, 2.6 },
		{ 130, 9.5, 2.6 }, { 330, 10.5, 3.2 }, { 90, 10.5, 3.2 }, { 30, 11.5, 4.0 },
	}) do
		local a = math.rad(spec[1])
		local eye = focus + Vector3.new(math.cos(a) * spec[2], spec[3], math.sin(a) * spec[2])
		local hit = workspace:Raycast(eye, focus - eye, params)
		if hit == nil then
			return CFrame.lookAt(eye, focus), focus
		end
	end
	-- Every line was blocked (a rebuilt boat could manage it): shoot from high
	-- over the bow rather than not at all.
	return CFrame.lookAt(focus + Vector3.new(0, 7, 12), focus), focus
end

--[[
	THE LINE IS A SUBTITLE NOW, NOT A SPEECH BUBBLE. The bubble hung 4.6 studs
	over Sandy's head -- and the tightened close-up (8.5-stud eye, 52-degree
	lens) frames barely four studs above his eyeline, so the zoom that fixed
	the sail pushed his own words out of the top of the frame. A subtitle on
	the lower letterbox bar is where a letterboxed film puts dialogue anyway,
	it cannot be framed out by ANY future shot change, and it reads on a phone.
	Name in the boatman's blue, line in stroked white, both riding the bar.
]]
local function subtitleOn(parent: ScreenGui): (Frame, TextLabel)
	local holder = Instance.new("Frame")
	holder.Name = "SendOffSubtitle"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.new(0.5, 0, 1, -10)
	holder.Size = UDim2.new(0.8, 0, 0.16, 0)
	holder.ZIndex = 13
	local who = Instance.new("TextLabel")
	who.BackgroundTransparency = 1
	who.Font = Enum.Font.LuckiestGuy
	who.TextSize = 22
	who.TextColor3 = Color3.fromRGB(112, 208, 255)
	who.TextStrokeColor3 = Color3.fromRGB(8, 20, 28)
	who.TextStrokeTransparency = 0
	who.Text = "SANDY SALT"
	who.Position = UDim2.new(0, 0, 0, 0)
	who.Size = UDim2.new(1, 0, 0, 24)
	who.ZIndex = 13
	who.Parent = holder
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBold
	text.TextSize = 19
	text.TextColor3 = Color3.new(1, 1, 1)
	text.TextStrokeColor3 = Color3.fromRGB(8, 20, 28)
	text.TextStrokeTransparency = 0
	text.TextWrapped = true
	-- Filled by typeInto, which paints the un-typed tail transparent rather
	-- than growing the string -- see its note.
	text.RichText = true
	text.Text = ""
	text.Position = UDim2.new(0, 0, 0, 26)
	text.Size = UDim2.new(1, 0, 1, -26)
	text.ZIndex = 13
	text.Parent = holder
	holder.Parent = parent
	return holder, text
end

local function play()
	if playing then
		return
	end
	playing = true
	task.wait(0.6)

	local man = findFerryman()
	if not man then
		playing = false
		return
	end

	local cam = workspace.CurrentCamera
	local pg = player:WaitForChild("PlayerGui")
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")

	local prevType = cam.CameraType
	local prevCF = cam.CFrame
	local prevFOV = cam.FieldOfView
	local prevWalk = hum and hum.WalkSpeed or nil
	local swept = {}
	for _, name in ipairs(SWEEP) do
		local gui = pg:FindFirstChild(name)
		if gui and gui:IsA("ScreenGui") and gui.Enabled then
			gui.Enabled = false
			table.insert(swept, gui)
		end
	end
	if hum then
		hum.WalkSpeed = 0
	end

	-- One ScreenGui carries the whole show: curtain, titles, hint, bubble.
	local show = Instance.new("ScreenGui")
	show.Name = "SendOff"
	show.ResetOnSpawn = false
	show.IgnoreGuiInset = true
	show.DisplayOrder = 250
	show.Parent = pg

	--[[
		THE CINEMATIC BARS. Two black slabs that slide in as the show opens and
		leave with it -- 11% each, the classic scope crop. Above the world and
		the titles ride clear of them (the title sits at -46 from the bottom,
		inside the lower bar's shadow line on purpose: names ON the bar is the
		letterboxed-film convention this is quoting).
	]]
	local bars = {}
	for _, side in ipairs({ 0, 1 }) do
		local bar = Instance.new("Frame")
		bar.BackgroundColor3 = Color3.new(0, 0, 0)
		bar.BorderSizePixel = 0
		bar.AnchorPoint = Vector2.new(0, side)
		bar.Position = UDim2.new(0, 0, side, 0)
		bar.Size = UDim2.new(1, 0, 0, 0)
		bar.ZIndex = 11
		bar.Parent = show
		TweenService:Create(bar, TweenInfo.new(0.35, Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out), { Size = UDim2.new(1, 0, 0.11, 0) }):Play()
		table.insert(bars, bar)
	end

	local curtain = Instance.new("Frame")
	curtain.Size = UDim2.fromScale(1, 1)
	curtain.BackgroundColor3 = Color3.new(0, 0, 0)
	curtain.BackgroundTransparency = 1
	curtain.BorderSizePixel = 0
	curtain.ZIndex = 10
	curtain.Parent = show

	local hint = Instance.new("TextLabel")
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.GothamBold
	hint.TextSize = 18
	hint.TextColor3 = Color3.new(1, 1, 1)
	hint.TextTransparency = 0.35
	hint.TextStrokeTransparency = 0.6
	-- BOTH gestures, because a player who only knows about the destructive one
	-- uses it. "press" rather than "click" or "tap": this reads on a phone too.
	hint.Text = "press for next  \u{00B7}  hold to skip"
	hint.AnchorPoint = Vector2.new(1, 1)
	hint.Position = UDim2.new(1, -26, 1, -22)
	hint.Size = UDim2.fromOffset(320, 24)
	hint.TextXAlignment = Enum.TextXAlignment.Right
	hint.ZIndex = 12
	hint.Parent = show

	--[[
		HOW MANY BEATS ARE LEFT, as pips above the hint -- the boatman plus one
		per stop. A hint promising "next" is a promise about a length the player
		cannot see, and four dots is the cheapest way to keep it: somebody
		pressing through can tell they are ending A SHOT rather than THE SHOW,
		which is the exact confusion the old single-click skip made permanent.
	]]
	local dots = Instance.new("Frame")
	dots.Name = "Beats"
	dots.BackgroundTransparency = 1
	dots.AnchorPoint = Vector2.new(1, 1)
	dots.Position = UDim2.new(1, -26, 1, -48)
	dots.Size = UDim2.fromOffset(200, 14)
	dots.ZIndex = 12
	dots.Parent = show
	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.HorizontalAlignment = Enum.HorizontalAlignment.Right
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.Padding = UDim.new(0, 6)
	row.Parent = dots

	local pips = {}
	for i = 1, #ISLES + 1 do
		local pip = Instance.new("Frame")
		pip.Name = "Beat" .. i
		pip.BackgroundColor3 = Color3.new(1, 1, 1)
		pip.BackgroundTransparency = 0.78
		pip.BorderSizePixel = 0
		pip.Size = UDim2.fromOffset(8, 8)
		pip.LayoutOrder = i
		pip.ZIndex = 12
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(1, 0)
		round.Parent = pip
		pip.Parent = dots
		pips[i] = pip
	end

	-- The lit pip carries the SHOT'S OWN colour, so the tint that names the
	-- island is the tint that says where you are in the tour.
	local function litPip(n: number, tint: Color3)
		for i, pip in ipairs(pips) do
			local on = (i == n)
			TweenService:Create(pip, TweenInfo.new(0.22, Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out), {
				BackgroundColor3 = on and tint or Color3.new(1, 1, 1),
				BackgroundTransparency = on and 0 or (i < n and 0.5 or 0.78),
				Size = UDim2.fromOffset(on and 12 or 8, on and 12 or 8),
			}):Play()
		end
	end

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.LuckiestGuy
	title.TextSize = 44
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextStrokeColor3 = Color3.fromRGB(12, 28, 38)
	title.TextStrokeTransparency = 0
	title.Text = ""
	title.AnchorPoint = Vector2.new(0.5, 1)
	title.Position = UDim2.new(0.5, 0, 1, TITLE_Y)
	title.Size = UDim2.fromOffset(700, 52)
	title.ZIndex = 12
	title.Parent = show

	--[[
		THE NAME GAINED A LINE UNDER IT, so the name moved up to make room. A
		place name alone says WHERE; one line of copy says why you would go --
		which is the whole job of a tour the boatman is using to sell a ferry
		ticket. Both still ride the lower bar, film-title fashion, and the pair
		clears the 11% bar on a 1080 screen.
	]]
	local blurb = Instance.new("TextLabel")
	blurb.BackgroundTransparency = 1
	blurb.Font = Enum.Font.GothamMedium
	blurb.TextSize = 19
	blurb.TextColor3 = Color3.fromRGB(238, 246, 250)
	blurb.TextStrokeColor3 = Color3.fromRGB(12, 28, 38)
	blurb.TextStrokeTransparency = 0.15
	blurb.Text = ""
	blurb.AnchorPoint = Vector2.new(0.5, 1)
	blurb.Position = UDim2.new(0.5, 0, 1, BLURB_Y)
	blurb.Size = UDim2.fromOffset(760, 24)
	blurb.ZIndex = 12
	blurb.Parent = show

	-- The card LANDS rather than appearing: the name rises the last few pixels
	-- as the curtain lifts, and its line follows a beat behind it.
	local function showCard(name: string, tint: Color3, line: string?)
		title.Text = name
		title.TextColor3 = tint
		title.TextTransparency = 1
		title.TextStrokeTransparency = 1
		title.Position = UDim2.new(0.5, 0, 1, TITLE_Y + 14)
		TweenService:Create(title, TweenInfo.new(0.34, Enum.EasingStyle.Quart,
			Enum.EasingDirection.Out), { TextTransparency = 0, TextStrokeTransparency = 0,
			Position = UDim2.new(0.5, 0, 1, TITLE_Y) }):Play()
		blurb.Text = line or ""
		blurb.TextTransparency = 1
		blurb.TextStrokeTransparency = 1
		if line then
			TweenService:Create(blurb, TweenInfo.new(0.34, Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out, 0, false, 0.14),
				{ TextTransparency = 0.05, TextStrokeTransparency = 0.15 }):Play()
		end
	end

	local function hideCard()
		title.Text = ""
		blurb.Text = ""
	end

	--[[
		A PRESS ASKS FOR THE NEXT BEAT. IT DOES NOT END THE SHOW.

		The handler this replaces set one `skipped` flag on any input and every
		wait in the file tested it -- so the single curious click a player makes
		during the boatman's line threw away all three islands behind it.
		Presses are COUNTED here instead and spent one beat at a time: mid-line
		it finishes the line, anywhere else it cuts to the next stop. Only a
		HELD input (HOLD_SKIP) still ends everything.

		THE COUNT IS ZEROED AT THE TOP OF EVERY BEAT, which is the part that is
		easy to get wrong. The curtain between two islands is a real streaming
		window and can run seconds; a press landing inside it would otherwise be
		banked and spend the island it was waiting for -- a black screen
		followed by one frame of The Dunes.
	]]
	local pending = 0
	local skipAll = false
	local downNow: InputObject? = nil
	local t0 = os.clock()

	-- Everything that is not a deliberate press. MouseMovement is the one that
	-- matters: without it every shot ends the moment the player nudges the mouse.
	local IDLE_INPUT = {
		[Enum.UserInputType.MouseMovement] = true,
		[Enum.UserInputType.MouseWheel] = true,
		[Enum.UserInputType.Focus] = true,
		[Enum.UserInputType.TextInput] = true,
		[Enum.UserInputType.Gyro] = true,
		[Enum.UserInputType.Accelerometer] = true,
	}

	local conns = {}
	table.insert(conns, UserInputService.InputBegan:Connect(function(io, processed)
		if processed or IDLE_INPUT[io.UserInputType] then
			return
		end
		if os.clock() - t0 < SKIP_AFTER then
			return
		end
		pending += 1
		downNow = io
		AudioKit.play("UIClick", nil, 0.7)
		-- Still the input that is down when this fires? Then it was a hold.
		task.delay(HOLD_SKIP, function()
			if downNow == io then
				skipAll = true
			end
		end)
	end))
	table.insert(conns, UserInputService.InputEnded:Connect(function(io)
		if downNow == io then
			downNow = nil
		end
	end))

	-- One press out of the jar, or none. A hold answers yes forever.
	local function tapped(): boolean
		if skipAll then
			return true
		end
		if pending > 0 then
			pending -= 1
			return true
		end
		return false
	end

	-- A wait a press can cut short. Polled every frame rather than on the old
	-- 0.08 clock: "instant" is the whole feel of press-to-advance, and an eighth
	-- of a second of nothing happening reads as a dropped input.
	local function beat(seconds: number)
		local from = os.clock()
		while os.clock() - from < seconds do
			if tapped() then
				return
			end
			task.wait()
		end
	end

	--[[
		THE LINE TYPES ITSELF, AND A PRESS FINISHES IT. Two useful things out of
		one gesture, and the contract every player already knows from every other
		game that reveals text a character at a time.

		IT IS REVEALED WITH RICH TEXT, NOT BY GROWING THE STRING. The label is
		centred and wrapped, so appending characters re-measures and re-centres
		the whole line every frame -- the words crawl sideways while they are
		being read, and a wrap point moves a word to the line above mid-sentence.
		Painting the un-typed tail transparent keeps the FULL line laid out from
		the first frame, so every word is in its final position before it is
		visible.

		AND THE TAIL NEEDS BOTH TAGS. `<font transparency="1">` hides the GLYPH
		and not its outline: the label's own TextStrokeTransparency is applied
		underneath and the whole un-typed remainder renders as solid dark text.
		Photographed on a grey card before and after -- with `<font>` alone the
		rest of the sentence is plainly readable in stroke colour, and with
		`<stroke transparency="1">` nested inside it there is nothing there at
		all. Turning the label's stroke off instead would work and costs the
		legibility the stroke is there for, over sea and sand.

		CODEPOINTS, NOT BYTES: the line carries an em dash, and cutting a
		multi-byte character in half paints a tofu box on the way past.
	]]
	local function typeInto(label: TextLabel, text: string, seconds: number)
		local n = utf8.len(text) or #text
		local from, lastTick = os.clock(), 0
		local shown = -1
		while shown < n do
			local want = n
			if not tapped() then
				want = math.min(n, math.floor((os.clock() - from) / seconds * n))
			end
			if want > shown then
				shown = want
				local cut = utf8.offset(text, shown + 1)
				local head = cut and string.sub(text, 1, cut - 1) or text
				local tail = cut and string.sub(text, cut) or ""
				label.Text = (tail == "") and head
					or (head .. '<font transparency="1"><stroke transparency="1">'
						.. tail .. "</stroke></font>")
				-- The tick is rate-limited, not per character: at 60fps this line
				-- reveals about two glyphs a frame and a tick each would be a buzz.
				if os.clock() - lastTick > 0.055 then
					lastTick = os.clock()
					AudioKit.play("WoodTick", nil, 0.26, 0.92 + math.random() * 0.16)
				end
			end
			if shown < n then
				task.wait()
			end
		end
		label.Text = text
	end

	local function fade(to: number)
		TweenService:Create(curtain, TweenInfo.new(CURTAIN), { BackgroundTransparency = to }):Play()
		task.wait(CURTAIN)
	end

	local bubble
	--[[
		THE ONE LIVE TWEEN, AND IT DIES BEFORE EVERY CUT. A running CFrame
		tween re-asserts itself every frame, so a hold that ends before its
		drift does leaves a tween ALIVE through the next `cam.CFrame =` write
		-- which is then quietly stomped, and the following drift starts from
		the OLD island: the cut becomes a three-second flight across the map.
		Measured, not theorised: the chambers' shorter holds did exactly this
		to the two shots after them. So the drift is tracked, its length is
		the stop's own hold, and drift() cancels the last one first.
	]]
	local activeDrift: Tween? = nil
	local function drift(tween: Tween?)
		if activeDrift then
			activeDrift:Cancel()
		end
		activeDrift = tween
		if tween then
			tween:Play()
		end
	end

	local ok, err = pcall(function()
		cam.CameraType = Enum.CameraType.Scriptable

		-- ACT ONE: the man himself, sail dodged by raycast, lens tightened.
		local shot, focus = pickCloseUp(man)
		if shot then
			litPip(1, Color3.fromRGB(112, 208, 255))
			-- The swoop and the lens arrive together: opening wide and settling to
			-- ZOOM_FOV pushes INTO him, which a straight fly-to does not.
			cam.FieldOfView = WIDE_FOV
			TweenService:Create(cam, TweenInfo.new(ACT1_PUSH, Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out), { CFrame = shot, FieldOfView = ZOOM_FOV }):Play()
			task.wait(ACT1_PUSH)
			local line
			bubble, line = subtitleOn(show)
			-- the drift: a slow slide along the ring, still looking at him. It runs
			-- the length of the whole act, press or no press; drift(nil) kills it.
			drift(TweenService:Create(cam, TweenInfo.new(ACT1_TYPE + ACT1_TAIL,
				Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ CFrame = shot * CFrame.new(1.6, 0.5, 0) }))
			pending = 0
			typeInto(line, LINE, ACT1_TYPE)
			beat(ACT1_TAIL)
			drift(nil)
			if bubble then
				bubble:Destroy()
				bubble = nil
			end
		end

		-- ACT TWO: the islands, one orbit each, cut through the curtain.
		for stageIndex, isle in ipairs(ISLES) do
			if skipAll then
				break
			end
			fade(0)   -- to black

			local port = isle.port and FerryConfig.Ports[isle.port]
			local a0, a1 = math.rad(isle.a0), math.rad(isle.a1)
			-- Two full keyframes. A plain orbit leaves the second one implicit
			-- (same centre, radius, height, look); a pull-back like Ashfall's
			-- overrides any of them, and the tween slides both the eye AND the
			-- look point between the two lookAt frames.
			local centre2 = isle.centre2 or isle.centre
			local look0 = isle.centre + Vector3.new(0, isle.lift, 0)
			local look1 = centre2 + Vector3.new(0, isle.lift2 or isle.lift, 0)
			local eye0 = isle.centre + Vector3.new(math.cos(a0) * isle.r, isle.y, math.sin(a0) * isle.r)
			local eye1 = centre2 + Vector3.new(math.cos(a1) * (isle.r2 or isle.r),
				isle.y2 or isle.y, math.sin(a1) * (isle.r2 or isle.r))

			--[[
				THE ESCORT, THEN THE PULL -- both under the curtain, and the
				sequencing is everything, learned the hard way twice:

				* The focus moves HERE and nowhere else. A "prefetch the next
				  stop while this one plays" pipeline sounded clever and was
				  measured evicting the island ON SCREEN (the Vault's 430 parts
				  hit zero two seconds into its own shot) -- under this place's
				  streaming, where the focus leaves, the world follows.
				* The pull is Player:RequestStreamAroundAsync -- the PLAYER
				  method. The Workspace spelling this used to call does not
				  exist and errored silently inside its pcall for every shot,
				  which is why the far islands and their terrain arrived as
				  imposters: nothing was ever actually requested.

				The request aims at the SUBJECT (what must not be a potato) and
				yields until the server has sent it or the stop's own budget
				runs out -- rooms are instant, Ashfall's third of a kilometre
				carries `stream = 5`. The curtain is black exactly as long as
				the world needs, and no longer.
			]]
			Net.get("OutroFocus"):FireServer({ stage = stageIndex })
			pcall(function()
				player:RequestStreamAroundAsync(look0, isle.stream or 2)
			end)
			--[[
				AND THE GATE ON THE CURTAIN: the request above can return while
				the parts are still landing (measured: the two big open islands
				arrived one to two seconds into their own shots, filling in on
				camera). So the curtain also WATCHES the stop's own container
				and stays black until its part count holds still for two beats
				-- or a hard cap, because a shot of sea and sky still beats a
				stalled show. Rooms that arrived whole pay half a second.
			]]
			if isle.container then
				local last, stable, since = -1, 0, os.clock()
				-- per-stop budget (`gate`), for any stop that outlives the flat cap
				while os.clock() - since < (isle.gate or 2.5) and stable < 2 and not skipAll do
					-- recursive, so a stop may name a nested container
					local c = workspace:FindFirstChild(isle.container, true)
					local n = 0
					if c then
						for _, d in ipairs(c:GetDescendants()) do
							if d:IsA("BasePart") then n += 1 end
						end
					end
					if n > 0 and n == last then
						stable += 1
					else
						stable = 0
					end
					last = n
					-- LEAVE THIS AT A QUARTER SECOND. Everything else in the show got
					-- faster; this did not, and it is the one number here that is not
					-- a pacing choice. "Stable" is two consecutive equal reads, so the
					-- poll IS the width of the plateau the test will accept -- halving
					-- it halves the lull that passes for "finished streaming", which
					-- is exactly how the big islands used to arrive on camera.
					task.wait(0.25)
				end
			end
			if skipAll then
				break
			end

			local tint = (port and port.tint) or isle.tint or Color3.new(1, 1, 1)
			local dwell = isle.hold or ISLE_HOLD
			cam.CFrame = CFrame.lookAt(eye0, look0)
			cam.FieldOfView = WIDE_FOV
			litPip(stageIndex + 1, tint)
			if stageIndex == #ISLES then
				hint.Text = "press to finish  \u{00B7}  hold to skip"
			end
			showCard(string.upper((port and port.name) or isle.name or ""), tint,
				KICKERS[isle.port])
			--[[
				THE CUT HAS A SOUND NOW. A hard cut between two places with nothing
				on it reads as a stall on a slow connection -- the player cannot
				tell a new shot from a frozen one. The whoosh is the sifter's own
				swing pitched down, so the tour still sounds like this game, and
				the last stop gets the tide's low boom under it because a volcano
				deserves one.
			]]
			AudioKit.play("SwingWhoosh", nil, 1.1, 0.8)
			if stageIndex == #ISLES then
				AudioKit.play("TideBoom", nil, 0.4)
			end
			fade(1)   -- reveal

			-- ONE tween carries the orbit AND the push-in. Opening a touch wide
			-- and settling on the authored lens gives a static vista some move
			-- without changing what the shot was framed to hold.
			drift(TweenService:Create(cam, TweenInfo.new(dwell,
				Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ CFrame = CFrame.lookAt(eye1, look1), FieldOfView = ZOOM_FOV }))
			pending = 0
			beat(dwell)
			drift(nil)
			hideCard()
		end

		-- home through the curtain, so the cut back is a cut, not a streak
		drift(nil)
		Net.get("OutroFocus"):FireServer({ stage = 0 })
		fade(0)
		cam.CFrame = prevCF
		fade(1)
	end)
	-- Belt to the tail's braces: however the show ended, the focus goes home.
	pcall(function()
		Net.get("OutroFocus"):FireServer({ stage = 0 })
	end)

	if activeDrift then
		activeDrift:Cancel()
	end

	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	if bubble then
		bubble:Destroy()
	end
	show:Destroy()
	cam.CameraType = prevType
	cam.CFrame = prevCF
	cam.FieldOfView = prevFOV
	if hum and prevWalk then
		hum.WalkSpeed = prevWalk
	end
	for _, gui in ipairs(swept) do
		gui.Enabled = true
	end
	if not ok then
		warn("[TutorialOutro] the send-off failed and was cleaned up: " .. tostring(err))
	end
	playing = false
end

player:GetAttributeChangedSignal(TutorialConfig.CelebrateAttribute):Connect(function()
	if (tonumber(player:GetAttribute(TutorialConfig.CelebrateAttribute)) or 0) > 0 then
		task.spawn(play)
	end
end)
