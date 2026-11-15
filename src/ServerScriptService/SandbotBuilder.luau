--[[
	SandbotBuilder  --  ServerScriptService.SandbotBuilder

	What the sandbot LOOKS like. One function, one table of numbers, and
	nothing in here knows what the drone does -- SandbotService owns that.

	WHY IT IS BUILT AND NOT IMPORTED
	--------------------------------
	The toolbox was searched first, which is the rule for props in this place.
	There is no shortage of sandbots on the Creator Store and not one of them is
	usable here: they are photoreal 13-inch appliances or joke models (a
	"Teleporting Explosive Knife Sandbot" was the second result), and dropping a
	grey plastic disc onto a beach whose every object is a saturated cartoon
	with a thick dark outline reads as an asset from another game. Half of the
	free ones also ship a require() backdoor.

	The machines this game already has are built rather than imported for the
	same reason AtvBuilder gives about the scoop -- "no toolbox vehicle comes
	with the thing this game is about" -- and a drone with sand brushes on it is
	that again.

	THE RECIPE, and it is the same four cues PanelKit lists for a button,
	translated into parts:

	  1. A DARK RIM disc a shade wider than the body. This is the thick outline;
	     it is what stops a coloured cylinder reading as a coloured cylinder.
	  2. SATURATED body colour, straight out of PanelKit's palette, so the drone
	     belongs to the same set as every button the player has been pressing.
	  3. A PALE LID stepped in and up, which is the gloss cap in three dimensions
	     -- the light face on top that says "toy plastic".
	  4. A FACE. Two eyes on the nose. It is a machine the player sends out alone
	     and watches from a distance, and a thing with a face is a thing you
	     look for.

	WHAT SandbotService LOOKS UP BY NAME
		Hull    : BasePart -- invisible. The root, the ONLY anchored part, and
		                     the only one whose CFrame is ever written. Nose = +Z.
		Lamp    : BasePart -- the status light. Its Color is the drone's state.
		BrushL  : BasePart -- the two side brushes, each on a Motor6D so a client
		BrushR  : BasePart    can spin them without a single replicated write.
		Bobble  : BasePart -- the aerial tip, bobbed client-side.
		Dust    : ParticleEmitter -- kicked up while it is working.

	EVERYTHING IS CanCollide FALSE, INCLUDING THE HULL, and that is a decision
	rather than an oversight. The drone is driven by writing a CFrame, so it has
	no momentum to give anybody; a solid one would shove the player who bought
	it off their own rake line, and would itself wedge against deckchairs. It
	CANNOT knock a player into the sea because it cannot touch them at all.
]]

local ServerStorage = game:GetService("ServerStorage")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SandbotConfig = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("SandbotConfig"))

local SandbotBuilder = {}

SandbotBuilder.TemplateName = "SandbotTemplate"

----------------------------------------------------------------
-- PALETTE
----------------------------------------------------------------
--[[
	PanelKit's own colours, typed out rather than required.

	PanelKit is a UI kit that pulls in TweenService and builds GuiObjects; this
	is a server module that builds parts, and requiring a whole drawing library
	to read five Color3s would put the UI kit on the server's boot path for no
	reason. They are copied WITH THEIR NAMES so a later palette change is
	greppable rather than a set of anonymous RGB triples.

	BLUE ON YELLOW is the choice worth recording: the beach is 203,177,106 sand
	under a Brightness 3.1 sun, so a sand-coloured or white drone disappears
	into it at any distance. `sea` is the palette's furthest colour from that,
	which is what makes a 5 stud object findable across a 256 stud field.
]]
local SEA      = Color3.fromRGB(64, 168, 240)
local SEA_DARK = Color3.fromRGB(28, 104, 176)
local SAND     = Color3.fromRGB(255, 240, 205)
local SUN      = Color3.fromRGB(255, 200, 62)
local INK      = Color3.fromRGB(30, 42, 56)      -- the outline, near-black navy
local WHITE    = Color3.fromRGB(255, 255, 255)

local SMOOTH = Enum.Material.SmoothPlastic

----------------------------------------------------------------
-- PRIMITIVES
----------------------------------------------------------------
local function part(parent: Instance, name: string, size: Vector3, cf: CFrame,
	colour: Color3, material: Enum.Material?): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = colour
	p.Material = material or SMOOTH
	p.Anchored = false          -- welded to the Hull; only the Hull is anchored
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false        -- see the shadow note at the foot of build()
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

