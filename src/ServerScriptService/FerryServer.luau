--[[
	FerryServer  --  ServerScriptService.FerryServer  (ModuleScript)

	Owns the crossings: where the three berths stand, who is allowed to sail
	where, and the move itself.

	SECURITY SHAPE, and it is stricter than the gates it replaces.
	------------------------------------------------------------
	The client sends a DESTINATION KEY and nothing else -- never a position,
	never a level, never a requirement. Two things are then re-checked here:

	  1. WHERE THEY ARE. The berth they sail FROM is worked out from the
	     player's own position against the talk anchors, not from anything they
	     said. The old gates never asked: a client that fired the travel prompt's
	     remote from the other side of the map was moved anyway, because a
	     ProximityPrompt's range is enforced on the CLIENT. Nothing here is.
	  2. WHAT THEY HAVE. The Sifter level is read off the player attribute
	     ProgressionServer writes, through the same FerryConfig.blockedReason the
	     panel greys its rows with, so the refusal the player is shown and the
	     refusal that actually happens are the same string.

	NOBODY IS EVER STRANDED. Sailing HOME is never gated -- FerryConfig gives the
	beach requireLevel 0, which is the floor of the Rebirths counter the ports now
	read -- and that is a correctness rule, not a kindness. A player who swam out
	here, or who was dropped by a check settling a frame late, must always be able
	to get back to the wash bay with a bag full of crust. The vault's own exit
	carries the same rule for the same reason.

	THE GATES NO LONGER MOVE UNDER A PLAYER. They read Rebirths, which only ever
	increments, so a port opened is a port kept. While they read the Sifter track
	a rebirth reset every one of them to locked, and this paragraph was carrying
	that weight on its own.

	THE CROSSING IS A VOYAGE WITH A TELEPORT IN THE MIDDLE OF IT.
	-------------------------------------------------------------
	It used to be a fade and a PivotTo, on the argument that an actually-sailing
	ferry is a wake, a rider, a network owner and a route and none of that is
	what "get me to the dunes" is asking for. Most of that argument still holds
	-- nothing here is a physics boat and nothing here has a route. What it got
	wrong is that the two ENDS of a crossing are worth having even if the middle
	is not:

	  board  the player is stood on the boat's deck and the mooring lines come
	         off her
	  cast   the boat is driven off the pier and out to sea, carrying them, and
	         they watch their own island go small behind them
	  ...    the screen goes dark, and the teleport happens in it
	  come   the FAR boat is driven in from open water to her own berth, still
	         carrying them
	  land   they step off onto the planks

	SO THE BOATS DO MOVE, and they move by one Heartbeat loop writing CFrames on
	anchored parts -- the same arrangement every other moving thing in this game
	uses. The passenger is not welded to anything and is not standing on
	anything: their HumanoidRootPart is anchored and written from the boat's own
	CFrame in the same loop, which is the only way the two can be guaranteed to
	agree to the frame. A Weld to a tweened anchored part gets there most of the
	time and jitters the rest.

	ONE CROSSING PER BERTH AT A TIME. There is one boat at each end and she
	cannot be leaving the beach and arriving at the cove at once, so both ends
	are marked busy for the length of a crossing and a second request is turned
	down in words rather than queued.

	EVERYTHING IS GIVEN BACK, WHATEVER HAPPENS. The whole run is wrapped so that
	one `finish` always executes: the character is unanchored, both boats are
	put back on their moorings with their lines on, both ends are marked free
	and the client is told to lift its veil. A player who dies, leaves or
	respawns in the middle costs a boat two seconds out of position and nothing
	else.

	THE TIMINGS ARE SHARED CONSTANTS, NOT A HANDSHAKE. FerryConfig.Trip is read
	here and on the client, so a dropped message can never leave somebody sitting
	in front of a black screen -- the client's veil runs on its own clock and has
	its own watchdog past the end of it. (VaultBuilder's transition records the
	same reasoning at length.)
]]

local FerryServer = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FerryConfig = require(ReplicatedStorage:WaitForChild("FerryConfig"))
local FerryBuilder = require(script.Parent:WaitForChild("FerryBuilder"))

local FOLDER_NAME = "Ferries"

-- One crossing at a time, and not twice in the same breath. The panel closes
-- itself on the click, so this only ever catches a double-fire or a script.
local SAIL_COOLDOWN = 2.0

local remotes
local berths = {}                 -- [key] = { port, model, talkAnchor, deckY, boat, ... }
local sailing = {}                -- [Player] = os.clock() of the last cast-off
local connections = {}
local started = false

----------------------------------------------------------------
-- REMOTES
----------------------------------------------------------------
local function ensureRemotes(): Folder
	local folder = ReplicatedStorage:FindFirstChild(FerryConfig.RemoteFolder)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FerryConfig.RemoteFolder
		folder.Parent = ReplicatedStorage
	end
	for _, name in ipairs(FerryConfig.Events) do
		if not folder:FindFirstChild(name) then
			local ev = Instance.new("RemoteEvent")
			ev.Name = name
			ev.Parent = folder
		end
	end
	return folder
