--[[
	TipClient  --  StarterPlayerScripts.TipClient  (ModuleScript, started by ClientMain)

	The clock behind the hint band at the top of the screen, and the chat commands
	that call one up on demand.

	Three files, one feature, and the split is the usual one:
		Modules.TipConfig   what is said, and how often          (data)
		Modules.ToastKit    the card itself -- ToastKit.tip()    (the widget)
		this                when                                 (the clock)

	ENTIRELY CLIENT-SIDE. There is no remote and no server half, because there is
	nothing here worth defending: a tip is a string this client already has,
	drawn on this client's own screen. That is also why the chat commands can be
	left on for everybody -- see TipConfig.CommandsInLiveGame.

	THE GROUP LINE IS THE REASON THIS EXISTS, and the rest of the rotation is what
	stops it being ignored. See the header of TipConfig.

	THE ROTATION ENDS. (2026-09-11.) It used to be a `while true`, which meant the
	band kept talking for as long as the session lasted -- fifteen tips in
	forty-five minutes, ninety in the five-hour sessions our heaviest player
	actually plays. A player wrote in to say so: "fun game but i hate the random
	pop ups.. ruins the calmness of the game". There are now three ways it stops,
	and all three are in rotate() below:

		a BUDGET   six tips a session, two once past the first rebirth
		the SCREEN  a tip is never drawn over an open card -- ToastKit.screenBusy
		the SWITCH  Settings -> Helpful Tips, saved, default on

	NONE OF THIS TOUCHES THE REACTIVE NOTIFICATIONS, and the distinction is the
	whole design. A toast when you sell a bag is the game answering something you
	did; a card that appears because 165 seconds elapsed is an interruption. Only
	the second kind is rationed here -- ToastKit.toast and ToastKit.banner are not
	this file's to quieten and were left exactly as they were.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local ToastKit = require(Modules:WaitForChild("ToastKit"))
local TipConfig = require(Modules:WaitForChild("TipConfig"))

local player = Players.LocalPlayer

local TipClient = {}

--------------------------------------------------------------------------
-- CHOOSING ONE
--------------------------------------------------------------------------

-- What the rotation last put up. Only used to stop an immediate repeat -- see
-- poolOf. Commands deliberately DO NOT set it: typing /tipgroup twice should
-- show it twice, and it should not then bias what the rotation does next.
local lastId: string? = nil

local function shouldSkip(tip): boolean
	if type(tip.skipWhen) ~= "function" then
		return false
	end
	-- pcall'd: a skipWhen that throws must not be able to empty the pool and
	-- silence the whole feature. A tip that cannot answer the question is shown.
	local ok, res = pcall(tip.skipWhen, player)
	if not ok then
		warn("[Tips] skipWhen errored for '" .. tostring(tip.id) .. "': " .. tostring(res))
		return false
	end
	return res == true
end

local function poolOf(noRepeat: boolean)
	local pool = {}
	for _, t in ipairs(TipConfig.Tips) do
		if not shouldSkip(t) and not (noRepeat and t.id == lastId) then
			table.insert(pool, t)
		end
	end
	return pool
end

--[[
	WEIGHTED, and the weights are relative rather than percentages -- so adding a
	tip to TipConfig re-balances the list on its own instead of needing every
	other number edited to keep a total of 100.

	THE NO-REPEAT PASS HAS A FALLBACK ON PURPOSE. Excluding the last-shown tip is
	right almost always, but it can empty the pool -- one tip left unskipped, say,
	or a list that has been cut down to a single entry. Falling back to the full
	pool means the worst case is seeing the same tip twice; without it the worst
	case is the band going silent for the rest of the session, which is the same
	symptom as the feature being broken.
]]
local function pick()
	local pool = poolOf(true)
	if #pool == 0 then
		pool = poolOf(false)
	end
	if #pool == 0 then
		return nil
	end

	local total = 0
	for _, t in ipairs(pool) do
		total += math.max(0, t.weight or 1)
	end
	if total <= 0 then
		return pool[math.random(#pool)]
	end

	local roll = math.random() * total
	for _, t in ipairs(pool) do
		roll -= math.max(0, t.weight or 1)
		if roll <= 0 then
			return t
		end
	end
	-- Float drift only; the loop above all but always returns.
	return pool[#pool]
end

--------------------------------------------------------------------------
-- SHOWING ONE
--------------------------------------------------------------------------

-- `remember` is false for anything the player asked for by name, so a command
-- cannot steer the rotation. Returns the text shown, or nil.
local function show(tip, remember: boolean): string?
	if not tip then
		return nil
	end
	local text = TipConfig.textOf(tip)
	if type(text) ~= "string" or text == "" then
		return nil
	end
	if remember then
		lastId = tip.id
	end
	-- pcall'd for the same reason the loop below is: this is a decoration, and a
	-- decoration is never allowed to be the thing that kills a running thread.
	local ok, err = pcall(ToastKit.tip, text, tip.kind, TipConfig.Hold)
	if not ok then
		warn("[Tips] could not draw '" .. tostring(tip.id) .. "': " .. tostring(err))
		return nil
	end
	return text
end

-- Index into TipConfig.Tips, for the commands. Public so a command can show a
-- numbered tip without reaching into the pick/weight machinery above.
function TipClient.showIndex(i: number): string?
	local tip = TipConfig.Tips[i]
	return tip and show(tip, false) or nil
end

function TipClient.showRandom(): string?
	return show(pick(), true)
end

--------------------------------------------------------------------------
-- THE CLOCK
--------------------------------------------------------------------------

--[[
	ENABLED, NOT PRESENT.  Measured 2026-09-25, applied 2026-09-28.

	This tests PRESENCE, and it should test Enabled. Measured 81 seconds into a
	session: an IntroCinema ScreenGui is STILL SITTING IN PlayerGui, Enabled =
	false, with all seven of its children and a FitRoot. IntroClient's own
	gui:Destroy() ran -- the boot log prints "[Intro] done after 4.5s" -- and
	StarterGui holds no template, so something leaves a second one behind and it
	never goes away.

	So this returns true for the WHOLE SESSION, and the bounded wait below runs
	its full 30 seconds before every tip. The first slot lands at ~105s rather
	than the 75s TipConfig.FirstDelay advertises, and every gap after it is 30s
	longer than the config says. Confirmed both ways: with the fix in, the first
	tip fired at 75s; with it out, a recorder saw nothing by 66s.

	HELD FOR THREE DAYS, ON PURPOSE. The fix changes tip cadence for EVERY
	player, veterans included, and on 2026-09-25 it would have landed the day
	before the D1 read that tests whether the pet-card work moved retention. It
	was applied on 2026-09-28, once the cohorts that read covers were already
	fixed in history and could no longer be disturbed by a change shipped now.

	FreeRewardPanel carried the same defect and was fixed alongside this.
	TutorialHud.awaitIntro already checks `g.Enabled` and was always correct.

	STILL UNEXPLAINED, and worth somebody's time: nothing here says WHY a second
	disabled IntroCinema is left in PlayerGui. Testing Enabled works around it.
	Finding whatever creates it would remove the need for the workaround.
]]
local function introUp(): boolean
	local pg = player:FindFirstChild("PlayerGui")
	local intro = pg and pg:FindFirstChild("IntroCinema")
	return intro ~= nil and intro.Enabled
end

--[[
	HOW MANY ARE LEFT, asked fresh every slot rather than fixed at boot.

	`Rebirths` is replicated and lands with the profile, which is long settled by
	the time the first slot comes round at 75s -- but reading it late buys one
	more thing: a player who rebirths DURING a session has their allowance cut to
	the veteran one on the spot, and if they are already past it the rotation
	ends there. Somebody who has just ascended is the last person on the beach who
	needs to be told how the beach works.
]]
local function budget(): number
	if (tonumber(player:GetAttribute("Rebirths")) or 0) > 0 then
		return TipConfig.BudgetVeteran
	end
	return TipConfig.BudgetNew
end

-- Spent slots, not attempts. Only rotate() increments it; a tip called up by
-- name from chat is the player asking, and asking is never rationed.
local shown = 0

--[[
	THE OFF SWITCH, WAITED ON RATHER THAN POLLED. Somebody who turns the row off
	has almost always turned it off for the session, so a poll here would be a
	timer running for hours to answer "still no". The attribute signal costs
	nothing while it is off and wakes instantly if they change their mind.
]]
local function awaitEnabled()
	while not TipConfig.enabled(player) do
		player:GetAttributeChangedSignal(TipConfig.Attribute):Wait()
	end
end

local function rotate()
	task.wait(TipConfig.FirstDelay)
	while shown < budget() do
		--[[
			NEVER OVER THE OPENING SHOT.

			IntroCinema owns the screen behind an opaque curtain at DisplayOrder
			260 -- well over ToastKit's 16 -- so a tip shown during it is drawn,
			held for ten seconds and retired without anybody having seen a pixel
			of it. That is worse than skipping: it silently spends one of the
			rotation's slots, and the group line is the one most likely to be
			spent that way given how often it comes up.

			Same poll TutorialHud and FreeRewardPanel both use, and it has the
			same ceiling for the same reason -- an intro that never tears down
			must not silence the band for the whole session.
		]]
		local waited = 0
		while introUp() and waited < 30 do
			task.wait(0.5)
			waited += 0.5
		end

		awaitEnabled()

		--[[
			AND NEVER OVER SOMEBODY ELSE'S CARD. (2026-09-11)

			The band is anchored top-centre and placeBand does not move it, so
			unlike the toast column a tip cannot step aside -- it draws on top of
			whatever is there. The free-reward card is the one that made this
			visible: it is a centred modal with a scrim, raised on join and left up
			until it is answered, so a tip due at 75s landed straight across it.

			THIS PATH DOES NOT SPEND A SLOT -- it is the one exception to the rule
			in the next note. A card drawn behind a scrim teaches nobody anything,
			so charging the session's budget for it would quietly turn six tips
			into three for exactly the players who open the most panels. Retry,
			do not consume.
		]]
		if ToastKit.screenBusy() then
			task.wait(TipConfig.BusyRetry)
			continue
		end

		--[[
			COUNTED WHETHER OR NOT A CARD CAME OUT, and that is the right way
			round even though it looks generous. showRandom answers nil in exactly
			two cases: every tip's skipWhen is true, so the rotation has nothing to
			say; or ToastKit could not draw it, which it has already warned about.
			Retrying either one on a loop with no counter is how this file got its
			`while true` in the first place. A slot reached is a slot spent.
		]]
		--[[
			THE FIRST SLOT OF A FIRST PLAYTHROUGH IS SPENT, NOT ROLLED.

			See TipConfig.FirstTipId for the measurement. The short version: nothing
			in the opening shot or the tutorial ever says that coming back pays, so
			the rotation was the only channel that did -- and a third of players see
			exactly one tip before they go.

			ONLY THE FIRST SLOT, and only for somebody who has never turned a tide.
			The same test `budget` above uses, for the same reason it gives there:
			somebody who has ascended is the last person on the beach who needs to
			be told how the beach works.

			skipWhen IS STILL HONOURED. If the forced tip has retired itself the draw
			falls through to the normal pool rather than spending the slot on nothing
			-- the same contract poolOf keeps.

			`remember` is true, so the next slot will not repeat it. A forced first
			tip that then came up again at 285s would spend two of six on one line.
		]]
		local forced = nil
		if shown == 0
			and TipConfig.FirstTipId
			and (tonumber(player:GetAttribute("Rebirths")) or 0) == 0
		then
			local idx = TipConfig.find(TipConfig.FirstTipId)
			local candidate = idx and TipConfig.Tips[idx]
			if candidate and not (candidate.skipWhen and candidate.skipWhen(player)) then
				forced = candidate
			end
		end

		if forced then
			show(forced, true)
		else
			TipClient.showRandom()
		end
		shown += 1
		task.wait(math.random(TipConfig.GapMin, TipConfig.GapMax))
	end
end

--------------------------------------------------------------------------
-- CHAT COMMANDS
--------------------------------------------------------------------------
--[[
	/tip           one at random, exactly as the rotation would pick it
	/tips          the numbered list, printed into chat
	/tip1 .. /tipN one specific tip; /tipgroup, /tipwash ... are the same commands
	               under their names, which is what TipConfig.alias is for

	Built on TextChatService, which this place is already on (ChatVersion checked
	at start()). They are created HERE, on the client, which is what makes them
	client-only: TextChatCommand fires Triggered on the machine that typed it, and
	nothing about a tip needs the server's opinion.
]]

local function systemMessage(text: string)
	-- TextChannels and RBXGeneral are made at RUNTIME -- neither exists in the
	-- place file -- so this resolves them late and gives up quietly rather than
	-- erroring inside a chat handler.
	local channels = TextChatService:FindFirstChild("TextChannels")
	local general = channels and channels:FindFirstChild("RBXGeneral")
	if general then
		pcall(function()
			(general :: any):DisplaySystemMessage(text)
		end)
	end
end

local function command(name: string, primary: string, secondary: string?, fn)
	-- Rebuilt rather than reused. Aliases must be unique across every
	-- TextChatCommand in the DataModel, so a leftover from a previous run (a
	-- re-require, a live edit) would collide with the one being made now.
	local old = TextChatService:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	local cmd = Instance.new("TextChatCommand")
	cmd.Name = name
	cmd.PrimaryAlias = primary
	if secondary and secondary ~= "" then
		cmd.SecondaryAlias = secondary
	end
	cmd.Triggered:Connect(function()
		local ok, err = pcall(fn)
		if not ok then
			warn("[Tips] command " .. primary .. " failed: " .. tostring(err))
		end
	end)
	cmd.Parent = TextChatService
end

local function buildCommands()
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		-- The legacy chat has no TextChatCommand at all. Say so once rather than
		-- half-registering something that will never fire.
		warn("[Tips] chat commands need TextChatService; this place is on "
			.. tostring(TextChatService.ChatVersion))
		return
	end

	command("TipRandom", "/tip", nil, function()
		if not TipClient.showRandom() then
			systemMessage("[Tips] nothing to show.")
		end
	end)

	command("TipList", "/tips", "/tiplist", function()
		systemMessage(string.format("[Tips] %d tips. /tip for a random one.",
			#TipConfig.Tips))
		for i, t in ipairs(TipConfig.Tips) do
			local text = TipConfig.textOf(t)
			if #text > 58 then
				text = string.sub(text, 1, 57) .. "\u{2026}"
			end
			systemMessage(string.format("  /tip%d  (/tip%s)  %s", i, t.alias, text))
		end
	end)

	for i, t in ipairs(TipConfig.Tips) do
		-- Numbered alias plus the named one, which is the whole reason
		-- TipConfig carries an `alias` field: /tip1 is quick to type and
		-- /tipgroup is the one you can remember a week later.
		command("Tip_" .. t.id, "/tip" .. i, "/tip" .. t.alias, function()
			TipClient.showIndex(i)
		end)
	end
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

local started = false

function TipClient.start()
	if started then
		return
	end
	started = true

	if TipConfig.CommandsInLiveGame or RunService:IsStudio() then
		local ok, err = pcall(buildCommands)
		if not ok then
			warn("[Tips] chat commands would not register: " .. tostring(err))
		end
	end

	-- Spawned, not called: rotate() is a wait loop that never returns, and this
	-- is started from ClientMain where blocking would cost everything below it.
	task.spawn(function()
		local ok, err = pcall(rotate)
		if not ok then
			warn("[Tips] the rotation stopped: " .. tostring(err))
		end
	end)
end

return TipClient
