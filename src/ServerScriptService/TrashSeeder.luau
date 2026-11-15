--[[
	TrashSeeder  --  ServerScriptService.TrashSeeder

	Puts collectible props on the sand. The WeightSystem already knows how to
	pick things up -- it just had nothing to pick up, because workspace.Trash was
	empty and nothing was tagged. This fills that folder and then gets out of the
	way; it does not touch collection, carrying or selling.

	WHAT A PROP HAS TO CARRY (WeightConfig's contract)
	--------------------------------------------------
		Tag        CollectibleTrash
		Attribute  Weight       -- lbs, from ItemConfig
		Attribute  ItemId       -- maps back into the catalogue
		Attribute  DisplayName  -- cosmetic

	ENCASED ITEMS LOOK LIKE ROCKS IN THE WORLD. That is the whole point of the
	mechanic: you cannot tell a Gold Bar from a Rolex until it is on the stand
	and you have blasted it, so the prop deliberately carries no visual tell.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local ItemConfig = require(Modules:WaitForChild("ItemConfig"))
-- What a find LOOKS like is ItemVisuals' job. See buildProp.
local ItemVisuals = require(Modules:WaitForChild("ItemVisuals"))
-- For the FIELDS and the depth of the sand over them -- see fieldLift. Plain
-- replicated data; no server dependency comes in with it.
local Config = require(ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Config"))

local TrashSeeder = {}

TrashSeeder.Count = 90
TrashSeeder.Radius = 105        -- CTB's beach is 256 studs across, centred (0,0)
TrashSeeder.RespawnDelay = 20

local rng = Random.new()
local folder

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function groundAt(x, z): number?
	rayParams.FilterDescendantsInstances = { folder }
	local hit = workspace:Raycast(Vector3.new(x, 60, z), Vector3.new(0, -140, 0), rayParams)
	return hit and hit.Position.Y or nil
end

--[[
	HOW FAR ABOVE THE RAY THE PROP ACTUALLY SITS -- and nil for a spot that is
	not on a rakeable field at all.

	THIS RUNS ON THE SERVER, AND THE SAND IS NOT HERE. Each field wears a loose
	top layer that the sifter cuts away column by column, and that layer is built
	PER CLIENT and carries CanQuery = false -- so the ray above cannot see it and
	stops at the terrain plane, which is the FLOOR of the channel the tool digs,
	half a stud below the sand a player is actually looking at. Seating a prop
	there buries it: measured against the catalogue, the shorter third of the
	items disappear completely under an untouched beach and most of the rest are
	peeking. Then raking the column revealed them -- so the beach appeared to get
	DIRTIER the more of it you cleaned, which is exactly backwards.

	Config.crustFor is the same answer CTB_Client's crustLift gives the
	decorative scatter (see the note beside it there, which describes this bug in
	words for the other litter system). Zero wherever a field has no crust --
	which, since 2026-09-17, is nowhere: the tomb and the shrine were the last
	two without one and both were given a crust to get a crisp swept edge, so
	their treasure and their offerings are now lifted onto the layer like
	everything else. This line used to end "so the vault is unaffected".

	The nil return doubles as the FIELD TEST. Radius 105 sits inside the beach's
	128-stud half-width so this never used to matter at boot, but reseat() below
	rolls positions for the rest of the session and a prop is only ever wanted on
	ground the tool can reach.
]]
local function fieldLift(x: number, z: number): number?
	local isl = Config.fieldAt(Vector3.new(x, 0, z))
	if not isl then
		return nil
	end
	local crust = Config.crustFor(isl)
	return crust and crust.rise or 0
end

--[[
	THE PROPS ARE THE REAL ART.

	This used to build every find as ONE PRIMITIVE PART -- def.Shape as a block,
	ball or cylinder, painted def.Color. Ninety of them, so the beach the game is
	about cleaning was ninety coloured boxes and tubes named "Crushed Can" and
	"Plastic Bottle". ItemVisuals.buildClean resolves
	ReplicatedStorage.Assets.Items.<id>.Clean instead -- the modelled art every
	one of the 41 catalogue entries already carries, and the same thing the Index,
	the reveal card and the sifter cart draw.

	SCALED, NOT SIZED. The old line was `def.Size * 1.4`, which only means
	anything to a primitive; a Model gets the same 1.4 through ScaleTo so it keeps
	its proportions.

	CanQuery goes back ON. buildClean turns it off because its usual caller is the
	wash bay, where the aim ray must reach the CRUST and never the prize -- but a
	prop lying on the sand has to be hittable or the pickup sweep cannot see it.
]]
local function dressProp(inst: Instance, queryable: boolean)
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = queryable
			d.CastShadow = false
		end
	end
end

--[[
	EVERY ENCASED FIND IS THE SAME ROCK. That is the whole mechanic: you cannot
	tell a Gold Bar from a Rolex until it is on the stand and you have blasted it,
	so the prop carries no tell -- not colour, not size, not silhouette. One
	shared model, cloned unrotated-in-kind, is the only shape that guarantees it.
	(The old version rolled one of three browns per lump, which is a tell of
	exactly the kind this comment says there must not be.)
]]
local function lumpModel(): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local rock = assets and assets:FindFirstChild("LumpRock")
	return (rock and rock:IsA("Model")) and rock or nil
end

local function buildProp(itemId: string): Instance?
	local def = ItemConfig.expect(itemId)
	local inst

	if def.Encased then
		local rock = lumpModel()
		if not rock then
			warn("[TrashSeeder] Assets.LumpRock is missing -- no crusted finds will be seeded")
			return nil
		end
		inst = rock:Clone()
		inst.Name = "Lump"
	else
		local ok, model = pcall(ItemVisuals.buildClean, itemId)
		if not ok or not model then
			warn("[TrashSeeder] no art for " .. itemId .. ": " .. tostring(model))
			return nil
		end
		inst = model
		inst.Name = def.DisplayName
		inst:ScaleTo(1.4)
	end

	dressProp(inst, true)

	inst:SetAttribute("ItemId", itemId)
	inst:SetAttribute("Weight", def.Weight)
	inst:SetAttribute("DisplayName", def.Encased and "Crusted Lump" or def.DisplayName)
	CollectionService:AddTag(inst, "CollectibleTrash")
	return inst
end

--[[
	LAY IT DOWN.

	place() used to apply a yaw and nothing else, so every prop kept whatever
	orientation its art happened to be authored in -- and a lot of that art is
	authored standing up, because that is how you model a bottle or draw a pizza
	box. Measured on a fresh seed: 14 of 90 props were stood on their edge,
	including a 4.5-stud pizza box balanced on its rim like a signpost.

	Litter on a beach has fallen over. The rule is one line: whichever axis is
	THINNEST ends up vertical. A flat box lands on its face, a crushed can lands
	on its dented side, a straw lands along the sand. It is the same rule
	CTB_Client's litterRest applies to the decorative scatter -- which is exactly
	why that scatter always looked right and these props did not.

	Returns the rotation AND the resulting vertical extent, because once a prop
	has been tipped over the sit height has to come off the axis that is now
	pointing up rather than off the authored Y. Using size.Y for a box that has
	just been laid on its face buries it.
]]
local function layFlat(size: Vector3): (CFrame, number)
	if size.Y <= size.X and size.Y <= size.Z then
		return CFrame.new(), size.Y                        -- already flattest on Y
	elseif size.X <= size.Z then
		return CFrame.Angles(0, 0, math.pi / 2), size.X    -- roll X up
	end
	return CFrame.Angles(-math.pi / 2, 0, 0), size.Z       -- pitch Z up
end

-- PivotTo, not CFrame: a prop is a Model now, and the sit height comes off its
-- bounding box rather than a single part's Size.
--
-- `accept` is an optional veto on the spot itself, given the world point the
-- prop would stand on. reseat() below passes one so a respawning prop cannot
-- land on sand somebody has already raked clean; the boot seed passes none,
-- because at boot nobody has raked anything.
local function place(inst: Instance, accept: ((Vector3) -> boolean)?)
	local _, size = inst:GetBoundingBox()
	-- Solved once, outside the retry loop: the shape does not change between
	-- candidate spots, only the ground under it does.
	local rest, height = layFlat(size)
	for _ = 1, 12 do
		local a, r = rng:NextNumber(0, math.pi * 2), math.sqrt(rng:NextNumber()) * TrashSeeder.Radius
		local x, z = math.cos(a) * r, math.sin(a) * r
		local y = groundAt(x, z)
		local lift = y and fieldLift(x, z)
		if y and lift and (not accept or accept(Vector3.new(x, y, z))) then
			-- Yaw about world up FIRST, then the lay-down: the spin has to be a
			-- compass heading on the sand, not a spin about whatever axis the prop
			-- was authored around. Reverse these two and a tipped prop cartwheels
			-- instead of turning.
			inst:PivotTo(CFrame.new(x, y + lift + height * 0.45, z)
				* CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
				* rest)
			return true
		end
	end
	return false
end

--[[
	PUT THIS ONE SOMEWHERE ELSE.

	A collected prop used to come back at the exact CFrame it was seeded at,
	which is fine for hand-placed set dressing and wrong for the beach's own
	ninety: the sand it was lying on may have been raked clean in the meantime,
	so the piece reappeared on ground the player had personally just cleared.

	TrashCollectionService calls this through its RespawnMove hook, which
	CTBBridge installs and answers with CTB's grid. False means every spot it
	tried is already clean -- the caller keeps the prop parked and asks again
	later rather than forcing it out, so a finished beach stays finished and
	fills back up when the tide turns it over.
]]
function TrashSeeder.reseat(inst: Instance, accept: ((Vector3) -> boolean)?): boolean
	return place(inst, accept)
end

function TrashSeeder.spawnOne()
	local id = ItemConfig.rollItemId(rng)
	local p = buildProp(id)
	if not p then
		return
	end
	if place(p) then
		p.Parent = folder
		-- Respawn on DESTRUCTION, so the beach never empties.
		--
		-- This is the fallback path, not the usual one. With
		-- WeightConfig.RespawnEnabled true -- which it is -- a collected prop is
		-- PARKED in ServerStorage rather than destroyed, so `parent` comes through
		-- non-nil, this body does nothing, and the piece comes back through
		-- TrashCollectionService's own respawn (which routes to reseat above).
		-- Turn RespawnEnabled off and collection destroys instead, and this is what
		-- keeps the population at ninety.
		p.AncestryChanged:Once(function(_, parent)
			if not parent then
				task.delay(TrashSeeder.RespawnDelay, function()
					if folder and folder.Parent then TrashSeeder.spawnOne() end
				end)
			end
		end)
	else
		p:Destroy()
	end
end

local started = false
function TrashSeeder.start()
	assert(RunService:IsServer(), "[TrashSeeder] server-only")
	if started then return end
	started = true

	folder = workspace:FindFirstChild("Trash")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Trash"
		folder.Parent = workspace
	end

	-- Only seed if the beach is bare, so hand-placed props are never doubled.
	if #folder:GetChildren() > 0 then
		print(string.format("[TrashSeeder] %d props already placed, not seeding", #folder:GetChildren()))
		return
	end

	local made = 0
	for _ = 1, TrashSeeder.Count do
		local before = #folder:GetChildren()
		TrashSeeder.spawnOne()
		if #folder:GetChildren() > before then made += 1 end
	end
	print(string.format("[TrashSeeder] seeded %d/%d props", made, TrashSeeder.Count))
end

return TrashSeeder