end

local function tell(player: Player, ok: boolean, message: string)
	remotes.FerryResult:FireClient(player, { ok = ok, message = message })
end

----------------------------------------------------------------
-- GROUND
----------------------------------------------------------------
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace.Terrain }
groundParams.IgnoreWater = true

--[[
	The deck height for one berth, measured at its LANDWARD end.

	Waited for rather than trusted. Two of the three islands pour their own
	terrain at boot (Island2Builder, Island3Builder) and a raycast taken a frame
	early either misses entirely or answers with the seabed -- which would build
	a pier ten studs under the water it is supposed to stand over. Island3Builder
	keeps a groundYWait for exactly this and records why.

	CLAMPED as well as waited for, because "waited long enough" is not the same
	as "got a sane answer". Every field in this game sits at cleanY = 3.0, so a
	deck outside 3.6 .. 5.5 is a bad read however patiently it was taken, and the
	fallback is better than a pier in the sea.
]]
local function deckHeightFor(port): number
	local x, z = port.dock.x, port.dock.landZ
	local y
	for _ = 1, 60 do
		local hit = workspace:Raycast(Vector3.new(x, 300, z), Vector3.new(0, -600, 0), groundParams)
		if hit then
			y = hit.Position.Y
			break
		end
		task.wait(0.1)
	end
	if not y then
		warn(string.format("[Ferry] no ground under the %s berth at (%d, %d); using 3.0",
			port.key, x, z))
		y = 3.0
	end
	local deck = math.clamp(y + 0.9, 3.6, 5.5)
	if math.abs(deck - (y + 0.9)) > 0.01 then
		warn(string.format("[Ferry] %s berth ground read %.2f, which is off the island plane; "
			.. "deck clamped to %.2f", port.key, y, deck))
	end
	return deck
end

----------------------------------------------------------------
-- WHERE A CROSSING PUTS YOU DOWN
----------------------------------------------------------------
--[[
	Six studs onto the deck from the landward end, facing inland.

	The Y is the deck plus 3.8, which is what the old gates used over their pads
	and is a HumanoidRootPart's rough standing height plus a little slack -- the
	player lands a few inches up and settles, rather than being posted into the
	planking. Off-centre on the opposite side to the ferryman so an arrival never
	lands inside him.

	BOTH DIRECTIONS ARE DERIVED. This was one subtraction and a fixed +Z heading
	while every berth happened to face the same way; the beach's now faces the
	other, and a fixed heading there would have put the arrival six studs the
	wrong side of the landward end -- which on that shore is inside a lifeguard
	tower.
]]
local function arrivalCFrame(port, deckY: number): CFrame
	local dir = FerryConfig.dirOf(port)
	local side = ((port.dock.boatX or 13) >= 0) and 1 or -1
	local at = Vector3.new(port.dock.x - side * 2.4, deckY + 3.8, FerryConfig.arrivalZ(port))
	return CFrame.lookAt(at, at - Vector3.new(0, 0, dir))
end

----------------------------------------------------------------
-- WHICH BERTH SOMEBODY IS STANDING AT
----------------------------------------------------------------
-- Nearest talk anchor inside FerryConfig.TalkRange, or nil. This is the whole
-- of the "are you allowed to book a crossing" test, and it is deliberately
-- positional: it cannot be lied to, and it means a player who walks away with
-- the panel open loses the ride rather than keeping a remote that works from
-- anywhere for the rest of the session.
local function berthAt(player: Player)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return nil
	end
	local best, bestDist = nil, FerryConfig.TalkRange
	for _, berth in pairs(berths) do
		local anchor = berth.talkAnchor
		if anchor and anchor.Parent then
			local d = (anchor.Position - hrp.Position).Magnitude
			if d <= bestDist then
				best, bestDist = berth, d
			end
		end
	end
	return best
end

----------------------------------------------------------------
-- THE CROSSING
----------------------------------------------------------------
--[[
	TAKING A CHARACTER OFF ITS OWN FEET, AND GIVING IT BACK.

	Anchored plus PlatformStand, and both halves are load-bearing. Anchoring
	alone leaves the Humanoid still running its state machine against a body
	that will not move, which comes out as a passenger jogging on the spot all
	the way to the dunes; PlatformStand alone leaves the body under physics,
	which comes out as a passenger falling through a boat that is moving faster
	than they are.
]]
--[[
	HOW FAR A PASSENGER MAY WANDER FROM THE SPOT THE BOAT CARRIES THEM ON.

	The leash is what replaced the anchor. It is a little under half the Deck's
	18.4 studs, so there is room to move about and jump on the spot, and none to
	walk off the side into open water half way to the dunes.

	The ceiling is what a jump is ALLOWED to be. R15's default JumpHeight is 7.2
	and the clamp only ever pulls DOWNWARD, so 9 is high enough that it never
	touches an ordinary jump and low enough that nothing can climb off the top of
	the cabin while the hull is moving under it.
]]
local RIDER_LEASH = 7
local RIDER_CEILING = 9

