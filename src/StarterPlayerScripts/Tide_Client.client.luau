--[[
	Tide_Client  --  StarterPlayer.StarterPlayerScripts.Tide_Client

	THE BEACH'S WEATHER: the wave that comes up the sand when a tide turns the
	field over.

	The mechanic was already there. CTB_Server clears the grid once the player
	has raked it, re-seeds the litter, pays `resetBonus` and fires "Tide";
	CTB_Client re-messes the sand and CTB_HUD pops the banner. Every other island
	has had a picture to go with that for as long as it has existed -- the Dunes
	its sandstorm (Island2_Client), Ashfall its eruption (Island4_Client), the
	vault its clearing (Vault_Client) -- and the island the game is NAMED AFTER
	answered its own signature event with one sound effect and a field of rubbish
	reappearing out of nowhere behind the player.

	ITS OWN FILE, for the reason the note over remessField in CTB_Client spells
	out: that chunk sits one statement under Luau's 200-locals-per-function
	ceiling. This was written inside it first and took the whole script over --
	"Out of local registers ... exceeded limit 200", which does not fail at the
	offending line, it stops CTB_Client compiling at all and takes the beach, the
	sifter and the HUD with it. Every other island's weather is a separate client
	script on the same remote anyway, so this is the house pattern, not a dodge.

	IT COMES IN OFF THE SEA. The front is released out on open water, a hundred
	studs past the last rakeable column, and runs in over the shallows before it
	ever touches sand -- so the first thing the player sees is a wave arriving,
	not a wave appearing. It rises as it comes (the height envelope below is the
	same 0..1..0 curve that drives everything else), stands at full height as it
	crosses the beach, and flattens out as it dies away to the south.

	IT RUNS WITH THE LITTER, AND IT HAS TO OVERTAKE IT. remessField staggers the
	junk back from the far edge of the grid to the near one at Config.remessStep
	a row, starting the instant the message lands -- so the far rows are already
	filling in while the wave is still out at sea. Nothing can be done about that
	end: no front that starts on the water can reach the far edge before a stagger
	that starts on the sand. What CAN be arranged is that the wave is IN FRONT of
	the litter line over the part of the beach the player is standing on, which is
	the half that has to read correctly -- litter appearing in the wave's wake,
	not ahead of it.

	SO THE SPEED IS DERIVED, NEVER TYPED: the wave covers the whole run, water to
	the far side of the field, in TIDE_OVERTAKE of the time the stagger takes to
	cross the field alone. That puts the two level at the middle of the beach and
	the wave ahead from there on. Move the stagger and the wave follows it.

	Presentation only. Not networked, decides nothing, and the field is re-messed
	off the same message whether any of this runs or not.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local CTB = ReplicatedStorage:WaitForChild("CTB")
local Config = require(CTB:WaitForChild("Config"))

-- Destroyed and rebuilt, so reloading this script in a live session leaves one
-- wave rather than two stacked on top of each other.
local old = workspace:FindFirstChild("Tide_FX")
if old then
	old:Destroy()
end
local fx = Instance.new("Folder")
fx.Name = "Tide_FX"
fx.Parent = workspace

--------------------------------------------------------------------------
-- WHAT THE WAVE IS MADE OF
--------------------------------------------------------------------------
--[[
	THE WAVE IS GEOMETRY. THE PARTICLES ARE ONLY THE SPRAY ON TOP OF IT.

	This started as two particle layers, the way the Dunes' sandstorm is built,
	and it does not work on this beach. Measured, in this place, at thirty studs:

	  - An OPAQUE RED emitter at rate 700 renders as a solid wall.
	  - The same emitter, same rate, same sizes, in an opaque pale TEAL renders
	    as a faint wash you can read the litter through.

	So it was never density. This place runs Brightness 3.10 + Exposure 0.05 +
	Bloom(0.55, threshold 1.6) -- the numbers Island3_Client's COVE_WATER block
	records for blowing its bay out to a flat white sheet -- and under that
	exposure ANY pale colour lands in the same blown-out band as the sand it is
	drawn on. Foam is white and this sand is nearly white, so a particle wave
	here has no contrast to spend and no edge to show. Turning the rate up only
	chose between invisible and total white-out; there was no setting between.

	Parts do not have that problem. A flat-shaded slab holds its silhouette at
	any distance under any exposure, which is why every other fixture in this
	game is built out of them.
]]
local SHEET_DEPTH = 70                                  -- studs of wet sand behind the front
local SHEET_ALPHA = 0.18
local SHEET_COLOUR = Color3.fromRGB(20, 110, 140)
local LIP_SEGMENTS = 18
local LIP_COLOUR = Color3.fromRGB(252, 255, 255)
local FOAM_TEX = "rbxasset://textures/particles/smoke_main.dds"

--[[
	THE WAVE HAS A FACE NOW, NOT JUST A WATERLINE.

	The first version was a two-stud lip: correct for the last inch of a wash
	running out on flat sand, and it read as a white line painted across the
	beach rather than as water arriving. A wave is a WALL, and the thing that
	makes it one is that it stands well over the player -- an avatar is about five
	and a half studs, and at ten the crest breaks a good four above their head
	with the beach behind it hidden until it passes. That is the whole effect.

	SEVEN AND A HALF WAS THE FIRST HONEST TRY AND IT WAS SHORT. It cleared an
	avatar's head by two studs, which is enough to prove the point on a graph and
	not enough to feel like weather. The face, the crest and the thickness all
	move together: a taller wall on the same 3.4-stud section reads as a sheet of
	card stood on its edge, not as a body of water.

	Two slabs per segment, because a wave is two materials: a deep water FACE
	that leans forward the way a breaking wave does, and an opaque white CREST
	sitting proud on top of it. The face is much darker than the sea it comes out
	of (Terrain.WaterColor is 28,152,180) for the exposure reason in the note
	above -- a vertical wall in the sea's own pale teal comes back white.
]]
local WAVE_H = 10.0                                     -- crest height at full strength
local CREST_H = 2.7
local FACE_D = 4.4                                      -- how thick the wall of water is
local FACE_COLOUR = Color3.fromRGB(18, 104, 134)
local FACE_ALPHA = 0.12
-- Leaning forward, the way a wave does before it breaks. Negative tips the top
-- toward -Z, which is the way the front is travelling.
local FACE_TILT = CFrame.Angles(math.rad(-14), 0, 0)
local SPRAY_H = 11                                      -- the emitter bar riding the face

-- How far out to sea the front is released, past the last rakeable column.
local TIDE_SEA_RUN = 112

-- The fraction of the stagger's crossing time in which the wave covers its
-- whole (longer) run. Under 1 means the wave gains on the litter line; 0.78
-- puts them level at about the middle of the field. See the header.
local TIDE_OVERTAKE = 0.78

-- The front does not stop dead at the last row. It runs on past the near edge
-- and fades as it goes, for the reason the Dunes' storm gives about its own: a
-- front that halts over the player and dissolves on the spot reads as a fog
-- machine being switched off rather than as the sea going back out.
local TIDE_IN, TIDE_RUNOUT = 0.5, 1.4

local function washPart(name: string, parent: Instance): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
	p.CastShadow = false
	p.Transparency = 1                                  -- shown only while a wave is running
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- ONE sheet, never segmented: it is translucent, and overlapping translucent
-- slabs double-blend along every seam -- the trap the HUD's foam line hit,
-- where a row of stadiums at one alpha read as a row of bubbles.
local sheet = washPart("Wash", fx)
sheet.Color = SHEET_COLOUR

-- The wave itself, in OPAQUE segments at jittered depths and heights. A single
-- slab the width of the beach is a ruler; the jitter is the whole difference
-- between a wave and a painted stripe. Sized on release, because the width
-- comes off the field and the field moves -- see the note in startTide.
local lipFolder = Instance.new("Folder")
lipFolder.Name = "Wave"
lipFolder.Parent = fx

local lipSegs = {}
for i = 1, LIP_SEGMENTS do
	local face = washPart("Face", lipFolder)
	face.Color = FACE_COLOUR
	local crest = washPart("Crest", lipFolder)
	crest.Color = LIP_COLOUR
	lipSegs[i] = { face = face, crest = crest, x = 0, dz = 0, h = WAVE_H, w = 8 }
end

-- The spray, at about a fifth of the rate the all-particle version needed. Over
-- geometry that already reads, particles are texture rather than substance --
-- which is the job they are actually good at here.
local sprayBar = washPart("Spray", fx)

local function sprayLayer(props): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Texture = FOAM_TEX
	-- Front is the part's -Z, which is the way the front is travelling, so the
	-- spray is thrown UP THE BEACH ahead of the water rather than back out to sea.
	e.EmissionDirection = Enum.NormalId.Front
	e.Rate = 0
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-30, 30)
	-- LIT, NOT GLOWING. Emission adds light to sand that is already the brightest
	-- thing in the game, which was half of how the first pass whited out.
	e.LightEmission = 0.12
	e.LightInfluence = 0.55
	for k, v in props do
		e[k] = v
	end
	e.Parent = sprayBar
	return e
end

local sprayBody = sprayLayer({
	Color = ColorSequence.new(Color3.fromRGB(248, 253, 255), Color3.fromRGB(146, 203, 217)),
	Size = NumberSequence.new(5, 15),
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.15, 0.34),
		NumberSequenceKeypoint.new(0.68, 0.52),
		NumberSequenceKeypoint.new(1, 1),
	}),
	Lifetime = NumberRange.new(1.1, 2.0),
	Speed = NumberRange.new(6, 14),
	SpreadAngle = Vector2.new(34, 8),
	Acceleration = Vector3.new(0, -3.5, 0),
	Drag = 1.1,
	ZOffset = -2,
})

