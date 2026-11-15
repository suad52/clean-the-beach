--[[
	FeedbackServer  --  ServerScriptService.FeedbackServer  (ModuleScript)

	Takes what a player types into Settings -> Feedback, attaches everything we
	can honestly say about who and what they are playing on, and writes it to a
	DataStore read in the Creator Dashboard:

		create.roblox.com -> this experience -> Data Stores -> PlayerFeedback

	This is the only DataStore in the place. ServerMain's persistence seam note
	still stands -- coins, levels and pets are deliberately not saved -- and this
	does not change it. Feedback is not player state; nothing here is ever read
	back into the game.

	TWO SOURCES, AND THE DIFFERENCE MATTERS
	---------------------------------------
	`server` is derived HERE from things the server itself wrote: levels, coins,
	rebirths, account age, membership. It cannot be forged.

	`client` is reported BY the client -- device, viewport, frame rate, graphics
	quality, and the Settings toggles. It cannot be checked, and it does not need
	to be: it is context on a bug report, not a permission. What it DOES need is
	bounding. A DataStore key is capped at 4MB and a RemoteEvent will carry
	whatever an exploiter puts in it, so an entry built by copying the client's
	table is an invitation to fill the store with junk at our expense. Hence the
	whitelist below: every field named, typed, clamped and cut, and anything not
	named dropped. The block is a fixed shape whatever arrives.

	The settings toggles have to come from the client because that is the only
	place they exist -- MenuHud writes them as Set_* attributes from a
	LocalScript, and attributes written on the client do not replicate up.

	ONE KEY PER SUBMISSION, NOT AN APPENDED LOG
	-------------------------------------------
	A log is a read-modify-write, and two players submitting in the same second
	race: both read the same list, both write, one message is silently lost. It
	also grows toward the 4MB ceiling with no way back. A key per submission has
	neither problem and costs exactly one SetAsync.

	THE KEYS SORT CHRONOLOGICALLY, which is not an accident -- the dashboard
	lists keys lexicographically, and os.time() is ten digits wide until the year
	2286, so lexicographic IS time order for the life of this game. The userId on
	the end stops two submissions in the same second overwriting each other.

	NOT FILTERED, DELIBERATELY
	--------------------------
	TextService filtering is required for text shown to OTHER PLAYERS. This is
	shown to nobody: it goes to a dashboard only the creators can open. Filtering
	would replace the complaint with hashes and leave us reading
	"the ###### bay is ######", which is worse than useless.

	STUDIO NEEDS API ACCESS TURNED ON
	---------------------------------
	DataStores are unreachable from Studio unless Game Settings -> Security ->
	"Enable Studio Access to API Services" is on. A published server does not
	care. A missing store is carried as nil and every submission answered
	honestly -- a feedback box that silently eats what you typed is the worst
	version of this feature.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FeedbackServer = {}

local STORE_NAME = "PlayerFeedback"
local REMOTE_FOLDER = "FeedbackRemotes"
local EVENTS = { "SubmitFeedback", "FeedbackResult", "AdminFetch", "AdminData", "AdminDelete", "AdminGrant" }

-- Long enough to be a sentence, short enough that one key is never near any
-- limit. The client counts against the same number; the client is not what
-- enforces it.
local MIN_CHARS = 4
local MAX_CHARS = 400

-- Per player. DataStore writes are budgeted at 60 + 10 per player per minute
-- across the whole server, so the cap that matters is one person leaning on the
-- button, not the room.
local COOLDOWN = 45

-- Ceilings for the client block. Nothing here is a guess about what a real
-- client sends -- they are the point past which a value is certainly junk.
local MAX_SETTINGS = 16       -- the panel has five
local MAX_KEY_LEN = 24

local store
local remotes
local lastSent = {}
local joinedAt = {}
local adminOf = {}
local trackKeys
local started = false

----------------------------------------------------------------
-- REMOTES  --  the same shape AtvServer and FerryServer use
----------------------------------------------------------------
local function ensureRemotes(): Folder
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

local function reply(player: Player, ok: boolean, message: string)
	remotes.FeedbackResult:FireClient(player, { ok = ok, message = message })
end

----------------------------------------------------------------
-- SANITISERS
----------------------------------------------------------------
--[[
	Control characters are stripped rather than kept. A MultiLine TextBox
	produces \n, and a dashboard entry is read as a single JSON string -- so
	newlines arrive as literal escapes mid-sentence and make it harder to read,
	not easier. Runs of whitespace collapse for the same reason.

	%c is a BYTE class and matches 0x00-0x1F only, so UTF-8 continuation bytes
	are untouched: emoji and accented text survive intact. Verified.

	Truncated LAST, so a message that is only long because of padding is not
	rejected for length it does not have.
]]
local function tidy(s: string): string
	s = s:gsub("%c", " ")
	s = s:gsub("%s+", " ")
	s = s:match("^%s*(.-)%s*$") or ""
	if #s > MAX_CHARS then
		s = s:sub(1, MAX_CHARS)
	end
	return s
end

local function str(v: any, max: number): string?
	if type(v) ~= "string" then
		return nil
	end
	v = v:gsub("%c", " "):gsub("%s+", " ")
	v = v:match("^%s*(.-)%s*$") or ""
	if v == "" then
		return nil
	end
	return (#v > max) and v:sub(1, max) or v
end

-- Clamped AND checked for NaN/inf, which are numbers, survive a type() test,
-- and are what a crafted payload sends to make a JSON encode fail.
local function num(v: any, lo: number, hi: number): number?
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return nil
	end
	return math.floor(math.clamp(v, lo, hi) * 10 + 0.5) / 10
end

--[[
	NOT `(type(v) == "boolean") and v or nil`.

	That is the classic Lua and/or trap and it is wrong exactly half the time:
	for v = false it evaluates to nil, so every FALSE flag was dropped from the
	entry and "this player has no touchscreen" became indistinguishable from
	"this client did not say". On a desktop submission that is four of the six
	device flags missing. Written out longhand, where false survives.
]]
local function flag(v: any): boolean?
	if type(v) ~= "boolean" then
		return nil
	end
	return v
end

local function sanitiseClient(raw: any)
	if type(raw) ~= "table" then
		return nil
	end

	local c = {
		platform = str(raw.platform, 24),
		viewport = str(raw.viewport, 16),
		locale = str(raw.locale, 16),
		systemLocale = str(raw.systemLocale, 16),
		fps = num(raw.fps, 0, 1000),
		fpsLow = num(raw.fpsLow, 0, 1000),
		quality = num(raw.quality, 0, 21),
		memoryMb = num(raw.memoryMb, 0, 262144),
		touch = flag(raw.touch),
		keyboard = flag(raw.keyboard),
		mouse = flag(raw.mouse),
		gamepad = flag(raw.gamepad),
		vr = flag(raw.vr),
		tenFoot = flag(raw.tenFoot),
	}

	--[[
		The toggles are taken by SHAPE rather than against a list of the five the
		panel has today. A second copy of that list would go stale the first time
		someone adds a toggle, and a feedback entry quietly missing the setting
		you just shipped is the exact case this is for. Bounded instead: short
		alphanumeric keys, boolean values, at most MAX_SETTINGS of them.
	]]
	if type(raw.settings) == "table" then
		local set, n = {}, 0
		for k, v in raw.settings do
			if n >= MAX_SETTINGS then
				break
			end
			if type(k) == "string" and #k <= MAX_KEY_LEN and k:match("^%w+$") and type(v) == "boolean" then
				set[k] = v
				n += 1
			end
		end
		c.settings = (n > 0) and set or nil
	end

	return c
end

----------------------------------------------------------------
-- WHAT THE SERVER KNOWS BY ITSELF
----------------------------------------------------------------
--[[
	Read from ProgressionConfig rather than listed here, so a track added to the
	game shows up in feedback without anyone remembering to add it twice. The
	attribute names are the config's own prefix + key, which is what
	ProgressionServer writes.
]]
local function levelKeys()
	if trackKeys then
		return trackKeys
	end
	trackKeys = {}
	local ok, PC = pcall(function()
		return require(ReplicatedStorage.Modules.ProgressionConfig)
	end)
	if ok and type(PC) == "table" and type(PC.Tracks) == "table" then
		local prefix = PC.AttrPrefix or "Lv_"
		for _, t in PC.Tracks do
			if type(t) == "table" and type(t.key) == "string" then
				table.insert(trackKeys, { attr = prefix .. t.key, name = t.key })
			end
		end
	end
	return trackKeys
end

--[[
	WHAT THE CLIENT AND THE SERVER EACH BELIEVE ABOUT THIS PLAYER'S PASSES.

	Added 2026-09-09 after a report -- "I purchased instant wash and it's not
	working" -- that cost a day to diagnose because nothing in the entry said
	whether the GAME thought they owned it. Everything else about that player
	was in the record: their coins, their tide, every upgrade level, their
	screen size. The one fact the report was actually about was missing.

		attr    the replicated OwnsX attribute. This is the CLIENT's copy and
		        the only thing it draws BUY-or-USE from.
		server  GamePassService's own record, which is what every entitlement in
		        the game is really decided on.
		known   whether that record is an answer from Roblox or a hole where one
		        should be (see GamePassService.ownsPassId).

	THE TWO SHOULD AGREE, AND THE BUG IS WHEN THEY DO NOT: the player is then
	looking at a button that does not match what the server will let them do.
	`attr=false, server=false` on a report that says "I bought it" is a stale
	record; `attr=true, server=false` is a client drawing a promise the server
	will refuse.

	STRINGS RATHER THAN BOOLEANS, because a nil attribute and a false one are
	different states and a nil would simply vanish from the stored table.

	NEVER WITH `refresh`, and that is not laziness. This runs inside a feedback
	submission: refresh YIELDS on a web call, and a player pressing SEND must
	not wait on Roblox -- nor should a run of reports be able to make this
	server hammer UserOwnsGamePassAsync. The unrefreshed pair is the state the
	player is complaining about anyway.
]]
local function passContext(player: Player)
	local okC, PassConfig = pcall(function()
		return require(ReplicatedStorage.Modules.PassConfig)
	end)
	if not (okC and type(PassConfig) == "table" and type(PassConfig.all) == "function") then
		return nil
	end
	local okG, GamePasses = pcall(function()
		return require(script.Parent:FindFirstChild("GamePassService"))
	end)

	local out, any = {}, false
	for _, entry in PassConfig.all() do
		if PassConfig.isLive(entry) and type(entry.key) == "string" then
			any = true
			local row = { attr = tostring(player:GetAttribute(entry.attribute)) }
			if okG and type(GamePasses) == "table" and type(GamePasses.ownsPassId) == "function" then
				local owns, known = GamePasses.ownsPassId(player, entry.id)
				row.server, row.known = tostring(owns), tostring(known)
			end
			out[entry.key] = row
		end
	end
	return any and out or nil
end

local function serverContext(player: Player)
	local levels = {}
	for _, t in levelKeys() do
		levels[t.name] = player:GetAttribute(t.attr) or 0
	end

	local joined = joinedAt[player]
	return {
		accountAge = player.AccountAge,
		membership = player.MembershipType.Name,
		localeId = player.LocaleId,
		coins = player:GetAttribute("Coins") or 0,
		rebirths = player:GetAttribute("Rebirths") or 0,
		totalEarned = player:GetAttribute("TotalEarned") or 0,
		carrying = player:GetAttribute("CurrentWeight") or 0,
		levels = levels,
		-- The answer to every "I paid for X and it does not work". See passContext.
		passes = passContext(player),
		-- How long they had been playing when they said this. "Quit after four
		-- minutes" and "said this at hour two" are different reports.
		sessionMin = joined and math.floor((os.clock() - joined) / 60) or nil,
		playersOnline = #Players:GetPlayers(),
		jobId = (game.JobId ~= "") and game.JobId or nil,
	}
end

----------------------------------------------------------------
-- SUBMISSION
----------------------------------------------------------------
local function onSubmit(player: Player, payload: any)
	-- A bare string is still accepted. It is what the first version of the
	-- client sent, and a player on a stale client should not be told their
	-- feedback failed.
	local raw, client
	if type(payload) == "string" then
		raw = payload
	elseif type(payload) == "table" then
		raw, client = payload.text, payload.client
	else
		return
	end
	if type(raw) ~= "string" then
		return
	end

	local message = tidy(raw)
	if #message < MIN_CHARS then
		reply(player, false, "Tell us a little more than that!")
		return
	end

	local now = os.clock()
	local last = lastSent[player]
	if last and now - last < COOLDOWN then
		reply(player, false, string.format("Hang on %d seconds, then send another.",
			math.ceil(COOLDOWN - (now - last))))
		return
	end

	-- Claimed BEFORE the write, not after. SetAsync yields, and without this a
	-- player leaning on the button gets several requests past the check while
	-- the first is still in flight -- which is exactly the case the cooldown
	-- exists for.
	lastSent[player] = now

	local at = os.time()
	local entry = {
		userId = player.UserId,
		name = player.Name,
		displayName = player.DisplayName,
		text = message,
		at = at,
		-- The dashboard shows raw JSON, and a unix timestamp is not something
		-- anyone reads at a glance. Both, so it sorts AND reads.
		when = os.date("!%Y-%m-%d %H:%M:%S UTC", at),
		placeVersion = game.PlaceVersion,
		-- Marks test submissions so a real one is never actioned as a test, or
		-- the other way round.
		studio = RunService:IsStudio() or nil,
		client = sanitiseClient(client),
		server = serverContext(player),
	}

	local key = string.format("%d_%d", at, player.UserId)
	local ok, err = pcall(function()
		-- The userIds argument associates the entry with its author for a data
		-- request. Without it this is orphaned personal data that cannot be
		-- found again if the player ever asks for it.
		store:SetAsync(key, entry, { player.UserId })
	end)

	if ok then
		reply(player, true, "Thanks! We read every one of these.")
	else
		-- Hand the cooldown back: they did not get to say anything, so making
		-- them wait 45 seconds to retry would be punishing them for our outage.
		lastSent[player] = nil
		warn("[Feedback] SetAsync failed for " .. player.Name .. ": " .. tostring(err))
		reply(player, false, "Could not send that just now -- try again in a moment.")
	end
end

----------------------------------------------------------------
-- READING IT BACK, IN GAME
----------------------------------------------------------------
--[[
	WHO MAY OPEN THE INBOX IS DECIDED HERE AND NOWHERE ELSE.

	The client never says who it is. It asks, and this answers -- both checks run
	against the Player object the server already holds, so there is nothing in
	the exchange for an exploiter to forge. A client that fires AdminFetch
	without being on this list gets "Not authorised" and the store is never
	touched.

	The allowlist is the guaranteed half. The group check is for whoever else
	runs the place: 250 sits just under Owner (255) deliberately, so it cannot
	grant anyone by accident. Lower it if the group's admin rank is further down.

	THE VERDICT IS CACHED per player, because GetRankInGroup is a network call --
	without this, a client firing the remote in a loop would have the server
	making one web request per fire on its behalf.
]]
-- THE NAMES IN THIS TABLE ARE USERNAMES, NOT DISPLAY NAMES, and the two are
-- routinely different -- 3060382122 is Koolguymean here and shows as "joint" in
-- game. Anybody being looked up or removed by the name they are known by has to
-- be resolved through UserService:GetUserInfosByUserIdsAsync first, or the wrong
-- person comes off the list. (254153724 / imad166, display name MABLINKIE, was
-- removed on 2026-08-29 for exactly this reason.)
local ADMIN_IDS = {
	[1210700083] = true,       -- IsABigBot
	[139112508]  = true,       -- Endey678
	[3159364800] = true,       -- sooad_sooad
	[3060382122] = true,       -- Koolguymean
	[254153724]  = true,       -- imad166 (owner)
}

--[[
	THE GROUP PATH IS OFF, AND THAT IS THE POINT.

	It used to be rank >= 250 in the group that owns the place, which reads as a
	sensible fallback and is not: "Speedy Clothes" has TWO roles at or above that
	-- Owner (255) and Co-Owner (253) -- and Co-Owner holds more people than the
	four named above. Left on, this list would not be the answer to "who can read
	the feedback"; the group's member list would be, and it would change without
	anyone touching this file.

	So the allowlist is now the whole gate. Set this back to a number to reopen
	the group path -- 253 admits every Co-Owner, 255 the group owner alone.
]]
local GROUP_ID = 4620487       -- game.CreatorId; this place is group-owned
local MIN_GROUP_RANK = nil

-- Newest N. ListKeysAsync plus one GetAsync per key is the entire cost of a
-- refresh, and the read budget is 60 + 10 per player per minute -- so this cap
-- is what stops one impatient press spending the whole server's minute.
local MAX_FETCH = 40
local CACHE_FOR = 45

local cache = { at = -math.huge, entries = nil, listed = 0 }
local fetching = false

local function isAdmin(player: Player): boolean
	local known = adminOf[player]
	if known ~= nil then
		return known
	end

	local verdict = false
	if ADMIN_IDS[player.UserId] then
		verdict = true
	elseif MIN_GROUP_RANK then
		-- GetRankInGroup yields and throws if the group service is having a
		-- moment. A failure has to read as "not an admin", never as "sure".
		local ok, rank = pcall(function()
			return player:GetRankInGroup(GROUP_ID)
		end)
		verdict = ok and rank >= MIN_GROUP_RANK
	end

	adminOf[player] = verdict
	return verdict
end

local function readStore()
	local pages = store:ListKeysAsync("", 100)
	local keys = {}
	repeat
		for _, k in pages:GetCurrentPage() do
			keys[#keys + 1] = k.KeyName
		end
		if pages.IsFinished then
			break
		end
		if not pcall(function() pages:AdvanceToNextPageAsync() end) then
			break
		end
	until false

	-- "<unixtime>_<userId>", and the timestamp is ten digits wide until 2286,
	-- so a descending string sort is newest-first without parsing anything.
	table.sort(keys, function(a, b) return a > b end)

	local listed = #keys
	local entries = {}
	for _, k in keys do
		if #entries >= MAX_FETCH then
			break
		end
		local ok, v = pcall(function() return store:GetAsync(k) end)
		-- A key that lists but will not fetch is a tombstone the listing has
		-- not caught up with. Not an error, and not an entry.
		if ok and type(v) == "table" then
			v._key = k
			entries[#entries + 1] = v
		end
	end
	return entries, listed
end

local function cachedEntries()
	if cache.entries and os.clock() - cache.at < CACHE_FOR then
		return cache.entries, cache.listed, true
	end

	-- ONE READER AT A TIME. Two admins pressing Refresh together would each run
	-- a full ListKeys plus forty GetAsync against the same budget to arrive at
	-- the same answer; the second waits for the first instead.
	if fetching then
		local waited = 0
		while fetching and waited < 15 do
			task.wait(0.2)
			waited += 0.2
		end
		if cache.entries then
			return cache.entries, cache.listed, true
		end
	end

	fetching = true
	local ok, entries, listed = pcall(readStore)
	fetching = false

	if not ok then
		warn("[Feedback] admin read failed: " .. tostring(entries))
		return nil, 0, false
	end
	cache.at, cache.entries, cache.listed = os.clock(), entries, listed
	return entries, listed, false
end

local function onAdminFetch(player: Player, payload: any)
	local admin = isAdmin(player)

	-- The hello never touches the store, so a client asking whether it may open
	-- the panel costs nothing and tells a non-admin nothing beyond "no".
	if type(payload) == "table" and payload.hello then
		remotes.AdminData:FireClient(player, { hello = true, ok = admin })
		return
	end

	if not admin then
		remotes.AdminData:FireClient(player, { ok = false, reason = "Not authorised." })
		return
	end
	if not store then
		remotes.AdminData:FireClient(player, { ok = false, reason = "Feedback store is offline." })
		return
	end

	local entries, listed, wasCached = cachedEntries()
	if not entries then
		remotes.AdminData:FireClient(player, { ok = false, reason = "Could not read the store." })
		return
	end
	remotes.AdminData:FireClient(player, {
		ok = true,
		entries = entries,
		listed = listed,
		cached = wasCached,
		max = MAX_FETCH,
	})
end

--[[
	DELETING ONE, WHICH IS THE ONE THING HERE THAT CANNOT BE UNDONE.

	RemoveAsync has no counterpart -- the entry is gone and there is no version
	of it to restore. So this re-checks admin (the fetch having passed earlier is
	not a licence), and shape-checks the key rather than merely requiring a
	string: every key this system writes is "<unixtime>_<userId>", so anything
	else is a typo or a client reaching for a key it did not read out of here.

	The CACHE IS DROPPED, not edited. The key listing keeps returning a removed
	key for a while afterwards, so a cache patched by hand and a cache rebuilt
	from the store would disagree about what exists. Dropping it means the next
	refresh is authoritative, and in the meantime the client is told exactly
	which card to take down -- cheaper than a full re-read for one deletion.

	The deletion is PRINTED with who did it. This is the only destructive action
	in the game reachable from a UI, and a server log is the only record of it.
]]
local function onAdminDelete(player: Player, key: any)
	if not isAdmin(player) then
		remotes.AdminData:FireClient(player, { ok = false, deleteFailed = true, reason = "Not authorised." })
		return
	end
	if not store then
		remotes.AdminData:FireClient(player, { ok = false, deleteFailed = true, reason = "Feedback store is offline." })
		return
	end
	if type(key) ~= "string" or not key:match("^%d+_%d+$") then
		remotes.AdminData:FireClient(player, { ok = false, deleteFailed = true, reason = "That is not a feedback key." })
		return
	end

	local ok, err = pcall(function()
		store:RemoveAsync(key)
	end)
	if not ok then
		warn("[Feedback] RemoveAsync failed for " .. key .. ": " .. tostring(err))
		remotes.AdminData:FireClient(player, { ok = false, deleteFailed = true, reason = "Could not delete that one." })
		return
	end

	cache.entries, cache.at = nil, -math.huge
	print(string.format("[Feedback] %s (%d) deleted %s", player.Name, player.UserId, key))
	remotes.AdminData:FireClient(player, { ok = true, deleted = key })
end

--[[
	WHAT CAN BE GIVEN, AND THROUGH WHOSE FRONT DOOR.

	Every kind goes through the system that OWNS that thing rather than writing
	its state from here:

		coins     SellServer.addCoins     the currency adapter, so OnCoinsChanged
		                                  fires and anything downstream sees it
		level     Lv_<key> + applyAll     ProgressionServer re-derives every
		                                  effect from the attributes
		rebirth   Rebirths + applyAll     the same door
		pet       PetServer.grant         owns the roster, the cap and the
		                                  replication
		vehicle   AtvTier                 the SAME attribute a coin purchase and
		                                  a game pass both write

	THE VEHICLE ONE IS NOT A GAME PASS, and cannot be. Pass ownership belongs to
	Roblox and there is no server call that grants one. What this gives is what
	the pass UNLOCKS -- the tier id in AtvTier -- which is exactly the decision
	GamePassService already made: "owning a pass is not a second kind of
	ownership", it writes the same attribute a purchase does. So a comped
	Tidebreaker is indistinguishable from a bought one everywhere in the game,
	and GamePassService's floor watcher only ever RAISES a value, so it will not
	undo this.

	EVERY LIST IS READ FROM THE LIVE CONFIG. Not from the client's payload, and
	not from a copy kept here. ProgressionConfig.Tracks went from eight entries
	to four during the afternoon this was written -- a hardcoded list would now
	be handing out levels in tracks that no longer exist.
]]
local MAX_GRANT = 1000000

local cfgCache = {}
local function cfg(name: string, inst: Instance?)
	if cfgCache[name] == nil then
		local ok, mod = false, nil
		if inst then
			ok, mod = pcall(function() return require(inst) end)
		end
		-- false, not nil: nil would retry the require on every grant.
		cfgCache[name] = (ok and mod) or false
	end
	return cfgCache[name] or nil
end

local function progConfig()
	return cfg("prog", ReplicatedStorage.Modules:FindFirstChild("ProgressionConfig"))
end
local function petConfig()
	return cfg("pets", ReplicatedStorage.Modules:FindFirstChild("PetConfig"))
end
local function atvConfig()
	return cfg("atv", ReplicatedStorage:FindFirstChild("AtvConfig"))
end
local function sellServer()
	return cfg("sell", script.Parent:FindFirstChild("SellServer"))
end
local function progServer()
	return cfg("progsrv", script.Parent:FindFirstChild("ProgressionServer"))
end
local function petServer()
	return cfg("petsrv", script.Parent:FindFirstChild("PetServer"))
end

local function tutorialServer()
	return cfg("tutsrv", script.Parent:FindFirstChild("TutorialServer"))
end
local function tutorialConfig()
	return cfg("tut", ReplicatedStorage.Modules:FindFirstChild("TutorialConfig"))
end
local function inventory()
	return cfg("inv", ReplicatedStorage.Modules:FindFirstChild("InventoryController"))
end
local function boardConfig()
	return cfg("board", ReplicatedStorage.Modules:FindFirstChild("LeaderboardConfig"))
end

local function commas(n: number): string
	local s = tostring(math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (s:gsub("^,", ""))
end

-- After a level or a rebirth changes, ProgressionServer is what turns the
-- attribute into an effect, and push() is what tells the client's shop about
-- it. Writing the attribute alone leaves the player faster on paper only.
local function reapply(p: Player)
	local Prog = progServer()
	if not Prog then
		return
	end
	if Prog.applyAll then
		pcall(Prog.applyAll, p)
	end
	if Prog.push then
		pcall(Prog.push, p)
	end
end

--------------------------------------------------------------------
-- Each giver returns (ok, what) -- `what` is the phrase the panel shows.
--------------------------------------------------------------------
local GIVERS = {}

GIVERS.coins = function(p: Player, _key: string?, amount: number?)
	if type(amount) ~= "number" or amount < 1 or amount > MAX_GRANT then
		return false, string.format("Amount must be 1 to %s.", commas(MAX_GRANT))
	end
	local Sell = sellServer()
	if not Sell or type(Sell.addCoins) ~= "function" then
		return false, "Currency system unavailable."
	end
	-- Tagged so a studio grant can never be mistaken for earned income on the
	-- economy report. It is a real movement and it is logged, just not as play.
	Sell.addCoins(p, amount, "admin")
	return true, commas(amount) .. " coins"
end

GIVERS.level = function(p: Player, key: string?, amount: number?)
	local PC = progConfig()
	if not PC then
		return false, "Progression config unavailable."
	end
	local track = PC.TrackByKey and key and PC.TrackByKey[key]
	if not track then
		return false, "No such upgrade."
	end
	local maxLv = PC.MaxLevel or 60
	if type(amount) ~= "number" or amount < 0 or amount > maxLv then
		return false, string.format("Level must be 0 to %d.", maxLv)
	end
	p:SetAttribute((PC.AttrPrefix or "Lv_") .. key, amount)
	reapply(p)
	return true, string.format("%s to level %d", track.name or key, amount)
end

--[[
	THE BOUND IS A TYPO GUARD, NOT THE GAME'S CEILING -- the tide ladder has not
	had one since 2026-09-11 (ProgressionConfig.Rebirth.LadderTides), so this
	can no longer be "whatever the game allows".

	SanityCap is the number SaveService loads against, and using the same one
	here is what stops this panel writing an attribute the player's own profile
	would refuse on the next join -- a grant that silently un-grants itself is
	the worst answer available. Every curve in the rebirth block is exponential
	in this number, so the guard is about keeping the arithmetic finite rather
	than about fairness; anything under it is a legitimate thing to hand a
	tester, including tides past the authored run.
]]
GIVERS.rebirth = function(p: Player, _key: string?, amount: number?)
	local PC = progConfig()
	local maxR = (PC and PC.Rebirth and PC.Rebirth.SanityCap) or 1000
	if type(amount) ~= "number" or amount ~= amount or amount < 0 or amount > maxR then
		return false, string.format("Rebirths must be 0 to %d.", maxR)
	end
	p:SetAttribute("Rebirths", amount)
	reapply(p)
	return true, "rebirth " .. tostring(amount)
end

GIVERS.pet = function(p: Player, key: string?, _amount: number?)
	local PetCfg = petConfig()
	local def = PetCfg and type(PetCfg.Pets) == "table" and key and PetCfg.Pets[key] or nil
	if not def then
		return false, "No such pet."
	end
	local Pets = petServer()
	if not Pets or type(Pets.grant) ~= "function" then
		return false, "Pet system unavailable."
	end
	-- grant() refuses at MaxOwned. That is its rule about its own system and
	-- not something to route around from here.
	if not Pets.grant(p, key) then
		return false, (def.DisplayName or key) .. " refused -- their pet slots may be full."
	end
	return true, tostring(def.DisplayName or key)
end

GIVERS.vehicle = function(p: Player, key: string?, _amount: number?)
	local AC = atvConfig()
	if not AC or type(AC.Tiers) ~= "table" then
		return false, "Vehicle config unavailable."
	end
	local tier
	for _, t in AC.Tiers do
		if tostring(t.id) == tostring(key) then
			tier = t
			break
		end
	end
	if not tier then
		return false, "No such vehicle."
	end
	p:SetAttribute(AC.OwnedAttribute or "AtvTier", tier.id)
	return true, tostring(tier.name or ("tier " .. tostring(tier.id)))
end

--[[
	REPLAY THE ONBOARDING. The only giver that hands over nothing.

	IT IS HERE RATHER THAN BEHIND A CHAT COMMAND OR A STUDIO-ONLY HOOK because
	everything a reset needs is already standing on this remote: the allowlist
	gate at the top of onAdminGrant, the two-press SURE? on the panel, and the
	audit line that records who did it to whom. A second gate somewhere else
	would be a second thing to get wrong, and a Studio-only hook could not be
	used to check the onboarding on a live server, which is where the drop-off
	was measured.

	THE WORK IS TutorialServer'S, not this file's. A reset is three attributes
	and a whitelisted save-flag clear, and every one of those belongs to the
	module that owns the tutorial -- see TutorialServer.restart, which is also
	what a command-bar caller should use.
]]
GIVERS.tutorial = function(p: Player, _key: string?, _amount: number?)
	local TS = tutorialServer()
	if not TS or type(TS.restart) ~= "function" then
		return false, "Tutorial system unavailable."
	end
	return TS.restart(p)
end

--[[
	THE WHOLE ONBOARDING, LAST STEP INCLUDED.

	`tutorial` above replays the card and touches no levels, which
	TutorialServer.restart's own note argues for and which is the right default.
	It has one consequence that makes it useless for checking the END of the
	onboarding: the card's final ask is "buy Sifter Width", and everything that
	steers a player to it -- the pulsing row in the shop, the three others going
	LOCKED, and ProgressionServer refusing to sell them -- hangs off
	TutorialConfig.locksOtherTracks, which is false the moment that track has
	been bought once. On any account that has played (and on every dev account,
	where DevGrant stamps all four tracks to 60 at join) the last step cannot be
	shown at all. Verified: with the track at 60 the shop paints four ordinary
	rows; with it at 0 the Sifter Width button breathes, the other three read
	"Locked -- buy Sifter Width first", and the server answers a press with
	"Buy Sifter Width first -- the tutorial is showing you how."

	So this verb is the restart PLUS the one extra fact that steer reads.

	IT COSTS THAT ONE TRACK'S LEVELS and there is no way around it: "never
	bought" is the state being restored. Coins, the other three tracks, the car
	ladder, rebirths and pets are all untouched -- `tutorial` remains the verb
	for anyone who wants the card back without paying that.

	AND IT IS SESSION-SCOPED, which the phrase it returns says out loud.
	SaveService clamps every saved level to [1, MaxLevel] and captures through
	levelOf, which clamps the same way, so a level of 0 cannot be written to a
	profile -- by design, and not worth loosening game-wide for a dev verb. The
	done-flag clear DOES persist (restart goes through clearOneTimeFlag); the
	zeroed track does not, so a rejoin brings it back at level 1 and the steer
	goes quiet. Check the onboarding in the session you press this in.
]]
GIVERS.onboarding = function(p: Player, _key: string?, _amount: number?)
	local TS = tutorialServer()
	if not TS or type(TS.restart) ~= "function" then
		return false, "Tutorial system unavailable."
	end

	local PC, TC = progConfig(), tutorialConfig()
	if not (PC and TC and TC.FirstTrack) then
		return false, "Progression or tutorial config unavailable."
	end

	--[[
		EVERYTHING BACK TO WHAT A NEW ACCOUNT HAS, in the order below, and the
		order is most of this function.

		LEVEL 1, NOT 0. One is the floor everywhere -- ProgressionServer's join
		hook stamps it, SaveService clamps to it, and TutorialServer.hasBought
		treats `> 1` as a purchase -- so 1 is precisely "never bought" and it is
		what a new player carries. (An earlier cut of this wrote 0 to get past a
		bug in locksOtherTracks; that test has been fixed to agree with hasBought,
		and a 0 here would only be a level no save file can hold.)
	]]
	local prefix = PC.AttrPrefix or "Lv_"
	for _, t in PC.Tracks do
		p:SetAttribute(prefix .. t.key, 1)
	end

	-- Coins through SellServer, so its own listeners see the balance move rather
	-- than finding a different number the next time they look.
	local Sell = sellServer()
	if Sell and type(Sell.getCoins) == "function" and type(Sell.addCoins) == "function" then
		local held = Sell.getCoins(p) or 0
		if held > 0 then
			Sell.addCoins(p, -held, "admin")
		end
	end

	-- The tide ladder and both earnings counters. TotalEarned matters as well as
	-- TideEarned: TutorialConfig.looksNew reads it, and an account with a
	-- lifetime figure on it does not look new however empty the purse is.
	p:SetAttribute("Rebirths", 0)
	p:SetAttribute("TideEarned", 0)
	p:SetAttribute("TotalEarned", 0)

	--[[
		The machine and its rake. AtvTier goes to 0 rather than to a pass floor:
		GamePassService watches this attribute and re-raises it for anybody who
		actually paid for a machine, which is the behaviour we want -- a pass is
		not progress and a reset must not take one away.
	]]
	p:SetAttribute("AtvTier", 0)
	local AC = atvConfig()
	if AC and AC.Upgrades then
		for _, t in AC.Upgrades do
			p:SetAttribute((AC.CarAttrPrefix or "CarLv_") .. t.key, 0)
		end
	end

	-- The bag. Same call onRebirth makes, for the same reason: what is in it was
	-- earned under the run being wiped.
	local Inv = inventory()
	local bag = Inv and Inv.Server and Inv.Server.find and Inv.Server.find(p)
	if bag then
		pcall(function()
			bag:RemoveWhere(function()
				return true
			end)
		end)
	end

	-- The litter half of the rebirth gate reads lifetime-minus-a-mark, so moving
	-- the mark up to today's total is what makes this tide read zero. The
	-- LIFETIME counter is deliberately untouched -- it is a global leaderboard
	-- rank, not this account's progress.
	local LB = boardConfig()
	if LB and LB.TrashAttribute then
		p:SetAttribute("TideTrashBase", tonumber(p:GetAttribute(LB.TrashAttribute)) or 0)
	end

	--[[
		NOW YIELD, AND ONLY THEN RESTART THE CARD.

		TutorialServer watches every `Lv_` attribute and re-stamps the done flag
		whenever hasBought is true. Every write above is one it is listening to,
		and AttributeChanged is DEFERRED -- so clearing the flag first would be
		undone a frame later by our own writes. Measured doing exactly that: the
		panel reported success and TutorialDone was back to true.

		One yield lets that stamp land while we are still here, and restart clears
		the flag afterwards. By this point every track is 1, so hasBought is false
		and nothing will stamp it again.
	]]
	task.wait()
	if not p.Parent then
		return false, "They left."
	end

	local ok, phrase = TS.restart(p)
	if not ok then
		return false, phrase or "Tutorial restart refused."
	end

	--[[
		AND THE HOLD, LAST. restart clears the done flag; this says the blank state
		is deliberate and must survive a rejoin -- DevGrant reads it two seconds
		into every Studio join and skips its billion coins and forty tides while it
		is set. TutorialServer.finish clears it, so the sandbox comes back on the
		join after the tutorial is finished and there is nothing to switch off.

		After restart, not before: finish() clears this flag, and the deferred stamp
		above can still be in flight until restart has run.
	]]
	p:SetAttribute(TC.HoldAttribute, true)

	-- Turns the attributes into effects and repaints the shop, which is where
	-- the steer shows up. Without it the rake stays 48.5 studs wide and the panel
	-- keeps drawing the levels it last heard about.
	reapply(p)

	return true, string.format("blanked to a new account and %s -- held until the "
		.. "tutorial is finished, so a rejoin will not re-grant", phrase or "card restarted")
end

local function refuseGrant(player: Player, why: string)
	remotes.AdminData:FireClient(player, { ok = false, grantFailed = true, reason = why })
end

local function onAdminGrant(player: Player, payload: any)
	if not isAdmin(player) then
		refuseGrant(player, "Not authorised.")
		return
	end
	if type(payload) ~= "table" then
		return
	end

	local give = GIVERS[payload.kind]
	if not give then
		refuseGrant(player, "Do not know how to give that.")
		return
	end

	-- NaN and inf are numbers and survive a type() test; they are also what a
	-- crafted payload sends to get past a naive range check.
	local amount = payload.amount
	if amount ~= nil then
		if type(amount) ~= "number" or amount ~= amount
			or amount == math.huge or amount == -math.huge then
			refuseGrant(player, "That is not a number.")
			return
		end
		amount = math.floor(amount)
	end

	-- Shape-checked before it is ever used as a table index or an attribute
	-- name. The givers check it against the live config as well; this is so a
	-- malformed one cannot get that far.
	local key = payload.key
	if key ~= nil and (type(key) ~= "string" or #key > 48 or not key:match("^%w+$")) then
		refuseGrant(player, "That is not a valid choice.")
		return
	end

	local targets = {}
	if payload.target == 0 then
		for _, p in Players:GetPlayers() do
			targets[#targets + 1] = p
		end
	elseif type(payload.target) == "number" then
		local p = Players:GetPlayerByUserId(payload.target)
		if not p then
			refuseGrant(player, "That player has left the server.")
			return
		end
		targets[1] = p
	else
		refuseGrant(player, "No player chosen.")
		return
	end

	local done, what, why = {}, nil, nil
	for _, p in targets do
		local pok, ok, msg = pcall(give, p, key, amount)
		if not pok then
			warn("[Feedback] give " .. tostring(payload.kind) .. " failed for "
				.. p.Name .. ": " .. tostring(ok))
			why = why or "Something went wrong -- check the server log."
		elseif ok then
			done[#done + 1] = p.Name
			what = msg
		else
			why = why or msg
		end
	end

	if #done == 0 then
		refuseGrant(player, why or "Nobody was given anything.")
		return
	end

	-- Printed with who did it, for the same reason the deletion is: this moves
	-- the economy and the server log is the only record of it.
	print(string.format("[Feedback] %s (%d) gave %s to %s",
		player.Name, player.UserId, tostring(what), table.concat(done, ", ")))

	remotes.AdminData:FireClient(player, {
		ok = true,
		granted = true,
		what = what,
		names = done,
	})
end

function FeedbackServer.start()
	if started then
		return
	end
	started = true

	remotes = ensureRemotes()

	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	store = ok and result or nil
	if not store then
		warn("[Feedback] no DataStore (" .. tostring(result) .. "). In Studio this is "
			.. "Game Settings -> Security -> Enable Studio Access to API Services.")
	end

	remotes.SubmitFeedback.OnServerEvent:Connect(function(player, payload)
		if not store then
			reply(player, false, "Feedback is offline right now, sorry!")
			return
		end
		onSubmit(player, payload)
	end)

	-- Both halves, because this starts LAST in ServerMain and the first player
	-- into a Studio test is already here by the time it does.
	for _, p in Players:GetPlayers() do
		joinedAt[p] = joinedAt[p] or os.clock()
	end
	Players.PlayerAdded:Connect(function(p)
		joinedAt[p] = os.clock()
	end)
	remotes.AdminFetch.OnServerEvent:Connect(onAdminFetch)
	remotes.AdminDelete.OnServerEvent:Connect(onAdminDelete)
	remotes.AdminGrant.OnServerEvent:Connect(onAdminGrant)

	Players.PlayerRemoving:Connect(function(p)
		lastSent[p] = nil
		joinedAt[p] = nil
		adminOf[p] = nil
	end)
end

return FeedbackServer
