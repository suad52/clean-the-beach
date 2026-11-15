--[[
	ShrineBuilder  --  ServerScriptService.ShrineBuilder  (ModuleScript)

	THE INNER SHRINE. What is behind the cove's shrine door: a sealed timber hall
	with a floor buried in the leavings of a festival, which the player sweeps
	clean with the same sifter they use on the beaches.

	It is Config.ISLANDS[6] -- a sixth rakeable field, not a special case. The
	server grid, the per-player progress, the finds, the sell pad and the clear
	bonus are all the machinery the beaches already use; the only things unique
	to it are the hall built around the field and the litter set it draws from
	(ReplicatedStorage.CTB.Shrine, built below, instead of washed-up cans).

	MODELLED ON THE TOMB, deliberately and almost line for line. VaultBuilder +
	Island2Builder's pyramid door are the pattern this copies: a clickable door
	on the island, a cinematic fade, a sealed room a long way away, a prompt to
	leave. Anything that reads oddly here is worth checking against the tomb
	first -- it is probably the same decision, already argued out over there.

	ONE FILE, BOTH SIDES, and that IS a departure from the tomb.

	Over in the desert the door lives in Island2Builder and the room in
	VaultBuilder, and CTB_Server joins them at boot because neither may load
	first. That split exists because the pyramid was already Island2Builder's.
	Here there is no such history and one reason not to repeat it: the cove is
	ADOPTED. Island3Builder hands back whatever is saved in the place file
	("[Cove] adopted the hand-built cove saved in the place file") and never
	reaches its own scatter code, so geometry added to that module would never
	appear. The porch is therefore its own root model with its own adoption
	check, exactly like the AFK shelter, and both ends of the door are here.

	WHERE THE ROOM IS. At (3000, 1500) on the same y = 3 plane as every other
	field, because Config.Y_MIN/Y_MAX and occupancyFor are shared and all six
	fields have to sit in the same voxel band. It is nowhere near the cove it is
	supposedly inside -- but it is sealed on all six sides and the only way in is
	the cinematic, so that never shows. Verified empty before it was claimed: no
	parts within 400 studs and no terrain.
]]

local Shrine = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local CTB = ReplicatedStorage:WaitForChild("CTB")
local Config = require(CTB:WaitForChild("Config"))
local Net = CTB:WaitForChild("Net")

local Terrain = workspace.Terrain

----------------------------------------------------------------
-- Dimensions
----------------------------------------------------------------
local ISL = Config.island(6)
local CX, CZ = ISL.cx, ISL.cz
local GROUND = ISL.cleanY

-- Interior. The rakeable field is CX/CZ +- 64, so this leaves 32 studs of clear
-- board each side for the colonnade to stand on and 56 at each end for the
-- altar and the way out -- none of it inside floor the player has to sweep.
local X0, X1 = CX - 96, CX + 96
local Z0, Z1 = CZ - 120, CZ + 120
local CEIL = GROUND + 36
local WALL = 6

-- The altar end lifts, the same trick and for the same reason the tomb's alcove
-- exists: the thing the hall points at has to be bigger than the things lining
-- it, and a hall sized for the statues is not tall enough for the statue.
local ALTAR_Z = CZ + 76
local ALTAR_CEIL = CEIL + 16

-- Where the cinematic puts you down: just inside the south end, looking up the
-- length of the hall at the altar.
local ENTRY = CFrame.lookAt(
	Vector3.new(CX, GROUND + 3.5, Z0 + 16),
	Vector3.new(CX, GROUND + 3.5, Z0 + 44))

-- Where leaving puts you. Set below by Shrine.buildEntrance once the porch
-- exists, so the two ends cannot disagree about where the door is.
--
-- The fallback is applied at CALL time rather than assigned here as a default,
-- so a load-order accident can never overwrite the real porch with it. Nobody
-- may be sealed in a room with no way out, so leave() always has an answer.
local FALLBACK_RETURN = CFrame.new(0, 8, 1660)

--[[
	How many rebirths the shrine asks for, and it is deliberately the cove's own
	number rather than a new bar to clear.

	FerryConfig.Ports gates Sakura Cove itself at three (the tomb's note records
	the ladder: cove three, tomb five, Ashfall ten). Anybody standing on the sand
	outside this door has already paid three, so at three the door is open to
	everyone who can reach it -- which is the intent. The shrine is an extra room
	on an island you have earned, not a second endgame competing with the tomb.

	IT IS STILL A REAL GATE, wired exactly like the tomb's: checked on the server
	inside the click handler, refused with the same strain-and-settle animation
	and the same "DoorLocked" message the client already knows how to draw. Raise
	this one number and the door locks properly, with no other line to move.
]]
Shrine.REBIRTHS = 3

-- Cinematic timings live in Config so the client fades on exactly the numbers
-- the server teleports on. Shared constants, NOT a handshake -- see the note in
-- Config.CINEMA for why a dropped packet must not be able to strand anyone
-- behind a black screen.
Shrine.BEAT = Config.CINEMA.beat
Shrine.FADE = Config.CINEMA.fade
Shrine.HOLD = Config.CINEMA.hold

----------------------------------------------------------------
-- Palette
--
-- A shrine, not a temple: vermilion and white with dark timber, which is the
-- Inari palette every player will recognise, against the cove's own pink.
-- Gold is used only where a real shrine gilds -- fittings, the mirror, the
-- ridge billets -- because gold everywhere is the tomb's look and these two
-- rooms must not be the same room in different colours.
----------------------------------------------------------------
local VERMILION = Color3.fromRGB(198, 66, 48)
local VERMILION_DEEP = Color3.fromRGB(150, 44, 34)
local VERMILION_LIGHT = Color3.fromRGB(226, 104, 82)
local TIMBER = Color3.fromRGB(96, 64, 44)
local TIMBER_DARK = Color3.fromRGB(62, 42, 30)
local TIMBER_LIGHT = Color3.fromRGB(158, 116, 78)
local PLASTER = Color3.fromRGB(236, 228, 212)
local PAPER = Color3.fromRGB(248, 242, 224)
local GOLD = Color3.fromRGB(226, 182, 92)
local GOLD_DEEP = Color3.fromRGB(178, 136, 54)
local ROOF_TILE = Color3.fromRGB(66, 72, 82)
local ROOF_TILE_DEEP = Color3.fromRGB(46, 52, 62)
local JADE = Color3.fromRGB(88, 134, 100)
local PETAL = Color3.fromRGB(255, 196, 212)
local INK = Color3.fromRGB(38, 34, 34)
local STONE = Color3.fromRGB(168, 164, 156)
local STONE_DARK = Color3.fromRGB(124, 120, 114)

-- Both verified to load; the same two the tomb uses, because they are the two
-- this place is known to have.
local SND_AMBIENCE = "rbxassetid://9125602882"
local SND_WHOOSH = "rbxassetid://9125742262"

----------------------------------------------------------------
-- Builders
----------------------------------------------------------------
local function P(parent, name, size, cf, colour, material, extra)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = colour or TIMBER
	p.Material = material or Enum.Material.Wood
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

local function box(parent, name, x0, x1, y0, y1, z0, z1, colour, material, extra)
	if x1 - x0 < 0.05 or y1 - y0 < 0.05 or z1 - z0 < 0.05 then
		return nil
	end
	return P(parent, name,
		Vector3.new(x1 - x0, y1 - y0, z1 - z0),
		CFrame.new((x0 + x1) * 0.5, (y0 + y1) * 0.5, (z0 + z1) * 0.5),
		colour, material, extra)
end

-- Local-space helper, so a lantern or a komainu can be placed and turned
-- without every number in it being rewritten.
local function lp(parent, name, base, size, offset, colour, material, extra)
	return P(parent, name, size, base * offset, colour, material, extra)
end

-- Decoration: out of every spatial query and never in the way. Anything the
-- player is not meant to stand on or shoot a ray at goes through here.
local function trim(parent, name, size, cf, colour, material, extra)
	extra = extra or {}
	extra.CanCollide = false
	extra.CanQuery = false
	return P(parent, name, size, cf, colour, material, extra)
end

--[[
	SHIDE -- the folded paper zigzags that hang off a shimenawa. Four little
	blocks stepping side to side, which is the whole shape at the size anybody
	sees it from, and the one detail that makes a rope read as a sacred rope
	rather than as a rope.
]]
local function shide(parent, at: CFrame)
	for i = 0, 3 do
		trim(parent, "Shide", Vector3.new(0.9, 0.75, 0.12),
			at * CFrame.new(((i % 2 == 0) and -0.32 or 0.32), -0.45 - i * 0.72, 0),
			PAPER, Enum.Material.SmoothPlastic)
	end
end

--[[
	SHIMENAWA -- the twisted rice-straw rope. Barrel-tapered: fat in the middle,
	bound at both ends, sagging a little. Built from segments rather than one
	part because the taper IS the object; a straight cylinder reads as a pipe.

	A cylinder's LENGTH runs along its LOCAL X, so each segment is turned a
	quarter turn about Y to lie along the run. Getting that backwards builds a
	stack of discs, which is what the first one was.
]]
local function shimenawa(parent, x0: number, x1: number, y: number, z: number, sag: number)
	local segs = 9
	local span = x1 - x0
	for i = 0, segs - 1 do
		local t = (i + 0.5) / segs
		local w = 1.5 + math.sin(t * math.pi) * 1.9
		local yy = y - math.sin(t * math.pi) * sag
		trim(parent, "Shimenawa", Vector3.new(span / segs + 0.4, w, w),
			CFrame.new(x0 + span * t, yy, z),
			Color3.fromRGB(214, 196, 148), Enum.Material.Fabric,
			{ Shape = Enum.PartType.Cylinder })
	end
	-- Bindings, and a shide every third segment.
	for i = 1, segs - 1, 3 do
		local t = i / segs
		local yy = y - math.sin(t * math.pi) * sag
		trim(parent, "ShimeBind", Vector3.new(0.5, 3.3, 3.3),
			CFrame.new(x0 + span * t, yy, z), Color3.fromRGB(238, 232, 210),
			Enum.Material.Fabric, { Shape = Enum.PartType.Cylinder })
		shide(parent, CFrame.new(x0 + span * t, yy - 1.6, z))
	end
end

--[[
	A HANGING PAPER LANTERN (chochin). Five stacked discs give the barrel its
	bulge, which two never do -- and the bulge is the only thing separating a
	chochin from a bucket. Warm and lit: these are the hall's light source.

	NOT NEON. See the note on the field's tints: this place runs Brightness 3.1
	with a bloom threshold of 0.8, and a neon lantern at that exposure is a white
	pill with no paper left in it. A pale warm SmoothPlastic plus a PointLight
	inside reads lit and keeps the ribs.
]]
local function lantern(parent, at: CFrame, tint: Color3?, lightRange: number?)
	local m = Instance.new("Model")
	m.Name = "Chochin"
	m.Parent = parent
	local body = tint or Color3.fromRGB(248, 226, 176)
	trim(m, "Cord", Vector3.new(0.16, 2.4, 0.16), at * CFrame.new(0, 1.2, 0),
		TIMBER_DARK, Enum.Material.SmoothPlastic)
	trim(m, "CapTop", Vector3.new(0.35, 1.5, 1.5), at * CFrame.new(0, 0.1, 0),
		TIMBER_DARK, Enum.Material.Wood, { Shape = Enum.PartType.Cylinder })
	local prof = { 2.1, 2.7, 2.9, 2.7, 2.1 }
	for i, d in ipairs(prof) do
		trim(m, "Paper", Vector3.new(0.62, d, d), at * CFrame.new(0, -0.45 - (i - 1) * 0.6, 0),
			body, Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Cylinder })
	end
	trim(m, "CapBase", Vector3.new(0.3, 1.3, 1.3), at * CFrame.new(0, -3.6, 0),
		TIMBER_DARK, Enum.Material.Wood, { Shape = Enum.PartType.Cylinder })
	-- A red band round the middle, which is what stops a row of these reading as
	-- a row of eggs.
	trim(m, "Band", Vector3.new(0.66, 3.0, 3.0), at * CFrame.new(0, -1.65, 0),
		VERMILION, Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Cylinder })

	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 208, 148)
	glow.Brightness = 1.5
	glow.Range = lightRange or 26
	-- Shadows off on every one of these. There are two dozen in the hall and a
	-- shadow-casting light each is not worth what it costs on a phone.
	glow.Shadows = false
	glow.Parent = m:FindFirstChild("Paper")
	return m
