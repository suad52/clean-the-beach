--[[
	PanelKit  --  ReplicatedStorage.Modules.PanelKit

	ONE CARTOON RECIPE FOR EVERY PANEL IN THE GAME.

	This is MenuHud's look, lifted out of MenuHud so it is not MenuHud's alone.
	The car spawner had grown its own -- flat slate panels, FredokaOne, hairline
	strokes, no slabs and no gloss -- and next to the Beach Shop it read as a
	different game's menu. Rather than copy the recipe across (this codebase has
	already paid for three notification systems and five sign styles), both draw
	from here.

	THE RECIPE. Four things do almost all the work, and every surface gets all
	four:

	  1. A SHADOW SLAB behind, offset down a few px in a darker shade of the same
	     hue. This is what makes a button read as a physical chunky object rather
	     than a coloured rectangle -- and pressing it moves the face down ONTO the
	     slab, which is why the click feels like a real button.
	  2. A THICK DARK OUTLINE (4-6px). Thin strokes read as "default Roblox".
	  3. A GLOSS CAP -- a white bar across the top ~46%, faded out downward. Cheap
	     fake specular; it is the single biggest "toy plastic" cue.
	  4. BACK EASING on every tween, so things overshoot and settle.

	Panels sit dead straight. An earlier pass tilted them a degree or two on the
	theory that axis-aligned rectangles look like a form -- in practice it just
	read as a panel that had not finished animating. The pop-in scale is what
	gives them life instead.
]]

local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")

local UiFit = require(script.Parent:WaitForChild("UiFit"))
-- Curves, durations, and the player's own ReducedMotion setting. Requires
-- nothing but TweenService, so it cannot close a loop back to here.
local Motion = require(script.Parent:WaitForChild("Motion"))

local PanelKit = {}

--[[
	HOW FAR THE BANNER HANGS ABOVE THE CARD.

	Named rather than written twice: the banner's own Position uses it, and so
	does the safe-area fit below, which has to know the card's TRUE top edge --
	the banner is where the close X lives, so a fit measured to the card alone
	puts the one control that closes the panel out of reach.
]]
local BANNER_LIFT = 22

--[[
	EVERY CARD IS TAGGED, so that something outside this module can answer "is
	a panel up?" without knowing about any of them.

	It has to be here rather than at the nineteen call sites because there is no
	other single place: this module builds the shell for every panel in the game,
	but it does not own the shell's visibility. `popIn` is the only shared way UP
	and there is no shared way down -- each caller hides itself, and they are
	split down the middle about how. MenuHud's panels and the trade window move
	the root's Visible under a ScreenGui that is Enabled from boot to logout; the
	car spawner and the ferry dialogue leave the root Visible forever and toggle
	the ScreenGui instead. So a reader has to AND the two tests, and this tag is
	what gives it the list to run them over.

	The tag says "this frame is a panel card". It does NOT say the card is open.
	PanelKit.card does not hide what it builds -- a card is Visible from the
	instant it is constructed until its caller hides it a line later -- so a
	reader that treats being tagged as being open will see every panel in the
	game open at once during boot.
]]
PanelKit.Tag = "CTB_Panel"

--------------------------------------------------------------------------
-- PALETTE
--------------------------------------------------------------------------
-- `ink` is the same warm outline SignKit letters every board with and CTB_HUD
-- outlines its panels with. Sharing one outline colour is most of what makes
-- separately-written screens read as one set.
PanelKit.C = {
	sand      = Color3.fromRGB(255, 240, 205),
	sandMid   = Color3.fromRGB(246, 219, 165),
	sandDeep  = Color3.fromRGB(222, 186, 126),
	wood      = Color3.fromRGB(146, 96, 54),
	woodDark  = Color3.fromRGB(92, 58, 32),
	ink       = Color3.fromRGB(56, 36, 20),
	white     = Color3.fromRGB(255, 255, 255),
	foam      = Color3.fromRGB(94, 226, 196),
	foamDark  = Color3.fromRGB(38, 158, 138),
	sea       = Color3.fromRGB(64, 168, 240),
	seaDark   = Color3.fromRGB(28, 104, 176),
	coral     = Color3.fromRGB(255, 118, 104),
	coralDark = Color3.fromRGB(198, 62, 62),
	sun       = Color3.fromRGB(255, 200, 62),
	sunDark   = Color3.fromRGB(214, 142, 24),
	grape     = Color3.fromRGB(186, 128, 255),
	grapeDark = Color3.fromRGB(122, 72, 190),
	lime      = Color3.fromRGB(140, 226, 96),
	limeDark  = Color3.fromRGB(86, 162, 52),
}
local C = PanelKit.C

--------------------------------------------------------------------------
-- PRIMITIVES
--------------------------------------------------------------------------

function PanelKit.darken(c: Color3, f: number?): Color3
	return c:Lerp(Color3.new(0, 0, 0), f or 0.35)
end
local darken = PanelKit.darken

function PanelKit.corner(inst: GuiObject, r: number)
	local x = Instance.new("UICorner")
	x.CornerRadius = UDim.new(0, r)
	x.Parent = inst
	return x
end
local corner = PanelKit.corner

function PanelKit.outline(inst: GuiObject, thick: number?, col: Color3?)
	local st = Instance.new("UIStroke")
	st.Thickness = thick or 4
	st.Color = col or C.ink
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.LineJoinMode = Enum.LineJoinMode.Round
	st.Parent = inst
	return st
end
local outline = PanelKit.outline

-- A UIGradient MULTIPLIES against the fill underneath, so anything gradient-lit
-- has to sit on a light base or the two tint each other into mud. CTB_HUD
-- records what that costs: it is what turned its panels near-black.
function PanelKit.grad(inst: GuiObject, top: Color3, bottom: Color3, rot: number?)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(top, bottom)
	g.Rotation = rot or 90
	g.Parent = inst
	return g
end
local grad = PanelKit.grad

-- The gloss cap. Sits inside the face, clipped by the same corner radius.
function PanelKit.gloss(face: GuiObject, r: number)
	local g = Instance.new("Frame")
	g.Name = "Gloss"
	g.BackgroundColor3 = C.white
	g.BorderSizePixel = 0
	g.Size = UDim2.new(1, -10, 0.46, 0)
	g.Position = UDim2.fromOffset(5, 4)
	g.ZIndex = (face.ZIndex or 1) + 1
	g.Parent = face
	corner(g, math.max(4, r - 4))
	local gg = Instance.new("UIGradient")
	gg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(0.7, 0.86),
		NumberSequenceKeypoint.new(1, 1),
	})
	gg.Rotation = 90
	gg.Parent = g
	return g
