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
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

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

-- 312 WIDE IS MEASURED, NOT PICKED. A row has to hold, on one line, the
-- longest display name in the catalogue ("Message in a Bottle", ~140px at
-- GothamBold 15) beside a 42px art tile, and on the next the longest state
-- string beside the widest price ("$40000" at LuckiestGuy 17). At the 292 this
-- started from, "ON THE STAND  42%" came out as "ON THE...".
local PANEL_W, PANEL_H = 312, 408
local ROW_H = 56
local TILE = 42
local HEAD_H = 44          -- the load track plus its gap, above the list

-- TOP-ANCHORED, NOT CENTRED, AND HEIGHT-CLAMPED.
--
-- The old panel was pinned to 0.5 of screen height at a fixed 372 tall, which
-- is fine at 1080 and runs straight through CTB_HUD's BEACH RAKED pill on a
-- short viewport. Anchoring the top instead makes the left edge read as one
-- stack -- coins, beach progress, carrying -- and fit() takes whatever height
-- is left between that pill and the hint line, so the card can shrink but it
-- can never overlap either of them.
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
local chips = {}           -- uid -> row Frame

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

-- Takes whatever height is left between CTB_HUD's raked pill and its hint
-- line. body/list/empty are all sized in SCALE off the card, so they follow
-- on their own; only the three fixed-offset shells have to be told.
-- The empty state is the tallest thing this card ever holds and the only part
-- of it laid out in fixed offsets, so it is what fit() has to bend. Held here
-- rather than kept local to build() for that reason.
local sackFrame, emptyTitle, emptyHint

local function fit()
	if not root then
		return
	end
	--[[
		AbsoluteSize is REAL pixels. TOP_Y, FOOT and PANEL_H are AUTHORED units,
		which UiFit scales on the way to the screen. Subtracting one from the other
		is a currency error, and it only became visible once the UI started
		scaling: on a 374px phone it worked out as 316 - 152 - 128 = 36, slammed
		into the clamp floor, and the card sat at its minimum with its own contents
		hanging out of the bottom. Converting the measurement into authored units
		first asks the right question -- how much room is there in the units this
		card is drawn in -- and gets 247 rather than 36.
	--]]
	local scale = UiFit.get()
	local roomY = gui.AbsoluteSize.Y / (scale > 0 and scale or 1)
	local h = math.clamp(roomY - TOP_Y - FOOT, 240, PANEL_H)
	root.Size = UDim2.fromOffset(PANEL_W, h)
	root.Card.Size = UDim2.fromOffset(PANEL_W, h)
	if slab then
		slab.Size = UDim2.fromOffset(PANEL_W, h)
	end

	--[[
		And then bend the empty state to whatever that left.

		Sack, title and hint come to 178 units stacked, and the body they sit in
		is the card minus its signboard and the load track -- which on a phone is
		about 139. Something has to give, and it must not be "draw outside the
		card", which is what fixed offsets were doing.

		The hint goes first: it is the least load-bearing thing on the card, and
		SACK EMPTY already says the same thing in fewer words. The sack shrinks
		next. Both labels are anchored to the BOTTOM of the body, so whatever
		height survives, they are inside it.
	--]]
	if emptyTitle and emptyHint and sackFrame and empty then
		local bodyH = empty.AbsoluteSize.Y / (scale > 0 and scale or 1)
		-- The labels own the bottom 56 units between them; whatever is left above
		-- is the sack's, and it is drawn at its authored 66 only if that fits.
		local above = bodyH - 56
		emptyHint.Visible = bodyH >= 178
		local sackPx = math.clamp(above - 10, 0, 66)
		sackFrame.Size = UDim2.fromOffset(sackPx, sackPx)
		-- Below about a third of its size it stops reading as a sack at all and
		-- is just a brown smudge over the words. Better absent.
		sackFrame.Visible = sackPx >= 24
	end
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "InventoryHud"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 6
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local closeFace
	root, body, closeFace = PanelKit.card(gui, "CARRYING", PANEL_W, PANEL_H, C.foam)
	-- A HUD readout is not a window. The X arrives with the shell, so it is
	-- removed rather than left sitting there doing nothing.
	closeFace.Parent:Destroy()
	root.Name = "Panel"
	root.AnchorPoint = Vector2.new(0, 0)
	-- 34 rather than the old 18: the banner overhangs the card by 17px a side,
	-- so at 18 the left end of the signboard sits a pixel off the screen edge.
	root.Position = UDim2.fromOffset(34, TOP_Y)

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
	track.Size = UDim2.new(1, 0, 0, 34)
	track.BackgroundColor3 = C.sandDeep
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.Parent = body
	corner(track, 17)
	outline(track, 3.5)

	trackFill = Instance.new("Frame")
	trackFill.Name = "Fill"
	trackFill.Size = UDim2.fromScale(0, 1)
	trackFill.BackgroundColor3 = C.sea
	trackFill.BorderSizePixel = 0
	trackFill.Parent = track
	corner(trackFill, 17)
	-- Created here only so retint() has a gradient to find; render owns the
	-- colour from now on.
	grad(trackFill, C.sea:Lerp(C.white, 0.25), darken(C.sea, 0.18))

	trackText = PanelKit.text(track, "0 / 20 LBS", 17, Enum.Font.LuckiestGuy, C.white)
	trackText.Size = UDim2.fromScale(1, 1)
	trackText.ZIndex = 4
	punch(trackText, 3)

	----------------------------------------------------------------
	-- THE LIST
	----------------------------------------------------------------
	list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.Position = UDim2.fromOffset(0, HEAD_H)
	list.Size = UDim2.new(1, 0, 1, -HEAD_H)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 5
	list.ScrollBarImageColor3 = C.woodDark
	list.ScrollBarImageTransparency = 0.25
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.Parent = body

	-- The last row otherwise sits flush against the card's inner edge and gets
	-- sliced by the scroll clip mid-letter.
	local pad = Instance.new("UIPadding")
	pad.PaddingBottom = UDim.new(0, 8)
	pad.Parent = list

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	-- Explicit LayoutOrder sorting. The default (Name) would order the rows
	-- alphabetically by uid, which is nearly-but-not-quite insertion order and
	-- makes items appear to jump around as you collect.
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	----------------------------------------------------------------
	-- EMPTY STATE
	--
	-- An empty panel used to be a 230x300 patch of nothing, which is the
	-- single largest thing on the screen for a player who has not picked
	-- anything up yet -- i.e. every new player, for their first minute.
	----------------------------------------------------------------
	empty = Instance.new("Frame")
	empty.Name = "Empty"
	empty.BackgroundTransparency = 1
	empty.Position = UDim2.fromOffset(0, HEAD_H)
	empty.Size = UDim2.new(1, 0, 1, -HEAD_H)
	empty.Parent = body

	-- Sits ON TOP OF the two labels, measured up from the bottom like they are.
	-- Left pinned 54 units from the top it kept its old place while they moved
	-- up to stay inside a shorter card, and the two ran straight through each
	-- other. One anchor for the whole stack or none of it.
	local sack = Instance.new("Frame")
	sack.Name = "Sack"
	sack.AnchorPoint = Vector2.new(0.5, 1)
	sack.Position = UDim2.new(0.5, 0, 1, -56)
	sack.Size = UDim2.fromOffset(66, 66)
	sack.BackgroundTransparency = 1
	sack.Parent = empty

	local handle = Instance.new("Frame")
	handle.Size = UDim2.fromScale(0.56, 0.56)
	handle.Position = UDim2.fromScale(0.22, 0)
	handle.BackgroundTransparency = 1
	handle.Parent = sack
	corner(handle, 33)
	outline(handle, 7, darken(C.sandDeep, 0.3))

	local sackBody = Instance.new("Frame")
	sackBody.Size = UDim2.fromScale(1, 0.62)
	sackBody.Position = UDim2.fromScale(0, 0.38)
	sackBody.BackgroundColor3 = C.sandDeep
	sackBody.BorderSizePixel = 0
	sackBody.Parent = sack
	corner(sackBody, 16)
	outline(sackBody, 4, darken(C.sandDeep, 0.3))

	-- Anchored to the BOTTOM of the empty area rather than pinned 132 and 158
	-- from its top. A fixed offset only works while the card is tall enough for
	-- it; measured from the bottom, they stay inside whatever height fit() ends
	-- up giving.
	local t1 = PanelKit.text(empty, "SACK EMPTY", 21, Enum.Font.LuckiestGuy, C.woodDark)
	t1.AnchorPoint = Vector2.new(0, 1)
	t1.Position = UDim2.new(0, 0, 1, -22)
	t1.Size = UDim2.new(1, 0, 0, 26)

	local t2 = PanelKit.text(empty, "comb the sand and it fills up", 13,
		Enum.Font.GothamMedium, darken(C.sandDeep, 0.4))
	t2.AnchorPoint = Vector2.new(0, 1)
	t2.Position = UDim2.new(0, 0, 1, 0)
	t2.Size = UDim2.new(1, 0, 0, 20)

	sackFrame, emptyTitle, emptyHint = sack, t1, t2

	fit()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	-- A scale change moves the goalposts as much as a resize does, and the
	-- ScreenGui's AbsoluteSize does not necessarily change with it.
	UiFit.onChanged(fit)
