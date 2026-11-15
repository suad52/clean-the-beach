--[[
	DriveHud  --  StarterPlayer.StarterPlayerScripts.DriveHud  (LocalScript)

	The dashboard, for as long as you are sitting in something from the car
	spawner. Before this there was nothing at all: Roblox's default is a bare
	VehicleSeat, which tells a driver none of the three things they actually
	want to know -- how fast am I going, how full am I, and how do I get out.

	AND ROBLOX'S OWN GAUGE IS OFF NOW. A VehicleSeat draws a stock "Speed" bar
	across the bottom of the screen the whole time it is occupied: grey dashes,
	a default font, reading MaxSpeed -- which is 0 on every machine in this game
	because AtvServer owns the driving, so the needle never moved. It sat a few
	pixels under this card, saying nothing, in nobody's art style. AtvBuilder
	and DozerBuilder both stamp HeadsUpDisplay = false on the seat now, so there
	is nothing for this script to hide and no per-frame fight with replication.

	DRAWN BY PanelKit, LIKE EVERY OTHER PANEL IN THE GAME, so it belongs to the
	same set of parts as the showroom and the Beach Shop rather than being a
	fourth look invented for the cab.

	IT READS, IT NEVER DECIDES. Speed comes off the chassis the client already
	has; the load comes off the two player attributes the server writes. This
	script has no authority over anything and no remote of its own.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local PanelKit = require(Modules:WaitForChild("PanelKit"))
local WeightConfig = require(ReplicatedStorage:WaitForChild("WeightSystem"):WaitForChild("WeightConfig"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local C = PanelKit.C

--[[
	SMALL, AND MADE OF FEWER PARTS.

	It was 360 x 96: a full panel with its own title line, a labelled stat bar
	and a permanent controls line, parked across the middle of the bottom band.
	That is a menu. This is a readout you glance at while driving, and at that
	size it was the largest thing on screen for the whole of every run.

	240 x 54 is a third of the area. What went:

	  * the HOLD caption and the stat bar's own value column. The bar sits under
	    the machine's name with the figure at the end of that line, so the kit's
	    LABEL / track / VALUE row would have spent 84 of 119 px repeating what
	    the two lines above it already said -- and a bar that turns coral needs
	    no caption to explain itself.
	  * the permanent controls line. It is shown for HINT_HOLD seconds when you
	    get in and then fades: a first-time driver still gets told, and everybody
	    else stops being told forever.
	  * the hairline rule down the middle. It was there to stop two columns of
	    text reading as one line that had wrapped -- a real problem, solved by
	    an apology. The speed chip solves it by being a different COLOUR, which
	    is one part doing the job instead of one part plus a divider.

	What did NOT go is the recipe -- slab, thick outline, gradient, gloss,
	PanelKit's palette. SMALLER, NOT A DIFFERENT LOOK. The cab has already cost
	this game one invented-here panel style and is not getting a second.
]]
local W, H = 240, 54
-- How long the controls line holds before it fades.
local HINT_HOLD = 4.5

local gui = Instance.new("ScreenGui")
gui.Name = "DriveHud"
gui.ResetOnSpawn = false
gui.Enabled = false
-- Under the shop modal (50) and above the world. It is a readout, not a thing
-- you click, so it never wants to be on top of a panel.
gui.DisplayOrder = 20
gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
gui.Parent = playerGui

local root = Instance.new("Frame")
root.Name = "Dash"
root.AnchorPoint = Vector2.new(0.5, 1)
-- Bottom centre, above the toast stack. The rail is hard right and the bag
-- panels hard left, so the middle of the bottom band is the one place a card
-- this wide does not land on something else.
-- 140 up, not 128. The toast stack lives in the bottom band and the first
-- "put away" or "fished out of the sea" message landed straight across the
-- dashboard. The controls line now hangs BELOW the card rather than inside it,
-- so this is the offset at which its last pixel lands where the old slab's did
-- and the toasts still clear the lot. The card grew twelve pixels TALLER in
-- this pass and not one pixel lower: it is anchored by its bottom edge, so all
-- of that went upward into empty sky and none of it into the toast lane.
root.Position = UDim2.new(0.5, 0, 1, -140)
root.Size = UDim2.fromOffset(W, H)
root.BackgroundTransparency = 1
root.Parent = gui

----------------------------------------------------------------
-- LAYOUT  --  measured, and centred rather than hung off the top
----------------------------------------------------------------
--[[
	THE OLD SPACING WAS TOP-HEAVY, AND THAT IS THE WHOLE OF WHAT WAS WRONG.

	In the 42px card the speed block ran y 1..33 and the name-and-bar column ran
	5..31, so both sat hard against the top edge and the card carried nine
	pixels of dead sand along the bottom that read as a misprint. Nothing is
	placed by eye here any more: each column states its own height and `top`
	centres it, so the card can be resized without anybody re-guessing a number.

	The widths are measured too, in this game's own fonts:

	  * "100" at LuckiestGuy 24 is 40px, so a 56px chip holds three digits with
	    8px of air either side -- and the fastest machine in the shop tops out
	    at 31 studs/s, so that is a spare digit nobody will ever spend.
	  * "STUDS/S" at GothamBlack 8 is 32px: same chip, no truncation.
	  * "TIDEBREAKER" at LuckiestGuy 12 is 74px -- the longest machine name
	    there is -- against an 84px box.
	  * "650/650" at LuckiestGuy 12 is 48px, and "1000/1000" would be 64. The
	    figure's box is 60 rather than the 50 today needs, so the first tier
	    with a four-digit hold does not silently come back "650/65...".
]]
local PAD = 12

local function top(blockH: number): number
	return math.floor((H - blockH) * 0.5)
end

-- The speed chip, on the left.
local CHIP_W, CHIP_H = 56, 40
local CHIP_Y = top(CHIP_H)                        -- 7

-- The name-and-hold column, on the right. A full pad clear of the chip.
local COL = PAD + CHIP_W + PAD                    -- 80
local COL_W = W - COL - PAD                       -- 148
local VALUE_W = 60
local TITLE_H, ROW_GAP, TRACK_H = 14, 5, 15
local COL_Y = top(TITLE_H + ROW_GAP + TRACK_H)    -- 10

-- Two pixels off the top of the type row, and ONLY the type row.
--
-- `top` centres a BOX; LuckiestGuy draws its ink in the upper part of the line
-- it is given and leaves the descender space empty at the bottom, so a name
-- centred perfectly by the numbers reads two pixels low. The chip is a solid
-- rectangle and needs none of this; the bar is a solid rectangle and needs none
-- of it either, which is why the lift is spent here and not on COL_Y itself --
-- moving the whole column would have taken the bar off centre to fix the text.
local LIFT = 2

----------------------------------------------------------------
-- THE CARD
----------------------------------------------------------------
-- Sized in SCALE so the slab and the card follow the root, which is what the
-- pop tween moves. Radius 15 and a 4px outline rather than 11 and 3: the kit
-- says thin strokes read as default Roblox, and at this size the difference
-- between a rounded rectangle and a chunky one is two numbers.
local slab = Instance.new("Frame")
slab.Name = "Slab"
slab.Size = UDim2.fromScale(1, 1)
slab.Position = UDim2.fromOffset(0, 5)
slab.BackgroundColor3 = C.woodDark
slab.BorderSizePixel = 0
slab.ZIndex = 1
slab.Parent = root
PanelKit.corner(slab, 15)
PanelKit.outline(slab, 4)

local card = Instance.new("Frame")
card.Name = "Card"
card.Size = UDim2.fromScale(1, 1)
card.BackgroundColor3 = C.sand
card.BorderSizePixel = 0
card.ZIndex = 2
card.Parent = root
PanelKit.corner(card, 15)
PanelKit.outline(card, 4)
PanelKit.grad(card, C.sand, C.sandMid)

--[[
	EVERY ZINDEX ON THIS CARD IS EXPLICIT, because the gui runs
	ZIndexBehavior.Global, where being somebody's child counts for nothing.
	PanelKit.text leaves labels at 5 and a bare Frame sits at 1 -- so the bar's
	fill and the machine's name were on the same layer, separated only by which
	one happened to be built first. The ladder:

	    1 slab   2 card   3 chip / track   4 chip gloss / track recess
	    5 fill   6 fill shine   8 all type
]]
local function label(parent: GuiObject, str: string, size: number, font: Enum.Font, colour: Color3, z: number)
	local l = PanelKit.text(parent, str, size, font, colour)
	l.ZIndex = z
	return l
end

--[[
	THE SPEED CHIP.

	A tinted plinth with the number on it -- the same shape this game puts every
	icon in, in the shop and the showroom and the reward cards. It does three
	jobs at once: it is the one saturated colour on a sand card, it separates
	the two columns so the divider could go, and white-on-sea holds a two-digit
	number at a glance in a way seaDark-on-sand never did.
]]
local chip = PanelKit.plinth(card, C.sea, 13)
chip.Name = "SpeedChip"
chip.Size = UDim2.fromOffset(CHIP_W, CHIP_H)
chip.Position = UDim2.fromOffset(PAD, CHIP_Y)
chip.ZIndex = 3
PanelKit.gloss(chip, 13)

local speed = label(chip, "0", 24, Enum.Font.LuckiestGuy, C.white, 8)
speed.Position = UDim2.fromOffset(0, 4)
speed.Size = UDim2.fromOffset(CHIP_W, 25)
PanelKit.punch(speed, 2.5)

local speedUnit = label(chip, "STUDS/S", 8, Enum.Font.GothamBlack, C.white, 8)
speedUnit.Position = UDim2.fromOffset(0, 28)
speedUnit.Size = UDim2.fromOffset(CHIP_W, 9)
-- Knocked back rather than recoloured. A separate paler blue would be a fourth
-- colour on a card that already has three; the same white at a quarter off
-- reads as a caption without adding one.
speedUnit.TextTransparency = 0.28

-- The machine's name, in the game's own face. GothamBold said this in the
-- voice of a settings row; LuckiestGuy says it in the voice of the banner over
-- every panel in the game, which is where the driver has just read it.
local title = label(card, "", 12, Enum.Font.LuckiestGuy, C.ink, 8)
title.Position = UDim2.fromOffset(COL, COL_Y - LIFT)
title.Size = UDim2.fromOffset(COL_W - VALUE_W - 4, TITLE_H)
title.TextXAlignment = Enum.TextXAlignment.Left

local loadText = label(card, "0", 12, Enum.Font.LuckiestGuy, C.seaDark, 8)
loadText.AnchorPoint = Vector2.new(1, 0)
loadText.Position = UDim2.new(1, -PAD, 0, COL_Y - LIFT)
loadText.Size = UDim2.fromOffset(VALUE_W, TITLE_H)
loadText.TextXAlignment = Enum.TextXAlignment.Right

----------------------------------------------------------------
-- THE HOLD BAR
----------------------------------------------------------------
-- Drawn here rather than through PanelKit.statBar -- see the note at the top
-- for why the kit's LABEL / track / VALUE row does not fit a column this
-- narrow. Same track, same recess, same outline: it is the kit's bar with its
-- caption taken off, not a second kind of bar.
local track = Instance.new("Frame")
track.Name = "Track"
track.Size = UDim2.fromOffset(COL_W, TRACK_H)
track.Position = UDim2.fromOffset(COL, COL_Y + TITLE_H + ROW_GAP)
track.BackgroundColor3 = C.sandDeep
track.BorderSizePixel = 0
track.ClipsDescendants = true
track.ZIndex = 3
track.Parent = card
PanelKit.corner(track, 7)
PanelKit.outline(track, 2.5)

-- Six pixels of soft dark down the inside of the top edge. This is the whole
-- difference between a track CUT INTO the card and a darker rectangle painted
-- onto it, and it is the same trick PanelKit.card plays with BannerShade.
local recess = Instance.new("Frame")
recess.Name = "Recess"
recess.Size = UDim2.new(1, 0, 0, 6)
recess.BackgroundColor3 = PanelKit.darken(C.sandDeep, 0.5)
recess.BorderSizePixel = 0
recess.ZIndex = 4
recess.Parent = track
local recessFade = Instance.new("UIGradient")
recessFade.Rotation = 90
recessFade.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.4),
	NumberSequenceKeypoint.new(1, 1),
})
recessFade.Parent = recess

local fill = Instance.new("Frame")
fill.Name = "Fill"
fill.Size = UDim2.fromScale(0.06, 1)
fill.BackgroundColor3 = C.lime
fill.BorderSizePixel = 0
fill.ZIndex = 5
fill.Parent = track
PanelKit.corner(fill, 7)
local fillGrad = PanelKit.grad(fill, C.lime, C.lime)

-- The fill's gloss cap, cut down for a bar this shallow: PanelKit.gloss is
-- tuned for a button face and would put its highlight halfway down a 15px
-- track. Four pixels along the top is the same cue at this scale. It vanishes
-- on its own when the fill is a stub, because -10 of a 9px frame is nothing.
local shine = Instance.new("Frame")
shine.Name = "Shine"
shine.Size = UDim2.new(1, -10, 0, 4)
shine.Position = UDim2.fromOffset(5, 3)
shine.BackgroundColor3 = C.white
shine.BackgroundTransparency = 0.55
shine.BorderSizePixel = 0
shine.ZIndex = 6
shine.Parent = fill
PanelKit.corner(shine, 2)

--[[
	RECOLOURING THE FILL MEANS RECOLOURING ITS GRADIENT WITH IT.

	This bar used to carry no gradient at all, and the note explaining why was
	right about the mechanism and wrong about the fix: a UIGradient MULTIPLIES
	against the fill under it, so a lime-derived gradient over a coral fill
	gives neither colour, it gives mud. Dropping the gradient is one way out of
	that. Moving BOTH STOPS with the fill is the other, it is what
	PanelKit.retint does for every chunky button in the game, and it is the one
	that leaves the bar looking like it is made of the same stuff as the rest of
	the interface.
]]
local fillTint: Color3? = nil
local function tintFill(c: Color3)
	if fillTint == c then
		return
	end
	fillTint = c
	fill.BackgroundColor3 = c
	fillGrad.Color = ColorSequence.new(c:Lerp(C.white, 0.3), PanelKit.darken(c, 0.2))
end
tintFill(C.lime)

--[[
	THE HOLD ARRIVES IN CHUNKS, SO THE BAR MOVES IN CHUNKS.

	A net sweep is a dozen items at once. Writing fill.Size every frame made
	each of those a hard jump of a few percent -- correct, and completely
	unfelt. Tweening to each new target instead is the kit's rule (back easing
	on everything that moves) and it is the difference between a number
	changing and something landing in the back of the truck.

	Back only on the way UP. Back-out overshoots PAST its target and settles,
	which on a rising bar is the punch; on a falling one -- the unload at the
	shop, 90% to nothing -- it would swing through negative width and flicker
	the fill out of existence for two frames. Quad down.
]]
local fillGoal = 0.06
local fillTween: Tween? = nil

