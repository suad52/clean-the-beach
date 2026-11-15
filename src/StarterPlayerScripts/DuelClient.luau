--[[
	DuelClient  --  StarterPlayerScripts.DuelClient

	The player's half of THE CLEAN-OFF: clicking somebody to challenge them, the
	invite that arrives, the count-in, the live score and the result.

	FIVE CARDS, ONE ScreenGui, shown by PHASE. The server sends one snapshot per
	push and this file decides nothing about the match from it -- no local score,
	no local timer, no local "I think I won". Everything on screen is the last
	thing the server said, which is the only way two clients watching one race
	can agree about it.

	CLICKING A PLAYER is the door. It is checked twice and neither check is
	trusted on its own: here, so the card only appears over a real, living,
	nearby player; and again on the server, off the characters' actual positions,
	because a client saying "we are standing together" is not evidence.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local DuelConfig = require(Modules:WaitForChild("DuelConfig"))
local Net = require(Modules:WaitForChild("Net"))
local PanelKit = require(Modules:WaitForChild("PanelKit"))
local UiFit = require(Modules:WaitForChild("UiFit"))

-- Touch targets: see the module. Substituted for MouseButton1Click/Activated so
-- a tap in the margin around a control that renders under 44px on a phone still
-- reaches the same handler. No-ops on desktop and on controls already big enough.
local TouchFit = require(Modules:WaitForChild("TouchFit"))

local C = PanelKit.C
local player = Players.LocalPlayer

local DuelClient = {}

local gui
local challengeCard, challengeName, challengeTarget
local inviteCard, inviteName, inviteBar
local hudCard, hudArena, hudYou, hudThem, hudClock
local bigCard, bigText, bigSub
local state = nil
local started = false

--------------------------------------------------------------------------
-- CARDS
--------------------------------------------------------------------------
--[[
	LIGHT TYPE ON THESE CARDS, ALWAYS.

	PanelKit.card puts a dark wood WELL (66,42,26 -> 104,70,44) behind the body,
	so every label below is drawn on near-black brown. These four cards were
	written while that well was still cream and asked for C.ink (56,36,20) and a
	darkened sandDeep -- ink on the well they actually sit on is a twenty-point
	colour difference and could not be read at all.

	The invite was the worst of the four to lose, because it is the one card that
	arrives UNASKED, over whatever the player was doing, and runs out on a timer:
	there is no going back to it to squint. A player could not see who had
	challenged them.

	Nothing here is a new idea -- the Trade invite next door is white type on the
	same well and always was, and so is every rail panel. These two constants
	exist so the next card added to this file starts from the right place.
]]
local BODY = C.sand      -- captions, blurbs, the small print
local HEAD = C.white     -- names, numbers, anything punched with an ink stroke

local function pill(parent, w, h, tint, label, y)
	local holder, face = PanelKit.chunky(parent, w, h, tint, 12)
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.new(0.5, 0, 1, y or 0)
	local t = PanelKit.text(face, label, 18, Enum.Font.LuckiestGuy, C.white)
	t.Size = UDim2.fromScale(1, 1)
	PanelKit.punch(t, 2)
	return holder, face
end

local function buildChallenge()
	local root, body, closeFace = PanelKit.card(gui, "CHALLENGE", 320, 176, C.coral)
	root.Name = "Challenge"
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.62)
	root.Visible = false
	if closeFace and closeFace.Parent then closeFace.Parent:Destroy() end
	challengeCard = root

	challengeName = PanelKit.text(body, "", 24, Enum.Font.LuckiestGuy, HEAD)
	challengeName.Size = UDim2.new(1, 0, 0, 30)
	challengeName.Position = UDim2.fromOffset(0, 4)
	PanelKit.punch(challengeName, 2.5)

	-- SAYS THE PRICE OUT LOUD. The clean-off pays no coins (DuelConfig owns the
	-- why), and a mode that pays nothing has to say so on the way in -- a player
	-- who accepted expecting a payout reads the empty result card as a bug.
	-- One line only: the body is 102px and the buttons take the bottom 40.
	local blurb = PanelKit.text(body, "Clear your patch first -- pride only.", 14,
		Enum.Font.GothamBold, BODY)
	blurb.Size = UDim2.new(1, 0, 0, 20)
	blurb.Position = UDim2.fromOffset(0, 36)

	local _, go = pill(body, 132, 40, C.lime, "CHALLENGE", 0)
	go.Parent.Position = UDim2.new(0.5, -70, 1, 0)
	TouchFit.press(go, function()
		if challengeTarget then
			Net.get("DuelChallenge"):FireServer(challengeTarget)
		end
		challengeCard.Visible = false
		challengeTarget = nil
	end)
	local _, no = pill(body, 118, 40, C.woodDark, "CANCEL", 0)
	no.Parent.Position = UDim2.new(0.5, 70, 1, 0)
	TouchFit.press(no, function()
		challengeCard.Visible = false
		challengeTarget = nil
	end)
end

local function buildInvite()
	local root, body, closeFace = PanelKit.card(gui, "A CHALLENGER", 340, 190, C.sun)
	root.Name = "Invite"
	root.AnchorPoint = Vector2.new(0.5, 0)
	-- 134. It moved down when EventHud took the top of the screen for its
	-- countdown and ToastKit's tip card moved down under it -- and it moved TWELVE
	-- further than that shift needed, because measuring the tip card on the way
	-- past showed the old 96 was already seven pixels INSIDE a two-line tip. The
	-- gap was documented as four and had never been measured. ToastKit's TIP_TOP
	-- note owns that sum; this is the number it now expects.
	root.Position = UDim2.new(0.5, 0, 0, 134)
	root.Visible = false
	if closeFace and closeFace.Parent then closeFace.Parent:Destroy() end
	inviteCard = root

	inviteName = PanelKit.text(body, "", 22, Enum.Font.LuckiestGuy, HEAD)
	inviteName.Size = UDim2.new(1, 0, 0, 28)
	inviteName.Position = UDim2.fromOffset(0, 2)
	PanelKit.punch(inviteName, 2.5)

	local blurb = PanelKit.text(body, "wants a clean-off -- pride only", 14,
		Enum.Font.GothamBold, BODY)
	blurb.Size = UDim2.new(1, 0, 0, 18)
	blurb.Position = UDim2.fromOffset(0, 30)

	-- The invite times out; the bar is the only honest way to say so.
	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, 0, 0, 10)
	track.Position = UDim2.fromOffset(0, 56)
	track.BackgroundColor3 = C.sandDeep
	track.BorderSizePixel = 0
	track.Parent = body
	PanelKit.corner(track, 5)
	inviteBar = Instance.new("Frame")
	inviteBar.Size = UDim2.fromScale(1, 1)
	inviteBar.BackgroundColor3 = C.coral
	inviteBar.BorderSizePixel = 0
	inviteBar.Parent = track
	PanelKit.corner(inviteBar, 5)

	local _, yes = pill(body, 132, 42, C.lime, "ACCEPT", 0)
	yes.Parent.Position = UDim2.new(0.5, -72, 1, 0)
	TouchFit.press(yes, function()
		Net.get("DuelReply"):FireServer(true)
		inviteCard.Visible = false
	end)
	local _, no = pill(body, 126, 42, C.coralDark, "DECLINE", 0)
	no.Parent.Position = UDim2.new(0.5, 72, 1, 0)
	TouchFit.press(no, function()
		Net.get("DuelReply"):FireServer(false)
		inviteCard.Visible = false
	end)
