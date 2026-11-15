--[[
	MenuHud  --  StarterPlayerScripts.MenuHud

	Right-hand rail + panels: Rebirth, Rewards, Pets, Index, Shop, Settings -- plus the
	Beach Shop's stock list, which is NOT on the rail. It opens by walking up to
	the counter at (26, -173) and pressing E, because there is a building there
	now. See THE SHOP, FROM THE WORLD below.

	THE CARTOON RECIPE
	------------------
	Four things do almost all the work, and every surface here gets all four:

	  1. A SHADOW SLAB behind, offset down a few px in a darker shade of the
	     same hue. This is what makes a button read as a physical chunky object
	     rather than a coloured rectangle -- and pressing it moves the face down
	     ONTO the slab, which is why the click feels like a real button.
	  2. A THICK DARK OUTLINE (4-6px). Thin strokes read as "default Roblox".
	  3. A GLOSS CAP -- a white bar across the top ~40%, faded out downward.
	     Cheap fake specular; it is the single biggest "toy plastic" cue.
	  4. BACK EASING on every tween, so things overshoot and settle.

	Panels sit dead straight. An earlier pass tilted them a degree or two on the
	theory that axis-aligned rectangles look like a form -- in practice it just
	read as a panel that had not finished animating, so it is gone. The pop-in
	scale is what gives them life instead.

	ICONS
	-----
	Emoji, rendered through a TextLabel. They are real multi-colour glyphs from
	the system font, which is what was actually wanted -- not flat white vector
	shapes, which is the look that got rejected. Each also keeps a named
	`IconSlot` ImageLabel underneath it, so dropping real sprite art in later is
	one assignment and the emoji is hidden:

	    slot.Image = "rbxassetid://..."   -- then slot.Visible = true
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
-- The Robux shop's one privileged call. PromptGamePassPurchase is a CLIENT call
-- -- there is no server-side way to open a purchase dialog -- and the server
-- hears the outcome on PromptGamePassPurchaseFinished and then asks Roblox
-- rather than taking this screen's word for it. See GamePassService.
local MarketplaceService = game:GetService("MarketplaceService")
-- Settings -> Feedback only, kept up here with the rest rather than fetched
-- inside the panel, so there is one list of what this file touches.
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Stats = game:GetService("Stats")
local LocalizationService = game:GetService("LocalizationService")
-- For the Rewards banner's INVITE button. Both calls it makes are client-only
-- and both can throw on a platform with no invite UI, so every use below is
-- pcall'd -- see the note at the button.
local SocialService = game:GetService("SocialService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Config = require(Modules:WaitForChild("ProgressionConfig"))
-- The shop's SECOND ladder -- AtvConfig.Upgrades, the car rake -- and the one
-- definition of owning a machine, which is what the Car tab is locked behind.
-- Replicated config, read only: every price here is re-derived on the server.
local AtvConfig = require(ReplicatedStorage:WaitForChild("AtvConfig"))
local ItemConfig = require(Modules:WaitForChild("ItemConfig"))
local ItemVisuals = require(Modules:WaitForChild("ItemVisuals"))
local InventoryController = require(Modules:WaitForChild("InventoryController"))
local Net = require(Modules:WaitForChild("Net"))
local PetConfig = require(Modules:WaitForChild("PetConfig"))
-- Beach Buddies: how many friends are on this server and what that is worth.
-- Replicated config over a server-written attribute, read only -- the till
-- re-derives the same number for itself before it pays anything.
local BuddyConfig = require(Modules:WaitForChild("BuddyConfig"))
-- The code table, for the Rewards panel's CODES tab. Read only for the COUNT --
-- the panel never tests a typed code against it; see the note at that tab.
local CodeConfig = require(Modules:WaitForChild("CodeConfig"))
-- The playtime ladder, for its COUNT. The labels and amounts still come off the
-- snapshot -- this is only so the strip builds as many cards as there are tiers
-- instead of the five it used to hardcode. See that loop.
local RewardsConfig = require(Modules:WaitForChild("RewardsConfig"))
-- The three sky rungs and which hour each forces. LightingLock is what applies
-- them; this file only draws the row that chooses one.
local DaylightConfig = require(Modules:WaitForChild("DaylightConfig"))
-- For the Helpful Tips row's key only. TipClient is what reads the attribute
-- this row writes; this file just draws the switch, the same way it does for the
-- sky rung above.
local TipConfig = require(Modules:WaitForChild("TipConfig"))
-- The two halves of the Robux shop: WHAT is for sale (assembled out of
-- PassConfig and AtvConfig so no id is typed twice) and what a pass COSTS,
-- which is read off what GamePassService published rather than out of a file.
local ShopConfig = require(Modules:WaitForChild("ShopConfig"))
local PassConfig = require(Modules:WaitForChild("PassConfig"))
-- The Quick Upgrade developer product, for its ID only -- so the stock rows can
-- draw a Robux button for it and know whether it is a real product yet. The
-- PRICE is not in there: ProductServer publishes it into the same folder the
-- passes use, and PassConfig.price reads it back.
local ProductConfig = require(Modules:WaitForChild("ProductConfig"))
-- The Pets tab is its own file. This one is big enough already, and keeping the
-- panel out of it means the two can be worked on at the same time without
-- colliding. MenuHud owns the rail; PetsPanel owns everything behind the key.
local PetsPanel = require(script.Parent:WaitForChild("PetsPanel"))
local AudioKit = require(Modules:WaitForChild("AudioKit"))
local UiFit = require(Modules:WaitForChild("UiFit"))
-- The cartoon recipe below used to live HERE, and only here, which is why the
-- car spawner ended up drawing its own. It moved to PanelKit; these locals are
-- now aliases so the forty-odd call sites in this file are untouched and there
-- is exactly one implementation of the look.
local PanelKit = require(Modules:WaitForChild("PanelKit"))
-- For the one thing this file could not say: why a row that is drawn knocked
-- back did nothing when it was pressed. See the SOON rows below.
local ToastKit = require(Modules:WaitForChild("ToastKit"))

-- Touch targets: see the module. Substituted for MouseButton1Click/Activated so
-- a tap in the margin around a control that renders under 44px on a phone still
-- reaches the same handler. No-ops on desktop and on controls already big enough.
local TouchFit = require(Modules:WaitForChild("TouchFit"))
-- Curves, durations, and the Reduced Motion answer. Used here for the four
-- LOOPING animations on this HUD -- see each one's note. A tween that repeats
-- forever is the thing a motion-sensitive player most needs stopped, because
-- unlike every other animation in this file it never ends on its own.
local Motion = require(Modules:WaitForChild("Motion"))
-- For `plotOf` and the attribute behind it -- whether this player is out on the
-- Long Shore. The rebirth button is the one control on this rail the server
-- refuses while they are; see the note in buildRebirth's refresh.
local AfkConfig = require(Modules:WaitForChild("AfkConfig"))
-- Which single row the shop is allowed to sell while the onboarding card is
-- still asking for it, and the name to print on the ones it is not. Pure
-- replicated data; ProgressionServer refuses the same rows server-side, so this
-- is the picture of a rule rather than the rule itself.
local TutorialConfig = require(Modules:WaitForChild("TutorialConfig"))

local player = Players.LocalPlayer
local MenuHud = {}

--------------------------------------------------------------------------
-- PALETTE
--------------------------------------------------------------------------
local C = PanelKit.C

local darken = PanelKit.darken
local corner = PanelKit.corner
local outline = PanelKit.outline
local grad = PanelKit.grad
local gloss = PanelKit.gloss
local chunky = PanelKit.chunky
local text = PanelKit.text
local punch = PanelKit.punch

-- The "you have not looked at the shop yet" mark on the shop key.
local ALERT_MARK = "rbxassetid://78060820456484"

--------------------------------------------------------------------------
-- SHOWING ARTWORK ONCE IT IS REALLY THERE
--------------------------------------------------------------------------
--[[
	The shelf icons are drawn over a hand-made "Fallback" block, and exactly one
	of the two may be visible: the art has a transparent background, so leaving
	both up shows the blocks through every gap in it.

	KEYED ON PreloadAsync's STATUS CALLBACK, NOT ON ImageLabel.IsLoaded.

	The note that used to sit by the shelf said IsLoaded is never signalled and
	so has to be polled. That was half the story, and the missing half is the
	bug: in this place IsLoaded does not merely lag, it never becomes true at
	all. Measured on the five coin-pack rows -- every one reported
	AssetFetchStatus.Success from the callback below while IsLoaded was still
	false, with the artwork on screen at full opacity the whole time. So the poll
	could never win, it simply ran its twenty seconds and gave up, and the drawn
	blocks sat on top of real artwork for the rest of the session. That is the
	"it still loads when I scroll down" everyone was seeing: nothing was loading,
	the placeholder just never left.

	PreloadAsync's second argument fires once per asset with a real status, so
	there is nothing to poll and nothing to time out.

	RETRIED, because Success is not guaranteed first time for an asset still in
	moderation -- which is the case the blocks exist for. After four goes the
	blocks stay, which is the right answer for an id that is genuinely dead.

	GUARDED by `watching`, so the repaint backstop can call this on every open
	without stacking a new request on a row that already has one in flight.
]]
local watching = {}

local function revealArt(im: ImageLabel, fb: GuiObject)
	if watching[im] then
		return
	end
	watching[im] = true
	task.spawn(function()
		local ContentProvider = game:GetService("ContentProvider")
		for attempt = 1, 4 do
			local arrived = false
			pcall(function()
				ContentProvider:PreloadAsync({ im }, function(_, status)
					if status == Enum.AssetFetchStatus.Success then
						arrived = true
					end
				end)
			end)
			if arrived then
				if fb.Parent then
					fb.Visible = false
				end
				watching[im] = nil
				return
			end
			task.wait(attempt * 2)
		end
		-- Released rather than left set: a later repaint is allowed to try again,
		-- which is what covers an asset that clears moderation mid-session.
		watching[im] = nil
	end)
end

--------------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------------
-- Forward-declared. All three are defined down in RAIL ICONS, which is far
-- below the panels that now also want them -- the reward tiles draw padlocks
-- and gift boxes out of the same two primitives. Nothing calls them at module
-- scope, so by the time any builder runs they are assigned.
--
-- STEEL is in here for the same reason and it is not optional: a local declared
-- BELOW a function is not in that function's scope at all, so reading it from
-- buildRewards would have found the global instead, and `ipart` assigns its
-- colour argument straight to BackgroundColor3 -- which throws on nil rather
-- than quietly drawing something grey.
local ipart, idisc, STEEL

local gui, rail, scrim
local panels = {}
local openName = nil
local snapshot = nil

--[[
	THE SCRIM.

	Every panel in this file is a cream card being read against a beach in full
	sun, and the panel loses. The eye keeps getting pulled off it by the litter,
	the palms and the sea, and no amount of work on the card itself fixes that,
	because the problem is not the card -- it is everything around it.

	Dimming the world for as long as something is open is most of what makes
	these read as designed rather than as pasted on.

	INERT ON PURPOSE. It is not Active and it is not a button, so it changes
	nothing about where a click lands; it is a backdrop and nothing else.
]]
local function setScrim(on: boolean)
	if not scrim then
		return
	end
	TweenService:Create(scrim, TweenInfo.new(on and 0.18 or 0.14),
		{ BackgroundTransparency = on and 0.45 or 1 }):Play()
end

local function comma(n)
	local o = tostring(math.floor(n or 0)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (o:gsub("^,", ""))
end
local function fmt(v, t)
	return (t and t.decimals) and string.format("%." .. t.decimals .. "f", v) or comma(v)
end

--[[
	SHORT FORM -- the rule and the whole argument for it now live in
	PanelKit.compact, unchanged. It moved when the AFK card needed the same
	rounding: a coins-per-second rate that scales with the run reaches six
	figures, and two copies of a rounding rule is how two screens end up
	disagreeing about what 999,999 is called.

	Kept as a local name because this file calls it as one in the quest rows,
	and a rename there would be churn for nothing.
]]
local compactNum = PanelKit.compact

-- THE ONE BALANCE.
--
-- Every money readout in the game reads this attribute -- it is the single
-- store the server writes (see SellServer's currency adapter) and it replicates
-- to us for free. This panel used to draw `snapshot.coins` instead: a COPY,
-- taken whenever ProgressionSync last fired. Any balance change that did not
-- come through SellServer left the copy behind, and the shop then sat there
-- showing an older number than the coin counter across the screen, with rows
-- painted red for prices the player could already afford.
--
-- The server is still the only thing that can move it, and still re-checks the
-- price itself on every purchase. Reading it here only decides what is drawn.
local function wallet(): number
	return player:GetAttribute("Coins") or 0
end

--------------------------------------------------------------------------
-- PANEL SHELL
--------------------------------------------------------------------------
-- The banner comes back too, and so does PanelKit's setTitle. The banner is
-- somewhere to hang a second global action -- the Pets panel's tray button is
-- on it. setTitle is the shop's: there is more than one counter in the world
-- now and the panel has to say which one you are standing at. Both beat
-- reaching into PanelKit's layout from out here, which is exactly how the
-- retitle spent so long writing to the wrong label.
local function makePanel(title, w, h, tint)
	local root, body, closeFace, banner, setTitle = PanelKit.card(gui, title, w, h, tint)
	root.Visible = false
	--[[
		NOTHING FITS THE PANEL TO THE SCREEN FROM HERE ANY MORE.  2026-09-18

		This used to call UiFit.clampPanel(root, w, h) on the way past, on the
		grounds that every menu panel is born through this function so one call
		covers the lot. It covered nothing: PanelKit.card had already put its own
		`SafeFit` UIScale on the root, Roblox honours only the first one, and the
		clamp written second was ignored on every panel this ever built. See the
		tombstone at the top of UiFit for the measurement.

		PanelKit.card fits the card itself now -- to the SAFE AREA, allowing for the
		banner that overhangs its top edge -- which is the same job done once, in
		the file that knows the card's shape.
	]]
	TouchFit.press(closeFace, function()
		MenuHud.close()
	end)
	return root, body, banner, setTitle
end

local function openPanel(name)
	if openName == name then
		MenuHud.close()
		return
	end
	for _, p in panels do
		p.root.Visible = false
		-- A panel can own a modal that is NOT parented inside its root -- the
		-- Index's detail card covers the whole screen, so it hangs off the gui.
		-- Hiding the root would leave it up over whatever opened next.
		if p.closeDetail then
			p.closeDetail()
		end
	end
	local p = panels[name]
	if not p then
		return
	end
	openName = name
	setScrim(true)
	PanelKit.popIn(p.root, p.w, p.h)
	if p.refresh then
		p.refresh()
	end
	--[[
		ONLY ON OPEN, WHICH `refresh` IS NOT.

		refresh runs here AND on every repaint -- a price landing, a pass
		resolving, the balance moving -- so anything one-shot hung off it fires
		repeatedly while the panel just sits there. A banner that re-jiggled every
		time an attribute changed would read as a twitch rather than as a greeting.
	]]
	if p.onOpen then
		p.onOpen()
	end
end

function MenuHud.close()
	openName = nil
	setScrim(false)
	for _, p in panels do
		p.root.Visible = false
		if p.closeDetail then
			p.closeDetail()
		end
	end
end

--[[
	PUT A NAMED PANEL IN FRONT OF THE PLAYER, FROM OUTSIDE THIS MODULE.

	NOT `openPanel` ITSELF, BECAUSE THAT ONE IS A TOGGLE. It is wired to the rail
	keys, where pressing the key you are already on has to shut the panel again --
	which is exactly wrong for a caller that means "show them this": the one
	player it would misfire on is the one who already had the panel open, and it
	would CLOSE it on them. So the rail keeps the toggle and this is a one-way
	door.

	Its caller is RebirthUnlockPrompt, which asks for the Rebirth panel when a
	player walks to the ferry without having turned the tide. Unknown names are
	the callee's problem and always have been -- openPanel returns on a missing
	entry rather than throwing -- so a panel that has not been built yet (this can
	be called before MenuHud.start) is a no-op, not an error.
]]
function MenuHud.open(name: string)
	if openName == name then
		return
	end
	openPanel(name)
end

--------------------------------------------------------------------------
-- PANELS THE WORLD OPENS
--
-- The stock list used to be a rail button. It is the inside of the building at
-- (26, -173) now, so what opens it is the ProximityPrompt StoreBuilder mounts
-- on the counter -- matched BY NAME, so renaming it there unhooks it here.
--
-- The Index has followed it off the rail. It is the computer on the desk that
-- stands on the sand between the sell shop and the Beach Shop, and what opens
-- it is IndexPrompt on Beach.IndexTerminal.PromptAnchor. That desk is AUTHORED
-- rather than built by anything, so the name is the whole contract: rename the
-- prompt in Studio and the Index goes unreachable, with nothing here to
-- complain about it.
--
-- Client-side on purpose. Opening a panel is not a privileged act, and the
-- purchase behind it goes through BuyUpgrade, which re-derives level, cost and
-- balance on the server. So there is no proximity check here worth faking.
--------------------------------------------------------------------------
-- Prompt name -> the panel it opens. Matched anywhere in the world, so neither
-- the shop nor the terminal has to tell this file where it is standing.
local WORLD_PROMPTS = {
	ShopPrompt = "Store",     -- StoreBuilder mounts it on the counter
	IndexPrompt = "Index",    -- authored on Beach.IndexTerminal.PromptAnchor
}
local WALK_AWAY = 26          -- studs, well outside the prompts' own 12 and 14

local walkToken = 0

-- Walking away from a counter should shut what it opened, and a prompt has no
-- "left range" event to hang that on. The token makes the poll self-cancelling:
-- a second visit starts a new one, and the old loop sees a stale token and
-- stops. ONE token serves both prompts, which is right rather than merely tidy
-- -- openPanel shuts everything else on the way up, so there is only ever one
-- panel to walk away from.
local function watchWalkAway(anchor: BasePart, panel: string)
	walkToken += 1
	local mine = walkToken
	task.spawn(function()
		while walkToken == mine and openName == panel do
			task.wait(0.25)
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if not hrp or (hrp.Position - anchor.Position).Magnitude > WALK_AWAY then
				MenuHud.close()
				break
			end
		end
	end)
end

local function wireWorldPrompts()
	ProximityPromptService.PromptTriggered:Connect(function(prompt, plr)
		local panel = WORLD_PROMPTS[prompt.Name]
		if plr ~= player or not panel then
			return
		end
		local anchor = prompt.Parent

		if panel == "Store" then
			-- Retitled from the prompt, BEFORE it opens: the same panel is now
			-- the beach shop and the desert outfitters, and a header reading
			-- BEACH SHOP while the player stands in the dunes is exactly the
			-- kind of seam that makes a second location feel bolted on. Falls
			-- back to the authored title if a prompt ever ships without
			-- ObjectText.
			local store = panels.Store
			if store and store.setTitle then
				local named = prompt.ObjectText
				store.setTitle((named ~= nil and named ~= "") and named or "Beach Shop")
			end
		end

		openPanel(panel)            -- toggles, the same way a rail button did
		if openName == panel and anchor and anchor:IsA("BasePart") then
			watchWalkAway(anchor, panel)
		end
	end)
end

--------------------------------------------------------------------------
-- STOCK LIST  --  what the shop sells
--------------------------------------------------------------------------
-- Roblox's font has NO fallback for newer emoji: a missing one renders as a
-- narrow box rather than failing loudly. Measure before shipping a new glyph --
-- a real colour emoji reports TextBounds.X ~= 35 at TextSize 38, a fallback
-- reports ~19, the same width as ">". U+1FAA3 bucket and the heavy arrow both
-- failed that test and were replaced.
local TRACK_EMOJI = {
	RollerWidth = "🧹", Pressure = "💪", BucketSize = "📦",
	BeachLegs = "👟",
	-- The car ladder's keys share this table. They cannot collide: one is keyed
	-- off ProgressionConfig.Tracks and the other off AtvConfig.Upgrades, and
	-- both are looked up by the same `track.key`.
	Rake = "🚜",
	--[[
		MEASURED, THE WAY THE NOTE ABOVE SAYS TO, before either of these shipped.
		At TextSize 38 in GothamBold, against ">" as the narrow-box reference and
		the tractor above as a glyph known to render:

			>                 11.0    the fallback box
			tractor (ships)   20.5    real
			cyclone           20.5    real
			basket            20.5    real
			wheel  U+1F6DE    11.0    FALLBACK -- the obvious pick for a steering
			pickup U+1F6FB    11.0    FALLBACK    rack, and it would have shipped
			                                     as an empty box.

		The absolute widths are lower than the 35/19 pair the note above quotes --
		that was taken at a different scale -- but the test is a COMPARISON against
		a glyph you can see working, and on that the answer is unambiguous.
	]]
	Steering = "🌀",
	Bed = "🧺",
}
local rows = {}
-- The Car tab's rows, kept apart from `rows` rather than merged into it. The two
-- ladders arrive in two different halves of the snapshot and are painted by two
-- different rules; one table keyed by track key would work only for as long as
-- no car track is ever named the same as a foot track.
local carRows = {}

-- Row geometry. Named because the scroll region below and the four widgets
-- inside a row all have to agree, and 92 is not obviously "78 plus a progress
-- bar" unless it says so somewhere.
-- 640 rather than 600: the tab strip below costs 48px of body and the rows must
-- not lose one for it -- four foot tracks at ROW_H is what this panel was sized
-- to show without scrolling, and a shop that scrolls on its first screen reads
-- as a shop with something hidden in it.
--[[
	730 WIDE, UP FROM 640, AND THE NUMBER IS DERIVED RATHER THAN CHOSEN.

	Every stock row carries a second buy button now -- the Robux one, see QUICK_W
	below -- which costs 104px down the right-hand edge. Ninety of that is this
	widening and the rest is air that was already there, so THE TEXT COLUMN COMES
	OUT AT EXACTLY THE 342px IT MEASURED BEFORE. Nothing that fitted stops fitting.

	That was worth solving properly rather than by eye. At 700 the column came out
	at 312 and the Beach Rake's blurb -- 327px at GothamMedium 13, the longest
	string either page draws -- truncated to "A towed sifter bar, far wider than
	the machine that...", which is a sentence cut off mid-clause on the most
	expensive row in the game.

	HEIGHT IS THE AXIS WITH NO ROOM and is untouched -- see the Settings panel's
	note about 600 being the proven ceiling. Width has plenty: measured against
	UiFit's 0.6 floor, the card renders at 438px and the banner (w + 34) at 458,
	inside the ~685 a landscape phone gives. Check that again before it grows
	further; the banner, not the card, is the thing that runs out of room first.
]]
local SHOP_W, SHOP_H = 730, 640
local ROW_H = 92
local ROW_GAP = 10

--[[
	TWO TABS, BECAUSE THERE ARE TWO LADDERS BEHIND THIS COUNTER.

	UPGRADES is what you buy for yourself: four tracks, capped by the tide, and
	gone again at the next rebirth. CAR is what you buy for the machine: it
	starts where the walker's own Sifter Width ends, it has no tide cap, and it
	survives the tide -- see AtvConfig.Upgrades' header for why all three differ.

	They are not two panels because they are one counter and one purse. The strip
	is built the same way the Rewards panel's is (a chunky() per tab, retint on
	select, pre-built pages shown and hidden rather than rebuilt) so there is one
	look for a tab in this game rather than two.
]]
local SHOP_TAB_H = 40
local SHOP_TABS_Y = 48        -- under the purse strip, which is 38 tall at y=0
local SHOP_PAGE_Y = SHOP_TABS_Y + SHOP_TAB_H + 8
-- The off state, lifted from the Rewards strip rather than picked again: a
-- second grey for the same idea is how two tab strips stop matching.
local TAB_OFF = Color3.fromRGB(150, 140, 126)
-- And the locked tile's cold grey-blue, lifted from the Rewards playtime tiles
-- for the same reason. This file already has one colour that means "you cannot
-- have this yet"; a second one would only mean "a different author".
local LOCK_GREY = Color3.fromRGB(122, 134, 150)
local shopPage = "Tracks"
local shopPages, shopTabs = {}, {}

local function setShopPage(key)
	shopPage = key
	for name, frame in shopPages do
		frame.Visible = (name == key)
	end
	for name, t in shopTabs do
		local on = (name == key)
		PanelKit.retint(t.face, t.slab, on and t.tint or TAB_OFF)
		t.label.TextTransparency = on and 0 or 0.25
	end
end
--[[
	Width reserved down the right-hand edge for the level chip and the TWO buy
	buttons, so the name, blurb and stat lines know where to stop.

	Derived rather than guessed, the way PASS_RIGHT's own note insists on -- and
	for the same trap it names: these labels start at x = 78 and are sized
	`1, -ROW_RIGHT`, which is a WIDTH, so the 78 is spent again at the right-hand
	end and belongs in this number too.

	Against the 682px a row measures inside a 730-wide panel:

		14 margin + 118 coin button + 8 gap + 96 Robux button  = 236
		so the button block's left edge sits 236 from the right
		78 icon + 236 + 26 air                                  = 340

	That leaves 682 - 340 = 342px of text, which is EXACTLY what the column
	measured before the Robux button existed. SHOP_W was picked to make that come
	out even; its own note says why, and the two numbers move together.

	Measured against every string either page draws, longest first: the Beach
	Rake's blurb 327px, "Needs a machine -- buy one at the car pad." 290px, Water
	Pressure's name 172px. All inside 342, none inside 312.
]]
local ROW_RIGHT = 340
-- The two buttons and the air between them. Named because four places have to
-- agree on them: this file's ROW_RIGHT arithmetic above, and the three lines
-- that build and position the pair.
local BUY_W, QUICK_W, BUY_GAP = 118, 96, 8

--[[
	HOW MANY RUNGS ONE PRESS BUYS.  2026-09-14

	Asked for in as many words: "incremental upgrades (x5, x10, x20, etc)", from
	a rebirth-25 player. Past the early tides a track takes dozens of rungs and
	each one was its own press.

	ONE MULTIPLIER FOR THE WHOLE SHOP, not a control per row. The rows are 92px
	and already carry a tile, a name, a blurb, a stat line, a level chip, a
	ladder bar, a coin button and a Robux button; a fifth control on each would
	be the thing that finally broke them on a phone. It is also how every shop in
	the genre does it, so it needs no explaining.

	25 RATHER THAN 20, which is what was asked for. ProgressionServer's BULK_MAX
	is the number that actually binds and it is 25; offering 20 here and having
	the server allow 25 would just be two numbers to keep in step for no gain.
]]
local BULK_STEPS = { 1, 5, 10, 25 }
local bulkAt = 1   -- index into BULK_STEPS
local function bulkN(): number
	return BULK_STEPS[bulkAt] or 1
end

--[[
	WHAT N RUNGS OF ONE TRACK WILL COST FROM WHERE IT STANDS.

	SUMMED, NOT MULTIPLIED, because the ladder is a curve: cost(level) is
	base * CostGrowth^(level-1) with CostGrowth 1.24, so ten rungs is a little
	under eight times the next one rather than ten times it. Multiplying would
	understate every bulk buy in the shop by about a fifth, which is the one
	genuinely misleading way to draw this.

	STOPS WHERE THE SERVER STOPS -- at the tide ceiling, and at the end of the
	ladder when costFor answers nil. It returns how many rungs it actually priced
	as well, so a x25 pressed three rungs below the cap totals three.

	ADVISORY, like every other figure this panel draws. ProgressionServer's onBuy
	re-derives the level, the price and the ceiling for every rung as it buys and
	stops on the first refusal, so nothing here decides anything -- it only has
	to agree with what is about to happen.
]]
local function bulkPrice(track, level: number, ceiling: number, n: number): (number, number)
	local total, rungs = 0, 0
	local at = tonumber(level) or 1
	local cap = tonumber(ceiling) or math.huge
	for k = 0, math.max(1, n) - 1 do
		if (at + k) >= cap then
			break
		end
		local c = Config.costFor(track, at + k)
		if not c then
			break
		end
		total += c
		rungs += 1
	end
	return total, rungs
end

local function buildShop()
	local root, body, _, setTitle = makePanel("Beach Shop", SHOP_W, SHOP_H, C.sun)
	-- Kept so wireWorldPrompts can retitle the header per counter. It is
	-- PanelKit's SETTER rather than a label, because the title is TWO stacked
	-- labels -- a white one over an ink shadow three pixels low. This used to
	-- hold banner:FindFirstChildOfClass("TextLabel"), which is the SHADOW (built
	-- first), so at every counter but the beach that counter's name arrived as a
	-- 55%-transparent ghost behind an unchanged white "BEACH SHOP".
	panels.Store = { root = root, w = SHOP_W, h = SHOP_H, setTitle = setTitle }

	-- A shop should tell you what you can afford. As a rail panel this could
	-- lean on the coin counter across the screen; standing at a counter with the
	-- panel filling the middle of it, that reads as the wrong half of a till.
	local purse = Instance.new("Frame")
	purse.Name = "Purse"
	purse.Size = UDim2.new(1, 0, 0, 38)
	purse.BackgroundColor3 = C.white
	purse.BorderSizePixel = 0
	purse.Parent = body
	corner(purse, 14)
	outline(purse, 3.5)
	grad(purse, C.white, C.sand)

	local purseLabel = text(purse, "IN YOUR POCKET", 14, Enum.Font.LuckiestGuy,
		Color3.fromRGB(132, 108, 82))
	purseLabel.Position = UDim2.fromOffset(14, 0)
	purseLabel.Size = UDim2.new(0.5, -14, 1, 0)
	purseLabel.TextXAlignment = Enum.TextXAlignment.Left

	--[[
		THE MULTIPLIER LIVES ON THE PURSE ROW, and it belongs there rather than on
		each row: what it changes is how much of your money one press spends, which
		is the same question the row it sits on already answers.

		MEASURED to fit the 730-wide panel: "IN YOUR POCKET" is 106px at the left,
		the largest balance this game can show ("$1,185,131,541") is 123px, and the
		four pills come to 140 -- so the amount is pulled left to clear them rather
		than being left to collide at the one balance nobody tests with.
	]]
	local bulkBox = Instance.new("Frame")
	bulkBox.Name = "Bulk"
	bulkBox.AnchorPoint = Vector2.new(1, 0.5)
	bulkBox.Position = UDim2.new(1, -14, 0.5, 0)
	bulkBox.Size = UDim2.fromOffset(140, 26)
	bulkBox.BackgroundTransparency = 1
	bulkBox.Parent = purse
	local bulkLay = Instance.new("UIListLayout")
	bulkLay.FillDirection = Enum.FillDirection.Horizontal
	bulkLay.VerticalAlignment = Enum.VerticalAlignment.Center
	bulkLay.Padding = UDim.new(0, 4)
	bulkLay.SortOrder = Enum.SortOrder.LayoutOrder
	bulkLay.Parent = bulkBox

	local bulkPills = {}
	local function paintBulk()
		for i, p in ipairs(bulkPills) do
			local on = (i == bulkAt)
			p.BackgroundColor3 = on and C.limeDark or C.white
			p.TextColor3 = on and C.white or Color3.fromRGB(132, 108, 82)
			local st = p:FindFirstChildWhichIsA("UIStroke")
			if st then
				st.Color = on and C.limeDark or Color3.fromRGB(196, 172, 140)
			end
		end
	end

	for i, n in ipairs(BULK_STEPS) do
		local pill = Instance.new("TextButton")
		pill.Name = "x" .. n
		pill.LayoutOrder = i
		pill.Size = UDim2.fromOffset(32, 26)
		pill.AutoButtonColor = false
		pill.BorderSizePixel = 0
		pill.Text = "x" .. n
		pill.Font = Enum.Font.LuckiestGuy
		pill.TextSize = 14
		pill.Parent = bulkBox
		corner(pill, 9)
		outline(pill, 2.5)
		bulkPills[i] = pill
		TouchFit.press(pill, function()
			bulkAt = i
			paintBulk()
			-- Every row's price and colour is a function of the multiplier, so the
			-- whole list is repainted rather than each pill knowing about rows.
			if panels.Store and panels.Store.refresh then
				panels.Store.refresh()
			end
		end)
	end
	paintBulk()

	local purseAmt = text(purse, "$0", 21, Enum.Font.LuckiestGuy, C.limeDark)
	purseAmt.Name = "Coins"
	purseAmt.AnchorPoint = Vector2.new(1, 0.5)
	-- Clear of the pills: 14 margin + 140 of pills + 12 of air.
	purseAmt.Position = UDim2.new(1, -166, 0.5, 0)
	purseAmt.Size = UDim2.new(0.5, -28, 1, 0)
	purseAmt.TextXAlignment = Enum.TextXAlignment.Right
	punch(purseAmt, 2.5)

	------------------------------------------------------------------
	-- THE TAB STRIP
	------------------------------------------------------------------
	local strip = Instance.new("Frame")
	strip.Name = "Tabs"
	strip.Position = UDim2.fromOffset(0, SHOP_TABS_Y)
	strip.Size = UDim2.new(1, 0, 0, SHOP_TAB_H)
	strip.BackgroundTransparency = 1
	strip.Parent = body
	local sl = Instance.new("UIListLayout")
	sl.FillDirection = Enum.FillDirection.Horizontal
	sl.Padding = UDim.new(0, 8)
	sl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	sl.Parent = strip

	local pageHost = Instance.new("Frame")
	pageHost.Name = "Pages"
	pageHost.Position = UDim2.fromOffset(0, SHOP_PAGE_Y)
	pageHost.Size = UDim2.new(1, 0, 1, -SHOP_PAGE_Y)
	pageHost.BackgroundTransparency = 1
	pageHost.Parent = body

	local function page(name)
		local f = Instance.new("Frame")
		f.Name = name
		f.Size = UDim2.fromScale(1, 1)
		f.BackgroundTransparency = 1
		f.Visible = false
		f.Parent = pageHost
		shopPages[name] = f
		return f
	end

	local tracksPage = page("Tracks")
	local carPage = page("Car")

	--[[
		THE CAR TAB IS ALWAYS CLICKABLE, even with nothing owned.

		A dead button teaches nothing. The lock is real -- the server refuses the
		purchase whatever this panel does -- but a player who cannot open the tab
		cannot find out what is behind it or how to get there, and "there is a
		greyed tab and I don't know why" is the same defect the Store's own
		TIDE CAP copy exists to avoid. So the tab opens and the PAGE says why.
	]]
	for i, t in ipairs({
		{ key = "Tracks", label = "UPGRADES", tint = C.sun },
		{ key = "Car", label = "CAR", tint = C.coral },
	}) do
		local holder, face, slab = chunky(strip, 200, SHOP_TAB_H - 2, t.tint, 12)
		holder.LayoutOrder = i
		local l = text(face, t.label, 17, Enum.Font.LuckiestGuy, C.white)
		l.Size = UDim2.fromScale(1, 1)
		l.ZIndex = 6
		punch(l, 2.5)
		shopTabs[t.key] = { face = face, slab = slab, label = l, tint = t.tint }
		TouchFit.press(face, function()
			setShopPage(t.key)
			if panels.Store.refresh then
				panels.Store.refresh()
			end
		end)
	end

	--[[
		A SCROLLING LIST, and it stays one now that it no longer has to be.

		Four rows of ROW_H 92 is 368px, 408 counting a gap under each, and the
		body has room for that -- the plain Frame with a UIListLayout this
		started as would do the job again today.

		It stays a ScrollingFrame because the fixed one nearly went wrong. The
		shop carried eight tracks for a while -- Beachcomber Reach, Haggling,
		Prospector's Eye and Lucky Charm have since been cut -- which is 816px of
		rows in the same body. A fixed frame does not clip or complain about
		that: it draws the overflow past the bottom edge of the card, where a row
		is not merely ugly but UNCLICKABLE, and the most expensive upgrades in
		the game would have been unbuyable with nothing on screen to say why.
		Scrolling costs nothing at four rows, and it is what stops a fifth track
		ever ending up out there.

		AutomaticCanvasSize rather than a computed CanvasSize, matching the Index
		panel further down this file: the row count is a property of
		ProgressionConfig.Tracks, and adding a fifth track should not require
		anybody to remember there is an arithmetic expression in here to update.
	]]
	-- One recipe, both pages. The Car tab's rows are the same object as the
	-- Upgrades tab's -- same anatomy, same widths, same buy button -- and two
	-- hand-built lists would be two places for a row to stop matching.
	local function stockList(parent, y)
		local list = Instance.new("ScrollingFrame")
		list.Name = "Rows"
		list.Position = UDim2.fromOffset(0, y or 0)
		list.Size = UDim2.new(1, 0, 1, -(y or 0))
		list.BackgroundTransparency = 1
		list.BorderSizePixel = 0
		list.ScrollBarThickness = 8
		list.ScrollBarImageColor3 = C.wood
		list.CanvasSize = UDim2.new()
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		list.ScrollingDirection = Enum.ScrollingDirection.Y
		list.Parent = parent
		local ly = Instance.new("UIListLayout")
		ly.Padding = UDim.new(0, ROW_GAP)
		ly.SortOrder = Enum.SortOrder.LayoutOrder
		ly.Parent = list
		-- Clear of the scrollbar, and a little air at the foot of the list so the
		-- last row is not flush against the bottom edge of the card it sits in.
		local listPad = Instance.new("UIPadding")
		listPad.PaddingRight = UDim.new(0, 12)
		listPad.PaddingBottom = UDim.new(0, 6)
		listPad.Parent = list
		return list
	end

	local list = stockList(tracksPage, 0)

	------------------------------------------------------------------
	-- THE CAR PAGE'S HEADER PLATE  --  which machine, and what it rakes
	------------------------------------------------------------------
	--[[
		A row of stock on its own does not explain this ladder. Two things have to
		be said before the price makes any sense, and neither of them fits on a
		stock row: WHICH machine this is being fitted to, and that the first rung
		already beats a Sifter Width track bought all the way to sixty.

		It is also where the lock lives. Locked, this plate is the whole answer to
		"why can I not buy anything" -- and it names the pad, because "you need a
		vehicle" without saying where they are sold is half an answer.
	]]
	-- 96, up from 82: the sub-line carries two sentences now rather than one --
	-- what the rake is for, and what the player's foot tracks are already worth on
	-- the machine. Three wrapped lines at 13pt instead of two. The car page had the
	-- room; the list below simply starts lower.
	local MACHINE_H = 96
	local machine = Instance.new("Frame")
	machine.Name = "Machine"
	machine.Size = UDim2.new(1, -12, 0, MACHINE_H)
	machine.BackgroundColor3 = C.white
	machine.BorderSizePixel = 0
	machine.Parent = carPage
	corner(machine, 18)
	outline(machine, 3.5)
	grad(machine, C.white, C.sand)

	local mTile = Instance.new("Frame")
	mTile.Name = "Tile"
	mTile.Size = UDim2.fromOffset(58, 58)
	mTile.Position = UDim2.fromOffset(10, 12)
	mTile.BackgroundColor3 = C.sun
	mTile.BorderSizePixel = 0
	mTile.Parent = machine
	corner(mTile, 16)
	outline(mTile, 3.5)
	gloss(mTile, 16)
	local mEmoji = text(mTile, "🚜", 30, Enum.Font.GothamBold, C.white)
	mEmoji.Name = "Emoji"
	mEmoji.Size = UDim2.fromScale(1, 1)
	mEmoji.ZIndex = 6

	local mKicker = text(machine, "YOUR MACHINE", 13, Enum.Font.LuckiestGuy,
		Color3.fromRGB(132, 108, 82))
	mKicker.Name = "Kicker"
	mKicker.Position = UDim2.fromOffset(78, 10)
	mKicker.Size = UDim2.new(1, -92, 0, 16)
	mKicker.TextXAlignment = Enum.TextXAlignment.Left

	local mName = text(machine, "", 21, Enum.Font.LuckiestGuy, C.ink)
	mName.Name = "Name"
	mName.Position = UDim2.fromOffset(78, 27)
	mName.Size = UDim2.new(1, -92, 0, 24)
	mName.TextXAlignment = Enum.TextXAlignment.Left

	local mSub = text(machine, "", 13, Enum.Font.GothamMedium,
		Color3.fromRGB(132, 108, 82))
	mSub.Name = "Sub"
	mSub.Position = UDim2.fromOffset(78, 51)
	mSub.Size = UDim2.new(1, -92, 0, 44)
	mSub.TextXAlignment = Enum.TextXAlignment.Left
	mSub.TextYAlignment = Enum.TextYAlignment.Top
	mSub.TextWrapped = true

	local carList = stockList(carPage, MACHINE_H + ROW_GAP)

	--[[
		BOTH LADDERS THROUGH ONE LOOP.

		The row anatomy below -- tile, name, blurb, stat line, level chip, ladder
		bar, buy button -- is identical for a foot track and a car track, and the
		only things that differ are which list it lands in, which table remembers
		it, and which remote its button fires. Those are the three fields of
		`spec`. Copying the hundred lines instead would have been a hundred lines
		that could drift.
	]]
	-- `ladder` is the fourth field, and it exists for the Robux button: one remote
	-- serves both ladders (there is one Robux price for every rung in the game),
	-- so the payload has to say which set of refusals applies. Net's note on
	-- QuickUpgrade argues why that is safe here and not for the coin remotes.
	for _, spec in {
		{ tracks = Config.Tracks, into = list, store = rows,
			remote = "BuyUpgrade", ladder = "foot" },
		{ tracks = AtvConfig.Upgrades, into = carList, store = carRows,
			remote = "BuyCarUpgrade", ladder = "car" },
	} do
	for i, track in spec.tracks do
		local row = Instance.new("Frame")
		row.Name = track.key
		row.Size = UDim2.new(1, 0, 0, ROW_H)
		row.BackgroundColor3 = C.white
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		row.Parent = spec.into
		corner(row, 18)
		-- Captured for the tutorial's glow below; every other row ignores it.
		local rowStroke = outline(row, 3.5)
		grad(row, C.white, C.sand)

		-- icon tile
		local tile = Instance.new("Frame")
		tile.Size = UDim2.fromOffset(58, 58)
		tile.Position = UDim2.fromOffset(10, 10)
		tile.BackgroundColor3 = track.tint
		tile.BorderSizePixel = 0
		tile.Parent = row
		corner(tile, 16)
		outline(tile, 3.5)
		grad(tile, track.tint:Lerp(C.white, 0.3), darken(track.tint, 0.2))
		gloss(tile, 16)

		local slot = Instance.new("ImageLabel")
		slot.Name = "IconSlot"
		slot.BackgroundTransparency = 1
		slot.Size = UDim2.fromScale(0.76, 0.76)
		slot.AnchorPoint = Vector2.new(0.5, 0.5)
		slot.Position = UDim2.fromScale(0.5, 0.5)
		slot.Image = ""
		slot.Visible = false
		slot.ZIndex = 6
		slot.Parent = tile

		local em = text(tile, TRACK_EMOJI[track.key] or "⭐", 30, Enum.Font.GothamBold, C.white)
		em.Size = UDim2.fromScale(1, 1)
		em.ZIndex = 6

		local nm = text(row, track.name, 21, Enum.Font.LuckiestGuy, C.ink)
		nm.Position = UDim2.fromOffset(78, 8)
		nm.Size = UDim2.new(1, -ROW_RIGHT, 0, 24)
		nm.TextXAlignment = Enum.TextXAlignment.Left

		local bl = text(row, track.blurb, 13, Enum.Font.GothamMedium, Color3.fromRGB(132, 108, 82))
		bl.Position = UDim2.fromOffset(78, 32)
		bl.Size = UDim2.new(1, -ROW_RIGHT, 0, 17)
		bl.TextXAlignment = Enum.TextXAlignment.Left

		local st = text(row, "", 15, Enum.Font.GothamBold, C.seaDark)
		st.Name = "Stat"
		st.Position = UDim2.fromOffset(78, 52)
		st.Size = UDim2.new(1, -ROW_RIGHT, 0, 18)
		st.TextXAlignment = Enum.TextXAlignment.Left

		--[[
			A CHIP AND A BAR, WHERE SIXTY PIPS USED TO BE.

			The old row drew one 12px dot per level, laid out horizontally at
			`Config.MaxLevel * 16` wide. That was 96px for six levels and reads
			beautifully. At sixty levels it is 960 pixels -- half again as wide as
			the whole panel -- so it would have run straight off the card and taken
			the buy button's corner with it.

			Pips were also the wrong shape of information once the ladder got long.
			Nobody counts to 41. The two things a player actually wants off this
			row are "what level am I" and "how much of this tide's allowance have I
			used", which is a number and a bar.

			THE BAR IS SCALED TO THE CEILING, NOT TO MaxLevel. At three rebirths
			the cap is 17 of 60, and a bar that sat one quarter full at the moment
			the track stopped being buyable would read as "you have barely started"
			at exactly the moment the correct message is "you are done until you
			rebirth". Against the ceiling it fills completely, which is the truth.
		]]
		local chip = Instance.new("Frame")
		chip.Name = "LevelChip"
		chip.AnchorPoint = Vector2.new(1, 0)
		chip.Position = UDim2.new(1, -14, 0, 10)
		chip.Size = UDim2.fromOffset(118, 24)
		chip.BackgroundColor3 = track.tint
		chip.BorderSizePixel = 0
		chip.Parent = row
		corner(chip, 12)
		outline(chip, 2.5)
		grad(chip, track.tint:Lerp(C.white, 0.28), darken(track.tint, 0.18))
		local lv = text(chip, "LV 1", 14, Enum.Font.LuckiestGuy, C.white)
		lv.Name = "Level"
		lv.Size = UDim2.fromScale(1, 1)
		lv.ZIndex = 6
		punch(lv, 2)

		local bar = Instance.new("Frame")
		bar.Name = "Ladder"
		bar.AnchorPoint = Vector2.new(1, 0)
		bar.Position = UDim2.new(1, -14, 0, 39)
		bar.Size = UDim2.fromOffset(118, 9)
		bar.BackgroundColor3 = darken(C.sandDeep, 0.2)
		bar.BorderSizePixel = 0
		bar.ClipsDescendants = true
		bar.Parent = row
		corner(bar, 5)
		outline(bar, 2)
		local barFill = Instance.new("Frame")
		barFill.Name = "Fill"
		barFill.Size = UDim2.fromScale(0, 1)
		barFill.BackgroundColor3 = track.tint
		barFill.BorderSizePixel = 0
		barFill.Parent = bar
		corner(barFill, 5)

		local holder, face = chunky(row, BUY_W, 40, C.lime, 15)
		holder.AnchorPoint = Vector2.new(1, 1)
		holder.Position = UDim2.new(1, -14, 1, -8)
		local cost = text(face, "BUY", 20, Enum.Font.LuckiestGuy, C.white)
		cost.Size = UDim2.fromScale(1, 1)
		cost.ZIndex = 6
		punch(cost, 3)
		--[[
			SHRUNK TO FIT RATHER THAN TRUNCATED, and the car ladder is what forced
			it. PanelKit.text sets TextTruncate.AtEnd, and MEASURED at LuckiestGuy
			20 in this 118px button:

				$2,740,000    99px   the dearest rung the foot ladder ever shows
				$71,800,000  110px
				$319,000,000 124px   the rake's last rung -- OVER

			So without this the most expensive purchase in the game reads
			"$319,000,0...", which is not a price. It is also the single worst
			place in the shop to be approximate, so compactNum ("$319M") is the
			wrong fix -- this file's own note says a price standing on its own
			stays exact BECAUSE the player is deciding whether to spend it.

			Capped at 20 so nothing gets BIGGER: TextScaled fills the height as
			well, and a 40px button would otherwise blow "BUY" up to double size.
			Everything at or under 118px is untouched, which is every row the
			Upgrades tab has ever drawn.
		]]
		cost.TextScaled = true
		local costFit = Instance.new("UITextSizeConstraint")
		costFit.MaxTextSize = 20
		costFit.MinTextSize = 13
		costFit.Parent = cost
		--[[
			THE SECOND BUY BUTTON  --  the same rung, paid for in Robux.

			NOT A SHORTCUT PAST ANYTHING, and the button is placed to say so: it sits
			BESIDE the coin price rather than replacing it, at the same height and
			size, so the row reads as one rung with two ways to pay. Everything that
			deadens the coin button -- the tide cap, the top of the ladder, a pass
			that supersedes the track, no machine on the car page -- hides this one
			too. See paintQuick.

			GRAPE, because that is what Robux means everywhere else in this game: the
			shop's rows, the showroom's pass buttons and the wash HUD's all use it.

			TEXT ONE STEP DOWN (16 against the coin button's 20) and a lower floor on
			the size constraint, because it is 96px rather than 118 and "R$ 1,234" is
			the widest thing it will ever have to say.
		]]
		local qHolder, qFace, qSlab = chunky(row, QUICK_W, 40, C.grape, 15)
		qHolder.AnchorPoint = Vector2.new(1, 1)
		qHolder.Position = UDim2.new(1, -(14 + BUY_W + BUY_GAP), 1, -8)
		-- BUILT HIDDEN, and paint is the only thing that ever shows it. The panel is
		-- drawn before the first snapshot arrives (the coin button sits there reading
		-- "BUY" with no price until one does), and a purple pill with NO text in it
		-- does not read as "loading" -- it reads as broken. The row simply has one
		-- button until there is something true to put on the second.
		qHolder.Visible = false
		local qCost = text(qFace, "", 16, Enum.Font.LuckiestGuy, C.white)
		qCost.Size = UDim2.fromScale(1, 1)
		qCost.ZIndex = 6
		punch(qCost, 3)
		qCost.TextScaled = true
		local qFit = Instance.new("UITextSizeConstraint")
		qFit.MaxTextSize = 16
		qFit.MinTextSize = 11
		qFit.Parent = qCost

		-- Built BEFORE both click handlers so the Robux one can read `quickLive`
		-- off it. paint sets that flag alongside the colour, which is what stops
		-- the two disagreeing -- the same guard the Robux shop's rows use, and for
		-- the same reason: chunky() has no disabled state.
		--[[
			THE STEER, BUILT WITH THE ROW AND PARKED UNTIL THE REFRESH WANTS IT.

			ON THE BUY BUTTON RATHER THAN ON THE ROW, and that is a layout decision
			rather than a taste one: these rows are laid out by a UIListLayout, which
			measures AbsoluteSize -- so a UIScale breathing on the row itself would
			shove its neighbours up and down the list twice a second. The button is
			the thing being asked for anyway.

			A STORED, CANCELLABLE TWEEN, the same shape the Rewards playtime card
			uses: an infinite reversing tween can only be stopped if you kept the
			handle. `bob` further down this file returns the UIScale instead and so
			cannot be stopped, which is why it is not what this uses.
		]]
		local pulseScale = Instance.new("UIScale")
		pulseScale.Parent = holder
		local pulse = TweenService:Create(pulseScale,
			TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Scale = 1.06 })

		local ui = {
			stat = st, cost = cost, face = face, slab = holder.Slab,
			level = lv, fill = barFill, track = track,
			quick = qHolder, quickCost = qCost, quickFace = qFace, quickSlab = qSlab,
			quickLive = false,
			-- The tutorial's steer: the row the card names breathes, the rest read
			-- LOCKED. `pulsing` is what stops refresh restarting a tween that is
			-- already running, which would snap it back to Scale 1 every time the
			-- purse changed.
			pulse = pulse, pulseScale = pulseScale, pulsing = false,
			stroke = rowStroke,
		}
		spec.store[track.key] = ui

		-- A KEY AND NOTHING ELSE, on either ladder. No level, no price -- the
		-- server looks up both for itself, so there is nothing in the payload to
		-- tamper with. Which remote is the only difference between the two, and
		-- it is deliberately not one remote with a flag: see Net's own note.
		TouchFit.press(face, function()
			-- `count` is advisory in exactly the way every other field on this wire
			-- is: ProgressionServer re-derives the level, the price and the ceiling
			-- for every rung it buys and stops the moment one is refused. See the
			-- loop in onBuy. The worst a wrong number here can do is buy fewer.
			Net.get(spec.remote):FireServer({ track = track.key, count = bulkN() })
		end)

		--[[
			AND THIS ONE BUYS NOTHING EITHER -- it ASKS.

			A key and which ladder it is on. The server re-derives the level and every
			refusal, records the intent, and fires QuickUpgradePrompt back; the dialog
			only ever opens on THAT. So this screen cannot open a Robux dialog for a
			rung the server would have refused, which is the whole point of the split.
			See ProgressionServer's QUICK UPGRADE header.

			The product id is deliberately absent from the payload: it travels the
			other way, so the client never names one.
		]]
		TouchFit.press(qFace, function()
			if not ui.quickLive then
				return
			end
			Net.get("QuickUpgrade"):FireServer({ track = track.key, ladder = spec.ladder })
		end)
	end
	end

	--[[
		THE ROBUX BUTTON'S THREE STATES, and only one of them is a purchase. They
		are the Robux shop's own three, in its own colours, so a player who has seen
		one recognises the other:

			R$ 39     grape, live. Fires QuickUpgrade, which is an ASK -- the server
			          decides whether a dialog opens at all.
			SOON      sandDeep, inert. No price has been published for the product,
			          which means Roblox has none for it. A live button here would
			          open a dialog that cannot complete.
			hidden    there is no rung to sell. Tide cap, top of the ladder, a pass
			          that supersedes the track, or no machine on the car page.

		HIDDEN RATHER THAN GREYED FOR THE THIRD ONE, which is the one departure
		from the Robux shop. The coin button beside it is already saying TIDE CAP or
		PASS or LOCKED -- that IS the answer -- and a second dead button repeating
		it in a different colour is noise. There is nothing for this button to say
		that the row is not already saying better.

		`quickLive` is set here alongside the colour, and the click handler reads
		it. chunky() has no disabled state -- the face is a TextButton whatever it
		is painted -- so the flag is what stops a SOON button opening a dialog.

		The product itself is resolved ONCE, at build: ProductConfig is static data.
		The PRICE is not -- it lands on a replicated folder some time after boot --
		which is why it is read on every paint and why buildShop repaints when that
		folder changes.
	]]
	local quickProduct = ProductConfig.live(ProductConfig.QuickUpgradeKey)
	local function paintQuick(ui, sellable: boolean)
		if not ui.quick then
			return
		end
		if not sellable then
			ui.quick.Visible = false
			ui.quickLive = false
			return
		end

		ui.quick.Visible = true
		local price = quickProduct and PassConfig.price(quickProduct.id) or nil
		if price and PassConfig.onSale(quickProduct.id) then
			ui.quickLive = true
			ui.quickCost.Text = "R$ " .. comma(price)
			PanelKit.retint(ui.quickFace, ui.quickSlab, C.grape)
		else
			ui.quickLive = false
			ui.quickCost.Text = "SOON"
			PanelKit.retint(ui.quickFace, ui.quickSlab, C.sandDeep)
		end
		-- Knocked back rather than greyed, matching the Robux shop: the face is
		-- already the wrong colour to press, and a second cue on the type is what
		-- stops SOON reading as a price you have not looked at properly.
		ui.quickCost.TextTransparency = ui.quickLive and 0 or 0.15
	end

	panels.Store.refresh = function()
		-- Above the snapshot guard on purpose: the purse is drawn from the live
		-- attribute, so it is right from the first frame the panel is open even if
		-- the progression snapshot has not landed yet. It used to read "$0" until
		-- one did.
		local coins = wallet()
		purseAmt.Text = "$" .. comma(coins)
		if not snapshot then return end
		for _, t in snapshot.tracks do
			local ui = rows[t.key]
			if ui then
				local tr = ui.track
				local ceiling = t.ceiling or Config.MaxLevel
				if t.passMaxed then
					--[[
						FINISHED BY A GAME PASS -- a THIRD dead end, and it is not
						either of the two below.

						Instant Wash removes the wash timer outright, so Water
						Pressure has nothing left to improve for a holder. Saying
						"MAXED" would be a lie about the ladder (they are still on
						level 1 of it) and "TIDE CAP" would be a lie about why. So
						the row says what actually happened: the pass covers it.

						Grape rather than sandDeep, because those two dead ends are
						something the player ran into and this one is something they
						BOUGHT. It is the colour the wash HUD's pass button and the
						showroom's Robux buttons already use, so "this is the game
						pass" means one thing everywhere.
					]]
					ui.stat.Text = t.passNote or (t.passMaxed .. " covers this")
					ui.cost.Text = "PASS"
					PanelKit.retint(ui.face, ui.slab, C.grape)
				elseif t.maxed then
					-- "maxed" covers two different dead ends and they are not the
					-- same news. A track at MaxLevel is finished for good; a track
					-- stopped at this tide's ceiling is finished only until the
					-- player rebirths -- and at zero rebirths that ceiling is 8 of
					-- 60, so it is the one players actually hit. Saying just MAXED
					-- there reads as a bug: they have the coins, the bar is full,
					-- and nothing happens.
					local tideCapped = ceiling < Config.MaxLevel
					ui.stat.Text = tideCapped
						and string.format("%s%s — capped until you rebirth", fmt(t.value, tr), tr.suffix)
						or string.format("%s%s — MAXED", fmt(t.value, tr), tr.suffix)
					ui.cost.Text = tideCapped and "TIDE CAP" or "MAX"
					--[[
						retint, NOT BackgroundColor3, and the difference is visible.

						chunky() paints a UIGradient on the face from the colour the
						button was BUILT with -- lime. A UIGradient MULTIPLIES, so
						setting only the background left every dead button in this
						shop still washed green, and every unaffordable one muddy
						rather than coral. PanelKit.retint repaints the gradient and
						darkens the slab by the same 0.45 this code already used, so
						it is a straight swap. It is the same fix DriveHud's header
						records making for the same reason, and what AtvClient's
						LOCKED bay has always done.

						Found with the Car tab, which is where it hurt: LOCKED is
						what every player without a machine sees, and a green button
						saying LOCKED is one they will click.
					]]
					PanelKit.retint(ui.face, ui.slab, C.sandDeep)
				else
					ui.stat.Text = string.format("%s%s  >  %s%s",
						fmt(t.value, tr), tr.suffix, fmt(t.nextValue, tr), tr.suffix)
					--[[
						THE PRICE OF WHAT THE BUTTON WILL ACTUALLY BUY.

						Showing the NEXT rung's price beside a button reading "x10"
						would be the one genuinely misleading way to do this -- it
						reads as ten for that price, and the curve climbs 1.24x a
						level, so ten is nearer eight times it. So the row totals
						what it is about to spend.

						ADVISORY, and deliberately so: the server buys rung by rung
						and re-reads the ceiling and the balance each time, so this
						number never decides anything. It only has to not lie.
					]]
					-- The button's only text IS this price (see the note by `cost` in
					-- the row builder -- there is no separate BUY label to put an "x10"
					-- on, and the 118px box is already measured to the last pixel). The
					-- multiplier is stated once, on the selector above the list.
					local total = bulkPrice(tr, t.level, ceiling, bulkN())
					ui.cost.Text = "$" .. comma(total)
					PanelKit.retint(ui.face, ui.slab, (coins >= total) and C.lime or C.coral)
				end
				-- The Robux button follows the coin button's fate exactly: there is
				-- either a rung for sale on this row or there is not, and no amount of
				-- money changes which. See ProgressionServer, which refuses the same
				-- three cases server-side.
				paintQuick(ui, not (t.passMaxed or t.maxed))

				--[[
					THE TUTORIAL'S ONE-ROW SHOP.

					While the card is still asking for its named track, that row
					breathes and the other three wear the Car tab's LOCKED look --
					dead button, the reason on the stat line, ladder bar knocked back.

					LAST, SO IT OVERRIDES. Every branch above has already painted this
					row for affordability or for a pass; a lock that ran before them
					would be repainted lime the moment the player could afford the row
					it is refusing.

					A PICTURE, NOT THE RULE. chunky() has no disabled state, so the grey
					face is still a live button -- deliberately: a player who presses it
					gets ProgressionServer's refusal toast, which is the sentence that
					explains the lock. Swallowing the press in silence would read as a
					broken shop instead of a closed one.
				]]
				local firstKey = TutorialConfig.FirstTrack
				local locked = TutorialConfig.locksOtherTracks(player,
					player:GetAttribute(Config.AttrPrefix .. firstKey))
				if locked and t.key ~= firstKey then
					local first = Config.TrackByKey[firstKey]
					ui.stat.Text = "Locked \u{2014} buy " .. ((first and first.name) or firstKey) .. " first."
					ui.cost.Text = "LOCKED"
					PanelKit.retint(ui.face, ui.slab, C.sandDeep)
					paintQuick(ui, false)
					ui.fill.BackgroundColor3 = C.sandDeep
				end

				-- FOLDED INTO THE CONDITION rather than guarding the Play, so the
				-- existing state machine does the work: when the setting changes,
				-- `wantPulse` flips, stops matching `ui.pulsing`, and the else branch
				-- below cancels and squares the scale exactly as it always has. A
				-- guard on the Play alone would never stop a pulse already running.
				-- The row is still marked as the one to buy: locked, tinted, named.
				local wantPulse = locked and t.key == firstKey and not Motion.reduced()
				if wantPulse ~= ui.pulsing then
					ui.pulsing = wantPulse
					if wantPulse then
						ui.pulse:Play()
					else
						ui.pulse:Cancel()
						ui.pulseScale.Scale = 1
					end
				end
				--[[
					AND THE GLOW, WHICH IS THE "NOW" TO THE PULSE'S "HERE".

					The pulse marks the row the card is asking for and runs from the
					moment the shop opens. The glow is the Rewards board's ready
					stroke -- sun, 5.5 -- and it comes on only when the purse can
					actually pay, because "time to upgrade" is a fact about the
					money, not the row. Driven on every repaint rather than latched:
					the purse moves between snapshots, and Coins is already wired to
					refreshOpenPanels. Rested back to the outline's own ink whenever
					it is not the tutorial's moment, so past the onboarding this is
					four dead property writes and nothing else.
				]]
				if ui.stroke then
					local glow = wantPulse and coins >= t.cost
					ui.stroke.Color = glow and C.sun or C.ink
					ui.stroke.Thickness = glow and 5.5 or 3.5
				end
				--[[
					BOTH NUMBERS, because they answer different questions and the
					second one is the one that gets misread.

					"LV 12 / 17"  -- 17 is THIS TIDE'S cap, and it is what the
					                 bar below is scaled to
					"LV 60 MAX"   -- the ladder itself is finished

					The ceiling is drawn in preference to MaxLevel deliberately. A
					player at 12 of a 60-rung ladder with 17 rungs unlocked needs to
					know about the 17; the 60 is a fact about the game, not about
					anything they can do this run.
				]]
				if t.passMaxed then
					-- The player's real level is deliberately not printed here.
					-- Nothing wrote it -- the pass changes what the jet does, not
					-- what they own -- so it is almost always LV 1, and "LV 1 / 17"
					-- beside a row saying PASS reads as the pass having failed.
					-- Full bar in the track's own colour: what finished looks like
					-- everywhere else in this panel.
					ui.level.Text = "LV MAX"
					ui.fill.Size = UDim2.fromScale(1, 1)
					ui.fill.BackgroundColor3 = tr.tint
				else
					ui.level.Text = (ceiling >= Config.MaxLevel and t.level >= Config.MaxLevel)
						and string.format("LV %d MAX", t.level)
						or string.format("LV %d / %d", t.level, ceiling)
					ui.fill.Size = UDim2.fromScale(math.clamp(t.level / math.max(ceiling, 1), 0, 1), 1)
					-- Full-and-stuck reads differently from full-and-finished, so the
					-- bar goes muted when the tide cap is what stopped it and keeps the
					-- track's own colour when the ladder is genuinely done.
					ui.fill.BackgroundColor3 = (t.maxed and ceiling < Config.MaxLevel)
						and C.sandDeep or tr.tint
				end
			end
		end

		--------------------------------------------------------------
		-- THE CAR PAGE
		--------------------------------------------------------------
		--[[
			PAINTED EVEN WHILE THE CAR PAGE IS HIDDEN, deliberately. It is a handful
			of text writes against a page the player can flip to in one click, and a
			tab that arrived a frame stale -- showing a price already paid, or
			LOCKED on a machine just bought -- would be worse than the work saved.
			The Index's detail card is the thing kept off refresh, and that is
			because it rebuilds instances; nothing here does.
		]]
		local car = snapshot.car
		if not car then
			return
		end

		if car.owned then
			mKicker.Text = "YOUR MACHINE"
			mName.Text = string.upper(car.machine or "MACHINE")
			-- The pitch, and it is the whole reason this tab exists: it says what
			-- the foot ladder tops out at, so the first rung's price has something
			-- to be measured against. Read off the snapshot rather than typed here,
			-- so retuning Sifter Width retunes this sentence with it.
			local pitch = string.format(
				"Sifter Width bought to level %d reaches %.1f studs on foot. Everything on this tab starts past it.",
				Config.MaxLevel, tonumber(car.floor) or 48.5)

			--[[
				AND A SECOND SENTENCE, WHICH IS THE ANSWER TO A PLAYER REQUEST.
				2026-09-18.

				Asked for as "ooo and more vehicle upgrades! speed/capacity/turning
				radius, etc." by a rebirth-29 player who was sitting on Beach Legs 40
				and Bucket Size 40 -- two tracks ALREADY carrying their machine's speed
				and bed, thirteen rungs below their own tide ceiling, with nothing
				anywhere on this tab saying so. Two of the three things they asked for
				were already buyable and they had no way to know it.

				The showroom does say it -- AtvClient draws "Your gear lifts its speed,
				hold" under a bay -- but that is a different panel, reached from the car
				pad, and it only appears on a machine you have not bought yet. The place
				the rungs are actually sold said nothing at all.

				LIVE NUMBERS RATHER THAN A CLAIM. "Beach Legs carries onto your machine"
				is a sentence a player has no reason to believe. "66 speed and 2,679 lbs
				here" is the machine's own readout, and it moves the next time they buy a
				rung -- which is the thing worth learning.

				BOTH NAMES COME OFF THE CONFIG, through the same Transfers table
				effectiveStats uses, so a renamed or re-pointed track cannot leave this
				sentence quietly wrong.
			]]
			local lift = car.lift
			if type(lift) == "table" then
				local function trackName(key: string?, fallback: string): string
					local t = key and Config.TrackByKey and Config.TrackByKey[key]
					return (t and t.name) or fallback
				end
				local legs = trackName(AtvConfig.Transfers.speed, "Beach Legs")
				local bucket = trackName(AtvConfig.Transfers.hold, "Bucket Size")
				local ownSpeed = tonumber(lift.ownSpeed) or 0
				local ownHold = tonumber(lift.ownHold) or 0
				local gotSpeed = (tonumber(lift.speed) or 0) > ownSpeed
				local gotHold = (tonumber(lift.hold) or 0) > ownHold

				if gotSpeed and gotHold then
					pitch ..= string.format(
						"  %s and %s ride along too \u{2014} %d speed and %s lbs on this machine.",
						legs, bucket, math.floor(lift.speed + 0.5), comma(lift.hold))
				elseif gotSpeed or gotHold then
					-- One has passed the machine and the other has not. Naming only the
					-- one that is live keeps the number honest, and the other track is a
					-- row on the Upgrades tab either way.
					pitch ..= string.format("  %s rides along too \u{2014} %s on this machine.",
						gotSpeed and legs or bucket,
						gotSpeed and string.format("%d speed", math.floor(lift.speed + 0.5))
							or string.format("%s lbs", comma(lift.hold)))
				else
					-- Neither has caught the machine yet, which is where a player who has
					-- just bought their first one stands. Still worth saying: it is the
					-- reason to go back to the other tab.
					pitch ..= string.format(
						"  %s and %s ride along too, once they pass %d speed and %s lbs.",
						legs, bucket, math.floor(ownSpeed + 0.5), comma(ownHold))
				end
			end
			mSub.Text = pitch
			mEmoji.Text = "\u{1F69C}"
			PanelKit.retint(mTile, nil, C.sun)
		else
			mKicker.Text = "LOCKED"
			mName.Text = "NO MACHINE"
			-- Names the pad. "You need a vehicle" without saying where they are sold
			-- is half an answer, and for most players this tab is the first time
			-- anything has told them the car pad sells something.
			mSub.Text = "Buy a bulldozer or a sweeper truck at the car pad along the beach, "
				.. "then come back and kit it out."
			mEmoji.Text = "\u{1F512}"
			PanelKit.retint(mTile, nil, LOCK_GREY)
		end

		--[[
			"+0.25 turn" FOR AN ADDITIVE TRACK, "62.5 studs" FOR THE RAKE.

			The rake's number is the whole width the machine ends up raking. The
			steering rack's and the cargo bed's are a BONUS on top of a number that
			differs per machine and per how far the player has taken Bucket Size --
			so drawn the same way, "0.25 turn" reads as the whole of a stat that is
			actually 2.85 on a Sandhog and 1.85 on a Tidebreaker.

			The TRACK says which it is (AtvConfig's `plus`), so this does not have to
			know any keys and a fourth track gets it right without touching this.
		]]
		local function carAmt(v, tr)
			return ((tr.plus and type(v) == "number" and v > 0) and "+" or "")
				.. fmt(v, tr) .. tr.suffix
		end

		for _, t in car.tracks do
			local ui = carRows[t.key]
			if ui then
				local tr = ui.track
				local ceiling = t.ceiling or AtvConfig.carCeiling(tr)
				if not car.owned then
					-- The refusal reason on the row as well as on the plate above it.
					-- The row is what carries the price, and a price with a dead
					-- button beside it is the question this line answers.
					ui.stat.Text = "Needs a machine \u{2014} buy one at the car pad."
					ui.cost.Text = "LOCKED"
					PanelKit.retint(ui.face, ui.slab, C.sandDeep)
				elseif t.maxed then
					-- ONE dead end here, not two. There is no tide cap on this ladder,
					-- so maxed means finished for good -- which is why this branch is
					-- half the size of the Upgrades tab's.
					ui.stat.Text = string.format("%s \u{2014} MAXED", carAmt(t.value, tr))
					ui.cost.Text = "MAX"
					PanelKit.retint(ui.face, ui.slab, C.sandDeep)
				else
					-- `value` is NIL at level 0, and that is the whole state rather
					-- than a missing number: nothing is bolted on yet. Printing the
					-- level-0 width would advertise a rake that is not on the machine.
					ui.stat.Text = t.value
						and string.format("%s  >  %s",
							carAmt(t.value, tr), carAmt(t.nextValue, tr))
						or string.format("Nothing fitted  >  %s",
							carAmt(t.nextValue, tr))
					ui.cost.Text = "$" .. comma(t.cost)
					PanelKit.retint(ui.face, ui.slab, (coins >= t.cost) and C.lime or C.coral)
				end
				-- Two dead ends on this page rather than the Upgrades tab's three, and
				-- LOCKED is the one that matters: a Robux button on a rake the player
				-- has nothing to bolt it to is the worst button in the shop.
				paintQuick(ui, car.owned and not t.maxed)
				ui.level.Text = (t.level >= ceiling)
					and string.format("LV %d MAX", t.level)
					or (t.level <= 0 and "NOT FITTED"
						or string.format("LV %d / %d", t.level, ceiling))
				ui.fill.Size = UDim2.fromScale(math.clamp(t.level / math.max(ceiling, 1), 0, 1), 1)
				ui.fill.BackgroundColor3 = car.owned and tr.tint or C.sandDeep
			end
		end
	end

	--[[
		THE ROBUX PRICE ARRIVES LATE AND CANNOT BE READ ONCE.

		ProductServer asks Roblox what the Quick Upgrade product costs on a thread
		at boot and publishes the answer into a replicated folder that does not
		exist during the first second of a session. Without this the Beach Shop
		would draw SOON on every row for the rest of a client's life unless a
		snapshot happened to land afterwards -- which is the exact defect the Robux
		shop's own copy of this block exists to avoid, and it is a worse one here
		because this panel is where the product is actually sold.

		WaitForChild with a timeout rather than an indefinite wait: if the folder
		never arrives the shop still works, it just goes on saying SOON, which is
		honest.
	]]
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild(PassConfig.InfoFolder, 30)
		if folder then
			folder.AttributeChanged:Connect(function()
				if panels.Store and panels.Store.refresh then
					panels.Store.refresh()
				end
			end)
			panels.Store.refresh()
		end
	end)

	-- Last, the way buildRewards does it: the pages exist by now, so this is what
	-- makes one of them visible. Without it the panel opens on two hidden pages
	-- and an unpainted strip.
	setShopPage(shopPage)
end

--------------------------------------------------------------------------
-- REBIRTH
--------------------------------------------------------------------------
local function buildRebirth()
	-- 396 rather than 430: the progress bar ends 230 into the body and the button
	-- is pinned to the bottom of it, so the old height left a sixty-pixel band of
	-- empty cream between the two with nothing to say for itself.
	-- 452 rather than 410: there are TWO gauges under the warning now, coins and
	-- litter, and the second one wants the 42px the button was sitting on.
	--[[
		BOTH NAMES, AND THE SECOND ONE IS THE SEARCH TERM.

		The feature is "Turn of the Tide" -- ProgressionConfig.Rebirth.Name, and the
		tide metaphor the whole progression is built on. But the word every player
		actually arrives here holding is REBIRTH, because that is the word the game
		uses everywhere it tells them they need one: the Dunes door reads
		"SEALED -- 1 REBIRTH", the Vault reads "Reach Rebirth 8 to enter", and a
		capped shop row reads "capped until you rebirth".

		So the game asks for a rebirth and then offers no button with that word on
		it -- the rail key is a wave sprite with no caption and this panel was titled
		in the theme alone. A player asked outright on 2026-09-09: "How do I
		rebirth?", with one rebirth already behind them, which is what makes it a
		NAMING problem rather than a tutorial one. They had done it. They could not
		find it again.

		THE THEME KEEPS TOP BILLING because it is what the panel is about and what
		every other string in here is written in; the plain word rides behind it for
		the player scanning for it.
	]]
	local root, body = makePanel("Turn of the Tide \u{2014} Rebirth", 520, 452, C.sea)
	panels.Rebirth = { root = root, w = 520, h = 452 }

	local hero = Instance.new("Frame")
	hero.Size = UDim2.new(1, 0, 0, 124)
	hero.BackgroundColor3 = C.sea
	hero.BorderSizePixel = 0
	hero.ClipsDescendants = true
	hero.Parent = body
	corner(hero, 20)
	outline(hero, 4)
	grad(hero, C.foam, C.sea)
	gloss(hero, 20)

	--[[
		THE WAVE IS DRAWN, NOT TYPED.

		This was a 40px "\u{1F30A}" in GothamBold parked in the top-left corner,
		and it rendered as a pale crescent -- Roblox's text emoji coverage is not
		the system's, and a glyph it cannot find comes back as something that
		looks like a broken icon rather than as nothing. Stranded in a corner of a
		centred layout, it read as a rendering fault on the panel.

		Two rounded bands across the bottom of the card do the same job, cannot
		fail to render, and actually belong to the box they are in.
	]]
	-- Along the BOTTOM EDGE, under the type. Set at 0.62 and 0.78 they crossed
	-- the multiplier line at exactly the height of the text and read as a
	-- strikethrough through "2.20x > 2.86x SELL BONUS" -- a decoration that
	-- looks like the number has been cancelled is worse than no decoration. The
	-- second one runs off the bottom, which is what the clip is for.
	for _, w in ipairs({ { 0.9, 0.36, 0.6 }, { 1, 0.68, 0.5 } }) do
		local swell = Instance.new("Frame")
		swell.Name = "Swell"
		swell.AnchorPoint = Vector2.new(0.5, 0.5)
		swell.Position = UDim2.fromScale(w[2], w[1])
		swell.Size = UDim2.new(0.62, 0, 0, 15)
		swell.BackgroundColor3 = C.white
		swell.BackgroundTransparency = w[3]
		swell.BorderSizePixel = 0
		swell.ZIndex = 4
		swell.Parent = hero
		corner(swell, 8)
	end

	--[[
		THE MULTIPLIER IS THE HERO, and it used to be the caption.

		"TIDE 3" was set at 36px and the sell bonus -- the entire reason anybody
		presses the button on this panel -- at 19px underneath it. That is the
		value proposition in the small print and the save-file bookkeeping in the
		headline. Swapped: the number you are buying is now the biggest thing on
		the screen and the tide count is a chip in the corner.
	]]
	local tideChip = Instance.new("Frame")
	tideChip.Name = "TideChip"
	tideChip.Position = UDim2.fromOffset(12, 11)
	tideChip.Size = UDim2.fromOffset(92, 26)
	tideChip.BackgroundColor3 = Color3.fromRGB(16, 52, 78)
	tideChip.BackgroundTransparency = 0.25
	tideChip.BorderSizePixel = 0
	tideChip.ZIndex = 6
	tideChip.Parent = hero
	corner(tideChip, 13)

	local tide = text(tideChip, "TIDE 0", 15, Enum.Font.LuckiestGuy, C.white)
	tide.Name = "Tide"
	tide.Size = UDim2.fromScale(1, 1)
	tide.ZIndex = 7
	punch(tide, 2.5)

	local mult = text(hero, "", 40, Enum.Font.LuckiestGuy, C.white)
	mult.Name = "Mult"
	mult.Position = UDim2.fromOffset(10, 40)
	mult.Size = UDim2.new(1, -20, 0, 46)
	mult.TextScaled = true
	mult.ZIndex = 6
	local multCap = Instance.new("UITextSizeConstraint")
	multCap.MaxTextSize = 40
	multCap.MinTextSize = 18
	multCap.Parent = mult
	punch(mult, 4)

	local multSub = text(hero, "SELL BONUS", 14, Enum.Font.LuckiestGuy, C.foam)
	-- 80, clear of the swells along the bottom edge of the card: at 90 the first
	-- band ran through the caption.
	multSub.Position = UDim2.fromOffset(0, 80)
	multSub.Size = UDim2.new(1, 0, 0, 20)
	multSub.ZIndex = 6
	punch(multSub, 2.5)

	--[[
		THIS SENTENCE IS THE ONLY WARNING IN THE GAME BEFORE A REBIRTH. The button
		below wires MouseButton1Click straight to DoRebirth with no confirm step,
		so anything not named here is destroyed without the player being told.

		"your machine" was added on 2026-08-24, when the tide started taking a
		coin-bought Sandhog (7,800,000) or Tidebreaker (108,000,000) with it. That
		is now the most expensive item in the list by an order of magnitude, and it
		was silent.

		The game-pass exception is deliberately not spelled out -- this is a
		one-paragraph warning, not the shop -- and it does not mislead a pass
		holder, because the Robux panel already promises them the opposite in as
		many words ("YOURS FOR GOOD -- ON EVERY DEVICE, THROUGH EVERY TIDE").
	]]
	local why = text(body, "Turning the tide washes away your coins, your finds, your machine "
		.. "and every upgrade — "
		.. "and leaves a permanent multiplier on everything you sell, plus a higher "
		-- Warm light sand, because the tray under it is dark wood now. This whole
		-- family of browns was chosen to sit on cream and is unreadable on the
		-- board -- anything drawn straight onto `body` had to come up with it.
		.. "ceiling on every track.", 15, Enum.Font.GothamMedium, Color3.fromRGB(226, 206, 176))
	why.Position = UDim2.fromOffset(6, 136)
	why.Size = UDim2.new(1, -12, 0, 72)
	why.TextWrapped = true
	why.TextYAlignment = Enum.TextYAlignment.Top

	--[[
		TWO GAUGES, BECAUSE THERE ARE TWO GATES.

		The tide asks for coins earned AND litter picked up, and the second one is
		not a footnote -- a player who cannot press the button has to be able to
		see WHICH of the two is holding them, or "NOT YET" is the whole
		explanation. Same gauge drawn twice rather than two hand-built ones, in
		different colours so they are not read as one bar that wrapped.
	]]
	-- `deep` is the foot of the gradient. Passed explicitly for the coin bar so
	-- it keeps the exact C.foam -> C.foamDark ramp it has always had; anything
	-- else takes a darkened copy of its own colour.
	local function gauge(y: number, fill: Color3, deep: Color3?)
		local bg = Instance.new("Frame")
		bg.Position = UDim2.fromOffset(6, y)
		bg.Size = UDim2.new(1, -12, 0, 32)
		bg.BackgroundColor3 = C.sandDeep
		bg.BorderSizePixel = 0
		bg.Parent = body
		corner(bg, 16)
		outline(bg, 3.5)

		local fillBar = Instance.new("Frame")
		fillBar.Name = "Bar"
		fillBar.Size = UDim2.fromScale(0, 1)
		fillBar.BackgroundColor3 = fill
		fillBar.BorderSizePixel = 0
		fillBar.Parent = bg
		corner(fillBar, 16)
		grad(fillBar, fill, deep or darken(fill, 0.3))

		local label = text(bg, "", 15, Enum.Font.LuckiestGuy, C.white)
		label.Name = "BarText"
		label.Size = UDim2.fromScale(1, 1)
		label.ZIndex = 8
		punch(label, 3)
		return bg, fillBar, label
	end

	local earnedBg, bar, bt = gauge(214, C.foam, C.foamDark)
	-- Lime rather than a second foam bar: two gates that look identical read as
	-- one bar that wrapped, and the player has to be able to see WHICH of the
	-- two is holding them.
	local trashBg, trashBar, trashText = gauge(252, C.lime)

	local holder, face = chunky(body, 330, 62, C.sun, 20)
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.new(0.5, 0, 1, 0)
	local go = text(face, "TURN THE TIDE", 26, Enum.Font.LuckiestGuy, C.white)
	go.Size = UDim2.fromScale(1, 1)
	go.ZIndex = 6
	punch(go, 3.5)
	-- Unconditional. There WAS a last-tide guard here, holding the press back
	-- from a request the server was certain to refuse; the ladder has no top any
	-- more (ProgressionConfig.Rebirth.LadderTides) so there is no doomed press
	-- left to catch. The two gates are the server's and it says its own refusals.
	TouchFit.press(face, function()
		Net.get("DoRebirth"):FireServer()
	end)

	panels.Rebirth.refresh = function()
		if not snapshot then return end
		tide.Text = "TIDE " .. snapshot.rebirths

		--[[
			THERE IS NO LAST TIDE ANY MORE, and this panel used to have a fourth
			state for one (added 2026-09-09, removed 2026-09-11 with the cap).

			It existed because at Rebirths == MaxRebirths the card went on selling a
			next tide that onRebirth would refuse: two progress bars demanding
			2,900,000,000 earned and 9,330 litter, and a button saying NOT YET, none
			of it reachable. The honest fix for that was the cap, not the fourth
			state -- with the ladder endless, every one of those numbers is a real
			goal again at every tide, and the three states below are the truth:
			on the shore, not yet, or go.
		]]
		earnedBg.Visible = true

		mult.Text = string.format("%.2fx  \u{2192}  %.2fx", snapshot.multiplier, snapshot.nextMultiplier)
		local pct = math.clamp(snapshot.totalEarned / math.max(snapshot.rebirthNeed, 1), 0, 1)
		TweenService:Create(bar, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Size = UDim2.fromScale(pct, 1) }):Play()
		-- THIS TIDE, not lifetime. `totalEarned` is the server's per-run counter
		-- now (ProgressionServer.tideEarnedOf) and it resets on every rebirth, so
		-- this bar starts each run empty and fills with work actually done in it.
		-- Said in the label, because the old lifetime number meant the bar opened
		-- most of the way full and nobody could tell what it was measuring.
		-- COMPACT, because this is the exact shape PanelKit.compact was written
		-- for: "348,291 / 1,000,000" is twenty-one characters of progress caption
		-- nobody reads digit by digit, and the bar above it already carries the
		-- proportion. The tide gate reaches 2.04B, so both halves are eight to ten
		-- figures for most of the run.
		bt.Text = string.format("%s / %s EARNED THIS TIDE",
			compactNum(snapshot.totalEarned), compactNum(snapshot.rebirthNeed))

		--[[
			THE LITTER GATE. `or 0` on both, and the bar hides itself when the need
			is zero: a snapshot from a server running an older build carries neither
			field, and an empty gauge reading "0 / 0" under a button that works
			perfectly well is worse than no gauge at all.
		]]
		local trashHave = snapshot.tideTrash or 0
		local trashNeed = snapshot.rebirthTrashNeed or 0
		trashBg.Visible = trashNeed > 0
		if trashNeed > 0 then
			local tPct = math.clamp(trashHave / trashNeed, 0, 1)
			TweenService:Create(trashBar, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Size = UDim2.fromScale(tPct, 1) }):Play()
			-- Same rule as the coin gauge above. This one stays small for longer --
			-- the litter gate tops out in the tens of thousands -- so compact leaves
			-- it alone until it is worth shortening.
			trashText.Text = string.format("%s / %s TRASH PICKED THIS TIDE",
				compactNum(trashHave), compactNum(trashNeed))
		end
		--[[
			THE SHORE IS A THIRD STATE, and it is not "NOT YET".

			ProgressionServer refuses a rebirth from the Long Shore -- see the gate
			at the top of onRebirth: the ascension teleports, and a teleport out of
			a live visit leaves the player frozen at the far end of it. The RULE is
			the server's and this does not duplicate it. Pressing still fires, and
			the server's own refusal is what says the sentence; all this does is
			stop the button claiming it is about to turn the tide.

			READ OFF THE ATTRIBUTE, NOT OFF `snapshot`. The snapshot is pushed by
			ProgressionServer and nothing pushes one when a visit begins or ends, so
			a panel opened on the beach and carried out to the shore would keep the
			face it was painted with. Hence the re-arm below, on the one fact
			(AfkConfig.Attr) that does replicate.
		]]
		local onShore = AfkConfig.plotOf(player) ~= nil
		local ok = snapshot.canRebirth and not onShore
		-- Thirteen characters, the same as "TURN THE TIDE" -- the button is sized
		-- for that string and every one of these has to live in the same 330px.
		go.Text = (onShore and "GO BACK FIRST")
			or (ok and "TURN THE TIDE" or "NOT YET")
		face.BackgroundColor3 = ok and C.sun or C.sandDeep
		holder.Slab.BackgroundColor3 = darken(ok and C.sun or C.sandDeep, 0.45)
	end

	-- Leaving for the shore and coming back are not progression events, so this
	-- is what repaints the button when one happens with the panel already open.
	player:GetAttributeChangedSignal(AfkConfig.Attr):Connect(function()
		if panels.Rebirth and panels.Rebirth.refresh then
			panels.Rebirth.refresh()
		end
	end)
end

--------------------------------------------------------------------------
-- PLACEHOLDER PANELS
--------------------------------------------------------------------------
-- `head` and `subText` default to the not-built-yet copy. A panel that IS built
-- but lives somewhere other than the rail passes its own directions instead.
local function buildSoon(name, tint, emoji, head, subText)
	local root, body = makePanel(name, 460, 300, tint)
	panels[name] = { root = root, w = 460, h = 300 }

	local tile = Instance.new("Frame")
	tile.AnchorPoint = Vector2.new(0.5, 0)
	tile.Position = UDim2.new(0.5, 0, 0, 6)
	tile.Size = UDim2.fromOffset(96, 96)
	tile.BackgroundColor3 = tint
	tile.BorderSizePixel = 0
	tile.Parent = body
	corner(tile, 26)
	outline(tile, 4)
	grad(tile, tint:Lerp(C.white, 0.3), darken(tint, 0.2))
	gloss(tile, 26)
	local em = text(tile, emoji, 46, Enum.Font.GothamBold, C.white)
	em.Size = UDim2.fromScale(1, 1)
	em.ZIndex = 6

	local t = text(body, head or "WASHING UP SOON!", 26, Enum.Font.LuckiestGuy, C.sand)
	t.Position = UDim2.fromOffset(0, 114)
	t.Size = UDim2.new(1, 0, 0, 34)
	punch(t, 3)

	-- A rule under the heading, faded out at both ends. These panels are one
	-- icon and two lines of text on a big cream field, and without something
	-- holding the two apart they read as a paragraph that lost its picture.
	local rule = Instance.new("Frame")
	rule.Name = "Rule"
	rule.AnchorPoint = Vector2.new(0.5, 0)
	rule.Position = UDim2.new(0.5, 0, 0, 152)
	rule.Size = UDim2.fromOffset(200, 4)
	-- White under the gradient: a UIGradient multiplies against the fill below
	-- it, so any other base here would drag the tint toward mud.
	rule.BackgroundColor3 = C.white
	rule.BorderSizePixel = 0
	rule.Parent = body
	corner(rule, 2)
	local rg = Instance.new("UIGradient")
	rg.Color = ColorSequence.new(tint)
	rg.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.25),
		NumberSequenceKeypoint.new(0.8, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	rg.Parent = rule

	local sub = text(body, subText or "This one is still out at sea. Check back later!", 15,
		Enum.Font.GothamMedium, Color3.fromRGB(226, 206, 176))
	sub.Position = UDim2.fromOffset(14, 168)
	sub.Size = UDim2.new(1, -28, 0, 44)
	sub.TextWrapped = true
end

--------------------------------------------------------------------------
-- SETTINGS
--------------------------------------------------------------------------
--[[
	Each setting writes a `Set_<key>` attribute on the player so any other system
	can read it, AND applies its effect immediately, so nothing depends on a
	listener existing.

	THEY ARE SAVED NOW, and this note used to say the opposite -- "personal, so
	they live entirely on the client; there is no remote here and no server
	round-trip". That was true until 2026-09-08 and the argument behind it was
	wrong in one specific way: a preference about what THIS MACHINE draws is still
	about the same machine when it comes back tomorrow. Somebody who dropped the
	shadows and hid the other beachgoers because their phone was struggling had to
	do it again on every join.

	SO THERE IS A REMOTE, AND IT IS THE ONLY THING HERE THAT LEAVES THE CLIENT.
	The effect is still applied locally and instantly -- the round trip is purely
	so the choice is still there next time. SettingsServer whitelists the key and
	the value; see its header for what is stored and what saving them costs.

	AND EACH ROW WATCHES ITS OWN ATTRIBUTE, which is what makes a restore land:
	this panel is BUILT AT BOOT and a profile takes a datastore round trip, so the
	saved value nearly always arrives AFTER the row has drawn itself at the
	default. Without the listeners every setting here would appear to save and be
	forgotten on every join.

	Music/SFX route through SoundGroups. SoundService itself has no Volume
	property -- setting one silently does nothing, which is a classic way to
	ship a dead volume slider.
]]
local SoundService = game:GetService("SoundService")
local Lighting = game:GetService("Lighting")

local function soundGroup(name)
	local g = SoundService:FindFirstChild(name)
	if not g then
		g = Instance.new("SoundGroup")
		g.Name = name
		g.Volume = 1
		g.Parent = SoundService
	end
	return g
end

-- A chunky sliding pill.
local function pill(parent, on)
	local holder = Instance.new("Frame")
	holder.Size = UDim2.fromOffset(96, 42)
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	local slab = Instance.new("Frame")
	slab.Size = UDim2.fromOffset(96, 38)
	slab.Position = UDim2.fromOffset(0, 5)
	slab.BackgroundColor3 = darken(C.limeDark, 0.4)
	slab.BorderSizePixel = 0
	slab.Parent = holder
	corner(slab, 19)
	outline(slab, 3.5)

	local face = Instance.new("TextButton")
	face.Size = UDim2.fromOffset(96, 38)
	face.BackgroundColor3 = C.lime
	face.BorderSizePixel = 0
	face.AutoButtonColor = false
	face.Text = ""
	face.Parent = holder
	corner(face, 19)
	outline(face, 3.5)

	local lbl = text(face, "ON", 16, Enum.Font.LuckiestGuy, C.white)
	lbl.Size = UDim2.fromOffset(52, 38)
	lbl.Position = UDim2.fromOffset(4, 0)
	lbl.ZIndex = 6
	punch(lbl, 2.5)

	local knob = Instance.new("Frame")
	knob.Size = UDim2.fromOffset(30, 30)
	knob.Position = UDim2.fromOffset(62, 4)
	knob.BackgroundColor3 = C.white
	knob.BorderSizePixel = 0
	knob.ZIndex = 7
	knob.Parent = face
	corner(knob, 15)
	outline(knob, 3)

	local state = on
	local function paint(animate)
		local ti = TweenInfo.new(animate and 0.16 or 0, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		TweenService:Create(knob, ti, { Position = UDim2.fromOffset(state and 62 or 4, 4) }):Play()
		TweenService:Create(face, TweenInfo.new(animate and 0.16 or 0),
			{ BackgroundColor3 = state and C.lime or C.coral }):Play()
		slab.BackgroundColor3 = darken(state and C.lime or C.coral, 0.45)
		lbl.Text = state and "ON" or "OFF"
		lbl.Position = UDim2.fromOffset(state and 4 or 40, 0)
	end
	paint(false)
	return holder, face, function() return state end, function(v, animate)
		state = v
		paint(animate ~= false)
	end
end

local SETTINGS = {
	{ key = "Music",       name = "Beach Tunes",       emoji = "\240\159\142\181", default = true },
	{ key = "SFX",         name = "Sound Effects",     emoji = "\240\159\148\138", default = true },
	{ key = "ScreenShake", name = "Screen Shake",      emoji = "\240\159\146\165", default = true },
	--[[
		THE GENERAL ANSWER, WHERE ScreenShake AND Flash ARE TWO SYMPTOMS OF IT.

		Roblox already asks this question in its own accessibility menu, and the
		answer is unreadable from game code -- UserGameSettings.ReducedMotion is
		RobloxScriptSecurity, the same wall MenuHud already hit on MasterVolume.
		So the player has to be asked twice, which is a shame and is not a reason
		to skip asking.

		DEFAULT false, because motion is this game's voice and turning it down
		for everybody to serve a minority is the wrong trade. Read through
		Modules.Motion, which every panel and toast now takes its curves from.
	]]
	{ key = "ReducedMotion", name = "Reduced Motion",  emoji = "\240\159\140\128", default = false },
	{ key = "HideOthers",  name = "Hide Other Beachgoers", emoji = "\240\159\145\165", default = false },
	--[[
		YOUR OWN PETS. Asked for on 2026-09-20: "Add a button to hide pets."

		YOUR OWN, and the name says so, because the OTHER half already exists --
		Hide Other Beachgoers sweeps every workspace model named "<Username>_",
		which is exactly how PetServer names a spawned pet. So other people's
		pets have always been coverable and yours never were. This is the half
		that was missing, not a second switch for the same thing.

		It is also why the two must not overlap. The note above `hidden` spells
		out what a SECOND concealer does to a part the first one already hid: it
		records the hidden value as the resting one and the part never comes
		back. Scoped to your own pets, the two sweeps can never touch the same
		instance, so that failure is impossible by construction rather than by
		careful ordering.
	]]
	{ key = "HidePets",    name = "Hide Your Pets",    emoji = "\240\159\144\190", default = false },
	--[[
		HIDE YOUR OWN VIP TAG. Asked for by PineappleJUICEbox, 2026-09-24.

		VipService owns the effect and is the only thing that builds the billboard;
		this row is just the switch. Off by default, because the tag is what the
		pass advertises and nobody buys it to hide it -- this is for the player who
		has worn it long enough to be done with it.

		DRAWN FOR EVERYBODY rather than gated on owning the pass, matching the call
		SettingsServer's SkipWashBay note makes: a gate here would have to agree
		with a gate over there forever. A player without VIP flips a boolean that
		changes nothing they can see, which costs one row and no correctness.
	]]
	{ key = "HideVipTag",  name = "Hide Your VIP Tag", emoji = "\240\159\145\145", default = false },
	{ key = "Shadows",     name = "Fancy Shadows",     emoji = "\226\152\128", default = true },
	-- The loose sand the sifter digs through, which stands over the field as a
	-- grid of raised squares. ON hides it and leaves the ground underneath, for
	-- anyone who would rather look at a flat beach. CTB_Client owns the effect --
	-- it is the only script that knows the layer exists.
	--[[
		YOUR OWN ARMS IN FIRST PERSON. Asked for on 2026-09-15, in the reporter's
		own words: "I don't know if it's intended, but my arms are visible in first
		person. Maybe a setting to turn that off could be nice?"

		It IS intended -- see FirstPersonView, which puts them back precisely so the
		sifter is not a wheelbarrow steering itself a stud and a half in front of
		nobody. But "intended" and "wanted by everybody" are different claims, and
		the honest answer to somebody who can see the seam is a switch rather than
		an explanation.

		OFF BY DEFAULT, so nobody else's game changes: false here means the arms
		stay, which is what every player has now. Named for the HIDE family beside
		it rather than "First-Person Arms" for the same reason -- a row whose ON
		state is the departure from normal reads the right way round in a list where
		the two rows above it already work like that.
	]]
	{ key = "HideArms", name = "Hide Your Arms", emoji = "\240\159\145\144", default = false },
	--[[
		WHO MAY PUT A POPUP ON YOUR SCREEN. Asked for twice on 2026-09-17, by two
		players who do not share a language: "Ability to turn off trade requests"
		and "거래 끄기 만들어주세요".

		ON BY DEFAULT, so nobody else's game changes, and phrased as the thing
		rather than the refusal -- this is a capability you switch off, like Beach
		Tunes, not a departure you switch on like the Hide rows above it.

		INCOMING ONLY: off, nobody can invite you, and you can still invite them.
		TradeService enforces it at the invite, which is the only place it can be
		enforced -- see the note there.
	]]
	{ key = "TradeRequests", name = "Trade Requests", emoji = "\240\159\164\157", default = true },
	--[[
		THE WASH RIG'S OWN NOISE, separately from Sound Effects. Asked for on
		2026-09-17: "The water gun sounds is too loud. Maybe giving us options to
		turn it off or lower it down would be cool."

		A ROW OF ITS OWN BECAUSE THE BLUNT ONE WAS ALREADY TRIED. Their settings
		snapshot has SFX OFF on that message and ON again in their next one
		thirteen minutes later -- they turned everything off, did not like it, and
		came back. Pointing them at Sound Effects would have been telling them to
		do the thing they had just undone.

		OFF, NOT QUIETER, and that is the honest half of the ask. AudioKit has one
		SFX bus because SoundGroups do not nest, so a real volume slider means
		per-Sound scaling and a multi-value row like Time of Day. This is the
		boolean that answers "turn it off" today; the slider is a bigger job.
	]]
	{ key = "WashSounds", name = "Wash Bay Sounds", emoji = "\240\159\146\166", default = true },
	{ key = "HideSquares", name = "Hide Sand Squares", emoji = "\226\172\156", default = false },
	--[[
		THE WHITE-OUT, IN BOTH PLACES IT HAPPENS. Asked for by a player on
		2026-09-09, in as many words: "I'd like a flash on/off option in the
		settings."

		CTB_Client's own note on the pickup glow had already written the case for
		this switch without calling it one: point lights ADD, so a sifter dragged
		through a line of litter pops several finds inside a second, each light
		rising while the last is still falling -- "what the player actually saw was
		not a glow on a bottle, it was the whole foreground going white for a
		moment on every pass". It was halved once. Halved is still a flash, and at
		a 41-stud sifter it happens every step of every session. Measured before
		the switch went in: 137 point lights in one 16-second pass across the
		beach field. After, with the row off: none, and the sand and the finds
		unchanged.

		TWO OWNERS, ONE ROW, which is why the key is "Flash" and not "PickupFlash".
		CTB_Client drops the find's point light and its spark burst; EggClient
		drops the hatch reveal's full-screen frame and the ring and shell burst
		that land on it. The pet roulette was added to the row on the owner's ask
		the same day -- it is the same effect and the same complaint, and a player
		hunting for "the flash" should not have to find two switches.

		ON BY DEFAULT, so nobody else's game changes. OFF keeps everything that is
		the EVENT rather than the light: the sand burst, the sound, the reel, the
		tier colour and the animal itself. The dig is still a dig and the hatch is
		still a hatch; they just stop strobing.
	]]
	{ key = "Flash",       name = "Flash Effects",    emoji = "\226\156\168", default = true },
	--[[
		THE HINT BAND. Asked for on 2026-09-10 in these words: "fun game but i
		hate the random pop ups.. ruins the calmness of the game".

		The rotation was also given an end the same day -- six tips a session, two
		for anyone past their first rebirth, where before it was a `while true`
		that ran for as long as the session did. This row is for the players that
		is still too many for, and it is a fair thing to want: the band is advice,
		and advice you did not ask for is the one kind of notification a player is
		entitled to refuse outright.

		OFF STOPS THE CLOCK, IT DOES NOT MUTE THE SCREEN. Everything that is the
		game answering something you did -- the sell toast, the storage-up banner,
		the hatch reveal, the event line -- is untouched. Turning this off makes
		the game quieter, not deader. /tip still works for anyone who wants one on
		purpose; see the note on `remember` in TipClient.

		ON BY DEFAULT, so nobody else's game changes.
	]]
	--[[
		THE WASH BAY, FOR THE PEOPLE WHO PAID TO SKIP IT.

		The Instant Wash prompt cleans the whole bag where you stand now, and
		never opens the sprayer -- asked for on 2026-09-16 by an owner: "having to
		actually interact with it and go into the pressure sprayer view is kind of
		annoying." That is the right default for a pass whose whole promise is not
		waiting, which is why this is ON.

		IT EXISTS BECAUSE THE FAST PATH TAKES SOMETHING AWAY. An owner who wants
		the minigame had no way back to it, and "you bought the pass" is a poor
		answer to somebody who liked hosing rocks. Off here and the prompt behaves
		exactly as it does for everybody else.

		`when` HIDES IT FROM EVERYONE ELSE, and it is the only row here that has
		one. A switch that cannot do anything is worse than no switch: it invites
		a player to flip it looking for a change that will not come. Twelve rows
		on a phone is already a scroll -- see the note on the list's height -- so
		a thirteenth has to earn its place for the player looking at it.
	]]
	{ key = "SkipWashBay", name = "Skip the Wash Bay", emoji = "\240\159\154\191", default = true,
	  watch = PassConfig.Passes.InstantWash.attribute,
	  when = function()
		  return PassConfig.owns(player, PassConfig.Passes.InstantWash.key)
	  end },
	{ key = TipConfig.SettingKey, name = "Helpful Tips", emoji = "\240\159\146\161", default = true },
}

--[[
	HIDE OTHER BEACHGOERS  --  the whole of somebody else, not just their body.

	The first version of this walked each other player's Character once, on the
	frame the switch was flipped, and set LocalTransparencyModifier on every
	BasePart and Decal under it. That misses in three directions at once, and all
	three were reported:

	IT MISSES CLASSES. LocalTransparencyModifier only exists on BasePart, so a
	pet -- a MeshPart plus a ParticleEmitter, a Beam, a Trail and a PointLight --
	stayed lit, and the VIP nameplate (a BillboardGui on the head) stayed up.
	Worse, THE ORDINARY NAMETAG IS NOT AN INSTANCE AT ALL: it is Roblox's own
	floating display, driven by Humanoid.DisplayDistanceType, so no amount of
	walking the character looking for things to switch off could ever have found
	it. Each class goes off by ITS OWN property here, or it does not go off.

	IT MISSES WHAT IS NOT UNDER THE CHARACTER, which is where their rake lives.
	Every OTHER player's sifter is drawn locally by CTB_Client as a replica model
	at Workspace.CTB_Peers.CTB_Sifter_<Username>; it is never an equipped Tool on
	their character. Their pets are the same shape (Workspace models named
	"<Username>_<PetId>", see PetServer.spawnBody) and so are their sandbots
	(Workspace.Sandbots, tagged with an OwnerUserId attribute).

	IT MISSES TIME. A pass at the moment of the toggle knows nothing about the
	player who joins a minute later, the character that respawns, the rake that
	gets equipped, or the peer rig CTB_Client rebuilds when somebody's width
	changes -- and CTB_Client parents that rig in and out of the world as they
	sit down and stand up. All of those arrived visible.

	So this is a RE-ASSERTING SWEEP rather than a wall of signals, which is the
	call IntroCinema's concealer already made over the same three models and for
	the same reason: those models are drawn by other scripts that rebuild and
	re-show them whenever they like, parts stream in late, and people join and
	respawn on their own schedule. A fifth-of-a-second pass cannot miss any of
	that; a set of DescendantAdded hooks demonstrably could.

	VEHICLES ARE DELIBERATELY LEFT ALONE. A pet, a rake replica and a sandbot are
	all CanCollide false -- hiding them removes a picture and nothing else. An ATV
	or a dozer is solid and can be stood on, so an invisible one is a wall you
	walk into rather than a beachgoer you stopped looking at.

	The ORIGINAL value of every property is recorded, so switching back off puts
	back what was actually there rather than a guessed default.
]]
local refreshHideOthers
do
	local SWEEP = 0.2

	--[[
		STRONG KEYS. THESE TWO TABLES ARE THE RESTORE LEDGER, NOT A CACHE, AND
		THIS WAS THE "PEOPLE GO INVISIBLE" BUG, ENTIRE.

		They were weak-keyed (__mode = "k") so that despawned bodies would not pile
		up for the length of a session. That is the wrong trade to make here: an
		entry lost from a cache costs a rebuild, an entry lost from THIS one is
		somebody left invisible until they rejoin.

		AND THEY WERE LOST, ROUTINELY. A Roblox Instance is kept alive by the
		DATAMODEL, not by Lua -- the userdata a weak table keys on is collectable
		the moment no ordinary Lua reference holds it, and between two sweep passes
		nothing does. Measured in this place: a BasePart still parented under
		Workspace, dropped into a weak table and left through a few collections, is
		GONE from the table while the part is still standing in the world.

		Losing the record breaks the restore twice over, and the second way is the
		one that leaves a permanent mark:

		  * reveal() never hears about the part, so it stays at
		    LocalTransparencyModifier = 1; and
		  * the NEXT sweep pass finds no record, so it records what it now sees --
		    the 1 the pass before it wrote -- as the "original", and reveal() hands
		    that straight back as the resting value.

		Which is precisely the failure the note on WASH_ATTR below warns about,
		with the garbage collector standing in for the second concealer. It bit
		hardest at a WASH BAY, where this sweep runs on every session: the stranded
		player's body, face and pets stayed hidden while their sifter -- a model
		CTB_Client rebuilds on its own schedule -- came back without them, so they
		read as a floating width tag over an empty patch of sand.

		The pile-up strong keys bring back is real, and it is bounded: reveal()
		clears both tables at the end of every session, and a session is one wash
		or one press of the setting.
	]]
	local hidden = {}    -- [Instance] = { prop = original }
	local displays = {}  -- [Humanoid] = { distanceType, healthType }
	local on = false
	local token = 0

	-- Switch one instance off by whatever property its class actually uses,
	-- recording what it was first. Re-entrant: called again on something already
	-- recorded it re-applies WITHOUT overwriting the saved original, which is what
	-- makes running this on a sweep safe.
	local function conceal(inst: Instance)
		local rec = hidden[inst]
		if rec == nil then
			rec = {}
			if inst:IsA("BasePart") then
				-- The client-only half of Transparency. Writing Transparency itself
				-- would be scribbling on somebody else's character -- a property this
				-- client does not own, and one the server would fight over.
				rec.LocalTransparencyModifier = inst.LocalTransparencyModifier
			elseif inst:IsA("Decal") then
				rec.Transparency = inst.Transparency    -- Texture inherits Decal
			elseif inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam")
				or inst:IsA("Smoke") or inst:IsA("Fire") or inst:IsA("Sparkles")
				or inst:IsA("Light") or inst:IsA("BillboardGui") or inst:IsA("SurfaceGui")
				or inst:IsA("Highlight") then
				rec.Enabled = inst.Enabled
			else
				return
			end
			hidden[inst] = rec
		end

		if rec.LocalTransparencyModifier ~= nil then
			inst.LocalTransparencyModifier = 1
		elseif rec.Transparency ~= nil then
			inst.Transparency = 1
		else
			inst.Enabled = false
		end
	end

	local function concealModel(model: Instance)
		for _, d in model:GetDescendants() do
			conceal(d)
		end
	end

	local function concealOthers()
		local prefixes = {}    -- "<Username>_", for finding their pets by name
		local peers = workspace:FindFirstChild("CTB_Peers")

		for _, other in Players:GetPlayers() do
			if other ~= player then
				local char = other.Character
				if char then
					-- Equipped tools are parented to the character, so this covers
					-- whatever is actually in their hands as well as the body, the
					-- face, the accessories and the VIP plate on the head.
					concealModel(char)

					local hum = char:FindFirstChildOfClass("Humanoid")
					if hum then
						if displays[hum] == nil then
							displays[hum] = { hum.DisplayDistanceType, hum.HealthDisplayType }
						end
						hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
						hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
					end
				end

				-- Their rake. Yours is Workspace.CTB_Sifter and every peer's is a
				-- replica under CTB_Peers, so this cannot take your own tool away.
				local ghost = peers and peers:FindFirstChild("CTB_Sifter_" .. other.Name)
				if ghost then
					concealModel(ghost)
				end

				table.insert(prefixes, other.Name .. "_")
			end
		end

		if #prefixes == 0 then
			return
		end

		-- ONE pass over Workspace's children for the whole server rather than one
		-- per player: this runs five times a second for as long as the switch is
		-- on, and the per-player version walks the same list once per beachgoer.
		for _, m in workspace:GetChildren() do
			if m:IsA("Model") then
				local n = m.Name
				for _, prefix in prefixes do
					if n:sub(1, #prefix) == prefix then
						concealModel(m)
						break
					end
				end
			end
		end

		-- Sandbots carry their owner, so they are matched on that rather than on a
		-- name: SandbotService names them by UserId, and a drone left behind by a
		-- previous session has no owner at all.
		local bots = workspace:FindFirstChild("Sandbots")
		if bots then
			for _, bot in bots:GetChildren() do
				if bot:GetAttribute("OwnerUserId") ~= player.UserId then
					concealModel(bot)
				end
			end
		end

		-- AND WHAT THEY LEFT ON THE STAND. A mounted lump is parented to the BAY,
		-- not to the player scrubbing it, so nothing above reaches it: with its
		-- owner hidden it sits in the shed being washed by nobody. Matched on
		-- WashOwner, which WashServer stamps BEFORE parenting the model precisely
		-- so it arrives with one -- but the nil case is skipped rather than hidden
		-- anyway, because a lump caught without its owner would be recorded as
		-- somebody else's and stay invisible for the rest of the session.
		for _, bay in CollectionService:GetTagged("WashBay") do
			local mounted = bay:FindFirstChild("Mounted")
			if mounted then
				for _, lump in mounted:GetChildren() do
					local owner = lump:GetAttribute("WashOwner")
					if owner ~= nil and owner ~= player.UserId then
						concealModel(lump)
					end
				end
			end
		end
	end

	--[[
		NO Parent GUARD ON THE WAY BACK, AND THAT IS DELIBERATE.

		Parent = nil does not mean gone. CTB_Client PARKS peer sifters that way --
		startPeerSifters.show writes `rig.model.Parent = on and peerFolder or nil`
		for every rig out of range -- so a rig parked at the moment a wash ended
		was skipped here, and sailed back into the world still veiled with nothing
		left running to put it right.

		Writing to an instance that really was destroyed is harmless: Destroy locks
		Parent and nothing else, so the write below simply lands on an object
		nobody can see. The pcall covers the rest.
	]]
	local function reveal()
		for inst, rec in pairs(hidden) do
			for prop, value in pairs(rec) do
				pcall(function()
					inst[prop] = value
				end)
			end
		end
		table.clear(hidden)

		for hum, was in pairs(displays) do
			pcall(function()
				hum.DisplayDistanceType = was[1]
				hum.HealthDisplayType = was[2]
			end)
		end
		table.clear(displays)
	end

	local function setHideOthers(want: boolean)
		if want == on then
			return
		end
		on = want
		-- Bumped on every change so a fast off-then-on cannot leave two sweeps
		-- running: the older one's token no longer matches and it stops itself.
		token += 1

		if not want then
			reveal()
			return
		end

		local mine = token
		task.spawn(function()
			local warned = false
			-- task.wait, NOT RenderStepped: a minimised or background window stops
			-- firing RenderStepped altogether and the sweep would stall with the
			-- whole server still hidden. The first pass runs before the first yield,
			-- so the toggle takes effect on the frame it is pressed.
			while token == mine do
				-- GUARDED, because this loop is the only thing keeping the picture
				-- honest. An error thrown in a task.spawn thread kills the thread and
				-- is swallowed by every pcall outside it, so an unguarded fault here
				-- would not surface as a broken sweep -- it would surface as a server
				-- full of people who never come back, with nothing still running to
				-- notice. A bad pass is skipped and the next one tries again; the
				-- warning fires once rather than five times a second.
				local fine, why = pcall(concealOthers)
				if not fine and not warned then
					warned = true
					warn("[MenuHud] hide-others sweep faulted: " .. tostring(why))
				end
				task.wait(SWEEP)
			end
		end)
	end

	--[[
		TWO THINGS ASK FOR THIS AND NEITHER OWNS IT.

		The settings toggle is one. The other is the WASH BAY: its camera sits
		seven studs in front of the stand looking back at it, and anybody walking
		through that gap is standing in the shot. WashClientController veils what
		belongs to the washing player itself; for everyone ELSE it raises this
		attribute and borrows the sweep above.

		IT HAD TO BE THE SAME SWEEP. A second concealer over the same parts would
		have its own idea of each one's "original" value, and whichever recorded
		second would capture the first's 1 as the resting state and hand that back
		on release -- a player left invisible until they respawned, from nothing
		more than toggling a setting during a wash. One owner, one record, and an
		OR over the two reasons.

		The attribute is the client's own and never leaves this machine, the same
		channel the Set_* keys use.
	]]
	local WASH_ATTR = "WashInBay"

	function refreshHideOthers()
		setHideOthers(player:GetAttribute("Set_HideOthers") == true
			or player:GetAttribute(WASH_ATTR) == true)
	end

	player:GetAttributeChangedSignal(WASH_ATTR):Connect(refreshHideOthers)
end

--[[
	HIDE YOUR OWN PETS  --  Set_HidePets, asked for 2026-09-20.

	A SWEEP OF ITS OWN RATHER THAN A SECOND REASON FOR THE ONE ABOVE. Folding
	this into refreshHideOthers was the first shape tried and it is wrong twice:
	that sweep's reveal() empties one shared table, so turning EITHER switch off
	would have un-hidden what the other still wanted, and the wash bay already
	holds it for reasons of its own. Two switches, two owners, two tables.

	SAFE ONLY BECAUSE THE SETS ARE DISJOINT. See the note on `hidden` above: a
	second concealer meeting an already-hidden part records the hidden value as
	the resting one and the part stays gone for the session. This sweep touches
	models prefixed with THIS player's name and that one skips them, so no
	instance is ever in both. Widening either to overlap would need one shared
	record, not two -- do not do it by hand.

	DRIVEN OFF THE ATTRIBUTE, NOT OFF applySetting. applySetting writes
	Set_<key> before it does anything else, so listening here catches the press,
	the restore and the boot through one path -- and cannot be left behind by a
	branch somebody forgets to add. It is the shape Modules.Motion settled on
	after Set_ReducedMotion was gated at its call sites and silently did nothing.
]]
do
	local PET_ATTR = "Set_HidePets"
	local SWEEP = 0.2

	local hidden = {}    -- [Instance] = { prop = original }
	local on = false
	local token = 0

	-- The same shape as conceal() above, and deliberately a copy: sharing that
	-- one would mean sharing its `hidden`, which is the exact thing the header
	-- says not to do.
	local function conceal(inst: Instance)
		local rec = hidden[inst]
		if rec == nil then
			rec = {}
			if inst:IsA("BasePart") then
				rec.LocalTransparencyModifier = inst.LocalTransparencyModifier
			elseif inst:IsA("Decal") then
				rec.Transparency = inst.Transparency
			elseif inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam")
				or inst:IsA("Smoke") or inst:IsA("Fire") or inst:IsA("Sparkles")
				or inst:IsA("Light") or inst:IsA("BillboardGui") or inst:IsA("SurfaceGui")
				or inst:IsA("Highlight") then
				rec.Enabled = inst.Enabled
			else
				return
			end
			hidden[inst] = rec
		end

		if rec.LocalTransparencyModifier ~= nil then
			inst.LocalTransparencyModifier = 1
		elseif rec.Transparency ~= nil then
			inst.Transparency = 1
		else
			inst.Enabled = false
		end
	end

	-- No Parent guard, for the reason reveal() above gives: a pet despawned
	-- while hidden must still be put right, and writing to a destroyed instance
	-- lands harmlessly.
	local function reveal()
		for inst, rec in pairs(hidden) do
			for prop, value in pairs(rec) do
				pcall(function()
					inst[prop] = value
				end)
			end
		end
		table.clear(hidden)
	end

	--[[
		PetServer names a spawned pet "<player.Name>_<PetId>" and parents it to
		the Workspace (PetServer, `model.Name = string.format("%s_%s", ...)` and
		`model.Parent = workspace`). concealOthers already matches every OTHER
		player's pets on that same prefix, so this is the one name it skips.

		Swept rather than hooked to equip/unequip: pets come and go from the
		world on the server's schedule -- an egg hatch, a death, a slot change --
		and a hook would have to find every one of those. Five passes a second
		over Workspace's direct children is what the sweep above already costs.
	]]
	local function concealMine()
		local prefix = player.Name .. "_"
		for _, m in workspace:GetChildren() do
			if m:IsA("Model") and m.Name:sub(1, #prefix) == prefix then
				for _, d in m:GetDescendants() do
					conceal(d)
				end
			end
		end
	end

	local function setHidePets(want: boolean)
		if want == on then
			return
		end
		on = want
		token += 1

		if not want then
			reveal()
			return
		end

		local mine = token
		task.spawn(function()
			local warned = false
			-- task.wait rather than RenderStepped, and guarded, for the two
			-- reasons the hide-others sweep writes out at length.
			while token == mine do
				local fine, why = pcall(concealMine)
				if not fine and not warned then
					warned = true
					warn("[MenuHud] hide-pets sweep faulted: " .. tostring(why))
				end
				task.wait(SWEEP)
			end
		end)
	end

	player:GetAttributeChangedSignal(PET_ATTR):Connect(function()
		setHidePets(player:GetAttribute(PET_ATTR) == true)
	end)
	setHidePets(player:GetAttribute(PET_ATTR) == true)
end

local function applySetting(key, on)
	player:SetAttribute("Set_" .. key, on)
	if key == "Music" then
		-- Through AudioKit, NOT by writing .Volume here. The music fader now has
		-- two independent inputs -- this toggle and the duck the sifting and wash
		-- bays hold while a session is open -- and with two writers the last one
		-- to touch it wins, so turning music on mid-sift would have cancelled the
		-- duck and leaving the bay would have cancelled the toggle. AudioKit owns
		-- the multiply.
		AudioKit.setMusicEnabled(on)
	elseif key == "SFX" then
		soundGroup("BeachSFX").Volume = on and 1 or 0
		-- The engine's own character foley (footsteps, jump, landing) sits on its
		-- own bus, because Roblox's RbxCharacterSounds script rewrites those
		-- Sounds' Volume on every state change and SoundGroups cannot nest. It
		-- has to be driven here too or turning SFX off would leave the player
		-- audibly running around a silent beach. 0.45, not 1: see AudioKit.
		soundGroup("BeachSteps").Volume = on and 0.45 or 0
	elseif key == "Shadows" then
		Lighting.GlobalShadows = on
	elseif key == "HideOthers" then
		-- Not setHideOthers(on): the wash bay can be asking for the same thing,
		-- and switching the setting off underneath a live session would put every
		-- other player back in the middle of the shot.
		refreshHideOthers()
	end
	-- ScreenShake is read by Modules.Motion (Motion.shake), which the ferry
	-- crossing, the tomb cinematic and the Ashfall eruption each ask before
	-- moving the camera -- nothing to do here. HidePets is the same shape: the
	-- block above watches its attribute directly. HideSquares is
	-- the same shape: CTB_Client watches the attribute, hides the loose sand
	-- layer and drops the litter that was lying on top of it. Neither effect can
	-- be reached from this file, and both are already applied by the SetAttribute
	-- at the top of it.
end

--[[
	ASK THE SERVER TO REMEMBER ONE. Separate from applySetting on purpose: every
	caller of that wants the effect, and only a caller acting on a PRESS wants the
	save. A restore calls applySetting and must not call this, or the value the
	server just sent would be sent straight back to it.

	Fire and forget. The setting is already applied locally, so nothing is waiting
	on an answer and a server that never replies costs the player the remembering,
	not the setting.
]]
local function saveSetting(key, value)
	pcall(function()
		Net.get("SettingSave"):FireServer({ key = key, value = value })
	end)
end

--------------------------------------------------------------------------
-- THE ROBUX SHOP  --  everything bought with money rather than with coins
--------------------------------------------------------------------------
--[[
	THE SECOND SHOP, AND IT IS NOT THE SAME SHOP.

	`panels.Store` above is the COIN shop: upgrade tracks and a car ladder,
	priced in the money a player earns, capped by the tide and wiped by every
	rebirth. This one is priced in Robux and nothing in it is ever taken away.
	One rail key was standing for both, which meant a player pressing SHOP got
	upgrades and a player looking for what they could buy with Robux had nowhere
	to press at all -- the wash pass was reachable only from the wash HUD and the
	two machine passes only from the showroom, so two thirds of this game's
	monetisation was behind a building you had to already be standing in.

	IT TYPES NO ID AND NO PRICE. The list is ShopConfig's (which assembles it out
	of PassConfig and AtvConfig); the price comes off the attributes
	GamePassService publishes at boot. A price in a client file is a price that is
	wrong the first time somebody runs a sale.

	EVERY BUTTON HAS THREE STATES AND ONLY ONE IS A PURCHASE:

		OWNED       sun, inert. Already theirs, on every device, for good.
		R$ 1,234    grape, live. Opens Roblox's own dialog and nothing else --
		            this panel never grants anything and never asks a server to.
		SOON        sandDeep, inert. The pass is OFF SALE, which NO AMOUNT OF CODE
		            CAN FIX (see GamePassService's header: two of the three are
		            off sale as this is written). A live button here opens a
		            dialog the player cannot complete, and a price on it would be
		            a figure for something Roblox will refuse to sell.

	BOTH HALVES OF THE STATE ARRIVE LATE AND NEITHER CAN BE READ ONCE. Ownership
	lands on the Player when GamePassService resolves a pass, which is a web call
	and is late by design; price and for-sale land on a folder that does not exist
	during the first second of a session. So `paint` is wired to both and the
	panel repaints itself rather than being built from a snapshot.
]]
-- Measured before shipping, the way the note on TRACK_EMOJI says to: Roblox's
-- font has no fallback for newer emoji and a missing one renders as a narrow
-- box rather than failing loudly. All three below are Unicode 6.0 -- the same
-- vintage as the stock list's own -- and the tractor is already proven in this
-- file on the Rake row.
local SHOP_GLYPH = {
	InstantWash = "\u{1F4A7}",
	-- Unicode 6.0 as well, and measured the same way: MONEY BAG renders in full
	-- colour here. A key with no entry falls back to the star, which is honest
	-- but says nothing about what the row sells.
	QuickSell = "\u{1F4B0}",
	-- BANKNOTE WITH DOLLAR SIGN, Unicode 6.0 -- the same vintage as the rest of
	-- this table, so it renders in full colour rather than as a narrow box.
	-- Deliberately not the money bag again: Quick Sell is the other gold row in
	-- this list and two identical glyphs would make the two rows one blur.
	DoubleCash = "\u{1F4B5}",
	--[[
		THE FIVE COIN PACKS SHARE ONE GLYPH, which is the opposite of what the note
		above says about Double Cash -- and for the opposite reason. Those two are
		different products that happened to look alike, so telling them apart was
		the job. These five are the SAME product in five sizes, and reading as one
		family is correct: what separates them is the name and the tint ramp below,
		which runs pale gold to deep amber in the order they are listed.

		MONEY BAG again, and deliberately: it is the only Unicode 6.0 glyph that
		actually depicts a pile of coins, it is already proven to render in full
		colour in this file, and the alternative was inventing a meaning for a gem
		or a trophy. The banknotes are taken and are the wrong object anyway.
	]]
	-- The shelf's own door row. Same glyph as the rungs behind it, because it is
	-- the same thing at a different zoom; without an entry it fell back to the
	-- star, which says nothing about what is behind the door.
	Coins = "\u{1F4B0}",
	CoinsBucket = "\u{1F4B0}",
	CoinsBarrow = "\u{1F4B0}",
	CoinsCart = "\u{1F4B0}",
	CoinsChest = "\u{1F4B0}",
	CoinsHoard = "\u{1F4B0}",
	Sandhog = "\u{1F69C}",
	Tidebreaker = "\u{1F69A}",
	--[[
		ROBOT FACE, U+1F916 -- and it is Unicode 8.0, not 6.0 like everything above
		it, so the rule in this block's own header was CHECKED rather than trusted.

		The measurement TextService cannot make: GetTextSize reports 28x30 for a
		colour emoji and for a tofu box alike, so width proves nothing here. Drawn
		on screen at 40px next to the two known-good glyphs above, 1F916 renders in
		full colour -- as did every other candidate tried (broom 1F9F9, cyclone,
		plug, gear), which says Roblox's bundled emoji font is a good deal newer
		than 6.0 now.

		The caution is worth keeping anyway. What changed is the evidence, not the
		rule: the test is a photograph, never an assumption about the font.
	]]
	Sandbot = "\u{1F916}",
}
-- Only for entries that bring no colour of their own. The machines carry their
-- livery down from AtvConfig, so a tile in the shop is the colour of the thing
-- that turns up on the pad.
local SHOP_TILE_TINT = {
	InstantWash = C.sea,
	-- Gold, matching the HUD key this pass unlocks and the coin on it. C.sun is
	-- also the fallback, so this line is saying it on purpose rather than by
	-- accident -- the day the fallback changes, this row should not move with it.
	QuickSell = C.sun,
	-- Green, and it is the only row in the shop that gets it. Gold in this game
	-- means COINS -- the counter, the purse, the Quick Sell key -- and this pass
	-- does not give you any; it changes what the ones you earn are worth. It is
	-- also the colour of the coin shop's own BUY button, which is the screen a
	-- player is comparing it against.
	DoubleCash = C.lime,
	-- The ladder, pale gold to deep amber. This is the only thing on the tile
	-- that says which pack is the big one before the player reads the name, so
	-- the steps are wide enough to tell apart at a glance rather than being a
	-- smooth ramp that reads as five of the same colour.
	-- The door takes the middle of its own ladder, so it reads as the family
	-- rather than as its smallest or its largest member.
	Coins = Color3.fromRGB(255, 186, 44),
	CoinsBucket = Color3.fromRGB(255, 226, 148),
	CoinsBarrow = Color3.fromRGB(255, 208, 92),
	CoinsCart = Color3.fromRGB(255, 186, 44),
	CoinsChest = Color3.fromRGB(244, 154, 28),
	CoinsHoard = Color3.fromRGB(228, 120, 22),
	-- Foam, which is the drone's own body colour rather than a free slot picked
	-- at random: a tile in the shop should be the colour of the thing that turns
	-- up on the sand. Not C.sea, which Instant Wash already has -- two blue rows
	-- in this list would read as one.
	Sandbot = C.foam,
}

-- 580 rather than 420: the featured banner costs 144px of body and the shop has
-- four rows behind it now. The list scrolls, so this is about how much is
-- visible without scrolling rather than about fitting everything.
local PASS_W, PASS_H = 620, 580
local PASS_ROW_H = 96
-- Air under the banner, and under the strapline beneath it.
local PASS_BANNER_GAP = 10
--[[
	Reserved off a row's WIDTH for everything that is not the name and the blurb,
	and it has to count BOTH ends of the row rather than just the button's.

	The first cut was 180 -- button 150, margin 14, air 16 -- and every row's text
	ran 52px UNDER its own buy button, measured. The reason is that these labels
	start at x = 78 (clear of the icon tile) but are sized `1, -PASS_RIGHT`, which
	is a width, so the 78 is spent again at the right-hand end: the label's right
	edge lands at 78 + width, not at width. So the tile's 78 belongs in here too.

	78 icon + 164 button-and-margin + 18 air = 260. The stock list's ROW_RIGHT is
	250 for the same reason and against a narrower button; this is that number
	re-derived rather than copied, because the two panels' buttons differ.
]]
local PASS_RIGHT = 260

--[[
	THE COIN SHELF -- the five sizes, behind the shop's one Coins row.

	A panel of its own rather than a card inside the shop, because the ladder is
	the product: five rungs need to be READ AGAINST EACH OTHER, and a modal big
	enough to do that is a panel with extra steps. The X closes the menu like
	every other panel's; BACK returns to the shop it was opened from.

	EVERY FIGURE ON IT IS A FLAT NUMBER OF COINS. The packs are `scaled = false`
	(see ProductConfig, which argues it out) -- a pack states what it gives you
	and gives you that. The arithmetic below is still ProductServer.grantOf's,
	deliberately and even though the two now agree trivially: the number on the
	button and the number granted must be the same calculation, so that a row
	turned back to `scaled` cannot start lying without this panel following it.
]]
local COINS_W, COINS_H = 560, 520
local COIN_ROW_H = 84

local function buildCoinShelf(tiers)
	local root, body = makePanel("Coins", COINS_W, COINS_H, C.sun)
	panels.Coins = { root = root, w = COINS_W, h = COINS_H }

	local note = text(body, "BIGGER PACKS PAY MORE COINS PER ROBUX -- THE HOARD IS THE BEST RATE",
		13, Enum.Font.GothamBold, C.sand)
	note.Position = UDim2.fromOffset(4, 0)
	note.Size = UDim2.new(1, -8, 0, 22)
	note.TextXAlignment = Enum.TextXAlignment.Left
	note.TextTransparency = 0.12

	local BACK_H = 56
	local list = Instance.new("ScrollingFrame")
	list.Name = "Tiers"
	list.Position = UDim2.fromOffset(0, 26)
	list.Size = UDim2.new(1, 0, 1, -(26 + BACK_H))
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 8
	list.ScrollBarImageColor3 = C.wood
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.Parent = body
	local ly = Instance.new("UIListLayout")
	ly.Padding = UDim.new(0, ROW_GAP)
	ly.SortOrder = Enum.SortOrder.LayoutOrder
	ly.Parent = list
	local lpad = Instance.new("UIPadding")
	lpad.PaddingRight = UDim.new(0, 12)
	lpad.PaddingBottom = UDim.new(0, 6)
	lpad.Parent = list

	-- Warmer as the packs get bigger, so the ladder reads as one before a word of
	-- it is. Sand up to gold: the top rung is the only one that is properly gold.
	local TIER_TINT = { C.sea, C.foam, C.lime, C.sun, C.gold or C.sun }

	--[[
		A DRAWN ICON PER RUNG, not the rung's number.

		A tile with "3" in it tells the player where they are in a list they can
		already see the length of. It says nothing about what they are buying,
		and five identical tiles differing by one digit is what made the shelf
		look unfinished.

		BUILT OUT OF FRAMES rather than uploaded as images, for two reasons: an
		image has to survive Roblox moderation and be owned by the right creator
		to load at all (see ShopConfig.Art's note), and at 54px a photograph of a
		bucket is mush anyway. Rounded rectangles and circles are exactly the
		vocabulary the rest of this UI is drawn in.

		EACH ONE IS A CONTAINER PLUS ITS COINS, and the containers get bigger and
		more permanent as you go up -- pail, barrow, cart, chest, hoard. The
		silhouette carries the ladder; the coins say what is in it.
	]]
	local function bit(parent, x, y, w, h, col, rad, z)
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(x, y)
		f.Size = UDim2.fromScale(w, h)
		f.BackgroundColor3 = col
		f.BorderSizePixel = 0
		f.ZIndex = z or 7
		f.Parent = parent
		if rad and rad > 0 then
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(rad, 0)
			c.Parent = f
		end
		return f
	end

	local WOOD  = Color3.fromRGB(150, 96, 46)
	local WOODL = Color3.fromRGB(196, 138, 76)
	local IRON  = Color3.fromRGB(74, 62, 58)
	local GOLDC = Color3.fromRGB(255, 206, 74)
	local GOLDD = Color3.fromRGB(206, 150, 26)

	local function coins(tile, spots)
		for _, s in ipairs(spots) do
			bit(tile, s[1], s[2], s[3], s[3] * 0.78, GOLDC, 0.5, 9)
			bit(tile, s[1], s[2] - s[3] * 0.10, s[3] * 0.52, s[3] * 0.40, Color3.fromRGB(255, 232, 150), 0.5, 10)
		end
	end

	local function drawIcon(parent, kind)
		-- Everything the fallback draws goes in ONE frame, so it can be hidden as a
		-- unit the moment the real artwork arrives. Laid out edge to edge, so the
		-- coordinates below are unchanged from when they were drawn on the tile.
		local tile = Instance.new("Frame")
		tile.Name = "Fallback"
		tile.Size = UDim2.fromScale(1, 1)
		tile.BackgroundTransparency = 1
		tile.ZIndex = 6
		tile.Parent = parent

		if kind == "CoinsBucket" then
			-- THE COINS TUCK BEHIND THE RIM. Floating clear above a wide rim, two
			-- coins over a horizontal bar read as a pair of eyes over a mouth --
			-- the first pass was a face, not a pail. Overlapping the rim is what
			-- makes them read as being IN something, and narrower-and-taller is
			-- what a bucket actually is.
			coins(tile, { { 0.40, 0.42, 0.22 }, { 0.62, 0.40, 0.24 } })
			bit(tile, 0.5, 0.68, 0.46, 0.42, WOOD, 0.16, 11)      -- pail body
			bit(tile, 0.5, 0.50, 0.58, 0.12, WOODL, 0.5, 12)      -- its rim
			bit(tile, 0.5, 0.74, 0.34, 0.06, WOODL, 0.5, 12)      -- a band
		elseif kind == "CoinsBarrow" then
			coins(tile, { { 0.44, 0.28, 0.22 }, { 0.66, 0.26, 0.24 } })
			bit(tile, 0.52, 0.48, 0.62, 0.30, WOOD, 0.16, 11)     -- the tub
			bit(tile, 0.52, 0.37, 0.72, 0.11, WOODL, 0.5, 12)
			bit(tile, 0.20, 0.70, 0.44, 0.09, IRON, 0.5, 11)      -- the leg
			bit(tile, 0.72, 0.74, 0.26, 0.26, IRON, 0.5, 12)      -- the wheel
			bit(tile, 0.72, 0.74, 0.10, 0.10, WOODL, 0.5, 13)
		elseif kind == "CoinsCart" then
			coins(tile, { { 0.34, 0.26, 0.22 }, { 0.56, 0.22, 0.24 }, { 0.74, 0.28, 0.20 } })
			bit(tile, 0.52, 0.50, 0.72, 0.32, WOOD, 0.10, 11)     -- the bed
			bit(tile, 0.52, 0.38, 0.78, 0.10, WOODL, 0.4, 12)
			bit(tile, 0.52, 0.56, 0.60, 0.07, WOODL, 0.4, 12)
			bit(tile, 0.32, 0.78, 0.22, 0.22, IRON, 0.5, 12)      -- two wheels
			bit(tile, 0.72, 0.78, 0.22, 0.22, IRON, 0.5, 12)
		elseif kind == "CoinsChest" then
			coins(tile, { { 0.34, 0.24, 0.20 }, { 0.60, 0.20, 0.22 } })
			bit(tile, 0.5, 0.62, 0.74, 0.40, WOOD, 0.12, 11)      -- the box
			bit(tile, 0.5, 0.40, 0.78, 0.26, WOODL, 0.34, 12)     -- the domed lid
			bit(tile, 0.5, 0.50, 0.82, 0.09, GOLDD, 0.3, 13)      -- the strap
			bit(tile, 0.5, 0.56, 0.16, 0.20, GOLDC, 0.24, 14)     -- the lock
		else -- CoinsHoard, and anything new that has not been drawn yet
			bit(tile, 0.5, 0.74, 0.80, 0.22, GOLDD, 0.5, 8)       -- the pile's base
			coins(tile, { { 0.28, 0.62, 0.26 }, { 0.72, 0.62, 0.26 }, { 0.50, 0.66, 0.28 },
				{ 0.38, 0.42, 0.24 }, { 0.64, 0.40, 0.24 } })
			-- one gem on top, the same amethyst the VIP pet and rake carry
			bit(tile, 0.50, 0.24, 0.26, 0.26, Color3.fromRGB(150, 60, 210), 0.22, 12).Rotation = 45
			bit(tile, 0.50, 0.21, 0.12, 0.10, Color3.fromRGB(216, 158, 255), 0.3, 13)
		end
	end

	local coinRows = {}
	-- Kept alongside the rows so paintCoins can re-check them on every open; see
	-- the note where they are filled in.
	local artOf, fallbackOf = {}, {}
	for i, p in ipairs(tiers) do
		local row = PanelKit.row(list, COIN_ROW_H, i)
		row.Name = p.key

		local tile = PanelKit.tile(row, 58, 10, (COIN_ROW_H - 58) * 0.5, TIER_TINT[i] or C.sun)
		tile.ClipsDescendants = true
		drawIcon(tile, p.key)
		--[[
			THE DRAWN VERSION STAYS UNDERNEATH. The blocks above cannot carry a
			stave seam or a spoke, so the real artwork is an image laid over them
			-- and an image that does not load draws NOTHING AT ALL, silently.
			With the blocks behind it the worst case is the shelf looking like it
			did before; without them it is five empty tiles. Same arrangement as
			the shop banners over their classic rows.
		]]
		local art = p.art
		if art then
			local im = Instance.new("ImageLabel")
			im.Name = "Art"
			im.AnchorPoint = Vector2.new(0.5, 0.5)
			im.Position = UDim2.fromScale(0.5, 0.5)
			im.Size = UDim2.fromScale(0.94, 0.94)
			im.BackgroundTransparency = 1
			im.Image = art
			im.ScaleType = Enum.ScaleType.Fit
			im.ZIndex = 20
			im.Parent = tile

			-- See revealArt at the top of the file: it hides the drawn block once
			-- the art has actually arrived, and it is also what the preload for a
			-- BUILT-HIDDEN panel is doing -- Roblox does not fetch an image inside a
			-- hidden frame, so without this nothing would load until somebody first
			-- opened the shelf.
			artOf[i] = im
			fallbackOf[i] = tile:FindFirstChild("Fallback")
			if fallbackOf[i] then
				revealArt(im, fallbackOf[i])
			end
		end

		local nm = text(row, p.name, 19, Enum.Font.LuckiestGuy, C.ink)
		nm.Position = UDim2.fromOffset(74, 11)
		nm.Size = UDim2.new(1, -230, 0, 22)
		nm.TextXAlignment = Enum.TextXAlignment.Left

		local amt = text(row, "", 15, Enum.Font.GothamBold, Color3.fromRGB(132, 108, 82))
		amt.Position = UDim2.fromOffset(74, 35)
		amt.Size = UDim2.new(1, -230, 0, 20)
		amt.TextXAlignment = Enum.TextXAlignment.Left

		local bags = text(row, "", 12, Enum.Font.GothamMedium, Color3.fromRGB(162, 140, 116))
		bags.Position = UDim2.fromOffset(74, 55)
		bags.Size = UDim2.new(1, -230, 0, 18)
		bags.TextXAlignment = Enum.TextXAlignment.Left

		-- GREEN, not the panel's usual grape. Every other price button in this
		-- game buys a thing; these buy CURRENCY, and green is what the shop's own
		-- Robux badges are painted -- so the colour already means "this is the
		-- money button" everywhere a player has seen it.
		local holder, face, slab = chunky(row, 132, 42, C.lime, 14)
		holder.AnchorPoint = Vector2.new(1, 0.5)
		holder.Position = UDim2.new(1, -14, 0.5, -3)
		local cost = text(face, "", 18, Enum.Font.LuckiestGuy, C.white)
		cost.Size = UDim2.fromScale(1, 1)
		cost.ZIndex = 6
		punch(cost, 3)

		local entry = { product = p, face = face, slab = slab, cost = cost,
			amt = amt, bags = bags, live = false }
		TouchFit.press(face, function()
			if not entry.live then
				--[[
					SAY SO. Added 2026-09-09.

					A row with a price but no id yet is a LABEL, NOT AN OFFER -- it
					paints knocked back and buys nothing, which is right, and
					ProductConfig's own note says as much. What was missing is that
					it did so in COMPLETE SILENCE: "Golden Hour in a Bottle, R$ 99"
					sits at the top of the coin list and a tap on it produced no
					dialog, no toast and no sound. Every other not-for-sale button in
					the game already says this sentence -- the wash bay's pass button
					and the HUD's Quick Sell key both toast it -- so this is the one
					place that was quiet.
				]]
				ToastKit.toast((p.name or "That") .. " is not on sale yet.", "deny", 2.6)
				return
			end
			MarketplaceService:PromptProductPurchase(player, p.id)
		end)
		coinRows[i] = entry
	end

	local bHolder, bFace = chunky(body, 200, 44, C.wood, 15)
	bHolder.AnchorPoint = Vector2.new(0.5, 1)
	bHolder.Position = UDim2.new(0.5, 0, 1, -4)
	local bText = text(bFace, "BACK TO SHOP", 17, Enum.Font.LuckiestGuy, C.white)
	bText.Size = UDim2.fromScale(1, 1)
	bText.ZIndex = 6
	punch(bText, 2.5)
	TouchFit.press(bFace, function()
		openPanel("Shop")
	end)

	local function paintCoins()
		--[[
			THE BACKSTOP for the artwork's fallback blocks.

			revealArt gives up after four attempts, which is right for a normal join
			and wrong the day an icon is uploaded: a freshly uploaded asset can sit
			in moderation far longer than that, and the blocks would then stay up
			for the rest of the session even though the image had since arrived.

			This used to read im.IsLoaded, which is exactly the flag that never
			becomes true here -- so the backstop could not fire either, and the two
			mechanisms failed for the same single reason. It asks revealArt now,
			which is guarded, so calling it on every repaint costs one table lookup
			per rung while a request is already in flight.
		]]
		for i, im in pairs(artOf) do
			local fb = fallbackOf[i]
			if fb and fb.Visible then
				revealArt(im, fb)
			end
		end

		-- ProductServer.grantOf's own arithmetic. See the header.
		local mult = player:GetAttribute("SellMultiplier")
		if type(mult) ~= "number" or mult ~= mult or mult <= 0 then
			mult = 1
		end
		for _, r in coinRows do
			local p = r.product
			local coins = p.amount
			if p.scaled ~= false then
				coins = coins * mult
			end
			coins = math.floor(coins + 0.5)
			r.amt.Text = "$" .. comma(coins)

			--[[
				THE PRICE IS ALWAYS DRAWN, AND THE PUBLISHED ONE ALWAYS WINS.

				ProductConfig's `price` is the INTENDED figure and exists so the ladder
				reads as a ladder before the products have been created on the
				Dashboard. The moment GetProductInfo has answered for a real id that
				answer replaces it, so a sale is never misreported. This row used to
				paint "SOON" instead, and a coin shelf whose every rung says SOON is one
				nobody can price or judge -- the numbers that make it a ladder are
				exactly the ones missing.

				LIVE IS A SEPARATE QUESTION FROM WHAT THE LABEL SAYS. A row with a price
				but no id yet is a LABEL, NOT AN OFFER: it paints knocked back and its
				button does nothing, rather than opening a dialog Roblox cannot
				complete. ProductServer's boot warning is what says so out loud.
			]]
			local price = PassConfig.price(p.id) or p.price
			r.live = price ~= nil and type(p.id) == "number" and p.id > 0
			r.cost.Text = price and ("R$ " .. comma(price)) or "--"
			PanelKit.retint(r.face, r.slab, r.live and C.lime or C.sandDeep)
			r.cost.TextTransparency = r.live and 0 or 0.15

			-- The rate, and it is the only line that says WHY the big packs are the
			-- good ones. Drawn from the same two numbers as the button above it, so
			-- the two cannot disagree.
			r.bags.Text = price
				and string.format("%s coins per R$", comma(math.floor(p.amount / price + 0.5)))
				or ""
		end
	end
	panels.Coins.refresh = paintCoins
	paintCoins()

	-- The multiplier moves on every rebirth, and each of these figures is drawn
	-- from it. A panel showing last tide's numbers is worse than one showing none.
	player:GetAttributeChangedSignal("SellMultiplier"):Connect(paintCoins)
	return paintCoins
end

--------------------------------------------------------------------------
-- THE GOLD ROW
--------------------------------------------------------------------------
--[[
	ONE ROW IN THIS SHOP IS DRAWN INSTEAD OF PAINTED, AND IT IS NOT A FALLBACK.

	MEASURED 2026-08-24, with MarketplaceService:GetProductInfo on every id in
	ShopConfig.Art and on ShopConfig.Feature.image: ALL NINE are owned by USER
	254153724, and this place belongs to GROUP 4620487. Roblox will not serve a
	user's image inside a group experience and it refuses SILENTLY -- so all nine
	banners load for the uploader in Studio and for nobody else, and the drawn row
	underneath is the only version any player has ever seen. ShopConfig's own
	header records the same trap; this is the confirmation of it.

	So the top offer gets its treatment in the layer that actually ships. Nothing
	here can fail moderation, be deleted, or be filed under the wrong account --
	and re-uploading the artwork under the group would not improve on it, because
	the pet on the plinth is the REAL GildedUnicorn, turning, rather than a still
	of it keyed out of a studio backdrop.

	ZINDEX IS GLOBAL ON THIS ScreenGui (see the note over makeTank), so every
	number below is compared against the whole gui rather than against siblings.
	They stay inside 2..9 -- the band the artwork rows already prove is safe
	(Art 8, State 9, stamp 10) -- so nothing here can climb over the panel shell.
]]
--[[
	GOLD IS A RAMP, NOT A COLOUR, and the first pass got that wrong.

	One flat 255,186,44 under a two-stop gradient photographed as ORANGE -- next
	to this panel's own amber header it read as a slightly different orange rather
	than as metal. What separates gold from orange is the HIGHLIGHT: a near-cream
	band across the top third falling to amber, which is the only cue that says
	"polished" rather than "painted".

	So the plate is paler and yellower than the first attempt, and it carries four
	stops instead of two (see metalRamp). The PILL then goes DEEPER than the plate
	rather than matching it -- gold on gold at the same value is a button you have
	to hunt for.
]]
local GOLD = {
	deep   = Color3.fromRGB(120, 74, 14),    -- outlines, slab, the badge ground
	tray   = Color3.fromRGB(88, 56, 20),     -- the pet's plinth: dark, so gold pops
	mid    = Color3.fromRGB(208, 146, 28),   -- the shadow end of the plate ramp
	warm   = Color3.fromRGB(246, 198, 62),
	bright = Color3.fromRGB(255, 240, 170),  -- the highlight band
	pale   = Color3.fromRGB(255, 250, 226),  -- rays and sparkles
	buy    = Color3.fromRGB(255, 162, 26),   -- the price pill, DEEPER than the plate
}

--[[
	The four-stop sheen. PanelKit.grad takes two colours because two is all any
	other surface in this game needs; metal is the exception -- the highlight has
	to sit at about a third of the way down and fall off fast on both sides, and
	two stops can only ever describe a flat lean.
]]
local function metalRamp(inst: GuiObject)
	local g = inst:FindFirstChildOfClass("UIGradient")
	if not g then
		g = Instance.new("UIGradient")
		g.Rotation = 90
		g.Parent = inst
	end
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0.00, GOLD.warm),
		ColorSequenceKeypoint.new(0.30, GOLD.bright),
		ColorSequenceKeypoint.new(0.62, GOLD.warm),
		ColorSequenceKeypoint.new(1.00, GOLD.mid),
	})
	return g
end

-- Where the gold row's text column starts, and what it reserves on the right.
-- 330 lands its right edge on 392, which is where the classic row's 78 + -260
-- lands too -- so the two layouts share a margin even though they share nothing
-- else.
local GOLD_TEXT_X, GOLD_RIGHT = 150, 330

--[[
	THE SUFFIX RULE, for the fourth time in this codebase -- PetServer.findArt,
	PetVisuals, PetsPanel.findArt and EggClient.petModel are the others, and the
	point of it is that a hand-renamed model resolves everywhere or nowhere.

	IT HAS TO WRAP, exactly as EggClient's does. ReplicatedStorage.Pets.VIP holds
	a MeshPart, not a Model, and PanelKit.turntable takes a Model -- measured,
	because the obvious `:GetBoundingBox()` on it throws.
]]
local function vipPetModel(): Model?
	local def = PetConfig.get(PassConfig.VipPetId)
	local pets = ReplicatedStorage:FindFirstChild("Pets")
	local folder = def and pets and pets:FindFirstChild(def.Tier)
	if not (def and folder) then
		return nil
	end
	local art = folder:FindFirstChild(def.ModelName) or folder:FindFirstChild(def.PetId)
	if not art then
		for _, child in folder:GetChildren() do
			if child.Name:sub(-#def.PetId) == def.PetId then
				art = child
				break
			end
		end
	end
	if not art then
		return nil
	end
	local model = art:Clone()
	if not model:IsA("Model") then
		local wrap = Instance.new("Model")
		model.Parent = wrap
		wrap.PrimaryPart = model:IsA("BasePart") and model or nil
		model = wrap
	end
	return model
end

-- The kind badge. The artwork had one baked in; a drawn row has to say the same
-- thing, because "GAME PASS" is what tells a player this is theirs for good
-- rather than a consumable.
local function goldBadge(row: Frame, x: number, y: number)
	local b = Instance.new("Frame")
	b.Name = "Kind"
	b.Position = UDim2.fromOffset(x, y)
	b.Size = UDim2.fromOffset(98, 24)
	b.BackgroundColor3 = GOLD.deep
	b.BorderSizePixel = 0
	b.ZIndex = 6
	b.Parent = row
	corner(b, 12)
	outline(b, 2.5)
	local t = text(b, "GAME PASS", 12, Enum.Font.GothamBold, GOLD.pale)
	t.Size = UDim2.fromScale(1, 1)
	t.ZIndex = 7
	return b
end

--[[
	Turns an ordinary stock row into the gold plate.

	IT RECOLOURS THE ROW rather than laying a card over it: PanelKit.row already
	put the corner, the outline and the white-to-sand gradient there, and painting
	over them costs a second object the size of the first for no gain. retint's
	note is the relevant one -- a UIGradient MULTIPLIES against the fill under it,
	so both stops have to move with the BackgroundColor3 or the result is mud.

	Returns the turntable handle, or nil, so the caller owns starting it.
]]
local function goldenRow(row: Frame)
	row.BackgroundColor3 = GOLD.warm
	metalRamp(row)
	local st = row:FindFirstChildOfClass("UIStroke")
	if st then
		st.Color = GOLD.deep
		st.Thickness = 4
	end

	--[[
		⚠️ ClipsDescendants DOES NOT CLIP A ROTATED CHILD. MEASURED, because the
		first version of this card leaned on it and the rays came out across the whole
		screen -- visible over the beach, a hundred pixels outside the shop panel.

		With ClipsDescendants = true on this very frame, the six bars spilled
		239/201/90/0 px in x and 0/179/401/478 px in y. The clip is honoured for an
		unrotated child and silently skipped for a rotated one, so a rotated child has
		to FIT BY CONSTRUCTION. The box stays because it costs nothing and it is still
		right for anything unrotated added here later -- but nothing below relies on
		it.
	]]
	local burst = Instance.new("Frame")
	burst.Name = "Burst"
	burst.Size = UDim2.fromScale(1, 1)
	burst.BackgroundTransparency = 1
	burst.ClipsDescendants = true
	burst.ZIndex = 2
	burst.Parent = row
	corner(burst, 18)

	--[[
		A SUNBURST ACROSS THE CARD. Rotated bars, not a texture -- a texture is an
		upload and an upload under the wrong account is the whole reason this card
		exists.

		SIX BARS, NOT TWELVE. A Frame rotates about its AnchorPoint, so a long thin
		bar centred on the origin is TWO spokes; six bars thirty degrees apart give
		twelve evenly spaced ones for half the objects.

		EVERY BAR IS CUT TO ITS OWN ANGLE, which is the whole trick given the note
		above -- the clip cannot save a rotated child, so each one is sized to fit the
		row unaided. Rotating a w x t bar by θ needs

			2h·|cos| + t·|sin| <= W        and        2h·|sin| + t·|cos| <= H

		so the half-length is the smaller of the two solutions for h. Across 0..150
		that gives 572 / 261 / 156 / 142 / 156 / 261 -- a fan that is long across the
		card and short up it, which is the right shape for something 572 by 142
		anyway. The 4px taken off each side is slack for the rounding.

		CENTRED ON THE ROW, not behind the pet. A burst centred at the pet would have
		to be symmetric about x = 71, and there are only 71px of room to its left --
		so every bar would be capped at 142 and the whole thing would hide behind the
		118px tray standing on top of it.
	]]
	local RAY_T = 13
	local halfW, halfH = 572 * 0.5 - 4, 142 * 0.5 - 4
	for i = 0, 5 do
		local r = math.rad(i * 30)
		local c, s = math.abs(math.cos(r)), math.abs(math.sin(r))
		local byW = (c > 1e-3) and ((2 * halfW - RAY_T * s) / (2 * c)) or math.huge
		local byH = (s > 1e-3) and ((2 * halfH - RAY_T * c) / (2 * s)) or math.huge
		local half = math.min(byW, byH)

		local ray = Instance.new("Frame")
		ray.Name = "Ray"
		ray.AnchorPoint = Vector2.new(0.5, 0.5)
		ray.Position = UDim2.fromScale(0.5, 0.5)
		ray.Size = UDim2.fromOffset(math.floor(half * 2), RAY_T)
		ray.Rotation = i * 30
		ray.BackgroundColor3 = GOLD.pale
		-- 0.72, not 0.86. At 0.86 over a mid-gold plate the burst was invisible in a
		-- screenshot -- present in the tree, absent on screen, which is the worst of
		-- both. It still has to stay well off opaque or it fights the blurb.
		ray.BackgroundTransparency = 0.72
		ray.BorderSizePixel = 0
		ray.ZIndex = 3
		ray.Parent = burst
	end

	-- Sparkles as rotated squares, for the same reason the rays are bars: a
	-- four-pointed-star GLYPH would be a bet on Roblox's font having a dingbat,
	-- and the note on SHOP_GLYPH says that bet is settled by a photograph or not
	-- at all. A diamond cannot render as a tofu box.
	--
	-- These are rotated too, so the clip does not hold them either -- but the
	-- biggest is 13px on a 45-degree turn, i.e. an 18px box, and every one is
	-- placed at least 20px inside the row. They fit unaided, which is the same
	-- rule the rays follow, just satisfied by being small.
	for _, sp in ipairs({
		{ 210, 26, 13, 0.10 }, { 268, 104, 8, 0.28 }, { 352, 34, 10, 0.18 },
		{ 408, 92, 7, 0.34 }, { 470, 44, 11, 0.16 }, { 520, 106, 8, 0.30 },
		{ 128, 118, 9, 0.24 },
	}) do
		local s = Instance.new("Frame")
		s.Name = "Sparkle"
		s.AnchorPoint = Vector2.new(0.5, 0.5)
		s.Position = UDim2.fromOffset(sp[1], sp[2])
		s.Size = UDim2.fromOffset(sp[3], sp[3])
		s.Rotation = 45
		s.BackgroundColor3 = C.white
		s.BackgroundTransparency = sp[4]
		s.BorderSizePixel = 0
		s.ZIndex = 4
		s.Parent = burst
		corner(s, 2)
	end

	--[[
		A BRIGHT HAIRLINE JUST INSIDE THE OUTLINE -- the bevel.

		The ink outline says where the plate ends; this says the plate has a polished
		EDGE. It is one inset frame with a transparent fill and its own light stroke,
		which is cheaper than the four bars the same effect would take.
	]]
	local bevel = Instance.new("Frame")
	bevel.Name = "Bevel"
	bevel.Position = UDim2.fromOffset(4, 4)
	bevel.Size = UDim2.new(1, -8, 1, -8)
	bevel.BackgroundTransparency = 1
	bevel.ZIndex = 5
	bevel.Parent = row
	corner(bevel, 14)
	local hair = Instance.new("UIStroke")
	hair.Thickness = 2
	hair.Color = GOLD.pale
	hair.Transparency = 0.45
	hair.Parent = bevel

	-- The pet stands ON something. PanelKit.plinth clips, which is what keeps the
	-- ViewportFrame inside the tray's rounded corners. Dark on purpose: the pet is
	-- itself gold, and a gold pet on a gold tray has nothing to be seen against.
	local tray = PanelKit.plinth(row, GOLD.tray, 16)
	tray.Position = UDim2.fromOffset(12, 12)
	tray.Size = UDim2.fromOffset(118, 118)
	tray.ZIndex = 4

	local model = vipPetModel()
	if not model then
		return nil
	end
	--[[
		IT ROCKS, IT DOES NOT ORBIT, AND THE ANGLES WERE MEASURED RATHER THAN PICKED.

		This mesh is 5.2 studs across against 17.3 long, so a full turn spends a third
		of itself edge-on. Projected width by orbit angle, computed off the eight
		bounding-box corners the same way PanelKit solves its fit:

			t =  40 deg   18.03 studs   <- widest
			t =  60 deg   17.42        (best width/height ratio, 0.84)
			t = 150 deg    5.74 studs   <- a sliver, and it looked like a bug

		So the arc is centred on 50 degrees and swings 30 either way: the whole 20..80
		band stays above about 16.5 studs wide, and the animal is never end-on. The
		reveal's `startAngle = math.pi` trick is not needed here -- that one is about
		which way a full orbit OPENS, and this camera never leaves the good side.

		SLOW -- 0.28 against the reveal's 0.55. That one is a payoff the player is
		watching; this one sits in a list they are reading, and motion that competes
		with the price is motion in the wrong place.
	]]
	local turn = PanelKit.turntable(tray, model, {
		startAngle = math.rad(50),
		arc = math.rad(30),
		-- 1.02, not 1.10: the tray is only 118px and the first pass left the animal
		-- sitting in the middle of it with a ring of empty brown all round. The fit
		-- is solved against all eight box corners at every orbit angle, so a margin
		-- this tight still cannot crop it.
		aspect = 1, fov = 36, speed = 0.28, margin = 1.02,
		-- Lit brighter than the reveal's, because this one sits on a DARK tray in a
		-- bright panel: at the reveal's levels it photographed as a silhouette.
		ambient = Color3.fromRGB(190, 172, 142),
		light = Color3.fromRGB(255, 252, 240),
		zIndex = 6,
	})
	return turn
end

local function buildRobuxShop()
	local root, body = makePanel("Shop", PASS_W, PASS_H, C.sun)
	panels.Shop = { root = root, w = PASS_W, h = PASS_H }

	------------------------------------------------------------------
	-- THE FEATURED BANNER
	------------------------------------------------------------------
	--[[
		ONE OFFER GETS THE TOP OF THE SHOP, drawn as its own artwork rather than
		as a row. The image already carries the price, the coins and the pet, so
		there is nothing to lay out over it -- the whole banner is the button,
		which is also the most forgiving target on a phone.

		WHICH offer is ShopConfig's business, not this file's, and if its artwork
		is missing feature() answers nil: the banner is skipped, the pass goes
		back to being an ordinary row, and the shop still works. An asset id that
		fails moderation is then a cosmetic problem rather than a broken screen.
	]]
	local feature = ShopConfig.feature()
	local bannerH, banner, bannerScale, bannerFace, ownedVeil = 0
	if feature then
		-- Sized off the panel's own width and the artwork's aspect, so re-cropping
		-- the banner cannot leave it stretched.
		bannerH = math.floor((PASS_W - 36) / feature.aspect + 0.5)

		banner = Instance.new("Frame")
		banner.Name = "Feature"
		banner.Size = UDim2.new(1, 0, 0, bannerH)
		banner.BackgroundTransparency = 1
		banner.Parent = body
		-- The jiggle scales and rotates about the MIDDLE of the banner. Without
		-- this the pivot is the top-left corner and it swings like a hinged sign.
		local pivot = Instance.new("UIScale")
		pivot.Parent = banner
		bannerScale = pivot

		--[[
			A DRAWN OFFER CARD UNDERNEATH THE ARTWORK, AND IT IS NOT DECORATION.

			Roblox refuses to serve an image the EXPERIENCE'S OWNER does not own, and
			it refuses SILENTLY -- the ImageLabel draws nothing and reports no error.
			This place belongs to group 4620487; an asset uploaded from a personal
			account renders perfectly in the uploader's own Studio (they are the one
			client authorised to fetch it) and is an empty hole for every player.
			The rail's own note at the RAIL table records the same trap costing a
			shop icon once already.

			So the banner does not depend on the image. This card is always built,
			always says the offer, and is always clickable; the artwork sits on top
			at a higher ZIndex and hides it completely when it loads. Nothing has to
			DETECT the failure -- a missing image simply draws nothing and the card
			is what shows through.
		]]
		local card = Instance.new("Frame")
		card.Name = "OfferCard"
		card.AnchorPoint = Vector2.new(0.5, 0.5)
		card.Position = UDim2.fromScale(0.5, 0.5)
		card.Size = UDim2.fromScale(1, 1)
		card.BackgroundColor3 = C.sea
		card.BorderSizePixel = 0
		card.ZIndex = 4
		card.Parent = banner
		corner(card, 16)
		outline(card, 4)
		grad(card, C.sea:Lerp(C.white, 0.30), darken(C.sea, 0.20))
		gloss(card, 16)

		local cardTitle = text(card, "STARTER PACK!", 30, Enum.Font.LuckiestGuy, C.sun)
		cardTitle.Position = UDim2.new(0, 0, 0, 10)
		cardTitle.Size = UDim2.new(1, 0, 0, 34)
		cardTitle.ZIndex = 5
		punch(cardTitle, 3)

		local cardLine = text(card, string.format("$%s  +  EXCLUSIVE PET",
			comma(PassConfig.StarterPackCoins)), 20, Enum.Font.LuckiestGuy, C.white)
		cardLine.Position = UDim2.new(0, 0, 0, 46)
		cardLine.Size = UDim2.new(1, 0, 0, 26)
		cardLine.ZIndex = 5
		punch(cardLine, 2.5)

		local cardSub = text(card, "BEST VALUE FOR NEW PLAYERS", 13, Enum.Font.GothamBold,
			C.sand)
		cardSub.AnchorPoint = Vector2.new(0.5, 1)
		cardSub.Position = UDim2.new(0.5, 0, 1, -10)
		cardSub.Size = UDim2.new(1, 0, 0, 18)
		cardSub.ZIndex = 5

		bannerFace = Instance.new("ImageButton")
		bannerFace.Name = "Buy"
		bannerFace.AnchorPoint = Vector2.new(0.5, 0.5)
		bannerFace.Position = UDim2.fromScale(0.5, 0.5)
		bannerFace.Size = UDim2.fromScale(1, 1)
		bannerFace.BackgroundTransparency = 1
		bannerFace.Image = feature.image
		bannerFace.ScaleType = Enum.ScaleType.Fit
		bannerFace.AutoButtonColor = false
		bannerFace.ZIndex = 6
		bannerFace.Parent = banner

		-- Drawn over the art once the pack is theirs. The banner keeps its place --
		-- it is what they bought -- but it stops being a button.
		ownedVeil = Instance.new("Frame")
		ownedVeil.Name = "Owned"
		ownedVeil.AnchorPoint = Vector2.new(0.5, 0.5)
		ownedVeil.Position = UDim2.fromScale(0.5, 0.5)
		ownedVeil.Size = UDim2.fromScale(1, 1)
		ownedVeil.BackgroundColor3 = C.ink
		ownedVeil.BackgroundTransparency = 0.45
		ownedVeil.BorderSizePixel = 0
		ownedVeil.Visible = false
		ownedVeil.ZIndex = 7
		ownedVeil.Parent = banner
		corner(ownedVeil, 14)
		local stamp = text(ownedVeil, "CLAIMED", 30, Enum.Font.LuckiestGuy, C.white)
		stamp.Size = UDim2.fromScale(1, 1)
		stamp.ZIndex = 8
		punch(stamp, 3.5)

		bannerFace.MouseButton1Down:Connect(function()
			if not ownedVeil.Visible then
				TweenService:Create(pivot, TweenInfo.new(0.07), { Scale = 0.97 }):Play()
			end
		end)
		local function releaseBanner()
			TweenService:Create(pivot, TweenInfo.new(0.16, Enum.EasingStyle.Back,
				Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
		bannerFace.MouseButton1Up:Connect(releaseBanner)
		bannerFace.MouseLeave:Connect(releaseBanner)
		TouchFit.press(bannerFace, function()
			if ownedVeil.Visible then
				return
			end
			-- Client call, as it has to be: there is no server-side way to open a
			-- purchase dialog. GamePassService hears the outcome and asks Roblox.
			MarketplaceService:PromptGamePassPurchase(player, feature.id)
		end)
	end

	local noteY = (bannerH > 0) and (bannerH + PASS_BANNER_GAP) or 0

	-- The one line of copy, and it is doing a job: everything else a player buys
	-- in this game is wiped by the next rebirth, so "this one is not" is the
	-- single most useful thing the panel can say before the prices.
	local note = text(body, "YOURS FOR GOOD \u{2014} ON EVERY DEVICE, THROUGH EVERY TIDE",
		13, Enum.Font.GothamBold, C.sand)
	note.Position = UDim2.fromOffset(4, noteY)
	note.Size = UDim2.new(1, -8, 0, 22)
	note.TextXAlignment = Enum.TextXAlignment.Left
	note.TextTransparency = 0.12

	local listY = noteY + 26
	local list = Instance.new("ScrollingFrame")
	list.Name = "Rows"
	list.Position = UDim2.fromOffset(0, listY)
	list.Size = UDim2.new(1, 0, 1, -listY)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 8
	list.ScrollBarImageColor3 = C.wood
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.Parent = body
	local ly = Instance.new("UIListLayout")
	ly.Padding = UDim.new(0, ROW_GAP)
	ly.SortOrder = Enum.SortOrder.LayoutOrder
	ly.Parent = list
	local pad = Instance.new("UIPadding")
	pad.PaddingRight = UDim.new(0, 12)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = list

	local shopRows = {}
	for i, item in ShopConfig.items() do
		-- The shelf's panel is built the moment its row is, out of the row's own
		-- tier list -- so this file never has to learn that ProductConfig exists.
		if item.kind == "coinshelf" and item.tiers and not panels.Coins then
			buildCoinShelf(item.tiers)
		end

		--[[
			A ROW WITH ARTWORK IS AS TALL AS ITS ARTWORK, and the height is DERIVED
			from the panel's own width rather than typed, exactly as the featured
			banner's is -- so re-cropping a banner cannot leave it stretched.

			PASS_W - 36 is the body's width (see the feature banner) and the further
			12 is the list's own right padding, which the scrollbar lives in.

			An entry with no artwork keeps PASS_ROW_H and every offset below comes
			out exactly where it did before -- the two `(rowH - PASS_ROW_H) * 0.5`
			terms are zero at that height. Nothing about the classic row moved.
		]]
		-- The gold row takes the artwork height too, off the same aspect, even
		-- though it has no artwork: it is the feature of this list and a 96-high
		-- feature between two 142s reads as the one row that failed to load.
		local rowH = PASS_ROW_H
		if item.image or item.style == "gold" then
			rowH = math.floor((PASS_W - 36 - 12) / (item.aspect or (2000 / 495)) + 0.5)
		end
		local drop = (rowH - PASS_ROW_H) * 0.5

		local row = PanelKit.row(list, rowH, i)
		row.Name = item.key or tostring(item.id)

		-- THE GOLD TREATMENT. See goldenRow -- and note that the pet's turntable is
		-- started here rather than in there, because a handle nobody starts is a
		-- still image and that is a difference worth being able to see in one place.
		local isGold = item.style == "gold"
		local goldHit
		if isGold then
			--[[
				THE WHOLE PLATE IS THE BUTTON, which is what the artwork rows already do
				-- their Art is an ImageButton covering everything -- and is the most
				forgiving target on a phone. A classic row is pill-only because a classic
				row is mostly blurb; this one is a poster.

				ZINDEX 5: under the title, blurb and badge (6) and under the pill (7), so
				it changes nothing about what is drawn. A TextLabel does not consume
				input, so the labels over it do not punch dead patches in it.
			]]
			goldHit = Instance.new("TextButton")
			goldHit.Name = "Hit"
			goldHit.Size = UDim2.fromScale(1, 1)
			goldHit.BackgroundTransparency = 1
			goldHit.Text = ""
			goldHit.AutoButtonColor = false
			goldHit.ZIndex = 5
			goldHit.Parent = row

			local turn = goldenRow(row)
			if turn then
				--[[
					STARTED AND LEFT RUNNING, unlike the ATV showroom's three, whose note
					says they only spin while their panel is up. That gate is worth its
					code there: three ViewportFrames over multi-part quads. This is ONE
					frame over ONE MeshPart, and a hidden ViewportFrame does not render --
					what keeps running is a single camera CFrame write per frame.
				]]
				turn:Start()
			end
		end

		local tint = item.tint or SHOP_TILE_TINT[item.key] or C.sun
		-- No icon tile on the gold row: the pet IS the icon, and a 58px emoji square
		-- beside a turning unicorn is two icons arguing.
		if not isGold then
			local tile = PanelKit.tile(row, 58, 10, (rowH - 58) * 0.5, tint)
			local glyph = text(tile, SHOP_GLYPH[item.key] or "\u{2B50}", 30, Enum.Font.GothamBold, C.white)
			glyph.Size = UDim2.fromScale(1, 1)
			glyph.ZIndex = 6
		end

		local textX = isGold and GOLD_TEXT_X or 78
		local textRight = isGold and GOLD_RIGHT or PASS_RIGHT

		-- White with an ink stroke on gold, not C.ink: dark brown on a gold plate is
		-- the one pairing in this palette with no value separation left in it.
		local nm = text(row, item.name, isGold and 42 or 21, Enum.Font.LuckiestGuy,
			isGold and C.white or C.ink)
		nm.Position = UDim2.fromOffset(textX, isGold and 8 or (12 + drop))
		nm.Size = UDim2.new(1, -textRight, 0, isGold and 46 or 24)
		nm.TextXAlignment = Enum.TextXAlignment.Left
		nm.ZIndex = 6
		if isGold then
			punch(nm, 4)
		end

		local bl = text(row, item.blurb or "", 13,
			isGold and Enum.Font.GothamBold or Enum.Font.GothamMedium,
			isGold and Color3.fromRGB(86, 48, 6) or Color3.fromRGB(132, 108, 82))
		bl.Position = UDim2.fromOffset(textX, isGold and 56 or (38 + drop))
		bl.Size = UDim2.new(1, -textRight, 0, isGold and 44 or 44)
		bl.ZIndex = 6
		bl.TextXAlignment = Enum.TextXAlignment.Left
		bl.TextYAlignment = Enum.TextYAlignment.Top
		bl.TextWrapped = true
		-- Wrapped rather than truncated: these blurbs are written as sentences and
		-- the machines' run to eighty characters. TextTruncate.AtEnd is PanelKit's
		-- default and would cut the sweeper's in half.
		bl.TextTruncate = Enum.TextTruncate.None

		if isGold then
			goldBadge(row, textX, 106)
		end

		local holder, face, slab = chunky(row, 150, 44, isGold and GOLD.buy or C.grape, 15)
		holder.AnchorPoint = Vector2.new(1, 0.5)
		holder.Position = UDim2.new(1, -14, 0.5, -3)
		local cost = text(face, "", 19, Enum.Font.LuckiestGuy, C.white)
		cost.Size = UDim2.fromScale(1, 1)
		cost.ZIndex = 6
		punch(cost, 3)

		--[[
			LIFTED OVER THE PLATE, and every course of the button has to be named.

			chunky leaves holder, slab and face on the default ZIndex 1 and derives its
			gloss from the face's ZIndex AT CREATION TIME -- so raising the face alone
			puts the gloss (2) underneath it and the button loses its cap. Under Global
			ZIndexBehavior the burst at 2 would cover all of it.
		]]
		if isGold then
			holder.ZIndex, slab.ZIndex, face.ZIndex = 7, 7, 7
			local capped = face:FindFirstChild("Gloss")
			if capped then
				capped.ZIndex = 8
			end
			cost.ZIndex = 9
		end

		-- `liveTint` is what paint() retints a PRESSABLE row to. Gold keeps its own,
		-- because a grape pill is the one thing that would break the plate.
		local entry = { item = item, face = face, slab = slab, cost = cost, live = false,
			liveTint = isGold and GOLD.buy or nil }

		-- What pressing this row does. The shelf's answer is the odd one out: it
		-- opens a panel instead of a purchase dialog, because what it is selling is
		-- five things and the player has not picked one yet.
		local function press()
			if not entry.live then
				-- The same silence the coin rows had, on the shelf above them. A row
				-- drawn SOON is inert on purpose; saying nothing at all is not.
				ToastKit.toast((item.name or "That") .. " is not on sale yet.", "deny", 2.6)
				return
			end
			-- No click sound. Not one button in this file plays one, and a single
			-- noisy button reads as a bug rather than as polish.
			if item.kind == "coinshelf" then
				openPanel("Coins")
			elseif item.kind == "product" then
				MarketplaceService:PromptProductPurchase(player, item.id)
			else
				MarketplaceService:PromptGamePassPurchase(player, item.id)
			end
		end

		--[[
			THE ARTWORK GOES ON TOP OF THE ROW, NOT INSTEAD OF IT.

			Everything above is still built and still laid out, and the banner is
			laid over it at a higher ZIndex where it covers the lot. That is the same
			trick the featured banner plays with its OfferCard, and for the same
			reason: AN IMAGE THAT DOES NOT LOAD DRAWS NOTHING AT ALL, silently. A
			deleted asset, one still in moderation, or -- the live case here -- one
			owned by a user rather than by the group that owns the place, would
			otherwise turn this shop into four empty boxes with no clue why.

			With the row underneath, the worst case is that the shop looks exactly
			like it did last week. Nothing has to DETECT the failure.
		]]
		if item.image then
			local art = Instance.new("ImageButton")
			art.Name = "Art"
			art.Size = UDim2.fromScale(1, 1)
			art.BackgroundTransparency = 1
			art.Image = item.image
			-- Fit, not Stretch: rowH is derived from this artwork's own aspect, so
			-- the two agree to within a rounded pixel and Fit cannot letterbox --
			-- but if a replacement banner is ever a different shape, Fit shows it
			-- honestly rather than squashing it to fit the box.
			art.ScaleType = Enum.ScaleType.Fit
			art.AutoButtonColor = false
			art.ZIndex = 8
			art.Parent = row
			corner(art, 16)

			-- OWNED / SOON, over the artwork. The price button underneath carries
			-- the same word, but it is behind the banner and nobody can read it.
			local veil = Instance.new("Frame")
			veil.Name = "State"
			veil.Size = UDim2.fromScale(1, 1)
			veil.BackgroundColor3 = C.ink
			veil.BackgroundTransparency = 0.45
			veil.BorderSizePixel = 0
			veil.Visible = false
			veil.ZIndex = 9
			veil.Parent = row
			corner(veil, 16)
			local stamp = text(veil, "OWNED", 26, Enum.Font.LuckiestGuy, C.white)
			stamp.Size = UDim2.fromScale(1, 1)
			stamp.ZIndex = 10
			punch(stamp, 3)

			entry.veil, entry.stamp = veil, stamp
			TouchFit.press(art, press)
		end

		--[[
			The guard inside press() is not decoration. chunky() has no disabled
			state -- the face is a TextButton whatever it is painted -- so OWNED and
			SOON would both still open a dialog: one asking a player to buy a thing
			they already own, the other opening a purchase Roblox will not complete.
			`live` is set by paint() alongside the colour, so the two cannot disagree.
		]]
		TouchFit.press(face, press)
		if goldHit then
			TouchFit.press(goldHit, press)
		end
		shopRows[i] = entry
	end

	local function paint()
		-- The banner's own state. It reads the same replicated attribute a row
		-- does -- the pass's, not the CLAIMED flag: what the shop is selling is the
		-- pass, and once it is theirs there is nothing left to sell them even if
		-- the grant has not landed yet.
		if ownedVeil and feature then
			ownedVeil.Visible = feature.attribute ~= nil
				and player:GetAttribute(feature.attribute) == true
		end
		for _, r in shopRows do
			local item = r.item

			-- A DOOR, NOT A PRICE. The shelf row has no id of its own and can never
			-- be owned; it is always pressable, and the SOON belongs to the sizes
			-- behind it, each of which paints its own.
			if item.kind == "coinshelf" then
				r.live = true
				r.cost.Text = string.format("%d SIZES", #(item.tiers or {}))
				r.cost.TextTransparency = 0
				PanelKit.retint(r.face, r.slab, C.grape)
				if r.veil then
					r.veil.Visible = false
				end
				continue
			end

			-- The client's copy, and it is only ever good enough to paint a button --
			-- the server asks Roblox before it hands anything over. See PassConfig.
			local owned = item.kind == "pass" and item.attribute ~= nil
				and player:GetAttribute(item.attribute) == true
			local price = PassConfig.price(item.id)

			if owned then
				r.live = false
				r.cost.Text = "OWNED"
				PanelKit.retint(r.face, r.slab, C.sun)
			elseif price and (item.kind == "product" or PassConfig.onSale(item.id)) then
				r.live = true
				r.cost.Text = "R$ " .. comma(price)
				-- The row's own colour where it has one -- see the gold row. OWNED and
				-- SOON deliberately keep the shared sun/sandDeep: those two are STATES
				-- and reading the same on every row is the point of them.
				PanelKit.retint(r.face, r.slab, r.liveTint or C.grape)
			else
				r.live = false
				r.cost.Text = "SOON"
				PanelKit.retint(r.face, r.slab, C.sandDeep)
			end
			-- Knocked back rather than greyed: the face is already the wrong colour
			-- to press, and a second cue on the type is what stops SOON reading as a
			-- price you have not looked at properly.
			r.cost.TextTransparency = r.live and 0 or 0.15

			-- And the same state again over the artwork, where there is any. The
			-- banner carries its own price, so a live row needs no overlay at all --
			-- this only ever draws the two states the picture cannot say itself.
			if r.veil then
				r.stamp.Text = owned and "OWNED" or "SOON"
				r.veil.Visible = not r.live
			end
		end
	end
	panels.Shop.refresh = paint
	paint()

	--[[
		THE COIN SHELF, and how the rest of the game gets to it.

		Running out of coins is the one moment a player is guaranteed to want the
		coin packs, and until now it was also the moment the game told them no and
		left them standing there. MenuHud.start() listens for a refusal carrying a
		shortfall and calls these two.

		PRICE, NOT `live`, is what decides whether there is anything to show. The
		`live` flag is set by paint(), and paint only runs on a panel that is OPEN
		-- so a shop nobody has opened since the boot-time price sweep landed would
		still be carrying live = false on every row and would answer "no coins for
		sale" wrongly. PassConfig.price reads the replicated attribute directly and
		is right whether or not this panel has ever been looked at.
	]]
	-- IS THERE A COIN SHELF AT ALL. Not "is anything on sale" -- the shelf row is
	-- a door rather than a price (see paint) and the rungs behind it draw their
	-- own state. This only answers whether the shop has coins to show, because a
	-- refusal must not open a screen that does not address the thing that sent
	-- the player there.
	panels.Shop.hasCoins = function(): boolean
		for _, r in shopRows do
			if r.item.kind == "coinshelf" and #(r.item.tiers or {}) > 0 then
				return true
			end
		end
		return false
	end

	-- WHICH PANEL A REFUSAL SHOULD LAND ON. The shelf is its own panel now, so
	-- the answer is "Coins" rather than the shop list with a scroll offset --
	-- landing on the list would make the player press one more button to reach
	-- the thing they were sent for. Falls back to the list if the panel was never
	-- built, which only happens when there is no shelf.
	panels.Shop.coinPanel = function(): string
		return panels.Coins and "Coins" or "Shop"
	end

	--[[
		THE JIGGLE, and it fires on OPEN only -- see the note in openPanel about why
		this is not hung off refresh.

		Two motions at once, which is what stops it reading as a glitch: the whole
		banner punches in from 88% with Back easing (the same arrival every panel in
		the game uses, so it belongs), and rocks through a decaying ±3.5 degrees
		while it settles. Past about 5 degrees the artwork's own text visibly
		skews, which reads as broken rather than as lively -- the same ceiling
		flashy() found on the rail's shop key.

		The token is what stops two opens overlapping: reopen the shop mid-wobble
		and the older sequence sees a stale token and stops rather than fighting the
		new one back and forth.
	]]
	local jiggleToken = 0
	if banner and bannerScale then
		panels.Shop.onOpen = function()
			jiggleToken += 1
			local mine = jiggleToken
			bannerScale.Scale = 0.88
			banner.Rotation = 0
			TweenService:Create(bannerScale, TweenInfo.new(0.42, Enum.EasingStyle.Back,
				Enum.EasingDirection.Out), { Scale = 1 }):Play()
			task.spawn(function()
				for _, step in ipairs({ { -3.5, 0.09 }, { 2.6, 0.10 }, { -1.4, 0.10 },
					{ 0.6, 0.10 }, { 0, 0.12 } }) do
					if jiggleToken ~= mine or not banner.Parent then
						return
					end
					TweenService:Create(banner, TweenInfo.new(step[2], Enum.EasingStyle.Sine,
						Enum.EasingDirection.InOut), { Rotation = step[1] }):Play()
					task.wait(step[2])
				end
			end)
		end
	end

	-- Ownership: one signal per pass, and they fire whenever GamePassService
	-- finishes asking Roblox -- on join, and again the moment a purchase lands.
	for _, r in shopRows do
		if r.item.attribute then
			player:GetAttributeChangedSignal(r.item.attribute):Connect(paint)
		end
	end

	--[[
		Prices: the folder is published on a thread at boot, so a client that opens
		this panel in the first second sees SOON on everything and must not be left
		there. WaitForChild with a timeout rather than an indefinite wait -- if the
		folder never arrives the shop still draws, it just draws honestly.
	]]
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild(PassConfig.InfoFolder, 30)
		if folder then
			folder.AttributeChanged:Connect(paint)
			paint()
		end
	end)
end

local function buildSettings()
	--[=[
		600 TALL, MATCHING THE BEACH SHOP -- the tallest panel in the game and
		therefore the proven ceiling: at UiFit's 0.6 floor that is 360px, inside
		the ~414 a phone in landscape has. Anything taller is a number nothing
		else here has had to survive.

		The body is h - 74, so 526. The toggles fill 350 of it and the feedback
		block below takes 163 of the remaining 176.

		SIX TOGGLES IN THE SAME 350. The sixth came out of the ROWS rather than out
		of the panel: 600 is the ceiling above, and the feedback block starts at a
		fixed FEED_Y, so a taller list would simply have laid the last toggle across
		it. 54 with 5 between them is 349, and 54 still clears both of the things a
		row has to hold -- the 44-px icon tile and the 42-px pill.

		AND THE SEVENTH IS WHY THIS LIST NOW SCROLLS. That paragraph describes a
		budget with nothing left in it: seven rows is 408 against the 350 there is,
		and the row height cannot come down again without going under the 44-px tile
		it has to hold. The window stays 350 and the canvas grows past it instead --
		the same stockList shape every other list in this file uses -- so this is the
		last time a setting has to be paid for out of the panel's height.
	]=]
	local SET_W, SET_H = 540, 600
	-- SET_-prefixed, because there is already a module-level ROW_H (92, the shop's
	-- row) that a bare one here would shadow for the whole of this function.
	local SET_ROW_H, SET_ROW_PAD = 54, 5
	local root, body = makePanel("Settings", SET_W, SET_H, C.grape)
	panels.Settings = { root = root, w = SET_W, h = SET_H }

	-- Was fromScale(1, 1), which covered the whole body, then a bounded Frame so
	-- the toggle list ended where its rows ended rather than lying across the
	-- feedback box. A ScrollingFrame now, for the reason in the note above: the
	-- window is still the same 350 and the rows are free to overflow it.
	local list = Instance.new("ScrollingFrame")
	list.Name = "Rows"
	list.Size = UDim2.new(1, 0, 0, 350)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 8
	list.ScrollBarImageColor3 = C.wood
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.Parent = body
	local ly = Instance.new("UIListLayout")
	ly.Padding = UDim.new(0, SET_ROW_PAD)
	ly.SortOrder = Enum.SortOrder.LayoutOrder
	ly.Parent = list
	-- Clear of the scrollbar, matching stockList.
	local listPad = Instance.new("UIPadding")
	listPad.PaddingRight = UDim.new(0, 12)
	listPad.PaddingBottom = UDim.new(0, 6)
	listPad.Parent = list

	for i, opt in SETTINGS do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, SET_ROW_H)
		row.BackgroundColor3 = C.white
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		row.Parent = list
		corner(row, 16)
		outline(row, 3.5)
		grad(row, C.white, C.sand)

		--[[
			A ROW MAY DECIDE IT DOES NOT APPLY TO THIS PLAYER -- see `when` on the
			Skip the Wash Bay row, currently the only one that has one.

			BUILT AND HIDDEN rather than skipped, because the answer can change
			mid-session: a pass bought while the panel is open has to bring its
			row in without the list being torn down. UIListLayout ignores an
			invisible child, so a hidden row costs no height and leaves no gap.

			Watched on the PASS ATTRIBUTE rather than polled, which is the same
			signal CTB_HUD's QUICK SELL key repaints itself off.
		]]
		if opt.when then
			local function applyWhen()
				local ok, visible = pcall(opt.when)
				row.Visible = ok and visible == true
			end
			if opt.watch then
				player:GetAttributeChangedSignal(opt.watch):Connect(applyWhen)
			end
			applyWhen()
		end

		local tile = Instance.new("Frame")
		tile.Size = UDim2.fromOffset(44, 44)
		tile.Position = UDim2.fromOffset(10, (SET_ROW_H - 44) * 0.5)
		tile.BackgroundColor3 = C.grape
		tile.BorderSizePixel = 0
		tile.Parent = row
		corner(tile, 13)
		outline(tile, 3)
		grad(tile, C.grape:Lerp(C.white, 0.3), darken(C.grape, 0.2))
		gloss(tile, 13)
		local em = text(tile, opt.emoji, 22, Enum.Font.GothamBold, C.white)
		em.Size = UDim2.fromScale(1, 1)
		em.ZIndex = 6

		local nm = text(row, opt.name, 19, Enum.Font.LuckiestGuy, C.ink)
		nm.Position = UDim2.fromOffset(64, 0)
		nm.Size = UDim2.new(1, -180, 1, 0)
		nm.TextXAlignment = Enum.TextXAlignment.Left

		local saved = player:GetAttribute("Set_" .. opt.key)
		if saved == nil then saved = opt.default end

		local holder, face, get, set = pill(row, saved)
		holder.AnchorPoint = Vector2.new(1, 0.5)
		holder.Position = UDim2.new(1, -14, 0.5, 0)
		applySetting(opt.key, saved)

		TouchFit.press(face, function()
			local v = not get()
			set(v, true)
			applySetting(opt.key, v)
			saveSetting(opt.key, v)
		end)

		--[[
			THE RESTORE LANDING AFTER THIS ROW WAS BUILT -- see the note at the top of
			the SETTINGS section for why that is the normal case rather than the edge.

			GUARDED ON THE PILL'S OWN STATE, not on the attribute: applySetting writes
			the attribute itself, so comparing against it would be comparing a value
			with itself. `get()` is what the row is currently SHOWING, so this fires
			only when the server disagrees with the screen -- which is a restore, and
			never an echo of a press this row just made.

			Not saved back, for the reason on saveSetting.
		]]
		player:GetAttributeChangedSignal("Set_" .. opt.key):Connect(function()
			local v = player:GetAttribute("Set_" .. opt.key)
			if type(v) == "boolean" and v ~= get() then
				set(v, true)
				applySetting(opt.key, v)
			end
		end)
	end

	----------------------------------------------------------------
	-- HUD SIZE  --  the one row here that is not a switch
	----------------------------------------------------------------
	--[=[
		UiFit already sizes every HUD to the screen, and this rides on top of that
		fit as a multiplier rather than replacing it -- see the note over UiFit.STEPS
		for why a preference has to be separate from a measurement, and why the four
		steps are taps rather than a slider.

		BUILT AFTER THE LOOP, NOT ADDED TO `SETTINGS`. Every row in that table is a
		boolean with a sliding pill; this one cycles through four named steps. Giving
		the table a `kind` field would have meant six rows carrying a discriminator
		that only the seventh ever reads.

		IT CHANGES THE PANEL IT IS DRAWN IN, WHICH IS THE POINT AND THE HAZARD. The
		press re-fits every ScreenGui including this one, so the row moves under the
		finger that pressed it. That is the correct feedback -- you see exactly what
		you bought -- and it is why the control is a CYCLE rather than four buttons
		in a row: there is one target, it stays under the cursor, and it is still
		there at every size.

		FIRST IN THE LIST, AND THAT WAS MEASURED. The window is 350 and seven rows
		are 408, so exactly one row is below the fold -- and when this was added at
		the END, the row you had to scroll for was the one a player who cannot read
		the HUD is looking for. It is also the only row here that is about being able
		to USE the panel rather than a preference about the game, which is the other
		half of the argument for putting it at the top.
	]=]
	local scaleRow = Instance.new("Frame")
	scaleRow.Name = "HudScale"
	scaleRow.Size = UDim2.new(1, 0, 0, SET_ROW_H)
	scaleRow.BackgroundColor3 = C.white
	scaleRow.BorderSizePixel = 0
	-- Ahead of every toggle: SETTINGS rows use LayoutOrder i, starting at 1.
	scaleRow.LayoutOrder = 0
	scaleRow.Parent = list
	corner(scaleRow, 16)
	outline(scaleRow, 3.5)
	grad(scaleRow, C.white, C.sand)

	local scaleTile = Instance.new("Frame")
	scaleTile.Size = UDim2.fromOffset(44, 44)
	scaleTile.Position = UDim2.fromOffset(10, (SET_ROW_H - 44) * 0.5)
	scaleTile.BackgroundColor3 = C.grape
	scaleTile.BorderSizePixel = 0
	scaleTile.Parent = scaleRow
	corner(scaleTile, 13)
	outline(scaleTile, 3)
	grad(scaleTile, C.grape:Lerp(C.white, 0.3), darken(C.grape, 0.2))
	gloss(scaleTile, 13)
	-- Two arrows pointing apart. DRAWN rather than typed for the reason the X
	-- glyphs in this file are: the display font has no fallback for the newer
	-- symbols and they come out as a blank box while still measuring.
	local scaleGlyph = text(scaleTile, "\226\134\148", 22, Enum.Font.GothamBold, C.white)
	scaleGlyph.Size = UDim2.fromScale(1, 1)
	scaleGlyph.ZIndex = 6

	local scaleName = text(scaleRow, "HUD Size", 19, Enum.Font.LuckiestGuy, C.ink)
	scaleName.Position = UDim2.fromOffset(64, 0)
	scaleName.Size = UDim2.new(1, -180, 1, 0)
	scaleName.TextXAlignment = Enum.TextXAlignment.Left

	-- The same 96x42 footprint the pills keep, so the right-hand edge of this
	-- column stays a straight line down the panel.
	local stepHolder = Instance.new("Frame")
	stepHolder.Name = "StepHolder"
	stepHolder.Size = UDim2.fromOffset(96, 42)
	stepHolder.AnchorPoint = Vector2.new(1, 0.5)
	stepHolder.Position = UDim2.new(1, -14, 0.5, 0)
	stepHolder.BackgroundTransparency = 1
	stepHolder.Parent = scaleRow

	local stepSlab = Instance.new("Frame")
	stepSlab.Size = UDim2.fromOffset(96, 38)
	stepSlab.Position = UDim2.fromOffset(0, 5)
	stepSlab.BackgroundColor3 = darken(C.grape, 0.45)
	stepSlab.BorderSizePixel = 0
	stepSlab.Parent = stepHolder
	corner(stepSlab, 19)
	outline(stepSlab, 3.5)

	local stepFace = Instance.new("TextButton")
	stepFace.Name = "Step"
	stepFace.Size = UDim2.fromOffset(96, 38)
	stepFace.BackgroundColor3 = C.grape
	stepFace.BorderSizePixel = 0
	stepFace.AutoButtonColor = false
	stepFace.Text = ""
	stepFace.Parent = stepHolder
	corner(stepFace, 19)
	outline(stepFace, 3.5)

	local stepLabel = text(stepFace, "", 15, Enum.Font.LuckiestGuy, C.white)
	stepLabel.Size = UDim2.fromScale(1, 1)
	stepLabel.ZIndex = 6
	punch(stepLabel, 2.5)

	--[=[
		THE ONE SAVED ROW IN THIS PANEL, and the six switches above it are still not.

		The note at the top of the SETTINGS section says settings live entirely on
		the client, and for those six it is still true. This one is the exception,
		because forgetting it is the whole problem: every other row is a taste you
		notice and flip back, and this one is the size of the interface you would use
		to flip it back. SettingsServer's header carries the full argument and the
		whitelist that keeps the remote honest.

		SO THE ATTRIBUTE HAS TWO WRITERS NOW, and they agree by construction. The
		client writes it on a press for instant feedback; the server writes it on a
		join from the profile, and again when it accepts a press. Both write the same
		step key, so the second write of a pair changes nothing and fires no signal.

		THE LISTENER BELOW IS WHAT MAKES A RESTORE LAND. This panel is BUILT AT BOOT
		(see the note at the foot of this file) and a profile takes a datastore round
		trip, so the saved value very nearly always arrives AFTER this row has drawn
		itself at the default. Without the listener the setting would appear to work
		and then be forgotten on every join -- which is exactly the bug it exists to
		fix, wearing a different hat.
	]=]
	local SCALE_ATTR = "Set_HudScale"

	local function stepIndex(): number
		local want = player:GetAttribute(SCALE_ATTR) or UiFit.DEFAULT_STEP
		for i, s in ipairs(UiFit.STEPS) do
			if s.key == want then
				return i
			end
		end
		return 2
	end

	-- `save` is false when the change CAME from the server, which is what stops a
	-- restore bouncing straight back as a save of the value we were just given.
	local function applyStep(i: number, animate: boolean?, save: boolean?)
		local step = UiFit.STEPS[i] or UiFit.stepFor(UiFit.DEFAULT_STEP)
		player:SetAttribute(SCALE_ATTR, step.key)
		stepLabel.Text = step.label
		UiFit.setUserScale(step.mult)
		if save then
			saveSetting("HudScale", step.key)
		end
		if animate then
			-- The same detent the pills give, so the two controls feel like one set.
			TweenService:Create(stepFace, TweenInfo.new(0.16, Enum.EasingStyle.Back,
				Enum.EasingDirection.Out), { BackgroundColor3 = C.grape }):Play()
		end
	end

	-- Not saved: this is drawing whatever is already on the player, which is the
	-- default on a fresh join and the restored value if the profile beat us here.
	applyStep(stepIndex(), false, false)

	TouchFit.press(stepFace, function()
		-- Wraps, so four steps are reachable from any of them without a second
		-- control -- and so the smallest is one press from the largest rather than
		-- three.
		applyStep((stepIndex() % #UiFit.STEPS) + 1, true, true)
	end)

	-- The restore landing after this row was built -- see the note above. Also
	-- covers the server correcting a value it would not accept. Not saved back,
	-- and guarded on the label so the server echoing a press cannot loop.
	player:GetAttributeChangedSignal(SCALE_ATTR):Connect(function()
		local step = UiFit.STEPS[stepIndex()]
		if step and step.label ~= stepLabel.Text then
			applyStep(stepIndex(), false, false)
		end
	end)

	----------------------------------------------------------------
	-- AUTO-RELEASE PETS
	----------------------------------------------------------------
	--[=[
		THE SECOND CYCLING ROW, AND IT IS BUILT FROM THE HUD SIZE ROW ABOVE.

		Same shape, same 96x42 pill, same three states of the save contract -- draw
		what is on the player, write on a press, redraw without saving when the
		server corrects it. Copied deliberately rather than factored out: two rows
		is not a pattern yet, and the one thing that would go wrong with a shared
		helper is the bit that differs (one stores a string key, the other a number).

		LAST IN THE PANEL, where HUD Size is first. The argument for HUD Size being
		top is that it is about being able to USE the panel; this is the opposite --
		a setting you come looking for once you have hundreds of pets, and one a new
		player should not meet before they have their first.

		WHY IT IS IN SETTINGS RATHER THAN THE PETS PANEL, which is where it was
		asked for: it is a persisted PREFERENCE, and every one of those in this game
		lives here and rides SettingsServer's whitelist. A copy of that plumbing in
		the Pets panel would be a second way to save a setting. The cost is
		discoverability, and it is real -- see the line the Pets panel prints under
		its tray when the filter is on, which is what closes that gap.
	]=]
	local petRow = Instance.new("Frame")
	petRow.Name = "PetAutoRelease"
	petRow.Size = UDim2.new(1, 0, 0, SET_ROW_H)
	petRow.BackgroundColor3 = C.white
	petRow.BorderSizePixel = 0
	petRow.LayoutOrder = 99
	petRow.Parent = list
	corner(petRow, 16)
	outline(petRow, 3.5)
	grad(petRow, C.white, C.sand)

	local petTile = Instance.new("Frame")
	petTile.Size = UDim2.fromOffset(44, 44)
	petTile.Position = UDim2.fromOffset(10, (SET_ROW_H - 44) * 0.5)
	petTile.BackgroundColor3 = C.coral
	petTile.BorderSizePixel = 0
	petTile.Parent = petRow
	corner(petTile, 13)
	outline(petTile, 3)
	grad(petTile, C.coral:Lerp(C.white, 0.3), darken(C.coral, 0.2))
	gloss(petTile, 13)
	local petGlyph = text(petTile, "\240\159\166\180", 22, Enum.Font.GothamBold, C.white)
	petGlyph.Size = UDim2.fromScale(1, 1)
	petGlyph.ZIndex = 6

	--[[
		THE ONLY ROW HERE WITH A SUB-LINE, AND IT EARNED ONE.  2026-09-13

		Reported as "Auto release doesn't work", from a rebirth-31 player. It works:
		measured on a live pull with the floor at RARE, nine of ten hatches came
		back "Auto-released 9 below RARE". What does not work is the SENTENCE.

		The reporter had it set to LEGENDARY and was holding 4 Common, 11 Uncommon,
		8 Rare and 7 Epic in a bag that was only 36 of 250 -- so nothing was even
		near full. Those thirty pets were caught BEFORE they turned the setting on,
		and "Auto-Release Below: LEGENDARY" reads like a promise about the bag you
		are looking at rather than about the next thing you hatch.

		IT IS A PULL FILTER, NOT A BAG SWEEP, and it stays one. Making it sweep
		would have it destroy pets a player already owns the moment a dropdown
		moves -- the exact shape of the lost-Mythic report that put two-tap arming
		on the release tiles in the first place. The sweep already exists, with its
		own confirm card, and it is called TIDY. So the row says which of the two
		it is and points at the other.

		Name and sub are laid out by hand rather than centred in the row, because
		SET_ROW_H is 54 and two lines have to sit in it: 8..30 and 31..46.
	]]
	local petName = text(petRow, "Auto-Release Below", 19, Enum.Font.LuckiestGuy, C.ink)
	petName.Position = UDim2.fromOffset(64, 8)
	petName.Size = UDim2.new(1, -180, 0, 22)
	petName.TextXAlignment = Enum.TextXAlignment.Left

	-- 220px of the 324 the box has at the narrowest row width, measured.
	local petSub = text(petRow, "New hatches only \u{2014} TIDY clears your bag", 12,
		Enum.Font.GothamMedium, Color3.fromRGB(140, 118, 92))
	petSub.Position = UDim2.fromOffset(64, 31)
	petSub.Size = UDim2.new(1, -180, 0, 15)
	petSub.TextXAlignment = Enum.TextXAlignment.Left

	local petHolder = Instance.new("Frame")
	petHolder.Name = "StepHolder"
	petHolder.Size = UDim2.fromOffset(96, 42)
	petHolder.AnchorPoint = Vector2.new(1, 0.5)
	petHolder.Position = UDim2.new(1, -14, 0.5, 0)
	petHolder.BackgroundTransparency = 1
	petHolder.Parent = petRow

	local petSlab = Instance.new("Frame")
	petSlab.Size = UDim2.fromOffset(96, 38)
	petSlab.Position = UDim2.fromOffset(0, 5)
	petSlab.BackgroundColor3 = darken(C.coral, 0.45)
	petSlab.BorderSizePixel = 0
	petSlab.Parent = petHolder
	corner(petSlab, 19)
	outline(petSlab, 3.5)

	local petFace = Instance.new("TextButton")
	petFace.Name = "Step"
	petFace.Size = UDim2.fromOffset(96, 38)
	petFace.BackgroundColor3 = C.coral
	petFace.BorderSizePixel = 0
	petFace.AutoButtonColor = false
	petFace.Text = ""
	petFace.Parent = petHolder
	corner(petFace, 19)
	outline(petFace, 3.5)
	gloss(petFace, 19)

	-- 13, not the 15 the HUD Size pill uses: "LEGENDARY" is the longest label in
	-- this game's rarity ladder and it does not fit the same 96px at 15.
	local petLabel = text(petFace, "OFF", 13, Enum.Font.LuckiestGuy, C.white)
	petLabel.Size = UDim2.fromScale(1, 1)
	petLabel.ZIndex = 6
	punch(petLabel, 2)

	local PET_ATTR = PetConfig.AutoReleaseAttribute

	local function petStepIndex(): number
		local want = PetConfig.autoReleaseFloor(player)
		for i, s in ipairs(PetConfig.AutoReleaseSteps) do
			if s.index == want then
				return i
			end
		end
		return 1
	end

	local function applyPetStep(i: number, animate: boolean?, save: boolean?)
		local step = PetConfig.AutoReleaseSteps[i] or PetConfig.AutoReleaseSteps[1]
		player:SetAttribute(PET_ATTR, step.index)
		petLabel.Text = step.label
		-- OFF wears the dead colour the SOON rows do, so "this is doing nothing"
		-- reads at a glance rather than having to be read.
		local tint = (step.index > 0) and C.coral or C.sandDeep
		petFace.BackgroundColor3 = tint
		petSlab.BackgroundColor3 = darken(tint, 0.45)
		if save then
			saveSetting("PetAutoRelease", step.index)
		end
		if animate then
			TweenService:Create(petFace, TweenInfo.new(0.16, Enum.EasingStyle.Back,
				Enum.EasingDirection.Out), { BackgroundColor3 = tint }):Play()
		end
	end

	applyPetStep(petStepIndex(), false, false)

	TouchFit.press(petFace, function()
		applyPetStep((petStepIndex() % #PetConfig.AutoReleaseSteps) + 1, true, true)
	end)

	player:GetAttributeChangedSignal(PET_ATTR):Connect(function()
		local step = PetConfig.AutoReleaseSteps[petStepIndex()]
		if step and step.label ~= petLabel.Text then
			applyPetStep(petStepIndex(), false, false)
		end
	end)

	----------------------------------------------------------------
	-- TIME OF DAY
	----------------------------------------------------------------
	--[=[
		DAY / DUSK / NIGHT. Asked for on 2026-09-11 by a player three tides in:
		"can you make it night time option? the light from the sane area hurts my
		eyes". The game pins noon and the playfield is pale sand, so an hour of it
		is a genuinely bright hour.

		THE THIRD CYCLING ROW, built from the same parts as the two above it. What
		is different is only what a press means: this one writes a preference that
		LightingLock reads, and LightingLock is the only thing in the game allowed
		to touch Lighting.ClockTime. Nothing here writes lighting directly -- the
		file that owns the clock keeps owning it.

		PLACED LAST, below the pet filter, for the reason the HUD Size row is
		placed first: that one is about being able to USE the panel and belongs at
		the top. This is a comfort preference somebody goes looking for.
	]=]
	local skyRow = Instance.new("Frame")
	skyRow.Name = "Daylight"
	skyRow.Size = UDim2.new(1, 0, 0, SET_ROW_H)
	skyRow.BackgroundColor3 = C.white
	skyRow.BorderSizePixel = 0
	skyRow.LayoutOrder = 100
	skyRow.Parent = list
	corner(skyRow, 16)
	outline(skyRow, 3.5)
	grad(skyRow, C.white, C.sand)

	local skyTile = Instance.new("Frame")
	skyTile.Size = UDim2.fromOffset(44, 44)
	skyTile.Position = UDim2.fromOffset(10, (SET_ROW_H - 44) * 0.5)
	skyTile.BackgroundColor3 = C.sea
	skyTile.BorderSizePixel = 0
	skyTile.Parent = skyRow
	corner(skyTile, 13)
	outline(skyTile, 3)
	grad(skyTile, C.sea:Lerp(C.white, 0.3), darken(C.sea, 0.2))
	gloss(skyTile, 13)
	local skyGlyph = text(skyTile, "\240\159\140\153", 22, Enum.Font.GothamBold, C.white)
	skyGlyph.Size = UDim2.fromScale(1, 1)
	skyGlyph.ZIndex = 6

	local skyName = text(skyRow, "Time of Day", 19, Enum.Font.LuckiestGuy, C.ink)
	skyName.Position = UDim2.fromOffset(64, 0)
	skyName.Size = UDim2.new(1, -180, 1, 0)
	skyName.TextXAlignment = Enum.TextXAlignment.Left

	local skyHolder = Instance.new("Frame")
	skyHolder.Name = "StepHolder"
	skyHolder.Size = UDim2.fromOffset(96, 42)
	skyHolder.AnchorPoint = Vector2.new(1, 0.5)
	skyHolder.Position = UDim2.new(1, -14, 0.5, 0)
	skyHolder.BackgroundTransparency = 1
	skyHolder.Parent = skyRow

	local skySlab = Instance.new("Frame")
	skySlab.Size = UDim2.fromOffset(96, 38)
	skySlab.Position = UDim2.fromOffset(0, 5)
	skySlab.BackgroundColor3 = darken(C.sea, 0.45)
	skySlab.BorderSizePixel = 0
	skySlab.Parent = skyHolder
	corner(skySlab, 19)
	outline(skySlab, 3.5)

	local skyFace = Instance.new("TextButton")
	skyFace.Name = "Step"
	skyFace.Size = UDim2.fromOffset(96, 38)
	skyFace.BackgroundColor3 = C.sea
	skyFace.BorderSizePixel = 0
	skyFace.AutoButtonColor = false
	skyFace.Text = ""
	skyFace.Parent = skyHolder
	corner(skyFace, 19)
	outline(skyFace, 3.5)
	gloss(skyFace, 19)

	local skyLabel = text(skyFace, "DAY", 15, Enum.Font.LuckiestGuy, C.white)
	skyLabel.Size = UDim2.fromScale(1, 1)
	skyLabel.ZIndex = 6
	punch(skyLabel, 2)

	local function skyStepIndex(): number
		return DaylightConfig.stepFor(player).index or 1
	end

	local function applySkyStep(i: number, animate: boolean?, save: boolean?)
		local step = DaylightConfig.Steps[i] or DaylightConfig.Steps[1]
		player:SetAttribute(DaylightConfig.Attribute, step.key)
		skyLabel.Text = step.label
		-- DAY wears the dead colour the SOON rows use: it is the rung that does
		-- nothing, and "nothing" should read at a glance.
		local tint = (step.hour ~= nil) and C.sea or C.sandDeep
		skyFace.BackgroundColor3 = tint
		skySlab.BackgroundColor3 = darken(tint, 0.45)
		if save then
			saveSetting(DaylightConfig.SettingKey, step.key)
		end
		if animate then
			TweenService:Create(skyFace, TweenInfo.new(0.16, Enum.EasingStyle.Back,
				Enum.EasingDirection.Out), { BackgroundColor3 = tint }):Play()
		end
	end

	applySkyStep(skyStepIndex(), false, false)

	TouchFit.press(skyFace, function()
		applySkyStep((skyStepIndex() % #DaylightConfig.Steps) + 1, true, true)
	end)

	player:GetAttributeChangedSignal(DaylightConfig.Attribute):Connect(function()
		local step = DaylightConfig.Steps[skyStepIndex()]
		if step and step.label ~= skyLabel.Text then
			applySkyStep(skyStepIndex(), false, false)
		end
	end)

	----------------------------------------------------------------
	-- FEEDBACK
	----------------------------------------------------------------
	--[=[
		THE ONE THING IN THIS PANEL THAT LEAVES THE CLIENT.

		Everything above is a personal preference written to an attribute and
		applied on the spot -- see the note at the top of this section. This is a
		message to the people who made the game, so it is the one control here
		with a server on the other end of it: FeedbackServer writes it to the
		PlayerFeedback DataStore, which is read in the Creator Dashboard.

		THE REMOTES RESOLVE IN THE BACKGROUND. buildSettings runs while the HUD
		is still being assembled, and a WaitForChild here would stall the entire
		menu until the server came up -- or for thirty seconds if it never did.
		So the box is built immediately and simply has nothing to fire until the
		folder appears; the button says so if it is pressed first.

		THE CLIENT CHECKS NOTHING THE SERVER TRUSTS. The length cap and the
		minimum below are so the counter cannot lie and so an empty press gets an
		instant answer instead of a round trip. FeedbackServer re-derives both,
		because everything here is reachable by anyone with an exploit.
	]=]
	local FEED_Y = 360
	local MAX_CHARS = 400
	local MIN_CHARS = 4
	local DIM = Color3.fromRGB(150, 128, 102)

	local sending = false
	local submitEv = nil

	--[=[
		FRAME RATE, SAMPLED WHILE THEY PLAY -- not when the panel opens.

		By the time this panel is up the world is behind a scrim with nothing
		moving in it, so a reading taken here would be the frame rate of a menu
		and would flatter every device that reports one. Two additions a frame is
		the price of the number being worth having.

		The low-water mark skips the first two samples: joining spikes to single
		digits while the place streams in, and a worst-FPS that always says 6 is
		a field nobody can use.
	]=]
	local fpsNow, fpsLow = 0, math.huge
	do
		local acc, frames, samples = 0, 0, 0
		RunService.RenderStepped:Connect(function(dt)
			acc += dt
			frames += 1
			if acc >= 1 then
				fpsNow = math.floor(frames / acc + 0.5)
				samples += 1
				if samples > 2 and fpsNow < fpsLow then
					fpsLow = fpsNow
				end
				acc, frames = 0, 0
			end
		end)
	end

	--[=[
		WHAT THEY ARE PLAYING ON, sent with the message.

		"It lags" and "the button does nothing" are unanswerable without this.

		EVERY FIELD HERE WAS PROBED, NOT ASSUMED, and two of the obvious ones
		turned out to be unavailable to a normal script:

			UserInputService:GetPlatform()  RobloxScriptSecurity. Platform is
			                                derived from input capabilities
			                                instead, which is the documented way
			                                and is why "Touch laptop" is a case.
			UserGameSettings.MasterVolume   RobloxScriptSecurity. Not recorded.

		SavedQualityLevel, IsTenFootInterface, GetTotalMemoryUsageMb and both
		locale ids all read fine and are here. The two locales are separately
		useful: RobloxLocaleId is the language they picked, SystemLocaleId is
		where the device thinks it is, and they disagree more often than not.

		None of this is trusted -- FeedbackServer whitelists, types and clamps
		every field before it is stored. It is context on a bug report.
	]=]
	local function deviceSnapshot()
		local touch, kb = UserInputService.TouchEnabled, UserInputService.KeyboardEnabled
		local vr = UserInputService.VREnabled

		local tenFoot = false
		pcall(function()
			tenFoot = GuiService:IsTenFootInterface()
		end)

		local platform
		if vr then
			platform = "VR"
		elseif tenFoot then
			platform = "Console"
		elseif touch and not kb then
			platform = "Mobile"
		elseif touch then
			platform = "Touch laptop"
		else
			platform = "Desktop"
		end

		local quality, memoryMb
		pcall(function()
			quality = UserSettings():GetService("UserGameSettings").SavedQualityLevel.Value
		end)
		pcall(function()
			memoryMb = Stats:GetTotalMemoryUsageMb()
		end)

		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize

		-- Read off the attributes applySetting writes, so this is what is
		-- actually in force rather than what the pills happen to be drawn as.
		local settings = {}
		for _, opt in SETTINGS do
			local v = player:GetAttribute("Set_" .. opt.key)
			if v == nil then
				v = opt.default
			end
			settings[opt.key] = v and true or false
		end

		return {
			platform = platform,
			touch = touch,
			keyboard = kb,
			mouse = UserInputService.MouseEnabled,
			gamepad = UserInputService.GamepadEnabled,
			vr = vr,
			tenFoot = tenFoot,
			viewport = vp and string.format("%dx%d", vp.X, vp.Y) or nil,
			quality = quality,
			memoryMb = memoryMb,
			fps = fpsNow,
			fpsLow = (fpsLow < math.huge) and fpsLow or nil,
			locale = LocalizationService.RobloxLocaleId,
			systemLocale = LocalizationService.SystemLocaleId,
			settings = settings,
		}
	end

	-- Light: this and the two labels below are drawn straight onto the board,
	-- which is dark wood now. The text box between them keeps its ink, because it
	-- has its own white field to sit on.
	local head = text(body, "TELL US WHAT YOU THINK", 17, Enum.Font.LuckiestGuy, C.sand)
	head.Position = UDim2.fromOffset(0, FEED_Y)
	head.Size = UDim2.new(1, 0, 0, 22)
	head.TextXAlignment = Enum.TextXAlignment.Left

	local boxHolder = Instance.new("Frame")
	boxHolder.Position = UDim2.fromOffset(0, FEED_Y + 28)
	boxHolder.Size = UDim2.new(1, 0, 0, 78)
	boxHolder.BackgroundColor3 = C.white
	boxHolder.BorderSizePixel = 0
	boxHolder.Parent = body
	corner(boxHolder, 14)
	outline(boxHolder, 3.5)

	local box = Instance.new("TextBox")
	box.Name = "FeedbackBox"
	box.Size = UDim2.fromScale(1, 1)
	box.BackgroundTransparency = 1
	-- FALSE. The default wipes what you typed the moment you click back into
	-- the box, which on a four-line message is the whole message.
	box.ClearTextOnFocus = false
	box.MultiLine = true
	box.TextWrapped = true
	box.Text = ""
	box.PlaceholderText = "Found a bug? Got an idea? Tell us here."
	box.PlaceholderColor3 = Color3.fromRGB(168, 148, 122)
	box.Font = Enum.Font.GothamMedium
	box.TextSize = 15
	box.TextColor3 = C.ink
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextYAlignment = Enum.TextYAlignment.Top
	box.ZIndex = 6
	box.Parent = boxHolder

	local boxPad = Instance.new("UIPadding")
	boxPad.PaddingLeft = UDim.new(0, 12)
	boxPad.PaddingRight = UDim.new(0, 12)
	boxPad.PaddingTop = UDim.new(0, 9)
	boxPad.PaddingBottom = UDim.new(0, 9)
	boxPad.Parent = box

	local count = text(body, "0/" .. MAX_CHARS, 13, Enum.Font.GothamBold, Color3.fromRGB(186, 164, 138))
	count.Position = UDim2.fromOffset(0, FEED_Y + 114)
	count.Size = UDim2.fromOffset(88, 42)
	count.TextXAlignment = Enum.TextXAlignment.Left

	--[[
		"THAT ALREADY EXISTS, AND IT IS ON THIS SCREEN."

		FOUR OF THE LIVE REPORTS ASK FOR A SWITCH THAT SHIPS. Whimsy asked for a
		way to reduce the flashing when washing (Flash Effects, on by default) and
		separately for a night mode; zero0steel asked for night mode too. Time of
		Day has offered DAY / DUSK / NIGHT the whole time.

		AND THE DAMNING PART IS WHERE THEY TYPED IT. This box lives INSIDE the
		Settings panel -- the switch Whimsy wanted was on screen, a few rows above
		the cursor, while they asked for it. So this is not "players cannot find
		Settings"; they were standing in it. The list simply did not answer the
		question they had in their head, because a player thinking "it flashes too
		much" is not scanning for the words "Flash Effects".

		So the hint is put where the asking happens rather than a mark on the rail
		key: a badge on the gear would have told Whimsy to open a panel they had
		already opened.

		IT NEVER BLOCKS THE SEND. The player may well have read the row and want
		something else -- Raven turned SFX off, found it too blunt and turned it
		back on, then asked for a volume slider, which is a real gap and not a
		miss. Telling that player "there is already a switch" and refusing them
		would be worse than the problem. It is a line of text; SEND is untouched.
	]]
	--[[
		EACH HINT CARRIES ITS OWN NAME, rather than looking one up in SETTINGS.

		That was the first shape and it was wrong: SETTINGS holds only the BOOLEAN
		rows. HUD Size, Auto-Release Below and Time of Day are built after the loop
		because they are multi-value, so a lookup found nothing for them -- and
		Time of Day is the single most useful thing in this table, since two of the
		four reports that prompted it asked for a night mode that has shipped all
		along.

		`untouched` is the value the row has for somebody who has never moved it:
		the boolean default, or "Day" for the daylight step. Anything else and the
		player has used the switch already and is telling us it is not enough.
	]]
	local HINTS = {
		-- Ordered: the first match wins, so the specific sits above the general.
		{ name = "Flash Effects", emoji = "\226\156\168", attr = "Set_Flash", untouched = true,
		  words = { "flash", "strobe", "blink", "white out", "whiteout" } },
		{ name = "Time of Day", emoji = "\240\159\140\153",
		  attr = "Set_" .. DaylightConfig.SettingKey, untouched = "Day",
		  words = { "night", "dusk", "evening", "dark mode", "darker", "time of day" } },
		{ name = "Helpful Tips", emoji = "\240\159\146\161",
		  attr = "Set_" .. TipConfig.SettingKey, untouched = true,
		  words = { "tip", "hint", "pop up", "popup", "pop-up" } },
		{ name = "Hide Sand Squares", emoji = "\226\172\156", attr = "Set_HideSquares", untouched = false,
		  words = { "square", "grid", "tile" } },
		{ name = "Hide Other Beachgoers", emoji = "\240\159\145\165", attr = "Set_HideOthers", untouched = false,
		  words = { "other player", "hide player", "other people", "crowd" } },
		{ name = "Hide Your Pets", emoji = "\240\159\144\190", attr = "Set_HidePets", untouched = false,
		  words = { "pet", "pets", "hide pet", "follower" } },
		{ name = "Hide Your Arms", emoji = "\240\159\145\144", attr = "Set_HideArms", untouched = false,
		  words = { "first person", "my arm", "arms visible" } },
		-- Added the same day the row was: the two players who asked for this are
		-- unlikely to be the last, and the next one should be told it is there.
		{ name = "Trade Requests", emoji = "\240\159\164\157", attr = "Set_TradeRequests", untouched = true,
		  words = { "trade request", "trading off", "turn off trade", "trade invite", "trade spam" } },
		{ name = "Screen Shake", emoji = "\240\159\146\165", attr = "Set_ScreenShake", untouched = true,
		  words = { "shake", "wobble" } },
		{ name = "Fancy Shadows", emoji = "\226\152\128", attr = "Set_Shadows", untouched = true,
		  words = { "shadow" } },
		{ name = "Beach Tunes", emoji = "\240\159\142\181", attr = "Set_Music", untouched = true,
		  words = { "music", "song", "soundtrack" } },
		-- Last of the audio rows on purpose: "sound" appears inside plenty of
		-- sentences about music, and Beach Tunes is the better answer to those.
		-- Above the general audio rows: "the water gun is too loud" should find
		-- the rig's own switch rather than the one that mutes the whole game.
		{ name = "Wash Bay Sounds", emoji = "\240\159\146\166", attr = "Set_WashSounds", untouched = true,
		  words = { "water gun", "wash sound", "sprayer", "hose", "washing is loud" } },
		{ name = "Sound Effects", emoji = "\240\159\148\138", attr = "Set_SFX", untouched = true,
		  words = { "sound effect", "sfx" } },
	}

	local function hintRow(typed: string)
		local low = string.lower(typed)
		for _, h in ipairs(HINTS) do
			for _, w in ipairs(h.words) do
				if string.find(low, w, 1, true) then
					--[[
						ONLY WHILE THE ROW IS STILL UNTOUCHED.

						Somebody who has already moved this switch knows perfectly
						well that it exists, and is asking for something the switch
						does not do -- Raven and the water gun exactly: they turned
						SFX off, found it too blunt, turned it back on and asked for
						a volume slider. Pointing at the row would read as not having
						listened.

						nil counts as untouched -- SettingsServer only writes the
						attribute once a value has been chosen or restored.
					]]
					local set = player:GetAttribute(h.attr)
					if set ~= nil and set ~= h.untouched then
						return nil
					end
					return h
				end
			end
		end
		return nil
	end

	local hint = text(body, "", 13, Enum.Font.GothamBold, Color3.fromRGB(255, 214, 120))
	hint.Position = UDim2.fromOffset(0, FEED_Y + 96)
	hint.Size = UDim2.new(1, 0, 0, 18)
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.TextTruncate = Enum.TextTruncate.AtEnd
	hint.Visible = false

	local function paintHint()
		local opt = (#box.Text >= 4) and hintRow(box.Text) or nil
		hint.Visible = opt ~= nil
		if opt then
			hint.Text = string.format("%s  Already a setting \u{2014} \"%s\", in the list above.",
				opt.emoji, opt.name)
		end
	end

	local status = text(body, "", 14, Enum.Font.GothamBold, Color3.fromRGB(226, 206, 176))
	status.Position = UDim2.fromOffset(92, FEED_Y + 114)
	status.Size = UDim2.new(1, -254, 0, 42)
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.TextWrapped = true
	status.TextTruncate = Enum.TextTruncate.None

	local sendHolder, sendFace = chunky(body, 150, 42, C.lime, 15)
	sendHolder.AnchorPoint = Vector2.new(1, 0)
	sendHolder.Position = UDim2.new(1, 0, 0, FEED_Y + 114)
	local sendLbl = text(sendFace, "SEND", 19, Enum.Font.LuckiestGuy, C.white)
	sendLbl.Size = UDim2.fromScale(1, 1)
	sendLbl.ZIndex = 6
	punch(sendLbl, 3)

	local function setStatus(msg: string, colour: Color3?)
		status.Text = msg
		status.TextColor3 = colour or C.ink
	end

	local function idle()
		sending = false
		sendLbl.Text = "SEND"
	end

	box:GetPropertyChangedSignal("Text"):Connect(function()
		if #box.Text > MAX_CHARS then
			-- Re-enters this handler; that pass paints the counter.
			box.Text = box.Text:sub(1, MAX_CHARS)
			return
		end
		count.Text = string.format("%d/%d", #box.Text, MAX_CHARS)
		paintHint()
		count.TextColor3 = (#box.Text >= MAX_CHARS) and C.coral or DIM
	end)

	TouchFit.press(sendFace, function()
		if sending then
			return
		end
		if not submitEv then
			setStatus("Still connecting -- one moment.", C.coral)
			return
		end
		local msg = box.Text:match("^%s*(.-)%s*$") or ""
		if #msg < MIN_CHARS then
			setStatus("Tell us a little more than that!", C.coral)
			return
		end

		sending = true
		sendLbl.Text = "..."
		setStatus("Sending...", DIM)
		submitEv:FireServer({ text = msg, client = deviceSnapshot() })

		-- The server answers every submission, but a reply that never arrives
		-- must not leave the button dead for the rest of the session.
		task.delay(10, function()
			if sending then
				idle()
				setStatus("No answer from the server -- try again.", C.coral)
			end
		end)
	end)

	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("FeedbackRemotes", 30)
		if not folder then
			warn("[MenuHud] FeedbackRemotes never appeared -- is FeedbackServer started?")
			setStatus("Feedback is offline right now.", C.coral)
			return
		end
		submitEv = folder:WaitForChild("SubmitFeedback")
		folder:WaitForChild("FeedbackResult").OnClientEvent:Connect(function(res)
			idle()
			if type(res) ~= "table" then
				return
			end
			setStatus(res.message or "", res.ok and C.limeDark or C.coral)
			-- Cleared only on success. A message that failed to send is still
			-- the only copy of what they wrote.
			if res.ok then
				box.Text = ""
			end
		end)
	end)
end

--------------------------------------------------------------------------
-- REWARDS
--------------------------------------------------------------------------
local rewardCards = {}
local rewardState = nil

-- Alert marks on the rail, by key name, so whoever owns a mark can switch it.
local railBadges = {}

-- Quest keys this player has actually laid eyes on. RewardsConfig gives every
-- quest a stable key ("d_earn", "m_kit"), so this survives the list being
-- reordered and cannot fire twice for the same quest.
local seenQuests = {}

--[[
	WHAT IS WAITING IN REWARDS, ANSWERED IN ONE PLACE.

	The tab strip inside the panel and the mark on the rail key outside it are
	asking the same question. Two copies of the answer drift the day a fourth
	page is added -- the dots would know about it and the rail would not.
]]
local function rewardsReady(snap)
	-- The COUNTS ride along for the CLAIM ALL buttons, which want a number rather
	-- than a yes. paintTabDots reads only the three named pages out of this, so
	-- the extra keys are invisible to it.
	local ready = {
		Daily = false, Quests = false, Playtime = false,
		nQuests = 0, nPlaytime = 0,
	}
	if not snap then
		return ready
	end
	ready.Daily = (snap.daily and not snap.daily.claimed) == true
	for _, q in ipairs(snap.quests or {}) do
		if q.ready then
			ready.Quests = true
			ready.nQuests += 1
		end
	end
	for _, t in ipairs(snap.playtime and snap.playtime.tiers or {}) do
		if t.ready then
			ready.Playtime = true
			ready.nPlaytime += 1
		end
	end
	return ready
end

--[[
	THE MARK ON THE RAIL KEY, which asks slightly more than the dots do.

	Anything claimable puts it up, and so does a quest this player has never
	opened the panel to see -- a quest nobody knows exists is not a goal, it is
	just a row waiting behind a button. On a fresh join nothing has been seen, so
	the mark is up until they look once; after that it only returns for a NEW
	quest or for something ready to claim.

	Before the first sync arrives there is nothing to be claimed about, so it
	stays down rather than guessing -- a mark that appears and then vanishes on
	its own reads as a glitch, not as news.
]]
local function rewardsWaiting(): boolean
	local snap = rewardState
	if not snap then
		return false
	end
	local ready = rewardsReady(snap)
	if ready.Daily or ready.Quests or ready.Playtime then
		return true
	end
	for _, q in ipairs(snap.quests or {}) do
		if q.key and not seenQuests[q.key] then
			return true
		end
	end
	return false
end

local function refreshRewardsAlert()
	local badge = railBadges.Rewards
	if badge then
		badge.Visible = rewardsWaiting()
	end
end

--[[
	AND THE SAME MARK WHEN A TIDE IS READY TO TURN.

	Two reports on 2026-09-17, both from phones and four hours apart:
	"I can't remember how to rebirth and I can't find how in the shop"
	(deathlydonut67), and "I keep forgetting to rebirth. Maybe a rebirth
	notification!" (Raven). They are the same miss from two directions -- one
	went looking and could not find it, the other was not thinking about it at
	all -- and the thing neither of them had is any sign that they were ELIGIBLE.

	The rail key has been there the whole time. What it never did was say when it
	mattered, so it read as furniture, and the second reporter had already
	rebirthed four times: this is not a player who cannot find the button, it is
	a player with no reason to look at it today.

	A BADGE RATHER THAN A POPUP, and that is deliberate rather than timid. The
	second report asks for a notification in as many words, and this game spent
	an update removing them -- "fun game but i hate the random pop ups.. ruins
	the calmness of the game", which is the row above Helpful Tips in Settings.
	Answering a request for a popup with a popup would trade one complaint for
	the one this game has already decided it cares about more. The mark is
	permanent while it is true, which is what "I keep forgetting" actually needs:
	it is still there the next time they look, and it costs nothing to ignore.

	`canRebirth` IS THE SERVER'S OWN ANSWER -- the same field the panel's BUY
	button reads two thousand lines up, so the mark and the button can never
	disagree about whether today is the day. Deliberately NOT `and not onShore`
	like that button is: standing on the AFK shore is a place you are, not a
	thing you lack, and a mark that blinked out when somebody wandered onto the
	idle dock would be the glitch the rewards note warns about.
]]
local function refreshRebirthAlert()
	local badge = railBadges.Rebirth
	if badge then
		-- Nothing before the first sync: there is nothing to be eligible ABOUT
		-- yet, and a mark that appears and then vanishes on its own reads as a
		-- glitch rather than as news.
		badge.Visible = (snapshot ~= nil) and snapshot.canRebirth == true
	end
end

-- Called when the panel is OPENED, not when it repaints: seeing the quests is
-- something the player does, not something a sync does to them.
local function markQuestsSeen()
	for _, q in ipairs(rewardState and rewardState.quests or {}) do
		if q.key then
			seenQuests[q.key] = true
		end
	end
end

local function mmss(sec)
	sec = math.max(0, math.floor(sec))
	return string.format("%d:%02d", sec // 60, sec % 60)
end

--[[
	THREE TABS, BECAUSE THERE ARE NOW THREE DIFFERENT PROMISES BEHIND THIS KEY.

		DAILY     come back tomorrow -- a streak ladder on the UTC day
		QUESTS    do a thing -- dailies that reset, milestones that never do
		PLAYTIME  stay a while -- the original session bounty, unchanged

	The playtime strip below is the panel that used to BE this panel, moved into
	a page and otherwise left alone: it was already the best-tuned thing in this
	file and a tab strip is no reason to redraw it.

	THE QUEST ROWS ARE BUILT FROM THE SNAPSHOT, NOT FROM A CLIENT-SIDE COPY OF
	THE QUEST LIST. The server already sends every field a row needs -- label,
	blurb, need, progress, payout -- so adding a quest to RewardsConfig makes it
	appear here with no change to this file at all. A second copy of the quest
	table on the client would be a second place to edit and a place for the two
	to disagree about what the player is being asked to do.
]]
local REW_W, REW_H = 690, 474
local questRows = {}      -- quest key -> the row's widgets
local ladderCells = {}    -- 1..7
local dailyUi = nil
local rewardPage = "Daily"
local rewardPages, rewardTabs = {}, {}

local function setRewardPage(key)
	rewardPage = key
	for name, frame in rewardPages do
		frame.Visible = (name == key)
	end
	for name, t in rewardTabs do
		local on = (name == key)
		PanelKit.retint(t.face, t.slab, on and t.tint or Color3.fromRGB(150, 140, 126))
		t.label.TextTransparency = on and 0 or 0.25
	end
end

local function buildRewards()
	local root, body, banner = makePanel("Rewards", REW_W, REW_H, C.lime)
	panels.Rewards = { root = root, w = REW_W, h = REW_H }

	--[[
		THE INVITE BUTTON, AND THE ONLY SOCIAL LOOP IN THE GAME.  2026-09-19.

		The game had none: no friend bonus, no invite, nothing rewarding bringing
		somebody or joining them. Trading was the only feature that even needed a
		second person, and it is gated behind a rebirth.

		IN THE BANNER, WHICH IS WHERE PanelKit SAYS A PANEL-WIDE ACTION GOES: "a
		button there is out of the content's way and reads as belonging to the whole
		panel rather than to a row. Mirror the X's geometry on the left." The car
		showroom's PUT AWAY is the other one of these, and this copies its geometry
		down to the ZIndex numbering -- this gui runs ZIndexBehavior.Global, where
		being the banner's child buys nothing and chunky() leaves its parts at 0, so
		an unnumbered button draws UNDER the banner it sits on.

		THE LABEL IS THE FEATURE'S ONLY EXPLANATION, so it carries the number rather
		than saying INVITE and leaving the bonus to be found. It reads "INVITE +10%"
		to somebody playing alone and "2 HERE +20%" once friends turn up: the same
		button teaches the rule and then reports it.

		WHY THE REWARDS PANEL. It is where the daily ladder, the playtime tiers and
		the quests already live -- the panel a player opens to ask "what else is
		there", which is the question this answers.
	]]
	do
		local inviteHolder, inviteFace, inviteSlab = chunky(banner, 168, 40, C.sea, 13)
		inviteHolder.Name = "Invite"
		inviteHolder.AnchorPoint = Vector2.new(0, 0.5)
		inviteHolder.Position = UDim2.new(0, 12, 0.5, -3)
		inviteHolder.ZIndex = 7
		inviteSlab.ZIndex = 7
		inviteFace.ZIndex = 8
		local inviteText = text(inviteFace, "INVITE", 15, Enum.Font.LuckiestGuy, C.white)
		inviteText.Size = UDim2.fromScale(1, 1)
		inviteText.ZIndex = 9
		punch(inviteText, 2.5)

		local function paintInvite()
			local n = BuddyConfig.countFor(player)
			local pct = math.floor(BuddyConfig.PerBuddy * 100 + 0.5)
			if n > 0 then
				inviteText.Text = string.format("%d HERE  +%d%%", n, n * pct)
			else
				inviteText.Text = string.format("INVITE  +%d%%", pct)
			end
		end
		paintInvite()
		player:GetAttributeChangedSignal(BuddyConfig.Attribute):Connect(paintInvite)

		--[[
			BOTH CALLS CAN THROW AND ONE OF THEM YIELDS.

			CanSendGameInviteAsync is a web call -- asked in a spawned thread so a slow
			answer cannot freeze the tap -- and on a client with no invite UI it throws
			rather than returning false. PromptGameInvite throws on the same clients.
			So both are pcall'd, and a failure says so once in the same voice every
			other unavailable thing in this game uses, rather than leaving a button
			that silently does nothing.
		]]
		TouchFit.press(inviteFace, function()
			task.spawn(function()
				local ok, can = pcall(function()
					return SocialService:CanSendGameInviteAsync(player)
				end)
				if not (ok and can) then
					ToastKit.toast("Invites are not available on this device.", "deny", 2.6)
					return
				end
				if not pcall(function() SocialService:PromptGameInvite(player) end) then
					ToastKit.toast("Invites are not available right now.", "deny", 2.6)
				end
			end)
		end)
	end

	----------------------------------------------------------------
	-- THE TAB STRIP
	----------------------------------------------------------------
	local strip = Instance.new("Frame")
	strip.Name = "Tabs"
	strip.Position = UDim2.fromOffset(0, 0)
	strip.Size = UDim2.new(1, 0, 0, 44)
	strip.BackgroundTransparency = 1
	strip.Parent = body
	local sl = Instance.new("UIListLayout")
	sl.FillDirection = Enum.FillDirection.Horizontal
	sl.Padding = UDim.new(0, 8)
	sl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	sl.Parent = strip

	local pageHost = Instance.new("Frame")
	pageHost.Name = "Pages"
	pageHost.Position = UDim2.fromOffset(0, 52)
	pageHost.Size = UDim2.new(1, 0, 1, -52)
	pageHost.BackgroundTransparency = 1
	pageHost.Parent = body

	local function page(name)
		local f = Instance.new("Frame")
		f.Name = name
		f.Size = UDim2.fromScale(1, 1)
		f.BackgroundTransparency = 1
		f.Visible = false
		f.Parent = pageHost
		rewardPages[name] = f
		return f
	end

	--[[
		CLAIM ALL -- one per page that can have several things waiting at once.

		IT ASKS FOR A PAGE, NOT A LIST. The payload is {kind = "claimAll", what =
		"quest"} and nothing more: RewardsServer walks its own config and re-tests
		every gate a single press would have tested, so this cannot claim anything
		one-at-a-time could not. Sending a list of what the panel believes is ready
		would be asking the client what it has earned.

		DIMMED, NOT HIDDEN, when there is nothing to take. A button that vanishes
		and reappears under a thumb already on its way down is how a mis-tap claims
		something the player never saw -- and it also stops the page shifting about
		as rewards come due. It says what it would do instead.

		The caller positions the holder: the quests page hangs it bottom-right off a
		list, the playtime page centres it under a centred strip.
	]]
	local function claimAllButton(parent, what)
		local holder, face, slab = chunky(parent, 186, 40, C.lime, 12)
		local label = text(face, "CLAIM ALL", 17, Enum.Font.LuckiestGuy, C.white)
		label.Size = UDim2.fromScale(1, 1)
		label.ZIndex = 6
		punch(label, 2.5)

		local live = false
		--[[
			TouchFit.activated, NOT a bare Activated:Connect.

			Activated was already the right SIGNAL -- it fires for a tap as well as
			a click, which is what the note here used to say and it was true. What
			it does not do is make the button big enough to tap. This face is built
			at 186x40 and the Rewards panel renders at about 0.6 on a phone, so it
			comes out 111x24 -- and it was the only control on the panel with no pad
			at all, while the tab strip six lines below has used TouchFit.press
			since it was written.

			That made CLAIM ALL, the primary action of two of the four pages, the
			smallest target on the panel. Measured on a 666x374 viewport.

			.activated rather than .press deliberately: the two signals hand their
			listener different arguments, and TouchFit keeps them apart for that
			reason -- see the note on the function.
		]]
		TouchFit.activated(face, function()
			if live then
				Net.get("ClaimReward"):FireServer({ kind = "claimAll", what = what })
			end
		end)

		return {
			holder = holder,
			set = function(n: number)
				live = n > 0
				label.Text = live and ("CLAIM ALL  " .. n) or "NOTHING READY"
				-- retint, not BackgroundColor3: chunky bakes a gradient from the
				-- colour it was built with, and a gradient multiplies against the
				-- fill under it -- so setting only the background gives mud.
				PanelKit.retint(face, slab, live and C.lime or C.sandDeep)
				label.TextTransparency = live and 0 or 0.3
			end,
		}
	end

	for i, t in ipairs({
		{ key = "Daily",    label = "DAILY",    tint = C.sun },
		{ key = "Quests",   label = "QUESTS",   tint = C.grape },
		{ key = "Playtime", label = "PLAYTIME", tint = C.lime },
		-- A FOURTH TAB FITS, and that was worth checking rather than assuming: the
		-- strip lays out horizontally at 154 wide with 8 of padding, so four come to
		-- 640 against the 654 this body has. A fifth would not, and whoever adds one
		-- has to narrow them all.
		{ key = "Codes",    label = "CODES",    tint = C.sea },
	}) do
		local holder, face, slab = chunky(strip, 154, 38, t.tint, 12)
		holder.LayoutOrder = i
		local l = text(face, t.label, 17, Enum.Font.LuckiestGuy, C.white)
		l.Size = UDim2.fromScale(1, 1)
		l.ZIndex = 6
		punch(l, 2.5)
		rewardTabs[t.key] = { face = face, slab = slab, label = l, tint = t.tint }
		TouchFit.press(face, function()
			setRewardPage(t.key)
			if panels.Rewards.refresh then panels.Rewards.refresh() end
		end)
	end

	----------------------------------------------------------------
	-- CODES
	----------------------------------------------------------------
	--[[
		WHERE A PLAYER TYPES A CODE.  2026-09-19.

		In the Rewards panel because that is where every other free thing in the
		game already lives -- the daily ladder, the playtime tiers and the quests --
		so it is the panel somebody opens to ask "what else can I get".

		THE CLIENT SENDS THE RAW STRING AND NOTHING ELSE. It does not check the code
		against CodeConfig before sending, even though it could: doing that would
		put a working oracle in every client, where a wrong guess and a right one
		look different without a round trip. CodeService answers both the same way.

		THE COUNT IS SHOWN AND THE CODES ARE NOT. "1 of 3 redeemed" tells a player
		there is something left to find, which is the whole point of announcing them
		somewhere -- and it leaks nothing, because the number of codes is not a
		secret and the strings are never sent to the client in a readable form they
		did not already have.
	]]
	do
		local cPage = page("Codes")

		local cHead = text(cPage, "ENTER A CODE", 21, Enum.Font.LuckiestGuy, C.sand)
		cHead.Position = UDim2.fromOffset(0, 0)
		cHead.Size = UDim2.new(1, 0, 0, 26)
		punch(cHead, 2.5)

		local cBlurb = text(cPage, "Codes are announced on the group and our socials.",
			14, Enum.Font.GothamMedium, Color3.fromRGB(226, 206, 176))
		cBlurb.Position = UDim2.fromOffset(0, 28)
		cBlurb.Size = UDim2.new(1, 0, 0, 20)

		local box = Instance.new("TextBox")
		box.Name = "CodeBox"
		box.AnchorPoint = Vector2.new(0.5, 0)
		box.Position = UDim2.new(0.5, 0, 0, 62)
		box.Size = UDim2.fromOffset(360, 48)
		box.BackgroundColor3 = Color3.fromRGB(255, 252, 244)
		box.BorderSizePixel = 0
		box.Font = Enum.Font.LuckiestGuy
		box.TextSize = 22
		box.TextColor3 = C.ink
		box.PlaceholderText = "type it here"
		box.PlaceholderColor3 = Color3.fromRGB(168, 148, 122)
		box.Text = ""
		box.ClearTextOnFocus = false
		-- Bounded at the box as well as at the server. The server is the one that
		-- counts; this just stops somebody pasting a novel into a 360px field.
		box.TextEditable = true
		box.MultiLine = false
		box.Parent = cPage
		corner(box, 14)
		outline(box, 3.5)

		local status = text(cPage, "", 14, Enum.Font.GothamBold,
			Color3.fromRGB(226, 206, 176))
		status.AnchorPoint = Vector2.new(0.5, 0)
		status.Position = UDim2.new(0.5, 0, 0, 174)
		status.Size = UDim2.new(1, 0, 0, 20)

		local function refreshCodes()
			local had, total = 0, 0
			for key in pairs(CodeConfig.ByCode) do
				total += 1
				if player:GetAttribute(CodeConfig.AttrPrefix .. key) == true then
					had += 1
				end
			end
			status.Text = (total > 0)
				and string.format("%d of %d redeemed", had, total)
				or ""
		end

		local function submit()
			local typed = box.Text
			if typed:gsub("%s", "") == "" then
				return
			end
			box.Text = ""
			Net.get("RedeemCode"):FireServer(typed)
		end

		local holder, face = chunky(cPage, 200, 44, C.lime, 13)
		holder.AnchorPoint = Vector2.new(0.5, 0)
		holder.Position = UDim2.new(0.5, 0, 0, 120)
		local rLabel = text(face, "REDEEM", 18, Enum.Font.LuckiestGuy, C.white)
		rLabel.Size = UDim2.fromScale(1, 1)
		rLabel.ZIndex = 6
		punch(rLabel, 3)
		TouchFit.press(face, submit)

		-- Enter submits too. `enterPressed` rather than every FocusLost: tapping
		-- away from the box on a phone should not spend the attempt.
		box.FocusLost:Connect(function(enterPressed)
			if enterPressed then
				submit()
			end
		end)

		-- The server stamps one attribute per redemption, so this is the signal that
		-- a code landed -- no second remote and nothing to keep in step.
		for key in pairs(CodeConfig.ByCode) do
			player:GetAttributeChangedSignal(CodeConfig.AttrPrefix .. key):Connect(refreshCodes)
		end
		refreshCodes()
	end

	----------------------------------------------------------------
	-- DAILY
	----------------------------------------------------------------
	local dPage = page("Daily")

	local dHead = text(dPage, "", 21, Enum.Font.LuckiestGuy, C.sand)
	dHead.Name = "Head"
	dHead.Position = UDim2.fromOffset(0, 0)
	dHead.Size = UDim2.new(1, 0, 0, 26)
	punch(dHead, 2.5)

	local dBlurb = text(dPage, "Log in on consecutive days and the bounty grows. Miss one and it starts again.",
		14, Enum.Font.GothamMedium, Color3.fromRGB(226, 206, 176))
	dBlurb.Position = UDim2.fromOffset(0, 28)
	dBlurb.Size = UDim2.new(1, 0, 0, 20)

	local rung = Instance.new("Frame")
	rung.Position = UDim2.fromOffset(0, 58)
	rung.Size = UDim2.new(1, 0, 0, 148)
	rung.BackgroundTransparency = 1
	rung.Parent = dPage
	local rl = Instance.new("UIListLayout")
	rl.FillDirection = Enum.FillDirection.Horizontal
	rl.Padding = UDim.new(0, 7)
	rl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rl.Parent = rung

	for i = 1, 7 do
		local cell = Instance.new("Frame")
		cell.Name = "D" .. i
		cell.Size = UDim2.fromOffset(84, 144)
		cell.BackgroundColor3 = C.white
		cell.BorderSizePixel = 0
		cell.LayoutOrder = i
		cell.Parent = rung
		corner(cell, 14)
		local cs = outline(cell, 3)
		local cg = grad(cell, C.white, C.sand)

		local dayL = text(cell, "DAY " .. i, 13, Enum.Font.LuckiestGuy, Color3.fromRGB(96, 78, 58))
		dayL.Position = UDim2.fromOffset(0, 8)
		dayL.Size = UDim2.new(1, 0, 0, 16)

		local coinL = text(cell, "", 19, Enum.Font.LuckiestGuy, C.sun)
		coinL.Position = UDim2.fromOffset(4, 52)
		coinL.Size = UDim2.new(1, -8, 0, 30)
		coinL.TextScaled = true
		local cap = Instance.new("UITextSizeConstraint")
		cap.MaxTextSize = 20
		cap.MinTextSize = 11
		cap.Parent = coinL
		punch(coinL, 2.5)

		-- A tick that only appears on rungs already behind the player. Drawn
		-- rather than typed, for the reason written up over the playtime tiles:
		-- an emoji is at the mercy of whatever glyph the device ships.
		local tickG = Instance.new("Frame")
		tickG.Name = "Tick"
		tickG.AnchorPoint = Vector2.new(0.5, 0)
		tickG.Position = UDim2.new(0.5, 0, 0, 96)
		tickG.Size = UDim2.fromOffset(34, 34)
		tickG.BackgroundColor3 = C.lime
		tickG.BorderSizePixel = 0
		tickG.Visible = false
		tickG.Parent = cell
		corner(tickG, 17)
		outline(tickG, 2.5)
		local t1 = ipart(tickG, 0.56, 0.16, 0.56, 0.44, C.white, 3, -45)
		t1.ZIndex = 7
		local t2 = ipart(tickG, 0.3, 0.16, 0.34, 0.58, C.white, 3, 45)
		t2.ZIndex = 7

		ladderCells[i] = { cell = cell, coin = coinL, tick = tickG, stroke = cs, grad = cg, day = dayL }
	end

	local dHolder, dFace, dSlab = chunky(dPage, 250, 54, C.lime, 16)
	dHolder.AnchorPoint = Vector2.new(0.5, 1)
	dHolder.Position = UDim2.new(0.5, 0, 1, -6)
	local dBtn = text(dFace, "CLAIM", 22, Enum.Font.LuckiestGuy, C.white)
	dBtn.Size = UDim2.fromScale(1, 1)
	dBtn.ZIndex = 6
	punch(dBtn, 3)
	TouchFit.press(dFace, function()
		Net.get("ClaimReward"):FireServer({ kind = "daily" })
	end)
	dailyUi = { head = dHead, face = dFace, slab = dSlab, label = dBtn, blurb = dBlurb }

	----------------------------------------------------------------
	-- QUESTS
	----------------------------------------------------------------
	local qPage = page("Quests")

	local qAll = claimAllButton(qPage, "quest")
	qAll.holder.AnchorPoint = Vector2.new(1, 1)
	-- -10 matches the list's own right padding, so the button sits under the last
	-- row's right edge rather than under its scrollbar.
	qAll.holder.Position = UDim2.new(1, -10, 1, 0)

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "List"
	-- 48 shorter than the page: the button lives in what it gives up. Without
	-- this the last quest row sits behind it and cannot be reached.
	scroll.Size = UDim2.new(1, 0, 1, -48)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.ScrollBarImageColor3 = C.wood
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = qPage
	local ql = Instance.new("UIListLayout")
	ql.Padding = UDim.new(0, 7)
	ql.SortOrder = Enum.SortOrder.LayoutOrder
	ql.Parent = scroll
	local qp = Instance.new("UIPadding")
	qp.PaddingRight = UDim.new(0, 10)
	qp.Parent = scroll

	local function sectionHeader(order, txt)
		local h = text(scroll, txt, 15, Enum.Font.LuckiestGuy, C.sand)
		h.LayoutOrder = order
		h.Size = UDim2.new(1, 0, 0, 22)
		h.TextXAlignment = Enum.TextXAlignment.Left
		return h
	end
	local heads = {
		daily = sectionHeader(1, "TODAY"),
		life = sectionHeader(1000, "MILESTONES"),
	}

	-- Rows are made on demand and then kept: a quest row changes state on a
	-- five-second tick, and rebuilding one on a timer is how a list flickers.
	local function questRow(q)
		local row = Instance.new("Frame")
		row.Name = q.key
		row.Size = UDim2.new(1, 0, 0, 62)
		row.BackgroundColor3 = C.white
		row.BorderSizePixel = 0
		row.Parent = scroll
		corner(row, 12)
		local rs = outline(row, 2.5)
		local rg = grad(row, C.white, C.sand)

		--[[
			FOUR COLUMNS THAT DO NOT TOUCH, and the first cut had three of them
			lying on top of each other. Measured live on a 644-wide row:

				name/blurb  12..496     (its box, not its text)
				track       12..484
				count      402..492     -- ON the bar, and only 90 wide
				coin       424..528     -- starting inside the blurb's box

			So the progress caption printed over the green fill, which put it half
			on green and half on grey at any partial progress; it truncated to
			"1,000,000 /..." because twenty-one characters do not fit ninety pixels;
			and the payout floated mid-row rather than sitting with the button it is
			the price of.

			The widths below are derived from the RIGHT edge inward -- button, then
			payout, then the caption -- and the bar takes what is left, because the
			three on the right are fixed and the bar is the only one that can give.
		]]
		local BTN_W, COIN_W, COUNT_W = 100, 108, 116
		local TEXT_RIGHT = BTN_W + COIN_W + 30      -- where name/blurb must stop
		local BAR_RIGHT = TEXT_RIGHT + COUNT_W + 8  -- where the bar must stop

		local name = text(row, q.label, 16, Enum.Font.LuckiestGuy, Color3.fromRGB(70, 52, 34))
		name.Position = UDim2.fromOffset(12, 7)
		name.Size = UDim2.new(1, -(TEXT_RIGHT + 12), 0, 19)
		name.TextXAlignment = Enum.TextXAlignment.Left

		local blurb = text(row, q.blurb, 12, Enum.Font.GothamMedium, Color3.fromRGB(140, 118, 92))
		blurb.Position = UDim2.fromOffset(12, 26)
		blurb.Size = UDim2.new(1, -(TEXT_RIGHT + 12), 0, 15)
		blurb.TextXAlignment = Enum.TextXAlignment.Left

		local track = Instance.new("Frame")
		track.Position = UDim2.fromOffset(12, 45)
		track.Size = UDim2.new(1, -(BAR_RIGHT + 12), 0, 9)
		track.BackgroundColor3 = Color3.fromRGB(214, 200, 180)
		track.BorderSizePixel = 0
		track.Parent = row
		corner(track, 5)
		local fill = Instance.new("Frame")
		fill.Size = UDim2.fromScale(0, 1)
		fill.BackgroundColor3 = C.lime
		fill.BorderSizePixel = 0
		fill.Parent = track
		corner(fill, 5)

		-- Beside the bar, not on it, and centred on the bar's own middle so the
		-- two read as one line. Short form AND a size constraint: the format keeps
		-- it short, the constraint guarantees it can never ellipsize however long
		-- a future quest's numbers get.
		local count = text(row, "", 11, Enum.Font.GothamBold, Color3.fromRGB(120, 100, 76))
		count.AnchorPoint = Vector2.new(1, 0.5)
		count.Position = UDim2.new(1, -TEXT_RIGHT, 0, 49)
		count.Size = UDim2.fromOffset(COUNT_W, 15)
		count.TextXAlignment = Enum.TextXAlignment.Right
		count.TextScaled = true
		local countCap = Instance.new("UITextSizeConstraint")
		countCap.MaxTextSize = 12
		countCap.MinTextSize = 8
		countCap.Parent = count

		-- Vertically centred and hard against the button: it is the price of
		-- pressing that button, so it belongs beside it rather than hovering over
		-- the end of the blurb.
		local coin = text(row, "", 17, Enum.Font.LuckiestGuy, C.sun)
		coin.AnchorPoint = Vector2.new(1, 0.5)
		coin.Position = UDim2.new(1, -(BTN_W + 18), 0.5, -1)
		coin.Size = UDim2.fromOffset(COIN_W, 24)
		coin.TextXAlignment = Enum.TextXAlignment.Right
		-- The sell multiplier reaches 705x, so a five-figure payout becomes an
		-- eight-figure one. It shrinks rather than truncating.
		coin.TextScaled = true
		local coinCap = Instance.new("UITextSizeConstraint")
		coinCap.MaxTextSize = 17
		coinCap.MinTextSize = 10
		coinCap.Parent = coin
		punch(coin, 2.5)

		local holder, face, slab = chunky(row, 100, 40, C.lime, 12)
		holder.AnchorPoint = Vector2.new(1, 0.5)
		holder.Position = UDim2.new(1, -8, 0.5, -3)
		local bl = text(face, "", 15, Enum.Font.LuckiestGuy, C.white)
		bl.Size = UDim2.fromScale(1, 1)
		bl.ZIndex = 6
		punch(bl, 2.5)
		TouchFit.press(face, function()
			Net.get("ClaimReward"):FireServer({ kind = "quest", key = q.key })
		end)

		local ui = { row = row, fill = fill, count = count, coin = coin,
			face = face, slab = slab, bl = bl, stroke = rs, grad = rg,
			name = name, blurb = blurb }
		questRows[q.key] = ui
		return ui
	end

	----------------------------------------------------------------
	-- PLAYTIME  --  unchanged from the panel this replaced
	----------------------------------------------------------------
	local pPage = page("Playtime")

	-- SAYS "SESSION", NOT "THE BEACH". The timer is wall-clock time on the
	-- SERVER -- it has no idea where you are standing, and the tiers latch once
	-- per session. The old wording read as a place requirement and stayed on
	-- screen unchanged while you were stood in the Dunes, so it told players
	-- that using the ferry would cost them a 30-minute bounty. It never did.
	-- SAYS "TODAY" BECAUSE IT IS TODAY. These were a session bounty that reset
	-- every time somebody rejoined; RewardsServer latches them per UTC day now
	-- and measures them on seconds played today, so the old sentence was
	-- advertising a rejoin loop that no longer pays.
	local blurb = text(pPage, "Claim a bounty for time played today. Resets at the end of the day.",
		15, Enum.Font.GothamMedium, Color3.fromRGB(226, 206, 176))
	blurb.Position = UDim2.fromOffset(0, 0)
	blurb.Size = UDim2.new(1, 0, 0, 22)

	-- Centred, under a strip of five centred tiers. The page is 348 tall and the
	-- strip ends at 270, so this sits in room that was already empty.
	local pAll = claimAllButton(pPage, "playtime")
	pAll.holder.AnchorPoint = Vector2.new(0.5, 1)
	pAll.holder.Position = UDim2.new(0.5, 0, 1, -4)

	--[[
		IT SCROLLS NOW, AND THAT IS WHAT LETS THE LADDER GROW.  2026-09-19.

		This was a plain Frame holding `for i = 1, 5` cards at a fixed 116 wide.
		Five come to 620 against the 654 this body has, so the strip was full -- and
		the count was written twice, once here and once in RewardsConfig.Playtime.
		Adding three tiers to the config produced a page drawing five cards above a
		button reading CLAIM ALL 8: three rungs that paid out, were counted, and
		were never drawn.

		SCROLLED RATHER THAN NARROWED. Solving the card width from the count is the
		obvious alternative and it does not survive the arithmetic: eight cards in
		654 is 73 apiece, and the chip inside one is 90 wide before the money label
		-- which already truncates at 116 ("$4,916,4..."). The figure is the whole
		point of the card, so the card keeps its size.

		A HORIZONTAL DRAG HAS NOTHING TO FIGHT HERE. TouchFit's notes are right that
		a drag inside a scrollable panel is a gesture fought over twice -- but this
		page does not scroll vertically and the strip is one row, so the conflict
		that rule exists for is not present.

		AutomaticCanvasSize, so nothing here has to know the count either: add a
		tier to RewardsConfig and the canvas grows with it.
	]]
	local pstrip = Instance.new("ScrollingFrame")
	pstrip.Position = UDim2.fromOffset(0, 30)
	-- 12 taller than the cards, for the bar that now sits under them.
	pstrip.Size = UDim2.new(1, 0, 0, 252)
	pstrip.BackgroundTransparency = 1
	pstrip.BorderSizePixel = 0
	pstrip.CanvasSize = UDim2.new()
	pstrip.AutomaticCanvasSize = Enum.AutomaticSize.X
	pstrip.ScrollingDirection = Enum.ScrollingDirection.X
	pstrip.ScrollBarThickness = 6
	pstrip.ScrollBarImageColor3 = C.wood
	pstrip.Parent = pPage
	local ly = Instance.new("UIListLayout")
	ly.FillDirection = Enum.FillDirection.Horizontal
	ly.Padding = UDim.new(0, 10)
	--[[
		LEFT, NOT CENTRE, AND THE DIFFERENCE IS REACHABILITY RATHER THAN TASTE.

		This was Center while the strip was a plain Frame holding exactly five
		cards, where it was right: 620 of cards in 654 of room, evenly spaced.

		UIListLayout centres against the FRAME's size, not the canvas. The moment
		the content is wider than the port -- which is the whole point of the strip
		scrolling -- centring puts the first card at (port - content) / 2, i.e.
		NEGATIVE. Measured at eight tiers: canvas 599 in a 392 port, CanvasPosition
		0, and T1 sitting 103px to the LEFT of the port's own left edge. Scrolling
		cannot reach it, because CanvasPosition does not go below zero.

		So the 1 MIN tier -- the first one a new player earns -- was drawn off the
		side of a scrolling frame and could not be brought back.
	]]
	ly.HorizontalAlignment = Enum.HorizontalAlignment.Left
	ly.Parent = pstrip

	-- OFF THE CONFIG, NOT A LITERAL. The count lived in two places and they
	-- disagreed the moment one of them moved; paintPlaytime already walks the
	-- snapshot and indexes rewardCards[i], so this was the only hardcode left.
	for i = 1, #RewardsConfig.Playtime do
		local card = Instance.new("Frame")
		card.Name = "T" .. i
		card.Size = UDim2.fromOffset(116, 236)
		card.BackgroundColor3 = C.white
		card.BorderSizePixel = 0
		card.LayoutOrder = i
		card.Parent = pstrip
		corner(card, 18)
		local cardStroke = outline(card, 3.5)
		local cardGrad = grad(card, C.white, C.sand)

		local cardScale = Instance.new("UIScale")
		cardScale.Parent = card
		local pulse = TweenService:Create(cardScale,
			TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Scale = 1.045 })

		local chip = Instance.new("Frame")
		chip.Name = "Chip"
		chip.AnchorPoint = Vector2.new(0.5, 0)
		chip.Position = UDim2.new(0.5, 0, 0, 9)
		chip.Size = UDim2.fromOffset(90, 26)
		chip.BackgroundColor3 = Color3.fromRGB(58, 38, 24)
		chip.BorderSizePixel = 0
		chip.Parent = card
		corner(chip, 13)

		local when = text(chip, "", 15, Enum.Font.LuckiestGuy, C.sand)
		when.Name = "When"
		when.Size = UDim2.fromScale(1, 1)

		-- Behind the icon and only lit on the claimable tier. Created BEFORE the
		-- tile: both sit at ZIndex 1 and Global behaviour breaks that on tree
		-- order, so building it after would put the glow over the icon.
		local tileGlow = Instance.new("Frame")
		tileGlow.Name = "TileGlow"
		tileGlow.AnchorPoint = Vector2.new(0.5, 0.5)
		tileGlow.Position = UDim2.new(0.5, 0, 0, 78)
		tileGlow.Size = UDim2.fromOffset(108, 108)
		tileGlow.BackgroundColor3 = C.sun
		tileGlow.BackgroundTransparency = 0.68
		tileGlow.BorderSizePixel = 0
		tileGlow.Visible = false
		tileGlow.ZIndex = 1
		tileGlow.Parent = card
		corner(tileGlow, 54)

		local tile = Instance.new("Frame")
		tile.AnchorPoint = Vector2.new(0.5, 0)
		tile.Position = UDim2.new(0.5, 0, 0, 42)
		tile.Size = UDim2.fromOffset(72, 72)
		tile.BackgroundColor3 = C.sun
		tile.BorderSizePixel = 0
		tile.Parent = card
		corner(tile, 18)
		outline(tile, 3.5)
		grad(tile, C.sun:Lerp(C.white, 0.3), darken(C.sun, 0.2))
		gloss(tile, 18)

		local PX = 72
		local function iconHolder(name)
			local g = Instance.new("Frame")
			g.Name = name
			g.Size = UDim2.fromScale(1, 1)
			g.BackgroundTransparency = 1
			g.Visible = false
			g.ZIndex = 6
			g.Parent = tile
			return g
		end

		local lockG = iconHolder("Lock")
		local shackle = Instance.new("Frame")
		shackle.AnchorPoint = Vector2.new(0.5, 0.5)
		shackle.Size = UDim2.fromScale(0.44, 0.44)
		shackle.Position = UDim2.fromScale(0.5, 0.36)
		shackle.BackgroundTransparency = 1
		shackle.ZIndex = 7
		shackle.Parent = lockG
		corner(shackle, PX * 0.22)
		outline(shackle, 5, STEEL)
		local lockBody = ipart(lockG, 0.68, 0.46, 0.5, 0.68, STEEL, PX * 0.1)
		lockBody.ZIndex = 8
		outline(lockBody, 2.5)
		local hole = idisc(lockG, 0.15, 0.5, 0.66, darken(C.wood, 0.35), PX)
		hole.ZIndex = 9

		local giftG = iconHolder("Gift")
		local gBox = ipart(giftG, 0.74, 0.48, 0.5, 0.7, C.coral, PX * 0.08)
		outline(gBox, 2.5)
		local gLid = ipart(giftG, 0.9, 0.2, 0.5, 0.42, C.coral:Lerp(C.white, 0.22), PX * 0.06)
		gLid.ZIndex = 8
		outline(gLid, 2.5)
		local gRibbon = ipart(giftG, 0.14, 0.76, 0.5, 0.62, C.sun, 0)
		gRibbon.ZIndex = 9

		--[[
			THE CLAIMED TICK IS REAL ART NOW, not two rotated bars.

			It was `ipart` twice -- a long bar at -45 and a short one at +45 -- which
			is how every other glyph in this file is built, and for those it is the
			right call: a drawn shape cannot fail to render and owes nothing to what
			font the device shipped. A tick is the one place that argument is weak,
			because two crossed rectangles is exactly what a tick is NOT -- the join
			has a notch in it and neither end is cut square.

			CROPPED TO THE INK, WHICH IS THE WHOLE TRICK WITH THIS ASSET. The upload
			is a 687x687 canvas with the tick occupying x 237..461, y 241..414 -- the
			larger side of it is 0.328 of the canvas, so ScaleType.Fit on the raw
			image maps all that transparent margin too and draws the tick at a third
			of the box however big the box is. ImageRect takes a 225px SQUARE centred
			on the ink (padded on the short axis so the crop stays square and the
			fit cannot letterbox), and the tick then fills the box it is given.

			Measured with AssetService:CreateEditableImageAsync rather than eyeballed;
			if the art is ever re-uploaded, re-measure -- these four numbers belong to
			this exact asset.

			0.62 of the tile is what the drawn pair spanned, so the state reads at
			the same weight as the padlock and the gift box beside it.
		]]
		local doneG = iconHolder("Done")
		local tick = Instance.new("ImageLabel")
		tick.Name = "Tick"
		tick.AnchorPoint = Vector2.new(0.5, 0.5)
		tick.Position = UDim2.fromScale(0.5, 0.5)
		tick.Size = UDim2.fromScale(0.62, 0.62)
		tick.BackgroundTransparency = 1
		tick.Image = "rbxassetid://75644328014701"
		tick.ImageRectOffset = Vector2.new(237, 215)
		tick.ImageRectSize = Vector2.new(225, 225)
		tick.ScaleType = Enum.ScaleType.Fit
		tick.ZIndex = 7
		tick.Parent = doneG

		local icons = { Lock = lockG, Gift = giftG, Done = doneG }

		local amt = text(card, "", 30, Enum.Font.LuckiestGuy, C.sun)
		amt.Name = "Amt"
		amt.Position = UDim2.fromOffset(7, 122)
		amt.Size = UDim2.new(1, -14, 0, 34)
		amt.TextScaled = true
		local amtCap = Instance.new("UITextSizeConstraint")
		amtCap.MaxTextSize = 26
		amtCap.MinTextSize = 13
		amtCap.Parent = amt
		punch(amt, 3)

		local holder, face = chunky(card, 102, 46, C.lime, 15)
		holder.Name = "Btn"
		holder.AnchorPoint = Vector2.new(0.5, 1)
		holder.Position = UDim2.new(0.5, 0, 1, -8)
		local bl = text(face, "", 17, Enum.Font.LuckiestGuy, C.white)
		bl.Name = "BL"
		bl.Size = UDim2.fromScale(1, 1)
		bl.ZIndex = 6
		punch(bl, 2.5)
		TouchFit.press(face, function()
			-- The OLD payload shape, on purpose. RewardsServer still reads a
			-- bare {tier = n} as a playtime claim precisely so a client mid
			-- session at the time of an update keeps paying out.
			Net.get("ClaimReward"):FireServer({ tier = i })
		end)

		rewardCards[i] = { card = card, when = when, amt = amt, face = face,
			slab = holder.Slab, bl = bl, tile = tile, icons = icons,
			grad = cardGrad, glow = tileGlow,
			stroke = cardStroke, scale = cardScale, pulse = pulse }
	end

	----------------------------------------------------------------
	-- REFRESH
	----------------------------------------------------------------
	local GREY = Color3.fromRGB(150, 140, 126)

	local function paintDaily(d)
		if not d then return end
		dailyUi.head.Text = ("DAY %d STREAK"):format(d.streak)
		--[[
			THE RULE THIS LINE STATES HAS TO BE THE RULE THAT IS RUNNING. It used
			to say "miss one and it starts again", which stopped being true the
			day RewardsConfig.GraceDays landed.

			Saying it out loud is most of the point. A streak quietly rescued
			teaches the player nothing and earns no goodwill; a player who knows
			one miss is survivable is a player who comes back on the day after
			the one they missed, which is the day the old rule sent away.
		]]
		if d.saved then
			dailyUi.blurb.Text =
				"Streak saved. You missed a day and kept it, and that was your one save."
			dailyUi.blurb.TextColor3 = C.sun
		else
			dailyUi.blurb.Text = d.grace
				and "Log in on consecutive days and the bounty grows. One missed day is forgiven."
				or "Log in on consecutive days. Your one save is spent until the ladder turns."
			dailyUi.blurb.TextColor3 = Color3.fromRGB(226, 206, 176)
		end
		for i, cell in ipairs(ladderCells) do
			local r = d.ladder[i]
			if r then
				--[[
				COMPACT, NOT COMMA'D, AND THE REASON IS A WRAP NOBODY SEES ON A PHONE.

				The rung pays scaled coins, so by tide 48 day seven is 2,400,000,000.
				"$2,400,000,000" wants 134px of LuckiestGuy; the cell is 56 wide. The
				label is TextScaled with a MinTextSize of 11, so once it cannot fit on
				one line at 11px it WRAPS -- and it wraps on the commas, which breaks
				the number mid-group: "$1,200,00" over "0,000". Measured on a tablet
				at 959x599.

				IT DOES NOT SHOW ON A PHONE, which is why it survived. At 666x374 the
				same label truncates to "$100,0..." instead -- unreadable in a
				different way, and quiet enough to look deliberate.

				PanelKit.compact gives "$2.4B" at 47px. It is one word with no spaces,
				so it CANNOT wrap at any size -- the failure is designed out rather
				than tuned around -- and it truncates rather than rounds, which is the
				one direction a number a player is about to claim may err in. See the
				note on compact for why that matters.

				The CLAIM button underneath still prints the full comma'd figure: it
				has the room, and the exact amount belongs on the thing being pressed.
			]]
			cell.coin.Text = "$" .. PanelKit.compact(r.coins)
				cell.tick.Visible = r.done
				if r.current and not d.claimed then
					cell.stroke.Color = C.sun
					cell.stroke.Thickness = 5
					cell.grad.Color = ColorSequence.new(C.white, C.sand)
					cell.coin.TextColor3 = C.sun
					cell.day.TextColor3 = Color3.fromRGB(96, 78, 58)
				elseif r.done then
					cell.stroke.Color = C.ink
					cell.stroke.Thickness = 3
					cell.grad.Color = ColorSequence.new(
						Color3.fromRGB(212, 226, 204), Color3.fromRGB(182, 200, 174))
					cell.coin.TextColor3 = Color3.fromRGB(146, 166, 138)
					cell.day.TextColor3 = Color3.fromRGB(120, 140, 116)
				else
					cell.stroke.Color = C.ink
					cell.stroke.Thickness = 3
					cell.grad.Color = ColorSequence.new(
						Color3.fromRGB(220, 212, 200), Color3.fromRGB(192, 182, 168))
					cell.coin.TextColor3 = Color3.fromRGB(84, 74, 62)
					cell.day.TextColor3 = Color3.fromRGB(120, 104, 84)
				end
			end
		end
		if d.claimed then
			dailyUi.label.Text = "COME BACK TOMORROW"
			dailyUi.face.BackgroundColor3 = C.sandDeep
			dailyUi.slab.BackgroundColor3 = darken(C.sandDeep, 0.45)
		else
			dailyUi.label.Text = "CLAIM  $" .. comma(d.coins)
			dailyUi.face.BackgroundColor3 = C.lime
			dailyUi.slab.BackgroundColor3 = darken(C.lime, 0.45)
		end
	end

	-- See the note by its only caller below.
	local function questAmount(q, n: number): string
		if q.stat == "playSec" then
			return ("%dm"):format(math.floor(n / 60))
		end
		return compactNum(n)
	end

	local function paintQuests(list)
		if not list then return end
		local nDaily, nLife = 0, 0
		for _, q in ipairs(list) do
			local ui = questRows[q.key] or questRow(q)
			-- Dailies first and milestones after, with the section headers
			-- pinned at 1 and 1000 so a new quest lands in its own block
			-- without this needing to know how many there are.
			if q.daily then
				nDaily += 1
				ui.row.LayoutOrder = 1 + nDaily
			else
				nLife += 1
				ui.row.LayoutOrder = 1000 + nLife
			end
			-- THE WARDROBE RUNGS PAY A SKIN AND NO COINS, so the payout slot prints
			-- what is actually on offer rather than "$0". The row's own name is
			-- already the skin's name ("DRIFTWOOD RAKE"), so this only has to say
			-- what KIND of thing it is. The colour is left to the state branches
			-- below -- gold when ready, green-grey once done -- which reads the same
			-- on a word as it does on a figure.
			ui.coin.Text = q.skin and "NEW SKIN" or ("$" .. comma(q.coins))
			-- A SECONDS COUNTER IS PRINTED AS MINUTES. "600 / 600" under a blurb
			-- that says "spend 10 minutes" is a number the player has to do sums on
			-- to believe, and it is the first reward a new account is offered. The
			-- two quests measured in seconds are the Long Shift daily and the
			-- driftwood rung; both read as "7m / 15m" now.
			ui.count.Text = ("%s / %s"):format(questAmount(q, q.have), questAmount(q, q.need))
			ui.fill.Size = UDim2.fromScale(math.clamp(q.have / math.max(1, q.need), 0, 1), 1)

			if q.claimed then
				ui.bl.Text = "DONE"
				ui.face.BackgroundColor3 = C.sandDeep
				ui.slab.BackgroundColor3 = darken(C.sandDeep, 0.45)
				ui.fill.BackgroundColor3 = Color3.fromRGB(146, 166, 138)
				ui.stroke.Color = C.ink
				ui.stroke.Thickness = 2.5
				ui.grad.Color = ColorSequence.new(
					Color3.fromRGB(212, 226, 204), Color3.fromRGB(182, 200, 174))
				ui.coin.TextColor3 = Color3.fromRGB(146, 166, 138)
			elseif q.ready then
				ui.bl.Text = "CLAIM!"
				ui.face.BackgroundColor3 = C.lime
				ui.slab.BackgroundColor3 = darken(C.lime, 0.45)
				ui.fill.BackgroundColor3 = C.lime
				ui.stroke.Color = C.sun
				ui.stroke.Thickness = 4
				ui.grad.Color = ColorSequence.new(C.white, C.sand)
				ui.coin.TextColor3 = C.sun
			else
				ui.bl.Text = "..."
				ui.face.BackgroundColor3 = C.sandDeep
				ui.slab.BackgroundColor3 = darken(C.sandDeep, 0.45)
				ui.fill.BackgroundColor3 = C.sea
				ui.stroke.Color = C.ink
				ui.stroke.Thickness = 2.5
				ui.grad.Color = ColorSequence.new(C.white, C.sand)
				ui.coin.TextColor3 = Color3.fromRGB(160, 132, 60)
			end
		end
		heads.daily.Visible = nDaily > 0
		heads.life.Visible = nLife > 0
	end

	local function paintPlaytime(pt)
		if not pt then return end
		for i, t in ipairs(pt.tiers) do
			local ui = rewardCards[i]
			if ui then
				ui.when.Text = t.label
				ui.amt.Text = "$" .. comma(t.coins)
				local st = t.claimed and "Done" or (t.ready and "Gift" or "Lock")
				for name, g in ui.icons do
					g.Visible = (name == st)
				end
				PanelKit.retint(ui.tile, nil,
					t.claimed and C.lime or (t.ready and C.sun or Color3.fromRGB(122, 134, 150)))
				if t.claimed then
					ui.bl.Text = "DONE"
					ui.face.BackgroundColor3 = C.sandDeep
					ui.slab.BackgroundColor3 = darken(C.sandDeep, 0.45)
					ui.stroke.Color = C.ink
					ui.stroke.Thickness = 3.5
					ui.grad.Color = ColorSequence.new(
						Color3.fromRGB(212, 226, 204), Color3.fromRGB(182, 200, 174))
					ui.amt.TextColor3 = Color3.fromRGB(146, 166, 138)
					ui.glow.Visible = false
					ui.pulse:Cancel()
					ui.scale.Scale = 1
				elseif t.ready then
					ui.bl.Text = "CLAIM!"
					ui.face.BackgroundColor3 = C.lime
					ui.slab.BackgroundColor3 = darken(C.lime, 0.45)
					ui.stroke.Color = C.sun
					ui.stroke.Thickness = 5.5
					ui.grad.Color = ColorSequence.new(C.white, C.sand)
					ui.amt.TextColor3 = C.sun
					ui.glow.Visible = true
					--[[
						CANCELLED, NOT MERELY NOT-STARTED. Skipping the Play alone would
						leave a pulse that was already running when the setting was
						thrown -- this branch is the READY one, so the cancel further
						down only ever fires once the card stops being claimable, which
						might be minutes. This runs on every push, so the correction
						lands within a tick of the switch.

						Claimable is still carried by the lime fill, the sun stroke and
						the glow above; the pulse was the flourish on top.
					]]
					if Motion.reduced() then
						ui.pulse:Cancel()
						ui.scale.Scale = 1
					else
						ui.pulse:Play()
					end
				else
					ui.bl.Text = mmss(t.remaining)
					ui.face.BackgroundColor3 = C.sandDeep
					ui.slab.BackgroundColor3 = darken(C.sandDeep, 0.45)
					ui.stroke.Color = C.ink
					ui.stroke.Thickness = 3.5
					ui.grad.Color = ColorSequence.new(
						Color3.fromRGB(220, 212, 200), Color3.fromRGB(192, 182, 168))
					ui.amt.TextColor3 = Color3.fromRGB(84, 74, 62)
					ui.glow.Visible = false
					ui.pulse:Cancel()
					ui.scale.Scale = 1
				end
			end
		end
	end

	--[[
		A DOT ON THE TAB OF ANY PAGE WITH SOMETHING WAITING. Three tabs means
		two of them are always hidden, and a reward you cannot see is one you do
		not claim -- the tab strip has to be able to say "there is something
		over here" without being opened.
	]]
	local function paintTabDots(snap)
		-- See rewardsReady: the rail key asks this same question from outside.
		local ready = rewardsReady(snap)
		for name, t in rewardTabs do
			local dot = t.face:FindFirstChild("Dot")
			if not dot then
				dot = Instance.new("Frame")
				dot.Name = "Dot"
				dot.AnchorPoint = Vector2.new(1, 0)
				dot.Position = UDim2.new(1, -7, 0, 6)
				dot.Size = UDim2.fromOffset(11, 11)
				dot.BackgroundColor3 = C.coral
				dot.BorderSizePixel = 0
				dot.ZIndex = 9
				dot.Parent = t.face
				corner(dot, 6)
				outline(dot, 2)
			end
			dot.Visible = ready[name] == true
		end
	end

	panels.Rewards.refresh = function()
		if not rewardState then return end
		paintDaily(rewardState.daily)
		paintQuests(rewardState.quests)
		paintPlaytime(rewardState.playtime)
		paintTabDots(rewardState)

		-- Off the same answer the dots and the rail mark use, so a page whose tab
		-- has a dot on it always has a live button behind it.
		local ready = rewardsReady(rewardState)
		qAll.set(ready.nQuests)
		pAll.set(ready.nPlaytime)
	end

	-- onOpen, not refresh: refresh runs on every repaint, and "they have now seen
	-- the quests" is a thing that happens once, when they open the panel.
	panels.Rewards.onOpen = function()
		markQuestsSeen()
		refreshRewardsAlert()
	end

	setRewardPage(rewardPage)
end


--------------------------------------------------------------------------
-- INDEX  --  THE FINDS BOARD
--------------------------------------------------------------------------
--[[
	A collection screen, not a price list.

	The old Index was a scrolling table of every item with its odds and payout.
	Accurate, and nobody opened it twice: a table cannot show you the thing you
	found. This is the shape the fishing game's Fish Index uses,
	translated to a beach -- a grid of specimen trays, each holding the REAL 3D
	model in a ViewportFrame over a rockpool, with rarity filter chips, a
	discovery count across the top, and a detail card behind every tile.
	Anything never held is a black silhouette under a "?", so the board reads as
	a map of what is still out there. That is the only reason to come back to it.

	WHAT COUNTS AS DISCOVERED
	-------------------------
	Nothing in here decides that, and nothing in here can be lied to. The client
	only ever learns an itemId once the server has revealed it -- publicView
	strips the id from a crusted record until the crust is off -- so the
	inventory mirror IS the discovery feed. Three signals, all of them already
	in the game; no new remotes:

		InventorySync         anything in the bag whose id has been revealed
		Wash/SiftItemCleaned  the reveal at the bay, the instant the crust goes
		SellResult            the receipt, which names every item in the sale

	It is SESSION state, exactly like coins and upgrade levels: nothing in this
	game persists yet. When a DataStore arrives, save the `found` set with them
	and seed it once in buildIndex -- markFound is the only door in.

	EVERY ITEM IS REACHABLE. TrashSeeder rolls its props off
	ItemConfig.rollItemId, which walks the whole catalogue, so a Meteorite
	really is out there at its stated odds. If that ever narrows to a
	hand-picked list, this board becomes a wall of "?" nobody can clear -- which
	is the kind of thing a collection screen has to stay honest about.
]]

-- Up-front-side, not a flat side view. Straight down +Z makes the flat items
-- (Phone, Wallet, Glasses -- wide on X/Z, thin on Y) read as slivers; this
-- angle shows their face. The same lesson the fish index learned on rays.
local CARD_DIR = Vector3.new(0.5, 0.42, 1).Unit

-- Frame by the model's BOX, aspect-aware, not by its bounding sphere.
-- FieldOfView is the VERTICAL fov, so a portrait viewport fits LESS
-- horizontally (tanH = tanV * aspect); fitting a sphere overflows tall models
-- in a tall tank.
local function frameModel(vpf, model, aspect, margin)
	local camera = Instance.new("Camera")
	camera.FieldOfView = 45
	camera.Parent = vpf
	vpf.CurrentCamera = camera

	local cf, size = model:GetBoundingBox()
	local tanV = math.tan(math.rad(camera.FieldOfView * 0.5))
	local tanH = tanV * math.max(aspect, 0.05)
	local halfH = size.Y * 0.5 + math.max(size.X, size.Z) * 0.12
	local halfW = math.max(size.X, size.Z) * 0.5
	local dist = math.max(halfH / tanV, halfW / tanH) * (margin or 1.3)
	camera.CFrame = CFrame.lookAt(cf.Position + CARD_DIR * dist, cf.Position)
	return camera, cf.Position, dist
end

-- A rockpool tray: shallow water over wet sand, lit from above. Its whole job
-- is to give the model a box to sit in, so 25 cards read as a cabinet rather
-- than as 25 props floating on a panel.
--
-- `z` IS NOT DECORATION. This ScreenGui runs ZIndexBehavior.Global, so ZIndex
-- is compared across the WHOLE gui and being someone's child buys you nothing:
-- the detail card sits at 61, so a tank built at the grid's ZIndex 3 renders
-- UNDERNEATH the very card that contains it -- a cream rectangle where the
-- specimen should be, with the ring around it still visible because that was
-- numbered higher. Every layer here is offset from a base the caller passes.
local function makeTank(parent, h, found, radius, z)
	local tank = Instance.new("Frame")
	tank.Name = "Tank"
	tank.Position = UDim2.fromOffset(7, 7)
	tank.Size = UDim2.new(1, -14, 0, h)
	-- White, because grad() MULTIPLIES against the base colour and a Frame's
	-- default is mid grey -- which is what turned the rockpool into dishwater.
	tank.BackgroundColor3 = Color3.new(1, 1, 1)
	tank.BorderSizePixel = 0
	tank.ClipsDescendants = true
	tank.ZIndex = z
	tank.Parent = parent
	corner(tank, radius)
	outline(tank, 2.5)
	if found then
		grad(tank, Color3.fromRGB(172, 234, 250), Color3.fromRGB(58, 152, 192))
	else
		-- Buried, not merely dark: silt browns rather than a black box.
		grad(tank, Color3.fromRGB(78, 72, 62), Color3.fromRGB(32, 30, 28))
	end

	-- One sun shaft, drawn as a DIAGONAL GRADIENT on a frame that fills the tank
	-- rather than as a rotated bar.
	--
	-- ClipsDescendants does not clip a descendant with a non-zero Rotation. The
	-- first version of this was a 15-degree bar 740px tall inside a 370px tank,
	-- and it sailed straight out of the bottom of the panel and across the screen
	-- -- and did it once per card, so the whole Index had light streaks raked
	-- over it. A UIGradient rotates the FILL, not the frame, so the frame stays
	-- axis-aligned and the clip holds.
	local ray = Instance.new("Frame")
	ray.Name = "Ray"
	ray.Size = UDim2.fromScale(1, 1)
	ray.BackgroundColor3 = C.white
	ray.BorderSizePixel = 0
	ray.ZIndex = z + 1
	ray.Parent = tank
	local rayGrad = Instance.new("UIGradient")
	rayGrad.Rotation = 104
	local peak = found and 0.8 or 0.93
	rayGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.3, 1),
		NumberSequenceKeypoint.new(0.42, peak),
		NumberSequenceKeypoint.new(0.54, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	rayGrad.Parent = ray

	-- Wet sand along the bottom. ClipsDescendants clips to the RECTANGLE and
	-- ignores UICorner, so a square strip pokes its corners out through the
	-- tank's rounded ones: give the strip the same radius and cap its top flat.
	local bed = Instance.new("Frame")
	bed.Name = "Bed"
	bed.AnchorPoint = Vector2.new(0, 1)
	bed.Position = UDim2.fromScale(0, 1)
	bed.Size = UDim2.new(1, 0, 0, math.max(14, h * 0.17))
	bed.BackgroundColor3 = found and Color3.fromRGB(232, 204, 150) or Color3.fromRGB(52, 46, 40)
	bed.BorderSizePixel = 0
	bed.ZIndex = z + 2
	bed.Parent = tank
	corner(bed, radius)
	local flat = Instance.new("Frame")
	flat.Size = UDim2.new(1, 0, 0, radius)
	flat.BackgroundColor3 = bed.BackgroundColor3
	flat.BorderSizePixel = 0
	flat.ZIndex = z + 2
	flat.Parent = bed

	return tank
end

-- The model itself. An undiscovered item gets the SAME geometry, blacked out:
-- a silhouette is a promise about the shape, which is what makes an unfound
-- tile interesting instead of blank.
local function putModel(tank, itemId, found, aspect, margin, z)
	local vpf = Instance.new("ViewportFrame")
	vpf.Name = "View"
	vpf.Size = UDim2.fromScale(1, 1)
	vpf.BackgroundTransparency = 1
	vpf.BorderSizePixel = 0
	vpf.ZIndex = z
	vpf.Ambient = found and Color3.fromRGB(206, 224, 238) or Color3.fromRGB(52, 52, 58)
	vpf.LightColor = found and Color3.fromRGB(255, 250, 234) or Color3.fromRGB(84, 84, 92)
	vpf.LightDirection = Vector3.new(-0.4, -1, -0.55)
	vpf.Parent = tank

	local ok, model = pcall(ItemVisuals.buildClean, itemId)
	if not (ok and model) then
		return vpf, nil
	end
	if not found then
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.Color = Color3.fromRGB(14, 20, 32)
				d.Material = Enum.Material.SmoothPlastic
				d.Reflectance = 0
			end
		end
	end
	model.Parent = vpf
	local camera, centre, dist = frameModel(vpf, model, aspect, margin)
	return vpf, model, camera, centre, dist
end

local FILTERS = { "All", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic" }
local CARD_W, CARD_H, TANK_H = 156, 164, 96
local IDX_W, IDX_H = 700, 496

local function buildIndex()
	local root, body = makePanel("Index", IDX_W, IDX_H, C.sea)
	panels.Index = { root = root, w = IDX_W, h = IDX_H }

	local total = #ItemConfig.Order
	local found, cards, chips = {}, {}, {}
	local filter, foundCount = "All", 0

	--[[
		THE SECOND AXIS: WHERE A FIND COMES FROM.

		Asked for on 2026-09-21, twenty-three minutes into a session: "The index
		should have some way to sort it by which beach the item is from, otherwise
		it's a bit hard to tell where exactly I'm supposed to collect."

		That is the right complaint about this board. It has always answered "what
		is still out there" and never "where do I go for it", and a grid of two
		hundred silhouettes is a worse map than a list if you cannot narrow it to
		the shore you are standing on.

		A SECOND ROW RATHER THAN MORE CHIPS IN THE FIRST. Rarity and place are
		independent questions -- "the Legendaries I am missing" and "what is left
		on Ashfall" are both things to ask, and "the Legendaries left on Ashfall"
		is the one this board could never answer before. One row of ten mixed
		chips would make them look like alternatives.

		`isle` IS A SOURCE KEY, not a label -- ItemConfig.sourceOf returns the same
		keys, so the test in applyFilter is an equality and not a lookup.
	]]
	local isleChips = {}
	local isle = "All"

	------------------------------------------------------------------
	-- HEADER: discovery progress
	------------------------------------------------------------------
	local track = Instance.new("Frame")
	track.Name = "Progress"
	track.Size = UDim2.new(1, 0, 0, 28)
	track.BackgroundColor3 = darken(C.sandDeep, 0.35)
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.Parent = body
	corner(track, 14)
	outline(track, 3)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.new(1, 1, 1)
	fill.BorderSizePixel = 0
	fill.Parent = track
	corner(fill, 14)
	grad(fill, C.foam, C.foamDark)

	local countText = text(track, "", 15, Enum.Font.LuckiestGuy, C.white)
	countText.Size = UDim2.fromScale(1, 1)
	countText.ZIndex = 8
	punch(countText, 2.5)

	------------------------------------------------------------------
	-- RARITY FILTER CHIPS
	------------------------------------------------------------------
	local chipRow = Instance.new("Frame")
	chipRow.Name = "Filters"
	chipRow.Position = UDim2.fromOffset(0, 36)
	chipRow.Size = UDim2.new(1, 0, 0, 30)
	chipRow.BackgroundTransparency = 1
	chipRow.Parent = body

	-- The island row, directly under the rarity one. Same geometry, so the two
	-- read as a pair of axes rather than as a control and an afterthought.
	local isleRow = Instance.new("Frame")
	isleRow.Name = "IslandFilters"
	isleRow.Position = UDim2.fromOffset(0, 70)
	isleRow.Size = UDim2.new(1, 0, 0, 30)
	isleRow.BackgroundTransparency = 1
	isleRow.Parent = body
	local isleLay = Instance.new("UIListLayout")
	isleLay.FillDirection = Enum.FillDirection.Horizontal
	isleLay.HorizontalAlignment = Enum.HorizontalAlignment.Center
	isleLay.VerticalAlignment = Enum.VerticalAlignment.Center
	isleLay.Padding = UDim.new(0, 6)
	isleLay.SortOrder = Enum.SortOrder.LayoutOrder
	isleLay.Parent = isleRow
	local chipLay = Instance.new("UIListLayout")
	chipLay.FillDirection = Enum.FillDirection.Horizontal
	chipLay.HorizontalAlignment = Enum.HorizontalAlignment.Center
	chipLay.VerticalAlignment = Enum.VerticalAlignment.Center
	chipLay.Padding = UDim.new(0, 6)
	chipLay.SortOrder = Enum.SortOrder.LayoutOrder
	chipLay.Parent = chipRow

	------------------------------------------------------------------
	-- THE GRID
	------------------------------------------------------------------
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Grid"
	-- 108, not 74: the island row took 34 of the grid's height. The board
	-- scrolls, so what this costs is a little under half a row of tiles on a
	-- desktop -- and it buys the one question the board could not answer.
	scroll.Position = UDim2.fromOffset(0, 108)
	scroll.Size = UDim2.new(1, 0, 1, -108)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 8
	scroll.ScrollBarImageColor3 = C.wood
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.Parent = body
	local gridLay = Instance.new("UIGridLayout")
	gridLay.CellSize = UDim2.fromOffset(CARD_W, CARD_H)
	gridLay.CellPadding = UDim2.fromOffset(10, 12)
	gridLay.HorizontalAlignment = Enum.HorizontalAlignment.Center
	gridLay.SortOrder = Enum.SortOrder.LayoutOrder
	gridLay.Parent = scroll
	local gridPad = Instance.new("UIPadding")
	gridPad.PaddingTop = UDim.new(0, 2)
	gridPad.PaddingBottom = UDim.new(0, 10)
	gridPad.Parent = scroll

	------------------------------------------------------------------
	-- DETAIL OVERLAY
	--
	-- Built once and re-dressed, never rebuilt per click: the tank holds a live
	-- ViewportFrame and a Camera, and churning those on every tap is how a
	-- collection screen starts hitching.
	------------------------------------------------------------------
	local detail = { open = false }

	local dim = Instance.new("TextButton")
	dim.Name = "IndexDetail"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.fromRGB(10, 14, 22)
	dim.BackgroundTransparency = 0.42
	dim.BorderSizePixel = 0
	dim.AutoButtonColor = false
	dim.Text = ""
	dim.Visible = false
	dim.ZIndex = 60
	dim.Parent = gui

	local dCard = Instance.new("Frame")
	dCard.Name = "Card"
	dCard.AnchorPoint = Vector2.new(0.5, 0.5)
	-- Nudged down, so its own close button clears the panel banner's X behind it.
	-- Two X buttons stacked in the same corner reads as a mistake.
	dCard.Position = UDim2.new(0.5, 0, 0.5, 24)
	dCard.Size = UDim2.fromOffset(660, 392)
	dCard.BackgroundColor3 = C.sand
	dCard.BorderSizePixel = 0
	dCard.ZIndex = 61
	dCard.Parent = dim
	corner(dCard, 24)
	outline(dCard, 5)
	grad(dCard, C.sand, C.sandMid)
	local dScale = Instance.new("UIScale")
	dScale.Parent = dCard

	local dTankHost = Instance.new("Frame")
	dTankHost.Name = "TankHost"
	dTankHost.Position = UDim2.fromOffset(11, 11)
	dTankHost.Size = UDim2.fromOffset(264, 370)
	dTankHost.BackgroundTransparency = 1
	dTankHost.ZIndex = 62
	dTankHost.Parent = dCard

	local dRing = Instance.new("Frame")
	dRing.Name = "Ring"
	dRing.Size = UDim2.fromScale(1, 1)
	dRing.BackgroundTransparency = 1
	dRing.ZIndex = 70
	dRing.Parent = dTankHost
	corner(dRing, 18)
	local dRingStroke = outline(dRing, 4, C.foam)

	local RX = 292
	local RW = 660 - RX - 16

	local plate = Instance.new("Frame")
	plate.Name = "Nameplate"
	plate.Position = UDim2.fromOffset(RX, 14)
	plate.Size = UDim2.fromOffset(RW, 48)
	plate.BackgroundColor3 = C.sun
	plate.BorderSizePixel = 0
	plate.ZIndex = 62
	plate.Parent = dCard
	corner(plate, 14)
	outline(plate, 4)
	grad(plate, C.sun:Lerp(C.white, 0.35), C.sunDark)
	gloss(plate, 14)
	-- Padded, so a long name never touches its own outline.
	local plateName = text(plate, "", 25, Enum.Font.LuckiestGuy, C.white)
	plateName.Size = UDim2.new(1, -22, 1, 0)
	plateName.Position = UDim2.fromOffset(11, 0)
	plateName.ZIndex = 64
	punch(plateName, 3)

	local dPill = Instance.new("Frame")
	dPill.Name = "Rarity"
	dPill.Position = UDim2.fromOffset(RX, 70)
	dPill.Size = UDim2.fromOffset(RW, 28)
	dPill.BorderSizePixel = 0
	dPill.ZIndex = 62
	dPill.Parent = dCard
	dPill.BackgroundColor3 = Color3.new(1, 1, 1)
	corner(dPill, 14)
	outline(dPill, 3)
	-- Made ONCE. grad() adds a fresh UIGradient every call, and calling it per
	-- click would stack a new one on the pill for every card ever opened -- only
	-- the first would render and the rest would just accumulate.
	local dPillGrad = grad(dPill, C.sea, C.seaDark)
	local dPillText = text(dPill, "", 15, Enum.Font.LuckiestGuy, C.white)
	dPillText.Size = UDim2.fromScale(1, 1)
	dPillText.ZIndex = 64
	punch(dPillText, 2.5)

	-- Four frosted stat rows. A tinted disc rather than an emoji icon: a glyph
	-- is at the mercy of whatever font the device ships, and this file has been
	-- bitten by exactly that before.
	local ROWS = { "ODDS", "WEIGHT", "SELLS FOR", "COMES UP" }
	local rows = {}
	for i, key in ipairs(ROWS) do
		local r = Instance.new("Frame")
		r.Name = key
		r.Position = UDim2.fromOffset(RX, 106 + (i - 1) * 38)
		r.Size = UDim2.fromOffset(RW, 32)
		r.BackgroundColor3 = C.white
		r.BackgroundTransparency = 0.28
		r.BorderSizePixel = 0
		r.ZIndex = 62
		r.Parent = dCard
		corner(r, 10)
		outline(r, 2.5)

		local disc = Instance.new("Frame")
		disc.AnchorPoint = Vector2.new(0, 0.5)
		disc.Position = UDim2.new(0, 9, 0.5, 0)
		disc.Size = UDim2.fromOffset(12, 12)
		disc.BackgroundColor3 = C.sea
		disc.BorderSizePixel = 0
		disc.ZIndex = 64
		disc.Parent = r
		corner(disc, 6)

		local lbl = text(r, key, 12, Enum.Font.GothamBold, Color3.fromRGB(126, 104, 78))
		lbl.Position = UDim2.fromOffset(28, 0)
		lbl.Size = UDim2.new(0.44, 0, 1, 0)
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.ZIndex = 64

		local val = text(r, "", 15, Enum.Font.LuckiestGuy, C.ink)
		val.AnchorPoint = Vector2.new(1, 0)
		val.Position = UDim2.new(1, -12, 0, 0)
		val.Size = UDim2.new(0.56, -24, 1, 0)
		val.TextXAlignment = Enum.TextXAlignment.Right
		val.ZIndex = 64

		rows[key] = { disc = disc, value = val }
	end

	-- FIELD NOTE, in the RIGHT column -- never a full-width ribbon along the
	-- bottom. The tank is taller than the text block and draws over anything
	-- that reaches under it: the exact trap the fish index hit.
	local note = Instance.new("Frame")
	note.Name = "FieldNote"
	note.Position = UDim2.fromOffset(RX, 260)
	note.Size = UDim2.fromOffset(RW, 118)
	note.BackgroundColor3 = C.white
	note.BackgroundTransparency = 0.4
	note.BorderSizePixel = 0
	note.ZIndex = 62
	note.Parent = dCard
	corner(note, 12)
	outline(note, 2.5)

	local noteHead = text(note, "FIELD NOTE", 12, Enum.Font.GothamBold, Color3.fromRGB(150, 126, 96))
	noteHead.Position = UDim2.fromOffset(12, 6)
	noteHead.Size = UDim2.new(1, -24, 0, 14)
	noteHead.TextXAlignment = Enum.TextXAlignment.Left
	noteHead.ZIndex = 64

	local noteBody = text(note, "", 15, Enum.Font.GothamMedium, C.ink)
	noteBody.Position = UDim2.fromOffset(12, 24)
	noteBody.Size = UDim2.new(1, -24, 1, -34)
	noteBody.TextWrapped = true
	noteBody.TextTruncate = Enum.TextTruncate.None
	noteBody.TextYAlignment = Enum.TextYAlignment.Top
	noteBody.ZIndex = 64

	local dTag = text(dCard, "", 13, Enum.Font.LuckiestGuy, C.white)
	dTag.AnchorPoint = Vector2.new(0.5, 1)
	dTag.Position = UDim2.fromOffset(143, 376)
	dTag.Size = UDim2.fromOffset(130, 20)
	dTag.ZIndex = 72
	punch(dTag, 2.5)

	-- chunky() leaves its slab and face at ZIndex 0, which is fine in a Sibling
	-- gui and invisible in a Global one -- the coral button vanishes and leaves a
	-- bare white X floating on the card. Numbered explicitly here.
	local dHolder, dClose, dSlab = chunky(dCard, 40, 40, C.coral, 13)
	dHolder.AnchorPoint = Vector2.new(1, 0)
	dHolder.Position = UDim2.fromOffset(654, -12)
	dHolder.ZIndex = 74
	dSlab.ZIndex = 74
	dClose.ZIndex = 75
	local dx = text(dClose, "X", 21, Enum.Font.LuckiestGuy, C.white)
	dx.Size = UDim2.fromScale(1, 1)
	dx.ZIndex = 76
	punch(dx, 3)

	local orbit = { conn = nil, t = 0 }

	local function closeDetail()
		detail.open = false
		dim.Visible = false
		if orbit.conn then
			orbit.conn:Disconnect()
			orbit.conn = nil
		end
		-- The grid comes back only now. While the detail is up it is hidden, so
		-- exactly ONE ViewportFrame renders and the turn stays smooth however
		-- many tiles are behind it.
		scroll.Visible = true
	end
	TouchFit.press(dClose, closeDetail)
	TouchFit.press(dim, closeDetail)

	local function openDetail(itemId)
		local d = ItemConfig.Items[itemId]
		if not d or not found[itemId] then
			return
		end
		local info = ItemConfig.rarityInfo(d.Rarity)

		if dTankHost:FindFirstChild("Tank") then
			dTankHost.Tank:Destroy()
		end
		-- Base 63: the detail card is 61, so anything at the grid's numbers would
		-- render behind it. See the note on makeTank.
		local tank = makeTank(dTankHost, 370, true, 18, 63)
		tank.Position = UDim2.fromOffset(0, 0)
		tank.Size = UDim2.fromScale(1, 1)

		local _, _, camera, centre, dist = putModel(tank, itemId, true, 264 / 370, 1.34, 66)

		plateName.Text = string.upper(d.DisplayName)
		dPillGrad.Color = ColorSequence.new(info.color:Lerp(C.white, 0.3), darken(info.color, 0.25))
		dPillText.Text = string.upper(d.Rarity)
		dRingStroke.Color = info.color

		rows.ODDS.value.Text = ItemConfig.oddsText(d.OneIn)
		rows.WEIGHT.value.Text = tostring(d.Weight) .. " lb"
		rows["SELLS FOR"].value.Text = "$" .. comma(d.ValueRange[1]) .. " - $" .. comma(d.ValueRange[2])
		rows["COMES UP"].value.Text = d.Encased and "CRUSTED" or "CLEAN"
		for _, r in pairs(rows) do
			r.disc.BackgroundColor3 = info.color
		end

		noteBody.Text = '"' .. (d.Description or "") .. '"'

		local n = 0
		for i, id in ipairs(ItemConfig.Order) do
			if id == itemId then
				n = i
			end
		end
		dTag.Text = "#" .. n .. " / " .. total

		detail.open = true
		dim.Visible = true
		scroll.Visible = false
		dScale.Scale = 0.82
		TweenService:Create(dScale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 1 }):Play()

		-- ORBIT THE CAMERA, never PivotTo the model. Spinning the model writes
		-- every part's CFrame each frame; spinning the camera is one write and
		-- looks identical.
		if orbit.conn then
			orbit.conn:Disconnect()
			orbit.conn = nil
		end
		if camera and centre then
			orbit.t = 0
			orbit.conn = RunService.RenderStepped:Connect(function(dt)
				if not detail.open then
					return
				end
				orbit.t += dt * 0.55
				local dir = CFrame.Angles(0, orbit.t, 0) * CARD_DIR
				camera.CFrame = CFrame.lookAt(centre + dir * dist, centre)
			end)
		end
	end

	------------------------------------------------------------------
	-- CARDS
	------------------------------------------------------------------
	--[[
		THE VIEWPORTS ARE FILLED IN AS YOU SCROLL, NOT ALL AT ONCE.

		MEASURED on a fresh join with nothing opened: this panel alone held 2,102
		GuiObjects and 159 of the HUD's 161 ViewportFrames -- two thirds of the
		menu's objects and essentially all of its viewports, for a board the player
		had not looked at. Each card was paying putModel's full price at boot: a
		ViewportFrame, a cloned item model and a solved camera, times the whole
		catalogue.

		That cost lands during the load, which is exactly where a low-end phone is
		already struggling -- one arrived with fpsLow 2 and reported the UI as
		broken.

		WHAT IS AND IS NOT DEFERRED. The TANK stays: it is a decorated Frame and it
		carries the rarity chip, the "?" and the gradient, so the board still reads
		correctly with no model in it. Only the View -- the ViewportFrame putModel
		builds -- waits until the card is actually near the viewport.

		WHY NOT LAZY-BUILD THE WHOLE PANEL, which would have saved the other 2,102
		objects too: markFound and its three remote listeners (InventorySync,
		WashItemCleaned, SellResult) live inside this builder, and the found set is
		SESSION state that nothing persists. A panel that does not exist until it is
		opened is a panel that has not been listening -- so the collection log would
		silently miss everything found before the first visit. Deferring the
		viewports costs none of that.
	]]
	local schedule   -- forward-declared: styleCard re-queues a pass below

	local function styleCard(rec)
		local d = rec.def
		local info = ItemConfig.rarityInfo(d.Rarity)
		local isFound = found[d.ItemId] == true

		if rec.tank then
			rec.tank:Destroy()
		end
		-- The View was parented to the tank that just died. Dropping the reference
		-- rather than the instance: holding a destroyed one would make ensureView
		-- believe this card is already filled.
		rec.view = nil
		rec.tank = makeTank(rec.face, TANK_H, isFound, 12, 3)
		-- Read by ensureView, which runs long after this and must colour the model
		-- the way this card is currently painted.
		rec.found = isFound
		if schedule then
			schedule()
		end

		-- Rarity chip, or a grey unknown one. Rebuilt on the NEW tank -- the old
		-- chip was parented to the tank that was just destroyed, so reusing it
		-- would hand back a dead instance.
		local chip = Instance.new("Frame")
		chip.Name = "Chip"
		chip.Position = UDim2.fromOffset(5, 5)
		chip.Size = UDim2.fromOffset(isFound and 64 or 40, 17)
		chip.BackgroundColor3 = isFound and info.color or Color3.fromRGB(96, 88, 78)
		chip.BorderSizePixel = 0
		chip.ZIndex = 9
		chip.Parent = rec.tank
		corner(chip, 8)
		outline(chip, 2)
		local ct = text(chip, isFound and string.upper(d.Rarity) or "???", 10,
			Enum.Font.GothamBold, C.white)
		ct.Size = UDim2.fromScale(1, 1)
		ct.ZIndex = 10

		if not isFound then
			-- A lone "?" sits high in its line box -- the glyph's ink is nowhere
			-- near the middle of the space the label reserves for it. Nudged
			-- down rather than left looking like a mistake.
			local q = text(rec.tank, "?", 46, Enum.Font.LuckiestGuy, Color3.fromRGB(255, 226, 150))
			q.Name = "Unknown"
			q.Size = UDim2.fromScale(1, 1)
			q.Position = UDim2.fromOffset(0, 7)
			q.TextTransparency = 0.08
			q.ZIndex = 9
			punch(q, 3.5)
		end

		rec.name.Text = isFound and d.DisplayName or "???"
		rec.name.TextColor3 = isFound and C.ink or Color3.fromRGB(150, 132, 110)
		-- The odds get the loud treatment; "not found yet" is a placeholder and
		-- should not shout in LuckiestGuy with a 2px outline round it.
		rec.sub.Text = isFound and ItemConfig.oddsText(d.OneIn) or "not found yet"
		rec.sub.TextColor3 = isFound and info.color or Color3.fromRGB(160, 142, 120)
		rec.sub.Font = isFound and Enum.Font.LuckiestGuy or Enum.Font.GothamMedium
		rec.sub.TextSize = isFound and 13 or 11
		rec.subStroke.Transparency = isFound and 0 or 1
		rec.faceStroke.Color = isFound and darken(info.color, 0.3) or C.ink
		rec.faceStroke.Thickness = isFound and 3.5 or 2.5
	end

	local function applyFilter()
		for _, rec in pairs(cards) do
			-- BOTH AXES, AND-ed. See the note by `isle`: rarity and place are
			-- independent questions and the interesting one is asking both at once.
			local byRarity = (filter == "All") or (rec.def.Rarity == filter)
			local byIsle = (isle == "All")
				or (ItemConfig.sourceOf(rec.def.ItemId) == isle)
			rec.holder.Visible = byRarity and byIsle
		end
		-- A filter moves every remaining card up the grid, so which ones are in
		-- front of the player changes completely.
		if schedule then
			schedule()
		end
	end

	local function refreshCount()
		-- Published here rather than from the dev hook, so the attribute is true
		-- after a REAL pickup as well. It read 0 while the board plainly showed
		-- three finds, because only the hook was writing it.
		gui:SetAttribute("IndexFound", foundCount)
		countText.Text = foundCount .. " / " .. total .. " FOUND   \u{00B7}   "
			.. math.floor(foundCount / total * 100 + 0.5) .. "%"
		TweenService:Create(fill, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = UDim2.fromScale(foundCount / total, 1) }):Play()
	end

	-- THE ONLY DOOR IN. Everything that learns an item id funnels through here,
	-- so persistence later is one save of `found` and one seed loop.
	local function markFound(itemId, quiet)
		if type(itemId) ~= "string" or found[itemId] or not ItemConfig.Items[itemId] then
			return false
		end
		found[itemId] = true
		foundCount += 1
		local rec = cards[itemId]
		if rec then
			styleCard(rec)
			if not quiet then
				local s = rec.holder:FindFirstChildOfClass("UIScale")
				if not s then
					s = Instance.new("UIScale")
					s.Parent = rec.holder
				end
				s.Scale = 0.7
				TweenService:Create(s, TweenInfo.new(0.34, Enum.EasingStyle.Back,
					Enum.EasingDirection.Out), { Scale = 1 }):Play()
			end
		end
		refreshCount()
		return true
	end

	for i, id in ipairs(ItemConfig.Order) do
		local d = ItemConfig.Items[id]

		local holder = Instance.new("Frame")
		holder.Name = id
		holder.Size = UDim2.fromOffset(CARD_W, CARD_H)
		holder.BackgroundTransparency = 1
		holder.LayoutOrder = i
		holder.Parent = scroll

		local slab = Instance.new("Frame")
		slab.Size = UDim2.fromOffset(CARD_W, CARD_H - 8)
		slab.Position = UDim2.fromOffset(0, 8)
		slab.BackgroundColor3 = C.woodDark
		slab.BorderSizePixel = 0
		slab.ZIndex = 1
		slab.Parent = holder
		corner(slab, 16)

		local face = Instance.new("TextButton")
		face.Name = "Face"
		face.Size = UDim2.fromOffset(CARD_W, CARD_H - 8)
		face.BackgroundColor3 = C.white
		face.BorderSizePixel = 0
		face.AutoButtonColor = false
		face.Text = ""
		face.ZIndex = 2
		face.Parent = holder
		corner(face, 16)
		local faceStroke = outline(face, 2.5)
		grad(face, C.white, C.sand)

		local nm = text(face, "", 14, Enum.Font.GothamBold, C.ink)
		nm.Position = UDim2.fromOffset(8, TANK_H + 11)
		nm.Size = UDim2.new(1, -16, 0, 19)
		nm.ZIndex = 7

		local sub = text(face, "", 13, Enum.Font.LuckiestGuy, C.sea)
		sub.Position = UDim2.fromOffset(8, TANK_H + 29)
		sub.Size = UDim2.new(1, -16, 0, 18)
		sub.ZIndex = 7
		local subStroke = punch(sub, 2)

		local rec = {
			def = d, holder = holder, face = face, faceStroke = faceStroke,
			name = nm, sub = sub, subStroke = subStroke, tank = nil,
		}
		cards[id] = rec

		TouchFit.press(face, function()
			if found[id] then
				openDetail(id)
			else
				-- Not silent: a tile that does nothing reads as a broken button.
				local s = holder:FindFirstChildOfClass("UIScale")
				if not s then
					s = Instance.new("UIScale")
					s.Parent = holder
				end
				TweenService:Create(s, TweenInfo.new(0.09), { Scale = 0.94 }):Play()
				task.delay(0.09, function()
					TweenService:Create(s, TweenInfo.new(0.18, Enum.EasingStyle.Back,
						Enum.EasingDirection.Out), { Scale = 1 }):Play()
				end)
			end
		end)

		styleCard(rec)
	end

	------------------------------------------------------------------
	-- THE VIEWPORT WINDOW
	------------------------------------------------------------------
	--[[
		TESTED BY GEOMETRY, NOT BY INDEX ARITHMETIC.

		The Pets panel works out which rows deserve a model from the cell size, the
		column count and the canvas offset. That is the faster answer and it is the
		wrong one HERE, because this grid is FILTERED: picking "Legendary" hides most
		of the cards and re-flows the rest, so a card's index tells you nothing about
		where it ended up.

		Asking each holder where it actually is costs one AbsolutePosition compare
		per card -- about 160 of them, once per frame at most -- and is immune to
		every layout change the filter chips can make.
	]]
	local RUNUP = CARD_H   -- one card-height of headroom, so a row is filled
	                       -- before it is scrolled into rather than as it lands

	local function ensureView(rec)
		if rec.view and rec.view.Parent then
			return
		end
		if not rec.tank then
			return
		end
		rec.view = putModel(rec.tank, rec.def.ItemId, rec.found == true,
			(CARD_W - 14) / TANK_H, 1.34, 6)
	end

	local function dropView(rec)
		if rec.view then
			rec.view:Destroy()
			rec.view = nil
		end
	end

	local function pass()
		--[[
			CLOSED MEANS EMPTIED, and that is the difference between deferring the
			cost and actually removing it. A hidden ViewportFrame does not render, so
			leaving them up costs no frame time -- but it holds a cloned model and a
			camera per card for the rest of the session, which is most of what this
			whole change exists to avoid on a phone.

			THE DETAIL CARD IS NOT "CLOSED", and that is why the two are tested
			separately. openDetail hides the GRID (scroll.Visible) while the panel
			itself stays open, so exactly one viewport renders; the player is two taps
			from being back on the board, and rebuilding the window they were looking
			at would be a visible stutter for no saving.
		]]
		if not root.Visible then
			for _, rec in pairs(cards) do
				dropView(rec)
			end
			return
		end
		if not scroll.Visible then
			return
		end
		local top = scroll.AbsolutePosition.Y
		local bottom = top + scroll.AbsoluteSize.Y
		for _, rec in pairs(cards) do
			local h = rec.holder
			if h.Visible and h.AbsoluteSize.Y > 0
				and h.AbsolutePosition.Y + h.AbsoluteSize.Y >= top - RUNUP
				and h.AbsolutePosition.Y <= bottom + RUNUP
			then
				ensureView(rec)
			else
				dropView(rec)
			end
		end
	end

	-- ONE PASS PER FRAME whatever asked for it. CanvasPosition changes every frame
	-- of a drag and AbsoluteSize every frame of the open tween; running the sweep
	-- per signal would do one frame's work several times over. Same idiom, and the
	-- same reason, as the Pets panel's own pool.
	local passQueued = false
	function schedule()
		if passQueued then
			return
		end
		passQueued = true
		task.defer(function()
			passQueued = false
			local ok, err = pcall(pass)
			if not ok then
				warn("[Index] viewport pass failed: " .. tostring(err))
			end
		end)
	end

	scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(schedule)
	scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(schedule)
	scroll:GetPropertyChangedSignal("Visible"):Connect(schedule)
	root:GetPropertyChangedSignal("Visible"):Connect(schedule)

	------------------------------------------------------------------
	-- FILTER CHIPS  (after the cards, so they have something to filter)
	------------------------------------------------------------------
	local function paintChips()
		for k, c in pairs(chips) do
			local on = (k == filter)
			c.btn.BackgroundColor3 = on and c.tint or darken(c.tint, 0.55)
			c.btn.BackgroundTransparency = on and 0 or 0.25
			c.label.TextTransparency = on and 0 or 0.35
		end
	end

	for i, key in ipairs(FILTERS) do
		local tint = (key == "All") and C.sea or ItemConfig.rarityInfo(key).color
		local chip = Instance.new("TextButton")
		chip.Name = key
		chip.Size = UDim2.fromOffset(key == "All" and 52 or 84, 28)
		chip.BackgroundColor3 = tint
		chip.BorderSizePixel = 0
		chip.AutoButtonColor = false
		chip.Text = ""
		chip.LayoutOrder = i
		chip.Parent = chipRow
		corner(chip, 14)
		outline(chip, 2.5)

		local lbl = text(chip, string.upper(key), 12, Enum.Font.GothamBold, C.white)
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.ZIndex = 6

		chips[key] = { btn = chip, label = lbl, tint = tint }
		TouchFit.press(chip, function()
			filter = key
			paintChips()
			applyFilter()
		end)
	end
	paintChips()

	------------------------------------------------------------------
	-- ISLAND CHIPS
	------------------------------------------------------------------
	--[[
		ONE TINT FOR ALL NINE, and it is not laziness. The rarity row above is
		colour-coded because rarity IS a colour in this game -- the tile chips, the
		detail pill and the tank stroke all wear it. Place has no palette, and
		inventing nine more hues would make the two rows compete for the eye instead
		of reading as "filter by this, then by that".

		SIZED TO FIT THE ROW RATHER THAN THE WORD. 52 for ALL plus nine at 62 plus
		nine 6px gaps is 664 in a 700-wide panel. "PENGUIN" is the longest short
		form and sits inside 62 at 11pt; anything longer would have had to be
		shortened in ItemConfig.Sources, which is why `short` exists there.
	]]
	local function paintIsles()
		for k, c in pairs(isleChips) do
			local on = (k == isle)
			c.btn.BackgroundColor3 = on and c.tint or darken(c.tint, 0.55)
			c.btn.BackgroundTransparency = on and 0 or 0.25
			c.label.TextTransparency = on and 0 or 0.35
		end
	end

	do
		-- "All" first, then the nine in ItemConfig's own order -- which is the map
		-- read west to east and down, the same order the ferry berths run in.
		local row = { { key = "All", short = "All" } }
		for _, src in ipairs(ItemConfig.Sources) do
			table.insert(row, src)
		end
		for i, src in ipairs(row) do
			local tint = (src.key == "All") and C.sea or C.foam
			local chip = Instance.new("TextButton")
			chip.Name = src.key
			chip.Size = UDim2.fromOffset(src.key == "All" and 52 or 62, 28)
			chip.BackgroundColor3 = tint
			chip.BorderSizePixel = 0
			chip.AutoButtonColor = false
			chip.Text = ""
			chip.LayoutOrder = i
			chip.Parent = isleRow
			corner(chip, 14)
			outline(chip, 2.5)

			local lbl = text(chip, string.upper(src.short), 11, Enum.Font.GothamBold, C.white)
			lbl.Size = UDim2.fromScale(1, 1)
			lbl.ZIndex = 6

			isleChips[src.key] = { btn = chip, label = lbl, tint = tint }
			TouchFit.press(chip, function()
				isle = src.key
				paintIsles()
				applyFilter()
			end)
		end
	end
	paintIsles()

	refreshCount()

	------------------------------------------------------------------
	-- THE DISCOVERY FEED
	------------------------------------------------------------------
	local function sweepBag(quiet)
		for _, rec in ipairs(InventoryController.Client.Items) do
			-- publicView only sends itemId once the server has revealed it, so
			-- a crusted lump in the bag contributes nothing. That is the whole
			-- reason this is safe to read on the client.
			if rec.itemId then
				markFound(rec.itemId, quiet)
			end
		end
	end
	sweepBag(true)
	InventoryController.Client.Changed:Connect(function()
		sweepBag(false)
	end)

	local function onCleaned(payload)
		if type(payload) == "table" and payload.itemId then
			markFound(payload.itemId)
		end
	end
	Net.get("WashItemCleaned").OnClientEvent:Connect(onCleaned)
	Net.get("SiftItemCleaned").OnClientEvent:Connect(onCleaned)

	Net.get("SellResult").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or type(payload.receipt) ~= "table" then
			return
		end
		-- The receipt is the last chance to catch anything picked up and sold
		-- inside a single inventory flush.
		for _, line in ipairs(payload.receipt) do
			markFound(line.itemId)
		end
	end)

	--[[
		THE SAVED SET -- WHICH IS WHAT EVERYTHING ABOVE USED TO START WITHOUT.

		The note further up says the found set is session state that nothing
		persists, and for a long time that was true: this board was rebuilt
		empty on every join and filled only from finds made while online, so a
		collection log with a "N / total FOUND" bar on it read as though it had
		forgotten everything. Two players reported it as the index resetting.
		SaveService now keeps `itemsFound` beside `pets.discovered` and sends
		it here.

		QUIET, because this is a restore and not a discovery. The loud path
		belongs to the moment a find is actually made; eighty cards popping at
		once on join would be neither a celebration nor readable.

		AND IT ASKS, which is what makes the arrival reliable. SaveService also
		sends the set unprompted at the end of its profile apply, but that and
		client boot are not ordered -- on a fast join the send lands before
		this listener exists and hits nothing at all. So the board asks once it
		is ready to hear the answer. When the unprompted send did arrive in
		time, the reply is simply the same ids again and markFound unions them
		away to nothing.
	]]
	local indexSync = Net.get("IndexSync")
	indexSync.OnClientEvent:Connect(function(ids)
		if type(ids) ~= "table" then
			return
		end
		for _, itemId in ipairs(ids) do
			markFound(itemId, true)
		end
	end)
	indexSync:FireServer()

	-- DEV HOOK, the shape the fish index uses -- VirtualInputManager clicks are
	-- capability-blocked, so the click paths need a door that is not a click.
	--   :Fire("Coin")             find one
	--   :Fire("__ALL__")          find everything
	--   :Fire("__RESET__")        clear the board
	--   :Fire("__DETAIL__:Coin")  open that card's detail
	local dev = Instance.new("BindableEvent")
	dev.Name = "DevDiscover"
	dev.Parent = gui
	dev.Event:Connect(function(arg)
		if arg == "__ALL__" then
			for _, id in ipairs(ItemConfig.Order) do
				markFound(id, true)
			end
		elseif arg == "__RESET__" then
			found, foundCount = {}, 0
			for _, rec in pairs(cards) do
				styleCard(rec)
			end
			refreshCount()
		elseif type(arg) == "string" and arg:sub(1, 11) == "__DETAIL__:" then
			openDetail(arg:sub(12))
		else
			markFound(arg)
		end
	end)

	gui:SetAttribute("IndexTotal", total)
	gui:SetAttribute("IndexFound", foundCount)

	-- Kept OFF refresh: ProgressionSync calls refresh on every open panel, and a
	-- coin purchase landing mid-read should not slam the detail card shut.
	panels.Index.closeDetail = closeDetail
	panels.Index.refresh = function()
		sweepBag(true)
		applyFilter()
		refreshCount()
	end
end

--------------------------------------------------------------------------
-- RAIL ICONS
--------------------------------------------------------------------------
--[[
	Drawn from Frames, not emoji.

	The pass before this one used system emoji because the FIRST vector attempt
	was flat white silhouettes, which read as placeholder art. These are the
	other kind of vector icon: full colour, multi-tone, outlined in C.ink and
	sitting under the face's own gloss cap exactly like every other surface in
	this file. An emoji is at the mercy of whatever glyph the player's device
	ships, which is the whole reason these looked wrong.

	Everything is positioned in SCALE inside a square holder, so one definition
	serves any icon size. `px` is only needed for corner radii, which are the one
	thing UICorner insists on in pixels.
]]
function ipart(parent, w, h, x, y, col, r, rot)
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = UDim2.fromScale(w, h)
	f.Position = UDim2.fromScale(x, y)
	f.BackgroundColor3 = col
	f.BorderSizePixel = 0
	f.Rotation = rot or 0
	f.ZIndex = 7
	f.Parent = parent
	if r and r > 0 then
		corner(f, r)
	end
	return f
end

function idisc(parent, d, x, y, col, px)
	return ipart(parent, d, d, x, y, col, px * d * 0.5)
end

STEEL = Color3.fromRGB(226, 232, 240)

local ICONS = {}

-- the turning tide: a ring with an arrow head riding it
function ICONS.Rebirth(g, px)
	local ring = Instance.new("Frame")
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Size = UDim2.fromScale(0.72, 0.72)
	ring.Position = UDim2.fromScale(0.5, 0.54)
	ring.BackgroundTransparency = 1
	ring.ZIndex = 7
	ring.Parent = g
	corner(ring, px * 0.36)
	outline(ring, math.max(4, px * 0.15), C.white)

	local head = ipart(g, 0.36, 0.36, 0.84, 0.3, C.white, px * 0.05, 45)
	head.ZIndex = 8
	outline(head, 2.5)
end

function ICONS.Rewards(g, px)
	local box = ipart(g, 0.8, 0.54, 0.5, 0.7, C.coral, px * 0.08)
	outline(box, 2.5)
	local lid = ipart(g, 0.94, 0.22, 0.5, 0.38, C.coral:Lerp(C.white, 0.22), px * 0.06)
	outline(lid, 2.5)
	local ribbon = ipart(g, 0.16, 0.8, 0.5, 0.58, C.sun, 0)
	ribbon.ZIndex = 9
	for _, sx in { -1, 1 } do
		local bow = idisc(g, 0.28, 0.5 + sx * 0.16, 0.2, C.sun, px)
		bow.ZIndex = 9
		outline(bow, 2)
	end
end

-- a paw: four toes over one pad
--[[
	THE COLLECTION BOARD: a case with four finds set out in it.

	Drawn rather than uploaded, like Pets -- a sprite would want a new asset on
	the group and the fallback glyph is what buildRail's IconSlot exists for.

	THREE FILLED AND ONE EMPTY, which is the whole idea in one shape: the Index
	is a thing you are part way through. Four solid tiles would read as a grid
	button and say nothing about collecting.
]]
function ICONS.Index(g, px)
	local case = ipart(g, 0.78, 0.68, 0.5, 0.52, STEEL, px * 0.12)
	case.ZIndex = 7
	outline(case, 2.5)

	-- Three found, set in rows of two, and the fourth slot left open.
	for _, t in { { 0.33, 0.37, C.coral }, { 0.67, 0.37, C.sun }, { 0.33, 0.67, C.lime } } do
		local find = ipart(g, 0.22, 0.2, t[1], t[2], t[3], px * 0.05)
		find.ZIndex = 9
		outline(find, 2)
	end
	-- The one still to find: the case's own shade, so it reads as an empty slot
	-- rather than as a fourth item in a colour nobody has seen.
	local empty = ipart(g, 0.22, 0.2, 0.67, 0.67, darken(STEEL, 0.28), px * 0.05)
	empty.ZIndex = 9
	outline(empty, 2)
end

function ICONS.Pets(g, px)
	local pad = ipart(g, 0.52, 0.4, 0.5, 0.68, C.sun, px * 0.2)
	pad.ZIndex = 8
	outline(pad, 2.5)
	for _, t in { { 0.23, 0.38 }, { 0.41, 0.24 }, { 0.59, 0.24 }, { 0.77, 0.38 } } do
		local toe = idisc(g, 0.21, t[1], t[2], C.sun, px)
		toe.ZIndex = 8
		outline(toe, 2)
	end
end

function ICONS.Shop(g, px)
	local handle = ipart(g, 0.11, 0.42, 0.19, 0.32, STEEL, px * 0.04, -26)
	outline(handle, 2.5)
	local basket = ipart(g, 0.68, 0.44, 0.57, 0.52, STEEL, px * 0.07)
	basket.ZIndex = 8
	outline(basket, 2.5)
	for _, x in { 0.4, 0.74 } do
		local wheel = idisc(g, 0.2, x, 0.86, darken(C.wood, 0.3), px)
		wheel.ZIndex = 9
		outline(wheel, 2)
	end
end

--[[
	Two chevrons climbing. It is the one shape that reads as "upgrade" with no
	word under it, which matters here more than on the other five: this key loses
	its caption on a phone exactly like they do (see the UiFit branch in
	buildRail), and unlike them it has no uploaded sprite to fall back on.

	ROTATION IS CLOCKWISE AND SCREEN Y GROWS DOWNWARD, so the LEFT arm of a "^"
	takes a NEGATIVE angle to lift its inner end and the right arm a positive one
	-- hence `sx * 38` rather than a sign picked by eye. Half of a 0.44 bar at 38
	degrees reaches 0.173 across and 0.135 up, so arms centred either side of
	0.5 by 0.145 overlap through the apex instead of leaving a notch in it.
]]
function ICONS.Upgrades(g, px)
	for i, y in { 0.66, 0.34 } do
		for _, sx in { -1, 1 } do
			local arm = ipart(g, 0.44, 0.155, 0.5 + sx * 0.145, y, C.white, px * 0.05, sx * 38)
			arm.ZIndex = 7 + i
			outline(arm, 2.5)
		end
	end
end

-- gear: teeth ringed round a hub that is drawn over their inner ends, which is
-- what keeps eight outlined squares from showing their seams
function ICONS.Settings(g, px)
	for i = 0, 7 do
		local a = i * math.pi / 4
		local tooth = ipart(g, 0.26, 0.26,
			0.5 + math.cos(a) * 0.37, 0.5 + math.sin(a) * 0.37, STEEL, px * 0.04, math.deg(a))
		outline(tooth, 2)
	end
	local hub = idisc(g, 0.7, 0.5, 0.5, STEEL, px)
	hub.ZIndex = 9
	outline(hub, 2.5)
	local hole = idisc(g, 0.28, 0.5, 0.5, darken(C.wood, 0.3), px)
	hole.ZIndex = 10
	outline(hole, 2)
end

--------------------------------------------------------------------------
-- RAIL
--------------------------------------------------------------------------
-- `emoji` is no longer read; ICONS above is keyed by `name`. Left in place so
-- the table still documents what each button was meant to depict.
-- SHOP HERE MEANS THE ROBUX SHOP, and only that. There are two shops in this
-- game -- the coin stock list (four tracks and the car ladder, capped by the
-- tide and wiped by a rebirth) and the Robux unlocks (bought once, kept for
-- good) -- and one key was standing for both. SHOP is now unambiguously the
-- second. The first is the counters' job: see the note on the commented-out
-- Upgrades entry below.
-- Skins is still gone: it was a placeholder panel taking up a slot.
-- Index followed them off: it is the computer on Beach.IndexTerminal now, and
-- the prompt on that desk is the only thing that opens it. Its hand-drawn book
-- glyph went with the key -- ICONS is keyed by `name`, so a drawing for a key
-- that is not on the rail could never be reached again.
-- `icon` is the uploaded sprite; where one is set it replaces the hand-drawn
-- glyph entirely, which is what the IconSlot in buildRail was always there for.
-- Pets has no sprite and still draws its own, so buildRail has to cope with
-- both -- hence the branch rather than a blanket swap.
local RAIL = {
	-- alert/alertDriven: the mark comes up when the tide can actually be turned
	-- and stays down until then -- see refreshRebirthAlert for the two reports
	-- that asked for it. DRIVEN, like Rewards, because the answer changes; the
	-- Shop's undriven mark is a standing "you have not looked in here" and a
	-- different thing entirely.
	{ name = "Rebirth",  tint = C.sea,   emoji = "🌊", icon = "rbxassetid://103945333054072", alert = true, alertDriven = true },
	{ name = "Rewards",  tint = C.lime,  emoji = "🎁", icon = "rbxassetid://101052520145515", alert = true, alertDriven = true },
	-- The wardrobe lives in this panel now, so the key says so. `label` is the
	-- CAPTION only -- the key stays "Pets" because panels, ICONS and railBadges
	-- are all indexed by it. See the note by `cap` in buildRail for the "&".
	{ name = "Pets",     label = "PETS & SKINS",
	  tint = C.grape:Lerp(C.coral, 0.35), emoji = "🐾", icon = "rbxassetid://123820048610246" },
	-- Seal A Driveway's shop key is rbxassetid://80513192214844 and CANNOT be used
	-- here: that asset belongs to group 261071327, this place to group 4620487, and
	-- Roblox refuses an image the experience's owner does not own. Measured, not
	-- assumed -- it reports IsLoaded=false while a control image beside it loads,
	-- and it fails SILENTLY, drawing an empty button rather than erroring. To share
	-- the art, re-upload the same file under this group and swap the id below.
	-- UPGRADES IS OFF THE RAIL AGAIN, and nothing has become unreachable by it.
	-- The key opened panels.Store -- the SAME stock list the four world counters
	-- open, wired in wireWorldPrompts -- so every track and the car ladder are
	-- still bought exactly where they always were. This removes a second way in,
	-- not the way in.
	--
	-- To put it back, uncomment the line below: ICONS.Upgrades still draws its
	-- glyph, RAIL_H is derived off #RAIL so the column re-measures itself, and
	-- the special case in buildRail's click handler is still there waiting. `foam`
	-- rather than the sun the Store panel wears, because two yellow keys side by
	-- side is the ambiguity that split existed to remove.
	--   { name = "Upgrades", tint = C.foam,  emoji = "⬆️" },
	--[[
		THE INDEX GOT A KEY OF ITS OWN. Asked for on 2026-09-16: "I sure wish we
		could see the index on every island, or even from a permanent UI button."

		It was reachable only through Pets -> INDEX, which is two taps behind a
		panel about something else -- and the player who asked was on his third
		message of the evening, so he had looked. This is the fourth findability
		miss in the same queue; the others were Flash Effects, Time of Day and
		rebirth.

		RAIL_H is derived off #RAIL, so the column re-measures itself for a sixth
		key with nothing else to change, and the click handler resolves
		panels.Index off the name like every other generic key.

		THE SPRITE WAS CHECKED BEFORE IT WENT IN, because an icon this place does
		not own fails SILENTLY -- the note on the Shop key above records that, and
		adding an `icon` removes the drawn fallback (see `if not e.icon` in
		buildRail), so a dead id would leave a blank button rather than a glyph.
		Tested through ContentProvider:PreloadAsync's STATUS CALLBACK rather than
		ImageLabel.IsLoaded, for the reason the shelf note at the top of this file
		gives at length: IsLoaded never becomes true in this place, on any asset.
		This id reported Success, alongside the Rebirth key as a control -- and
		IsLoaded was false for both.

		ICONS.Index IS KEPT rather than deleted, the same way ICONS.Upgrades is
		kept for a key that is commented out: it costs nothing and it is what
		buildRail falls back to if this id is ever pulled or moderated.

		CORAL because the other five are taken: sea, lime, grape-to-coral, sun and
		grape. `foam` is spoken for by the commented-out Upgrades key above.
	]]
	{ name = "Index",    tint = C.coral, emoji = "\240\159\147\148", icon = "rbxassetid://140277415442153" },
	{ name = "Shop",     tint = C.sun,   emoji = "🛒", icon = "rbxassetid://139248949720401", flashy = true, alert = true },
	{ name = "Settings", tint = C.grape, emoji = "⚙️", icon = "rbxassetid://103717590058681" },
}

-- FIVE buttons since Upgrades came off: 5 * 99 + 4 * 8 = 527 tall. That clears
-- a 1080 screen with room to spare and still does NOT fit a phone -- see
-- fitRail in buildRail, which measures the room the screen actually has and
-- shrinks the whole column into it rather than trusting a number authored
-- against a monitor.
--
-- SO NOTHING HAD TO BE RESIZED BY HAND WHEN THE KEY CAME OFF, and that is the
-- point of writing RAIL_H off #RAIL rather than typing the number: adding or
-- dropping a key moves the height, fitRail re-measures, and every key grows or
-- shrinks together by whatever the screen actually needs. On a desktop that is
-- nothing. The floor is MIN_KEY 34 and no real device gets near it.
local BTN = 92

-- The column's authored height, and the one number the fit measures against.
-- Derived off RAIL, so adding a key cannot leave the arithmetic behind.
local RAIL_H = #RAIL * (BTN + 7) + (#RAIL - 1) * 8

-- How far in off the right edge the column normally sits. Named because
-- fitRail's sidestep is written as an ADDITION to it, and a magic 20 in two
-- places is how the two drift apart.
local RAIL_GUTTER = 20

--[[
	THE SHOP BUTTON, and only the shop button.

	Ported from Seal A Driveway's rail key (SealerUI.Shell, _buildRail) so the two
	games' shops read as the same brand. Every number below is that key's rather
	than a fresh guess, because they were already tuned against the same problem:
	a button that has to be found without being looked for, on a rail a player
	stares at for a whole session.

	  * a bob on the holder -- 7% of scale on a 1.5s cycle. Past about 9% the
	    caption under it visibly swims, which reads as broken rather than lively.
	  * a ten-ray sunburst behind the icon, turning once every 26s
	  * TWO sheens, at 1.9s and 2.9s. One sweep every 1.9s is the flashiest a
	    single sheen gets before it stops reading as a pass of light and starts
	    reading as a flicker; a second at a period that is NOT a multiple of the
	    first gets past that ceiling honestly, because the two drift in and out of
	    phase and only realign every 55 seconds.
	  * the icon rocking in short bursts with a full second of rest between them.
	    A shake that never stops is something the eye adapts to and then filters
	    out as texture; one that stops and starts re-arrives every time.

	THE BURST IS TINTED TO THE KEY, NOT WHITE. That is the lesson the original
	carries: brightness is what makes a fan of rays read as light, and WHITENESS
	is what makes it swallow the icon standing in it. Seal A Driveway's key is
	green and lights it green, so this one lights C.sun warm.

	THE ROCK GOES ON THE ICON, NOT THE KEY. Rotating the button turns its caption
	with it, and a tilting word reads as a bug. That is also why the bob gets the
	holder and the rock gets the picture.

	ONLY THE SHOP. The moment a second key moves, neither is the one that moves.
--]]
local function bob(inst, amount, period)
	local sc = inst:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	sc.Parent = inst
	--[[
		HANDED TO Motion RATHER THAN GATED, and the difference is not academic:
		this helper is called while the rail is built, which happens before the
		profile carrying Set_ReducedMotion has loaded. An `if not reduced` here
		asks the question too early and always gets "no" -- measured, with the
		setting on and persisted, this icon was still bobbing.

		Motion.loop starts it only when motion is allowed and cancels it the
		moment the answer changes, which also covers the switch being thrown
		mid-session. The rest closure puts the scale back to 1 so a stopped bob
		does not leave the icon frozen 7% too big.
	]]
	Motion.loop(
		TweenService:Create(sc, TweenInfo.new(period or 1.6, Enum.EasingStyle.Sine,
			Enum.EasingDirection.InOut, -1, true), { Scale = 1 + (amount or 0.045) }),
		function()
			sc.Scale = 1
		end)
	return sc
end

local function sunburst(parent, rays, diameter, colour, z)
	local hub = Instance.new("Frame")
	hub.Name = "Sunburst"
	hub.BackgroundTransparency = 1
	hub.AnchorPoint = Vector2.new(0.5, 0.5)
	hub.Position = UDim2.fromScale(0.5, 0.5)
	hub.Size = UDim2.fromOffset(diameter, diameter)
	hub.ZIndex = z or parent.ZIndex
	hub.Parent = parent

	for i = 1, rays do
		local r = Instance.new("Frame")
		r.Name = "Ray"
		r.AnchorPoint = Vector2.new(0.5, 0.5)
		r.Position = UDim2.fromScale(0.5, 0.5)
		r.Size = UDim2.fromOffset(math.max(4, math.floor(diameter * 0.09)), diameter)
		r.BackgroundColor3 = colour
		r.BackgroundTransparency = 0.62
		r.BorderSizePixel = 0
		r.Rotation = (i - 1) * (180 / rays)
		r.ZIndex = hub.ZIndex
		r.Parent = hub
		-- tapered rather than a bar, so the fan reads as light and not as a wheel
		local g = Instance.new("UIGradient")
		g.Rotation = 90
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.15),
			NumberSequenceKeypoint.new(1, 1),
		})
		g.Parent = r
	end

	-- A rotation that never stops. Slow enough at 26 seconds that it reads as
	-- atmosphere rather than animation, which is why it is easy to leave running
	-- and why it is registered rather than merely started. The rays stay drawn
	-- and lit; they hold still, squared back to 0.
	Motion.loop(
		TweenService:Create(hub, TweenInfo.new(26, Enum.EasingStyle.Linear,
			Enum.EasingDirection.InOut, -1), { Rotation = 180 }),
		function()
			hub.Rotation = 0
		end)
	return hub
end

-- A gradient offset sweep rather than a clipped bar: it takes the corner radius
-- from the thing it is laid over, so it cannot spill past a rounded edge.
local function sheen(inst, period, z)
	local sh = Instance.new("Frame")
	sh.Name = "Sheen"
	sh.BackgroundColor3 = C.white
	sh.BorderSizePixel = 0
	sh.Size = UDim2.fromScale(1, 1)
	sh.ZIndex = z or (inst.ZIndex + 1)
	sh.Parent = inst
	local c = inst:FindFirstChildOfClass("UICorner")
	corner(sh, c and c.CornerRadius.Offset or 12)

	local g = Instance.new("UIGradient")
	g.Rotation = 18
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.42, 1),
		NumberSequenceKeypoint.new(0.5, 0.72),
		NumberSequenceKeypoint.new(0.58, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	g.Offset = Vector2.new(-1.4, 0)
	g.Parent = sh
	task.spawn(function()
		local gap = period or 2.2
		while sh.Parent do
			TweenService:Create(g, TweenInfo.new(gap, Enum.EasingStyle.Quad,
				Enum.EasingDirection.InOut), { Offset = Vector2.new(1.4, 0) }):Play()
			task.wait(gap + 2 + math.random() * 3)
			g.Offset = Vector2.new(-1.4, 0)
		end
	end)
	return sh
end

--[[
	THE ALERT BADGE.

	A mark in the inward top corner of a key, overhanging its edge the way a
	notification count does. Deliberately the one STILL thing on the shop key:
	it already bobs, sheens twice and rocks its icon, and a badge that also
	pulsed would be lost in that. Motion draws the eye to the key; the badge is
	what the eye lands on once it is there.

	It is a single piece of uploaded art rather than a red disc with a glyph
	drawn on it. The art is already a red mark with its own navy outline and
	highlight, so a disc behind it would be red on red -- the drawing IS the
	badge, and the frame is only there to place and size it.

	ZIndex 9 clears everything on the face -- icon 6, caption 7, sheen 8 -- so
	the light sweeps UNDER it rather than washing across it.
--]]
local function alertBadge(face)
	local badge = Instance.new("Frame")
	badge.Name = "Alert"
	badge.AnchorPoint = Vector2.new(0.5, 0.5)
	-- Top LEFT, which on this rail is the INWARD corner. The keys sit hard
	-- against the right edge of the screen, so a badge on the outward side
	-- overhangs toward it -- it was already reaching 3px past the rail, and on a
	-- narrower screen that is the first thing to get clipped. Inward, it always
	-- has the whole screen behind it.
	badge.Position = UDim2.fromScale(0.13, 0.13)
	-- Taller than the disc it replaces (30) because the art is a tall glyph in a
	-- square image: Fit letterboxes it, so the box height IS the mark height and
	-- it would otherwise read smaller than what was there before.
	badge.Size = UDim2.fromOffset(36, 36)
	badge.BackgroundTransparency = 1
	badge.ZIndex = 9
	badge.Parent = face

	local mark = Instance.new("ImageLabel")
	mark.Name = "Mark"
	mark.BackgroundTransparency = 1
	mark.Size = UDim2.fromScale(1, 1)
	mark.Image = ALERT_MARK
	-- Fit, not Stretch: the source is square with the glyph centred in it, and
	-- stretching to a non-square box would fatten the mark.
	mark.ScaleType = Enum.ScaleType.Fit
	mark.ZIndex = 10
	mark.Parent = badge

	-- A black copy a couple of pixels down-right. The art carries its own
	-- outline, but it is thin, and this rail sits over bright sand and white
	-- surf where a thin dark line on a red mark is exactly what disappears.
	local shadow = mark:Clone()
	shadow.Name = "MarkShadow"
	shadow.Image = ALERT_MARK
	shadow.ImageColor3 = Color3.new(0, 0, 0)
	shadow.ImageTransparency = 0.55
	shadow.Position = UDim2.fromOffset(2, 3)
	shadow.ZIndex = 9
	shadow.Parent = badge

	return badge
end

local function flashy(face, slot, tint)
	-- THE PICTURE PULSES, NOT THE KEY.
	--
	-- This started on the holder, which is where Seal A Driveway puts it -- but
	-- that scales the whole square: the plastic, its outline, its shadow slab and
	-- the caption all breathe together, so one key on a rail of five is
	-- permanently changing size. Moving it to the ImageLabel keeps every key
	-- identical and lets the art inside do the moving, which is the part worth
	-- looking at anyway.
	--
	-- It also retires the reason the amount was capped at 7% -- nothing is
	-- dragging a caption about any more -- so this is free to go livelier later.
	bob(slot, 0.07, 1.5)

	-- Inside the plastic, and tinted toward the key's own colour. At a wider
	-- diameter in near-white it spills past the key and washes the icon out --
	-- the burst becomes the icon, which is precisely backwards.
	sunburst(face, 10, BTN * 1.12, tint:Lerp(C.white, 0.55), 5)

	sheen(face, 1.9, 8)
	sheen(face, 2.9, 8)

	-- The rock. Two left-right wobbles, then centre and a full second still.
	local SHAKE = 8
	local OUT, BACK, REST = 0.11, 0.2, 1
	local WOBBLES = 2
	if slot and slot.Visible then
		local function turn(to, secs)
			TweenService:Create(slot, TweenInfo.new(secs, Enum.EasingStyle.Sine,
				Enum.EasingDirection.InOut), { Rotation = to }):Play()
			task.wait(secs)
		end
		task.spawn(function()
			-- stops with the rail rather than outliving it
			while slot.Parent do
				for i = 1, WOBBLES do
					-- only the FIRST leg is a flick from standstill; the rest are
					-- already in motion, so they take the full crossing time
					turn(-SHAKE, if i == 1 then OUT else BACK)
					turn(SHAKE, BACK)
				end
				turn(0, OUT)
				task.wait(REST)
			end
		end)
	end
end

local function buildRail()
	rail = Instance.new("Frame")
	rail.Name = "Rail"
	rail.AnchorPoint = Vector2.new(1, 0.5)
	-- The authored pose. fitRail below re-solves it on the first frame and on
	-- every change after that, so this is only what it looks like until then.
	rail.Position = UDim2.new(1, -RAIL_GUTTER, 0.5, 0)
	rail.Size = UDim2.fromOffset(BTN, RAIL_H)
	rail.BackgroundTransparency = 1
	rail.Parent = gui

	--[[
		THE RAIL IS MEASURED INTO THE ROOM IT HAS, NOT AUTHORED AND HOPED FOR.

		527 pixels of keys is a desktop number. UiFit scales the HUD down for a
		phone but stops at 0.6 -- deliberately, because below that a 92px key
		stops being a target -- and 527 * 0.6 is 316 pixels of rail in the 272 a
		landscape phone leaves under the topbar. Measured on a 685x338 viewport:
		REBIRTH, REWARDS and PETS were on screen, SHOP was two thirds off the
		bottom of it and SETTINGS was not on it at all.

		A FLOOR THAT PROTECTS TOUCH TARGETS CANNOT ALSO GUARANTEE A FIT, and
		UiFit's floor is there for a good reason, so this does not lower it. The
		rail carries a UIScale of its own on top of UiFit's and shrinks only
		itself, only as far as it has to, and only on the screens that cannot
		hold it. A desktop computes want = 1 and lands where it always did.

		THE OLD CORRECTION COUNTED THE TOPBAR TWICE, which is most of what ran
		the rail off the bottom. It compared GuiService.TopbarInset -- TRUE
		screen coordinates, Max.Y = 58 -- against rail.AbsolutePosition.Y, which
		is measured from the BOTTOM of the gui inset whatever a ScreenGui says
		about IgnoreGuiInset. Probed rather than assumed: a Frame at Position
		(0, 0) in an IgnoreGuiInset ScreenGui reports AbsolutePosition (0, -58),
		and the same Frame in an inset-respecting one reports (0, 0). So the
		rail was pushed a whole inset further down than the topbar ever needed.
		GetGuiInset is what takes that back.

		STATELESS, where the old pass tracked what it had `applied` and undid it
		on the way to a new answer. Every number below comes from the camera, the
		topbar and the parent scale -- never from where the rail currently sits --
		so running it twice writes the same values twice. That matters, because
		writing them is what re-fires the AbsoluteSize signal that runs it.
	]]
	do
		-- A little air, so a key never kisses the topbar or the screen edge.
		local MARGIN = 8
		-- Floor on a key's rendered size. Fitting wins over comfort -- a key off
		-- the bottom of the screen cannot be pressed at all -- but not past the
		-- point where what is left is no longer a button. No real device gets
		-- anywhere near this; it is a backstop, not a target.
		local MIN_KEY = 34
		--[[
			HOW FAR LEFT THE JUMP BUTTON MAY BE PUSHED.

			It is moved out of the rail's column rather than dodged -- see placeJump
			-- but not without limit. The left end of a landscape phone is the
			movement thumbstick, and a jump button shoved into that is just a
			different unpressable button. Roblox parks the stick around x = 120, so
			this stops well clear of it.
		]]
		local JUMP_MIN_X = 170

		local shrink = Instance.new("UIScale")
		shrink.Parent = rail

		-- UiFit's scale, and anything else between the rail and the screen. NOT
		-- the rail's own, which is the thing being solved for.
		local function parentScale(): number
			local s, node = 1, rail.Parent
			while node and node:IsA("GuiObject") do
				local us = node:FindFirstChildOfClass("UIScale")
				if us then
					s *= us.Scale
				end
				node = node.Parent
			end
			return (s > 0) and s or 1
		end

		-- Roblox's own jump button. nil on anything without touch controls, which
		-- is what keeps a desktop out of the branch entirely.
		local function jumpButton(): GuiObject?
			local pg = player:FindFirstChild("PlayerGui")
			local touch = pg and pg:FindFirstChild("TouchGui")
			local btn = touch and touch:FindFirstChild("JumpButton", true)
			return (btn and btn:IsA("GuiObject")) and btn or nil
		end

		--[[
			MOVE ROBLOX'S BUTTON OUT OF THE COLUMN, RATHER THAN DODGING IT.

			WHY THIS IS SAFE TO DO AT ALL: the tap-eating problem the old sidestep
			existed for is a render-order one. TouchGui is built with no DisplayOrder
			(ControlModule:CreateTouchGuiContainer) so it draws at 0 while this gui
			is at 12, and a TextButton over the jump button does not merely hide it,
			it EATS THE TAP. Moving the button out from under the rail removes the
			overlap entirely, so there is no render order left to lose to.

			WRITTEN IN THE HOLDER'S OWN UNITS, at scale 0 with a plain offset, so it
			does not matter whether TouchControlFrame is full-width -- which is not
			something to assume about a frame Roblox owns and may re-shape.

			THE ONE-PIXEL TOLERANCE IS WHAT STOPS A LOOP. watchJump re-runs fitRail
			on this button's AbsolutePosition changing, which is exactly what writing
			Position here does -- so without a test for "already there" this would
			call itself forever. It also means Roblox putting the button back on a
			control-scheme change is simply undone on the next pass.
		]]
		local function placeJump(railLeft: number)
			local btn = jumpButton()
			if not (btn and btn.Visible and btn.AbsoluteSize.X > 0) then
				return
			end
			local holder = btn.Parent
			if not (holder and holder:IsA("GuiObject") and holder.AbsoluteSize.X > 0) then
				return
			end

			local wantX = math.max(JUMP_MIN_X, railLeft - MARGIN - btn.AbsoluteSize.X)
			local offset = wantX - holder.AbsolutePosition.X
			if btn.Position.X.Scale ~= 0 or math.abs(btn.Position.X.Offset - offset) > 1 then
				btn.Position = UDim2.new(0, offset, btn.Position.Y.Scale, btn.Position.Y.Offset)
			end
		end

		local function fitRail()
			local camera = workspace.CurrentCamera
			if not camera or camera.ViewportSize.Y <= 1 then
				return
			end
			local parent = rail.Parent
			if not (parent and parent:IsA("GuiObject")) then
				return
			end

			local s = parentScale()
			local inset = GuiService:GetGuiInset().Y
			local full = RAIL_H * s

			-- The topbar's reserved band runs to the right edge of the screen on
			-- every device measured, and this rail is always hard right, so it is
			-- always underneath it. No x test worth writing.
			local top = math.max(MARGIN, (GuiService.TopbarInset.Max.Y - inset) + MARGIN)
			local roomBottom = camera.ViewportSize.Y - inset - MARGIN

			--[[
				THE RAIL NO LONGER DODGES THE BUTTON. THE BUTTON MOVES.

				This used to try to fit ABOVE the jump button and step LEFT of it when
				it could not. Measured across every landscape phone size, fitting
				above it was never once affordable -- five keys of 92 is 527 authored
				against about 300 of usable column, so a key that cleared came out at
				25 to 35px, under the 44 that test exists to protect:

				  896x414   35.3      812x375   28.5
				  844x390   31.1      780x360   25.8

				So the sidestep was never the fallback on a phone, it WAS the layout,
				and it parked the whole rail over the middle of the play area for the
				whole session. The rail keeps the corner it was designed for, and
				placeJump takes the button out from under it instead.
			]]
			local bottom = roomBottom

			local want = math.clamp((bottom - top) / full, math.min(1, MIN_KEY / (BTN * s)), 1)
			shrink.Scale = want

			-- Centred in the room it is allowed, which reduces to top-aligned the
			-- moment the rail only just fits.
			local h = full * want
			local y = math.clamp((top + bottom - h) * 0.5, top, math.max(top, bottom - h))

			-- Where the rail's own left edge lands, in screen pixels. The button is
			-- placed against THIS rather than against a guess, so it follows the rail
			-- through every scale the clamp above can choose -- and on a desktop,
			-- where there is no jump button at all, placeJump returns immediately.
			placeJump(camera.ViewportSize.X - RAIL_GUTTER * s - BTN * s * want)

			-- Position is written in the PARENT's units, and AnchorPoint 0.5 means
			-- the offset moves the CENTRE -- so the answer is measured off where
			-- {0.5, 0} actually lands rather than off the screen's own middle.
			-- `shift` is screen pixels and this is parent units, hence the divide.
			local mid = parent.AbsolutePosition.Y + parent.AbsoluteSize.Y * 0.5
			rail.Position = UDim2.new(1, -RAIL_GUTTER, 0.5, (y + h * 0.5 - mid) / s)
		end

		task.defer(fitRail)
		GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(fitRail)
		-- Catches UiFit adopting the rail into its scaled FitRoot, and every
		-- later change to that scale.
		rail:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitRail)
		-- A viewport that changes without moving UiFit off its floor leaves
		-- AbsoluteSize alone, so the camera has to be asked directly as well.
		local function watchCamera(cam)
			if cam then
				cam:GetPropertyChangedSignal("ViewportSize"):Connect(fitRail)
			end
		end
		watchCamera(workspace.CurrentCamera)
		workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
			watchCamera(workspace.CurrentCamera)
			fitRail()
		end)

		--[[
			THE JUMP BUTTON IS NOT A CONSTANT, AND NOTHING ELSE HERE REPORTS THAT
			IT MOVED.

			It arrives after this runs, it is re-laid-out whenever the viewport
			changes, and it is destroyed outright when a player picks up a
			gamepad. Each of those moves the bottom of the band, and the camera
			and AbsoluteSize signals above see none of them -- caught by driving
			one from y = 300 to y = 120 and watching the rail keep the size it had
			chosen for the first position.

			The viewport case also has an ORDER to it: the camera signal can run
			before Roblox has moved its own controls, so that pass fits against a
			stale button. Its AbsolutePosition changing is what corrects it, which
			is free because fitRail is stateless -- a second run over the same
			inputs writes the same answer.
		]]
		local watched
		local function watchJump()
			local btn = jumpButton()
			if btn ~= watched then
				watched = btn
				if btn then
					btn:GetPropertyChangedSignal("AbsolutePosition"):Connect(fitRail)
					btn:GetPropertyChangedSignal("Visible"):Connect(fitRail)
					btn.AncestryChanged:Connect(function()
						watched = nil
						task.defer(fitRail)
					end)
				end
			end
			fitRail()
		end
		task.defer(watchJump)
		local pg = player:FindFirstChild("PlayerGui")
		if pg then
			local function onTouchGui(c)
				if c.Name == "TouchGui" then
					task.defer(watchJump)
				end
			end
			pg.ChildAdded:Connect(onTouchGui)
			pg.ChildRemoved:Connect(onTouchGui)
		end
	end

	local ly = Instance.new("UIListLayout")
	ly.Padding = UDim.new(0, 8)
	ly.SortOrder = Enum.SortOrder.LayoutOrder
	ly.Parent = rail

	for i, e in RAIL do
		local holder, face = chunky(rail, BTN, BTN, e.tint, 26)
		holder.Name = e.name
		holder.LayoutOrder = i

		local slot = Instance.new("ImageLabel")
		slot.Name = "IconSlot"
		slot.BackgroundTransparency = 1
		-- Centred on the middle of its own box rather than hung from the top, so a
		-- UIScale on it grows evenly in every direction instead of pushing it down
		-- into the caption. The occupied rectangle is unchanged: 0.07..0.63 either
		-- way, which is why this is safe to do for every key and not just the Shop.
		slot.AnchorPoint = Vector2.new(0.5, 0.5)
		slot.Position = UDim2.fromScale(0.5, 0.35)
		slot.Size = UDim2.fromScale(0.56, 0.56)
		slot.Image = e.icon or ""
		slot.Visible = e.icon ~= nil
		slot.ScaleType = Enum.ScaleType.Fit    -- never squash art to the square
		slot.ZIndex = 6
		slot.Parent = face

		-- The hand-drawn glyph is the FALLBACK now, not the default. Building it
		-- unconditionally would stack a vector icon underneath every sprite.
		local glyphHolder
		if not e.icon then
			local glyph = Instance.new("Frame")
			glyph.Name = "Icon"
			glyph.AnchorPoint = Vector2.new(0.5, 0)
			glyph.Position = UDim2.fromScale(0.5, 0.09)
			glyph.Size = UDim2.fromOffset(BTN * 0.48, BTN * 0.48)
			glyph.BackgroundTransparency = 1
			glyph.ZIndex = 6
			glyph.Parent = face
			local draw = ICONS[e.name]
			if draw then
				draw(glyph, BTN * 0.48)
			end
			glyphHolder = glyph
		end

		if e.flashy then
			flashy(face, slot, e.tint)
		end
		if e.alert then
			local badge = alertBadge(face)
			railBadges[e.name] = badge
			--[[
				A DRIVEN MARK STARTS DOWN.

				The Shop's is not driven -- it is a standing "you have not looked
				in here yet". The Rewards one answers a question whose answer
				changes, so it comes up only when refreshRewardsAlert says so, and
				putting it on screen before the first sync would be a guess.
			]]
			if e.alertDriven then
				badge.Visible = false
			end
		end

		-- Caption straight onto the face. It used to sit on a plate darkened 55%
		-- off the tint, with its own 2.5px outline -- which read as a grey box
		-- wedged between the word and the button rather than as part of either.
		-- The label's own ink stroke is what carries it now, so it is a shade
		-- thicker than it needed to be over a dark plate.
		--[[
			`label` OVERRIDES THE CAPTION AND NOTHING ELSE. `name` is the KEY --
			ICONS, panels and railBadges are all indexed by it, and the click handler
			below resolves the panel from it -- so a button that wants to say
			something other than its key says it here rather than being renamed.

			MEASURED, because the box does not truncate (TextTruncate.None below) and
			a caption that does not fit simply spills. The box is 84px -- the key is
			92 less 8 of padding -- and at 12px LuckiestGuy "PETS AND SKINS" measures
			94 and overflows, where "PETS & SKINS" measures 77 and fits. Hence the
			ampersand. It is the longest caption on the rail (SETTINGS, the previous
			longest, is 55), so 84 is the real ceiling for anything added here later.
		]]
		local cap = text(face, e.label or e.name:upper(), 12, Enum.Font.LuckiestGuy, C.white)
		cap.AnchorPoint = Vector2.new(0.5, 1)
		cap.Position = UDim2.new(0.5, 0, 1, -7)
		cap.Size = UDim2.new(1, -8, 0, 22)
		cap.TextScaled = false
		cap.TextTruncate = Enum.TextTruncate.None
		cap.ZIndex = 7
		punch(cap, 3)

		--[[
			THE CAPTION COMES OFF ON A SMALL SCREEN.

			UiFit scales the whole rail down to fit a phone -- five 92px keys are
			527px of a 390px screen otherwise -- but scaling is the wrong answer for
			type that is already 12px. At the floor scale this word renders about
			seven pixels tall, which is not small, it is unreadable, and it still
			eats the bottom third of a key that has become quite small itself.

			So below the compact threshold the word goes and the picture takes the
			space. That is only defensible because the rail wears real art now: an
			icon that identifies the button on its own is exactly what makes the
			label optional. Back when these were hand-drawn glyphs it would not
			have been.
		--]]
		UiFit.onChanged(function()
			local tight = UiFit.compact()
			cap.Visible = not tight
			-- With no caption under it there is no reason for the icon to sit high
			-- in the key; centred and larger, it reads at a glance on a phone.
			slot.Size = UDim2.fromScale(tight and 0.72 or 0.56, tight and 0.72 or 0.56)
			slot.Position = UDim2.fromScale(0.5, tight and 0.5 or 0.35)
			if glyphHolder then
				glyphHolder.Size = UDim2.fromOffset(BTN * (tight and 0.62 or 0.48),
					BTN * (tight and 0.62 or 0.48))
				glyphHolder.Position = UDim2.fromScale(0.5, tight and 0.19 or 0.09)
			end
		end)

		face.MouseEnter:Connect(function()
			TweenService:Create(face, TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Rotation = (i % 2 == 0) and 4 or -4 }):Play()
		end)
		face.MouseLeave:Connect(function()
			TweenService:Create(face, TweenInfo.new(0.14), { Rotation = 0 }):Play()
		end)
		TouchFit.press(face, function()
			--[[
				THE UPGRADES KEY OPENS THE STOCK LIST, AND IT IS THE ONLY SPECIAL CASE
				ON THIS RAIL.

				The key is called Upgrades and the panel is called Store, so the name
				does not resolve on its own. Renaming the panel is not worth it --
				panels.Store is what four world counters and wireWorldPrompts already
				call it, and renaming for the benefit of one click handler is how a
				string gets changed in three files and missed in a fourth.

				It used to open a signpost reading "walk up to a counter", which was
				true, is still true, and was the wrong thing for the most-pressed key
				on the rail to do. A player finishes a sell, reaches for the one
				control on screen that sells things, and is told to go and find a
				building. Every tide, after every sell, for the whole game.

				panels.Store is the SAME stock list the four counters open -- this
				adds no second way to buy anything, it just stops the rail lying
				about what it does. The counters are untouched.

				Titled from here because there is no prompt to read an ObjectText off,
				and the panel is authored "BEACH SHOP", which is wrong at three of the
				four counters and wrong on the rail as well.
			]]
			if e.name == "Upgrades" and panels.Store then
				-- setTitle, not a label: the header is two stacked labels and buildShop
				-- hands back PanelKit's setter for exactly that reason.
				if panels.Store.setTitle then
					panels.Store.setTitle("UPGRADES")
				end
				openPanel("Store")
				return
			end
			-- SHOP falls through to the generic path, because unlike UPGRADES it has
			-- a panel of its own with the same name (buildRobuxShop -> panels.Shop).
			openPanel(e.name)
		end)
	end
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------
local started = false
function MenuHud.start()
	if started then return end
	started = true

	gui = Instance.new("ScreenGui")
	gui.Name = "BeachMenuHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 12
	gui.Parent = player:WaitForChild("PlayerGui")

	-- See setScrim. ZIndex 0 because this gui runs ZIndexBehavior.Global, which
	-- puts this under every panel and under the rail in one number.
	--
	-- FOUR TIMES THE SCREEN, and that is not laziness. UiFit wraps everything
	-- here in a scaled FitRoot, so a full-size scrim would be scaled down with
	-- the rest and leave a bright border of un-dimmed beach around the edge on
	-- exactly the small screens that need the help most. Oversizing it costs
	-- nothing and survives any scale UiFit picks.
	scrim = Instance.new("Frame")
	scrim.Name = "Scrim"
	scrim.AnchorPoint = Vector2.new(0.5, 0.5)
	scrim.Position = UDim2.fromScale(0.5, 0.5)
	scrim.Size = UDim2.fromScale(4, 4)
	scrim.BackgroundColor3 = Color3.fromRGB(16, 24, 40)
	scrim.BackgroundTransparency = 1
	scrim.BorderSizePixel = 0
	scrim.ZIndex = 0
	scrim.Parent = gui

	buildRail()
	-- The rail is what OWNS the mark, so the first verdict has to be applied
	-- after it exists. ProgressionSync can land before this line -- the panels
	-- are built inside start() and the remote is connected at the bottom of it --
	-- and a sync that arrived first would have found no badge to switch and left
	-- an eligible player unmarked until the next one. Reading `snapshot` back out
	-- here costs one comparison and closes that window.
	refreshRebirthAlert()
	buildShop()
	buildRobuxShop()
	buildRebirth()
	buildRewards()
	buildIndex()
	-- Pets. The panel, its PetSync subscription and every button behind it live
	-- in PetsPanel; what it cannot make for itself is the ScreenGui, the panel
	-- registry and the card factory, so those are handed in.
	PetsPanel.build({
		gui = gui,
		panels = panels,
		makePanel = makePanel,
		PanelKit = PanelKit,
		Net = Net,
		PetConfig = PetConfig,
		-- Wrapped rather than passed directly: this table is built at boot and
		-- MenuHud.close is assigned further up the file, so handing over the
		-- function VALUE here would hand over whatever it was at that instant.
		-- The Pets panel's TRADE key needs this to put the menu away before the
		-- trade panel opens over the top of it -- otherwise the scrim stays lit
		-- behind a panel that is no longer MenuHud's.
		close = function()
			MenuHud.close()
		end,
	})
	--[[
		The rail's Shop button is directions to the counter, not a stock list --
		the stock list is what the counter prompt opens.

		IT IS NOT ONLY ON THE BEACH, AND THIS USED TO SAY IT WAS. WORLD_PROMPTS
		matches ShopPrompt ANYWHERE (see wireWorldPrompts), and four counters in
		the world carry that name: Beach.Store, Island2's Dune Outfitters,
		Island3's Kakigori Stand and Island4's Ashfall Outfitters. The same stock
		list opens at all four and retitles itself from the prompt's ObjectText.

		So "FIND US ON THE BEACH" was telling a player standing ten feet from the
		Ashfall Outfitters that they had to sail home to spend anything. They did
		not -- and this key is directions, so it has to be true.
	]]
	-- No signpost panel for Shop any more: the rail key opens panels.Store
	-- directly (see the note on the click handler in buildRail). The directions
	-- it used to give are still true and still worth having somewhere -- they are
	-- just not what a player wants from the button labelled SHOP.
	buildSettings()
	wireWorldPrompts()

	--[[
		WHY A PANEL USED TO FADE IN THE FIRST TIME IT WAS OPENED.

		Every panel above is BUILT AT BOOT and left hidden, which is what makes
		opening one instant -- there are no instances left to create. What that does
		not make instant is the ARTWORK. Roblox will not fetch an image that lives
		inside a hidden frame, so the first time a panel goes up every icon on it
		starts downloading at that moment and arrives over the next second or two.

		The shelf icons further up this file already worked this out and solved it
		for themselves -- see the PreloadAsync there and the long note beside it,
		which says exactly this. This does the same for everything else that got
		built, in one pass, so no future shelf has to remember to.

		MESHES TOO, not just images. The pet trays and the Index cards are
		ViewportFrames with real models in them, and a mesh in a hidden viewport is
		no more fetched than an image in a hidden frame -- deduped on MeshId,
		because a roster of sixty pets is nothing like sixty distinct meshes.

		SPAWNED, DELAYED AND CHUNKED, all three deliberately. PreloadAsync yields
		until each batch has landed, and handing it every asset in the menu at once
		competes with the world streaming in around a player who would rather see
		the beach than a shop they have not opened yet. Small batches with a breath
		between them reach the same place without spending the first seconds of the
		session on it.
	]]
	task.spawn(function()
		local ContentProvider = game:GetService("ContentProvider")

		-- A beat first: the map and the character win the opening seconds.
		task.wait(3)

		local seen, queue = {}, {}
		local function want(key: string, inst: Instance)
			if key ~= "" and not seen[key] then
				seen[key] = true
				queue[#queue + 1] = inst
			end
		end

		for _, d in gui:GetDescendants() do
			if d:IsA("ImageLabel") or d:IsA("ImageButton") then
				want(d.Image, d)
			elseif d:IsA("MeshPart") then
				want(d.MeshId, d)
			end
		end

		for i = 1, #queue, 8 do
			local batch = table.move(queue, i, math.min(i + 7, #queue), 1, {})
			-- pcall per batch: one deleted or moderated asset in the menu should
			-- cost that batch, not every asset queued behind it.
			pcall(function()
				ContentProvider:PreloadAsync(batch)
			end)
			task.wait(0.1)
		end
	end)

	Net.get("RewardsSync").OnClientEvent:Connect(function(snap)
		if type(snap) ~= "table" then return end
		rewardState = snap
		refreshRewardsAlert()
		local p = panels.Rewards
		if p and p.refresh and p.root.Visible then
			p.refresh()
		end
	end)

	--[[
		PANELS A COIN CHANGE HAS NO BUSINESS REPAINTING. Added 2026-09-09.

		`refresh` means "draw yourself again" and for most panels that is a handful
		of labels. For the Pets tab it is PetsPanel.rebuild, which DESTROYS AND
		RECREATES EVERY TILE -- measured at 250 pets that is 3,142 instances. The
		Index is the same shape.

		Neither of them draws a price, a cost or a balance, so a coin movement can
		never change what they look like. But the balance moves constantly, and on
		the AFK Long Shore it moves ONCE A SECOND: a player who left the Pets tab
		open while idling had the whole grid torn down and rebuilt every second,
		which flashes every tile back to a name placeholder and makes the list
		impossible to scroll. It also fires on every sale, every upgrade, every
		event payout and every egg.

		AN EXCLUSION, NOT AN INCLUSION, so a panel added later keeps repainting on
		coins by default -- which is the safe direction to be wrong in. A panel only
		goes on this list when its refresh is expensive AND its content is
		price-free. Everything a snapshot changes still repaints everything.
	]]
	local COIN_AGNOSTIC = { Pets = true, Index = true }

	local function refreshOpenPanels(fromCoins: boolean?)
		for name, p in panels do
			if p.refresh and p.root.Visible and not (fromCoins and COIN_AGNOSTIC[name]) then
				p.refresh()
			end
		end
	end

	--[[
		THE ONLY PLACE A QUICK UPGRADE DIALOG IS EVER OPENED.

		The row's Robux button does not open one -- it asks the server, which
		re-derives the level and every refusal, records WHICH rung was meant (a
		receipt cannot say) and fires this back only if the rung is genuinely for
		sale. So a refusal costs a toast instead of a dialog the player could not
		have got anything out of.

		The id comes from the server rather than from this file's own ProductConfig
		lookup, deliberately: the thing that recorded the intent and the thing that
		takes the Robux then cannot be about two different products. Checked for
		sanity anyway, because PromptProductPurchase on a nonsense id is a dialog
		that cannot complete.
	]]
	Net.get("QuickUpgradePrompt").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		local id = payload.productId
		if type(id) ~= "number" or id <= 0 then
			return
		end
		-- Client call, as it has to be: there is no server-side way to open a
		-- purchase dialog. ProductServer hears the outcome as a RECEIPT, which is
		-- the only thing in this exchange that proves anybody paid.
		MarketplaceService:PromptProductPurchase(player, id)
	end)

	Net.get("ProgressionSync").OnClientEvent:Connect(function(snap)
		if type(snap) ~= "table" then return end
		snapshot = snap
		refreshOpenPanels()
		-- Off the SYNC rather than off the coin counter beside it: `canRebirth` is
		-- the server's verdict and it only ever changes when the server says so.
		-- The balance moves every few frames and re-deciding the mark that often
		-- would be work for an answer that cannot have moved.
		refreshRebirthAlert()
	end)

	-- The balance moves far more often than the snapshot does, and it is the
	-- number the HUD's coin counter is already drawing. Following it directly is
	-- what keeps the two in step no matter WHICH bit of the game moved the money
	-- -- a sale, a bounty, a tide bonus, an ATV -- without every one of them
	-- having to remember to push a snapshot.
	-- Wrapped rather than connected directly: the signal hands its listener no
	-- arguments, and this one has to arrive knowing it came from the balance so
	-- COIN_AGNOSTIC can apply. See the note on refreshOpenPanels.
	player:GetAttributeChangedSignal("Coins"):Connect(function()
		refreshOpenPanels(true)
	end)

	--[[
		AND THE TUTORIAL'S OWN TWO FACTS, for the one-row shop above.

		A PURCHASE already repaints the list -- it moves a level, the server pushes
		a snapshot, and refreshOpenPanels runs -- so neither of these is what lifts
		the lock in the ordinary case. They are for the two moments nothing else
		reports: the done-stamp landing (a restored profile, or the last step
		completing) and the admin panel putting the tutorial BACK, which has to
		re-lock a shop that may be open at the time.
	]]
	player:GetAttributeChangedSignal(TutorialConfig.DoneAttribute):Connect(refreshOpenPanels)
	player:GetAttributeChangedSignal(Config.AttrPrefix .. TutorialConfig.FirstTrack)
		:Connect(refreshOpenPanels)

	--[[
		OUT OF COINS -> THE COIN SHELF.

		Every refusal that comes down to "you cannot afford this" carries a
		`needCoins` shortfall on its Notify payload, and this turns that into the
		shop, scrolled to the coin packs. The player still gets the toast --
		FeedbackClient is on the same remote and draws it; this is a second
		listener doing a different job with the same message.

		A STRUCTURED FIELD, NOT THE TEXT. The obvious cheap version is to look for
		"more coins" in the sentence, and it is wrong in both directions: it breaks
		the day somebody rewords a toast, and it fires on any message that happens
		to contain the phrase. A number that is only ever set by a genuine
		affordability check cannot do either.

		AND IT DOES NOT OPEN A SHOP WITH NOTHING IN IT. hasCoins is checked first,
		so until the coin products have real ids on the Dashboard this whole path
		is inert and the refusal is just the toast it always was.
	]]
	Net.get("Notify").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		local short = payload.needCoins
		if type(short) ~= "number" or short <= 0 then
			return
		end
		local shop = panels.Shop
		if not (shop and shop.hasCoins and shop.hasCoins()) then
			return
		end
		openPanel(shop.coinPanel and shop.coinPanel() or "Shop")
	end)
end

return MenuHud
