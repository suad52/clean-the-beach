--[[
	AtvBuilder  --  ServerScriptService.AtvBuilder

	Builds the WHEELED machine in the car spawner -- the sweeper truck. The
	bulldozer has its own builder because it has an operator's station and a
	blade to hang.

	STILL ONE FUNCTION AND A TABLE, with one row in the table. It carried three
	while the shop had a quad and a pickup in it, and the recipe below is why
	those two were ever cheap to add or remove: a wheeled machine is a shell
	name and five boxes of numbers, not a file of its own. The next one is one
	row again.

	THE RECIPE
	----------
		1. an invisible Chassis, the ONLY thing that collides
		2. an imported shell, welded to it and tinted
		3. a VehicleSeat, turned to face the nose
		4. a scoop NET across the front, built rather than imported
		5. a stack of FILL parts inside the cargo box, revealed as it loads

	Real wheel physics on an imported mesh is a good way to watch a truck
	cartwheel into the sea, so nothing here collides but the chassis box.

	THE SHELL IS AN IMPORT. NOTHING ITS UPLOADER WROTE RUNS.
	--------------------------------------------------------
		Sweeper  17613757980  46 scripts, 2 seats

	It was normalised once into ServerStorage.Vehicles: stripped to geometry,
	flattened, turned so forward is +Z, scaled, and stood on its own pivot, so
	the pad's SpawnPoint drops it and the dozer identically.

	Two other shells lived here and their models have been deleted with the tiers
	that used them. The asset ids are kept because they are the only part of
	those machines that cannot be re-derived from this file:

		Quad     1486436878   57 scripts, 3 ScreenGuis, 2 seats, a Sound
		Pickup   6418225759   42 scripts, 12 seats (it shipped as three trucks
		                      on a showcase pad; the white one was the one used)

	THE NET IS NOT IMPORTED, AND THAT IS THE POINT
	----------------------------------------------
	No toolbox vehicle comes with the thing this game is about. The scoop is
	built here, sized per machine, and it is the widest part of every
	silhouette -- and now it visibly FILLS, because the hold behind it is a
	real container rather than a number on the HUD.

	WHAT AtvServer LOOKS UP BY NAME
		Chassis   : BasePart    -- the body. Network owner, weld root.
		Seat      : VehicleSeat -- occupancy and Throttle/Steer input
		Net       : BasePart    -- the scoop
		ScoopFill : BasePart    -- what is IN the scoop, by FillIndex
		Fill      : BasePart    -- cargo in the box, by FillIndex
]]

local ServerStorage = game:GetService("ServerStorage")

local AtvBuilder = {}

AtvBuilder.TemplateFolder = "Vehicles"

local STEEL = Color3.fromRGB(150, 156, 166)
local SEATC = Color3.fromRGB(26, 26, 30)

