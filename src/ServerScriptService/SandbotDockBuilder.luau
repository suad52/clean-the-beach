--[[
	SandbotDockBuilder  --  ServerScriptService.SandbotDockBuilder

	THE SANDBOT HOME: the little charging kennel the drone is sent out from and
	put away into, standing beside the car spawner on every island that has one.

	WHY THERE IS A BUILDING AT ALL
	------------------------------
	The sandbot used to be sold and driven from a KEY ON THE SCREEN -- a
	full-width row in the left-hand column that read BEACH SANDBOT over a price
	to anybody who did not own the pass, and DEPLOY to anybody who did. It was
	there for every second of every session whether or not the player had any
	interest in it, it took 66 pixels off the carried-items drawer, and it
	advertised a Robux purchase from the same corner as the coin counter.

	EVERY OTHER PURCHASE IN THIS GAME IS A PLACE YOU WALK UP TO. The car
	showroom, the wash bay, the beach shop, the egg plaza, the ferry berth. The
	sandbot was the one feature sold from the HUD, and a machine is exactly the
	kind of thing that is better sold by standing one in front of the player:
	there is a real drone parked on the charging plate of every one of these,
	lit and turning its brushes over, which is an advertisement no button is.

	It buys a SECURITY improvement for nothing as well. The prompt's Triggered
	fires on the server, so the engine itself vouches that the player was
	standing at the dock -- where a remote could only ever claim they were. That
	is the argument Net's header makes about the egg station and the upgrade
	kiosk, applied to one more feature.

	AND IT IS NOT SCENERY ANY MORE. The drone is DEPLOYED FROM the plate and
	PARKED BACK ONTO it: SandbotService puts a new machine down on this building's
	berth and drives it out through the mouth, and drives it back in and hands over
	to the display at the end. So `berth` below is load-bearing geometry rather
	than decoration, and "which dock did they press" is a real input -- one the
	prompt hands over for free and a remote could not have carried at all.

	WHERE THEY GO: AT THE END OF THE EGG ROW
	----------------------------------------
	One dock per CarSpawner tag still -- that tag is what makes the timing and the
	adoption below work -- but it now stands at the END OF THAT ISLAND'S EGG ROW
	rather than on the car pad's flank. Same argument the header opens with, taken
	one step further: the egg plaza is the one place on every island where a player
	is ALREADY standing at a row of machines deciding whether to spend, so a fifth
	shopfront belongs on the end of it rather than out by the car park.

	THE FACING IS THE ROW'S OWN AND THERE IS NO PER-ISLAND ANGLE TO GET WRONG.
	PetStationBuilder lays its booths along the row frame's X with their open faces
	down its +Z, and +Z is this file's mouth -- so handing the row's rotation
	straight through points the dock the same way as the booths beside it.

	THE ROW'S HIGH (+local X) END, on all four islands, and it is a rule rather
	than four addresses. MEASURED over the body band a walking character occupies,
	at EGG_GAP:

		beach      109.8, -168.6  clear. The LOW end is the AFK shore's deck.
		dunes     1464.0, -176.6  clear, on the market's west flank.
		cove         30.0, 1392.2 clear, inside the sando's paving (which ends at
		                          1400) and twelve studs short of the field (1404).
		ashfall   -2228.0, -655.7 clear, on the landing's egg forecourt.

	The LOW end is blocked on two of the four -- the beach's AfkEntry deck and a
	cove SakuraTree's trunk collider -- which is why the rule picks HIGH rather
	than whichever is nearer to anything.

	None of the four is inside a rakeable field. CHECKED with Config.fieldAt, not
	assumed, because a dock on terrain the player rakes flat is the one placement
	fault that cannot be lived with.

	An island with NO egg row falls back to the old rule -- the pad's left flank,
	GAP studs off. That is not dead code: the vault and the two interiors carry
	`plaza = false`, so a car pad ever tagged near one still gets a dock.

	ADOPTION CONTRACT
	-----------------
	The same one BayBuilder, StoreBuilder and CarSpawnerBuilder have: a fallback,
	not an owner. A tagged dock already standing within CLAIM studs of a pad is
	that pad's dock and this does nothing at all, so the moment a nicer one is
	hand-built in Studio and tagged, this code stands down and the authored one
	keeps its place.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local SignKit = require(Modules:WaitForChild("SignKit"))
local SandbotConfig = require(Modules:WaitForChild("SandbotConfig"))
-- WHERE THE EGG ROW IS. PetConfig holds the row FRAME (x, z, yaw) and CTB.Config
-- answers which island a pad stands on; the row's LENGTH is read off the built
-- plaza rather than from either, because the booth pitch is derived at run time
-- from the widest tube on that island's shelf. Both are plain replicated data.
local PetConfig = require(Modules:WaitForChild("PetConfig"))
local CTBConfig = require(ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Config"))

-- For the machine parked on the plate. template() is idempotent and builds into
-- ServerStorage, so requiring it here costs nothing SandbotService was not
-- already paying, and nothing replicates.
local SandbotBuilder = require(ServerScriptService:WaitForChild("SandbotBuilder"))

local SandbotDockBuilder = {}

SandbotDockBuilder.TAG = "SandbotDock"

-- What SandbotClient looks for inside a dock to spin its brushes. Spelled once
-- here and once there; if it ever needs a third home it belongs in the config.
SandbotDockBuilder.DisplayName = "DisplaySandbot"

-- Which pads it stands beside. AtvConfig.SpawnerTag is the same string; it is
-- not required here because this module has no other reason to load the car
-- shop's whole table.
local CAR_TAG = "CarSpawner"

-- Where PetStationBuilder parks its plazas, and what it calls each one. Spelled
-- here because that builder does not export either, and a dock that cannot find
-- the row simply falls back to the pad flank rather than failing.
local PLAZA_ROOT = "PetStations"
local PLAZA_PREFIX = "Plaza_"

--------------------------------------------------------------------------
-- THE NUMBERS
--------------------------------------------------------------------------
--[[
	Across and front-to-back, AND THE WIDTH IS SET BY THE BRUSHES.

	The machine is 5.2 across the hull and 8.4 ACROSS THE BRUSHES -- the number
	SandbotConfig.Sweep is derived from, and the one that matters here. At 9.5
	wide the side walls left an inner span of exactly 8.4, so the brush tips sat
	five thousandths of a stud off the walls and swept through them. Measured on
	the first build.

	11.0 leaves 9.9 between the walls: three quarters of a stud of air either
	side of a spinning brush. If the brushes are ever widened in SandbotBuilder,
	this moves with them.

	The depth is the machine's own 5.8 plus an apron to stand on and enough roof
	to read as a shelter.
]]
local W, D = 11.0, 10.0

local TOP = 0.35            -- the floor's top face, relative to the origin
-- 2.0 thick, and the depth is buried. The ground beside these pads is not level
-- with them -- the beach probes 2.73 against a pad surface of 3.60 -- so a thin
-- slab laid at the pad's own height would show daylight underneath.
local THICK = 2.0

local WALL_H = 4.2          -- head height on a 5 stud character, so it reads as a shelter
local WALL_T = 0.55
-- The side walls stop short of the mouth. Full depth makes a tunnel you cannot
-- see the machine in from the side, which is the one thing this building is for.
local SIDE_D = 6.0

-- WHERE ON THE FLOOR THE MACHINE STANDS. Slightly back of centre, so it parks
-- under the roof rather than in the doorway and is still fully visible from the
-- front. AT FILE SCOPE because it is no longer only the build's business: the
-- berth below is measured off it, and SandbotService drives to that.
local PLATE_Z = -0.4

--[[
	HOW FAR IT IS FROM THE PLATE TO THE OPEN FACE, along the mouth.

	Exported because SandbotService needs to know where the doorway is to drive
	through it, and the two numbers that decide it (the depth, and how far back the
	plate sits) are this file's. Adding a stud of depth here moves the drone's
	route out with it, which is the point.
]]
SandbotDockBuilder.MouthGap = D * 0.5 - PLATE_Z

--[[
	THE ALLEY BETWEEN THE CAR PAD'S EDGE AND THE DOCK'S, AND IT IS MEASURED
	AGAINST SERVICECLEARANCE RATHER THAN CHOSEN.

	That pass keeps a 4 stud apron round every service point and NAMES anything
	solid standing inside one in the boot log. A dock inside the car pad's apron
	would be in that list at every start for ever, which is exactly the kind of
	standing false alarm that teaches people to stop reading the log.

	5.0 WAS NOT ENOUGH, by 0.16 studs, and the reason is worth writing down: the
	apron is measured off the pad MODEL'S BOUNDING BOX, not off its slab. The
	sign board hangs 1.12 studs past the slab on the +X side, so the box is 17.12
	wide round a 16 stud pad and its centre is 0.56 off the pad's own. Measured on
	Ashfall: apron edge -2121.16, dock floor edge -2121.00 -- and all three plain
	pads duly turned up in the log as obstructions of the pad they stand beside.

	6.0 clears it by 0.84 on the plain pads and by 2.05 on the beach's showroom,
	and it is a wider alley to walk down, which is no loss.
]]
local GAP = 6.0

--[[
	THE ALLEY BETWEEN THE LAST EGG BOOTH AND THE DOCK, AND IT IS SET BY THE TWO
	PROMPTS RATHER THAN BY THE LOOK.

	Both are bound to E and ProximityPrompt's Exclusivity is OnePerButton, so
	where their ranges overlap only the NEARER one is shown -- and a player walking
	up to the dock past the booths gets whichever the engine picks rather than the
	one they walked towards. That is the same failure the REACH note below records
	against the car pad, against a different neighbour.

	This dock's REACH is 10 and an egg station's MaxActivationDistance is 12, so
	the two anchors have to be at least 22 apart. MEASURED at the four high ends:
	at GAP's own 6.0 they came out 19.0 / 19.6 / 20.4 / 20.8 -- EVERY island
	overlapping. At 10.0 they are 22.9 / 23.5 / 24.2 / 24.7, disjoint on all four,
	tightest margin just under a stud.

	It is also a wider alley to walk down than the car pad's was, which is no loss.
]]
local EGG_GAP = 10.0

--[[
	HOW NEAR A TAGGED DOCK HAS TO BE TO A PAD TO COUNT AS THAT PAD'S DOCK.

	240, NOT 60, AND THAT NUMBER MOVED WITH THE BUILDING. 60 was measured against
	a dock standing on the pad's own flank; the egg row is 110 to 180 studs away
	(beach 178.8, cove 120.0, dunes 110.0, ashfall 140.8), so at 60 claimedBy
	would not have recognised the dock it had just built -- and ensureFor would
	have stood a SECOND one beside every row on every sweep. Silent duplication,
	and the idempotence the whole sweep rests on.

	Still far under the 1,554 studs between the closest two car spawners in the
	game (the beach's and the cove's), so no dock can be claimed by the wrong pad.
]]
local CLAIM = 240

--[[
	HOW FAR THE PROMPT REACHES, AND IT IS SET AGAINST THE CAR PAD'S.

	The two prompts are both bound to E, and ProximityPrompt's default
	Exclusivity is OnePerButton -- so where their ranges overlap, only the nearer
	one is shown, and a player standing between the two buildings gets whichever
	the engine picks rather than the one they walked towards.

	MEASURED, so there is no overlap at all: the two anchors are 19.1 studs apart
	on the three plain pads (38.8 on the beach's showroom). A plain pad's own
	reach is 9, so 10 here leaves the bands disjoint by a tenth of a stud, and 12
	did not.

	10 still covers the whole apron in front of the dock and the alley beside it
	-- the far corner of the alley is 8.7 studs from the anchor.
]]
local REACH = 10

-- The machine's own colour, out of SandbotBuilder's palette, so the charging
-- plate and the guide lights say SANDBOT whatever the island's stone is.
local SEA = Color3.fromRGB(64, 168, 240)

--------------------------------------------------------------------------
-- WHERE THE MACHINE STANDS
--------------------------------------------------------------------------
--[[
	THE BERTH: the exact pose a sandbot occupies when it is home -- position AND
	facing, with +Z looking out of the mouth.

	It is what a deploy is placed on and what a recall drives back to, so the one
	thing it may not be is APPROXIMATELY the display's pose: the drone is destroyed
	at the end of a recall and the display becomes visible in the same frame, and
	the handover only disappears if the two are the same CFrame to the stud.

	SO IT IS READ OFF THE DISPLAY ITSELF wherever there is one. Deriving it a
	second time from TOP/Hover/Height would be the same arithmetic written twice,
	in two files, drifting the first time either moves -- and the display's pivot
	IS that arithmetic, already evaluated, because build() puts it there.

	The FLOOR is the fallback and it carries the rotation in both cases: `origin`
	is the frame the whole building was laid out in, and Floor is the one part
	placed on its own axis with no offset but height, so unwinding that height
	recovers it exactly.

	nil for a model this file cannot read -- a hand-built dock with neither part.
	That is a real answer: SandbotService falls back to putting the drone down
	beside its owner, which is what it did before there was a building at all.
]]
function SandbotDockBuilder.berth(dock: Model?): CFrame?
	if not (dock and dock:IsA("Model") and dock:IsDescendantOf(workspace)) then
		return nil
	end

	local floor = dock:FindFirstChild("Floor")
	if not (floor and floor:IsA("BasePart")) then
		return nil
	end
	-- build() places the floor at origin * CFrame.new(0, TOP - THICK * 0.5, 0).
	local origin = floor.CFrame * CFrame.new(0, THICK * 0.5 - TOP, 0)

	local display = dock:FindFirstChild(SandbotDockBuilder.DisplayName)
	if display and display:IsA("Model") then
		-- Rotation from the origin rather than from the pivot: they agree today, and
		-- the origin is the one of the two that cannot be nudged by somebody dragging
		-- the stock model in Studio.
		return (origin - origin.Position) + display:GetPivot().Position
	end

	return origin * CFrame.new(0,
		TOP + SandbotConfig.Hover + SandbotConfig.Height * 0.5, PLATE_Z)
end

--------------------------------------------------------------------------
-- THE PALETTE, READ OFF THE PAD RATHER THAN LISTED HERE
--------------------------------------------------------------------------
--[[
	CarSpawnerBuilder carries two palettes -- concrete and asphalt on the beach,
	stone and gold in the desert -- and picks one per island. A third copy of
	those colours in this file would be a third copy to keep in step, and the day
	somebody adds a fourth island's palette the dock beside it would be wearing
	the beach's.

	So the dock wears WHATEVER THE PAD IT STANDS BESIDE IS WEARING, read straight
	off the pad's own parts. It cannot drift, it needs no table, and a hand-
	recoloured pad brings its dock with it.

	The fallbacks are CarSpawnerBuilder's beach palette, and they are only
	reached if a pad is missing the part in question -- which would mean somebody
	hand-built a pad without it, and a dock in beach colours is a better answer
	than an error.
]]
local function skinPart(pad: Model, childName: string, colour: Color3, material: Enum.Material)
	local p = pad:FindFirstChild(childName)
	if p and p:IsA("BasePart") then
		return p.Color, p.Material
	end
	return colour, material
end

local function skinOf(pad: Model)
	local skin = {}
	skin.floor, skin.floorMat = skinPart(pad, "Pad",
		Color3.fromRGB(62, 64, 70), Enum.Material.Asphalt)
	skin.wall, skin.wallMat = skinPart(pad, "KerbBack",
		Color3.fromRGB(150, 148, 142), Enum.Material.Concrete)
	skin.post, skin.postMat = skinPart(pad, "SignPost",
		Color3.fromRGB(99, 66, 40), Enum.Material.Wood)
	skin.ink = skinPart(pad, "SignBoard", Color3.fromRGB(38, 42, 48), Enum.Material.SmoothPlastic)
	skin.line = skinPart(pad, "BayLine", Color3.fromRGB(238, 232, 212), Enum.Material.SmoothPlastic)
	skin.accent = skinPart(pad, "Bollard", Color3.fromRGB(226, 168, 52), Enum.Material.Metal)
	return skin
end

--------------------------------------------------------------------------
-- THE BUILD
--------------------------------------------------------------------------
--[[
	`origin` is the floor's own frame: +Z is the mouth, y = 0 is TOP studs under
	the floor's top face. `opts` is optional and every field of it is:
	{ name, sign, parent, reach }.
]]
function SandbotDockBuilder.build(origin: CFrame, skin, opts): Model
	opts = opts or {}

	local model = Instance.new("Model")
	model.Name = opts.name or "SandbotHome"

	local function part(props): BasePart
		local p = Instance.new("Part")
		p.Anchored = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		local offset = props.Offset
		for k, v in props do
			if k ~= "Offset" then
				p[k] = v
			end
		end
		p.CFrame = origin * offset
		p.Parent = model
		return p
	end

	-- Decoration: out of every spatial query, and never in the way of anything.
	-- Same split CarSpawnerBuilder draws between its slab and its bay markings.
	local function trim(props): BasePart
		props.CanCollide = false
		props.CanQuery = false
		props.CanTouch = false
		return part(props)
	end

	-- A DISC LYING FLAT is (thickness, diameter, diameter) turned +90 about Z.
	-- Pass (d, t, d) and you get a wheel standing on its edge, which is the trap
	-- SandbotBuilder.disc records paying for twice.
	local function plate(name: string, dia: number, thick: number, y: number, z: number,
		colour: Color3, material: Enum.Material)
		return trim({
			Name = name,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(thick, dia, dia),
			Color = colour,
			Material = material,
			Offset = CFrame.new(0, y, z) * CFrame.Angles(0, 0, math.pi * 0.5),
		})
	end

	------------------------------------------------------------------
	-- THE FLOOR
	------------------------------------------------------------------
	part({
		Name = "Floor",
		Size = Vector3.new(W, THICK, D),
		Color = skin.floor,
		Material = skin.floorMat,
		Offset = CFrame.new(0, TOP - THICK * 0.5, 0),
	})

	------------------------------------------------------------------
	-- THE CHARGING PLATE  --  what says "the machine goes HERE"
	------------------------------------------------------------------
	-- PLATE_Z is at file scope: SandbotDockBuilder.berth is measured off it.
	-- Both float 0.02 clear of the floor's top face rather than sitting on it:
	-- two coplanar faces z-fight, which at this size reads as the plate
	-- flickering. Same 0.02 CarSpawnerBuilder's bay lines use.
	plate("PlateRim", 7.0, 0.12, TOP + 0.08, PLATE_Z, skin.ink, Enum.Material.SmoothPlastic)
	plate("Plate", 6.3, 0.14, TOP + 0.10, PLATE_Z, SEA, Enum.Material.SmoothPlastic)

	for _, sx in { -1, 1 } do
		trim({
			Name = "Contact",
			Size = Vector3.new(0.9, 0.45, 0.35),
			Color = skin.accent,
			Material = Enum.Material.Metal,
			Offset = CFrame.new(sx * 1.15, TOP + 0.22, PLATE_Z - 2.7),
		})
	end

	------------------------------------------------------------------
	-- THE SHELL  --  three walls and an open front, like every bay in the game
	------------------------------------------------------------------
	part({
		Name = "BackWall",
		Size = Vector3.new(W, WALL_H, WALL_T),
		Color = skin.wall,
		Material = skin.wallMat,
		Offset = CFrame.new(0, TOP + WALL_H * 0.5, -(D * 0.5 - WALL_T * 0.5)),
	})
	-- One dark band across the back. A flat wall of one colour behind a blue
	-- machine is a lot of unbroken plastic, and this is the cheapest shoulder
	-- available -- the same trick the drone's own Waist is.
	trim({
		Name = "Dado",
		Size = Vector3.new(W + 0.08, 0.34, WALL_T + 0.08),
		Color = skin.ink,
		Material = Enum.Material.SmoothPlastic,
		Offset = CFrame.new(0, TOP + 0.95, -(D * 0.5 - WALL_T * 0.5)),
	})

	for _, sx in { -1, 1 } do
		part({
			Name = "SideWall",
			Size = Vector3.new(WALL_T, WALL_H, SIDE_D),
			Color = skin.wall,
			Material = skin.wallMat,
			Offset = CFrame.new(sx * (W * 0.5 - WALL_T * 0.5), TOP + WALL_H * 0.5,
				-(D * 0.5 - SIDE_D * 0.5)),
		})
		-- The two posts the canopy stands on. SOLID, deliberately: ServiceClearance's
		-- own rule is that a player walking through a pillar reads as a broken game.
		-- They leave an 8.4 stud mouth, which is wider than the machine.
		part({
			Name = "Post",
			Size = Vector3.new(0.55, WALL_H, 0.55),
			Color = skin.post,
			Material = skin.postMat,
			Offset = CFrame.new(sx * (W * 0.5 - 0.35), TOP + WALL_H * 0.5, D * 0.5 - 0.35),
		})
		-- A bay light on each post, in the machine's own blue. It is what makes the
		-- dock findable along a dark shop row and at night.
		--
		-- PROUD OF THE POST'S FRONT FACE, not centred in it. A 0.7 ball inside a
		-- 0.55 post shows 0.075 of itself on each side, which is a paler patch
		-- rather than a lamp -- the same mistake the drone's own Lamp records
		-- making with a flat disc on its lid.
		trim({
			Name = "GuideLight",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(0.85, 0.85, 0.85),
			Color = SEA,
			Material = Enum.Material.Neon,
			Offset = CFrame.new(sx * (W * 0.5 - 0.35), TOP + WALL_H - 0.45, D * 0.5 + 0.15),
		})
	end

	trim({
		Name = "Roof",
		Size = Vector3.new(W + 1.3, 0.45, D + 1.3),
		Color = skin.wall,
		Material = skin.wallMat,
		Offset = CFrame.new(0, TOP + WALL_H + 0.225, 0),
	})
	trim({
		Name = "RoofEdge",
		Size = Vector3.new(W + 1.5, 0.18, 0.34),
		Color = skin.accent,
		Material = Enum.Material.Metal,
		Offset = CFrame.new(0, TOP + WALL_H + 0.08, (D + 1.3) * 0.5 - 0.17),
	})

	------------------------------------------------------------------
	-- THE SIGN
	------------------------------------------------------------------
	-- ON THE FRONT, ABOVE THE ROOF, not on a post at the side. The car pad's
	-- board is edge-on to the row because a pad is approached from every
	-- direction; a kennel has ONE open face and everybody who reads this is
	-- standing in front of it.
	--
	-- BOTH faces, which for a board this thin means Front (-Z) and Back (+Z). A
	-- thin board has two readable sides and signing only one is a coin flip you
	-- lose half the time -- the lesson the wash bay's own board records.
	local board = trim({
		Name = "SignBoard",
		Size = Vector3.new(7.4, 1.8, 0.32),
		Color = skin.ink,
		Material = Enum.Material.SmoothPlastic,
		Offset = CFrame.new(0, TOP + WALL_H + 1.35, D * 0.5 - 0.1),
	})
	SignKit.dress(board, opts.sign or "SANDBOT HOME",
		{ Enum.NormalId.Front, Enum.NormalId.Back })

	trim({
		Name = "SignTrim",
		Size = Vector3.new(7.8, 0.28, 0.36),
		Color = skin.accent,
		Material = Enum.Material.Metal,
		Offset = CFrame.new(0, TOP + WALL_H + 2.4, D * 0.5 - 0.1),
	})

	------------------------------------------------------------------
	-- WHERE THE PROMPT HANGS
	------------------------------------------------------------------
	-- Invisible, and at the mouth rather than at the machine: the player stands
	-- in front of the dock, and a prompt anchored on the back wall measures its
	-- reach from the wrong end of the building.
	part({
		Name = "PromptAnchor",
		Size = Vector3.new(1, 1, 1),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Offset = CFrame.new(0, TOP + 3.0, D * 0.5 - 0.6),
	})

	------------------------------------------------------------------
	-- THE STOCK
	------------------------------------------------------------------
	--[[
		A REAL MACHINE, PARKED. This is what makes the dock worth building instead
		of a sign: AtvServer stands a bulldozer and a tipper on the car pad's
		plinths for exactly this reason -- somebody who owns nothing still walks up
		to the thing rather than to a rectangle with a price over it.

		IT IS THE SAME MODEL a deployed drone is, cloned from the same template, so
		it cannot drift from what the player is being sold. Nothing drives it: the
		Hull is anchored and SandbotService has no record of it. SandbotClient
		spins its brushes along with everybody else's, because a parked machine
		whose brushes are dead still reads as a prop.

		PivotTo BEFORE PARENTING, AND THAT IS NOT TIDINESS. Every part except the
		Hull is unanchored and held by a WeldConstraint, and a WeldConstraint locks
		the offset its two parts have WHEN IT BECOMES ACTIVE -- which is when the
		model enters the workspace. Moving the hull after that point leaves the
		body where it was and welds it there; SandbotService's spawn() carries the
		full account of what that looked like.

		The height is the drone's own ride height over the floor, so it sits on the
		plate exactly as it sits on sand.
	]]
	local stock = SandbotBuilder.template():Clone()
	stock.Name = SandbotDockBuilder.DisplayName
	stock:PivotTo(origin * CFrame.new(0,
		TOP + SandbotConfig.Hover + SandbotConfig.Height * 0.5, PLATE_Z))
	stock.Parent = model

	------------------------------------------------------------------
	model.PrimaryPart = model:FindFirstChild("Floor")
	model:SetAttribute("PromptReach", opts.reach or REACH)
	-- Parented BEFORE it is tagged, so anything listening on the tag -- the
	-- prompt binder in SandbotService, the brush spin on every client -- finds a
	-- finished building in the world rather than a model still under
	-- construction.
	model.Parent = opts.parent or workspace
	CollectionService:AddTag(model, SandbotDockBuilder.TAG)
	return model
end

--------------------------------------------------------------------------
-- WHERE ONE GOES
--------------------------------------------------------------------------
--[[
	NAMED OFF THE ISLAND, NOT OFF THE PAD -- AND THAT CLEARS A COLLISION.

	It used to be `pad.Name .. "Home"`, which is the SAME name
	CarSpawnerBuilder.ensureAt gives an island's second car pad. So the dock and
	that bay were both called e.g. "AshfallCarSpawnerHome", and the boot log has
	been printing one name for two different buildings.

	It is not true any more either: the dock does not stand beside the car pad.
	"SakuraCoveSandbotHome" says whose it is and what it is, and the spaces come
	out because island names have them ("Sakura Cove", "Ashfall Isle") and an
	Explorer search does not want them.

	NOTHING LOOKS A DOCK UP BY NAME. SandbotService binds its prompt and
	SandbotClient spins its brushes off SandbotDockBuilder.TAG -- both checked
	before this was renamed. The name is for a human reading the tree.
]]
local function nameFor(pad: Model): string
	local isl = CTBConfig.nearestField(pad:GetPivot().Position)
	local base = isl and (isl.name:gsub("%s+", "")) or pad.Name
	return base .. "SandbotHome"
end

--[[
	DOES THIS PAD ALREADY HAVE A HOME?

	Asked by DISTANCE rather than by name, and that is the whole adoption
	contract in one function. A name test alone breaks on both of the cases that
	actually happen here:

		RENAMING   Island3 and Island4 build their pad through
		           CarSpawnerBuilder.build -- which tags it while it is still
		           called "CarSpawner" -- and rename it afterwards.
		HAND-BUILT A dock authored in Studio and tagged will be called whatever
		           its author called it, and it must WIN.

	CLAIM is 60: comfortably over the 36 studs the beach's showroom pad puts
	between the two centres, and comfortably under the 1,500 that separate the
	closest two car spawners in the game -- so no dock can be mistaken for a
	different pad's.
]]
local function claimedBy(pad: Model): Model?
	local at = pad:GetPivot().Position
	for _, dock in CollectionService:GetTagged(SandbotDockBuilder.TAG) do
		if dock:IsA("Model") and dock:IsDescendantOf(workspace) then
			local there = dock:GetPivot().Position
			local dx, dz = there.X - at.X, there.Z - at.Z
			if dx * dx + dz * dz <= CLAIM * CLAIM then
				return dock
			end
		end
	end
	return nil
end

--[[
	THE END OF THIS ISLAND'S EGG ROW, as a full CFrame -- position AND facing.

	nil when the island has no row, which is a real answer rather than a failure:
	the vault and the two interiors carry `plaza = false`, and ensureFor falls back
	to the pad flank on nil.

	THE ROW'S LENGTH IS MEASURED OFF THE BUILT PLAZA, NOT COMPUTED. The pitch is
	PetStationBuilder's `rowPitch`, solved at run time from the widest tube on THIS
	island's shelf, and the booth count is per-island -- so reading the models is
	both shorter than re-deriving any of that and automatically right when either
	moves. The plazas are standing by the time this runs: PetStationBuilder
	finishes inside ServerMain and the dock sweep is SandbotService.start(), its
	last line.

	The FRAME, though, comes from PetConfig rather than from the models, because
	that is where the row's rotation is decided and three of the four rows are a
	single file of booths that cannot tell you their own axis.

	Projected into the row's own X, so a rotated row needs no special case. A
	booth's half-width is the WIDER of its two horizontal extents: they are very
	nearly square in plan and which axis is which depends on the yaw.
]]
local function eggRowSpot(pad: Model): CFrame?
	local isl = CTBConfig.nearestField(pad:GetPivot().Position)
	local over = isl and PetConfig.StationOverrides and PetConfig.StationOverrides[isl.id]
	local row = over and over.row
	if not (row and type(row.x) == "number" and type(row.z) == "number") then
		return nil
	end

	local plazas = workspace:FindFirstChild(PLAZA_ROOT)
	local plaza = plazas and plazas:FindFirstChild(PLAZA_PREFIX .. isl.name)
	if not plaza then
		return nil
	end

	local base = CFrame.new(row.x, 0, row.z) * CFrame.Angles(0, math.rad(row.yaw or 0), 0)

	local hi = -math.huge
	for _, station in plaza:GetChildren() do
		if station:IsA("Model") and station:GetAttribute("EggKey") then
			local cf, size = station:GetBoundingBox()
			local along = base:PointToObjectSpace(cf.Position).X
			hi = math.max(hi, along + math.max(size.X, size.Z) * 0.5)
		end
	end
	if hi == -math.huge then
		-- A plaza folder with nothing on it. Treat it as no row rather than
		-- standing a dock on the row's own centre.
		return nil
	end

	return base * CFrame.new(hi + EGG_GAP + W * 0.5, 0, 0)
end

-- Returns the dock standing beside this pad, and whether this call is what put
-- it there.
function SandbotDockBuilder.ensureFor(pad: Model): (Model?, boolean)
	if not (pad and pad:IsA("Model") and pad:IsDescendantOf(workspace)) then
		return nil, false
	end

	local slab = pad:FindFirstChild("Pad")
	if not (slab and slab:IsA("BasePart")) then
		-- Every CarSpawnerBuilder pad has one and it is the model's PrimaryPart.
		-- A tagged model without it is somebody's own pad built to a different
		-- shape, and guessing where its edge is would put a building through it.
		warn("[SandbotDock] " .. pad.Name .. " has no Pad part -- no dock beside it")
		return nil, false
	end

	local standing = claimedBy(pad)
	if standing then
		return standing, false
	end

	--[[
		WHERE IT STANDS, AND WHICH WAY IT LOOKS -- both out of one CFrame.

		The egg row's far end where the island has a row, the pad's LEFT flank where
		it does not. See the header for both, and for why the fallback is not dead
		code.

		Either way it is expressed IN THAT THING'S OWN FRAME rather than the
		world's, so a row or a pad that is ever rotated takes its dock round with it
		instead of leaving it standing in the sea.
	]]
	local frame = eggRowSpot(pad)
	if not frame then
		local off = slab.Size.X * 0.5 + GAP + W * 0.5
		frame = slab.CFrame * CFrame.new(-off, 0, 0)
	end
	local spot = frame.Position
	local padTop = slab.Position.Y + slab.Size.Y * 0.5

	--[[
		THE FLOOR HEIGHT: THE GROUND AT THE DOCK'S OWN SPOT.

		It used to be the PAD's surface with the ground as a floor under it, which
		was right while the two stood side by side and is meaningless now they are a
		hundred studs apart on different paving. The egg booths stand on the plaza
		and so does this; the pad's top survives only as the fallback for a ray that
		finds nothing at all.

		THE PLAZA IS EXCLUDED AS WELL AS THE PAD. A booth's roof is several studs
		over the ground, and while EGG_GAP puts the dock ten studs clear of the
		nearest one today, a wider booth or a smaller gap would put a roof under this
		ray and stand the whole building on top of it.

		THICK's 2.0 studs hang below the origin, which is what covers the ground
		being a little uneven underneath.
	]]
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = { pad }
	local plazas = workspace:FindFirstChild(PLAZA_ROOT)
	if plazas then
		table.insert(ignore, plazas)
	end
	params.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(Vector3.new(spot.X, spot.Y + 200, spot.Z),
		Vector3.new(0, -400, 0), params)
	local groundY = hit and hit.Position.Y or padTop

	local origin = (frame - frame.Position) + Vector3.new(spot.X, groundY, spot.Z)

	return SandbotDockBuilder.build(origin, skinOf(pad), {
		name = nameFor(pad),
		-- Beside the pad in the tree as well as in the world. It matters on
		-- Ashfall, which destroys and rebuilds its whole island folder: a dock
		-- parented to the workspace would outlive the pad it belongs to.
		parent = pad.Parent or workspace,
	}), true
end

--------------------------------------------------------------------------
-- THE SWEEP
--------------------------------------------------------------------------
--[[
	HOW LONG TO WAIT BEFORE BUILDING BESIDE A PAD THAT TURNS UP LATE.

	CarSpawnerBuilder tags a pad the instant it is parented to the workspace, and
	the island builders then RENAME it and REPARENT it into their own folder --
	Island3 to Market, Island4 to Landing. Acting on the tag immediately would
	name the dock "CarSpawnerHome" and leave it parented to the workspace, which
	is the one arrangement that outlives the pad on Ashfall.

	A second and a half is far more than either builder takes to finish that, and
	nothing is waiting on it: the dock is scenery until somebody walks up to it.
]]
local LATE = 1.5

local watching = false

--[[
	ONE DOCK PER CAR SPAWNER, EVERY ISLAND, AND THEN KEEP WATCHING.

	The sweep is not enough on its own, and the reason is worth stating: this
	runs from SandbotService.start(), which is the last line of ServerMain -- and
	the islands are not all finished by then. The log order at boot is
	ServerMain, THEN the dunes, the vault, the cove, Ashfall and the ferry, all
	from CTB_Server's own pass.

	Three of the four pads are standing by the time this runs (the beach's and
	the two hand-built islands' are adopted straight out of the place file), and
	Island4Builder then destroys and rebuilds ITS island wholesale -- taking its
	car pad, and the dock this sweep put beside it, with it. The tag watcher is
	what gives Ashfall its dock back, and what would give a fifth island one
	without anybody coming back to this file.

	Idempotent by construction: claimedBy means a second call over the same world
	builds nothing.
]]
function SandbotDockBuilder.ensureAll(): (number, number)
	assert(RunService:IsServer(), "[SandbotDockBuilder] server-only")

	local pads = CollectionService:GetTagged(CAR_TAG)
	local standing = 0
	for _, pad in pads do
		-- pcall per pad: one island's pad being an odd shape must not cost every
		-- other island its dock.
		local ok, dock = pcall(SandbotDockBuilder.ensureFor, pad)
		if not ok then
			warn("[SandbotDock] " .. pad.Name .. " threw: " .. tostring(dock))
		elseif dock then
			standing += 1
		end
	end

	if not watching then
		watching = true
		CollectionService:GetInstanceAddedSignal(CAR_TAG):Connect(function(pad)
			task.delay(LATE, function()
				-- It may have been destroyed again in the meantime; Island4 is
				-- rebuilt from source and nothing promises it only happens once.
				if pad.Parent then
					local ok, err = pcall(SandbotDockBuilder.ensureFor, pad)
					if not ok then
						warn("[SandbotDock] late pad threw: " .. tostring(err))
					end
				end
			end)
		end)
	end

	return standing, #pads
end

return SandbotDockBuilder
