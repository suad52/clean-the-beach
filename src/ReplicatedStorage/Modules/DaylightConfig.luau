--[[
	DaylightConfig  --  ReplicatedStorage.Modules.DaylightConfig

	WHAT HOUR THIS PLAYER HAS ASKED THE SKY TO SIT AT, if any.

	Asked for on 2026-09-11: "Can you make it night time option? the light from
	the sand area hurts my eyes" -- a desktop player three tides in, forty-six
	minutes that session. The complaint is real and visible: the game pins noon
	(CTB_Server sets Lighting.ClockTime = 12 and re-asserts it), Brightness is
	3.1, and the whole playfield is pale sand. Somebody looking at that for an
	hour is entitled to ask for the lights down.

	THREE RUNGS, AND "DAY" IS NOT AN HOUR
	-------------------------------------
		DAY    hour = nil  -- no override at all
		DUSK   hour = 17   -- the golden hour the Cove already uses
		NIGHT  hour = 0

	DAY BEING NIL IS THE LOAD-BEARING PART. The clock is a shared channel --
	LightingLock holds Lighting.ClockTime at whatever CTB_ClockTarget says, and
	Island3_Client, Island4_Client and IntroCinema all drive that attribute, the
	Cove writing it EVERY FRAME while its golden-hour blend moves. A "Day" that
	meant "force 12" would be a fourth writer fighting those three: the cove
	would stop looking like the cove and the opening shot would lose its dawn.
	nil means this file stands aside and the game behaves exactly as it always
	has, which is why it is the default.

	AND WHEN IT IS NOT NIL IT WINS OUTRIGHT. LightingLock applies it in
	readTarget, downstream of every one of those writers, so the cove may write
	17 sixty times a second and a player who asked for night still gets night.
	That is the intended precedence rather than an accident of ordering: somebody
	who turned the lights down because bright sand hurts should not have an
	island turn them back up.

	THE VALUE STORED IS THE KEY, NOT THE HOUR. SettingsServer's whitelist
	compares values for equality, and hours would make "Day" and "Night"
	indistinguishable the moment somebody wanted a midnight that was not zero.
	The key also survives a retune of what DUSK means.
]]

local DaylightConfig = {}

-- Written by the Settings panel as `Set_Daylight`; SettingsServer's PREFIX plus
-- the row's key. Named here so the string exists once.
DaylightConfig.SettingKey = "Daylight"
DaylightConfig.Attribute = "Set_Daylight"

DaylightConfig.Steps = {
	{ key = "Day", label = "DAY", hour = nil },
	--[[
		17 because that is the hour the Cove already calls golden
		(Island3_Client's HOUR_COVE), not a number picked here. A player who wants
		the glare down without the lights out gets the light the game has already
		tuned a whole island around.
	]]
	{ key = "Dusk", label = "DUSK", hour = 17 },
	--[[
		MIDNIGHT, AND IT IS NOT PITCH BLACK. Measured on the home beach at
		ClockTime 0: the sand goes muted, the shop signs stay legible and every
		building in the row is readable -- Brightness 3.1 and the lit props carry
		it. 21:00 was tried too (the stale value that used to sit in the place
		file) and is barely darker than dusk.
	]]
	{ key = "Night", label = "NIGHT", hour = 0 },
}

DaylightConfig.Default = "Day"

DaylightConfig.StepByKey = {}
for i, step in ipairs(DaylightConfig.Steps) do
	step.index = i
	DaylightConfig.StepByKey[step.key] = step
end

-- The set SettingsServer whitelists. Built from the table above so a rung added
-- there cannot be one the server then refuses to save.
function DaylightConfig.values(): { [any]: boolean }
	local set = {}
	for _, step in ipairs(DaylightConfig.Steps) do
		set[step.key] = true
	end
	return set
end

-- The step this player is on. Anything unrecognised -- a key from a build that
-- had different rungs, or nothing at all -- reads as the default rather than as
-- an error, because the failure mode of a lighting preference must be ordinary
-- daylight.
function DaylightConfig.stepFor(player: Instance?)
	if typeof(player) == "Instance" then
		local v = player:GetAttribute(DaylightConfig.Attribute)
		local step = (type(v) == "string") and DaylightConfig.StepByKey[v] or nil
		if step then
			return step
		end
	end
	return DaylightConfig.StepByKey[DaylightConfig.Default]
end

--[[
	The hour to force, or NIL to leave the clock alone.

	NIL IS AN ANSWER, not a failure -- see the header. Callers must test for it
	rather than falling back to a number of their own, or "Day" becomes a fourth
	writer on a channel that already has three.
]]
function DaylightConfig.hourFor(player: Instance?): number?
	return DaylightConfig.stepFor(player).hour
end

return DaylightConfig
