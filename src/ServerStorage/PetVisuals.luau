--[[
	PetVisuals  --  ReplicatedStorage.Modules.PetVisuals

	What a pet LOOKS like. PetConfig says a pet exists, which tier it is and
	what it is worth; this says it is a rust-red fennec that trails embers.

	THE PROBLEM THIS SOLVES
	-----------------------
	The sixty meshes arrive from the exporter as one bare MeshPart each -- no
	texture, no vertex colour, no children. Sixty identical grey animals, told
	apart only by silhouette. Tier was legible on the reveal card and nowhere
	on the pet itself, so three Legendaries following you looked exactly like
	three Commons.

	WHY THE EFFECTS ARE NOT BAKED INTO THE STORED MODELS
	----------------------------------------------------
	The base colour and material ARE painted onto the library copies -- see
	PetVisuals.paintLibrary -- so nothing is grey in the explorer, in a
	viewport, or in any future inventory panel. The EFFECTS deliberately are
	not:

		* a stored emitter rides along into every clone, including the ones a
		  UI ViewportFrame makes, where particles are pure cost and are not
		  even simulated;
		* effects have to be sized to the pet's FINAL scale, and a pet is
		  scaled differently by the follow rig (2.6 studs) and by the hatch
		  reveal (4.2) -- so they are built AFTER the scaling, not before, or
		  every number would need two versions.

	So: one function, called at both spawn sites, that measures what it has
	been handed and dresses it to fit.

	SIZING RULE  --  everything is a fraction of `half`
	---------------------------------------------------
	`half` is half the pet's largest dimension. Every offset, particle size,
	speed, acceleration and light range below is a multiple of it. Nothing in
	this file is in absolute studs, which is what lets one palette row dress
	an 18-stud Leviathan and a 4-stud minnow without either looking wrong.

	BUDGET  --  three pets each, and everyone's are on your screen
	-------------------------------------------------------------
	A player has three out and a full server can put sixty in one view. So the
	ceiling is deliberately low: at most two emitters per pet, rates in single
	digits for the low tiers, PointLights only from Rare up and never with
	Shadows, and the rarity ring is two Beams on four Attachments rather than
	the dozen little parts it looks like.

	ADDING A PET
	------------
	Add a row to PALETTE keyed by PetConfig's PetId. `fx` names a row in FX;
	if you want a new effect, add a row there rather than a special case here.
	A pet with no PALETTE row still works -- it comes out in its tier colour
	with the tier aura, which is exactly what the old grey pets got.
]]

local PetVisuals = {}

local PetConfig = require(script.Parent:WaitForChild("PetConfig"))

local C3 = Color3.fromRGB
local M = Enum.Material

--------------------------------------------------------------------------
-- TEXTURES
--------------------------------------------------------------------------
-- Engine built-ins only. An uploaded particle sheet would be one more asset
-- to moderate and one more thing that can 404 on a fresh place; these five
-- plus colour, squash and rotation cover every effect below.
local TEX = {
	spark = "rbxasset://textures/particles/sparkles_main.dds",           -- six-point star
	fire  = "rbxasset://textures/particles/fire_main.dds",               -- torn flame
	smoke = "rbxasset://textures/particles/smoke_main.dds",              -- soft puff
	blob  = "rbxasset://textures/particles/explosion01_implosion_main.dds", -- round bead
	wisp  = "rbxasset://textures/particles/explosion01_smoke_main.dds",  -- thin streak cloud
}

--------------------------------------------------------------------------
-- WHERE ON THE ANIMAL
--------------------------------------------------------------------------
--[[
	The meshes share a convention: X is width, Y is height, Z is length, and
	the HEAD IS AT -Z. That last one is not a guess -- it is what makes
	PetServer's `CFrame.lookAt(goal, goal + hrp.LookVector)` point pets the
	same way the player is walking, since a part's LookVector is its -Z.

	Offsets are fractions of the mesh's own size, so "head" lands on the head
	of a long leviathan and of a squat toad alike.
]]
local PLACE = {
	core  = function(S) return Vector3.new(0, 0, 0) end,
	feet  = function(S) return Vector3.new(0, -S.Y * 0.44, 0) end,
	head  = function(S) return Vector3.new(0, S.Y * 0.16, -S.Z * 0.34) end,
	front = function(S) return Vector3.new(0, 0, -S.Z * 0.46) end,
	back  = function(S) return Vector3.new(0, S.Y * 0.40, S.Z * 0.04) end,
	tail  = function(S) return Vector3.new(0, 0, S.Z * 0.42) end,
	halo  = function(S) return Vector3.new(0, S.Y * 0.62, 0) end,
}

--------------------------------------------------------------------------
-- EFFECT RECIPES
--------------------------------------------------------------------------
--[[
	A row is a plain table read by makeEmitter below. Only `tex` is required;
	everything else has a sane default, so a new effect is usually four or
	five lines.

		place   PLACE key                        (default "core")
		rate    particles/second at 1x           (tier scales it)
		size    peak size, fraction of `half`
		grow    true = start small and swell, smoke-fashion
		life    {min, max} seconds
		speed   {min, max}, fraction of `half` per second
		spread  degrees, both axes
		dir     emission face                    (default Top)
		accel   vertical only, fraction of `half` per second squared
		drag    engine drag
		spin    {min, max} degrees/second
		squash  >1 stretches along travel; pair with orient for speed lines
		orient  "VelocityParallel" for streaks
		shape   Sphere | Box | Cylinder | Disc   (default Sphere)
		style   Volume | Surface                 (default Volume)
		inout   Outward | Inward | InAndOut
		colors  list of Color3, or the strings "body" / "accent" / "tier"
		t       held transparency, 0 = solid
		glow    LightEmission 0..1
		lock    true = particles ride the pet instead of being left behind

	`colors` resolving to strings is the whole reason one recipe can serve
	nine pets: "leaf" on a fawn is tan, on a sloth it is moss, and neither
	needed its own row.
]]
local function derive(base, over)
	local t = table.clone(base)
	for k, v in over do
		t[k] = v
	end
	return t
