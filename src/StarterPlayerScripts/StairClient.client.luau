--[[
	THE ASH ON THE ASHEN STAIR -- the half you can see.

	CTB_Server owns whether a cell is swept; ReplicatedStorage.CTB.Stair owns where
	it is; this draws it and cuts it, and it is drawn ENTIRELY LOCALLY for exactly
	the reason CTB_Client's crust is: swept progress is private, so two people on
	the same stair each need to see their own path up it and nobody else's.

	========================================================================
	WHY IT IS A SEPARATE SCRIPT AND NOT PART OF CTB_Client
	========================================================================

	CTB_Client's crust is a run-length encoding along WORLD X of a flat grid at a
	single height -- "sizes may differ freely because nothing here is ever
	ROTATED", as its own comment puts it. Every one of those assumptions is false
	on a staircase: 34 slabs, each yawed to face along the road, pitched to lie on
	a 34-degree cone, at 34 different heights. Bending that builder into a shape
	it was explicitly written not to take would have cost the sand the very thing
	that makes it cheap.

	So this is its own small builder with the same IDEA -- one part per unbroken
	run of uncut cells -- turned ninety degrees: the runs go ALONG the road rather
	than across it, because the road is only three cells wide and hundreds long.
	An untouched stair is about a hundred parts, not five hundred and sixty.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local CTB = ReplicatedStorage:WaitForChild("CTB")
local Config = require(CTB:WaitForChild("Config"))
local Stair = require(CTB:WaitForChild("Stair"))
local Net = CTB:WaitForChild("Net")

local folder = Instance.new("Folder")
folder.Name = "CTB_StairAsh"
folder.Parent = workspace

-- swept[i] = true, with its own running count. The count is kept rather than
-- derived: the readout below runs on Heartbeat, and counting five hundred keys
-- every frame to draw one percentage is the kind of thing that does not show up
-- until somebody is standing still on a phone.
local swept = {}
local sweptCount = 0
local cells = 0
-- One part per (tread, column) run, keyed "t:ix:runStart" -- rebuilt a column at
-- a time, which is the whole reason the runs go along the road.
local slabs = {}
local dirtyCols = {}
local ready = false

--[[
	THE TONE. Ashfall's messy terrain is Mud, tinted near-black by CTB_Server's
	applyLook, and Config.CRUST.lighten is what lifts the loose top layer off the
	packed stuff underneath. The same trick here, off the tread's OWN colour
	rather than off a terrain tint -- these are parts, so what the player is
	comparing the ash against is the Slate under it, not the sand two hundred
	studs below.
]]
local function ashColour(tread: BasePart): Color3
	local c = tread.Color
	local k = Stair.LIGHTEN
	return Color3.new(
		c.R + (1 - c.R) * k,
		c.G + (1 - c.G) * k,
		c.B + (1 - c.B) * k)
end

local function colKey(ti: number, ix: number): string
	return ti .. ":" .. ix
end

-- Tear down every slab of one column of one tread.
local function clearCol(key: string)
	local held = slabs[key]
	if not held then
		return
	end
	for _, p in ipairs(held) do
		p:Destroy()
	end
	slabs[key] = nil
end

--[[
	REBUILD ONE COLUMN: walk it from the foot of the tread to its head and make
	one part per unbroken run of cells that are still buried.

	The slab is built in the TREAD'S frame, so it inherits the yaw and the pitch
	of the road for free and never has to be told about either.
]]
local function buildCol(treads, ti: number, ix: number)
	local t = treads[ti]
	-- STREAMED OUT: leave the ash exactly as it is. This place runs with
	-- StreamingEnabled, so walking back down to the beach takes the tread parts
	-- away -- and clearing the column here would delete the player's own drawn
	-- ash the moment they stopped looking at it, then have nothing to redraw it
	-- from. The guard is BEFORE clearCol for that reason.
	if not t or not t.part.Parent then
		return
	end
	local key = colKey(ti, ix)
	clearCol(key)
	local made = nil
	local run0 = nil
	local colour = ashColour(t.part)

	local function flush(run1: number)
		if not run0 then
			return
		end
		local n = run1 - run0 + 1
		local p = Instance.new("Part")
		p.Name = "Ash"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Material = Enum.Material.Sand
		p.Color = colour
		p.Size = Vector3.new(Stair.CELL, Stair.RISE + Stair.BURY, n * t.step)
		-- Centred on the run, and lifted so RISE stands proud of the tread and
		-- BURY sinks into it -- the same straddle Config.CRUST uses, and for the
		-- same reason: an underside flush with the stone z-fights it.
		local midz = (run0 + (n - 1) * 0.5)
		p.CFrame = t.seat * Stair.localCF(t, ix, midz)
			* CFrame.new(0, (Stair.RISE - Stair.BURY) * 0.5, 0)
		p.Parent = folder
		made = made or {}
		made[#made + 1] = p
		run0 = nil
	end

	for iz = 0, t.nz - 1 do
		if swept[Stair.index(t, ix, iz)] then
			flush(iz - 1)
		else
			run0 = run0 or iz
		end
	end
	flush(t.nz - 1)
	slabs[key] = made
end

-- A cell changed: the column it belongs to has to be redrawn. Batched onto
-- Heartbeat so a sweep that clears twenty cells across three columns costs three
-- rebuilds and not twenty.
local function touch(treads, idx: number)
	for ti, t in ipairs(treads) do
		local span = Stair.ACROSS * t.nz
		if idx > t.base and idx <= t.base + span then
			local off = idx - t.base - 1
			dirtyCols[colKey(ti, off % Stair.ACROSS)] = { ti, off % Stair.ACROSS }
			return
		end
	end
end

local function rebuildAll()
	local treads, n = Stair.treads()
	if not treads then
		return false
	end
	if n ~= cells then
		cells = n
		swept = {}
	end
	for _, held in pairs(slabs) do
		for _, p in ipairs(held) do
			p:Destroy()
		end
	end
	slabs = {}
	table.clear(dirtyCols)
	for ti = 1, #treads do
		for ix = 0, Stair.ACROSS - 1 do
			buildCol(treads, ti, ix)
		end
		-- Cheap, but it is still 34 treads of part creation on one frame the
		-- first time somebody walks up here.
		if ti % 8 == 0 then
			task.wait()
		end
	end
	return true
end

--[[
	THE PUFF. One short-lived slab dropped where the ash just was, so a swept
	cell crumbles instead of blinking out -- Config.CRUST's `crumb`, in the
	tread's frame.
]]
-- The falling puff. Skipped for a tread that has streamed out -- there is
-- nothing to see over there anyway.
local function crumb(t, ix: number, iz: number, colour: Color3)
	local p = Instance.new("Part")
	p.Name = "AshCrumb"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Sand
	p.Color = colour
	local inset = Config.CRUST.crumb_inset or 0.25
	p.Size = Vector3.new(Stair.CELL - inset * 2, Stair.RISE, t.step - inset * 2)
	p.CFrame = t.seat * Stair.localCF(t, ix, iz) * CFrame.new(0, Stair.RISE * 0.5, 0)
	p.Parent = folder
	local life = Config.CRUST.crumb_life or 0.24
	TweenService:Create(p, TweenInfo.new(life), {
		Transparency = 1,
		CFrame = p.CFrame * CFrame.new(0, -Stair.RISE * 1.6, 0),
	}):Play()
	task.delay(life + 0.05, function()
		p:Destroy()
	end)
end

local function markClean(list)
	local treads = Stair.treads()
	if not treads then
		return
	end
	for _, idx in ipairs(list) do
		if not swept[idx] then
			swept[idx] = true
			sweptCount += 1
			touch(treads, idx)
			-- and the puff, for the cells near enough to be worth one
			for ti, t in ipairs(treads) do
				local span = Stair.ACROSS * t.nz
				if idx > t.base and idx <= t.base + span then
					local off = idx - t.base - 1
					if Config.CRUST.crumb and t.part.Parent then
						crumb(t, off % Stair.ACROSS, math.floor(off / Stair.ACROSS), ashColour(t.part))
					end
					break
				end
			end
		end
	end
end

----------------------------------------------------------------
-- The readout
--
-- Its own label rather than a line in CTB_HUD, because it is only true while
-- the player is actually on the mountain and the HUD's progress bar belongs to
-- whichever FIELD they are standing on. It fades in when they reach the
-- trailhead and out when they leave.
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "StairHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 6
gui.Parent = player:WaitForChild("PlayerGui")

local label = Instance.new("TextLabel")
label.Name = "Progress"
label.AnchorPoint = Vector2.new(0.5, 0)
label.Position = UDim2.new(0.5, 0, 0, 96)
label.Size = UDim2.new(0, 300, 0, 26)
label.BackgroundTransparency = 1
label.Font = Enum.Font.GothamBold
label.TextSize = 18
label.TextColor3 = Color3.fromRGB(255, 214, 176)
label.TextStrokeTransparency = 0.4
label.TextStrokeColor3 = Color3.fromRGB(28, 18, 14)
label.TextTransparency = 1
label.Text = ""
label.Parent = gui

local function setLabel(text: string, show: boolean)
	label.Text = text
	TweenService:Create(label, TweenInfo.new(0.25), {
		TextTransparency = show and 0 or 1,
		TextStrokeTransparency = show and 0.4 or 1,
	}):Play()
end

local banner = 0
local nextPoll = 0
local shown = nil

----------------------------------------------------------------
-- Wire
----------------------------------------------------------------
Net.OnClientEvent:Connect(function(kind, a, b)
	if kind == "StairSync" then
		cells = tonumber(a) or 0
		swept = {}
		sweptCount = 0
		if type(b) == "table" then
			for _, idx in ipairs(b) do
				if not swept[idx] then
					swept[idx] = true
					sweptCount += 1
				end
			end
		end
		if ready then
			task.spawn(rebuildAll)
		end
	elseif kind == "StairClean" then
		if type(a) == "table" then
			markClean(a)
		end
	elseif kind == "StairReset" then
		swept = {}
		sweptCount = 0
		if ready then
			task.spawn(rebuildAll)
		end
	elseif kind == "StairDone" then
		banner = os.clock() + 4
		setLabel(string.format("%s %s   +%d", Stair.NAME, Stair.BANNER, tonumber(a) or 0), true)
	end
end)

----------------------------------------------------------------
-- Build it the first time the player is anywhere near, and never before: the
-- stair is 2,200 studs from spawn and a player who never sails to Ashfall must
-- not pay a part of it. Exactly the contract CTB_Client's ensureIslandBuilt
-- keeps for the islands' litter.
----------------------------------------------------------------
task.spawn(function()
	while true do
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and not ready and Stair.near(hrp.Position, 160) then
			if rebuildAll() then
				ready = true
				print(string.format("[Stair] ash drawn over %d cells", cells))
			end
		end
		task.wait(1)
	end
end)

RunService.Heartbeat:Connect(function()
	if next(dirtyCols) then
		local treads = Stair.treads()
		if treads then
			for _, col in pairs(dirtyCols) do
				buildCol(treads, col[1], col[2])
			end
		end
		table.clear(dirtyCols)
	end

	if os.clock() < banner then
		return
	end
	-- Four times a second is plenty for a percentage, and Stair.near walks all
	-- 34 treads.
	local now = os.clock()
	if now < nextPoll then
		return
	end
	nextPoll = now + 0.25

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and cells > 0 and Stair.near(hrp.Position, 60) then
		local text = string.format("%s   %d%%", Stair.NAME, math.floor(sweptCount / cells * 100))
		if text ~= shown then
			shown = text
			setLabel(text, true)
		end
	elseif shown ~= nil then
		shown = nil
		setLabel("", false)
	end
end)

print("[Stair] client ready -- the road up the mountain sweeps like the sand")
