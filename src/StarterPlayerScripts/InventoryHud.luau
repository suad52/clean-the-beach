--[[
	InventoryHud  --  StarterPlayerScripts.InventoryHud

	The carried-storage view. Renders straight off
	InventoryController.Client.Changed, which is fed by exactly the same
	InventorySync flush that repaints the pellets inside the roller drum -- so
	"3" on the key and three lit pellets in the roller are the same fact
	rendered twice, never two counters that have to be kept in step.

	Value display is not a UI choice. A record arrives with `value = nil` unless
	the server has rolled it, so "???" is what an unrolled item genuinely is.
	There is nothing to peek at in the client's memory.

	A KEY, NOT A CARD
	-----------------
	Shut, this is a 58px button with a count on it, sitting at the bottom of
	CTB_HUD's stack on the same x as everything above it. It used to be a 248x82
	card carrying a signboard with the word CARRYING on it at 20pt and a load
	track under that -- 82px of permanent screen for a list nobody had opened,
	and the track was drawing CurrentWeight / MaxWeight, which is the SAME pair
	of attributes the load bar three rows above it draws. One of the two had to
	go and it was never going to be the one you can see without clicking.

	So the key says how MANY, the bar above says how HEAVY, and the list of what
	is one press away.

	Shut also switches the list off, and a ViewportFrame under a hidden frame is
	not rendered -- so shut is not merely small, it is free. The rows themselves
	stay BUILT; see setOpen.

	THE COLUMN IS HudKit.L's, NOT THIS FILE'S
	-----------------------------------------
	Where the key sits and where the drawer starts are HudKit.L.KEY_Y and
	HudKit.L.DRAWER_Y. CTB_HUD places its three readouts off the same table.
	This is deliberate: the old card was 248 wide under 274 pills with its left
	edge nudged to 29 by hand to line the two up, because each file did the
	arithmetic for itself and the two answers drifted every time either moved.

	THE THUMBNAIL IS THE REAL MODEL, AND ONLY WHEN IT IS ALLOWED TO BE
	-----------------------------------------------------------------
	A cleaned record carries an itemId, so its row draws the actual art through
	ItemVisuals.buildClean -- the same model the reveal card and the Index show,
	which is the one-art-source rule this codebase has already paid for three
	times. A CRUSTED record does not carry one: the server has not told this
	client what is inside, and there is nothing here to look up. Those rows get
	the generic lump glyph, so the panel cannot leak a reveal even by accident.
	Templates are cached per id and cloned, so twenty cans cost one build.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local ItemConfig = require(Modules:WaitForChild("ItemConfig"))
local ItemVisuals = require(Modules:WaitForChild("ItemVisuals"))
local InventoryController = require(Modules:WaitForChild("InventoryController"))
local HudKit = require(Modules:WaitForChild("HudKit"))
local UiFit = require(Modules:WaitForChild("UiFit"))

-- Touch targets: see the module. Substituted for MouseButton1Click/Activated so
-- a tap in the margin around a control that renders under 44px on a phone still
-- reaches the same handler. No-ops on desktop and on controls already big enough.
local TouchFit = require(Modules:WaitForChild("TouchFit"))

local L = HudKit.L
local A = HudKit.A
local K = HudKit.C

local corner = HudKit.corner
local outline = HudKit.outline
local grad = HudKit.grad
local punch = HudKit.punch
local text = HudKit.text

local player = Players.LocalPlayer

local InventoryHud = {}

--------------------------------------------------------------------------
-- METRICS
--------------------------------------------------------------------------
-- The drawer is the column's width, so it lines up with the three readouts
-- above the key rather than being its own measurement.
local PANEL_W = L.W
local PAD_X   = 12          -- the drawer's own inner margin
local ROW_H   = 48
local ROW_GAP = 6
local TILE    = 38
local HEAD_H  = 22          -- the "CARRYING 3" line
local CLOSE   = 22          -- the X on the header, square, inside HEAD_H
local LIST_TOP = 10 + HEAD_H
local BOTTOM  = 12
local LIST_PAD = 6          -- breathing room under the last row
local EMPTY_H = 26

-- A row still has to hold the longest display name in the catalogue ("Message
-- in a Bottle", ~132px at GothamBold 13) beside a 32px art tile, and on the
-- line below the longest state string ("ON SCREEN  42%", ~86px at GothamBold
-- 11) clear of the widest price ("$40000", ~54px at LuckiestGuy 15). At
-- PANEL_W 256 that leaves about eight pixels of slack, which is why the column
-- width is a floor and not a preference.
local INNER_W = PANEL_W - PAD_X * 2

-- Where the list starts scrolling instead of the drawer growing. Off the SCREEN
-- rather than a flat row count: fit() grows the drawer down toward the hint
-- line and only then scrolls.
local MIN_ROWS = 2
local FOOT = 128            -- the hint line (36 tall, 76 off the bottom) plus air

-- BOTH bay states are listed. Which one a mounted lump carries is a ServerMain
-- decision -- WashServer writes "Washing", SiftServer writes "Sifting" -- and a
-- missing key here falls through to the raw state string.
local STATE_LABEL = {
	Crusted = "CRUSTED",
	Washing = "ON STAND",
	Sifting = "ON SCREEN",
	Cleaned = "READY",
}

-- Mixed for a near-white plate: (140,235,170) mint and (96,190,220) ice both
-- disappear on anything paler than mid-sand.
local STATE_COLOR = {
	Crusted = Color3.fromRGB(150, 100, 44),
	Washing = Color3.fromRGB(26, 128, 174),
	Sifting = Color3.fromRGB(178, 124, 20),
	Cleaned = Color3.fromRGB(40, 152, 84),
}

local VALUE_READY   = Color3.fromRGB(34, 146, 78)
local VALUE_UNKNOWN = Color3.fromRGB(150, 118, 84)

-- Wider than the 62 it was. A row is a whole STACK now, so the number on it is
-- a stack's worth -- "$4,120" rather than "$14" -- and 62px truncated it.
local VALUE_W = 76

-- The row, left to right: a rarity bar, the art tile, then everything else.
local STRIPE_X = 6
local STRIPE_W = 4
local TILE_X    = STRIPE_X + STRIPE_W + 6      -- 16
local CONTENT_X = TILE_X + TILE + 10           -- 64

--[[
	THE VERTICAL RHYTHM, DERIVED RATHER THAN TYPED.

	These were four hardcoded offsets -- tile at 6, name at 4, tag at 23, value at
	22 -- which were right for a 44-tall row with a 32px tile and silently wrong
	the moment either changed. Growing the art is exactly that change, so they are
	solved from ROW_H and TILE now and the next size is one number.

	The two text lines are 17 and 16 with 2 between them: 35 of the row, centred,
	which leaves the tile free to be as tall as the row can hold.
]]
local LINE_H  = 17
local TILE_Y  = math.floor((ROW_H - TILE) / 2)
local LINE1_Y = math.floor((ROW_H - (LINE_H + 2 + 16)) / 2)
local LINE2_Y = LINE1_Y + LINE_H + 2
-- Room for "999+" at GothamBold 13, right-aligned on the name's line.
local COUNT_W = 42

local function comma(n: number): string
	local s = tostring(math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (s:gsub("^,", ""))
end

local gui, keyHolder, keyFace, keyBadge, keyCount
local drawer, drawerFace, list, empty, headText, headValue
local chips = {}           -- uid -> row Frame

-- Shut on arrival, and it stays that way until it is asked.
local open = false
local sizeTween: Tween?
local rowCount = 0

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
	-- Bright. A 32px tile is small enough that a realistically-lit prop just
	-- reads as a dark smudge; these want to look like catalogue art.
	vpf.Ambient = Color3.fromRGB(226, 220, 208)
	vpf.LightColor = Color3.fromRGB(255, 252, 244)
	vpf.LightDirection = Vector3.new(-0.35, -1, -0.5)
	-- ABOVE the tile's gloss cap, not under it. The viewport's own background is
	-- transparent, so the gloss still reads everywhere the model is not -- the
	-- item ends up looking like it is behind glass rather than fogged by it.
	vpf.ZIndex = 9
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
local LUMP_ART = "rbxassetid://81967715628272"

--[[
	OVERSIZED ON PURPOSE, AND CLIPPED BY THE TILE.

	The art is a lump centred in a 687x687 canvas with a wide transparent margin
	all round it -- only 71% of each side is the rock itself. Dropped into the
	32px tile at 1:1, ScaleType.Fit maps the whole canvas INCLUDING that margin,
	and the lump comes out about 23px floating in a tile it does not fill.

	1.18 puts the box at 37.8 and draws the rock at about 27px, which is what the
	vector glyph this replaced occupied. The overhang is the canvas's own empty
	margin, and the tile clips (it has to: an item's viewport would otherwise
	spill across the name beside it), so none of the overflow is ever seen.

	THE NUMBER BELONGS TO THIS ART AND NOTHING ELSE. The previous lump was
	1024x559 with the rock filling 46% of the width, and wanted 1.85 -- a figure
	that would draw this one at 42px, half of it outside the tile. Re-solve on
	any swap; the sum is simply

		target px / (the art's larger side as a fraction of the box)

	which here is 27 / 0.715.
]]
local LUMP_FILL = 1.18

local function lumpGlyph(tile: GuiObject)
	local holder = Instance.new("Frame")
	holder.Name = "Art"
	holder.Size = UDim2.fromScale(1, 1)
	holder.BackgroundTransparency = 1
	holder.ZIndex = 9
	holder.Parent = tile

	local lump = Instance.new("ImageLabel")
	lump.Name = "Lump"
	lump.AnchorPoint = Vector2.new(0.5, 0.5)
	lump.Position = UDim2.fromScale(0.5, 0.5)
	lump.Size = UDim2.fromScale(LUMP_FILL, LUMP_FILL)
	lump.BackgroundTransparency = 1
	lump.Image = LUMP_ART
	lump.ScaleType = Enum.ScaleType.Fit
	lump.ZIndex = 9
	lump.Parent = holder
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
-- HOW TALL THE DRAWER IS
--------------------------------------------------------------------------
--[[
	A question about the CONTENTS first and the screen second.

	Asked in that order: what does the list actually need, then how much room is
	there between the drawer's own top and the hint line. The smaller wins, so a
	one-item bag draws a one-item drawer however big the monitor is -- where the
	old card took every pixel it was offered and filled the difference with
	blank sand.
]]
local function contentHeight(shown: number): number
	if shown <= 0 then
		return LIST_TOP + EMPTY_H + BOTTOM
	end
	return LIST_TOP + shown * ROW_H + (shown - 1) * ROW_GAP + LIST_PAD + BOTTOM
end

--[[
	TWO EASES, AND THAT IS NOT AN OVERSIGHT. Back overshoots, which is the house
	style and exactly right on the way OPEN: the drawer springs past its target
	into empty room and settles. On the way SHUT the same overshoot takes it
	PAST zero and the frame flips inside out for three frames. Closing gets
	Quart, which only ever approaches from above.

	Only the holder is tweened. Its slab and face are both sized fromScale(1, 1)
	against it, so they follow for free -- and the face CLIPS, which is what
	makes the close read as a drawer rolling up rather than as a list falling
	out of a shrinking box.
]]
local function applyHeight(h: number, animate: boolean?)
	local target = UDim2.fromOffset(PANEL_W, h)
	local from = drawer.Size.Y.Offset
	if sizeTween then
		sizeTween:Cancel()
		sizeTween = nil
	end

	if not animate or from == h then
		drawer.Size = target
		return
	end

	local info = (h > from)
		and TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		or TweenInfo.new(0.2, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

	sizeTween = TweenService:Create(drawer, info, { Size = target })
	sizeTween:Play()
	return sizeTween
end

-- What the drawer wants to be when it is open. Answered whether it is open or
-- not, because setOpen needs the number to animate TOWARD it.
local function fit(animate: boolean?)
	if not drawer then
		return
	end
	--[[
		AbsoluteSize is REAL pixels. Everything else here is AUTHORED units,
		which UiFit scales on the way to the screen. Subtracting one from the
		other is a currency error, and it only becomes visible once the UI
		starts scaling: on a short phone viewport it lands on the clamp floor
		and the drawer sits at its minimum with its own contents hanging out of
		the bottom. Converting the measurement into authored units first asks
		the right question -- how much room is there in the units this drawer is
		drawn in.
	]]
	local scale = UiFit.get()
	--[[
		THE COLUMN'S COMPACT PASS IS A SECOND SCALE ON TOP OF UiFit'S, and this
		sum is the real px one authored unit of THIS DRAWER measures. Dividing by
		UiFit's alone was right until the column started shrinking itself, and
		would now answer in units 16% too big -- the drawer would believe it had
		less room than it has and show a row fewer than it can.

		FOOT IS THE EXCEPTION and has to be converted back out. It reserves the
		hint line at the bottom of the screen, which belongs to CTB_HUD and is NOT
		on this column, so it is still measured in UiFit's units.
	]]
	local mult = HudKit.columnMult()
	local unit = (scale > 0 and scale or 1) * mult
	local roomY = gui.AbsoluteSize.Y / unit

	local floorH = contentHeight(MIN_ROWS)
	local ceiling = math.max(roomY - (FOOT / mult) - L.DRAWER_Y, floorH)

	-- HOW MANY ROWS THAT IS. Derived rather than fixed, so the drawer uses the
	-- room the screen actually has before handing the rest to a scrollbar.
	local maxRows = math.max(MIN_ROWS, math.floor(
		(ceiling - LIST_TOP - BOTTOM - LIST_PAD + ROW_GAP) / (ROW_H + ROW_GAP)))

	local shown = math.clamp(rowCount, 0, maxRows)
	local h = math.floor(math.min(contentHeight(shown), ceiling))

	-- Shut, the drawer is a closed box: the arithmetic above still runs because
	-- the scrollbar test below wants it, but the height is zero.
	applyHeight(open and h or 0, animate)

	-- THE BAR ONLY EXISTS WHEN THERE IS SOMETHING BELOW THE FOLD.
	--
	-- A ScrollingFrame draws its bar whenever the canvas is even a pixel over
	-- the window, and a row's 3px border stroke is enough to push it there: a
	-- drawer holding ONE item came up with a scrollbar down the side of it.
	-- Answered from the authored numbers rather than AbsoluteCanvasSize, which
	-- is a frame behind the layout that produced it.
	if list then
		local canvasH = (rowCount > 0)
			and (rowCount * ROW_H + (rowCount - 1) * ROW_GAP + LIST_PAD)
			or 0
		local windowH = h - LIST_TOP - BOTTOM
		list.ScrollBarThickness = (open and canvasH > windowH + 1) and 4 or 0
	end
end

--------------------------------------------------------------------------
-- OPEN / SHUT
--------------------------------------------------------------------------
--[[
	Visible = false on the drawer is the POINT of the shut state, not tidying up
	after it. Every row carries a ViewportFrame with a real model in it, and a
	ViewportFrame under a hidden frame is not rendered -- so shut is not merely
	small, it is free.

	The rows themselves stay BUILT. render() keeps them in step whether the
	drawer is open or not, which costs a few property writes per sync; the
	alternative is rebuilding twenty thumbnails every time it is opened.
]]
local closeToken = 0

local function setOpen(v: boolean)
	if open == v or not drawer then
		return
	end
	open = v

	list.Visible = open and rowCount > 0
	empty.Visible = open and rowCount == 0

	if open then
		closeToken += 1        -- cancels a close that is still rolling up
		drawer.Visible = true
		fit(true)
	else
		-- Hidden only once it has finished rolling up -- switching Visible off
		-- here is what made the old card vanish instead of closing. Tokened so a
		-- reopen mid-animation cannot have the pending hide land on top of it.
		closeToken += 1
		local mine = closeToken
		fit(true)
		task.delay(0.22, function()
			if closeToken == mine and not open then
				drawer.Visible = false
			end
		end)
	end
end

--------------------------------------------------------------------------
-- BUILD
--------------------------------------------------------------------------
local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "InventoryHud"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 6
	-- FALSE, matching CTB_HUD's. The two measure y from the same origin only if
	-- they agree about the topbar, and HudKit.L's numbers mean nothing if they
	-- do not.
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	----------------------------------------------------------------
	-- THE KEY
	----------------------------------------------------------------
	keyHolder, keyFace = HudKit.key(gui, L.KEY, A.foam, 18)
	keyHolder.Name = "BackpackKey"
	keyHolder.Position = UDim2.fromOffset(L.X, L.KEY_Y)
	-- The same compact pass CTB_HUD gives the three readouts above this key.
	-- Both ScreenGuis move by HudKit.COMPACT_COLUMN or the column comes apart
	-- at the seam between them. AFTER the Position above -- fitColumn rescales
	-- the offset it is handed.
	HudKit.fitColumn(keyHolder)

	--[[
		SPRITE, not HudKit.backpackGlyph's drawn pack. ScaleType.Fit for the
		same reason the rail's keys use it -- the art is not guaranteed square,
		and letterboxing it is better than squashing it to the button.

		CENTRED, where the vector pack was hung at (11, 10) with a 36px box. A
		sprite carries its own margin inside the image, so reusing the vector
		glyph's numbers would draw it small and high in a 58px key.

		0.62 IS THE VECTOR PACK'S OWN HEIGHT, and the number is a property of
		THIS art rather than a taste call. The sprite is full-bleed -- opaque
		to all four edges of its square canvas, carrying no margin of its own
		-- and Fit maps the whole canvas into the box, so here the box simply
		IS the pack. 0.62 of 58 draws it at 36px, which is what the drawn pack
		measured, and leaves its corners inside the face's 18px radius.

		So this has to be re-solved if the art is ever swapped again: a sprite
		with its own margin needs a BIGGER box to draw the same pack.

		ZIndex 8 puts it over the gloss cap (6) and under the count badge (12),
		which is where the drawn pack sat. Parented to the FACE, not the holder,
		so it rides the 5px press drop with everything else on the key.
	]]
	local glyph = Instance.new("ImageLabel")
	glyph.Name = "Icon"
	glyph.BackgroundTransparency = 1
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.5)
	glyph.Size = UDim2.fromScale(0.62, 0.62)
	glyph.Image = "rbxassetid://103992807805250"
	glyph.ScaleType = Enum.ScaleType.Fit
	glyph.ZIndex = 8
	glyph.Parent = keyFace

	keyBadge, keyCount = HudKit.badge(keyFace, 26)
	keyBadge.Visible = false

	TouchFit.press(keyFace, function()
		setOpen(not open)
	end)

	----------------------------------------------------------------
	-- THE DRAWER
	----------------------------------------------------------------
	local holder, face = HudKit.surface(gui, PANEL_W, contentHeight(0), 20)
	drawer, drawerFace = holder, face
	drawer.Name = "Drawer"
	drawer.Position = UDim2.fromOffset(L.X, L.DRAWER_Y)
	drawer.Size = UDim2.fromOffset(PANEL_W, 0)
	drawer.Visible = false
	-- Safe to scale even though this is the one piece of the column that
	-- animates: applyHeight tweens the SIZE, and fitColumn only ever rewrites
	-- the Position, which this never moves off.
	HudKit.fitColumn(drawer)
	-- See applyHeight: the roll-up depends on this.
	drawerFace.ClipsDescendants = true

	headText = text(drawerFace, "CARRYING", 14, K.textDim)
	-- Stops short of the X rather than running under it. The count is short
	-- enough today that it would not reach, but the label is the thing that
	-- grows here and the button is the thing that cannot move.
	headText.Size = UDim2.new(1, -(PAD_X * 2 + CLOSE + 6 + 92), 0, HEAD_H)
	headText.Position = UDim2.fromOffset(PAD_X, 8)
	headText.TextXAlignment = Enum.TextXAlignment.Left
	headText.ZIndex = 10

	--[[
		WHAT THE BAG IS WORTH RIGHT NOW, in the dead space the header had on its
		right. It is the question this drawer gets opened to answer -- "is it worth
		walking to the pad yet" -- and it was the one number not on screen.

		READY ONLY. A crusted lump has no rolled value, so counting it would make
		the total jump every time the bay finished one, which reads as the price
		moving rather than as the item becoming sellable.
	]]
	headValue = text(drawerFace, "", 14, VALUE_READY)
	headValue.Name = "HeadValue"
	headValue.AnchorPoint = Vector2.new(1, 0)
	headValue.Position = UDim2.new(1, -(PAD_X + CLOSE + 8), 0, 8)
	headValue.Size = UDim2.fromOffset(88, HEAD_H)
	headValue.TextXAlignment = Enum.TextXAlignment.Right
	headValue.ZIndex = 10

	--[[
		A WAY OUT THAT IS VISIBLE.

		The drawer already shut two ways -- B, or a second press of the key it
		came from -- and both of them are things you have to have been told.
		An X on the panel is the only one of the three that says so on screen,
		which is the whole reason it is worth 22px of header.

		It calls setOpen(false) and nothing else: the key, the B key and this
		all land on the same function, so the drawer cannot end up believing it
		is open while it is rolled up. Closing is still ONE piece of code.

		Drawn from two rotated Frames rather than typed as a glyph, for the
		reason HudKit gives for drawing its icons: LuckiestGuy has no
		multiplication sign, and what a device substitutes for one is its own
		business. Two bars at +/-45 look the same everywhere.
	]]
	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -PAD_X, 0, 8 + math.floor((HEAD_H - CLOSE) / 2))
	close.Size = UDim2.fromOffset(CLOSE, CLOSE)
	close.BackgroundColor3 = K.track
	close.AutoButtonColor = false    -- the hover below does this properly
	close.Text = ""
	close.BorderSizePixel = 0
	close.ZIndex = 11
	close.Parent = drawerFace
	HudKit.roundOff(close)
	outline(close, 2.5)

	for _, rot in { 45, -45 } do
		local bar = Instance.new("Frame")
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.fromScale(0.5, 0.5)
		bar.Size = UDim2.fromOffset(CLOSE * 0.44, math.max(2, CLOSE * 0.13))
		bar.Rotation = rot
		bar.BackgroundColor3 = K.text
		bar.BorderSizePixel = 0
		bar.ZIndex = 12
		bar.Parent = close
		HudKit.roundOff(bar)
	end

	-- Coral on hover, which is the colour this HUD already uses for the one
	-- thing on the key that is not chrome -- the count badge.
	close.MouseEnter:Connect(function()
		close.BackgroundColor3 = A.coral
	end)
	close.MouseLeave:Connect(function()
		close.BackgroundColor3 = K.track
	end)
	TouchFit.press(close, function()
		setOpen(false)
	end)

	list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.Position = UDim2.fromOffset(PAD_X, LIST_TOP)
	list.Size = UDim2.new(1, -PAD_X * 2, 1, -(LIST_TOP + BOTTOM))
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 4
	list.ScrollBarImageColor3 = K.ink
	list.ScrollBarImageTransparency = 0.35
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.ZIndex = 8
	list.Parent = drawerFace

	-- The last row otherwise sits flush against the drawer's inner edge and
	-- gets sliced by the scroll clip mid-letter.
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
	-- EMPTY STATE -- one line, and the drawer shrinks around it.
	----------------------------------------------------------------
	empty = Instance.new("Frame")
	empty.Name = "Empty"
	empty.BackgroundTransparency = 1
	empty.Position = UDim2.fromOffset(PAD_X, LIST_TOP)
	empty.Size = UDim2.new(1, -PAD_X * 2, 0, EMPTY_H)
	empty.ZIndex = 8
	empty.Parent = drawerFace

	local none = text(empty, "SACK EMPTY", 15, K.textDim)
	none.Size = UDim2.fromScale(1, 1)
	none.ZIndex = 9

	list.Visible = false
	empty.Visible = false

	fit()
	-- Both WRAPPED rather than connected raw. fit's first argument is `animate`
	-- and UiFit.onChanged hands its listener the SCALE -- a number, and every
	-- number is truthy, so a raw connection would animate on every resize.
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
-- The plate every list in the game uses, in the drawer's own palette rather
-- than PanelKit's sand: a near-white card with the item's art on the left.
local function plate(parent: GuiObject): Frame
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, ROW_H)
	row.BackgroundColor3 = K.rowFace
	row.BorderSizePixel = 0
	row.ZIndex = 8
	row.Parent = parent
	corner(row, 14)
	outline(row, 3)
	grad(row, K.rowFace, K.rowDark)
	return row
end

local function artTile(row: GuiObject): Frame
	--[[
		NO BOX. The tile used to be a tinted, outlined, gradient-lit square with the
		art sitting inside it -- a frame around a picture that is already a picture,
		on a row that already has its own plate and its own outline. Three nested
		rectangles for one item.

		WHAT IT IS STILL FOR is position and CLIPPING, and the clipping is not
		optional. The crusted lump's art is drawn at 1.85x the tile so its wide
		canvas fills the square (see lumpGlyph), and an item's ViewportFrame renders
		right to its own edges -- both rely on this frame cutting them off at 32px.
		Remove ClipsDescendants and the lump spills across the name beside it.

		Rarity used to be carried by this box's tint. It is on the bar down the
		row's left edge now, which is where it actually reads.
	]]
	local tile = Instance.new("Frame")
	tile.Name = "Tile"
	tile.Size = UDim2.fromOffset(TILE, TILE)
	tile.Position = UDim2.fromOffset(TILE_X, TILE_Y)
	tile.BackgroundTransparency = 1
	tile.BorderSizePixel = 0
	tile.ZIndex = 9
	tile.ClipsDescendants = true
	tile.Parent = row
	return tile
end

local function makeChip(): Frame
	local row = plate(list)
	row.Name = "Item"
	-- -10 leaves the scrollbar its channel; a full-width row draws underneath
	-- it and the bar sits on top of the value.
	row.Size = UDim2.new(1, -10, 0, ROW_H)

	--[[
		THE RARITY BAR.

		Rarity was already on the row -- the art tile is retinted by it -- but on
		a list where nearly everything is Common that is a pale tile among pale
		tiles, and the one Legendary in four hundred looked like all the rest. The
		same fact, moved to the edge the eye runs down.
	]]
	local stripe = Instance.new("Frame")
	stripe.Name = "Rarity"
	stripe.Position = UDim2.fromOffset(STRIPE_X, 8)
	stripe.Size = UDim2.fromOffset(STRIPE_W, ROW_H - 16)
	stripe.BackgroundColor3 = K.rowDark
	stripe.BorderSizePixel = 0
	stripe.ZIndex = 10
	stripe.Parent = row
	corner(stripe, 2)

	artTile(row)

	--[[
		THE STACK COUNT SITS AT THE END OF THE NAME'S LINE, not on the picture.

		It was a badge on the tile's corner, which worked while the tile was a
		tinted box -- the number had its own surface to sit on. With the box gone
		it is a figure stamped across the artwork, and the artwork is the thing
		being identified.

		The right end of the name's line is empty on every row (names are
		left-aligned and short), and it puts the count directly above the value --
		so the two numbers on the row line up in a column: how many, then how much.

		NO PILL. The row already lost one box today; a second number does not need
		a surface of its own to be legible on a near-white plate.
	]]
	local countBadge = Instance.new("Frame")
	countBadge.Name = "Count"
	countBadge.AnchorPoint = Vector2.new(1, 0)
	countBadge.Position = UDim2.new(1, -10, 0, LINE1_Y)
	countBadge.Size = UDim2.fromOffset(COUNT_W, LINE_H)
	countBadge.BackgroundTransparency = 1
	countBadge.BorderSizePixel = 0
	countBadge.ZIndex = 10
	countBadge.Visible = false
	countBadge.Parent = row

	local countText = text(countBadge, "", 13, K.rowSub, Enum.Font.GothamBold)
	countText.Name = "N"
	countText.Size = UDim2.fromScale(1, 1)
	countText.TextXAlignment = Enum.TextXAlignment.Right
	countText.ZIndex = 10

	local name = text(row, "", 13, K.rowText, Enum.Font.GothamBold)
	name.Name = "ItemName"
	name.Position = UDim2.fromOffset(CONTENT_X, LINE1_Y)
	name.Size = UDim2.new(1, -(CONTENT_X + 10), 0, LINE_H)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.ZIndex = 10

	--[[
		THE STATE AS A TAG, not a stray coloured word. Same colour and the same
		four words, with a shape around them -- which is what makes it read as a
		status ON the item rather than as a second line of description under it.

		AutomaticSize on both the tag and its label, so the pill is exactly as wide
		as the word: "READY" and "ON SCREEN" want very different boxes, and a fixed
		one is too roomy for the first or too tight for the second.
	]]
	local tag = Instance.new("Frame")
	tag.Name = "StateTag"
	tag.Position = UDim2.fromOffset(CONTENT_X, LINE2_Y)
	tag.Size = UDim2.fromOffset(0, 16)
	tag.AutomaticSize = Enum.AutomaticSize.X
	tag.BackgroundColor3 = STATE_COLOR.Crusted
	-- Faint. The word carries the colour; the pill only has to say there is one.
	tag.BackgroundTransparency = 0.82
	tag.BorderSizePixel = 0
	tag.ZIndex = 10
	tag.Parent = row
	corner(tag, 6)

	local tagPad = Instance.new("UIPadding")
	tagPad.PaddingLeft = UDim.new(0, 7)
	tagPad.PaddingRight = UDim.new(0, 7)
	tagPad.Parent = tag

	local sub = text(tag, "", 11, STATE_COLOR.Crusted, Enum.Font.GothamBold)
	sub.Name = "Sub"
	sub.Size = UDim2.fromOffset(0, 16)
	sub.AutomaticSize = Enum.AutomaticSize.X
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.ZIndex = 11

	local value = text(row, "", 15, VALUE_UNKNOWN)
	value.Name = "Value"
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.new(1, -10, 0, LINE2_Y - 1)
	value.Size = UDim2.fromOffset(VALUE_W, 18)
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.ZIndex = 10

	-- Back easing, like every other thing that arrives in this game.
	local scale = Instance.new("UIScale")
	scale.Scale = 0.74
	scale.Parent = row
	TweenService:Create(scale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }):Play()

	return row
end

--[[
	ONE ROW PER KIND, NOT PER ITEM.

	A row used to be one record. That is right for a bag of six and wrong for a
	bag of four hundred and seventy-six, which is what this drawer was actually
	being opened on: eight visible rows of "Plastic Bottle", "Soda Cup",
	"Plastic Bottle" with no way to tell what was in there or what it was worth.

	It was not only unreadable, it was expensive. Every row carries a
	ViewportFrame with a WorldModel, a Model and a Camera in it -- so four
	hundred items meant four hundred viewports being rendered behind a panel you
	had to scroll for a minute to reach the end of. Grouping takes that to about
	one per kind.

	STATE IS PART OF THE KEY. Three bottles on the sifting screen and forty in
	the bag are not the same row: one lot you can sell and the other you are
	waiting on, and merging them would hide exactly that.
]]
local function groupsOf(items)
	local byKey, order, count = {}, {}, 0
	for _, rec in items do
		count += 1
		-- rec.itemId is ABSENT for a crusted lump -- the server never sent it, so
		-- every lump groups together under one key rather than being looked up.
		local key = (rec.itemId or "__lump") .. "|" .. tostring(rec.state)
		local g = byKey[key]
		if not g then
			g = {
				key = key,
				itemId = rec.itemId,
				state = rec.state,
				rarity = rec.rarity,
				progress = rec.progress,
				count = 0,
				total = 0,
				known = 0,
			}
			byKey[key] = g
			order[#order + 1] = g
		end
		g.count += 1
		if rec.value then
			g.total += rec.value
			g.known += 1
		end
	end

	--[[
		MOST VALUABLE FIRST.

		The old list was insertion order, which at this size means the thing worth
		seeing is wherever you happened to pick it up. What a player opens this
		for is "what is in my bag and what is it worth", so the money leads.

		Ties fall through to count and then to the key, which is what keeps the
		order STABLE between syncs -- sorting on value alone would let equal rows
		swap places every time the table rehashed, and a list that reshuffles
		while you read it is worse than one in the wrong order.
	]]
	table.sort(order, function(x, y)
		if x.total ~= y.total then
			return x.total > y.total
		end
		if x.count ~= y.count then
			return x.count > y.count
		end
		return x.key < y.key
	end)
	return order, count
end

local function paintChip(chip: Frame, g, order: number)
	local def = g.itemId and ItemConfig.get(g.itemId) or nil
	local name = def and def.DisplayName or ItemConfig.LumpDisplayName
	chip.LayoutOrder = order
	-- The count rides on the NAME rather than in a badge of its own. The row has
	-- to say what it is and how many in one glance, and two places to look is
	-- half of what made the ungrouped list unreadable.
	chip.ItemName.Text = name

	--[[
		AND THE NAME GIVES BACK ONLY THE ROOM THE COUNT TAKES.

		The longest name in the catalogue is "Message in a Bottle" at about 132px,
		which does not fit beside a count. It does not have to: the long names are
		the one-off finds, and a stack of one shows no count at all -- so the row
		that needs the width is exactly the row that has it.
	]]
	local stacked = g.count > 1
	chip.Count.Visible = stacked
	chip.Count.N.Text = "x" .. ((g.count > 999) and "999+" or tostring(g.count))
	chip.ItemName.Size = stacked
		and UDim2.new(1, -(CONTENT_X + COUNT_W + 16), 0, LINE_H)
		or UDim2.new(1, -(CONTENT_X + 10), 0, LINE_H)

	-- The bar only. The tile is transparent now, and PanelKit.retint writes
	-- BackgroundColor3 unconditionally -- calling it here would paint the box
	-- straight back on in the rarity's colour.
	local rarity = ItemConfig.rarityColor(g.rarity or "Unknown")
	chip.Rarity.BackgroundColor3 = rarity
	setArt(chip.Tile, g.itemId)

	local stateColor = STATE_COLOR[g.state] or STATE_COLOR.Crusted
	chip.StateTag.BackgroundColor3 = stateColor
	-- A PERCENTAGE IS ONLY TRUE OF ONE ITEM. Several at different points through
	-- the same machine have no single number between them, so a grouped row says
	-- what they are and leaves the progress to the bay actually doing it.
	local sub = chip.StateTag.Sub
	if g.count == 1 and g.state ~= "Cleaned" and g.progress and g.progress > 0.01 then
		sub.Text = string.format("%s  %d%%",
			STATE_LABEL[g.state] or g.state, math.floor(g.progress * 100))
	else
		sub.Text = STATE_LABEL[g.state] or g.state
	end
	sub.TextColor3 = stateColor

	-- The stack's worth, not one item's. "???" only when NOTHING in the group has
	-- been rolled -- a crusted lump has no value to add up yet.
	chip.Value.Text = (g.known > 0) and ("$" .. comma(g.total)) or "???"
	chip.Value.TextColor3 = (g.state == "Cleaned") and VALUE_READY or VALUE_UNKNOWN
end

--------------------------------------------------------------------------
-- RENDER
--------------------------------------------------------------------------
local function render(client)
	-- Keyed by GROUP now, not by uid. A chip therefore survives items being
	-- added to and taken out of its stack, which is what stops the whole list
	-- being torn down and rebuilt -- viewports and all -- on every single sync.
	local groups, count = groupsOf(client.Items)

	local seen = {}
	for i, g in groups do
		seen[g.key] = true
		local chip = chips[g.key]
		if not chip then
			chip = makeChip()
			chips[g.key] = chip
		end
		paintChip(chip, g, i)
	end

	for key, chip in chips do
		if not seen[key] then
			chip:Destroy()
			chips[key] = nil
		end
	end

	-- A badge reading 0 is noise, not information: an empty bag is what the key
	-- says when it says nothing.
	if keyBadge then
		keyBadge.Visible = count > 0
		keyCount.Text = (count > 99) and "99+" or tostring(count)
	end
	if headText then
		headText.Text = (count > 0) and ("CARRYING  " .. count) or "CARRYING"
	end
	if headValue then
		local ready = 0
		for _, g in groups do
			if g.state == "Cleaned" then
				ready += g.total
			end
		end
		-- Blank rather than "$0": an empty bag has nothing to say about money.
		headValue.Text = (ready > 0) and ("$" .. comma(ready)) or ""
	end

	empty.Visible = open and (count == 0)
	list.Visible = open and (count > 0)

	-- The drawer is as tall as this many rows, so the count has to reach fit()
	-- before it can answer. Cheap to call on every sync: it writes one Size
	-- property and only when the arithmetic lands somewhere new.
	-- ROWS, not items. The drawer is as tall as what it actually draws, so a bag
	-- of four hundred bottles is now one row tall instead of asking fit() for a
	-- height it will only clamp away.
	if #groups ~= rowCount then
		rowCount = #groups
		-- Animated: an open drawer that gains a row should slide, not jump.
		-- Shut, the drawer is not visible and applyHeight snaps.
		fit(open)
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

	-- Paint once from whatever has already arrived, in case the first sync beat
	-- us to the connection.
	render(InventoryController.Client)

	--[[
		B, the one key this HUD claims, and it is free: ClientMain switches the
		CoreGui backpack off so `~` opens nothing, and the only other letters
		bound anywhere in the game are the wash and sift minigames' A/D/Q and the
		ProximityPrompts' E/F.

		gameProcessedEvent covers the chat bar and every other text field --
		without it, typing "grab a bin" into chat opens and shuts the drawer
		twice.
	]]
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if not gameProcessed and input.KeyCode == Enum.KeyCode.B then
			setOpen(not open)
		end
	end)
end

-- The door into the drawer that is not a click. VirtualInputManager clicks are
-- capability-blocked, so a test needs one -- the same reason MenuHud carries a
-- DevDiscover BindableEvent -- and anything that wants the drawer out of the
-- way has one too.
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