--[[
	TutorialGuide  --  StarterPlayerScripts.TutorialGuide  (ModuleScript)

	WHERE TO GO, drawn in the world rather than described in a sentence. Owned
	by TutorialHud, which is the only thing that calls it: TutorialHud decides
	WHICH step the player is on, this file answers WHERE that step happens and
	points at it.

	FOUR SIGNALS, AND EVERY ONE OF THEM ANSWERS A DIFFERENT QUESTION
	---------------------------------------------------------------
	  ping   -- a disc on the ground that pulses outward. "It is exactly here",
	            at the scale of a footstep. The one thing that survives being
	            stood next to.
	  marker -- a billboard floating over it with the step's icon, its one-word
	            name and the distance, with chevrons pointing down at the ping.
	            AlwaysOnTop, so a shop counter behind a wall is still findable.
	  crumbs -- nine dots laid along the ground from the player toward it, each
	            bobbing a beat later than the one behind it so the wave travels
	            AWAY from you. That direction is the whole message; a static
	            dotted line reads as scenery.
	  edge   -- when the target is off screen, a chevron pinned to the screen
	            edge with the distance under it. Without this a player facing
	            the wrong way sees nothing at all and the other three are a
	            secret.

	EVERYTHING IS BUILT ON THE CLIENT AND PARENTED TO WORKSPACE, so it exists
	for this player only -- no remote, no replication, and nothing another
	player can see cluttering their beach.

	FOUR TRAPS, ALL OF WHICH BIT HERE FIRST
	---------------------------------------
	1. THE PARTS MUST BE INVISIBLE TO EVERY SYSTEM, not just intangible.
	   CanCollide = false is not enough: WeightConfig.isCandidate would answer
	   yes to anything that ended up tagged or in Workspace.Trash, and the
	   crumb raycasts below would hit each other. CanQuery and CanTouch are off
	   for that reason, and the folder is deliberately NOT called Trash.

	2. THE EDGE POINTER MUST NOT BE UiFit-SCALED. It is positioned in raw
	   viewport pixels straight out of WorldToViewportPoint, and UiFit's
	   FitRoot multiplies everything inside it by the screen scale -- so on a
	   phone the pointer would sit at 0.6x of where the target actually is.
	   The opt-out is UiFit's own eligibility rule: it only absorbs children
	   whose Size is PURE OFFSET on both axes, so the full-screen container
	   below is sized in SCALE and is left alone. Its art carries a UIScale of
	   its own so it still shrinks on a small screen.

	3. WorldToViewportPoint, NOT WorldToScreenPoint. The gui this draws into
	   is IgnoreGuiInset = true (it has to be -- TutorialHud measures the rail
	   off a frame in another gui that also is), so its origin is the top left
	   of the SCREEN, which is viewport space. WorldToScreenPoint subtracts the
	   topbar and would put the pointer 36px high for the whole session.

	4. A TARGET BEHIND THE CAMERA PROJECTS TO THE WRONG SIDE. Roblox returns a
	   negative Z for it and a point mirrored through the screen centre, so the
	   pointer swings to the opposite edge from the one it should. Negating the
	   offset when Z is negative is the fix, and it is the difference between
	   "turn around" and "go the wrong way".
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local HudKit = require(Modules:WaitForChild("HudKit"))
local UiFit = require(Modules:WaitForChild("UiFit"))

local C, A = HudKit.C, HudKit.A
local player = Players.LocalPlayer

local TutorialGuide = {}

----------------------------------------------------------------
-- DIALS
----------------------------------------------------------------
local FOLDER_NAME = "TutorialGuide"

local LIFT = 8            -- studs the marker floats above the ground
local BOB = 0.85          -- studs the marker rides up and down
local BOB_RATE = 2.1

local PING_R = 2.6        -- studs, the resting disc: about a place to stand
local PING_RATE = 1.15    -- pulses per second

local CRUMBS = 9
local CRUMB_GAP = 7
local CRUMB_NEAR = 8      -- nothing is drawn inside this, it would be underfoot
local CRUMB_R = 0.5
local PATH_EVERY = 0.1    -- seconds between re-laying the path

-- Under this the marker is standing right in front of you and the crumbs and
-- the edge pointer are noise. The ping and the marker stay.
local ARRIVED = 14

local EDGE_MARGIN = 78    -- viewport pixels the pointer keeps off the edge
local EDGE_SIZE = 76

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------
local folder: Folder?
local beacon: Part?
local pingBase: Part?
local pingWave: Part?
local crumbs: { Part } = {}

local marker: BillboardGui?
local markerRoot: Frame?
local markerScale: UIScale?
local markerGlyph: TextLabel?
local markerLabel: TextLabel?
local markerDist: TextLabel?
local chipFace: GuiObject?
local chipSlab: GuiObject?
local markerChevrons: { Frame } = {}

local edgeHolder: Frame?
local edgePointer: Frame?
local edgeChevron: Frame?
local edgeDist: TextLabel?

local render: RBXScriptConnection?
local current = nil       -- the live target, or nil
local pathAt = 0
local groundAtT = 0
local clock = 0
local built = false

-- Reused rather than rebuilt per raycast: a RaycastParams allocation nine times
-- a frame is the kind of garbage that only shows up on a phone.
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

----------------------------------------------------------------
-- THE CHEVRON
----------------------------------------------------------------
--[[
	MOVED TO HudKit, AND THE ARGUMENT FOR MOVING IT IS THE INTERESTING PART.

	This was a local here: forty lines of trigonometry plus the note explaining
	why the obvious build draws an X rather than a V. RebirthUnlockPrompt's
	arrow to the ferry then wanted the same shape, and a second copy of THAT is
	exactly what HudKit and PanelKit exist to stop -- this codebase has already
	paid for three notification systems and five sign styles.

	The reasoning now lives at HudKit.chevron, unchanged. Every call site below
	is untouched, and the retint loops still key off the face pass sitting at
	the higher ZIndex.
]]
local chevron = HudKit.chevron

----------------------------------------------------------------
-- BUILDING
----------------------------------------------------------------
local function part(name: string, size: Vector3, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Shape = shape or Enum.PartType.Ball
	p.Anchored = true
	p.CanCollide = false
	-- See trap 1 in the header. Both of these are load bearing, not tidiness.
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.Locked = true
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = A.sun
	p.Parent = folder
	return p
end

local function buildWorld()
	folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = workspace

	-- A Cylinder Part lies along its X axis, so a disc on the ground is one
	-- turned a quarter about Z with its length as the thickness.
	pingBase = part("PingBase", Vector3.new(0.18, PING_R * 2, PING_R * 2), Enum.PartType.Cylinder)
	pingBase.Transparency = 0.45
	pingWave = part("PingWave", Vector3.new(0.14, PING_R * 2, PING_R * 2), Enum.PartType.Cylinder)
	pingWave.Transparency = 0.6

	beacon = part("Beacon", Vector3.new(0.2, 0.2, 0.2))
	beacon.Transparency = 1

	for i = 1, CRUMBS do
		local c = part("Crumb" .. i, Vector3.new(CRUMB_R * 2, CRUMB_R * 2, CRUMB_R * 2))
		c.Transparency = 0.15
		crumbs[i] = c
	end

	-- THE CHARACTER GOES IN THE FILTER TOO, and re-goes in on every respawn.
	-- The crumb trail is dropped from four studs above the ground along a line
	-- that starts eight studs from the player -- which is inside their own
	-- collision box while they are running -- so without this the first dot
	-- lands on a shoulder and rides along with them.
	local function refilter()
		local keep = { folder }
		if player.Character then
			table.insert(keep, player.Character)
		end
		rayParams.FilterDescendantsInstances = keep
	end
	refilter()
	player.CharacterAdded:Connect(refilter)
end

local MARKER_W, MARKER_H = 168, 214

local function buildMarker()
	marker = Instance.new("BillboardGui")
	marker.Name = "Marker"
	marker.Adornee = beacon
	-- PIXELS, NOT STUDS. A studs-sized billboard shrinks with distance, and
	-- the one moment this has to be readable is the moment the thing it points
	-- at is far enough away that you cannot see it. Size and the UIScale below
	-- are driven TOGETHER at range so it does not sit on the horizon at full
	-- size -- see the note on markerScale in step().
	marker.Size = UDim2.fromOffset(MARKER_W, MARKER_H)
	marker.AlwaysOnTop = true
	marker.LightInfluence = 0
	marker.MaxDistance = 5000
	marker.ResetOnSpawn = false
	marker.Parent = player:WaitForChild("PlayerGui")

	--[[
		TOP LEFT, NOT CENTRED, and that is what makes the shrink look right.

		A UIScale scales a frame's descendants about the frame's OWN TOP LEFT
		CORNER. On a centred root that drags the whole marker up and to the left
		as it shrinks -- forty pixels of drift at range, which reads as the
		marker sliding off the thing it is pointing at. Anchored at the origin
		and with the BillboardGui's Size driven by the same number, the content
		and the box shrink together and the billboard's own centring does the
		rest.
	]]
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.Position = UDim2.fromOffset(0, 0)
	root.Size = UDim2.fromOffset(MARKER_W, MARKER_H)
	root.Parent = marker
	markerRoot = root

	markerScale = Instance.new("UIScale")
	markerScale.Parent = root

	-- The icon, on the step's own colour. One glyph is the fastest thing on
	-- screen to recognise and it needs no language at all.
	local chipHolder, face, slab = HudKit.surface(root, 66, 66, 20, A.sun)
	chipHolder.Name = "Chip"
	chipHolder.AnchorPoint = Vector2.new(0.5, 0)
	chipHolder.Position = UDim2.fromOffset(MARKER_W * 0.5, 0)
	HudKit.gloss(face, 20)
	chipFace, chipSlab = face, slab
	markerGlyph = HudKit.text(face, "", 34, C.text)
	markerGlyph.ZIndex = 12

	markerLabel = HudKit.text(root, "", 24, A.white, Enum.Font.LuckiestGuy)
	markerLabel.Position = UDim2.fromOffset(0, 74)
	markerLabel.Size = UDim2.fromOffset(MARKER_W, 28)
	HudKit.punch(markerLabel, 4)

	markerDist = HudKit.text(root, "", 18, A.sunLight, Enum.Font.GothamBold)
	markerDist.Position = UDim2.fromOffset(0, 102)
	markerDist.Size = UDim2.fromOffset(MARKER_W, 22)
	HudKit.punch(markerDist, 3)

	-- Three of them, pointing DOWN at the ping. The travelling fade is applied
	-- per frame below; a static stack is a decoration, a moving one is an
	-- instruction.
	for i = 1, 3 do
		local ch = chevron(root, 54, A.sun, 4)
		ch.Rotation = 180
		ch.Position = UDim2.fromOffset(MARKER_W * 0.5, 140 + (i - 1) * 26)
		markerChevrons[i] = ch
	end
end

local function buildEdge(gui: ScreenGui)
	-- SIZED IN SCALE ON PURPOSE. See trap 2 in the header: this is UiFit's own
	-- opt-out and the reason the pixel maths below can be taken at face value.
	edgeHolder = Instance.new("Frame")
	edgeHolder.Name = "EdgePointer"
	edgeHolder.BackgroundTransparency = 1
	edgeHolder.Size = UDim2.fromScale(1, 1)
	edgeHolder.ZIndex = 2
	edgeHolder.Visible = false
	edgeHolder.Parent = gui

	edgePointer = Instance.new("Frame")
	edgePointer.Name = "Pointer"
	edgePointer.BackgroundTransparency = 1
	edgePointer.AnchorPoint = Vector2.new(0.5, 0.5)
	edgePointer.Size = UDim2.fromOffset(EDGE_SIZE, EDGE_SIZE)
	edgePointer.Parent = edgeHolder

	-- The art shrinks with the screen even though the POSITION must not.
	local s = Instance.new("UIScale")
	s.Parent = edgePointer
	UiFit.onChanged(function(scale)
		s.Scale = scale
	end)

	edgeChevron = chevron(edgePointer, EDGE_SIZE, A.sun, 4)
	edgeChevron.Position = UDim2.fromScale(0.5, 0.5)

	--[[
		A SIBLING OF THE POINTER RATHER THAN A CHILD OF IT, and placed by step()
		rather than by this layout.

		The pointer spins to face the target, and anything parented to it spins
		too -- so a caption inside it is upside down for half the circle. The
		counter-rotation trick fixes the letters and not the POSITION: the label
		still orbits the arrow, so the number ends up off the side of the screen
		as often as not. Placed independently, a little way back along the same
		ray, it is always inboard of the arrow and always level.
	]]
	edgeDist = HudKit.text(edgeHolder, "", 18, A.white, Enum.Font.LuckiestGuy)
	edgeDist.Name = "Distance"
	edgeDist.AnchorPoint = Vector2.new(0.5, 0.5)
	edgeDist.Size = UDim2.fromOffset(90, 22)
	edgeDist.ZIndex = 8
	HudKit.punch(edgeDist, 4)
	local ds = Instance.new("UIScale")
	ds.Parent = edgeDist
	UiFit.onChanged(function(scale)
		ds.Scale = scale
	end)
end

----------------------------------------------------------------
-- GROUND
----------------------------------------------------------------
-- Down from just ABOVE the point rather than from high overhead, which matters
-- exactly once: the shop counter's anchor is under a roof, and a ray dropped
-- from thirty studs up lands on the roof and puts the whole marker on it.
local function groundAt(pos: Vector3): Vector3
	local hit = workspace:Raycast(pos + Vector3.new(0, 4, 0), Vector3.new(0, -90, 0), rayParams)
	return hit and hit.Position or pos
end

----------------------------------------------------------------
-- THE FRAME
----------------------------------------------------------------
local function rootPart(): BasePart?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return (root and root:IsA("BasePart")) and root or nil
end

-- A wash session takes the camera and the controls, and a screen full of
-- chevrons over a rock you are already standing at is the loudest possible way
-- to be in the way. WashClientController publishes nothing, but its ScreenGui
-- being enabled IS the state -- the same signal TutorialHud reads the intro's
-- curtain off.
local function busy(): boolean
	local pg = player:FindFirstChild("PlayerGui")
	local wash = pg and pg:FindFirstChild("WashHud")
	return wash ~= nil and wash:IsA("ScreenGui") and wash.Enabled
end

local function hideAll()
	if beacon then
		if marker then marker.Enabled = false end
		pingBase.Transparency = 1
		pingWave.Transparency = 1
		for _, c in ipairs(crumbs) do
			c.Transparency = 1
		end
	end
	if edgeHolder then
		edgeHolder.Visible = false
	end
end

local function layPath(from: Vector3, to: Vector3, span: number)
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local dir = (flat.Magnitude > 1e-3) and flat.Unit or Vector3.zero
	for i, crumb in ipairs(crumbs) do
		local along = CRUMB_NEAR + (i - 1) * CRUMB_GAP
		-- Stop short of the target rather than piling up on it: the ping is what
		-- marks the spot and a trail that runs into it reads as one blob.
		if dir == Vector3.zero or along > span - 6 then
			crumb.Transparency = 1
		else
			crumb:PivotTo(CFrame.new(groundAt(from + dir * along) + Vector3.new(0, CRUMB_R + 0.35, 0)))
			crumb.Transparency = 0
		end
	end
end

local function step(dt: number)
	clock += dt

	local target = current
	local root = rootPart()
	if not target or not root or busy() then
		hideAll()
		return
	end

	-- A part-backed target is followed, so a marker on something that moves --
	-- or on a prompt anchor a builder repositions on boot -- never drifts.
	local pos = target.position
	if target.part and target.part.Parent then
		pos = target.part.Position
	end
	if not pos then
		hideAll()
		return
	end

	-- Re-dropped on a timer rather than per frame: it is one raycast, but it is
	-- one raycast for a number that only changes when the target does.
	local ground = target.ground
	if not ground or clock - groundAtT >= PATH_EVERY then
		groundAtT = clock
		ground = groundAt(pos)
		target.ground = ground
	end

	local here = root.Position
	local span = (Vector3.new(here.X, 0, here.Z) - Vector3.new(ground.X, 0, ground.Z)).Magnitude

	----------------------------------------------------------------
	-- The ping
	----------------------------------------------------------------
	local spin = CFrame.Angles(0, 0, math.rad(90))
	pingBase.CFrame = CFrame.new(ground + Vector3.new(0, 0.12, 0)) * spin
	pingBase.Transparency = 0.45

	-- One pulse, restarting: grows out from the disc and fades as it goes, so
	-- the eye is drawn INWARD to where it started.
	local wave = (clock * PING_RATE) % 1
	local waveR = PING_R * (1 + wave * 1.9)
	pingWave.Size = Vector3.new(0.14, waveR * 2, waveR * 2)
	pingWave.CFrame = CFrame.new(ground + Vector3.new(0, 0.1, 0)) * spin
	pingWave.Transparency = 0.35 + wave * 0.65

	----------------------------------------------------------------
	-- The marker
	----------------------------------------------------------------
	beacon.CFrame = CFrame.new(ground + Vector3.new(0, LIFT + math.sin(clock * BOB_RATE) * BOB, 0))
	marker.Enabled = true
	markerDist.Text = string.format("%dm", math.max(1, math.floor(span + 0.5)))

	-- Full size up close, a little under two thirds at range. Not smaller: the
	-- distance line is the thing being read at range and it has to survive.
	-- BOTH of these, always together -- see the note on markerRoot's anchor.
	local s = math.clamp(1 - (span - 20) / 260, 0.62, 1)
	markerScale.Scale = s
	marker.Size = UDim2.fromOffset(MARKER_W * s, MARKER_H * s)

	-- The fade travels DOWN the stack, toward the ground.
	for i, ch in ipairs(markerChevrons) do
		local phase = (clock * 1.5 - (i - 1) * 0.22) % 1
		for _, limb in ipairs(ch:GetChildren()) do
			if limb:IsA("Frame") then
				limb.BackgroundTransparency = 0.15 + 0.55 * phase
			end
		end
	end

	----------------------------------------------------------------
	-- The crumbs
	----------------------------------------------------------------
	if span <= ARRIVED then
		for _, c in ipairs(crumbs) do
			c.Transparency = 1
		end
	else
		if clock - pathAt >= PATH_EVERY then
			pathAt = clock
			layPath(here, ground, span)
		end
		-- The wave runs from the player OUTWARD, which is the direction the
		-- whole trail is trying to say. A wave running the other way reads,
		-- unmistakably, as "come back".
		for i, crumb in ipairs(crumbs) do
			if crumb.Transparency < 1 then
				local phase = math.sin(clock * 4.4 - (i - 1) * 0.7)
				crumb.Transparency = 0.12 + 0.42 * (0.5 - phase * 0.5)
			end
		end
	end

	----------------------------------------------------------------
	-- The edge pointer
	----------------------------------------------------------------
	local cam = workspace.CurrentCamera
	if not cam then
		edgeHolder.Visible = false
		return
	end

	--[[
		AIMED AT THE GROUND, NOT AT THE MARKER FLOATING OVER IT.

		The marker rides eight studs up, and from twenty studs away eight studs
		up is most of the way to the top of the screen -- so an edge pointer
		measured off the marker fires while the shop counter it is pointing at
		fills the middle of the view. "It is behind you" printed over the thing
		itself is the one way this can actively mislead.

		Plus two, because the ground point at the very bottom of a doorway is
		still effectively off screen when you are stood on top of it.
	]]
	local aim = ground + Vector3.new(0, 2, 0)
	local screen = cam:WorldToViewportPoint(aim)   -- see trap 3
	local vp = cam.ViewportSize
	local cx, cy = vp.X * 0.5, vp.Y * 0.5
	local dx, dy = screen.X - cx, screen.Y - cy
	if screen.Z < 0 then
		dx, dy = -dx, -dy                          -- see trap 4
	end

	local limX = math.max(1, cx - EDGE_MARGIN)
	local limY = math.max(1, cy - EDGE_MARGIN)
	-- How far along the ray from the centre the screen edge is. Below 1 the
	-- target is outside the safe rect, which is the whole test.
	local reach = math.min(limX / math.max(math.abs(dx), 1e-3),
		limY / math.max(math.abs(dy), 1e-3))
	local off = (screen.Z < 0) or reach < 1

	if off and span > ARRIVED then
		edgeHolder.Visible = true
		edgePointer.Position = UDim2.fromOffset(cx + dx * reach, cy + dy * reach)
		-- The art points UP at zero, so a target due right (+x) wants a quarter
		-- turn clockwise -- hence the +90.
		edgePointer.Rotation = math.deg(math.atan2(dy, dx)) + 90
		-- Back along the same ray, so the number is always on the inboard side of
		-- the arrow whichever edge it has pinned itself to.
		local back = math.max(0, reach - EDGE_SIZE / math.max(math.sqrt(dx * dx + dy * dy), 1e-3))
		edgeDist.Position = UDim2.fromOffset(cx + dx * back, cy + dy * back)
		edgeDist.Text = string.format("%dm", math.max(1, math.floor(span + 0.5)))
	else
		edgeHolder.Visible = false
	end
end

----------------------------------------------------------------
-- PUBLIC
----------------------------------------------------------------
--[[
	The gui is BORROWED, not owned: TutorialHud's ScreenGui is already up,
	already IgnoreGuiInset and already the thing the intro sweeps off screen, so
	a second one here would be a second thing to remember in both places.
]]
function TutorialGuide.attach(gui: ScreenGui)
	if built then
		return
	end
	built = true
	buildWorld()
	buildMarker()
	buildEdge(gui)
	hideAll()
end

--[[
	POINT AT SOMETHING, or at nothing.

	target = { part = BasePart?, position = Vector3?, label = string,
	           glyph = string, tint = Color3 }

	`part` wins when it is given and still parented, so a marker follows what it
	is on; `position` is the fallback and the only option for a place rather
	than a thing -- "the sand", which is not an instance.
]]
function TutorialGuide.point(target)
	if not built then
		return
	end
	current = target
	if not target then
		hideAll()
		return
	end

	-- Forced, so the first frame after a step change is already correct rather
	-- than one PATH_EVERY behind on the old target's ground.
	target.ground = nil
	pathAt = -math.huge

	local tint = target.tint or A.sun
	markerGlyph.Text = target.glyph or ""
	markerLabel.Text = target.label or ""
	-- regrad and NOT BackgroundColor3, for the reason HudKit.bar spells out:
	-- surface() has already been through grad(), which leaves the base white so
	-- the gradient stops are the colour you get. Writing the background here
	-- would multiply the tint against itself.
	HudKit.regrad(chipFace, tint, HudKit.darken(tint, 0.24))
	chipSlab.BackgroundColor3 = HudKit.darken(tint, 0.5)
	for _, ch in ipairs(markerChevrons) do
		for _, limb in ipairs(ch:GetChildren()) do
			-- The face pass is the one at the higher ZIndex; the outline stays ink.
			if limb:IsA("Frame") and limb.ZIndex >= 5 then
				limb.BackgroundColor3 = tint
			end
		end
	end
	for _, limb in ipairs(edgeChevron:GetChildren()) do
		if limb:IsA("Frame") and limb.ZIndex >= 5 then
			limb.BackgroundColor3 = tint
		end
	end
	pingBase.Color = tint
	pingWave.Color = tint
	for _, c in ipairs(crumbs) do
		c.Color = tint
	end

	if not render then
		-- RenderStepped, not Heartbeat: the edge pointer is placed off the
		-- camera, and a frame of lag on it shows up as the arrow swimming
		-- behind the view every time the player turns.
		render = RunService.RenderStepped:Connect(function(dt)
			local ok, err = pcall(step, dt)
			if not ok then
				warn("[CleanTheBeach] tutorial guide stopped: " .. tostring(err))
				TutorialGuide.stop()
			end
		end)
	end
end

function TutorialGuide.clear()
	current = nil
	hideAll()
end

-- Everything, including the parts. The tutorial runs once and then this is dead
-- weight in Workspace for the rest of the session.
function TutorialGuide.stop()
	current = nil
	if render then
		render:Disconnect()
		render = nil
	end
	if marker then
		marker:Destroy()
		marker = nil
		markerRoot, markerScale, markerGlyph, markerLabel, markerDist = nil, nil, nil, nil, nil
		chipFace, chipSlab = nil, nil
	end
	if edgeHolder then
		edgeHolder:Destroy()
		edgeHolder = nil
		edgePointer, edgeChevron, edgeDist = nil, nil, nil
	end
	if folder then
		folder:Destroy()
		folder = nil
	end
	table.clear(crumbs)
	table.clear(markerChevrons)
	beacon, pingBase, pingWave = nil, nil, nil
	built = false
end

return TutorialGuide