end

local function buildHud()
	local root, body, closeFace = PanelKit.card(gui, "CLEAN-OFF", 300, 150, C.sea)
	root.Name = "Hud"
	root.AnchorPoint = Vector2.new(0.5, 0)
	root.Position = UDim2.new(0.5, 0, 0, 84)
	root.Visible = false
	if closeFace and closeFace.Parent then closeFace.Parent:Destroy() end
	hudCard = root

	hudArena = PanelKit.text(body, "", 15, Enum.Font.GothamBold, BODY)
	hudArena.Size = UDim2.new(1, 0, 0, 18)

	-- YOURS on the left, THEIRS on the right, and the numbers are the whole
	-- readout: a race is "how many left", not a percentage.
	-- The bright ends of the two hues rather than the dark ends: limeDark and
	-- coralDark were picked to sit on cream and both go muddy on the well. The
	-- ink stroke below is what keeps them from glowing.
	hudYou = PanelKit.text(body, "0", 40, Enum.Font.LuckiestGuy, C.lime)
	hudYou.Size = UDim2.new(0.45, 0, 0, 44)
	hudYou.Position = UDim2.fromOffset(0, 22)
	PanelKit.punch(hudYou, 2.5)
	local youCap = PanelKit.text(body, "YOU", 12, Enum.Font.GothamBold, BODY)
	youCap.Size = UDim2.new(0.45, 0, 0, 14)
	youCap.Position = UDim2.fromOffset(0, 64)

	hudThem = PanelKit.text(body, "0", 40, Enum.Font.LuckiestGuy, C.coral)
	hudThem.Size = UDim2.new(0.45, 0, 0, 44)
	hudThem.Position = UDim2.new(0.55, 0, 0, 22)
	PanelKit.punch(hudThem, 2.5)
	local themCap = PanelKit.text(body, "THEM", 12, Enum.Font.GothamBold, BODY)
	themCap.Size = UDim2.new(0.45, 0, 0, 14)
	themCap.Position = UDim2.new(0.55, 0, 0, 64)

	hudClock = PanelKit.text(body, "", 20, Enum.Font.LuckiestGuy, HEAD)
	hudClock.Size = UDim2.new(1, 0, 0, 24)
	hudClock.Position = UDim2.new(0, 0, 1, -26)
	PanelKit.punch(hudClock, 2)
