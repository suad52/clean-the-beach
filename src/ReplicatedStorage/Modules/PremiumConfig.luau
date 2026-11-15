--[[
	PremiumConfig  --  ReplicatedStorage.Modules.PremiumConfig

	WHAT ROBLOX PREMIUM IS WORTH IN THIS GAME, which until now was nothing.
	MembershipType was read in exactly one place -- FeedbackServer, so a report
	could say whether the sender had it -- and nowhere at all as a benefit.

	WHY IT IS WORTH HAVING. Roblox pays the creator out of a pool weighted by how
	long Premium members spend in the experience, so a perk that makes them stay
	is paid for twice: once in engagement and once in the payout. It is the only
	revenue in the game that needs no purchase decision from the player.

	WHY LUCK AND NOT COINS. Every other lever here is a coin multiplier, and
	coins are the one thing this economy has too many routes into already -- the
	till, the daily ladder, the events, the boosts, the packs. Luck is a
	different axis: it improves what comes OUT of an egg, which is a thing you
	buy WITH coins. So a luck perk makes the egg sink more attractive rather than
	making coins less scarce. It pushes on the economy in the direction that
	needs pushing.

	IT DOES NOT DEVALUE ANYTHING SOLD. There is no luck pass -- the eight passes
	are the two machines, VIP, the Starter Pack, 2x Cash, SandBot, Quick Sell and
	Instant Wash -- so this steps on nothing a player can pay for. It is also
	reachable without Premium, by equipping better pets, so it is a head start
	rather than a wall.

	A QUARTER, because the luck a player builds themselves reaches roughly six
	(that is +500% on the pets panel) and a perk worth a quarter of a point is a
	real nudge at the bottom of the run and a rounding error at the top. It
	should not be the reason somebody wins; it should be the reason they stay a
	bit longer early, which is when Premium conversion actually happens.
]]

local PremiumConfig = {}

-- Added to the luck a player's equipped pets already give. See the header for
-- why this is a quarter rather than a multiplier.
PremiumConfig.LuckBonus = 0.25

-- What to call it wherever it is shown.
PremiumConfig.Name = "Premium"

--[[
	Safe on both sides and total: a nil, a non-Player, or a client that has not
	replicated its membership yet all read as "not Premium", which is the
	direction it has to fail in -- paying a perk to somebody who has not got it
	is worse than being a frame late to pay somebody who has.
]]
function PremiumConfig.isPremium(player: Instance?): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	return player.MembershipType == Enum.MembershipType.Premium
end

function PremiumConfig.luckBonusFor(player: Instance?): number
	return PremiumConfig.isPremium(player) and PremiumConfig.LuckBonus or 0
end

return PremiumConfig
