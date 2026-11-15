--[[
	SandbotClient  --  StarterPlayerScripts.SandbotClient

	THE SANDBOT'S WHOLE CLIENT HALF, AND IT DRAWS NOTHING.

	Four jobs, and not one of them is a button:

		1. THE BRUSH SPIN -- the one cue that says the machine is cleaning,
		   written locally onto a server-owned joint so it costs the network
		   nothing at all. It covers the drones that are out AND the one parked
		   in each island's dock.

		2. WHAT THE DOCK'S PROMPT SAYS -- the three states the old HUD key had,
		   repainted onto the walk-up prompt for this player alone. Same trick as
		   the spin: a local write to a server-owned instance.

		3. EMPTYING THE KENNEL -- while this player's drone is out, the display
		   machine in the dock it left is hidden ON THIS SCREEN ONLY, so the
		   drone driving out of it reads as that machine leaving rather than as
		   a second one budding off it. The same trick a third time.

		4. THE PURCHASE DIALOG -- MarketplaceService:PromptGamePassPurchase is a
		   CLIENT call and there is no server-side form of it. So when the dock
		   turns somebody away for not owning the pass, the server names the pass
		   on SandbotOffer and this file puts the dialog up.

	WHAT IT REPLACED
	----------------
	SandbotHud: a full-width key on the left-hand column that read BEACH SANDBOT
	over a price to a player who did not own the pass, DEPLOY to one who did, and
	RECALL / SWEEPING - 41 raked while the drone was out. It is parked in
	ServerStorage as SandbotHud_BACKUP_preDock.

	It was on screen for every second of every session whether or not the player
	had any interest in the drone, and it sold a Robux purchase from the same
	corner as the coin counter. The SANDBOT HOME beside each island's car spawner
	says the same three things -- here is the machine, here is what it costs,
	press E -- to somebody who has walked up to it, which is how every other
	purchase in this game is made.

	NOTHING IS BOUGHT ON THE STRENGTH OF ANYTHING IN HERE. The dialog is
	Roblox's; GamePassService hears the outcome on PromptGamePassPurchaseFinished
	and goes and ASKS Roblox rather than believing a callback.
]]

local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Net = require(Modules:WaitForChild("Net"))
local PassConfig = require(Modules:WaitForChild("PassConfig"))
local SandbotConfig = require(Modules:WaitForChild("SandbotConfig"))
local ToastKit = require(Modules:WaitForChild("ToastKit"))

local player = Players.LocalPlayer

local SandbotClient = {}

local started = false

-- The two names this file has to agree with the server about: the folder
-- SandbotService parks deployed drones in, and the tag SandbotDockBuilder puts
-- on every dock. Spelled once each, here.
local FOLDER_NAME = "Sandbots"
local DOCK_TAG = "SandbotDock"
local DISPLAY_NAME = "DisplaySandbot"

----------------------------------------------------------------
-- THE DRONE'S OWN MOTION
----------------------------------------------------------------
--[[
	SPINNING BRUSHES, DRAWN ENTIRELY ON THIS MACHINE.

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

	AND OFF THE DOCKS AS WELL. Each SANDBOT HOME has an inert machine parked on
	its charging plate -- the showroom stock, exactly as AtvServer stands a
	bulldozer on the car pad's plinths -- and a parked drone whose brushes are
	dead still reads as a prop. The same three lines animate both because a
	display bot is a real one that is never driven.
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
	show up in everybody's Explorer as state this file had scribbled onto the
	world, and it is not world state -- it is this file's scratch pad. Weak keys
	so a recalled drone's joints are collectable rather than pinned for the rest
	of the session.
]]
local restPose = setmetatable({}, { __mode = "k" })

