--[[
	TradeClient  --  StarterPlayerScripts.TradeClient

	The pet trading panel, the player picker that opens one, and the invite card.

	WHAT IT IS ALLOWED TO DECIDE: NOTHING. Every button sends a verb and at most
	a petId; the server owns who may trade, what is on the table, whether a lock
	stands and when the swap happens. This draws the last TradeState it was sent
	and nothing else -- there is no local copy of the table to get out of step.

	THE PANEL IS ITS OWN ScreenGui rather than a MenuHud rail panel, for the same
	reason DuelHud and AfkCard are: it is opened by a thing that happens TO you
	(an invite) at least as often as by a thing you go looking for, and it has to
	be able to appear over whatever else is open.

	Opened from the Pets panel's TRADE key, which fires the BindableEvent this
	file puts in its own gui -- the same seam BeachMenuHud's DevDiscover uses.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Net = require(Modules:WaitForChild("Net"))
local PanelKit = require(Modules:WaitForChild("PanelKit"))
local PetConfig = require(Modules:WaitForChild("PetConfig"))
local TradeConfig = require(Modules:WaitForChild("TradeConfig"))
-- Only for its art cache -- PetsPanel.art. Not to draw anything of its own.
-- The require is cached per client, so this is the SAME prepared set of pet
-- models the collection screen uses and the loading screen already paid for.
local PetsPanel = require(script.Parent:WaitForChild("PetsPanel"))

-- Touch targets: see the module. Substituted for MouseButton1Click/Activated so
-- a tap in the margin around a control that renders under 44px on a phone still
-- reaches the same handler. No-ops on desktop and on controls already big enough.
local TouchFit = require(Modules:WaitForChild("TouchFit"))

local C = PanelKit.C
local corner, outline, grad = PanelKit.corner, PanelKit.outline, PanelKit.grad
local text, punch, chunky, darken = PanelKit.text, PanelKit.punch, PanelKit.chunky, PanelKit.darken

local TINT = C.foam:Lerp(C.sea, 0.35)
local W, H = 760, 620

--------------------------------------------------------------------------
-- GUI ROOT
--------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "TradeHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 45
gui.Parent = player:WaitForChild("PlayerGui")

-- The seam the Pets panel opens this through.
local openEvent = Instance.new("BindableEvent")
openEvent.Name = "OpenTrade"
openEvent.Parent = gui

local function send(payload)
	Net.get("TradeAction"):FireServer(payload)
end

--------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------
-- The last snapshot from the server, or nil when there is no session.
local session = nil
-- The last PetSync, so the collection strip knows what there is to offer.
local pets = { owned = {}, equipped = {} }
local invite = nil

--------------------------------------------------------------------------
-- A PET TILE  --  the one shape both the table and the collection use
--------------------------------------------------------------------------
--[[
	IT SHOWS THE PET NOW, NOT JUST ITS NAME.

	This was a tinted block with a name on it, and the note here argued that
	was right because "a viewport renders its own scene every frame, and a
	trade screen can have twenty pets on it at once". The first half is true
	and the conclusion did not follow. A name does not tell you what you are
	about to give away, and it does not tell you what giving it away COSTS --
	which on this screen is luck, the only stat a pet has and the entire
	reason one pet is worth more than another.

	So every tile carries the animal and its luck bonus. The cost is bounded
	two ways rather than by going without:

	  * the art comes out of PetsPanel's cache -- templates already flattened
	    and anchored, with the camera solved once per species -- so a tile
	    clones one MeshPart and sets a CFrame, and measures nothing;
	  * ART_CAP is a ceiling on live scenes across the whole panel, spent in
	    DRAW ORDER, so repaint()'s two offer grids are served before the
	    collection strip. What you are actually trading always has a picture;
	    the worst case is a player holding sixty distinct species seeing the
	    last few rows of their own collection fall back to the tinted block.
	    Capped or not, every tile still gets the name and the luck.

	64 is PetsPanel's own POOL_CAP, and that panel draws 250 tiles.
]]
local ART_CAP = 64

--[[
	THE BUDGET IS A SET OF LIVE VIEWPORTS, NOT A TALLY OF THEM.

	It was a counter, incremented on build and decremented from the
	viewport's own `Destroying`. Measured: the first draw got its 64 and
	every repaint after it got ZERO -- the tiles came back with names and
	luck and no animals at all. Whatever the exact accounting slip, a counter
	that drifts one way is unrecoverable, because nothing ever puts it back.

	This cannot drift. A destroyed instance has a nil Parent, so the set
	prunes itself as it is read and the number it returns is a fact about the
	screen rather than a record of what was supposed to have happened to it.
	At most ART_CAP entries, read once per tile.
]]
local artLive = {}      -- [ViewportFrame] = true, while it is still parented

local function artInUse(): number
	local n = 0
	for vp in pairs(artLive) do
		if vp.Parent then
			n += 1
		else
			artLive[vp] = nil
		end
	end
	return n
end

--[[
	THE FRAME, AND WHY IT NARROWS THE LENS.

	PetsPanel solved each species' camera against ITS tile -- 104 wide by 116
	tall, a portrait -- at the default 70-degree vertical FOV. FieldOfView is
	VERTICAL, so the animal comes out at the same FRACTION of the frame's
	height whatever the frame's pixel size is: about four tenths. Four tenths
	of PetsPanel's 116 is a portrait; four tenths of the 46 this tile can
	spare is a smudge, which is exactly what the first cut looked like.

	40 degrees is that same framing pulled in until the pet fills the short
	band, and it costs nothing: no re-solve, no second camera per species and
	no touching a cache another panel is drawing from.

	The band stops at 50 and the name's scrim starts at 36, so the fourteen
	pixels they share are the empty backdrop under a centred animal rather
	than its feet. Measured, not guessed -- at 56 tall the pets were being cut
	in half by their own captions.
]]
local ART_TOP, ART_H, ART_FOV = 4, 46, 40

local function petArt(tile: GuiObject, petId: string): ViewportFrame?
	if artInUse() >= ART_CAP then
		return nil
	end
	local entry = PetsPanel.art(PetConfig, petId)
	if not entry then
		return nil
	end

	local vp = Instance.new("ViewportFrame")
	vp.Name = "Art"
	-- Under the tier cap and over the tile's own tint, which stays on as the
	-- backdrop the animal is lit against.
	vp.Position = UDim2.fromOffset(0, ART_TOP)
	vp.Size = UDim2.new(1, 0, 0, ART_H)
	vp.BackgroundTransparency = 1
	vp.Ambient = Color3.fromRGB(190, 190, 200)
	vp.LightColor = Color3.fromRGB(255, 250, 240)
	vp.LightDirection = Vector3.new(-0.4, -1, -0.6)
	vp.ZIndex = 1
	vp.Parent = tile

	local cam = Instance.new("Camera")
	cam.CFrame = entry.cam
	cam.FieldOfView = ART_FOV
	cam.Parent = vp
	vp.CurrentCamera = cam
	-- A CLONE. The entry is the shared template; parenting it here would move
	-- the cache into whichever tile asked last.
	entry.model:Clone().Parent = vp

	-- Nothing to release. A repaint destroys the tile, the tile takes this
	-- with it, and artInUse notices the next time it is asked. That matters
	-- because the two halves of the screen are torn down separately: PetSync
	-- rebuilds the collection strip on its own, with the offer grids left
	-- standing and their viewports still spending budget.
	artLive[vp] = true
	return vp
end

local function petTile(parent: GuiObject, petId: string?, count: number?, w: number, h: number,
	wornMark: boolean?)
	local tile = Instance.new("TextButton")
	tile.Size = UDim2.fromOffset(w, h)
	tile.AutoButtonColor = false
	tile.Text = ""
	tile.BorderSizePixel = 0
	tile.Parent = parent
	corner(tile, 12)

	if not petId then
		-- An empty slot reads as a hole cut in the board, not as a pet.
		tile.BackgroundColor3 = Color3.fromRGB(40, 25, 15)
		outline(tile, 3, darken(C.ink, 0.1))
		return tile
	end

	local def = PetConfig.get(petId)
	local info = def and PetConfig.tierInfo(def.Tier)
	tile.BackgroundColor3 = info and darken(info.color, 0.45) or darken(C.sandDeep, 0.45)
	outline(tile, 3)

	-- A tier-coloured cap, so rarity reads without reading a word.
	local cap = Instance.new("Frame")
	cap.Size = UDim2.new(1, 0, 0, 6)
	cap.BackgroundColor3 = info and info.color or C.sandDeep
	cap.BorderSizePixel = 0
	cap.ZIndex = 2
	cap.Parent = tile
	corner(cap, 6)

	petArt(tile, petId)

	--[[
		THE NAME SITS ON THE ART, NOT BESIDE IT.

		A solid caption bar would cost 22 of the tile's 62 pixels and the animal
		is what the player opened this to look at. A scrim fading up from the
		foot costs none of the picture -- the cached camera centres the pet, so
		the bottom of the frame is backdrop anyway -- and it makes white type
		read over a pale pet as surely as over a dark one.

		WRAPPED, NOT TRUNCATED. Measured at 11px in this width: 51 of the 63
		names fit on one line and the longest, Emberforge Salamander, is 1.51
		lines. Two lines therefore covers the whole roster, and the label is
		BOTTOM-aligned so a one-line name sits on the foot instead of floating
		in the middle of a box sized for two.
	]]
	local scrim = Instance.new("Frame")
	scrim.Name = "Scrim"
	scrim.AnchorPoint = Vector2.new(0, 1)
	scrim.Position = UDim2.new(0, 0, 1, 0)
	scrim.Size = UDim2.new(1, 0, 0, 26)
	scrim.BackgroundColor3 = Color3.fromRGB(10, 7, 12)
	scrim.BorderSizePixel = 0
	scrim.ZIndex = 2
	scrim.Parent = tile
	corner(scrim, 12)
	local sg = Instance.new("UIGradient")
	sg.Rotation = 90
	sg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.55, 0.5),
		NumberSequenceKeypoint.new(1, 0.28),
	})
	sg.Parent = scrim

	-- Stops short of the count badge's corner when there is one to stop short of.
	local nm = text(tile, def and def.DisplayName or petId, 11, Enum.Font.LuckiestGuy, C.white)
	nm.Size = UDim2.new(1, (count and count > 1) and -42 or -10, 0, 26)
	nm.Position = UDim2.new(0, 5, 1, -28)
	nm.TextWrapped = true
	nm.TextTruncate = Enum.TextTruncate.None
	nm.TextXAlignment = Enum.TextXAlignment.Left
	nm.TextYAlignment = Enum.TextYAlignment.Bottom
	nm.ZIndex = 3
	punch(nm, 2)

	--[[
		THE LUCK, TOP RIGHT, AND IT IS THE POINT OF THE SCREEN.

		A trade is a swap of cleaning luck; the name only says which animal it
		came wrapped in. Through the SAME PetConfig.luckText the Pets panel caps
		its tiles with and the HUD writes beside the clover, so the number read
		here is the number the player has already learned to read everywhere
		else -- and a pet cannot be worth +12% on one screen and +12.4% here.

		Tier-coloured rather than one flat chip: rarity and luck climb together,
		so the two cues reinforce each other instead of competing, and it ties
		the badge to the cap strip directly above it.
	]]
	if def then
		local luck = text(tile, PetConfig.luckText(def.Luck), 11, Enum.Font.LuckiestGuy, C.white)
		luck.Size = UDim2.fromOffset(40, 17)
		luck.Position = UDim2.new(1, -44, 0, 9)
		luck.BackgroundColor3 = info and darken(info.color, 0.12) or C.sun
		luck.BackgroundTransparency = 0
		luck.ZIndex = 4
		corner(luck, 6)
		outline(luck, 2)
	end

	if count and count > 1 then
		local badge = text(tile, "x" .. count, 12, Enum.Font.LuckiestGuy, C.ink)
		badge.Size = UDim2.fromOffset(28, 18)
		badge.Position = UDim2.new(1, -32, 1, -21)
		badge.BackgroundColor3 = C.sun
		badge.BackgroundTransparency = 0
		badge.ZIndex = 4
		corner(badge, 6)
	end

	-- THE TICK: the same green disc the Pets panel marks an equipped tile with,
	-- and it means the same thing here -- this one is out with you right now.
	--
	-- It is a NOTE, NOT A LOCK. Offering a pet you are wearing is allowed and the
	-- swap takes it off your back for you (see PetServer.canGive). The mark is
	-- here so that is a decision the player made rather than something they
	-- discover afterwards, which is the whole difference on a screen where the
	-- thing being given away does not come back.
	if wornMark then
		local tick = text(tile, "\u{2713}", 13, Enum.Font.LuckiestGuy, C.white)
		tick.Size = UDim2.fromOffset(18, 18)
		tick.Position = UDim2.fromOffset(5, 9)
		tick.BackgroundColor3 = C.limeDark
		tick.BackgroundTransparency = 0
		tick.ZIndex = 4
		corner(tick, 9)
		outline(tick, 2)
	end
	return tile
