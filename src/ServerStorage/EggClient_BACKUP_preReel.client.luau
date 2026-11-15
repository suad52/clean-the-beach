--[[
	EggClient  --  StarterPlayer.StarterPlayerScripts.EggClient  (LocalScript)

	Three jobs, in order of how often they run:

		1. IDLE      every egg on every plaza bobs and turns. Done here rather
		             than with unanchored parts or server tweens because it is
		             pure decoration: twelve eggs across four islands cost the
		             server exactly nothing this way.
		2. HATCH     the reveal, when the server says a roll landed. Its own
		             full-screen scene -- see THE HATCH SCREEN below.
		3. THE CHIP  a small always-on readout of your three slots and the luck
		             they are worth, with click-to-unequip.

	WHAT THIS FILE IS NOT ALLOWED TO DO
	-----------------------------------
	Decide anything. The pet, the tier, the price and the deduction have all
	already happened on the server by the time HatchEgg arrives -- this plays
	back a result. There is no code path here that can change what was won, and
	the equip button sends a pet id and a boolean, never a slot index or a luck
	number.

	THE HATCH TAKES THE SCREEN, NOT THE CAMERA
	------------------------------------------
	The sequence plays on an opaque full-screen ScreenGui with the egg and the
	pet inside a ViewportFrame, so nothing in the world -- the character, the
	sifter in front of them, other players, the pedestal itself -- can be in the
	shot. The camera is never touched. Every exit from the sequence goes through
	`finish`, which is idempotent, and what it puts back is the HUDs it hid and
	the walk speed it took.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
-- No `camera` handle on purpose. The hatch used to take the CurrentCamera and
-- hand it back; it now plays on its own screen and never touches it, and a
-- module-level reference to it is the first step back to the version that did.

local Modules = ReplicatedStorage:WaitForChild("Modules")
local PetConfig = require(Modules:WaitForChild("PetConfig"))
local PetVisuals = require(Modules:WaitForChild("PetVisuals"))
local Net = require(Modules:WaitForChild("Net"))
-- The reveal is painted with the same kit as every other panel and reveal in
-- the game -- PanelKit's card, chunky button, outlined text and turntable --
-- because a hatch screen that invented its own look would read as a different
-- game's menu however well it was drawn.
local PanelKit = require(Modules:WaitForChild("PanelKit"))
local AudioKit = require(Modules:WaitForChild("AudioKit"))
local UiFit = require(Modules:WaitForChild("UiFit"))

local Debris = game:GetService("Debris")

-- No WOBBLE constant here any more. The whole scene's timing -- how long the
-- player takes to walk in, how long they stoop, when the thing inside knocks
-- and when the shell gives -- is WALK_IN, STOOP_FOR and KNOCKS inside
-- playHatch, next to the loop that reads them.

-- Forward-declared: `finish` is called from the wiring at the bottom, from the
-- card's X and from the watchdog, all of which are written before or inside
-- the function that defines it.
local finish
local playHatch

local CREAM = Color3.fromRGB(255, 252, 242)
local INK = Color3.fromRGB(52, 34, 18)

--------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------
local hatching = false
local restore = nil       -- how to put the camera back, or nil when we do not hold it
local myPets = { owned = {}, equipped = {}, luck = 1, maxEquipped = PetConfig.MaxEquipped }

--------------------------------------------------------------------------
-- UI SCAFFOLDING
--------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "PetUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 40
gui.Parent = player:WaitForChild("PlayerGui")

local function label(parent, text, size, color, scaled)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.LuckiestGuy
	l.Text = text
	l.TextSize = size
	l.TextColor3 = color or CREAM
	l.TextStrokeTransparency = 0.4
	l.TextStrokeColor3 = INK
	l.TextScaled = scaled == true
	l.Parent = parent
	return l
end

local function corner(inst, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 10)
	c.Parent = inst
	return c
end

--------------------------------------------------------------------------
-- THE LUCK CHIP
--------------------------------------------------------------------------
--[[
	Deliberately tiny. This is a persistent readout, not a menu: it says what
	your luck is and which three pets are making it, and the only interaction
	is clicking one off. Anything more belongs behind a button, not stapled to
	the corner of the screen for the whole session.
]]
local chip = Instance.new("Frame")
chip.Name = "LuckChip"
chip.AnchorPoint = Vector2.new(1, 0)
chip.Position = UDim2.new(1, -14, 0, 96)
chip.Size = UDim2.fromOffset(178, 30)
chip.BackgroundColor3 = Color3.fromRGB(28, 40, 34)
chip.BackgroundTransparency = 0.15
chip.BorderSizePixel = 0
chip.Visible = false
chip.Parent = gui
corner(chip, 8)

local chipText = label(chip, "🍀 +0%", 15, Color3.fromRGB(150, 230, 160))
chipText.Size = UDim2.new(1, -10, 0, 18)
chipText.Position = UDim2.fromOffset(5, 1)
chipText.TextXAlignment = Enum.TextXAlignment.Left

local slotRow = Instance.new("Frame")
slotRow.BackgroundTransparency = 1
slotRow.Size = UDim2.new(1, -10, 0, 9)
slotRow.Position = UDim2.fromOffset(5, 19)
slotRow.Parent = chip

local slotLayout = Instance.new("UIListLayout")
slotLayout.FillDirection = Enum.FillDirection.Horizontal
slotLayout.Padding = UDim.new(0, 3)
slotLayout.Parent = slotRow

local function refreshChip()
	local n = #myPets.equipped
	chip.Visible = n > 0 or next(myPets.owned) ~= nil
	chipText.Text = string.format("🍀 %s   %d/%d", PetConfig.luckText(myPets.luck or 1),
		n, myPets.maxEquipped or PetConfig.MaxEquipped)

	for _, c in slotRow:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	for _, petId in myPets.equipped do
		local def = PetConfig.get(petId)
		local pip = Instance.new("TextButton")
		pip.Size = UDim2.fromOffset(52, 9)
		pip.BackgroundColor3 = def and PetConfig.tierColor(def.Tier) or CREAM
		pip.BorderSizePixel = 0
		pip.Text = ""
		pip.AutoButtonColor = true
		pip.Parent = slotRow
		corner(pip, 4)

		-- Click to put it away. The server re-checks that you had it equipped,
		-- so a spoofed click is a no-op rather than an exploit.
		pip.Activated:Connect(function()
			Net.get("PetEquip"):FireServer({ petId = petId, equip = false })
		end)
	end
end

--------------------------------------------------------------------------
-- PET ART
--------------------------------------------------------------------------
-- Same suffix-matching rule the server uses, and the same tolerance for a
-- missing model: the reveal still plays, in the right tier colour.
local function petModel(def): Model?
	local root = ReplicatedStorage:FindFirstChild("Pets")
	local folder = root and root:FindFirstChild(def.Tier)
	local found = folder and (folder:FindFirstChild(def.ModelName) or folder:FindFirstChild(def.PetId))
	if not found and folder then
		for _, child in folder:GetChildren() do
			if child.Name:sub(-#def.PetId) == def.PetId then
				found = child
				break
			end
		end
	end

	local model
	if found then
		model = found:Clone()
		if not model:IsA("Model") then
			local wrap = Instance.new("Model")
			model.Parent = wrap
			wrap.PrimaryPart = model:IsA("BasePart") and model or nil
			model = wrap
		end
	else
		model = Instance.new("Model")
		local body = Instance.new("Part")
		body.Size = Vector3.new(1.7, 1.5, 2.2)
		body.Color = PetConfig.tierColor(def.Tier)
		body.Material = Enum.Material.SmoothPlastic
		body.Parent = model
		model.PrimaryPart = body
	end

	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CastShadow = false
		end
	end
	-- COLOUR ONLY, and deliberately.
	--
	-- The library copies are painted server-side on boot and that
	-- replicates, so this is mostly belt and braces -- but it also covers
	-- the fallback part built above, which has never been near the library.
	--
	-- What it must NOT do is call PetVisuals.decorate. The reveal runs in a
	-- ViewportFrame (see eggScene, and the shardBurst note about the old
	-- 70-particle burst), and a ViewportFrame renders no ParticleEmitters,
	-- no Beams, no Trails and no lights. Every effect the follow pet wears
	-- would be built, replicated into the frame, and drawn by nothing.
	PetVisuals.paint(model, def.PetId)

	if not model.PrimaryPart then
		model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart", true)
	end
	return model
end

--------------------------------------------------------------------------
-- IDLE EGGS
--------------------------------------------------------------------------
local eggBases = setmetatable({}, { __mode = "k" })  -- weak: streamed-out plazas drop out

local function trackStation(model: Instance)
	if not model:IsA("Model") then
		return
	end
	local egg = model:FindFirstChild("Egg")
	if egg and egg:IsA("BasePart") then
		local ring = model:FindFirstChild("GlowRing")
		eggBases[egg] = {
			cf = egg.CFrame,
			ring = (ring and ring:IsA("BasePart")) and ring or nil,
		}
	end
end

for _, m in CollectionService:GetTagged("PetStation") do
	trackStation(m)
end
CollectionService:GetInstanceAddedSignal("PetStation"):Connect(trackStation)

--[[
	A LAZY TILT ON TOP OF THE BOB.

	A sine bob and a constant spin are two steady motions, and the eye reads
	steady motion as machinery -- the eggs looked like they were on a turntable
	in a shop window. Two slow tilts at frequencies that divide neither into
	each other nor into the bob give the float a wander that never quite
	repeats, which is the difference between hovering and being driven.

	The phase comes off the egg's own position, so the three eggs standing in a
	row on one plaza are not moving in lockstep. That was the other half of what
	made a row of them look mechanical.
]]
RunService.RenderStepped:Connect(function()
	local t = os.clock()
	for egg, state in eggBases do
		if egg.Parent then
			local base = state.cf
			local ph = base.Position.X * 0.1 + base.Position.Z * 0.07
			local bob = math.sin(t * 1.5 + ph) * 0.28
			egg.CFrame = base
				* CFrame.new(0, bob, 0)
				* CFrame.Angles(0, t * 0.6, 0)
				* CFrame.Angles(math.sin(t * 0.63 + ph * 1.7) * 0.07, 0,
					math.sin(t * 0.9 + ph) * 0.09)

			-- The plinth glow breathes against the bob -- brightest when the egg is at
			-- the bottom of its travel -- so the light reads as the thing holding the
			-- egg up rather than as a decal painted on the wood.
			-- Resolved lazily as well as at track time: the tag can arrive on this
			-- client a beat before the ring does, and a station that streamed in in
			-- that order would otherwise never light up for the rest of the session.
			-- The lookup stops the first time it finds anything.
			local ring = state.ring
			if not ring and egg.Parent then
				ring = egg.Parent:FindFirstChild("GlowRing")
				state.ring = ring
			end
			if ring and ring.Parent then
				ring.Transparency = 0.74 + bob * 0.25
			end
		end
	end
end)

--------------------------------------------------------------------------
-- THE STATION FRONT  --  odds panel, price pill, key bubble
--
-- WHY THIS IS ON THE CLIENT AND NOT IN PetStationBuilder.
--
-- Every part of it is PER PLAYER. The odds panel greys a pet to "??" until
-- this player has hatched one, the price pill goes red when this player cannot
-- afford it, and the key bubble is only up while this player is standing in
-- range. A server-built billboard would have to show one answer to everybody --
-- and the odds panel in particular is the reason the whole station reads: it is
-- the thing that tells a player what they are gambling on before they spend.
--
-- WHAT IT COSTS, AND THE ONE THING THAT KEEPS IT AFFORDABLE.
--
-- Each icon is a ViewportFrame with a real pet model in it. Five icons on
-- fifteen stations is seventy-five live viewports, which is not free on a
-- phone -- so a panel is BUILT ON APPROACH and destroyed on the way out, and at
-- any moment at most a couple exist. The hysteresis between the two ranges is
-- what stops a player standing exactly on the boundary from rebuilding five
-- viewports twice a second.
--------------------------------------------------------------------------

--[[
	WHY THE PANEL IS BACK IN STUDS, AND THE PETS ARE REAL.

	Two passes got this wrong in opposite directions and the third has to satisfy
	both constraints at once.

	Pass one sized the panel with fromScale -- STUDS -- at 9.4 wide, nearly the 11
	studs between one pedestal and the next. A stud-sized billboard is a physical
	object: it grows as you walk toward it, so by the time you could press the
	prompt it covered the screen. That is the plaza you could not walk through.

	Pass two sized it with fromOffset -- PIXELS -- which fixed that completely and
	broke the thing the panel is for. The pet art was a ViewportFrame per tile,
	and A VIEWPORTFRAME DOES NOT RENDER INSIDE A BILLBOARDGUI. Verified rather
	than assumed: the viewports existed, were Visible, held a WorldModel with the
	pet in it and a camera correctly framing it, and setting their background to
	opaque magenta changed nothing on screen. They are simply not drawn there.

	So the pets are REAL PARTS now, floating in front of the panel -- which is
	what the games this is modelled on actually do, and it looks better than a
	40-pixel viewport ever would. That forces the panel back into studs: a
	pixel-sized billboard and a stud-sized pet drift apart as the player moves,
	and the percentage has to stay over the animal it belongs to.

	5.8 studs is the number that satisfies both: half the width that made the
	plaza unwalkable, and wide enough for five animals to be told apart.

	The pets are placed each frame in the CAMERA's plane rather than the world's,
	because a BillboardGui always turns to face the camera and anything meant to
	line up with one has to turn with it.
]]
local PANEL_IN = 46          -- build the front inside this
local PANEL_OUT = 62         -- tear it down outside this; the gap is the hysteresis
local ODDS_SHOWN = 5         -- one per animal on the egg's shelf

local PANEL_STUDS = Vector2.new(5.8, 2.3)
--[[
	THE CARD'S GEOMETRY, AS NUMBERS, and it lives up here rather than inline in
	buildFront because the animals are NOT children of the panel -- they are real
	parts flown in front of it -- and the only thing holding each one over its own
	tile is that this block and the layout below agree. Inline literals in two
	places are two places to disagree, and they did.

	CELL_W USED TO BE PANEL_STUDS.X / ODDS_SHOWN. That is 1.16 studs, which is the
	pitch the cells would sit at if the card had no padding and the layout no
	gaps. It has both: the row is inset 3% a side, and the five cells are 19% of
	what is left with 1.2% between them, so the true pitch is 1.1013. Every animal
	was therefore placed further out than the tile it belongs to -- 0.06 studs of
	drift on the inner columns, 0.12 on the outer ones -- and the Common and the
	Legendary hung off the outside edges of their own cards.
]]
local CARD_H_SCALE = 0.78    -- card height, scale of the panel height
local CARD_PAD_X = 0.03      -- each side, scale of the card width
local CARD_PAD_Y = 0.08      -- top and bottom, scale of the card height
local CELL_SCALE = 0.19      -- one cell, scale of the row width
local CELL_GAP = 0.012       -- UIListLayout padding, scale of the row width
-- The rarity word used to sit in the bottom fifth of every cell, so the tile
-- stopped short at 0.80 to leave room for it. The word is gone -- the tier's
-- colour says it, see oddsIcon -- and the tile takes the space back. That is
-- what makes the animals bigger without the panel growing a stud.
local TILE_BOTTOM = 0.98     -- tile's bottom edge, scale of the cell, from its top
local TILE_H = 0.74          -- tile height, scale of the cell

local CARD_H = PANEL_STUDS.Y * CARD_H_SCALE
local ROW_W = PANEL_STUDS.X * (1 - CARD_PAD_X * 2)
local ROW_H = CARD_H * (1 - CARD_PAD_Y * 2)
-- The panel's centre is 0, and the card hangs from its top edge.
local ROW_TOP = PANEL_STUDS.Y * 0.5 - CARD_H * CARD_PAD_Y
local CELL_W = ROW_W * CELL_SCALE
local CELL_PITCH = CELL_W + ROW_W * CELL_GAP
-- Longest dimension of a pet on the panel, in studs. The tile it stands on is
-- 1.11 studs tall and 0.97 wide now that the rarity strip is gone, so 0.80
-- keeps a margin on both axes and is a third bigger than the 0.62 that had to
-- clear a label.
local PET_SIZE = 0.80
--[[
	WHERE THE ROW SITS, camera-up from the panel's CENTRE -- and it is derived,
	not dialled.

	The card fills the top 78% of a 2.3-stud panel and carries 8% padding, so the
	row of cells runs from +1.01 to -0.50, and the tile inside each cell spans
	TILE_BOTTOM - TILE_H to TILE_BOTTOM of that. At the -0.02 this started at,
	every animal stood a fifth of a stud low, sunk through the bottom of its own
	tile.

	IT IS ONLY THE FALLBACK NOW. The placer at the bottom of this block measures
	where each tile was actually drawn instead of computing where it ought to
	be, and only reaches for this on a frame where the panel has no layout yet.
]]
local PET_DY = ROW_TOP - ROW_H * (TILE_BOTTOM - TILE_H * 0.5)
local PET_TOWARD = 0.35      -- studs toward the camera, so they stand off the card

local PILL_PX = Vector2.new(140, 42)
local KEY_PX = Vector2.new(62, 62)

local fronts = {}            -- [stationModel] = { gui..., }

--[[
	THE FIVE ANIMALS IN THIS EGG, AND THEIR OWN CHANCES.

	This card has now been wrong in both directions, and what fixed it was in
	PetConfig rather than in here.

	It first printed each pictured pet's OWN chance -- 2.9%, 1.9%, 1.1%, 0.8%,
	0.429% on the Basic egg -- every one arithmetically correct and the card as
	a whole nonsense: five percentages on one card read as a BREAKDOWN, a
	breakdown reads as summing to 100, and those summed to 7.2. So it was
	changed to print the TIER's whole share, 50 / 25 / 14 / 8 / 3, which did sum
	to 100 and was honest about the shape of the gamble -- but was no longer
	about the animal in the picture. The pet under "50%" was really a
	seventeenth of it.

	ONE CAUSE UNDER BOTH: an egg could roll any of the sixty pets, so no number
	existed that described the picture and the roll at the same time. An egg is
	five named animals now (see PetConfig.Eggs), so the number under an animal
	is that animal's own chance, the five of them sum to 100 by construction,
	and the picture is the thing being bought rather than a mascot standing in
	for a rarity.

	The tier did not stop mattering -- it decides the COLOUR of the tile and the
	badge, which is how the card is read from across the plaza. It just no
	longer needs a word of its own. See oddsIcon.
]]
local function oddsFor(eggDef)
	local rows = {}
	for _, entry in ipairs(eggDef.pool or {}) do
		table.insert(rows, {
			petId = entry.petId,
			chance = entry.chance,
			tier = entry.tier,
			-- The one-in-a-million pet on the Prestige shelf. Its badge says "???"
			-- rather than its number; nothing else about it is different.
			secret = entry.secret,
		})
	end
	-- PetConfig hands the pool over likeliest-first already. Sorting again costs
	-- nothing on five rows and means the column order is a property of this
	-- card rather than something inherited; the tie-break keeps it stable across
	-- rebuilds, so an animal cannot swap columns when the player walks away and
	-- comes back.
	table.sort(rows, function(a, b)
		if a.chance ~= b.chance then
			return a.chance > b.chance
		end
		return a.petId < b.petId
	end)
	return rows
end

-- Three decimal places on the long shots and none on the safe ones. "0.575%" is
-- a number a player will screenshot; "0.6%" is not, and "1%" on something that
-- is really 0.575% is a lie the panel does not need to tell.
--
-- Trailing zeros are trimmed, because "0.800%" claims a precision the number
-- does not have and reads as a typo next to "0.429%".
local function pct(x: number): string
	local p = x * 100
	if p >= 10 then
		return string.format("%d%%", math.floor(p + 0.5))
	elseif p >= 1 then
		return (string.format("%.1f", p):gsub("%.0$", "")) .. "%"
	end
	local s = string.format("%.3f", p):gsub("0+$", ""):gsub("%.$", "")
	return s .. "%"
end

local function roundify(inst: GuiObject, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
	return c
end

--[[
	One icon: the pet itself on a tier-tinted tile, with its real chance on a
	badge above it.

	NOTHING IS HIDDEN. The first pass greyed a pet to "??" until the player had
	hatched one, on the reasoning that an index is more fun to fill in than to
	read -- which is a fine argument about an INDEX and the wrong one about a
	shop front. This panel exists to answer "what am I buying" before the player
	spends, and a wall of question marks answers it with nothing: a new player,
	who is exactly the player deciding whether this is worth 100 coins, saw five
	question marks and five "??" and had no reason to press the button.

	So every pet shows its model and its real percentage, always.
]]
local function oddsIcon(parent: GuiObject, row, order: number)
	local tier = PetConfig.tierInfo(row.tier)

	local cell = Instance.new("Frame")
	cell.Name = "Odds" .. order
	cell.BackgroundTransparency = 1
	cell.Size = UDim2.fromScale(CELL_SCALE, 1)
	cell.LayoutOrder = order
	cell.Parent = parent

	local tile = Instance.new("Frame")
	tile.Name = "Tile"
	tile.AnchorPoint = Vector2.new(0.5, 1)
	tile.Position = UDim2.fromScale(0.5, TILE_BOTTOM)
	tile.Size = UDim2.fromScale(0.94, TILE_H)
	-- Only a third of the way to white. At 0.35 every tile was near enough the
	-- same pale wash and a pale pet on it disappeared; this keeps the tier
	-- readable as a colour AND gives the model something to stand against.
	tile.BackgroundColor3 = (tier and tier.glow or PanelKit.C.sandMid):Lerp(Color3.new(1, 1, 1), 0.12)
	tile.BorderSizePixel = 0
	tile.ZIndex = 3
	tile.Parent = cell
	roundify(tile, 10)

	-- The tier's own colour, as an edge. The FILL has to stay pale or a pale pet
	-- standing in front of it disappears, which leaves all five tiles as nearly
	-- the same wash -- so the border is where the rarity gets to be saturated.
	local tileEdge = Instance.new("UIStroke")
	tileEdge.Thickness = 2
	tileEdge.Color = tier and tier.color or PanelKit.C.sandDeep
	tileEdge.Transparency = 0.15
	tileEdge.Parent = tile

	-- The tile is only the BACKDROP now. The animal itself is a real part placed
	-- in front of this card every frame -- see spawnPets below and the placer at
	-- the bottom of this block -- because a ViewportFrame is not drawn inside a
	-- BillboardGui at all.

	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0.5, 0)
	badge.Position = UDim2.fromScale(0.5, 0)
	badge.Size = UDim2.fromScale(1.02, 0.34)
	badge.BackgroundColor3 = tier and tier.color or PanelKit.C.sandDeep
	badge.BorderSizePixel = 0
	badge.ZIndex = 6
	badge.Parent = cell
	roundify(badge, 8)

	--[[
		"???" ON THE ONE THAT IS ONE IN A MILLION.

		PetConfig marks it; this only draws it. The number itself, 0.0001%, is
		true and would fit -- and it reads as a broken decimal point. Five
		percentages descending to a row of question marks reads as what it is:
		there is something in this egg they are not telling you the odds of. The
		animal is still pictured and still tinted its own colour, so it is a
		secret about the CHANCE, not about the prize.
	]]
	local txt = label(badge, row.secret and "???" or pct(row.chance), 14, CREAM, true)
	txt.Size = UDim2.fromScale(0.9, 0.8)
	txt.Position = UDim2.fromScale(0.05, 0.1)
	txt.ZIndex = 7
	-- Same ceiling, same reason: "31%" is three characters and would otherwise
	-- render twice the size of "0.429%" on the badge beside it.
	local badgeCap = Instance.new("UITextSizeConstraint")
	badgeCap.MaxTextSize = 17
	badgeCap.Parent = txt
	-- White on a mid-tone tier colour needs an edge at this size.
	local st = Instance.new("UIStroke")
	st.Thickness = 1.5
	st.Color = Color3.fromRGB(40, 28, 18)
	st.Transparency = 0.25
	st.Parent = txt

	--[[
		NOTHING IS WRITTEN UNDER THE TILE.

		There used to be a word there: COMMON, UNCOMMON, RARE, EPIC, LEGENDARY,
		set in a darkened version of the tier's colour along the bottom of every
		cell. It is gone -- and the RARITY is not. The tile's border and the badge
		behind the percentage are still the tier's own colour, which is the half
		of it that survives being read at a glance from thirty studs away; the
		word was the half that needed stopping and squinting for, at 13 point, in
		one fifth of a cell one fifth of a 5.8-stud card, with two of the five
		words long enough to wrap.

		It was also the last thing on the card still describing a TIER after
		everything else on it had become about a particular animal (see oddsFor),
		so removing it took a contradiction out of the panel as well as a smear.

		The tile comes back with the cell because the placer measures it. See
		PLACING THE ANIMALS.
	]]
	return cell, tile
end

local function buildFront(model: Model)
	if fronts[model] then
		return
	end
	local egg = model:FindFirstChild("Egg")
	local anchor = model:FindFirstChild("PromptAnchor") or egg
	local eggDef = PetConfig.eggFor(model:GetAttribute("EggKey"))

	--[[
		WHERE THE FRONT HANGS, now that the egg is inside a glass tube.

		These offsets were measured off a 2.8-stud egg floating a stud over a
		wooden rim: the panel at +3.9 cleared its top and the price pill at -2.1
		sat under it in open air. The egg is now suspended INSIDE a case between
		6.6 and 11.6 studs tall, so both of those land in the glass -- the panel
		behind the cap and the pill somewhere in the plinth.

		PetStationBuilder puts a SignAnchor over the tube's own top for exactly
		this, and the whole front hangs off that instead. The old numbers are kept
		as the fallback, because a station built before the tubes (or a hand-made
		one) still has an egg and no anchor, and it should still read.
	]]
	local signAt = model:FindFirstChild("SignAnchor")
	local mount = (signAt and signAt:IsA("BasePart")) and signAt or egg
	local PANEL_AT = signAt and Vector3.new(0, 0.9, 0) or Vector3.new(0, 3.9, 0)
	local PILL_AT = signAt and Vector3.new(0, -0.75, 0) or Vector3.new(0, -2.1, 0)
	if not (egg and egg:IsA("BasePart") and anchor and eggDef) then
		return
	end

	local made = { parts = {}, muted = {} }
	fronts[model] = made

	--[[
		THE OLDER SIGNS STAND DOWN WHILE THIS IS UP.

		Every station carries two earlier labels: PetStationBuilder's own EggSign
		(the egg's name and cost, correct), and an EggGUI authored into the place
		(a leftover from the Creator Store kit the pedestals came from -- no script
		in the game creates it, and all fifteen of them read "Weak Egg / $500"
		regardless of which egg they are sitting on). Left alone they stack three
		prices on one pedestal, one of them wrong.

		SWITCHED OFF, NOT DELETED. They are hand-authored instances in somebody's
		place file; a client script is not the thing that gets to decide they are
		gone. Enabled goes back on the way out, and the place is untouched.
	]]
	-- EggBars is PetStationBuilder's own themed price/rarity signage on the tube
	-- top. It says the same thing to everybody and is what you read from across
	-- the plaza; this front is the per-player version of it and stands in the
	-- same place, so exactly one of the two is ever up. Beyond PANEL_OUT this
	-- front is torn down and the bars come straight back.
	for _, name in ipairs({ "EggGUI", "EggSign", "EggBars" }) do
		local old = model:FindFirstChild(name, true)
		if old and old:IsA("BillboardGui") and old.Enabled then
			old.Enabled = false
			table.insert(made.muted, old)
		end
	end

	----------------------------------------------------------------
	-- THE ODDS PANEL, over the egg
	----------------------------------------------------------------
	-- Clamped. UiFit reports off the live viewport, and a viewport read during a
	-- bad frame (a minimised window reports 1x1 and UiFit answers 0.60) would
	-- bake a two-thirds-size panel into a front that is never rebuilt while the
	-- player stands there. The floor costs nothing and the failure it prevents is
	-- an unreadable station.
	local fit = math.clamp(UiFit.get(), 0.8, 1.25)

	local panel = Instance.new("BillboardGui")
	panel.Name = "EggOdds"
	panel.Adornee = mount
	panel.Size = UDim2.fromScale(PANEL_STUDS.X, PANEL_STUDS.Y)
	-- Over the tube's own cap, in the place the station's static bars occupy
	-- when this is not up. See WHERE THE FRONT HANGS.
	panel.StudsOffsetWorldSpace = PANEL_AT
	panel.AlwaysOnTop = false
	panel.MaxDistance = PANEL_OUT
	panel.Parent = mount
	table.insert(made.parts, panel)
	-- Held rather than only listed for teardown: the placer reads its
	-- AbsoluteSize and AbsolutePosition every frame.
	made.panel = panel

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.Size = UDim2.fromScale(1, CARD_H_SCALE)
	card.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	card.BorderSizePixel = 0
	card.ZIndex = 2
	card.Parent = panel
	roundify(card, 14)
	-- A white card on a bright sky has no edge at all without this.
	local cardEdge = Instance.new("UIStroke")
	cardEdge.Thickness = 2
	cardEdge.Color = Color3.fromRGB(56, 44, 32)
	cardEdge.Transparency = 0.25
	cardEdge.Parent = card

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(CARD_PAD_Y, 0)
	pad.PaddingBottom = UDim.new(CARD_PAD_Y, 0)
	pad.PaddingLeft = UDim.new(CARD_PAD_X, 0)
	pad.PaddingRight = UDim.new(CARD_PAD_X, 0)
	pad.Parent = card

	local row = Instance.new("Frame")
	row.Name = "Row"
	row.Size = UDim2.fromScale(1, 1)
	row.BackgroundTransparency = 1
	row.ZIndex = 3
	row.Parent = card

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(CELL_GAP, 0)
	layout.Parent = row

	local rows = oddsFor(eggDef)
	local shown = math.min(ODDS_SHOWN, #rows)
	-- The tiles are kept, not just built: each animal is flown to wherever its
	-- OWN tile was drawn this frame, so the placer needs the frame itself and
	-- not a column number. See PLACING THE ANIMALS.
	local tiles = {}
	for i = 1, shown do
		local _, tile = oddsIcon(row, rows[i], i)
		tiles[i] = tile
	end

	--[[
		THE ANIMALS, as real parts.

		One cloned pet mesh per column, scaled to a fixed longest-dimension so a
		long pet and a tall one take the same room on the shelf, anchored and inert
		-- CanQuery off matters, because the prompt's line of sight runs straight
		through here and a pet that can be raycast is a station that will not open.

		Parented to the EGG rather than to the workspace, so they stream out with
		the station and cannot outlive it.
	]]
	made.pets = {}
	for i = 1, shown do
		local src = petModel(PetConfig.get(rows[i].petId))
		local mesh
		if src then
			for _, d in ipairs(src:GetDescendants()) do
				if d:IsA("BasePart") then
					mesh = d:Clone()
					break
				end
			end
			src:Destroy()
		end
		if mesh then
			for _, junk in ipairs(mesh:GetChildren()) do
				junk:Destroy()
			end
			local longest = math.max(mesh.Size.X, mesh.Size.Y, mesh.Size.Z)
			mesh.Size = mesh.Size * (PET_SIZE / math.max(longest, 0.001))
			mesh.Name = "OddsPet" .. i
			mesh.Anchored = true
			mesh.CanCollide = false
			mesh.CanQuery = false
			mesh.CanTouch = false
			mesh.CastShadow = false
			mesh.Massless = true
			mesh.Parent = egg
			table.insert(made.parts, mesh)
			-- The tile it has to stand on, and -- for the fallback path only -- the
			-- column it belongs over, measured from the middle of the row.
			table.insert(made.pets, {
				part = mesh,
				tile = tiles[i],
				dx = (i - (shown + 1) / 2) * CELL_PITCH,
			})
		end
	end
	-- The placer flies each animal to its own tile every frame, measured from
	-- here -- so this pair has to be the SAME anchor and offset the panel got,
	-- or the pets stand over the tube while the card sits over the egg.
	made.anchorPart = mount
	made.panelOffset = PANEL_AT

	-- The little tail that makes a floating rectangle read as a speech panel
	-- pointing at the egg rather than as a sign hanging in the air behind it.
	local tail = Instance.new("Frame")
	tail.Name = "Tail"
	tail.AnchorPoint = Vector2.new(0.5, 0)
	tail.Position = UDim2.fromScale(0.5, 0.74)
	tail.Size = UDim2.fromScale(0.075, 0.16)
	tail.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	tail.BorderSizePixel = 0
	tail.Rotation = 45
	tail.ZIndex = 1
	tail.Parent = panel

	----------------------------------------------------------------
	-- THE PRICE PILL, under the egg
	----------------------------------------------------------------
	local pillGui = Instance.new("BillboardGui")
	pillGui.Name = "EggPrice"
	pillGui.Adornee = mount
	pillGui.Size = UDim2.fromOffset(PILL_PX.X * fit, PILL_PX.Y * fit)
	pillGui.StudsOffsetWorldSpace = PILL_AT
	pillGui.AlwaysOnTop = false
	pillGui.MaxDistance = PANEL_OUT
	pillGui.Parent = mount
	table.insert(made.parts, pillGui)

	local pill = Instance.new("Frame")
	pill.Name = "Pill"
	pill.Size = UDim2.fromScale(1, 1)
	pill.BackgroundColor3 = Color3.fromRGB(38, 46, 54)
	pill.BorderSizePixel = 0
	pill.ZIndex = 2
	pill.Parent = pillGui
	roundify(pill, 999)
	local pillEdge = Instance.new("UIStroke")
	pillEdge.Thickness = 3
	pillEdge.Color = Color3.fromRGB(16, 20, 26)
	pillEdge.Parent = pill

	local gem = Instance.new("Frame")
	gem.Name = "Gem"
	gem.AnchorPoint = Vector2.new(0, 0.5)
	gem.Position = UDim2.fromScale(0.055, 0.5)
	gem.Size = UDim2.fromScale(0.16, 0.56)
	gem.BackgroundColor3 = eggDef.accent
	gem.BorderSizePixel = 0
	gem.Rotation = 45
	gem.ZIndex = 3
	gem.Parent = pill
	roundify(gem, 4)

	local price = label(pill, tostring(eggDef.cost), 22, CREAM, true)
	price.Name = "Price"
	price.AnchorPoint = Vector2.new(0, 0.5)
	price.Position = UDim2.fromScale(0.25, 0.5)
	price.Size = UDim2.fromScale(0.68, 0.66)
	price.TextXAlignment = Enum.TextXAlignment.Left
	price.ZIndex = 4
	made.price = price
	made.cost = eggDef.cost

	----------------------------------------------------------------
	-- THE KEY BUBBLE
	--
	-- The prompt's own UI is switched off LOCALLY -- Style = Custom on the
	-- client renders nothing and replicates nowhere -- and this is drawn in its
	-- place. The prompt still owns everything that matters: the range, the line
	-- of sight, the hold, and the Triggered the server is listening on. Only the
	-- picture changes.
	----------------------------------------------------------------
	local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
	if prompt then
		made.prompt = prompt
		prompt.Style = Enum.ProximityPromptStyle.Custom

		local keyGui = Instance.new("BillboardGui")
		keyGui.Name = "EggKey"
		keyGui.Adornee = egg
		keyGui.Size = UDim2.fromOffset(KEY_PX.X * fit, KEY_PX.Y * fit)
		keyGui.StudsOffsetWorldSpace = Vector3.new(0, 0.1, 0)
		keyGui.AlwaysOnTop = true
		keyGui.Enabled = false
		keyGui.Parent = egg
		table.insert(made.parts, keyGui)

		local box = Instance.new("Frame")
		box.Name = "Box"
		box.AnchorPoint = Vector2.new(0.5, 0.5)
		box.Position = UDim2.fromScale(0.5, 0.5)
		box.Size = UDim2.fromScale(0.86, 0.86)
		box.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		box.BorderSizePixel = 0
		box.ZIndex = 4
		box.Parent = keyGui
		roundify(box, 16)

		local key = label(box, prompt.KeyboardKeyCode.Name, 40, Color3.fromRGB(28, 30, 36), true)
		key.Size = UDim2.fromScale(0.78, 0.78)
		key.Position = UDim2.fromScale(0.11, 0.11)
		key.ZIndex = 5
		-- Touch has no key to press. The prompt shows on tap there, so the bubble
		-- has to say the thing that IS true on a phone.
		if not prompt.KeyboardKeyCode or prompt.KeyboardKeyCode == Enum.KeyCode.Unknown then
			key.Text = "TAP"
		end

		table.insert(made.parts, prompt.PromptShown:Connect(function()
			keyGui.Enabled = true
			box.Size = UDim2.fromScale(0.5, 0.5)
			TweenService:Create(box, TweenInfo.new(0.24, Enum.EasingStyle.Back,
				Enum.EasingDirection.Out), { Size = UDim2.fromScale(0.86, 0.86) }):Play()
		end))
		table.insert(made.parts, prompt.PromptHidden:Connect(function()
			keyGui.Enabled = false
		end))
	end
end

local function dropFront(model: Model)
	local made = fronts[model]
	if not made then
		return
	end
	fronts[model] = nil

	-- THE PROMPT'S OWN UI GOES BACK ON. Style stays wherever it was last written,
	-- so a station left on Custom with this front torn down is a prompt that
	-- draws nothing at all -- an invisible "press E" is worse than a plain one.
	-- Restoring it here means the custom bubble only ever exists alongside the
	-- thing that draws it, however the player leaves.
	if made.prompt and made.prompt.Parent then
		made.prompt.Style = Enum.ProximityPromptStyle.Default
	end

	for _, old in ipairs(made.muted or {}) do
		if old.Parent then
			old.Enabled = true
		end
	end

	for _, thing in ipairs(made.parts) do
		pcall(function()
			-- The list carries both instances and the two prompt connections, which
			-- do not answer to Destroy.
			if typeof(thing) == "RBXScriptConnection" then
				thing:Disconnect()
			else
				thing:Destroy()
			end
		end)
	end
end

-- Affordability, repainted rather than rebuilt: the panel is expensive to make
-- and a balance changes on every sale.
local function repaintPrices()
	local coins = tonumber(player:GetAttribute("Coins")) or 0
	for _, made in pairs(fronts) do
		if made.price and made.price.Parent then
			made.price.TextColor3 = (coins >= (made.cost or 0))
				and Color3.fromRGB(150, 240, 170)
				or Color3.fromRGB(248, 150, 140)
		end
	end
end
player:GetAttributeChangedSignal("Coins"):Connect(repaintPrices)

--[[
	PLACING THE ANIMALS -- BY MEASURING THE CARD, NOT BY PREDICTING IT.

	The percentages live on a BillboardGui and the animals are real parts flying
	in front of it, so something has to hold each animal over its own tile from
	every angle a player can walk to. The previous pass laid the row out along
	the CAMERA's right and up vectors -- correct, that is the plane a billboard
	draws in -- and then pulled the whole row PET_TOWARD studs toward the camera
	so the animals stand off the card instead of z-fighting it.

	THAT LAST STEP WAS THE FAULT, and everything else was built on top of it.
	Moving a point toward the camera does not only make it bigger: it projects
	FURTHER FROM THE MIDDLE OF THE SCREEN, by depth / (depth - PET_TOWARD). The
	old code knew that and corrected the offsets WITHIN the row for it -- and
	never corrected the row's own anchor, which spreads by exactly the same
	ratio. A point in the middle of the screen spreads by nothing at all, so
	facing a station straight on looked perfect. Turn until the station sits out
	at the edge of the view and the whole row slides outward as one piece, off
	its own tiles: 19 pixels on a 55-pixel tile, measured, with the panel two
	thirds of the way to the right edge of a 1522-wide viewport. From inside the
	game that reads as "the pets slide off when I walk", which is why it kept
	getting chased as a problem about walking.

	NO EXTRA CORRECTION TERM IS ADDED HERE, because another formula predicting
	where Roblox will draw the card is another formula that can be wrong. This
	READS the card instead. Every tile reports its own AbsolutePosition and
	AbsoluteSize in pixels, so the offset from the panel's centre to a tile's
	centre is a MEASURED pixel vector; the panel's centre is drawn exactly where
	WorldToViewportPoint puts it (checked against a crosshair drawn on a
	ScreenGui at that pixel -- it lands dead on the middle tile); and the animal
	is flown out along the ray through the sum of the two, as far out as the
	card. Standing a third of a stud in front then costs nothing at all, because
	a point slid along its own view ray does not move on screen -- which is the
	property the old formula was missing.

	One connection for every station rather than one each: at most a couple of
	fronts exist at a time and this is five CFrame writes apiece.
]]
RunService.RenderStepped:Connect(function()
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local cf = cam.CFrame
	local camPos, right, up, look = cf.Position, cf.RightVector, cf.UpVector, cf.LookVector
	local t = os.clock()
	for _, made in pairs(fronts) do
		local anchor = made.anchorPart
		local panel = made.panel
		if anchor and anchor.Parent and made.pets and panel and panel.Parent then
			local centre = anchor.Position + made.panelOffset
			local screen = cam:WorldToViewportPoint(centre)
			local panelPx = panel.AbsoluteSize
			-- How far out the animals are drawn: level with the card, less the
			-- third of a stud they stand off it. screen.Z is the depth along the
			-- camera's look vector and goes negative behind it, so this guard also
			-- covers the degenerate frame where the camera is inside the panel --
			-- a teleport, or a cutscene parked in the pedestal -- where there is no
			-- sane answer and last frame's is the best one available.
			local depth = screen.Z - PET_TOWARD
			if depth > 0.5 then
				-- Pixels per stud ON THE CARD, straight off what Roblox just drew.
				-- This is also what converts the bob, so the animals rise and fall by
				-- the same fraction of a tile at every distance rather than by a
				-- fixed number of studs.
				local pxPerStud = (panelPx.Y > 1) and (panelPx.Y / PANEL_STUDS.Y) or 0
				local panelMid = panel.AbsolutePosition + panelPx * 0.5
				for i, slot in ipairs(made.pets) do
					local part, tile = slot.part, slot.tile
					if part.Parent then
						-- Each on its own phase, so the row breathes instead of pulsing.
						local bob = math.sin(t * 1.6 + i * 0.9) * 0.045
						local pos
						if tile and tile.Parent and pxPerStud > 0 then
							local off = (tile.AbsolutePosition + tile.AbsoluteSize * 0.5) - panelMid
							-- Screen y runs DOWN and the bob is up, hence the minus.
							local dir = cam:ViewportPointToRay(
								screen.X + off.X,
								screen.Y + off.Y - bob * pxPerStud).Direction.Unit
							-- Out along that ray until it is level with the card. Dividing
							-- by the ray's own component along the look vector is what
							-- makes an animal at the edge of the row land at the same
							-- DEPTH as one in the middle rather than the same distance --
							-- the row is a straight shelf, not an arc bending toward the
							-- player at the ends.
							pos = camPos + dir * (depth / math.max(dir:Dot(look), 0.05))
						else
							-- The frame before the layout has run, or a panel Roblox is
							-- not drawing at all: the old camera-plane placement, which is
							-- right in front of the player and wrong out at the edges.
							local flat = depth / screen.Z
							pos = centre
								+ right * (slot.dx * flat)
								+ up * ((PET_DY + bob) * flat)
								- look * PET_TOWARD
						end
						-- Turned to the camera and yawed a little: a three-quarter view
						-- reads as an animal, dead-on reads as a mugshot.
						part.CFrame = CFrame.lookAt(pos, pos - look) * CFrame.Angles(0, math.rad(28), 0)
					end
				end
			end
		end
	end
end)

-- The approach check. Four times a second, not per frame: it is a distance
-- comparison against a handful of stations and nothing it decides can change
-- inside a quarter of a second of walking.
task.spawn(function()
	while true do
		task.wait(0.25)
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			for _, model in CollectionService:GetTagged("PetStation") do
				local egg = model:FindFirstChild("Egg")
				if egg and egg:IsA("BasePart") then
					local d = (egg.Position - root.Position).Magnitude
					if d <= PANEL_IN and not fronts[model] then
						local ok, err = pcall(buildFront, model)
						if not ok then
							warn("[EggClient] station front failed:", err)
							fronts[model] = nil
						end
						repaintPrices()
					elseif d > PANEL_OUT and fronts[model] then
						dropFront(model)
					end
				elseif fronts[model] then
					dropFront(model)
				end
			end
		end
	end
end)

--------------------------------------------------------------------------
-- THE HATCH SCREEN
--------------------------------------------------------------------------
--[[
	IT IS ITS OWN SCREEN NOW, AND THAT IS A CORRECTNESS FIX AS MUCH AS A LOOK.

	The first cut played the hatch IN THE WORLD. It took the camera, pointed it
	at the pedestal from the player's own side, dimmed everything to 38 percent
	transparent and shook a prop egg where the station's egg floats -- which
	means everything else was still in the shot and still moving: the character
	standing at the prompt, the sifter CTB_Client redraws in front of them every
	RenderStepped, other players, their quads, the pedestal itself, the plaza
	roof, a sakura branch. The one thing the moment is about was the one thing
	not guaranteed to be visible.

	NO CAMERA ANGLE FIXES THAT, because the obstruction is not in one place and
	half of it is attached to the player. So the scene came off the map:

		* an OPAQUE backdrop -- the world is not dimmed, it is gone;
		* the egg and the pet live in a VIEWPORTFRAME, which renders its own
		  children and NOTHING else. Nothing in the world can get into the shot,
		  by construction rather than by camera work;
		* every other HUD is hidden for the duration, so nothing overlaps either;
		* the character stands still, because somebody who cannot see the world
		  should not be walking around in it.

	THE CAMERA IS NEVER TAKEN NOW. The old header's worry -- "a cinematic that
	can drop the camera in Scriptable is a cinematic that soft-locks the game"
	-- was a cost of playing in the world, and it is simply gone: when the
	backdrop lifts, the view is exactly where the player left it. What replaced
	it is a smaller promise (put some ScreenGuis back, hand movement back) and
	`finish` is still the single idempotent path that keeps it -- called by the
	sequence, by the card's X, by the watchdog and by respawning.

	WHAT THE SHOT IS, IN ORDER: black, an egg lying on the ground, the PLAYER'S
	OWN CHARACTER walking in and stooping over it, the thing inside knocking its
	way out, a flash, and the pet.

	IT IS THEIR CHARACTER, CLONED FROM THE LIVE ONE -- their body, their skin,
	whatever hat they are wearing this minute. A stand-in rig would be somebody
	else finding the egg, and the beat only works because it is them. See
	actorScene for what is stripped off the clone and why the whole thing is
	moved rigidly rather than posed.

	THE CURTAIN IS BLACK, and it used to be the egg's own colour darkened. Black
	means there is nothing on screen to read until the scene is in it -- and it
	leaves the FLASH, which is where the tier arrives, the only colour change in
	the whole sequence. The tier is not drawn anywhere before that frame.

	IT IS A CUTSCENE, NOT A TASK. An earlier pass had the player click the shell
	three times to break it, arguing that a hatch you merely watch is a receipt.
	That is the wrong end of it: the buying was the decision, and a three-click
	chore between the player and the animal only stands in front of the thing
	they paid for. The knocks are on a timer now and the whole sequence runs
	itself.
]]

local HIDE = {
	"CleanTheBeachHUD", "InventoryHud", "BeachMenuHud", "WeightHUD",
	"SiftHud", "WashHud", "DriveHud", "RevealPopup", "FeedbackHud", "ToastKit",
	-- our own chip: it is a HUD readout, and the reveal is about to say the
	-- same thing in letters four times the size
	"PetUI",
}
local hidden = {}

local function hideHud()
	table.clear(hidden)
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return
	end
	for _, name in HIDE do
		local g = pg:FindFirstChild(name)
		if g and g:IsA("ScreenGui") and g.Enabled then
			g.Enabled = false
			table.insert(hidden, g)
		end
	end
end

local function showHud()
	for _, g in hidden do
		if g.Parent then
			g.Enabled = true
		end
	end
	table.clear(hidden)
end

-- Stand still for it. Captured and handed back rather than assumed, because
-- ProgressionServer owns WalkSpeed (Beach Legs moves it) and writing 16 back
-- would silently refund an upgrade. Same idiom as the vault's own cinema.
local heldSpeed, heldJump = nil, nil

local function freeze()
	local ch = player.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	if not hum or heldSpeed ~= nil then
		return
	end
	heldSpeed, heldJump = hum.WalkSpeed, hum.JumpPower
	hum.WalkSpeed = 0
	hum.JumpPower = 0
end

local function thaw()
	local ch = player.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	if hum and heldSpeed ~= nil then
		hum.WalkSpeed = heldSpeed
		hum.JumpPower = heldJump
	end
	heldSpeed, heldJump = nil, nil
end

--------------------------------------------------------------------------
-- THE SCREEN, BUILT ONCE
--------------------------------------------------------------------------
--[[
	SIZED IN SCALE, NOT PIXELS, AND THAT IS WHAT KEEPS UiFit OFF IT. UiFit
	absorbs a ScreenGui's top-level children only when BOTH size axes are pure
	offset, and shrinking a full-screen backdrop to 60 percent would leave a
	border of live game round a modal -- its own note says so. The backdrop is
	fromScale(1, 1), so it is left alone, and everything else here hangs off it
	rather than off the ScreenGui. Only the card, which is genuinely pixel-sized,
	carries a UIScale of its own.
]]
local hatchGui = Instance.new("ScreenGui")
hatchGui.Name = "PetHatch"
hatchGui.ResetOnSpawn = false
hatchGui.IgnoreGuiInset = true
hatchGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
-- Over every HUD and every panel, under the two cinemas that are allowed to
-- interrupt anything (RebirthCinema 240, IntroCinema 260).
hatchGui.DisplayOrder = 220
hatchGui.Enabled = false
hatchGui.Parent = player:WaitForChild("PlayerGui")

-- The curtain. Near-black, and named because the sequence sets it back to this
-- on every run -- it is repainted to the TIER at the flash, and a run that
-- inherited the last run's tier colour would open on a spoiler.
local CURTAIN = Color3.fromRGB(7, 7, 11)

local backdrop = Instance.new("Frame")
backdrop.Name = "Backdrop"
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = CURTAIN
backdrop.BackgroundTransparency = 1
backdrop.BorderSizePixel = 0
backdrop.ZIndex = 1
backdrop.Parent = hatchGui

-- A vignette, so a flat fill reads as a room rather than as a colour swatch.
local vign = Instance.new("Frame")
vign.Name = "Vignette"
vign.Size = UDim2.fromScale(1, 1)
vign.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
vign.BackgroundTransparency = 0.55
vign.BorderSizePixel = 0
vign.ZIndex = 3
vign.Parent = backdrop
local vignGrad = Instance.new("UIGradient")
vignGrad.Rotation = 90
vignGrad.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.25),
	NumberSequenceKeypoint.new(0.5, 1),
	NumberSequenceKeypoint.new(1, 0.15),
})
vignGrad.Parent = vign

--[[
	THE RAYS. Sixteen blades on a hub that turns, which is the shorthand every
	game with a crate in it uses for "something is coming out of this".

	ONE ROTATION WRITE PER FRAME, NOT SIXTEEN. The blades are children of a hub
	and the hub is what turns; rotating a container rotates its contents about
	the container's centre, so the fan spins for the cost of one property.

	The hub is 2.4 screen-heights across so the blades still reach the corners
	of an ultrawide window, and each blade fades out along its own length so the
	fan has no hard outer edge to give away that it is eighteen rectangles.

	THE GRADIENT RUNS INNER-BRIGHT AND IT IS NOT OPTIONAL. Written the other way
	round it does not merely look wrong -- it eats half the fan. A blade fading
	OUT toward the hub is invisible near the centre and solid at its far end, and
	the far end of every downward blade is a screen and a half below the bottom
	of the window, so the lower nine blades render entirely off-screen and the
	fan comes out as a semicircle over the pet's head.

	CENTRED ON THE STAGE, NOT ON THE SCREEN. The fan is what the pet stands in
	front of, so it converges where the pet is (0.38 of the height) rather than
	halfway down the window with the reveal sitting above its hub.

	EACH BLADE IS DOUBLE-ENDED, AND THAT IS A BUG FIX, NOT A STYLE.

	GuiObject.Rotation pivots about the object's own CENTRE. It does not respect
	AnchorPoint -- which is easy to assume, because AnchorPoint governs
	everything else about where a frame sits. The blades used to be anchored at
	(0.5, 1) and half a hub tall, so each one turned about a point a quarter of
	a hub-height ABOVE the hub's middle, and eighteen of them converged there
	instead of at the hub. Then the hub's own spin swung that false centre round
	a 480-pixel circle once every few seconds: on screen the entire fan drifted
	off into a corner and sat there pointing at nothing, while the egg it was
	supposed to be radiating from stayed in the middle of the shot.

	A blade centred on the hub and running the full height across it turns about
	the hub, because now its centre IS the hub. That makes every blade
	double-ended, so nine of them draw eighteen rays and they are spaced over
	half a turn rather than a whole one -- a blade at 200 degrees is the same
	two rays as a blade at 20.

	The gradient is symmetric for the same reason: both ends of a blade are now
	far ends, so both have to fade out, and the middle is the hub.

	THE VERY CENTRE IS BACKED OFF and it is not optional. Eighteen opaque rays
	meeting at a point make a solid disc, and the disc would sit directly behind
	the reveal and flatten it.
]]
local RAYS = 18
-- Halved, because each blade now draws a ray out of each end.
local BLADES = RAYS // 2
local rayHub = Instance.new("Frame")
rayHub.Name = "Rays"
rayHub.AnchorPoint = Vector2.new(0.5, 0.5)
rayHub.Position = UDim2.fromScale(0.5, 0.38)
rayHub.Size = UDim2.fromScale(2.4, 2.4)
rayHub.SizeConstraint = Enum.SizeConstraint.RelativeYY
rayHub.BackgroundTransparency = 1
rayHub.ZIndex = 2
rayHub.Parent = backdrop

local blades = {}
for i = 1, BLADES do
	local b = Instance.new("Frame")
	b.Name = "Ray"
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.Position = UDim2.fromScale(0.5, 0.5)
	-- Full height, centred: the blade's middle sits on the hub, so Rotation --
	-- which pivots about the centre -- turns it about the hub.
	b.Size = UDim2.fromScale(0.022, 1)
	-- Half a turn, not a whole one. See the note above.
	b.Rotation = (i - 1) * (180 / BLADES)
	b.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	b.BackgroundTransparency = 1
	b.BorderSizePixel = 0
	b.ZIndex = 2
	b.Parent = rayHub
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	-- Symmetric: both ends of the blade are far ends now, and 0.5 is the hub.
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.32, 0.1),
		NumberSequenceKeypoint.new(0.5, 0.28),
		NumberSequenceKeypoint.new(0.68, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	g.Parent = b
	blades[i] = b
end

local function tintRays(colour: Color3, alpha: number)
	for _, b in blades do
		b.BackgroundColor3 = colour
		TweenService:Create(b, TweenInfo.new(0.35), { BackgroundTransparency = alpha }):Play()
	end
end

-- The square the egg and then the pet stand in. Sized off the screen HEIGHT
-- and held square by an aspect constraint, so it is the same shot on a phone
-- in landscape as on a monitor and never crops the model.
local stage = Instance.new("Frame")
stage.Name = "Stage"
stage.AnchorPoint = Vector2.new(0.5, 0.5)
stage.Position = UDim2.fromScale(0.5, 0.38)
stage.Size = UDim2.fromScale(0.5, 0.5)
stage.BackgroundTransparency = 1
stage.ZIndex = 4
stage.Parent = backdrop
local stageAspect = Instance.new("UIAspectRatioConstraint")
stageAspect.AspectRatio = 1
stageAspect.DominantAxis = Enum.DominantAxis.Height
stageAspect.Parent = stage

local eggTitle = PanelKit.text(backdrop, "", 34, Enum.Font.LuckiestGuy, PanelKit.C.white)
eggTitle.Name = "EggTitle"
eggTitle.AnchorPoint = Vector2.new(0.5, 0)
eggTitle.Position = UDim2.fromScale(0.5, 0.055)
eggTitle.Size = UDim2.fromScale(0.66, 0.075)
eggTitle.TextScaled = true
eggTitle.TextTransparency = 1
eggTitle.ZIndex = 6
local eggTitleStroke = PanelKit.punch(eggTitle, 3)
eggTitleStroke.Transparency = 1

-- A skip surface over the whole screen. It is a Frame with Active on rather
-- than a TextButton so it can sit UNDER the card's own X without eating its
-- clicks -- ZIndex 5 against the card's 10.
local skip = Instance.new("TextButton")
skip.Name = "Skip"
skip.Size = UDim2.fromScale(1, 1)
skip.BackgroundTransparency = 1
skip.Text = ""
skip.AutoButtonColor = false
skip.ZIndex = 5
skip.Visible = false
skip.Parent = backdrop
-- Connected ONCE, here, not per hatch. `skip` outlives every run, so a
-- connection made inside the sequence would stack up one deeper per egg and
-- the tenth one would call finish ten times. `finish` is late-bound through the
-- forward declaration, which is what lets this sit above the definition.
skip.Activated:Connect(function()
	finish()
end)

--[[
	THERE IS NO CRACK SURFACE ANY MORE.

	A second full-screen button used to sit here beside `skip`, because during the
	cracking beat a click had to do the OPPOSITE of skipping -- it was the player
	working at the shell -- and one button that sometimes ends the scene and
	sometimes advances it is one mis-set flag away from a player losing their
	hatch by tapping it. Two surfaces solved that, along with a hint line telling
	the player which one they were looking at.

	The egg opens on a timer now, so both are gone and so is the whole class of
	bug: there is exactly one full-screen button on this screen, it only ever
	means skip, and it is only on screen once the pet is.
]]

--[[
	A GLOW, BUILT OUT OF NOTHING.

	Roblox GUI has no radial gradient and no additive blending, so a soft halo is
	normally an imported PNG. This is four concentric circles instead -- a
	UICorner at 999 makes any square a disc -- each bigger and more transparent
	than the last. Four steps is where the banding stops being visible against a
	dark backdrop, and it costs four frames and no asset that could fail to load.

	`set(alpha)` runs the whole stack from invisible to full, so the caller can
	drive it straight off "how cracked is this egg".
]]
local function glowDisc(parent: GuiObject, colour: Color3, zIndex: number, cx: number?, cy: number?)
	local ring = {}
	local holder = Instance.new("Frame")
	holder.Name = "Glow"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	-- Round the EGG, not round the square. The egg sits off to one side on a
	-- floor near the bottom of the shot, and a halo centred on the frame lights
	-- the air beside it. See stagePoint.
	holder.Position = UDim2.fromScale(cx or 0.5, cy or 0.5)
	holder.Size = UDim2.fromScale(1, 1)
	holder.BackgroundTransparency = 1
	holder.ZIndex = zIndex
	holder.Parent = parent

	for i = 1, 4 do
		local d = Instance.new("Frame")
		d.AnchorPoint = Vector2.new(0.5, 0.5)
		d.Position = UDim2.fromScale(0.5, 0.5)
		-- Capped under 1 so the outermost ring cannot spill outside the stage
		-- square and clip against the edge of the screen.
		d.Size = UDim2.fromScale(0.44 + i * 0.13, 0.44 + i * 0.13)
		d.BackgroundColor3 = colour
		d.BackgroundTransparency = 1
		d.BorderSizePixel = 0
		d.ZIndex = zIndex
		d.Parent = holder
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0.5, 0)
		c.Parent = d
		ring[i] = d
	end

	local api = {}
	function api:set(alpha: number)
		alpha = math.clamp(alpha, 0, 1)
		for i, d in ipairs(ring) do
			-- The inner disc is the brightest and the outer ones only ever hint,
			-- which is what a falloff is.
			d.BackgroundTransparency = 1 - alpha * (0.42 / i)
		end
	end
	function api:tint(c: Color3)
		for _, d in ipairs(ring) do
			d.BackgroundColor3 = c
		end
	end
	-- The halo follows the shot. It sits over the EGG, which stands on a floor
	-- near the bottom of the frame, and moves back to the middle of the square
	-- for the reveal, where the pet is framed on a turntable that fills it.
	function api:centre(cx: number, cy: number)
		holder.Position = UDim2.fromScale(cx, cy)
	end
	function api:Destroy()
		holder:Destroy()
	end
	api:set(0)
	return api
end

--------------------------------------------------------------------------
-- SCENE PIECES
--------------------------------------------------------------------------
-- Up front, to the side, and above. Dead-on makes a ball of revolution read as
-- a flat disc; the side angle catches the band and gives it a highlight, and
-- the height is what buys the FLOOR -- enough of a downward tilt that the pad
-- reads as a lit disc with dark above it rather than as an outdoors this scene
-- has no way to light. Shallower than the drop-only shot used, because there is
-- a five-stud person standing in it now and a steep camera looks at the top of
-- their head.
local EGG_DIR = Vector3.new(0.26, 0.28, 1).Unit
-- Hoisted out of eggScene: the stage-position maths below has to agree with the
-- camera the scene is actually shot on, and two 40s in two places is one edit
-- away from disagreeing.
local EGG_FOV = 40
--[[
	FRAMING TWO SUBJECTS, which is what changed.

	This shot used to hold one object -- an egg at the origin -- and the numbers
	here were a frustum sum for exactly that: 10.5 studs at 40 degrees gives a
	3.82-stud half-frame, and a 3.0-stud egg tilted through the peak of a knock
	reaches 2.29 of it, so it could not clip however hard it rocked.

	It holds A PERSON AND AN EGG now, and a person is five studs tall standing
	still. So the camera is further back, the look-at is no longer the origin --
	it sits between the two of them -- and the egg came DOWN to 2.4 so that it
	reads as something a player could pick up rather than something they would
	have to roll.

	Checked by projecting the corners rather than by eye (see stagePoint): at 13
	studs the arriving player's head lands at 0.24 of the square and their feet at
	0.73, the egg sits at 0.65 across and 0.63 down, and the player's starting
	mark is off the left edge at -0.19 -- so they genuinely walk IN from outside
	the frame instead of fading up inside it.
]]
local EGG_DIST = 13.0
local EGG_HEIGHT = 2.4
-- Between the two of them and a little off the floor. The shot is a two-hander,
-- so its centre is neither subject.
local LOOK_AT = Vector3.new(-0.5, 0.45, 0)

-- The floor, in the viewport's own studs. Everything in the scene is measured
-- off it: the egg sits on it, the player walks in across it, the shadow lies on
-- it, and the pet comes up out of it.
local GROUND_Y = -1.9
local EGG_X = 1.0        -- the egg waits right of centre, so the walk in has somewhere to go
local PAD_WIDE = 16      -- across, so its far edge is inside the frame and its near edge is not
local SHADE_WIDE = 2.6   -- the patch of dark under the egg
local PET_TALL = 2.6     -- longest dimension of the animal that climbs out

-- THE PLAYER: where they come in from, where they stop, and how tall the scene
-- makes them. ACTOR_TALL is not a taste -- avatars run from about four studs to
-- seven depending on what somebody is wearing and how they have scaled
-- themselves, and a shot framed for a five-stud character puts a seven-stud
-- one's head out through the top of it.
local ACTOR_START_X = -7.5
local ACTOR_END_X = -1.9
local ACTOR_Z = 0.45
local ACTOR_TALL = 4.8
-- A quarter turn to -90 would face the egg square on and show the camera a
-- flank. Backing 28 degrees off that turns a shoulder toward the lens: the same
-- three-quarter view the station board turns its pets to, for the same reason.
local ACTOR_YAW = math.rad(-62)

--[[
	WHERE A POINT IN THE SCENE LANDS IN THE STAGE SQUARE.

	The GUI effects -- the rings, the shards, the halo -- are drawn in FRONT of
	the viewport rather than inside it (a ViewportFrame draws no particles and no
	GUI), so each one has to be told where the thing it belongs to appears on
	screen. That used to be the middle of the square, which was right for exactly
	as long as the scene was one egg at the origin with the camera pointed at it.

	It is a floor, an egg off to one side and a person now, so a ring thrown at
	the middle bursts in the air beside the egg. Rather than dialling numbers in
	until they look right -- and re-dialling every one of them the next time the
	camera moves a degree -- this projects the point through the same camera the
	scene is shot on, and the constants below fall out of it.

	The stage is square, held there by a UIAspectRatioConstraint, so one
	half-frame serves both axes.
]]
local function stagePoint(p: Vector3): (number, number)
	local eye = LOOK_AT + EGG_DIR * EGG_DIST
	local look = (LOOK_AT - eye).Unit
	local up = (Vector3.yAxis - look * look:Dot(Vector3.yAxis)).Unit
	local right = look:Cross(up).Unit
	local v = p - eye
	local half = v:Dot(look) * math.tan(math.rad(EGG_FOV * 0.5))
	-- Screen y runs down, hence the sign on the second one.
	return 0.5 + (v:Dot(right) / half) * 0.5, 0.5 - (v:Dot(up) / half) * 0.5
end

-- The middle of the egg, which is where everything the egg throws belongs.
local EGG_CX, EGG_CY = stagePoint(Vector3.new(EGG_X, GROUND_Y + EGG_HEIGHT * 0.5, 0))

--[[
	THE PLAYER, IN THEIR OWN CUTSCENE.

	The LIVE character, cloned. A stand-in rig would be somebody else finding the
	egg, and the beat only lands because it is them.

	WHAT COMES OFF THE CLONE, and why each one would bite:

		* EVERY SCRIPT. This is parented under a ScreenGui, which lives in
		  PlayerGui, where LocalScripts RUN -- so a cloned Animate would wake up
		  and start driving a second set of animations against a rig that is
		  meant to be placed by hand.
		* THE HUMANOID, which brings a name tag, a health bar and a state machine
		  with it, none of which belong in a shot.
		* tools, emitters, trails, beams, lights and sounds. A ViewportFrame
		  draws no particles and no lights at all, and a Sound in here would play
		  out of a scene the player is not standing in.

	EVERYTHING IS ANCHORED and the model is moved as one rigid piece. Posing it
	through its Motor6Ds is the better-looking answer and it is not the reliable
	one: it needs the joint pass to run inside a ViewportFrame, and what it falls
	back to on a frame where that does not happen is a T-pose. Anchored, the worst
	case is the player's own standing pose sliding along the floor -- a stiff
	walk rather than a broken avatar -- and the bob and roll below buy back most
	of what the joints would have given.
]]
local function actorScene(world: Instance)
	local char = player.Character
	if not char or not char:FindFirstChildWhichIsA("BasePart") then
		return nil
	end
	--[[
		ARCHIVABLE HAS TO BE TURNED ON FIRST, and this is the whole trick.

		Roblox ships a player's Character with Archivable = false, and Clone() on a
		non-archivable instance does not throw -- IT RETURNS NIL. So the pcall
		succeeds, `clone` is nil, and the scene quietly plays with nobody in it:
		no error, no warning, no character, and nothing anywhere to say why. It
		cost a probe run to find.

		Put back immediately afterwards. This is a local write on a model the
		server owns, so it replicates nowhere, but leaving a flag flipped because
		it happens not to matter is how the next thing to read it gets a surprise.
	]]
	local archivable = char.Archivable
	char.Archivable = true
	local ok, clone = pcall(function()
		return char:Clone()
	end)
	char.Archivable = archivable
	if not ok or not clone then
		return nil
	end

	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("LuaSourceContainer") or d:IsA("Humanoid") or d:IsA("Tool")
			or d:IsA("BillboardGui") or d:IsA("SurfaceGui") or d:IsA("ParticleEmitter")
			or d:IsA("Trail") or d:IsA("Beam") or d:IsA("Light") or d:IsA("Sound") then
			d:Destroy()
		end
	end

	local parts = 0
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			parts += 1
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
		end
	end
	if parts == 0 then
		clone:Destroy()
		return nil
	end

	local root = clone:FindFirstChild("HumanoidRootPart")
		or clone:FindFirstChildWhichIsA("BasePart")
	if not root then
		clone:Destroy()
		return nil
	end
	clone.PrimaryPart = root

	-- Sized BEFORE the rig is read, because ScaleTo moves the joint offsets too:
	-- a C0 captured beforehand would be a full-size offset applied to a shrunken
	-- body, which is an avatar that comes apart at the seams.
	local _, raw = clone:GetBoundingBox()
	pcall(function()
		clone:ScaleTo(ACTOR_TALL / math.max(raw.Y, 0.001))
	end)

	--[[
		THE RIG, READ AS A TREE -- AND WHY THE POSE IS THROWN AWAY FIRST.

		A cloned character is frozen in whatever frame of whatever animation the
		player happened to be in when they pressed the prompt, and in this game
		they are usually raking. The first run of this scene put a man bent
		double at the waist with his arms hanging in front of him, sliding along
		the floor like that for five seconds, because that is what he was doing
		at the pedestal. Nothing was wrong with the placement. It was a
		photograph of the wrong moment.

		So the pose is discarded and rebuilt from the JOINTS. Every Motor6D
		carries the offset its two parts sit at when nothing is animating them --
		C0 and C1 -- and that is the neutral standing pose the rig was authored
		in. Walking the tree from the root and writing

			child = parent * C0 * bend * C1:Inverse()

		stands the character back up, and leaves a slot in the middle of it for
		this scene to bend. `bend` is the whole difference between an animation
		and a statue being dragged about.

		ACCESSORIES COME ALONG because they hang off the same kind of joint: a
		Weld has a C0 and a C1 exactly as a motor does. A WeldConstraint has
		neither, so its offset is read off its two parts before anything has
		moved and used as the C0 it does not have. Miss that and the hat stays
		hanging where the head used to be.

		Every part is ANCHORED and written directly, so none of this depends on
		Roblox evaluating joints inside a ViewportFrame -- which is not
		documented either way, and is an odd thing to bet a cutscene on.
	]]
	local joints, byName = {}, {}
	do
		--[[
			THE TREE IS UNDIRECTED, AND THAT IS NOT A DETAIL.

			A Motor6D runs Part0 -> Part1, and the body's motors are all oriented
			outward from the root, so following Part0 to Part1 walks the skeleton
			in the right order. AN ACCESSORY IS WELDED THE OTHER WAY ROUND: the
			Handle is Part0 and the head is Part1. A strictly forward walk
			therefore never reaches the hat -- and a part the walk never reaches
			is never moved, so it stays standing at the player's position IN THE
			WORLD, a hundred studs from this scene. The bounding box measured off
			the model afterwards then spans that whole distance, the root height
			taken from it is nonsense, and the character is placed a hundred
			studs up: on screen, a speck in the corner of the shot. That is
			exactly what happened.

			So every joint is entered twice, once each way, and whichever end the
			walk reaches first becomes the parent. The reversed copy carries the
			inverse offset and is never bent -- a bend written for a shoulder
			means nothing applied backwards through a hat.
		]]
		local kids = {}
		local function link(p0, p1, c0, c1inv, name, flip)
			kids[p0] = kids[p0] or {}
			table.insert(kids[p0], { part = p1, c0 = c0, c1inv = c1inv, name = name, flip = flip })
		end

		--[[
			THREE WAYS A LIMB CAN BE ATTACHED TO ANOTHER ONE, and this rig uses
			the one nobody writes about.

			The first pass looked for Motor6Ds, because that is what an R15
			character has been made of for ten years. THIS CHARACTER HAS NONE --
			not one JointInstance anywhere in it. Roblox's current avatar rig is
			built from AnimationConstraints between Attachments, with
			BallSocketConstraints alongside them for the physics, and the whole
			skeleton is invisible to a scan that asks for joints.

			It failed SILENTLY and it looked like a maths problem: every part fell
			through to the pin-to-root fallback below, which reproduces the pose
			the clone arrived in exactly, so the character kept the raking pose
			and the rebuild appeared to be a no-op that had been written wrong.
			The giveaway was the bounding box coming out at precisely the
			original depth times the scale factor.

			An AnimationConstraint holds Attachment1's part so that the two
			attachments coincide, which is the same relationship a motor's C0 and
			C1 describe -- so the attachment CFrames drop straight into the same
			formula, and a rig of either kind comes out standing.
		]]
		for _, d in ipairs(clone:GetDescendants()) do
			local p0, p1, c0, c1
			if d:IsA("JointInstance") and d.Part0 and d.Part1 then
				p0, p1, c0, c1 = d.Part0, d.Part1, d.C0, d.C1
			elseif (d.ClassName == "AnimationConstraint" or d.ClassName == "RigidConstraint")
				and d.Attachment0 and d.Attachment1 then
				-- The current rig: the body hangs off AnimationConstraints and the
				-- accessories off RigidConstraints. BallSocketConstraints are
				-- deliberately NOT read -- they link the same pairs of parts for
				-- the physics solver, and taking both would enter every limb twice.
				local q0, q1 = d.Attachment0.Parent, d.Attachment1.Parent
				if q0 and q0:IsA("BasePart") and q1 and q1:IsA("BasePart") then
					p0, p1 = q0, q1
					c0, c1 = d.Attachment0.CFrame, d.Attachment1.CFrame
				end
			elseif d:IsA("WeldConstraint") and d.Part0 and d.Part1 then
				-- No C0 or C1 to read, so the offset the two parts are sitting
				-- at right now IS the offset. Taken here, before anything has
				-- moved, because a moment later it would not be.
				p0, p1 = d.Part0, d.Part1
				c0, c1 = p0.CFrame:ToObjectSpace(p1.CFrame), CFrame.identity
			end
			if p0 and p1 and p0 ~= p1 then
				link(p0, p1, c0, c1:Inverse(), d.Name, false)
				link(p1, p0, c1, c0:Inverse(), d.Name, true)
			end
		end

		-- Breadth first from the root, so a part is never placed before the one
		-- it hangs off has been.
		local seen = { [root] = true }
		local queue, head = { root }, 1
		while head <= #queue do
			local p = queue[head]
			head += 1
			for _, k in ipairs(kids[p] or {}) do
				if not seen[k.part] then
					seen[k.part] = true
					local rec = {
						parent = p, part = k.part, name = k.name,
						c0 = k.c0, c1inv = k.c1inv, flip = k.flip,
					}
					table.insert(joints, rec)
					if not k.flip then
						byName[k.name] = rec
					end
					table.insert(queue, k.part)
				end
			end
		end

		-- Anything the tree still does not reach -- a part welded by something
		-- with a nil Part0, a loose decoration parented into the character -- is
		-- pinned to the root at the offset it arrived with. Leaving it alone is
		-- not an option, for the reason in the note above: one forgotten part
		-- back at the player's world position drags the bounding box across the
		-- map and takes the height measurement with it.
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") and not seen[d] then
				seen[d] = true
				table.insert(joints, {
					parent = root, part = d, name = "", flip = true,
					c0 = root.CFrame:ToObjectSpace(d.CFrame), c1inv = CFrame.identity,
				})
			end
		end
	end

	local function pose(rootCF: CFrame, bend: { [string]: CFrame }?)
		root.CFrame = rootCF
		for _, j in ipairs(joints) do
			local b = (bend and not j.flip) and bend[j.name] or nil
			j.part.CFrame = j.parent.CFrame * j.c0 * (b or CFrame.identity) * j.c1inv
		end
	end

	-- Stood up once, square on, to measure how high the root sits above the
	-- soles. Everything after this places the ROOT and lets the legs say where
	-- the floor is -- which is why bending at the waist does not push the feet
	-- through the pad the way tipping the whole body did.
	pose(CFrame.new())
	local cf, box = clone:GetBoundingBox()
	local rootUp = root.Position.Y - (cf.Position.Y - box.Y * 0.5)

	clone.Name = "Actor"
	clone.Parent = world
	return {
		model = clone,
		pose = pose,
		rootUp = rootUp,
		-- R6 has no Waist, and its shoulders and hips do not share R15's axis
		-- convention -- the bends written for R15 would come out on one as a
		-- shrug and a splay. Those rigs, and any rig whose skeleton this did not
		-- manage to read, get the shot without the limb animation rather than
		-- with a broken one.
		rigged = byName.Waist ~= nil,
	}
end

--[[
	The egg, rebuilt rather than cloned off the pedestal.

	Cloning the STATION's egg is tempting and wrong: the station is a hundred
	studs away behind a prompt, it can be streamed out, and on the plazas the
	player has not visited yet it does not exist on this client at all. So the
	egg on the screen is built here -- but out of the SAME shell mesh the station
	uses, staged in ReplicatedStorage.Assets.EggShell where both halves of the
	game can reach it, and painted in the same PetConfig colour. The egg that
	cracks is the egg that was on the pedestal because they are the same asset.

	The old recipe was a squashed ball with a cylinder band round it. It falls
	back to exactly that if the asset is missing, because a hatch that plays with
	a rounder egg is a hatch, and a hatch that throws is a player stuck behind a
	backdrop with no HUD.

	The band is kept as a real part in the fallback and as an empty stand-in
	otherwise, so the caller's wobble can keep writing to it without asking which
	egg it got.
]]
local function eggScene(parent: GuiObject, eggDef)
	local vpf = Instance.new("ViewportFrame")
	vpf.Name = "EggScene"
	vpf.AnchorPoint = Vector2.new(0.5, 0.5)
	vpf.Position = UDim2.fromScale(0.5, 0.5)
	vpf.Size = UDim2.fromScale(1, 1)
	vpf.BackgroundTransparency = 1
	vpf.Ambient = Color3.fromRGB(152, 148, 162)
	vpf.LightColor = Color3.fromRGB(255, 250, 238)
	vpf.LightDirection = Vector3.new(-0.4, -1, -0.45)
	vpf.ZIndex = 6
	vpf.Parent = parent

	-- A WorldModel, not a bare parent: without one a ViewportFrame does no
	-- lighting pass and everything comes out flat and muddy. PanelKit's
	-- turntable records the same thing.
	local world = Instance.new("WorldModel")
	world.Parent = vpf

	--[[
		THE SHELL THE PEDESTAL WAS WEARING, looked up by the egg's own key.

		Assets.EggShells holds one textured mesh per egg, normalised to a stud
		tall, cut from the same modelled egg that is suspended in that shelf's
		tube -- so the egg that cracks here is the egg the player was standing in
		front of. The moment the two disagree the hatch stops being the opening of
		that egg and becomes a cutscene about a different one, which is exactly
		what happened while the tubes carried four eggs and this folder had three.

		NOT TINTED when it carries its own art. MeshPart.Color MULTIPLIES the
		texture, so running a gold egg through the Prestige lilac gives a brown
		one -- and the importer's default grey is 0.64, which is why the whole
		pack looked muddy until every part of it was set to white.
	]]
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local shells = assets and assets:FindFirstChild("EggShells")
	local ownArt = true
	local template = shells and eggDef.key and shells:FindFirstChild(eggDef.key)
	if not (template and template:IsA("BasePart")) then
		template = assets and assets:FindFirstChild("EggShell")
		ownArt = false
	end

	local shell, band
	if template and template:IsA("BasePart") then
		shell = template:Clone()
		shell.Name = "Shell"
		-- PARKED AT THE ORIGIN, EXPLICITLY, because a clone inherits the
		-- template's CFrame and the template is a Creator Store part that came
		-- out of the kit standing on a pedestal at (-117, 12.8, 61) with a
		-- quarter turn on it. The viewport camera looks at the origin, so an
		-- inherited CFrame puts the egg twelve studs off the top of frame -- and
		-- the only reason that was ever survivable is that the wobble below
		-- overwrites it on the first RenderStepped. Depending on a later loop to
		-- undo a bad starting value is how you get a one-frame flash of nothing.
		shell.CFrame = CFrame.new()
		-- The template is one stud tall, so this is the height in studs. See the
		-- frustum note by EGG_DIST for why it is this number and not a larger one.
		shell.Size = template.Size * EGG_HEIGHT
		shell.Color = ownArt and Color3.new(1, 1, 1) or eggDef.color
		shell.Material = Enum.Material.SmoothPlastic
		shell.Anchored = true
		shell.CanCollide = false
		shell.Parent = world

		-- Nothing to draw, but the wobble writes a CFrame to it every frame.
		band = Instance.new("Part")
		band.Name = "Band"
		band.Size = Vector3.one
		band.CFrame = CFrame.new()
		band.Transparency = 1
		band.Anchored = true
		band.CanCollide = false
		band.Parent = world
	else
		shell = Instance.new("Part")
		shell.Name = "Shell"
		shell.Shape = Enum.PartType.Ball
		shell.Size = Vector3.new(3.1, 3.9, 3.1)
		shell.Color = eggDef.color
		shell.Material = Enum.Material.SmoothPlastic
		shell.Anchored = true
		shell.CanCollide = false
		shell.Parent = world

		band = Instance.new("Part")
		band.Name = "Band"
		band.Shape = Enum.PartType.Cylinder
		band.Size = Vector3.new(0.42, 3.24, 3.24)
		band.Color = eggDef.accent
		band.Material = Enum.Material.SmoothPlastic
		band.Anchored = true
		band.CanCollide = false
		band.Parent = world
	end

	-- On its mark before the first frame is drawn. The loop that animates the egg
	-- does not run until the next RenderStepped, and a shell left at the origin
	-- for that one frame is a shell buried halfway through the pad.
	local rest = CFrame.new(EGG_X, GROUND_Y + shell.Size.Y * 0.5, 0)
	shell.CFrame = rest
	band.CFrame = rest * CFrame.Angles(0, 0, math.rad(90))

	--[[
		THE FLOOR, AND THE PATCH OF DARK UNDER THE EGG.

		Nothing can be FOUND in a void -- there has to be a somewhere for the egg
		to have been lying in. The pad is a plain disc rather than a plane because
		a plane has a horizon and a disc has an EDGE, and an edge inside the frame
		with darkness above it reads as a lit platform, which is the shot; a
		horizon reads as an outdoors this scene has no way to light.

		The shade is what sits the egg ON the pad rather than in front of it, and
		it tightens and darkens as the egg hops on a knock. It stays FLAT on the
		floor: a shadow that travels up with the egg is a decal stuck to it.

		Both are cylinders on their side -- a Roblox cylinder runs along its X
		axis, so a quarter turn about Z stands one up as a disc.
	]]
	local pad = Instance.new("Part")
	pad.Name = "Pad"
	pad.Shape = Enum.PartType.Cylinder
	pad.Size = Vector3.new(0.7, PAD_WIDE, PAD_WIDE)
	-- Half a thickness down, so the pad's TOP is exactly GROUND_Y.
	pad.CFrame = CFrame.new(0, GROUND_Y - 0.35, 0) * CFrame.Angles(0, 0, math.rad(90))
	pad.Color = PanelKit.darken(eggDef.color, 0.66)
	pad.Material = Enum.Material.SmoothPlastic
	pad.Anchored = true
	pad.CanCollide = false
	pad.Parent = world

	local shade = Instance.new("Part")
	shade.Name = "Shade"
	shade.Shape = Enum.PartType.Cylinder
	shade.Size = Vector3.new(0.06, SHADE_WIDE, SHADE_WIDE)
	-- A hair proud of the pad. Flush is a z-fight.
	shade.CFrame = CFrame.new(EGG_X, GROUND_Y + 0.04, 0) * CFrame.Angles(0, 0, math.rad(90))
	shade.Color = Color3.new(0, 0, 0)
	shade.Material = Enum.Material.SmoothPlastic
	shade.Transparency = 0.55
	shade.Anchored = true
	shade.CanCollide = false
	shade.Parent = world

	-- The player walks in beside it. Nil is a perfectly good answer -- somebody
	-- who is mid-respawn has no character to clone -- and the scene plays without
	-- them rather than not playing.
	local actor = actorScene(world)

	local cam = Instance.new("Camera")
	cam.FieldOfView = EGG_FOV
	cam.CFrame = CFrame.lookAt(LOOK_AT + EGG_DIR * EGG_DIST, LOOK_AT)
	cam.Parent = vpf
	vpf.CurrentCamera = cam

	return vpf, shell, band, shade, actor
end

-- Shrapnel, as GUI. A ViewportFrame does NOT render ParticleEmitters -- the
-- old sequence's 70-particle burst would simply not have appeared in here --
-- so the shell comes apart in front of the viewport instead of inside it.
local function shardBurst(parent: GuiObject, a: Color3, b: Color3, n: number, cx: number?, cy: number?)
	local across, mid = cx or 0.5, cy or 0.5
	for i = 1, n do
		local ang = (i / n) * math.pi * 2 + (math.random() - 0.5) * 0.5
		local far = 0.30 + math.random() * 0.42
		local sh = Instance.new("Frame")
		sh.Name = "Shard"
		sh.AnchorPoint = Vector2.new(0.5, 0.5)
		sh.Position = UDim2.fromScale(across, mid)
		sh.Size = UDim2.fromScale(0.036, 0.046)
		sh.BackgroundColor3 = (i % 3 == 0) and b or a
		sh.BorderSizePixel = 0
		sh.Rotation = math.random(0, 359)
		sh.ZIndex = 9
		sh.Parent = parent
		PanelKit.corner(sh, 3)
		TweenService:Create(sh, TweenInfo.new(0.8, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
			Position = UDim2.fromScale(across + math.cos(ang) * far, mid + math.sin(ang) * far),
			Rotation = sh.Rotation + math.random(-280, 280),
			Size = UDim2.fromScale(0.006, 0.008),
			BackgroundTransparency = 1,
		}):Play()
		Debris:AddItem(sh, 0.95)
	end
end

--[[
	A SHOCKWAVE, one per hit.

	The shell taking a knock is a rotation, and a rotation on a round object is
	the hardest motion in the world to see -- three clicks all landed and only
	the sound said so. A ring thrown off the egg the instant it is struck puts
	the impact somewhere the eye cannot miss it, and it expands outward, which
	is the one direction nothing else on this screen is moving.

	In front of the viewport rather than inside it, for the same reason the
	shards are: a ViewportFrame draws no particles and no GUI of its own.
]]
local function shockwave(parent: GuiObject, colour: Color3, cx: number?, cy: number?)
	local w = Instance.new("Frame")
	w.Name = "Shock"
	w.AnchorPoint = Vector2.new(0.5, 0.5)
	-- Where the hit happened, which is the middle of the egg and not the middle
	-- of the square. See stagePoint.
	w.Position = UDim2.fromScale(cx or 0.5, cy or 0.5)
	w.Size = UDim2.fromScale(0.34, 0.34)
	w.BackgroundTransparency = 1
	w.ZIndex = 8
	w.Parent = parent
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.5, 0)
	round.Parent = w

	local edge = Instance.new("UIStroke")
	edge.Thickness = 4
	edge.Color = colour
	edge.Transparency = 0.1
	edge.Parent = w

	-- Quint out: nearly all of the travel happens in the first fifth of a
	-- second, which is what a shock is. A linear ring is a smoke signal.
	TweenService:Create(w, TweenInfo.new(0.55, Enum.EasingStyle.Quint,
		Enum.EasingDirection.Out), { Size = UDim2.fromScale(1.15, 1.15) }):Play()
	TweenService:Create(edge, TweenInfo.new(0.55, Enum.EasingStyle.Quad,
		Enum.EasingDirection.Out), { Transparency = 1, Thickness = 0.5 }):Play()
	Debris:AddItem(w, 0.7)