end

--[[
	A STONE LANTERN (toro). Six stacked pieces, the fire box glowing. Used along
	the approach outside and either side of the altar within.
]]
local function toro(parent, at: CFrame, scale: number)
	local s = scale or 1
	local m = Instance.new("Model")
	m.Name = "Toro"
	m.Parent = parent
	local function piece(name, sx, sy, sz, y, colour, mat, extra)
		return trim(m, name, Vector3.new(sx * s, sy * s, sz * s),
			at * CFrame.new(0, y * s, 0), colour or STONE, mat or Enum.Material.Slate, extra)
	end
	piece("Base", 3.4, 0.8, 3.4, 0.4)
	piece("Plinth", 2.2, 0.7, 2.2, 1.15)
	piece("Shaft", 1.2, 3.2, 1.2, 3.1)
	piece("Platform", 3.0, 0.6, 3.0, 5.0)
	local fire = piece("FireBox", 2.4, 2.2, 2.4, 6.4, Color3.fromRGB(188, 184, 176))
	piece("Window", 1.6, 1.4, 2.6, 6.4, Color3.fromRGB(255, 216, 156), Enum.Material.SmoothPlastic)
	piece("Roof", 4.2, 1.1, 4.2, 8.0, STONE_DARK)
	piece("Cap", 0.9, 1.1, 0.9, 9.0, STONE_DARK)
	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 202, 140)
	glow.Brightness = 1.2
	glow.Range = 22 * s
	glow.Shadows = false
	glow.Parent = fire
	return m
end

--[[
	KOMAINU -- the lion-dogs that guard a shrine, one mouth open and one shut.
	Boxes and balls only, and the read comes almost entirely from the silhouette:
	a heavy chest, a low head, a curled tail standing up behind. Anything more
	detailed than this is invisible at the distance anybody sees them from.
]]
local function komainu(parent, at: CFrame, openMouth: boolean, scale: number)
	local s = scale or 1
	local mm = Instance.new("Model")
	mm.Name = "Komainu"
	mm.Parent = parent
	local function part(name, sx, sy, sz, ox, oy, oz, colour, shape)
		return trim(mm, name, Vector3.new(sx * s, sy * s, sz * s),
			at * CFrame.new(ox * s, oy * s, oz * s), colour or STONE, Enum.Material.Slate,
			shape and { Shape = shape } or nil)
	end
	part("Plinth", 4.4, 1.6, 6.0, 0, 0.8, 0, STONE_DARK)
	part("Body", 2.9, 3.0, 5.0, 0, 3.1, 0)
	part("Chest", 3.2, 2.6, 2.2, 0, 3.3, -1.6)
	part("Head", 2.7, 2.5, 2.6, 0, 5.6, -2.0)
	part("Snout", 1.5, 1.2, 1.4, 0, 5.1, -3.4)
	if openMouth then
		part("Jaw", 1.2, 0.7, 1.1, 0, 4.5, -3.5, INK)
	end
	for _, sx2 in ipairs({ -1, 1 }) do
		part("Ear", 0.9, 1.0, 0.6, sx2 * 1.0, 6.7, -1.6)
		part("Eye", 0.5, 0.5, 0.5, sx2 * 0.8, 5.9, -3.1, INK, Enum.PartType.Ball)
		part("LegF", 1.0, 2.4, 1.0, sx2 * 1.0, 2.4, -2.0)
		part("LegB", 1.1, 2.2, 1.1, sx2 * 1.0, 2.3, 1.8)
	end
	-- The tail: three balls climbing, which is the curl. One part reads as a stump.
	for i = 0, 2 do
		part("Tail", 1.7 - i * 0.3, 1.7 - i * 0.3, 1.7 - i * 0.3,
			0, 4.6 + i * 1.1, 2.4 + i * 0.35, STONE, Enum.PartType.Ball)
	end
	-- A mane of four balls round the neck, the one flourish worth the parts.
	for i = 0, 3 do
		local a = math.rad(-60 + i * 40)
		part("Mane", 1.3, 1.3, 1.3, math.sin(a) * 1.5, 5.5 + math.cos(a) * 0.6, -1.0,
			STONE_DARK, Enum.PartType.Ball)
	end
	return mm
end

--[[
	A JAPANESE ROOF, which is the single most recognisable thing in this build
	and the one worth spending parts on.

	FOUR THINGS MAKE IT READ, and it took all four:
	  * it OVERHANGS a long way -- an eave flush with the wall is a shed;
	  * it is built from stepped courses, each one wider and lower than the last,
	    so the pitch CONCAVES instead of running straight to the ridge;
	  * the ridge is a fat capped beam, not a line where two slopes meet;
	  * katsuogi (the short billets lying across the ridge) and chigi (the forked
	    finials at each end) sit on top of it.

	Built along Z: `depth` runs front-to-back, `width` across. Courses are laid
	from the eave inward.
]]
--[[
	A JAPANESE ROOF, which is the single most recognisable thing in this build
	and the one worth spending parts on.

	IT IS TWO PITCHED PLANES, NOT A STACK OF SLABS. The first version laid
	horizontal courses, each one narrower and higher than the last -- and from
	the ground that is a ziggurat. A wedding cake, in the shot it was caught in.
	Stepping only reads as a slope when the steps are far smaller than the
	distance you view them from, and nobody views a shrine roof from far away.

	So each side is a set of segments ROTATED TO THE PITCH, and the four things
	that make the shape read are:
	  * it OVERHANGS a long way -- an eave flush with the wall is a shed;
	  * the pitch is CONCAVE, steep at the ridge and flaring out almost flat at
	    the eave, which is the line that says "Japanese" and not "barn". Height
	    above the eave goes as u^1.7 with u measured inward, so the slope starts
	    flat at the eave and steepens all the way up;
	  * the ridge is a fat capped beam, not a line where two planes meet;
	  * katsuogi (short billets across the ridge) and chigi (forked finials at
	    each end) sit on top of it.

	Gabled along X: `width` is the ridge direction, `depth` front-to-back, both
	measured over the overhang. The gable ends are stepped -- they are seen
	nearly edge-on and a triangle of five boxes is indistinguishable from a
	wedge there, where the slopes are seen broadside and were not.
]]
local function roof(parent, cx: number, cz: number, baseY: number,
	width: number, depth: number, rise: number, segs: number, tint: Color3?)

	local tile = tint or ROOF_TILE
	local m2 = Instance.new("Model")
	m2.Name = "Roof"
	m2.Parent = parent
	segs = math.max(3, segs)
	local half = depth * 0.5

	-- The two slopes.
	for _, sz in ipairs({ -1, 1 }) do
		for i = 0, segs - 1 do
			local u0, u1 = i / segs, (i + 1) / segs
			local z0 = cz + sz * half * (1 - u0)
			local z1 = cz + sz * half * (1 - u1)
			local y0 = baseY + rise * (u0 ^ 1.7)
			local y1 = baseY + rise * (u1 ^ 1.7)
			local len = math.sqrt((z1 - z0) ^ 2 + (y1 - y0) ^ 2)
			local mid = Vector3.new(cx, (y0 + y1) * 0.5, (z0 + z1) * 0.5)
			-- lookAt puts the frame's LOOK (-Z) on the target, so local Z lies
			-- along the slope either way -- and the slab is symmetric, so which
			-- way round it points does not matter.
			trim(m2, "Slope", Vector3.new(width, 1.5, len + 0.6),
				CFrame.lookAt(mid, Vector3.new(cx, y1, z1)),
				(i % 2 == 0) and tile or ROOF_TILE_DEEP, Enum.Material.Slate)
			-- The exposed rafter ends, on the lowest segment only: the detail
			-- that stops the eave being a bare edge.
			if i == 0 then
				trim(m2, "Rafters", Vector3.new(width + 0.6, 0.5, len * 0.55),
					CFrame.lookAt(mid, Vector3.new(cx, y1, z1)) * CFrame.new(0, -1.0, len * 0.2),
					TIMBER_LIGHT, Enum.Material.Wood)
			end
		end
	end

	-- The gable ends, stepped, plus the barge board down each slope edge.
	for _, sx in ipairs({ -1, 1 }) do
		local gx = cx + sx * width * 0.5
		for i = 0, 4 do
			local u0, u1 = i / 5, (i + 1) / 5
			local zw = half * (1 - u0) * 2
			local h0 = baseY + rise * (u0 ^ 1.7)
			local h1 = baseY + rise * (u1 ^ 1.7)
			-- TUCKED WELL INBOARD. Flush with the slope's outer edge these stood
			-- proud of it -- the slope is TILTED, so its surface at that X is
			-- lower than a vertical box reaching the same height, and the steps
			-- showed as a white staircase up the roof from every side angle.
			-- Timber rather than plaster too: if a sliver ever does show, boarding
			-- is what a gable end is made of.
			trim(m2, "Gable", Vector3.new(1.6, h1 - h0, zw - 0.6),
				CFrame.new(gx - sx * 2.6, (h0 + h1) * 0.5 - 0.5, cz), TIMBER_LIGHT,
				Enum.Material.Wood)
		end
		-- GEGYO: the little pendant board hung at the gable's apex, which is the
		-- one ornament that tells you this is a shrine and not a farmhouse.
		trim(m2, "Gegyo", Vector3.new(2.2, 4.4, 3.2),
			CFrame.new(gx - sx * 0.6, baseY + rise - 2.4, cz), TIMBER_LIGHT, Enum.Material.Wood)
		trim(m2, "GegyoBoss", Vector3.new(2.6, 1.6, 1.6),
			CFrame.new(gx - sx * 0.6, baseY + rise - 1.2, cz), GOLD_DEEP, Enum.Material.Metal,
			{ Reflectance = 0.2 })
	end

	-- THE RIDGE, and it must be fat. A thin one reads as a seam.
	local ridgeY = baseY + rise + 0.9
	trim(m2, "Ridge", Vector3.new(width * 0.99, 2.6, depth * 0.13),
		CFrame.new(cx, ridgeY, cz), ROOF_TILE_DEEP, Enum.Material.Slate)
	trim(m2, "RidgeCap", Vector3.new(width * 1.01, 1.1, depth * 0.16),
		CFrame.new(cx, ridgeY + 1.6, cz), GOLD_DEEP, Enum.Material.Metal, { Reflectance = 0.18 })

	-- KATSUOGI: short billets lying ACROSS the ridge. A cylinder's length runs
	-- along its local X, so these need turning a quarter turn to lie across it.
	local n = math.clamp(math.floor(width / 16), 3, 7)
	for i = 0, n - 1 do
		local t = (n == 1) and 0.5 or (i / (n - 1))
		trim(m2, "Katsuogi", Vector3.new(depth * 0.20, 2.0, 2.0),
			CFrame.new(cx - width * 0.38 + width * 0.76 * t, ridgeY + 2.3, cz)
				* CFrame.Angles(0, math.rad(90), 0),
			GOLD_DEEP, Enum.Material.Metal, { Shape = Enum.PartType.Cylinder, Reflectance = 0.15 })
	end

	-- CHIGI: the forked finials at each end of the ridge, crossed like scissors.
	for _, sx in ipairs({ -1, 1 }) do
		for _, tilt in ipairs({ -1, 1 }) do
			trim(m2, "Chigi", Vector3.new(1.2, rise * 0.5 + 5, 1.2),
				CFrame.new(cx + sx * (width * 0.48), ridgeY + rise * 0.16 + 2.6, cz)
					* CFrame.Angles(math.rad(tilt * 24), 0, math.rad(sx * -13)),
				GOLD_DEEP, Enum.Material.Metal, { Reflectance = 0.18 })
		end
	end
	return m2
