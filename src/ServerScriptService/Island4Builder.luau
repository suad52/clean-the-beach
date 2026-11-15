--[[
	Island4Builder  --  ServerScriptService.Island4Builder  (ModuleScript)

	ASHFALL ISLE. The game's fourth rakeable destination and the LAST one: 2200
	studs due west of the beach, a mile of black volcanic sand under a live cone
	that stands two hundred studs over it.

	It is deliberately the biggest thing in this place by a distance. The cove's
	plateau is 296 studs of radius; this one is 480, its sea disc is 790 against
	the cove's 620, and its rakeable field is 80x80 where the beach -- the biggest
	until now -- is 64. Standing on the camp's north gate you can see the far end
	of the strand, the west terrace, the arch on the east shore and the crater,
	and none of them is close.

	WHAT LIVES WHERE, because this area is split across three scripts and the
	split is a hard rule, not a preference:

	  here                terrain -- the sea, the island, the volcano, the crater,
	                      the terrace and the caves -- and every piece of SHARED,
	                      CIVIC geometry: the camp and its market, the sell pad,
	                      the shop counter and its ShopPrompt, the stair up the
	                      cone, the lava streams, the arch, and the SCATTER
	                      PLACEMENT of the dressed props. All server-built, so
	                      everyone sees the same island.
	  Island4Props        the props themselves, as pure builders. Rocks, palms,
	                      spires, torches, braziers, tents, crates, lava pools,
	                      fumaroles, ripples, footprints and the litter set. It
	                      decides nothing about WHERE anything goes.
	  CTB_Server          the rakeable field itself and who has raked what. To
	                      that script this island is just Config.ISLANDS[5].
	  Island4_Client      everything that MOVES or is PRIVATE: the ash fall, the
	                      ember drift, the eruption plume, the heat shimmer over
	                      the crater, the smoke-grade, the water and the ambience.

	ORDER. build() must run BEFORE CTB_Server's baselineField(). The plateau is
	filled solid and the rakeable columns are then carved into the top of it; the
	other way round the plateau simply buries them. CTB_Server calls this at the
	bottom of itself, in that order, and nothing else should call it.

	It returns the island's SellPad so CTB_Server can add it to the list of pads
	that pay out. That is not decoration: without a pad out here a full bag sets
	RollerBlocked and the sifter stops dead, and the only way out of it is a
	2200-stud swim. An island with no pad is an island that bricks itself after
	one bagful.

	HAND-EDITING THIS ISLAND. By default build() destroys Workspace.Island4 and
	makes it again, so anything moved in Studio is gone the moment you press Play.
	Set the boolean attribute "HandBuilt" on the Workspace.Island4 folder and that
	stops -- see ADOPT OR BUILD, just above build(). Nothing in this script
	connects an event, so an adopted island is the saved geometry plus the final
	sweeps and nothing else.

	WHAT THIS SCRIPT MAY NOT DO, each learned the hard way somewhere in this place:

	  * Nothing may stand inside the rakeable square, x [-2360, -2040]
	    z [-160, 160]. The player would be raking sand out from under it.
	    openGround() gates every scattered placement and assertClearOfField()
	    re-checks the whole finished island geometrically at the end, because a
	    prop builder written by another script can always hand back a model bigger
	    than advertised.
	  * No TERRAIN may use Enum.Material.Basalt, Mud or CrackedLava outside this
	    island, and no terrain inside it may use anything else. Those three are
	    tinted globally by CTB_Server.applyLook -- Basalt is the black sand, Mud
	    is its (dormant) raked partner and CrackedLava is the cooling flow on the
	    cone -- exactly as Ground and Asphalt are Sakura Cove's. Sand/Snow/
	    Limestone belong to the beach, Sandstone/Salt/Rock/Slate to the dunes,
	    Cobblestone/Pavement to the vault.
	  * Neon stays at Transparency 0. Above zero it renders near-black under
	    Future lighting, which is the opposite of a glow -- and on an island lit
	    by lava that rule matters more here than anywhere else in the game.
	  * Nothing that glows may carry a PointLight by default. There are close to
	    two hundred glowing parts out here and Future lighting shades every
	    fragment inside every light volume once per light; the Neon carries the
	    LOOK for free and the lights are placed by hand where they have work to do.
]]

local Island4 = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CTB = ReplicatedStorage:WaitForChild("CTB")
local Config = require(CTB:WaitForChild("Config"))
-- The camp's signs go through the same kit as the beachfront's, the dunes' and
-- the cove's. This module REBUILDS its island on every boot and SignDresser's
-- world pass runs on ServerMain's schedule, so a sign left for SignDresser would
-- be dressed and then thrown away. These have to be right when they are made.
local SignKit = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("SignKit"))

local Terrain = workspace.Terrain

----------------------------------------------------------------
-- The props module, held at arm's length
----------------------------------------------------------------
--[[
	Island4Props is written by a different script and every one of its builders is
	a place where this island can fail. CTB_Server already wraps this whole module
	in a pcall so a broken island costs the area rather than the boot -- that
	protection is worth nothing if one bad prop takes the terrain, the sell pad
	and the way home down with it.

	So: the require is guarded, every call goes through prop() below, and a missing
	or throwing builder costs exactly one prop and a counted warning. The island
	still has its land, its camp, its pad and its ferry.
]]
local Props = nil
do
	local ok, mod = pcall(function()
		return require(script.Parent:WaitForChild("Island4Props", 5))
	end)
	if ok and type(mod) == "table" then
		Props = mod
	else
		warn("[Ashfall] Island4Props did not load -- the island will be built bare. " .. tostring(mod))
	end
end

local propFails = 0

-- One call into Island4Props. Returns the Model, or nil, and never throws.
local function prop(fnName: string, ...): Model?
	if not Props then
		propFails += 1
		return nil
	end
	local builder = Props[fnName]
	if type(builder) ~= "function" then
		propFails += 1
		if propFails <= 4 then
			warn(string.format("[Ashfall] Island4Props.%s is missing", fnName))
		end
		return nil
	end
	local ok, m = pcall(builder, ...)
	if not ok then
		propFails += 1
		if propFails <= 4 then
			warn(string.format("[Ashfall] Island4Props.%s threw: %s", fnName, tostring(m)))
		end
		return nil
	end
	if typeof(m) ~= "Instance" then
		-- A builder that forgets to return is a silent hole in the island: the model
		-- is parented and looks fine, and the caller can no longer place, scale or
		-- count it. Treated as a failure so it shows up in the summary.
		propFails += 1
		return nil
	end
	return m
end

----------------------------------------------------------------
-- Where everything is
----------------------------------------------------------------
local ISL = Config.island(5)
local GROUND = ISL.cleanY              -- 3.0, the same voxel band as every field

--[[
	THE FIELD'S CENTRE AND THE ISLAND'S ANCHOR ARE TWO DIFFERENT POINTS, and
	keeping them apart is the single thing that lets this island's square grow.

	Everything below hangs off CZ: the landmass disc, the volcano's axis, the
	terrace, the arch, the camp, the pier. If CZ were simply ISL.cz then moving
	the rakeable square would move THE MOUNTAIN -- and the mountain carries a
	34-tread stair, three lava streams, a caldera and the Magma Chamber's door,
	all placed analytically against its axis by this file and by MagmaBuilder.

	So FCX/FCZ are the SQUARE and CX/CZ are the ISLAND, and CZ is pinned by
	arithmetic rather than by hope:

		the square's north edge = FCZ + FIELD_HALF = (CZ - GROW) + (160 + GROW)
		                        = CZ + 160, for every value of GROW

	That is the line the cone's foot stands twenty studs behind, so the cone
	never has to move. All the growth comes out of the SOUTH side, across the
	open strand between the field and the camp, and the camp goes with it.
]]
local FCX, FCZ = ISL.cx, ISL.cz        -- the RAKEABLE SQUARE's centre: -2200, -160
local FIELD_HALF = ISL.half            -- 320: the square is FCX/FCZ +- this
local GROW = FIELD_HALF - 160          -- how much bigger the square is than this layout was drawn for
local CX, CZ = FCX, FCZ + GROW         -- THE ISLAND ANCHOR: -2200, 0. Frozen by construction.

--[[
	HOW MUCH BIGGER THE FIELD IS THAN THE ISLAND THIS LAYOUT WAS DRAWN FOR.

	Every distance below was originally typed as a literal against a 160-stud
	half-width, and every one of them encodes a CLEARANCE rather than a place:
	twenty studs between the field and the cone's foot, fifty-two between the
	field and the camp's north gate, thirty between the field and the terrace's
	east rim, sixteen between the pier's landward end and the plateau edge.

	So the layout is written as "the shipped number, plus or minus GROW" and the
	island grows or shrinks WITH its field, holding every one of those
	clearances exactly. Raise Config.ISLANDS[5].grid and:

		the cone, its stair, its streams and its caldera move NORTH by GROW
		the camp, the road, the services and the pier move SOUTH by GROW
		the Cinder Terrace moves WEST and the obsidian arch EAST by GROW
		the four shore radii and the sea disc all grow by GROW

	GROW is zero at grid 80, which is the geometry this file shipped with, so
	nothing here changes meaning -- it just stops being a set of magic numbers.

	TWO THINGS DO NOT SCALE, on purpose. The cone's own profile (V_BASE_R,
	V_TOP, V_TOP_R) and the camp's own dimensions (CAMP_HALF, EAST_HALF,
	LANE_HALF) are the SIZES of objects, not distances between them: a bigger
	beach does not want a bigger mountain or a wider market square, it wants the
	same ones further apart.
]]

--[[
	THE ISLAND IS POURED IN TWO GROUNDS, AND WHICH IS WHICH IS MEASURED.

	SAND is ISL.matMessy -- Mud, tinted near-black. Everything flat: the seabed,
	the shelf, the tideline, the plateau, the rakeable field, the relief mounds and
	the channel home. It is chosen because it renders DEAD FLAT (spread 0.00 over
	twenty-five probes) and its grain is a fine damp speckle. Config's row for this
	island carries the full measurement.

	ROCK is Basalt, tinted a paler grey-brown. Everything that is meant to be
	stone: the cone, the summit, the west terrace and the sea stacks. It is chosen
	for the very property that disqualified it from the beach -- it displaces its
	surface by up to 0.69 studs and never twice the same, so a mountain poured in
	it comes out lumpy for free where one poured in Mud would be a smooth grey
	dune.

	The third, CrackedLava, is the top quarter of the cone and the flows down it.

	Getting these the wrong way round is not a subtle mistake. The first cut of
	this island poured EVERYTHING in Basalt and the note it came back with was
	"I see rock everywhere" -- correct, and the sand was the part that was wrong.
]]
local SAND = ISL.matMessy
local ROCK = Enum.Material.Basalt

--[[
	THE LANDMASS IS NOT CENTRED ON THE FIELD, and that is the single decision the
	whole layout turns on.

	Every other island in this game is a disc with its rakeable square in the
	middle. This one cannot be: a volcano big enough to be the point of the island
	needs three hundred studs of radius and it may not touch the square, so if the
	cone were centred on the field the field would be inside it, and if the cone
	sat beside a centred field the island would have to be twice as wide to hold
	both with the shore in the right place.

	So the LAND is a disc centred 60 studs NORTH of the field (ICZ), the FIELD
	sits in its southern half, and the cone stands in its northern half with its
	foot fifteen studs clear of the square. What that buys, in order from the sea:

		z -444   the pier head, out on the shelf
		z -404   the pier's landward end, on dry black sand
		z -368   the camp's south kerb
		z -212   the camp's north gate
		z -160   the rakeable field begins
		z  160   ...and ends
		z  180   the cone's foot
		z  470   the cone's axis; the crater is 200 studs above all of this
		z  760   the cone's north foot, which runs off the plateau into the sea

	and east and west of the field, 300 studs of open black sand either side for
	the terrace and the arch to stand in.
]]
-- The landmass centre. It slides SOUTH with the growth (and the shore radii grow
-- by the same GROW) so that the disc's NORTH edge stays exactly where it was --
-- z = ICZ + PLATEAU_R = 540, with the cone's north foot still running off it into
-- the sea -- while its south edge follows the pier out.
local ICZ = CZ + 60 - GROW             -- the landmass centre, on the field's axis

--[[
	THE SEA, AND WHY THE RADII ARE WHAT THEY ARE.

	SEA_R is used for the airspace wipe, the seabed AND the water, and those three
	MUST stay equal, so that a rebuild on a running server never clears a wider
	circle than it refills. It also has to contain EVERY voxel this file writes --
	including the cone's north foot, which reaches 700 studs from the centre --
	or a rebuild leaves the old island's leftovers standing outside the wipe.

	The seabed is laid at -24..-12 and the sea at -12..SEA_TOP, which reproduces
	the beach's own offshore column exactly: measured, the beach at (-800, 0) is
	solid Sand to a rendered -10 with water over it at -0.50. The wipe starts at
	-24 rather than deeper for the same reason -- everything below -24 out here is
	untouched seabed, and refilling from -24 exactly means there is never an air
	gap sealed under the water.

	IT GOES 250 STUDS UP, WHICH NO OTHER ISLAND'S WIPE HAS TO. The cove's clears
	-24..220 and never sees anything above 40. This one has a crater rim at 200
	and an eruption plume over it, so the wipe has to reach past the summit or the
	second boot leaves the first boot's mountain standing inside the new one.
]]
local SEA_R = 790 + GROW
local SEA_FLOOR = -12                  -- top of the seabed, matching the beach's
local WIPE_TOP = 250

--[[
	THE WATER SURFACE, AND A Fill* TRAP WORTH THE PARAGRAPH -- inherited whole
	from Island3Builder, which measured it in this place:

	  Terrain:FillBlock    water top -0.5 -> surface -0.500   (exact)
	  Terrain:FillCylinder water top -0.5 -> surface  0.000

	FillCylinder rounds a water top UP to the voxel boundary; FillBlock honours
	the fraction. So this island's sea -- poured with FillCylinder -- actually
	sits at 0.00, half a stud above the beach's -0.50. SEA_SURFACE is the number
	that is TRUE, and everything that has to meet the water uses that one.

	The corridor in bridgeToBeach() is FillBlock, so it CAN hit a fraction, and it
	ramps from the beach's -0.50 up to this island's 0.00 in five 0.1-stud steps
	rather than meeting either one on a lip.
]]
local SEA_TOP = -0.5                   -- what the fill is ASKED for
local SEA_SURFACE = 0.0                -- what FillCylinder actually renders

--[[
	THE ISLAND, AS THREE DISCS AND A LIFT. The heights here are NOT the heights
	you get: Fill* rounds to whole voxels and smooth terrain renders its surface
	at the CENTRE of the first non-full voxel, so a disc filled to y = 0 comes out
	rendering at y = 2. The rakeable field renders at exactly 3.0, so filling the
	plateau "to 3" would leave the field sitting in a three-stud pit with a wall
	round it. The land is filled to 0 and lifted to 3.0 by an explicit 0..4 voxel
	layer further down.

	  660  outer slope        renders at -6
	  570  the shallow shelf  renders at -2, so two studs of water over it
	  494  wet sand           renders at  2, a stud under the dry sand
	  480  the island proper  lifted to  3.0, flush with the field

	THE TIDELINE BAND IS FOURTEEN STUDS WIDE AND THAT IS DELIBERATELY NARROW. The
	cove's is 116 and the brief for that island asked for a wide shallow bay; this
	one is a young volcanic island, where the sea meets the land in a hurry. The
	SHALLOWS are still wide -- 76 studs of shelf under two studs of water, which is
	the "shallow ocean water" the brief asks for -- it is only the wet SAND that is
	a strip.

	AND IT IS WHAT SETS THE LENGTH OF THE FERRY PIER, which is the reason to get it
	right rather than to eyeball it. A berth needs its landward end at least a
	dozen studs inside the dry edge and its head at least a dozen studs PAST the
	waterline, so the pier can never be shorter than the tideline band plus both
	margins. At 32 studs of wet sand that came to a 62-stud pier against the
	beach's 48 and the cove's 36 -- and every crossing in the game would have ended
	with a longer walk up a longer jetty. At 14 it is 44, which is in line.

	MOVE THIS AND RE-SURVEY FerryConfig.Ports. The Ashfall row's landZ / seaZ /
	boatZ were measured against these four radii, and the number that fails
	silently is boatZ: the ferry does not check its own depth, so a boat moored
	over wet sand simply sits on the beach looking like a shipwreck.
]]
-- All four grow with the field (see GROW): the tideline band stays fourteen
-- studs, the shelf stays seventy-six, and the pier keeps the length FerryConfig
-- was surveyed against -- the island simply gets wider under all of it.
local SLOPE_R = 660 + GROW
local SHORE_R = 570 + GROW
local WET_R = 494 + GROW
local PLATEAU_R = 480 + GROW

--[[
	THE VOLCANO.

	A truncated cone with a spherical bite out of the top. Its PROFILE is an
	analytic function (coneR below) rather than a stack of hand-typed radii,
	because three other things have to land exactly on that surface -- the stair,
	the lava streams and the crater dressing -- and "raycast it and hope" is how
	a road ends up floating in front of a mountain.

	  V_BASE_R  290   the foot. Fifteen studs clear of the field's north edge,
	                  which is the whole reason VZ is 470 and not 440.
	  V_TOP     182   the height the cone is TRUNCATED at -- the summit plateau
	  V_TOP_R   110   the radius of that plateau
	  exponent 1.15   > 1, so the sides are CONCAVE: a wide flaring skirt and a
	                  steeper upper cone, which is what a stratovolcano is and
	                  what a straight-sided cone conspicuously is not

	THE TRUNCATION IS WIDE ON PURPOSE, AND THE FIRST CUT GOT IT WRONG. It was a
	56-stud apex at h = 215 with a spherical bite out of the top, which is the
	obvious way to make a crater and produces a mountain nobody can stand on: with
	an exponent above 1 the sides go VERTICAL as they approach the apex (dr/dh
	tends to zero), so the "rim" came out as a knife edge on top of a 40-stud
	crag, the stair's last six treads were climbing a cliff, and there was nowhere
	to put a walkway that could see the lava.

	A 110-stud plateau instead gives a 44-stud-wide rim terrace round a 132-stud
	pit -- somewhere to arrive, walk round and look down from -- and the sides only
	stand up in the last dozen studs, which reads as a summit crag rather than as
	a wall.

	The crater is then a straight cylindrical carve rather than a ball. A caldera
	HAS near-vertical walls, the numbers are all readable off one line instead of
	being solved for, and nothing about the rim depends on where a sphere happens
	to cut a curve.
]]
-- VZ moves north with the field. 470 = FIELD_HALF(160) + 20 clear + V_BASE_R(290),
-- which is exactly the sentence the note above tells you not to break, so it is
-- now arithmetic instead of a number to keep in step by hand.
-- Off the ISLAND anchor, not the field's, so the mountain never moves: CZ is
-- pinned such that the square's north edge is always CZ + 160, and 470 - 290 is
-- 180, which is that edge plus the twenty studs this note demands.
local VX, VZ = CX, CZ + 470
local V_BASE_R = 290
local V_TOP = 182
local V_TOP_R = 110
local PIT_R = 66
local PIT_FILL = 162                   -- the crater floor is FILLED to here
--[[
	WHAT THE FLAT TOPS ACTUALLY RENDER AT, and it is FOUR studs rather than the
	two the slopes get.

	The cone is poured in four-stud slabs starting at y = 2, so every slab straddles
	two rows of the voxel grid (which is aligned to multiples of four). On a SLOPE
	that averages out and the surface lands a clean two studs proud -- surveyed at
	nine radii, mean +1.95. On a FLAT top the last slab is the only thing in its
	rows and the rounding goes the other way: measured at eight bearings, the summit
	plateau renders at 186 and the crater floor at 166, both four over their fill.

	It matters because the rim walk, the lookout, the fumaroles and the lake all sit
	on those two surfaces. Built against +2 they were laid a stud and a half INTO
	the rock -- measured, a mean of -2.49 across the fourteen walk slabs.
]]
local FLAT_LIFT = 4
local RIM_Y = V_TOP + FLAT_LIFT             -- 186, what the summit plateau renders at
local CRATER_FLOOR = PIT_FILL + FLAT_LIFT   -- 166, what the crater floor renders at