end
local gloss = PanelKit.gloss

function PanelKit.text(parent: GuiObject, str: string, size: number, font: Enum.Font?, col: Color3?)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = font or Enum.Font.LuckiestGuy
	l.TextSize = size
	l.TextColor3 = col or C.white
	l.Text = str
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.ZIndex = 5
	l.Parent = parent
	return l
end
local text = PanelKit.text

-- Outlined text: the cartoon staple. A real UIStroke on the label.
function PanelKit.punch(l: TextLabel, thick: number?, col: Color3?)
	local st = Instance.new("UIStroke")
	st.Thickness = thick or 2.5
	st.Color = col or C.ink
	st.LineJoinMode = Enum.LineJoinMode.Round
	st.Parent = l
	return st
end
local punch = PanelKit.punch

--[[
	A chunky button: shadow slab + face + gloss + outline, with a press that
	drops the face onto the slab. `holder` is what you position; `face` is the
	clickable TextButton.
]]
function PanelKit.chunky(parent: GuiObject, w: number, h: number, tint: Color3, r: number?)
	r = r or math.floor(h * 0.28)

	local holder = Instance.new("Frame")
	holder.Size = UDim2.fromOffset(w, h + 7)
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	local slab = Instance.new("Frame")
	slab.Name = "Slab"
	slab.Size = UDim2.fromOffset(w, h)
	slab.Position = UDim2.fromOffset(0, 7)
	slab.BackgroundColor3 = darken(tint, 0.45)
	slab.BorderSizePixel = 0
	slab.Parent = holder
	corner(slab, r)
	outline(slab, 4)

	local face = Instance.new("TextButton")
	face.Name = "Face"
	face.Size = UDim2.fromOffset(w, h)
	face.Position = UDim2.fromOffset(0, 0)
	face.BackgroundColor3 = tint
	face.BorderSizePixel = 0
	face.AutoButtonColor = false
	face.Text = ""
	face.Parent = holder
	corner(face, r)
	outline(face, 4)
	grad(face, tint:Lerp(C.white, 0.25), darken(tint, 0.18))
	gloss(face, r)

	local up, down = UDim2.fromOffset(0, 0), UDim2.fromOffset(0, 5)
	face.MouseButton1Down:Connect(function()
		TweenService:Create(face, TweenInfo.new(0.06), { Position = down }):Play()
	end)
	face.MouseButton1Up:Connect(function()
		TweenService:Create(face, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Position = up }):Play()
	end)
	face.MouseLeave:Connect(function()
		TweenService:Create(face, TweenInfo.new(0.12), { Position = up }):Play()
	end)
	return holder, face, slab
end
local chunky = PanelKit.chunky

--[[
	Recolour a chunky button after the fact -- a BUY that turns red when you
	cannot afford it, a SPAWN that turns blue once you own the thing.

	Not just BackgroundColor3. The face carries a UIGradient baked from the
	ORIGINAL tint, and a UIGradient MULTIPLIES against the fill underneath -- so
	painting a coral face under a lime gradient gives neither colour, it gives
	mud. Both stops move with the fill. (The Beach Shop's own rows still do the
	naive version and are a shade off because of it; they should come through
	here too.)
]]
function PanelKit.retint(face: GuiObject, slab: GuiObject?, tint: Color3)
	face.BackgroundColor3 = tint
	-- The face's OWN gradient. gloss() puts another one on the Gloss frame, which
	-- is a child of the face, not of this search.
	local g = face:FindFirstChildOfClass("UIGradient")
	if g then
		g.Color = ColorSequence.new(tint:Lerp(C.white, 0.25), darken(tint, 0.18))
	end
	if slab then
		slab.BackgroundColor3 = darken(tint, 0.45)
	end
end