end

--------------------------------------------------------------------------
-- THE PANEL
--------------------------------------------------------------------------
local root, body, closeFace = PanelKit.card(gui, "Trade", W, H, TINT)
root.Visible = false

-- Two views in one card: the picker when there is no session, the table when
-- there is. One card so the panel does not appear to change identity when an
-- invite is accepted.
local pickerView = Instance.new("Frame")
pickerView.Name = "Picker"
pickerView.Size = UDim2.fromScale(1, 1)
pickerView.BackgroundTransparency = 1
pickerView.Parent = body

local tableView = Instance.new("Frame")
tableView.Name = "Table"
tableView.Size = UDim2.fromScale(1, 1)
tableView.BackgroundTransparency = 1
tableView.Visible = false
tableView.Parent = body

--------------------------------------------------------------------------
-- PICKER  --  who is near enough to ask
--------------------------------------------------------------------------
local pickerNote = text(pickerView, "", 15, Enum.Font.GothamMedium, Color3.fromRGB(226, 214, 190))
pickerNote.Size = UDim2.new(1, 0, 0, 44)
pickerNote.Position = UDim2.fromOffset(0, 2)
pickerNote.TextWrapped = true

local pickerList = Instance.new("ScrollingFrame")
pickerList.Size = UDim2.new(1, 0, 1, -56)
pickerList.Position = UDim2.fromOffset(0, 52)
pickerList.BackgroundTransparency = 1
pickerList.BorderSizePixel = 0
pickerList.ScrollBarThickness = 8
pickerList.ScrollBarImageColor3 = C.wood
pickerList.CanvasSize = UDim2.new()
pickerList.AutomaticCanvasSize = Enum.AutomaticSize.Y
pickerList.ScrollingDirection = Enum.ScrollingDirection.Y
pickerList.Parent = pickerView

