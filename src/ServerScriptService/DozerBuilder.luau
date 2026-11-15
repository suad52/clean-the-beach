--[[
	DozerBuilder  --  ServerScriptService.DozerBuilder

	Builds the Sandhog D10, tier 3 of the car spawner. AtvBuilder's opposite
	number: same contract, same output, different provenance.

	THE SHELL IS A TOOLBOX IMPORT. THE MACHINE IS NOT.
	--------------------------------------------------
	The tracks, hood, blade, ripper and exhaust come from Creator Store asset
	14401582209, normalised once into ServerStorage.Vehicles.Dozer. What arrived
	with it -- 18 LocalScripts, 6 Scripts, 3 ModuleScripts, 4 RemoteEvents, two
	ScreenGuis of dashboard, a VehicleSeat and its whole suspension rig -- was
	stripped before it was stored. Nothing the uploader wrote runs in this game.
	Everything that MOVES this machine is in AtvServer, and everything a driver
	touches is built below.

	WHAT NORMALISING FIXED, so the numbers here make sense:
		* forward is +Z, like every frontage and every vehicle in this game.
		  The import faced +X.
		* 16 studs nose to ripper, down from 29. A CAT at native scale is a
		  building parked on the beach.
		* the pivot is the GROUND under the tracks, not the box centre -- so the
		  pad's SpawnPoint drops a dozer exactly the way it drops the truck.
		* the cab came off. At 16 studs its interior is 2.3 x 2.6 x 1.9 and a
		  seated character is about 2 x 2 x 3, so any seat inside put the
		  driver's head through a solid mesh roof. Scaling up does not fix that,
		  it just makes a 25 stud bulldozer with the same clipping. The bare
		  deck it left is what the operator's station below stands on.

	HOW IT IS PUT TOGETHER  --  the same shape as AtvBuilder
	-------------------------------------------------------
	One `Chassis` part is the entire physics body: the only thing that collides,
	with everything else welded to it and CanCollide false. Real track physics
	on an imported mesh is a good way to watch nine tons cartwheel into the sea.

	The one exception is the BLADE, which hangs off a Motor6D instead of a weld
	so the drive can drop it when you push and lift it when you back off. A
	WeldConstraint cannot be animated; a Motor6D is the joint that can.

	WHAT AtvServer LOOKS UP BY NAME
		Chassis      : BasePart    -- the body. Network owner, weld root.
		Seat         : VehicleSeat -- occupancy and Throttle/Steer input
		Blade        : BasePart    -- the blade, on BladeMotor
		ScoopFill    : BasePart    -- the heap banked against the blade
		Fill         : BasePart    -- cargo in the skip
		BladeMotor   : Motor6D     -- drop/lift, driven from the throttle
		BladeSpray   : ParticleEmitter -- sand off the cutting edge
		TrackDust    : ParticleEmitter -- two, one per track
]]

local ServerStorage = game:GetService("ServerStorage")

-- For buildFill. The three wheeled machines and this one draw their loads with
-- the same lumps in the same order, and two copies of that would drift.
local AtvBuilder = require(script.Parent:WaitForChild("AtvBuilder"))

local DozerBuilder = {}

DozerBuilder.TemplateFolder = "Vehicles"
DozerBuilder.TemplateName = "Dozer"

-- The game's own sand-dust texture -- CTB_Client, Island2Builder and Island3
-- all raise sand with this one, and a fourth choice here would be a fourth
-- kind of sand on the same beach.
local SAND_TEX = "rbxasset://textures/particles/smoke_main.dds"
local SAND_LIGHT = Color3.fromRGB(226, 205, 158)
local SAND_DARK = Color3.fromRGB(186, 160, 112)

local STEEL = Color3.fromRGB(150, 156, 166)
local PLASTIC = Color3.fromRGB(32, 34, 38)
local SEATC = Color3.fromRGB(24, 24, 26)
local CANVAS = Color3.fromRGB(246, 242, 230)

