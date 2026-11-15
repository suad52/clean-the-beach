--[[
	IntroCinema  --  StarterPlayerScripts.IntroCinema

	The opening shot. The player's own avatar walks the tideline dragging the
	sifter, something gold turns over in the sand, and the screen cuts to the
	title.

	IT IS THE REAL AVATAR AND THE REAL TOOL, which is the whole reason to do this
	in-engine rather than as a video. The first thing a player sees is THEIR hat,
	THEIR shirt, THEIR sifter -- and the shot is a promise about the loop they are
	about to play, made with the actual loop. A pre-rendered intro cannot do that
	and a generic dummy actively works against it.

	NOTHING HERE IS AUTHORITATIVE. Delete this file and the game is exactly what
	it was: no remote is fired, no cell is raked, no item is granted, nothing is
	saved. The coin is a client-side prop that exists for four seconds. Every path
	out of the sequence -- finished, skipped, errored, respawned -- goes through
	one finish(), and there is a hard timer behind it, because a cinematic that
	never ends is the worst failure this file can have.

	WHY IT IS STAGED ON THE WEST SHORE AND NOT WHERE THEY SPAWN
	-----------------------------------------------------------
	Two reasons, and the second is the load-bearing one.

	The spawn pad looks inland: the sell hut and the shop are behind it and the
	sea is three hundred studs the other way, so a camera there frames a hut. The
	west shore has the waterline, the palms and the loungers in one shot.

	And it is OUTSIDE THE RAKEABLE FIELD (the beach's is +-128 on both axes; this
	runs at x = -196). Walking the sifter across the field would rake real cells,
	fire real Clean messages at the server, and pop real items -- which means a
	RevealPopup card sliding up over the title. The intro must not be able to
	touch the save.

	STREAMING IS WHY THE SCREEN IS BLACK BEFORE ANYTHING MOVES
	----------------------------------------------------------
	StreamingEnabled is on, so at join the client does not have the west shore's
	terrain yet -- and a raycast into terrain that has not arrived returns nil,
	which would seat the avatar and the coin at a fallback height and play the
	whole shot in mid-air. The character IS the streaming focus, so the order has
	to be: black screen, move them, WAIT for the ground to answer a ray, and only
	then fade up. The blackout is doing real work, not just setting a mood.

	IT IS THE SECOND HALF OF A JOIN, NOT THE FIRST
	----------------------------------------------
	ReplicatedFirst.IntroClient already owns the first few seconds: it takes
	Roblox's loading screen down, draws the splash and the progress bar, and waits
	on the things this place builds at runtime -- terrain, the bay, ~650 surface
	marks. This file must not put a single frame on screen before that has
	finished, or the player watches a black rectangle instead of a progress bar --
	and the two would take the camera off each other every frame.

	So they hand over through two attributes on the LocalPlayer, the same way every
	other cross-script signal in this place is passed:

		CTB_WorldReady    set by IntroClient  -- the beach exists, you may start
		CTB_IntroCovered  set here            -- my black is up, take yours down

	IntroClient skips its own camera reveal when it sees the second one and falls
	back to it when it does not, so deleting this file leaves a working join rather
	than a broken one.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Debris = game:GetService("Debris")
-- Only for CharacterWalkSpeed, and only as the last-resort fallback in finish().
-- Reading the place's own authored default beats typing a number that is right
-- today -- which is the mistake finish() itself used to make.
local StarterPlayer = game:GetService("StarterPlayer")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local PanelKit = require(Modules:WaitForChild("PanelKit"))
local AudioKit = require(Modules:WaitForChild("AudioKit"))
--[[
	For the three LOOPING animations on the title card below.

	This card is the one place in the game where the setting cannot be known in
	time: it is built during the join, before the profile carrying
	Set_ReducedMotion has arrived, so a plain `if Motion.reduced()` here would
	always read false. Motion.loop is what makes it work anyway -- the loops are
	registered, and cancelled the moment the answer lands, which for a card that
	holds for several seconds is most of its life.
]]
local Motion = require(Modules:WaitForChild("Motion"))

local C = PanelKit.C
local player = Players.LocalPlayer

local IntroCinema = {}

----------------------------------------------------------------
-- Where it is shot
----------------------------------------------------------------

--[[
	THE TIDELINE ON THE WEST SHORE -- and it is TEN STUDS FURTHER OUT than it
	was, with the camera moved to the other side of the walker. Both were faults
	you could see, and both were invisible to the obvious test.

	THE ROCK. `Beach > Rock` sits at (-190, 3, 6) and is 9 x 5 x 10, so it spans
	x -196..-183 and z -1..13. The walk line WAS x -196: the walker went through
	its western face for most of the walk. It is `CanCollide = false`, so nothing
	stopped them, and it is `CanQuery = false`, so no raycast and no
	GetPartBoundsInBox ever reported it. **A visual-obstruction audit cannot use
	spatial queries** -- scenery is deliberately excluded from them. Iterate the
	parts and test the boxes by hand.

	THE PALM. The grove runs x -193..-136 with canopies up to 43 studs across,
	sitting at y 18-35. The old wide shot flew from (SHORE_X+40) to (SHORE_X+31)
	at y 12.5 down to 6.6 -- which is inside that grove. The lens was in a canopy
	for the whole of the opening shot.

	THE FIX IS THE STAGING, not the shot list. Measured: every prop on this shore
	sits at x >= -196, and the seaward side is empty sand all the way to the
	water. So the walk moved to -206 (ten clear studs off the rock, ground flat
	to within half a stud) and the camera moved to the SEAWARD side. Nothing can
	get between the lens and the subject because there is nothing there -- and
	the grove stops being an obstruction and becomes the backdrop, lit from
	behind the camera by the 17:00 sun.
]]
local SHORE_X = -206
local WALK_FROM_Z = 11
local WALK_TO_Z = -16
local WALK_SPEED = 6.2               -- a working pace, not a stroll and not a jog

--[[
	How far in front of the player the find sits, and it is measured off the TOOL
	rather than off them.

	Config.ROLLER_DIST puts the sifter's CENTRE 4.6 studs ahead, which is what the
	first pass measured against -- and it is the wrong number. Measured across all
	67 parts of the real tool, the basket and its tines reach from 1.27 to 7.22
	studs along the player's facing. So a coin at two and a half studs was rising
	inside the basket, behind the mesh and the avatar's own legs, and from the
	hero camera the find was hidden behind the thing that found it.

	10.5 puts it three and a quarter studs clear of the furthest tine: open sand,
	nothing between it and the camera, and the tool and the player who pushed it
	standing behind the find rather than over it. It is also simply where a sifter
	would have turned something up -- ahead of the tines, not under them.
]]
local COIN_AHEAD = 10.5

--[[
	THE TOOL IS CLAMPED FOR THE SHOT, AND A ROCK IS WHY.

	The sifter being pushed is THEIRS -- their skin, their colours -- and that
	is the promise this opening makes. Its WIDTH cannot be part of that
	promise, because the ladder runs from 5.5 studs at level 0 to 48.5 at
	level 60 (ProgressionConfig's RollerWidth track) and the beach it is
	staged on is a fixed piece of ground.

	`Beach.Props.Rock` stands beside the top of the walk. MEASURE IT AS A
	ROTATED BOX -- it is yawed 40.9 degrees, so its Size reads 9.49 x 10.17 and
	its real footprint is x -196.42..-182.59, z -0.67..13.23. Taking Size at
	face value puts its west corner two and a quarter studs further inland than
	it is, which is exactly the margin an audit would then think it had.

	The tool measures w + 1.1 across (its axle overhangs the basket by 0.55 a
	side), so its inland edge lands at SHORE_X + (w + 1.1)/2 and the gap to the
	rock is 10.42 studs. At the starting 6 the edge is x -202.4 and there is six
	studs of daylight; anything past about 19.7 touches; at 48.5 the edge is
	x -181.2, which is not near the rock -- it is through it and out the far side.

	MOVING THE WALK SEAWARD CANNOT FIX IT. Clearing 48.5 studs of tool needs
	SHORE_X below -221, and the sand there measures about y 1.0 against a
	waterline at roughly x -228: the shot would be filmed in the surf.

	14 leaves the inland edge at x -198.45, two studs clear, and it is already
	more tool than the tracking shot can comfortably hold from nine studs out.
	A player under it sees their own tool exactly; a player over it sees a
	smaller one for twelve seconds and their real one the moment the curtain
	lifts.
]]
local INTRO_MAX_WIDTH = 14

--[[
	THE COIN LIES FLAT AND IS DRAWN ON ITS EDGE, WHICH IS THE WHOLE BUG.

	The mesh is 1.785 x 0.329 x 1.785 at hero scale -- a disc, thin on Y -- so
	burying it half a stud down was plenty. Then the render loop tilts it 74
	degrees to catch the light, and a tilted disc is 1.81 studs TALL: its
	vertical half-extent goes from 0.16 to 0.90. Buried at a flat -0.5 it stood
	six tenths of a stud proud of the sand for the five and a half seconds it
	is supposed to be hidden in it, which is what a player sees as "the coin
	starts half out of the ground".

	So the burial is MEASURED off the part and the tilt rather than picked, and
	the rise is measured off the burial -- `coinDrop + COIN_SETTLE` -- so the
	coin still comes to rest exactly where it always did no matter how deep it
	started. Re-scale the mesh or change the tilt and this follows.
]]
local COIN_LIFT = 0.28               -- coinBase sits this far above the sand
local COIN_TILT = math.rad(74)       -- how far off flat it is drawn
local COIN_SETTLE = 1.35             -- where it hangs, above coinBase
local COIN_UNDER = 0.15              -- clearly under the surface, not flush with it

-- Golden hour for the length of the shot, through LightingLock's own API rather
-- than by writing ClockTime (which that script would immediately undo -- see its
-- header). Eased back to noon under the title card, so the game the player is
-- handed is the game's real daylight and the intro is the exception.
local GOLDEN_HOUR = 17
local HOME_HOUR = 12

-- Where they are put back. The screen is fully black when this happens, which is
-- the entire reason the walk can be staged two hundred studs from the spawn pad.
local SPAWN_FALLBACK = Vector3.new(0, 6, -139)

----------------------------------------------------------------
-- The beats
--
-- One clock for the whole sequence, in seconds from the first visible frame.
-- Camera, coin, sound and captions are all functions of it, so retiming a beat
-- is moving one number here rather than chasing four task.delays that agreed
-- with each other yesterday.
----------------------------------------------------------------
-- Twelve and a half seconds, and it is short on purpose: the loading screen has
-- already had three or four of them before this starts, and the number that
-- actually matters is how long a first-time player waits before they are holding
-- the tool. Every beat below is the shortest length that still reads.
local T_FADE_UP   = 0.8              -- black lifts off the opening frame
local T_TRACK     = 2.4              -- cut from the wide to the tracking shot
local T_STOP      = 4.6              -- they stop walking
local T_GLINT     = 5.0              -- something catches the light in the sand
local T_RISE      = 5.6              -- the coin comes up out of it
local T_CLOSE     = 7.0              -- push in to the hero close-up
local T_FLASH     = 8.2              -- gold blows out the frame
local T_BLACK     = 8.45             -- hard cut
local T_TITLE     = 9.1              -- the card lands on a screen already black
local T_SHINE     = 9.55             -- light sweeps across the letters
local T_LIFT      = 11.6             -- title out, world in
local T_DONE      = 12.4

-- Skipping is allowed almost immediately. A player who has seen this twice must
-- never feel held; the only reason it is not zero is that a key still down from
-- the loading screen would eat the intro before its first frame.
local SKIP_AFTER = 1.0

local SPARK_TEX = "rbxasset://textures/particles/sparkles_main.dds"
local SAND_TEX = "rbxasset://textures/particles/smoke_main.dds"

-- Every HUD that gets out of the way, ToastKit included. RebirthCinema keeps
-- toasts up on purpose -- its server message is worth reading -- but nothing
-- that can arrive in the first fifteen seconds of a session is worth a banner
-- across the title card.
local HIDE = {
	"CleanTheBeachHUD", "InventoryHud", "BeachMenuHud", "WeightHUD",
	"FeedbackHud", "RevealPopup", "SiftHud", "DriveHud", "ToastKit",
	-- The event countdown. Nothing that is ten minutes away is worth a pill over
	-- the title card -- and it is a READOUT, so unlike ToastKit there is nothing
	-- in it the player would be sorry to have missed.
	"EventHud",
	"BoostHud",
	-- TutorialHud waits this shot out on its own (it watches this gui), so it
	-- should never be up in the first place. Listed anyway: the sweep is what
	-- makes "nothing but the shot is on screen" true regardless of who forgets.
	"TutorialHud",
}

----------------------------------------------------------------
-- State
----------------------------------------------------------------
local gui, curtain, flash, barTop, barBottom, backdrop
local card, title, titleShadow, shine, shineGrad, rule, sub, skipHint

-- Fade a label AND its outline together, always both. These are ink-outlined at
-- 7px, so on the shadow copy the stroke IS most of the silhouette: moving
-- TextTransparency on its own leaves a hollow black wordmark hanging behind the
-- gold one. Going through here means no call site can hold one and forget the
-- other, which is exactly how a black outlined "Ready" once sat dead centre on
-- the loading screen for four and a half seconds.
local function setAlpha(l: TextLabel, a: number)
	l.TextTransparency = a
	local st = l:FindFirstChildOfClass("UIStroke")
	if st then
		st.Transparency = a
	end
end
local fx: Folder? = nil
local coin: BasePart? = nil
-- How far below coinBase the coin waits. Set from the real part once it is
-- built; the default is only what a coin that failed to build would use.
local coinDrop = 0.5
-- The player's real tool width while the shot is borrowing the attribute.
local heldWidth: number? = nil
local widthConn: RBXScriptConnection? = nil

local running = false
local guard = 0
-- How far up/down the shore THIS shot is staged, in studs -- see
-- laneOffset() below. Recomputed at the top of every run(), so a fresh join
-- always starts from the true value rather than compounding onto whatever
-- the last run left behind.
local laneZ = 0
local conns = {}
local hidden = {}
local controlsModule, controlsWanted = nil, true

local function track(conn)
	table.insert(conns, conn)
	return conn
end

local function dropConns()
	for _, c in ipairs(conns) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(conns)
end

----------------------------------------------------------------
-- Small maths
----------------------------------------------------------------

local function clamp01(x: number): number
	return x < 0 and 0 or (x > 1 and 1 or x)
end

-- Smoothstep. Every move in the shot uses it: a camera that starts and stops
-- dead is the single loudest tell that a shot was keyframed by hand.
local function ease(x: number): number
	x = clamp01(x)
	return x * x * (3 - 2 * x)
end

local function lerpV(a: Vector3, b: Vector3, t: number): Vector3
	return a + (b - a) * t
end

----------------------------------------------------------------
-- Ground
--
-- Terrain only, and water is ignored: the shot is staged on wet sand near the
-- waterline and a ray that stopped at the sea surface would float the coin.
----------------------------------------------------------------
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace.Terrain }
groundParams.IgnoreWater = true

local function groundY(x: number, z: number): number?
	local hit = workspace:Raycast(Vector3.new(x, 120, z), Vector3.new(0, -240, 0), groundParams)
	return hit and hit.Position.Y or nil
end

-- The handshake with the loading screen. Nothing here raises so much as a black
-- frame until IntroClient says the world it has been covering is built.
-- Ceilinged, because a signal that never arrives must cost the shot and not the
-- session.
local function waitForWorld(seconds: number): boolean
	if player:GetAttribute("CTB_WorldReady") == true then
		return true
	end
	local deadline = os.clock() + seconds
	repeat
		task.wait(0.1)
	until player:GetAttribute("CTB_WorldReady") == true or os.clock() > deadline
	return player:GetAttribute("CTB_WorldReady") == true
end

-- Terrain collision is rebuilt a frame or so behind the voxels arriving, and
-- with streaming the voxels themselves arrive when they arrive. Both are the
-- same wait from here: keep asking until the ground answers.
local function waitForShore(seconds: number): boolean
	local deadline = os.clock() + seconds
	repeat
		if groundY(SHORE_X, WALK_FROM_Z + laneZ) and groundY(SHORE_X, WALK_TO_Z + laneZ) then
			return true
		end
		task.wait(0.1)
	until os.clock() > deadline
	return false
end

-- TWO PEOPLE JOINING AT THE SAME INSTANT USED TO BE STAGED IN THE SAME SPOT.
-- Both are the real avatar and both are network-owned by their own client, so
-- neither could see or defer to the other, and they walked the shoot standing
-- inside one another the whole time.
--
-- Fixed without a remote: every client already has the same `Players:GetPlayers()`
-- list by the time this runs (waitForWorld above costs several seconds, which is
-- long past when a joining Player instance replicates), so ranking that list by
-- UserId gives every client the SAME order for the SAME people without asking the
-- server to referee it. Rank fans out from the centre lane, alternating sides, and
-- wraps at LANE_COUNT so a crowded server still lands within the verified-clear
-- stretch of sand (measured flat, empty and CanQuery to +-100 studs of SHORE_X
-- along Z). Solo, the list is one long, the rank is always 0, and laneZ is 0 --
-- exactly the shot as it was before this existed.
local LANE_SPACING = 12
local LANE_COUNT = 16
local function laneOffset(): number
	local ids = {}
	for _, p in ipairs(Players:GetPlayers()) do
		table.insert(ids, p.UserId)
	end
	table.sort(ids)
	local rank = 0
	for i, id in ipairs(ids) do
		if id == player.UserId then
			rank = i - 1
			break
		end
	end
	rank %= LANE_COUNT
	local half = math.ceil(rank / 2)
	local sign = (rank % 2 == 1) and -1 or 1
	return sign * half * LANE_SPACING
end

----------------------------------------------------------------
-- Particles
--
-- Deliberately a copy of CTB_Client's sandBurst/sparkBurst rather than a call
-- into them: those are locals inside a 2900-line LocalScript, and reaching them
-- would mean exporting a surface from the file that owns the whole sifter for
-- the sake of two puffs. They are fifteen lines each.
----------------------------------------------------------------

local function holder(pos: Vector3): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.new(0.2, 0.2, 0.2)
	p.CFrame = CFrame.new(pos)
	p.Parent = fx
	return p
end

local function sandPuff(pos: Vector3, count: number)
	local p = holder(pos)
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = SAND_TEX
	pe.Color = ColorSequence.new(Color3.fromRGB(240, 220, 176), Color3.fromRGB(206, 178, 132))
	pe.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(0.4, 1.8),
		NumberSequenceKeypoint.new(1, 2.6),
	})
	pe.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(0.6, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	pe.Lifetime = NumberRange.new(0.35, 0.8)
	pe.Speed = NumberRange.new(4, 11)
	pe.SpreadAngle = Vector2.new(52, 52)
	pe.Acceleration = Vector3.new(0, -24, 0)
	pe.Rotation = NumberRange.new(0, 360)
	pe.RotSpeed = NumberRange.new(-120, 120)
	pe.Rate = 0
	pe.LightEmission = 0.25
	pe.Parent = p
	pe:Emit(count)
	Debris:AddItem(p, 1.4)
end

local function sparkPuff(pos: Vector3, count: number, colour: Color3, speed: number)
	local p = holder(pos)
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = SPARK_TEX
	pe.Color = ColorSequence.new(colour)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
	pe.Lifetime = NumberRange.new(0.4, 0.95)
	pe.Speed = NumberRange.new(speed * 0.4, speed)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Acceleration = Vector3.new(0, -14, 0)
	pe.Rate = 0
	pe.LightEmission = 1
	pe.Parent = p
	pe:Emit(count)
	Debris:AddItem(p, 2.2)
end

----------------------------------------------------------------
-- The coin
--
-- The game's own Gold Coin mesh, scaled up to hero size. A cylinder stands in if
-- the asset is ever renamed: a missing prop must cost the shot its subject, not
-- throw inside a boot script and take the rest of the client's start() calls
-- down with it.
----------------------------------------------------------------

--[[
	A LOCAL WRITE, ON PURPOSE.

	CTB_Client rebuilds the tool off `player:GetAttribute("RollerWidth")` and
	nothing else, so overriding it here is a change that never leaves this
	client: the server's own copy is untouched, and the raking sweep -- which
	this sequence does not run at all -- is measured server-side off a value
	this never sees.

	HELD, NOT SET ONCE. ProgressionServer's applyAll lands on join and
	SaveService calls it again when the profile arrives; both write this
	attribute and both can fall INSIDE these twelve seconds. So the clamp
	watches and re-applies. Writing the clamp cannot re-enter, because the
	guard only fires on a value above it.
]]
local function narrowSifter()
	local function apply()
		local w = player:GetAttribute("RollerWidth")
		if type(w) == "number" and w > INTRO_MAX_WIDTH then
			heldWidth = w
			player:SetAttribute("RollerWidth", INTRO_MAX_WIDTH)
		end
	end
	apply()
	widthConn = player:GetAttributeChangedSignal("RollerWidth"):Connect(apply)
end

-- Disconnect BEFORE writing back, or the watcher above sees the real width
-- arrive and clamps it straight down again.
local function restoreSifter()
	if widthConn then
		widthConn:Disconnect()
		widthConn = nil
	end
	if heldWidth then
		player:SetAttribute("RollerWidth", heldWidth)
		heldWidth = nil
	end
end

-- The coin's VERTICAL half-extent as it is actually drawn. The tilt is about
-- the part's own X, so local Y contributes cos(tilt) and local Z sin(tilt);
-- local X is horizontal at every spin angle and contributes nothing.
local function coinHalfHeight(part: BasePart): number
	return 0.5 * (part.Size.Y * math.abs(math.cos(COIN_TILT))
		+ part.Size.Z * math.abs(math.sin(COIN_TILT)))
end

local function buildCoin(at: Vector3): BasePart
	-- RECURSIVE, because the item assets are not flat: every entry under
	-- Assets.Items is a folder of CONDITION variants (Coin.Clean."Gold Coin"),
	-- and only some of them have more than one. Reaching for the mesh by a fixed
	-- path found nothing and fell through to the cylinder below without saying
	-- so -- which is the failure mode a silent fallback always has.
	local items = ReplicatedStorage:FindFirstChild("Assets")
	items = items and items:FindFirstChild("Items")
	local folder = items and items:FindFirstChild("Coin")
	local src = folder and folder:FindFirstChild("Gold Coin", true)

	local p
	if src and src:IsA("BasePart") then
		p = src:Clone()
		p.Size = src.Size * 2.1
	else
		p = Instance.new("Part")
		p.Shape = Enum.PartType.Cylinder
		p.Size = Vector3.new(0.3, 1.8, 1.8)
	end

	p.Name = "IntroCoin"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Color = Color3.fromRGB(255, 198, 62)
	-- Metal over the asset's SmoothPlastic, and a little reflectance with it. The
	-- camera orbits this thing for a second and a half at arm's length and the
	-- only story in that shot is the light moving across it.
	p.Material = Enum.Material.Metal
	p.Reflectance = 0.22
	p.CFrame = CFrame.new(at)
	p.Parent = fx

	local light = Instance.new("PointLight")
	light.Name = "Glow"
	light.Color = Color3.fromRGB(255, 208, 110)
	light.Range = 12
	light.Brightness = 0
	light.Shadows = false
	light.Parent = p

	local dust = Instance.new("ParticleEmitter")
	dust.Name = "Dust"
	dust.Texture = SPARK_TEX
	dust.Color = ColorSequence.new(Color3.fromRGB(255, 226, 150))
	dust.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 0) })
	dust.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	dust.Lifetime = NumberRange.new(0.5, 1.1)
	dust.Speed = NumberRange.new(0.4, 1.4)
	dust.SpreadAngle = Vector2.new(180, 180)
	dust.Acceleration = Vector3.new(0, 1.2, 0)
	dust.Rate = 0
	dust.LightEmission = 1
	dust.Parent = p

	return p