local pickerLayout = Instance.new("UIListLayout")
pickerLayout.Padding = UDim.new(0, 8)
pickerLayout.SortOrder = Enum.SortOrder.LayoutOrder
pickerLayout.Parent = pickerList

local function refreshPicker()
	for _, c in pickerList:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end

	if not TradeConfig.meetsGate(player) then
		pickerNote.Text = TradeConfig.gateText()
			.. "  You have " .. TradeConfig.rebirthsOf(player) .. "."
		pickerNote.TextColor3 = C.sun
		return
	end
	pickerNote.TextColor3 = Color3.fromRGB(226, 214, 190)

	-- EVERYONE IN THE SERVER, not everyone nearby. Sorted by name rather than by
	-- join order: this is a list you look somebody up in, and join order is not
	-- an order a player can search.
	local others = {}
	for _, other in Players:GetPlayers() do
		if other ~= player then
			table.insert(others, other)
		end
	end
	table.sort(others, function(a, b)
		return a.DisplayName:lower() < b.DisplayName:lower()
	end)

	if #others == 0 then
		pickerNote.Text = "Nobody else is in this world right now. Trading needs somebody to trade with."
		return
	end
	pickerNote.Text = string.format("%d other player%s in this world -- pick one to send a trade invite to.",
		#others, #others == 1 and "" or "s")

	for i, other in others do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -10, 0, 56)
		row.BackgroundColor3 = C.white
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		row.Parent = pickerList
		corner(row, 14)
		outline(row, 3)
		grad(row, C.white, C.sand)

		local nm = text(row, other.DisplayName, 19, Enum.Font.LuckiestGuy, C.ink)
		nm.Size = UDim2.new(1, -170, 1, 0)
		nm.Position = UDim2.fromOffset(16, 0)
		nm.TextXAlignment = Enum.TextXAlignment.Left

		local holder, face = chunky(row, 130, 40, C.lime, 12)
		holder.AnchorPoint = Vector2.new(1, 0.5)
		holder.Position = UDim2.new(1, -14, 0.5, -3)
		local lbl = text(face, "INVITE", 17, Enum.Font.LuckiestGuy, C.white)
		lbl.Size = UDim2.fromScale(1, 1)
		punch(lbl, 2)
		TouchFit.press(face, function()
			send({ action = "invite", userId = other.UserId })
		end)
	end
