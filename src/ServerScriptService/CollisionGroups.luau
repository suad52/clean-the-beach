--[[
	CollisionGroups  --  ServerScriptService.CollisionGroups

	WHO IS ALLOWED TO BUMP INTO WHOM. Three rules, and all three are OFF:

		player  x player   -- no shoving at the sell counter, no bodyblocking a
	                      prompt, no queue of characters piling up on the ferry
		vehicle x vehicle  -- two machines spawned on neighbouring pads pass
	                      through each other instead of launching
		player  x vehicle  -- you cannot be run over, and a parked truck is not
	                      a wall between you and the sand behind it

	EVERYTHING ELSE IS UNTOUCHED. Both groups still collide with Default, which
	is terrain, the buildings, the ferry decks, the arena walls and every prop on
	the beach -- so machines still drive on sand and players still stand on
	floors. This file only ever writes the two groups it registers.

	⚠️ WHY THIS DOES NOT BREAK GETTING INTO A MACHINE. Collision groups switch
	Touched off along with the physical contact, so a seat you board by walking
	into it would stop working. AtvServer does not: its EnterPrompt is a
	ProximityPrompt that calls seat:Sit(humanoid) directly, and the one Touched
	connection in the whole game (AfkService's entry pad) is Default-group
	scenery a player still collides with. Both were checked before this landed.
	If a future feature seats somebody by contact, it has to use a prompt too.

	The showroom stock on the car pad is DELIBERATELY not in the vehicle group.
	Those are anchored, inert display models -- scenery shaped like a truck --
	and AtvServer's makeInert has always made them solid on purpose, because a
	machine you can walk through reads as a hologram.

	PUBLIC API
		CollisionGroups.start()             -- ServerMain, before anything spawns
		CollisionGroups.apply(root, group)  -- paint a model and everything it
	                                       grows later
]]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

local CollisionGroups = {}

CollisionGroups.Player = "Players"
CollisionGroups.Vehicle = "Vehicles"

local started = false

local function ensureGroup(name: string)
	if PhysicsService:IsCollisionGroupRegistered(name) then
		return
	end
	local ok, err = pcall(function()
		PhysicsService:RegisterCollisionGroup(name)
	end)
	if not ok then
		warn("[CollisionGroups] could not register " .. name .. ": " .. tostring(err))
	end
end

--[[
	Paint a whole model, AND KEEP PAINTING IT.

	The second half is the half that matters. A machine is not finished when it
	is parented: AtvBuilder.fitRake destroys and rebuilds the towed bar every
	time a rung is bought, and the tine count is a function of the width -- so a
	one-shot sweep at spawn would leave a maxed rake in the Default group and
	give the player a forty-tine wall that still shoves people around.

	The connection is not tracked because it does not need to be: Destroy()
	severs every connection on the instance, and both callers (a despawned
	machine, a respawned character) destroy their root.
]]
function CollisionGroups.apply(root: Instance, group: string): RBXScriptConnection?
	if not root then
		return nil
	end
	group = group or CollisionGroups.Vehicle

	if root:IsA("BasePart") then
		root.CollisionGroup = group
	end
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = group
		end
	end

	return root.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			d.CollisionGroup = group
		end
	end)
end

--[[
	A CHARACTER IS ALSO NOT FINISHED WHEN IT ARRIVES. Accessories stream in over
	the first few frames and a Tool's Handle is parented in every time one is
	equipped, so the same live connection covers both -- otherwise a player
	wearing a big hat would still be able to headbutt somebody.
]]
local function bindCharacter(char: Model)
	CollisionGroups.apply(char, CollisionGroups.Player)
end

local function bindPlayer(player: Player)
	player.CharacterAdded:Connect(bindCharacter)
	if player.Character then
		bindCharacter(player.Character)
	end
end

function CollisionGroups.start()
	if started then
		return
	end
	started = true

	ensureGroup(CollisionGroups.Player)
	ensureGroup(CollisionGroups.Vehicle)

	PhysicsService:CollisionGroupSetCollidable(
		CollisionGroups.Player, CollisionGroups.Player, false)
	PhysicsService:CollisionGroupSetCollidable(
		CollisionGroups.Vehicle, CollisionGroups.Vehicle, false)
	PhysicsService:CollisionGroupSetCollidable(
		CollisionGroups.Player, CollisionGroups.Vehicle, false)

	Players.PlayerAdded:Connect(bindPlayer)
	-- Anyone already in: this module is started first in ServerMain, but a
	-- Studio session that reloads the script mid-run would otherwise leave the
	-- one player in the game solid.
	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end
end

return CollisionGroups