local function setFill(f: number)
	if f == fillGoal then
		return
	end
	local rising = f > fillGoal
	fillGoal = f
	if fillTween then
		fillTween:Cancel()
	end
	fillTween = TweenService:Create(fill,
		TweenInfo.new(0.22, rising and Enum.EasingStyle.Back or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = UDim2.fromScale(f, 1) })
	fillTween:Play()
end

-- Back to the stub, with no tween, for a machine you have only just got into:
-- the first frame of the loop then fills it from empty to whatever you are
-- carrying, which is the one moment the bar is worth watching.
local function resetFill()
	if fillTween then
		fillTween:Cancel()
		fillTween = nil
	end
	fillGoal = 0.06
	fill.Size = UDim2.fromScale(0.06, 1)
end

----------------------------------------------------------------
-- THE CONTROLS LINE
----------------------------------------------------------------
--[[
	BELOW THE CARD, AND ONLY FOR A MOMENT. The controls are what a first-time
	driver needs and what everyone else has read a hundred times, so they are
	not chrome -- they are something the card says once, as you get in.

	ON A DARK PILL NOW, because this is the one piece of type in the HUD with
	nothing behind it. Muted brown at 9px, on open sand, in bright sun, in the
	four and a half seconds it exists: it was very nearly invisible in the exact
	moment it had to be read. Wood, ink outline, sand-coloured type -- the same
	three parts as everything else -- and AutomaticSize so the pill is however
	wide the sentence is rather than however wide someone guessed.

	Parented to root rather than card so it is not clipped by the corner radius
	and does not have to fit the card's width.
]]
local HINT_BG = 0.08

