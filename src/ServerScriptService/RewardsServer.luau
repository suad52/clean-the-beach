--[[
	RewardsServer  --  ServerScriptService.RewardsServer

	Three sections behind one panel: DAILY, QUESTS, PLAYTIME.
	What each of them offers lives in ReplicatedStorage.Modules.RewardsConfig.

	THE DAILY STREAK EXISTS NOW BECAUSE PERSISTENCE DOES
	----------------------------------------------------
	This file used to open with a note explaining why there was no daily board:
	"a daily-streak board is a lie without persistence -- with no DataStore
	wired, Day 3 would reset every time the server restarted". That was true
	when it was written and it is not true any more -- SaveService owns a real
	profile store now -- so the note's own advice has been taken. It said:

		Swapping to daily later is small: replace `elapsedFor` with a stored
		UTC date check and keep the claim/grant path exactly as it is.

	Which is what happened. `elapsedFor` is still here, still driving PLAYTIME,
	and the daily and quest claims come down the same `ClaimReward` remote into
	the same "check on the server, pay through SellServer, push" shape.

	THE CLOCK IS THE SERVER'S, IN ALL THREE SECTIONS
	------------------------------------------------
	The client sends an index or a key and nothing else -- never an amount,
	never a progress figure, never a date. Every threshold is re-checked here
	against state this file owns, so a client claiming the 30-minute bounty at
	twenty seconds, or day 7 on its first join, or a quest it has not finished,
	gets nothing.

	WHAT IS LATCHED WHERE, because the three differ and it matters:

		playtime   once per DAY, measured on seconds played TODAY.
		daily      once per DAY, and the day is the UTC date, not 24 hours.
		quests     dailies once per day, milestones once EVER.

	PLAYTIME USED TO BE PER SESSION AND WAS THE BIGGEST FAUCET IN THE GAME.
	The five tiers total 10,300 coins at multiplier 1.0, the clock was
	`os.clock() - joined`, and `tierClaimed` was deliberately left out of the
	save -- so the whole ladder came back every time somebody rejoined. Measured
	at tide 0 that is worth more per half hour than playing is, and rejoining
	paid better than raking.

	The fix is not a smaller number, it is a longer latch: the tiers now measure
	`playSec` -- seconds played TODAY, across sessions, which this file already
	kept for the LONG SHIFT quest -- and `tierClaimed` rolls with the day and is
	saved. A player who plays ten minutes, leaves, and comes back for another
	twenty still reaches the 30-minute tier, which a session clock would never
	have let them do. Rejoining to farm them does nothing at all.

	`elapsedFor` and the `joined` table went with that change. Nothing else in
	the game measured a session.

	PERSISTENCE SEAM
	----------------
	`exportFor` / `restore` are the pair SaveService reads and writes, the same
	way it uses ProgressionServer.levelOf and PetServer.restore. Nothing else
	reaches into `state`, and this file never touches a DataStore itself.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Net = require(Modules:WaitForChild("Net"))
local RewardsConfig = require(Modules:WaitForChild("RewardsConfig"))
local ProgressionConfig = require(Modules:WaitForChild("ProgressionConfig"))
-- For the litter counter's attribute name only. The daily pool measures
-- against it, and it is the one lifetime counter a rebirth does not clear --
-- which is exactly what makes it safe to read as a daily.
local LeaderboardConfig = require(Modules:WaitForChild("LeaderboardConfig"))
local SellServer = require(script.Parent:WaitForChild("SellServer"))
local ProgressionServer = require(script.Parent:WaitForChild("ProgressionServer"))
-- The wardrobe rungs' payout -- see claimQuest. SkinService requires only Config
-- and SkinConfig, so it is a leaf from here and cannot close a cycle back.
local SkinService = require(script.Parent:WaitForChild("SkinService"))
-- The 30-day rung's payout. Safe to require for the same reason SkinService is:
-- PetServer reaches for PetConfig, PetVisuals, Net, PremiumConfig, SellServer
-- and LuckService, and not one of them reaches back here.
local PetServer = require(script.Parent:WaitForChild("PetServer"))

local RewardsServer = {}

-- Kept as an alias rather than a second copy: the tiers moved into
-- RewardsConfig so the client can read them too, and anything still asking
-- this module for them should get the same table rather than a stale one.
RewardsServer.Tiers = RewardsConfig.Playtime

--[[
	SCALED BY THE RUN, exactly the way AfkConfig.rateFor scales the idle shore.

	A flat coin amount in an economy whose sell multiplier reaches 705x is
	worthless almost immediately: 6,000 for half an hour is a fair bounty on a
	first tide and a rounding error by the fourth.

	THE SNAPSHOT IS SCALED TOO, not just the payout. A panel advertising 6,000
	while the till pays 78,000 is the same defect pointing the other way, and it
	is the half the player actually reads.
]]
local function scaled(player: Player, coins: number): number
	local mult = player and player:GetAttribute("SellMultiplier")
	if type(mult) ~= "number" or mult ~= mult or mult <= 0 then
		mult = 1
	end
	return math.floor(coins * mult + 0.5)
end
RewardsServer.scaled = scaled

--[[
	THE DAILY LADDER'S OWN FIGURE, which is the scaled one OR a share of the next
	rebirth, whichever is larger. See RewardsConfig.dailyFloor for why the ladder
	needs a second index and why only this ladder gets one.

	ONE FUNCTION FOR ALL THREE CALL SITES -- the ladder in the snapshot, the
	current rung in the snapshot, and the payout. The header over `scaled` is
	emphatic that the advertised figure and the paid figure must be the same
	number ("a panel advertising 6,000 while the till pays 78,000 is the same
	defect pointing the other way"), and three copies of a max() is how they stop
	being the same number.
]]
local function dailyCoins(player: Player, rung): number
	local n = math.max(0, math.floor(tonumber(player:GetAttribute("Rebirths")) or 0))
	local need = ProgressionConfig.Rebirth.requirement(n + 1)
	return math.max(scaled(player, rung and rung.coins or 0),
		RewardsConfig.dailyFloor(rung, need))
end

--------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------
local state = {}      -- player -> the persisted-ish blob; see blankState

local function blankState()
	return {
		day = "",             -- the UTC date everything below refers to
		streak = 0,           -- consecutive days the daily has been claimed
		dailyClaimed = false, -- has today's rung been taken
		playSec = 0,          -- seconds played TODAY, across sessions
		-- DISTINCT DAYS THIS PLAYER HAS SHOWN UP, ever, and it only goes up --
		-- see the wardrobe note in RewardsConfig for why the skin rungs count
		-- these rather than riding `streak`, which a single missed day resets.
		daysVisited = 0,
		base = {},            -- stat values stamped when the day rolled
		questDone = {},       -- daily quest keys claimed today
		lifeDone = {},        -- milestone keys claimed, ever
		tierClaimed = {},     -- playtime tiers claimed TODAY (rolled, and saved)
		-- THE ONE FORGIVEN MISS -- see RewardsConfig.GraceDays. `graceUsed` is
		-- whether it has been spent this turn of the ladder; `graceSaved` is
		-- whether it was spent getting to TODAY, which is what the panel says
		-- out loud so the player learns the rule by being rescued by it.
		graceUsed = false,
		graceSaved = false,
	}
end

--------------------------------------------------------------------------
-- THE STATS QUESTS ASK ABOUT
--------------------------------------------------------------------------
--[[
	Every one of these is monotonic and already maintained by somebody else,
	which is the whole reason quests need no event plumbing -- see the header
	of RewardsConfig for why hooking the sell path was rejected.

	`levels` counts levels BOUGHT, not levels held: every track starts at 1, so
	four tracks read as 4 before the player has purchased anything, and a
	milestone worded "reach 25 upgrade levels" would already be a sixth done on
	a fresh save.
]]
function RewardsServer.statOf(player: Player, stat: string): number
	if stat == "earned" then
		return math.max(0, math.floor(tonumber(player:GetAttribute("TotalEarned")) or 0))
	elseif stat == "levels" then
		local n = 0
		for _, t in ProgressionConfig.Tracks do
			n += math.max(0, ProgressionServer.levelOf(player, t.key) - 1)
		end
		return n
	elseif stat == "rebirths" then
		return math.max(0, ProgressionServer.rebirthsOf(player))
	elseif stat == "vehicle" then
		return math.max(0, math.floor(tonumber(player:GetAttribute("AtvTier")) or 0))
	elseif stat == "trash" then
		return math.max(0, math.floor(
			tonumber(player:GetAttribute(LeaderboardConfig.TrashAttribute)) or 0))
	elseif stat == "playSec" then
		local s = state[player]
		return s and math.floor(s.playSec) or 0
	elseif stat == "daysVisited" then
		-- Distinct days this player has shown up, ever. Counted in rollDay, which
		-- is the one place that fires exactly once per UTC day.
		local s = state[player]
		return s and math.floor(s.daysVisited) or 0
	end
	return 0
end

-- A daily quest measures from the baseline stamped at the day roll; a
-- milestone measures from zero. One function, one difference.
local function progressFor(player: Player, quest): number
	local now = RewardsServer.statOf(player, quest.stat)
	if not quest.daily then
		return now
	end
	local s = state[player]
	local base = (s and s.base[quest.stat]) or 0
	return math.max(0, now - base)
end

--------------------------------------------------------------------------
-- THE DAY ROLL
--------------------------------------------------------------------------
--[[
	Called on join, on restore, and on the slow tick -- a session can and does
	cross midnight, and a player who is stood on the beach when it happens
	should see the panel refill rather than have to rejoin.

	IT NEVER TOUCHES `lifeDone`. Milestones are the one thing here that does
	not care what day it is.
]]
local function rollDay(player: Player): boolean
	local s = state[player]
	if not s then
		return false
	end
	local today = RewardsConfig.dayKey()
	if s.day == today then
		return false
	end

	--[[
		A gap of more than one day breaks the streak back to 1 rather than to 0:
		you are on day one again, and day one still pays. There is no state in
		which opening this panel on a new day offers nothing.

		EXCEPT ONCE A LADDER. A gap of exactly two days means exactly one day
		missed, and that one is forgiven if the forgiveness is in hand -- see
		RewardsConfig.GraceDays for why, and for why it cannot be farmed.

		An unparseable or backwards gap falls through to the reset, which is the
		safe direction: a clock that disagrees with itself must not mint streak.
	]]
	local gap = (s.day ~= "") and RewardsConfig.dayGap(s.day, today) or nil
	s.graceSaved = false
	if s.day == "" then
		s.streak = math.max(1, s.streak)
	elseif gap == 1 then
		s.streak += 1
		-- A fresh turn of the ladder earns the forgiveness back. Keyed off the
		-- streak rather than off a date, so it cannot be moved by when you
		-- choose to return.
		if s.streak % #RewardsConfig.DailyLadder == 1 then
			s.graceUsed = false
		end
	elseif gap == 2 and not s.graceUsed and RewardsConfig.GraceDays > 0 then
		s.graceUsed = true
		s.graceSaved = true
		-- s.streak deliberately untouched: held, not advanced.
	else
		s.streak = 1
		-- A streak that has already fallen to the bottom keeps nothing worth
		-- protecting, so the forgiveness comes back with it.
		s.graceUsed = false
	end

	-- Counted HERE rather than on join, because this is the one place that
	-- fires exactly once per new UTC day: joining twice in an evening, or a
	-- session that crosses midnight and rolls on the tick, both land here once.
	s.daysVisited += 1

	s.day = today
	s.dailyClaimed = false
	s.playSec = 0
	-- Rolled WITH playSec, and it has to be: the tiers are thresholds on that
	-- counter, so zeroing one without the other either locks today's bounties
	-- out or hands them back the instant the clock resets.
	s.tierClaimed = {}
	s.questDone = {}
	s.base = {}
	for _, q in ipairs(RewardsConfig.Quests) do
		if q.daily then
			s.base[q.stat] = RewardsServer.statOf(player, q.stat)
		end
	end
	-- playSec is its own baseline: it was just zeroed, so stamping it from the
	-- live value would immediately re-credit today's seconds.
	s.base.playSec = 0
	return true
end

--------------------------------------------------------------------------
-- SNAPSHOT
--------------------------------------------------------------------------
function RewardsServer.snapshot(player: Player)
	local s = state[player]
	if not s then
		return { playtime = { elapsed = 0, tiers = {} }, daily = nil, quests = {} }
	end

	-- Seconds played TODAY, not this session. See the header.
	local e = s.playSec
	local tiers = {}
	for i, t in ipairs(RewardsConfig.Playtime) do
		tiers[i] = {
			at = t.at,
			coins = scaled(player, t.coins),
			label = t.label,
			claimed = s.tierClaimed[i] == true,
			ready = (e >= t.at) and not s.tierClaimed[i],
			remaining = math.max(0, math.floor(t.at - e)),
		}
	end

	local rung, rungIndex = RewardsConfig.rungFor(math.max(1, s.streak))
	local ladder = {}
	for i, r in ipairs(RewardsConfig.DailyLadder) do
		ladder[i] = {
			day = r.day,
			coins = dailyCoins(player, r),
			-- Rungs BELOW the current one read as done; the current one is
			-- either live or already taken today.
			done = (i < rungIndex) or (i == rungIndex and s.dailyClaimed),
			current = (i == rungIndex),
		}
	end

	local quests = {}
	-- Worked out once rather than per quest: the rotation is a whole-table
	-- question and the answer is the same for every row in it.
	local liveToday = RewardsConfig.dailyToday(s.day)
	for _, q in ipairs(RewardsConfig.Quests) do
		if q.daily and not liveToday[q.key] then continue end
		local done = q.daily and (s.questDone[q.key] == true) or (s.lifeDone[q.key] == true)
		local have = progressFor(player, q)
		quests[#quests + 1] = {
			key = q.key,
			daily = q.daily == true,
			label = q.label,
			blurb = q.blurb,
			-- The panel prints a seconds counter as minutes, so it has to know which
			-- quests are measured in seconds. Cheaper than shipping a formatted
			-- string and leaving the client unable to say anything else about it.
			stat = q.stat,
			need = q.need,
			have = math.min(have, q.need),
			coins = scaled(player, q.coins),
			-- The panel prints the skin's name where a coin figure would go, so it
			-- needs to know there is one. Just the key; MenuHud does not require
			-- SkinConfig and does not need to.
			skin = q.skin,
			claimed = done,
			ready = (have >= q.need) and not done,
		}
	end

	return {
		playtime = { elapsed = math.floor(e), tiers = tiers },
		daily = {
			streak = math.max(1, s.streak),
			rung = rungIndex,
			claimed = s.dailyClaimed,
			coins = dailyCoins(player, rung),
			ladder = ladder,
			-- Whether a forgiven miss is in hand, and whether one was spent
			-- getting to today. The panel says both out loud -- a streak saved
			-- silently teaches the player nothing and earns no goodwill.
			grace = not s.graceUsed,
			saved = s.graceSaved == true,
		},
		quests = quests,
	}
end

function RewardsServer.push(player: Player)
	if player.Parent then
		Net.get("RewardsSync"):FireClient(player, RewardsServer.snapshot(player))
	end
end

--------------------------------------------------------------------------
-- CLAIMS
--------------------------------------------------------------------------
--[[
	WHILE A BULK CLAIM IS OPEN, PAYING IS COLLECTING.

	claimAll walks the same per-item claim functions a single claim uses -- that
	is the whole point, every gate gets re-tested -- but each of those ends in
	pay(), and pay() credits, toasts and pushes. Ten quests would be ten credits,
	ten toasts stacked up the screen and ten snapshots down the wire for one
	button press.

	So pay() collects into the open batch instead and claimAll settles it once.
	The claim functions are untouched and cannot tell the difference.

	KEYED BY PLAYER rather than one flag: nothing in this path yields today, but a
	batch left open by one player must never swallow another's payout if it ever
	grows one.
]]
local batching = {}

-- `reason` is the economy key (see SellServer's ECONOMY table), which is NOT
-- the same thing as `what` beside it: that one is the toast the player reads
-- ("Quest complete!"), this one is how the Creator Dashboard groups the coins.
-- Carried on the batch too, which is safe because claimAll only ever settles a
-- batch of ONE kind -- it is called per shelf, not across them.
local function pay(player: Player, coins: number, what: string, reason: string?)
	local b = batching[player]
	if b then
		b.coins += coins
		b.n += 1
		b.reason = b.reason or reason
		return
	end
	SellServer.addCoins(player, coins, reason)
	Net.get("Notify"):FireClient(player, {
		text = string.format("%s  +%d coins", what, coins),
		kind = "pickup",
	})
	RewardsServer.push(player)
end

local function claimPlaytime(player: Player, i)
	if type(i) ~= "number" or i ~= i or i % 1 ~= 0 then return end
	local tier = RewardsConfig.Playtime[i]
	local s = state[player]
	if not tier or not s or s.tierClaimed[i] then return end
	if s.playSec < tier.at then return end   -- server clock, server threshold
	s.tierClaimed[i] = true
	pay(player, scaled(player, tier.coins), "Bounty claimed!", "playtime")
end

local function claimDaily(player: Player)
	local s = state[player]
	if not s then return end
	rollDay(player)
	if s.dailyClaimed then return end
	local rung = RewardsConfig.rungFor(math.max(1, s.streak))
	s.dailyClaimed = true
	pay(player, dailyCoins(player, rung), string.format("Day %d reward!", math.max(1, s.streak)),
		"daily")
end

local function claimQuest(player: Player, key)
	if type(key) ~= "string" then return end
	local q = RewardsConfig.QuestByKey[key]
	local s = state[player]
	if not q or not s then return end
	-- A rotated-out daily is not claimable. The panel does not offer it, but
	-- the panel is not what decides: this arrives as a client message, and the
	-- key is whatever the client put in it.
	if q.daily and not RewardsConfig.isDailyToday(key, s.day) then return end
	local done = q.daily and s.questDone[key] or s.lifeDone[key]
	if done then return end
	if progressFor(player, q) < q.need then return end   -- the gate
	if q.daily then
		s.questDone[key] = true
	else
		s.lifeDone[key] = true
	end
	--[[
		ZERO IS A REAL PAYOUT HERE, so it is skipped rather than paid. The three
		wardrobe rungs pay a skin and no coins; running them through pay() would
		announce "Quest complete!  +0 coins" at somebody who just earned a rake.
	]]
	if q.coins > 0 then
		pay(player, scaled(player, q.coins), "Quest complete!", "quest")
	end
	if q.skin then
		-- No notify of our own: SkinService.grant announces through SkinClient,
		-- which draws the same "<NAME> UNLOCKED" banner every room skin gets, and
		-- it CHOOSES the skin too -- so the tool in their hands changes on the
		-- press. A second line of our own would just talk over that.
		SkinService.grant(player, q.skin)
		-- pay() would have done this; a skin-only rung still has to repaint the
		-- row from CLAIM to DONE.
		RewardsServer.push(player)
	end
	if q.pet then
		--[[
			THE ONE PET NOBODY CAN ROLL. No notify of our own, for the same reason
			the skin rung has none: PetServer.grant announces both outcomes
			itself, and the `forWhat` name is what makes its refusal name THIS
			rung rather than ask an unrelated-sounding question -- see the note
			above PetServer.grant, which was written about exactly that bug.

			IT CAN REFUSE, and the refusal has to be honoured: a full pet bag is
			an ordinary state, not a fault. The rung was marked done above, so
			letting a failed grant stand would burn a thirty-day reward on a full
			bag. Un-marking puts the row back to CLAIM, which is better than the
			"rejoin to claim it" that message offers the purchase paths: this one
			is re-pressable the moment they free a slot, no rejoin needed.
		]]
		if not PetServer.grant(player, q.pet, q.label) then
			s.lifeDone[key] = nil
		end
		RewardsServer.push(player)
	end
end

--[[
	CLAIM EVERYTHING READY ON ONE PAGE.

	"ALL" IS DECIDED HERE, NOT SENT. The client names a PAGE, never a list of
	what it believes it has earned -- so this walks every quest or every tier and
	calls the SAME claim function a single press calls. Each re-tests its own gate
	(claimed already? progress met? server clock past the threshold?), so a sweep
	cannot pay for anything a single claim would have refused.

	THE DAILY IS IN NEITHER PAGE, deliberately. It is one button on its own tab,
	and folding it into a sweep would claim a streak rung the player never looked
	at -- which is the one reward here they might be saving.
]]
local function claimAll(player: Player, what)
	local s = state[player]
	if not s then
		return
	end
	rollDay(player)

	local b = { coins = 0, n = 0 }
	batching[player] = b

	if what == "quest" then
		for key in RewardsConfig.QuestByKey do
			claimQuest(player, key)
		end
	elseif what == "playtime" then
		for i in RewardsConfig.Playtime do
			claimPlaytime(player, i)
		end
	end

	-- Closed before the payout, so nothing below can leave a batch open and
	-- silently swallow this player's next single claim.
	batching[player] = nil

	if b.n == 0 then
		return
	end
	SellServer.addCoins(player, b.coins, b.reason)
	Net.get("Notify"):FireClient(player, {
		text = string.format("Claimed %d reward%s  +%d coins",
			b.n, (b.n == 1) and "" or "s", b.coins),
		kind = "pickup",
	})
	RewardsServer.push(player)
end

local function onClaim(player: Player, payload)
	if type(payload) ~= "table" then return end
	if not state[player] then return end
	local kind = payload.kind
	if kind == "daily" then
		claimDaily(player)
	elseif kind == "quest" then
		claimQuest(player, payload.key)
	elseif kind == "claimAll" then
		claimAll(player, payload.what)
	else
		-- No `kind` means the old shape, {tier = n}. Kept working on purpose:
		-- a client mid-session when the server updates is otherwise a player
		-- whose panel silently stops paying.
		claimPlaytime(player, payload.tier)
	end
end

--------------------------------------------------------------------------
-- THE PERSISTENCE SEAM  (SaveService is the only caller)
--------------------------------------------------------------------------
function RewardsServer.exportFor(player: Player)
	local s = state[player]
	if not s then
		return nil
	end
	-- tierClaimed IS SAVED NOW, and it has to be. It used to be left out on the
	-- grounds that the tiers ran on a session clock that reset to zero anyway;
	-- they run on `playSec` and roll with the day, so leaving it out is exactly
	-- what would hand the whole 10,300-coin ladder back on every rejoin.
	return {
		day = s.day,
		streak = s.streak,
		dailyClaimed = s.dailyClaimed,
		playSec = math.floor(s.playSec),
		daysVisited = s.daysVisited,
		base = s.base,
		questDone = s.questDone,
		lifeDone = s.lifeDone,
		tierClaimed = s.tierClaimed,
		graceUsed = s.graceUsed,
		graceSaved = s.graceSaved,
	}
end

--[[
	Everything validated on the way in rather than trusted, the same contract
	SaveService.migrate keeps: a profile written by an older build must degrade
	to a sane player, never to an error three lines into a join.

	The day is rolled AFTER the merge, so a profile saved yesterday advances the
	streak on load rather than waiting for the next tick.
]]
function RewardsServer.restore(player: Player, blob)
	local s = state[player]
	if not s then
		return
	end
	-- Which baselines the SAVE actually carried, as opposed to which ones are
	-- merely present. Everything in s.base was already stamped once by the
	-- rollDay in `hook`, which ran before this profile existed -- see the note
	-- at the foot of this function for why that distinction decides a payout.
	local fromBlob: { [string]: boolean } = {}
	if type(blob) == "table" then
		if type(blob.day) == "string" and #blob.day == 10 then
			s.day = blob.day
		end
		if type(blob.streak) == "number" and blob.streak == blob.streak then
			s.streak = math.clamp(math.floor(blob.streak), 0, 3650)
		end
		s.dailyClaimed = blob.dailyClaimed == true
		-- Both default to false on a profile written before the grace existed,
		-- which hands every returning player their first forgiveness. That is
		-- the generous direction and the correct one: nobody should lose a
		-- streak to a rule that was not in force when they missed the day.
		s.graceUsed = blob.graceUsed == true
		s.graceSaved = blob.graceSaved == true
		if type(blob.playSec) == "number" and blob.playSec == blob.playSec then
			s.playSec = math.clamp(math.floor(blob.playSec), 0, 86400)
		end
		--[[
			A PROFILE WRITTEN BEFORE THIS FIELD EXISTED reads nil and lands on the
			blank state's 0, which is the right answer rather than a lucky one:
			their next day roll makes it 1 and the ladder starts from there. It
			costs a returning player their first rung's head start and it cannot
			be recovered -- the game has never stored what days anybody visited --
			so the honest behaviour is to start counting now, not to guess.

			Seeded from `streak` would have been the clever version and is wrong:
			a streak is consecutive days and resets, so it is a FLOOR on days
			visited that reads 1 for most of the population.
		]]
		if type(blob.daysVisited) == "number" and blob.daysVisited == blob.daysVisited then
			s.daysVisited = math.clamp(math.floor(blob.daysVisited), 0, 3650)
		end
		if type(blob.base) == "table" then
			for k, v in blob.base do
				if type(k) == "string" and type(v) == "number" and v == v then
					s.base[k] = math.max(0, math.floor(v))
					fromBlob[k] = true
				end
			end
		end
		--[[
			INTEGER KEYS DO NOT SURVIVE A DATASTORE INTACT. `tierClaimed` is keyed
			1..5, and a sparse table like {[1]=true,[3]=true} is serialised as JSON
			and comes back as {["1"]=true,["3"]=true} -- string keys. A restore that
			only accepted numbers would silently forget every claim on the first
			reload and hand the ladder straight back, which is the bug this whole
			change exists to close.

			Both shapes are read; neither is trusted past tonumber and a bounds check
			against the ladder that actually exists, so a tier deleted from the config
			cannot linger as a claim on a rung nothing offers.
		]]
		if type(blob.tierClaimed) == "table" then
			for k, v in blob.tierClaimed do
				local i = tonumber(k)
				if v == true and i and i == i and i % 1 == 0 and RewardsConfig.Playtime[i] then
					s.tierClaimed[i] = true
				end
			end
		end

		for _, field in ipairs({ "questDone", "lifeDone" }) do
			if type(blob[field]) == "table" then
				for k, v in blob[field] do
					-- Only keys that still exist: a quest deleted from the
					-- config must not linger as a claim on a key nothing offers.
					if v == true and RewardsConfig.QuestByKey[k] then
						s[field][k] = true
					end
				end
			end
		end
	end
	rollDay(player)
	--[[
		A STAT THAT IS NEW TO THE DAILY POOL HAS NO SAVED BASELINE, and
		progressFor measures against zero when it finds none -- which reads a
		player's whole lifetime total as one day's work and makes the quest
		claimable the instant it rotates in. Not theoretical: `trash` joined the
		pool after this game had shipped, so every profile written before that
		comes back without one.

		TESTING s.base[stat] FOR nil WOULD NOT FIND IT. `hook` stamps a baseline
		for every daily stat the moment the player joins, which is BEFORE this
		profile has loaded and so before the attributes it reads hold anything --
		leaving a missing stat sitting there as a stale 0 rather than as nil.
		That zero IS the bug: lifetime minus nothing is lifetime. Hence fromBlob,
		which records what the save itself carried rather than what is present.

		By here the attributes ARE loaded -- SaveService writes them before it
		calls this -- so re-stamping reads true values. rollDay just above may
		have stamped everything already if the day rolled; this then re-stamps
		the same numbers, which is why it is safe to run unconditionally.

		A baseline the save DID carry is this day's real progress and is left
		alone. playSec is stamped at zero for the same reason rollDay stamps it
		there: the counter was reset rather than measured.
	]]
	for _, q in ipairs(RewardsConfig.Quests) do
		if q.daily and not fromBlob[q.stat] then
			s.base[q.stat] = (q.stat == "playSec") and 0
				or RewardsServer.statOf(player, q.stat)
		end
	end
	RewardsServer.push(player)
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------
local started = false
function RewardsServer.start()
	assert(RunService:IsServer(), "[RewardsServer] server-only")
	if started then return end
	started = true

	local function hook(player: Player)
		state[player] = blankState()
		rollDay(player)
		RewardsServer.push(player)
	end
	Players.PlayerAdded:Connect(hook)
	for _, p in Players:GetPlayers() do hook(p) end
	Players.PlayerRemoving:Connect(function(p)
		state[p] = nil
		batching[p] = nil
	end)

	Net.get("ClaimReward").OnServerEvent:Connect(onClaim)

	--[[
		The slow tick does three jobs, and they share a loop because they share
		a cadence: accumulate today's playtime, roll the day if the session has
		crossed midnight, and push -- a tier or a quest becoming ready is
		something the player should see without reopening the panel.

		FIVE SECONDS IS ALSO THE playSec RESOLUTION, which is why the quest
		asks for fifteen minutes rather than a number where five seconds of
		drift would be visible.
	]]
	local PERIOD = 5
	task.spawn(function()
		while true do
			task.wait(PERIOD)
			for _, p in Players:GetPlayers() do
				local s = state[p]
				if s then
					if not rollDay(p) then
						s.playSec += PERIOD
					end
					RewardsServer.push(p)
				end
			end
		end
	end)
end

return RewardsServer