end

--------------------------------------------------------------------------
-- TABLE  --  two offers, a status line, your collection, three buttons
--------------------------------------------------------------------------
local GRID_W, TILE_W, TILE_H, GAP = 348, 110, 62, 6

local function offerPanel(parent, x, titleText, titleCol)
	local holder = Instance.new("Frame")
	holder.Size = UDim2.fromOffset(GRID_W, 236)
	holder.Position = UDim2.fromOffset(x, 26)
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	local head = text(holder, titleText, 18, Enum.Font.LuckiestGuy, titleCol)
	head.Size = UDim2.new(1, 0, 0, 24)
	head.TextXAlignment = Enum.TextXAlignment.Left

	local grid = Instance.new("Frame")
	grid.Name = "Grid"
	grid.Size = UDim2.new(1, 0, 0, 210)
	grid.Position = UDim2.fromOffset(0, 26)
	grid.BackgroundTransparency = 1
	grid.Parent = holder

	local g = Instance.new("UIGridLayout")
	g.CellSize = UDim2.fromOffset(TILE_W, TILE_H)
	g.CellPadding = UDim2.fromOffset(GAP, GAP)
	g.SortOrder = Enum.SortOrder.LayoutOrder
	g.Parent = grid

	local lock = text(holder, "", 14, Enum.Font.LuckiestGuy, C.sand)
	lock.Size = UDim2.new(1, 0, 0, 20)
	lock.Position = UDim2.new(0, 0, 1, -18)
	lock.TextXAlignment = Enum.TextXAlignment.Left

	return { grid = grid, head = head, lock = lock }
