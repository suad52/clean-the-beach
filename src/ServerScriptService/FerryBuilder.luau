--[[
	FerryBuilder  --  ServerScriptService.FerryBuilder  (ModuleScript)

	THE BERTHS. A pier, a boat moored off the end of it, and the man standing on
	the deck in front of the boat -- one set per island, built from primitives
	the same way every other structure in this game is.

	PURE GEOMETRY. Nothing in here knows what a requirement is, who is allowed
	to sail, or that a ProximityPrompt exists. FerryServer places these, hangs
	the prompt on the anchor this hands back, and owns every decision. Splitting
	it that way is what lets the boats be rebuilt or restyled without touching a
	line of the travel rules -- the same split AtvBuilder and AtvServer keep.

	THE PLANKS AND THE BOAT COME OUT OF THE TOOLBOX. Both were hand-built here
	from primitives to start with, and the boat especially -- nine tapered hull
	slices with a sheer curve on them -- was a good deal of arithmetic to end up
	with something that still read as a box with a point on it at any distance.
	Two Creator Store models replace all of it:

	  the pier    135140381930731, used as a KIT rather than a model. It is
	              sixty-four copies of one hand-laid wavy plank mesh and a
	              tally of posts, so a berth lays as many planks as its own
	              shoreline needs instead of being stuck with the L-shaped run
	              the model happens to be.
	  the boat    12020038826, a two-mesh wooden sailing boat. Scaled to 0.46
	              (32 studs bow to stern), floated with its keel 1.35 under the
	              waterline, and painted per berth.

	NEITHER IS CLONED FROM THE MARKETPLACE AT RUNTIME. Both are stripped of
	every script, GUI and camera the uploads carried and kept in
	ServerStorage.FerryAssets, which this file clones out of. A toolbox model
	dropped straight into a running game is somebody else's code executing in
	yours: the plank model shipped three scripts, and the other pier measured
	for this job shipped seven of them plus a "validation" ScreenGui.

	AND IT ALL STILL WORKS WITHOUT THEM. If the folder is missing -- a place
	file restored from before it existed, an asset that failed to save -- every
	clone call answers nil and the berth falls back to plain boxes in the same
	skin. A ferry you can still sail on beats a berth that failed to build.

	WHAT COMES BACK
	---------------
	build(port, deckY) returns a Model plus a table of handles:

	  talkAnchor  an invisible part at the ferryman's chest. FerryServer puts
	              the prompt here rather than on his torso so the prompt's reach
	              is a property of the BERTH and does not change if he is ever
	              restyled thinner.
	  boat        the boat Model, with a Root at its waterline centre
	  man         the ferryman Model, with a Root at his feet
	  deckY       the pier deck's top surface, for the arrival CFrame
	  riderOffset where a passenger stands, in the boat's OWN frame. FerryServer
	              drives the player off this every frame of a crossing, so the
	              one place that knows where the deck is is the file that built
	              it.
	  lines       the two mooring lines, so the crossing can drop them

	Both Roots exist for FerryClient, which idles the boat on the swell and
	breathes the man -- the camel's trick: capture each part's offset from the
	Root once, then drive the whole model off one CFrame per frame, locally, so
	nothing about the motion costs bandwidth or replicates.

	THREE RULES THIS FILE INHERITS FROM THE ISLANDS IT STANDS ON
	-----------------------------------------------------------
	  * No part may use Enum.Material.Ground or Enum.Material.Asphalt. Those are
	    Sakura Cove's terrain pair and CTB_Server tints them globally; they are
	    spoken for place-wide. (Island3Builder's header records this.)
	  * Part Sandstone renders mauve-grey under this place's sky whatever colour
	    it is painted -- Island2Builder measured it and converts its whole
	    pyramid to Concrete at the end of its build. Nothing here uses Sandstone,
	    because that sweep only covers workspace.Island2 and these berths live in
	    a folder of their own.
	  * Neon above Transparency 0 renders near-black under Future lighting. Every
	    lantern here is solid Neon with a PointLight beside it, never a
	    translucent one.
]]

local FerryBuilder = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local SignKit = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("SignKit"))
-- For the mooring alone: where she lies and which way her bow points. Those two
-- are read by the crossing as well as by the build, so they live with the rest
-- of the berth's survey rather than being worked out twice.
local FerryConfig = require(ReplicatedStorage:WaitForChild("FerryConfig"))
local GameConfig = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("GameConfig"))

----------------------------------------------------------------
-- THE TOOLBOX KIT
----------------------------------------------------------------
-- Resolved once, warned about once, and never assumed. Every caller below
-- checks for nil and draws a box instead -- see the header.
local assets = ServerStorage:FindFirstChild("FerryAssets")
if not assets then
	warn("[Ferry] ServerStorage.FerryAssets is missing -- the berths will be "
		.. "built from plain boxes. See the header of FerryBuilder.")
end

local function kit(name: string): Instance?
	local src = assets and assets:FindFirstChild(name)
	return src and src:Clone() or nil
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
	p.Color = colour or Color3.fromRGB(200, 200, 200)
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