--[[
	THE TWO-STUD LIFT, AND IT IS MEASURED RATHER THAN GUESSED.

	Smooth terrain renders its surface at the CENTRE of the first non-full voxel,
	not at the top of the last full one -- Config.SURFACE_BASE records the same
	thing for the flat fields. So the cone you can stand on is two studs ABOVE the
	cone that was poured.

	Surveyed on the finished mountain, raycasting five bearings at each of nine
	radii from 280 down to 70: the offset came out +2.0, +2.0, +2.3, +2.3, +2.2,
	+2.3, +1.3, +1.6, +1.6 -- mean +1.95, and flat across the whole slope.

	IT IS NOT COSMETIC. Everything this file puts on the mountain -- 34 stair
	treads, 78 lava plates, three pools -- is placed analytically rather than by
	raycast, so that it lands correctly whether or not terrain collision has
	streamed in yet. Without the lift they are all placed on the POURED cone, and
	the first build measured exactly that: the treads sat a mean 6.1 studs UNDER
	the rock (the two studs, plus a 3.5-stud inward nudge on a 40-degree slope)
	and the stream pools were buried up to 17.
]]
local CONE_LIFT = 2.0

-- The cone's radius at a height above sea level. Outside [0, V_TOP] it answers
-- the nearest end rather than an imaginary number, so a caller stepping past
-- the summit gets the summit instead of a crash.
local function coneR(h: number): number
	if h <= 0 then
		return V_BASE_R
	end
	if h >= V_TOP then
		return V_TOP_R
	end
	return V_TOP_R + (V_BASE_R - V_TOP_R) * ((V_TOP - h) / V_TOP) ^ 1.15
end
Island4.coneR = coneR

--[[
	THE INVERSE, AND IT IS THE ONE EVERYTHING ACTUALLY USES.

	Given a RADIUS, the height of the surface you can walk on there. Parametrising
	by radius rather than by height is what lets one loop cross the flat summit
	plateau and the 40-degree slope below it without a special case: on the
	plateau the answer is simply constant.
]]
local function coneSurfaceH(r: number): number
	if r >= V_BASE_R then
		return GROUND
	end
	if r <= V_TOP_R then
		-- the flat summit, which rounds two studs higher than the slope does
		return RIM_Y
	end
	local t = (r - V_TOP_R) / (V_BASE_R - V_TOP_R)
	return V_TOP * (1 - t ^ (1 / 1.15)) + CONE_LIFT
end
Island4.coneSurfaceH = coneSurfaceH

-- A point ON the walkable cone surface at this radius and bearing.
local function conePointR(r: number, theta: number): Vector3
	return Vector3.new(VX + math.cos(theta) * r, coneSurfaceH(r), VZ + math.sin(theta) * r)
end

--[[
	THE CAMP. Everything here is south of z = -160 by at least sixteen studs --
	see the note on assertClearOfField.

		DECK_Z0..Z1   the causeway off the pier, 36 studs
		CAMP_Z0..Z1   the camp square, 156 deep by 208 across
		LANE_Z1       the Cinder Road, which runs out of the north gate and stops
		              sixteen studs short of the field

	THE ROAD IS A THROUGH-ROUTE AND THE SERVICES ARE ON THE FLANKS, which is the
	lesson Island3Builder's precinct re-plan records in full and this island takes
	for free. The rakeable field is on the FAR SIDE of the camp from the pier, so
	anything standing on the axis stands between the sand and the scales. Nothing
	may be built in x [CX-15, CX+15] over the whole run: it is the walk home, the
	sifter lane and the drive line at once.
]]
-- MINUS TWO GROWS, and the two are different halves of the same growth: one for
-- the square's own extra reach and one for its centre sliding south to keep the
-- cone where it is. CAMP_Z1 - (FCZ - FIELD_HALF) comes out at 52 studs whatever
-- the field size, which is the gap the note above is describing.
local DECK_Z0, DECK_Z1 = CZ - 404 - 2 * GROW, CZ - 368 - 2 * GROW
local CAMP_Z0, CAMP_Z1 = CZ - 368 - 2 * GROW, CZ - 212 - 2 * GROW
--[[
	THE SQUARE IS NOT SYMMETRICAL, and that is the point.

	It was 104 either side of the road, which gave the SERVICE flank ninety studs
	of empty paving behind a frontage line and put the vehicle pad thirty studs
	beyond the kerb -- a walk of a hundred and thirty studs from the road to the
	machines, across ground with nothing on it. The east side is a STREET, and a
	street is as wide as its buildings are deep.

	So the east half is now 76 -- deep enough for the weighhouse (its plinth ends
	at CX+67) and nothing more -- and the west half stays 104, because that flank
	carries the egg row and wants the air. See the frontage note on the services.
]]
local CAMP_HALF = 104        -- the WEST half
local EAST_HALF = 76         -- the service flank, pulled in to its own buildings
local LANE_HALF = 13
local LANE_Z1 = CZ - 176 - 2 * GROW    -- sixteen studs short of the field, whatever its size
local GATE_GAP = 19                    -- the break in the north kerb, either side of CX

-- The four services, sited against each other rather than one at a time --
-- and ALL FOUR ON THE EAST FLANK now. The camp is laid out to the one plan
-- every precinct in the game follows: services together on one side of the
-- walk, the egg row alone on the other (the WEST flank here -- the left hand
-- walking in from the pier; PetStationBuilder puts it inside the square at
-- x CX-28, on its own frontage line -- see the apron this file lays under it),
-- and every frontage facing the road.
--   WASH   east flank, NORTH end -- a crusted find arrives from the field,
--          not from the ferry, so purification takes the corner nearest the
--          sand
--   SHOP   east flank, MIDDLE, six studs off the wash bay's shoulder --
--          "the outfitters next to the wash bay" is the brief, verbatim
--   SELL   east flank, SOUTH end, its hall facing WEST across the road; the
--          road is dead straight, so the pad still reads from the north gate
--   CAR    outside the east kerb entirely, pointing north up ninety studs of
--          open sand. See the note on the drive.
--[[
	ONE FRONTAGE LINE, AT CX+22, and every service on the flank starts on it.

	The road edge is at CX+13. Nine studs of paving in front of a shopfront is a
	pavement; ninety is a car park with a shed at the far end of it, which is what
	the flank was when the buildings sat at CX+46..CX+86 and the pad at CX+134.
	So each of the three is placed by the offset that puts ITS OWN west face on
	CX+22 -- the wash rig is 16 across so its centre is +30, the shop plinth is 28
	so its centre is +36, the weighhouse plinth is 21.2 so its centre is +32.6 --
	and they read as one terrace rather than three objects at three setbacks.

	THE WEIGHHOUSE WAS THE ONE THAT NEVER JOINED THE LINE, and this note claimed
	it had. It said "the sell pad is 13 so its centre is +28", which was true of a
	SELL constant that stopped being the pad's position the day the pad moved up
	onto the hall's deck -- and HALL itself sat at CX+56, putting its plinth face
	on CX+45.4. THIRTY-TWO studs of empty paving in front of the one building on
	this island a player has to walk into, beside two that keep nine. From the
	pier it read as a shed parked at the back of a car park while the wash bay and
	the shop made a street.

	The offset is quoted against the PLINTH (HALL.X +- 10.6), not the deck or the
	pad, because the plinth is the widest course and therefore the thing whose
	edge a player reads as the building's face.

	The dead SELL constant is gone with it. A constant that names the old position
	of something, sitting one line above the real one, is exactly the drift this
	file's own notes keep warning about.
]]
local HALL = Vector3.new(CX + 32.6, GROUND, CZ - 320 - 2 * GROW)
local WASH = Vector3.new(CX + 30, GROUND, CZ - 240 - 2 * GROW)
local SHOP = Vector3.new(CX + 36, GROUND, CZ - 276 - 2 * GROW)
local CARPAD = Vector3.new(CX + 92, GROUND, CZ - 262 - 2 * GROW)

--[[
	THE WEST TERRACE -- "the Cinder Terrace" -- and the caves under it.

	A basalt mesa west of the field: three stacked discs to y = 34, with a ramp up
	its south face and a cave cut into its east one. It is the island's second
	storey and the reason the west half is not just more sand.

	SITED BY TWO EDGES AT ONCE. Its east rim has to clear the rakeable square (30
	studs do it) and its west rim has to stay inside the plateau (it clears by
	nine). Move it either way and one of those two breaks -- and the one that
	breaks silently is the second, because terrain outside the plateau simply
	falls into the sea and looks intentional.
]]
-- Both edges the note above names are clearances, so both follow GROW: the east
-- rim keeps its thirty studs off the square and the west rim its nine inside the
-- plateau, because PLATEAU_R grew by the same amount.
-- Both edges the note above names are clearances, so both follow the island: the
-- east rim keeps its thirty studs off the square (hence -GROW in x) and the west
-- rim its nine inside the plateau (hence ICZ, which is where the plateau is
-- centred, rather than a fixed offset from a centre that moved).
local TERRACE_X, TERRACE_Z = CX - 330 - GROW, ICZ + 30
local TERRACE_R = 140
local TERRACE_TOP = 34

-- THE OBSIDIAN ARCH, on the east shore, standing across the waterline: its
-- inland leg is on dry sand and its seaward leg is in the shallows. That is the
-- whole composition -- an arch entirely on land is a doorway to nothing, and one
-- entirely at sea is a rock nobody can reach.
local ARCH_X, ARCH_Z = CX + 466 + GROW, ICZ - 40

-- TRAVEL IS THE FERRY. FerryConfig carries the route and the requirement,
-- FerryBuilder puts a pier, a moored boat and a boatman at the foot of the
-- causeway, and FerryServer runs the crossing. The one number worth carrying
-- over here: the berth occupies x CX +- 34, z -480 .. -388, which is what the
-- KEEP_OUT box below reserves so nothing is scattered inside the boat.

----------------------------------------------------------------
-- Palette
----------------------------------------------------------------
--[[
	PUBLISHED, NOT PUSHED -- the same contract Island3Builder keeps with its own
	props module. Island4Props exports Props.PALETTE so the two scripts agree on
	one set of tones, and neither of them should have to load first to be correct,
	so this file states a complete palette of its own and then lets the props
	module overwrite any key it defines. If Island4Props is missing entirely the
	camp still comes out the right colour.

	THE RULE THAT MATTERS ON THIS ISLAND IS THE OPPOSITE OF THE COVE'S. Sakura
	Cove's note warns that nothing may go near white, because a pale value with no
	grain left in it reads as a hole in the screen. Here nothing may go near
	BLACK, and for the same reason from the other end: the sand is tinted (56,50,
	52) and a prop painted anywhere near it has no silhouette at all. `basalt` at
	(74,68,76) is the darkest thing allowed to stand on the ground, and every
	rock, kerb and post is that or lighter.

	The exception is `obsidian`, which is nearly black on purpose: it is glass and
	it reads by its highlight rather than by its tone.
]]
local PALETTE = {
	basalt = Color3.fromRGB(74, 68, 76),
	basaltPale = Color3.fromRGB(112, 106, 112),
	obsidian = Color3.fromRGB(28, 26, 34),
	ash = Color3.fromRGB(150, 144, 144),
	ashPale = Color3.fromRGB(196, 190, 186),
	ember = Color3.fromRGB(255, 122, 42),
	emberDeep = Color3.fromRGB(198, 56, 24),
	glow = Color3.fromRGB(255, 198, 108),
	sulphur = Color3.fromRGB(226, 198, 84),
	frond = Color3.fromRGB(56, 112, 76),
	timber = Color3.fromRGB(104, 76, 54),
	canvas = Color3.fromRGB(206, 190, 164),
	rope = Color3.fromRGB(172, 144, 100),
	iron = Color3.fromRGB(104, 104, 112),
}
if Props and type(Props.PALETTE) == "table" then
	-- Name for name: this pair of files was written together, so unlike the cove's
	-- palette adoption there is no alias table to translate. A key the props side
	-- names that this one does not is IGNORED rather than added, so a typo on
	-- either side cannot quietly introduce a fifteenth colour.
	for k, v in pairs(Props.PALETTE) do
		if typeof(v) == "Color3" and PALETTE[k] ~= nil then
			PALETTE[k] = v
		end
	end
end

local function dk(c: Color3, f: number?): Color3
	return c:Lerp(PALETTE.obsidian, f or 0.3)
end
local function lt(c: Color3, f: number?): Color3
	return c:Lerp(PALETTE.ashPale, f or 0.32)
end

----------------------------------------------------------------
-- Small builders
----------------------------------------------------------------
local function P(parent, name, size, cf, colour, material, extra)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = colour or PALETTE.basalt
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if extra then
		for k, v in pairs(extra) do
			p[k] = v
		end
	end
	p.Parent = parent
	return p
end

