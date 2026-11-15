--[[
	LeaderboardConfig  --  ReplicatedStorage.Modules.LeaderboardConfig

	THE THREE WORLD LEADERBOARDS, in one place: what they rank, what they are
	called, what colour they wear and where they stand.

		ServerScriptService.LeaderboardBuilder   the three boards as objects
		ServerScriptService.LeaderboardService   the stores, the polling, the paint

	GLOBAL MEANS GLOBAL. These rank every account that has ever played the game,
	not the people currently in the server -- that is what the Roblox player list
	already does (CTBBridge.mirrorLeaderstats). Cross-server ranking is what an
	OrderedDataStore is for, and it is the only structure that can answer "who is
	top" without reading every profile.

	WHY THIS IS A SHARED MODULE FOR A SERVER-ONLY FEATURE. The boards are drawn
	server-side (LeaderboardService's header says why there is no remote), so no
	client needs any of this today. It lives in Modules anyway because
	TrashAttribute below is read by the two collection paths that increment it,
	and a stat's name wants one home rather than three string literals that
	drift apart the first time one of them is renamed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- The rakeable fields themselves. Required rather than copied, because WHERE a
-- board stands is derived from the field it overlooks -- see boardLine below.
local Field = require(ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Config"))

local LeaderboardConfig = {}

--------------------------------------------------------------------------
-- THE STAT THE GAME DID NOT ALREADY KEEP
--------------------------------------------------------------------------
--[[
	Coins and Rebirths were both already on the player and already saved. "Trash
	picked" was not: the game counted WEIGHT carried and COINS earned, and it
	threw the piece count away at both of the two places litter is collected.

	So this is a new lifetime counter, incremented at those two paths --
	CTBBridge.tryAdd (CTB's own buried field, which is most of the sand) and
	TrashCollectionService.collect (the tagged props the vehicle nets pick up) --
	and persisted by SaveService alongside everything else.

	LIFETIME, AND A REBIRTH DOES NOT CLEAR IT. A rebirth takes back coins,
	levels and the machine; it is not meant to take back the record of work
	done, and a "most trash" board that reset every tide would rank nobody but
	the players who had not rebirthed recently.
]]
LeaderboardConfig.TrashAttribute = "TrashPicked"

--------------------------------------------------------------------------
-- THE STORES
--------------------------------------------------------------------------
--[[
	The schema rides in the store NAME, exactly as SaveService does it, and for
	the same two reasons: bumping it starts a clean ranking rather than migrating
	one in place, and STUDIO GETS ITS OWN STORE so a test session cannot put a
	fake score on the live board. That second half is not tidiness here -- an
	OrderedDataStore is public-facing by definition, so a Studio write lands in
	front of every player in the game.
]]
LeaderboardConfig.SCHEMA = 1

function LeaderboardConfig.storeName(key: string): string
	return string.format("ctb_lb_%s_v%d%s", key, LeaderboardConfig.SCHEMA,
		RunService:IsStudio() and "_studio" or "")
end

--------------------------------------------------------------------------
-- CADENCE
--------------------------------------------------------------------------
--[[
	BOTH NUMBERS ARE SET BY THE DATASTORE BUDGET, not by taste.

	Reads: GetSortedAsync gets its own allowance, and three boards on a 60s poll
	is three calls a minute against it whatever the server population is. A
	leaderboard that is a minute stale is a leaderboard; one that costs a request
	per player per board is a throttle.

	Writes: SetAsync allows 60 + 10 per player per minute. Publishing three
	values per player every 90 seconds is 2 writes per player per minute at the
	worst, and LeaderboardService only writes a value that actually CHANGED --
	which on the rebirth and trash boards is almost never.
]]
LeaderboardConfig.PollSeconds = 60
LeaderboardConfig.PublishSeconds = 90

--[[
	HOW OFTEN "WHERE YOU STAND" IS RECOMPUTED, and it is not on either of the two
	numbers above because it COSTS NOTHING. The standings pass touches no store at
	all: it walks the ten rows the last poll already fetched and compares them
	against a value read straight off the player. Three boards, ten rows, however
	many people are in the server -- arithmetic.

	FIVE SECONDS BECAUSE THE GAP IS THE POINT. "1,240 more to reach the board"
	that only moves once a minute is a sign; one that ticks down while you are
	raking is the thing that keeps you raking. It is deliberately far quicker than
	the board beside it, which cannot be -- that one is a web request.
]]
LeaderboardConfig.StandingsSeconds = 5

-- How many rows a board carries. Ten is what fits at a size somebody can read
-- from the sand without walking up to it, which is the only number that matters
-- for a thing standing in the world rather than sitting in a panel.
LeaderboardConfig.TopN = 10

--------------------------------------------------------------------------
-- WHERE THEY STAND
--------------------------------------------------------------------------
--[[
	ALONG A FIELD'S RIGHT-HAND EDGE, facing back across it. "Right" is the
	player's: on the beach they spawn at the south edge (0, -139) looking north
	into the field, and from there the -X side is the one on their right. Every
	island is laid out the same way round, so the same side works on all of them.

	OUTSIDE THE RAKEABLE SQUARE, AND THAT IS LOAD-BEARING RATHER THAN TIDY.
	CTB.Config.ISLANDS[n].resetAt is 1.0 on every field in this game, which means
	a field tolerates NO blocked cells -- one solid part parked on one column and
	that island never turns over again. See the long note on ISLANDS[1].resetAt.
	So a board line is always the field's half-width PLUS Clearance, never a typed
	coordinate that could quietly fall inside a square somebody later grew.

	The row runs along Z and is centred on the field, so it is broadside to a
	player working it rather than edge-on to them.

	The Y is a starting height only: the builder raycasts for the real ground
	under each board and drops it onto whatever is actually there.
]]
LeaderboardConfig.RowStep = Vector3.new(0, 0, 24)    -- one board to the next
LeaderboardConfig.Clearance = 10                     -- field edge to the board line

LeaderboardConfig.BoardWidth = 20
LeaderboardConfig.BoardHeight = 14
LeaderboardConfig.BoardLift = 4.5                    -- ground to the bottom edge

--[[
	ONE ROW PER FIELD. `island` indexes CTB.Config.ISLANDS.

	The beach used to be the only one. These are the four fields you TRAVEL to --
	the ferry's own berths -- so the boards are wherever a player actually works.

	THE THREE THAT ARE DELIBERATELY ABSENT, all of them sealed interiors rather
	than shores, and all measured rather than assumed:

	  [3] Vault           IMPOSSIBLE. Its hall columns stand 75 studs out from a
	                      field of half-width 64, so the only line that clears the
	                      square is 11 studs wide -- and the architrave over it
	                      leaves 2 studs of headroom for a board 14 studs tall.
	  [6] Inner Shrine    Room enough (walls at 96, ceiling +35), but it is a
	                      sealed hall behind a tide gate, not a shore.
	  [7] Magma Chamber   Room enough (walls at 116, ceiling +45), but its floor
	                      at the board line is Neon lava plate -- a board would
	                      need a cut pad under it first.

	Adding one back is a row here plus the matching row in FreeRewardConfig.Sites.

	`along` shifts the row's CENTRE along Z, away from the field's own middle, and
	two of the four need it because something is standing where the row wants to be.

	BOTH WERE FOUND BY A SIGHT-LINE TEST, NOT A COLLISION TEST, and that
	distinction is the whole reason they were nearly missed. The first pass swept
	for CanCollide parts and reported both of these lines clear -- but a cactus
	arm and a sakura trunk stand between the player and the sign whether or not a
	raycast stops on them, and a board you cannot read is not a board. Anything
	moved here has to be re-checked against what can be SEEN through, by testing
	the volume in front of the face for any part with Transparency < 0.9.

		Dunes  -36  a cactus in Island2.DesertDressing stands on that line from
		            z = 0 northward and blocks every clearance out to +46. The
		            southern half is clear; -36 puts the boards at z -60/-36/-12.
		Cove   -36  a sakura trunk stands over the middle of that line, AND the
		            ground rises into a mound between z 1588 and 1612. -24 clears
		            the trunk but leaves one board of the three standing 7.5 studs
		            above its neighbours, because each one is dropped onto its own
		            ground -- correct, and it reads as a broken row. -36 puts all
		            three on flat sand at y 3.0. The reward sign opposite carries
		            the same -36 so the pair stays face to face.

	SO A SITE NEEDS TWO CHECKS, NOT ONE: is the sight line clear, and is the
	GROUND under the whole row level? A row is dropped board by board, so sloping
	ground steps it. Sweep `along` for a stretch where the three ground samples
	agree to within about half a stud.
]]
LeaderboardConfig.Sites = {
	{ island = 1 },                  -- Beach, exactly where it always was: x -138, z -24/0/24
	{ island = 2, along = -36 },     -- Dunes -- cactus, see above
	{ island = 4, along = -36 },     -- Sakura Cove -- trunk + a mound, see above
	{ island = 5 },                  -- Ashfall Isle
	{ island = 8 },                  -- Penguin Island -- Island5Builder keeps the west edge clear for it
}

--[[
	Resolve a site to the line its boards stand on.

	SHARED WITH THE FREE REWARD SIGN, which stands on the opposite edge of the
	same fields (FreeRewardConfig.Sites, side = 1) and is the same object at the
	same size. One implementation so the two can never disagree about where a
	field's edge is.

	Returns: the X of the board faces, the direction they look (back across the
	field), the field's Z centre, and its name for logging.
]]
function LeaderboardConfig.boardLine(site): (number, Vector3, number, string)
	local f = Field.ISLANDS[site.island]
	assert(f, "[Leaderboard] no island " .. tostring(site.island) .. " in CTB.Config.ISLANDS")
	local half = f.grid * Field.TILE * 0.5
	local side = site.side or -1
	local x = f.cx + side * (half + (site.clearance or LeaderboardConfig.Clearance))
	-- The faces look back the way they came, across the field.
	return x, Vector3.new(-side, 0, 0), f.cz, f.name
end

--------------------------------------------------------------------------
-- THE WINNER'S PODIUM
--------------------------------------------------------------------------
--[[
	The player at the top of each board stands in front of it on a podium,
	dancing. LeaderboardWinner builds the rig; LeaderboardBuilder builds the
	podium it stands on.

	FIVE STUDS IN FRONT, AND NOT ONE MORE. The clear strip between the boards
	(x -138) and the edge of the rakeable field (x -128) is nine studs wide, and
	a podium standing inside the field would sit on columns the sifter is
	supposed to rake -- the same reason the boards themselves stand clear of it.
	Five puts the whole podium, at 7.4 studs across, comfortably in the strip.

	AND THE HEIGHT IS SET BY WHAT IT COVERS. Anything standing in front of a
	board hides part of it: a 5.5-stud avatar on a 2-stud podium reaches y 10.4,
	and the board's bottom edge is at 7.5. Two studs is the tallest podium whose
	winner still tops out BELOW the first row -- which is why the freshness stamp
	moved up into the banner, since the strip it used to occupy is now the strip
	the winner's head passes through.
]]
LeaderboardConfig.PodiumStandoff = 5                 -- face of the board to podium centre
LeaderboardConfig.PodiumHeight = 2                   -- ground to the surface they stand on
LeaderboardConfig.PodiumWidth = 7.4

--------------------------------------------------------------------------
-- THE BOARDS
--------------------------------------------------------------------------
--[[
	`stat` is a KEY, not a getter: LeaderboardService owns how a stat is read,
	because two of the three come from other services (SellServer, then
	ProgressionServer) and a config file that reached into those would drag the
	whole server dependency graph into ReplicatedStorage.

	The tints are PanelKit's palette -- sun, foam, grape -- written out rather
	than required, so the one server-side thing that needs three colours does not
	have to pull in a UI kit to get them.
]]
LeaderboardConfig.Boards = {
	{
		key = "money",
		title = "MOST MONEY",
		blurb = "richest on the shore",
		stat = "coins",
		format = "money",
		tint = Color3.fromRGB(255, 200, 62),
		-- A DANCE EACH, and they are Roblox's own default emotes: an animation
		-- loaded onto a rig nobody is playing has to be owned by Roblox or by this
		-- place, and these three are the ones every avatar already knows. Three
		-- different ones because three winners doing the same move in a row along
		-- the sand reads as one prop copied three times.
		dance = 507771019,
	},
	{
		key = "trash",
		title = "MOST TRASH",
		blurb = "pieces picked up, all time",
		stat = "trash",
		format = "count",
		tint = Color3.fromRGB(94, 226, 196),
		dance = 507776043,
	},
	{
		key = "rebirths",
		title = "MOST REBIRTHS",
		blurb = "turns of the tide",
		stat = "rebirths",
		format = "count",
		tint = Color3.fromRGB(186, 128, 255),
		dance = 507777268,
	},
}

--------------------------------------------------------------------------
-- WHERE YOU STAND
--------------------------------------------------------------------------
--[[
	THE PERSONAL HALF OF A PUBLIC BOARD -- three player attributes per ranking,
	written by LeaderboardService and read by LeaderboardRank on the client.

	ATTRIBUTES RATHER THAN A REMOTE, which keeps LeaderboardService's header rule
	intact instead of bending it. That rule is "there is nothing on a leaderboard
	one player may see and another may not", and it is why the ten rows are drawn
	server-side onto a shared SurfaceGui. Your own rank is the one part of this
	feature that IS per-player -- so it needs a per-player channel, and this game
	already has one it uses for every other progress readout. No remote, no
	payload, no late-joiner handling: an attribute is simply there when the
	client first looks.

	PUBLIC, AND THAT IS FINE. Player attributes replicate to every client, so any
	player can read another's rank. It is the same information the board standing
	in front of them already shows, in the same units, about accounts that opted
	into a global ranking by playing.

	  LbRank_<key>   your position. NIL means "further down than the last row the
	                 board shows" -- an OrderedDataStore cannot answer "what number
	                 am I" without reading the whole store, so it is not guessed.
	  LbGap_<key>    what stands between you and the row above. When you are top
	                 it is your LEAD over second instead, and when you are level
	                 with somebody it is 0.
	  LbAhead_<key>  whose name that gap is measured against.
]]
function LeaderboardConfig.rankAttribute(key: string): string
	return "LbRank_" .. key
end

function LeaderboardConfig.gapAttribute(key: string): string
	return "LbGap_" .. key
end

function LeaderboardConfig.aheadAttribute(key: string): string
	return "LbAhead_" .. key
end

--------------------------------------------------------------------------
-- FORMATTING
--------------------------------------------------------------------------
--[[
	SHORTENED, NOT COMMA-GROUPED. A top money score runs to nine or ten digits
	and the board is twenty studs wide read from thirty studs away: "1,204,880,310"
	is a smear at that size where "1.2B" is a number. Grouping is kept for the
	small values, where every digit still fits and rounding would throw away the
	only thing separating two neighbouring rows.
]]
local function grouped(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

local UNITS = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }

function LeaderboardConfig.formatValue(n: number, format: string): string
	n = math.max(0, math.floor(tonumber(n) or 0))
	if format == "money" then
		if n < 1e6 then
			return "$" .. grouped(n)
		end
		for _, u in UNITS do
			if n >= u[1] then
				-- One decimal, and the trailing ".0" trimmed: "$4M" not "$4.0M".
				local v = string.format("%.1f", n / u[1]):gsub("%.0$", "")
				return "$" .. v .. u[2]
			end
		end
	end
	if n >= 1e6 then
		for _, u in UNITS do
			if n >= u[1] then
				local v = string.format("%.1f", n / u[1]):gsub("%.0$", "")
				return v .. u[2]
			end
		end
	end
	return grouped(n)
end

return LeaderboardConfig
