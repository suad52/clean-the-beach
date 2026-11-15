--[[
	TrashCollectionService  --  ServerScriptService.WeightSystem.TrashCollectionService

	The world half: which instances are collectible, who is allowed to collect
	one, and what happens to it afterwards. All of it server-side.

	SECURITY SHAPE
	--------------
	The client sends ONE thing: the instance it would like to pick up. Every
	other fact is established here.

		* the instance must be in the registry -- an unregistered instance is
		  refused outright, so this remote can never be used to destroy or move
		  something that is not a piece of trash
		* the player must be alive, with a HumanoidRootPart
		* the player must be within range of it (client radius + a latency
		  allowance), measured from the server's own copy of both positions
		* the request must pass a token bucket
		* the WEIGHT is read here, from the instance, never from the packet
		* the capacity decision belongs to WeightService

	RACES
	-----
	Between the registry check and the despawn there is not a single yielding
	call, and the instance is claimed before anything is committed. Two players
	touching the same bottle on the same frame therefore cannot both bank it:
	the second one finds it gone and is told so.

	NO PROMPT, NO KEY
	-----------------
	Collecting is walking. This file used to be able to hang a ProximityPrompt
	on every registered piece of litter behind WeightConfig.UseProximityPrompts;
	that flag and the branch behind it are gone, so nothing here can put an "E"
	over a bottle again. What drives collection is WeightClient's sweep firing
	CollectRequest, validated below exactly as it always was.

	SELECTIVE PICKUP
	----------------
	Every item is judged on its own. A tyre that does not fit is refused with
	"TooHeavy" while the cans around it keep collecting normally -- there is no
	global "blocked" state anywhere in this file, because the answer depends
	entirely on the weight of the item being asked about.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local WeightSystem = ReplicatedStorage:WaitForChild("WeightSystem", 30)
assert(WeightSystem, "[TrashCollectionService] ReplicatedStorage.WeightSystem is missing")
local WeightConfig = require(WeightSystem:WaitForChild("WeightConfig"))
local WeightNet = require(WeightSystem:WaitForChild("WeightNet"))

local WeightService = require(script.Parent:WaitForChild("WeightService"))
-- For the attribute NAME only. The lifetime piece counter the MOST TRASH world
-- leaderboard ranks -- CTBBridge increments the same attribute for the finds
-- that come out of CTB's own buried field. See the block over its countPickup.
local LeaderboardConfig = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("LeaderboardConfig"))

local TAG = WeightConfig.CollectibleTag
local HIDDEN_FOLDER_NAME = "WeightSystem_Collected"
local BASE_RANGE = math.max(WeightConfig.ManualPickupRadius, WeightConfig.AutoCollectRadius)
	+ WeightConfig.ServerRangeTolerance

-- Per player, not a constant: riding an ATV widens the reach to its net, and a
-- fixed ceiling here would refuse everything the net legitimately caught. The
-- net radius is a SERVER-written attribute (AtvServer), so this is still the
-- server deciding how far this player may reach -- never the client.
local function rangeFor(player: Player): number
	local reach = WeightConfig.reachFor(player) + WeightConfig.ServerRangeTolerance
	return math.max(BASE_RANGE, reach)
end

local TrashCollectionService = {}

type Entry = {
	conns: { RBXScriptConnection },
	homeParent: Instance,
	homeCFrame: CFrame,
}

local registry: { [Instance]: Entry } = {}
local claimed: { [Instance]: boolean } = {}
local buckets: { [Player]: { tokens: number, last: number } } = {}
local connections: { RBXScriptConnection } = {}

local hiddenFolder: Folder
local started = false

local register, unregister

----------------------------------------------------------------
-- REGISTRY
----------------------------------------------------------------

-- Something further up the tree is already the collectible, so this is one of
-- its parts, not a pickup of its own.
local function hasRegisteredAncestor(instance: Instance): boolean
	local parent = instance.Parent
	while parent and parent ~= workspace do
		if registry[parent] then
			return true
		end
		parent = parent.Parent
	end
	return false
end

function register(instance: Instance)
	if typeof(instance) ~= "Instance" or registry[instance] then
		return
	end
	if not WeightConfig.isCandidate(instance) then
		return
	end
	if not instance:IsDescendantOf(workspace) then
		return
	end
	if hasRegisteredAncestor(instance) then
		return
	end

	local part = WeightConfig.anchorPart(instance)
	if not part then
		warn("[TrashCollectionService] collectible has no BasePart, skipping: " .. instance:GetFullName())
		return
	end
	local parent = instance.Parent
	if not parent then
		return
	end

	local entry: Entry = {
		conns = {},
		homeParent = parent,
		homeCFrame = instance:GetPivot(),
	}
	-- Registry first: AddTag below fires GetInstanceAddedSignal straight back
	-- into this function, and the guard at the top has to already see it.
	registry[instance] = entry

	if not CollectionService:HasTag(instance, TAG) then
		CollectionService:AddTag(instance, TAG)
	end

	table.insert(entry.conns, instance.Destroying:Connect(function()
		unregister(instance)
	end))
	table.insert(entry.conns, instance.AncestryChanged:Connect(function()
		if not instance:IsDescendantOf(workspace) then
			unregister(instance)
		end
	end))

end

function unregister(instance: Instance): Entry?
	local entry = registry[instance]
	if not entry then
		return nil
	end
	registry[instance] = nil
	claimed[instance] = nil

	for _, conn in entry.conns do
		conn:Disconnect()
	end
	table.clear(entry.conns)
	return entry
end

----------------------------------------------------------------
-- DESPAWN / RESPAWN
----------------------------------------------------------------
local function stillPart(instance: Instance)
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		end
	end
	if instance:IsA("BasePart") then
		instance.AssemblyLinearVelocity = Vector3.zero
		instance.AssemblyAngularVelocity = Vector3.zero
	end
end

--[[
	WHERE A COLLECTED PROP COMES BACK.

	Parked in ServerStorage rather than destroyed: it leaves the world for every
	client (ServerStorage does not replicate) and can come back exactly where the
	builder put it, so a hand-placed prop is never lost to a pickup.

	BUT THE BEACH'S OWN LITTER DOES NOT GO BACK WHERE IT WAS. Returning one of
	TrashSeeder's props to its seeded CFrame drops it onto sand the player may
	have raked clean while it was parked -- garbage reappearing on ground they
	personally just cleared, which is the one thing raking is supposed to
	guarantee against. RespawnMove is the hook that rolls a fresh spot instead.
	CTBBridge installs it and answers out of CTB's own grid; nothing in this
	system needs to know that grid exists.

	THE CONTRACT, and the middle case is the point of it:
	  true   -- the hook has moved it; use where it now stands
	  false  -- nowhere to put it yet (the whole field is clean). Stay parked and
	            ask again after another RespawnDelay. The tide will make room.
	  nil    -- no opinion; fall back to the seeded CFrame

	Only props whose home is the trash folder are offered to the hook at all, so
	hand-placed set dressing keeps the exact-restore behaviour it has always had.
]]
TrashCollectionService.RespawnMove = nil

local restore
restore = function(instance: Instance, homeParent: Instance, homeCFrame: CFrame)
	-- Destroyed, or something else moved it while it was parked: leave it be.
	if instance.Parent ~= hiddenFolder then
		return
	end
	if not homeParent or not homeParent:IsDescendantOf(game) then
		instance:Destroy()
		return
	end

	local placed = false
	local move = TrashCollectionService.RespawnMove
	if move and homeParent == WeightConfig.trashFolder() then
		local ok, verdict = pcall(move, instance)
		if not ok then
			warn("[TrashCollectionService] RespawnMove failed: " .. tostring(verdict))
		elseif verdict == false then
			task.delay(WeightConfig.RespawnDelay, restore, instance, homeParent, homeCFrame)
			return
		else
			placed = verdict == true
		end
	end

	if not placed then
		instance:PivotTo(homeCFrame)
	end
	stillPart(instance)
	instance.Parent = homeParent
	-- The folder's DescendantAdded fires too; register() is idempotent, and
	-- a tagged item that lives outside the folder needs this call.
	register(instance)
end

local function despawn(instance: Instance)
	local entry = unregister(instance)
	if not entry then
		return
	end

	if not WeightConfig.RespawnEnabled then
		instance:Destroy()
		return
	end

	instance.Parent = hiddenFolder
	task.delay(WeightConfig.RespawnDelay, restore, instance, entry.homeParent, entry.homeCFrame)
end

----------------------------------------------------------------
-- REQUEST GATE
----------------------------------------------------------------
local function allowRequest(player: Player): boolean
	local now = os.clock()
	local bucket = buckets[player]
	if not bucket then
		bucket = { tokens = WeightConfig.RequestBurst, last = now }
		buckets[player] = bucket
	end
	bucket.tokens = math.min(
		WeightConfig.RequestBurst,
		bucket.tokens + (now - bucket.last) * WeightConfig.MaxRequestsPerSecond)
	bucket.last = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

--[[
	THE VEHICLE HOLD

	While a player is sitting in something from the car spawner, the net fills
	THE MACHINE and not the bag on their back. Resolved lazily and optionally --
	this folder is a standalone system and must still run in a place with no
	vehicles in it at all -- so every use below is guarded.
]]
local holdLoaded = false
local VehicleHold = nil
local function vehicleHold()
	if holdLoaded then
		return VehicleHold
	end
	holdLoaded = true
	local module = game:GetService("ServerScriptService"):FindFirstChild("VehicleHold")
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" and type(result.riding) == "function" then
			VehicleHold = result
		elseif not ok then
			warn("[TrashCollectionService] VehicleHold present but would not load:", result)
		end
	end
	return VehicleHold
end

--[[
	FLYING A COLLECTED PIECE INTO THE MACHINE THAT TOOK IT.

	A piece of litter that simply BLINKS OUT reads as a bug rather than as a
	pickup, however close the machine is. So it is thrown to the scoop first,
	on a short arc, and despawned when it lands -- and it lands in the net or
	against the blade, which is where the load then visibly piles up.

	INTO THE SCOOP, NOT INTO THE MIDDLE OF THE MACHINE. Falling back to the
	PrimaryPart puts the arc into the chassis, which on the dozer is under the
	canopy behind the driver -- litter flying over your shoulder rather than
	into the thing collecting it. Net first, blade second, and the fallback is
	only for a machine with neither.

	SERVER SIDE, so every player sees the same thing and the existing despawn
	(which parks the prop in ServerStorage for the respawn timer) still runs
	exactly as before -- it just runs a quarter of a second later.

	The piece stays CLAIMED for the whole flight, so nobody else can take it in
	mid-air, and its Anchored/CanCollide are put back before it is handed on:
	a prop that respawned anchored would sit in the sand refusing to be picked
	up ever again.

	WHAT YOU DRIVE OVER DOES NOT FLY. THAT IS THE WHOLE POINT.
	---------------------------------------------------------
	A piece already inside the scoop has nowhere to fly TO, and tossing it into
	the air first is what made collection read as litter being sucked at the
	machine rather than gathered by it -- the flight is supposed to be the net
	sweeping something in, not a magnet. Under FLY_NEAR it simply goes, which
	is what running a truck over a bottle should look like.

	And the ones that do fly are timed by DISTANCE, so a piece caught at the
	edge of the net travels for longer than one clipped by the bumper. A fixed
	duration makes the far ones streak and the near ones dawdle.
]]
local FLY_NEAR = 7          -- studs. Inside this it is already in the scoop.
local FLY_SPEED = 62        -- studs/second the toss travels at
local FLY_MIN = 0.10
local FLY_MAX = 0.34
local FLY_ARC = 3

local function flyInto(instance: Instance, model: Model?, finish: () -> ())
	local target = model and (model:FindFirstChild("Net")
		or model:FindFirstChild("Blade")
		or model.PrimaryPart)
	if not (target and target:IsA("BasePart") and instance:IsA("PVInstance")) then
		finish()
		return
	end

	local span = (instance:GetPivot().Position - target.Position).Magnitude
	if span <= FLY_NEAR then
		finish()
		return
	end
	local flyTime = math.clamp(span / FLY_SPEED, FLY_MIN, FLY_MAX)

	local frozen = {}
	local function freeze(p: BasePart)
		table.insert(frozen, { p, p.Anchored, p.CanCollide })
		p.Anchored = true
		p.CanCollide = false
	end
	if instance:IsA("BasePart") then
		freeze(instance)
	end
	for _, d in instance:GetDescendants() do
		if d:IsA("BasePart") then
			freeze(d)
		end
	end

	task.spawn(function()
		local from = instance:GetPivot().Position
		-- The arc is scaled to the trip as well. A three stud hop over a one
		-- stud journey is a prop bouncing on the spot.
		local arc = FLY_ARC * math.clamp(span / 24, 0.35, 1)
		local t = 0
		while t < flyTime do
			local dt = RunService.Heartbeat:Wait()
			t += dt
			if not (instance.Parent and target.Parent) then
				break
			end
			local a = math.min(t / flyTime, 1)
			-- Smoothstep in, so it leaves the sand gently and arrives fast.
			local eased = a * a * (3 - 2 * a)
			local pos = from:Lerp(target.Position, eased)
				+ Vector3.new(0, math.sin(a * math.pi) * arc, 0)
			instance:PivotTo(CFrame.new(pos) * CFrame.Angles(t * 11, t * 8, t * 5))
		end
		for _, e in frozen do
			if e[1].Parent then
				e[1].Anchored = e[2]
				e[1].CanCollide = e[3]
			end
		end
		finish()
	end)
end

local function respond(player: Player, ok: boolean, reason: string, instance: Instance?, weight: number?, label: string?)
	WeightNet.get("CollectResult"):FireClient(player, {
		ok = ok,
		reason = reason,
		item = instance,
		weight = weight and WeightConfig.round(weight) or nil,
		label = label,
		load = WeightService.getLoad(player),
		max = WeightService.getMax(player),
	})
end

----------------------------------------------------------------
-- COLLECT
----------------------------------------------------------------
--[[
	The whole feature, in one function.

	Returns true only when the item was banked, and a reason code alongside it so
	a caller can decide between "say nothing" (you were too far away, someone beat
	you to it) and "toast the player" (it is too heavy).

	TWO WAYS IN, DIFFERING IN EXACTLY TWO THINGS -- see the two thin wrappers
	under this function.

	  the player asked for this piece
	      Range is checked against their reach, and every refusal is answered so
	      the client stops nominating it.

	  the SIFTER passed over the cell it is lying on
	      THE RAKE BAND IS THE RANGE TEST. It is the thing the player can
	      actually see sweeping the sand, it is what the server already used to
	      decide the cell was cleared, and at a high RollerWidth it is several
	      times wider than any pickup reach -- so measuring the prop against the
	      reach as well would refuse pieces the tool visibly just swept over.
	      Refusals are also SILENT, because CTB_Server answers a refused rake by
	      stopping the roller and firing its own once-per-episode BAG FULL nudge.
	      Two toasts for one event is worse than none.

	The success answer is sent on BOTH paths. The client needs it whether or not
	it asked: it carries the new load and max, which is what moves the bag meter.
]]
local function attempt(player: Player, instance: Instance, checkRange: boolean, quiet: boolean): (boolean, string)
	-- One place that decides whether a refusal is spoken aloud, so no branch
	-- below can forget which of the two callers it is answering.
	local function refuse(reason: string, weight: number?, label: string?): (boolean, string)
		if not quiet then
			respond(player, false, reason, instance, weight, label)
		end
		return false, reason
	end

	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, "NoPlayer"
	end
	if typeof(instance) ~= "Instance" then
		return false, "Unavailable"
	end

	-- Registered, and not already being handed to somebody else.
	if not registry[instance] or claimed[instance] then
		return refuse("Unavailable")
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (root and root:IsA("BasePart")) or not humanoid or humanoid.Health <= 0 then
		return refuse("NoCharacter")
	end

	local position = WeightConfig.positionOf(instance)
	if not position then
		return refuse("Unavailable")
	end
	if checkRange and (position - root.Position).Magnitude > rangeFor(player) then
		return refuse("TooFar")
	end

	-- Read from the instance, never from the request.
	local weight = WeightConfig.resolveWeight(instance)
	local label = WeightConfig.labelOf(instance)

	--[[
		RIDING: IT GOES IN THE MACHINE.

		This branch returns on every path, so the bag route below is genuinely
		the on-foot case rather than a fallback that might also run. A driver's
		own rucksack is not touched at all while they are sitting down -- which
		is the point of the feature: you can fill a 450 lb hopper with a full
		bag on your back and sort it out later.
	]]
	local holds = vehicleHold()
	local hold = holds and holds.riding(player)
	if hold then
		if not holds.canStow(hold, weight) then
			return refuse("HoldFull", weight, label)
		end
		claimed[instance] = true
		if not holds.stow(hold, WeightConfig.itemIdOf(instance), weight, label) then
			claimed[instance] = nil
			return refuse("HoldFull", weight, label)
		end
		-- Banked already: the hold has it and the HUD has moved. The prop itself
		-- takes a quarter second to get there, and only then is it despawned.
		respond(player, true, "Collected", instance, weight, label)
		flyInto(instance, hold.model, function()
			despawn(instance) -- clears the claim as part of unregistering
		end)
		return true, "Collected"
	end

	local fits, why = WeightService.canCarry(player, weight)
	if not fits then
		return refuse(why, weight, label)
	end

	-- Committed from here: no yields until the item is gone.
	claimed[instance] = true

	local record, reason = WeightService.collect(player, weight, {
		itemId = WeightConfig.itemIdOf(instance),
		label = label,
	})
	if not record then
		claimed[instance] = nil
		return refuse(reason, weight, label)
	end

	-- ANSWER FIRST, THEN DESPAWN. despawn parks the instance in ServerStorage,
	-- which does not replicate, so an ack fired after it reaches the client with
	-- payload.item already nil -- and the success branch there is guarded on
	-- `typeof(item) == "Instance"`, so forget(item) never ran and the client
	-- could re-nominate something it had just collected, burning a request on an
	-- answer of "Unavailable". Neither call yields, so the claim still cannot be
	-- raced between the two.
	-- Counted here, past the last thing that can refuse: the weight ledger has
	-- taken it and the instance is on its way out, so this piece is genuinely
	-- collected and cannot be un-collected by a later branch.
	local key = LeaderboardConfig.TrashAttribute
	player:SetAttribute(key, (tonumber(player:GetAttribute(key)) or 0) + 1)

	respond(player, true, "Collected", instance, weight, label)
	despawn(instance) -- clears the claim as part of unregistering
	return true, "Collected"
end

-- The player (or their vehicle's net) nominated this piece.
function TrashCollectionService.collect(player: Player, instance: Instance): boolean
	local ok = attempt(player, instance, true, false)
	return ok
end

--[[
	The sifter swept the cell this piece is lying on.

	Hands back the reason as well as the verdict, because the caller has to tell
	two refusals apart and they mean opposite things for the sand:

	  Full / TooHeavy / HoldFull   the bag would not take it. The cell must stay
	                               dirty -- clearing sand out from under a piece
	                               the player cannot carry is the bug this whole
	                               path exists to remove.
	  Unavailable / anything else  somebody else is mid-collect, or it is already
	                               on its way out. The cell cleans normally.
]]
function TrashCollectionService.collectFromRake(player: Player, instance: Instance): (boolean, string)
	return attempt(player, instance, false, true)
end

----------------------------------------------------------------
-- BOOT
----------------------------------------------------------------
local function watchFolder(folder: Instance)
	for _, descendant in folder:GetDescendants() do
		register(descendant)
	end
	table.insert(connections, folder.DescendantAdded:Connect(register))
end

function TrashCollectionService.start()
	assert(RunService:IsServer(), "[TrashCollectionService] server-only")
	if started then
		return
	end
	started = true

	local existing = ServerStorage:FindFirstChild(HIDDEN_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		hiddenFolder = existing
	else
		hiddenFolder = Instance.new("Folder")
		hiddenFolder.Name = HIDDEN_FOLDER_NAME
		hiddenFolder.Parent = ServerStorage
	end

	local folder = WeightConfig.trashFolder()
	if not folder and WeightConfig.CreateTrashFolder then
		local created = Instance.new("Folder")
		created.Name = WeightConfig.TrashFolderName
		created.Parent = workspace
		folder = created
	end

	-- Anything tagged in the place file, anywhere.
	for _, instance in CollectionService:GetTagged(TAG) do
		register(instance)
	end
	table.insert(connections, CollectionService:GetInstanceAddedSignal(TAG):Connect(register))

	if folder then
		watchFolder(folder)
	end
	-- Someone deletes and re-makes the Trash folder mid-session.
	table.insert(connections, workspace.ChildAdded:Connect(function(child)
		if child.Name == WeightConfig.TrashFolderName and child:IsA("Folder") then
			watchFolder(child)
		end
	end))

	table.insert(connections, WeightNet.get("CollectRequest").OnServerEvent:Connect(function(player, payload)
		if not allowRequest(player) then
			-- Answered, not dropped. A silent drop leaves the client's in-flight
			-- lock set for the whole ClientRequestTimeout, so one throttled fire
			-- stops that player collecting ANYTHING for a second -- a far worse
			-- outcome for an honest hiccup than for the spam this gate aims at.
			-- "Unavailable" is a reason the client stays deliberately quiet about.
			respond(player, false, "Unavailable", nil)
			return
		end

		-- A list from auto-collect, or a single instance from a manual pick, the
		-- prompt path or an older client. Both still work.
		if typeof(payload) == "Instance" then
			TrashCollectionService.collect(player, payload)
			return
		end
		if type(payload) ~= "table" then
			return
		end
		-- Counts every entry visited rather than only the ones that turn out to
		-- be instances, so a table full of junk cannot make this loop run long.
		local seen = 0
		for _, instance in payload do
			seen += 1
			if seen > WeightConfig.MaxAutoBatch then
				break
			end
			if typeof(instance) == "Instance" then
				-- Isolated. One item throwing inside the collect path must not take
				-- the rest of the batch down with it: before batching that cost you
				-- a single pickup, now it would cost every item queued behind it.
				local ok, err = pcall(TrashCollectionService.collect, player, instance)
				if not ok then
					warn("[TrashCollectionService] collect failed: " .. tostring(err))
				end
			end
		end
	end))

	table.insert(connections, Players.PlayerRemoving:Connect(function(player)
		buckets[player] = nil
	end))
end

function TrashCollectionService.stop()
	for _, conn in connections do
		conn:Disconnect()
	end
	table.clear(connections)
	for instance in registry do
		unregister(instance)
	end
	table.clear(buckets)
	started = false
end

-- Useful from the command bar: TrashCollectionService.count() -> live pickups
function TrashCollectionService.count(): number
	local n = 0
	for _ in registry do
		n += 1
	end
	return n
end

return TrashCollectionService