end

local mine = offerPanel(tableView, 0, "YOUR OFFER", C.foam)
local theirs = offerPanel(tableView, GRID_W + 28, "THEIR OFFER", C.sun)

local status = text(tableView, "", 17, Enum.Font.LuckiestGuy, C.white)
status.Size = UDim2.new(1, 0, 0, 30)
status.Position = UDim2.fromOffset(0, 268)
punch(status, 2.5)

local collLabel = text(tableView, "YOUR PETS  --  tap to put one on the table.  \u{2713} means it is out with you.",
	14, Enum.Font.GothamBold, Color3.fromRGB(206, 190, 164))
collLabel.Size = UDim2.new(1, 0, 0, 20)
collLabel.Position = UDim2.fromOffset(0, 302)
collLabel.TextXAlignment = Enum.TextXAlignment.Left

local collection = Instance.new("ScrollingFrame")
collection.Size = UDim2.new(1, 0, 0, 150)
collection.Position = UDim2.fromOffset(0, 324)
collection.BackgroundTransparency = 1
collection.BorderSizePixel = 0
collection.ScrollBarThickness = 8
collection.ScrollBarImageColor3 = C.wood
collection.CanvasSize = UDim2.new()
collection.AutomaticCanvasSize = Enum.AutomaticSize.Y
collection.ScrollingDirection = Enum.ScrollingDirection.Y
collection.Parent = tableView

local collGrid = Instance.new("UIGridLayout")
collGrid.CellSize = UDim2.fromOffset(TILE_W, TILE_H)
collGrid.CellPadding = UDim2.fromOffset(GAP, GAP)
collGrid.SortOrder = Enum.SortOrder.LayoutOrder
collGrid.Parent = collection

