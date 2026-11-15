--[[
	ServiceClearance  --  ServerScriptService.ServiceClearance

	Keeps the ground around every service point walkable.

	THE PROBLEM THIS EXISTS FOR
	---------------------------
	Every island dresses its plaza -- stone lanterns, banner poles, votive racks,
	tiki torches, water troughs, crates -- and none of it is placed against the
	buildings on purpose. The services and the dressing are laid out by different
	passes, so where one happens to land beside the other the player is left
	threading a two-stud gap to reach a prompt.

	Measured in the place before this pass existed:

		cove   the omikuji rack stood INSIDE the car pad's own footprint with a leg
		       nine studs up the exit lane, so a quad drove into it pulling away;
		       the ema board stood 0.1 studs off the wash bay's wall; and a
		       komainu, a stone lantern and a banner pole all touched the kakigori
		       stall.
		dunes  a water trough 2.2 studs off the wash bay.
		ash    a water trough 1.2 studs off the wash bay.

	WHY A RUNTIME PASS AND NOT A FIX IN EACH BUILDER
	------------------------------------------------
	Because the islands do not agree on where their geometry comes from, and the
	two answers need opposite fixes:

		Island2, Island3   carry the HandBuilt attribute, so their builders ADOPT
		                   the place file and return before their own layout code
		                   runs. Editing those builders changes nothing you can
		                   see.
		Island4            has no such attribute and is rebuilt from source on
		                   every boot, so editing ITS workspace geometry is wiped
		                   before the first player joins.

	One pass over the finished world is the only fix that lands on both, and it
	keeps working when somebody adds a lantern later or flips HandBuilt either
	way. That is the same shape as SignDresser: re-assert over whatever is
	actually standing, rather than trying to fix every path that could have put
	it there.

	WHAT IT CHANGES
	---------------
	It sets CanCollide = false on DRESSING that intrudes on a service apron.
	Nothing moves and nothing is deleted -- the island looks identical, you
	simply stop catching on the scenery beside the shop.

	WHAT IT REFUSES TO TOUCH
	------------------------
	Anything not named in DRESSING below stays solid, so walls, counters, kerbs,
	decks and the posts holding a roof up are never softened. The four KaguraPosts
	over the cove's car pad and the four WaterHouse posts over the dune bay are
	load-bearing TO THE EYE, and a player walking through a pillar reads as a
	broken game where a player walking through a paper lantern reads as nothing at
	all. Trees and tents are off the list for the same reason: a sakura you can
	walk through is worse than one you walk around.

	Anything left solid inside an apron is NAMED in the boot log, so the next
	person to find a gap they cannot fit through knows what to go and look at.

	CanQuery and CanTouch are deliberately left alone. The pickup sweep and the
	field raycasts run through those, and a prop that stopped answering raycasts
	would change where litter can be found -- which is not what this is for.

	WHEN IT RUNS
	------------
	CTB_Server calls apply() after the last island builder and after the ferry,
	because Island4Builder rebuilds its whole island and would otherwise put the
	solid copies back a beat later. It is idempotent: calling it again is free,
	and every part it changes is marked with the CLEARED attribute so a human can
	find them all with a single search.
]]

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local ServiceClearance = {}

--------------------------------------------------------------------------
-- THE APRON
--------------------------------------------------------------------------
-- Studs of walkable ground kept around a service's own footprint. Four is the
-- width of the character plus room to turn: below that you are steering, and
-- steering past a lantern to reach a prompt is the complaint this fixes.
local MARGIN = 4.0

-- The band a walking character actually occupies. STEP_OVER is the bottom of
-- it: a Humanoid climbs anything shorter than this without noticing, so a kerb
-- or a floor mat is not an obstacle and must not be counted as one.
local STEP_OVER = 1.3
local BODY_TOP = 5.5

-- The car pad's exit. A machine leaves along the SpawnPoint's +Z -- ZVector,
-- NOT LookVector, which is its negative; see the note in AtvServer.drive(). The
-- lane is wider than a quad because a quad that has to be threaded out of its
-- own pad is the same bug at the wheel instead of on foot.
local LANE_LENGTH = 26
local LANE_WIDTH = 11

-- A model bigger than this in plan is not a shop, it is the whole island
-- section the shop stands in -- Ashfall's prompt hangs off Landing, which is
-- 253 studs across. Past this we apron the prompt anchor instead.
local BIG_MODEL = 60
local ANCHOR_APRON = 14

-- Size guard on DRESSING, so that a future prop which merely borrows one of
-- these names cannot be softened if it is actually a building.
local MAX_SPAN = 14
local MAX_RISE = 16

ServiceClearance.CLEARED = "ClearedForService"

