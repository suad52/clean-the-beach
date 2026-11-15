--[[
	VipService  --  ServerScriptService.VipService

	Everything game pass 1953715528 hands over:

	  THE TAG      a billboard over the head, built on the SERVER and parented
	               into the character, so every player in the server sees it.
	               A client-side tag would only ever be visible to its owner,
	               which is the one person who does not need convincing.
	  THE RAKE     SkinConfig's `vip` skin, granted and worn.
	  THE PET      the Gilded Unicorn, ONCE per account.

	TWO KINDS OF THING, AND THEY ARE NOT HANDLED THE SAME WAY.

	The tag and the skin are STATES. They are re-derived from the pass on every
	join and on every respawn, they cost nothing to redo, and redoing them is
	how a player who buys VIP mid-session gets them without rejoining.

	The pet is a GRANT. It moves something into an inventory that is saved, so
	it is guarded by a saved flag and the same three rules StarterPackService's
	header sets out -- nothing before the profile has loaded, the flag before the
	goods, and a forced write immediately after. A pass is permanent; a grant
	hung off ownership alone pays out on every join for ever.

	THE PET CAN BE REFUSED, and the only real reason is a collection already at
	PetConfig.MaxOwned. Nothing is claimed when that happens, so the unicorn is
	still waiting on the next join -- and givePet names the pass when it asks, so
	the player reads "Your VIP pet is waiting -- your pet bag is full" rather than
	a bare line about their bag. The tag and the rake are unaffected: they are
	states, they landed before this, and they stay.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local PassConfig = require(Modules:WaitForChild("PassConfig"))
local PetConfig = require(Modules:WaitForChild("PetConfig"))
local SkinConfig = require(Modules:WaitForChild("SkinConfig"))
local Net = require(Modules:WaitForChild("Net"))

local GamePassService = require(script.Parent:WaitForChild("GamePassService"))
local PetServer = require(script.Parent:WaitForChild("PetServer"))
local SaveService = require(script.Parent:WaitForChild("SaveService"))
local SkinService = require(script.Parent:WaitForChild("SkinService"))

local VipService = {}

local ENTRY = PassConfig.get(PassConfig.VipKey)
local CLAIMED = PassConfig.VipClaimedAttribute

-- Generous, and the same number StarterPackService waits: a DataStore read is
-- normally well under a second, and the cost of waiting too long is that a
-- paying player gets their pet a moment late.
local LOAD_TIMEOUT = 45
local LOAD_POLL = 0.25

local granting: { [Player]: boolean } = {}
local watching: { [Player]: { RBXScriptConnection } } = {}
local connections = {}
local started = false

local function owns(player: Player): boolean
	return ENTRY ~= nil and GamePassService.ownsPassId(player, ENTRY.id)
end

----------------------------------------------------------------
-- THE TAG
----------------------------------------------------------------
--[[
	ON THE SERVER, IN THE CHARACTER. Two things follow from that and both are
	load-bearing:

	  it replicates, so everyone sees it. That is the product.
	  it dies with the character, so it has to be rebuilt on every spawn --
	    which is what the CharacterAdded hook below is for.

	MaxDistance is set so the tag fades out before the name label does. A tag
	legible from further away than the player's own name reads as a HUD element
	rather than as something they are wearing.
]]
local TAG_NAME = "VipTag"

-- The owner's own switch, written by the settings panel as Set_<key> and
-- validated/saved by SettingsServer. Read here and nowhere else: whether the
-- billboard goes up is a decision about ONE billboard, so it belongs beside the
-- code that builds it rather than in a config every module would then import.
local HIDE_ATTR = "Set_HideVipTag"

local function clearTag(char: Model?)
	local head = char and char:FindFirstChild("Head")
	local old = head and head:FindFirstChild(TAG_NAME)
	if old then
		old:Destroy()
	end
end

local function buildTag(char: Model)
	local head = char:FindFirstChild("Head")
	if not head then
		return
	end
	clearTag(char)

	--[[
		RED CARPET AND ACTUAL GOLD, and EVERY PIECE IS CONCENTRIC.

		The first version was gold-on-black and sat wrong on the vertical: the
		face was pinned at 0.46 and its shadow slab at 0.54 to fake a drop
		shadow, which meant the lit plate -- the thing the eye actually centres
		on -- was half a slab high in a box that was itself centred on the head.
		Everything here shares one anchor at 0.5, 0.5 and the shadow is a
		SEPARATE frame behind, offset in pixels. Offsetting the thing you can
		see to imply the thing you cannot is always the wrong way round.

		THE GOLD IS A RAMP, NOT A COLOUR. A single flat yellow is what made the
		first one read as plastic -- the same note SkinConfig's three golds and
		the shop badge's rim both make. Bright at the top, deep at the bottom,
		and the same ramp on the text so the letters read as cut from the metal
		rather than printed on it.
	]]
	local GOLD_HI, GOLD_LO = Color3.fromRGB(255, 236, 170), Color3.fromRGB(198, 140, 26)
	local RED_HI, RED_LO = Color3.fromRGB(178, 26, 42), Color3.fromRGB(112, 10, 24)

	local bb = Instance.new("BillboardGui")
	bb.Name = TAG_NAME
	bb.Size = UDim2.fromOffset(168, 52)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 2.7, 0)
	bb.AlwaysOnTop = false
	bb.LightInfluence = 0
	bb.MaxDistance = 90

	local function plate(parent, name, sizeOff, z, radius)
		local f = Instance.new("Frame")
		f.Name = name
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(0.5, 0.5)
		f.Size = UDim2.new(1, sizeOff, 1, sizeOff)
		f.BorderSizePixel = 0
		f.ZIndex = z
		f.Parent = parent
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(radius, 0)
		c.Parent = f
		return f
	end

	-- The shadow, behind and below. Its own frame, so nothing lit has to move.
	local shadow = plate(bb, "Shadow", -2, 1, 0.46)
	shadow.Position = UDim2.new(0.5, 0, 0.5, 3)
	shadow.BackgroundColor3 = Color3.fromRGB(24, 6, 10)
	shadow.BackgroundTransparency = 0.35

	-- THE OUTER LINING: the gold band. It is the whole frame; the red sits
	-- inside it, so the gold is what the silhouette is made of.
	local rim = plate(bb, "Rim", 0, 2, 0.46)
	rim.BackgroundColor3 = GOLD_HI
	local rimGrad = Instance.new("UIGradient")
	rimGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0.00, GOLD_HI),
		ColorSequenceKeypoint.new(0.45, Color3.fromRGB(238, 190, 74)),
		ColorSequenceKeypoint.new(1.00, GOLD_LO),
	})
	rimGrad.Rotation = 90
	rimGrad.Parent = rim
	-- A thin dark edge on the gold itself. Not black -- a deep bronze, so the
	-- band still reads as metal at the point it meets the sky.
	local rimEdge = Instance.new("UIStroke")
	rimEdge.Color = Color3.fromRGB(96, 60, 8)
	rimEdge.Thickness = 2
	rimEdge.Parent = rim

	local face = plate(bb, "Face", -9, 3, 0.44)
	face.BackgroundColor3 = RED_HI
	local faceGrad = Instance.new("UIGradient")
	faceGrad.Color = ColorSequence.new(RED_HI, RED_LO)
	faceGrad.Rotation = 90
	faceGrad.Parent = face

	-- The sheen across the top of the velvet. Low and wide, because a hard
	-- highlight on a red plate reads as plastic rather than as cloth.
	local sheen = Instance.new("Frame")
	sheen.AnchorPoint = Vector2.new(0.5, 0)
	sheen.Position = UDim2.new(0.5, 0, 0, 3)
	sheen.Size = UDim2.new(1, -12, 0.42, 0)
	sheen.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	sheen.BackgroundTransparency = 0.88
	sheen.BorderSizePixel = 0
	sheen.ZIndex = 4
	sheen.Parent = face
	local shc = Instance.new("UICorner")
	shc.CornerRadius = UDim.new(0.5, 0)
	shc.Parent = sheen

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.new(1, -14, 1, -12)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.LuckiestGuy
	label.Text = PassConfig.VipTagText
	label.TextColor3 = Color3.new(1, 1, 1)      -- the gradient below is the colour
	label.TextScaled = true
	label.ZIndex = 5
	label.Parent = face
	-- Gold letters, from the same ramp as the rim. A UIGradient on a TextLabel
	-- tints the glyphs, which is the only way to get metal INTO type here.
	local textGrad = Instance.new("UIGradient")
	textGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 244, 198)),
		ColorSequenceKeypoint.new(0.52, Color3.fromRGB(255, 206, 84)),
		ColorSequenceKeypoint.new(1.00, Color3.fromRGB(214, 152, 28)),
	})
	textGrad.Rotation = 90
	textGrad.Parent = label
	-- Cut against the red with a dark maroon rather than black: black on this
	-- red is a hole, maroon is a shadow.
	local textEdge = Instance.new("UIStroke")
	textEdge.Color = Color3.fromRGB(70, 6, 16)
	textEdge.Thickness = 2.5
	textEdge.Parent = label
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = 30
	cap.Parent = label

	bb.Parent = head