--------------------------------------------------------------------------
-- THE PANEL SHELL
--------------------------------------------------------------------------
--[[
	Slab + sand card + an overhanging tinted banner with a coral X on it.
	Returns (root, body, closeFace, banner, setTitle) -- the caller parents
	`root`, fills `body`, and decides what the X does, because "close" means
	something different to a rail panel and to a world-prompt modal.

	`setTitle` is for a panel that is RENAMED after it is built -- one stock
	list standing in for four counters, one reveal card standing in for six
	rarities. Take it and never touch the labels: the title is two of them and
	setting one is the bug written out at the labels themselves.

	`banner` is handed back for the rare panel with a SECOND global action. It is
	the right home for one: a button there is out of the content's way and reads
	as belonging to the whole panel rather than to a row, which is exactly what a
	"put the thing away" does. Mirror the X's geometry on the left.

	ZINDEXES ARE EXPLICIT. MenuHud's gui runs ZIndexBehavior.Global, where being
	a child counts for nothing: chunky() leaves its slab and face at 0 and the
	banner is 4, so the coral button drew UNDER the banner on every panel in the
	game and all that showed was a bare white X floating on the signboard.
]]
--[[
	THE CARD IS FITTED TO THE SAFE AREA, NOT TO THE WHOLE WINDOW. Added 2026-09-09
	off a playtest.

	Every panel in the game is one of these: a fixed-height card centred on its
	ScreenGui, with the banner -- and the close X inside it -- hanging BANNER_LIFT
	above the card's top edge. Centred on the physical screen, that banner lands
	inside the band Roblox reserves for its own top bar, and ROBLOX OWNS THE TAPS
	THERE. Measured on a 1269x662 window: the Beach Shop's close button sat at
	y -40..2, two of its forty-two pixels reachable, and clicking where it appears
	did nothing at all -- the only way out of that panel was to walk away from the
	shop prompt.

	IT IS NOT A PHONE PROBLEM. It is the card's own height against the space under
	the bar, so the tallest panels go first -- Beach Shop 640, Pets 620, Settings
	600 -- and a 1366x768 desktop, the commonest Roblox window there is, already
	loses two of them. It got WORSE when a player raised HUD SIZE, which is the
	one thing they would try: at HUGE the Settings close button measured y
	-110..-55, a hundred pixels up into the bar.

	TWO PARTS, AND BOTH BELONG HERE RATHER THAN IN UiFit, because the problem is
	this CARD's height and not the HUD's scale. Capping the global scale to fit
	the tallest panel would shrink the rail, the pills and the wash bay with it,
	on every screen, open panel or not -- and it would break WashHud's reticle,
	which is drawn in raw screen coordinates on purpose (see WashClientController's
	note on IgnoreGuiInset).

		1. The card is pushed down by half the inset, so it centres in the space
		   the player can see and touch instead of in the whole window.
		2. It carries a UIScale of its own that ONLY EVER SHRINKS, and only when
		   the card is bigger than that space -- on EITHER axis.

	THE WIDTH MATTERS AS MUCH AS THE HEIGHT, and it is the same bug seen sideways.
	UiFit's fit takes the smaller of the width and height terms and then clamps
	the result UP to a 0.6 floor, which throws the width away: hold the phone
	upright at 402x750 and the true fit is 0.314 while the HUD still draws at 0.6,
	so the panels come out wider than the screen and the close X on Pets and on
	the trade window is off the right edge entirely -- with the pet grid then
	sitting over the rail key that would have toggled the panel shut. Fitting the
	card's own widest part (the banner, w + 34) here fixes that without touching
	the global scale, which must keep its floor: text that shrinks below it stops
	being readable, and the rail and the pills are not what overflows.

	Only ScreenGuis that IGNORE the inset need part 1 -- one that respects it is
	already inside the safe area and must not be pushed twice, so the offset is
	resolved from the host at fit time rather than assumed.

	Re-fitted on every UiFit change and every viewport change, so a rotation or a
	HUD SIZE tap re-solves it. `popIn` animates Size, not Scale, so the open
	animation is untouched by any of this.
]]
local function fitToSafeArea(root: Frame, w: number, h: number)
	local fit = Instance.new("UIScale")
	fit.Name = "SafeFit"
	fit.Scale = 1
	fit.Parent = root

	-- The last Position this function wrote, or nil before the first one. See the
	-- note over the write itself: it is how a card whose OWNER places it is told
	-- apart from one still sitting where PanelKit put it.
	local placed: UDim2? = nil

	local function resolve()
		if not root.Parent then
			return
		end
		local camera = workspace.CurrentCamera
		local viewport = camera and camera.ViewportSize
		if not viewport or viewport.Y <= 1 then
			return
		end

		-- Resolved every time rather than cached: `absorb` reparents this card into
		-- UiFit's FitRoot a frame after it is built, so the ScreenGui above it is
		-- not knowable when card() runs.
		local screen = root:FindFirstAncestorWhichIsA("ScreenGui")
		local inset = (screen and screen.IgnoreGuiInset) and GuiService:GetGuiInset().Y or 0

		--[[
			SOLVED ABOUT THE CARD'S CENTRE, AND THE CENTRE IS THE SAFE AREA'S.

			MEASURED FROM THE CENTRE OUTWARDS, BECAUSE THE CARD IS NOT SYMMETRIC.
			The banner hangs BANNER_LIFT above the slab and nothing hangs below it,
			so the half that must clear the top bar is taller than the half that must
			clear the bottom of the screen. Solving it as one centred box -- which is
			what this did first -- comes out about 3.5% too generous and leaves the
			close X eight pixels inside the bar. Measured exactly that on the Settings
			card before this was written the second time. Both halves are still solved
			separately below; what changed is only WHERE the centre sits.
		]]
		local aboveCentre = h * 0.5 + BANNER_LIFT
		local belowCentre = h * 0.5

		-- UiFit's FitRoot already carries the HUD scale, so the card renders at
		-- <authored> * hud * own. Solve `own` for what is left.
		local hud = UiFit.get()
		if hud <= 0 then
			hud = 1
		end

		--[[
			PART 1, WHICH THE NOTE ABOVE HAS ALWAYS DESCRIBED AND THE CODE HAS NEVER
			DONE: push the card down by half the inset.  2026-09-18

			Leaving the card centred on the WINDOW while demanding that its banner
			clear the top bar makes it pay for that bar TWICE -- once in the room it
			gives up above, and again in the identical room it then cannot use below.
			Measured in Play at 735x278, inset 58, hud 0.600, with Pets open: the card
			rendered y 5..157 inside a safe area of 0..220, so it was squeezed to 0.407
			while 63 usable pixels sat empty underneath it.

			Centred in the safe area instead, both halves get 110 and the same card
			solves to 0.552 -- a THIRD bigger on a screen that did not change. The gain
			lands exactly where it is needed: the global fit is pinned to UiFit's 0.6
			floor on every phone, so every phone was paying this in full.

			THE OFFSET IS DIVIDED BY `hud` BECAUSE IT IS RESOLVED IN THE PARENT. A
			Position offset on this card is measured in the FitRoot's units and the
			FitRoot carries the HUD scale, so a raw inset/2 would land as inset/2 * hud
			real pixels -- under-pushing hardest on the small screens this is for.
			SafeFit does not enter into it: a UIScale scales the object it sits on, not
			the offset that placed it.

			The note that stood above said the card is never moved, and gave "nothing
			here has to reason about which UIScale a Position offset is resolved
			against" as the reason. That reasoning is the paragraph above, and a third
			of every panel is too much to pay for not writing it. Nothing in the game
			reads or writes a card root's Position -- checked before this changed.
		]]
		--[[
			AND ONLY WHILE NOBODY ELSE IS PLACING THIS CARD.

			Not every card is centred. RevealPopup drives its own Position -- it parks
			the card offscreen right and tweens it to a fixed TOP-anchored rest spot,
			because the top-right corner is the one place a 320x400 card can land
			without covering something live. TradeHud, FreeRewardGui and the admin
			panel leave theirs centred; DuelHud's three change the AnchorPoint instead.

			A resolve firing after RevealPopup had parked its card -- a window resize, a
			HUD SIZE tap, a phone rotating -- would have yanked it back to the middle of
			the screen and left it there, because that file only writes Position inside
			`present`. The next reveal would then appear from the centre instead of
			sliding in from the edge, and every one after it.

			So remember what was written and write again only if that is still what is
			there. A card its owner has placed keeps its placement; one nobody has
			touched centres in the safe area. Compared by value -- UDim2 is a value
			type, so this is an equality test and not an identity one.
		]]
		local want = UDim2.new(0.5, 0, 0.5, (inset * 0.5) / hud)
		if placed == nil or root.Position == placed then
			root.Position = want
			placed = want
		end

		--[[
			MEASURED AGAINST THE GUI'S OWN HEIGHT, NOT THE WINDOW'S.

			A ScreenGui that RESPECTS the inset is already shorter than the viewport by
			exactly the top bar, so solving one against viewport.Y handed it half an
			inset of room that was never its to spend. That is the one direction in
			which this fit could let a card off the BOTTOM of the screen rather than
			merely shrink it too far. `inset` is zero for those guis, so the same two
			lines cover both kinds.
		]]
		local host = (screen and screen.AbsoluteSize.Y > 1) and screen.AbsoluteSize or viewport
		local half = math.max(1, (host.Y - inset) * 0.5)

		-- The banner overhangs the slab by 17 a side, so it -- not `w` -- is what
		-- has to clear the screen edges. No inset on this axis.
		fit.Scale = math.min(1,
			half / (aboveCentre * hud),
			half / (belowCentre * hud),
			host.X / ((w + 34) * hud))
	end

	resolve()
	UiFit.onChanged(resolve)
	root:GetPropertyChangedSignal("Parent"):Connect(resolve)

	--[[
		THE CAMERA IS REPLACED ON SOME RESPAWNS, AND A CONNECTION TO IT GOES WITH IT.
		Added 2026-09-18.

		This used to bind workspace.CurrentCamera's ViewportSize once, right here,
		and never again. After a respawn that swapped the camera instance, the only
		thing left to tell a card its window had changed was UiFit.onChanged -- and
		that fires from UiFit.refresh, which RETURNS EARLY when the scale has not
		moved.

		"The scale has not moved" is the common case rather than the rare one. Both
		of scaleFor's ratios sit pinned to MIN_SCALE on every phone in the game and
		to MAX_SCALE on most desktops, so turning a phone from 740x360 to 360x740
		leaves the scale at 0.600 either way round -- while the room a card has goes
		from 302 tall to 682 and its widest part from fitting to not. A card could
		be left solved for the window before last with no second signal coming.

		UiFit.start rebinds for this exact reason and says so; this is the same fix
		one level down. Re-solved on the swap as well as rebound, because replacing
		the camera fires no ViewportSize change of its own and the new one may
		already report a different size.

		THE OLD CONNECTION IS DROPPED FIRST, which UiFit does not bother with -- a
		stale camera's signal simply stops firing. It matters more here: this runs
		once per CARD rather than once for the game, so a session that swapped the
		camera a dozen times would otherwise leave eighteen cards each carrying a
		dozen live subscriptions to resolve.
	]]
	local viewportConn: RBXScriptConnection? = nil
	local function watchCamera()
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		if viewportConn then
			viewportConn:Disconnect()
		end
		viewportConn = camera:GetPropertyChangedSignal("ViewportSize"):Connect(resolve)
	end
	watchCamera()

	local cameraConn = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		watchCamera()
		resolve()
	end)

	-- Both of the above outlive the card otherwise: they hang off Workspace and
	-- the camera, not off root. RevealPopup destroys and rebuilds its whole gui
	-- whenever the viewport crosses UiFit's compact threshold, so this is a card
	-- that really does go away mid-session. (The UiFit.onChanged listener above
	-- cannot be taken back -- that module keeps an append-only list -- but it is
	-- one closure over a resolve that early-returns on a parentless root.)
	root.Destroying:Connect(function()
		if viewportConn then
			viewportConn:Disconnect()
			viewportConn = nil
		end
		cameraConn:Disconnect()
	end)
