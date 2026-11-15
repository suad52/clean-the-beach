--[[
	SignKit  --  ReplicatedStorage.Modules.SignKit

	ONE FACE FOR EVERY SIGN IN THE WORLD.

	The shack row had grown a different sign style per builder, plus two more on
	the boards authored in the place file:

		CAR SPAWN      LuckiestGuy  cream   3px stroke
		WASH BAY       LuckiestGuy  gold    no stroke
		SELL           FredokaOne   gold    no stroke
		  ...and the OTHER side of that same board read "[coin] SELL HERE [coin]"
		  with emoji in it, so the one sign said two different things
		BEACH SHOP     FredokaOne + GothamBold, no stroke
		OPEN           FredokaOne   green   3px stroke
		DUNE BAZAAR    LuckiestGuy  brown   no stroke

	They now all come through here.

	THE RULES
	---------
	  * LuckiestGuy for a NAME, GothamBold for a readout under it. That is the
	    same pairing the HUD already uses -- a LuckiestGuy headline over a
	    GothamBold sub-line -- so a sign reads as part of the game rather than as
	    a prop somebody dropped in.
	  * A heavy ink outline on every one, in the warm ink MenuHud's rail and
	    CTB_HUD's panels already share. Sharing one outline colour is most of
	    what makes separately-built things read as one set.
	  * Lettering CONTRASTS with the board it is on, decided from the board's own
	    luminance: cream letters and ink outline on a dark board, ink letters and
	    cream outline on a pale one. The Dune Bazaar's board is pale sand and the
	    row's are near-black, so a single fixed text colour cannot serve both --
	    inverting the pair keeps it ONE style, legible on either.

	NO EMOJI. Roblox's font has no fallback for newer emoji and they come out as
	a narrow box, which reads as a broken sign rather than a missing glyph --
	the same reason ToastKit's badges are ASCII. See the note at its KINDS table.

	THE CANVAS IS DERIVED FROM THE FACE, AND SIZED AROUND THE TextSize CEILING
	--------------------------------------------------------------------------
	Three of these boards carried a 800x600 canvas on a face that is 4:1 or wider
	-- SellArea's is 15 x 3.6 studs. A SurfaceGui stretches its canvas to fill the
	face, so those were drawing 4:3 lettering squashed onto a letterbox, which is
	most of why the same font looked like a different weight from board to board.
	The canvas here is computed from the face, so its aspect is right by
	construction and stays right if anyone resizes a board.

	Its HEIGHT is not a free choice, though, because Roblox clamps TextSize at
	100 no matter what you ask for (measured: asking 127 or 200 both come back
	100). A fixed pixels-per-stud density therefore punishes big boards -- at 48
	px/stud SellArea's 3.6-stud board wanted 127px lettering, got 100, and ended
	up with text at 58% of its board height while the wash bay next door sat at
	74%. Same font, same rule, visibly different signs: exactly the problem this
	file exists to end.

	So the canvas height is pinned so the text block lands ON the ceiling --
	canvasH = 100 / (the fraction of the canvas that block gets) -- and the width
	follows the face aspect. Every board then renders its name at the same
	fraction of its own height, and the pixel density falls out where it should:
	dense on the little OPEN plaque you read from two studs away, sparser on the
	26-stud Bazaar sign you read from across the dunes.

	THE TEXT IS MEASURED, NOT TextScaled. TWO REASONS, AND THE FIRST IS A TRAP
	-------------------------------------------------------------------------
	1. TextScaled and TextWrapped are the SAME SWITCH in disguise. Setting
	   TextScaled = true turns TextWrapped on with it, and setting TextWrapped =
	   false afterwards turns TextScaled straight back OFF -- silently, with no
	   error. Every sign styled that way falls back to the authored TextSize,
	   which on these boards was 8, and the row renders as blank planks with a
	   speck in the middle. (Confirmed in-place: a label came back reading
	   scaled=false the instant TextWrapped was cleared.)
	2. Even done in the right order, TextScaled WANTS to wrap. It picks the
	   largest size that fits the box, and two lines at 32px fit a short wide
	   board better than one line at 34px -- so "SIFTERS BUCKETS BOOTS" breaks
	   mid-phrase and hangs its second row off the bottom edge.

	So the size is computed here instead: measure the string once at a reference
	size, then take whichever of the height fit and the width fit is smaller. One
	line, always, at the largest size that actually fits the board. Deterministic,
	needs no layout pass to settle, and works on the server -- the same reasoning
	ToastKit records for measuring its pills instead of auto-sizing them.
]]

local TextService = game:GetService("TextService")

local SignKit = {}

-- The warm ink every panel, rail and HUD outline in this game already shares.
SignKit.INK = Color3.fromRGB(56, 36, 20)
SignKit.CREAM = Color3.fromRGB(255, 250, 238)

