--[[
	CTBBridge  --  ServerScriptService.CTBBridge

	The single seam between Clean the Beach and the sift/sell system. Everything
	CTB-specific lives here; no other file in this system knows CTB exists.

	WHAT CHANGES ABOUT THE GAME
	---------------------------
	Before: roller uncovers litter -> bag -> stand on SellPad -> flat price.
	After, and this is the whole shape of the game now:

	  LOOSE litter (Can, Bottle, Shell, Coin -- the majority)
	      roller uncovers it -> value rolled on the spot -> already Cleaned
	      -> stand on SellPad -> paid. No detour, no minigame. The fast
	      moment-to-moment run is completely uninterrupted.

	  ENCASED finds (Glasses, Watch, Phone -- the money)
	      sifter uncovers a featureless lump, identity withheld -> sifting bay,
	      blast the crust off chunk by chunk -> value AND identity revealed
	      -> stand on SellPad -> paid.

	Standing on the pad holding a crusted lump refuses and says so.

	WHY THE BAG BECOMES OUR ARRAY RATHER THAN MIRRORING IT
	------------------------------------------------------
	CTB kept `state[plr].bag = {itemId, ...}`. A mirror would mean two lists that
	can disagree the moment anything goes wrong, which is exactly the failure the
	whole shared-state design exists to prevent. So CTB_Server's three bag touch
	points now call into this bridge, and InventoryController owns the only list.
	CTB_HUD is untouched: it reads the Bag / BagValue / BagMax / Coins player
	ATTRIBUTES, and this module keeps writing all four.

	CURRENCY
	--------
	CTB holds cash on a player attribute, not leaderstats. SellServer.Currency is
	pointed at that attribute, so there is still exactly one grant path and no
	duplicate "Coins" appears on the player list.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local ItemConfig = require(Modules:WaitForChild("ItemConfig"))
-- For the attribute NAME only. Pure data with no requires of its own -- the
-- same grounds SaveService holds it on.
local TutorialConfig = require(Modules:WaitForChild("TutorialConfig"))
local InventoryController = require(Modules:WaitForChild("InventoryController"))

local SellServer = require(script.Parent:WaitForChild("SellServer"))
local ValueCalculator = require(script.Parent:WaitForChild("ValueCalculator"))
-- For the attribute NAME only -- plain replicated data, no server dependencies.
local LeaderboardConfig = require(Modules:WaitForChild("LeaderboardConfig"))
-- The FIELDS and their cell grids, for the rake-collect index further down.
-- Also plain replicated data: requiring it here pulls in no server code.
local Config = require(ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Config"))

--[[
	ONE PIECE OF LITTER, COUNTED FOR LIFE.

	This game measured litter in WEIGHT carried and COINS earned and threw the
	piece count away, so "how much trash have you picked up" had no answer to
	rank. This is that answer, and it is incremented at the two places litter
	actually changes hands -- here, and TrashCollectionService.collect for the
	tagged props the vehicle nets take.

	COUNTED WHERE IT IS TAKEN, not where it is sold. A find that goes into the
	bag has been picked up whatever happens to it afterwards: sold, released,
	or still sitting in the bag when the player logs off. Counting at the sell
	pad instead would rank patience rather than work, and would miss every piece
	stowed in a machine's hold.
]]
local function countPickup(player: Player)
	local key = LeaderboardConfig.TrashAttribute
	player:SetAttribute(key, (tonumber(player:GetAttribute(key)) or 0) + 1)
end

local CTBBridge = {}

-- CTB's own RemoteEvent, so its HUD keeps getting the messages it expects.
local ctbNet = ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Net")

--------------------------------------------------------------------------
-- CURRENCY: CTB's player attribute
--------------------------------------------------------------------------

local CTB_CURRENCY = {
	get = function(player: Player): number
		return player:GetAttribute("Coins") or 0
	end,
	add = function(player: Player, delta: number): number
		local total = math.max(0, (player:GetAttribute("Coins") or 0) + delta)
		player:SetAttribute("Coins", total)
		return total
	end,
}

-- Claimed BEFORE SellServer.start(), not from inside CTBBridge.start().
--
-- SellServer only builds its own leaderstats balance when nobody has claimed
-- the currency, and it asks that question once, in start(). The bridge used to
-- answer it afterwards -- so every player got a leaderstats "Coins" that was
-- created, never written again, and sat on the player list reading $0 for the
-- whole session while the HUD across the screen counted real money. Claiming
-- first means there is exactly one balance from the first frame.
function CTBBridge.claimCurrency()
	SellServer.Currency = CTB_CURRENCY
end

--------------------------------------------------------------------------
-- MONEY, for CTB_Server
--------------------------------------------------------------------------
-- CTB_Server used to read and write the `Coins` attribute itself. That did move
-- the right number -- the adapter above points at that very attribute -- but it
-- went AROUND SellServer, so nothing hanging off the one grant path ever ran:
-- lifetime earnings never counted a tide bonus, and the shop's purse and its
-- red/green buy buttons went on showing the balance from before it.
--
-- These two are the seam's money API, so every coin in the game moves through
-- one function and every view of it hears about the move.
function CTBBridge.coins(player: Player): number
	return SellServer.getCoins(player)
end

-- `reason` is forwarded rather than swallowed: this bridge is how CTB_Server and
-- StairServer reach the one grant path, so dropping it here would leave every
-- coin those two move off the economy report. See SellServer's ECONOMY table.
function CTBBridge.addCoins(player: Player, delta: number, reason: string?): number
	return SellServer.addCoins(player, delta, reason)
end

--------------------------------------------------------------------------
-- THE PLAYER LIST
--------------------------------------------------------------------------
-- A pure VIEW of the attribute above, never a second store: it is only ever
-- assigned FROM `Coins` and nothing in the game reads it back. That is what
-- lets the player list carry the balance without reintroducing the two-numbers-
-- that-can-disagree problem the currency adapter exists to prevent.
local function mirrorLeaderstats(player: Player)
	local ls = player:FindFirstChild("leaderstats")
	if not ls then
		ls = Instance.new("Folder")
		ls.Name = "leaderstats"
		ls.Parent = player
	end
	local coins = ls:FindFirstChild("Coins")
	if not coins then
		coins = Instance.new("IntValue")
		coins.Name = "Coins"
		coins.Parent = ls
	end
	coins.Value = player:GetAttribute("Coins") or 0
end

--------------------------------------------------------------------------
-- ATTRIBUTES that CTB_HUD reads
--------------------------------------------------------------------------

-- BagValue is CLEANED items only. A dirty item has no rolled value yet, so
-- there is genuinely nothing to add -- which is the point: the HUD's worth
-- readout now only climbs when you actually clean something.
function CTBBridge.pushAttributes(player: Player)
	local inv = InventoryController.Server.find(player)
	if not inv then
		return
	end
	local worth = 0
	for _, rec in inv:Items() do
		if rec.state == "Cleaned" and rec.value then
			worth += rec.value
		end
	end
	player:SetAttribute("Bag", inv:Count())
	player:SetAttribute("BagValue", worth)
	player:SetAttribute("BagMax", inv:MaxCapacity())
end

--[[
	ROLLERBLOCKED, AND WHY IT IS DRIVEN OFF THE WEIGHT RATHER THAN OFF THE FLUSH.

	THE BUG. CTB_Server writes this flag, but only from inside the per-tick rake
	loop -- so it is only ever corrected while the player is actually dragging the
	sifter across a field. Fill a bag, walk off the field to the sell pad, sell:
	nothing rakes between the sale and the next step onto sand, so the flag stayed
	true and CTB_HUD went on printing "BAG FULL of crusted finds" over a bag that
	was now 16 lbs into a 68 lb limit. It corrected itself the moment you walked
	back onto sand, which is exactly what made it look intermittent.

	WHY NOT ON InventoryController.Server.Changed, WHICH IS THE OBVIOUS PLACE.
	Because the ledger is not up to date yet when it fires. WeightService.reconcile
	is ALSO a listener on that signal, and it is the thing that drops the sold
	records and recomputes the load -- so a listener that asks hasRoom() from
	inside the same flush is asking before the weight has come off. Measured: the
	flag stayed true through a sale that took the bag from 68 lbs to 16.

	CurrentWeight is the signal that means "the ledger has settled": WeightService
	writes it at the end of push(), after recompute(). MaxWeight is watched with it
	so a Bucket Size purchase unblocks a full bag immediately rather than at the
	next rake tick.

	hasRoom is the same authority CTB_Server asks, so the two writers cannot
	disagree about what "full" means -- they call one function. Written only on a
	change, as CTB_Server's is, so this costs no attribute writes at rest.
]]
local function refreshBlocked(player: Player)
	if not player.Parent then
		return
	end
	local blocked = not CTBBridge.hasRoom(player)
	if player:GetAttribute("RollerBlocked") ~= blocked then
		player:SetAttribute("RollerBlocked", blocked)
	end
end

--------------------------------------------------------------------------
-- HOOKS called from CTB_Server
--------------------------------------------------------------------------

--[[
	THE VEHICLE HOLD, reached the same lazy optional way the weight system is.

	The beach's OWN litter -- the hundreds of props CTB buries and the sifter
	rakes up -- arrives through tryAdd below, and it is most of what is lying on
	the sand. Without this branch a player in a truck drove over all of it and
	nothing happened: the only thing the net could collect was TrashSeeder's
	ninety tagged props, so the beach looked full and the machine looked broken.
]]
local holdLoaded = false
local VehicleHold = nil
local function vehicleHold()
	if holdLoaded then
		return VehicleHold
	end
	holdLoaded = true
	local module = script.Parent:FindFirstChild("VehicleHold")
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" and type(result.riding) == "function" then
			VehicleHold = result
		elseif not ok then
			warn("[CTBBridge] VehicleHold present but would not load:", result)
		end
	end
	return VehicleHold
end

--[[
	What one of CTB's finds weighs, by the same table the pickup path prices
	everything else with, so a bottle costs the same wherever it came from.

	It reaches WeightConfig DIRECTLY rather than through weightSystem(), which is
	declared further down this file and is therefore nil at the moment tryAdd
	below wants it. That was not a crash you would notice, it was a real bug:
	CTB_Server clears a find off the field BEFORE calling tryAdd, so every throw
	in here deleted a piece of litter without banking it. The beach cleared and
	the hold did not move -- litter that vanished instead of being collected.
]]
local weightConfigLoaded = false
local weightConfigCache = nil
local function itemWeights()
	if weightConfigLoaded then
		return weightConfigCache
	end
	weightConfigLoaded = true
	local folder = ReplicatedStorage:FindFirstChild("WeightSystem")
	local module = folder and folder:FindFirstChild("WeightConfig")
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" then
			weightConfigCache = result
		end
	end
	return weightConfigCache
end

local function weightOf(itemId: string): number
	local config = itemWeights()
	if not config then
		return 1
	end
	local w = config.WeightByItemId[itemId]
	return (type(w) == "number" and w > 0) and w or (config.DefaultItemWeight or 1)
end

--[[
	THE ONBOARDING'S ONE-LUMP CAP, RESOLVED THE WAY EVERY OTHER CROSS-SYSTEM
	REACH IN THIS FILE IS: lazily, optionally, and behind a pcall. See
	itemWeights above and weightSystem below -- a require at the top would mean a
	place without the onboarding could not run this one, and CTBBridge is up
	before TutorialServer is.

	WHY IT IS NEEDED HERE AT ALL, when CTB_Server already runs every find it digs
	up through TutorialServer.biasFind: because the RAKE is not the only thing
	that fills a bag. TrashSeeder lays ninety collectible props on the beach and
	draws each of them through ItemConfig.rollItemId, the beach's ordinary table
	-- measured at 7.95% crusted -- so roughly seven lumps are lying in the open
	at any moment, and walking over one arrives HERE without ever having been
	near the tutorial's hook. tryAdd is the single door every id has to come
	through to become a bag record, which is what makes it the right backstop.

	The cap is idempotent, so a find that already went through biasFind pays
	nothing for passing it twice.

	ONE SEAM, MEASURED AND LEFT ALONE. WeightService.collect resolves the prop's
	id, weight and label BEFORE it calls this, so a swapped pickup leaves its
	weight-ledger row naming the rock while the bag holds the substitute. Nothing
	shows it: WeightClient's success branch reads ok / item / load and never the
	label, and that row's itemId is read by a debug dump and the adopt path and by
	nothing else. CrustedWeight is derived from the INVENTORY's state rather than
	from the row, so the number the HUD and the tutorial both watch stays honest.
	The alternative -- refusing the prop -- leaves a rock lying on the sand that
	the player walks over again and again and can never clear.
]]
local tutorialLoaded, TutorialServer = false, nil
local function tutorialCap(player: Player, itemId: string): string
	if not tutorialLoaded then
		tutorialLoaded = true
		local moduleScript = script.Parent:FindFirstChild("TutorialServer")
		if moduleScript and moduleScript:IsA("ModuleScript") then
			local ok, result = pcall(require, moduleScript)
			if ok and type(result) == "table" and type(result.capCrust) == "function" then
				TutorialServer = result
			elseif not ok then
				warn("[CTBBridge] TutorialServer present but would not load:", result)
			end
		end
	end
	if not TutorialServer then
		return itemId
	end
	-- No island to name: this is the door the beach's own litter comes through,
	-- and capCrust falls back to CTB's shared pool when it is not given one.
	local ok, result = pcall(TutorialServer.capCrust, player, itemId, nil)
	return (ok and type(result) == "string") and result or itemId
end

-- Roller uncovered `itemId`. Returns true if it was taken, false if full
-- (CTB relocates it back into the sand on false, exactly as before).
function CTBBridge.tryAdd(player: Player, itemId: string): boolean
	-- Before anything else, so the machine's hold is capped exactly as the bag is.
	itemId = tutorialCap(player, itemId)

	-- Riding: it goes in the machine, not the bag. Returning false when the HOLD
	-- is full is the same contract as a full bag, so CTB puts the find back in
	-- the sand and nothing is lost.
	local holds = vehicleHold()
	local hold = holds and holds.riding(player)
	if hold then
		local w = weightOf(itemId)
		if not holds.canStow(hold, w) then
			return false
		end
		-- stow can still refuse, so the count hangs off its answer rather than off
		-- having got this far.
		local stowed = holds.stow(hold, itemId, w, nil)
		if stowed then
			countPickup(player)
		end
		return stowed
	end

	local inv = InventoryController.Server.get(player)
	if not inv:HasRoom(1) then
		return false
	end
	-- Inventory:Add refuses ids it does not know, which is the guard that keeps
	-- ItemConfig and CTB's Config.ITEMS from silently drifting apart.
	local rec = inv:Add(itemId)
	if not rec then
		warn("[CTBBridge] ItemConfig has no entry for CTB item id:", itemId)
		return false
	end

	-- Loose litter was never a mystery. Roll its value here and mark it ready,
	-- so a normal run of trash never has to visit the sifting bay at all -- that
	-- detour is reserved for the finds worth detouring for.
	if not ItemConfig.isEncased(itemId) then
		--[[
			THE TUTORIAL'S RICH LITTER. While the onboarding is armed,
			TutorialServer publishes a flat per-item value sized so one small
			bag pays the first rung of every track -- the argument lives over
			TutorialConfig.BagCap. An attribute, not a require: the same seam
			SellServer reads Golden Hour through. LOOSE LITTER ONLY -- what a
			lump turns out to hold stays ValueCalculator's business at the bay,
			or the tutorial's one mystery would have a printed answer.
		]]
		local tutorialValue = tonumber(player:GetAttribute(TutorialConfig.TrashValueAttribute))
		inv:SetValue(rec.uid, (tutorialValue and tutorialValue > 0)
			and tutorialValue or ValueCalculator.roll(itemId))
		inv:SetState(rec.uid, "Cleaned")
	end
	countPickup(player)
	return true
end

--------------------------------------------------------------------------
-- WHAT THE POP EFFECT IS ALLOWED TO SAY
--------------------------------------------------------------------------
-- CTB_Server broadcasts every uncovered find to EVERY client so they all see
-- it burst out of the sand. For an encased find that broadcast cannot carry
-- the real id: ItemConfig's contract is that the id is withheld until the
-- crust is off (see InventoryController.publicView, which strips it from the
-- inventory snapshot for exactly this reason), and a client that is told
-- "Glasses" has been told the answer -- on the wire, not merely on screen.
--
-- Loose litter was never a mystery, so it goes through unchanged.
CTBBridge.LUMP_ID = "Lump"

function CTBBridge.popIdFor(itemId: string): string
	if ItemConfig.isEncased(itemId) then
		return CTBBridge.LUMP_ID
	end
	return itemId
end

--------------------------------------------------------------------------
-- IS THERE ROOM?  (asked BEFORE anything is raked)
--------------------------------------------------------------------------
-- A full bag stops the roller working now, rather than raking on and quietly
-- reburying whatever it turns up. That makes this the load-bearing question,
-- and the obvious way to ask it is wrong here:
--
-- `inv:HasRoom(1)` counts SLOTS, and the weight system lifts the slot cap to
-- 9999 at runtime (WeightConfig.OverrideInventorySlots) and rations by LOAD
-- instead. So the slot check is always true and can never answer this. It is
-- still asked first, because putting the slot cap back is a one-line config
-- change and this should keep working the day someone makes it.
--
-- The weight question is not "is there a sliver of space" but "would the
-- LIGHTEST thing the beach can hand over still fit". Half a pound of headroom
-- is full for every practical purpose: raking on would turn up finds that
-- bounce straight back into the sand, which is the exact behaviour this exists
-- to stop. The threshold is read off WeightConfig's own tables rather than
-- written down, so re-tuning what things weigh moves it automatically.

local weightLoaded = false
local WeightService, WeightConfig

local function weightSystem()
	if weightLoaded then
		return WeightService, WeightConfig
	end
	weightLoaded = true

	local folder = script.Parent:FindFirstChild("WeightSystem")
	local service = folder and folder:FindFirstChild("WeightService")
	local shared = ReplicatedStorage:FindFirstChild("WeightSystem")
	local config = shared and shared:FindFirstChild("WeightConfig")
	if not (service and config) then
		return nil, nil   -- no weight system installed; slots are the only limit
	end

	local ok, a, b = pcall(function()
		return require(service), require(config)
	end)
	if ok then
		WeightService, WeightConfig = a, b
	else
		warn("[CTBBridge] weight system is present but would not load:", a)
	end
	return WeightService, WeightConfig
end

local lightest: number? = nil

local function lightestCollectable(config): number
	if lightest then
		return lightest
	end
	local best = math.huge
	for _, table_ in ipairs({ config.WeightByItemId, config.WeightByName }) do
		if type(table_) == "table" then
			for _, w in pairs(table_) do
				if type(w) == "number" and w > 0 and w < best then
					best = w
				end
			end
		end
	end
	if best == math.huge then
		best = config.DefaultItemWeight or 1
	end
	lightest = math.max(best, config.MinItemWeight or 0)
	return lightest
end

-- `find` rather than `get`, so being asked 24 times a second by the sim loop
-- never creates an inventory for a player who has not picked anything up.
function CTBBridge.hasRoom(player: Player): boolean
	-- Riding: the question is about the MACHINE, and a full bag is no answer at
	-- all -- the whole point of a hold is that you can keep working with a full
	-- rucksack on the seat beside you.
	local holds = vehicleHold()
	local hold = holds and holds.riding(player)
	if hold then
		local config = itemWeights()
		return holds.canStow(hold, config and lightestCollectable(config) or 1)
	end

	local inv = InventoryController.Server.find(player)
	if inv and not inv:HasRoom(1) then
		return false
	end

	local service, config = weightSystem()
	if not (service and config) then
		return true
	end

	local ok, reason = service.canCarry(player, lightestCollectable(config))
	-- "NoData" is a ledger that has not been built for this player yet, which
	-- means they are carrying nothing at all -- room by definition, not a
	-- refusal. "Full" and "TooHeavy" are both genuinely no room for even the
	-- lightest thing out there.
	return ok or reason == "NoData"
end

--------------------------------------------------------------------------
-- THE RAKE IS A COLLECTION SWEEP
--------------------------------------------------------------------------
--[[
	WHY THIS EXISTS.

	Two kinds of rubbish lie on a field, and only one of them used to notice the
	tool going over it.

	  the DECORATIVE scatter   built per client by CTB_Client, keyed to the very
	                           cells the server rakes, and swept into the basket
	                           the instant its cell is cleared. Always worked.
	  the COLLECTIBLE props    TrashSeeder's ninety: tagged CollectibleTrash,
	                           shared by everyone, and worth money. Nothing in
	                           CTB ever looked at them. The only way to pick one
	                           up was to WALK within WeightConfig.AutoCollectRadius
	                           of it.

	So "this field is 100% raked" and "there are ninety pieces of rubbish lying
	on it" were consistent states -- and past the early levels the rake band
	clears sand several times wider than that walking circle, so the tool would
	visibly sweep a piece and leave it standing on bare ground.

	This is the join. A cell about to be marked clean asks what is standing on
	it, and whatever is there is COLLECTED rather than deleted -- the player is
	paid for it exactly as if they had walked over it. Making the beach
	finishable therefore costs the run nothing; it hands over MORE per tide than
	the walking circle ever did, because the rake reaches further than the reach
	does.

	THE INVARIANT IT BUYS, and the one worth keeping in mind when editing any of
	this: A CLEAN CELL HAS NOTHING STANDING ON IT.

	INDEXED BY CELL, NOT SEARCHED. The sweep visits every cell of the swept
	rectangle on every tick at 24 Hz. A distance test against ninety props in
	there would be thousands of comparisons a second against a table that
	actually changes a few times a minute, so the index is maintained off the
	tag's own signals and read O(1).
]]
local TRASH_TAG = "CollectibleTrash"

local trashByCell = {}     -- island id -> cell index -> { [Instance]: true }
local trashCell = {}       -- Instance -> { isl = island id, idx = cell index }
local trashWatch = {}      -- Instance -> AncestryChanged connection

-- The same arithmetic CTB_Server's sweep uses to turn a world point into a
-- cell, so a prop and the column it is standing in can never disagree about
-- which cell that is.
local function cellFor(pos: Vector3)
	local isl = Config.fieldAt(pos)
	if not isl then
		return nil, nil
	end
	local ix = math.floor((pos.X - isl.x0) / Config.TILE)
	local iz = math.floor((pos.Z - isl.z0) / Config.TILE)
	if ix < 0 or iz < 0 or ix >= isl.grid or iz >= isl.grid then
		return nil, nil
	end
	return isl, Config.index(isl, ix, iz)
end

local function dropFromIndex(inst: Instance)
	local at = trashCell[inst]
	if not at then
		return
	end
	trashCell[inst] = nil
	local byCell = trashByCell[at.isl]
	local set = byCell and byCell[at.idx]
	if set then
		set[inst] = nil
		if next(set) == nil then
			byCell[at.idx] = nil
		end
	end
end

-- Re-read where this prop is and file it under that cell. This is the REMOVAL
-- path too: a piece parked in ServerStorage between pickups is not on any
-- field, so it simply drops out of the index.
local function indexProp(inst: Instance)
	dropFromIndex(inst)
	if not inst:IsDescendantOf(workspace) then
		return
	end
	local config = itemWeights()
	local pos = config and config.positionOf(inst)
	if not pos then
		return
	end
	local isl, idx = cellFor(pos)
	if not isl then
		return
	end
	local byCell = trashByCell[isl.id]
	if not byCell then
		byCell = {}
		trashByCell[isl.id] = byCell
	end
	local set = byCell[idx]
	if not set then
		set = {}
		byCell[idx] = set
	end
	set[inst] = true
	trashCell[inst] = { isl = isl.id, idx = idx }
end

-- AncestryChanged catches every move that matters: a piece is seeded (parented
-- in), collected (parented out to ServerStorage) and respawned (moved, THEN
-- parented back). The respawn pivots before it re-parents, so by the time this
-- fires the new position is already on the instance.
local function watchProp(inst: Instance)
	if trashWatch[inst] then
		return
	end
	trashWatch[inst] = inst.AncestryChanged:Connect(function()
		indexProp(inst)
	end)
	indexProp(inst)
end

local function unwatchProp(inst: Instance)
	local conn = trashWatch[inst]
	if conn then
		conn:Disconnect()
		trashWatch[inst] = nil
	end
	dropFromIndex(inst)
end

-- Lazy and optional, the same shape as vehicleHold and weightSystem above: the
-- beach still runs with no weight system installed, it just has nothing tagged
-- to sweep up.
local trashLoaded = false
local TrashCollection = nil
local function trashCollection()
	if trashLoaded then
		return TrashCollection
	end
	trashLoaded = true
	local folder = script.Parent:FindFirstChild("WeightSystem")
	local module = folder and folder:FindFirstChild("TrashCollectionService")
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" and type(result.collectFromRake) == "function" then
			TrashCollection = result
		elseif not ok then
			warn("[CTBBridge] TrashCollectionService present but would not load:", result)
		end
	end
	return TrashCollection
end

local seederLoaded = false
local TrashSeeder = nil
local function trashSeeder()
	if seederLoaded then
		return TrashSeeder
	end
	seederLoaded = true
	local module = script.Parent:FindFirstChild("TrashSeeder")
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" and type(result.reseat) == "function" then
			TrashSeeder = result
		elseif not ok then
			warn("[CTBBridge] TrashSeeder present but would not load:", result)
		end
	end
	return TrashSeeder
end

--[[
	IS ANYTHING STANDING ON THIS CELL?

	The rake asks once per cell per tick, about cells it may not go on to touch
	at all, so the answer has to be two table reads and no allocation. It exists
	because the sweep now visits a cell that is ALREADY CLEAN when something is
	lying on it -- see the note over rakeCell -- and measuring the band for every
	clean cell of a finished field just to discover there is nothing there is work
	that loop should not be doing.
]]
function CTBBridge.hasLitter(islId: number, idx: number): boolean
	local byCell = trashByCell[islId]
	return byCell ~= nil and byCell[idx] ~= nil
end

--[[
	The sifter has just swept (islId, idx). What should it do about what is lying
	there?

	  "None"   nothing was standing on that cell
	  "Taken"  collected, or already on its way out -- clean the cell
	  "Full"   the bag or the hold refused it. DO NOT clean the cell: leave the
	           sand standing over the piece and stop the roller. This is the same
	           contract tryAdd already has for a buried find, and it is what stops
	           the tool clearing ground out from under something the player has
	           no room to pick up.

	ASKED ABOUT CLEAN CELLS TOO, which is the whole reason hasLitter above exists.
	A raked cell can still have something standing on it -- a respawn is allowed
	onto ground that only SOME of the players working that field have cleared --
	and the sweep used to visit a cell only while it still had sand on it, so it
	never asked again. "Full" from a clean cell means what it always meant (stop
	the roller); there is simply no sand left to leave standing over the piece.
]]
function CTBBridge.rakeCell(player: Player, islId: number, idx: number): string
	local byCell = trashByCell[islId]
	local set = byCell and byCell[idx]
	if not set then
		return "None"
	end
	local service = trashCollection()
	if not service then
		return "None"
	end

	local status = "None"
	-- Clearing the CURRENT key during traversal is allowed, which is what a
	-- successful collect does to this very table by way of AncestryChanged.
	for inst in set do
		local took, reason = service.collectFromRake(player, inst)
		if took then
			status = "Taken"
		elseif reason == "Full" or reason == "TooHeavy" or reason == "HoldFull" then
			return "Full"
		elseif status == "None" then
			-- Somebody else is mid-collect, or it has already gone. Not this
			-- cell's problem, and not a reason to leave sand standing over it.
			status = "Taken"
		end
	end
	return status
end

--------------------------------------------------------------------------
-- WHERE A COLLECTED PIECE COMES BACK
--------------------------------------------------------------------------
--[[
	IS THIS CELL ALREADY RAKED? Handed in by CTB_Server, which owns the grids.

	The dependency runs one way -- CTB_Server requires this module, and it is a
	Script rather than a ModuleScript, so it cannot be required back. The answer
	is therefore installed rather than fetched.

	WHOSE grid, on a busy server? CTB's fields are PER PLAYER: your raked columns
	are yours and the sand beside you is untouched for the person standing in it.
	CTB_Server answers this "raked by every player currently on that field", so a
	piece can still come back onto ground that only SOME people have cleared --
	the alternative starves everyone else's beach the moment one player finishes
	theirs. Solo, which is the case this was reported in, it is exact.
]]
CTBBridge.isRaked = nil

function CTBBridge.setRakedQuery(fn: ((number, number) -> boolean)?)
	CTBBridge.isRaked = fn
end

function CTBBridge.rakedAt(pos: Vector3): boolean
	local query = CTBBridge.isRaked
	if not query then
		return false
	end
	local isl, idx = cellFor(pos)
	if not isl then
		return false
	end
	local ok, answer = pcall(query, isl.id, idx)
	return ok and answer == true
end

--------------------------------------------------------------------------
-- THE SANDBOT
--------------------------------------------------------------------------
--[[
	THE DRONE RAKES THROUGH CTB_Server'S OWN RAKE, AND THAT IS THE WHOLE POINT.

	The sandbot (SandbotService) is a second thing sweeping a band across a
	field. It could have had a rake of its own -- a loop over cells, a call to
	rakeCell, a Clean message -- and every one of those would have been a SECOND
	DEFINITION of what raking pays, what a full bag does to it, when the tide
	turns over and what the client is told. Two of those drifting apart is a
	drone that clears sand the player is not paid for, or pays for sand it did
	not clear.

	So it does not have one. CTB_Server installs its rake here and SandbotService
	calls it, exactly the way isRaked above is installed and for exactly the same
	reason: CTB_Server is a Script and cannot be required, so the answer has to
	be handed over rather than fetched.

	TWO SEAMS, because the drone has two questions and they are not the same:

	  sweepDrone   rake the band I have just driven through, and tell me how it
	               went. Everything about WHAT that costs and pays is over there.
	  dirtyNear    where is the nearest column I have not raked? Only CTB_Server
	               can answer: the grids are per player and they are private to
	               it.

	The third question -- where is the nearest piece of litter -- is answered
	HERE, because the litter index is this file's (see trashByCell above).
]]
CTBBridge.droneSweep = nil
CTBBridge.droneDirty = nil

function CTBBridge.setDroneSweep(fn)
	CTBBridge.droneSweep = fn
end

function CTBBridge.setDroneDirty(fn)
	CTBBridge.droneDirty = fn
end

--[[
	Rake the band from `last` to `cur`, `hw` either side of it, for `player`.

	The verdict, and every caller has to handle all four:

	  "raked"    it cleared at least one column
	  "clean"    the band was already clear. Not a failure: it is what driving
	             over ground you have raked looks like.
	  "full"     the bag would not take what was lying there. THE DRONE MUST
	             STOP -- clearing sand out from under a piece the player cannot
	             carry is the exact bug rakeCell's contract exists to prevent.
	  "nofield"  not over a rakeable field at all (the plaza, a dock, the sea).

	The second return is HOW MANY COLUMNS went clean, which is the drone's own
	readout and nothing else -- no coins, no items. It is a count of cells, so it
	cannot be mistaken for money by anything downstream.

	pcall'd, and a throw is reported as "nofield". A drone is a luxury bolted onto
	the side of the game's core loop; an error inside the rake must never be able
	to take a Heartbeat connection down with it.
]]
function CTBBridge.sweepDrone(player: Player, cur: Vector3, last: Vector3,
	look: Vector3, hw: number, hd: number): (string, number)
	local fn = CTBBridge.droneSweep
	if not fn then
		return "nofield", 0
	end
	local ok, verdict, cleared = pcall(fn, player, cur, last, look, hw, hd)
	if not ok then
		warn("[CTBBridge] drone sweep failed: " .. tostring(verdict))
		return "nofield", 0
	end
	return (type(verdict) == "string") and verdict or "nofield",
		(type(cleared) == "number") and cleared or 0
end

-- The centre of the nearest cell `player` has not raked, within `rings` cells
-- of `from`, or nil if their field is finished (or they are not on one).
function CTBBridge.dirtyNear(player: Player, from: Vector3, rings: number): Vector3?
	local fn = CTBBridge.droneDirty
	if not fn then
		return nil
	end
	local ok, spot = pcall(fn, player, from, rings)
	if not ok then
		warn("[CTBBridge] drone target failed: " .. tostring(spot))
		return nil
	end
	return typeof(spot) == "Vector3" and spot or nil
end

--[[
	THE NEAREST PIECE OF TAGGED LITTER TO A POINT, within `range` studs.

	Off the SAME index the sweep reads (trashByCell), so the drone cannot be
	sent to a bottle the rake does not believe is there. A distance test against
	every prop on the island would be ninety comparisons per ask; a ring walk out
	from the drone's own cell is a handful, and it stops at the first hit.

	RING ORDER IS NOT DISTANCE ORDER -- see Config.eachRing -- so the range test
	is done on the real vector, and a corner hit slightly further than a hit on
	the next ring in is a difference of a few studs in where the drone drives
	next. It is not worth a full sort.

	The descendant check is not belt and braces: a piece parked in ServerStorage
	between pickups drops out of the index on AncestryChanged, but the drone can
	ask in the same frame as somebody else's collect, and driving to a bottle that
	is no longer there is the one visible symptom of a stale index.
]]
function CTBBridge.trashNear(from: Vector3, range: number): (Instance?, Vector3?)
	local isl, cx, cz = Config.cellAt(from)
	if not isl then
		return nil
	end
	local byCell = trashByCell[isl.id]
	if not byCell or next(byCell) == nil then
		return nil
	end
	local config = itemWeights()
	if not config then
		return nil
	end

	local found, foundAt
	local rings = math.max(0, math.floor(range / Config.TILE))
	for r = 0, rings do
		Config.eachRing(isl, cx, cz, r, function(ix, iz)
			local set = byCell[Config.index(isl, ix, iz)]
			if not set then
				return nil
			end
			for inst in set do
				if inst:IsDescendantOf(workspace) then
					local pos = config.positionOf(inst)
					if pos and (pos - from).Magnitude <= range then
						found, foundAt = inst, pos
						return true
					end
				end
			end
			return nil
		end)
		if found then
			return found, foundAt
		end
	end
	return nil
end

--[[
	TrashCollectionService.RespawnMove, installed in start().

	A collected piece used to come back at the exact CFrame it was seeded at,
	which dropped it onto sand the player may have raked clean while it was
	parked -- rubbish reappearing on ground they had personally just cleared.
	It rolls a fresh spot instead and refuses any spot that is currently raked.

	FALSE MEANS WAIT, NOT GIVE UP. On a field that is entirely clean there is
	nowhere legitimate to put it, so the piece stays parked and is offered the
	same question again later. The tide turns every field over on a timer, and
	the beach fills back up then. Forcing it out would undo the whole point.
]]
local function respawnMove(instance: Instance): boolean?
	local seeder = trashSeeder()
	if not seeder then
		return nil
	end
	return seeder.reseat(instance, function(pos)
		return not CTBBridge.rakedAt(pos)
	end)
end

--[[
	Player stepped on the SellPad -- or pressed the HUD's QUICK SELL key, which
	CTB_Server routes into the same sell().

	`anchor` overrides where the sale's effects play and changes nothing else
	about the sale. SellServer reads `counter.anchor` for the coin shower and
	the till bell and for nothing else, so handing it a one-field stand-in is
	the whole of the difference between selling at the pad and selling from
	wherever the player happens to be standing.
]]
function CTBBridge.sell(player: Player, anchor: BasePart?)
	-- The result is deliberately dropped. nil means nothing was cleaned and
	-- SellServer has already said so; a real sale announces itself through the
	-- OnSold hook claimed in start(), so there is nothing left for this to do.
	SellServer.sellAll(player, anchor and { anchor = anchor } or CTBBridge.counter)
end

--[[
	CTB_HUD's OWN SOLD ANIMATION -- the "SOLD n ITEMS +$x" banner and the punch on
	the coin pill. It wants (total, sold, counts).

	CLAIMED OFF SellServer.OnSold RATHER THAN WRITTEN INTO CTBBridge.sell ABOVE,
	and the move is the point rather than tidiness. `sell` is no longer the only
	door to the till: WashServer sells a find the instant it finishes washing
	(SellServer.sellItems), and SellServer's own tagged-counter prompt never comes
	through this file at all. Announced from inside `sell`, both of those moved the
	player's coins and left the HUD saying nothing -- which reads as the balance
	changing on its own.

	COUNTS ARE BUILT FROM THE RECEIPT, so a sale of one item sends one entry. The
	HUD only uses the total and the count today, but the third argument is what CTB
	has always sent and dropping it would be a change to a message four scripts
	read.
]]
local function announceSale(player: Player, result)
	local counts = {}
	for _, line in result.receipt do
		counts[line.itemId] = (counts[line.itemId] or 0) + 1
	end
	ctbNet:FireClient(player, "Sold", result.total, result.sold, counts)
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

local started = false
function CTBBridge.start()
	assert(RunService:IsServer(), "[CTBBridge] server-only")
	if started then
		return
	end
	started = true

	-- Idempotent, and normally already done by ServerMain before SellServer
	-- started. Repeated here so the bridge is still correct if it is ever booted
	-- on its own.
	CTBBridge.claimCurrency()

	-- ONE announcement for every sale in the game, whichever door it came through.
	-- See announceSale. Assigned rather than wrapped: nothing else claims this
	-- hook, and CTB's HUD is the only thing in the place that draws a sale.
	SellServer.OnSold = announceSale

	--[[
		The cell index for the tagged props, and the respawn rule that keeps them
		off ground the player has cleared.

		The GetTagged sweep and the Added signal overlap ON PURPOSE and the order
		does not matter: TrashSeeder tags each prop before it parents it, so a
		piece seeded before this runs is caught by the sweep and one seeded after
		is caught by the signal. watchProp is idempotent either way.
	]]
	for _, inst in CollectionService:GetTagged(TRASH_TAG) do
		watchProp(inst)
	end
	CollectionService:GetInstanceAddedSignal(TRASH_TAG):Connect(watchProp)
	CollectionService:GetInstanceRemovedSignal(TRASH_TAG):Connect(unwatchProp)

	local collection = trashCollection()
	if collection then
		collection.RespawnMove = respawnMove
	end

	-- One flush -> one attribute push, same as every other view in the system.
	InventoryController.Server.Changed:Connect(function(player)
		CTBBridge.pushAttributes(player)
	end)

	local function hook(player: Player)
		InventoryController.Server.get(player)
		CTBBridge.pushAttributes(player)

		-- The player list follows the balance for the rest of the session.
		mirrorLeaderstats(player)
		player:GetAttributeChangedSignal("Coins"):Connect(function()
			mirrorLeaderstats(player)
		end)

		-- See refreshBlocked. These two are the only facts the answer depends on,
		-- and CurrentWeight is written only once the ledger has settled.
		player:GetAttributeChangedSignal("CurrentWeight"):Connect(function()
			refreshBlocked(player)
		end)
		player:GetAttributeChangedSignal("MaxWeight"):Connect(function()
			refreshBlocked(player)
		end)
	end
	Players.PlayerAdded:Connect(hook)
	for _, player in Players:GetPlayers() do
		hook(player)
	end
end

-- Set by ServerMain once the station is placed, purely so the coin-shower FX
-- has a world position to fire from.
CTBBridge.counter = nil

return CTBBridge
