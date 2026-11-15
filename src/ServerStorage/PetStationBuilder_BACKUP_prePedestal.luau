--[[
	PetStationBuilder  --  ServerScriptService.PetStationBuilder

	Puts an egg plaza on every island: three pedestals in a row, one per egg,
	each tagged PetStation with the EggKey attribute PetServer binds its prompt
	to.

	ADOPTION, not replacement -- the same contract BayBuilder and StoreBuilder
	use. If a plaza already exists (authored by hand, or built by an earlier
	run) this re-dresses it and re-tags it rather than building a second one on
	top. Running it twice is a no-op, which is what makes it safe to call from
	ServerMain on every boot.

	WHERE THEY GO
	-------------
	Derived, not hard-coded. Each island row in CTB.Config carries its centre
	(cx, cz) and its field half-width, so the plaza is placed a fixed setback
	BEYOND the field edge -- outside the rakeable area, because anything inside
	it stands on terrain the player levels flat. Change an island's size and the
	plaza moves with it.

	The ground is found by raycast rather than trusted from the island row:
	cleanY is what the FIELD settles at, and the plaza is deliberately not on
	the field.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local PetConfig = require(Modules:WaitForChild("PetConfig"))

local PetStationBuilder = {}

local FOLDER_NAME = "PetStations"

local WOOD = Color3.fromRGB(146, 104, 66)
local WOOD_DARK = Color3.fromRGB(110, 76, 48)
local SAND = Color3.fromRGB(232, 214, 174)

--------------------------------------------------------------------------
-- CTB's island table, reached the same optional way everything else reaches it
--------------------------------------------------------------------------
local function ctbConfig()
	local ctb = ReplicatedStorage:FindFirstChild("CTB")
	local module = ctb and ctb:FindFirstChild("Config")
	if not (module and module:IsA("ModuleScript")) then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" and type(result.ISLANDS) == "table" then
		return result
	end
	warn("[PetStationBuilder] CTB.Config would not load; stations cannot be placed")
	return nil
end

--------------------------------------------------------------------------
-- GROUND
--------------------------------------------------------------------------
-- Straight down from well above, ignoring anything we or another builder has
-- already put there, so a re-run does not stack a plaza on top of itself.
local function groundAt(x: number, z: number, fallbackY: number, ignore: { Instance }): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true

	local from = Vector3.new(x, fallbackY + 260, z)
	local hit = workspace:Raycast(from, Vector3.new(0, -600, 0), params)
	if hit then
		return hit.Position.Y
	end
	return fallbackY
end

--------------------------------------------------------------------------
-- PARTS
--------------------------------------------------------------------------
local function part(name: string, size: Vector3, cf: CFrame, color: Color3,
	material: Enum.Material, parent: Instance): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

--[[
	The egg itself: a Creator Store shell mesh floating over the pedestal.

	ONE TEXTURED MESH PER EGG, staged under ReplicatedStorage.Assets.EggShells
	and normalised to one stud tall -- see shellTemplate for why they are not
	tinted and what happens when an egg has no art of its own.

	The old shell was a squashed Ball with a Cylinder band round it, which read
	as a ball with a stripe on it rather than as an egg -- the silhouette is the
	whole of what makes an egg an egg at forty studs, and a sphere does not have
	it. The band is gone with the sphere: it existed to break up a shape that no
	longer needs breaking up.

	STAGED IN ReplicatedStorage, NOT ServerStorage, on purpose. The hatch screen
	builds its own copy of this egg on the client (EggClient.eggScene) and the
	two have to be the same object or the egg that cracks is not the egg that was
	on the pedestal.

	FALLS BACK TO THE OLD SPHERE if the asset is ever missing. A station with a
	less good egg on it still sells pets; a station that throws does not.

	Unanchored would be more charming and is not worth it -- three of these per
	island, on five islands, is fifteen physics assemblies simulating forever on
	the server for a bob the client can fake. It is anchored and the CLIENT bobs
	it (see EggClient), so an idle plaza costs nothing.
]]
--[[
	HOW BIG THE EGG IS, and it is smaller than both things it replaced.

	The first mesh pass went in at 4.4 studs tall against the old sphere's 3.9 --
	but a sphere and an egg of the same HEIGHT do not read the same size at all.
	A sphere is as wide as it is tall and reads as its width; an egg is tall and
	narrow and reads as its height, and this one stood a clear three studs over
	the player's own head on a plinth that was already chest high.

	2.8 with a short gap puts the egg STRADDLING the player's own eye line rather
	than towering over it -- a thing you walk up to and look at, not a monument.
	A player's head sits at about y = 8.2 on this plaza and the egg now runs 7.0
	to 9.8, so you meet it at eye level from the path.

	SEATED ON THE RIM RATHER THAN AT A FIXED HEIGHT (see buildPedestal): with the
	egg's own height now a dial, a hard-coded 6.2 stud offset would have left it
	floating over the plinth the moment the dial moved.
]]
local EGG_HEIGHT = 2.8

-- Daylight between the rim and the bottom of the egg. Enough that it reads as
-- hovering; not so much that it is out of reach.
--
-- It has to clear the BOB as well as the rim. The client swings the egg through
-- +/- 0.28 studs, so at 0.4 the bottom of the downstroke was 0.12 above the wood
-- and buried in the plinth glow -- the egg looked bedded into the light rather
-- than floating over it. 0.75 keeps the whole travel clear of both.
local EGG_FLOAT = 0.75

-- Top of the pedestal rim, measured off the pieces buildPedestal actually makes:
-- Plinth centre +2.1 of height 3.2, then Rim centre +3.9 of height 0.5.
local RIM_TOP = 3.9 + 0.25

--[[
	THE SHELL FOR ONE EGG -- one per egg now, rather than one for all three.

	The first pass staged a single mesh and tinted it cream, sand and lilac.
	That is cheap and it reads as three of the same object in three colours,
	because that is exactly what it was. The games this is modelled on give
	every egg its own art, and that art is most of how a player tells a
	100-coin egg from a 50,000-coin one from the far side of a plaza -- long
	before they are close enough for the price pill to resolve.

	So ReplicatedStorage.Assets.EggShells holds one TEXTURED mesh per egg key,
	each normalised to exactly one stud tall so EGG_HEIGHT stays literal.

	THEY ARE NOT TINTED. Color multiplies the texture, so a gold egg run
	through the Prestige lilac is a brown egg. The palette still drives
	everything AROUND the shell -- the light, the sparkle, the plinth glow, the
	panel and the pill -- so an egg added to PetConfig with no art of its own
	still comes out of here coherent.

	FALLS BACK TWICE: EggShells[key], then the old shared Assets.EggShell,
	then buildEgg's own sphere. Each step down is a worse-looking station and
	none of them is a broken one.

	The second return says whether the shell carries its own art, which is what
	decides if it gets painted.
]]
local function shellTemplate(key: string?): (BasePart?, boolean)
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return nil, false
	end
	local shells = assets:FindFirstChild("EggShells")
	local own = key and shells and shells:FindFirstChild(key)
	if own and own:IsA("BasePart") then
		return own, true
	end
	local shared = assets:FindFirstChild("EggShell")
	if shared and shared:IsA("BasePart") then
		return shared, false
	end
	return nil, false
end

local function buildEgg(cf: CFrame, egg, parent: Instance): BasePart
	local template, ownArt = shellTemplate(egg.key)
	local shell
	if template then
		shell = template:Clone()

		--[[
			STRIPPED TO THE MESH, and this is not tidiness.

			The part this came out of was a Creator Store egg, and a Creator Store
			part is a part with a whole scene hanging off it. This one carried a
			SECOND full-size Egg MeshPart as a child -- 7.7 x 10.4 x 7.5 studs --
			plus the kit's own 15 x 4 stud billboard reading "Weak Egg / $500", a
			sparkle emitter, a weld and an attachment.

			Setting Size on the part does NOT scale its children, so every station
			stood a 2.8-stud tinted egg inside a 10.4-stud white one. The white one
			is what everybody saw: the eggs were two and a half times the player's
			height, they ignored their own colour because the tinted shell was
			inside them, and the kit's price board came along for the ride and read
			the same wrong price on all fifteen pedestals.

			The memory of this place already said to strip scripts out of toolbox
			assets. Scripts were checked and there were none; the lesson is wider
			than scripts, so this strips EVERYTHING and adds back only what the
			station actually wants.
		]]
		for _, junk in ipairs(shell:GetChildren()) do
			junk:Destroy()
		end

		-- The template is one stud tall, so this is the height in studs.
		shell.Size = template.Size * EGG_HEIGHT
	else
		warn("[PetStationBuilder] no egg shell asset; falling back to a sphere")
		shell = Instance.new("Part")
		shell.Shape = Enum.PartType.Ball
		shell.Size = Vector3.new(3.1, 3.9, 3.1)
		ownArt = false
	end

	shell.Name = "Egg"
	shell.CFrame = cf
	-- Only the art-less fallbacks get painted. See shellTemplate.
	shell.Color = ownArt and Color3.new(1, 1, 1) or egg.color
	shell.Material = Enum.Material.SmoothPlastic
	--[[
		A LITTLE SPECULAR.

		An egg in this kind of game is a lacquered, faintly wet-looking thing, and
		SmoothPlastic on its own is matte -- flat under a sky with nothing to catch.
		0.05 is a sheen and not a mirror: enough for the sun to draw a highlight
		down one side, which is what gives the silhouette a top and a bottom instead
		of reading as a cut-out.
	]]
	shell.Reflectance = 0.05
	shell.Anchored = true
	shell.CanCollide = false
	-- CanQuery = false: the egg hovers exactly where the prompt's line of
	-- sight would run, and a prompt occluded by its own egg is a station that
	-- refuses to open.
	shell.CanQuery = false
	shell.CanTouch = false
	shell.CastShadow = false
	shell.Parent = parent

	local light = Instance.new("PointLight")
	light.Brightness = 1.1
	light.Range = 11
	light.Color = egg.accent
	light.Parent = shell

	--[[
		SPARKLE, AND THE RATE IS THE PRICE.

		Emitted from the part's own volume -- a ParticleEmitter parented straight to
		a BasePart uses that part as its shape, so there is no Attachment to place
		and the sparkle comes off the whole shell rather than out of one point
		inside it.

		The rate scales with the egg's index, so the Basic egg glitters faintly and
		the Prestige egg is unmistakable from the path. That is the one difference
		between the three that still reads at forty studs, and it does the job the
		price pill cannot do until the player is close enough to read digits.

		rbxasset:// -- a texture that SHIPS WITH THE ENGINE, not an upload. This
		place has already been bitten by assets that resolve for the uploader and
		for nobody else, and a sparkle that silently fails to load is a station that
		looks broken with nothing in the log.
	]]
	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Name = "Sparkle"
	sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkle.Color = ColorSequence.new(egg.accent)
	sparkle.LightEmission = 0.85
	sparkle.LightInfluence = 0
	sparkle.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.35, 0.44),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparkle.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.25, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	sparkle.Lifetime = NumberRange.new(0.9, 1.6)
	sparkle.Rate = 3 + (egg.index or 1) * 4
	sparkle.Speed = NumberRange.new(0.4, 1.1)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.Rotation = NumberRange.new(0, 360)
	sparkle.RotSpeed = NumberRange.new(-60, 60)
	-- Drifting up rather than falling: a sparkle that sinks reads as ash.
	sparkle.Acceleration = Vector3.new(0, 1.2, 0)
	sparkle.Parent = shell

	--[[
		THE PLINTH GLOW.

		A neon disc a hand's width over the rim, in the egg's accent, so the
		pedestal looks like it is holding the egg up ON something rather than like
		the egg happens to be hanging over some wood. It is also what gives the
		float a reference: a thing suspended over nothing reads as a mistake, and
		the same thing suspended over a light reads as suspended.

		PARENTED TO THE STATION, NOT TO THE EGG. The egg bobs and turns every frame
		on the client, and a glow welded to that would swing about under it.

		Rebuilt rather than added to, because the adoption pass calls buildEgg again
		and a ring per re-dress would stack.
	]]
	local stale = parent:FindFirstChild("GlowRing")
	if stale then
		stale:Destroy()
	end
	local ring = Instance.new("Part")
	ring.Name = "GlowRing"
	ring.Shape = Enum.PartType.Cylinder
	-- X is a cylinder's axis, so this is a 4.6-wide disc 0.12 thick, laid flat.
	ring.Size = Vector3.new(0.12, 3.4, 3.4)
	-- Just off the wood, not floating in the gap: this is light ON the rim.
	ring.CFrame = cf
		* CFrame.new(0, -(EGG_FLOAT + EGG_HEIGHT * 0.5) + 0.12, 0)
		* CFrame.Angles(0, 0, math.rad(90))
	ring.Color = egg.accent
	ring.Material = Enum.Material.Neon
	-- Faint. Neon at 0.62 across 4.6 studs was not a glow, it was a painted lid
	-- on the pedestal -- the widest, flattest, most opaque thing in the shot.
	ring.Transparency = 0.74
	ring.Anchored = true
	ring.CanCollide = false
	-- The prompt's line of sight runs through here too.
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Parent = parent

	return shell
end

local function buildSign(anchor: BasePart, egg)
	local gui = Instance.new("BillboardGui")
	gui.Name = "EggSign"
	gui.Size = UDim2.fromScale(7.4, 2.4)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 5.4, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 90
	gui.Parent = anchor

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromScale(1, 0.56)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.LuckiestGuy
	title.Text = egg.name
	title.TextColor3 = Color3.fromRGB(255, 252, 242)
	title.TextStrokeTransparency = 0.35
	title.TextStrokeColor3 = Color3.fromRGB(52, 34, 18)
	title.TextScaled = true
	title.Parent = gui

	local cost = Instance.new("TextLabel")
	cost.Name = "Cost"
	cost.Size = UDim2.fromScale(1, 0.44)
	cost.Position = UDim2.fromScale(0, 0.56)
	cost.BackgroundTransparency = 1
	cost.Font = Enum.Font.LuckiestGuy
	cost.Text = "$" .. egg.cost
	cost.TextColor3 = egg.accent
	cost.TextStrokeTransparency = 0.35
	cost.TextStrokeColor3 = Color3.fromRGB(52, 34, 18)
	cost.TextScaled = true
	cost.Parent = gui
end

--------------------------------------------------------------------------
-- ONE PEDESTAL
--------------------------------------------------------------------------
local function buildPedestal(parent: Instance, cf: CFrame, egg): Model
	local model = Instance.new("Model")
	model.Name = "EggStation_" .. egg.key
	model:SetAttribute("EggKey", egg.key)
	model.Parent = parent

	part("Base", Vector3.new(7.2, 1, 7.2), cf, SAND, Enum.Material.Sand, model)
	part("Plinth", Vector3.new(4.4, 3.2, 4.4), cf * CFrame.new(0, 2.1, 0), WOOD,
		Enum.Material.WoodPlanks, model)
	part("Rim", Vector3.new(5.1, 0.5, 5.1), cf * CFrame.new(0, 3.9, 0), WOOD_DARK,
		Enum.Material.WoodPlanks, model)

	-- The prompt lives on its own part rather than on the plinth, so its
	-- position is independent of the art. Invisible, non-colliding, and at
	-- chest height where a walk-up actually points.
	local anchor = part("PromptAnchor", Vector3.new(4.6, 4.4, 4.6),
		cf * CFrame.new(0, 3.4, 0), WOOD, Enum.Material.WoodPlanks, model)
	anchor.Transparency = 1
	anchor.CanCollide = false

	-- Sat on the rim with a stud of daylight under it, so it reads as hovering
	-- over the pedestal rather than as balanced on it or buried in it -- and so
	-- that changing EGG_HEIGHT moves the egg instead of breaking the stack.
	buildEgg(cf * CFrame.new(0, RIM_TOP + EGG_FLOAT + EGG_HEIGHT * 0.5, 0), egg, model)
	buildSign(anchor, egg)
	-- The odds panel, the price pill and the E bubble are NOT built here. They
	-- are per-player -- the panel greys out pets this player has not discovered
	-- and the pill reads their own balance -- so EggClient draws them off the
	-- PetStation tag. See the station-front block there.


	model.PrimaryPart = anchor
	CollectionService:AddTag(model, "PetStation")
	return model
end

--------------------------------------------------------------------------
-- ONE PLAZA
--------------------------------------------------------------------------
local function buildPlaza(root: Folder, isl, lateral: number): Model
	local existing = root:FindFirstChild("Plaza_" .. isl.name)
	if existing then
		-- Adopted. Re-tag every pedestal in case the tag was lost with a
		-- Studio undo, and leave the geometry exactly where it stands.
		--
		-- RE-DRESSING THE EGG IS PART OF ADOPTION, and it has to be, because the
		-- plazas are SAVED IN THE PLACE. Adoption returning early on a plaza that
		-- already exists is what makes this safe to run every boot -- and it is
		-- also what would have left every station in this place carrying the old
		-- sphere-and-band egg forever, with buildEgg's new mesh only ever
		-- appearing on an island nobody had built yet. Anything that is not
		-- already a MeshPart is rebuilt from the template, in place, at the same
		-- CFrame; anything that is, is left alone. So this converges rather than
		-- churning, and running it twice is still a no-op.
		for _, child in existing:GetChildren() do
			if child:IsA("Model") and child:GetAttribute("EggKey") then
				CollectionService:AddTag(child, "PetStation")

				local egg = child:FindFirstChild("Egg")
				local key = child:GetAttribute("EggKey")
				local def = PetConfig.eggFor(key)
				local template = shellTemplate(key)
				-- Re-dressed when it is not the mesh yet, AND when it is the mesh at
				-- the wrong size -- otherwise a retune of EGG_HEIGHT would only ever
				-- reach islands that had never been built, which is the same trap
				-- adoption set the first time. Compared with a tolerance because a
				-- float that has been through a clone and a save is not the float it
				-- started as.
				local wrongSize = egg and egg:IsA("MeshPart")
					and math.abs(egg.Size.Y - EGG_HEIGHT) > 0.05

				-- Anything hanging off the egg that is not the station's own light is
				-- kit baggage that rode in on a clone (see the strip in buildEgg).
				-- Checked as well as the size, because the baggage is the SAME size
				-- whatever height the egg is set to and would otherwise survive every
				-- re-dress this function does.
				-- The wrong ART, not merely the wrong size. A station built before the
				-- per-egg shells went in is a correctly-sized egg wearing the shared
				-- mesh, and nothing else in here would ever notice.
				local wrongMesh = egg and egg:IsA("MeshPart")
					and template and template:IsA("MeshPart")
					and egg.MeshId ~= template.MeshId

				local carriesJunk = false
				if egg then
					for _, c in ipairs(egg:GetChildren()) do
						if not (c:IsA("PointLight") or c:IsA("ParticleEmitter")) then
							carriesJunk = true
							break
						end
					end
				end

				if def and template and egg
					and (not egg:IsA("MeshPart") or wrongSize or wrongMesh or carriesJunk) then
					-- Re-seated, not left where the old one was: a smaller egg parked at
					-- the taller one's centre floats.
					local base = child:FindFirstChild("Base")
					local at = egg.CFrame
					if base then
						at = base.CFrame * CFrame.new(0, RIM_TOP + EGG_FLOAT + EGG_HEIGHT * 0.5, 0)
					end
					egg:Destroy()
					-- The band belonged to the sphere and has no place on the mesh.
					local band = child:FindFirstChild("Band")
					if band then
						band:Destroy()
					end
					buildEgg(at, def, child)
				end
			end
		end
		return existing
	end

	local plaza = Instance.new("Model")
	plaza.Name = "Plaza_" .. isl.name
	plaza.Parent = root

	local half = (type(isl.half) == "number") and isl.half or 128
	local cx = (type(isl.cx) == "number") and isl.cx or 0
	local cz = (type(isl.cz) == "number") and isl.cz or 0
	local fallbackY = (type(isl.cleanY) == "number") and isl.cleanY or 3

	local baseZ = cz - (half + PetConfig.StationSetback)
	local spacing = PetConfig.StationSpacing
	local span = (#PetConfig.Eggs - 1) * spacing

	for i, egg in PetConfig.Eggs do
		local x = cx + lateral + (i - 1) * spacing - span * 0.5
		local y = groundAt(x, baseZ, fallbackY, { plaza, root })
		-- Sunk half a stud so the base plate beds into the sand instead of
		-- sitting on it as a floating tile.
		buildPedestal(plaza, CFrame.new(x, y - 0.5, baseZ), egg)
	end

	return plaza
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------
local built = false

function PetStationBuilder.ensureWorld()
	assert(RunService:IsServer(), "[PetStationBuilder] server-only")
	if built then
		return
	end
	built = true

	local Config = ctbConfig()
	if not Config then
		return
	end

	local root = workspace:FindFirstChild(FOLDER_NAME)
	if not root then
		local f = Instance.new("Folder")
		f.Name = FOLDER_NAME
		f.Parent = workspace
		root = f
	end

	-- EVERY island, not a list of them. See the note on PetConfig.
	-- StationOverrides: a hand-written list of islands was already missing one
	-- the day it was written.
	local placed, names = 0, {}
	for id, isl in Config.ISLANDS do
		local override = PetConfig.StationOverrides[id] or {}
		local ok, err = pcall(buildPlaza, root, isl, override.lateral or 0)
		if ok then
			placed += 1
			table.insert(names, isl.name or ("island " .. tostring(id)))
		else
			warn("[PetStationBuilder] could not place plaza on island", id, err)
		end
	end

	print(string.format("[PetStationBuilder] %d egg plazas up, %d eggs each (%s)",
		placed, #PetConfig.Eggs, table.concat(names, ", ")))
end

return PetStationBuilder