end

----------------------------------------------------------------
-- The screen
----------------------------------------------------------------

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "IntroCinema"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	-- Above RebirthCinema's 240 and the vault's 200. Neither can physically be
	-- running in the first fifteen seconds of a session, but "above everything"
	-- is one less thing to be wrong about later.
	gui.DisplayOrder = 260
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- OFF UNTIL IT IS WANTED. This is built at client boot, while the loading
	-- screen is still counting terrain in, and an enabled ScreenGui at
	-- DisplayOrder 260 with an opaque curtain would sit on top of that screen for
	-- the whole build -- the player would watch black instead of a progress bar.
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Opens OPAQUE. The first frame of the session is black on purpose: it hides
	-- the spawn, the walk out to the shore, and the wait for terrain to stream.
	curtain = Instance.new("Frame")
	curtain.Name = "Curtain"
	curtain.Size = UDim2.fromScale(1, 1)
	curtain.BackgroundColor3 = Color3.fromRGB(6, 5, 9)
	curtain.BackgroundTransparency = 0
	curtain.BorderSizePixel = 0
	curtain.ZIndex = 10
	curtain.Parent = gui

	-- The gold blowout on the cut. Separate from the curtain so the two can
	-- overlap -- white peaks while black is already coming in under it, which is
	-- what makes the cut feel like a cut rather than a dissolve.
	flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = Color3.fromRGB(255, 244, 214)
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.ZIndex = 11
	flash.Parent = gui

	local function bar(name: string, anchor: Vector2, pos: UDim2)
		local f = Instance.new("Frame")
		f.Name = name
		f.AnchorPoint = anchor
		f.Position = pos
		f.Size = UDim2.fromScale(1, 0)
		f.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		f.BorderSizePixel = 0
		f.ZIndex = 9
		f.Parent = gui
		return f
	end
	barTop = bar("BarTop", Vector2.new(0, 0), UDim2.fromScale(0, 0))
	barBottom = bar("BarBottom", Vector2.new(0, 1), UDim2.fromScale(0, 1))

	----------------------------------------------------------------
	-- The title backdrop
	--
	-- Golden hour behind the wordmark, drawn in the same flat shapes as the
	-- loading screen, so the two screens a player sees before they have touched
	-- anything read as one set rather than as two people's work. No image assets
	-- here either -- see IntroClient for why that rule exists.
	--
	-- IT IS A CANVASGROUP, and that is what makes it affordable. Transparency is
	-- not inherited in Roblox GUI -- a frame at BackgroundTransparency 1 still
	-- draws every child at full opacity -- so fading sixty-odd frames up and back
	-- down otherwise means walking the subtree twice and tweening each thing's
	-- own property. GroupTransparency is one number for the lot.
	--
	-- It goes up at T_TITLE and NOT BEFORE. The cut at T_BLACK has to stay black:
	-- a title that lands after a beat of nothing is an announcement, and that
	-- beat is the whole reason the card lands at all.
	----------------------------------------------------------------
	local TITLE_Y = 0.4                 -- what the wordmark is centred on
	-- Low and slim. This is a title card, not the loading screen: the shoreline
	-- is here to give the sky something to sit on, and the moment it is thick
	-- enough to be a subject it starts competing with the wordmark for the eye.
	local HORIZON, SHORE = 0.85, 0.95
	local SUN_CORE = Color3.fromRGB(255, 249, 224)
	local FOAM = Color3.fromRGB(238, 253, 255)

	backdrop = Instance.new("CanvasGroup")
	backdrop.Name = "TitleBackdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundTransparency = 1
	backdrop.GroupTransparency = 1
	backdrop.Visible = false
	backdrop.ZIndex = 11
	backdrop.Parent = gui

	-- Everything in here is born WHITE, because a UIGradient multiplies against
	-- the fill underneath it and two colours tint each other into mud. PanelKit's
	-- own note above `outline` records what that cost the HUD, and the loading
	-- screen lost an entire sunset to it before anybody noticed.
	local function bd(name: string, z: number, parent: Instance?): Frame
		local f = Instance.new("Frame")
		f.Name = name
		f.BackgroundColor3 = C.white
		f.BorderSizePixel = 0
		f.ZIndex = z
		f.Parent = parent or backdrop
		return f
	end

	local function pill(f: GuiObject)
		local x = Instance.new("UICorner")
		x.CornerRadius = UDim.new(1, 0)
		x.Parent = f
	end

	local function grad(host: GuiObject, rot: number, cols: ColorSequence, alpha: NumberSequence?)
		local g = Instance.new("UIGradient")
		g.Rotation = rot
		g.Color = cols
		if alpha then
			g.Transparency = alpha
		end
		g.Parent = host
		return g
	end

	local sky = bd("Sky", 1)
	sky.Size = UDim2.fromScale(1, 1)
	grad(sky, 90, ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(44, 100, 172)),
		ColorSequenceKeypoint.new(0.32, Color3.fromRGB(112, 170, 218)),
		ColorSequenceKeypoint.new(0.6, Color3.fromRGB(255, 172, 118)),
		ColorSequenceKeypoint.new(0.82, Color3.fromRGB(255, 216, 144)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 228, 168)),
	}))

	-- Sunburst. Nine frames rather than eighteen: each one is a DIAMETER through
	-- the centre, so it draws a spoke on both sides. The container is what turns,
	-- which is one tween for the whole star instead of nine that would have to
	-- stay in step with each other for the length of the card.
	local rays = bd("Rays", 2)
	rays.BackgroundTransparency = 1
	rays.AnchorPoint = Vector2.new(0.5, 0.5)
	rays.Position = UDim2.fromScale(0.5, TITLE_Y)
	rays.Size = UDim2.fromScale(1, 1)
	for i = 0, 8 do
		local spoke = bd("Spoke", 1, rays)
		spoke.AnchorPoint = Vector2.new(0.5, 0.5)
		spoke.Position = UDim2.fromScale(0.5, 0.5)
		-- Width in SCALE off the full-screen container, so the spokes still reach
		-- the corners of a monitor nobody tested this on.
		spoke.Size = UDim2.new(2.6, 0, 0, ({ 40, 20, 28 })[i % 3 + 1])
		-- WARM WHITE, NOT GOLD. Gold at 0.9 over the blue at the top of the sky
		-- averages to a dirty grey-brown, and nine of those read as smears on the
		-- player's screen rather than as light. Near-white only ever lightens
		-- whatever it crosses, which is what a shaft of light does.
		spoke.BackgroundColor3 = SUN_CORE
		spoke.BackgroundTransparency = 0.78
		spoke.Rotation = i * 20
		-- And they dissolve toward the tips rather than running off the edge of
		-- the screen at full strength, which is the other half of reading as light
		-- rather than as nine painted stripes.
		grad(spoke, 0, ColorSequence.new(C.white), NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.34, 1),
			NumberSequenceKeypoint.new(0.44, 0.35),
			NumberSequenceKeypoint.new(0.5, 0.2),
			NumberSequenceKeypoint.new(0.56, 0.35),
			NumberSequenceKeypoint.new(0.66, 1),
			NumberSequenceKeypoint.new(1, 1),
		}))
	end
	-- Two minutes for a full turn, which is slow enough to read as light rather
	-- than as movement -- and is exactly the kind of thing that gets left running
	-- because nobody notices it. The rays stay drawn; they stop turning.
	Motion.loop(
		TweenService:Create(rays, TweenInfo.new(120, Enum.EasingStyle.Linear,
			Enum.EasingDirection.Out, -1), { Rotation = 360 }),
		function()
			rays.Rotation = 0
		end)

	-- The bloom the wordmark sits on. Thirteen faint discs rather than four thick
	-- ones: stacked translucent circles BAND as soon as there are few enough to
	-- count, and composited alpha is 1 - product(1 - a), so many faint layers
	-- reach the same brightness in the middle with no edge anywhere.
	local bloom = bd("Bloom", 3)
	bloom.BackgroundTransparency = 1
	bloom.AnchorPoint = Vector2.new(0.5, 0.5)
	bloom.Position = UDim2.fromScale(0.5, TITLE_Y)
	bloom.Size = UDim2.fromOffset(0, 0)
	for i = 13, 1, -1 do
		local r = math.round(52 * (1 + i * 0.42))
		local disc = bd("Halo" .. i, 1, bloom)
		disc.AnchorPoint = Vector2.new(0.5, 0.5)
		disc.Position = UDim2.fromScale(0.5, 0.5)
		disc.Size = UDim2.fromOffset(r * 2, r * 2)
		disc.BackgroundColor3 = C.sun
		disc.BackgroundTransparency = 0.88 + i * 0.008
		pill(disc)
	end
	local bloomScale = Instance.new("UIScale")
	bloomScale.Parent = bloom
	Motion.loop(
		TweenService:Create(bloomScale, TweenInfo.new(4.2, Enum.EasingStyle.Sine,
			Enum.EasingDirection.InOut, -1, true), { Scale = 1.07 }),
		function()
			bloomScale.Scale = 1
		end)

	-- Motes, { x, y, diameter }. Reversing tweens rather than spawned loops on
	-- purpose: this gui is disabled and re-enabled rather than destroyed, and a
	-- `while` loop left running on it outlives the shot it was written for.
	for i, m in ipairs({
		{ 0.13, 0.3, 10 }, { 0.21, 0.62, 6 }, { 0.32, 0.16, 8 }, { 0.71, 0.24, 7 },
		{ 0.79, 0.55, 11 }, { 0.88, 0.36, 6 }, { 0.62, 0.7, 8 },
	}) do
		local mote = bd("Mote", 4)
		mote.AnchorPoint = Vector2.new(0.5, 0.5)
		mote.Position = UDim2.fromScale(m[1], m[2])
		mote.Size = UDim2.fromOffset(m[3], m[3])
		mote.BackgroundColor3 = SUN_CORE
		-- Faint. At 0.45 the smaller ones stopped reading as motes and started
		-- reading as dead pixels, which is not a thought a title card wants.
		mote.BackgroundTransparency = 0.62
		pill(mote)
		-- The rest closure captures where this mote started, so a stopped drift
		-- puts it back on its mark rather than freezing it part-way up.
		local home = mote.Position
		Motion.loop(
			TweenService:Create(mote, TweenInfo.new(3.4 + i * 0.45, Enum.EasingStyle.Sine,
				Enum.EasingDirection.InOut, -1, true),
				{ Position = home - UDim2.fromScale(0, 0.035) }),
			function()
				mote.Position = home
			end)
	end

	local sea = bd("Sea", 5)
	sea.AnchorPoint = Vector2.new(0.5, 0)
	sea.Position = UDim2.fromScale(0.5, HORIZON)
	sea.Size = UDim2.fromScale(1, SHORE - HORIZON)
	sea.ClipsDescendants = true
	grad(sea, 90, ColorSequence.new({
		-- Lighter at the top: water directly under the horizon is reflecting the
		-- lit sky, and without that the sea abuts the sunset as a flat stripe.
		ColorSequenceKeypoint.new(0, Color3.fromRGB(154, 214, 202)),
		ColorSequenceKeypoint.new(0.45, Color3.fromRGB(56, 152, 180)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(20, 88, 126)),
	}))

	-- The light on the water, on the bloom's own axis. A soft column that fades
	-- out at its edges, not a stack of dashes: a tapered stack of rungs reads as
	-- a ladder down to the sun whatever it happens to be made of.
	local path = bd("SunPath", 1, sea)
	path.AnchorPoint = Vector2.new(0.5, 0)
	path.Position = UDim2.fromScale(0.5, 0)
	path.Size = UDim2.new(0, 300, 1, 0)
	grad(path, 0, ColorSequence.new(SUN_CORE), NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.84),
		NumberSequenceKeypoint.new(0.5, 0.45),
		NumberSequenceKeypoint.new(0.8, 0.84),
		NumberSequenceKeypoint.new(1, 1),
	}))

	local horizonLine = bd("Horizon", 7)
	horizonLine.AnchorPoint = Vector2.new(0.5, 0.5)
	horizonLine.Position = UDim2.fromScale(0.5, HORIZON)
	horizonLine.Size = UDim2.new(1, 0, 0, 3)
	horizonLine.BackgroundColor3 = SUN_CORE
	horizonLine.BackgroundTransparency = 0.5

	local shore = bd("Shore", 6)
	shore.AnchorPoint = Vector2.new(0.5, 1)
	shore.Position = UDim2.fromScale(0.5, 1)
	shore.Size = UDim2.fromScale(1, 1 - SHORE)
	grad(shore, 90, ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(202, 168, 116)),
		ColorSequenceKeypoint.new(0.35, Color3.fromRGB(252, 228, 178)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(228, 194, 138)),
	}))

	-- Straight waterline, scalloped underside. NEARLY OPAQUE on purpose:
	-- overlapping translucent shapes blend twice where they meet, so a row of
	-- them at any real alpha stops reading as foam and starts reading as a line
	-- of bubbles -- the eye picks out the overlaps instead of the shape.
	local wash = bd("Wash", 2, shore)
	wash.BackgroundTransparency = 1
	wash.AnchorPoint = Vector2.new(0.5, 0)
	wash.Position = UDim2.fromScale(0.5, 0)
	wash.Size = UDim2.fromScale(1, 0)
	local waterline = bd("Waterline", 1, wash)
	waterline.AnchorPoint = Vector2.new(0.5, 0.5)
	waterline.Position = UDim2.fromScale(0.5, 0)
	waterline.Size = UDim2.new(1, 0, 0, 10)
	waterline.BackgroundColor3 = FOAM
	waterline.BackgroundTransparency = 0.06
	for i = 0, 26 do
		local s = bd("Scallop", 1, wash)
		s.AnchorPoint = Vector2.new(0.5, 0.5)
		s.Position = UDim2.new(i / 26, 0, 0, 7)
		s.Size = UDim2.fromOffset(56, 26)
		s.BackgroundColor3 = FOAM
		s.BackgroundTransparency = 0.06
		pill(s)
	end

	----------------------------------------------------------------
	-- The title card
	--
	-- TextScaled on a card sized in SCALE, not a TextSize in pixels: this is the
	-- first thing a phone sees and a 96px title laid out for a desktop viewport
	-- runs off both edges of one. The shine label is built to exactly the same
	-- box for the same reason -- two TextScaled labels in identical frames stay
	-- registered on every screen, which is what lets the sweep sit ON the
	-- letters instead of drifting off them.
	----------------------------------------------------------------
	card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.47)
	card.Size = UDim2.fromScale(0.86, 0.42)
	card.BackgroundTransparency = 1
	card.Visible = false
	card.ZIndex = 12
	card.Parent = gui

	-- Fredoka One over Luckiest Guy: rounder, wider apertures, and it holds its
	-- shape at the size a wordmark has to be. Nunito for the line underneath --
	-- Gotham's caps are handsome and slightly cold, and this is a beach. Both
	-- match the loading screen, which is the point.
	local TITLE_FACE = Font.fromEnum(Enum.Font.FredokaOne)
	local function bodyFace(weight: Enum.FontWeight): Font
		local f = Font.fromEnum(Enum.Font.Nunito)
		f.Weight = weight
		return f
	end

	local function bigLine(colour: Color3, z: number): TextLabel
		local l = PanelKit.text(card, "CLEAN THE BEACH", 90, Enum.Font.LuckiestGuy, colour)
		l.FontFace = TITLE_FACE
		l.TextScaled = true
		l.TextTruncate = Enum.TextTruncate.None
		l.AnchorPoint = Vector2.new(0.5, 0)
		l.Position = UDim2.fromScale(0.5, 0.06)
		l.Size = UDim2.fromScale(1, 0.46)
		l.ZIndex = z
		return l
	end

	-- THE SHADOW, nine pixels low and carrying the same 7px outline so its
	-- silhouette matches the gold copy's outer edge rather than its fill. An
	-- outline on its own reads flat; this is what gives the wordmark weight.
	titleShadow = bigLine(C.ink, 12)
	titleShadow.Position = UDim2.new(0.5, 0, 0.06, 9)
	PanelKit.punch(titleShadow, 7, C.ink)

	-- WHITE, with the gradient below carrying the gold. Same reason as everything
	-- else on this screen: a UIGradient MULTIPLIES against the fill underneath
	-- it, so gold-on-gold comes back muddy and only white leaves the ramp saying
	-- exactly what it says.
	title = bigLine(C.white, 13)
	-- The warm ink every panel and every sign in this game is outlined with. One
	-- outline colour is most of what makes separately-written screens read as one
	-- set, and a title card is the worst possible place to break that.
	PanelKit.punch(title, 7, C.ink)

	local titleGrad = Instance.new("UIGradient")
	titleGrad.Rotation = 90
	titleGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 248, 216)),
		ColorSequenceKeypoint.new(0.46, Color3.fromRGB(255, 214, 122)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(246, 166, 36)),
	})
	titleGrad.Parent = title

	-- The sweep is a SEPARATE white copy, and has to be. Its own gradient is
	-- white on white, so all it decides is WHERE the copy is opaque -- a band of
	-- highlight travelling across letters that are otherwise not there. Putting
	-- it on the title instead would fight the gold ramp above for the one
	-- gradient a label gets.
	shine = bigLine(Color3.new(1, 1, 1), 14)
	shine.TextTransparency = 1

	shineGrad = Instance.new("UIGradient")
	shineGrad.Color = ColorSequence.new(Color3.new(1, 1, 1))
	shineGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.40, 1),
		NumberSequenceKeypoint.new(0.50, 0.1),
		NumberSequenceKeypoint.new(0.60, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	shineGrad.Rotation = 16
	shineGrad.Offset = Vector2.new(-1.1, 0)
	shineGrad.Parent = shine

	rule = Instance.new("Frame")
	rule.Name = "Rule"
	rule.AnchorPoint = Vector2.new(0.5, 0)
	rule.Position = UDim2.fromScale(0.5, 0.56)
	rule.Size = UDim2.fromScale(0, 0.012)
	-- White under the gradient, same rule as everywhere else here.
	rule.BackgroundColor3 = C.white
	rule.BorderSizePixel = 0
	rule.ZIndex = 13
	rule.Parent = card
	PanelKit.corner(rule, 8)
	-- Faded out at both ends. A hairline that stops dead is a bar; one that
	-- dissolves is a rule, and that difference is most of what makes a card look
	-- printed rather than assembled.
	local ruleGrad = Instance.new("UIGradient")
	ruleGrad.Color = ColorSequence.new(C.sun)
	ruleGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.18, 0),
		NumberSequenceKeypoint.new(0.82, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	ruleGrad.Parent = rule

	sub = PanelKit.text(card, "rake the sand  \u{00B7}  find what the tide left",
		26, Enum.Font.GothamBold, C.sand)
	sub.FontFace = bodyFace(Enum.FontWeight.ExtraBold)
	sub.TextScaled = true
	sub.TextTruncate = Enum.TextTruncate.None
	sub.AnchorPoint = Vector2.new(0.5, 0)
	sub.Position = UDim2.fromScale(0.5, 0.63)
	sub.Size = UDim2.fromScale(0.8, 0.13)
	sub.ZIndex = 13
	-- It sits on a lit sky now rather than on black, so it needs the outline to
	-- stay legible -- and it matches the wordmark above it while it is there.
	PanelKit.punch(sub, 3, C.ink)

	skipHint = PanelKit.text(gui, "press any key to skip", 18, Enum.Font.GothamBold,
		Color3.fromRGB(226, 214, 190))
	skipHint.FontFace = bodyFace(Enum.FontWeight.Bold)
	skipHint.AnchorPoint = Vector2.new(1, 1)
	skipHint.Position = UDim2.new(1, -26, 1, -22)
	skipHint.Size = UDim2.fromOffset(230, 24)
	skipHint.TextXAlignment = Enum.TextXAlignment.Right
	skipHint.TextTransparency = 1
	skipHint.ZIndex = 12
end

----------------------------------------------------------------
-- Controls
--
-- Lifted from WashClientController, including the reason it is spawned:
-- resolving PlayerModule YIELDS the first time, and this is called from a boot
-- path that must not stall the start() calls behind it.
----------------------------------------------------------------

local function setControls(enabled: boolean)
	controlsWanted = enabled
	task.spawn(function()
		if not controlsModule then
			local ok, res = pcall(function()
				local ps = player:WaitForChild("PlayerScripts", 10)
				return require(ps:WaitForChild("PlayerModule", 10)):GetControls()
			end)
			controlsModule = ok and res or nil
		end
		if not controlsModule then
			return
		end
		if controlsWanted then
			controlsModule:Enable()
		else
			controlsModule:Disable()
		end
	end)
end

local function hideHud()
	table.clear(hidden)
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return
	end
	for _, name in ipairs(HIDE) do
		local g = pg:FindFirstChild(name)
		if g and g:IsA("ScreenGui") and g.Enabled then
			g.Enabled = false
			table.insert(hidden, g)
		end
	end
end

-- Re-run while the shot plays. Half of these ScreenGuis are built on demand by
-- the file that owns them, and several of them are still booting when the intro
-- starts -- a one-shot hide misses every one that arrives afterwards.
local function hideLateHud()
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return
	end
	for _, name in ipairs(HIDE) do
		local g = pg:FindFirstChild(name)
		if g and g:IsA("ScreenGui") and g.Enabled then
			g.Enabled = false
			local known = false
			for _, h in ipairs(hidden) do
				if h == g then
					known = true
					break
				end
			end
			if not known then
				table.insert(hidden, g)
			end
		end
	end
end

local function showHud()
	for _, g in ipairs(hidden) do
		if g.Parent then
			g.Enabled = true
		end
	end
	table.clear(hidden)
end

----------------------------------------------------------------
-- Other players
--
-- Only one avatar belongs in this shot -- everyone else on the beach, or
-- anyone who joins mid-shot, is invisible to THIS client for the length of
-- the sequence, and that means more than their body:
--
--   * their PET -- a plain Workspace model named "<Username>_<PetName>"
--     (see PetVisuals). It is not parented under the character and carries
--     no owner attribute, so it has to be found by that name prefix.
--   * their SIFTER GHOST -- Workspace.CTB_Peers.CTB_Sifter_<Username>, the
--     replica CTB_Client draws for every OTHER player's tool. It is not a
--     real equipped Tool, so it never shows up under their Character either.
--   * their NAME/HEALTH TAG -- Roblox's own floating display, driven by
--     Humanoid.DisplayDistanceType / HealthDisplayType, not a custom gui.
--
-- HIDING IS PER-CLASS, AND THAT IS THE WHOLE LESSON HERE.
--
-- LocalTransparencyModifier ONLY EXISTS ON BasePart. The first attempt set it
-- across each model and called the job done -- but a pet is a MeshPart plus a
-- ParticleEmitter, a Beam, a Trail and a PointLight; the sifter ghost carries a
-- BillboardGui and more emitters; and a face is a Decal. None of those are
-- BaseParts, so every one of them stayed on screen and the fix read as having
-- done nothing at all. Measured in a live session: the pet's mesh went to
-- LocalTransparencyModifier = 1 and HELD it, while its emitter sat at
-- Enabled = true the entire time.
--
-- So each class is switched off by ITS OWN property, and the original value is
-- recorded per instance so restore puts back what was actually there.
--
-- AND IT IS RE-ASSERTED ON A SWEEP rather than wired to signals. Pets and the
-- ghost are drawn by other scripts that can rebuild or re-show them mid-shot,
-- parts stream in late, and a player can join or respawn at any point in the
-- twelve seconds. A pass every tenth of a second cannot miss any of that; a set
-- of ChildAdded/DescendantAdded hooks demonstrably could.
----------------------------------------------------------------
local hiddenInst = {}    -- [Instance] = { propertyName = originalValue }
local savedDisplay = {}  -- [Humanoid]  = { DisplayDistanceType, HealthDisplayType }
local concealing = false

-- Switch one instance off by whatever property its class actually uses, first
-- recording what it was. Re-entrant: called again on an instance already
-- recorded, it re-applies WITHOUT overwriting the saved original.
local function conceal(inst: Instance)
	local rec = hiddenInst[inst]
	if rec == nil then
		rec = {}
		if inst:IsA("BasePart") then
			rec.LocalTransparencyModifier = inst.LocalTransparencyModifier
		elseif inst:IsA("Decal") then
			-- Texture inherits Decal, so this covers both.
			rec.Transparency = inst.Transparency
		elseif inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam")
			or inst:IsA("Smoke") or inst:IsA("Fire") or inst:IsA("Sparkles")
			or inst:IsA("Light") or inst:IsA("BillboardGui") or inst:IsA("SurfaceGui")
			or inst:IsA("Highlight") then
			rec.Enabled = inst.Enabled
		else
			return
		end
		hiddenInst[inst] = rec
	end

	if rec.LocalTransparencyModifier ~= nil then
		inst.LocalTransparencyModifier = 1
	elseif rec.Transparency ~= nil then
		inst.Transparency = 1
	else
		inst.Enabled = false
	end
end

local function concealModel(model: Instance)
	for _, d in ipairs(model:GetDescendants()) do
		conceal(d)
	end
end

-- One pass over everyone who is not the local player: their character and its
-- nametag, their pet(s), and their sifter ghost.
local function concealOthers()
	local peers = workspace:FindFirstChild("CTB_Peers")
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			local char = other.Character
			if char then
				concealModel(char)
				-- The floating name and health bar are Roblox's OWN display, not a
				-- gui this place builds -- there is no instance to hide, only these
				-- two Humanoid properties.
				local hum = char:FindFirstChildOfClass("Humanoid")
				if hum then
					if savedDisplay[hum] == nil then
						savedDisplay[hum] = { hum.DisplayDistanceType, hum.HealthDisplayType }
					end
					hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
					hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
				end
			end

			-- Pets: plain Workspace models named "<Username>_<PetName>", not
			-- parented under the character. The local player's own pet is
			-- deliberately left alone -- only OTHER people vanish.
			local prefix = other.Name .. "_"
			for _, m in ipairs(workspace:GetChildren()) do
				if m:IsA("Model") and m.Name:sub(1, #prefix) == prefix then
					concealModel(m)
				end
			end

			-- The rake. Your own sifter is Workspace.CTB_Sifter; everyone else's
			-- is a replica under CTB_Peers, so this cannot catch yours by mistake.
			local ghost = peers and peers:FindFirstChild("CTB_Sifter_" .. other.Name)
			if ghost then
				concealModel(ghost)
			end
		end
	end
end

local function watchOtherPlayers()
	if concealing then
		return
	end
	concealing = true
	-- task.wait rather than RenderStepped: a minimised Studio window stops
	-- firing RenderStepped entirely and the sweep would stall with everyone
	-- still hidden. See the note on this in the gotchas.
	task.spawn(function()
		while concealing do
			concealOthers()
			task.wait(0.1)
		end
	end)
end

-- Puts every recorded property back exactly as it was found. Clearing the flag
-- FIRST stops the sweep above before anything is restored, so nothing can be
-- re-hidden behind this.
-- NO Parent GUARD, for the reason set out on MenuHud's reveal(): Parent = nil
-- does not mean gone. CTB_Client parks every peer sifter that is out of range by
-- writing Parent = nil on it, so a rig parked on the frame the opening ended was
-- skipped here and came back into the world still concealed -- permanently, as
-- nothing re-asserts a peer rig's transparency once the shot is over. A property
-- write on an instance that really was destroyed is harmless: Destroy locks
-- Parent and nothing else.
local function restoreOtherPlayers()
	concealing = false
	for inst, rec in pairs(hiddenInst) do
		for prop, value in pairs(rec) do
			pcall(function()
				inst[prop] = value
			end)
		end
	end
	table.clear(hiddenInst)
	for hum, saved in pairs(savedDisplay) do
		pcall(function()
			hum.DisplayDistanceType = saved[1]
			hum.HealthDisplayType = saved[2]
		end)
	end
	table.clear(savedDisplay)
end

----------------------------------------------------------------
-- Putting it all back
--
-- Every exit runs through here -- the end of the shot, the skip key, a respawn,
-- the panic timer. It is idempotent and it never trusts that the sequence got
-- as far as setting a given thing up.
----------------------------------------------------------------

local function finish(token: number, home: Vector3?)
	if token ~= guard or not running then
		return
	end
	running = false
	dropConns()
	restoreOtherPlayers()
	restoreSifter()

	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")

	-- Behind the curtain, so nobody sees the jump back across the beach.
	if hrp and home then
		hrp.CFrame = CFrame.new(home) * CFrame.Angles(0, math.rad(180), 0)
	end
	if hum then
		--[[
			BEACH LEGS, NOT A FLAT 16 -- AND THIS LINE WAS THE "I REJOIN AND I AM
			SLOW" BUG, ENTIRE.

			finish() is the single funnel every exit from the opening goes through
			-- watched, skipped, errored, respawned, timed out, all ten call sites
			-- so this ran on EVERY join, and it ran LAST. ProgressionServer had
			already done its job correctly: applyAll writes Humanoid.WalkSpeed from
			the player's Beach Legs level on PlayerAdded, and SaveService calls it
			again the moment the profile lands. Then the intro finished a couple of
			seconds later and put 16 straight over the top of it.

			The character is network-owned by this client, so a client write to its
			own humanoid wins -- and nothing re-derives WalkSpeed until the next
			applyAll, which for most players never comes. Measured in a live session
			on a maxed save: Lv_BeachLegs 60, BaseWalkSpeed 66, and a character
			actually moving at 16. That pairing is the whole signature of the bug --
			every stat readout is derived from the attributes and reads MAXED, while
			the humanoid the player is steering is at a quarter of it.

			16 was not even a sensible constant to land on: this place authors
			StarterPlayer.CharacterWalkSpeed at 24 -- matched to the level-1 floor,
			ProgressionConfig.BaseWalkSpeed, since 2026-08-28; it was 19 -- so the
			"restore" was slower than a brand new character with no upgrades at all.

			BaseWalkSpeed is ProgressionServer publishing what it just wrote, and it
			exists for exactly this -- see the long note on it in applyAll, and
			AfkClient.restoreSpeed, which is the same fix applied to the same class
			of bug on the idle shore. Anything that drives this humanoid down and
			has to hand it back reads that attribute rather than guessing.
		]]
		hum.WalkSpeed = player:GetAttribute("BaseWalkSpeed") or StarterPlayer.CharacterWalkSpeed
		hum.AutoRotate = true
	end

	local cam = workspace.CurrentCamera
	if cam then
		if hum then
			cam.CameraSubject = hum
		end
		cam.CameraType = Enum.CameraType.Custom
	end

	setControls(true)
	player:SetAttribute("CTB_ClockTarget", HOME_HOUR)

	if fx then
		fx:Destroy()
		fx, coin = nil, nil
	end

	showHud()

	-- The world coming up. Quick, because by this point the player has been
	-- looking at a title card and wants to be holding the sifter.
	TweenService:Create(curtain, TweenInfo.new(0.55, Enum.EasingStyle.Quad),
		{ BackgroundTransparency = 1 }):Play()
	TweenService:Create(flash, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
	for _, f in ipairs({ barTop, barBottom }) do
		TweenService:Create(f, TweenInfo.new(0.45, Enum.EasingStyle.Quad), { Size = UDim2.fromScale(1, 0) }):Play()
	end
	for _, l in ipairs({ title, titleShadow, shine, sub, skipHint }) do
		TweenService:Create(l, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
		local st = l:FindFirstChildOfClass("UIStroke")
		if st then
			TweenService:Create(st, TweenInfo.new(0.3), { Transparency = 1 }):Play()
		end
	end
	TweenService:Create(rule, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
	-- Quicker than the curtain's 0.55s, so the beach comes up THROUGH this rather
	-- than out from behind it once it has already gone.
	TweenService:Create(backdrop, TweenInfo.new(0.34), { GroupTransparency = 1 }):Play()

	task.delay(0.6, function()
		if not running then
			curtain.BackgroundTransparency = 1
			flash.BackgroundTransparency = 1
			card.Visible = false
			backdrop.Visible = false
			gui.Enabled = false
		end
	end)
end

----------------------------------------------------------------
-- The shot
----------------------------------------------------------------

-- Where the camera is at time t. `walker` is the avatar's root position this
-- frame and `coinAt` is the coin's, so the shot stays framed on things that are
-- actually moving rather than on where they were predicted to be.
local function cameraAt(t: number, walker: Vector3, coinAt: Vector3, ground: number): CFrame
	local eye, focus

	if t < T_TRACK then
		--[[
			WIDE, LOW, AND LOOKING UP THE TIDELINE -- the shot is turned ninety
			degrees from where it was, and that is what fixes the composition as
			well as the palm.

			The old wide sat east of the walker and looked WEST across the beach for
			the sea behind him. Two things wrong with it: east of the walker is the
			palm grove, and the beach rises inland, so any camera far enough east to
			be a wide is either inside a canopy or staring at a slope. Both were
			tried and photographed before this was written.

			This one stands SOUTH, down the shore, and looks back up it. Palms and
			umbrellas rake down the left, open water fills the right, and the walker
			comes toward the lens instead of across it -- which is also the reason it
			hooks better: an approach is a promise, and a crossing is a fact.

			It pushes in only slightly. The walker closes 20 studs on his own in
			these two and a bit seconds, and a camera that rushes at a subject who is
			already coming reads as a zoom rather than a move.
		]]
		local a = ease(t / T_TRACK)
		eye = lerpV(
			Vector3.new(SHORE_X + 4, ground + 4.6, -38 + laneZ),
			Vector3.new(SHORE_X + 3, ground + 3.4, -33 + laneZ), a)
		focus = walker + Vector3.new(0, 2.2, 0)

	elseif t < T_STOP then
		-- TRACKING, locked to the walker and closing on them. This is the shot
		-- that has to sell the loop, so it is the one that holds on the tool: the
		-- sifter is behind them, throwing sand, for the whole of it.
		-- Three quarters on and ABOVE the tool. The sifter is pushed in front of
		-- the player, not dragged behind (see gripCFrame in CTB_Client), so a
		-- head-on camera at chest height is looking at the back of a wire basket
		-- with an avatar behind it. From up here the basket, the sand coming off
		-- it and the player working it are all in the same frame, which is the
		-- entire job of this shot.
		--
		-- ON THE SEAWARD SIDE, which is the whole reason this shot is now safe:
		-- there is not one part west of x -200 on this stretch, so the tracking
		-- camera cannot clip anything however long it holds.
		local a = ease((t - T_TRACK) / (T_STOP - T_TRACK))
		eye = walker + lerpV(Vector3.new(-12.5, 4.6, -8.0), Vector3.new(-8.6, 3.2, -4.8), a)
		focus = walker + Vector3.new(0, 2.1, 0)

	elseif t < T_CLOSE then
		-- DOWN TO THE SAND. The camera leaves the walker and goes to the ground
		-- ahead of them, arriving just as the glint does -- so the player is
		-- already looking at the right patch of beach when it happens.
		local a = ease((t - T_STOP) / (T_CLOSE - T_STOP))
		eye = lerpV(walker + Vector3.new(-8.6, 3.2, -4.8), coinAt + Vector3.new(-2.4, 1.2, -1.9), a)
		focus = lerpV(walker + Vector3.new(0, 2.1, 0), coinAt + Vector3.new(0, 0.15, 0), a)

	else
		-- HERO. A slow arc around the coin with the walker standing behind it, so
		-- the last thing on screen before the cut is the find AND the finder.
		--
		-- THE ARC STAYS ON THE SEAWARD SIDE TOO. Not for clearance -- at under
		-- three studs from the coin nothing is close -- but for screen direction:
		-- the camera has been west of the subject for eight seconds, and swinging
		-- to the far side here would flip the walker across the frame on the last
		-- shot before the cut, which reads as a mistake even to somebody who could
		-- not say why.
		local a = ease((t - T_CLOSE) / (T_BLACK - T_CLOSE))
		local ang = 3.76 - a * 0.9
		local dist = 2.6 - a * 0.9
		eye = coinAt + Vector3.new(math.cos(ang) * dist, 0.75 + a * 0.45, math.sin(ang) * dist)
		focus = coinAt
	end

	return CFrame.lookAt(eye, focus)
end

-- Where the coin is at time t, and how bright. Buried until T_RISE, then it
-- comes up out of the sand on an overshoot and hangs, turning.
local function coinStateAt(t: number, base: Vector3): (Vector3, number, number)
	local buried = base.Y - coinDrop
	if t < T_RISE then
		return Vector3.new(base.X, buried, base.Z), 0, t * 1.1
	end
	local a = clamp01((t - T_RISE) / 1.35)
	-- Back-out: it breaks the surface fast, overshoots, and settles. Sand gives
	-- way suddenly or not at all.
	local e = 1 + 2.2 * math.pow(a - 1, 3) + 1.2 * math.pow(a - 1, 2)
	-- The travel is whatever it takes to get from where it was buried back to
	-- the same resting height, so burying it deeper does not leave it low.
	local y = buried + e * (coinDrop + COIN_SETTLE)
	-- and then a small hover, so the hero shot is not orbiting something nailed
	-- in place
	if a >= 1 then
		y += math.sin((t - T_RISE - 1.35) * 2.1) * 0.055
	end
	return Vector3.new(base.X, y, base.Z), math.min(a * 2.4, 1), t * 2.6
end

----------------------------------------------------------------
-- The sequence
----------------------------------------------------------------

local function run()
	guard += 1
	local token = guard
	running = true
	watchOtherPlayers()
	narrowSifter()

	-- Nothing on screen and nothing touched until the loading screen says the
	-- world is built. That can be half a minute on a cold join, which is why the
	-- panic timer below is armed AFTER this wait rather than before it.
	waitForWorld(34)

	curtain.BackgroundTransparency = 0
	gui.Enabled = true
	flash.BackgroundTransparency = 1
	backdrop.Visible = false
	backdrop.GroupTransparency = 1
	card.Visible = false
	setAlpha(title, 1)
	setAlpha(titleShadow, 1)
	shine.TextTransparency = 1
	sub.TextTransparency = 1
	rule.Size = UDim2.fromScale(0, 0.012)
	rule.BackgroundTransparency = 0

	-- BETWEEN ONE FRAME AND THE NEXT, NOT A FADE, and that is the whole fix for
	-- the flash of loading screen this used to show. The splash is UNDERNEATH
	-- this curtain: fading the curtain in means the progress bar is visible
	-- through it for the length of the fade, which is exactly the "split second
	-- of loading screen" that was being seen. It goes up opaque instead, and only
	-- once it has actually been drawn is the splash told it may go.
	--
	-- The wait is a plain task.wait rather than RenderStepped:Wait, because a
	-- Studio window that is minimised stops firing RenderStepped entirely and
	-- this would never return.
	task.wait(0.05)
	player:SetAttribute("CTB_IntroCovered", true)

	hideHud()
	setControls(false)

	-- THE PANIC TIMER, armed before anything can fail. Every early return below
	-- leaves the player behind a black screen otherwise.
	task.delay(T_DONE + 8, function()
		finish(token, SPAWN_FALLBACK)
	end)

	local char = player.Character or player.CharacterAdded:Wait()
	local hum = char:WaitForChild("Humanoid", 10)
	local hrp = char:WaitForChild("HumanoidRootPart", 10)
	if not (hum and hrp) then
		finish(token, nil)
		return
	end

	-- Remember where they actually spawned; that is where they get handed back,
	-- and it beats a constant if the pad ever moves.
	local home = hrp.Position
	local pad = workspace:FindFirstChild("Beach")
	pad = pad and pad:FindFirstChild("SpawnLocation")
	if pad and pad:IsA("BasePart") then
		home = pad.Position + Vector3.new(0, 3.5, 0)
	end

	-- See laneOffset() above -- keeps two simultaneous joiners off each other.
	laneZ = laneOffset()

	-- Out to the shore, high enough to drop onto whatever the sand turns out to
	-- be, and THEN wait for the ground to answer. The character is the streaming
	-- focus, so this move is what makes the terrain arrive at all.
	hum.WalkSpeed = 0
	hrp.CFrame = CFrame.lookAt(
		Vector3.new(SHORE_X, 12, WALK_FROM_Z + laneZ),
		Vector3.new(SHORE_X, 12, WALK_FROM_Z + laneZ - 10))

	if not waitForShore(8) then
		-- The shore never arrived. Nothing is broken and nothing is worth showing;
		-- hand the session over rather than play a shot of the inside of a cloud.
		finish(token, home)
		return
	end

	local ground = groundY(SHORE_X, WALK_FROM_Z + laneZ) or 3
	local stopAt = Vector3.new(SHORE_X, groundY(SHORE_X, WALK_TO_Z + laneZ) or ground, WALK_TO_Z + laneZ)

	-- Provisional only. The real position is taken from where the avatar ACTUALLY
	-- stops -- see the stop beat below -- because this one is only right if the
	-- walk lands exactly on its mark, and it does not have to.
	local coinBase = Vector3.new(SHORE_X - 0.7, 0, WALK_TO_Z + laneZ - COIN_AHEAD)
	coinBase = Vector3.new(coinBase.X, (groundY(coinBase.X, coinBase.Z) or ground) + COIN_LIFT, coinBase.Z)

	fx = Instance.new("Folder")
	fx.Name = "CTB_Intro"
	fx.Parent = workspace
	coin = buildCoin(Vector3.new(coinBase.X, coinBase.Y, coinBase.Z))
	-- Now that the part exists, how deep it has to sit to be out of sight:
	-- the lift that put coinBase above the sand, plus the coin's own tilted
	-- half-height, plus a little so its rim is under the surface and not on it.
	coinDrop = COIN_LIFT + coinHalfHeight(coin) + COIN_UNDER
	coin.CFrame = CFrame.new(coinBase.X, coinBase.Y - coinDrop, coinBase.Z)

	hrp.CFrame = CFrame.lookAt(
		Vector3.new(SHORE_X, ground + 3.2, WALK_FROM_Z + laneZ),
		Vector3.new(SHORE_X, ground + 3.2, WALK_FROM_Z + laneZ - 10))

	local cam = workspace.CurrentCamera
	if not cam then
		finish(token, home)
		return
	end
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = cameraAt(0, hrp.Position, coinBase, ground)

	-- Golden hour, and the music pulled right down so the title has somewhere to
	-- arrive from. dipMusic restores itself on its own timer, which is set to end
	-- exactly as the card lands.
	player:SetAttribute("CTB_ClockTarget", GOLDEN_HOUR)
	AudioKit.dipMusic(0.05, T_TITLE)

	-- Letterbox in under the black, so it is already there when the picture
	-- arrives rather than closing over a shot the player has started watching.
	for _, f in ipairs({ barTop, barBottom }) do
		TweenService:Create(f, TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{ Size = UDim2.fromScale(1, 0.105) }):Play()
	end

	local t0 = os.clock()
	local walking = false
	local fired = {}

	-- One-shot beats, fired by the clock rather than by task.delay so that a
	-- frame hitch cannot reorder them against the camera.
	local function once(key: string, at: number, t: number, fn)
		if t >= at and not fired[key] then
			fired[key] = true
			fn()
		end
	end

	track(RunService.RenderStepped:Connect(function()
		if not running or guard ~= token then
			return
		end
		local t = os.clock() - t0

		local here = hrp.Position
		local coinPos, glow, spin = coinStateAt(t, coinBase)

		if coin then
			coin.CFrame = CFrame.new(coinPos)
				* CFrame.Angles(0, spin, 0)
				* CFrame.Angles(COIN_TILT, 0, 0)
			local light = coin:FindFirstChild("Glow")
			if light and light:IsA("PointLight") then
				light.Brightness = glow * 2.6
			end
		end

		cam.CFrame = cameraAt(t, here, coinPos, ground)

		-- The picture arrives.
		once("up", 0.0, t, function()
			TweenService:Create(curtain, TweenInfo.new(T_FADE_UP, Enum.EasingStyle.Quad),
				{ BackgroundTransparency = 1 }):Play()
			AudioKit.play("Wave", nil, 0.85, 0.9)
		end)

		once("walk", 0.35, t, function()
			walking = true
			hum.WalkSpeed = WALK_SPEED
			hum:MoveTo(stopAt)
		end)

		once("skiphint", 1.6, t, function()
			TweenService:Create(skipHint, TweenInfo.new(0.5), { TextTransparency = 0.35 }):Play()
		end)

		-- MoveTo is re-issued while the walk is on. Roblox gives up on a MoveTo
		-- after 8 seconds of it, and one nudge from a wave or a slope in between
		-- would otherwise leave them standing still for the rest of the shot.
		if walking and t < T_STOP then
			if math.floor(t * 2) ~= math.floor((t - 0.02) * 2) then
				hum:MoveTo(stopAt)
			end
		end

		once("stop", T_STOP, t, function()
			walking = false
			hum.WalkSpeed = 0
			hum:MoveTo(hrp.Position)

			-- THE FIND IS PLACED HERE, NOT AT SETUP, and that is the difference
			-- between a shot that frames it and one that goes looking for it. Where
			-- they stop is not where they were sent: a slope, a wave, a slow frame
			-- and MoveTo leaves them a stud or two short. Measuring off the real
			-- position and the real facing puts the coin in front of the sifter
			-- every time.
			local look = hrp.CFrame.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			flat = flat.Magnitude > 0.01 and flat.Unit or Vector3.new(0, 0, -1)
			local at = here + flat * COIN_AHEAD
			coinBase = Vector3.new(at.X, (groundY(at.X, at.Z) or ground) + COIN_LIFT, at.Z)
			if coin then
				coin.CFrame = CFrame.new(coinBase.X, coinBase.Y - coinDrop, coinBase.Z)
			end
		end)

		-- Facing the find. Done by hand rather than by MoveTo: a MoveTo two studs
		-- away makes them shuffle into it, and they are meant to have SEEN
		-- something, not walked onto it.
		if t >= T_STOP and t < T_CLOSE then
			local flat = Vector3.new(coinBase.X - here.X, 0, coinBase.Z - here.Z)
			if flat.Magnitude > 0.05 then
				local want = CFrame.lookAt(here, here + flat.Unit)
				hrp.CFrame = hrp.CFrame:Lerp(want, 0.12)
			end
		end

		once("glint", T_GLINT, t, function()
			sparkPuff(Vector3.new(coinBase.X, coinBase.Y, coinBase.Z), 10,
				Color3.fromRGB(255, 232, 168), 5)
			AudioKit.play("FairyDust", nil, 0.45, 1.2)
		end)

		once("rise", T_RISE, t, function()
			sandPuff(Vector3.new(coinBase.X, coinBase.Y, coinBase.Z), 26)
			sparkPuff(Vector3.new(coinBase.X, coinBase.Y + 0.4, coinBase.Z), 22,
				Color3.fromRGB(255, 214, 120), 11)
			AudioKit.stack("SandDrop", "Pickup", nil, 0.07, 1.0)
			if coin then
				local dust = coin:FindFirstChild("Dust")
				if dust and dust:IsA("ParticleEmitter") then
					dust.Rate = 9
				end
			end
		end)

		once("hero", T_CLOSE, t, function()
			AudioKit.play("LegendaryHit", nil, 0.5, 1.02)
		end)

		-- THE CUT. Gold blows the frame out over a quarter of a second and black is
		-- already coming in underneath it, so the picture is gone at the peak
		-- rather than dissolving away after it.
		once("flash", T_FLASH, t, function()
			TweenService:Create(flash, TweenInfo.new(T_BLACK - T_FLASH, Enum.EasingStyle.Quad,
				Enum.EasingDirection.In), { BackgroundTransparency = 0 }):Play()
			AudioKit.play("TideBoom", nil, 0.8, 0.6)
			TweenService:Create(skipHint, TweenInfo.new(0.2), { TextTransparency = 1 }):Play()
		end)

		once("black", T_BLACK, t, function()
			curtain.BackgroundTransparency = 0
			TweenService:Create(flash, TweenInfo.new(0.22), { BackgroundTransparency = 1 }):Play()
			-- The camera is done. Everything left is on the screen, and holding a
			-- scriptable camera on a coin nobody can see costs a frame for nothing.
			if fx then
				fx:Destroy()
				fx, coin = nil, nil
			end
			-- Back toward the game's own daylight while the screen is black, so the
			-- world that fades up at the end is already the right hour.
			local ct0 = os.clock()
			track(RunService.RenderStepped:Connect(function()
				local a = clamp01((os.clock() - ct0) / 2.5)
				player:SetAttribute("CTB_ClockTarget",
					GOLDEN_HOUR + (HOME_HOUR - GOLDEN_HOUR) * ease(a))
			end))
		end)

		-- THE CARD, on a screen that has been black for two thirds of a second.
		-- The pause is the point: a title that lands on the same frame as the cut
		-- is a transition, and a title that lands after a beat of nothing is an
		-- announcement.
		once("title", T_TITLE, t, function()
			-- The sky comes up WITH the card and not a moment before it. The beat
			-- of nothing after the cut is what makes this land as an announcement,
			-- and lighting the backdrop early spends it for nothing.
			backdrop.Visible = true
			backdrop.GroupTransparency = 1
			TweenService:Create(backdrop, TweenInfo.new(0.55, Enum.EasingStyle.Quad),
				{ GroupTransparency = 0 }):Play()
			card.Visible = true
			card.Size = UDim2.fromScale(0.72, 0.35)
			setAlpha(title, 0)
			setAlpha(titleShadow, 0.5)
			sub.TextTransparency = 1
			TweenService:Create(card, TweenInfo.new(0.52, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Size = UDim2.fromScale(0.86, 0.42) }):Play()
			TweenService:Create(rule, TweenInfo.new(0.6, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
				{ Size = UDim2.fromScale(0.42, 0.012) }):Play()
			AudioKit.stack("TideArrive", "Upgrade", nil, 0.16, 0.95)
		end)

		once("shine", T_SHINE, t, function()
			shine.TextTransparency = 0
			shineGrad.Offset = Vector2.new(-1.1, 0)
			TweenService:Create(shineGrad, TweenInfo.new(0.85, Enum.EasingStyle.Quad),
				{ Offset = Vector2.new(1.1, 0) }):Play()
			TweenService:Create(sub, TweenInfo.new(0.5), { TextTransparency = 0 }):Play()
		end)

		once("lift", T_LIFT, t, function()
			AudioKit.play("Wave", nil, 0.6, 1.06)
		end)

		if t >= T_DONE then
			finish(token, home)
		end
	end))

	-- Skipping. Anything at all: a key, a click, a tap, a gamepad button.
	track(UserInputService.InputBegan:Connect(function(input)
		if not running or guard ~= token then
			return
		end
		if os.clock() - t0 < SKIP_AFTER then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Focus then
			return
		end
		-- Straight to black rather than straight to the game: a hard cut from a
		-- beach at golden hour to the same beach at noon reads as a graphics fault.
		-- The backdrop goes with it rather than fading, or a skip taken during the
		-- title card leaves the sunset sitting over the black it just cut to.
		curtain.BackgroundTransparency = 0
		backdrop.Visible = false
		player:SetAttribute("CTB_ClockTarget", HOME_HOUR)
		task.delay(0.12, function()
			finish(token, home)
		end)
	end))

	-- A death or a respawn mid-shot detaches everything this is driving. There is
	-- nothing to rescue at that point; end it and give them the beach.
	track(player.CharacterAdded:Connect(function()
		finish(token, nil)
	end))

	-- The late-HUD sweep, once a second for the length of the shot.
	task.spawn(function()
		while running and guard == token do
			hideLateHud()
			task.wait(1)
		end
	end)
end

----------------------------------------------------------------
-- Boot
----------------------------------------------------------------

local started = false

function IntroCinema.start()
	if started then
		return
	end
	started = true

	-- BOTH HALVES ARE WRAPPED, and build() is the one that matters. This is
	-- called straight out of ClientMain, ahead of the inventory mirror and every
	-- HUD in the game -- so an error thrown here does not cost the intro, it
	-- costs the entire client boot behind it. A cinematic is never allowed to be
	-- the reason somebody cannot play.
	local built = pcall(build)
	if not built then
		warn("[CleanTheBeach] intro screen would not build; skipping the opening shot")
		if gui then
			gui:Destroy()
			gui = nil
		end
		-- Told anyway, or the loading screen sits there waiting to be covered by
		-- something that is never coming and only its own ceiling gets it moving.
		player:SetAttribute("CTB_IntroCovered", nil)
		return
	end

	task.spawn(function()
		local ok, err = pcall(run)
		if not ok then
			warn("[CleanTheBeach] intro failed, skipping it: " .. tostring(err))
			finish(guard, nil)
		end
	end)
end

return IntroCinema