end

function PanelKit.card(parent: Instance, title: string, w: number, h: number, tint: Color3)
	local root = Instance.new("Frame")
	root.Name = title
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromOffset(w, h)
	root.BackgroundTransparency = 1
	root.Rotation = 0
	root.Parent = parent
	fitToSafeArea(root, w, h)

	--[[
		THE GLOW. Three rounded frames behind the card, tinted with the panel's
		own colour and each one fainter than the last.

		A hard-edged slab on a dimmed backdrop reads as a sticker laid on the
		screen. Light spilling out from behind the edges is what makes the same
		card read as sitting ABOVE it, and it costs three frames.

		Tinted rather than black on purpose: it picks up the banner colour, so
		each panel arrives with its own light around it instead of all five
		sharing one grey shadow.

		ZIndex 0 puts it under the slab (1) under MenuHud's Global behaviour, and
		under the scrim's own 0 by tree order -- the scrim is built first.
	]]
	for i = 3, 1, -1 do
		local glow = Instance.new("Frame")
		glow.Name = "Glow" .. i
		glow.AnchorPoint = Vector2.new(0.5, 0.5)
		glow.Position = UDim2.new(0.5, 0, 0.5, 8)
		glow.Size = UDim2.fromOffset(w + i * 28, h + i * 28)
		-- Lifted a third of the way to white. At full saturation the lime panel
		-- arrived wearing a highlighter and the halo competed with the banner it
		-- was supposed to be lit by; washed out, it reads as light rather than as
		-- a second copy of the colour.
		glow.BackgroundColor3 = tint:Lerp(C.white, 0.35)
		glow.BackgroundTransparency = 0.8 + i * 0.05
		glow.BorderSizePixel = 0
		glow.ZIndex = 0
		glow.Parent = root
		corner(glow, 26 + i * 12)
	end

	local slab = Instance.new("Frame")
	slab.Size = UDim2.fromOffset(w, h)
	slab.Position = UDim2.fromOffset(0, 9)
	slab.BackgroundColor3 = C.woodDark
	slab.BorderSizePixel = 0
	slab.Parent = root
	corner(slab, 26)
	outline(slab, 5)

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.Size = UDim2.fromOffset(w, h)
	card.BackgroundColor3 = C.sand
	card.BorderSizePixel = 0
	card.Parent = root
	corner(card, 26)
	outline(card, 5)
	grad(card, C.sand, C.sandMid)

	--[[
		THE WELL -- a dark recessed board for the content to sit ON.

		THE REAL PROBLEM WAS VALUE, NOT LAYOUT. Every panel was cream card, cream
		tray, cream-white rows: three tones within a few percent of each other and
		nothing anywhere for the eye to anchor on. No amount of aligning things
		fixes a screen with no darks in it -- it just produces tidier mush.

		So the tray went dark, and everything sitting on it stayed bright. That is
		one change and it is most of why these panels stopped looking generated:
		the reward cards, the settings rows and the shop rows are all pale, and
		against wet-dark wood they read as paper pinned to a board.

		IT IS NOT A NEW IDEA IN THIS GAME, WHICH IS THE POINT. The coin counter
		and the weight bar in the corner have been dark pills the whole time --
		the panels were the only surface in the HUD that had no darks at all.

		WHITE UNDER THE GRADIENT. A UIGradient multiplies against the fill below
		it -- the card above does sand-over-sand and comes out a good deal deeper
		than either stop says -- so this one carries its colours honestly.

		It is built BEFORE `body`. Both sit at ZIndex 1 and Global behaviour
		breaks that tie on tree order, so the tray has to be the earlier child or
		it paints over everything the caller puts in the body.
	]]
	local well = Instance.new("Frame")
	well.Name = "Well"
	well.Position = UDim2.fromOffset(12, 50)
	well.Size = UDim2.new(1, -24, 1, -62)
	well.BackgroundColor3 = C.white
	well.BorderSizePixel = 0
	well.ClipsDescendants = true
	well.ZIndex = 1
	well.Parent = card
	corner(well, 18)
	grad(well, Color3.fromRGB(66, 42, 26), Color3.fromRGB(104, 70, 44))
	outline(well, 3)

	--[[
		THE PLANKING IS GONE, AND THE ARGUMENT FOR IT DID NOT SURVIVE BEING LOOKED AT.

		This used to lay sixteen white frames across the well at 45 degrees, 18px
		thick, at 0.95 transparency -- described here as "individually invisible,
		and together the difference between a surface and a fill".

		They were not invisible. Eighteen pixels is thick enough that a twentieth of
		an alpha still reads, and because they were WHITE on a dark wood well the
		contrast ran the wrong way -- so every panel in the game wore a set of pale
		diagonal bands across it. Read as a hatched placeholder swatch rather than
		as grain, which is the exact failure the comment was trying to avoid.

		THE WELL IS STILL NOT A FLAT FILL, which was the real worry: it carries a
		gradient (66,42,26 -> 104,70,44) plus a 3px outline plus BannerShade's soft
		dark falling across its top edge. That is three sources of value change
		before anything is drawn on it, and it is enough.

		It was also the single most-duplicated object in the interface: PanelKit.card
		builds every panel in the game, so this loop was putting 224 Frames into the
		PlayerGui -- 112 in the menu alone -- for a texture nobody asked for.

		If a surface texture is ever wanted here again, it wants to be DARKER than
		the well rather than lighter, and a few pixels thick rather than eighteen.
	]]

	-- The banner casting into the tray. Sixteen pixels of soft dark under the
	-- signboard is the whole difference between a header sitting on the card and
	-- a header bolted to it.
	local shade = Instance.new("Frame")
	shade.Name = "BannerShade"
	shade.AnchorPoint = Vector2.new(0.5, 0)
	shade.Position = UDim2.new(0.5, 0, 0, 38)
	shade.Size = UDim2.new(1, -22, 0, 18)
	-- Nearly black rather than woodDark: the tray it falls onto is wood now, and
	-- a brown shadow on brown is no shadow at all.
	shade.BackgroundColor3 = Color3.fromRGB(26, 16, 9)
	shade.BorderSizePixel = 0
	shade.ZIndex = 3
	shade.Parent = card
	corner(shade, 9)
	local sg = Instance.new("UIGradient")
	sg.Rotation = 90
	sg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.62),
		NumberSequenceKeypoint.new(1, 1),
	})
	sg.Parent = shade

	-- Banner header, overhanging both edges like a signboard.
	local banner = Instance.new("Frame")
	banner.Name = "Banner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, -BANNER_LIFT)
	banner.Size = UDim2.fromOffset(w + 34, 62)
	banner.BackgroundColor3 = tint
	banner.BorderSizePixel = 0
	banner.ZIndex = 4
	banner.Parent = root
	corner(banner, 20)
	outline(banner, 5)
	grad(banner, tint:Lerp(C.white, 0.28), darken(tint, 0.22))
	gloss(banner, 20)

	--[[
		Two labels: the ink one is a shadow three pixels low. The outline alone
		reads flat at this size, and the title is the one piece of type on the
		panel that is meant to be looked at rather than read.

		SO THERE IS NO "THE TITLE" TO FIND BY CLASS, AND TWO CALLERS HAD ALREADY
		TRIED. The shadow is built FIRST and both were called TextLabel, so
		`banner:FindFirstChildOfClass("TextLabel")` returned the 55%-transparent
		copy: a retitle through it repainted the ghost and left the white label
		reading whatever the panel was AUTHORED with. The Beach Shop opens at
		four counters and showed DUNE OUTFITTERS ghosted behind BEACH SHOP,
		three pixels apart; the reveal card showed every rarity behind COMMON.

		Hence both a NAME each -- so a lookup that has to happen can say which
		one it wants -- and `setTitle` handed back below, which is what a
		retitling caller should actually hold. One write, both copies, no way to
		pick the wrong one.
	]]
	local ts = text(banner, title:upper(), 30, Enum.Font.LuckiestGuy, C.ink)
	ts.Name = "TitleShadow"
	ts.Position = UDim2.fromOffset(0, 3)
	ts.Size = UDim2.fromScale(1, 1)
	ts.TextTransparency = 0.55
	ts.ZIndex = 5
	punch(ts, 3.5)

	local t = text(banner, title:upper(), 30, Enum.Font.LuckiestGuy, C.white)
	t.Name = "Title"
	t.Size = UDim2.fromScale(1, 1)
	t.ZIndex = 6
	punch(t, 3.5)

	-- Upper-cased in here rather than at the call sites, because the build
	-- above does it too and a header that shouts on the beach and whispers in
	-- the dunes is the same seam by a different route.
	local function setTitle(s: string)
		local up = tostring(s):upper()
		t.Text = up
		ts.Text = up
	end

	local closeHolder, closeFace, closeSlab = chunky(banner, 46, 46, C.coral, 15)
	closeHolder.AnchorPoint = Vector2.new(1, 0.5)
	closeHolder.Position = UDim2.new(1, -10, 0.5, -3)
	closeHolder.ZIndex = 7
	closeSlab.ZIndex = 7
	closeFace.ZIndex = 8
	local x = text(closeFace, "X", 24, Enum.Font.LuckiestGuy, C.white)
	x.Size = UDim2.fromScale(1, 1)
	x.ZIndex = 9
	punch(x, 3)

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Position = UDim2.fromOffset(18, 56)
	body.Size = UDim2.new(1, -36, 1, -74)
	body.BackgroundTransparency = 1
	body.Parent = card

	-- See the note by PanelKit.Tag. Tagged on the way out rather than at the top,
	-- so nothing ever sees a half-built card in the list.
	CollectionService:AddTag(root, PanelKit.Tag)

	return root, body, closeFace, banner, setTitle