-- Thinner, faster, whiter, gone in a second: the fling off the top of the lip.
local sprayEdge = sprayLayer({
	Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(210, 238, 246)),
	Size = NumberSequence.new(2.5, 8),
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.18, 0.42),
		NumberSequenceKeypoint.new(1, 1),
	}),
	Lifetime = NumberRange.new(0.5, 1.0),
	Speed = NumberRange.new(30, 60),
	SpreadAngle = Vector2.new(22, 7),
	Drag = 2.3,
	ZOffset = 1,
})

--------------------------------------------------------------------------
-- DRIVING IT
--------------------------------------------------------------------------
local tideT = -1        -- seconds since the wave was released; < 0 = calm

--[[
	THE FIELD IS MEASURED ON EVERY RELEASE, never captured once at load.

	An island row is DERIVED -- Config computes half, cells, x0 and z0 off grid
	and centre -- and it demonstrably moves: the cove's grid went 48 -> 96 and its
	centre 1500 -> 1596 underneath a running session while this was being written.
	A wave that had cached the old field would sweep a strip of open sea while the
	litter came back somewhere else, and that reads as a broken wave rather than
	as a stale number. It is four multiplications, once every few minutes.
]]
local tideStart, tideSpeed, tideGround, tideSeaY = 0, 0, 0, -0.5
local tideHold, tideLen = 0, 0
-- Followed rather than snapped to, so a step in the terrain under the front --
-- and the south slope has a few -- arrives as the wave riding over it instead
-- of as the whole wall jumping. Fast enough to make the shore climb in the
-- half second the wave spends on it.
local tideBase = -0.5
local BASE_FOLLOW = 8

