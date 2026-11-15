--[[
	AtvClient  --  StarterPlayer.StarterPlayerScripts.AtvClient  (LocalScript)

	The car spawner's showroom. Opens when the pad's prompt is triggered, stands
	the stock on plinths turning under the lights -- a bulldozer and a sweeper
	truck -- and sends a TIER NUMBER when a button is pressed.

	TWO WAYS TO PAY, ONE PER BAY. Coins go through AtvBuy the way they always
	have. Robux goes through MarketplaceService directly, because
	PromptGamePassPurchase is a CLIENT call and routing it through a remote would
	buy nothing -- the server learns about the purchase from
	PromptGamePassPurchaseFinished either way, and it asks Roblox rather than
	taking this script's word for it. See GamePassService.
	Nothing else: prices, stats and whether you can afford one are all decided
	again on the server, and this panel is only ever drawing what it was told.

	IT IS DRAWN BY PanelKit, LIKE EVERY OTHER PANEL IN THE GAME.
	-----------------------------------------------------------
	This used to build its own look -- flat slate rectangles, FredokaOne,
	hairline strokes, no shadow slabs, no gloss -- and then a flat list with a
	numbered swatch per row. Both are gone. The shell, the plinths, the
	turntables, the stat bars and the buttons are the SAME PanelKit functions
	the Beach Shop and the Index draw with, so they cannot drift again without
	drifting together.

	THE MACHINES ARE REAL.
	----------------------
	Each plinth turns the machine its builder actually builds, cloned from the
	previews AtvServer parks in ReplicatedStorage at boot. Repaint a tier, move
	its rack, change the dozer's canopy, and the showroom follows with no second
	edit -- the same contract SignKit has with the boards and the wash viewmodel
	has with the tool. The panel never models a vehicle of its own.

	TWO BAYS, AND NOTHING HERE COUNTS TO TWO.
	The bay width, the full-bar mark on every stat and the loop that draws them
	are all off #AtvConfig.Tiers -- which is what let the shop go from four
	machines to two without a layout number moving. A third is a config entry;
	the only numbers below that would need a hand are the card's own width and
	height, which is why they are the first two constants in the file.

	Driving needs no code here at all -- the VehicleSeat replicates Throttle and
	Steer on its own, and AtvServer reads them.
]]

local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local AtvConfig = require(ReplicatedStorage:WaitForChild("AtvConfig"))
local ToastKit = require(Modules:WaitForChild("ToastKit"))
local PanelKit = require(Modules:WaitForChild("PanelKit"))

-- Touch targets: see the module. Substituted for MouseButton1Click/Activated so
-- a tap in the margin around a control that renders under 44px on a phone still
-- reaches the same handler. No-ops on desktop and on controls already big enough.
local TouchFit = require(Modules:WaitForChild("TouchFit"))

local remotes = ReplicatedStorage:WaitForChild("AtvRemotes", 30)
assert(remotes, "[AtvClient] AtvRemotes never appeared -- is AtvServer started?")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local C = PanelKit.C

local function comma(n: number): string
	local s = tostring(math.max(0, math.floor(n)))
	local grouped = (s:reverse():gsub("(%d%d%d)", "%1,"):reverse())
	if grouped:sub(1, 1) == "," then
		grouped = grouped:sub(2)
	end
	return grouped
end

----------------------------------------------------------------
-- WHAT A FULL BAR MEANS
----------------------------------------------------------------
-- The ladder's own top, read off the config rather than written down, so adding
-- a machine re-scales every bar instead of pinning them at a number that is no
-- longer the maximum.
--
local BEST = { net = 0, speed = 0, turn = 0, hold = 1 }
for _, t in AtvConfig.Tiers do
	BEST.net = math.max(BEST.net, t.netRadius)
	BEST.speed = math.max(BEST.speed, t.speed)
	BEST.turn = math.max(BEST.turn, t.turn)
	BEST.hold = math.max(BEST.hold, AtvConfig.holdOf(t))
end