local function seize(char: Model?): (BasePart?, Humanoid?)
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return nil, nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		-- Somebody who booked a crossing from the seat of an ATV. A passenger
		-- still welded to a quad drags the whole vehicle across the map.
		hum.Sit = false
		--[[
			NEITHER ANCHORED NOR PLATFORM-STOOD ANY MORE, and the old note here
			was right about why both used to be: anchoring alone left the Humanoid
			running its state machine against a body that would not move, which
			came out as a passenger jogging on the spot all the way to the dunes;
			PlatformStand alone left them under physics, which came out as a
			passenger falling through a boat moving faster than they were.

			Both of those are the same fault seen twice -- NOTHING WAS CARRYING
			THEM. The hull is tweened rather than sailed, so it imparts no motion
			to anything standing on it, and the fix was to stop them being a thing
			that stands. `run` carries them explicitly now (see the leash there),
			which leaves the Humanoid free to do what it likes on top -- walk a
			couple of steps, turn round, and jump.

			Reported 2026-09-15: "cant jump when taking sail boat".
		]]
		hum.PlatformStand = false
	end
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	hrp.Anchored = false
	return hrp, hum
end

local function release(player: Player)
	local char = player.Character
	if not char then
		return
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		hrp.Anchored = false
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = false
	end
end

-- The lines come off before she leaves and go back on when she is tied up.
-- Hidden rather than destroyed: they are two parts built once by FerryBuilder
-- and they have to be there for the next crossing.
local function setLines(berth, on: boolean)
	for _, rope in ipairs(berth.lines or {}) do
		if rope.Parent then
			rope.Transparency = on and 0 or 1
		end
	end
end

-- Foam off the stern, on only while she is actually moving. Enabled rather
-- than Emit()ed: a server-side Emit does not replicate at all. FerryBuilder's
-- addWake records the whole of that.
local function setWake(boat: Model?, on: boolean)
	local wake = boat and boat:FindFirstChild("Wake")
	local foam = wake and wake:FindFirstChildOfClass("ParticleEmitter")
	if foam then
		foam.Enabled = on
	end
end

-- Spray off the bow, on only for the rough half of a leg. Written on a change
-- rather than every frame: `run` calls this at 60 Hz and an unconditional
-- assignment is sixty replicated property writes a second for nothing.
local function setSpray(vessel, on: boolean)
	if vessel.sprayOn == on then
		return
	end
	vessel.sprayOn = on
	local boat = vessel.model
	local spray = boat and boat:FindFirstChild("Spray")
	local burst = spray and spray:FindFirstChildOfClass("ParticleEmitter")
	if burst then
		burst.Enabled = on
	end
end

--[[
	A VESSEL IS THE BOAT ONE PARTICULAR CROSSING IS DRIVING, AND IT EXISTS
	BECAUSE TWO CROSSINGS MUST NOT DRIVE THE SAME HULL.

	THE BUG IT FIXES. Every animation in this file used to read `berth.boat`, so a
	crossing owned the berth's one boat for its whole length -- and `request`
	turned everybody else away with "She's out on the water" for as long as it
	lasted. Measured: the destination berth is held for the full trip plus the
	swing, about nine to eleven seconds, and the Beach is one end of nearly every
	route. A player reported it on 2026-09-11 at rebirth 3 -- "no me deja viajar en
	barco porque me sale que ella está navegando" -- and being refused the ferry is
	being refused the whole map, which is the one thing this game cannot afford:
	MapUnlocks says two thirds of players never reach the second island as it is.

	SIMPLY DROPPING THE CHECK WOULD BREAK IT. The far boat is teleported out to sea
	with the arriving passenger aboard (step 5 of voyage), so a second player
	casting off from that berth at the same moment would board a hull that is about
	to be moved out from under them -- two coroutines PivotTo-ing one model.

	SO THE CROSSING BRINGS ITS OWN BOAT WHEN IT HAS TO.

	  The berth's boat is FREE   ->  the crossing uses it. One boat, exactly as
	                                 before. This is the overwhelmingly common
	                                 case and it is pixel-for-pixel unchanged.
	  The berth's boat is OUT    ->  the crossing sails a CLONE instead, and the
	                                 moored one stays where it is.

	So the fiction of one boat holds whenever it can, and where it cannot the
	player sees a second boat rather than a closed door. Nobody is ever refused.

	THE CLONE IS NOT CALLED "Boat", and that is not cosmetic. FerryClient's idle
	swell finds rigs with `berth:FindFirstChild("Boat")` and animates that model's
	parts locally; two children by that name would make the lookup a coin toss and
	leave the moored boat stiff while a clone bobbed. A hull under way is driven by
	`run` and wants no idle rig at all.
]]
local function acquireVessel(berth)
	if not berth.busy then
		berth.busy = true
		return { model = berth.boat, berth = berth, mine = true }
	end
	local source = berth.boat
	if not (source and source.Parent) then
		-- No hull to copy. The crossing still runs -- the passenger is carried by
		-- CFrame, not by the boat -- it just has nothing to stand on. Better a
		-- strange-looking trip than a refusal.
		return { model = nil, berth = berth, mine = false }
	end
	local clone = source:Clone()
	clone.Name = "BoatUnderway"
	clone.Parent = source.Parent
	return { model = clone, berth = berth, mine = false }