--[[
	One ray a frame, which is what lets the wave climb the beach instead of
	sliding through it: the sand runs from the sea floor up to the field over
	about thirty studs of slope, and a front pinned to either end is buried at one
	and floating at the other. Clamped to the sea surface so the wave rides ON the
	water rather than down on the seabed while it is still out there.

	TERRAIN ONLY, and that is not tidiness. Aimed at everything, the ray catches
	the litter, the deckchairs and the parasols the beach is covered in, and the
	whole wave hops a stud and a half as it passes over a prop -- measured at 4.83
	where the sand is 3.00. A wave climbs the BEACH; it does not climb the
	furniture.
]]
local groundRay = RaycastParams.new()
groundRay.IgnoreWater = true
groundRay.FilterType = Enum.RaycastFilterType.Include
groundRay.FilterDescendantsInstances = { workspace.Terrain }

local function baseAt(x: number, z: number): number
	local hit = workspace:Raycast(Vector3.new(x, 140, z), Vector3.new(0, -300, 0), groundRay)
	if not hit then
		-- Terrain that has not streamed in. Inside the field the answer is known
		-- flat; outside it, assume open water.
		local isl = Config.HOME
		return (math.abs(z - isl.cz) <= isl.half) and tideGround or tideSeaY
	end
	return math.max(hit.Position.Y, tideSeaY)