end

local FX = {}

-- --- EARTH, AIR, LITTLE ANIMALS ---------------------------------------
FX.dust = {
	tex = "smoke", place = "feet", rate = 5, size = 0.15, grow = true,
	life = {0.45, 0.8}, speed = {0.10, 0.35}, spread = 30, accel = 0.25,
	colors = {"accent"}, t = 0.40, glow = 0.05, spin = {-30, 30},
}
FX.fluff = {
	tex = "blob", place = "core", rate = 4, size = 0.09,
	life = {0.9, 1.6}, speed = {0.08, 0.25}, spread = 180, accel = 0.12,
	drag = 1.2, colors = {"accent"}, t = 0.18, glow = 0.25,
	shape = "Sphere", style = "Volume",
}
FX.leaf = {
	tex = "spark", place = "back", rate = 4, size = 0.11,
	life = {0.9, 1.5}, speed = {0.15, 0.45}, spread = 90, accel = -0.5,
	drag = 1.6, spin = {-140, 140}, colors = {"accent"}, t = 0.15, glow = 0.15,
	squash = 1.6,
}
FX.bloom = derive(FX.leaf, { glow = 0.85, t = 0.05, rate = 6, place = "core", spread = 180 })
FX.pollen = {
	tex = "spark", place = "core", rate = 5, size = 0.07,
	life = {1.1, 1.9}, speed = {0.10, 0.30}, spread = 180, accel = 0.18,
	drag = 1.0, colors = {"accent"}, t = 0.1, glow = 0.7, spin = {-40, 40},
	shape = "Sphere", style = "Surface", inout = "Outward",
}
FX.glimmer = derive(FX.pollen, { size = 0.10, rate = 8, glow = 1, t = 0, spin = {-90, 90} })
FX.feather = {
	tex = "blob", place = "back", rate = 4, size = 0.13,
	life = {1.2, 2.0}, speed = {0.10, 0.30}, spread = 120, accel = -0.35,
	drag = 2.2, spin = {-60, 60}, squash = 2.0, colors = {"accent"},
	t = 0.16, glow = 0.2,
}
FX.droplet = {
	tex = "blob", place = "feet", rate = 6, size = 0.08,
	life = {0.35, 0.7}, speed = {0.25, 0.6}, spread = 55, accel = -2.2,
	colors = {"accent"}, t = 0.25, glow = 0.35,
}
FX.bubble = {
	tex = "blob", place = "core", rate = 6, size = 0.10,
	life = {0.9, 1.6}, speed = {0.20, 0.5}, spread = 60, accel = 0.55,
	drag = 0.8, colors = {"accent"}, t = 0.45, glow = 0.4,
	shape = "Sphere", style = "Volume",
}
FX.sand = {
	tex = "smoke", place = "feet", rate = 7, size = 0.13, grow = true,
	life = {0.5, 0.9}, speed = {0.25, 0.6}, spread = 40, accel = -0.3,
	colors = {"accent", "body"}, t = 0.45, glow = 0.1, spin = {-50, 50},
}
FX.cloud = {
	tex = "smoke", place = "core", rate = 4, size = 0.24, grow = true,
	life = {1.2, 2.0}, speed = {0.05, 0.2}, spread = 180, accel = 0.05,
	drag = 1.5, colors = {"accent"}, t = 0.62, glow = 0.35,
	shape = "Sphere", style = "Surface", inout = "Outward", lock = true,
}
FX.mist = derive(FX.cloud, { place = "feet", size = 0.22, t = 0.7, accel = -0.05, rate = 5 })
FX.snow = {
	tex = "spark", place = "halo", rate = 7, size = 0.07,
	life = {1.0, 1.7}, speed = {0.10, 0.30}, spread = 180, accel = -0.55,
	drag = 1.8, spin = {-90, 90}, colors = {"accent"}, t = 0.1, glow = 0.75,
}
FX.blizzard = derive(FX.snow, { rate = 14, size = 0.10, speed = {0.35, 0.9}, spread = 180, drag = 0.9 })

-- --- FIRE, FORGE, STORM ------------------------------------------------
FX.ember = {
	tex = "fire", place = "back", rate = 8, size = 0.16,
	life = {0.4, 0.8}, speed = {0.35, 0.9}, spread = 35, accel = 1.4,
	colors = {C3(255, 240, 180), "accent", C3(150, 40, 12)}, t = 0.1, glow = 0.9,
	spin = {-120, 120},
}
FX.magma = derive(FX.ember, {
	place = "core", rate = 13, size = 0.19, life = {0.5, 1.0},
	speed = {0.4, 1.1}, spread = 65, shape = "Sphere", style = "Surface",
	inout = "Outward",
})
-- Its own ramp rather than magma's: magma ends on a dark ember red, and
-- on a white-hot bird that tail reads as a column of grey smoke coming off it.
FX.solar = derive(FX.magma, { rate = 18, size = 0.24, glow = 1, t = 0, accel = 1.8,
	colors = {C3(255, 252, 226), C3(255, 186, 66), C3(255, 96, 28)} })