end

-- The open: punches in from 70% with Back easing. Every panel in the game
-- arrives this way, and a panel that just appeared would read as a different
-- app's menu however well it was painted.
function PanelKit.popIn(root: GuiObject, w: number, h: number)
	root.Visible = true
	root.Rotation = 0
	--[[
		THE PUNCH IS THE GAME'S VOICE AND IT STAYS. 0.70 with Back/Out is a long
		way outside what a productivity interface would do, and the note above
		argues why it is right here: every panel arrives this way, and one that
		merely appeared would read as a different app's menu.

		BUT A PLAYER WHO HAS ASKED FOR REDUCED MOTION HAS ASKED FOR EXACTLY THIS
		TO STOP. Roblox takes that answer in its own accessibility menu and this
		game was reading it nowhere. They get 0.96 -- a settle rather than a
		punch -- on the near-instant step Motion.info collapses to, so the panel
		still transitions rather than teleporting.
	]]
	local from = Motion.reduced() and 0.96 or 0.7
	root.Size = UDim2.fromOffset(w * from, h * from)
	Motion.tween(root, Motion.Dur.panel, Motion.Ease.pop, { Size = UDim2.fromOffset(w, h) })
end

--------------------------------------------------------------------------
-- A ROW
--------------------------------------------------------------------------
--------------------------------------------------------------------------
-- A TURNTABLE  --  a model on a plinth, rotating
--------------------------------------------------------------------------
--[[
	The Index's specimen tank, generalised: a ViewportFrame with the model framed
	by its bounding BOX and a camera that orbits it.

	ORBIT THE CAMERA, NEVER PivotTo THE MODEL. Spinning the model writes every
	part's CFrame every frame -- a quad is a few dozen parts, three of them on
	screen at once -- where spinning the camera is one write and looks identical.
	The Index learned this the same way.

	FRAMED AT EVERY ANGLE THE ORBIT PASSES THROUGH, NOT JUST THE FIRST ONE.
	A single fit at the starting angle is what crops a turning model: a quad is
	half again as long as it is wide, so the silhouette grows and shrinks as it
	comes broadside, and a distance that fitted it nose-on clips both ends a
	quarter turn later. The distance here is solved in closed form against all
	eight corners of the bounding box at 24 sample angles and the worst one wins.

	FOCUSED ON THE MASS, NOT THE BOX CENTRE. These quads carry thin masts that
	add two studs of empty height to the bounding box, so its centre sits well
	above the machine and the body rode low in the plinth with a band of nothing
	over it. The look-at point is the VOLUME-WEIGHTED centroid instead -- chassis
	and wheels outvote a pair of aerials -- and the fit is solved about that same
	point, so re-centring cannot reintroduce cropping.

	The caller gets a handle with :Start() / :Stop() / :Destroy(). Nothing spins
	until Start, so a closed panel costs nothing.
]]

