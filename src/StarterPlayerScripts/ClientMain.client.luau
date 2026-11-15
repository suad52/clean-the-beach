--[[
	ClientMain  --  StarterPlayerScripts.ClientMain  (LocalScript)

	The one client boot script. Every other client file is a ModuleScript with a
	.start(), for the same reason the server has one ServerMain: explicit order
	instead of whatever order Roblox happens to run N sibling LocalScripts in.

	Order:
		1. Inventory mirror  -- must be listening BEFORE any HUD renders, or the
		                        first sync arrives with nobody home.
		2. HUDs              -- carried panel, feedback toasts, reveal card.
		3. Wash              -- last: it is the only one that takes over the
		                        camera and the controls.

	THE BAY IS A MATCHED PAIR
	-------------------------
	WashClientController talks the Wash* remotes and WashServer fires them;
	SiftClientController talks Sift* and SiftServer fires those. ServerMain runs
	WashServer, so this runs WashClientController -- and the two must be switched
	over TOGETHER. A mismatch does not error: the server opens a session nobody on
	the client is listening for, and the player gets a lump on the stand and no
	way to touch it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Modules = ReplicatedStorage:WaitForChild("Modules")

-- No hotbar. The one Tool in the game -- the Power Washer -- is LENT OUT by the
-- bay for the length of a wash and taken back at the end of it (see
-- WasherTool.equip/stow), and the server equips it into the player's hand
-- directly, so it never needs a slot. Leaving the backpack on put an empty
-- hotbar at the bottom of the screen, directly over CTB_HUD's hint line, for
-- the 99% of the session when there is nothing to hold.
--
-- WasherTool's `wanted` flag is the other half of this: with no hotbar a player
-- has no way to re-equip, so anything that unequips the washer mid-wash is
-- undone automatically.
--
-- Spawned, and retried: SetCoreGuiEnabled throws if the CoreGui has not
-- finished booting, which is a coin toss this early in a LocalScript, and a
-- blocking retry here would hold up every start() below it.
task.spawn(function()
	for _ = 1, 30 do
		if pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Backpack, false) then
			return
		end
		task.wait(0.1)
	end
	warn("[BeachCleanup] could not switch the backpack UI off")
end)
local InventoryController = require(Modules:WaitForChild("InventoryController"))

local here = script.Parent
local InventoryHud = require(here:WaitForChild("InventoryHud"))
local FeedbackClient = require(here:WaitForChild("FeedbackClient"))
local RevealPopup = require(here:WaitForChild("RevealPopup"))
local MenuHud = require(here:WaitForChild("MenuHud"))
local RebirthCinema = require(here:WaitForChild("RebirthCinema"))
local IntroCinema = require(here:WaitForChild("IntroCinema"))
local WashClientController = require(here:WaitForChild("WashClientController"))
local AfkClient = require(here:WaitForChild("AfkClient"))
local DuelClient = require(here:WaitForChild("DuelClient"))
local FeedbackAdminHud = require(here:WaitForChild("FeedbackAdminHud"))
local TutorialHud = require(here:WaitForChild("TutorialHud"))
local RebirthUnlockPrompt = require(here:WaitForChild("RebirthUnlockPrompt"))
local FreeRewardPanel = require(here:WaitForChild("FreeRewardPanel"))
local TipClient = require(here:WaitForChild("TipClient"))
local SandbotClient = require(here:WaitForChild("SandbotClient"))
local LeaderboardRank = require(here:WaitForChild("LeaderboardRank"))
local BoostHud = require(here:WaitForChild("BoostHud"))
local NextShoreHud = require(here:WaitForChild("NextShoreHud"))
local TravelHud = require(here:WaitForChild("TravelHud"))

-- Notifications first: every other system below can fire one during its own
-- start(), and the kit builds its ScreenGui on demand anyway -- but standing it
-- up here means the very first toast is not the one paying to build it.
local ToastKit = require(Modules:WaitForChild("ToastKit"))
ToastKit.start()

--[[
	EVERY PROXIMITY PROMPT IN THE GAME IS TIED WITH THE THUMBSTICK, AND A TIE IS
	NOT AN ORDERING.

	Roblox builds the prompt layer itself, as a ScreenGui called "ProximityPrompts"
	in the PlayerGui, and leaves its DisplayOrder at 0 -- which is the SAME number
	Roblox's own TouchGui uses for the DynamicThumbstick and the jump button.
	Measured in Play: DisplayOrder=0, ZIndexBehavior Global.

	CTB_HUD has already written up what that costs, with numbers: it defaulted to
	0 for the same reason, and GetGuiObjectsAtPosition put the thumbstick ABOVE
	QUICK SELL -- 26 of the pad's 44 pixels dead, a tap there starting a movement
	drag instead of pressing the button. The fix there was DisplayOrder = 1.

	THE WASH BAY PROMPTS SIT IN THE SAME BAND. The thumbstick claims x -100..266,
	y 105..416 on a 666x374 phone. The bay's two prompt buttons are 72px tall and
	project to roughly y 101..213 on a screen that size, centred horizontally --
	so a 192-wide button spans about x 237..429 and its left edge is inside the
	thumbstick's x range. Not the whole button, but its left-hand end, on the one
	control in the wash bay that destroys something.

	SUSPECTED RATHER THAN PROVEN, and said plainly: this cannot be measured on a
	desktop, where there is no TouchGui to tie with. It is here because the
	precedent is documented in this game with real numbers, because a player who
	had already reported the throw-away button twice reported it again from a
	750x390 phone, and because raising a DisplayOrder cannot break anything.

	2, not 1: above TouchGui and above CTB_HUD's own column, and still far below
	the toast stack (16) and every panel (40+). A world-anchored prompt should
	pass over the coin pill and under a menu.

	WATCHED RATHER THAN SET ONCE. The layer is built on demand -- it does not
	exist at boot and is created the first time a prompt comes into range -- so
	setting it here and walking away would set nothing at all.
]]
do
	local playerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
	local function lift(child: Instance)
		if child:IsA("ScreenGui") and child.Name == "ProximityPrompts" then
			child.DisplayOrder = 2
		end
	end
	for _, c in playerGui:GetChildren() do
		lift(c)
	end
	playerGui.ChildAdded:Connect(lift)
end

-- THE OPENING SHOT, AND IT IS FIRST BECAUSE OF WHAT IT PUTS UP, NOT WHAT IT
-- DOES. IntroCinema.start() is synchronous only as far as raising an opaque
-- black ScreenGui; the sequence itself is on its own thread. Starting it here
-- means the curtain is up before the spawn, the walk out to the shore and the
-- terrain stream that follow it -- all of which are meant to happen behind it.
--
-- It hides the other HUDs by name and re-sweeps once a second, so it does not
-- care that every one of them is started below this line.
IntroCinema.start()

InventoryController.Client.start()

InventoryHud.start()
FeedbackClient.start()
RevealPopup.start()
MenuHud.start()
-- After MenuHud, because the rebirth cinematic switches MenuHud's ScreenGui off
-- for the length of the shot and back on at the end -- so the gui has to exist
-- before the first message could arrive.
RebirthCinema.start()
WashClientController.start()
-- The idle shore's puppet and card. Last, and order-independent: it does
-- nothing at all until the server sends an AfkSync, and its card is built
-- disabled.
AfkClient.start()
-- The 1v1 arenas. Also order-independent: it draws nothing until either a
-- DuelInvite arrives or the player clicks somebody.
DuelClient.start()

-- The feedback inbox. Last and unconditional: start() only asks the server
-- whether this client may have it, and builds nothing at all unless the answer
-- comes back yes -- so on an ordinary player's machine this costs one remote.
FeedbackAdminHud.start()

-- The four-step card. Order-independent and cheap to call: start() returns
-- immediately, and the thread behind it builds nothing unless the player looks
-- new AND the opening shot has finished. It is last because it is the one
-- thing here nobody needs -- if it ever throws, everything above it is already
-- up.
TutorialHud.start()

-- The first-rebirth nudge. Order-independent and cheap to call: start() only
-- wires the ProgressionSync listener, and the card itself is built lazily the
-- first time the gate is actually crossed -- which for most players is well
-- after this line runs.
RebirthUnlockPrompt.start()

--[[
	HOW CLOSE THE FIRST ISLAND IS, for tide 0 only. Deliberately NEXT TO the line
	above: the two are the same conversation at opposite ends of it -- this one
	pulls a new player toward the gate, that one meets them when they arrive, and
	this one switches itself off on the push that raises that card so the two are
	never on screen together.

	Same shape and the same cost as its neighbour: start() wires the
	ProgressionSync listener and nothing else, and the pill is built lazily on the
	first snapshot that shows a tide-0 player short of the gate -- so a returning
	veteran never allocates it at all.
]]
NextShoreHud.start()

--[[
	Quick travel across the island you are on. Late and unconditional: it owns
	one ScreenGui and one card, reads the world fresh every time it opens, and
	nothing above it depends on it. It has no remote -- every destination it
	offers is on the island the player is already standing on, so there is
	nothing for a server to check.
]]
TravelHud.start()

-- The free reward card. Built now, SHOWN later: start() only wires the remote
-- and the board's prompt, and the pop-up itself waits for the server's first
-- sync and for the opening shot's curtain to come down. Last, alongside
-- TutorialHud, and for the same reason -- nothing above it depends on it.
FreeRewardPanel.start()

-- The hint band at the top of the screen. Last, and the least urgent thing in
-- this file: start() registers the chat commands and spawns a wait loop that
-- does not put anything on screen for TipConfig.FirstDelay seconds, so nothing
-- above it is waiting on this and nothing here is racing the boot.
TipClient.start()

--[[
	THE SANDBOT'S CLIENT HALF, AND IT DRAWS NOTHING.

	This used to be SandbotHud -- a key on the left column that was a storefront
	when you did not own the pass and a DEPLOY button when you did. The drone is
	sent out from the SANDBOT HOME beside each island's car spawner now, so
	there is no key: what is left is the brush spin (a local write to a
	server-owned joint, which replicates nowhere) and the purchase dialog, which
	only a client can open.

	Last, and order-independent: it puts up no ScreenGui, and its RenderStepped
	loop finds nothing until somebody's drone is out.
]]
SandbotClient.start()

-- The "where you stand" plaques over the world boards. Last, and about as
-- order-independent as anything here gets: start() wires one attribute listener
-- and then waits on workspace.Leaderboards, which the server has not necessarily
-- finished building yet. Nothing above it depends on it and it draws nothing at
-- all until a board is within ninety studs.
LeaderboardRank.start()

-- The bought golden hour's countdown, at the foot of the money column. Last and
-- order-independent: it reads two player attributes and draws nothing at all
-- unless one of them says a boost is running, which for most sessions is never.
BoostHud.start()

print("[BeachCleanup] client ready")