FX.core = {
	tex = "blob", place = "core", rate = 10, size = 0.20,
	life = {0.5, 0.9}, speed = {0.5, 1.2}, spread = 180, accel = 0,
	colors = {C3(255, 236, 200), "accent"}, t = 0, glow = 1,
	shape = "Sphere", style = "Surface", inout = "Inward", lock = true,
}
FX.spark = {
	tex = "spark", place = "back", rate = 9, size = 0.10,
	life = {0.3, 0.6}, speed = {0.8, 2.0}, spread = 180, accel = -1.6,
	colors = {C3(255, 246, 210), "accent"}, t = 0, glow = 1, squash = 2.4,
	orient = "VelocityParallel",
}
FX.lightning = derive(FX.spark, { rate = 14, size = 0.12, squash = 4.5, accel = 0, life = {0.18, 0.4}, speed = {1.4, 3.2} })
FX.gear = derive(FX.spark, { rate = 6, size = 0.08, squash = 1.4, orient = nil, place = "tail", accel = -2.4 })
FX.rust = {
	tex = "smoke", place = "back", rate = 5, size = 0.13, grow = true,
	life = {0.6, 1.1}, speed = {0.15, 0.4}, spread = 120, accel = -0.6,
	drag = 1.4, colors = {"accent", "body"}, t = 0.4, glow = 0.05, spin = {-70, 70},
}
FX.storm = {
	tex = "wisp", place = "core", rate = 8, size = 0.17,
	life = {0.4, 0.8}, speed = {1.0, 2.4}, spread = 180, accel = 0,
	colors = {"accent"}, t = 0.25, glow = 0.85, squash = 3.2,
	orient = "VelocityParallel", shape = "Sphere", style = "Surface", inout = "Outward",
}

-- --- MAGIC, VOID, THE HEAVENS ------------------------------------------
FX.rune = {
	tex = "spark", place = "core", rate = 7, size = 0.12,
	life = {0.8, 1.4}, speed = {0.05, 0.2}, spread = 180, accel = 0.1,
	colors = {"accent"}, t = 0, glow = 1, spin = {-160, 160}, lock = true,
	shape = "Sphere", style = "Surface", inout = "Outward",
}
FX.sacred = derive(FX.rune, { rate = 10, size = 0.15, spin = {-70, 70}, squash = 1.8 })
FX.moonlight = {
	tex = "blob", place = "core", rate = 6, size = 0.13,
	life = {1.2, 2.0}, speed = {0.08, 0.22}, spread = 180, accel = 0.14,
	drag = 1.1, colors = {"accent", C3(236, 246, 255)}, t = 0.15, glow = 1,
	shape = "Sphere", style = "Surface", inout = "Outward", lock = true,
}
FX.starlight = {
	tex = "spark", place = "core", rate = 8, size = 0.12,
	life = {0.7, 1.3}, speed = {0.10, 0.35}, spread = 180, accel = 0.2,
	colors = {C3(255, 255, 236), "accent"}, t = 0, glow = 1, spin = {-40, 40},
	shape = "Sphere", style = "Surface", inout = "Outward",
}
FX.celestial = derive(FX.starlight, { rate = 13, size = 0.16, squash = 1.7, life = {0.9, 1.6} })
FX.aurora = {
	tex = "wisp", place = "back", rate = 5, size = 0.21, grow = true,
	life = {1.1, 1.9}, speed = {0.10, 0.3}, spread = 120, accel = 0.22,
	drag = 1.3, colors = {C3(120, 255, 214), "accent", C3(150, 170, 255)},
	t = 0.35, glow = 1, spin = {-30, 30}, squash = 2.2,
}
FX.prism = {
	tex = "spark", place = "core", rate = 10, size = 0.11,
	life = {0.8, 1.4}, speed = {0.15, 0.45}, spread = 180, accel = 0.1,
	colors = {C3(255, 120, 160), C3(255, 226, 120), C3(120, 255, 190), C3(140, 180, 255)},
	t = 0, glow = 1, spin = {-120, 120},
	shape = "Sphere", style = "Surface", inout = "Outward",
}
FX.void = {
	tex = "smoke", place = "core", rate = 9, size = 0.16, grow = true,
	life = {0.6, 1.1}, speed = {0.5, 1.3}, spread = 180, accel = 0,
	colors = {"accent", C3(26, 10, 40)}, t = 0.2, glow = 0.6,
	shape = "Sphere", style = "Surface", inout = "Inward", spin = {-80, 80},
}
FX.holy = {
	tex = "wisp", place = "feet", rate = 9, size = 0.16,
	life = {0.7, 1.2}, speed = {0.6, 1.4}, spread = 12, accel = 0.6,
	colors = {"accent", C3(255, 252, 236)}, t = 0.1, glow = 1, squash = 3.4,
	shape = "Cylinder", style = "Surface", lock = true,
}
FX.abyss = {
	tex = "blob", place = "core", rate = 7, size = 0.12,
	life = {1.2, 2.1}, speed = {0.15, 0.4}, spread = 180, accel = 0.3,
	drag = 0.9, colors = {"accent"}, t = 0.15, glow = 1,
	shape = "Sphere", style = "Surface", inout = "Outward",
}
FX.chrono = {
	tex = "spark", place = "core", rate = 9, size = 0.13,
	life = {1.0, 1.6}, speed = {0, 0.1}, spread = 180, accel = 0,
	colors = {"accent", C3(255, 246, 200)}, t = 0.05, glow = 1,
	spin = {-200, 200}, lock = true,
	shape = "Cylinder", style = "Surface", inout = "Outward",
}
FX.sandstorm = derive(FX.sand, {
	place = "core", rate = 11, size = 0.16, spread = 180, accel = 0.1,
	drag = 1.2, shape = "Sphere", style = "Surface", inout = "Outward",
	lock = true, t = 0.5,
})
--------------------------------------------------------------------------
-- THE PALETTE
--------------------------------------------------------------------------
--[[
	Sixty rows: body colour, surface material, accent colour, effect.

	The accent is the pet's SECOND colour and it is doing more work than it
	looks like -- a mesh is one part and can only be one colour, so the accent
	is the only way a pig reads as pink-with-soot rather than just pink. It
	tints the effect, the trail and the rarity ring, so it is what you
	actually see moving.

	Materials are picked for the surface break-up they give a flat-shaded
	low-poly mesh at noon (the game pins ClockTime to 12): Slate and Pebble
	granulate stone, Fabric and Grass fuzz fur and moss, Ice and Glass go
	translucent, CorrodedMetal and DiamondPlate carry their own grime. Neon is
	deliberately absent -- it discards all the facet shading these meshes are
	made of and turns a fox into a yellow blob. It is used only on the rarity
	ring and the Legendary aura shell, where flatness is the point.
]]
local PALETTE = {}

