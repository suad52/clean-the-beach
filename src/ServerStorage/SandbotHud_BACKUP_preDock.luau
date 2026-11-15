--[[
	SandbotHud  --  StarterPlayerScripts.SandbotHud

	The SANDBOT key, on the left-hand column under the backpack and QUICK
	SELL row -- plus the small amount of cosmetic motion the drone itself needs.

	ONE KEY, THREE CONTROLS, and that is on purpose -- it is exactly the shape
	CTB_HUD's QUICK SELL key already has, and for the same reason. The thing
	being sold IS a button, so the honest place to advertise it is where the
	button will be:

		unbought   a storefront. Name over price, grape, opens Roblox's dialog.
		stowed     DEPLOY. Sends the drone out.
		out        RECALL, with what it is doing on the second line.

	paint() below owns which of the three it currently is and NOTHING ELSE MAY
	DECIDE. Every input it reads arrives late and none of it can be read once:
	ownership lands when GamePassService finishes a web call, the price lands on
	a folder that does not exist during the first second of a session, and the
	drone's state arrives on a remote. So this is wired to all four signals at
	the foot of the file rather than run off a snapshot.

	WHY IT IS ITS OWN ScreenGui
	---------------------------
	The column already spans two -- CTB_HUD's three readouts and InventoryHud's
	backpack key -- and HudKit.L is what keeps them in one line. A third is the
	same arrangement again, under the same rule: IgnoreGuiInset FALSE, so all
	three measure y from the same origin, and HudKit.fitColumn so all three
	shrink together on a phone. UiFit picks it up on its own (it watches
	PlayerGui.ChildAdded), so there is nothing to register.

	OWNERSHIP IS THE CLIENT'S COPY and is only ever good enough to decide what
	this button SAYS. A press still has to get past GamePassService on the
	server, which asks Roblox rather than reading the attribute. Being wrong here
	costs a wrong-looking button and one refused tap -- nothing more.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local HudKit = require(Modules:WaitForChild("HudKit"))
local Net = require(Modules:WaitForChild("Net"))
local PassConfig = require(Modules:WaitForChild("PassConfig"))
local SandbotConfig = require(Modules:WaitForChild("SandbotConfig"))
local ToastKit = require(Modules:WaitForChild("ToastKit"))
local AudioKit = require(Modules:WaitForChild("AudioKit"))

local player = Players.LocalPlayer

local L = HudKit.L
local A = HudKit.A

local ENTRY = PassConfig.Passes.Sandbot

local CREAM = Color3.fromRGB(255, 246, 224)
local OUTLINE = Color3.fromRGB(30, 42, 56)
local GRAPE = Color3.fromRGB(186, 128, 255)
local GRAPE_DEEP = Color3.fromRGB(108, 62, 176)

local SandbotHud = {}

local gui, holder, face, title, sub
local snapshot = nil          -- the last SandbotSync payload, or nil when stowed
local started = false

----------------------------------------------------------------
-- THE GLYPH
----------------------------------------------------------------
--[[
	Drawn from Frames, never typed as an emoji -- the rule the rest of HudKit's
	glyphs follow, because an emoji is at the mercy of whatever the player's
	device ships and half of them ship these as something else entirely.

	The drone from the front: a body, a lid, and the two eyes. Four frames, and
	it is recognisable at 40px because the EYES are what the model reads as from
	across the beach too -- the icon and the object agree about what the thing
	looks like.
]]
local function droneGlyph(parent: Instance, px: number)
	local root = Instance.new("Frame")
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromOffset(px, px)
	root.ZIndex = 9
	root.Parent = parent

	local body = Instance.new("Frame")
	body.BackgroundColor3 = A.sea
	body.BorderSizePixel = 0
	body.Size = UDim2.fromOffset(px, px * 0.62)
	body.Position = UDim2.fromOffset(0, px * 0.30)
	body.ZIndex = 9
	body.Parent = root
	HudKit.corner(body, math.floor(px * 0.28))
	HudKit.outline(body, 2.5, OUTLINE, 0)

	local lid = Instance.new("Frame")
	lid.BackgroundColor3 = CREAM
	lid.BorderSizePixel = 0
	lid.Size = UDim2.fromOffset(px * 0.56, px * 0.22)
	lid.Position = UDim2.fromOffset(px * 0.22, px * 0.18)
	lid.ZIndex = 10
	lid.Parent = root
	HudKit.corner(lid, math.floor(px * 0.11))
	HudKit.outline(lid, 2.5, OUTLINE, 0)

	for i, x in { 0.20, 0.58 } do
		local e = Instance.new("Frame")
		e.Name = "Eye" .. i
		e.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		e.BorderSizePixel = 0
		e.Size = UDim2.fromOffset(px * 0.22, px * 0.22)
		e.Position = UDim2.fromOffset(px * x, px * 0.46)
		e.ZIndex = 11
		e.Parent = root
		HudKit.corner(e, math.floor(px * 0.11))

		local pupil = Instance.new("Frame")
		pupil.BackgroundColor3 = OUTLINE
		pupil.BorderSizePixel = 0
		pupil.Size = UDim2.fromOffset(px * 0.11, px * 0.11)
		pupil.Position = UDim2.fromOffset(px * 0.055, px * 0.055)
		pupil.ZIndex = 12
		pupil.Parent = e
		HudKit.corner(pupil, math.floor(px * 0.055))
	end

	return root
end

----------------------------------------------------------------
-- PAINT
----------------------------------------------------------------
local function isOut(): boolean
	-- Two sources, and the ATTRIBUTE is the one that decides. The sync payload
	-- carries the detail (what it is doing, how much it has raked) but it is
	-- fired on a timer, so between a tap and the next sync the attribute is the
	-- only thing that has caught up -- and a key that stays on DEPLOY for half a
	-- second after you pressed it reads as a press that did not register.
	return player:GetAttribute(SandbotConfig.OutAttribute) == true
end

local function paint()
	if not face then
		return
	end

	local owned = SandbotConfig.owns(player)

	if not owned then
		--[[
			THE STOREFRONT. Two lines: the name over what it costs.

				R$ 199   grape, live   -- opens Roblox's own dialog
				SOON     grape, inert  -- the pass is off sale, or has not been
				                         created yet, and NO AMOUNT OF CODE FIXES
				                         EITHER. A price here would be a figure for
				                         something Roblox will refuse to sell.

			The same two the Robux shop's rows use, in the same colours, so a
			player who has seen one recognises the other.
		]]
		HudKit.regrad(face, GRAPE, GRAPE_DEEP)
		title.Text = ENTRY.name:upper()
		title.TextSize = 19
		title.TextColor3 = CREAM
		title.Position = UDim2.fromOffset(58, 4)
		title.Size = UDim2.new(1, -68, 0, 24)
		sub.Visible = true
		local price = PassConfig.price(ENTRY.id)
		sub.Text = (price and PassConfig.onSale(ENTRY.id))
			and ("R$ " .. price) or "SOON"
		sub.TextColor3 = Color3.fromRGB(240, 230, 255)
		return
	end

	if not isOut() then
		-- Bought and stowed. One line, and the LIME the game already uses for
		-- "nothing is wrong, go ahead".
		HudKit.regrad(face, Color3.fromRGB(150, 232, 110), Color3.fromRGB(86, 162, 52))
		title.Text = "DEPLOY SANDBOT"
		title.TextSize = 20
		title.TextColor3 = CREAM
		title.Position = UDim2.fromOffset(58, 0)
		title.Size = UDim2.new(1, -68, 1, 0)
		sub.Visible = false
		return
	end

	-- Out. Two lines again: the verb over what it is doing.
	local state = snapshot and snapshot.state or "docked"
	local full = state == "full"
	if full then
		-- CORAL, the game's one refusal colour. The drone is not broken and the
		-- button still works -- it is telling the player to go and sell.
		HudKit.regrad(face, Color3.fromRGB(255, 132, 122), Color3.fromRGB(186, 54, 52))
	else
		HudKit.regrad(face, A.seaLight, A.seaDeep)
	end
	title.Text = "RECALL SANDBOT"
	title.TextSize = 19
	title.TextColor3 = CREAM
	title.Position = UDim2.fromOffset(58, 4)
	title.Size = UDim2.new(1, -68, 0, 24)
	sub.Visible = true
	sub.TextColor3 = full and Color3.fromRGB(255, 232, 226) or Color3.fromRGB(226, 244, 255)

	local label = (snapshot and snapshot.label) or SandbotConfig.Labels.docked
	local raked = (snapshot and tonumber(snapshot.raked)) or 0
	-- The count is left off until there IS one: "SWEEPING - 0 raked" on the first
	-- second of every deployment reads as a drone that is not working.
	sub.Text = raked > 0
		and string.format("%s \u{00B7} %d raked", label, raked)
		or label
end

----------------------------------------------------------------
-- THE DRONE'S OWN MOTION
----------------------------------------------------------------
--[[
	SPINNING BRUSHES AND A BOBBING AERIAL, DRAWN ENTIRELY ON THIS MACHINE.

	The server writes ONE CFrame per drone per tick -- the hull -- and everything
	else on the model is welded to it. The brushes hang off Motor6Ds instead, and
	this writes their C0 locally: a property written by a client onto a
	server-owned instance applies here and replicates NOWHERE, so eight drones on
	a busy server cost the network nothing at all for the one cue that says this
	thing is cleaning.

	PER FRAME rather than on the server's 20 Hz tick, because that is the whole
	point of doing it here -- a spin stepped at 20 Hz strobes.

	IT DRIVES OFF THE FOLDER, NOT OFF THE LOCAL PLAYER'S DRONE. Everybody's
	drone spins on everybody's screen; there is no ownership check anywhere in
	this block, deliberately.
]]
-- THE AERIAL IS NOT ANIMATED, and it was meant to be. It is welded to the hull,
-- so a per-frame CFrame write is fought by the weld on the next physics step and
-- settles into a shimmer rather than a bob. Un-welding it would cost a joint per
-- drone for two tenths of a stud of motion, and the mast already whips visibly
-- when the drone corners -- which is the liveliness it was put there for.
local SPIN_RATE = 7.5         -- radians/second

--[[
	WHERE EACH JOINT'S REST POSE IS REMEMBERED.

	C0 is about to stop being the rest pose, so it has to be captured the first
	time a joint is touched -- reading it back off a spinning joint on a later
	frame compounds the rotation and flings the brush out to the horizon.

	A LOCAL TABLE, not an attribute on the joint. An attribute would work (a
	client's write to a server-owned instance stays local), but it would also
	show up in everybody's Explorer as state this HUD had scribbled onto the
	world, and it is not world state -- it is this file's scratch pad. Weak keys
	so a recalled drone's joints are collectable rather than pinned for the rest
	of the session.
]]
local restPose = setmetatable({}, { __mode = "k" })

--[[
	⚠️ DO NOT INTERPOLATE THE HULL ON THE CLIENT. IT WAS TRIED AND IT IS WORSE.

	The temptation is obvious. SandbotService drives the hull every server frame,
	but an anchored part's CFrame only REPLICATES at about 30 Hz, so on a 60 fps
	client the drone advances on roughly half the frames. Easing a rendered pose
	toward the replicated one in this very loop looks like free smoothness and
	costs no bandwidth.

	IT FIGHTS REPLICATION AND LOSES. The client's eased pose necessarily lags
	the authoritative one, so the sequence per frame is: server update lands and
	puts the hull AHEAD, this loop writes the eased pose and pulls it BACK.
	Measured over 360 rendered frames: **47.9% of them moved the drone
	BACKWARDS along its own nose, by up to 1.4 studs**, and the apparent speed
	went from 29 studs/s to 98. A drone that visibly shudders back and forth is
	a great deal worse than one that advances every other frame.

	The same 360-frame test on the SERVER's own copy: 359 forward, 0 backward,
	28.8 studs/s. The authoritative motion is already perfect -- the ~30 Hz
	replication rate is the floor, and it is not something a client-side write
	can get underneath.

	If this ever genuinely needs to be smoother, the answer is to make the hull
	a PHYSICS body (AtvServer's machines are smooth because Roblox interpolates
	parts it simulates), not to write CFrames from here.
]]

local function startMotion()
	local spin = 0
	RunService.RenderStepped:Connect(function(dt)
		local folder = workspace:FindFirstChild("Sandbots")
		if not folder then
			return
		end
		spin = (spin + SPIN_RATE * dt) % (math.pi * 2)
		local turn = CFrame.Angles(0, spin, 0)     -- about the HULL's up, see below

		for _, model in folder:GetChildren() do
			local hull = model:IsA("Model") and model.PrimaryPart
			if hull then
				-- The hull's CFrame is the SERVER's and is never written from here.
				-- See the block at the top of this section for what happened when it
				-- was. Only the brush joints below are client-side.
				for _, joint in hull:GetChildren() do
					if joint:IsA("Motor6D") and joint.Name == "Spin" then
						local rest = restPose[joint]
						if not rest then
							rest = joint.C0
							restPose[joint] = rest
						end
						--[[
							TURNED ABOUT THE HULL'S VERTICAL, THROUGH THE HUB'S OWN
							POSITION -- not post-multiplied onto the rest pose.

							`rest * CFrame.Angles(0, spin, 0)` was the first version and
							it tumbles the brush end over end. The hub is a STOOD-UP
							cylinder: SandbotBuilder.disc bakes Angles(0, 0, pi/2) into it
							so the cylinder's axis (local X) points at world up -- which
							means the hub's local Y lies flat IN the disc, and turning
							about it rolls the brush like a wheel instead of spinning it
							like a brush. Measured: the disc's axis walked from (0,1,0)
							to (0,0.70,0.71) over one radian.

							Splitting the rest into its position and its rotation and
							putting the yaw BETWEEN them turns the hub about the hull's
							up axis, wherever the pieces happen to be pointing. It does
							not depend on knowing which local axis the cylinder uses,
							which is the part that was easy to get wrong.
						]]
						joint.C0 = CFrame.new(rest.Position) * turn * (rest - rest.Position)
					end
				end
			end
		end
	end)
end

----------------------------------------------------------------
-- BUILD
----------------------------------------------------------------
function SandbotHud.start()
	if started then
		return
	end
	started = true

	gui = Instance.new("ScreenGui")
	gui.Name = "SandbotHud"
	gui.ResetOnSpawn = false
	-- The same order InventoryHud sits at: this is the same column and neither
	-- ever overlaps the other.
	gui.DisplayOrder = 6
	-- FALSE, matching CTB_HUD's and InventoryHud's. All three measure y from the
	-- same origin only if they agree about the topbar, and HudKit.L's numbers
	-- mean nothing if they do not.
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	holder, face = HudKit.pressable(gui, L.W, L.SANDBOT_H, A.sea, 18)
	holder.Name = "SandbotKey"
	holder.Position = UDim2.fromOffset(L.X, L.SANDBOT_Y)
	-- The same compact pass the four pieces above this get. AFTER the Position:
	-- fitColumn captures the offset it is handed and rescales from there, so a
	-- piece given to it before it has been placed is pinned at the origin.
	HudKit.fitColumn(holder)

	local glyph = droneGlyph(face, 40)
	glyph.Position = UDim2.fromOffset(11, 6)

	title = HudKit.text(face, "SANDBOT", 19, CREAM, Enum.Font.LuckiestGuy)
	title.ZIndex = 9
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	HudKit.punch(title, 2.5, OUTLINE, 0.1)

	sub = HudKit.text(face, "", 14, CREAM, Enum.Font.GothamBold)
	sub.ZIndex = 9
	sub.Size = UDim2.new(1, -68, 0, 20)
	sub.Position = UDim2.fromOffset(58, 27)
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.TextTruncate = Enum.TextTruncate.AtEnd
	HudKit.punch(sub, 2, OUTLINE, 0.2)

	--------------------------------------------------------------
	-- THE PRESS
	--------------------------------------------------------------
	face.Activated:Connect(function()
		AudioKit.play("UIClick", nil, 1, 1.1)

		if not SandbotConfig.owns(player) then
			--[[
				STRAIGHT TO MARKETPLACESERVICE, not through a remote.

				PromptGamePassPurchase is a CLIENT call -- there is no server-side
				way to open a purchase dialog on somebody's screen -- so a remote
				here would be a hop that changes nothing. It is not a hole either:
				the server hears the result on PromptGamePassPurchaseFinished and
				then goes and ASKS Roblox rather than believing the callback.

				OFF SALE IS A TOAST, NOT A DIALOG, and that branch also covers the
				pass not existing yet (id 0): PassConfig.onSale is false for both,
				and prompting either would open a modal the player cannot complete
				and leave them thinking the purchase failed.
			]]
			if not PassConfig.onSale(ENTRY.id) then
				ToastKit.toast(ENTRY.name .. " is not on sale yet.", "deny", 2.6)
				return
			end
			MarketplaceService:PromptGamePassPurchase(player, ENTRY.id)
			return
		end

		-- Owned. One word, and no client-side early-out: the server owns every
		-- precondition (are they alive, are they on a field, do they really own
		-- the pass) and answers a refusal in words.
		Net.get("SandbotControl"):FireServer(isOut() and "recall" or "deploy")
	end)

	--------------------------------------------------------------
	-- WHAT MAKES IT REPAINT
	--------------------------------------------------------------
	-- 1. The drone went out or came back.
	player:GetAttributeChangedSignal(SandbotConfig.OutAttribute):Connect(paint)

	-- 2. Ownership landed. GamePassService writes this when its web call comes
	--    back, which is well after this file has drawn itself.
	player:GetAttributeChangedSignal(ENTRY.attribute):Connect(paint)

	-- 3. What the drone is doing.
	Net.get("SandbotSync").OnClientEvent:Connect(function(payload)
		snapshot = (type(payload) == "table") and payload or nil
		paint()
	end)

	--[[
		4. The price landed.

		The info folder does not exist during the first second of a session, so
		this waits for it on a thread rather than reading a snapshot -- exactly
		what CTB_HUD's sell key and the shop panel both do. If it never arrives
		the key still draws; it just keeps saying SOON, which is the honest answer
		for a pass whose price could not be read.
	]]
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild(PassConfig.InfoFolder, 30)
		if folder then
			folder.AttributeChanged:Connect(paint)
			paint()
		end
	end)

	paint()
	startMotion()
end

return SandbotHud