end

--------------------------------------------------------------------------
-- ROWS
--------------------------------------------------------------------------

local function makeChip(): Frame
	local row = PanelKit.row(list, ROW_H)
	row.Name = "Item"
	-- -12 leaves the scrollbar its channel; a full-width row draws underneath
	-- it and the bar sits on top of the value.
	row.Size = UDim2.new(1, -12, 0, ROW_H)

	local tile = PanelKit.tile(row, TILE, 8, 7, C.sandDeep)
	tile.Name = "Tile"
	tile.ClipsDescendants = true

	local name = PanelKit.text(row, "", 15, Enum.Font.GothamBold, C.ink)
	name.Name = "ItemName"
	name.Position = UDim2.fromOffset(TILE + 16, 5)
	name.Size = UDim2.new(1, -(TILE + 28), 0, 21)
	name.TextXAlignment = Enum.TextXAlignment.Left

	local sub = PanelKit.text(row, "", 12, Enum.Font.GothamBold, STATE_COLOR.Crusted)
	sub.Name = "Sub"
	sub.Position = UDim2.fromOffset(TILE + 16, 28)
	-- Stops 8px short of the price rather than running under it: 58 in from the
	-- left, and the price is 84 wide sitting 12 off the right edge.
	sub.Size = UDim2.new(1, -(TILE + 120), 0, 18)
	sub.TextXAlignment = Enum.TextXAlignment.Left

	local value = PanelKit.text(row, "", 17, Enum.Font.LuckiestGuy, VALUE_UNKNOWN)
	value.Name = "Value"
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.new(1, -12, 0, 27)
	value.Size = UDim2.fromOffset(84, 20)
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

	empty.Visible = (count == 0)
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
end

return InventoryHud
