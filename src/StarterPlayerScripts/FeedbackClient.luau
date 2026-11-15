--[[
	FeedbackClient  --  StarterPlayerScripts.FeedbackClient

	Everything the server broadcasts that is not the sifting minigame itself:
	world one-shot effects (Fx), soft messages (Notify), and the sell receipt
	(SellResult).

	WHY THE PARTICLES LIVE HERE AND NOT ON THE SERVER
	-------------------------------------------------
	ParticleEmitter:Emit() called on the server does NOT replicate -- it fires
	into the void and no client sees anything. Bursts must be triggered client
	side. So the server sends a tiny descriptor over the Fx remote and every
	client builds and emits its own copy, which also means the emitters cost the
	server nothing and are trivially skippable on low-end devices.
]]

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local ItemConfig = require(Modules:WaitForChild("ItemConfig"))
local ItemVisuals = require(Modules:WaitForChild("ItemVisuals"))
local Net = require(Modules:WaitForChild("Net"))
local ToastKit = require(Modules:WaitForChild("ToastKit"))
local AudioKit = require(Modules:WaitForChild("AudioKit"))
local PanelKit = require(Modules:WaitForChild("PanelKit"))

local C = PanelKit.C

local player = Players.LocalPlayer

local FeedbackClient = {}

local gui, receipt

--------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------

