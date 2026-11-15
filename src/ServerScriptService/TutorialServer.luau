--[[
	TutorialServer  --  ServerScriptService.TutorialServer

	Two jobs, and neither of them draws anything. The cards are
	StarterPlayerScripts.TutorialHud's business; this is the half that has to be
	true on the server.

	1. THE GUARANTEE: A NEW PLAYER ALWAYS HAS SOMETHING TO WASH
	----------------------------------------------------------
	The onboarding sends a first-timer to a wash bay. It can only do that
	honestly if there is a lump in the bag when they get there -- and on the
	beach that is a coin toss, not a certainty: crusted finds are 7.4% of what
	comes up, so a first bag with nothing in it happens often enough to be a
	routine experience rather than an edge case. A tutorial step you cannot
	complete is worse than no tutorial at all, because the player does not know
	which of the two of you is broken.

	So `biasFind` is called on every find the sifter turns up, and while the
	player is still owed lumps it swaps a loose id for a crusted one. It swaps
	the ID, not the outcome: what comes out of the rock is still rolled by the
	wash bay and priced by ValueCalculator exactly as always, and the id it
	picks is drawn from THAT FIELD'S OWN POOL at that pool's own relative odds --
	so a beach lump is a Starfish or a Lure the overwhelming majority of the
	time, and the Meteorite at the far end of the table is as unlikely as it has
	always been. Nobody is handed a prize; they are handed the mechanic.

	WHY IT IS SPENT ON THE FIND AND NOT ON THE BAG. The obvious version --
	"when the bag is nearly full and still has no crust, force one" -- has to
	poll, has to define "nearly", and pays out at the moment the player is
	already walking to the sell pad. Spending it on the FIRST finds means the
	very first thing a new player digs up is a mystery rock, which is the most
	interesting thing this game does, and it costs one attribute read per find.

	WHY THE CALL SITE IS CTB_Server AND NOT CTBBridge.tryAdd, which is the
	tidier-looking seam. Because CTB_Server broadcasts the find's public id to
	the finder for the pop effect (`Bridge.popIdFor(found)`) on the line AFTER
	it banks it. Swapping inside tryAdd would put a lump in the bag while the
	sand popped a bottle -- one substitution visible to the player as a bug.
	Substituting before both calls is what keeps them telling one story.

	2. THE DONE STAMP, WITHOUT A REMOTE
	-----------------------------------
	The tutorial's last step is buying an upgrade, and an upgrade is a `Lv_`
	track moving off 1 -- which is an attribute this server writes itself. So
	"they finished" is a thing the server can OBSERVE, and the whole feature
	needs no RemoteEvent in either direction.

	THE CARD ASKS FOR ONE PARTICULAR TRACK AND THIS STAMP ACCEPTS ANY, AND THAT
	ASYMMETRY IS DELIBERATE. TutorialHud's last step names Sifter Width, because
	a first-timer looking at four shop rows needs to be told which one -- but
	this stamp is answering a different question: "does this account still need
	to be shown the loop?". Somebody who has bought a bigger bucket has plainly
	found the shop, and holding the card over them for a second session because
	they bought the wrong row would be pedantry with a DataStore behind it.

	The looseness is also what stops the flag being unreachable. Tying it to one
	track means a player who never buys that track never gets stamped, and sees
	the card every session forever.

	That is not merely tidy. A client-fired "I'm done" is a client deciding
	what gets written to a DataStore, and the honest version of it -- a player
	closing the card with the X -- is not a thing that should be remembered as
	having learned the loop anyway. Dismissing gets you out of this session's
	card; playing the loop is what retires it for good.

	Persisted through SaveService's `tutorialDone` field, so this is
	once-per-account rather than once-per-session.

	STUDIO NOTE. DevGrant hands every Studio joiner half a million coins, three
	rebirths and a full set of levels two seconds after they join, so
	`TutorialConfig.looksNew` is false for them and none of this arms. To test
	the onboarding in Studio, set DevGrant's ENABLED to false.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local ItemConfig = require(Modules:WaitForChild("ItemConfig"))
-- For the CAP below, which asks what is in the bag rather than keeping a count
-- of its own. Plain replicated data with a server half; SellServer, WeightService
-- and CTBBridge all reach it the same way.
local InventoryController = require(Modules:WaitForChild("InventoryController"))
local ProgressionConfig = require(Modules:WaitForChild("ProgressionConfig"))
local TutorialConfig = require(Modules:WaitForChild("TutorialConfig"))
-- For capacityForLevel only: the restore target when the tutorial's small bag
-- is handed back -- the same read EventService's Scrap Rush drop makes, so the
-- two overrides can never disagree about what "normal" is.
local WeightConfig = require(ReplicatedStorage:WaitForChild("WeightSystem"):WaitForChild("WeightConfig"))
-- The one remote this file now owns: the send-off's streaming escort. See the
-- OutroFocus note in Net's own list -- the tutorial's card-and-guarantee halves
-- still never speak; this belongs to the cinematic, which is a different animal.
local Net = require(Modules:WaitForChild("Net"))
local CollectionService = game:GetService("CollectionService")

local Config = require(ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Config"))

local TutorialServer = {}

-- The bias has its own stream, so arming a tutorial cannot perturb the field
-- generator's sequence for anybody else on the server.
local rng = Random.new()

local conns: { [Player]: { RBXScriptConnection } } = {}
local started = false

--------------------------------------------------------------------------
-- WAITING FOR THE PROFILE
--------------------------------------------------------------------------
--[[
	Every attribute `looksNew` reads is written by SaveService's restore, which
	lands after the join -- so asking too early answers "new" for a player with
	twenty rebirths.

	Resolved LAZILY AND OPTIONALLY, the same contract WeightService keeps with
	CTBBridge and WeightConfig keeps with ProgressionConfig: a place with no
	save module still runs, it just falls back to a fixed wait. Requiring it at
	the top would also invert ServerMain's order, which starts SaveService after
	the systems whose seams it claims.
]]
local saveLoaded, SaveService = false, nil
local function saveService()
	if saveLoaded then
		return SaveService
	end
	saveLoaded = true
	local moduleScript = ServerScriptService:FindFirstChild("SaveService")
	if moduleScript and moduleScript:IsA("ModuleScript") then
		local ok, result = pcall(require, moduleScript)
		if ok and type(result) == "table" and type(result.isLoaded) == "function" then
			SaveService = result
		elseif not ok then
			warn("[TutorialServer] SaveService present but would not load:", result)
		end
	end
	return SaveService
end

-- Bounded. A profile that never loads (no DataStore access in Studio with API
-- services off, a store outage) must not leave a genuinely new player without
-- the guarantee -- so this falls through and arms anyway. The cost of being
-- wrong here is two crusted finds for someone who did not need them.
local PROFILE_WAIT = 12
local function awaitProfile(player: Player)
	local service = saveService()
	if not service then
		task.wait(3)
		return
	end
	local deadline = os.clock() + PROFILE_WAIT
	while os.clock() < deadline do
		if not player.Parent then
			return
		end
		if service.isLoaded(player) then
			-- One frame past the load: `apply` writes Rebirths and TotalEarned
			-- inside the same call that flips the flag, and reading between the
			-- two is the whole bug this function exists to avoid.
			task.wait(0.2)
			return
		end
		task.wait(0.25)
	end
end

--------------------------------------------------------------------------
-- THE CRUSTED SUBSET OF A FIELD
--------------------------------------------------------------------------
--[[
	WHICH IDS ARE CRUSTED IS ItemConfig'S ANSWER, NEVER A LIST HERE.

	CTB.Config says so itself where it scales the crusted half of a field --
	"Modules.ItemConfig owns the Encased flag and this table is documented as
	mirroring it, so a second hand-kept list of the crusted ones in this file is
	exactly the drift both files warn about". A third copy in this file would be
	the same mistake with one more place to forget.

	Cached against the POOL TABLE rather than against the island row, because
	every island without its own `itemPool` shares Config.ITEMS and should share
	one answer. Weak keys so a pool that is ever rebuilt does not pin the old one.
]]
local encasedCache = setmetatable({}, { __mode = "k" })

local function poolFor(isl)
	if isl and type(isl.itemPool) == "table" and #isl.itemPool > 0 then
		return isl.itemPool
	end
	return Config.ITEMS
end

local function encasedFor(isl)
	local pool = poolFor(isl)
	if type(pool) ~= "table" then
		return nil
	end
	local cached = encasedCache[pool]
	if cached then
		return cached
	end

	local list, total = {}, 0
	for _, entry in ipairs(pool) do
		local id = entry.id
		if type(id) == "string" and ItemConfig.isEncased(id) then
			-- The pool's OWN spawn weight, so the substitute is drawn at the odds
			-- the field already uses among its lumps -- a Starfish most of the
			-- time, a Meteorite one find in a million and a half, exactly as if
			-- the roll had come up crusted on its own.
			local w = (type(entry.weight) == "number" and entry.weight > 0) and entry.weight or 1
			total += w
			table.insert(list, { id = id, weight = w })
		end
	end

	cached = { list = list, total = total }
	encasedCache[pool] = cached
	return cached
end

--------------------------------------------------------------------------
-- THE CAP  --  one lump, whatever the beach rolls
--------------------------------------------------------------------------
--[[
	THE OTHER HALF OF THE GUARANTEE, AND IT IS THE HALF THAT WAS MISSING.

	biasFind below makes sure a first-timer finds A lump. Nothing made sure they
	did not find SIX -- and the onboarding cannot survive six. The sell pad
	refuses crusted finds, correctly, because they have no rolled value yet; the
	card's SECOND step is SELL and its third is WASH. So every lump past the
	first is dead weight in the bag at the exact step that is asking the player
	to turn the bag into money, and a bag that came up mostly crust puts them on
	the pad with the card saying SELL and nothing happening. There is no way to
	read that as anything but broken.

	TWO DOORS FILL A BAG AND ONLY ONE OF THEM COMES PAST biasFind:

	  THE RAKE   CTB_Server rolls a buried find, and the sandbot's sweep is
	             that same rakeRect handed over as a function, so both arrive
	             through the hook below.
	  THE SAND   TrashSeeder lays ninety collectible props on the beach and
	             draws each one through ItemConfig.rollItemId -- the beach's
	             ordinary table, measured at 7.95% crusted, so about seven of
	             the ninety are lumps lying in the open with LumpRock art on
	             them. Walking over one goes straight to CTBBridge.tryAdd
	             having never been near this file.

	So the cap is called from BOTH doors, and the test is on THE BAG rather than
	on a counter.

	WHY THE BAG AND NOT A SPENT-COUNT. A count has to be decremented by exactly
	one writer or it double-spends, and the rake path calls this TWICE: once in
	biasFind, because the pop effect is broadcast off the id that function
	returns and a swap made later would throw a rock out of the sand and put a
	bottle in the bag; and once in tryAdd, for the doors that never saw biasFind.
	"Are they already carrying one" is idempotent, needs no ledger, cannot be
	spent on a find the bag then refuses for want of room, and self-heals -- wash
	the lump and the beach is free to hand them another.

	IT SWAPS RATHER THAN REFUSES. A refusal leaves the find buried or the prop
	lying on the sand, and a player walking over the same rock four times with
	nothing happening reads as the game being broken -- and the beach has to stay
	clearable. The substitute is drawn from THAT FIELD'S OWN POOL at that pool's
	own odds, which is the same move the guarantee makes in the other direction.
]]
local looseCache = setmetatable({}, { __mode = "k" })

local function looseFor(isl)
	local pool = poolFor(isl)
	if type(pool) ~= "table" then
		return nil
	end
	local cached = looseCache[pool]
	if cached then
		return cached
	end

	local list, total = {}, 0
	for _, entry in ipairs(pool) do
		local id = entry.id
		if type(id) == "string" and not ItemConfig.isEncased(id) then
			local w = (type(entry.weight) == "number" and entry.weight > 0) and entry.weight or 1
			total += w
			table.insert(list, { id = id, weight = w })
		end
	end

	cached = { list = list, total = total }
	looseCache[pool] = cached
	return cached
end

-- Is the onboarding running for this player? The credit attribute is written
-- when the tutorial arms and cleared by finish(), so its PRESENCE is the window
-- -- including after the credit itself has been spent, which is precisely when
-- the cap has work to do. Its VALUE is the guarantee's business, not this one's.
local function inTutorial(player: Player): boolean
	return player:GetAttribute(TutorialConfig.LumpsAttribute) ~= nil
end

-- The moment the guarantee's lump was handed over, so capCrust can tell "the
-- granted rock, still travelling from the roll to the bag" from "a fresh rock
-- after the credit is spent". The rake's grant passes through capCrust a beat
-- later via tryAdd, BEFORE the rock has landed in the bag -- without this
-- window the cap would swap the very lump the guarantee just granted. Weak
-- keys, so a leaver cannot be kept alive by their timestamp.
local grantedAt: { [Player]: number } = setmetatable({}, { __mode = "k" })

-- Is there already something in the bag the sell pad would refuse? Asked as the
-- complement of "Cleaned" rather than as a list of state names -- the same call
-- SellServer.sellAll makes when it decides there is nothing to sell, and for the
-- same reason its note gives: it counts the lump currently mounted at a bay,
-- whose state is "Washing", as still being carried. It is one rock and it is not
-- finished with.
local function carryingCrust(player: Player): boolean
	local inv = InventoryController.Server.find(player)
	if not inv then
		return false
	end
	return inv:Count() - inv:CountByState("Cleaned") > 0
end

-- Returns an item id, always, exactly as biasFind does: every refusal path hands
-- back what it was given, so both call sites can be unconditional assignments.
function TutorialServer.capCrust(player: Player, itemId: string, isl): string
	if typeof(player) ~= "Instance" or type(itemId) ~= "string" then
		return itemId
	end
	-- Cheapest test first. This is on the path of every find and every piece of
	-- litter on the server, and one attribute read is where everybody past their
	-- first session stops.
	if not inTutorial(player) or not ItemConfig.isEncased(itemId) then
		return itemId
	end
	--[[
		ONE LUMP PER TUTORIAL NOW, NOT ONE PER BAG. The old test was carrying
		alone, which re-opened the tap the moment the lump was washed -- and the
		onboarding's beach is one lump and then trash, all the way to the shop.

		`owed > 0`   the guarantee has not been paid yet; an empty-handed player
		             may take this one. If it is the PROP door paying (a seeded
		             LumpRock walked over before the rake forced anything), the
		             credit is spent right here, exactly as biasFind spends it
		             for the rake -- or the field would still owe a second.
		`inFlight`   biasFind granted within the last beat and the rock has not
		             landed in the bag yet -- this call IS that rock, passing
		             through tryAdd's door. See grantedAt above.
	]]
	local owed = tonumber(player:GetAttribute(TutorialConfig.LumpsAttribute)) or 0
	local inFlight = os.clock() - (grantedAt[player] or -1e9) < 3
	if not carryingCrust(player) and (owed > 0 or inFlight) then
		if owed > 0 and not inFlight then
			player:SetAttribute(TutorialConfig.LumpsAttribute, owed - 1)
			grantedAt[player] = os.clock()
		end
		return itemId    -- empty-handed and entitled: this IS the one
	end

	local set = looseFor(isl)
	if not set or set.total <= 0 then
		-- A field with nothing loose on it at all. Nothing to swap to, so the find
		-- stands: one extra rock in the bag beats a find that silently becomes
		-- nothing.
		return itemId
	end

	local roll = rng:NextNumber() * set.total
	for _, entry in ipairs(set.list) do
		roll -= entry.weight
		if roll <= 0 then
			return entry.id
		end
	end
	-- Floating point ran off the end of the table, as in biasFind. The last row is
	-- still a loose id, which is the only property the caller depends on.
	return set.list[#set.list].id
end

--------------------------------------------------------------------------
-- THE HOOK  --  called from CTB_Server, once per find
--------------------------------------------------------------------------
--[[
	RETURNS AN ITEM ID, ALWAYS. Every refusal path hands back exactly what it
	was given, so the call site can be an unconditional assignment and there is
	no branch in CTB_Server that can drop a find on the floor.

	Costs one attribute read per find for everybody, tutorial or not -- but per
	FIND, not per cell. A wide sifter covers a couple of hundred cells in a tick
	and only a handful of them turn anything up, so the read is a rounding error
	next to the rake itself, and the alternative is a second table of live players
	kept in step with Players by hand.
]]
function TutorialServer.biasFind(player: Player, itemId: string, isl): string
	if typeof(player) ~= "Instance" or type(itemId) ~= "string" then
		return itemId
	end

	local owed = tonumber(player:GetAttribute(TutorialConfig.LumpsAttribute)) or 0
	if owed <= 0 then
		-- Nothing owed -- but the CAP may still have something to say, and it has
		-- to say it here rather than being left to tryAdd, because the pop effect
		-- is broadcast off the id this function returns. Hands back what it was
		-- given for everybody who is not mid-onboarding.
		return TutorialServer.capCrust(player, itemId, isl)
	end

	-- The field paid the debt itself. Spending the credit rather than swapping
	-- keeps the guarantee to exactly N crusted finds instead of N EXTRA ones,
	-- which on a lucky opening bag would have been most of the bag.
	if ItemConfig.isEncased(itemId) then
		player:SetAttribute(TutorialConfig.LumpsAttribute, owed - 1)
		grantedAt[player] = os.clock()
		return itemId
	end

	local set = encasedFor(isl)
	if not set or set.total <= 0 then
		-- Nothing on this field is EVER crusted -- the vault's whole exemption.
		-- The debt is left standing rather than burned, so it is still owed on
		-- the first field that has lumps in it.
		return itemId
	end

	local roll = rng:NextNumber() * set.total
	for _, entry in ipairs(set.list) do
		roll -= entry.weight
		if roll <= 0 then
			player:SetAttribute(TutorialConfig.LumpsAttribute, owed - 1)
			grantedAt[player] = os.clock()
			return entry.id
		end
	end

	-- Floating point ran off the end of the table. Not reachable in practice,
	-- and the last row is still a crusted id, which is the only property the
	-- caller depends on.
	player:SetAttribute(TutorialConfig.LumpsAttribute, owed - 1)
	grantedAt[player] = os.clock()
	return set.list[#set.list].id
end

--------------------------------------------------------------------------
-- ARMING AND STAMPING
--------------------------------------------------------------------------
local PREFIX = ProgressionConfig.AttrPrefix

-- Has this player bought ANYTHING, ever -- not the one track the card names.
-- See the header for why the two differ. Level 1 is what every track starts at,
-- so "> 1" is a purchase and "== 1" is the shop having never been opened.
local function hasBought(player: Player): boolean
	for _, track in ipairs(ProgressionConfig.Tracks) do
		local level = tonumber(player:GetAttribute(PREFIX .. track.key))
		if level and level > 1 then
			return true
		end
	end
	return false
end

-- Lazily, exactly as saveService above -- and for the same reason: a tutorial
-- that cannot find the weight system should shrug and run big-bagged, not
-- stall a join over it.
local weightLoaded, WeightService = false, nil
local function weightService()
	if weightLoaded then
		return WeightService
	end
	weightLoaded = true
	local folder = ServerScriptService:FindFirstChild("WeightSystem")
	local moduleScript = folder and folder:FindFirstChild("WeightService")
	if moduleScript and moduleScript:IsA("ModuleScript") then
		local ok, result = pcall(require, moduleScript)
		if ok and type(result) == "table" and type(result.setMaxWeight) == "function" then
			WeightService = result
		else
			warn("[TutorialServer] WeightService present but would not load:", result)
		end
	end
	return WeightService
end

--[[
	THE SMALL BAG AND THE RICH LITTER -- armed and withdrawn as one unit.

	engage caps the bag at TutorialConfig.BagCap through WeightService's manual
	override (the Scrap Rush seam: it holds until Bucket Size next moves, and
	Bucket Size is a row the tutorial keeps locked), and publishes the per-item
	litter value -- the first rung of every track over TutorialConfig.TrashItems
	-- as an attribute CTBBridge reads at the pickup roll. Numbers on the
	player, not requires between systems: the seam Golden Hour already uses.

	disengage is guarded by the caller on whether the tutorial was ARMED, and
	that guard is load-bearing: finish() also runs for every restored veteran
	the moment their profile proves a purchase, and blindly resetting THEIR bag
	to the ladder would cancel a live Scrap Rush cap for anyone whose join
	happened to land mid-event.
]]
local function engage(player: Player)
	local WS = weightService()
	if WS then
		WS.setMaxWeight(player, TutorialConfig.BagCap)
	end
	local total = 0
	for _, track in ipairs(ProgressionConfig.Tracks) do
		total += ProgressionConfig.costFor(track, 1) or 0
	end
	player:SetAttribute(TutorialConfig.TrashValueAttribute,
		math.ceil(total / math.max(1, TutorialConfig.TrashItems)))

	--[[
		THE FLOOR: A NEW PLAYER STARTS ABLE TO AFFORD THE LESSON.

		The rigged litter above all but guarantees the money -- one piece of
		$360 trash outprices the $280 row -- but "all but" is not a word an
		onboarding gets to use, so the purse is topped up to the named track's
		first rung the moment the tutorial arms. Derived, not typed: if the
		shop reprices, the floor follows.

		A TOP-UP TO the cost, not a grant OF it, and the attribute is written
		directly rather than through SellServer.addCoins -- deliberately, on
		both counts. This is not earnings: routing it through the sell seam
		would bump TotalEarned, and TotalEarned is half of looksNew() -- a
		player who joined, armed and quit would come back looking like a
		veteran and never see the tutorial again. The Coins attribute is the
		balance's source of truth (SellServer's own note), so a straight write
		is the whole job.

		ONCE, AT ARM, not a standing floor. A floor that refilled while armed
		would let eggs be farmed at a discount (spend below the line, get
		topped back up, repeat); this way the guarantee costs at most one
		rung's price per tutorial, and a player who spends their bag money on
		eggs mid-tutorial recovers the honest way -- any single piece of the
		rigged trash covers the row.
	]]
	--[[
		THE FLOOR STAYS AT ONE RUNG, AND THE PET CARD DOES NOT CHANGE THAT.

		Checked on 2026-09-23, when the onboarding's new fourth card (HATCH YOUR
		FIRST PET, 500 coins) raised the obvious question: can a first-timer still
		afford the shop after buying an egg? Measured rather than assumed, on a
		live server:

		  sum of first rungs   1,440   (280 + 480 + 360 + 320)
		  rigged litter        360 a piece -- ceil(1440 / TrashItems)
		  first bag sells for  about 1,440
		  Basic egg            500
		  Sifter Width rung    280

		They reach the pet card holding roughly 1,440 and need 780 for both. There
		is no gap to close, so nothing is added here: a floor raised to cover the
		egg would hand every new account 500 coins it demonstrably does not need,
		and the 84% who skip that card are not skipping it for want of money.

		CAUTION FOR THE NEXT READER, since it cost a wrong answer once:
		ProgressionConfig.costFor takes the TRACK TABLE, not the key string. Called
		with a key it silently returns 100 for every track, which makes the sum look
		like 400 and this floor look inadequate. It is not.
	]]
	local first = ProgressionConfig.TrackByKey
		and ProgressionConfig.TrackByKey[TutorialConfig.FirstTrack]
	local firstCost = first and ProgressionConfig.costFor(first, 1)
	if type(firstCost) == "number" and firstCost > 0 then
		local coins = tonumber(player:GetAttribute("Coins")) or 0
		if coins < firstCost then
			player:SetAttribute("Coins", firstCost)
		end
	end
end

local function disengage(player: Player)
	player:SetAttribute(TutorialConfig.TrashValueAttribute, nil)
	local WS = weightService()
	if WS then
		WS.setMaxWeight(player,
			WeightConfig.capacityForLevel(player:GetAttribute(WeightConfig.CapacityLevelAttribute)))
	end
end

--[[
	THE STREAMING ESCORT. The send-off's island shots are filmed thousands of
	studs from the character, and under StreamingEnabled that camera sees the
	imposter meshes -- the potato island, not the island. ReplicationFocus is
	the engine's own answer: walk the focus to each stop and the server streams
	FULL detail there. The client asks per stage over OutroFocus; everything
	here is validation and cleanup:

	  * stages must exist in TutorialConfig.OutroStops (no free camera),
	  * asks only count inside a per-player window opened by a REAL tutorial
	    finish (a veteran, or a client fabricating the remote cold, is refused),
	  * the focus part dies with the window, with stage 0, and with the player,
	    whichever comes first -- a leaked focus is a permanent spying hole.
]]
local OUTRO_WINDOW = 120
local outroUntil: { [Player]: number } = setmetatable({}, { __mode = "k" })
local focusPart: { [Player]: BasePart } = setmetatable({}, { __mode = "k" })

local function releaseFocus(player: Player)
	if player.Parent then
		player.ReplicationFocus = nil
	end
	local part = focusPart[player]
	if part then
		part:Destroy()
		focusPart[player] = nil
	end
end

local function onOutroFocus(player: Player, payload)
	local stage = (type(payload) == "table") and tonumber(payload.stage) or nil
	if stage == nil then
		return
	end
	if stage <= 0 or os.clock() > (outroUntil[player] or 0) then
		releaseFocus(player)
		return
	end
	local stop = TutorialConfig.OutroStops[stage]
	if not stop then
		return
	end
	local part = focusPart[player]
	if not part then
		part = Instance.new("Part")
		part.Name = "OutroFocus"
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = 1
		part.Size = Vector3.one
		part.Parent = workspace
		focusPart[player] = part
	end
	part.Position = stop.centre + Vector3.new(0, stop.y or 0, 0)
	player.ReplicationFocus = part
end

local function finish(player: Player)
	-- Read BEFORE the clear below: "was the onboarding armed" is the guard on
	-- handing the bag back, and the credit attribute IS the armed flag.
	local wasArmed = player:GetAttribute(TutorialConfig.LumpsAttribute) ~= nil
	player:SetAttribute(TutorialConfig.DoneAttribute, true)
	-- Cleared rather than left standing: an unspent credit would keep biasing
	-- finds for a player who is plainly past needing it.
	player:SetAttribute(TutorialConfig.LumpsAttribute, nil)
	-- AND THE HOLD, if an admin blanked this account to walk the onboarding.
	-- This is the end condition the hold is named for: the wipe lasts until the
	-- tutorial is finished, and finishing it is this function. Clearing it here
	-- rather than in the panel means it lifts however the tutorial ends --
	-- bought on the first tide, or retired on a later join by hasBought.
	player:SetAttribute(TutorialConfig.HoldAttribute, nil)
	if wasArmed then
		disengage(player)
		-- The send-off, written LAST like the replay tick and for the same
		-- reason: by the time the client's cinematic wakes, the world it is
		-- celebrating -- the big bag back, the shop unlocked -- already stands.
		local n = tonumber(player:GetAttribute(TutorialConfig.CelebrateAttribute)) or 0
		player:SetAttribute(TutorialConfig.CelebrateAttribute, n + 1)
		-- The streaming escort answers only inside this window, and the window
		-- cleans up after itself even if the client dies mid-show.
		outroUntil[player] = os.clock() + OUTRO_WINDOW
		task.delay(OUTRO_WINDOW + 5, function()
			if player.Parent and os.clock() > (outroUntil[player] or 0) then
				releaseFocus(player)
			end
		end)
	end
end

local function track(player: Player, conn: RBXScriptConnection)
	local list = conns[player]
	if not list then
		list = {}
		conns[player] = list
	end
	table.insert(list, conn)
end

local function onJoin(player: Player)
	--[[
		THE STAMP IS WIRED FIRST AND UNCONDITIONALLY, before the profile wait
		below. A player who is not new needs no guarantee but still has to be
		able to finish -- and more to the point, `hasBought` is false for a
		brand new player at exactly the moment this runs, so a listener wired
		after the wait would miss a purchase made during it.
	]]
	track(player, player.AttributeChanged:Connect(function(name)
		if name:sub(1, #PREFIX) ~= PREFIX then
			return
		end
		if player:GetAttribute(TutorialConfig.DoneAttribute) then
			return
		end
		if hasBought(player) then
			finish(player)
		end
	end))

	task.spawn(function()
		-- Wrapped: this is onboarding, and it is not allowed to be the reason a
		-- join fails. Every other system on this player is already up.
		local ok, err = pcall(function()
			awaitProfile(player)
			if not player.Parent then
				return
			end
			-- A restored profile that has already bought something retires the
			-- tutorial here, which is what upgrades every player who was already
			-- playing before this field existed.
			if hasBought(player) then
				finish(player)
				return
			end
			if not TutorialConfig.looksNew(player) then
				return
			end
			player:SetAttribute(TutorialConfig.LumpsAttribute, TutorialConfig.LumpGrant)
			-- The wash bay is where the measured drop-off is, so a new player
			-- gets an easier jet for their first few lumps. TutorialConfig
			-- carries the whole argument and both halves of the number.
			player:SetAttribute(TutorialConfig.WashBoostAttribute,
				TutorialConfig.WashBoostGrant)
			-- The small bag and the rich litter arm with the credits; finish()
			-- withdraws all of it in one breath.
			engage(player)
		end)
		if not ok then
			warn("[CleanTheBeach] tutorial did not arm: " .. tostring(err))
		end
	end)
end

local function onLeave(player: Player)
	local list = conns[player]
	if not list then
		return
	end
	for _, conn in ipairs(list) do
		conn:Disconnect()
	end
	conns[player] = nil
end

--[[
	PLAY THE ONBOARDING AGAIN, ON AN ACCOUNT THAT HAS ALREADY FINISHED IT.

	THE SAVED FLAG IS THE ONE THAT COUNTS. `tutorialDone` is held once set --
	SaveService ORs the attribute with the stored value on capture precisely so
	a save racing a join cannot write a false over a true -- so clearing the
	ATTRIBUTE alone buys a reset that lasts until the next rejoin, at which
	point apply() stamps it straight back. SaveService.clearOneTimeFlag is the
	whitelisted door out of that, and it exists for exactly this.

	IT DOES NOT TOUCH COINS, LEVELS OR PETS. Replaying the tutorial is a
	question about the CARD and the crusted finds in front of it, not about
	unwinding somebody's run -- and a tester who wants a truly blank account
	has the admin panel's other verbs for that. One consequence worth knowing:
	on an account that has already bought upgrades, the done-stamp listener in
	onJoin will retire the tutorial again the moment any track moves, which is
	the correct behaviour and is also what the last step of the card asks for.

	Returns (ok, phrase) in the shape the admin panel's givers use.
]]
function TutorialServer.restart(player: Player): (boolean, string)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, "No such player."
	end

	local persisted = false
	local Save = saveService()
	if Save and type(Save.clearOneTimeFlag) == "function" then
		persisted = Save.clearOneTimeFlag(player, "tutorialDone") == true
	end

	player:SetAttribute(TutorialConfig.DoneAttribute, nil)
	player:SetAttribute(TutorialConfig.LumpsAttribute, TutorialConfig.LumpGrant)
	player:SetAttribute(TutorialConfig.WashBoostAttribute, TutorialConfig.WashBoostGrant)
	engage(player)

	--[[
		THE EDGE THE CARD WATCHES, and it is written LAST on purpose: TutorialHud
		re-reads nothing when it re-shows, so the lump credit and the easy wash
		have to already be standing when the tick it is watching arrives.

		Incremented rather than set to true, so a second restart in the same
		session is a second event rather than a value that was already there.
	]]
	local n = tonumber(player:GetAttribute(TutorialConfig.ReplayAttribute)) or 0
	player:SetAttribute(TutorialConfig.ReplayAttribute, n + 1)

	print(("[TutorialServer] restarted the tutorial for %s (saved flag %s)")
		:format(player.Name, persisted and "cleared" or "NOT cleared"))
	return true, persisted and "tutorial restarted"
		or "tutorial restarted (this session only -- no save)"
end

function TutorialServer.start()
	assert(RunService:IsServer(), "[TutorialServer] server-only")
	if started then
		return
	end
	started = true

	Net.get("OutroFocus").OnServerEvent:Connect(onOutroFocus)

	Players.PlayerAdded:Connect(onJoin)
	Players.PlayerRemoving:Connect(function(player)
		releaseFocus(player)
		onLeave(player)
	end)
	-- Anyone already in. ServerMain starts this late enough that a fast joiner
	-- on a fresh server can beat it, and that player is precisely the one most
	-- likely to be new.
	for _, player in ipairs(Players:GetPlayers()) do
		onJoin(player)
	end
end

return TutorialServer