local function pet(id, body, mat, accent, fx, extra)
	local row = extra or {}
	row.body, row.mat, row.accent, row.fx = body, mat, accent, fx
	PALETTE[id] = row
end

-- COMMON  --  farmyard and rockpool. Earth tones, matte surfaces, small
-- effects that sit at the feet rather than around the head.
pet("PebblePup",        C3(134, 146, 160), M.Slate,         C3(214, 220, 228), "dust")
pet("MittenKit",        C3(228, 146,  74), M.Fabric,        C3(255, 238, 212), "fluff")
pet("CloverBun",        C3(243, 233, 208), M.Fabric,        C3(124, 198,  98), "leaf")
pet("AcornSquirrel",    C3(170,  98,  52), M.Wood,          C3(228, 188, 122), "leaf")
pet("PuddleDuckling",   C3(250, 206,  72), M.SmoothPlastic, C3(120, 196, 226), "droplet")
pet("MeadowLamb",       C3(245, 241, 232), M.Fabric,        C3(214, 194, 172), "pollen")
pet("SpeckleHen",       C3(233, 225, 213), M.Fabric,        C3(216,  62,  54), "feather")
pet("CinderPiglet",     C3(238, 150, 160), M.SmoothPlastic, C3(255, 128,  56), "ember")
pet("BrambleHedgehog",  C3(136, 102,  72), M.Fabric,        C3(202, 170, 126), "leaf")
pet("SandyCrablet",     C3(233, 116,  66), M.SmoothPlastic, C3(255, 200, 152), "sand")
pet("DuneGecko",        C3(198, 178, 112), M.Sand,          C3(142, 168,  88), "sand")
pet("TideMinnow",       C3(120, 188, 214), M.SmoothPlastic, C3(228, 246, 252), "bubble")
pet("PocketMole",       C3(126, 106, 114), M.Fabric,        C3(246, 180, 186), "dust")
pet("BuckleBeetle",     C3( 62, 104,  72), M.Metal,         C3(154, 222, 152), "pollen")
pet("FuzzChick",        C3(255, 222, 110), M.Fabric,        C3(250, 160,  60), "fluff")
pet("CobbleToad",       C3(112, 148,  86), M.Grass,         C3(192, 216, 122), "droplet")
pet("NibbleMouse",      C3(180, 168, 190), M.Fabric,        C3(248, 182, 192), "fluff")

-- UNCOMMON  --  same world, better dye. Colours get one notch of saturation
-- and effects lift off the ground.
pet("TidalTerrapin",    C3( 72, 142, 120), M.Slate,         C3(182, 234, 208), "bubble")
pet("LongearLop",       C3(200, 180, 208), M.Fabric,        C3(252, 238, 246), "pollen")
pet("BoulderArmadillo", C3(150, 138, 120), M.Slate,         C3(198, 184, 164), "dust")
pet("CoilSnail",        C3(114, 188, 180), M.SmoothPlastic, C3(228, 170,  82), "droplet")
pet("FanfinBetta",      C3(216,  62, 122), M.SmoothPlastic, C3( 92, 142, 234), "bubble")
pet("TusklingBoar",     C3(128,  98,  76), M.Fabric,        C3(240, 232, 214), "dust")
pet("AntlerFawn",       C3(198, 144,  90), M.Fabric,        C3(253, 245, 231), "leaf")
pet("BanditRaccoon",    C3(128, 132, 142), M.Fabric,        C3( 46,  46,  54), "fluff")
pet("PufferNimbus",     C3(176, 216, 240), M.SmoothPlastic, C3(255, 255, 255), "cloud")
pet("WaddlePenguin",    C3( 60,  68,  86), M.SmoothPlastic, C3(250, 172,  52), "snow")
pet("PerchOwlet",       C3(160, 120,  82), M.Fabric,        C3(246, 228, 192), "feather")
pet("SnorkelOtter",     C3(150, 106,  72), M.Fabric,        C3(182, 230, 242), "bubble")
pet("SprigSloth",       C3(152, 154, 126), M.Grass,         C3(128, 180,  98), "leaf")

-- RARE  --  the elemental step. Every one of these glows: this is the tier
-- where a PointLight switches on and the pet starts lighting the sand it
-- walks over.
pet("LunarKit",         C3(180, 198, 232), M.SmoothPlastic, C3(152, 224, 255), "moonlight")
pet("EmberwispFennec",  C3(240, 184, 104), M.Fabric,        C3(255, 134,  50), "ember")
pet("GlimmerMoth",      C3(178, 152, 206), M.Fabric,        C3(255, 234, 152), "glimmer")
pet("RuneGolemite",     C3( 94,  98, 106), M.Slate,         C3( 82, 234, 222), "rune")
pet("FrostCubling",     C3(202, 232, 248), M.Ice,           C3(122, 202, 242), "snow")
pet("ThornwoodSprout",  C3(142, 112,  78), M.Wood,          C3(126, 210,  92), "bloom")
pet("MistailSerpent",   C3( 60, 122, 126), M.SmoothPlastic, C3(198, 238, 238), "mist")
pet("PrismJelly",       C3(206, 206, 255), M.Glass,         C3(255, 190, 240), "prism", { transparency = 0.42 })
pet("StarfleckDeer",    C3( 60,  66, 112), M.SmoothPlastic, C3(255, 242, 182), "starlight")
pet("CinderImp",        C3( 74,  56,  56), M.Slate,         C3(255, 122,  42), "ember")
pet("AuroraAxolotl",    C3(250, 170, 210), M.SmoothPlastic, C3(122, 255, 216), "aurora")
pet("GrimoireBat",      C3( 80,  58, 112), M.Fabric,        C3(234, 216, 170), "rune")
pet("SandwhisperDjinn", C3(226, 188, 122), M.Sand,          C3(122, 202, 255), "sandstorm")

