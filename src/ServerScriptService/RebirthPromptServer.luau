--[[
	RebirthPromptServer  --  ServerScriptService.RebirthPromptServer

	The server half of the first-rebirth nudge. It draws nothing and it does not
	decide WHEN the card is due -- RebirthUnlockPrompt (client) already has the
	same truth MenuHud's rebirth panel does, off ProgressionSync's `canRebirth`
	and `rebirths` -- this module only remembers that the card has been shown,
	so it never shows twice.

	WHY THE STAMP IS CLIENT-TRIGGERED RATHER THAN DERIVED FROM STATE. The
	obvious version watches TideEarned and stamps the attribute the instant the
	gate crosses -- but that fires the moment the condition becomes true, not
	when the player has actually SEEN anything. An existing account that was
	already past the threshold before this feature shipped would restore
	straight into "seen", and the card that exists for exactly that player would
	never fire. Waiting for the client's own dismiss (either button, or the X)
	ties the flag to the thing it is meant to record.

	Persisted through SaveService's `rebirthPromptSeen` field, the same
	held-once-set shape TutorialConfig.DoneAttribute uses -- see that module's
	header for why a one-time flag has to be held rather than re-derived.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Net = require(Modules:WaitForChild("Net"))
local RebirthPromptConfig = require(Modules:WaitForChild("RebirthPromptConfig"))

local RebirthPromptServer = {}

local started = false

function RebirthPromptServer.start()
	assert(RunService:IsServer(), "[RebirthPromptServer] server-only")
	if started then
		return
	end
	started = true

	-- No payload: the client is reporting "I dismissed the card", not asking
	-- for anything, so there is nothing on this message worth tampering with.
	Net.get("RebirthPromptSeen").OnServerEvent:Connect(function(player)
		player:SetAttribute(RebirthPromptConfig.SeenAttribute, true)
	end)
end

return RebirthPromptServer
