--[[
	BadgeConfig  --  ReplicatedStorage.Modules.BadgeConfig

	ROBLOX BADGES, which this game had none of. BadgeService was not called
	anywhere in the place, and the game has 48 tides, nine islands and 205 index
	items with nothing marking any of it.

	WHY THEY ARE WORTH HAVING beyond the obvious: a badge is the only reward in
	the game that is visible from OUTSIDE it. Roblox lists them on the experience
	page and on the player's own profile, so they are simultaneously a goal, a
	completion hook, and the only thing here that advertises the game to somebody
	who has not played it.

	EVERY ID IS 0 UNTIL YOU CREATE IT. A badge cannot be made from code -- it is
	created in the Creator Dashboard (Communication -> Badges) and costs 100
	Robux each. BadgeService says at boot which of these are still uncreated and
	names them, exactly the way ProductServer does for the developer product it
	cannot sell. Paste the id in here and it starts awarding; nothing else needs
	touching.

	THE GATES ARE REBIRTHS because the tide ladder is the spine of this game and
	FunnelConfig.MapRungs already gates every island on the same number -- so a
	player earning "The Vault" badge is earning it on the tide the Vault actually
	opens, and the two cannot drift apart without somebody meaning it.

	AWARDED ONCE, BY ROBLOX. BadgeService:AwardBadge is idempotent on their side
	-- a player who already has one is not re-awarded and no error is raised --
	so nothing here has to remember who has what.
]]

local BadgeConfig = {}

--[[
	  key       what this file calls it; used only in logs
	  id        the Creator Dashboard id. 0 means NOT CREATED YET.
	  name      what it is called on the Dashboard, for the boot warning
	  desc      the Dashboard description, kept here so the two cannot drift
	  rebirths  the tide at which it is earned
	  needsCar  true for the one that is not about tides at all

	FIVE, NOT TWENTY. A badge list that mirrors every rung of the ladder stops
	reading as an achievement and starts reading as a progress bar, and each one
	costs 100 Robux to create -- so these are the moments worth marking.

	SPACED SO MOST PLAYERS GET SOME. Two are reachable in a first session or two
	(tides 1 and 4), one sits where the shop opens (a machine needs 14 tides), one
	is the back half (22) and one is the end of the authored run (48). A list that
	was all late badges would be invisible to almost everybody who plays.

	PENGUIN ISLAND (tide 34) WAS CUT to get to five. It sat between Ashfall at 22
	and the end at 48 and was the least distinct of the six -- another "you
	reached an island" in a stretch that already had one. Motorised survived the
	cut instead because it is the only one that is not a tide count, and a list of
	five identical-shaped badges is duller than a list of four plus one.
]]
BadgeConfig.Badges = {
	{
		key = "FirstTide", id = 267142414838145, rebirths = 1,
		name = "Turn of the Tide",
		desc = "Turned the tide for the first time. The whole beach goes back to the "
			.. "sand -- and you come back worth more.",
	},
	{
		key = "Vault", id = 1755131910368322, rebirths = 4,
		name = "The Vault",
		desc = "Four tides deep. The treasure chamber under the island opens for you.",
	},
	{
		key = "Motorised", id = 2095216972494703, needsCar = true,
		name = "Motorised",
		desc = "Bought your first machine. No more raking the beach on foot.",
	},
	{
		key = "Ashfall", id = 1160646399548531, rebirths = 22,
		name = "Ashfall Isle",
		desc = "Twenty-two tides behind you, and the ground is still warm.",
	},
	{
		key = "EveryTide", id = 3671067209154016, rebirths = 48,
		name = "Rode Every Tide",
		desc = "Forty-eight tides. Every island swept, every ladder climbed. "
			.. "There is no more beach.",
	},
}

--[[
	True once somebody has pasted an id in. Anything at or below zero is the
	placeholder, and a non-number is a typo -- both read as "not created".

	THE INTEGER CHECK IS NOT PEDANTRY. Roblox badge ids are sixteen digits now
	(the five here run from 2.7e14 to 3.7e15), and Luau numbers are doubles --
	exact only up to 2^53, about 9.0e15. An id past that would be SILENTLY
	ROUNDED on the way into this table and then awarded as a badge that does not
	exist, failing inside BadgeService's pcall where nobody would ever see it.
	All five clear it today with room to spare; this is here so the day one does
	not, it is loud instead of invisible.
]]
function BadgeConfig.isLive(entry): boolean
	if type(entry) ~= "table" or type(entry.id) ~= "number" or entry.id <= 0 then
		return false
	end
	if entry.id ~= math.floor(entry.id) or entry.id > 2 ^ 53 then
		warn(string.format("[Badges] %s has an id this runtime cannot hold exactly "
			.. "(%s). It would be awarded as a different number -- check it.",
			tostring(entry.name), tostring(entry.id)))
		return false
	end
	return true
end

function BadgeConfig.live(): { any }
	local out = {}
	for _, entry in BadgeConfig.Badges do
		if BadgeConfig.isLive(entry) then
			table.insert(out, entry)
		end
	end
	return out
end

function BadgeConfig.pending(): { any }
	local out = {}
	for _, entry in BadgeConfig.Badges do
		if not BadgeConfig.isLive(entry) then
			table.insert(out, entry)
		end
	end
	return out
end

return BadgeConfig
