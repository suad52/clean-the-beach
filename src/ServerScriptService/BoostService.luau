--[[
	BoostService  --  ServerScriptService.BoostService


	GRANTS AND ENDS THE BOUGHT GOLDEN HOUR. BoostConfig says what one is and how
	to read it; this is the only thing in the game that WRITES one.

	The effect itself is not here. SellServer multiplies by BoostConfig.
	multiplierFor at the till, alongside the rebirth multiplier, the 2x Cash pass
	and the live event -- four numbers, four promises, none of them merged. This
	file only owns the two attributes that answer "is one running".


	TIME ADDS, AND THERE IS NO CAP.

	A second purchase while one is live extends the deadline rather than replacing
	it, so nobody can waste money by buying at the wrong moment -- which is the
	one thing a timed product must never do. Ten purchases is 150 minutes, and
	that is allowed to be true: a cap would mean quietly taking Robux for time
	that is never handed over, and there is no version of that worth the tidier
	number.

	THE STRONGER MULTIPLIER WINS IF THEY EVER DIFFER. One product today, so this
	never fires -- but the rule has to exist before a second one is added, because
	the alternative is a 3x purchase silently downgrading somebody's running 5x.


	IT SURVIVES A REJOIN, AND THAT IS NOT OPTIONAL.

	Roblox restarts servers constantly. Fifteen paid minutes that die with the
	instance is a product that sometimes delivers two minutes, and the player
	cannot tell that from a bug. So the deadline goes in the profile through the
	same exportFor / restore pair PetServer, RewardsServer, SkinService and
	ProductServer already use -- see SaveService's header table.

	STORED AS AN ABSOLUTE os.time() DEADLINE, so a boost keeps running across the
	gap: quit with nine minutes left, come back four minutes later in a different
	server, and five are left. A stored REMAINING time would hand back the full
	nine and turn every restart into free minutes.

	WHICH MEANS IT CAN EXPIRE WHILE THEY ARE AWAY, and that is correct and worth
	stating: the product sells a window of wall-clock time, the same as the event
	it copies. It is what the shelf says and what the toast counts down.


	THE SWEEP BELOW IS TIDYING, NOT MECHANISM. BoostConfig.multiplierFor compares
	the deadline against the clock on every read, so a boost is already over the
	instant it is over. This loop exists to clear the attributes and tell the
	player -- if it stopped entirely, no sale would ever be over-paid.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local BoostConfig = require(Modules:WaitForChild("BoostConfig"))
local Net = require(Modules:WaitForChild("Net"))

local BoostService = {}

local started = false

-- How often the tidy-up looks. Generous on purpose: it decides only when the
-- "boost over" toast fires, never whether a sale is multiplied.
local SWEEP_SECONDS = 2

--------------------------------------------------------------------------
-- GRANTING
--------------------------------------------------------------------------
--[[
	Add time. Returns the new deadline, or nil if nothing was written.

	THE ONLY WAY A BOOST IS EVER CREATED, so every rule above is enforced in one
	place: ProductServer's receipt handler calls this and so would any future
	reward that hands one out.

	MEASURED FROM NOW OR FROM THE EXISTING DEADLINE, WHICHEVER IS LATER. That is
	the whole of "time adds": an expired deadline is in the past, so `math.max`
	against the clock starts a fresh window, and a live one gets extended.
]]
function BoostService.grant(player: Player, seconds: number?, multiplier: number?): number?
	if not (player and player.Parent) then
		return nil
	end

	local add = tonumber(seconds) or BoostConfig.Seconds
	local mult = tonumber(multiplier) or BoostConfig.Multiplier
	if add ~= add or add <= 0 or mult ~= mult or mult <= 1 then
		return nil
	end

	local now = os.time()
	local standing = tonumber(player:GetAttribute(BoostConfig.UntilAttr)) or 0
	if standing ~= standing then
		standing = 0
	end
	local deadline = math.max(now, standing) + add

	-- Never downgrade a running boost -- see the header.
	local live = tonumber(player:GetAttribute(BoostConfig.MultAttr)) or 0
	if live == live and live > mult and standing > now then
		mult = live
	end

	player:SetAttribute(BoostConfig.MultAttr, mult)
	player:SetAttribute(BoostConfig.UntilAttr, deadline)
	return deadline
end

--------------------------------------------------------------------------
-- PERSISTENCE  (SaveService's exportFor / restore pair)
--------------------------------------------------------------------------
-- Nil when there is nothing running, so an ordinary profile carries no boost
-- field at all rather than a dead deadline -- the arrangement SkinService and
-- RewardsServer's exports use.
function BoostService.exportFor(player: Player)
	if BoostConfig.remainingFor(player) <= 0 then
		return nil
	end
	return {
		until_ = tonumber(player:GetAttribute(BoostConfig.UntilAttr)),
		mult = tonumber(player:GetAttribute(BoostConfig.MultAttr)),
	}
end

--[[
	VALIDATED, NOT TRUSTED, in the way every other restore in SaveService is: the
	blob has been through a datastore and a schema migration, and this is money.

	A DEADLINE ALREADY PAST IS DROPPED rather than written and swept a moment
	later, so a player who was away longer than their boost never sees a readout
	flash up and vanish.
]]
function BoostService.restore(player: Player, blob: any)
	if type(blob) ~= "table" then
		return
	end
	local deadline = tonumber(blob.until_)
	local mult = tonumber(blob.mult)
	if not deadline or deadline ~= deadline or deadline <= os.time() then
		return
	end
	if not mult or mult ~= mult or mult <= 1 then
		return
	end
	player:SetAttribute(BoostConfig.MultAttr, mult)
	player:SetAttribute(BoostConfig.UntilAttr, deadline)
end

--------------------------------------------------------------------------
-- ENDING
--------------------------------------------------------------------------
local function clear(player: Player)
	player:SetAttribute(BoostConfig.MultAttr, nil)
	player:SetAttribute(BoostConfig.UntilAttr, nil)
end

function BoostService.start()
	assert(RunService:IsServer(), "[BoostService] server-only")
	if started then
		return
	end
	started = true

	task.spawn(function()
		while true do
			task.wait(SWEEP_SECONDS)
			for _, player in ipairs(Players:GetPlayers()) do
				-- The attribute is the thing being tidied, so this asks whether one is
				-- WRITTEN and separately whether it is still worth anything.
				if player:GetAttribute(BoostConfig.UntilAttr) ~= nil
					and BoostConfig.remainingFor(player) <= 0
				then
					clear(player)
					pcall(function()
						Net.get("Notify"):FireClient(player, {
							text = "Your golden hour has run out.",
							kind = "warn",
						})
					end)
				end
			end
		end
	end)

	print(string.format("[Boost] online -- %dx for %d minutes a purchase, time adds",
		BoostConfig.Multiplier, BoostConfig.Seconds // 60))
end

return BoostService