--[[
	A DISC LYING FLAT, and the two traps in one line of code.

	A cylinder's LENGTH is Size.X; the other two axes are its circular cross
	section. So a disc is (thickness, diameter, diameter) -- pass (d, t, d) and
	you get a wheel standing on its edge, which is the bug that cost the AFK
	shore two passes over its parasols.

	Standing it up is a rotation of +90 about Z, which sends local X to world Y.
	ANY OTHER ROTATION MUST BE APPLIED AFTER IT -- the two do not commute, and
	the other order lays the disc flat again.
]]
local function disc(parent: Instance, name: string, diameter: number, thick: number,
	at: Vector3, colour: Color3, material: Enum.Material?): BasePart
	local p = part(parent, name, Vector3.new(thick, diameter, diameter),
		CFrame.new(at) * CFrame.Angles(0, 0, math.pi * 0.5), colour, material)
	p.Shape = Enum.PartType.Cylinder
	return p
end

-- The same disc turned to face down the nose (+Z), for the eyes. Local X goes
-- to world Z, so the rotation is about Y instead.
local function facing(parent: Instance, name: string, diameter: number, thick: number,
	at: Vector3, colour: Color3, material: Enum.Material?): BasePart
	local p = part(parent, name, Vector3.new(thick, diameter, diameter),
		CFrame.new(at) * CFrame.Angles(0, math.pi * 0.5, 0), colour, material)
	p.Shape = Enum.PartType.Cylinder
	return p
end

local function ball(parent: Instance, name: string, diameter: number, at: Vector3,
	colour: Color3, material: Enum.Material?): BasePart
	local p = part(parent, name, Vector3.new(diameter, diameter, diameter),
		CFrame.new(at), colour, material)
	p.Shape = Enum.PartType.Ball
	return p
end

