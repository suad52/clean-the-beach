--[[
	PanelWatch  --  StarterPlayer.StarterPlayerScripts.PanelWatch  (LocalScript)

	A PANEL IS UP, SO GIVE THE PLAYER BACK THEIR POINTER AND THEIR DISTANCE.

	First person pins the mouse to the middle of the screen. That is the default
	camera's doing and it is how first person works everywhere -- but it means
	that the moment a panel opens, the player is holding a cursor they cannot
	move. They can see the Beach Shop and they cannot press anything on it, and
	they cannot click off it either. Shift lock does exactly the same thing in
	third person, so this was never only a first-person problem; it was only ever
	invisible because nobody could reach first person before.

	TWO THINGS HAPPEN HERE AND THEY ARE DELIBERATELY INDEPENDENT. One of them
	fixes the bug and the other one is the part you can see.

	THE POINTER IS FREED BY A MODAL BUTTON -- one invisible GuiButton with
	`Modal` set. Modal is an engine-level override of MouseBehavior rather than
	another script writing the same property, which is what makes it the right
	tool: the camera writes LockCenter every single frame, so anything that
	competes by writing loses, and something applied after the write does not.
	It is also the only half of this that helps a player in shift lock, or one
	using Camera Toggle, neither of whom gets their cursor back from a zoom.

	IT LIVES IN THIS SCRIPT'S OWN ScreenGui, which is not fussiness. Modal only
	counts while the button is Visible, and Visible walks the whole ancestor
	chain -- and RebirthCinema and IntroCinema switch other people's guis off by
	name for the length of a cutscene. Parked inside one of those, the pointer
	would silently re-lock halfway through, with nothing to read as a cause.

	THE CAMERA IS PULLED BACK because reading a shop menu from inside your own
	head is not reading it. That half only fires if the player was ACTUALLY in
	first person when the panel opened, so a third-person player's framing is
	never touched by any of this.

	GETTING BACK IN IS NOT THE SAME WRITE BACKWARDS, and this is the trap worth
	the paragraph. Raising CameraMinZoomDistance pushes the camera out, because
	the camera re-clamps its current distance the moment the property changes.
	LOWERING IT AGAIN DOES NOTHING: the same clamp runs on the distance it now
	has, and twelve clamped between 0.5 and 70 is twelve. The obvious symmetric
	release leaves the player in third person for the rest of the session, and it
	TESTS AS WORKING -- the panel opens, the camera pulls back, the panel closes,
	nothing looks broken, and first person is quietly gone until they rejoin.

	The way back in is CameraMode.LockFirstPerson: the one branch that ignores
	the minimum entirely and pins the distance at 0.5. So the mode is set, the
	minimum is restored underneath it, and the mode goes back to Classic -- in
	that order, because Classic re-clamps against whatever the minimum is by
	then, and by then it is 0.5 again.

	AND IT TAKES TWO TICKS TO DO IT, which is the part that cost a test run.
	Written as three statements in a row it does nothing at all: property changed
	signals are DEFERRED, so all three land before the camera hears about any of
	them, and what it finally reads is Classic with a minimum of 0.5 and a
	distance of twelve -- which clamps to twelve. Measured: the camera pulled out
	on open, the panel closed, and the player stayed at twelve studs with every
	property apparently correct. So the mode goes on in one sweep and the
	minimum comes back in the NEXT one, a tenth of a second later, by which time
	the camera has read the mode and pinned the distance at 0.5.

	WHAT COUNTS AS A PANEL. Every card in the game is built by PanelKit.card,
	which tags its root. A tagged root is OPEN when the root is Visible AND the
	ScreenGui above it is Enabled. Both tests are needed -- see the note by
	PanelKit.Tag for why the callers are split down the middle -- and either one
	on its own reports half the panels in the game wrong in one direction or the
	other.

	THE STATE IS SWEPT, NOT COUNTED. Every tick this recounts from scratch
	rather than incrementing on an open signal and decrementing on a close one,
	because the counting version fails in the one way that matters: a panel
	destroyed while open, or a close path that throws, leaves the count above
	zero, and the player is then permanently unable to zoom in with nothing on
	screen to explain why. A recount cannot get stuck.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local PanelKit = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("PanelKit"))

local player = Players.LocalPlayer

--[[
	GUIS THAT ARE NOT PANELS EVEN WHEN THEY HOLD A CARD.

	Three different kinds, and all three would misbehave if they were counted:

	  A SESSION THAT OWNS THE CAMERA. WashHud, the vault, a rebirth, the ferry
	  CROSSING. These drive the camera themselves, so the zoom write would be a
	  no-op anyway -- the camera controller is torn down under a Scriptable
	  camera and there is nothing left to re-clamp -- and we would be left
	  thinking we had pulled somebody back who was never moved.

	  SOMETHING WORN FOR THE WHOLE OF AN ACTIVITY. DriveHud is Enabled for the
	  entire length of a drive. Counted as a panel, it would hold the camera out
	  and the pointer loose from the moment you got in a machine until you got
	  out of it.

	  PERMANENT CHROME. The bag, the weight bar, the toast column, the tutorial
	  card. These are never "open"; they are just there.
]]
local IGNORE = {
	WashHud = true,
	VaultCinema = true,
	RebirthCinema = true,
	FerryTransit = true,
	DriveHud = true,
	TutorialHud = true,
	ToastKit = true,
	CleanTheBeachHUD = true,
	WeightHUD = true,
	InventoryHud = true,
	PetUI = true,
	StairHud = true,
	FeedbackHud = true,
}

-- Far enough back to read a card over your own shoulder, close enough that it
-- does not read as the camera being yanked. The game's own resting distance is
-- around twenty.
local PANEL_MIN = 12

-- StarterPlayer's floor, which is what the player is put back on.
local FOOT_MIN = 0.5

-- BaseCamera's FIRST_PERSON_DISTANCE_THRESHOLD. Under it the camera snaps the
-- distance to 0.5 and calls itself first person, so the test never straddles.
local FIRST_PERSON = 1.0

local SWEEP = 0.1

----------------------------------------------------------------
-- THE BUTTON THAT FREES THE POINTER
----------------------------------------------------------------
-- One pixel, fully transparent, in the corner. Size and position are not the
-- point -- Modal is a property test, not a coverage test -- but a button with
-- no size at all is a thing the engine is entitled to skip, so it gets one.
local gui = Instance.new("ScreenGui")
gui.Name = "PanelCursor"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = -1
gui.Parent = player:WaitForChild("PlayerGui")

local freeMouse = Instance.new("TextButton")
freeMouse.Name = "FreeMouse"
freeMouse.Modal = true
freeMouse.Visible = false
freeMouse.Text = ""
freeMouse.AutoButtonColor = false
freeMouse.BackgroundTransparency = 1
freeMouse.Size = UDim2.fromOffset(1, 1)
freeMouse.Position = UDim2.fromOffset(0, 0)
freeMouse.ZIndex = 0
freeMouse.Selectable = false
freeMouse.Parent = gui

----------------------------------------------------------------
-- IS ANYTHING UP
----------------------------------------------------------------
local function anyPanelOpen(): boolean
	for _, root in CollectionService:GetTagged(PanelKit.Tag) do
		if root:IsA("GuiObject") and root.Visible then
			local screen = root:FindFirstAncestorWhichIsA("ScreenGui")
			if screen and screen.Enabled and not IGNORE[screen.Name] then
				return true
			end
		end
	end
	return false
end

----------------------------------------------------------------
-- HOLDING AND LETTING GO
----------------------------------------------------------------
local held = false
-- Whether the player was at the eyes when the first panel went up, and so
-- whether there is anywhere to put them back. Cleared if they scroll out
-- themselves while the panel is up -- see the sweep.
local restoreFirstPerson = false
-- Step one of the way back in has been done and step two is owed. See the
-- header: the two cannot happen in the same breath.
local restorePending = false

local function distance(cam: Camera): number
	return (cam.Focus.Position - cam.CFrame.Position).Magnitude
end

local function acquire()
	if held then
		return
	end
	held = true
	-- ONLY WHERE THERE IS A POINTER TO FREE. A phone never had the problem: a
	-- tap lands on a button whatever the camera is doing. And Modal has a
	-- second, quieter effect that would be a real loss there -- a visible Modal
	-- button switches the touch controls off, so the thumbstick would vanish
	-- every time a card came up. Asked at the moment of use rather than at
	-- startup, because a mouse can arrive after the game has loaded.
	freeMouse.Visible = UserInputService.MouseEnabled

	local cam = workspace.CurrentCamera
	restoreFirstPerson = cam ~= nil
		and cam.CameraType == Enum.CameraType.Custom
		and distance(cam) < FIRST_PERSON
	if restoreFirstPerson then
		player.CameraMinZoomDistance = PANEL_MIN
	end
end

-- Step two of the way back in, run a sweep after step one. Idempotent, called
-- from both arms of the sweep and from a respawn, because the one state this
-- script must never leave behind is a player locked into first person by a
-- CameraMode nobody put back.
local function finishRestore()
	if not restorePending then
		return
	end
	--[[
		THE FLAG IS CLEARED LAST, AND THE ORDER IS THE WHOLE POINT.

		Clearing it first meant that anything going wrong between here and the
		second write -- an error, a value the engine refuses -- left the player in
		LockFirstPerson with `restorePending` ALREADY false, so no later sweep
		ever tried again. On a desktop the wheel IS the camera, so that is a
		player who cannot zoom at all until they rejoin, which is exactly the one
		state the header says this script must never leave behind. Writing first
		and clearing after costs nothing and makes the retry the default.

		No path is known to throw here. This is the invariant being held by the
		code rather than by the absence of a reason to break it.
	]]
	player.CameraMinZoomDistance = FOOT_MIN
	player.CameraMode = Enum.CameraMode.Classic
	restorePending = false
end

local function release()
	if not held then
		return
	end
	held = false
	freeMouse.Visible = false

	if not restoreFirstPerson then
		return
	end
	restoreFirstPerson = false

	local cam = workspace.CurrentCamera
	if cam and cam.CameraType == Enum.CameraType.Custom then
		-- Step one. The minimum stays at twelve for another tenth of a second and
		-- it does not matter: LockFirstPerson is the branch that never reads it.
		player.CameraMode = Enum.CameraMode.LockFirstPerson
		restorePending = true
	else
		-- A cutscene took the camera while the panel was up. Give the floor back
		-- and leave the framing to whoever owns it now; scrolling in is possible
		-- again the moment they hand it back.
		player.CameraMinZoomDistance = FOOT_MIN
	end
end

-- A respawn does not close anything -- every gui in this place is
-- ResetOnSpawn = false -- but it is the one moment worth being certain we are
-- not holding something we can no longer see a reason for. The sweep takes it
-- straight back if a panel really is still up.
player.CharacterAdded:Connect(function()
	release()
	finishRestore()
end)

local since = 0
RunService.Heartbeat:Connect(function(dt)
	since -= dt
	if since > 0 then
		return
	end
	since = SWEEP

	if anyPanelOpen() then
		-- Land any restore still in flight before taking the camera again, so the
		-- mode is never read as LockFirstPerson by the acquire below.
		finishRestore()
		acquire()
		-- THEY MAY HAVE SCROLLED OUT ON PURPOSE while the card was up, and if
		-- they did, dropping them back into first person on close would be us
		-- overriding a decision they just made. The spring only ever travels
		-- from 0.5 UP TO PANEL_MIN on the way out, and occlusion can only pull
		-- the camera in, so anything past it is a hand on the wheel.
		if restoreFirstPerson then
			local cam = workspace.CurrentCamera
			if cam and distance(cam) > PANEL_MIN + 1 then
				restoreFirstPerson = false
				player.CameraMinZoomDistance = FOOT_MIN
			end
		end
	elseif held then
		release()
	else
		finishRestore()
	end
end)
