--[[
	WeightNet  --  ReplicatedStorage.WeightSystem.WeightNet

	Single owner of the two RemoteEvents this system uses. The server creates
	them on require; the client waits for them. Nothing else in the system
	calls Instance.new("RemoteEvent").

	This deliberately does NOT extend ReplicatedStorage.Modules.Net. That
	module owns a fixed list of the base game's remotes, and adding to it would
	mean editing a base file. A second, self-contained folder costs nothing and
	keeps the two systems separable.

	DIRECTION CONTRACT -- read before adding a remote:

		C -> S   CollectRequest   { the instance the player wants }  and NOTHING else
		S -> C   CollectResult    { ok, reason, item, weight, load, max, label }

	The client never sends a weight, never sends a capacity, and never sends a
	result. It nominates an instance; the server decides everything about it.
	Current and max load reach the client as PLAYER ATTRIBUTES (same pattern
	CTB_HUD already uses for Bag / Coins), so there is no sync remote at all.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "Remotes"
local EVENT_NAMES = {
	"CollectRequest", -- client -> server
	"CollectResult",  -- server -> client
}

local WeightNet = {}

local root = script.Parent
local folder: Instance?

if RunService:IsServer() then
	folder = root:FindFirstChild(FOLDER_NAME)
	if not folder then
		local created = Instance.new("Folder")
		created.Name = FOLDER_NAME
		created.Parent = root
		folder = created
	end
	for _, name in EVENT_NAMES do
		if not folder:FindFirstChild(name) then
			local event = Instance.new("RemoteEvent")
			event.Name = name
			event.Parent = folder
		end
	end
else
	folder = root:WaitForChild(FOLDER_NAME, 30)
	assert(folder, "[WeightNet] the server never created " .. FOLDER_NAME
		.. " -- is ServerScriptService.WeightSystem.WeightSystemBoot present and enabled?")
end

local cache: { [string]: RemoteEvent } = {}

function WeightNet.get(name: string): RemoteEvent
	local hit = cache[name]
	if hit then
		return hit
	end
	assert(table.find(EVENT_NAMES, name), "[WeightNet] unknown remote: " .. tostring(name))

	local found = folder:FindFirstChild(name)
	if not found and RunService:IsClient() then
		found = folder:WaitForChild(name, 15)
	end
	assert(found and found:IsA("RemoteEvent"), "[WeightNet] remote not found: " .. name)

	cache[name] = found
	return found
end

return WeightNet
