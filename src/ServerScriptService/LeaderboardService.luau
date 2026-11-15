--[[
	LeaderboardService  --  ServerScriptService.LeaderboardService

	THREE GLOBAL LEADERBOARDS: most money, most trash picked up, most rebirths.
	One OrderedDataStore each, polled on a timer, painted onto the three boards
	LeaderboardBuilder stands next to the spawn -- every row with the account's
	face on it, and the account at the top of each board standing on the podium
	in front of it (LeaderboardWinner), dancing.

	THERE IS NO REMOTE, AND THAT IS THE DESIGN. The rows are drawn into a
	SurfaceGui on the SERVER, which replicates like any other instance. A
	leaderboard is public by definition -- there is nothing on it one player may
	see and another may not -- so a remote, a client script and a per-player
	payload would be three moving parts bought for nothing. It also means the
	boards are correct for a player who joins mid-poll without any late-joiner
	handling: they replicate already filled in.

	WHAT IS ACTUALLY HARD HERE, and both halves are about writing rather than
	reading:

	1. NEVER PUBLISH A PLAYER WHOSE PROFILE HAS NOT LOADED. Every value below is
	   read live off the player, and a player who has just joined reads as zero
	   coins and zero rebirths until SaveService puts their profile back. Publish
	   in that window and the board is not merely wrong -- it has OVERWRITTEN the
	   player's real standing with a zero, and the only way back is for them to
	   earn it again. So every write is gated on SaveService.isLoaded.

	2. WRITE ONLY WHAT CHANGED. SetAsync is budgeted at 60 + 10/player a minute,
	   shared with every other store in the game -- SaveService's profiles are on
	   the same allowance. Rebirths and trash move rarely and coins move all the
	   time, so caching the last value written turns three writes per player per
	   cycle into roughly one.

	EVERY DataStore CALL IS WRAPPED. A leaderboard is decoration: if the service
	is down, or the place has no API access, the boards say so in plain words and
	nothing else in the game notices. Nothing here is allowed to throw into a
	join, a leave or a sale.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local LeaderboardConfig = require(Modules:WaitForChild("LeaderboardConfig"))

local LeaderboardService = {}

local started = false
local boards = nil                 -- key -> the built board (rows, stamp)
local stores = {}                  -- key -> OrderedDataStore
local lastWrote = {}               -- [player] = { [key] = last value published }
local nameCache = {}               -- [userId] = username
local warned = false

--[[
	HOW MANY ROWS ARE ASKED FOR, against TopN drawn. The surplus exists to decide
	ties -- see the cut in pollOne -- and 100 is GetSortedAsync's ceiling for a
	single page, so this is as much headroom as one request can buy. It holds
	until more than a hundred accounts sit on the same value at the bottom edge of
	the board, which on the rebirth ladder means a hundred at the 40 cap.
]]
local FETCH = 100

-- The last page each ranking came back with, kept so the standings pass can run
-- on its own quick clock without touching a store. Cleared to nil rather than to
-- an empty table when a poll fails, so "we have no idea" stays distinguishable
-- from "nobody is ranked".
local lastEntries = {}             -- key -> { {userId, name, value}, ... }

-- Resolved in start(), not at require time, for the reason TradeService gives:
-- these are siblings and requiring them up here would fix the boot order of
-- modules that do not otherwise care about each other.
local SellServer, ProgressionServer, SaveService, LeaderboardWinner

--------------------------------------------------------------------------
-- READING A STAT
--------------------------------------------------------------------------
--[[
	The three live in three different places, which is exactly why this is a
	function here rather than a getter in LeaderboardConfig -- see the note over
	LeaderboardConfig.Boards.

	MONEY IS THE BALANCE, not lifetime earnings. "Most money" is read the way a
	player reads it: what is in the bag right now. TotalEarned is already saved
	and would make a steadier board -- a rebirth wipes coins, so the money board
	turns over where a lifetime one would not -- but it answers a different
	question than the one on the sign, and the sign is what players believe.
]]
local function valueOf(player: Player, stat: string): number
	local raw = 0
	if stat == "coins" then
		raw = SellServer and SellServer.getCoins(player) or 0
	elseif stat == "rebirths" then
		raw = ProgressionServer and ProgressionServer.rebirthsOf(player) or 0
	elseif stat == "trash" then
		raw = player:GetAttribute(LeaderboardConfig.TrashAttribute) or 0
	end
	raw = tonumber(raw) or 0
	-- NaN fails every comparison including its own, so it has to be caught by
	-- name rather than by clamping. An OrderedDataStore takes integers only.
	if raw ~= raw then
		return 0
	end
	return math.clamp(math.floor(raw), 0, 9e15)
end

--------------------------------------------------------------------------
-- THE STORES
--------------------------------------------------------------------------
local function storeFor(key: string)
	if stores[key] then
		return stores[key]
	end
	local ok, s = pcall(function()
		return DataStoreService:GetOrderedDataStore(LeaderboardConfig.storeName(key))
	end)
	if not ok or not s then
		if not warned then
			warned = true
			warn("[Leaderboard] no OrderedDataStore (" .. tostring(s) .. "). In Studio this "
				.. "needs Game Settings > Security > Enable Studio Access to API Services.")
		end
		return nil
	end
	stores[key] = s
	return s
end

--------------------------------------------------------------------------
-- WRITING
--------------------------------------------------------------------------
local function publishFor(player: Player)
	-- See note 1 in the header. This is the guard that stops a mid-join read
	-- from zeroing somebody's standing.
	if not player.Parent or not (SaveService and SaveService.isLoaded(player)) then
		return
	end
	local mine = lastWrote[player]
	if not mine then
		mine = {}
		lastWrote[player] = mine
	end

	for _, def in ipairs(LeaderboardConfig.Boards) do
		local v = valueOf(player, def.stat)
		--[[
			ZERO IS PUBLISHED LIKE ANY OTHER VALUE, and it has to be. This read
			`v > 0 and ...` until 2026-09-08, which is note 1 again one layer down --
			except that note 1's actual hazard is a profile that has not loaded, and
			the isLoaded gate at the top of this function already refuses that. Past
			that gate a zero is a REAL zero, and the guard only had one remaining
			effect: it made a rebirth invisible to the money board.

			WHAT IT COST. onRebirth sets coins to exactly 0, so the write was skipped
			and the player's PRE-REBIRTH PEAK stayed in the store for good. Spending
			coins in the shop published normally (a smaller number is still > 0), so
			the board followed a player down when they bought something and froze when
			they turned the tide -- and MOST MONEY came to be topped by whoever had
			rebirthed at the highest balance, showing a number nobody had held in
			weeks. That is the opposite of what the header above valueOf promises,
			which is the balance as the player reads it.

			The write it adds is one per rebirth per player, against a budget of
			60 + 10/player a minute. It is not measurable.
		]]
		if mine[def.key] ~= v then
			local s = storeFor(def.key)
			if s then
				local ok, err = pcall(function()
					s:SetAsync(tostring(player.UserId), v)
				end)
				if ok then
					mine[def.key] = v
				else
					-- Left uncached on purpose, so the next cycle retries it.
					warn("[Leaderboard] publish failed for " .. def.key .. ": " .. tostring(err))
				end
			end
		end
	end
end

--------------------------------------------------------------------------
-- NAMES
--------------------------------------------------------------------------
-- Cached for the life of the server. A name lookup is a web call with its own
-- throttle, the board asks for the same thirty accounts every minute, and
-- usernames do not change often enough to be worth re-asking.
local function nameOf(userId: number): string
	local hit = nameCache[userId]
	if hit then
		return hit
	end
	local here = Players:GetPlayerByUserId(userId)
	if here then
		nameCache[userId] = here.Name
		return here.Name
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and type(name) == "string" and name ~= "" then
		nameCache[userId] = name
		return name
	end
	-- Not cached: a failed lookup is usually a throttle, and caching it would
	-- pin "Player 123" onto the board until the server restarts.
	return "Player " .. tostring(userId)
end

--------------------------------------------------------------------------
-- PAINTING
--------------------------------------------------------------------------
local function paint(board, entries: { any }?, note: string?)
	local def = board.def
	for i, row in ipairs(board.rows) do
		local e = entries and entries[i]
		if e then
			row.name.Text = e.name
			row.value.Text = LeaderboardConfig.formatValue(e.value, def.format)
			row.frame.BackgroundTransparency = 0
			-- A URL, NOT A FETCH -- see the note over LeaderboardBuilder's buildRow.
			-- The client resolves the thumbnail when it draws the row, so ten faces a
			-- board cost this poll nothing and cannot throttle.
			row.face.Image = "rbxthumb://type=AvatarHeadShot&id="
				.. tostring(e.userId) .. "&w=150&h=150"
			row.face.Visible = true
		else
			-- An unfilled row is emptied rather than hidden, so the board keeps its
			-- ten-row shape on a young store instead of collapsing to a stub. The
			-- face goes away entirely though: an empty circle reads as a picture that
			-- failed to load, where no circle reads as an empty row.
			row.name.Text = ""
			row.value.Text = ""
			row.face.Image = ""
			row.face.Visible = false
			row.frame.BackgroundTransparency = 0.55
		end
	end
	board.stamp.Text = note or ""

	-- Whoever is top of the board goes on the podium in front of it. Returns at
	-- once and does nothing at all when rank 1 has not changed, which is almost
	-- every poll -- see LeaderboardWinner.set.
	local top = entries and entries[1]
	if LeaderboardWinner then
		LeaderboardWinner.set(board, top and top.userId or nil)
	end
end

--------------------------------------------------------------------------
-- READING
--------------------------------------------------------------------------
--[[
	ONE FETCH, EVERY COPY.

	`boards[key]` is a LIST now -- every board in the world showing that ranking,
	one row per island. The GetSortedAsync in pollOne stays exactly ONE call per
	key per poll however many islands that grows to; only the painting fans out.

	That distinction is the entire budget. Three boards on a 60s poll is three
	requests a minute (see LeaderboardConfig's cadence note); polling per BOARD
	instead of per KEY would have made it twelve the moment the boards went onto
	the other three islands, and would go on multiplying with every island added.
]]
local function paintAll(list, entries: { any }?, note: string?)
	for _, board in ipairs(list) do
		-- Isolated per copy: one island's board failing to paint must not cost the
		-- other three theirs.
		local ok, err = pcall(paint, board, entries, note)
		if not ok then
			warn(string.format("[Leaderboard] paint failed on %s/%s: %s",
				tostring(board.island), tostring(board.def and board.def.key), tostring(err)))
		end
	end
end

local function stampAll(list, text: string)
	for _, board in ipairs(list) do
		board.stamp.Text = text
	end
end

--------------------------------------------------------------------------
-- WHERE EACH PLAYER IN THIS SERVER STANDS
--------------------------------------------------------------------------
--[[
	THE BOARD ANSWERS "WHO IS WINNING". THIS ANSWERS "HOW AM I DOING", which for
	everybody outside the top ten -- which is very nearly everybody -- is the only
	one of the two that can change what they do next.

	NO DATASTORE CALL. It reads the page the last poll already fetched and the
	player's own live value, so it is pure arithmetic and can run on a five-second
	clock (LeaderboardConfig.StandingsSeconds). That is what lets the gap tick
	down while somebody is actually raking, which is the whole point of showing it.

	THE LIVE VALUE, NOT THE PUBLISHED ONE. What is in the store is up to
	PublishSeconds behind, and a player who has just earned a thousand coins is
	asking about the thousand coins. The one place that matters is the skip below:
	a player's OWN row on the board carries their stale published score, and
	counting it would rank them behind themselves the moment they spent a coin.

	RANK IS NOT GUESSED PAST THE LAST ROW. An OrderedDataStore has no "what number
	am I" -- answering it means paging the whole store -- so a player below the
	page gets a nil rank and the number that IS knowable and IS the useful one:
	what it takes to reach the bottom row of the board.
]]
local function setAttr(player: Player, name: string, value: any)
	if player:GetAttribute(name) ~= value then
		player:SetAttribute(name, value)
	end
end

local function applyStanding(player: Player, def, entries: { any }?)
	local rankAttr = LeaderboardConfig.rankAttribute(def.key)
	local gapAttr = LeaderboardConfig.gapAttribute(def.key)
	local aheadAttr = LeaderboardConfig.aheadAttribute(def.key)

	-- No page, an empty ranking, or a profile still loading: say nothing rather
	-- than something wrong. A loading profile reads as zero on every stat, which
	-- is the same hazard note 1 in the header describes for writes.
	if not entries or #entries == 0 or not (SaveService and SaveService.isLoaded(player)) then
		setAttr(player, rankAttr, nil)
		setAttr(player, gapAttr, nil)
		setAttr(player, aheadAttr, nil)
		return
	end

	local mine = valueOf(player, def.stat)

	-- Walking a DESCENDING list, the last row still above you is the one directly
	-- above you -- so this needs one pass and no sorting. The descent is
	-- GUARANTEED rather than assumed: pollOne sorts every page before caching it,
	-- see the tie note there.
	local rank, above, level = 1, nil, nil
	for _, e in ipairs(entries) do
		if e.userId ~= player.UserId then
			if e.value > mine then
				rank += 1
				above = e
			elseif e.value == mine and not level then
				level = e
			end
		end
	end

	-- MEASURED AGAINST TopN, NOT AGAINST #entries. A young store returns three
	-- rows for a board that draws ten, and a player who beats none of the three is
	-- fourth on that board -- not off it.
	if rank > LeaderboardConfig.TopN then
		local last = entries[#entries]
		setAttr(player, rankAttr, nil)
		setAttr(player, aheadAttr, last.name)
		setAttr(player, gapAttr, math.max(0, last.value - mine))
		return
	end

	setAttr(player, rankAttr, rank)

	if above then
		setAttr(player, aheadAttr, above.name)
		setAttr(player, gapAttr, math.max(0, above.value - mine))
	elseif level then
		-- Nobody ahead, but not alone at the top either. A zero gap is how the card
		-- tells the two apart, and it is the honest reading of a tie -- which the
		-- rebirth board will produce a lot of once accounts reach the 40 ceiling.
		setAttr(player, aheadAttr, level.name)
		setAttr(player, gapAttr, 0)
	else
		-- Top, outright. The gap worth showing now is the one BEHIND: how much
		-- clear water there is between you and second.
		local second
		for _, e in ipairs(entries) do
			if e.userId ~= player.UserId then
				second = e
				break
			end
		end
		setAttr(player, aheadAttr, second and second.name or nil)
		setAttr(player, gapAttr, second and math.max(0, mine - second.value) or nil)
	end
end

local function standingsPass()
	for _, def in ipairs(LeaderboardConfig.Boards) do
		for _, player in ipairs(Players:GetPlayers()) do
			-- Per player, so one bad read cannot cost everyone else their card.
			pcall(applyStanding, player, def, lastEntries[def.key])
		end
	end
end

local function pollOne(def, list)
	local s = storeFor(def.key)
	if not s then
		-- No store at all: there is no ranking to stand in, so the cards go blank
		-- with the board rather than holding a number nothing can back up.
		lastEntries[def.key] = nil
		paintAll(list, nil, "leaderboard offline")
		return
	end

	local ok, page = pcall(function()
		return s:GetSortedAsync(false, FETCH)
	end)
	if not ok then
		-- The BOARDS ARE NOT CLEARED on a failed poll. A throttle is a moment, and
		-- blanking ten rows because one request bounced would make the common
		-- case -- a busy minute -- look like a wiped leaderboard.
		warn("[Leaderboard] poll failed for " .. def.key .. ": " .. tostring(page))
		stampAll(list, "could not refresh -- retrying")
		return
	end

	local okPage, raw = pcall(function()
		return page:GetCurrentPage()
	end)
	if not okPage or type(raw) ~= "table" then
		stampAll(list, "could not refresh -- retrying")
		return
	end

	local entries = {}
	for _, item in ipairs(raw) do
		local userId = tonumber(item.key)
		local value = tonumber(item.value)
		if userId and value and value > 0 then
			-- NO NAME YET. Resolving one is a web call, and most of what comes back in
			-- an over-fetched page is about to be thrown away -- see below.
			table.insert(entries, { userId = userId, value = value })
		end
	end

	--[[
		TIES GET A FIXED ORDER, AND THE REBIRTH BOARD IS WHY.

		GetSortedAsync orders by VALUE. What it does between two accounts holding
		the SAME value is not specified, and two of these three boards can only tie
		by accident -- coins and lifetime trash are big numbers that rarely collide.
		Rebirths is not: it is a small integer, in practice 0 to about 40 (where the
		authored ladder ends), so a tie at the top of that board is ordinary rather
		than exotic. It used to become PERMANENT as accounts piled up on the cap;
		since the ladder stopped having one (2026-09-11) the leaders eventually
		separate again, which makes this tiebreak matter less and still not enough
		less to remove -- the tides past 40 are long, so a tie can stand for hours.

		WHAT AN UNSTABLE ORDER ACTUALLY COSTS is not a reshuffled list -- it is the
		PODIUM. LeaderboardWinner.set does nothing while rank 1 is unchanged, which
		is what makes a once-a-minute poll free; hand it a first place that flips
		between two tied accounts and every poll destroys a standing rig and builds
		a new one, on four boards, for as long as the tie lasts. (Not a web call
		each time -- descCache holds the appearance per account -- but a rebuilt
		twenty-part model and a re-loaded dance, forever, for no visible change.)

		SO THE ORDER IS DECIDED HERE rather than trusted from the store. Sorting a
		page of ten costs nothing and makes the whole chain below deterministic --
		the painted rows, the podium, and the standings pass that walks this list
		expecting it to descend.

		USER ID IS A TIEBREAK, NOT A JUDGEMENT. It is stable, it is unique (they are
		the store's own keys, so no two entries can compare equal and the comparator
		stays a strict order), and it is already in hand. It happens to favour the
		older account, which is arbitrary -- WHO SHOULD ACTUALLY BE AHEAD among
		players on the same number is a design question this does not answer and
		should not pretend to. Answering it properly means ranking on when the count
		was reached, which an OrderedDataStore can only do as a composite value --
		a schema change, not a sort. Until then the honest reading of two rows with
		the same number on them is that they are level.
	]]
	table.sort(entries, function(a, b)
		if a.value ~= b.value then
			return a.value > b.value
		end
		return a.userId < b.userId
	end)

	--[[
		AND ONLY NOW IS IT CUT TO TEN, which is the other half of the tie problem
		and the half that sorting alone does not touch.

		Ordering the page the store hands back fixes the order of the rows IN it. It
		does not decide WHICH tied accounts are in it: ask for ten rows while
		thirteen accounts hold the ceiling, and the three the store leaves out are
		the store's choice, made again on every request. Measured on a saturated
		rebirth board, an account was in the page on one read and gone on the next --
		so the board's membership drifted, and with it the first row the podium is
		built from. That is the churn this was supposed to stop.

		SO THE PAGE IS OVER-FETCHED AND THE CUT IS MADE HERE, against a tiebreak
		this file controls. FETCH rows in, TopN rows out, and the answer is the same
		on every poll and in every server as long as no more than FETCH accounts are
		stacked on the boundary value.

		IT COSTS NO EXTRA REQUEST. GetSortedAsync's budget counts calls, not rows,
		so a hundred-row page is the same one request a ten-row page was -- and the
		names, which are the genuinely expensive part, are resolved AFTER this line
		rather than before it. Ten lookups either way.
	]]
	for i = #entries, LeaderboardConfig.TopN + 1, -1 do
		entries[i] = nil
	end
	for _, e in ipairs(entries) do
		e.name = nameOf(e.userId)
	end

	-- Kept for the standings pass, which runs on a much quicker clock than this
	-- one and must never make a request of its own. Note that a FAILED poll above
	-- leaves the previous page in place untouched, for the same reason it leaves
	-- the painted rows alone: a throttle is a moment, not a wipe.
	lastEntries[def.key] = entries

	if #entries == 0 then
		paintAll(list, nil, "nobody ranked yet -- be the first")
		return
	end
	paintAll(list, entries, string.format("top %d worldwide -- refreshes every %ds",
		#entries, LeaderboardConfig.PollSeconds))
end

local function pollAll()
	for _, def in ipairs(LeaderboardConfig.Boards) do
		local list = boards[def.key]
		if list and #list > 0 then
			-- Isolated per stat: one store throttling must not cost the other two
			-- their refresh.
			local ok, err = pcall(pollOne, def, list)
			if not ok then
				warn("[Leaderboard] poll failed for " .. def.key .. ": " .. tostring(err))
			end
		end
	end
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------
function LeaderboardService.start()
	assert(RunService:IsServer(), "[LeaderboardService] server-only")
	if started then
		return
	end
	started = true

	local here = script.Parent
	SellServer = require(here:WaitForChild("SellServer"))
	ProgressionServer = require(here:WaitForChild("ProgressionServer"))
	SaveService = require(here:WaitForChild("SaveService"))
	LeaderboardWinner = require(here:WaitForChild("LeaderboardWinner"))

	boards = require(here:WaitForChild("LeaderboardBuilder")).build()
	for _, def in ipairs(LeaderboardConfig.Boards) do
		paintAll(boards[def.key], nil, "reading the records...")
	end

	Players.PlayerRemoving:Connect(function(plr)
		-- The last word on this player, and the one that matters most: a session's
		-- whole gain lands here if they leave between publish cycles. Spawned so a
		-- throttled write cannot hold up the leave path -- SaveService is on the
		-- same event and its profile write is the one that must not be delayed.
		local snapshot = plr
		task.spawn(function()
			pcall(publishFor, snapshot)
			lastWrote[snapshot] = nil
		end)
	end)

	-- READ FIRST, and immediately: the boards are the visible half, and a player
	-- who joins a fresh server should not stare at "reading the records" for a
	-- minute while the first publish cycle runs.
	task.spawn(function()
		while true do
			local ok, err = pcall(pollAll)
			if not ok then
				warn("[Leaderboard] poll cycle failed: " .. tostring(err))
			end
			task.wait(LeaderboardConfig.PollSeconds)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(LeaderboardConfig.PublishSeconds)
			for _, plr in ipairs(Players:GetPlayers()) do
				pcall(publishFor, plr)
			end
		end
	end)

	-- WHERE EVERYONE STANDS, on its own quick clock. Separate from the poll above
	-- because it shares none of its costs: no store, no web call, no budget -- so
	-- it is free to run twelve times as often, which is what makes the gap on the
	-- card move while somebody is working rather than once a minute.
	task.spawn(function()
		while true do
			local ok, err = pcall(standingsPass)
			if not ok then
				warn("[Leaderboard] standings pass failed: " .. tostring(err))
			end
			task.wait(LeaderboardConfig.StandingsSeconds)
		end
	end)

	print(string.format(
		"[Leaderboard] online -- %d global rankings across %d rows, poll %ds / publish %ds",
		#LeaderboardConfig.Boards, #LeaderboardConfig.Sites,
		LeaderboardConfig.PollSeconds, LeaderboardConfig.PublishSeconds))
end

-- Exposed for the one caller that legitimately wants a value on the board NOW
-- rather than at the next cycle: a rebirth is rare, deliberate, and the first
-- thing a player does afterwards is go and look at the rebirth board.
function LeaderboardService.publishNow(player: Player)
	if not started then
		return
	end
	task.spawn(function()
		pcall(publishFor, player)
	end)
end

return LeaderboardService
