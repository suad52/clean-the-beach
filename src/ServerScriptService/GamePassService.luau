--[[
	GamePassService  --  ServerScriptService.GamePassService

	Who owns which game pass, and what owning one does. THE FIRST MONETISATION
	CODE IN THIS GAME -- there was none before it, so the shape it sets here is
	the shape the next pass will copy.

	IT SERVES TWO KINDS OF PASS, AND THEY ARE NOT THE SAME SHAPE.

	  TIER PASSES   AtvConfig.Tiers. A pass here means "you own that machine",
	                so it writes into the SAME attribute a coin purchase writes
	                and every existing ownership check keeps working untouched.
	                See the next block.

	  FLAT PASSES   PassConfig.Passes. A pass here unlocks a VERB rather than a
	                thing -- Instant Wash is the first -- so there is no ladder
	                to raise and no floor to re-assert. It writes one boolean
	                attribute for the HUD to paint a button off, and records the
	                real answer where only the server can read it.

	The second kind is the one the header used to say would need "a second
	`apply` and no new plumbing", and that turned out to be right: it shares the
	ownsPass retry, the price publishing and the purchase callback below, and
	adds one table and one accessor.

	OWNING A PASS IS NOT A SECOND KIND OF OWNERSHIP
	-----------------------------------------------
	This is the load-bearing decision in the file. A pass writes the tier's id
	into `AtvTier` -- the SAME attribute a coin purchase writes -- rather than
	adding a parallel "or they have the pass" clause to every check. So
	AtvServer.spawn, AtvServer.buy, the showroom's SPAWN/BUY state and
	RewardsConfig's "Own a vehicle" quest all keep working untouched, and there
	stays exactly ONE definition of what a player owns.

	EXACTLY ONE READER NOW NEEDS MORE THAN THAT ATTRIBUTE, and it is worth
	knowing why the trick stops there. Everything above works because a pass
	RAISES `AtvTier` and every reader just asks the attribute. Since 2026-08-24
	ProgressionServer.onRebirth LOWERS it -- the tide takes a coin-bought machine
	-- and "is this player exempt" is a question the attribute cannot answer
	about itself, because by the time you read it, it has already been written.
	That one caller therefore asks this module directly (owns / tiersKnown /
	refreshTiers). It is the only exception and it should stay the only one: a
	second destructive reader is how the single definition above quietly becomes
	two.

	It bypasses the rebirth gate as a consequence rather than as a special case:
	spawn() has never checked rebirths, only ownership. blockedReason is the
	BUYING gate, and somebody who already owns the thing never reaches it.

	THE FLOOR IS RE-ASSERTED, NOT SET ONCE
	--------------------------------------
	Three things write AtvTier on join -- AtvServer's PlayerAdded default,
	SaveService's load, and this -- and their order is not guaranteed. Rather
	than guess at it, this records what the player's passes ENTITLE them to and
	watches the attribute: anything that writes a lower value gets the floor put
	back. It only ever raises, so it cannot fight the save file (a save of 4
	outranks a tier-3 pass and is left alone) and it cannot loop (re-writing the
	value it already holds fires no change signal).

	THE PASSES ARE OFF SALE AS THIS IS WRITTEN
	------------------------------------------
		1953498888  "Bulldozer"  -> Sandhog D10   (tier 3)
		1953742878  "Truck"      -> Tidebreaker   (tier 4)

	Both exist and both belong to this place's group, but both have IsForSale =
	false and no Robux price, and NO AMOUNT OF CODE FIXES THAT -- Roblox will not
	sell an off-sale pass, so PromptGamePassPurchase opens a dialog the player
	cannot complete. They have to be put on sale with a price in the Creator
	Dashboard. checkForSale() below says so in the output at every boot, loudly,
	until they are; the moment they go on sale the price appears on the buttons
	and the purchase works with no code change.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local AtvConfig = require(ReplicatedStorage:WaitForChild("AtvConfig"))
local PassConfig = require(Modules:WaitForChild("PassConfig"))
local Net = require(Modules:WaitForChild("Net"))

local GamePassService = {}

-- What a panel reads to draw a price on a Robux button. A folder of
-- attributes rather than a RemoteEvent push: it replicates on its own, it is
-- there before any client asks, and a client joining late gets it for free.
--
-- Named for the car showroom because that is what it served first, and keyed
-- by pass ID rather than by anything car-shaped -- which is why the wash pass
-- moved in with no change to it at all. PassConfig.InfoFolder is the same
-- string; the two must not drift.
local INFO_FOLDER = PassConfig.InfoFolder

-- Highest tier id each player's passes entitle them to. The floor this module
-- keeps putting back.
local entitled: { [Player]: number } = {}
--[[
	DID ROBLOX ACTUALLY ANSWER ABOUT THE TIER PASSES, as opposed to "the floor is
	still 0"? These are not the same statement and the difference became
	destructive on 2026-08-24.

	`entitled` collapses three outcomes into one number: owns (raised), does not
	own (left at 0), and COULD NOT ASK (also left at 0). That was harmless for as
	long as the floor was only ever used to RAISE `AtvTier` -- an unresolved
	lookup simply failed to grant something, and the next join tried again, which
	is exactly what the note above `ownsPass` promises.

	ProgressionServer.onRebirth now reads the entitlement to decide whether to
	WIPE a machine, and there "we could not ask" collapsing to "they do not own
	it" destroys a Robux purchase and persists the loss through SaveService. So
	the third outcome has to be visible from outside, and this is it: true only
	once every tier pass has come back with a definite yes or no.
]]
local tiersKnown: { [Player]: boolean } = {}

--[[
	THE SERVER'S OWN RECORD OF THE FLAT PASSES, and the only one that decides
	anything.

	There is a replicated attribute saying the same thing -- resolve() writes it
	so a HUD can paint a button -- and it is deliberately not what gets read
	when a paying player asks for the thing they paid for. An attribute is a
	statement on a Player instance; this is what Roblox answered.

	A MISSING ENTRY IS NOT A `false`. It means nobody has asked yet, or the ask
	failed -- and those two have to be distinguishable from a genuine no, or a
	network blip during somebody's join quietly revokes the pass they bought
	for the rest of the session. ownsPassId's refresh path exists for exactly
	that case: a miss re-asks rather than answering from the hole.
]]
local flat: { [Player]: { [number]: boolean } } = {}

--[[
	PASSES ROBLOX TOLD US, THIS SESSION, THAT THIS PLAYER JUST BOUGHT.

	This exists because UserOwnsGamePassAsync IS CACHED, and the cache is warmed
	by the join sweep with the answer "no" -- which is correct at the time and
	wrong the instant they buy. Re-asking on PromptGamePassPurchaseFinished can
	therefore come back "no" for a pass the player has this second paid for, and
	then everything downstream is consistent and wrong: the attribute never
	changes, so StarterPackService's watcher never fires, so the pack is never
	handed over. The player has paid and been given nothing, and the only cure is
	to rejoin -- which nobody thinks to do, because nothing tells them to.

	So the purchase EVENT is the authority for the rest of the session, and the
	web call is only ever allowed to upgrade a "no" to a "yes", never the reverse.
	That is safe: PromptGamePassPurchaseFinished is raised by the engine on the
	SERVER, not sent up by the client, so `wasPurchased` is not a client claim.
	The next join re-asks from cold and is the real reconciliation.
]]
local purchased: { [Player]: { [number]: boolean } } = {}

local watchers: { [Player]: RBXScriptConnection } = {}
local connections = {}
local started = false

----------------------------------------------------------------
-- ASKING ROBLOX
----------------------------------------------------------------
--[[
	Both of these are web calls and both can throw -- a dropped request must not
	become "you do not own the thing you paid for", so every one is pcall'd and
	a failure is reported as UNKNOWN rather than as false.

	That distinction matters more than it looks. Treating a failed lookup as
	"does not own" would quietly revoke a paying player's machine for the length
	of a network blip; treating it as unknown leaves whatever they already had
	alone and tries again next join.
]]
local function ownsPass(userId: number, passId: number): boolean?
	for attempt = 1, 3 do
		local ok, result = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(userId, passId)
		end)
		if ok then
			return result == true
		end
		if attempt < 3 then
			task.wait(attempt * 2)
		else
			warn(string.format("[GamePassService] could not read pass %d for user %d: %s",
				passId, userId, tostring(result)))
		end
	end
	return nil
end

local function productInfo(passId: number)
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(passId, Enum.InfoType.GamePass)
	end)
	return ok and info or nil