local hint = Instance.new("TextLabel")
hint.Name = "Hint"
hint.AnchorPoint = Vector2.new(0.5, 0)
hint.Position = UDim2.new(0.5, 0, 1, 10)
hint.Size = UDim2.fromOffset(0, 24)
hint.AutomaticSize = Enum.AutomaticSize.X
hint.BackgroundColor3 = C.woodDark
hint.BackgroundTransparency = 1
hint.BorderSizePixel = 0
hint.Font = Enum.Font.GothamBold
hint.TextSize = 10
hint.TextColor3 = C.sand
hint.TextTransparency = 1
hint.Text = ""
hint.ZIndex = 8
hint.Parent = root
PanelKit.corner(hint, 12)
local hintStroke = PanelKit.outline(hint, 2.5)
hintStroke.Transparency = 1
local hintPad = Instance.new("UIPadding")
hintPad.PaddingLeft = UDim.new(0, 14)
hintPad.PaddingRight = UDim.new(0, 14)
hintPad.Parent = hint

----------------------------------------------------------------
-- WHAT WE ARE SITTING IN
----------------------------------------------------------------
--[[
	A machine from the car spawner is a seat whose model carries a NetRadius
	attribute -- the same mark AtvBuilder and DozerBuilder both stamp on. Any
	other seat in the game (a deck chair, the ferry) is not one of ours and
	gets no dashboard.
]]
local function machineOf(humanoid: Humanoid?)
	local seat = humanoid and humanoid.SeatPart
	local model = seat and seat.Parent
	if not (model and model:IsA("Model")) then
		return nil
	end
	if type(model:GetAttribute("NetRadius")) ~= "number" then
		return nil
	end
	return model