end

local function easeIn(u: number): number
	return u * u                      -- off a pier: slow, then gathering way
end

local function easeOut(u: number): number
	local v = 1 - u
	return 1 - v * v                  -- into a berth: carrying way, then stopping
end

local function linear(u: number): number
	return u                          -- out in it: no acceleration to speak of
end

--[[
	THE SEA STATE, and it is the whole of what the crossing was missing.

	`swell` is a POSE, added on top of wherever the run has got the boat to.
	Four motions at four deliberately unrelated periods, so they never line up
	into a metronome: heave (up and down on the water), pitch (her bow into it),
	roll (beam-on) and a slow yaw wander, as if the sea keeps pushing her off
	her line and she keeps coming back to it.

	AMPLITUDE IS A PARAMETER, NOT A CONSTANT, and that is the point of the
	whole rewrite. `rough` runs 0 in the lee of an island and 1 out past the
	point, so the identical function draws a boat sliding out of a sheltered
	berth and a boat being thrown about, and everything in between is
	continuous -- no beat starts or stops, the water just gets up.

	ROLL IS ABOUT HER LENGTH AND PITCH IS ABOUT HER BEAM. She is built
	long-ways along local X with her beam on local Z, so roll is a rotation
	about X and pitch is one about Z. The other way round gives a boat
	see-sawing end over end sideways, which is the one mistake here that looks
	like a bug rather than like weather.

	WHY THE PLAYER GOES WITH IT, and why this is server-side. The rider's
	CFrame is the boat's finished pose times a fixed offset, written in the
	same frame of the same loop -- so he pitches exactly when she pitches and
	the two cannot drift. Done on the client instead, the boat would heave
	under a player the server still had standing flat on the water.
]]
local HEAVE = 1.5                     -- studs, at the top of a swell
local PITCH = 0.20                    -- radians, bow up
local ROLL = 0.14                     -- radians, beam on
local YAW = 0.10                      -- radians, shoved off her line

local function swell(t: number, rough: number): CFrame
	if rough <= 0.001 then
		return CFrame.identity
	end
	local heave = math.sin(t * 2.1) * 0.62 + math.sin(t * 3.7 + 1.1) * 0.38
	local pitch = math.sin(t * 2.4 + 0.6) * 0.7 + math.sin(t * 1.3) * 0.3
	local roll = math.sin(t * 1.7 + 2.2)
	local yaw = math.sin(t * 0.9 + 0.4)
	return CFrame.new(0, heave * HEAVE * rough, 0)
		* CFrame.Angles(0, yaw * YAW * rough, 0)
		* CFrame.Angles(roll * ROLL * rough, 0, pitch * PITCH * rough)
end

--[[
	HOW FAR ALONG SHE ACTUALLY IS, once the sea has had its say.

	Progress used to be a plain ease. Out in the swell it is a FIGHT: she
	drives, a wave stops her, she gives a little back, and she goes again. This
	is that -- the ease with a wobble laid over it, scaled by `rough` so the
	two sheltered beats are left exactly as they were.

	ENVELOPED AND CLAMPED, and both are load-bearing. The envelope dies away at
	u = 0 and u = 1 so she never surges off her own mooring or lurches at the
	moment of tying up; the clamp is what stops a shove near the end of the run
	IN putting her past the berth and through her own pier.
]]
local function surgeAt(u: number, rough: number, ease): number
	local base = ease(u)
	if rough <= 0.001 then
		return base
	end
	local envelope = math.sin(u * math.pi) ^ 0.7
	local kick = math.sin(u * math.pi * 5.2) * 0.055
		+ math.sin(u * math.pi * 2.3 + 1.0) * 0.038
	return math.clamp(base + kick * envelope * rough, 0, 1)
end