--[[
	THE DRESSING. Named rather than inferred from size, because size does not
	separate the two cases: a NoboriPole and a roof pillar are both thin and
	tall, and only one of them is holding something up.

	These are the model or part names as the island builders write them. A name
	that is not here is left solid, which is the safe direction to be wrong in --
	the cost is a snag that gets reported in the log, not a hole in a building.
]]
local DRESSING = {
	-- Sakura Cove
	StoneLantern = true, PaperLantern = true, Komainu = true, VendingMachine = true,
	EmaKake = true, OmikujiRack = true, Saisenbako = true, Nemaki = true,
	Chozubachi = true, ChozuWell = true, ChozuRim = true, Hishaku = true,
	NoboriPole = true, NoboriCloth = true, NoboriBand = true, NoboriArm = true,
	Shide = true, Shimenawa = true, Suzu = true, SuzuRope = true,

	-- Ashfall Isle
	TikiTorch = true, Brazier = true, CampCrate = true, Sack = true,

	-- the dunes, and the two that turn up on more than one island
	Urn = true, Spout = true, Crate = true,
	Trough = true, TroughWater = true,

	-- Penguin Island (Island5Props): crates, barrels, sleds, drifts, cairns,
	-- the campfire and the presents under the tree. Lamp posts, snowmen and
	-- the birds stay solid -- a lamp is a post and a penguin is a penguin.
	Box = true, Lid = true, Batten = true, Slat = true, Drum = true, RimTop = true, RimBottom = true,
	Runner = true, RunnerToe = true, HandleBar = true, HandleUpright = true, Drift = true, Stone = true,
	Log = true, Flame = true, Embers = true, Ash = true, Ribbon = true, BowLoop = true, BowKnot = true,
	Tin = true, Bulb = true, Cord = true,

	-- The Frozen Wreck (WreckProps): trunks, barrels, rope, nets and the rime
	-- on everything, which is what stands beside the purser's office.
	Trunk = true, Stave = true, Strap = true, Lock = true, LidDome = true, Net = true, NetFrost = true,
	RopeLoop = true, Turn = true, Frost = true, InsideFrost = true, Corner = true, BandLow = true,
	BandHigh = true, Streak = true,
}

--------------------------------------------------------------------------
-- RESOLVING WHAT COUNTS AS A SERVICE
--------------------------------------------------------------------------
local function islandOf(inst: Instance): Instance?
	local node = inst
	while node and node.Parent and node.Parent ~= workspace do
		node = node.Parent
	end
	return (node and node.Parent == workspace) and node or nil
end

-- An apron box in the rig's OWN frame, so a rotated rig gets a rotated apron.
-- The cove's wash bay is pivoted a quarter turn; an axis-aligned box round it
-- would reach four studs past one wall and nothing at all past another.
local function apronOf(cf: CFrame, size: Vector3, margin: number)
	local footing = cf.Position.Y - size.Y / 2
	local band = BODY_TOP - STEP_OVER
	local centre = Vector3.new(cf.Position.X, footing + STEP_OVER + band / 2, cf.Position.Z)
	return (cf - cf.Position) + centre,
		Vector3.new(size.X + margin * 2, band, size.Z + margin * 2),
		footing
end

local function collect(): { any }
	local points = {}

	-- SandbotDock is on this list for the same reason the other two are, and not
	-- because anything is blocking one today: every dock in the game was placed
	-- on ground this module's own body-band test found clear. It is here so that
	-- the dock beside a LATER car spawner -- or beside one somebody moves -- is
	-- covered by the pass rather than by somebody having remembered to check.
	for _, tag in ipairs({ "WashBay", "CarSpawner", "SandbotDock" }) do
		for _, rig in ipairs(CollectionService:GetTagged(tag)) do
			if rig:IsDescendantOf(workspace) and rig:IsA("Model") then
				local cf, size = rig:GetBoundingBox()
				local box, extent, footing = apronOf(cf, size, MARGIN)
				table.insert(points, {
					kind = tag, name = rig.Name, rig = rig,
					box = box, extent = extent, footing = footing,
				})

				if tag == "CarSpawner" then
					local spawn = rig:FindFirstChild("SpawnPoint", true)
					if spawn and spawn:IsA("BasePart") then
						-- +Z is the nose. The lane keeps the SpawnPoint's rotation and
						-- only its position is moved, so the box runs straight down the
						-- drive however the pad is turned.
						local band = BODY_TOP - STEP_OVER
						local foot = spawn.Position.Y - spawn.Size.Y / 2
						local mid = spawn.Position + spawn.CFrame.ZVector * (LANE_LENGTH / 2)
						table.insert(points, {
							kind = "CarLane", name = rig.Name .. " exit", rig = rig,
							box = (spawn.CFrame - spawn.Position)
								+ Vector3.new(mid.X, foot + STEP_OVER + band / 2, mid.Z),
							extent = Vector3.new(LANE_WIDTH, band, LANE_LENGTH),
							footing = foot,
						})
					end
				end
			end
		end
	end

	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "ShopPrompt" then
			local anchor = d.Parent
			local owner = anchor and anchor.Parent
			if anchor and anchor:IsA("BasePart") and owner then
				local cf, size
				if owner:IsA("Model") then
					cf, size = owner:GetBoundingBox()
				end
				-- Ashfall hangs its prompt off Landing, the whole arrival terrace. An
				-- apron round THAT is an apron round the island.
				if (not cf) or math.max(size.X, size.Z) > BIG_MODEL then
					cf, size, owner = anchor.CFrame,
						Vector3.new(ANCHOR_APRON, BODY_TOP, ANCHOR_APRON), anchor
					local box, extent, footing = apronOf(cf, size, 0)
					table.insert(points, { kind = "Shop", name = d.ObjectText, rig = owner,
						box = box, extent = extent, footing = footing })
				else
					local box, extent, footing = apronOf(cf, size, MARGIN)
					table.insert(points, { kind = "Shop", name = d.ObjectText, rig = owner,
						box = box, extent = extent, footing = footing })
				end
			end
		elseif d:IsA("BasePart") and d.Name == "SellPad" then
			local box, extent, footing = apronOf(d.CFrame, d.Size, MARGIN)
			table.insert(points, {
				kind = "Sell", name = (d.Parent and d.Parent.Name or "?"), rig = d,
				box = box, extent = extent, footing = footing,
			})
		end
	end

	return points
