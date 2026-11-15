--[[
	PetsPanel  --  StarterPlayerScripts.PetsPanel

	The Pets tab: five equipped slots, the collection, and the index.

	WHY THIS IS NOT INSIDE MenuHud
	------------------------------
	MenuHud owns the rail, the panel registry and the house style, and it is
	ninety-five kilobytes of somebody else's careful work. A panel that lives
	inside it is a merge conflict waiting to happen every time either of us
	touches the file. So MenuHud keeps three lines -- a rail entry, a require,
	and one call -- and hands this module the four things it cannot make for
	itself: the ScreenGui, the panel registry, the card factory, and PanelKit.

	Everything else, including the PetSync subscription, is owned here.

	WHAT IT IS ALLOWED TO DECIDE: NOTHING
	-------------------------------------
	Every button sends an action and at most a pet id. The server owns which
	five are best, whether a slot is free, whether the bag is full, and what
	any of it is worth in luck. This draws the last snapshot it was sent.

	VIEWPORTS ARE RATIONED
	----------------------
	A ViewportFrame renders its own little scene every frame, so a grid of a
	hundred of them is a hundred extra scenes. There are exactly six here: the
	five equipped slots, and the one in the detail card. The grids are chunky
	tinted tiles instead -- which is also what the rest of this menu looks like.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local PetsPanel = {}

--[[
	BIGGER THAN IT WAS, AND THE EXTRA IS ALL CONTENT.

	At 680x520 the grid ran four 122x74 tiles across and every one of them was a
	name squeezed into two lines with a release button sitting ON the name. The
	tiles are 154x94 now, which is what a two-line pet name and a bottom row of
	badges actually need; 720x588 is what fits three rows of those without the
	scroll starting halfway up the panel.

	Every Y below is measured off the one above it. Move the slot row and the
	stat row, the chips, the grid and the empty message all have to move with it.
]]
local W, H = 720, 588

--------------------------------------------------------------------------
-- ART
--------------------------------------------------------------------------
-- The same suffix rule PetServer, PetVisuals and EggClient all use, so a
-- hand-renamed model resolves everywhere or nowhere.
local function findArt(def)
	local root = ReplicatedStorage:FindFirstChild("Pets")
	local folder = root and root:FindFirstChild(def.Tier)
	if not folder then
		return nil
	end
	local exact = folder:FindFirstChild(def.ModelName) or folder:FindFirstChild(def.PetId)
	if exact then
		return exact
	end
	for _, child in folder:GetChildren() do
		if child.Name:sub(-#def.PetId) == def.PetId then
			return child
		end
	end
	return nil
end

--------------------------------------------------------------------------
-- BUILD
--------------------------------------------------------------------------
function PetsPanel.build(ctx)
	local gui = assert(ctx.gui, "[PetsPanel] needs the ScreenGui")
	local panels = assert(ctx.panels, "[PetsPanel] needs the panel registry")
	local makePanel = assert(ctx.makePanel, "[PetsPanel] needs makePanel")
	local PanelKit = assert(ctx.PanelKit, "[PetsPanel] needs PanelKit")
	local Net = assert(ctx.Net, "[PetsPanel] needs Net")
	local PetConfig = assert(ctx.PetConfig, "[PetsPanel] needs PetConfig")

	local C = PanelKit.C
	local darken, corner, outline = PanelKit.darken, PanelKit.corner, PanelKit.outline
	local grad, chunky, text, punch = PanelKit.grad, PanelKit.chunky, PanelKit.text, PanelKit.punch

	local TINT = C.grape:Lerp(C.coral, 0.35)

	-- THREE values, not four: makePanel wires the close X itself and returns
	-- (root, body, banner). Taking a closeFace out of it puts nil in `banner`,
	-- and a chunky() parented to nil builds silently and is never seen -- which
	-- is exactly how the TRADE key below went missing the first time.
	local root, body, banner = makePanel("Pets", W, H, TINT)
	panels.Pets = { root = root, w = W, h = H }

	--[[
		THE TRADE KEY, IN THE BANNER.

		PanelKit.card hands the banner back precisely for this -- "the rare panel
		with a SECOND global action", mirrored on the X's own geometry. Trading is
		exactly that: it belongs to the whole collection rather than to any row,
		and the stat row below is already 610 of its 644 pixels wide, so a fifth
		control down there would have had to shrink the luck pill to fit.

		It talks to TradeClient through the BindableEvent that script puts in its
		own ScreenGui -- the same seam BeachMenuHud's DevDiscover uses. Found
		lazily rather than at build time because the two scripts start in whatever
		order StarterPlayerScripts feels like.
	]]
	local tradeHolder, tradeFace = PanelKit.chunky(banner, 132, 44, C.foam, 13)
	tradeHolder.AnchorPoint = Vector2.new(0, 0.5)
	tradeHolder.Position = UDim2.new(0, 10, 0.5, -3)
	tradeHolder.ZIndex = 7
	for _, d in tradeHolder:GetDescendants() do
		if d:IsA("GuiObject") then
			d.ZIndex = math.max(d.ZIndex, 8)
		end
	end
	local tradeLbl = text(tradeFace, "TRADE", 18, Enum.Font.LuckiestGuy, C.white)
	tradeLbl.Size = UDim2.fromScale(1, 1)
	tradeLbl.ZIndex = 9
	punch(tradeLbl, 3)

	tradeFace.MouseButton1Click:Connect(function()
		local hud = Players.LocalPlayer:FindFirstChild("PlayerGui")
		local tradeGui = hud and hud:FindFirstChild("TradeHud")
		local opener = tradeGui and tradeGui:FindFirstChild("OpenTrade")
		if not opener then
			return
		end
		if ctx.close then
			ctx.close()
		end
		opener:Fire()
	end)

	-- Last snapshot from the server. Everything drawn below is a view of this.
	local state = {
		owned = {}, equipped = {}, discovered = {},
		luck = 1, ownedCount = 0,
		maxEquipped = PetConfig.MaxEquipped, maxOwned = PetConfig.MaxOwned,
	}
	local view = "Collection"   -- or "Index"

	local function send(payload)
		Net.get("PetEquip"):FireServer(payload)
	end

	------------------------------------------------------------------
	-- A PET IN A BOX
	------------------------------------------------------------------
	-- Rationed: see the header. Returns the ViewportFrame so the caller can
	-- re-point it at a different pet rather than building a second one.
	local function petViewport(parent)
		local vp = Instance.new("ViewportFrame")
		vp.BackgroundTransparency = 1
		vp.Size = UDim2.fromScale(1, 1)
		vp.Ambient = Color3.fromRGB(190, 190, 200)
		vp.LightColor = Color3.fromRGB(255, 250, 240)
		vp.LightDirection = Vector3.new(-0.4, -1, -0.6)
		vp.Parent = parent

		local cam = Instance.new("Camera")
		cam.Parent = vp
		vp.CurrentCamera = cam
		return vp
	end

	local function showPet(vp: ViewportFrame, petId: string?)
		for _, c in vp:GetChildren() do
			if not c:IsA("Camera") then
				c:Destroy()
			end
		end
		if not petId then
			return
		end
		local def = PetConfig.get(petId)
		local art = def and findArt(def)
		if not art then
			return
		end

		local model = art:Clone()
		if not model:IsA("Model") then
			local wrap = Instance.new("Model")
			model.Parent = wrap
			wrap.PrimaryPart = model:IsA("BasePart") and model or nil
			model = wrap
		end
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = false
			end
		end
		model.Parent = vp

		local centre, size = model:GetBoundingBox()
		local biggest = math.max(size.X, size.Y, size.Z, 0.1)
		-- The pack faces -Z once the FBX axis conversion has run, so the camera
		-- sits on the -Z side or every card would be a portrait of a tail.
		local dir = Vector3.new(0.55, 0.42, -1).Unit
		vp.CurrentCamera.CFrame =
			CFrame.lookAt(centre.Position + dir * biggest * 1.85, centre.Position)
	end

	------------------------------------------------------------------
	-- HEADER: the five slots
	------------------------------------------------------------------
	local slotRow = Instance.new("Frame")
	slotRow.Name = "Slots"
	slotRow.Size = UDim2.new(1, 0, 0, 104)
	slotRow.BackgroundTransparency = 1
	slotRow.Parent = body

	local slotLay = Instance.new("UIListLayout")
	slotLay.FillDirection = Enum.FillDirection.Horizontal
	-- Centred. Five 88px tiles and four 8px gaps come to 472 in a 644 body, so
	-- left-aligning them parked the whole row against the left edge with a
	-- hand's width of empty cream beside it -- which reads as a row that failed
	-- to finish loading rather than as a deliberate left margin.
	slotLay.HorizontalAlignment = Enum.HorizontalAlignment.Center
	slotLay.VerticalAlignment = Enum.VerticalAlignment.Center
	slotLay.Padding = UDim.new(0, 8)
	slotLay.SortOrder = Enum.SortOrder.LayoutOrder
	slotLay.Parent = slotRow

	local slots = {}
	for i = 1, PetConfig.MaxEquipped do
		local tile = Instance.new("TextButton")
		tile.Name = "Slot" .. i
		tile.LayoutOrder = i
		tile.Size = UDim2.fromOffset(96, 96)
		-- Darker than it was: the pet's name is white and sat on a mid tan, which
		-- is two light values fighting. On a deep tan the name reads at a glance.
		--
		-- Taken further again now the tray behind it is dark wood rather than
		-- cream. Same reasoning, moved target: a deep tan was a strong socket on
		-- cream and is within a few percent of the board it now sits on. These
		-- want to read as holes CUT IN the board, which also gives the pet
		-- viewport that lands in them something dark to sit against.
		tile.BackgroundColor3 = Color3.fromRGB(40, 25, 15)
		tile.BorderSizePixel = 0
		tile.AutoButtonColor = false
		tile.Text = ""
		tile.Parent = slotRow
		corner(tile, 14)
		outline(tile, 3)

		local vp = petViewport(tile)
		vp.Size = UDim2.new(1, -10, 1, -22)
		vp.Position = UDim2.fromOffset(5, 2)

		local empty = text(tile, "EMPTY", 13, Enum.Font.LuckiestGuy, Color3.fromRGB(138, 114, 90))
		empty.Size = UDim2.fromScale(1, 1)

		local nameLbl = text(tile, "", 13, Enum.Font.GothamBold, C.white)
		nameLbl.Size = UDim2.new(1, -8, 0, 18)
		nameLbl.Position = UDim2.new(0, 4, 1, -20)
		nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
		nameLbl.ZIndex = 4

		slots[i] = { tile = tile, vp = vp, empty = empty, name = nameLbl, petId = nil }

		tile.Activated:Connect(function()
			local petId = slots[i].petId
			if petId then
				send({ petId = petId, equip = false })
			end
		end)
	end

	------------------------------------------------------------------
	-- HEADER: luck, capacity, and the two buttons
	------------------------------------------------------------------
	local statRow = Instance.new("Frame")
	statRow.Position = UDim2.fromOffset(0, 114)
	statRow.Size = UDim2.new(1, 0, 0, 46)
	statRow.BackgroundTransparency = 1
	statRow.Parent = body

	--[[
		LAID OUT, NOT NUMBERED.

		The luck pill and the two buttons were positioned by hand at x = 0, 204
		and 362, which ended the group at 480 in a 644-wide row and left a
		hundred-and-sixty pixel hole between the last button and the capacity
		pill on the right. Three controls with a gap that size between them do
		not read as a group with a stat beside it; they read as things that have
		drifted apart. A list layout packs them and keeps packing them whatever
		any of them is resized to next.
	]]
	-- CENTRED, and the capacity pill is IN the row rather than pinned to the
	-- right edge of it. The slot row above is centred, so a left-aligned cluster
	-- under it started eighty pixels to the left of the tiles it belongs to and
	-- the two rows shared no edge at all -- which is what made this header look
	-- assembled out of parts rather than laid out.
	local statLeft = Instance.new("Frame")
	statLeft.Name = "Row"
	statLeft.Size = UDim2.fromScale(1, 1)
	statLeft.BackgroundTransparency = 1
	statLeft.Parent = statRow

	local statLay = Instance.new("UIListLayout")
	statLay.FillDirection = Enum.FillDirection.Horizontal
	statLay.HorizontalAlignment = Enum.HorizontalAlignment.Center
	statLay.VerticalAlignment = Enum.VerticalAlignment.Center
	statLay.Padding = UDim.new(0, 8)
	statLay.SortOrder = Enum.SortOrder.LayoutOrder
	statLay.Parent = statLeft

	local luckPill = Instance.new("Frame")
	luckPill.LayoutOrder = 1
	luckPill.Size = UDim2.fromOffset(206, 40)
	luckPill.BackgroundColor3 = darken(C.limeDark, 0.1)
	luckPill.BorderSizePixel = 0
	luckPill.Parent = statLeft
	corner(luckPill, 12)
	outline(luckPill, 3)
	grad(luckPill, C.lime, C.limeDark)

	-- No clover glyph. Roblox's text emoji coverage is not the system's, and one
	-- it cannot find comes back looking like a broken icon rather than like
	-- nothing -- the rebirth panel shipped a wave that rendered as a pale
	-- crescent for exactly this reason. The pill is already green and already
	-- says what it is.
	local luckText = text(luckPill, "+0% CLEANING LUCK", 17, Enum.Font.LuckiestGuy, C.white)
	luckText.Size = UDim2.fromScale(1, 1)
	punch(luckText, 2)

	local capPill = Instance.new("Frame")
	capPill.LayoutOrder = 4
	capPill.Size = UDim2.fromOffset(104, 40)
	capPill.BackgroundColor3 = C.sandDeep
	capPill.BorderSizePixel = 0
	capPill.Parent = statLeft
	corner(capPill, 12)
	outline(capPill, 3)

	-- INK, not white. This pill is the one light slab in the row, and white on
	-- light tan is the same mistake the slot tiles were making.
	local capText = text(capPill, "0 / 100", 17, Enum.Font.LuckiestGuy, C.ink)
	capText.Size = UDim2.fromScale(1, 1)

	local bestHolder, bestFace = chunky(statLeft, 152, 40, C.sun, 13)
	bestHolder.LayoutOrder = 2
	local bestLbl = text(bestFace, "EQUIP BEST", 18, Enum.Font.LuckiestGuy, C.white)
	bestLbl.Size = UDim2.fromScale(1, 1)
	punch(bestLbl, 2)
	bestFace.MouseButton1Click:Connect(function()
		send({ action = "best" })
	end)

	local offHolder, offFace = chunky(statLeft, 124, 40, C.coral, 13)
	offHolder.LayoutOrder = 3
	local offLbl = text(offFace, "TAKE OFF", 18, Enum.Font.LuckiestGuy, C.white)
	offLbl.Size = UDim2.fromScale(1, 1)
	punch(offLbl, 2)
	offFace.MouseButton1Click:Connect(function()
		send({ action = "unequipAll" })
	end)

	------------------------------------------------------------------
	-- VIEW CHIPS
	------------------------------------------------------------------
	local chipRow = Instance.new("Frame")
	chipRow.Position = UDim2.fromOffset(0, 172)
	chipRow.Size = UDim2.new(1, 0, 0, 36)
	chipRow.BackgroundTransparency = 1
	chipRow.Parent = body

	local chipLay = Instance.new("UIListLayout")
	chipLay.FillDirection = Enum.FillDirection.Horizontal
	chipLay.VerticalAlignment = Enum.VerticalAlignment.Center
	chipLay.Padding = UDim.new(0, 6)
	chipLay.Parent = chipRow

	local chips = {}
	local rebuild   -- forward-declared: the chips call it

	for _, name in { "Collection", "Index" } do
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(name == "Collection" and 140 or 110, 36)
		b.BackgroundColor3 = Color3.fromRGB(48, 31, 19)
		b.BorderSizePixel = 0
		b.AutoButtonColor = false
		b.Font = Enum.Font.LuckiestGuy
		b.TextSize = 17
		b.TextColor3 = C.white
		b.Text = string.upper(name)
		b.Parent = chipRow
		corner(b, 10)
		outline(b, 2)
		chips[name] = b
		b.Activated:Connect(function()
			if view ~= name then
				view = name
				rebuild()
			end
		end)
	end

	-- Parented to the BODY, not the chip row: the chip row runs a horizontal
	-- UIListLayout, which would pack this hard against the last chip instead of
	-- letting it sit out on the right.
	-- Readable. This was white darkened by 15%, which is a very light grey, on a
	-- cream panel -- the count was on screen the whole time and effectively
	-- invisible. Everything else that is body copy in this menu is the same warm
	-- brown, so this is too.
	-- Light on the dark board. The browns in this file were all picked to sit on
	-- cream and none of them survived the tray going dark.
	local progress = text(body, "", 16, Enum.Font.GothamBold, Color3.fromRGB(240, 226, 200))
	progress.AnchorPoint = Vector2.new(1, 0)
	progress.Position = UDim2.new(1, 0, 0, 172)
	progress.Size = UDim2.fromOffset(280, 36)
	progress.TextXAlignment = Enum.TextXAlignment.Right

	------------------------------------------------------------------
	-- THE GRID
	------------------------------------------------------------------
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Grid"
	scroll.Position = UDim2.fromOffset(0, 216)
	scroll.Size = UDim2.new(1, 0, 1, -216)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 8
	scroll.ScrollBarImageColor3 = C.wood
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.Parent = body

	local gridLay = Instance.new("UIGridLayout")
	gridLay.CellSize = UDim2.fromOffset(154, 94)
	gridLay.CellPadding = UDim2.fromOffset(8, 8)
	gridLay.SortOrder = Enum.SortOrder.LayoutOrder
	gridLay.Parent = scroll

	local pad = Instance.new("UIPadding")
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = scroll

	-- Outside the grid on purpose. Parented to the scroll, a UIGridLayout would
	-- crop this sentence into one 122x74 cell.
	-- Centred in the GRID, not sitting near the top of it. The collection area
	-- is 250-odd pixels tall and empty on a new save, and one line parked at the
	-- top of all that space reads as the first row of a list that failed to load
	-- rather than as an answer to "why is this empty".
	local emptyMsg = text(body, "No pets yet", 22, Enum.Font.LuckiestGuy, C.sand)
	emptyMsg.Position = UDim2.fromOffset(0, 300)
	emptyMsg.Size = UDim2.new(1, 0, 0, 30)
	emptyMsg.Visible = false

	-- The second line is the useful one: the first says what is wrong, this says
	-- what to do about it.
	local emptyHint = text(body, "Hatch one at any egg plaza — there is one on every island.",
		15, Enum.Font.GothamMedium, Color3.fromRGB(206, 184, 156))
	emptyHint.Position = UDim2.fromOffset(0, 332)
	emptyHint.Size = UDim2.new(1, 0, 0, 24)
	emptyHint.Visible = false

	------------------------------------------------------------------
	-- DETAIL CARD  (the panel's one other viewport)
	------------------------------------------------------------------
	local detail = Instance.new("Frame")
	detail.Name = "PetDetail"
	detail.AnchorPoint = Vector2.new(0.5, 0.5)
	detail.Position = UDim2.fromScale(0.5, 0.5)
	detail.Size = UDim2.fromOffset(300, 320)
	detail.BackgroundColor3 = darken(C.sandDeep, 0.1)
	detail.BorderSizePixel = 0
	detail.Visible = false
	detail.ZIndex = 40
	detail.Parent = gui
	corner(detail, 18)
	outline(detail, 4)

	local dVp = petViewport(detail)
	dVp.Size = UDim2.new(1, -24, 0, 176)
	dVp.Position = UDim2.fromOffset(12, 14)
	dVp.ZIndex = 41

	local dName = text(detail, "", 22, Enum.Font.LuckiestGuy, C.white)
	dName.Size = UDim2.new(1, -20, 0, 30)
	dName.Position = UDim2.fromOffset(10, 196)
	dName.ZIndex = 42

	local dTier = text(detail, "", 15, Enum.Font.LuckiestGuy, C.white)
	dTier.Size = UDim2.new(1, -20, 0, 22)
	dTier.Position = UDim2.fromOffset(10, 226)
	dTier.ZIndex = 42

	local dLuck = text(detail, "", 15, Enum.Font.GothamBold, C.white)
	dLuck.Size = UDim2.new(1, -20, 0, 22)
	dLuck.Position = UDim2.fromOffset(10, 250)
	dLuck.ZIndex = 42

	local dCloseHolder, dCloseFace = chunky(detail, 110, 34, C.coral, 12)
	dCloseHolder.AnchorPoint = Vector2.new(0.5, 0)
	dCloseHolder.Position = UDim2.new(0.5, 0, 1, -44)
	dCloseHolder.ZIndex = 42
	local dCloseLbl = text(dCloseFace, "CLOSE", 15, Enum.Font.LuckiestGuy, C.white)
	dCloseLbl.Size = UDim2.fromScale(1, 1)

	local function closeDetail()
		detail.Visible = false
		showPet(dVp, nil)
	end
	dCloseFace.MouseButton1Click:Connect(closeDetail)
	panels.Pets.closeDetail = closeDetail

	local function openDetail(petId: string, known: boolean)
		local def = PetConfig.get(petId)
		if not def then
			return
		end
		local info = PetConfig.tierInfo(def.Tier)
		showPet(dVp, known and petId or nil)
		dName.Text = known and def.DisplayName or "???"
		dTier.Text = string.upper(def.Tier)
		dTier.TextColor3 = info.color
		dLuck.Text = known
			and (PetConfig.luckText(def.Luck) .. " cleaning luck")
			or "Not discovered yet."
		detail.Visible = true
		PanelKit.popIn(detail, 300, 320)
	end

	------------------------------------------------------------------
	-- TILES
	------------------------------------------------------------------
	local function tile(petId: string, known: boolean, count: number?, equipped: boolean)
		local def = PetConfig.get(petId)
		local info = PetConfig.tierInfo(def.Tier)

		local card = Instance.new("TextButton")
		card.Name = petId
		card.AutoButtonColor = false
		card.Text = ""
		card.BackgroundColor3 = known and darken(info.color, 0.45) or darken(C.sandDeep, 0.45)
		card.BorderSizePixel = 0
		card.LayoutOrder = def.TierIndex * 1000 + def.Index
		card.Parent = scroll
		corner(card, 12)
		outline(card, equipped and 4 or 2)
		if equipped then
			local stroke = card:FindFirstChildWhichIsA("UIStroke")
			if stroke then
				stroke.Color = C.lime
			end
		end

		-- A tier-coloured cap, so rarity is legible without reading a word.
		--[[
			THE TILE IS TWO BANDS, and that is the fix for the release button.

			The name used to run the full width with the X dropped on top of it at
			the top right, so every releasable pet read "PUDDLE DUCKLINGX" and the
			longer names lost a letter to it. Name owns the upper band on its own;
			luck, the count badge and the X share the lower one, in that order from
			the left. Nothing overlaps anything.
		]]
		local cap = Instance.new("Frame")
		cap.Size = UDim2.new(1, 0, 0, 7)
		cap.BackgroundColor3 = known and info.color or darken(C.sandDeep, 0.2)
		cap.BorderSizePixel = 0
		cap.Parent = card
		corner(cap, 6)

		local nm = text(card, known and def.DisplayName or "? ? ?", 15,
			Enum.Font.LuckiestGuy, known and C.white or darken(C.white, 0.5))
		nm.Size = UDim2.new(1, -14, 0, 42)
		nm.Position = UDim2.fromOffset(7, 13)
		nm.TextWrapped = true

		local sub = text(card, known and PetConfig.luckText(def.Luck) or "",
			13, Enum.Font.GothamBold, known and info.glow or C.white)
		sub.Size = UDim2.fromOffset(72, 18)
		sub.Position = UDim2.new(0, 9, 1, -26)
		sub.TextXAlignment = Enum.TextXAlignment.Left

		if count and count > 1 then
			local badge = text(card, "x" .. count, 13, Enum.Font.LuckiestGuy, C.ink)
			badge.Size = UDim2.fromOffset(34, 20)
			-- Slides right when there is no X beside it, so an equipped tile does
			-- not wear a hole where the release button would have been.
			badge.Position = UDim2.new(1, equipped and -42 or -76, 1, -27)
			badge.BackgroundColor3 = C.sun
			badge.BackgroundTransparency = 0
			badge.ZIndex = 3
			corner(badge, 6)
		end
		return card
	end

	------------------------------------------------------------------
	-- REBUILD
	------------------------------------------------------------------
	function rebuild()
		for _, c in scroll:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end

		for name, b in chips do
			local on = (view == name)
			-- The off chip is cut into the board like the sockets are, so the live
			-- one is the only lit thing in the row.
			b.BackgroundColor3 = on and TINT or Color3.fromRGB(48, 31, 19)
			b.TextColor3 = on and C.white or Color3.fromRGB(152, 130, 106)
		end

		if view == "Collection" then
			-- Best first, so the pet you want is where your eye already is.
			local order = {}
			for petId, n in state.owned do
				if PetConfig.get(petId) and n > 0 then
					table.insert(order, petId)
				end
			end
			table.sort(order, function(a, b)
				local da, db = PetConfig.Pets[a], PetConfig.Pets[b]
				if da.Luck ~= db.Luck then
					return da.Luck > db.Luck
				end
				return da.PetId < db.PetId
			end)

			for _, petId in order do
				local equipped = table.find(state.equipped, petId) ~= nil
				local card = tile(petId, true, state.owned[petId], equipped)
				card.Activated:Connect(function()
					send({ petId = petId, equip = not equipped })
				end)

				-- Release. Refuses on an equipped pet server-side too -- this
				-- just does not offer the button, so the refusal is rare.
				if not equipped then
					local x = Instance.new("TextButton")
					-- Bottom right, in the badge row. See THE TILE IS TWO BANDS.
					x.Size = UDim2.fromOffset(24, 24)
					x.Position = UDim2.new(1, -32, 1, -30)
					x.BackgroundColor3 = C.coralDark
					x.BorderSizePixel = 0
					x.Font = Enum.Font.LuckiestGuy
					x.TextSize = 15
					x.TextColor3 = C.white
					x.Text = "X"
					x.ZIndex = 4
					x.Parent = card
					corner(x, 6)
					x.Activated:Connect(function()
						send({ action = "release", petId = petId })
					end)
				end
			end

			emptyMsg.Visible = (#order == 0)
			emptyHint.Visible = emptyMsg.Visible
			progress.Text = string.format("%d pets  ·  %d different",
				state.ownedCount or 0, #order)
		else
			emptyMsg.Visible = false
			emptyHint.Visible = false
			local seen = 0
			for _, petId in PetConfig.Order do
				local known = state.discovered[petId] == true
				if known then
					seen += 1
				end
				local card = tile(petId, known, nil, false)
				card.Activated:Connect(function()
					openDetail(petId, known)
				end)
			end
			progress.Text = string.format("%d / %d discovered", seen, PetConfig.Count)
		end
	end

	------------------------------------------------------------------
	-- APPLY A SNAPSHOT
	------------------------------------------------------------------
	local function apply(snap)
		state.owned = snap.owned or {}
		state.equipped = snap.equipped or {}
		state.discovered = snap.discovered or {}
		state.luck = snap.luck or 1
		state.ownedCount = snap.ownedCount or 0
		state.maxEquipped = snap.maxEquipped or PetConfig.MaxEquipped
		state.maxOwned = snap.maxOwned or PetConfig.MaxOwned

		for i, slot in slots do
			local petId = state.equipped[i]
			if slot.petId ~= petId then
				slot.petId = petId
				showPet(slot.vp, petId)
			end
			slot.empty.Visible = petId == nil
			slot.name.Text = petId and (PetConfig.get(petId) and PetConfig.get(petId).DisplayName or petId) or ""
			local stroke = slot.tile:FindFirstChildWhichIsA("UIStroke")
			if stroke then
				local def = petId and PetConfig.get(petId)
				stroke.Color = def and PetConfig.tierColor(def.Tier) or C.ink
			end
		end

	-- No clover here either. Taking the glyph out of the label this writes over
	-- was the whole point, and it went straight back on at the first refresh --
	-- a build-time string is only ever the placeholder for a live one.
	luckText.Text = PetConfig.luckText(state.luck) .. " CLEANING LUCK"

		local full = state.ownedCount >= state.maxOwned
		capText.Text = string.format("%d / %d", state.ownedCount, state.maxOwned)
		capText.TextColor3 = full and C.coralDark or C.ink

		if root.Visible then
			rebuild()
		end
	end

	Net.get("PetSync").OnClientEvent:Connect(function(snap)
		if type(snap) == "table" then
			apply(snap)
		end
	end)

	panels.Pets.refresh = rebuild
	rebuild()
	return panels.Pets
end

return PetsPanel
