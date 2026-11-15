--[[
	FerryConfig  --  ReplicatedStorage.FerryConfig

	THE FERRY. What replaced the travel gates.

	Every island used to carry a pair of stone/torii gateways with a
	ProximityPrompt on a pad: stand on it, press E, and you were somewhere else.
	Two gates per destination, four in the world, each one hard-wired to exactly
	one other place -- so the beach grew a row of arches, adding a fourth island
	would have meant two more, and none of them ever explained what they wanted
	from you until you were standing on the pad being refused.

	It is a BOAT now, at the end of each map, with a ferryman standing in front
	of it. His prompt opens ONE panel: every shore he sails to, each showing
	whether it is open to you or what it still wants. One berth per island
	instead of a gate per route, one list instead of four signs, and a new
	destination is a row in this table rather than two more arches.

	It opened on a four-topic CONVERSATION until 2026-08-19 (where can you take
	me / what is it you do / what's on the other islands / nothing for now), with
	the shores one level down behind the first of those. That is a press and a
	read standing in front of the only thing anybody opens a ferryman for, on a
	crossing players make over and over to go and empty a bag. The panel is the
	destination list now and nothing else.

	WHAT LIVES WHERE
	----------------
	  here            the routes, the requirements, and where every berth
	                  stands. Replicated, because the panel draws its rows
	                  straight off this and none of it is secret -- the SERVER
	                  re-reads the requirement when it is asked to sail, so a
	                  client editing its copy changes only what its screen says.
	  FerryBuilder    the geometry: the pier, the boat and the ferryman. Pure
	                  building, no gameplay.
	  FerryServer     puts the berths in the world, owns the prompts and the
	                  remotes, checks the requirement and runs the crossing.
	  FerryClient     the ferryman's dialogue panel, the idle motion on the
	                  boats and the men, and the fade across the water.

	THE VAULT IS NOT A PORT, deliberately. The treasure chamber is reached
	through the pyramid door and its own cinematic (VaultBuilder), it is sealed
	on all six sides and it is not somewhere a boat could tie up. It stays
	Config.ISLANDS[3] and stays off this table.

	REQUIREMENTS ARE REBIRTH COUNTS NOW, and they are the spine of the game's
	pacing rather than a side effect of the upgrade ceiling. See LevelAttribute
	below for why they moved off Sifter levels.

		The Beach        0   home, always open
		The Dunes        1   the first rebirth is the first new shore
		Sakura Cove      8
		Ashfall Isle    22

	The three interiors are gated on the same counter by their own builders, and
	they INTERLEAVE with the shores -- the ladder goes region by region, so an
	island and its room are both finished before the next island opens:

		 1  The Dunes      shore
		 4  The Vault      the Dunes' room      (VaultBuilder)
		 8  Sakura Cove    shore
		14  Inner Shrine   the Cove's room      (ShrineBuilder)
		22  Ashfall Isle   shore
		32  Magma Chamber  Ashfall's room       (MagmaBuilder)
		34  Penguin Island this file, port 5     (Island5Builder)
		40  Frozen Wreck   Penguin's room       (FrozenWreckBuilder)

	The gaps widen on purpose -- 1, 3, 4, 6, 8, 10 -- and every rung is worth more
	than the one before it: 78, 100, 190, 190, 280, 563 coins a find. That second
	property is not automatic and was not free; ItemConfig.ISLAND_PREMIUM carries
	the rebalance that bought it, and its note names the head-to-head steps.
	Moving any gate here means re-checking that chain.

	Home is deliberately free, and that is a correctness rule rather than a
	kindness: a player who rebirthed, or who swam, must always be able to get
	back to the wash bay with a full bag.
]]

local FerryConfig = {}

----------------------------------------------------------------
-- WIRING
----------------------------------------------------------------
FerryConfig.RemoteFolder = "FerryRemotes"
FerryConfig.Events = { "FerryMenu", "FerrySail", "FerryResult", "FerryTrip" }

--[[
	The progression attribute the crossings are gated on.

	"Rebirths", AND IT USED TO BE "RollerLevel". That was the Sifter Width track
	level, and gating on it had three problems that were only visible once the
	whole ladder was measured end to end:

	1. IT WAS NOT A GATE, IT WAS A SPEED BUMP. A track level is only reachable
	   once ProgressionConfig's ceiling allows it, so each port really cost a
	   couple of ceiling steps -- and inside the tide that granted them, the
	   coins were trivial. Sakura Cove landed about THIRTY SECONDS after the
	   tide that unlocked it began. A destination that opens in half a minute is
	   not a destination.

	2. IT WAS RE-RENTED EVERY TIDE. onRebirth resets every track to 1, so a
	   rebirth stranded you on the home beach until you had re-bought the level.
	   Rebirths only ever increments, so a port opened is now a port kept -- and
	   the "nobody may be stranded" rule below stops being load-bearing.

	3. IT COUPLED TWO UNRELATED DIALS. Retuning CostGrowth or the ceiling step
	   silently moved every island gate, because those decide when a level is
	   reachable. Island pacing is now stated here and nowhere else.

	The attribute is written by ProgressionServer on rebirth and restored by
	SaveService on join, so it is authoritative and saved. RollerLevel is still
	written -- CTB_Server's sifter reads it -- it simply no longer gates a boat.
]]
FerryConfig.LevelAttribute = "Rebirths"

-- How close to a ferryman you have to be for him to take a booking. The panel
-- is opened BY his prompt so this can only fail for someone firing the remote
-- by hand -- which is exactly who it is for. Generous enough that walking a
-- few steps while the panel is open never loses you the ride.
FerryConfig.TalkRange = 30

--[[
	THE CROSSING, in eight beats, and it is a VOYAGE now rather than a dip to
	black. You are put aboard, the boat stands out to sea with you on it, the
	screen goes dark somewhere off the point, and it lifts again on the far boat
	running IN to her own pier. Only the middle of it is a teleport.

	  board  stepping aboard, and the mooring lines coming off the bollards
	  cast   the departure. She pulls away from the pier over sheltered water,
	         still in the lee of the island, and it is smooth.
	  fight  past the point, and the sea gets hold of her. This is the beat the
	         crossing is FOR: she pitches into the swell, loses ground to a wave
	         and drives through the next one, and the rider goes with her.
	  fade   the dip to black, out where there is nothing but water
	  hold   black, while the far island streams in
	  surge  the veil lifts already at sea, running in on a following swell --
	         the roughest water of the crossing, taken stern-to.
	  come   the last of it, into the lee of the far island and calm again.
	  land   moored, and stepping off onto the planks

	TWO MOVING BEATS A SIDE, NOT ONE, and that is the whole shape of it: every
	crossing goes calm -> rough -> rough -> calm, so the sea is something that
	builds and then lets go rather than a constant. `FerryConfig.MID_OUT` is
	where the change happens on both sides -- the point past which she is out
	of shelter.

	SHARED CONSTANTS RATHER THAN A HANDSHAKE, for the reason VaultBuilder's
	transition records: the client runs its veil on its own clock and the server
	runs the boats and the player on its own, so a dropped message can never
	leave somebody sitting in front of a black screen. The client also holds a
	watchdog well past the end of all six.

	WHY THESE NUMBERS. The whole crossing is 9.0 seconds against the old 5.7 and
	the 2.2 before that, and that is a lot to spend on a journey somebody makes
	just to go and empty a bag. It buys the one thing neither shorter version
	could: a sea that does something to you. The two rough beats are the long
	ones on purpose -- a boat that fights the water for half a second has not
	fought it, and `fight` and `surge` are the only beats in here that anybody
	will remember. The calm beats either side are cut to the shortest that still
	reads; `cast` at 1.5 is about as short as a boat can leave a pier without
	looking like it was shoved.
]]
FerryConfig.Trip = {
	board = 0.4,
	cast = 1.5,
	fight = 2.2,
	fade = 0.4,
	hold = 0.5,
	surge = 2.2,
	come = 1.4,
	land = 0.4,
}

-- How far out the boats run along the pier's own axis, measured from the
-- mooring. Far enough that the pier is behind you and the shore has started to
-- go small; near enough that all of it is over open water on every one of the
-- three shorelines (the shallowest shelf, the dunes', is still four studs down
-- at eighty).
FerryConfig.SAIL_OUT = 78

-- Where the shelter ends: the boat is in the island's lee up to here and in the
-- open past it, which is what splits `cast` from `fight` and `surge` from
-- `come`. Measured, not chosen -- 34 studs out is roughly where the pier stops
-- blocking the fetch on the shortest of the three heads, so the sea coming up
-- lines up with the last of the planks going by.
FerryConfig.MID_OUT = 34

----------------------------------------------------------------
-- THE PORTS
----------------------------------------------------------------
--[[
	One row per berth, and a berth is BOTH a place you can sail from and a place
	you can sail to -- there is no such thing as a one-way port here, which is
	most of what made the old gate pairs awkward.

	  island        the Config.ISLANDS id this berth belongs to. Used for
	                nothing mechanical; it is the link back to the field, the
	                litter set and the reset bonus.
	  sign          what the pier's board says, in the game's sign voice.
	  requireLevel  REBIRTHS to LAND here. Never checked on the way out.

	                MEASURED AGAINST ProgressionConfig's RollerWidth TRACK, which
	                now runs to level 60 rather than the 6 it had when these were
	                first written. The old 1 / 3 / 5 / 6 gates were tuned against
	                that six-rung ladder -- against the new one they would have
	                opened the volcano inside the first ten minutes, which is not
	                a rebalance, it is the whole map handed over at once.

	                They are re-pitched against the REBIRTH CEILING rather than
	                against a price, because the ceiling is the only thing a
	                player cannot buy their way past:

	                  ceiling(0) = 8    Dunes at 6 is reachable on the first tide
	                  ceiling(3) = 17   Sakura Cove wants three rebirths
	                  ceiling(10) = 38  Ashfall wants ten

	                THE LAST TWO MOVED OUT when the rebirth curve was re-pitched
	                (ProgressionConfig.Rebirth.requirement). Against tides of
	                eight to ten minutes, six rebirths put the FINAL shore about
	                fifty-five minutes in -- so nine tenths of the game had no new
	                destination left in it. Ten rebirths is a little under two
	                hours, which leaves the back half of the ladder something to
	                be walking toward.

	                So each shore is a genuine milestone again, and the boatmen's
	                refusal lines ("Not with that little rake, friend", "Come back
	                maxed") mean something for more than four purchases.
	  code          the three letters on the panel's tile. Not an emoji: the
	                Roblox font has no fallback for the newer ones and they
	                render as a box (see the note at ToastKit's KINDS table).

	  dock.x        the pier's centre line. All three piers run along Z.
	  dock.landZ    the landward end, on solid ground.
	  dock.seaZ     the pier head, a stud or two into the water.
	  dock.boatZ    where the boat lies, alongside the head.
	  dock.boatX    how far off the centre line she is moored, signed. She lies
	                BOW OUT, parallel to the pier rather than across the end of
	                it, because a boat that leaves has to leave in the direction
	                she is pointing -- see the departure in FerryServer.

	THE SEA IS NOT ALWAYS AT THE LOW END OF Z ANY MORE. It was on all three
	berths when this table was written, and `arrivalZ` was one subtraction and
	one fixed heading because of it. The beach's berth has since moved to the
	FAR shore -- the watchtower end, +Z -- so everything directional now goes
	through `dirOf` below and no caller may assume a sign.

	EVERY ONE OF THESE Z NUMBERS WAS SURVEYED, NOT CHOSEN. The waterline was
	raycast off the terrain each island's builder actually made:

	  beach   on the tower shore, x = -22: sand holds 3.0 out to z = 160 and
	          the waterline is z = 190. The head at 196 stands a stud into the
	          water and the mooring at 204 has three studs under her keel. The
	          centre line is at -22 rather than 0 to clear the lifeguard tower
	          at (10, 152), which is 11 studs wide and would have had an arch
	          post through it.
	  dunes   the plateau steps down at z = -313; the head at -330 stands in the
	          shallow shelf and the mooring at -338 in 4 studs
	  cove    the bay's waterline is z = 1252 on the axis (Island3Builder's own
	          note derives it); the head at 1242 is in the bay and the mooring
	          at 1234 sits over the bay floor at -2
	  ashfall the west island's waterline is z = -450 on its own axis; the head at
	          -462 is twelve studs past it in two studs of water, and the mooring
	          at -480 keeps the whole 32-stud hull over the -2 shelf. See the
	          survey note on that row -- its tideline is only fourteen studs wide,
	          so this is the one berth with no slack in it at all

	Move an island's terrain and these have to be re-surveyed with it. The
	builder raycasts the DECK height rather than trusting a constant, but it
	cannot invent a shoreline that is not there.

	WHAT THE FERRYMAN CAN BE ASKED. `tale` is what a boatman says about THIS
	island when somebody asks him what is out there, and it lives on the port
	rather than on the man because all three of them can be asked about all
	three islands. `ferryman.job` is the one thing only he can answer.
]]
--[[
	INLAND: WHAT IS ON A SHORE THAT THE BOAT DOES NOT GO TO.  2026-09-12

	FOUR OF THE NINE ISLANDS ARE NOT PORTS. The Vault, the Inner Shrine, the
	Magma Chamber and the Frozen Wreck are interiors behind a door on another
	island -- the Vault is inside the Dunes, the Shrine inside the Cove, and so
	on. The ferry panel lists five destinations and, until now, said nothing
	about the other four anywhere. So a player looking at the one travel screen
	in the game concluded they did not exist.

	Reported in as many words: "how can i get to island 3" -- from somebody with
	ELEVEN rebirths against the Vault's gate of four. They were seven tides past
	the door and could not find it. The live funnel agrees: of the players who
	reach the Dunes only 13.6%% ever open that door, and the Shrine and Magma
	Chamber are at 0.45%% and 0.01%%.

	The door itself is not the problem -- it wears a floating "TAP TO OPEN"
	legible from ninety studs. Knowing which shore to look on is.

	THE REBIRTH FIGURE IS A COPY, AND `owner` NAMES THE ORIGINAL. Each door's
	real gate is a constant in its own builder (Vault.REBIRTHS and friends) and
	those live in ServerScriptService, where no client can read them. The number
	here is for the CARD ONLY -- no door is ever opened by it, every one of them
	re-checks its own constant on the server when clicked -- so the worst a stale
	copy can do is print the wrong hint. Change a builder's constant and change
	the row here; `owner` is how you find which.
]]
FerryConfig.Ports = {
	{
		id = 1,
		key = "Beach",
		island = 1,
		name = "The Beach",
		sign = "BEACH FERRY",
		blurb = "Home sand. The shops, the wash bay and the sifting kiosk.",
		-- Zero, and it must stay zero. Home is the one port that can never refuse:
		-- see the "nobody may be stranded" rule in the header.
		requireLevel = 0,
		code = "BCH",
		tint = Color3.fromRGB(94, 226, 196),

		-- seaZ AND boatZ BOTH PUSHED OUT TEN. The mooring itself was always over
		-- water -- the seabed is 3.4 down at the old boatZ -- but a boat is 32
		-- studs long and the measurement that matters is the seabed under her
		-- STERN, not under her middle. At boatZ 204 the after end sat at z = 188,
		-- where the sand is +0.48: above the waterline entirely, so the last few
		-- studs of her were run up the beach. The pier head goes with her so the
		-- two keep the same relationship, and landZ is untouched, so nothing
		-- about where a crossing puts you ashore moves.
		dock = { x = -22, landZ = 158, seaZ = 206, boatZ = 214, boatX = 13 },

		boat = { name = "Bucket & Spade", style = "launch" },

		tale = "Home sand, and the only shore with a wash bay on it. "
			.. "Shops behind you, sifting kiosk up the path, and more litter "
			.. "than four of me could carry. Everybody starts here.",

		ferryman = {
			name = "Sandy Salt",
			title = "Beach Boatman",
			style = "beach",
			greeting = "She's fuelled and the sea's flat as a plate. Where are we off to?",
			job = "Me? I run the boat. Three shores on my rope and I'll take you "
				.. "to any of them, so long as your rake's wide enough for where "
				.. "you're going. No charge -- I like the company.",
			refuse = "Ha! Not with that little rake, friend. Get some width on it first.",
			here = "You're standing on it, mate. Try somewhere with a bit more sand.",
			depart = "Cast off! Mind the spray.",
		},
	},
	{
		id = 2,
		key = "Dunes",
		island = 2,
		name = "The Dunes",
		sign = "DUNE FERRY",
		blurb = "A desert under a pyramid. Buried relics, and a door that wants rebirths.",
		--[[
			ONE REBIRTH, and it is the first thing the rebirth button ever buys.

			The old gate was Sifter Lv.6, reachable inside the very first tide,
			which made the second shore a four-minute errand rather than a reward.
			Putting it on the first rebirth gives tide 0 a shape it did not have --
			it is now the Beach tutorial tide, and turning the tide is what ends it.

			THE OPENING IS DELIBERATELY SLOW NOW (2026-08b). requirement(1) is
			3,250 against a 21,044 tide-0 ladder, pitched at about twenty minutes
			of first-tide play -- the Beach is a real tutorial rather than a
			lobby, and maxing its shop before the first turn is no longer on the
			table. The quick tides are 2 through 4: the Dunes' premium roughly
			triples income, the gate holds nearly still, and the Vault lands
			about twenty minutes after this shore does.
		]]
		requireLevel = 1,
		code = "DUN",
		--[[
			WHAT IS ON THIS SHORE THAT THE BOAT DOES NOT GO TO. See the `inland`
			note in the header above Ports.
		]]
		inland = { name = "The Vault", rebirths = 4, owner = "VaultBuilder" },
		tint = Color3.fromRGB(255, 200, 62),

		dock = { x = 1500, landZ = -282, seaZ = -330, boatZ = -338, boatX = 13 },

		boat = { name = "Barque of the Sun", style = "felucca" },

		tale = "A desert with a pyramid standing in the middle of it. The sand "
			.. "there is older and it keeps better things -- and there is a door "
			.. "in that pyramid that only opens for someone who has begun again.",

		ferryman = {
			name = "Ankhef",
			title = "Keeper of the Crossing",
			style = "dunes",
			greeting = "The river goes where I take it. Name your shore, traveller.",
			job = "I keep the crossing. My father kept it, and his. The water "
				.. "between these shores is mine to carry people over, and I have "
				.. "never once lost one.",
			refuse = "The sand keeps its own doors. Return when your rake has earned one.",
			here = "You stand on my shore already. Choose another.",
			depart = "Push off. The sun goes with us.",
		},
	},
	{
		id = 3,
		key = "Cove",
		island = 4,
		name = "Sakura Cove",
		sign = "COVE FERRY",
		blurb = "Pink sand under falling blossom, and a torii out in the bay.",
		-- Three rebirths (ceiling 17). The first shore that asks you to turn the
		-- tide before you can stand on it -- and it now asks twice more, which at
		-- the retuned tide length is about twenty-five minutes in rather than
		-- seventeen. The gap to Ashfall is what actually grew; this moved one rung
		-- so the cove does not end up crowding the dunes.
		-- 15, NOT 17. See NEVER GATE ON THE EXACT CEILING on the Ashfall row:
		-- ceiling(3) is 17, so 17 demanded a PERFECTLY maxed sifter at exactly
		-- three rebirths and one rung short read as impossible. 15 is the same
		-- three rebirths with two levels of headroom.
		--[[
			12 NOW, WHICH IS TWO REBIRTHS RATHER THAN THREE.

			The rule above is unchanged and this obeys it: ceiling(2) is 14, so 12
			is two rungs of headroom at exactly two rebirths, the same shape as
			every other gate on this board.

			EIGHT REBIRTHS, and the old Sifter Lv.12 is what this replaces. That
			gate resolved to "two ceiling steps", and inside the tide that granted
			them the coins were pocket change -- measured, the cove opened ABOUT
			THIRTY SECONDS into that tide. It read as no gate at all.

			EIGHT RATHER THAN FOUR BECAUSE THE TOMB GOES FIRST. The rule the whole
			ladder now follows is REGION BY REGION: you finish an island and its
			room before the next island opens. The Dunes are the second
			destination, their tomb is the third, and this is the fourth.

				Dunes 1 -> Vault 4 -> COVE 8 -> Shrine 14 -> Ashfall 22 -> Magma 32

			That cost a rebalance rather than just a swap. At its old values the
			tomb beat this island by 2.7x head-to-head, so opening it first would
			have made the cove dead ground -- see ItemConfig.ISLAND_PREMIUM, where
			TOMB came down and COVE went up so that every rung on the ladder is
			worth more than the one before it.
		]]
		requireLevel = 8,
		code = "SKR",
		inland = { name = "The Inner Shrine", rebirths = 14, owner = "ShrineBuilder" },
		tint = Color3.fromRGB(255, 168, 196),

		-- Ten out, exactly as the beach's is and for the same reason: the cove's
		-- shelf comes up to +0.26 at z = 1250, which is where her stern used to
		-- lie. (The dunes' shelf is flat at -2 for the whole length of her and is
		-- deliberately left alone.)
		dock = { x = 0, landZ = 1268, seaZ = 1232, boatZ = 1224, boatX = 13 },

		boat = { name = "Hanami-maru", style = "yakata" },

		tale = "Pink sand, and blossom on the water all year whether anyone "
			.. "rakes it or not. There is a torii standing out in the bay. It is "
			.. "the furthest shore I go to, and the prettiest.",

		ferryman = {
			name = "Kaito",
			title = "Cove Boatman",
			style = "cove",
			greeting = "Blossom falls, the tide turns. I row either way -- which way is yours?",
			job = "I row. That is the whole of it. In the morning I sweep the "
				.. "blossom off the planks, and the rest of the day I take people "
				.. "where they are going.",
			refuse = "Not yet. The current only carries those the sand has taught.",
			here = "This is my shore. Pick a further one.",
			depart = "Sit low. The bay is kind today.",
		},
	},
	{
		id = 4,
		key = "Ashfall",
		island = 5,
		name = "Ashfall Isle",
		sign = "ASHFALL FERRY",
		blurb = "Black sand under a live volcano. The last shore, and the biggest.",

		--[[
			THE LAST AND HARDEST FERRY GATE, which it has always been.

			The long argument that used to sit here is deleted rather than kept,
			because every version of it was reasoning about Sifter LEVELS -- "never
			gate on the exact ceiling", "move in threes and stay two below a
			ceiling", 6 then 24 then 38 then 18. None of that survives the move to
			rebirth gates, and a reader following it would be tuning against a
			system this port no longer touches. The one lesson worth carrying over:
			a gate whose requirement the player cannot see a route to is broken,
			which is why blockedReason now prints how many rebirths are left.

			TWENTY-TWO REBIRTHS (2026-08; it was 19, and before that Sifter
			Lv.18, which resolved to five rebirths -- the richest open field in
			the game arrived about forty minutes in). It moved out with the
			2026-08 curve retune: the level ceiling now climbs all the way to
			rebirth 36 instead of capping at 26, so the whole map ladder
			stretched with it -- Shrine 14, this shore 22, Magma 32.

			At 22 it sits just past half way up a 40-rebirth ladder, which is
			where the last ISLAND should sit when there is still a room behind
			it: the Magma Chamber asks 32. Ashfall is the thing at the end of the
			map, and the chamber is the thing at the end of Ashfall.

			The fields either side of it carry the wait: the Cove opens at 8 and
			its Shrine at 14, so tides 8 through 21 are not spent looking at the
			same sand. (An earlier note here said "the Inner Shrine opens at 8
			and the Vault at 13" -- both wrong; the ladder has always run Vault
			4, Cove 8, Shrine next.)
		]]
		requireLevel = 22,
		code = "ASH",
		inland = { name = "The Magma Chamber", rebirths = 32, owner = "MagmaBuilder" },
		tint = Color3.fromRGB(255, 122, 42),

		--[[
			SURVEYED OFF THE TERRAIN Island4Builder ACTUALLY MAKES, like the other
			three, and this shore is the tightest of the four because its tideline is
			deliberately narrow (see the ring note in that file).

			Raycast down the berth's centre line after a build: dry sand holds 3.4 out
			to z = -404, the waterline is z = -450, the shelf is flat at -2.1 from
			-462 to about -500, and the outer slope drops to -6 past -510.

			So the landward end at -404 is the last stud of ground that reads 3.4 --
			twenty studs further out and deckHeightFor would clamp and warn. The head
			at -462 stands twelve studs past the waterline in two studs of water, and
			the mooring at -480 puts her ENTIRE length over the -2 shelf: measured on
			her own line (x = -2187) her stern at -464 and her bow at -496 both read
			-2.1. That last check is the one that matters -- a boat is 32 studs long
			and the ferry never tests its own depth, so a mooring surveyed at its
			midpoint alone is how a boat ends up beached at one end.
		]]
		-- MOVED 320 STUDS SOUTH WITH THE ISLAND, not re-surveyed by eye. Ashfall's
		-- rakeable square went from 320 studs across to 640 and Island4Builder took
		-- the whole of that growth out of the SOUTH side (see Config.ISLANDS[5].cz
		-- and the GROW note in that file), so the causeway, the camp and the pier
		-- all slid down by 2 * (half - 160) = 320. These three keep exactly the
		-- relationship they were measured with: landZ is DECK_Z0, 16 studs inside
		-- the plateau's edge; seaZ is 28 studs past the waterline; boatZ is 18
		-- further out so a 32-stud hull moors by its stern rather than its middle.
		dock = { x = -2200, landZ = -724, seaZ = -782, boatZ = -800, boatX = 13 },

		boat = { name = "Cinderdrift", style = "outrigger" },

		tale = "West. Further than the other two put together, and the sand there "
			.. "is black as a cold grate. There's a mountain on it that is still "
			.. "awake -- you can see the glow off the top of it from halfway across. "
			.. "Bring nothing you mind losing.",

		ferryman = {
			name = "Koa",
			title = "Ashfall Boatman",
			style = "ashfall",
			greeting = "She's warm out there today. Say the word and I'll put you on that beach.",
			job = "I run the long leg. Nobody else will take it -- the water past the "
				.. "point is bad and the mountain drops grit on my deck the whole way "
				.. "in. Somebody has to, and I like the look of the thing.",
			refuse = "Not on that rake, friend. Ashfall eats beginners. Come back maxed.",
			here = "You're on it. Look up if you don't believe me.",
			depart = "Hold on. It gets rough past the point.",
		},
	},
	{
		id = 5,
		key = "Penguin",
		island = 8,
		name = "Penguin Island",
		sign = "POLAR SLEIGH",
		blurb = "A frozen sea, a lost liner, and more penguins than sand. The biggest shore there is.",

		--[[
			THIRTY-FOUR REBIRTHS (2026-09). Two past the Magma Chamber's 32, so the
			ladder keeps climbing out of Ashfall's room rather than stopping in it,
			and fourteen short of the authored top (LadderTides 48) so there is
			still a room behind this shore: the Frozen Wreck asks 40. Penguin
			Island is the thing at the end of the map now, and the wreck is the
			thing at the end of Penguin Island.
		]]
		requireLevel = 34,
		code = "PGN",
		inland = { name = "The Frozen Wreck", rebirths = 40, owner = "FrozenWreckBuilder" },
		tint = Color3.fromRGB(150, 226, 255),

		--[[
			SURVEYED OFF Island5Builder's LAYOUT, which copies Ashfall's landing
			constants (and so Ashfall's berth relationship) onto a plateau lifted to
			3.0 whose south edge is at z -3444: landZ is DECK_Z0, 16 studs inside
			the plateau's edge; seaZ is 28 past the snow beach's edge at -3458 --
			and out there the sea is ICE. The pack ice is a solid sheet at y 0 out
			to a radius of 1080, so the vessel here is a sleigh, and a sleigh sits
			ON the ice: no lead is cut for it and nothing about the berth asks for
			water. The kit is FerryAssets.FerrySleigh (see boat.kit below).
		]]
		dock = { x = 0, landZ = -3428, seaZ = -3486, boatZ = -3504, boatX = 13 },

		-- kit: the model FerryBuilder clones instead of FerryBoat. Sleigh and
		-- team as one model, so the crossing carries the reindeer with it.
		boat = { name = "Northwind", style = "sleigh", kit = "FerrySleigh" },

		tale = "South. Right off the bottom of the map and out across open water, "
			.. "and then the water stops being water. There's a ship on the far "
			.. "shore that's been there longer than I have, and a town that grew up "
			.. "round it, and birds. Thousands of birds. Dress warm.",

		ferryman = {
			name = "Santa",
			title = "Sleigh Captain",
			style = "santa",
			greeting = "Ho ho! Room on the sleigh for one more. Shall we?",
			job = "I run the polar route. The team knows the way over the ice better "
				.. "than I do, and they don't mind the cold -- I'm the one in the coat. "
				.. "Been at it a long time. You'd be surprised how long.",
			refuse = "Not yet, my friend. The ice wants a proper veteran under it. Come back when you've earned your stripes.",
			here = "You're on it! Mind the penguins -- they'll follow you home if you let them.",
			depart = "Hold on to your hat. The team likes a fast start.",
		},
	},
}

----------------------------------------------------------------
-- WHAT YOU CAN ASK HIM
----------------------------------------------------------------
--[[
	The player's side of the conversation, in one place so all three men are
	asked the same four things in the same words.

	This is here rather than in FerryClient for the reason every other string in
	this table is: the ferryman's voice is content, and content that three
	islands share belongs next to the islands. Nothing mechanical reads it --
	the client matches on the KEY, never on the sentence.
]]
--[[
	ONLY `leave` IS DRAWN NOW. The panel opens straight onto the shores, so
	there is no topic list for `routes` to sit on, nothing behind the list for
	`back` to return to, and `job` / `isles` have no row to be asked from.

	They are kept rather than deleted, along with every port's `tale` and its
	ferryman's `job` line, because they are authored CONTENT and restoring the
	conversation is then a change to FerryClient alone. Nothing reads them today
	-- that is a deliberate parking space, not drift, and this note is what keeps
	it from becoming drift.
]]
FerryConfig.Ask = {
	routes = "Where can you take me?",
	job = "What is it you do out here?",
	isles = "What's on the other islands?",
	leave = "Nothing for now.",
	back = "Something else...",
}

----------------------------------------------------------------
-- LOOKUPS
----------------------------------------------------------------
FerryConfig.ByKey = {}
for _, port in ipairs(FerryConfig.Ports) do
	FerryConfig.ByKey[port.key] = port
end

-- nil rather than an error on an unknown key: this is fed straight from a
-- remote, and a bad key is a message to ignore, not a server-side throw.
function FerryConfig.port(key: any)
	if type(key) ~= "string" then
		return nil
	end
	return FerryConfig.ByKey[key]
end

--[[
	WHICH WAY THE SEA IS, as +1 or -1 along Z. Everything directional in the
	ferry goes through this.

	It used to be a constant -1, because all three berths happened to face that
	way. The beach's has moved to the tower shore and faces +1, and the failure
	that produced was not a wonky pier -- `buildPier` had always worked it out
	for itself -- but an ARRIVAL six studs the wrong side of the landward end,
	which on that shore is inside the lifeguard tower. Derived, never authored:
	a berth cannot get this wrong about itself.
]]
function FerryConfig.dirOf(port): number
	return (port.dock.seaZ < port.dock.landZ) and -1 or 1
end

-- Where a crossing puts you down: six studs onto the deck from the landward
-- end, facing inland.
function FerryConfig.arrivalZ(port): number
	return port.dock.landZ + FerryConfig.dirOf(port) * 6
end

--[[
	THE BOAT'S BERTH, as a position on the waterline and a heading.

	She lies ALONGSIDE the pier head and BOW OUT rather than across the end of
	it, which is the whole reason `boatX` exists. A boat moored broadside can
	only leave sideways, and a boat leaving sideways looks like scenery being
	dragged; bow-out, she just goes.

	The heading is a yaw and nothing else, because the boat template is built
	with its LENGTH along its own X and floats at y = 0.

	HER BOW IS LOCAL -X, WHICH IS THE OTHER END FROM THE ONE THIS FILE USED TO
	SAIL HER ON. She is a double-ender and both ends taper, so the hull alone
	does not say which is which; the steering oar hung off the +X quarter and
	the sail set forward of the mast at x = -2.66 both do. She has therefore
	been crossing stern-first since she replaced the hand-built punt, with the
	passenger stood facing the wake -- which is exactly the "facing the opposite
	way" this pair of functions now fixes. Rotating -X onto world (0, 0, dir) is
	a quarter turn the SAME way round as dir.

	AND SHE TURNS ROUND TO COME BACK IN. `heading` is bow-to-sea, which is the
	pose she waits at her mooring in and the pose she leaves in; `headingIn` is
	the same berth taken the other way about, and it is what an ARRIVING boat
	uses so that she runs at her own pier bow-first. Without the second one the
	half of every crossing that a player actually watches -- the arrival -- is
	sailed backwards.
]]
function FerryConfig.moorPos(port): Vector3
	return Vector3.new(port.dock.x + (port.dock.boatX or 13), 0, port.dock.boatZ)
end

function FerryConfig.heading(port): CFrame
	return CFrame.Angles(0, FerryConfig.dirOf(port) * math.pi * 0.5, 0)
end

function FerryConfig.headingIn(port): CFrame
	return FerryConfig.heading(port) * CFrame.Angles(0, math.pi, 0)
end

-- Where she runs to when she leaves, and where she comes in from when she
-- arrives. The same point either way: an arrival is a departure played
-- backwards, which is why there is one number rather than two.
function FerryConfig.seaPos(port): Vector3
	return FerryConfig.moorPos(port)
		+ Vector3.new(0, 0, FerryConfig.dirOf(port) * FerryConfig.SAIL_OUT)
end

-- The handover between the sheltered beat and the rough one, on the same line
-- out. Inside SAIL_OUT by construction, so nothing here needs its own survey.
function FerryConfig.midPos(port): Vector3
	return FerryConfig.moorPos(port)
		+ Vector3.new(0, 0, FerryConfig.dirOf(port) * FerryConfig.MID_OUT)
end

--[[
	The player's rebirth count, defensively. A handler can run before SaveService
	has restored the attribute, and `nil < 4` is an error rather than a refusal.

	THE FLOOR IS 0, NOT 1, AND THAT IS THE WHOLE GATE. It was `math.max(1, ...)`
	when this read RollerLevel, where 1 is the correct floor because there is no
	level 0. Rebirths is 0-based, and leaving the clamp at 1 would have reported
	every brand-new player as having one rebirth -- handing them The Dunes
	(requireLevel 1) before they had earned a single coin.
]]
function FerryConfig.levelOf(player: Player): number
	local n = player:GetAttribute(FerryConfig.LevelAttribute)
	return (type(n) == "number") and math.max(0, math.floor(n)) or 0
end

--[[
	Everything standing between a player and this crossing, or nil if nothing
	is. Shared by the panel (which greys the row) and the server (which is the
	one that actually decides) so the two can never disagree about what a
	refusal says.

	`fromKey` is where they are standing. Sailing to the port you are already at
	is the one refusal that is not about progression, and it has to be caught
	here rather than silently succeeding -- a crossing that teleports you six
	studs down your own pier looks like a bug.
]]
function FerryConfig.blockedReason(port, level: number, fromKey: string?): string?
	if not port then
		return "No such crossing."
	end
	if fromKey and fromKey == port.key then
		return "You are already here."
	end
	if level < port.requireLevel then
		-- Says where the number comes from AND how far off they are. "Needs 19
		-- rebirths" on its own does not tell a player at 3 whether they are close.
		local short = port.requireLevel - level
		return string.format("Needs %d %s -- %d to go. Turn the tide at the shop.",
			port.requireLevel,
			port.requireLevel == 1 and "rebirth" or "rebirths",
			short)
	end
	return nil
end

return FerryConfig