end

local current: Model? = nil

--[[
	THE POP, THROUGH A UISCALE RATHER THAN THROUGH THE ROOT'S SIZE.

	PanelKit.popIn tweens the root's Size, which only carries children that are
	themselves sized in SCALE -- and every readout on this card is placed at a
	measured offset, so what the old pop actually animated was an empty slab
	growing out from under a set of labels that never moved.

	A UIScale scales the object AND its descendants about the anchor point, and
	this card's anchor is its bottom centre, so the whole dashboard punches up
	off the bottom of the screen as one piece, controls line included. Same 0.3s
	Back-out as PanelKit.popIn: the kit's move, taken through the one property
	that works on a hand-placed layout.
]]
local scale = Instance.new("UIScale")
scale.Parent = root

local function popIn()
	scale.Scale = 0.7
	TweenService:Create(scale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }):Play()
end

-- The controls line, up for a moment and then gone. Tokened, because getting
-- out of one machine and straight into another must not leave the first one's
-- fade running across the second one's line -- and the fade is three tweens
-- now (type, pill, outline), so they are held and cancelled rather than
-- out-written, which a direct property set cannot do to a running tween.
local hintToken = 0
local hintTweens: { Tween } = {}

local function stopHintTweens()
	for _, t in hintTweens do
		t:Cancel()
	end
	table.clear(hintTweens)
