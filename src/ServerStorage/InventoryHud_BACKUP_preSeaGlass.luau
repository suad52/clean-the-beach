--[[
	InventoryHud  --  StarterPlayerScripts.InventoryHud

	The carried-storage view. Renders straight off
	InventoryController.Client.Changed, which is fed by exactly the same
	InventorySync flush that repaints the pellets inside the roller drum -- so
	"5 / 12" on screen and five lit pellets in the roller are the same fact
	rendered twice, never two counters that have to be kept in step.

	Value display is not a UI choice. A record arrives with `value = nil` unless
	the server has rolled it, so "???" is what an unrolled item genuinely is.
	There is nothing to peek at in the client's memory.

	THE LOOK IS PANELKIT'S, NOT ITS OWN
	-----------------------------------
	This was the last flat slate surface in the game: a translucent near-black
	rectangle with Gotham chips in it, sitting three inches from a rail of
	chunky outlined toy buttons. It is a PanelKit card now -- wood slab, sand
	face, an overhanging tinted signboard -- and its rows are `PanelKit.row`,
	the same white-to-sand plate the Beach Shop's stock list is built from.
	Nothing here invents a colour; every one comes out of PanelKit.C, which is
	most of what makes two separately-written screens read as one game.

	THE THUMBNAIL IS THE REAL MODEL, AND ONLY WHEN IT IS ALLOWED TO BE
	-----------------------------------------------------------------
	A cleaned record carries an itemId, so its row draws the actual art through
	ItemVisuals.buildClean -- the same model the reveal card and the Index show,
	which is the one-art-source rule this codebase has already paid for three
	times. A CRUSTED record does not carry one: the server has not told this
	client what is inside, and there is nothing here to look up. Those rows get
	the generic lump glyph, so the panel cannot leak a reveal even by accident.
	Templates are cached per id and cloned, so twenty cans cost one build.

	IT IS A DROPDOWN, AND IT STARTS SHUT
	------------------------------------
	Open, this card runs from under the raked pill down to the menu rail's
	bottom edge on the far side of the screen -- a 248-wide column down most of
	the left of the display, held there all session for a readout a player
	glances at twice a minute. Shut, it is the signboard and the load track:
	how many things and how heavy, in 82px, in line with the coin and beach
	pills above it. The list is one click away instead of always underfoot.

	The whole of what is visible when it is shut is the handle -- banner and
	track both -- and the chevron on the right is the only part that exists
	purely to say so. Shut also switches the list off, and a ViewportFrame under
	a hidden frame is not rendered, so the card stops DRAWING twenty item
	thumbnails nobody is looking at. It still builds them; see setOpen.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local ItemConfig = require(Modules:WaitForChild("ItemConfig"))
local ItemVisuals = require(Modules:WaitForChild("ItemVisuals"))
local InventoryController = require(Modules:WaitForChild("InventoryController"))
local PanelKit = require(Modules:WaitForChild("PanelKit"))
local UiFit = require(Modules:WaitForChild("UiFit"))

local C = PanelKit.C
local corner = PanelKit.corner
local outline = PanelKit.outline
local grad = PanelKit.grad
local punch = PanelKit.punch
local darken = PanelKit.darken

local player = Players.LocalPlayer

local InventoryHud = {}

-- SIZED TO ITS CONTENTS, NOT TO THE CATALOGUE.
--
-- This was 312x408 FIXED, which is a quarter of a phone screen held open for a
-- bag with one can in it: the blank cream slab under the list was the single
-- largest object on the HUD for most of a session, and the card ran from under
-- the raked pill down past mid-screen whatever it was holding. Every metric
-- here came down a notch, and the card's HEIGHT is now computed from how many
-- rows there actually are (see fit) rather than taking every pixel offered.
--
-- 248 is a floor, not a round number. A row still has to hold the longest
-- display name in the catalogue ("Message in a Bottle", ~132px at GothamBold
-- 13) beside a 34px art tile, and on the line below the longest state string
-- ("ON SCREEN  42%", ~86px at GothamBold 11) clear of the widest price
-- ("$40000", ~54px at LuckiestGuy 15).
local PANEL_W = 248
local ROW_H = 46
local ROW_GAP = 6
local TILE = 34
local HEAD_H = 34          -- the load track plus its gap, above the list
local TRACK_H = HEAD_H - 8 -- the track alone, with nothing under it to clear
local LIST_PAD = 8         -- breathing room under the last row

-- WHERE THE LIST STARTS SCROLLING INSTEAD OF THE CARD GROWING.
--
-- This used to be a flat four rows, which is a readout on a phone and a third of
-- the room going spare on anything taller. It comes off the screen now: fit()
-- grows the card until its bottom edge is level with the MENU RAIL on the other
-- side of the HUD -- the lowest thing on it -- and only then scrolls. This is
-- the floor under that, for a viewport short enough to have no room at all.
--
-- Nothing is hidden either way: the load track above the list already carries
-- the total, and the list scrolls for the detail.
local MIN_ROWS = 3

-- What the body owes the card around it. PanelKit.card's own defaults are 56
-- above and 18 below, sized for its full-height signboard; build() trims the
-- board and moves the body up to match.
local BODY_TOP, BODY_BOTTOM = 40, 16

-- The one line an empty sack gets, replacing a drawn sack plus a heading plus
-- a hint -- three objects that between them said "nothing here".
local EMPTY_H = 28

-- SHUT. The track plus the card's own padding, and that is the whole panel.
-- TRACK_H rather than HEAD_H because HEAD_H's 8px is clearance for a list that
-- is not being drawn. Unlike the open height this does not consult the screen:
-- 82px fits anywhere the card fits at all.
local COLLAPSED_H = TRACK_H + BODY_TOP + BODY_BOTTOM

-- TOP-ANCHORED, NOT CENTRED, AND HEIGHT-CAPPED.
--
-- The old panel was pinned to 0.5 of screen height at a fixed 372 tall, which
-- is fine at 1080 and runs straight through CTB_HUD's BEACH RAKED pill on a
-- short viewport. Anchoring the top instead makes the left edge read as one
-- stack -- coins, beach progress, carrying. These two are a CEILING now rather
-- than a target: fit() asks the contents first, and only falls back to the room
-- between that pill and the hint line when the list is long enough to want it.
local TOP_Y = 152          -- clears the raked pill, which ends at 126
local FOOT = 128           -- the hint line (36 tall, 76 off the bottom) plus air

-- BOTH bay states are listed. Which one a mounted lump carries is a ServerMain
-- decision -- WashServer writes "Washing", SiftServer writes "Sifting" -- and a
-- missing key here falls through to the raw state string, so the chip for the
-- item actually on the stand read a bare "Washing" in Crusted brown.
-- Shortened from "ON THE STAND" / "ON THE SCREEN". The row's second line also
-- carries a percentage, and the two together have to fit beside the price.
local STATE_LABEL = {
	Crusted = "CRUSTED",
	Washing = "ON STAND",
	Sifting = "ON SCREEN",
	Cleaned = "READY",
}

-- Re-mixed for a CREAM plate. The old set was chosen against a near-black
-- panel: (140,235,170) mint and (96,190,220) ice both disappear on sand, which
-- is the sort of thing that only shows up after the background changes.
local STATE_COLOR = {
	Crusted = Color3.fromRGB(150, 100, 44),
	Washing = Color3.fromRGB(26, 128, 174),
	Sifting = Color3.fromRGB(178, 124, 20),
	Cleaned = Color3.fromRGB(40, 152, 84),
}

local VALUE_READY   = Color3.fromRGB(34, 146, 78)
local VALUE_UNKNOWN = Color3.fromRGB(150, 118, 84)

local gui, root, slab, body, list, empty
local track, trackFill, trackText
local bannerText, chevron
local chips = {}           -- uid -> row Frame

-- Shut on arrival, and it stays that way until it is asked. A player who wants
-- the itemised list opens it; a player who does not never has the column.
local open = false
local sizeTween: Tween?

--------------------------------------------------------------------------
-- ITEM ART
--------------------------------------------------------------------------

-- One build per item id, cloned per row. A bag of twenty cans is one
-- buildClean, and the template never enters the DataModel.
local artCache = {}
local function template(itemId: string): Model?
	local cached = artCache[itemId]
	if cached == nil then
		local ok, model = pcall(ItemVisuals.buildClean, itemId)
		cached = (ok and model) or false
		artCache[itemId] = cached
	end
	return cached and cached:Clone() or nil
end

-- Up-front-side, the same angle the Index's cards use: straight down +Z turns
-- the flat items (Phone, Glasses, Wallet) into slivers.
local THUMB_DIR = Vector3.new(0.5, 0.42, 1).Unit

local function thumbnail(tile: GuiObject, itemId: string): boolean
	local model = template(itemId)
	if not model then
		return false
	end

	local vpf = Instance.new("ViewportFrame")
	vpf.Name = "Art"
	vpf.Size = UDim2.fromScale(1, 1)
	vpf.BackgroundTransparency = 1
	-- Bright. A 42px tile is small enough that a realistically-lit prop just
	-- reads as a dark smudge; these want to look like catalogue art.
	vpf.Ambient = Color3.fromRGB(226, 220, 208)
	vpf.LightColor = Color3.fromRGB(255, 252, 244)
	vpf.LightDirection = Vector3.new(-0.35, -1, -0.5)
	-- ABOVE the tile's gloss cap (ZIndex 2), not under it. The viewport's own
	-- background is transparent, so the gloss still reads everywhere the model
	-- is not -- the item ends up looking like it is sitting behind glass rather
	-- than fogged by it.
	vpf.ZIndex = 3
	vpf.Parent = tile

	-- A WorldModel, not a bare parent: without one a ViewportFrame does no
	-- lighting pass and every part comes out flat and muddy.
	local world = Instance.new("WorldModel")
	world.Parent = vpf
	model.Parent = world

	local cam = Instance.new("Camera")
	cam.FieldOfView = 42
	cam.Parent = vpf
	vpf.CurrentCamera = cam

	-- The tile is square, so tanH = tanV and one solve frames both axes.
	-- Framed by the BOX, not the bounding sphere. A sphere fit is the radius of
	-- the longest diagonal, so a straw or a phone -- long on one axis, thin on
	-- the other two -- gets pushed back far enough to fit a cube it does not
	-- fill, and lands in the tile as a speck. The tile is square, so tanH = tanV
	-- and one solve covers both axes.
	local cf, size = model:GetBoundingBox()
	local tanV = math.tan(math.rad(cam.FieldOfView * 0.5))
	local halfH = size.Y * 0.5 + math.max(size.X, size.Z) * 0.12
	local halfW = math.max(size.X, size.Z) * 0.5
	local dist = math.max(halfH, halfW) / tanV * 1.12
	cam.CFrame = CFrame.lookAt(cf.Position + THUMB_DIR * dist, cf.Position)
	return true
end

-- What a row draws when it is NOT allowed to know what it is holding.
local function lumpGlyph(tile: GuiObject)
	local holder = Instance.new("Frame")
	holder.Name = "Art"
	holder.Size = UDim2.fromScale(1, 1)
	holder.BackgroundTransparency = 1
	holder.ZIndex = 3
	holder.Parent = tile

	local rock = Instance.new("Frame")
	rock.Size = UDim2.fromScale(0.72, 0.66)
	rock.Position = UDim2.fromScale(0.14, 0.2)
	rock.BackgroundColor3 = Color3.fromRGB(138, 116, 86)
	rock.BorderSizePixel = 0
	rock.ZIndex = 3
	rock.Parent = holder
	corner(rock, 12)
	outline(rock, 2.5)
	grad(rock, Color3.fromRGB(178, 154, 118), Color3.fromRGB(104, 86, 64))

	-- Three clumps, so it reads as crusted rather than as a brown pebble.
	for i, spot in { Vector2.new(0.1, 0.06), Vector2.new(0.52, -0.04), Vector2.new(0.3, 0.5) } do
		local clump = Instance.new("Frame")
		clump.Size = UDim2.fromScale(0.34 - i * 0.04, 0.34 - i * 0.04)
		clump.Position = UDim2.fromScale(spot.X, spot.Y)
		clump.BackgroundColor3 = Color3.fromRGB(118, 98, 74)
		clump.BorderSizePixel = 0
		clump.ZIndex = 4
		clump.Parent = rock
		corner(clump, 8)
		outline(clump, 2)
	end
end

-- Swapped only when the answer changes: a row repaints on every sync, and
-- rebuilding a ViewportFrame sixty times a second would be a real cost for a
-- picture that has not moved.
local function setArt(tile: GuiObject, itemId: string?)
	local wanted = itemId or "__lump"
	if tile:GetAttribute("ArtId") == wanted then
		return
	end
	tile:SetAttribute("ArtId", wanted)

	local old = tile:FindFirstChild("Art")
	if old then
		old:Destroy()
	end
	if not (itemId and thumbnail(tile, itemId)) then
		lumpGlyph(tile)
	end
end

--------------------------------------------------------------------------
-- BUILD
--------------------------------------------------------------------------

--[[
	HOW TALL THE CARD IS -- a question about the CONTENTS first and the screen
	second, which is the whole of this change.

	Asked in that order: what does the list actually need, capped at MAX_ROWS;
	then how much room is there between CTB_HUD's raked pill and its hint line.
	The smaller of the two wins. A one-item bag therefore draws a one-item card
	however big the monitor is -- where the old version took every pixel it was
	offered and filled the difference with blank sand.

	body/list/empty are all sized in SCALE off the card, so they follow on their
	own; only the card, its shadow slab and the root have to be told.
]]
local rowCount = 0

--[[
	THE LOWEST THING ON THE HUD, which is the line this card grows down to.

	Read off the rail itself rather than recomputed from MenuHud's constants, so
	a sixth rail button moves this too.

	BeachMenuHud has IgnoreGuiInset TRUE and this ScreenGui has it FALSE, so the
	two measure y from different origins and their AbsolutePositions cannot be
	subtracted from each other raw -- the difference is the topbar, which is
	exactly the gap between the two guis' heights. It is worth 58px, and it is
	the same currency error the note inside fit() is about.

	Nil until MenuHud has built the rail. ClientMain starts this module BEFORE
	MenuHud, so that is the state on the first few frames of every session, and
	fit() falls back to the hint line until the retry below catches it.
]]
local function railBottom(): number?
	local pg = player:FindFirstChild("PlayerGui")
	local menu = pg and pg:FindFirstChild("BeachMenuHud")
	local rail = menu and menu:FindFirstChild("Rail", true)
	if not (rail and rail:IsA("GuiObject") and rail.AbsoluteSize.Y > 0) then
		return nil
	end
	local inset = menu.AbsoluteSize.Y - gui.AbsoluteSize.Y
	local scale = UiFit.get()
	return (rail.AbsolutePosition.Y + rail.AbsoluteSize.Y - inset) / (scale > 0 and scale or 1)
end

--[[
	THE THREE SURFACES THE CARD'S HEIGHT LIVES ON -- the root, the sand card and
	the shadow slab under it -- moved as one. Leave any of them behind and the
	card grows off its own shadow.

	TWO EASES, AND THAT IS NOT AN OVERSIGHT. Back overshoots, which is the house
	style and exactly right on the way OPEN: the card springs past its target
	into empty room and settles. On the way SHUT the same overshoot takes it
	BELOW the final height -- 318px of travel undershoots to about 50 against a
	target of 82 -- and `body` is sized in SCALE off the card, so for three
	frames the load track is left hanging out of the bottom edge. Closing gets
	Quart, which only ever approaches from above.
]]
local function applyHeight(h: number, animate: boolean?)
	local target = UDim2.fromOffset(PANEL_W, h)
	local from = root.Size.Y.Offset
	if sizeTween then
		sizeTween:Cancel()
		sizeTween = nil
	end

	-- Snapped when there is nowhere to travel: render() calls fit() on every
	-- sync, and while the card is shut every one of those lands on COLLAPSED_H.
	if not animate or from == h then
		root.Size = target
		root.Card.Size = target
		if slab then
			slab.Size = target
		end
		return
	end

	local info = (h > from)
		and TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		or TweenInfo.new(0.2, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

	sizeTween = TweenService:Create(root, info, { Size = target })
	sizeTween:Play()
	TweenService:Create(root.Card, info, { Size = target }):Play()
	if slab then
		TweenService:Create(slab, info, { Size = target }):Play()
	end
end

local function fit(animate: boolean?)
	if not root then
		return
	end
	--[[
		AbsoluteSize is REAL pixels. TOP_Y, FOOT and the row metrics are AUTHORED
		units, which UiFit scales on the way to the screen. Subtracting one from
		the other is a currency error, and it only became visible once the UI
		started scaling: on a 374px phone it worked out as 316 - 152 - 128 = 36,
		slammed into the clamp floor, and the card sat at its minimum with its own
		contents hanging out of the bottom. Converting the measurement into
		authored units first asks the right question -- how much room is there in
		the units this card is drawn in -- and gets 247 rather than 36.
	--]]
	local scale = UiFit.get()
	local roomY = gui.AbsoluteSize.Y / (scale > 0 and scale or 1)

	-- The floor is the empty card, not a fixed 240: a viewport short enough to
	-- push the ceiling below that has nowhere better to put the difference, and
	-- a load track with no number on it is worse than a card that overlaps.
	local floorH = HEAD_H + EMPTY_H + BODY_TOP + BODY_BOTTOM
	-- Down to the rail's bottom edge; back to the hint line only while the rail
	-- does not exist yet.
	local ceiling = math.max((railBottom() or (roomY - FOOT)) - TOP_Y, floorH)

	-- HOW MANY ROWS THAT IS. Derived rather than fixed, so the card uses the room
	-- the screen actually has before handing the rest to a scrollbar.
	local maxRows = math.max(MIN_ROWS, math.floor(
		(ceiling - BODY_TOP - BODY_BOTTOM - HEAD_H - LIST_PAD + ROW_GAP) / (ROW_H + ROW_GAP)))

	local shown = math.clamp(rowCount, 0, maxRows)
	local contentH
	if shown == 0 then
		contentH = HEAD_H + EMPTY_H
	else
		contentH = HEAD_H + shown * ROW_H + (shown - 1) * ROW_GAP + LIST_PAD
	end

	local h = math.floor(math.min(contentH + BODY_TOP + BODY_BOTTOM, ceiling))

	-- Everything above is the OPEN height. Shut, the arithmetic still runs --
	-- maxRows and the scrollbar test below both want it -- but the card itself
	-- is one constant.
	if not open then
		h = COLLAPSED_H
	end

	applyHeight(h, animate)

	-- THE BAR ONLY EXISTS WHEN THERE IS SOMETHING BELOW THE FOLD.
	--
	-- A ScrollingFrame draws its bar whenever the canvas is even a pixel over
	-- the window, and the row's 3.5px border stroke is enough to push it there:
	-- a card holding ONE item came up with a scrollbar down the side of it,
	-- which is exactly the sort of decoration-for-nothing this pass is removing.
	-- Answered from the authored numbers rather than AbsoluteCanvasSize, which
	-- is a frame behind the layout that produced it.
	if list then
		local canvasH = (rowCount > 0)
			and (rowCount * ROW_H + (rowCount - 1) * ROW_GAP + LIST_PAD)
			or 0
		local windowH = h - BODY_TOP - BODY_BOTTOM - HEAD_H
		list.ScrollBarThickness = (open and canvasH > windowH + 1) and 4 or 0
	end
end

--------------------------------------------------------------------------
-- OPEN / SHUT
--------------------------------------------------------------------------

--[[
	Visible = false on the list is the POINT of the shut state, not tidying up
	after it. Every row carries a ViewportFrame with a real model in it, and a
	ViewportFrame under a hidden frame is not rendered -- so shut is not merely
	small, it is free.

	The rows themselves stay BUILT. render() keeps them in step whether the card
	is open or not, which costs a few property writes per sync; the alternative
	is rebuilding twenty thumbnails every time the card is opened.
]]
local function setOpen(v: boolean)
	if open == v or not root then
		return
	end
	open = v

	list.Visible = open
	empty.Visible = open and rowCount == 0

	TweenService:Create(chevron, TweenInfo.new(0.24, Enum.EasingStyle.Back,
		Enum.EasingDirection.Out), { Rotation = open and 180 or 0 }):Play()

	fit(true)
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "InventoryHud"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 6
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local closeFace, banner
	root, body, closeFace, banner = PanelKit.card(gui, "CARRYING", PANEL_W,
		HEAD_H + EMPTY_H + BODY_TOP + BODY_BOTTOM, C.foam)
	-- A HUD readout is not a window. The X arrives with the shell, so it is
	-- removed rather than left sitting there doing nothing.
	closeFace.Parent:Destroy()
	root.Name = "Panel"
	root.AnchorPoint = Vector2.new(0, 0)
	-- 30, not the old 34: the trimmed signboard below overhangs the card by 13px
	-- a side rather than PanelKit's 17, and this keeps its left edge on the same
	-- line as the coin pill's above it.
	-- 29, not 30: the signboard overhangs the card by 13 a side, so this is what
	-- puts its left edge on x = 16 -- the same x CTB_HUD's coin and raked pills
	-- start at. The three of them are one column and they have to line up.
	root.Position = UDim2.fromOffset(29, TOP_Y)

	--[[
		THE SIGNBOARD, TRIMMED.

		PanelKit draws a 62-tall board with 30pt lettering on it, which is right
		for a modal you opened on purpose and far too loud for a readout that is
		on screen the entire session -- the word CARRYING was the largest text in
		the game, bigger than the coin count. Trimmed HERE rather than in
		PanelKit: every other panel using that shell is a modal and wants the
		full-size board, and this file must not change how they look.

		The gloss cap is sized in SCALE, so it follows on its own; only the label
		and its outline are authored in points.
	]]
	banner.Position = UDim2.new(0.5, 0, 0, -14)
	banner.Size = UDim2.fromOffset(PANEL_W + 26, 42)
	for _, child in banner:GetChildren() do
		if child:IsA("TextLabel") then
			bannerText = child
			child.TextSize = 20
			-- Inset by the chevron's width on the right and by the same again on
			-- the left, so the title stays centred in the room that is left
			-- rather than sliding under the button.
			child.Size = UDim2.new(1, -88, 1, 0)
			child.Position = UDim2.fromOffset(44, 0)
			local st = child:FindFirstChildOfClass("UIStroke")
			if st then
				st.Thickness = 2.5
			end
		end
	end

	----------------------------------------------------------------
	-- THE HANDLE
	--
	-- The whole banner is the button, and so is the track below it: between
	-- them they ARE the card when it is shut, and a shut dropdown whose only
	-- handle is a 32px corner is a dropdown nobody finds.
	--
	-- The chevron is drawn from two bars rather than set as a "down triangle"
	-- glyph, for the reason every other icon in this game is drawn: a glyph is
	-- at the mercy of whatever the player's device ships, and half of them ship
	-- that one as an emoji.
	----------------------------------------------------------------
	-- 0, not PanelKit.card's -3. That nudge is measured against a 62-tall board
	-- with a 46px X on it, where there is room to sit the face high and let its
	-- shadow slab show below. This board is trimmed to 42 and chunky's holder is
	-- 39 of it, so the same -3 hangs 2px of button out over the top edge -- and
	-- the banner does not clip.
	local chevHolder, chevFace = PanelKit.chunky(banner, 32, 32, C.foamDark, 11)
	chevHolder.AnchorPoint = Vector2.new(1, 0.5)
	chevHolder.Position = UDim2.new(1, -12, 0.5, 0)
	chevHolder.ZIndex = 9

	chevron = Instance.new("Frame")
	chevron.Name = "Chevron"
	chevron.AnchorPoint = Vector2.new(0.5, 0.5)
	chevron.Position = UDim2.fromScale(0.5, 0.5)
	chevron.Size = UDim2.fromOffset(20, 20)
	chevron.BackgroundTransparency = 1
	chevron.ZIndex = 9
	chevron.Parent = chevFace
	-- -1 is the left arm and +1 the right. Rotation runs CLOCKWISE, so the left
	-- arm has to tip its far end DOWN (+42) and the right arm tip its far end UP
	-- (-42) to meet in the middle. That is a V; setOpen spins the container 180
	-- and it is a caret.
	for _, arm in { -1, 1 } do
		local bar = Instance.new("Frame")
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Size = UDim2.fromOffset(13, 4)
		-- y 10, not 9: a V is not symmetric about its bars' CENTRES -- the two tips
		-- reach further from them than the apex does. At 42 degrees this puts the
		-- ink between y 4.2 and 15.8 of the 20px box, dead centre; centring the bars
		-- instead leaves the whole glyph sitting a pixel high in the button.
		bar.Position = UDim2.fromOffset(10 + arm * 4, 10)
		bar.Rotation = arm * -42
		bar.BackgroundColor3 = C.white
		bar.BorderSizePixel = 0
		bar.ZIndex = 9
		bar.Parent = chevron
		corner(bar, 2)
		outline(bar, 2)
	end
	chevFace.MouseButton1Click:Connect(function()
		setOpen(not open)
	end)

	local grab = Instance.new("TextButton")
	grab.Name = "Handle"
	grab.Size = UDim2.fromScale(1, 1)
	grab.BackgroundTransparency = 1
	grab.Text = ""
	grab.AutoButtonColor = false
	-- Over the title (6) and under the chevron (9), so the thing that LOOKS
	-- pressable is the thing that takes the press.
	grab.ZIndex = 8
	grab.Parent = banner
	grab.MouseButton1Click:Connect(function()
		setOpen(not open)
	end)

	-- And close the gap the full-size board used to leave under it. PanelKit's
	-- own inset (18/56/18) is measured against the 62-tall banner.
	body.Position = UDim2.fromOffset(14, BODY_TOP)
	body.Size = UDim2.new(1, -28, 1, -(BODY_TOP + BODY_BOTTOM))

	-- The shadow slab PanelKit.card builds but does not hand back. Named so
	-- fit() can resize it with the card -- leave it behind and the card grows
	-- off its own shadow.
	for _, child in root:GetChildren() do
		if child:IsA("Frame") and child.Name == "Frame" then
			child.Name = "Slab"
			slab = child
			break
		end
	end

	----------------------------------------------------------------
	-- THE LOAD TRACK
	--
	-- A recessed sand channel that fills with sea. The number lives ON the
	-- bar rather than above it, because the banner already says what the
	-- panel is and a second heading would just be the word CARRYING twice.
	----------------------------------------------------------------
	track = Instance.new("Frame")
	track.Name = "Track"
	track.Size = UDim2.new(1, 0, 0, TRACK_H)
	track.BackgroundColor3 = C.sandDeep
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.Parent = body
	corner(track, 13)
	outline(track, 3)

	trackFill = Instance.new("Frame")
	trackFill.Name = "Fill"
	trackFill.Size = UDim2.fromScale(0, 1)
	trackFill.BackgroundColor3 = C.sea
	trackFill.BorderSizePixel = 0
	trackFill.Parent = track
	corner(trackFill, 13)
	-- Created here only so retint() has a gradient to find; render owns the
	-- colour from now on.
	grad(trackFill, C.sea:Lerp(C.white, 0.25), darken(C.sea, 0.18))

	trackText = PanelKit.text(track, "0 / 20 LBS", 14, Enum.Font.LuckiestGuy, C.white)
	trackText.Size = UDim2.fromScale(1, 1)
	trackText.ZIndex = 4
	punch(trackText, 2.5)

	-- The other half of the handle. Shut, the track is half of what is on the
	-- screen, and making the player hit the banner instead would be arbitrary.
	local trackGrab = Instance.new("TextButton")
	trackGrab.Name = "Handle"
	trackGrab.Size = UDim2.fromScale(1, 1)
	trackGrab.BackgroundTransparency = 1
	trackGrab.Text = ""
	trackGrab.AutoButtonColor = false
	trackGrab.ZIndex = 6
	trackGrab.Parent = track
	trackGrab.MouseButton1Click:Connect(function()
		setOpen(not open)
	end)

	----------------------------------------------------------------
	-- THE LIST
	----------------------------------------------------------------
	list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.Position = UDim2.fromOffset(0, HEAD_H)
	list.Size = UDim2.new(1, 0, 1, -HEAD_H)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 4
	list.ScrollBarImageColor3 = C.woodDark
	list.ScrollBarImageTransparency = 0.25
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.Parent = body

	-- The last row otherwise sits flush against the card's inner edge and gets
	-- sliced by the scroll clip mid-letter.
	local pad = Instance.new("UIPadding")
	pad.PaddingBottom = UDim.new(0, LIST_PAD)
	pad.Parent = list

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, ROW_GAP)
	-- Explicit LayoutOrder sorting. The default (Name) would order the rows
	-- alphabetically by uid, which is nearly-but-not-quite insertion order and
	-- makes items appear to jump around as you collect.
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	----------------------------------------------------------------
	-- EMPTY STATE
	--
	-- One line, and the card shrinks around it.
	--
	-- This was a drawn sack with a heading and a hint under it, held open at
	-- the card's full height: roughly 230x300 of nothing, which made it the
	-- single largest object on the screen for a player who had not picked
	-- anything up yet -- i.e. every new player, for their first minute. Three
	-- objects saying "nothing here" is two more than the fact is worth.
	----------------------------------------------------------------
	empty = Instance.new("Frame")
	empty.Name = "Empty"
	empty.BackgroundTransparency = 1
	empty.Position = UDim2.fromOffset(0, HEAD_H)
	empty.Size = UDim2.new(1, 0, 1, -HEAD_H)
	empty.Parent = body

	local none = PanelKit.text(empty, "SACK EMPTY", 15, Enum.Font.LuckiestGuy,
		darken(C.sandDeep, 0.34))
	none.Size = UDim2.new(1, 0, 0, EMPTY_H)

	-- Shut, so neither of these is drawn until the handle is pulled.
	list.Visible = false
	empty.Visible = false

	fit()
	-- Both WRAPPED rather than connected raw. fit's first argument is `animate`
	-- now, and UiFit.onChanged hands its listener the SCALE -- a number, and
	-- every number is truthy, so a raw connection would tween the card open on
	-- every resize.
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		fit()
	end)
	-- A scale change moves the goalposts as much as a resize does, and the
	-- ScreenGui's AbsoluteSize does not necessarily change with it.
	UiFit.onChanged(function()
		fit()
	end)
end

--------------------------------------------------------------------------
-- ROWS
--------------------------------------------------------------------------

local function makeChip(): Frame
	local row = PanelKit.row(list, ROW_H)
	row.Name = "Item"
	-- -10 leaves the scrollbar its channel; a full-width row draws underneath
	-- it and the bar sits on top of the value.
	row.Size = UDim2.new(1, -10, 0, ROW_H)

	local tile = PanelKit.tile(row, TILE, 8, 6, C.sandDeep)
	tile.Name = "Tile"
	tile.ClipsDescendants = true

	local name = PanelKit.text(row, "", 13, Enum.Font.GothamBold, C.ink)
	name.Name = "ItemName"
	name.Position = UDim2.fromOffset(TILE + 12, 4)
	name.Size = UDim2.new(1, -(TILE + 22), 0, 18)
	name.TextXAlignment = Enum.TextXAlignment.Left

	local sub = PanelKit.text(row, "", 11, Enum.Font.GothamBold, STATE_COLOR.Crusted)
	sub.Name = "Sub"
	sub.Position = UDim2.fromOffset(TILE + 12, 24)
	-- Stops 6px short of the price rather than running under it: 46 in from the
	-- left, and the price is 58 wide sitting 10 off the right edge.
	sub.Size = UDim2.new(1, -(TILE + 86), 0, 16)
	sub.TextXAlignment = Enum.TextXAlignment.Left

	local value = PanelKit.text(row, "", 15, Enum.Font.LuckiestGuy, VALUE_UNKNOWN)
	value.Name = "Value"
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.new(1, -10, 0, 23)
	value.Size = UDim2.fromOffset(58, 18)
	value.TextXAlignment = Enum.TextXAlignment.Right

	-- Back easing, like every other thing that arrives in this game.
	local scale = Instance.new("UIScale")
	scale.Scale = 0.74
	scale.Parent = row
	TweenService:Create(scale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }):Play()

	return row