--[[
	GEOMETRY, PER KIND. Measured off the normalised shells, in their own frame
	where y = 0 is the sand under the tyres and +Z is the nose.

		shell    ServerStorage.Vehicles.<name>, and its size for reference
		seat     where the driver sits. NOT the imported seat's position --
		         every one of these uploaders parked their seat a stud above
		         the bodywork, so those heights hover a rider over the saddle.
		chassis  the collider. Sized to the WHEELBASE, never to the shell: the
		         net hangs studs off the nose and a box that included it would
		         ground the machine on things its tyres are nowhere near.

		         ITS UNDERSIDE IS THE RIDE HEIGHT. The box rests on the sand, so
		         (y - h/2) is exactly how far the machine sinks into it -- these
		         are a quarter to a half stud, enough to bed the tyres in without
		         burying the axles. The first pass had them at 0.6-0.7 and the
		         trucks looked like they were sitting on their bellies.
		net      the scoop. `mouth` is how wide it is DRAWN; the reach is the
		         tier's netRadius and the two are deliberately different -- a
		         net literally spanning 44 studs would be wider than the shop.

		         `y` IS SET SO THE LIP RIDES ON THE SAND. Every machine's
		         collider bottom is at 0.25, so a lip whose underside sits at
		         0.20 is just in the surface. An earlier pass hung these at
		         bumper height to stop them looking like grilles on a rope, and
		         that traded one wrong look for another -- a sweeper floating a
		         stud clear of the beach it is supposed to be sweeping.

		         `mount` is what fixes the original complaint properly: the
		         height on the machine that the stays run UP to, so the scoop is
		         visibly bolted to the bodywork while still touching the ground.
		fill     the cargo box the load is drawn in -- the sweeper's tipper bed.
]]
AtvBuilder.RIGS = {
	sweeper = {
		--[[
			Asset 6284556717 -- an orange-cabbed tipper with a big open grey bed.
			Third shell in this slot: first a salt-spreader lorry whose hopper was
			a SEALED box with a grille (a load nobody could see), then a smaller
			low-poly tipper. This one is the shape the top machine wants -- a
			bed open to the sky, wide enough to read as six hundred pounds.
		]]
		shell = "Sweeper",                                -- base 7.6 x 8.0 x 20.0
		--[[
			ONE NUMBER RESIZES THE WHOLE MACHINE.

			Every measurement in this row was tuned against the shell at its FIRST
			normalised size, and the shells were later scaled up because a Roblox
			character is 5 studs tall and chunky -- at realistic vehicle scale the
			driver stood a head over the thing they were meant to be driving.

			Rather than re-tune two dozen offsets by hand, build() multiplies them
			all by this. It has to match the factor the shell in ServerStorage was
			scaled by, or the seat ends up somewhere else.
		]]
		scale = 1.5,                                      -- final 11.4 x 11.9 x 30.0
		-- Read off the import's own DriveSeat rather than guessed: this cab's
		-- driver sits OFF CENTRE, which no amount of eyeballing a midline was
		-- ever going to produce.
		seat = { x = 1.30, y = 4.05, z = 3.73 },
		chassis = { w = 6.0, h = 1.8, d = 15.0, y = 1.15 },
		net = { y = 0.45, z = 10.60, mouth = 9.0, depth = 2.8, mount = 3.2 },
		--[[
			The dump bed, FILLED TO THE RIM rather than lining its floor -- a
			full 650 lbs has to look like a full truck, not like a layer at the
			bottom of a deep box. This bed's inside runs 3.3 to about 7.3 and
			runs z -6.7 to -0.2.

			Eight rows over 3.8 studs is a step every 0.48, small enough that one
			piece of litter visibly moves the pile.
		]]
		fill = { x = 0, y = 5.30, z = -3.45, w = 5.6, h = 3.8, d = 5.8, rows = 8 },
	},
}

--[[
	WHAT A LOAD LOOKS LIKE.

	Lumps, not a slab. A cargo box that filled with one smooth rising block
	reads as a progress bar someone has laid in the truck; what a beach cleaner
	actually collects is bags and bottles and boxes, so each layer is three
	lumps at different sizes, angles and muted rubbish colours.

	Deterministic, not random: the shape is derived from the part's index, so
	the showroom preview and the machine that drives off the pad are the same
	object rather than two rolls of the dice.
]]
local RUBBISH = {
	Color3.fromRGB(96, 104, 96),
	Color3.fromRGB(122, 116, 98),
	Color3.fromRGB(78, 96, 84),
	Color3.fromRGB(134, 128, 116),
	Color3.fromRGB(88, 92, 104),
	Color3.fromRGB(112, 98, 84),
}

function AtvBuilder.template(name: string): Model?
	local folder = ServerStorage:FindFirstChild(AtvBuilder.TemplateFolder)
	local model = folder and folder:FindFirstChild(name)
	if model and model:IsA("Model") then
		return model
	end
	return nil
end