local function comma(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

-- The hand-rolled playAt that used to live here is gone. It built a bare Sound
-- off a raw SoundId, so it got no bus (and therefore ignored the Settings
-- panel's Sound Effects toggle outright), no pitch variation, and no attack
-- ramp -- which is what made a chunk popping twenty times in a row read as one
-- sample on repeat. AudioKit owns all of that now; the call sites below pass a
-- slot NAME and, where they want it, a relative nudge rather than an absolute
-- level the kit is trying to own.

--------------------------------------------------------------------------
-- GUI
--------------------------------------------------------------------------

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "FeedbackHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 14
	gui.Parent = player:WaitForChild("PlayerGui")

	-- The 420x200 "Toasts" holder that used to sit here is GONE. ToastKit took
	-- over the drawing, so nothing was ever parented into it again -- it was an
	-- invisible frame occupying y 150..350 in the middle of the screen, which is
	-- exactly the sort of ghost that makes the next person laying out this HUD
	-- think a slot is taken when it is not.

	-- SITS ON TOP OF ToastKit's COLUMN, not across the middle.
	--
	-- A sale fires this AND a "SOLD n ITEMS" banner, so the two have to stack
	-- rather than share a spot. ToastKit now owns a bottom-anchored column whose
	-- highest reach is 310px off the bottom edge (banner 88 + 64, a 22 gap that
	-- absorbs the banner's drift, then a three-toast stack 136 tall). 322 parks
	-- this card's bottom edge just above that, so a full stack and a receipt can
	-- both be up and neither is covered.
	--
	-- NOT sized against the wash-lifted column: that lift only happens while the
	-- wash minigame card is on screen, and a receipt cannot fire then -- it comes
	-- from SellResult, i.e. from standing on the sell pad, not at the wash bay.
	--
	-- Bottom-anchored for the same reason ToastKit is: an offset from the bottom
	-- holds its gap on a tall viewport where a 0.62 scale would drift down into
	-- the HUD.
	-- A PAPER SLIP, not a dark slab.
	--
	-- This was (18,24,20) at 10% alpha with a mint hairline -- the same flat
	-- near-black the CARRYING panel and the reveal card were drawn in, and the
	-- same one nothing else in the game uses any more. It is PanelKit's plate
	-- now: wood slab, white-to-sand face, 4px warm ink outline. A receipt IS a
	-- bit of paper, so of every surface in this HUD it is the one that most
	-- obviously wanted to be cream.
	--
	-- The labels stay children of `receipt` rather than of the paper, so
	-- showReceipt's receipt.Total / .Detail / .Best paths are untouched -- and
	-- under Sibling ZIndexBehavior they are added after the paper, so they draw
	-- on top of it without needing a ZIndex apiece.
	receipt = Instance.new("Frame")
	receipt.Name = "Receipt"
	receipt.AnchorPoint = Vector2.new(0.5, 1)
	receipt.Position = UDim2.new(0.5, 0, 1, -322)
	receipt.Size = UDim2.fromOffset(340, 120)
	receipt.BackgroundTransparency = 1
	receipt.BorderSizePixel = 0
	receipt.Visible = false
	receipt.Parent = gui

	local slab = Instance.new("Frame")
	slab.Name = "Slab"
	slab.Size = UDim2.fromScale(1, 1)
	slab.Position = UDim2.fromOffset(0, 7)
	slab.BackgroundColor3 = C.woodDark
	slab.BorderSizePixel = 0
	slab.Parent = receipt
	PanelKit.corner(slab, 18)
	PanelKit.outline(slab, 4)

	local paper = Instance.new("Frame")
	paper.Name = "Paper"
	paper.Size = UDim2.fromScale(1, 1)
	paper.BackgroundColor3 = C.white
	paper.BorderSizePixel = 0
	paper.Parent = receipt
	PanelKit.corner(paper, 18)
	PanelKit.outline(paper, 4)
	PanelKit.grad(paper, C.white, C.sand)

	local total = Instance.new("TextLabel")
	total.Name = "Total"
	total.BackgroundTransparency = 1
	total.Position = UDim2.fromOffset(0, 10)
	total.Size = UDim2.new(1, 0, 0, 52)
	total.Font = Enum.Font.LuckiestGuy
	total.TextScaled = true
	total.TextColor3 = Color3.fromRGB(62, 186, 104)
	total.Text = ""
	total.Parent = receipt
	-- Outlined glyphs, not a glow. On cream, green text needs the dark edge to
	-- stop it going pastel -- and an outlined number is what the load bar, the
	-- rail and every toast in the game already use.
	PanelKit.punch(total, 3.5)

	local detail = Instance.new("TextLabel")
	detail.Name = "Detail"
	detail.BackgroundTransparency = 1
	detail.Position = UDim2.fromOffset(14, 64)
	detail.Size = UDim2.new(1, -28, 0, 22)
	detail.Font = Enum.Font.GothamBold
	detail.TextSize = 14
	detail.TextTruncate = Enum.TextTruncate.AtEnd
	detail.TextColor3 = C.woodDark
	detail.Text = ""
	detail.Parent = receipt

	local best = Instance.new("TextLabel")
	best.Name = "Best"
	best.BackgroundTransparency = 1
	best.Position = UDim2.fromOffset(14, 86)
	best.Size = UDim2.new(1, -28, 0, 22)
	best.Font = Enum.Font.GothamBold
	best.TextSize = 13
	best.TextTruncate = Enum.TextTruncate.AtEnd
	best.TextColor3 = C.woodDark
	best.Text = ""
	best.Parent = receipt
end

--------------------------------------------------------------------------
-- TOASTS
--------------------------------------------------------------------------

-- Every Notify the server sends lands here. The flat dark rectangle this used to
-- draw is gone: ToastKit owns the look now, and CTB_HUD and WeightClient draw
-- through the same kit, so all three finally agree with each other and with the
-- rest of the game's cartoon UI.
local function toast(text: string, kind: string?, tint: Color3?)
	ToastKit.toast(text, kind, nil, tint)
end

--------------------------------------------------------------------------
-- RECEIPT
--------------------------------------------------------------------------

local receiptToken = 0

local function showReceipt(payload)
	receiptToken += 1
	local myToken = receiptToken

	receipt.Total.Text = "+ $" .. comma(payload.total or 0)
	--[[
		THE EVENT MULTIPLIER GETS NAMED ON THE LINE, not a row of its own.

		SellServer hands over three multipliers and never merges them -- rebirth,
		pass, event -- and this card has never drawn any of them: the rebirth panel
		and the shop each advertise their own. The event is the one with no screen
		of its own, and a till that pays double without saying why is the moment
		the player is most likely to think something is wrong.

		So it is appended exactly the way the batch bonus already is, rather than
		becoming a fourth row: the three rows below sit at fixed offsets ending at
		y = 108 in a 120-tall card, and there is no room for another.
	]]
	local eventMult = tonumber(payload.eventMultiplier) or 1
	receipt.Detail.Text = string.format(
		"%d item%s sold%s%s",
		payload.sold or 0,
		(payload.sold == 1) and "" or "s",
		(payload.bonus and payload.bonus > 0)
			and string.format("   (+$%s batch bonus)", comma(payload.bonus))
			or "",
		(eventMult > 1) and string.format("   GOLDEN HOUR x%g", eventMult) or ""
	)
	if payload.best then
		receipt.Best.Text = string.format(
			"Best find: %s -- $%s",
			payload.best.displayName,
			comma(payload.best.value)
		)
		-- Darkened toward black: the tier colours were mixed to glow on a
		-- near-black card, and Common's (196,204,212) is invisible on cream.
		receipt.Best.TextColor3 = PanelKit.darken(ItemConfig.rarityColor(payload.best.rarity), 0.45)
	else
		receipt.Best.Text = ""
	end

	-- Size left at 340x120. The three rows inside are laid out at fixed offsets
	-- ending at y = 108, so shrinking the card without moving them would crowd
	-- the best-find line against the bottom edge. This card was only ever moved,
	-- not resized.
	receipt.Visible = true
	receipt.Size = UDim2.fromOffset(300, 106)
	TweenService:Create(
		receipt,
		TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = UDim2.fromOffset(340, 120) }
	):Play()

	task.delay(2.8, function()
		-- A second sale during the hold must not hide the newer receipt.
		if receiptToken == myToken then
			receipt.Visible = false
		end
	end)
end

--------------------------------------------------------------------------
-- WORLD FX
--------------------------------------------------------------------------

local function coinShower(part: BasePart, intensity: number)
	local e = ItemVisuals.attachEmitter(part, {
		Name = "CoinShower",
		Texture = GameConfig.Textures.Sparkle,
		Color = ColorSequence.new(Color3.fromRGB(255, 236, 150), Color3.fromRGB(255, 176, 40)),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(0.3, 0.85),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.05),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Lifetime = NumberRange.new(0.8, 1.5),
		Speed = NumberRange.new(9, 18),
		SpreadAngle = Vector2.new(28, 28),
		EmissionDirection = Enum.NormalId.Top,
		Acceleration = Vector3.new(0, -34, 0),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-220, 220),
		LightEmission = 0.7,
		Rate = 0,
		Enabled = false,
		ZOffset = 0.4,
	})
	e:Emit(math.floor(30 + intensity * 90))
	Debris:AddItem(e, 3)

	-- Till bell first, coins a beat behind it. Two clips on one beat is how the
	-- sale gets weight without simply getting louder -- and the gap is what
	-- makes it read as a consequence (rang up, THEN paid) rather than a chord.
	AudioKit.stack("Register", "CoinShower", part, 0.12)
