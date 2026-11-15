--[[
	SignDresser  --  ServerScriptService.SignDresser

	Puts every sign in the world through SignKit, at runtime.

	WHY THIS EXISTS AT ALL, AND NOT JUST IN THE BUILDERS
	----------------------------------------------------
	Only some of these boards come from a builder. SellArea's and UpgradeKiosk's
	are AUTHORED in the place file and belong to Clean the Beach itself, and the
	wash bay and car spawner models are authored-and-tagged too -- which means
	their builders adopt what is already there and never run their own sign code.
	Fixing the builders alone changes nothing you can see.

	So this re-asserts the style over whatever is standing, the same way
	CTB_Server re-asserts the skybox and LightingLock re-asserts the clock. The
	builders were fixed as well, for the day someone deletes a model and one gets
	rebuilt from scratch -- but this is the pass that actually decides.

	WHAT IT DELIBERATELY DOES NOT DO
	--------------------------------
	It does not create boards, move them, or repaint the timber. Each building
	keeps its own colour -- sea blue for the bay, gold for the shop, amber for the
	car pad, pale sand for the Bazaar -- because the row reads as four buildings,
	not one. It is the LETTERING that becomes one system.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local SignKit = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("SignKit"))

local SignDresser = {}

local BACK_FRONT = { Enum.NormalId.Back, Enum.NormalId.Front }
local LEFT_RIGHT = { Enum.NormalId.Left, Enum.NormalId.Right }

--[[
	THE ROW, LEFT TO RIGHT ALONG THE BEACH.

	`tag` resolves the model where one carries a tag (those two are adopted, so
	their path is whatever the place file happens to call them); `path` is a
	dot-walk from workspace for the rest.

	The text is spelled out here rather than left to whatever each board was
	saved with, because two of them disagreed with THEMSELVES: SellArea's board
	said "SELL" on one side and "[coin] SELL HERE [coin]" on the other. One board,
	one name, both faces.
]]
local SIGNS = {
	{ tag = "CarSpawner", board = "SignBoard", faces = LEFT_RIGHT, text = "CAR SPAWN" },
	{ tag = "WashBay", board = "SignBoard", faces = BACK_FRONT, text = "WASH BAY" },
	{ path = "Beach.SellArea", board = "SignBoard", faces = BACK_FRONT, text = "SELL HERE" },
	-- The index used to be a desk standing on open sand between two shacks, which
	-- is why it had no board to dress. It is a shack now, built off SellArea's
	-- shell at a narrower span, so it joins the row and the row's lettering.
	{ path = "Beach.IndexTerminal", board = "SignBoard", faces = BACK_FRONT, text = "INDEX" },
	{ path = "Beach.Store", board = "StockBoard", faces = { Enum.NormalId.Back },
		text = "SIFTERS  BUCKETS  BOOTS" },
	-- The one sign whose colour means something rather than decorating: green is
	-- what "open" looks like on a shop door. It keeps the row's outline and face,
	-- so it still belongs to the set.
	{ path = "Beach.Store", board = "OpenSign", faces = { Enum.NormalId.Back },
		text = "OPEN", tint = Color3.fromRGB(150, 230, 160) },
	-- NOT the desert. Island2Builder REBUILDS its island on every boot, and it
	-- runs from CTB_Server on its own schedule -- measured: it replaced the
	-- Bazaar and the gates a beat AFTER this pass had dressed them, and both
	-- reverted. Those signs go through SignKit inside that builder instead, where
	-- nothing can come along afterwards and overwrite them.
}

--[[
	The two labels that float in the world rather than sitting on a board. They
	are signs by every measure that matters -- the player reads them off the
	scenery -- and the sell pad's was the last FredokaOne left on the beachfront,
	standing two studs from a board that now reads LuckiestGuy.

	It keeps its colour -- mint says the pad is live. Only the face and the
	outline are made to match.
]]
local FLOATING = {
	{ path = "Beach.SellArea.SellPad", gui = "SellPrompt",
		tint = Color3.fromRGB(214, 255, 226) },
	-- The desert's gate boards and the pyramid door hint are dressed by
	-- Island2Builder, for the rebuild reason noted on SIGNS above.
}

local function resolve(entry): BasePart?
	local model
	if entry.tag then
		model = CollectionService:GetTagged(entry.tag)[1]
	else
		model = workspace
		for segment in string.gmatch(entry.path, "[^%.]+") do
			model = model and model:FindFirstChild(segment)
		end
	end
	if not model then
		return nil
	end
	-- Recursive: SellArea's board hangs off a sub-model, the Store's sits at the
	-- top level, and which is which is not worth encoding here.
	local board = model:FindFirstChild(entry.board, true)
	return (board and board:IsA("BasePart")) and board or nil
end

--------------------------------------------------------------------------
-- THE KIOSK, WHICH IS THE ONE BOARD WITH TWO ROWS
--------------------------------------------------------------------------
--[[
	Handled apart from the table because its second label is LIVE: CTB_Client
	writes the player's own sifter level into `Info` every time it changes, and
	it reaches that label by name through `Board.KioskGui.Info`. So the names of
	the SurfaceGui and of that label are load-bearing and nothing here may rename
	either -- only the font, colour and outline are ours to set. (A server-side
	style write replicates; the client's text write does not, which is exactly
	the split that keeps the board private per player.)
]]
local function dressKiosk()
	local beach = workspace:FindFirstChild("Beach")
	local kiosk = beach and beach:FindFirstChild("UpgradeKiosk")
	local board = kiosk and kiosk:FindFirstChild("Board", true)
	if not (board and board:IsA("BasePart")) then
		warn("[SignDresser] no Beach.UpgradeKiosk.Board -- the shop sign keeps its old face")
		return false
	end

	local gui = board:FindFirstChildWhichIsA("SurfaceGui")
	if not gui then
		warn("[SignDresser] the kiosk board carries no SurfaceGui")
		return false
	end

	-- ONE ROW NOW. This board used to carry a name and a "Lv.1 * 9 studs"
	-- readout under it, so neither got the centred full-height slot a one-line
	-- sign takes -- the name was pinned to the top 0.44 and the readout to the
	-- bottom 0.30. The readout is gone (owner's call, 2026-08-21) and the layout
	-- goes with it: leaving the name at 0.08 would ride it high on a board with
	-- an empty bottom third.
	local NAME_BOX = Vector2.new(0.92, 0.66)

	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = SignKit.canvasFor(board, gui.Face, NAME_BOX.Y)
	gui.LightInfluence = 0
	local canvas = gui.CanvasSize

	-- Any stale Info label from before the readout was dropped. Removed here
	-- rather than left hidden: SignKit.sub is no longer called on it, so left in
	-- place it would render at whatever size and position it was last saved at.
	local info = gui:FindFirstChild("Info")
	if info then
		info:Destroy()
	end

	for _, label in ipairs(gui:GetChildren()) do
		if label:IsA("TextLabel") then
			label.Text = "UPGRADES"
			SignKit.name(label, board, gui.Face)
			-- Re-placed and re-fitted AFTER name(), which sizes to the whole face.
			label.AnchorPoint = Vector2.new(0.5, 0.5)
			label.Position = UDim2.fromScale(0.5, 0.5)
			label.Size = UDim2.fromScale(NAME_BOX.X, NAME_BOX.Y)
			SignKit.fitOneLine(label, Vector2.new(canvas.X * NAME_BOX.X, canvas.Y * NAME_BOX.Y))
		end
	end
	return true
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

local started = false
function SignDresser.start()
	assert(RunService:IsServer(), "[SignDresser] server-only")
	if started then
		return
	end
	started = true

	local done, missing = 0, {}
	for _, entry in ipairs(SIGNS) do
		local board = resolve(entry)
		if board then
			SignKit.dress(board, entry.text, entry.faces, entry.tint)
			done += 1
		else
			table.insert(missing, (entry.tag or entry.path) .. "." .. entry.board)
		end
	end
	if dressKiosk() then
		done += 1
	end

	for _, entry in ipairs(FLOATING) do
		local node = workspace
		for segment in string.gmatch(entry.path, "[^%.]+") do
			node = node and node:FindFirstChild(segment)
		end
		local gui = node and node:FindFirstChild(entry.gui)
		local label = gui and gui:FindFirstChildWhichIsA("TextLabel")
		if label then
			SignKit.floating(label, entry.tint)
			done += 1
		else
			table.insert(missing, entry.path .. "." .. entry.gui)
		end
	end

	-- Named, not counted. A sign that quietly did not get dressed is the exact
	-- failure this module exists to stop, and "6 of 7" does not say which one.
	if #missing > 0 then
		warn("[SignDresser] could not find: " .. table.concat(missing, ", "))
	end
	print(string.format("[SignDresser] %d signs on one face", done))
end

return SignDresser