local collEmpty = text(tableView, "", 15, Enum.Font.GothamMedium, Color3.fromRGB(190, 176, 152))
collEmpty.Size = UDim2.new(1, 0, 0, 40)
collEmpty.Position = UDim2.fromOffset(0, 380)
collEmpty.TextWrapped = true
collEmpty.Visible = false

-- The three buttons.
local btnRow = Instance.new("Frame")
btnRow.Size = UDim2.new(1, 0, 0, 50)
btnRow.Position = UDim2.new(0, 0, 1, -50)
btnRow.BackgroundTransparency = 1
btnRow.Parent = tableView

local btnLayout = Instance.new("UIListLayout")
btnLayout.FillDirection = Enum.FillDirection.Horizontal
btnLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
btnLayout.VerticalAlignment = Enum.VerticalAlignment.Center
btnLayout.Padding = UDim.new(0, 10)
btnLayout.SortOrder = Enum.SortOrder.LayoutOrder
btnLayout.Parent = btnRow

local cancelHolder, cancelFace = chunky(btnRow, 170, 44, C.coral, 13)
cancelHolder.LayoutOrder = 1
local cancelLbl = text(cancelFace, "CANCEL", 18, Enum.Font.LuckiestGuy, C.white)
cancelLbl.Size = UDim2.fromScale(1, 1)
punch(cancelLbl, 2)

local lockHolder, lockFace, lockSlab = chunky(btnRow, 210, 44, C.sun, 13)
lockHolder.LayoutOrder = 2
local lockLbl = text(lockFace, "LOCK OFFER", 18, Enum.Font.LuckiestGuy, C.white)
lockLbl.Size = UDim2.fromScale(1, 1)
punch(lockLbl, 2)

local okHolder, okFace, okSlab = chunky(btnRow, 210, 44, C.lime, 13)
okHolder.LayoutOrder = 3
local okLbl = text(okFace, "CONFIRM", 18, Enum.Font.LuckiestGuy, C.white)
okLbl.Size = UDim2.fromScale(1, 1)
punch(okLbl, 2)

TouchFit.press(cancelFace, function()
	send({ action = "cancel" })
end)
TouchFit.press(lockFace, function()
	if session then
		send({ action = session.myLock and "unlock" or "lock" })
	end
end)
TouchFit.press(okFace, function()
	send({ action = "confirm" })
end)

--------------------------------------------------------------------------
-- DRAWING THE TABLE
--------------------------------------------------------------------------
local function fillGrid(panel, rows, onClick)
	for _, c in panel.grid:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local shown = 0
	for i, row in rows do
		local t = petTile(panel.grid, row.petId, row.count, TILE_W, TILE_H)
		t.LayoutOrder = i
		shown += 1
		if onClick then
			TouchFit.press(t, function()
				onClick(row.petId)
			end)
		end
	end
	-- Pad to nine so the table always reads as a table with empty places rather
	-- than as a list that happens to be short.
	for i = shown + 1, TradeConfig.MaxOffer do
		local t = petTile(panel.grid, nil, nil, TILE_W, TILE_H)
		t.LayoutOrder = i
		t.AutoButtonColor = false
	end
end

-- How many copies are not already on the table. EQUIPPED COPIES ARE INCLUDED,
-- which is the client half of PetServer.canGive's rule: a pet you are wearing
-- is a pet you can trade, and the swap takes it off your back for you.
local function spareOf(petId: string): number
	local held = pets.owned[petId] or 0
	local onTable = 0
	if session then
		for _, row in session.mine do
			if row.petId == petId then
				onTable = row.count
			end
		end
	end
	return held - onTable
end

-- How many copies are on the player's back. Not a limit any more -- it only
-- decides which tiles get the tick, so somebody about to offer their only
-- Mythic can see it is the one currently following them around.
local function wornOf(petId: string): number
	local n = 0
	for _, id in pets.equipped do
		if id == petId then
			n += 1
		end
	end
	return n
end

