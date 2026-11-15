--[[
	TutorialHud  --  StarterPlayerScripts.TutorialHud  (ModuleScript)

	FOUR STEPS, AND THEY ARE THE LOOP:

		fill the bag -> sell -> wash -> widen the sifter

	THERE USED TO BE A SECOND SELL AFTER THE WASH, AND THE GAME OUTGREW IT.

	The argument for it was good and is worth keeping written down, because it
	is still true of the FIRST sale: the sell pad takes CLEANED items and skips
	crusted ones, so a first-timer who fills a bag and cashes it in is left
	holding lumps and a payout smaller than the bag they were carrying. That
	leftover IS the lesson, and it is the only moment in the game where the
	answer to "why did that not all sell?" is standing forty studs away with a
	hose on it. Step three still answers it.

	What killed step four is that WashServer now SELLS THE FIND ITSELF on the
	beat the reveal lands (see the AUTO-SELL note in that file). The sale the
	step was waiting for therefore happens a second or so BEFORE the step arms
	its own TotalEarned baseline -- so the card ticked itself off for something
	the player had not done, pointed them at a sell pad where nothing would
	happen, and left them holding an empty bag. A step that completes itself is
	worse than no step: it teaches the player that the card is not describing
	the game.

	Removed rather than repaired because there is nothing left for it to teach.
	The wash step already ends with the money in the purse and the reveal card
	on screen; asking for a walk to the pad afterwards is asking for a walk.

	Shown once per ACCOUNT now rather than once per session -- SaveService
	carries TutorialDone and TutorialServer stamps it. See TutorialConfig.

	WHAT IS ON THE CARD, AND WHAT IS NOT
	------------------------------------
	An icon, three words, a meter and five pips. No sentences. The card answers
	"which of the five am I on and how far through it", and it answers it in a
	shape you can read without stopping -- because the actual instruction is not
	on the card at all. It is in the world: TutorialGuide puts a pulsing disc on
	the floor of the place you are meant to be, a floating marker over it with
	the distance, a trail of dots leading there from your feet, and a chevron on
	the screen edge when it is behind you. A tutorial that has to be READ is a
	tutorial that gets closed.

	The METER is the other half of that. "Fill your bag" with a bar filling is a
	complete instruction; "fill your bag" on its own is a question about when.
	Steps that have a number worth watching draw it (the load, the crust
	draining as it rinses); the rest draw the distance to where they are sending
	you.

	IT WATCHES ATTRIBUTES AND OWNS NO REMOTES, and that is still the design.
	Every step of the loop already writes its result onto the player --
	CurrentWeight when something comes out of the sand, TotalEarned when it
	sells, CrustedWeight when it needs rinsing and again when it does not, Lv_*
	when a level is bought. A tutorial that asked the server "have they sold
	yet" would be a second source of truth for something that already has one,
	and it would need SiftServer, WashServer, the sell pad and the shop all to
	remember to tell it.

	EVERY TEST IS A DELTA FROM THE MOMENT ITS OWN STEP BEGAN, and that is the
	one structural change from the four-step version this replaces. That card
	took ONE baseline when it appeared and tested every step against it, which
	works exactly as long as no action appears twice -- and this sequence sells
	twice. Against a single baseline, the first sale satisfies step four before
	the player has washed anything. So each step arms its own baseline in
	`arm`, and `done` measures against that.

	THE PRICE OF THAT is that the sequence is strictly in order now, where the
	old one advanced furthest-first. It is the right trade here: three of the
	four steps are things a new player cannot do early (there is nothing to sell
	until the bag has something in it, nothing to wash until a lump is in the
	bag), and the one that could be done out of order -- buying an upgrade with
	the money from the first sale -- is a step the card will simply find already
	satisfied the moment it arms, so it completes on its own the instant they
	get there.

	A STEP THAT DOES NOT APPLY IS SKIPPED, NOT FAILED. `arm` may answer "skip",
	and the wash step does exactly that when the bag has no crust in it:
	TutorialServer guarantees a crusted find for every player it armed, but it
	cannot arm somebody it never saw as new, and sending that player to a bay
	that will refuse them is the one thing this must never do. It used to cascade
	-- skipping the wash also skipped the sale after it -- and with that sale
	gone the skip now hands straight to the shop, which is the right place for a
	player who had nothing to rinse to end up.

	WHY HudKit AND NOT PanelKit
	---------------------------
	This is chrome that sits in a corner for a stretch of the session, which is
	HudKit's brief -- and PanelKit.chunky, the obvious shell for it, builds its
	face as a TextButton with a press animation wired in. The whole card would
	have depressed like a button and done nothing, which reads as broken. Only
	the DISMISS key is a key. HudKit's silhouette is PanelKit's exactly (slab,
	4px outline, gloss cap) so it still matches the rail beside it.

	WHERE IT SITS
	-------------
	Top right, tucked against the rail, because the left column is spoken for:
	CTB_HUD's three readouts run to y = 164 and InventoryHud's drawer opens at
	HudKit.L.DRAWER_Y underneath them.

	IT MEASURES THE RAIL rather than re-deriving MenuHud's constants, the same
	way MenuHud's own railBottom() does. Two traps in doing that, both of which
	bit here first:

	  - the rail must be looked up RECURSIVELY. UiFit reparents every top-level
	    child into a FitRoot, so the non-recursive find returns nothing.
	  - AbsolutePosition is in SCREEN pixels, already multiplied by UiFit's
	    scale, while Position offsets inside the FitRoot are pre-scale. Mixing
	    them is correct at scale 1 and wrong on every phone. Hence the divide.

	IgnoreGuiInset IS TRUE TO MATCH BeachMenuHud. Two ScreenGuis that overlap
	have to agree about it or their AbsolutePositions are measured from origins
	a topbar apart -- and this one is positioned off a frame living in the
	other. TutorialGuide draws its screen-edge chevron into this same gui and
	depends on that choice too; see its header, trap 3.
]]

local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local HudKit = require(Modules:WaitForChild("HudKit"))
local PanelKit = require(Modules:WaitForChild("PanelKit"))
local ToastKit = require(Modules:WaitForChild("ToastKit"))
local AudioKit = require(Modules:WaitForChild("AudioKit"))
local UiFit = require(Modules:WaitForChild("UiFit"))
local TutorialConfig = require(Modules:WaitForChild("TutorialConfig"))
-- For the PET step: the attribute name PetServer publishes the owned count on,
-- and the key of the egg this card points a first-timer at. Named here rather
-- than typed, the same contract the sifter track below keeps.
local PetConfig = require(Modules:WaitForChild("PetConfig"))
-- For the LAST STEP'S track: its attribute name, and the name the shop prints
-- beside it. Both derived rather than typed, so renaming the track in one place
-- renames it on this card too instead of leaving it pointing at a row that no
-- longer exists under that name.
local ProgressionConfig = require(Modules:WaitForChild("ProgressionConfig"))

-- For fieldAt / the island squares only: "the sand" is the one target in the
-- sequence that is a PLACE rather than a thing, and Config is where the places
-- are. Everything else resolves to a BasePart.
local Config = require(ReplicatedStorage:WaitForChild("CTB"):WaitForChild("Config"))