--[[
	Drive one boat, and whoever is standing on her, from `a` to `b`.

	ONE LOOP RATHER THAN A TWEEN, because a TweenService tween drives one
	instance's properties and there are two things here that have to agree to
	the frame: the boat and the passenger standing on her deck. Tweened
	separately they drift by a frame's worth of easing and the player's feet
	slide about on the planks. That was true before the sea state and it is
	twice as true now -- there is no tween that produces `swell` at all.

	`roughA` -> `roughB` is the sea over the length of THIS leg, lerped. A
	crossing is four of these: calm to building, building to full, full to
	dropping, dropping to calm.

	The rider is re-resolved every frame and only written if their root is
	still anchored, so a player who dies or respawns mid-run is simply left
	behind by the boat rather than being flown along as a corpse.

	WAKE ON, NEVER OFF. Two legs a side means turning it off at the end of a
	run would blink the foam out in the middle of the crossing; `voyage` owns
	switching it off, and `restore` catches the case where the crossing died.
]]
local function run(vessel, player: Player, a: CFrame, b: CFrame, seconds: number,
	ease, roughA: number, roughB: number)

	local boat = vessel.model
	local berth = vessel.berth
	setWake(boat, true)
	local t0 = os.clock()
	while true do
		local now = os.clock()
		local u = math.clamp((now - t0) / seconds, 0, 1)
		local rough = roughA + (roughB - roughA) * u
		setSpray(vessel, rough > 0.45)

		local cf = a:Lerp(b, surgeAt(u, rough, ease)) * swell(now, rough)
		if boat and boat.Parent and boat.PrimaryPart then
			boat:PivotTo(cf)
		end
		--[[
			CARRIED, NOT PINNED -- which is the whole of letting them jump.

			This line used to be `hrp.CFrame = cf * berth.riderOffset` behind an
			`hrp.Anchored` guard: the passenger was welded to one spot on the hull
			and rewritten there every frame, so any jump they started was undone
			before it drew.

			Now the rider point is a LEASH rather than a position. Horizontally
			they are pulled back to within RIDER_LEASH of it, which is what keeps
			them aboard a hull that is teleporting rather than sailing. VERTICALLY
			the clamp only ever pushes DOWN -- off.Y is read from where they
			actually are, so a jump in progress is preserved and gravity brings it
			back to the deck on its own.

			The floor at 0 is doing a second job: it is why they cannot fall
			through a hull that moves faster than physics can follow, which is the
			fault the anchor was there to prevent. Collision with the Deck part
			still happens and still feels right; this is the guarantee underneath
			it.

			ROTATION IS LEFT ALONE. Pinning took the boat's heading with it and
			spun the passenger through every turn; carrying lets them face wherever
			they are looking, which is what anybody standing on a deck expects.
		]]
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") and not hrp.Anchored then
			local want = (cf * berth.riderOffset).Position
			local off = hrp.Position - want
			local flat = Vector3.new(off.X, 0, off.Z)
			if flat.Magnitude > RIDER_LEASH then
				flat = flat.Unit * RIDER_LEASH
			end
			local lift = math.clamp(off.Y, 0, RIDER_CEILING)
			hrp.CFrame = CFrame.new(want + flat + Vector3.new(0, lift, 0))
				* (hrp.CFrame - hrp.CFrame.Position)
		end
		if u >= 1 then
			return
		end
		RunService.Heartbeat:Wait()
	end
end

--[[
	THE FIVE POSES OF A BERTH.

	Three points on one line out -- the mooring, the edge of the shelter, and
	the sea -- taken in either of two headings. `heading` is bow-to-sea, which
	is how she waits and how she leaves; `headingIn` is the same berth the
	other way about, which is how she ARRIVES. Without the second set the half
	of every crossing a player actually watches is sailed backwards.
]]
local function seaCF(berth): CFrame
	return CFrame.new(FerryConfig.seaPos(berth.port)) * FerryConfig.heading(berth.port)
end

local function midCF(berth): CFrame
	return CFrame.new(FerryConfig.midPos(berth.port)) * FerryConfig.heading(berth.port)
end

local function seaInCF(berth): CFrame
	return CFrame.new(FerryConfig.seaPos(berth.port)) * FerryConfig.headingIn(berth.port)
end

local function midInCF(berth): CFrame
	return CFrame.new(FerryConfig.midPos(berth.port)) * FerryConfig.headingIn(berth.port)
end

local function moorInCF(berth): CFrame
	return CFrame.new(berth.moorCF.Position) * FerryConfig.headingIn(berth.port)
end

-- How long she takes to swing round at her berth after landing bow-in.
local SWING = 1.9