end

--------------------------------------------------------------------------
-- IS THIS PART DRESSING?
--------------------------------------------------------------------------
-- Walks up from the part to the island folder looking for a DRESSING name. The
-- intruders are almost never named themselves -- a komainu presents as Paw,
-- Haunch, Chest and Tail -- so the question is which UNIT the part belongs to,
-- and the whole unit is softened together or not at all.
local function dressingUnit(part: BasePart, island: Instance): Instance?
	local node: Instance? = part
	while node and node ~= island and node ~= workspace do
		if DRESSING[node.Name] then
			local size
			if node:IsA("Model") then
				local _, s = node:GetBoundingBox()
				size = s
			elseif node:IsA("BasePart") then
				size = node.Size
			end
			if size and math.max(size.X, size.Z) <= MAX_SPAN and size.Y <= MAX_RISE then
				return node
			end
			return nil
		end
		node = node.Parent
	end
	return nil
end

--------------------------------------------------------------------------
-- THE PASS
--------------------------------------------------------------------------
function ServiceClearance.apply(): (number, number)
	assert(RunService:IsServer(), "[ServiceClearance] server-only")

	local points = collect()
	local freedUnits, freedParts = {}, 0
	local stubborn = {}

	for _, point in ipairs(points) do
		local island = islandOf(point.rig)
		if island then
			local params = OverlapParams.new()
			params.MaxParts = 3000
			local hits = workspace:GetPartBoundsInBox(point.box, point.extent, params)

			for _, part in ipairs(hits) do
				-- ANCHORED ONLY. Clearing CanCollide on a loose part does not hold it
				-- up -- it takes away the floor it was resting on, and the prop leaves
				-- the map. Every island builder anchors its dressing, so this costs
				-- nothing today and is the difference between a snag and a hole the
				-- first time somebody drops in a prop they forgot to anchor.
				if part.CanCollide and part.Anchored
					and part ~= point.rig and not part:IsDescendantOf(point.rig) then
					-- Anything a Humanoid steps straight over is not in the way.
					if part.Position.Y + part.Size.Y / 2 > point.footing + STEP_OVER then
						local unit = dressingUnit(part, island)
						if unit then
							part.CanCollide = false
							part:SetAttribute(ServiceClearance.CLEARED, true)
							freedParts += 1
							freedUnits[unit] = true
						else
							local key = string.format("%s/%s", point.name, part.Name)
							stubborn[key] = (stubborn[key] or 0) + 1
						end
					end
				end
			end
		end
	end

	local unitCount = 0
	for _ in pairs(freedUnits) do
		unitCount += 1
	end

	print(string.format(
		"[ServiceClearance] %d service points; %d parts across %d props made pass-through",
		#points, freedParts, unitCount))

	--[[
		NAMED, NOT COUNTED. Everything below is solid geometry standing inside a
		service apron -- which is USUALLY right (a shop's own counter, a kerb, the
		pillars holding a roof up) and is occasionally the next version of the bug
		this module exists for. "7 obstacles remain" would not tell anybody which.
	]]
	local names = {}
	for key, n in pairs(stubborn) do
		table.insert(names, (n > 1) and (key .. " x" .. n) or key)
	end
	if #names > 0 then
		table.sort(names)
		print("[ServiceClearance] still solid inside an apron (by design unless it blocks): "
			.. table.concat(names, ", "))
	end

	return freedParts, unitCount
end

return ServiceClearance