-- Axis-aligned box from world bounds, exactly as the island builders take it: a
-- pier is a run of rectangles that has to line up with a shoreline sixty studs
-- away, and bounds are far easier to keep honest than centre+size.
local function box(parent, name, x0, x1, y0, y1, z0, z1, colour, material, extra)
	if x1 - x0 < 0.05 or y1 - y0 < 0.05 or z1 - z0 < 0.05 then
		return nil
	end
	return P(parent, name,
		Vector3.new(x1 - x0, y1 - y0, z1 - z0),
		CFrame.new((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5),
		colour, material, extra)
end

-- A part placed in some base frame's LOCAL space. Everything about a boat or a
-- man is described relative to its own origin, so the whole thing can be moved
-- or turned by changing one CFrame instead of two hundred numbers.
local function lp(parent, name, base, size, offset, colour, material, extra)
	return P(parent, name, size, base * offset, colour, material, extra)
end

-- A cylinder standing on its END. A Part cylinder's axis runs along its LOCAL
-- X, so every upright one in this file is turned a quarter turn about Z --
-- written once here because getting it wrong lays a hat brim on its side.
local function upright(parent, name, base, height, diameter, offset, colour, material, extra)
	local props = { Shape = Enum.PartType.Cylinder }
	if extra then
		for k, v in pairs(extra) do
			props[k] = v
		end
	end
	return lp(parent, name, base, Vector3.new(height, diameter, diameter),
		offset * CFrame.Angles(0, 0, math.pi * 0.5), colour, material, props)
end

-- A straight run between two world points: ropes, gangways, oars, spars. The
-- part's Z axis is aligned to the line, which is what CFrame.lookAt gives -- a
-- box is symmetric about that axis, so which end it looks at never matters.
local function span(parent, name, a: Vector3, b: Vector3, w: number, h: number,
	colour, material, extra)
	local d = (b - a).Magnitude
	if d < 0.1 then
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
-- SKINS
----------------------------------------------------------------
--[[
	One palette per berth, and every one is borrowed from the island it stands
	on rather than invented here. That is the whole reason three boats built by
	one hull function read as three different places: the shapes differ a little
	and the paint differs completely.

	  Beach   the beachfront shacks' cream and sea, over the warm timber the
	          wash bay and the sell shop are built from
	  Dunes   Island2Builder's STONE / GOLD / LAPIS / TURQUOISE, exactly
	  Cove    Island3Builder's cream / blossom / vermilion / plum, exactly
	  Ashfall Island4Props' basalt / ash / ember / iron, exactly

	ASHFALL IS THE ONE DARK SKIN AND IT INVERTS THE HULL RULE. The other three
	paint the hull a near-white so she reads against her own sea; on black sand
	under a black mountain a white hull is the only bright thing for four hundred
	studs and the boat stops being scenery and becomes the subject. Hers is the
	island's pale ash instead, with the EMBER on the boot line and the trim, which
	is the one colour out there that means heat.
]]
local SKINS = {
	Beach = {
		deck = Color3.fromRGB(198, 152, 96),
		deckDark = Color3.fromRGB(138, 98, 58),
		post = Color3.fromRGB(120, 84, 50),
		rope = Color3.fromRGB(226, 198, 148),
		hull = Color3.fromRGB(255, 250, 238),
		boot = Color3.fromRGB(64, 168, 240),
		trim = Color3.fromRGB(94, 226, 196),
		accent = Color3.fromRGB(255, 118, 104),
		metal = Color3.fromRGB(214, 216, 220),
		iron = Color3.fromRGB(122, 130, 140),
		glow = Color3.fromRGB(255, 226, 168),
		board = Color3.fromRGB(255, 250, 238),
	},
	Dunes = {
		deck = Color3.fromRGB(224, 176, 106),
		deckDark = Color3.fromRGB(176, 128, 72),
		post = Color3.fromRGB(160, 114, 64),
		rope = Color3.fromRGB(206, 172, 104),
		hull = Color3.fromRGB(206, 172, 104),
		boot = Color3.fromRGB(40, 78, 150),
		trim = Color3.fromRGB(240, 194, 82),
		accent = Color3.fromRGB(60, 168, 158),
		metal = Color3.fromRGB(240, 194, 82),
		iron = Color3.fromRGB(150, 112, 68),
		glow = Color3.fromRGB(255, 214, 140),
		board = Color3.fromRGB(242, 210, 148),
	},
	Cove = {
		deck = Color3.fromRGB(240, 208, 206),
		deckDark = Color3.fromRGB(196, 152, 158),
		post = Color3.fromRGB(172, 152, 164),
		rope = Color3.fromRGB(255, 246, 238),
		hull = Color3.fromRGB(255, 246, 238),
		boot = Color3.fromRGB(228, 78, 58),
		trim = Color3.fromRGB(228, 78, 58),
		accent = Color3.fromRGB(104, 206, 208),
		metal = Color3.fromRGB(66, 42, 62),
		iron = Color3.fromRGB(96, 82, 92),
		glow = Color3.fromRGB(255, 196, 148),
		board = Color3.fromRGB(255, 246, 238),
	},
	Ashfall = {
		deck = Color3.fromRGB(104, 76, 54),
		deckDark = Color3.fromRGB(72, 52, 38),
		post = Color3.fromRGB(74, 68, 76),
		rope = Color3.fromRGB(172, 144, 100),
		hull = Color3.fromRGB(196, 190, 186),
		boot = Color3.fromRGB(198, 56, 24),
		trim = Color3.fromRGB(255, 122, 42),
		accent = Color3.fromRGB(226, 198, 84),
		metal = Color3.fromRGB(150, 144, 144),
		iron = Color3.fromRGB(84, 84, 92),
		glow = Color3.fromRGB(255, 198, 108),
		board = Color3.fromRGB(196, 190, 186),
	},
	-- Penguin Island: a timber berth on the pack ice, and the vessel is a red
	-- sleigh with gold trim -- hull/boot are the sleigh's own colours and trim
	-- is the island's ice blue.
	Penguin = {
		deck = Color3.fromRGB(142, 104, 70),
		deckDark = Color3.fromRGB(92, 66, 44),
		post = Color3.fromRGB(84, 58, 38),
		rope = Color3.fromRGB(196, 168, 118),
		hull = Color3.fromRGB(196, 44, 48),
		boot = Color3.fromRGB(236, 196, 84),
		trim = Color3.fromRGB(150, 226, 255),
		accent = Color3.fromRGB(46, 128, 84),
		metal = Color3.fromRGB(214, 216, 220),
		iron = Color3.fromRGB(70, 74, 82),
		glow = Color3.fromRGB(255, 214, 140),
		board = Color3.fromRGB(226, 232, 240),
	},
}

----------------------------------------------------------------
-- THE PIER
----------------------------------------------------------------
--[[
	Deck, planking, pilings, a rail down both sides and a signed arch at the
	landward end. It steps up in two 0.45-stud lips off the sand rather than
	starting flush: a pier deck level with the beach reads as a path somebody
	painted, and 0.9 studs is well inside a character's step height so it costs
	nothing to walk onto.

	THE HEAD IS LEFT OPEN. Rails stop seven studs short of the seaward end,
	which is where the gangway goes -- a railed-off pier head would put a fence
	between the player and the one thing the pier is for.

	THE PLANKING IS THE TOOLBOX KIT, LAID BY HAND. One wavy plank mesh, 2.5
	studs along the run by 13.5 across, dropped every 2.0 -- so each one
	overlaps its neighbour and the deck gets a ragged edge no box can have. A
	little jitter in height and in yaw on top of that, off a seeded Random so
	the same berth comes out the same every boot.

	NONE OF THE PLANKS COLLIDE. A wavy mesh underfoot is a wavy mesh to walk
	on, and sixty of them in a row is a player catching their toe every second
	stud. One invisible flat slab sits flush with their tops and takes all of
	it; the planks are paint.
]]
local HALF_W = 6.75                    -- deck half-width: the plank kit's own
local RAIL_H = 2.9
local PLANK_STEP = 2.0                 -- how far apart they are laid
local PLANK_RISE = 1.0                 -- plank centre to its walking surface

local function buildPier(parent, port, skin, deckY: number)
	local m = Instance.new("Model")
	m.Name = "Pier"
	m.Parent = parent

	local x = port.dock.x
	local landZ, seaZ = port.dock.landZ, port.dock.seaZ
	local dir = (seaZ < landZ) and -1 or 1        -- along Z, toward the water
	local z0, z1 = math.min(landZ, seaZ), math.max(landZ, seaZ)

	-- Seeded off the berth's own X so the three piers are laid differently from
	-- each other and identically to themselves on every boot.
	local rng = Random.new(math.floor(port.dock.x) * 7919 + port.id)

	-- What is actually walked on. Invisible, flush with the plank tops, and the
	-- only collidable thing in the deck.
	box(m, "DeckPlate", x - HALF_W, x + HALF_W, deckY - 0.5, deckY, z0, z1,
		skin.deck, Enum.Material.WoodPlanks, { Transparency = 1, CastShadow = false })

	local laid = 0
	local pz = z0 + 1.1
	while pz < z1 - 0.4 do
		local plank = kit("Plank")
		if not plank then
			break
		end
		plank.Name = "Plank"
		plank.Color = skin.deck
		plank.CanCollide = false
		plank.CanQuery = false
		plank.CanTouch = false
		plank.CFrame = CFrame.new(x, deckY - PLANK_RISE + (rng:NextNumber() - 0.5) * 0.14, pz)
			* CFrame.Angles(0, math.pi * 0.5 + (rng:NextNumber() - 0.5) * 0.13, 0)
		plank.Parent = m
		laid += 1
		pz += PLANK_STEP
	end

	-- The fallback, and the reason a missing FerryAssets is a shrug rather than
	-- a hole in the world: no kit, so the deck is simply visible.
	if laid == 0 then
		local plate = m:FindFirstChild("DeckPlate")
		if plate then
			plate.Transparency = 0
		end
	end

	-- The step up off the sand, landward of the deck.
	local stepOuter = landZ - dir * 2.4
	box(m, "Step", x - 6, x + 6, deckY - 1.0, deckY - 0.5,
		math.min(landZ, stepOuter), math.max(landZ, stepOuter),
		skin.deckDark, Enum.Material.WoodPlanks)

	-- Pilings, run to y = -16. That is under the seabed on every berth -- the
	-- beach's is at -5, the dunes' at -4 and the cove's bay floor at -2 -- so
	-- the landward ones are simply buried in the sand they stand in rather than
	-- being cut to length island by island.
	local pilingTop = deckY - 0.55
	local pz2 = z0 + 3
	while pz2 < z1 do
		for _, s in ipairs({ -1, 1 }) do
			local post = kit("Post")
			if post then
				post.Name = "Piling"
				post.Color = skin.post
				post.Size = Vector3.new(1.5, pilingTop + 16, 1.0)
				post.CFrame = CFrame.new(x + s * 5.9, (pilingTop - 16) * 0.5, pz2)
					* CFrame.Angles(0, (rng:NextNumber() - 0.5) * 0.2, 0)
				post.Parent = m
			else
				box(m, "Piling", x + s * 5.9 - 0.75, x + s * 5.9 + 0.75, -16, pilingTop,
					pz2 - 0.75, pz2 + 0.75, skin.post, Enum.Material.Wood)
			end
		end
		pz2 += 8
	end

	-- Rail: posts, a top bar and a rope slung between. Stops short of the head.
	local railEnd = seaZ - dir * 7
	local r0, r1 = math.min(railEnd, landZ), math.max(railEnd, landZ)
	local rz = r0
	while rz <= r1 + 0.01 do
		for _, s in ipairs({ -1, 1 }) do
			box(m, "RailPost", x + s * 6.5 - 0.26, x + s * 6.5 + 0.26, deckY, deckY + RAIL_H,
				rz - 0.26, rz + 0.26, skin.post, Enum.Material.Wood)
		end
		rz += 5.5
	end
	for _, s in ipairs({ -1, 1 }) do
		box(m, "RailTop", x + s * 6.5 - 0.34, x + s * 6.5 + 0.34,
			deckY + RAIL_H - 0.3, deckY + RAIL_H, r0 - 0.3, r1 + 0.3,
			skin.post, Enum.Material.Wood)
		box(m, "RailRope", x + s * 6.5 - 0.16, x + s * 6.5 + 0.16,
			deckY + 1.35, deckY + 1.62, r0, r1, skin.rope, Enum.Material.Fabric,
			{ CanCollide = false })
	end

	--[[
		Bollards: the pair at the head, and one more thirteen studs inboard on
		the side the boat lies.

		The third one is not decoration. She is moored ALONGSIDE now rather than
		across the end of the pier, and a boat lying alongside is held by a
		spring line forward and a stern line aft -- two lines running to two
		points thirteen studs apart. Run off a single pair side by side across
		the head, as they were when she lay across it, both lines came out
		parallel and the whole thing read as a boat on a leash.

		IRON, not skin.metal. On the beach that key is the near-white the lamp
		hoods use, and white posts on a pale deck read as bins somebody left at
		the end of the pier rather than as mooring bitts.
	]]
	local bollardZ = seaZ - dir * 2.4
	local side = ((port.dock.boatX or 13) >= 0) and 1 or -1

	local function bollard(bx: number, bz: number): Vector3
		box(m, "Bollard", bx - 0.5, bx + 0.5, deckY, deckY + 1.5, bz - 0.5, bz + 0.5,
			skin.iron, Enum.Material.Metal)
		box(m, "BollardCap", bx - 0.72, bx + 0.72, deckY + 1.5, deckY + 1.78,
			bz - 0.72, bz + 0.72, skin.iron, Enum.Material.Metal, { CanCollide = false })
		return Vector3.new(bx, deckY + 1.3, bz)
	end

	local moorings = {}
	for _, s in ipairs({ -1, 1 }) do
		local p = bollard(x + s * 4.2, bollardZ)
		if s == side then
			moorings[1] = p
		end
	end
	moorings[2] = bollard(x + side * 4.2, bollardZ - dir * 13)

	-- A lamp at each end, on OPPOSITE sides, so the deck is lit down its length
	-- rather than down one edge. Inboard of the rail posts at +-6.5 so the two
	-- never occupy the same stud.
	local function lamp(lx: number, lz: number)
		box(m, "LampPost", lx - 0.3, lx + 0.3, deckY, deckY + 5.0, lz - 0.3, lz + 0.3,
			skin.post, Enum.Material.Wood)
		local bulb = box(m, "LampGlass", lx - 0.62, lx + 0.62, deckY + 5.0, deckY + 5.9,
			lz - 0.62, lz + 0.62, skin.glow, Enum.Material.Neon, { CanCollide = false })
		box(m, "LampHood", lx - 0.9, lx + 0.9, deckY + 5.9, deckY + 6.3,
			lz - 0.9, lz + 0.9, skin.metal, Enum.Material.Metal, { CanCollide = false })
		if bulb then
			light(bulb, skin.glow, 34, 1.1)
		end
	end
	lamp(x + 5.6, seaZ - dir * 9)
	lamp(x - 5.6, landZ + dir * 9)

	--[[
		THE ARCH, at the landward end, carrying the board.

		Its posts stand OUTSIDE the deck (x +- 8.4 against a half-width of 7) so
		all fourteen studs of walking surface stay clear. An arch a player has to
		squeeze through is the sort of thing that only shows up once somebody is
		running for the boat with a full bag.

		Signed on BOTH faces through SignKit, like every other board in the game:
		a thin board has two readable sides and signing one is a coin flip you
		lose half the time. The wash bay's own board records losing it.
	]]
	local archZ = landZ + dir * 1.6
	for _, s in ipairs({ -1, 1 }) do
		box(m, "ArchPost", x + s * 8.4 - 0.55, x + s * 8.4 + 0.55, deckY - 1.6, deckY + 9.4,
			archZ - 0.55, archZ + 0.55, skin.post, Enum.Material.Wood)
	end
	box(m, "ArchBeam", x - 9.2, x + 9.2, deckY + 9.4, deckY + 10.1, archZ - 0.6, archZ + 0.6,
		skin.post, Enum.Material.Wood)
	local board = box(m, "SignBoard", x - 8, x + 8, deckY + 5.6, deckY + 9.2,
		archZ - 0.26, archZ + 0.26, skin.board, Enum.Material.WoodPlanks,
		{ CanCollide = false })
	if board then
		SignKit.dress(board, port.sign, { Enum.NormalId.Front, Enum.NormalId.Back })
	end

	return m, moorings, dir, side
end

----------------------------------------------------------------
-- THE BOAT
----------------------------------------------------------------
--[[
	ONE BOAT, THREE PAINT JOBS.

	She is a Creator Store model -- a wooden sailing boat in two meshes, a hull
	and a sail -- kept stripped and pre-scaled in ServerStorage.FerryAssets and
	cloned per berth. What used to stand here was three hand-built hulls
	sharing a nine-slice generator with a sheer curve and tapered end caps, and
	the honest reading of it was that no amount of arithmetic makes forty boxes
	look like a boat.

	THE PAINT IS WHAT MAKES THREE OF THEM. The hull takes the berth's timber
	and the SAIL takes its accent, which is deliberate rather than tidy: the
	sail is the only part of her that reads from the far end of an island, so
	it is the part that has to say which island she belongs to.

	HOW SHE IS BUILT. Every number about her that another file could want is
	measured here and nowhere else:

	  * Root sits at her waterline centre and is her PrimaryPart, so one
	    PivotTo moves the whole boat -- which is what the crossing drives and
	    what FerryClient's swell rides on.
	  * her LENGTH runs along local X, and her BOW IS LOCAL -X. She is a
	    double-ender, so the hull does not settle it either way; the steering
	    oar on the +X quarter and the sail set forward of the mast at x = -2.66
	    both do. FerryConfig.heading is what turns that onto a berth's seaward
	    axis, and FerryConfig.headingIn turns her round to come back in.
	  * THE HULL MESH DOES NOT COLLIDE. Its collision would be whatever the
	    convex decomposition of a wavy hull happens to come out as, which is
	    not a thing to stand a player on. One flat invisible Deck part does
	    that job and is the only collidable thing aboard.
]]
local BOAT_LEN = 32.1                  -- bow to stern
local BOAT_BEAM = 9.2                  -- at her widest
local BOAT_DECK = 1.09                 -- the deck sole, above the waterline

--[[
	Where a passenger stands, in the boat's OWN frame: amidships, a little
	forward of the mast, FACING THE BOW.

	Both halves of that were wrong and they were wrong together. She was being
	sailed stern-first (see FerryConfig.heading), and this offset turned the
	rider to match -- so a player boarded looking backwards down a boat that was
	itself going backwards, and the two errors cancelled into something that
	merely felt odd rather than obviously broken. Now the bow leads and he looks
	over it.

	The quarter turn is there because she is built with her length along local X
	while a character faces along its own -Z: a yaw of +pi/2 puts a LookVector of
	(-1, 0, 0) on him, which is her bow.
]]
local RIDER = CFrame.new(-2.4, BOAT_DECK + 3.0, 0) * CFrame.Angles(0, math.pi * 0.5, 0)

-- Where the boatman stands: aft, at the tiller, out of the walking lane down
-- the middle of the deck. Turned toward the bow and canted in toward the pier
-- so that a player walking up to talk to him is not addressing his shoulder --
-- see the yaw derivation in FerryBuilder.build.
local CREW_X = 5.6

--[[
	HER WAKE, off the stern at the waterline. Off until she is moving.

	ENABLED RATHER THAN EMITTED, and that is a hard constraint rather than a
	preference: ParticleEmitter:Emit() called on the SERVER does not replicate
	(FeedbackClient's header records finding this out), so a server-side burst
	is a burst nobody sees. Toggling `Enabled` is an ordinary property change
	and reaches every client that has her streamed in -- which matters, because
	a ferry leaving is something the people left on the pier should get to
	watch.

	Slow particles from a fast boat. The foam is meant to be left BEHIND her, so
	it barely moves on its own and she drives away from it; give it speed of its
	own and it chases her instead, which reads as an outboard rather than a hull
	pushing water.
]]
local function addWake(boat: Model, at: CFrame)
	local p = P(boat, "Wake", Vector3.new(1.4, 0.4, BOAT_BEAM * 0.8), at,
		Color3.new(1, 1, 1), Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false,
			CastShadow = false })

	local e = Instance.new("ParticleEmitter")
	e.Name = "Foam"
	e.Texture = GameConfig.Textures.Smoke
	e.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(198, 226, 236))
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(0.45, 2.6),
		NumberSequenceKeypoint.new(1, 3.4),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(0.6, 0.7),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Lifetime = NumberRange.new(0.7, 1.4)
	e.Speed = NumberRange.new(0.4, 2)
	e.SpreadAngle = Vector2.new(28, 12)
	e.Acceleration = Vector3.new(0, -1.5, 0)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-24, 24)
	e.Rate = 34
	e.LightEmission = 0.35
	e.Enabled = false
	e.Parent = p
	return p
