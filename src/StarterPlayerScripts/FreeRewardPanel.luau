--[[
	FreeRewardPanel  --  StarterPlayerScripts.FreeRewardPanel

	The FREE REWARD card: 1,000 coins for joining the group. Pops up once on join
	while it is still unclaimed, and opens again from the board on the far side of
	the beach.

	BUILT FROM PanelKit, NOT FROM THE MOCKUP IMAGE, and that is a decision worth
	stating. The design was handed over as a picture, and a picture can be shipped
	two ways: upload it and draw buttons on top of it, or rebuild it. Uploading it
	loses, here, for a reason this place has already been bitten by twice --
	Roblox refuses to serve an image the EXPERIENCE'S OWNER does not own, and it
	refuses SILENTLY. This place belongs to a group; an asset uploaded from a
	personal account renders perfectly for the uploader and is an empty rectangle
	for every player. See the note on the RAIL table in MenuHud, which records the
	same trap costing a shop icon.

	So the LAYOUT is the mockup's -- header, a prize pane on the left, a
	requirements pane on the right, two numbered steps, a claim button -- and every
	pixel of it is drawn by PanelKit, which every other panel in the game is drawn
	by. It cannot fail to load and it matches the rest of the interface.

	THERE IS ONE REQUIREMENT NOW, AND IT IS THE ONE THE SERVER CAN CHECK.

	This card used to carry two numbered steps: LIKE THE GAME, then JOIN THE GROUP.
	Step 1 was a button that reported the player's own word back to the server,
	which recorded it and then required it -- so a player who never liked anything
	could press it, press CLAIM, and be paid. That is not a check and the card
	should never have drawn it as one, tick and all.

	It is gone rather than reworded. Roblox exposes no API that could turn it into
	a check (see FreeRewardConfig), and rewarding an individual player for a like
	is against Roblox's rules besides. What is left is the group, which the SERVER
	asks Roblox about at the moment of the claim.

	Do not add a client-reported "liked" boolean back to the remote: it would be
	the player's own machine answering a question about the player.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local PanelKit = require(Modules:WaitForChild("PanelKit"))
local FreeRewardConfig = require(Modules:WaitForChild("FreeRewardConfig"))
local Net = require(Modules:WaitForChild("Net"))
local UiFit = require(Modules:WaitForChild("UiFit"))

-- Touch targets: see the module. Substituted for MouseButton1Click/Activated so
-- a tap in the margin around a control that renders under 44px on a phone still
-- reaches the same handler. No-ops on desktop and on controls already big enough.
local TouchFit = require(Modules:WaitForChild("TouchFit"))
-- For DoneAttribute only -- see awaitTutorial. This file does not drive the
-- tutorial, it just refuses to land on top of it.
local TutorialConfig = require(Modules:WaitForChild("TutorialConfig"))

local player = Players.LocalPlayer
local C = PanelKit.C
local corner, outline, grad, gloss = PanelKit.corner, PanelKit.outline, PanelKit.grad, PanelKit.gloss
local chunky, text, punch, darken = PanelKit.chunky, PanelKit.text, PanelKit.punch, PanelKit.darken

local FreeRewardPanel = {}

local W, H = 640, 400
local PROMPT_NAME = "FreeRewardPrompt"

local gui, root, scrim
local state = nil
local shownThisSession = false
local widgets = {}

local function comma(n)
	local o = tostring(math.floor(n or 0)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (o:gsub("^,", ""))
end

----------------------------------------------------------------
-- THE COIN STACK
----------------------------------------------------------------
-- Four ellipses and a face-on disc, which is the mockup's pile in the cheapest
-- shape that reads at this size. Drawn rather than an image, for the reason in
-- the header.
local function coinStack(parent: GuiObject)
	local holder = Instance.new("Frame")
	holder.Name = "Coins"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.62)
	holder.Size = UDim2.fromOffset(150, 110)
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	for i = 1, 4 do
		local c = Instance.new("Frame")
		c.Name = "Disc" .. i
		c.AnchorPoint = Vector2.new(0.5, 1)
		c.Position = UDim2.new(0.42, 0, 1, -(i - 1) * 15)
		c.Size = UDim2.fromOffset(104, 26)
		c.BackgroundColor3 = (i % 2 == 0) and C.sun or Color3.fromRGB(240, 178, 34)
		c.BorderSizePixel = 0
		c.ZIndex = 5 + i
		c.Parent = holder
		corner(c, 13)
		outline(c, 3.5)
	end

	-- The face-on coin, with a $ on it.
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.78, 0.42)
	face.Size = UDim2.fromOffset(78, 78)
	face.BackgroundColor3 = C.sun
	face.BorderSizePixel = 0
	face.ZIndex = 10
	face.Parent = holder
	corner(face, 39)
	outline(face, 4)
	grad(face, C.sun:Lerp(C.white, 0.35), darken(C.sun, 0.18))
	local rim = Instance.new("Frame")
	rim.AnchorPoint = Vector2.new(0.5, 0.5)
	rim.Position = UDim2.fromScale(0.5, 0.5)
	rim.Size = UDim2.fromOffset(56, 56)
	rim.BackgroundTransparency = 1
	rim.ZIndex = 11
	rim.Parent = face
	corner(rim, 28)
	outline(rim, 3, darken(C.sun, 0.45))
	local dollar = text(face, "$", 40, Enum.Font.LuckiestGuy, darken(C.sun, 0.5))
	dollar.Size = UDim2.fromScale(1, 1)
	dollar.ZIndex = 12
	return holder
end

----------------------------------------------------------------
-- BUILD
----------------------------------------------------------------
local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FreeRewardGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	-- Above MenuHud (12) so the join-time card is not opened behind an open menu,
	-- and below the intro's curtain, which owns the screen while it runs.
	gui.DisplayOrder = 20
	gui.Parent = player:WaitForChild("PlayerGui")

	scrim = Instance.new("Frame")
	scrim.Name = "Scrim"
	scrim.AnchorPoint = Vector2.new(0.5, 0.5)
	scrim.Position = UDim2.fromScale(0.5, 0.5)
	scrim.Size = UDim2.fromScale(4, 4)
	scrim.BackgroundColor3 = Color3.fromRGB(16, 24, 40)
	scrim.BackgroundTransparency = 1
	scrim.BorderSizePixel = 0
	scrim.ZIndex = 0
	scrim.Parent = gui

	local card, body, closeFace = PanelKit.card(gui, "Free Reward", W, H, C.grape)
	root = card
	root.Visible = false
	TouchFit.press(closeFace, function()
		FreeRewardPanel.close()
	end)

	----------------------------------------------------------------
	-- LEFT: THE PRIZE
	----------------------------------------------------------------
	local left = Instance.new("Frame")
	left.Name = "Prize"
	left.Size = UDim2.new(0.4, -6, 1, 0)
	left.BackgroundColor3 = C.white
	left.BorderSizePixel = 0
	left.Parent = body
	corner(left, 18)
	outline(left, 3.5)
	grad(left, C.white, C.sand)

	local coinsWord = text(left, "COINS", 30, Enum.Font.LuckiestGuy, C.sun)
	coinsWord.Position = UDim2.new(0, 0, 0, 12)
	coinsWord.Size = UDim2.new(1, 0, 0, 34)
	punch(coinsWord, 3)

	widgets.amount = text(left, comma(FreeRewardConfig.Coins), 34, Enum.Font.LuckiestGuy,
		darken(C.sun, 0.15))
	widgets.amount.Position = UDim2.new(0, 0, 0, 46)
	widgets.amount.Size = UDim2.new(1, 0, 0, 36)
	punch(widgets.amount, 3)

	coinStack(left)

	----------------------------------------------------------------
	-- RIGHT: THE REQUIREMENTS
	----------------------------------------------------------------
	local right = Instance.new("Frame")
	right.Name = "Requirements"
	right.AnchorPoint = Vector2.new(1, 0)
	right.Position = UDim2.new(1, 0, 0, 0)
	right.Size = UDim2.new(0.6, -6, 1, 0)
	right.BackgroundColor3 = C.white
	right.BorderSizePixel = 0
	right.Parent = body
	corner(right, 18)
	outline(right, 3.5)
	grad(right, C.white, C.sand)

	local head = text(right, "REQUIREMENT", 24, Enum.Font.LuckiestGuy, C.sun)
	head.Position = UDim2.new(0, 0, 0, 10)
	head.Size = UDim2.new(1, 0, 0, 28)
	punch(head, 2.5)

	-- THE ONE REQUIREMENT, and it is real: pressing it makes the SERVER go and ask
	-- Roblox again, so a player who joined the group a moment ago does not have to
	-- rejoin the game. Unnumbered now that it is not one of a pair.
	local groupHolder, groupFace, groupSlab = chunky(right, 300, 46, C.sun, 14)
	groupHolder.AnchorPoint = Vector2.new(0.5, 0)
	groupHolder.Position = UDim2.new(0.5, 0, 0, 50)
	widgets.groupLabel = text(groupFace, "JOIN THE GROUP", 20, Enum.Font.LuckiestGuy, C.white)
	widgets.groupLabel.Size = UDim2.fromScale(1, 1)
	widgets.groupLabel.ZIndex = 6
	punch(widgets.groupLabel, 3)
	widgets.groupFace, widgets.groupSlab = groupFace, groupSlab
	TouchFit.press(groupFace, function()
		Net.get("FreeRewardClaim"):FireServer("check")
		widgets.hint.Text = "CHECKING..."
	end)

	widgets.hint = text(right, "", 14, Enum.Font.GothamBold, Color3.fromRGB(132, 108, 82))
	widgets.hint.Position = UDim2.new(0, 10, 0, 112)
	widgets.hint.Size = UDim2.new(1, -20, 0, 56)
	widgets.hint.TextWrapped = true
	widgets.hint.TextTruncate = Enum.TextTruncate.None

	--[[
		A PLAIN ASK, WORTH NOTHING, AND SAYING SO IN THE LINE ITSELF.

		Asking for a like is fine. PAYING an individual player for one is the part
		Roblox forbids, so this states outright that the reward does not depend on
		it -- which is also true, and is the difference between a courtesy and a
		bribe.

		Deliberately NOT a button. A button in this pane reads as a step whatever
		its caption says, and a step that does nothing is the thing being removed.
	]]
	local nudge = text(right, "Enjoying the game? A like helps a lot \u{2014} it is not "
		.. "needed for this reward.", 12, Enum.Font.Gotham, Color3.fromRGB(158, 134, 108))
	nudge.Position = UDim2.new(0, 10, 0, 174)
	nudge.Size = UDim2.new(1, -20, 0, 40)
	nudge.TextWrapped = true
	nudge.TextTruncate = Enum.TextTruncate.None

	local claimHolder, claimFace, claimSlab = chunky(right, 300, 54, C.lime, 16)
	claimHolder.AnchorPoint = Vector2.new(0.5, 1)
	claimHolder.Position = UDim2.new(0.5, 0, 1, -12)
	widgets.claimLabel = text(claimFace, "CLAIM", 26, Enum.Font.LuckiestGuy, C.white)
	widgets.claimLabel.Size = UDim2.fromScale(1, 1)
	widgets.claimLabel.ZIndex = 6
	punch(widgets.claimLabel, 3)
	widgets.claimFace, widgets.claimSlab = claimFace, claimSlab
	TouchFit.press(claimFace, function()
		if not widgets.claimLive then
			return
		end
		Net.get("FreeRewardClaim"):FireServer("claim")
	end)
end

----------------------------------------------------------------
-- PAINT
----------------------------------------------------------------
function FreeRewardPanel.refresh()
	if not root then
		return
	end
	local claimed = state and state.claimed == true
	-- THE SERVER'S OWN ANSWER FROM ROBLOX, never a local flag: this button can
	-- never say "ready" for a claim the server is going to refuse, and the tick
	-- means a fact rather than a tap.
	local inGroup = state and state.inGroup == true

	PanelKit.retint(widgets.groupFace, widgets.groupSlab, inGroup and C.foam or C.sun)
	widgets.groupLabel.Text = inGroup and "IN THE GROUP  \u{2713}" or "JOIN THE GROUP"

	local live = (not claimed) and inGroup
	widgets.claimLive = live

	if claimed then
		widgets.claimLabel.Text = "CLAIMED"
		PanelKit.retint(widgets.claimFace, widgets.claimSlab, C.sandDeep)
		widgets.hint.Text = "You have already claimed this reward. Thanks!"
	elseif live then
		widgets.claimLabel.Text = "CLAIM"
		PanelKit.retint(widgets.claimFace, widgets.claimSlab, C.lime)
		widgets.hint.Text = string.format("Ready! Press CLAIM for %s coins.",
			comma(FreeRewardConfig.Coins))
	else
		widgets.claimLabel.Text = "CLAIM"
		PanelKit.retint(widgets.claimFace, widgets.claimSlab, C.sandDeep)
		widgets.hint.Text = string.format(
			"Join the %s group, then press the button above to re-check.",
			(state and state.groupName) or FreeRewardConfig.GroupName)
	end

	widgets.amount.Text = comma((state and state.coins) or FreeRewardConfig.Coins)
end

----------------------------------------------------------------
-- OPEN / CLOSE
----------------------------------------------------------------
function FreeRewardPanel.open()
	if not root then
		return
	end
	FreeRewardPanel.refresh()
	TweenService:Create(scrim, TweenInfo.new(0.18), { BackgroundTransparency = 0.45 }):Play()
	PanelKit.popIn(root, W, H)
end

function FreeRewardPanel.close()
	if not root then
		return
	end
	root.Visible = false
	TweenService:Create(scrim, TweenInfo.new(0.14), { BackgroundTransparency = 1 }):Play()
end

----------------------------------------------------------------
-- NOT ON TOP OF THE TUTORIAL
----------------------------------------------------------------
--[[
	(2026-09-11, alongside the tip-band work -- same complaint, same cause: two
	unprompted things sharing a screen because nothing coordinates them.)

	This card is a centred modal with a scrim, and until now it was raised as soon
	as the opening shot cleared -- which for a brand-new player is the exact
	second the tutorial starts telling them what to do. Two cards, two voices, and
	the one they have to answer first is the one about a group they have never
	heard of.

	The reward is also worth MORE after the tutorial than during it. Coins mean
	nothing to somebody who has not yet sold a bag.

	THE COST, STATED PLAINLY: a player who quits mid-tutorial now never sees the
	offer. That is the trade, and it is why the wait is bounded rather than
	absolute -- five minutes and the card comes up regardless.
]]
local function tutorialUp(): boolean
	local pg = player:FindFirstChild("PlayerGui")
	local hud = pg and pg:FindFirstChild("TutorialHud")
	return hud ~= nil and hud:IsA("ScreenGui") and hud.Enabled
end

local function awaitTutorial()
	-- A player who has already finished it will never raise the HUD at all, so
	-- without this they would sit through the grace period below for nothing.
	if player:GetAttribute(TutorialConfig.DoneAttribute) then
		return
	end

	--[[
		"NOT UP YET" AND "NOT COMING" LOOK THE SAME AT FIRST, and that is the one
		thing this has to get right. TutorialHud raises itself behind a bounded
		profile wait of its own, so for the first few seconds after the intro the
		HUD is absent whether or not it is about to appear. `seen` is what tells
		them apart: once the card has been up, its going down means finished; if
		it never comes up inside the grace window, it was never owed.
	]]
	local deadline = os.clock() + 300
	local grace = os.clock() + 20
	local seen = false
	while os.clock() < deadline do
		if tutorialUp() then
			seen = true
		elseif seen or os.clock() > grace then
			return
		end
		if player:GetAttribute(TutorialConfig.DoneAttribute) then
			return
		end
		task.wait(0.5)
	end
end

----------------------------------------------------------------
-- BOOT
----------------------------------------------------------------
local started = false
function FreeRewardPanel.start()
	if started then
		return
	end
	started = true

	build()
	-- fit(), which is what AfkClient, DuelClient and TutorialHud all use to hand a
	-- ScreenGui of their own to the global scaler. (There is no adopt().)
	UiFit.fit(gui)

	Net.get("FreeRewardSync").OnClientEvent:Connect(function(snap)
		if type(snap) ~= "table" then
			return
		end
		state = snap
		FreeRewardPanel.refresh()

		--[[
			THE POP-UP, and it is shown ONCE per session and only while unclaimed.

			"Whenever you join" is what was asked for and is what this does -- the
			card is up on every join until the reward has been taken. After that it
			stops, because a card advertising a thing you already own, on every
			single join, forever, is the definition of nagging.

			It waits for the intro to be out of the way. IntroCinema owns the screen
			for the first couple of seconds and raises an opaque curtain over it;
			a card popped behind that is a card the player never sees.
		]]
		--[[
			WAIT FOR `loaded`. The first sync arrives before the profile does -- the
			server's group lookup and SaveService's DataStore read race each other --
			and in that first payload `claimed = false` means "not known yet", not
			"they have not claimed". Opening on it showed the offer to players who
			had already taken it, and which way it fell was down to whichever web
			call happened to finish first.

			The server sends a second, unconditional sync once the profile is in.
			That is the one this acts on.
		]]
		if not shownThisSession and snap.loaded and not snap.claimed then
			shownThisSession = true
			task.spawn(function()
				local pg = player:FindFirstChild("PlayerGui")
				local waited = 0
				-- ENABLED, NOT PRESENT. Measured 2026-09-25, applied 2026-09-28. An
				-- IntroCinema gui is still in PlayerGui at 81s, Enabled = false, long
				-- after IntroClient destroyed its own -- so a presence test is true for
				-- the whole session and this loop burned its full 12 seconds on every
				-- join for nothing. Same defect as TipClient's introUp, where it was
				-- costing 30s in front of every tip; both were held three days so they
				-- would not shift timing under a pending D1 read.
				while waited < 12 do
					local intro = pg and pg:FindFirstChild("IntroCinema")
					if not (intro and intro.Enabled) then
						break
					end
					task.wait(0.25)
					waited += 0.25
				end
				awaitTutorial()
				task.wait(0.6)
				if root and not (state and state.claimed) then
					FreeRewardPanel.open()
				end
			end)
		end
	end)

	-- The board on the far side of the beach. Matched BY NAME, so renaming the
	-- prompt in FreeRewardBoard unhooks this -- the same contract MenuHud's world
	-- prompts keep with the shop counters.
	ProximityPromptService.PromptTriggered:Connect(function(prompt, plr)
		if plr == player and prompt.Name == PROMPT_NAME then
			FreeRewardPanel.open()
		end
	end)
end

return FreeRewardPanel