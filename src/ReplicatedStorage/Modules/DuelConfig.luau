--[[
	DuelConfig  --  ReplicatedStorage.Modules.DuelConfig

	THE CLEAN-OFF: a 1v1 race. Two players are dropped on identical pitches in
	one of four arenas and the first to clear their litter wins.

	Shared by the four files that run it:
		ServerScriptService.DuelArenaBuilder   the four arenas
		ServerScriptService.DuelService        challenges, matches, scoring
		StarterPlayerScripts.DuelClient        click-to-challenge, cards, HUD

	WHY THE LITTER IS THE ARENA'S OWN AND NOT THE GAME'S.

	The obvious build is "seed the pitch with real litter and let the rake and
	the bag do the work". Three reasons not to, and they are the shape of this
	whole feature:

	  * CTB's litter feeds the INVENTORY, which feeds the sell pad. A duel that
	    fills your bag turns a race into a farming route, and the winner is
	    whoever brought the emptier bag.
	  * the rakeable field is per-player TERRAIN state. Two players racing on one
	    patch of it is exactly the case it is not built for.
	  * a race has to be FAIR to the stud. Arena litter is placed from a fixed
	    per-round seed and mirrored across the divider, so both pitches are the
	    same problem. Real litter is scattered.

	So the arena owns its own props, the count is the score, and NOTHING leaves
	the arena at all -- not the litter, and not a payout either. The race pays no
	coins; see WHAT A WIN IS WORTH, below, for why the prize went.
]]

local DuelConfig = {}

--------------------------------------------------------------------------
-- WHERE
--------------------------------------------------------------------------

-- Far out, and far from the idle shore at (8000, 8000) as well -- two systems
-- that teleport players must not be able to see each other's geometry.
DuelConfig.Origin = Vector3.new(12000, 0, 12000)
DuelConfig.ArenaPitch = 460         -- how far apart the four arenas stand

-- One pitch, per player. The divider runs down the middle on Z, so the two
-- pitches are mirrored across X and neither has the better light or the
-- shorter walk.
DuelConfig.PitchWidth = 76          -- along X, per player
DuelConfig.PitchDepth = 96          -- along Z
DuelConfig.Divider = 8              -- the wall between them