-- Axis-aligned box from world bounds. The camp, its decking and its kerbs are
-- all laid out against each other's faces, and bounds are far easier to keep
-- flush than centre+size when the thing you are lining up is two hundred studs
-- away. Returns nil on a degenerate extent, so every caller that needs the
-- handle has to check it -- SignKit.dress on a nil board is a crash at boot.
local function box(parent, name, x0, x1, y0, y1, z0, z1, colour, material, extra)
	if x1 - x0 < 0.05 or y1 - y0 < 0.05 or z1 - z0 < 0.05 then
		return nil
	end
	return P(parent, name,
		Vector3.new(x1 - x0, y1 - y0, z1 - z0),
		CFrame.new((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5),
		colour, material, extra)
end

-- Local-space part: build around a CFrame so an arch or a gate can be placed and
-- turned without every number in it being rewritten.
local function lp(parent, name, base, size, offset, colour, material, extra)
	return P(parent, name, size, base * offset, colour, material, extra)
end

-- A straight run between two world points: rails, ropes, spans, lava seams. The
-- part's Z axis is aligned to the line, which is what CFrame.lookAt gives.
local function span(parent, name, a: Vector3, b: Vector3, w: number, h: number,
	colour, material, extra)
	local d = (b - a).Magnitude
	if d < 0.05 then
		return nil
	end
	return P(parent, name, Vector3.new(w, h, d), CFrame.lookAt((a + b) * 0.5, b),
		colour, material, extra)
end

local function light(part: BasePart, colour: Color3, range: number, brightness: number)
	local l = Instance.new("PointLight")
	l.Color = colour
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = part
	return l
end

----------------------------------------------------------------
-- Raycast placement
----------------------------------------------------------------
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { Terrain }
groundParams.IgnoreWater = true

-- The solid floor at (x, z), water ignored. Fired from well above the summit,
-- because on this island "above the ground" can mean 210 studs up.
local function groundY(x: number, z: number, fallback: number): number
	local hit = workspace:Raycast(Vector3.new(x, 300, z), Vector3.new(0, -560, 0), groundParams)
	return hit and hit.Position.Y or fallback
end

--[[
	The same, but it WAITS for that particular column's collision to exist.

	waitForGround() below proves the terrain is raycastable somewhere, and for the
	scatter that is enough -- a rock that misses lands at GROUND, which is where
	it was going anyway. It is NOT enough for anything on the cone. Collision is
	rebuilt per chunk, and the cone is 700 studs from the camp in entirely
	different chunks, so it can miss while the camp is already solid.

	Island3Builder records the failure this prevents and it is worth repeating:
	a miss falls back to a constant, the constant happens to be right, and the day
	somebody changes the geometry the landmark silently detaches from it.
]]
local function groundYWait(x: number, z: number, fallback: number): number
	for _ = 1, 90 do
		local hit = workspace:Raycast(Vector3.new(x, 300, z), Vector3.new(0, -560, 0), groundParams)
		if hit then
			return hit.Position.Y
		end
		task.wait()
	end
	warn(string.format("[Ashfall] no terrain under (%.0f, %.0f) after 90 frames; using the fallback %.1f",
		x, z, fallback))
	return fallback
end

--[[
	Terrain COLLISION is rebuilt a frame or so behind the voxel write, so a
	raycast fired in the same tick as a Fill* misses and reports nothing there.
	Everything scattered below is placed by raycast, so without this every rock,
	palm and log silently lands at its fallback height and floats -- which looks
	like a placement bug rather than the timing one it is, and cost the dunes real
	time to find.

	The probe points have to be somewhere the terrain actually exists AND far
	enough apart to be in different chunks: the camp, which is solid plateau and
	is also the first thing built on, and the crater floor, which is 800 studs
	away and 170 studs up.
]]
local function waitForGround(): boolean
	for _ = 1, 240 do
		if workspace:Raycast(Vector3.new(CX, 300, CAMP_Z0 + 40), Vector3.new(0, -560, 0), groundParams)
			and workspace:Raycast(Vector3.new(VX, 300, VZ), Vector3.new(0, -560, 0), groundParams) then
			return true
		end
		task.wait()
	end
	warn("[Ashfall] terrain never became raycastable; scattered props will sit at ground level")
	return false
end

----------------------------------------------------------------
-- Clearance
----------------------------------------------------------------
-- Would a circle of this radius reach into the rakeable square? Terrain written
-- outside the field's y band survives the field write, so a mound placed over
-- the square would leave sand hanging above the very columns the player is
-- trying to rake.
local function clearOfField(x, z, r)
	local dx = math.max(0, math.abs(x - CX) - FIELD_HALF)
	local dz = math.max(0, math.abs(z - FCZ) - FIELD_HALF)
	return dx * dx + dz * dz > (r + 10) * (r + 10)
end

local function clearOfBox(x, z, r, bx0, bx1, bz0, bz1)
	local dx = math.max(0, math.max(bx0 - x, x - bx1))
	local dz = math.max(0, math.max(bz0 - z, z - bz1))
	return dx * dx + dz * dz > (r + 6) * (r + 6)
end

-- Everything the scattered decor has to stay out of. Written CX-relative on
-- purpose: the dunes' equivalent table is absolute world numbers that happen to
-- be CX-relative, and the first person to move that island would have found out
-- the hard way. { x0, x1, z0, z1 }.
local KEEP_OUT = {
	{ CX - CAMP_HALF - 10, CX + EAST_HALF + 10, CAMP_Z0 - 10, CAMP_Z1 + 10 },  -- the camp
	{ CX - LANE_HALF - 12, CX + LANE_HALF + 12, DECK_Z0 - 8, LANE_Z1 + 6 },    -- causeway and road
	{ CX - 34, CX + 34, CZ - 480 - 2 * GROW, CZ - 388 - 2 * GROW },            -- the ferry berth
	{ CX + 66, CX + 122, CZ - 290 - 2 * GROW, LANE_Z1 + 6 },                   -- car pad and its drive
	-- The stair's trailhead and the apron in front of it. Everything higher up
	-- the cone is kept clear by the cone test in openGround instead. It rides
	-- north with the cone, so it is expressed against VZ rather than as a pair
	-- of world numbers that only happened to be right at one field size.
	{ CX + 96, CX + 176, VZ - 280, VZ - 212 },
	--[[
		THE EGG PLAZA, WHICH THIS FILE DOES NOT BUILD, no longer needs its own
		entry: PetStationBuilder stands the four booths INSIDE the camp square
		now (the west flank of the road, x CX-40 -- see the `row` frame on
		PetConfig.StationOverrides[5]), and the camp box above already keeps the
		scatter out of the whole square.
	]]
}

local function clearOfBuildings(x, z, r)
	for _, b in ipairs(KEEP_OUT) do
		if not clearOfBox(x, z, r, b[1], b[2], b[3], b[4]) then
			return false
		end
	end
	return true
end

-- Inside the volcano's own footprint. Nothing scattered on the flat may stand
-- here: the cone is 34 degrees at its foot and a palm dropped on it comes out of
-- the slope sideways. The cone's own dressing is placed against coneR instead.
local function onCone(x, z, margin)
	local dx, dz = x - VX, z - VZ
	local r = V_BASE_R + (margin or 0)
	return dx * dx + dz * dz <= r * r
end

local function onTerrace(x, z, margin)
	local dx, dz = x - TERRACE_X, z - TERRACE_Z
	local r = TERRACE_R + (margin or 0)
	return dx * dx + dz * dz <= r * r
end

local function openGround(x, z, r)
	return clearOfField(x, z, r) and clearOfBuildings(x, z, r) and not onCone(x, z, r)
end

--[[
	THE LAST WORD ON THE RAKEABLE SQUARE, and it is deliberately not the same test
	as openGround().

	openGround() gates a placement by its intended radius; this measures what
	actually got built. A prop builder in another script can hand back a model
	four times the size it advertises, a scale can be fat-fingered, and a
	hand-built box can be typed with the wrong sign -- none of which openGround()
	can see. So every BasePart under the finished island is checked against the
	square by its real world-axis-aligned extent, including rotation.

	It reports rather than deletes. Something standing in the field is a bug to go
	and fix in the code that put it there; quietly destroying it at boot would
	hide the bug and leave a hole in the island instead.
]]
--[[
	THREE TERMS, and each one is a different way of NOT costing a cell.

	STANDABLE  a part you can jump onto costs nothing: the sweep has no Y term,
	           so raking from on top of a boulder marks the column under it.
	SHADOW     the band reaches 3 studs either side of a point 4.6 ahead of the
	           character, so anything narrower than about six studs can simply
	           be walked around -- a tiki torch is under a stud across.
	GROUNDED   a roof, an awning or an arch is high, wide and harmless: you walk
	           underneath it. Only something whose foot is ON the sand can keep
	           a character away from what is beneath it.

	All three have to hold before this says a word. It remains a HEURISTIC and it
	says so: the authoritative test is whether a character can stand within reach
	of every cell centre, which needs a flood fill over the finished world and is
	not something to run at boot on every server.
]]
local STANDABLE = 8
local SHADOW = 6
local GROUNDED = 4

local function assertClearOfField(root: Instance): number
	local inside, blocking, first = 0, 0, nil
	for _, p in ipairs(root:GetDescendants()) do
		if p:IsA("BasePart") then
			local cf, s = p.CFrame, p.Size
			local rx, ux, lx = cf.RightVector, cf.UpVector, cf.LookVector
			local exx = math.abs(rx.X) * s.X * 0.5 + math.abs(ux.X) * s.Y * 0.5 + math.abs(lx.X) * s.Z * 0.5
			local ezz = math.abs(rx.Z) * s.X * 0.5 + math.abs(ux.Z) * s.Y * 0.5 + math.abs(lx.Z) * s.Z * 0.5
			if math.abs(cf.X - FCX) - exx < FIELD_HALF and math.abs(cf.Z - FCZ) - ezz < FIELD_HALF then
				inside += 1
				local eyy = math.abs(rx.Y) * s.X * 0.5 + math.abs(ux.Y) * s.Y * 0.5 + math.abs(lx.Y) * s.Z * 0.5
				if p.CanCollide and p.Transparency < 1
					and (cf.Y + eyy) > GROUND + STANDABLE
					and math.min(exx, ezz) * 2 > SHADOW
					and (cf.Y - eyy) < GROUND + GROUNDED then
					blocking += 1
					first = first or p:GetFullName()
				end
			end
		end
	end
	if blocking > 0 then
		warn(string.format(
			"[Ashfall] %d solid part(s) too tall to stand on are INSIDE the rakeable square "
			.. "(%d parts of any kind are) -- a cell nobody can reach never lets this field "
			.. "turn over. First: %s", blocking, inside, first))
	end
	return blocking
end

----------------------------------------------------------------
-- The corridor home
----------------------------------------------------------------
--[[
	A SWIMMABLE CHANNEL BETWEEN TWO OCEANS, and it is not decoration.

	The crossing is gated at nineteen rebirths (FerryConfig.Ports -- it read
	"Sifter Lv.6" when this note was written, before the ports moved onto the
	Rebirths counter), and a gate is only ever a suggestion in a game where the
	player can swim -- so somebody WILL strike out west from the beach. Surveyed
	with a raycast grid over the whole negative quadrant:

	  x >= -900        beach ocean, surface -0.50, seabed rendering -10
	  x -900 .. -1412  NOTHING. No water, no seabed, no part, at any depth.
	  x <= -1412       this island's sea begins (on the z = 0 line)

	A swimmer who leaves the beach heading west loses swim state at x = -900 and
	free-falls to FallenPartsDestroyHeight. From water level a 500-stud gap
	between two identical seas is invisible until you are in it. Island3Builder
	found the identical hole to the north and this is the same fix.

	PURELY ADDITIVE. Every voxel it writes is either VOID or already exactly what
	it writes: the seabed course is -24..-12 against the beach's solid-to--10
	column, and the water course meets the beach at its own -0.50 surface. Growing
	SEA_R instead would have had to WIPE before it refilled, and a wipe is what
	does this kind of damage in the first place.

	AND IT IS LAID STRIP BY STRIP, WHICH IS THE WHOLE REASON IT IS A LOOP. A
	rectangle would end on a straight west-facing edge, and past the middle of it
	that edge has VOID on the far side -- so closing the hole on the axis would
	have opened a new one 300 studs off it. Each 40-stud strip instead stops where
	this island's own sea disc takes over at that z, so the channel's far boundary
	IS the disc and no part of it ends in nothing.

	EVERY x BOUNDARY BELOW IS A MULTIPLE OF FOUR, AND THAT IS NOT COSMETIC.
	Terrain voxels are 4 studs and aligned to multiples of 4 in world space. A
	fill whose edge lands mid-voxel writes that voxel at PARTIAL occupancy, and a
	partly filled water voxel renders as a dip -- measured on the cove's first cut
	of its own channel as a one-stud trench across every band edge. The Y values
	stay fractional on purpose: that is the ramp, and FillBlock honours a
	fractional water top exactly.
]]
local CHANNEL_HALF = 360          -- z either side of the axis
local CHANNEL_STEP = 40
local CHANNEL_X0 = -760           -- well inside the beach's own ocean
local CHANNEL_BANDS = {
	{ -760, -792, -0.5 }, { -792, -828, -0.4 }, { -828, -864, -0.3 },
	{ -864, -900, -0.2 }, { -900, -936, -0.1 }, { -936, CX - 40, SEA_SURFACE },
}

local function bridgeToBeach()
	for z0 = ICZ - CHANNEL_HALF, ICZ + CHANNEL_HALF - CHANNEL_STEP, CHANNEL_STEP do
		local z1 = z0 + CHANNEL_STEP
		-- the strip's widest offset from the island's own centre line decides where
		-- the disc takes over, so both of its edges are covered rather than just
		-- its middle
		local zm = math.max(math.abs(z0 - ICZ), math.abs(z1 - ICZ))
		-- Clamped at zero rather than skipped: a strip whose |z| exceeds SEA_R would
		-- otherwise be dropped and leave a 40-stud void stripe down the side of the
		-- finished channel.
		local reach = math.max(SEA_R * SEA_R - zm * zm, 0)
		-- -8 so the join overlaps the disc rather than meeting it on a seam, then
		-- rounded DOWN to the voxel grid (we are travelling in -x) so the join is
		-- not a partial-occupancy dip
		local xEnd = math.floor((CX + math.sqrt(reach) - 8) / 4) * 4
		if xEnd < CHANNEL_X0 - 1 then
			local cz = (z0 + z1) * 0.5
			Terrain:FillBlock(
				CFrame.new((CHANNEL_X0 + xEnd) * 0.5, (-24 + SEA_FLOOR) * 0.5, cz),
				Vector3.new(CHANNEL_X0 - xEnd, SEA_FLOOR - (-24), CHANNEL_STEP),
				ISL.matMessy)
			for _, band in ipairs(CHANNEL_BANDS) do
				local bx0 = band[1]
				local bx1 = math.max(band[2], xEnd)
				if bx0 > bx1 + 0.5 then
					Terrain:FillBlock(
						CFrame.new((bx0 + bx1) * 0.5, (SEA_FLOOR + band[3]) * 0.5, cz),
						Vector3.new(bx0 - bx1, band[3] - SEA_FLOOR, CHANNEL_STEP),
						Enum.Material.Water)
				end
			end
		end
	end
end

----------------------------------------------------------------
-- Terrain
----------------------------------------------------------------
local function buildTerrain(): (number, number)
	local rng = Random.new(Config.SEED + 8412)

	-- Wipe the airspace first, so a rebuild on a running server does not stack a
	-- second volcano inside the first. The radius is the SAME as the sea's below
	-- and must stay that way -- clearing a wider circle than we refill would punch
	-- a hole in the ocean. It stops at -24 rather than at the bottom of the world
	-- because -24 is where the untouched seabed begins.
	Terrain:FillCylinder(CFrame.new(CX, (WIPE_TOP + -24) * 0.5, ICZ),
		WIPE_TOP + 24, SEA_R, Enum.Material.Air)

	-- Seabed, then sea, laid to reproduce the beach's own offshore column exactly
	-- (see the note on SEA_R).
	Terrain:FillCylinder(CFrame.new(CX, (SEA_FLOOR - 24) * 0.5, ICZ),
		SEA_FLOOR + 24, SEA_R, ISL.matMessy)
	Terrain:FillCylinder(CFrame.new(CX, (SEA_TOP + SEA_FLOOR) * 0.5, ICZ),
		SEA_TOP - SEA_FLOOR, SEA_R, Enum.Material.Water)

	-- Join it to the beach's ocean. Runs BEFORE the island so that if the channel
	-- ever grows far enough west to reach land, the land wins.
	bridgeToBeach()

	--[[
		The island, as three discs.

		FILLED FROM -12 AND NOT FROM -24, which is where the other islands start
		theirs. The seabed above is already solid from -24 to -12 across the WHOLE
		disc, in the same material, so everything below -12 here would be a second
		write of voxels that already hold exactly what it would write. On a 480-stud
		plateau that is a quarter of a million voxels of pure duplication, and this
		island pours more terrain at boot than the other three put together.
	]]
	local BOTTOM = SEA_FLOOR
	for _, ring in ipairs({
		{ r = SLOPE_R, top = -8 },        -- outer slope, renders at -6
		{ r = SHORE_R, top = -4 },        -- the shallow shelf, renders at -2
		{ r = WET_R, top = 0 },           -- wet sand at the waterline, renders at 2
	}) do
		Terrain:FillCylinder(CFrame.new(CX, (BOTTOM + ring.top) * 0.5, ICZ),
			ring.top - BOTTOM, ring.r, ISL.matMessy)
	end

	--[[
		Lift the land to exactly the field's surface height, one voxel layer, at the
		same occupancy the field is written at. This is what makes the rakeable
		square flush with the sand around it -- and flush is not a nicety, it is a
		constraint: raked progress is per player and each client redraws its own
		columns, so a messy column and a raked column must be the SAME height or
		other people's avatars float and sink.

		The region's bounds are all multiples of four on purpose. Region3 is expanded
		to the voxel grid anyway, but a bound that needed expanding would leave the
		mats/occs arrays a row short of the region and WriteVoxels would reject the
		whole write.
	]]
	do
		local _, o3 = Config.occupancyFor(GROUND)
		local V = Config.VOXEL
		-- PLATEAU_R + 4, not a literal: the lift layer has to cover every disc the
		-- pour above laid, and PLATEAU_R grows with the field (see GROW). Typed as
		-- 484 this silently stopped lifting the outer ring the moment the island
		-- got bigger, and an unlifted ring renders a stud low with a step round it.
		local LX0, LX1 = CX - (PLATEAU_R + 4), CX + (PLATEAU_R + 4)
		local LZ0, LZ1 = ICZ - (PLATEAU_R + 4), ICZ + (PLATEAU_R + 4)
		local nx = math.floor((LX1 - LX0) / V)
		local nz = math.floor((LZ1 - LZ0) / V)

		local region = Region3.new(
			Vector3.new(LX0, 0, LZ0),
			Vector3.new(LX1, V, LZ1)
		):ExpandToGrid(V)

		local r2 = PLATEAU_R * PLATEAU_R
		local mats, occs = table.create(nx), table.create(nx)
		for xi = 1, nx do
			local mx, ox = { table.create(nz) }, { table.create(nz) }
			mats[xi], occs[xi] = mx, ox
			local wx = LX0 + (xi - 0.5) * V
			local dx = wx - CX
			for zi = 1, nz do
				local wz = LZ0 + (zi - 0.5) * V
				local dz = wz - ICZ
				if dx * dx + dz * dz <= r2 then
					mx[1][zi], ox[1][zi] = ISL.matMessy, o3
				else
					-- Outside the land this band is already empty, so this is a no-op --
					-- but it has to be written as AIR at zero, because WriteVoxels
					-- rejects a real material at occupancy 0.
					mx[1][zi], ox[1][zi] = Enum.Material.Air, 0
				end
			end
		end
		Terrain:WriteVoxels(region, V, mats, occs)
	end

	--[[
		THE VOLCANO, as a stack of four-stud slabs on the analytic profile.

		SLABS, NOT NESTED DISCS. The obvious build is one FillCylinder per height
		from the ground up, each a little narrower -- but every one of those fills
		the whole column beneath it, so the cone would be poured something like
		fifty times over. Thin slabs stacked instead write the cone's actual volume
		once, and the radius only changes by about a voxel per slab, so terrain
		smoothing has nothing to terrace.

		THE FIRST SLAB IS GROUNDED INTO THE SEABED. The cone's north and east feet
		run off the edge of the plateau and out over the shelf, which is where the
		sea cliffs come from -- and a slab starting at y = 0 out there would be a
		disc of rock hanging over open water.

		THE TOP QUARTER IS CrackedLava. The cone is basalt as far as h = 160 and
		freshly resurfaced above it, which is true of a live volcano and is also the
		only place in the game that material is allowed (see the header).
	]]
	Terrain:FillCylinder(CFrame.new(VX, (BOTTOM + 2) * 0.5, VZ), 2 - BOTTOM, coneR(0), ROCK)
	do
		local h = 2
		while h < V_TOP do
			local top = math.min(h + 4, V_TOP)
			local mid = (h + top) * 0.5
			-- ROCK, not SAND, and the boundary at the cone's foot is where the beach
			-- stops and the mountain starts. See the two-grounds note at the top.
			Terrain:FillCylinder(CFrame.new(VX, mid, VZ), top - h, coneR(mid),
				(mid > 132) and Enum.Material.CrackedLava or ROCK)
			h = top
		end
	end

	--[[
		THE CRATER: a straight cylinder taken out of the summit plateau, and a pan of
		CrackedLava poured into the bottom of it.

		Carved from PIT_FILL upward and no lower, which is what leaves the pan
		standing: the floor is the cone's own rock, repainted, rather than something
		dropped in afterwards. The result is a pit 132 studs across and 20 deep, with
		44 studs of rim terrace round it -- a caldera you walk out onto rather than a
		funnel you look into from a knife edge. See the note on V_TOP for the version
		that was not.
	]]
	Terrain:FillCylinder(CFrame.new(VX, (PIT_FILL + 250) * 0.5, VZ), 250 - PIT_FILL, PIT_R,
		Enum.Material.Air)
	Terrain:FillCylinder(CFrame.new(VX, (PIT_FILL - 18 + PIT_FILL) * 0.5, VZ), 18, PIT_R - 4,
		Enum.Material.CrackedLava)

	--[[
		THE CINDER TERRACE, west of the field: three stacked discs, so the climb out
		of the sand is two steps rather than one thirty-stud wall. Their tops render
		two studs above what is asked for, so this comes out at 14 / 26 / 36.
	]]
	-- ROCK. A mesa standing thirty-five studs out of a black beach is the second
	-- biggest piece of stone on the island and it should read as stone.
	for _, ring in ipairs({
		{ r = TERRACE_R, top = 12 },
		{ r = TERRACE_R - 20, top = 24 },
		{ r = TERRACE_R - 38, top = TERRACE_TOP },
	}) do
		Terrain:FillCylinder(CFrame.new(TERRACE_X, ring.top * 0.5, TERRACE_Z),
			ring.top, ring.r, ROCK)
	end

	--[[
		THE EMBER CAVE, cut into the terrace's south face and running seventy studs
		in to a chamber with a light shaft over it.

		Carved with a chain of balls rather than one long block because a tunnel with
		flat walls and square corners reads as a corridor somebody built. The balls
		overlap by half their radius so the bore never pinches between them.

		THE SHAFT IS THE POINT OF THE ROOM. A sealed chamber lit only by its own lava
		is a dark box the player cannot photograph; a hole in the roof puts a column
		of daylight down the middle of it and gives the lava something to be darker
		than.
	]]
	do
		local mouthZ = TERRACE_Z - TERRACE_R + 6
		for i = 0, 6 do
			Terrain:FillBall(Vector3.new(TERRACE_X, 13, mouthZ + i * 11), 10.5, Enum.Material.Air)
		end
		Terrain:FillBall(Vector3.new(TERRACE_X, 15, mouthZ + 80), 19, Enum.Material.Air)
		for i = 0, 4 do
			Terrain:FillBall(Vector3.new(TERRACE_X + 3, 22 + i * 7, mouthZ + 80), 7.5, Enum.Material.Air)
		end
	end

	--[[
		THE EAST TIDE POOL, at the foot of the arch. An inlet bitten out of the dry
		edge and refilled with two studs of water, so the arch's seaward leg is
		standing in the sea and its landward one is on sand. Its outer edge reaches
		past the wet ring, so it is joined to the ocean rather than being a puddle.
	]]
	-- Sited off the arch rather than off the island centre, so the two cannot
	-- drift apart when the island grows: the pool is 34 studs seaward of the leg.
	Terrain:FillCylinder(CFrame.new(ARCH_X + 34, 12, ARCH_Z), 32, 40, Enum.Material.Air)
	Terrain:FillCylinder(CFrame.new(ARCH_X + 34, (SEA_TOP + -4) * 0.5, ARCH_Z),
		SEA_TOP - (-4), 40, Enum.Material.Water)

	--[[
		Relief on the flat. Low mounds, not dunes: a ball sunk to (1 - lift) of its
		radius shows lift * r above the sand, and at 0.24-0.38 with radii in the
		teens and twenties these top out around ten studs. The dunes run 0.55-0.72
		because that island needs a WALL to close its horizon; this one has a two
		hundred stud volcano to close it, and anything taller here would only get in
		the way of looking at it.
	]]
	local mounds = 0
	for _ = 1, 900 do
		if mounds >= 60 then
			break
		end
		local ang = rng:NextNumber(0, math.pi * 2)
		-- The band rides out with the island: its inner edge has to clear the
		-- rakeable square (openGround would reject the draw anyway, but a band
		-- that is mostly rejected quietly stops producing mounds) and its outer
		-- edge has to stay on the plateau, which grew by the same GROW.
		local dist = rng:NextNumber(190 + GROW, 468 + GROW)
		local r = rng:NextNumber(14, 32)
		local x = CX + math.cos(ang) * dist
		local z = ICZ + math.sin(ang) * dist
		if openGround(x, z, r) and not onTerrace(x, z, r) then
			local lift = 0.24 + (dist - 190 - GROW) / 278 * 0.14
			Terrain:FillBall(Vector3.new(x, GROUND - r * (1 - lift), z), r, ISL.matMessy)
			mounds += 1
		end
	end

	-- ...and a ring of rock stacks standing off the shore, which is what stops a
	-- 480-stud disc reading as a dinner plate from the water. Placed on the shelf
	-- rather than on the sand, so they come out of the sea.
	local stacks = 0
	for _ = 1, 260 do
		if stacks >= 16 then
			break
		end
		local ang = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(WET_R + 18, SHORE_R - 12)
		local x = CX + math.cos(ang) * dist
		local z = ICZ + math.sin(ang) * dist
		-- not through the ferry berth, and not into the tide pool
		if clearOfBuildings(x, z, 22) and not onCone(x, z, 26)
			and (Vector3.new(x, 0, z) - Vector3.new(ARCH_X + 34, 0, ARCH_Z)).Magnitude > 66 then
			local r = rng:NextNumber(9, 17)
			-- ROCK: these are stacks the sea has left standing, not sandbars.
			Terrain:FillBall(Vector3.new(x, rng:NextNumber(-2, 3), z), r, ROCK)
			stacks += 1
		end
	end

	return mounds, stacks
end

----------------------------------------------------------------
-- A BASALT ARCH  --  the shape this island signs itself with
----------------------------------------------------------------
--[[
	Two legs and a span, built from mesh boulders stacked along a parabola.

	IT IS NOT A DOORFRAME. The first cut of this was two columns and a lintel and
	it read as a gate somebody had built; a sea arch is a hole the water left in a
	headland, so the span is a shallow arc, the legs are wider at the bottom than
	the top, and every stone is turned to its own angle. Eleven boulders do it.

	`span` is the clear opening and `rise` is how high the underside of the arc
	gets over the ground at its middle.
]]
local function buildArch(parent, name: string, base: CFrame, spanW: number, rise: number, seed: number)
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	local rng = Random.new(seed)
	local half = spanW * 0.5

	--[[
		THE ARC SPRINGS FROM THE LEG TOPS. IT DID NOT, AND THAT IS WHY STONES HUNG
		IN THE AIR.

		The comment on the old loop said "nine stones on a parabola through the two
		leg tops" and the arithmetic did no such thing. Two separate faults:

		  HEIGHT. The parabola was y = rise - (rise/half^2)x^2, which is ZERO at
		  x = +-half, so its ends sat at rise*0.14 -- six studs off the ground on a
		  46-stud arch. The leg stacks topped out near y 28. The arc therefore
		  passed BELOW the legs at the springing and sailed over the top of them in
		  the middle with nothing under it.

		  PLAN. The legs stood at x = +-(half + 10 - t*3), i.e. four to ten studs
		  OUTSIDE the arc's own ends. Even at the right height they could not have
		  met it.

		So the springing point is now one number, `springY`, used by both halves:
		the legs stack up to it at x = +-half, and the parabola is written to pass
		through (+-half, springY) and reach `rise` at the crown.
	]]
	local springY = rise * 0.42

	-- The legs: four stones each, overlapping, standing directly under the arc's
	-- ends and leaning in as they climb.
	for _, side in ipairs({ -1, 1 }) do
		for i = 0, 3 do
			local t = i / 3
			local h = rise * (0.58 - t * 0.16)
			local at = base * CFrame.new(side * (half + (1 - t) * 6), t * springY,
				rng:NextNumber(-2, 2)) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0)
			prop("rock", m, at, h, "boulder", PALETTE.basalt)
		end
	end

	-- The arc: nine stones on a parabola that really does pass through the leg
	-- tops. u is the position across the span, -1 at one springing and +1 at the
	-- other, so y is springY at both ends and `rise` at the crown by construction.
	for i = 0, 8 do
		local u = -1 + (i / 8) * 2
		local x = u * half
		local y = springY + (rise - springY) * (1 - u * u)
		-- dy/dx of the line above, so each stone lies along the arc rather than
		-- across it.
		local ang = math.atan(-2 * (rise - springY) * u / half)
		local at = base * CFrame.new(x, y, rng:NextNumber(-2, 2)) * CFrame.Angles(0, 0, ang)
		prop("rock", m, at, rise * (0.42 + (i % 2) * 0.08), (i % 3 == 0) and "boulder" or "rock",
			(i % 2 == 0) and PALETTE.basalt or lt(PALETTE.basalt, 0.14))
	end
	return m