--[[
	THE PARKED MACHINES, RE-SWEPT ON A SLOW TIMER RATHER THAN WATCHED.

	CollectionService:GetTagged builds a fresh array on every call and this loop
	runs sixty times a second, so it cannot be asked per frame. The first version
	swept once at start and then relied on GetInstanceAddedSignal for the rest.

	THAT DID NOT WORK, AND IT FAILED SILENTLY: measured in Play, all four docks
	were visible to CollectionService:GetTagged afterwards and not one display
	bot was spinning. The docks are built by the server at the end of ServerMain
	-- the same moment this file is starting up -- so the sweep is a race, and
	the added signal did not cover the loss. Nothing errors; the machines just
	sit dead still in their kennels, which reads as scenery rather than as stock.

	So there is ONE mechanism now instead of two, and it is the one that cannot
	be out of step with the world: ask again every SWEEP_EVERY seconds. Half a
	GetTagged call a second over four docks is nothing, and it also picks up a
	dock that streamed back in, or one Island4 rebuilt after its island was
	thrown away.

	Weak keys, same reason as restPose: a display whose dock has gone should be
	collectable rather than pinned for the session.
]]
local parked = setmetatable({}, { __mode = "k" })
local SWEEP_EVERY = 2

--[[
	DO NOT INTERPOLATE THE HULL ON THE CLIENT. IT WAS TRIED AND IT IS WORSE.

	The temptation is obvious. SandbotService drives the hull every server frame,
	but an anchored part's CFrame only REPLICATES at about 30 Hz, so on a 60 fps
	client the drone advances on roughly half the frames. Easing a rendered pose
	toward the replicated one in this very loop looks like free smoothness and
	costs no bandwidth.

	IT FIGHTS REPLICATION AND LOSES. The client's eased pose necessarily lags
	the authoritative one, so the sequence per frame is: server update lands and
	puts the hull AHEAD, this loop writes the eased pose and pulls it BACK.
	Measured over 360 rendered frames: 47.9% of them moved the drone BACKWARDS
	along its own nose, by up to 1.4 studs, and the apparent speed went from 29
	studs/s to 98. A drone that visibly shudders back and forth is a great deal
	worse than one that advances every other frame.

	The same 360-frame test on the SERVER's own copy: 359 forward, 0 backward,
	28.8 studs/s. The authoritative motion is already perfect -- the ~30 Hz
	replication rate is the floor, and it is not something a client-side write
	can get underneath. SandbotConfig.Speed came down to 22 partly for this
	reason: slower is literally smoother here.

	If this ever genuinely needs to be smoother, the answer is to make the hull
	a PHYSICS body (AtvServer's machines are smooth because Roblox interpolates
	parts it simulates), not to write CFrames from here.
]]
local function spinBrushes(model: Instance, turn: CFrame)
	local hull = model:IsA("Model") and model.PrimaryPart
	if not hull then
		return
	end
	-- The hull's CFrame is the SERVER's and is never written from here. See the
	-- block above for what happened when it was. Only the brush joints are ours.
	for _, joint in hull:GetChildren() do
		if joint:IsA("Motor6D") and joint.Name == "Spin" then
			local rest = restPose[joint]
			if not rest then
				rest = joint.C0
				restPose[joint] = rest
			end
			--[[
				TURNED ABOUT THE HULL'S VERTICAL, THROUGH THE HUB'S OWN POSITION --
				not post-multiplied onto the rest pose.

				`rest * CFrame.Angles(0, spin, 0)` was the first version and it
				tumbles the brush end over end. The hub is a STOOD-UP cylinder:
				SandbotBuilder.disc bakes Angles(0, 0, pi/2) into it so the
				cylinder's axis (local X) points at world up -- which means the
				hub's local Y lies flat IN the disc, and turning about it rolls the
				brush like a wheel instead of spinning it like a brush. Measured:
				the disc's axis walked from (0,1,0) to (0,0.70,0.71) over one radian.

				Splitting the rest into its position and its rotation and putting the
				yaw BETWEEN them turns the hub about the hull's up axis, wherever the
				pieces happen to be pointing. It does not depend on knowing which
				local axis the cylinder uses, which is the part that was easy to get
				wrong.
			]]
			joint.C0 = CFrame.new(rest.Position) * turn * (rest - rest.Position)
		end
	end
end

-- FindFirstChild, never WaitForChild: this runs off the render loop and must
-- not yield. A dock whose display has not replicated yet is simply picked up by
-- the next sweep, which is what makes the timer the whole mechanism.
local function sweepDocks()
	for _, dock in CollectionService:GetTagged(DOCK_TAG) do
		local display = dock:FindFirstChild(DISPLAY_NAME)
		if display then
			parked[display] = true
		end
	end
end