--[[
	MEASURED OFF THE NORMALISED TEMPLATE, in its own local frame where y = 0 is
	the sand under the tracks and +Z is forward. Written down rather than probed
	at build time because a build that silently re-measures a template someone
	has since edited puts the driver's seat somewhere surprising -- if the shell
	changes, these want changing WITH it, visibly.

		deck top      5.55   the flat behind the hood, where the cab used to be
		blade centre  (0, 2.62, 6.55), 9.83 x 3.88 x 2.26
		track outers  x = +/- 3.54, running z -4.1 .. 4.2
]]
--[[
	ONE NUMBER RESIZES THE MACHINE, exactly as AtvBuilder.RIGS[kind].scale does.
	Every measurement below was taken off the shell at its FIRST normalised size
	(16 studs nose to ripper); the shell in ServerStorage has since been scaled
	up because a Roblox character is 5 studs tall and chunky, and at realistic
	vehicle scale the machines were smaller than the people driving them.

	This MUST match the factor the shell was scaled by.

	Two things deliberately do NOT take it: the seat and CANOPY_CLEAR. Those are
	sized to a character, and a character does not grow with the truck.
]]
local S = 1.45

local DECK_TOP = 5.55 * S
local BLADE_NAME = "Blade"

-- The collider. Sized to the TRACK FOOTPRINT, not the machine: the blade
-- overhangs the front by four studs and the ripper the back by three, and a
-- box that included them would ground the dozer on slopes its tracks are
-- nowhere near. Its underside sits a little under the top of the tracks, so
-- the machine beds into soft sand instead of perching on it.
local CHASSIS_W, CHASSIS_H, CHASSIS_D = 7.0 * S, 1.8 * S, 9.0 * S
local CHASSIS_Y = 1.8 * S

--[[
	THE HEAP THE BLADE IS PUSHING  --  this machine's scoop.

	The wheeled machines catch litter in a net and it visibly sits there. A
	dozer has no net, and pretending the skip on its back fills straight off the
	beach is what made collection read as teleporting: the blade, which is the
	part of this machine the driver is looking at, showed nothing at all.

	So the blade banks a heap in front of itself, and that heap IS the scoop --
	it fills as you push, then tips back into the skip. Which is also just what
	a dozer does, and what CTB's own sifter already does with sand.

	Measured off the shell: the blade is 9.83 x 3.88 wide and deep, centred at
	(0, 2.62, 6.55), so its front face is at z 7.68 and its cutting edge at
	y 0.68. The heap is CENTRED ON THAT FACE rather than sitting out in front of
	it -- a dozer blade is concave and carries its material in the bowl, and a
	first pass that put the heap wholly ahead of the face left three studs of
	daylight between the blade and the thing it was supposed to be pushing.

	Its underside is just under the cutting edge, which reads as material being
	scraped up. An earlier pass had it a full stud lower, which reads instead as
	litter the machine is driving straight over.
]]
local HEAP_W, HEAP_H, HEAP_D = 8.6 * S, 1.80 * S, 2.0 * S
local HEAP_Y, HEAP_Z = 1.40 * S, 7.80 * S

-- The operator's station, bottom to top. Written out because each of these is
-- measured against the next -- the canopy has to clear a seated character's
-- head, and the seat has to clear the deck -- and a stack of magic offsets
-- buried in the build is how a layout stops being adjustable.
local FLOOR_Y = DECK_TOP + 0.11 * S
local SEAT_Y = FLOOR_Y + 0.46
local SEAT_Z = -1.10 * S
local CANOPY_CLEAR = 3.30      -- seat surface to canopy underside. A HEAD, not a truck.
local CANOPY_Y = SEAT_Y + 0.35 + CANOPY_CLEAR

function DozerBuilder.template(): Model?
	local folder = ServerStorage:FindFirstChild(DozerBuilder.TemplateFolder)
	local model = folder and folder:FindFirstChild(DozerBuilder.TemplateName)
	if model and model:IsA("Model") then
		return model
	end
	return nil
end

