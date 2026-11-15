--[[
	WashServer  --  ServerScriptService.WashServer

	Owns the wash bay, the mounted lump, and every chunk's erosion. Replaces the
	old SiftingServer.

	THE PROTOCOL, AND WHY IT IS TIGHTER THAN THE OLD ONE
	----------------------------------------------------
	The client sends `{chunk = i}` while the trigger is held, roughly 15x a
	second. That is the whole payload. It does not say how hard, how long, or
	how much -- because with a held trigger none of those are the player's to
	decide; they are a function of the pressure tier the server already knows.

	On each packet the server computes:

		dt = clamp(now - session.lastAim, 0, MaxTickDelta)
		erosion = pressure * dt / chunkWork      -- in CHUNKS, and it may exceed 1

	The aimed chunk is spent first and any surplus spills into the nearest crust
	still standing, bounded by the player's WasherSpread. See the long note beside
	the erosion itself for why the old one-chunk clamp made Pressure levels 44-60
	buy literally nothing.

	so the erosion credited over any wall-clock second is `pressure` seconds'
	worth, no matter how many packets arrive in it. Sending at 1000Hz just makes
	each dt a thousandth of a second. There is no quantity to inflate, and the
	MaxTickDelta clamp means a client that goes silent for ten seconds cannot
	come back and bank the gap either.

	What the client DOES get to decide is which chunk -- the aim -- which is
	exactly the skill the mechanic is about.

	AUTO-ADVANCE
	------------
	When a lump finishes and the player is still carrying crusted ones, the next
	is mounted automatically after the reveal beat. Walking back to the prompt
	between every rock would kill the rhythm.

	AUTO-SELL
	---------
	On the same beat, the find that just came out of the crust SELLS ITSELF. It
	is one uid through SellServer.sellItems, never sellAll -- the bag of raked
	litter beside it is untouched and still wants the walk to a pad. See
	sellFinished for the whole argument, including why a paid game pass depends
	on that line being drawn exactly there.

	INSTANT WASH
	------------
	The one game pass this file knows about, and it works on BOTH halves of the
	mechanic:

	  the button   finishes the whole BAG in a tap (onInstantRequest + bulkWash)
	  the jet      every clump comes off the moment the jet touches it (onAim)

	The second one matters more than it looks. A pass that only worked through a
	button would punish the player for using the tool -- pick up the washer you
	paid to make instant and it is slow again -- so the erosion rule itself is
	what changes, and the button is a shortcut past the aiming rather than the
	only way to get what was bought.

	Neither is a separate completion path: both mark chunks spent and go through
	the SAME completeLump every blasted lump goes through.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- For the lazy, optional FunnelServer lookup below.
local ServerScriptService = game:GetService("ServerScriptService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local GameConfig = require(Modules:WaitForChild("GameConfig"))
local PassConfig = require(Modules:WaitForChild("PassConfig"))
local ItemConfig = require(Modules:WaitForChild("ItemConfig"))
local ItemVisuals = require(Modules:WaitForChild("ItemVisuals"))
local InventoryController = require(Modules:WaitForChild("InventoryController"))
local Net = require(Modules:WaitForChild("Net"))

local ValueCalculator = require(script.Parent.ValueCalculator)
--[[
	THE TILL, because a washed find no longer waits in the bag for a walk to a
	sell pad. sellFinished below is the only caller and its note is the argument.

	No cycle: SellServer reaches for GameConfig, ItemConfig, InventoryController,
	Net, PassConfig, ValueCalculator and GamePassService, and not one of them has
	heard of this file. ServerMain requires and starts it well before this bay
	opens, so the WaitForChild is a formality rather than a real wait.
]]
local SellServer = require(script.Parent:WaitForChild("SellServer"))
local WasherTool = require(script.Parent.WasherTool)
local LuckService = require(script.Parent.LuckService)
local GamePassService = require(script.Parent.GamePassService)
--[[
	THE ONBOARDING'S EASIER JET. Pure replicated data with no requires of its
	own, so it costs this file's boot order nothing -- and the CLIENT reads the
	identical number out of the identical module, which is what keeps the jet
	the server erodes with and the jet the player watches in step. The whole
	argument for the boost, and every constant in it, is in that file.
]]
local TutorialConfig = require(Modules:WaitForChild("TutorialConfig"))

local CFG = GameConfig.Washing

-- The pass this bay honours. Declared up here rather than beside
-- onInstantRequest because onAim needs it too -- see the header.
local INSTANT = PassConfig.Passes.InstantWash

-- The bay's own stream, so the luck roll cannot be perturbed by anything else
-- drawing from a shared generator.
local luckRng = Random.new()

local WashServer = {}

local bays = {}       -- [Model] = bay
local sessions = {}   -- [Player] = session

--[[
	THE WASH BAY FUNNEL, resolved LAZILY AND OPTIONALLY -- the same contract
	FunnelConfig keeps with the builders it reads gates from, and for the same
	two reasons: this module must stay requirable at any point in ServerMain's
	order, and a stripped place with no analytics in it must still wash rocks.

	Every call below is a step in FunnelConfig.WashSteps. See that table's header
	for what the four of them are for; the short version is that onboarding step
	4 is this game's measured drop-off and "did not wash" is five different
	failures wearing one number.
]]
local funnelLoaded, FunnelServer = false, nil
local function washFunnel(player: Player, key: string)
	if not funnelLoaded then
		funnelLoaded = true
		local moduleScript = ServerScriptService:FindFirstChild("FunnelServer")
		if moduleScript and moduleScript:IsA("ModuleScript") then
			local ok, result = pcall(require, moduleScript)
			if ok and type(result) == "table" and type(result.wash) == "function" then
				FunnelServer = result
			end
		end
	end
	if FunnelServer then
		-- Guarded: instrumentation must never be able to fail a wash.
		pcall(FunnelServer.wash, player, key)
	end
end
local rateWindow = {} -- [Player] = {start, count}

local bayCounter = 0
local lumpSeed = 0

--[[
	ONE STAND, ANY NUMBER OF WASHERS, AND NOBODY SEES ANYBODY ELSE'S ROCK.

	The bay used to fan lumps out along the stand -- three slots at 0, -4 and
	+4 studs -- so several players could wash shoulder to shoulder. Two things
	were wrong with that, and they pointed the same way:

	  * THE OFFSETS WERE NEVER APPLIED. mount called `spawnLump(bay, rec)` with
	    no slot argument, so `SLOT_OFFSETS[nil]` fell through to its `or 0` and
	    every lump in the bay pivoted to the SAME point. Three players washing
	    meant three rocks interpenetrating on one stand, each coming apart
	    inside the others. That is what a player reports as seeing somebody
	    else's lump on top of their own.
	  * EVEN APPLIED THEY COULD NOT HAVE WORKED. Everything the shot is built
	    out of is positioned from `stand`, dead centre: the camera focus, the
	    silt bed, the debris landing plate and every audio anchor over in
	    WashClientController. A player in slot 2 would have had the camera
	    framing empty air four studs from their own lump.

	So a bay is a PERSONAL STATION now. Every lump mounts at the centre of the
	stand and each client is shown only its own -- see the foreign-lump veil in
	WashClientController, which is the other half of this change. Everyone gets
	the one good shot, the Fx below go to the owner rather than to the whole
	server, and there is no capacity left to run out of: a bay that looks empty
	must never tell a player it is full.
]]

--------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------

local function notify(player: Player, text: string, kind: string?)
	Net.get("Notify"):FireClient(player, { text = text, kind = kind or "info" })
end

local function rootPosition(player: Player): Vector3?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return root and root.Position or nil
end

local function inRange(player: Player, bay): boolean
	local pos = rootPosition(player)
	return pos ~= nil and (pos - bay.stand.Position).Magnitude <= CFG.BayRange
end

--------------------------------------------------------------------------
-- BAY REGISTRATION
--------------------------------------------------------------------------

--[[
	FORWARD-DECLARED, because the prompt closure below is written two hundred
	lines before `bulkWash` -- which is what it needs -- exists. The closure only
	RUNS on a press, long after both are assigned, so the order on the page costs
	nothing; the alternative is hoisting bulkWash and every helper it reads above
	the bay registry, which would move four hundred lines to save this comment.
]]
local tryInstantBag

-- Forward-declared for the same reason tryInstantBag is: the bay's prompts are
-- wired two hundred lines above the inventory helpers they lean on.
local binCrusted

local function registerBay(model: Instance)
	if not model:IsA("Model") or bays[model] then
		return
	end

	--[[
		WORKSPACE ONLY.

		A tagged model in ServerStorage is not a bay, it is a photograph of one --
		and a CollectionService tag survives being cloned into a backup. Exactly
		one tag in this place points outside Workspace and it points at
		Island3_BACKUP_preShrineSell.Market.CoveWashBay, so on every boot this
		function built a Mounted folder and a live ProximityPrompt INSIDE that
		backup, wired the prompt to mount(), and counted a bay no player can reach.

		Guarding here rather than at the call site because the tag can also be
		added later: GetInstanceAddedSignal fires for a clone dropped into
		ServerStorage just as readily as for one parented into the world.
	]]
	if not model:IsDescendantOf(workspace) then
		return
	end

	local stand = model:FindFirstChild("Stand", true)
	if not (stand and stand:IsA("BasePart")) then
		warn("[WashServer] wash bay has no BasePart named 'Stand':", model:GetFullName())
		return
	end

	bayCounter += 1

	local mountFolder = model:FindFirstChild("Mounted")
	if not mountFolder then
		mountFolder = Instance.new("Folder")
		mountFolder.Name = "Mounted"
		mountFolder.Parent = model
	end

	local promptHost = model:FindFirstChild("PromptAnchor", true)
	if not (promptHost and promptHost:IsA("BasePart")) then
		promptHost = stand
	end

	local prompt = promptHost:FindFirstChildWhichIsA("ProximityPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Mount Crusted Find"
		prompt.ObjectText = "Wash Bay"
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 12
		prompt.RequiresLineOfSight = false
		prompt.Parent = promptHost
	end

	--[[
		AND A WAY OUT FOR SOMEBODY WHO DOES NOT WANT TO WASH AT ALL.

		Asked for on 2026-09-15: "a way to trash crusted items (no money gain but
		no sitting through hosing either)". The phrasing is the specification --
		they are not asking to be paid, they are asking to stop being made to
		wait. Instant Wash sells the other answer to the same friction (speed WITH
		the money), so this takes nothing from it: what it hands back is the
		minute, not the coins.

		A SECOND PROMPT RATHER THAN A SECOND TAP ON THE FIRST. A ProximityPrompt
		is one action, and the bay's existing one already means two different
		things depending on whether you own the pass. Hanging a third meaning off
		it would make E unpredictable; a key of its own is always the same key.

		HELD, NOT TAPPED. This throws finds away and there is no undo, so it wants
		the same deliberateness the feedback panel's DELETE gets from its two
		presses. A second of hold is cheaper to explain than a confirmation box
		nobody asked for.

		IT CANNOT TAKE THE ROCK ON THE STAND. That record's state is "Washing"
		rather than "Crusted", so a player mid-wash keeps the lump they are
		looking at -- the same distinction bulkWash relies on.
	]]
	local binPrompt = promptHost:FindFirstChild("BinPrompt")
	if not binPrompt then
		binPrompt = Instance.new("ProximityPrompt")
		binPrompt.Name = "BinPrompt"
		binPrompt.Parent = promptHost
	end

	--[[
		TOLD APART FROM THE MOUNT PROMPT BESIDE IT, WHICH IT WAS NOT.  2026-09-19.

		Reported the day after this shipped, from a 776x384 phone: "the 'bin' and
		'mount' buttons being in the same place are messing me up :(". They were
		right and it was two separate mistakes stacked.

		THE KEYS ONLY EXIST ON A KEYBOARD. E and R make these unmistakable on a
		desktop, and the note above reasons entirely in those terms -- "a key of its
		own is always the same key". On touch there is no key: Roblox draws one
		tappable button per prompt, both hang on the same PromptAnchor, and both sat
		at UIOffset 0,0. Two buttons, one point on the screen.

		AND THE WORDS WERE NEARLY THE SAME STRING. "Mount Crusted Find" against
		"Bin Crusted Finds" -- same length, same shape, same second word, and the
		same "Wash Bay" caption underneath. Even pulled apart they would read as one
		control drawn twice.

		So: the bin prompt moves down out of the mount prompt's place, and says what
		it does in words that share nothing with it. THAT MATTERS MORE HERE THAN ON
		ANY OTHER PROMPT IN THE GAME, because this is the one action in the wash bay
		that destroys something and has no undo -- a mis-tap costs a bagful of finds.
		The one-second hold stays for the same reason.

		WRITTEN EVERY TIME RATHER THAN ONLY ON CREATE. These properties used to sit
		inside the `if not binPrompt` above, so a bay whose prompt already existed --
		every bay on a server that has been up since before this change -- would have
		kept the old text and the old position forever.
	]]
	binPrompt.ActionText = "Throw Away"
	-- Says WHAT it throws away. "No coins, no waiting" described the bargain but
	-- not the subject, and a player holding a bag of litter read it as a bin for
	-- the bag -- pressed it, got told there was nothing crusted, and reported the
	-- button as broken. Three did, on 2026-09-19.
	binPrompt.ObjectText = "Crusted finds only"
	binPrompt.KeyboardKeyCode = Enum.KeyCode.R
	--[[
		A TAP, NOT A HELD PRESS, AND THE DELIBERATENESS MOVED TO binCrusted.

		This was HoldDuration = 1, and on touch that is the one gesture a prompt
		button cannot rely on. Roblox's DynamicThumbstick claims a region that
		measures x -100..266, y 105..416 on a 666x374 phone -- most of the screen
		-- and a press held inside it is a movement drag. The mount prompt beside
		this one is HoldDuration 0 and has never been reported; this one is a hold
		and was reported three times within hours of shipping, twice from phones.

		The hold existed to make a destructive action deliberate, and the note
		below it asked for "the same deliberateness the feedback panel's DELETE
		gets from its two presses". It now HAS that, literally -- binCrusted arms
		on the first press and bins on the second. That is the stated intent, and
		unlike a hold it is a gesture that works the same on every device.
	]]
	binPrompt.HoldDuration = 0
	binPrompt.MaxActivationDistance = 12
	binPrompt.RequiresLineOfSight = false
	--[[
		CLEAR OF THE MOUNT PROMPT'S BUTTON -- AND 56 WAS NOT, WHICH IS WHY THIS
		IS 84.  Measured 2026-09-20, in Play, off the live billboards.

		The note that set 56 got two things wrong, and they cancelled into a
		number that looked reasoned:

		  "two ~40px prompt buttons" -- they are 72px. Roblox builds each prompt
		  as a BillboardGui sized UDim2.new(0, width, 0, 72); the width tracks
		  the text and the HEIGHT IS ALWAYS 72. So a 56px separation left the two
		  buttons overlapping by 16px, across the full 192px width of the narrower
		  one. Better than the 100% overlap that was reported, but still a band
		  where the finger that wanted Mount gets Throw Away.

		  "+96 put this button at y=307 ... buried in the bottom band" -- the sign
		  is backwards. UIOffset is applied as BillboardGui.SizeOffset.Y, at
		  exactly UIOffset.Y/72, and a POSITIVE SizeOffset.Y moves a billboard UP.
		  Measured at the home bay: Throw Away (offset 56) spans y 183..255 and
		  Mount (offset 0) spans y 239..311 -- the bin prompt is ABOVE, not below.
		  96 would have put it nearer the top of the screen, not into the
		  thumbstick. It was replaced for a hazard that was never there.

		84 = the 72px button plus a 12px gap. On a 374-tall phone, with the anchor
		projecting to about y=211, that puts Mount at 175..247 and Throw Away at
		91..163: a real gap, both comfortably on screen, and the destructive one
		furthest from the thumbstick band at the bottom rather than nearest it.

		WHY NOT MORE. Every pixel here is upward drift away from the thing the
		prompt is attached to, and this one already sits a button's height off its
		own anchor. 12px is a gap a finger can feel without the label floating
		free of the bay it belongs to.

		Pixels rather than studs, still: UIOffset moves the prompt's GUI, so the
		gap does not shrink to nothing on the phones that need it most.

		------------------------------------------------------------------
		NEGATIVE NOW, 2026-09-23: THE GAP WAS RIGHT, THE SIDE WAS WRONG.
		------------------------------------------------------------------
		Everything measured above still holds -- 72px buttons, positive is UP, 84
		is one button plus a 12px gap. Only the SIGN changes, and with it which of
		the two a player reads first.

		At +84 the order down the screen was:

		    R  Throw Away        <- destructive, read first
		    E  Mount Crusted Find

		So the loudest control at a station whose entire purpose is washing was the
		one that destroys the thing you came to wash. Five reports say so, across
		both platforms and three versions of this control: Tayah683 and Hestia on
		the overlap, Yipyap0081 three times, and Kitskat95 on 2026-09-23 from a
		DESKTOP -- "the wash bay is saying 'throw away' instead of letting me rinse
		off the crust. Its been doing this for a few days now."

		RULED OUT FIRST, by measurement, so this is not another guess at the same
		control: it is not the touch gate (Kitskat95 reports touch=false, so that
		path never runs for them); it is not prompt suppression (both prompts share
		GamepadKeyCode ButtonX under OnePerButton, which looked like a collision --
		tested in Play, both still draw, before and after changing the button); and
		it is not a disabled prompt (WashServer contains zero .Enabled writes, so
		both are up whenever anybody is in range). What is left is the order.

		AND THE ORIGINAL REASON FOR "UP" HAS EXPIRED. It was the thumbstick: keep
		the destructive button out of the band at the bottom of a phone. Since the
		touch bay key shipped, WashClientController sets THIS PROMPT to Style =
		Custom on every touch device and draws a house button instead -- so on the
		only screens that have a thumbstick, this prompt is not drawn at all. It
		renders on desktop and nowhere else, and a desktop has no thumbstick to
		collide with. The hazard the sign was protecting against no longer exists.
	]]
	binPrompt.UIOffset = Vector2.new(0, -84)

	-- Once per bay. The connect used to sit outside the guard above, so a second
	-- call for the same model would have wired a second handler to a destructive
	-- action and binned twice on one press.
	if not binPrompt:GetAttribute("Wired") then
		binPrompt:SetAttribute("Wired", true)
		binPrompt.Triggered:Connect(function(player)
			binCrusted(player)
		end)
	end

	local bay = {
		model = model,
		stand = stand,
		mountFolder = mountFolder,
		prompt = prompt,
		id = string.format("bay%02d", bayCounter),
		occupants = {},   -- [Player] = true, for the bay-removed sweep below
	}
	bays[model] = bay

	--[[
		THE PASS SKIPS THE SPRAYER, NOT THE WALK.

		Reported 2026-09-16 by a player who owns Instant Wash: "it would be nice
		if i didnt have to enter the wash bay every time. I understand needing to
		walk up to it/be near it, but having to actually interact with it and go
		into the pressure sprayer view is kind of annoying." That sentence draws
		the line for us -- the walk stays, the camera goes -- so this is on the
		prompt rather than on a key somewhere on the HUD.

		It was the loudest of five asks about washing from three players in two
		days, the others being auto-wash (twice) and a way to bin a crusted find
		rather than sit through it.

		SPAWNED, because tryInstantBag asks Roblox about the pass and that is a
		web call. A ProximityPrompt.Triggered handler that yields holds up every
		later press of the same prompt, so one player waiting on a lookup would
		stall the queue behind them at a shared bay.

		FALLS THROUGH ON FALSE, which is every case that is not "an owner with
		something crusted to clean": a non-owner, a failed lookup, an empty bag.
		The bay then opens exactly as it always has, so nothing here can leave a
		player standing at a prompt that did nothing.
	]]
	prompt.Triggered:Connect(function(player)
		task.spawn(function()
			if tryInstantBag(player) then
				return
			end
			WashServer.mount(player, bay)
		end)
	end)

	model.AncestryChanged:Connect(function(_, parent)
		if not parent then
			-- Collected first: endSession deletes from bay.occupants as it runs,
			-- and mutating a table mid-iteration is undefined.
			local leaving = {}
			for occupant in pairs(bay.occupants) do
				table.insert(leaving, occupant)
			end
			for _, occupant in ipairs(leaving) do
				WashServer.endSession(occupant, "bay-removed")
			end
			bays[model] = nil
		end
	end)
end

-- Look up the registered bay for a tagged Model. Exposed because `bays` is
-- otherwise unreachable from outside, which left mount() callable only from
-- the ProximityPrompt closure -- no dev tooling, no headless test, no way to
-- open a bay from a cutscene or a tutorial step.
function WashServer.bayFromModel(model: Model)
	return bays[model]
end

--[[
	IS THIS PLAYER STANDING AT A BAY WITH THE HOSE OUT, right now.

	Exposed for the same reason bayFromModel above is: `sessions` is otherwise
	unreachable, and "are they still washing" is a question two features outside
	this file legitimately need to ask -- it is the difference between a player
	who has finished the job and one who is halfway through it.

	FunnelServer is the current caller, and it needs THIS answer rather than an
	approximation of it: TutorialHud ends its WASH step on "the bag is clean, or
	they washed something and walked off", and it reads the walking-off half from
	its own PlayerGui. A server-side funnel with no equivalent would have to
	settle for "washed one lump", which credits the step some seconds early and
	under-reports the drop-off at the bay -- the one number that step exists to
	measure.

	A READ, and deliberately not a handle: it answers true or false rather than
	handing back the session table, so nothing outside this file can reach into a
	live wash and change it.
]]
function WashServer.isWashing(player: Player): boolean
	return sessions[player] ~= nil
end

--------------------------------------------------------------------------
-- MOUNT / UNMOUNT
--------------------------------------------------------------------------

local function spawnLump(bay, rec, player: Player): Model
	lumpSeed += 1
	local model = ItemVisuals.buildEncased(rec.itemId, lumpSeed)
	model:SetAttribute("WashUid", rec.uid)
	-- The itemId attribute would hand the client the answer for free.
	model:SetAttribute("ItemId", nil)
	-- ...AND SO DOES THE NAME. buildEncased calls it "Lump_GoldWatch", which
	-- replicates like everything else, so anyone who opened the explorer -- or
	-- read it off the Mounted folder from a local script -- knew what was inside
	-- before a single clump came off. SiftServer closed this and the line was
	-- lost in the port to the wash bay, along with setWetness and the rest.
	model.Name = "Lump"
	-- WHOSE ROCK THIS IS. Stamped BEFORE the model is parented, so it arrives
	-- on the client as part of the instance rather than as a property change a
	-- moment later: WashClientController veils every mounted lump that is not
	-- the local player's, and one that landed without this attribute would be
	-- visible for the frame or two before the veil caught up with it.
	model:SetAttribute("WashOwner", player.UserId)
	model.Parent = bay.mountFolder
	-- Centred on the stand for everybody. The camera, the silt bed and the
	-- debris landing plate are all built from `stand` itself, so this is the
	-- one position in the bay that every other part of the mechanic agrees on.
	model:PivotTo(bay.stand.CFrame * CFrame.new(0, bay.stand.Size.Y * 0.5 + 1.9, 0))
	return model
end

-- Returns TRUE only if a lump is now on the stand.
--
-- It used to return nothing, and every one of the bail-outs below looked
-- identical to success from the outside. That is fine for a player walking up
-- and pressing E -- they get a notify and nothing happens -- but completeLump
-- calls this to auto-advance AFTER it has already despawned the finished rock,
-- and a silent bail there leaves a live session with no model: camera locked,
-- empty stand, nothing to wash, and Q the only way out.
function WashServer.mount(player: Player, bay): boolean
	local inv = InventoryController.Server.get(player)

	local existing = sessions[player]
	if existing and existing.bay ~= bay then
		WashServer.endSession(player, "moved-bay")
		existing = nil
	end
	if existing and existing.uid then
		notify(player, "Finish the one on the stand first.", "warn")
		return false
	end

	local crusted = inv:GetByState("Crusted")
	if #crusted == 0 then
		notify(player, "Nothing crusted to wash. Go find some!", "info")
		return false
	end

	local rec = crusted[1]

	--[[
		LUCK, AND THE ONE PLACE IT IS SPENT.

		Equipped pets get a chance to step this lump's contents up its pool's
		encased ladder -- a Driftwood becomes a Coin becomes a Watch. It happens
		here, at MOUNT, and not at the reveal, for two reasons:

		  * The crust is built from the item id (spawnLump -> buildEncased), and
		    so are the chunk count and the toughness. Swapping the id at
		    completion would announce a Gold Watch while the model that just came
		    apart was a Driftwood.
		  * `luckRolled` makes it once per lump, ever. A lump can be un-mounted
		    and re-mounted (endSession puts it back Crusted with its chunks), and
		    without this flag a player could mount-cancel-mount to reroll their
		    luck until it paid out.

		Nothing on the client contradicts it: publicView strips itemId and rarity
		from a crusted record, so the player has never been told what they picked
		up. Both fields are server-only for the same reason washChunks is.
	]]
	if not rec.luckRolled then
		rec.luckRolled = true
		local upgraded, steps = LuckService.upgradeItem(player, rec.itemId, luckRng)
		if steps > 0 then
			rec.itemId = upgraded
			rec.luckSteps = steps
		end
	end

	inv:SetState(rec.uid, "Washing")
	rec.stationId = bay.id

	local session = existing
	if not session then
		session = { player = player, bay = bay, lastAim = 0, lastPacket = 0, lastPush = 0 }
		sessions[player] = session
		bay.occupants[player] = true
		-- STEP 2. Only on a NEW session: remounting the rock you walked away from
		-- is the same lump, and `existing` is how this function already tells the
		-- two apart.
		washFunnel(player, "Mounted")
	end

	-- RESTORE THE SHELL THEY LEFT.
	--
	-- endSession's comment has always said "walking away costs the condition
	-- bonus, not the work" -- but mount built a brand new 14-chunk crust every
	-- time, so the work was exactly what it cost. The bag chip went on showing
	-- the old percentage (rec.progress is written separately), which made it look
	-- like the number was lying rather than the rock.
	--
	-- rec.washChunks is server-side only: publicView does not copy it, so it
	-- never reaches a client and cannot leak the shape of the lump.
	local total = ItemConfig.chunkCount(rec.itemId)
	local chunks = table.create(total, 0)
	local saved = rec.washChunks
	if type(saved) == "table" and #saved == total then
		for i = 1, total do
			local v = saved[i]
			chunks[i] = (type(v) == "number") and math.clamp(v, 0, 1) or 0
		end
	end

	session.uid = rec.uid
	session.model = spawnLump(bay, rec, player)
	session.total = total
	session.chunks = chunks
	session.chunkWork = ItemConfig.chunkWorkFor(rec.itemId, CFG.ChunkWork)
	session.lastAim = os.clock()

	-- Take back off whatever was already gone. Done AFTER spawnLump, because the
	-- shell is built whole and then pruned -- there is no "build 9 of 14" path,
	-- and adding one would put the surviving chunks in different places than the
	-- player left them.
	local remaining = total
	for i = 1, total do
		if chunks[i] >= 1 then
			local chunk = ItemVisuals.findChunk(session.model, i)
			if chunk then
				chunk:Destroy()
			end
			remaining -= 1
		end
	end
	-- A fully-stripped lump is flipped to Cleaned the instant its last chunk
	-- goes, so it can never come back here as Crusted. If a bad save ever says
	-- otherwise, start it over rather than mounting a rock with nothing to wash.
	if remaining <= 0 then
		session.model:Destroy()
		session.chunks = table.create(total, 0)
		session.model = spawnLump(bay, rec, player)
		remaining = total
	end
	session.remaining = remaining
	if remaining < total then
		ItemVisuals.setUncovered(session.model, 1 - remaining / total)
	end

	-- Lend them the washer for the length of the session. Done BEFORE the
	-- WashBegin message so the tool is already on its way to the client when
	-- that arrives -- the client waits for it either way, but this is one less
	-- frame of an empty hand.
	WasherTool.equip(player)

	Net.get("WashBegin"):FireClient(player, {
		bayId = bay.id,
		bay = bay.model,
		stand = bay.stand,
		model = session.model,
		uid = rec.uid,
		chunkTotal = session.total,
		-- The resumed shell, so a re-mounted lump opens at the percentage it was
		-- left at instead of flashing 0% until the first WashProgress push lands
		-- a tenth of a second later. It is the player's own progress on their own
		-- find -- the mystery is WHAT is inside, and none of that is in here.
		chunks = session.chunks,
		remaining = session.remaining,
		-- NOT sent: itemId, rarity, value. The player is washing a mystery.
	})
	-- THE OWNER, NOT THE SERVER. Every one of this file's Fx sends used to be a
	-- FireAllClients so that passers-by got the knock, the grit and the sparkle
	-- off somebody else's rock. Now that a mounted lump is drawn for its owner
	-- alone, those all landed on a rock the bystander cannot see -- a pop and a
	-- puff of grit hanging in an empty bay.
	Net.get("Fx"):FireClient(player, { kind = "Mount", part = session.model and session.model.PrimaryPart or bay.stand })
	return true
end

local function despawn(session)
	if session.model then
		session.model:Destroy()
		session.model = nil
	end
end

function WashServer.endSession(player: Player, reason: string?)
	local session = sessions[player]
	if not session then
		return
	end
	sessions[player] = nil
	session.bay.occupants[player] = nil

	local inv = InventoryController.Server.find(player)
	if inv and session.uid then
		local rec = inv:Get(session.uid)
		if rec and rec.state == "Washing" then
			-- Back in the bag, keeping the crust it has already lost. Walking
			-- away costs the condition bonus, not the work -- and this line is
			-- what makes that true; mount() reads it back.
			rec.washChunks = session.chunks
			inv:SetState(session.uid, "Crusted")
			rec.stationId = nil
			rec.interrupted = true
		end
	end

	despawn(session)
	WasherTool.stow(player)   -- washer goes back on the hook with the session
	Net.get("WashEnd"):FireClient(player, { reason = reason or "done" })
end

--------------------------------------------------------------------------
-- COMPLETION
--------------------------------------------------------------------------

--[[
	AUTO-SELL: THE FIND THAT JUST CAME OUT OF THE CRUST, AND NOTHING ELSE.

	Washing used to end with the find sitting in the bag as a Cleaned record,
	waiting on a walk to a sell pad. It sells itself now, on the beat the reveal
	lands.

	IT IS THE WASHED FINDS AND NEVER sellAll, AND THAT IS THE LOAD-BEARING LINE.
	One uid when a lump was blasted by hand; the whole bag's worth of FINDS when
	the Instant Wash button finished them all in a tap. Litter, never. A bag is mostly
	raked litter, and emptying it as a side effect of washing a rock would do two
	things nobody asked for: it would take the bring-a-full-bag-in decision the
	batch bonus is built around away from the player, and it would make the QUICK
	SELL GAME PASS -- "empty the whole bag from anywhere" -- worthless to anybody
	who ever washes anything. SellServer.sellItems exists for exactly this
	distinction and argues it at length in its own header.

	NOT CONDITIONAL ON THE SESSION STILL BEING OPEN, which is why the caller runs
	it before its own guard. By the time this fires the record is already Cleaned,
	already valued and already theirs; stepping off the stand during the reveal
	beat is not a reason to be handed an unsold rock instead of the money.

	`anchor` IS THE ONLY THING THEIR POSITION CHANGES: the stand if they are still
	at it, their own root part if they walked, because a coin shower nobody can
	see reads as a sale that did not happen. Same call CTB_Server's QuickSell
	branch makes, for the same reason it makes it.

	NO RECEIPT SLIP (`receipt = false`). The reveal card is already on screen
	naming this item and this figure, and FeedbackClient parks the slip where it
	would land on top of it. The banner, the till bell and the coin shower all
	still play, so the sale is not silent -- it is just not said twice.
]]
local function sellFinished(player: Player, uids: { string }, anchor: BasePart?)
	if not (player.Parent and #uids > 0) then
		return
	end
	SellServer.sellItems(player, uids, anchor and { anchor = anchor } or nil,
		{ receipt = false })
end

local function completeLump(session)
	local player = session.player

	-- STEP 4. A lump that reaches this line is finished -- the same thing the
	-- wash-boost credit below keys off, and for the same reason.
	washFunnel(player, "Finished")

	--[[
		SPENT PER LUMP, AND HERE RATHER THAN AT THE MOUNT.

		Charging it at mount would eat a credit for a rock the player walked
		away from half-washed, which is the exact moment the tutorial is least
		able to afford to get harder. A lump that reaches this line is finished.
	]]
	local easyLeft = TutorialConfig.washBoostOf(player)
	if easyLeft > 0 then
		player:SetAttribute(TutorialConfig.WashBoostAttribute, easyLeft - 1)
	end
	--[[
		THE BAG-WIDE BATCH COMES OFF THE SESSION HERE, ABOVE EVERY BAIL-OUT BELOW.

		onInstantRequest parks the uids of the finds it washed with no model on
		session.bulkUids. They are already Cleaned and already valued -- real
		money the player has earned -- so a `return` below that left them sitting
		on a session table nobody reads again would strand a whole bag's worth of
		it unsold. Taken now, sold on whichever path this function leaves by.
	]]
	local bulkUids = session.bulkUids or {}
	session.bulkUids = nil

	local inv = InventoryController.Server.find(player)
	if not inv then
		return
	end
	local rec = inv:Get(session.uid)
	if not rec then
		-- The rock on the stand is not in the bag any more, so there is no reveal
		-- to play and nothing to add to the batch. The batch is still owed.
		sellFinished(player, bulkUids, session.bay.stand)
		return
	end
	local def = ItemConfig.expect(rec.itemId)

	inv:SetProgress(rec.uid, 1)
	rec.washChunks = nil   -- nothing left to resume; do not carry it into the sale
	local value = ValueCalculator.roll(rec.itemId, {
		uninterrupted = not rec.interrupted,
		stalled = false,
		player = player,
	})
	inv:SetValue(rec.uid, value)
	-- Flipping to Cleaned is what un-hides the identity in publicView. Until
	-- this line the client has never been told what it was washing.
	inv:SetState(rec.uid, "Cleaned")

	local model = session.model
	if model then
		-- setUncovered, not setWetness: the function was renamed with the sift
		-- pass and this call site was left behind. It threw "attempt to call a
		-- nil value" HERE, before the reveal was ever sent -- so a lump that was
		-- fully washed simply sat on the stand and the session never advanced.
		ItemVisuals.setUncovered(model, 1)
	end

	Net.get("WashItemCleaned"):FireClient(player, {
		uid = rec.uid,
		itemId = rec.itemId,
		displayName = def.DisplayName,
		description = def.Description,
		rarity = def.Rarity,
		value = value,
		model = model,
		-- How many rungs the player's pets moved this one up, or nil. Purely so
		-- a reveal can say so; every consumer ignores fields it does not know.
		luckSteps = rec.luckSteps,
	})
	Net.get("Fx"):FireClient(player, {
		kind = "Sparkle",
		part = model and model.PrimaryPart or session.bay.stand,
		rarity = def.Rarity,
	})

	local finishedUid = session.uid
	session.uid = nil

	-- `.hold`, not `.RevealHoldBonus`: the tier tables in ItemConfig call the
	-- field `hold`, so this read nil and the addition threw -- taking the
	-- despawn/auto-advance delay with it.
	local hold = CFG.RevealHoldTime + (ItemConfig.rarityInfo(def.Rarity).hold or 0)
	task.delay(hold, function()
		-- SOLD FIRST, and deliberately ABOVE the session guard -- see sellFinished.
		-- Whether they are still stood at the bay decides where the coins burst,
		-- not whether they are paid.
		local atBay = sessions[player] == session
		local char = player.Character

		--[[
			THE ROCK ON THE STAND, PLUS WHATEVER THE INSTANT WASH BUTTON DID TO
			THE REST OF THE BAG.

			ONE list into ONE payOut, and that is not tidiness. The batch bonus is
			`min(#items * BatchBonusPerItem, MaxBatchBonus)` -- 2% an item to a 50%
			ceiling -- so twelve finds put through as twelve sales of one are paid
			2% each, and the same twelve as one batch are paid 24%. They were
			washed in one gesture, so they are one batch. It is also one coin
			shower and one banner rather than twelve of each.

			A LOCAL, NOT session.bulkUids. This delay outlives the session by
			design, and reading the list off the table here would hand it to payOut
			a second time for whatever lump this player mounts next. It was taken
			off the session at the top of completeLump and this closure holds the
			only reference left.
		]]
		local uids = {}
		if finishedUid then
			table.insert(uids, finishedUid)
		end
		for _, uid in ipairs(bulkUids) do
			table.insert(uids, uid)
		end

		sellFinished(player, uids,
			atBay and (session.model and session.model.PrimaryPart or session.bay.stand)
				or (char and char:FindFirstChild("HumanoidRootPart")))

		if not atBay then
			return
		end
		despawn(session)

		-- Auto-advance: mounting the next lump keeps the rhythm going instead
		-- of sending the player back to the prompt after every rock.
		--
		-- The mount is part of the CONDITION, not a statement after it. Written
		-- as a bare call it could fail its own internal checks and fall through
		-- to nothing, and by then the finished rock is already despawned -- so
		-- the player kept the camera and the HUD but had an empty stand in front
		-- of them. Whatever the reason, if there is no new lump the session ends
		-- cleanly instead of stranding them in it.
		local live = InventoryController.Server.find(player)
		local advanced = live ~= nil
			and #live:GetByState("Crusted") > 0
			and inRange(player, session.bay)
			and WashServer.mount(player, session.bay)
		if not advanced then
			WashServer.endSession(player, "stand-clear")
		end
	end)

	return finishedUid
end

--------------------------------------------------------------------------
-- AIM PACKET
--------------------------------------------------------------------------

local function passesRateLimit(player: Player, now: number): boolean
	local w = rateWindow[player]
	if not w or now - w.start >= 1 then
		rateWindow[player] = { start = now, count = 1 }
		return true
	end
	w.count += 1
	return w.count <= CFG.MaxPacketsPerSecond
end

--[[
	THE NEAREST CLUMP STILL STANDING, for the tutorial's forgiving aim.

	BY POSITION WHERE IT CAN, BY INDEX WHERE IT CANNOT. The aimed chunk has
	usually just been destroyed -- that is why we are here -- so findChunk on it
	answers nil and there is no origin to measure from. Index distance is a fair
	stand-in: ItemVisuals lays the shell out in index order, so neighbouring
	numbers are neighbouring clumps, and the redirect only has to be CLOSE
	rather than optimal. Falling back rather than bailing out matters: bailing
	out is precisely the do-nothing packet this exists to remove.
]]
local function nearestLive(session, from: number): number?
	local aim = ItemVisuals.findChunk(session.model, from)
	local origin = aim and aim.Position
	local best, bestD = nil, nil
	for i = 1, session.total do
		if session.chunks[i] < 1 then
			local d = math.abs(i - from)
			if origin then
				local part = ItemVisuals.findChunk(session.model, i)
				if part then
					d = (part.Position - origin).Magnitude
				end
			end
			if not bestD or d < bestD then
				best, bestD = i, d
			end
		end
	end
	return best
end

local function onAim(player: Player, payload)
	local session = sessions[player]
	if not (session and session.uid and session.model) then
		return
	end
	if type(payload) ~= "table" then
		return
	end

	local index = payload.chunk
	if type(index) ~= "number" or index ~= index or index % 1 ~= 0 then
		return
	end
	if index < 1 or index > session.total then
		return
	end

	local now = os.clock()
	if now - session.lastPacket < CFG.MinPacketInterval then
		return
	end
	if not passesRateLimit(player, now) then
		return
	end
	session.lastPacket = now

	if not inRange(player, session.bay) then
		WashServer.endSession(player, "out-of-range")
		return
	end

	-- The only quantity in the whole exchange, and the server owns both terms.
	local dt = math.clamp(now - session.lastAim, 0, CFG.MaxTickDelta)
	session.lastAim = now
	if dt <= 0 then
		return
	end

	--[[
		IS THIS ONE OF THE TUTORIAL'S EASY LUMPS. Asked once, used three times
		below -- the redirect here, and the budget and the reach further down.
	]]
	local easy = TutorialConfig.washIsEasy(player)

	local before = session.chunks[index]
	if before >= 1 then
		if not easy then
			return -- already gone
		end
		--[[
			TUTORIAL ONLY: A PACKET AIMED AT A HOLE IS THE DROP-OFF.

			At the first washer tier WasherSpread is 1, so one packet may clear
			one clump and no more -- and a packet aimed at a clump that has
			already gone returns above having done nothing at all. A player who
			has not yet learned to sweep the reticle spends most of a first wash
			that way, which reads as a jet that has stopped working rather than
			as an aim that has drifted. It is the likeliest reason the measured
			drop-off is AT the bay rather than on the walk to it.

			So during the tutorial the jet finds the nearest crust still
			standing instead of throwing the packet away. It is deliberately not
			how the real mechanic works -- aim is the skill the wash bay is
			teaching -- which is why it is spent, four lumps and gone.
		]]
		local swap = nearestLive(session, index)
		if not swap then
			return
		end
		index = swap
		before = session.chunks[index]
	end

	--[[
		INSTANT WASH DOES NOT MAKE THE JET STRONGER. IT MAKES IT FINAL.

		Written as `after = 1` rather than as a huge pressure multiplier, and the
		difference is not cosmetic. Pressure is a NUMBER that flows into the
		tool's name, the audio pitch, the client's prediction and the shop's
		stat line; a pass that set it to ten thousand would have to be undone in
		five places and would print "10000.0 psi" in the one that got missed.
		This touches the erosion rule and nothing else -- WasherPressure stays
		the number the player actually bought.

		ONE PACKET, ONE CLUMP for the PASS, and that is the real speed limit on it.
		The client sends a chunk index about 30 times a second for a pass holder
		(see the send block in WashClientController), so a 22-piece lump melts in
		well under a second of holding the trigger -- fast enough to read as
		instant, and still the player sweeping the jet across the rock rather than
		a cutscene. MaxPacketsPerSecond is what actually caps it and it is not
		raised here: a client that floods this remote gets its extra packets
		dropped exactly as it always did.

		The lookup is a table index, not a web call -- ownsFlat only asks Roblox
		when told to refresh, and it is deliberately NOT told to here. This runs
		up to forty times a second per washer. A pass bought mid-session starts
		working the moment GamePassService writes its record, which is the same
		instant the HUD button turns gold.
	]]
	--[[
		THE JET'S SURPLUS SPILLS NOW, AND THAT IS WHAT MAKES PRESSURE WORTH BUYING
		PAST ABOUT LEVEL 43.

		This used to be `math.min(1, before + pressure * dt / chunkWork)`, and the
		clamp threw away everything past the aimed chunk. One packet could finish at
		most one clump, so once a packet carried a whole chunk's work the jet
		stopped getting faster: the client sends about 15 packets a second, and
		22 chunks / 15 is a hard floor of 1.47 s a lump NO MATTER THE PRESSURE.

		Measured, a packet carries `pressure * (1/15) / chunkWork` chunks of work,
		and at the beach's spawn-weighted chunkWork of ~2.49 that reaches 1.0 at
		about 37 psi -- Pressure level 43. Levels 44 to 60 changed nothing at all
		while still costing a third of every ladder rebuild, which is the same
		defect the removed TideLuck track was: an upgrade that visibly does nothing.

		Spilling the surplus into the nearest crust still standing makes the whole
		curve a clean reciprocal again -- a lump is chunks * chunkWork / pressure,
		so every level buys the same fraction of a wash from 6 psi to 80.5.

		WASHERSPREAD IS THE REACH LIMIT, AND THIS IS ITS FIRST CONSUMER. It was
		written by ProgressionServer off the same track and read by nothing but
		SiftClientController -- the sifting screen, which ServerMain does not start.
		It is the right number for the job and it was already tuned for it:
		GameConfig.Washer.Levels runs spread 1.0 -> 2.2 across its twelve tiers, and
		a packet at each tier's pressure carries 0.16 -> 2.16 chunks of work. The
		two curves track each other, so the reach never binds before the pressure
		does -- EXCEPT on a lag spike, where dt is clamped to MaxTickDelta (0.12 s)
		rather than the usual 1/15 and the budget is nearly double. There the reach
		stops one recovered packet stripping half a lump, which is exactly the rail
		MaxTickDelta was providing on its own before.

		The aimed chunk is ALWAYS spent first and the spill is ordered by distance
		from it, so the shell still comes apart under the reticle rather than at
		random. Nothing here touches what the client may decide: it still sends one
		chunk index, and the server still owns dt, the pressure and the ordering.
	]]
	local cleared = {}
	if GamePassService.ownsFlat(player, INSTANT.key) then
		session.chunks[index] = 1
		table.insert(cleared, index)
	else
		local pressure = WasherTool.pressureFor(player)
		local budget = pressure * dt / session.chunkWork
		local reach = tonumber(player:GetAttribute("WasherSpread")) or 1
		reach = math.clamp(reach, 1, session.total)

		--[[
			AND THE TUTORIAL'S OWN JET, WHICH IS A MULTIPLIER ON THE BUDGET AND
			A FLOOR UNDER THE REACH -- never a write to WasherPressure.

			Same rule the Instant Wash pass follows a few lines up and for the
			same reason: pressure is a NUMBER that flows into the tool's name,
			the audio pitch, the client's prediction and the shop's stat line,
			so a boost that moved it would have to be undone in five places and
			would print a psi the player never bought. This touches the erosion
			rule and nothing else.

			The reach floor is the half that does the work: a budget of three
			clumps with a reach of one still only clears one. Together they take
			a well-aimed first lump from about two and a half seconds to under
			one, and a badly aimed one from most of a minute to about the same.
		]]
		if easy then
			budget *= TutorialConfig.WashBoostPressure
			reach = math.clamp(math.max(reach, TutorialConfig.WashBoostReach),
				1, session.total)
		end

		-- The aimed chunk first, then the nearest crust still standing. The list is
		-- only built when there is actually surplus to spend, so the ordinary
		-- low-pressure case stays the single table write it always was.
		local order = { index }
		if budget > (1 - before) and reach > 1 then
			local aim = ItemVisuals.findChunk(session.model, index)
			local origin = aim and aim.Position
			local near = {}
			for i = 1, session.total do
				if i ~= index and session.chunks[i] < 1 then
					local part = origin and ItemVisuals.findChunk(session.model, i)
					table.insert(near, {
						i = i,
						d = (part and origin) and (part.Position - origin).Magnitude or math.huge,
					})
				end
			end
			table.sort(near, function(a, b) return a.d < b.d end)
			for _, e in ipairs(near) do
				table.insert(order, e.i)
			end
		end

		local touched = 0
		for _, i in ipairs(order) do
			if budget <= 0 or touched >= reach then
				break
			end
			local cur = session.chunks[i]
			if cur < 1 then
				local give = math.min(budget, 1 - cur)
				local landed = cur + give
				session.chunks[i] = landed
				budget -= give
				touched += 1
				if landed >= 1 then
					table.insert(cleared, i)
				end
			end
		end
	end

	if #cleared > 0 then
		for _, i in ipairs(cleared) do
			local chunk = ItemVisuals.findChunk(session.model, i)
			if chunk then
				-- Destroying it server-side replicates, so bystanders watch the
				-- rock come apart too. The flying flake is the client's business.
				chunk:Destroy()
			end
			session.remaining -= 1
			-- STEP 3. The first chunk off the rock, which is the proof the jet
			-- actually reached it -- see WashSteps on why this is not the trigger
			-- pull. Deduped inside FunnelServer.wash, so firing it per chunk costs
			-- one table lookup after the first.
			washFunnel(player, "Scrubbed")

			Net.get("WashChunkGone"):FireClient(player, { chunk = i })
			Net.get("Fx"):FireClient(player, {
				kind = "ChunkGone",
				part = session.model and session.model.PrimaryPart or session.bay.stand,
				chunk = i,
			})
		end

		-- Progress and the uncover blend are a FUNCTION of session.remaining rather
		-- than an increment, so they are written once after the whole packet has
		-- landed instead of once per chunk. Two chunks in one packet used to be
		-- impossible; at high pressure it is now the normal case.
		local inv = InventoryController.Server.find(player)
		if inv then
			inv:SetProgress(session.uid, 1 - session.remaining / session.total)
		end
		if session.model then
			ItemVisuals.setUncovered(session.model, 1 - session.remaining / session.total)
		end

		if session.remaining <= 0 then
			completeLump(session)
		end
	end
end

--------------------------------------------------------------------------
-- INSTANT WASH  --  the game pass
--------------------------------------------------------------------------

--[[
	THE PASS DOES THE WORK THE JET WOULD HAVE DONE, AND NOTHING ELSE -- ONLY NOW
	ACROSS THE WHOLE BAG RATHER THAN THE ONE ROCK ON THE STAND.

	Every remaining chunk is marked spent and destroyed, and then the lump goes
	through the SAME completeLump a blasted one goes through. That is the
	load-bearing decision in this block: the reveal, the value roll, the
	uninterrupted bonus, the luck steps, the inventory flip and the auto-advance
	to the next rock are all one code path. A second definition of "this lump is
	finished" is how a paying player ends up with a subtly different item than
	the one they would have washed by hand.

	WHAT IT DELIBERATELY DOES NOT DO. It does not skip the mount, so luck is
	still rolled once per lump at the stand and a pass cannot be used to reroll
	it. It does not touch value: an instant wash is worth exactly what the same
	lump was worth a second earlier. What the player bought is the minute, not
	the money.

	OWNERSHIP IS ASKED OF ROBLOX, NEVER OF THE CLIENT. PassConfig's
	OwnsInstantWash attribute exists so the HUD can decide whether to draw BUY
	or USE. It replicates downward and a client cannot write it, but it is still
	a statement on a Player instance and nothing here reads it --
	GamePassService.ownsFlat answers off its own record, and re-asks Roblox when
	that record has no entry (see the note there: a dropped web call during a
	join must not revoke a pass for the session).

	THE PAYLOAD IS EMPTY, and that is the security. There is no chunk list to
	forge and no count to inflate: the server already knows which lump is on the
	stand and how much of it is left. The only thing a client can do by sending
	this is ask.

	IT IS STILL WORTH HAVING NOW THAT THE JET IS INSTANT TOO. Washing by hand
	still costs the player the aiming -- sweeping the reticle over twenty-two
	clumps takes a second or two of attention -- and this is the button that
	skips that.

	AND IT IS NOT ONE ROCK ANY MORE. "Somebody clearing a bag of thirty lumps
	wants it" is what this note used to say, and they did: they pressed it thirty
	times, and sat through a reveal hold (0.6s plus up to 0.75s of rarity beat)
	and a fresh mount between every press. The tap is the whole bag now -- the
	rock on the stand through the usual door, and every other crusted find
	through bulkWash below.
]]
-- Long enough that a held button or a scripted flood cannot turn this into a
-- stream of UserOwnsGamePassAsync calls -- ownsFlat YIELDS on the refresh path
-- -- and short enough to be invisible to somebody clearing a bag one tap at a
-- time. The reveal hold alone is longer than this.
local INSTANT_COOLDOWN = 0.75

--[[
	AND THE REST OF THE BAG, WHICH IS MOST OF WHAT THE BUTTON IS NOW.

	These records have no model, no stand and no session -- there is nothing to
	take a crust off. So the question this function has to answer is not "how do
	I wash it" but "what does mount() do to a lump on its way to being finished
	that a lump finished in the bag must have done to it too". Three things:

	  * THE LUCK ROLL. mount() spends it once per lump EVER, guarded by
	    rec.luckRolled -- a lump can be mounted and abandoned, and the flag is
	    what stops mount-cancel-mount being a reroll. A find that goes straight
	    from the bag to Cleaned has never had its roll, and a pass that quietly
	    cancelled the player's pets would be a downgrade sold as a convenience.
	    Same call, same rng, same flag, so it still cannot be rerolled.
	  * THE VALUE ROLL, off the same context completeLump builds. `uninterrupted`
	    stays honest either way: a lump they walked out on half-washed still
	    carries rec.interrupted and still loses the bonus.
	  * washChunks AND stationId CLEARED. A part-washed lump carries a saved
	    shell for mount() to rebuild from; leaving that on a Cleaned record is a
	    stale resume lying in wait for a state name to drift back over it.

	WHAT IT DELIBERATELY DOES NOT DO, and each of these is a bug if you add it:

	  * NO WashItemCleaned PER FIND. RevealPopup QUEUES its cards and holds each
	    one for 3 seconds plus the rarity's own beat -- twelve finds is over
	    forty seconds of cards, in front of a player who pressed a button whose
	    entire promise is not waiting. The rock on the stand gets the reveal
	    because it is the one that visibly came apart; the rest get counted, and
	    the sale names the money.
	  * NO SALE OF ITS OWN. The uids go back to the caller and ride the mounted
	    lump's sale -- one batch, one bonus, one coin shower. See completeLump.
	  * NO TUTORIAL WASH CREDIT SPENT. completeLump burns one of
	    TutorialConfig's easier-jet credits per lump; burning twelve on one tap
	    would strip the onboarding boost from a player who never used it. Nobody
	    in the tutorial owns this pass, so this is a rail rather than a
	    behaviour -- but it is the rail that keeps it that way.
	  * NOTHING PASSES THROUGH "Washing". These go Crusted -> Cleaned in one step
	    and never take a stationId, so no bay and no other player's session can
	    see them mid-flight.

	ONLY "Crusted", AND THAT IS THE WHOLE ENTITLEMENT CHECK. It is this player's
	own inventory object, and the one record that is deliberately NOT in that set
	is the one on the stand -- its state is "Washing" -- so the skipUid guard
	below is a belt on top of a brace rather than the brace itself.
]]
local function bulkWash(player: Player, inv, skipUid: string?)
	local uids, best, lifted = {}, nil, 0

	-- GetByState builds a FRESH array, so flipping state inside this loop is not
	-- mutating the thing being iterated.
	for _, rec in ipairs(inv:GetByState("Crusted")) do
		if rec.uid == skipUid then
			continue
		end

		if not rec.luckRolled then
			rec.luckRolled = true
			local upgraded, steps = LuckService.upgradeItem(player, rec.itemId, luckRng)
			if steps > 0 then
				rec.itemId = upgraded
				rec.luckSteps = steps
			end
		end

		--[[
			AN ID NOTHING CAN NAME IS LEFT CRUSTED, AND THAT IS CONTAINMENT RATHER
			THAN TIDINESS.

			payOut builds its receipt with ItemConfig.expect, which ASSERTS -- and
			it does so BEFORE RemoveWhere and before the coins are added. With one
			uid in the call that throw cost the player one find. With the whole bag
			in it, a single unknown id would take the entire sale down: no coins,
			nothing removed, and only a line in the log to say why.

			So the id is resolved HERE, where the blast radius is one record.
			Anything ItemConfig cannot name never enters the uid list and stays
			Crusted, still washable by hand. It should never happen -- every id in
			a bag came from rollItemId or a luck ladder -- which is exactly why it
			must not be able to empty somebody's bag for nothing on the day it does.
		]]
		local def = ItemConfig.get(rec.itemId)
		if not def then
			warn("[WashServer] bulk wash skipped an unnameable itemId:", rec.itemId)
			continue
		end

		rec.washChunks = nil
		rec.stationId = nil

		local value = ValueCalculator.roll(rec.itemId, {
			uninterrupted = not rec.interrupted,
			stalled = false,
			player = player,
		})
		inv:SetProgress(rec.uid, 1)
		inv:SetValue(rec.uid, value)
		inv:SetState(rec.uid, "Cleaned")

		table.insert(uids, rec.uid)
		-- COUNTED SO THE TOAST CAN SAY SO. These finds get no reveal card, so
		-- without this the player's pets quietly step eleven items up a ladder
		-- and nothing anywhere mentions it -- which reads exactly like the paid
		-- system having been skipped by the paid button.
		if (rec.luckSteps or 0) > 0 then
			lifted += 1
		end
		-- BY ROLLED VALUE, and the toast prints the figure beside the name so
		-- "top" cannot be misread as "rarest".
		if not best or value > best.value then
			best = { displayName = def.DisplayName, value = value }
		end
	end

	-- Every write above went through the inventory's own setters, so the whole
	-- bag is ONE dirty flag and ONE InventorySync on the next Heartbeat rather
	-- than a replication message per find.
	return uids, best, lifted
end

--[[
	CLEAN THE BAG WHERE THEY STAND, AND NEVER OPEN THE BAY.

	The prompt path for Instant Wash owners -- see the note on prompt.Triggered.
	Returns TRUE only when it actually did the work, because the caller reads
	that as "handled" and falls through to the ordinary mount on false.

	WHAT IT DELIBERATELY DOES NOT DO:

	* NO SESSION. Nothing is mounted, so no stand is claimed, no camera is taken
	  and no other player is blocked out of the bay while this runs. That is the
	  whole request.
	* NO SALE. bulkWash's own note explains why it never sells -- in the session
	  path the uids ride the mounted lump's receipt. There is no lump here, so
	  the finds simply land in the bag as Cleaned with their values rolled, and
	  the player sells them the way they sell everything else. Paying out from a
	  prompt would be a second sell path with its own bonus and its own debounce.
	* NO REVEAL CARDS. Same reason the bulk path suppresses them: twelve finds is
	  over forty seconds of queued cards in front of somebody who pressed a
	  button whose entire promise is not waiting.

	THE COOLDOWN IS PER PLAYER, not per session, because there is no session to
	hang it on. A prompt is trivially spammable and every press behind the first
	would be a fresh ownership web call.
]]
local bagWashAt: { [Player]: number } = {}

-- When this player last armed the bin prompt. See binCrusted.
local binArmedAt: { [Player]: number } = {}
local BIN_ARM_FOR = 4
-- And the floor under it: a confirm sooner than this is a double-tap, not two
-- decisions. Without it, swapping the one-second hold for two taps would have
-- made the destructive path EASIER to hit by accident than the thing it replaced.
local BIN_ARM_MIN = 0.35

Players.PlayerRemoving:Connect(function(player)
	bagWashAt[player] = nil
	binArmedAt[player] = nil
end)

--[[
	THROW THE CRUSTED ONES AWAY, AND PAY NOTHING FOR THEM.

	The bay's R prompt -- see the note where it is built. No coins, no receipt, no
	value roll: this is the opposite of a sale and the whole point is that it is
	free of the wash rather than free of the work.

	NO LUCK ROLL EITHER, deliberately. bulkWash rolls LuckService on anything it
	cleans because that record is about to be worth money; rolling it here would
	spend a player's luck on a find they are in the middle of discarding.

	The cooldown is shared with nothing. Binning is idempotent -- a second press
	with an empty bag finds nothing and says so -- so it needs no throttle beyond
	the hold the prompt already asks for.
]]
function binCrusted(player: Player)
	local inv = InventoryController.Server.find(player)
	if not inv then
		return
	end

	--[[
		COUNTED BEFORE ANYTHING IS TAKEN, so the empty case can be answered
		without destroying anything and the confirmation can say how many.

		AND IT NAMES WHAT IT WILL NOT TAKE. "Nothing crusted in your bag" is true
		and unhelpful to somebody standing there with a full bag of litter who
		pressed a button labelled "Throw Away" -- which is exactly what three
		players did on 2026-09-19 before reporting it as broken.
	]]
	local crusted = inv:GetByState("Crusted")
	if #crusted == 0 then
		binArmedAt[player] = nil
		notify(player, "Nothing crusted to throw away \u{2014} this bins crusted finds, "
			.. "not litter. Sell litter at the pad.", "info")
		return
	end

	--[[
		THE ONBOARDING GETS EXACTLY ONE LUMP, AND THIS BUTTON COULD DESTROY IT WITH
		NO WAY BACK.

		TutorialConfig.LumpGrant is 1. The credit is spent the moment the rock is
		granted, and TutorialServer.capCrust then swaps EVERY later encased find for
		loose litter for as long as the player is still in the tutorial -- its own
		note: "the onboarding's beach is one lump and then trash, all the way to the
		shop". The credit is only ever re-stamped on JOIN, and only for somebody who
		still looksNew.

		So a new player who threw this away did not take a slower route to the wash
		bay. They took NO route: nothing else in that session can ever put a crusted
		find in their bag, and "Washed the lumps" is the measured drop-off step of
		the funnel.

		THE OLD BUG WAS HIDING THIS ONE. Before 2026-09-19 the bin wanted a one-second
		hold, which the DynamicThumbstick ate on touch -- the button did not work at
		all, and could not take anybody's rock. The two-press confirm that fixed it
		is also what made this reachable for the first time. Both shipped together.

		REFUSED RATHER THAN RE-CREDITED. Handing back a credit would send them off to
		rake for another rock, which is a punishment for pressing a button they were
		allowed to press. Keeping the rock costs them nothing and is what they almost
		certainly meant -- nobody in the opening five minutes wants to destroy the
		only interesting thing they have found.

		ONLY WHEN IT IS THE LAST ONE. A tutorial player holding two crusted finds is
		past the guarantee (the prop door can pay one out early), and binning down to
		one is theirs to do.

		TESTED ON THE CREDIT ATTRIBUTE, NOT ON looksNew, AND THAT WAS A CORRECTION.
		looksNew is the wrong question twice over here:

		  It reads TotalEarned <= 0, and step 3 of this game's own funnel is "Sold
		  the haul". Everybody standing at a wash bay has sold something, so
		  looksNew is already false by the time this line could ever run -- the
		  guard would have been dead code.

		  And its own note warns it is MEANINGLESS until profileSettled, answering
		  yes for everybody before the restore lands -- so on the paths where it
		  did fire it could have refused an experienced player's bin.

		The presence of LumpsAttribute is exactly TutorialServer's own inTutorial()
		test, which is the window capCrust swaps finds in -- so it is the same
		question, asked the same way, by the two pieces of code that have to agree.
		`owed <= 0` is the credit already being spent.
	]]
	local owed = tonumber(player:GetAttribute(TutorialConfig.LumpsAttribute))
	if #crusted == 1 and owed ~= nil and owed <= 0 then
		binArmedAt[player] = nil
		notify(player, "Hang on to that one \u{2014} it is the find the beach owes you, "
			.. "and washing it is the next thing to do. Mount it on the stand.", "warn")
		return
	end

	--[[
		TWO PRESSES, AND THE SECOND ONE IS THE ONE THAT DESTROYS.

		The prompt used to carry a one-second hold for this, which is the gesture
		touch cannot give it -- see the note where HoldDuration is set. The hold
		was never the point; the note asking for it asked for "the same
		deliberateness the feedback panel's DELETE gets from its two presses", so
		this is that, by the same mechanism and with the same four seconds.

		IT IS STRICTLY SAFER THAN THE HOLD WAS. A hold could be completed by
		accident by a player who leant on the key; two separate presses inside a
		window cannot, and the first one now states the count out loud so nobody
		confirms a number they had not seen.

		PER PLAYER, and cleared on leave beside bagWashAt, for its reason: there
		is no session to hang it on.
	]]
	local now = os.clock()
	local armedAt = binArmedAt[player]
	if not armedAt or (now - armedAt) > BIN_ARM_FOR then
		binArmedAt[player] = now
		notify(player, string.format(
			"Throw away %d crusted find%s? Press again to confirm \u{2014} no coins for those.",
			#crusted, #crusted == 1 and "" or "s"), "warn")
		return
	end
	-- Inside the window but too soon to be a second decision. Swallowed rather
	-- than re-armed, so a fumbled double-tap neither bins nor silently resets the
	-- clock the player is watching.
	if (now - armedAt) < BIN_ARM_MIN then
		return
	end
	binArmedAt[player] = nil

	local taken = inv:RemoveWhere(function(rec)
		return rec.state == "Crusted"
	end)
	if #taken == 0 then
		-- The bag changed between the two presses. Nothing to report and nothing
		-- was lost, so this says so rather than claiming a binning that did not
		-- happen.
		notify(player, "Nothing crusted to throw away any more.", "info")
		return
	end
	notify(player, string.format("Binned %d crusted find%s \u{2014} no coins for those.",
		#taken, #taken == 1 and "" or "s"), "info")
end


function tryInstantBag(player: Player): boolean
	-- Mid-wash already: they are standing in the bay with a rock on the stand,
	-- and the in-bay Instant button is the control for that. Taking the bag out
	-- from under a live session is what the session path's own uid guard exists
	-- to prevent.
	if sessions[player] then
		return false
	end

	local now = os.clock()
	if now - (bagWashAt[player] or -math.huge) < INSTANT_COOLDOWN then
		-- Handled rather than fallen through: a second press inside the cooldown
		-- is the same press, and opening the bay for it would be the one outcome
		-- the player was trying to avoid.
		return true
	end

	--[[
		AND THE OWNER MAY WANT THE BAY BACK -- Settings -> "Skip the Wash Bay",
		ON by default, and the panel only shows the row to people who own the pass.

		Read BEFORE the ownership lookup, because it is a free attribute read and
		the lookup is a web call: somebody who has turned this off should not spend
		a round trip to Roblox every time they press E on a wash bay.

		`== false` rather than `not`, so the unset case -- every owner who has never
		touched the row, which is all of them on the day this ships -- reads as ON.
	]]
	if player:GetAttribute("Set_SkipWashBay") == false then
		return false
	end

	local inv = InventoryController.Server.find(player)
	if not inv or #inv:GetByState("Crusted") == 0 then
		return false
	end

	-- Asked BEFORE the clock is stamped, so a failed lookup does not lock them
	-- out of retrying for the cooldown.
	local owned, known = GamePassService.ownsFlat(player, INSTANT.key, true)
	if not owned then
		if not known then
			notify(player, "Could not check your " .. INSTANT.name
				.. " purchase just now \u{2014} opening the bay instead.", "warn")
		end
		-- Non-owners say nothing and get the bay, which is the behaviour they
		-- have always had. The pass is advertised on the in-bay button they are
		-- about to see; a refusal here would be a second pitch for the same
		-- thing, fired at somebody who only pressed E to wash a rock.
		return false
	end

	-- Re-checked after the yield. The lookup is a web call and they may have
	-- left, or walked into a bay and started a session, in the seconds it took.
	if not player.Parent or sessions[player] then
		return false
	end
	inv = InventoryController.Server.find(player)
	if not inv then
		return false
	end

	bagWashAt[player] = os.clock()
	local uids, best, lifted = bulkWash(player, inv, nil)
	if #uids == 0 then
		return false
	end

	notify(player, string.format("Instant Wash cleaned %d find%s in your bag%s%s.",
		#uids,
		#uids == 1 and "" or "s",
		best and string.format(" \u{2014} top: %s ($%d)",
			best.displayName, math.floor(best.value + 0.5)) or "",
		lifted > 0 and string.format(", pets lifted %d", lifted) or ""), "info")
	return true
end


local function onInstantRequest(player: Player)
	local session = sessions[player]
	if not (session and session.uid and session.model) then
		return
	end
	if session.remaining <= 0 then
		return -- already finished; the reveal is playing
	end

	local now = os.clock()
	if now - (session.lastInstant or 0) < INSTANT_COOLDOWN then
		return
	end
	session.lastInstant = now

	if not inRange(player, session.bay) then
		WashServer.endSession(player, "out-of-range")
		return
	end

	--[[
		CAPTURED BEFORE THE YIELD BELOW, because the session table is not enough
		to tell one lump from the next. mount() REUSES it -- it only allocates a
		fresh one when there is none -- so after an auto-advance sessions[player]
		is still this very table with a different rock on it, and the identity
		check under the yield would pass. The uid is the only thing that moves.
	]]
	local uidBefore = session.uid

	--[[
		THE ONLY PLACE IN THE GAME THAT RE-ASKS ROBLOX ABOUT THIS PASS -- AND AS
		OF 2026-09-09 THE PLAYER WHO NEEDS IT CAN ACTUALLY REACH IT.

		GamePassService's own note on the refresh path says it exists so that "a
		player whose join sweep hit a blip" is rescued by their next tap rather
		than by rejoining. That was never true in practice: the tap is fired from
		one line in WashClientController, and that line sat behind
		`if not passOwned() then ... return end` -- a read of the very attribute
		the refresh exists to correct. The rescue was locked inside the failure.
		The client now sends unconditionally and this branch is what answers it.

		THREE ANSWERS, NOT TWO. `known` reports whether that `false` is Roblox's
		answer or a hole where an answer should be (see GamePassService.ownsPassId):

		  owned           get on with it.
		  no, DEFINITE    they have not bought it. The client raises the store
		                  dialog on the same tap (PromptGamePassPurchase is a
		                  client call and there is no server-side way to open one),
		                  so this only has to say it.
		  no, UNKNOWN     three failed web calls, or they left mid-lookup. NEVER
		                  tell somebody who may have paid that they did not buy
		                  the thing they bought. Say what actually happened and
		                  name the cure that always works.

		AND THE ASK ITSELF IS HALF THE FIX, whatever it answers. Reaching this
		line is what re-resolves a stale record: ownsPassId writes both the flat
		record and the OwnsInstantWash attribute on any definite answer, so an
		owner whose join sweep was wrong is repaired by their own tap and the
		button turns gold under their finger.
	]]
	local owned, known = GamePassService.ownsFlat(player, INSTANT.key, true)
	if not owned then
		if known then
			notify(player, INSTANT.name .. " is a game pass \u{2014} you do not own it yet.", "warn")
		else
			notify(player, "Could not check your " .. INSTANT.name
				.. " purchase just now \u{2014} try again in a moment, or rejoin to refresh it.", "warn")
		end
		return
	end

	--[[
		RE-CHECKED AFTER THE YIELD, and this is not paranoia.

		ownsFlat's refresh path is a web call. It can take seconds, and a wash
		session is a thing a player can walk out of in one. Everything read
		above -- the session, its model, its chunk array -- may belong to a
		session that has since ended, or to a DIFFERENT lump the auto-advance
		mounted while the request was out. Stripping the shell off that one
		would finish a rock the player never touched -- and now it would finish
		their whole bag along with it, off a tap they aimed at something else.

		SO THE UID IS THE TEST, not the table. See uidBefore above for why
		`sessions[player] ~= session` cannot see an auto-advance on its own.
	]]
	if sessions[player] ~= session or session.uid ~= uidBefore
		or not (session.uid and session.model) then
		return
	end
	if session.remaining <= 0 then
		return
	end

	local cleared = {}
	for i = 1, session.total do
		if session.chunks[i] < 1 then
			session.chunks[i] = 1
			local chunk = ItemVisuals.findChunk(session.model, i)
			if chunk then
				-- Destroyed server-side, exactly as onAim does it, so bystanders
				-- watch the rock come apart too.
				chunk:Destroy()
			end
			table.insert(cleared, i)
		end
	end
	session.remaining = 0

	-- ONE message carrying every index, not a WashChunkGone each. Twenty-two of
	-- those would each bloom their own ring, climb their own chain rung and
	-- fire their own pop: a two-second drum roll in front of a reveal that is
	-- supposed to land now.
	Net.get("WashInstant"):FireClient(player, { chunks = cleared })
	-- And ONE more for the same reason -- the Fx handler emits grit and a pop
	-- per message, and twenty-two of those is a drum roll in front of a reveal
	-- that is supposed to land now.
	Net.get("Fx"):FireClient(player, { kind = "ChunkGone", part = session.model and session.model.PrimaryPart or session.bay.stand })

	local inv = InventoryController.Server.find(player)
	if inv then
		inv:SetProgress(session.uid, 1)
	end
	ItemVisuals.setUncovered(session.model, 1)

	--[[
		AND THE WHOLE BAG WITH IT.

		BEFORE completeLump, not after, and the ordering is load-bearing:
		completeLump's reveal hold ends in the auto-advance, and the advance asks
		whether anything is still Crusted. With the bag already finished the
		answer is no, so the session closes itself on the same beat the reveal
		leaves the screen -- one tap in, one reveal, and out of the bay with
		nothing left to wash. Run afterwards it would mount the next lump first
		and the button would read as having done half its job.

		The uids ride on the session so the mounted lump's sale can take them
		with it; the toast is immediate because the player pressed something and
		the bag emptying under them deserves a reason on the same frame.
	]]
	local bulkUids, best, lifted = {}, nil, 0
	if inv then
		bulkUids, best, lifted = bulkWash(player, inv, session.uid)
	end
	session.bulkUids = bulkUids
	if #bulkUids > 0 then
		notify(player, string.format("Instant Wash cleaned %d more find%s in your bag%s%s.",
			#bulkUids,
			#bulkUids == 1 and "" or "s",
			best and string.format(" \u{2014} top: %s ($%d)",
				best.displayName, math.floor(best.value + 0.5)) or "",
			lifted > 0 and string.format(", pets lifted %d", lifted) or ""), "info")
	end

	completeLump(session)
end

--------------------------------------------------------------------------
-- TICK
--------------------------------------------------------------------------

--[[
	STEP 1, AND IT HAS TO BE SWEPT RATHER THAN HOOKED.

	"Reached a wash bay" is the one of the four the server is not already told
	about: mounting, scrubbing and finishing all pass through code of their own,
	and simply standing near a bay passes through nothing. ProximityPrompt's own
	PromptShown fires on the CLIENT only, and this funnel does not take the
	client's word for anything.

	So: every player against every bay, once a tick. Five bays and a handful of
	players is a few dozen distance tests a second, which is nothing beside the
	sweep SkinService already runs at five times this rate -- and it stops
	mattering entirely after the first hit, because FunnelServer.wash dedupes and
	the early-out below never reaches the arithmetic again.

	inRange IS THE SAME TEST THE BAY ITSELF USES, deliberately. A funnel that
	counted "reached" at a radius the prompt does not agree with would report
	players as having had a chance they never actually got offered.
]]
local function sweepReached()
	for _, player in Players:GetPlayers() do
		for _, bay in bays do
			if inRange(player, bay) then
				washFunnel(player, "Reached")
				break
			end
		end
	end
end

local function tick()
	local now = os.clock()
	sweepReached()
	for player, session in sessions do
		if not inRange(player, session.bay) then
			WashServer.endSession(player, "walked-away")
			continue
		end
		if session.uid and now - session.lastPush >= CFG.ProgressPushInterval then
			session.lastPush = now
			Net.get("WashProgress"):FireClient(player, {
				uid = session.uid,
				chunks = session.chunks,
				remaining = session.remaining,
				total = session.total,
			})
		end
	end
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

local started = false
function WashServer.start()
	assert(RunService:IsServer(), "[WashServer] server-only")
	if started then
		return
	end
	started = true

	local tag = GameConfig.Tags.WashBay
	for _, model in CollectionService:GetTagged(tag) do
		registerBay(model)
	end
	CollectionService:GetInstanceAddedSignal(tag):Connect(registerBay)

	Net.get("WashAim").OnServerEvent:Connect(onAim)
	Net.get("WashEndRequest").OnServerEvent:Connect(function(player)
		WashServer.endSession(player, "player-request")
	end)
	-- Its own thread, because the handler yields on the ownership refresh and a
	-- RemoteEvent handler that yields holds up every later firing of the same
	-- remote. One player waiting on a web call must not stall another's tap.
	Net.get("WashInstantRequest").OnServerEvent:Connect(function(player)
		task.spawn(onInstantRequest, player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		WashServer.endSession(player, "left")
		rateWindow[player] = nil
	end)

	RunService.Heartbeat:Connect(tick)
end

return WashServer