end

----------------------------------------------------------------
-- THE ASHEN STAIR  --  the road up the cone
----------------------------------------------------------------
--[[
	A ledge road that climbs the cone in a little over half a turn, from the black
	sand north of the field to the crater rim.

	EVERY SLAB IS PLACED ON THE ANALYTIC SURFACE, not raycast onto it. coneSurfaceH
	is the inverse of the same profile the cone was poured from, plus the measured
	CONE_LIFT, so a slab at a given radius is exactly on the mountain by
	construction -- no waiting for collision, no misses, and it still lands
	correctly if the terrain has not streamed in yet. That is the whole reason the
	profile is a function and not a table of radii.

	IT IS PARAMETRISED BY RADIUS, NOT BY HEIGHT, and that is not a detail. The
	summit is a flat plateau, so the last stretch of the climb gains no height at
	all -- a loop stepping through HEIGHT would either stop at the plateau edge or
	spend every one of its last steps in the same place. Stepping through radius
	crosses the slope and the plateau with one expression and no special case.

	WHY HALF A TURN AND NOT THREE. A spiral road looks wonderful and is a walk
	nobody finishes: the gradient is set by how much horizontal run you spend per
	stud of climb, and a full spiral round a 290-stud cone is over a thousand studs
	of path for 180 of height -- ten degrees, and more than a minute at walking
	speed. 3.6 radians gives about 620 studs at seventeen, which is a climb rather
	than a commute, and it still crosses three faces of the mountain so the view
	changes on the way up.

	IT IS A LEDGE, NOT A BRIDGE. Each tread is centred ON the surface line, so its
	inner half is buried in the slope and its outer half stands proud with a kerb
	along the edge -- about eight studs of clear walking width at every gradient
	the cone has. A road that floats clear of the rock it is climbing is the single
	tell that a mountain path was built rather than cut.

	WHICH SIDE IS OUTWARD IS DERIVED, NOT ASSUMED. A tread's own +X is inward on a
	counter-clockwise climb and outward on a clockwise one, so the kerb, the
	torches and the cairns take their sign from a dot product against the radius
	rather than from a constant. The first cut hard-coded +X and put the kerb, the
	torches and every cairn on the cliff side of the road.
]]
local STAIR_THETA0 = -1.07             -- the trailhead: the cone's south-east foot
local STAIR_SWEEP = 3.6                -- radians, counter-clockwise
local STAIR_R0, STAIR_R1 = 286, 104    -- foot to a little inside the plateau edge
local STAIR_STEPS = 34
local STAIR_W = 13

local function stairPoint(t: number): Vector3
	return conePointR(STAIR_R0 + (STAIR_R1 - STAIR_R0) * t, STAIR_THETA0 + STAIR_SWEEP * t)
end

local function buildStair(parent): (Model, number)
	local m = Instance.new("Model")
	m.Name = "AshenStair"
	m.Parent = parent

	local torches = 0
	local made = 0
	local prev = stairPoint(0)
	for i = 1, STAIR_STEPS do
		local at = stairPoint(i / STAIR_STEPS)
		local mid = (prev + at) * 0.5
		local len = (at - prev).Magnitude
		if len > 0.2 then
			local cf = CFrame.lookAt(mid, at)
			-- +1 if the tread's own +X points away from the axis, -1 if it points at it
			local outward = Vector3.new(mid.X - VX, 0, mid.Z - VZ)
			outward = (outward.Magnitude > 0.01) and outward.Unit or Vector3.new(1, 0, 0)
			local side = (cf.RightVector:Dot(outward) >= 0) and 1 or -1
			local seat = CFrame.new(mid - Vector3.new(0, 0.6, 0)) * cf.Rotation

			--[[
				THE TREAD IS ALSO A CLEANABLE SURFACE, and two attributes are the
				whole of that contract.

				CTB.Stair lays a grid of ash cells over every tread and CTB_Server
				sweeps them with the same band that rakes the sand. It cannot use
				the rakeable grid for this: Config.fieldAt is XZ-only, the stair's
				footprint is nowhere near Ashfall's square, and Config.surfaceY
				hands back one flat height per island while these treads climb from
				y = 7 to y = 185. So it reads the parts.

				StairStep  the order up the mountain. All 34 are named "Tread", and
				           sorting by height would be a guess -- this is the truth.
				StairSpan  the tread's REAL length along the road. Size.Z is that
				           times 1.2, because consecutive treads are stretched into
				           each other so the road has no gaps in it; laying ash over
				           Size.Z would overlap every join and z-fight down the
				           whole flight.
			]]
			local tread = P(m, "Tread", Vector3.new(STAIR_W, 2.2, len * 1.2), seat,
				(i % 2 == 0) and PALETTE.basalt or lt(PALETTE.basalt, 0.1), Enum.Material.Slate)
			if tread then
				made += 1
				tread:SetAttribute("StairStep", i)
				tread:SetAttribute("StairSpan", len)
			end
			-- the outer kerb, which is what makes it read as a cut ledge and also stops
			-- a quad simply driving off the side of the mountain
			P(m, "Kerb", Vector3.new(1.4, 2.6, len * 1.2),
				seat * CFrame.new(side * STAIR_W * 0.5, 1.0, 0),
				dk(PALETTE.basalt, 0.22), Enum.Material.Slate)

			if i % 6 == 3 then
				if prop("tikiTorch", m, seat * CFrame.new(side * (STAIR_W * 0.5 - 1.2), 1.1, 0), 8, true) then
					torches += 1
				end
			elseif i % 6 == 0 then
				prop("cairn", m, seat * CFrame.new(-side * (STAIR_W * 0.5 - 1.6), 1.1, 0), 5.5, i)
			end
		end
		prev = at
	end

	-- The trailhead: an apron of paving out onto the sand, two cairns and a board,
	-- so the way up is announced from the field rather than found by accident.
	local foot = stairPoint(0)
	local outward = (Vector3.new(foot.X, 0, foot.Z) - Vector3.new(VX, 0, VZ))
	outward = (outward.Magnitude > 0.01) and outward.Unit or Vector3.new(0, 0, -1)
	local apronAt = Vector3.new(foot.X, GROUND, foot.Z) + outward * 16
	local apronCF = CFrame.lookAt(apronAt, apronAt + outward)
	P(m, "TrailApron", Vector3.new(30, 1.0, 34), apronCF * CFrame.new(0, -0.38, 0),
		dk(PALETTE.basalt, 0.1), Enum.Material.Slate, { CanCollide = true })
	for _, s in ipairs({ -1, 1 }) do
		prop("cairn", m, apronCF * CFrame.new(s * 12, 0.12, -13), 8, 11 + s)
		if prop("tikiTorch", m, apronCF * CFrame.new(s * 12, 0.12, 13), 10, true) then
			torches += 1
		end
	end
	--[[
		HOW MANY TREADS THERE ARE, ON THE MODEL, and it is a STREAMING fix rather
		than a convenience.

		This place runs with StreamingEnabled. A client standing on the home beach
		has the AshenStair MODEL replicated and none of its parts; a client
		halfway up has some of them. CTB.Stair builds its cell layout by counting
		Tread parts, so without this it would happily cache a nine-tread stair and
		go on returning it after the other twenty-five arrived -- the model
		instance it validates its cache against never changes.

		With this the module can tell "not here yet" from "all here", refuses to
		build a partial layout, and invalidates the moment the count disagrees.
		The SERVER never needs it, because nothing streams there -- which is
		exactly why this would not have shown up in a server-side test.
	]]
	m:SetAttribute("StairTreads", made)

	local board = P(m, "TrailBoard", Vector3.new(15, 4.2, 0.5),
		apronCF * CFrame.new(0, 8.4, 14.4), PALETTE.ash, Enum.Material.Slate)
	SignKit.dress(board, "THE ASHEN STAIR", { Enum.NormalId.Front, Enum.NormalId.Back })
	for _, s in ipairs({ -1, 1 }) do
		P(m, "TrailPost", Vector3.new(0.9, 8.6, 0.9),
			apronCF * CFrame.new(s * 7, 4.3, 14.4), PALETTE.basalt, Enum.Material.Slate)
	end

	return m, torches
end

----------------------------------------------------------------
-- THE LAVA STREAMS
----------------------------------------------------------------
--[[
	Three flows off the crater rim, down the faces the stair does not use.

	EACH IS TWO THINGS AT ONCE and it needs both. The TERRAIN under it is repainted
	CrackedLava in a chain of balls, which is what makes the channel part of the
	mountain rather than a decal on it -- a stripe you can see from the camp eight
	hundred studs away, long after the individual glowing plates have stopped
	resolving. The PLATES are Neon, laid on the analytic surface exactly as the
	stair's treads are, and they are what make it read as molten up close.

	NOT ONE OF THEM CARRIES A LIGHT. There are two hundred-odd discs here and
	Future lighting shades every fragment inside every light volume once per
	light; the glow is the Neon, which costs nothing, and the actual illumination
	comes from the six pools and the lake, which are placed by hand. This is the
	rule the header states and this is the loop it was written for -- and it is
	what lets the disc count go up without the frame cost following it.

	The flow COOLS as it descends -- `hot` runs from 1 at the rim to about 0.15 at
	the foot -- so the stream is bright orange where it leaves the crater and dull
	red by the time it reaches the sand. A stream that is the same colour along its
	whole length reads as a painted line.
]]
--[[
	THE THREE BEARINGS ARE CHOSEN AGAINST THE STAIR, NOT SPREAD EVENLY.

	The stair sweeps theta from -1.07 to 2.53 -- which in [0, 2pi) is 5.21..6.28
	and 0..2.53 -- so the flows take the gap between those, and they take it with
	room to spare: each one wanders up to 0.34 radians either side of its bearing,
	which at the foot of the cone is eighty-five studs of drift.

	The first cut put one at 1.82pi (= 5.72), inside the stair's arc. It was not
	subtle: a flow crossed the road, its levee stood ten studs proud of the treads,
	and the audit came back with a mean tread sitting a stud under the rock and one
	tread buried to its kerb.
]]
local STREAM_ANGLES = { 3.28, 4.04, 4.80 }

--[[
	HOW FAR THE STRIPE'S COOLED CRUST STANDS OVER THE ROCK IT RUNS ON.

	ZERO, and that is the answer rather than a compromise. FillBall ADDS material,
	and terrain then RENDERS a filled voxel about two studs above what was poured
	(the same offset CONE_LIFT is about), so a ball whose top is level with the
	surface still leaves a stripe standing a couple of studs proud -- which is the
	levee a lava channel builds, at exactly the height that reads without becoming
	a wall.

	Sunk any less it is a ridge: at 2.5 the finished stripe stood over four studs
	over its own Neon plates and buried them (measured mean -4.29). Sunk any more
	and the top voxel keeps its Basalt and the stripe stops being visible at all,
	which is the whole reason to paint terrain rather than just lay parts.
]]
local LEVEE = 0

