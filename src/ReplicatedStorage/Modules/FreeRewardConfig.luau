--[[
	FreeRewardConfig  --  ReplicatedStorage.Modules.FreeRewardConfig

	The one-off group reward: 1,000 coins, once per account, for being in the
	experience's group.

	EVERY REQUIREMENT THAT PAYS IS ONE THE SERVER VERIFIES WITH ROBLOX. There is
	exactly one of them:

		JOIN THE GROUP   Player:IsInGroup(GroupId), asked of Roblox BY THE SERVER
		                 at the moment of the claim. A client cannot fake it,
		                 cannot skip it and cannot ask the server to skip it --
		                 the remote carries a verb and nothing else.

	IT USED TO ASK FOR A LIKE AS WELL. THAT HALF IS GONE, for two separate
	reasons, either of which is enough on its own.

		NOT CHECKABLE    Roblox exposes NO API for whether a player has liked or
		                 favourited an experience -- there is no IsLiked, no
		                 IsFavorited, no GetLikeStatus on Player, on
		                 MarketplaceService or anywhere else. Measured, not
		                 assumed. So the step could only ever be a button a player
		                 pressed to assert something about themselves, and the
		                 server had no choice but to take their word: press it,
		                 claim, paid. Which is precisely the complaint that got
		                 this rewritten.

		NOT ALLOWED      Roblox's own rules forbid rewarding an INDIVIDUAL player
		                 for liking or favouriting an experience. (A milestone
		                 offered to EVERYBODY -- "free pet at 20k likes" -- is a
		                 different thing and is fine.) So even a magic like API
		                 would not make this a reward we are permitted to pay.

	Rewarding a group join is both checkable and permitted, which is why it is the
	one requirement left standing.

	DO NOT ADD THE LIKE BACK AS A GATE. A client-reported "I liked it" boolean is
	worth exactly nothing -- it is the player's own machine answering a question
	about the player -- and dressing it up as a check would be worse than not
	having it, because the next person reading the code would believe it. Asking
	for a like is fine; PAYING for one is the part that is not.
]]

-- For groupName() at the foot of this file. GroupService is the web call; it is
-- fenced behind RunService:IsServer() because this module is replicated.
local GroupService = game:GetService("GroupService")
local RunService = game:GetService("RunService")

local FreeRewardConfig = {}

-- The experience's own group. Read off game.CreatorId rather than typed, so it
-- cannot drift if the place is ever moved: this place is group-owned (verified
-- CreatorType == Group at the time of writing) and the reward is for joining
-- THAT group. The literal is the fallback for a place that has been copied into
-- a personal account, where CreatorId is a user id and no group check is
-- meaningful.
local FALLBACK_GROUP = 4620487
FreeRewardConfig.GroupId = (game.CreatorType == Enum.CreatorType.Group)
	and game.CreatorId or FALLBACK_GROUP

FreeRewardConfig.Coins = 1000

-- Saved, and held once set -- the same shape SaveService already uses for
-- `tutorialDone` and `starterPackClaimed`. A session flag would pay out again on
-- every server the player ever joins.
FreeRewardConfig.ClaimedAttribute = "FreeRewardClaimed"
-- Published by the server after it asks Roblox. The client may READ this to
-- paint a button and may never write it -- and a client that writes it anyway
-- changes nothing, because an attribute set on the client does not replicate
-- upward. The server's copy is always the server's own answer.
FreeRewardConfig.InGroupAttribute = "InRewardGroup"

--[[
	THE RESOLVED NAME, PUBLISHED FOR THE CLIENT.

	groupName() below is IsServer-gated, so a client calling it gets the fallback
	literal. That was fine while only the panel and the boards named the group --
	both are server-side. It stopped being fine the moment a CLIENT string used
	it: TipConfig's `group` tip builds its line from GroupName and runs on the
	client, so it advertised "Join the Clean the Beach group" while the five
	boards it points at read "JOIN THE SPEEDY CLOTHES GROUP".

	Caught 2026-09-25 by rendering the tip on a live client. A player following
	that tip would go looking for a group that does not exist under that name --
	which is the exact defect the board fix was written to remove, reintroduced
	one layer up.

	So the server writes what it resolved onto the player and the client reads it
	back. One attribute, set beside the sync payload that already carries the
	same string.
]]
FreeRewardConfig.GroupNameAttribute = "RewardGroupName"

-- The name as anybody can see it, server or client. Falls back to the literal,
-- so a client that asks before the first sync gets the old answer rather than
-- an empty one.
function FreeRewardConfig.groupNameFor(player: Instance?): string
	if player then
		local v = player:GetAttribute(FreeRewardConfig.GroupNameAttribute)
		if type(v) == "string" and v ~= "" then
			return v
		end
	end
	return FreeRewardConfig.GroupName
end

