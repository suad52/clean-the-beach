--[[
	AfkBus  --  ServerScriptService.AfkBus

	⚠️ ANYTHING THAT MOVES A PLAYER OUT OF THE LONG SHORE MUST COME THROUGH HERE.

	This exists because of a specific bug in the same feature in Seal A Driveway,
	and the shape of it is worth stating so nobody has to rediscover it:

		A visit is not the character's POSITION. It is the AfkPlot attribute, the
		bay held in the service's table, the client's input sinks and the client's
		walk loop. Teleport the character out without ending the visit and every
		one of those stays live -- the bay stays held, the puppet keeps steering
		toward waypoints eight thousand studs away, and the player arrives
		wherever they were sent unable to move, because the sinks are still
		swallowing their keys.

		That is exactly what happened there: an idler who clicked a Join button --
		a click being the one input a visit does not sink -- arrived in the arena
		frozen. Measured 59 studs of drift in 7 seconds, wrong walk speed, wrong
		tool, all three input binds still connected.

	So: call `AfkBus.wake(plr)` FIRST, then do your teleport. wake() ends the
	visit WITHOUT moving them -- you are doing that -- and answers the CFrame the
	shore would have sent them home to.

	THAT RETURN VALUE IS LOAD-BEARING for anything that restores a player
	afterwards. Snapshot it as the place to put them back, not where they are
	standing: restoring an idler to where they were standing drops them back on
	the shore with no visit -- not earning, not walked, and the GO BACK prompt a
	no-op on them, since leave() early-returns when there is no visit.

	Register/ask shape, like every other bus here: AfkService provides, callers
	ask, and neither has to require the other.
]]

local AfkBus = {}

local provider = nil

function AfkBus.provide(impl)
	provider = impl
end

-- True while the player is on the shore. Safe before AfkService has started.
function AfkBus.isIdle(plr: Player): boolean
	if not provider or not provider.isIdle then
		return false
	end
	local ok, res = pcall(provider.isIdle, plr)
	return ok and res == true
end

--[[
	End the visit without moving them, and answer where home was.

	Returns nil when the player was not idle, which is the common case and is
	not an error -- callers should treat nil as "nothing to do" and carry on
	with their own teleport.
]]
function AfkBus.wake(plr: Player): CFrame?
	if not provider or not provider.wake then
		return nil
	end
	local ok, res = pcall(provider.wake, plr)
	if not ok then
		warn("[AfkBus] wake failed: " .. tostring(res))
		return nil
	end
	return res
end

return AfkBus
