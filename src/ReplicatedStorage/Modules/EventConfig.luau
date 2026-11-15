--[[
	EventConfig  --  ReplicatedStorage.Modules.EventConfig

	WHAT RUNS, WHEN, AND HOW EVERY MACHINE AGREES ABOUT IT WITHOUT ASKING.

	One server event every ten minutes. This module is the timetable and the
	roster; EventService runs it and EventHud draws it. Pure replicated data plus
	arithmetic -- no services, no remotes, no state -- so the server, the client
	and a command bar can all ask it the same questions and get the same answers.

	THE CLOCK IS THE RETENTION MECHANIC, NOT THE EVENT. A player who can see
	"GOLDEN HOUR in 3:41" has a reason to still be here in three minutes and
	forty-one seconds; a player who gets a nice surprise has had a nice surprise.
	Everything below is arranged so that countdown can be drawn early, exactly,
	and without a round trip.

	ANCHORED TO os.time(), NOT TO SERVER UPTIME. A slot is a wall-clock block of
	CYCLE seconds since the epoch, so every server in the game runs the same
	event in the same minute. That is worth more than it looks: it makes the
	schedule something players can learn and tell each other about, and it means
	a player who hops servers does not reset the clock they were waiting on.

	THE BAG, NOT A DIE. Picking at random lets the same event come up three times
	running, which reads as broken. `eventForSlot` deals from a shuffled bag that
	refills when it empties, so every event runs exactly once per round -- and it
	is DERIVED FROM THE SLOT NUMBER rather than remembered, so a server that has
	been up for four minutes knows the whole past and future of the rotation.

	  Known limit, stated rather than hidden: two rounds are shuffled
	  independently, so the bag can in principle deal the same event either side
	  of a round boundary. `dealFor` swaps the first two entries when that would
	  happen, which fixes it for any roster of three or more. Below three it is
	  arithmetically impossible to avoid and this module does not pretend to.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EventConfig = {}

-- Ten minutes, and the event is a fraction of it. The QUIET IS LOAD-BEARING: a
-- game that is always in an event has no events.
EventConfig.Cycle = 600
-- How long before the doors open the announcement goes up. Long enough to
-- change your plan for, short enough that the pill is not shouting all day.
EventConfig.Lead = 60

-- Written by EventService onto ReplicatedStorage, read by SellServer (which
-- must NOT require the service -- see the note there) and by the HUD.
EventConfig.SellMultAttr = "CTB_EventSellMultiplier"
-- The live event's id, or nil. Anything that wants "is X running" asks here.
EventConfig.LiveAttr = "CTB_EventLive"

--[[
	THE ROSTER.

	`kind` is a ToastKit kind, so an event's colour, badge glyph and notification
	pitch all come from the one table that already decides those for the rest of
	the game rather than from a second palette invented here.

	`duration` is the live window in seconds. Everything else is the event's own
	business and is read by EventService alone.
]]
EventConfig.Events = {
	{
		id = "golden_hour",
		name = "GOLDEN HOUR",
		blurb = "Every sale pays double",
		short = "2x SALES",
		kind = "money",
		duration = 60,
		-- Rides ALONGSIDE the rebirth and pass multipliers, never folded into
		-- either. SellServer's own note says why at length.
		sellMultiplier = 2,
	},
	{
		id = "scrap_rush",
		name = "SCRAP RUSH",
		blurb = "No weight limit -- carry the lot",
		short = "NO LIMIT",
		kind = "level",
		duration = 60,
		-- What the bag is lifted TO. Not infinity: a number keeps the HUD's load
		-- bar meaningful, and 40,000 lbs is more than the whole beach.
		holdCap = 40000,
		-- Shouted at this many seconds left, because the event ends with the
		-- player holding more than they can normally carry and the walk to the
		-- till is the point. Without this it is a trap rather than a rush.
		warnAt = 30,
	},
	{
		id = "golden_cans",
		name = "GOLDEN CANS",
		blurb = "Gold cans hidden across the islands",
		short = "FIRST TOUCH",
		kind = "pickup",
		duration = 60,
		cans = 14,
		--[[
			PRICED BY THE ISLAND IT LANDED ON, NOT BY WHAT IT IS.

			It was a flat 2500 everywhere, and that number was wrong at both ends
			of the game. On the BEACH it paid TEN TIMES the TIDE bonus for a lap of
			the starter map -- the map every player is standing on -- so a minute of
			this event out-earned the loop the game is actually about. On ASHFALL,
			twenty-two rebirths deep, the same can was a fifth of that island's
			clear bonus, so the reward for reaching the last map was that the event
			stopped being worth crossing for.

			STILL FLAT WITHIN AN ISLAND, which is the half of the old note that was
			right: a can is a race, and pricing it off rarity would make the good
			ones worth camping and the rest worth ignoring. What varies is the map,
			and the player chose the map by going there.

			The ladder is each island's own `resetBonus` DOUBLED -- the beach's TIDE
			bonus is 250, which is where 500 comes from -- so the game says how much
			an island is worth in ONE place and this follows it instead of inventing
			a second opinion that drifts. Keyed by Config.ISLANDS index. Only the
			four open-air islands are listed because they are the only ones
			EventService seats cans on (its CAN_ISLANDS); the three chamber islands
			are sealed rooms behind deep gates and never get one.
		]]
		canCoinsByIsland = {
			[1] = 500,     -- Beach         (TIDE         250)
			[2] = 1400,    -- Dunes         (SANDSTORM    700)
			[4] = 7200,    -- Sakura Cove   (HANAMI     3,600)
			[5] = 25600,   -- Ashfall Isle  (ERUPTION  12,800)
			[8] = 40600,   -- Penguin Island (BLIZZARD 20,300)
		},
		-- What an island with no entry above pays, and what a can that has somehow
		-- lost its island stamp is worth. The STARTER rate on purpose: a miss here
		-- should under-pay, never over-pay.
		canCoinsBase = 500,
	},
}

EventConfig.ById = {}
for _, e in ipairs(EventConfig.Events) do
	EventConfig.ById[e.id] = e
end

--[[
	WHAT ONE GOLDEN CAN IS WORTH, ON THE ISLAND IT WAS SEATED ON.

	NIL-TOLERANT ON PURPOSE. EventService stamps the island onto the can when it
	builds it and reads it back when somebody touches it, which are up to sixty
	seconds apart. A can that reaches the second half of that without an island
	-- one already in the world when this shipped, anything that clones a can --
	has to pay SOMETHING rather than put a nil through the `%d` in the notify
	line and take the whole Touched handler down with it.
]]
function EventConfig.canCoinsFor(def, islandId: number?): number
	local byIsland = def and def.canCoinsByIsland
	return (islandId and byIsland and byIsland[islandId])
		or (def and def.canCoinsBase)
		or 0
end

--------------------------------------------------------------------------
-- THE TIMETABLE
--------------------------------------------------------------------------

function EventConfig.slotAt(t: number?): number
	return math.floor((t or os.time()) / EventConfig.Cycle)
end

function EventConfig.slotStart(slot: number): number
	return slot * EventConfig.Cycle
end

-- One deterministic shuffle per round, seeded off the round alone -- so two
-- machines that have never spoken deal the same hand.
local BAG_SEED = 90210

local function rawDeal(round: number): { number }
	local n = #EventConfig.Events
	local order = table.create(n)
	for i = 1, n do
		order[i] = i
	end
	local rng = Random.new(BAG_SEED + round)
	for i = n, 2, -1 do
		local j = rng:NextInteger(1, i)
		order[i], order[j] = order[j], order[i]
	end
	return order
end

-- Non-recursive on purpose: `round` is os.time()/1800-ish, i.e. about a
-- million, so anything that walks back through the rounds is not an option.
-- Swapping the first two entries cannot change the LAST one at three or more,
-- which is what makes reading the previous round's tail safe here.
local function dealFor(round: number): { number }
	local order = rawDeal(round)
	local n = #order
	if round > 0 and n >= 3 then
		local prev = rawDeal(round - 1)
		if order[1] == prev[n] then
			order[1], order[2] = order[2], order[1]
		end
	end
	return order
end

function EventConfig.eventForSlot(slot: number)
	local n = #EventConfig.Events
	if n == 0 then
		return nil
	end
	local round = math.floor(slot / n)
	local pos = slot - round * n          -- slot % n, and correct for negatives
	return EventConfig.Events[dealFor(round)[pos + 1]]
end

--[[
	Everything the HUD needs about right now, in one call, from the clock alone.

	  phase   "live"  an event is running       -> `event`, `endsAt`
	          "soon"  inside the lead-in        -> `next`, `startsAt`
	          "idle"  the quiet                 -> `next`, `startsAt`

	The client calls this every frame off its OWN os.time(), which is why the
	countdown does not stutter when the network does: nothing about the number on
	screen is waiting for a message.
]]
function EventConfig.stateAt(t: number?)
	t = t or os.time()
	local slot = EventConfig.slotAt(t)
	local start = EventConfig.slotStart(slot)
	local current = EventConfig.eventForSlot(slot)

	if current and t < start + current.duration then
		return {
			phase = "live",
			event = current,
			startsAt = start,
			endsAt = start + current.duration,
			left = start + current.duration - t,
		}
	end

	local nextSlot = slot + 1
	local nextStart = EventConfig.slotStart(nextSlot)
	local nextEvent = EventConfig.eventForSlot(nextSlot)
	local until_ = nextStart - t
	return {
		phase = (until_ <= EventConfig.Lead) and "soon" or "idle",
		event = nextEvent,
		startsAt = nextStart,
		endsAt = nextStart + (nextEvent and nextEvent.duration or 0),
		left = until_,
	}
end

--------------------------------------------------------------------------
-- WHAT THE REST OF THE GAME ASKS
--------------------------------------------------------------------------
--[[
	THE SELL MULTIPLIER, THROUGH AN ATTRIBUTE RATHER THAN A REQUIRE.

	SellServer needs to know whether Golden Hour is up. It must not require
	EventService to find out: the service pays coins through SellServer, so the
	two requiring each other is a cycle -- and a config module that both sides
	already hold is the seam that costs nothing.

	Server-written, so a client cannot forge it; client-readable, which the HUD
	wants anyway. Missing or <= 1 is the common case and is the no-event answer.
]]
function EventConfig.liveSellMultiplier(): number
	local v = ReplicatedStorage:GetAttribute(EventConfig.SellMultAttr)
	return (type(v) == "number" and v > 1) and v or 1
end

function EventConfig.liveId(): string?
	local v = ReplicatedStorage:GetAttribute(EventConfig.LiveAttr)
	return (type(v) == "string" and v ~= "") and v or nil
end

--[[
	THE BAG FLOOR THE LIVE EVENT IMPOSES, or nil when nothing is lifting it.

	SAME SEAM, SAME REASON AS liveSellMultiplier ABOVE, and it is here rather
	than in either caller because there are TWO of them and they are in
	different systems. Bag capacity is re-derived from the Bucket Size ladder in
	two places -- ProgressionServer.applyAll, on every purchase, respawn and
	rebirth, and WeightService.applyCapacity, off the Lv_BucketSize attribute
	signal -- and BOTH of them used to overwrite a live Scrap Rush lift.

	THE BUG THAT NAMED THIS FUNCTION. Buying any Bucket Size rung during Scrap
	Rush put the normal weight limit straight back, mid-event, for the rest of
	the event: EventService only restores at `stop`, so nothing ever lifted it
	again. Reported by a player on 2026-09-09 -- "during the no-weight-limit
	event, if you upgrade capacity, the weight limit comes back" -- and it is
	the exact inverse of what EventService's own note promises, which is that a
	level bought mid-event survives.

	A FLOOR, NOT AN ASSIGNMENT. Callers take math.max of the ladder and this, so
	a player whose Bucket Size has genuinely outgrown the event cap keeps their
	own number -- which is the same rule that makes the restore read the ladder
	rather than a remembered figure.

	READS THE ATTRIBUTE, NOT EventService. A config module both sides already
	hold is the seam that costs nothing; requiring the service from
	WeightService would be a new edge into a module that starts near the end of
	ServerMain, and requiring it from ProgressionServer would invert the boot
	order outright.
]]
function EventConfig.liveHoldCap(): number?
	local def = EventConfig.ById[EventConfig.liveId() or ""]
	local cap = def and def.holdCap
	return (type(cap) == "number" and cap > 0) and cap or nil
end

-- m:ss, for a countdown that has to be read at a glance out of the corner of
-- an eye while driving something.
function EventConfig.clock(seconds: number): string
	local s = math.max(0, math.floor(seconds + 0.5))
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

return EventConfig
