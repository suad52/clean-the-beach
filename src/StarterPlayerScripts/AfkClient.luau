--[[
	AfkClient  --  StarterPlayerScripts.AfkClient

	The half of THE LONG SHORE the player watches: the puppet that rakes the bay,
	the card that says what it is earning, and the input sinks that stop the
	player fighting their own character for the wheel.

	THE PUPPET IS COSMETIC AND THAT IS DELIBERATE. It walks; it does not rake.
	It writes no terrain, calls nothing in CTB_Client, and adds nothing to the
	beach-raked percentage. The wage is wall-clock and the server pays it whether
	this loop is running at 60 fps or 2 -- see the long note in AfkConfig for why
	tying pay to the walk would punish exactly the players the mode is for.

	WHAT MAKES IT READ AS A PERSON rather than a thing following a path. All four
	are free, none of them touch the money:
	  * ease down into a corner and back out (TurnFloor / TurnRadius)
	  * a varied beat at each lane end -- identical pauses are their own tell
	  * half a stud of wander, faded out by the SAME term as the turn easing so
	    the aim is un-nudged by the time arrival matters and the puppet cannot
	    end up circling its own waypoint
	  * at the end of a lap it walks down to the water and stands looking at it,
	    instead of freezing mid-beach

	⚠️ ARRIVAL IS ALWAYS TESTED AGAINST THE TRUE WAYPOINT, never against the
	wandered aim. Test against the aim and the wander term decides when you have
	arrived, which is how a puppet ends up orbiting a lane end forever.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local AfkConfig = require(Modules:WaitForChild("AfkConfig"))
local Net = require(Modules:WaitForChild("Net"))
-- Only for the walking floor, and only for the window before BaseWalkSpeed has
-- been written. It was a literal 16 -- see ProgressionConfig.BaseWalkSpeed.
local ProgressionConfig = require(Modules:WaitForChild("ProgressionConfig"))
local PanelKit = require(Modules:WaitForChild("PanelKit"))
local UiFit = require(Modules:WaitForChild("UiFit"))

-- Touch targets: see the module. Substituted for MouseButton1Click/Activated so
-- a tap in the margin around a control that renders under 44px on a phone still
-- reaches the same handler. No-ops on desktop and on controls already big enough.
local TouchFit = require(Modules:WaitForChild("TouchFit"))

local C = PanelKit.C
local player = Players.LocalPlayer

local AfkClient = {}

local state = nil          -- the live sync payload, or nil when not idle
local walker = nil         -- the running walk coroutine's cancel flag
local started = false

-- card
local gui, root, bayLabel, earnedLabel, rateLabel

--------------------------------------------------------------------------
-- THE LAP
--------------------------------------------------------------------------

--[[
	The waypoints for one bay, in world space, derived from the same numbers the
	builder drew the rake lanes with -- so the puppet walks ON the pale strips
	rather than beside them.

	Lanes run along X and step toward the sea, which is how a person actually
	rakes a beach: out, step over, back, step over. The lap finishes at the
	water's edge, which is where the rest beat happens.
]]
local function lapFor(bay: number): { Vector3 }
	local o = AfkConfig.plotOrigin(bay)
	local halfX = AfkConfig.PlotWidth * 0.5 - AfkConfig.LaneInset
	local usable = AfkConfig.PlotDepth - AfkConfig.LaneInset * 2
	local lanes = AfkConfig.LaneCount

	local pts = {}
	for i = 1, lanes do
		local t = (lanes == 1) and 0.5 or ((i - 1) / (lanes - 1))
		local z = o.Z - usable * 0.5 + usable * t
		-- Odd lanes run +X, even lanes run -X, so the puppet never teleports
		-- back to the start of a lane -- it turns and comes home down the next.
		local a, b = -halfX, halfX
		if i % 2 == 0 then
			a, b = halfX, -halfX
		end
		table.insert(pts, Vector3.new(o.X + a, o.Y, z))
		table.insert(pts, Vector3.new(o.X + b, o.Y, z))
	end
	-- ...and out to the water to stand for a moment.
	table.insert(pts, Vector3.new(o.X, o.Y, o.Z + AfkConfig.PlotDepth * 0.5 - 5))
	return pts
end

--------------------------------------------------------------------------
-- THE WALK
--------------------------------------------------------------------------

--[[
	HAND THE LEGS BACK, AND TO THE RIGHT NUMBER.

	The puppet drives WalkSpeed every frame -- down to TurnFloor into a corner
	and to a flat 0 for the beat at the water -- so whatever ends the walk has to
	put a real speed back or the player is left crawling or frozen.

	⚠️ OFF THE SHORE IT IS NOT AfkConfig.WalkSpeed. That is the SHORE's stroll
	speed (10), and writing it here on the way out was the whole of "you come
	back from the idle area and you are slow forever": the server's own restore
	(AfkService.leave -> ProgressionServer.applyAll) had already run and set the
	real speed, and this line -- a client write to its own humanoid, so it
	replicates and wins -- landed a moment later and overwrote it. It survived
	every respawn because nothing re-derived it until the next applyAll.

	BaseWalkSpeed is ProgressionServer publishing what it just wrote, so this
	restores the Beach Legs value rather than a constant -- including a level
	bought WHILE idling, which the shop panel allows. ProgressionConfig's
	BaseWalkSpeed (the level-1 floor, 24) is only the fallback for a client that
	somehow reads the attribute before the server has written one; it was a
	literal 16, which stopped being the floor on 2026-08-28.
]]
--[[
	HOW FAR FROM ITS BAY THE WALK STILL BELIEVES IT IS DRIVING THIS CHARACTER.

	The furthest waypoint on a lap is about 29 studs from the bay's centre (half
	the plot width, less the lane inset), so a whole plot width is twice the
	slack the walk itself can ever need -- and anything past it is not a puppet
	that wandered, it is a character something moved out from under the loop.
	See AfkBus's header for the class of bug that is.
]]
local BAY_LEASH = AfkConfig.PlotWidth

--[[
	STOP THE HUMANOID, NOT JUST THE LOOP.

	`Humanoid:MoveTo` is a STANDING ORDER and not a per-frame command: the
	humanoid walks at that target until it arrives or eight seconds pass, and
	cancelling the coroutine that issued it does nothing to the order. The last
	target is a lane end eight thousand studs away, so leaving the shore mid-lane
	sent the player walking off across the real beach the moment they landed on
	it -- "we are still walking after leaving".

	WHY IT WAS ONLY SOMETIMES. The default control module calls Humanoid:Move
	every frame the player is steering, and Move cancels a MoveTo. Anybody who
	touched a key on the way back cleared it for themselves and never saw the
	bug; anybody who had let go of the keyboard to go idle -- which is every
	user of this mode -- did.

	The MoveTo at the character's own feet is the documented cancel. The zero
	Move behind it is what hands the wheel back to the control module in the
	same frame rather than at the next keypress.
]]
local function haltMove()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp or hum.Health <= 0 then
		return
	end
	hum:MoveTo(hrp.Position)
	hum:Move(Vector3.zero, false)
end

--[[
	`onShore` IS THE CALLER'S ANSWER AND IT BEATS THE ATTRIBUTE.

	AfkPlot and the AfkSync message are two separate pieces of replication and
	nothing orders them. A leave handled off the message can therefore read an
	attribute that has not cleared yet, conclude the player is still out there
	and put the SHORE's speed back -- which is the "come back permanently slow"
	bug in its second costume, and it survives every respawn for the same reason
	it did the first time. Anything that KNOWS says so; nil keeps the old
	behaviour for callers that genuinely have to ask.
]]
local function restoreSpeed(onShore: boolean?)
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return
	end
	if onShore == nil then
		onShore = AfkConfig.plotOf(player) ~= nil
	end
	if onShore then
		hum.WalkSpeed = AfkConfig.WalkSpeed
	else
		hum.WalkSpeed = player:GetAttribute("BaseWalkSpeed") or ProgressionConfig.BaseWalkSpeed
	end
end

--[[
	The restore is done HERE as well as at the tail of the walk coroutine, and
	the pair is not redundant. The coroutine only reaches its tail when it next
	RESUMES, and the longest thing it waits on is the rest beat at the water --
	during which it has parked the humanoid at 0. Leaving on that beat meant
	standing rooted on the beach for the rest of it. Both write the same value
	now, so whichever lands second is a no-op.
]]
local function stopWalk(onShore: boolean?)
	if walker then
		walker.cancelled = true
		-- Told to the walk, so its tail does not halt a SECOND time seconds
		-- later -- by then the player has the wheel back and a stray zero Move
		-- is a frame of stutter for no reason. See the tail.
		walker.halted = true
		walker = nil
	end
	--[[
		OUTSIDE the `if`, where the restore used to sit INSIDE it.

		A walk that has already run out its own tail leaves `walker` nil and can
		still have left a standing MoveTo behind it -- which is exactly the state
		a sync arriving a beat late finds. A stop that did nothing at all in that
		case would leave the character walking with nothing running to stop it.
		Both calls are idempotent, so paying for them twice costs nothing.
	]]
	haltMove()
	restoreSpeed(onShore)
end

local function startWalk(bay: number)
	stopWalk()
	local token = { cancelled = false }
	walker = token

	task.spawn(function()
		local pts = lapFor(bay)
		local rng = Random.new(bay * 7919 + 13)
		local i = 1
		local wanderPhase = rng:NextNumber(0, 6.28)

		while not token.cancelled do
			local char = player.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if not hum or not hrp or hum.Health <= 0 then
				task.wait(0.4)
				continue
			end

			local target = pts[i]
			local isRest = (i == #pts)

			-- Walk to it, re-aiming every frame.
			local guard = os.clock() + 30    -- a lane is ~5s; 30 means something is wrong
			while not token.cancelled do
				local dt = RunService.Heartbeat:Wait()
				--[[
					⚠️ RE-TESTED AFTER THE WAIT, AND THAT IS THE WHOLE RACE.

					stopWalk is called from a remote handler and this yield is the
					entire frame, so the cancel lands DURING it far more often than
					it lands anywhere else. Testing only at the top of the loop
					honoured it one MoveTo too late: the loop steered the character
					at a waypoint on the shore AFTER stopWalk had already halted it,
					re-arming the standing order it had just cleared, and the walk
					then outlived this coroutine by eight seconds.
				]]
				if token.cancelled then
					break
				end
				char = player.Character
				hum = char and char:FindFirstChildOfClass("Humanoid")
				hrp = char and char:FindFirstChild("HumanoidRootPart")
				if not hum or not hrp or hum.Health <= 0 then
					break
				end

				-- ARRIVAL AGAINST THE TRUE WAYPOINT. Flat distance: the bay is
				-- level and the character's Y wobbles as it walks.
				local here = hrp.Position

				--[[
					THE PUPPET DOES NOT FOLLOW THE CHARACTER OFF THE SHORE.

					Everything that moves a player out is supposed to end the visit
					first -- that is what AfkBus is for, and its header lists what
					goes wrong when something does not. This is the last line of
					that defence: the character is somewhere else, this loop is
					still steering, and the aim is a lane end eight thousand studs
					away. Marked `offShore` so the tail hands back the REAL walk
					speed rather than the shore's stroll -- by definition the visit
					attribute cannot be trusted at this point, since a visit that
					had ended properly would have stopped this loop already.
				]]
				if (here - AfkConfig.plotOrigin(bay)).Magnitude > BAY_LEASH then
					token.cancelled = true
					token.offShore = true
					break
				end

				local flat = (Vector3.new(here.X, 0, here.Z) - Vector3.new(target.X, 0, target.Z)).Magnitude
				if flat < 3 or os.clock() > guard then
					break
				end

				--[[
					THE EASE. One term, used twice.

					Near the waypoint `near` runs 0..1, and it both slows the walk
					(so the puppet leans into the corner instead of stopping dead)
					and fades the wander out. Fading the wander by the SAME term is
					what guarantees the aim is honest by the time the distance test
					above starts mattering.
				]]
				local near = math.clamp(flat / AfkConfig.TurnRadius, 0, 1)
				local ease = AfkConfig.TurnFloor + (1 - AfkConfig.TurnFloor) * near
				hum.WalkSpeed = AfkConfig.WalkSpeed * ease

				wanderPhase += AfkConfig.WanderRate * dt
				local drift = AfkConfig.Wander * near
				local aim = target + Vector3.new(
					math.cos(wanderPhase) * drift, 0, math.sin(wanderPhase) * drift)

				hum:MoveTo(aim)
			end

			if token.cancelled then
				break
			end

			--[[
				THE BEAT AT THE END OF A LANE, and the longer one at the water.

				The rest stop is two beats and not one: the humanoid faces the way
				it is walking, so a puppet that simply stops at the water's edge is
				facing the water only by luck. It stands, then is nudged to look
				back up the beach, which is what somebody straightening up from a
				job actually does.
			]]
			if isRest then
				local hum2 = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
				if hum2 then
					hum2.WalkSpeed = 0
				end
				task.wait(AfkConfig.RestHold * 0.6)
				local char2 = player.Character
				local hrp2 = char2 and char2:FindFirstChild("HumanoidRootPart")
				if hrp2 and not token.cancelled then
					local o = AfkConfig.plotOrigin(bay)
					local look = Vector3.new(o.X, hrp2.Position.Y, o.Z - AfkConfig.PlotDepth)
					hrp2.CFrame = CFrame.lookAt(hrp2.Position, look)
				end
				task.wait(AfkConfig.RestHold * 0.4)
			else
				task.wait(rng:NextNumber(AfkConfig.PauseMin, AfkConfig.PauseMax))
			end

			i += 1
			if i > #pts then
				i = 1
			end
		end

		--[[
			Whatever ended the loop, do not leave the character crawling -- OR
			walking. See haltMove: the standing order outlives this coroutine
			unless something cancels it, and the tail is one of the two places
			that can.

			ONLY IF STOPWALK DID NOT ALREADY DO IT, and that is not an
			optimisation. The tail is reached when the coroutine next RESUMES,
			and the longest thing it waits on is the five-second beat at the
			water -- so an unconditional halt here would fire up to five seconds
			after the player got the wheel back, and a zero Move landing on
			somebody who is walking is a frame of stutter they did nothing to
			earn. What is left for this to catch is the loop ending on its OWN:
			a death, or the leash above.
		]]
		if not token.halted then
			haltMove()
		end
		if token.offShore then
			restoreSpeed(false)
		else
			restoreSpeed()
		end
	end)
end

--------------------------------------------------------------------------
-- THE WHEEL
--------------------------------------------------------------------------

--[[
	WHILE THE PUPPET IS DRIVING, THE PLAYER IS NOT.

	Without this the player's WASD fights MoveTo every frame and the character
	judders on the spot. Sunk at High priority against the PlayerActions rather
	than against key codes, so it covers the thumbstick and the touch pad too.

	CLICKS ARE NOT SUNK, on purpose -- the card's GO BACK button has to remain
	pressable, and so does the leave prompt. That is also the hole that bit the
	same system in Seal A Driveway: a click is the one input that still gets
	through, so anything a click can reach must go through AfkBus. See its note.
]]
local SINK = "AfkSinkMovement"
local sunk = false

local function sinkInput(on: boolean)
	if on == sunk then
		return
	end
	sunk = on
	if on then
		ContextActionService:BindActionAtPriority(SINK,
			function() return Enum.ContextActionResult.Sink end,
			false, Enum.ContextActionPriority.High.Value,
			Enum.PlayerActions.CharacterForward, Enum.PlayerActions.CharacterBackward,
			Enum.PlayerActions.CharacterLeft, Enum.PlayerActions.CharacterRight,
			Enum.PlayerActions.CharacterJump)
	else
		ContextActionService:UnbindAction(SINK)
	end
end

--------------------------------------------------------------------------
-- THE CARD
--------------------------------------------------------------------------

local function buildCard()
	gui = Instance.new("ScreenGui")
	gui.Name = "AfkCard"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 8
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	--[[
		THE CARD IS 224 TALL, AND IT WAS 168.

		PanelKit.card's `h` is the OUTER height and the body it hands back is
		`h - 74` -- the banner, the well inset and the bottom margin come out of
		it. So 168 gave a 94px body, and the four things laid into it are 26 + 40
		+ 18 for the labels plus a 40px button anchored to the BOTTOM: 124px of
		content in 94px of room. The button therefore sat at 54..94 and drew
		straight over both the earnings figure and the rate line, which is what
		the card actually looked like in play -- "+181", "GO BACK" and "16.3
		coins a second while you are away" all stacked on the same forty pixels.

		224 gives a 150px body. The offsets below are written as a column that
		adds up to it with room to spare, and the button is the only thing
		anchored to the bottom edge, so the two ends cannot meet in the middle
		again:

			  0.. 24   BAY n
			 26.. 72   +earned          (the big number)
			 76.. 96   the rate line
			110..150   GO BACK          (anchored bottom)
	]]
	local body, closeFace
	root, body, closeFace = PanelKit.card(gui, "THE LONG SHORE", 300, 224, C.sea)
	root.Name = "Card"
	root.AnchorPoint = Vector2.new(0.5, 1)
	--[[
		Sat 96 up while the card was 168 tall. Growing it to 224 pushes its TOP
		56px further into the screen, and what is behind this card is the thing
		the whole mode exists to watch -- your own character raking the bay.

		80 rather than 96, which is as low as it can go: the HUD's tutorial line
		runs at y 667..703 in an 801-tall viewport, and at 72 the card's bottom
		edge landed on 671 and clipped the top of it. 80 puts the card at
		431..655 -- twelve pixels clear of the text, sixteen lower than it
		shipped. (PanelKit's glow frames still fall across the subtitle and
		tint it; that is every card in the game and not this one's to fix.)
	]]
	root.Position = UDim2.new(0.5, 0, 1, -80)
	-- The X would be a second way out that does not tell the server anything.
	if closeFace and closeFace.Parent then
		closeFace.Parent:Destroy()
	end

	-- NOT C.ink. The well this sits on is a 18%-to-29% dark wood gradient and
	-- ink is 15% Rec.709 luma, so the bay number was black type on a black tray
	-- -- present in every screenshot of this card and legible in none of them.
	-- sandDeep is 74% and still reads as subordinate to the green figure below.
	bayLabel = PanelKit.text(body, "BAY -", 20, Enum.Font.LuckiestGuy, C.sandDeep)
	bayLabel.Size = UDim2.new(1, 0, 0, 24)
	bayLabel.Position = UDim2.fromOffset(0, 0)

	earnedLabel = PanelKit.text(body, "+0", 34, Enum.Font.LuckiestGuy, C.limeDark)
	earnedLabel.Size = UDim2.new(1, 0, 0, 46)
	earnedLabel.Position = UDim2.fromOffset(0, 26)
	PanelKit.punch(earnedLabel, 2.5)

	-- 13 rather than 14: the body is 264 wide and the longest this line gets is
	-- a three-figure rate ("125.0 coins a second while you are away"), which at
	-- 14 measures past the edge and loses its last word to PanelKit.text's
	-- TextTruncate. Measured, not eyeballed.
	-- Lifted from a 0.35 darken (48%) to 0.18 (61%): the same dark-tray problem
	-- as the bay label above, one step less severe.
	rateLabel = PanelKit.text(body, "", 13, Enum.Font.GothamBold, PanelKit.darken(C.sandDeep, 0.18))
	rateLabel.Size = UDim2.new(1, 0, 0, 20)
	rateLabel.Position = UDim2.fromOffset(0, 76)

	local holder, face = PanelKit.chunky(body, 168, 40, C.coral, 12)
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.new(0.5, 0, 1, 0)
	local go = PanelKit.text(face, "GO BACK", 18, Enum.Font.LuckiestGuy, C.white)
	go.Size = UDim2.fromScale(1, 1)
	PanelKit.punch(go, 2)
	TouchFit.press(face, function()
		Net.get("AfkControl"):FireServer("leave")
	end)

	UiFit.fit(gui)
end

local function paint()
	if not root then
		return
	end
	if not state then
		gui.Enabled = false
		return
	end
	gui.Enabled = true
	bayLabel.Text = ("BAY %d"):format(state.bay or 0)

	--[[
		COMPACT ABOVE A THOUSAND, ONE DECIMAL BELOW IT.

		The rate is coins per SECOND and it scales with the run now (see
		AfkConfig.TideGrowth), so across a full forty tides it runs from 1.2 to
		about 172,000. "%.1f" was right for the first and unreadable for the
		second: the note on rateLabel's font size measured this line's room as a
		three-figure rate, and "171602.5" is eight characters before the word
		"coins" -- PanelKit.text truncates, so the sentence would have lost its
		last word rather than wrapped.

		The decimal is kept where it fits because "2.0" reads as a RATE and "2"
		reads as a count, and on the tutorial tide that distinction is the whole
		of what the line is saying.

		The earnings figure gets the same treatment for the same reason -- one
		capped session on the last tide banks about 309M, which is nine digits at
		34pt in a 264px well.
	]]
	local rate = state.rate or 0
	earnedLabel.Text = "+" .. PanelKit.compact(state.earned or 0)
	rateLabel.Text = ("%s coins a second while you are away"):format(
		(rate < 1000) and ("%.1f"):format(rate) or PanelKit.compact(rate))
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

function AfkClient.start()
	if started then
		return
	end
	started = true

	buildCard()

	Net.get("AfkSync").OnClientEvent:Connect(function(snap)
		state = snap
		if snap and snap.bay then
			sinkInput(true)
			startWalk(snap.bay)
		else
			sinkInput(false)
			-- FALSE, not "go and look at the attribute". A nil payload IS the
			-- server saying the visit is over, and it can arrive before AfkPlot
			-- has cleared on this client -- see the note on restoreSpeed.
			stopWalk(false)
		end
		paint()
	end)

	-- The earned figure moves once a second and the rest of the payload does
	-- not, so it is followed off the attribute rather than by re-syncing the
	-- whole card every tick.
	player:GetAttributeChangedSignal(AfkConfig.EarnedAttr):Connect(function()
		if state then
			state.earned = player:GetAttribute(AfkConfig.EarnedAttr) or 0
			paint()
		end
	end)

	--[[
		A VISIT CANNOT SURVIVE A RESPAWN, and the client has to agree with the
		server about that. AfkService ends the visit on CharacterAdded; this is
		the same event on this side, so the sinks and the walk stop even if the
		sync message is late.
	]]
	player.CharacterAdded:Connect(function()
		if not AfkConfig.plotOf(player) then
			state = nil
			sinkInput(false)
			stopWalk(false)
			paint()
		end
	end)
end

return AfkClient