--[[
	TWO PASSES, AND THE ORDER IS THE WHOLE POINT.

	Everything else on this mountain is placed against coneSurfaceH, which is exact
	because the cone is exactly what the profile poured. The streams are the one
	thing that cannot be: they lay their OWN terrain, and how high that stripe ends
	up standing depends on how much its balls overlap each other, which varies down
	the flow as the step length grows and the radius does.

	So the terrain for all three flows goes down first, the build waits for the
	collision to catch up, and only then are the plates and the pools laid on it BY
	RAYCAST. Predicting the height instead is what the two previous cuts did, and
	both were measurably wrong -- mean -11.6 studs and then mean -2.2.

	The raycast still has a fallback (the analytic surface plus the levee), because
	a miss should cost one plate sitting slightly low rather than a plate at y = 0.
]]
local function buildLavaStreams(parent): (Model, number)
	local m = Instance.new("Model")
	m.Name = "LavaStreams"
	m.Parent = parent

	----------------------------------------------------------------
	-- Pass one: the terrain stripes
	----------------------------------------------------------------
	local paths = {}
	for si, theta0 in ipairs(STREAM_ANGLES) do
		local rng = Random.new(Config.SEED + 600 + si)
		local steps = 26
		local wander = 0
		local pts = {}
		-- From the crater's lip, across the rim terrace, and down the outside. Run on
		-- RADIUS for the reason the stair does: the terrace is flat, so a loop
		-- stepping through height would never cross it.
		for i = 0, steps do
			local t = i / steps
			local r = (PIT_R + 3) + (V_BASE_R - 8 - (PIT_R + 3)) * t
			-- a lazy sideways wander, so the flow is not a radius drawn with a ruler
			wander += rng:NextNumber(-0.035, 0.035)
			wander = math.clamp(wander, -0.34, 0.34)
			local at = conePointR(r, theta0 + wander)
			--[[
				HOW DEEP TO SINK THE BALL. FillBall ADDS material -- there is no
				"repaint in place" -- so where its centre goes decides how much rock the
				stripe piles onto the mountain. Its top is put level with the surface
				(LEVEE = 0) and terrain still renders that a couple of studs proud, which
				is the raised channel a cooling flow actually builds. Centred four studs
				down with a fourteen-stud radius, as the first cut had it, it stood NINE
				studs proud -- a levee taller than the flow is wide, which buried the
				plates and swallowed a stair tread whole.
			]]
			local ballR = 9 + t * 5
			Terrain:FillBall(at - Vector3.new(0, ballR - LEVEE, 0), ballR, Enum.Material.CrackedLava)
			table.insert(pts, { at = at, t = t })
		end
		paths[si] = pts
	end

	-- Let the collision for what was just poured exist before anything is laid on
	-- it. waitForGround has already returned by now, so a chunk is at most a frame
	-- or two behind; this is generous.
	for _ = 1, 30 do
		task.wait()
	end

	----------------------------------------------------------------
	-- Pass two: the ribbon, laid on what is actually there
	----------------------------------------------------------------
	--[[
		ONE CONTINUOUS RIBBON PER FLOW, NOT A CHAIN OF SLABS.

		This laid one box per path segment -- twenty-six a flow, each turned by
		CFrame.lookAt(mid, at). Props.lavaSeam's own header now lists what was wrong
		with a box; what was wrong HERE is that the raycast already knew the surface
		normal and threw it away, keeping only the height. So every slab was banked
		by the world's Y on a forty-degree face.

		THE SPACING IS DERIVED FROM THE WIDTH, not fixed. 0.38 of a diameter, so the
		overlap holds as the flow widens from seven studs at the rim to fourteen at
		the foot -- a fixed step would be seamless at one end of the stream and
		scalloped at the other.

		WHAT IT COSTS. About sixty-five discs a flow against the old twenty-six
		segments, so roughly two hundred parts for the three streams rather than
		seventy-eight. Every one is still a bare Neon cylinder with no light, no
		emitter, no shadow, no collision and no query -- which is the rule this
		section's header sets, and the reason the count can go up at all.
	]]
	local function crustAt(at: Vector3): (Vector3, Vector3)
		local hit = workspace:Raycast(at + Vector3.new(0, 50, 0), Vector3.new(0, -110, 0), groundParams)
		if hit then
			return hit.Position, hit.Normal
		end
		return Vector3.new(at.X, at.Y + CONE_LIFT, at.Z), Vector3.new(0, 1, 0)
	end
	local function crustTop(at: Vector3): number
		local pos = crustAt(at)
		return pos.Y
	end

	local plates = 0
	for si, pts in ipairs(paths) do
		local rng = Random.new(Config.SEED + 900 + si)

		-- Walk the polyline at a spacing set by how wide the flow is here, carrying
		-- `t` along with it so the taper and the cooling stay in step with the path.
		local walked = {}
		for i = 1, #pts - 1 do
			local a, b = pts[i], pts[i + 1]
			local seg = b.at - a.at
			local segLen = seg.Magnitude
			if segLen > 1e-3 then
				local step = math.max(2.2, (7 + a.t * 7) * 0.38)
				local n = math.max(1, math.floor(segLen / step))
				for k = 0, n - 1 do
					local f = k / n
					table.insert(walked, {
						at = a.at + seg * f,
						t = a.t + (b.t - a.t) * f,
						dir = seg / segLen,
					})
				end
			end
		end
		if #walked > 0 then
			local last = pts[#pts]
			table.insert(walked, { at = last.at, t = last.t, dir = walked[#walked].dir })
		end

		for i, w in ipairs(walked) do
			local pos, normal = crustAt(w.at)

			-- Forward, flattened INTO the surface. A direction still carrying a
			-- component along the normal would roll the disc off the slope.
			local fwd = w.dir - normal * w.dir:Dot(normal)
			if fwd.Magnitude < 1e-3 then
				fwd = Vector3.new(0, 0, 1)
			else
				fwd = fwd.Unit
			end

			--[[
				TAPERED AT BOTH ENDS. `edge` climbs from 0 at the first and last disc to
				1 across four of them, so the ribbon emerges from the vent and dies away
				into the sand rather than starting and stopping on a flat cut.

				`wobble` is per-disc rather than per-segment: a ribbon whose width is a
				clean function of t is a taper, and a taper reads as a ruler.
			]]
			local edge = math.clamp(math.min(i - 1, #walked - i) / 4, 0, 1)
			local wobble = 0.88 + rng:NextNumber(0, 0.24)
			local width = (7 + w.t * 7) * wobble * (0.25 + 0.75 * edge)

			-- Hot patches drifting down the flow ON TOP of the overall cooling, so the
			-- ribbon is not one flat colour from the rim to the sand.
			local hot = math.clamp(1 - w.t * 0.85, 0.12, 1)
				* (0.82 + 0.18 * math.sin(i * 0.7 + si))

			-- RightVector along the normal: that is the cylinder's own axis, so the
			-- disc face ends up parallel to the ground under it.
			prop("lavaSeam", m, CFrame.fromMatrix(pos + normal * 0.42, normal, fwd),
				width, 0.5, math.clamp(hot, 0.1, 1))
			plates += 1
		end

		--[[
			THE VENT THE FLOW LEAVES FROM, AND IT HAS TO BE ON THE FLAT.

			This sat at V_TOP_R + 16 -- sixteen studs OUTSIDE the terrace, which is to
			say on the forty-degree face. Props.lavaPool builds a horizontal Neon disc
			twenty-six studs across with a ring of rocks round it, and says in its own
			header that `cf` is the lava SURFACE. On a slope that surface is a red
			plate lying across the mountain at an angle nothing else on the island
			shares. Three of them, one per flow, and they were the first thing the eye
			found on the whole cone.

			V_TOP_R - 14 is on the rim terrace, which is dead flat at RIM_Y, so the
			pool is a pool again -- and it sits ON the ribbon's path, so the stream now
			runs out of it and over the lip instead of past a plate left on the hill.

			It still carries the light. See the header on why not one disc in two
			hundred does.
		]]
		local shelf = conePointR(V_TOP_R - 14, STREAM_ANGLES[si] + 0.06)
		prop("lavaPool", m, CFrame.new(shelf.X, crustTop(shelf) + 1.0, shelf.Z), 13, 400 + si)
	end

	return m, plates
end

----------------------------------------------------------------
-- THE CALDERA
----------------------------------------------------------------
--[[
	The lake, the rim walk and the lookout.

	THE LAKE IS ONE SLAB AND FOUR LIGHTS, and both halves of that are deliberate.
	A hundred-stud disc of Neon is a single part and reads as molten rock from the
	camp; what it CANNOT do is light the crater walls, because a Neon part emits
	nothing. Four PointLights spaced round the lake do that, and four is the count
	because one in the middle lights the floor and leaves the walls flat.

	THE RIM WALK is where the stair arrives, and it is laid ON the terrace rather
	than cut into anything: the plateau is dead flat at RIM_Y, so fourteen slabs
	and a rail take the arrival round to the lookout on the south side -- the one
	spot on this island that looks down into the lava AND out over the whole strand
	at the same time.

	THE RAIL IS ON THE CRATER SIDE ONLY. Outside the walk is forty studs of flat
	rock; inside it is a twenty-stud drop into a lava lake. Which side that is gets
	derived from the radius, the same way the stair's kerb does.
]]
local function buildCaldera(parent): Model
	local m = Instance.new("Model")
	m.Name = "Caldera"
	m.Parent = parent

	-- The floor renders two studs above the fill; the lake sits a hair over that
	-- so its edge is not co-planar with the rock it lies on.
	local lakeY = CRATER_FLOOR + 0.7
	local lakeR = PIT_R - 10
	local lake = P(m, "LavaLake", Vector3.new(1.2, lakeR * 2, lakeR * 2),
		CFrame.new(VX, lakeY, VZ) * CFrame.Angles(0, 0, math.pi * 0.5),
		PALETTE.emberDeep, Enum.Material.Neon,
		{ Shape = Enum.PartType.Cylinder, CanCollide = false, CanQuery = false,
			CanTouch = false, CastShadow = false })
	for i = 1, 4 do
		local a = (i / 4) * math.pi * 2
		local beacon = P(m, "LakeGlow", Vector3.new(2, 2, 2),
			CFrame.new(VX + math.cos(a) * 30, lakeY + 5, VZ + math.sin(a) * 30),
			PALETTE.ember, Enum.Material.Neon,
			{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false,
				CastShadow = false })
		light(beacon, PALETTE.ember, 90, 2.6)
	end

	-- Cooled plates drifting on the lake: the same trick Island4Props.lavaPool
	-- uses at one twentieth the scale, and the reason a hundred-stud Neon disc
	-- does not read as a swimming pool.
	local rng = Random.new(Config.SEED + 777)
	for i = 1, 9 do
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(4, lakeR * 0.75)
		local w = rng:NextNumber(9, 22)
		P(m, "Raft", Vector3.new(w, 1.0, w * rng:NextNumber(0.55, 1)),
			CFrame.new(VX + math.cos(a) * d, lakeY + 0.5, VZ + math.sin(a) * d)
				* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
			dk(PALETTE.basalt, 0.4), Enum.Material.Slate,
			{ CanCollide = false, CastShadow = false })
	end

	-- The rim walk, from where the stair tops out round to the south lookout. On
	-- the flat terrace, midway between the pit's edge and the plateau's.
	local WALK_R = (PIT_R + V_TOP_R) * 0.5
	local arriveTheta = STAIR_THETA0 + STAIR_SWEEP
	local walkSteps = 14
	local sweep = -2.5                       -- back the way the stair came, to the south
	local prev = nil
	for i = 0, walkSteps do
		local th = arriveTheta + sweep * (i / walkSteps)
		local at = Vector3.new(VX + math.cos(th) * WALK_R, RIM_Y - 0.6, VZ + math.sin(th) * WALK_R)
		if prev then
			local mid = (prev + at) * 0.5
			local len = (at - prev).Magnitude
			local cf = CFrame.lookAt(mid, at)
			local outward = Vector3.new(mid.X - VX, 0, mid.Z - VZ).Unit
			local side = (cf.RightVector:Dot(outward) >= 0) and 1 or -1
			P(m, "RimWalk", Vector3.new(11, 2.0, len * 1.2), cf,
				(i % 2 == 0) and PALETTE.basalt or lt(PALETTE.basalt, 0.1), Enum.Material.Slate)
			-- rail on the CRATER side only: outside the walk is forty studs of flat
			-- terrace, inside it is a twenty-stud drop into the lake
			P(m, "RimRail", Vector3.new(0.7, 3.4, len * 1.2), cf * CFrame.new(-side * 5.4, 1.7, 0),
				PALETTE.iron, Enum.Material.Metal, { CanCollide = true })
			if i % 5 == 0 then
				prop("tikiTorch", m, cf * CFrame.new(side * 5.0, 1.0, 0), 8, true)
			end
		end
		prev = at
	end

	-- The lookout, at the end of the walk, a few studs further out on the terrace.
	local lookTheta = arriveTheta + sweep
	local lookAt = Vector3.new(VX + math.cos(lookTheta) * (WALK_R + 16), RIM_Y - 0.6,
		VZ + math.sin(lookTheta) * (WALK_R + 16))
	local lookCF = CFrame.lookAt(lookAt, Vector3.new(VX, lookAt.Y, VZ))
	P(m, "Lookout", Vector3.new(26, 2.2, 20), lookCF * CFrame.new(0, -0.1, 0),
		lt(PALETTE.basalt, 0.14), Enum.Material.Slate)
	for _, s in ipairs({ -1, 1 }) do
		P(m, "LookoutRail", Vector3.new(0.7, 3.6, 20), lookCF * CFrame.new(s * 12.6, 2.0, 0),
			PALETTE.iron, Enum.Material.Metal)
	end
	P(m, "LookoutRail", Vector3.new(26, 3.6, 0.7), lookCF * CFrame.new(0, 2.0, -9.6),
		PALETTE.iron, Enum.Material.Metal)
	prop("brazier", m, lookCF * CFrame.new(-9, 1.1, 7), 1.1)
	prop("brazier", m, lookCF * CFrame.new(9, 1.1, 7), 1.1)
	local board = P(m, "SummitBoard", Vector3.new(17, 4.4, 0.5),
		lookCF * CFrame.new(0, 8.6, 9.4), PALETTE.ash, Enum.Material.Slate)
	SignKit.dress(board, "THE CALDERA", { Enum.NormalId.Front, Enum.NormalId.Back })
	for _, s in ipairs({ -1, 1 }) do
		P(m, "BoardPost", Vector3.new(0.9, 9, 0.9), lookCF * CFrame.new(s * 8, 4.6, 9.4),
			PALETTE.basalt, Enum.Material.Slate)
	end

	-- Fumaroles on the terrace, which is where a real one puts them.
	for i = 1, 6 do
		local th = arriveTheta + sweep - 0.55 - i * 0.42
		local rr = (i % 2 == 0) and (PIT_R + 8) or (V_TOP_R - 12)
		prop("fumarole", m,
			CFrame.new(VX + math.cos(th) * rr, RIM_Y, VZ + math.sin(th) * rr), 1.5, 900 + i)
	end

	Island4.lakePart = lake
	return m
end

----------------------------------------------------------------
-- THE EMBER CAVE
----------------------------------------------------------------
-- The dressing for the bore carved in buildTerrain: a framed mouth, torches
-- down the tunnel and a pool under the light shaft. Placed by RAYCAST, unlike
-- everything on the cone -- a carved tunnel's floor is the product of seven
-- overlapping balls and there is no function that predicts it.
local function buildCave(parent): Model
	local m = Instance.new("Model")
	m.Name = "EmberCave"
	m.Parent = parent

	local mouthZ = TERRACE_Z - TERRACE_R + 6

	-- the mouth: boulders either side and a lintel stone over it
	for _, s in ipairs({ -1, 1 }) do
		prop("rock", m, CFrame.new(TERRACE_X + s * 15, groundY(TERRACE_X + s * 15, mouthZ - 8, GROUND), mouthZ - 8)
			* CFrame.Angles(0, s * 0.8, 0), 18, "boulder", PALETTE.basalt)
	end
	--[[
		NO SIGNBOARD. There was an EMBER CAVE board on two posts standing out in
		front of the mouth, and a hole in a mountain does not come with signage --
		the boulders and the torch light inside are the invitation. Every other
		sign on this island marks something a person built.
	]]

	-- torches down the bore, alternating sides. Probed from inside for the reason
	-- the chamber block below gives.
	for i = 0, 5 do
		local z = mouthZ + 4 + i * 12
		local x = TERRACE_X + ((i % 2 == 0) and -6 or 6)
		local hit = workspace:Raycast(Vector3.new(x, 24, z), Vector3.new(0, -40, 0), groundParams)
		prop("tikiTorch", m, CFrame.new(x, hit and hit.Position.Y or GROUND, z), 7, true)
	end

	--[[
		The chamber: a pool under the shaft, spires round it, a fern where the
		daylight lands.

		PROBED FROM INSIDE THE CAVE, NOT FROM THE SKY. groundY fires from y = 300,
		which in here finds the top of the terrace thirty studs overhead -- so the
		first cut put the chamber's lava pool seventeen studs inside the ceiling. A
		room under a mountain is the one place on this island a downward raycast
		cannot be trusted, and it is the one place nothing analytic knows the answer
		either, because the floor is the product of seven overlapping carves.
	]]
	local cz = mouthZ + 80
	local function caveFloor(x, z)
		local hit = workspace:Raycast(Vector3.new(x, 24, z), Vector3.new(0, -40, 0), groundParams)
		return hit and hit.Position.Y or GROUND
	end
	local floor = caveFloor(TERRACE_X, cz)
	prop("lavaPool", m, CFrame.new(TERRACE_X - 6, caveFloor(TERRACE_X - 6, cz + 4) + 0.8, cz + 4), 9, 314)
	for _, s in ipairs({ -1, 1 }) do
		prop("obsidianSpire", m, CFrame.new(TERRACE_X + s * 12, caveFloor(TERRACE_X + s * 12, cz - 6), cz - 6)
			* CFrame.Angles(0, s, 0), 1.1, 220 + s)
	end
	prop("pumiceCluster", m, CFrame.new(TERRACE_X + 4, caveFloor(TERRACE_X + 4, cz), cz), 1.3, 44)
	prop("campCrate", m, CFrame.new(TERRACE_X + 9, floor, cz + 9) * CFrame.Angles(0, 0.6, 0), "crate", 12)
	return m
end

----------------------------------------------------------------
-- ASHFALL LANDING  --  the camp
----------------------------------------------------------------
--[[
	The one place on the island where the game is played rather than looked at:
	the berth you arrive at, the shop, the wash bay, the vehicle pad and the sell
	pad, laid out around a single through-road from the pier to the sand.

	THE ROAD IS THE PLAN. Island3Builder's precinct note records what happens when
	it is not -- the hall stood across the only route between the field and the
	scales, and the car pad pointed at a shed -- and every one of those decisions
	is inverted here from the start:

		* the Cinder Road runs unbroken from the causeway at z = -368 out onto the
		  sand at z = -176, and nothing may stand in x [CX-15, CX+15] over that
		  whole run: it is the walk home, the sifter lane and the drive line at once
		* the SERVICES ALL TAKE THE EAST FLANK, north to south: the wash bay
		  nearest the field (a crusted find arrives from the sand, not from the
		  ferry), the outfitters on its shoulder, and the weighhouse at the south
		  end turned to face WEST across the road -- the road is dead straight,
		  so the pad still reads from the north gate
		* the WEST FLANK belongs to the EGG ROW and nothing else --
		  PetStationBuilder stands the four booths on the paving at x CX-40,
		  facing east at the road, so walking in from the pier the eggs are the
		  whole left-hand side of the street
		* the VEHICLE PAD goes OUTSIDE the east kerb pointing north, with ninety
		  studs of open sand in front of it and a drive laid on so the line is
		  obvious before you touch a key

	It returns the SellPad, which is the one thing in this file CTB_Server needs.
]]
local function buildCamp(parent): (Model, BasePart, number)
	local m = Instance.new("Model")
	m.Name = "Landing"
	m.Parent = parent

	local G = GROUND
	local X0, X1 = CX - CAMP_HALF, CX + EAST_HALF
	local torches = 0

	-- THE CAMP'S OWN DATUM. Every z in this function that is not already written
	-- as an offset from it carries CZ - ... - 2*GROW for the same reason the camp
	-- square does: these sit ON that square, and it moves south when the rakeable
	-- field grows. Left as bare world numbers they would be abandoned in the
	-- middle of the rakeable sand. Declared up here rather than down in the
	-- dressing because the frontages and the spurs below want it too.
	local CD = CZ - 2 * GROW

	local function torch(cf, h, lit)
		if prop("tikiTorch", m, cf, h, lit) then
			torches += 1
		end
	end

	----------------------------------------------------------------
	-- The causeway off the pier
	----------------------------------------------------------------
	-- 0.12 proud and not an inch more. "Raised decking" is a look, not a height:
	-- anything a player can trip on between the only way in and the only place to
	-- sell is a bug. What makes it READ as raised is the stringer -- a beam
	-- dropped nearly a stud below the deck along both sides, which casts the
	-- shadow line a raised deck has without ever being something to walk up.
	do
		local plank = 2.4
		local n = math.floor((DECK_Z1 - DECK_Z0) / plank)
		for i = 0, n - 1 do
			local z = DECK_Z0 + i * plank
			box(m, "Plank", CX - LANE_HALF, CX + LANE_HALF, G - 0.5, G + 0.12,
				z + 0.08, z + plank - 0.08,
				(i % 2 == 0) and PALETTE.timber or dk(PALETTE.timber, 0.22),
				Enum.Material.WoodPlanks)
		end
		for _, s in ipairs({ -1, 1 }) do
			box(m, "Stringer", CX + s * LANE_HALF - 0.9, CX + s * LANE_HALF + 0.9,
				G - 0.9, G + 0.16, DECK_Z0, DECK_Z1, dk(PALETTE.timber, 0.4),
				Enum.Material.WoodPlanks)
			torch(CFrame.new(CX + s * (LANE_HALF + 3.4), G, DECK_Z0 + 8), 9, true)
			torch(CFrame.new(CX + s * (LANE_HALF + 3.4), G, DECK_Z1 - 6), 9, s > 0)
		end
	end

	----------------------------------------------------------------
	-- The square
	----------------------------------------------------------------
	-- Collidable and 0.12 proud, so the player walks ON the paving rather than
	-- through a decal of it. Same number as the causeway, and they meet edge to
	-- edge at z = CAMP_Z0 with no overlap, so there is no coplanar strip to
	-- z-fight.
	box(m, "Paving", X0, X1, G - 0.5, G + 0.12, CAMP_Z0, CAMP_Z1,
		lt(PALETTE.basalt, 0.06), Enum.Material.Slate)
	--[[
		THE SLAB JOINTS, AND NONE OF THEM HAS EVER EXISTED.

		They asked for y from G+0.12 to G+0.17, and box() drops any part with a span
		under 0.05. G is 3.0, so that span is computed in floating point as
		3.17 - 3.12 = 0.049999999999999822 -- UNDER the guard by two parts in 10^17.
		All seven returned nil, silently, at every boot this island has ever had, and
		the comment above describing the paving's divisions described nothing.

		That is most of why a hundred and eighty studs by a hundred and fifty-six read
		as one undivided sheet of grey. 0.07 clears the guard with room that no
		rounding can eat, and asking for a span that lands exactly ON a threshold is
		the bug, not the guard.

		THE ONE OVER THE ROAD IS SKIPPED. At an eighth of 180 the joints land on
		CX-81.5, -59, -36.5, -14, +8.5, +31 and +53.5, and CX+8.5 is INSIDE the Cinder
		Road -- coplanar with a slab that is drawn in the same band, i.e. a z-fighting
		stripe flickering up the middle of the one piece of paving nothing is allowed
		to stand on. Six joints and a clean road beats seven and a seam.
	]]
	for i = 1, 7 do
		local jx = X0 + i * ((X1 - X0) / 8)
		if math.abs(jx - CX) > LANE_HALF + 0.5 then
			box(m, "Joint", jx - 0.3, jx + 0.3, G + 0.12, G + 0.19, CAMP_Z0, CAMP_Z1,
				dk(PALETTE.basalt, 0.3), Enum.Material.Slate, { CanCollide = false })
		end
	end

	-- The west kerb runs the whole depth. The east one is BROKEN over the vehicle
	-- pad, so walking out to the machines is a gap in an edge rather than a step
	-- over one -- the same call the two gate breaks below make.
	box(m, "Kerb", X0 - 1.3, X0 + 1.3, G + 0.12, G + 0.8, CAMP_Z0, CAMP_Z1,
		PALETTE.basalt, Enum.Material.Slate)
	for _, run in ipairs({ { CAMP_Z0, CZ - 290 - 2 * GROW }, { CZ - 234 - 2 * GROW, CAMP_Z1 } }) do
		box(m, "Kerb", X1 - 1.3, X1 + 1.3, G + 0.12, G + 0.8, run[1], run[2],
			PALETTE.basalt, Enum.Material.Slate)
	end
	for _, run in ipairs({ { X0, CX - GATE_GAP }, { CX + GATE_GAP, X1 } }) do
		box(m, "KerbSouth", run[1], run[2], G + 0.12, G + 0.8, CAMP_Z0 - 1.3, CAMP_Z0 + 1.3,
			PALETTE.basalt, Enum.Material.Slate)
		box(m, "KerbNorth", run[1], run[2], G + 0.12, G + 0.8, CAMP_Z1 - 1.3, CAMP_Z1 + 1.3,
			PALETTE.basalt, Enum.Material.Slate)
	end

	-- THE CINDER ROAD. A paler lane straight up the middle, running the whole
	-- depth of the square and on out over the sand past the north gate. It is the
	-- one piece of paving nothing is allowed to stand on.
	--
	-- IT STOPS AT LANE_Z1, NOT AT THE FIELD EDGE. assertClearOfField measures a
	-- part's real extent, and a slab reaching z = -176 clears the square's south
	-- edge by sixteen studs. Run it the last sixteen and the island reports itself
	-- broken at every boot.
	box(m, "CinderRoad", CX - LANE_HALF, CX + LANE_HALF, G + 0.12, G + 0.2,
		CAMP_Z0, LANE_Z1, PALETTE.ash, Enum.Material.Slate, { CanCollide = false })
	for _, s in ipairs({ -1, 1 }) do
		box(m, "RoadEdge", CX + s * LANE_HALF - 0.5, CX + s * LANE_HALF + 0.5,
			G + 0.12, G + 0.32, CAMP_Z0, LANE_Z1, dk(PALETTE.basalt, 0.2),
			Enum.Material.Slate, { CanCollide = false })
	end

	----------------------------------------------------------------
	-- THE WEST FRONTAGE, and the spurs off the road to every door
	----------------------------------------------------------------
	--[[
		THE EGG ROW GETS AN APRON, the way the dune row does.

		PetStationBuilder sites that row off PetConfig.StationOverrides[5].row and
		parents it into Workspace.PetStations -- so it is NOT part of this model and
		this file cannot move it. What this file CAN do is what Island2Builder does
		for the dune row with its Forecourt: lay the made ground the booths stand on,
		out to the road, so four sheds on open paving read as a shopfront instead of
		as four sheds on open paving.

		THE X IS PetConfig'S NUMBER, NOT THIS FILE'S. That override is CX-28; the
		deepest booth is 16.4 through, so the fronts land on CX-20 -- seven studs off
		the road edge at CX-13, which is the pavement the cove's row keeps and the
		same reasoning its own note gives. It used to be CX-40, and PetConfig's note
		said so out loud: "~20 studs of paving to the road edge". Twenty studs is not
		a pavement, it is a forecourt with nothing in it, and this flank had ninety
		more behind it.

		IF THAT OVERRIDE MOVES, THIS APRON MOVES WITH IT. One number, two files, and
		the note at PetConfig's end points back here so neither can go stale quietly.

		The z is that override's too (CD-280). The apron is quoted generously at
		either end rather than fitted to the row's length, because the booth pitch is
		computed from the tube models at run time (rowPitch) and is none of this
		file's business.
	]]
	local EGG_X, EGG_Z = CX - 28, CD - 280
	box(m, "EggForecourt", EGG_X - 14, CX - LANE_HALF - 0.6, G - 0.5, G + 0.42,
		EGG_Z - 42, EGG_Z + 42, PALETTE.basalt, Enum.Material.Slate)

	--[[
		THE TWO FRONTAGE LINES, DRAWN. A pale band one stud wide down the pavement at
		each frontage offset -- CX+22 on the service flank, CX-20 on the egg flank.

		This is the cove's device and it is most of why that plaza reads as a made
		place at a third of this one's footprint: its kerb runs are picked out in a
		colour against the paving, so the ground is divided into bays you can see
		rather than one slab you cannot. Ashfall had the Joint lines for that and they
		are eight studs apart across a hundred and eighty, i.e. a grid, not a plan.

		The east line runs the WHOLE depth of the square, not just past the three
		buildings. Where a building stands it reads as its threshold; where none does
		it reads as the pavement continuing, which is the honest thing for it to say
		and the reason the flank still looks deliberate at the ends.
	]]
	box(m, "FrontageLine", CX + 21, CX + 22, G + 0.13, G + 0.21, CAMP_Z0, CAMP_Z1,
		PALETTE.ashPale, Enum.Material.Slate, { CanCollide = false })
	box(m, "FrontageLine", CX - 21, CX - 20, G + 0.43, G + 0.51, EGG_Z - 42, EGG_Z + 42,
		PALETTE.ashPale, Enum.Material.Slate, { CanCollide = false })

	--[[
		A SPUR OFF THE ROAD TO EVERY DOOR -- the cove's SandoBranch, in ash.

		Nine studs is a short spur and that is the point: the pale lane visibly
		reaches out of the road and touches each threshold, so the three buildings
		are things the road GOES to rather than things standing near it. It costs two
		flat parts apiece and it is the difference between a street and a car park.

		It starts at CX+13.6 rather than at CX+13. RoadEdge is a lip standing at
		CX+13 +- 0.5 and 0.2 proud of the road; a spur begun on CX+13 would share that
		half stud of ground at the same height and z-fight along its whole length.

		The egg flank gets none: its apron already runs to the road edge, which is
		the same statement made by a wider part.
	]]
	--[[
		AND TWO BANDS ACROSS THE ROAD, at the thirds of the camp's own length.

		The walk from the arrival gate to the north gate is a hundred and fifty-six
		studs of one unbroken lane -- the cove's sando is ninety and has a torii
		standing over it besides. These are the cheap half of that: a threshold you
		cross, twice, so the length reads as three bays instead of one corridor.

		FLAT AND NON-COLLIDABLE, which is why they are bands and not posts. A post
		pair either side of the road would stand in the nine-stud pavement, and that
		pavement has a torch row in it already.
	]]
	for _, bz in ipairs({ CD - 318, CD - 262 }) do
		box(m, "RoadBand", CX - LANE_HALF, CX + LANE_HALF, G + 0.2, G + 0.28,
			bz - 1.5, bz + 1.5, PALETTE.ashPale, Enum.Material.Slate,
			{ CanCollide = false })
	end

	for _, sp in ipairs({
		{ z = WASH.Z, half = 6 },
		{ z = SHOP.Z, half = 7 },
		{ z = HALL.Z, half = 8 },
	}) do
		box(m, "RoadSpur", CX + LANE_HALF + 0.6, CX + 22, G + 0.12, G + 0.2,
			sp.z - sp.half, sp.z + sp.half, PALETTE.ash, Enum.Material.Slate,
			{ CanCollide = false })
		for _, s in ipairs({ -1, 1 }) do
			box(m, "SpurEdge", CX + LANE_HALF + 0.6, CX + 22, G + 0.12, G + 0.3,
				sp.z + s * sp.half - 0.5, sp.z + s * sp.half + 0.5,
				dk(PALETTE.basalt, 0.2), Enum.Material.Slate, { CanCollide = false })
		end
	end

	----------------------------------------------------------------
	-- THE SELL PAD and the Weighhouse over it
	----------------------------------------------------------------
	--[[
		THREE COURSES, NOT ONE SLAB. Same shape and behaviour as the beach's --
		CTB_Server tests every pad in its list against the player's position, so
		standing on this one sells exactly as that one does, and this is the part
		that must come back out of build().

		The beach gets away with a single part because its sand is cool enough to
		hold an edge against gold. BLACK sand is the opposite problem and the worse
		one: a dark pad on dark paving has no edge at all. So it takes a PALE frame
		rather than the dark one the cove and the dunes use -- the only place on
		this island where the contrast runs the other way -- and rides 0.34 above
		ground so the glow beneath clears the paving's joint lines.
	]]
	--[[
		THE PAD IS ON THE HALL'S DECK, NOT OUT ON THE PAVING IN FRONT OF IT.

		It used to sit at SELL.X = CX+28, which is nineteen studs clear of the
		hall's mouth at HX0 = CX+47 -- so the building said SELL YOUR FINDS over an
		empty deck while the thing you actually stand on was a rectangle painted on
		the open plaza. The comment under it claimed "the pad is still in its
		mouth"; it was not, and had not been since the hall was moved to the east
		flank.

		Now it is centred on the hall and lifted onto the deck, so you walk in
		under the roof to sell. It FITS with room to spare and that was checked
		rather than hoped: the deck is 18 x 34 (HX0..HX1 by HZ0..HZ1) and the
		widest course here is the 16.4 x 23.4 frame, which leaves 0.8 studs of deck
		either side and 5.3 front and back.

		HEIGHT IS FINE FOR THE SELL TEST. CTB_Server's pad check allows nine studs
		of vertical slack (`math.abs(rel.Y) <= 9`); the deck lifts the pad 1.7. The
		step up is the plinth's 1.1 then the deck's 0.6, both inside what a
		character walks up without jumping.
	]]
	local HX0, HX1 = HALL.X - 9, HALL.X + 9
	local HZ0, HZ1 = HALL.Z - 17, HALL.Z + 17
	local DECK_TOP = G + 1.7

	local padX, padZ = HALL.X, HALL.Z
	P(m, "PadFrame", Vector3.new(16.4, 0.3, 23.4), CFrame.new(padX, DECK_TOP + 0.27, padZ),
		PALETTE.ashPale, Enum.Material.Slate, { CanCollide = false })
	P(m, "PadGlow", Vector3.new(14.4, 0.24, 21.4), CFrame.new(padX, DECK_TOP + 0.42, padZ),
		PALETTE.ember, Enum.Material.Neon, { CanCollide = false })
	local pad = P(m, "SellPad", Vector3.new(13, 0.45, 20),
		CFrame.new(padX, DECK_TOP + 0.52, padZ), lt(PALETTE.basalt, 0.2), Enum.Material.Slate)

	--[[
		THE STEP UP, so the deck reads as somewhere to walk rather than a ledge.
		Two treads across the hall's whole mouth, each landing on half the rise --
		one at the plinth's height and one at the deck's. Without them the only cue
		that you may walk in is that you can.
	]]
	for i = 1, 2 do
		box(m, "HallStep", HX0 - 3.4 + (i - 1) * 1.7, HX0 - 1.7 + (i - 1) * 1.7,
			G - 0.5, G + 0.55 * i + 0.6, HZ0 + 5, HZ1 - 5,
			PALETTE.basalt, Enum.Material.Slate)
	end

	-- The hall around it, open to the WEST now that it stands on the east flank,
	-- so the pad sits in its mouth and the mouth faces the road. Its depth is in
	-- X and its width in Z, because it is turned across the road.
	box(m, "HallPlinth", HX0 - 1.6, HX1 + 1.6, G - 0.5, G + 1.1, HZ0 - 1.6, HZ1 + 1.6,
		PALETTE.basalt, Enum.Material.Slate)
	box(m, "HallDeck", HX0, HX1, G + 1.1, G + 1.7, HZ0, HZ1,
		PALETTE.timber, Enum.Material.WoodPlanks)
	box(m, "HallBack", HX1 - 0.8, HX1, G + 1.7, G + 13, HZ0, HZ1,
		lt(PALETTE.basalt, 0.1), Enum.Material.Slate)
	for _, s in ipairs({ -1, 1 }) do
		box(m, "HallWall", HX0, HX1, G + 1.7, G + 13,
			(s < 0) and HZ0 or (HZ1 - 0.8), (s < 0) and (HZ0 + 0.8) or HZ1,
			lt(PALETTE.basalt, 0.1), Enum.Material.Slate)
		box(m, "HallPost", HX0 - 0.4, HX0 + 1.4, G + 1.7, G + 13,
			HALL.Z + s * 15 - 0.9, HALL.Z + s * 15 + 0.9,
			PALETTE.timber, Enum.Material.Wood)
	end
	for i = 0, 3 do
		box(m, "HallRoof" .. i, HX0 - 4 + i * 2.6, HX1 + 4 - i * 2.6, G + 13 + i * 1.2,
			G + 14.2 + i * 1.2, HZ0 - 3 + i * 0.8, HZ1 + 3 - i * 0.8,
			(i == 0) and dk(PALETTE.timber, 0.3) or PALETTE.basalt, Enum.Material.Slate,
			{ CanCollide = false })
	end
	local sellBoard = box(m, "SellBoard", HX0 - 0.8, HX0 - 0.3, G + 8.4, G + 12.4,
		HALL.Z - 12, HALL.Z + 12, PALETTE.ash, Enum.Material.Slate)
	if sellBoard then
		SignKit.dress(sellBoard, "SELL YOUR FINDS", { Enum.NormalId.Right, Enum.NormalId.Left })
	end
	-- ON THE HALL'S OWN CENTRE LINE, at its two ends -- not at HALL.X-11, which
	-- was eleven studs clear of the building when it stood on CX+56 and is the
	-- PAVEMENT now that it stands on the frontage line. Measured there: a fire
	-- basket at CX+21.6 cut the nine-stud pavement to a four-stud squeeze, which
	-- is the furniture-in-a-doorway mistake this file keeps warning about.
	prop("brazier", m, CFrame.new(HALL.X, G, HALL.Z - 20), 1)
	prop("brazier", m, CFrame.new(HALL.X, G, HALL.Z + 20), 1)

	----------------------------------------------------------------
	-- THE OUTFITTERS  --  the shop
	----------------------------------------------------------------
	--[[
		The upgrade panel opens on a ProximityPrompt named "ShopPrompt" anywhere in
		the world. That name is the entire integration and renaming it unhooks the
		shop, exactly as StoreBuilder's, Island2Builder's and Island3Builder's copies
		of this comment say. RequiresLineOfSight is off for the same reason it is off
		there: the counter stands between the player and the anchor, so the test would
		hide the prompt from precisely where you are meant to be standing. ObjectText
		is not cosmetic either -- MenuHud retitles its panel from it, and left blank
		the header reads BEACH SHOP while you are standing on a volcano.

		THE ANCHOR IS A PART THIS FILE OWNS OUTRIGHT. A prompt parented to a prop that
		another script builds would vanish the moment that prop failed, and the shop
		would be gone with it.
	]]
	do
		local facing = CFrame.lookAt(Vector3.new(SHOP.X, G, SHOP.Z), Vector3.new(CX, G, SHOP.Z))
		box(m, "ShopPlinth", SHOP.X - 14, SHOP.X + 14, G - 0.5, G + 0.42, SHOP.Z - 13, SHOP.Z + 13,
			PALETTE.basalt, Enum.Material.Slate)
		prop("outfitterStall", m, facing * CFrame.new(0, 0.42, 0))

		local anchor = P(m, "PromptAnchor", Vector3.new(1, 1, 1),
			facing * CFrame.new(0, G + 5.2, -9),
			PALETTE.ash, Enum.Material.SmoothPlastic,
			{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
		anchor.CFrame = facing * CFrame.new(0, 5.2, -9)
		local shopPrompt = Instance.new("ProximityPrompt")
		shopPrompt.Name = "ShopPrompt"
		shopPrompt.ActionText = "Browse"
		shopPrompt.ObjectText = "Ashfall Outfitters"
		shopPrompt.KeyboardKeyCode = Enum.KeyCode.E
		shopPrompt.HoldDuration = 0
		shopPrompt.MaxActivationDistance = 16
		shopPrompt.RequiresLineOfSight = false
		shopPrompt.Parent = anchor

		-- Both faces: a thin board has two readable sides and signing only one is a
		-- coin flip you lose half the time.
		local board = P(m, "ShopBoard", Vector3.new(22, 4.2, 0.5), facing * CFrame.new(0, 12.6, -9.6),
			PALETTE.ash, Enum.Material.Slate)
		--[[
			THE BOARD SAYS WHAT THE SHOP DOES, NOT WHAT IT IS CALLED.

			It said "OUTFITTERS", which tells a player nothing -- the dunes' marquee
			had the identical fault ("DUNE BAZAAR" and "DUNE OUTFITTERS" both read as
			generic shop from across the street) and was changed to SELL and UPGRADES
			for the same reason. The cove's board has read UPGRADES since it was built.

			The shop's NAME survives on the prompt's ObjectText, which is what MenuHud
			retitles its panel from -- exactly the split the dunes kept, where the
			marquee carries the verb and the prompt carries "Dune Outfitters".
		]]
		SignKit.dress(board, "UPGRADES", { Enum.NormalId.Front, Enum.NormalId.Back })
		for _, s in ipairs({ -1, 1 }) do
			P(m, "BoardPost", Vector3.new(0.8, 13, 0.8), facing * CFrame.new(s * 10.6, 6.5, -9.6),
				PALETTE.timber, Enum.Material.Wood)
		end
		torch(facing * CFrame.new(-13, 0.42, -11), 8, true)
		torch(facing * CFrame.new(13, 0.42, -11), 8, true)
	end

	----------------------------------------------------------------
	-- THE WASH BAY
	----------------------------------------------------------------
	--[[
		A CLONE OF THE AUTHORED BEACH SHACK, the same way the dunes' and the cove's
		are: that model is the one WashServer knows how to bind (it carries the tag
		and a part named Stand), and cloning it means all four islands stay one
		building rather than four that drift.

		Turned to face -X, across the road. Placed by its BOUNDING BOX rather than
		its pivot -- the authored model's pivot sits above its own underside, which
		is a fact about how somebody saved it rather than anything to build against.
	]]
	local authored = workspace:FindFirstChild("WashBay")
	if authored and authored:IsA("Model") then
		local rig = authored:Clone()
		rig.Name = "AshfallWashBay"
		rig:PivotTo(CFrame.new(WASH.X, 0, WASH.Z) * CFrame.Angles(0, -math.pi * 0.5, 0))
		local bcf, bsize = rig:GetBoundingBox()
		rig:PivotTo(rig:GetPivot() + Vector3.new(
			WASH.X - bcf.Position.X,
			(G + 0.12) - (bcf.Position.Y - bsize.Y * 0.5),
			WASH.Z - bcf.Position.Z))
		rig.Parent = m
		-- Only the awning slats and the signboard are repainted. The timber is the
		-- same carpenter as the beach's and looks right here; the stripes are the one
		-- part that would read as imported, so they go ember-and-ash.
		for _, p in ipairs(rig:GetDescendants()) do
			if p:IsA("BasePart") then
				local n = p.Name:match("^Stripe(%d+)$")
				if n then
					p.Color = (tonumber(n) % 2 == 0) and PALETTE.ashPale or PALETTE.emberDeep
				elseif p.Name == "SignBoard" then
					p.Color = PALETTE.basalt
				end
			end
		end
		-- A trough of meltwater beside it, on the NORTH shoulder: south of the bay is
		-- the lane to the vehicle pad, and six studs of solid rock standing in a
		-- route is the mistake Island3Builder's precinct note is about.
		-- ON THE FAR SIDE OF THE BAY FROM THE ROAD. It used to sit on WASH.X - 15,
		-- which was open sand when the bay stood at CX+54 and is the PAVEMENT now
		-- that the bay stands on CX+22: six studs of collidable rock two studs off
		-- the kerb, in the one lane every player on this island walks.
		box(m, "Trough", WASH.X + 9, WASH.X + 15, G + 0.12, G + 3.2, WASH.Z + 8, WASH.Z + 16,
			PALETTE.basalt, Enum.Material.Slate)
		box(m, "TroughWater", WASH.X + 9.6, WASH.X + 14.4, G + 2.7, G + 3.0, WASH.Z + 8.6, WASH.Z + 15.4,
			Color3.fromRGB(120, 174, 186), Enum.Material.Glass,
			{ CanCollide = false, Transparency = 0.35, Reflectance = 0.25 })
	end

	----------------------------------------------------------------
	-- THE VEHICLE PAD, outside the east kerb
	----------------------------------------------------------------
	--[[
		CarSpawnerBuilder builds its bay CLOSED at the back and OPEN at the front,
		and its SpawnPoint faces +Z, so a machine leaves pointing north. That is
		exactly why the pad is out here and not in the square: north of it is ninety
		studs of open black sand and then the field, and there is nothing in between.
		The cove learned this the other way round, with a quad pointed at a shed.
	]]
	local okCar, carErr = pcall(function()
		local CarSpawnerBuilder = require(script.Parent:WaitForChild("CarSpawnerBuilder"))
		local carPad = CarSpawnerBuilder.build(CFrame.new(CARPAD.X, G + 0.2, CARPAD.Z))
		carPad.Name = "AshfallCarSpawner"
		carPad.Parent = m
		-- The builder hangs its board off the pad's +X side, because on the beach
		-- that is the side the whole row of frontages is walked up from. Here +X is
		-- open sand and the camp is on the other side, so the three sign parts are
		-- reflected across the pad's own centre line. SignKit already dressed BOTH
		-- faces of that board, so the reflection costs nothing.
		for _, p in ipairs(carPad:GetChildren()) do
			if p:IsA("BasePart") and (p.Name == "SignPost" or p.Name == "SignBoard"
				or p.Name == "SignTrim") then
				p.Position = Vector3.new(2 * CARPAD.X - p.Position.X, p.Position.Y, p.Position.Z)
			end
		end
	end)
	if not okCar then
		warn("[Ashfall] no vehicle pad at the landing:", carErr)
	end

	-- A spur of paving out through the break in the kerb, so the walk to the
	-- machines is a made path and not eight studs of loose sand.
	box(m, "CarApron", X1 - 2, CARPAD.X - 10, G - 0.5, G + 0.12,
		CARPAD.Z - 13, CARPAD.Z + 13, lt(PALETTE.basalt, 0.06), Enum.Material.Slate)

	--[[
		THE DRIVE. Packed ash from the bay mouth to the edge of the field, and the
		one piece of this island whose whole job is to be READ rather than walked on:
		somebody who has just spent six thousand on a quad should be able to see
		where it goes before they touch a key.

		IT STOPS AT LANE_Z1 for the reason the road does.
	]]
	box(m, "Drive", CARPAD.X - 9, CARPAD.X + 9, G + 0.02, G + 0.1,
		CARPAD.Z + 11, LANE_Z1, dk(PALETTE.ash, 0.35), Enum.Material.Slate,
		{ CanCollide = false })
	for _, s in ipairs({ -1, 1 }) do
		box(m, "DriveRut", CARPAD.X + s * 3.4 - 0.9, CARPAD.X + s * 3.4 + 0.9,
			G + 0.1, G + 0.16, CARPAD.Z + 11, LANE_Z1,
			PALETTE.ash, Enum.Material.Slate, { CanCollide = false })
	end

	----------------------------------------------------------------
	-- THE TWO GATES
	----------------------------------------------------------------
	-- The north gate is the one that matters: from out on the field the camp is a
	-- low dark line with three roofs on it, and this is the shape that says WHERE
	-- IT OPENS. The kerb is broken either side of it.
	do
		local gateZ = CAMP_Z1
		for _, s in ipairs({ -1, 1 }) do
			box(m, "GatePost", CX + s * GATE_GAP - 3, CX + s * GATE_GAP + 3, G, G + 18,
				gateZ - 3, gateZ + 3, PALETTE.basalt, Enum.Material.Slate)
			box(m, "GateFoot", CX + s * GATE_GAP - 4.4, CX + s * GATE_GAP + 4.4, G, G + 2.4,
				gateZ - 4.4, gateZ + 4.4, dk(PALETTE.basalt, 0.2), Enum.Material.Slate)
			torch(CFrame.new(CX + s * (GATE_GAP + 9), G + 0.12, gateZ), 10, true)
		end
		box(m, "GateLintel", CX - GATE_GAP - 5, CX + GATE_GAP + 5, G + 18, G + 22,
			gateZ - 3.6, gateZ + 3.6, lt(PALETTE.basalt, 0.12), Enum.Material.Slate)
		local nameBoard = box(m, "NameBoard", CX - 15, CX + 15, G + 22.2, G + 27,
			gateZ - 0.8, gateZ - 0.3, PALETTE.ash, Enum.Material.Slate)
		if nameBoard then
			SignKit.dress(nameBoard, "ASHFALL LANDING", { Enum.NormalId.Front, Enum.NormalId.Back })
		end
	end

	-- ...and a smaller one where the causeway meets the square, so arriving reads
	-- as arriving somewhere.
	do
		local gateZ = CAMP_Z0
		for _, s in ipairs({ -1, 1 }) do
			box(m, "ArrivalPost", CX + s * GATE_GAP - 2.2, CX + s * GATE_GAP + 2.2, G, G + 13,
				gateZ - 2.2, gateZ + 2.2, PALETTE.timber, Enum.Material.Wood)
		end
		box(m, "ArrivalLintel", CX - GATE_GAP - 3.6, CX + GATE_GAP + 3.6, G + 13, G + 15.4,
			gateZ - 2.6, gateZ + 2.6, dk(PALETTE.timber, 0.25), Enum.Material.Wood)
	end

	----------------------------------------------------------------
	-- Dressing
	----------------------------------------------------------------
	-- Every z here is an offset from CD, the camp datum declared at the top of this
	-- function -- see the note on it.
	prop("canvasTent", m, CFrame.lookAt(Vector3.new(CX - 78, G + 0.12, CD - 344),
		Vector3.new(CX - 40, G + 0.12, CD - 344)), 1.1)
	prop("canvasTent", m, CFrame.lookAt(Vector3.new(CX - 80, G + 0.12, CD - 238),
		Vector3.new(CX - 40, G + 0.12, CD - 238)), 0.95)
	prop("campCrate", m, CFrame.new(CX - 34, G + 0.12, CD - 352) * CFrame.Angles(0, 0.4, 0), "crate", 1)
	prop("campCrate", m, CFrame.new(CX - 26, G + 0.12, CD - 358) * CFrame.Angles(0, -0.7, 0), "barrel", 2)
	-- The arrival apron south of the weighhouse, and back against the flank
	-- rather than out on the frontage line at CX+22 -- see the note on it.
	prop("campCrate", m, CFrame.new(CX + 42, G + 0.12, CD - 356) * CFrame.Angles(0, 0.9, 0), "nets", 3)
	prop("campCrate", m, CFrame.new(CX + 52, G + 0.12, CD - 348) * CFrame.Angles(0, 0.2, 0), "sacks", 4)
	prop("campCrate", m, CFrame.new(CX - 90, G + 0.12, CD - 262) * CFrame.Angles(0, 1.2, 0), "barrel", 5)
	-- CX+84 is OUTSIDE the kerb now that the east half is 76.
	prop("campCrate", m, CFrame.new(CX - 92, G + 0.12, CD - 318) * CFrame.Angles(0, -0.3, 0), "crate", 6)
	-- Both clear of the two frontage lines: the egg row's faces sit at
	-- x CX-20 and the shop plinth reaches z -281, and a fire basket standing
	-- in front of either is furniture in a doorway.
	prop("brazier", m, CFrame.new(CX - 64, G + 0.12, CD - 300), 1.15)
	-- Back by the kerb, not on CX+30: that is the pavement between the shop's
	-- plinth (ends z -289) and the weighhouse (starts z -301), which is a
	-- doorway, and a fire basket in a doorway is the thing this camp's whole
	-- layout note is about.
	prop("brazier", m, CFrame.new(CX + 68, G + 0.12, CD - 294), 1.15)
	for _, z in ipairs({ CD - 344, CD - 300, CD - 256 }) do
		for _, s in ipairs({ -1, 1 }) do
			torch(CFrame.new(CX + s * (LANE_HALF + 6), G + 0.12, z), 9, (z ~= CD - 300))
		end
	end
	--[[
		THE FRAME ROUND THE SQUARE -- and the four palms it replaces.

		There were four palms standing here and the note under them argued that
		sparse was both the brief and the truth. Sparse WAS right. The species was
		not: they were the one thing on this plaza that read as imported from the
		beach -- four bright green crowns on black ash under a live volcano, in the
		shot every player of this island sees before any other. This island's own
		scatter carries thirty burnt trees and not one of them was allowed inside the
		square.

		Every other precinct frames its walk with its OWN flora, and that is most of
		why the cove reads full at a third of this footprint: six sakura stand INSIDE
		its market, with a treeline past them. This is that, in Ashfall's props --
		dead trees, obsidian, basalt, cairns, pumice, sulphur.

		WORKED INTO THE OUTER BANDS, NOT SCATTERED. Everything is at |dx| >= 46, so it
		frames the walk instead of narrowing it, and it is quoted as CX/CD offsets so
		it slides south with the square exactly as the rest of the dressing does.

		THREE THINGS IT KEEPS OUT OF, and they are the reason the list is a table
		rather than a scatter loop -- each entry was placed against them:
		  the frontage lines   CX+22 east, CX-20 west, and the pavement in front
		  the vehicle route    the east kerb break, z CD-290..CD-234, out to the
		                       apron -- the walk to the machines
		  the square itself    everything sits between the south and north kerbs
	]]
	for _, t in ipairs({
		-- builder,         dx,    dz,   arg,  seed
		{ "burntTree",      -94,  -338,    16,   3 },
		{ "burntTree",      -98,  -262,    13,   7 },
		{ "burntTree",      -64,  -224,    14,  12 },
		{ "burntTree",       68,  -358,    15,   5 },
		{ "burntTree",       64,  -224,    12,   9 },
		{ "obsidianSpire",  -88,  -300,  1.10,   2 },
		{ "obsidianSpire",  -68,  -356,  0.85,   6 },
		{ "obsidianSpire",   52,  -352,  0.90,   4 },
		{ "obsidianSpire",   56,  -222,  0.80,  10 },
		{ "basaltColumns",  -56,  -342,  0.90,   8 },
		{ "cairn",          -96,  -226,     5,   1 },
		{ "cairn",          -50,  -232,   4.4,  13 },
		{ "cairn",           70,  -298,     5,  11 },
		{ "pumiceCluster",  -84,  -358,  1.00,  14 },
		{ "pumiceCluster",  -58,  -292,  0.85,  15 },
		{ "pumiceCluster",   70,  -218,  0.85,  16 },
		{ "sulphurCrust",   -72,  -282,     9,  17 },
		{ "sulphurCrust",    60,  -308,     7,  18 },
		{ "charredLog",     -82,  -324,     8,  19 },
		{ "charredLog",      48,  -306,     7,  20 },
		{ "rockFormation",  -98,  -362,  0.75,  21 },
	}) do
		prop(t[1], m, CFrame.new(CX + t[2], G + 0.12, CD + t[3])
			* CFrame.Angles(0, t[5] * 1.37, 0), t[4], t[5])
	end

	--[[
		THE WEIGHHOUSE'S BACK YARD. Pulling the hall onto the frontage line at CX+22
		left the twenty-eight studs it used to occupy empty, and empty ground BEHIND a
		building is the one kind this plaza had too much of already.

		A sell shop is where the cargo goes, so this is cargo: crates, a barrel, a
		sack pile, a fire basket and the third canvas tent, tucked against the flank
		rather than lined up. It is clear of the vehicle route to the north of it and
		of the hall's own east wall.
	]]
	prop("campCrate", m, CFrame.new(CX + 50, G + 0.12, CD - 326) * CFrame.Angles(0, 0.5, 0), "crate", 21)
	prop("campCrate", m, CFrame.new(CX + 56, G + 0.12, CD - 332) * CFrame.Angles(0, -0.8, 0), "barrel", 22)
	prop("campCrate", m, CFrame.new(CX + 48, G + 0.12, CD - 336) * CFrame.Angles(0, 0.2, 0), "sacks", 23)
	prop("brazier", m, CFrame.new(CX + 58, G + 0.12, CD - 318), 1.0)
	prop("canvasTent", m, CFrame.lookAt(Vector3.new(CX + 66, G + 0.12, CD - 336),
		Vector3.new(CX + 30, G + 0.12, CD - 336)), 1.0)

	--[[
		TWO FIRE BASKETS AT THE EGG ROW'S ENDS, which is what the flank has instead of
		hanging lamps: there is nothing on an apron to hang one from. At +-38 they sit
		just past the last booth either way, so they bracket the row rather than stand
		in front of one -- the doorway rule the braziers by the shop already follow.

		ON THE BOOTHS' OWN CENTRE LINE (EGG_X), NOT ON THEIR FRONTAGE. They were on
		CX-20, which is the frontage itself, and it measured exactly the same squeeze
		the hall's pair did: 2.5 studs of clear walk down a row a player has to walk
		the length of. Back here they are level with the booth bodies and the whole
		pavement is open.

		G+0.42 is the APRON's top, not the paving's. Every other prop in this camp is
		given the ground under it, and these two stand on the EggForecourt.
	]]
	prop("brazier", m, CFrame.new(EGG_X, G + 0.42, EGG_Z - 38), 1.05)
	prop("brazier", m, CFrame.new(EGG_X, G + 0.42, EGG_Z + 38), 1.05)

	--[[
		HANGING EMBER LAMPS on the three service frontages -- the cove's paper
		lanterns, in iron. Six of them, two per building, hung off the posts and
		boards each one already has so nothing new has to stand on the pavement.

		NO PointLight ON ANY OF THEM, and that is deliberate rather than lazy. This
		island already ships forty-seven light sources and the sky is pinned to day;
		under this grade a Neon core reads as lit on its own, and the note in
		Island3Builder about a decorative lantern being given a 22-stud range inside a
		23-stud stall is exactly the mistake six more would be.

		finalSweeps takes the shadows off both courses for free -- the cage is over
		half transparent and the core is Neon, which are two of the three classes it
		already strips.
	]]
	local function emberLamp(x: number, z: number, y: number, reach: number)
		P(m, "LampBracket", Vector3.new(math.abs(reach) + 0.4, 0.34, 0.34),
			CFrame.new(x + reach * 0.5, y + 1.6, z), PALETTE.iron, Enum.Material.Metal,
			{ CanCollide = false })
		P(m, "LampChain", Vector3.new(0.18, 1.3, 0.18), CFrame.new(x + reach, y + 0.95, z),
			PALETTE.iron, Enum.Material.Metal, { CanCollide = false })
		P(m, "LampCage", Vector3.new(1.5, 1.9, 1.5), CFrame.new(x + reach, y, z),
			PALETTE.iron, Enum.Material.DiamondPlate,
			{ CanCollide = false, Transparency = 0.55 })
		P(m, "LampCore", Vector3.new(0.95, 1.25, 0.95), CFrame.new(x + reach, y, z),
			PALETTE.glow, Enum.Material.Neon, { CanCollide = false })
	end
	for _, s in ipairs({ -1, 1 }) do
		emberLamp(CX + 23.6, HALL.Z + s * 15, G + 9.0, -1.1)   -- off the hall posts
		emberLamp(CX + 26.4, SHOP.Z + s * 10.6, G + 8.6, -1.1) -- off the shop's board posts
		emberLamp(CX + 22.6, WASH.Z + s * 6, G + 8.2, -1.1)    -- off the bay's road corner
	end

	--[[
		FOUR STANDARDS, one at each corner of the frontage block -- this island's
		answer to the cove's nobori, which is the one piece of furniture in that
		market doing the most work per part: something TALL at intervals, so the walk
		has a rhythm and a silhouette against the sky.

		ON THE OUTER PAVING AT |dx| = 46, NOT ON THE PAVEMENT. The pavement is nine
		studs between the road edge and a shopfront, the torch row already stands in
		it at CX+-19, and a second collidable pole three studs from a torch leaves
		two and a half studs to walk through. Out here they frame the block instead
		and read from further away, which is what a standard is for.
	]]
	local function standard(x: number, z: number, seed: number)
		P(m, "BannerPole", Vector3.new(0.7, 16, 0.7), CFrame.new(x, G + 8.12, z),
			PALETTE.iron, Enum.Material.Metal)
		P(m, "BannerFinial", Vector3.new(1.3, 1.3, 1.3),
			CFrame.new(x, G + 16.6, z) * CFrame.Angles(0.62, seed * 0.9, 0),
			PALETTE.ember, Enum.Material.Neon, { CanCollide = false })
		P(m, "BannerCrossbar", Vector3.new(0.45, 0.45, 4.6), CFrame.new(x, G + 14.9, z + 2.3),
			PALETTE.iron, Enum.Material.Metal, { CanCollide = false })
		-- Thin through X so the cloth faces ACROSS the road, which is the only
		-- bearing anybody reads it from.
		P(m, "BannerCloth", Vector3.new(0.3, 8.4, 3.6), CFrame.new(x, G + 10.5, z + 2.3),
			PALETTE.emberDeep, Enum.Material.Fabric, { CanCollide = false })
		P(m, "BannerHem", Vector3.new(0.34, 0.9, 3.6), CFrame.new(x, G + 6.4, z + 2.3),
			PALETTE.sulphur, Enum.Material.Fabric, { CanCollide = false })
	end
	standard(CX - 46, CD - 350, 1)
	standard(CX - 46, CD - 230, 2)
	standard(CX + 46, CD - 352, 3)
	standard(CX + 46, CD - 228, 4)

	return m, pad, torches
end

----------------------------------------------------------------
-- ADOPT OR BUILD
--
-- The same switch the dunes and the cove use: a Workspace.Island4 folder
-- carrying the HandBuilt attribute is authored geometry, and build() leaves it
-- exactly as saved. Without the attribute nothing changes and the island is
-- generated from scratch as it always was.
--
-- Adopting is three things -- find the sell pad, publish it, and run the sweeps
-- below. NOTHING in this script connects an event: the camp's ShopPrompt is a
-- ProximityPrompt, which IS a saved instance, and everything that moves out here
-- belongs to Island4_Client.
--
-- TO FREEZE THE ISLAND, once: run Island4.build() from the command bar in Edit
-- mode so the place holds the CURRENT geometry, set the attribute on the folder
-- it leaves behind, and save.
----------------------------------------------------------------
local HAND_BUILT = "HandBuilt"

--[[
	FINAL SWEEPS, run over the finished island whether it was generated or adopted.

	All four are idempotent and cost one descendant walk between them, and each is
	worth MORE on a hand-built island than on a generated one: a generated island
	has just been through them, so on an adopted one what they are really checking
	is whatever a person has added since.

	ANCHOR. Island4Props' contract says every BasePart it returns is anchored, and
	this is not a substitute for that -- it is the net under it. An unanchored part
	in a server-built island does not fail visibly at boot; it falls over some time
	in the next few minutes on a live server, on somebody else's screen, with
	nothing in the log.

	SHADOW CASTERS. Every part out here ships with CastShadow on, and under Future
	lighting each one is a draw into the shadow map whether or not it puts anything
	on the ground. Three classes never do: anything under a stud on its smallest
	axis, anything Neon (a part that is supposed to be emitting light casting a
	hard black shadow is wrong as well as expensive -- and this island has two
	hundred Neon parts), and anything more than half transparent.

	THE FIELD ASSERTION. Nothing may stand inside the rakeable square, and dragging
	a rock into it is precisely the mistake hand-editing invites.
]]
local function finalSweeps(root: Instance): (number, number, number, number, number)
	local unanchored = 0
	for _, p in ipairs(root:GetDescendants()) do
		if p:IsA("BasePart") and not p.Anchored then
			p.Anchored = true
			unanchored += 1
		end
	end

	local shadowsOff = 0
	for _, p in ipairs(root:GetDescendants()) do
		if p:IsA("BasePart") and p.CastShadow then
			local s = p.Size
			if math.min(s.X, s.Y, s.Z) < 1.0
				or p.Material == Enum.Material.Neon
				or p.Transparency > 0.5 then
				p.CastShadow = false
				shadowsOff += 1
			end
		end
	end

	local intruders = assertClearOfField(root)

	local partCount, lightCount = 0, 0
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			partCount += 1
		elseif d:IsA("Light") then
			lightCount += 1
		end
	end

	return unanchored, shadowsOff, intruders, partCount, lightCount
end

----------------------------------------------------------------
-- build
----------------------------------------------------------------
function Island4.build()
	--[[
		ADOPTED? Then the island in the place file IS the island, and build() returns
		here before it can touch any of it. See ADOPT OR BUILD, above.

		This is the FIRST thing build() does, ahead of the terrain note below,
		because the wipe that note is about is exactly what is being skipped.
	]]
	local existing = workspace:FindFirstChild("Island4")
	if existing and existing:GetAttribute(HAND_BUILT) == true then
		local landing = existing:FindFirstChild("Landing")
		local pad = landing and landing:FindFirstChild("SellPad")
		if pad then
			Island4.sellPad = pad
			Island4.built = true
			local unanchored, shadowsOff, intruders, partCount, lightCount = finalSweeps(existing)
			if unanchored > 0 then
				warn(string.format(
					"[Ashfall] anchored %d hand-placed part(s) that were left loose. Edit runs no "
					.. "physics, so they look right in Studio and fall over on a live server.",
					unanchored))
			end
			print(string.format(
				"[Ashfall] adopted the hand-built island saved in the place file: %d parts, "
				.. "%d lights, %d shadow casters trimmed, %d field intruders",
				partCount, lightCount, shadowsOff, intruders))
			return pad
		end
		warn(string.format(
			"[Ashfall] Workspace.Island4 is marked %s but has no Landing.SellPad -- rebuilding "
			.. "it from code, which loses any hand edits AND wipes raked progress. Rename that "
			.. "part back, or clear the %s attribute if the island is meant to be code-built.",
			HAND_BUILT, HAND_BUILT))
	end

	--[[
		ONCE, EVER, AND BEFORE baselineField(). NOT "idempotent".

		The GEOMETRY half is idempotent -- the folder is destroyed and remade. The
		TERRAIN half is not, in one specific and unrecoverable way: buildTerrain opens
		with a 790-radius Air wipe that covers the whole rakeable square, so a second
		call erases every column every player in the server has raked on Ashfall Isle,
		with no warning and no way back. At boot that is exactly right, because
		CTB_Server lays the baseline down immediately afterwards.
	]]
	if Island4.built then
		warn("[Ashfall] build() called again. The terrain wipe covers the whole rakeable square, "
			.. "so every player's raked progress on Ashfall Isle has just been erased. This is only "
			.. "safe once, at boot, before CTB_Server's baselineField().")
	end
	Island4.built = true

	local old = workspace:FindFirstChild("Island4")
	if old then
		old:Destroy()
	end

	local root = Instance.new("Folder")
	root.Name = "Island4"
	root.Parent = workspace

	--[[
		THE LITTER SET, built before anything else that can throw.

		ISLANDS[5].litterSet names ReplicatedStorage.CTB.Volcano and CTB_Client waits
		thirty seconds for it before giving up and scattering nothing. It is one call
		and it has no dependency on the island existing, so it goes first: a build
		that fails halfway still leaves the field with junk on it.
	]]
	local litterCount = 0
	do
		local ok, folder, n = pcall(function()
			return Props and Props.buildLitterSet(CTB)
		end)
		if ok and folder then
			litterCount = n or 0
		else
			warn("[Ashfall] the Volcano litter set could not be built: " .. tostring(folder))
		end
	end

	local mounds, stacks = buildTerrain()
	waitForGround()

	local props = Instance.new("Folder")
	props.Name = "Props"
	props.Parent = root

	----------------------------------------------------------------
	-- The camp, and the pad that must come out of it
	----------------------------------------------------------------
	local _, sellPad, campTorches = buildCamp(root)
	--[[
		PUBLISHED THE MOMENT IT EXISTS, not staked on the rest of build() finishing.

		CTB_Server only learns about this pad from build()'s return value, and that is
		six hundred lines away: the volcano, the stair, the streams, the caldera, the
		cave, the whole scatter and the field assertion all sit in between. Anything
		that throws in there leaves the pad PHYSICALLY STANDING in the world, glowing,
		under its "SELL YOUR FINDS" board -- and unregistered, so it does nothing. The
		player fills a bag on it, gets RollerBlocked, and there is no way out at all.
	]]
	Island4.sellPad = sellPad

	----------------------------------------------------------------
	-- The mountain
	----------------------------------------------------------------
	local _, stairTorches = buildStair(root)
	local _, plates = buildLavaStreams(root)
	buildCaldera(root)
	buildCave(root)

	----------------------------------------------------------------
	-- The landmark
	----------------------------------------------------------------
	--[[
		THE OBSIDIAN ARCH, standing across the waterline on the east shore.

		Its Y comes off a raycast and not off a constant. The ground under it is the
		product of three disc fills, a voxel lift and a carve, and the one thing that
		must be true of this arch is that its feet are ON that ground -- an arch
		resting a stud above its own reflection is a prop, an arch standing in the
		surf is a landmark.

		groundYWait, not groundY: this column is five hundred studs from the probe
		point in different chunks, and a miss here silently drops the landmark onto a
		fallback constant.
	]]
	local archY = groundYWait(ARCH_X, ARCH_Z, GROUND)
	buildArch(root, "ObsidianArch",
		CFrame.new(ARCH_X, archY - 2, ARCH_Z) * CFrame.Angles(0, math.pi * 0.12, 0),
		74, 46, 1717)
	-- A second, smaller one out on the shelf, so the first reads as one of a set
	-- that the sea is still making rather than as a single freak.
	local arch2X, arch2Z = CX + 556 + GROW, ICZ + 58
	buildArch(root, "LesserArch",
		CFrame.new(arch2X, groundYWait(arch2X, arch2Z, -2) - 1, arch2Z)
			* CFrame.Angles(0, -math.pi * 0.3, 0),
		40, 26, 2323)

	----------------------------------------------------------------
	-- Scatter
	----------------------------------------------------------------
	-- A fresh seed offset, so this island's layout is stable across boots but is
	-- not correlated with the dunes' (+5150), the vault's (+3141) or the cove's
	-- (+6188).
	local rng = Random.new(Config.SEED + 9430)

	--[[
		PROP-TO-PROP SPACING, which openGround() does not and cannot do.

		openGround() answers "is this spot clear of the rakeable field, of the civic
		geometry and of the cone". It knows nothing about the props this same loop
		has already dropped -- and on an island whose signature prop is a fourteen-
		stud boulder, two of them three studs apart is not a formation, it is a
		clipping error with a shadow.

		ONE list shared by every scatter below, because the collisions are between
		categories as often as within them. The radius each claim reserves is the
		prop's real footprint, not its trunk: a palm is its canopy.
	]]
	local placed = {}
	local function spaced(x: number, z: number, r: number): boolean
		for _, q in ipairs(placed) do
			local dx, dz = x - q[1], z - q[2]
			local reach = r + q[3]
			if dx * dx + dz * dz < reach * reach then
				return false
			end
		end
		return true
	end
	local function claim(x: number, z: number, r: number)
		table.insert(placed, { x, z, r })
	end

	-- Rock formations, everywhere. This is the island's texture and there are
	-- more of them than of anything else.
	local formations = 0
	for _ = 1, 1200 do
		if formations >= 46 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		-- EVERY SCATTER BAND ON THIS ISLAND CARRIES + GROW, and it is not cosmetic.
		-- These radii were drawn as "just outside the square, just inside the
		-- plateau" against a 160-stud half. openGround rejects anything reaching
		-- into the field, so a band left at 180..470 over a 320-stud half is
		-- rejected for its whole inner two thirds and the pass quietly places a
		-- handful of props in the corners instead of ringing the island.
		local d = rng:NextNumber(180 + GROW, 470 + GROW)
		local x, z = CX + math.cos(a) * d, ICZ + math.sin(a) * d
		local s = rng:NextNumber(0.7, 1.7)
		if openGround(x, z, 22 * s) and spaced(x, z, 20 * s) and not onTerrace(x, z, 6) then
			local y = groundY(x, z, GROUND)
			if y > 1.0 then
				if prop("rockFormation", props, CFrame.new(x, y, z)
					* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), s, formations) then
					formations += 1
					claim(x, z, 20 * s)
				end
			end
		end
	end

	-- Lava rocks on the tideline, placed by HEIGHT rather than by radius so they
	-- land on the wet sand instead of somewhere on the flat.
	local tideRocks = 0
	for _ = 1, 900 do
		if tideRocks >= 56 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(WET_R - 40, SHORE_R)
		local x, z = CX + math.cos(a) * d, ICZ + math.sin(a) * d
		local h = rng:NextNumber(4, 11)
		if clearOfBuildings(x, z, 12) and spaced(x, z, h) and not onCone(x, z, 8) then
			local y = groundY(x, z, GROUND)
			-- the tideline and only the tideline: the wet ring renders a stud under the
			-- dry sand and the shelf two under the water
			if y > -3.2 and y < GROUND - 0.15 then
				if prop("rock", props, CFrame.new(x, y, z)
					* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), h,
					(h > 8) and "rock" or "low", PALETTE.basalt) then
					tideRocks += 1
					claim(x, z, h)
				end
			end
		end
	end

	--[[
		BURNT TREES, NOT PALMS -- out here. Biased to the south half where the camp
		is: the north of this island is a mountain and things do not grow on it.

		The scatter was green tropical palms, and on a plain of black volcanic grit
		they were the only objects in frame that had obviously not been through what
		the island has been through. The four palms in the camp SQUARE stay -- that
		is a place people live and water things, and it is the one spot where
		tropical reads as deliberate rather than as an oversight.
	]]
	local palms = 0
	for _ = 1, 700 do
		if palms >= 30 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(190 + GROW, 430 + GROW)
		local x, z = CX + math.cos(a) * d, ICZ + math.sin(a) * d
		-- two thirds of them south of the field, one third scattered. The line is
		-- the field's own north quarter, not a fixed 120, so it stays in the same
		-- place on the island however big the square is.
		if z > FCZ + FIELD_HALF - 40 and rng:NextNumber() < 0.72 then
			continue
		end
		local h = rng:NextNumber(13, 22)
		if openGround(x, z, 16) and spaced(x, z, 12) and not onTerrace(x, z, 4) then
			local y = groundY(x, z, GROUND)
			if math.abs(y - GROUND) < 4 then
				if prop("burntTree", props, CFrame.new(x, y, z)
					* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), h, palms) then
					palms += 1
					claim(x, z, 12)
				end
			end
		end
	end

	--[[
		Pumice, logs and stumps: the low dressing, packed in around the rocks rather
		than given room of their own.

		THE 42% SLICE WAS FERNS. See the note on Island4Props.pumiceCluster for why
		an ash plain around a live volcano is the one place a broad-leafed plant
		cannot go, whatever colour it is painted.

		ONE HUNDRED AND TEN, NOT FORTY. This ring is 185 to 460 studs out -- about
		half a million square studs -- so forty props was one object every thirteen
		thousand, which is not dressing, it is punctuation. The island read as a
		grey plain with a few things on it because that is what it was.
	]]
	local low = 0
	for _ = 1, 2400 do
		if low >= 110 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(185 + GROW, 460 + GROW)
		local x, z = CX + math.cos(a) * d, ICZ + math.sin(a) * d
		if openGround(x, z, 9) and spaced(x, z, 7) then
			local y = groundY(x, z, GROUND)
			if math.abs(y - GROUND) < 6 then
				local roll = rng:NextNumber()
				local cf = CFrame.new(x, y, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0)
				local made
				if roll < 0.42 then
					made = prop("pumiceCluster", props, cf, rng:NextNumber(0.8, 1.5), low)
				elseif roll < 0.74 then
					made = prop("charredLog", props, cf, rng:NextNumber(8, 14))
				else
					made = prop("stump", props, cf, rng:NextNumber(4, 7))
				end
				if made then
					low += 1
					claim(x, z, 7)
				end
			end
		end
	end

	-- Obsidian spires and fumaroles, on the terrace and along the cone's skirt --
	-- the two places the ground is genuinely volcanic rather than sandy.
	local vents = 0
	for _ = 1, 1400 do
		if vents >= 40 then
			break
		end
		local onTerraceTop = rng:NextNumber() < 0.5
		local x, z
		if onTerraceTop then
			local a = rng:NextNumber(0, math.pi * 2)
			local d = rng:NextNumber(10, TERRACE_R - 52)
			x, z = TERRACE_X + math.cos(a) * d, TERRACE_Z + math.sin(a) * d
		else
			local a = rng:NextNumber(0, math.pi * 2)
			local d = rng:NextNumber(V_BASE_R + 14, V_BASE_R + 60)
			x, z = VX + math.cos(a) * d, VZ + math.sin(a) * d
		end
		if clearOfField(x, z, 14) and clearOfBuildings(x, z, 14) and spaced(x, z, 13) then
			local y = groundY(x, z, GROUND)
			if y > 1.0 then
				local cf = CFrame.new(x, y, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0)
				local made
				if rng:NextNumber() < 0.55 then
					made = prop("obsidianSpire", props, cf, rng:NextNumber(0.8, 1.7), vents)
				else
					made = prop("fumarole", props, cf, rng:NextNumber(1.0, 1.8), vents)
				end
				if made then
					vents += 1
					claim(x, z, 13)
				end
			end
		end
	end

	--[[
		SULPHUR CRUSTS AND COLUMNAR BASALT -- the two things this island was missing
		most, and they are missing different things.

		THE CRUSTS ARE FOR COLOUR. Ashfall's palette is four greys, an orange for
		the lava and a green for the palms, so anywhere out of sight of a flow the
		whole island resolves to one flat tone -- which is the note the playtest
		came back with. `sulphur` was already in the palette and unused. They go
		NEAR THE VENTS by preference, because that is where the real thing forms,
		and they are flat, so they cost the skyline nothing.

		THE COLUMNS ARE FOR SILHOUETTE. Columnar joints are the most recognisable
		rock a volcano leaves and there was not one on the island. They stand along
		the cone's skirt and on the terrace, where the ground is genuinely volcanic
		rather than sand.
	]]
	local crusts = 0
	for _ = 1, 1200 do
		if crusts >= 34 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(V_BASE_R + 6, V_BASE_R + 120)
		local x, z = VX + math.cos(a) * d, VZ + math.sin(a) * d
		if clearOfField(x, z, 10) and clearOfBuildings(x, z, 10) and spaced(x, z, 8) then
			local y = groundY(x, z, GROUND)
			if y > 0.6 then
				if prop("sulphurCrust", props, CFrame.new(x, y + 0.06, z)
					* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
					rng:NextNumber(6, 13), crusts) then
					crusts += 1
					claim(x, z, 6)
				end
			end
		end
	end

	--[[
		THE RING IS THE LOW DRESSING'S RING, AND THAT TOOK TWO WRONG ONES TO FIND.

		First cut: V_BASE_R + 10 .. + 74 about the CONE's centre at (CX, CZ + 470).
		That circle's far side is out past z 830 -- open sea, since the plateau is
		480 about (CX, ICZ) -- and its near side crosses the rakeable field, so
		clearOfField and the shoreline between them took all twelve. Zero placed.

		Second cut narrowed the band to the one the obsidian spires use. Two
		placed: the spires and fumaroles run FIRST and have already claimed
		thirteen-stud circles across it.

		So it uses the ring the low dressing uses, which is measured about the
		LANDMASS centre and therefore cannot wander into the water, with the same
		`math.abs(y - GROUND)` guard that keeps a hundred and ten ferns on dry
		land. The north-half test is the only thing added: columnar joints belong
		near the cone, not out on the camp's beach.
	]]
	local columns = 0
	for _ = 1, 2000 do
		if columns >= 12 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(195 + GROW, 440 + GROW)
		local x, z = CX + math.cos(a) * d, ICZ + math.sin(a) * d
		-- The cone is north, at VZ. Keep them on that half.
		if z > ICZ + 50 and openGround(x, z, 12) and spaced(x, z, 11) then
			local y = groundY(x, z, GROUND)
			if math.abs(y - GROUND) < 5 then
				if prop("basaltColumns", props, CFrame.new(x, y, z)
					* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
					rng:NextNumber(0.9, 1.6), columns) then
					columns += 1
					claim(x, z, 11)
				end
			end
		end
	end

	--[[
		CAIRNS. Props.cairn has been in the kit since the island was written and was
		only ever used at the camp; out on the flat it is the cheapest thing there
		is that says somebody walked here before you, which is exactly what a bare
		plain between a landing and a mountain wants.
	]]
	-- `spaced` sums both radii, so 9 here already means eighteen-plus studs from
	-- anything with a footprint. 24 was the first cut and it landed ONE cairn in
	-- sixteen: by the time this loop runs there are two hundred and fifty claims
	-- on the flat and every one of them was adding its own radius to the test.
	local cairns = 0
	for _ = 1, 1600 do
		if cairns >= 16 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(190 + GROW, 450 + GROW)
		local x, z = CX + math.cos(a) * d, ICZ + math.sin(a) * d
		if openGround(x, z, 8) and spaced(x, z, 9) then
			local y = groundY(x, z, GROUND)
			if math.abs(y - GROUND) < 4 then
				if prop("cairn", props, CFrame.new(x, y, z)
					* CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
					rng:NextNumber(4.5, 8), cairns) then
					cairns += 1
					claim(x, z, 8)
				end
			end
		end
	end

	-- Two lava pools out on the flat, west and east of the field, so the ground
	-- glows somewhere other than up the mountain.
	for _, at in ipairs({
		{ TERRACE_X + 30, TERRACE_Z + 30 },
		{ CX + FIELD_HALF + 140, ICZ - 20 },
	}) do
		local y = groundY(at[1], at[2], GROUND)
		prop("lavaPool", props, CFrame.new(at[1], y + 0.9, at[2]), 15, at[1])
	end

	--[[
		RIPPLES AND FOOTPRINTS -- the brief's "subtle natural sand ripples and
		footprints", and the only decoration on this island that has to be told where
		NOT to go rather than where to go.

		Not one of them may fall inside the rakeable square: the crust layer already
		owns that surface and a ripple standing on it would be a bump the sifter
		cannot cut. So they go on the black sand OUTSIDE the field, which on this
		island is most of it -- the plateau is 960 studs across and the square is 320
		of them.

		The footprints are laid in pairs of trails that all point roughly at the camp,
		because that is where everybody on this island has walked from.
	]]
	local ripples, trails = 0, 0
	for _ = 1, 500 do
		if ripples >= 26 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(180 + GROW, 450 + GROW)
		local x, z = CX + math.cos(a) * d, ICZ + math.sin(a) * d
		if openGround(x, z, 26) and spaced(x, z, 22) and not onTerrace(x, z, 10) then
			local y = groundY(x, z, GROUND)
			if math.abs(y - GROUND) < 1.2 then
				if prop("sandRipples", props,
					CFrame.new(x, y, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
					rng:NextNumber(26, 46), 9, PALETTE.basalt, ripples) then
					ripples += 1
					claim(x, z, 22)
				end
			end
		end
	end
	for _ = 1, 300 do
		if trails >= 7 then
			break
		end
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(210 + GROW, 400 + GROW)
		local x, z = CX + math.cos(a) * d, ICZ + math.sin(a) * d
		local toward = (Vector3.new(CX, 0, CAMP_Z1) - Vector3.new(x, 0, z))
		if toward.Magnitude > 60 and openGround(x, z, 16) then
			local dir = toward.Unit
			local b = Vector3.new(x, 0, z) + dir * 46
			if openGround(b.X, b.Z, 16) then
				local ya = groundY(x, z, GROUND)
				local yb = groundY(b.X, b.Z, GROUND)
				if math.abs(ya - GROUND) < 0.9 and math.abs(yb - GROUND) < 0.9 then
					if prop("footprints", props, Vector3.new(x, ya + 0.08, z),
						Vector3.new(b.X, yb + 0.08, b.Z), 14, PALETTE.basalt, trails) then
						trails += 1
					end
				end
			end
		end
	end

	----------------------------------------------------------------
	-- Final sweeps
	----------------------------------------------------------------
	local unanchored, shadowsOff, intruders, partCount, lightCount = finalSweeps(root)
	if unanchored > 0 then
		warn(string.format("[Ashfall] anchored %d part(s) that arrived loose from Island4Props",
			unanchored))
	end

	print(string.format(
		"[Ashfall] island built: %d mounds, %d sea stacks, %d rock formations, %d tide rocks, "
		.. "%d burnt trees, %d low props, %d vents, %d sulphur crusts, %d column clusters, %d cairns, "
		.. "%d ripple patches, %d footprint trails, "
		.. "%d lava plates; %d torches; %d litter pieces; %d prop failures, %d field intruders",
		mounds, stacks, formations, tideRocks, palms, low, vents, crusts, columns, cairns,
		ripples, trails, plates,
		campTorches + stairTorches, litterCount, propFails, intruders))
	print(string.format("[Ashfall] cost: %d parts, %d lights, %d shadow casters trimmed; "
		.. "summit y=%.0f, crater floor y=%.0f", partCount, lightCount, shadowsOff, RIM_Y, CRATER_FLOOR))

	return sellPad
end

return Island4
