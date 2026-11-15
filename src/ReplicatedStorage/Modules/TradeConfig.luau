--[[
	TradeConfig  --  ReplicatedStorage.Modules.TradeConfig

	The rules of PET TRADING, shared by the three files that run it:
		ServerScriptService.TradeService      sessions, offers, the swap
		ServerScriptService.PetServer         applyTrade -- the atomic exchange
		StarterPlayerScripts.TradeClient      the panel and the player picker

	Replicated because the panel has to draw the gate and the limits, and none
	of it is secret: the server re-checks every one of these on every action and
	again at the moment of the swap.

	WHY A REBIRTH GATE AT ALL
	-------------------------
	Trading is the one system in this game where one player's action can empty
	another player's collection, so it is the one worth putting a door in front
	of. A fresh account costs nothing to make; a rebirth costs a tide. Requiring
	one is what stops a scammer spinning up throwaways faster than they can be
	banned, and it is why the gate is on the REBIRTH counter rather than on
	coins, playtime or a level -- those three are all farmable inside one
	session, and a rebirth is the one number in the game that is not.

	It gates BOTH SIDES and it is checked THREE TIMES: when the invite is sent,
	when it is accepted, and again in the frame the pets actually move. A player
	who somehow arrived at a session without it still cannot complete one.
]]

local TradeConfig = {}

--------------------------------------------------------------------------
-- THE DOOR
--------------------------------------------------------------------------

-- Turns of the Tide required to trade at all. 1, so the very first rebirth
-- unlocks it -- that is about half an hour in, which is long enough to cost a
-- bot farm something and short enough that a real player is not locked out of a
-- social feature for a week.
TradeConfig.MinRebirths = 1

-- Written on the player for the length of a session: the partner's UserId, or
-- nil. Anything that must not run mid-trade asks this and nothing else -- the
-- same contract DuelConfig.Attr and AfkConfig.Attr use.
TradeConfig.Attr = "TradeWith"

function TradeConfig.rebirthsOf(player: Player?): number
	local n = player and player:GetAttribute("Rebirths")
	return (type(n) == "number" and n == n) and math.max(0, math.floor(n)) or 0
end

function TradeConfig.meetsGate(player: Player?): boolean
	return TradeConfig.rebirthsOf(player) >= TradeConfig.MinRebirths
end

-- One sentence, written once, so the panel's locked state and the server's
-- refusal cannot describe the requirement differently.
function TradeConfig.gateText(): string
	local n = TradeConfig.MinRebirths
	return string.format("Trading unlocks after %d Turn%s of the Tide.", n, n == 1 and "" or "s")
end

-- Whether this player is free to START one. Being mid-duel or out on the idle
-- shore are both "somewhere else" -- see TradeService.canTrade, which adds the
-- checks that need the server's own session table.
function TradeConfig.partnerOf(player: Player?): number?
	local v = player and player:GetAttribute(TradeConfig.Attr)
	return (type(v) == "number") and v or nil
end

--------------------------------------------------------------------------
-- THE TABLE
--------------------------------------------------------------------------

--[[
	Nine a side, drawn as a 3x3. Not a round number for its own sake: nine is
	what fits a readable 64px tile grid inside half a panel, and a limit low
	enough that both players can actually READ what is on the table is worth more
	than a limit that lets somebody dump ninety pets into a wall of icons nobody
	checks. Bulk trades can be done twice.
]]
TradeConfig.MaxOffer = 9

-- How long an unanswered invite stands. The same twenty seconds a duel
-- challenge gets, for the same reason: an invite nobody answers must not sit on
-- screen forever or hold the sender hostage.
TradeConfig.InviteSeconds = 20

-- Between invites FROM one player. Trading is the one place in the game where
-- an unsolicited popup is a nuisance vector, so the sender is throttled.
TradeConfig.InviteCooldown = 4

--[[
	THERE IS NO RANGE CHECK, AND THAT IS THE POINT.

	This started as a forty-stud walk-up, mirroring the duel's challenge range on
	the reasoning that a trade is something you do with somebody you walked up to.
	That reasoning does not survive the map. The five islands are up to five and a
	half thousand studs apart and gated behind different ferry levels, so two
	players who want to trade were routinely on islands neither could reach -- and
	a player at Ashfall could not trade with a friend on the home beach at all
	without sailing back. A social feature that requires both people to solve a
	travel problem first is a social feature nobody uses.

	So the door is the SERVER, not the distance: anyone in the same world can be
	invited. There is nothing to exploit in it -- the pets are the same pets
	wherever the two of them are standing, and every other guard (the rebirth
	gate, the ownership re-check, the both-lock-then-both-confirm handshake) is
	unchanged and is where the actual safety lives.

	What replaces range as the anti-nuisance measure is InviteCooldown above,
	which is the thing that actually mattered: proximity never stopped an invite
	spammer, it just made them stand next to you.

	NO `Range` FIELD IS LEFT BEHIND. A config value nothing reads is the exact
	defect this codebase already paid for once -- see ProgressionConfig's note on
	TideLuck, which sold 4,200 coins of an attribute no code ever read. If a range
	rule is ever wanted again it comes back with its consumer.
]]

--------------------------------------------------------------------------
-- THE STATES A SESSION MOVES THROUGH
--------------------------------------------------------------------------
--[[
	editing  -> either side may add or remove
	locked   -> that side has stopped changing their offer
	confirmed-> that side has agreed to the trade as it stands

	THE ONE RULE THAT MAKES THIS SAFE TO SHIP: any change to either offer clears
	BOTH sides' lock AND both sides' confirm. That is the whole anti-scam design.
	The classic trade scam is to show a good pet, wait for the other person to
	confirm, swap it for a bad one and let their confirmation stand -- and it is
	impossible here, because the swap itself un-confirms them.

	Both must be locked before either may confirm, so the offer a player is
	agreeing to is frozen at the moment they agree to it.
]]
TradeConfig.Phase = {
	Editing = "editing",
	Locked = "locked",
	Confirmed = "confirmed",
}

return TradeConfig