local function weld(root: BasePart, piece: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = root
	w.Part1 = piece
	w.Parent = piece
end

----------------------------------------------------------------
-- THE BRUSHES
----------------------------------------------------------------
--[[
	THE WIDEST THING ON THE DRONE, AND THE REASON SandbotConfig.Sweep IS 8.4.

	A hub at x = +-2.65 with blades reaching 1.55 spans 8.4 studs tip to tip,
	which is exactly what the rake band is set to. If these move, that number
	moves with them -- CTB_Server's own note records what a band wider than the
	machine looks like: sand going clean three studs to the side of a machine
	that visibly never went near it.

	FOUR BLADES, NOT MORE. They spin, and past about five a spinning disc of
	thin boxes stops reading as separate bristles and starts strobing.

	ON A Motor6D rather than a WeldConstraint. The joint is what lets a client
	spin them by writing C0 locally -- a local write to a server-owned instance
	applies on that machine and replicates nowhere, so eight drones cost the
	network nothing at all for the one cue that says this thing is cleaning.
]]
local BLADE_REACH = 1.55
local BLADES = 4

local function brush(model: Model, root: BasePart, name: string, at: Vector3)
	local hub = disc(model, name, 0.80, 0.55, at, INK)

	for i = 1, BLADES do
		local a = (i - 1) * (math.pi * 2 / BLADES)
		-- Out along the hub's own plane, which is the world XZ plane: the hub is
		-- flat, so a blade is placed by yawing about Y and stepping out in Z.
		-- Centred at half its own length, so the TIP lands exactly BLADE_REACH from
		-- the hub. Any gap added here widens the drone's real span past
		-- SandbotConfig.Sweep and puts the rake band outside the brushes again.
		local cf = CFrame.new(at) * CFrame.Angles(0, a, 0)
			* CFrame.new(0, 0, BLADE_REACH * 0.5)
		-- Tapered: wider at the hub, so the blade reads as a swept bristle rather
		-- than a lolly stick. One part each, because four of them are spinning.
		-- 0.50 wide, not 0.34. Thinner than this and four of them spinning read as
		-- a flicker of white sticks rather than as a brush turning.
		local blade = part(model, name .. "Blade", Vector3.new(0.50, 0.20, BLADE_REACH), cf, SAND)
		weld(hub, blade)
	end

	local motor = Instance.new("Motor6D")
	motor.Name = "Spin"
	motor.Part0 = root
	motor.Part1 = hub
	-- C0/C1 in each part's own frame, so the joint's rest pose is exactly where
	-- the pieces were built. The client spins by post-multiplying a yaw onto C0,
	-- and needs this rest value to spin ABOUT the hub rather than swing it.
	motor.C0 = root.CFrame:ToObjectSpace(hub.CFrame)
	motor.C1 = CFrame.new()
	motor.Parent = root
	return hub
end

----------------------------------------------------------------
-- THE DRONE
----------------------------------------------------------------
function SandbotBuilder.build(): Model
	local D = SandbotConfig.Hull            -- 5.2, the body diameter
	local H = SandbotConfig.Height

	local model = Instance.new("Model")
	model.Name = "Sandbot"

	--[[
		THE HULL IS INVISIBLE AND IT IS THE WHOLE MACHINE.

		Same shape AtvBuilder uses -- an invisible box that is the collider and
		the weld root, with the visible shell hung off it -- and for the same
		reason: it means every offset below is measured in one frame whose +Z is
		the nose and whose y = 0 is the middle of the body, rather than in
		whatever frame a rotated cylinder happens to have.

		It is also the ONLY anchored part. SandbotService writes this CFrame and
		nothing else; the rest of the drone is welded and comes along for free.
	]]
	local hull = part(model, "Hull", Vector3.new(D, H, D), CFrame.new(), SEA)
	hull.Transparency = 1
	hull.Anchored = true
	model.PrimaryPart = hull

	--[[
		THE STACK, AND WHY EVERY BAND IS THIN EXCEPT THE BODY.

		The first pass made the dark rim H * 0.72 tall and a half stud wider than
		the body, on the theory that a thick outline is what this game's art is
		made of. In three dimensions that is not an outline, it is a SECOND DRUM:
		the rim engulfed the body and left one blue sliver showing, so the drone
		read as a black tyre with a lid on it -- and the eyes, which sat inside
		the rim's radius, disappeared into it completely.

		The outline has to be a LIP, not a layer. One dark band flush with the
		underside and one at the waist, both thin, with the body carrying the
		whole middle of the silhouette. Everything below is measured off the hull
		centre with the hull half-height (0.75) as the floor, so the bands can be
		checked against each other by reading down the list.
	]]
	local FLOOR = -H * 0.5                 -- -0.75, the underside

	-- 1. THE SKIRT -- the dark lip the drone sits on, flush with the underside
	--    and a little wider than the body so it reads as an outline from above.
	weld(hull, disc(model, "Skirt", D + 0.30, 0.30, Vector3.new(0, FLOOR + 0.15, 0), INK))

	-- 2. THE BODY -- the mass. It carries the colour, so it gets the height.
	weld(hull, disc(model, "Body", D, 1.05, Vector3.new(0, -0.10, 0), SEA))
	-- A darker band at the waist: one flat colour over five studs is a lot of
	-- unbroken plastic, and this is the cheapest way to give it a shoulder.
	weld(hull, disc(model, "Waist", D + 0.06, 0.22, Vector3.new(0, -0.52, 0), SEA_DARK))

	-- 3. THE LID, stepped in and up. The gloss cap, in parts.
	weld(hull, disc(model, "Trim", D * 0.86, 0.18, Vector3.new(0, 0.47, 0), SUN))
	weld(hull, disc(model, "Lid", D * 0.75, 0.30, Vector3.new(0, 0.66, 0), SAND))

	--[[
		THE LAMP. Neon, and the only Neon on the drone.

		Its colour IS the state -- SandbotConfig.Lamps -- so it has to be the one
		thing on the model that glows, or the state is one bright thing among
		several. SandbotService writes this Color and nothing else about the look.
	]]
	--[[
		A DOME, NOT A DISC, and it is half sunk into the lid.

		A flat neon disc lying on a cream lid is only visible from directly above,
		and directly above is the one angle a player never has -- the camera sits
		behind and a little over the character, looking at a drone that is usually
		driving away. Measured on the first build: the lamp read as a slightly
		paler patch on the lid and nothing else.

		A dome standing 0.6 proud of the lid catches the light on its shoulder
		from every angle down to ground level, which is what a beacon has to do to
		be the readout it is for. The lid's top face is at 0.81, so a 1.25 ball
		centred at 0.86 is buried to just under half its height.
	]]
	local lamp = ball(model, "Lamp", 1.25, Vector3.new(0, 0.86, 0),
		SandbotConfig.Lamps.docked, Enum.Material.Neon)
	weld(hull, lamp)
	-- A dark collar round its foot, so the dome reads as SET INTO the lid rather
	-- than as a ball resting on it.
	weld(hull, disc(model, "LampRing", 1.45, 0.16, Vector3.new(0, 0.80, 0), INK))

	--[[
		4. THE FACE.

		Set into the NOSE rather than on the lid, because the drone is seen from
		behind and above nearly all the time -- it drives away from you -- and a
		face on top would only ever be visible when it came home. On the nose it
		turns to look wherever it is going.

		The pupil is a separate disc a hair PROUD of the white, not flush with
		it: two coplanar faces z-fight, and at this distance that reads as the
		eye flickering.
	]]
	--[[
		THE EYES MUST STAND PROUD OF A ROUND BODY, and that is arithmetic rather
		than taste. The body is a cylinder of radius 2.6, so its surface at x is
		z = sqrt(2.6^2 - x^2) -- at x = 0.85 that is 2.46. An eye centred any
		nearer than that is INSIDE the drone. The first pass put them at 2.30 and
		they vanished.

		2.58 puts the white just clear at that x and its front face at 2.69, and
		the pupil is a further 0.14 out rather than flush: two coplanar faces
		z-fight, and at this distance that reads as the eye flickering.
	]]
	for _, x in { -0.85, 0.85 } do
		weld(hull, facing(model, "Eye", 0.95, 0.22, Vector3.new(x, 0.06, 2.58), WHITE))
		weld(hull, facing(model, "Pupil", 0.46, 0.14, Vector3.new(x, 0.06, 2.72), INK))
	end

	-- The bumper across the nose: a cylinder lying along X, which is a cylinder's
	-- own axis, so this one needs no rotation at all. Its ENDS stick out past a
	-- round body by design -- that is what makes it read as a bar bolted on
	-- rather than as another band of the drone itself.
	local bumper = part(model, "Bumper", Vector3.new(3.40, 0.55, 0.55),
		CFrame.new(0, -0.34, 2.40), INK)
	bumper.Shape = Enum.PartType.Cylinder
	weld(hull, bumper)

	-- 5. THE BRUSHES. See the block above them for why they are 2.65 out.
	-- y = -0.45 puts the blades' underside at -0.725, a hair inside the hull's
	-- own -0.75 floor -- so at SandbotConfig.Hover they skim the sand rather than
	-- ploughing through it or hovering visibly clear of it.
	brush(model, hull, "BrushL", Vector3.new(-2.65, -0.45, 1.50))
	brush(model, hull, "BrushR", Vector3.new(2.65, -0.45, 1.50))

	-- 6. THE BACK END: a grille slot and a bobbing aerial, so the silhouette is
	--    not the same from both ends and you can tell at a glance which way it
	--    is pointing without seeing the face.
	weld(hull, part(model, "Vent", Vector3.new(2.10, 0.14, 0.70),
		CFrame.new(0, 0.82, -1.35), INK))

	local mastY = 1.60
	local mast = disc(model, "Mast", 0.16, 1.60, Vector3.new(0, mastY, -1.45), INK)
	weld(hull, mast)
	-- NOT Neon, deliberately. The Lamp is the drone's readout and it has to be
	-- the only thing on the model that glows -- a second glowing ball is a
	-- second status light that never changes, which is worse than no light.
	local bobble = ball(model, "Bobble", 0.55, Vector3.new(0, mastY + 0.86, -1.45), SUN)
	weld(hull, bobble)

	--[[
		7. THE DUST. Emitters are toggled on the CROSSING by SandbotService, never
		written per tick -- Rate and Enabled are replicated properties, and
		rewriting them every frame is a stream of network traffic saying what the
		previous frame said. AtvServer's spray does the same.

		Parented to the HULL, which is invisible: an emitter does not need a
		visible parent, and hanging it on the rim would emit from a spinning
		cylinder's surface normals rather than from under the middle.
	]]
	local dust = Instance.new("ParticleEmitter")
	dust.Name = "Dust"
	dust.Enabled = false
	dust.Color = ColorSequence.new(Color3.fromRGB(246, 226, 178))
	dust.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 2.2),
	})
	dust.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	dust.Lifetime = NumberRange.new(0.35, 0.7)
	dust.Rate = 22
	dust.Speed = NumberRange.new(1.5, 3.5)
	dust.SpreadAngle = Vector2.new(38, 38)
	dust.Acceleration = Vector3.new(0, -6, 0)
	dust.EmissionDirection = Enum.NormalId.Back      -- -Z: out behind it
	dust.Parent = hull

	--[[
		SHADOWS OFF, EVERY PART, and it is deliberate rather than a default.

		ServerMain runs a shadow pass over the whole home island whose rule is
		"anything under a stud on its smallest axis, anything Neon, anything more
		than half transparent" -- and by that rule most of this model would be
		trimmed anyway. Doing it at build time means a drone that spawns after
		that pass has run (which is all of them -- they spawn on demand) is not
		the one object on the beach still casting twenty separate shadows.

		The drone still reads as sitting on the sand: the rim is dark and the
		brushes touch the surface, which is what grounds a small object. A cast
		shadow at this size is a smudge.
	]]
	return model
end

--[[
	BUILT ONCE INTO ServerStorage AND CLONED PER DEPLOY.

	ServerStorage does not replicate, so the template costs no client anything,
	and cloning is a great deal cheaper than re-running build() -- which is
	twenty-odd Instance.new calls and a set of welds -- every time somebody taps
	the key.

	Idempotent: a second call hands back the template that is already there.
]]
function SandbotBuilder.template(): Model
	local existing = ServerStorage:FindFirstChild(SandbotBuilder.TemplateName)
	if existing and existing:IsA("Model") then
		return existing
	end
	local model = SandbotBuilder.build()
	model.Name = SandbotBuilder.TemplateName
	model.Parent = ServerStorage
	return model
end

return SandbotBuilder