--[[
	Put a berth back exactly as it was found: boat on her mooring in the pose
	the next departure wants her in, lines on, free to be booked again. Called
	from `finish` whatever happened.

	`swing` is the only optional part. An arriving boat berths BOW-IN, which is
	the wrong way round to leave, so somebody has to turn her -- and by then
	the player is stood on the planks watching, so a snap reads as the boat
	glitching. Turned by hand through an explicit half circle rather than by
	CFrame:Lerp: a 180 degree rotation has no unique interpolation axis, and
	which one the slerp picks is not something to leave to chance in front of
	the player. `finish` calls this WITHOUT the swing, so a crossing that died
	half way still snaps the berth straight rather than blocking on an
	animation nobody is watching.
]]
local function restore(berth, swing: boolean?)
	local boat = berth.boat
	if boat and boat.Parent and boat.PrimaryPart then
		if swing then
			local pos = berth.moorCF.Position
			local rot = berth.moorCF.Rotation
			local t0 = os.clock()
			while boat.Parent and boat.PrimaryPart do
				local u = math.clamp((os.clock() - t0) / SWING, 0, 1)
				boat:PivotTo(CFrame.new(pos) * rot
					* CFrame.Angles(0, math.pi * (1 - easeOut(u)), 0))
				if u >= 1 then
					break
				end
				RunService.Heartbeat:Wait()
			end
		end
		if boat.Parent and boat.PrimaryPart then
			boat:PivotTo(berth.moorCF)
		end
	end
	setLines(berth, true)
	setWake(berth.boat, false)
	-- The emitter directly rather than setSpray: that one dedupes against a
	-- VESSEL's own flag, and this is the berth putting its own boat to bed. A
	-- vessel's flag has nothing to say about a hull that is no longer sailing.
	do
		local spray = berth.boat and berth.boat:FindFirstChild("Spray")
		local burst = spray and spray:FindFirstChildOfClass("ParticleEmitter")
		if burst then
			burst.Enabled = false
		end
	end
	berth.busy = false
end

--[[
	GIVE THE BOAT BACK. The mirror of acquireVessel -- see its note.

	The berth's OWN boat is moored again, lines on, exactly as it always was.
	A clone is destroyed: it was only ever scenery carrying one passenger, the
	passenger has been put ashore by the time this runs, and the berth it arrived
	at already has a boat tied up at that mooring.

	SAFE TO CALL TWICE. sail()'s tidy-up runs it on every path out of a crossing,
	including the ones voyage has already taken -- a second release on a clone that
	is already gone, or a berth that is already moored, has to be a no-op rather
	than a second swing.
]]
local function releaseVessel(vessel, swing: boolean?)
	if not vessel or vessel.released then
		return
	end
	vessel.released = true
	if vessel.mine then
		restore(vessel.berth, swing)
	elseif vessel.model and vessel.model.Parent then
		vessel.model:Destroy()
	end
end

local function voyage(player: Player, from, to, vessels)
	local trip = FerryConfig.Trip

	local hrp = seize(player.Character)
	if not hrp then
		return
	end

	-- One hull for the leg out, one for the leg in -- the same two-boat handoff
	-- this has always used, except that each side is now a VESSEL rather than the
	-- berth's boat directly, so a second crossing on the same route brings its own
	-- rather than fighting for this one. Handed back through `vessels` so sail()'s
	-- tidy-up can release whatever this function had in hand when it stopped.
	vessels.out = acquireVessel(from)
	local outward = vessels.out

	-- 1. ABOARD. Stood on her deck, lines off.
	hrp.CFrame = from.moorCF * from.riderOffset
	setLines(from, false)
	task.wait(trip.board)

	-- 2. CAST OFF. Out of the berth and down the island's lee, and it is
	--    smooth: the sea only starts to come up at the very end of this.
	run(outward, player, from.moorCF, midCF(from), trip.cast, easeIn, 0, 0.35)

	-- 3. THE FIGHT. Past the point, and the water gets hold of her. Full
	--    roughness by the end, and no easing on the run -- out here she is
	--    making way against it rather than accelerating away from anything.
	run(outward, player, midCF(from), seaCF(from), trip.fight, linear, 0.35, 1)
	setWake(outward.model, false)
	setSpray(outward, false)

	-- 4. THE CUT. The client is already going dark on its own clock; this side
	--    only has to be somewhere else by the time it comes back.
	task.wait(trip.fade)
	releaseVessel(outward)

	--[[
		Ask for the far shore to stream in WHILE the screen is still dark.
		StreamingEnabled is on and these berths are 1500+ studs apart, so
		without this the veil lifts on an empty void for a second or two --
		exactly the bug the vault's transition documents. Asked for around the
		point out at SEA rather than around the pier, because that is where the
		player actually reappears.
	]]
	local toSea = seaInCF(to)
	pcall(function()
		player:RequestStreamAroundAsync(toSea.Position, 12)
	end)

	if not (player.Parent and player.Character) then
		return
	end

	-- 5. THE FAR BOAT, out on the water with them aboard her, and already
	--    turned for home so the veil lifts on a bow pointing at the island.
	vessels["in"] = acquireVessel(to)
	local inward = vessels["in"]
	if inward.model and inward.model.Parent and inward.model.PrimaryPart then
		inward.model:PivotTo(toSea)
	end
	setLines(to, false)
	-- Through `seize` again rather than a bare Anchored: a player who died and
	-- respawned during the dark has a BRAND NEW Humanoid, and that one has
	-- never been told to stop trying to walk.
	hrp = seize(player.Character)
	if not hrp then
		return
	end
	hrp.CFrame = toSea * to.riderOffset
	remotes.FerryTrip:FireClient(player, { phase = "in" })
	task.wait(trip.hold)

	-- 6. THE SURGE. The roughest water of the crossing, and the player is
	--    dropped straight into the middle of it -- the veil lifts on a boat
	--    already fighting rather than on one setting off.
	run(inward, player, toSea, midInCF(to), trip.surge, linear, 1, 0.4)

	-- 7. IN. Into the lee of the far island, the sea drops away, and she runs
	--    down onto her berth and ties up.
	run(inward, player, midInCF(to), moorInCF(to), trip.come, easeOut, 0.4, 0)
	setWake(inward.model, false)
	setSpray(inward, false)
	setLines(to, true)
	task.wait(trip.land)

	-- 8. ASHORE.
	release(player)
	local c = player.Character
	if c and c.PrimaryPart then
		c:PivotTo(arrivalCFrame(to.port, to.deckY))
	end
	pcall(function()
		player:RequestStreamAroundAsync(to.moorCF.Position, 6)
	end)

	-- 9. and the boatman swings her round for the next one.
	releaseVessel(inward, true)
