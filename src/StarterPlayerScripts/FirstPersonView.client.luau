--[[
	FirstPersonView  --  StarterPlayer.StarterPlayerScripts.FirstPersonView  (LocalScript)

	YOUR ARMS STAY ON WHEN YOU SCROLL ALL THE WAY IN.

	CameraMinZoomDistance is 0.5, so the camera comes all the way to the eyes.
	The sifter is still drawn there -- it is a model in Workspace, placed off the
	character's root, and the engine's first-person fade never touches it. What
	the engine DOES take away is the character, all of it, and that included the
	two arms reaching out to the handlebar. The result was a wheelbarrow steering
	itself a stud and a half in front of nobody.

	So the arms are put back. Six parts on an R15 rig, two on an R6 one, held at
	zero every frame while the camera is at the eyes.

	EVERY FRAME, NOT ONCE -- and this is the whole reason the script is a
	RenderStep rather than a pair of signals. TransparencyController computes an
	alpha of exactly 1.0 in first person, and at exactly 1.0 its own tween guard
	fails, which marks the character dirty AGAIN on the next frame. It is not a
	write-once-and-settle: it rewrites LocalTransparencyModifier on every cached
	part of the character on every single frame, forever, for as long as you are
	zoomed in. A one-shot write here would be undone before it was ever drawn.

	AT Camera + 1, for the same reason. The camera module runs its whole update,
	transparency included, at Enum.RenderPriority.Camera.Value. Binding one above
	it is what puts this write after theirs in the same frame instead of before
	it. (WashClientController is already at Camera + 5 on the same principle.)

	NOTHING IS RESTORED ON THE WAY OUT, deliberately. Letting go means letting
	the camera module have the parts back, and it writes them the very next frame
	-- 1 while you are still zoomed in, 0 once you scroll out. Writing our own 0
	on release would be the bug rather than the tidy-up: the wash bay hides the
	whole character for the length of a session, and a helpful zero on the way
	out would put an arm back in the middle of somebody's cutaway.

	WHICH IS ALSO WHY A SCRIPTABLE CAMERA IS LEFT ALONE. The intro, a rebirth,
	the ferry crossing, the vault and the wash bay all drive the camera
	themselves and several of them clear the character out of the shot on
	purpose. Custom-only, and seated is skipped too -- there is no bar to reach
	for from a driver's seat, and the arms the engine hides there are folded in
	a lap.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

-- Both rigs. A character only ever has one set, and FindFirstChild on the other
-- four names costs nothing worth measuring.
local ARMS = {
	"LeftUpperArm", "LeftLowerArm", "LeftHand",
	"RightUpperArm", "RightLowerArm", "RightHand",
	"Left Arm", "Right Arm",
}

-- BaseCamera's own FIRST_PERSON_DISTANCE_THRESHOLD. Below this it snaps the
-- distance to 0.5 and calls itself first person, so the test never straddles.
local FIRST_PERSON = 1.0

RunService:BindToRenderStep("CTB_FirstPersonArms", Enum.RenderPriority.Camera.Value + 1, function()
	local cam = workspace.CurrentCamera
	if not cam or cam.CameraType ~= Enum.CameraType.Custom then
		return
	end

	local char = player.Character
	if not char then
		return
	end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.SeatPart ~= nil then
		return
	end

	--[[
		AND THE PLAYER MAY SAY NO -- Settings -> "Hide Your Arms", off by default.

		RETURNING IS THE WHOLE IMPLEMENTATION, and that is the header's doing: this
		script never restores anything on the way out, because the camera module
		rewrites LocalTransparencyModifier on every cached part every frame anyway.
		So declining to write is enough -- the engine's own first-person fade has
		the parts back on the very next frame, which is exactly the state this
		script exists to override.

		Read per frame rather than cached, so the switch takes effect while the
		player is still looking at the panel that flipped it.
	]]
	if player:GetAttribute("Set_HideArms") == true then
		return
	end

	if (cam.Focus.Position - cam.CFrame.Position).Magnitude >= FIRST_PERSON then
		return
	end

	for _, name in ARMS do
		local part = char:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			part.LocalTransparencyModifier = 0
		end
	end
end)