-- EPIC  --  machines and weather. Hard materials, a rarity ring on the
-- ground, and effects loud enough to read from across a beach.
pet("Rustclaw",         C3(152,  86,  50), M.CorrodedMetal, C3(230, 126,  54), "rust")
pet("MagmaColossus",    C3( 58,  44,  44), M.Basalt,        C3(255,  98,  22), "magma")
pet("VoltaicWolf",      C3( 54,  68,  98), M.Metal,         C3( 92, 232, 255), "lightning")
pet("Gearhawk",         C3(192, 148,  74), M.Foil,          C3(255, 208, 112), "gear")
pet("TidebreakerKraken",C3( 30,  94, 112), M.SmoothPlastic, C3( 98, 234, 216), "abyss")
pet("CryoRhino",        C3(178, 216, 240), M.Ice,           C3( 72, 152, 216), "blizzard")
pet("ScrapheapSentinel",C3(106, 106, 112), M.DiamondPlate,  C3(242, 198,  42), "spark")
pet("EmberforgeSalamander", C3(170, 54, 40), M.Basalt,      C3(255, 170,  52), "magma")
pet("TempestRay",       C3( 66,  74, 126), M.SmoothPlastic, C3(182, 202, 255), "storm")
pet("ChronoBeetle",     C3( 74, 142, 126), M.Metal,         C3(255, 216, 112), "chrono")

-- LEGENDARY  --  seven, and they are meant to stop a conversation. Ring,
-- halo, aura shell, trail and the brightest lights in the file.
pet("Trihedron",        C3( 42,  40,  54), M.Marble,        C3(255, 208,  94), "sacred")
pet("AegisWarden",      C3(228, 230, 238), M.Marble,        C3(255, 216, 122), "holy")
pet("VoidSerpentEmperor", C3(32, 26,  46), M.SmoothPlastic, C3(188,  98, 255), "void")
pet("SolarisPhoenix",   C3(255, 168,  52), M.SmoothPlastic, C3(255, 196,  86), "solar")
pet("TitanCorebreaker", C3( 98,  96, 106), M.Metal,         C3(255,  86,  50), "core")
pet("CelestialKirin",   C3(148, 228, 198), M.SmoothPlastic, C3(255, 246, 192), "celestial")
pet("AbyssalLeviathan", C3( 24,  46,  76), M.SmoothPlastic, C3( 72, 246, 234), "abyss")

-- Penguin Island's three Mythics (2026-09-11). Textured meshes ignore the body
-- colour; the accent is what drives their light, trail, ring, halo and shell.
pet("FrostfangWolf",    C3(236, 242, 248), M.SmoothPlastic, C3(120, 210, 255), "blizzard")
pet("AuroraPhoenix",    C3(214, 236, 255), M.SmoothPlastic, C3(140, 255, 220), "celestial")
pet("BorealisWyrm",     C3( 60,  92, 150), M.SmoothPlastic, C3( 90, 200, 255), "storm")

PetVisuals.Palette = PALETTE
--------------------------------------------------------------------------
-- WHAT A TIER IS WORTH, VISUALLY
--------------------------------------------------------------------------
--[[
	The ladder has to be readable at a glance and from behind, because that is
	the angle you spend the whole game looking at your own pets from. So each
	rung adds a WHOLE NEW KIND of thing rather than just more of the last one:

		Common      colour, a small effect
		Uncommon    + a denser aura
		Rare        + it lights the ground, + a motion trail
		Epic        + a rarity ring at its feet
		Legendary   + a halo, + an aura shell around the whole silhouette

	Rates are per-second and get multiplied by the pet's own effect rate, so a
	Legendary is roughly six times the particle budget of a Common -- which is
	the right way round, since you will own dozens of Commons and one of these.
]]
--[==[
	`auraGlow` is LightEmission, and it is on the ladder for a reason that is
	not obvious: a particle at LightEmission 1 is drawn ADDITIVELY, and adding
	a pale colour to a bright noon sky produces almost exactly the bright noon
	sky. The Common aura is a near-white grey, so at 1 it was invisible in the
	one place the game is actually played. Turning it DOWN makes it show up --
	the particle goes back to being a solid object with a colour instead of a
	contribution of light -- and turning it up on the Legendaries, whose
	colours are saturated gold and violet, is what makes those read as light
	rather than as confetti.
]==]
local TIER = {
	Common    = { auraRate = 6,  auraSize = 0.115, fxScale = 0.95, auraGlow = 0.35 },
	Uncommon  = { auraRate = 8,  auraSize = 0.130, fxScale = 1.05, auraGlow = 0.50 },
	Rare      = { auraRate = 10, auraSize = 0.140, fxScale = 1.10, auraGlow = 0.80, light = 1.3, trail = true },
	Epic      = { auraRate = 13, auraSize = 0.155, fxScale = 1.20, auraGlow = 0.95, light = 2.0, trail = true, ring = true },
	Legendary = { auraRate = 18, auraSize = 0.175, fxScale = 1.35, auraGlow = 1.00, light = 2.8, trail = true, ring = true, halo = true, shell = true },
	-- MISSING UNTIL 2026-09-11, and it mattered the day an egg shipped whose
	-- whole product is Mythics: the lookup below falls back to Common, so the
	-- Jade Wish Dragon had been wearing a Common's aura since it was hatched.
	-- One step past Legendary on every dial, and VIP the same (the Gilded
	-- Unicorn is a Mythic with a pass attached).
	Mythic    = { auraRate = 22, auraSize = 0.190, fxScale = 1.50, auraGlow = 1.00, light = 3.4, trail = true, ring = true, halo = true, shell = true },
	VIP       = { auraRate = 22, auraSize = 0.190, fxScale = 1.50, auraGlow = 1.00, light = 3.4, trail = true, ring = true, halo = true, shell = true },
}