end

--[[
	A TORII. Two posts, a curved kasagi (the top rail, which OVERHANGS and turns
	up at the ends), the nuki tie-beam under it and the little gakuzuka block
	between them. Vermilion with black feet, which is the Inari colouring.
]]
local function torii(parent, cx: number, y: number, cz: number, span: number, height: number)
	local m2 = Instance.new("Model")
	m2.Name = "Torii"
	m2.Parent = parent
	local postR = span * 0.055
	for _, sx in ipairs({ -1, 1 }) do
		-- Posts LEAN IN slightly, which every real torii does and which is most of
		-- why a straight-sided one looks like a football goal.
		trim(m2, "Post", Vector3.new(postR * 2, height, postR * 2),
			CFrame.new(cx + sx * span * 0.5, y + height * 0.5, cz)
				* CFrame.Angles(0, 0, math.rad(sx * 1.6)),
			VERMILION, Enum.Material.Wood)
		trim(m2, "PostFoot", Vector3.new(postR * 2.5, 2.2, postR * 2.5),
			CFrame.new(cx + sx * span * 0.5, y + 1.1, cz), INK, Enum.Material.Slate)
	end
	-- NUKI: the tie beam, which stops short of the posts on a real one.
	trim(m2, "Nuki", Vector3.new(span * 0.92, height * 0.055, postR * 1.7),
		CFrame.new(cx, y + height * 0.76, cz), VERMILION, Enum.Material.Wood)
	trim(m2, "Gakuzuka", Vector3.new(postR * 1.2, height * 0.10, postR * 1.9),
		CFrame.new(cx, y + height * 0.855, cz), VERMILION_DEEP, Enum.Material.Wood)
	-- KASAGI: the crown. Three courses, each wider, so it reads as turning up at
	-- the tips rather than as a plank laid on two sticks.
	local kw = span * 1.22
	trim(m2, "Shimaki", Vector3.new(kw * 0.94, height * 0.045, postR * 2.2),
		CFrame.new(cx, y + height * 0.925, cz), VERMILION_DEEP, Enum.Material.Wood)
	trim(m2, "Kasagi", Vector3.new(kw, height * 0.055, postR * 2.9),
		CFrame.new(cx, y + height * 0.975, cz), INK, Enum.Material.Slate)
	for _, sx in ipairs({ -1, 1 }) do
		trim(m2, "KasagiTip", Vector3.new(kw * 0.13, height * 0.05, postR * 2.9),
			CFrame.new(cx + sx * kw * 0.47, y + height * 0.995, cz)
				* CFrame.Angles(0, 0, math.rad(sx * -7)), INK, Enum.Material.Slate)
	end
	return m2
end

----------------------------------------------------------------
-- The shrine litter set
--
-- ReplicatedStorage.CTB.Shrine, cloned by CTB_Client for island 6 exactly the
-- way it clones the trash meshes for the beaches and the gold for the tomb.
--
-- Every entry is a single BasePart. That is load-bearing: the sink and raise
-- tweens in CTB_Client drive one part directly, and a Model would need welding
-- before it could be moved as a piece.
--
-- BLOCK AND BALL ONLY, which is the tomb's rule and the dune set's before it. A
-- Part cylinder's axis runs along its LOCAL X and the scatter overwrites each
-- prop's CFrame outright, so every cylinder comes out lying on its side however
-- the template was saved.
--
-- WHAT A FESTIVAL LEAVES BEHIND, not rubbish. The point of a per-island set is
-- that the junk says where you are: cans and bottles on the beach, spilled gold
-- in the tomb, and here the aftermath of a night of prayers and offerings --
-- fortune slips, spent incense, sake cups, ema boards, coins, petals.
----------------------------------------------------------------
local OFFERINGS = {
	-- Paper, which is most of what is actually on the floor of a shrine
	{ "Omikuji", Vector3.new(0.35, 0.5, 0.9), PAPER, Enum.Material.SmoothPlastic, 0, Enum.PartType.Block },
	{ "OmikujiRolled", Vector3.new(0.3, 0.3, 1.1), Color3.fromRGB(240, 236, 220), Enum.Material.SmoothPlastic, 0, Enum.PartType.Block },
	{ "PaperCrane", Vector3.new(1.0, 0.6, 0.8), Color3.fromRGB(236, 176, 196), Enum.Material.SmoothPlastic, 0, Enum.PartType.Block },
	{ "ShideScrap", Vector3.new(0.8, 0.2, 0.7), PAPER, Enum.Material.SmoothPlastic, 0, Enum.PartType.Block },
	{ "FanPaper", Vector3.new(1.6, 0.18, 1.0), Color3.fromRGB(246, 214, 150), Enum.Material.SmoothPlastic, 0, Enum.PartType.Block },

	-- Wood
	{ "EmaPlaque", Vector3.new(1.5, 0.22, 1.2), Color3.fromRGB(192, 148, 96), Enum.Material.Wood, 0, Enum.PartType.Block },
	{ "EmaSmall", Vector3.new(1.1, 0.2, 0.9), Color3.fromRGB(206, 164, 110), Enum.Material.Wood, 0, Enum.PartType.Block },
	{ "Chopstick", Vector3.new(1.9, 0.16, 0.16), Color3.fromRGB(214, 182, 130), Enum.Material.Wood, 0, Enum.PartType.Block },
	{ "IncenseStub", Vector3.new(0.14, 0.14, 1.4), Color3.fromRGB(84, 62, 48), Enum.Material.Wood, 0, Enum.PartType.Block },

	-- Pottery and glass
	{ "SakeCup", Vector3.new(0.9, 0.55, 0.9), PLASTER, Enum.Material.SmoothPlastic, 0.05, Enum.PartType.Ball },
	{ "SakeFlask", Vector3.new(0.9, 1.4, 0.9), Color3.fromRGB(226, 226, 214), Enum.Material.SmoothPlastic, 0.05, Enum.PartType.Ball },
	{ "TeaBowl", Vector3.new(1.2, 0.6, 1.2), JADE, Enum.Material.SmoothPlastic, 0.06, Enum.PartType.Ball },
	{ "Shard", Vector3.new(0.8, 0.25, 0.9), Color3.fromRGB(210, 208, 196), Enum.Material.Slate, 0, Enum.PartType.Block },

	-- Metal, and the one thing on this floor that is literally money
	{ "OfferingCoin", Vector3.new(0.7, 0.16, 0.7), GOLD_DEEP, Enum.Material.Metal, 0.3, Enum.PartType.Ball },
	{ "CoinScatter", Vector3.new(1.5, 0.3, 1.3), GOLD, Enum.Material.Metal, 0.28, Enum.PartType.Ball },
	{ "BellCharm", Vector3.new(0.8, 0.8, 0.8), GOLD, Enum.Material.Metal, 0.35, Enum.PartType.Ball },

	-- Petals, because it is a cove shrine and the trees are outside the door
	{ "PetalDrift", Vector3.new(1.7, 0.1, 1.4), PETAL, Enum.Material.SmoothPlastic, 0, Enum.PartType.Block },
	{ "PetalHeap", Vector3.new(2.1, 0.35, 1.8), Color3.fromRGB(250, 178, 198), Enum.Material.SmoothPlastic, 0, Enum.PartType.Ball },

	-- The showpieces. Four against eighteen, and they are what the eye lands on:
	-- a floor of nothing but paper reads as one texture at any distance.
	{ "LanternFallen", Vector3.new(2.3, 2.0, 2.3), Color3.fromRGB(244, 218, 168), Enum.Material.SmoothPlastic, 0, Enum.PartType.Ball },
	{ "DarumaDoll", Vector3.new(1.8, 1.9, 1.8), VERMILION, Enum.Material.SmoothPlastic, 0.05, Enum.PartType.Ball },
	{ "MaskKitsune", Vector3.new(1.5, 1.7, 0.6), Color3.fromRGB(250, 244, 232), Enum.Material.SmoothPlastic, 0.08, Enum.PartType.Block },
	{ "SakeBarrel", Vector3.new(2.0, 2.2, 2.0), Color3.fromRGB(226, 210, 172), Enum.Material.Wood, 0, Enum.PartType.Ball },
}

local function buildOfferingSet(): number
	local old = CTB:FindFirstChild("Shrine")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "Shrine"
	folder.Parent = CTB

	for _, t in ipairs(OFFERINGS) do
		local p = Instance.new("Part")
		p.Name = t[1]
		p.Size = t[2]
		p.Color = t[3]
		p.Material = t[4]
		p.Reflectance = t[5]
		p.Shape = t[6]
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = folder
	end
	return #OFFERINGS
end

----------------------------------------------------------------
-- Floor
--
-- Same two-step as the tomb and the desert plateau: fill to a whole voxel
-- boundary, then write the top layer at the field's own occupancy. Fill*
-- rounds to whole voxels and smooth terrain renders its surface at the centre
-- of the first non-full voxel, so filling "to y = 3" would actually come out at
-- y = 6 and leave the rakeable square sitting in a pit.
----------------------------------------------------------------
local function buildFloor()
	local fx0, fx1 = CX - 128, CX + 128
	local fz0, fz1 = CZ - 148, CZ + 148

	Terrain:FillBlock(
		CFrame.new((fx0 + fx1) * 0.5, 40, (fz0 + fz1) * 0.5),
		Vector3.new(fx1 - fx0 + 40, 160, fz1 - fz0 + 40), Enum.Material.Air)
	Terrain:FillBlock(
		CFrame.new((fx0 + fx1) * 0.5, -10, (fz0 + fz1) * 0.5),
		Vector3.new(fx1 - fx0, 20, fz1 - fz0), ISL.matMessy)

	local _, o3 = Config.occupancyFor(GROUND)
	local nx = (fx1 - fx0) // Config.VOXEL
	local nz = (fz1 - fz0) // Config.VOXEL
	local region = Region3.new(
		Vector3.new(fx0, 0, fz0),
		Vector3.new(fx1, Config.VOXEL, fz1)
	):ExpandToGrid(Config.VOXEL)

	local mats, occs = table.create(nx), table.create(nx)
	for xi = 1, nx do
		local mx, ox = { table.create(nz) }, { table.create(nz) }
		mats[xi], occs[xi] = mx, ox
		for zi = 1, nz do
			mx[1][zi], ox[1][zi] = ISL.matMessy, o3
		end
	end
	Terrain:WriteVoxels(region, Config.VOXEL, mats, occs)