end

local function sail(player: Player, from, to)
	local char = player.Character
	if not (char and char.PrimaryPart) then
		tell(player, false, "Catch your breath first.")
		return
	end

	sailing[player] = os.clock()
	-- The berths are NOT marked busy here any more. acquireVessel takes that
	-- decision per leg, at the moment each leg starts, and its answer is which
	-- hull to sail rather than whether anyone else may sail at all.
	local vessels = {}

	remotes.FerryTrip:FireClient(player, {
		phase = "out",
		caption = string.upper(to.port.name),
		line = from.port.ferryman.depart,
	})

	task.spawn(function()
		local ok, err = pcall(voyage, player, from, to, vessels)
		if not ok then
			warn("[Ferry] the crossing threw: " .. tostring(err))
		end

		--[[
			FINISH, and it runs on every path out of the above. Nobody may be left
			anchored to a boat that is no longer under them, and no hull may be left
			out at sea by a crossing that has stopped happening.

			WHATEVER THIS CROSSING HAD IN HAND, and only that. It used to restore
			both berths unconditionally, which was safe when a crossing owned them
			both -- and would now drag another player's boat home from the middle of
			their own trip. releaseVessel is idempotent, so the legs voyage already
			finished cleanly are no-ops here.
		]]
		release(player)
		releaseVessel(vessels.out)
		releaseVessel(vessels["in"])
		sailing[player] = nil
		if player.Parent then
			remotes.FerryTrip:FireClient(player, { phase = "done" })
		end
	end)
end

--[[
	The one entry point a client can reach. Everything it is told is re-derived
	here: where they are, where they asked to go, and whether they may.
]]
function FerryServer.request(player: Player, destKey: any)
	local to = FerryConfig.port(destKey)
	if not to then
		return                          -- a malformed message, not a refusal
	end

	local last = sailing[player]
	if last and os.clock() - last < SAIL_COOLDOWN then
		return
	end

	local from = berthAt(player)
	if not from then
		tell(player, false, "You are not at a ferry.")
		return
	end

	local dest = berths[to.key]
	if not dest then
		tell(player, false, "That crossing is not running.")
		return
	end

	--[[
		NOBODY IS TURNED AWAY FOR SOMEBODY ELSE'S CROSSING ANY MORE.

		This used to refuse whenever either berth was busy -- "She's out on the
		water. Wait for her to come back in." -- on the reasoning that there is one
		boat at each end and she cannot be in two places. The reasoning was sound
		and the cost was not: the Beach is one end of nearly every route, a crossing
		holds the far berth for nine to eleven seconds, and at the six or seven
		players these servers actually run that is a door that is shut a great deal
		of the time. A player at rebirth 3 reported exactly this on 2026-09-11, and
		a refused ferry is a refused MAP -- the funnel already says two thirds of
		players never reach the second island.

		acquireVessel handles it where it belongs now: if the berth's boat is free
		the crossing takes it and nothing looks any different, and if it is already
		out the crossing sails a clone. See its note for why simply deleting this
		check without that would have put two crossings on one hull.

		The per-PLAYER guard above (SAIL_COOLDOWN) stays. That one stops somebody
		double-clicking themselves onto two boats at once, which is a different
		question and still worth answering.
	]]

	local blocked = FerryConfig.blockedReason(to, FerryConfig.levelOf(player), from.port.key)
	if blocked then
		-- The ferryman's own words first, then the number. He is the one being
		-- asked, and "Needs Sifter Lv.5." on its own reads like a form rejecting
		-- you rather than a man turning you down.
		if to.key == from.port.key then
			tell(player, false, from.port.ferryman.here)
		else
			tell(player, false, from.port.ferryman.refuse .. "  (" .. blocked .. ")")
		end
		return
	end

	sail(player, from, dest)
