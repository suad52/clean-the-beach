--[[
	WeightSystemBoot  --  ServerScriptService.WeightSystem.WeightSystemBoot  (Script)

	Starts the weight-based collection + dynamic storage system. This is the
	ONLY new Script on the server; everything else it owns is a module.

	It touches nothing that already exists:
		* it does not require, start or re-order ServerMain, CTB_Server,
		  SiftingServer, SellServer or CTBBridge
		* it does not call InventoryController.Server.start() -- ServerMain
		  already owns that, and calling it twice is a no-op anyway
		* it adds no instance to the world except an empty Workspace.Trash
		  (WeightConfig.CreateTrashFolder) and a ServerStorage parking folder

	ORDER MATTERS, for the same reason it does in ServerMain:
		1. WeightService -- the ledger has to exist before anything can bank
		   into it, and it has to be listening to Players.PlayerAdded before
		   the first player arrives.
		2. TrashCollectionService -- requires WeightNet, which is what creates
		   the RemoteEvents the client is waiting on.
]]

local RunService = game:GetService("RunService")

assert(RunService:IsServer(), "[WeightSystem] WeightSystemBoot must be a Script on the server")

local WeightService = require(script.Parent:WaitForChild("WeightService"))
local TrashCollectionService = require(script.Parent:WaitForChild("TrashCollectionService"))

WeightService.start()
TrashCollectionService.start()

print(string.format("[WeightSystem] online -- %d collectible%s registered",
	TrashCollectionService.count(),
	TrashCollectionService.count() == 1 and "" or "s"))
