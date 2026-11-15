--[[
	RebirthPromptConfig  --  ReplicatedStorage.Modules.RebirthPromptConfig

	The one fact RebirthUnlockPrompt (client) and RebirthPromptServer (server)
	have to agree on: the name of the attribute that remembers whether the
	first-rebirth nudge has already been shown to this account.

	SET ONCE, ON THE SERVER, AND PERSISTED -- SaveService carries this field
	(see its `rebirthPromptSeen` note) the same way it carries TutorialDone, so
	the card is a once-per-ACCOUNT event rather than a once-per-session one.
	RebirthPromptServer stamps it the moment the client reports the card was
	dismissed; a client cannot stamp its own attribute and have that reach the
	server, which is why the remote exists at all.
]]

local RebirthPromptConfig = {}

RebirthPromptConfig.SeenAttribute = "RebirthPromptSeen"

return RebirthPromptConfig