end

local function refreshTag(player: Player)
	local char = player.Character
	if not char then
		return
	end
	--[[
		THE OWNER MAY SWITCH THEIR OWN TAG OFF, AND IT COMES OFF FOR EVERYBODY.

		Asked for by PineappleJUICEbox on 2026-09-24 -- "Have a toggle to turn vip
		tag off pls", 28 rebirths, so somebody who has worn it a while.

		NOT DRAWN THEN HIDDEN. The header above says why this billboard is built on
		the server and parented into the character: so every player in the server
		sees it. That cuts both ways -- a client-side hide would take it off the one
		screen it was not bothering anybody on, and leave it up for everyone else.
		The only honest way to switch it off is not to build it.

		THE PASS IS UNTOUCHED. The rake and the pet are a state and a grant of their
		own and this switch reaches neither; it is one boolean about one billboard.
		Turning it back on rebuilds the tag at once, through the listener in `watch`
		-- a toggle that waited for a respawn would read as broken.
	]]
	if owns(player) and player:GetAttribute(HIDE_ATTR) ~= true then
		buildTag(char)
	else
		clearTag(char)
	end
end

----------------------------------------------------------------
-- THE RAKE
----------------------------------------------------------------
--[[
	GRANTED AND THEN CHOSEN, and the second call is not redundant.

	SkinService.grant also chooses, but only the FIRST time -- it returns false
	for a skin already owned and changes nothing. So on every join after the one
	they bought it on, grant is a no-op and the player would be wearing whatever
	they last picked. `choose` is what makes it "always equipped".

	It is still only a default, not a lock: a VIP who walks up to the tomb's
	plinth and takes the Pharaoh's Sieve gets to keep wearing it for that
	session. Refusing that would be taking a thing away from the player who paid
	the most.
]]
local function applySkin(player: Player)
	if not owns(player) then
		return
	end
	local key = PassConfig.VipSkinKey
	if not SkinConfig.exists(key) then
		warn("[VIP] SkinConfig has no skin '" .. tostring(key) .. "' -- no rake granted.")
		return
	end
	SkinService.grant(player, key)
	SkinService.choose(player, key)
