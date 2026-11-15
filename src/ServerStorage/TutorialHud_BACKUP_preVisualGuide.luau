--[[
	TutorialHud  --  StarterPlayerScripts.TutorialHud  (ModuleScript)

	A four-step card that teaches the loop once and then gets out of the way:
	rake -> wash -> sell -> upgrade. Four, because that IS the loop. A fifth
	step would be a manual.

	IT WATCHES ATTRIBUTES AND OWNS NO REMOTES, and that is the whole design.
	Every step of the loop already writes its result onto the player: Bag when
	something comes out of the sand, CrustedWeight when it needs rinsing,
	TotalEarned when it sells, Lv_* when a level is bought. A tutorial that
	asked the server "have they sold yet" would be a second source of truth for
	something that already has one, and it would need SiftServer, WashServer,
	the sell pad and the shop all to remember to tell it. Watching numbers they
	ALREADY write means a new way to earn a coin advances this for free, and a
	system this has never heard of cannot break it.

	EVERY TEST IS "IT WENT UP SINCE THE CARD APPEARED", never an absolute. The
	baseline is taken in show(), so a player who arrives holding something is
	not credited for a step they did not do.

	OUT OF ORDER IS NOT AN ERROR. Players do not queue. Anything the loop
	allows -- selling before washing, buying an upgrade with the coins you
	walked in with -- ticks the steps before it too, because a card still
	asking for step 2 after you have plainly done step 3 is exactly what makes
	a tutorial feel like it is not watching. evaluate() tests furthest-first
	for that reason.

	THE WASH STEP MAY NOT APPLY AT ALL: a run can turn up nothing crusted, and
	then there is no wash to do and no way to do it. It is not special-cased --
	the furthest-first rule already carries it the moment anything sells.

	SHOWN ONCE PER SESSION, TO A PLAYER WHO LOOKS NEW (nothing earned, no
	rebirths). THERE IS NO DATASTORE IN THIS PLACE -- nothing persists between
	sessions at all -- so "has seen the tutorial" cannot be remembered, and
	this does not pretend to. If saving is ever added, one TutorialDone
	attribute tested in wanted() is the entire change.

	WHY HudKit AND NOT PanelKit
	---------------------------
	This is chrome that sits in a corner for a stretch of the session, which is
	HudKit's brief -- and PanelKit.chunky, the obvious shell for it, builds its
	face as a TextButton with a press animation wired in. The whole card would
	have depressed like a button and done nothing, which reads as broken. Only
	the DISMISS key is a key. HudKit's silhouette is PanelKit's exactly (slab,
	4px outline, gloss cap) so it still matches the rail beside it.

	WHERE IT SITS
	-------------
	Top right, tucked against the rail, because the left column is spoken for:
	CTB_HUD's three readouts run to y = 164 and InventoryHud's drawer opens at
	HudKit.L.DRAWER_Y underneath them.

	IT MEASURES THE RAIL rather than re-deriving MenuHud's constants, the same
	way MenuHud's own railBottom() does. Two traps in doing that, both of which
	bit here first:

	  - the rail must be looked up RECURSIVELY. UiFit reparents every top-level
	    child into a FitRoot, so the non-recursive find returns nothing.
	  - AbsolutePosition is in SCREEN pixels, already multiplied by UiFit's
	    scale, while Position offsets inside the FitRoot are pre-scale. Mixing
	    them is correct at scale 1 and wrong on every phone. Hence the divide.

	IgnoreGuiInset IS TRUE TO MATCH BeachMenuHud. Two ScreenGuis that overlap
	have to agree about it or their AbsolutePositions are measured from origins
	a topbar apart -- and this one is positioned off a frame living in the
	other.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local HudKit = require(Modules:WaitForChild("HudKit"))
local PanelKit = require(Modules:WaitForChild("PanelKit"))
local ToastKit = require(Modules:WaitForChild("ToastKit"))
local UiFit = require(Modules:WaitForChild("UiFit"))

local C, A = HudKit.C, HudKit.A
local player = Players.LocalPlayer

local TutorialHud = {}

----------------------------------------------------------------
-- The steps
----------------------------------------------------------------
--[[
	`watch` names the attributes worth hanging a changed-signal on; `rose`
	answers "is this further along than the baseline". Both are needed,
	because several of these numbers also move for reasons that are not
	progress -- CrustedWeight falls as you wash and rises again as you dig --
	so a signal is only a hint that it is worth re-testing.
]]
local STEPS = {
	{
		title = "RAKE THE SAND",
		blurb = "Walk the beach to comb litter up out of it.",
		watch = { "Bag", "CurrentWeight" },
		rose = function(base)
			return (player:GetAttribute("Bag") or 0) > (base.Bag or 0)
				or (player:GetAttribute("CurrentWeight") or 0) > (base.CurrentWeight or 0)
		end,
	},
	{
		title = "RINSE THE CRUST",
		blurb = "Crusted finds pay more clean. Take them to a WASH BAY.",
		watch = { "CrustedWeight" },
		-- Crusted weight has to have gone UP and then come back down. Arriving
		-- at zero is not a wash, it is an empty bag.
		rose = function(_, seen)
			return seen.crustedPeak > 0.001
				and (player:GetAttribute("CrustedWeight") or 0) <= 0.001
		end,
	},
	{
		title = "SELL YOUR FINDS",
		blurb = "Stand on the SELL pad to cash the bag in.",
		watch = { "TotalEarned", "Coins" },
		rose = function(base)
			return (player:GetAttribute("TotalEarned") or 0) > (base.TotalEarned or 0)
		end,
	},
	{
		title = "BUY AN UPGRADE",
		blurb = "Spend it at the shop -- a wider roller finds more per pass.",
		-- No single attribute to name: ANY Lv_* moving is an upgrade, and which
		-- ones exist is the shop's business rather than this file's. The
		-- unfiltered AttributeChanged below covers all of them, and any added
		-- later, without this list needing to know.
		watch = {},
		rose = function(base)
			for name, was in pairs(base) do
				if name:sub(1, 3) == "Lv_" and typeof(was) == "number"
					and (player:GetAttribute(name) or 0) > was then
					return true
				end
			end
			return false
		end,
	},
}

----------------------------------------------------------------
-- Layout
----------------------------------------------------------------
local W, H = 292, 132
local TOP = 54            -- level with the top of the rail
local RAIL_GUTTER = 12    -- between this card's right edge and the rail's left
local FALLBACK_RIGHT = 124  -- 20 screen gutter + 92 rail + 12, if the rail is not up

-- See the header for both traps this is threading.
local function railInset(): number
	local cam = workspace.CurrentCamera
	local pg = player:FindFirstChild("PlayerGui")
	local menu = pg and pg:FindFirstChild("BeachMenuHud")
	local rail = menu and menu:FindFirstChild("Rail", true)
	if cam and rail and rail:IsA("GuiObject") and rail.AbsoluteSize.X > 0 then
		local scale = UiFit.get()
		if scale > 0 then
			local rightPx = cam.ViewportSize.X - rail.AbsolutePosition.X
			return rightPx / scale + RAIL_GUTTER
		end
	end
	return FALLBACK_RIGHT
end

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local gui, root, face, titleLabel, blurbLabel, stepLabel
local pips = {}
-- TWO CONNECTION LISTS, and that is not tidiness. The dismiss key is wired
-- once in build() and has to survive hide(); the attribute watchers are wired
-- per show() and have to not. One list meant hide() unwired the X, so a second
-- show() put up a card that could not be closed.
local permConns, showConns = {}, {}
local started, running = false, false
local at = 1
local base, seen = {}, { crustedPeak = 0 }

local function track(list, c: RBXScriptConnection)
	table.insert(list, c)
end

----------------------------------------------------------------
-- The card
----------------------------------------------------------------
local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "TutorialHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true      -- matches BeachMenuHud; see the header
	gui.DisplayOrder = 11          -- under the rail's 12, over InventoryHud's 6
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	-- A plain Frame face: passive, no press. See the header.
	local holder, f = HudKit.surface(gui, W, H, 12, C.rowFace)
	root, face = holder, f
	root.Name = "Card"
	root.AnchorPoint = Vector2.new(1, 0)

	-- "STEP n OF 4": small and dim, because it is the frame around the
	-- instruction rather than the instruction.
	stepLabel = HudKit.text(face, "", 11, C.rowSub, Enum.Font.GothamBold)
	stepLabel.TextXAlignment = Enum.TextXAlignment.Left
	stepLabel.TextYAlignment = Enum.TextYAlignment.Top
	stepLabel.Position = UDim2.fromOffset(14, 11)
	stepLabel.Size = UDim2.fromOffset(W - 50, 14)

	titleLabel = HudKit.text(face, "", 20, C.rowText, Enum.Font.LuckiestGuy)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.TextYAlignment = Enum.TextYAlignment.Top
	titleLabel.Position = UDim2.fromOffset(14, 28)
	-- W - 50, not W - 28: the dismiss key occupies the top right corner and a
	-- left-aligned label wide enough to reach it would run a long title
	-- underneath it. Stopping short truncates instead, which is the failure that
	-- can be seen.
	titleLabel.Size = UDim2.fromOffset(W - 50, 24)

	-- TextWrapped in a fixed box and NO TextScaled: scaled text in a wrapping
	-- label picks its own size per string, so a two-line blurb and a one-line
	-- blurb come out at different sizes and the card jitters between steps.
	blurbLabel = HudKit.text(face, "", 13, C.rowSub, Enum.Font.GothamBold)
	blurbLabel.TextXAlignment = Enum.TextXAlignment.Left
	blurbLabel.TextYAlignment = Enum.TextYAlignment.Top
	blurbLabel.TextWrapped = true
	blurbLabel.Position = UDim2.fromOffset(14, 56)
	blurbLabel.Size = UDim2.fromOffset(W - 28, 40)

	-- One pip per step along the bottom, so "how much of this is left" is
	-- answerable without reading anything.
	local pipW = math.floor((W - 28 - (#STEPS - 1) * 6) / #STEPS)
	for i = 1, #STEPS do
		local pip = Instance.new("Frame")
		pip.Name = "Pip" .. i
		pip.Size = UDim2.fromOffset(pipW, 6)
		pip.Position = UDim2.fromOffset(14 + (i - 1) * (pipW + 6), H - 18)
		pip.BackgroundColor3 = C.rowDark
		pip.BorderSizePixel = 0
		pip.ZIndex = 12
		pip.Parent = face
		HudKit.corner(pip, 3)
		pips[i] = pip
	end

	--[[
		Dismiss. A tutorial you cannot close is a modal. This IS a button, so it
		gets the key treatment and the press that comes with it.

		EVERY LAYER OF IT IS RE-Z-INDEXED BY HAND. The gui is ZIndexBehavior
		Sibling, so ZIndex is global and a parent's does not carry to its
		children -- and HudKit.surface, which key() is built on, hands back a slab
		at 1 and a face at 2. Left alone, the whole key draws UNDER the card face
		it is sitting on. PanelKit.card lifts its own close key exactly this way.
	]]
	local keyHolder, keyFace, keySlab = HudKit.key(face, 22, C.rowDark, 7)
	keyHolder.Name = "Skip"
	keyHolder.AnchorPoint = Vector2.new(1, 0)
	keyHolder.Position = UDim2.fromOffset(W - 10, 9)
	keyHolder.ZIndex = 13
	keySlab.ZIndex = 13
	keyFace.ZIndex = 14
	-- The gloss cap is built INSIDE the face by HudKit.key at its own fixed
	-- ZIndex, so lifting the face alone buries it and the key loses the one
	-- highlight that makes it read as plastic. It has to come up too.
	local keyGloss = keyFace:FindFirstChild("Gloss")
	if keyGloss then
		keyGloss.ZIndex = 15
	end
	local x = HudKit.text(keyFace, "X", 12, C.rowText, Enum.Font.LuckiestGuy)
	x.ZIndex = 16
	track(permConns, keyFace.MouseButton1Click:Connect(function()
		TutorialHud.hide()
	end))

	-- A resize moves the rail, and this card is placed off the rail. Registered
	-- HERE rather than in show(): UiFit.onChanged has no matching remove, so
	-- doing it per-show would stack a listener each time. build() runs once.
	UiFit.onChanged(function()
		if running and root then
			root.Position = UDim2.new(1, -railInset(), 0, TOP)
		end
	end)

	UiFit.fit(gui)
end

----------------------------------------------------------------
-- Rendering
----------------------------------------------------------------
local function paint()
	local step = STEPS[at]
	if not step then
		return
	end
	stepLabel.Text = ("STEP %d OF %d"):format(at, #STEPS)
	titleLabel.Text = step.title
	titleLabel.TextColor3 = C.rowText
	blurbLabel.Text = step.blurb
	for i, pip in ipairs(pips) do
		pip.BackgroundColor3 = (i < at) and A.foam or (i == at) and A.sun or C.rowDark
	end
end

-- A tick, then move on. The pause is the point: a step that vanishes the
-- instant it completes never gets read as "I did that".
local function advance(to: number)
	if to <= at or not running then
		return
	end
	local done = STEPS[at]
	at = to
	if done then
		titleLabel.Text = done.title .. "  \u{2713}"
		titleLabel.TextColor3 = A.foam
	end
	for i = 1, math.min(#pips, to - 1) do
		pips[i].BackgroundColor3 = A.foam
	end
	task.delay(0.9, function()
		if not running then
			return
		end
		if at > #STEPS then
			-- PUT THE CARD AWAY FIRST, AND ONLY THEN CONGRATULATE. The toast is
			-- the decoration and the dismissal is the job, so the job must not be
			-- downstream of it: this runs inside a task.delay with nothing above it
			-- to catch a throw, and a toast that failed took the close with it and
			-- left the finished card on screen for the rest of the session.
			TutorialHud.hide()
			pcall(ToastKit.toast, "That is the loop. Off you go.", "good", 4)
		else
			paint()
			-- popIn WRITES root.Size, so the holder has to be exactly (W, H) --
			-- which HudKit.surface gives and PanelKit.chunky (w, h + 7) does not.
			PanelKit.popIn(root, W, H)
		end
	end)
end

-- Furthest-first, so an out-of-order completion carries the steps before it.
local function evaluate()
	if not running then
		return
	end
	local crusted = player:GetAttribute("CrustedWeight") or 0
	if crusted > seen.crustedPeak then
		seen.crustedPeak = crusted
	end
	for i = #STEPS, at, -1 do
		local ok, hit = pcall(STEPS[i].rose, base, seen)
		if ok and hit then
			advance(i + 1)
			return
		end
	end
end

----------------------------------------------------------------
-- Show / hide
----------------------------------------------------------------
function TutorialHud.show()
	if running then
		return
	end
	if not gui then
		build()
	end
	running = true
	at = 1

	-- The baseline, taken now and not at boot: whatever they are holding when
	-- the card goes up does not count as having been done for it.
	base = player:GetAttributes()
	seen = { crustedPeak = player:GetAttribute("CrustedWeight") or 0 }

	paint()
	root.Position = UDim2.new(1, -railInset(), 0, TOP)
	gui.Enabled = true
	PanelKit.popIn(root, W, H)

	-- The named attributes are the cheap path; the unfiltered signal is the
	-- backstop for the upgrade step, which cannot name what it waits for.
	for _, step in ipairs(STEPS) do
		for _, name in ipairs(step.watch) do
			track(showConns, player:GetAttributeChangedSignal(name):Connect(evaluate))
		end
	end
	track(showConns, player.AttributeChanged:Connect(evaluate))
end

function TutorialHud.hide()
	if not running then
		return
	end
	running = false
	for _, c in ipairs(showConns) do
		c:Disconnect()
	end
	table.clear(showConns)
	if not (gui and root) then
		return
	end
	local away = root.Position + UDim2.fromOffset(24, 0)
	TweenService:Create(root, TweenInfo.new(0.25, Enum.EasingStyle.Quad),
		{ Position = away }):Play()
	task.delay(0.28, function()
		if not running and gui then
			gui.Enabled = false
		end
	end)
end

----------------------------------------------------------------
-- Boot
----------------------------------------------------------------
-- Nothing earned and no rebirths. Deliberately loose: this is a card in the
-- corner with an X on it, so being wrong costs a returning player one click,
-- where being too strict costs a new player the tutorial.
local function wanted(): boolean
	return (player:GetAttribute("TotalEarned") or 0) <= 0
		and (player:GetAttribute("Rebirths") or 0) <= 0
end

--[[
	WAIT OUT THE OPENING SHOT. IntroCinema raises an opaque curtain at
	DisplayOrder 260 and sweeps the HUDs off once a second for the length of
	it; TutorialHud is on that list, so a card put up during the shot would be
	switched off and stay off. Watching its ScreenGui is the signal it does not
	otherwise publish -- enabled means the curtain is up, disabled again means
	it has come down.

	Both waits are bounded. If the intro fails to build it destroys its gui and
	nothing is coming; if it hangs, the tutorial is still not the thing worth
	losing. Either way this falls through and shows the card.
]]
local function awaitIntro()
	local pg = player:WaitForChild("PlayerGui")
	local deadline = os.clock() + 8
	local sawCurtain = false
	while os.clock() < deadline do
		local g = pg:FindFirstChild("IntroCinema")
		if not g then
			break
		end
		if g.Enabled then
			sawCurtain = true
			break
		end
		task.wait(0.1)
	end
	if not sawCurtain then
		return
	end
	deadline = os.clock() + 60
	while os.clock() < deadline do
		local g = pg:FindFirstChild("IntroCinema")
		if not g or not g.Enabled then
			return
		end
		task.wait(0.2)
	end
end

function TutorialHud.start()
	if started then
		return
	end
	started = true

	-- Spawned and wrapped: this is the least important thing on the client and
	-- it is not allowed to be the reason a boot stops.
	task.spawn(function()
		local ok, err = pcall(function()
			if not wanted() then
				return
			end
			awaitIntro()
			-- Re-tested on the far side: the opening shot runs about fifteen
			-- seconds and the server may have finished loading them into it.
			if not wanted() then
				return
			end
			task.wait(1.2)
			TutorialHud.show()
		end)
		if not ok then
			warn("[CleanTheBeach] tutorial did not start: " .. tostring(err))
		end
	end)
end

return TutorialHud
