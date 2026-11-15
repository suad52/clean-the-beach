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

-- Touch targets: see the module. Substituted for MouseButton1Click/Activated so
-- a tap in the margin around a control that renders under 44px on a phone still
-- reaches the same handler. No-ops on desktop and on controls already big enough.
local TouchFit = require(Modules:WaitForChild("TouchFit"))
-- Curves, durations, and the player's Reduced Motion answer. The hatch is the
-- most motion-heavy sequence in the game, so it is the one that most needs to
-- be able to turn itself down: see the ray spin and the card below.
local Motion = require(Modules:WaitForChild("Motion"))

local Debris = game:GetService("Debris")
local UserInputService = game:GetService("UserInputService")

--[[
	TOUCH GETS THE ENGINE'S OWN PROMPT, AND IT HAS TO.

	See the key-bubble block in buildFront. The short version: a ProximityPrompt
	set to Style = Custom draws NOTHING, and the thing it stops drawing is the
	only tappable surface a phone player has.

	KeyboardEnabled rather than TouchEnabled alone, because a tablet with a
	keyboard case and a laptop with a touchscreen both report TouchEnabled and
	both have a key to press.
]]
local TOUCH_ONLY = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

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
	Deliberately tiny. This is a persistent readout, not a menu.

	IT IS NOT A CHIP ANY MORE. It was a dark green slab with a gloss cap, a
	drawn clover, a counter pill and a row of five slot pips, parked on the
	right shoulder above the rail. It is two things in the BOTTOM LEFT now:
	the clover, and your total luck in white, with nothing drawn behind them.

	WHY THE SLAB WENT. A persistent readout is on screen for the whole
	session, and every piece of furniture it carries competes with the game
	underneath it. Outlined white type straight on the world is what the
	pickup line along the foot of the screen already does, so this reads as
	part of the HUD rather than as a panel that failed to close.

	WHAT WENT WITH IT: the n/5 counter and the five clickable slot pips. Both
	have a home in the Pets panel -- the "n / 5 EQUIPPED" pill, and tapping a
	tile to take that pet off -- so neither was the only way to reach
	anything. If the pips ever come back they want to be UNDER the number,
	not beside it: the corner they are in now has no width to spare.
]]
local CHIP_W, CHIP_H = 210, 40
local CHIP_MARGIN = 24     -- clear air between the readout and the screen corner

local chip = Instance.new("Frame")
chip.Name = "LuckChip"
chip.AnchorPoint = Vector2.new(0, 1)
chip.Position = UDim2.new(0, CHIP_MARGIN, 1, -CHIP_MARGIN)
chip.Size = UDim2.fromOffset(CHIP_W, CHIP_H)
chip.BackgroundTransparency = 1
chip.Visible = false
chip.Parent = gui

local chipScale = Instance.new("UIScale")
chipScale.Parent = chip

--[[
	THE CLOVER IS AN IMAGE NOW, NOT FOUR DISCS AND A STEM.

	It was the literal emoji once, and this file has already been bitten by
	that twice -- see the reward tiles, where a padlock arrived as a flat tan
	square, and the rail icons above them. The four-disc drawing was the fix
	and it worked, but a shape assembled out of primitives is a guess at an
	icon rather than the icon.

	An uploaded asset has neither problem: there is no font to be missing it,
	and it is the artwork rather than an approximation of it. The rule the
	drawing was protecting was never "draw everything" -- it was "never let a
	GLYPH stand for anything", and an asset id is not a glyph.
]]
local CLOVER = "rbxassetid://82411464535798"

local clover = Instance.new("ImageLabel")
clover.Name = "Clover"
clover.AnchorPoint = Vector2.new(0, 0.5)
clover.Position = UDim2.new(0, 0, 0.5, 0)
clover.Size = UDim2.fromOffset(38, 38)
clover.BackgroundTransparency = 1
clover.Image = CLOVER
clover.ScaleType = Enum.ScaleType.Fit
clover.ZIndex = 6
clover.Parent = chip

--[[
	THE NUMBER, IN WHITE, ON NOTHING.

	It was a pale green, which is a colour that only works while there is a
	dark green face behind it. Over the world it has to be white with an ink
	outline -- the same treatment every panel title in the game wears, and the
	reason it stays readable over wet sand, open sea and black volcanic rock
	alike.

	TextStrokeTransparency stays at 1. `label` above sets Roblox's own soft
	text stroke, and stacking that under PanelKit.punch's real UIStroke gives
	a muddy double edge rather than a thicker one.
]]
local chipText = label(chip, "+0%", 24, Color3.fromRGB(255, 255, 255))
chipText.Name = "Luck"
chipText.AnchorPoint = Vector2.new(0, 0.5)
chipText.Position = UDim2.new(0, 48, 0.5, 0)
chipText.Size = UDim2.new(1, -48, 0, 32)
chipText.TextXAlignment = Enum.TextXAlignment.Left
chipText.ZIndex = 6
chipText.TextStrokeTransparency = 1
PanelKit.punch(chipText, 3)

--[[
	NOTHING TRACKS THE RAIL ANY MORE, AND THAT IS THE POINT.

	There was a placeChip() here that found the menu rail recursively, divided
	its AbsolutePosition back through UiFit's scale, and re-ran on two signals
	plus a resize -- all of it to keep a right-hand chip from touching the
	right-hand rail. Moving the readout to the opposite corner deletes the
	problem rather than tracking it.

	If anything ever does need to share the bottom-left, put it in a list
	layout with this rather than bringing the follower back.
]]