end

--[[
	SPRAY OFF THE BOW, and it is the difference between a boat travelling and a
	boat FIGHTING.

	The wake is what she leaves behind; this is what she throws up when she puts
	her nose into something. It is off by default and FerryServer turns it on for
	the two rough beats of a crossing only -- and hard against the two calm ones,
	because spray coming off a boat sliding out of a sheltered harbour is spray
	that means nothing.

	Fast, upward and OUTWARD, which is the opposite of the wake's arrangement and
	for the opposite reason: this is water being hit rather than water being left,
	so it has to visibly leave her rather than hang.
]]
local function addSpray(boat: Model, at: CFrame)
	local p = P(boat, "Spray", Vector3.new(1.6, 0.6, BOAT_BEAM * 0.7), at,
		Color3.new(1, 1, 1), Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false,
			CastShadow = false })

	local e = Instance.new("ParticleEmitter")
	e.Name = "Burst"
	e.Texture = GameConfig.Textures.Smoke
	e.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(214, 238, 246))
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(0.35, 3.2),
		NumberSequenceKeypoint.new(1, 5.2),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.5, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Lifetime = NumberRange.new(0.5, 1.1)
	e.Speed = NumberRange.new(14, 26)
	e.SpreadAngle = Vector2.new(46, 34)
	e.Acceleration = Vector3.new(0, -46, 0)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-60, 60)
	e.Rate = 70
	e.LightEmission = 0.6
	-- Up and over the bow, in the boat's own frame: EmissionDirection is a face
	-- of the anchor part, and Top is the one pointing at the sky on a part that
	-- lies flat across her stem.
	e.EmissionDirection = Enum.NormalId.Top
	e.Enabled = false
	e.Parent = p
	return p
