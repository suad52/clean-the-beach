--[[
	VehicleHold  --  ServerScriptService.VehicleHold

	Every machine in the car spawner carries its OWN cargo box, and this owns
	them. It is a second storage, not a bigger bag:

		drive          litter lands in the SCOOP, and the scoop tips into THE
		               MACHINE's hold each time it fills
		park + unload  you move it from the machine into the bag on your back,
		               a bagful at a time
		sell           you walk that bag to the scales, as you always did

	So a run is: fill a 450 lb hopper, then make four trips to the pad with a
	100 lb bag. The hold is what improves up the ladder; the bag is still the
	Bucket Size track and is untouched by any of this.

	WHY A MODULE AND NOT PART OF AtvServer
	--------------------------------------
	TrashCollectionService has to ask "is this player filling a machine right
	now?" on every single pickup, and it lives in the WeightSystem folder,
	which knows nothing about vehicles and should stay that way. A small module
	both sides can require keeps that seam one function wide, and keeps
	AtvServer's ride records private to AtvServer.

	WHO OWNS A HOLD
	---------------
	Keyed by the player who bought and spawned the machine. Somebody else
	hopping into your truck gets a ride, not your cargo box -- the same rule
	NetRadius has always had, for the same reason.

	PUBLIC API
		VehicleHold.open(player, entry)   -- AtvServer, on spawn
		VehicleHold.close(player)         -- AtvServer, on despawn
		VehicleHold.riding(player)        -- the hold they are SEATED in, or nil
		VehicleHold.parked(player)        -- their machine's hold, seated or not
		VehicleHold.canStow(hold, weight)
		VehicleHold.stow(hold, itemId, weight, label) -> boolean
		VehicleHold.unload(player)        -> moved, weight, remaining, reason
		VehicleHold.isEmpty(player)       -- despawn guard
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local WeightConfig = require(ReplicatedStorage:WaitForChild("WeightSystem"):WaitForChild("WeightConfig"))

local VehicleHold = {}

local holds: { [Player]: any } = {}

-- The bag this unloads INTO. Resolved lazily and optionally, the same way
-- ProgressionServer reaches it, so this module still loads in a place where the
-- weight system is not installed.
local weightLoaded = false
local WeightService = nil
local function weight()
	if weightLoaded then
		return WeightService
	end
	weightLoaded = true
	local folder = ServerScriptService:FindFirstChild("WeightSystem")
	local service = folder and folder:FindFirstChild("WeightService")
	if service and service:IsA("ModuleScript") then
		local ok, result = pcall(require, service)
		if ok and type(result) == "table" and type(result.collect) == "function" then
			WeightService = result
		elseif not ok then
			warn("[VehicleHold] weight system present but would not load:", result)
		end
	end
	return WeightService
end

----------------------------------------------------------------
-- WHAT THE PLAYER AND THE WORLD SEE
----------------------------------------------------------------
--[[
	Two player attributes, and they describe THE MACHINE BEING RIDDEN -- both
	are zero on foot. That is not an oversight, it is the switch: WeightConfig's
	freeFor() reads exactly this pair to decide which container a pickup should
	be measured against, so "riding" and "has a hold with room" are the same
	question asked once.

	A PARKED machine's contents go on its own prompt instead, which is where the
	player is looking at the moment they need that number.
]]
local function publish(player: Player, hold)
	if not player.Parent then
		return
	end
	local seated = hold and hold.seat and hold.seat.Parent and hold.seat.Occupant ~= nil
		and Players:GetPlayerFromCharacter(hold.seat.Occupant.Parent) == player
	player:SetAttribute(WeightConfig.HoldLoadAttribute, seated and WeightConfig.round(hold.load) or 0)
	player:SetAttribute(WeightConfig.HoldMaxAttribute, seated and hold.capacity or 0)

	if hold and hold.prompt and hold.prompt.Parent then
		hold.prompt.ObjectText = string.format("%s \u{2014} %s / %s %s",
			hold.name, WeightConfig.format(hold.load), WeightConfig.format(hold.capacity),
			WeightConfig.Unit)
		--[[
			OFFERED ONLY WHEN IT CAN BE TAKEN: something in the hold, AND the
			player out of the seat.

			The seated half is the one that mattered. A ProximityPrompt on the
			machine you are sitting in is inside its own activation distance at
			all times, so "Unload" sat on the screen for the entire drive -- and
			unloading is not even something you do from the cab, it is what you
			get out to do.
		]]
		hold.prompt.Enabled = hold.load > WeightConfig.EPSILON and not seated
	end
end
VehicleHold.publish = publish

--[[
	THE LOAD, MADE VISIBLE.

	Each builder hands over a stack of "fill" parts, bottom of the box first,
	and this reveals them as the hold fills. Written only when the COUNT
	changes, not every time a can goes in: Transparency replicates, and a
	truck being driven through litter collects several times a second.
]]
local function reveal(parts, frac: number, shown: number): number
	if not parts or #parts == 0 then
		return shown
	end
	frac = math.clamp(frac, 0, 1)
	-- Ceil, so the very first item put in shows something. A box that stayed
	-- visibly empty until it was an eighth full would read as broken.
	local want = (frac > 0) and math.max(1, math.ceil(frac * #parts)) or 0
	if want == shown then
		return shown
	end
	for i, part in parts do
		part.Transparency = (i <= want) and (part:GetAttribute("FillTransparency") or 0) or 1
	end
	return want
end

--[[
	TWO CONTAINERS, ONE LOAD.

	The cargo box shows everything that has been TIPPED INTO it, and the scoop
	out front shows what is still riding in the net -- so the bed's share is
	deliberately (load - scoopLoad) rather than load. That subtraction is the
	whole effect: when the scoop tips, the same weight leaves one container and
	arrives in the other in a single frame, and the pile in the back visibly
	jumps by a scoopful.
]]
local function refit(hold)
	--[[
		THE EPSILON IS NOT DECORATION. reveal() ceils, so ANY fraction above zero
		lights a lump -- and `load` is rounded on the way in while `scoopLoad`
		was not, so an untipped scoop left a crumb of a pound behind in this
		subtraction and the cargo box lit its first lump with nothing whatever in
		it. scoopLoad is rounded to match now; this is the belt to that brace.
	]]
	local inBox = hold.load - hold.scoopLoad
	hold.shown = reveal(hold.fill,
		(hold.capacity > 0 and inBox > WeightConfig.EPSILON) and (inBox / hold.capacity) or 0,
		hold.shown)
	hold.scoopShown = reveal(hold.scoop,
		(hold.scoopMax > 0) and (hold.scoopLoad / hold.scoopMax) or 0,
		hold.scoopShown)
end

----------------------------------------------------------------
-- LIFECYCLE
----------------------------------------------------------------
function VehicleHold.open(player: Player, entry)
	VehicleHold.close(player)
	local capacity = math.max(0, entry.capacity or 0)
	local hold = {
		model = entry.model,
		seat = entry.seat,
		prompt = entry.prompt,
		fill = entry.fill,
		name = entry.name or "Hold",
		capacity = capacity,
		load = 0,
		items = {},
		shown = -1,

		-- The scoop. See stow() for the cycle; `scoopMax` is how much it holds
		-- before it tips, and it is a SCOOPFUL rather than a share of the hold:
		-- the 650 lb truck would otherwise carry forty pounds of loose rubbish
		-- in its net and only tip it twice a run. Twelve pounds is five or six
		-- pickups, which is a rhythm you can see.
		scoop = entry.scoop,
		scoopMax = math.max(1, entry.scoopCapacity or 12),
		scoopLoad = 0,
		scoopShown = -1,
	}
	holds[player] = hold
	refit(hold)
	publish(player, hold)
	return hold
end

--[[
	RESIZE A HOLD THAT IS ALREADY OPEN.

	The hold's capacity is the better of the machine's own bed and the player's
	Bucket Size (see AtvConfig.effectiveStats), and Bucket Size can be bought
	WHILE THE MACHINE IS RUNNING. Without this the new capacity would not arrive
	until the truck was put away and spawned again -- and since a loaded machine
	is never auto-despawned, "buy the upgrade, nothing happens" would be the
	normal case rather than the edge one.

	Never shrinks below what is already aboard. A rebirth resets Bucket Size to
	level 1, and a hold that shrank under its own load would put the machine into
	a state canStow() cannot reason about -- and would strand cargo the player
	cannot unload. It clamps to the current load instead and the overflow drains
	normally as they unload.
]]
function VehicleHold.setCapacity(player: Player, capacity: number): boolean
	local hold = holds[player]
	if not hold or type(capacity) ~= "number" or capacity ~= capacity then
		return false
	end
	local next = math.max(0, capacity, hold.load)
	if math.abs(next - hold.capacity) <= WeightConfig.EPSILON then
		return false
	end
	hold.capacity = next
	-- The fill parts are drawn as a FRACTION of capacity, so a resize has to
	-- redraw them or a half-full bed keeps the pile height of the old one.
	refit(hold)
	publish(player, hold)
	return true
end

function VehicleHold.close(player: Player)
	local hold = holds[player]
	if not hold then
		return
	end
	holds[player] = nil
	if player.Parent then
		player:SetAttribute(WeightConfig.HoldLoadAttribute, 0)
		player:SetAttribute(WeightConfig.HoldMaxAttribute, 0)
	end
end

-- Their machine, whether or not they are sitting in it. This is the one the
-- unload prompt uses -- you have to be able to empty a truck you are standing
-- next to.
function VehicleHold.parked(player: Player)
	local hold = holds[player]
	if hold and hold.model and hold.model.Parent then
		return hold
	end
	return nil
end

-- The machine they are DRIVING. Only this one fills, so that walking past your
-- own parked truck does not post litter into it from ten studs away.
function VehicleHold.riding(player: Player)
	local hold = VehicleHold.parked(player)
	if not hold or not (hold.seat and hold.seat.Parent) then
		return nil
	end
	local occupant = hold.seat.Occupant
	if not occupant then
		return nil
	end
	if Players:GetPlayerFromCharacter(occupant.Parent) ~= player then
		return nil
	end
	return hold
end

function VehicleHold.isEmpty(player: Player): boolean
	local hold = holds[player]
	return not hold or hold.load <= WeightConfig.EPSILON
end

----------------------------------------------------------------
-- IN
----------------------------------------------------------------
function VehicleHold.canStow(hold, w: number): boolean
	if not hold or type(w) ~= "number" or w ~= w then
		return false
	end
	return hold.load + w <= hold.capacity + WeightConfig.EPSILON
end

--[[
	IT LANDS IN THE SCOOP, AND THE SCOOP TIPS WHEN IT IS FULL.

	`load` is still the whole machine and nothing outside this module needs to
	know the scoop exists -- the HUD, the prompt, the capacity check and the
	unload all read the same single number they always did. `scoopLoad` is only
	a note of how much of that total has not reached the box yet, and refit()
	draws the two containers from the pair.

	So the visible cycle is: five or six pieces of litter pile up in the net,
	then the net empties and the bed jumps. The tip is instant on purpose. A
	scoop that drained smoothly is a second progress bar; a scoop that goes from
	full to empty in one frame is a machine dumping its shovel.
]]
function VehicleHold.stow(hold, itemId: string?, w: number, label: string?): boolean
	if not VehicleHold.canStow(hold, w) then
		return false
	end
	table.insert(hold.items, { itemId = itemId, weight = w, label = label })
	hold.load = WeightConfig.round(hold.load + w)
	hold.scoopLoad = WeightConfig.round(hold.scoopLoad + w)
	if hold.scoopLoad >= hold.scoopMax then
		hold.scoopLoad = 0
	end
	refit(hold)
	for owner, h in holds do
		if h == hold then
			publish(owner, hold)
			break
		end
	end
	return true
end

----------------------------------------------------------------
-- OUT
----------------------------------------------------------------
--[[
	Hold -> bag, taking as much as will fit and stopping cleanly when it will
	not. Returns (moved, weight, remaining, reason).

	ITEMS GO IN THROUGH WeightService.collect, which is the same door a pickup
	off the sand uses -- so the inventory, the ledger and every panel reading
	them all see an ordinary arrival. Nothing here needs to know how an item is
	priced, whether it is crusted, or what the sell pad will do with it.

	Newest out first (a stack, not a queue). It makes no gameplay difference --
	nothing in the hold is ordered by anything a player can see -- and popping
	the end of the array avoids reshuffling a 450 lb hopper on every item.
]]
function VehicleHold.unload(player: Player)
	local hold = VehicleHold.parked(player)
	if not hold then
		return 0, 0, 0, "NoVehicle"
	end
	if hold.load <= WeightConfig.EPSILON then
		return 0, 0, 0, "HoldEmpty"
	end
	local service = weight()
	if not service then
		return 0, 0, #hold.items, "NoBag"
	end

	local moved, movedWeight = 0, 0
	while #hold.items > 0 do
		local item = hold.items[#hold.items]
		local fits = service.canCarry(player, item.weight)
		if not fits then
			break
		end
		local record = service.collect(player, item.weight, {
			itemId = item.itemId,
			label = item.label,
		})
		if not record then
			break
		end
		table.remove(hold.items)
		hold.load = WeightConfig.round(math.max(0, hold.load - item.weight))
		moved += 1
		movedWeight = WeightConfig.round(movedWeight + item.weight)
	end

	-- Newest out first, and the newest is exactly what is sitting in the scoop,
	-- so the net empties before the box does. Clamped to the load as well, or a
	-- machine emptied to nothing could be left drawing rubbish in a net that
	-- provably has none in it.
	hold.scoopLoad = WeightConfig.round(math.clamp(hold.scoopLoad - movedWeight, 0, hold.load))
	refit(hold)
	publish(player, hold)
	return moved, movedWeight, #hold.items, (moved > 0) and "Ok" or "BagFull"
end

function VehicleHold.snapshot(player: Player)
	local hold = holds[player]
	if not hold then
		return nil
	end
	return {
		load = hold.load,
		capacity = hold.capacity,
		count = #hold.items,
		name = hold.name,
	}
end

Players.PlayerRemoving:Connect(function(player)
	holds[player] = nil
end)

return VehicleHold