-- Shown on the panel and on the board so a player knows where to go. Not a
-- clickable link: an in-experience script cannot open a browser window (that API
-- is RobloxScriptSecurity), so the honest thing is to name the group and let
-- them find it from the experience page.
--
-- RE-MEASURED 2026-09-22 and the note above is CORRECT, which is worth recording
-- because it was worth doubting: from a LocalScript in a running Play session,
-- BOTH GuiService:OpenBrowserWindow and GuiService:OpenNativeOverlay refuse with
-- "lacking capability RobloxScript". There is no clickable route to the group
-- page from inside an experience. Naming it is the whole of what we can do --
-- which is exactly why the name has to be RIGHT.
--
-- A FALLBACK ONLY, AND IT WAS WRONG. This line used to be the single source of
-- the name, and group 4620487 is not called "Clean the Beach" -- it is called
-- "Speedy Clothes". So the panel and all five boards spent their lives telling
-- every player to go and find a group that does not exist under that name, and
-- a 1,000-coin reward nobody outside the group could discover their way into.
--
-- Typing the name was the mistake, and it is the same mistake GroupId above
-- already refuses to make by reading game.CreatorId. Ask Roblox. See groupName().
FreeRewardConfig.GroupName = "Clean the Beach"

--[[
	WHERE THE BOARDS STAND: mirrored from the leaderboards, on every field that
	has them.

	LeaderboardConfig.Sites puts a row of three on a field's LEFT edge (side -1);
	these stand the same distance out on the RIGHT (side 1), facing back the other
	way, so the two read as a matched pair from the middle of any field.

	The geometry is not repeated here. LeaderboardConfig.boardLine resolves a site
	to a world line off CTB.Config.ISLANDS, and both signs call it -- so a field
	that is ever moved or resized takes BOTH of its signs with it, and the two can
	never end up disagreeing about where its edge is.

	KEEP THIS LIST IN STEP WITH LeaderboardConfig.Sites. The three sealed
	interiors are absent from both for the reasons set out there; the Vault cannot
	take a board of this size at all.

	THE DUNES CACTUS TOOK TWO GOES, and the second is the one worth remembering.
	A cactus in Island2.DesertDressing stands about 11 studs off that field's
	right-hand edge, so the default clearance of 10 puts the sign inside it; +20
	cleared the COLLISION and the sign was still unreadable, because the cactus
	was then standing squarely in front of its face. Pushing a sign further out
	cannot fix a blocker that sits between it and the field -- it makes it worse.
	The fix is `along`: slide it down the edge to a stretch with nothing on it.

	So: check a moved sign against what can be SEEN through, not what stops a
	raycast -- the volume in front of the face, any part with Transparency < 0.9.

		Dunes  -24  clear of the cactus, and near the leaderboards' own -36 so
		            the two still read as a pair across the field.
		Cove   -36  matches the shift LeaderboardConfig.Sites makes for the sakura
		            trunk and the mound behind it, so this pair stays face to face
		            too. Ground here is flat sand at y 3.0 either way.

	The Y is a starting height only -- the builder raycasts for the ground
	actually under each one, the same way LeaderboardBuilder does.
]]
FreeRewardConfig.Sites = {
	{ island = 1, side = 1 },                                -- Beach, unchanged: x 138
	{ island = 2, side = 1, clearance = 20, along = -24 },   -- Dunes -- see the cactus note
	{ island = 4, side = 1, along = -36 },                   -- Sakura Cove -- matches the row
	{ island = 5, side = 1 },                                -- Ashfall Isle
	{ island = 8, side = 1 },                                -- Penguin Island -- the east edge is kept clear for it
}

--[[
	THE REAL NAME, ASKED OF ROBLOX, ONCE PER SERVER.

	SERVER-ONLY. GroupService is a web call and this module is replicated, so a
	client that calls it is handed the fallback rather than a yield it never asked
	for. The client has no need of it anyway: the panel reads the name off the
	server's sync payload, and the boards are server-built.

	CACHED, because the answer cannot change inside one server's life, and the
	first caller is the only one that should pay for the round trip.

	PCALL'D, because a lookup that fails must cost the correct SPELLING and not
	the board: a dropped request falls back to the literal above and the sign
	still goes up.

	RENAME THE GROUP AND THIS FOLLOWS IT, with no code change and no republish
	beyond the next server boot: whatever the group is called when a server starts
	is what the panel and all five boards say.
]]
local cachedGroupName: string? = nil
function FreeRewardConfig.groupName(): string
	if cachedGroupName then
		return cachedGroupName
	end
	if not RunService:IsServer() then
		return FreeRewardConfig.GroupName
	end
	local ok, info = pcall(function()
		return GroupService:GetGroupInfoAsync(FreeRewardConfig.GroupId)
	end)
	if ok and type(info) == "table" and type(info.Name) == "string" and info.Name ~= "" then
		cachedGroupName = info.Name
	else
		warn(string.format("[FreeReward] could not read the name of group %d (%s) -- "
			.. "falling back to %q", FreeRewardConfig.GroupId, tostring(info),
			FreeRewardConfig.GroupName))
		cachedGroupName = FreeRewardConfig.GroupName
	end
	return cachedGroupName
end

return FreeRewardConfig
