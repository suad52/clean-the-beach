--[[
	SettingsServer  --  ServerScriptService.SettingsServer


	THE SETTINGS THAT SURVIVE A REJOIN -- all seven of them.

	MenuHud's Settings panel used to be client-only by design, on the argument
	that a preference about what this machine draws needs no server. What that
	missed is that the SAME MACHINE comes back tomorrow: a player who turns the
	music off, hides the other beachgoers and drops the fancy shadows because
	their phone is struggling had to do all three again on every single join, and
	the reasons they did it the first time have not changed.

	HUD SIZE CAME FIRST AND IS STILL THE STRONGEST CASE, because forgetting it is
	circular: every other row is a taste you notice and flip back, and that one is
	the size of the interface you would use to flip it back. The rest followed
	once the mechanism existed -- there is no version of "remember this" that is
	right for one row and wrong for the six beside it.


	THE ATTRIBUTE IS THE STATE, and there is no second table in here shadowing it.

	A saved setting lives exactly where the unsaved ones live -- a `Set_<key>`
	attribute on the player -- and this file simply writes that one from the
	SERVER instead of from the client, so it replicates and so `exportFor` has
	something to read at save time. One value, one home, and the panel's read path
	is identical for a saved row and an unsaved one.


	WHITELISTED IN BOTH DIRECTIONS. `SAVED` names the keys that may be stored at
	all, and each carries the set of values it will accept. A remote that took a
	key and a value on trust would be a way to write arbitrary data into another
	player's profile under a name of the sender's choosing -- so the key must be
	in the table and the value must be one this build recognises, or nothing is
	written and nothing is answered.

	The HUD Size values come from UiFit.STEPS rather than being listed again here,
	so a step added or renamed there cannot leave this file accepting a value the
	client can no longer draw.


	WHAT SAVING THEM COSTS, written down because it is a real trade rather than a
	free win: a preference is now shared across a player's DEVICES. Somebody who
	mutes the music on a phone finds it muted on their PC. That is the correct
	call for the four that are about a machine struggling or about not wanting to
	look at something (Shadows, HideSquares, HideOthers, ScreenShake) and it is
	arguable for the two audio rows, which are often situational. They are in
	anyway, because a settings panel where two rows quietly forget and five do not
	is worse than either rule applied honestly -- and a player who wants the music
	back presses one button.

	ONLY WHAT WAS ACTUALLY CHOSEN IS STORED. The panel writes its attributes on
	the CLIENT at boot from `opt.default`, and a client write never reaches the
	server -- so an account that has never opened this panel saves nothing at all
	and keeps whatever the defaults become in a later build.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Net = require(Modules:WaitForChild("Net"))
-- For the list of valid HUD sizes. Data only -- UiFit.start() is the client's
-- business and is never called from here.
local UiFit = require(Modules:WaitForChild("UiFit"))
-- For the auto-release rungs alone. Pure data; PetConfig owns which tiers may be
-- chosen and this file only has to whitelist the same set. See PetAutoRelease.
local PetConfig = require(Modules:WaitForChild("PetConfig"))
-- For the daylight rungs alone. Same arrangement as PetConfig above: that module
-- owns which rungs exist and this one only has to whitelist the same set.
local DaylightConfig = require(Modules:WaitForChild("DaylightConfig"))
-- For the Helpful Tips key only, so the row's name is written once and both
-- sides of the save read it from there.
local TipConfig = require(Modules:WaitForChild("TipConfig"))

local SettingsServer = {}

local started = false

-- The panel writes `Set_<key>`; this is the same prefix, from the other side.
local PREFIX = "Set_"

local function hudSizeValues(): { [any]: boolean }
	local set = {}
	for _, step in ipairs(UiFit.STEPS) do
		set[step.key] = true
	end
	return set
end

-- Every toggle in the panel is a plain on/off, so they all share one value set.
-- Written as a function rather than a shared table so no row can be handed a
-- reference another row could edit.
local function boolValues(): { [any]: boolean }
	return { [true] = true, [false] = true }
end

--[[
	ONE ROW PER SAVED SETTING, in the order the panel draws them.

	The keys match MenuHud's SETTINGS table and its HUD Size row exactly, because
	both sides address the same `Set_<key>` attribute. A key here that the panel
	does not write is dead weight; a key the panel writes that is NOT here is
	simply not saved, which is a safe default and is what every one of these was
	until 2026-09-08.
]]
local SAVED = {
	{ key = "HudScale", values = hudSizeValues() },
	{ key = "Music", values = boolValues() },
	{ key = "SFX", values = boolValues() },
	{ key = "ScreenShake", values = boolValues() },
	-- The general form of ScreenShake and Flash. Saved for the same reason they
	-- are: a player who has asked for less motion has asked once, not once per
	-- session. Modules.Motion reads the attribute this writes.
	{ key = "ReducedMotion", values = boolValues() },
	{ key = "HideOthers", values = boolValues() },
	-- Your own pets, which Hide Other Beachgoers never covered: it matches every
	-- OTHER player's by name prefix and skips yours. MenuHud owns the sweep.
	{ key = "HidePets", values = boolValues() },
	{ key = "Shadows", values = boolValues() },
	{ key = "HideSquares", values = boolValues() },
	--[[
		YOUR OWN ARMS IN FIRST PERSON -- FirstPersonView reads it.

		Saved for the reason every row here is, and this one has a sharper version
		of it than most: the player who asked had scrolled all the way in and stayed
		there, so it is their normal camera rather than a look they took once. A
		switch that forgot would put the arms back in front of their face on every
		single join.
	]]
	{ key = "HideArms", values = boolValues() },
	--[[
		THE WASH BAY, FOR INSTANT WASH OWNERS -- WashServer.tryInstantBag reads it.

		Saved like the rest, and note it is saved for EVERY player rather than only
		for owners: the panel hides the row from people who do not own the pass,
		but hiding a row is a drawing decision and this list is a storage one. A
		value written before a purchase -- or left behind after a refund -- is one
		boolean, and the alternative is a gate here that has to agree with a gate
		in MenuHud forever.
	]]
	{ key = "SkipWashBay", values = boolValues() },
	--[[
		HIDE YOUR OWN VIP TAG -- VipService reads it when it decides whether to
		build the billboard.

		Stored for everyone rather than gated on owning the pass, which is exactly
		the call the note above makes for SkipWashBay and for the same reason: a
		value written before a purchase, or left behind after a refund, is one
		boolean, and the alternative is a gate here that has to agree with a gate in
		MenuHud forever.
	]]
	{ key = "HideVipTag", values = boolValues() },
	--[[
		WHO MAY INVITE YOU TO TRADE -- TradeService reads it at the invite.

		Saved, and this row would be the worst one in the list to forget. Somebody
		turns trade requests off BECAUSE strangers are interrupting them; a switch
		that quietly flips back on at the next join hands them the exact thing they
		asked to be rid of, from a player who has no idea they already said no.
	]]
	{ key = "TradeRequests", values = boolValues() },
	--[[
		THE WASH RIG'S MOTOR AND SPRAY -- WashClientController's rigGain reads it.

		Saved for the ordinary reason, and with a sharper edge than most: the
		player who asked had already turned the whole SFX bus off and back on
		looking for this. A switch that forgot itself would send them round that
		loop again on their next join.
	]]
	{ key = "WashSounds", values = boolValues() },
	--[[
		The white-out, wherever the game throws one. Asked for by a player on
		2026-09-09 -- "I'd like a flash on/off option in the settings" -- and
		CTB_Client's own note on the pickup glow had already written the case:
		point lights ADD, so a wide sifter dragged through a line of litter pops
		several finds inside a second and the foreground goes white on every pass.

		TWO CLIENTS READ IT, which is why the key is not "PickupFlash": CTB_Client
		for the find's light and sparks, EggClient for the hatch reveal's
		full-screen frame and the burst that lands on it. Saved like every other
		row here, so the choice survives a rejoin -- and this is one of the rows
		the note above is squarely right about sharing across devices: somebody
		who turns flashes off on a phone wants them off on a PC too.
	]]
	{ key = "Flash", values = boolValues() },
	--[[
		THE HINT BAND. Asked for on 2026-09-10: "fun game but i hate the random pop
		ups.. ruins the calmness of the game".

		The rotation was given an end the same day -- six tips a session, two once
		past the first rebirth, where before it ran for as long as the session did.
		This row is for the players that is still too many for.

		SAVED, and this is a row where forgetting would be the whole bug. Somebody
		who turned tips off did it BECAUSE they did not want to be interrupted; a
		switch that quietly flips back on at the next join hands them the exact
		thing they asked to be rid of, and makes them ask twice. Same argument the
		Flash note above makes about carrying across devices, and it applies here
		for the same reason.

		TipClient is the only reader. TipConfig.Attribute is this key's `Set_` name.
	]]
	{ key = TipConfig.SettingKey, values = boolValues() },
	--[[
		THE PET AUTO-RELEASE FLOOR, and it is the first row here that is not a
		toggle -- the value is a TIER INDEX, 0 for off.

		WHITELISTED FROM PetConfig'S OWN LIST rather than from a range check. The
		obvious `values` here is "any number 0..7", and it would be wrong in the
		one direction that matters: PetConfig deliberately stops the ladder at
		Legendary so nothing can be set to auto-destroy a Mythic, and a range test
		here would quietly re-open exactly that. Built from the same table the panel
		draws, so the two cannot disagree about which rungs exist.

		SAVED like every other row, and this is one where it really matters: a
		filter that silently forgot itself between sessions would either stop
		working (annoying) or, if it defaulted ON, start releasing pets somebody
		never asked it to (unforgivable). It defaults to OFF, so a profile with no
		value keeps everything.
	]]
	{ key = "PetAutoRelease", values = (function()
		local set = {}
		for _, step in ipairs(PetConfig.AutoReleaseSteps) do
			set[step.index] = true
		end
		return set
	end)() },
	--[[
		THE SKY. Asked for on 2026-09-11 -- "can you make it night time option? the
		light from the sand area hurts my eyes".

		The value is a STRING KEY ("Day" / "Dusk" / "Night"), not an hour, and
		DaylightConfig's header says why: "Day" is the absence of an override
		rather than a time, so it has no number to be stored as.

		SAVED, and this is one of the rows where that matters most. Somebody turns
		this on because the brightness is physically uncomfortable; handing them a
		white beach again on every join would be the setting failing at the one job
		it has.
	]]
	{ key = DaylightConfig.SettingKey, values = DaylightConfig.values() },
}

local function ruleFor(key: any)
	if type(key) ~= "string" then
		return nil
	end
	for _, rule in ipairs(SAVED) do
		if rule.key == key then
			return rule
		end
	end
	return nil
end

--------------------------------------------------------------------------
-- PERSISTENCE  (SaveService's exportFor / restore pair)
--------------------------------------------------------------------------
--[[
	Read straight off the attributes, which is the point of keeping the state
	there: there is nothing to keep in step, and a value the player changed a
	millisecond before the save is already in it.

	AN EMPTY TABLE RATHER THAN NIL when nothing is set. SaveService's `blank()`
	is the KEY LIST its payload builder iterates, so a field that can read back as
	nil needs a non-nil default there anyway -- see the warning on `boost`.
]]
function SettingsServer.exportFor(player: Player)
	local out = {}
	for _, rule in ipairs(SAVED) do
		local v = player:GetAttribute(PREFIX .. rule.key)
		if v ~= nil and rule.values[v] then
			out[rule.key] = v
		end
	end
	return out
end

--[[
	VALIDATED AGAINST THE SAME WHITELIST ON THE WAY BACK IN, not just on the way
	out. The blob has been through a datastore and a schema migration, and a build
	that has since dropped a step must not restore a player into a size it can no
	longer draw -- they would be left with a HUD they cannot fix from a panel they
	cannot read.
]]
function SettingsServer.restore(player: Player, blob: any)
	if type(blob) ~= "table" then
		return
	end
	for _, rule in ipairs(SAVED) do
		local v = blob[rule.key]
		if v ~= nil and rule.values[v] then
			player:SetAttribute(PREFIX .. rule.key, v)
		end
	end
end

--------------------------------------------------------------------------
-- THE REMOTE
--------------------------------------------------------------------------
function SettingsServer.start()
	assert(RunService:IsServer(), "[SettingsServer] server-only")
	if started then
		return
	end
	started = true

	Net.get("SettingSave").OnServerEvent:Connect(function(player, payload)
		if type(payload) ~= "table" then
			return
		end
		local rule = ruleFor(payload.key)
		-- Silence rather than a refusal message: there is no legitimate client that
		-- can send an unknown key, so there is nobody to tell. The panel already
		-- applied the change locally either way -- saving is the only thing at stake
		-- here, and a dropped save is the correct outcome for a value this build
		-- does not recognise.
		if not rule or payload.value == nil or not rule.values[payload.value] then
			return
		end
		--[[
			WRITING THE ATTRIBUTE IS THE WHOLE SAVE. It replicates back to the owner
			(harmlessly -- they already hold this value, so the client's own listener
			sees no change), and it is what `exportFor` reads when SaveService next
			collects. Nothing is written to the datastore here: the profile is dirty
			by the periodic and leave saves like everything else, and a settings
			press is not worth a forced write.
		]]
		player:SetAttribute(PREFIX .. rule.key, payload.value)
	end)

	print(string.format("[Settings] online -- %d saved preference(s)", #SAVED))
end

return SettingsServer