end

local function paintChip(chip: Frame, rec, order: number)
	-- rec.itemId is ABSENT for a crusted lump -- the server never sent it. That
	-- is why this falls back to a generic name rather than looking one up:
	-- there is genuinely nothing here to look up.
	local def = rec.itemId and ItemConfig.get(rec.itemId) or nil
	chip.LayoutOrder = order
	chip.ItemName.Text = def and def.DisplayName or ItemConfig.LumpDisplayName

	-- retint, not BackgroundColor3: the tile carries a UIGradient baked from
	-- its old tint, and a gradient MULTIPLIES against the fill under it, so
	-- painting a mythic pink face under a common-grey gradient gives mud.
	PanelKit.retint(chip.Tile, nil, ItemConfig.rarityColor(rec.rarity or "Unknown"))
	setArt(chip.Tile, rec.itemId)

	local stateColor = STATE_COLOR[rec.state] or STATE_COLOR.Crusted
	if rec.state ~= "Cleaned" and rec.progress and rec.progress > 0.01 then
		chip.Sub.Text = string.format("%s  %d%%",
			STATE_LABEL[rec.state] or rec.state, math.floor(rec.progress * 100))
	else
		chip.Sub.Text = STATE_LABEL[rec.state] or rec.state
	end
	chip.Sub.TextColor3 = stateColor

	chip.Value.Text = InventoryController.Client.valueText(rec)
	chip.Value.TextColor3 = (rec.state == "Cleaned") and VALUE_READY or VALUE_UNKNOWN
