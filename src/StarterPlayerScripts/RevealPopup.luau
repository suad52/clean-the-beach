--[[
	RevealPopup  --  StarterPlayerScripts.RevealPopup

	The payoff card: name, clean model on a slow turntable, rarity colour, and
	the revealed $value. Driven purely by SiftItemCleaned, which only the server
	ever fires -- so both the identity and the number on this card are the
	server's, revealed at the same instant the last chunk comes off.

	Reveals QUEUE. The bay auto-advances to the next lump, so two cards can
	otherwise end up fighting for the same corner.

	THE LOOK IS PANELKIT'S
	----------------------
	This was a near-black slab with a coloured hairline round it, which is a
	strange thing for the biggest moment in the game to look like. It is a
	PanelKit card now, and the RARITY is what paints it: the signboard across
	the top carries the tier's name in the tier's colour, so a Mythic arrives
	pink and a Common arrives pale without a single extra widget. The model sits
	in a rockpool tank, the same tray the Index shows its specimens in.

	VIEWPORTFRAME NOTES
	-------------------
	* A ViewportFrame's Camera.FieldOfView is VERTICAL. Framing by vertical FOV
	  alone under-frames a card that is wider than it is tall, so the distance
	  below is the max of the vertical and horizontal solves.
	* The model must be parented INTO the ViewportFrame (or a WorldModel inside
	  it) -- a model left in Workspace renders nothing.
	* Set PrimaryPart before PivotTo. An unset PrimaryPart makes PivotTo discard
	  the model's rotation, which turns a careful turntable into a jitter.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local ItemConfig = require(Modules:WaitForChild("ItemConfig"))
local ItemVisuals = require(Modules:WaitForChild("ItemVisuals"))
local PanelKit = require(Modules:WaitForChild("PanelKit"))
local UiFit = require(Modules:WaitForChild("UiFit"))
local Net = require(Modules:WaitForChild("Net"))
-- Curves, durations, and the player's Reduced Motion answer.
local Motion = require(Modules:WaitForChild("Motion"))

local C = PanelKit.C
local corner = PanelKit.corner
local outline = PanelKit.outline
local grad = PanelKit.grad
local punch = PanelKit.punch
local darken = PanelKit.darken

local player = Players.LocalPlayer

local RevealPopup = {}

--[[
	TWO SIZES, AND THE SMALL ONE IS NOT JUST THE BIG ONE SCALED.

	UiFit already shrinks this whole card on a phone (down to 0.6), and that is
	the wrong tool on its own for this particular card: scaling makes the thing
	the player is squinting at SMALLER, which is the opposite of the complaint.

	So the compact card drops the line worth least -- the flavour description --
	and takes the height back rather than shrinking the name, the odds or the
	value. 300x340 against 320x400 is a fifth less screen covered, with every
	word that matters the same size or bigger.

	CARD_W/CARD_H are the LIVE pair, written by build(). `present` reads them for
	the offscreen park position, which is why they are not constants: a compact
	card parked at the desktop width leaves a 20px sliver on screen.
]]
local DESK_W, DESK_H = 320, 400
local COMPACT_W, COMPACT_H = 300, 340

local CARD_W, CARD_H = DESK_W, DESK_H
local compact = false

-- Tank height, then the top of each line under it. One table per size so the
-- two layouts are read side by side rather than reconstructed from arithmetic.
local LAYOUT = {
	[false] = { tank = 162, name = 170, odds = 201, oddsSize = 13, desc = 224 },
	[true]  = { tank = 150, name = 158, odds = 190, oddsSize = 15, desc = nil },
}

local HOLD = 3.0

-- PARKED CLEAR OF THE MENU RAIL, not over it.
--
-- The rail is 92 wide at (1, -20), so anything anchored nearer the edge than
-- about 130 draws straight across five buttons -- and this card outranks it
-- (DisplayOrder 20 against 12), so it wins. 132 puts the signboard's right
-- edge, overhang included, a pixel clear of the rail's left edge.
local REST_X = -132

-- TOP-ANCHORED, NOT CENTRED ON 0.28 OF SCREEN HEIGHT.
--
-- A scale anchor has to be re-derived every time the card's height changes and
-- this one never was: at 400 tall, 0.28 of a 693px viewport puts the centre at
-- 194 and the signboard at -28, i.e. off the top of the screen. An offset from
-- the top edge holds wherever the card's height lands.
--
-- 132 IS MEASURED AGAINST CTB_HUD'S LOAD BAR, IN THE OTHER GUI'S COORDINATES.
-- That bar is 10..64 with a 5px shadow under it -- but CTB_HUD's ScreenGui has
-- IgnoreGuiInset FALSE and this one has it TRUE, so everything over there is
-- 36px further down than its numbers say. 105 is where it really ends; the
-- banner overhangs this card by 22, so anything under 127 clips it.
local REST_Y = 132

local gui, card, banner, setBannerTitle
local tank, itemName, oddsText, descText, valueText, valuePill
local turntable
local queue = {}
local showing = false
local spinConn
-- Set when the viewport crosses UiFit's compact threshold while a card is up.
-- Rebuilding mid-reveal would delete the card in the middle of the one moment
-- this file exists for, so pump() does it when the queue drains instead.
local relayoutWanted = false

--------------------------------------------------------------------------
-- BUILD
--------------------------------------------------------------------------

local function build()
	CARD_W = compact and COMPACT_W or DESK_W
	CARD_H = compact and COMPACT_H or DESK_H
	local L = LAYOUT[compact]

	gui = Instance.new("ScreenGui")
	gui.Name = "RevealPopup"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 20
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local body, closeFace
	card, body, closeFace, banner, setBannerTitle = PanelKit.card(gui, "COMMON", CARD_W, CARD_H, C.sea)
	-- Nothing to close: the card leaves on its own timer.
	closeFace.Parent:Destroy()
	card.Name = "Card"
	-- High and right: CTB_HUD's upgrade panel sits right-centre at 0.62 and the
	-- menu rail runs the full height beside it, so the top-right corner is the
	-- one place a card this size can land without covering something live.
	card.AnchorPoint = Vector2.new(1, 0)
	card.Position = UDim2.new(1, CARD_W + 80, 0, REST_Y) -- offscreen right
	card.Visible = false

	----------------------------------------------------------------
	-- THE TANK  --  a rockpool for the specimen to sit in
	----------------------------------------------------------------
	tank = Instance.new("Frame")
	tank.Name = "Tank"
	tank.Size = UDim2.new(1, 0, 0, L.tank)
	-- White, because grad() MULTIPLIES against the base colour and a Frame's
	-- default is mid grey -- which is what turns a rockpool into dishwater.
	tank.BackgroundColor3 = Color3.new(1, 1, 1)
	tank.BorderSizePixel = 0
	tank.ClipsDescendants = true
	tank.Parent = body
	corner(tank, 18)
	outline(tank, 4)
	grad(tank, Color3.fromRGB(176, 236, 250), Color3.fromRGB(60, 154, 194))

	-- Wet sand along the bottom. ClipsDescendants clips to the RECTANGLE and
	-- ignores UICorner, so a square strip pokes its corners out through the
	-- tank's rounded ones: give the strip the same radius and let the top edge
	-- of it be covered by its own body.
	local bed = Instance.new("Frame")
	bed.Name = "Bed"
	bed.AnchorPoint = Vector2.new(0, 1)
	bed.Position = UDim2.fromScale(0, 1)
	bed.Size = UDim2.new(1, 0, 0, 26)
	bed.BackgroundColor3 = Color3.fromRGB(232, 204, 150)
	bed.BorderSizePixel = 0
	bed.ZIndex = 2
	bed.Parent = tank
	corner(bed, 18)

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Viewport"
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(198, 194, 186)
	viewport.LightColor = Color3.fromRGB(255, 250, 240)
	viewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
	viewport.ZIndex = 4
	viewport.Parent = tank

	local vcam = Instance.new("Camera")
	vcam.Parent = viewport
	viewport.CurrentCamera = vcam

	----------------------------------------------------------------
	-- THE WORDS
	----------------------------------------------------------------
	--[[
		WHITE, NOT INK, AND THE REASON IS THAT THE TRAY MOVED UNDER IT.

		PanelKit.card's well used to be cream. It is dark wood now (66,42,26 ->
		104,70,44, see the note on it over there) and these three labels were never
		brought up with it -- so the item's NAME was ink (56,36,20) on wood, i.e.
		darker than the board it was printed on, the odds were the tier colour
		DARKENED, and the description was woodDark on wood, which is to say it had
		not been visible at all for some time.

		MenuHud's rebirth warning hit exactly this and its note says the same
		thing: anything drawn straight onto a body had to come up when the tray
		went down. Bright type on a dark tray is the whole look -- "paper pinned to
		a board", as PanelKit puts it.

		The stroke is not decoration either: this is the one line on the card that
		is read at a glance, over a viewport whose colours belong to the item.
	]]
	itemName = PanelKit.text(body, "", 22, Enum.Font.LuckiestGuy, C.white)
	itemName.Position = UDim2.fromOffset(0, L.name)
	itemName.Size = UDim2.new(1, 0, 0, 30)
	punch(itemName, 2.5)
	-- "Message in a Bottle" is 19 characters and the card is 284 wide inside.
	-- Scaled with a ceiling rather than truncated: a reveal that reads
	-- "Message in a Bo..." is the one line on this card nobody wants clipped.
	itemName.TextScaled = true
	itemName.TextTruncate = Enum.TextTruncate.None
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = 22
	cap.MinTextSize = 12
	cap.Parent = itemName

	-- Colour is set per reveal from the tier -- see `present`.
	oddsText = PanelKit.text(body, "", L.oddsSize, Enum.Font.GothamBold, C.white)
	oddsText.Position = UDim2.fromOffset(0, L.odds)
	oddsText.Size = UDim2.new(1, 0, 0, 20)

	-- The flavour line, and the first thing to go on a phone: it is the only
	-- text on this card that says nothing about what was found or what it is
	-- worth. `descText` stays nil there and `present` is written to expect that.
	descText = nil
	if L.desc then
		-- Warm light sand, the colour MenuHud settled on for body copy over the
		-- same dark tray. Gotham at 12 in a brown would be invisible again.
		descText = PanelKit.text(body, "", 12, Enum.Font.Gotham, Color3.fromRGB(226, 206, 176))
		descText.Position = UDim2.fromOffset(10, L.desc)
		descText.Size = UDim2.new(1, -20, 0, 44)
		descText.TextWrapped = true
		descText.TextTruncate = Enum.TextTruncate.None
		descText.TextYAlignment = Enum.TextYAlignment.Top
	end

	----------------------------------------------------------------
	-- THE NUMBER
	--
	-- On its own gold plate rather than as loose text: this is the one fact
	-- the player came for, and a chunky slab is how everything else in this
	-- game says "press me / take me / this is the point".
	----------------------------------------------------------------
	valuePill = Instance.new("Frame")
	valuePill.Name = "Value"
	valuePill.AnchorPoint = Vector2.new(0.5, 1)
	valuePill.Position = UDim2.new(0.5, 0, 1, 0)
	valuePill.Size = UDim2.new(1, -28, 0, 48)
	valuePill.BackgroundColor3 = C.sun
	valuePill.BorderSizePixel = 0
	valuePill.Parent = body
	corner(valuePill, 16)
	outline(valuePill, 4)
	grad(valuePill, C.sun:Lerp(C.white, 0.25), darken(C.sun, 0.18))
	PanelKit.gloss(valuePill, 16)

	valueText = PanelKit.text(valuePill, "", 30, Enum.Font.LuckiestGuy, C.white)
	valueText.Size = UDim2.fromScale(1, 1)
	valueText.ZIndex = 6
	punch(valueText, 3.5)

	turntable = { viewport = viewport, camera = vcam, model = nil, angle = 0, dist = 6, centre = Vector3.zero }
end

--------------------------------------------------------------------------
-- TURNTABLE
--------------------------------------------------------------------------

local function frameModel(model: Model)
	local vp = turntable.viewport
	local vcam = turntable.camera

	if turntable.model then
		turntable.model:Destroy()
	end

	model.Parent = vp
	turntable.model = model

	local cf, size = model:GetBoundingBox()
	local radius = math.max(size.Magnitude * 0.5, 0.35)

	local absolute = vp.AbsoluteSize
	local aspect = (absolute.Y > 0) and (absolute.X / absolute.Y) or 1
	local halfV = math.rad(vcam.FieldOfView) * 0.5
	local halfH = math.atan(math.tan(halfV) * aspect)

	-- Solve both axes and take whichever needs more room. Framing on the
	-- vertical alone clips a wide item's ends.
	local dist = math.max(radius / math.tan(halfV), radius / math.tan(halfH)) * 1.25

	-- The model is NOT re-pivoted here. GetBoundingBox's centre and a model's
	-- pivot are different points on multi-part authored art, so moving it to
	-- "centre" would put the turntable's axis off the object it is orbiting.
	turntable.centre = cf.Position
	turntable.dist = dist
	turntable.angle = math.rad(-25)
end

local function spin(dt: number)
	local t = turntable
	if not (t and t.model and t.model.Parent) then
		return
	end
	--[[
		REDUCED MOTION STOPS THE ORBIT, NOT THE CARD.

		A continuous rotation is the single most motion-heavy thing on this popup
		and the one a motion-sensitive player most needs stopped -- a tween ends,
		this does not. The camera is still positioned and framed on the angle set
		by frameModel, so the item is presented exactly as well; it simply holds
		still. Left below the guard rather than returning early for that reason:
		the CFrame still has to be written, or a rebuild mid-reveal would leave
		the camera wherever it last was.
	]]
	if not Motion.reduced() then
		t.angle += dt * 0.7
	end
	local eye = t.centre
		+ Vector3.new(math.cos(t.angle), 0.42, math.sin(t.angle)).Unit * (t.dist or 6)
	t.camera.CFrame = CFrame.lookAt(eye, t.centre)
end

--------------------------------------------------------------------------
-- SHOW
--------------------------------------------------------------------------

--[[
	FUNCTIONS, NOT CONSTANTS, and that is the whole reason they changed shape.

	A TweenInfo built at load time bakes in whatever Reduced Motion said then.
	The player can turn it on from the Settings panel mid-session, so the answer
	has to be read at the moment the card actually moves.

	The exit WAS Quad/In. Entering and exiting both want ease-out: an ease-in
	holds the card still at the exact moment the player has finished reading it
	and is waiting for it to go, so the card read as reluctant to leave.

	0.42 on the way in is longer than the 300ms UI ceiling on purpose -- this is
	a reward reveal, which is where the rules put the delight budget.
]]
local function enterInfo(): TweenInfo
	return Motion.info(0.42, Motion.Ease.pop)
end

local function exitInfo(): TweenInfo
	return Motion.info(Motion.Dur.menu, Motion.Ease.out)
end

local function present(payload)
	local def = ItemConfig.get(payload.itemId)
	local rarity = payload.rarity or (def and def.Rarity) or "Common"
	local colour = ItemConfig.rarityColor(rarity)

	-- THE WHOLE CARD IS PAINTED BY THE TIER. retint, not BackgroundColor3: the
	-- banner carries a UIGradient baked from the last reveal's colour, and a
	-- gradient MULTIPLIES against the fill under it -- a Mythic face under a
	-- Common gradient gives neither colour, it gives mud.
	PanelKit.retint(banner, nil, colour)
	-- Through PanelKit's setter. The banner title is a white label over an ink
	-- shadow, and this used to write to banner:FindFirstChildOfClass("TextLabel")
	-- -- the SHADOW -- so the card was built reading COMMON and the white word
	-- stayed COMMON however rare the find was, with the real tier showing only as
	-- a faint ghost three pixels below it. It upper-cases inside the setter.
	setBannerTitle(rarity)

	itemName.Text = payload.displayName or (def and def.DisplayName) or payload.itemId
	-- The odds are the point of the reveal: the value alone does not tell you
	-- whether this was lucky. ItemConfig owns the true number.
	local odds = payload.itemId and ItemConfig.oddsTextFor(payload.itemId) or ""
	oddsText.Text = odds
	-- LIFTED toward white, not darkened toward black. It was darkened, and the
	-- note here used to argue for that on the grounds that these tiers were mixed
	-- to glow on a near-black card and would vanish on sand. The tray is neither:
	-- it is dark wood, so a darkened tier colour is now the invisible one --
	-- Epic's grape at 45% darker is (102,70,140) against a (66,42,26) board.
	-- Lifting keeps the tier readable AS its colour and legible at a glance,
	-- which is what the line is for.
	--
	-- HALFWAY, AND THAT IS MEASURED RATHER THAN CHOSEN BY EYE. Contrast against
	-- the lighter end of the tray, over all six tiers -- the small-text bar is
	-- 4.5:1:
	--
	--   lift   0.35   0.42   0.50
	--   worst  4.07   4.40   4.81      (Mythic's pink is the worst case, then Epic)
	--
	-- 0.35 and 0.42 both leave two tiers under the bar. At 0.5 every tier clears
	-- it and all six are still plainly their own colour.
	oddsText.TextColor3 = colour:Lerp(C.white, 0.5)
	if descText then
		descText.Text = payload.description or (def and def.Description) or ""
	end
	valueText.Text = "$" .. tostring(payload.value or 0)

	-- Visible BEFORE framing: AbsoluteSize is what frameModel divides by to get
	-- the viewport aspect, and an unlaid-out frame reports zero.
	card.Visible = true

	-- Build a fresh clean model for the card rather than reparenting the one on
	-- the stand: the server destroys that one a second from now.
	local built = ItemVisuals.buildClean(payload.itemId)
	frameModel(built)

	TweenService:Create(card, enterInfo(), { Position = UDim2.new(1, REST_X, 0, REST_Y) }):Play()

	if rarity ~= "Common" then
		local pp = built.PrimaryPart
		if pp then
			ItemVisuals.burstSparkle(pp, rarity)
		end
	end

	task.wait(HOLD + (ItemConfig.rarityInfo(rarity).hold or 0))

	local out = TweenService:Create(card, exitInfo(), { Position = UDim2.new(1, CARD_W + 80, 0, REST_Y) })
	out:Play()
	out.Completed:Wait()
	card.Visible = false
	if turntable.model then
		turntable.model:Destroy()
		turntable.model = nil
	end
end

--------------------------------------------------------------------------
-- FITTING THE SCREEN
--------------------------------------------------------------------------
--[[
	The card is BUILT at one of two sizes rather than resized, because its frame
	is PanelKit's -- glows, slab, well, banner overhang, all sized from w and h at
	construction. Reaching into another module's card to resize eight frames from
	here is the kind of coupling that breaks the next time that file is touched;
	throwing the card away and building the other one is two lines and cannot go
	stale.

	DRIVEN BY UiFit.onChanged, NOT READ ONCE AT BOOT. UiFit.start lives in its own
	LocalScript and YIELDS up to five seconds waiting for a real viewport
	measurement, so nothing about ClientMain's order guarantees a useful answer by
	the time RevealPopup.start runs -- a phone would have booted into the desktop
	card and stayed there. onChanged fires immediately AND on every change, so the
	first honest measurement lands here whenever it arrives.
]]
local function rebuild()
	if gui then
		gui:Destroy()
	end
	build()
end

local function fitTo(scale: number)
	local want = scale < UiFit.COMPACT_BELOW
	if want == compact and gui then
		return
	end
	compact = want
	if showing then
		relayoutWanted = true
		return
	end
	rebuild()
end

local function pump()
	if showing then
		return
	end
	showing = true
	task.spawn(function()
		while #queue > 0 do
			local payload = table.remove(queue, 1)
			local ok, err = pcall(present, payload)
			if not ok then
				warn("[RevealPopup] present failed:", err)
				card.Visible = false
			end
		end
		showing = false
		-- The window changed size mid-reveal. Safe now: nothing is on screen.
		if relayoutWanted then
			relayoutWanted = false
			rebuild()
		end
	end)
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

local started = false
function RevealPopup.start()
	if started then
		return
	end
	started = true

	build()

	-- BOTH reveal remotes, because which one fires is a ServerMain decision:
	-- WashServer sends WashItemCleaned, SiftServer sends SiftItemCleaned, and
	-- only one of the two is started. Listening to a single name meant the card
	-- silently never appeared the moment the other bay was the live one --
	-- the reveal is the payoff of the whole mechanic, so it should not depend on
	-- which module happens to be switched on.
	local function onCleaned(payload)
		if type(payload) ~= "table" or not payload.itemId then
			return
		end
		table.insert(queue, payload)
		pump()
	end

	Net.get("WashItemCleaned").OnClientEvent:Connect(onCleaned)
	Net.get("SiftItemCleaned").OnClientEvent:Connect(onCleaned)

	-- AFTER the listeners are wired, so a reveal that lands during the rebuild
	-- this may trigger is queued rather than dropped.
	UiFit.onChanged(fitTo)

	-- Reads `turntable` fresh on every frame, so a rebuild swapping the card out
	-- from under it needs no re-connection.
	spinConn = RunService.RenderStepped:Connect(spin)
end

function RevealPopup.stop()
	if spinConn then
		spinConn:Disconnect()
		spinConn = nil
	end
end

return RevealPopup