local function refreshCollection()
	for _, c in collection:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local ids = {}
	for petId, n in pets.owned do
		if n > 0 and PetConfig.get(petId) and spareOf(petId) > 0 then
			table.insert(ids, petId)
		end
	end
	table.sort(ids, function(a, b)
		local da, db = PetConfig.Pets[a], PetConfig.Pets[b]
		if da.Luck ~= db.Luck then
			return da.Luck > db.Luck
		end
		return da.PetId < db.PetId
	end)

	collEmpty.Visible = (#ids == 0)
	if #ids == 0 then
		-- Two different empties, because they need two different answers.
		local anyOwned = next(pets.owned) ~= nil
		collEmpty.Text = anyOwned
			and "Every pet you own is already on the table."
			or "No pets yet -- hatch one at any egg plaza."
		return
	end

	for i, petId in ids do
		-- Ticked when the copies left are ones being worn: `spare <= worn` is
		-- exactly "putting one more on the table has to come off my back".
		local spare = spareOf(petId)
		local t = petTile(collection, petId, spare, TILE_W, TILE_H, spare <= wornOf(petId))
		t.LayoutOrder = i
		TouchFit.press(t, function()
			send({ action = "offer", petId = petId })
		end)
	end
end

local function paintButtons()
	if not session then
		return
	end
	lockLbl.Text = session.myLock and "UNLOCK" or "LOCK OFFER"
	PanelKit.retint(lockFace, lockSlab, session.myLock and C.grape or C.sun)

	local bothLocked = session.myLock and session.theirLock
	okLbl.Text = session.myConfirm and "CONFIRMED" or "CONFIRM"
	PanelKit.retint(okFace, okSlab,
		session.myConfirm and C.foamDark or (bothLocked and C.lime or darken(C.lime, 0.5)))
end

local function paintStatus()
	if not session then
		return
	end
	local function mark(on: boolean, word: string)
		return (on and "\u{2713} " or "\u{2022} ") .. word
	end
	mine.lock.Text = session.myConfirm and mark(true, "YOU CONFIRMED")
		or mark(session.myLock, session.myLock and "YOU LOCKED" or "editing")
	mine.lock.TextColor3 = session.myConfirm and C.lime or (session.myLock and C.sun or C.sand)

	theirs.lock.Text = session.theirConfirm and mark(true, "THEY CONFIRMED")
		or mark(session.theirLock, session.theirLock and "THEY LOCKED" or "editing")
	theirs.lock.TextColor3 = session.theirConfirm and C.lime or (session.theirLock and C.sun or C.sand)

	if session.myConfirm and session.theirConfirm then
		status.Text = "Trading..."
		status.TextColor3 = C.lime
	elseif session.myLock and session.theirLock then
		status.Text = "Both locked -- confirm to swap"
		status.TextColor3 = C.lime
	elseif session.myLock or session.theirLock then
		status.Text = "Waiting for both sides to lock"
		status.TextColor3 = C.sun
	else
		status.Text = "Put pets on the table, then lock"
		status.TextColor3 = C.white
	end
end

local function repaint()
	if session then
		pickerView.Visible = false
		tableView.Visible = true
		theirs.head.Text = string.upper(session.partnerName) .. "'S OFFER"
		fillGrid(mine, session.mine, function(petId)
			send({ action = "unoffer", petId = petId })
		end)
		fillGrid(theirs, session.theirs, nil)
		refreshCollection()
		paintStatus()
		paintButtons()
	else
		tableView.Visible = false
		pickerView.Visible = true
		refreshPicker()
	end
end

--------------------------------------------------------------------------
-- OPEN / CLOSE
--------------------------------------------------------------------------
local function open()
	repaint()
	PanelKit.popIn(root, W, H)
end

local function close()
	root.Visible = false
end

TouchFit.press(closeFace, close)
openEvent.Event:Connect(function()
	if root.Visible then
		close()
	else
		open()
	end
end)

--------------------------------------------------------------------------
-- THE INVITE CARD
--------------------------------------------------------------------------
local inviteRoot, inviteBody = PanelKit.card(gui, "Trade Invite", 460, 220, C.grape)
inviteRoot.Visible = false
-- Above the trade panel: an invite that arrives while the picker is open has to
-- be answerable.
inviteRoot.ZIndex = 60
for _, d in inviteRoot:GetDescendants() do
	if d:IsA("GuiObject") then
		d.ZIndex = d.ZIndex + 60
	end
end

local inviteText = text(inviteBody, "", 20, Enum.Font.LuckiestGuy, C.white)
inviteText.Size = UDim2.new(1, 0, 0, 60)
inviteText.Position = UDim2.fromOffset(0, 4)
inviteText.TextWrapped = true
inviteText.ZIndex = 65
punch(inviteText, 2.5)

local inviteRow = Instance.new("Frame")
inviteRow.Size = UDim2.new(1, 0, 0, 50)
inviteRow.Position = UDim2.new(0, 0, 1, -56)
inviteRow.BackgroundTransparency = 1
inviteRow.ZIndex = 65
inviteRow.Parent = inviteBody

local ir = Instance.new("UIListLayout")
ir.FillDirection = Enum.FillDirection.Horizontal
ir.HorizontalAlignment = Enum.HorizontalAlignment.Center
ir.VerticalAlignment = Enum.VerticalAlignment.Center
ir.Padding = UDim.new(0, 12)
ir.Parent = inviteRow

local noHolder, noFace = chunky(inviteRow, 150, 44, C.coral, 13)
noHolder.LayoutOrder = 1
local noLbl = text(noFace, "NO THANKS", 17, Enum.Font.LuckiestGuy, C.white)
noLbl.Size = UDim2.fromScale(1, 1)
punch(noLbl, 2)

local yesHolder, yesFace = chunky(inviteRow, 150, 44, C.lime, 13)
yesHolder.LayoutOrder = 2
local yesLbl = text(yesFace, "TRADE", 17, Enum.Font.LuckiestGuy, C.white)
yesLbl.Size = UDim2.fromScale(1, 1)
punch(yesLbl, 2)

for _, d in inviteRow:GetDescendants() do
	if d:IsA("GuiObject") then
		d.ZIndex = math.max(d.ZIndex, 66)
	end
end

local function clearInvite()
	invite = nil
	inviteRoot.Visible = false
end

TouchFit.press(noFace, function()
	send({ action = "decline" })
	clearInvite()
end)
TouchFit.press(yesFace, function()
	send({ action = "accept" })
	clearInvite()
end)

--------------------------------------------------------------------------
-- WIRE
--------------------------------------------------------------------------
Net.get("TradeState").OnClientEvent:Connect(function(snap)
	local had = session ~= nil
	session = (type(snap) == "table") and snap or nil
	if session and not had then
		-- A session that opened while the panel was shut is an invite that was
		-- just accepted, so show the table without being asked.
		open()
	elseif root.Visible then
		repaint()
	elseif had and not session then
		close()
	end
end)

Net.get("TradeInvite").OnClientEvent:Connect(function(data)
	if type(data) ~= "table" then
		clearInvite()
		return
	end
	invite = data
	inviteText.Text = string.format("%s wants to trade pets.", data.fromName or "Somebody")
	PanelKit.popIn(inviteRoot, 460, 220)
end)

Net.get("PetSync").OnClientEvent:Connect(function(snap)
	if type(snap) ~= "table" then
		return
	end
	pets.owned = snap.owned or {}
	pets.equipped = snap.equipped or {}
	if root.Visible and session then
		refreshCollection()
	end
end)

--[[
	The picker is a list of WHO IS IN THE SERVER, so the only things that can
	stale it are somebody joining or leaving.

	That used to be a 1.5s poll, because the list was of who was standing nearby
	and people walk. Server membership does not drift -- it changes on two events
	and nothing else -- so it is watched rather than swept, and an open picker
	costs nothing while nobody is coming or going.
]]
local function refreshIfPicking()
	if root.Visible and not session then
		refreshPicker()
	end
end
Players.PlayerAdded:Connect(refreshIfPicking)
Players.PlayerRemoving:Connect(function()
	-- Deferred: PlayerRemoving fires BEFORE the player leaves Players, so a list
	-- rebuilt here would still contain the person who is on their way out.
	task.defer(refreshIfPicking)
end)

-- The gate can be crossed mid-session (a rebirth while the panel is shut), and
-- the picker's locked message has to stop being true when it does.
player:GetAttributeChangedSignal("Rebirths"):Connect(function()
	if root.Visible and not session then
		refreshPicker()
	end
end)