--[[
	Up-front-side rather than straight on: a flat side view makes a vehicle read
	as a cardboard cutout, and this angle shows the length AND the rack.

	IT PUTS THE CAMERA AT +Z, WHICH IS THE BACK OF ANYTHING BUILT TO ROBLOX'S
	CONVENTION -- a part's LookVector is its own -Z, so a model authored to face
	forward has its front at -Z and this direction opens on its tail.

	That was invisible while the only caller was the ATV showroom, whose quads
	are authored the other way round. It is not invisible on an animal. Callers
	whose subject faces -Z pass `startAngle = math.pi`, which is the same orbit
	started half a turn round -- see the egg reveal.
]]
local TURN_DIR = Vector3.new(0.62, 0.38, 1).Unit
local FIT_SAMPLES = 24

function PanelKit.turntable(parent: GuiObject, model: Model, opts: { [string]: any }?)
	opts = opts or {}

	local vpf = Instance.new("ViewportFrame")
	vpf.Name = "Turntable"
	vpf.Size = UDim2.fromScale(1, 1)
	vpf.BackgroundTransparency = 1
	vpf.Ambient = opts.ambient or Color3.fromRGB(190, 180, 165)
	vpf.LightColor = opts.light or Color3.fromRGB(255, 250, 235)
	vpf.LightDirection = Vector3.new(-0.35, -1, -0.5)
	vpf.ZIndex = opts.zIndex or 6
	vpf.Parent = parent

	-- A WorldModel, not a bare parent: without one a ViewportFrame does no
	-- lighting pass and every part comes out flat-shaded and muddy.
	local world = Instance.new("WorldModel")
	world.Parent = vpf

	local shown = model:Clone()
	for _, d in shown:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
	shown.Parent = world

	local camera = Instance.new("Camera")
	camera.FieldOfView = opts.fov or 40
	camera.Parent = vpf
	vpf.CurrentCamera = camera

	local cf, size = shown:GetBoundingBox()
	local aspect = math.max(opts.aspect or 1, 0.05)
	local tanV = math.tan(math.rad(camera.FieldOfView * 0.5))
	local tanH = tanV * aspect

	-- WHERE TO LOOK: the centre of the model's MASS, not of its box.
	local mass, centre = 0, Vector3.zero
	for _, d in shown:GetDescendants() do
		if d:IsA("BasePart") then
			local v = d.Size.X * d.Size.Y * d.Size.Z
			mass += v
			centre += d.Position * v
		end
	end
	centre = (mass > 0) and (centre / mass) or cf.Position

	-- HOW FAR BACK: the eight corners of the box, at every angle the orbit will
	-- reach. For a camera at `centre + dir * D` looking back at `centre`, a point
	-- P decomposes into right (a), up (b) and depth-past-centre (c), and fits
	-- when |a| <= tanH * (D + c) and |b| <= tanV * (D + c). Solve each for D and
	-- take the largest -- exact, and no guessing margin to tune.
	local corners = {}
	for _, sx in { -0.5, 0.5 } do
		for _, sy in { -0.5, 0.5 } do
			for _, sz in { -0.5, 0.5 } do
				table.insert(corners, cf * Vector3.new(size.X * sx, size.Y * sy, size.Z * sz))
			end
		end
	end

	local dist = 0
	for step = 0, FIT_SAMPLES - 1 do
		local dir = (CFrame.Angles(0, step * 2 * math.pi / FIT_SAMPLES, 0) * TURN_DIR)
		local look = CFrame.lookAt(centre + dir, centre)
		for _, p in corners do
			local v = p - centre
			local a = math.abs(v:Dot(look.RightVector))
			local b = math.abs(v:Dot(look.UpVector))
			local c = -v:Dot(look.LookVector)   -- + is further from the camera
			dist = math.max(dist, a / tanH - c, b / tanV - c)
		end
	end
	dist = math.max(dist, 0.1) * (opts.margin or 1.06)

	-- `startAngle` only moves where the orbit BEGINS. The fit above already
	-- solved the distance against all 24 sample angles, so starting anywhere on
	-- the circle is framed exactly as well as starting at zero.
	local handle = { frame = vpf, model = shown, camera = camera,
		t = opts.startAngle or 0, conn = nil }
	local speed = opts.speed or 0.6

	--[[
		ARC: ROCK THROUGH +-arc RADIANS ABOUT startAngle INSTEAD OF ORBITING.

		A full turn is right for a MACHINE, which is roughly as wide from any side.
		It is wrong for a subject with a THIN AXIS, and the shop's Gilded Unicorn is
		the case that proved it: 5.2 studs across against 17.3 long, so its projected
		width was MEASURED at 18.03 studs at t = 40 degrees and 5.74 at t = 150 --
		i.e. a third of every full revolution showed a sliver, and the card looked
		broken for a second at a time.

		`arc` keeps the subject inside the angles that flatter it while still moving,
		which a fixed camera does not. Sine rather than a triangle wave so it eases at
		both ends instead of snapping back.

		THE FIT IS UNAFFECTED. The distance above was already solved against all 24
		sample angles round the full circle, so any subset of them is framed at least
		as well -- an arc can never crop what a full orbit did not.
	]]
	local arc = opts.arc
	local base = handle.t

	local function place()
		local dir = CFrame.Angles(0, handle.t, 0) * TURN_DIR
		camera.CFrame = CFrame.lookAt(centre + dir * dist, centre)
	end
	place()

	function handle:Start()
		if self.conn then
			return
		end
		self.conn = RunService.RenderStepped:Connect(function(dt)
			if arc then
				self.phase = (self.phase or 0) + dt * speed
				self.t = base + math.sin(self.phase) * arc
			else
				self.t += dt * speed
			end
			place()
		end)
	end

	function handle:Stop()
		if self.conn then
			self.conn:Disconnect()
			self.conn = nil
		end
	end

	function handle:Destroy()
		self:Stop()
		vpf:Destroy()
	end

	return handle