end

--------------------------------------------------------------------------
-- THE SEQUENCE
--------------------------------------------------------------------------
-- 176 tall is not a round number: the body PanelKit.card leaves is (h - 74), so
-- this is the name (32) + the luck line (22) + the EQUIP button's own 47 with
-- a stud of air between them. At the 128 it started at, the button overlapped
-- the luck line and the luck line overlapped the name.
local CARD_W, CARD_H = 430, 176

local active = false
local token = 0
local liveStage = {}   -- everything this run made inside `stage`, to sweep up

local function clearStage()
	for _, inst in liveStage do
		if typeof(inst) == "table" and inst.Destroy then
			pcall(function() inst:Destroy() end)
		elseif typeof(inst) == "Instance" then
			inst:Destroy()
		end
	end
	table.clear(liveStage)
	for _, c in stage:GetChildren() do
		if not c:IsA("UIAspectRatioConstraint") then
			c:Destroy()
		end
	end
	for _, c in backdrop:GetChildren() do
		if c.Name == "Shard" or c.Name == "Flash" or c.Name == "RevealCard" then
			c:Destroy()
		end
	end
end

--[[
	ONE WAY OUT, and everything calls it: the sequence's own tail, the card's X,
	the skip surface, the watchdog, respawning, and the pcall round playHatch.
	It is idempotent because half of those can fire in either order.
]]
finish = function(tok: number?)
	--[[
		The token is what stops a FINISHED run tearing down a LIVE one.

		Every exit from playHatch is followed by a belt-and-braces finish() from
		the wiring, and between an early exit and that call there is a yield --
		so a second HatchEgg can land, start a new run and put a new screen up,
		and the old run's tidy-up would pull it straight back down again. Passing
		the token the caller believes it owns makes that a no-op.

		No token means "tear down whatever is up", which is what the X, the skip
		surface, the watchdog and a respawn all want.
	]]
	if not active or (tok ~= nil and tok ~= token) then
		return
	end
	active = false
	token += 1

	TweenService:Create(backdrop, TweenInfo.new(0.34), { BackgroundTransparency = 1 }):Play()
	TweenService:Create(vign, TweenInfo.new(0.34), { BackgroundTransparency = 1 }):Play()
	TweenService:Create(eggTitle, TweenInfo.new(0.22), { TextTransparency = 1 }):Play()
	TweenService:Create(eggTitleStroke, TweenInfo.new(0.22), { Transparency = 1 }):Play()
	for _, b in blades do
		TweenService:Create(b, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
	end
	local card = backdrop:FindFirstChild("RevealCard")
	if card then
		TweenService:Create(card, TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
			Position = UDim2.new(0.5, 0, 1.35, 0),
		}):Play()
	end
	for _, c in stage:GetChildren() do
		if c:IsA("GuiObject") then
			TweenService:Create(c, TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
				Size = UDim2.fromScale(0.1, 0.1),
			}):Play()
		end
	end

	skip.Visible = false
	showHud()
	thaw()

	local mine = token
	task.delay(0.42, function()
		if not active and token == mine then
			hatchGui.Enabled = false
			clearStage()
		end
	end)
	hatching = false