end

local function hideHint()
	stopHintTweens()
	hint.TextTransparency = 1
	hint.BackgroundTransparency = 1
	hintStroke.Transparency = 1
end

local function flashHint(str: string)
	hintToken += 1
	local mine = hintToken
	stopHintTweens()
	hint.Text = str
	hint.TextTransparency = 0
	hint.BackgroundTransparency = HINT_BG
	hintStroke.Transparency = 0
	task.delay(HINT_HOLD, function()
		if hintToken ~= mine then
			return
		end
		local info = TweenInfo.new(0.55)
		local a = TweenService:Create(hint, info, { TextTransparency = 1, BackgroundTransparency = 1 })
		local b = TweenService:Create(hintStroke, info, { Transparency = 1 })
		table.insert(hintTweens, a)
		table.insert(hintTweens, b)
		a:Play()
		b:Play()
	end)
end

local function show(model: Model?)
	current = model
	gui.Enabled = model ~= nil
	if not model then
		-- Cancel any pending fade and put the line away with the card, so
		-- getting straight back in shows it again from full rather than
		-- mid-tween.
		hintToken += 1
		hideHint()
		return
	end
	title.Text = string.upper((model.Name:gsub("^Veh_", "")))
	resetFill()
	flashHint("WASD drive  \u{2022}  SPACE to get out  \u{2022}  F to unload")
	popIn()
end

RunService.RenderStepped:Connect(function()
	local char = player.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	local model = machineOf(humanoid)
	if model ~= current then
		show(model)
	end
	if not model then
		return
	end

	local chassis = model.PrimaryPart
	if chassis then
		-- Rounded to a whole number. A speedometer flickering through three
		-- decimals is noise, not information.
		speed.Text = string.format("%d", math.floor(chassis.AssemblyLinearVelocity.Magnitude + 0.5))
	end

	local load = tonumber(player:GetAttribute(WeightConfig.HoldLoadAttribute)) or 0
	local max = tonumber(player:GetAttribute(WeightConfig.HoldMaxAttribute)) or 0
	if max > 0 then
		local f = math.clamp(load / max, 0, 1)
		-- Floored at a sliver rather than zero, exactly as the kit's bar does
		-- it: an empty track reads as a broken bar where a stub reads as
		-- "empty".
		setFill(math.max(f, 0.06))
		--[[
			THREE STAGES, NOT TWO. Lime the whole way up said nothing at all
			until it said coral, so the only warning a driver ever got was the
			one that means "you are already done". Sun at 60% is the stage that
			can still be acted on -- there is a run left in it -- and coral at
			90% keeps exactly its old meaning: from here on the beach stops
			going in. The figure turns with the bar so the two never disagree.
		]]
		tintFill(f >= 0.9 and C.coral or (f >= 0.6 and C.sun or C.lime))
		loadText.TextColor3 = (f >= 0.9) and C.coralDark or C.seaDark
		loadText.Text = string.format("%d/%d", math.floor(load + 0.5), math.floor(max + 0.5))
	else
		setFill(0.06)
		tintFill(C.lime)
		loadText.TextColor3 = C.seaDark
		loadText.Text = "0"
	end
end)
