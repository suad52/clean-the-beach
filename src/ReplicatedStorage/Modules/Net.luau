--[[
	Net  --  ReplicatedStorage.Modules.Net

	Single owner of every RemoteEvent in the cleanup loop. The server creates
	the folder on require; the client waits for it. Nothing else in the codebase
	calls Instance.new("RemoteEvent").

	DIRECTION CONTRACT -- read this before adding a remote:

		C -> S   SiftShake, SiftEndRequest, PetEquip, EggBuy
		S -> C   InventorySync, SiftBegin, SiftEnd, SiftProgress, SiftChunkGone,
		         SiftItemCleaned, SellResult, Notify, Fx, ScreenChanged,
		         HatchEgg, PetSync, EggMenu

	SiftShake carries ONE field: `dir`, either 1 or -1, sent the instant the
	player's swing changes direction. Not an amount, not a duration, not a
	progress value -- and deliberately not a speed, even though speed is what
	the mechanic rewards. The server times the reversals against its own clock,
	derives the cadence itself, and credits `rate * vigour * elapsed`.

	The one thing the client decides is WHEN it turns around, which is precisely
	the part that should be the player's. Two of the same `dir` in a row is not
	a reversal and is dropped, and because vigour peaks and then falls away, a
	client that floods the remote sifts SLOWER than one that plays properly.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "BeachCleanupNet"

local EVENT_NAMES = {
	-- Restored: the pressure washer's remotes. The Sift* names below are left
	-- in place so the disabled sift modules still resolve if re-enabled.
	"WashBegin",
	"WashEnd",
	"WashProgress",
	"WashChunkGone",
	"WashItemCleaned",
	"WasherChanged",
	"WashAim",
	"WashEndRequest",

	--[[
		THE INSTANT WASH GAME PASS. Two remotes, and the client's half of it
		carries NOTHING -- not a chunk list, not a count, not a pass id.

		WashInstantRequest is a bare "do the thing". Everything that decides
		whether it happens is already server-side: which lump is on the stand,
		how much of it is left, whether the player is still standing at the bay,
		and -- the one that matters -- whether Roblox says they own the pass.
		GamePassService answers that last one off its own record, never off the
		replicated attribute the HUD paints its button with.

		WashInstant comes back with the indices that were cleared, in ONE
		message rather than a WashChunkGone each. Twenty-two of those would each
		bloom their own ring and climb their own chain rung: a two-second drum
		roll in front of a reveal that is meant to land immediately.
	]]
	"WashInstant",        -- S->C: {chunks = {i, ...}} the whole shell, at once
	"WashInstantRequest", -- C->S: no payload; the server owns every precondition

	-- server -> client
	"InventorySync",   -- full snapshot (identity + value hidden while crusted)
	--[[
		THE ONLY NAME HERE THAT TRAVELS BOTH WAYS, and it is one name rather
		than a Fetch/Data pair because there is exactly one question and one
		answer: C->S carries no payload and means "send me my index", S->C
		carries { itemId, ... } and is the whole found set.

		SaveService owns both ends. The client asks because the board can
		finish building after the join-time send has already gone out.
	]]
	"IndexSync",       -- S->C: the saved item index. C->S: please send it.
	-- THE SIFT SYSTEM'S REMOTES ARE GONE (2026-08) -- all but one. The sift
	-- minigame was removed (its modules are parked in ServerStorage), and six
	-- of its seven names went with it: SiftBegin, SiftEnd, SiftProgress,
	-- SiftChunkGone, ScreenChanged, SiftShake, SiftEndRequest. The one below
	-- STAYS because two LIVE scripts connect to it during client boot --
	-- RevealPopup and MenuHud deliberately listen to the wash AND sift reveal
	-- remotes -- and Net.get asserts on unknown names, so removing this name
	-- crashes every client at RevealPopup.start. Nothing fires it any more.
	"SiftItemCleaned", -- reveal payload: name, rarity, rolled value (no writer)
	-- {playtime = {elapsed, tiers[]}, daily = {streak, rung, claimed, coins,
	-- ladder[]}, quests = {…}} -- the whole Rewards panel in one push. It
	-- carries every field a quest ROW needs (label, blurb, need, have, coins),
	-- so adding a quest to RewardsConfig needs no client change at all.
	"RewardsSync",
	"ProgressionSync", -- levels, costs, rebirths, multiplier -- the panel's truth
	-- {sold, subtotal, bonus, multiplier, passMultiplier, total, coins}. The two
	-- multipliers are separate and never pre-combined: `multiplier` is the rebirth
	-- figure the rebirth panel advertises, `passMultiplier` is 2x Cash. See the
	-- arithmetic in SellServer.sellAll for why folding them would break a promise.
	"SellResult",
	"Notify",          -- soft UI message ("Sift the crust off first!")
	"Fx",              -- broadcast one-shot effects (sparkle, coin shower)
	-- {phase = "rise" | "land", rebirths, seconds}. Two beats rather than one
	-- message and a client-side timer: the SERVER owns when the character is
	-- actually moved to the spawn, so the curtain has to be told to lift by the
	-- thing that did the moving, not by a clock that hopes to agree with it.
	"RebirthAscend",
	-- The pet system. There is deliberately no "buy egg" message: hatching is
	-- driven by a ProximityPrompt whose Triggered event is connected on the
	-- SERVER (see PetServer), so the engine itself validates that the player is
	-- standing at the station. A remote here could only ever be a claim that
	-- they were.
	"HatchEgg",        -- S->C: what you just won {eggKey, count, results[], anchor}
	"PetSync",         -- S->C: {owned, equipped, luck, maxEquipped}
	--[[
		EggMenu / EggBuy -- buying an egg is TWO messages now, and the split is
		the security rather than the UI.

		The ProximityPrompt's Triggered is engine-validated: it proves the player
		was genuinely within range. A RemoteEvent proves nothing. So the prompt no
		longer hatches -- it opens the menu and RECORDS the intent server-side,
		and EggBuy is only ever honoured against a live one whose station the
		player is still standing at.

		EggBuy carries a COUNT and nothing else. Not a price, not an egg key, not
		a station: all three are read off the recorded intent, so there is no
		field in the payload worth tampering with.
	]]
	"EggMenu",         -- S->C: {eggKey, eggName, cost, coins, room, max}
	"EggBuy",          -- C->S: {count = 1..10}

	-- client -> server
	-- PetEquip carries FUSE too, as action = "fuse": see the note on that branch
	-- in PetServer for why it is not a remote of its own.
	"PetEquip",        -- {petId = string, equip = boolean} -- an ID and a flag,
	                   -- never a slot index and never a luck number
	-- THE WARDROBE. A skin KEY and nothing else: SkinService.choose re-tests that
	-- the key exists in this build and that the player owns it, which is the same
	-- test the plinths go through, so this remote grants no authority the world
	-- does not already grant. It exists because three EARNED skins now have no
	-- plinth behind them, and `choose` used to have only two callers -- a stand
	-- and the VIP pass -- which left a plinth-less skin wearable once and never
	-- again.
	"SkinChoose",      -- C->S: skinKey (string)
	-- (SiftShake and SiftEndRequest were removed with the sift system, 2026-08)
	-- {kind = "daily"} | {kind = "quest", key = s} | {tier = n}
	-- An index or a key, never an amount and never a date: the server owns the
	-- clock and re-checks every threshold itself. The bare {tier = n} form is
	-- the original playtime payload and is still accepted, so a client that is
	-- mid-session when the server updates keeps paying out.
	"ClaimReward",
	-- THE FREE REWARD, and it is a separate pair from ClaimReward above because it
	-- is a different kind of thing: the daily/quest rewards are earned in-game and
	-- gated on counters the server already holds, where this one is gated on
	-- GROUP MEMBERSHIP, which is a web call to Roblox. Sharing a remote would mean
	-- one handler with two entirely different preconditions in it.
	"FreeRewardSync",  -- S->C: {inGroup, claimed, coins, groupId, groupName}
	"FreeRewardClaim", -- C->S: "check" (re-ask Roblox) | "claim" -- no amount, ever
	-- REDEEMABLE CODES, and a third separate remote for the same reason the two
	-- above are separate from each other: the precondition is different again.
	-- This one is gated on a string matching a table and on the account not having
	-- had it before -- no counter, no web call, no amount. CodeService bounds the
	-- length before it looks at the contents, and answers "not valid" identically
	-- for a wrong code and for rubbish, so the table cannot be probed.
	"RedeemCode",      -- C->S: the typed string, and nothing else
	"BuyUpgrade",      -- {track = string} -- a KEY, never a level or a price
	-- The SECOND shop ladder: AtvConfig.Upgrades, the car rake, sold from the
	-- Beach Shop's Car tab. Same contract as BuyUpgrade and a separate remote
	-- rather than a flag on that one, because the two obey different rules --
	-- this one refuses a player with no machine and has no tide ceiling -- and a
	-- handler that branched on the payload would be one `if` away from selling a
	-- car rung to somebody at the foot-track price.
	"BuyCarUpgrade",   -- {track = string} -- a KEY, never a level or a price
	--[[
		QUICK UPGRADE -- the same rung, paid for in Robux instead of coins. TWO
		messages, and the split is the whole design rather than the UI.

		A developer product receipt names a PRODUCT and a PLAYER and nothing else.
		There is one Quick Upgrade product for every track on both ladders, so by
		the time ProcessReceipt runs there is nothing in the receipt that says
		WHICH rung was bought. The intent has to have been recorded before the
		Robux moved -- which is exactly the shape EggMenu/EggBuy above already
		uses, and for the same reason.

		So QuickUpgrade does NOT buy anything. It asks: the server re-derives the
		level, the ceiling and every refusal for itself, records the intent if the
		rung is genuinely for sale, and only then fires QuickUpgradePrompt back.
		A refusal therefore costs a toast rather than a Robux dialog the player
		cannot get anything out of.

		It carries a KEY and a LADDER and nothing else -- no level, no price, no
		product id. The product id travels the other way, on the prompt, so the
		client cannot name one.

		ONE REMOTE FOR BOTH LADDERS, unlike BuyUpgrade / BuyCarUpgrade above, and
		the argument those two are split on does not reach this one: it is about
		PRICE ("selling a car rung at the foot-track price"), and there is no coin
		price anywhere in this pair. The Robux price is one number for every rung
		on either ladder. What still differs -- the tide ceiling on one, the
		machine lock on the other -- is a REFUSAL, and getting a refusal wrong
		costs a wrongly-refused tap rather than anybody's money.
	]]
	"QuickUpgrade",       -- C->S: {track = string, ladder = "car"?} -- a key, never a price
	"QuickUpgradePrompt", -- S->C: {productId = number, track = string} -- the go-ahead
	"DoRebirth",       -- no payload; the server owns every precondition
	-- The first-rebirth nudge (RebirthUnlockPrompt / RebirthPromptServer). No
	-- payload: this is "the card was dismissed", not a request, and it is what
	-- lets the server stamp RebirthPromptConfig.SeenAttribute against the
	-- moment the player actually saw the card rather than the moment the gate
	-- alone went true. See RebirthPromptServer's header.
	"RebirthPromptSeen", -- C->S: no payload

	-- THE LONG SHORE. Two words in, one snapshot out.
	--
	-- "enter" is deliberately NOT the only door: the walk-up prompt on the beach
	-- shelter is connected on the server, where the engine itself vouches that
	-- the player is standing at it. This remote exists for the doors that are
	-- not a walk-up -- a HUD key, a settings toggle, a test -- and for "leave",
	-- which the card's button fires from wherever the player is standing.
	"AfkControl",      -- C->S: "enter" | "leave"
	"AfkSync",         -- S->C: {bay, rate, earned, walkSpeed} or nil when not idle

	-- THE CLEAN-OFF, the 1v1 arenas.
	--
	-- The client sends exactly two facts and neither is trusted: a userId it
	-- wants to challenge, and a yes/no. It never sends a pickup, a score or a
	-- finish -- those are the server's own proximity test on the server's own
	-- litter, because a race where the client reports its progress is a race
	-- won by whoever edits their client.
	"DuelChallenge",   -- C->S: userId of the player being challenged
	"DuelReply",       -- C->S: true | false
	"DuelInvite",      -- S->C: {fromName, fromUserId, seconds} or nil to clear
	"DuelState",       -- S->C: the whole match snapshot, or nil when not in one

	--[[
		PET TRADING. Three remotes, and the client's half of it carries nothing
		worth tampering with.

		TradeAction is ONE message with an `action` word rather than eight
		remotes, because every one of them is the same shape -- a verb and at
		most a petId -- and eight doors into one session table is eight places to
		forget the same validation. The fields it may carry:

			invite   userId    who to ask
			accept / decline   answers the standing invite, no payload
			offer / unoffer    petId, a KEY -- never a count, never a value and
			                   never a slot: the server owns how many you have
			lock / unlock      no payload
			confirm            no payload
			cancel             no payload

		There is deliberately no "complete" verb. The swap is not something a
		client asks for -- it happens when the SERVER observes both sides
		confirmed, which is the one moment it can be sure both agreed to the same
		table. A client that could request the exchange could request it a frame
		after changing its offer.
	]]
	"TradeAction",     -- C->S: {action = string, userId = number?, petId = string?}
	"TradeState",      -- S->C: the whole session snapshot, or nil when not in one
	"TradeInvite",     -- S->C: {fromName, fromUserId, seconds} or nil to clear

	--[[
		THE SANDBOT. ONE REMOTE, AND IT ONLY OPENS A SHOP DIALOG.

		THERE IS NO CONTROL REMOTE, and that is worth stating rather than leaving as
		an absence: deploy and recall are what a ProximityPrompt on the SANDBOT HOME
		does, connected on the SERVER. Triggered gives the server the player AND the
		building, both vouched for by the engine -- where a remote could only ever
		claim the first and never carry the second at all.

		THE BUILDING IS NOT DECORATION TO THIS ANY MORE. A deploy is placed on that
		dock's own charging plate and drives out of its mouth; a recall drives back
		to it and parks. "Which dock" is a real input now, and the only door that
		answers it honestly is a prompt hanging on the dock.

		One existed briefly, for a HUD key that has been taken out again -- the key
		quoted a Robux purchase from the same corner as the coin counter and charged
		the carried-items drawer 66 pixels for it. Both halves went together.

		SandbotSync is gone with it and is not missed. The drone's state is on the
		player as SandbotConfig.OutAttribute, which replicates downward for free --
		that is what makes the dock prompt say DEPLOY or RECALL, and what tells a
		client whose kennel is standing empty.

		SandbotOffer is the one thing a server genuinely cannot do for itself:
		MarketplaceService:PromptGamePassPurchase is a CLIENT call. So when the
		dock refuses somebody who does not own the pass, it names the pass and the
		client puts the dialog up. Nothing is granted on the strength of it --
		GamePassService hears the outcome and goes and asks Roblox.
	]]
	"SandbotOffer",    -- S->C: passId -- "you may offer them this", never a grant

	--[[
		THE TEN-MINUTE CLOCK. S->C only, and the client is not waiting on it.

		EventConfig is replicated and the timetable is arithmetic on os.time(), so
		both ends work the schedule out for themselves -- which is what keeps the
		countdown on screen smooth when the network is not. What this message is
		for is the OFFSET: it carries the server's `now` so a client can measure
		how far its own clock is out and stop showing 0:00 for two seconds.

		{phase = "idle"|"soon"|"live", id, startsAt, endsAt, now}
	]]
	"EventState",
	--[[
		The tutorial send-off's streaming escort. C->S: { stage = n } while the
		outro cinematic is showing island n of TutorialConfig.OutroStops --
		TutorialServer walks the player's ReplicationFocus to that stop so the
		shot streams in FULL detail instead of as imposters; stage 0 (or the
		window lapsing) hands the focus back to the character. Server-validated
		against the config table and a per-player time window, so it cannot be
		driven as a free map-spying camera.
	]]
	"OutroFocus",       -- C->S: { stage = number }
	--[[
		A PERSONAL SETTING WORTH KEEPING. C->S: { key = string, value = any }.

		Most of the Settings panel is deliberately client-only and unsaved -- see
		its header -- because a preference that only affects what this machine draws
		needs no server. HUD Size is the exception: a player who could not read the
		interface had to fix it again on every join, which is the one setting where
		forgetting is the whole problem.

		SettingsServer WHITELISTS both the key and the value, so this is a request
		to store one of a handful of named strings and not a way to write arbitrary
		data into somebody's profile.
	]]
	"SettingSave",      -- C->S: { key = string, value = any }
}

-- NOTE: there is no screen-upgrade remote. The kiosk upgrade is a server-side
-- ProximityPrompt, so the engine itself validates that the player is standing
-- at the kiosk -- strictly better than trusting a remote that says they are.

local Net = {}

local folder

if RunService:IsServer() then
	folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if not folder then
		local f = Instance.new("Folder")
		f.Name = FOLDER_NAME
		f.Parent = ReplicatedStorage
		folder = f
	end
	for _, name in EVENT_NAMES do
		if not folder:FindFirstChild(name) then
			local ev = Instance.new("RemoteEvent")
			ev.Name = name
			ev.Parent = folder
		end
	end
else
	folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, 30)
	assert(folder, "[Net] server never created " .. FOLDER_NAME .. " -- is ServerMain running?")
end

local cache = {}

function Net.get(name)
	local hit = cache[name]
	if hit then
		return hit
	end
	assert(table.find(EVENT_NAMES, name), "[Net] unknown remote: " .. tostring(name))

	local found = folder:FindFirstChild(name)
	if not found and RunService:IsClient() then
		found = folder:WaitForChild(name, 15)
	end
	assert(found, "[Net] remote not found: " .. name)

	cache[name] = found
	return found
end

return Net