end

-- Returns the token of the run it started, so the caller's tidy-up can tell
-- whether the screen still belongs to it. See finish().
playHatch = function(payload): number?
	local def = PetConfig.get(payload.petId)
	if not def then
		return nil
	end
	local eggDef = PetConfig.eggFor(payload.eggKey)
		or { name = "EGG", color = CREAM, accent = Color3.fromRGB(126, 205, 158) }
	local tier = PetConfig.tierInfo(payload.tier)

	hatching = true
	active = true
	token += 1
	local mine = token
	local function stale()
		return token ~= mine or not active
	end

	-- The watchdog. Everything below yields, and a yield that never comes back
	-- would strand the player behind an opaque screen with no HUD and no legs.
	task.delay(22, function()
		if token == mine then
			finish()
		end
	end)

	clearStage()
	hideHud()
	freeze()
	AudioKit.dipMusic(0.3, 9)

	----------------------------------------------------------------
	-- 1. THE CURTAIN  --  to black
	----------------------------------------------------------------
	hatchGui.Enabled = true
	skip.Visible = false
	backdrop.BackgroundColor3 = CURTAIN
	backdrop.BackgroundTransparency = 1
	vign.BackgroundTransparency = 1
	rayHub.Rotation = 0
	for _, b in blades do
		b.BackgroundColor3 = eggDef.accent
		b.BackgroundTransparency = 1
	end
	TweenService:Create(backdrop, TweenInfo.new(0.4), { BackgroundTransparency = 0 }):Play()
	TweenService:Create(vign, TweenInfo.new(0.4), { BackgroundTransparency = 0.45 }):Play()
	-- THE RAYS STAY OFF UNTIL THE EGG IS DOWN. They are the "something is coming
	-- out of this" shorthand, and while the egg is still in the air nothing is
	-- coming out of anything -- up there all they say is that the shot has
	-- started, which the curtain already said.
	AudioKit.play("SwingWhoosh", nil, 0.8, 0.7)

	eggTitle.Text = string.upper(payload.eggName or eggDef.name or "EGG")
	eggTitle.TextColor3 = eggDef.accent
	TweenService:Create(eggTitle, TweenInfo.new(0.35), { TextTransparency = 0 }):Play()
	TweenService:Create(eggTitleStroke, TweenInfo.new(0.35), { Transparency = 0 }):Play()

	local raySpin = 5
	local rayConn = RunService.RenderStepped:Connect(function(dt)
		rayHub.Rotation += dt * raySpin
	end)
	table.insert(liveStage, { Destroy = function() rayConn:Disconnect() end })

	----------------------------------------------------------------
	-- 2. THE FIND  --  the player walks in and stoops over the egg
	----------------------------------------------------------------
	local vpf, shell, band, shade, actor = eggScene(stage, eggDef)
	-- NO SCALE-UP ON THE VIEWPORT. What arrives in this shot is the PLAYER, and a
	-- frame that is zooming in underneath them turns one clear motion into two
	-- vague ones.
	vpf.Size = UDim2.fromScale(1, 1)

	-- The WorldModel the egg is sitting in. The animal is parented into the same
	-- one when it climbs out, so it arrives in this shot rather than in a new
	-- one.
	local world = shell.Parent
	local baseSize = shell.Size

	--[[
		LIGHT COMING OUT OF THE SHELL.

		A second copy of the same mesh a hair larger, in Neon and the egg's accent,
		invisible to start with and brought up one step per knock -- so the egg does
		not merely get LOUDER as it is hit, it starts to glow from the inside. It is
		the clearest way to say "something in here is coming out" without crack
		decals, which would have to be authored per mesh and would slide about on a
		shell that is turning.

		Neon ignores the viewport's lighting, so this reads as emitted light and not
		as a paler egg. The texture is dropped where the engine allows it, because a
		patterned glow reads as a second egg behind the first; where it does not,
		the tinted result is still a glow and still better than nothing.
	]]
	local aura = shell:Clone()
	aura.Name = "Aura"
	aura.Size = shell.Size * 1.035
	pcall(function()
		aura.TextureID = ""
	end)
	aura.Color = eggDef.accent
	aura.Material = Enum.Material.Neon
	aura.Transparency = 1
	aura.CastShadow = false
	aura.Parent = shell.Parent

	--[[
		THE SCENE, AS ONE FUNCTION OF TIME.

		Everything that moves in this shot -- how far along their walk the player
		is, how far over the egg they are stooping, how hard the egg is rocking --
		is computed from the clock inside one loop rather than driven by a chain
		of tweens. The loop has to know where all of it IS on every frame anyway,
		to keep the shadow under the egg and the player's feet on the floor, and
		two systems writing one position is how a character walks twice.
	]]
	local WALK_IN = 1.35      -- seconds from off frame to standing over the egg
	local STOOP_FOR = 0.45    -- and then down over it
	local ARRIVE_AT = WALK_IN + STOOP_FOR
	-- When the thing inside knocks, measured from the top of the scene. The
	-- first lands a quarter second after the player has settled over it: long
	-- enough to be a surprise, close enough that they are still bent down.
	local KNOCKS = { 2.05, 2.65, 3.20 }

	-- An impact, decaying: full at the moment of contact and gone a fifth of a
	-- second later. Squared so it drops away fast and then lingers, which is the
	-- shape a struck object actually rings with.
	local function squashAt(dt: number): number
		return math.max(0, 1 - dt / 0.20) ^ 2
	end

	local glow = glowDisc(stage, eggDef.accent, 3, EGG_CX, EGG_CY)
	table.insert(liveStage, glow)

	local knocks = 0
	local lastHit = -9
	local t0 = os.clock()

	local wobble
	wobble = RunService.RenderStepped:Connect(function()
		if not shell.Parent then
			wobble:Disconnect()
			return
		end
		local t = os.clock() - t0
		local since = os.clock() - lastHit
		local hit = math.max(0, 1 - since / 0.5) ^ 2
		local done = knocks / #KNOCKS

		------------------------------------------------------------------
		-- THE EGG, which is DEAD STILL until something inside it moves.
		--
		-- An egg already rocking when the player walks up has not been found by
		-- them, it has been caught in the act -- and the walk in stops being a
		-- discovery and becomes an approach to something already happening.
		------------------------------------------------------------------
		local hop, squash = 0, 0
		if knocks > 0 then
			if since < 0.26 then
				hop = math.sin(since / 0.26 * math.pi) * 0.30
			else
				squash = squashAt(since - 0.26)
			end
		end
		-- Idle is a slow uneasy sway; a knock is a fast hard one on top of it.
		-- 13 degrees, not 20: a knock has to read as a hit and not a swing, and
		-- at 20 the egg rolled far enough that its silhouette left the frame.
		local lean = (knocks > 0)
			and (math.sin(t * (3.0 + 3 * done)) * math.rad(2 + 4 * done)
				+ math.sin(since * 46) * math.rad(13) * hit)
			or 0

		-- Squash and stretch, roughly holding volume, so the shell reads as
		-- something that GIVES rather than something being scaled.
		shell.Size = baseSize * Vector3.new(1 + squash * 0.13, 1 - squash * 0.20, 1 + squash * 0.13)
		aura.Size = shell.Size * 1.035

		--[[
			BUILT FROM THE CONTACT POINT UP, which is the difference between
			rocking and hovering: an egg on a floor rotating about its own CENTRE
			swings its bottom down through the floor. Rotate first, then step half
			a shell along the rotated Y, and it pivots on the spot it is standing
			on.
		]]
		local foot = CFrame.new(EGG_X, GROUND_Y + hop, 0) * CFrame.Angles(0, 0, lean)
		local base = foot * CFrame.new(0, shell.Size.Y * 0.5, 0)
		shell.CFrame = base
		band.CFrame = base * CFrame.Angles(0, 0, math.rad(90))
		-- Rides the shell exactly, so the light stays INSIDE the egg instead of
		-- trailing a knock by a frame and reading as a halo stuck to the air.
		aura.CFrame = base
		aura.Transparency = 1 - math.clamp(done * 0.5 + hit * 0.3, 0, 1)

		-- The patch of dark stays FLAT ON THE FLOOR and only changes size.
		local spread = 1 + hop * 0.55
		shade.Size = Vector3.new(0.06, SHADE_WIDE * spread, SHADE_WIDE * spread)
		shade.Transparency = math.clamp(0.5 + hop * 0.4, 0, 1)

		glow:set(done * 0.7 + hit * 0.25)

		------------------------------------------------------------------
		-- THE PLAYER: walk in, stoop over it, flinch when it moves.
		------------------------------------------------------------------
		if actor then
			local walk = math.clamp(t / WALK_IN, 0, 1)
			-- Smoothstep, so they set off and they arrive rather than starting
			-- and stopping at full speed.
			local eased = walk * walk * (3 - 2 * walk)
			-- The steps fade in and out with the travel, so the moments at each
			-- end where the character is not going anywhere are still.
			local striding = 1 - (walk * 2 - 1) ^ 2
			local swing = math.sin(t * 9) * striding
			local stoop = math.clamp((t - WALK_IN) / STOOP_FOR, 0, 1)
			stoop = stoop * stoop * (3 - 2 * stoop)

			local bend
			if actor.rigged then
				-- Down over the egg, and snapping back off every knock. `hit`
				-- is the same decaying impact the shell rocks on, so the flinch
				-- and the knock are the same event rather than two things that
				-- happen to be near each other.
				local over = math.rad(-34) * stoop + math.rad(22) * hit
				bend = {
					-- Legs in opposition, and knees that only fold the way a
					-- knee folds -- half a cycle each, never both at once.
					LeftHip = CFrame.Angles(math.rad(28) * swing, 0, 0),
					RightHip = CFrame.Angles(-math.rad(28) * swing, 0, 0),
					LeftKnee = CFrame.Angles(-math.rad(34) * math.max(0, -swing), 0, 0),
					RightKnee = CFrame.Angles(-math.rad(34) * math.max(0, swing), 0, 0),
					-- Arms swing against the legs, then come forward with the
					-- stoop: somebody bending to look at something reaches for
					-- it, they do not leave their arms behind.
					LeftShoulder = CFrame.Angles(-math.rad(22) * swing + over * 0.5, 0, 0),
					RightShoulder = CFrame.Angles(math.rad(22) * swing + over * 0.5, 0, 0),
					Waist = CFrame.Angles(over, 0, 0),
					Neck = CFrame.Angles(math.rad(-18) * stoop + math.rad(12) * hit, 0, 0),
				}
			end

			actor.pose(
				CFrame.new(
						ACTOR_START_X + (ACTOR_END_X - ACTOR_START_X) * eased,
						-- The ROOT is placed and the legs hang off it, so the
						-- soles land on the floor by construction.
						GROUND_Y + actor.rootUp + math.abs(math.sin(t * 9)) * 0.10 * striding,
						ACTOR_Z)
					* CFrame.Angles(0, ACTOR_YAW, 0)
					-- A rigged character bends at the waist. One that is not
					-- tips as a single piece, which is the whole of what it can
					-- do without joints to bend.
					* CFrame.Angles(actor.rigged and 0
						or (math.rad(-20) * stoop + math.rad(26) * hit), 0, 0)
					* CFrame.Angles(0, 0, math.sin(t * 9) * math.rad(3.5) * striding),
				bend)
		end
	end)
	table.insert(liveStage, { Destroy = function() wobble:Disconnect() end })

	-- THE ARRIVAL. They reach it, they stoop over it, and the light comes up --
	-- which is the moment the egg stops being scenery.
	task.wait(ARRIVE_AT)
	if stale() then
		return mine
	end
	AudioKit.play("WoodTick", nil, 0.5, 0.7)
	-- NOW the rays come up. Until this point the player was walking past a
	-- stone, and rays behind a stone give the whole thing away.
	tintRays(eggDef.accent, 0.82)
	raySpin = 9

	----------------------------------------------------------------
	-- 3. THE KNOCKING  --  three, on a timer, each harder than the last
	----------------------------------------------------------------
	for i, at in ipairs(KNOCKS) do
		-- Scheduled against t0 rather than slept for in turn, so one long frame
		-- cannot push everything after it out of time with the loop above.
		local due = at - (os.clock() - t0)
		if due > 0 then
			task.wait(due)
		end
		if stale() then
			return mine
		end
		knocks = i
		lastHit = os.clock()
		-- Each knock is a shade higher and louder than the last: the shell is
		-- getting thinner, and the ear reads rising pitch as something about to
		-- give.
		AudioKit.play("EggCrack", nil, 0.85 + i * 0.12, 0.92 + i * 0.09)
		raySpin += 7
		shockwave(stage, eggDef.accent, EGG_CX, EGG_CY)
		shardBurst(stage, eggDef.color, eggDef.accent, 3 + i * 2, EGG_CX, EGG_CY)
	end

	-- A beat on the last knock before the shell gives, so the third hit is seen
	-- to be the one that did it rather than being swallowed by what follows.
	task.wait(0.3)
	if stale() then
		return mine
	end

	----------------------------------------------------------------
	-- 4. THE PET COMES OUT
	----------------------------------------------------------------
	wobble:Disconnect()

	--[[
		THE SHELL GOES BY SWELLING AND FADING, not by being cut.

		Cutting it is one frame with an egg and the next frame without one, which
		the eye reads as a fault in the picture. Letting it blow outward and
		vanish over a quarter of a second, with the shards thrown in front of the
		viewport on the same frame, keeps it ONE object going from closed to open
		-- and leaves the animal standing where the egg was rather than wherever a
		new shot decided to put it.
	]]
	local shellOut = TweenInfo.new(0.26, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(shell, shellOut, { Size = shell.Size * 1.4, Transparency = 1 }):Play()
	TweenService:Create(aura, shellOut, { Size = aura.Size * 1.5, Transparency = 1 }):Play()
	AudioKit.play("EggShatter", nil, 1, 1)
	shardBurst(stage, eggDef.color, eggDef.accent, 20, EGG_CX, EGG_CY)
	shockwave(stage, eggDef.accent, EGG_CX, EGG_CY)
	-- The player flinches off this one as well. The loop reads `lastHit` for the
	-- recoil, and the shell letting go is the hardest hit in the scene.
	lastHit = os.clock()

	--[[
		AND THE ANIMAL CLIMBS OUT OF THE FLOOR.

		Scaled to the SHOT and not to the animal: the roster is authored at wildly
		different sizes, and a Kraken arriving at eight times a duckling's height
		would simply be off frame.

		Driven by hand on RenderStepped rather than through TweenService, because
		what is being eased is a Model's SCALE together with its height off the
		floor and a tween can drive neither. `ScaleTo` is absolute against the
		model's ORIGINAL size, so re-issuing it every frame is stable rather than
		compounding -- and it scales about the model's PIVOT, which is wherever
		the exporter happened to leave it, so the bounding box is measured back
		afterwards and the animal is placed by its own feet. Without that it sinks
		through the pad as it grows.
	]]
	local emerge = petModel(def)
	if emerge and world then
		emerge.Name = "Emerging"
		emerge.Parent = world
		local _, box = emerge:GetBoundingBox()
		local fit = PET_TALL / math.max(box.X, box.Y, box.Z, 0.001)
		-- Turned a little off the camera: a three-quarter view reads as an animal,
		-- dead-on reads as a mugshot. The station board turns its pets by the same
		-- angle for the same reason.
		emerge:PivotTo(CFrame.new(emerge:GetPivot().Position) * CFrame.Angles(0, math.rad(28), 0))

		local riseT0 = os.clock()
		local rise
		rise = RunService.RenderStepped:Connect(function()
			if not emerge.Parent then
				rise:Disconnect()
				return
			end
			local u = math.clamp((os.clock() - riseT0) / 0.55, 0, 1)
			-- Back-out: it overshoots and settles, which is the difference between
			-- a pop and an inflation.
			local e = 1 + 2.70158 * (u - 1) ^ 3 + 1.70158 * (u - 1) ^ 2
			emerge:ScaleTo(fit * (0.3 + 0.7 * e))
			local cf, size = emerge:GetBoundingBox()
			-- Starts UNDER the pad and rises out of it. The pad is opaque and the
			-- camera is above it, so under it is genuinely out of sight.
			local sunk = (1 - e) * 1.5
			emerge:TranslateBy(Vector3.new(EGG_X, GROUND_Y + size.Y * 0.5 - sunk, 0) - cf.Position)
		end)
		table.insert(liveStage, { Destroy = function() rise:Disconnect() end })
	end
	AudioKit.play("FairyDust", nil, 0.9, 1)

	-- Long enough to see what came out; short enough that the flash is still the
	-- answer to it rather than a footnote.
	task.wait(0.62)
	if stale() then
		return mine
	end

	----------------------------------------------------------------
	-- 5. THE FLASH  --  and the tier arriving all at once
	----------------------------------------------------------------
	vpf:Destroy()

	local flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = tier.glow
	flash.BackgroundTransparency = 0.05
	flash.BorderSizePixel = 0
	flash.ZIndex = 12
	flash.Parent = backdrop
	TweenService:Create(flash, TweenInfo.new(0.42, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	}):Play()
	Debris:AddItem(flash, 0.6)

	--[[
		THE HATCH GLOW.

		The same disc that has been building under the shell for three knocks,
		repainted into the tier's colour and taken to full -- so the light the
		player has been watching leak out of the cracks is the light the pet
		arrives in. Building a second glow here instead would have the first one
		blink out and a different one blink on, on the same frame, which reads as
		a swap rather than as something opening.

		It stays up under the pet for the rest of the reveal and breathes, which is
		the difference between a pet standing on a dark screen and a pet standing
		in its own light.
	]]
	glow:tint(tier.glow)
	-- Back to the middle of the square with it: the egg it was lighting stood on
	-- the floor, and what stands here from the next beat on is a turntable that
	-- fills the whole stage.
	glow:centre(0.5, 0.5)
	glow:set(1)
	local glowT0 = os.clock()
	local glowConn = RunService.RenderStepped:Connect(function()
		glow:set(0.82 + math.sin((os.clock() - glowT0) * 2.1) * 0.18)
	end)
	table.insert(liveStage, { Destroy = function() glowConn:Disconnect() end })

	raySpin = 26
	TweenService:Create(backdrop, TweenInfo.new(0.5), {
		-- 0.7, not 0.84. A tier colour taken almost to black is a brown screen
		-- whatever tier it was, and the whole job of this beat is that the
		-- player can name the rarity before they have read the word.
		BackgroundColor3 = PanelKit.darken(tier.color, 0.7),
	}):Play()
	tintRays(tier.glow, 0.5)

	-- Weight for the good ones. An Epic that lands on the same chime as a
	-- Common is an Epic the player has no reason to shout about.
	local big = (tier.index or 1) >= 4
	-- ONE sound here, where there used to be three. The other two have already
	-- been spent where they belong: EggShatter on the shell giving way, FairyDust
	-- under the animal climbing out of the floor. What lands on this frame is the
	-- TIER, and it is the only thing the beat is about -- three layers stacked on
	-- it would bury the one that matters.
	AudioKit.play(big and "LegendaryHit" or "Upgrade", nil, big and 1 or 0.85, big and 1 or 1.08)

	----------------------------------------------------------------
	-- 6. THE REVEAL  --  the pet, on the house turntable
	----------------------------------------------------------------
	-- PanelKit.turntable rather than a hand-rolled spin: it solves the camera
	-- distance against all eight corners of the bounding box at 24 orbit
	-- angles, so a long pet cannot clip a quarter-turn later, and it looks at
	-- the volume centroid rather than the box centre so a tall ear does not
	-- push the animal into the floor. The Index and the ATV showroom frame
	-- their models with the same call.
	local model = petModel(def)
	local turn
	if model then
		turn = PanelKit.turntable(stage, model, {
			aspect = 1,
			fov = 38,
			speed = 0.55,
			margin = 1.16,
			ambient = Color3.fromRGB(168, 162, 176),
			light = tier.glow:Lerp(Color3.fromRGB(255, 255, 255), 0.55),
			zIndex = 6,
		})
		turn.frame.AnchorPoint = Vector2.new(0.5, 0.5)
		turn.frame.Position = UDim2.fromScale(0.5, 0.5)
		turn.frame.Size = UDim2.fromScale(0.2, 0.2)
		turn:Start()
		TweenService:Create(turn.frame, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = UDim2.fromScale(1, 1),
		}):Play()
		table.insert(liveStage, turn)
		model:Destroy()
	end

	eggTitle.Text = string.upper(payload.displayName or def.DisplayName or payload.petId or "?")
	eggTitle.TextColor3 = tier.glow

	----------------------------------------------------------------
	-- 7. THE CARD
	----------------------------------------------------------------
	task.wait(0.22)
	if stale() then
		return mine
	end

	local card, body, closeFace, banner = PanelKit.card(backdrop, payload.tier or "COMMON",
		CARD_W, CARD_H, tier.color)
	card.Name = "RevealCard"
	card.AnchorPoint = Vector2.new(0.5, 1)
	card.Position = UDim2.new(0.5, 0, 1.35, 0)
	card.ZIndex = 10
	-- The card is the one thing here measured in pixels, so it is the one thing
	-- that needs the phone scale the rest gets for free from being sized in
	-- scale against the screen.
	local cardScale = Instance.new("UIScale")
	cardScale.Scale = UiFit.get()
	cardScale.Parent = card
	closeFace.Activated:Connect(finish)

	local name = PanelKit.text(body, payload.displayName or def.DisplayName or "?", 30,
		Enum.Font.LuckiestGuy, PanelKit.C.ink)
	name.Size = UDim2.new(1, 0, 0, 32)
	name.Position = UDim2.fromOffset(0, 0)
	name.TextScaled = true
	name.ZIndex = 6

	local luckLine = PanelKit.text(body, "🍀 " .. (payload.luckText or "+0%") .. " CLEANING LUCK",
		19, Enum.Font.GothamBold, PanelKit.C.woodDark)
	luckLine.Size = UDim2.new(1, 0, 0, 22)
	luckLine.Position = UDim2.fromOffset(0, 33)
	luckLine.ZIndex = 6

	-- Only offered when it did NOT auto-equip, so the button is never a no-op.
	if not payload.equipped then
		local holder, face = PanelKit.chunky(body, 176, 40, tier.color, 13)
		holder.AnchorPoint = Vector2.new(0.5, 1)
		holder.Position = UDim2.new(0.5, 0, 1, 0)
		holder.ZIndex = 7
		local capt = PanelKit.text(face, "EQUIP", 22, Enum.Font.LuckiestGuy, PanelKit.C.white)
		capt.Size = UDim2.fromScale(1, 1)
		capt.ZIndex = 9
		PanelKit.punch(capt, 3)
		face.Activated:Connect(function()
			Net.get("PetEquip"):FireServer({ petId = payload.petId, equip = true })
			capt.Text = "EQUIPPED"
			face.Active = false
			AudioKit.play("UIClick", nil, 1, 1.1)
		end)
	else
		local on = PanelKit.text(body, "EQUIPPED", 18, Enum.Font.LuckiestGuy, PanelKit.C.limeDark)
		on.AnchorPoint = Vector2.new(0.5, 1)
		on.Position = UDim2.new(0.5, 0, 1, 0)
		on.Size = UDim2.new(1, 0, 0, 24)
		on.ZIndex = 6
	end

	TweenService:Create(card, TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0.955, 0),
	}):Play()
	AudioKit.play("WoodTick", nil, 0.75, 0.8)

	----------------------------------------------------------------
	-- 8. LOOK AT IT, THEN GIVE THE WORLD BACK
	----------------------------------------------------------------
	-- Longer for the good ones. A Legendary that is gone as fast as a Common is
	-- a Legendary the player never got to look at.
	skip.Visible = true

	task.wait(2.3 + (tier.index or 1) * 0.34)
	if stale() then
		return mine
	end
	finish(mine)
	return mine
