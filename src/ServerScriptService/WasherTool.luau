--[[
	WasherTool  --  ServerScriptService.WasherTool

	The power washer itself: the tool model, the pressure tier a player owns,
	and the upgrade that sells them the next one.

	WHERE PRESSURE LIVES
	--------------------
	On a player attribute, `WasherLevel`, mirroring how Clean the Beach already
	stores RollerLevel. WashServer reads pressureFor(player) on every aim packet
	rather than caching it in the session, so an upgrade bought mid-wash takes
	effect on the very next chunk instead of next time you mount something.

	Attributes are server-written and client-readable, which is the correct
	shape here: the client needs the number to size its jet, and knowing it buys
	an exploiter nothing -- the server multiplies by its own clock regardless.

	THE UPGRADE
	-----------
	A second ProximityPrompt on Clean the Beach's existing UpgradeKiosk board,
	beside the roller upgrade its HUD already drives. Same kiosk, same coins,
	same cost-ladder shape -- and CTB_HUD needs no changes at all, because a
	prompt lives in the world rather than in their UI.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local Net = require(Modules:WaitForChild("Net"))

local SellServer = require(script.Parent.SellServer)

local CFG = GameConfig.Washer

local WasherTool = {}

local tools = {} -- [Player] = Tool

--------------------------------------------------------------------------
-- TIERS
--------------------------------------------------------------------------

function WasherTool.levelOf(player: Player): number
	local lvl = player:GetAttribute("WasherLevel")
	if type(lvl) ~= "number" then
		return CFG.DefaultLevel
	end
	return math.clamp(math.floor(lvl), 1, #CFG.Levels)
end

function WasherTool.pressureFor(player: Player): number
	-- ProgressionServer owns the Pressure track now and writes WasherPressure on
	-- every purchase and spawn. Trusting the attribute rather than re-deriving
	-- from CFG.Levels means one ladder, not two that can drift.
	local psi = player:GetAttribute("WasherPressure")
	if type(psi) == "number" and psi > 0 then
		return psi
	end
	return CFG.Levels[WasherTool.levelOf(player)].pressure
end

local function applyTier(player: Player, level: number)
	local tier = CFG.Levels[level]
	player:SetAttribute("WasherLevel", level)
	player:SetAttribute("WasherPressure", tier.pressure)
	player:SetAttribute("WasherSpread", tier.spread)
	player:SetAttribute("WasherLabel", tier.label)
	Net.get("WasherChanged"):FireClient(player, {
		level = level,
		pressure = tier.pressure,
		spread = tier.spread,
		label = tier.label,
	})
end

--------------------------------------------------------------------------
-- THE TOOL
--------------------------------------------------------------------------

local function weldTo(part: BasePart, host: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = host
	w.Part1 = part
	w.Parent = host
end

local function buildWasher(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Power Washer"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.ToolTip = "Hold to blast crust off a mounted find"
	--[[
		POINTS THE LANCE FORWARD -- WHICH THE ROTATION THAT USED TO BE HERE DID NOT.

		This line has always carried the comment "rather than up like a torch", and
		up like a torch is exactly what it did. Measured on the live tool, barrel
		position relative to the handle:

		  Angles(-90, 0, 0)   +2.10 UP,      +0.65 forward   <- was here
		  no rotation         -0.65 down,    +2.10 FORWARD   <- is here now

		Worth fixing even though the player holding it never sees it. The wash
		camera veils the tool with LocalTransparencyModifier, which is a
		client-only override -- so the local player saw nothing and everyone ELSE
		in the server watched them hold a pressure washer straight up in the air.
	]]
	tool.Grip = CFrame.new(0, 0, 0.4)

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.4, 0.4, 2.2)
	handle.Color = Color3.fromRGB(226, 178, 52)
	handle.Material = Enum.Material.SmoothPlastic
	handle.CanCollide = false
	handle.CanQuery = false
	handle.TopSurface = Enum.SurfaceType.Smooth
	handle.BottomSurface = Enum.SurfaceType.Smooth
	handle.Parent = tool

	local base = handle.CFrame

	local function add(name, size, offset, color, material, shape)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.Color = color
		p.Material = material
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		if shape then
			p.Shape = shape
		end
		-- Positioned relative to the handle BEFORE welding: a WeldConstraint
		-- bakes the offset at creation time.
		p.CFrame = base * offset
		p.Parent = tool
		weldTo(p, handle)
		return p
	end

	-- Lance barrel
	add("Barrel", Vector3.new(0.28, 0.28, 2.6),
		CFrame.new(0, 0.05, -2.2), Color3.fromRGB(58, 62, 70), Enum.Material.Metal)

	-- Nozzle tip. The jet is emitted from here and the aim ray starts here.
	local nozzle = add("Nozzle", Vector3.new(0.34, 0.34, 0.5),
		CFrame.new(0, 0.05, -3.6) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(214, 220, 228), Enum.Material.Metal, Enum.PartType.Cylinder)
	nozzle.Reflectance = 0.25

	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	-- Down the barrel, which is the nozzle's own -Z. The rotation applied above
	-- is about Z, and a rotation about Z leaves Z where it was -- so despite the
	-- part being a cylinder laid on its side, forward is still -Z. Checked
	-- against the built CFrame rather than reasoned about: -Z comes out 0.0
	-- degrees off the barrel, +Y is 90 off. This offset used to be on Y, which
	-- put the muzzle out the SIDE of the nozzle and took the jet with it.
	muzzle.Position = Vector3.new(0, 0, -0.3)
	muzzle.Parent = nozzle

	-- Trigger grip
	add("Trigger", Vector3.new(0.32, 0.9, 0.4),
		CFrame.new(0, -0.5, 0.3), Color3.fromRGB(38, 40, 46), Enum.Material.SmoothPlastic)

	-- Hose stub
	add("Hose", Vector3.new(0.26, 0.26, 0.9),
		CFrame.new(0, -0.1, 1.4), Color3.fromRGB(30, 32, 36), Enum.Material.Fabric)

	return tool
end

--------------------------------------------------------------------------
-- HANDING IT OVER
--------------------------------------------------------------------------
--[[
	The washer used to be handed out on spawn and live in the backpack for the
	whole session. Two things wrong with that: the player carried a pressure
	washer while rolling the beach, and its hotbar slot sat permanently at the
	bottom of the screen, on top of CTB_HUD's hint line.

	It is now lent out by the bay, for exactly as long as a wash session is
	open -- WashServer.mount hands it over, WashServer.endSession takes it back.

	`wanted` is what makes that hold up with the backpack UI switched off (see
	ClientMain). With no hotbar there is no way for a player to put the tool
	back if anything unequips it mid-wash, so anything that does is undone.
]]
local wanted = {}   -- [Player] = true while a bay wants them holding it

local function humanoidOf(player: Player): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

function WasherTool.equip(player: Player)
	wanted[player] = true

	local tool = tools[player]
	if not (tool and tool.Parent) then
		if tool then
			tool:Destroy()
		end
		tool = buildWasher()
		tools[player] = tool

		tool.Unequipped:Connect(function()
			-- Deferred: Unequipped fires while the tool is mid-move between the
			-- character and the backpack, and re-equipping from inside the
			-- handler fights that move rather than following it.
			task.defer(function()
				if not (wanted[player] and tools[player] == tool and tool.Parent) then
					return
				end
				local char = player.Character
				-- Already back in hand. EquipTool on an equipped tool cycles
				-- Unequipped/Equipped, and without this the handler feeds itself
				-- until the engine cuts it off with a re-entrancy error.
				if not char or tool.Parent == char then
					return
				end
				local humanoid = char:FindFirstChildOfClass("Humanoid")
				if humanoid then
					humanoid:EquipTool(tool)
				end
			end)
		end)
	end

	-- Already in hand -- which is the COMMON case, because mounting the next
	-- lump without leaving the bay calls this again. Re-equipping an equipped
	-- tool cycles Unequipped/Equipped and sets the handler above off against
	-- itself; this early-out is what stops that.
	local char = player.Character
	if tool.Parent == char then
		return
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return
	end
	if tool.Parent ~= backpack then
		tool.Parent = backpack
	end

	local humanoid = humanoidOf(player)
	if humanoid then
		humanoid:EquipTool(tool)
	end
end

function WasherTool.stow(player: Player)
	wanted[player] = nil
	local tool = tools[player]
	tools[player] = nil
	if tool then
		-- wanted was cleared first, so the Unequipped handler above sees this as
		-- intentional and does not put it straight back.
		tool:Destroy()
	end
end

--------------------------------------------------------------------------
-- UPGRADE  (prompt on Clean the Beach's existing kiosk)
--------------------------------------------------------------------------

function WasherTool.tryUpgrade(player: Player)
	local level = WasherTool.levelOf(player)
	local nxt = CFG.Levels[level + 1]
	if not nxt then
		Net.get("Notify"):FireClient(player, {
			text = "Washer is already maxed out!",
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
	SellServer.addCoins(player, -nxt.cost, "washer")
	applyTier(player, level + 1)

	Net.get("Notify"):FireClient(player, {
		text = string.format("Upgraded to %s -- %.1f pressure!", nxt.label, nxt.pressure),
		kind = "pickup",
	})
	Net.get("Fx"):FireAllClients({ kind = "Upgrade", part = WasherTool.kioskAnchor })
end

WasherTool.kioskAnchor = nil

--[[
	THE ANCHOR, AND NO PROMPT ON IT.

	There was a ProximityPrompt built here and then disabled on the very next
	line, because the Beach Shop's Pressure track supersedes this ladder -- one
	ladder climbed from two places at two prices was the thing being avoided,
	and that reasoning still stands.

	What did not stand was building the object anyway. It sat on the kiosk board
	wearing the label "Upgrade Washer -- Pressure Washer (0)", because every tier
	in GameConfig.Washer.Levels carries cost = 0 -- so the one fact the control
	advertised was a price that does not exist. A disabled control that lies is
	worse than no control at all.

	The anchor stays. tryUpgrade still plays its Fx off it, and it is the hook if
	the washer ladder is ever sold from the world again.
]]
local function attachKioskAnchor()
	local beach = workspace:FindFirstChild("Beach")
	local kiosk = beach and beach:FindFirstChild("UpgradeKiosk")
	if not kiosk then
		warn("[WasherTool] no Beach.UpgradeKiosk -- washer Fx has no anchor")
		return
	end
	WasherTool.kioskAnchor = kiosk:FindFirstChild("Board")
		or kiosk:FindFirstChildWhichIsA("BasePart", true)
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

local started = false
function WasherTool.start()
	assert(RunService:IsServer(), "[WasherTool] server-only")
	if started then
		return
	end
	started = true

	local function hook(player: Player)
		--[[
			SEED ONLY, and only when nothing has written these yet.

			This used to call applyTier unconditionally, which was harmless while
			the Pressure track and GameConfig.Washer.Levels were both six long and
			is actively destructive now that the track runs to 60. levelOf() clamps
			to #CFG.Levels, and applyTier WRITES THE CLAMPED NUMBER BACK to
			WasherLevel -- so a player at Pressure level 40 who was hooked here
			would have their level silently rewritten to 12 and their pressure
			dropped to the top label's, undoing twenty-eight purchases.

			It is not reachable today only because ServerMain starts this module
			before ProgressionServer, so applyAll always lands second. That is a
			line ordering in another file holding a data invariant together, which
			is not something to leave standing.

			ProgressionServer.applyAll is the one writer of all four Washer
			attributes. This is just the fallback for a place where it is not
			running at all.
		]]
		if player:GetAttribute("WasherPressure") == nil then
			applyTier(player, WasherTool.levelOf(player))
		end
		-- No washer on spawn any more. The bay lends one out; see equip above.
		player.CharacterAdded:Connect(function()
			-- The tool dies with the character. If a bay is still mid-session and
			-- wants this player holding one, hand over a fresh one -- otherwise
			-- make sure nothing is left over from the previous life.
			if wanted[player] then
				task.defer(function()
					WasherTool.equip(player)
				end)
			else
				WasherTool.stow(player)
			end
		end)
	end
	Players.PlayerAdded:Connect(hook)
	for _, player in Players:GetPlayers() do
		hook(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		wanted[player] = nil
		tools[player] = nil
	end)

	attachKioskAnchor()
end

return WasherTool
