--[[
	PetServer  --  ServerScriptService.PetServer

	Owns every pet a player has, which five are out, what that is worth in
	luck, and the bodies following them around.

	TWO CEILINGS
	------------
	PetConfig.MaxEquipped (5) is how many can follow you. PetConfig.MaxOwned
	(250) is how many you may hold at all, and it is checked in `hatch` BEFORE
	the coins move -- a cap enforced after the charge is a station that takes
	fifty thousand and hands back nothing. `release` is the way back under it.

	A FULL BAG IS A REFUSAL THE EGG PANEL HAS TO NAME. `openMenu` sends `room`
	and EggClient draws off it -- and it used to fold that into the same boolean
	as the price and label both cases "CAN'T AFFORD", so a player at the ceiling
	with money in hand was told the wrong thing. The two are separate there now;
	the wording follows `hatch`'s own refusal below so one problem reads the same
	wherever the player meets it.

	SECURITY SHAPE  --  and why buying is not a remote
	--------------------------------------------------
	Hatching is driven by a ProximityPrompt whose Triggered event is connected
	HERE, on the server. That makes the trigger engine-validated: the player
	genuinely stands within MaxActivationDistance of the egg, with the engine's
	own rate limit on activation. A client cannot fire a prompt it is not
	standing at, cannot name a price, and cannot name a pet.

	This is the same shape SellServer and WashServer use, and it is strictly
	stronger than a "BuyEgg" RemoteEvent, which would have to be trusted about
	which station it was at. The remotes that DO exist run the other way:

		HatchEgg   S -> C   here is what you just won, play the sequence
		PetSync    S -> C   your collection, your five slots, what you have
		                    discovered, and your luck
		PetEquip   C -> S   an ACTION and at most a pet id -- never a slot, a
		                    count, a price or a luck value

	PetEquip is the one inbound message and it carries no numbers at all: the
	server looks up whether you own that pet, whether a slot is free, and
	recomputes the luck attribute itself. There is no field in the payload that
	could be inflated.

	PERSISTENCE SEAM
	----------------
	This game saves nothing (see the note at the bottom of ServerMain: coins,
	upgrades and carried items are all session-only). Pets follow the same
	convention rather than inventing a private DataStore:

		PetServer.OnPetsChanged = function(player, owned, equipped) ... end
		PetServer.restore(player, owned, equipped, discovered)

	`discovered` is worth saving separately from `owned`: it is what the Pet
	Index draws, and releasing a pet must not un-discover it.

	Wire those two to a save module and pets persist; leave them and a session
	is a session.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local PetConfig = require(Modules:WaitForChild("PetConfig"))
local PetVisuals = require(Modules:WaitForChild("PetVisuals"))
local Net = require(Modules:WaitForChild("Net"))
-- What Roblox Premium is worth here, which is a slice of luck and nothing else.
-- Replicated config over a property the client cannot forge; see its header for
-- why the perk is luck rather than coins.
local PremiumConfig = require(Modules:WaitForChild("PremiumConfig"))

local SellServer = require(script.Parent:WaitForChild("SellServer"))
local LuckService = require(script.Parent:WaitForChild("LuckService"))

local PetServer = {}

PetServer.TAG = "PetStation"

-- [Player] = { owned = {[petId] = count}, equipped = {petId, ...} }
local data = {}
-- [Player] = { [slotIndex] = { model, align, orient, root } }
local bodies = {}
-- [Player] = os.clock() of the last hatch, one anti-spam clock per player
local lastHatch = {}
-- [Player] = the lastHatch stamp we have ALREADY warned about, so somebody
-- mashing the buy button is told once per cooldown rather than once per tap.
-- Weak-keyed: a throttle note must not be the thing keeping a leaver alive.
local coolWarned: { [Player]: number } = setmetatable({}, { __mode = "k" })
-- [Player] = os.clock() of the last equip/release, throttling a remote that can
-- respawn five models per call.
local lastEquip = {}
local stations = {}   -- [Model] = station

local rng = Random.new()

PetServer.OnPetsChanged = nil

local HATCH_COOLDOWN = 1.25
local EQUIP_COOLDOWN = 0.15

--------------------------------------------------------------------------
-- SMALL HELPERS
--------------------------------------------------------------------------

local function notify(player: Player, text: string, kind: string?)
	Net.get("Notify"):FireClient(player, { text = text, kind = kind or "info" })
end

local function stateOf(player: Player)
	local d = data[player]
	if not d then
		-- `discovered` is deliberately separate from `owned`: it is what the Pet
		-- Index draws, and an index that forgets a pet the moment you release it
		-- is a collection log that punishes you for tidying up.
		--
		-- `locked` is petId -> true, and it is BY ID rather than per copy because
		-- this data model has no per-copy identity at all -- `owned` is a count,
		-- which is what makes trading arithmetic (see the note over canGive). So a
		-- lock protects every copy of that pet; a player trimming spares of
		-- something they have locked unlocks it first. That is the right way round:
		-- the cost of the coarse rule is one extra tap, and the thing it is
		-- defending against is unrecoverable.
		d = { owned = {}, equipped = {}, discovered = {}, locked = {} }
		data[player] = d
	end
	return d
end

local function countOwned(d): number
	local n = 0
	for _, c in d.owned do
		n += c
	end
	return n
end

--------------------------------------------------------------------------
-- LUCK
--------------------------------------------------------------------------
--[[
	The one writer of the PetLuck attribute. LuckService is the one reader, and
	it clamps whatever it finds -- so a bad value here can only ever be a
	smaller effect, never a larger one.
]]
--[[
	PREMIUM RIDES ON TOP, and it is added in BOTH places that produce this number
	-- here and in `snapshot` below -- for the reason RewardsServer's `scaled`
	note gives about its own figures: the panel advertising one number while the
	roll uses another is the same defect whichever way round it points. The pets
	panel reads snapshot.luck; LuckService reads this attribute; they have to be
	the same value.
]]
local function recomputeLuck(player: Player)
	local d = stateOf(player)
	local luck = PetConfig.luckOf(d.equipped) + PremiumConfig.luckBonusFor(player)
	player:SetAttribute(LuckService.ATTRIBUTE, luck)
	return luck
end

--------------------------------------------------------------------------
-- REPLICATION
--------------------------------------------------------------------------

local function snapshot(player: Player)
	local d = stateOf(player)
	local owned = {}
	for petId, count in d.owned do
		owned[petId] = count
	end
	local equipped = table.clone(d.equipped)
	local discovered = {}
	for petId in d.discovered do
		discovered[petId] = true
	end
	local locked = {}
	for petId in d.locked do
		locked[petId] = true
	end
	return {
		owned = owned,
		equipped = equipped,
		discovered = discovered,
		locked = locked,
		ownedCount = countOwned(d),
		-- With the Premium term, so the panel shows what the roll will use. See
		-- recomputeLuck.
		luck = PetConfig.luckOf(equipped) + PremiumConfig.luckBonusFor(player),
		maxEquipped = PetConfig.MaxEquipped,
		maxOwned = PetConfig.MaxOwned,
	}
end

local function push(player: Player)
	if not player.Parent then
		return
	end
	-- THE COUNT AS AN ATTRIBUTE, alongside the payload rather than instead of it.
	-- The panel reads the snapshot; TutorialHud (client, watches attributes) and
	-- FunnelServer (derives its steps from the server's own attributes) read this.
	-- Written HERE because `push` is the one place every ownership change already
	-- passes through -- grant, release, fuse, trade, restore and the join hook all
	-- end in it, so there is no path that moves a pet and misses this line.
	player:SetAttribute(PetConfig.OwnedAttribute, countOwned(stateOf(player)))
	Net.get("PetSync"):FireClient(player, snapshot(player))
	if PetServer.OnPetsChanged then
		-- Copies, for the reason in PetServer.get: a save module that keeps the
		-- table it was handed would be holding live server state.
		local d = stateOf(player)
		task.spawn(PetServer.OnPetsChanged, player,
			table.clone(d.owned), table.clone(d.equipped), table.clone(d.locked))
	end
end

--------------------------------------------------------------------------
-- ART
--------------------------------------------------------------------------
--[[
	Find a pet's model under ReplicatedStorage.Pets.<Tier>.

	Matched by SUFFIX rather than by exact name, so all of these resolve to the
	same pet and the setup script's naming does not have to be permanent:

		Pet_Common_01_PebblePup     (what the FBX import produces)
		PebblePup                   (hand-renamed)

	Returns nil when the art is missing, which is a supported state -- see
	buildPlaceholder. The pack is 60 models and this system has to work on the
	day 59 of them have imported.
]]
local function findArt(def)
	local root = ReplicatedStorage:FindFirstChild("Pets")
	local folder = root and root:FindFirstChild(def.Tier)
	if not folder then
		return nil
	end
	local exact = folder:FindFirstChild(def.ModelName) or folder:FindFirstChild(def.PetId)
	if exact then
		return exact
	end
	for _, child in folder:GetChildren() do
		if child.Name:sub(-#def.PetId) == def.PetId then
			return child
		end
	end
	return nil
end

-- A tinted lozenge in the pet's tier colour. Not a placeholder in the "fix
-- this later" sense: a player who owns a pet whose mesh failed to import still
-- sees something following them that is the right colour and the right size,
-- and it still grants the full luck.
local function buildPlaceholder(def): Model
	local model = Instance.new("Model")
	model.Name = def.PetId

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Shape = Enum.PartType.Block
	body.Size = Vector3.new(1.6, 1.4, 2.1)
	body.Color = PetConfig.tierColor(def.Tier)
	body.Material = Enum.Material.SmoothPlastic
	body.TopSurface = Enum.SurfaceType.Smooth
	body.BottomSurface = Enum.SurfaceType.Smooth
	body.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.2, 1.1, 1.1)
	head.Color = PetConfig.tierInfo(def.Tier).glow
	head.Material = Enum.Material.SmoothPlastic
	head.CFrame = body.CFrame * CFrame.new(0, 0.5, -1.2)
	head.Parent = model

	model.PrimaryPart = body
	return model
end

-- Every part welded to one root, weightless, and out of the player's way.
-- CanQuery = false matters as much as CanCollide: a pet bobbing at chest
-- height is exactly where a ProximityPrompt raycast goes, and three of them
-- following you would otherwise block the prompt on every station you walk up
-- to -- including the one that sold them to you.
local function prepare(model: Model, targetHeight: number): BasePart?
	local root = model.PrimaryPart
	if not root then
		root = model:FindFirstChildWhichIsA("BasePart", true)
		if not root then
			return nil
		end
		model.PrimaryPart = root
	end

	local _, size = model:GetBoundingBox()
	local tallest = math.max(size.X, size.Y, size.Z)
	if tallest > 0.05 then
		local factor = targetHeight / tallest
		-- ScaleTo is proportional and keeps the pivot, which is what we want:
		-- the imported pets have their origin at their own centre of mass.
		pcall(function()
			model:ScaleTo(factor)
		end)
	end

	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			d.CastShadow = false
			if d ~= root then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = root
				weld.Part1 = d
				weld.Parent = root
			end
		end
	end
	root.Massless = false  -- the assembly root carries the mass the movers act on
	return root
end

--------------------------------------------------------------------------
-- THE FOLLOW RIG
--------------------------------------------------------------------------
--[[
	AlignPosition/AlignOrientation in OneAttachment mode, with the goal written
	straight onto the mover every frame.

	The alternative -- a second anchored "goal" part per pet, moved each frame,
	with TwoAttachment movers pointed at it -- is three extra instances per pet
	and nine per player that all replicate. OneAttachment needs none of them:
	the goal is a property, and a property write is not an instance.

	Responsiveness is the whole point of using movers rather than CFraming the
	pet directly. A CFramed pet is glued to the player and reads as a decal; a
	sprung one lags into corners, overshoots when you stop, and settles -- which
	is what makes it read as a thing that is following you rather than attached.
]]
--[[
	Five, in a shallow V behind the player -- and NOTHING ON THE CENTRE LINE.

	WHY THAT RULE EXISTS. +Z in the character's own frame is BEHIND them
	(LookVector is -Z), and the follow camera is behind them too, about thirteen
	studs back. So a pet's local offset is not "where it walks", it is "where it
	sits between the player and their own camera", and the closer a slot is to
	x = 0 the nearer it sits to the middle of the screen.

	The old slot 3 was Vector3.new(0, 2.7, 6.0): dead on the centre line, six
	studs back, at head height -- roughly seven studs in front of the lens and
	squarely in the middle third of the frame. Its own comment said it was put
	there "further back and higher so it is not hidden between them", which
	solved the pet's visibility by spending the player's. Measured in play it
	covered the sifter on the beach and sat over the pedestal in the wash bay,
	which is the one place in the game that asks the player to aim.

	THE ARITHMETIC TO KEEP IF THESE ARE RETUNED. A slot's angle off screen
	centre is about atan(|x| / (13 - z)), against a half-FOV of 35 degrees. The
	centre third of the screen is the first ~12 degrees of that, so a slot wants
	to clear it:

		slots 1-2   atan(3.3 / 9.2) = 20 deg    the shoulders, and the two best
		                                        pets -- most visible, still clear
		slots 3-4   atan(6.1 / 6.6) = 43 deg    wide, near the frame edge
		slot 5      x = 0, but LIFTED to 4.8 -- it clears the centre VERTICALLY
		            instead, atan(2.8 / 4.4) = 32 deg above the axis, which is
		            the top of the frame rather than the middle of it

	Slot 5 is the one that keeps the arrangement looking like a V rather than
	two unrelated pairs, and it is the only one that can sit on x = 0 without
	costing anything -- pets already hover with a bob and a ring under them, so
	a higher one reads as flying rather than as floating by mistake.
]]
local SLOT_OFFSETS = {
	Vector3.new(-3.3, 2.0, 3.8),
	Vector3.new(3.3, 2.0, 3.8),
	Vector3.new(-6.1, 2.3, 6.4),
	Vector3.new(6.1, 2.3, 6.4),
	Vector3.new(0, 4.8, 8.6),
}

local function destroyBodies(player: Player)
	local set = bodies[player]
	if not set then
		return
	end
	for _, body in set do
		if body.model then
			body.model:Destroy()
		end
	end
	bodies[player] = nil
end

local function spawnBody(player: Player, petId: string, slot: number)
	local def = PetConfig.get(petId)
	if not def then
		return nil
	end

	local art = findArt(def)
	local model
	if art then
		model = art:Clone()
		-- A MeshPart exported on its own arrives as a bare part, not a Model.
		if not model:IsA("Model") then
			local wrapper = Instance.new("Model")
			wrapper.Name = def.PetId
			model.Parent = wrapper
			wrapper.PrimaryPart = model:IsA("BasePart") and model or nil
			model = wrapper
		end
	else
		model = buildPlaceholder(def)
	end
	model.Name = string.format("%s_%s", player.Name, def.PetId)

	local root = prepare(model, 2.6)
	if not root then
		model:Destroy()
		return nil
	end

	-- Colour, rarity aura, ring, light, trail. AFTER prepare, never before:
	-- every size in PetVisuals is measured off the pet's final scale, and
	-- prepare is what sets that scale. Dressing first would size a
	-- Legendary's halo to the 21-stud raw export.
	--
	-- `paint` is off for the placeholder because buildPlaceholder has already
	-- coloured it, in two tones, from the same tier table.
	PetVisuals.decorate(model, petId, { paint = art ~= nil })

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	-- The (0, 50, 0) fallback is the world origin, which is another island's
	-- worth of distance away from a player standing anywhere but the beach. It
	-- is survivable only because stepBodies snaps a pet that far out on the
	-- first frame the HumanoidRootPart exists -- see SNAP_DIST.
	local start = hrp and (hrp.CFrame * CFrame.new(SLOT_OFFSETS[slot] or SLOT_OFFSETS[1]))
		or CFrame.new(0, 50, 0)
	model:PivotTo(start)

	local attachment = Instance.new("Attachment")
	attachment.Name = "PetGoal"
	attachment.Parent = root

	local align = Instance.new("AlignPosition")
	align.Name = "PetFollow"
	align.Mode = Enum.PositionAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.ApplyAtCenterOfMass = true
	align.MaxForce = 45000
	align.MaxVelocity = 90
	align.Responsiveness = 22
	align.RigidityEnabled = false
	align.Parent = root

	local orient = Instance.new("AlignOrientation")
	orient.Name = "PetFace"
	orient.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orient.Attachment0 = attachment
	orient.MaxTorque = 45000
	orient.MaxAngularVelocity = 28
	orient.Responsiveness = 14
	orient.RigidityEnabled = false
	orient.Parent = root

	model.Parent = workspace

	-- Simulated on the owner's machine, so their own pets never stutter on a
	-- busy server. Wrapped: the character can die between the check above and
	-- this line, and SetNetworkOwner throws on a part that is no longer in the
	-- workspace.
	pcall(function()
		root:SetNetworkOwner(player)
	end)

	return { model = model, root = root, align = align, orient = orient, slot = slot }
end

local function rebuildBodies(player: Player)
	destroyBodies(player)
	local d = stateOf(player)
	if #d.equipped == 0 then
		return
	end
	local set = {}
	for slot, petId in d.equipped do
		local body = spawnBody(player, petId, slot)
		if body then
			table.insert(set, body)
		end
	end
	bodies[player] = set
end

--[[
	A PET THAT IS MILES BEHIND IS TELEPORTED, NOT FLOWN.

	THE BUG THIS FIXES: take a ferry with pets equipped and they vanish. Nothing
	here ever repositioned them -- the movers were simply handed a goal on another
	island and left to fly there. Three things then compound:

	  1. AlignPosition.MaxVelocity is 90, and the hops are 1500 studs to the
	     Dunes or the Cove, 2200 to Ashfall, 3000 to the Vault, 11300 to the
	     Long Shore and 17000 to a duel arena -- 17 seconds of flight at best
	     and over three minutes at worst.
	  2. workspace.StreamingEnabled is TRUE, so a pet left 1500 studs away is
	     not replicated to its owner at all. It does not read as "lagging
	     behind", it reads as gone.
	  3. `spawnBody` hands the root's network ownership to the player, and an
	     owner who has streamed away cannot simulate it. The pet stops moving
	     entirely rather than slowly catching up, which is why it never arrives.

	WHY THE THRESHOLD IS SAFE. The follow offsets reach about 7 studs, the
	fastest vehicle in the game does 31 studs/s (AtvConfig tier 4) and the pet's
	mover does 90, so nothing a player can legitimately do opens a gap of eighty
	studs -- while the SHORTEST teleport in the game is 1500. There is a wide
	band between "lagging" and "another island" and the snap sits in it, so a pet
	never blinks during ordinary play.

	AND IT IS DISTANCE-BASED RATHER THAN HOOKED TO THE FERRY, deliberately. Five
	different systems move a character -- FerryServer, AfkService, DuelService,
	ProgressionServer's rebirth and the vault exit -- and a hook on each is five
	places to remember and one more every time somebody adds a teleport. This
	asks the only question that actually matters and covers all of them.
]]
local SNAP_DIST = 80

local function snapBody(player: Player, body, goal: CFrame)
	-- Ownership has to come back to the server first: the client owns this root,
	-- and a CFrame written server-side on a part somebody else is simulating is
	-- overwritten by their next physics frame. Wrapped because the part can
	-- leave the workspace between the distance test and here.
	pcall(function()
		body.root:SetNetworkOwner(nil)
	end)
	body.model:PivotTo(goal)
	-- Or it arrives carrying whatever momentum it had when it was left behind.
	body.root.AssemblyLinearVelocity = Vector3.zero
	body.root.AssemblyAngularVelocity = Vector3.zero
	pcall(function()
		body.root:SetNetworkOwner(player)
	end)
end

-- One Heartbeat for every pet on the server. Writing two properties per pet is
-- cheap; the springs do the actual work on the owning client.
local function stepBodies()
	local now = os.clock()
	for player, set in bodies do
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if not hrp then
			continue
		end
		for _, body in set do
			if not body.root.Parent then
				continue
			end
			local offset = SLOT_OFFSETS[body.slot] or SLOT_OFFSETS[1]
			-- A slow bob, phase-shifted per slot so five pets are never a rank of
			-- clones moving in lockstep.
			local bob = math.sin(now * 2.2 + body.slot * 2.1) * 0.22
			local goal = hrp.CFrame * CFrame.new(offset.X, offset.Y + bob, offset.Z)

			if (body.root.Position - goal.Position).Magnitude > SNAP_DIST then
				snapBody(player, body, goal)
			end

			body.align.Position = goal.Position
			-- Facing the player's forward, not the player: a pet that turns to
			-- look at you every time you stop reads as a security camera.
			body.orient.CFrame = CFrame.lookAt(goal.Position, goal.Position + hrp.CFrame.LookVector)
		end
	end
end

--------------------------------------------------------------------------
-- OWNING, EQUIPPING
--------------------------------------------------------------------------

--[[
	`forWhat` NAMES THE THING THAT WAS TRYING TO HAND THIS PET OVER, and it exists
	for one failure: a bag at MaxOwned.

	The refusal below is correct and always was. What was wrong is WHO the message
	sounded like it was about. A player who pressed BUY on the Starter Pack, was
	charged Robux, and received nothing got a toast reading "Your pet bag is full
	(250/250)" -- which is the answer to a question they did not ask. It reads as
	an unrelated notification, and the PACK reads as broken.

	That is not hypothetical: it is exactly what a saturated Studio profile did,
	and telling it apart from a genuine fault in the pass took a full pass through
	the monetisation code. A paying customer gets no such chance.

	Callers that are not a purchase pass nothing and get the old sentence, which is
	still the right one for a hatch or a trade -- there the pet bag IS what the
	player was thinking about.
]]
function PetServer.grant(player: Player, petId: string, forWhat: string?): boolean
	local def = PetConfig.get(petId)
	if not def then
		warn("[PetServer] refused unknown petId:", petId)
		return false
	end
	local d = stateOf(player)

	-- Last line of defence. `hatch` checks this before it charges, which is the
	-- check that matters; this one catches any other caller.
	if countOwned(d) >= PetConfig.MaxOwned then
		local held, cap = countOwned(d), PetConfig.MaxOwned
		if type(forWhat) == "string" and forWhat ~= "" then
			-- "waiting", not "lost", and it is the truth: every caller that passes a
			-- name is all-or-nothing and claims NOTHING on this path, so the grant is
			-- retried by its own join sweep. A player who is not told that has no
			-- reason to come back and try.
			notify(player, string.format("%s is waiting \u{2014} your pet bag is full "
				.. "(%d/%d). Release a pet, then rejoin to claim it.", forWhat, held, cap), "warn")
			warn(string.format("[PetServer] %s: bag full (%d/%d), so %s could not be "
				.. "granted for %s. Nothing was claimed; it retries on their next join.",
				player.Name, held, cap, tostring(petId), forWhat))
		else
			notify(player, string.format("Your pet bag is full (%d/%d).", held, cap), "warn")
		end
		return false
	end

	d.owned[petId] = (d.owned[petId] or 0) + 1
	-- Once seen, always in the index -- even if this one is released later.
	d.discovered[petId] = true

	-- Auto-equip into a free slot. A pet you just paid for and then have to go
	-- and find a menu to switch on is a pet that feels like it did not arrive.
	if #d.equipped < PetConfig.MaxEquipped then
		table.insert(d.equipped, petId)
		recomputeLuck(player)
		rebuildBodies(player)
	end
	push(player)
	return true
end

function PetServer.setEquipped(player: Player, petId: string, equip: boolean): boolean
	local def = PetConfig.get(petId)
	if not def then
		return false
	end
	local d = stateOf(player)

	if equip then
		if (d.owned[petId] or 0) <= 0 then
			return false
		end
		--[[
			YOU MAY WEAR AS MANY COPIES AS YOU OWN.

			This used to refuse outright if the id was already equipped -- the
			reasoning being that three slots of one Legendary would be the only
			loadout anyone ever ran, and that duplicates are a trade good.

			That cost more than it bought. A ten-pull that lands eleven pets
			across three species left a five-slot bag holding three, EQUIP BEST
			filled three and stopped, and nothing on screen explained why. A
			player cannot tell "the game is broken" from "the game has a rule
			I cannot see", and they should not have to.

			The cap is what you actually own, which is the only limit that is
			self-evident. The mono-loadout is still a real trade -- five of one
			pet is five of the same Luck instead of your five best -- and
			PetConfig.luckOf already sums the list, so it prices itself.
		]]
		local wearing = 0
		for _, id in d.equipped do
			if id == petId then
				wearing += 1
			end
		end
		if wearing >= (d.owned[petId] or 0) then
			return false
		end
		if #d.equipped >= PetConfig.MaxEquipped then
			notify(player, string.format("You can only have %d pets out.", PetConfig.MaxEquipped), "warn")
			return false
		end
		table.insert(d.equipped, petId)
	else
		local i = table.find(d.equipped, petId)
		if not i then
			return false
		end
		table.remove(d.equipped, i)
	end

	recomputeLuck(player)
	rebuildBodies(player)
	push(player)
	return true
end

--[[
	EQUIP BEST -- one recompute, one rebuild, one push.

	The obvious build is a loop of setEquipped calls, and that is wrong three
	ways: it tears down and respawns the follow rig once per pet, it fires a sync
	per pet, and it can refuse halfway and leave a half-applied loadout. This
	swaps the whole list at once and touches the world exactly once.
]]
function PetServer.equipBest(player: Player): boolean
	local d = stateOf(player)
	local best = PetConfig.bestOf(d.owned, PetConfig.MaxEquipped)

	-- Already wearing exactly this? Do nothing. Pressing the button twice must
	-- not restart five spawn animations for no change.
	if #best == #d.equipped then
		local same = true
		for i, petId in best do
			if d.equipped[i] ~= petId then
				same = false
				break
			end
		end
		if same then
			return false
		end
	end

	d.equipped = best
	recomputeLuck(player)
	rebuildBodies(player)
	push(player)
	return true
end

--[[
	Release one copy, to get back under MaxOwned.

	An EQUIPPED pet is refused rather than quietly unequipped and deleted. In a
	grid where release sits next to equip, silently destroying the thing the
	player is currently wearing is the misclick that loses somebody a Legendary.

	COUNTED, NOT ID-LEVEL. The old test refused if the id appeared in `equipped`
	at all, which was right while only one copy could ever be worn. Now that a
	player may wear as many as they own, a player holding six and wearing two
	had four spares they could not throw away and no way to get under MaxOwned
	except by taking pets off first.

	THE TRADE SIDE NO LONGER DOES THIS. canGive below lets a player put a pet
	they are wearing straight onto the table, because applyTrade takes it off
	their back in the same commit. Release has no such second half -- it destroys
	-- so the worn copy stays reserved here.
]]
function PetServer.release(player: Player, petId: string): boolean
	local d = stateOf(player)
	local count = d.owned[petId] or 0
	if count <= 0 then
		return false
	end
	--[[
		THE LOCK, AND IT IS CHECKED HERE RATHER THAN ONLY IN THE PANEL.

		The client draws a padlock instead of an X on a locked tile and does not
		offer the tap -- but the panel is a drawing of a snapshot, and the only
		thing standing between a stale snapshot and a destroyed pet is this line.
		Same rule the equipped test below has followed since it was written.

		WHY THE FEATURE EXISTS. A player lost a Mythic on 2026-09-09: "when I
		unequipped a pet and tried to re-equip it, my 300%% Mythic was deleted
		with one click". Release mode is a sticky toggle, and the ONLY protection
		it had was the equipped test immediately below -- so unequipping a pet
		stripped the exact guard that was keeping it alive, and the next tap,
		meant to put it back on, destroyed it instead.
	]]
	if d.locked[petId] then
		local def = PetConfig.get(petId)
		notify(player, string.format("%s is locked. Unlock it first.",
			def and def.DisplayName or "That pet"), "warn")
		return false
	end
	local worn = 0
	for _, id in d.equipped do
		if id == petId then
			worn += 1
		end
	end
	if count - worn <= 0 then
		notify(player, "Take one off before you release it.", "warn")
		return false
	end
	if count <= 1 then
		d.owned[petId] = nil
	else
		d.owned[petId] = count - 1
	end
	-- `discovered` is untouched on purpose: the index remembers.
	--
	-- So is `locked`, and for a different reason: this line is only reached for
	-- a pet that is NOT locked, so there is never a stale flag to clear here.
	-- A lock survives releasing the last copy and applies again to the next one
	-- hatched, which is what a player who locked something meant.
	push(player)
	return true
end

--[[
	FIVE DUPLICATES BECOME ONE OF THE RUNG ABOVE.

	Asked for on 2026-09-21: "Was ist mit einer Maschine um die doppelten tiere
	zu multiplizieren?" The reasoning for reading that as a fusion rather than
	literally, and for the count and the ceiling, is in PetConfig beside
	FuseCount. This half is the safety.

	IT ENFORCES EXACTLY THE TWO RULES release DOES, and restates them rather than
	calling release five times: a loop of single releases is five syncs and five
	save writes, which is the mistake keepBest's note already describes. The
	rules are the lock and the worn copy, and the note above release explains
	what each of them cost a player before it existed.

	THE OUTCOME IS ROLLED BEFORE ANYTHING IS DESTROYED. If this pet has nowhere
	to go -- a Mythic at the ceiling, or the VIP pet which is not on the ladder --
	the player is told and keeps all five. Rolling afterwards would mean a path
	where five pets are gone and the reward turns out to be nil.

	SPACE IS NEVER THE PROBLEM HERE. Five leave and one arrives, so the bag is
	four lighter than it started and grant's cap test cannot refuse. That is why
	this consumes first and grants second; the reverse would fail at MaxOwned,
	which is exactly where a player with duplicates to burn is standing.
]]
function PetServer.fuse(player: Player, petId: string): boolean
	local def = PetConfig.get(petId)
	if not def then
		return false
	end

	local need = PetConfig.FuseCount
	local outId = PetConfig.fuseOutcome(petId, Random.new())
	if not outId then
		notify(player, string.format("%s is already as high as fusing goes.",
			def.DisplayName), "warn")
		return false
	end

	local d = stateOf(player)
	if d.locked[petId] then
		notify(player, string.format("%s is locked. Unlock it first.", def.DisplayName), "warn")
		return false
	end

	local count = d.owned[petId] or 0
	local worn = 0
	for _, id in d.equipped do
		if id == petId then
			worn += 1
		end
	end
	-- Spare means NOT counting the ones out on the beach, the same arithmetic
	-- release does one pet at a time.
	local spare = count - worn
	if spare < need then
		notify(player, string.format("Fusing takes %d spare %s \226\128\148 you have %d.",
			need, def.DisplayName, math.max(0, spare)), "warn")
		return false
	end

	local left = count - need
	d.owned[petId] = (left > 0) and left or nil
	-- `discovered` and `locked` are untouched, exactly as release leaves them:
	-- the index remembers, and this line is only reached for an unlocked pet.

	if not PetServer.grant(player, outId, nil) then
		-- Should be unreachable -- see the note on space above -- but five pets
		-- have already gone, so the client must hear about it either way.
		warn(string.format("[PetServer] %s: fused %d x %s but could not be granted %s",
			player.Name, need, tostring(petId), tostring(outId)))
		push(player)
		return false
	end

	local outDef = PetConfig.get(outId)
	notify(player, string.format("%d \195\151 %s \226\134\146 %s!", need, def.DisplayName,
		outDef and outDef.DisplayName or outId), "good")
	return true
end

--[[
	KEEP THE BEST N AND RELEASE EVERYTHING ELSE.

	ASKED FOR BY NAME, on 2026-09-09: "\u{30da}\u{30c3}\u{30c8}\u{306e}\u{30ed}\u{30c3}\u{30af}\u{3068}\u{4e00}\u{6589}\u{524a}\u{9664}\u{306e}\u{5b9f}\u{88c5}\u{3092}\u{304a}\u{9858}\u{3044}\u{3057}\u{307e}\u{3059}\u{3002}" -- pet locking and
	bulk deletion. The lock half already existed. This is the other half, and it
	is the answer to the grind that produced the report: at MaxOwned the game
	refuses to hatch and sends you to the Pets tab, where clearing space was two
	hundred and fifty individual taps.

	THE PLAYER STATES WHAT TO KEEP, NOT WHAT TO DESTROY. That is the whole safety
	argument for this shape over a "release everything" button. A number that is
	misread too low keeps fewer pets than intended; a number misread on a delete
	button destroys more than intended. Only one of those is recoverable by
	stopping and thinking, and neither is recoverable afterwards -- so the
	direction the mistake falls in is the design.

	RANKED BY PetConfig.bestOf, WHICH IS THE SAME FUNCTION EQUIP BEST USES, so
	"your best" means one thing in this game rather than two that disagree. It
	orders copies by luck, then tier, then id -- the same order the grid sorts
	tiles in, so what survives is what the player was already looking at down the
	top of the list.

	TWO THINGS OUTRANK THE RANKING, AND BOTH KEEP MORE THAN N RATHER THAN FEWER:
	a LOCKED pet is never released -- by species, because that is what a lock is
	in this data model -- and a WORN copy is never released. Those are the same
	two rules PetServer.release enforces one pet at a time, restated here because
	this path does not go through it: a loop of single releases would be a sync
	and a save write per pet, which is the mistake equipBest's note already
	describes.

	So the count that survives can EXCEED N, and that is correct. A player who
	locked twelve pets and asked to keep their best ten meant both things.
]]
function PetServer.keepBest(player: Player, keep: number): number
	local d = stateOf(player)
	keep = math.clamp(math.floor(tonumber(keep) or 0), 0, PetConfig.MaxOwned)

	-- The survivors, as a multiset: bestOf returns one entry per COPY.
	local survive = {}
	for _, petId in PetConfig.bestOf(d.owned, keep) do
		survive[petId] = (survive[petId] or 0) + 1
	end

	-- Locked: every copy of that species stays, whatever the ranking said.
	for petId, count in d.owned do
		if d.locked[petId] then
			survive[petId] = count
		end
	end

	-- Worn: at least as many copies as are currently on the player.
	local worn = {}
	for _, petId in d.equipped do
		worn[petId] = (worn[petId] or 0) + 1
	end
	for petId, n in worn do
		if (survive[petId] or 0) < n then
			survive[petId] = n
		end
	end

	--[[
		The keys are only ever REWRITTEN or REMOVED here, never added, which is
		what makes editing the table safe while iterating it.

		`discovered` is untouched on purpose and so is `locked`, for the two
		reasons written out over PetServer.release: the index remembers a pet you
		no longer hold, and a lock is meant to outlive the copy it was protecting.
	]]
	local released = 0
	for petId, count in d.owned do
		local left = math.min(count, survive[petId] or 0)
		if left < count then
			released += count - left
			d.owned[petId] = (left > 0) and left or nil
		end
	end

	if released > 0 then
		-- ONE push for the whole sweep. See equipBest.
		push(player)
		notify(player, string.format("Released %d pet%s. Your best %d are still here.",
			released, released == 1 and "" or "s", keep), "info")
	end
	return released
end

--[[
	LOCK OR UNLOCK A PET, so a misclick in release mode cannot destroy it.

	SET FOR A PET YOU DO NOT OWN IS ALLOWED, and that is deliberate rather than
	an oversight: the flag's whole job is to be in place BEFORE the tap that
	would have spent it, and a player who locks something in the Index before
	hatching it has done exactly the right thing. Nothing downstream reads a
	lock for a pet that is not held.

	CLEARING IS UNCONDITIONAL. There is no state in which the game should refuse
	to let somebody unlock their own pet -- a lock that cannot be lifted is a
	second way to lose the pet, not a safeguard.
]]
function PetServer.setLocked(player: Player, petId: string, locked: boolean): boolean
	if not PetConfig.get(petId) then
		return false
	end
	local d = stateOf(player)
	local want = locked and true or nil
	if d.locked[petId] == want then
		return false
	end
	d.locked[petId] = want
	push(player)
	return true
end

--------------------------------------------------------------------------
-- TRADING  --  the exchange, and the only place two ledgers move at once
--------------------------------------------------------------------------
--[[
	WHY THE SWAP LIVES IN HERE RATHER THAN IN TradeService.

	TradeService owns the negotiation -- who invited whom, what is on the table,
	who has locked and confirmed. It does NOT own pets, and a trade orchestrated
	from outside this module would have to run `release` on one player and then
	`grant` on the other, which is two half-transactions with a gap in the
	middle. If anything refused in that gap -- a full bag, a pet that was equipped
	after the offer was made -- the pets would already be gone from one side and
	not yet arrived at the other. That is how a trade system dupes or deletes.

	So the exchange is ONE call, here, where the ledgers are: everything is
	validated first, and only then does anything move. Past the COMMIT line below
	there is nothing that can fail and nothing that yields -- Luau will not
	preempt between those statements, so no other code can observe a half-done
	trade or act on it.

	PETS ARE FUNGIBLE BY ID. There is no per-instance uid in this data model:
	`owned` is petId -> count. So an offer is a {petId = count} table and a trade
	is arithmetic on two of them, which is a large part of why this is short.
]]

local function offerSize(offer): number
	local n = 0
	for _, c in offer do
		n += math.floor(c)
	end
	return n
end

--[[
	Can this player hand over exactly this offer, right now?

	EQUIPPED COPIES COUNT. The only question asked here is whether the ledger
	holds enough of that pet. How many of them the player happens to be wearing
	is not this function's business.

	IT USED TO BE. The old rule reserved a copy for every slot the pet was
	sitting in -- own four and wear three and exactly one was tradeable -- which
	is exactly backwards for a trade screen. The pets people want to trade are
	the ones they have out; a player with a single Mythic on their back could not
	put it on the table at all, and the answer was a trip to the Pets tab to
	unequip it and come back. That is a detour with no rule behind it. The offer
	tray had a whole empty state written for the dead end it produced.

	NOTHING DOWNSTREAM NEEDED THE RESERVATION. applyTrade runs tidyEquipped after
	the swap, which drops any slot now wearing a pet the player no longer holds a
	copy of -- so trading a pet off your own back takes it off your back, in the
	same commit, with no frame where a slot points at a pet that has gone.

	PetServer.release still reserves worn copies and that difference is on
	purpose: release DESTROYS a pet and a misclick there is unrecoverable, where a
	trade is a table both sides locked and then confirmed.
]]
function PetServer.canGive(player: Player, offer): (boolean, string?)
	if type(offer) ~= "table" then
		return false, "Nothing offered."
	end
	local d = stateOf(player)
	for petId, count in offer do
		-- A WHOLE, FINITE, POSITIVE NUMBER OR NOTHING.
		--
		-- TradeService only ever writes integers into an offer, so none of this is
		-- reachable from the client today -- the remote carries a petId and no
		-- count at all. It is here because `offer` is a plain table and this is the
		-- function that decides whether one is honest, so it should not depend on
		-- its only caller staying careful. Checked BEFORE the floor rather than
		-- after: 1.5 floored to 1 used to pass and be silently treated as one pet,
		-- and math.huge floored to math.huge used to reach the ownership test and
		-- be refused with a message about taking pets off.
		if type(petId) ~= "string" or type(count) ~= "number"
			or count ~= count or count == math.huge or count == -math.huge
			or count < 1 or math.floor(count) ~= count then
			return false, "That offer does not make sense."
		end
		if not PetConfig.get(petId) then
			return false, "That is not a pet."
		end
		local held = d.owned[petId] or 0
		if held < count then
			local def = PetConfig.get(petId)
			return false, string.format("You do not have that many copies of %s.",
				def and def.DisplayName or petId)
		end
		--[[
			A LOCKED PET DOES NOT GO ON THE TABLE EITHER.

			The note above draws a line between release (destroys, so a worn copy
			stays reserved) and trade (both sides lock and confirm, so it does
			not need the reservation). A LOCK IS ON THE OTHER SIDE OF THAT LINE
			FROM THE EQUIPPED TEST: it is not a statement about what the player is
			currently wearing, it is a standing instruction that this pet is not
			to leave the collection -- and a trade is the other way it can.

			The player is refused with a reason rather than the pet being silently
			dropped from the offer, so the fix is one tap in the Pets tab and
			there is no state where a confirmed trade quietly moves less than what
			was on the table.
		]]
		if d.locked[petId] then
			local def = PetConfig.get(petId)
			return false, string.format("%s is locked. Unlock it in the Pets tab first.",
				def and def.DisplayName or petId)
		end
	end
	return true, nil
end

-- The exchange. Returns false and a reason WITHOUT having moved anything, or
-- true with both ledgers already swapped and both clients already told.
function PetServer.applyTrade(A: Player, offerA, B: Player, offerB): (boolean, string?)
	if A == B then
		return false, "You cannot trade with yourself."
	end
	if not A.Parent or not B.Parent then
		return false, "That player has gone."
	end

	local okA, whyA = PetServer.canGive(A, offerA)
	if not okA then
		return false, whyA
	end
	local okB, whyB = PetServer.canGive(B, offerB)
	if not okB then
		return false, whyB
	end

	local dA, dB = stateOf(A), stateOf(B)
	local outA, outB = offerSize(offerA), offerSize(offerB)

	-- Room is checked NET, not gross: giving four away and taking four back does
	-- not need eight free slots, and refusing it because it briefly would is the
	-- kind of arithmetic that makes a full collection untradeable.
	if countOwned(dA) - outA + outB > PetConfig.MaxOwned then
		return false, string.format("%s has no room for that many pets.", A.DisplayName)
	end
	if countOwned(dB) - outB + outA > PetConfig.MaxOwned then
		return false, string.format("%s has no room for that many pets.", B.DisplayName)
	end

	--[[
		THE LAST GUARD, AND IT IS THE DUPE VECTOR.

		The subtraction below writes `nil` when a count reaches zero, which is what
		keeps `owned` free of empty rows. If a count were ever to go NEGATIVE it
		would write nil just the same -- the giver would lose whatever they had and
		the receiver would still be credited the full amount. That is a dupe on one
		side and a deletion on the other, from one missing check.

		canGive above already makes it impossible, and nothing yields between there
		and here so the ledger cannot move in the gap. This re-derives it anyway,
		across BOTH offers, before a single value is written -- because "an earlier
		function guarantees it" is exactly the assumption that stops being true the
		day somebody adds a second caller.
	]]
	for petId, count in offerA do
		if (dA.owned[petId] or 0) - count < 0 then
			return false, "That trade no longer adds up."
		end
	end
	for petId, count in offerB do
		if (dB.owned[petId] or 0) - count < 0 then
			return false, "That trade no longer adds up."
		end
	end

	------------------------------------------------------------------
	-- COMMIT. Nothing below here can fail, and nothing below here yields.
	------------------------------------------------------------------
	local function move(from, to, offer)
		for petId, count in offer do
			local left = (from.owned[petId] or 0) - count
			from.owned[petId] = (left > 0) and left or nil
			to.owned[petId] = (to.owned[petId] or 0) + count
			-- Traded pets count as discovered: the index is a record of what you
			-- have held, and a pet you were handed is one you have held.
			to.discovered[petId] = true
		end
	end
	move(dA, dB, offerA)
	move(dB, dA, offerB)

	-- Belt and braces against canGive: drop any slot that is now wearing a pet
	-- the player no longer has a copy of. Backwards, because it removes.
	local function tidyEquipped(d)
		local seen = {}
		for i = #d.equipped, 1, -1 do
			local id = d.equipped[i]
			seen[id] = (seen[id] or 0) + 1
			if seen[id] > (d.owned[id] or 0) then
				table.remove(d.equipped, i)
			end
		end
	end
	tidyEquipped(dA)
	tidyEquipped(dB)

	recomputeLuck(A)
	recomputeLuck(B)
	push(A)
	push(B)

	-- Model work LAST: rebuildBodies clones and parents, which is the one thing
	-- in this function that could yield. By here the ledgers are already correct
	-- and already saved, so a yield costs at worst a frame of stale pets.
	rebuildBodies(A)
	rebuildBodies(B)
	return true, nil
end

-- The persistence seam's other half. Every table is validated against the
-- catalogue rather than trusted, so a save written by an older roster cannot
-- resurrect a pet that no longer exists.
function PetServer.restore(player: Player, owned, equipped, discovered, locked)
	local d = stateOf(player)
	d.owned, d.equipped, d.discovered, d.locked = {}, {}, {}, {}

	if type(owned) == "table" then
		local held = 0
		for petId, count in owned do
			if PetConfig.get(petId) and type(count) == "number" and count > 0 then
				-- A save written before the cap existed, or under a higher one,
				-- is truncated rather than rejected: losing the tail of a
				-- collection beats refusing to load it at all.
				local take = math.min(math.floor(count), PetConfig.MaxOwned - held)
				if take > 0 then
					d.owned[petId] = take
					d.discovered[petId] = true
					held += take
				end
			end
		end
	end
	if type(discovered) == "table" then
		for petId in discovered do
			if PetConfig.get(petId) then
				d.discovered[petId] = true
			end
		end
	end
	-- Restored WITHOUT reference to what is owned, for the reason setLocked
	-- gives: a lock is allowed to run ahead of the pet. A profile saved by a
	-- version before locks existed simply has none, which is the same thing a
	-- new account has.
	if type(locked) == "table" then
		for petId in locked do
			if PetConfig.get(petId) then
				d.locked[petId] = true
			end
		end
	end
	if type(equipped) == "table" then
		-- Counted, not de-duplicated: a saved loadout may legitimately hold two
		-- of the same pet now (see the note in equip), and the old `not
		-- table.find` test would have silently dropped the second on every
		-- single load.
		local wearing = {}
		for _, petId in equipped do
			if PetConfig.get(petId)
				and (wearing[petId] or 0) < (d.owned[petId] or 0)
				and #d.equipped < PetConfig.MaxEquipped
			then
				wearing[petId] = (wearing[petId] or 0) + 1
				table.insert(d.equipped, petId)
			end
		end
	end

	recomputeLuck(player)
	rebuildBodies(player)
	push(player)
end

--[[
	COPIES, not the live tables.

	This used to hand back `d.owned` and `d.equipped` directly, which made every
	caller a potential writer of authoritative state -- and the persistence seam
	below is exactly the kind of caller that would hold onto one and mutate it
	between saves. A test caught it first: comparing "before" and "after"
	snapshots compared a table with itself, because both names pointed at the
	same one.
]]
function PetServer.get(player: Player)
	local d = stateOf(player)
	return table.clone(d.owned), table.clone(d.equipped)
end

--------------------------------------------------------------------------
-- HATCHING
--------------------------------------------------------------------------

--[[
	BUYING IS TWO STEPS NOW, AND THE FIRST STEP IS THE SECURITY.

	The prompt used to hatch on the spot. It opens a menu instead -- and what
	makes that safe is exactly what made the old way safe: ProximityPrompt's
	Triggered is ENGINE-VALIDATED, so it proves the player genuinely stood
	within MaxActivationDistance. A RemoteEvent proves nothing on its own.

	So the trigger records an INTENT (which station, when) and EggBuy is only
	honoured against a live one. The payload carries a count and nothing else:
	the egg, the price and the station all come off the recorded intent, so
	there is no field in the message worth forging.

	Re-checked on the way OUT as well as the way in, because between opening a
	menu and pressing confirm a player can walk a long way.
]]
local MAX_BULK = 10
local INTENT_LIFE = 30      -- seconds an opened menu stays good for
local INTENT_SLACK = 8      -- studs of grace on top of the prompt's own range
local intents = {}          -- [Player] = { station, eggKey, at }

local function rootOf(player: Player): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") or nil
end

function PetServer.openMenu(player: Player, eggKey: string, station)
	local egg = PetConfig.eggFor(eggKey)
	if not egg then
		warn("[PetServer] station names an egg that does not exist:", eggKey)
		return
	end
	intents[player] = { station = station, eggKey = eggKey, at = os.clock() }

	-- Everything the menu needs to do its own arithmetic and grey its own
	-- buttons. All of it is re-derived here at purchase time anyway -- this is
	-- for drawing, not for deciding.
	Net.get("EggMenu"):FireClient(player, {
		eggKey = egg.key,
		eggName = egg.name,
		blurb = egg.blurb,
		cost = egg.cost,
		coins = SellServer.getCoins(player),
		room = math.max(0, PetConfig.MaxOwned - countOwned(stateOf(player))),
		max = MAX_BULK,
		anchor = station and station.anchor or nil,
	})
end

function PetServer.hatch(player: Player, eggKey: string, station, count: number?): boolean
	local egg = PetConfig.eggFor(eggKey)
	if not egg then
		warn("[PetServer] station names an egg that does not exist:", eggKey)
		return false
	end

	local want = math.clamp(math.floor(tonumber(count) or 1), 1, MAX_BULK)

	local now = os.clock()

	local function refuse(text: string)
		notify(player, text, "warn")
		Net.get("Fx"):FireClient(player, { kind = "Reject", part = station and station.anchor or nil })
		return false
	end

	--[[
		THE COOLDOWN SAYS SO NOW. IT USED TO REFUSE IN SILENCE.

		This check sat above `refuse` and returned a bare false, which made it the
		ONLY path out of a purchase that told the player nothing. Everything else
		here speaks: bag full, cannot afford, no intent, stale menu, walked away --
		all of them notify. A buy that does nothing at all, with no toast and no
		Reject, is indistinguishable from a broken button.

		juicebox reported exactly that on 2026-09-27 -- "it won't let me buy pets"
		-- and their profile ruled out every path that DOES speak: 0/250 pets so
		the bag was not full, no auto-release saved, 0 pets ever discovered, and
		4.9M coins against a 500-coin Basic and a 400k Prestige, so they could
		afford what was in front of them. This silent branch is the only refusal
		left that behaves the way they described.

		THAT IS NOT A DIAGNOSIS AND IT IS NOT CLAIMED AS ONE. Their report could
		not be reproduced. What is claimed is narrower and is true either way: a
		purchase flow should not have a silent refusal in it.

		ONCE PER COOLDOWN, NOT ONCE PER TAP. A player mashing the button at 1.25s
		intervals would otherwise get a column of identical toasts, which is its
		own bug report. `coolWarned` stores the lastHatch stamp already warned
		about, so each genuine cooldown window speaks exactly once.
	]]
	local last = lastHatch[player] or -math.huge
	if now - last < HATCH_COOLDOWN then
		if coolWarned[player] ~= last then
			coolWarned[player] = last
			return refuse("One at a time \u{2014} try that again in a moment.")
		end
		return false
	end

	--[[
		THE BAG FIRST, because it decides how many we are even trying to buy.

		grant() refuses when full too, but it runs AFTER addCoins -- so without
		this a ten-pack of Prestige eggs would take half a million coins and hand
		back however many happened to fit.
	]]
	local held = countOwned(stateOf(player))
	local room = PetConfig.MaxOwned - held
	if room <= 0 then
		return refuse(string.format("Pet bag full (%d/%d). Release some in the Pets tab.",
			held, PetConfig.MaxOwned))
	end

	--[[
		AND THE BALANCE, WHICH CANNOT BE LEFT TO addCoins.

		The currency adapter clamps at zero (see CTBBridge.CTB_CURRENCY.add), so
		addCoins(-50000) on a player holding 300 succeeds, empties their pocket
		and returns 0. Deducting without checking would not error -- it would
		quietly charge everything they had and still hand them a pet.
	]]
	local coins = SellServer.getCoins(player)
	local afford = math.floor(coins / math.max(egg.cost, 1))
	if afford <= 0 then
		return refuse(string.format("%s costs $%d. You have $%d.", egg.name, egg.cost, coins))
	end

	--[[
		CLAMPED, NOT REFUSED. Asking for ten and being told "no" when nine would
		have worked is the worst of the three answers; taking the money for ten
		and handing back nine is the worst of all. So the order shrinks to what is
		actually payable and storable, and the player is TOLD which limit bit.
	]]
	--[[
		THE AUTO-RELEASE FLOOR CHANGES WHAT "ROOM" MEANS.

		With the filter off, every pull needs a slot and the clamp below is the
		whole story. With it on, most pulls need NO slot at all -- they are thrown
		back the instant they are rolled -- so clamping the order to the free space
		would defeat the entire feature: the player who asked for this was sitting
		AT the cap, which is exactly when `room` is 0 and nothing can be opened.

		SO THE ORDER IS SIZED ON WHAT THEY CAN AFFORD, and the space is checked per
		pull inside the loop, where the answer is actually known. One slot is still
		required to start: with none at all the first keeper would have nowhere to
		go, and finding that out after paying is the outcome this is meant to
		prevent.
	]]
	local floor = PetConfig.autoReleaseFloor(player)
	local filtering = floor > 0

	local n = filtering and math.min(want, afford) or math.min(want, room, afford)
	if n < want then
		notify(player, string.format("Opened %d instead of %d -- %s.", n, want,
			(filtering or (afford < want and afford <= room)) and "that is all you can afford"
				or "that is all the room left in your bag"), "warn")
	end

	lastHatch[player] = now

	local results, bestIndex, bestTier = {}, 0, nil
	local thrownBack, opened = 0, 0
	for _ = 1, n do
		-- Roll first, charge second, grant third. If a roll ever throws, nobody
		-- has been charged for that one.
		local petId, tier = PetConfig.rollPet(eggKey, rng)
		local def = PetConfig.expect(petId)
		local d = stateOf(player)

		--[[
			A LOCKED PET IS NEVER THROWN BACK, whatever the floor says.

			The lock is the player's standing instruction that this pet does not
			leave the collection, and it already outranks the release button and the
			trade table (see PetServer.release and canGive). A filter set once and
			forgotten must not be the one thing that gets past it.
		]]
		local keep = d.locked[petId] or not PetConfig.belowFloor(petId, floor)

		--[[
			CHECKED BEFORE THE CHARGE, AND IT STOPS THE WHOLE ORDER.

			Only a KEEPER needs a slot, so this can only bite once the bag has
			genuinely filled with things the player asked to keep. Breaking rather
			than skipping is deliberate: every pull after this one would hit the same
			wall, and charging for nine more rolls that cannot be kept is the exact
			"took the money and handed back nothing" the clamp above exists to avoid.
		]]
		if keep and countOwned(d) >= PetConfig.MaxOwned then
			notify(player, string.format("Pet bag full (%d/%d) \u{2014} stopped after %d.",
				countOwned(d), PetConfig.MaxOwned, opened), "warn")
			break
		end

		SellServer.addCoins(player, -egg.cost, "egg")
		opened += 1
		if keep then
			PetServer.grant(player, petId)
		else
			-- NOT granted and then released: that would churn the ledger, the save
			-- and every client push for a pet the player never owned. The one thing
			-- grant() does that still has to happen is the INDEX -- they found it,
			-- and an index that forgets what the filter caught would make the
			-- collection log impossible to finish with the feature switched on.
			d.discovered[petId] = true
			thrownBack += 1
		end

		local info = PetConfig.tierInfo(tier)
		local idx = (type(info) == "table" and info.index) or 1
		if idx > bestIndex then
			bestIndex, bestTier = idx, tier
		end

		table.insert(results, {
			petId = petId,
			displayName = def.DisplayName,
			tier = tier,
			luck = def.Luck,
			luckText = PetConfig.luckText(def.Luck),
			equipped = table.find(d.equipped, petId) ~= nil,
			-- So the reveal can say what happened to it. The player still SEES every
			-- animal they paid to roll -- hiding the ones the filter caught would
			-- make a ten-pack look like it short-changed them.
			released = (not keep) or nil,
		})
	end
	n = opened

	-- One push for the whole order. grant() pushes per keeper; a batch that was
	-- ALL thrown back changes only `discovered`, which nothing else would send.
	if thrownBack > 0 then
		push(player)
		notify(player, string.format("Auto-released %d below %s.", thrownBack,
			PetConfig.autoReleaseLabel(floor)), "info")
	end

	Net.get("HatchEgg"):FireClient(player, {
		eggKey = egg.key,
		eggName = egg.name,
		cost = egg.cost,
		spent = egg.cost * n,
		count = n,
		requested = want,
		-- The client builds every reveal model from ReplicatedStorage.Pets, the
		-- same folder the server reads, so no art is replicated here.
		results = results,
		anchor = station and station.anchor or nil,
	})

	-- Everyone sees a hatch, and on a ten-pack they see the BEST of it. A
	-- station that visibly pays out is the single best advert the feature has,
	-- and unlike a sell payout it leaks no numbers.
	Net.get("Fx"):FireAllClients({
		kind = "Sparkle",
		part = station and station.anchor or nil,
		rarity = bestTier,
	})
	return true
end

--------------------------------------------------------------------------
-- STATIONS
--------------------------------------------------------------------------
--[[
	A station is any Model tagged PetStation carrying an `EggKey` attribute and
	a BasePart to hang the prompt on. PetStationBuilder builds and tags them,
	but nothing here depends on that -- tag a model you have built by hand and
	it works identically.
]]
local function registerStation(model: Instance)
	if not model:IsA("Model") or stations[model] then
		return
	end

	local eggKey = model:GetAttribute("EggKey")
	if type(eggKey) ~= "string" or not PetConfig.eggFor(eggKey) then
		warn("[PetServer] PetStation has no usable EggKey attribute:", model:GetFullName())
		return
	end
	local egg = PetConfig.eggFor(eggKey)

	local anchor = model:FindFirstChild("PromptAnchor", true)
	if not (anchor and anchor:IsA("BasePart")) then
		anchor = model:FindFirstChildWhichIsA("BasePart", true)
	end
	if not anchor then
		warn("[PetServer] PetStation has no BasePart:", model:GetFullName())
		return
	end

	local prompt = anchor:FindFirstChildWhichIsA("ProximityPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 12
		prompt.RequiresLineOfSight = false
		prompt.Parent = anchor
	end
	prompt.ActionText = string.format("Hatch  $%d", egg.cost)
	prompt.ObjectText = egg.name

	local station = { model = model, anchor = anchor, prompt = prompt, eggKey = eggKey }
	stations[model] = station

	-- Opens the menu; it does not buy. See the note above PetServer.openMenu
	-- for why the split is the security and not the decoration.
	prompt.Triggered:Connect(function(player)
		PetServer.openMenu(player, eggKey, station)
	end)

	model.AncestryChanged:Connect(function(_, parent)
		if not parent then
			stations[model] = nil
		end
	end)
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

local started = false
function PetServer.start()
	assert(RunService:IsServer(), "[PetServer] server-only")
	if started then
		return
	end
	started = true

	local function hook(player: Player)
		stateOf(player)
		recomputeLuck(player)
		push(player)
		player.CharacterAdded:Connect(function()
			-- Bodies do not survive a death: the movers are acting on a root
			-- whose network owner has just been reassigned, and the pets end up
			-- drifting at the corpse. Rebuilt one beat later so the new
			-- HumanoidRootPart exists to spawn them next to.
			task.defer(rebuildBodies, player)
		end)
	end

	-- The sixty stored meshes import grey. Painting them here rather than
	-- leaving it as a command-bar chore means a place that has just had the
	-- pack re-imported comes up coloured instead of coming up grey and
	-- waiting for somebody to remember. Writes only Color/Material, so it is
	-- free to run on every boot.
	do
		local ok, painted = pcall(PetVisuals.paintLibrary)
		if ok then
			print(string.format("[PetServer] painted %d/%d pet models", painted, PetConfig.Count))
		else
			warn("[PetServer] could not paint the pet library:", painted)
		end
	end

	Players.PlayerAdded:Connect(hook)
	for _, player in Players:GetPlayers() do
		hook(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		destroyBodies(player)
		data[player] = nil
		lastHatch[player] = nil
		lastEquip[player] = nil
		intents[player] = nil
	end)

	--[[
		THE PURCHASE, honoured only against a live intent.

		The count is the ONLY thing the client gets a say in, and even that is
		clamped twice -- here to the bulk limit, and again inside hatch() to what
		the player can actually pay for and store.
	]]
	Net.get("EggBuy").OnServerEvent:Connect(function(player, payload)
		if type(payload) ~= "table" then
			return
		end
		local intent = intents[player]
		if not intent then
			notify(player, "Walk up to an egg station first.", "warn")
			return
		end
		if os.clock() - intent.at > INTENT_LIFE then
			intents[player] = nil
			notify(player, "That menu went stale -- press E at the egg again.", "warn")
			return
		end

		-- STILL THERE? The prompt proved it when the menu opened; this proves it
		-- at the moment the money moves.
		local root = rootOf(player)
		local anchor = intent.station and intent.station.anchor
		local reach = ((intent.station and intent.station.prompt
			and intent.station.prompt.MaxActivationDistance) or 12) + INTENT_SLACK
		if not (root and anchor) or (root.Position - anchor.Position).Magnitude > reach then
			intents[player] = nil
			notify(player, "You walked away from the egg.", "warn")
			return
		end

		PetServer.hatch(player, intent.eggKey, intent.station, payload.count)
	end)

	--[[
		THE ONE INBOUND MESSAGE, and everything it is not allowed to say.

		A payload may name an ACTION and a PET ID. It may not name a slot, a
		luck value, a count, or a price -- the server derives every one of those
		from its own tables. "best" carries no data whatsoever.

		Throttled because each of these can tear down and respawn up to five
		models: a client holding the button down would otherwise rebuild the
		follow rig as fast as it could send.
	]]
	Net.get("PetEquip").OnServerEvent:Connect(function(player, payload)
		if type(payload) ~= "table" then
			return
		end
		local now = os.clock()
		if now - (lastEquip[player] or -math.huge) < EQUIP_COOLDOWN then
			return
		end
		lastEquip[player] = now

		local action = payload.action
		if action == "best" then
			PetServer.equipBest(player)
			return
		end
		if action == "unequipAll" then
			local d = stateOf(player)
			if #d.equipped > 0 then
				d.equipped = {}
				recomputeLuck(player)
				rebuildBodies(player)
				push(player)
			end
			return
		end

		--[[
			CARRIES A NUMBER RATHER THAN A PET, so it is answered above the petId
			guard below -- the same reason "best" and "unequipAll" are.

			The count is re-derived here from the server's own tables and the
			client's is never trusted: the panel computes the same figure with the
			same function only so the confirmation card can name it before the tap.
		]]
		if action == "keepBest" then
			PetServer.keepBest(player, payload.keep)
			return
		end
		local petId = payload.petId
		if type(petId) ~= "string" then
			return
		end
		--[[
			FUSE RIDES THIS REMOTE RATHER THAN ONE OF ITS OWN, and that was a
			correction: a PetFuse event was written first and it was the wrong
			shape twice over. Every other thing you can do to a pet -- equip,
			release, lock, keepBest, unequipAll -- arrives here as an `action`, and
			this handler is where the EQUIP_COOLDOWN anti-spam gate lives. A remote
			of its own would have been the one destructive pet action in the game
			with no rate limit on it.

			The payload carries an id and nothing else. How many copies it costs,
			which rung it produces and which pet comes back are all decided in
			PetServer.fuse off the server's own tables.
		]]
		if action == "fuse" then
			PetServer.fuse(player, petId)
			return
		end
		if action == "release" then
			PetServer.release(player, petId)
			return
		end
		if action == "lock" then
			PetServer.setLocked(player, petId, payload.locked == true)
			return
		end
		PetServer.setEquipped(player, petId, payload.equip == true)
	end)

	for _, model in CollectionService:GetTagged(PetServer.TAG) do
		registerStation(model)
	end
	CollectionService:GetInstanceAddedSignal(PetServer.TAG):Connect(registerStation)

	RunService.Heartbeat:Connect(stepBodies)
end

return PetServer
