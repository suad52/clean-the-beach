--[[
	FunnelConfig  --  ServerScriptService.FunnelConfig

	THE TAXONOMY OF EVERY FUNNEL THIS GAME REPORTS, and nothing else. The half
	that watches players and fires the events is FunnelServer; this is the half
	a designer edits.

	THREE FUNNELS, THREE DIFFERENT QUESTIONS
	----------------------------------------
	ONBOARDING  Six steps, once per account. Roblox's OWN onboarding funnel
	            rather than a custom one, so it lands on the Analytics tab's
	            onboarding chart. Five of the six mirror the cards
	            StarterPlayerScripts.TutorialHud draws; the sixth sits in FRONT
	            of them -- ARRIVED -- and it is the denominator.

	            Without it the funnel opens on "filled a bag", and the biggest
	            drop-off any collection game has -- the player who joined,
	            looked around and left without ever raking -- is invisible,
	            because the people who never started are not in the chart at
	            all. A funnel whose first step is already an achievement always
	            reads as though onboarding is working.

	MAP         Eight rungs, once per account, lifetime. Which shores and rooms
	            this account has ever unlocked. Every rung is a REBIRTH GATE.

	TIDE        Roblox progression events, one Start and one Complete per
	            rebirth, forty levels deep. The map funnel answers "did they
	            ever reach Ashfall"; this answers WHICH TIDE THEY STOPPED ON,
	            which is the number the pacing in ProgressionConfig is tuned
	            against and the only one fine-grained enough to retune it.

	WHAT IS HARD-WRITTEN HERE AND WHAT IS READ LIVE, AND WHY THE SPLIT
	------------------------------------------------------------------
	IT IS THE OPPOSITE WAY ROUND FROM THE REST OF THIS CODEBASE, on purpose.

	Everywhere else here, a name is read off its owner so a rename moves both
	copies together. An analytics dashboard inverts that: the funnel name, the
	step NUMBERS and the progression path are the JOIN KEYS a year of collected
	data is filed under. Derive one of those from a display string and the day
	somebody retitles "Turn of the Tide" the chart forks in two, with half the
	history under a name nothing writes to any more and no error anywhere. So
	every key below is typed out and must never be renamed.

	The NUMBERS those keys are measured against are the opposite case, and they
	are read live: the six rebirth gates are enforced by FerryConfig and by the
	three room builders, they have already been re-paced twice, and a second
	hand-kept copy of them in this file is exactly the drift CTB.Config warns
	about where it mirrors ItemConfig. `gate` below is therefore a WITNESS, not
	the source -- FunnelConfig.audit() reads both and reports any that have
	moved, so drift is a line in the output rather than a silently wrong chart.

	LABELS -- step names, level names -- are neither, and those are free to be
	derived and free to change: Roblox identifies a funnel step by its NUMBER
	and carries the name alongside it for display.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local ProgressionConfig = require(Modules:WaitForChild("ProgressionConfig"))

local FunnelConfig = {}

--------------------------------------------------------------------------
-- NAME HYGIENE
--------------------------------------------------------------------------
--[[
	Roblox publishes no length or charset limit for these strings, which is
	exactly why this exists: an undocumented limit is one that is discovered by
	a whole day of events being dropped rather than by an error. Fifty
	characters and a plain charset is comfortably inside anything an analytics
	backend is likely to accept, and every name in this file is well under it
	-- so this is a guard against a future edit, not a transform that is
	currently changing anything.
]]
local MAX_NAME = 50

function FunnelConfig.clean(s: any): string
	if type(s) ~= "string" then
		s = tostring(s)
	end
	-- Anything outside letters, digits, space and the two safe punctuation
	-- marks becomes a space rather than being deleted, so "Sifter-Width" and
	-- "Sifter Width" cannot collapse onto the same string.
	s = (s:gsub("[^%w%s_%-]", " "):gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1"))
	if #s > MAX_NAME then
		s = s:sub(1, MAX_NAME):gsub("%s+$", "")
	end
	return s
end

--------------------------------------------------------------------------
-- 1. THE ONBOARDING FUNNEL
--------------------------------------------------------------------------
--[[
	STEP NUMBERS ARE THE JOIN KEY AND ARE FROZEN. Inserting a step in the
	middle renumbers every step after it, and the dashboard has no way to know
	that -- last month's "step 4" and this month's are different events stacked
	in one bar. A new step goes on the END, or the funnel is retired and a new
	one started.

	FunnelServer re-derives every step from the server's own attributes rather
	than being told by the client -- see its header for why that is not merely
	the tidier option here.

	THIS DOES NOT MAP ONE-TO-ONE ONTO TutorialHud's CARDS, and the note that used
	to stand here claiming "steps 2-6 are the five cards, in its order" was wrong
	twice over. There were never five cards, there were four; and SOLD_AGAIN has
	no card at all -- it is derived from TotalEarned moving a second time, which
	is why it can be measured for a player the wash step skipped. Counted
	2026-09-22: FILL YOUR BAG, SELL YOUR HAUL, WASH THE LUMPS, BUY <sifter>, and
	now HATCH YOUR FIRST PET sitting fourth, ahead of the shop.
]]
FunnelConfig.Onboarding = {
	ARRIVED = 1,
	FILLED = 2,
	SOLD = 3,
	WASHED = 4,
	SOLD_AGAIN = 5,
	UPGRADED = 6,
	-- Added 2026-09-22, ON THE END, which is the only place a step may be added:
	HATCHED = 7,
}

-- The one row that names a shop track reads the track's own name, because it
-- is a LABEL and TutorialHud prints the same string on the card from the same
-- place. Guarded: a place with that track renamed away still reports a funnel,
-- it just reports it against a generic label.
local sifterTrack = ProgressionConfig.TrackByKey and ProgressionConfig.TrackByKey.RollerWidth
local sifterName = (sifterTrack and type(sifterTrack.name) == "string") and sifterTrack.name or "the first upgrade"

FunnelConfig.OnboardingSteps = {
	{ step = 1, key = "Arrived", name = "Arrived on the beach" },
	{ step = 2, key = "Filled", name = "Filled the bag" },
	{ step = 3, key = "Sold", name = "Sold the haul" },
	{ step = 4, key = "Washed", name = "Washed the lumps" },
	{ step = 5, key = "SoldAgain", name = "Sold again" },
	{ step = 6, key = "Upgraded", name = FunnelConfig.clean("Bought " .. sifterName) },
	--[[
		STEP 7, AND WHAT THE 6 -> 7 GAP IS FOR.

		Measured against 899 live profiles on 2026-09-22: pet owners came back for
		a second day at 23.1% against 4.4% for everybody else, it survives
		controlling for session length, and 79% of players owned no pet. The Basic
		egg costs 500 and the median one-day player logs off with 1,423 unspent, so
		this was never an affordability problem -- nothing told them.

		TutorialHud now asks for a pet on the card BEFORE the shop, so a player who
		followed the card completes this the instant it arms. That is the point:
		what this gap measures is the ones who did NOT -- of everybody who finished
		onboarding, how many came out of it owning a pet.
	]]
	{ step = 7, key = "Hatched", name = "Hatched a pet" },
}

--------------------------------------------------------------------------
-- 2. THE MAP FUNNEL
--------------------------------------------------------------------------
--[[
	A LIFETIME funnel, not a per-session one. Roblox groups a custom funnel's
	steps by `funnelSessionId`, and the docs give both shapes: a GUID for
	something a player does repeatedly in one sitting (a shop visit), or a
	constructed id for something tracked "longer-term". Unlocking Ashfall is as
	long-term as this game gets -- it is thirty-odd tides and several hours --
	so the id is the account, and the funnel measures a career rather than a
	session.

	That is also what makes this funnel correct for players who ALREADY EXIST.
	Roblox ignores a repeated step and auto-completes skipped earlier ones, so
	FunnelServer logging nothing but a returning player's CURRENT rung on join
	fills in every rung below it -- the whole back catalogue arrives without a
	migration, a stored high-water mark, or eight events per login.
]]
FunnelConfig.Map = {
	-- FROZEN. See the header: this is the join key.
	Name = "MapUnlocks",
}

function FunnelConfig.Map.sessionFor(player: Player): string
	return "map-" .. tostring(player.UserId)
end

--------------------------------------------------------------------------
-- 3. THE WASH BAY FUNNEL
--------------------------------------------------------------------------
--[[
	WHAT THIS IS FOR, AND WHY IT IS A FUNNEL OF ITS OWN.

	Onboarding step 4, "Washed the lumps", is the measured drop-off of this game
	and has been for weeks: 10.45% churn on phone and 11.16% on tablet against
	4-6% at every step either side of it. But "did not wash" is FIVE different
	failures wearing one number --

	  never found a wash bay
	  found one and could not work the prompt
	  mounted a lump and could not work the jet
	  started washing and gave up part way
	  stopped playing for reasons that have nothing to do with any of it

	-- and four separate fixes have now shipped against the middle three without
	anybody being able to say which failure they were aimed at. This is the
	instrument that ends the guessing.

	NOT SUB-STEPS INSIDE Onboarding. The header of that table is unambiguous:
	step numbers are the join key and are frozen, and "a new step goes on the END,
	or the funnel is retired and a new one started". Splitting step 4 in place
	would renumber SoldAgain and Upgraded and stack two different events in one
	bar on every dashboard going back. So: a new one started.

	A LIFETIME ID, like Map and for the same reason. The question is "of the
	players who ever reached a bay, how many ever finished a wash", not "what
	happened in this sitting" -- and Roblox auto-completes skipped earlier steps
	within a session id, so a returning player who finishes a wash fills in the
	rungs below it without a migration.

	WHAT EACH GAP WILL TELL YOU, which is the whole point of the shape:

	  absent from step 1   never reached a bay      -> discovery, not the UI
	  1 -> 2               reached, never mounted   -> the prompt
	  2 -> 3               mounted, never scrubbed  -> the jet, or aiming
	  3 -> 4               scrubbed, never finished -> length, or difficulty
]]
FunnelConfig.Wash = {
	-- FROZEN. See the header: this is the join key.
	Name = "WashBay",
}

function FunnelConfig.Wash.sessionFor(player: Player): string
	return "wash-" .. tostring(player.UserId)
end

--[[
	STEP 3 IS THE FIRST CHUNK, NOT THE FIRST TRIGGER PULL.

	A player can hold the jet on empty air for a while, and a funnel that counted
	that as "scrubbed" would report the aiming problem as solved. One chunk gone
	is proof the jet reached the rock, which is exactly the thing the touch camera
	ladder was changed to make possible.
]]
FunnelConfig.WashSteps = {
	{ step = 1, key = "Reached",  name = "Reached a wash bay" },
	{ step = 2, key = "Mounted",  name = "Mounted a lump" },
	{ step = 3, key = "Scrubbed", name = "Broke the first chunk" },
	{ step = 4, key = "Finished", name = "Finished a wash" },
}

FunnelConfig.WashByKey = {}
for _, row in ipairs(FunnelConfig.WashSteps) do
	FunnelConfig.WashByKey[row.key] = row
end

-- Resolve a gate off the module that ENFORCES it, lazily and optionally -- the
-- same contract TutorialServer keeps with SaveService. Lazy because two of the
-- three sources are big builder modules and this file must be requirable at any
-- point in ServerMain's order without dragging them in early; optional because
-- a stripped test place with no Ashfall in it should still report a funnel.
local function ferryGate(key: string)
	return function(): number?
		local moduleScript = ReplicatedStorage:FindFirstChild("FerryConfig")
		if not (moduleScript and moduleScript:IsA("ModuleScript")) then
			return nil
		end
		local ok, Ferry = pcall(require, moduleScript)
		if not (ok and type(Ferry) == "table" and type(Ferry.ByKey) == "table") then
			return nil
		end
		local port = Ferry.ByKey[key]
		return port and tonumber(port.requireLevel) or nil
	end
end

-- All three room builders are pure declaration at require time -- they define
-- functions and constants and build nothing until they are called -- so this is
-- side-effect free, and CTB_Server requiring the same ModuleScript later gets
-- the same cached table.
local function roomGate(moduleName: string)
	return function(): number?
		local moduleScript = ServerScriptService:FindFirstChild(moduleName)
		if not (moduleScript and moduleScript:IsA("ModuleScript")) then
			return nil
		end
		local ok, Room = pcall(require, moduleScript)
		if not (ok and type(Room) == "table") then
			return nil
		end
		return tonumber(Room.REBIRTHS)
	end
end

--[[
	`gate` IS THE WITNESS, `from` IS THE SOURCE. See the header. The value in
	the column is what the ladder read when this file was written; `from` reads
	what it is now. FunnelServer calls audit() once at boot and prints any that
	have parted company, so a re-paced gate shows up as a line in the output
	rather than as a chart that quietly stops meaning what it says.

	The ORDER of these rows is the funnel and is frozen; the gates decide only
	which rung a given rebirth count falls on.
]]
FunnelConfig.MapRungs = {
	{ step = 1, key = "Beach", name = "The Beach", gate = 0, from = ferryGate("Beach") },
	{ step = 2, key = "Dunes", name = "The Dunes", gate = 1, from = ferryGate("Dunes") },
	{ step = 3, key = "Vault", name = "The Vault", gate = 4, from = roomGate("VaultBuilder") },
	{ step = 4, key = "Cove", name = "Sakura Cove", gate = 8, from = ferryGate("Cove") },
	{ step = 5, key = "Shrine", name = "The Inner Shrine", gate = 14, from = roomGate("ShrineBuilder") },
	{ step = 6, key = "Ashfall", name = "Ashfall Isle", gate = 22, from = ferryGate("Ashfall") },
	{ step = 7, key = "Magma", name = "The Magma Chamber", gate = 32, from = roomGate("MagmaBuilder") },
	{ step = 8, key = "Penguin", name = "Penguin Island", gate = 34, from = ferryGate("Penguin") },
	{ step = 9, key = "Wreck", name = "The Frozen Wreck", gate = 40, from = roomGate("FrozenWreckBuilder") },
	-- The end of the AUTHORED ladder rather than a place. Read off LadderTides.
	--
	-- IT IS NO LONGER THE END OF THE GAME: nothing refuses a 41st rebirth since
	-- 2026-09-11, so this rung means "past everything that was paced" rather
	-- than "finished". That is still the rung worth charting -- it is where the
	-- map stops handing out new places and the run becomes pure multiplier --
	-- and the name says what the player did, not that they stopped.
	{
		step = 10,
		key = "Ended",
		name = "Rode every tide",
		gate = 48,
		from = function()
			return tonumber(ProgressionConfig.Rebirth.LadderTides)
		end,
	},
}

-- Resolved once and held. A gate cannot change inside a running server -- every
-- source of one is a constant in a module -- so re-reading it per rebirth would
-- be three pcall'd requires on a hot-ish path for an answer that cannot move.
local gateCache: { [number]: number } = {}

function FunnelConfig.gateOf(rung): number
	local cached = gateCache[rung.step]
	if cached then
		return cached
	end
	local live = nil
	if type(rung.from) == "function" then
		local ok, value = pcall(rung.from)
		if ok then
			live = tonumber(value)
		end
	end
	-- The witness is the fallback, never the answer. A place where the module
	-- that owns a gate is missing reports the funnel against the last known
	-- pacing, which is a great deal better than dropping the rung and
	-- renumbering every rung above it in the middle of a data set.
	local resolved = live or rung.gate
	gateCache[rung.step] = resolved
	return resolved
end

--[[
	THE HIGHEST RUNG THIS MANY REBIRTHS HAS UNLOCKED.

	Scans the whole table rather than stopping at the first gate it clears,
	because the rows are ordered by the FUNNEL and the gates are read live: if
	somebody re-paces the Vault above Sakura Cove, an early-out would report the
	Cove as unreached by a player standing in it. Eight rows is not a loop worth
	optimising.
]]
function FunnelConfig.rungFor(rebirths: number)
	local n = math.max(0, math.floor(tonumber(rebirths) or 0))
	local best = nil
	for _, rung in ipairs(FunnelConfig.MapRungs) do
		if n >= FunnelConfig.gateOf(rung) then
			if not best or rung.step > best.step then
				best = rung
			end
		end
	end
	return best
end

--------------------------------------------------------------------------
-- 3. THE TIDE PROGRESSION PATH
--------------------------------------------------------------------------
--[[
	FROZEN, and NOT read off ProgressionConfig.Rebirth.Name even though that
	string says "Turn of the Tide" today. See the header: a progression path is
	a join key, and deriving it from a display name means a cosmetic retitle
	splits the chart in two with no error anywhere.
]]
FunnelConfig.Tide = {
	Path = "TurnOfTheTide",
}

-- A label, so this one IS derived: a tide that lands on a gate is named after
-- what it opens, which is what makes the progression chart readable next to the
-- map funnel without a lookup table in the reader's head.
function FunnelConfig.Tide.levelName(tide: number): string
	local n = math.max(0, math.floor(tonumber(tide) or 0))
	for _, rung in ipairs(FunnelConfig.MapRungs) do
		if FunnelConfig.gateOf(rung) == n and rung.step > 1 then
			return FunnelConfig.clean(string.format("Tide %d - %s", n, rung.name))
		end
	end
	return FunnelConfig.clean(string.format("Tide %d", n))
end

--------------------------------------------------------------------------
-- DRIFT
--------------------------------------------------------------------------
--[[
	Read every gate live and report the ones that no longer match the witness
	in the table above. Returns a list of {rung, live} so a caller can decide
	how loud to be; FunnelServer prints them at boot.

	A MISMATCH IS NOT AN ERROR AND MUST NOT BEHAVE LIKE ONE. The live value is
	already what the funnel is using -- gateOf prefers it -- so the game is
	reporting correctly either way. This exists so that whoever re-paced the
	ladder finds out that a chart's meaning moved with it, and can update the
	witness column in the same commit.
]]
function FunnelConfig.audit()
	local drift = {}
	for _, rung in ipairs(FunnelConfig.MapRungs) do
		local live = FunnelConfig.gateOf(rung)
		if live ~= rung.gate then
			table.insert(drift, { rung = rung, live = live })
		end
	end
	return drift
end

return FunnelConfig
