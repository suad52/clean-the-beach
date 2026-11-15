--[[
	TradeService  --  ServerScriptService.TradeService

	PET TRADING between two players, gated on TradeConfig.MinRebirths.

	This file owns the NEGOTIATION and nothing else. It does not own pets: the
	exchange itself is one call to PetServer.applyTrade, which is where the two
	ledgers live and is the only place they are allowed to move at once. See the
	header over that function for why the swap is not orchestrated from here.

	THE SHAPE OF A SESSION
	----------------------
		invite  -> one standing invite per target, twenty seconds
		open    -> both sides editing their half of the table
		locked  -> a side has stopped changing their offer
		confirm -> a side has agreed to the table as it stands
		swap    -> the frame both are confirmed, and only then

	THE ONE RULE THAT MAKES IT SAFE TO SHIP
	---------------------------------------
	ANY change to EITHER offer clears BOTH locks and BOTH confirmations. That is
	the whole anti-scam design and it is enforced in exactly one place --
	`touchOffer` below -- so there is no path that can change a table without
	going through it.

	The scam it defeats is the only one that matters: show a Mythic, wait for the
	other player to confirm, swap it for a Common and let their confirmation
	stand. Here the swap un-confirms them, and confirming is only possible once
	both sides are locked, so the table a player agrees to is frozen at the
	moment they agree to it.

	WHAT THE CLIENT IS TRUSTED WITH: a verb and a petId. Never a count, never a
	value, never the other player's half, and never the completion. Every action
	re-derives the session from this table, re-checks that the caller is in it,
	and re-checks the rebirth gate -- which is also checked a third time inside
	the swap, because a session that somehow outlived a rebirth reset must not
	be completable.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Net = require(Modules:WaitForChild("Net"))
local PetConfig = require(Modules:WaitForChild("PetConfig"))
local TradeConfig = require(Modules:WaitForChild("TradeConfig"))

local TradeService = {}

-- Resolved in start(), not at require time: PetServer is a sibling and requiring
-- it up here would fix the boot order of two modules that do not otherwise care.
local PetServer = nil

--------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------
-- BOTH players map to the SAME session table, so there is one copy of the
-- truth and "the other side" is never a second record that can disagree.
local sessions: { [Player]: any } = {}
local invites: { [Player]: any } = {}      -- [target] = {from, expires}
local lastInvite: { [Player]: number } = {} -- [sender] = os.clock(), the throttle
local started = false

--[[
	A TABLE, NOT POSITIONAL ARGUMENTS. Fixed 2026-09-09.

	This sent `(text, kind)` as two arguments. FeedbackClient, the only listener
	on the Notify remote, opens with

		if type(payload) ~= "table" or type(payload.text) ~= "string" then return end

	-- so EVERY notification this file has ever sent was dropped on arrival, in
	silence. Nothing errored and nothing appeared: a trade that was refused, an
	invite that expired, a partner who walked away all looked to the player like
	a button that did nothing. Found while clearing the same class of bug out of
	DuelService, which had the shape right and the words missing.
]]
local function notify(player: Player, text: string, kind: string?)
	if player and player.Parent then
		Net.get("Notify"):FireClient(player, { text = text, kind = kind or "warn" })
	end
end

local function otherOf(session, player: Player): Player
	return (session.a == player) and session.b or session.a
end

--------------------------------------------------------------------------
-- CAN THIS PLAYER TRADE AT ALL?
--------------------------------------------------------------------------
-- The gate, plus the two "you are somewhere else" cases. Returns a reason so
-- the refusal can say which door is shut rather than just failing quietly.
function TradeService.canTrade(player: Player): (boolean, string?)
	if not player or not player.Parent then
		return false, "That player has gone."
	end
	if not TradeConfig.meetsGate(player) then
		return false, TradeConfig.gateText()
	end
	if sessions[player] then
		return false, "Already trading."
	end
	-- Mid-duel or out on the idle shore. Both teleport, and a trade panel open
	-- over either is a session nobody is looking at.
	if player:GetAttribute("DuelArena") ~= nil then
		return false, "Finish the duel first."
	end
	if player:GetAttribute("AfkPlot") ~= nil then
		return false, "Come back from the Long Shore first."
	end
	return true, nil
end

--------------------------------------------------------------------------
-- WHAT EACH SIDE SEES
--------------------------------------------------------------------------
--[[
	A snapshot is built PER PLAYER and names the halves "mine" and "theirs", so
	the panel never has to work out which side of the table it is sitting at --
	and so a client cannot learn anything about the other player beyond what is
	actually on the table in front of them.
]]
local function snapshotFor(session, player: Player)
	local them = otherOf(session, player)
	local function rows(offer)
		local out = {}
		for petId, count in offer do
			table.insert(out, { petId = petId, count = count })
		end
		table.sort(out, function(x, y) return x.petId < y.petId end)
		return out
	end
	return {
		partnerName = them.DisplayName,
		partnerUserId = them.UserId,
		mine = rows(session.offer[player]),
		theirs = rows(session.offer[them]),
		myLock = session.locked[player],
		theirLock = session.locked[them],
		myConfirm = session.confirmed[player],
		theirConfirm = session.confirmed[them],
		maxOffer = TradeConfig.MaxOffer,
	}
end

local function pushBoth(session)
	for _, p in { session.a, session.b } do
		if p.Parent then
			Net.get("TradeState"):FireClient(p, snapshotFor(session, p))
		end
	end
end

--------------------------------------------------------------------------
-- OPENING AND CLOSING
--------------------------------------------------------------------------
local function closeSession(session, textA: string?, textB: string?)
	if session.closed then
		return
	end
	session.closed = true
	for _, p in { session.a, session.b } do
		sessions[p] = nil
		if p.Parent then
			p:SetAttribute(TradeConfig.Attr, nil)
			Net.get("TradeState"):FireClient(p, nil)
		end
	end
	if textA then notify(session.a, textA, "warn") end
	if textB then notify(session.b, textB, "warn") end
end

local function openSession(a: Player, b: Player)
	local session = {
		a = a, b = b,
		offer = { [a] = {}, [b] = {} },
		locked = { [a] = false, [b] = false },
		confirmed = { [a] = false, [b] = false },
		closed = false,
	}
	sessions[a] = session
	sessions[b] = session
	a:SetAttribute(TradeConfig.Attr, b.UserId)
	b:SetAttribute(TradeConfig.Attr, a.UserId)
	pushBoth(session)
	return session
end

--------------------------------------------------------------------------
-- THE RULE
--------------------------------------------------------------------------
--[[
	EVERY offer change goes through here, and this is the only function allowed
	to touch `offer`. Clearing both sides' lock and confirm is not a courtesy --
	it is the anti-scam guarantee, and having exactly one writer is what makes it
	possible to say that with a straight face.
]]
local function touchOffer(session, mutate: (any) -> ())
	mutate(session)
	session.locked[session.a] = false
	session.locked[session.b] = false
	session.confirmed[session.a] = false
	session.confirmed[session.b] = false
end

--------------------------------------------------------------------------
-- THE SWAP
--------------------------------------------------------------------------
-- Runs only when the SERVER observes both confirmed. Re-checks the gate a
-- third time and hands the whole exchange to PetServer in one call.
local function tryComplete(session)
	if session.closed then
		return
	end
	if not (session.confirmed[session.a] and session.confirmed[session.b]) then
		return
	end
	local A, B = session.a, session.b

	if not TradeConfig.meetsGate(A) or not TradeConfig.meetsGate(B) then
		closeSession(session, TradeConfig.gateText(), TradeConfig.gateText())
		return
	end

	local ok, why = PetServer.applyTrade(A, session.offer[A], B, session.offer[B])
	if not ok then
		-- Refused with nothing moved. Unlock rather than close: the usual reason
		-- is a full bag or a pet that got equipped, and both are fixable without
		-- rebuilding the whole table.
		touchOffer(session, function() end)
		pushBoth(session)
		notify(A, why or "Trade refused.", "warn")
		notify(B, why or "Trade refused.", "warn")
		return
	end

	local gaveA = 0
	for _, c in session.offer[A] do gaveA += c end
	local gaveB = 0
	for _, c in session.offer[B] do gaveB += c end

	closeSession(session)
	notify(A, string.format("Traded %d pet%s for %d with %s.",
		gaveA, gaveA == 1 and "" or "s", gaveB, B.DisplayName), "good")
	notify(B, string.format("Traded %d pet%s for %d with %s.",
		gaveB, gaveB == 1 and "" or "s", gaveA, A.DisplayName), "good")
	print(string.format("[Trade] %s <-> %s : %d for %d", A.Name, B.Name, gaveA, gaveB))
end

--------------------------------------------------------------------------
-- THE ACTIONS
--------------------------------------------------------------------------
local function doInvite(plr: Player, targetId)
	if type(targetId) ~= "number" then
		return
	end
	local target = Players:GetPlayerByUserId(targetId)
	if not target or target == plr then
		return
	end

	-- Throttled per sender: an unsolicited popup is a nuisance vector, and this
	-- is the one remote in the game that can produce one on a stranger's screen.
	local now = os.clock()
	if lastInvite[plr] and now - lastInvite[plr] < TradeConfig.InviteCooldown then
		return
	end

	local okA, whyA = TradeService.canTrade(plr)
	if not okA then
		notify(plr, whyA or "You cannot trade right now.")
		return
	end
	local okB, whyB = TradeService.canTrade(target)
	if not okB then
		-- Deliberately vague about the other player's state -- "they are busy" is
		-- all the sender needs, and their rebirth count is not the sender's
		-- business. The one exception is the gate, which is public and is the
		-- thing a sender most needs to understand.
		notify(plr, (whyB == TradeConfig.gateText())
			and string.format("%s has not turned the tide yet.", target.DisplayName)
			or string.format("%s is busy.", target.DisplayName))
		return
	end
	--[[
		AND THEY MAY HAVE SHUT THE DOOR -- Settings -> "Trade Requests", on by
		default.

		Asked for twice on 2026-09-17: "Ability to turn off trade requests"
		(TheLegendOf27) and "거래 끄기 만들어주세요" (月下花). Two people who do not
		share a language both wanted the same door.

		INCOMING ONLY, and that is the literal request rather than the broad one.
		The nuisance is an unsolicited popup on a stranger's screen -- this file's
		own note calls it "the one remote in the game that can produce one". A
		player who turns it off keeps the ability to START a trade, because
		initiating is a thing they chose to do and nobody asked to lose it.

		CHECKED HERE RATHER THAN IN canTrade, deliberately: canTrade is asked
		about the SENDER too, a few lines up, and folding this into it would stop
		them inviting anybody -- which is the broad reading nobody typed.

		SERVER-SIDE, because a client-side block is not one. The invite is a
		FireClient at a stranger; refusing to draw it on the receiving end still
		spends their attention and still lets a modified client spam.

		IT NAMES THE REASON, departing from the deliberate vagueness above. "X is
		busy" invites a retry in ten seconds, and a sender who retries forever is
		exactly the experience the setting exists to end. That somebody has
		trading off is not a secret worth keeping at the cost of the feature
		working.
	]]
	if target:GetAttribute("Set_TradeRequests") == false then
		notify(plr, string.format("%s is not taking trade requests.", target.DisplayName))
		return
	end
	if invites[target] then
		notify(plr, string.format("%s already has an invite waiting.", target.DisplayName))
		return
	end

	-- NO RANGE CHECK. Anyone in the same server may be invited -- see the note in
	-- TradeConfig for why the forty-stud walk-up was removed. Nothing here needs
	-- the characters at all now, which also means an invite works while either
	-- player is mid-respawn rather than failing on a missing HumanoidRootPart.
	lastInvite[plr] = now
	invites[target] = { from = plr, expires = now + TradeConfig.InviteSeconds }
	Net.get("TradeInvite"):FireClient(target, {
		fromName = plr.DisplayName,
		fromUserId = plr.UserId,
		seconds = TradeConfig.InviteSeconds,
	})
	notify(plr, string.format("Trade invite sent to %s.", target.DisplayName), "good")
end

local function doReply(plr: Player, accept: boolean)
	local inv = invites[plr]
	if not inv then
		return
	end
	invites[plr] = nil
	if plr.Parent then
		Net.get("TradeInvite"):FireClient(plr, nil)
	end
	if not accept then
		notify(inv.from, string.format("%s declined.", plr.DisplayName))
		return
	end

	-- Re-checked on BOTH sides at accept time: twenty seconds is long enough for
	-- either of them to have started a duel, gone idle or opened another trade.
	local okA = TradeService.canTrade(inv.from)
	local okB, whyB = TradeService.canTrade(plr)
	if not okA or not okB then
		notify(plr, whyB or "That trade is no longer available.")
		notify(inv.from, "That trade is no longer available.")
		return
	end
	openSession(inv.from, plr)
end

local function doOffer(plr: Player, petId, adding: boolean)
	local session = sessions[plr]
	if not session or session.closed or type(petId) ~= "string" then
		return
	end
	if not PetConfig.get(petId) then
		return
	end

	--[[
		A LOCKED SIDE MAY NOT EDIT, and this is about meaning rather than safety.

		The trade is already safe without it: touchOffer clears both confirmations
		on any change, so a table can never move under a standing agreement. But
		without this check "LOCK" did not actually lock anything -- a locked player
		could still add a pet, and the only visible effect was that both sides
		silently came unlocked. A button that does not do what it says is worse
		than no button.

		So locking freezes your half, and changing your mind is an explicit UNLOCK
		-- which clears both confirmations on its way through, exactly as an edit
		would have.
	]]
	if session.locked[plr] then
		notify(plr, "Unlock your offer before changing it.")
		return
	end

	local offer = session.offer[plr]

	if adding then
		local total = 0
		for _, c in offer do total += c end
		if total >= TradeConfig.MaxOffer then
			notify(plr, string.format("Nine pets a side is the limit."))
			return
		end
		-- Proposed table, tested before it is adopted, so an offer can never sit
		-- on screen claiming more copies than the player actually has spare.
		local want = table.clone(offer)
		want[petId] = (want[petId] or 0) + 1
		local ok, why = PetServer.canGive(plr, want)
		if not ok then
			notify(plr, why or "You cannot offer that.")
			return
		end
		touchOffer(session, function()
			offer[petId] = want[petId]
		end)
	else
		if not offer[petId] then
			return
		end
		touchOffer(session, function()
			local left = offer[petId] - 1
			offer[petId] = (left > 0) and left or nil
		end)
	end
	pushBoth(session)
end

local function doLock(plr: Player, locked: boolean)
	local session = sessions[plr]
	if not session or session.closed then
		return
	end
	session.locked[plr] = locked and true or false
	if not locked then
		-- Unlocking is a change of mind, so it un-confirms both for the same
		-- reason an offer change does.
		session.confirmed[session.a] = false
		session.confirmed[session.b] = false
	end
	pushBoth(session)
end

local function doConfirm(plr: Player)
	local session = sessions[plr]
	if not session or session.closed then
		return
	end
	-- BOTH must be locked first. This is what freezes the table a player is
	-- agreeing to at the moment they agree to it.
	if not (session.locked[session.a] and session.locked[session.b]) then
		notify(plr, "Both sides have to lock first.")
		return
	end
	session.confirmed[plr] = true
	pushBoth(session)
	tryComplete(session)
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------
function TradeService.start()
	assert(RunService:IsServer(), "[TradeService] server-only")
	if started then
		return
	end
	started = true

	PetServer = require(script.Parent:WaitForChild("PetServer"))

	Net.get("TradeAction").OnServerEvent:Connect(function(plr, payload)
		if type(payload) ~= "table" then
			return
		end
		local action = payload.action
		if action == "invite" then
			doInvite(plr, payload.userId)
		elseif action == "accept" then
			doReply(plr, true)
		elseif action == "decline" then
			doReply(plr, false)
		elseif action == "offer" then
			doOffer(plr, payload.petId, true)
		elseif action == "unoffer" then
			doOffer(plr, payload.petId, false)
		elseif action == "lock" then
			doLock(plr, true)
		elseif action == "unlock" then
			doLock(plr, false)
		elseif action == "confirm" then
			doConfirm(plr)
		elseif action == "cancel" then
			local session = sessions[plr]
			if session then
				local them = otherOf(session, plr)
				closeSession(session, nil, nil)
				notify(them, string.format("%s cancelled the trade.", plr.DisplayName))
			end
		end
	end)

	-- Invites expire on their own, so somebody who alt-tabs does not hold their
	-- inviter hostage.
	task.spawn(function()
		while true do
			task.wait(1)
			for target, inv in pairs(invites) do
				if os.clock() > inv.expires or not target.Parent or not inv.from.Parent then
					invites[target] = nil
					if target.Parent then
						Net.get("TradeInvite"):FireClient(target, nil)
					end
				end
			end
		end
	end)

	-- LEAVING ENDS IT. A trade with one player in it is not a trade, and leaving
	-- the other side staring at a locked table with nobody across it is worse
	-- than ending it outright.
	Players.PlayerRemoving:Connect(function(plr)
		invites[plr] = nil
		lastInvite[plr] = nil
		for target, inv in pairs(invites) do
			if inv.from == plr then
				invites[target] = nil
				if target.Parent then
					Net.get("TradeInvite"):FireClient(target, nil)
				end
			end
		end
		local session = sessions[plr]
		if session then
			local them = otherOf(session, plr)
			closeSession(session)
			notify(them, string.format("%s left -- the trade is off.", plr.DisplayName))
		end
	end)

	print("[Trade] pet trading online -- " .. TradeConfig.gateText())
end

return TradeService