end

--------------------------------------------------------------------------
-- A STAT BAR
--------------------------------------------------------------------------
--[[
	LABEL [========------] VALUE, on one line.

	A number on its own says nothing without the others to hold it against --
	"SPEED 46" is only fast or slow once you have seen 80. The bar carries the
	comparison and the number carries the fact, so a player reads the ladder at a
	glance and still gets the exact figure.

	The track is recessed and the fill is the panel's own tint, outlined like
	everything else, so it belongs to the same set of parts as the buttons.

	Returns a handle with :Set(value, max, text).
]]
function PanelKit.statBar(parent: GuiObject, label: string, tint: Color3, w: number, y: number)
	local LABEL_W, VALUE_W, H = 44, 40, 20

	local rowHolder = Instance.new("Frame")
	rowHolder.Name = label
	rowHolder.Position = UDim2.fromOffset(0, y)
	rowHolder.Size = UDim2.fromOffset(w, H)
	rowHolder.BackgroundTransparency = 1
	rowHolder.Parent = parent

	local name = text(rowHolder, label, 11, Enum.Font.GothamBold, C.ink)
	name.Position = UDim2.fromOffset(0, 0)
	name.Size = UDim2.fromOffset(LABEL_W, H)
	name.TextXAlignment = Enum.TextXAlignment.Left

	local trackW = w - LABEL_W - VALUE_W - 8
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.fromOffset(LABEL_W, H * 0.5)
	track.Size = UDim2.fromOffset(trackW, 12)
	track.BackgroundColor3 = C.sandDeep
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.Parent = rowHolder
	corner(track, 6)
	outline(track, 2)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = tint
	fill.BorderSizePixel = 0
	fill.Parent = track
	corner(fill, 6)
	grad(fill, tint:Lerp(C.white, 0.32), darken(tint, 0.16))

	local value = text(rowHolder, "", 12, Enum.Font.GothamBold, C.seaDark)
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.new(1, 0, 0, 0)
	value.Size = UDim2.fromOffset(VALUE_W, H)
	value.TextXAlignment = Enum.TextXAlignment.Right

	local handle = { frame = rowHolder, fill = fill, value = value }
	function handle:Set(v: number, max: number, str: string?)
		-- Floored at a sliver rather than zero: an empty track reads as a broken
		-- bar, where a stub reads as "the bottom of the ladder".
		local f = (max > 0) and math.clamp(v / max, 0, 1) or 0
		fill.Size = UDim2.fromScale(math.max(f, 0.06), 1)
		value.Text = str or tostring(v)
	end
	return handle
end