end

local function buildBoat(parent, port, skin, moorCF: CFrame)
	-- A port may name its own kit (Penguin Island's sleigh); the boat is the
	-- default and the only one most berths will ever use.
	local m = kit((port.boat and port.boat.kit) or "FerryBoat")

	if m then
		m.Name = "Boat"
		local hull = m:FindFirstChild("Hull")
		if hull then
			hull.Color = skin.hull
		end
		local sail = m:FindFirstChild("Sail")
		if sail then
			sail.Color = skin.trim
		end
		m.Parent = parent
		m:PivotTo(moorCF)
		-- After the pivot, in her final frame -- P takes a WORLD CFrame. Wake at
		-- the stern (+X), spray at the bow (-X); getting those the wrong way
		-- round gives a boat that foams where it is going and splashes where it
		-- has been.
		addWake(m, moorCF * CFrame.new(BOAT_LEN * 0.46, 0.1, 0))
		addSpray(m, moorCF * CFrame.new(-BOAT_LEN * 0.44, 0.55, 0))
		return m
	end

	-- No kit: a punt, in the right paint, moored in the right place. Enough
	-- that a crossing still has something to leave on. See the file header.
	m = Instance.new("Model")
	m.Name = "Boat"
	m.Parent = parent

	local root = lp(m, "Root", moorCF, Vector3.new(1, 1, 1), CFrame.new(),
		skin.hull, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false,
			CastShadow = false })
	m.PrimaryPart = root

	lp(m, "Hull", moorCF, Vector3.new(BOAT_LEN, 2.6, BOAT_BEAM),
		CFrame.new(0, BOAT_DECK - 1.3, 0), skin.hull, Enum.Material.WoodPlanks,
		{ CanCollide = false })
	lp(m, "Bulwark", moorCF, Vector3.new(BOAT_LEN - 3, 1.1, BOAT_BEAM + 0.4),
		CFrame.new(0, BOAT_DECK + 0.55, 0), skin.boot, Enum.Material.WoodPlanks,
		{ CanCollide = false })
	lp(m, "Deck", moorCF, Vector3.new(BOAT_LEN - 6, 0.4, BOAT_BEAM - 1.6),
		CFrame.new(0, BOAT_DECK - 0.2, 0), skin.deck, Enum.Material.WoodPlanks)
	lp(m, "Mast", moorCF, Vector3.new(0.5, 14, 0.5),
		CFrame.new(-2.6, BOAT_DECK + 7, 0), skin.post, Enum.Material.Wood,
		{ CanCollide = false })
	lp(m, "Sail", moorCF, Vector3.new(0.3, 9, 7),
		CFrame.new(-3.1, BOAT_DECK + 6, 0), skin.trim, Enum.Material.Fabric,
		{ CanCollide = false })
	addWake(m, moorCF * CFrame.new(BOAT_LEN * 0.46, 0.1, 0))
	addSpray(m, moorCF * CFrame.new(-BOAT_LEN * 0.44, 0.55, 0))

	return m
