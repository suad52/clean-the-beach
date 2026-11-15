--[[
	SiftScreen  --  ServerScriptService.SiftScreen

	The screen deck a player owns: which tier they are on, what that is worth in
	work-per-second, and the upgrade that sells them the next one. Replaces
	WasherTool.

	WHY THERE IS NO TOOL ANY MORE
	-----------------------------
	The washer was a Tool, lent out for the length of a session and taken back
	afterwards. That existed because a jet has to come from somewhere the player
	is holding. A shake does not: the player grips the deck that is already in
	front of them, so there is nothing to hand over.

	Dropping it takes a surprising amount of awkwardness with it. WasherTool had
	to fight the backpack UI (which ClientMain switches off, leaving no way for a
	player to re-equip anything that got knocked out of their hand), re-equip on
	respawn mid-session, and guard against Unequipped feeding itself into a
	re-entrancy error. None of that has a reason to exist now.

	The tier is still visible -- better than before, in fact. It renders on the
	deck the player is looking directly at while they sift, instead of on a lance
	pointed away from the camera.

	WHERE THE TIER LIVES
	--------------------
	The player attributes keep their `Washer*` names. They are not ours: the
	Progression panel's "Pressure" track writes WasherLevel and WasherPressure on
	every purchase and every spawn (see ProgressionServer.applyAll), and renaming
	them would mean editing that, the saved level keys, and anything that has
	already persisted them. Same call as CTB's RollerWidth -- the contract keeps
	its old name, the game stops using the old word.

	THE UPGRADE
	-----------
	A ProximityPrompt on Clean the Beach's existing UpgradeKiosk board. It is
	left disabled, exactly as the washer's was, because the Upgrades panel sells
	the same ladder through the same grant path -- two live ladders would let a
	player climb one from two places at two different prices.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local Net = require(Modules:WaitForChild("Net"))

local SellServer = require(script.Parent.SellServer)

local CFG = GameConfig.Screen

local SiftScreen = {}

--------------------------------------------------------------------------
-- TIERS
--------------------------------------------------------------------------

function SiftScreen.levelOf(player: Player): number
	local lvl = player:GetAttribute("WasherLevel")
	if type(lvl) ~= "number" then
		return CFG.DefaultLevel
	end
	return math.clamp(math.floor(lvl), 1, #CFG.Levels)
end

-- Work per second at FULL vigour. SiftServer reads this on every reversal
-- rather than caching it in the session, so an upgrade bought mid-sift takes
-- effect on the very next shake instead of on the next lump.
function SiftScreen.rateFor(player: Player): number
	-- ProgressionServer owns the track and writes the attribute on every
	-- purchase and spawn. Trusting it rather than re-deriving from CFG.Levels
	-- means one ladder, not two that can drift.
	local rate = player:GetAttribute("WasherPressure")
	if type(rate) == "number" and rate > 0 then
		return rate
	end
	return CFG.Levels[SiftScreen.levelOf(player)].rate
end

function SiftScreen.throwFor(player: Player): number
	local t = player:GetAttribute("WasherSpread")
	if type(t) == "number" and t > 0 then
		return t
	end
	return CFG.Levels[SiftScreen.levelOf(player)].throw
end

local function applyTier(player: Player, level: number)
	local tier = CFG.Levels[level]
	player:SetAttribute("WasherLevel", level)
	player:SetAttribute("WasherPressure", tier.rate)
	player:SetAttribute("WasherSpread", tier.throw)
	player:SetAttribute("WasherLabel", tier.label)
	Net.get("ScreenChanged"):FireClient(player, {
		level = level,
		rate = tier.rate,
		throw = tier.throw,
		label = tier.label,
	})
end

--------------------------------------------------------------------------
-- UPGRADE  (prompt on Clean the Beach's existing kiosk)
--------------------------------------------------------------------------

local function nextTier(player: Player)
	return CFG.Levels[SiftScreen.levelOf(player) + 1]
end

function SiftScreen.tryUpgrade(player: Player)
	local level = SiftScreen.levelOf(player)
	local nxt = CFG.Levels[level + 1]
	if not nxt then
		Net.get("Notify"):FireClient(player, {
			text = "Screen is already the best there is!",
			kind = "warn",
		})
		return
	end

	local coins = SellServer.getCoins(player)
	if coins < nxt.cost then
		Net.get("Notify"):FireClient(player, {
			text = string.format("Need %d more coins for the %s", nxt.cost - coins, nxt.label),
			kind = "warn",
			-- The shortfall, which is what sends MenuHud to the coin packs. Only an
			-- affordability refusal sets it; see the note over ProgressionServer's
			-- notify().
			needCoins = nxt.cost - coins,
		})
		return
	end

	-- Spend through the same single grant path everything else uses, so the
	-- currency adapter still decides where the balance actually lives.
	SellServer.addCoins(player, -nxt.cost)
	applyTier(player, level + 1)

	Net.get("Notify"):FireClient(player, {
		text = string.format("Upgraded to the %s -- shakes %.1f a second!", nxt.label, nxt.rate),
		kind = "pickup",
	})
	-- To the buyer only: personal progress, not a public announcement.
	Net.get("Fx"):FireClient(player, { kind = "Upgrade", part = SiftScreen.kioskAnchor })
end

SiftScreen.kioskAnchor = nil

local function attachKioskPrompt()
	local beach = workspace:FindFirstChild("Beach")
	local kiosk = beach and beach:FindFirstChild("UpgradeKiosk")
	if not kiosk then
		warn("[SiftScreen] no Beach.UpgradeKiosk -- screen upgrades unavailable")
		return
	end
	local board = kiosk:FindFirstChild("Board") or kiosk:FindFirstChildWhichIsA("BasePart", true)
	if not board then
		return
	end
	SiftScreen.kioskAnchor = board

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ScreenUpgradePrompt"
	prompt.ActionText = "Upgrade Screen"
	prompt.ObjectText = "Kiosk"
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = board

	-- Superseded by the Beach Shop's track, which spends the same coins
	-- through the same grant path. Leaving both wired would let a player climb
	-- one ladder from two places at two different prices.
	prompt.Enabled = false
	prompt.Triggered:Connect(SiftScreen.tryUpgrade)

	-- Deliberately generic. This used to read the FIRST player's tier off
	-- Players:GetPlayers()[1] and stamp it on a prompt everyone shares, which
	-- showed one player's next upgrade price to the whole server. The prompt is
	-- disabled anyway (see above), so rather than plumb a per-player label through
	-- a shared instance it just states what the prompt does. If it is ever
	-- re-enabled, the price belongs in the Upgrades panel, which is per-player.
	prompt.ActionText = "Upgrade Screen"
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

local started = false
function SiftScreen.start()
	assert(RunService:IsServer(), "[SiftScreen] server-only")
	if started then
		return
	end
	started = true

	local function hook(player: Player)
		applyTier(player, SiftScreen.levelOf(player))
	end
	Players.PlayerAdded:Connect(hook)
	for _, player in Players:GetPlayers() do
		hook(player)
	end

	-- Still called even though the prompt ships disabled: it is what sets
	-- kioskAnchor, which the upgrade Fx is fired at.
	attachKioskPrompt()
end

return SiftScreen