-- For format() only, so "12.5" and "12" are written the way both of the game's
-- other load readouts write them rather than a third way.
local WeightSystem = ReplicatedStorage:WaitForChild("WeightSystem")
local WeightConfig = require(WeightSystem:WaitForChild("WeightConfig"))

local TutorialGuide = require(script.Parent:WaitForChild("TutorialGuide"))

-- Touch targets: see the module. Substituted for MouseButton1Click/Activated so
-- a tap in the margin around a control that renders under 44px on a phone still
-- reaches the same handler. No-ops on desktop and on controls already big enough.
local TouchFit = require(Modules:WaitForChild("TouchFit"))

local C, A = HudKit.C, HudKit.A
local player = Players.LocalPlayer

local TutorialHud = {}

----------------------------------------------------------------
-- READING THE PLAYER
----------------------------------------------------------------
local function num(name: string): number
	return tonumber(player:GetAttribute(name)) or 0
end

local function rootPart(): BasePart?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return (root and root:IsA("BasePart")) and root or nil
end

-- Mid-wash. WashClientController publishes no state, but its ScreenGui being
-- enabled IS the state, and it is the same signal awaitIntro below reads the
-- opening shot's curtain off.
local function washing(): boolean
	local pg = player:FindFirstChild("PlayerGui")
	local hud = pg and pg:FindFirstChild("WashHud")
	return hud ~= nil and hud:IsA("ScreenGui") and hud.Enabled
end

----------------------------------------------------------------
-- WHERE EACH STEP HAPPENS
----------------------------------------------------------------
--[[
	RESOLVED LIVE, EVERY THIRD OF A SECOND, AND NEVER CACHED ACROSS A STEP.
	Half of this row is BUILT AT RUNTIME -- StoreBuilder raises the shop on
	boot, BayBuilder adopts or builds the bay, the island builders clone both
	onto four more shores -- so a handle taken once at start() is a handle taken
	before some of these exist. Cheap enough to simply ask again: two
	FindFirstChilds and, for the bay, a tag lookup.
]]

local SAND_INSET = 26

-- "The sand", which is not an instance. Answers nil once the player is
-- standing on it -- there is nowhere left to point, and the instruction from
-- there is "walk about", which the load bar reports better than an arrow.
local function sandTarget(): Vector3?
	local root = rootPart()
	if not root then
		return nil
	end
	local here = root.Position
	if Config.fieldAt(here) then
		return nil
	end

	local best, bx, bz, bd
	for _, isl in ipairs(Config.ISLANDS) do
		local x = math.clamp(here.X, isl.cx - isl.half, isl.cx + isl.half)
		local z = math.clamp(here.Z, isl.cz - isl.half, isl.cz + isl.half)
		local d = (Vector3.new(x, 0, z) - Vector3.new(here.X, 0, here.Z)).Magnitude
		if not bd or d < bd then
			best, bd, bx, bz = isl, d, x, z
		end
	end
	if not best then
		return nil
	end

	-- PULLED IN OFF THE BOUNDARY. The nearest point of the rakeable square is
	-- the line where the sand stops, and on the home beach that line is the
	-- promenade kerb the player is already standing on -- a marker on it reads
	-- as "you are there" for a step that has not started.
	local toCentre = Vector3.new(best.cx - bx, 0, best.cz - bz)
	local inset = (toCentre.Magnitude > SAND_INSET) and toCentre.Unit * SAND_INSET or toCentre
	return Vector3.new(bx, here.Y, bz) + inset
end

local function sellTarget(): BasePart?
	local beach = workspace:FindFirstChild("Beach")
	local area = beach and beach:FindFirstChild("SellArea")
	local pad = area and area:FindFirstChild("SellPad", true)
	return (pad and pad:IsA("BasePart")) and pad or nil
end

-- BY TAG, and nearest. WashServer binds bays by CollectionService rather than
-- by path for exactly this reason -- four islands have one and they are built
-- by four different scripts -- so following the same tag is what makes this
-- point at the bay you can actually reach.
local function washTarget(): BasePart?
	local root = rootPart()
	local here = root and root.Position or Vector3.zero
	local best, bd
	for _, model in ipairs(CollectionService:GetTagged("WashBay")) do
		if model:IsDescendantOf(workspace) then
			local anchor = model:FindFirstChild("PromptAnchor", true)
				or model:FindFirstChild("Stand", true)
			if anchor and anchor:IsA("BasePart") then
				local d = (anchor.Position - here).Magnitude
				if not bd or d < bd then
					best, bd = anchor, d
				end
			end
		end
	end
	return best
end

--[[
	THE EGG PLAZA, BY TAG AND NEAREST -- the same contract washTarget keeps just
	above, and for the same reason: PetStationBuilder raises a plaza on five
	islands and tags every tube PetStation, so following the tag is what makes
	this point at the one the player can actually walk to.

	THE BASIC TUBE IS PREFERRED OVER THE MERELY NEAREST. A plaza is a ROW of
	five, and four of them cost 15,000 and upwards -- so "whichever tube is
	closest" can land a first-timer on the 160,000,000 Arctic egg, which reads as
	"you cannot afford this" at the exact moment the card is telling them they
	can. The Basic egg is 500, which is the one being asked for. Nearest is the
	fallback, for a plaza that does not carry it.

	PromptAnchor, AND NOT A CHILD CALLED "Root". A station HAS a Root and it is a
	Frame, inside the SurfaceGui that draws the price bar -- so a recursive
	FindFirstChild("Root") returns a GuiObject, the IsA("BasePart") test below
	rejects it, and every tube is silently skipped. Measured on a live station,
	which is also where the name came from: PromptAnchor is the model's
	PrimaryPart, and it is the same part name washTarget above looks for.
]]
-- ONE SOURCE, shared with TutorialServer's purse floor. It was a literal here
-- and the floor would have had a second copy of it -- two places to change a
-- price that has to move together, which is the shape of a drift bug rather
-- than a risk of one.
local FIRST_EGG = TutorialConfig.FirstEgg

local function eggTarget(): BasePart?
	local root = rootPart()
	local here = root and root.Position or Vector3.zero
	local best, bd, any, ad
	for _, model in ipairs(CollectionService:GetTagged("PetStation")) do
		if model:IsDescendantOf(workspace) then
			local anchor = model.PrimaryPart or model:FindFirstChild("PromptAnchor", true)
			if anchor and anchor:IsA("BasePart") then
				local d = (anchor.Position - here).Magnitude
				if model:GetAttribute("EggKey") == FIRST_EGG and (not bd or d < bd) then
					best, bd = anchor, d
				end
				if not ad or d < ad then
					any, ad = anchor, d
				end
			end
		end
	end
	return best or any
end