end

----------------------------------------------------------------
-- THE FERRYMAN
----------------------------------------------------------------
--[[
	A REAL ROBLOX AVATAR, and not a stack of boxes.

	What stood here was a hand-built figure -- ten Parts and a per-island
	costume -- and the honest reading of it was the same one the boat got
	before it: no amount of arithmetic makes a dozen boxes look like a person.
	He is an R15 character now, built by CreateHumanoidModelFromDescription,
	wearing genuine catalogue hair, with a real head mesh and a real face.

	WHY NOT A FREE MODEL OFF THE STORE. That was tried first, across four
	searches. The store's free NPCs are almost without exception fan rigs of
	other people's characters or meme heads, and none of it was usable here. A
	HumanoidDescription is the same marketplace by another door: the hair is a
	catalogue accessory by asset id -- all three are Roblox's own, so none of
	them can go off-sale out from under this file -- and the body is Roblox's.

	EVERY PART IS ANCHORED, AND THE POSE IS BAKED IN.

	These rigs are the new constraint kind (AnimationConstraint and
	BallSocketConstraint, not Motor6D), so a pose is normally something the
	physics solver arrives at. That is no use here: the boat is driven by
	PivotTo at 60 Hz during a crossing, and an unanchored crew trails a frame
	behind it and swings. `bend` therefore walks the arm chains by hand, about
	the rig's own shoulder and elbow attachments, and then the whole man is
	anchored. It costs a static pose and buys a man who does not come apart on
	a boat that is being thrown around.

	He is not still, though. He lives INSIDE the boat model, so FerryClient's
	swell rides him with the deck he is standing on -- and during a crossing
	the sea state written by FerryServer pitches him with her. A separate
	"Ferryman" rig in that file is gone with this; the boat carries him.

	THE ACCESSORY WELD HAS TO BE RESOLVED BY HAND, for the same reason. An
	AccessoryWeld is a Weld, welds are solved by the physics engine, and an
	anchored part is never solved -- so hair on an anchored rig stays exactly
	where the model was assembled, which is the world origin. `snapAccessories`
	does the one line of arithmetic the engine would have done, and the whole
	man is assembled AT the origin so that line is the only one that has to be
	right.

	ONLY THE DECK COLLIDES. Every part of him is CanCollide = false, which is a
	change from the box man -- he stood on a pier and being solid was fine
	there. He now stands on a boat that moves under a player, and a solid
	obstacle on a moving deck is a thing that shoves people into the sea.
]]
local Players = game:GetService("Players")

--[[
	WHAT EACH OF THE THREE LOOKS LIKE.

	Body colour is doing the work clothing normally would: torso is his shirt,
	legs are his trousers, and both are taken off the berth's own palette so
	the man agrees with the boat he is standing in. Roblox's free catalogue has
	no linen tunic, no galabeya and no hakama in it, so a shirt texture would
	have put all three of them in the same plaid.
]]
local LOOKS = {
	beach = {
		hair = "63690008",                 -- Pal Hair
		skin = Color3.fromRGB(226, 172, 128),
		shirt = Color3.fromRGB(255, 250, 238),
		legs = Color3.fromRGB(76, 104, 138),
	},
	dunes = {
		hair = "7193454569",               -- Braided Hair - Black
		skin = Color3.fromRGB(178, 122, 78),
		shirt = Color3.fromRGB(242, 210, 148),
		legs = Color3.fromRGB(226, 190, 132),
	},
	cove = {
		hair = "62234425",                 -- Brown Hair
		skin = Color3.fromRGB(238, 206, 186),
		shirt = Color3.fromRGB(255, 246, 238),
		legs = Color3.fromRGB(66, 42, 62),
	},
	ashfall = {
		hair = "7193454569",               -- Braided Hair - Black
		skin = Color3.fromRGB(168, 116, 84),
		shirt = Color3.fromRGB(198, 56, 24),
		legs = Color3.fromRGB(74, 68, 76),
	},
	-- The fifth man drives a sleigh, wears red, and is who you think he is.
	-- The beard is built with the hat (santaHat): the catalogue's free hair
	-- has no beard in it.
	santa = {
		hair = "63690008",                 -- Pal Hair, under the hat
		skin = Color3.fromRGB(238, 206, 186),
		shirt = Color3.fromRGB(196, 44, 48),
		legs = Color3.fromRGB(150, 30, 34),
	},
}

local function snapAccessories(m: Model)
	for _, acc in ipairs(m:GetChildren()) do
		if acc:IsA("Accessory") then
			local h = acc:FindFirstChild("Handle")
			local w = h and h:FindFirstChildOfClass("Weld")
			if h and h:IsA("BasePart") and w and w.Part0 and w.Part1 then
				-- Part0.CFrame * C0 == Part1.CFrame * C1, and Part0 is the Handle.
				h.CFrame = w.Part1.CFrame * w.C1 * w.C0:Inverse()
			end
		end
	end
end

