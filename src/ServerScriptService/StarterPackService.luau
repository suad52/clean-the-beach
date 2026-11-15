--[[
	StarterPackService  --  ServerScriptService.StarterPackService

	Hands over the Starter Pack: 20,000 coins and the exclusive Kingsmane pet,
	ONCE per account, to anybody who owns game pass 1954531042.

	THE ONLY HARD PROBLEM HERE IS "ONCE", so it is worth being explicit about.

	A game pass is PERMANENT. GamePassService re-asks Roblox on every join and
	writes `OwnsStarterPack` every time, so that attribute answers "do they own
	the pass", and it is true for the rest of the account's life. A grant hung off
	it pays out 20,000 coins per login, forever. What makes this a one-off is a
	SECOND, SAVED flag -- PassConfig.ClaimedAttribute, persisted by SaveService's
	`starterPackClaimed` -- and three rules around it:

	  1. NOTHING IS GRANTED BEFORE THE PROFILE IS LOADED. The claimed flag arrives
	     with the profile, so a check that runs first sees an unclaimed player who
	     has claimed already. This waits on SaveService.isLoaded and gives up
	     rather than guessing if the load never lands -- a player who misses out
	     until their next join has lost nothing; a player paid twice has cost the
	     game 20,000 coins that were never earned.

	  2. THE FLAG IS SET BEFORE THE GOODS MOVE, and a per-session guard closes the
	     gap inside a single server. Two grants racing -- the join check and the
	     purchase signal landing together -- would otherwise both read "unclaimed"
	     and both pay.

	  3. IT IS SAVED IMMEDIATELY. Without a forced write, a player who buys the
	     pack and whose server dies before the next autosave rejoins unclaimed and
	     is paid again. SaveService.forceSave is the one call that closes that.

	AND IT IS ALL-OR-NOTHING. If the pet cannot be given -- the only real reason
	is a collection already at PetConfig.MaxOwned -- NOTHING is claimed and no
	coins move. The player is told why by PetServer's own notify, and the pack is
	still waiting on their next join once they have made room. A partial grant
	that banked the coins and dropped the pet would be unrecoverable: the flag
	would say they had been paid.

	THAT REFUSAL IS NAMED NOW. `give` passes the pack's name into PetServer.grant,
	so a full-bag buyer reads "Your Starter Pack is waiting -- your pet bag is full
	(250/250). Release a pet, then rejoin to claim it." rather than a bare line
	about their pet bag. The behaviour is unchanged; what changed is that the
	message is about the thing they paid for. Worth keeping: this is the only path
	in the game where a player is charged Robux and correctly receives nothing, so
	it is the one that most needs to explain itself.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local PassConfig = require(Modules:WaitForChild("PassConfig"))
local PetConfig = require(Modules:WaitForChild("PetConfig"))
local Net = require(Modules:WaitForChild("Net"))

local GamePassService = require(script.Parent:WaitForChild("GamePassService"))
local PetServer = require(script.Parent:WaitForChild("PetServer"))
local SaveService = require(script.Parent:WaitForChild("SaveService"))
-- The ONE grant path. Every coin in the game moves through this so that lifetime
-- earnings, the shop's purse and the save's dirty flag all hear about it -- see
-- the note in CTBBridge about what going around it costs.
local SellServer = require(script.Parent:WaitForChild("SellServer"))

local StarterPackService = {}

local ENTRY = PassConfig.get(PassConfig.StarterPackKey)
local CLAIMED = PassConfig.ClaimedAttribute

-- How long to wait for a profile before giving up on this join. Generous: a
-- DataStore read is normally well under a second, and the cost of waiting too
-- long is that a paying player gets their pack a moment late.
local LOAD_TIMEOUT = 45
local LOAD_POLL = 0.25

-- Per-session, per-player. Rule 2 above: the join check and the purchase signal
-- can both be in flight, and both would read the attribute as unset.
local granting: { [Player]: boolean } = {}
local connections = {}
-- One per player, disconnected when they leave. Kept apart from `connections`
-- (which holds the module's own lifetime signals) because a per-player signal
-- appended to that array is never removed, and a server that runs for a day
-- accumulates one dead connection per join.
local watching: { [Player]: RBXScriptConnection } = {}
local started = false

local function alreadyClaimed(player: Player): boolean
	return player:GetAttribute(CLAIMED) == true
end

--[[
	The grant itself. Returns true only if the pack actually changed hands.

	Every early return here is load-bearing -- this function is reached from two
	directions (a join sweep and a purchase) and may be reached again on the next
	join, so it has to be safe to call as often as anything likes.
]]
local function give(player: Player, reason: string): boolean
	if not ENTRY or not player.Parent then
		return false
	end
	if granting[player] or alreadyClaimed(player) then
		return false
	end

	-- The SERVER's answer, off the record GamePassService resolved from Roblox on
	-- join -- never off the replicated attribute, which is the client's copy and
	-- is only ever good enough to paint a button.
	if not GamePassService.ownsPassId(player, ENTRY.id) then
		return false
	end

	--[[
		RULE 1. The claimed flag lands with the profile, so until it has landed
		"not claimed" is indistinguishable from "not loaded yet".
	]]
	local waited = 0
	while not SaveService.isLoaded(player) do
		if waited >= LOAD_TIMEOUT or not player.Parent then
			warn(string.format("[StarterPack] %s owns the pack but their profile never "
				.. "loaded after %ds -- granting nothing. It will be waiting on their "
				.. "next join.", player.Name, LOAD_TIMEOUT))
			return false
		end
		task.wait(LOAD_POLL)
		waited += LOAD_POLL
	end

	-- Re-checked AFTER the wait: the profile that just landed is the thing that
	-- knows whether this account has already been paid.
	if granting[player] or alreadyClaimed(player) then
		return false
	end
	granting[player] = true

	--[[
		THE PET FIRST, and the claim only if it lands. PetServer.grant refuses at
		PetConfig.MaxOwned and tells the player why itself, so a full collection
		leaves the whole pack unclaimed and retryable rather than banking the coins
		and silently dropping the pet.
	]]
	-- The third argument NAMES THE PURCHASE, and it is the whole difference
	-- between a player being told why their pack did not arrive and a player being
	-- told an unrelated fact about their pet bag. See PetServer.grant's own note.
	local ok, gotPet = pcall(PetServer.grant, player, PassConfig.StarterPackPetId,
		"Your " .. ((ENTRY and ENTRY.name) or "Starter Pack"))
	if not ok then
		warn("[StarterPack] PetServer.grant threw:", gotPet)
		granting[player] = nil
		return false
	end
	if not gotPet then
		-- PetServer has said why, and now says it in terms of the pack.
		granting[player] = nil
		return false
	end

	-- RULE 2: stamped before the coins move, so nothing that runs during the
	-- grant can read this player as unclaimed.
	player:SetAttribute(CLAIMED, true)
	SellServer.addCoins(player, PassConfig.StarterPackCoins, "starterpack")

	--[[
		RULE 3: on disk now, not at the next autosave -- and the answer is CHECKED
		rather than discarded. forceSave returns true only when the UpdateAsync
		actually landed, so the boolean is the difference between "written" and
		"attempted".

		A false is NOT rolled back, and that is deliberate. The two live causes are
		an autosave already in flight and a failed UpdateAsync, and neither loses
		the claim: both the coin hook and the pet hook have marked the profile
		dirty, and the leave handler saves unconditionally. Undoing the grant here
		-- or worse, clearing the claimed flag -- would turn a late write into a
		double payout, which is the one outcome this whole file exists to prevent.
		So it warns and leaves the state alone.
	]]
	local okSave, wrote = pcall(SaveService.forceSave, player)
	if not (okSave and wrote) then
		warn(string.format("[StarterPack] granted to %s but the forced save did not "
			.. "land -- the profile is dirty and will be written by the autosave or on "
			.. "leave. Not rolled back: a retry would pay twice.", player.Name))
	end
	granting[player] = nil

	local def = PetConfig.get(PassConfig.StarterPackPetId)
	pcall(function()
		Net.get("Notify"):FireClient(player, {
			text = string.format("Starter Pack claimed \u{2014} %s coins and %s!",
				tostring(PassConfig.StarterPackCoins),
				def and def.DisplayName or PassConfig.StarterPackPetId),
			kind = "pickup",
		})
	end)

	print(string.format("[StarterPack] granted to %s (%s): %d coins + %s",
		player.Name, reason, PassConfig.StarterPackCoins, PassConfig.StarterPackPetId))
	return true
end

StarterPackService.give = give

local function watch(player: Player)
	--[[
		ON A COLD JOIN IT IS THE SIGNAL BELOW, NOT THIS SPAWN, THAT DOES THE
		GRANTING -- and that is worth writing down, because the obvious "fix" for
		it is wrong.

		GamePassService connects PlayerAdded before this module does, and its sweep
		runs three yielding vehicle-pass lookups before it reaches the flat passes.
		So when give() asks ownsPassId here, the record is still the empty table
		and the answer is a truthful "no": this spawn returns false and grants
		nothing.

		The pack still arrives, because resolveFlat writes its RECORD before it
		writes the attribute -- so by the time the attribute changes nil -> true on
		a fresh Player, ownsPassId can answer yes and the second give() succeeds.

		DO NOT "FIX" THE FALSE BY PASSING refresh = true. That turns every join into
		a blocking UserOwnsGamePassAsync call on a path that already gets the right
		answer a frame later, which is exactly what ownsPassId's own header warns
		against. What this spawn is genuinely for is the WARM start: a server where
		this module is required after players are already in, and the attribute has
		long since stopped changing.
	]]
	task.spawn(give, player, "join")

	-- And the moment a purchase resolves. GamePassService writes this attribute
	-- from PromptGamePassPurchaseFinished, having gone and ASKED Roblox rather
	-- than trusting the client's word -- so this fires on a real purchase only.
	if ENTRY then
		if watching[player] then
			watching[player]:Disconnect()
		end
		watching[player] = player:GetAttributeChangedSignal(ENTRY.attribute)
			:Connect(function()
				if player:GetAttribute(ENTRY.attribute) == true then
					task.spawn(give, player, "purchase")
				end
			end)
	end
end

function StarterPackService.start()
	assert(RunService:IsServer(), "[StarterPack] server-only")
	if started then
		return
	end
	started = true

	if not ENTRY then
		warn("[StarterPack] PassConfig has no '" .. tostring(PassConfig.StarterPackKey)
			.. "' entry -- the pack cannot be granted.")
		return
	end
	if not PetConfig.get(PassConfig.StarterPackPetId) then
		warn("[StarterPack] PetConfig has no pet '" .. tostring(PassConfig.StarterPackPetId)
			.. "' -- the pack would pay coins and no pet, so it is disabled.")
		return
	end

	connections[#connections + 1] = Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	connections[#connections + 1] = Players.PlayerRemoving:Connect(function(player)
		granting[player] = nil
		if watching[player] then
			watching[player]:Disconnect()
			watching[player] = nil
		end
	end)

	print(string.format("[StarterPack] online -- pass %d grants %d coins + %s",
		ENTRY.id, PassConfig.StarterPackCoins, PassConfig.StarterPackPetId))
end

return StarterPackService