end

----------------------------------------------------------------
-- THE PET
----------------------------------------------------------------
local function alreadyClaimed(player: Player): boolean
	return player:GetAttribute(CLAIMED) == true
end

local function givePet(player: Player, reason: string): boolean
	if not ENTRY or not player.Parent then
		return false
	end
	if granting[player] or alreadyClaimed(player) then
		return false
	end
	if not owns(player) then
		return false
	end

	-- RULE 1: the claimed flag arrives with the profile, so until it has landed
	-- "not claimed" is indistinguishable from "not loaded yet".
	local waited = 0
	while not SaveService.isLoaded(player) do
		if waited >= LOAD_TIMEOUT or not player.Parent then
			warn(string.format("[VIP] %s owns VIP but their profile never loaded after "
				.. "%ds -- granting no pet. It will be waiting on their next join.",
				player.Name, LOAD_TIMEOUT))
			return false
		end
		task.wait(LOAD_POLL)
		waited += LOAD_POLL
	end

	if granting[player] or alreadyClaimed(player) then
		return false
	end
	granting[player] = true

	--[[
		THE THIRD ARGUMENT NAMES THE PURCHASE, and here it names the PET rather than
		the pass -- because unlike the Starter Pack, VIP is not all-or-nothing from
		the player's side. The tag and the rake have already landed by this point and
		are theirs; it is only the unicorn that is waiting. "VIP is waiting" would be
		an outright lie to somebody already wearing the tag.
	]]
	local ok, got = pcall(PetServer.grant, player, PassConfig.VipPetId, "Your VIP pet")
	if not ok then
		warn("[VIP] PetServer.grant threw:", got)
		granting[player] = nil
		return false
	end
	if not got then
		-- A full bag is the only real reason, and PetServer has now said so in terms
		-- of the pass. Nothing is claimed, so it is still waiting once they make room.
		granting[player] = nil
		return false
	end

	-- RULE 2: the flag before anything else can read this player as unclaimed.
	player:SetAttribute(CLAIMED, true)

	-- RULE 3: on disk now, not at the next autosave. A false is NOT rolled back
	-- -- the pet hook has already marked the profile dirty and the leave handler
	-- saves unconditionally, and undoing the claim here would turn a late write
	-- into a second Legendary.
	local okSave, wrote = pcall(SaveService.forceSave, player)
	if not (okSave and wrote) then
		warn(string.format("[VIP] granted the pet to %s but the forced save did not "
			.. "land -- the profile is dirty and will be written on leave. Not rolled "
			.. "back: a retry would hand over a second one.", player.Name))
	end
	granting[player] = nil

	local def = PetConfig.get(PassConfig.VipPetId)
	pcall(function()
		Net.get("Notify"):FireClient(player, {
			text = string.format("VIP \u{2014} %s is yours!",
				def and def.DisplayName or PassConfig.VipPetId),
			kind = "pickup",
		})
	end)
	print(string.format("[VIP] %s (%s): granted %s", player.Name, reason, PassConfig.VipPetId))
	return true