-- Turn a chain of parts about one of the rig's own attachments, in the
-- CHARACTER's axes rather than the world's -- so the same numbers pose him
-- whichever way the berth has him facing.
local function bend(m: Model, hostName: string, attName: string, rot: CFrame, names: { string })
	local root = m:FindFirstChild("HumanoidRootPart")
	local host = m:FindFirstChild(hostName)
	local att = host and host:FindFirstChild(attName)
	if not (root and root:IsA("BasePart") and att and att:IsA("Attachment")) then
		return
	end
	local frame = CFrame.new(att.WorldPosition) * root.CFrame.Rotation
	local delta = frame * rot * frame:Inverse()
	for _, n in ipairs(names) do
		local p = m:FindFirstChild(n)
		if p and p:IsA("BasePart") then
			p.CFrame = delta * p.CFrame
		end
	end
end

local ARM_L = { "LeftUpperArm", "LeftLowerArm", "LeftHand" }
local ARM_R = { "RightUpperArm", "RightLowerArm", "RightHand" }
local FORE_L = { "LeftLowerArm", "LeftHand" }
local FORE_R = { "RightLowerArm", "RightHand" }

--[[
	THE STANCE: a man with a hand on a tiller.

	Shoulders 68 degrees out of the T is arms-at-rest; much past that and the
	upper arms start to pass through the ribs, much short of it and he is still
	presenting. The right arm then goes BACK rather than down, because he is
	steering with it and the tiller is behind him -- and that asymmetry is most
	of what stops the pose reading as a mannequin. The left keeps a little
	elbow so the two sides are not a mirror of each other.

	EVERY SIGN HERE IS DERIVED, NOT GUESSED, and the first pass had two of them
	backwards -- which came out as a scarecrow standing on the boat with its
	arms up and out. The rig is assembled at the identity CFrame, so `bend`'s
	frame is the world's and the character's at the same time, and the whole
	derivation is this: a character faces its own -Z, so its RIGHT arm hangs off
	+X and its LEFT off -X. Rotating about +Z carries +X toward +Y, so the right
	arm needs a NEGATIVE rotation to come down and the left a positive one.
	Rotating about +X carries -Y toward -Z, so a hanging arm needs a NEGATIVE
	rotation about X to swing BACK and a positive one to swing forward -- which
	is why the shoulder below is negative and the elbows, which fold a forearm
	forward, are positive.
]]
local function poseCrew(m: Model)
	bend(m, "UpperTorso", "RightShoulderRigAttachment", CFrame.Angles(0, 0, math.rad(-68)), ARM_R)
	bend(m, "UpperTorso", "LeftShoulderRigAttachment", CFrame.Angles(0, 0, math.rad(68)), ARM_L)
	bend(m, "UpperTorso", "RightShoulderRigAttachment", CFrame.Angles(math.rad(-26), 0, 0), ARM_R)
	bend(m, "RightUpperArm", "RightElbowRigAttachment", CFrame.Angles(math.rad(34), 0, 0), FORE_R)
	bend(m, "LeftUpperArm", "LeftElbowRigAttachment", CFrame.Angles(math.rad(16), 0, 0), FORE_L)
end

--[[
	THE ONE THING THE CATALOGUE COULD NOT GIVE HIM.

	Three hats, drawn from the head's OWN size rather than from constants, so a
	change of rig scale carries them with it. Everything here is CanCollide and
	CanQuery off: a hat is not an obstacle and it is not a click target.
]]
local NOHIT = { CanCollide = false, CanQuery = false, CanTouch = false }

local function strawHat(m, head: BasePart, skin)
	local base = head.CFrame
	local w, h = head.Size.X, head.Size.Y
	upright(m, "HatBrim", base, 0.18, w * 2.5, CFrame.new(0, h * 0.42, 0),
		Color3.fromRGB(236, 206, 140), Enum.Material.Fabric, NOHIT)
	upright(m, "HatCrown", base, h * 0.62, w * 1.16, CFrame.new(0, h * 0.72, 0),
		Color3.fromRGB(226, 192, 124), Enum.Material.Fabric, NOHIT)
	upright(m, "HatBand", base, 0.2, w * 1.2, CFrame.new(0, h * 0.5, 0),
		skin.accent, Enum.Material.Fabric, NOHIT)
end

local function nemes(m, head: BasePart, skin)
	local base = head.CFrame
	local w, h, d = head.Size.X, head.Size.Y, head.Size.Z
	-- the cloth over the crown and down the back of the neck
	lp(m, "Nemes", base, Vector3.new(w * 1.42, h * 0.86, d * 1.3),
		CFrame.new(0, h * 0.22, d * 0.16), skin.boot, Enum.Material.Fabric, NOHIT)
	lp(m, "NemesBand", base, Vector3.new(w * 1.48, h * 0.2, d * 1.34),
		CFrame.new(0, h * 0.56, d * 0.14), skin.trim, Enum.Material.Metal, NOHIT)
	-- the two lappets down the front. The character faces its own -Z.
	for _, s in ipairs({ -1, 1 }) do
		lp(m, "Lappet", base, Vector3.new(w * 0.42, h * 0.95, d * 0.34),
			CFrame.new(s * w * 0.66, -h * 0.24, -d * 0.28), skin.boot,
			Enum.Material.Fabric, NOHIT)
	end
end

local function coneHat(m, head: BasePart, skin)
	local base = head.CFrame
	local w, h = head.Size.X, head.Size.Y
	-- a cone, in four discs. Roblox has no cone primitive and a tapered stack
	-- reads as one from anywhere a player stands.
	for i = 0, 3 do
		upright(m, "Kasa", base, 0.22, w * (2.5 - i * 0.62),
			CFrame.new(0, h * (0.4 + i * 0.16), 0),
			Color3.fromRGB(232, 214, 176), Enum.Material.Fabric, NOHIT)
	end
	upright(m, "KasaCord", base, 0.16, w * 1.9, CFrame.new(0, h * 0.46, 0),
		skin.trim, Enum.Material.Fabric, NOHIT)
end

-- A cloth tied round the head, knotted at the back. The fourth boatman works a
-- deck that has ash falling on it the whole way in, and a bandana is what
-- somebody in that situation actually wears -- it also has to differ from the
-- other three in SILHOUETTE and not only in colour, which rules out a fourth
-- brim: at a hundred studs the straw hat, the kasa and a brimmed anything are
-- one shape.
local function bandana(m, head: BasePart, skin)
	local base = head.CFrame
	local w, h, d = head.Size.X, head.Size.Y, head.Size.Z
	lp(m, "Bandana", base, Vector3.new(w * 1.06, h * 0.44, d * 1.06),
		CFrame.new(0, h * 0.3, 0), skin.trim, Enum.Material.Fabric, NOHIT)
	lp(m, "BandanaKnot", base, Vector3.new(w * 0.34, h * 0.22, d * 0.34),
		CFrame.new(0, h * 0.24, d * 0.58), skin.trim, Enum.Material.Fabric, NOHIT)
	-- the two tails, hanging down the back of the neck
	for _, s in ipairs({ -1, 1 }) do
		lp(m, "BandanaTail", base, Vector3.new(w * 0.2, h * 0.62, d * 0.14),
			CFrame.new(s * w * 0.16, -h * 0.06, d * 0.6) * CFrame.Angles(0.2, 0, s * 0.18),
			skin.boot, Enum.Material.Fabric, NOHIT)
	end