function DozerBuilder.build(tier, pivot: CFrame): Model
	local template = DozerBuilder.template()
	assert(template, "[DozerBuilder] ServerStorage." .. DozerBuilder.TemplateFolder
		.. "." .. DozerBuilder.TemplateName .. " is missing -- the dozer shell is not in the place")

	local model = Instance.new("Model")
	model.Name = "Veh_" .. tier.key

	local function part(props): BasePart
		local p = Instance.new(props.ClassName or "Part")
		props.ClassName = nil
		p.Anchored = false
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		local offset = props.Offset
		props.Offset = nil
		for k, v in props do
			p[k] = v
		end
		p.CFrame = pivot * offset
		p.Parent = model
		return p
	end

	------------------------------------------------------------------
	-- CHASSIS  --  the only thing that collides
	------------------------------------------------------------------
	local chassis = part({
		Name = "Chassis",
		Size = Vector3.new(CHASSIS_W, CHASSIS_H, CHASSIS_D),
		Transparency = 1,
		CanCollide = true,
		Offset = CFrame.new(0, CHASSIS_Y, 0),
	})
	-- Light, and slippery. The whole assembly is nine tons of imported mesh by
	-- volume and none of that is doing any work: the drive is velocity-based,
	-- so mass only ever shows up as something for ground friction to fight and
	-- as a shove for any character it touches. AtvBuilder's chassis carries the
	-- same properties for the same reason.
	chassis.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.1, 0, 1, 1)

	------------------------------------------------------------------
	-- THE SHELL
	------------------------------------------------------------------
	local shell = template:Clone()
	local blade = nil
	for _, p in shell:GetChildren() do
		if p:IsA("BasePart") then
			p.Anchored = false
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			-- Near weightless. These are scenery bolted to the collider above;
			-- left at mesh density they roughly quadruple the assembly's mass
			-- for nothing gained.
			p.CustomPhysicalProperties = PhysicalProperties.new(0.05, 0.3, 0, 1, 1)
			p.CFrame = pivot * p.CFrame
			if p.Name == BLADE_NAME then
				blade = p
			end
			p.Parent = model
		end
	end
	shell:Destroy()

	------------------------------------------------------------------
	-- THE OPERATOR'S STATION  --  where the cab was
	------------------------------------------------------------------
	-- A floor first: the deck under it is three overlapping meshes with a seam
	-- down the middle, and a seat welded straight onto that reads as furniture
	-- balanced on a lorry.
	part({
		Name = "Floor",
		Size = Vector3.new(4.6 * S, 0.22 * S, 4.3 * S),
		Color = PLASTIC,
		Material = Enum.Material.DiamondPlate,
		Offset = CFrame.new(0, FLOOR_Y, -0.75 * S),
	})

	local seat = part({
		ClassName = "VehicleSeat",
		Name = "Seat",
		Size = Vector3.new(2.2, 0.7, 2.3),
		Color = SEATC,
		Material = Enum.Material.Fabric,
		CanCollide = true,
		CanQuery = true,
		CanTouch = true,
		-- The seat must not drive the body itself: AtvServer owns the driving,
		-- and a VehicleSeat torquing a chassis it has no wheels for only fights
		-- the constraints.
		MaxSpeed = 0,
		Torque = 0,
		TurnSpeed = 0,
		-- ROBLOX'S OWN SPEEDOMETER, OFF -- same reason as AtvBuilder's seat: the
		-- stock gauge reads MaxSpeed, which is 0 on every machine in this game,
		-- so it sat under DriveHud saying nothing in somebody else's font.
		HeadsUpDisplay = false,
		-- TURNED 180. A character faces its seat's LookVector, and LookVector is
		-- a CFrame's NEGATIVE Z axis, while this machine's nose is +Z -- so an
		-- unturned seat sits the driver facing back over the ripper while the
		-- blade goes the other way. The seat back, the console and the levers are
		-- all placed around a driver looking at the blade and needed no change.
		Offset = CFrame.new(0, SEAT_Y, SEAT_Z) * CFrame.Angles(0, math.pi, 0),
	})
	part({
		Name = "SeatBack",
		Size = Vector3.new(2.2, 1.4, 0.4),
		Color = SEATC,
		Material = Enum.Material.Fabric,
		Offset = CFrame.new(0, SEAT_Y + 0.9, SEAT_Z - 1.15),
	})
	-- The deck is far wider than a driver now, so the station gets a plinth to
	-- stand the seat on rather than a chair adrift on a flatbed.
	part({
		Name = "SeatPlinth",
		Size = Vector3.new(2.9, 0.5, 3.0),
		Color = PLASTIC,
		Material = Enum.Material.Metal,
		Offset = CFrame.new(0, SEAT_Y - 0.5, SEAT_Z - 0.2),
	})

	-- Console and two track levers. A tracked machine is steered by its
	-- levers, one per track, and they are the clearest thing you can put in
	-- front of a driver that says this is not a quad with a steering wheel.
	part({
		Name = "Console",
		Size = Vector3.new(3.0, 0.6, 0.7),
		Color = tier.accent,
		Material = Enum.Material.Metal,
		Offset = CFrame.new(0, SEAT_Y + 0.5, SEAT_Z + 2.3),
	})
	for _, sx in { -1, 1 } do
		part({
			Name = "Lever",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1.6, 0.22, 0.22),
			Color = STEEL,
			Material = Enum.Material.Metal,
			Offset = CFrame.new(sx * 0.85, SEAT_Y + 1.2, SEAT_Z + 2.1)
				* CFrame.Angles(math.rad(24), 0, math.rad(90)),
		})
		part({
			Name = "LeverGrip",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(0.42, 0.42, 0.42),
			Color = PLASTIC,
			Material = Enum.Material.SmoothPlastic,
			Offset = CFrame.new(sx * 0.85, SEAT_Y + 1.9, SEAT_Z + 1.82),
		})
	end

	------------------------------------------------------------------
	-- CANOPY  --  a sunshade, because this is a beach
	------------------------------------------------------------------
	-- Four posts and a striped awning, the same red-and-cream slats the wash
	-- bay and the Beach Shop wear. A bare rollbar would have done the job of
	-- clearing the driver's head; this one also makes a stock CAT look like it
	-- belongs to this beach rather than to a building site.
	local postH = CANOPY_Y - FLOOR_Y
	for _, sx in { -1, 1 } do
		for _, sz in { 1.6, -3.0 } do
			part({
				Name = "CanopyPost",
				Size = Vector3.new(0.3, postH, 0.3),
				Color = tier.accent,
				Material = Enum.Material.Metal,
				Offset = CFrame.new(sx * 2.3, FLOOR_Y + postH * 0.5, SEAT_Z + sz),
			})
		end
	end
	part({
		Name = "CanopyFrame",
		Size = Vector3.new(5.2, 0.22, 5.2),
		Color = tier.accent,
		Material = Enum.Material.Metal,
		Offset = CFrame.new(0, CANOPY_Y + 0.11, SEAT_Z - 0.7),
	})
	for i = 0, 5 do
		part({
			Name = "CanopySlat",
			Size = Vector3.new(5.4, 0.18, 0.88),
			Color = (i % 2 == 0) and CANVAS or Color3.fromRGB(214, 74, 64),
			Material = Enum.Material.Fabric,
			Offset = CFrame.new(0, CANOPY_Y + 0.3, SEAT_Z - 3.0 + i * 0.88),
		})
	end
	-- Beacon on the canopy, because the one thing a machine this size owes the
	-- people walking round it is being visible.
	part({
		Name = "Beacon",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(0.7, 0.62, 0.7),
		Color = Color3.fromRGB(255, 176, 40),
		Material = Enum.Material.Neon,
		Offset = CFrame.new(0, CANOPY_Y + 0.7, SEAT_Z - 2.6),
	})

	------------------------------------------------------------------
	-- THE SKIP  --  where nine hundred pounds of beach goes
	------------------------------------------------------------------
	-- Behind the canopy and above the ripper, which is the only part of this
	-- machine with nothing already on it. A dozer has no bed and no hopper, so
	-- rather than pretend the blade holds the load, it gets a skip bolted to the
	-- back -- which is what the shop's blurb promises and what a real one would
	-- have if it were doing this job.
	local SKIP_Y, SKIP_Z = 4.60 * S, -4.70 * S
	local SKIP_W, SKIP_D, SKIP_H = 5.8 * S, 3.6 * S, 1.9 * S
	part({
		Name = "SkipFloor",
		Size = Vector3.new(SKIP_W, 0.22, SKIP_D),
		Color = tier.accent,
		Material = Enum.Material.DiamondPlate,
		Offset = CFrame.new(0, SKIP_Y, SKIP_Z),
	})
	for _, side in { { SKIP_W, 0.2, 0, (SKIP_D - 0.2) * 0.5 }, { SKIP_W, 0.2, 0, -(SKIP_D - 0.2) * 0.5 },
	                 { 0.2, SKIP_D, (SKIP_W - 0.2) * 0.5, 0 }, { 0.2, SKIP_D, -(SKIP_W - 0.2) * 0.5, 0 } } do
		part({
			Name = "SkipWall",
			Size = Vector3.new(side[1], SKIP_H, side[2]),
			Color = tier.accent,
			Material = Enum.Material.Metal,
			Offset = CFrame.new(side[3], SKIP_Y + SKIP_H * 0.5, SKIP_Z + side[4]),
		})
	end
	-- Two struts down to the deck, so it is carried rather than hovering.
	for _, sx in { -1, 1 } do
		part({
			Name = "SkipStrut",
			Size = Vector3.new(0.26 * S, 1.5 * S, 0.26 * S),
			Color = tier.accent,
			Material = Enum.Material.Metal,
			Offset = CFrame.new(sx * 2.2 * S, SKIP_Y - 0.75 * S, SKIP_Z + 1.2 * S),
		})
	end

	AtvBuilder.buildFill(part, {
		x = 0, y = SKIP_Y + SKIP_H * 0.5 + 0.1 * S, z = SKIP_Z,
		w = SKIP_W - 0.6 * S, h = SKIP_H, d = SKIP_D - 0.6 * S, rows = 6,
	})

	-- ...and what is banked against the blade on its way there. Three rows, a
	-- scoopful, and welded to the chassis rather than to the blade: the blade
	-- rides up and down under power and a heap of loose material on the sand
	-- does not go up with it.
	-- perRow 5, not the cargo box's 3: a third of a twelve stud blade is a four
	-- stud lump, and half a stud tall that is a plank rather than a piece of
	-- rubbish. See buildFill.
	AtvBuilder.buildFill(part, {
		x = 0, y = HEAP_Y, z = HEAP_Z,
		w = HEAP_W, h = HEAP_H, d = HEAP_D, rows = 3, perRow = 5,
	}, "ScoopFill")

	------------------------------------------------------------------
	-- FX  --  what a nine ton machine leaves behind it
	------------------------------------------------------------------
	-- All start disabled. AtvServer turns them on when the machine is actually
	-- working, which is the difference between a bulldozer and a hair dryer.
	local function emitter(parent: BasePart, name: string, offset: CFrame, opts): ParticleEmitter
		local att = Instance.new("Attachment")
		att.Name = name .. "At"
		att.CFrame = parent.CFrame:ToObjectSpace(pivot * offset)
		att.Parent = parent

		local e = Instance.new("ParticleEmitter")
		e.Name = name
		e.Texture = SAND_TEX
		e.Color = ColorSequence.new(SAND_LIGHT, SAND_DARK)
		-- Fade in, hold, fade out. `rise` is how quickly it reaches full: sand
		-- thrown by a blade is at its densest almost immediately, dust behind a
		-- track billows up over a moment.
		e.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(opts.rise or 0.18, opts.peak),
			NumberSequenceKeypoint.new(1, 1),
		})
		e.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, opts.size0),
			NumberSequenceKeypoint.new(1, opts.size1),
		})
		e.Lifetime = NumberRange.new(opts.life0, opts.life1)
		e.Rate = opts.rate
		e.Speed = NumberRange.new(opts.speed0, opts.speed1)
		e.SpreadAngle = Vector2.new(opts.spread, opts.spread)
		e.Rotation = NumberRange.new(0, 360)
		e.RotSpeed = NumberRange.new(-40, 40)
		e.Acceleration = Vector3.new(0, -12, 0)
		e.LightEmission = 0.15
		e.Enabled = false
		e.Parent = att
		return e
	end

	--[[
		THE SPRAY GOES WHERE SAND ACTUALLY LEAVES A BLADE, WHICH IS NOT THE
		MIDDLE OF IT.

		The first version emitted from a single point on the cutting edge, at
		(0, 0.9, 7.5). The blade's front face is at z = 7.68 and it is a big
		concave mesh, so that point is a fifth of a stud INSIDE it: every
		particle spawned behind nine studs of solid blade and the only ones that
		ever reached the camera were the few that fell out underneath. On screen
		it was four specks.

		A blade under load does two visible things instead. Sand rolls UP the
		curved face and curls over the top, and it spills off both ENDS, which is
		the part you can always see because nothing is in front of it. So: one
		emitter clear of the top edge and one at each end, tilted outward.
	]]
	if blade then
		-- Peak 0.12, not 0.28. Pale sand thrown against a bright beach is a
		-- low-contrast subject to begin with, and at the first values the spray
		-- was invisible in play at any angle -- technically emitting, and no
		-- use. These are the numbers that read from the seat.
		emitter(blade, "BladeSpray", CFrame.new(0, 1.5 * S, 8.6 * S), {
			peak = 0.12, rise = 0.15, size0 = 1.8, size1 = 5.2, life0 = 0.35, life1 = 0.8,
			rate = 72, speed0 = 6, speed1 = 14, spread = 55,
		})
		for _, sx in { -1, 1 } do
			-- Rotated about Z so the emitter's own +Y -- the direction a
			-- ParticleEmitter throws -- leans outward and up, away from the
			-- machine. Straight up would put both plumes back over the blade.
			emitter(blade, "BladeSpray",
				CFrame.new(sx * 4.4 * S, 1.2 * S, 7.8 * S) * CFrame.Angles(0, 0, math.rad(-52) * sx), {
					peak = 0.12, rise = 0.15, size0 = 1.5, size1 = 4.6, life0 = 0.4, life1 = 0.9,
					rate = 61, speed0 = 7, speed1 = 15, spread = 38,
				})
		end
	end
	-- Kicked up behind each track. Quieter, and on whenever the thing is
	-- moving at all -- tracks throw sand whether or not the blade is loaded.
	for _, sx in { -1, 1 } do
		-- Thinner than the blade's, and it stays that way. This is the plume the
		-- driver actually looks at -- the default camera is behind the machine --
		-- so it is the one that would read as smoke if it were pushed any harder.
		emitter(chassis, "TrackDust", CFrame.new(sx * 2.9 * S, 0.5 * S, -4.0 * S), {
			peak = 0.38, size0 = 1.1, size1 = 3.4, life0 = 0.4, life1 = 0.95,
			rate = 22, speed0 = 2, speed1 = 6, spread = 34,
		})
	end

	------------------------------------------------------------------
	-- JOIN IT ALL UP
	------------------------------------------------------------------
	-- Everything is rigidly welded to the chassis EXCEPT the blade. A
	-- WeldConstraint holds two parts where they are and offers nothing to
	-- animate, so the blade gets a Motor6D: same rigid attachment, but its C0
	-- can be written every frame, which is how AtvServer drops it into the sand
	-- under power and lifts it clear when you back off.
	--
	-- The joint sits on the blade's TOP REAR EDGE, where the ram arms meet it.
	-- Hinging anywhere else swings the blade away from the arms that are
	-- supposed to be holding it.
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") and p ~= chassis and p ~= blade then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = chassis
			weld.Part1 = p
			weld.Parent = chassis
		end
	end

	if blade then
		local hinge = pivot * CFrame.new(0, 4.40 * S, 5.45 * S)
		local motor = Instance.new("Motor6D")
		motor.Name = "BladeMotor"
		motor.Part0 = chassis
		motor.Part1 = blade
		motor.C0 = chassis.CFrame:ToObjectSpace(hinge)
		motor.C1 = blade.CFrame:ToObjectSpace(hinge)
		motor.Parent = chassis
		-- AtvServer reads this C0 once on spawn and keeps it as the rest pose, so
		-- every frame after that is one multiply off a known-good joint rather
		-- than a joint rebuilt from world positions that are already moving.
	end

	model.PrimaryPart = chassis
	model:SetAttribute("Tier", tier.id)
	model:SetAttribute("NetRadius", tier.netRadius)
	model:SetAttribute("Hold", tier.hold or 0)
	-- The blade IS the sweep on this machine, so the raked lane is exactly as
	-- wide as the blade. See AtvBuilder for why that matters.
	model:SetAttribute("SweepWidth", blade and blade.Size.X or (9.83 * S))
	-- And how far it runs fore and aft, so the sand goes where the CUTTING EDGE
	-- is rather than eleven studs back under the tracks. Measured with
	-- AtvBuilder's helper so both builders answer this the same way; the blade is
	-- at its rest pose here, which is the pose the band is sized for.
	local ahead, back = AtvBuilder.sweepSpan(model, chassis)
	model:SetAttribute("SweepAhead", ahead)
	model:SetAttribute("SweepBack", back)
	return model
end

return DozerBuilder