end

-- 0 .. 1 .. 0. It rises over the run in off the water, holds for the whole
-- crossing, and falls once the wave is past the last column and there is no
-- more litter behind it to leave.
local function tideAmount(t: number): number
	if t < 0 then
		return 0
	elseif t < TIDE_IN then
		return t / TIDE_IN
	elseif t < tideHold then
		return 1
	end
	return math.max(0, 1 - (t - tideHold) / TIDE_RUNOUT)
end

local function hide()
	sprayBody.Rate, sprayEdge.Rate = 0, 0
	sheet.Transparency = 1
	for _, seg in ipairs(lipSegs) do
		seg.face.Transparency = 1
		seg.crest.Transparency = 1
	end
end

local function onHomeBeach(): boolean
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local zone = hrp and Config.zoneAt(hrp.Position) or nil
	return zone ~= nil and zone.id == Config.HOME.id
end

local function startTide()
	-- Already running. The server rate-limits a reset to one per six seconds so
	-- this cannot happen today, but restarting the clock would teleport the front
	-- back out to sea for a frame if it ever could.
	if tideT >= 0 then
		return
	end

	local isl = Config.HOME
	local rows = isl.grid - 1
	local nearZ = Config.cellCentre(isl, 0, 0).Z
	tideGround = isl.cleanY

	-- OUT ON THE WATER, past the last column and past the beach's own slope.
	tideStart = isl.cz + isl.half + TIDE_SEA_RUN

	-- The sea surface, measured rather than assumed -- it is the one height the
	-- wave has to match while it is still out there, and it is not the field's.
	local wetRay = RaycastParams.new()
	wetRay.IgnoreWater = false
	local wet = workspace:Raycast(Vector3.new(isl.cx, 140, tideStart), Vector3.new(0, -300, 0), wetRay)
	tideSeaY = (wet and wet.Material == Enum.Material.Water) and wet.Position.Y or -0.5
	tideBase = tideSeaY               -- released on the water, so this starts true

	-- See the header: the stagger's crossing time is the clock everything is
	-- measured against, and the wave runs its own longer distance inside a
	-- fraction of it so that it gains on the litter line.
	local sweep = rows * Config.remessStep(isl)
	tideHold = sweep * TIDE_OVERTAKE
	tideSpeed = (tideStart - nearZ) / tideHold
	tideLen = tideHold + TIDE_RUNOUT

	-- WIDER THAN THE BEACH, on purpose. The field is 256 across and the water is
	-- another sixty-odd studs past each edge; a wave exactly as wide as the grid
	-- has two visible ends, and a wave with ends is a prop.
	local W = isl.half * 2 + 130
	sheet.Size = Vector3.new(W, 0.4, SHEET_DEPTH)
	sprayBar.Size = Vector3.new(W, SPRAY_H, 10)

	-- TWO SINES OF DIFFERENT PERIOD on both the depth and the height, so the
	-- crest is ragged without repeating on a beat the eye can pick out. Segments
	-- overlap by just over a stud in X: enough that the jitter cannot open a gap,
	-- little enough that the seams do not stack up into bright bars on the fade.
	local segW = W / LIP_SEGMENTS
	for i, seg in ipairs(lipSegs) do
		seg.x = isl.cx - W * 0.5 + segW * (i - 0.5)
		seg.dz = math.sin(i * 1.7) * 2.4 + math.sin(i * 0.6) * 1.2
		seg.h = WAVE_H * (0.88 + 0.12 * math.sin(i * 2.3) + 0.07 * math.sin(i * 1.1))
		seg.w = segW + 1.2
		seg.crest.Size = Vector3.new(segW + 1.8, CREST_H, FACE_D + 1.2)
	end

	tideT = 0
