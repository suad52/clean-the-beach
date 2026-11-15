--[[
	BoostHud  --  StarterPlayerScripts.BoostHud  (ModuleScript)


	ONE READOUT: "a golden hour you paid for is running, and this much is left".
	It is on screen only while one is, which is a quarter of an hour at a time and
	never otherwise.


	IT READS ATTRIBUTES AND OWNS NOTHING. BoostService writes the two CTB_Boost
	attributes and BoostConfig knows how to read them; there is no remote, no
	payload and nothing to re-sync after a respawn, and a player who joins with a
	boost already running gets a correct pill the first time it draws.

	THE CLOCK IS DERIVED, NOT COUNTED DOWN. Every tick asks BoostConfig.
	remainingFor rather than subtracting from a number it is holding, so the
	readout cannot drift away from the deadline the till is actually using -- and
	a tab that was throttled in the background comes back showing the truth rather
	than however far its own subtraction got.


	WHERE IT STANDS, AND THIS WAS MEASURED RATHER THAN CHOSEN.

	The left column is the money column -- coins, bag load, raked -- and a sell
	multiplier is a money readout, so it belongs at the bottom of that stack
	rather than in the top-centre chain. It is also the only free space: at 1190 x
	751 the top centre already runs EventPill (y 2-34), the Ashen Stair's progress
	(31-55) and the tip card (52-156), three things that already abut each other,
	where the left column is empty from the keys ending at 242 all the way down to
	the pet luck chip at 633.

	SO IT CONTINUES THE COLUMN'S OWN RHYTHM rather than inventing a position:
	x 16 like every pill above it, and y 254 -- the same twelve-ish stud gap under
	the keys (184 + 58) that those pills keep between each other.

	UNTINTED, WHICH IS A RULE RATHER THAN A PREFERENCE. HudKit's note over `key`
	says it plainly: the readouts in this column are chrome and the one tinted
	thing on it is the one you can press. A gold pill here would read as a button.
	The colour goes on the NUMBERS instead, which is where the event pill puts it
	too.

	IgnoreGuiInset = false TO MATCH CleanTheBeachHUD, whose column this joins.
	Two ScreenGuis sharing a column must agree about the inset or they are laid
	out in different coordinate spaces and drift apart by the topbar's height.

	UiFit needs no call from here: its start() watches PlayerGui.ChildAdded, so a
	ScreenGui parented below is picked up and given the same FitRoot and the same
	scale as the pills it is lining up with.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local BoostConfig = require(Modules:WaitForChild("BoostConfig"))
local HudKit = require(Modules:WaitForChild("HudKit"))
-- For `clock` alone. A second mm:ss formatter is a second thing to get wrong,
-- and the pill beside this one is already using that one.
local EventConfig = require(Modules:WaitForChild("EventConfig"))

local player = Players.LocalPlayer

local BoostHud = {}

-- The column, matching CleanTheBeachHUD's pills exactly -- see the header.
local X, Y = 16, 254
local W, H = 256, 34
local RADIUS = 12

-- The money gold this game already uses for the MOST MONEY board and the Dunes
-- ferry. On the numbers only.
local GOLD = Color3.fromRGB(255, 200, 62)

local gui, pill, multLabel, nameLabel, clockLabel
local started = false

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "BoostHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	-- Below EventHud (11) and MenuHud (12), and deterministic against the column
	-- it joins, which sits at 0.
	gui.DisplayOrder = 1
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local root = Instance.new("Frame")
	root.Name = "BoostPill"
	root.Position = UDim2.fromOffset(X, Y)
	root.Size = UDim2.fromOffset(W, H)
	root.BackgroundTransparency = 1
	root.Parent = gui

	-- Untinted: the same three-layer readout as LoadPill and RakedPill above it.
	local holder = HudKit.surface(root, W, H, RADIUS)
	holder.Position = UDim2.fromOffset(0, 0)
	pill = holder

	multLabel = HudKit.text(holder, "", 20, GOLD)
	multLabel.Name = "Mult"
	multLabel.Position = UDim2.fromOffset(12, 0)
	multLabel.Size = UDim2.fromOffset(46, H)
	multLabel.TextXAlignment = Enum.TextXAlignment.Left
	HudKit.punch(multLabel)

	nameLabel = HudKit.text(holder, "GOLDEN HOUR", 13, HudKit.C.textDim, Enum.Font.GothamBold)
	nameLabel.Name = "Title"
	nameLabel.Position = UDim2.fromOffset(58, 0)
	nameLabel.Size = UDim2.fromOffset(120, H)
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left

	clockLabel = HudKit.text(holder, "", 17, GOLD)
	clockLabel.Name = "Clock"
	clockLabel.AnchorPoint = Vector2.new(1, 0)
	clockLabel.Position = UDim2.new(1, -12, 0, 0)
	clockLabel.Size = UDim2.fromOffset(64, H)
	clockLabel.TextXAlignment = Enum.TextXAlignment.Right
	HudKit.punch(clockLabel)
end

local function refresh()
	if not gui then
		return
	end
	local left = BoostConfig.remainingFor(player)
	local mult = BoostConfig.multiplierFor(player)
	if left <= 0 or mult <= 1 then
		gui.Enabled = false
		return
	end
	-- "2x" rather than "x2": it is the way every multiplier in this game is
	-- written, from the 2x Cash pass to the receipt.
	multLabel.Text = string.format("%gx", mult)
	clockLabel.Text = EventConfig.clock(left)
	gui.Enabled = true
end

function BoostHud.start()
	if started or not RunService:IsClient() then
		return
	end
	started = true

	build()
	refresh()

	-- The attributes move twice a purchase and once at expiry; the clock moves
	-- every second. Both routes call the same refresh, which reads the deadline
	-- rather than trusting either of them to be timely.
	player.AttributeChanged:Connect(function(name)
		if name == BoostConfig.MultAttr or name == BoostConfig.UntilAttr then
			refresh()
		end
	end)

	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(refresh)
			if not ok then
				warn("[BoostHud] refresh failed: " .. tostring(err))
			end
		end
	end)
end

return BoostHud