local function shopTarget(): BasePart?
	local beach = workspace:FindFirstChild("Beach")
	if not beach then
		return nil
	end
	local store = beach:FindFirstChild("Store")
	if store then
		--[[
			THE THRESHOLD BEFORE THE COUNTER, and the difference is where the
			ping ends up. Every target here is dropped to the ground under it,
			and the ground under the counter's prompt anchor IS THE COUNTER --
			so pointing at the anchor lays a glowing disc across the shopkeeper's
			till and leaves the trail of dots stopping at the front of the stall.
			StoreBuilder's Threshold is the strip of floor a customer stands on,
			which is the thing actually being asked for.

			The anchor is still the fallback: the bazaar and the two island shops
			are built by other scripts and have no threshold of their own.
		]]
		local sill = store:FindFirstChild("Threshold", true)
		if sill and sill:IsA("BasePart") then
			return sill
		end
		local anchor = store:FindFirstChild("PromptAnchor", true)
		if anchor and anchor:IsA("BasePart") then
			return anchor
		end
	end
	-- The NAME is the contract: MenuHud opens the stock panel off any
	-- ProximityPrompt called ShopPrompt, wherever in the model it hangs, so
	-- following the same name survives the counter being rebuilt.
	local prompt = beach:FindFirstChild("ShopPrompt", true)
	if prompt and prompt.Parent and prompt.Parent:IsA("BasePart") then
		return prompt.Parent
	end
	return nil
end

----------------------------------------------------------------
-- THE UPGRADE THE LAST STEP ASKS FOR
----------------------------------------------------------------
--[[
	SIFTER WIDTH, and both halves of it come off ProgressionConfig rather than
	being typed here: the attribute the purchase moves, and the name the shop
	prints beside the row. The whole point of the step is that a player can
	match the words on the card to the words in the list, so a rename that
	moved one and not the other would break it silently.

	Guarded, because this file is not allowed to be the reason a client boot
	stops. If the track ever goes away the step falls back to the generic
	attribute name -- which simply never fires, leaving a card the player can
	still close, rather than an error during show().
]]
local SIFTER_KEY = "RollerWidth"
local SIFTER_TRACK = ProgressionConfig.TrackByKey and ProgressionConfig.TrackByKey[SIFTER_KEY]
local SIFTER_ATTR = (ProgressionConfig.AttrPrefix or "Lv_") .. SIFTER_KEY
local SIFTER_NAME = (SIFTER_TRACK and SIFTER_TRACK.name) or "Sifter Width"

if not SIFTER_TRACK then
	warn("[CleanTheBeach] tutorial: ProgressionConfig has no " .. SIFTER_KEY
		.. " track -- the last step will not complete on its own")
end

----------------------------------------------------------------
-- THE FIVE
----------------------------------------------------------------
--[[
	`arm`  takes this step's baseline, and may answer "skip".
	`done` answers "has it happened SINCE arm", never an absolute.
	`watch` names the attributes worth hanging a changed-signal on. It is a
	        hint, not the test: several of these numbers also move for reasons
	        that are not progress -- CrustedWeight falls as you wash and rises
	        again as you dig -- so a signal only means it is worth re-asking.
]]
local STEPS = {
	{
		title = "FILL YOUR BAG",
		word = "RAKE HERE",
		-- A BASKET, and it is not the first choice. U+1FAA3 BUCKET is the obvious
		-- glyph for a bag of beach litter and Roblox has no font for it: it
		-- measures 6px wide against 28 for every other emoji in this table and
		-- draws as nothing at all, on a tile 58px across. Measure a new glyph's
		-- TextBounds before trusting it.
		glyph = "\u{1F9FA}",
		tint = A.sun,
		target = sandTarget,
		meter = "load",
		watch = { "CurrentWeight", "MaxWeight", "RollerBlocked" },
		arm = function() end,
		-- RollerBlocked FIRST, because it is the game's OWN answer to "is this
		-- bag full" -- CTBBridge.hasRoom, the same function that stops the
		-- sifter. A bag holding 11.4 of 12 lbs with only 2 lb lumps left to
		-- find is full in every sense that matters, and the arithmetic below
		-- would sit there waiting for a find that can never fit.
		done = function()
			if player:GetAttribute("RollerBlocked") == true then
				return true
			end
			local max = num("MaxWeight")
			return max > 0 and num("CurrentWeight") >= max - 0.75
		end,
	},
	{
		title = "SELL YOUR HAUL",
		word = "SELL",
		glyph = "\u{1F4B0}",
		tint = A.foam,
		target = sellTarget,
		meter = "range",
		watch = { "TotalEarned", "Coins" },
		--[[
			NOTHING SELLABLE IS AN ANSWER, NOT A FAILURE -- the same call the WASH
			step below makes about an empty crust, and this step needed it more.

			The sell pad takes CLEANED items and refuses crusted ones, and it is
			right to: a lump has no rolled value yet. But the only completion test
			this step has is TotalEarned moving, so a bag holding nothing but crust
			parks the player on the pad watching it say "wash the crust off those
			first" while the card says SELL -- and there is no way out, because the
			step before this one has already declared the bag full.

			CurrentWeight MINUS CrustedWeight is the sellable load. WeightService
			computes CrustedWeight as the weight of everything in the bag whose state
			is not "Cleaned", which is exactly the set SellServer.sellAll refuses, and
			both attributes are rounded from the same sum -- so an all-crust bag gives
			a difference of exactly zero and the epsilon is only guarding an empty one.

			The cascade in enter() then hands straight to WASH, which is where a
			player holding only lumps was always meant to be going, and the bay sells
			the find itself on the reveal -- so the money still lands.

			TutorialServer.capCrust makes this rare rather than routine (one lump per
			bag while the onboarding runs). It is kept because "rare" is not "never":
			step one also completes on RollerBlocked, which is the game answering
			"nothing else fits" rather than "the bag is full of sellable things".
		]]
		arm = function(mem)
			mem.earned = num("TotalEarned")
			if num("CurrentWeight") - num("CrustedWeight") <= 0.001 then
				return "skip"
			end
			return nil
		end,
		done = function(mem)
			return num("TotalEarned") > mem.earned + 0.5
		end,
	},
	{
		title = "WASH THE LUMPS",
		word = "WASH BAY",
		glyph = "\u{1F6BF}",
		tint = A.sea,
		target = washTarget,
		meter = "crust",
		watch = { "CrustedWeight" },
		arm = function(mem)
			mem.crust = num("CrustedWeight")
			-- NOTHING TO WASH IS AN ANSWER, NOT A FAILURE. See the header.
			if mem.crust <= 0.001 then
				return "skip"
			end
			return nil
		end,
		--[[
			ALL OF IT, OR AS MUCH AS THEY MEANT TO DO.

			The bay auto-advances to the next lump after each reveal, so "the
			first rock is clean" is the middle of the job rather than the end of
			it -- and a card that jumped to SELL AGAIN while the player was
			still holding the hose would be pointing them away from what they
			are doing. So it waits for the bag to be clean, OR for them to have
			washed something and walked off, which is them deciding they are
			finished. Either way it cannot stall: leaving the bay ends the step.
		]]
		done = function(mem)
			local crust = num("CrustedWeight")
			if crust > mem.crust - 0.001 then
				return false
			end
			return crust <= 0.001 or not washing()
		end,
	},
	{
		--[[
			BEFORE THE SHOP CARD, NOT AFTER IT, AND THE ORDER IS THE DESIGN.

			WHY THE STEP EXISTS. Measured 2026-09-22 against 899 live profiles:
			owning a pet is the strongest thing in the data next to coming back --
			23.1% of pet owners returned for a second day against 4.4% of everybody
			else, and it holds inside EVERY session-length band, so it is not merely
			a marker for players who happened to stay longer. 79% of players own no
			pet at all, and 82% of the one-day churners never owned one.

			They are not short of money. The Basic egg is 500 coins; the median
			one-day player earns 9,619 and logs off with 1,423 still in the bank,
			and the plaza stands 89 studs from the wash bay. Nothing in the game
			ever mentioned it -- TutorialConfig carried zero occurrences of "pet"
			or "egg", and the onboarding funnel had no step for one.

			WHY IT CANNOT GO AFTER THE SHOP CARD. TutorialServer stamps
			DoneAttribute the moment ANY track moves; the tick loop below hides this
			whole card on that attribute; and `finish` fires the outro flight at the
			same instant. A card placed after the shop would therefore be drawn over
			a cinematic for the half second before it was torn down.

			A NUDGE, NOT A GATE. The server retires the tutorial off hasBought
			whatever card happens to be showing, so a player who ignores this one
			still buys the sifter, still gets the big bag back, and still gets the
			send-off. The only thing skipping it costs them is the pet.
		]]
		title = "HATCH YOUR FIRST PET",
		word = "EGGS",
		-- MEASURED, as the basket note on step one demands rather than suggests.
		-- At TextSize 40 in SourceSansBold this renders 26.5px wide -- identical
		-- to that basket and to the cart on the step below -- against 16.0 for
		-- U+1FAA3, the bucket that note records as drawing nothing at all.
		glyph = "\u{1F95A}",
		tint = A.foam,
		target = eggTarget,
		-- A CONTROL, NOT A DISTANCE. See the `travel` branch in tick() for the
		-- measurements and for why this one step is the exception.
		meter = "travel",
		watch = { PetConfig.OwnedAttribute },
		--[[
			ABSOLUTE, NOT A DELTA FROM THIS STEP'S OWN ARM.

			Every other card here measures a CHANGE since it began, because this
			sequence sells twice and one shared baseline would let the first sale
			satisfy the second sale's step. Neither half of that reasoning reaches
			here: there is no second hatch. The question is "does this player own a
			pet", so somebody who already bought one stands the card down instead of
			being asked for another 500 coins.
		]]
		arm = function()
			if num(PetConfig.OwnedAttribute) > 0 then
				return "skip"
			end
			return nil
		end,
		done = function()
			return num(PetConfig.OwnedAttribute) > 0
		end,
	},
	{
		--[[
			ONE NAMED TRACK, NOT "ANY UPGRADE".

			The shop opens on four rows and a first-timer has no way to tell
			which of them is worth the seventy pounds they are holding. Sifter
			Width is the answer to that: it is the CHEAPEST row, it is the only
			one whose effect is visible in the world the moment it is bought --
			the rake gets wider and the next pass turns up more -- and it makes
			the step after the tutorial, which is another bagful, faster than the
			one before it. An upgrade whose benefit the player cannot SEE teaches
			them that upgrades are a tax rather than the point of the loop.

			So the title names the row exactly as the shop prints it, because
			matching a word on a card to a word in a list is the whole of the
			task being asked for here.
		]]
		title = "BUY " .. SIFTER_NAME:upper(),
		word = "SHOP",
		glyph = "\u{1F6D2}",
		tint = A.sun,
		target = shopTarget,
		meter = "range",
		-- Nameable now, where "any upgrade" was not: one attribute, so this gets
		-- the cheap changed-signal rather than leaning on show()'s unfiltered one.
		watch = { SIFTER_ATTR },
		-- `or 1` on BOTH sides. ProgressionServer writes no attribute at all
		-- until the first purchase on a track, and treating a missing baseline
		-- as zero would fire on the level 1 every track already starts at.
		arm = function(mem)
			mem.sifter = tonumber(player:GetAttribute(SIFTER_ATTR)) or 1
		end,
		done = function(mem)
			return (tonumber(player:GetAttribute(SIFTER_ATTR)) or 1) > mem.sifter
		end,
	},
}

