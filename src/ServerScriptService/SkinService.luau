--[[
	SkinService  --  ServerScriptService.SkinService

	WHO OWNS WHICH SIFTER SKIN, WHICH ONE THEY ARE WEARING, AND THE ONE PLACE
	EITHER OF THOSE CAN CHANGE.

	Three facts per player, all published as Player attributes because that is
	the channel the client already watches for RollerWidth:

		SkinOwn_<key>   boolean, one per skin. Stamped true, never cleared -- a
		                rebirth takes your levels, not your wardrobe.
		SkinChosen      what you wear everywhere. Persisted by SaveService.
		SkinActive      what you are wearing this second. DERIVED, never saved.

	THE ROOM WINS WHILE YOU ARE IN IT. `SkinActive` is recomputed on a slow tick
	as `(the room's own skin, if you own it) or SkinChosen`, so walking into the
	tomb puts the gold sifter in your hands and walking out of it hands your own
	choice back. Nothing about that is saved, which is the point: the override is
	a place, not a decision.

	WHY THE CLAIM IS A DISTANCE TEST AND NOT A PROMPT
	-------------------------------------------------
	PetServer's header makes the case for engine-validated ProximityPrompts over
	remotes, and it is right -- for anything a player has to CHOOSE to do. This
	is not that: the brief is that walking up to the centrepiece is enough, so
	there is no keypress to validate. What replaces the prompt is that the test
	happens HERE, on the server, against the server's own copy of the character
	and the server's own record of where the plinth is. The client is never
	asked, sends nothing, and cannot claim anything by saying it is somewhere.

	The cost is one distance check per player per TICK against at most three
	registered plinths, and only for players whose Config.zoneAt is a room that
	has one -- which is nobody, almost all of the time.

	THE HOLD, and it is the only fiddly thing in here. Claiming fires the
	ceremony on the client, and that animation takes SkinConfig.Ceremony.handoff
	seconds to fly the new tool across the room. Writing SkinActive immediately
	would re-forge the sifter in the player's hands before the display had left
	its plinth, so the sync is HELD until the comet lands. It is a deadline
	rather than a flag: a player who dies, leaves the room or logs out mid-flight
	simply has it expire, and the next tick puts them in the right skin.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CTB = ReplicatedStorage:WaitForChild("CTB")
local Config = require(CTB:WaitForChild("Config"))
local Net = CTB:WaitForChild("Net")
-- The module Net, NOT the CTB remote above. That one is a shared action bus with
-- a live OnServerEvent handler in CTB_Server; a dedicated remote is what every
-- other panel-driven action in this game uses (PetEquip, ClaimReward), and it
-- keeps a malformed skin payload out of that bus entirely.
local NetModule = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Net"))
local SkinConfig = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("SkinConfig"))

local SkinService = {}

--------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------
-- [Player] = { owned = { [key] = true }, chosen = key, active = key, hold = 0 }
local state = {}

-- [skinKey] = { pos = Vector3, island = id }. Filled by SkinPlinthBuilder as
-- each room's stand goes up, so a room that failed to build simply has no
-- claim point rather than a claim point hanging in the void.
local plinths = {}

-- Suppressed while a profile is being written back on, exactly as SaveService's
-- own `restoring` flag is: a restore is not a change and must not mark the
-- profile dirty from inside the load that produced it.
local restoring = {}

--[[
	THE PERSISTENCE SEAM. SaveService WRAPS this rather than assigning it (see
	note 2 in that file), so anything else that ever wants to hear about a skin
	change can do the same. Nil until somebody claims it, which is the honest
	state for a server with no persistence configured.
]]
SkinService.OnSkinsChanged = nil

local TICK = 0.2

--------------------------------------------------------------------------
-- READ / WRITE
--------------------------------------------------------------------------
local function get(player: Player)
	local s = state[player]
	if not s then
		s = {
			-- Everybody owns the steel one. It is not a reward and there is
			-- nowhere to claim it, so it is simply true from the first frame.
			owned = { [SkinConfig.DefaultKey] = true },
			chosen = SkinConfig.DefaultKey,
			active = SkinConfig.DefaultKey,
			hold = 0,
		}
		state[player] = s
	end
	return s
end

local function announce(player: Player)
	local s = state[player]
	if not s or restoring[player] then
		return
	end
	local hook = SkinService.OnSkinsChanged
	if hook then
		hook(player, table.clone(s.owned), s.chosen)
	end
end

-- Attributes are the replication. Written only when they actually move: a
-- SetAttribute to the value already there still fires the changed signal on
-- every client watching it, and the client's answer to that signal is to
-- rebuild the tool in the player's hands.
local function publish(player: Player)
	local s = get(player)
	for _, skin in ipairs(SkinConfig.Skins) do
		local want = s.owned[skin.key] == true
		local attr = SkinConfig.OwnPrefix .. skin.key
		if (player:GetAttribute(attr) == true) ~= want then
			player:SetAttribute(attr, want or nil)
		end
	end
	if player:GetAttribute(SkinConfig.ChosenAttribute) ~= s.chosen then
		player:SetAttribute(SkinConfig.ChosenAttribute, s.chosen)
	end
	if player:GetAttribute(SkinConfig.ActiveAttribute) ~= s.active then
		player:SetAttribute(SkinConfig.ActiveAttribute, s.active)
	end
end

--------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------
function SkinService.owns(player: Player, key: string): boolean
	return get(player).owned[key] == true
end

function SkinService.chosenOf(player: Player): string
	return get(player).chosen
end

--[[
	HAND OVER A SKIN. Returns true only when it was NEW, which is what the
	claim path keys the ceremony off -- a second grant of the same skin is a
	no-op rather than a second title card.

	Granting also CHOOSES it. Somebody who has just walked the length of a tomb
	to claim a gold sifter wants to be holding a gold sifter, and asking them to
	go and equip it somewhere else would be the one wrong answer here.
]]
function SkinService.grant(player: Player, key: string): boolean
	if not SkinConfig.exists(key) then
		warn("[Skins] refused to grant unknown skin '" .. tostring(key) .. "'")
		return false
	end
	local s = get(player)
	if s.owned[key] then
		return false
	end
	s.owned[key] = true
	s.chosen = key
	publish(player)
	announce(player)
	return true
end

-- Wear it everywhere. Refuses a skin the player does not own -- there is no
-- path that can ask for one today, and the day there is, this is where it
-- should be stopped rather than three modules downstream.
function SkinService.choose(player: Player, key: string): boolean
	local s = get(player)
	if not (SkinConfig.exists(key) and s.owned[key]) or s.chosen == key then
		return false
	end
	s.chosen = key
	publish(player)
	announce(player)
	return true
end

--------------------------------------------------------------------------
-- THE PLINTH REGISTER
--------------------------------------------------------------------------
-- Called by SkinPlinthBuilder once each stand is standing. Position is the
-- claim POINT -- the middle of the base at floor level -- rather than the
-- hovering display, so the radius measures a walk rather than a reach.
function SkinService.registerPlinth(key: string, islandId: number, pos: Vector3)
	if not SkinConfig.exists(key) then
		warn("[Skins] refused to register a plinth for unknown skin '" .. tostring(key) .. "'")
		return
	end
	plinths[key] = { pos = pos, island = islandId }
end

function SkinService.plinthFor(key: string)
	return plinths[key]
end

--------------------------------------------------------------------------
-- THE TICK
--------------------------------------------------------------------------
local function step(player: Player)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end
	local s = get(player)
	local pos = hrp.Position

	-- Which room, if any. zoneAt is the right question rather than fieldAt: the
	-- plinths stand OUTSIDE the rakeable square (they have to -- see the
	-- blocked-cell rule in Config) and a player standing at one is therefore
	-- not on the field at all.
	local zone = Config.zoneAt(pos)
	local skin = SkinConfig.forIsland(zone and zone.id or nil)

	if skin then
		local p = plinths[skin.key]
		if p and (pos - p.pos).Magnitude <= SkinConfig.ClaimRadius then
			if SkinService.grant(player, skin.key) then
				-- Held until the comet lands, so the tool re-forges on the
				-- impact rather than while the display is still on its stand.
				s.hold = os.clock() + SkinConfig.Ceremony.handoff
				Net:FireClient(player, "SkinUnlock", skin.key, skin.island)
			elseif SkinService.choose(player, skin.key) then
				Net:FireClient(player, "SkinPick", skin.key, skin.island)
			end
		end
	end

	if os.clock() < s.hold then
		return
	end

	local want = (skin and s.owned[skin.key]) and skin.key or s.chosen
	if s.active ~= want then
		s.active = want
		publish(player)
	end
end

--------------------------------------------------------------------------
-- PERSISTENCE SEAM  --  SaveService calls these two and nothing else
--------------------------------------------------------------------------
function SkinService.exportFor(player: Player)
	local s = state[player]
	if not s then
		return nil
	end
	return { owned = table.clone(s.owned), chosen = s.chosen }
end

--[[
	Validated on the way in rather than trusted, the same rule
	PetServer.restore and SaveService.migrate both follow: a profile written by
	an older build must degrade to a sane player. An unknown key is dropped, a
	chosen skin the player does not own falls back to the steel one, and
	anything that is not a table at all leaves them exactly as they were.

	OWNERSHIP IS UNIONED, NEVER REPLACED. A restore that raced a claim -- the
	profile lands a beat after somebody walked into the tomb -- must not take
	the gold sifter back off them.
]]
function SkinService.restore(player: Player, data)
	local s = get(player)
	restoring[player] = true

	if type(data) == "table" then
		if type(data.owned) == "table" then
			for key, on in data.owned do
				if on == true and SkinConfig.exists(key) then
					s.owned[key] = true
				end
			end
		end
		if SkinConfig.exists(data.chosen) and s.owned[data.chosen] then
			s.chosen = data.chosen
		end
	end

	s.owned[SkinConfig.DefaultKey] = true
	if not s.owned[s.chosen] then
		s.chosen = SkinConfig.DefaultKey
	end
	-- Recomputed on the next tick anyway; set here so a returning player's very
	-- first frame draws the tool they left in rather than a steel one that
	-- swaps a fifth of a second later.
	if os.clock() >= s.hold then
		s.active = s.chosen
	end

	restoring[player] = nil
	publish(player)
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------
local started = false

function SkinService.start()
	assert(RunService:IsServer(), "[SkinService] server-only")
	if started then
		return
	end
	started = true

	local function onJoin(player: Player)
		-- Stamped before the profile lands, so a player whose save is slow (or
		-- whose place has no API access at all) still gets a tool with a
		-- palette rather than a client falling back on every read.
		publish(player)
	end

	Players.PlayerAdded:Connect(onJoin)
	for _, player in Players:GetPlayers() do
		onJoin(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		state[player] = nil
		restoring[player] = nil
	end)

	-- One loop for the whole server rather than a connection per player. TICK
	-- is 0.2s: the claim circle is 14 studs across and the fastest a player
	-- moves is 66 studs a second (the top of the WalkSpeed track), so even a
	-- sprint cannot cross it between two ticks.
	task.spawn(function()
		while true do
			task.wait(TICK)
			for _, player in Players:GetPlayers() do
				-- Per player, so one bad character cannot stop the sweep for
				-- everybody else on the server.
				local ok, err = pcall(step, player)
				if not ok then
					warn("[Skins] tick failed for " .. player.Name .. ": " .. tostring(err))
				end
			end
		end
	end)

	--[[
		THE WARDROBE'S ONE REMOTE.

		Until now `choose` had exactly two callers -- walking onto a plinth you
		already own, and the VIP pass -- which meant a skin with no plinth could be
		worn once and never again. That was survivable while the only plinth-less
		skin was VIP's (you are handed it and most players never own a second), and
		it stopped being survivable the moment three EARNED skins arrived with no
		stand behind them: claiming the second rung stranded the first.

		NOTHING IS TRUSTED HERE. `choose` already refuses a key this build does not
		know and a skin the player does not own -- it is the same function the
		plinth path calls -- so this adds a door, not an exemption. The type check
		is only so a malformed payload cannot reach it at all.

		NO REPLY. choose() publishes on success, which is what moves the tool and
		repaints every wardrobe tile watching the attribute. A refusal is silent on
		purpose: the only way to ask for a skin you do not own is a tampered client.
	]]
	NetModule.get("SkinChoose").OnServerEvent:Connect(function(player, key)
		if type(key) ~= "string" then
			return
		end
		SkinService.choose(player, key)
	end)

	print("[Skins] wardrobe online -- " .. #SkinConfig.claimable() .. " claimable skins")
end

return SkinService