-- The rarity aura every pet wears, in ITS TIER'S colour -- the same colours
-- ItemConfig and the reveal card use, so "the blue one" means one thing
-- across the whole game.
local AURA = {
	tex = "spark", place = "core", size = 0.12,
	life = {0.7, 1.3}, speed = {0.10, 0.40}, spread = 180, accel = 0.15,
	colors = {"tier", "tierglow"}, t = 0, glow = 1, spin = {-90, 90},
	shape = "Sphere", style = "Surface", inout = "Outward",
}

--------------------------------------------------------------------------
-- BUILDERS
--------------------------------------------------------------------------
local function pick(entry, ctx)
	if typeof(entry) == "Color3" then return entry end
	if entry == "body" then return ctx.body end
	if entry == "tier" then return ctx.tier.color end
	if entry == "tierglow" then return ctx.tier.glow end
	return ctx.accent
end

local function colorSeq(list, ctx)
	if not list or #list == 0 then
		return ColorSequence.new(ctx.accent)
	end
	if #list == 1 then
		return ColorSequence.new(pick(list[1], ctx))
	end
	local kp = {}
	for i, entry in list do
		table.insert(kp, ColorSequenceKeypoint.new((i - 1) / (#list - 1), pick(entry, ctx)))
	end
	return ColorSequence.new(kp)
end

-- Fade in fast, hold, fade out. A particle that pops in at full opacity reads
-- as a glitch; one that never reaches full opacity reads as nothing at all.
local function transSeq(t)
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.16, t),
		NumberSequenceKeypoint.new(0.70, t),
		NumberSequenceKeypoint.new(1, 1),
	})
end

local function sizeSeq(peak, grow)
	if grow then
		-- smoke: born small, swells as it dissipates
		return NumberSequence.new({
			NumberSequenceKeypoint.new(0, peak * 0.35),
			NumberSequenceKeypoint.new(1, peak * 1.35),
		})
	end
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.28, peak),
		NumberSequenceKeypoint.new(1, 0),
	})
end

--[==[
	THE TWO GAINS, AND WHY THE TABLE ABOVE LIES ON PURPOSE.

	The fractions in FX are written the way you would describe an effect out
	loud -- "a tenth of the animal", "drifting slowly" -- and taken literally
	both of them come out wrong on a 2.6-stud follow pet.

	SIZE. `half` is 1.3 studs there, so a "0.1 of half" spark is a 0.13-stud
	quad. Worse, most of that quad is empty: the sparkles sheet is a six-point
	star whose bright pip is about a quarter of its own image, while smoke and
	the round bead fill nearly all of theirs. That ratio is TEX_FILL -- it is
	not an artistic choice, it is how much ink each of the five built-in
	sheets actually has, and without it a spark and a puff written at the same
	number come out four times apart on screen.

	SPEED. The authored speeds move a particle less than a stud over its whole
	life, which sounds like the gentle drift that was wanted and is in fact
	entirely INSIDE the animal, with an opaque mesh in front of every one of
	them. An effect has to clear the silhouette to exist at all.

	Both corrections are one number each and they live here rather than in the
	rows, so the whole file re-tunes from two lines instead of from thirty-five
	with two of them missed.
]==]
local PARTICLE_GAIN = 2.6
local SPEED_GAIN = 2.5
local TEX_FILL = { spark = 2.4, fire = 1.4, smoke = 1.0, blob = 1.2, wisp = 1.3 }

local function makeEmitter(spec, ctx)
	local half = ctx.half
	local at = Instance.new("Attachment")
	at.Name = "PetFxOrigin"
	at.Position = (PLACE[spec.place or "core"] or PLACE.core)(ctx.size)
	at.Parent = ctx.root

	local e = Instance.new("ParticleEmitter")
	e.Name = "PetFx"
	e.Texture = TEX[spec.tex] or TEX.spark
	e.Color = colorSeq(spec.colors, ctx)
	e.Size = sizeSeq((spec.size or 0.12) * PARTICLE_GAIN * (TEX_FILL[spec.tex] or 1) * half, spec.grow)
	e.Transparency = transSeq(spec.t or 0.1)
	e.LightEmission = spec.glow or 0.5
	e.LightInfluence = 0

	local life = spec.life or {0.6, 1.1}
	e.Lifetime = NumberRange.new(life[1], life[2])
	e.Rate = math.max(1, math.round((spec.rate or 6)))

	-- Speed and acceleration are fractions of `half`, so a big pet throws its
	-- sparks proportionally further and the effect keeps the same shape.
	local sp = spec.speed or {0.2, 0.5}
	e.Speed = NumberRange.new(sp[1] * SPEED_GAIN * half, sp[2] * SPEED_GAIN * half)
	e.Acceleration = Vector3.new(0, (spec.accel or 0) * half, 0)
	e.Drag = spec.drag or 0

	e.SpreadAngle = Vector2.new(spec.spread or 30, spec.spread or 30)
	e.EmissionDirection = Enum.NormalId[spec.dir or "Top"]
	e.LockedToPart = spec.lock == true
	e.ZOffset = spec.zoff or 0

	if spec.spin then
		e.Rotation = NumberRange.new(0, 360)
		e.RotSpeed = NumberRange.new(spec.spin[1], spec.spin[2])
	end
	if spec.squash then
		e.Squash = NumberSequence.new(spec.squash)
	end
	if spec.orient then
		e.Orientation = Enum.ParticleOrientation[spec.orient]
	end
	if spec.shape then
		e.Shape = Enum.ParticleEmitterShape[spec.shape]
	end
	if spec.style then
		e.ShapeStyle = Enum.ParticleEmitterShapeStyle[spec.style]
	end
	if spec.inout then
		e.ShapeInOut = Enum.ParticleEmitterShapeInOut[spec.inout]
	end
	e.Parent = at
	return e
end