end

-- The count-in and the result share one big centred card: they never overlap,
-- and two cards that can never both be up are one card with two faces.
local function buildBig()
	local root = Instance.new("Frame")
	root.Name = "Big"
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.42)
	root.Size = UDim2.fromOffset(420, 150)
	root.BackgroundTransparency = 1
	root.Visible = false
	root.Parent = gui
	bigCard = root

	bigText = PanelKit.text(root, "", 76, Enum.Font.LuckiestGuy, C.white)
	bigText.Size = UDim2.new(1, 0, 0, 96)
	PanelKit.punch(bigText, 4)

	bigSub = PanelKit.text(root, "", 20, Enum.Font.LuckiestGuy, C.sun)
	bigSub.Size = UDim2.new(1, 0, 0, 28)
	bigSub.Position = UDim2.fromOffset(0, 100)
	PanelKit.punch(bigSub, 2.5)
end

--------------------------------------------------------------------------
-- PAINT
--------------------------------------------------------------------------

local function paint()
	if not gui then return end
	if not state then
		hudCard.Visible = false
		bigCard.Visible = false
		return
	end

	hudArena.Text = state.arenaName or ""
	hudYou.Text = tostring(state.youLeft or 0)
	hudThem.Text = tostring(state.theyLeft or 0)

	if state.phase == "countdown" then
		hudCard.Visible = true
		hudClock.Text = state.blurb or ""
		bigCard.Visible = true
		bigText.Text = (state.seconds and state.seconds > 1) and tostring((state.seconds or 1) - 1) or "GO"
		bigSub.Text = (state.oppName and ("vs " .. state.oppName)) or ""
	elseif state.phase == "race" then
		hudCard.Visible = true
		hudClock.Text = ("%d:%02d left"):format(math.floor((state.seconds or 0) / 60), (state.seconds or 0) % 60)
		-- GO holds for a beat after the count so the start reads.
		bigCard.Visible = (state.seconds or 0) > DuelConfig.RoundSeconds - 1
		bigText.Text = "GO"
		bigSub.Text = ""
	elseif state.phase == "result" then
		hudCard.Visible = true
		hudClock.Text = ""
		bigCard.Visible = true
		local r = state.result
		bigText.Text = (r == "win" and "YOU WIN") or (r == "lose" and "YOU LOSE") or "A DRAW"
		bigText.TextColor3 = (r == "win") and C.lime or ((r == "lose") and C.coral or C.white)
		-- NO PRIZE LINE. The clean-off pays nothing, so the sub-line carries the
		-- only two things a purely competitive race has to report: the scoreline
		-- in pieces cleared, and how many of these you have won.
		local total = state.total or DuelConfig.LitterCount
		bigSub.Text = ("%d - %d  |  %d WINS"):format(
			total - (state.youLeft or total),
			total - (state.theyLeft or total),
			state.wins or 0)
	else
		hudCard.Visible = false
		bigCard.Visible = false
	end
end

--------------------------------------------------------------------------
-- CLICKING SOMEBODY
--------------------------------------------------------------------------

local function playerUnderMouse(): Player?
	local mouse = player:GetMouse()
	local target = mouse and mouse.Target
	if not target then return nil end
	local model = target:FindFirstAncestorOfClass("Model")
	while model do
		local other = Players:GetPlayerFromCharacter(model)
		if other then return other end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

