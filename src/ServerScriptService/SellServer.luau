--[[
	SellServer  --  ServerScriptService.SellServer
	(this is the module the design doc calls "SellStationManager")

	Owns leaderstats.Coins and every counter is the only path by which a player
	can gain cash.

	SECURITY SHAPE
	--------------
	There is NO remote here. Selling is driven entirely by a ProximityPrompt
	whose Triggered event is connected on the SERVER, so the trigger itself is
	engine-validated: the player must genuinely be within
	MaxActivationDistance of the counter with line of sight, and the engine
	rate-limits prompt activation. A client cannot fire a prompt it is not
	standing at.

	The payout is then computed from records the server rolled itself. The
	client never submits a list of what it is selling, never submits values,
	and never submits an amount.

	REJECTION
	---------
	Crusted and Washing items are skipped, not sold, and the player is told why
	with a soft Notify rather than a blocked prompt -- a trigger that silently
	does nothing reads as a bug. Loose litter arrives already Cleaned, so a
	normal run of trash sells with no friction at all.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local ItemConfig = require(Modules:WaitForChild("ItemConfig"))
local InventoryController = require(Modules:WaitForChild("InventoryController"))
local Net = require(Modules:WaitForChild("Net"))
-- WHICH passes multiply a sale, and by how much. Pure replicated data; the
-- number lives with the pass rather than here for the same reason the pass id
-- does. See PassConfig.paying.
local PassConfig = require(Modules:WaitForChild("PassConfig"))
-- The ten-minute clock's timetable. A CONFIG module, deliberately -- see the
-- note by the event multiplier below for why this may not be EventService.
local EventConfig = require(Modules:WaitForChild("EventConfig"))
-- The bought golden hour, and a CONFIG module for the same reason EventConfig
-- is: BoostService pays nothing and reads nothing here, but requiring a sibling
-- service from the till is the shape that becomes a cycle later.
local BoostConfig = require(Modules:WaitForChild("BoostConfig"))
-- Beach Buddies, and a CONFIG module for the third time and the same reason:
-- BuddyService pays nothing itself, but a service required from here that ever
-- wanted to pay would close a cycle. See BuddyConfig's header.
local BuddyConfig = require(Modules:WaitForChild("BuddyConfig"))

local ValueCalculator = require(script.Parent.ValueCalculator)
--[[
	WHO OWNS A PASS, AND IT IS ASKED HERE RATHER THAN READ OFF THE PLAYER.

	There is a replicated `OwnsDoubleCash` attribute saying the same thing, and it
	is deliberately not what decides a payout: it is a statement written onto a
	Player instance, which is good enough to paint a button and nothing more. This
	is the server's own record of what Roblox answered. See PassConfig's note on
	`owns`.

	No cycle: GamePassService reaches only for AtvConfig, PassConfig and Net, and
	none of the three knows this module exists.
]]
local GamePassService = require(script.Parent:WaitForChild("GamePassService"))

local CFG = GameConfig.Selling

local SellServer = {}

local counters = {}      -- [Model] = counter
local lastSellAt = {}    -- [Player] = os.clock()
local lastRefuseAt = {}  -- [Player] = os.clock(), throttles the refusal toast

--[[
	Optional persistence seam. Assign a function here from a save module and it
	will be called after every balance change:

		SellServer.OnCoinsChanged = function(player, newTotal, delta) ... end

	Nothing in this system writes to a DataStore -- coins are session-only until
	you wire this up.
]]
SellServer.OnCoinsChanged = nil

--[[
	FIRED AFTER EVERY COMPLETED SALE, with the same payload the receipt is built
	from:

		SellServer.OnSold = function(player, payload) ... end

	One claimant today -- CTBBridge, which turns it into CTB_HUD's own "SOLD"
	banner. It is a HOOK rather than a line inside CTBBridge.sell because that
	function is no longer the only door to the till: the wash bay now sells a
	finished find directly (see sellItems below), and the tagged-counter prompt
	further down sells without going through the bridge at all. Announcing from
	here means every door animates the same HUD, and there is exactly one place
	that decides what a sale looks like.
]]
SellServer.OnSold = nil

--------------------------------------------------------------------------
-- LEADERSTATS
--------------------------------------------------------------------------

--[[
	CURRENCY ADAPTER
	----------------
	Not every game keeps cash in leaderstats. Clean the Beach, for one, holds it
	on a player ATTRIBUTE ("Coins") that its HUD reads directly. Point
	SellServer.Currency at whatever store the host game already owns and every
	payout lands in the right place -- there is still exactly ONE grant path.
]]
SellServer.Currency = nil -- {get = f(player), add = f(player, delta) -> total}

local function ensureLeaderstats(player: Player): IntValue
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
		coins.Value = 0
		coins.Parent = ls
	end
	return coins
end

--------------------------------------------------------------------------
-- ECONOMY ANALYTICS
--------------------------------------------------------------------------
--[[
	EVERY COIN THIS GAME MOVES, REPORTED TO THE CREATOR DASHBOARD.  2026-09-19.

	WHY THIS WAS THE FIRST THING WORTH BUILDING. The game already reports its
	funnels -- FunnelServer logs onboarding, map unlocks and the tide ladder --
	but AnalyticsService.LogEconomyEvent was not called anywhere in the place. So
	the one question this game is actually made of, "where do coins come from and
	where do they go", could not be answered from any dashboard. Every balance
	decision -- what a rung should cost, whether the tide wipe is too harsh,
	whether anybody buys eggs -- was being made without the numbers.

	ONE PLACE, BECAUSE THERE IS ONE GRANT PATH. addCoins below is the only
	function in the game that moves the balance; 24 call sites across 18 modules
	go through it. That is what makes this a contained change rather than a
	sweep, and it is why the header above is worth keeping true.

	THE CALLER SAYS WHY, BECAUSE NOTHING HERE CAN INFER IT. A delta of -9,500 is
	a rung, an egg, a machine or a rebirth wipe, and the dashboard groups by
	those. Callers pass a short `reason` key; this table turns it into the
	transaction type Roblox groups on plus a SKU worth reading in a report.

	NO REASON MEANS NO EVENT, AND THAT IS A FEATURE. SaveService restores a
	profile by calling addCoins with the saved balance on every single join. Left
	to log, that one call site would report the entire playerbase's savings as
	fresh income every session and drown every real source in the game. It passes
	no reason on purpose; so does any internal bookkeeping added later.

	IT CAN NEVER FAIL A PAYOUT. The whole thing is inside a pcall and runs after
	the balance has already moved. An analytics outage, a bad enum or a nil
	player costs a log line, never a player's coins.
]]
local Analytics = game:GetService("AnalyticsService")

--[[
	THE ENUM HAS SIX MEMBERS AND "Other" IS NOT ONE OF THEM.

	IAP, Shop, Gameplay, ContextualPurchase, TimedReward, Onboarding -- that is
	the whole list. Indexing an Enum with a name it does not have THROWS rather
	than returning nil, so a TT.Other in the table below took the entire module
	down at load, and with it every coin in the game. Caught in Play before it
	shipped; worth the sentence because the failure is total and the typo is
	invisible until the module is first required.
]]
local TT = Enum.AnalyticsEconomyTransactionType

-- `false` means KNOWN BUT DELIBERATELY NOT REPORTED -- distinct from a missing
-- key, which is a typo and warns.
local ECONOMY: { [string]: any } = {
	-- SOURCES
	sell        = { TT.Gameplay,  "SellFinds" },
	bonus       = { TT.Gameplay,  "FieldBonus" },
	event       = { TT.Gameplay,  "EventPayout" },
	penguin     = { TT.Gameplay,  "PenguinPet" },
	stair       = { TT.Gameplay,  "AshenStair" },
	afk         = { TT.Gameplay,  "IdleShore" },
	daily       = { TT.TimedReward, "DailyLadder" },
	playtime    = { TT.TimedReward, "PlaytimeTier" },
	quest       = { TT.TimedReward, "Quest" },
	group       = { TT.Onboarding, "GroupReward" },
	-- An announced giveaway, which is neither earned nor bought. Its own SKU so
	-- a code drop does not read as a spike in play.
	code        = { TT.TimedReward, "Code" },
	coinpack    = { TT.IAP,       "CoinPack" },
	starterpack = { TT.IAP,       "StarterPack" },
	-- SINKS
	upgrade     = { TT.Shop,      "FootUpgrade" },
	carupgrade  = { TT.Shop,      "CarUpgrade" },
	car         = { TT.Shop,      "Vehicle" },
	egg         = { TT.Shop,      "Egg" },
	washer      = { TT.Shop,      "WasherUpgrade" },
	plot        = { TT.Shop,      "FieldUnlock" },
	-- Not a purchase: the tide takes the balance rather than selling anything for
	-- it. Still a sink, because a coin that leaves the economy has to be counted
	-- somewhere or sources and sinks stop adding up -- and this is the single
	-- biggest one in the game.
	rebirth     = { TT.Gameplay,  "TideWipe" },
	-- NOT REPORTED. The admin panel's give/take is a studio tool; a few million
	-- coins conjured during testing would sit in the report beside real income
	-- and there is no honest transaction type for it. The movement still happens,
	-- it just is not play and is not counted as such.
	admin       = false,
}

local function logEconomy(player: Player, delta: number, total: number, reason: string?)
	if not reason or delta == 0 then
		return
	end
	local row = ECONOMY[reason]
	if row == false then
		return   -- known, deliberately unreported
	end
	if not row then
		-- Loud, because a typo'd reason is a hole in the report that nothing else
		-- would ever show. Cheap: it fires once per unknown key per server life.
		warn("[SellServer] unknown economy reason " .. tostring(reason)
			.. " -- add it to ECONOMY or the dashboard will not group it")
		return
	end
	pcall(function()
		Analytics:LogEconomyEvent(
			player,
			(delta > 0) and Enum.AnalyticsEconomyFlowType.Source
				or Enum.AnalyticsEconomyFlowType.Sink,
			"Coins",
			math.abs(delta),
			math.max(0, total),
			row[1].Name,
			row[2]
		)
	end)
end

-- The single grant path. Every other module that wants to pay a player calls
-- this; nothing writes coins.Value directly.
--
-- `reason` is a key from ECONOMY above and is what puts the movement on the
-- Creator Dashboard's economy report. Omitting it is legal and silent -- see
-- the note there for the one call site that must omit it.
function SellServer.addCoins(player: Player, amount: number, reason: string?): number
	assert(RunService:IsServer(), "[SellServer] server-only")

	if SellServer.Currency then
		local delta = math.floor(amount)
		local total = SellServer.Currency.add(player, delta)
		if delta ~= 0 and SellServer.OnCoinsChanged then
			task.spawn(SellServer.OnCoinsChanged, player, total, delta)
		end
		logEconomy(player, delta, total, reason)
		return total
	end

	local coins = ensureLeaderstats(player)
	local delta = math.floor(amount)
	if delta == 0 then
		return coins.Value
	end
	coins.Value = math.max(0, coins.Value + delta)
	if SellServer.OnCoinsChanged then
		task.spawn(SellServer.OnCoinsChanged, player, coins.Value, delta)
	end
	logEconomy(player, delta, coins.Value, reason)
	return coins.Value
end

function SellServer.getCoins(player: Player): number
	if SellServer.Currency then
		return SellServer.Currency.get(player)
	end
	return ensureLeaderstats(player).Value
end

--------------------------------------------------------------------------
-- SELLING
--------------------------------------------------------------------------

local function notify(player: Player, text: string, kind: string?)
	Net.get("Notify"):FireClient(player, { text = text, kind = kind or "info" })
end

--[[
	THE TILL. Every coin this game pays for a find comes out of this function,
	and the two callers below differ only in WHICH records they hand it.

	That split is the whole point of extracting it. The rebirth multiplier, the
	2x Cash pass, the batch bonus and the receipt are each argued at length in
	the comments they sit beside, and every one of those arguments turns on
	there being ONE place a find becomes cash. A second sell path with its own
	arithmetic is how a player ends up being paid a different amount for the
	same rock depending on where they were standing.

	`records` must already be Cleaned and must already be this player's; both
	callers filter before they get here, and sumCleaned skips anything that is
	not. Returns nil for an empty list -- there is no such thing as a sale of
	nothing -- and the CALLER decides whether that silence deserves a toast.
]]
local function payOut(player: Player, inv, records, counter, opts)
	if #records == 0 then
		return nil
	end
	opts = opts or {}
	-- Called `cleaned` from here down because that is what this arithmetic has
	-- always called it, and renaming it would make the diff unreadable against
	-- every comment below that names it.
	local cleaned = records

	local subtotal = ValueCalculator.sumCleaned(cleaned)

	-- Batch bonus. Rewards a full clean-then-sell run over dribbling items in.
	local bonusRate = math.min(#cleaned * CFG.BatchBonusPerItem, CFG.MaxBatchBonus)
	local bonus = math.floor(subtotal * bonusRate + 0.5)
	local total = subtotal + bonus

	-- THE REBIRTH MULTIPLIER.
	--
	-- ProgressionServer writes SellMultiplier on join, after every purchase and
	-- after every rebirth, and the rebirth panel sells the whole feature on it:
	-- "1.00x > 1.25x SELL BONUS". Nothing anywhere read it. So turning the tide
	-- cost the player their coins, their finds and every upgrade level in
	-- exchange for a number that changed nothing about what they earned.
	--
	-- This is the one place a find becomes cash, so it is the one place the
	-- multiplier can be applied without a second code path. Missing or <= 1 is
	-- the no-rebirth case and is left exactly alone.
	--
	-- Applied LAST, and that order is deliberate: subtotal, then the batch
	-- bonus, then this, so the multiplier lands on the bonused figure. That is
	-- what makes one full-bag run by a rebirthed player worth bringing in
	-- rather than three small ones.
	--
	-- It is also the only multiplier in the chain. The Haggling upgrade track
	-- stacked a second one on top of it and came out of the game with the
	-- track; the branch went with it rather than being left reading an
	-- attribute nothing writes any more. Nothing else may be folded into this
	-- one either: the receipt names it and the rebirth panel advertises the
	-- same figure, so a second thing multiplied in quietly would make the
	-- panel's promise stop matching the till.
	local multiplier = player:GetAttribute("SellMultiplier")
	if type(multiplier) == "number" and multiplier > 1 then
		total = math.floor(total * multiplier + 0.5)
	else
		multiplier = 1
	end

	--[[
		THE GAME PASS MULTIPLIER  --  2x Cash, and it is a SECOND number rather
		than a second thing folded into the one above.

		The paragraph above says why, and it was written before this pass existed:
		"the receipt names it and the rebirth panel advertises the same figure, so
		a second thing multiplied in quietly would make the panel's promise stop
		matching the till." A player at 1.20x who saw 2.40x on their receipt would
		be right to think the rebirth panel was lying.

		So `multiplier` stays exactly what the rebirth panel promises, this rides
		alongside it, and the payload below carries BOTH.

		ASKED OF THE SERVER'S RECORD, NOT OF THE ATTRIBUTE. GamePassService.
		ownsPassId answers off what Roblox told it; the OwnsDoubleCash attribute is
		the client's copy and only ever decides what a button says.

		WITHOUT `refresh`, and that is the one judgement call here. Passing true
		re-asks Roblox on a miss -- a web call, on the path every single sale in
		the game takes. GamePassService's own note reserves that for "somewhere a
		player is already waiting on a button they pressed"; a sell prompt is not
		that, and the join sweep already retries three times. The cost of being
		wrong is one session paying single on a dropped request, which the next
		join fixes by itself.

		APPLIED LAST, AFTER the rebirth multiplier, so "double" means double the
		figure the player would otherwise have seen -- which is the only reading of
		"2x Cash" that survives a player checking it against a sale they remember.
	]]
	local passMultiplier = 1
	for _, entry in PassConfig.paying() do
		if GamePassService.ownsPassId(player, entry.id) then
			passMultiplier *= entry.payMultiplier
		end
	end
	if passMultiplier > 1 then
		total = math.floor(total * passMultiplier + 0.5)
	end

	--[[
		THE EVENT MULTIPLIER  --  Golden Hour, and a THIRD number for the third
		time, for the reason the two paragraphs above give twice.

		The rebirth panel advertises `multiplier` and the shop advertises
		`passMultiplier`; a player who saw either of those figures change because
		an event was running would be right to think one of those screens was
		lying. So this rides alongside both and the receipt names all three.

		ASKED OF A CONFIG MODULE, NOT OF EventService. The service pays coins
		through addCoins in this very file, so the two requiring each other is a
		cycle. EventConfig is pure replicated data that both sides already hold,
		and it reads one server-written attribute -- which a client cannot forge
		and the HUD can display.

		APPLIED LAST, after the pass, on the same reasoning: "double" has to mean
		double the figure the player would otherwise have seen.
	]]
	local eventMultiplier = EventConfig.liveSellMultiplier()
	if eventMultiplier > 1 then
		total = math.floor(total * eventMultiplier + 0.5)
	end

	--[[
		THE BOUGHT GOLDEN HOUR  --  a FOURTH number, for the fourth time, and the
		three paragraphs above have now given the reason three times.

		The rebirth panel advertises `multiplier`, the shop advertises
		`passMultiplier`, the event pill advertises `eventMultiplier`, and the boost
		readout advertises this. Four screens, four promises; fold any two together
		and one of those screens starts lying.

		PER PLAYER, WHERE THE EVENT ABOVE IS PER SERVER. That is the only structural
		difference between them: Golden Hour is one attribute on ReplicatedStorage
		and everyone in the server rides it, this is two attributes on the player who
		paid for it.

		ASKED OF A CONFIG MODULE, NOT OF BoostService, for exactly the reason the
		event above is asked of EventConfig: the service would be a require cycle
		waiting to happen, and BoostConfig is pure replicated data that reads two
		server-written attributes -- which a client cannot forge and the HUD can
		display.

		APPLIED LAST, after the event, on the same reasoning the other three give:
		"double" has to mean double the figure the player would otherwise have seen.
	]]
	local boostMultiplier = BoostConfig.multiplierFor(player)
	if boostMultiplier > 1 then
		total = math.floor(total * boostMultiplier + 0.5)
	end

	--[[
		BEACH BUDDIES  --  a FIFTH number, and the four notes above have now made
		this argument four times, so this one will be short: it is its own term
		because it is its own promise on its own screen.

		PER PLAYER, like the boost above and unlike the event. BuddyService counts
		how many people on this server are on your friends list and writes it to an
		attribute; this reads that attribute. A client cannot forge it and the HUD
		can display it -- the same contract every term in this stack has.

		APPLIED LAST, after the boost, on the reasoning all four give: each number
		has to mean what the screen advertising it says it means.
	]]
	local buddyMultiplier = BuddyConfig.multiplierFor(player)
	if buddyMultiplier > 1 then
		total = math.floor(total * buddyMultiplier + 0.5)
	end

	-- Build the receipt BEFORE the records are destroyed.
	local receipt = {}
	local best = nil
	for _, rec in cleaned do
		local def = ItemConfig.expect(rec.itemId)
		table.insert(receipt, {
			itemId = rec.itemId,
			displayName = def.DisplayName,
			rarity = def.Rarity,
			value = rec.value or 0,
		})
		if not best or (rec.value or 0) > best.value then
			best = { displayName = def.DisplayName, rarity = def.Rarity, value = rec.value or 0 }
		end
	end

	-- One RemoveWhere call -> one dirty flag -> ONE InventorySync. The roller
	-- pellets and the carried HUD therefore empty on the same frame; there is
	-- no window in which the two views disagree.
	--
	-- BY UID, not by state. It used to be `rec.state == "Cleaned"`, which is the
	-- same set when the caller is sellAll and the WRONG set for anybody else:
	-- sellItems hands over a named few, and a state predicate would take the rest
	-- of the bag out with them. The receipt above is built from this very list,
	-- so what is charged for and what is taken cannot drift apart.
	local sold = {}
	for _, rec in records do
		sold[rec.uid] = true
	end
	inv:RemoveWhere(function(rec)
		return sold[rec.uid] == true
	end)

	-- The biggest source in the game by a wide margin, and the one every sink is
	-- priced against. See ECONOMY above.
	local coins = SellServer.addCoins(player, total, "sell")

	local payload = {
		sold = #receipt,
		subtotal = subtotal,
		bonusRate = bonusRate,
		bonus = bonus,
		multiplier = multiplier,
		-- The REBIRTH multiplier and the PASS multiplier, separately and never
		-- pre-combined. 1 when no paying pass is owned, which is the common case.
		-- Kept apart so a receipt can name each one; see the note above the
		-- arithmetic for what folding them together would break.
		passMultiplier = passMultiplier,
		-- ...and the event's, which is 1 for the fifty-odd minutes an hour when
		-- nothing is running. Four numbers, four promises, none of them merged.
		eventMultiplier = eventMultiplier,
		-- ...and the one the player bought, which is 1 unless they are inside a
		-- window they paid for. Last in the chain and last on the slip.
		boostMultiplier = boostMultiplier,
		-- ...and the one their friends earned them, 1 when nobody they know is
		-- here. Five numbers, five promises, still none of them merged.
		buddyMultiplier = buddyMultiplier,
		buddyCount = BuddyConfig.countFor(player),
		total = total,
		coins = coins,
		best = best,
		receipt = receipt,
	}
	--[[
		THE RECEIPT SLIP IS OPTIONAL, AND IT IS THE ONLY THING `opts` DECIDES.

		FeedbackClient parks that card 322px off the bottom of the screen on an
		assumption written into its own layout note -- "a receipt cannot fire
		[while the wash card is up]; it comes from SellResult, i.e. from standing
		on the sell pad, not at the wash bay". Auto-selling a finished find makes
		that false, and the slip would land on top of the reveal card that is
		already naming the same item and the same figure.

		So the bay asks for the sale without the slip. Everything else about the
		payout is identical -- same multipliers, same batch bonus, same coin
		shower, same announcement -- because it is the same function.
	]]
	if opts.receipt ~= false then
		Net.get("SellResult"):FireClient(player, payload)
	end

	-- To the seller only.
	--
	-- This deliberately used to go to everyone -- "other players seeing a big
	-- payout is free marketing for the loop" -- but the shower is sized by the
	-- payout, so it broadcast how much the seller just made. With progress private
	-- everywhere else, that was the last place another player's run leaked out.
	-- Flip this back to FireAllClients if the social pull is worth more than the
	-- privacy.
	Net.get("Fx"):FireClient(player, {
		kind = "CoinShower",
		part = counter and counter.anchor or nil,
		amount = total,
		intensity = math.clamp(#receipt / 6, 0.35, 1),
	})

	--[[
		THE ONE ANNOUNCEMENT, fired LAST -- after the money and the bag have both
		actually moved -- so a claimant is always describing a sale that has
		happened rather than one that is about to.

		Spawned, for the same reason OnCoinsChanged is: a claimant that throws or
		yields must not be able to take the till down with it.
	]]
	if SellServer.OnSold then
		task.spawn(SellServer.OnSold, player, payload)
	end

	-- Returned as well as announced, and the two are for different readers. The
	-- hook is for anything that wants to hear about EVERY sale wherever it came
	-- from; the return is for the caller that made this one and may want to know
	-- whether it happened. nil means nothing was sold.
	return payload
end

function SellServer.sellAll(player: Player, counter)
	local now = os.clock()
	if now - (lastSellAt[player] or -math.huge) < CFG.CooldownSeconds then
		return nil
	end
	lastSellAt[player] = now

	local inv = InventoryController.Server.get(player)

	local cleaned = inv:GetByState("Cleaned")
	if #cleaned == 0 then
		-- Throttled separately from the sell cooldown: a walk-on sell pad
		-- re-triggers constantly, and repeating this every 0.75s reads as a
		-- stuck HUD rather than as advice.
		if now - (lastRefuseAt[player] or -math.huge) >= CFG.RefusalNotifyCooldown then
			lastRefuseAt[player] = now
			-- Counted as "everything left", not as a list of state names. We are
			-- already inside `#cleaned == 0`, so anything still in the bag is by
			-- definition uncleaned -- and the old sum of "Crusted" + "Sifting"
			-- missed the lump actually mounted at the bay, whose state is
			-- "Washing", telling a player holding one find that they had nothing
			-- to sell. One less pair of string literals to keep in step.
			local crusted = inv:Count()
			if crusted > 0 then
				notify(player, "Wash the crust off those first!", "warn")
				Net.get("Fx"):FireClient(player, {
					kind = "Reject",
					part = counter and counter.anchor or nil,
				})
			else
				notify(player, "You have nothing to sell.", "info")
			end
		end
		return nil
	end

	return payOut(player, inv, cleaned, counter, nil)
end

--[[
	SELL A NAMED FEW, NOT THE BAG.

	sellAll is the counter: the player walked up, so everything ready to go goes.
	This is the other shape the game needs -- ONE find, sold the moment it is
	finished, without touching the litter the player is still out collecting.
	WashServer's completeLump is the caller, and the split is deliberate:

	  * A bag of raked litter is a BATCH, and walking it in is what the batch
	    bonus and the Quick Sell pass are both about. Emptying it as a side
	    effect of washing a rock would take that decision away from the player
	    and quietly make a pass somebody paid for pointless.
	  * A washed find is already finished, already valued and already revealed.
	    There is nothing left to decide about it, so there is nothing for the
	    walk to the pad to be a decision about either.

	NO COOLDOWN, AND THAT IS NOT AN OVERSIGHT. CFG.CooldownSeconds exists to stop
	a walk-on sell PAD re-triggering the till every tick. This path is
	server-driven, fires at most once per lump, and a lump takes the reveal hold
	(1.3s and up) to finish -- so there is nothing here for a debounce to defend.
	Sharing `lastSellAt` with the pad would instead mean a find silently failing
	to sell because the player happened to sell at a counter a moment earlier: it
	stays Cleaned in the bag, which loses nobody anything and looks exactly like
	the feature being broken.

	SILENT WHEN THERE IS NOTHING TO DO. sellAll's refusal toast exists because a
	player pressed something and deserves an answer. Nobody pressed this.

	`uids` IS SERVER-SUPPLIED. Nothing forwards a client's list here and nothing
	should -- the state check below stops a nonsense uid, it does not establish
	that the player was ever entitled to the record behind a real one.
]]
function SellServer.sellItems(player: Player, uids: { string }, counter, opts)
	assert(RunService:IsServer(), "[SellServer] server-only")

	local inv = InventoryController.Server.find(player)
	if not inv then
		return nil
	end

	local records = {}
	for _, uid in uids do
		local rec = inv:Get(uid)
		-- Cleaned only. A Crusted or Washing record has no rolled value yet, so
		-- selling one would pay nothing AND delete the find.
		if rec and rec.state == "Cleaned" then
			table.insert(records, rec)
		end
	end

	return payOut(player, inv, records, counter, opts)
end

--[[
	THE BAG IS BANKED WHEN THE PLAYER LEAVES  --  2026-09-09.

	CLOSES: "leaving destroys the whole bag, including litter that already has a
	rolled sale value". Raked litter is Cleaned and valued the instant it is
	picked up, so the HUD has been showing a price for every piece all along.
	InventoryController.Server.release then destroyed the array on PlayerRemoving
	and no handler anywhere sold it first: a disconnect with a full bag deleted
	money the player had already earned.

	THE SAME DOOR THE WASH BAY USES. sellItems, with a server-built uid list, so
	this is the counter's payout exactly -- same batch bonus, same rebirth
	multiplier, same pass multiplier, same event and boost windows, because it is
	the same payOut. There is deliberately no leave-sale rate: a second rate is
	how a player ends up being paid a different amount for the same rock
	depending on how their session happened to end.

	CLEANED ONLY. Crusted and Washing records are left to die with the bag --
	they have no revealed identity and no rolled value, sellItems refuses them
	anyway, and SaveService's header gives the same reason for not persisting
	them.

	IT CANNOT DOUBLE-PAY. payOut removes the records by uid in the same breath as
	it pays for them, and the caller destroys the inventory the instant this
	returns, so there is nothing left for a second seller to find. Nothing else
	sells on the leave path.

	NO RECEIPT SLIP (`receipt = false`): there is no client left to draw one on.

	NOTHING HERE YIELDS, which is what makes it safe on the leave path -- see the
	note on Server.Releasing, which task.spawns us alongside the profile save.
]]
local function sellOnLeave(player: Player, inv)
	local cleaned = inv:GetByState("Cleaned")
	if #cleaned == 0 then
		return
	end
	local uids = table.create(#cleaned)
	for _, rec in cleaned do
		table.insert(uids, rec.uid)
	end
	SellServer.sellItems(player, uids, nil, { receipt = false })
end


--------------------------------------------------------------------------
-- COUNTER REGISTRATION
--------------------------------------------------------------------------

--[[
	NOTHING IN THIS PLACE CARRIES THE SellCounter TAG, AND THAT IS NOT A BUG.

	Clean the Beach sells through its own pads -- Beach.SellArea, and the four
	island SellPads that copy it -- so this path has no users here. It is the
	seam a HOST game uses (see CTBBridge): tag a model, get a working "Sell All
	Cleaned Items" counter with no code. Left standing on purpose. Recorded here
	because an empty GetTagged looks exactly like a break until you go and check,
	and somebody already has.

	WORKSPACE ONLY, for the reason WashServer.registerBay now states at length: a
	tag survives being cloned into a backup, and this function would happily build
	a prompt inside ServerStorage and wire it to sellAll.
]]
local function registerCounter(model: Instance)
	if not model:IsA("Model") or counters[model] then
		return
	end
	if not model:IsDescendantOf(workspace) then
		return
	end

	local anchor = model:FindFirstChild("SellAnchor", true)
	if not (anchor and anchor:IsA("BasePart")) then
		anchor = model:FindFirstChildWhichIsA("BasePart", true)
	end
	if not anchor then
		warn("[SellServer] sell counter has no BasePart:", model:GetFullName())
		return
	end

	local prompt = anchor:FindFirstChildWhichIsA("ProximityPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Sell All Cleaned Items"
		prompt.ObjectText = "Buyer"
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 11
		prompt.RequiresLineOfSight = false
		prompt.Parent = anchor
	end

	local counter = { model = model, anchor = anchor, prompt = prompt }
	counters[model] = counter

	prompt.Triggered:Connect(function(player)
		SellServer.sellAll(player, counter)
	end)

	model.AncestryChanged:Connect(function(_, parent)
		if not parent then
			counters[model] = nil
		end
	end)
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

local started = false
function SellServer.start()
	assert(RunService:IsServer(), "[SellServer] server-only")
	if started then
		return
	end
	started = true

	-- Only create leaderstats when WE own the currency. With an adapter set,
	-- the host game already has a balance and a second "Coins" on the player
	-- list would be a visible duplicate.
	if not SellServer.Currency then
		Players.PlayerAdded:Connect(ensureLeaderstats)
		for _, player in Players:GetPlayers() do
			ensureLeaderstats(player)
		end
	end
	-- Bank the bag before InventoryController destroys it. Claimed off
	-- Server.Releasing rather than off PlayerRemoving because our own
	-- PlayerRemoving is connected after theirs and would arrive with the bag
	-- already gone -- see sellOnLeave above.
	InventoryController.Server.Releasing:Connect(sellOnLeave)

	Players.PlayerRemoving:Connect(function(player)
		lastSellAt[player] = nil
		lastRefuseAt[player] = nil
	end)

	local tag = GameConfig.Tags.SellCounter
	for _, model in CollectionService:GetTagged(tag) do
		registerCounter(model)
	end
	CollectionService:GetInstanceAddedSignal(tag):Connect(registerCounter)
end

return SellServer
