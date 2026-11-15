--[[
	TipConfig  --  ReplicatedStorage.Modules.TipConfig

	The rotating hint band that drops in at the top of the screen every few
	minutes. Data only: TipClient owns the clock and the chat commands, ToastKit
	owns the widget, and this file owns WHAT IS SAID and HOW OFTEN.

	THE POINT OF THE FEATURE IS THE GROUP TIP. The rest of the list is not
	padding -- a band that only ever says "join the group" is an advert and reads
	like one, and players learn to dismiss it without reading. Mixed in with real
	playing advice it stays worth looking at, which is what keeps the group line
	getting read at all. That is why the group tip is WEIGHTED rather than
	scheduled separately: it comes up about three times as often as any single
	hint, without ever being the only thing the band says.

	EVERY NON-GROUP TIP BELOW IS CHECKED AGAINST THE CODE, NOT REMEMBERED.
	A hint that is wrong is worse than no hint -- it sends a player to a counter
	that is not there and they conclude the game is broken, not the tip. Where a
	claim could not be verified it was WEAKENED until it could be (the wash tip
	says the washer takes the crust off, which WashServer does, and does NOT say a
	clean item sells for more, which nothing in ItemConfig actually says).
	If you add one, name the file you checked it against.
]]

local FreeRewardConfig = require(script.Parent:WaitForChild("FreeRewardConfig"))
-- For LocalPlayer alone, and only so the group line can read the name the
-- SERVER resolved. nil on the server, where groupNameFor falls back to the
-- literal -- which is correct there, since nothing server-side draws a tip.
local Players = game:GetService("Players")

local TipConfig = {}

--------------------------------------------------------------------------
-- THE CLOCK
--------------------------------------------------------------------------
--[[
	"Do not have it come up too often" is the whole brief for these four numbers.

	FIRST_DELAY is long on purpose. A hint band in the first thirty seconds lands
	on top of the opening shot and the tutorial card, which are already telling
	the player what to do -- a third voice there is noise, and the group tip in
	particular is asking a favour of somebody who has not decided whether they
	like the game yet.

	The gap is a RANGE rather than a fixed period so the band does not become
	metronomic; a player who can predict it stops reading it.
]]
--[[
	THE FIRST TIP OF A FIRST PLAYTHROUGH IS NOT A DRAW -- TipClient shows THIS one.

	Measured 2026-09-25, walking the first two minutes with a poller:

	  IntroClient mentions of tomorrow / daily / come back:  0
	  TutorialHud mentions of tomorrow / daily / come back:  0
	  the tutorial's send-off used to be "That is the loop. Off you go."

	So the daily reward -- the one mechanic whose entire purpose is to bring a
	player back -- was reachable only through the rail's gift icon and named only
	by a rotating tip. Against the session lengths measured 2026-09-22:

	  10.4% of one-day players quit under 60s  -> saw ZERO tips
	  30%   quit under 180s -> saw ONE  -> 2 of 12 tips mention returning: ~17%
	  median one-day session 7.2 min -> saw TWO                        -> ~33%

	Two thirds of median players were never told that coming back pays.

	Spending the first slot deterministically takes that to ~everyone who lasts
	75 seconds. It costs one draw out of a budget of six, and it costs it in the
	slot least able to afford a miss -- the one a third of players never get past.

	BY ID RATHER THAN BY INDEX, so reordering Tips cannot silently point this at
	something else. An id that does not exist falls back to a normal draw.
	Set to nil to restore the old behaviour exactly.
]]
TipConfig.FirstTipId = "daily"

TipConfig.FirstDelay = 75            -- seconds into the session before the first one
TipConfig.GapMin = 165               -- shortest gap between tips
TipConfig.GapMax = 255               -- longest gap between tips
TipConfig.Hold = 10                  -- seconds on screen before it leaves by itself

