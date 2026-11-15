--[[
	FeedbackAdminHud  --  StarterPlayerScripts.FeedbackAdminHud

	The admin panel. Press F2. Two tabs:

		FEEDBACK   what players wrote, with the device and progress they wrote
		           it from, and a delete for each one
		CURRENCY   hand coins to somebody in this server

	NOTHING IS BUILT FOR A NON-ADMIN
	--------------------------------
	On start this asks the server one question -- "may I?" -- and only builds the
	ScreenGui if the answer is yes. So on an ordinary player's client the panel
	does not exist to be found, unhidden or fired at, and the key does nothing.

	That is convenience, NOT the security. FeedbackServer decides who may read,
	delete or grant, and re-checks on every single call; a client that fabricates
	the whole of this file still gets "Not authorised". Building nothing here
	just means an exploiter has nothing to notice in the first place.

	F2 BECAUSE IT IS FREE. The game binds A, B, D, E, F, Q and Backspace, and F9
	is Roblox's own developer console. F2 collides with neither.

	EVERY DESTRUCTIVE OR ECONOMIC BUTTON TAKES TWO PRESSES. See `arm` -- one
	mis-click should not delete a bug report or move the economy.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local PanelKit = require(Modules:WaitForChild("PanelKit"))
local UiFit = require(Modules:WaitForChild("UiFit"))

--[[
	THE SAME CATALOGUES THE GAME USES, not a copy. What can be given is whatever
	these currently list, so a track added or removed by somebody else shows up
	here without this file being touched -- which matters: Tracks went from eight
	entries to four while this was being written.

	AtvConfig sits at the top of ReplicatedStorage rather than under Modules, and
	is optional: if the car system is ever pulled, the VEHICLE chip simply offers
	nothing instead of this file failing to load.
]]
local ProgressionConfig = require(Modules:WaitForChild("ProgressionConfig"))
local PetConfig = require(Modules:WaitForChild("PetConfig"))

-- Touch targets: see the module. Substituted for MouseButton1Click/Activated so
-- a tap in the margin around a control that renders under 44px on a phone still
-- reaches the same handler. No-ops on desktop and on controls already big enough.
local TouchFit = require(Modules:WaitForChild("TouchFit"))
local AtvConfig = (function()
	local m = ReplicatedStorage:FindFirstChild("AtvConfig")
	local ok, cfg = pcall(function() return m and require(m) end)
	return ok and cfg or nil
end)()

local C = PanelKit.C
local corner = PanelKit.corner
local outline = PanelKit.outline
local grad = PanelKit.grad
local text = PanelKit.text
local chunky = PanelKit.chunky
local punch = PanelKit.punch
local retint = PanelKit.retint

local player = Players.LocalPlayer

local FeedbackAdminHud = {}

local W, H = 720, 560
local TOP_H = 40
local KEY = Enum.KeyCode.F2
--[[
	THIS PANEL DRAWS ON TWO SURFACES, AND THEY WANT OPPOSITE INK.

	The feedback CARDS are white-to-sand, so `DIM` -- and `C.ink` beside it --
	read on them exactly as they were meant to. But `PanelKit.card` lays a dark
	wood WELL under the body, and anything parented straight to a pane rather
	than to a card is printed on THAT: a gradient from (66, 42, 26) to
	(104, 70, 44).

	Measured against the well's midpoint, the cream-scheme colours do not
	survive the trip -- `C.ink` (56, 36, 20) is 1.38:1, which is darker than the
	board it sits on, and `DIM` is 2.15:1. The two below are the same ink at the
	values that board needs: 6.9:1 and 3.6:1.

	So: DIM and C.ink on a card, these two on a pane. MenuHud's rebirth panel
	carries the same note for the same reason.
]]
local DIM = Color3.fromRGB(132, 108, 82)
local ON_WELL = Color3.fromRGB(226, 206, 176)
local DIM_WELL = Color3.fromRGB(168, 146, 118)

-- How long an armed button stays armed. Short enough that walking away cannot
-- leave one live, long enough to read the word SURE.
local ARM_FOR = 4

-- Mirrors FeedbackServer's MAX_GRANT. A copy, and knowingly so: this one is
-- here to stop a typo before it costs a round trip, and the server's is the one
-- that decides.
local MAX_GRANT = 1000000

local gui, root, body, status, refreshLbl
local panes, tabBtns = {}, {}
local list                       -- the feedback scroller
local rowHolder, selLabel, amountBox, grantLbl, grantResult
local tab = "feedback"
local open = false
local admin = false
local busy = false
local remotes
local started = false

local shown = {}
local listedCount = 0
local selectedId, selectedName = nil, nil
local rows = {}

--[[
	WHAT is being given, and WHICH one of it.

	`amount` is the placeholder shown in the box, and nil means the box is not
	shown at all -- a pet has no quantity and an amount field beside one is an
	invitation to type a number that gets ignored. `list` says whether there is a
	catalogue to choose from.
]]
local KINDS = {
	{ id = "coins",   label = "COINS",   amount = "How many coins?", list = false },
	{ id = "level",   label = "UPGRADE", amount = "Level",           list = true },
	{ id = "rebirth", label = "REBIRTH", amount = "How many?",       list = false },
	{ id = "pet",     label = "PET",     amount = nil,               list = true },
	{ id = "vehicle", label = "VEHICLE", amount = nil,               list = true },
	-- NEITHER A LIST NOR AN AMOUNT, which the panel already handles: the option
	-- list is hidden when `list` is false and the number box when `amount` is
	-- nil, so this chip is the target picker and one press. There is nothing to
	-- choose -- the verb takes no argument, it just puts the onboarding back.
	{ id = "tutorial", label = "TUTORIAL", amount = nil,              list = false },
	--[[
		THE SAME RESET, PLUS THE ONE FACT THE LAST STEP NEEDS.

		TUTORIAL above replays the card and deliberately touches no levels. That
		is the right default, and it is also why it cannot show the LAST step to
		anybody who has ever bought an upgrade: the card's final ask is "buy
		Sifter Width", and the shop's steer for it -- the pulsing row and the three
		LOCKED ones -- is gated on that track never having been bought. On a dev
		account, where every track is stamped to 60 on join, that step is
		unreachable. This one puts the track back too. See FeedbackServer.
	]]
	{ id = "onboarding", label = "ONBOARDING", amount = nil,          list = false },
}
local KIND_BY_ID = {}
for _, k in KINDS do
	KIND_BY_ID[k.id] = k
end

local kind = "coins"
local chosenKey, chosenName = nil, nil
local kindChips, optionRows = {}, {}
local optionList, boxHolder, grantHolder, chipRow
--[[
	Where the kind grid ends, in `right`'s coordinates -- everything under it is
	positioned from this rather than from a typed constant, because the grid grew
	a second row when ONBOARDING made seven chips.

	A NUMBER AT MODULE SCOPE, not a reach into the frame. setKind is defined well
	above the builder, so `kindRow` is a local it cannot see: reading
	`kindRow.Size` from in there indexed a nil GLOBAL and threw on every call --
	which is not a layout bug, it is setKind never completing. The symptom was
	the whole grant tab going inert: no chip ever lit, and PET/UPGRADE/VEHICLE
	showed no catalogue, because the line that populates it is past the throw.

	Seeded with the one-row value so the first paint is sane even if something
	somehow calls setKind before the builder has run.
]]
local kindsBottom = 26 + 26 + 6

--------------------------------------------------------------------------
-- FORMATTING
--------------------------------------------------------------------------
local function comma(n: any): string
	if type(n) ~= "number" then
		return tostring(n)
	end
	local s = tostring(math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (s:gsub("^,", ""))
end

-- Drops the empties rather than leaving "Desktop  ·    ·  60 fps" where a
-- field was absent. Every line on a card is built through this.
local function join(sep: string, parts: { any }): string
	local out = {}
	for _, p in parts do
		if p ~= nil and p ~= "" then
			out[#out + 1] = tostring(p)
		end
	end
	return table.concat(out, sep)
end

--[[
	TextTruncate is reset to None. PanelKit.text sets AtEnd, which is right for
	a one-line pill and wrong for everything wrapped: with it on, a label stops
	at the first line and puts an ellipsis on a message that had four more to go.
]]
local function wrap(parent: Instance, str: string, size: number, font: Enum.Font,
	colour: Color3, order: number?)

	local l = text(parent, str, size, font, colour)
	l.Size = UDim2.new(1, 0, 0, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.TextWrapped = true
	l.TextTruncate = Enum.TextTruncate.None
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.LayoutOrder = order or 1
	return l
end

--------------------------------------------------------------------------
-- TWO-PRESS GUARD
--------------------------------------------------------------------------
--[[
	Shared by DELETE and GRANT, which are the only two buttons in the game that
	cannot simply be pressed again to undo: RemoveAsync has no counterpart, and a
	grant that went to the wrong person cannot be pulled back from here.

	The visuals are passed in rather than done here because the two buttons are
	painted differently -- the delete is a flat frame, the grant is a chunky one
	whose fill is a baked UIGradient that has to be retinted rather than
	recoloured, or it comes out mud.
]]
local function arm(face: GuiButton, lbl: TextLabel, setIdle: () -> (),
	setArmed: () -> (), onFire: () -> ())

	local armed, timer = false, nil

	local function standDown()
		armed = false
		-- The row may have been destroyed by a re-render while this was armed.
		if lbl.Parent then
			setIdle()
		end
	end

	TouchFit.press(face, function()
		if not armed then
			armed = true
			setArmed()
			timer = task.delay(ARM_FOR, function()
				if armed then
					standDown()
				end
			end)
			return
		end
		if timer then
			task.cancel(timer)
			timer = nil
		end
		armed = false
		lbl.Text = "\226\128\166"
		onFire()
	end)

	return standDown
end

--------------------------------------------------------------------------
-- FEEDBACK TAB
--------------------------------------------------------------------------
local function requestDelete(key: string?)
	if remotes and key then
		remotes.AdminDelete:FireServer(key)
	end
end

local function deleteButton(parent: GuiObject, key: string?)
	local btn = Instance.new("TextButton")
	btn.Name = "Delete"
	btn.AnchorPoint = Vector2.new(1, 0.5)
	btn.Position = UDim2.new(1, 0, 0.5, 0)
	btn.Size = UDim2.fromOffset(68, 22)
	btn.BackgroundColor3 = C.sand
	btn.AutoButtonColor = false
	btn.Text = ""
	btn.BorderSizePixel = 0
	btn.ZIndex = 6
	btn.Parent = parent
	corner(btn, 8)
	outline(btn, 2)

	local lbl = text(btn, "DELETE", 11, Enum.Font.GothamBold, C.wood)
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.ZIndex = 7

	arm(btn, lbl,
		function()
			lbl.Text = "DELETE"
			lbl.TextColor3 = C.wood
			btn.BackgroundColor3 = C.sand
		end,
		function()
			lbl.Text = "SURE?"
			lbl.TextColor3 = C.white
			btn.BackgroundColor3 = C.coral
		end,
		function()
			requestDelete(key)
		end)
	return btn
end

local function addCard(e, order: number)
	local c = e.client or {}
	local s = e.server or {}

	local card = Instance.new("Frame")
	card.Name = "Entry"
	-- -12 leaves the scrollbar its channel; a full-width card draws under it.
	card.Size = UDim2.new(1, -12, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3 = C.white
	card.BorderSizePixel = 0
	card.LayoutOrder = order
	card.Parent = list
	corner(card, 14)
	outline(card, 3)
	grad(card, C.white, C.sand)

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 11)
	pad.PaddingBottom = UDim.new(0, 12)
	pad.PaddingLeft = UDim.new(0, 13)
	pad.PaddingRight = UDim.new(0, 13)
	pad.Parent = card

	local ly = Instance.new("UIListLayout")
	ly.SortOrder = Enum.SortOrder.LayoutOrder
	ly.Padding = UDim.new(0, 4)
	ly.Parent = card

	--[[
		The header is a ROW, not a label, because the delete button has to live
		in it. A UIListLayout lays out every GuiObject child it has and there is
		no way to exempt one, so anything that must sit beside the text rather
		than under it has to share a container with it.
	]]
	local head = Instance.new("Frame")
	head.Name = "Head"
	head.Size = UDim2.new(1, 0, 0, 22)
	head.BackgroundTransparency = 1
	head.LayoutOrder = 1
	head.Parent = card

	local title = text(head, join("   ", {
		e.displayName or e.name or "Unknown",
		"@" .. tostring(e.name or "?"),
		e.when,
		e.studio and "[studio]" or nil,
	}), 15, Enum.Font.LuckiestGuy, C.ink)
	-- Stops short of the button rather than running under it. TextTruncate is
	-- left at PanelKit's AtEnd here: this one IS a single line.
	title.Size = UDim2.new(1, -78, 1, 0)
	title.TextXAlignment = Enum.TextXAlignment.Left

	deleteButton(head, e._key)

	-- The message is the thing you opened this to read, so it is the only line
	-- on the card at body size and full ink.
	wrap(card, e.text or "", 15, Enum.Font.GothamMedium, C.ink, 2)

	local device = join("  \226\128\162  ", {
		c.platform, c.viewport,
		c.quality and ("quality " .. tostring(c.quality)) or nil,
		c.fps and (math.floor(c.fps) .. " fps"
			.. (c.fpsLow and (" / low " .. math.floor(c.fpsLow)) or "")) or nil,
		c.memoryMb and (math.floor(c.memoryMb) .. " MB") or nil,
	})
	if device ~= "" then
		wrap(card, device, 12, Enum.Font.GothamBold, DIM, 3)
	end

	local who = join("  \226\128\162  ", {
		s.accountAge and (comma(s.accountAge) .. "d old") or nil,
		s.membership, c.locale,
		(c.systemLocale and c.systemLocale ~= c.locale) and ("device " .. c.systemLocale) or nil,
		s.sessionMin and (s.sessionMin .. " min in") or nil,
		s.coins and (comma(s.coins) .. " coins") or nil,
		s.rebirths and ("rebirth " .. tostring(s.rebirths)) or nil,
	})
	if who ~= "" then
		wrap(card, who, 12, Enum.Font.GothamBold, DIM, 4)
	end

	if type(s.levels) == "table" then
		local names = {}
		for k in s.levels do names[#names + 1] = k end
		table.sort(names)
		local bits = {}
		for _, k in names do bits[#bits + 1] = k .. " " .. tostring(s.levels[k]) end
		if #bits > 0 then
			wrap(card, "levels   " .. table.concat(bits, "   "), 11, Enum.Font.Gotham, DIM, 5)
		end
	end

	if type(c.settings) == "table" then
		local names = {}
		for k in c.settings do names[#names + 1] = k end
		table.sort(names)
		local bits = {}
		for _, k in names do bits[#bits + 1] = k .. " " .. (c.settings[k] and "on" or "off") end
		if #bits > 0 then
			wrap(card, "settings   " .. table.concat(bits, "   "), 11, Enum.Font.Gotham, DIM, 6)
		end
	end
end

local function clearList()
	for _, c in list:GetChildren() do
		-- The UIListLayout is a child too, and destroying it would leave every
		-- card stacked at the top of the frame.
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local function render(data)
	clearList()

	if not data.ok then
		local why = data.reason or "Could not read the store."
		status.Text = why
		wrap(list, why, 15, Enum.Font.GothamMedium, ON_WELL, 1)
		return
	end

	shown = data.entries or {}
	listedCount = data.listed or #shown

	status.Text = join("   \226\128\162   ", {
		#shown .. " shown",
		(listedCount > #shown) and (listedCount .. " in the store") or nil,
		data.cached and "cached" or "fresh",
	})

	if #shown == 0 then
		wrap(list, "No feedback yet.", 15, Enum.Font.GothamMedium, DIM_WELL, 1)
		return
	end
	for i, e in shown do
		addCard(e, i)
	end
end

-- Redraw from what is already in hand, without asking the server again.
local function repaint()
	render({ ok = true, entries = shown, listed = listedCount, cached = true })
end

local function fetch()
	if busy or not remotes then
		return
	end
	busy = true
	refreshLbl.Text = "\226\128\166"
	status.Text = "Reading the store\226\128\166"
	remotes.AdminFetch:FireServer({})

	-- The server answers every fetch, but a reply that never arrives must not
	-- leave the button dead for the rest of the session. Generous, because a
	-- cold read is a ListKeys plus up to forty GetAsync.
	task.delay(25, function()
		if busy then
			busy = false
			refreshLbl.Text = "REFRESH"
			status.Text = "No answer from the server."
		end
	end)
end

--------------------------------------------------------------------------
-- GIVE TAB
--------------------------------------------------------------------------
-- One row shape for both lists on this tab -- the players on the left and the
-- catalogue on the right. They are the same object: a name, something small and
-- dim on the right, and a selected state.
local function listRow(parent: Instance, title: string, right: string?, order: number,
	onClick: () -> ())

	local f = Instance.new("TextButton")
	f.Name = title
	f.Size = UDim2.new(1, -10, 0, 36)
	f.BackgroundColor3 = C.white
	f.AutoButtonColor = false
	f.Text = ""
	f.BorderSizePixel = 0
	f.LayoutOrder = order
	f.Parent = parent
	corner(f, 9)
	outline(f, 2.5)

	local n = text(f, title, 13, Enum.Font.GothamBold, C.ink)
	n.Size = UDim2.new(1, -100, 1, 0)
	n.Position = UDim2.fromOffset(10, 0)
	n.TextXAlignment = Enum.TextXAlignment.Left
	n.ZIndex = 6

	local r = text(f, right or "", 12, Enum.Font.GothamBold, DIM)
	r.AnchorPoint = Vector2.new(1, 0)
	r.Size = UDim2.fromOffset(84, 36)
	r.Position = UDim2.new(1, -10, 0, 0)
	r.TextXAlignment = Enum.TextXAlignment.Right
	r.ZIndex = 6

	TouchFit.press(f, onClick)
	return { frame = f, name = n, right = r }
end

local function paintSelection(set, isOn: (any) -> boolean)
	for _, r in set do
		local on = isOn(r)
		r.frame.BackgroundColor3 = on and C.sea or C.white
		r.name.TextColor3 = on and C.white or C.ink
		r.right.TextColor3 = on and C.white or DIM
	end
end

local function paintRows()
	paintSelection(rows, function(r) return r.id == selectedId end)
	selLabel.Text = selectedName and ("Giving to:  " .. selectedName)
		or "Pick somebody on the left."
end

local function paintOptions()
	paintSelection(optionRows, function(r) return r.key == chosenKey end)
end

local function selectPlayer(id: number?, name: string?)
	selectedId, selectedName = id, name
	paintRows()
end

local function buildRows()
	for _, c in rowHolder:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	rows = {}

	local online = Players:GetPlayers()
	table.sort(online, function(x, y) return x.Name:lower() < y.Name:lower() end)

	-- 0 is everyone in THIS server. Coins are not persisted in this game, so
	-- there is no such thing as crediting somebody who is not here.
	local r = listRow(rowHolder, "Everyone here", #online .. " online", 0, function()
		selectPlayer(0, "Everyone here")
	end)
	r.id = 0
	rows[#rows + 1] = r

	for i, p in online do
		local id, nm = p.UserId, p.Name
		local row = listRow(rowHolder, nm, comma(p:GetAttribute("Coins") or 0), i, function()
			selectPlayer(id, nm)
		end)
		row.id = id
		rows[#rows + 1] = row
	end

	-- A selection that has left the server would send a grant nobody receives.
	if selectedId ~= nil and selectedId ~= 0 and not Players:GetPlayerByUserId(selectedId) then
		selectPlayer(nil, nil)
	else
		paintRows()
	end
end

--[[
	THE CATALOGUE FOR A KIND, built from the live config every time it is opened
	rather than cached at boot. Somebody else edits these modules while the game
	is open, which is not hypothetical: four upgrade tracks disappeared during
	the writing of this file.
]]
local function optionsFor(k: string)
	local out = {}
	if k == "level" then
		for _, t in (ProgressionConfig and ProgressionConfig.Tracks or {}) do
			out[#out + 1] = { key = t.key, name = t.name or t.key, right = nil }
		end
	elseif k == "pet" then
		local order = PetConfig and PetConfig.Order or {}
		for _, id in order do
			local def = PetConfig.Pets and PetConfig.Pets[id]
			out[#out + 1] = {
				key = id,
				name = (def and def.DisplayName) or id,
				right = def and def.Tier or nil,
			}
		end
	elseif k == "vehicle" then
		for _, t in (AtvConfig and AtvConfig.Tiers or {}) do
			out[#out + 1] = {
				key = tostring(t.id),
				name = t.name or ("Tier " .. tostring(t.id)),
				right = t.price and comma(t.price) or nil,
			}
		end
	end
	return out
end

local function buildOptions()
	for _, c in optionList:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	optionRows = {}

	local opts = optionsFor(kind)
	if #opts == 0 then
		wrap(optionList, "Nothing to give here.", 13, Enum.Font.GothamMedium, DIM_WELL, 1)
		return
	end
	for i, o in opts do
		local row = listRow(optionList, o.name, o.right, i, function()
			chosenKey, chosenName = o.key, o.name
			paintOptions()
		end)
		row.key = o.key
		optionRows[#optionRows + 1] = row
	end
	paintOptions()
end

local function requestGrant()
	if not remotes then
		return
	end
	local spec = KIND_BY_ID[kind]
	grantLbl.Text = "GIVE"

	if selectedId == nil then
		grantResult.Text = "Pick somebody on the left first."
		grantResult.TextColor3 = C.coral
		return
	end
	if spec.list and chosenKey == nil then
		grantResult.Text = "Pick which one first."
		grantResult.TextColor3 = C.coral
		return
	end

	local amount = nil
	if spec.amount then
		amount = tonumber(amountBox.Text)
		if not amount then
			grantResult.Text = "Type a number first."
			grantResult.TextColor3 = C.coral
			return
		end
		amount = math.floor(amount)
	end

	grantResult.Text = "Sending\226\128\166"
	grantResult.TextColor3 = DIM_WELL
	remotes.AdminGrant:FireServer({
		target = selectedId,
		kind = kind,
		key = spec.list and chosenKey or nil,
		amount = amount,
	})
end

--[[
	Switching what is being given moves the controls under it rather than
	leaving a hole: with no catalogue to show, the amount box and the button
	come up to where the list would have been. A panel with 200px of nothing in
	the middle of it reads as one that failed to load.
]]
local function setKind(id: string)
	local spec = KIND_BY_ID[id]
	if not spec then
		return
	end
	kind = id
	chosenKey, chosenName = nil, nil

	for k, c in kindChips do
		local on = (k == id)
		c.face.BackgroundColor3 = on and C.sea or C.sand
		c.label.TextColor3 = on and C.white or C.wood
	end

	optionList.Visible = spec.list
	boxHolder.Visible = spec.amount ~= nil
	amountBox.PlaceholderText = spec.amount or ""
	amountBox.Text = ""

	if spec.amount then
		local hint = spec.amount
		if id == "level" then
			hint = string.format("Level 0 to %d", (ProgressionConfig and ProgressionConfig.MaxLevel) or 60)
		elseif id == "rebirth" then
			-- SanityCap, not a game ceiling -- the tide ladder is uncapped and this
			-- is only the number FeedbackServer's own guard refuses above. Same
			-- source on both sides so the box cannot offer a grant the server
			-- would bounce.
			hint = string.format("0 to %d", (ProgressionConfig and ProgressionConfig.Rebirth
				and ProgressionConfig.Rebirth.SanityCap) or 1000)
		end
		amountBox.PlaceholderText = hint
	end

	-- Both measured off the bottom of the kind grid rather than typed, so a
	-- seventh chip wrapping onto a second row moved these with it.
	local y = spec.list and (kindsBottom + optionList.Size.Y.Offset + 8) or kindsBottom
	boxHolder.Position = UDim2.fromOffset(0, y)
	local gy = y + (spec.amount and 48 or 0)
	-- The quick amounts are coin-shaped: 100 / 1K / 10K / 100K means nothing
	-- against a level ceiling of 60 or the handful of tides worth typing.
	chipRow.Visible = (id == "coins")
	if chipRow.Visible then
		chipRow.Position = UDim2.fromOffset(0, gy)
		gy += 34
	end
	grantHolder.Position = UDim2.fromOffset(0, gy)
	grantResult.Position = UDim2.fromOffset(0, gy + 58)
	grantResult.Text = ""

	if spec.list then
		buildOptions()
	else
		-- Cleared, not merely hidden. The rows belong to the kind that built
		-- them, so switching to REBIRTH would otherwise keep a hidden list of
		-- upgrade tracks parented behind it for the rest of the session.
		for _, c in optionList:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		optionRows = {}
	end
end

--------------------------------------------------------------------------
-- TABS
--------------------------------------------------------------------------
local function setTab(name: string)
	tab = name
	for key, p in panes do
		p.Visible = (key == name)
	end
	for key, b in tabBtns do
		local on = (key == name)
		b.face.BackgroundColor3 = on and C.sea or C.sand
		b.label.TextColor3 = on and C.white or C.wood
	end
	if name == "feedback" then
		refreshLbl.Text = "REFRESH"
		status.Text = (#shown > 0) and status.Text or "Press REFRESH to read the store."
		if #shown == 0 and not busy then
			fetch()
		end
	else
		refreshLbl.Text = "REFRESH"
		status.Text = "Given to players in this server only."
		buildRows()
		setKind(kind)
	end
end

local function setOpen(v: boolean)
	if not root or open == v then
		return
	end
	open = v
	if open then
		PanelKit.popIn(root, W, H)
		setTab(tab)
	else
		root.Visible = false
	end
end

--------------------------------------------------------------------------
-- BUILD
--------------------------------------------------------------------------
local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FeedbackAdmin"
	gui.ResetOnSpawn = false
	-- Above MenuHud (12) and FeedbackHud (14): this is a tool held over the
	-- game, not part of it.
	gui.DisplayOrder = 20
	gui.IgnoreGuiInset = true
	gui.Parent = player:WaitForChild("PlayerGui")

	local card, cardBody, closeFace = PanelKit.card(gui, "Admin", W, H, C.sea)
	root, body = card, cardBody
	root.Visible = false
	TouchFit.press(closeFace, function()
		setOpen(false)
	end)

	----------------------------------------------------------------
	-- top bar
	----------------------------------------------------------------
	local function tabButton(key: string, label: string, x: number)
		local b = Instance.new("TextButton")
		-- "feedbackTab", not "feedback": the PANE is called "feedback", and two
		-- siblings under Body sharing a name means FindFirstChild returns
		-- whichever was built first -- the button -- to anyone who ever looks
		-- one up by name. Nothing here does, which is exactly how a trap like
		-- that survives to catch someone else.
		b.Name = key .. "Tab"
		b.Size = UDim2.fromOffset(112, 30)
		b.Position = UDim2.fromOffset(x, 2)
		b.BackgroundColor3 = C.sand
		b.AutoButtonColor = false
		b.Text = ""
		b.BorderSizePixel = 0
		b.Parent = body
		corner(b, 9)
		outline(b, 2.5)
		local l = text(b, label, 13, Enum.Font.GothamBold, C.wood)
		l.Size = UDim2.fromScale(1, 1)
		l.ZIndex = 6
		TouchFit.press(b, function()
			setTab(key)
		end)
		tabBtns[key] = { face = b, label = l }
	end
	tabButton("feedback", "FEEDBACK", 0)
	tabButton("grant", "CURRENCY", 118)

	status = text(body, "", 13, Enum.Font.GothamBold, DIM_WELL)
	status.Position = UDim2.fromOffset(240, 2)
	status.Size = UDim2.new(1, -382, 0, 30)
	status.TextXAlignment = Enum.TextXAlignment.Left

	local rHolder, rFace = chunky(body, 132, 30, C.lime, 11)
	rHolder.AnchorPoint = Vector2.new(1, 0)
	rHolder.Position = UDim2.new(1, 0, 0, 0)
	refreshLbl = text(rFace, "REFRESH", 14, Enum.Font.LuckiestGuy, C.white)
	refreshLbl.Size = UDim2.fromScale(1, 1)
	refreshLbl.ZIndex = 6
	punch(refreshLbl, 2.5)
	TouchFit.press(rFace, function()
		if tab == "feedback" then
			fetch()
		else
			buildRows()
		end
	end)

	----------------------------------------------------------------
	-- panes
	----------------------------------------------------------------
	local function pane(name: string)
		local p = Instance.new("Frame")
		p.Name = name
		p.Position = UDim2.fromOffset(0, TOP_H + 8)
		p.Size = UDim2.new(1, 0, 1, -(TOP_H + 8))
		p.BackgroundTransparency = 1
		p.Visible = false
		p.Parent = body
		panes[name] = p
		return p
	end

	local fPane = pane("feedback")
	list = Instance.new("ScrollingFrame")
	list.Name = "Entries"
	list.Size = UDim2.fromScale(1, 1)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.ScrollBarThickness = 6
	list.ScrollBarImageColor3 = C.wood
	list.Parent = fPane
	local fly = Instance.new("UIListLayout")
	fly.SortOrder = Enum.SortOrder.LayoutOrder
	fly.Padding = UDim.new(0, 8)
	fly.Parent = list

	local gPane = pane("grant")

	rowHolder = Instance.new("ScrollingFrame")
	rowHolder.Name = "Players"
	rowHolder.Size = UDim2.new(0, 318, 1, 0)
	rowHolder.BackgroundTransparency = 1
	rowHolder.BorderSizePixel = 0
	rowHolder.CanvasSize = UDim2.new()
	rowHolder.AutomaticCanvasSize = Enum.AutomaticSize.Y
	rowHolder.ScrollingDirection = Enum.ScrollingDirection.Y
	rowHolder.ScrollBarThickness = 6
	rowHolder.ScrollBarImageColor3 = C.wood
	rowHolder.Parent = gPane
	local gly = Instance.new("UIListLayout")
	gly.SortOrder = Enum.SortOrder.LayoutOrder
	gly.Padding = UDim.new(0, 6)
	gly.Parent = rowHolder

	local right = Instance.new("Frame")
	right.Name = "Give"
	right.Position = UDim2.fromOffset(334, 0)
	right.Size = UDim2.new(1, -334, 1, 0)
	right.BackgroundTransparency = 1
	right.Parent = gPane

	selLabel = text(right, "Pick somebody on the left.", 14, Enum.Font.GothamBold, ON_WELL)
	selLabel.Size = UDim2.new(1, 0, 0, 22)
	selLabel.TextXAlignment = Enum.TextXAlignment.Left

	--[[
		WHAT is being given. A GRID, and it has to be one now.

		This was a horizontal UIListLayout of 64px chips, sized when there were
		five of them: 5 x 64 + 4 gaps is 344 in a 362-wide pane. TUTORIAL made six
		and pushed the row to 414 -- fifty-two pixels past the edge, with a
		UIListLayout that does not wrap -- so that chip has been hanging off the
		side. ONBOARDING would be the seventh.

		Four to a row, and the cell width is a SCALE rather than a pixel count.
		That is not tidiness -- the first cut of this typed 84px against a pane I
		had measured at 362, and the pane is really about 351, so a 354px row
		wrapped to THREE per row and the seventh chip fell out of the bottom of a
		frame sized for two. A width of (1/4 of the parent, minus its share of the
		gaps) comes out exact at any pane width: 4 cells plus 3 gaps is the parent,
		whatever the parent turns out to be. The row count below is then a fact
		rather than a hope.

		A quarter of the pane also carries a ten-character label at size 10, which
		"ONBOARDING" needs and the old 64px never did.
	]]
	local KIND_GAP = 6
	local KIND_PER_ROW = 4
	local KIND_CHIP_H = 26
	local kindRows = math.ceil(#KINDS / KIND_PER_ROW)

	local kindRow = Instance.new("Frame")
	kindRow.Name = "Kinds"
	kindRow.Position = UDim2.fromOffset(0, 26)
	kindRow.Size = UDim2.new(1, 0, 0,
		kindRows * KIND_CHIP_H + (kindRows - 1) * KIND_GAP)
	kindRow.BackgroundTransparency = 1
	kindRow.Parent = right
	-- Published for setKind and for the option list below. See its declaration.
	kindsBottom = 26 + kindRow.Size.Y.Offset + 6
	--[[
		The -1 is SLACK AND IT IS LOAD-BEARING. Four cells at exactly a quarter of
		the pane, less their exact share of the gaps, sums to the pane width to the
		pixel -- and UIGridLayout wraps when the next cell does not fit, so "fits
		exactly" loses to a rounding error and drops to three per row. Measured
		doing precisely that: 4 x 66.65 + 3 x 4.8 = 281.0 in a 281 pane, wrapped.
		One pixel per cell buys four pixels of room and settles it.
	]]
	local kly = Instance.new("UIGridLayout")
	kly.CellSize = UDim2.new(
		1 / KIND_PER_ROW, -(KIND_GAP * (KIND_PER_ROW - 1) / KIND_PER_ROW + 1),
		0, KIND_CHIP_H)
	kly.CellPadding = UDim2.fromOffset(KIND_GAP, KIND_GAP)
	kly.SortOrder = Enum.SortOrder.LayoutOrder
	kly.Parent = kindRow

	for i, k in KINDS do
		local kb = Instance.new("TextButton")
		kb.Name = k.id
		-- No Size: UIGridLayout writes it from CellSize.
		kb.BackgroundColor3 = C.sand
		kb.AutoButtonColor = false
		kb.Text = ""
		kb.BorderSizePixel = 0
		kb.LayoutOrder = i
		kb.Parent = kindRow
		corner(kb, 8)
		outline(kb, 2)
		local kl = text(kb, k.label, 10, Enum.Font.GothamBold, C.wood)
		kl.Size = UDim2.fromScale(1, 1)
		kl.ZIndex = 6
		TouchFit.press(kb, function()
			setKind(k.id)
		end)
		kindChips[k.id] = { face = kb, label = kl }
	end

	optionList = Instance.new("ScrollingFrame")
	optionList.Name = "Options"
	-- Under the kind grid, whatever height it came out at.
	optionList.Position = UDim2.fromOffset(0, kindsBottom)
	optionList.Size = UDim2.new(1, 0, 0, 196)
	optionList.BackgroundTransparency = 1
	optionList.BorderSizePixel = 0
	optionList.CanvasSize = UDim2.new()
	optionList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	optionList.ScrollingDirection = Enum.ScrollingDirection.Y
	optionList.ScrollBarThickness = 5
	optionList.ScrollBarImageColor3 = C.wood
	optionList.Parent = right
	local oly = Instance.new("UIListLayout")
	oly.SortOrder = Enum.SortOrder.LayoutOrder
	oly.Padding = UDim.new(0, 5)
	oly.Parent = optionList

	boxHolder = Instance.new("Frame")
	boxHolder.Name = "Amount"
	-- Overwritten by setKind on every switch; this is only what it is built at.
	boxHolder.Position = UDim2.fromOffset(0, kindsBottom + 196 + 8)
	boxHolder.Size = UDim2.new(1, 0, 0, 40)
	boxHolder.BackgroundColor3 = C.white
	boxHolder.BorderSizePixel = 0
	boxHolder.Parent = right
	corner(boxHolder, 11)
	outline(boxHolder, 3)

	amountBox = Instance.new("TextBox")
	amountBox.Name = "AmountBox"
	amountBox.Size = UDim2.fromScale(1, 1)
	amountBox.BackgroundTransparency = 1
	amountBox.ClearTextOnFocus = false
	amountBox.Text = ""
	amountBox.PlaceholderText = "How many coins?"
	amountBox.PlaceholderColor3 = Color3.fromRGB(168, 148, 122)
	amountBox.Font = Enum.Font.GothamBold
	amountBox.TextSize = 16
	amountBox.TextColor3 = C.ink
	amountBox.ZIndex = 6
	amountBox.Parent = boxHolder
	local abPad = Instance.new("UIPadding")
	abPad.PaddingLeft = UDim.new(0, 12)
	abPad.PaddingRight = UDim.new(0, 12)
	abPad.Parent = amountBox

	--[[
		Digits only, and clamped to the ceiling FOR THE KIND being given -- 60
		for a level, SanityCap for rebirths, a million for coins. The server
		re-checks all three; this is so the box cannot show a number it already
		knows the server would refuse.

		THE REBIRTH ONE IS NOT A GAME CEILING and has not been since 2026-09-11:
		the ladder is endless, and SanityCap is only where FeedbackServer's typo
		guard and SaveService's corruption guard both sit. Read it from there
		rather than typing a number, because a box that clamps lower than the
		server silently makes the higher tides ungrantable from this panel.
	]]
	local function kindCeiling(): number
		if kind == "level" then
			return (ProgressionConfig and ProgressionConfig.MaxLevel) or 60
		elseif kind == "rebirth" then
			return (ProgressionConfig and ProgressionConfig.Rebirth
				and ProgressionConfig.Rebirth.SanityCap) or 1000
		end
		return MAX_GRANT
	end

	amountBox:GetPropertyChangedSignal("Text"):Connect(function()
		local cleaned = amountBox.Text:gsub("%D", "")
		if #cleaned > 0 then
			local n = tonumber(cleaned)
			local ceiling = kindCeiling()
			if n and n > ceiling then
				cleaned = tostring(ceiling)
			end
		end
		if cleaned ~= amountBox.Text then
			amountBox.Text = cleaned
		end
	end)

	chipRow = Instance.new("Frame")
	chipRow.Name = "Quick"
	chipRow.Position = UDim2.fromOffset(0, 106)
	chipRow.Size = UDim2.new(1, 0, 0, 28)
	chipRow.BackgroundTransparency = 1
	chipRow.Parent = right
	local cly = Instance.new("UIListLayout")
	cly.FillDirection = Enum.FillDirection.Horizontal
	cly.Padding = UDim.new(0, 6)
	cly.Parent = chipRow

	for i, amt in { 100, 1000, 10000, 100000 } do
		local chip = Instance.new("TextButton")
		chip.Size = UDim2.fromOffset(80, 28)
		chip.BackgroundColor3 = C.sand
		chip.AutoButtonColor = false
		chip.Text = ""
		chip.BorderSizePixel = 0
		chip.LayoutOrder = i
		chip.Parent = chipRow
		corner(chip, 8)
		outline(chip, 2)
		local cl = text(chip, comma(amt), 12, Enum.Font.GothamBold, C.wood)
		cl.Size = UDim2.fromScale(1, 1)
		cl.ZIndex = 6
		TouchFit.press(chip, function()
			amountBox.Text = tostring(amt)
		end)
	end

	local gFace, gSlab
	grantHolder, gFace, gSlab = chunky(right, 220, 42, C.sun, 13)
	grantHolder.Position = UDim2.fromOffset(0, 154)
	grantLbl = text(gFace, "GIVE", 17, Enum.Font.LuckiestGuy, C.white)
	grantLbl.Size = UDim2.fromScale(1, 1)
	grantLbl.ZIndex = 6
	punch(grantLbl, 3)
	arm(gFace, grantLbl,
		function()
			grantLbl.Text = "GIVE"
			retint(gFace, gSlab, C.sun)
		end,
		function()
			-- Every other verb on this panel ADDS something, and the worst a
			-- misfire costs is a player with more coins than they earned.
			-- ONBOARDING is the one that takes everything away, so it does not get
			-- to wear the same word: the armed button says what it is about to do.
			grantLbl.Text = (kind == "onboarding") and "WIPE?" or "SURE?"
			retint(gFace, gSlab, C.coral)
		end,
		requestGrant)

	grantResult = text(right, "", 13, Enum.Font.GothamBold, DIM_WELL)
	grantResult.Position = UDim2.fromOffset(0, 212)
	grantResult.Size = UDim2.new(1, 0, 0, 0)
	grantResult.AutomaticSize = Enum.AutomaticSize.Y
	grantResult.TextWrapped = true
	grantResult.TextTruncate = Enum.TextTruncate.None
	grantResult.TextXAlignment = Enum.TextXAlignment.Left
	grantResult.TextYAlignment = Enum.TextYAlignment.Top

	-- The roster changes under the panel; a stale list would offer a grant to
	-- somebody who has gone.
	local function rosterChanged()
		if gui and panes.grant and panes.grant.Visible then
			buildRows()
		end
	end
	Players.PlayerAdded:Connect(rosterChanged)
	Players.PlayerRemoving:Connect(rosterChanged)

	-- Same scaling as every other panel, so this is usable on a phone too.
	UiFit.fit(gui)
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------
function FeedbackAdminHud.start()
	if started then
		return
	end
	started = true

	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("FeedbackRemotes", 30)
		if not folder then
			warn("[FeedbackAdmin] FeedbackRemotes never appeared -- is FeedbackServer started?")
			return
		end
		remotes = {
			AdminFetch = folder:WaitForChild("AdminFetch"),
			AdminData = folder:WaitForChild("AdminData"),
			AdminDelete = folder:WaitForChild("AdminDelete"),
			AdminGrant = folder:WaitForChild("AdminGrant"),
		}

		remotes.AdminData.OnClientEvent:Connect(function(data)
			if type(data) ~= "table" then
				return
			end

			if data.hello then
				admin = data.ok and true or false
				if admin and not gui then
					build()
					print("[FeedbackAdmin] press F2 for the admin panel")
				end
				return
			end
			if not (admin and gui) then
				return
			end

			--------------------------------------------------
			-- currency replies
			--------------------------------------------------
			if data.granted then
				grantLbl.Text = "GIVE"
				grantResult.Text = string.format("Gave %s to %s.",
					tostring(data.what or "it"),
					(data.names and #data.names > 0) and table.concat(data.names, ", ") or "nobody")
				grantResult.TextColor3 = C.limeDark
				amountBox.Text = ""
				buildRows()      -- balances moved
				return
			end
			if data.grantFailed then
				grantLbl.Text = "GIVE"
				grantResult.Text = data.reason or "Could not do that."
				grantResult.TextColor3 = C.coral
				return
			end

			--------------------------------------------------
			-- feedback replies
			--------------------------------------------------
			--[[
				A FAILED DELETE MUST NOT COST THE LIST.

				Tagged separately from an ordinary refusal because the two want
				opposite things on screen: a fetch that fails has nothing to
				show, so the panel says why; a DELETE that fails still has the
				whole inbox sitting there, and clearing it to print one line
				would throw away what the admin was reading.
			]]
			if data.deleteFailed then
				repaint()
				status.Text = data.reason or "Could not delete that one."
				return
			end

			if data.deleted then
				for i = #shown, 1, -1 do
					if shown[i]._key == data.deleted then
						table.remove(shown, i)
					end
				end
				-- listedCount too: the store really is one shorter, and leaving
				-- it would make the header claim an entry that is gone.
				listedCount = math.max(#shown, listedCount - 1)
				repaint()
				status.Text = "Deleted."
				return
			end

			busy = false
			if refreshLbl then
				refreshLbl.Text = "REFRESH"
			end
			render(data)
		end)

		remotes.AdminFetch:FireServer({ hello = true })
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		-- gameProcessedEvent covers the chat bar, the feedback box and the
		-- amount box: without it, typing in any of them and hitting F2 toggles.
		if gameProcessed or input.KeyCode ~= KEY then
			return
		end
		if not admin then
			return
		end
		setOpen(not open)
	end)
end

-- The door in that is not a keypress, for testing and for anything that wants
-- the panel out of the way.
function FeedbackAdminHud.toggle()
	setOpen(not open)
end

function FeedbackAdminHud.isOpen(): boolean
	return open
end

return FeedbackAdminHud