end

RunService.Heartbeat:Connect(function(dt)
	if tideT < 0 then
		return
	end
	tideT += dt
	if tideT >= tideLen then
		tideT = -1
		hide()
		return
	end

	local amount = tideAmount(tideT)
	local front = tideStart - tideSpeed * tideT
	local cx = Config.HOME.cx
	tideBase += (baseAt(cx, front) - tideBase) * math.min(dt * BASE_FOLLOW, 1)
	local base = tideBase

	-- HOW FAR ASHORE THE FRONT IS, 0 on open water and 1 once it is up on the
	-- flat field. It falls out of the same ray as the height, and it is what
	-- keeps the wet sand off the sea: a slab of wet SAND lying on open water,
	-- which is what the first version drew for the first second of every tide,
	-- reads as a bug and not as a wave.
	local ashore = math.clamp((base - tideSeaY) / math.max(0.1, tideGround - tideSeaY), 0, 1)

	-- The wet sand trails the front, and stays on the sand where it belongs.
	sheet.CFrame = CFrame.new(cx, tideGround + 0.15, front + SHEET_DEPTH * 0.5)
	sheet.Transparency = 1 - (1 - SHEET_ALPHA) * amount * ashore

	-- The wave rises with the envelope rather than popping in at full height: it
	-- builds coming in over the water and flattens out as it dies.
	local grow = 0.34 + 0.66 * amount
	for _, seg in ipairs(lipSegs) do
		local h = seg.h * grow
		local z = front + seg.dz
		-- Centred a little under half its height, so the tilt cannot lift the foot
		-- of the wall off the sand.
		seg.face.Size = Vector3.new(seg.w, h, FACE_D)
		seg.face.CFrame = CFrame.new(seg.x, base + h * 0.44, z) * FACE_TILT
		seg.face.Transparency = 1 - (1 - FACE_ALPHA) * amount
		-- The crest sits on top and slightly forward, because the face leans: the
		-- foam belongs on the lip of the wall, not behind it.
		seg.crest.CFrame = CFrame.new(seg.x, base + h * 0.94, z - h * 0.16)
		seg.crest.Transparency = 1 - amount
	end

	-- About 220 live between the two layers, against the ~1,500 the all-particle
	-- version needed to be visible at all. The slabs carry the shape now; these
	-- only have to break its edge up, so the bar rides up the face with it.
	sprayBar.CFrame = CFrame.new(cx, base + WAVE_H * grow * 0.62, front)
	sprayBody.Rate = 130 * amount
	sprayEdge.Rate = 90 * amount
end)

-- Same remote CTB_Client listens on, and keyed off the ISLAND rather than off
-- the word "TIDE", exactly as Island2_Client keys off DUNES.id: this file is
-- the beach's weather, and renaming the event in Config should not silently
-- switch the sea off. Gated on being here, for the reason the Dunes gives --
-- the field comes back either way, and a wave crossing the spawn beach while
-- its owner is up a volcano is a few hundred parts and particles nobody will
-- ever look at.
local net = CTB:WaitForChild("Net")
net.OnClientEvent:Connect(function(action, islandId)
	if action == "Tide" and islandId == Config.HOME.id and onHomeBeach() then
		startTide()
	end
end)

hide()
print(string.format(
	"[Tide] client ready -- a %.1f-stud wave in off the sea, %.2fs from the water to the far side",
	WAVE_H, (Config.HOME.grid - 1) * Config.remessStep(Config.HOME) * TIDE_OVERTAKE))