end

local function onFx(payload)
	if type(payload) ~= "table" then
		return
	end
	local part = payload.part
	if payload.kind ~= "Reject" and not (part and part:IsA("BasePart") and part.Parent) then
		return
	end

	if payload.kind == "Sparkle" then
		ItemVisuals.burstSparkle(part, payload.rarity or "Common")
	elseif payload.kind == "CoinShower" then
		coinShower(part, payload.intensity or 0.5)
	elseif payload.kind == "Pickup" then
		local rarity = payload.rarity or "Common"
		ItemVisuals.burstSparkle(part, rarity)
		-- A much gentler rarity ladder than the old 1.0/1.25/1.5. That spread was
		-- tuned for a synthetic blip, where a big jump just reads as "higher";
		-- on a real close-miked paper crinkle anything past about +20% stops
		-- sounding like paper and starts sounding like a cartoon mouse.
		local pitch = rarity == "Legendary" and 1.18 or (rarity == "Rare" and 1.08 or 1.0)
		AudioKit.play("Pickup", part, 1, pitch)
	elseif payload.kind == "Pet" then
		-- A penguin, petted: a few white sparkles and a honk. The coin itself
		-- arrives through the HUD the way every coin does.
		ItemVisuals.burstSparkle(part, "Common")
		AudioKit.play("PenguinHonk", part, 1, 1)
	elseif payload.kind == "Mount" then
		AudioKit.play("Mount", part, 1, 0.95)
	elseif payload.kind == "ChunkGone" then
		-- Bystander version of a chunk shaking loose. The sifter's own client
		-- does the flying flake; everyone else just gets the grit and the pop.
		local grit = ItemVisuals.makeGritEmitter(part)
		grit:Emit(10)
		Debris:AddItem(grit, 2)
		-- Quieter than the sifter's own pop, because this is somebody ELSE's
		-- lump coming apart across the bay. The explicit 0.9 + rand*0.5 pitch
		-- roll that used to be here is gone: AudioKit jitters this slot by 8%
		-- and rotates four different takes, so the variation is both smaller
		-- and far more convincing than one clip swinging over half an octave.
		AudioKit.play("ChunkPop", part, 0.7)
	elseif payload.kind == "Upgrade" then
		ItemVisuals.burstSparkle(part, "Rare")
		-- No longer pitched up. The old +15% was pushing a thin electronic ping
		-- into the bright range to make it feel like an achievement; the clip is
		-- a wood-mallet chime now and it is warmer left where it was recorded.
		AudioKit.play("Upgrade", part)
	elseif payload.kind == "Reject" then
		if part and part:IsA("BasePart") and part.Parent then
			-- The slot is already the Mount knock pitched down; no nudge needed.
			AudioKit.play("Reject", part)
		end
	end
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

local started = false
function FeedbackClient.start()
	if started then
		return
	end
	started = true

	build()

	Net.get("Notify").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or type(payload.text) ~= "string" then
			return
		end
		local tint = payload.rarity and ItemConfig.rarityColor(payload.rarity) or nil
		toast(payload.text, payload.kind, tint)
	end)

	Net.get("SellResult").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		showReceipt(payload)
	end)

	Net.get("Fx").OnClientEvent:Connect(onFx)
end

FeedbackClient.toast = function(text, kind)
	if gui then
		toast(text, kind)
	end
end

return FeedbackClient