----------------------------------------------------------------
-- WHAT THE DOCK'S PROMPT SAYS
----------------------------------------------------------------
--[[
	THE OLD HUD KEY'S THREE STATES, MOVED ONTO THE BUILDING.

		unbought   GET THE SANDBOT over its price -- a storefront, which is the
		           honest thing to put in front of somebody who cannot use it.
		stowed     DEPLOY SANDBOT.
		out        RECALL SANDBOT.

	A ProximityPrompt is ONE instance shown to everybody in range, so on the face
	of it these cannot differ per player -- and SandbotService's bindDock says as
	much about the text IT writes. They differ anyway, because a CLIENT's write
	to a property of a server-owned instance applies here and replicates NOWHERE.
	Exactly the fact the brush spin above is built on, spent on two strings
	instead of a joint.

	NOTHING HERE IS A PRECONDITION. Being wrong costs a wrong-looking prompt and
	one press that gets answered differently from how it was labelled: the server
	re-asks GamePassService (which asks Roblox) before it spawns anything, and
	the unowned branch fires the offer. That is the same rule PassConfig.owns is
	written under.

	EVERY INPUT ARRIVES LATE and none of it can be read once -- ownership lands
	when a web call comes back, the price lands on a folder that does not exist
	in the first second of a session, the docks stream in island by island, and
	the drone's state changes on a keypress. So this is wired to all four signals
	at the foot of the file AND re-run by the dock sweep, rather than run off a
	snapshot.
]]
local function promptText(): (string, string)
	if not SandbotConfig.owns(player) then
		local entry = PassConfig.get(SandbotConfig.PassKey)
		local id = entry and entry.id
		--[[
			THE NAME COMES OFF PassConfig, NOT OUT OF THIS FILE, because that is the
			one place that holds what the STORE PAGE calls it -- "SandBot", asked of
			Roblox. This line sits directly under a button that opens Roblox's own
			dialog, and the two disagreeing is the one thing a storefront may not do.

			THE PRICE IS DELIBERATELY NOT ON THE PROMPT. This used to return
			"R$ " .. price as the object line -- the figure quoted on the sign before
			the player had shown the least interest in it, which is the same complaint
			SandbotDockBuilder's header makes about the old HUD key advertising a
			Robux purchase from the corner of the screen. Roblox's own dialog states
			the price and offer() toasts it, and BOTH of those happen after the press.
			Nothing is hidden; it is just not quoted first.

			"Coming soon" STAYS, AND IT IS NOT A PRICE. It covers both an off-sale
			pass and one nobody has created yet, and it is the one thing a player does
			need before pressing -- without it the press opens a modal they cannot
			complete, which reads as a purchase that failed. On sale, the object line
			says what the building is, the way the owned states already do.

			onSale() checks the price is published itself, so there is nothing left
			here that needs to read the figure.
		]]
		return "Get the " .. ((entry and entry.name) or "Sandbot"),
			PassConfig.onSale(id) and "Sandbot Home" or "Coming soon"
	end
	if player:GetAttribute(SandbotConfig.OutAttribute) == true then
		return "Recall Sandbot", "Sandbot Home"
	end
	return "Deploy Sandbot", "Sandbot Home"
end

local function paintPrompts()
	local action, object = promptText()
	for _, dock in CollectionService:GetTagged(DOCK_TAG) do
		local anchor = dock:FindFirstChild("PromptAnchor")
		local prompt = anchor and anchor:FindFirstChildWhichIsA("ProximityPrompt")
		-- Guarded on a real change: these are cheap, but they are also written
		-- from a 2 second sweep over every dock in the game, and a property set to
		-- the value it already has is still a change signal fired at whatever is
		-- listening -- which here is Roblox's own prompt UI.
		if prompt and (prompt.ActionText ~= action or prompt.ObjectText ~= object) then
			prompt.ActionText = action
			prompt.ObjectText = object
		end
	end
end

