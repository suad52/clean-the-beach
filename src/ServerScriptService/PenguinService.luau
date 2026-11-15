--[[
	PenguinService  --  ServerScriptService.PenguinService  (ModuleScript)

	PET A PENGUIN, GET A COIN. The whole feature, server side: every Model
	tagged "Penguin" (PenguinBuilder stamps the tag) gets a ProximityPrompt on
	its PromptAnchor, and a completed hold pays ONE coin through the one grant
	path the game has -- SellServer.addCoins -- which is what counts it toward
	the tide, pushes the HUD and dirties the save. Nothing here touches the
	Coins attribute directly and nothing here invents a second currency.

	IT IS THE CAMEL'S PROMPT WITH A SERVER BEHIND IT. Island2Builder's camel
	carries an identical "Pet" prompt that pays nothing (Island2_Client plays a
	grunt and nods it); this is the same shape plus the handler. The numbers --
	HoldDuration 0.4, reach 12, line-of-sight off -- are the camel's.

	TWO COOLDOWNS, AND BOTH ARE THE POINT OF THE FEATURE RATHER THAN A GUARD
	AGAINST IT. A coin a press with no cooldown is a held E key printing money
	and a ProgressionSync push fifteen times a second; the engine's own prompt
	rate limit is not a per-player one (SandbotService says so in as many
	words). So: one pet every PET_COOLDOWN seconds per player, and the SAME bird
	not again for SAME_BIRD_COOLDOWN -- a colony of sixty is sixty coins if you
	walk the whole strand, which is a reason to walk the whole strand.

	BOUND BY TAG, NOT BY A BOOT SWEEP. Penguin Island is built by CTB_Server
	after ServerMain has finished, and rebuilt from source on every boot, so a
	one-shot GetTagged here finds nothing; GetInstanceAddedSignal is what
	actually binds the colony, and AncestryChanged drops a bird the rebuild
	threw away.
]]

local PenguinService = {}

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local Net = require(Modules:WaitForChild("Net"))
local SellServer = require(script.Parent:WaitForChild("SellServer"))

PenguinService.TAG = (type(GameConfig.Tags) == "table" and GameConfig.Tags.Penguin) or "Penguin"

local PET_COINS = 1
local PET_COOLDOWN = 1.5        -- seconds between any two pets, per player
local SAME_BIRD_COOLDOWN = 8    -- seconds before the same bird pays the same player again
local PROMPT_NAME = "PenguinPrompt"

local lastPet: { [Player]: number } = {}
local lastBird: { [Player]: { [Model]: number } } = {}
local penguins: { [Model]: { model: Model, anchor: BasePart, prompt: ProximityPrompt } } = {}
local connections = {}
local started = false
local bound = 0

local function pet(player: Player, bird)
	if not (player and player.Parent and bird and bird.anchor and bird.anchor.Parent) then
		return
	end
	local now = os.clock()
	if now - (lastPet[player] or -math.huge) < PET_COOLDOWN then
		return
	end
	local mine = lastBird[player]
	if not mine then
		mine = {}
		lastBird[player] = mine
	end
	if now - (mine[bird.model] or -math.huge) < SAME_BIRD_COOLDOWN then
		-- Already paid for this one. The bird still nods on the client (it
		-- reacts to the prompt, not to the coin), which is the right feel: it
		-- likes you, it has just already told you so.
		return
	end
	mine[bird.model] = now
	lastPet[player] = now

	SellServer.addCoins(player, PET_COINS, "penguin")

	-- Feedback to the petter only. FeedbackClient drops an Fx whose part is not
	-- streamed in, and a bird on another island is not; the petter is within
	-- twelve studs by construction.
	Net.get("Fx"):FireClient(player, {
		kind = "Pet",
		part = bird.anchor,
		amount = PET_COINS,
	})
end

local function bindPenguin(model: Instance)
	if not (model:IsA("Model") and model:IsDescendantOf(workspace)) or penguins[model] then
		return
	end
	local anchor = model:FindFirstChild("PromptAnchor") or model:FindFirstChild("Body")
		or model:FindFirstChildWhichIsA("BasePart", true)
	if not (anchor and anchor:IsA("BasePart")) then
		warn("[PenguinService] " .. model:GetFullName() .. " has no part to hang a prompt on")
		return
	end
	if anchor:FindFirstChildWhichIsA("ProximityPrompt") then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = PROMPT_NAME
	prompt.ActionText = "Pet"
	prompt.ObjectText = "Penguin"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0.4
	-- Reach is the bird's own plus however far it roams: the client walks the
	-- model (and this prompt with it) round its resting spot, while the server
	-- measures from where the bird was stood.
	prompt.MaxActivationDistance = (tonumber(model:GetAttribute("PromptReach")) or 12)
		+ (tonumber(model:GetAttribute("Roam")) or 0)
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor

	local rec = { model = model, anchor = anchor, prompt = prompt }
	penguins[model] = rec
	bound += 1
	connections[#connections + 1] = prompt.Triggered:Connect(function(player: Player)
		pet(player, rec)
	end)
	-- The island is destroyed and remade on every boot; a bird that went with
	-- it must not be held here for ever.
	connections[#connections + 1] = model.AncestryChanged:Connect(function(_, parent)
		if not parent then
			penguins[model] = nil
		end
	end)
end

function PenguinService.start()
	assert(RunService:IsServer(), "[PenguinService] server-only")
	if started then
		return
	end
	started = true

	connections[#connections + 1] = Players.PlayerRemoving:Connect(function(player)
		lastPet[player] = nil
		lastBird[player] = nil
	end)

	for _, m in ipairs(CollectionService:GetTagged(PenguinService.TAG)) do
		bindPenguin(m)
	end
	connections[#connections + 1] =
		CollectionService:GetInstanceAddedSignal(PenguinService.TAG):Connect(bindPenguin)

	print(string.format("[PenguinService] online -- %d penguin(s) bound so far, +%d coin a pet, "
		.. "%.1fs between pets", bound, PET_COINS, PET_COOLDOWN))
end

-- For the boot log and tests: how many birds are wired right now.
function PenguinService.count(): number
	local n = 0
	for _ in pairs(penguins) do
		n += 1
	end
	return n
end

return PenguinService