end

-- The red one with the white brim, and the beard that goes with it. The
-- cone is a tapered stack tipped back so the bobble hangs behind the head;
-- the beard is a block under the chin with a moustache over it, in the
-- hat's own white -- and at a hundred studs the silhouette is the beard.
local function santaHat(m, head: BasePart, skin)
	local base = head.CFrame
	local w, h, d = head.Size.X, head.Size.Y, head.Size.Z
	local RED = Color3.fromRGB(196, 44, 48)
	local WHITE = Color3.fromRGB(250, 250, 252)
	for i = 0, 3 do
		upright(m, "HatCone", base, h * 0.2, w * (1.18 - i * 0.26),
			CFrame.new(0, h * (0.5 + i * 0.17), d * 0.06 * i) * CFrame.Angles(0.16, 0, 0),
			RED, Enum.Material.Fabric, NOHIT)
	end
	upright(m, "HatBrim", base, h * 0.16, w * 1.32, CFrame.new(0, h * 0.44, 0), WHITE, Enum.Material.Fabric, NOHIT)
	lp(m, "HatBobble", base, Vector3.new(w * 0.3, w * 0.3, w * 0.3),
		CFrame.new(0, h * 0.98, d * 0.34), WHITE, Enum.Material.Fabric,
		{ Shape = Enum.PartType.Ball, CanCollide = false, CanQuery = false, CanTouch = false })
	-- the beard: chin block, two cheeks, and the moustache. The face is -Z.
	lp(m, "Beard", base, Vector3.new(w * 0.74, h * 0.62, d * 0.34),
		CFrame.new(0, -h * 0.34, -d * 0.36), WHITE, Enum.Material.Fabric, NOHIT)
	for _, s in ipairs({ -1, 1 }) do
		lp(m, "BeardCheek", base, Vector3.new(w * 0.22, h * 0.46, d * 0.5),
			CFrame.new(s * w * 0.42, -h * 0.12, -d * 0.2), WHITE, Enum.Material.Fabric, NOHIT)
	end
	lp(m, "Moustache", base, Vector3.new(w * 0.62, h * 0.12, d * 0.16),
		CFrame.new(0, -h * 0.06, -d * 0.5), WHITE, Enum.Material.Fabric, NOHIT)
end

local HATS = { beach = strawHat, dunes = nemes, cove = coneHat, ashfall = bandana, santa = santaHat }

local function buildFerryman(parent, port, base: CFrame)
	local style = port.ferryman.style
	local look = LOOKS[style] or LOOKS.beach
	local skin = SKINS[port.key] or SKINS.Beach

	local desc = Instance.new("HumanoidDescription")
	desc.HeadColor, desc.LeftArmColor, desc.RightArmColor = look.skin, look.skin, look.skin
	desc.TorsoColor = look.shirt
	desc.LeftLegColor, desc.RightLegColor = look.legs, look.legs
	desc.HeightScale, desc.WidthScale = 1.0, 1.04
	desc.BodyTypeScale, desc.ProportionScale = 0.35, 0.5
	desc.HairAccessory = look.hair

	local ok, m = pcall(function()
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)

	if not (ok and typeof(m) == "Instance") then
		-- A web call failed. The berth still has to have something to hang the
		-- prompt on, or the whole port becomes unusable over a bad minute on
		-- Roblox's avatar service.
		warn(string.format("[Ferry] %s could not be built (%s); the berth keeps its prompt "
			.. "but has nobody standing at it.", tostring(port.ferryman.name), tostring(m)))
		local stub = Instance.new("Model")
		stub.Name = "Ferryman"
		stub.Parent = parent
		local anchor = P(stub, "TalkAnchor", Vector3.new(3.6, 6, 3.6),
			base * CFrame.new(0, 3, 0), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic,
			{ Transparency = 1, CanCollide = false, CanTouch = false, CastShadow = false })
		stub.PrimaryPart = anchor
		return stub, anchor
	end

	m.Name = "Ferryman"

	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end

	local hum = m:FindFirstChildOfClass("Humanoid")
	if hum then
		-- Kept, because the Shirt/Pants/BodyColors machinery is his; neutered,
		-- because everything else it brings is a nuisance on a decoration.
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		hum.NameDisplayDistance = 0
		hum.WalkSpeed = 0
		hum.JumpPower = 0
		hum.AutoRotate = false
		hum.RequiresNeck = false
		pcall(function()
			hum.EvaluateStateMachine = false
		end)
	end

	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end

	m.PrimaryPart = m:FindFirstChild("HumanoidRootPart")
	if m.PrimaryPart then
		-- Assembled AT the origin and posed there, then moved once. `bend`
		-- reads world attachment positions and `snapAccessories` reads world
		-- CFrames, so doing both in the identity frame is one whole class of
		-- rotation bug that cannot happen.
		m.PrimaryPart.CFrame = CFrame.new()
	end
	m.Parent = parent

	snapAccessories(m)
	poseCrew(m)

	local head = m:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		local dress = HATS[style]
		if dress then
			dress(m, head, skin)
		end
	end

	-- Stand him ON the deck rather than through it: the pivot is the root, and
	-- the root is at hip height, so the lift is measured off the finished
	-- bounding box rather than guessed.
	local bbCF, bbSize = m:GetBoundingBox()
	local bottom = bbCF.Position.Y - bbSize.Y * 0.5
	m:PivotTo(base * CFrame.new(0, -bottom, 0))

	--[[
		THE NAMEPLATE, SIZED IN STUDS AND NOT IN PIXELS.

		A BillboardGui's Size takes a UDim2, and the two halves of it mean
		completely different things: the OFFSET half is pixels, which do not
		shrink with distance, and the SCALE half is STUDS, which do.

		Written in pixels (230 x 62) this was measured standing over its own
		pier: from the beachfront the man's name rendered wider than the boat he
		is stood in front of, and from the plaza the cove's read across half the
		bay. That is the identical failure Island3Builder records for the arrival
		gate's old billboard -- "SIFTER Lv.5 NEEDED" hanging in the sky at two or
		three times the width of the board it belonged to.

		11 x 2.6 STUDS sits over a figure who is 5.8 tall and reads as a label
		pinned above his head at every distance, because it is a real object in
		the world rather than a decal on the lens.
	]]
	local plateHost = head or m.PrimaryPart
	local plate = Instance.new("BillboardGui")
	plate.Name = "NamePlate"
	plate.Size = UDim2.fromScale(11, 2.6)
	plate.StudsOffsetWorldSpace = Vector3.new(0, 2.4, 0)
	plate.MaxDistance = 130
	plate.AlwaysOnTop = false
	plate.Parent = plateHost

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "ManName"
	nameLabel.Size = UDim2.fromScale(1, 0.58)
	nameLabel.Position = UDim2.fromScale(0, 0)
	nameLabel.Text = port.ferryman.name
	nameLabel.Parent = plate
	SignKit.floating(nameLabel, port.tint)

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "ManTitle"
	titleLabel.Size = UDim2.fromScale(1, 0.42)
	titleLabel.Position = UDim2.fromScale(0, 0.58)
	titleLabel.Text = string.upper(port.ferryman.title)
	titleLabel.Parent = plate
	SignKit.floating(titleLabel, Color3.fromRGB(255, 250, 238))

	-- What the prompt hangs on. Its own part, so the reach belongs to the BERTH
	-- rather than to whichever body part happened to be nearest -- and it is
	-- built after the move, in world space, because everything under this model
	-- travels with the boat from here on.
	local talk = P(m, "TalkAnchor", Vector3.new(3.6, 6.2, 3.6),
		m:GetPivot() * CFrame.new(0, 0.7, 0), Color3.new(1, 1, 1),
		Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanTouch = false, CastShadow = false })

	return m, talk