--[[
	A RING OUT OF TWO BEAMS.

	A Beam is a cubic Bezier: it leaves Attachment0 along that attachment's
	own +X and arrives at Attachment1 along its -X, with CurveSize0/1 setting
	how far the two handles reach. Put two attachments a diameter apart, aim
	both their +X the same way round the circle, and hand them handles of
	4/3 r with OPPOSITE SIGNS and you get a clean semicircle. Two of those,
	mirrored, close the loop.

	The sign pair is the whole trick and it is not obvious: (+K, +K) draws a
	figure eight, which is what this looked like for its first three attempts.

	Six instances for a ring that follows the pet exactly. The dozen little
	Neon parts it replaces looked the same and cost twice as much on a screen
	with sixty pets on it.
]]
local function makeRing(ctx, y, radius, color, width, transparency)
	local K = radius * (4 / 3)
	local function att(x, forward)
		local a = Instance.new("Attachment")
		a.Name = "PetRingNode"
		a.CFrame = CFrame.fromMatrix(Vector3.new(x, y, 0), forward, Vector3.new(0, 1, 0))
		a.Parent = ctx.root
		return a
	end
	local function arc(forward)
		local b = Instance.new("Beam")
		b.Name = "PetRing"
		b.Attachment0 = att(radius, forward)
		b.Attachment1 = att(-radius, forward)
		b.CurveSize0, b.CurveSize1 = K, -K
		b.Width0, b.Width1 = width, width
		b.Color = ColorSequence.new(color)
		b.LightEmission = 1
		b.LightInfluence = 0
		b.Transparency = NumberSequence.new(transparency)
		b.FaceCamera = true
		b.Segments = 26
		b.Parent = ctx.root
	end
	arc(Vector3.new(0, 0, 1))
	arc(Vector3.new(0, 0, -1))
end

local function makeLight(ctx, color, brightness)
	local a = Instance.new("Attachment")
	a.Name = "PetGlowOrigin"
	a.Parent = ctx.root
	local l = Instance.new("PointLight")
	l.Name = "PetGlow"
	l.Color = color
	l.Brightness = brightness
	-- Clamped rather than purely proportional: the reveal pet is 60% bigger
	-- than the follow pet and should not be 60% more of a floodlight.
	l.Range = math.clamp(ctx.half * 4.5, 4, 15)
	l.Shadows = false          -- sixty shadow-casting pets is a slideshow
	l.Parent = a
	return l
end

local function makeTrail(ctx, color)
	local S = ctx.size
	local function node(name, y)
		local a = Instance.new("Attachment")
		a.Name = name
		a.Position = Vector3.new(0, y, S.Z * 0.40)
		a.Parent = ctx.root
		return a
	end
	local t = Instance.new("Trail")
	t.Name = "PetTrail"
	t.Attachment0 = node("PetTrailTop", S.Y * 0.30)
	t.Attachment1 = node("PetTrailBottom", -S.Y * 0.28)
	t.Color = ColorSequence.new(color)
	t.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	t.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0.15),
	})
	-- 0.24s, not 0.30. A pet lags into corners and briefly outruns the player
	-- catching up, and at walking speed every extra tenth of a second is
	-- another stud and a half of ribbon behind an animal that is only two and
	-- a half studs long. Three of them at 0.30 is a lot of screen.
	t.Lifetime = 0.24
	t.LightEmission = 0.9
	t.LightInfluence = 0
	-- Without a MinLength the trail draws a smear while the pet only bobs on
	-- the spot, which is most of the time.
	t.MinLength = 0.2
	t.FaceCamera = true
	t.Parent = ctx.root
	return t
end

-- The Legendary shell: the pet's own mesh again, one notch bigger, Neon, and
-- nearly transparent. At 0.93 it is a rim of colour that hugs the silhouette;
-- anything below about 0.88 stops being an aura and starts being a repaint,
-- which flattens away all the facet shading the meshes are made of.
local function makeShell(ctx, color)
	if not ctx.clean then
		return nil
	end
	local sh = ctx.clean:Clone()
	sh.Name = "PetAuraShell"
	sh.Size = ctx.size * 1.10
	sh.CFrame = ctx.root.CFrame
	sh.Material = Enum.Material.Neon
	sh.Color = color
	sh.Transparency = 0.93
	sh.Reflectance = 0
	sh.CastShadow = false
	sh.CanCollide = false
	sh.CanQuery = false
	sh.CanTouch = false
	sh.Massless = true
	sh.Anchored = ctx.anchored
	sh.Parent = ctx.root
	if not ctx.anchored then
		local w = Instance.new("WeldConstraint")
		w.Part0 = ctx.root
		w.Part1 = sh
		w.Parent = sh
	end
	return sh
end
--------------------------------------------------------------------------
-- PUBLIC
--------------------------------------------------------------------------

-- Colour and material only. Safe on a library copy, safe to run twice, and
-- deliberately cheap: this is what a ViewportFrame or an icon wants, with
-- none of the emitters that would cost it something.
function PetVisuals.paint(inst: Instance, petId: string)
	local row = PALETTE[petId]
	local def = PetConfig.get(petId)
	local body = row and row.body or (def and PetConfig.tierColor(def.Tier))
	if not body then
		return
	end

	local function apply(p: BasePart)
		-- The shell is the one part that is meant to stay the accent colour.
		if p.Name == "PetAuraShell" then
			return
		end
		--[==[
			A pet that came out of the exporter CARRYING ITS OWN COLOURS is
			already right, and tinting it makes it worse, not grey-proof.

			The Blender pack bakes every material's base colour into a 512x512
			atlas and points each face's UVs at its own swatch, so one MeshPart
			holds six colours. BasePart.Color MULTIPLIES the texture, so writing
			the tier colour here would push all six swatches toward one hue --
			exactly the flat single-colour look this file was written to fix.

			So: textured pets are left at white and render as authored. A pet
			that still arrives bare (no texture) falls through and gets the old
			tier-colour treatment, unchanged.
		]==]
		if p:IsA("MeshPart") and p.TextureID ~= "" then
			return
		end
		p.Color = body
		if row then
			if row.mat then
				p.Material = row.mat
			end
			if row.transparency then
				p.Transparency = row.transparency
			end
		end
	end

	if inst:IsA("BasePart") then
		apply(inst)
	end
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			apply(d)
		end
	end