function DuelConfig.arenaOrigin(index: number): Vector3
	local span = (#DuelConfig.Arenas - 1) * DuelConfig.ArenaPitch
	return DuelConfig.Origin + Vector3.new((index - 1) * DuelConfig.ArenaPitch - span * 0.5, 0, 0)
end

-- The centre of player `side`'s pitch (1 = -X, 2 = +X) in arena `index`.
function DuelConfig.pitchCentre(index: number, side: number): Vector3
	local o = DuelConfig.arenaOrigin(index)
	local dx = (DuelConfig.PitchWidth + DuelConfig.Divider) * 0.5
	return o + Vector3.new((side == 1) and -dx or dx, 0, 0)
end

--------------------------------------------------------------------------
-- THE FOUR ARENAS
--
-- One per island, so a duel always looks like somewhere the player has been.
-- Every colour here is taken off the island it names rather than invented, so
-- the arenas read as that place's stone and not as four recolours of one box.
--------------------------------------------------------------------------
DuelConfig.Arenas = {
	{
		key = "TidePools",
		name = "THE TIDE POOLS",
		blurb = "Low tide on the home beach.",
		floor = Color3.fromRGB(228, 198, 138),   -- the shore's own sand
		trim  = Color3.fromRGB(176, 140, 88),
		accent = Color3.fromRGB(94, 226, 196),   -- foam
		wall  = Color3.fromRGB(150, 146, 152),
		sky   = Color3.fromRGB(108, 226, 226),
	},
	{
		key = "SunkenSouk",
		name = "THE SUNKEN SOUK",
		blurb = "A buried market square in the dunes.",
		floor = Color3.fromRGB(224, 176, 106),   -- the dunes' stone
		trim  = Color3.fromRGB(176, 128, 72),
		accent = Color3.fromRGB(240, 194, 82),   -- the dunes' gold
		wall  = Color3.fromRGB(150, 108, 62),
		sky   = Color3.fromRGB(40, 78, 150),     -- lapis
	},
	{
		key = "BlossomCourt",
		name = "THE BLOSSOM COURT",
		blurb = "A shrine courtyard under the sakura.",
		floor = Color3.fromRGB(196, 180, 158),   -- the cove's paving
		trim  = Color3.fromRGB(168, 152, 160),
		accent = Color3.fromRGB(255, 150, 190),  -- blossom
		wall  = Color3.fromRGB(58, 50, 58),      -- the cove's slate
		sky   = Color3.fromRGB(228, 78, 58),     -- vermillion
	},
	{
		key = "CinderPit",
		name = "THE CINDER PIT",
		blurb = "Ash flats in the shadow of the volcano.",
		floor = Color3.fromRGB(96, 92, 96),      -- ashfall grey
		trim  = Color3.fromRGB(64, 60, 64),
		accent = Color3.fromRGB(255, 118, 68),   -- ember
		wall  = Color3.fromRGB(48, 44, 48),
		sky   = Color3.fromRGB(255, 88, 48),
	},
}

function DuelConfig.arenaByKey(key: string)
	for i, a in ipairs(DuelConfig.Arenas) do
		if a.key == key then return a, i end
	end
	return nil
end

--------------------------------------------------------------------------
-- THE RACE
--------------------------------------------------------------------------

-- How much litter each player has to clear. The score IS this count going
-- down, so it wants to be small enough to read at a glance on the HUD and big
-- enough that one lucky pickup does not decide the match.
DuelConfig.LitterCount = 24

-- How close you have to be to sweep a piece up. Generous on purpose: a race
-- decided by pixel-accurate walking is a race about the controls.
DuelConfig.PickupRadius = 6

DuelConfig.CountdownSeconds = 4      -- 3 - 2 - 1 - GO
DuelConfig.RoundSeconds = 150        -- the ceiling; see winnerOf below
DuelConfig.ResultSeconds = 6         -- how long the win card holds before home

-- An invite nobody answers must not sit on screen forever, and must not hold
-- an arena open either.
DuelConfig.InviteSeconds = 20

-- How far apart two players can be and still challenge each other. A duel is a
-- thing you do to somebody you are standing next to, not a thing you do to a
-- name on a list.
DuelConfig.ChallengeRange = 60

--[[
	WHO WON.

	Runs for BOTH end conditions -- somebody cleared their pitch, or the clock
	ran out -- so there is one answer to "who won" and not two that can
	disagree. Fewest left wins; equal is a draw, which is a real outcome and not
	an error.
]]
function DuelConfig.winnerOf(leftA: number, leftB: number): number
	if leftA < leftB then return 1 end
	if leftB < leftA then return 2 end
	return 0
end

--[[
	WHAT A WIN IS WORTH: NOTHING, AND THAT IS THE FEATURE.

	The clean-off used to pay 2,400 x SellMultiplier for a win and 800 for a
	draw -- "one good bag", pitched at about 60% of the raking rate so it was
	worth the detour without ever being the optimal farm. That arithmetic was
	sound and is not why the prize went.

	IT WENT BECAUSE A MODE THAT PAYS COINS IS A MODE PLAYERS ENTER FOR COINS,
	and from that moment every part of it has to be argued against the beach: is
	it worth the two and a half minutes, does it out-farm raking, does LOSING
	cost me money. Answer all three well and what you have built is a second
	income source that happens to have an opponent standing in it. Answer any of
	them badly and the mode is a trap.

	Purely competitive removes the question. The race is the entire reward, a
	loss costs nothing but the round, and the only reason to accept a challenge
	is to beat the person who sent it. The one thing a win moves is WinsAttr
	below, which is a scoreboard and not a currency.

	SO NOTHING IN THE DUEL MAY GRANT ANYTHING -- no coins, no items, no XP.
	DuelService no longer holds a coin bridge at all, which is deliberate: the
	way back in is to re-add one and re-argue the paragraph above, not to slip a
	payout into the result block.
]]

--------------------------------------------------------------------------
-- THE CONTRACT WITH EVERYTHING ELSE
--------------------------------------------------------------------------

-- Set on the PLAYER for the length of a match. Anything that needs to know
-- whether somebody is mid-duel asks this: the AFK shore refuses to take them,
-- and anything that teleports must not.
DuelConfig.Attr = "DuelArena"        -- arena index, or nil
DuelConfig.SideAttr = "DuelSide"     -- 1 or 2, which pitch
DuelConfig.WinsAttr = "DuelWins"     -- lifetime, for the card

function DuelConfig.arenaOf(player: Player): number?
	local v = player and player:GetAttribute(DuelConfig.Attr)
	return (type(v) == "number") and v or nil
end

DuelConfig.FolderName = "DuelArenas"

return DuelConfig
