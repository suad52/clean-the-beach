--[[
	SiftServer  --  ServerScriptService.SiftServer

	Owns the sifting bay, the lump sitting on the screen, and how fast the crust
	comes off it. Replaces WashServer.

	THE PROTOCOL
	------------
	The client sends `{dir = 1 | -1}` the instant the player's swing changes
	direction, and nothing else. No speed, no amount, no duration -- even though
	speed is the whole skill of the mechanic, because the moment a client is
	allowed to report how hard it is shaking, that is the number an exploiter
	edits.

	So the server measures it instead. It keeps the timestamps of the last
	CadenceWindow seconds of reversals and divides:

		cadence = #reversals / CadenceWindow
		vigour  = 1 - ((cadence - CadenceBest) / CadenceSpan)^2
		gain    = rate * vigour * dt / chunkWork

	where dt is the gap since the last credit, clamped to MaxTickDelta.

	WHY FLOODING THE REMOTE BACKFIRES
	---------------------------------
	That vigour term is a curve with a peak, not a ramp. It is 1.0 at
	CadenceBest and falls away on BOTH sides. A bot hammering reversals at the
	rate limiter's ceiling sits miles past the peak and bottoms out at
	VigourFloor -- it sifts about a twelfth as fast as somebody just playing.
	The exploit is not merely capped, it is worse than not doing it.

	And because dt is measured between credits, shaking faster never buys extra
	time either: twice the reversals is twice as many credits of half the dt.
	Over any wall-clock second the server credits one second of work, scaled by
	how good the rhythm was during it.

	Two reversals of the same sign in a row are not a reversal at all, and are
	dropped -- so holding one direction, or mashing one key, does nothing.

	WHICH CHUNK COMES OFF
	---------------------
	Not the player's choice any more -- there is no aim in a shake. Each lump
	gets a seeded shuffle at mount time and the crust breaks away in that order,
	so it comes apart in a scattered, physical-looking pattern rather than
	peeling tidily from index 1. The client is told which chunk is currently
	working loose so it can rattle that one; it is never told what is underneath.

	AUTO-ADVANCE
	------------
	When a lump finishes and the player is still carrying crusted ones, the next
	goes on the screen automatically after the reveal beat. Walking back to the
	prompt between every rock would kill the rhythm -- and rhythm is now quite
	literally the mechanic.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local ItemConfig = require(Modules:WaitForChild("ItemConfig"))
local ItemVisuals = require(Modules:WaitForChild("ItemVisuals"))
local InventoryController = require(Modules:WaitForChild("InventoryController"))
local Net = require(Modules:WaitForChild("Net"))

local ValueCalculator = require(script.Parent.ValueCalculator)
local SiftScreen = require(script.Parent.SiftScreen)

local CFG = GameConfig.Sifting

local SiftServer = {}

local bays = {}       -- [Model] = bay
local sessions = {}   -- [Player] = session
local rateWindow = {} -- [Player] = {start, count}

local bayCounter = 0
local lumpSeed = 0

--------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------

local function notify(player: Player, text: string, kind: string?)
	Net.get("Notify"):FireClient(player, { text = text, kind = kind or "info" })
end

local function rootPosition(player: Player): Vector3?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return root and root.Position or nil
end

local function inRange(player: Player, bay): boolean
	local pos = rootPosition(player)
	return pos ~= nil and (pos - bay.screen.Position).Magnitude <= CFG.BayRange
end

--------------------------------------------------------------------------
-- BAY REGISTRATION
--------------------------------------------------------------------------

local function registerBay(model: Instance)
	if not model:IsA("Model") or bays[model] then
		return
	end

	local screen = model:FindFirstChild("Screen", true)
	if not (screen and screen:IsA("BasePart")) then
		warn("[SiftServer] sifting bay has no BasePart named 'Screen':", model:GetFullName())
		return
	end

	bayCounter += 1

	local mountFolder = model:FindFirstChild("Mounted")
	if not mountFolder then
		mountFolder = Instance.new("Folder")
		mountFolder.Name = "Mounted"
		mountFolder.Parent = model
	end

	local promptHost = model:FindFirstChild("PromptAnchor", true)
	if not (promptHost and promptHost:IsA("BasePart")) then
		promptHost = screen
	end

	local prompt = promptHost:FindFirstChildWhichIsA("ProximityPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Sift Crusted Find"
		prompt.ObjectText = "Sifting Bay"
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 12
		prompt.RequiresLineOfSight = false
		prompt.Parent = promptHost
	end

	local bay = {
		model = model,
		screen = screen,
		mountFolder = mountFolder,
		prompt = prompt,
		id = string.format("bay%02d", bayCounter),
		occupant = nil,
	}
	bays[model] = bay

	prompt.Triggered:Connect(function(player)
		SiftServer.mount(player, bay)
	end)

	model.AncestryChanged:Connect(function(_, parent)
		if not parent then
			if bay.occupant then
				SiftServer.endSession(bay.occupant, "bay-removed")
			end
			bays[model] = nil
		end
	end)
end

-- Look up the registered bay for a tagged Model. Exposed because `bays` is
-- otherwise unreachable from outside, which left mount() callable only from
-- the ProximityPrompt closure -- no dev tooling, no headless test, no way to
-- open a bay from a cutscene or a tutorial step.
function SiftServer.bayFromModel(model: Model)
	return bays[model]
end

--------------------------------------------------------------------------
-- MOUNT / UNMOUNT
--------------------------------------------------------------------------

local function spawnLump(bay, rec): Model
	lumpSeed += 1
	local model = ItemVisuals.buildEncased(rec.itemId, lumpSeed)
	model:SetAttribute("SiftUid", rec.uid)
	-- The itemId attribute would hand the client the answer for free.
	model:SetAttribute("ItemId", nil)
	-- ...and so does the NAME. buildEncased calls it "Lump_Coin", which replicates
	-- like everything else, so anyone who opened the explorer -- or read it from a
	-- local script -- knew what was inside before they had shaken it once. The
	-- whole point of a crusted find is that it is a mystery until it opens.
	model.Name = "Lump"
	model.Parent = bay.mountFolder
	-- Sits IN the deck now, not floating above a post: just clear of the mesh so
	-- the crust that shakes loose has somewhere to fall through.
	model:PivotTo(bay.screen.CFrame * CFrame.new(0, bay.screen.Size.Y * 0.5 + 1.1, 0))
	return model
end

-- The order the crust breaks away in. Seeded off the lump so it is stable for
-- the life of the session (a re-push of progress must never reshuffle it), and
-- scattered so the rock comes apart in patches instead of unzipping from one
-- end.
local function shuffleOrder(total: number, seed: number): { number }
	local order = table.create(total)
	for i = 1, total do
		order[i] = i
	end
	local rng = Random.new(seed)
	for i = total, 2, -1 do
		local j = rng:NextInteger(1, i)
		order[i], order[j] = order[j], order[i]
	end
	return order
end

function SiftServer.mount(player: Player, bay)
	local inv = InventoryController.Server.get(player)

	if bay.occupant and bay.occupant ~= player then
		notify(player, "Someone is already using this bay.", "warn")
		return
	end

	local existing = sessions[player]
	if existing and existing.bay ~= bay then
		SiftServer.endSession(player, "moved-bay")
		existing = nil
	end
	if existing and existing.uid then
		notify(player, "Finish the one on the screen first.", "warn")
		return
	end

	local crusted = inv:GetByState("Crusted")
	if #crusted == 0 then
		notify(player, "Nothing crusted to sift. Go find some!", "info")
		return
	end

	local rec = crusted[1]
	inv:SetState(rec.uid, "Sifting")
	rec.stationId = bay.id

	local session = existing
	if not session then
		session = { player = player, bay = bay, lastPacket = 0, lastPush = 0 }
		sessions[player] = session
		bay.occupant = player
	end

	session.uid = rec.uid
	session.model = spawnLump(bay, rec)
	session.total = ItemConfig.chunkCount(rec.itemId)
	session.remaining = session.total
	session.chunkWork = ItemConfig.chunkWorkFor(rec.itemId, CFG.ChunkWork)
	session.chunks = table.create(session.total, 0)
	session.order = shuffleOrder(session.total, lumpSeed)
	session.nextIndex = 1

	-- Shake state. `reversals` is the sliding window the cadence is measured
	-- over; `lastDir` is what makes a reversal a reversal.
	session.reversals = {}
	session.lastDir = 0
	session.lastShake = 0
	session.lastCredit = os.clock()
	session.vigour = 0

	Net.get("SiftBegin"):FireClient(player, {
		bayId = bay.id,
		bay = bay.model,
		screen = bay.screen,
		model = session.model,
		uid = rec.uid,
		chunkTotal = session.total,
		current = session.order[1],
		-- NOT sent: itemId, rarity, value, or the rest of the order. The player
		-- is sifting a mystery, and knowing what breaks next tells them nothing
		-- about what is inside.
	})
	Net.get("Fx"):FireAllClients({ kind = "Mount", part = bay.screen })
end

local function despawn(session)
	if session.model then
		session.model:Destroy()
		session.model = nil
	end
end

function SiftServer.endSession(player: Player, reason: string?)
	local session = sessions[player]
	if not session then
		return
	end
	sessions[player] = nil
	if session.bay.occupant == player then
		session.bay.occupant = nil
	end

	local inv = InventoryController.Server.find(player)
	if inv and session.uid then
		local rec = inv:Get(session.uid)
		if rec and rec.state == "Sifting" then
			-- Back in the bag, keeping the crust it has already lost. Walking
			-- away costs the condition bonus, not the work.
			inv:SetState(session.uid, "Crusted")
			rec.stationId = nil
			rec.interrupted = true
		end
	end

	despawn(session)
	Net.get("SiftEnd"):FireClient(player, { reason = reason or "done" })
end

--------------------------------------------------------------------------
-- COMPLETION
--------------------------------------------------------------------------

local function completeLump(session)
	local player = session.player
	local inv = InventoryController.Server.find(player)
	if not inv then
		return
	end
	local rec = inv:Get(session.uid)
	if not rec then
		return
	end
	local def = ItemConfig.expect(rec.itemId)

	inv:SetProgress(rec.uid, 1)
	local value = ValueCalculator.roll(rec.itemId, {
		uninterrupted = not rec.interrupted,
		stalled = false,
		player = player,
	})
	inv:SetValue(rec.uid, value)
	-- Flipping to Cleaned is what un-hides the identity in publicView. Until
	-- this line the client has never been told what it was sifting.
	inv:SetState(rec.uid, "Cleaned")

	local model = session.model
	if model then
		ItemVisuals.setUncovered(model, 1)
	end

	Net.get("SiftItemCleaned"):FireClient(player, {
		uid = rec.uid,
		itemId = rec.itemId,
		displayName = def.DisplayName,
		description = def.Description,
		rarity = def.Rarity,
		value = value,
		model = model,
	})
	Net.get("Fx"):FireAllClients({
		kind = "Sparkle",
		part = model and model.PrimaryPart or session.bay.screen,
		rarity = def.Rarity,
	})

	local finishedUid = session.uid
	session.uid = nil

	-- `hold`, not `RevealHoldBonus`: rarityInfo's keys are lowercase, and the
	-- old name silently evaluated to nil -- which threw right here and killed
	-- the reveal beat, the despawn and the auto-advance with it.
	local hold = CFG.RevealHoldTime + (ItemConfig.rarityInfo(def.Rarity).hold or 0)
	task.delay(hold, function()
		if sessions[player] ~= session then
			return
		end
		despawn(session)

		-- Auto-advance: putting the next lump on the screen keeps the rhythm
		-- going instead of sending the player back to the prompt after each rock.
		local live = InventoryController.Server.find(player)
		if live and #live:GetByState("Crusted") > 0 and inRange(player, session.bay) then
			SiftServer.mount(player, session.bay)
		else
			SiftServer.endSession(player, "screen-clear")
		end
	end)

	return finishedUid
end

--------------------------------------------------------------------------
-- SHAKE PACKET
--------------------------------------------------------------------------

local function passesRateLimit(player: Player, now: number): boolean
	local w = rateWindow[player]
	if not w or now - w.start >= 1 then
		rateWindow[player] = { start = now, count = 1 }
		return true
	end
	w.count += 1
	return w.count <= CFG.MaxPacketsPerSecond
end

-- Reversals per second over the trailing window, measured entirely on the
-- server clock. Trimming first is what makes this decay when the player slows
-- down or stops, rather than remembering a good burst forever.
local function cadenceOf(session, now: number): number
	local rev = session.reversals
	local cut = now - CFG.CadenceWindow
	while #rev > 0 and rev[1] < cut do
		table.remove(rev, 1)
	end
	return #rev / CFG.CadenceWindow
end

-- 1.0 on the sweet spot, falling away quadratically on either side. Squared
-- rather than linear so the peak is broad enough to actually hold but the
-- tails drop off hard -- which is what makes flooding the remote pointless.
local function vigourOf(cadence: number): number
	local off = (cadence - CFG.CadenceBest) / CFG.CadenceSpan
	return math.max(math.clamp(1 - off * off, 0, 1), CFG.VigourFloor)
end

local function popChunk(session, index: number)
	local chunk = ItemVisuals.findChunk(session.model, index)
	if chunk then
		-- Destroying it server-side replicates, so bystanders watch the rock come
		-- apart too. The falling flake is the client's business.
		chunk:Destroy()
	end
	session.remaining -= 1

	Net.get("SiftChunkGone"):FireClient(session.player, {
		chunk = index,
		next = session.order[session.nextIndex + 1],
	})
	Net.get("Fx"):FireAllClients({
		kind = "ChunkGone",
		part = session.bay.screen,
		chunk = index,
	})

	local inv = InventoryController.Server.find(session.player)
	if inv then
		inv:SetProgress(session.uid, 1 - session.remaining / session.total)
	end
	if session.model then
		ItemVisuals.setUncovered(session.model, 1 - session.remaining / session.total)
	end
end

local function onShake(player: Player, payload)
	local session = sessions[player]
	if not (session and session.uid and session.model) then
		return
	end
	if type(payload) ~= "table" then
		return
	end

	local dir = payload.dir
	if dir ~= 1 and dir ~= -1 then
		return
	end

	local now = os.clock()
	if not passesRateLimit(player, now) then
		return
	end
	-- Two of the same sign is not a reversal. Holding a direction, or mashing
	-- one key, produces nothing at all.
	if dir == session.lastDir then
		return
	end
	-- Faster than a human wrist can turn around. Dropped before it can even
	-- reach the cadence estimate, so it cannot drag the rhythm off the peak
	-- for a player who is genuinely playing on a bad connection.
	if now - session.lastShake < CFG.MinReversalInterval then
		return
	end
	session.lastDir = dir
	session.lastShake = now
	session.lastPacket = now

	if not inRange(player, session.bay) then
		SiftServer.endSession(player, "out-of-range")
		return
	end

	-- Everything from here is the server's own arithmetic on the server's own
	-- clock. Nothing the client sent contributes a magnitude.
	local cadence = cadenceOf(session, now)
	table.insert(session.reversals, now)
	session.vigour = vigourOf(cadence)

	local dt = math.clamp(now - session.lastCredit, 0, CFG.MaxTickDelta)
	session.lastCredit = now
	if dt <= 0 then
		return
	end

	local gain = SiftScreen.rateFor(player) * session.vigour * dt / session.chunkWork

	-- Spill over between chunks rather than throwing the remainder away, or a
	-- fast screen would waste most of a big shake on whatever was nearly gone.
	local carry = gain
	while carry > 0 and session.nextIndex <= session.total do
		local index = session.order[session.nextIndex]
		local after = session.chunks[index] + carry
		if after < 1 then
			session.chunks[index] = after
			carry = 0
		else
			session.chunks[index] = 1
			carry = after - 1
			session.nextIndex += 1
			popChunk(session, index)
			if session.remaining <= 0 then
				completeLump(session)
				return
			end
		end
	end
end

--------------------------------------------------------------------------
-- TICK
--------------------------------------------------------------------------

local function tick()
	local now = os.clock()
	for player, session in sessions do
		if not inRange(player, session.bay) then
			SiftServer.endSession(player, "walked-away")
			continue
		end

		-- Stopped swinging: let the rhythm die off so the HUD meter falls and the
		-- screen visibly settles, instead of freezing at whatever it last read.
		if session.uid and now - session.lastShake > CFG.ShakeGrace then
			session.vigour = 0
			session.lastCredit = now
		end

		if session.uid and now - session.lastPush >= CFG.ProgressPushInterval then
			session.lastPush = now
			Net.get("SiftProgress"):FireClient(player, {
				uid = session.uid,
				chunks = session.chunks,
				remaining = session.remaining,
				total = session.total,
				current = session.order[session.nextIndex],
				vigour = session.vigour,
			})
		end
	end
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

local started = false
function SiftServer.start()
	assert(RunService:IsServer(), "[SiftServer] server-only")
	if started then
		return
	end
	started = true

	local tag = GameConfig.Tags.SiftBay
	for _, model in CollectionService:GetTagged(tag) do
		registerBay(model)
	end
	CollectionService:GetInstanceAddedSignal(tag):Connect(registerBay)

	Net.get("SiftShake").OnServerEvent:Connect(onShake)
	Net.get("SiftEndRequest").OnServerEvent:Connect(function(player)
		SiftServer.endSession(player, "player-request")
	end)

	Players.PlayerRemoving:Connect(function(player)
		SiftServer.endSession(player, "left")
		rateWindow[player] = nil
	end)

	RunService.Heartbeat:Connect(tick)
end

return SiftServer