----------------------------------------------------------------
-- LAYOUT
----------------------------------------------------------------
local W, H = 292, 112
--[[
	THE CARD'S TOP, AND WHY IT IS NO LONGER A CONSTANT.

	This was a flat 54 under the comment "level with the top of the rail", and it
	was neither. MEASURED on a live client at UiFit's 0.6 compact scale: the rail's
	first button sits at AbsolutePosition.Y = +7.8, and this card sat at -25.6 --
	thirty-three pixels apart, and on the WRONG SIDE OF ZERO.

	Negative is the part that matters. This ScreenGui is IgnoreGuiInset, so y = 0
	is the bottom of the Roblox topbar and anything above it is drawn UNDER
	Roblox's own strip -- which on this client measured 58px tall. The card's
	dismiss key landed at -20.2, i.e. inside that strip, where Roblox's buttons
	take the tap first.

	SO THE X WAS NOT BROKEN, IT WAS UNDERNEATH THE TOPBAR. Two players reported it
	on 2026-09-10 -- "can't make it go away with the x" -- and both were on
	phones, where the strip is taller and the menu button sits in exactly that
	corner. It is also why this never came up on desktop: the same 54 at scale 1.0
	puts the card at -4, barely clipping, and a mouse can still reach most of a
	key that is four pixels high.

	54 SURVIVES ONLY AS A FLOOR. railTop() measures the real rail when one is up,
	and otherwise clears the measured inset by hand -- because the whole defect
	was a number that assumed an inset height and a UI scale that were both
	wrong.
]]
local TOP = 54            -- floor only; see railTop()
local RAIL_GUTTER = 12    -- between this card's right edge and the rail's left
local FALLBACK_RIGHT = 124  -- 20 screen gutter + 92 rail + 12, if the rail is not up

local ICON = 58
local COL = 84            -- where the text column starts, right of the icon
-- Stops short of the dismiss key, which occupies W-32 .. W-10. 36 rather than
-- 40 because the longest title on the card is now the shop row's own name --
-- measured at 168px against LuckiestGuy 20, which needed the extra four.
local TEXT_W = W - COL - 36

-- See the header for both traps this is threading.
local function railInset(): number
	local cam = workspace.CurrentCamera
	local pg = player:FindFirstChild("PlayerGui")
	local menu = pg and pg:FindFirstChild("BeachMenuHud")
	local rail = menu and menu:FindFirstChild("Rail", true)
	if cam and rail and rail:IsA("GuiObject") and rail.AbsoluteSize.X > 0 then
		local scale = UiFit.get()
		if scale > 0 then
			local rightPx = cam.ViewportSize.X - rail.AbsolutePosition.X
			return rightPx / scale + RAIL_GUTTER
		end
	end
	return FALLBACK_RIGHT
end

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------
local gui, root, face
local iconFace, iconSlab, glyphLabel
local stepLabel, titleLabel
local barHolder, barFill, barLevel, barCaption, rangeLabel
local pips = {}

-- TWO CONNECTION LISTS, and that is not tidiness. The dismiss key is wired
-- once in build() and has to survive hide(); the attribute watchers are wired
-- per show() and have to not. One list meant hide() unwired the X, so a second
-- show() put up a card that could not be closed.
local permConns, showConns = {}, {}

