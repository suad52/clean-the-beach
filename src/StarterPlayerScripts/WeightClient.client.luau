--[[
	WeightClient  --  StarterPlayer.StarterPlayerScripts.WeightClient  (LocalScript)

	Prediction and feedback for the weight system. It owns exactly three jobs,
	and none of them is authority:

		1. work out what the player is standing over
		2. ASK the server for everything in reach that fits
		3. draw what the server said

	THERE IS NO PICKUP KEY AND NO PICKUP PROMPT
	-------------------------------------------
	Collecting is WALKING. There used to be an "[E] Plastic Bottle - 2 lb"
	billboard over the nearest item within ManualPickupRadius (14 studs) and an
	E binding that acted on it -- while auto-collect only reached
	AutoCollectRadius, which was 8. TrashSeeder lays 90 props over a 105 stud
	radius, roughly 20 studs apart, so most litter spent its whole life in the
	gap between those two numbers: it advertised itself as collectible, and then
	sat there as the player walked past, because nothing outside 8 studs was
	ever swept. That reads as litter that is simply broken.

	The fix is not a better prompt. The two radii are now the SAME number and
	the sweep takes everything it can reach, so what a player can see they can
	have -- no key to learn, and no state where the game is waiting on input.

	THE PREDICTION IS NOT A DECISION
	--------------------------------
	This script does compare an item's weight against the free space it can see
	-- but only to decide what to ASK for. That is what produces the required
	behaviour: walk through a pile with 3 lbs left and the cans keep flowing
	while the tyre is stepped over, with no rejected-request spam in between.
	The server re-runs the same check on every request and its answer is final;
	if the two ever disagree, the server wins and this script just redraws.

	Free space is read from the CurrentWeight / MaxWeight player attributes,
	which only the server writes -- the same pattern CTB_HUD already uses for
	Bag and Coins. Editing them locally changes nothing but this HUD.

	The HUD is positioned to sit UNDER the existing CTB_HUD panels (coins at
	y=18, beach progress at y=96) and its toast sits under the bag panel, so
	nothing overlaps and CTB_HUD is not touched.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local AudioKit = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("AudioKit"))

local WeightSystem = ReplicatedStorage:WaitForChild("WeightSystem", 30)
assert(WeightSystem, "[WeightClient] ReplicatedStorage.WeightSystem is missing")
local WeightConfig = require(WeightSystem:WaitForChild("WeightConfig"))
local WeightNet = require(WeightSystem:WaitForChild("WeightNet"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CollectRequest = WeightNet.get("CollectRequest")
local CollectResult = WeightNet.get("CollectResult")

local EPS = WeightConfig.EPSILON
local UNIT = WeightConfig.Unit

-- The warm ink PanelKit, SignKit and CTB_HUD all outline with. This file had
-- its own near-black (16,14,24), which is a different colour to every other
-- outline on the screen -- close enough to look like a mistake rather than a
-- choice, which is exactly what it was.
local OUTLINE = Color3.fromRGB(56, 36, 20)
local GOLD = Color3.fromRGB(255, 200, 62)
-- Wood, not slate, to agree with PanelKit and SignKit. CREAM, RED and GREEN
-- left with the pickup billboard that was the only thing using them.
local PANEL_BODY = Color3.fromRGB(118, 72, 36)
local BAR_LIGHT = Color3.fromRGB(140, 226, 255)
local BAR_FULL = Color3.fromRGB(255, 178, 44)

--[[
	THE PICKUP IS THE MOST-FIRED SOUND IN THE GAME.

	Auto-collect means walking through a pile can trigger it several times a
	second, for as long as the player keeps raking -- which makes it the one
	slot where the difference between a sample and a texture is worth the most.
	It used to be `rbxasset://sounds/clickfast.wav` at a fixed 1.15: the exact
	same 40ms blip, at the exact same pitch, hundreds of times a session.

	AudioKit's Pickup slot is two takes of close-miked paper crinkle rotated
	round-robin with 7% pitch jitter on each, so no two grabs in a row are the
	same sound. Both are played FLAT (nil parent, non-positional) on purpose:
	this is the player's own hand, and it belongs against the ear rather than
	somewhere out in the world with a rolloff on it.
]]

----------------------------------------------------------------
-- Small builders (deliberately local: CTB_HUD's own helpers are private to it
-- and this script must not reach into another script's UI)
----------------------------------------------------------------
local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

local function stroke(parent: Instance, thickness: number, colour: Color3, transparency: number?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = colour
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function textStroke(parent: Instance, thickness: number, colour: Color3, transparency: number?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = colour
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.Parent = parent
	return s
end

local function label(parent: Instance, text: string, size: number, colour: Color3, font: Enum.Font?)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Font = font or Enum.Font.GothamBold
	t.Text = text
	t.TextSize = size
	t.TextColor3 = colour
	t.Size = UDim2.fromScale(1, 1)
	t.Parent = parent
	return t
end

----------------------------------------------------------------
-- HUD
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "WeightHUD"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 3
gui.Parent = playerGui

-- Load pill, bottom-left. Every other corner is spoken for: CTB_HUD owns the
-- top-left column (coins, LOAD, beach progress) with InventoryHud's backpack
-- key under it and its drawer opening down the same edge, MenuHud's rail owns
-- the right, and the mobile touch button lands bottom-right. Bottom-left is the
-- one place this can sit without covering anything.
--
-- Still off by default, and now for a sharper reason than "two panels already
-- report this": the LOAD row in that column IS this pill -- same two
-- attributes, same arithmetic -- so switching this on puts the same number on
-- screen twice. The top-centre bar that used to be the second copy is gone.
local pill = Instance.new("Frame")
pill.Name = "LoadPill"
pill.Size = UDim2.fromOffset(250, 48)
pill.AnchorPoint = Vector2.new(0, 1)
pill.Position = UDim2.new(0, 18, 1, -18)
pill.BackgroundTransparency = 1
-- Off by default: the two existing panels already report this number. Kept
-- built rather than skipped so flipping the flag is the only change needed.
pill.Visible = WeightConfig.ShowLoadPill == true
pill.Parent = gui

local pillShade = Instance.new("Frame")
pillShade.Size = UDim2.fromScale(1, 1)
pillShade.Position = UDim2.fromOffset(0, 5)
pillShade.BackgroundColor3 = OUTLINE
pillShade.BackgroundTransparency = 0.45
pillShade.BorderSizePixel = 0
pillShade.ZIndex = 0
pillShade.Parent = pill
corner(pillShade, 15)

local pillBody = Instance.new("Frame")
pillBody.Size = UDim2.fromScale(1, 1)
pillBody.BackgroundColor3 = PANEL_BODY
pillBody.BorderSizePixel = 0
pillBody.ClipsDescendants = true
pillBody.ZIndex = 1
pillBody.Parent = pill
corner(pillBody, 15)
local pillStroke = stroke(pillBody, 2.5, OUTLINE)

local loadFill = Instance.new("Frame")
loadFill.Size = UDim2.new(0, 0, 1, 0)
loadFill.BackgroundColor3 = BAR_LIGHT
loadFill.BackgroundTransparency = 0.7
loadFill.BorderSizePixel = 0
loadFill.ZIndex = 2
loadFill.Parent = pillBody

-- Crate glyph, drawn from frames for the same reason CTB_HUD draws its own:
-- an emoji renders in whatever font the player's device happens to ship.
local crate = Instance.new("Frame")
crate.Size = UDim2.fromOffset(24, 20)
crate.Position = UDim2.fromOffset(14, 14)
crate.BackgroundColor3 = Color3.fromRGB(206, 142, 66)
crate.BorderSizePixel = 0
crate.ZIndex = 4
crate.Parent = pillBody
corner(crate, 4)
stroke(crate, 2, OUTLINE)

local crateBand = Instance.new("Frame")
crateBand.Size = UDim2.new(1, 0, 0, 5)
crateBand.Position = UDim2.fromScale(0, 0.4)
crateBand.BackgroundColor3 = Color3.fromRGB(150, 92, 36)
crateBand.BorderSizePixel = 0
crateBand.ZIndex = 5
crateBand.Parent = crate

local loadText = label(pillBody, "LOAD  0 / 20 " .. UNIT, 18, Color3.fromRGB(226, 236, 246))
loadText.ZIndex = 4
loadText.Size = UDim2.new(1, -54, 1, 0)
loadText.Position = UDim2.fromOffset(48, 0)
loadText.TextXAlignment = Enum.TextXAlignment.Left
textStroke(loadText, 2, OUTLINE, 0.3)

local ToastKit = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("ToastKit"))

-- Was a bare label at y=118, parked there specifically to dodge CTB_HUD's toast
-- at 0.34 height. Both go through ToastKit now, which owns one stack -- so they
-- cannot overlap by construction rather than by each side remembering to stay
-- out of the other's way. `kind` replaces the old Color3: the kit owns the
-- palette so every notification in the game agrees on what amber means.
local function showToast(text: string, kind: string, hold: number)
	ToastKit.toast(text, kind, hold)
end

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------
local candidates: { [Instance]: BasePart } = {}   -- item -> the part we measure from
local blockedUntil: { [Instance]: number } = {}   -- item -> os.clock() to retry at
-- The in-flight BATCH. One sweep asks for everything in reach that fits, not
-- just the nearest thing, so the lock is "is anything still unanswered" rather
-- than "which single item did we ask for".
local pendingItems: { [Instance]: true } = {}
local pendingCount = 0
local pendingUntil = 0
local nextRequestAt = 0
local lastNotifyAt = -math.huge

-- Latched, not throttled. "You are full" is worth saying once when you walk
-- into something you cannot take; saying it every 1.8s for the whole walk back
-- to the sell pad would be nagging, not feedback. Re-armed by any change to
-- CurrentWeight or MaxWeight, i.e. the moment the fact could stop being true.
local fullNotified = false

-- Defined further down, forward-declared here because scan() calls it.
local notify

--[[
	ROOM LEFT IN WHATEVER IS FILLING RIGHT NOW -- which is the bag on foot and
	THE MACHINE'S HOLD while sitting in one.

	Through WeightConfig, because the server measures the same question with the
	same function and two answers that can disagree eventually will. It matters
	more than it looks: this number decides what the client even ASKS for, so a
	version that only ever measured the bag would go silent the moment that bag
	was full -- while sitting in a truck with four hundred pounds going spare.
]]
local function freeSpace(): number
	if player:GetAttribute(WeightConfig.MaxWeightAttribute) == nil
		and not WeightConfig.holdActive(player) then
		-- Attributes have not landed yet. Ask for everything and let the
		-- server sort it out -- it is the authority either way.
		return math.huge
	end
	return WeightConfig.freeFor(player)
end

local fillTween: Tween? = nil

local function refreshPill()
	local load = player:GetAttribute(WeightConfig.CurrentWeightAttribute)
	local max = player:GetAttribute(WeightConfig.MaxWeightAttribute)
	if type(load) ~= "number" then
		load = 0
	end
	if type(max) ~= "number" or max <= 0 then
		max = WeightConfig.BaseMaxWeight
	end

	loadText.Text = string.format("LOAD  %s / %s %s",
		WeightConfig.format(load), WeightConfig.format(max), UNIT)

	if fillTween then
		fillTween:Cancel()
	end
	fillTween = TweenService:Create(loadFill, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.new(math.clamp(load / max, 0, 1), 0, 1, 0),
	})
	fillTween:Play()

	local full = load >= max - EPS
	loadFill.BackgroundColor3 = full and BAR_FULL or BAR_LIGHT
	pillStroke.Color = full and GOLD or OUTLINE
	pillStroke.Thickness = full and 3.5 or 2.5
	loadText.TextColor3 = full and GOLD or Color3.fromRGB(226, 236, 246)
end

-- A refusal is only worth remembering until the thing that caused it changes.
local function reviewBlocked()
	local free = freeSpace()
	local now = os.clock()
	for item, until_ in blockedUntil do
		if not item.Parent then
			blockedUntil[item] = nil
		elseif now >= until_ or WeightConfig.resolveWeight(item) <= free + EPS then
			blockedUntil[item] = nil
		end
	end
end

----------------------------------------------------------------
-- CANDIDATES
----------------------------------------------------------------
local function consider(instance: Instance)
	if candidates[instance] then
		return
	end
	if not WeightConfig.isCandidate(instance) then
		return
	end
	local part = WeightConfig.anchorPart(instance)
	if part then
		candidates[instance] = part
		return
	end

	--[[
		No BasePart yet, which is NOT the same thing as "not a pickup".

		Every collectible in this place is a Model, and both routes into this
		function -- the CollectibleTrash tag and the Trash folder's
		DescendantAdded -- can fire the moment that Model is parented, before its
		MeshParts have replicated to this client. anchorPart then finds nothing.

		Dropping it here was silent and permanent: nothing ever reconsiders the
		Model, because the parts arriving a moment later fail isCandidate on their
		own (only the top instance counts). The prop just sat on the sand,
		un-collectable, for that one player -- which is exactly "I walked over it
		and nothing happened".

		So wait for the first part instead of giving up on it.
	]]
	local conn: RBXScriptConnection? = nil
	conn = instance.DescendantAdded:Connect(function(descendant)
		if not descendant:IsA("BasePart") then
			return
		end
		if conn then
			conn:Disconnect()
			conn = nil
		end
		-- Re-checked rather than assumed: a prop deleted, untagged or moved out
		-- of Trash while we were waiting must not come back as a candidate.
		if not candidates[instance] and instance.Parent and WeightConfig.isCandidate(instance) then
			consider(instance)
		end
	end)
end

local function forget(instance: Instance)
	candidates[instance] = nil
	blockedUntil[instance] = nil
	if pendingItems[instance] then
		pendingItems[instance] = nil
		pendingCount -= 1
	end
end

for _, instance in CollectionService:GetTagged(WeightConfig.CollectibleTag) do
	consider(instance)
end
CollectionService:GetInstanceAddedSignal(WeightConfig.CollectibleTag):Connect(consider)
CollectionService:GetInstanceRemovedSignal(WeightConfig.CollectibleTag):Connect(forget)

-- Folder route as well as the tag, so a prop dropped straight into
-- Workspace.Trash is visible to this script even before the server has
-- finished tagging it.
local watched: { [Instance]: boolean } = {}
local function watchFolder(folder: Instance)
	if watched[folder] then
		return
	end
	watched[folder] = true
	for _, descendant in folder:GetDescendants() do
		consider(descendant)
	end
	folder.DescendantAdded:Connect(consider)
	folder.DescendantRemoving:Connect(forget)
end

local existingFolder = WeightConfig.trashFolder()
if existingFolder then
	watchFolder(existingFolder)
end
workspace.ChildAdded:Connect(function(child)
	if child.Name == WeightConfig.TrashFolderName and child:IsA("Folder") then
		watchFolder(child)
	end
end)

----------------------------------------------------------------
-- REQUESTS
----------------------------------------------------------------
--[[
	One sweep's worth of asking.

	Takes a LIST. It used to take a single instance, and that is what left the
	litter you had already walked past on the sand: scan() nominated the NEAREST
	item and nothing else, so anything behind you lost the "nearest" contest on
	every tick -- its distance growing while the litter ahead shrank -- until it
	left the radius having never once been asked for. In a vehicle, where the net
	reaches wider and the machine crosses the beach at speed, one item per sweep
	could not keep up at all.

	This is a throughput change and not a trust change. The server validates
	every entry in the batch on its own -- registered, unclaimed, in range, fits
	-- exactly as it validated a request that could only name one thing.
]]
local function request(items: { Instance })
	if #items == 0 then
		return
	end
	local now = os.clock()
	if now < nextRequestAt then
		return
	end
	if pendingCount > 0 and now < pendingUntil then
		return
	end

	table.clear(pendingItems)
	pendingCount = 0
	for _, item in items do
		pendingItems[item] = true
		pendingCount += 1
	end
	pendingUntil = now + WeightConfig.ClientRequestTimeout
	nextRequestAt = now + WeightConfig.ClientRequestSpacing
	CollectRequest:FireServer(items)
end

--[[
	One sweep. Builds autoBatch: EVERY item in reach that fits and is not
	sitting out a refusal, nearest first. That per-item test is what lets a
	player walk past a tyre they cannot lift while still hoovering up the cans
	beside it -- there is no global "blocked" state on either side of the wire.

	autoBatch was a single `bestAuto`. See request() for why taking only the
	nearest one per tick left the things you had walked over lying there.

	It also used to pick a second thing, `bestTarget`: the nearest item within
	ManualPickupRadius whatever it weighed, which fed the E prompt. Both are
	gone -- see the header.
]]
local function scan()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (root and root:IsA("BasePart")) or not humanoid or humanoid.Health <= 0 then
		return
	end

	local origin = root.Position
	local free = freeSpace()
	local now = os.clock()

	-- On foot this is just AutoCollectRadius; in a vehicle it is the net.
	local autoReach = WeightConfig.reachFor(player)

	local eligible: { Instance } = {}
	local autoDist: { [Instance]: number } = {}
	-- Something in auto range that does NOT fit. Drives the one message the
	-- player is owed when a sweep comes back with nothing to ask for.
	local heavyInReach = false

	for item, part in candidates do
		-- Collected, respawning or deleted: drop it. Clearing a field of the
		-- table being traversed is safe in Luau.
		if not item.Parent or not part.Parent or not item:IsDescendantOf(workspace) then
			candidates[item] = nil
			blockedUntil[item] = nil
			continue
		end

		local distance = (part.Position - origin).Magnitude
		if distance > autoReach then
			continue
		end

		local blocked = blockedUntil[item]
		if not (blocked and now < blocked) then
			if WeightConfig.resolveWeight(item) <= free + EPS then
				table.insert(eligible, item)
				autoDist[item] = distance
			else
				heavyInReach = true
			end
		end
	end

	--[[
		Nearest first, then admitted against a RUNNING total of what the bag can
		still take -- not against the same snapshot every time.

		Testing each item against the untouched `free` was the first version of
		this batch, and it was worse than the starvation it set out to fix: with
		6 lb spare and ten 2 lb lumps in reach, all ten pass "fits by itself", the
		server takes three and refuses seven, and the TooHeavy branch below then
		puts a 2 second blockedUntil on every one of those seven. Walking into a
		pile with a nearly-full bag would have LOCKED THE PILE OUT.
	]]
	table.sort(eligible, function(a, b)
		return autoDist[a] < autoDist[b]
	end)

	local autoBatch: { Instance } = {}
	local budget = free
	for _, item in eligible do
		if #autoBatch >= WeightConfig.MaxAutoBatch then
			break
		end
		local weight = WeightConfig.resolveWeight(item)
		if weight <= budget + EPS then
			table.insert(autoBatch, item)
			budget -= weight
		else
			-- The bag filled up part way through this sweep. Everything past this
			-- point is a refusal waiting to happen, so it is left for the next
			-- sweep rather than asked for and blocked.
			heavyInReach = true
			break
		end
	end

	if WeightConfig.AutoCollect and #autoBatch > 0 then
		request(autoBatch)
		return
	end

	--[[
		The sweep found nothing to ask for. If something in reach simply does not
		fit, the player is owed a word about it -- and the old guard here
		(`free <= EPS`) only covered a bag with NO room left at all.

		The gap that left is the silent one: room left, but less than the lightest
		thing in front of you -- every encased lump is 2 lb against a 20 lb bag --
		so scan nominates nothing, no request is ever sent, and the game says
		nothing whatsoever while you walk over litter. That reads exactly like a
		broken pickup. heavyInReach is that case.
	]]
	if not fullNotified and heavyInReach then
		fullNotified = true
		if free <= EPS then
			notify(WeightConfig.Messages.Full, "warn", 2.2)
		else
			notify(string.format(WeightConfig.Messages.TooHeavy, WeightConfig.format(free), UNIT), "warn", 2.2)
		end
	end
end

local accumulator = 0
RunService.Heartbeat:Connect(function(dt)
	accumulator += dt
	if accumulator < WeightConfig.ClientScanInterval then
		return
	end
	-- Subtract the interval rather than zeroing it. Zeroing throws away the
	-- overshoot, so the true sweep period is ceil(interval/dt)*dt and never
	-- catches up after a slow frame -- at 30fps that stretches 0.1s to 0.133s
	-- and drags the collect rate down with it. Clamped so that one long hitch
	-- cannot bank enough credit to fire a burst of sweeps back to back.
	accumulator = math.min(accumulator - WeightConfig.ClientScanInterval,
		WeightConfig.ClientScanInterval)
	scan()
end)

----------------------------------------------------------------
-- SERVER ANSWERS
----------------------------------------------------------------
function notify(text: string, kind: string, hold: number)
	local now = os.clock()
	if now - lastNotifyAt < WeightConfig.NotifyCooldown then
		return
	end
	lastNotifyAt = now
	showToast(text, kind, hold)
	-- Under the toast's own tick, not over it: this fires alongside a ToastKit
	-- notification that is already making a noise, and two refusals at full
	-- level on the same frame is what turns "you cannot carry that" into a
	-- telling-off.
	AudioKit.play("Reject", nil, 0.8)
end

CollectResult.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then
		return
	end
	-- Tick this item off the in-flight batch. A nil item means the server
	-- answered without naming one (the request gate refusing a fire); that ends
	-- the whole batch, because there is nothing to tick off and sitting out the
	-- timeout would stop the player collecting anything at all for a second.
	local answered = payload.item
	if typeof(answered) == "Instance" then
		if pendingItems[answered] then
			pendingItems[answered] = nil
			pendingCount -= 1
		end
	elseif answered == nil then
		table.clear(pendingItems)
		pendingCount = 0
	end

	local item = payload.item

	if payload.ok then
		if typeof(item) == "Instance" then
			blockedUntil[item] = nil
			forget(item)
		end
		AudioKit.play("Pickup")
		refreshPill()
		return
	end

	local reason = payload.reason
	if reason == "TooHeavy" or reason == "Full" then
		if typeof(item) == "Instance" then
			blockedUntil[item] = os.clock() + WeightConfig.ClientRetryDelay
		end
		local free = freeSpace()
		if reason == "Full" or free <= EPS or free == math.huge then
			notify(WeightConfig.Messages.Full, "warn", 2.2)
		else
			notify(string.format(WeightConfig.Messages.TooHeavy, WeightConfig.format(free), UNIT), "warn", 2.2)
		end

	elseif reason == "BagFull" then
		if typeof(item) == "Instance" then
			blockedUntil[item] = os.clock() + WeightConfig.ClientRetryDelay
		end
		notify(WeightConfig.Messages.BagFull, "warn", 2.2)

	elseif reason == "UnknownItem" then
		if typeof(item) == "Instance" then
			blockedUntil[item] = os.clock() + WeightConfig.ClientRetryDelay
		end
		notify(WeightConfig.Messages.UnknownItem, "deny", 2.0)
	end
	-- "TooFar", "Unavailable" and "NoCharacter" are deliberately silent: the
	-- player did not do anything wrong and there is nothing to act on.
end)

----------------------------------------------------------------
-- ATTRIBUTE -> HUD
----------------------------------------------------------------
player:GetAttributeChangedSignal(WeightConfig.CurrentWeightAttribute):Connect(function()
	refreshPill()
	reviewBlocked()
	fullNotified = false
end)
-- Only an INCREASE is announced, and only once a previous value has been seen:
-- the first push of this attribute is the server saying what capacity you start
-- with, which is not an upgrade and must not toast on spawn.
local shownMax = player:GetAttribute(WeightConfig.MaxWeightAttribute)

player:GetAttributeChangedSignal(WeightConfig.MaxWeightAttribute):Connect(function()
	refreshPill()
	reviewBlocked()
	fullNotified = false
	local max = player:GetAttribute(WeightConfig.MaxWeightAttribute)
	if type(max) ~= "number" then
		return
	end
	if type(shownMax) == "number" and max > shownMax + EPS then
		ToastKit.banner(string.format("STORAGE UP  \u{2014}  %s %s", WeightConfig.format(max), UNIT), "level", 2)
	end
	shownMax = max
end)

-- A respawn invalidates every distance we had measured.
player.CharacterAdded:Connect(function()
	table.clear(pendingItems)
	pendingCount = 0
	fullNotified = false
	table.clear(blockedUntil)
end)

refreshPill()
