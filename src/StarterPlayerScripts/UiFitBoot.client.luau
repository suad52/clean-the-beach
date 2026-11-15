--[[
	UiFitBoot  --  StarterPlayerScripts.UiFitBoot  (LocalScript)

	Starts the one thing that makes the HUDs fit a phone. See Modules.UiFit for
	what it actually does and why it wraps rather than scaling in place.

	Its own script rather than a line in ClientMain, because the HUDs it covers
	belong to several unrelated systems -- Clean the Beach's own HUD, the
	sift/sell add-on, the weight system, the vault and the ATV panel -- and none
	of them owns the others. Hanging it off any one boot file would make that
	system's load order quietly responsible for whether everyone else fits on
	screen.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UiFit = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("UiFit"))

UiFit.start()

print(string.format("[UiFit] %.2f scale for a %s viewport%s",
	UiFit.get(), tostring(workspace.CurrentCamera.ViewportSize),
	UiFit.compact() and " (compact)" or ""))
