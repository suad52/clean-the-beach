--[[
	NextShoreHud  --  StarterPlayerScripts.NextShoreHud  (ModuleScript)

	HOW CLOSE THE FIRST ISLAND IS, ON SCREEN, FOR THE ONE TIDE IT MATTERS.

	WHY THIS EXISTS -- MEASURED, NOT GUESSED (2026-09-11). The MapUnlocks funnel
	over one day, 25,599 players:

		1. The Beach          25,599      100%
		2. The Dunes           8,532       33.33%
		3. The Vault           1,162        4.54%

	And the onboarding funnel over the same day says 21,609 of those finished all
	six tutorial steps. So THIRTEEN THOUSAND PLAYERS A DAY learn the whole loop --
	fill a bag, sell it, wash a lump, sell again, buy an upgrade -- and then quit
	on the home beach without ever seeing a second island. That is 51% of everyone
	who arrives, lost in one stretch.

	WHAT WAS ALREADY IN THAT STRETCH, because three things were and it is worth
	saying why a fourth is not a fourth copy:

	  TutorialOutro         flies them over the Dunes, the Cove and Ashfall the
	                        moment the card finishes. They are TOLD.
	  RebirthUnlockPrompt   explains what a rebirth buys and points at the boat --
	                        but only once the gate is already MET. It rewards
	                        arrival; it cannot pull anybody toward it.
	  TipConfig             rotates through pets, wash, index, duels. Randomly,
	                        and about three of them land in the first ten minutes.

	So the gap is not knowledge. It is that between being sold three islands at
	minute five and reaching the first at minute fifteen, NOTHING ON SCREEN SAYS
	HOW CLOSE THEY ARE. The rebirth panel has the bar; you have to go and open it,
	and the rail key that opens it is an uncaptioned wave icon. Ten minutes of
	visible progress toward a thing they were just shown, replaced by ten minutes
	of raking and hoping.

	IT NAMES THE PLACE, NOT THE MECHANIC. "THE DUNES", off FerryConfig, because
	that is the word the send-off just put in their head. "Rebirth" is a system;
	the island is the reward, and the reward is what belongs on a progress bar.

	TIDE ZERO ONLY, AND THEN GONE FOR EVER. `rebirths > 0` and this never builds
	again for that account. It is an onboarding aid, not permanent chrome -- the
	player who has turned the tide once has met the ferry, the rebirth panel and
	the unlock card, and does not need a fourth thing telling them about it.

	IT ADDS NOTHING TO THE SERVER. ProgressionSync already carries every field
	this draws -- rebirths, totalEarned, rebirthNeed, tideTrash, rebirthTrashNeed,
	canRebirth -- computed once in ProgressionServer.snapshot and pushed to the
	client that MenuHud and RebirthUnlockPrompt already listen to. No remote, no
	second source of truth, no way for this to disagree with the panel.

	HOW TO TELL WHETHER IT WORKED: MapUnlocks step 2 completion, currently
	33.33%. If it has not moved after a few days at 25k arrivals a day, this is
	not the answer and it should come out rather than sit there as speculative
	chrome. Watch step 3 (Dunes -> Vault, 13.62%) at the same time: if THAT drops,
	the churn has merely moved and the gate was not the problem.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local HudKit = require(Modules:WaitForChild("HudKit"))
local Net = require(Modules:WaitForChild("Net"))
local PanelKit = require(Modules:WaitForChild("PanelKit"))
-- The destination's NAME and COLOUR come from the ferry that sails there, so the
-- chip and the boat cannot end up calling the same island two different things.
local FerryConfig = require(ReplicatedStorage:WaitForChild("FerryConfig"))
-- For ProfileAttribute alone -- "the server has finished deciding who you are".
-- See the note on the settle test in apply().
local TutorialConfig = require(Modules:WaitForChild("TutorialConfig"))
-- For SeenAttribute only: whether RebirthUnlockPrompt has already had its one
-- turn. See the ready state in apply() for why that decides who speaks.
local RebirthPromptConfig = require(Modules:WaitForChild("RebirthPromptConfig"))

local player = Players.LocalPlayer

local NextShoreHud = {}

--[[
	THE COLUMN, AND THE NUMBERS ARE NOT INVENTED HERE.

	CleanTheBeachHUD stacks CoinPill (y 12, h 54), LoadPill (70, 38), RakedPill
	(115, 30) and the QuickSell key (158, 58); BoostHud continues it at 254. This
	sits under the lot at 292 -- measured, not estimated, so it cannot land on the
	boost pill on the one session where a tide-0 player has bought a boost.

	IgnoreGuiInset = false TO MATCH CleanTheBeachHUD, whose column this joins.
	BoostHud's own note has the reason: two ScreenGuis sharing a column must agree
	about the inset or they are laid out in different coordinate spaces and drift
	apart by the height of the topbar. (That is not theoretical here -- the
	tutorial card spent a release drawn UNDER the topbar for exactly this class of
	mistake.)

	UiFit needs no call: its start() watches PlayerGui.ChildAdded, so a ScreenGui
	parented below is picked up and given the same FitRoot and the same scale as
	the pills it is lining up with.
]]
local X, Y = 16, 292
local W, H = 256, 46
local RADIUS = 12
local BAR_H = 12

local gui, root, titleLabel, figureLabel, barLevel, barHolder
-- `retired` is gone with the permanent retire it guarded (2026-09-12). This pill
-- can now come back after a tide -- see the ready state in apply() -- so a latch
-- that could never be cleared was the one thing making that impossible.
local started = false
local shown = false
local barTween: Tween?

--[[
	THE BAR IS DRIVEN BY A NumberValue, NOT BY A CALL.

	HudKit.bar hands back a `Level` NumberValue whose Changed drives the fill and
	the foam -- see the note over the fill: nothing about that bar grows, the
	readout is a gradient cutoff, and this value is where the cutoff comes from.
	CTB_HUD's load pill tweens the same handle for the same reason.

	TWEENED RATHER THAN SET, because this number moves on every sale and a bar
	that jumps reads as a counter rather than as progress. Cancelled first: two
	live tweens on one value fight, and the loser wins about half the time.
]]
local function setLevel(t: number)
	if not barLevel then
		return
	end
	if barTween then
		barTween:Cancel()
	end
	barTween = TweenService:Create(barLevel,
		TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Value = math.clamp(t, 0, 1) })
	barTween:Play()
end

-- The first port that asks for a rebirth. Read rather than hard-coded: if the
-- map is ever reordered, or a new first island is added, this follows it.
local function firstGatedPort()
	local best
	for _, port in ipairs(FerryConfig.Ports or {}) do
		local need = tonumber(port.requireLevel) or 0
		if need > 0 and (best == nil or need < (tonumber(best.requireLevel) or 0)) then
			best = port
		end
	end
	return best
end

local function build()
	local port = firstGatedPort()
	local tint = (port and typeof(port.tint) == "Color3") and port.tint
		or Color3.fromRGB(255, 200, 62)

	gui = Instance.new("ScreenGui")
	gui.Name = "NextShoreHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	-- The same rung BoostHud takes: below EventHud (11) and MenuHud (12), and
	-- deterministic against the column it joins, which sits at 0.
	gui.DisplayOrder = 1
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	root = Instance.new("Frame")
	root.Name = "NextShorePill"
	root.Position = UDim2.fromOffset(X, Y)
	root.Size = UDim2.fromOffset(W, H)
	root.BackgroundTransparency = 1
	root.Parent = gui

	-- Untinted, which is this column's rule rather than a preference: HudKit's
	-- note over `key` says the readouts here are chrome and the one tinted thing
	-- is the one you can press. A coloured pill would read as a button. The
	-- island's colour goes on its NAME instead.
	local holder = HudKit.surface(root, W, H, RADIUS)
	holder.Position = UDim2.fromOffset(0, 0)

	titleLabel = HudKit.text(holder, string.upper(port and port.name or "THE NEXT SHORE"),
		15, tint, Enum.Font.LuckiestGuy)
	titleLabel.Position = UDim2.fromOffset(12, 4)
	titleLabel.Size = UDim2.fromOffset(150, 18)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.ZIndex = 6
	HudKit.punch(titleLabel, 2)

	figureLabel = HudKit.text(holder, "", 13, HudKit.C.rowSub, Enum.Font.GothamBold)
	figureLabel.AnchorPoint = Vector2.new(1, 0)
	figureLabel.Position = UDim2.new(1, -12, 0, 5)
	figureLabel.Size = UDim2.fromOffset(110, 16)
	figureLabel.TextXAlignment = Enum.TextXAlignment.Right
	figureLabel.ZIndex = 6

	local bh, _, _, _, _, level = HudKit.bar(holder, W - 24, BAR_H, tint,
		HudKit.darken(tint, 0.3))
	bh.Position = UDim2.fromOffset(12, H - BAR_H - 7)
	bh.ZIndex = 6
	barHolder, barLevel = bh, level
end

--[[
	WHICH GATE TO DRAW, AND IT IS THE ONE FURTHEST BEHIND.

	A rebirth needs coins earned this tide AND litter picked this tide -- see
	ProgressionConfig's litter block for why a coin gate alone does not ask
	anybody to actually clean a beach. Drawing only the coins would let the bar
	sit at 100% while the player is still short, which is the one thing a progress
	bar must never do.

	The litter gate is pitched so a player who earns their coins by raking never
	meets it, so in practice this is the coin bar almost always -- but "almost
	always" is not a thing to draw a promise on.
]]
local function ratio(have: number, need: number): number
	if need <= 0 then
		return 1
	end
	return math.clamp(have / need, 0, 1)
end

local function apply(snap)
	if type(snap) ~= "table" then
		return
	end

	--[[
		NOT UNTIL THE SERVER HAS SAID WHO THIS PLAYER IS.

		ProgressionServer pushes a snapshot on join, and on a returning player that
		first push carries rebirths = 0 -- the restore has not landed yet. Acting on
		it builds this pill in front of somebody with forty tides behind them and
		then retires it a second later, which is a flash of onboarding chrome across
		a veteran's screen on every single join.

		MEASURED, not guessed: without this test the pill built on a 40-rebirth
		account and read "THE DUNES $0 / $11K" before DevGrant's stamp arrived.

		IT IS THE SAME TRAP AND THE SAME FIX AS THE TUTORIAL CARD, which spent a
		release being raised for veterans for exactly this reason -- see
		TutorialConfig.ProfileAttribute, which was added for it. Any client feature
		that branches on "is this player new" has to wait for that flag; the join
		push is not an answer to that question.

		DROPPED, NOT QUEUED. Another snapshot follows the settle within moments
		(SaveService's restore calls ProgressionServer.push itself), so there is
		nothing to hold on to.
	]]
	if not TutorialConfig.profileSettled(player) then
		return
	end

	--[[
		THE GATE IS MET -- AND THIS NO LONGER JUST GETS OUT OF THE WAY.
		(Rewritten 2026-09-12, off two reports.)

		IT USED TO HIDE HERE and hand the moment to RebirthUnlockPrompt, on the
		reasoning that the card explains the rebirth better than a finished bar
		can. The card does -- ONCE. It stamps RebirthPromptSeen and never speaks
		again for that account. So a player who met the gate, glanced at the card,
		dismissed it and carried on raking had, from that moment, NOTHING anywhere
		telling them the rebirth was sitting there waiting.

		That is a real player, in German, on the live build: "Man kann keine
		Wiedergeburt machen" -- you can't do a rebirth. They had 37,558 earned
		against a gate of 10,800 and simply did not know. They worked it out
		eventually; their profile has two tides on it now. It is also the third
		report of its kind -- "How do I rebirth?" came in twice before.

		So: while the card still has its one turn to take, stay out of its way.
		After that, this is the only thing left that can say it, and it says it.

		PAST TIDE ZERO TOO, which the block below deliberately did not do. The old
		rule was "one tide and they have met the ferry and the panel, so they know
		how the game works". The other report this week was somebody at ELEVEN
		rebirths asking how to reach an island gated at four. One tide does not
		teach the game.
	]]
	if snap.canRebirth == true then
		if player:GetAttribute(RebirthPromptConfig.SeenAttribute) ~= true then
			-- The card is about to speak. Two of these at once would be the fourth
			-- copy this module's header is careful not to be.
			if gui then
				gui.Enabled = false
			end
			shown = false
			return
		end
		if not gui then
			build()
		end
		-- NAMES THE MECHANIC HERE, not the island -- the opposite of the rule in
		-- the header, and on purpose. Up there the island is the reward and
		-- "rebirth" is jargon. Here the player has already earned the island and
		-- what they cannot find is the BUTTON, so the button is what it names.
		titleLabel.Text = "TURN THE TIDE"
		figureLabel.Text = "READY"
		setLevel(1)
		if not shown then
			shown = true
			gui.Enabled = true
			root.Position = UDim2.fromOffset(X - 28, Y)
			TweenService:Create(root, TweenInfo.new(0.35, Enum.EasingStyle.Back,
				Enum.EasingDirection.Out), { Position = UDim2.fromOffset(X, Y) }):Play()
		end
		return
	end

	--[[
		PAST TIDE ZERO AND NOT READY: NOTHING.

		Hidden rather than retired. The old code set `retired` here and never
		built again for that account, which is what made the ready state above
		impossible to reach for anybody past their first tide -- and "past their
		first tide" is every player the second report came from.

		Still no permanent chrome: between tides this pill is off, and it comes
		back only when the player has actually earned something and has not
		noticed. A bar counting toward a gate they are mid-way through is the
		clutter the header warns about; "you can do this now" is not.
	]]
	if (tonumber(snap.rebirths) or 0) > 0 then
		if gui then
			gui.Enabled = false
		end
		shown = false
		return
	end

	if not gui then
		build()
	end

	local earned = tonumber(snap.totalEarned) or 0
	local need = tonumber(snap.rebirthNeed) or 0
	local trash = tonumber(snap.tideTrash) or 0
	local trashNeed = tonumber(snap.rebirthTrashNeed) or 0

	local coinAt = ratio(earned, need)
	local trashAt = ratio(trash, trashNeed)

	if trashNeed > 0 and trashAt < coinAt then
		figureLabel.Text = string.format("%s / %s trash",
			PanelKit.compact(trash), PanelKit.compact(trashNeed))
		setLevel(trashAt)
	else
		figureLabel.Text = string.format("$%s / $%s",
			PanelKit.compact(earned), PanelKit.compact(need))
		setLevel(coinAt)
	end

	if not shown then
		shown = true
		gui.Enabled = true
		-- Slides in from the left rather than appearing: the column it joins is
		-- already on screen, and a pill that pops into a settled stack reads as a
		-- glitch.
		root.Position = UDim2.fromOffset(X - 28, Y)
		TweenService:Create(root, TweenInfo.new(0.35, Enum.EasingStyle.Back,
			Enum.EasingDirection.Out), { Position = UDim2.fromOffset(X, Y) }):Play()
	end
end

function NextShoreHud.start()
	if started then
		return
	end
	started = true

	--[[
		NOTHING IS BUILT UNTIL A SNAPSHOT SAYS IT SHOULD BE. build() runs on the
		first push that shows a tide-0 player short of the gate -- so a returning
		veteran never allocates this at all, and the join path costs them nothing.
		That is the same lesson the Index panel taught this week: 159 viewports
		built at boot for a board nobody had opened.
	]]
	Net.get("ProgressionSync").OnClientEvent:Connect(apply)
end

return NextShoreHud