----------------------------------------------------------------
-- PANEL
----------------------------------------------------------------
-- One bay per machine, each running the FULL HEIGHT of the card. The bays used
-- to stop two thirds of the way down and leave a band of bare sand under them,
-- which bought nothing and squeezed both the plinth and the text.
--
-- THE CARD IS SIZED TO THE STOCK, and the stock is two machines now. At the
-- 900 wide the four-machine shop needed, two bays came out 432px each -- a
-- 190px plinth adrift in the middle of a card twice as wide as it needs to be.
-- 560 gives a 256px bay, comfortably wider than the 207 that four had.
--
-- This is the ONLY number that needs a hand when the stock changes; bay width,
-- every bar's full mark and the draw loop are all off #AtvConfig.Tiers.
--
-- PUT AWAY lives in the BANNER, not under the bays. Reserving a slot for it in
-- the body cost 67px of card whether or not a machine was out -- and it is a
-- panel-wide action anyway, so it belongs beside the X rather than below bays
-- it has nothing to do with. That 67px went into the bays.
--
-- Height is the CONTENT: 74 of chrome, 38 of purse, a 10 gap, then the bay.
--
-- STILL 610 WITH A SECOND BUTTON IN EVERY BAY, and that was worth some care.
-- The Robux button needs 46px and the bay had 27 of slack, so the obvious move
-- was 660 -- which would have made this the tallest panel in the game by 60px
-- (the Beach Shop is 640 x 600, the Index 700 x 496) and put it at 92% of a
-- 720-tall viewport. The 30px came out of the PLINTH instead: see PLINTH_H.
local PANEL_W, PANEL_H = 560, 610
local BAY_GAP = 12
local BODY_W, BODY_H = PANEL_W - 36, PANEL_H - 74
local BAY_W = math.floor((BODY_W - BAY_GAP * (#AtvConfig.Tiers - 1)) / #AtvConfig.Tiers)
local BAY_TOP = 48
local BAY_H = BODY_H - BAY_TOP

local gui = Instance.new("ScreenGui")
gui.Name = "AtvPanel"
gui.ResetOnSpawn = false
gui.Enabled = false
-- Above the side button rail. This is a MODAL -- it has a click-off backdrop
-- and its buttons must be reachable -- and MenuHud's rail sits high enough to
-- render straight over the top of it and clip the action column off.
gui.DisplayOrder = 50
-- Global, to match MenuHud: PanelKit numbers its banner and close button
-- through explicitly on the assumption that a child's ZIndex counts for
-- nothing, and under Sibling behaviour those numbers would fight the tree.
gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
gui.Parent = playerGui

local shade = Instance.new("TextButton")   -- click-off backdrop
shade.Size = UDim2.fromScale(1, 1)
shade.BackgroundColor3 = C.ink
shade.BackgroundTransparency = 0.45
shade.AutoButtonColor = false
shade.Text = ""
shade.ZIndex = 0
shade.Parent = gui

--[[
	610 TALL AGAINST A 553 CANVAS on a 750x390 phone -- it hung 28 off the top
	and 28 off the bottom, reported as "The ui is off the screen".

	THIS SCRIPT NO LONGER DOES ANYTHING ABOUT THAT, AND DID NOT BEFORE EITHER.
	It used to follow the line below with UiFit.clampPanel(root, PANEL_W,
	PANEL_H), because this card is built here rather than through MenuHud's
	makePanel and so did not inherit that one's clamp. Neither call ever had an
	effect: PanelKit.card puts its own `SafeFit` UIScale on the root first, and
	Roblox honours only the first UIScale on an object. See UiFit's tombstone.

	PanelKit.card fits the card to the safe area itself, off the w and h passed
	here -- the AUTHORED pair, which still matters: popIn animates the root's
	Size for 0.3s on every open, so a fit read off the live value would solve a
	different panel on each frame of the animation.
]]
local root, body, closeFace, banner = PanelKit.card(gui, "Car Spawner", PANEL_W, PANEL_H, C.foam)

----------------------------------------------------------------
-- THE PURSE
----------------------------------------------------------------
-- The Beach Shop's, part for part, because it is answering the same question
-- in the same place and a second design for it would be a second thing to keep
-- in step.
local purse = Instance.new("Frame")
purse.Name = "Purse"
purse.Size = UDim2.new(1, 0, 0, 38)
purse.BackgroundColor3 = C.white
purse.BorderSizePixel = 0
purse.Parent = body
PanelKit.corner(purse, 14)
PanelKit.outline(purse, 3.5)
PanelKit.grad(purse, C.white, C.sand)

local purseLabel = PanelKit.text(purse, "IN YOUR POCKET", 14, Enum.Font.LuckiestGuy, C.ink)
purseLabel.Position = UDim2.fromOffset(14, 0)
purseLabel.Size = UDim2.new(0.5, -14, 1, 0)
purseLabel.TextXAlignment = Enum.TextXAlignment.Left

local purseAmt = PanelKit.text(purse, "$0", 21, Enum.Font.LuckiestGuy, C.limeDark)
purseAmt.Name = "Coins"
purseAmt.AnchorPoint = Vector2.new(1, 0.5)
purseAmt.Position = UDim2.new(1, -14, 0.5, 0)
purseAmt.Size = UDim2.new(0.5, -28, 1, 0)
purseAmt.TextXAlignment = Enum.TextXAlignment.Right
PanelKit.punch(purseAmt, 2.5)

local tideAmt = PanelKit.text(purse, "", 13, Enum.Font.GothamBold, Color3.fromRGB(132, 108, 82))
tideAmt.AnchorPoint = Vector2.new(0.5, 0.5)
tideAmt.Position = UDim2.fromScale(0.5, 0.5)
tideAmt.Size = UDim2.new(0.4, 0, 1, 0)

----------------------------------------------------------------
-- THE BAYS
----------------------------------------------------------------
local floor = Instance.new("Frame")
floor.Name = "Bays"
floor.Position = UDim2.fromOffset(0, BAY_TOP)
floor.Size = UDim2.new(1, 0, 0, BAY_H)
floor.BackgroundTransparency = 1
floor.Parent = body

local ly = Instance.new("UIListLayout")
ly.FillDirection = Enum.FillDirection.Horizontal
ly.Padding = UDim.new(0, BAY_GAP)
ly.SortOrder = Enum.SortOrder.LayoutOrder
ly.Parent = floor

--[[
	The previews AtvServer built. Waited for rather than assumed: the panel is
	created the moment this script runs, and the folder is written on the server
	inside AtvServer.start -- which usually wins that race and does not have to.
	A missed one leaves an empty plinth, not an error.
]]
local previews = ReplicatedStorage:WaitForChild("AtvPreviews", 20)

--[[
	WHAT EACH GAME PASS COSTS, published by GamePassService as attributes on a
	folder rather than pushed down a remote -- so it is already here when this
	script runs, and a client joining late gets it for free.

	A PRICE IS ALLOWED TO BE MISSING, and that is the case worth handling rather
	than the case worth asserting on: a pass that is off sale has no price at
	all. The button below reads that as "not buyable yet" and says so, instead of
	drawing R$ 0 -- which reads as free and is the one wrong thing a price label
	can say.
]]
local passInfo = ReplicatedStorage:WaitForChild("AtvPassInfo", 20)

local function passPrice(id: number?): number?
	if not (passInfo and id) then
		return nil
	end
	local n = passInfo:GetAttribute("Price_" .. tostring(id))
	return (type(n) == "number" and n > 0) and n or nil
end

local function passOnSale(id: number?): boolean
	if not (passInfo and id) then
		return false
	end
	return passInfo:GetAttribute("ForSale_" .. tostring(id)) == true and passPrice(id) ~= nil
end

-- The bay, top to bottom. Written out because every one of these is measured
-- against the next, and a stack of magic offsets buried in the loop is how a
-- layout stops being adjustable.
--[[
	160, DOWN FROM 190, AND THE MACHINE DID NOT GET SMALLER.

	This is where the Robux button's 46px came from rather than off the bottom of
	the card -- see PANEL_H. It costs less than it sounds: PanelKit.turntable is
	handed (BAY_W - 18) / PLINTH_H as its aspect and frames the model to fit, so
	a shorter, wider window is a shorter, wider window and not a smaller machine.
	At 238 x 160 the aspect goes 1.25 -> 1.49, which suits a thirty stud truck
	BETTER than the squarer box did.

	The 30px comes off every row below in step, so the gaps between them are
	unchanged: 7 under the plinth, 2 under the name, 4 under the blurb and 4
	under the refusal line.
]]
local PLINTH_H = 160
local NAME_Y = 176
-- 52px of blurb, not 38. At the 207px bay a four-machine shop gave, the longest
-- blurb wrapped to three lines and the old two-and-a-half-line box cut the
-- third one off. Kept at the wider bay: the Sandhog's still runs to three.
local BLURB_Y = 202
local WHY_Y = 258
local BARS_Y = 280
local BAR_STEP = 26
local BAR_COUNT = 4

local bays = {}
for i, tier in ipairs(AtvConfig.Tiers) do
	local bay = Instance.new("Frame")
	bay.Name = tier.key
	bay.Size = UDim2.fromOffset(BAY_W, BAY_H)
	bay.BackgroundColor3 = C.white
	bay.BorderSizePixel = 0
	bay.LayoutOrder = i
	bay.Parent = floor
	PanelKit.corner(bay, 18)
	PanelKit.outline(bay, 3.5)
	PanelKit.grad(bay, C.white, C.sand)

	-- The plinth takes the TIER's own paint, so the two bays read as two
	-- machines before a word is read.
	local plinth = PanelKit.plinth(bay, tier.body, 14)
	plinth.Position = UDim2.fromOffset(9, 9)
	plinth.Size = UDim2.fromOffset(BAY_W - 18, PLINTH_H)

	local turn
	local source = previews and previews:FindFirstChild(tier.key)
	if source then
		turn = PanelKit.turntable(plinth, source, {
			aspect = (BAY_W - 18) / PLINTH_H,
			speed = 0.55 + i * 0.05,   -- barely different, so the bays do not lockstep
			zIndex = 7,
		})
	end

	local nm = PanelKit.text(bay, tier.name, 19, Enum.Font.LuckiestGuy, C.ink)
	nm.Position = UDim2.fromOffset(8, NAME_Y)
	nm.Size = UDim2.new(1, -16, 0, 24)

	local bl = PanelKit.text(bay, tier.blurb, 12, Enum.Font.GothamMedium,
		Color3.fromRGB(132, 108, 82))
	bl.Position = UDim2.fromOffset(12, BLURB_Y)
	bl.Size = UDim2.new(1, -24, 0, 52)
	bl.TextWrapped = true
	bl.TextTruncate = Enum.TextTruncate.None

	local stats = Instance.new("Frame")
	stats.Name = "Stats"
	stats.Position = UDim2.fromOffset(12, BARS_Y)
	stats.Size = UDim2.new(1, -24, 0, BAR_STEP * BAR_COUNT)
	stats.BackgroundTransparency = 1
	stats.Parent = bay

	local barW = BAY_W - 24
	local netBar = PanelKit.statBar(stats, "NET", C.sea, barW, 0)
	local spdBar = PanelKit.statBar(stats, "SPEED", C.sun, barW, BAR_STEP)
	local turnBar = PanelKit.statBar(stats, "TURN", C.grape, barW, BAR_STEP * 2)
	local holdBar = PanelKit.statBar(stats, "HOLD", C.lime, barW, BAR_STEP * 3)
	-- Bare numbers, no units. "16 studs" did not fit the value column and came
	-- back "16 stu...", and the label already says which stat it is -- the other
	-- two carry no unit either, so a lone number is the consistent answer.
	netBar:Set(tier.netRadius, BEST.net, tostring(tier.netRadius))
	spdBar:Set(tier.speed, BEST.speed, tostring(tier.speed))
	turnBar:Set(tier.turn, BEST.turn, string.format("%.1f", tier.turn))
	-- HOLD is the stat the ladder is actually built on -- 300 lbs to 650 -- so
	-- it is the bar that carries the reason to save for the second machine,
	-- which is the one thing the two-bay shop has to say.
	holdBar:Set(AtvConfig.holdOf(tier), BEST.hold, tostring(AtvConfig.holdOf(tier)))

	-- The refusal, in a slot of its own between the blurb and the bars -- empty
	-- when there is nothing to say. It used to hang off the bottom edge, where
	-- it landed on top of the bars the moment they arrived.
	local why = PanelKit.text(bay, "", 12, Enum.Font.GothamBold, C.coralDark)
	why.Name = "Why"
	why.Position = UDim2.fromOffset(10, WHY_Y)
	why.Size = UDim2.new(1, -20, 0, 18)

	local holder, face, slab = PanelKit.chunky(bay, BAY_W - 26, 44, C.lime, 15)
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.new(0.5, 0, 1, -3)
	local cost = PanelKit.text(face, "BUY", 19, Enum.Font.LuckiestGuy, C.white)
	cost.Size = UDim2.fromScale(1, 1)
	cost.ZIndex = 6
	PanelKit.punch(cost, 3)

	--[[
		THE OTHER WAY TO PAY.

		ABOVE the coin button, not beside it. At a 256px bay two buttons side by
		side are 122px each, and "$250,000" at a readable weight does not fit in
		122 -- it came back "$250,0...". Stacked, both get the full width and the
		prices stay legible, which is the whole job of a price.

		Grape, so the three states a bay can be in are three colours a player can
		tell apart at a glance without reading any of them: lime you can afford,
		sea you own, grape is real money.
	]]
	local passHolder, passFace, passSlab = PanelKit.chunky(bay, BAY_W - 26, 40, C.grape, 15)
	passHolder.AnchorPoint = Vector2.new(0.5, 1)
	passHolder.Position = UDim2.new(0.5, 0, 1, -53)
	local passCost = PanelKit.text(passFace, "", 17, Enum.Font.LuckiestGuy, C.white)
	passCost.Size = UDim2.fromScale(1, 1)
	passCost.ZIndex = 6
	PanelKit.punch(passCost, 2.5)

	-- The bar handles are KEPT now. They used to be set once here off the tier's
	-- own numbers and never touched again, which stopped being true the moment a
	-- machine's stats started depending on what the player had bought: refresh()
	-- re-Sets all four every time the panel is drawn.
	bays[i] = {
		tier = tier, face = face, slab = slab, cost = cost, why = why, turn = turn,
		netBar = netBar, spdBar = spdBar, turnBar = turnBar, holdBar = holdBar,
		passHolder = passHolder, passFace = passFace, passSlab = passSlab,
		passCost = passCost, passId = AtvConfig.passOf(tier),
	}
end

-- Bare numbers in a 40px column: whole where they are whole (net, hold), one
-- decimal where the ladder moves in halves (Beach Legs' half-stud speeds).
local function stat(n: number): string
	if math.abs(n - math.floor(n + 0.5)) < 0.05 then
		return comma(math.floor(n + 0.5))
	end
	return string.format("%.1f", n)
end

----------------------------------------------------------------
-- PUT AWAY
----------------------------------------------------------------
-- In the BANNER, mirroring the X: it is a panel-wide action, not a per-bay one,
-- and down in the body it cost 67px of reserved card whether or not a machine
-- was out. Only up while one actually is, so the panel never offers to put away
-- something that is not there.
--
-- ZIndexes numbered through by hand for the same reason PanelKit numbers the
-- close button's: this gui runs ZIndexBehavior.Global, where being the banner's
-- child buys nothing and chunky() leaves its parts at 0 -- so an unnumbered
-- button draws UNDER the very banner it sits on.
local awayHolder, awayFace, awaySlab = PanelKit.chunky(banner, 150, 40, C.coral, 13)
awayHolder.AnchorPoint = Vector2.new(0, 0.5)
awayHolder.Position = UDim2.new(0, 12, 0.5, -3)
awayHolder.ZIndex = 7
awaySlab.ZIndex = 7
awayFace.ZIndex = 8
local awayText = PanelKit.text(awayFace, "PUT AWAY", 16, Enum.Font.LuckiestGuy, C.white)
awayText.Size = UDim2.fromScale(1, 1)
awayText.ZIndex = 9
PanelKit.punch(awayText, 2.5)

----------------------------------------------------------------
-- STATE -> PANEL
----------------------------------------------------------------
local state = { owned = 0, coins = 0, rebirths = 0, riding = false }

-- THE ONE BALANCE, and the rest of the player's own state with it.
--
-- `owned`, `coins` and `rebirths` are all plain player attributes that
-- replicate to us, so the AtvMenu push is not the only way to learn them -- and
-- it was never a good one. It fires once, when the pad's prompt is triggered,
-- and nothing refreshes it afterwards: sell something with the panel open and
-- the wallet stayed on the old figure, and buying a machine left the panel
-- showing the price still in your pocket. Re-read on every draw instead, so this panel
-- and the HUD's coin counter can never disagree.
--
-- The server still re-reads every price and re-checks the balance itself in
-- AtvServer.buy; this only decides what the panel says.
local function readState()
	state.coins = player:GetAttribute("Coins") or 0
	state.rebirths = math.max(0, math.floor(tonumber(player:GetAttribute("Rebirths")) or 0))
	state.owned = math.max(0, math.floor(tonumber(player:GetAttribute(AtvConfig.OwnedAttribute)) or 0))
end

--[[
	WHAT THIS PANEL TREATS AS OWNED.

	The AtvTier ladder OR the pass attribute, and the second one is belt and
	braces rather than a second rule: GamePassService writes a pass straight into
	AtvTier, so the first test is normally already true. It is the window between
	the pass resolving and the attribute landing that this covers, and in that
	window a bay that said BUY over a machine the player had just paid for would
	be the worst possible moment to be a frame behind.

	DISPLAY ONLY, either way. The server re-derives ownership for itself in
	AtvServer.spawn, and a client that lies to its own attributes gets a button
	that says SPAWN and a server that says "You do not own that one."
]]
local function ownsTier(tier): boolean
	return state.owned >= tier.id or AtvConfig.ownsPass(player, tier)
end

local function refresh()
	readState()
	purseAmt.Text = "$" .. comma(state.coins)
	tideAmt.Text = string.format("%d rebirth%s", state.rebirths, state.rebirths == 1 and "" or "s")
	awayHolder.Visible = state.riding

	--[[
		WHAT EACH MACHINE WOULD ACTUALLY DO FOR *THIS* PLAYER.

		The showroom used to draw the raw tier table, which was honest while a
		machine was a fixed lump of stats. It is not any more: speed and hold are
		each max(the machine's, this player's upgrade track) -- see
		AtvConfig.effectiveStats -- so a maxed walker looking at a Tidebreaker's
		"31 SPEED" was being quoted a number they had already beaten on foot, and
		the 250,000 coin purchase looked like a downgrade.

		THE BAR SCALE IS RECOMPUTED HERE TOO, not taken from the static BEST
		above. Bars are a comparison, and PanelKit.statBar clamps at 1.0 -- so
		against the shop's own maximum, an upgraded stat would peg every bar of
		every machine full and the comparison the bars exist for would be gone.
	]]
	local best = { net = 1, speed = 1, turn = 1, hold = 1 }
	local effective = {}
	for _, ui in bays do
		local s = AtvConfig.effectiveStats(player, ui.tier)
		effective[ui.tier.id] = s
		best.net = math.max(best.net, s.netRadius)
		best.speed = math.max(best.speed, s.speed)
		best.turn = math.max(best.turn, s.turn)
		best.hold = math.max(best.hold, s.hold)
	end

	for _, ui in bays do
		local tier = ui.tier
		local owned = ownsTier(tier)
		local blocked = AtvConfig.blockedReason(player, tier, state.coins, state.rebirths)
		local s = effective[tier.id]

		ui.netBar:Set(s.netRadius, best.net, stat(s.netRadius))
		ui.spdBar:Set(s.speed, best.speed, stat(s.speed))
		ui.turnBar:Set(s.turn, best.turn, string.format("%.1f", s.turn))
		ui.holdBar:Set(s.hold, best.hold, stat(s.hold))

		-- Four states, four colours, and the tint carries the meaning: sea for a
		-- thing you own and can call out, lime for a price you can pay, coral for
		-- one you cannot, sand for a gate that money does not open.
		if owned then
			ui.cost.Text = "SPAWN"
			PanelKit.retint(ui.face, ui.slab, C.sea)
		elseif blocked and blocked:find("rebirth") then
			ui.cost.Text = "LOCKED"
			PanelKit.retint(ui.face, ui.slab, C.sandDeep)
		elseif blocked then
			ui.cost.Text = "$" .. comma(tier.price)
			PanelKit.retint(ui.face, ui.slab, C.coral)
		else
			ui.cost.Text = "$" .. comma(tier.price)
			PanelKit.retint(ui.face, ui.slab, C.lime)
		end

		--[[
			THE ROBUX BUTTON, and it has three states rather than two.

			Gone once you own the machine -- there is nothing left to sell you.
			Shown in grape with a price when the pass is on sale. And shown DIMMED
			saying SOON when the pass exists but is not on sale, which is the state
			both passes are in as this is written.

			That third state is deliberate rather than lazy. Hiding the button
			would make the shop look like it never had a Robux option at all, which
			from the outside is indistinguishable from the feature being broken --
			and it would hide the one thing that tells whoever publishes this place
			why nobody can buy anything. It lights up on its own the moment the
			pass goes on sale in the Creator Dashboard; no code changes.

			NOTE IT IS SHOWN OVER A REBIRTH LOCK ON PURPOSE. A pass unlocks its
			machine outright, so "LOCKED" on the coin button above a live price
			here is exactly the true statement: coins cannot open this yet, Robux
			can. See GamePassService.
		]]
		if owned or not ui.passId then
			ui.passHolder.Visible = false
		else
			ui.passHolder.Visible = true
			if passOnSale(ui.passId) then
				ui.passCost.Text = "R$ " .. comma(passPrice(ui.passId))
				PanelKit.retint(ui.passFace, ui.passSlab, C.grape)
			else
				ui.passCost.Text = "R$ SOON"
				PanelKit.retint(ui.passFace, ui.passSlab, C.sandDeep)
			end
		end

		--[[
			ONE SLOT, TWO MESSAGES, and the refusal always wins it.

			A player who cannot buy this machine needs to know why far more than
			they need to know it would suit their gear, so the boost line only
			appears when there is nothing standing in the way.

			The boost line exists at all because a stat that silently got better
			is a reward the player never learns they earned. Without it the only
			evidence that sixty levels of Beach Legs carry onto a bulldozer is a
			number on a bar that they have no reason to believe used to be lower.
		]]
		local boosts = {}
		if s.upgraded.speed then table.insert(boosts, "speed") end
		if s.upgraded.hold then table.insert(boosts, "hold") end

		if blocked and not owned then
			ui.why.TextColor3 = C.coralDark
			ui.why.Text = blocked
		elseif #boosts > 0 then
			ui.why.TextColor3 = C.limeDark
			ui.why.Text = "Your gear lifts its " .. table.concat(boosts, ", ") .. "."
		else
			ui.why.Text = ""
		end
	end
end

----------------------------------------------------------------
-- WIRING
----------------------------------------------------------------
-- The turntables only run while the panel is up. A ViewportFrame per bay on a
-- RenderStepped each is not free, and a closed modal should cost nothing.
local function spin(on: boolean)
	for _, ui in bays do
		if ui.turn then
			if on then
				ui.turn:Start()
			else
				ui.turn:Stop()
			end
		end
	end
end

local function closePanel()
	gui.Enabled = false
	spin(false)
end

for _, ui in bays do
	TouchFit.press(ui.face, function()
		if ownsTier(ui.tier) then
			remotes.AtvSpawn:FireServer(ui.tier.id)
		else
			remotes.AtvBuy:FireServer(ui.tier.id)
		end
		closePanel()
	end)

	--[[
		STRAIGHT TO MARKETPLACESERVICE, not through a remote.

		PromptGamePassPurchase is a client call -- there is no server-side way to
		open a purchase dialog on somebody's screen -- so a remote here would be a
		hop that changes nothing. It is not a hole either: the server hears about
		the result on PromptGamePassPurchaseFinished and then goes and ASKS Roblox
		whether the pass is owned rather than believing the callback.

		THE PANEL STAYS UP, unlike the coin button which closes it. Roblox's
		purchase dialog is its own modal and it can be cancelled; closing the shop
		behind it would leave somebody who changed their mind staring at the pad.
	]]
	TouchFit.press(ui.passFace, function()
		if not ui.passId then
			return
		end
		if not passOnSale(ui.passId) then
			ToastKit.toast("That pass is not on sale yet \u{2014} coins still work.", "deny", 2.6)
			return
		end
		MarketplaceService:PromptGamePassPurchase(player, ui.passId)
	end)
end

TouchFit.press(closeFace, closePanel)
TouchFit.activated(shade, closePanel)
TouchFit.press(awayFace, function()
	remotes.AtvStore:FireServer()
	closePanel()
end)

remotes.AtvMenu.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then
		return
	end
	-- `riding` is the one field only the server knows -- there is no attribute
	-- for whether a machine is out. Everything else refresh() re-reads for itself.
	state.riding = payload.riding == true
	refresh()
	gui.Enabled = true
	spin(true)
	-- Punches in from 70% the way every panel in the game does. A modal that
	-- just appeared would read as a different app's menu however well painted.
	PanelKit.popIn(root, PANEL_W, PANEL_H)
end)

-- Money, rebirths and what you own can all move while the panel is open: a
-- bounty lands, a sale pays out, you buy the machine you are looking at. Redraw
-- on each, so the wallet here always says what the HUD says.
local watched = { "Coins", "Rebirths", AtvConfig.OwnedAttribute }
-- ...and one per game pass, so a purchase completed with the panel still open
-- turns its own bay from a price into SPAWN without anyone closing anything.
for _, tier in AtvConfig.Tiers do
	local attr = AtvConfig.passAttribute(tier)
	if attr then
		table.insert(watched, attr)
	end
end
for _, attr in watched do
	player:GetAttributeChangedSignal(attr):Connect(function()
		if gui.Enabled then
			refresh()
		end
	end)
end

-- Prices land a moment after boot -- GamePassService reads them off the web --
-- and a panel opened inside that window would otherwise sit on "R$ SOON" until
-- it was closed and reopened.
if passInfo then
	passInfo.AttributeChanged:Connect(function()
		if gui.Enabled then
			refresh()
		end
	end)
end

----------------------------------------------------------------
-- RESULT MESSAGES
----------------------------------------------------------------
-- Through ToastKit, not a fourth notification system.
--
-- This used to build its own "AtvToast" ScreenGui: bare 28pt text parked at
-- y = 170, which is precisely the arrangement ToastKit's header describes
-- itself as having replaced -- a separate look, in a separate place, with a
-- standing chance of landing on top of whatever else was talking. It now joins
-- the one stack in the bottom band with everything else.
--
-- Kinds, not colours: `pickup` is the kit's green and `deny` its red, and deny
-- also carries the wobble that marks a refusal.
--[[
	AND, SOMETIMES, A PURCHASE DIALOG BEHIND THE TOAST.

	`promptPass` is a game pass id the SERVER decided was worth offering at the
	moment it refused something -- today that is somebody with no machine of
	their own pressing E on a stranger's truck, which is the best introduction to
	vehicles this game gets. The server cannot open the dialog itself:
	PromptGamePassPurchase is a client call and there is no server-side form of
	it. See AtvServer's `tell`.

	TWO THINGS GUARD IT, and both are about not being obnoxious rather than about
	security -- nothing is granted here, GamePassService asks Roblox afterwards.

	  ON SALE.  An off-sale pass opens a dialog the player CANNOT COMPLETE (see
	            GamePassService's header), so putting one up in response to a
	            keypress would be strictly worse than doing nothing. They get a
	            second line pointing at the coin price instead.

	  A COOLDOWN. E is a key people lean on. Without this, walking along a row of
	            parked machines holding E is a stack of purchase dialogs.
]]
local lastPassPrompt = 0
local PASS_PROMPT_GAP = 6

remotes.AtvResult.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then
		return
	end
	ToastKit.toast(tostring(payload.message), payload.ok and "pickup" or "deny", 2.2)

	local pass = payload.promptPass
	if type(pass) ~= "number" or pass <= 0 then
		return
	end
	if os.clock() - lastPassPrompt < PASS_PROMPT_GAP then
		return
	end
	lastPassPrompt = os.clock()

	if passOnSale(pass) then
		MarketplaceService:PromptGamePassPurchase(player, pass)
	else
		ToastKit.toast("Get your own at the Car Spawner \u{2014} coins buy one too.", "deny", 2.8)
	end
end)

----------------------------------------------------------------
-- THE STOCK'S OWN ROBUX PROMPT  --  one per machine on the plinth
----------------------------------------------------------------
--[[
	WALK UP TO A MACHINE AND IT OFFERS ITS OWN PASS.

	AtvServer stands the real bulldozer and the real truck on the showroom's
	plinths and hangs a tagged ProximityPrompt on each (standPassPrompt, which
	carries the reasoning for the key, the height and the reach). This is the
	other half: what the prompt SAYS, and what pressing it does.

	BOTH ARE THIS SCRIPT'S JOB, FOR TWO SEPARATE REASONS.

	  THE DIALOG.  PromptGamePassPurchase is a client call -- there is no
	               server-side way to open one on somebody's screen -- which is
	               the same reason the bays' Robux buttons above reach
	               MarketplaceService directly instead of through a remote. Not
	               a hole: GamePassService hears the outcome on
	               PromptGamePassPurchaseFinished and asks Roblox rather than
	               believing this script.

	  THE LABEL.   A ProximityPrompt is ONE instance seen by everybody, so the
	               server cannot make its text per-player -- and ownership is
	               exactly the per-player part, because there is nothing left to
	               sell somebody who already holds the pass. A client may write a
	               replicated instance's properties locally, and nothing undoes
	               these: the server sets them once at boot and never again.

	SWEPT ON A TIMER, NOT DRIVEN OFF GetInstanceAddedSignal. Measured on
	2026-08-23 against the Sandbot docks: on the client the added signal does not
	reliably fire for instances the SERVER tagged, and it fails silently -- the
	symptom is a label that is simply never painted. This is two prompts every
	two seconds, and the sweep also covers stock that streamed back in and a pad
	tagged after boot.
]]
local PROMPT_SWEEP = 2

--[[
	THE HIGHEST TIER THIS PLAYER'S *PASSES* ENTITLE THEM TO, which is not the
	same question as which machines they own, and the difference decides whether
	a plinth has anything left to sell.

	A pass covers every tier at or below its own -- GamePassService.owns compares
	with `>=`, and a tier pass writes its id straight into AtvTier -- so the
	truck's pass makes the bulldozer permanent too, and standing a price over the
	bulldozer afterwards would be offering somebody a thing they already have.
	The panel's bays get this for free from `ownsTier`; a prompt is per-machine
	and has to ask it directly.
]]
local function passFloor(): number
	local floor = 0
	for _, tier in AtvConfig.Tiers do
		if AtvConfig.ownsPass(player, tier) and tier.id > floor then
			floor = tier.id
		end
	end
	return floor
end

-- Do they hold this machine RIGHT NOW, by any route. Only ever asked after the
-- pass floor has already been ruled out, so reaching here means coins bought it
-- -- and a coin-bought machine is taken by the next tide (ProgressionServer's
-- rebirth wipe spares only pass holders), which is the whole pitch and is what
-- turns the offer from "Unlock" into "Keep Forever".
local function holdsTierNow(tier): boolean
	return (tonumber(player:GetAttribute(AtvConfig.OwnedAttribute)) or 0) >= tier.id
end

local function tierOfPrompt(prompt: Instance)
	if not prompt:IsA("ProximityPrompt") then
		return nil
	end
	return AtvConfig.tier(prompt:GetAttribute(AtvConfig.PassPromptTierAttribute))
end

local function paintPassPrompt(prompt: ProximityPrompt)
	local tier = tierOfPrompt(prompt)
	local id = tier and AtvConfig.passOf(tier)
	-- Nothing to sell: off, rather than a button that opens a Roblox dialog
	-- telling the player they already own this.
	if not id or passFloor() >= tier.id then
		prompt.Enabled = false
		return
	end

	prompt.Enabled = true
	prompt.ActionText = holdsTierNow(tier) and "Keep Forever" or "Unlock"
	if passOnSale(id) then
		prompt.ObjectText = string.format("%s \u{2014} R$ %s", tier.name, comma(passPrice(id)))
	else
		-- SOON rather than hidden, and rather than a figure. Both car passes are
		-- off sale as this is written, and the bays' Robux button draws exactly
		-- this for exactly this reason: a hidden offer is indistinguishable from
		-- a broken one, and "R$ 0" reads as free.
		prompt.ObjectText = tier.name .. " \u{2014} R$ soon"
	end
end

local function paintPassPrompts()
	for _, prompt in CollectionService:GetTagged(AtvConfig.PassPromptTag) do
		if prompt:IsA("ProximityPrompt") then
			paintPassPrompt(prompt)
		end
	end
end

task.spawn(function()
	while true do
		paintPassPrompts()
		task.wait(PROMPT_SWEEP)
	end
end)

-- ...and immediately on the things that change what a prompt should say, so a
-- pass bought at the plinth takes its own price tag down on the spot rather
-- than leaving it standing for the rest of the sweep. COINS ARE DELIBERATELY
-- NOT ON THIS LIST: they move on every sale and they change nothing here.
do
	local instant = { AtvConfig.OwnedAttribute }
	for _, tier in AtvConfig.Tiers do
		local attr = AtvConfig.passAttribute(tier)
		if attr then
			table.insert(instant, attr)
		end
	end
	for _, attr in instant do
		player:GetAttributeChangedSignal(attr):Connect(paintPassPrompts)
	end
	-- Prices land a moment after boot, the same window the panel's own watcher
	-- covers: without this a prompt read in the first second says SOON until the
	-- sweep comes round again.
	if passInfo then
		passInfo.AttributeChanged:Connect(paintPassPrompts)
	end
end

--[[
	AND THE PRESS ITSELF.

	Through ProximityPromptService rather than by connecting to each prompt's own
	Triggered, which is how MenuHud reaches the shop counters: one connection
	covers stock that has not been built yet, stock that streams in later and a
	pad rebuilt mid-session, with no bookkeeping of its own to go stale.

	The pass floor is re-checked here rather than trusted from the paint pass.
	The prompt is switched off for an owner, so this branch should be
	unreachable -- but "should be" is doing the work in a window measured in
	frames (the sweep is two seconds wide), and the cost of being wrong is a
	purchase dialog for a pass the player already bought.
]]
ProximityPromptService.PromptTriggered:Connect(function(prompt, who)
	if who ~= player or not CollectionService:HasTag(prompt, AtvConfig.PassPromptTag) then
		return
	end
	local tier = tierOfPrompt(prompt)
	local id = tier and AtvConfig.passOf(tier)
	if not id or passFloor() >= tier.id then
		return
	end

	--[[
		AN OFF-SALE PASS OPENS A DIALOG THE PLAYER CANNOT COMPLETE, so it is
		refused here rather than put up -- the same guard the AtvResult handler
		above uses, and for the same reason. The line points at the coin price
		instead, which is live for both machines and is two steps away: R opens
		the showroom from this very spot.
	]]
	if not passOnSale(id) then
		ToastKit.toast(string.format(
			"The %s pass is not on sale yet \u{2014} press R to buy it with coins.",
			tier.name), "deny", 3)
		return
	end
	MarketplaceService:PromptGamePassPurchase(player, id)
end)