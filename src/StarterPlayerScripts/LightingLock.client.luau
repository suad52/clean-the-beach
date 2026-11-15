--[[
	LightingLock  --  StarterPlayer.StarterPlayerScripts.LightingLock  (LocalScript)

	ONE HOUR, held on this machine for the whole session -- and which hour is
	now something another client script is allowed to ask for.

	WHY A CLIENT-SIDE LOCK EXISTS AT ALL
	------------------------------------
	CTB_Server already pins Lighting.ClockTime to 12 and re-asserts it whenever
	anything writes it. That guard is server-side, and it is enough right up
	until something writes the clock on the PLAYER's machine -- which it cannot
	see and cannot correct.

	Something does. Measured in this place: with the server sitting at exactly
	12, the client read 1.5, then 3.0, then 4.5 across a few minutes -- walking
	forward in 1.5 hour steps while the server never moved. That is why the sky
	kept going dark despite the server-side lock. The prime suspect is the
	Studio weather plugin this place already fights over the skybox (see the
	note at the top of CTB_Server.applyLook), but the fix does not depend on
	knowing: anything that writes the clock locally is undone here.

	WHY IT IS RETARGETABLE NOW, AND WHY IT IS STILL A LOCK
	-----------------------------------------------------
	Sakura Cove is a golden-hour island. That is a PER-PLAYER look -- Lighting
	writes made on a client do not replicate, the same trick the Dunes' heat
	grade already runs on -- so Island3_Client wants the clock at 17 while the
	player is in the cove and back at 12 the moment they leave. Deleting the
	lock to allow that would hand the machine straight back to whatever is
	walking the clock forward, so the hour became a VARIABLE instead: both
	defences below are exactly as they were, they simply re-assert the CURRENT
	TARGET rather than a constant.

	Nothing that does not opt in sees any change. With no target set the target
	IS 12, which is what every script in this place got before.

	THE API
	-------
	One attribute on the LocalPlayer, which is how every other client script in
	this place already talks to the rest (RollerLevel, RollerBlocked,
	CurrentWeight, Coins -- all read with GetAttributeChangedSignal):

		local player = game:GetService("Players").LocalPlayer
		player:SetAttribute("CTB_ClockTarget", 17)     -- hold golden hour
		player:SetAttribute("CTB_ClockTarget", 12)     -- hand it back
		player:SetAttribute("CTB_ClockTarget", nil)    -- same thing; nil means noon

	The LocalPlayer rather than Lighting, on purpose. A Player is created fresh
	at runtime, so it cannot carry a stale value saved into the place file the
	way Lighting's own ClockTime already does -- that is sitting at 21:00 in the
	file and is half the reason this script exists. Client writes to it never
	replicate either, so the target is per player, which is the whole point.

	Anything that is not a number in [0, 24] is refused, warned about ONCE and
	held at noon: a typo in a caller must not be able to leave somebody sitting
	in the dark for a session. Once only, because a caller writing a bad value
	is usually writing it every frame.

	EASING IS THE CALLER'S JOB, and that is what makes easing possible at all.
	This script never tweens; it only ever drives ClockTime AT the target. So a
	caller eases by moving the TARGET -- write the attribute every frame with
	its own interpolated value and the clock follows it exactly, with nothing to
	fight over:

		local t0, from, to, dur = os.clock(), 12, 17, 2.4
		local conn
		conn = RunService.RenderStepped:Connect(function()
			local a = math.min((os.clock() - t0) / dur, 1)
			player:SetAttribute("CTB_ClockTarget", from + (to - from) * a)
			if a >= 1 then conn:Disconnect() end
		end)

	Had the ease been done in here against a target set once, the two would have
	been two writers on one property and which one won would have depended on
	which connection happened to fire last.

	WHY IT CANNOT FIGHT ITSELF
	--------------------------
	Assigning a property the value it already holds does not fire Changed, so
	the guard writing the target cannot re-trigger the guard. The only writes
	that cost anything are the ones putting it wrong.

	The heartbeat is a deliberate second line rather than superstition: the
	signal is what catches a writer, and the poll is what catches a value that
	arrives without one (a fresh replication pass on spawn, most of all). At
	2 seconds it is free. It re-READS the target as well as re-asserting it, so
	a target set before this script booted is picked up either way.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Pure replicated data: the three rungs the Settings row offers and which hour
-- each one forces. Required for hourFor alone -- see readTarget.
local DaylightConfig = require(ReplicatedStorage:WaitForChild("Modules")
	:WaitForChild("DaylightConfig"))

local player = Players.LocalPlayer

-- The one name callers use. Prefixed, because a bare "ClockTarget" on the
-- Player would sit in the same namespace as the game-state attributes the
-- server writes and this one is nobody's business but the client's.
local TARGET_ATTR = "CTB_ClockTarget"
local DEFAULT_HOUR = 12

local target = DEFAULT_HOUR
local warned = false

local function readTarget(): number
	--[[
		THE PLAYER'S OWN PREFERENCE FIRST, AND IT BEATS EVERY OTHER WRITER.

		This is the funnel every caller's target passes through, so applying the
		setting HERE rather than by writing TARGET_ATTR is what stops it being a
		fourth writer on a channel that already has three. Island3_Client blends
		the cove's golden hour by writing that attribute EVERY FRAME; a preference
		that wrote it too would lose the fight sixty times a second. Written this
		way the cove may say whatever it likes and a player who asked for night
		still gets night.

		nil FROM hourFor MEANS "DAY", which means stand aside -- not "force 12".
		That is the whole reason the default costs nothing: with it selected this
		block does nothing at all and the intro shot, the cove and Ashfall keep
		the lighting they were authored with. See DaylightConfig's header.
	]]
	local preferred = DaylightConfig.hourFor(player)
	if preferred ~= nil then
		return preferred
	end

	local v = player:GetAttribute(TARGET_ATTR)
	if v == nil then
		return DEFAULT_HOUR
	end
	-- `v ~= v` is the NaN test: NaN compares unequal to everything, so it would
	-- make hold()'s guard true forever and turn this into a write every frame.
	if type(v) ~= "number" or v ~= v or v < 0 or v > 24 then
		if not warned then
			warned = true
			warn(string.format("[LightingLock] %s = %s is not an hour in [0, 24]; holding %d",
				TARGET_ATTR, tostring(v), DEFAULT_HOUR))
		end
		return DEFAULT_HOUR
	end
	return v
end

local function hold()
	if Lighting.ClockTime ~= target then
		Lighting.ClockTime = target
	end
end

local function retarget()
	target = readTarget()
	hold()
end

-- ADOPT, do not overwrite. StarterPlayerScripts run in no guaranteed order, so
-- a script that set a target before this one booted must not have it thrown
-- away; only a Player carrying no target at all is stamped with the default,
-- and that is purely so the attribute is discoverable in the Explorer.
if player:GetAttribute(TARGET_ATTR) == nil then
	player:SetAttribute(TARGET_ATTR, DEFAULT_HOUR)
end
retarget()

player:GetAttributeChangedSignal(TARGET_ATTR):Connect(retarget)
-- The Settings row, and SaveService's restore landing after this script booted.
-- Same handler: both only ever mean "the answer readTarget gives has changed".
player:GetAttributeChangedSignal(DaylightConfig.Attribute):Connect(retarget)

Lighting:GetPropertyChangedSignal("ClockTime"):Connect(hold)
-- TimeOfDay is the same underlying value and writing it fires ClockTime's
-- signal too (verified in this place), so this is belt and braces rather than
-- a second mechanism.
Lighting:GetPropertyChangedSignal("TimeOfDay"):Connect(hold)

-- A respawn hands the client a fresh set of replicated property values.
player.CharacterAdded:Connect(hold)

local since = 0
RunService.Heartbeat:Connect(function(dt)
	since += dt
	if since < 2 then
		return
	end
	since = 0
	retarget()
end)