SignKit.NAME_FONT = Enum.Font.LuckiestGuy
SignKit.SUB_FONT = Enum.Font.GothamBold

-- Roblox's hard clamp on TextLabel.TextSize. Not a style choice -- asking for
-- more silently gives you this, which is what made the tall boards inconsistent
-- before the canvas was sized around it.
SignKit.TEXT_CEILING = 100

SignKit.NAME_STROKE = 4
SignKit.SUB_STROKE = 2.5

-- Uniform margin, so letters never touch the board edge and every sign in the
-- row carries the same border of empty board around its text.
local NAME_INSET = Vector2.new(0.92, 0.74)

-- Measured at this, then scaled. Big enough that the ratio is accurate and the
-- rounding at the end is worth less than a pixel.
local REFERENCE_SIZE = 100

--[[
	The canvas for one face: aspect from the board, height pinned so `tallestBlock`
	(that block's share of the canvas height) comes out exactly at the ceiling.

	Pass `tallestBlock` for a board carrying more than one row -- the kiosk gives
	its name 0.44 of the face, so its canvas has to be taller for that 0.44 to
	still be 100px.
]]
function SignKit.canvasFor(board: BasePart, face: Enum.NormalId, tallestBlock: number?): Vector2
	local studs = SignKit.faceStuds(board, face)
	local height = SignKit.TEXT_CEILING / (tallestBlock or NAME_INSET.Y)
	-- Guarded: a zero-thickness face would divide by zero and hand the SurfaceGui
	-- a NaN canvas, which renders as nothing at all.
	local aspect = (studs.Y > 0) and (studs.X / studs.Y) or 1
	return Vector2.new(math.max(1, height * aspect), height)
end

--------------------------------------------------------------------------
-- FITTING ONE LINE TO A BOARD
--------------------------------------------------------------------------

-- The studs a given face actually presents, which is NOT always X by Y: a thin
-- board signed on its Left/Right faces shows Z by Y, and that is exactly the
-- shape the car spawner's and the wash bay's side boards are.
function SignKit.faceStuds(board: BasePart, face: Enum.NormalId): Vector2
	local s = board.Size
	if face == Enum.NormalId.Left or face == Enum.NormalId.Right then
		return Vector2.new(s.Z, s.Y)
	elseif face == Enum.NormalId.Top or face == Enum.NormalId.Bottom then
		return Vector2.new(s.X, s.Z)
	end
	return Vector2.new(s.X, s.Y)   -- Front / Back
end

--[[
	Set `label` to the largest ONE-LINE size that fits `box` pixels.

	`measureAs` is for a label whose text changes at runtime: the kiosk's readout
	grows from "Lv.1 - 9 studs" to "Lv.6 - 34 studs", and a sign that re-sized its
	own lettering every time the number ticked would read as broken. Measure the
	widest it will ever be, and it never moves.
]]
function SignKit.fitOneLine(label: TextLabel, box: Vector2, measureAs: string?)
	-- Order matters: TextScaled has to go first, because clearing TextWrapped
	-- while TextScaled is on turns TextScaled off anyway and the two would fight.
	label.TextScaled = false
	label.TextWrapped = false

	local str = measureAs or label.Text
	if str == "" then
		return
	end
	local ok, bounds = pcall(function()
		return TextService:GetTextSize(str, REFERENCE_SIZE, label.Font, Vector2.new(1e5, 1e4))
	end)
	if not (ok and bounds and bounds.X > 0) then
		-- No metrics (an unloaded font on a headless server): fall back to the box
		-- height, which is right for a short name and merely too big for a long one.
		label.TextSize = math.max(1, math.floor(box.Y))
		return
	end

	local byHeight = box.Y / REFERENCE_SIZE          -- bounds.Y IS the reference on one line
	local byWidth = box.X / bounds.X
	label.TextSize = math.max(1, math.floor(REFERENCE_SIZE * math.min(byHeight, byWidth)))
end

--------------------------------------------------------------------------
-- CONTRAST
--------------------------------------------------------------------------

-- Rec. 709 luma. Not a plain average: a mid green and a mid blue average the
-- same and do not read the same, and the Bazaar's sand board sits right where
-- that difference decides which way round the lettering has to go.
local function luma(c: Color3): number
	return 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B
end

-- Returns (textColour, strokeColour) for lettering that sits on `board`.
function SignKit.contrastOn(board: BasePart?): (Color3, Color3)
	if board and luma(board.Color) > 0.5 then
		return SignKit.INK, SignKit.CREAM
	end
	return SignKit.CREAM, SignKit.INK
end

--------------------------------------------------------------------------
-- STYLING ONE LABEL
--------------------------------------------------------------------------

local function ensureStroke(label: TextLabel, thickness: number, colour: Color3)
	local s = label:FindFirstChildOfClass("UIStroke")
	if not s then
		s = Instance.new("UIStroke")
		s.Parent = label
	end
	s.Thickness = thickness
	s.Color = colour
	-- Contextual outlines the GLYPHS. Border would box the label's rectangle,
	-- which on a transparent label is a frame around nothing.
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.LineJoinMode = Enum.LineJoinMode.Round
	return s
end

--[[
	Style an existing label as a sign NAME.

	`tint` overrides the contrast colour for the rare sign whose colour carries
	meaning rather than decoration -- the shop's green OPEN is the only one. The
	stroke still comes from the board, so an accent name keeps the same outline
	as every other sign and still reads as part of the set.
]]
function SignKit.name(label: TextLabel, board: BasePart, face: Enum.NormalId, tint: Color3?)
	local text, ink = SignKit.contrastOn(board)
	label.Font = SignKit.NAME_FONT
	label.TextColor3 = tint or text
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(NAME_INSET.X, NAME_INSET.Y)
	ensureStroke(label, SignKit.NAME_STROKE, ink)

	-- From the CANVAS we just derived, not from AbsoluteSize: nothing has laid
	-- out yet when a builder calls this, and on the server it never will.
	local canvas = SignKit.canvasFor(board, face)
	SignKit.fitOneLine(label, Vector2.new(canvas.X * NAME_INSET.X, canvas.Y * NAME_INSET.Y))
	return label
end

-- The readout line under a name -- the kiosk's "Lv.3 - 13 studs". Same ink, one
-- step down in weight, so it reads as a caption rather than as a second sign.
-- `box` is the label's own share of the board, since a sub-line never gets the
-- whole face; `measureAs` is the widest string it will ever hold.
function SignKit.sub(label: TextLabel, board: BasePart, box: Vector2, measureAs: string?)
	local text, ink = SignKit.contrastOn(board)
	label.Font = SignKit.SUB_FONT
	label.TextColor3 = text
	label.BackgroundTransparency = 1
	ensureStroke(label, SignKit.SUB_STROKE, ink)
	SignKit.fitOneLine(label, box, measureAs)
	return label
end

--[[
	A FLOATING label -- one that lives in a BillboardGui rather than on a board:
	the sell pad's "STEP HERE TO SELL", the desert gate's "SIFTER Lv.3 NEEDED".

	Same face and same outline as the boards, so the whole beachfront speaks with
	one voice, but TextScaled is left ON and the size is NOT measured. A
	BillboardGui's pixel size changes with camera distance, so there is no fixed
	box to fit to -- TextScaled is the right tool there, and the wrapping it drags
	along is harmless on a label that is already sized to its own text.

	`tint` is expected rather than exceptional here: these labels are colour-coded
	status (mint for a live pad, salmon for a locked gate) and that coding is
	worth more than uniform cream. The FONT and the OUTLINE are what make them
	match.
]]
function SignKit.floating(label: TextLabel, tint: Color3?)
	label.Font = SignKit.NAME_FONT
	label.TextColor3 = tint or SignKit.CREAM
	label.TextScaled = true
	label.BackgroundTransparency = 1
	-- The legacy TextStroke renders thinner than a UIStroke at the same nominal
	-- weight, which is why the gate sign looked lighter than the boards despite
	-- already carrying the right ink. One outline system, not two.
	label.TextStrokeTransparency = 1
	ensureStroke(label, SignKit.NAME_STROKE, SignKit.INK)
	return label
end

--------------------------------------------------------------------------
-- THE SURFACE
--------------------------------------------------------------------------

function SignKit.surface(board: BasePart, face: Enum.NormalId, tallestBlock: number?): SurfaceGui
	local existing
	for _, c in ipairs(board:GetChildren()) do
		if c:IsA("SurfaceGui") and c.Face == face then
			existing = c
			break
		end
	end
	local sg = existing or Instance.new("SurfaceGui")
	sg.Face = face
	sg.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	sg.CanvasSize = SignKit.canvasFor(board, face, tallestBlock)
	-- 0, so a sign reads the same at any sun angle. These are painted boards,
	-- not screens, but a lit SurfaceGui goes muddy in the shack's shadow.
	sg.LightInfluence = 0
	sg.Parent = board
	return sg
end

--[[
	Dress a board: one name, on every face given, all saying the same thing.

	Passing more than one face is the normal case, not the exception. A thin
	board has two readable sides and signing only one is a coin flip you lose
	half the time -- the wash bay's own board records losing it.
]]
function SignKit.dress(board: BasePart, text: string, faces: { Enum.NormalId }, tint: Color3?)
	for _, face in ipairs(faces) do
		local sg = SignKit.surface(board, face)
		local label = sg:FindFirstChild("Name") or sg:FindFirstChildWhichIsA("TextLabel")
		if not label then
			label = Instance.new("TextLabel")
			label.Parent = sg
		end
		label.Name = "Name"
		label.Text = text
		SignKit.name(label, board, face, tint)
	end
	return board
end

return SignKit