--[[
	Shared with DozerBuilder, which has a skip rather than a bed but wants the
	identical stack of lumps in it. `part` is the caller's own part factory so
	the pieces land in the caller's model with the caller's defaults.

	`name` is what the lumps are CALLED, and there are two stacks on every
	machine: "Fill" is the cargo box, "ScoopFill" is the scoop out front. Same
	lumps, same order, two different containers -- see the scoop block in
	build() for why the load makes that stop on its way in.
]]
function AtvBuilder.buildFill(part, box, name: string?): { BasePart }
	local made = {}
	local fillName = name or "Fill"
	local rows = math.max(1, box.rows or 4)
	--[[
		HOW MANY LUMPS ACROSS, and it is not a detail.

		Three is right for a cargo box, where all you ever see is the top of the
		pile and a big piece is a big bin bag. It was badly wrong in an OPEN
		SCOOP: a third of a 13.5 stud mouth is a four stud lump, and at half a
		stud tall that is a plank -- the first scoop came out as a stack of
		boards jutting through the net frame on both sides.

		The scoop passes 5, which puts every lump inside the frame and closer to
		as deep as it is wide.
	]]
	local perRow = math.max(1, box.perRow or 3)
	for row = 0, rows - 1 do
		-- Bottom row first: the hold reveals these in order, so index order IS
		-- the order a box fills in.
		local ry = -box.h * 0.5 + (row + 0.5) * (box.h / rows)
		for k = 0, perRow - 1 do
			local i = row * perRow + k
			-- Deterministic jitter. Three different irrational-ish multipliers
			-- so the lumps do not fall into a visible grid.
			local jx = (math.sin(i * 12.9898) * 43758.5453) % 1
			local jz = (math.sin(i * 78.233) * 12345.6789) % 1
			local js = (math.sin(i * 39.425) * 24634.6345) % 1
			local lump = part({
				Name = fillName,
				Size = Vector3.new(
					box.w / perRow * (0.72 + js * 0.5),
					(box.h / rows) * (0.85 + jx * 0.45),
					box.d * (0.38 + jz * 0.34)),
				Color = RUBBISH[(i % #RUBBISH) + 1],
				Material = Enum.Material.Slate,
				Transparency = 1,      -- the hold turns these on as it loads
				Offset = CFrame.new(
					box.x + (-box.w * 0.5 + (k + 0.5) * (box.w / perRow)) + (jx - 0.5) * 0.5,
					box.y + ry,
					box.z + (jz - 0.5) * box.d * 0.35)
					* CFrame.Angles(0, (jz - 0.5) * 1.2, (jx - 0.5) * 0.5),
			})
			-- What to go back to when shown. Kept on the part so the hold does
			-- not need a parallel table it could get out of step with.
			lump:SetAttribute("FillTransparency", 0)
			lump:SetAttribute("FillIndex", i + 1)
			made[#made + 1] = lump
		end
	end
	return made
end

--[[
	HOW FAR THE MACHINE REACHES FORE AND AFT OF ITS CHASSIS, along its own +Z.

	CTB_Server rakes a band this long, so the sand goes as the SCOOP meets it
	rather than when the chassis centre gets there. On the thirty-stud tipper
	those two points are sixteen studs apart -- half a second at road speed --
	and that gap was the whole of "I drive over the sand and it disappears after
	I have already passed it".

	MEASURED OFF THE MODEL THAT WAS ACTUALLY BUILT, not tabled beside the rig.
	The scoop's z is already written down once in RIGS; a second copy of it here
	would be one more number to forget when a net moves, and the failure would be
	silent -- a band slightly out of step with the blade looks like nothing at
	all until you are staring at it.

	Every part contributes its own half-extent along the chassis's Z rather than
	just its centre, which is what makes an angled stay or a tilted fill lump
	count for the ground it really covers.
]]
function AtvBuilder.sweepSpan(model: Model, chassis: BasePart): (number, number)
	local ahead, back = 0, 0
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			local rel = chassis.CFrame:ToObjectSpace(p.CFrame)
			local s = p.Size
			-- Half the part's shadow on the chassis's Z axis: the axis-aligned
			-- extent of a rotated box, which is |Rz| . size.
			local half = 0.5 * (math.abs(rel.RightVector.Z) * s.X
				+ math.abs(rel.UpVector.Z) * s.Y
				+ math.abs(rel.LookVector.Z) * s.Z)
			local z = rel.Position.Z
			ahead = math.max(ahead, z + half)
			back = math.max(back, half - z)
		end
	end
	return ahead, back
end

--[[
	THE TOWED RAKE  --  what a Beach Rake upgrade actually looks like.

	WHY THIS EXISTS AT ALL, AND WHY IT IS NOT A WIDER SCOOP.

	AtvConfig.Upgrades sells a car-only ladder that widens the band CTB_Server
	rakes while you drive, from the machine's own blade to 98.5 studs. Stamping
	that number on SweepWidth and stopping there would reproduce, exactly, the
	two bugs this codebase has already paid for once each:

		CTB_Server's own note: a band taken from the net's REACH rather than the
		scoop's drawn mouth meant "three studs of beach either side being raked
		clean by a machine that visibly never went near it".

		CTB_Client's own note, on the player's sifter: buying width "widened the
		SWEEP while the basket in the player's hands stayed the size it was built
		at", so "the upgrade just paid for was invisible until the next rejoin".

	So the rule both of those settle on is one rule -- THE BAND IS AS WIDE AS THE
	THING THAT DREW IT -- and this function is what keeps it true out here.

	IT IS A SEPARATE ATTACHMENT, NOT THE SCOOP GROWN. The scoop's `mouth` is
	spread across six part families in build() below: three take it as a Size.X,
	two take it as a POSITION, the stays SOLVE their length and angle from it, the
	bag's cord COUNT is a function of it, and the fifteen ScoopFill lumps are cut
	to it -- and every one of them is welded, so the positioned ones cannot even
	be moved without remaking their joints. RIGS' own header settles the argument
	anyway: "a net literally spanning 44 studs would be wider than the shop". A
	ninety-eight stud one is a different machine, not a bigger scoop.

	A towed rake bar is also simply what the fiction wants. The scoop is what
	picks litter UP; this is what combs the sand, which is the player's own
	sifter's job, done at machine scale.

	DESTROY AND REBUILD, which is the pattern CTB_Client's syncSifterWidth uses
	for the same reason: every dimension AND the tine count are functions of the
	width, so there is no in-place resize that ends up correct.

	MASSLESS, and that is not tidiness. These are welded to a chassis that drives
	on velocity against a hand-tuned CustomPhysicalProperties, and fifty parts of
	real mass hung off its nose would change how every machine handles the moment
	somebody bought a rung.
]]
local RAKE_MAX_TINES = 40

-- The machine's lowest point along its own up axis -- the same |R| . size
-- projection sweepSpan does, on Y instead of Z, so an angled stay or a tilted
-- wheel counts for the ground it really sits on. Called with the rig already
-- destroyed, so a re-fit never measures the last rake's own tines.
local function groundOf(model: Model, chassis: BasePart): number
	local low = math.huge
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			local rel = chassis.CFrame:ToObjectSpace(p.CFrame)
			local s = p.Size
			local half = 0.5 * (math.abs(rel.RightVector.Y) * s.X
				+ math.abs(rel.UpVector.Y) * s.Y
				+ math.abs(rel.LookVector.Y) * s.Z)
			low = math.min(low, rel.Position.Y - half)
		end
	end
	return (low < math.huge) and low or 0
end

--[[
	Fit (or remove) the rake on an already-built, already-spawned machine.

	`width` is the FINISHED width in studs, or nil for none. Anything at or under
	`builtWidth` -- the blade or scoop the machine came with -- draws nothing:
	the machine already has something that wide out front, and a rake hidden
	inside the blade is fifty parts nobody can see.

	Returns the width actually drawn, or nil.
]]
function AtvBuilder.fitRake(model: Model, builtWidth: number, width: number?, colours): number?
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return nil
	end
	local old = model:FindFirstChild("SifterRig")
	if old then
		old:Destroy()
	end

	local chassis = model.PrimaryPart
	if not (chassis and chassis:IsA("BasePart")) then
		return nil
	end
	if type(width) ~= "number" or width ~= width or width <= (tonumber(builtWidth) or 0) then
		return nil
	end

	local bar = colours and colours.bar or Color3.fromRGB(248, 226, 178)
	local trim = colours and colours.trim or Color3.fromRGB(196, 92, 44)

	local rig = Instance.new("Folder")
	rig.Name = "SifterRig"
	rig.Parent = model

	local ground = groundOf(model, chassis)
	--[[
		JUST AHEAD OF THE MACHINE, not inside it.

		SweepAhead is the front of the band and, on both machines, the front of the
		scoop or blade -- so a bar centred there would be buried in it. A stud and a
		half clear puts the rake in front of the cutting edge, which means the sand
		gives way a fraction BEHIND the tines rather than in front of them. That
		lead is smaller than the four-stud grid cell the band is quantised to
		anyway, which is the same residual DOZER_HANDOFF settles for.

		SweepAhead is deliberately NOT re-stamped for the rake. It is measured
		across the chassis's Z and the rake is a change in X; re-running sweepSpan
		here would only fold this bar's own stud and a half into the band.
	]]
	local ahead = tonumber(model:GetAttribute("SweepAhead")) or 8
	local zBar = ahead + 1.5
	local half = width * 0.5

	local made = {}
	local function piece(name, size, colour, material, cf)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.Color = colour
		p.Material = material
		p.Anchored = false
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		-- See the header. Fifty parts of mass on the nose is a handling change.
		p.Massless = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.CFrame = chassis.CFrame * cf
		p.Parent = rig
		made[#made + 1] = p
		return p
	end

	-- The tool bar, and a truss behind and above it. One bar ninety-eight studs
	-- long and half a stud thick reads as a drawn line; two at different heights
	-- read as a frame with something holding it up.
	piece("RakeBar", Vector3.new(width, 0.55, 0.55), bar, Enum.Material.Metal,
		CFrame.new(0, ground + 0.62, zBar))
	piece("RakeTruss", Vector3.new(width, 0.38, 0.38), bar, Enum.Material.Metal,
		CFrame.new(0, ground + 2.05, zBar - 1.25))

	--[[
		THE TEETH, and their SPACING is what the width actually buys.

		The count is a function of the width the same way the player's own sifter
		derives `tines` from its width -- so a wider rake is visibly more rake
		rather than the same comb stretched. Capped at RAKE_MAX_TINES because past
		that the spacing is finer than anything the four-stud sand grid can show,
		and it is fifty welded parts on every machine on the beach.
	]]
	local tines = math.clamp(math.floor(width / 2.4), 6, RAKE_MAX_TINES)
	for i = 0, tines - 1 do
		local x = -half + (i + 0.5) * (width / tines)
		piece("RakeTine", Vector3.new(0.22, 1.15, 0.22), bar, Enum.Material.Metal,
			CFrame.new(x, ground + 0.30, zBar - 0.12) * CFrame.Angles(math.rad(22), 0, 0))
	end

	-- End plates, so the bar finishes rather than simply stopping.
	for _, sx in { -1, 1 } do
		piece("RakeEnd", Vector3.new(0.45, 1.7, 1.9), trim, Enum.Material.Metal,
			CFrame.new(sx * (half + 0.2), ground + 1.05, zBar - 0.5))
	end

	--[[
		THE STAYS, solved from both ends the way the scoop's are -- a real diagonal
		from a point on the truss back to the machine's nose, rather than a bar
		poked at the bodywork at a guessed angle.

		HOW MANY IS A FUNCTION OF WIDTH, and that is the whole reason they are
		here. Two stays hold a fourteen-stud scoop and read fine; two stays under
		ninety-eight studs of bar read as a plank balanced on a stick. Pairs, so
		the rake is always symmetrical.
	]]
	local pairsOfStays = math.clamp(math.floor(width / 22), 1, 4)
	for k = 1, pairsOfStays do
		local frac = k / (pairsOfStays + 0.35)
		for _, sx in { -1, 1 } do
			local tip = Vector3.new(sx * half * frac, ground + 2.05, zBar - 1.25)
			local root = Vector3.new(sx * math.min(half * frac, 2.6) , ground + 3.4, ahead - 3.0)
			local mid = (tip + root) * 0.5
			-- Length AND angle out of the two ends, exactly as the scoop's NetStay
			-- does it. lookAt puts the part's Z along the run, which is the axis
			-- Size.Z measures.
			piece("RakeStay", Vector3.new(0.3, 0.3, (root - tip).Magnitude), trim,
				Enum.Material.Metal, CFrame.lookAt(mid, root))
		end
	end

	-- Welded, never anchored: the machine is a driven physics assembly and an
	-- anchored part bolted to it would nail the whole truck to the beach.
	for _, p in made do
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = chassis
		weld.Part1 = p
		weld.Parent = p
	end

	return width
end

function AtvBuilder.build(tier, pivot: CFrame): Model
	local raw = AtvBuilder.RIGS[tier.kind or "sweeper"]
	assert(raw, "[AtvBuilder] no rig for kind " .. tostring(tier.kind))

	-- Every offset in the table is in the shell's ORIGINAL normalised units.
	-- One multiply here is what keeps a resize to a single number.
	local S = raw.scale or 1
	local rig = {
		shell = raw.shell,
		seat = { x = (raw.seat.x or 0) * S, y = raw.seat.y * S, z = raw.seat.z * S },
		chassis = { w = raw.chassis.w * S, h = raw.chassis.h * S,
		            d = raw.chassis.d * S, y = raw.chassis.y * S },
		net = { y = raw.net.y * S, z = raw.net.z * S,
		        mouth = raw.net.mouth * S, depth = raw.net.depth * S,
		        mount = (raw.net.mount or 2) * S },
		fill = { x = raw.fill.x * S, y = raw.fill.y * S, z = raw.fill.z * S,
		         w = raw.fill.w * S, h = raw.fill.h * S, d = raw.fill.d * S,
		         rows = raw.fill.rows },
	}
	local template = AtvBuilder.template(rig.shell)
	assert(template, "[AtvBuilder] ServerStorage." .. AtvBuilder.TemplateFolder .. "."
		.. rig.shell .. " is missing -- that shell is not in the place")

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
	local c = rig.chassis
	local chassis = part({
		Name = "Chassis",
		Size = Vector3.new(c.w, c.h, c.d),
		Transparency = 1,
		CanCollide = true,
		Offset = CFrame.new(0, c.y, 0),
	})
	-- Light, so it does not shove the player's character around, and slippery,
	-- because the drive is velocity-based and ground friction only fights it.
	chassis.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.1, 0, 1, 1)

	------------------------------------------------------------------
	-- THE SHELL, IN THIS TIER'S PAINT
	------------------------------------------------------------------
	for _, source in template:GetChildren() do
		if source:IsA("BasePart") then
			local p = source:Clone()
			p.Anchored = false
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			-- Near weightless: scenery bolted to the collider above, and at
			-- mesh density it would multiply the assembly's mass for nothing.
			p.CustomPhysicalProperties = PhysicalProperties.new(0.05, 0.3, 0, 1, 1)
			p.CFrame = pivot * source.CFrame

			-- VertexColor MULTIPLIES the texture, so a repaint keeps the panel
			-- lines. The texture is a mid-tone, hence the 1.9 gain -- a raw
			-- colour comes out muddy.
			local mesh = p:FindFirstChildWhichIsA("SpecialMesh")
			if mesh and mesh.TextureId ~= "" and tier.body then
				mesh.VertexColor = Vector3.new(tier.body.R * 1.9, tier.body.G * 1.9, tier.body.B * 1.9)
			end
			p.Parent = model
		end
	end

	------------------------------------------------------------------
	-- SEAT
	------------------------------------------------------------------
	-- TURNED 180. A character faces its seat's LookVector, which is the
	-- CFrame's NEGATIVE Z axis, and these machines' noses are +Z -- so an
	-- unturned seat sits the rider facing backwards over their own tail.
	part({
		ClassName = "VehicleSeat",
		Name = "Seat",
		Size = Vector3.new(2.1, 0.5, 2.2),   -- a character, not the machine: never scaled
		Color = SEATC,
		Material = Enum.Material.Fabric,
		Transparency = 1,      -- every shell has a seat modelled into it already
		CanCollide = true,
		CanQuery = true,
		CanTouch = true,
		-- The seat must not drive the body itself: AtvServer owns the driving,
		-- and a VehicleSeat torquing a chassis it has no wheels for only fights
		-- the constraints.
		MaxSpeed = 0,
		Torque = 0,
		TurnSpeed = 0,
		-- ROBLOX'S OWN SPEEDOMETER, OFF. A VehicleSeat draws a stock "Speed"
		-- gauge across the bottom of the screen the moment anybody sits in it,
		-- and it is not ours: grey dashes, a default font, no relation to any
		-- other surface in the game. DriveHud says the same number in the
		-- game's own hand a few pixels above it, so this one is pure noise --
		-- and it read as MaxSpeed, which is 0 here, so it never moved anyway.
		HeadsUpDisplay = false,
		Offset = CFrame.new(rig.seat.x, rig.seat.y, rig.seat.z) * CFrame.Angles(0, math.pi, 0),
		-- YOU GET IN WITH E, not by walking into it. AtvServer hangs an Enter
		-- prompt on the machine; leaving touch on as well means brushing past a
		-- parked truck teleports you into the driving seat.
		CanTouch = false,
	})

	------------------------------------------------------------------
	-- THE NET
	------------------------------------------------------------------
	local n = rig.net
	local mouth, netY, netZ = n.mouth, n.y, n.z

	local bar = 0.18 * S
	part({
		Name = "Net",
		Size = Vector3.new(mouth, bar, bar),
		Color = tier.netColour,
		Material = Enum.Material.Metal,
		Offset = CFrame.new(0, netY + 1.05 * S, netZ + 0.35 * S),
	})
	for _, sx in { -1, 1 } do
		part({
			Name = "NetArm",
			Size = Vector3.new(bar, 1.35 * S, bar),
			Color = tier.netColour,
			Material = Enum.Material.Metal,
			Offset = CFrame.new(sx * mouth * 0.5, netY + 0.4 * S, netZ + 0.35 * S),
		})
		--[[
			THE STAY, and it is the reason the scoop can sit on the sand without
			looking dropped there.

			It runs from the top of the net UP AND BACK to `mount` on the
			machine's nose -- a real diagonal, sized and angled from the two
			ends rather than a horizontal bar poked at the bodywork. Solved
			rather than eyeballed so it stays correct on this rig and on anything
			added later.
		]]
		local top = Vector3.new(sx * mouth * 0.45, netY + 1.05 * S, netZ + 0.2 * S)
		local anchor = Vector3.new(sx * mouth * 0.30, n.mount, netZ - n.depth - 1.6 * S)
		local mid = (top + anchor) * 0.5
		part({
			Name = "NetStay",
			Size = Vector3.new(bar * 0.9, bar * 0.9, (anchor - top).Magnitude),
			Color = tier.netColour,
			Material = Enum.Material.Metal,
			Offset = CFrame.lookAt(mid, anchor),
		})
	end
	part({
		Name = "NetLip",
		Size = Vector3.new(mouth, 0.2 * S, 0.55 * S),
		Color = tier.accent,
		Material = Enum.Material.Metal,
		Offset = CFrame.new(0, netY - 0.15 * S, netZ + 0.5 * S),
	})

	-- The bag: criss-crossed cord raked back under the nose.
	local cord = 0.06 * S
	local across = math.max(5, math.floor(mouth / (0.55 * S)))
	for i = 0, across do
		local x = -mouth * 0.5 + (i / across) * mouth
		part({
			Name = "NetCord",
			Size = Vector3.new(cord, cord, n.depth),
			Color = tier.netColour,
			Material = Enum.Material.Fabric,
			Transparency = 0.15,
			Offset = CFrame.new(x, netY + 0.25 * S, netZ - 0.35 * S) * CFrame.Angles(math.rad(28), 0, 0),
		})
	end
	for i = 0, 3 do
		part({
			Name = "NetCord",
			Size = Vector3.new(mouth, cord, cord),
			Color = tier.netColour,
			Material = Enum.Material.Fabric,
			Transparency = 0.15,
			Offset = CFrame.new(0, netY + (0.7 - i * 0.42) * S, netZ + (0.1 - i * 0.44) * S)
				* CFrame.Angles(math.rad(28), 0, 0),
		})
	end

	------------------------------------------------------------------
	-- WHAT THE SCOOP IS HOLDING
	------------------------------------------------------------------
	--[[
		THE LOAD GOES THROUGH THE NET BEFORE IT GOES IN THE BOX.

		A machine whose cargo bed rose while the scoop in front of it stayed
		empty was collecting litter by teleporting it -- the shovel, which is
		the part of the machine you are actually looking at as you drive, never
		showed a thing.

		So the net is a container of its own. Litter lands HERE first, this
		visibly fills over about half a dozen pickups, and then it tips: the
		scoop empties and the bed behind it jumps by what the scoop was
		holding. VehicleHold owns that cycle; the builder's only job is to put
		a stack of lumps inside the bag.

		Sized off the net rather than tabled per rig, so a machine added later
		gets a working scoop from its `net` entry alone. Three rows, not six:
		this is a scoopful, and every lump has to be visible from the seat
		rather than adding a millimetre to a pile.
	]]
	AtvBuilder.buildFill(part, {
		x = 0,
		y = netY + 0.50 * S,
		-- Back off the lip. At netZ - 0.30 the deepest lumps poked out through
		-- the front bar of the frame, which is the one edge of the scoop the
		-- driver is looking straight down at.
		z = netZ - 0.55 * S,
		w = mouth * 0.80,
		h = 1.10 * S,
		d = n.depth * 0.55,
		rows = 3,
		perRow = 5,
	}, "ScoopFill")

	------------------------------------------------------------------
	-- THE LOAD
	------------------------------------------------------------------
	AtvBuilder.buildFill(part, rig.fill)

	------------------------------------------------------------------
	-- JOIN IT ALL UP
	------------------------------------------------------------------
	--[[
		Everything is rigidly welded to the chassis EXCEPT THE WHEELS, which get
		a Motor6D each so the drive can turn them.

		A WeldConstraint holds two parts where they are and offers nothing to
		animate. The joint is placed at the wheel's own centre but takes the
		CHASSIS's orientation, so "rotate C0 about X" is the axle whatever
		arbitrary rotation the imported tyre mesh happens to carry -- and the
		rims, hubs and centre caps stacked at the same centre all turn together
		without having to agree about anything.
	]]
	local biggest = 0
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") and p ~= chassis then
			if p.Name == "Wheel" then
				local axle = CFrame.new(p.Position) * chassis.CFrame.Rotation
				local motor = Instance.new("Motor6D")
				motor.Name = "WheelMotor"
				motor.Part0 = chassis
				motor.Part1 = p
				motor.C0 = chassis.CFrame:ToObjectSpace(axle)
				motor.C1 = p.CFrame:ToObjectSpace(axle)
				motor.Parent = chassis
				biggest = math.max(biggest, p.Size.X, p.Size.Y, p.Size.Z)
			else
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = chassis
				weld.Part1 = p
				weld.Parent = chassis
			end
		end
	end

	model.PrimaryPart = chassis
	model:SetAttribute("Tier", tier.id)
	model:SetAttribute("NetRadius", tier.netRadius)
	model:SetAttribute("Hold", tier.hold or 0)
	-- Distance per turn comes off the biggest tyre on the machine, so a small
	-- wheel spins visibly faster than a lorry's at the same road speed -- which
	-- is the whole reason to drive them off speed rather than off a fixed rate.
	model:SetAttribute("WheelRadius", (biggest > 0) and (biggest * 0.5) or 0)
	-- How wide a lane this machine RAKES, read by CTB_Server. It is the scoop's
	-- drawn mouth, not the net's reach: the raked band is the visible mark the
	-- machine leaves, and a band wider than the thing that made it is litter
	-- vanishing off to the side of a truck that never went near it.
	model:SetAttribute("SweepWidth", mouth)
	-- How far the raked band runs in front of and behind the chassis. The front
	-- of it is the front of the scoop, which is the only place a driver can be
	-- told the sand goes. See AtvBuilder.sweepSpan.
	local ahead, back = AtvBuilder.sweepSpan(model, chassis)
	model:SetAttribute("SweepAhead", ahead)
	model:SetAttribute("SweepBack", back)
	return model
end

return AtvBuilder