--[[
	AND THEN THEY STOP. (2026-09-11, off a player report: "fun game but i hate
	the random pop ups.. ruins the calmness of the game".)

	The clock above was tuned for how often a tip appears and nobody ever asked
	the other question, which is how many there should be IN TOTAL. The rotation
	was a `while true`, so the answer was "forever": about fifteen in a
	forty-five minute session, and roughly NINETY in the 335-minute sessions our
	heaviest player actually plays. At that point the band is not teaching
	anybody anything, it is just something that happens to you every three
	minutes for five hours.

	Six covers the first ~18 minutes, which is the window where a hint is still
	telling a player something they do not know.

	VETERANS GET TWO, and they get them for one reason only: a returning player
	may have missed a feature added since they last played. They do not need to
	be told where the green pad is. `rebirths > 0` is the test because it is the
	one flag that cannot be true by accident -- it only ever increments, and
	anyone who has reached it has been through the whole beach at least once.

	THE BUDGET IS PER SESSION, not per account, and that is deliberate. It costs
	nothing to persist and a player who comes back tomorrow is allowed to be
	reminded; the complaint was never about the first tip.
]]
TipConfig.BudgetNew = 6              -- tips per session, first playthrough
TipConfig.BudgetVeteran = 2          -- tips per session, once rebirths > 0

--[[
	THE OFF SWITCH. Settings row "Helpful Tips", ON by default so nobody else's
	game changes. Same `Set_<key>` channel as every other row -- MenuHud writes
	the attribute, TipClient reads it, and there is no remote in between.
]]
TipConfig.SettingKey = "Tips"
TipConfig.Attribute = "Set_Tips"

-- How long to sit on a slot that could not be drawn because something else owned
-- the screen. Short enough that the tip still lands near the moment it was due,
-- long enough that the probe behind it is free. A skipped slot is NOT spent --
-- see the note in TipClient.rotate.
TipConfig.BusyRetry = 20

-- ON unless the player has explicitly turned the row off. `nil` is a player who
-- has never touched the row, which is nearly all of them.
function TipConfig.enabled(player: Instance?): boolean
	if not player then
		return true
	end
	return player:GetAttribute(TipConfig.Attribute) ~= false
end

--[[
	CHAT COMMANDS: /tip1 .. /tipN, /tip<name>, /tip and /tips.

	On for everybody, because there is nothing to abuse -- a tip is drawn on the
	client that asked for it, costs the server nothing and is not worth anything.
	Set this to false to make them Studio-only, the same way DevGrant gates itself
	on RunService:IsStudio().
]]
TipConfig.CommandsInLiveGame = true

--------------------------------------------------------------------------
-- THE TIPS
--------------------------------------------------------------------------
--[[
	`kind` is a ToastKit KINDS key and picks the colour and the pop's pitch:
		money (gold) | info (blue) | warn (amber) | pickup (green)
		level (violet) | tide (teal) | deny (red)

	`alias` is the word half of this tip's chat command -- /tip<alias>. It is also
	the SecondaryAlias on the numbered command, so /tip1 and /tipgroup are the
	same thing. Keep them unique and lower case.

	`weight` is relative, not a percentage. See the note at the top for why the
	group line carries five.

	THE WEIGHT IS NOT THE RATE, AND THE GAP IS NOT A BUG. On paper the group tip
	is 5 of 16, or 31%. MEASURED over 150 draws it comes out around 26%, and the
	reason is TipClient's no-repeat pass: whatever was shown last is held out of
	the next draw, and the heaviest entry is by far the most likely to be the one
	being held out. So the rule taxes the group line hardest -- which is the right
	way round, because back-to-back group tips are exactly what would make a
	player start ignoring the band. Do not "correct" the weights to hit 31%.
	It is still roughly three and a half times any single hint.
]]
TipConfig.Tips = {
	{
		id = "group",
		alias = "group",
		kind = "money",
		--[[
			5 -> 2 (2026-09-11). At weight 5 against nine tips of weight 1 this was a
			third of every draw, and a new player sees about THREE tips in their first
			ten minutes (FirstDelay 75, then GapMin 165) -- so the one stretch where
			the drop-off actually happens was spent mostly re-offering a reward they
			had already been shown a board for.

			Still the heaviest tip, because free coins for joining the group is the
			most valuable single thing on the list and it retires itself the moment it
			is claimed (see skipWhen). It just no longer crowds out pets, the wash bay
			and the Index in the window those most need to land.
		]]
		weight = 2,
		--[[
			BUILT FROM FreeRewardConfig RATHER THAN TYPED, so the number in the
			band and the number the server actually pays cannot drift apart. That
			is a real risk here and not a hypothetical one: this is the only
			place in the game that ADVERTISES the amount, so a hand-typed 1,000
			would go on being advertised for as long as it took somebody to
			notice, and the player who claimed a different figure would be right
			to call it a bait and switch.

			It says CLAIM IT AT THE BOARD because that is the honest instruction:
			joining the group does not pay by itself. FreeRewardService wants the
			claim, the panel is what makes it, and a board is where the panel lives.
			There is one on every field now (FreeRewardConfig.Sites), so "the reward
			board" is true wherever the player happens to be reading this.

			IT NO LONGER ASKS FOR A LIKE. It used to open "Like the game and join
			the ... group", which advertised a requirement nothing could check and
			that Roblox does not permit paying an individual for. The group is the
			whole of what is asked and the whole of what is checked -- see
			FreeRewardConfig.
		]]
		text = function(comma)
			--[[
				groupNameFor, NOT GroupName. This line runs on the CLIENT, where
				FreeRewardConfig.groupName() is IsServer-gated and hands back the
				fallback literal -- so this tip was advertising "Join the Clean the
				Beach group" while the five boards it points the player AT read
				"JOIN THE SPEEDY CLOTHES GROUP". Rendered on a live client to
				confirm it, 2026-09-25.

				The server now publishes what it resolved onto the player; this
				reads it back. See FreeRewardConfig.GroupNameAttribute.
			]]
			return string.format(
				"Join the %s group for %s free coins! Claim it at the reward board.",
				FreeRewardConfig.groupNameFor(Players.LocalPlayer),
				comma(FreeRewardConfig.Coins))
		end,
		--[[
			AND IT STOPS BEING OFFERED THE MOMENT IT IS PAID. The reward is once
			per account (FreeRewardConfig.ClaimedAttribute, saved), so going on
			to pitch it at somebody who has already taken it is advertising a
			thing they cannot buy -- the single most annoying kind of notice a
			game can put on screen. TipClient drops this entry from the pool
			entirely once the attribute is set, which also hands the remaining
			weight back to the real hints.
		]]
		skipWhen = function(player)
			return player:GetAttribute(FreeRewardConfig.ClaimedAttribute) and true or false
		end,
	},

	-- MenuHud's RAIL note: UPGRADES is deliberately off the rail, and the four
	-- world counters are the only way in. Track names from ProgressionConfig.
	{
		id = "upgrades", alias = "upgrades", kind = "info", weight = 1,
		text = "Upgrades are bought at the counters by the shop, not in the menu: "
			.. "Sifter Width, Water Pressure, Bucket Size and Beach Legs.",
	},

	-- WeightConfig.Messages.Full / BagFull: a full bag refuses the pickup.
	{
		id = "bucket", alias = "bag", kind = "warn", weight = 1,
		text = "Bag full? Nothing else goes in until you walk it to a sell pad.",
	},

	-- ProgressionConfig: the coin ladder is wiped by a rebirth; SellServer.sellAll
	-- applies the rebirth multiplier to every sale afterwards.
	{
		id = "rebirth", alias = "rebirth", kind = "tide", weight = 1,
		text = "A rebirth clears your upgrades, and pays it back on every sale you "
			.. "ever make after it.",
	},

	-- ProgressionConfig's header: "LuckService.luckOf has pets as its only luck source."
	{
		id = "pets", alias = "pets", kind = "level", weight = 1,
		text = "Pets are the only luck in the game. Hatch eggs to turn up rarer finds.",
	},

	-- MenuHud's RAIL note: the Index key came off the rail; Beach.IndexTerminal's
	-- prompt is the only thing that opens it now.
	{
		id = "index", alias = "index", kind = "info", weight = 1,
		text = "Every find you make is logged on the beach computer. Go and fill the Index.",
	},

	-- DuelClient: click a player to raise the challenge card. DuelConfig: first
	-- pitch cleared wins.
	{
		id = "duel", alias = "duel", kind = "pickup", weight = 1,
		text = "Click another beachgoer to challenge them to a clean-off. First pitch "
			.. "clear wins.",
	},

	-- AfkService: the beach shelter is the door into the idle shore, and the wage
	-- is on the wall clock rather than on what the puppet rakes.
	{
		id = "afk", alias = "afk", kind = "tide", weight = 1,
		text = "Heading off for a while? The shelter down the shore keeps paying you "
			.. "while you idle.",
	},

	-- WashServer / WasherTool: the bay lends the power washer for the length of a
	-- wash. Deliberately makes no claim about the price -- see the header.
	{
		id = "wash", alias = "wash", kind = "info", weight = 1,
		text = "Something caked in crust? The wash bay lends you a power washer to "
			.. "take it off.",
	},

	-- RewardsConfig.DailyLadder: a monotonic streak ladder on the UTC day, clamped
	-- rather than wrapped at the top.
	{
		id = "daily", alias = "daily", kind = "money", weight = 1,
		text = "The daily reward climbs every day you come back in a row. Don't break "
			.. "the streak.",
	},

	-- RewardsConfig: the daily three are re-offered every day against that day's
	-- baseline.
	{
		id = "quests", alias = "quests", kind = "money", weight = 1,
		text = "Quests sit in the Rewards panel, and the daily ones come back around "
			.. "every day.",
	},

	-- FerryBuilder / DevGrant's note: the ferry reads the tide counter, and the
	-- Dunes are the first shore it opens.
	{
		id = "ferry", alias = "ferry", kind = "tide", weight = 1,
		text = "The ferry opens a new shore as you clear tides. The Dunes are the "
			.. "first one out.",
	},
}

--------------------------------------------------------------------------
-- READING A TIP
--------------------------------------------------------------------------

-- 1000 -> "1,000". Local rather than shared: nothing else in Modules has one to
-- borrow, and this is four lines against a new dependency for every caller.
local function comma(n: number): string
	local s = string.format("%d", math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	-- The gsub above leaves a leading comma on exact multiples of 1000.
	return (out:gsub("^,", ""))
end

TipConfig.comma = comma

-- `text` may be a plain string or a function, so a tip can quote a live number
-- instead of a copy of one. Resolved late -- at the moment it is shown, not at
-- require time -- so a value that changes during the session is still right.
function TipConfig.textOf(tip): string
	if type(tip.text) == "function" then
		local ok, s = pcall(tip.text, comma)
		if ok and type(s) == "string" then
			return s
		end
		warn("[Tips] tip '" .. tostring(tip.id) .. "' would not build its text")
		return ""
	end
	return tip.text
end

-- Index of the tip carrying this id or alias, or nil. Used by the chat commands.
function TipConfig.find(key: string): number?
	key = string.lower(key)
	for i, t in ipairs(TipConfig.Tips) do
		if string.lower(t.id) == key or string.lower(t.alias) == key then
			return i
		end
	end
	return nil
end

return TipConfig