end

VipService.givePet = givePet

----------------------------------------------------------------
-- WIRING
----------------------------------------------------------------
local function apply(player: Player, reason: string)
	if not owns(player) then
		return
	end
	applySkin(player)
	refreshTag(player)
	task.spawn(givePet, player, reason)
end

local function watch(player: Player)
	local conns = {}

	-- The warm start: a server where this module is required after players are
	-- already in. On a cold join the attribute below is what does the work --
	-- GamePassService resolves the flat passes a moment after PlayerAdded, so
	-- this first pass usually finds an honest "no". Same shape, and the same
	-- reasoning, as StarterPackService's own spawn.
	task.spawn(apply, player, "join")

	if ENTRY then
		conns[#conns + 1] = player:GetAttributeChangedSignal(ENTRY.attribute)
			:Connect(function()
				if player:GetAttribute(ENTRY.attribute) == true then
					apply(player, "purchase")
				end
			end)
	end

	-- The settings panel writes the switch; the tag answers immediately rather
	-- than on the next respawn. Cheap: refreshTag is one ownership read and one
	-- billboard either way.
	conns[#conns + 1] = player:GetAttributeChangedSignal(HIDE_ATTR):Connect(function()
		refreshTag(player)
	end)

	-- The tag lives in the character, so it dies with it.
	conns[#conns + 1] = player.CharacterAdded:Connect(function(char)
		-- Head is not always there on the frame the character is
		char:WaitForChild("Head", 10)
		refreshTag(player)
	end)
	if player.Character then
		refreshTag(player)
	end

	watching[player] = conns
end

function VipService.start()
	assert(RunService:IsServer(), "[VIP] server-only")
	if started then
		return
	end
	started = true

	if not ENTRY then
		warn("[VIP] PassConfig has no '" .. tostring(PassConfig.VipKey)
			.. "' entry -- nothing will be granted.")
		return
	end
	if not PetConfig.get(PassConfig.VipPetId) then
		warn("[VIP] PetConfig has no pet '" .. tostring(PassConfig.VipPetId)
			.. "' -- the tag and rake still work, the pet does not.")
	end

	connections[#connections + 1] = Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	connections[#connections + 1] = Players.PlayerRemoving:Connect(function(player)
		granting[player] = nil
		for _, c in ipairs(watching[player] or {}) do
			c:Disconnect()
		end
		watching[player] = nil
	end)

	print(string.format("[VIP] online -- pass %d grants the %s tag, the '%s' rake and %s",
		ENTRY.id, PassConfig.VipTagText, PassConfig.VipSkinKey, PassConfig.VipPetId))
end

return VipService
