--[[
	SkinPlinthBuilder  --  ServerScriptService.SkinPlinthBuilder

	THE CENTREPIECE IN EACH OF THE THREE ROOMS: a lit stand with that room's
	sifter hanging over it, standing on the walk between the door you arrive at
	and the sand you came to rake.

	WHERE THEY STAND, AND IT IS NOT A TASTE DECISION
	------------------------------------------------
	Every room drops you at its south end facing north up its own axis, and the
	rakeable square starts some way in front of that. The plinth goes in the gap:
	on the axis, ahead of the arrival point, short of the field. You see it the
	instant the fade lifts, and you cannot reach the sand without walking through
	SkinConfig.ClaimRadius of it -- which is the whole reason the claim needs no
	button.

	The Z of each is derived from that room's FIELD EDGE rather than typed as a
	world coordinate, because the one thing that must never happen is a solid
	part standing inside a rakeable square: every island resets at 1.0 now, so a
	single cell nobody can reach means that field never turns over again. Derived
	this way the stands move south with the edge if a room is ever widened.
	`assertClear` re-checks the finished model against the real extents anyway,
	the same belt-and-braces Island3Builder and Island4Builder both use.

	THE GAPS ARE MEASURED, and the survey is why they differ:

		The Tomb        16 studs.  The hall's axis is empty carpet from the
		                doorway (z -112) to the dais (z 88); the nearest
		                anything is a column 78 studs off to the side.
		Inner Shrine     9 studs.  Was the tightest of the three and no longer is.
		                The worship apparatus -- saisen box and suzu bell --
		                occupied z 1410..1418 dead on the axis and the stand was
		                fitted into the 14 clear studs between it and the field
		                edge at 1436. THAT APPARATUS HAS BEEN REMOVED (see
		                ShrineBuilder's note where it used to be built), so the
		                axis is now clear from the entrance to the field. The
		                stand has NOT been moved: z 1420..1434, x 2928..3068 is
		                still surveyed free and still where it stands. There is
		                simply more room in front of it than this figure implies.
		Magma Chamber   16 studs.  Free on the axis from z -1636 to the field
		                edge at -1580; the stalls flanking it stop at x 2968
		                and start again at 3052.

	THE SHOWPIECE IS ITS OWN GEOMETRY, DELIBERATELY
	-----------------------------------------------
	The tool in the player's hands is assembled by CTB_Client.buildSifter, which
	is a client-side model wired into an IK grip, five per-frame part lists and
	six emitters. None of that belongs on a museum stand, so this file builds a
	static replica at 1.4x instead: same basket, same blade, same barrow wheels,
	no moving parts.

	What the two DO share is SkinConfig.pieces -- every colour, material and
	reflectance on both objects comes out of the same table -- so the thing on
	the plinth and the thing you walk away with cannot drift apart in the way
	that actually matters.

	EVERYTHING PER-PLAYER IS LEFT TO THE CLIENT. Whether this skin is claimed is
	a different answer for every person in the room, so the server builds one
	neutral stand and SkinClient tints the ring, drives the hover and hangs the
	label. Nothing here knows who is looking at it.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CTB = ReplicatedStorage:WaitForChild("CTB")
local Config = require(CTB:WaitForChild("Config"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local SkinConfig = require(Modules:WaitForChild("SkinConfig"))
local SkinService = require(script.Parent:WaitForChild("SkinService"))

local SkinPlinthBuilder = {}

-- The tag SkinClient watches. On the MODEL, not on a part: the client wants the
-- whole stand in one handle, and CollectionService fires its added signal as
-- the room streams in, which is the only moment it can be found.
SkinPlinthBuilder.Tag = "CTB_SkinPlinth"

--------------------------------------------------------------------------
-- WHERE
--------------------------------------------------------------------------
-- gap: studs of clear floor between the field's south edge and the middle of
-- the stand. See the survey in the header -- these are measured, not chosen.
local PLACES = {
	{ key = "gilded", folder = "Vault", gap = 16 },
	{ key = "vermilion", folder = "InnerShrine", gap = 9 },
	{ key = "ember", folder = "MagmaChamber", gap = 16 },
	{ key = "icebreaker", folder = "FrozenWreck", gap = 16 },
}

--------------------------------------------------------------------------
-- PARTS
--------------------------------------------------------------------------
local function P(parent: Instance, name: string, size: Vector3, cf: CFrame,
	colour: Color3, material: Enum.Material, extra: { [string]: any }?)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.Size = size
	p.CFrame = cf
	p.Color = colour
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if extra then
		for k, v in extra do
			(p :: any)[k] = v
		end
	end
	-- The shadow rule the island builders' finalSweeps already apply, applied
	-- here rather than left for a later pass: nothing under a stud casts a
	-- shadow worth a pixel, and a surface that is supposed to be emitting light
	-- should not also be painting a hard black one.
	local s = p.Size
	if math.min(s.X, s.Y, s.Z) < 1.0 or p.Material == Enum.Material.Neon or p.Transparency > 0.5 then
		p.CastShadow = false
	end
	p.Parent = parent
	return p
end

-- A part in one of the skin's own colours. The single seam between this file
-- and the tool the player carries.
local function pp(parent: Instance, name: string, size: Vector3, cf: CFrame,
	skin, key: string, extra: { [string]: any }?)
	local piece = skin.pieces[key]
	local p = P(parent, name, size, cf, piece.c, piece.m, extra)
	if piece.r > 0 then
		p.Reflectance = piece.r
	end
	return p
end

-- Stand a Cylinder on its end. A Part cylinder's axis runs along its LOCAL X,
-- which is the same trap CTB_Client's own `UP` exists for.
local UP = CFrame.Angles(0, 0, math.rad(90))

--------------------------------------------------------------------------
-- THE SHOWPIECE
--
-- Built in the tool's own frame and then planted at `pivot`:
--   origin  the wheel axle
--   -Z      forward, where the tines are -- so an unrotated model presents
--           its cutting edge to a player walking up from the south
--   +Y      up from the axle
--------------------------------------------------------------------------
local S = 1.4                                    -- showpiece scale
local DW = 6 * S                                 -- Config.LEVELS[1].width, enlarged
local DHALF = DW * 0.5
local DLEN = 2.4 * S
local DBH = 0.95 * S                             -- basket height
local DFLOOR = -0.3 * S                          -- mesh floor, below the axle
local DBAR = 0.1 * S                             -- wire thickness
local DTINE = 0.75 * S
local DR = Config.ROLLER_RADIUS * S              -- wheel radius
local DGRIP_Y, DGRIP_Z = 2.85 * S, 3.15 * S
local DSPAN = 1.15 * S

local function buildShowpiece(parent: Instance, skin, pivot: CFrame): Model
	local m = Instance.new("Model")
	m.Name = "Display"

	-- What Model:PivotTo turns about. Without a PrimaryPart GetPivot hands back
	-- the bounding-box centre, which for a tool with a long handle is halfway
	-- up the handle -- so the hover would orbit rather than spin.
	local core = P(m, "Core", Vector3.new(0.4, 0.4, 0.4), pivot,
		Color3.new(1, 1, 1), Enum.Material.SmoothPlastic,
		{ Transparency = 1, CanQuery = false, CastShadow = false })
	m.PrimaryPart = core

	local function at(off: CFrame): CFrame
		return pivot * off
	end

	local zFront, zBack = -DLEN * 0.5, DLEN * 0.5
	local rimY = DFLOOR + DBH
	local NOQ = { CanQuery = false }

	-- Mesh floor: crossed wire, because the gaps are the whole idea of a sifter.
	for i = 0, 5 do
		pp(m, "Rib", Vector3.new(DW, DBAR, DBAR),
			at(CFrame.new(0, DFLOOR, zFront + (i / 5) * DLEN)), skin, "mesh", NOQ)
	end
	for i = 0, 9 do
		-- The ember skin lights every third wire, so the floor reads as a grate
		-- with something still glowing under it rather than as dark mesh.
		local key = (skin.charm == "ember" and i % 3 == 0) and "tine" or "mesh"
		pp(m, "Wire", Vector3.new(DBAR, DBAR, DLEN),
			at(CFrame.new(-DHALF + (i / 9) * DW, DFLOOR, 0)), skin, key, NOQ)
	end

	-- Rim all the way round, uprights a side, and a wired back wall.
	for _, z in ipairs({ zFront, zBack }) do
		pp(m, "Rim", Vector3.new(DW, DBAR * 1.7, DBAR * 1.7),
			at(CFrame.new(0, rimY, z)), skin, "frame", NOQ)
	end
	for _, sx in ipairs({ -1, 1 }) do
		pp(m, "Rail", Vector3.new(DBAR * 1.7, DBAR * 1.7, DLEN),
			at(CFrame.new(sx * DHALF, rimY, 0)), skin, "frame", NOQ)
		for i = 0, 3 do
			pp(m, "Upright", Vector3.new(DBAR, DBH, DBAR),
				at(CFrame.new(sx * DHALF, DFLOOR + DBH * 0.5, zFront + (i / 3) * DLEN)),
				skin, "mesh", NOQ)
		end
	end
	for i = 0, 8 do
		pp(m, "BackBar", Vector3.new(DBAR, DBH, DBAR),
			at(CFrame.new(-DHALF + (i / 8) * DW, DFLOOR + DBH * 0.5, zBack)), skin, "mesh", NOQ)
	end

	-- The working edge, and the one place a skin is allowed to light itself.
	pp(m, "Lip", Vector3.new(DW, 0.34 * S, 0.1 * S),
		at(CFrame.new(0, DFLOOR - 0.2 * S, zFront - 0.1 * S) * CFrame.Angles(math.rad(-32), 0, 0)),
		skin, "blade", NOQ)
	for i = 0, 8 do
		pp(m, "Tine", Vector3.new(0.09 * S, 0.09 * S, DTINE),
			at(CFrame.new(-DHALF + (i / 8) * DW, DFLOOR - 0.28 * S, zFront - DTINE * 0.5 - 0.06 * S)
				* CFrame.Angles(math.rad(-22), 0, 0)), skin, "tine", NOQ)
	end

	-- Two barrow wheels, outboard and dead on the axle line.
	local hx = DHALF + 0.3 * S
	for _, sx in ipairs({ -1, 1 }) do
		pp(m, "Tyre", Vector3.new(0.34 * S, DR * 2, DR * 2),
			at(CFrame.new(sx * hx, 0, 0)), skin, "tyre",
			{ Shape = Enum.PartType.Cylinder, CanQuery = false })
		pp(m, "Hub", Vector3.new(0.38 * S, DR * 0.8, DR * 0.8),
			at(CFrame.new(sx * hx, 0, 0)), skin, "hub",
			{ Shape = Enum.PartType.Cylinder, CanQuery = false })
		pp(m, "Spoke", Vector3.new(0.4 * S, DR * 1.6, 0.08 * S),
			at(CFrame.new(sx * hx, 0, 0)), skin, "spoke", NOQ)
	end

	-- Axle and handle. Same triangle the tool solves, at the authored default
	-- grip position: there is no avatar to measure a reach against here.
	pp(m, "Axle", Vector3.new(DW + 0.7 * S, 0.16 * S, 0.16 * S),
		at(CFrame.new()), skin, "steel", { Shape = Enum.PartType.Cylinder, CanQuery = false })
	for _, sx in ipairs({ -1, 1 }) do
		local a = Vector3.new(sx * hx, 0, 0)
		local b = Vector3.new(sx * DSPAN, DGRIP_Y, DGRIP_Z)
		local d = b - a
		pp(m, "HandleRail", Vector3.new(0.22 * S, 0.22 * S, d.Magnitude),
			at(CFrame.lookAt(a + d * 0.5, b)), skin, "steel", NOQ)
	end
	pp(m, "Grip", Vector3.new(3.1 * S, 0.36 * S, 0.36 * S),
		at(CFrame.new(0, DGRIP_Y, DGRIP_Z)), skin, "grip",
		{ Shape = Enum.PartType.Cylinder, CanQuery = false })
	pp(m, "Crossbar", Vector3.new(hx + DSPAN, 0.18 * S, 0.18 * S),
		at(CFrame.new(0, DGRIP_Y * 0.5, DGRIP_Z * 0.5)), skin, "steel",
		{ Shape = Enum.PartType.Cylinder, CanQuery = false })

	--[[
		THE CHARM, and it is not decoration on any of the three.

		The palettes alone would give three recoloured rakes. What makes each
		one read as an OBJECT FROM ITS ROOM is the one fitting nobody would
		bolt to a garden tool: a cartouche, hung paper, or a grate still cooling.
	]]
	if skin.charm == "scarab" then
		-- A cartouche on the back rail: the gilt oval a name goes inside, with
		-- the tomb's lapis at the centre of it.
		pp(m, "Cartouche", Vector3.new(1.5 * S, 0.9 * S, 0.16 * S),
			at(CFrame.new(0, rimY + 0.5 * S, zBack + 0.12 * S)), skin, "frame", NOQ)
		pp(m, "CartoucheEye", Vector3.new(0.62 * S, 0.62 * S, 0.2 * S),
			at(CFrame.new(0, rimY + 0.5 * S, zBack + 0.16 * S)), skin, "grip", NOQ)
		for _, sx in ipairs({ -1, 1 }) do
			-- The winged sun's outstretched half, stepped in three.
			for i = 1, 3 do
				pp(m, "Wing", Vector3.new(0.5 * S, (0.5 - i * 0.11) * S, 0.14 * S),
					at(CFrame.new(sx * (0.95 + i * 0.5) * S, rimY + (0.5 - i * 0.06) * S,
						zBack + 0.12 * S)), skin, "blade", NOQ)
			end
			pp(m, "HubRing", Vector3.new(0.12 * S, DR * 2.3, DR * 2.3),
				at(CFrame.new(sx * (hx + 0.24 * S), 0, 0)), skin, "spoke",
				{ Shape = Enum.PartType.Cylinder, CanQuery = false })
		end

	elseif skin.charm == "shide" then
		-- Shimenawa across the back rail with four shide folded over it. Each
		-- strip is three stepped tiles, which is the zigzag the paper is cut in.
		pp(m, "Shimenawa", Vector3.new(DW * 0.86, 0.34 * S, 0.34 * S),
			at(CFrame.new(0, rimY + 0.42 * S, zBack + 0.1 * S)), skin, "grip",
			{ Shape = Enum.PartType.Cylinder, CanQuery = false })
		for i = 1, 4 do
			local sx = (i - 2.5) / 2 * DW * 0.62
			for j = 0, 2 do
				P(m, "Shide", Vector3.new(0.42 * S, 0.36 * S, 0.05 * S),
					at(CFrame.new(sx + ((j % 2 == 0) and -0.14 or 0.14) * S,
						rimY + (0.16 - j * 0.36) * S, zBack + 0.14 * S)),
					Color3.fromRGB(248, 246, 240), Enum.Material.SmoothPlastic, NOQ)
			end
		end
		-- ...and a suzu on the crossbar, because a shrine object jingles.
		pp(m, "Suzu", Vector3.new(0.46 * S, 0.46 * S, 0.46 * S),
			at(CFrame.new(0, DGRIP_Y * 0.5 - 0.36 * S, DGRIP_Z * 0.5)), skin, "hub",
			{ Shape = Enum.PartType.Ball, CanQuery = false })

	elseif skin.charm == "ember" then
		-- The basket is still holding heat. Three bars of it under the floor,
		-- and a slag crust banked along the back rail.
		for i = -1, 1 do
			pp(m, "Coal", Vector3.new(DW * 0.7, 0.1 * S, 0.34 * S),
				at(CFrame.new(0, DFLOOR - 0.14 * S, i * 0.9 * S)), skin, "blade",
				{ Transparency = 0.25, CanQuery = false })
		end
		for i = 0, 5 do
			pp(m, "Slag", Vector3.new((0.5 + (i % 3) * 0.22) * S, (0.34 + (i % 2) * 0.2) * S, 0.4 * S),
				at(CFrame.new((i - 2.5) * 1.3 * S, rimY + 0.16 * S, zBack - 0.1 * S)
					* CFrame.Angles(0, math.rad(i * 23), math.rad(i * 7))),
				skin, "frame", NOQ)
		end

	elseif skin.charm == "frost" then
		-- Icicles under the front rim and rime along the back rail: the tool
		-- came out of a hull that has been freezing for a lifetime.
		for i = -1, 1 do
			pp(m, "Icicle", Vector3.new(0.2 * S, (0.62 - math.abs(i) * 0.16) * S, 0.2 * S),
				at(CFrame.new(i * DW * 0.28, rimY - 0.42 * S, zFront + 0.04 * S)), skin, "blade",
				{ Transparency = 0.2, CanQuery = false })
		end
		pp(m, "Rime", Vector3.new(DW * 0.8, 0.2 * S, 0.3 * S),
			at(CFrame.new(0, rimY + 0.18 * S, zBack + 0.08 * S)), skin, "tine",
			{ Transparency = 0.15, CanQuery = false })
	end

	m.Parent = parent
	return m
end

--------------------------------------------------------------------------
-- THE STAND
--------------------------------------------------------------------------
local CAP_Y = 3.4           -- top of the drum, above the floor
local HOVER = 4.0           -- the showpiece's axle, above the cap
local TILT = math.rad(-12)  -- handle back, tines toward whoever is walking up

local function dressGilded(root: Instance, base: CFrame, skin)
	-- Two obelisks flanking it, in the tomb's own banded sandstone.
	local SANDSTONE = Color3.fromRGB(226, 180, 112)
	local SAND_DARK = Color3.fromRGB(180, 136, 78)
	local LAPIS = Color3.fromRGB(40, 78, 150)
	for _, sx in ipairs({ -1, 1 }) do
		local x = sx * 7.2
		P(root, "Obelisk", Vector3.new(2.2, 11, 2.2),
			base * CFrame.new(x, 5.5, 0), SANDSTONE, Enum.Material.Sandstone, { CanCollide = true })
		P(root, "ObeliskBand", Vector3.new(2.5, 1.1, 2.5),
			base * CFrame.new(x, 7.4, 0), LAPIS, Enum.Material.SmoothPlastic)
		P(root, "ObeliskCap", Vector3.new(1.8, 2.2, 1.8),
			base * CFrame.new(x, 12.1, 0), skin.tint, Enum.Material.Metal, { Reflectance = 0.3 })
		P(root, "ObeliskFoot", Vector3.new(3.2, 1.0, 3.2),
			base * CFrame.new(x, 0.5, 0), SAND_DARK, Enum.Material.Slate, { CanCollide = true })
	end
	-- A gilt lintel across the two, so the pair frames the piece instead of
	-- standing beside it.
	P(root, "Lintel", Vector3.new(17.6, 1.6, 2.6),
		base * CFrame.new(0, 13.6, 0), SAND_DARK, Enum.Material.Sandstone)
	P(root, "LintelGold", Vector3.new(18.6, 0.9, 3.1),
		base * CFrame.new(0, 14.7, 0), skin.tint, Enum.Material.Metal, { Reflectance = 0.25 })
end

local function dressVermilion(root: Instance, base: CFrame, skin)
	-- A torii straddling the stand. Small -- 13 studs of span against the
	-- room's own 34 -- so it reads as a gateway over an offering rather than as
	-- a second entrance to the hall.
	local TIMBER_DARK = Color3.fromRGB(62, 42, 30)
	local STONE = Color3.fromRGB(168, 164, 156)
	-- POSTS AT 7.5, NOT 6.5. The showpiece is 9.8 studs across its wheels and
	-- the posts are 1.7 thick, so at 6.5 the gateway had 0.7 studs of daylight
	-- either side of the thing it is meant to frame -- which photographs as a
	-- tool wedged into a doorway. 15 studs of span gives it 2.6 a side.
	local H = 12.5
	for _, sx in ipairs({ -1, 1 }) do
		local x = sx * 7.5
		P(root, "ToriiFoot", Vector3.new(2.6, 1.0, 2.6),
			base * CFrame.new(x, 0.5, 0), STONE, Enum.Material.Slate, { CanCollide = true })
		P(root, "ToriiPost", Vector3.new(1.7, H, 1.7),
			base * CFrame.new(x, H * 0.5 + 1, 0), skin.tint, Enum.Material.Wood, { CanCollide = true })
	end
	P(root, "ToriiNuki", Vector3.new(17.4, 1.1, 1.3),
		base * CFrame.new(0, H - 1.4, 0), skin.tint, Enum.Material.Wood)
	P(root, "ToriiShimaki", Vector3.new(19.2, 1.1, 2.0),
		base * CFrame.new(0, H + 1.1, 0), skin.tint, Enum.Material.Wood)
	P(root, "ToriiKasagi", Vector3.new(20.4, 1.3, 2.6),
		base * CFrame.new(0, H + 2.2, 0), TIMBER_DARK, Enum.Material.Wood)
	-- Shimenawa slung between the posts with shide over it, matching the
	-- fitting on the sifter itself.
	P(root, "Shimenawa", Vector3.new(14.6, 0.7, 0.7),
		base * CFrame.new(0, H - 3.4, -1.1), Color3.fromRGB(236, 226, 198), Enum.Material.Fabric)
	for i = 1, 5 do
		local x = (i - 3) * 3.0
		for j = 0, 2 do
			P(root, "Shide", Vector3.new(0.72, 0.62, 0.08),
				base * CFrame.new(x + ((j % 2 == 0) and -0.22 or 0.22), H - 4.1 - j * 0.62, -1.1),
				Color3.fromRGB(248, 246, 240), Enum.Material.SmoothPlastic)
		end
	end
end

local function dressEmber(root: Instance, base: CFrame, skin)
	-- Not a pedestal: an anvil, with the horn a smith would draw over. The
	-- chamber has a forge in it already, and this is the thing that came off it.
	local BASALT = Color3.fromRGB(28, 26, 30)
	P(root, "AnvilHorn", Vector3.new(3.0, 1.5, 5.6),
		base * CFrame.new(0, CAP_Y - 0.5, -5.4), BASALT, Enum.Material.Slate, { CanCollide = true })
	P(root, "AnvilHeel", Vector3.new(4.6, 1.5, 3.0),
		base * CFrame.new(0, CAP_Y - 0.5, 5.2), BASALT, Enum.Material.Slate, { CanCollide = true })
	-- A moat of it round the foot, cracked open. Clinker banked outside each
	-- crack so the light has an edge rather than reading as a lit disc.
	for i = 0, 11 do
		local a = i * math.pi / 6
		P(root, "Crack", Vector3.new(1.3, 0.22, 3.4),
			base * CFrame.new(math.cos(a) * 7.6, 0.16, math.sin(a) * 7.6) * CFrame.Angles(0, -a, 0),
			skin.tint, Enum.Material.Neon, { Transparency = 0.18 })
		P(root, "Clinker", Vector3.new(2.0, 0.7, 2.0),
			base * CFrame.new(math.cos(a + 0.26) * 9.1, 0.35, math.sin(a + 0.26) * 9.1)
				* CFrame.Angles(0, a, math.rad(9)), BASALT, Enum.Material.Slate)
	end
	local foot = root:FindFirstChild("Foot")
	if foot then
		local heat = Instance.new("PointLight")
		heat.Color = skin.tint
		heat.Range = 26
		heat.Brightness = 1.1
		heat.Shadows = false
		heat.Parent = foot
	end
end

local DRESS = { gilded = dressGilded, vermilion = dressVermilion, ember = dressEmber }

--------------------------------------------------------------------------
-- FLOOR
--------------------------------------------------------------------------
--[[
	MEASURED, NOT ASSUMED. `cleanY` is the number a field is WRITTEN at and it
	is not always the number a player's feet are on: ShrineBuilder's BOARD_Y
	note records WoodPlanks rendering a full stud proud of Sand, and the sell
	mat that ignored it spent its whole life buried under the floor. Probed in
	Edit against the two rooms standing there -- the shrine's boards come back
	4.00 and the magma chamber's mud 3.00, off the same cleanY of 3.

	So the stand raycasts. Terrain only, from head height INSIDE the room -- a
	ray from above hits the sealed ceiling -- and it falls back to cleanY if the
	floor is somehow not poured yet.
]]
local function floorAt(x: number, z: number, cleanY: number): number
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Include
	rp.FilterDescendantsInstances = { workspace.Terrain }
	rp.IgnoreWater = true
	local hit = workspace:Raycast(Vector3.new(x, cleanY + 11, z), Vector3.new(0, -22, 0), rp)
	return hit and hit.Position.Y or cleanY
end

--------------------------------------------------------------------------
-- THE FIELD CHECK
--------------------------------------------------------------------------
-- Island3Builder and Island4Builder both carry one of these. It measures real
-- rotated extents rather than centres, because a stand placed 4 studs clear
-- with a 10-stud lintel on it is not clear at all.
local function assertClear(root: Instance, isl): number
	local blocking, first = 0, nil
	for _, p in ipairs(root:GetDescendants()) do
		if p:IsA("BasePart") then
			local cf, s = p.CFrame, p.Size
			local rx, ux, lx = cf.RightVector, cf.UpVector, cf.LookVector
			local ex = math.abs(rx.X) * s.X * 0.5 + math.abs(ux.X) * s.Y * 0.5 + math.abs(lx.X) * s.Z * 0.5
			local ez = math.abs(rx.Z) * s.X * 0.5 + math.abs(ux.Z) * s.Y * 0.5 + math.abs(lx.Z) * s.Z * 0.5
			if math.abs(cf.X - isl.cx) - ex < isl.half and math.abs(cf.Z - isl.cz) - ez < isl.half then
				blocking += 1
				first = first or p:GetFullName()
			end
		end
	end
	if blocking > 0 then
		warn(string.format("[Skins] %d part(s) of the %s stand are INSIDE the rakeable square "
			.. "-- that field can never turn over again. First: %s", blocking, isl.name, first))
	end
	return blocking
end

--------------------------------------------------------------------------
-- BUILD
--------------------------------------------------------------------------
local function buildOne(place): Model?
	local skin = SkinConfig.get(place.key)
	local isl = Config.island(skin.island)
	local room = workspace:FindFirstChild(place.folder)
	if not room then
		warn(string.format("[Skins] no %s in the workspace -- %s has nowhere to stand",
			place.folder, skin.short))
		return nil
	end

	local old = room:FindFirstChild("SkinPlinth")
	if old then
		old:Destroy()
	end

	local x = isl.cx
	local z = isl.cz - isl.half - place.gap
	local y = floorAt(x, z, isl.cleanY)
	local base = CFrame.new(x, y, z)

	local root = Instance.new("Model")
	root.Name = "SkinPlinth"
	-- Read by SkinClient off the tagged model, so it never has to map a
	-- position back to a room.
	root:SetAttribute("SkinKey", skin.key)
	root:SetAttribute("IslandId", skin.island)

	-- The stand itself: a stepped foot, a drum, a cap.
	local DARK = Color3.fromRGB(38, 34, 40)
	P(root, "Foot", Vector3.new(13, 0.9, 13),
		base * CFrame.new(0, 0.45, 0), DARK, Enum.Material.Slate, { CanCollide = true })
	P(root, "Drum", Vector3.new(CAP_Y - 1.2, 8.4, 8.4),
		base * CFrame.new(0, (CAP_Y - 1.2) * 0.5 + 0.9, 0) * UP, DARK, Enum.Material.Slate,
		{ Shape = Enum.PartType.Cylinder, CanCollide = true })
	P(root, "DrumBand", Vector3.new(0.5, 9.0, 9.0),
		base * CFrame.new(0, CAP_Y - 1.1, 0) * UP, skin.tint, Enum.Material.Metal,
		{ Shape = Enum.PartType.Cylinder, Reflectance = 0.2 })
	local cap = P(root, "Cap", Vector3.new(0.6, 9.6, 9.6),
		base * CFrame.new(0, CAP_Y - 0.3, 0) * UP, DARK, Enum.Material.Slate,
		{ Shape = Enum.PartType.Cylinder, CanCollide = true })

	--[[
		THE RING. Sixteen short bars round the cap rather than one lit disc: a
		disc reads as a floor panel, and the client needs individual pieces to
		chase light round the circle during the ceremony anyway.
	]]
	local ring = Instance.new("Model")
	ring.Name = "Ring"
	ring.Parent = root
	for i = 0, 15 do
		local a = i * math.pi / 8
		local p = P(ring, "Rune", Vector3.new(0.5, 0.16, 1.5),
			base * CFrame.new(math.cos(a) * 4.3, CAP_Y + 0.06, math.sin(a) * 4.3)
				* CFrame.Angles(0, -a, 0),
			skin.tint, Enum.Material.Neon, { CanQuery = false })
		p:SetAttribute("Index", i)
	end

	--[[
		The column the piece hangs in. Two sleeves rather than one, so the edge
		falls off instead of ending on a hard cylinder wall.

		0.955 AND 0.978, WHICH LOOK ABSURD AND ARE NOT. Neon ignores lighting,
		so it does not dim with distance or angle the way every other material
		does -- VaultBuilder's skylight note records the finding ("a 0.88
		transparent slab 40 studs wide still reads as solid white paint over
		whatever is behind it") and its own beams sit at 0.945..0.99. These are
		those numbers, and they photograph as a faint column in a lit room and a
		visible shaft in a dark one, which is right for both.

		The shrine USED TO have a red-and-white column on this exact axis that
		was not this: Worship/SuzuRope, the bell rope, hung at (CX, 11..26,
		CZ - 86), thirteen studs in front of the stand, filling the middle of
		any shot taken from the arrival point. It cost one round of chasing a
		transparency bug that was not there. The rope and the box under it have
		since been removed, so a shot down the axis is now this beam and nothing
		else -- which is worth knowing in the other direction: if a red column
		turns up here again, something has been put back.
	]]
	local beam = Instance.new("Model")
	beam.Name = "Beam"
	beam.Parent = root
	for i = 1, 2 do
		P(beam, "Sleeve", Vector3.new(13, 1.4 + i * 1.6, 1.4 + i * 1.6),
			base * CFrame.new(0, CAP_Y + 6.5, 0) * UP, skin.tint, Enum.Material.Neon,
			{ Shape = Enum.PartType.Cylinder, CanQuery = false, Transparency = 0.932 + i * 0.023 })
	end

	-- Where the piece floats, and what lights it. The showpiece is planted
	-- here and the client hovers it about this same point.
	local hover = base * CFrame.new(0, CAP_Y + HOVER, 0)
	local halo = P(root, "Halo", Vector3.new(1, 1, 1), hover,
		Color3.new(1, 1, 1), Enum.Material.Neon,
		{ Transparency = 1, CanQuery = false, CastShadow = false })
	local glow = skin.glow or { c = skin.tint, range = 14, brightness = 1.0 }
	local light = Instance.new("PointLight")
	light.Color = glow.c
	light.Range = math.max(glow.range, 18)
	light.Brightness = glow.brightness + 0.5
	light.Shadows = false
	light.Parent = halo

	-- Motes drifting up out of the cap. Rate is left at a trickle here and
	-- driven by the client, which is the half that knows whether this stand is
	-- still waiting to be claimed.
	local mote = Instance.new("ParticleEmitter")
	mote.Name = "Motes"
	mote.Color = ColorSequence.new(skin.tint)
	mote.LightEmission = 1
	mote.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 0),
	})
	mote.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.25, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	mote.Lifetime = NumberRange.new(1.4, 2.6)
	mote.Speed = NumberRange.new(1.5, 3.5)
	mote.SpreadAngle = Vector2.new(18, 18)
	mote.EmissionDirection = Enum.NormalId.Right   -- the cap is a Cylinder on its end
	mote.Acceleration = Vector3.new(0, 1.2, 0)
	mote.Rate = 6
	mote.Parent = cap

	-- The board. On the -Z face, which is the side the player arrives from in
	-- all three rooms -- a Part's Front IS its -Z, and dressing the wrong face
	-- is the trap ShrineBuilder's own signage note records.
	local plate = P(root, "Plate", Vector3.new(11, 2.4, 0.4),
		base * CFrame.new(0, 1.9, -4.5), DARK, Enum.Material.SmoothPlastic,
		{ CanQuery = false })
	pcall(function()
		local SignKit = require(Modules:WaitForChild("SignKit", 15))
		SignKit.dress(plate, skin.name, { Enum.NormalId.Front }, skin.tint)
	end)

	local dress = DRESS[skin.key]
	if dress then
		dress(root, base, skin)
	end

	-- Last, so the dressing is behind it and the piece is what the eye lands on.
	buildShowpiece(root, skin, hover * CFrame.Angles(TILT, 0, 0))

	root.Parent = room
	CollectionService:AddTag(root, SkinPlinthBuilder.Tag)
	assertClear(root, isl)

	-- The claim point is the FOOT, not the floating piece: the radius is meant
	-- to measure a walk rather than a reach.
	SkinService.registerPlinth(skin.key, skin.island, base.Position)
	return root
end

function SkinPlinthBuilder.buildAll(): number
	local built = 0
	for _, place in ipairs(PLACES) do
		-- One pcall each. A stand that cannot be built costs its own skin and
		-- nothing else -- the room, its field and its sell pad are all already
		-- standing by the time this runs.
		local ok, made = pcall(buildOne, place)
		if ok and made ~= nil then
			built += 1
		elseif not ok then
			warn("[Skins] the " .. place.key .. " stand failed to build: " .. tostring(made))
		end
	end
	print(string.format("[Skins] %d of %d centrepieces standing", built, #PLACES))
	return built
end

return SkinPlinthBuilder
