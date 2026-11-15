--[[
	AtvServer  --  ServerScriptService.AtvServer

	Owns the car spawner: who owns which machine, taking the money, putting one
	on the pad, driving it, and the net that makes it worth owning.

	TWO KINDS OF MACHINE, ONE PIPELINE
	----------------------------------
	Tier 3 is a bulldozer and tier 4 a sweeper truck. Everything about buying,
	owning, spawning, recovering and putting away is identical for both -- the
	only places the difference shows are two tables keyed on the tier's `kind`:
	BUILDERS, which picks who makes the model, and PROFILES, which picks how it
	moves. Adding a third machine is an entry in each.

	SECURITY SHAPE
	--------------
	The client sends a TIER NUMBER and nothing else -- never a price, never a
	stat, never a spawn position. Every number is re-read from AtvConfig here,
	the balance is checked here, and coins move through SellServer.addCoins,
	which is the one grant path in the game. There is no payload to tamper with.

	DRIVING
	-------
	One `Chassis` part is the whole physics body and everything else is welded
	to it. Motion is a LinearVelocity limited to the X/Z axes -- so gravity is
	still doing its job and the machine falls and settles on terrain normally --
	plus an AlignOrientation holding it level and pointing where the player
	steers. Real wheel physics on an imported shell flips it into the sea the
	first time it clips a dune; this cannot flip, and on a beach that matters
	more than simulation does.

	Network ownership goes to the rider, so their own input is not a round trip.
	Throttle and Steer come off the VehicleSeat, which replicates them to us for
	free, and the constraint values are written from here.

	THE NET
	-------
	Riding sets the NetRadius player attribute. The WeightSystem reads it on
	both sides -- the client widens its pickup sweep to match, and the server
	widens the range it will accept a pickup from -- so the net is a real reach
	and not a client-side claim. It is cleared the moment they get off.

	THE HOLD
	--------
	Every machine carries its own cargo box, owned by ServerScriptService.
	VehicleHold. While you are sitting in one the net fills THE MACHINE, not the
	bag on your back; you then unload it into your bag a bagful at a time and
	walk that to the scales. This module's part in that is small and all in one
	place: open a hold when a machine is built, close it when the machine goes,
	and hang the Unload prompt on it.

	A LOADED MACHINE IS NOT PUT AWAY. The idle despawn below would otherwise
	quietly bin four hundred pounds of somebody's afternoon for the crime of
	standing still, so it waits until the hold is empty.

	THAT IS A RULE ABOUT THE IDLE SWEEP, NOT ABOUT EVERY despawn, and it is worth
	being exact because the sentence above used to read as though it were.
	`despawn` itself never moves cargo anywhere: VehicleHold.close just drops the
	record, so every caller has to decide this question for itself.

	THREE OF THEM HAVE DECIDED TO EMPTY THE HOLD FIRST: the ownership watcher
	(the tier can be lowered by an admin write outside any wipe -- see its note),
	PUT AWAY, and the replace-your-own despawn inside spawn(). The last two are
	new as of 2026-09-09 and this paragraph used to defend the opposite -- "the
	player's own button, so the loss is at least theirs to make" -- which is a
	defence of a button labelled PUT AWAY quietly binning four hundred pounds,
	and of a SPAWN press doing the same with no button that even claimed to. Both
	go through unloadBeforeDespawn now, which refuses to put the machine away at
	all when the bag cannot take what is in it.

	THE PATHS THAT STILL END THE RIDE WHATEVER IS IN THE BOX are the ones with
	nobody left to hand the cargo to: leaving, the model vanishing, and going
	overboard with no pad to be returned to. Anything new that calls despawn has
	to decide this question for itself.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AtvConfig = require(ReplicatedStorage:WaitForChild("AtvConfig"))
local WeightConfig = require(ReplicatedStorage:WaitForChild("WeightSystem"):WaitForChild("WeightConfig"))
local AtvBuilder = require(script.Parent:WaitForChild("AtvBuilder"))
local DozerBuilder = require(script.Parent:WaitForChild("DozerBuilder"))
local VehicleHold = require(script.Parent:WaitForChild("VehicleHold"))
local SellServer = require(script.Parent:WaitForChild("SellServer"))
local GamePassService = require(script.Parent:WaitForChild("GamePassService"))
local CollisionGroups = require(script.Parent:WaitForChild("CollisionGroups"))

local AtvServer = {}

----------------------------------------------------------------
-- THE TWO KINDS
----------------------------------------------------------------
local BUILDERS = {
	dozer = DozerBuilder.build,
	sweeper = AtvBuilder.build,
}

--[[
	DRIVE PROFILES  --  what makes a tracked machine feel tracked.

	Both kinds run the same two constraints, a LinearVelocity on X/Z and an
	AlignOrientation holding them level. The difference is entirely these
	numbers and one of them in particular:

		spool     how fast it reaches the speed you asked for. The truck is near
		          instant; nine tons is not, and a dozer that leapt to 100
		          studs/s would be a wheeled machine with a blade painted on.
		brake     the same, coming down. Deliberately quicker than spool but
		          still slower than the truck's -- it takes a moment to stop.
		steerRate how fast the steering reaches the lock you asked for, same
		          shape as spool and for the same reason. See the ramp in drive().
		reverse   share of top speed available backwards.
		bite      FLOOR under steering authority at a standstill, 0..1.

		          This is the whole difference between the two vehicles. The
		          truck steers by pointing its front wheels, so at 0 studs/s it
		          has no steering at all and its bite rises with speed -- without
		          that a parked truck pirouettes. Tracks steer by driving one side
		          and braking the other, which works just as well stopped, so the
		          dozer's floor is 1: it turns on the spot, and that is the
		          single most recognisable thing a tracked machine does.

		torque    AlignOrientation strength. Scaled to what it is turning.

	`sweeper` WAS CALLED `quad` until the quad and the pickup left the shop: all
	three wheeled machines shared it, so it was always the WHEELED profile rather
	than any one machine's. Renamed rather than left behind as a fallback,
	because a profile named after a vehicle that no longer exists is exactly what
	the next tidy-up deletes -- taking the truck's handling with it.
]]
local PROFILES = {
	dozer = { spool = 1.15, brake = 2.1, reverse = 0.62, bite = 1, torque = 4500000, steerRate = 8 },
	sweeper = { spool = 3.2, brake = 3.2, reverse = 0.45, bite = 0, torque = 700000, steerRate = 14 },
}

-- Blade animation, in the blade joint's own frame. Small on purpose: the ram
-- arms holding the blade are welded to the chassis and do not move with it, so
-- anything bigger than this swings the blade out of the arms that are
-- supposed to be carrying it.
local BLADE_LIFT = 0.55        -- studs the blade rides up when it is not working
local BLADE_PITCH = -0.10      -- radians it tips forward into the sand when it is

-- Below this the wheels are treated as stopped. Without it a machine parked on
-- a slope creeps at a hundredth of a stud a second and its tyres turn forever.
local WHEEL_DEADBAND = 0.4

-- Pounds the scoop carries before it tips into the cargo box. See the hold's
-- open() call in spawn() for why it is a fixed scoopful and not a share.
local SCOOP_LOAD = 12

local function builderFor(tier)
	return BUILDERS[AtvConfig.kindOf(tier)] or AtvBuilder.build
end

local function profileFor(tier)
	return PROFILES[AtvConfig.kindOf(tier)] or PROFILES.sweeper
end

local REMOTE_FOLDER = "AtvRemotes"
local EVENTS = { "AtvMenu", "AtvBuy", "AtvSpawn", "AtvStore", "AtvResult" }

local DESPAWN_AFTER = 45      -- seconds parked and empty before it is put away

-- The beach ends, and 80 studs/s crosses it in about three seconds. Measured:
-- holding forward from the pad puts the quad in open sea, sinking, well before
-- a player would think to turn. Anything below this is fished out and put back
-- on the pad rather than left at the bottom of the map with the rider aboard.
local RECOVER_BELOW_Y = 0
local RECOVER_COOLDOWN = 2

local remotes
local active = {}             -- [Player] = { model, seat, chassis, tier, linear, align, yaw, emptySince }
local connections = {}
--[[
	ONE PER PLAYER, AND SEPARATE FROM `connections`, for the reason despawn()
	gives about ride watchers: `connections` is boot-time wiring that is never
	emptied, so a per-player signal parked in it would leak one live handler per
	join for the life of the server.
]]
local tierWatchers = {}       -- [Player] = RBXScriptConnection
local started = false

----------------------------------------------------------------
-- REMOTES
----------------------------------------------------------------
local function ensureRemotes()
	local folder = ReplicatedStorage:FindFirstChild(REMOTE_FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = REMOTE_FOLDER
		folder.Parent = ReplicatedStorage
	end
	for _, name in EVENTS do
		if not folder:FindFirstChild(name) then
			local ev = Instance.new("RemoteEvent")
			ev.Name = name
			ev.Parent = folder
		end
	end
	return folder
end

--[[
	One toast on the player's screen, and optionally a purchase dialog behind it.

	`promptPass` IS A GAME PASS ID THE CLIENT SHOULD OFFER TO SELL. It exists
	because PromptGamePassPurchase is a CLIENT call -- there is no server-side
	way to open a purchase dialog on somebody's screen -- so the most the server
	can do is name the pass at the moment it refuses somebody and let AtvClient
	check whether it is actually on sale and put it up.

	Nothing is BOUGHT on the strength of this. GamePassService still hears about
	the result from PromptGamePassPurchaseFinished and goes and asks Roblox,
	rather than taking anyone's word for it.
]]
local function tell(player: Player, ok: boolean, message: string, promptPass: number?)
	remotes.AtvResult:FireClient(player, { ok = ok, message = message, promptPass = promptPass })
end

-- What the player calls the thing they are riding. Every message below used to
-- say "ATV", which was true of the wheeled machines the shop used to carry and
-- was never true of the bulldozer -- "Fished your ATV out of the sea" over a
-- bulldozer reads as a message meant for something else.
local function rideName(player: Player): string
	local ride = active[player]
	return (ride and ride.tier and ride.tier.name) or "Vehicle"
end

----------------------------------------------------------------
-- SHOWROOM PREVIEWS
----------------------------------------------------------------
--[[
	One inert copy of each machine in ReplicatedStorage, for the spawner panel to
	clone into its ViewportFrames and turn on a plinth.

	BUILT BY AtvBuilder, not modelled again in the UI. The panel shows the actual
	machine that drives out onto the pad, so repainting a tier or moving its rack
	changes the showroom with no second edit -- the same contract SignKit has with
	the boards and the wash viewmodel has with the tool.

	Built on the SERVER because AtvBuilder lives in ServerScriptService and a
	LocalScript cannot reach it. One model per tier, once, at boot; they
	replicate to everyone and cost nothing after that.

	INERT. Anchored (nothing to simulate), CanCollide/CanQuery/CanTouch off, and
	the VehicleSeat swapped for a plain Part -- a VehicleSeat cloned into a
	WorldModel is a seat the client's camera code can notice, and none of it is
	needed to look at.
]]
local PREVIEW_FOLDER = "AtvPreviews"
local SHOWROOM_FOLDER = "VehicleShowroom"

--[[
	Strip a freshly built machine down to something that only has to be LOOKED
	at. Shared by the panel's previews and by the stock standing on the pad,
	because "inert" means the same thing in both places and drifting apart would
	mean one of them quietly keeping a live seat or a running emitter.

	`collide` is the one real difference. A preview lives in a ViewportFrame
	where collision is meaningless; a machine parked on the pad is something a
	player can walk into, and one they can walk THROUGH reads as a hologram.

	CanQuery stays off either way. These are scenery, and scenery that answers
	raycasts is scenery that turns up in somebody else's ground probe.
]]
local function makeInert(model: Model, collide: boolean)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = collide
			d.CanQuery = false
			d.CanTouch = false
		elseif d:IsA("Sound") or d:IsA("ParticleEmitter") then
			d:Destroy()
		end
	end
	-- The seat, replaced in place so whatever was welded to it still is.
	local seat = model:FindFirstChildWhichIsA("VehicleSeat", true)
	if seat then
		local stand = Instance.new("Part")
		stand.Name = seat.Name
		stand.Size = seat.Size
		stand.CFrame = seat.CFrame
		stand.Color = seat.Color
		stand.Material = seat.Material
		stand.Anchored = true
		stand.CanCollide = false
		stand.CanQuery = false
		stand.CanTouch = false
		stand.Parent = model
		seat:Destroy()
	end
end

local function buildPreviews()
	local existing = ReplicatedStorage:FindFirstChild(PREVIEW_FOLDER)
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = PREVIEW_FOLDER

	for _, tier in AtvConfig.Tiers do
		local ok, model = pcall(builderFor(tier), tier, CFrame.new())
		if ok and model then
			model.Name = tier.key
			makeInert(model, false)
			model.Parent = folder
		else
			warn("[AtvServer] preview build failed for tier " .. tostring(tier.key) .. ": "
				.. tostring(model))
		end
	end

	folder.Parent = ReplicatedStorage
	return folder
end

----------------------------------------------------------------
-- OWNERSHIP
----------------------------------------------------------------
local function rebirthsOf(player: Player): number
	local n = player:GetAttribute("Rebirths")
	return (type(n) == "number") and math.max(0, math.floor(n)) or 0
end

local function ownedTierId(player: Player): number
	local n = player:GetAttribute(AtvConfig.OwnedAttribute)
	return (type(n) == "number") and math.max(0, math.floor(n)) or 0
end

----------------------------------------------------------------
-- DESPAWN
----------------------------------------------------------------
local function despawn(player: Player, reason: string?)
	local ride = active[player]
	if not ride then
		return
	end
	active[player] = nil

	-- The upgrade watchers, which belong to THIS ride and not to the module.
	-- The module-wide `connections` table is never emptied (it holds boot-time
	-- wiring that lives as long as the server), so per-ride signals must not go
	-- in it: a player who spawns and stores a machine forty times in a session
	-- would otherwise leave forty live handlers behind, every one of them still
	-- recomputing stats for a truck that no longer exists.
	if ride.watchers then
		for _, conn in ride.watchers do
			conn:Disconnect()
		end
	end

	VehicleHold.close(player)
	if ride.model and ride.model.Parent then
		ride.model:Destroy()
	end
	if player.Parent then
		player:SetAttribute(AtvConfig.NetRadiusAttribute, 0)
	end
	if reason and player.Parent then
		tell(player, true, reason)
	end
end

--[[
	A LOADED MACHINE IS EMPTIED INTO THE BAG BEFORE IT IS PUT AWAY -- 2026-09-09.

	Closes the bug where PUT AWAY, and the replace-your-own despawn inside
	spawn(), destroyed a full hold without a word. `despawn` moves no cargo:
	VehicleHold.close simply drops the record, so several hundred pounds of
	somebody's afternoon went nowhere at all -- VehicleLoad and VehicleMax to
	zero, nothing in the bag, nothing in the till, and no warning either side of
	it. Pressing SPAWN again while a loaded machine was out did it too, which is
	worse: there was not even a button claiming to put anything away.

	IT UNLOADS FIRST AND REFUSES RATHER THAN DESTROYS. The hold goes into the bag
	through VehicleHold.unload -- the same door the F prompt uses, so the
	inventory and the ledger see an ordinary arrival -- and if the bag cannot take
	all of it the machine STAYS OUT and the player gets the unload prompt's own
	words back. A partial unload is kept and is not a failure: what fitted is in
	the bag, the rest is still in the box, and the machine is still standing there
	to press again after the scales.

	THE POST-CHECK IS isEmpty AND NOT `moved > 0`, because unload is partial by
	design. Moving four items of six and then despawning would still bin the other
	two -- quieter than the old bug and no less a robbery.

	TWO CASES MUST NOT BLOCK, or a player could be locked out of their own pad
	forever: no ride record at all (there is nothing to put away, and despawn is
	a no-op anyway), and a hold whose model has already gone -- unload's
	"NoVehicle" -- whose cargo is unreachable by anybody from that moment on.

	Returns true when it is safe to despawn.
]]
local function unloadBeforeDespawn(player: Player): boolean
	if not active[player] or VehicleHold.isEmpty(player) then
		return true
	end
	local moved, movedWeight, _remaining, reason = VehicleHold.unload(player)
	if VehicleHold.isEmpty(player) or reason == "NoVehicle" then
		if moved > 0 then
			tell(player, true, string.format("Unloaded %s %s into your bag.",
				WeightConfig.format(movedWeight), WeightConfig.Unit))
		end
		return true
	end
	tell(player, false, WeightConfig.Messages.BagFullToUnload)
	return false
end

--[[
	A MACHINE YOU NO LONGER OWN DOES NOT STAY UNDER YOU.

	Since the tide wipes `AtvTier` for anyone without the matching game pass
	(ProgressionServer.onRebirth), a player can stop owning the thing they are
	sitting in while they are sitting in it. Nothing else would have noticed:
	`active` is the ride record and no part of the drive loop re-checks
	ownership, so the truck would have kept driving, kept collecting into its
	hold and kept its net radius published -- a vehicle that survived the wipe in
	everything but the shop panel's opinion of it.

	WRITTEN AGAINST THE ATTRIBUTE RATHER THAN AGAINST REBIRTH, deliberately. The
	invariant worth enforcing is "you are riding something you own", not "a
	rebirth just happened" -- so a refund, an admin correction (FeedbackServer
	writes this attribute) or any later way of losing a machine is covered by the
	same line, and this file needs to know nothing about tides.

	It only ever fires on a DROP: `>=` leaves a player who just bought a bigger
	machine, or a pass holder whose floor was re-raised, exactly where they are.

	THE HOLD IS EMPTIED INTO THE BAG FIRST, because `despawn` does not do it.
	despawn -> VehicleHold.close simply drops the hold record; nothing is moved
	and nothing is paid, which is the "quietly bin four hundred pounds of
	somebody's afternoon" this file's header forbids. On the REBIRTH path that
	loss would at least be consistent (onRebirth empties the bag too, and the
	cargo was earned under the old tide) -- but this watcher is deliberately
	bound to the attribute rather than to rebirth, and the OTHER writer is
	FeedbackServer's admin `vehicle` giver, which can write a tier DOWN during no
	tide at all. Unloading first costs nothing on the rebirth path and is the
	difference between a correction and a robbery on the admin one.

	THE MESSAGE DOES NOT NAME THE TIDE, for the same reason. It said "The tide
	took it", which is a lie on every path this watcher exists to cover except
	one.
]]
local function watchOwnership(player: Player)
	if tierWatchers[player] then
		tierWatchers[player]:Disconnect()
	end
	tierWatchers[player] = player:GetAttributeChangedSignal(AtvConfig.OwnedAttribute)
		:Connect(function()
			local ride = active[player]
			if not (ride and ride.tier and ownedTierId(player) < ride.tier.id) then
				return
			end
			-- Best effort: whatever will not fit in the bag is lost either way, and
			-- the machine is going regardless of what unload reports.
			if not VehicleHold.isEmpty(player) then
				pcall(VehicleHold.unload, player)
			end
			despawn(player, string.format(
				"The %s is no longer yours \u{2014} buy another at the pad.", ride.tier.name))
		end)
end

----------------------------------------------------------------
-- SPAWNING
----------------------------------------------------------------
--[[
	WHICH PAD, now that there is more than one.

	This was `GetTagged(...)[1]` when the beach had the only vehicle pad in the
	world. Sakura Cove has one too -- its kagura-den, outside the shrine's outer
	torii -- and CollectionService's order is not the player's: taking the first
	tagged model would have spawned every cove player's quad on the beach, 1500
	studs away, at a pad they cannot see.

	So it is the NEAREST pad to whoever is asking. With no player to measure from
	-- the recovery sweep can run for a rider whose character has gone -- it falls
	back to the first, which is the old behaviour and is fine: there is nothing
	better to say.
]]
local function spawnerModel(player: Player?)
	local pads = CollectionService:GetTagged(AtvConfig.SpawnerTag)
	if #pads <= 1 then
		return pads[1]
	end

	local char = player and player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return pads[1]
	end

	local best, bestD = pads[1], math.huge
	for _, pad in pads do
		local ok, pivot = pcall(function()
			return pad:GetPivot()
		end)
		if ok then
			local d = (pivot.Position - hrp.Position).Magnitude
			if d < bestD then
				best, bestD = pad, d
			end
		end
	end
	return best
end

--[[
	HOW FAR OUT OF THE YARD IS "GONE".

	A machine is drawn only for its own driver until it has been driven clear of
	the pad it spawned on (see the reveal block in the Heartbeat, and
	AtvConfig.ConcealedAttribute for why), and this is the number that decides
	when that is.

	MEASURED OFF THE PAD RATHER THAN TYPED, because the pads are not the same
	size. The beach showroom is 54 studs across with stock parked at either end;
	the three island pads are 17. One fixed figure would either be halfway across
	the showroom or two pad-widths past the end of a cove pad.

	So it is the pad's own half-width plus a margin about the length of the thing
	leaving it -- a Tidebreaker is thirty studs long, and it has to be OFF the
	yard rather than merely have its nose over the line. That comes out at 45
	studs at the beach and the 32 stud floor at the islands.
]]
local REVEAL_MARGIN = 18
local REVEAL_MIN = 32

local function revealDistanceFor(pad: Model?): number
	if not pad then
		return REVEAL_MIN
	end
	-- pcall'd for the same reason spawnerModel's GetPivot is: these throw on a
	-- model with no parts in it, and a pad mid-rebuild is one.
	local ok, size = pcall(function()
		return pad:GetExtentsSize()
	end)
	if not ok or typeof(size) ~= "Vector3" then
		return REVEAL_MIN
	end
	return math.max(REVEAL_MIN, math.max(size.X, size.Z) * 0.5 + REVEAL_MARGIN)
end

--[[
	Where a machine is delivered, the middle of the yard it is delivered into,
	and how far from that middle counts as having left.

	All three together, off ONE lookup, because spawnerModel picks the pad
	NEAREST the player -- ask it again a few steps later and it can honestly
	answer with a different pad, which would move the finish line under a machine
	that is already driving away from the first one.
]]
local function spawnPlacement(player: Player?): (CFrame?, Vector3?, number)
	local pad = spawnerModel(player)
	local point = pad and pad:FindFirstChild("SpawnPoint")
	if not (point and point:IsA("BasePart")) then
		return nil, nil, REVEAL_MIN
	end
	local ok, pivot = pcall(function()
		return pad:GetPivot()
	end)
	return point.CFrame, (ok and pivot.Position) or point.Position, revealDistanceFor(pad)
end

local function spawnPointCFrame(player: Player?): CFrame?
	local cf = spawnPlacement(player)
	return cf
end

----------------------------------------------------------------
-- YOUR UPGRADES, ON THE MACHINE
----------------------------------------------------------------
--[[
	Recompute this ride's effective stats and push them everywhere they are read.

	Called once at spawn and again on every change to a track the transfer reads
	-- so a level bought while the engine is running takes effect on the next
	frame rather than the next spawn. That matters more than it sounds: a loaded
	machine is deliberately never auto-despawned, so a player who buys Bucket
	Size mid-run might not respawn their truck for the rest of the session.

	FIVE PLACES HAVE TO AGREE, and this is the only function that writes any of
	them:

		ride.stats             what drive() steers and accelerates with
		model NetRadius attr   DriveHud's marker and dashboard reading
		player NetRadius attr  WeightConfig.reachFor, on BOTH sides -- so the
		                       client's pickup sweep and the server's range gate
		                       widen together and cannot disagree
		the hold's capacity    VehicleHold, which owns the cargo box
		model SweepWidth attr  the band CTB_Server combs -- AND the rake drawn
		                       across the machine's nose, which is one operation
		                       and not two. See the block itself.

	The Beach Rake is why the watcher list is not just the Transfers pair any
	more: AtvConfig.transferAttributes() returns the car ladder's attributes too,
	so a rung bought from the driving seat lands on the machine on the next
	frame without this file having to know that ladder exists.

	The player attribute is written only while its OWNER is in the seat, which is
	the rule NetRadius has always had: somebody else hopping into your truck gets
	a ride, not a twenty-stud vacuum cleaner.
]]
local function applyStats(player: Player)
	local ride = active[player]
	if not ride then
		return nil
	end

	local stats = AtvConfig.effectiveStats(player, ride.tier)
	ride.stats = stats

	if ride.model and ride.model.Parent then
		ride.model:SetAttribute("NetRadius", stats.netRadius)

		--[[
			THE RAKE, AND THE ONE RULE IT HAS TO KEEP.

			SweepWidth is the band CTB_Server combs and it reads it straight off
			this model, so publishing a wider number here is the whole of making a
			Beach Rake work -- CTB_Server needs no change at all. It is also, on
			its own, exactly the bug that file and CTB_Client have each already
			paid for once: sand clearing in a strip wider than anything on screen.

			So the publish and the draw are ONE operation and must stay adjacent.
			They take the same local, and fitRake refuses anything at or under the
			built blade rather than drawing a rake hidden inside it.

			STAMPED ON THE MACHINE, NOT ON THE PLAYER -- deliberately, in the way
			NetRadius below is deliberately the other way round. A net is a REACH
			and belongs to the person, which is why a hitchhiker does not get one.
			A rake is bolted to the truck: it is visibly there whoever is in the
			seat, and a band that stopped matching the bar the moment somebody else
			drove would be the invisible-width bug wearing a different hat.
		]]
		local built = ride.builtSweep or 0
		local fitted = stats.sweepWidth
		local sweep = math.max(built, (type(fitted) == "number" and fitted) or 0)
		if sweep > 0 then
			ride.model:SetAttribute("SweepWidth", sweep)
		end
		-- Rebuilt only when the width actually moved. applyStats fires on every
		-- watched track, so a Bucket Size purchase would otherwise tear down and
		-- re-weld fifty parts on the nose of a moving truck for nothing.
		if ride.rakeWidth ~= sweep then
			ride.rakeWidth = sweep
			AtvBuilder.fitRake(ride.model, built, fitted, {
				bar = ride.tier and ride.tier.netColour,
				trim = ride.tier and ride.tier.accent,
			})
		end
	end

	local seat = ride.seat
	local occupant = seat and seat.Parent and seat.Occupant
	local rider = occupant and Players:GetPlayerFromCharacter(occupant.Parent)
	if rider == player then
		player:SetAttribute(AtvConfig.NetRadiusAttribute, stats.netRadius)
	end

	VehicleHold.setCapacity(player, stats.hold)
	return stats
end

local function drive(ride, dt: number)
	local seat, chassis = ride.seat, ride.chassis
	if not (seat and seat.Parent and chassis and chassis.Parent) then
		return
	end

	-- THE EFFECTIVE STATS, not the tier's own.
	--
	-- `ride.stats` is max(machine, player's upgrade tracks) -- see
	-- AtvConfig.effectiveStats -- and applyStats() recomputes it whenever a
	-- level changes. Reading tier.speed / tier.turn here instead is what made
	-- every level of Beach Legs worthless the moment the player got in.
	--
	-- Falls back to the tier for a ride recorded before applyStats ran, so a
	-- machine is never motionless because a stat table was missing.
	local stats = ride.stats or ride.tier
	local profile = ride.profile
	local throttle = math.clamp(seat.Throttle, -1, 1)
	local steer = math.clamp(seat.Steer, -1, 1)

	-- Nobody aboard: coast to a stop rather than holding the last velocity.
	if not seat.Occupant then
		throttle, steer = 0, 0
	end

	-- Reverse is deliberately slower than forward, the way anything with a
	-- reverse gear is -- and it stops the machine being driven backwards at
	-- full tilt to dodge the net being on the front.
	local target = stats.speed * throttle * (throttle < 0 and profile.reverse or 1)
	-- Asking for less than you have is braking, and braking is not the same
	-- curve as pulling away -- least of all on something this heavy.
	local rate = (math.abs(target) > math.abs(ride.speed)) and profile.spool or profile.brake
	ride.speed += (target - ride.speed) * math.min(dt * rate, 1)

	-- Steering authority: whatever speed has earned, or the machine's floor,
	-- whichever is greater. Tracks have a floor of 1 and turn on the spot; the
	-- wheeled truck has none and cannot.
	local rolling = math.clamp(math.abs(ride.speed) / (stats.speed * 0.45), 0, 1)
	local bite = math.max(profile.bite, rolling)
	--[[
		MINUS, and this sign is worth being careful about because it is easy to
		talk yourself out of.

		A rotation of +theta about Y sends the +Z axis toward +X. The nose is +Z
		-- but a rider facing world +Z has their RIGHT hand toward world -X, not
		+X. So +theta swings the nose to the rider's LEFT, and a right turn is a
		yaw that FALLS.

		This was briefly flipped to += on the theory that +X is "the machine's
		right", which is the mistake above written down. Measured with a rider
		actually in the seat and real keys: at += , holding D swung the nose
		-1.00 against the rider's own RightVector. Dead backwards. The original
		sign was correct and only the drive axis below was ever wrong.

		If you ever need to re-check this, measure against the seated character's
		RightVector -- never against a world axis you have reasoned about.
	]]
	--[[
		THE STEERING RAMPS, AND UNTIL 2026-09-12 IT WAS THE ONLY INPUT THAT DID NOT.

		Reported as "the Sandhog turns too much". The value it turns at is NOT the
		problem and was deliberately left alone -- 2.6 rad/s is the one number the
		dozer beats the truck on and AtvConfig calls skid steer "this machine's
		whole character" three separate times. Dropping it would answer the report
		by deleting the machine's reason to exist.

		What was actually wrong is the asymmetry a few lines up. THROTTLE is eased
		-- `spool` coming up, `brake` coming down, on the stated grounds that "nine
		tons is not [instant]" -- and steering was applied RAW off the seat. On a
		keyboard seat.Steer is -1, 0 or +1 with nothing in between, so a tap went
		straight to full lock and released to dead centre. At a bite of 1 (tracks
		steer just as well stopped) that is 149 degrees a second arriving in one
		frame: a quarter-second tap swung the nose about 30 degrees.

		The PEAK IS UNCHANGED, which is the point. Hold the key and the machine
		still reaches 2.6 rad/s in about a third of a second and sustains it, so a
		committed turn feels exactly as it did and the stat on the shop card is
		still honest. Only the first moment changes, and the first moment is the
		whole complaint.

		THE TRUCK IS ON 14, which is near enough instant -- it eases in about two
		tenths. Nobody reported the Tidebreaker and it steers by pointing its front
		wheels rather than by braking a track, so it has no reason to feel heavy.
		It takes the field only because a profile that answers this question for
		one machine and not the other is a nil the next tier would find.

		Eases BOTH ways: letting go straightens out over the same ramp rather than
		stopping the yaw dead, which is the other half of how a heavy machine
		ought to feel.
	]]
	ride.steer += (steer - ride.steer) * math.min(dt * (profile.steerRate or 14), 1)
	ride.yaw -= ride.steer * stats.turn * bite * dt * (ride.speed < 0 and -1 or 1)

	ride.align.CFrame = CFrame.Angles(0, ride.yaw, 0)
	--[[
		THE NOSE IS +Z, AND CFrame.LookVector IS NOT IT.

		Roblox's LookVector is a CFrame's NEGATIVE Z axis. Every vehicle in this
		game is built the other way round -- AtvBuilder puts the net, the brush
		guard and the headlights at POSITIVE z and marks the +z pair as the
		steering wheels, DozerBuilder puts the blade there, and
		CarSpawnerBuilder's SpawnPoint is documented as facing +Z out toward the
		beach so that "a car placed on it is already pointing down the drive".

		Driving on LookVector therefore pushed every machine out through its own
		back end. Measured on a Tidebreaker: hold W and it travels at -1.00 dot
		with the direction its net points -- exactly backwards, with the scoop
		that is the whole reason to own the thing trailing behind it.

		ZVector is the +Z axis, which is the nose. It reads oddly next to
		LookVector and it is the correct one. The steering sign above is NOT part
		of this fix and must not be moved with it -- see the note there.
	]]
	ride.linear.VectorVelocity = chassis.CFrame.ZVector * ride.speed

	----------------------------------------------------------------
	-- THE WHEELS
	----------------------------------------------------------------
	--[[
		Rolled off DISTANCE TRAVELLED, not off a fixed rate: turns = distance /
		circumference, so a stationary machine's wheels are still, reverse turns
		them backwards, and a quad's small tyres spin visibly faster than a
		lorry's at the same road speed. Anything else reads as a toy with a motor
		in it rather than a vehicle rolling.

		The sign: a wheel's contact patch moves BACKWARD along the machine as it
		drives forward, and rotating +theta about the joint's X axis sends a
		point below the axle toward -Z. Forward is +Z, so forward is +theta.
	]]
	if ride.wheels then
		if math.abs(ride.speed) > WHEEL_DEADBAND then
			ride.spin += (ride.speed * dt) / ride.wheelRadius
			-- Wrapped, so a long session cannot walk this into the range where a
			-- float stops having fractions of a radian left.
			ride.spin %= math.pi * 2
			local turn = CFrame.Angles(ride.spin, 0, 0)
			for _, w in ride.wheels do
				w.motor.C0 = w.rest * turn
			end
		end
	end

	----------------------------------------------------------------
	-- THE BLADE, AND WHAT IT KICKS UP
	----------------------------------------------------------------
	-- Down and biting only when the machine is actually pushing forward under
	-- power. Reversing or coasting lifts it, which is what a dozer does and
	-- also what stops it ploughing the beach backwards.
	--
	-- Eased rather than snapped: a blade that changed height in one frame is a
	-- prop being teleported, and the ease is two lines.
	if ride.bladeMotor and ride.bladeMotor.Parent then
		local working = (throttle > 0.05 and ride.speed > 2) and 1 or 0
		ride.blade += (working - ride.blade) * math.min(dt * 4.5, 1)
		ride.bladeMotor.C0 = ride.bladeRest
			* CFrame.new(0, BLADE_LIFT * (1 - ride.blade), 0)
			* CFrame.Angles(BLADE_PITCH * ride.blade, 0, 0)
	end

	-- Emitters are toggled on the CROSSING, never written per frame. Rate and
	-- Enabled are replicated properties, and three of them rewritten every
	-- Heartbeat per dozer is a stream of network traffic that says nothing the
	-- previous frame did not.
	if ride.spray then
		local on = throttle > 0.05 and ride.speed > 6
		if ride.sprayOn ~= on then
			ride.sprayOn = on
			for _, e in ride.spray do
				e.Enabled = on
			end
		end
	end
	if ride.dust then
		local on = math.abs(ride.speed) > 8
		if ride.dustOn ~= on then
			ride.dustOn = on
			for _, e in ride.dust do
				e.Enabled = on
			end
		end
	end
end

function AtvServer.spawn(player: Player, tierId: number)
	local tier = AtvConfig.tier(tierId)
	if not tier then
		return
	end
	if ownedTierId(player) < tier.id then
		tell(player, false, "You do not own that one.")
		return
	end

	local cf, padCentre, revealAt = spawnPlacement(player)
	if not cf then
		tell(player, false, "The spawner pad is missing.")
		return
	end

	--[[
		A BUSY PAD NEVER REFUSES ANYBODY, AND THAT IS A CHANGE.

		There was a clear-radius check here: somebody else's chassis within eight
		studs of the delivery point and you were told "Something is already on the
		pad." It existed to stop two machines being posted into the same cubic
		metre.

		IT COULD BE HELD INDEFINITELY, AND THAT IS WHY IT IS GONE. A machine is
		only put away once it has been parked AND EMPTY for DESPAWN_AFTER seconds
		-- putting a loaded one away destroys the load, which is a robbery rather
		than a tidy-up -- so one player who wanders off with cargo in the bed locks
		that pad for everybody else for as long as they stay logged in. There are
		four pads on the map. That is a shop somebody can close by going AFK.

		TWO THINGS ALREADY DO THE JOB THE CHECK WAS DOING:

		  COLLISION. Every spawned machine goes into the Vehicles group and
		  Vehicles x Vehicles is off (see CollisionGroups), so two of them in one
		  place interpenetrate quietly. There is nothing to launch.

		  CONCEALMENT. A machine is drawn only for its own owner until it has been
		  driven clear of the yard, so two players delivering into the same bay
		  each see exactly ONE machine -- their own. The overlap the check existed
		  to prevent is not on anybody's screen.

		Replacing your OWN is still fine and expected, and that is what the
		despawn below is: one machine per player, as it has always been.

		AND IT EMPTIES THE OLD ONE INTO THE BAG FIRST -- 2026-09-09. This line used
		to destroy a loaded hold exactly as PUT AWAY did, so a player who pressed
		SPAWN with four hundred pounds in the bed lost it to a button that says
		nothing about putting anything away. If the bag will not take the cargo the
		old machine stays where it is and nothing is built here. See
		unloadBeforeDespawn.
	]]
	if not unloadBeforeDespawn(player) then
		return
	end
	despawn(player)

	-- pcall'd because a builder can legitimately refuse: DozerBuilder asserts
	-- when its shell is not in the place, and that should reach the player as a
	-- refusal rather than as a server error and a prompt that does nothing.
	local built, model = pcall(builderFor(tier), tier, cf)
	if not (built and typeof(model) == "Instance") then
		warn("[AtvServer] build failed for tier " .. tostring(tier.key) .. ": " .. tostring(model))
		tell(player, false, string.format("The %s failed to build.", tier.name))
		return
	end

	--[[
		WHOSE IT IS, AND THAT NOBODY ELSE MAY LOOK AT IT YET -- STAMPED BEFORE IT
		IS PARENTED, AND THAT ORDER IS THE WHOLE TRICK.

		A machine is delivered ONTO THE PAD, in the middle of a showroom other
		people are standing in, and three of them arriving at once is three
		trucks posted through each other in front of an audience. So everybody
		except the owner draws it invisible until it has been driven clear --
		see AtvConfig.ConcealedAttribute and StarterPlayerScripts.VehicleVeil.

		A subtree replicates when it is PARENTED, tags and attributes and all.
		Stamp these afterwards instead and the model reaches every client for a
		moment with no owner and no concealment on it -- which is precisely the
		one frame of thirty-stud truck appearing out of nowhere that this exists
		to remove.
	]]
	model:SetAttribute(AtvConfig.OwnerAttribute, player.UserId)
	model:SetAttribute(AtvConfig.ConcealedAttribute, true)
	CollectionService:AddTag(model, AtvConfig.VehicleTag)

	model.Parent = workspace

	--[[
		INTO THE VEHICLE GROUP, so it passes through players and through other
		machines. Done HERE rather than in either builder: DozerBuilder and
		AtvBuilder both feed this one function, and the showroom stock comes out
		of those same builders and is deliberately left solid (see makeInert).
		This is the line that separates a machine somebody drives from one that is
		standing on a plinth to be looked at.

		The connection it returns is not kept -- despawn destroys the model, and
		that severs it.
	]]
	CollisionGroups.apply(model, CollisionGroups.Vehicle)

	-- Anything below that throws would otherwise leave a machine standing in the
	-- world with no ride record behind it: undrivable, no net, and not cleaned
	-- up by despawn because despawn does not know about it. Guarded so the
	-- model goes with the failure.
	local wired = false
	task.defer(function()
		if not wired and model.Parent then
			model:Destroy()
		end
	end)

	local chassis = model.PrimaryPart
	--[[
		BY CLASS, NOT BY NAME.

		An imported shell is free to contain a part called Seat, and the tipper's
		cab has two modelled cushions called exactly that. A name lookup found
		one of those, saw it was not a VehicleSeat, and refused to spawn a
		machine that had been built perfectly well -- "The Tidebreaker 900
		failed to build", with nothing wrong in the builder at all.

		The shells are sanitised on import too (anything called Seat, Chassis,
		Net* or Fill is renamed Shell_*), but this is the check that cannot be
		tripped by the next model somebody drops in.
	]]
	local seat = model:FindFirstChildWhichIsA("VehicleSeat")
	if not (chassis and seat) then
		model:Destroy()
		tell(player, false, string.format("The %s failed to build.", tier.name))
		return
	end

	local profile = profileFor(tier)

	-- max(what the machine is, what this player has bought). Computed before the
	-- ride record so the hold can be opened at the right size on the first frame
	-- rather than being resized a moment later -- a cargo box that visibly grows
	-- the instant you spawn it reads as a glitch, not as a reward.
	local stats = AtvConfig.effectiveStats(player, tier)

	local attachment = Instance.new("Attachment")
	attachment.Name = "DriveAttachment"
	attachment.Parent = chassis

	-- X and Z only. Y is left to gravity, so the machine drops onto the sand and
	-- rides terrain instead of flying at a fixed height.
	local linear = Instance.new("LinearVelocity")
	linear.Attachment0 = attachment
	linear.RelativeTo = Enum.ActuatorRelativeTo.World
	linear.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	-- ForceLimitMode MUST be PerAxis. It defaults to Magnitude, and in that
	-- mode MaxAxesForce is ignored entirely in favour of MaxForce -- which
	-- defaults to 1000, against an assembly that masses ~310. The machine would
	-- have crawled, and the Y-axis exemption that leaves gravity alone would
	-- not have applied at all.
	linear.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	linear.MaxAxesForce = Vector3.new(1e6, 0, 1e6)
	linear.VectorVelocity = Vector3.zero
	linear.Parent = chassis

	local align = Instance.new("AlignOrientation")
	align.Attachment0 = attachment
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.RigidityEnabled = false
	align.MaxTorque = profile.torque
	align.Responsiveness = 40
	align.CFrame = CFrame.Angles(0, 0, 0)
	align.Parent = chassis

	local _, startYaw = cf:ToOrientation()

	-- Whatever this machine happens to carry. All optional -- the blade is the
	-- dozer's alone -- and drive() skips every block whose handle is nil rather
	-- than each kind needing its own drive function.
	local bladeMotor = chassis:FindFirstChild("BladeMotor")
	-- Every wheel's joint plus the pose it was built at. Cached here rather than
	-- re-read per frame: drive() writes these forty times a second.
	local wheels = {}
	for _, d in chassis:GetChildren() do
		if d:IsA("Motor6D") and d.Name == "WheelMotor" then
			table.insert(wheels, { motor = d, rest = d.C0 })
		end
	end
	local spray, dust, fill, scoop = {}, {}, {}, {}
	for _, d in model:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			if d.Name == "BladeSpray" then
				table.insert(spray, d)
			elseif d.Name == "TrackDust" then
				table.insert(dust, d)
			end
		elseif d:IsA("BasePart") then
			if d.Name == "Fill" then
				table.insert(fill, d)
			elseif d.Name == "ScoopFill" then
				table.insert(scoop, d)
			end
		end
	end
	-- Bottom of the box first. GetDescendants is in creation order today and
	-- that is not a promise, so the order the load appears in is carried on the
	-- parts themselves rather than assumed.
	local function byIndex(a, b)
		return (a:GetAttribute("FillIndex") or 0) < (b:GetAttribute("FillIndex") or 0)
	end
	table.sort(fill, byIndex)
	table.sort(scoop, byIndex)

	active[player] = {
		model = model,
		chassis = chassis,
		seat = seat,
		tier = tier,
		stats = stats,
		profile = profile,
		--[[
			THE BLADE THIS MACHINE WAS BUILT WITH, captured BEFORE anything can
			overwrite it.

			applyStats republishes SweepWidth whenever a Beach Rake level changes,
			and it publishes max(built, fitted) -- so it has to still know what
			"built" was. Read it back off the model instead and the first rake
			fitted becomes the new floor, and the next one after that, ratcheting a
			number that is meant to be a fixed property of the machine's geometry.

			Off the MODEL rather than off the tier, because that is where it is
			measured: the builders derive it from what they actually built (a mesh
			blade's Size.X, a drawn scoop mouth). There is no such field on a tier
			and deliberately never was -- see AtvBuilder's note.
		]]
		builtSweep = tonumber(model:GetAttribute("SweepWidth")) or 0,
		-- The yard this one was delivered into and how far out of it counts as
		-- gone. Captured rather than re-measured every tick, for the reason
		-- spawnPlacement gives: the nearest pad is not a constant.
		padCentre = padCentre,
		revealAt = revealAt,
		concealed = true,
		linear = linear,
		align = align,
		yaw = startYaw,
		speed = 0,
		-- Where the steering actually is, as opposed to where the seat is asking
		-- for it to be. See the ramp in drive().
		steer = 0,
		emptySince = os.clock(),

		bladeMotor = bladeMotor,
		-- The rest pose, read once. Every frame after this is one multiply off a
		-- known-good joint rather than a joint re-solved from world positions
		-- that are themselves moving.
		bladeRest = bladeMotor and bladeMotor.C0 or nil,
		blade = 0,
		wheels = (#wheels > 0) and wheels or nil,
		wheelRadius = math.max(0.5, model:GetAttribute("WheelRadius") or 1),
		spin = 0,
		spray = (#spray > 0) and spray or nil,
		dust = (#dust > 0) and dust or nil,
	}
	align.CFrame = CFrame.Angles(0, startYaw, 0)

	------------------------------------------------------------------
	-- THE HOLD, AND THE WAY OUT OF IT
	------------------------------------------------------------------
	-- On the chassis, which is invisible but is the middle of the machine --
	-- so the prompt is reachable from any side of a twenty stud truck. Line of
	-- sight is off for the same reason: the box you are emptying is frequently
	-- between you and the middle of the thing holding it.
	--[[
		E TO GET IN.

		The seat's own CanTouch is off (see AtvBuilder), so walking into a parked
		machine no longer teleports you into the driving seat -- which is Roblox's
		default and is a nuisance around something thirty studs long that you are
		trying to walk past. This prompt is the only way in.

		On the SEAT rather than the chassis, so the E appears where the door is.
	]]
	local enter = Instance.new("ProximityPrompt")
	enter.Name = "EnterPrompt"
	enter.ActionText = "Drive"
	-- WHOSE IT IS, ON THE PROMPT ITSELF. Only the owner can get in (see the
	-- Triggered handler), and a prompt that says "Drive" and then refuses is a
	-- prompt that reads as broken. Saying it in the label turns the refusal into
	-- something the player already knew before they pressed anything.
	enter.ObjectText = string.format("%s's %s", player.DisplayName, tier.name)
	enter.KeyboardKeyCode = Enum.KeyCode.E
	enter.HoldDuration = 0
	enter.MaxActivationDistance = 12
	enter.RequiresLineOfSight = false
	--[[
		ALWAYS SHOWN, because the default OnePerButton produced a DEADLOCK.

		A machine spawns 6.6 studs from the pad's own anchor, and OnePerButton
		shows only the NEAREST prompt on a given key -- so with the pad's prompt
		also on a key, standing at a freshly spawned machine could hide this one
		entirely. Measured: E did nothing beside a newly spawned truck, and
		worked perfectly twenty studs away, before this was set.

		THIS ALONE DOES NOT STOP THE PAD'S PROMPT FROM ALSO FIRING. AlwaysShow
		only exempts THIS prompt from being hidden by exclusivity -- it does
		nothing to the OTHER prompt, which stays visible and triggerable on its
		own terms. The two used to share E, and a single press near a parked
		machine fired BOTH: sat the driver down AND popped the showroom open.
		The pad's prompt is on a different key now (see bindPad) specifically so
		the two can never both answer the same keypress, which is the only fix
		that does not depend on distances or exclusivity rules. AlwaysShow stays
		set for the OTHER E prompts a machine can end up parked beside -- the
		Sandbot dock among them -- so Drive is never the one that loses a
		OnePerButton contest.
	]]
	enter.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	enter.Parent = seat

	--[[
		YOUR OWN MACHINE, AND ONLY YOURS.

		Anybody in range used to be able to press E and drive off in somebody
		else's truck. The notes further down still talk about a passenger getting
		"a ride, not a twenty-stud vacuum cleaner", and that WAS the shape of
		this: the net and the cargo box were the owner's, but the wheels were
		anyone's -- which is a stolen car with the boot locked.

		What a refused player is told depends on what they have got, because the
		two cases want opposite things said:

		  THEY OWN A MACHINE  they already know how this works and are simply
		                      standing at the wrong one. Point them at the pad.
		  THEY OWN NOTHING    this is somebody meeting vehicles by walking into
		                      one, which is the best moment there will ever be to
		                      offer them this one. The tier's pass id rides along
		                      with the refusal and AtvClient puts the dialog up if
		                      the pass is actually on sale.
	]]
	connections[#connections + 1] = enter.Triggered:Connect(function(who)
		if seat.Occupant then
			return
		end
		if who ~= player then
			if AtvConfig.ownsMachine(who) then
				tell(who, false, string.format(
					"That is not your %s \u{2014} spawn your own at the pad.", tier.name))
			else
				tell(who, false, string.format("That %s belongs to %s.",
					tier.name, player.DisplayName), AtvConfig.passOf(tier))
			end
			return
		end
		local char = who.Character
		local humanoid = char and char:FindFirstChildWhichIsA("Humanoid")
		if humanoid and humanoid.Health > 0 then
			seat:Sit(humanoid)
		end
	end)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "UnloadPrompt"
	prompt.ActionText = "Unload"
	prompt.ObjectText = tier.name
	--[[
		F, NOT E, AND THAT IS NOT A PREFERENCE.

		ProximityPrompt.Exclusivity defaults to OnePerButton: only one prompt per
		KEY is shown at a time within range. Enter and Unload are both on the
		same machine and both apply at the same moment -- standing beside a
		parked truck with cargo in it -- so on the same key one of them silently
		wins and the other never fires. Measured: pressing E next to a loaded
		machine did nothing at all, because Unload had taken the button and was
		not itself eligible.

		Two keys, two prompts, no contest. E gets you in, F empties the box.
	]]
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 18
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false          -- nothing in it yet; the hold turns it on
	prompt.Parent = chassis

	VehicleHold.open(player, {
		model = model,
		seat = seat,
		prompt = prompt,
		fill = fill,
		--[[
			THE SCOOP IS A CONTAINER, NOT DECORATION.

			Litter piles up in the net or against the blade first, and tips into
			the box behind when it is full -- so the part of the machine the
			driver is looking at is the part that reacts to a pickup. Before
			this the scoop never changed and the load appeared in a bed behind
			the cab, which is why collecting read as teleporting.

			SCOOP_LOAD is deliberately flat across the shop rather than a share
			of the hold. It is a scoopful -- five or six pieces of litter -- and
			tying it to capacity would have the big truck tip twice a run.
		]]
		scoop = (#scoop > 0) and scoop or nil,
		scoopCapacity = SCOOP_LOAD,
		name = tier.name,
		-- The BETTER of the machine's bed and the player's own bag. Past Bucket
		-- Size 37 a Sandhog carries more than 300 lbs, and past 45 a Tidebreaker
		-- carries more than 650 -- see AtvConfig.effectiveStats.
		capacity = stats.hold,
	})

	connections[#connections + 1] = prompt.Triggered:Connect(function(who)
		-- Your own machine only. Emptying somebody else's truck into your bag is
		-- not a feature, and the hold is keyed to its owner anyway.
		if who ~= player then
			tell(who, false, "That is not your machine.")
			return
		end
		local moved, movedWeight, remaining, reason = VehicleHold.unload(player)
		if moved > 0 then
			local left = (remaining > 0)
				and string.format(" %s %s still aboard.", WeightConfig.format(
					(VehicleHold.snapshot(player) or {}).load or 0), WeightConfig.Unit)
				or ""
			tell(player, true, string.format("Unloaded %s %s from the %s.%s",
				WeightConfig.format(movedWeight), WeightConfig.Unit, tier.name, left))
		elseif reason == "HoldEmpty" then
			tell(player, false, WeightConfig.Messages.HoldEmpty)
		else
			tell(player, false, WeightConfig.Messages.BagFullToUnload)
		end
	end)

	wired = true

	-- The rider owns the physics, so their steering is not a round trip.
	pcall(function()
		chassis:SetNetworkOwner(player)
	end)

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local ride = active[player]
		if not ride then
			return
		end
		local occupant = seat.Occupant
		if occupant then
			local rider = Players:GetPlayerFromCharacter(occupant.Parent)
			--[[
				THE BACKSTOP BEHIND THE ENTER PROMPT.

				The prompt above already refuses anybody but the owner, and the
				seat's own CanTouch is off (see AtvBuilder), so there is no way
				into this seat that this branch can currently see. That is exactly
				why it is here: a VehicleSeat is one Sit() call away from being
				taken, and the next thing that seats somebody -- a cutscene, a
				ferry, a tutorial nudge -- would otherwise quietly hand them the
				keys. Standing them back up costs one property write and this
				never fires in normal play.

				Setting Sit false re-enters this handler with no occupant, and
				THAT pass is what clears the net and puts the Drive prompt back --
				so there is nothing to undo here before returning.
			]]
			if rider and rider ~= player then
				occupant.Sit = false
				if AtvConfig.ownsMachine(rider) then
					tell(rider, false, string.format(
						"That is not your %s \u{2014} spawn your own at the pad.", tier.name))
				else
					tell(rider, false, string.format("That %s belongs to %s.",
						tier.name, player.DisplayName), AtvConfig.passOf(tier))
				end
				return
			end
			-- The net is the owner's. Nobody ELSE can be in this seat any more
			-- (see above), so what this now guards is a rider whose Player has
			-- already gone: GetPlayerFromCharacter answers nil mid-leave.
			if rider == player then
				-- This ride's own net, which is all of it. It used to be worth
				-- saying EFFECTIVE here: reach transferred from the Beachcomber
				-- Reach track, so a well-levelled walker climbing in would have
				-- shrunk to the machine's number. That track was removed and
				-- netRadius came off AtvConfig.Transfers with it rather than be
				-- left as a branch reading an attribute nothing writes, so the
				-- net is the tier's again. Falls back to the tier if stats
				-- somehow never landed.
				player:SetAttribute(AtvConfig.NetRadiusAttribute,
					(ride.stats or ride.tier).netRadius)
			end
			ride.emptySince = nil
		else
			player:SetAttribute(AtvConfig.NetRadiusAttribute, 0)
			ride.emptySince = os.clock()
		end
		-- No "Drive" offered on a seat that already has somebody in it.
		if enter.Parent then
			enter.Enabled = occupant == nil
		end
		-- The hold's capacity is published only while its owner is aboard, and
		-- that pair of attributes is what WeightConfig.freeFor reads to decide
		-- which container a pickup is measured against. So this call is not
		-- bookkeeping -- it is the switch between filling the machine and
		-- filling your own bag.
		VehicleHold.publish(player, VehicleHold.parked(player))
	end)

	------------------------------------------------------------------
	-- KEEPING THE MACHINE IN STEP WITH THE SHOP
	------------------------------------------------------------------
	-- One watcher per transferable track. Rebirth rewrites all of them, so a
	-- tide that resets Bucket Size to level 1 correctly hands the truck its own
	-- 650 lb bed back rather than leaving it on a bag capacity that is gone.
	local watchers = {}
	for _, attribute in AtvConfig.transferAttributes() do
		table.insert(watchers, player:GetAttributeChangedSignal(attribute):Connect(function()
			applyStats(player)
		end))
	end
	active[player].watchers = watchers
	-- Once now, which is also what normalises the NetRadius the builders stamped
	-- straight off the tier a moment ago.
	applyStats(player)

	-- Both numbers, and the unload said out loud. A machine that quietly filled
	-- its own box and then refused to let the player sell would be a bug report,
	-- not a feature -- the one thing they have to be told is that the cargo is
	-- in the truck and comes out at the truck.
	--
	-- The EFFECTIVE numbers, and it says so when they are yours: being told
	-- "650 lb hold" while standing next to a machine your own Bucket Size has
	-- taken well past that is the feature failing to land even though it
	-- worked. Speed and hold are the only two that can be yours -- the net is
	-- the tier's, so there is nothing to boast about there.
	local boosted = stats.upgraded.speed or stats.upgraded.hold
	-- The rake gets said out loud on its own rather than folded into `boosted`,
	-- because it is not the same news. Speed and hold being yours means a track
	-- you already had happens to have overtaken the machine; a rake is a thing
	-- bought FOR the machine at end-game prices, and its width is what was paid
	-- for. Measured against the built blade so it is silent on a bare machine.
	local fitted = stats.sweepWidth
	local rake = (type(fitted) == "number" and fitted > (active[player].builtSweep or 0))
		and string.format(" %d stud rake.", math.floor(fitted + 0.5)) or ""
	tell(player, true, string.format(
		"%s ready \u{2014} %d stud net, %d lb hold.%s%s E to drive, F at the machine to unload.",
		tier.name, math.floor(stats.netRadius + 0.5), math.floor(stats.hold + 0.5),
		rake, boosted and " Fitted to your own gear." or ""))
end

----------------------------------------------------------------
-- BUYING
----------------------------------------------------------------
function AtvServer.buy(player: Player, tierId: number)
	local tier = AtvConfig.tier(tierId)
	if not tier then
		return
	end
	if ownedTierId(player) >= tier.id then
		tell(player, false, "You already own that one.")
		return
	end

	local coins = SellServer.getCoins(player)
	local blocked = AtvConfig.blockedReason(player, tier, coins, rebirthsOf(player))
	if blocked then
		tell(player, false, blocked)
		return
	end

	-- Through the one grant path, so lifetime earnings and every other hook
	-- hanging off it see the spend.
	SellServer.addCoins(player, -tier.price, "car")
	player:SetAttribute(AtvConfig.OwnedAttribute, tier.id)
	tell(player, true, string.format("Bought the %s!", tier.name))

	AtvServer.spawn(player, tier.id)
end

----------------------------------------------------------------
-- BOOT
----------------------------------------------------------------
--[[
	Stand one machine on every DisplayPoint a showroom pad carries.

	WHY THE SHOP IS A PLACE AND NOT JUST A MENU. Somebody who owns nothing used
	to walk up to an empty rectangle with CAR SPAWN written over it, and had to
	press E to find out there was anything for sale at all. Now the stock is
	standing on it -- a bulldozer and thirty studs of dump truck, full size, in
	the paint they really spawn in -- and the prompt is what you press once you
	have already decided you want one.

	BUILT BY THE REAL BUILDERS, like the panel's previews and for the same
	reason: repaint a tier or move its rack and the showroom follows with no
	second edit. What stands here IS what drives off the pad.

	PARENTED TO A FOLDER IN WORKSPACE, NOT INTO THE PAD, and that is not tidiness
	-- ServiceClearance sizes its apron off the pad model's bounding box, and a
	thirteen stud machine dropped inside that model would move the box's floor
	and quietly shift the clearance zone for a building that had not changed.

	Rebuilt from scratch each boot rather than saved into the place: these are
	derived scenery, and a copy in the file would be a second one to keep in step.
]]
--[[
	THE STOCK SELLS ITS OWN PASS  --  one prompt per machine on the plinth.

	Walk up to the bulldozer and you are offered the BULLDOZER's game pass; walk
	up to the truck and you are offered the TRUCK's. That is the one thing the
	pad's own panel cannot do -- a panel is a list, and a list has no idea which
	machine you were standing in front of when you opened it.

	G, AND THE KEY IS THE LOAD-BEARING DECISION HERE. Three prompts already
	overlap on this pad: E seats the driver (the Enter prompt in spawn(), reach
	12), R opens this showroom (bindPad, reach 20 across a 53 stud frontage) and
	F empties the hold -- and a machine delivered into the middle bay stands 17
	studs from either display, inside all of them. Exclusivity does NOT rescue a
	shared key: AlwaysShow only exempts a prompt from being HIDDEN and does
	nothing to stop the OTHER one firing, which is exactly how a single press of
	E used to both sit the driver down and pop this shop open on top of them. A
	key nothing else in the game binds is the only thing that cannot regress.
	Measured across every script in the place rather than assumed: E, F, R, B,
	Space, Backspace and Q are all spoken for somewhere (Q is the wash bay's way
	out), and G is not.

	NOTHING IS SOLD ON THIS SIDE, AND THERE IS NO `Triggered` HANDLER AT ALL.
	PromptGamePassPurchase is a CLIENT call -- there is no server-side way to
	open a purchase dialog on somebody's screen -- so AtvClient finds this prompt
	by tag and puts the dialog up itself, exactly as the panel's own Robux
	buttons do. It is not a hole: GamePassService still hears the outcome on
	PromptGamePassPurchaseFinished and goes and asks Roblox rather than believing
	anybody.

	WHAT IT SAYS IS PAINTED BY THE CLIENT, for the one reason a label can only be
	painted there: a ProximityPrompt is ONE instance seen by everyone, the price
	is the same for everybody but OWNERSHIP is not, and there is nothing left to
	sell somebody who already holds the pass. What is set below is the honest
	un-painted state -- the machine's name, no figure -- so a prompt seen in the
	moment before the client's first sweep is right, just quieter.

	SEVEN STUDS UP, NEVER ON THE FLOOR. ShrineBuilder and MagmaBuilder both
	record a prompt at ground level that never rendered at all -- PromptShown did
	not fire from five studs away with line of sight off and nothing competing --
	and the identical thing a few studs higher showed instantly. The cause is
	still unknown, so the rule stands as a rule. Seven also lays the label across
	the machine's own flank (both are about 13 studs tall) rather than floating it
	over the roof, and it keeps the range almost entirely horizontal: distance to
	an attachment is measured in three dimensions, so height spent here is reach
	spent too.

	REACH IS OFF THE MACHINE'S OWN BOX, because a Tidebreaker is 32 studs long
	and a fixed radius measured from its middle would be out of range at its own
	nose. Half the longer side plus ten covers walking up to any face of it --
	22.5 for the Sandhog and 26.2 for the Tidebreaker, off their built bounding
	boxes. The default OnePerButton exclusivity settles the rest: the two plinths
	stand 34 studs apart, so wherever the ranges overlap the NEAREST machine wins
	the key, which is precisely "the one you walked up to".
]]
local PASS_PROMPT_LIFT = 7      -- studs above the machine's own floor
local PASS_PROMPT_MARGIN = 10   -- studs of reach past the end of the machine

local function standPassPrompt(model: Model, tier)
	-- A machine with no pass gets no prompt. There is nothing to sell, and a
	-- prompt with nothing behind it is the button CarSpawnerBuilder's header
	-- refuses to draw for the same reason.
	local passId = AtvConfig.passOf(tier)
	local chassis = model.PrimaryPart
	if not (passId and chassis) then
		return
	end

	local box, size = model:GetBoundingBox()
	-- ON AN ATTACHMENT, not on a part of the machine: the chassis sits wherever
	-- its rig put it (mid-body on one, over the tracks on the other) and the
	-- prompt has to be a known height above the SAND whatever that is. The box's
	-- own floor is that reference, and it costs nothing to ask.
	local anchor = Instance.new("Attachment")
	anchor.Name = "PassPromptAnchor"
	anchor.Parent = chassis
	anchor.WorldPosition = Vector3.new(box.Position.X,
		box.Position.Y - size.Y * 0.5 + PASS_PROMPT_LIFT, box.Position.Z)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PassPrompt"
	prompt.ActionText = "Unlock"
	prompt.ObjectText = tier.name
	prompt.KeyboardKeyCode = Enum.KeyCode.G
	-- OFF ButtonX, which every other prompt in the place leaves on the default.
	-- On a controller OnePerButton would otherwise hide this behind whichever of
	-- the pad's prompt or the machine's happened to be nearer, and a pass that
	-- can only be bought with a keyboard is a pass a good share of players cannot
	-- buy at all.
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonY
	prompt.HoldDuration = 0
	-- The stock is CanQuery = false all over (see makeInert), so a sight test
	-- would pass straight through the machine anyway -- but the pad's kerbs and
	-- the bollards at its mouth are real, and a price tag that blinks out when
	-- you walk round the back of the truck is a price tag nobody finds.
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = math.max(size.X, size.Z) * 0.5 + PASS_PROMPT_MARGIN
	prompt:SetAttribute(AtvConfig.PassPromptTierAttribute, tier.id)
	prompt.Parent = anchor

	CollectionService:AddTag(prompt, AtvConfig.PassPromptTag)
end

local function dressShowroom(pad: Model)
	local points = {}
	for _, d in pad:GetDescendants() do
		if d:IsA("BasePart") and d.Name == "DisplayPoint" then
			table.insert(points, d)
		end
	end
	if #points == 0 then
		return
	end

	local root = workspace:FindFirstChild(SHOWROOM_FOLDER)
	if not root then
		root = Instance.new("Folder")
		root.Name = SHOWROOM_FOLDER
		root.Parent = workspace
	end

	for _, point in points do
		local tier = AtvConfig.tier(point:GetAttribute("Tier"))
		if tier then
			local name = pad.Name .. "_" .. tier.key
			local existing = root:FindFirstChild(name)
			if existing then
				existing:Destroy()
			end
			-- The point's own CFrame, so the stock inherits the pad's facing and
			-- stands nose-out down the drive like something just parked there.
			local ok, model = pcall(builderFor(tier), tier, point.CFrame)
			if ok and model then
				model.Name = name
				makeInert(model, true)
				-- After makeInert rather than before. The prompt hangs off an
				-- Attachment and would survive that sweep either way, but "finish
				-- the machine, then put a price on it" is the order that stays
				-- true if the sweep ever grows a case that walks children.
				standPassPrompt(model, tier)
				model.Parent = root
			else
				warn("[AtvServer] showroom build failed for " .. tostring(tier.key)
					.. ": " .. tostring(model))
			end
		end
	end
end

local function bindPad(pad: Model)
	-- The stock first, so a showroom pad is dressed even if it turns out to have
	-- no anchor to hang a prompt on.
	dressShowroom(pad)

	local anchor = pad:FindFirstChild("PromptAnchor") or pad:FindFirstChild("Pad")
	if not (anchor and anchor:IsA("BasePart")) then
		warn("[AtvServer] car spawner has no PromptAnchor")
		return
	end
	if anchor:FindFirstChildWhichIsA("ProximityPrompt") then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "AtvPrompt"
	prompt.ActionText = "Car Spawner"
	prompt.ObjectText = "Dozers & Trucks"
	--[[
		R, NOT E -- FIXED 2026-08-24, and this is the actual fix, not the
		distance tuning below it.

		A machine spawns 6.6 studs from this pad's own anchor, well inside both
		this prompt's reach and the Enter prompt's 12 (see spawn()), so a player
		sitting down was always inside both ranges at once. Putting Enter's
		Exclusivity on AlwaysShow stopped this prompt from HIDING it, but
		AlwaysShow does not stop the other prompt from ALSO firing -- so one
		press of E sat the driver down AND popped the showroom open on top of
		them. No radius split fixes that; the ranges overlap by design; the pad
		must cover a wide showroom while the door is right next to it. A second
		key is the only thing that guarantees the two can never both answer the
		same press, which is exactly the reason Unload sits on F rather than E
		-- see that prompt's own note in spawn().
	]]
	prompt.KeyboardKeyCode = Enum.KeyCode.R
	prompt.HoldDuration = 0
	--[[
		OFF THE PAD, because only the pad knows how wide it is.

		9 was measured against the 16 stud pad: far enough to cover it, close
		enough not to swallow the driver's door of a machine standing 6.6 studs
		away. That clash is a different key's problem now (see the note above),
		so this reach only has to cover the pad on its own terms. The beach pad
		is 53 studs across now with stock at either end, and at 9 a player walking
		up to the bulldozer would be stood in the shop with no way to open it.
		CarSpawnerBuilder stamps 20 there and 9 on the plain pads.
	]]
	prompt.MaxActivationDistance = tonumber(pad:GetAttribute("PromptReach")) or 9
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor

	connections[#connections + 1] = prompt.Triggered:Connect(function(player)
		remotes.AtvMenu:FireClient(player, {
			owned = ownedTierId(player),
			coins = SellServer.getCoins(player),
			rebirths = rebirthsOf(player),
			riding = active[player] ~= nil,
		})
	end)
end

function AtvServer.start()
	assert(RunService:IsServer(), "[AtvServer] server-only")
	if started then
		return
	end
	started = true

	remotes = ensureRemotes()
	buildPreviews()
	-- Before the pads bind, so a player who joins into a dressed showroom has
	-- their pass ownership resolved by the time they can press anything, and
	-- after ensureRemotes so AtvResult exists for it to announce a live purchase
	-- through.
	--
	-- SERVERMAIN STARTS IT FIRST NOW, so in practice this is a no-op -- start()
	-- is guarded. It moved because the passes are no longer all AtvConfig's:
	-- the wash bay sells one too, and a wash pass that only resolves if the car
	-- showroom got as far as step 9 is a wash pass that silently stops working
	-- the day this file throws. The call is kept because the ordering it states
	-- is still true of the showroom, and deleting it would invite it back.
	GamePassService.start()

	for _, pad in CollectionService:GetTagged(AtvConfig.SpawnerTag) do
		bindPad(pad)
	end
	connections[#connections + 1] =
		CollectionService:GetInstanceAddedSignal(AtvConfig.SpawnerTag):Connect(bindPad)

	connections[#connections + 1] = remotes.AtvBuy.OnServerEvent:Connect(function(player, tierId)
		if type(tierId) == "number" then
			AtvServer.buy(player, tierId)
		end
	end)
	connections[#connections + 1] = remotes.AtvSpawn.OnServerEvent:Connect(function(player, tierId)
		if type(tierId) == "number" then
			AtvServer.spawn(player, tierId)
		end
	end)
	connections[#connections + 1] = remotes.AtvStore.OnServerEvent:Connect(function(player)
		-- PUT AWAY EMPTIES THE BOX FIRST, and does not put the machine away at all
		-- if the bag cannot take what is in it -- 2026-09-09. It used to despawn
		-- unguarded, which binned a full hold in silence. See unloadBeforeDespawn.
		if not unloadBeforeDespawn(player) then
			return
		end
		-- Named before the despawn, which is what clears the record it reads.
		despawn(player, rideName(player) .. " put away.")
	end)

	connections[#connections + 1] = Players.PlayerAdded:Connect(function(player)
		if player:GetAttribute(AtvConfig.OwnedAttribute) == nil then
			player:SetAttribute(AtvConfig.OwnedAttribute, 0)
		end
		player:SetAttribute(AtvConfig.NetRadiusAttribute, 0)
		player:SetAttribute(AtvConfig.HoldLoadAttribute, 0)
		player:SetAttribute(AtvConfig.HoldMaxAttribute, 0)
		watchOwnership(player)
	end)
	for _, player in Players:GetPlayers() do
		if player:GetAttribute(AtvConfig.OwnedAttribute) == nil then
			player:SetAttribute(AtvConfig.OwnedAttribute, 0)
		end
		player:SetAttribute(AtvConfig.NetRadiusAttribute, 0)
		player:SetAttribute(AtvConfig.HoldLoadAttribute, 0)
		player:SetAttribute(AtvConfig.HoldMaxAttribute, 0)
		watchOwnership(player)
	end
	connections[#connections + 1] = Players.PlayerRemoving:Connect(function(player)
		despawn(player)
		if tierWatchers[player] then
			tierWatchers[player]:Disconnect()
			tierWatchers[player] = nil
		end
	end)

	connections[#connections + 1] = RunService.Heartbeat:Connect(function(dt)
		for player, ride in active do
			if not (ride.model and ride.model.Parent) then
				despawn(player)
				continue
			end
			-- Off the edge and sinking: put it back before the rider drowns with it.
			local y = ride.chassis.Position.Y
			if y < RECOVER_BELOW_Y and os.clock() - (ride.lastRecover or 0) > RECOVER_COOLDOWN then
				ride.lastRecover = os.clock()
				local cf = spawnPointCFrame(player)
				if cf then
					ride.speed = 0
					ride.linear.VectorVelocity = Vector3.zero
					ride.chassis.AssemblyLinearVelocity = Vector3.zero
					ride.model:PivotTo(cf)
					tell(player, false, string.format("Fished your %s out of the sea.", ride.tier.name))
				else
					despawn(player, string.format("%s lost overboard.", ride.tier.name))
				end
				continue
			end

			drive(ride, dt)

			--[[
				OUT OF THE YARD, AND NOW EVERYBODY CAN SEE IT.

				LATCHED, DELIBERATELY. A machine driven back onto the pad stays
				visible. Re-concealing on the way in would make a parked truck
				blink out from under the people standing beside it -- a worse
				picture than the one this fixes -- and it would do it every time
				somebody reversed a stud too far.

				FLAT DISTANCE. The beach pad sits at the bottom of a slope and
				Ashfall's is on a shelf; counting the climb would let a machine
				that has gone nowhere qualify by driving uphill.
			]]
			if ride.concealed then
				local centre = ride.padCentre
				local reveal = (centre == nil)
				if centre then
					local at = ride.chassis.Position
					local dx, dz = at.X - centre.X, at.Z - centre.Z
					local far = ride.revealAt or REVEAL_MIN
					reveal = (dx * dx + dz * dz) >= far * far
				end
				if reveal then
					ride.concealed = false
					ride.model:SetAttribute(AtvConfig.ConcealedAttribute, false)
				end
			end

			-- Parked and empty for long enough: put it away rather than leaving
			-- abandoned machines littering the beach the player is here to clean.
			-- ...but never with cargo still in it. Putting a loaded machine away
			-- destroys the load, and "I parked up to go and sell and my four
			-- hundred pounds vanished" is not a tidy-up, it is a robbery.
			if ride.emptySince and os.clock() - ride.emptySince > DESPAWN_AFTER
				and VehicleHold.isEmpty(player) then
				despawn(player, string.format("%s returned to the pad.", ride.tier.name))
			end
		end
	end)
end

return AtvServer