----------------------------------------------------------------
-- WHOSE MACHINE IS IN THE KENNEL
----------------------------------------------------------------
--[[
	THE DISPLAY MACHINE STEPS ASIDE FOR ITS OWNER, AND FOR NOBODY ELSE.

	A deployed drone is placed on the charging plate in the display's exact pose
	and drives out from there. That only reads as THE machine leaving if the one
	parked in the kennel stops being visible; otherwise it reads as a second drone
	budding off the first. Same at the other end -- the drone parks in the
	display's pose and is destroyed, and the display returning in the same frame is
	what makes the handover invisible.

	A DOCK IS ONE BUILDING SHOWN TO EVERYBODY, THOUGH, and the drone is per player.
	So this cannot be a server-side Destroy or a replicated Transparency: it is the
	same fact the brush spin and the prompt text are built on -- a CLIENT's write
	to a server-owned property applies here and replicates NOWHERE. The kennel
	empties for the player whose machine just drove out of it and stays stocked for
	everybody else, who see showroom stock and somebody else's drone, which is the
	true account of what is in front of them.

	LocalTransparencyModifier RATHER THAN Transparency, because it is the property
	that MEANS this -- a value the renderer lays over the replicated one -- and
	because it leaves the real Transparency alone for whatever the server does with
	it later. Guarded on a real change: this runs off the dock sweep as well as off
	the attribute, and a property set to what it already holds is still a change
	signal fired at the renderer.
]]
local function setHidden(display: Instance, hide: boolean)
	local want = hide and 1 or 0
	for _, part in display:GetDescendants() do
		if part:IsA("BasePart") and part.LocalTransparencyModifier ~= want then
			part.LocalTransparencyModifier = want
		end
	end
end

--[[
	BY NAME, off the two attributes the server writes together.

	ONE KENNEL, NOT ALL FOUR. The other three have nothing to do with this player's
	drone and are still selling the pass to whoever walks past them.

	A NAME THAT MATCHES NOTHING HIDES NOTHING, which is exactly the right failure:
	Island4 destroys and rebuilds its island, dock included, and a drone that came
	out of the old one simply leaves a stocked kennel behind it. A dangling
	instance reference was the alternative.
]]
local function syncDisplays()
	local out = player:GetAttribute(SandbotConfig.OutAttribute) == true
	local home = player:GetAttribute(SandbotConfig.HomeAttribute)
	for _, dock in CollectionService:GetTagged(DOCK_TAG) do
		local display = dock:FindFirstChild(DISPLAY_NAME)
		if display then
			setHidden(display, out and dock.Name == home)
		end
	end
end

local function startMotion()
	local spin = 0
	local nextSweep = 0
	RunService.RenderStepped:Connect(function(dt)
		spin = (spin + SPIN_RATE * dt) % (math.pi * 2)
		local turn = CFrame.Angles(0, spin, 0)     -- about the HULL's up

		local folder = workspace:FindFirstChild(FOLDER_NAME)
		if folder then
			for _, model in folder:GetChildren() do
				spinBrushes(model, turn)
			end
		end

		local now = os.clock()
		if now >= nextSweep then
			nextSweep = now + SWEEP_EVERY
			sweepDocks()
			-- The same sweep paints the prompts and re-hides the stock, for the same
			-- reason it finds the parked machines at all: a dock that streamed in a
			-- moment ago is wearing the server's neutral fallback text and is fully
			-- stocked, and nothing else would come along and correct either.
			paintPrompts()
			syncDisplays()
		end

		for display in parked do
			if display.Parent then
				spinBrushes(display, turn)
			else
				-- Streamed out, or its island was rebuilt. The sweep above puts the
				-- replacement back.
				parked[display] = nil
			end
		end
	end)
end

----------------------------------------------------------------
-- THE SHOP DIALOG
----------------------------------------------------------------
--[[
	E IS A KEY PEOPLE LEAN ON, so the DIALOG is rationed -- and only the dialog.

	Without the gap, holding E at the dock is a stack of purchase modals. The
	OFF-SALE toast below is deliberately outside the ration: a player who presses
	twice and is told nothing the second time has been given a broken button, and
	a toast is cheap.

	The same shape AtvClient's promptPass branch uses, for the same reason.
]]
local PROMPT_GAP = 6
local lastPrompt = -math.huge