-- The tray a turntable sits in: a recessed plinth, so a model reads as being ON
-- something rather than floating on the card.
function PanelKit.plinth(parent: GuiObject, tint: Color3, r: number?)
	r = r or 16
	local tray = Instance.new("Frame")
	tray.Name = "Plinth"
	tray.BackgroundColor3 = tint
	tray.BorderSizePixel = 0
	tray.ClipsDescendants = true
	tray.Parent = parent
	corner(tray, r)
	outline(tray, 3.5)
	grad(tray, tint:Lerp(C.white, 0.34), darken(tint, 0.22))
	return tray
end

-- The Beach Shop's stock row, which is the shape every list in the game uses:
-- a white-to-sand plate with a tinted icon tile on the left.
function PanelKit.row(parent: GuiObject, height: number, order: number?)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, height)
	row.BackgroundColor3 = C.white
	row.BorderSizePixel = 0
	row.LayoutOrder = order or 1
	row.Parent = parent
	corner(row, 18)
	outline(row, 3.5)
	grad(row, C.white, C.sand)
	return row
end

function PanelKit.tile(row: GuiObject, px: number, x: number, y: number, tint: Color3)
	local tile = Instance.new("Frame")
	tile.Size = UDim2.fromOffset(px, px)
	tile.Position = UDim2.fromOffset(x, y)
	tile.BackgroundColor3 = tint
	tile.BorderSizePixel = 0
	tile.Parent = row
	corner(tile, 16)
	outline(tile, 3.5)
	grad(tile, tint:Lerp(C.white, 0.3), darken(tint, 0.2))
	gloss(tile, 16)
	return tile
end

--------------------------------------------------------------------------
-- NUMBERS
--------------------------------------------------------------------------

--[[
	SHORT FORM, for the places where a number has to share a line with another
	number. Comma grouping is right for a price standing on its own -- it is
	exact and the player is deciding whether to spend -- and wrong for
	"348,291 / 1,000,000", which is twenty-one characters of progress caption
	nobody reads digit by digit.

	Trailing ".0" is dropped, so a round million is "1M" rather than "1.0M", and
	anything under a thousand comes back untouched: most quests count to single
	figures and "2 / 2" must not become "2.0 / 2.0".

	THE THRESHOLD IS NOT THE UNIT. Each rung claims from 999.5 of the rung below
	rather than from its own value, and that is a rounding fix rather than a
	fudge: 999,999 is over the K threshold, divides to 999.999, prints as "1000"
	and comes out "1000K" -- which is not a number anybody writes. Handing it to
	the M rung instead gives "1M".

	IT WAS A LOCAL IN MenuHud until the idle shore needed it too. The AFK card
	quotes a coins-per-SECOND rate, and once that rate scales with the run
	(AfkConfig.TideGrowth) it reaches six figures -- four characters more than
	its line can carry. Two copies of a rounding rule is how two screens end up
	disagreeing about what 999,999 is called, so it moved here rather than being
	copied; MenuHud's compactNum is a one-line call to this now.
]]
--[[
	T WAS ADDED 2026-09-10, and it is a headroom fix rather than a nicety. The
	top rung used to be B, which meant the first player to pass 999.5 billion got
	"1000B" -- the exact defect the note above says the 999.5 thresholds exist to
	prevent, just one rung further up. It is reachable: a live player was measured
	at 13.6B lifetime earned with the sell multiplier still climbing toward x268.

	STOPS AT T ON PURPOSE. The rungs past it (Qa, Qi) are notation a player has to
	be taught rather than read, and nothing in this economy is priced anywhere
	near them -- the last rebirth gate is 2.04B. If the game ever does reach a
	quadrillion the honest answer is a different notation, not another letter.
]]
--[[
	THE THRESHOLDS ARE EXACT NOW, AND THAT IS THE ROUNDING FIX BELOW SHOWING
	THROUGH -- changed 2026-09-17.

	They used to be 999.5, one rung down from the unit they promote to, and the
	notes above explain why: the printer ROUNDED, so 999,999 divided to 999.999,
	printed "1000" and came out "1000K". Promoting anything from 999.5 up to the
	next rung hid that.

	The printer truncates now, so it can no longer reach 1000 at all -- 999,999
	floors to "999K" on its own. The old thresholds would have become a bug in
	the opposite direction: 999,500 would take the M rung and truncate to "0.9M",
	which is both wrong and smaller than the "999K" it replaced.
]]
local COMPACT_UNITS = {
	{ at = 1e12, per = 1e12, suffix = "T" },
	{ at = 1e9,  per = 1e9,  suffix = "B" },
	{ at = 1e6,  per = 1e6,  suffix = "M" },
	{ at = 1e3,  per = 1e3,  suffix = "K" },
}

--[[
	TRUNCATED, NEVER ROUNDED, BECAUSE THIS PRINTS MONEY THE PLAYER HAS.

	Reported 2026-09-15: "the hud says i have 15k coins but when i go buy the 15k
	egg it says in reality i only have 14.500 or so, so the hud is on te wrong".
	They were right and the HUD was wrong. `%.0f` rounds to nearest, so 14,600
	printed "15K" -- and the shop, which spends `comma()` and is exact, then
	refused a 15,000 purchase the counter had just promised.

	ROUNDING UP A BALANCE IS THE ONE DIRECTION THAT CANNOT BE ALLOWED. Rounding
	down understates what you have, which costs a player nothing and is corrected
	the moment they open the shop; rounding up tells them they can afford
	something they cannot. Truncation is also what every other running total in
	this game already does implicitly -- coins are integers everywhere else.

	The DECIMAL rule is unchanged: one below ten (1.2M), none above it (28M),
	three significant figures being as much as the slot can carry.

	INTEGER MATH RATHER THAN n / u.per, and it is not pedantry. 2,900,000 / 1e6
	is 2.8999999999999999 in a double, so flooring the tenth off the quotient
	prints "2.8M" for a number that is exactly 2.9M. Taking the whole and the
	tenth off the integer and its remainder cannot drift.
]]
function PanelKit.compact(n: number): string
	n = math.floor(tonumber(n) or 0)
	for _, u in ipairs(COMPACT_UNITS) do
		if n >= u.at then
			local whole = math.floor(n / u.per)
			local tenths = math.floor((n % u.per) * 10 / u.per)
			local s = (whole < 10) and string.format("%d.%d", whole, tenths)
				or string.format("%d", whole)
			return (s:gsub("%.0$", "")) .. u.suffix
		end
	end
	return tostring(n)
end

return PanelKit