--[[
	THE WASH BAY IS A NO-DUEL ZONE.

	Clicking somebody raises the challenge card -- and inside a bay, CLICKING IS
	THE GAME: the washer fires on mouse button one. So every shot that went past
	the lump and landed on a player in the next stall threw a CHALLENGE card up
	over the wash HUD, in the one place in this game the player cannot walk out
	of and is plainly not looking for a duel in.

	CHECKED ON BOTH ENDS. Refusing only the click made from inside a bay still
	leaves somebody stood on the sand outside able to pull a washing player into
	an arena twelve thousand studs away, mid-session -- which is the same
	interruption arriving from the other direction.

	BAYS ARE FOUND BY TAG, not by name and not by a workspace scan. BayBuilder
	tags every bay it makes and the four already saved in the place carry the tag
	too, so this stays right for one built after this file has started, and it
	costs nothing on the islands that have not loaded yet -- they simply have no
	tagged bay to test against.

	THE PAD IS MEASURED OFF THE SHED, which is 15.5 x 16.6 studs with an open
	front. Eight studs carries the zone a little way onto the apron people queue
	on and still stops well short of the market stalls behind it; ten on the
	vertical covers both the deck and the roof.
]]
local BAY_PAD_XZ = 8
local BAY_PAD_Y = 10

local function inWashBay(pos: Vector3): boolean
	for _, bay in CollectionService:GetTagged("WashBay") do
		if bay:IsA("Model") and bay:IsDescendantOf(workspace) then
			-- Wrapped: GetBoundingBox throws on a model with no parts in it, which
			-- is what a bay looks like for the frame between being tagged and being
			-- filled in.
			local ok, cf, size = pcall(bay.GetBoundingBox, bay)
			if ok then
				local rel = cf:PointToObjectSpace(pos)
				if math.abs(rel.X) <= size.X * 0.5 + BAY_PAD_XZ
					and math.abs(rel.Z) <= size.Z * 0.5 + BAY_PAD_XZ
					and math.abs(rel.Y) <= size.Y * 0.5 + BAY_PAD_Y then
					return true
				end
			end
		end
	end
	return false
end

local function tryChallenge()
	-- Not while you are already in one, and not while an invite is up.
	if state or (inviteCard and inviteCard.Visible) then return end
	if DuelConfig.arenaOf(player) then return end

	local other = playerUnderMouse()
	if not other or other == player then return end

	local a = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local b = other.Character and other.Character:FindFirstChild("HumanoidRootPart")
	local hum = other.Character and other.Character:FindFirstChildOfClass("Humanoid")
	if not a or not b or not hum or hum.Health <= 0 then return end
	-- Neither end of it may be in a wash bay -- see the note above.
	if inWashBay(a.Position) or inWashBay(b.Position) then return end
	if (a.Position - b.Position).Magnitude > DuelConfig.ChallengeRange then return end

	challengeTarget = other.UserId
	challengeName.Text = other.DisplayName
	challengeCard.Visible = true
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

function DuelClient.start()
	if started then return end
	started = true

	gui = Instance.new("ScreenGui")
	gui.Name = "DuelHud"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 9
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	buildChallenge()
	buildInvite()
	buildHud()
	buildBig()
	UiFit.fit(gui)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			tryChallenge()
		end
	end)

	Net.get("DuelInvite").OnClientEvent:Connect(function(inv)
		if not inv then
			inviteCard.Visible = false
			return
		end
		inviteName.Text = inv.fromName or "?"
		inviteCard.Visible = true
		challengeCard.Visible = false
		-- The bar runs the invite down. If the server's timeout beats it the
		-- card is cleared by the nil push above, so the two cannot disagree.
		local total = inv.seconds or DuelConfig.InviteSeconds
		local t0 = os.clock()
		task.spawn(function()
			while inviteCard.Visible do
				local left = math.max(0, 1 - (os.clock() - t0) / total)
				inviteBar.Size = UDim2.fromScale(left, 1)
				if left <= 0 then break end
				RunService.Heartbeat:Wait()
			end
		end)
	end)

	Net.get("DuelState").OnClientEvent:Connect(function(snap)
		state = snap
		if snap then
			challengeCard.Visible = false
			inviteCard.Visible = false
		end
		paint()
	end)
end

return DuelClient