end

----------------------------------------------------------------
-- PUBLISHING WHAT A PASS COSTS
----------------------------------------------------------------
local function ensureInfoFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild(INFO_FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = INFO_FOLDER
		folder.Parent = ReplicatedStorage
	end
	return folder
end

--[[
	Read once at boot and published for the panel.

	PRICE IS ALLOWED TO BE ABSENT and the panel is built to cope: an off-sale
	pass has no PriceInRobux at all, so the button draws without a figure rather
	than drawing "R$ 0" -- which would read as free and is the one wrong thing a
	price label can say.
]]
local function publishOne(folder: Folder, id: number, what: string, offSale: { string })
	local info = productInfo(id)
	local key = tostring(id)
	if info then
		folder:SetAttribute("Name_" .. key, tostring(info.Name))
		folder:SetAttribute("ForSale_" .. key, info.IsForSale == true)
		-- Only when it is a real number. SetAttribute(nil) CLEARS, which is
		-- exactly what a pass taken off sale should do to a stale price.
		folder:SetAttribute("Price_" .. key,
			(type(info.PriceInRobux) == "number") and info.PriceInRobux or nil)
		if info.IsForSale ~= true or type(info.PriceInRobux) ~= "number" then
			table.insert(offSale, string.format("%s (%d) for the %s",
				tostring(info.Name), id, what))
		end
	else
		folder:SetAttribute("ForSale_" .. key, false)
		folder:SetAttribute("Price_" .. key, nil)
		table.insert(offSale, string.format("%d for the %s -- LOOKUP FAILED", id, what))
	end
end

local function publishPassInfo()
	local folder = ensureInfoFolder()
	local offSale = {}
	local unmade = {}

	for _, entry in AtvConfig.allPasses() do
		publishOne(folder, entry.id, entry.tier.name, offSale)
	end
	-- Same folder, same attribute names, same warning. A flat pass is off sale
	-- in exactly the way a car pass is, and it fails to sell in exactly the
	-- same way, so it has no business having its own report.
	--
	-- A pass that HAS NOT BEEN CREATED YET is a different thing from one that is
	-- off sale, and it is reported separately below rather than folded into that
	-- list: "turn it on in the dashboard" and "make it in the dashboard" are two
	-- different jobs. Asking about id 0 would also only ever produce a LOOKUP
	-- FAILED line saying nothing, because GetProductInfo throws on it.
	for _, entry in PassConfig.all() do
		if PassConfig.isLive(entry) then
			publishOne(folder, entry.id, entry.name .. " pass", offSale)
		else
			table.insert(unmade, entry.name)
		end
	end

	if #offSale > 0 then
		warn("[GamePassService] ------------------------------------------------")
		warn("[GamePassService] THESE GAME PASSES CANNOT BE BOUGHT. Nothing in the")
		warn("[GamePassService] code can change that -- Roblox will not sell a pass")
		warn("[GamePassService] that is off sale, so the R$ button opens a dialog")
		warn("[GamePassService] the player cannot complete:")
		for _, line in offSale do
			warn("[GamePassService]     " .. line)
		end
		warn("[GamePassService] Fix: Creator Dashboard -> this experience ->")
		warn("[GamePassService] Monetization -> Passes -> set a price and turn")
		warn("[GamePassService] 'Item for Sale' on. No code change is needed after.")
		warn("[GamePassService] The coin prices work regardless.")
		warn("[GamePassService] ------------------------------------------------")
	end

	-- A `print`, not a `warn`. Nothing here is broken and nothing is being sold
	-- badly: an unmade pass draws as an inert SOON row and cannot take anybody's
	-- Robux. It is a note that a finished feature is waiting on one number.
	if #unmade > 0 then
		print(string.format(
			"[GamePassService] %d pass(es) are written but not yet created on the "
			.. "Creator Dashboard, so they show as SOON and cannot be bought: %s. "
			.. "Create each one, paste its id into PassConfig, set a price and turn "
			.. "'Item for Sale' on -- no code change is needed after that.",
			#unmade, table.concat(unmade, ", ")))
	end
end

----------------------------------------------------------------
-- THE FLOOR
----------------------------------------------------------------
local function applyFloor(player: Player)
	local floor = entitled[player]
	if not floor or floor <= 0 or not player.Parent then
		return
	end
	local current = tonumber(player:GetAttribute(AtvConfig.OwnedAttribute)) or 0
	if current < floor then
		-- Raise only. A save file that outranks the pass is left where it is.
		player:SetAttribute(AtvConfig.OwnedAttribute, floor)
	end
end

-- Tell the player, through the showroom's own toast channel if it is up yet.
-- Reached lazily and optionally, the way VehicleHold reaches the weight system:
-- this module must not care whether AtvServer has started.
local function tell(player: Player, message: string)
	local folder = ReplicatedStorage:FindFirstChild("AtvRemotes")
	local event = folder and folder:FindFirstChild("AtvResult")
	if event and event:IsA("RemoteEvent") then
		event:FireClient(player, { ok = true, message = message })
	end
end

--[[
	One pass, one player, one answer -- and it writes THREE things:

		the Pass_<id> attribute   what the panel paints its button off
		the entitlement floor     what keeps AtvTier from being written down
		AtvTier itself            via applyFloor

	`announce` is false for the join sweep and true for a live purchase. Telling
	somebody they own a thing they bought last week, every time they join, is
	noise; telling them the moment the Robux leaves is the confirmation.
]]
local function resolve(player: Player, entry, announce: boolean)
	-- A pass bought this session is not re-asked about at all: the cache can
	-- still be saying "no", and a yielding web call whose answer we would throw
	-- away is a delay on the one path where the player is watching. See
	-- `purchased`.
	local bought = purchased[player]
	local owns = (bought and bought[entry.id]) or ownsPass(player.UserId, entry.id)
	if owns == nil or not player.Parent then
		-- UNKNOWN. Everything is left exactly as it was, INCLUDING the flag: one
		-- unanswered tier is enough to make the whole entitlement unsafe to wipe
		-- against, so the sweep below can only ever set it true if no entry took
		-- this branch.
		return
	end

	local attr = AtvConfig.passAttribute(entry.tier)
	if attr then
		player:SetAttribute(attr, owns)
	end
	if not owns then
		return
	end

	entitled[player] = math.max(entitled[player] or 0, entry.tier.id)
	applyFloor(player)

	if announce then
		tell(player, string.format("%s unlocked \u{2014} it is yours for good. Spawn it at the pad.",
			entry.tier.name))
	end
end

--[[
	THE FLAT PASSES. One attribute, one record, and no floor to keep putting
	back -- there is no ladder here for a save file to outrank.

	The UNKNOWN case is handled the same way it is above and for the same
	reason: a dropped web request leaves everything exactly as it was rather
	than writing `false` over a pass somebody owns. What differs is who pays
	for being wrong. A tier pass that resolves late costs a button that says
	BUY for a second; a flat pass that resolves late costs the same button AND
	a refused first tap, so ownsPassId re-asks on the miss rather than waiting
	for the next join.
]]
local function resolveFlat(player: Player, entry, announce: boolean)
	--[[
		A PASS THAT DOES NOT EXIST IS NOT ASKED ABOUT, and its attribute is LEFT
		ALONE rather than written false.

		Asking would be three UserOwnsGamePassAsync throws with a 2s and then a 4s
		backoff between them -- per player, on every single join -- for an answer
		that cannot be anything but no.

		Not writing `false` is the half that matters later: it is what lets a
		Studio-only dev unlock write `true` onto the attribute and have it stick
		(see SandbotService). On a live server nothing writes it at all, so it reads
		nil -- which PassConfig.owns and every panel already treat as "no".
	]]
	if not PassConfig.isLive(entry) then
		return
	end

	-- Bought this session: believed outright, and not re-asked. See `purchased`.
	local bought = purchased[player]
	local owns = (bought and bought[entry.id]) or ownsPass(player.UserId, entry.id)
	if owns == nil or not player.Parent then
		return      -- unknown: leave everything exactly as it was
	end

	local record = flat[player]
	if record then
		record[entry.id] = owns
	end
	player:SetAttribute(entry.attribute, owns)

	-- Notify, not the showroom's AtvResult channel. A wash pass has no business
	-- announcing itself through the car panel's remote, and Notify is the
	-- game-wide toast every other system already speaks.
	if owns and announce then
		Net.get("Notify"):FireClient(player, {
			text = string.format("%s unlocked \u{2014} %s", entry.name, entry.blurb),
			kind = "level",
		})
	end
end

local function sweep(player: Player, announce: boolean)
	--[[
		THE TIER SWEEP REPORTS WHETHER IT ACTUALLY GOT ANSWERS, and it is counted
		here rather than inside resolve() because the question is about the SET:
		"is this player's machine entitlement safe to wipe against" is only true
		if every tier pass came back definite. resolve() sees one entry and cannot
		answer it.

		Re-asked on every sweep rather than latched once. sweep() runs on join and
		again after a purchase, so a player whose join hit a network blip has the
		flag corrected the next time anything asks -- which is the same
		"try again later, revoke nothing now" shape ownsPass itself uses.
	]]
	local answered = true
	for _, entry in AtvConfig.allPasses() do
		resolve(player, entry, announce)
		-- resolve() writes the Pass_<id> attribute on ANY definite answer and
		-- returns without touching anything on an unknown, so the attribute is
		-- the honest record of whether this entry was answered.
		local attr = AtvConfig.passAttribute(entry.tier)
		if attr and typeof(player:GetAttribute(attr)) ~= "boolean" then
			answered = false
		end
	end
	if answered then
		tiersKnown[player] = true
	end

	for _, entry in PassConfig.all() do
		resolveFlat(player, entry, announce)
	end
end

--[[
	RE-ASKING ABOUT A PASS WE BELIEVE THEY DO NOT OWN, AND WHY THAT IS A THING
	THIS FILE HAS TO DO AT ALL.

	PromptGamePassPurchaseFinished only fires for a prompt THIS server raised.
	A player who buys from the Roblox app's Store tab -- one tap off the
	experience page, and a normal way to buy on a phone -- completes the whole
	purchase somewhere this server cannot see. Nothing fires, the join sweep's
	`false` stands, and the pass is inert for the rest of their session while
	the shop goes on drawing a BUY button at them. That is the shape of the
	2026-09-06 report: "I purchased instant wash and it's not working."

	RATIONED, because ownsPass yields and retries with backoff. One ask per
	pass per player per REASK_GAP, tracked here rather than by each caller so
	the two callers below cannot add up to a flood between them.

	IT MAY NOT WIN, AND THAT IS UNDERSTOOD. UserOwnsGamePassAsync is cached per
	server and the join sweep warmed that cache with "no" -- which is why the
	header above says the next join is the real reconciliation. When the cache
	turns over, this catches it inside a minute and the player never has to
	learn the word "rejoin". When it does not, the REFUSAL MESSAGE is what has
	to carry them, and that is why ownsPassId now reports whether its `false`
	was an answer or a hole.
]]
local REASK_GAP = 30
local lastAsk: { [Player]: { [number]: number } } = {}

local function reaskFlat(player: Player, entry): boolean
	if not (PassConfig.isLive(entry) and player.Parent) then
		return false
	end
	-- Owned is settled and is never re-asked. An UNKNOWN is left alone too: it
	-- means the join sweep got no answer, and its own retry owns that case --
	-- re-asking here would race it for the same web call.
	local record = flat[player]
	if not (record and record[entry.id] == false) then
		return false
	end

	local seen = lastAsk[player]
	if not seen then
		return false
	end
	local now = os.clock()
	if now - (seen[entry.id] or -math.huge) < REASK_GAP then
		return false
	end
	seen[entry.id] = now

	-- announce = true: somebody who bought this outside the game and has been
	-- playing without it deserves to be told the moment it lands.
	resolveFlat(player, entry, true)   -- YIELDS
	return true
end

-- Public so a caller answering a button the player just pressed can force the
-- question without knowing how the rationing works. Returns whether it asked.
function GamePassService.reask(player: Player, key: string): boolean
	local entry = PassConfig.get(key)
	return entry ~= nil and reaskFlat(player, entry)
end

--[[
	THE SLOW LOOP, for the player who buys outside and then simply plays.

	SEQUENTIAL, never a fan-out: each pass is asked and waited on in turn, so a
	Roblox outage costs this thread its backoff rather than costing the server
	four threads per player all backing off at once.

	IT ENDS ITSELF once there is nothing left to ask about -- every live pass
	either owned or still unknown -- so the steady state for a player who owns
	everything, and for one who owns nothing and never buys, is the same: no
	standing cost beyond one pass over the table.
]]
local RECONCILE_EVERY = 60

local function reconcileLoop(player: Player)
	task.spawn(function()
		-- Staggered off the user id so a full server does not wake together.
		task.wait(RECONCILE_EVERY * (0.5 + 0.5 * ((player.UserId % 97) / 97)))
		while player.Parent do
			local outstanding = false
			for _, entry in PassConfig.all() do
				if not player.Parent then
					return
				end
				local record = flat[player]
				if PassConfig.isLive(entry) and record and record[entry.id] == false then
					outstanding = true
					reaskFlat(player, entry)   -- YIELDS
				end
			end
			if not outstanding then
				return
			end
			task.wait(RECONCILE_EVERY)
		end
	end)
end

local function onPlayerAdded(player: Player)
	entitled[player] = entitled[player] or 0
	lastAsk[player] = lastAsk[player] or {}
	-- FALSE UNTIL PROVEN, and the sweep below is off the join thread -- so for
	-- the first moments of a session the answer to "is the entitlement known" is
	-- honestly no. Anything that wipes against it must treat that as "do not
	-- wipe", not as "they own nothing".
	tiersKnown[player] = tiersKnown[player] or false
	flat[player] = flat[player] or {}
	purchased[player] = purchased[player] or {}

	-- Put the floor back after anything else writes AtvTier. See the header:
	if watchers[player] then
		watchers[player]:Disconnect()
	end
	watchers[player] = player:GetAttributeChangedSignal(AtvConfig.OwnedAttribute)
		:Connect(function()
			applyFloor(player)
		end)

	-- Off the join thread: three web calls must not hold up everything else
	-- hanging off PlayerAdded.
	task.spawn(sweep, player, false)
	-- ...and then keep asking about whatever came back no. See reaskFlat.
	reconcileLoop(player)
end

local function onPlayerRemoving(player: Player)
	if watchers[player] then
		watchers[player]:Disconnect()
		watchers[player] = nil
	end
	entitled[player] = nil
	tiersKnown[player] = nil
	flat[player] = nil
	purchased[player] = nil
	lastAsk[player] = nil
end

----------------------------------------------------------------
-- API
----------------------------------------------------------------
-- Does this player own the pass for this tier? The SERVER's answer, off the
-- entitlement this module resolved -- never off the replicated attribute,
-- which is the client's copy and is only ever used to paint a button.
function GamePassService.owns(player: Player, tier): boolean
	local id = AtvConfig.passOf(tier)
	if not id or not tier then
		return false
	end
	return (entitled[player] or 0) >= tier.id
end

--[[
	Has Roblox actually answered about this player's TIER passes yet?

	FALSE means "we do not know", which is NOT the same as owns() returning false
	and must never be treated as it. The only caller that needs the distinction
	is ProgressionServer.onRebirth, because it is the only thing in the game that
	acts DESTRUCTIVELY on the entitlement -- everything else merely fails to
	grant something and gets another chance on the next sweep.

	See the note on `tiersKnown` for why the flag has to exist at all, and the
	one on `ownsPass` for the rule it is protecting: a dropped web request must
	not revoke a pass somebody paid for.
]]
function GamePassService.tiersKnown(player: Player): boolean
	return tiersKnown[player] == true
end

--[[
	Re-ask Roblox about this player's tier passes, right now, and say whether the
	answer is trustworthy. YIELDS -- ownsPass backs off 2s then 4s across three
	attempts, so a fully failing lookup costs about six seconds.

	That cost is acceptable at the ONE call site this exists for (a rebirth is a
	rare, deliberate, once-a-tide act) and would not be anywhere else. Do not
	reach for this on a hot path; use owns()/tiersKnown() there.
]]
function GamePassService.refreshTiers(player: Player): boolean
	for _, entry in AtvConfig.allPasses() do
		resolve(player, entry, false)
		if not player.Parent then
			return false
		end
		local attr = AtvConfig.passAttribute(entry.tier)
		if attr and typeof(player:GetAttribute(attr)) ~= "boolean" then
			return false
		end
	end
	tiersKnown[player] = true
	return true
end

--[[
	Does this player own this FLAT pass? The server's answer, and the only one
	anything is allowed to act on.

	It never reads the replicated attribute. That attribute exists so a HUD can
	decide whether to draw BUY or USE; it is a statement written onto a Player,
	and the whole point of asking here is to not take a statement.

	`refresh` RE-ASKS ROBLOX WHEN THE ANSWER IS NOT ALREADY YES, AND YIELDS.
	Pass it true only from somewhere a player is already waiting on a button
	they pressed, and only behind a cooldown -- it is a web call, and a caller
	that can be spammed without one turns a remote into a way to make this
	server hammer UserOwnsGamePassAsync.

	Without it the failure is quiet and nasty: ownsPass reports a dropped
	request as UNKNOWN rather than as false, so a player whose join sweep hit a
	blip has no entry at all -- and every tap of a pass they genuinely bought
	would be refused until they rejoined.
]]
--[[
	SECOND RETURN: `known` -- IS THAT `false` AN ANSWER, OR A HOLE?

	The boolean has to stay a boolean, because a caller deciding whether to hand
	something over must treat "we could not ask" as "do not hand it over". But a
	caller deciding what to SAY has a third case, and conflating it with `no` is
	how this function came to tell a paying customer "you do not own it yet".

		false, true    Roblox answered, and the answer is no. Offer to sell it.
		false, false   the web call failed, or nothing has asked yet. Say so.
		true,  true    owned.

	Extra returns are dropped by any caller that takes one value, so every
	existing call site is unchanged.
]]
function GamePassService.ownsPassId(player: Player, passId: number, refresh: boolean?): (boolean, boolean)
	-- `<= 0` is the placeholder id of a pass that has not been created yet (see
	-- PassConfig.isLive). It matters HERE rather than only in the join sweep
	-- because `refresh` reaches Roblox: without this, every tap of an unmade
	-- pass's button would make this server throw its way through three
	-- UserOwnsGamePassAsync retries with backoff, for an answer that is no.
	--
	-- KNOWN, not unknown: a pass that does not exist is one nobody owns, and
	-- that is a definite answer rather than a lookup we skipped.
	if type(passId) ~= "number" or passId <= 0 then
		return false, true
	end
	local record = flat[player]
	if record and record[passId] == true then
		return true, true
	end
	-- Bought this session. Checked even though resolveFlat writes the record a
	-- moment later, because "a moment later" is not good enough for a caller that
	-- is answering a button the player is looking at.
	local bought = purchased[player]
	if bought and bought[passId] then
		return true, true
	end
	if not refresh then
		-- A RECORDED `false` IS AN ANSWER; A MISSING ENTRY IS NOT. resolveFlat
		-- writes the record only on a definite answer and returns without
		-- touching anything on an unknown, so the presence of the key is exactly
		-- "Roblox has told us about this one".
		return false, record ~= nil and record[passId] == false
	end

	local owns = ownsPass(player.UserId, passId)   -- YIELDS
	if owns == nil or not player.Parent then
		-- THREE THROWS WITH BACKOFF, OR THEY LEFT MID-CALL. Not an answer, and
		-- the caller must not print one.
		return false, false
	end

	-- Re-read rather than reusing `record`: the player may have left and
	-- rejoined while the web call was out, and writing into the table they had
	-- on the way in would be writing into a table nothing reads any more.
	local live = flat[player]
	if live then
		live[passId] = owns
	end
	for _, entry in PassConfig.all() do
		if entry.id == passId then
			player:SetAttribute(entry.attribute, owns)
		end
	end
	return owns, true
end

-- Convenience over the above, so a caller names the pass rather than repeating
-- its number. `key` is a PassConfig.Passes key. Carries the `known` flag
-- through -- see the note on ownsPassId.
function GamePassService.ownsFlat(player: Player, key: string, refresh: boolean?): (boolean, boolean)
	local entry = PassConfig.get(key)
	if not entry then
		-- A key this build does not define. Definite, and not a lookup failure.
		return false, true
	end
	return GamePassService.ownsPassId(player, entry.id, refresh)
end

--[[
	PRETEND A PASS WAS BOUGHT.  STUDIO ONLY, ENFORCED HERE RATHER THAN TRUSTED.

	This exists because THE PEOPLE WHO MAKE THE GAME CANNOT BUY ITS PASSES.
	Roblox will not sell you an item you are the seller of, and these are group
	assets on the group that owns the place -- so for anybody with a stake in
	Group 4620487, UserOwnsGamePassAsync answers `false` forever and every path
	that hangs off a pass is dead code they can never walk through. Testing the
	Starter Pack meant owning a second account.

	It takes the same route a real purchase does -- the session `purchased`
	record -- so what gets tested is the real flow and not a special case: the
	attribute flips exactly as it would for a customer, and StarterPackService
	hears it through its own watcher with no idea anything was staged.

	The IsStudio guard is not a reminder, it is the mechanism. On a live server
	this function returns false and writes nothing, so shipping a call to it by
	accident cannot give anybody a pass.
]]
function GamePassService.setOwnedForTesting(player: Player, passId: number): boolean
	if not RunService:IsStudio() then
		warn("[GamePassService] setOwnedForTesting is Studio-only and did nothing.")
		return false
	end
	if type(passId) ~= "number" or not player.Parent then
		return false
	end
	local bought = purchased[player]
	if not bought then
		return false
	end
	bought[passId] = true
	for _, entry in PassConfig.all() do
		if entry.id == passId then
			resolveFlat(player, entry, false)
			return true
		end
	end
	for _, entry in AtvConfig.allPasses() do
		if entry.id == passId then
			resolve(player, entry, false)
			return true
		end
	end
	return false
end

function GamePassService.start()
	assert(RunService:IsServer(), "[GamePassService] server-only")
	if started then
		return
	end
	started = true

	-- The FOLDER synchronously, the PRICES on a thread. The panel waits on the
	-- folder existing and copes with an attribute arriving late, so creating it
	-- up front means a client that opens the shop during the first second gets a
	-- button that fills itself in rather than no button at all.
	ensureInfoFolder()
	task.spawn(publishPassInfo)

	connections[#connections + 1] = Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	connections[#connections + 1] = Players.PlayerRemoving:Connect(onPlayerRemoving)

	--[[
		THE PURCHASE ITSELF.

		`wasPurchased` is not taken on trust -- it is the signal to go and ASK
		Roblox, not the answer. It is a client-driven callback, and re-resolving
		costs one web call at the only moment a player is guaranteed to be
		waiting for something to happen anyway.
	]]
	connections[#connections + 1] = MarketplaceService.PromptGamePassPurchaseFinished
		:Connect(function(player: Player, passId: number, wasPurchased: boolean)
			if not wasPurchased then
				--[[
					"THE DIALOG CLOSED WITHOUT A SALE" IS NOT NOTHING, AND
					DISCARDING IT USED TO STRAND THE ONE PLAYER IT MATTERS FOR.

					Roblox raises this with wasPurchased = false for an ordinary
					cancel -- and for the case that produced the 2026-09-06 report:
					a player who ALREADY OWNS the pass is shown "you already own
					this item" and no sale happens. That is the strongest evidence
					this server will ever get that its own record is wrong:
					somebody is trying to buy a thing we believe they lack, and
					Roblox is refusing to sell it to them.

					So it is re-asked rather than dropped. A genuine cancel costs
					one lookup that changes nothing and is rationed to one per
					REASK_GAP anyway; an already-owner is corrected on the spot
					instead of playing on with a pass they paid for and cannot use.
				]]
				for _, entry in PassConfig.all() do
					if entry.id == passId then
						task.spawn(reaskFlat, player, entry)
					end
				end
				return
			end
			--[[
				RECORDED BEFORE ANYTHING ELSE, and synchronously.

				This is the line that makes the difference between a player who
				pays and is served and a player who pays and is not. Everything
				below now resolves off it instead of off a cache that was warmed
				with "no" during their join and has not expired yet.
			]]
			local bought = purchased[player]
			if bought then
				bought[passId] = true
			end
			for _, entry in AtvConfig.allPasses() do
				if entry.id == passId then
					task.spawn(resolve, player, entry, true)
				end
			end
			for _, entry in PassConfig.all() do
				if entry.id == passId then
					task.spawn(resolveFlat, player, entry, true)
				end
			end
		end)
end

return GamePassService