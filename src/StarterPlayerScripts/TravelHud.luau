--!strict
--[[
	TravelHud  --  StarterPlayerScripts.TravelHud

	QUICK TRAVEL TO THE STATIONS ON THE ISLAND YOU ARE ALREADY STANDING ON.

	Asked for on 2026-09-17: "\237\133\148\236\158\144\237\143\172\237\138\184 , \236\151\133\234\183\184\236\157\180\235\147\156, \237\142\171, \237\140\144\235\167\164 \237\133\148\236\158\144\237\143\172\237\138\184 \235\167\140\235\147\164\236\150\180\236\163\188\236\132\184\236\154\148."
	-- "teleports: upgrade, pet, sell, please make teleports." Nothing of the
	kind existed; the Ferry moves you BETWEEN islands and there was no way at
	all to cross the one you are on.

	CURRENT ISLAND ONLY, AND THAT IS THE WHOLE SECURITY MODEL
	---------------------------------------------------------
	Every destination this offers is somewhere the player is ALREADY standing --
	same island, same zone, reachable on foot in a few seconds. So there is
	nothing to bypass: no rebirth gate, no ferry fare, no room they have not
	earned. That is why this file has NO REMOTE and asks the server for nothing.

	A cross-island version would be a completely different piece of work. It
	would have to be server-authoritative (the island ladder is real progression)
	and it would compete with the Ferry, which is built content with a crossing
	of its own. Deliberately not done.

	WHY THIS IS NOT A RAIL KEY
	--------------------------
	The obvious home is a seventh key on MenuHud's RAIL, and the rail is built to
	take one -- RAIL_H is derived off #RAIL and fitRail re-measures. It is still
	the wrong place. Six keys make RAIL_H 634; seven make it 741. On a 374-tall
	phone fitRail has about 340 to work with, so seven keys land at 92 * (340/741)
	= 42px -- under the 44px touch minimum, on the device this game already has a
	funnel problem on. A convenience feature is not worth shrinking every existing
	key past the line.

	So this owns one small button and one card, and touches no existing layout.

	DISCOVERED AT RUNTIME, NEVER BAKED
	----------------------------------
	The stations cannot be listed in a table here, because three islands do not
	have any until they are built: the Vault's SellPad comes from VaultBuilder,
	Penguin's and the Wreck's from their own builders, and none of them exist in
	the place file. A baked table would be right in Edit and wrong in play.

	So the list is rebuilt every time the card opens. It is a walk over
	Workspace's descendants plus two CollectionService lookups, once per open,
	which is nothing next to what opening a panel already costs.

	The four kinds are found the way the game itself finds them:
	  SELL      a BasePart named "SellPad" -- CTB_Server collects exactly these
	  UPGRADE   a model named Upgrade* (UpgradeKiosk on Beach, UpgradeStall in
	            the two rooms). Several islands have none, and those simply do
	            not show the row -- there is nothing there to travel to.
	  PETS      CollectionService "PetStation", which PetStationBuilder tags
	  WASH      CollectionService "WashBay", which WashServer tags
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local PanelKit = require(Modules:WaitForChild("PanelKit"))
local TouchFit = require(Modules:WaitForChild("TouchFit"))
local Motion = require(Modules:WaitForChild("Motion"))
local Config = require(ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Config"))

local C = PanelKit.C
local player = Players.LocalPlayer

local TravelHud = {}

--------------------------------------------------------------------------
-- WHAT COUNTS AS A DESTINATION
--------------------------------------------------------------------------
-- Order is the order the rows are drawn in, and it is the order of the
-- opening loop rather than alphabetical: fill the bag, sell it, wash what
-- was crusted, spend what you made, and the eggs last because they are the
-- side quest.
local KINDS = {
	{ key = "Sell",    label = "SELL YOUR HAUL", tint = C.sun },
	{ key = "Wash",    label = "WASH BAY",       tint = C.sea },
	{ key = "Upgrade", label = "UPGRADES",       tint = C.foam },
	{ key = "Pets",    label = "EGGS",           tint = C.grape },
}

-- How far from the station the player is put down. Eight studs is outside
-- every counter's own footprint and inside the prompt range of all of them,
-- so you arrive with the button already offered rather than having to close
-- the distance yourself.
local STAND_OFF = 8

--[[
	PanelKit.chunky RETURNS A FRAME, NOT A BUTTON, and finding that out cost a
	silent start().

	TouchFit.press wants a GuiButton -- it binds MouseButton1Click -- and handing
	it a chunky face throws "MouseButton1Click is not a valid member of Frame".
	That threw INSIDE start(), after the travel key was built and before the card
	was, so the symptom was a button that existed and did nothing rather than an
	error anyone would notice. MenuHud never hits this because its settings rows
	go through `pill`, which builds a real TextButton.

	So: an invisible TextButton laid over the face, filling it. The chunky art
	stays exactly as it is and the press has something it can legally bind to.
]]
local function pressable(face: GuiObject, fn: () -> ()): TextButton
	local hit = Instance.new("TextButton")
	hit.Name = "Hit"
	hit.Size = UDim2.fromScale(1, 1)
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.AutoButtonColor = false
	-- Over the label (8) and the gloss, so nothing inside the face can swallow
	-- the tap the way a ZIndex-6 caption would.
	hit.ZIndex = 20
	hit.Parent = face
	TouchFit.press(hit, fn)
	return hit
end

local function pivotOf(inst: Instance): Vector3?
	local ok, cf = pcall(function()
		return (inst :: any):GetPivot()
	end)
	return ok and cf.Position or nil
end

--[[
	Everything on ONE island, keyed by kind.

	Bucketed with Config.zoneAt rather than by which model a thing is parented
	under, because the parenting is not consistent -- the Beach's wash bay is a
	Workspace child while the Dunes' is inside Island2.Market -- and the zone is
	the question actually being asked anyway.
]]
local function stationsOn(islandId: number): { [string]: { Instance } }
	local found: { [string]: { Instance } } = {}
	local function keep(kind: string, inst: Instance)
		local pos = pivotOf(inst)
		if not pos then
			return
		end
		local zone = Config.zoneAt(pos)
		if not (zone and zone.id == islandId) then
			return
		end
		found[kind] = found[kind] or {}
		table.insert(found[kind], inst)
	end

	for _, d in workspace:GetDescendants() do
		if d:IsA("BasePart") and d.Name == "SellPad" then
			keep("Sell", d)
		elseif d.Name:sub(1, 7) == "Upgrade" and (d:IsA("Model") or d:IsA("BasePart")) then
			keep("Upgrade", d)
		end
	end
	for _, m in CollectionService:GetTagged("PetStation") do
		keep("Pets", m)
	end
	for _, m in CollectionService:GetTagged("WashBay") do
		keep("Wash", m)
	end
	return found
end

--[[
	WHERE TO PUT THE PLAYER DOWN, and it is beside the station rather than on it.

	Landing on the pivot drops you inside a kiosk's roof or in the middle of a
	sell pad's glow. The offset is taken TOWARDS THE ISLAND CENTRE, because every
	one of these counters faces inward off the shoreline -- so the approach side
	is the inland side, which is also the side the player would have walked in
	from.

	The ground is found by a downward ray rather than assumed from the station's
	own Y: the Shrine's stall stands at y=21 and the Magma bench at y=12, and a
	fixed drop would either bury you or leave you falling.

	THE RAY STARTS SIX STUDS UP, NOT FORTY, AND THAT WAS A BUG FOUND IN PLAY.
	From forty it hits whatever is OVERHEAD first: travelling to the Beach wash
	bay landed the player at y=15.9 on the bay's own canopy, eleven studs up and
	in a Climbing state, with the roof standing in for the floor. Six clears the
	pads and the counters and starts below every canopy in the game.

	And the result is CLAMPED as well as started low, because a station tucked
	under something lower than six studs would still find a lid. A hit more than
	six studs above the station itself is not ground the player wants; the
	station's own height is the honest fallback.
]]
local function landingFor(inst: Instance, isl): CFrame?
	local pos = pivotOf(inst)
	if not pos then
		return nil
	end
	local inward = Vector3.new((isl.cx or 0) - pos.X, 0, (isl.cz or 0) - pos.Z)
	local dir = (inward.Magnitude > 1) and inward.Unit or Vector3.new(0, 0, 1)
	local spot = pos + dir * STAND_OFF

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character :: any }
	local hit = workspace:Raycast(spot + Vector3.new(0, 6, 0), Vector3.new(0, -90, 0), params)
	local y = hit and hit.Position.Y or pos.Y
	if y > pos.Y + 6 then
		y = pos.Y
	end
	return CFrame.lookAt(Vector3.new(spot.X, y + 3.5, spot.Z), Vector3.new(pos.X, y + 3.5, pos.Z))
end

--[[
	WHEN THIS MUST REFUSE.

	A SCRIPTABLE CAMERA MEANS A CINEMATIC OWNS THE SHOT -- the ferry crossing,
	the rebirth ascent, the vault reveal, the skin ceremony. Moving the root out
	from under any of them leaves the player watching an empty frame, and the
	ferry one would land them mid-ocean. One test covers all of them, and it
	keeps working when a sixth cinematic is written.

	SEATED covers the car and the ferry deck: teleporting out of a seat leaves
	the weld behind and drags the vehicle with you.
]]
local function refusal(): string?
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not (char and hum and char:FindFirstChild("HumanoidRootPart")) then
		return "Hold on \226\128\148 still getting you on the beach."
	end
	if workspace.CurrentCamera and workspace.CurrentCamera.CameraType == Enum.CameraType.Scriptable then
		return "Not in the middle of this."
	end
	if hum.SeatPart ~= nil or hum:GetState() == Enum.HumanoidStateType.Seated then
		return "Hop off first."
	end
	return nil
end

--------------------------------------------------------------------------
-- THE CARD
--------------------------------------------------------------------------
local gui: ScreenGui
local card: Frame
local body: Frame
local note: TextLabel
local open = false

local CARD_W, CARD_H = 320, 300
local ROW_H = 52

local function say(text: string)
	note.Text = text
	note.TextTransparency = 0
	Motion.tween(note, 1.6, Motion.Ease.hover, { TextTransparency = 1 })
end

local function rebuild()
	for _, c in body:GetChildren() do
		if c:IsA("GuiObject") and c ~= note then
			c:Destroy()
		end
	end

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local zone = hrp and Config.zoneAt((hrp :: BasePart).Position)
	if not zone then
		say("Nothing to travel to out here.")
		return
	end

	local found = stationsOn(zone.id)
	local isl
	for _, i in Config.ISLANDS do
		if i.id == zone.id then
			isl = i
		end
	end

	local order = 0
	local any = false
	for _, kind in KINDS do
		local list = found[kind.key]
		if list and #list > 0 then
			any = true
			order += 1
			local holder = Instance.new("Frame")
			holder.Size = UDim2.new(1, 0, 0, ROW_H)
			holder.BackgroundTransparency = 1
			holder.LayoutOrder = order
			holder.Parent = body

			-- One row per KIND, not per instance. Ashfall has four egg stations
			-- and a list of four identical "EGGS" rows is a worse answer than one
			-- row that takes you to the nearest of them.
			local face, slab = PanelKit.chunky(holder, 288, 44, kind.tint, 14)
			face.AnchorPoint = Vector2.new(0.5, 0.5)
			face.Position = UDim2.fromScale(0.5, 0.5)
			local lbl = PanelKit.text(face, kind.label, 18, Enum.Font.LuckiestGuy, C.white)
			lbl.Size = UDim2.fromScale(1, 1)
			lbl.ZIndex = 8
			PanelKit.punch(lbl, 2)

			local targets = list
			pressable(face, function()
				local no = refusal()
				if no then
					say(no)
					return
				end
				local me = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
				if not me then
					return
				end
				-- Nearest of this kind, measured from where the player actually is.
				local best, bestD
				for _, t in targets do
					local p = pivotOf(t)
					if p then
						local dist = (p - (me :: BasePart).Position).Magnitude
						if bestD == nil or dist < bestD then
							best, bestD = t, dist
						end
					end
				end
				local cf = best and landingFor(best, isl or { cx = 0, cz = 0 })
				if not cf then
					say("Could not find that one.")
					return
				end
				(me :: BasePart).CFrame = cf
				TravelHud.close()
			end)
		end
	end

	if not any then
		say("No counters on this island.")
	end
end

function TravelHud.close()
	open = false
	card.Visible = false
end

function TravelHud.toggle()
	if open then
		TravelHud.close()
		return
	end
	open = true
	rebuild()
	PanelKit.popIn(card, CARD_W, CARD_H)
end

--------------------------------------------------------------------------
function TravelHud.start()
	gui = Instance.new("ScreenGui")
	gui.Name = "TravelHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	-- Above the HUD (1) and the toast column (16), below every rail panel (40+):
	-- this is a HUD control that opens one card, not a panel in the rail's stack.
	gui.DisplayOrder = 18
	gui.Parent = player:WaitForChild("PlayerGui")

	--[[
		UNDER THE LEFT-HAND STACK, AND THE FIRST PLACE THIS WENT WAS WRONG.

		It was authored top-right "above the rail", which turned out not to exist:
		measured in Play at 1274x525 the rail spans y 7..458 -- the WHOLE right
		edge -- and the button landed on top of its first key. That is the exact
		overlap this session spent an afternoon removing from the wash bay, so it
		was moved rather than nudged.

		What is actually free, measured rather than guessed:

		  rail          x 1194..1259   y 7..458      the entire right edge
		  coin/load     x 9..170       y 9..75
		  QUICK SELL    x 55..170      y 115..152
		  luck chip     x 18..171      y 420..450
		  tutorial line x 374..900     y 412..438
		  event pill    x 554..720     y 2..24

		-- which leaves the left column, x 9..170 and y 152..420, empty.

		IT SITS 23px BELOW QUICK SELL RATHER THAN TUCKED UNDER IT. Quick Sell is a
		ROBUX button. A free convenience key butted against a paid one is a mis-tap
		that costs the player money, and that is a different class of mistake from
		a mis-tap that costs them a walk.

		Authored in unscaled units: UiFit wraps every top-level child whose size is
		pure offset and scales the lot (0.73 on this viewport), so these numbers are
		the absolute ones divided through by that.
	]]
	--[[
		ONE POSITION ON EVERY DEVICE, AND THE TOUCH SPLIT THAT WAS HERE IS GONE.

		2026-09-23 this key was moved to 0.62 of the width on touch only, to get it
		out of Roblox's DynamicThumbstick (measured claim x -100..266, y 105..416 on
		a 666x374 phone -- the authored spot below renders x 45..140, y 144..175 at
		scale 0.6, entirely inside it).

		THAT FIX WAS WORSE THAN WHAT IT REPLACED. 0.62 of the width is the middle of
		a phone screen, and it drew four reports in a single day on v1264, against
		one for the position it replaced:

		  Honeypiezzz  832x440  "The travel button is in the middle of my screen"
		  Lilly        714x360  "remove travel button"
		  Ndyy         750x360  "tombol perjalanan nya menghalang tau"
		  akio         792x392  "the travel button overlap with the water pressure
		                        button. it's annoying"

		akio's is the one that explains the rest: this gui is DisplayOrder 18 and
		MenuHud is 12, so the key draws OVER an open panel. At x 45..140 it clears a
		centred card; at 0.62 it lands in the middle of one, on top of the rows.
		Putting the key back fixes that as a side effect -- nothing else is needed.

		OWNER'S CALL, 2026-09-25: one position everywhere, matching desktop.

		⚠️ RECORDED SO IT IS NOT REDISCOVERED AS A BUG: this spot IS inside the
		thumbstick's claim, and tggrozovaia reported exactly that ("Put the travel
		button somewhere else, it's in the way", 764x384 touch). That trade was made
		deliberately -- one complaint about a button near the stick beat four about a
		button in the middle of the screen. If it comes back, the options already
		considered were the right-hand rail (MenuHud's RAIL re-measures when a key is
		added, so it is the supported path) or dropping the floating key and reaching
		travel from a panel. Do not simply move it sideways again.

		-- the original placement note follows, and its measurements still stand --

		WHAT THE TOUCH SPLIT WAS TRYING TO FIX, for the record: the list below is
		missing the one control that matters most on a phone.

		Every rect measured for that list -- rail, coin/load, QUICK SELL, luck chip,
		tutorial line, event pill -- was measured at 1274x525, ON A DESKTOP. Roblox's
		own touch controls are not in it because they do not exist on the machine it
		was measured on. So "the left column, x 9..170 and y 152..420, empty" is true
		of this game's UI and false of the screen: that rectangle is where Roblox
		puts the thumbstick.

		MEASURED 2026-09-23 against the DynamicThumbstick claim WashClientController
		recorded (x -100..266, y 105..416 on a 666x374 phone):

		    TRAVEL rendered    x 45..140   y 144..175     (authored 75,240 at 0.6)
		    thumbstick claim   x -100..266  y 115..426
		    overlap            95 x 31 -- THE ENTIRE BUTTON, not a clipped corner

		Reported by tggrozovaia from a 764x384 touch laptop, 0 rebirths, five
		minutes in: "Put the travel button somewhere else, it's in the way." It was
		sitting on top of the control they walk with.

		0.62 OF THE WIDTH IS NOT A GUESS -- it is the same constant the wash bay key
		uses, chosen there against this same measurement, where it "spans about
		x 323..503 and clears the region outright". The thumbstick's claim ends at
		x 266, and 0.62 of any phone this game floors at puts the whole button past
		it. The rail hugs the right edge behind its own gutter, so the band between
		them is free.

		SCALE ON X, OFFSET ON Y, and the mix is deliberate. UiFit wraps this gui in a
		FitRoot whose ABSOLUTE size is the screen (measured: FitRoot abs 1272x467 on
		a 1272x525 viewport), so a Scale position is a true screen fraction while an
		offset is multiplied by the UIScale. x therefore tracks the phone's width,
		and y stays exactly where it was authored -- the key does not move up or
		down, it only crosses the screen.

		DESKTOP IS UNTOUCHED, and deliberately: there is no thumbstick there, and
		the left-column position above was reasoned carefully, including the 23px
		that keeps a free key off a Robux one. None of that is wrong on a mouse.

		KNOWN EDGE: below about 600 logical px of width, 0.62 starts to graze the
		thumbstick's right edge. Nothing this game runs on is that narrow -- the
		narrowest reported is 666 -- but if that changes, anchor off the right edge
		rather than widening this fraction.
	]]
	local btn = Instance.new("Frame")
	btn.Name = "TravelKey"
	btn.AnchorPoint = Vector2.new(0, 0)
	btn.Position = UDim2.new(0, 75, 0, 240)
	btn.Size = UDim2.fromOffset(158, 51)
	btn.BackgroundTransparency = 1
	btn.Parent = gui

	--[[
		AND IT STANDS DOWN WHILE A PANEL IS OPEN.

		THE POSITION WAS NEVER GOING TO FIX THIS. This gui is DisplayOrder 18 and
		MenuHud is 12, so wherever the key sits it draws ON TOP of every card in
		the game. Three reports, three different spots on the screen, one cause:

		  akio 2026-09-24          "overlap with the water pressure button"
		  Kay 2026-09-25           "in my way and I can't really upgrade how I like"
		  mimikyuumiyaa 2026-09-25 "in the way of ... turning the beach tune on/off
		                            or claiming the quest rewards ... iPad landscape"

		The first two were the 0.62 position, which landed in the middle of a
		centred card. Moving the key back fixed those two -- measured 2026-09-27,
		it now clears Shop, Rewards, Settings, Pets, Index and the rest at every
		viewport checked, including both of mimikyuumiyaa's iPad orientations
		(scale 0.95 landscape, 0.65 portrait).

		IT DID NOT FIX ALL OF THEM. The same sweep found the FERRY BOARD still
		overlapping this key by 11px -- that card is not centred like the others.
		So "put the button somewhere nothing else is" is a claim that has to hold
		against every panel at every aspect ratio, and it does not.

		A HUD KEY HAS NO BUSINESS OVER AN OPEN CARD, whatever the geometry. So it
		hides while one is up, which is the rule rather than the exception this
		was being maintained as.

		ITS OWN CARD IS EXCLUDED, deliberately: this key is the control that opens
		that card, and letting the card it raised switch it off is circular. The
		card is centred and the key is far left, so they do not collide anyway.

		POLLED, NOT SIGNALLED, and at a quarter second. The tagged set changes
		rarely and PanelWatch already sweeps it the same way; the cost is a table
		walk four times a second against a list of twenty. The loop ends with the
		button, so a destroyed gui does not leave it spinning.
	]]
	local function panelOpen(): boolean
		for _, root in CollectionService:GetTagged(PanelKit.Tag) do
			if root:IsA("GuiObject") and root.Visible then
				local screen = root:FindFirstAncestorWhichIsA("ScreenGui")
				if screen and screen.Enabled and screen ~= gui then
					return true
				end
			end
		end
		return false
	end

	task.spawn(function()
		while btn.Parent do
			btn.Visible = not panelOpen()
			task.wait(0.25)
		end
	end)

	local face = PanelKit.chunky(btn, 158, 51, C.foam, 14)
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.5, 0.5)
	local lbl = PanelKit.text(face, "TRAVEL", 18, Enum.Font.LuckiestGuy, C.white)
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.ZIndex = 8
	PanelKit.punch(lbl, 2)
	pressable(face, function()
		TravelHud.toggle()
	end)

	local root, cardBody, closeFace = PanelKit.card(gui, "Travel", CARD_W, CARD_H, C.foam)
	card = root
	body = cardBody
	card.Visible = false

	local lay = Instance.new("UIListLayout")
	lay.FillDirection = Enum.FillDirection.Vertical
	lay.HorizontalAlignment = Enum.HorizontalAlignment.Center
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Padding = UDim.new(0, 6)
	lay.Parent = body

	-- Lives OUTSIDE the list layout (LayoutOrder 999 would still take a row), so
	-- a refusal does not shove the buttons around while the player is aiming.
	note = PanelKit.text(card, "", 15, Enum.Font.GothamBold, C.ink)
	note.AnchorPoint = Vector2.new(0.5, 1)
	note.Position = UDim2.new(0.5, 0, 1, -10)
	note.Size = UDim2.new(1, -24, 0, 20)
	note.TextTransparency = 1
	note.ZIndex = 20

	if closeFace then
		TouchFit.press(closeFace, function()
			TravelHud.close()
		end)
	end
end

return TravelHud