--[[
	THE VERTICAL TWIN OF railInset, and it exists for the same reason: the rail is
	laid out by another ScreenGui at a scale this file does not own, so the only
	honest way to line up with it is to MEASURE it.

	Both roots are IgnoreGuiInset and both are absorbed by UiFit, so the rail's
	offset inside its own FitRoot is the offset this card wants inside its own --
	once it is taken back out of rendered pixels into the unscaled units a Size
	offset is written in. Same conversion railInset does.

	THE FALLBACK IS THE BUG FIX. With no rail up there is nothing to measure, and
	the old constant put the card under the topbar -- so the fallback clears the
	inset that is actually reported, with eight pixels of air under it, and only
	then falls back on 54 if that is somehow the larger number.

	BELOW THE STATE BLOCK, NOT BESIDE railInset, because it reads `root` -- and
	one line higher that name is a nil global rather than this file's own upvalue.
]]
local function railTop(): number
	local scale = UiFit.get()
	if scale <= 0 then
		scale = 1
	end
	local pg = player:FindFirstChild("PlayerGui")
	local menu = pg and pg:FindFirstChild("BeachMenuHud")
	local rail = menu and menu:FindFirstChild("Rail", true)
	local parent = root and root.Parent
	if rail and rail:IsA("GuiObject") and rail.AbsoluteSize.Y > 0
		and parent and parent:IsA("GuiObject")
	then
		return (rail.AbsolutePosition.Y - parent.AbsolutePosition.Y) / scale
	end
	return math.max(TOP, (GuiService:GetGuiInset().Y + 8) / scale)
end

local started, running = false, false
--[[
	WAS THIS CARD ASKED FOR, RATHER THAN OFFERED?

	Set only by the replay hook at the foot of this file, which is only ever
	reached from TutorialServer.restart -- the admin verb for walking the
	onboarding on an account that finished it long ago. Nothing on an ordinary
	join writes it.

	It exists to exempt that card from the retire test in show()'s slow loop.
	restart() clears TutorialDone and re-grants the lump credit, but it does NOT
	wipe rebirths -- so a deliberate replay on a forty-tide test account trips
	"this player is not new" on its very first tick and closes itself instantly.
	The retire test is there to catch a card nobody asked for; this says when
	somebody did.
]]
local replayed = false
local at = 1
local mem = {}
local pointedPart, pointedPos = nil, nil

local function trackConn(list, c: RBXScriptConnection)
	table.insert(list, c)
end