local function offer(passId: number)
	--[[
		OFF SALE IS A TOAST, NOT A DIALOG, and that branch also covers a pass
		nobody has created yet. PassConfig.onSale is false for both, and prompting
		either opens a modal the player CANNOT COMPLETE -- see GamePassService's
		header -- which reads as a purchase that failed rather than as a pass that
		is not for sale.

		THE SANDBOT IS LIVE NOW (1955383241, R$ 99), so the ordinary path through
		here is the dialog. The branch stays because the seller's own account is
		still refused by Roblox and because a pass can be taken off sale from the
		Dashboard at any time, with no code change to notice it.

		THE CLIENT OWNS THIS WORDING RATHER THAN THE SERVER, because the price and
		the on-sale flag live in the replicated info folder and the server would be
		guessing at both. SandbotService fires the id and says nothing.
	]]
	local entry = PassConfig.get(SandbotConfig.PassKey)
	local name = (entry and entry.name) or "Sandbot"

	if not PassConfig.onSale(passId) then
		ToastKit.toast(name .. " is not on sale yet.", "deny", 2.6)
		return
	end

	if os.clock() - lastPrompt < PROMPT_GAP then
		return
	end
	lastPrompt = os.clock()

	--[[
		STRAIGHT TO MARKETPLACESERVICE. It is not a hole: the server hears the
		result on PromptGamePassPurchaseFinished and then goes and ASKS Roblox
		rather than believing the callback, so the worst this can do is open a
		dialog somebody did not want.
	]]
	local price = PassConfig.price(passId)
	ToastKit.toast(price
		and string.format("%s \u{2014} R$ %d", name, price)
		or name, "info", 2.2)
	MarketplaceService:PromptGamePassPurchase(player, passId)
end

----------------------------------------------------------------
-- REPAINT
----------------------------------------------------------------
--[[
	THE PROMPTS AND THE KENNELS ANSWER TO THE SAME SIGNALS, so they are repainted
	together rather than each wiring its own copy of the list.

	THERE IS NO KEY IN HERE ANY MORE. One stood in the left-hand column for owners
	-- DEPLOY over RECALL, never a price -- and it has gone, because the drone now
	comes OUT OF and GOES BACK INTO a building, and "which building" is not
	something a button in the corner of the screen can answer. The dock's own
	prompt can: Triggered hands the server the player AND the instance they
	pressed, both vouched for by the engine. HudKit's optional-row seam went with
	it, and the carried-items drawer has its 66 pixels back.
]]
local function repaint()
	paintPrompts()
	syncDisplays()
end

----------------------------------------------------------------
-- BOOT
----------------------------------------------------------------
function SandbotClient.start()
	if started then
		return
	end
	started = true

	Net.get("SandbotOffer").OnClientEvent:Connect(function(passId)
		-- A number or nothing. The server is the only sender and it sends the id
		-- off PassConfig, but a payload this file cannot read is worth dropping in
		-- silence rather than turning into a prompt for pass nil.
		if type(passId) == "number" then
			offer(passId)
		end
	end)

	--------------------------------------------------------------
	-- WHAT MAKES THE PROMPT REPAINT
	--------------------------------------------------------------
	-- 1. The drone went out or came back. DEPLOY and RECALL are the same prompt,
	--    and it is the same edge that empties or restocks a kennel.
	player:GetAttributeChangedSignal(SandbotConfig.OutAttribute):Connect(repaint)

	-- 1b. WHICH kennel. The server writes this in the same breath as the one
	--     above, but the two arrive as separate changes and either may land
	--     first -- so both are wired, and whichever is second holds the whole
	--     answer. The 2 second sweep is the backstop under both.
	player:GetAttributeChangedSignal(SandbotConfig.HomeAttribute):Connect(repaint)

	-- 2. Ownership landed. GamePassService writes this when its web call comes
	--    back, which is well after this file has run.
	local entry = PassConfig.get(SandbotConfig.PassKey)
	if entry then
		player:GetAttributeChangedSignal(entry.attribute):Connect(repaint)
	end

	--[[
		3. The price landed.

		The info folder does not exist during the first second of a session, so
		this waits for it on a thread rather than reading a snapshot. If it never
		arrives the prompt still works; it just keeps saying "Coming soon", which
		is the honest answer for a pass whose price could not be read.
	]]
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild(PassConfig.InfoFolder, 30)
		if folder then
			folder.AttributeChanged:Connect(repaint)
			repaint()
		end
	end)

	-- 4. A dock streamed in. That one is the sweep inside startMotion.
	startMotion()
	repaint()
end

return SandbotClient