end

----------------------------------------------------------------
-- Build: the hall
----------------------------------------------------------------
function Shrine.build()
	local old = workspace:FindFirstChild("InnerShrine")
	if old then
		old:Destroy()
	end
	local root = Instance.new("Folder")
	root.Name = "InnerShrine"
	root.Parent = workspace

	local props = buildOfferingSet()
	buildFloor()

	----------------------------------------------------------------
	-- Shell: six sealed sides, with the altar end raised.
	--
	-- Nobody is meant to know this room is standing on its own 1500 studs east
	-- of the cove. Every wall runs to the ceiling above it, the two ceiling
	-- slabs meet the walls at their own heights, and the only opening anywhere
	-- is the vertical face at ALTAR_Z between the two -- which is interior, and
	-- is the mouth of the altar bay.
	----------------------------------------------------------------
	local shell = Instance.new("Model")
	shell.Name = "Shell"
	shell.Parent = root

	local TOP = CEIL + WALL
	local ALTAR_TOP = ALTAR_CEIL + WALL

	box(shell, "WallN", X0 - WALL, X1 + WALL, GROUND, ALTAR_CEIL, Z1, Z1 + WALL, PLASTER,
		Enum.Material.Concrete)
	box(shell, "WallS", X0 - WALL, X1 + WALL, GROUND, CEIL, Z0 - WALL, Z0, PLASTER,
		Enum.Material.Concrete)
	for _, w in ipairs({ { X0 - WALL, X0, "W" }, { X1, X1 + WALL, "E" } }) do
		box(shell, "Wall" .. w[3], w[1], w[2], GROUND, CEIL, Z0, ALTAR_Z, PLASTER,
			Enum.Material.Concrete)
		box(shell, "Wall" .. w[3] .. "Altar", w[1], w[2], GROUND, ALTAR_CEIL, ALTAR_Z, Z1, PLASTER,
			Enum.Material.Concrete)
	end
	box(shell, "Ceiling", X0 - WALL, X1 + WALL, CEIL, TOP, Z0 - WALL, ALTAR_Z, TIMBER_DARK,
		Enum.Material.Wood)
	box(shell, "CeilingAltar", X0 - WALL, X1 + WALL, ALTAR_CEIL, ALTAR_TOP, ALTAR_Z, Z1 + WALL,
		TIMBER_DARK, Enum.Material.Wood)

	--[[
		THE DADO, and it is doing more work than it looks like.

		A plaster wall 36 studs tall with nothing on it reads as a warehouse. Real
		shrine interiors band the wall: dark timber to about waist height, plaster
		above, a rail where they meet. Three boxes per wall and the room stops
		being a white box.
	]]
	local DADO = GROUND + 7
	local function banded(name, x0, x1, z0, z1)
		box(shell, name .. "Dado", x0, x1, GROUND, DADO, z0, z1, TIMBER, Enum.Material.Wood)
		box(shell, name .. "Rail", x0 - 0.4, x1 + 0.4, DADO, DADO + 0.9, z0 - 0.4, z1 + 0.4,
			TIMBER_DARK, Enum.Material.Wood)
	end
	banded("S", X0, X1, Z0, Z0 + 0.8)
	banded("N", X0, X1, Z1 - 0.8, Z1)
	banded("W", X0, X0 + 0.8, Z0, Z1)
	banded("E", X1 - 0.8, X1, Z0, Z1)

	--[[
		SHOJI ALONG BOTH SIDE WALLS, backlit.

		This is the one thing that stops a sealed room feeling sealed. Each bay is
		a pale panel in a dark lattice with a light behind it, which the eye reads
		as an overcast afternoon on the other side of the paper -- and it costs a
		part per mullion instead of an actual exterior.

		The panels are NOT transparent and there is nothing behind them: a
		translucent panel on a sealed wall shows the black inside of the shell,
		which is worse than no window at all. What sells it is the PointLight in
		front, grazing the paper.
	]]
	local shoji = Instance.new("Model")
	shoji.Name = "Shoji"
	shoji.Parent = root
	for _, side in ipairs({ { X0 + 1.0, 1 }, { X1 - 1.0, -1 } }) do
		local wx, inward = side[1], side[2]
		for bz = Z0 + 26, ALTAR_Z - 26, 26 do
			local z0, z1 = bz, bz + 18
			trim(shoji, "Paper", Vector3.new(0.5, 15, z1 - z0),
				CFrame.new(wx + inward * 0.3, DADO + 8.4, (z0 + z1) * 0.5), PAPER,
				Enum.Material.SmoothPlastic)
			-- the lattice: two rails and four mullions, all thin and dark
			for _, ry in ipairs({ DADO + 1.2, DADO + 8.4, DADO + 15.6 }) do
				trim(shoji, "Rail", Vector3.new(0.75, 0.7, z1 - z0 + 0.6),
					CFrame.new(wx + inward * 0.55, ry, (z0 + z1) * 0.5), TIMBER_DARK,
					Enum.Material.Wood)
			end
			for k = 0, 4 do
				trim(shoji, "Mullion", Vector3.new(0.75, 15, 0.55),
					CFrame.new(wx + inward * 0.55, DADO + 8.4, z0 + (z1 - z0) * k / 4),
					TIMBER_DARK, Enum.Material.Wood)
			end
			local day = Instance.new("PointLight")
			day.Color = Color3.fromRGB(226, 236, 255)
			day.Brightness = 1.1
			day.Range = 30
			day.Shadows = false
			day.Parent = shoji:FindFirstChild("Paper")
		end
	end

	----------------------------------------------------------------
	-- The colonnade
	--
	-- Vermilion pillars on stone pads, with the bracket blocks (tokyo) that sit
	-- between a Japanese pillar and the beam it carries. Outside the field on
	-- purpose: ISLANDS[6].resetAt is 1.0, which means the square tolerates NO
	-- blocked cells -- one solid part parked on one cell and this room can never
	-- be finished again. x = CX +- 76 against a field edge at CX +- 64.
	----------------------------------------------------------------
	local colon = Instance.new("Model")
	colon.Name = "Colonnade"
	colon.Parent = root
	local PILLAR_X = 76
	local pillarZ = {}
	for z = Z0 + 30, ALTAR_Z - 10, 27 do
		table.insert(pillarZ, z)
	end
	for _, sx in ipairs({ -1, 1 }) do
		local px = CX + sx * PILLAR_X
		for _, pz in ipairs(pillarZ) do
			P(colon, "PillarPad", Vector3.new(7.5, 1.2, 7.5),
				CFrame.new(px, GROUND + 0.6, pz), STONE_DARK, Enum.Material.Slate)
			P(colon, "Pillar", Vector3.new(5.2, 25, 5.2),
				CFrame.new(px, GROUND + 13.7, pz), VERMILION, Enum.Material.Wood)
			trim(colon, "PillarRing", Vector3.new(5.8, 0.8, 5.8),
				CFrame.new(px, GROUND + 8, pz), GOLD_DEEP, Enum.Material.Metal,
				{ Reflectance = 0.16 })
			-- tokyo: two stepped bracket blocks under the beam
			trim(colon, "Bracket", Vector3.new(7.4, 1.4, 7.4),
				CFrame.new(px, GROUND + 26.9, pz), TIMBER_LIGHT, Enum.Material.Wood)
			trim(colon, "Bracket2", Vector3.new(9.2, 1.4, 9.2),
				CFrame.new(px, GROUND + 28.3, pz), TIMBER, Enum.Material.Wood)
		end
		-- the architrave the whole row carries
		trim(colon, "Architrave", Vector3.new(6.4, 2.6, ALTAR_Z - Z0 - 26),
			CFrame.new(px, GROUND + 30.3, (Z0 + 30 + ALTAR_Z - 10) * 0.5), TIMBER,
			Enum.Material.Wood)
		trim(colon, "ArchitraveTrim", Vector3.new(7.0, 0.7, ALTAR_Z - Z0 - 26),
			CFrame.new(px, GROUND + 31.9, (Z0 + 30 + ALTAR_Z - 10) * 0.5), VERMILION_DEEP,
			Enum.Material.Wood)
	end

	--[[
		A COFFERED CEILING (goten-jo). Dark beams both ways with pale panels
		between them, which is what every hall of this kind has overhead -- and
		the ceiling is a third of what the player sees from the floor of a room
		this tall, so leaving it as one flat slab wastes the biggest surface here.
	]]
	local coff = Instance.new("Model")
	coff.Name = "Coffers"
	coff.Parent = root
	trim(coff, "Panel", Vector3.new(X1 - X0, 0.6, ALTAR_Z - Z0),
		CFrame.new(CX, CEIL - 0.4, (Z0 + ALTAR_Z) * 0.5), Color3.fromRGB(206, 190, 164),
		Enum.Material.Wood)
	for z = Z0 + 12, ALTAR_Z - 6, 16 do
		trim(coff, "BeamX", Vector3.new(X1 - X0, 1.7, 1.6),
			CFrame.new(CX, CEIL - 1.2, z), TIMBER_DARK, Enum.Material.Wood)
	end
	for x = X0 + 16, X1 - 8, 24 do
		trim(coff, "BeamZ", Vector3.new(1.6, 1.7, ALTAR_Z - Z0),
			CFrame.new(x, CEIL - 1.2, (Z0 + ALTAR_Z) * 0.5), TIMBER_DARK, Enum.Material.Wood)
	end

	----------------------------------------------------------------
	-- Hanging lanterns, two rows, between the pillars
	----------------------------------------------------------------
	local lamps = Instance.new("Model")
	lamps.Name = "Lanterns"
	lamps.Parent = root
	for _, sx in ipairs({ -1, 1 }) do
		for _, pz in ipairs(pillarZ) do
			lantern(lamps, CFrame.new(CX + sx * (PILLAR_X - 12), GROUND + 24, pz + 13.5))
		end
	end

	--[[
		A ROW DOWN THE MIDDLE, and it is a gameplay fix rather than a decorative
		one.

		Both aisles were lit and the centre was not, which put the darkest part of
		the room exactly over the rakeable square -- the 128 studs the player
		actually spends all their time on, looking for litter against a floor
		tinted (122, 86, 58). Hung higher than the aisle pairs so they clear a
		head and do not become the thing you walk into.
	]]
	for _, pz in ipairs(pillarZ) do
		lantern(lamps, CFrame.new(CX, GROUND + 28, pz + 13.5),
			Color3.fromRGB(250, 230, 190), 40)
	end
	----------------------------------------------------------------
	-- The altar bay
	--
	-- Everything past ALTAR_Z, under the raised ceiling. A shrine's holy of
	-- holies holds a MIRROR, not an idol -- the shintai, the object the god is
	-- said to inhabit -- so that is what the hall points at, up a flight of
	-- steps behind a rope nobody crosses.
	----------------------------------------------------------------
	local altar = Instance.new("Model")
	altar.Name = "Altar"
	altar.Parent = root

	-- Three steps up to the platform, each one narrower.
	for i = 0, 2 do
		box(altar, "Step", CX - 46 + i * 5, CX + 46 - i * 5, GROUND + i * 1.6,
			GROUND + (i + 1) * 1.6, ALTAR_Z + 4 + i * 4, Z1 - 4, TIMBER_LIGHT,
			Enum.Material.Wood)
	end
	local DECK = GROUND + 4.8
	box(altar, "Deck", CX - 40, CX + 40, DECK - 0.9, DECK, ALTAR_Z + 16, Z1 - 6, TIMBER_LIGHT,
		Enum.Material.Wood)
	box(altar, "DeckEdge", CX - 41, CX + 41, DECK - 1.5, DECK - 0.6, ALTAR_Z + 15, Z1 - 5,
		TIMBER_DARK, Enum.Material.Wood)

	-- The honden cabinet the mirror stands in: a vermilion box with gold
	-- fittings and its own little roof, which is the shrine-within-the-shrine.
	local HZ = Z1 - 20
	box(altar, "CabinetBase", CX - 15, CX + 15, DECK, DECK + 2, HZ - 8, HZ + 8, TIMBER_DARK,
		Enum.Material.Wood)
	box(altar, "Cabinet", CX - 13, CX + 13, DECK + 2, DECK + 17, HZ - 6.5, HZ + 6.5, VERMILION,
		Enum.Material.Wood)
	box(altar, "CabinetInset", CX - 9, CX + 9, DECK + 4, DECK + 14.5, HZ - 7.2, HZ - 6.4, INK,
		Enum.Material.Slate)
	for _, sx in ipairs({ -1, 1 }) do
		box(altar, "CabinetPost", CX + sx * 13 - 1.2, CX + sx * 13 + 1.2, DECK + 2, DECK + 18,
			HZ - 7, HZ + 7, VERMILION_DEEP, Enum.Material.Wood)
	end
	box(altar, "CabinetLintel", CX - 15, CX + 15, DECK + 17, DECK + 19, HZ - 8, HZ + 8, GOLD_DEEP,
		Enum.Material.Metal, { Reflectance = 0.2 })
	roof(altar, CX, HZ, DECK + 19, 38, 26, 9, 6)

	--[[
		THE SHINTAI: a polished bronze mirror on a stand, and the one genuinely
		reflective thing in the room.

		A Ball part is a SPHERE OF ITS SMALLEST AXIS however its Size reads back,
		so a disc cannot be made this way -- it comes out a marble. This is a
		cylinder, which does honour a non-uniform Size, stood on end with
		Orientation (0, 0, 90); a cylinder's length is its local X, so the two
		equal numbers are the diameter.
	]]
	trim(altar, "MirrorStand", Vector3.new(3, 3.4, 1.6),
		CFrame.new(CX, DECK + 4.2, HZ - 1), TIMBER_DARK, Enum.Material.Wood)
	local mirror = trim(altar, "Shintai", Vector3.new(0.7, 8.4, 8.4),
		CFrame.new(CX, DECK + 9.4, HZ - 1) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(238, 214, 150), Enum.Material.Metal,
		{ Reflectance = 0.55, Shape = Enum.PartType.Cylinder })
	trim(altar, "ShintaiRim", Vector3.new(0.55, 9.6, 9.6),
		CFrame.new(CX, DECK + 9.4, HZ - 1.3) * CFrame.Angles(0, 0, math.rad(90)),
		GOLD_DEEP, Enum.Material.Metal, { Reflectance = 0.3, Shape = Enum.PartType.Cylinder })
	local halo = Instance.new("PointLight")
	halo.Color = Color3.fromRGB(255, 226, 170)
	halo.Brightness = 2.2
	halo.Range = 40
	halo.Shadows = false
	halo.Parent = mirror

	-- Offerings on the deck in front of it: rice, sake, salt, a sprig of sakaki.
	for i, off in ipairs({ { -9, "Rice", PLASTER }, { -3, "Salt", Color3.fromRGB(250, 250, 244) },
		{ 3, "Sake", Color3.fromRGB(228, 226, 210) }, { 9, "Sakaki", JADE } }) do
		trim(altar, "OfferStand", Vector3.new(3.4, 1.6, 3.4),
			CFrame.new(CX + off[1], DECK + 0.8, HZ + 9), TIMBER_DARK, Enum.Material.Wood)
		trim(altar, off[2], Vector3.new(2.4, 2.2, 2.4),
			CFrame.new(CX + off[1], DECK + 2.5, HZ + 9), off[3],
			off[2] == "Sakaki" and Enum.Material.Grass or Enum.Material.SmoothPlastic,
			{ Shape = Enum.PartType.Ball })
	end

	-- Stone lanterns and guardians flanking the steps, turned to face each other
	-- across the way in -- komainu look at the visitor, not at the wall.
	toro(altar, CFrame.new(CX - 34, GROUND, ALTAR_Z + 20), 1.3)
	toro(altar, CFrame.new(CX + 34, GROUND, ALTAR_Z + 20), 1.3)
	komainu(altar, CFrame.new(CX - 24, GROUND, ALTAR_Z + 2) * CFrame.Angles(0, math.rad(196), 0), true, 1.25)
	komainu(altar, CFrame.new(CX + 24, GROUND, ALTAR_Z + 2) * CFrame.Angles(0, math.rad(164), 0), false, 1.25)

	--[[
		THE ROPE ACROSS THE BAY MOUTH. A shimenawa marks the boundary of the
		sacred, and hung across the opening at ALTAR_Z it does the same job for
		the composition: it frames the altar from the hall and gives the eye
		something at mid height in a room that is otherwise floor and ceiling.
	]]
	shimenawa(altar, CX - 44, CX + 44, GROUND + 25, ALTAR_Z + 1, 3.2)

	----------------------------------------------------------------
	-- The saisenbako and the bell, at the near end where you arrive
	----------------------------------------------------------------
	local worship = Instance.new("Model")
	worship.Name = "Worship"
	worship.Parent = root
	local WZ = Z0 + 34
	box(worship, "Saisenbako", CX - 9, CX + 9, GROUND, GROUND + 4.4, WZ - 3.5, WZ + 3.5, TIMBER,
		Enum.Material.Wood)
	box(worship, "SaisenRim", CX - 9.6, CX + 9.6, GROUND + 4.4, GROUND + 5, WZ - 4.1, WZ + 4.1,
		TIMBER_DARK, Enum.Material.Wood)
	-- the slatted top coins go through
	for sx = -8, 8, 2 do
		trim(worship, "SaisenSlat", Vector3.new(1.1, 0.5, 7.4),
			CFrame.new(CX + sx, GROUND + 4.9, WZ), TIMBER_DARK, Enum.Material.Wood)
	end
	--[[
		THE SUZU: bell above, pull-rope below, hung off its own beam.

		Both numbers were wrong first time. The rope was 1.5 studs thick and ran
		y 11..29, which from the arrival point is a red COLUMN straight up the
		middle of the shot -- it hid the altar the whole hall is pointing at. And
		the bell sat at y 26.5, i.e. inside the top third of the rope rather than
		above it, so the two read as one object.

		Thin rope, bell clear above it, and a beam to hang the pair from -- an
		object floating with nothing holding it up is the thing that makes a room
		look unfinished.
	]]
	trim(worship, "SuzuBeam", Vector3.new(15, 1.3, 1.3),
		CFrame.new(CX, GROUND + 31, WZ), TIMBER_DARK, Enum.Material.Wood)
	trim(worship, "SuzuHanger", Vector3.new(0.4, 3.4, 0.4),
		CFrame.new(CX, GROUND + 29, WZ), TIMBER_DARK, Enum.Material.Wood)
	trim(worship, "Suzu", Vector3.new(4.6, 4.2, 4.6),
		CFrame.new(CX, GROUND + 25.6, WZ), GOLD_DEEP, Enum.Material.Metal,
		{ Reflectance = 0.3, Shape = Enum.PartType.Ball })
	trim(worship, "SuzuRope", Vector3.new(0.95, 15, 0.95),
		CFrame.new(CX, GROUND + 15.6, WZ), Color3.fromRGB(206, 58, 58), Enum.Material.Fabric)
	-- The white bindings every couple of studs, which is what makes a red bar
	-- read as a braided rope.
	for i = 0, 4 do
		trim(worship, "RopeBind", Vector3.new(1.15, 0.7, 1.15),
			CFrame.new(CX, GROUND + 10 + i * 3, WZ), Color3.fromRGB(240, 236, 226),
			Enum.Material.Fabric)
	end

	----------------------------------------------------------------
	-- The offertory box: this room's sell pad, so a bag filled in here does not
	-- have to be carried back out through the cinematic to be worth anything.
	-- The tomb's scales, restated in wood.
	----------------------------------------------------------------
	local counter = Instance.new("Model")
	counter.Name = "Juyosho"
	counter.Parent = root
	local SX, SZ = CX - 62, Z0 + 30

	box(counter, "Counter", SX - 12, SX + 12, GROUND, GROUND + 4.6, SZ + 6, SZ + 12, TIMBER,
		Enum.Material.Wood)
	box(counter, "CounterTop", SX - 13, SX + 13, GROUND + 4.6, GROUND + 5.4, SZ + 5.4, SZ + 12.6,
		TIMBER_LIGHT, Enum.Material.Wood)
	for _, sx in ipairs({ -1, 1 }) do
		box(counter, "Post", SX + sx * 12 - 0.7, SX + sx * 12 + 0.7, GROUND + 5.4, GROUND + 20,
			SZ + 8.5, SZ + 9.9, VERMILION, Enum.Material.Wood)
	end
	box(counter, "Valance", SX - 13.5, SX + 13.5, GROUND + 19, GROUND + 21, SZ + 8, SZ + 10.4,
		VERMILION_DEEP, Enum.Material.Wood)
	roof(counter, SX, SZ + 9.2, GROUND + 21, 30, 14, 5, 5)
	lantern(counter, CFrame.new(SX - 9, GROUND + 17, SZ + 6.5), Color3.fromRGB(252, 214, 150))
	lantern(counter, CFrame.new(SX + 9, GROUND + 17, SZ + 6.5), Color3.fromRGB(252, 214, 150))

	local pad = P(counter, "SellPad", Vector3.new(20, 0.45, 13),
		CFrame.new(SX, GROUND + 0.22, SZ), TIMBER_LIGHT, Enum.Material.Wood)
	P(counter, "PadGlow", Vector3.new(20.7, 0.2, 13.7),
		CFrame.new(SX, GROUND + 0.06, SZ), Color3.fromRGB(255, 216, 150), Enum.Material.Neon,
		{ CanCollide = false, Transparency = 0.35 })

	----------------------------------------------------------------
	-- The way out
	--
	-- A torii standing inside the room, over a lit pad. The tomb uses a doorway
	-- with a neon veil across it; here the gate IS the doorway, which is what a
	-- torii means -- you are leaving the sacred ground by passing under it.
	----------------------------------------------------------------
	local exitM = Instance.new("Model")
	exitM.Name = "Exit"
	exitM.Parent = root
	local EZ = Z0 + 12

	torii(exitM, CX, GROUND, EZ, 30, 26)
	shimenawa(exitM, CX - 13, CX + 13, GROUND + 19, EZ, 1.6)
	toro(exitM, CFrame.new(CX - 24, GROUND, EZ), 1.0)
	toro(exitM, CFrame.new(CX + 24, GROUND, EZ), 1.0)

	P(exitM, "Pad", Vector3.new(13, 0.5, 10),
		CFrame.new(CX, GROUND + 0.25, EZ - 5), Color3.fromRGB(255, 196, 208),
		Enum.Material.Neon, { Transparency = 0.5 })

	--[[
		THE PROMPT DOES NOT GO ON THE PAD. It goes on an anchor six studs above
		it, and that is not tidiness -- on the pad it never rendered.

		WHAT WAS MEASURED. Standing five studs away, prompt enabled, in range,
		RequiresLineOfSight off, no other prompt within 120 studs:
		ProximityPromptService.PromptShown never fired, and E did nothing. A
		prompt built on the CLIENT on the same part did not show either, so it
		was not the replicated instance. A fresh part with a fresh prompt at the
		pad's exact position (y = 3.25, a quarter stud over a terrain floor at
		y = 3) did not show; the identical thing nine studs higher showed
		instantly. Moving it up fixed it, and the whole leave flow then worked
		first try.

		WHAT IS NOT KNOWN is WHY, and the obvious explanation is wrong. "A prompt
		at floor level does not render" was the first conclusion and it does not
		survive a control: the TOMB's exit prompt sits at exactly the same
		GROUND + 0.25 over the same y = 3 terrain, and it shows perfectly well.
		So it is something about this spot or this pad, not the height as such --
		possibly the torii standing across the doorway two studs behind it.

		Left at six studs because that is where a prompt belongs anyway: head
		height, on its own invisible anchor, which is the pattern the pyramid
		porch and the AFK shelter both already use. If anybody ever wants the
		real answer, the reproduction above is the whole of it.
	]]
	local promptAt = P(exitM, "PromptAnchor", Vector3.new(1, 1, 1),
		CFrame.new(CX, GROUND + 6, EZ - 5), Color3.fromRGB(255, 196, 208),
		Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false, CanTouch = false })
	local leave = Instance.new("ProximityPrompt")
	leave.Name = "LeavePrompt"
	leave.ActionText = "Leave"
	leave.ObjectText = "The Inner Shrine"
	leave.HoldDuration = 0.5
	leave.MaxActivationDistance = 16
	leave.RequiresLineOfSight = false
	leave.Parent = promptAt
	leave.Triggered:Connect(function(plr)
		Shrine.leave(plr)
	end)

	----------------------------------------------------------------
	-- Petals in the air, and the hall's own ambience.
	--
	-- The petals are the one thing tying this room to the island it is
	-- nominally inside: the cove is pink, and a sealed hall with sakura drifting
	-- through it reads as being under those trees rather than in a box 1500
	-- studs away. Emitted from a wide flat host near the ceiling, drifting down.
	----------------------------------------------------------------
	local fx = P(root, "PetalFall", Vector3.new(150, 1, 190),
		CFrame.new(CX, CEIL - 3, (Z0 + ALTAR_Z) * 0.5), PETAL, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false })
	local petals = Instance.new("ParticleEmitter")
	petals.Name = "Petals"
	petals.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	petals.Color = ColorSequence.new(PETAL, Color3.fromRGB(255, 232, 240))
	petals.LightEmission = 0.25
	petals.Rate = 26
	petals.Lifetime = NumberRange.new(6, 11)
	petals.Speed = NumberRange.new(1.5, 3.5)
	petals.SpreadAngle = Vector2.new(28, 28)
	petals.Acceleration = Vector3.new(1.2, -1.6, 0)
	petals.Rotation = NumberRange.new(0, 360)
	petals.RotSpeed = NumberRange.new(-45, 45)
	petals.EmissionDirection = Enum.NormalId.Bottom
	petals.Size = NumberSequence.new(0.85)
	petals.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.12, 0.25),
		NumberSequenceKeypoint.new(0.85, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	petals.Parent = fx

	local amb = Instance.new("Sound")
	amb.Name = "ShrineAmbience"
	amb.SoundId = SND_AMBIENCE
	amb.Looped = true
	amb.Volume = 0.18
	amb.RollOffMaxDistance = 260
	amb.RollOffMode = Enum.RollOffMode.Linear
	amb.Parent = fx
	amb:Play()

	print(string.format("[Shrine] inner hall built: %d offering types, %d parts",
		props, #root:GetDescendants()))

	return pad
end

----------------------------------------------------------------
-- The porch, on the cove
----------------------------------------------------------------
Shrine.ENTRY_NAME = "CoveShrine"

-- The site, on the cove's north shore. The rakeable cove field is z 1404..1596,
-- so this whole complex sits clear of it -- ISLANDS[4].resetAt is 1.0 and that
-- square tolerates no blocked cells either.
local SITE_Y = 3
local SANDO_Z0, SANDO_Z1 = 1628, 1708
local HALL_Z0, HALL_Z1 = 1712, 1786
local HALL_HX = 48

--[[
	SITE PREPARATION, and it is a terrain write on an ADOPTED island, so it is
	deliberately as small as it can be.

	The cove's north shore is flat at y = 3 apart from two grassy mounds sitting
	squarely on the centreline -- one at z 1700..1710 rising to 13, one at
	z 1750..1780 rising to 15 -- and a building cannot stand on either. Only what
	is under the paving and the plinth is levelled: the mound at (30, 1675) and
	the one at (-60, 1735) are outside the footprint and are left exactly as they
	were, which keeps the shore looking sculpted rather than bulldozed.

	Two-step, the same as every other field write in this game: fill to a whole
	voxel boundary, then set the top layer's occupancy, because smooth terrain
	renders its surface at the centre of the first non-full voxel and filling
	"to y = 3" lands at y = 6.
]]
local function prepareSite()
	local COVE = Config.island(4)
	local regions = {
		{ -18, 18, SANDO_Z0 - 6, SANDO_Z1 + 4 },
		{ -HALL_HX - 8, HALL_HX + 8, HALL_Z0 - 6, HALL_Z1 + 8 },
	}
	for _, r in ipairs(regions) do
		local x0, x1, z0, z1 = r[1], r[2], r[3], r[4]
		--[[
			THE AIR FILL HAS TO START AT THE FLOOR, not above it.

			This cleared y 8..80 first time round, which is fine for a mound whose
			top is at 15 and useless for the four studs of it between 4 and 8 --
			so both centreline mounds came back as low stumps and the raycast
			found the site still at 10 where it should have been 3. Smooth terrain
			also renders its surface at the centre of the first non-full voxel, so
			a hard cut at 8 reads a little above 8 and the stub looked taller than
			it was.

			Cleared from the target surface up, filled solid from -30 to it. Not
			from further down: the cove's landmass carries on below and there is no
			reason to punch a hole in it that the sea can see.
		]]
		Terrain:FillBlock(CFrame.new((x0 + x1) * 0.5, 62, (z0 + z1) * 0.5),
			Vector3.new(x1 - x0, 116, z1 - z0), Enum.Material.Air)
		Terrain:FillBlock(CFrame.new((x0 + x1) * 0.5, -13, (z0 + z1) * 0.5),
			Vector3.new(x1 - x0, 34, z1 - z0), COVE.matMessy)

		--[[
			THE ARRAY IS SIZED OFF THE EXPANDED REGION, NOT OFF THE RAW BOUNDS.

			ExpandToGrid pushes a Region3 out to whole voxels, so a region asked
			for as x -18..18 comes back as -20..20 -- ten voxels, not the nine
			(x1 - x0) // 4 predicts -- and WriteVoxels rejects the mismatch with
			"10x1x23 array expected". The tomb's version of this loop gets away
			with the shorthand only because every bound it uses is already a
			multiple of four. Reading the size back off the region cannot drift.
		]]
		local _, o3 = Config.occupancyFor(SITE_Y)
		local region = Region3.new(Vector3.new(x0, 0, z0),
			Vector3.new(x1, Config.VOXEL, z1)):ExpandToGrid(Config.VOXEL)
		local nx = math.floor(region.Size.X / Config.VOXEL + 0.5)
		local ny = math.floor(region.Size.Y / Config.VOXEL + 0.5)
		local nz = math.floor(region.Size.Z / Config.VOXEL + 0.5)
		local mats, occs = table.create(nx), table.create(nx)
		for xi = 1, nx do
			local mx, ox = table.create(ny), table.create(ny)
			mats[xi], occs[xi] = mx, ox
			for yi = 1, ny do
				mx[yi], ox[yi] = table.create(nz), table.create(nz)
				for zi = 1, nz do
					mx[yi][zi], ox[yi][zi] = COVE.matMessy, o3
				end
			end
		end
		Terrain:WriteVoxels(region, Config.VOXEL, mats, occs)
	end
end

--[[
	ANYTHING ALREADY STANDING HERE IS MOVED, NEVER DELETED.

	The cove is hand-built and saved in the place file, so every tree on it is
	somebody's decision. Two props land inside this footprint -- a BeachSet on
	the edge of the paving and one SakuraTree in the middle of the hall -- and
	both are shifted sideways onto clear sand rather than removed, with a line in
	the log saying which and where from. Re-running the build does not move them
	twice: anything already outside the footprint is left alone.
]]
local function clearSite(): number
	local moved = 0
	local function inside(q: Vector3): boolean
		if q.Z >= SANDO_Z0 - 6 and q.Z <= SANDO_Z1 + 4 and math.abs(q.X) <= 18 then
			return true
		end
		return q.Z > HALL_Z0 - 6 and q.Z <= HALL_Z1 + 8 and math.abs(q.X) <= HALL_HX + 8
	end

	local props = workspace:FindFirstChild("Island3")
	props = props and props:FindFirstChild("Props")
	if not props then
		return 0
	end
	for _, child in ipairs(props:GetChildren()) do
		local ok, pivot = pcall(function()
			return child:GetPivot().Position
		end)
		if ok and inside(pivot) then
			-- Straight out to the side, the shorter way, and well clear.
			local push = (pivot.X < 0) and -1 or 1
			local target = Vector3.new(push * (HALL_HX + 26) + (pivot.X - math.floor(pivot.X)),
				pivot.Y, pivot.Z)
			pcall(function()
				child:PivotTo(child:GetPivot() + (target - pivot))
			end)
			warn(string.format("[Shrine] moved %s off the shrine site: %s -> %s",
				child.Name, tostring(pivot), tostring(target)))
			moved += 1
		end
	end
	return moved
end

function Shrine.buildEntrance()
	local existing = workspace:FindFirstChild(Shrine.ENTRY_NAME)
	if existing then
		existing:Destroy()
	end

	prepareSite()
	local moved = clearSite()

	local root = Instance.new("Model")
	root.Name = Shrine.ENTRY_NAME
	root.Parent = workspace

	----------------------------------------------------------------
	-- The approach (sando)
	----------------------------------------------------------------
	local app = Instance.new("Model")
	app.Name = "Approach"
	app.Parent = root

	box(app, "Sando", -13, 13, SITE_Y - 0.6, SITE_Y + 0.35, SANDO_Z0, SANDO_Z1, STONE,
		Enum.Material.Slate)
	for _, sx in ipairs({ -1, 1 }) do
		box(app, "SandoKerb", sx * 13 - 1.2, sx * 13 + 1.2, SITE_Y - 0.6, SITE_Y + 0.75,
			SANDO_Z0, SANDO_Z1, STONE_DARK, Enum.Material.Slate)
	end
	-- Flagging: a cross joint every eight studs, which is what stops eighty
	-- studs of one grey part reading as a road.
	for z = SANDO_Z0 + 8, SANDO_Z1 - 4, 8 do
		trim(app, "SandoJoint", Vector3.new(26, 0.12, 0.5), CFrame.new(0, SITE_Y + 0.42, z),
			STONE_DARK, Enum.Material.Slate)
	end

	-- TWO torii, not one. A single gate is a doorway; a pair is an approach, and
	-- the second one seen through the first is the shot the whole path exists for.
	torii(app, 0, SITE_Y, SANDO_Z0 + 6, 34, 30)
	torii(app, 0, SITE_Y, SANDO_Z0 + 48, 27, 24)

	for _, z in ipairs({ SANDO_Z0 + 26, SANDO_Z0 + 66 }) do
		toro(app, CFrame.new(-19, SITE_Y, z), 1.15)
		toro(app, CFrame.new(19, SITE_Y, z), 1.15)
	end

	-- Nobori banners down the path: tall narrow cloth on a pole, and the one
	-- thing here that moves the eye vertically between the two gates.
	for i, z in ipairs({ SANDO_Z0 + 16, SANDO_Z0 + 36, SANDO_Z0 + 56 }) do
		for _, sx in ipairs({ -1, 1 }) do
			local bx = sx * 16
			trim(app, "NoboriPole", Vector3.new(0.5, 22, 0.5),
				CFrame.new(bx, SITE_Y + 11, z), TIMBER_DARK, Enum.Material.Wood)
			trim(app, "NoboriArm", Vector3.new(4.4, 0.4, 0.4),
				CFrame.new(bx + sx * 2.1, SITE_Y + 21.4, z), TIMBER_DARK, Enum.Material.Wood)
			trim(app, "NoboriCloth", Vector3.new(4, 13, 0.2),
				CFrame.new(bx + sx * 2.1, SITE_Y + 14.6, z),
				(i % 2 == 0) and PAPER or VERMILION, Enum.Material.Fabric)
		end
	end

	-- The water basin (temizuya) beside the path, where you rinse before going up.
	local tz = SANDO_Z0 + 44
	box(app, "ChozuWell", 24, 34, SITE_Y, SITE_Y + 3.6, tz - 5, tz + 5, STONE_DARK,
		Enum.Material.Slate)
	box(app, "ChozuRim", 23.2, 34.8, SITE_Y + 3.6, SITE_Y + 4.4, tz - 5.8, tz + 5.8, STONE,
		Enum.Material.Slate)
	box(app, "ChozuWater", 24.4, 33.6, SITE_Y + 3.9, SITE_Y + 4.1, tz - 4.4, tz + 4.4,
		Color3.fromRGB(150, 214, 226), Enum.Material.Glass,
		{ Transparency = 0.35, CanCollide = false })
	trim(app, "Hishaku", Vector3.new(4.4, 0.35, 0.35), CFrame.new(29, SITE_Y + 4.6, tz - 2),
		TIMBER_LIGHT, Enum.Material.Wood)

	komainu(app, CFrame.new(-17, SITE_Y, SANDO_Z1 - 2) * CFrame.Angles(0, math.rad(200), 0), true, 1.15)
	komainu(app, CFrame.new(17, SITE_Y, SANDO_Z1 - 2) * CFrame.Angles(0, math.rad(160), 0), false, 1.15)

	----------------------------------------------------------------
	-- The hall
	----------------------------------------------------------------
	local hall = Instance.new("Model")
	hall.Name = "Hall"
	hall.Parent = root

	local DECK = SITE_Y + 6          -- the veranda floor
	local WALL_TOP = DECK + 21
	local WX = 42                    -- the walls; the deck runs out to HALL_HX
	local FACE_Z = HALL_Z0 + 6       -- the south wall, the one with the door in it

	-- Plinth and veranda. The deck stands proud of the walls all the way round,
	-- which is the engawa -- and it is what stops the building looking like a box
	-- dropped on a slab.
	box(hall, "Plinth", -HALL_HX, HALL_HX, SITE_Y - 1, DECK - 1, HALL_Z0, HALL_Z1, STONE_DARK,
		Enum.Material.Slate)
	box(hall, "PlinthCap", -HALL_HX - 1.2, HALL_HX + 1.2, DECK - 1.4, DECK - 0.8,
		HALL_Z0 - 1.2, HALL_Z1 + 1.2, STONE, Enum.Material.Slate)
	box(hall, "Deck", -HALL_HX, HALL_HX, DECK - 0.9, DECK, HALL_Z0, HALL_Z1, TIMBER_LIGHT,
		Enum.Material.WoodPlanks)

	-- Steps up, centred on the door.
	for i = 0, 2 do
		box(hall, "Step", -18 + i * 1.5, 18 - i * 1.5, SITE_Y + i * 1.8, SITE_Y + (i + 1) * 1.8,
			HALL_Z0 - 7 + i * 2.2, HALL_Z0, STONE, Enum.Material.Slate)
	end

	-- Balustrade round the veranda, broken for the steps.
	local function rail(x0, x1, z0, z1)
		box(hall, "RailTop", x0, x1, DECK + 3.1, DECK + 3.7, z0, z1, VERMILION_DEEP,
			Enum.Material.Wood)
		box(hall, "RailMid", x0 + 0.15, x1 - 0.15, DECK + 1.6, DECK + 2.1, z0 + 0.15, z1 - 0.15,
			VERMILION, Enum.Material.Wood)
	end
	rail(-HALL_HX, -18, HALL_Z0, HALL_Z0 + 1.2)
	rail(18, HALL_HX, HALL_Z0, HALL_Z0 + 1.2)
	rail(-HALL_HX, HALL_HX, HALL_Z1 - 1.2, HALL_Z1)
	rail(-HALL_HX, -HALL_HX + 1.2, HALL_Z0, HALL_Z1)
	rail(HALL_HX - 1.2, HALL_HX, HALL_Z0, HALL_Z1)

	-- Corner and intermediate pillars, on their own stone pads.
	local pxs = { -WX, -21, 21, WX }
	local pzs = { FACE_Z, HALL_Z1 - 6 }
	for _, px in ipairs(pxs) do
		for _, pz in ipairs(pzs) do
			P(hall, "Pillar", Vector3.new(4.6, 21, 4.6), CFrame.new(px, DECK + 10.5, pz),
				VERMILION, Enum.Material.Wood)
			trim(hall, "PillarFoot", Vector3.new(6, 1, 6), CFrame.new(px, DECK + 0.5, pz),
				STONE_DARK, Enum.Material.Slate)
			trim(hall, "Bracket", Vector3.new(6.6, 1.3, 6.6), CFrame.new(px, WALL_TOP + 0.7, pz),
				TIMBER_LIGHT, Enum.Material.Wood)
		end
	end
	for _, sx in ipairs({ -1, 1 }) do
		P(hall, "Pillar", Vector3.new(4.6, 21, 4.6), CFrame.new(sx * WX, DECK + 10.5, 1749),
			VERMILION, Enum.Material.Wood)
	end

	-- Walls: plaster panels in a dark frame, with the south wall left open where
	-- the doorway goes.
	local function wallPanel(name, x0, x1, z0, z1)
		box(hall, name, x0, x1, DECK, WALL_TOP, z0, z1, PLASTER, Enum.Material.Concrete)
		box(hall, name .. "Dado", x0 - 0.2, x1 + 0.2, DECK, DECK + 5, z0 - 0.2, z1 + 0.2, TIMBER,
			Enum.Material.Wood)
		box(hall, name .. "Head", x0 - 0.3, x1 + 0.3, WALL_TOP - 1.6, WALL_TOP, z0 - 0.3, z1 + 0.3,
			TIMBER_DARK, Enum.Material.Wood)
	end
	local DOOR_HX, DOOR_TOP = 9, DECK + 17
	wallPanel("WallSW", -WX, -DOOR_HX, FACE_Z - 1, FACE_Z + 1)
	wallPanel("WallSE", DOOR_HX, WX, FACE_Z - 1, FACE_Z + 1)
	box(hall, "DoorHead", -DOOR_HX - 1, DOOR_HX + 1, DOOR_TOP, WALL_TOP, FACE_Z - 1.2, FACE_Z + 1.2,
		TIMBER_DARK, Enum.Material.Wood)
	wallPanel("WallN", -WX, WX, HALL_Z1 - 7, HALL_Z1 - 5)
	wallPanel("WallW", -WX - 1, -WX + 1, FACE_Z, HALL_Z1 - 5)
	wallPanel("WallE", WX - 1, WX + 1, FACE_Z, HALL_Z1 - 5)

	-- THE ROOF, and it is the whole silhouette. Deliberately enormous against the
	-- building under it: a Japanese roof overhangs by a third of the hall's width
	-- and that overhang is the thing you recognise from across the island.
	roof(hall, 0, 1749, WALL_TOP + 1, 118, 96, 26, 9)

	-- Lanterns along the eave and either side of the door.
	for _, sx in ipairs({ -1, 1 }) do
		for _, lz in ipairs({ HALL_Z0 + 3, 1749, HALL_Z1 - 3 }) do
			lantern(hall, CFrame.new(sx * (HALL_HX - 3), WALL_TOP + 2, lz),
				Color3.fromRGB(252, 208, 150), 30)
		end
	end

	----------------------------------------------------------------
	-- The door
	----------------------------------------------------------------
	local doorM = Instance.new("Model")
	doorM.Name = "Doors"
	doorM.Parent = root

	shimenawa(doorM, -DOOR_HX - 3, DOOR_HX + 3, DOOR_TOP + 1.2, FACE_Z - 1.8, 1.4)

	--[[
		TWO LEAVES SLIDING APART, not one slab sinking.

		The pyramid's door drops into the floor because it is a sealed tomb and
		there is unlimited room below it. A shrine's doors are a PAIR and they
		slide -- and sliding sideways into the wall also dodges the trap the
		pyramid hit head on, where an 18-stud slab rising into a 28-stud porch
		stood proud of its own roof. There is nothing above these to foul.
	]]
	local leaves = {}
	for _, sx in ipairs({ -1, 1 }) do
		local leaf = P(doorM, "DoorLeaf", Vector3.new(DOOR_HX, DOOR_TOP - DECK, 1.4),
			CFrame.new(sx * DOOR_HX * 0.5, (DECK + DOOR_TOP) * 0.5, FACE_Z), VERMILION,
			Enum.Material.Wood)
		-- Gold studs in three rows, the classic fitting on a shrine door.
		for r = 1, 3 do
			for c = 1, 3 do
				trim(doorM, "DoorStud", Vector3.new(0.9, 0.9, 0.5),
					CFrame.new(sx * DOOR_HX * 0.5 + (c - 2) * 2.6,
						DECK + 3.5 + (r - 1) * 4.4, FACE_Z - 0.9),
					GOLD_DEEP, Enum.Material.Metal, { Reflectance = 0.25 })
			end
		end
		table.insert(leaves, leaf)
	end

	-- Warm light behind the doors, tweened up as they open. This is what sells
	-- the door as leading SOMEWHERE rather than into a black slot.
	local spillPart = P(doorM, "DoorSpill", Vector3.new(1, 1, 1),
		CFrame.new(0, DECK + 8, FACE_Z + 5), GOLD, Enum.Material.Neon,
		{ Transparency = 1, CanCollide = false, CanQuery = false })
	local spill = Instance.new("PointLight")
	spill.Color = Color3.fromRGB(255, 214, 150)
	spill.Range = 32
	spill.Brightness = 0
	spill.Parent = spillPart

	-- Incense drifting out of the opening.
	local smokePart = P(doorM, "DoorIncense", Vector3.new(DOOR_HX * 2, 1, 1),
		CFrame.new(0, DECK + 1, FACE_Z - 1), PLASTER, Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanCollide = false, CanQuery = false })
	local smoke = Instance.new("ParticleEmitter")
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Rate = 0
	smoke.Lifetime = NumberRange.new(2.2, 4.5)
	smoke.Speed = NumberRange.new(1.5, 4)
	smoke.SpreadAngle = Vector2.new(24, 10)
	smoke.Color = ColorSequence.new(Color3.fromRGB(236, 226, 214))
	smoke.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2),
		NumberSequenceKeypoint.new(1, 9),
	})
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.7),
		NumberSequenceKeypoint.new(1, 1),
	})
	smoke.Parent = smokePart

	-- Sounds. The same two the pyramid's slab uses, pitched up: these are timber
	-- doors on a wooden track, not a ton of stone.
	local grind = Instance.new("Sound")
	grind.SoundId = SND_WHOOSH
	grind.Volume = 0.5
	grind.PlaybackSpeed = 1.15
	grind.RollOffMaxDistance = 120
	grind.Parent = leaves[1]
	local refuseSnd = Instance.new("Sound")
	refuseSnd.SoundId = SND_WHOOSH
	refuseSnd.Volume = 0.35
	refuseSnd.PlaybackSpeed = 0.7
	refuseSnd.RollOffMaxDistance = 90
	refuseSnd.Parent = leaves[1]

	-- "Click this" is not discoverable on a pair of doors, least of all on a
	-- phone where there is no hover cursor. Stood well proud of the face for the
	-- reason the pyramid's hint records: at the lintel it is inside the masonry.
	local hint = Instance.new("BillboardGui")
	hint.Name = "DoorHint"
	hint.Size = UDim2.new(0, 250, 0, 58)
	hint.StudsOffsetWorldSpace = Vector3.new(0, (DOOR_TOP - DECK) * 0.5 + 3.5, -7)
	hint.MaxDistance = 100
	hint.Parent = leaves[1]
	local hintLabel = Instance.new("TextLabel")
	hintLabel.Size = UDim2.fromScale(1, 1)
	hintLabel.Text = "TAP TO ENTER"
	hintLabel.Parent = hint
	pcall(function()
		local SignKit = require(ReplicatedStorage.Modules:WaitForChild("SignKit"))
		SignKit.floating(hintLabel, Color3.fromRGB(255, 226, 176))
	end)

	local homeCF = {}
	for _, l in ipairs(leaves) do
		homeCF[l] = l.CFrame
	end
	local SLIDE = DOOR_HX - 0.6
	local DOOR_TIME, DOOR_LEAD, AUTO_CLOSE = 1.5, 0.25, 9
	local isOpen, moving, epoch = false, false, 0

	local function moveAll(open: boolean, info: TweenInfo)
		local last
		for k, l in ipairs(leaves) do
			local dir = (k == 1) and -1 or 1
			last = TweenService:Create(l, info,
				{ CFrame = homeCF[l] + Vector3.new(open and dir * SLIDE or 0, 0, 0) })
			last:Play()
		end
		return last
	end

	local function slide(open: boolean)
		moving = true
		isOpen = open
		hint.Enabled = not open
		if open then
			task.wait(DOOR_LEAD)
			smoke:Emit(40)
			smoke.Rate = 6
			TweenService:Create(spill, TweenInfo.new(1.4), { Brightness = 2.2 }):Play()
		else
			smoke.Rate = 0
			TweenService:Create(spill, TweenInfo.new(1.2), { Brightness = 0 }):Play()
		end
		grind.TimePosition = 0
		grind:Play()
		local tw = moveAll(open, TweenInfo.new(DOOR_TIME, Enum.EasingStyle.Quart,
			open and Enum.EasingDirection.Out or Enum.EasingDirection.InOut))
		tw.Completed:Connect(function()
			moving = false
		end)
		-- A tween that never completes latches `moving` true and the door is dead
		-- for the session -- and TweenService genuinely does stall while the
		-- window is minimised. One unconditional release, well after it should
		-- have landed. Straight out of the pyramid door's notes.
		task.delay(DOOR_TIME + 2, function()
			moving = false
		end)
	end

	-- Refused: the leaves strain against the latch and settle back. A door that
	-- simply does nothing reads as broken, and the player has to be able to tell
	-- "locked" from "bug".
	local function refuse()
		if moving then
			return
		end
		moving = true
		refuseSnd:Play()
		local strain
		for k, l in ipairs(leaves) do
			local dir = (k == 1) and -1 or 1
			strain = TweenService:Create(l, TweenInfo.new(0.13, Enum.EasingStyle.Quad,
				Enum.EasingDirection.Out), { CFrame = homeCF[l] + Vector3.new(dir * 0.5, 0, 0) })
			strain:Play()
		end
		strain.Completed:Connect(function()
			local back = moveAll(false, TweenInfo.new(0.55, Enum.EasingStyle.Elastic,
				Enum.EasingDirection.Out))
			back.Completed:Connect(function()
				moving = false
			end)
		end)
		task.delay(2.5, function()
			moving = false
		end)
	end

	-- Nobody standing in the opening when it closes.
	local function doorwayClear(): boolean
		for _, plr in ipairs(Players:GetPlayers()) do
			local char = plr.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp then
				local d = hrp.Position - Vector3.new(0, DECK + 5, FACE_Z)
				if math.abs(d.X) < DOOR_HX + 3 and math.abs(d.Z) < 9 and math.abs(d.Y) < 14 then
					return false
				end
			end
		end
		return true
	end

	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = 40
	click.Parent = leaves[1]
	local click2 = Instance.new("ClickDetector")
	click2.MaxActivationDistance = 40
	click2.Parent = leaves[2]

	local function onClick(plr)
		if moving or isOpen then
			return
		end
		-- GATED, and checked here on the server off the same Rebirths attribute
		-- ProgressionServer writes. The click is the only entry point and this is
		-- the only place it is answered, so a client cannot talk its way in.
		local have = plr:GetAttribute("Rebirths") or 0
		if have < Shrine.REBIRTHS then
			Net:FireClient(plr, "DoorLocked", Shrine.REBIRTHS, have)
			refuse()
			return
		end
		slide(true)
		-- The doorway is handed over as the shot's SUBJECT: without it the client
		-- has nothing to frame and dollies along wherever the player happens to be
		-- looking. A fixed point, not the leaf -- the leaves are moving.
		Shrine.enter(plr, Vector3.new(0, DECK + 8, FACE_Z))

		epoch += 1
		local mine = epoch
		task.spawn(function()
			task.wait(AUTO_CLOSE)
			while epoch == mine and not doorwayClear() do
				task.wait(2)
			end
			if epoch == mine and isOpen and not moving then
				slide(false)
			end
		end)
	end
	click.MouseClick:Connect(onClick)
	click2.MouseClick:Connect(onClick)

	-- The name board over the doorway.
	pcall(function()
		local SignKit = require(ReplicatedStorage.Modules:WaitForChild("SignKit"))
		-- ON THE DOOR HEAD, under the eave. At WALL_TOP + 2.6 it was inside the
		-- roof's lowest course and the lettering read through half a slab of
		-- slate -- the same trap the pyramid's door hint records, where the hint
		-- spent its whole life buried in the lintel.
		local b = P(hall, "NameBoard", Vector3.new(24, 3.6, 0.5),
			CFrame.new(0, WALL_TOP - 2.4, FACE_Z - 2.2), Color3.fromRGB(46, 38, 34),
			Enum.Material.SmoothPlastic, { CanCollide = false, CanQuery = false })
		SignKit.dress(b, "INNER SHRINE", { Enum.NormalId.Front, Enum.NormalId.Back })
	end)

	--[[
		WHERE LEAVING PUTS THEM: at the foot of the steps, looking up at the hall
		they have just come out of -- the tomb's plaza rule.

		Set here rather than published for CTB_Server to join up, because unlike
		the pyramid both ends of this door live in one module and there is no
		load-order problem to design around.
	]]
	Shrine.returnCF = CFrame.lookAt(
		Vector3.new(0, SITE_Y + 3.5, HALL_Z0 - 20),
		Vector3.new(0, SITE_Y + 3.5, HALL_Z0 + 4))

	print(string.format("[Shrine] cove porch built: %d parts, %d props moved off the site",
		#root:GetDescendants(), moved))

	return root
end

----------------------------------------------------------------
-- The transition
--
-- Both directions of the same fade, written once. The timings are constants
-- shared with the client rather than a handshake: the client fades on its own
-- clock and the server teleports on its own, so a dropped acknowledgement can
-- never leave somebody staring at a black screen.
--
-- IT REUSES THE TOMB'S "Cinema" MESSAGE ON PURPOSE. Vault_Client's handler is
-- already generic -- it takes ("out", caption, kind) / ("in", kind) and knows
-- nothing about which room it is fading into -- so the shrine gets the push-in,
-- the title card and the fade back for nothing. The only vault-specific things
-- over there are its colour grade and its drone, both keyed on that island's
-- id, and neither fires for this one. A grade of its own is the obvious next
-- pass and needs no change here.
----------------------------------------------------------------
local function travel(plr: Player, target: CFrame, caption: string, kind: string)
	local char = plr.Character
	if not char or not char.PrimaryPart then
		return
	end

	Net:FireClient(plr, "Cinema", "out", caption, kind)

	-- Ask for the destination to stream in WHILE the screen is still fading.
	-- StreamingEnabled is on and these two places are 1500+ studs apart, so
	-- without this the fade lifts on an empty void for a second or two.
	task.spawn(function()
		pcall(function()
			plr:RequestStreamAroundAsync(target.Position, 10)
		end)
	end)

	task.delay(Shrine.BEAT + Shrine.FADE, function()
		local c = plr.Character
		if not c or not c.PrimaryPart then
			-- Died or left mid-fade. Lift the screen so they are not stuck in
			-- black -- and as "leave", because there is no arrival to reveal and
			-- the plain fade is the one that also hands the camera straight back.
			Net:FireClient(plr, "Cinema", "in", "leave")
			return
		end
		c:PivotTo(target)
		pcall(function()
			plr:RequestStreamAroundAsync(target.Position, 6)
		end)
		task.wait(Shrine.HOLD)
		Net:FireClient(plr, "Cinema", "in", kind)
	end)
end

-- `subject` is the doorway, handed over as the shot's subject for the client to
-- frame. Not consumed today -- the tomb passes one too and Vault_Client's fade
-- ignores it -- but it is the right thing for the call site to know and costs
-- nothing to keep until the camera work wants it.
function Shrine.enter(plr: Player, subject: Vector3?)
	travel(plr, ENTRY, "THE INNER SHRINE", "enter")
end

function Shrine.leave(plr: Player)
	-- Resolved now, not at load: see the note on FALLBACK_RETURN. Nobody may be
	-- left sealed in a room with no exit, so this always has an answer even if
	-- buildEntrance never ran.
	travel(plr, Shrine.returnCF or FALLBACK_RETURN, "", "leave")
end

return Shrine
