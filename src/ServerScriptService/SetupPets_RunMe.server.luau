--[[
	SETUP: sort the imported pet pack into ReplicatedStorage.Pets

	Paste into the Roblox Studio COMMAND BAR (View -> Command Bar) and press
	Enter. Safe to run more than once: it adopts anything already filed and
	only moves what is still loose.

	It is deliberately self-contained -- the roster is embedded rather than
	required from PetConfig -- because a command-bar script has to work on a
	place where the modules are not installed yet.

	WHAT IT MATCHES
	---------------
	Anything whose name ends with a pet's name, ignoring case, underscores and
	Roblox's duplicate suffixes. All of these file as the same pet:

		Pet_Common_01_PebblePup      the FBX export's own name
		PebblePup                     hand-renamed
		PebblePup.001 / PebblePup_2   Blender / Studio duplicate suffixes

	If the importer split a pet into one MeshPart per material, the wrapping
	Model still carries the name, and the whole Model is moved.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local ROSTER = {
	Common = {
		"PebblePup", "MittenKit", "CloverBun", "AcornSquirrel", "PuddleDuckling",
		"MeadowLamb", "SpeckleHen", "CinderPiglet", "BrambleHedgehog",
		"SandyCrablet", "DuneGecko", "TideMinnow", "PocketMole", "BuckleBeetle",
		"FuzzChick", "CobbleToad", "NibbleMouse",
	},
	Uncommon = {
		"TidalTerrapin", "LongearLop", "BoulderArmadillo", "CoilSnail",
		"FanfinBetta", "TusklingBoar", "AntlerFawn", "BanditRaccoon",
		"PufferNimbus", "WaddlePenguin", "PerchOwlet", "SnorkelOtter",
		"SprigSloth",
	},
	Rare = {
		"LunarKit", "EmberwispFennec", "GlimmerMoth", "RuneGolemite",
		"FrostCubling", "ThornwoodSprout", "MistailSerpent", "PrismJelly",
		"StarfleckDeer", "CinderImp", "AuroraAxolotl", "GrimoireBat",
		"SandwhisperDjinn",
	},
	Epic = {
		"Rustclaw", "MagmaColossus", "VoltaicWolf", "Gearhawk",
		"TidebreakerKraken", "CryoRhino", "ScrapheapSentinel",
		"EmberforgeSalamander", "TempestRay", "ChronoBeetle",
	},
	Legendary = {
		"Trihedron", "AegisWarden", "VoidSerpentEmperor", "SolarisPhoenix",
		"TitanCorebreaker", "CelestialKirin", "AbyssalLeviathan",
	},
}

local TIER_ORDER = { "Common", "Uncommon", "Rare", "Epic", "Legendary" }

-- Lowercased, letters and digits only. "Pet_Common_01_PebblePup" ->
-- "petcommon01pebblepup", which still ENDS WITH "pebblepup".
local function norm(s)
	return (s:lower():gsub("[^%a%d]", ""))
end

-- Longest first, so "CinderPiglet" can never be claimed by a shorter name that
-- happens to be a suffix of it.
local lookup = {}
for _, tier in TIER_ORDER do
	for i, name in ROSTER[tier] do
		table.insert(lookup, {
			key = norm(name),
			name = name,
			tier = tier,
			canonical = string.format("Pet_%s_%02d_%s", tier, i, name),
		})
	end
end
table.sort(lookup, function(a, b)
	return #a.key > #b.key
end)

local function identify(instanceName)
	local n = norm(instanceName)
	-- Blender's ".001" and Studio's " (2)" both survive norm() as trailing
	-- digits, so try the trimmed form as well.
	local trimmed = n:gsub("%d+$", "")
	for _, row in lookup do
		if n:sub(-#row.key) == row.key or trimmed:sub(-#row.key) == row.key then
			return row
		end
	end
	return nil
end

-- Folders
local pets = ReplicatedStorage:FindFirstChild("Pets")
if not pets then
	pets = Instance.new("Folder")
	pets.Name = "Pets"
	pets.Parent = ReplicatedStorage
end

local tierFolder = {}
for _, tier in TIER_ORDER do
	local f = pets:FindFirstChild(tier)
	if not f then
		f = Instance.new("Folder")
		f.Name = tier
		f.Parent = pets
	end
	tierFolder[tier] = f
end

-- Anything already filed counts as done.
local filed = {}
for _, tier in TIER_ORDER do
	for _, child in tierFolder[tier]:GetChildren() do
		local row = identify(child.Name)
		if row then
			filed[row.name] = true
			if child.Name ~= row.canonical then
				child.Name = row.canonical
			end
		end
	end
end

-- Search the usual landing spots. Descendants, not children: an FBX import
-- arrives wrapped in a Model.
local roots = { workspace, ReplicatedStorage, ServerStorage }
local claimed, skipped = {}, 0

for _, root in roots do
	for _, inst in root:GetDescendants() do
		if inst:IsA("Model") or inst:IsA("BasePart") then
			--[[
				Skip only what is already IN A TIER FOLDER.

				This used to skip everything under ReplicatedStorage.Pets, which
				sounds equivalent and is not: the FBX import had been dropped at
				Pets/CleanTheBeach60Pets, one level above the tier folders, so
				all sixty were "already in place" and the script filed nothing
				and reported sixty missing. Where the import lands is the user's
				choice, and Pets is a perfectly sensible place to put it.
			]]
			local alreadyFiled = false
			for _, tf in tierFolder do
				if inst:IsDescendantOf(tf) then
					alreadyFiled = true
					break
				end
			end
			if not alreadyFiled then
				local row = identify(inst.Name)
				if row and not filed[row.name] and not claimed[row.name] then
					-- Prefer the outermost instance carrying this name, so a
					-- material-split pet moves as one Model rather than as
					-- loose MeshParts.
					local best = inst
					local walk = inst.Parent
					while walk and walk ~= root do
						if (walk:IsA("Model") or walk:IsA("BasePart"))
							and identify(walk.Name) == row
						then
							best = walk
						end
						walk = walk.Parent
					end
					claimed[row.name] = { instance = best, row = row }
				end
			end
		end
	end
end

local moved = 0
for _, entry in claimed do
	local ok, err = pcall(function()
		entry.instance.Name = entry.row.canonical
		entry.instance.Parent = tierFolder[entry.row.tier]
		if entry.instance:IsA("BasePart") then
			entry.instance.Anchored = true
		else
			for _, d in entry.instance:GetDescendants() do
				if d:IsA("BasePart") then
					d.Anchored = true
				end
			end
		end
	end)
	if ok then
		moved += 1
		filed[entry.row.name] = true
	else
		skipped += 1
		warn("[PetSetup] could not file", entry.row.name, err)
	end
end

-- Report
local missing = {}
for _, tier in TIER_ORDER do
	local have = 0
	for _, name in ROSTER[tier] do
		if filed[name] then
			have += 1
		else
			table.insert(missing, tier .. "/" .. name)
		end
	end
	print(string.format("[PetSetup] %-10s %2d / %2d", tier, have, #ROSTER[tier]))
end

print(string.format("[PetSetup] moved %d this run, %d failed", moved, skipped))

-- Anything left behind by the import is REPORTED, never deleted -- what is in
-- the place file is the user's call.
for _, root in { workspace, ReplicatedStorage } do
	for _, inst in root:GetDescendants() do
		if inst:IsA("Folder") or inst:IsA("Model") then
			local leftovers = #inst:GetChildren()
			if leftovers > 0 and inst.Name:lower():find("pets") and not inst:IsDescendantOf(pets) then
				print(string.format("[PetSetup] import wrapper still at %s (%d left inside)",
					inst:GetFullName(), leftovers))
			end
		end
	end
end
if #missing > 0 then
	warn(string.format("[PetSetup] %d models not found: %s",
		#missing, table.concat(missing, ", ")))
else
	print("[PetSetup] all 60 pets are filed. Nothing else to do.")
end