end

--------------------------------------------------------------------------
-- RENDER
--------------------------------------------------------------------------

-- What limits carried storage. Slots no longer do: the weight system lifts the
-- cap to 9999 and rations by LOAD instead, so client.MaxCapacity would render
-- "3 / 9999" here. Falls back to the slot count when the weight attributes are
-- absent, so this still reads correctly with the weight system removed.
local function storage(client): (number, number, string)
	local load = player:GetAttribute("CurrentWeight")
	local maxLoad = player:GetAttribute("MaxWeight")
	if type(load) == "number" and type(maxLoad) == "number" and maxLoad > 0 then
		return load, maxLoad, " LBS"
	end
	return client.Count, client.MaxCapacity, ""
end

local function amount(n: number): string
	local whole = math.floor(n + 0.5)
	if math.abs(n - whole) < 1e-3 then
		return tostring(whole)
	end
	return string.format("%.1f", n)
end

local function render(client)
	local carried, limit, unit = storage(client)
	local full = carried >= limit - 1e-4

	trackText.Text = string.format("%s / %s%s", amount(carried), amount(limit), unit)
	TweenService:Create(trackFill, TweenInfo.new(0.18), {
		Size = UDim2.fromScale(limit > 0 and math.clamp(carried / limit, 0, 1) or 0, 1),
	}):Play()
	-- Gold is the game's one loud state -- CTB_HUD's load bar goes gold at the
	-- same instant, off the same two attributes. Two bars disagreeing about
	-- what full looks like is worse than either colour.
	PanelKit.retint(trackFill, nil, full and C.sun or C.sea)

	local seen, count = {}, 0
	for i, rec in client.Items do
		seen[rec.uid] = true
		count += 1
		local chip = chips[rec.uid]
		if not chip then
			chip = makeChip()
			chips[rec.uid] = chip
		end
		paintChip(chip, rec, i)
	end

	for uid, chip in chips do
		if not seen[uid] then
			chip:Destroy()
			chips[uid] = nil
		end
	end

	-- Both of these are the OPEN card's business. Shut, the list is switched off
	-- and the count on the banner is the whole story.
	empty.Visible = open and (count == 0)
	if bannerText then
		bannerText.Text = (count > 0) and ("CARRYING  " .. count) or "CARRYING"
	end

	-- The card is as tall as this many rows, so the count has to reach fit()
	-- before it can answer. Cheap to call on every sync: it writes three Size
	-- properties and only when the arithmetic lands somewhere new.
	if count ~= rowCount then
		rowCount = count
		-- Animated: an open card that gains a row should slide, not jump. Shut,
		-- the height does not move and applyHeight snaps straight out of it.
		fit(true)
	end
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