----------------------------------------------------------------
-- THE CARD
----------------------------------------------------------------
local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "TutorialHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true      -- matches BeachMenuHud; see the header
	gui.DisplayOrder = 11          -- under the rail's 12, over InventoryHud's 6
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	-- A plain Frame face: passive, no press. See the header.
	local holder, f = HudKit.surface(gui, W, H, 12, C.rowFace)
	root, face = holder, f
	root.Name = "Card"
	root.AnchorPoint = Vector2.new(1, 0)

	--[[
		THE ICON, AND IT IS THE BIGGEST THING ON THE CARD ON PURPOSE. A bucket,
		a coin, a shower head, a gem, a trolley -- five silhouettes that are
		told apart at a glance and in any language, which is more than the
		title beside them can claim. It is retinted per step by paint().
	]]
	local iconHolder, iFace, iSlab = HudKit.surface(face, ICON, ICON, 16, A.sun)
	iconHolder.Name = "Icon"
	iconHolder.Position = UDim2.fromOffset(14, 20)
	iconHolder.ZIndex = 3
	iSlab.ZIndex = 3
	iFace.ZIndex = 4
	HudKit.gloss(iFace, 16)
	local iGloss = iFace:FindFirstChild("Gloss")
	if iGloss then
		iGloss.ZIndex = 5
	end
	iconFace, iconSlab = iFace, iSlab
	glyphLabel = HudKit.text(iFace, "", 34, C.text)
	glyphLabel.ZIndex = 6

	-- "STEP n OF 5": small and dim, because it is the frame around the
	-- instruction rather than the instruction.
	stepLabel = HudKit.text(face, "", 11, C.rowSub, Enum.Font.GothamBold)
	stepLabel.TextXAlignment = Enum.TextXAlignment.Left
	stepLabel.TextYAlignment = Enum.TextYAlignment.Top
	stepLabel.Position = UDim2.fromOffset(COL, 18)
	stepLabel.Size = UDim2.fromOffset(TEXT_W, 14)

	titleLabel = HudKit.text(face, "", 20, C.rowText, Enum.Font.LuckiestGuy)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.TextYAlignment = Enum.TextYAlignment.Top
	titleLabel.Position = UDim2.fromOffset(COL, 34)
	-- TEXT_W stops 40px short of the right edge: the dismiss key occupies that
	-- corner and a left-aligned label wide enough to reach it would run a long
	-- title underneath it. Stopping short truncates instead, which is the
	-- failure that can be seen.
	titleLabel.Size = UDim2.fromOffset(TEXT_W, 24)

	--[[
		THE METER, and the two modes share a row rather than stacking, because a
		card that changes height between steps jumps under the rail.

		Only ever ONE of these is visible. paint() picks; tick() fills.
	]]
	local bHolder, _, fill, _, _, level = HudKit.bar(face, 116, 16, A.sunLight, A.sun)
	bHolder.Name = "Meter"
	bHolder.Position = UDim2.fromOffset(COL, 62)
	bHolder.ZIndex = 3
	barHolder, barFill, barLevel = bHolder, fill, level

	barCaption = HudKit.text(face, "", 12, C.rowSub, Enum.Font.GothamBold)
	barCaption.TextXAlignment = Enum.TextXAlignment.Left
	barCaption.Position = UDim2.fromOffset(COL + 124, 62)
	barCaption.Size = UDim2.fromOffset(W - COL - 138, 16)
	barCaption.ZIndex = 8

	rangeLabel = HudKit.text(face, "", 14, C.rowSub, Enum.Font.GothamBold)
	rangeLabel.TextXAlignment = Enum.TextXAlignment.Left
	rangeLabel.Position = UDim2.fromOffset(COL, 62)
	rangeLabel.Size = UDim2.fromOffset(TEXT_W, 18)
	rangeLabel.ZIndex = 8

	-- One pip per step along the bottom, so "how much of this is left" is
	-- answerable without reading anything.
	local pipW = math.floor((W - 28 - (#STEPS - 1) * 6) / #STEPS)
	for i = 1, #STEPS do
		local pip = Instance.new("Frame")
		pip.Name = "Pip" .. i
		pip.Size = UDim2.fromOffset(pipW, 6)
		pip.Position = UDim2.fromOffset(14 + (i - 1) * (pipW + 6), H - 18)
		pip.BackgroundColor3 = C.rowDark
		pip.BorderSizePixel = 0
		pip.ZIndex = 12
		pip.Parent = face
		HudKit.corner(pip, 3)
		pips[i] = pip
	end

	--[[
		Dismiss. A tutorial you cannot close is a modal. This IS a button, so it
		gets the key treatment and the press that comes with it.

		EVERY LAYER OF IT IS RE-Z-INDEXED BY HAND. The gui is ZIndexBehavior
		Sibling, so ZIndex is global and a parent's does not carry to its
		children -- and HudKit.surface, which key() is built on, hands back a slab
		at 1 and a face at 2. Left alone, the whole key draws UNDER the card face
		it is sitting on. PanelKit.card lifts its own close key exactly this way.
	]]
	local keyHolder, keyFace, keySlab = HudKit.key(face, 22, C.rowDark, 7)
	keyHolder.Name = "Skip"
	keyHolder.AnchorPoint = Vector2.new(1, 0)
	keyHolder.Position = UDim2.fromOffset(W - 10, 9)
	keyHolder.ZIndex = 13
	keySlab.ZIndex = 13
	keyFace.ZIndex = 14
	-- The gloss cap is built INSIDE the face by HudKit.key at its own fixed
	-- ZIndex, so lifting the face alone buries it and the key loses the one
	-- highlight that makes it read as plastic. It has to come up too.
	local keyGloss = keyFace:FindFirstChild("Gloss")
	if keyGloss then
		keyGloss.ZIndex = 15
	end
	local x = HudKit.text(keyFace, "X", 12, C.rowText, Enum.Font.LuckiestGuy)
	x.ZIndex = 16
	trackConn(permConns, TouchFit.press(keyFace, function()
		TutorialHud.hide()
	end))

	-- A resize moves the rail, and this card is placed off the rail. Registered
	-- HERE rather than in show(): UiFit.onChanged has no matching remove, so
	-- doing it per-show would stack a listener each time. build() runs once.
	UiFit.onChanged(function()
		if running and root then
			root.Position = UDim2.new(1, -railInset(), 0, railTop())
		end
	end)

	UiFit.fit(gui)

	-- The world half hangs off this same gui. AFTER UiFit.fit, deliberately:
	-- fit() absorbs whatever is already there, and although the guide's
	-- container is sized in scale and would be skipped either way, ordering it
	-- so that it is never even offered is one less thing depending on that
	-- rule staying true.
	TutorialGuide.attach(gui)
end

----------------------------------------------------------------
-- POINTING
----------------------------------------------------------------
local function retarget(force: boolean?)
	local step = STEPS[at]
	if not step or not running then
		return
	end

	local got = step.target and step.target() or nil
	local part, pos = nil, nil
	if typeof(got) == "Instance" then
		part = got
	elseif typeof(got) == "Vector3" then
		pos = got
	end

	-- ONLY ON A REAL CHANGE. TutorialGuide.point re-tints five parts and a
	-- billboard and throws away its cached ground, so calling it three times a
	-- second for a target that has not moved is a raycast and a pile of
	-- property writes for nothing. The 12 stud slack is for the sand, which is
	-- derived from the player's own position and therefore drifts as they walk.
	local same = (part == pointedPart)
		and ((pos == nil) == (pointedPos == nil))
		and (pos == nil or (pos - pointedPos).Magnitude <= 12)
	if same and not force then
		return
	end
	pointedPart, pointedPos = part, pos

	if not part and not pos then
		TutorialGuide.clear()
		return
	end
	TutorialGuide.point({
		part = part,
		position = pos,
		label = step.word,
		glyph = step.glyph,
		tint = step.tint,
	})
end

local function rangeTo(): number?
	local root = rootPart()
	if not root then
		return nil
	end
	local to = pointedPos
	if pointedPart and pointedPart.Parent then
		to = pointedPart.Position
	end
	if not to then
		return nil
	end
	local a, b = root.Position, to
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

----------------------------------------------------------------
-- RENDERING
----------------------------------------------------------------
local function paint()
	local step = STEPS[at]
	if not step then
		return
	end
	stepLabel.Text = ("STEP %d OF %d"):format(at, #STEPS)
	titleLabel.Text = step.title
	titleLabel.TextColor3 = C.rowText
	glyphLabel.Text = step.glyph

	-- regrad, NOT BackgroundColor3: surface() has been through grad(), which
	-- leaves the base white so the stops are the colour you get. Writing the
	-- background instead multiplies the tint against itself and the icon comes
	-- out near black. HudKit.bar's header spells the same trap out.
	HudKit.regrad(iconFace, step.tint, HudKit.darken(step.tint, 0.24))
	iconSlab.BackgroundColor3 = HudKit.darken(step.tint, 0.5)
	-- The meter wears the step's colour too, so "gold means the bag" and "blue
	-- means the crust" are the same statement the icon beside it is making.
	HudKit.regrad(barFill, step.tint, HudKit.darken(step.tint, 0.3))

	local meter = step.meter == "load" or step.meter == "crust"
	barHolder.Visible = meter
	barCaption.Visible = meter
	rangeLabel.Visible = not meter

	for i, pip in ipairs(pips) do
		pip.BackgroundColor3 = (i < at) and A.foam or (i == at) and A.sun or C.rowDark
	end
end

local function tick()
	local step = STEPS[at]
	if not step then
		return
	end

	if step.meter == "load" then
		local max, load = num("MaxWeight"), num("CurrentWeight")
		barLevel.Value = (max > 0) and math.clamp(load / max, 0, 1) or 0
		barCaption.Text = ("%s / %s"):format(WeightConfig.format(load), WeightConfig.format(max))
	elseif step.meter == "crust" then
		-- DRAINS rather than fills, because what is being watched is how much is
		-- left to do. `mem.crust` is what was in the bag when the step armed, so
		-- a bag that picks up MORE crust mid-wash is clamped rather than
		-- overflowing the pill.
		local crust = num("CrustedWeight")
		local from = math.max(mem.crust or crust, 0.001)
		barLevel.Value = math.clamp(crust / from, 0, 1)
		barCaption.Text = ("%s lbs"):format(WeightConfig.format(crust))
	elseif step.meter == "travel" then
		--[[
			THE ONE STEP THAT NAMES A CONTROL INSTEAD OF A DISTANCE.

			Every other card measures a walk, because every other leg of this
			onboarding is one. Measured 2026-09-23 on the Beach promenade:

			  Spawn -> Sell   40      Sell -> Wash    23
			  Wash  -> Shop   26      Wash -> Plaza   89

			The stations are one continuous ribbon from x -64 to +94 and the egg
			plaza is its EAST END, while the shop this card hands to is the west.
			So a range readout here says "92m away" directly after three legs of
			20-40m, pointing away from the next step. It does not read as a
			direction, it reads as a reason to skip -- and 83.91% of players did,
			which is the largest drop in the onboarding funnel by a factor of six.

			THE WALK WAS NEVER REQUIRED. TravelHud already lists EGGS among its
			destinations and its STAND_OFF puts the player down 8 studs from the
			tube -- "outside every counter's own footprint and inside the prompt
			range of all of them, so you arrive with the button already offered".
			One tap, no distance. A first-timer four cards into a tutorial simply
			has no reason to know that control exists, so this step says so.

			THE WORLD MARKER STAYS. `target` is still eggTarget, so anyone who
			would rather walk it still gets the ping and the chevron. What is
			removed is only the number that made walking look like the only option.

			Checked before writing this: the promenade cannot simply be re-ordered
			instead. It is fully built out -- the largest gap between any two
			stations is 6.5 studs against the 13.6 a tube needs -- so putting the
			eggs on the route would mean moving world geometry. This does not.
		]]
		rangeLabel.Text = "TRAVEL \u{2192} EGGS"
	else
		local d = rangeTo()
		rangeLabel.Text = d and ("%dm away"):format(math.max(1, math.floor(d + 0.5))) or ""
	end
end

----------------------------------------------------------------
-- THE MACHINE
----------------------------------------------------------------
local enter, evaluate

local function finish()
	-- PUT THE CARD AWAY FIRST, AND ONLY THEN CONGRATULATE. The toast is the
	-- decoration and the dismissal is the job, so the job must not be
	-- downstream of it: this runs inside a task.delay with nothing above it to
	-- catch a throw, and a toast that failed took the close with it and left
	-- the finished card on screen for the rest of the session.
	TutorialHud.hide()
	--[[
		THE SEND-OFF NAMES THE REASON TO COME BACK, and this is the one moment in
		the session where that lands.

		It read "That is the loop. Off you go." Measured 2026-09-25: the opening
		shot mentions tomorrow / daily / coming back ZERO times, and so did this
		file. The daily reward was named only by a rotating tip, which a third of
		players never get past one of -- see TipConfig.FirstTipId for the counts.

		This is the highest-attention beat a first-timer has: they have just
		finished the walk, the outro is about to fly, and the card is coming down.
		It costs one string.

		6s RATHER THAN 4s because the line is twice as long. The toast is not
		competing with anything -- hide() has already taken the card away.
	]]
	pcall(ToastKit.toast,
		"That is the loop. Off you go \u{2014} and the daily reward climbs every day you come back.",
		"good", 6)
	pcall(AudioKit.play, "Upgrade")
end

--[[
	BECOME step `i`, skipping any that answer "skip" as they arm.

	The loop is what makes a skip cascade safely: the wash step skipping hands
	straight to the sale after it, which skips too, and the walk ends on the
	shop rather than on a step that quietly never completes.
]]
function enter(i: number)
	while i <= #STEPS do
		at = i
		local step = STEPS[i]
		local ok, answer = pcall(step.arm, mem)
		if not ok then
			warn("[CleanTheBeach] tutorial step " .. i .. " would not arm: " .. tostring(answer))
			answer = nil
		end
		if answer ~= "skip" then
			break
		end
		i += 1
	end

	if i > #STEPS then
		finish()
		return
	end

	-- retarget BEFORE tick: the distance readout is measured off whatever the
	-- guide is currently pointing at, and advance() clears that -- so ticking
	-- first paints one empty frame of it on every step change.
	paint()
	retarget(true)
	tick()
	PanelKit.popIn(root, W, H)
	-- A step can arm already satisfied -- the upgrade bought with the money
	-- from the first sale is the one that actually happens -- and waiting for
	-- an attribute signal that has already been and gone would hang there.
	evaluate()
end

-- A tick, then move on. The pause is the point: a step that vanishes the
-- instant it completes never gets read as "I did that".
local function advance()
	if not running then
		return
	end
	local done = STEPS[at]
	local from = at
	-- ONE LAST TICK BEFORE THE STEP IS PARKED. `at` goes out of range below for
	-- the length of the pause and tick() no-ops while it is, so without this the
	-- meter freezes on the reading BEFORE the one that completed the step -- a
	-- crust bar stuck at two pounds under a ticked-off WASH THE LUMPS.
	tick()
	if done then
		titleLabel.Text = done.title .. "  \u{2713}"
		titleLabel.TextColor3 = A.foam
	end
	for i = 1, math.min(#pips, from) do
		pips[i].BackgroundColor3 = A.foam
	end
	-- The guide goes NOW rather than in 0.9s. The step is over; leaving the
	-- chevrons on the sell pad through the tick reads as "go back and sell
	-- again", which for two of these five steps is a real instruction.
	pointedPart, pointedPos = nil, nil
	TutorialGuide.clear()
	pcall(AudioKit.play, "StreakStep")

	-- `at` is parked past the end for the length of the pause so evaluate()
	-- cannot re-enter and advance twice off the same signal.
	at = #STEPS + 1
	task.delay(0.9, function()
		if running then
			enter(from + 1)
		end
	end)
end

function evaluate()
	if not running then
		return
	end
	local step = STEPS[at]
	if not step then
		return
	end
	local ok, hit = pcall(step.done, mem)
	if ok and hit then
		advance()
	end
end

----------------------------------------------------------------
-- SHOW / HIDE
----------------------------------------------------------------
function TutorialHud.show()
	if running then
		return
	end
	if not gui then
		build()
	end
	-- Idempotent, and here as well as in build() on purpose: hide() DESTROYS the
	-- guide's parts rather than switching them off, so a second show() in the
	-- same session would otherwise point at instances that no longer exist.
	TutorialGuide.attach(gui)
	running = true
	mem = {}
	pointedPart, pointedPos = nil, nil

	root.Position = UDim2.new(1, -railInset(), 0, railTop())
	gui.Enabled = true

	-- The named attributes are the cheap path; the unfiltered signal is the
	-- backstop for the upgrade step, which cannot name what it waits for.
	for _, step in ipairs(STEPS) do
		for _, name in ipairs(step.watch) do
			trackConn(showConns, player:GetAttributeChangedSignal(name):Connect(evaluate))
		end
	end
	trackConn(showConns, player.AttributeChanged:Connect(evaluate))

	enter(1)

	--[[
		THE SLOW LOOP, and it is not a second source of truth -- evaluate() is
		still driven by the attribute signals above. This fills the meter, keeps
		the distance honest and re-resolves the target, none of which any
		attribute reports: the player walking toward the sell pad changes
		nothing on the player at all.

		It DOES re-run evaluate as well, and that is deliberate rather than
		belt-and-braces. Two of the five tests do not depend on an attribute
		moving at the moment they become true -- the wash step goes from "not
		yet" to "done" when the player walks AWAY from the bay, which is a
		ScreenGui closing, not a number changing.

		Ten a second, ended by `running` rather than by a handle to cancel.
	]]
	task.spawn(function()
		local n = 0
		while running do
			n += 1
			local ok, err = pcall(function()
				--[[
					RETIRE IF THIS PLAYER TURNS OUT NOT TO BE NEW.

					The belt to awaitProfile's braces, and it is here because the
					failure it guards against is the one players actually reported:
					a card raised on a blind looksNew has NOTHING that will ever
					close it. Its last step waits for an upgrade level to move past
					where it was when the step armed, and a veteran armed it at the
					level they already had -- so the card asks for a purchase they
					have made, will not accept the one they make next if they cannot
					afford it, and stays.

					THE TWO FACTS IT TRUSTS ARE BOTH ONE-WAY. TutorialDone is set
					once and never cleared, and no player reaches a rebirth during
					their own onboarding -- the first one costs 10,800 coins against
					a tutorial bag worth a few hundred. So neither can fire on a
					genuine first run, and either one arriving means the profile
					landed late and this card should never have been raised.

					NOT looksNew ITSELF: that also tests TotalEarned, which moves the
					moment a real first-timer sells their first bag -- half way
					through the tutorial the card is running.
				]]
				if not replayed
					and (player:GetAttribute(TutorialConfig.DoneAttribute)
						or (tonumber(player:GetAttribute("Rebirths")) or 0) > 0)
				then
					TutorialHud.hide()
					return
				end
				tick()
				evaluate()
				if n % 3 == 0 then
					retarget()
					-- RE-PLACED, not placed once. show() can run before MenuHud has
					-- built its rail, and railTop()/railInset() then answer from the
					-- fallbacks -- which are deliberately conservative rather than
					-- correct. UiFit.onChanged catches a resize but not a rail that
					-- simply arrived late, and this is two cheap reads.
					if root then
						root.Position = UDim2.new(1, -railInset(), 0, railTop())
					end
				end
			end)
			if not ok then
				warn("[CleanTheBeach] tutorial tick failed: " .. tostring(err))
			end
			task.wait(0.1)
		end
	end)
end

function TutorialHud.hide()
	if not running then
		return
	end
	running = false
	for _, c in ipairs(showConns) do
		c:Disconnect()
	end
	table.clear(showConns)

	-- EVERYTHING, INCLUDING THE PARTS IN WORKSPACE. This is shown once and
	-- never again in the session, so there is nothing to keep warm -- and a
	-- pulsing disc left on the sell pad after the card is gone is the worst
	-- possible leftover, because it is still an instruction.
	pcall(TutorialGuide.stop)

	if not (gui and root) then
		return
	end
	local away = root.Position + UDim2.fromOffset(24, 0)
	TweenService:Create(root, TweenInfo.new(0.25, Enum.EasingStyle.Quad),
		{ Position = away }):Play()
	task.delay(0.28, function()
		if not running and gui then
			gui.Enabled = false
		end
	end)
end

----------------------------------------------------------------
-- BOOT
----------------------------------------------------------------
--[[
	WAIT OUT THE OPENING SHOT. IntroCinema raises an opaque curtain at
	DisplayOrder 260 and sweeps the HUDs off once a second for the length of
	it; TutorialHud is on that list, so a card put up during the shot would be
	switched off and stay off. Watching its ScreenGui is the signal it does not
	otherwise publish -- enabled means the curtain is up, disabled again means
	it has come down.

	Both waits are bounded. If the intro fails to build it destroys its gui and
	nothing is coming; if it hangs, the tutorial is still not the thing worth
	losing. Either way this falls through and shows the card.
]]
local function awaitIntro()
	local pg = player:WaitForChild("PlayerGui")
	local deadline = os.clock() + 8
	local sawCurtain = false
	while os.clock() < deadline do
		local g = pg:FindFirstChild("IntroCinema")
		if not g then
			break
		end
		if g.Enabled then
			sawCurtain = true
			break
		end
		task.wait(0.1)
	end
	if not sawCurtain then
		return
	end
	deadline = os.clock() + 60
	while os.clock() < deadline do
		local g = pg:FindFirstChild("IntroCinema")
		if not g or not g.Enabled then
			return
		end
		task.wait(0.2)
	end
end

--[[
	WAIT FOR THE SERVER TO SAY WHO THIS PLAYER IS -- the test the opening shot
	was standing in for, asked directly.

	THE BUG THIS REPLACES (2026-09-10). looksNew reads three attributes that all
	arrive with the profile, so before the restore lands it answers YES for
	everybody. awaitIntro was the only thing holding the card back until those had
	arrived -- and it gives the curtain EIGHT SECONDS to go up, then gives up. On
	a phone the loading screen routinely runs longer than that, so the wait fell
	through, the second looksNew test was as blind as the first, and the card went
	up in front of veterans. Two players reported it the same evening, both on
	mobile, one at three rebirths and one at two -- and because the card was
	measuring a step they had already completed before it armed, it then had
	nothing to complete and sat there.

	SIXTY SECONDS, AND FALLING THROUGH IS SAFE. A place with no API access never
	settles a profile at all -- except that SaveService stamps the flag on that
	path too, precisely so this cannot hang. The timeout is the backstop for a
	server old enough not to stamp it: on that server this behaves exactly as it
	did before, which is the right way to degrade.
]]
local function awaitProfile()
	local deadline = os.clock() + 60
	while os.clock() < deadline do
		if TutorialConfig.profileSettled(player) then
			return true
		end
		task.wait(0.2)
	end
	return false
end

function TutorialHud.start()
	if started then
		return
	end
	started = true

	-- Spawned and wrapped: this is the least important thing on the client and
	-- it is not allowed to be the reason a boot stops.
	task.spawn(function()
		local ok, err = pcall(function()
			--[[
				THE PROFILE FIRST, AND THERE IS NO EARLY looksNew TEST ANY MORE.

				There used to be one here, before the wait, as a cheap way to skip
				the whole thing for an obvious veteran. It could never do that job:
				at this point in the boot NOBODY has their attributes yet, so it
				answered "new" for every player in the game and skipped nobody. What
				it actually did was make the code look like it had two guards when
				it had none.
			]]
			awaitProfile()
			if not TutorialConfig.looksNew(player) then
				return
			end
			-- ONLY NOW is the opening shot worth waiting out, and only as a
			-- COSMETIC wait: IntroCinema sweeps this HUD off while its curtain is
			-- up, so a card raised under it would be switched off and stay off.
			-- Nothing about WHO the player is depends on this any more.
			awaitIntro()
			-- Re-tested on the far side regardless. The shot is fifteen seconds
			-- long and a player can finish the tutorial's first step inside it if
			-- they were already part-way through on a previous session.
			if not TutorialConfig.looksNew(player) then
				return
			end
			task.wait(1.2)
			TutorialHud.show()
		end)
		if not ok then
			warn("[CleanTheBeach] tutorial did not start: " .. tostring(err))
		end
	end)
end

----------------------------------------------------------------
-- PLAYING IT AGAIN
----------------------------------------------------------------
--[[
	AN ATTRIBUTE, NOT A REMOTE, and that is this feature's whole design rather
	than a shortcut. TutorialConfig's header is explicit that the two halves of
	the onboarding never speak -- "there is no remote in this feature at all" --
	because the only thing that can make them contradict each other is
	disagreeing about who is new. TutorialServer.restart re-grants the lump
	credit and the easy wash and THEN ticks this counter, so by the time the
	edge arrives here the world it describes is already standing.

	A COUNTER RATHER THAN A FLAG, so it can only ever fire on a deliberate
	restart: nothing writes it on an ordinary join, which is what keeps this out
	of the way of the normal path -- start() below still owns the first showing,
	still waits out the opening shot, and still tests looksNew.

	hide() FIRST, ALWAYS. show() returns immediately while `running` is true, so
	restarting a card that is already up would otherwise do nothing at all. The
	beat between them is the card sliding out; without it the new card pops in
	on top of the old one's exit tween.
]]
player:GetAttributeChangedSignal(TutorialConfig.ReplayAttribute):Connect(function()
	if (tonumber(player:GetAttribute(TutorialConfig.ReplayAttribute)) or 0) <= 0 then
		return
	end
	-- Latched for the session: this card was ASKED for, so the retire test in
	-- show()'s loop must leave it alone. See the note over `replayed`.
	replayed = true
	TutorialHud.hide()
	task.delay(0.35, function()
		TutorialHud.show()
	end)
end)

return TutorialHud