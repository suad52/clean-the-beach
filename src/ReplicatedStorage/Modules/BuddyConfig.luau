--[[
	BuddyConfig  --  ReplicatedStorage.Modules.BuddyConfig

	BEACH BUDDIES: the sell bonus for having friends on your server.

	WHY THIS EXISTS. The game had no social loop at all -- no friend bonus, no
	invite prompt, nothing that rewarded bringing somebody or joining somebody.
	Virality is the only metric that feeds back into DAU, and trading was the
	only thing in the game that even needed a second person.

	ONE MORE TERM ON THE TILL'S STACK, and it is deliberately built the same way
	as the three before it. SellServer already multiplies by the rebirth figure,
	the 2x Cash pass, the live event and a bought Golden Hour, and the notes
	there are emphatic about why each one stays its own number: four screens make
	four promises, and folding any two together makes one of those screens lie.
	This is the fifth promise and it gets the same treatment.

	A CONFIG MODULE RATHER THAN A SERVICE, for the reason EventConfig and
	BoostConfig give at their own call sites: SellServer cannot require a service
	that pays through SellServer without building a cycle. This is pure
	replicated data plus one reader over a SERVER-WRITTEN attribute -- which a
	client cannot forge and the HUD can display.

	SERVER-WIDE, NOT PROXIMITY. The behaviour worth paying for is "join your
	friend's server", not "stand next to them" -- and a proximity rule would
	quietly tax normal play, where two friends rake different fields.

	THE NUMBERS. A tenth each, up to four. The cap is what keeps it a bonus
	rather than the whole economy: a server that happens to be full of one
	friend group would otherwise hand everyone in it +200% on top of a rebirth
	multiplier that already reaches 819x. At the cap this is x1.4, which is worth
	going out of your way for and is still smaller than the 2x Cash pass -- the
	thing players actually pay for should stay the bigger number.

	IT IS SYMMETRIC AND THAT IS ON PURPOSE. Both sides of a friendship get the
	bonus, so inviting somebody helps you as much as it helps them. Two alt
	accounts can farm a tenth of a multiplier off each other; that costs a second
	client to run and is bounded by the cap, which is a worse deal than simply
	playing, so there is nothing here to defend against.
]]

local BuddyConfig = {}

-- Written by BuddyService on the server, read here and by the HUD. Never
-- written by a client; the till reads it through multiplierFor below.
BuddyConfig.Attribute = "BuddyCount"

BuddyConfig.PerBuddy = 0.10
BuddyConfig.MaxBuddies = 4

-- What to call it on screen, in one place so the HUD and the toast agree.
BuddyConfig.Name = "Beach Buddies"

function BuddyConfig.countFor(player: Instance?): number
	if typeof(player) ~= "Instance" then
		return 0
	end
	local n = player:GetAttribute(BuddyConfig.Attribute)
	if type(n) ~= "number" or n ~= n or n < 0 then
		return 0
	end
	return math.min(math.floor(n), BuddyConfig.MaxBuddies)
end

--[[
	The till's fifth multiplier. 1 when nobody you know is here, which is the
	common case -- and returning exactly 1 rather than 1.0-something matters,
	because SellServer only applies a term when it is greater than 1 and only
	advertises it when it applied.
]]
function BuddyConfig.multiplierFor(player: Instance?): number
	return 1 + BuddyConfig.countFor(player) * BuddyConfig.PerBuddy
end

return BuddyConfig