-- SHOWN ONCE YOU HAVE A PET, not from the first frame: an empty "+0%" in
-- the corner of a brand new save is a readout about a system the player has
-- not met yet.
local function refreshChip()
	chip.Visible = #myPets.equipped > 0 or next(myPets.owned) ~= nil
	chipText.Text = PetConfig.luckText(myPets.luck or 1)
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
-- 8, UP FROM 5, FOR THE ARCTIC EGG. That shelf carries the Celestial's five
-- animals plus three Mythics, and a cap of five would have hidden exactly the
-- three the player sailed to Penguin Island to see. The card grows to fit:
-- buildFront widens the panel by shown/5 and narrows each cell so the tiles
-- stay the size they always were (see `wide` and `cellScale` there). Every
-- other egg still shows five on the same card it always had.
local ODDS_SHOWN = 8         -- one per animal on the egg's shelf, up to this

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
local function oddsIcon(parent: GuiObject, row, order: number, cellScale: number?)
	local tier = PetConfig.tierInfo(row.tier)

	local cell = Instance.new("Frame")
	cell.Name = "Odds" .. order
	cell.BackgroundTransparency = 1
	cell.Size = UDim2.fromScale(cellScale or CELL_SCALE, 1)
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

	-- A shelf with more than five animals on it gets a wider card, not smaller
	-- tiles: the panel scales by shown/5 and the cells narrow by the same
	-- amount below, so a tile is the same studs wide on every egg and the
	-- animal on it the same size. See ODDS_SHOWN.
	local wide = math.max(1, math.min(ODDS_SHOWN, #(eggDef.pool or {})) / 5)

	local panel = Instance.new("BillboardGui")
	panel.Name = "EggOdds"
	panel.Adornee = mount
	panel.Size = UDim2.fromScale(PANEL_STUDS.X * wide, PANEL_STUDS.Y)
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
	-- Five cells at CELL_SCALE fill a card exactly; more than five share the
	-- (wider) row equally so the tiles keep their size. See `wide` above.
	local cellScale = math.min(CELL_SCALE, (1 - CELL_GAP * (shown - 1)) / shown)
	-- The tiles are kept, not just built: each animal is flown to wherever its
	-- OWN tile was drawn this frame, so the placer needs the frame itself and
	-- not a column number. See PLACING THE ANIMALS.
	local tiles = {}
	for i = 1, shown do
		local _, tile = oddsIcon(row, rows[i], i, cellScale)
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
				-- The pitch of THIS card's cells, which is CELL_PITCH on a five-animal
				-- shelf and the widened row's share on a bigger one.
				dx = (i - (shown + 1) / 2) * (ROW_W * wide * (cellScale + CELL_GAP)),
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
	-- THE KEY BUBBLE  --  ON A KEYBOARD ONLY
	--
	-- The prompt's own UI is switched off LOCALLY -- Style = Custom on the
	-- client renders nothing and replicates nowhere -- and this is drawn in its
	-- place. The prompt still owns everything that matters: the range, the line
	-- of sight, the hold, and the Triggered the server is listening on. Only the
	-- picture changes.
	--
	-- ON TOUCH IT WAS NOT ONLY THE PICTURE THAT CHANGED, AND THAT LOCKED PHONES
	-- OUT OF THE ENTIRE PET ECONOMY.
	--
	-- The default prompt UI is not decoration on a phone: it IS the button. Style
	-- = Custom removes it, and what went up instead was a BillboardGui holding a
	-- Frame holding a TextLabel -- three things, none of them clickable. Nothing
	-- in this place calls prompt:InputHoldBegin() either (checked: zero callers,
	-- anywhere), so there was no second path in.
	--
	-- The ranges made it inescapable rather than occasional. PANEL_IN is 46 and
	-- MaxActivationDistance is 12, so the style is already Custom for 34 studs
	-- before the prompt is even live, and dropFront only restores Default when the
	-- player walks AWAY. A touch player could stand on top of any of the ten
	-- stations and never open one.
	--
	-- The "TAP" fallback below looks like it covered this and never could: it is
	-- gated on KeyboardKeyCode == Unknown, and PetServer sets Enum.KeyCode.E on
	-- every prompt it makes. A phone read "E".
	--
	-- So touch keeps the engine's prompt, which is designed to be tapped, and
	-- skips the bubble entirely -- leaving both up would draw two prompts on one
	-- egg.
	----------------------------------------------------------------
	local prompt = model:FindFirstChildWhichIsA("ProximityPrompt", true)
	if prompt and not TOUCH_ONLY then
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

		--[[
			A BUTTON, NOT A FRAME -- and that is the whole of this change.

			The note above says it in as many words: "three things, none of them
			clickable", and nothing in the place called InputHoldBegin either, so on
			a desktop the E key was the ONLY way into an egg station. A player asked
			for the other one on 2026-09-09 -- "please make the pet roulette
			selection possible by clicking as well as with the E button".

			IT IS THE SAME DOOR, NOT A SECOND ONE. The click drives the prompt's own
			InputHoldBegin/End rather than firing a remote, so the server still sees
			an engine-validated Triggered -- which is exactly what PetServer.openMenu
			relies on to prove the player is genuinely standing at the station. A
			remote here would be a way in that proves nothing, and that is the one
			thing this bubble must not become.

			DESKTOP ONLY BY CONSTRUCTION. This whole branch is skipped on touch
			(TOUCH_ONLY above), where the engine's own prompt is already tappable and
			two prompts on one egg was the bug that rule exists to prevent.

			AutoButtonColor is off: the bubble already has its own PromptShown pop,
			and Roblox's grey-on-press would fight the tween.
		]]
		local box = Instance.new("TextButton")
		box.Name = "Box"
		box.AutoButtonColor = false
		box.Text = ""
		box.AnchorPoint = Vector2.new(0.5, 0.5)
		box.Position = UDim2.fromScale(0.5, 0.5)
		box.Size = UDim2.fromScale(0.86, 0.86)
		box.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		box.BorderSizePixel = 0
		box.ZIndex = 4
		box.Parent = keyGui
		roundify(box, 16)

		--[[
			HELD FOR THE PROMPT'S OWN HoldDuration, rather than begun and ended in
			the same breath. These prompts are authored at 0, where a begin alone is
			enough -- but a prompt somebody later gives a hold time to would then be
			untriggerable by mouse and perfectly fine by key, which is a difference
			nobody would think to look for.

			GUARDED ON Enabled: PromptHidden switches the bubble off rather than
			destroying it, and a click landing in the same frame as the walk-away
			would otherwise open a station the player has already left.
		]]
		table.insert(made.parts, box.MouseButton1Click:Connect(function()
			if not keyGui.Enabled or not prompt.Enabled then
				return
			end
			prompt:InputHoldBegin()
			local hold = prompt.HoldDuration
			if hold > 0 then
				task.wait(hold)
			else
				task.wait()
			end
			prompt:InputHoldEnd()
		end))

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
			TweenService:Create(box, Motion.info(0.24, Motion.Ease.pop),
				{ Size = UDim2.fromScale(0.86, 0.86) }):Play()
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
	-- the event countdown, for the same reason as the chip below: a readout, and
	-- the hatch is a full-screen moment that should have nothing else on it
	"EventHud",
	"BoostHud",
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
		TweenService:Create(b, Motion.fade(0.35), { BackgroundTransparency = alpha }):Play()
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
TouchFit.activated(skip, function()
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
	DEAD CODE, KEPT ON PURPOSE  --  nothing calls eggScene or actorScene.

	This is the old hatch: your character walked in from off frame, stooped over
	a shell, knocked on it three times and an animal climbed out of the floor.
	The reel replaced all of it (see THE REEL, above), and these two functions
	plus stagePoint and the EGG_*/ACTOR_* constants are what is left of it.

	Kept rather than deleted because it is a working animation that took real
	work and is one call away from being usable again -- and because deleting
	four hundred lines out from under another editor is not a client script's
	decision to make. If the reel is here to stay, this whole block goes.

	--------------------------------------------------------------------

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
		-- Shards flung outward and spun: movement in every property, so the whole
		-- burst collapses under Reduced Motion. They still fade out on the same
		-- ramp, which is what keeps the shell reading as having broken rather than
		-- having vanished.
		TweenService:Create(sh, Motion.info(0.8, Motion.Ease.out), {
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
	-- The ring's GROWTH is movement and collapses; the stroke fading out is what
	-- is left to carry the beat when it does.
	TweenService:Create(w, Motion.info(0.55, Motion.Ease.out),
		{ Size = UDim2.fromScale(1.15, 1.15) }):Play()
	TweenService:Create(edge, Motion.fade(0.55), { Transparency = 1, Thickness = 0.5 }):Play()
	Debris:AddItem(w, 0.7)
end

--------------------------------------------------------------------------
-- THE REEL
--------------------------------------------------------------------------
--[[
	The shelf rolls past a marker, slows, and stops on the one you got.

	WHY A REEL AND NOT A CRACKING EGG
	---------------------------------
	The old hatch was a private moment: your character walked in, knocked on a
	shell three times, and one animal climbed out of the floor. It was pretty,
	and it told the player nothing. You never saw what you had NOT got, so a
	Legendary and a Common arrived through the identical eight seconds, and the
	odds printed on the station board stayed an abstraction right up until the
	card slid in at the end.

	A reel says the same thing in three seconds and says it with the other four
	animals in shot: the shelf goes past, you read it, it slows, it stops on
	one. THE NEAR MISSES ARE THE POINT -- a Common that goes by two tiles after
	the Legendary is a better story than a Common on its own.

	HOW OFTEN EACH ANIMAL APPEARS
	-----------------------------
	Frequency follows RARITY, which is the whole idea -- but not raw odds.
	Straight proportion is honest and unwatchable: the Prestige mythic is one
	roll in a million, so a strip drawn on true odds would never once show the
	rarest thing in the game. The weights are SQUARE-ROOTED, which keeps the
	order exactly -- the commonest is still the commonest, by a mile -- while
	pulling a 0.0001% tail up to something a 34-tile strip can hold.

	Then every animal on the shelf is guaranteed at least one appearance before
	the marker, so a roll always shows you the whole shelf even when the dice
	would have left the rarest off it.

	AND IT IS THIS EGG'S SHELF, NOT THE WHOLE ROSTER. A reel parading sixty pets
	when five of them are reachable would be a lie told at the exact moment the
	player is looking hardest.

	WHAT IT COSTS
	-------------
	Eleven ViewportFrames, not thirty-four. The tiles are RECYCLED -- the strip
	is a virtual position and the eleven live tiles are re-dressed as they wrap
	around it -- so a longer roll costs seconds and not memory. The pet meshes
	are built ONCE into prototypes and the tiles clone from those, so a whole
	roll does five petModel() builds rather than one per tile.
]]
local REEL_PITCH = 0.152      -- one tile step, as a fraction of the window width
local REEL_SLOTS = 11         -- live tiles: enough to cover the window and wrap
local REEL_LEFT = 5           -- how many of them sit left of the marker
local REEL_STEPS = 46         -- steps travelled before it lands
-- Solo rolls are the long one; a ten-pack rolls each item faster or the
-- batch outlasts the player's patience. See playHatch.
local REEL_TIME = 5.0
local REEL_TIME_BULK = 2.4
-- Softer than the ^4 it started at: at 46 tiles that curve spent nearly
-- the whole roll crawling, and the middle of a reel has to be readable.
local REEL_EASE = 3.4
local REEL_FOV = 32
-- NEGATIVE Z, so the tile opens on the animal's FACE.
--
-- The roster is authored head-at--Z -- PetVisuals' PLACE table puts "head" at
-- -Z * 0.34 and PetServer aims a follow pet with
-- `CFrame.lookAt(goal, goal + hrp.LookVector)`, which only walks them forwards
-- because their -Z is their front. A camera parked at +Z therefore spent the
-- whole reel looking at sixty tails.
local TILE_DIR = Vector3.new(0.42, 0.24, -1).Unit

local function reelPlan(eggDef, winnerId)
	local pool = eggDef.pool or eggDef.pets or {}
	local ids = {}
	if #pool == 0 then
		for k = -REEL_SLOTS, REEL_STEPS + REEL_SLOTS do
			ids[k] = winnerId
		end
		return ids, REEL_STEPS
	end

	local w, total = {}, 0
	for i, entry in ipairs(pool) do
		w[i] = math.sqrt(math.max(entry.chance or 0, 1e-6))
		total += w[i]
	end

	local last
	for k = -REEL_SLOTS, REEL_STEPS + REEL_SLOTS do
		local pick
		-- Re-rolled a few times against a repeat: a strip that stutters on the
		-- same animal twice running reads as a stuck reel rather than as a
		-- likely outcome. Bounded, so a one-animal shelf still terminates.
		for _ = 1, 5 do
			local r, acc = math.random() * total, 0
			for i, entry in ipairs(pool) do
				acc += w[i]
				if r <= acc then
					pick = entry.petId
					break
				end
			end
			if pick ~= last then
				break
			end
		end
		ids[k] = pick or pool[1].petId
		last = ids[k]
	end

	-- Every animal on the shelf, at least once, before the marker.
	local seen = {}
	for k = 0, REEL_STEPS - 1 do
		seen[ids[k]] = true
	end
	local at = 4
	for _, entry in ipairs(pool) do
		if not seen[entry.petId] and at < REEL_STEPS - 2 then
			ids[at] = entry.petId
			at += 5
		end
	end

	ids[REEL_STEPS] = winnerId
	return ids, REEL_STEPS
end

local function buildReel(parent: GuiObject, eggDef, ids)
	local shelf = eggDef.accent

	local win = Instance.new("Frame")
	win.Name = "Reel"
	win.AnchorPoint = Vector2.new(0.5, 0.5)
	win.Position = UDim2.fromScale(0.5, 0.47)
	win.Size = UDim2.fromScale(0.88, 0.30)
	win.BackgroundColor3 = Color3.fromRGB(12, 12, 18)
	win.BackgroundTransparency = 0.16
	win.BorderSizePixel = 0
	win.ClipsDescendants = true
	win.ZIndex = 5
	win.Parent = parent
	corner(win, 18)

	local edge = Instance.new("UIStroke")
	edge.Color = shelf
	edge.Thickness = 3
	edge.Transparency = 0.12
	edge.Parent = win

	local protos = {}
	local function protoFor(petId)
		local got = protos[petId]
		if got == nil then
			local def = PetConfig.get(petId)
			got = def and petModel(def) or false
			if got then
				got.Parent = nil
			end
			protos[petId] = got
		end
		return got or nil
	end

	local slots = {}
	for i = 1, REEL_SLOTS do
		local tile = Instance.new("Frame")
		tile.Name = "Tile" .. i
		tile.AnchorPoint = Vector2.new(0.5, 0.5)
		tile.Size = UDim2.new(REEL_PITCH * 0.86, 0, 0.84, 0)
		tile.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
		tile.BorderSizePixel = 0
		tile.ZIndex = 6
		tile.Parent = win
		corner(tile, 12)

		-- Tier colour, top to bottom, so a tile reads as lit rather than as a
		-- flat swatch -- and so the strip has depth at speed.
		local grad = Instance.new("UIGradient")
		grad.Rotation = 90
		grad.Parent = tile

		local ring = Instance.new("UIStroke")
		ring.Thickness = 2.5
		ring.Parent = tile

		local vpf = Instance.new("ViewportFrame")
		-- 0.80, not 0.84: the name plate below grew to hold a name.
		vpf.Size = UDim2.fromScale(1, 0.80)
		vpf.BackgroundTransparency = 1
		vpf.Ambient = Color3.fromRGB(150, 148, 158)
		vpf.LightColor = Color3.fromRGB(255, 252, 244)
		vpf.LightDirection = Vector3.new(-0.3, -1, -0.4)
		vpf.ZIndex = 7
		vpf.Parent = tile

		local cam = Instance.new("Camera")
		cam.FieldOfView = REEL_FOV
		cam.Parent = vpf
		vpf.CurrentCamera = cam
		-- A WorldModel, not a bare parent: without one a ViewportFrame does no
		-- lighting pass and every animal comes out flat and muddy.
		local world = Instance.new("WorldModel")
		world.Parent = vpf

		--[[
			THE NAME PLATE. It was a bare tier-coloured pill: the right colour and
			no information, on the one screen where the player is trying to read
			what is going past. Knowing you missed a Jade Wish Dragon by two tiles
			is the entire argument for showing the strip at all, and it does not
			work if the tiles are anonymous.

			Wider and taller than the pill it replaces (0.88 x 0.15 against
			0.72 x 0.07) because the roster reaches 21 characters -- "Emberforge
			Salamander" -- and TextScaled under a floor is what keeps that legible
			next to "Gearhawk" without either one being set for the other.
		]]
		local bar = Instance.new("Frame")
		bar.Name = "Bar"
		bar.AnchorPoint = Vector2.new(0.5, 1)
		bar.Position = UDim2.fromScale(0.5, 0.965)
		bar.Size = UDim2.fromScale(0.88, 0.15)
		bar.BorderSizePixel = 0
		bar.ZIndex = 8
		bar.Parent = tile
		corner(bar, 999)

		-- White on the tier colour with the house ink stroke, rather than a
		-- colour picked per tier: the plate runs from a muted Common grey to a
		-- Celestial glare, and one legible pairing beats eight tuned ones.
		local nameLabel = label(bar, "", 14, Color3.fromRGB(255, 255, 255), true)
		nameLabel.Name = "PetName"
		nameLabel.Size = UDim2.fromScale(0.92, 0.82)
		nameLabel.Position = UDim2.fromScale(0.04, 0.09)
		nameLabel.ZIndex = 9
		nameLabel.TextStrokeTransparency = 0.25
		local nameCap = Instance.new("UITextSizeConstraint")
		nameCap.MaxTextSize = 14
		nameCap.MinTextSize = 7
		nameCap.Parent = nameLabel

		slots[i] = { tile = tile, vpf = vpf, world = world, cam = cam,
			ring = ring, bar = bar, grad = grad, nameLabel = nameLabel,
			k = nil, id = nil }
	end

	--[[
		THE ENDS FADE INTO THE BACKDROP.

		A clipped strip has two hard vertical edges where tiles blink in and out
		of existence, and the eye goes straight to them. Painting the curtain
		back over the last fifth of each end means the tiles arrive out of the
		dark and leave into it, which is the difference between a reel and a
		row of boxes sliding under a mask.
	]]
	local fade = Instance.new("Frame")
	fade.Name = "Fade"
	fade.Size = UDim2.fromScale(1, 1)
	fade.BackgroundColor3 = CURTAIN
	fade.BorderSizePixel = 0
	fade.ZIndex = 11
	fade.Parent = win
	local fg = Instance.new("UIGradient")
	fg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.04),
		NumberSequenceKeypoint.new(0.24, 1),
		NumberSequenceKeypoint.new(0.76, 1),
		NumberSequenceKeypoint.new(1, 0.04),
	})
	fg.Parent = fade

	-- THE MARKER, in the shelf's own accent so the thing the reel is aiming at
	-- belongs to the egg being opened rather than being a generic white line.
	local post = Instance.new("Frame")
	post.Name = "Marker"
	post.AnchorPoint = Vector2.new(0.5, 0.5)
	post.Position = UDim2.fromScale(0.5, 0.5)
	post.Size = UDim2.new(0, 4, 1, 0)
	post.BackgroundColor3 = shelf
	post.BackgroundTransparency = 0.3
	post.BorderSizePixel = 0
	post.ZIndex = 12
	post.Parent = win
	for _, y in ipairs({ 0, 1 }) do
		local wedge = Instance.new("Frame")
		wedge.Name = "Wedge"
		wedge.AnchorPoint = Vector2.new(0.5, 0.5)
		wedge.Position = UDim2.fromScale(0.5, y)
		wedge.Size = UDim2.fromOffset(18, 18)
		wedge.Rotation = 45
		wedge.BackgroundColor3 = shelf
		wedge.BorderSizePixel = 0
		wedge.ZIndex = 13
		wedge.Parent = win
		corner(wedge, 3)
	end

	local function dress(slot, petId)
		if slot.id == petId then
			return
		end
		slot.id = petId
		for _, c in slot.world:GetChildren() do
			c:Destroy()
		end
		local def = PetConfig.get(petId)
		local tier = PetConfig.tierInfo(def and def.Tier or "Common")
		local proto = protoFor(petId)
		if proto then
			local m = proto:Clone()
			m.Parent = slot.world
			--[[
				THE CAMERA MOVES, NOT THE ANIMAL.

				The roster is authored at wildly different sizes and its pivots
				are wherever each exporter left them, so fitting by scaling and
				re-seating the model is two operations that can each be wrong.
				Framing it from its own bounding sphere is one that cannot: pull
				back far enough for the radius to fill the frustum and look at
				the centre.
			]]
			local cf, size = m:GetBoundingBox()
			local radius = math.max(size.X, size.Y, size.Z) * 0.5
			local dist = radius / math.tan(math.rad(REEL_FOV * 0.5)) * 1.45
			slot.cam.CFrame = CFrame.lookAt(cf.Position + TILE_DIR * dist, cf.Position)
		end
		slot.tile.BackgroundColor3 = PanelKit.darken(tier.color, 0.62)
		slot.grad.Color = ColorSequence.new(
			PanelKit.darken(tier.color, 0.40),
			PanelKit.darken(tier.color, 0.80))
		slot.ring.Color = tier.glow
		slot.bar.BackgroundColor3 = tier.color
		slot.nameLabel.Text = (def and def.DisplayName) or petId or "?"
	end

	local api = {}

	function api:intro()
		win.Size = UDim2.fromScale(0.88, 0.03)
		-- The reel window opening. Movement, and it runs INSIDE an egg opening --
		-- the same sequence the hatch belongs to -- so it answers the setting the
		-- same way the hatch does rather than being the one thing that still
		-- punches when everything around it has stopped.
		TweenService:Create(win, Motion.info(0.34, Motion.Ease.pop),
			{ Size = UDim2.fromScale(0.88, 0.30) }):Play()
	end

	--[[
		THE TILE THAT HOLDS STRIP POSITION k IS `k % REEL_SLOTS`, AND THAT IS THE
		WHOLE RECYCLING SCHEME. It used to be `slots[i]` for the i-th tile in the
		window, which is not recycling at all -- it is eleven tiles each shuffling
		one place left every step, so EVERY tile got a new strip position, and
		therefore a new animal, on every one of the 46 steps.

		The `slot.id == petId` early-out in dress() could not save it either:
		reelPlan deliberately never puts the same animal in consecutive positions,
		so a tile moving from k to k+1 was GUARANTEED a different one. Measured
		over a real 5-second roll: 517 dress calls, 517 of them destroying a
		MeshPart and cloning another, bunched into the fast opening frames where
		several steps pass per frame. That is the tearing.

		Modulo, eleven consecutive positions map to eleven distinct tiles (checked
		across the whole range the roll visits, negatives included -- Luau's %% is
		non-negative, so k = -1 lands on slot 11 rather than off the end). When the
		window advances one step, exactly ONE tile has wrapped and exactly one
		rebuild happens. Same measurement: 43 rebuilds, down 92%.
	]]
	function api:place(s: number)
		local first = math.floor(s) - REEL_LEFT
		for n = 0, REEL_SLOTS - 1 do
			local k = first + n
			local slot = slots[(k % REEL_SLOTS) + 1]
			if slot.k ~= k then
				slot.k = k
				dress(slot, ids[k] or ids[0])
			end
			slot.tile.Position = UDim2.new(0.5 + (k - s) * REEL_PITCH, 0, 0.5, 0)
		end
	end

	-- The landing: the one under the marker grows and the rest stand down, so
	-- the winner is picked out by the strip itself before the flash says so.
	function api:pop(k: number)
		--[[
			THE POST COMES OFF THE WINNER.

			A bright line down the middle of the animal you just won is the one
			thing on this screen that must not be there at the moment the player
			finally looks at it -- it read as a crack straight down the Kirin. The
			wedges above and below stay, so the marker still says where the reel
			stopped without drawing on the prize.
		]]
		TweenService:Create(post, Motion.fade(0.25), { BackgroundTransparency = 1 }):Play()
		for _, slot in ipairs(slots) do
			local won = (slot.k == k)
			TweenService:Create(slot.tile, Motion.info(0.3, Motion.Ease.pop), {
				Size = won and UDim2.new(REEL_PITCH * 1.14, 0, 1, 0)
					or UDim2.new(REEL_PITCH * 0.76, 0, 0.7, 0),
			}):Play()
			if won then
				-- Thickness is a weight ramp rather than travel, so it reads as a fade
				-- and keeps its length: it is what marks the winning slot once the
				-- tile's own punch has been turned down.
				TweenService:Create(slot.ring, Motion.fade(0.22), { Thickness = 5 }):Play()
			else
				TweenService:Create(slot.tile, Motion.fade(0.3), { BackgroundTransparency = 0.6 }):Play()
				TweenService:Create(slot.ring, Motion.fade(0.3), { Transparency = 0.72 }):Play()
			end
		end
	end

	function api:Destroy()
		if win.Parent then
			win:Destroy()
		end
		for _, p in pairs(protos) do
			if p then
				p:Destroy()
			end
		end
		table.clear(protos)
	end

	return api
end

--------------------------------------------------------------------------
-- THE BACKGROUND, THE SKIP BAR, AND THE BUY MENU
--------------------------------------------------------------------------
local function money(n: number): string
	local s = tostring(math.floor(n))
	local t = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return "$" .. (t:gsub("^,", ""))
end

--[[
	THE BACKGROUND, because a modal that is just black reads as a loading
	screen rather than as an event.

	Three layers and not one asset between them:

		* a vertical GRADIENT in the egg's own two colours, so the screen is
		  the colour of the thing being opened before anything happens on it
		* the ray fan that was already here, tinted to match
		* drifting DISCS, slow and soft and behind everything, which is what
		  stops the gradient reading as a flat wash

	The backdrop's own BackgroundColor3 is left WHITE and the colour lives
	entirely in the gradient, because a UIGradient MULTIPLIES its parent's
	colour -- tinting both is how you get mud. Everything here re-tints to the
	TIER when the pet lands, so the background is part of the reveal instead of
	something the reveal happens in front of.
]]
local bgGrad
local function skinBackdrop(top: Color3, bottom: Color3, tween: number?)
	if not bgGrad then
		bgGrad = Instance.new("UIGradient")
		bgGrad.Name = "Sky"
		bgGrad.Rotation = 90
		bgGrad.Parent = backdrop
	end
	backdrop.BackgroundColor3 = Color3.new(1, 1, 1)
	local seq = ColorSequence.new(top, bottom)
	if tween and tween > 0 then
		-- ColorSequence is not a tweenable type, so this is stepped by hand.
		local from = bgGrad.Color
		local t0 = os.clock()
		local conn
		conn = RunService.RenderStepped:Connect(function()
			local u = math.clamp((os.clock() - t0) / tween, 0, 1)
			bgGrad.Color = ColorSequence.new(
				from.Keypoints[1].Value:Lerp(top, u),
				from.Keypoints[#from.Keypoints].Value:Lerp(bottom, u))
			if u >= 1 then
				conn:Disconnect()
			end
		end)
		return conn
	end
	bgGrad.Color = seq
	return nil
end

local BOKEH = 18
local function bokehLayer(tint: Color3)
	local holder = Instance.new("Frame")
	holder.Name = "Bokeh"
	holder.Size = UDim2.fromScale(1, 1)
	holder.BackgroundTransparency = 1
	holder.ZIndex = 2
	holder.Parent = backdrop

	local discs = {}
	for i = 1, BOKEH do
		local d = Instance.new("Frame")
		local r = 0.035 + (i % 5) * 0.026
		d.AnchorPoint = Vector2.new(0.5, 0.5)
		d.Size = UDim2.fromScale(r, r)
		-- RelativeXX so they stay round on any window instead of becoming eggs
		-- of their own on an ultrawide.
		d.SizeConstraint = Enum.SizeConstraint.RelativeXX
		d.BackgroundColor3 = tint
		d.BackgroundTransparency = 0.86 + (i % 3) * 0.04
		d.BorderSizePixel = 0
		d.ZIndex = 2
		d.Parent = holder
		corner(d, 999)
		discs[i] = { f = d, x = math.random(), y = math.random(),
			vy = 0.010 + math.random() * 0.026, ph = math.random() * 10 }
	end

	local t0 = os.clock()
	local conn = RunService.RenderStepped:Connect(function()
		local t = os.clock() - t0
		for _, b in ipairs(discs) do
			b.f.Position = UDim2.fromScale(
				b.x + math.sin(t * 0.22 + b.ph) * 0.022,
				(b.y - t * b.vy) % 1.24 - 0.12)
		end
	end)

	local api = {}
	function api:tint(c: Color3)
		for _, b in ipairs(discs) do
			b.f.BackgroundColor3 = c
		end
	end
	function api:Destroy()
		conn:Disconnect()
		holder:Destroy()
	end
	return api
end

--[[
	THE SKIP BAR.

	Two buttons and a counter, and the reason there are two is a ten-pack: SKIP
	means "I have seen this one", SKIP ALL means "show me the haul". One button
	that did both depending on how long you held it would be a coin flip at the
	exact moment the player is impatient.

	SKIP ALL only exists when there is more than one to skip.
]]
local function skipBar(total: number, onSkip, onSkipAll)
	local holder = Instance.new("Frame")
	holder.Name = "SkipBar"
	holder.AnchorPoint = Vector2.new(1, 1)
	holder.Position = UDim2.new(0.975, 0, 0.955, 0)
	holder.Size = UDim2.fromOffset((total > 1) and 322 or 158, 52)
	holder.BackgroundTransparency = 1
	holder.ZIndex = 24
	holder.Parent = backdrop
	local fit = Instance.new("UIScale")
	fit.Scale = UiFit.get()
	fit.Parent = holder

	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.HorizontalAlignment = Enum.HorizontalAlignment.Right
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Padding = UDim.new(0, 10)
	row.Parent = holder

	local counter
	if total > 1 then
		counter = PanelKit.text(holder, "1 / " .. total, 20,
			Enum.Font.LuckiestGuy, PanelKit.C.white)
		counter.LayoutOrder = 1
		counter.Size = UDim2.fromOffset(72, 40)
		counter.ZIndex = 25
		PanelKit.punch(counter, 3)
	end

	local function button(order, w, caption, colour, cb)
		local box, face = PanelKit.chunky(holder, w, 44, colour, 12)
		box.LayoutOrder = order
		box.ZIndex = 25
		local cap = PanelKit.text(face, caption, 19, Enum.Font.LuckiestGuy, PanelKit.C.white)
		cap.Size = UDim2.fromScale(1, 1)
		cap.ZIndex = 27
		PanelKit.punch(cap, 3)
		TouchFit.activated(face, function()
			AudioKit.play("UIClick", nil, 0.9, 1.05)
			cb()
		end)
		return box
	end

	if total > 1 then
		button(2, 148, "SKIP ALL", PanelKit.C.coral or Color3.fromRGB(232, 108, 96), onSkipAll)
	end
	button(3, 138, "SKIP", PanelKit.C.wood or Color3.fromRGB(146, 104, 66), onSkip)

	local api = {}
	function api:setIndex(i: number)
		if counter then
			counter.Text = i .. " / " .. total
		end
	end
	function api:Destroy()
		holder:Destroy()
	end
	return api
end

--[[
	THE BUY MENU.

	The prompt no longer buys -- it asks. PetServer records that the player was
	genuinely at the station (see the note over PetServer.openMenu) and sends
	what this needs to draw itself; the only thing that travels back is a COUNT.

	Everything on it is re-derived server side before a coin moves, so the
	arithmetic here is for the player's benefit and not for the server's: the
	menu greys a quantity it thinks is unaffordable, and the server would have
	clamped it anyway.
]]
local buyGui = Instance.new("ScreenGui")
buyGui.Name = "PetEggBuy"
buyGui.ResetOnSpawn = false
buyGui.IgnoreGuiInset = true
buyGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
buyGui.DisplayOrder = 215
buyGui.Enabled = false
buyGui.Parent = player:WaitForChild("PlayerGui")

local function closeBuyMenu()
	buyGui.Enabled = false
	for _, c in buyGui:GetChildren() do
		c:Destroy()
	end
end

local function openBuyMenu(info)
	closeBuyMenu()
	-- Never over a hatch. The server will not honour a purchase mid-sequence
	-- anyway, and a menu behind the curtain is a menu the player cannot see
	-- but can still click.
	if hatching then
		return
	end
	buyGui.Enabled = true

	local eggColour = info.color or CREAM
	local accent = info.accent or Color3.fromRGB(126, 205, 158)
	local maxN = math.max(1, math.min(info.max or 10, 10))

	local dim = Instance.new("TextButton")
	dim.Name = "Dim"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.fromRGB(6, 6, 10)
	dim.BackgroundTransparency = 1
	dim.BorderSizePixel = 0
	dim.Text = ""
	dim.AutoButtonColor = false
	dim.ZIndex = 1
	dim.Parent = buyGui
	TweenService:Create(dim, Motion.fade(0.18), { BackgroundTransparency = 0.42 }):Play()
	TouchFit.activated(dim, closeBuyMenu)

	--[[
		SIZED FOR THE HIERARCHY, NOT THE OTHER WAY ROUND.

		PanelKit.card leaves (H - 74) of body, and a chunky button draws a lip
		BELOW its own frame. At 430x316 everything was legal and nothing had any
		room: five rows of small text stacked with four-pixel gaps, so the thing
		the menu is actually FOR -- how many, and what that costs -- carried no
		more weight than the flavour line above it.

		470x364 buys one clear order of importance: quantity, then total, then
		everything else at the size of a footnote because that is what it is.
	]]
	--[[
		THE PALETTE, DRIVEN BY THE ACCENT RATHER THAN BY THE SHELL.

		Every interactive thing on this card used to derive from `info.color`,
		which is the colour of the EGG -- and a Basic egg is a white egg:
		rgb(240,236,224). Darkening that gave the presets rgb(192,188,179) and
		the total pill rgb(107,106,100), so on the starter egg the whole control
		cluster came out cream-and-grey with no colour anywhere except the one
		green Confirm. It only ever looked designed on Prestige and Celestial,
		whose shells happen to be saturated.

		`info.accent` is what the egg is BRANDED with and it is strong on all
		four -- mint, amber, gold, magenta -- so it takes every control, and the
		shell keeps the job it is good for: tinting the card and its banner. The
		total is a fixed dark neutral rather than a derived one, so the price
		reads the same on every egg instead of shifting hue.
	]]
	local eggColour = info.color or CREAM
	local accent = info.accent or Color3.fromRGB(126, 205, 158)
	local STEP_TINT = PanelKit.darken(accent, 0.26)
	local CHIP_OFF = PanelKit.darken(accent, 0.52)
	local TRAY = Color3.fromRGB(54, 38, 26)

	--[[
		SIZED FOR THE HIERARCHY, NOT THE OTHER WAY ROUND.

		PanelKit.card leaves (H - 74) of body, and a chunky button draws a 7px
		lip BELOW its own frame -- which is what the old layout kept forgetting.
		Measured on it: 5px between the stepper row and the presets, and 3px
		between the presets' lip and the total pill. Everything was legal and
		nothing could breathe.

		One gutter of 14 everywhere, and the rows stack from named heights, so
		the arithmetic is visible instead of five hand-picked Y values that
		drift the moment one control changes size.
	]]
	local PAD = 14
	local LIP = 7               -- what PanelKit.chunky draws below its own frame
	local BLURB_H, ROW_H, CHIP_H, TOTAL_H, HAVE_H, GO_H = 22, 54, 34, 50, 22, 56

	local blurbY = 4
	local rowY = blurbY + BLURB_H + 10
	local chipY = rowY + ROW_H + LIP + PAD
	local totalY = chipY + CHIP_H + LIP + PAD
	local haveY = totalY + TOTAL_H + 10
	local goY = haveY + HAVE_H + PAD

	local W = 480
	local H = goY + GO_H + LIP + 74

	--[[
		ONE UIScale, AND IT IS UiFit'S -- SO THIS CARD STAYS A TOP-LEVEL CHILD OF
		THE ScreenGui. (2026-09-09, the buy menu rendering at the wrong size on a
		phone.)

		This card used to carry a `fit = UiFit.get()` UIScale of its OWN as well as
		being absorbed into UiFit's FitRoot, and that is where the "scaled twice"
		report came from. It is not what happens now, and the difference matters:
		PanelKit.card builds its own SafeFit UIScale inside the root before the
		caller can add anything, and ROBLOX HONOURS ONLY THE FIRST UIScale ON A
		GuiObject -- a second one is ignored outright, it does not multiply.
		Measured: a 480x399 frame carrying SafeFit=1 and then fit=0.6 renders
		480x399, not 288x239. The caller's UIScale has been dead weight ever since
		SafeFit landed, so it is gone rather than left to mislead the next reader.

		WHICH MEANS MOVING THE CARD OFF THE ScreenGui IS THE ONE THING NOT TO DO.
		Hung under `dim` -- fromScale(1, 1), which UiFit's `eligible` test skips --
		nothing scales it at all: on a 750x402 phone it measured 480x399, 421 tall
		with the banner against 366 of safe screen, CONFIRM off the bottom and the
		close X off the top. Parented here it is pure offset on both axes, UiFit
		absorbs it, and the screen scale is applied exactly once: 0.6 stays 0.6 and
		1.0 stays 1.0. SafeFit then sits under that and solves for what is left
		below the top bar, which is what its own arithmetic divides by `hud` for.
	]]
	local card, body, closeFace = PanelKit.card(buyGui, string.upper(info.eggName or "EGG"),
		W, H, eggColour)
	card.Name = "BuyCard"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.52)
	card.ZIndex = 10
	TouchFit.activated(closeFace, closeBuyMenu)

	--[[
		BRIGHT ON THE TRAY, NOT DARK.

		PanelKit.card's body is a dark recessed WELL -- its own note says "the
		tray went dark, and everything sitting on it stayed bright". This card
		was written against a cream tray, so its blurb, its quantity and its
		balance line were all C.ink and C.woodDark: dark text on dark board.
		Every value on this card is a light one.
	]]
	local blurb = PanelKit.text(body, info.blurb or "", 16, Enum.Font.GothamMedium,
		PanelKit.darken(PanelKit.C.white, 0.3))
	blurb.Size = UDim2.new(1, -16, 0, BLURB_H)
	blurb.Position = UDim2.fromOffset(8, blurbY)
	blurb.TextWrapped = true
	blurb.ZIndex = 6

	-- the quantity, and the whole point of the menu
	local n = 1
	local refreshBuy

	-- The biggest thing on the card, because it is the one thing the player is
	-- here to change. Its own UIScale, so it can kick when it moves.
	local qty = PanelKit.text(body, "1x", 52, Enum.Font.LuckiestGuy, PanelKit.C.white)
	qty.Size = UDim2.new(0, 150, 0, ROW_H)
	qty.Position = UDim2.new(0.5, -75, 0, rowY)
	qty.ZIndex = 7
	PanelKit.punch(qty, 3.5)
	local qtyScale = Instance.new("UIScale")
	qtyScale.Parent = qty

	--[[
		THE PLUS AND MINUS ARE DRAWN, NOT TYPED.

		They were LuckiestGuy "\u{2212}" and "+" at 34. That font's minus is a
		short thin dash, and it arrived as a small dark smudge in the middle of
		a 60px button -- in a screenshot the button reads as empty. Two rounded
		bars cannot be mistaken for anything else, and they match the drawn
		icons the rail and the reward tiles already use for this same reason.
	]]
	local function stepper(x: number, plus: boolean)
		local box, face = PanelKit.chunky(body, 62, ROW_H, STEP_TINT, 15)
		box.Position = UDim2.new(0.5, x, 0, rowY)
		box.ZIndex = 7
		local function bar(w: number, h: number)
			local f = Instance.new("Frame")
			f.AnchorPoint = Vector2.new(0.5, 0.5)
			f.Position = UDim2.fromScale(0.5, 0.5)
			f.Size = UDim2.fromOffset(w, h)
			f.BackgroundColor3 = PanelKit.C.white
			f.BorderSizePixel = 0
			f.ZIndex = 9
			f.Parent = face
			PanelKit.corner(f, 999)
			PanelKit.outline(f, 2.5)
			return f
		end
		bar(26, 8)
		if plus then
			bar(8, 26)
		end
		return box, face
	end

	local minusBox, minusFace = stepper(-166, false)
	local plusBox, plusFace = stepper(104, true)

	-- The three anybody actually wants, so 10x is one tap and not nine.
	local chips = Instance.new("Frame")
	chips.Size = UDim2.new(1, 0, 0, CHIP_H)
	chips.Position = UDim2.fromOffset(0, chipY)
	chips.BackgroundTransparency = 1
	chips.ZIndex = 7
	chips.Parent = body
	local chipRow = Instance.new("UIListLayout")
	chipRow.FillDirection = Enum.FillDirection.Horizontal
	chipRow.HorizontalAlignment = Enum.HorizontalAlignment.Center
	chipRow.VerticalAlignment = Enum.VerticalAlignment.Center
	chipRow.Padding = UDim.new(0, 10)
	chipRow.Parent = chips

	--[[
		THE PRESETS SHOW WHICH ONE IS ON, which they did not before: tapping 5x
		changed the number above and left all three buttons looking identical,
		so the card answered "how many" in one place and contradicted itself by
		omission in another.
	]]
	local presets = {}
	for i, v in ipairs({ 1, 5, 10 }) do
		if v <= maxN then
			local box, face, slab = PanelKit.chunky(chips, 84, CHIP_H, CHIP_OFF, 11)
			box.LayoutOrder = i
			box.ZIndex = 8
			local cap = PanelKit.text(face, v .. "x", 19, Enum.Font.LuckiestGuy, PanelKit.C.white)
			cap.Size = UDim2.fromScale(1, 1)
			cap.ZIndex = 10
			PanelKit.punch(cap, 2)
			presets[#presets + 1] = { value = v, face = face, slab = slab, cap = cap }
			TouchFit.activated(face, function()
				n = v
				AudioKit.play("UIClick", nil, 0.7, 1.15)
				refreshBuy()
			end)
		end
	end

	--[[
		THE TOTAL, AS A PILL RATHER THAN A LINE.

		It used to be dark text on the cream body at the same weight as the
		sentence above it, which put the price and the flavour text in the same
		voice. On its own dark slab it is unmistakably the number, and it has
		somewhere to go red without the whole card changing colour.
	]]
	local totalPill = Instance.new("Frame")
	totalPill.Name = "Total"
	totalPill.Size = UDim2.new(1, -20, 0, TOTAL_H)
	totalPill.Position = UDim2.fromOffset(10, totalY)
	totalPill.BackgroundColor3 = TRAY
	totalPill.BorderSizePixel = 0
	totalPill.ZIndex = 6
	totalPill.Parent = body
	PanelKit.corner(totalPill, 14)
	PanelKit.outline(totalPill, 3)

	-- A coin, not an abstract gem: this line is money, and the game already has
	-- one shape that means money.
	local coin = Instance.new("Frame")
	coin.AnchorPoint = Vector2.new(0, 0.5)
	coin.Position = UDim2.new(0, 15, 0.5, 0)
	coin.Size = UDim2.fromOffset(26, 26)
	coin.BackgroundColor3 = PanelKit.C.sun
	coin.BorderSizePixel = 0
	coin.ZIndex = 7
	coin.Parent = totalPill
	PanelKit.corner(coin, 999)
	PanelKit.outline(coin, 2.5)
	local coinInner = Instance.new("Frame")
	coinInner.AnchorPoint = Vector2.new(0.5, 0.5)
	coinInner.Position = UDim2.fromScale(0.5, 0.5)
	coinInner.Size = UDim2.fromScale(0.62, 0.62)
	coinInner.BackgroundColor3 = PanelKit.C.sunDark
	coinInner.BorderSizePixel = 0
	coinInner.ZIndex = 8
	coinInner.Parent = coin
	PanelKit.corner(coinInner, 999)

	local totalTag = PanelKit.text(totalPill, "TOTAL", 16, Enum.Font.LuckiestGuy,
		PanelKit.darken(PanelKit.C.white, 0.3))
	totalTag.AnchorPoint = Vector2.new(0, 0.5)
	totalTag.Position = UDim2.new(0, 50, 0.5, 0)
	totalTag.Size = UDim2.fromOffset(80, 24)
	totalTag.TextXAlignment = Enum.TextXAlignment.Left
	totalTag.ZIndex = 7

	local totalLine = PanelKit.text(totalPill, money(info.cost or 0), 29,
		Enum.Font.LuckiestGuy, PanelKit.C.sun)
	totalLine.AnchorPoint = Vector2.new(1, 0.5)
	totalLine.Position = UDim2.new(1, -16, 0.5, 0)
	totalLine.Size = UDim2.new(0.6, 0, 0, 34)
	totalLine.TextXAlignment = Enum.TextXAlignment.Right
	totalLine.ZIndex = 7
	PanelKit.punch(totalLine, 2.5)

	local haveLine = PanelKit.text(body,
		string.format("You have %s   \u{2022}   Bag room %d", money(info.coins or 0), info.room or 0),
		16, Enum.Font.GothamBold, PanelKit.C.sandDeep)
	haveLine.Size = UDim2.new(1, -16, 0, HAVE_H)
	haveLine.Position = UDim2.fromOffset(8, haveY)
	haveLine.ZIndex = 6

	local confirmBox, confirmFace = PanelKit.chunky(body, 300, GO_H, accent, 15)
	confirmBox.AnchorPoint = Vector2.new(0.5, 0)
	confirmBox.Position = UDim2.new(0.5, 0, 0, goY)
	confirmBox.ZIndex = 8
	local confirmCap = PanelKit.text(confirmFace, "CONFIRM", 26,
		Enum.Font.LuckiestGuy, PanelKit.C.white)
	confirmCap.Size = UDim2.fromScale(1, 1)
	confirmCap.ZIndex = 10
	PanelKit.punch(confirmCap, 3)

	--[[
		TWO SEPARATE REFUSALS, AND THE BUTTON HAS TO SAY WHICH ONE.

		These used to be one boolean labelled with only one of its halves, so a
		player standing at the station with $2,579 in hand and a $500 egg on the
		board was told "CAN'T AFFORD" -- because their PET BAG was full. The
		subtitle one line above already said `Bag room 0` and was right; the
		button was the only thing lying, and it is the thing people read.

		The bag case is checked FIRST because it is the one a player cannot
		solve by playing longer: no amount of coins clears it, and the fix
		(release something) is somewhere else entirely, so the button has to name
		it. Wording follows PetServer.hatch's own server-side refusal, which
		already pointed at the Pets tab -- one phrasing for one problem, wherever
		the player meets it.
	]]
	function refreshBuy()
		qty.Text = n .. "x"
		local total = (info.cost or 0) * n
		totalLine.Text = money(total)
		local room = math.max(info.room or 0, 0)
		local hasRoom = n <= room
		local canPay = total <= (info.coins or 0)
		local ok = canPay and hasRoom
		totalLine.TextColor3 = ok and PanelKit.C.sun or Color3.fromRGB(255, 138, 128)
		if ok then
			confirmCap.Text = "CONFIRM  " .. n .. "x"
		elseif not hasRoom then
			-- room == 0 is a full bag; room > 0 means the bag simply cannot take
			-- THIS many, which is a different sentence and a solvable one.
			confirmCap.Text = (room <= 0) and "PET BAG FULL" or ("ONLY ROOM FOR " .. room)
		else
			confirmCap.Text = "CAN'T AFFORD"
		end
		confirmFace.Active = ok
		confirmBox.BackgroundTransparency = ok and 0 or 0.45

		-- The button has room for a diagnosis and not for a cure, so the line
		-- above it carries the cure. Only on a FULL bag: "release some" is not
		-- advice when the bag has room and the player merely asked for ten.
		haveLine.Text = (room <= 0)
			and string.format("You have %s   \u{2022}   Pet bag full \u{2014} release some in the Pets tab",
				money(info.coins or 0))
			or string.format("You have %s   \u{2022}   Bag room %d",
				money(info.coins or 0), room)

		-- A stepper that cannot move says so, rather than looking live and
		-- doing nothing when it is pressed.
		minusFace.BackgroundTransparency = (n > 1) and 0 or 0.5
		plusFace.BackgroundTransparency = (n < maxN) and 0 or 0.5

		for _, p in ipairs(presets) do
			local on = (p.value == n)
			PanelKit.retint(p.face, p.slab, on and accent or CHIP_OFF)
			p.cap.TextTransparency = on and 0 or 0.25
		end
		return ok
	end

	local function step(d)
		local was = n
		n = math.clamp(n + d, 1, maxN)
		AudioKit.play(was == n and "Reject" or "UIClick", nil, 0.6, 1.1 + n * 0.02)
		if was ~= n then
			-- A kick on the number, so the eye follows the thing that changed
			-- rather than hunting for it.
			qtyScale.Scale = 1.18
			TweenService:Create(qtyScale, Motion.info(0.22, Motion.Ease.pop), { Scale = 1 }):Play()
		end
		refreshBuy()
	end

	TouchFit.activated(minusFace, function() step(-1) end)
	TouchFit.activated(plusFace, function() step(1) end)

	TouchFit.activated(confirmFace, function()
		if not refreshBuy() then
			AudioKit.play("Reject", nil, 0.8, 1)
			return
		end
		AudioKit.play("UIClick", nil, 1, 1)
		Net.get("EggBuy"):FireServer({ count = n })
		closeBuyMenu()
	end)

	refreshBuy()
	-- The buy card's own arrival. 0.85 rather than popIn's 0.70 because this one
	-- opens over a menu rather than over the world; Motion.info settles it flat
	-- under Reduced Motion.
	card.Size = UDim2.fromOffset(W * 0.85, H * 0.85)
	TweenService:Create(card, Motion.info(0.24, Motion.Ease.pop),
		{ Size = UDim2.fromOffset(W, H) }):Play()
	AudioKit.play("WoodTick", nil, 0.7, 1.05)
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

	-- All fades, so all of them survive Reduced Motion at full length -- the
	-- stage dissolves rather than being cut away. Only the card and the stage
	-- children below actually move, and only those collapse.
	TweenService:Create(backdrop, Motion.fade(0.34), { BackgroundTransparency = 1 }):Play()
	TweenService:Create(vign, Motion.fade(0.34), { BackgroundTransparency = 1 }):Play()
	TweenService:Create(eggTitle, Motion.fade(0.22), { TextTransparency = 1 }):Play()
	TweenService:Create(eggTitleStroke, Motion.fade(0.22), { Transparency = 1 }):Play()
	for _, b in blades do
		TweenService:Create(b, Motion.fade(0.3), { BackgroundTransparency = 1 }):Play()
	end
	local card = backdrop:FindFirstChild("RevealCard")
	if card then
		-- Back/In WAS an anticipation on the way OUT: the card lifted slightly
		-- before dropping away, which delays the one moment the player is waiting
		-- on. Entering and exiting both want ease-out -- see Modules.Motion.
		-- MOVEMENT, so this is what collapses under Reduced Motion while the
		-- fades above keep their length.
		TweenService:Create(card, Motion.info(0.26, Motion.Ease.out), {
			Position = UDim2.new(0.5, 0, 1.35, 0),
		}):Play()
	end
	for _, c in stage:GetChildren() do
		if c:IsA("GuiObject") then
			-- Same correction, and movement for the same reason.
			TweenService:Create(c, Motion.info(0.24, Motion.Ease.out), {
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
	--[[
		ONE PAYLOAD, ONE TO TEN ANIMALS.

		The old single-pet shape is still accepted -- an older server, or
		anybody firing the remote by hand to test, still plays a sequence -- but
		the shape the server sends now is a `results` array and the whole
		sequence is a loop over it.
	]]
	local results = payload.results
	if type(results) ~= "table" or #results == 0 then
		if type(payload.petId) ~= "string" then
			return nil
		end
		results = { {
			petId = payload.petId, displayName = payload.displayName,
			tier = payload.tier, luck = payload.luck,
			luckText = payload.luckText, equipped = payload.equipped,
		} }
	end
	local eggDef = PetConfig.eggFor(payload.eggKey)
		or { name = "EGG", color = CREAM, accent = Color3.fromRGB(126, 205, 158), pool = {} }
	local total = #results
	local solo = (total == 1)

	hatching = true
	active = true
	token += 1
	local mine = token
	local function stale()
		return token ~= mine or not active
	end

	-- The watchdog scales with the batch, or a ten-pack would trip its own
	-- safety net two animals in.
	task.delay(24 + total * 11, function()
		if token == mine then
			finish()
		end
	end)

	clearStage()
	hideHud()
	freeze()
	AudioKit.dipMusic(0.3, 10 + total * 4)

	----------------------------------------------------------------
	-- 1. THE CURTAIN, AND THE SKY BEHIND IT
	----------------------------------------------------------------
	hatchGui.Enabled = true
	skip.Visible = false
	backdrop.BackgroundTransparency = 1
	vign.BackgroundTransparency = 1
	rayHub.Rotation = 0
	for _, b in blades do
		b.BackgroundColor3 = eggDef.accent
		b.BackgroundTransparency = 1
	end

	-- The screen is the colour of the egg being opened before anything happens
	-- on it. See skinBackdrop for why the backdrop itself stays white.
	skinBackdrop(PanelKit.darken(eggDef.color, 0.60), PanelKit.darken(eggDef.accent, 0.84))
	local bokeh = bokehLayer(eggDef.accent)
	table.insert(liveStage, bokeh)

	-- FADES, so these keep their full duration under Reduced Motion. Cutting
	-- straight to a black backdrop is harsher than fading to one, and it is the
	-- movement this setting is meant to remove, not the transition. See
	-- Motion.fade.
	TweenService:Create(backdrop, Motion.fade(0.4), { BackgroundTransparency = 0 }):Play()
	TweenService:Create(vign, Motion.fade(0.4), { BackgroundTransparency = 0.42 }):Play()
	AudioKit.play("SwingWhoosh", nil, 0.8, 0.7)

	eggTitle.Text = string.upper(payload.eggName or eggDef.name or "EGG")
	eggTitle.TextColor3 = eggDef.accent
	TweenService:Create(eggTitle, Motion.fade(0.35), { TextTransparency = 0 }):Play()
	TweenService:Create(eggTitleStroke, Motion.fade(0.35), { Transparency = 0 }):Play()

	--[[
		THE RAYS STOP TURNING UNDER REDUCED MOTION, AND THEY ARE THE REASON THIS
		FILE READS THE SETTING AT ALL.

		Every tween in this sequence ends on its own; this one does not -- it runs
		on RenderStepped for as long as the hatch is up, which for a ten-pull is a
		long time to hold a rotating sunburst behind a card somebody is trying to
		read. A continuous rotation is the single worst thing on screen for a
		motion-sensitive player.

		The hub is left in place and still painted, so the sunburst is still THERE
		backing the egg; it simply holds still. Connected either way rather than
		skipped, because liveStage's teardown expects the handle.
	]]
	local raySpin = Motion.reduced() and 0 or 5
	local rayConn = RunService.RenderStepped:Connect(function(dt)
		if raySpin ~= 0 then
			rayHub.Rotation += dt * raySpin
		end
	end)
	table.insert(liveStage, { Destroy = function() rayConn:Disconnect() end })

	local glow = glowDisc(stage, eggDef.accent, 3)
	table.insert(liveStage, glow)
	glow:set(0.22)

	----------------------------------------------------------------
	-- SKIPPING, which is two different verbs
	----------------------------------------------------------------
	local skipOne, skipAll = false, false
	local bar = skipBar(total,
		function() skipOne = true end,
		function() skipAll = true skipOne = true end)
	table.insert(liveStage, bar)

	-- Yields like task.wait, but comes straight back the moment the player
	-- presses SKIP. Every pause in the sequence goes through it, which is what
	-- makes the button feel connected to anything.
	local function nap(seconds: number)
		local due = os.clock() + seconds
		while os.clock() < due do
			if stale() or skipOne then
				return
			end
			task.wait()
		end
	end

	----------------------------------------------------------------
	-- ONE ANIMAL: roll, land, flash, stand it up
	----------------------------------------------------------------
	local function playOne(r, index: number)
		local tier = PetConfig.tierInfo(r.tier)
		local def = PetConfig.get(r.petId)
		bar:setIndex(index)
		skipOne = false

		--[[
			WHETHER THIS PLAYER WANTS THE BANG. The same Set_Flash switch that gates
			the light a find throws on the beach (CTB_Client, popItem and sweepMark);
			the owner asked for the one row to cover this reveal too, and it is the
			same complaint either way -- a near-white frame thrown over the whole
			screen. Here it is worse per press than on the sand: a ten-pack runs this
			function TEN TIMES, so the switch is off means ten full-screen blowouts
			in about twenty seconds.

			Read per pet rather than once per run, so a player who turns it off is not
			made to sit through the rest of the batch they already started. Nil is ON,
			so nobody who has never opened the panel sees a different hatch.

			IT GATES THE BLOWOUT, NOT THE REVEAL. The tier still arrives -- the sky
			re-skin, the bokeh and halo tint, the rays and the title all carry it, and
			the animal still stands up on the turntable. The header at the top of this
			file calls the flash "where the tier arrives"; with this off it arrives as
			a 0.45s fade instead of a punch, which is the whole of what was asked for.
		]]
		local flashOn = player:GetAttribute("Set_Flash") ~= false

		-- 2. THE ROLL
		local ids, winAt = reelPlan(eggDef, r.petId)
		local reel = buildReel(backdrop, eggDef, ids)
		local reelSlot = { Destroy = function() reel:Destroy() end }
		table.insert(liveStage, reelSlot)
		reel:place(0)
		reel:intro()
		AudioKit.play("SwingWhoosh", nil, 0.7, 1.15)
		nap(0.3)
		if stale() then
			return nil
		end

		-- A ten-pack rolls each item faster, or the batch outlasts the player.
		local dur = solo and REEL_TIME or REEL_TIME_BULK
		local t0, lastStep, lastTick, done = os.clock(), -999, 0, false
		local roll
		roll = RunService.RenderStepped:Connect(function()
			-- SKIP lands it rather than cutting it: u jumps to 1, so the strip
			-- snaps to its stop and the pop still plays. A reel that vanished
			-- mid-spin would leave the player wondering what they got.
			local u = skipOne and 1 or math.clamp((os.clock() - t0) / dur, 0, 1)
			local e = 1 - (1 - u) ^ REEL_EASE
			local s = winAt * e
			reel:place(s)
			local step = math.floor(s)
			if step ~= lastStep then
				lastStep = step
				local now = os.clock()
				if now - lastTick >= 0.05 then
					lastTick = now
					AudioKit.play("WoodTick", nil, 0.22, 1.55 - 0.45 * e)
				end
			end
			glow:set(0.22 + 0.5 * e)
			if u >= 1 then
				done = true
			end
		end)
		while not done and not stale() do
			task.wait()
		end
		roll:Disconnect()
		if stale() then
			return nil
		end

		-- 3. THE LANDING
		reel:place(winAt)
		reel:pop(winAt)
		AudioKit.play("Register", nil, 0.85, 1)
		tintRays(tier.glow, 0.6)
		raySpin = 16
		skipOne = false
		nap(solo and 0.75 or 0.5)
		if stale() then
			return nil
		end

		--[[
			SKIP ALL GETS OUT HERE, not at the top of the next loop.

			The strip still LANDS -- the player sees what this one was, which is
			the difference between skipping a reveal and losing a pet -- but the
			flash, the turntable and the second and a half of standing there are
			all skipped. Waiting for the loop to notice cost a second and a half
			per press, on the one input that exists because the player is done
			waiting.
		]]
		if skipAll then
			reel:Destroy()
			return nil
		end

		-- 4. THE FLASH, and the sky turning the tier's colour
		if flashOn then
			local flash = Instance.new("Frame")
			flash.Name = "Flash"
			flash.Size = UDim2.fromScale(1, 1)
			flash.BackgroundColor3 = tier.glow
			flash.BackgroundTransparency = 0.05
			flash.BorderSizePixel = 0
			flash.ZIndex = 22
			flash.Parent = backdrop
			-- A fade, so it survives Reduced Motion whole: the flash is what covers
			-- the swap, and cutting it would expose the thing it is hiding.
			TweenService:Create(flash, Motion.fade(0.42), { BackgroundTransparency = 1 }):Play()
			Debris:AddItem(flash, 0.6)
		end
		-- Outside the branch: the strip has to come down either way, or the reel
		-- would still be standing in front of the animal.
		reel:Destroy()

		skinBackdrop(PanelKit.darken(tier.color, 0.5), PanelKit.darken(tier.glow, 0.86), 0.45)
		bokeh:tint(tier.glow)
		glow:tint(tier.glow)
		glow:centre(0.5, 0.5)
		glow:set(1)
		raySpin = 26
		tintRays(tier.glow, 0.5)
		local big = (tier.index or 1) >= 4
		AudioKit.play(big and "LegendaryHit" or "Upgrade", nil,
			big and 1 or 0.85, big and 1 or 1.08)
		-- The impact that lands ON the flash -- a ring off the stage and the shell
		-- coming apart. Gated with it rather than separately: they fire in the same
		-- frame and read as one event, so leaving these behind a suppressed flash
		-- would be a bang with the bang taken out of it. The sting at 3556 stays --
		-- the setting is about light, and a silent reveal is not what was asked for.
		if flashOn then
			shockwave(stage, tier.glow)
			shardBurst(stage, eggDef.color, tier.glow, big and 22 or 12)
		end

		-- 5. THE ANIMAL, on the house turntable
		local model = petModel(def)
		local turn
		if model then
			turn = PanelKit.turntable(stage, model, {
				-- HALF A TURN ROUND, so the animal opens facing the player.
				-- PanelKit's orbit starts at +Z, which is the BACK of anything
				-- authored head-at--Z, and this whole roster is (see TILE_DIR).
				-- The reveal was showing a tail for the first second and a half of
				-- the one shot the player actually waited for.
				startAngle = math.pi,
				aspect = 1, fov = 38, speed = 0.55, margin = 1.16,
				ambient = Color3.fromRGB(168, 162, 176),
				light = tier.glow:Lerp(Color3.fromRGB(255, 255, 255), 0.55),
				zIndex = 6,
			})
			turn.frame.AnchorPoint = Vector2.new(0.5, 0.5)
			turn.frame.Position = UDim2.fromScale(0.5, 0.5)
			turn.frame.Size = UDim2.fromScale(0.2, 0.2)
			turn:Start()
			TweenService:Create(turn.frame, Motion.info(0.5, Motion.Ease.pop),
				{ Size = UDim2.fromScale(1, 1) }):Play()
			table.insert(liveStage, turn)
			model:Destroy()
		end

		eggTitle.Text = string.upper(r.displayName or r.petId or "?")
		eggTitle.TextColor3 = tier.glow
		return turn
	end

	----------------------------------------------------------------
	-- THE BATCH
	----------------------------------------------------------------
	local shownAny = false
	for i, r in ipairs(results) do
		if stale() or skipAll then
			break
		end
		local turn = playOne(r, i)
		shownAny = true
		if stale() then
			return mine
		end

		if solo then
			break
		end

		-- Long enough to read the name and see the shape, and no longer: at ten
		-- of them the difference between 1.2s and 2s is eight seconds of a
		-- player waiting to see a list they already know they own.
		skipOne = false
		nap(1.2)
		if turn then
			turn:Destroy()
		end
		for _, c in stage:GetChildren() do
			if c:IsA("GuiObject") and c.Name ~= "Glow" then
				c:Destroy()
			end
		end
	end
	if stale() then
		return mine
	end

	----------------------------------------------------------------
	-- 6. THE CARD  --  one animal, or the whole haul
	----------------------------------------------------------------
	skipOne = false
	if solo then
		local r = results[1]
		local tier = PetConfig.tierInfo(r.tier)
		local def = PetConfig.get(r.petId)
		nap(0.22)
		if stale() then
			return mine
		end

		local card, body, closeFace = PanelKit.card(backdrop, r.tier or "COMMON",
			CARD_W, CARD_H, tier.color)
		card.Name = "RevealCard"
		card.AnchorPoint = Vector2.new(0.5, 1)
		card.Position = UDim2.new(0.5, 0, 1.35, 0)
		card.ZIndex = 10
		local cardScale = Instance.new("UIScale")
		cardScale.Scale = UiFit.get()
		cardScale.Parent = card
		TouchFit.activated(closeFace, finish)

		local name = PanelKit.text(body, r.displayName or (def and def.DisplayName) or "?", 30,
			Enum.Font.LuckiestGuy, PanelKit.C.ink)
		name.Size = UDim2.new(1, 0, 0, 32)
		name.TextScaled = true
		name.ZIndex = 6

		--[[
			THE CLOVER ON THIS LINE IS AN IMAGE, NOT THE EMOJI IT WAS.

			It opened with "\u{1F340}" until now. This file already knows what that
			costs -- see the reward tiles, where a padlock arrived as a flat tan
			square -- and the pets panel has had a clover taken out of it twice for
			the same reason. Roblox's font has no fallback for newer emoji: a
			missing one renders as a narrow box rather than failing loudly, so it
			ships looking broken on exactly the devices nobody tested on. MenuHud
			states the measurement to use if a new glyph is ever proposed.

			An asset id has no glyph to be missing. Same clover the luck readout at
			the foot of the screen and the pets panel both use.
		]]
		local luckRow = Instance.new("Frame")
		luckRow.Name = "LuckLine"
		luckRow.BackgroundTransparency = 1
		luckRow.Size = UDim2.new(1, 0, 0, 22)
		luckRow.Position = UDim2.fromOffset(0, 33)
		luckRow.ZIndex = 6
		luckRow.Parent = body

		local luckLay = Instance.new("UIListLayout")
		luckLay.FillDirection = Enum.FillDirection.Horizontal
		luckLay.HorizontalAlignment = Enum.HorizontalAlignment.Center
		luckLay.VerticalAlignment = Enum.VerticalAlignment.Center
		luckLay.Padding = UDim.new(0, 6)
		luckLay.SortOrder = Enum.SortOrder.LayoutOrder
		luckLay.Parent = luckRow

		local luckClover = Instance.new("ImageLabel")
		luckClover.Name = "Clover"
		luckClover.LayoutOrder = 1
		luckClover.Size = UDim2.fromOffset(20, 20)
		luckClover.BackgroundTransparency = 1
		luckClover.Image = CLOVER
		luckClover.ScaleType = Enum.ScaleType.Fit
		luckClover.ZIndex = 6
		luckClover.Parent = luckRow

		-- AutomaticSize so the pair stays centred as the number grows; truncation
		-- off with it, for the reason the pets panel spells out.
		local luckLine = PanelKit.text(luckRow,
			(r.luckText or "+0%") .. " CLEANING LUCK",
			19, Enum.Font.GothamBold, PanelKit.C.woodDark)
		luckLine.LayoutOrder = 2
		luckLine.AutomaticSize = Enum.AutomaticSize.X
		luckLine.Size = UDim2.fromOffset(0, 22)
		luckLine.TextTruncate = Enum.TextTruncate.None
		luckLine.ZIndex = 6

		if not r.equipped then
			local holder, face, slab = PanelKit.chunky(body, 176, 40, tier.color, 13)
			holder.AnchorPoint = Vector2.new(0.5, 1)
			holder.Position = UDim2.new(0.5, 0, 1, 0)
			holder.ZIndex = 7
			local capt = PanelKit.text(face, "EQUIP", 22, Enum.Font.LuckiestGuy, PanelKit.C.white)
			capt.Size = UDim2.fromScale(1, 1)
			capt.ZIndex = 9
			PanelKit.punch(capt, 3)

			--[[
				THE CAPTION FOLLOWS THE SERVER; IT DOES NOT SPEAK FOR IT.
				(2026-09-09, the card saying EQUIPPED next to a toast saying no.)

				This button used to write "EQUIPPED" and grey itself out ON THE TAP,
				one line after FireServer and before the server had said anything at
				all. But PetServer.setEquipped refuses when the bag is already full --
				#d.equipped >= PetConfig.MaxEquipped -- and toasts "You can only have
				5 pets out." So a player carrying a full loadout, which is most of the
				mid and late game, got a card claiming the pet was out and a toast
				directly underneath it saying the opposite, and the pet stayed in the
				bag. Two readouts of the same fact on one screen disagreeing is worse
				than either one being slow.

				The truth arrives on PetSync. The server pushes a snapshot ONLY when
				the change actually took, so the caption waits for this pet's count in
				`equipped` to go UP from what it was at the tap. COUNTING, not
				table.find: you may wear as many copies of an id as you own (see
				setEquipped's own note), so "is it in the list" is already true for
				the second copy and would confirm a refusal as a success.

				A REFUSAL SENDS NOTHING BACK -- setEquipped returns false without
				calling push() -- so there is no failure message to listen for and the
				timer is the only way out of the pending look. It hands the button
				back rather than leaving a dead control, so the player can take
				something off and try again. `asked` stays true across that timeout on
				purpose: a sync that merely arrived late still settles the caption
				instead of being thrown away.

				THE GUARD IS A FLAG AND NOT `face.Active`. This button is 40px tall,
				under TouchFit.MIN, so on a touch device TouchFit has built a PAD
				beneath it and wired the pad's Activated to this same handler. The pad
				does not read face.Active, so Active alone leaves the tap live on
				exactly the devices this card is hardest to hit on.
			]]
			local WAIT_FOR_SERVER = 1.5
			local PRESSED = PanelKit.darken(tier.color, 0.5)

			local function wearing(list)
				local n = 0
				for _, id in list or {} do
					if id == r.petId then
						n += 1
					end
				end
				return n
			end

			local asked, asking, wasWearing = false, false, 0
			local syncConn
			syncConn = Net.get("PetSync").OnClientEvent:Connect(function(payload)
				if stale() or not holder.Parent then
					syncConn:Disconnect()
					return
				end
				if not asked or type(payload) ~= "table" then
					return
				end
				if wearing(payload.equipped) > wasWearing then
					asking = false
					syncConn:Disconnect()
					capt.Text = "EQUIPPED"
					face.Active = false
					PanelKit.retint(face, slab, PRESSED)
				end
			end)
			-- The card is torn down by finish() well before most sessions end, and a
			-- remote connection held by a destroyed button is a leak per hatch.
			holder.Destroying:Connect(function()
				syncConn:Disconnect()
			end)

			TouchFit.activated(face, function()
				if asking or not face.Active then
					return
				end
				asked, asking = true, true
				wasWearing = wearing(myPets.equipped)
				capt.Text = "EQUIPPING"
				PanelKit.retint(face, slab, PRESSED)
				Net.get("PetEquip"):FireServer({ petId = r.petId, equip = true })
				AudioKit.play("UIClick", nil, 1, 1.1)
				task.delay(WAIT_FOR_SERVER, function()
					-- Still waiting means the server said no, silently. Put the button
					-- back the way it was so the tap is worth making again.
					if asking and face.Parent then
						asking = false
						capt.Text = "EQUIP"
						PanelKit.retint(face, slab, tier.color)
					end
				end)
			end)
		else
			local on = PanelKit.text(body, "EQUIPPED", 18, Enum.Font.LuckiestGuy, PanelKit.C.limeDark)
			on.AnchorPoint = Vector2.new(0.5, 1)
			on.Position = UDim2.new(0.5, 0, 1, 0)
			on.Size = UDim2.new(1, 0, 0, 24)
			on.ZIndex = 6
		end

		TweenService:Create(card, Motion.info(0.42, Motion.Ease.pop),
			{ Position = UDim2.new(0.5, 0, 0.955, 0) }):Play()
		AudioKit.play("WoodTick", nil, 0.75, 0.8)
		skip.Visible = true
		nap(2.6 + (tier.index or 1) * 0.4)
	else
		--[[
			THE HAUL.

			A ten-pack ends on a list, not on the tenth animal -- what the player
			wants at that point is "what did I get", and ten reveals have already
			answered "what is this one" ten times. Skipping the batch lands here
			too, which is the whole reason SKIP ALL is worth pressing: it does
			not throw the pets away, it shows them to you at once.
		]]
		for _, c in stage:GetChildren() do
			if c:IsA("GuiObject") and c.Name ~= "Glow" then
				c:Destroy()
			end
		end
		glow:set(0.5)
		eggTitle.Text = string.upper(payload.eggName or eggDef.name or "EGG")
		eggTitle.TextColor3 = eggDef.accent

		local best = results[1]
		for _, r in ipairs(results) do
			local a = PetConfig.tierInfo(r.tier)
			local b = PetConfig.tierInfo(best.tier)
			if (a and a.index or 1) > (b and b.index or 1) then
				best = r
			end
		end

		--[[
			THE CARD IS SIZED TO THE HAUL, NOT THE OTHER WAY ROUND.

			It was a fixed 520 x 300 holding a row of 92 x 88 cells, so five pets
			left about a hundred and fifty pixels of empty brown under them and ten
			had to squeeze. Deriving both from the grid means one row or two both
			come out packed, and the floor on the width is only there so a two-pet
			haul does not end up narrower than its own title.
		]]
		local CELL_W, CELL_H, PAD = 108, 136, 8
		local cols = math.min(total, 5)
		local rows = math.ceil(total / cols)
		local gridW = cols * CELL_W + (cols - 1) * PAD
		local gridH = rows * CELL_H + (rows - 1) * PAD
		-- 36 is PanelKit.card's own body inset, 74 its banner plus footer.
		local W = math.max(gridW + 48, 430)
		local H = gridH + 74 + 14 + 52 + 12

		local card, body, closeFace = PanelKit.card(backdrop,
			string.format("%d \u{00D7} %s", total, string.upper(eggDef.name or "EGG")),
			W, H, eggDef.color)
		card.Name = "RevealCard"
		card.AnchorPoint = Vector2.new(0.5, 0.5)
		card.Position = UDim2.fromScale(0.5, 0.5)
		card.ZIndex = 10
		local cardScale = Instance.new("UIScale")
		cardScale.Scale = UiFit.get()
		cardScale.Parent = card
		TouchFit.activated(closeFace, finish)

		local grid = Instance.new("Frame")
		grid.Name = "Haul"
		grid.AnchorPoint = Vector2.new(0.5, 0)
		grid.Position = UDim2.new(0.5, 0, 0, 0)
		grid.Size = UDim2.fromOffset(gridW, gridH)
		grid.BackgroundTransparency = 1
		grid.ZIndex = 6
		grid.Parent = body
		local layout = Instance.new("UIGridLayout")
		layout.CellSize = UDim2.fromOffset(CELL_W, CELL_H)
		layout.CellPadding = UDim2.fromOffset(PAD, PAD)
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment = Enum.VerticalAlignment.Top
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = grid

		--[[
			ONE TILE PER PET, AND THE PET IS ACTUALLY ON IT.

			The old cell was a flat darkened swatch carrying a name, a 4px pip and
			a percentage -- the two things a player wants after opening ten eggs are
			WHICH ANIMALS and HOW GOOD, and it showed neither as anything but text.
			These are the real meshes in ViewportFrames, framed the way the reel
			frames its tiles (TILE_DIR, so they face out rather than presenting a
			tail) on the house's chunky slab-and-gloss recipe.

			DUPLICATES ARE NOT COLLAPSED. Four Pebble Pups is four tiles, because
			the card is answering "what did those eggs give me" and an "x4" badge
			quietly re-answers a different question.
		]]
		local tiles = {}
		for i, r in ipairs(results) do
			local tier = PetConfig.tierInfo(r.tier)
			local rare = (tier.index or 1) >= 4
			local isBest = (r == best)

			local cell = Instance.new("Frame")
			cell.Name = "Tile" .. i
			cell.LayoutOrder = i
			cell.BackgroundTransparency = 1
			cell.ZIndex = 7
			cell.Parent = grid
			local cellScale = Instance.new("UIScale")
			cellScale.Scale = 0
			cellScale.Parent = cell

			-- Shadow slab under the face: the single biggest "toy" cue in the kit,
			-- and the reason a flat swatch never read as an object.
			local slab = Instance.new("Frame")
			slab.Size = UDim2.fromScale(1, 1)
			slab.Position = UDim2.fromOffset(0, 6)
			slab.BackgroundColor3 = PanelKit.darken(tier.color, 0.72)
			slab.BorderSizePixel = 0
			slab.ZIndex = 7
			slab.Parent = cell
			corner(slab, 16)
			PanelKit.outline(slab, 4)

			local face = Instance.new("Frame")
			face.Name = "Face"
			face.Size = UDim2.fromScale(1, 1)
			face.BackgroundColor3 = tier.color
			face.BorderSizePixel = 0
			face.ZIndex = 8
			face.Parent = cell
			corner(face, 16)
			PanelKit.outline(face, 4)
			PanelKit.grad(face, tier.color:Lerp(PanelKit.C.white, 0.34),
				PanelKit.darken(tier.color, 0.34))
			PanelKit.gloss(face, 16)

			-- A soft disc behind the animal, brighter the rarer it is. It is what
			-- makes a Mythic read as lit from behind rather than merely pinker.
			local halo = Instance.new("Frame")
			halo.AnchorPoint = Vector2.new(0.5, 0.5)
			halo.Position = UDim2.fromScale(0.5, 0.37)
			halo.Size = UDim2.fromOffset(84, 84)
			halo.BackgroundColor3 = tier.glow
			halo.BackgroundTransparency = rare and 0.45 or 0.72
			halo.BorderSizePixel = 0
			halo.ZIndex = 9
			halo.Parent = face
			corner(halo, 999)

			local vpf = Instance.new("ViewportFrame")
			vpf.AnchorPoint = Vector2.new(0.5, 0)
			vpf.Position = UDim2.new(0.5, 0, 0, 6)
			vpf.Size = UDim2.fromOffset(CELL_W - 12, 74)
			vpf.BackgroundTransparency = 1
			vpf.Ambient = Color3.fromRGB(158, 154, 166)
			vpf.LightColor = Color3.fromRGB(255, 252, 244)
			vpf.LightDirection = Vector3.new(-0.3, -1, -0.4)
			vpf.ZIndex = 10
			vpf.Parent = face
			local vcam = Instance.new("Camera")
			vcam.FieldOfView = REEL_FOV
			vcam.Parent = vpf
			vpf.CurrentCamera = vcam
			-- A WorldModel, or the frame does no lighting pass and the animal comes
			-- out flat and muddy. Same reason as the reel's tiles.
			local vworld = Instance.new("WorldModel")
			vworld.Parent = vpf

			local pdef = PetConfig.get(r.petId)
			local pm = pdef and petModel(pdef)
			if pm then
				pm.Parent = vworld
				local bcf, bsize = pm:GetBoundingBox()
				local radius = math.max(bsize.X, bsize.Y, bsize.Z) * 0.5
				local d = radius / math.tan(math.rad(REEL_FOV * 0.5)) * 1.5
				vcam.CFrame = CFrame.lookAt(bcf.Position + TILE_DIR * d, bcf.Position)
			end

			-- 81..107 against the ribbon's 109: a two-line name fills its whole box,
			-- and at 30 tall the second line landed three pixels inside the ribbon.
			local nm = label(face, r.displayName or r.petId or "?", 13, CREAM, false)
			nm.Position = UDim2.fromOffset(5, 81)
			nm.Size = UDim2.new(1, -10, 0, 26)
			nm.TextWrapped = true
			nm.ZIndex = 12
			local nmCap = Instance.new("UITextSizeConstraint")
			nmCap.MaxTextSize = 13
			nmCap.MinTextSize = 8
			nmCap.Parent = nm

			-- The tier on a pill of its own colour, so the card can be read by
			-- shape and hue before a word of it is read.
			local ribbon = Instance.new("Frame")
			ribbon.AnchorPoint = Vector2.new(0.5, 1)
			ribbon.Position = UDim2.new(0.5, 0, 1, -7)
			ribbon.Size = UDim2.fromOffset(CELL_W - 20, 20)
			ribbon.BackgroundColor3 = tier.glow
			ribbon.BorderSizePixel = 0
			ribbon.ZIndex = 12
			ribbon.Parent = face
			corner(ribbon, 999)
			PanelKit.outline(ribbon, 2.5)
			local rt = label(ribbon, string.upper(tier.key or r.tier or ""), 11, INK, false)
			rt.Size = UDim2.fromScale(1, 1)
			rt.TextStrokeTransparency = 1
			rt.ZIndex = 13

			-- The luck figure as a chip on the corner, where a badge goes.
			if r.luckText and r.luckText ~= "" then
				local chip = Instance.new("Frame")
				chip.AnchorPoint = Vector2.new(1, 0)
				chip.Position = UDim2.new(1, 3, 0, -5)
				chip.Size = UDim2.fromOffset(46, 21)
				chip.BackgroundColor3 = INK
				chip.BorderSizePixel = 0
				chip.ZIndex = 14
				chip.Parent = face
				corner(chip, 999)
				PanelKit.outline(chip, 2.5, tier.glow)
				local ct = label(chip, r.luckText, 11, tier.glow, false)
				ct.Size = UDim2.fromScale(1, 1)
				ct.TextStrokeTransparency = 1
				ct.ZIndex = 15
			end

			-- The pick of the haul wears a star and keeps breathing after it lands.
			if isBest and total > 1 then
				local star = label(face, "\u{2605}", 26, tier.glow, false)
				star.AnchorPoint = Vector2.new(0, 0)
				star.Position = UDim2.fromOffset(-6, -10)
				star.Size = UDim2.fromOffset(30, 30)
				star.ZIndex = 15
				star.Rotation = -14
			end

			tiles[i] = { scale = cellScale, best = isBest }
		end

		--[[
			THEY LAND ONE AT A TIME, LEFT TO RIGHT.

			Ten tiles appearing together is a table; ten dropping in with a tick
			each is an opening. The gap is capped so a ten-pack still finishes well
			inside the nap below, and the best one gets the louder note.
		]]
		task.spawn(function()
			local gap = math.min(0.075, 0.55 / math.max(total, 1))
			for i, t in ipairs(tiles) do
				if stale() then
					return
				end
				TweenService:Create(t.scale, Motion.info(0.34, Motion.Ease.pop), { Scale = 1 }):Play()
				AudioKit.play(t.best and "Upgrade" or "WoodTick", nil,
					t.best and 0.7 or 0.3, t.best and 1 or (1.2 + i * 0.03))
				if t.best then
					--[[
						THE BEST TILE BREATHES, FOREVER, AND REDUCED MOTION STOPS IT.

						-1 with reverses is an endless pulse -- the same class of thing
						as the ray spin, and the reason neither can simply be handed to
						Motion.info: a TweenInfo built there carries no repeat count, so
						collapsing its duration would leave it looping FASTER rather
						than stopping. It is skipped instead.

						Nothing is lost by skipping it. The tile is already scaled to 1
						by the tween above, and `best` is carried by its own colour and
						sound; the pulse was only ever the flourish on top.
					]]
					task.delay(0.34, function()
						if not stale() and not Motion.reduced() then
							TweenService:Create(t.scale, TweenInfo.new(0.9,
								Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
								{ Scale = 1.05 }):Play()
						end
					end)
				end
				task.wait(gap)
			end
		end)

		local holder, face = PanelKit.chunky(body, 224, 46,
			PetConfig.tierInfo(best.tier).color, 14)
		holder.AnchorPoint = Vector2.new(0.5, 1)
		holder.Position = UDim2.new(0.5, 0, 1, 0)
		holder.ZIndex = 8
		local capt = PanelKit.text(face, "EQUIP BEST", 21, Enum.Font.LuckiestGuy, PanelKit.C.white)
		capt.Size = UDim2.fromScale(1, 1)
		capt.ZIndex = 10
		PanelKit.punch(capt, 3)
		TouchFit.activated(face, function()
			Net.get("PetEquip"):FireServer({ action = "best" })
			capt.Text = "EQUIPPED"
			face.Active = false
			AudioKit.play("UIClick", nil, 1, 1.1)
		end)

		card.Size = UDim2.fromOffset(W * 0.8, H * 0.8)
		TweenService:Create(card, Motion.info(0.4, Motion.Ease.pop),
			{ Size = UDim2.fromOffset(W, H) }):Play()
		AudioKit.play("CoinShower", nil, 0.8, 1)
		skip.Visible = true
		nap(4.5)
	end

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

--[[
	THE MENU, which is what the prompt does now.

	The server has already recorded that this player was standing at the
	station when they pressed E (see PetServer.openMenu); this only draws the
	choice and sends a count back.
]]
Net.get("EggMenu").OnClientEvent:Connect(function(info)
	if type(info) ~= "table" then
		return
	end
	local def = PetConfig.eggFor(info.eggKey)
	if def then
		info.color = def.color
		info.accent = def.accent
		info.blurb = info.blurb or def.blurb
	end
	openBuyMenu(info)
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