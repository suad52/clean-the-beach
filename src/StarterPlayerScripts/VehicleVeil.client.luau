--[[
	VehicleVeil  --  StarterPlayer.StarterPlayerScripts.VehicleVeil  (LocalScript)

	SOMEBODY ELSE'S MACHINE IS NOT DRAWN UNTIL IT HAS LEFT THE YARD.

	A car is delivered onto the pad -- the middle of a showroom that other people
	are standing in, pressing E, looking at the stock. Before this, a machine
	spawning was thirty studs of dump truck appearing from nothing on top of
	whoever happened to be standing there, and two players spawning at once was
	two of them posted through each other. So every client except the machine's
	owner draws it invisible until its owner has driven it clear of the pad.

	The OWNER always sees their own, from the first frame. That is the whole
	shape of the feature: the person who pressed the button gets a machine, and
	everyone else gets it once it is a machine driving down the beach rather than
	a machine materialising in a shop.

	WHO DECIDES
	-----------
	Not this script. AtvServer stamps every spawned machine with an owner and a
	Concealed flag before it is parented (so it is never on screen unstamped for
	a frame), and clears the flag from its own Heartbeat once the machine is far
	enough from the pad it came out of. All this does is watch the tag and paint.
	See AtvConfig's VehicleTag block.

	COLLISION IS ALREADY DEALT WITH, which is why hiding one is honest rather
	than a trap you can walk into: CollisionGroups puts every spawned machine in
	the Vehicles group, and Players x Vehicles is off. An invisible truck is not
	something anyone can bump into, be run over by, or be blocked behind.

	TWO KINDS OF HIDING, AND THE SECOND ONE IS THE FIDDLY ONE
	---------------------------------------------------------
	LocalTransparencyModifier is a display-only field. Nothing else in the game
	writes it, it replicates to nobody, and a machine destroyed under us leaves
	nothing behind -- so parts are one assignment each way.

	`Enabled` on a ProximityPrompt or a ParticleEmitter is not that, and neither
	is `Transparency` on a decal. Those are real replicated properties that the
	SERVER GOES ON WRITING while the machine is hidden: AtvServer turns the track
	dust on the moment a dozer passes 8 studs/s, and VehicleHold turns the Unload
	prompt on the moment there is anything in the box. Writing `false` over one of
	those does not stop that -- it only loses whatever the server says next,
	because our own value is what the property now holds and there is nothing left
	to compare against.

	So each of those is held DOWN rather than merely set: the override remembers
	what the property would say if we were not holding it, and the change signal
	-- which fires for the server's writes too -- keeps that up to date. Letting
	go puts the remembered value back, so a truck that drove out of the yard with
	its dust running is drawn running on the frame it appears.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AtvConfig = require(ReplicatedStorage:WaitForChild("AtvConfig"))

local player = Players.LocalPlayer

local TAG = AtvConfig.VehicleTag
local OWNER = AtvConfig.OwnerAttribute
local CONCEALED = AtvConfig.ConcealedAttribute

--[[
	RE-APPLIED ON A SLOW TICK, not once when the machine arrives.

	LocalTransparencyModifier is documented as being reset when a part's own
	Transparency is written, and VehicleHold writes Transparency on the cargo
	box's fill slabs every time the net picks something up. A machine can be
	loading while it is still in the yard -- the net is live from the first frame
	-- so a one-shot hide would let the load, and only the load, show through.

	A quarter of a second is under noticing, the work is a few dozen client-only
	property writes that replicate to nobody, and it only runs at all while there
	is something concealed -- which is a handful of seconds per spawn.
]]
local REPAINT = 0.25

-- [Model] = { holds = { [Instance] = record }, conns = { RBXScriptConnection } }
local veils = {}
-- [Model] = { RBXScriptConnection } -- the attribute watchers, which outlive the
-- veil itself: a machine that has been revealed still has to be watched, because
-- nothing says an owner cannot change (and a tag removed mid-flight must unbind).
local watched = {}
local veilCount = 0

----------------------------------------------------------------
-- WHAT IS HELD DOWN, AND AT WHAT VALUE
----------------------------------------------------------------
-- Everything here is a replicated property the server may write while we are
-- hiding the machine. Parts are NOT in this list -- see the header.
local function heldProperty(inst: Instance): (string?, any)
	if inst:IsA("Decal") or inst:IsA("Texture") then
		return "Transparency", 1
	end
	if inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam")
		or inst:IsA("Smoke") or inst:IsA("Fire") or inst:IsA("Sparkles") then
		return "Enabled", false
	end
	if inst:IsA("ProximityPrompt") or inst:IsA("Light") or inst:IsA("LayerCollector") then
		return "Enabled", false
	end
	return nil, nil
end

local function hide(veil, inst: Instance)
	if inst:IsA("BasePart") then
		inst.LocalTransparencyModifier = 1
		return
	end

	local prop, off = heldProperty(inst)
	if not prop or veil.holds[inst] then
		return
	end

	-- Typed loose on purpose: the property being written is a NAME chosen at
	-- runtime, so there is nothing for the checker to check and the alternative
	-- is the same three lines once per class.
	local held: any = inst
	local record = { prop = prop, off = off, want = held[prop] }
	-- The signal fires for OUR write below as well as the server's, and the
	-- second pass finds the value already `off` and stops. That is the recursion
	-- guard, and it is why the test is against `off` rather than a flag.
	record.conn = inst:GetPropertyChangedSignal(prop):Connect(function()
		local now = held[prop]
		if now ~= off then
			record.want = now
			held[prop] = off
		end
	end)
	held[prop] = off
	veil.holds[inst] = record
end

local function repaint(veil)
	for _, d in veil.model:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = 1
		end
	end
end

----------------------------------------------------------------
-- PUTTING IT BACK
----------------------------------------------------------------
local function attach(model: Model)
	if veils[model] then
		return
	end

	local veil = { model = model, holds = {}, conns = {} }
	veils[model] = veil
	veilCount += 1

	if model:IsA("BasePart") then
		hide(veil, model)
	end
	for _, d in model:GetDescendants() do
		hide(veil, d)
	end

	-- A machine is not finished when it arrives, in two separate ways: it is
	-- still replicating in, and AtvBuilder.fitRake destroys and rebuilds the
	-- towed bar whenever a rake level changes. Both arrive as descendants.
	table.insert(veil.conns, model.DescendantAdded:Connect(function(d)
		if veils[model] then
			hide(veil, d)
		end
	end))
	table.insert(veil.conns, model.DescendantRemoving:Connect(function(d)
		local record = veil.holds[d]
		if record then
			record.conn:Disconnect()
			veil.holds[d] = nil
		end
	end))
end

local function detach(model: Model)
	local veil = veils[model]
	if not veil then
		return
	end
	veils[model] = nil
	veilCount -= 1

	for _, conn in veil.conns do
		conn:Disconnect()
	end

	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = 0
		end
	end
	-- ...and every held property back to whatever the server last said it should
	-- be, rather than to whatever it happened to be when we took hold of it.
	for inst, record in veil.holds do
		record.conn:Disconnect()
		if inst.Parent then
			local held: any = inst
			pcall(function()
				held[record.prop] = record.want
			end)
		end
	end
	veil.holds = {}
end

----------------------------------------------------------------
-- WIRING
----------------------------------------------------------------
-- Mine is always drawn. Everything else is drawn once the server clears the
-- flag -- and an unstamped model (a Studio session with a stale machine in it,
-- say) is treated as visible rather than as hidden, because a machine nobody
-- can see is the worse failure of the two.
local function shouldVeil(model: Model): boolean
	if model:GetAttribute(OWNER) == player.UserId then
		return false
	end
	return model:GetAttribute(CONCEALED) == true
end

local function evaluate(model: Model)
	if shouldVeil(model) then
		attach(model)
	else
		detach(model)
	end
end

local function bind(model: Instance)
	if not model:IsA("Model") or watched[model] then
		return
	end
	local conns = {
		model:GetAttributeChangedSignal(CONCEALED):Connect(function()
			evaluate(model)
		end),
		model:GetAttributeChangedSignal(OWNER):Connect(function()
			evaluate(model)
		end),
	}
	watched[model] = conns
	evaluate(model)
end

local function unbind(model: Instance)
	local conns = watched[model]
	if conns then
		for _, conn in conns do
			conn:Disconnect()
		end
		watched[model] = nil
	end
	-- Nothing to restore on a destroyed model, and detach copes with that (it
	-- checks Parent before writing) -- but a tag REMOVED from a machine that is
	-- still standing there has to give the machine back.
	if model:IsA("Model") then
		detach(model)
	end
end

for _, model in CollectionService:GetTagged(TAG) do
	bind(model)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(bind)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(unbind)

local since = 0
RunService.Heartbeat:Connect(function(dt)
	if veilCount == 0 then
		return
	end
	since -= dt
	if since > 0 then
		return
	end
	since = REPAINT
	for model, veil in veils do
		if model.Parent then
			repaint(veil)
		end
	end
end)