end

--------------------------------------------------------------------------
-- WIRING
--------------------------------------------------------------------------
Net.get("PetSync").OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then
		return
	end
	myPets = {
		owned = payload.owned or {},
		equipped = payload.equipped or {},
		luck = payload.luck or 1,
		maxEquipped = payload.maxEquipped or PetConfig.MaxEquipped,
	}
	refreshChip()
end)

Net.get("HatchEgg").OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" or hatching then
		return
	end
	-- The sequence yields, so it cannot run on the remote's own thread: a
	-- second hatch arriving during the wait would otherwise be dropped by the
	-- engine rather than by our own `hatching` guard.
	task.spawn(function()
		local mine
		local ok, err = pcall(function()
			mine = playHatch(payload)
		end)
		if ok then
			-- Belt and braces, and TOKENED. On a clean finish this is a no-op; on
			-- an early exit the run that superseded this one now owns the screen,
			-- and tearing it down here is exactly the bug the token exists for.
			finish(mine)
		else
			-- A throw leaves `hatching` true and the screen up with no HUD and no
			-- walk speed, which is the one failure the player cannot undo. Nothing
			-- else can have started in the meantime, so this one is unconditional.
			warn("[EggClient] hatch sequence failed:", err)
			finish()
		end
	end)
end)

-- Dying mid-sequence would otherwise leave a respawned character standing
-- behind the backdrop with its movement still pinned at zero.
player.CharacterAdded:Connect(function()
	-- The Humanoid we froze is gone, so there is nothing to hand the old speed
	-- back to and the fresh one is already at its own. Drop the record BEFORE
	-- finish() so thaw() cannot write a stale number onto the new character.
	heldSpeed, heldJump = nil, nil
	finish()
end)

refreshChip()