local started = false
function InventoryHud.start()
	if started then
		return
	end
	started = true

	build()
	InventoryController.Client.Changed:Connect(render)

	-- The bar is drawn from weight now, and weight does not always move with
	-- the item list: a roller upgrade widens MaxWeight without adding an item,
	-- and InventorySync would never report it. Repaint on both.
	local function repaint()
		render(InventoryController.Client)
	end
	player:GetAttributeChangedSignal("CurrentWeight"):Connect(repaint)
	player:GetAttributeChangedSignal("MaxWeight"):Connect(repaint)

	-- Paint once from whatever has already arrived, in case the first sync beat
	-- us to the connection.
	render(InventoryController.Client)

	--[[
		B, the one key this HUD claims, and it is free: ClientMain switches the
		CoreGui backpack off so `~` opens nothing, and the only other letters bound
		anywhere in the game are the wash and sift minigames' A/D/Q and the
		ProximityPrompts' E/F.

		gameProcessedEvent covers the chat bar and every other text field -- without
		it, typing "grab a bin" into chat opens and shuts the drawer twice.
	]]
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not gameProcessed and input.KeyCode == Enum.KeyCode.B then
			setOpen(not open)
		end
	end)

	-- THE RAIL DOES NOT EXIST YET. ClientMain starts this module before MenuHud,
	-- so the first fit() sizes the card against the hint-line fallback and would
	-- keep that number for the whole session. Polled rather than hooked because
	-- there is nothing to hook: the rail is built inside MenuHud's own start and
	-- announces nothing. Stops the moment it finds it.
	task.spawn(function()
		for _ = 1, 30 do
			task.wait(0.4)
			if railBottom() then
				fit()
				return
			end
		end
	end)
end

-- The door into the drawer that is not a click. VirtualInputManager clicks are
-- capability-blocked, so a test needs one -- the same reason MenuHud carries a
-- DevDiscover BindableEvent -- and anything that wants the card out of the way
-- (the rebirth cinematic hides the whole ScreenGui today) has one too.
function InventoryHud.setOpen(v: boolean)
	setOpen(v and true or false)
end

function InventoryHud.toggle()
	setOpen(not open)
end

function InventoryHud.isOpen(): boolean
	return open
end

return InventoryHud