end

----------------------------------------------------------------
-- BUILD
----------------------------------------------------------------
local function bindPrompt(berth)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "FerryPrompt"
	-- "Sail", not "Talk": the prompt opens the destination list directly now,
	-- so what it offers is a crossing rather than a conversation. His name stays
	-- on the ObjectText -- he is still who you are dealing with.
	prompt.ActionText = "Sail"
	prompt.ObjectText = berth.port.ferryman.name
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	-- 19, up from 15. He used to stand twelve studs IN from the pier head and
	-- you met him half way down the planks; he is on the boat now, which is
	-- moored off the end and thirteen studs to one side, so the shortest
	-- possible walk-up is about thirteen studs and fifteen left almost no
	-- margin at all. Still comfortably inside FerryConfig.TalkRange (30), which
	-- is what actually decides whether a booking is allowed.
	prompt.MaxActivationDistance = 19
	-- Off for the same reason the shop counters have it off: the ferryman's own
	-- hat, his pole and the pier rail all sit between the camera and the anchor
	-- from perfectly reasonable places to stand.
	prompt.RequiresLineOfSight = false
	prompt.Parent = berth.talkAnchor

	table.insert(connections, prompt.Triggered:Connect(function(player)
		--[[
			The payload carries WHERE THEY ARE and nothing else.

			Not the level, not the prices, not which rows to grey out: the bar
			re-reads the player's own attributes every time it draws, exactly as
			the ATV showroom learned to. A one-shot push is correct the instant it
			is sent and wrong the moment anything changes -- buy the upgrade that
			opens the cove while the bar is open and a pushed level would still be
			refusing you.

			`near` is the exception, and it is GEOMETRY rather than state: where
			this man is standing. The bar closes itself when the player walks off
			and it has to measure that from HIM -- measured from the pier head
			instead, it shut itself the moment somebody stepped ashore off a
			crossing, because on the dunes that is forty-two studs away. Sent
			rather than derived, because under StreamingEnabled a ferryman on
			another island does not exist on that machine to be measured.
		]]
		remotes.FerryMenu:FireClient(player, {
			at = berth.port.key,
			near = berth.talkAnchor and berth.talkAnchor.Position or nil,
		})
	end))
end

function FerryServer.start()
	assert(RunService:IsServer(), "[Ferry] server-only")
	if started then
		return
	end
	started = true

	remotes = ensureRemotes()

	-- Idempotent: a second boot replaces the berths rather than stacking a
	-- second pier on top of the first, the same contract the island builders
	-- keep with their own folders.
	local old = workspace:FindFirstChild(FOLDER_NAME)
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = workspace

	local built = 0
	for _, port in ipairs(FerryConfig.Ports) do
		--[[
			Each berth in its own pcall. A pier that fails to build is one island
			you have to swim to; a throw here with three of them in one loop
			would take the other two down with it, and the beach's is the one
			everybody needs. The islands are wrapped the same way in CTB_Server
			and for the same reason.
		]]
		local ok, err = pcall(function()
			local deckY = deckHeightFor(port)
			local model, handles = FerryBuilder.build(port, deckY)
			model.Parent = folder

			local berth = {
				port = port,
				model = model,
				talkAnchor = handles.talkAnchor,
				deckY = deckY,
				-- Everything the crossing drives. All of it is measured by the
				-- builder, because the builder is the one that knows where the
				-- boat's deck actually is.
				boat = handles.boat,
				moorCF = handles.moorCF,
				riderOffset = handles.riderOffset,
				lines = handles.lines,
				busy = false,
			}
			berths[port.key] = berth
			bindPrompt(berth)
			built += 1
		end)
		if not ok then
			warn(string.format("[Ferry] the %s berth failed to build: %s", port.key, tostring(err)))
		end
	end

	table.insert(connections, remotes.FerrySail.OnServerEvent:Connect(function(player, destKey)
		FerryServer.request(player, destKey)
	end))

	table.insert(connections, Players.PlayerRemoving:Connect(function(player)
		sailing[player] = nil
	end))

	local names = {}
	for _, port in ipairs(FerryConfig.Ports) do
		local b = berths[port.key]
		if b then
			-- "Lv.%d" until the ports moved onto the Rebirths counter. A boot log
			-- naming the wrong unit is how a stale gate survives a read-through.
			table.insert(names, string.format("%s (deck y=%.2f, %d %s)",
				port.key, b.deckY, port.requireLevel,
				port.requireLevel == 1 and "rebirth" or "rebirths"))
		end
	end
	print(string.format("[Ferry] %d/%d berths: %s", built, #FerryConfig.Ports,
		table.concat(names, ", ")))
end

FerryServer.berths = berths

return FerryServer