end

--[[
	Paint the sixty stored models in place, once.

	Called by PetServer on boot rather than left as a command-bar chore, so a
	place that has just had the pack re-imported comes up coloured instead of
	coming up grey and waiting for somebody to remember. It only ever writes
	Color/Material/Transparency, so re-running it costs nothing and cannot
	break a model.
]]
function PetVisuals.paintLibrary(petsFolder: Instance?): number
	local root = petsFolder or game:GetService("ReplicatedStorage"):FindFirstChild("Pets")
	if not root then
		return 0
	end
	local painted = 0
	for _, petId in PetConfig.Order do
		local def = PetConfig.get(petId)
		local folder = root:FindFirstChild(def.Tier)
		if folder then
			local art = folder:FindFirstChild(def.ModelName) or folder:FindFirstChild(petId)
			if not art then
				-- Same suffix rule PetServer and EggClient use, so a
				-- hand-renamed model is painted too.
				for _, child in folder:GetChildren() do
					if child.Name:sub(-#petId) == petId then
						art = child
						break
					end
				end
			end
			if art then
				PetVisuals.paint(art, petId)
				painted += 1
			end
		end
	end
	return painted
end

--[[
	Dress a spawned pet.

	CALL THIS AFTER THE MODEL HAS BEEN SCALED. Everything is measured off the
	root part's size at the moment of the call, which is what lets the 2.6-stud
	follow pet and the 4.2-stud reveal pet share one palette row. Calling it
	before a ScaleTo would size the effects to the raw export, which is
	anywhere from 4 to 26 studs.

	opts.showcase   the hatch reveal: about half again as much of everything,
	                because it is on screen alone, for two seconds, and that is
	                the moment the pet has to look worth the coins.
	opts.paint      false to leave the colours alone and add only the effects.
	                PetServer passes this for the missing-art placeholder,
	                which is already two-tone in its tier's colours -- painting
	                it would flatten a body and a head into one flat lozenge.

	Anchored-ness is read off the part rather than passed in: an anchored pet
	is a showcase pet standing still and its extra parts are anchored too; an
	unanchored one is riding the follow rig and its extras are welded to it.
	Passing that in as a flag is one more thing that can disagree with reality.
]]
function PetVisuals.decorate(model: Instance, petId: string, opts): BasePart?
	opts = opts or {}
	local root: BasePart? = nil
	if model:IsA("BasePart") then
		root = model
	elseif model:IsA("Model") then
		root = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	end
	if not root then
		return nil
	end
	-- Idempotent. rebuildBodies can run twice in a frame on a fast respawn and
	-- a pet wearing two auras is a pet at double the particle budget.
	if root:GetAttribute("PetDressed") then
		return root
	end
	root:SetAttribute("PetDressed", true)

	local def = PetConfig.get(petId)
	local tierKey = def and def.Tier or "Common"
	local tierInfo = PetConfig.tierInfo(tierKey)
	local row = PALETTE[petId] or {}
	local dress = TIER[tierKey] or TIER.Common

	-- Taken BEFORE anything is attached, so the shell is a bare copy of the
	-- mesh and not a copy carrying a second set of emitters and lights.
	local clean = nil
	if root:IsA("MeshPart") then
		clean = root:Clone()
		for _, c in clean:GetChildren() do
			c:Destroy()
		end
	end

	if opts.paint ~= false then
		PetVisuals.paint(root, petId)
	end

	local S = root.Size
	local ctx = {
		root = root,
		size = S,
		half = math.max(S.X, S.Y, S.Z) * 0.5,
		body = row.body or tierInfo.color,
		accent = row.accent or tierInfo.glow,
		tier = tierInfo,
		anchored = root.Anchored,
		clean = clean,
	}

	local boost = opts.showcase and 1.5 or 1

	-- 1. the rarity aura, in the tier's colour
	makeEmitter(derive(AURA, {
		rate = dress.auraRate * boost,
		size = dress.auraSize * (opts.showcase and 1.15 or 1),
		glow = dress.auraGlow or 1,
	}), ctx)

	-- 2. the pet's own effect, in the pet's own colours
	local sig = FX[row.fx or ""]
	if sig then
		makeEmitter(derive(sig, {
			rate = (sig.rate or 6) * (dress.fxScale or 1) * boost,
			size = (sig.size or 0.12) * (opts.showcase and 1.15 or 1),
		}), ctx)
	end

	-- 3. from Rare up it lights what it walks over
	if dress.light then
		makeLight(ctx, row.light or ctx.accent, dress.light * boost)
	end
	if dress.trail then
		makeTrail(ctx, row.trail or ctx.accent)
	end

	-- 4. Epic and Legendary stand inside a ring
	if dress.ring then
		makeRing(ctx,
			-S.Y * 0.5 - ctx.half * 0.05,
			ctx.half * 0.95,
			row.ring or ctx.accent,
			math.max(0.035, ctx.half * 0.05),
			0.15)
	end
	-- 5. and a Legendary wears a halo and a shell
	if dress.halo then
		makeRing(ctx,
			S.Y * 0.5 + ctx.half * 0.26,
			ctx.half * 0.42,
			row.halo or tierInfo.glow,
			math.max(0.025, ctx.half * 0.032),
			0.22)
	end
	if dress.shell then
		makeShell(ctx, row.shell or ctx.accent)
	end

	return root
end

PetVisuals.Fx = FX
PetVisuals.TierDressing = TIER
PetVisuals.Places = PLACE

return PetVisuals