end

----------------------------------------------------------------
-- BUILD
----------------------------------------------------------------
--[[
	One berth. `deckY` is passed in rather than raycast here because FerryServer
	is the one that knows whether the island's terrain has settled -- the cove
	and the dunes are both poured at boot, and a raycast taken a frame early
	answers with the seabed.
]]
function FerryBuilder.build(port, deckY: number)
	local skin = SKINS[port.key] or SKINS.Beach

	local m = Instance.new("Model")
	m.Name = port.key .. "Ferry"

	local pier, moorings, dir, side = buildPier(m, port, skin, deckY)

	--[[
		THE GATEWAY SIGN, BEACH ONLY: "NEXT ISLANDS", readable from spawn.

		The dock is the answer to "where does this game go next", and it stands
		three hundred and forty studs north of the spawn -- far enough that a
		first-timer never learns it exists. So the beach berth alone wears a
		gate over the land end of its pier: two posts just outside the deck
		edges, a board big enough to read across the beach, both faces dressed
		(the south face for the beach, the north for the tutorial send-off shot,
		which looks back down the pier from the water).

		SignKit.dress does the lettering: one line, fitted to the face, in the
		board's own contrast colour -- the same call every other board in the
		game goes through, so a repaint follows the kit.
	]]
	if port.key == "Beach" then
		local gz = port.dock.landZ + 3
		local gx = port.dock.x
		local postX = HALF_W + 1.6
		for _, sx in ipairs({ -1, 1 }) do
			P(m, "GatePost",
				Vector3.new(1.6, 21, 1.6),
				CFrame.new(gx + sx * postX, deckY + 9.5, gz),
				skin.post, Enum.Material.Wood)
		end
		--[[
			THE BOARD HANGS ON THE FRONT OF THE POSTS, NOT THROUGH THEM. At the
			posts' own z the uprights ran straight through the face and cut the
			lettering into thirds. One board-and-post half-depth south puts the
			whole face proud of the timber with the backs still kissing the post
			fronts -- mounted on, not floating off. The north face pays for it
			(the posts now stand ahead of that side's letters near the edges),
			and that is the right trade: the south face is the one read from
			spawn, and the send-off's own shots frame the islands themselves
			now, not the back of this gate.
		]]
		local board = P(m, "GateBoard",
			Vector3.new(postX * 2 + 4.4, 6.5, 0.7),
			CFrame.new(gx, deckY + 17.2, gz - 1.15),
			skin.deckDark, Enum.Material.WoodPlanks, { CanCollide = false })
		-- The trim bar the sell shop's boards wear, in the berth's own teal.
		P(m, "GateTrim",
			Vector3.new(postX * 2 + 4.8, 0.55, 0.8),
			CFrame.new(gx, deckY + 20.7, gz - 1.2),
			skin.trim, Enum.Material.SmoothPlastic, { CanCollide = false })
		if board then
			SignKit.dress(board, "NEXT ISLANDS",
				{ Enum.NormalId.Front, Enum.NormalId.Back })
		end
	end

	local moorPos = FerryConfig.moorPos(port)
	local moorCF = CFrame.new(moorPos) * FerryConfig.heading(port)
	local boat = buildBoat(m, port, skin, moorCF)

	--[[
		THE BOATMAN IS ON THE BOAT.

		He used to stand twelve studs in from the pier head, which was fine while
		a crossing was a fade to black -- but the boat now carries you across in
		front of you for nine seconds, and an empty one says nobody is sailing
		it. He is aft at the tiller, off the centre line so the walking lane down
		the deck is clear, and he is a CHILD OF THE BOAT MODEL: everything the
		crossing does to her -- the run out, the pitch into the swell, the roll --
		it does to him, without one line in FerryServer knowing he exists.

		HIS HEADING IS DERIVED, and it has to be. He faces the bow (local -X, a
		yaw of pi/2 in her frame) turned about half a radian toward the pier, so
		a player walking up the planks to talk to him is not addressing his
		shoulder. WHICH WAY that turn goes depends on the berth: her local +Z
		points at world +X * dir, and the pier is always thirteen studs of world
		-X off her beam, so the pier lies at local Z = -13 * dir -- which is
		astern of the yaw on the beach and ahead of it on the other two.
	]]
	local manBase = moorCF * CFrame.new(CREW_X, BOAT_DECK, 0)
		* CFrame.Angles(0, math.pi * 0.5 - dir * 0.55, 0)
	local man, talk = buildFerryman(boat, port, manBase)

	-- The plank across to her waist. Not collidable: it is a 40-degree ramp
	-- from a pier deck down to a boat deck, which is scenery rather than a
	-- staircase -- and the boat's own Deck is solid, so anyone who wants to be
	-- aboard can simply step onto her.
	local gz = port.dock.seaZ - dir * 5
	span(m, "Gangway",
		Vector3.new(port.dock.x + side * (HALF_W - 0.4), deckY - 0.15, gz),
		Vector3.new(moorPos.X - side * (BOAT_BEAM * 0.5 - 0.6), BOAT_DECK + 0.35, gz),
		3.0, 0.35, skin.deck, Enum.Material.WoodPlanks,
		{ CanCollide = false, CanQuery = false })

	-- The two lines that say she is tied up rather than parked. Handed back so
	-- the crossing can take them off her before she leaves.
	local lines = {}
	for i, at in ipairs(moorings) do
		local cleat = Vector3.new(moorPos.X - side * (BOAT_BEAM * 0.5 - 0.3),
			BOAT_DECK + 0.5, moorPos.Z - dir * (i == 1 and 6 or 14))
		local rope = span(m, "MooringLine", at, cleat, 0.2, 0.2, skin.rope,
			Enum.Material.Fabric, { CanCollide = false, CanQuery = false })
		if rope then
			table.insert(lines, rope)
		end
	end

	-- Nothing translucent or lit here casts a shadow it needs to, and sixty
	-- parts of pier throwing shadow onto sand nobody looks at is the cheapest
	-- thing in the berth to give back. The cove trims its own props the same way.
	for _, p in ipairs(m:GetDescendants()) do
		if p:IsA("BasePart") and (p.Transparency > 0.5 or p.Material == Enum.Material.Neon) then
			p.CastShadow = false
		end
	end

	return m, {
		talkAnchor = talk,
		boat = boat,
		man = man,
		pier = pier,
		deckY = deckY,
		moorCF = moorCF,
		riderOffset = RIDER,
		lines = lines,
	}
end

return FerryBuilder
