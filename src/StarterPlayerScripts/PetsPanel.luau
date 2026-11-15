--[[
	PetsPanel  --  StarterPlayerScripts.PetsPanel

	The Pets tab: the collection, the index, and every control that acts on
	them.

	WHY THIS IS NOT INSIDE MenuHud
	------------------------------
	MenuHud owns the rail, the panel registry and the house style, and it is
	ninety-five kilobytes of somebody else's careful work. A panel that lives
	inside it is a merge conflict waiting to happen every time either of us
	touches the file. So MenuHud keeps three lines -- a rail entry, a require,
	and one call -- and hands this module the four things it cannot make for
	itself: the ScreenGui, the panel registry, the card factory, and PanelKit.

	WHAT IT IS ALLOWED TO DECIDE: NOTHING
	-------------------------------------
	Every button sends an action and at most a pet id. The server owns which
	five are best, whether a slot is free, whether the bag is full, and what
	any of it is worth in luck. This draws the last snapshot it was sent.

	THE LAYOUT, AND WHY IT CHANGED
	------------------------------
	Re-cut to the reference shot: a big outlined title on the left with a rule
	running to a count on the right, a CREAM tray filling the panel, square
	pet tiles carrying their own badges with a value written underneath, and a
	toolbar along the bottom -- a red button on the left, icon buttons in the
	middle, a search field on the right.

	The five equipped SLOTS are gone as a separate row, and that is the whole
	reason there is room for the tray. Equipped is a state a tile is in, not a
	place a pet sits: the reference marks it with a green tick on the tile and
	so does this, equipped tiles sort first, and the header carries a
	"3 / 5 EQUIPPED" pill so the count is still a number you can read. Nothing
	was removed from what the panel can DO -- click a tile to equip or unequip
	exactly as before.

	NO GLYPH FONTS FOR THE BADGES
	-----------------------------
	The stars and the tick are BUILT OUT OF FRAMES, not typed. Roblox's text
	emoji coverage is not the system's and a character it cannot find comes
	back looking like a broken icon rather than like nothing -- the rebirth
	panel shipped a wave that rendered as a pale crescent for exactly that
	reason, and this file already had the clover taken out of it twice. A star
	made of two squares at 0 and 45 degrees renders on every device or the
	renderer is broken.

	THE CLOVER IS BACK, AS AN UPLOADED IMAGE, and that is not a reversal of
	the rule above -- it is the rule's other half. What failed twice was the
	CHARACTER: a font without it falls back to a broken box. An asset id has
	no fallback to fail to. It marks the luck line along the foot.

	VIEWPORTS ARE RECYCLED, NOT RATIONED
	------------------------------------
	A ViewportFrame renders its own little scene every frame, so the panel used
	to hand out the first thirty-six and let the rest of the grid fall back to a
	name on a tinted block. With MaxOwned at 250 that is most of a collection,
	and scrolling down into a wall of lettering is the bug this replaces.

	Now a small pool of viewports MOVES to whatever is on screen -- the rows in
	view plus one row of run-up either side, about thirty scenes -- so every
	tile carries its actual pet and a full collection costs LESS than the old
	half-empty one did. The models are prepared once per species into a cache,
	and the meshes behind them are fetched during the loading screen (see
	IntroClient's "Waking the pets"), so opening this panel does no work that
	could have been done earlier. The detail card keeps a viewport of its own,
	outside the pool.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- One frame, waited on precisely: restoreScroll has to let the layout recompute
-- AutomaticCanvasSize before it writes a position back. See its note.
local RunService = game:GetService("RunService")

-- Touch targets: see the module. Substituted for MouseButton1Click/Activated so
-- a tap in the margin around a control that renders under 44px on a phone still
-- reaches the same handler. No-ops on desktop and on controls already big enough.
local TouchFit = require(game:GetService("ReplicatedStorage"):WaitForChild("Modules"):WaitForChild("TouchFit"))

-- The wardrobe's catalogue. Required here rather than threaded through `ctx`
-- like PetConfig is, because ctx is MenuHud's contract with this file and
-- MenuHud has no reason to know skins exist -- the panel reads the palettes and
-- the two `Set`-style attributes (SkinChosen, SkinOwn_<key>) straight off the
-- player, exactly as SkinClient does to draw the tool.
local SkinConfig = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("SkinConfig"))

local PetsPanel = {}

--[[
	WIDER AND SHORTER THAN IT WAS.

	720x588 was sized around a 104-tall slot row, a 46-tall stat row and a
	36-tall chip row stacked above the grid -- 216 pixels of header before the
	first tile. The header is 96 now and the tray takes the rest, which is
	what makes six tiles across at a readable size possible at all.
]]
local W, H = 780, 620

-- The viewport pool: how many rows of run-up to keep live either side of the
-- visible band, and the ceiling on live scenes however large the panel gets.
local POOL_RUNUP = 1
local POOL_CAP = 64

--------------------------------------------------------------------------
-- ART
--------------------------------------------------------------------------
-- The same suffix rule PetServer, PetVisuals and EggClient all use, so a
-- hand-renamed model resolves everywhere or nowhere.
local function findArt(def)
	local root = ReplicatedStorage:FindFirstChild("Pets")
	local folder = root and root:FindFirstChild(def.Tier)
	if not folder then
		return nil
	end
	local exact = folder:FindFirstChild(def.ModelName) or folder:FindFirstChild(def.PetId)
	if exact then
		return exact
	end
	for _, child in folder:GetChildren() do
		if child.Name:sub(-#def.PetId) == def.PetId then
			return child
		end
	end
	return nil
end

--------------------------------------------------------------------------
-- THE ART CACHE
--------------------------------------------------------------------------
--[[
	EVERY PET, PREPARED ONCE.

	showPet used to do the whole job per tile: clone the art, walk the clone
	anchoring parts, measure a bounding box and solve a camera off it. That is
	tolerable thirty-six times when a panel opens and ruinous once the same work
	has to happen again for every row scrolled past.

	So it happens once per SPECIES, and what a tile gets is a clone of the
	finished thing plus the camera that was solved with it. All 61 prepare in
	about 3ms and a clone costs about 0.04ms, because a pet in this game is a
	single MeshPart with no descendants of its own.

	The templates are parented to NIL and held alive by this table alone.
	Model:GetBoundingBox() does not need a parent -- measured, not assumed --
	and an unparented template is in nobody's render path and turns up in
	nobody's GetDescendants.
]]
local prepped = {}   -- petId -> { model = Model, cam = CFrame }  |  false

local function prepare(PetConfig, petId: string)
	local hit = prepped[petId]
	if hit ~= nil then
		return hit or nil
	end

	local def = PetConfig.get(petId)
	local art = def and findArt(def)
	if not art then
		-- Cached as a MISS rather than left absent, or a pet with no art would
		-- re-walk its whole tier folder every time it scrolled past.
		prepped[petId] = false
		return nil
	end

	local model = art:Clone()
	if not model:IsA("Model") then
		local wrap = Instance.new("Model")
		model.Parent = wrap
		wrap.PrimaryPart = model:IsA("BasePart") and model or nil
		model = wrap
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
		end
	end

	local centre, size = model:GetBoundingBox()
	-- The pack faces -Z once the FBX axis conversion has run, so the camera
	-- sits on the -Z side or every card would be a portrait of a tail.
	--[[
		1.85 WAS FRAMED FOR A 96px SLOT, and the grid tile is bigger and the
		slot row is gone. At that distance a Kraken -- a tall thin silhouette
		whose bounding box is mostly empty air -- came out as a smudge in the
		middle of a large tile. Pulled in to 1.35, and the fit uses the two
		WIDEST axes rather than the largest, so a tall pet fills the frame
		instead of being scaled down by its own height.
	]]
	local axes = { size.X, size.Y, size.Z }
	table.sort(axes)
	local span = math.max((axes[2] + axes[3]) * 0.5, 0.1)
	local dir = Vector3.new(0.45, 0.34, -1).Unit

	local entry = {
		model = model,
		cam = CFrame.lookAt(centre.Position + dir * span * 1.35, centre.Position),
	}
	prepped[petId] = entry
	return entry
end

-- Every pet there is, whether or not this player owns one: the Index shows the
-- whole roster and the Collection draws up to 250 tiles out of it. The
-- expensive half -- fetching the meshes themselves -- is spent on the loading
-- screen instead. See IntroClient's "Waking the pets".
local function prepareAll(PetConfig)
	for _, petId in PetConfig.Order do
		prepare(PetConfig, petId)
	end
end

--[[
	THE CACHE IS SHARED, AND TradeClient IS THE SECOND CALLER.

	A require is cached per client, so a second panel asking for a pet's art
	gets THIS table and THIS `prepped` -- the templates the loading screen
	already paid for, not a second set solved again behind another screen. That
	is the whole reason this is exposed rather than copied: two prepare()s is
	two camera solves per species and two sets of models held alive for the
	life of the session, to draw the same 63 animals.

	Returns `{ model = Model, cam = CFrame }` or nil for a pet with no art.
	CLONE the model -- the entry is the template and handing it out directly
	would move the cache into whatever viewport asked last.
]]
function PetsPanel.art(PetConfig, petId: string)
	return prepare(PetConfig, petId)
end

--------------------------------------------------------------------------
-- BUILD
--------------------------------------------------------------------------
function PetsPanel.build(ctx)
	local gui = assert(ctx.gui, "[PetsPanel] needs the ScreenGui")
	local panels = assert(ctx.panels, "[PetsPanel] needs the panel registry")
	local makePanel = assert(ctx.makePanel, "[PetsPanel] needs makePanel")
	local PanelKit = assert(ctx.PanelKit, "[PetsPanel] needs PanelKit")
	local Net = assert(ctx.Net, "[PetsPanel] needs Net")
	local PetConfig = assert(ctx.PetConfig, "[PetsPanel] needs PetConfig")

	local C = PanelKit.C
	local darken, corner, outline = PanelKit.darken, PanelKit.corner, PanelKit.outline
	local chunky, text, punch = PanelKit.chunky, PanelKit.text, PanelKit.punch

	local TINT = C.grape:Lerp(C.coral, 0.35)

	-- The tray's own palette. CREAM is the sheet, RULE is the heavy border and
	-- the lettering's outline, and DOODLE is the faint pattern that shows
	-- through wherever there are no tiles.
	local CREAM = Color3.fromRGB(252, 246, 232)
	local RULE = Color3.fromRGB(74, 104, 140)
	local DOODLE = Color3.fromRGB(226, 218, 202)
	local INKED = Color3.fromRGB(38, 28, 22)

	-- THREE values, not four: makePanel wires the close X itself and returns
	-- (root, body, banner). Taking a closeFace out of it puts nil in `banner`,
	-- and a chunky() parented to nil builds silently and is never seen.
	local root, body, banner = makePanel("Pets", W, H, TINT)
	--[[
		THE BANNER SAYS WHAT THE RAIL KEY SAYS. makePanel takes one string and uses
		it as both the registry KEY and the headline, and the key has to stay "Pets"
		-- panels.Pets is what MenuHud's rail, its world prompts and this file's own
		return value are all keyed on. So the headline is retitled afterwards rather
		than renamed, the same split MenuHud's RAIL entry makes between `name` and
		`label`. Both labels: PanelKit draws a shadow copy behind the title.
	]]
	for _, n in ipairs({ "Title", "TitleShadow" }) do
		local lbl = banner and banner:FindFirstChild(n)
		if lbl and lbl:IsA("TextLabel") then
			lbl.Text = "PETS & SKINS"
		end
	end
	panels.Pets = { root = root, w = W, h = H }

	-- Last snapshot from the server. Everything drawn below is a view of this.
	local state = {
		owned = {}, equipped = {}, discovered = {}, locked = {},
		luck = 1, ownedCount = 0,
		maxEquipped = PetConfig.MaxEquipped, maxOwned = PetConfig.MaxOwned,
	}
	local view = "Collection"   -- or "Index"
	--[[
		TWO MODES, AND THEY ARE MUTUALLY EXCLUSIVE.

		A tile does one of three things when it is tapped -- equip, release, or
		lock -- and which one is decided here rather than by anything on the tile.
		Entering either mode leaves the other, because "delete" and "protect from
		deletion" being armed at the same time is exactly the ambiguity that makes
		a destructive tap a surprise.
	]]
	local releaseMode = false
	local lockMode = false
	-- Fusing spends five pets, so it is a destructive mode and it is arm-and-
	-- confirm like release rather than one tap. See the note over `armed`: that
	-- rule was written after a player lost a Mythic to a single tap, and "you
	-- get something better back" does not make five Legendaries cheap.
	local fuseMode = false
	local filter = ""
	--[[
		THE ONE TILE WHOSE NEXT TAP IS FINAL, AND ONLY THAT ONE.  2026-09-09

		Release mode being armed is not consent to destroy the pet under the
		finger. A tile has to be ASKED first and answer second, so this holds
		{ i, petId } for the tile that has been asked. The release is sent only
		when the second tap lands on that same index AND that same pet -- both,
		because the grid sorts by luck and a snapshot can re-sort it underneath
		an armed tile, after which index i is a different animal.

		rebuild() clears it, so a snapshot, a mode change, a search or an open
		all disarm. It fails closed: a lost arm costs one extra tap, and the tap
		it costs is the one that was going to be a surprise.
	]]
	local armed = nil

	local function send(payload)
		Net.get("PetEquip"):FireServer(payload)
	end

	------------------------------------------------------------------
	-- SMALL SHAPES, BUILT RATHER THAN TYPED
	------------------------------------------------------------------
	--[[
		A STAR IS TWO SQUARES. One at 0 degrees, one at 45, same centre: eight
		points, chunky, and impossible for a font to fail to render. See the
		note in the header about why nothing here is a text glyph.
	]]
	local function star(parent, size, colour, z)
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.Size = UDim2.fromOffset(size, size)
		holder.ZIndex = z or 6
		holder.Parent = parent
		for i, rot in ipairs({ 0, 45 }) do
			local blade = Instance.new("Frame")
			blade.AnchorPoint = Vector2.new(0.5, 0.5)
			blade.Position = UDim2.fromScale(0.5, 0.5)
			blade.Size = UDim2.fromOffset(size * 0.78, size * 0.78)
			blade.Rotation = rot
			blade.BackgroundColor3 = colour
			blade.BorderSizePixel = 0
			blade.ZIndex = (z or 6) + i
			blade.Parent = holder
			corner(blade, math.max(2, math.floor(size * 0.16)))
		end
		return holder
	end

	-- A tick is two bars. Short one down-right, long one up-right, meeting at
	-- the elbow -- again so no font has to have the character.
	local function tick(parent, size, colour, z)
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.Size = UDim2.fromOffset(size, size)
		holder.ZIndex = z or 6
		holder.Parent = parent
		local short = Instance.new("Frame")
		short.AnchorPoint = Vector2.new(0.5, 0.5)
		short.Position = UDim2.fromScale(0.34, 0.62)
		short.Size = UDim2.fromOffset(size * 0.20, size * 0.42)
		short.Rotation = -45
		short.BackgroundColor3 = colour
		short.BorderSizePixel = 0
		short.ZIndex = (z or 6) + 1
		short.Parent = holder
		corner(short, 2)
		local long = Instance.new("Frame")
		long.AnchorPoint = Vector2.new(0.5, 0.5)
		long.Position = UDim2.fromScale(0.60, 0.46)
		long.Size = UDim2.fromOffset(size * 0.20, size * 0.74)
		long.Rotation = 38
		long.BackgroundColor3 = colour
		long.BorderSizePixel = 0
		long.ZIndex = (z or 6) + 1
		long.Parent = holder
		corner(long, 2)
		return holder
	end

	--[[
		A PADLOCK IS A BODY AND A SHACKLE: a rounded block with a ring standing
		behind its top edge, the body drawn OVER the ring so only the arch of it
		shows. Built rather than typed for the same reason star() and tick() above
		are -- see the note at the top of the file about glyphs that did not
		render.
	]]
	local function padlock(parent, size, colour, z)
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.Size = UDim2.fromOffset(size, size)
		holder.ZIndex = z or 6
		holder.Parent = parent

		local shackle = Instance.new("Frame")
		shackle.AnchorPoint = Vector2.new(0.5, 0)
		shackle.Position = UDim2.fromScale(0.5, 0.04)
		shackle.Size = UDim2.fromOffset(size * 0.48, size * 0.48)
		shackle.BackgroundTransparency = 1
		shackle.ZIndex = (z or 6) + 1
		shackle.Parent = holder
		corner(shackle, math.max(2, math.floor(size * 0.24)))
		local ring = Instance.new("UIStroke")
		ring.Thickness = math.max(2, size * 0.12)
		ring.Color = colour
		ring.Parent = shackle

		local body = Instance.new("Frame")
		body.AnchorPoint = Vector2.new(0.5, 1)
		body.Position = UDim2.fromScale(0.5, 0.98)
		body.Size = UDim2.fromOffset(size * 0.80, size * 0.56)
		body.BackgroundColor3 = colour
		body.BorderSizePixel = 0
		body.ZIndex = (z or 6) + 2
		body.Parent = holder
		corner(body, math.max(2, math.floor(size * 0.14)))
		return holder
	end

	-- One toolbar button: a square face with a drawn icon on it.
	local function toolButton(parent, order, tipText, draw)
		local b = Instance.new("TextButton")
		b.LayoutOrder = order
		b.Size = UDim2.fromOffset(62, 46)
		b.BackgroundColor3 = CREAM
		b.BorderSizePixel = 0
		b.AutoButtonColor = false
		b.Text = ""
		b.Parent = parent
		corner(b, 12)
		local st = outline(b, 3)
		if st and st:IsA("UIStroke") then
			st.Color = RULE
		end
		draw(b)
		-- The label under it, because a drawn icon is a guess until it is named.
		-- 11pt in a 62-wide key rather than 9pt in a 44-wide one: at the old
		-- size the three captions were a grey smudge under three grey smudges.
		local cap = text(b, tipText, 11, Enum.Font.GothamBold, RULE)
		cap.Size = UDim2.new(1, 0, 0, 12)
		cap.Position = UDim2.new(0, 0, 1, -13)
		cap.ZIndex = 8
		return b
	end

	--[[
		THE ART FOR ONE OF THE THREE TOOL KEYS.

		EACH IS SIZED TO ITS OWN CANVAS, and that is not one number three times.
		ScaleType.Fit maps the WHOLE image including its transparent margin, so how
		big the box must be depends on how much of the file is actually the icon.
		Measured, per asset:

		  index    730x686, art fills it     -> a 26 box draws 26.0 x 24.4
		  release  1023x673, art 50% x 87%   -> a 26 box draws 13 x 15, so 40
		  locked   512x512,  art 71% x 100%  -> a 26 box draws 18.5 x 26

		The release art is half margin, which is why its box is oversized by so
		much; the letterboxed remainder is transparent and the button does not clip,
		so nothing of the overhang is ever seen.

		CENTRED ON THE GLYPH BAND, NOT THE BUTTON. The caption owns the bottom 12px
		of a 46-tall key, so the art belongs in the 28 above it -- centring on the
		button would sit every icon low and crowd the word under it.
	]]
	local function toolArt(b: GuiObject, asset: string, box: number)
		local im = Instance.new("ImageLabel")
		im.Name = "Icon"
		im.AnchorPoint = Vector2.new(0.5, 0.5)
		im.Position = UDim2.new(0.5, 0, 0, 16)
		im.Size = UDim2.fromOffset(box, box)
		im.BackgroundTransparency = 1
		im.Image = asset
		im.ScaleType = Enum.ScaleType.Fit
		im.ZIndex = 7
		im.Parent = b
		return im
	end

	------------------------------------------------------------------
	-- A PET IN A BOX
	------------------------------------------------------------------
	local function petViewport(parent)
		local vp = Instance.new("ViewportFrame")
		vp.BackgroundTransparency = 1
		vp.Size = UDim2.fromScale(1, 1)
		vp.Ambient = Color3.fromRGB(190, 190, 200)
		vp.LightColor = Color3.fromRGB(255, 250, 240)
		vp.LightDirection = Vector3.new(-0.4, -1, -0.6)
		vp.Parent = parent

		local cam = Instance.new("Camera")
		cam.Parent = vp
		vp.CurrentCamera = cam
		return vp
	end

	local function showPet(vp: ViewportFrame, petId: string?)
		for _, c in vp:GetChildren() do
			if not c:IsA("Camera") then
				c:Destroy()
			end
		end
		if not petId then
			return
		end
		-- Both halves come out of the cache: the model is a clone of a template
		-- that was already flattened and anchored, and the camera was solved
		-- against that same template, so nothing is measured here.
		local entry = prepare(PetConfig, petId)
		if not entry then
			return
		end
		entry.model:Clone().Parent = vp
		vp.CurrentCamera.CFrame = entry.cam
	end

	------------------------------------------------------------------
	-- HEADER: the title, the rule, and the count
	------------------------------------------------------------------
	--[[
		The reference's masthead: name on the left, count on the right, and a
		rule joining them so the two read as one line rather than as two labels
		that happen to share a y. The rule is drawn BETWEEN them at runtime --
		it is anchored to the title's measured width, because "Your Pets!" and
		a translated string are not the same number of pixels.
	]]
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 44)
	header.BackgroundTransparency = 1
	header.Parent = body

	local title = text(header, "Your Pets!", 34, Enum.Font.LuckiestGuy, C.white)
	title.AnchorPoint = Vector2.new(0, 0.5)
	title.Position = UDim2.new(0, 2, 0.5, 0)
	title.Size = UDim2.fromOffset(230, 44)
	title.TextXAlignment = Enum.TextXAlignment.Left
	punch(title, 4)

	local countLbl = text(header, "0 Pets", 24, Enum.Font.LuckiestGuy, C.white)
	countLbl.AnchorPoint = Vector2.new(1, 0.5)
	countLbl.Position = UDim2.new(1, -2, 0.5, 0)
	countLbl.Size = UDim2.fromOffset(200, 40)
	countLbl.TextXAlignment = Enum.TextXAlignment.Right
	punch(countLbl, 3)

	--[[
		THE FILTER SAYS SO WHERE THE PETS ARE, not only where it was set.

		Auto-release is a Settings row -- that is where every persisted preference
		in this game lives and it rides SettingsServer's whitelist for free. The
		cost of putting it there is that the player who WANTS it is standing in this
		panel, or at an egg station, and would never think to look under a spanner
		icon. This line is what pays that back: it is the only place the setting is
		visible from the pet context, and it is deliberately phrased as a statement
		of what is happening rather than as a control, because it is not one.

		HIDDEN WHEN OFF, which is the common case and the default. A row of
		permanent chrome saying a feature is doing nothing is worse than no row.
	]]
	local filterNote = text(header, "", 12, Enum.Font.GothamBold, C.white)
	filterNote.AnchorPoint = Vector2.new(1, 0.5)
	filterNote.Position = UDim2.new(1, -2, 0.5, 20)
	filterNote.Size = UDim2.fromOffset(240, 16)
	filterNote.TextXAlignment = Enum.TextXAlignment.Right
	filterNote.TextTransparency = 0.25
	filterNote.Visible = false
	punch(filterNote, 2)

	--[[
		CALLED FROM BOTH rebuild() AND apply(), and it has to be.

		It lived in apply() alone at first, which paints whatever the last SNAPSHOT
		said -- and the thing it is reporting is not in the snapshot. It is an
		attribute written by a row in the Settings panel, so the ordinary way a
		player meets this is: change the setting, close Settings, open Pets. No pet
		data moved, no snapshot arrived, and the line still claimed whatever it said
		last time. MEASURED: switched the filter to OFF and the panel went on
		advertising "AUTO-RELEASING BELOW LEGENDARY".

		rebuild() is what runs on open (panels.Pets.refresh), so that is the call
		that fixes it; apply() keeps its call so the line is also right the instant a
		snapshot lands while the panel is already up.
	]]
	local function paintFilterNote()
		-- Players.LocalPlayer, not a `player` upvalue: this file has never had one.
		local floor = PetConfig.autoReleaseFloor(Players.LocalPlayer)
		filterNote.Visible = floor > 0
		if floor > 0 then
			filterNote.Text = "AUTO-RELEASING BELOW " .. PetConfig.autoReleaseLabel(floor)
		end
	end

	local rule = Instance.new("Frame")
	rule.AnchorPoint = Vector2.new(0, 0.5)
	rule.Position = UDim2.new(0, 236, 0.5, 4)
	rule.Size = UDim2.new(1, -450, 0, 3)
	rule.BackgroundColor3 = C.white
	rule.BackgroundTransparency = 0.35
	rule.BorderSizePixel = 0
	rule.Parent = header
	corner(rule, 2)

	------------------------------------------------------------------
	-- HEADER: the stat pills and the two global actions
	------------------------------------------------------------------
	local statRow = Instance.new("Frame")
	statRow.Position = UDim2.fromOffset(0, 48)
	statRow.Size = UDim2.new(1, 0, 0, 42)
	statRow.BackgroundTransparency = 1
	statRow.Parent = body

	--[[
		THESE FOUR WIDTHS ADD UP AND HAVE TO. The body is 744 wide and a
		horizontal UIListLayout does not wrap -- it runs the last control off
		the end and no error is raised. 126+98+142+106 is 472, plus three 8px
		gaps is 496, centred.

		THE LUCK PILL USED TO LEAD THIS ROW at 198 wide. It is not a pill any
		more and it is not up here -- see LUCK, further down.
	]]
	local statLay = Instance.new("UIListLayout")
	statLay.FillDirection = Enum.FillDirection.Horizontal
	statLay.HorizontalAlignment = Enum.HorizontalAlignment.Center
	statLay.VerticalAlignment = Enum.VerticalAlignment.Center
	statLay.Padding = UDim.new(0, 8)
	statLay.SortOrder = Enum.SortOrder.LayoutOrder
	statLay.Parent = statRow

	local eqPill = Instance.new("Frame")
	eqPill.LayoutOrder = 1
	eqPill.Size = UDim2.fromOffset(126, 38)
	eqPill.BackgroundColor3 = darken(C.foamDark, 0.05)
	eqPill.BorderSizePixel = 0
	eqPill.Parent = statRow
	corner(eqPill, 12)
	outline(eqPill, 3)
	local eqText = text(eqPill, "0 / 5 EQUIPPED", 15, Enum.Font.LuckiestGuy, C.white)
	eqText.Size = UDim2.fromScale(1, 1)
	punch(eqText, 2)

	local capPill = Instance.new("Frame")
	capPill.LayoutOrder = 2
	capPill.Size = UDim2.fromOffset(98, 38)
	capPill.BackgroundColor3 = C.sandDeep
	capPill.BorderSizePixel = 0
	capPill.Parent = statRow
	corner(capPill, 12)
	outline(capPill, 3)
	-- INK, not white: this pill is the one light slab in the row.
	local capText = text(capPill, "0 / 100", 17, Enum.Font.LuckiestGuy, C.ink)
	capText.Size = UDim2.fromScale(1, 1)

	local bestHolder, bestFace = chunky(statRow, 142, 38, C.sun, 12)
	bestHolder.LayoutOrder = 3
	local bestLbl = text(bestFace, "EQUIP BEST", 17, Enum.Font.LuckiestGuy, C.white)
	bestLbl.Size = UDim2.fromScale(1, 1)
	punch(bestLbl, 2)
	TouchFit.press(bestFace, function()
		send({ action = "best" })
	end)

	--[[
		THE TRADE KEY.

		Trading belongs to the whole collection rather than to any row, and it
		talks to TradeClient through the BindableEvent that script puts in its
		own ScreenGui -- the same seam BeachMenuHud's DevDiscover uses. Found
		lazily rather than at build time because the two scripts start in
		whatever order StarterPlayerScripts feels like.
	]]
	local tradeHolder, tradeFace = chunky(statRow, 106, 38, C.foam, 12)
	tradeHolder.LayoutOrder = 4
	local tradeLbl = text(tradeFace, "TRADE", 17, Enum.Font.LuckiestGuy, C.white)
	tradeLbl.Size = UDim2.fromScale(1, 1)
	punch(tradeLbl, 2)
	TouchFit.press(tradeFace, function()
		local hud = Players.LocalPlayer:FindFirstChild("PlayerGui")
		local tradeGui = hud and hud:FindFirstChild("TradeHud")
		local opener = tradeGui and tradeGui:FindFirstChild("OpenTrade")
		if not opener then
			return
		end
		if ctx.close then
			ctx.close()
		end
		opener:Fire()
	end)

	------------------------------------------------------------------
	-- THE TRAY
	------------------------------------------------------------------
	--[[
		The cream sheet the whole reference is built around. PanelKit's body is
		a DARK recessed well -- everything drawn straight onto it has to be a
		light value or it disappears, which is what happened to the egg buy
		menu -- so the tray is a sheet laid ON the well, and inside the tray the
		rule reverses: dark lettering on cream.
	]]
	local TRAY_TOP = 96
	-- 98 RATHER THAN 62: the luck line lives in the extra 36. It costs the
	-- grid no rows -- two rows of 140 plus padding is 302 and the tray still
	-- measures 352 inside -- so what it spent was scroll, not tiles.
	local TRAY_BOTTOM = 98

	local tray = Instance.new("Frame")
	tray.Name = "Tray"
	tray.Position = UDim2.fromOffset(0, TRAY_TOP)
	tray.Size = UDim2.new(1, 0, 1, -(TRAY_TOP + TRAY_BOTTOM))
	tray.BackgroundColor3 = CREAM
	tray.BorderSizePixel = 0
	tray.ClipsDescendants = true
	tray.Parent = body
	corner(tray, 18)
	do
		local st = outline(tray, 4)
		if st and st:IsA("UIStroke") then
			st.Color = RULE
		end
	end

	--[[
		NO DOODLE FIELD. There was one -- fifty-odd faint dashes scattered over
		the sheet so an empty tray read as paper rather than as a blank
		rectangle. On screen it read as scratches and dirt, which is worse than
		blank. A clean sheet with tiles on it is what the reference actually is.
	]]
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Grid"
	scroll.Position = UDim2.fromOffset(12, 12)
	scroll.Size = UDim2.new(1, -24, 1, -24)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 8
	scroll.ScrollBarImageColor3 = RULE
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ZIndex = 2
	scroll.Parent = tray

	--[[
		ROOM FOR THE RING, or the outside tiles lose it.

		A ScrollingFrame clips, a UIGridLayout puts its first cell flush against
		that clip on both axes, and a UIStroke in Border mode draws OUTWARD from
		the frame it is on -- so the tile ring had nowhere to go. Measured on the
		live panel: an equipped tile drew from y 167 and x 292 while the clip box
		starts at 171 and 296, so THE WHOLE TOP ROW AND THE WHOLE LEFT COLUMN
		were missing 4px of border while every interior tile looked fine.

		SIZED OFF THE THICKEST RING, not guessed: `outline(card, equipped and 4
		or 3)` below, so 4 is the worst case, and 6 leaves it two pixels of air
		rather than having it kiss the edge it was being cut by.

		It costs nothing in columns. Six cells need 6*104 + 5*10 = 674 and the
		grid measures 720 wide, so the 12 this takes horizontally still leaves
		room for the same six across. AutomaticCanvasSize counts padding, so the
		last row still scrolls fully into view.
	]]
	local RING_MAX = 4
	local gridPad = Instance.new("UIPadding")
	gridPad.PaddingTop = UDim.new(0, RING_MAX + 2)
	gridPad.PaddingBottom = UDim.new(0, RING_MAX + 2)
	gridPad.PaddingLeft = UDim.new(0, RING_MAX + 2)
	gridPad.PaddingRight = UDim.new(0, RING_MAX + 2)
	gridPad.Parent = scroll

	local gridLay = Instance.new("UIGridLayout")
	gridLay.CellSize = UDim2.fromOffset(104, 140)
	gridLay.CellPadding = UDim2.fromOffset(10, 10)
	gridLay.SortOrder = Enum.SortOrder.LayoutOrder
	gridLay.Parent = scroll

	------------------------------------------------------------------
	-- THE WARDROBE
	------------------------------------------------------------------
	--[[
		A THIRD VIEW IN THIS TRAY, AND ITS OWN SHEET RATHER THAN THE PET GRID.
		(2026-09-11.)

		The grid above is built for two hundred and fifty cells: a viewport pool
		that follows the scroll, a per-tile diff that turns a 250-cell redraw into
		a handful, and a window solved by arithmetic off the layout. Every one of
		those exists because of scale, and NONE of it is wanted here -- there are
		nine skins and there will never be many. Threading skins through dressCell
		would have put a second meaning on `petId`, `known`, `equipped` and
		`locked` in the hottest code in this file, to save building a sheet that
		is forty lines.

		So: a second ScrollingFrame in the same tray, hidden unless the view asks
		for it. It inherits the tray's paper, outline and clipping for free, and
		the pet grid does not learn that skins exist.

		NO VIEWPORTS. A skin IS a palette -- SkinConfig's header opens with it --
		so the honest thumbnail is the palette, not a render of a rake. Four bands
		of the actual `pieces` colours read at tile size, cost nothing, and cannot
		disagree with the tool the way a posed model eventually would.
	]]
	local skinSheet = Instance.new("ScrollingFrame")
	skinSheet.Name = "Skins"
	skinSheet.Position = UDim2.fromOffset(12, 12)
	skinSheet.Size = UDim2.new(1, -24, 1, -24)
	skinSheet.BackgroundTransparency = 1
	skinSheet.BorderSizePixel = 0
	skinSheet.ScrollBarThickness = 8
	skinSheet.ScrollBarImageColor3 = RULE
	skinSheet.CanvasSize = UDim2.new()
	skinSheet.AutomaticCanvasSize = Enum.AutomaticSize.Y
	skinSheet.ScrollingDirection = Enum.ScrollingDirection.Y
	skinSheet.ZIndex = 2
	skinSheet.Visible = false
	skinSheet.Parent = tray

	local skinPad = Instance.new("UIPadding")
	skinPad.PaddingTop = UDim.new(0, 6)
	skinPad.PaddingBottom = UDim.new(0, 6)
	skinPad.PaddingLeft = UDim.new(0, 6)
	skinPad.PaddingRight = UDim.new(0, 6)
	skinPad.Parent = skinSheet

	local skinLay = Instance.new("UIGridLayout")
	-- 228: the widest cell that still gives THREE columns. The sheet measures
	-- 720 against a 780 panel and its padding takes 12, so 3 x 228 + 2 x 10 = 704
	-- of 708. See the note on ICON for why the icon is sized off what is left
	-- rather than the other way round.
	skinLay.CellSize = UDim2.fromOffset(228, 118)
	skinLay.CellPadding = UDim2.fromOffset(10, 10)
	skinLay.SortOrder = Enum.SortOrder.LayoutOrder
	skinLay.Parent = skinSheet

	-- Built once, on the first look at the wardrobe, and repainted after that.
	-- Nine tiles is not worth a pool, but it is worth not rebuilding the sheet
	-- on every attribute change -- and an attribute changes on every claim.
	local skinTiles = {}

	--[[
		THE TOOL ITSELF, DRAWN AT 64 SQUARE, IN THE SKIN'S OWN COLOURS.

		This was four colour bands first, and bands were the wrong answer: they
		told a player which hues a skin uses and nothing about what they would be
		holding. Every one of the nine pieces below is the piece it is named after
		on the real sifter -- the mesh floor, the rim around it, the cutting lip,
		the comb of tines, the barrow wheel with its spokes and hub, the handle
		rail and the grip -- so the icon cannot drift from the tool without
		somebody changing the palette that drives both.

		A SIDE ELEVATION, because the sifter is a long low object and any
		three-quarter view of one at 64px is a smudge. Left to right it reads
		wheel, tray, tines, handle, which is the silhouette a player has been
		pushing around the beach all session.

		THE WHEEL SITS ON TOP of the tines, ZIndex 9 against 8, because on the
		real tool it is nearer the camera than the comb behind it. Drawn under
		them it reads as a wheel embedded in the rake.

		EVERY NUMBER BELOW IS IN A 64 BOX, and `part` scales them to whatever ICON
		actually is. Authoring in a fixed space and scaling on the way out is what
		lets the box be retuned -- it went 64 -> 60 the first time the sheet was
		measured against a real panel -- without re-deriving twenty numbers by hand.

		Drawn rather than an uploaded sprite for the reason at the top of this
		file -- and for one more: nine skins would be nine assets that have to be
		re-exported every time a palette is retuned.
	]]
	-- SIXTY, and it is the text column that decides it rather than the drawing.
	-- The sheet measures 720 inside a 780 panel, so a three-column grid caps the
	-- cell at 229 (3 x 229 + 2 x 10 = 707 of 708 usable). Against a 228 cell the
	-- name needs 136 at 13px for "Beachcomber's Rake", which leaves the icon 60.
	-- A 240 cell drew a bigger sifter and then only fitted TWO per row, which is
	-- a worse sheet -- measured in Play, not guessed.
	local ICON = 60

	local function swatch(parent, skin)
		local pieces = skin.pieces or {}
		local function col(key)
			local p = pieces[key]
			return (p and p.c) or skin.tint or CREAM
		end

		local plate = Instance.new("Frame")
		plate.Name = "Sifter"
		plate.Position = UDim2.fromOffset(12, 16)
		plate.Size = UDim2.fromOffset(ICON, ICON)
		plate.BackgroundColor3 = CREAM
		plate.BorderSizePixel = 0
		plate.ClipsDescendants = true
		plate.ZIndex = 6
		plate.Parent = parent
		corner(plate, 12)
		local st = outline(plate, 3)
		if st and st:IsA("UIStroke") then
			st.Color = RULE
		end

		-- Authored in a 64 box (see the note above) and scaled to ICON here, so
		-- every coordinate below stays the number it was drawn as.
		local k = ICON / 64
		local function part(x, y, w, h, colour, radius, z, rot)
			local f = Instance.new("Frame")
			f.AnchorPoint = Vector2.new(0.5, 0.5)
			f.Position = UDim2.fromOffset(x * k, y * k)
			f.Size = UDim2.fromOffset(math.max(1, w * k), math.max(1, h * k))
			f.BackgroundColor3 = colour
			f.BorderSizePixel = 0
			f.Rotation = rot or 0
			f.ZIndex = z
			f.Parent = plate
			if radius and radius > 0 then
				corner(f, radius * k)
			end
			return f
		end

		-- The handle goes on FIRST and sits behind the tray, so the joint between
		-- the two is hidden by the rim rather than drawn as a butt seam.
		part(45, 17, 30, 4, col("steel"), 2, 7, -32)
		part(57, 10, 11, 6, col("grip"), 3, 8, -32)

		-- The tray: rim, then the wire floor inset into it, then the wires.
		part(31, 34, 50, 16, col("frame"), 3, 7)
		part(31, 34, 44, 10, col("mesh"), 2, 8)
		for i = 0, 3 do
			part(16 + i * 9, 34, 2, 10, col("frame"), 0, 9)
		end

		-- The cutting lip, and the comb that runs ahead of it.
		part(31, 43, 46, 3, col("blade"), 1, 8)
		for i = 0, 6 do
			part(11 + i * 7, 48, 3, 7, col("tine"), 1, 8)
		end

		-- The barrow wheel, three rings deep so the spoke colour has somewhere to
		-- be. Nested rather than drawn as spokes: two 2px bars at this size read
		-- as dirt on the tyre.
		part(13, 46, 20, 20, col("tyre"), 10, 9)
		part(13, 46, 12, 12, col("spoke"), 6, 10)
		part(13, 46, 6, 6, col("hub"), 3, 11)

		--[[
			THE LOCKED VEIL, built here and switched by paintSkins.

			The palette stays VISIBLE underneath it on purpose -- a locked tile is
			an advertisement, and greying the sifter out would hide the one thing
			that makes somebody want it. So the tool is washed toward the paper
			rather than desaturated, and a padlock sits on top to say why.

			padlock() is the shape the pet tiles already use for a locked pet. Same
			meaning, same drawing -- a second padlock drawn slightly differently is
			how two parts of one panel start looking like two panels.
		]]
		local veil = Instance.new("Frame")
		veil.Name = "Veil"
		veil.Size = UDim2.fromScale(1, 1)
		veil.BackgroundColor3 = CREAM
		veil.BackgroundTransparency = 0.38
		veil.BorderSizePixel = 0
		veil.Visible = false
		veil.ZIndex = 12
		veil.Parent = plate
		corner(veil, 12)

		local lock = padlock(plate, 26, Color3.fromRGB(128, 118, 104), 13)
		lock.Name = "Lock"
		lock.AnchorPoint = Vector2.new(0.5, 0.5)
		lock.Position = UDim2.fromScale(0.5, 0.5)
		lock.Visible = false

		return plate, veil, lock
	end

	local function buildSkinTile(skin, order: number)
		local tile = Instance.new("Frame")
		tile.Name = skin.key
		tile.LayoutOrder = order
		tile.BackgroundColor3 = C.white
		tile.BorderSizePixel = 0
		tile.ZIndex = 4
		tile.Parent = skinSheet
		corner(tile, 14)
		local st = outline(tile, 3)
		if st and st:IsA("UIStroke") then
			st.Color = RULE
		end

		local _plate, veil, lock = swatch(tile, skin)

		-- THIRTEEN, MEASURED. "Beachcomber's Rake" is the longest name in the
		-- catalogue and at 15px it is 159px against a box of 136 -- it came out as
		-- "BEACHCOMBER'S...", which is the one word on the tile that has to survive.
		-- 13px puts it at 136 exactly, so the box takes the last 4px of the tile's
		-- right margin as well. Re-measure if a longer name is ever added.
		local name = text(tile, skin.short or skin.name, 13, Enum.Font.LuckiestGuy, INKED)
		name.Position = UDim2.fromOffset(80, 14)
		name.Size = UDim2.fromOffset(140, 18)
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.ZIndex = 6

		-- The blurb once it is yours, the way to get it while it is not. Two lines
		-- of 11px in 34px, wrapped rather than truncated: "Rewards -> Quests: come
		-- back on 7 days" is an instruction and half of one is useless.
		local sub = text(tile, "", 11, Enum.Font.GothamMedium, RULE)
		sub.Position = UDim2.fromOffset(80, 34)
		sub.Size = UDim2.fromOffset(140, 34)
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.TextYAlignment = Enum.TextYAlignment.Top
		sub.TextWrapped = true
		sub.TextTruncate = Enum.TextTruncate.None
		sub.ZIndex = 6

		local holder, face = chunky(tile, 140, 34, C.lime, 11)
		holder.Position = UDim2.fromOffset(80, 72)
		holder.ZIndex = 6
		local lbl = text(face, "", 14, Enum.Font.LuckiestGuy, C.white)
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.ZIndex = 8
		punch(lbl, 2)

		--[[
			THE TAP IS ALWAYS WIRED, and the server is what refuses.

			The alternative -- unbinding the press on a locked tile -- puts the
			ownership rule in two places that have to agree, and the one on this
			side is reading a replicated attribute that can be a frame stale.
			SkinService.choose already refuses a skin the player does not own (it is
			the same function the plinths call), so the tile stays a button and the
			answer stays in one place.
		]]
		TouchFit.press(face, function()
			Net.get("SkinChoose"):FireServer(skin.key)
		end)

		local e = { tile = tile, sub = sub, holder = holder, face = face,
			lbl = lbl, slab = holder:FindFirstChild("Slab"), stroke = st,
			veil = veil, lock = lock, name = name }
		skinTiles[skin.key] = e
		return e
	end

	--[[
		CHOSEN IS NOT ALWAYS WHAT IS IN YOUR HANDS, AND THIS SHEET USED TO SAY IT
		WAS.

		SkinService keeps two answers (see SkinConfig's header): `SkinChosen` is
		your pick and `SkinActive` is what you are holding right now. Standing in
		a room whose skin you own, its step() forces active to the ROOM's skin --
		`local want = (skin and s.owned[skin.key]) and skin.key or s.chosen`.

		This panel read `chosen` alone. So a player who opened the wardrobe inside
		the Shrine and tapped Pharaoh's Sieve got the tick moving onto Pharaoh's
		Sieve and a tool in their hands that did not change -- the sheet claiming
		one thing and their own screen showing another, with nothing anywhere
		saying why. Reported as "Unable to change sifter skin to the pharaoh skin
		for some reason", and the reason was a room three metres away.

		The override itself is right and stays: walking into the tomb is supposed
		to put the tomb's sifter in your hands. What was missing is that it says
		so. `active` now drives the WORN rim -- because that IS the tool -- and
		the pick keeps a state of its own so the choice still reads as taken.
	]]
	local function paintSkins()
		local me = Players.LocalPlayer
		local chosen = me:GetAttribute(SkinConfig.ChosenAttribute)
		local active = me:GetAttribute(SkinConfig.ActiveAttribute) or chosen
		-- A room is lending this player its own sifter over the top of their pick.
		local lent = active ~= chosen
		for i, skin in ipairs(SkinConfig.Skins) do
			local e = skinTiles[skin.key] or buildSkinTile(skin, i)
			local owned = me:GetAttribute(SkinConfig.OwnPrefix .. skin.key) == true
				or skin.key == SkinConfig.DefaultKey
			-- WORN follows the tool, not the preference.
			local worn = owned and active == skin.key
			-- Picked, and waiting for the door. Only ever true while `lent` is.
			local pending = owned and lent and chosen == skin.key

			e.sub.Text = owned and (skin.blurb or "") or SkinConfig.howToGet(skin)
			e.sub.TextColor3 = owned and RULE or Color3.fromRGB(150, 140, 126)

			-- The one line that answers the question the tick raised. It replaces
			-- the blurb rather than joining it: two sentences in a 2-line sub-label
			-- truncates, and this one is the one being asked about.
			if pending then
				e.sub.Text = "Yours again at the door -- this room lends its own."
				e.sub.TextColor3 = INKED
			elseif worn and lent then
				e.sub.Text = "Lent by this room while you are inside it."
				e.sub.TextColor3 = INKED
			end

			-- The veil and the padlock ride on OWNED, not on worn: there are three
			-- button states but only two tiles -- one you have and one you do not.
			e.veil.Visible = not owned
			e.lock.Visible = not owned

			if worn then
				--[[
					THE ONE TILE THAT SHOULD BE FINDABLE WITHOUT READING ANY OF THEM.

					Nine tiles of near-identical furniture and exactly one answers
					"what am I holding right now", which is the question somebody
					opens this sheet asking. A 4px sun-coloured rim and a warm paper
					are two signals rather than one, because the rim alone is the
					same weight as every other tile's outline at a glance.
				]]
				e.lbl.Text = "WORN"
				e.face.BackgroundColor3 = C.sun
				if e.slab then e.slab.BackgroundColor3 = darken(C.sun, 0.45) end
				if e.stroke then
					e.stroke.Color = C.sun
					e.stroke.Thickness = 4
				end
				e.tile.BackgroundColor3 = Color3.fromRGB(255, 248, 226)
				e.name.TextColor3 = INKED
			elseif pending then
				-- Chosen, and not a failure: the tap DID land. Sun-coloured like
				-- WORN because it is the same answer one doorway later, but at the
				-- outline's ordinary weight so the tool actually in their hands
				-- keeps the heavier rim.
				e.lbl.Text = "AT THE DOOR"
				e.face.BackgroundColor3 = C.sun
				if e.slab then e.slab.BackgroundColor3 = darken(C.sun, 0.45) end
				if e.stroke then
					e.stroke.Color = C.sun
					e.stroke.Thickness = 3
				end
				e.tile.BackgroundColor3 = Color3.fromRGB(255, 250, 238)
				e.name.TextColor3 = INKED
			elseif owned then
				--[[
					EQUIP, NOT "WEAR", AND THE TWO WORDS WERE THE WHOLE PROBLEM.

					Reported 2026-09-21 from an 814x430 phone: "Is the button to switch
					skins supposed to be 'Wear'? Might be bugged." It was not bugged --
					verified in Play, the press moves WORN across correctly -- and that
					is exactly what makes the report worth acting on. Somebody could not
					tell the ACTION from the STATE and assumed the panel was broken.

					Look at the sheet they were looking at: six tiles reading WEAR and
					one reading WORN. Four letters each, the same pill, the same colour
					weight, one transposed letter in the middle. It is the same failure
					WashServer wrote up for the bin and mount prompts -- "same length,
					same shape ... would read as one control drawn twice" -- and it is
					worse here, because these two sit in a grid with each other.

					EQUIP shares no letter position with WORN, is a different length, and
					reads as an instruction rather than a description. It is also ALREADY
					THIS PANEL'S OWN WORD: the pets tab two rows up says EQUIP BEST and
					TAKE OFF. The skins tab speaking a second dialect was the odd one out.

					WORN stays. It is the right word for the state and nothing else in
					the sheet now looks like it.
				]]
				e.lbl.Text = "EQUIP"
				e.face.BackgroundColor3 = C.lime
				if e.slab then e.slab.BackgroundColor3 = darken(C.lime, 0.45) end
				if e.stroke then
					e.stroke.Color = RULE
					e.stroke.Thickness = 3
				end
				e.tile.BackgroundColor3 = C.white
				e.name.TextColor3 = INKED
			else
				-- LOCKED, and it says so on the key rather than only in the sub-line:
				-- the button is the thing a finger goes to, so it has to be the thing
				-- that says it will not do anything yet.
				e.lbl.Text = "LOCKED"
				e.face.BackgroundColor3 = Color3.fromRGB(198, 190, 176)
				if e.slab then e.slab.BackgroundColor3 = Color3.fromRGB(150, 142, 128) end
				if e.stroke then
					e.stroke.Color = Color3.fromRGB(186, 178, 164)
					e.stroke.Thickness = 3
				end
				e.tile.BackgroundColor3 = Color3.fromRGB(242, 238, 230)
				-- The name goes quiet too, so a locked row does not shout its prize
				-- at the same weight as one the player can actually put on.
				e.name.TextColor3 = Color3.fromRGB(132, 122, 108)
			end
		end
	end

	------------------------------------------------------------------
	-- THE VIEWPORT POOL
	------------------------------------------------------------------
	--[[
		EVERY TILE SHOWS ITS PET; NOT EVERY TILE OWNS A VIEWPORT.

		A handful of viewports get MOVED to whatever the player is looking at as
		they scroll -- the same trick EggClient's reel plays with its eleven
		tiles. Six across and about three rows of a 328-tall band is roughly
		thirty live scenes at any moment, which is fewer than the thirty-six the
		old fixed budget paid for whether they were on screen or not.

		THE WINDOW IS ARITHMETIC, NOT MEASUREMENT. Asking 250 cells for their
		AbsolutePosition on every frame of a drag is how a scroll becomes a
		stutter. A UIGridLayout's geometry is knowable -- cell size, padding,
		column count -- so a row falls out of a LayoutOrder and a y falls out of
		the row. Those numbers are re-read from the layout on each pass rather
		than remembered, because the pop-in tween resizes the panel underneath
		them on every open.
	]]
	-- Unassigned viewports wait here. It is invisible, and a ViewportFrame
	-- under a hidden frame is not rendered, so parked costs nothing. NOT in the
	-- scroll: the UIGridLayout would hand it a cell of its own.
	local park = Instance.new("Frame")
	park.Name = "ViewportPool"
	park.Size = UDim2.fromOffset(0, 0)
	park.BackgroundTransparency = 1
	park.Visible = false
	park.Parent = tray

	local pool = {}    -- every viewport ever made, parked or standing
	local slots = {}   -- index -> { host, ph, petId }, in LayoutOrder order
	local live = {}    -- index -> the viewport standing in that slot

	local function release(i: number)
		local vp = live[i]
		if not vp then
			return
		end
		live[i] = nil
		showPet(vp, nil)
		vp.Parent = park
		local slot = slots[i]
		if slot and slot.ph then
			slot.ph.Visible = true
		end
	end

	local function freeViewport(): ViewportFrame?
		for i = #pool, 1, -1 do
			local vp = pool[i]
			if not vp.Parent then
				-- Destroyed along with a cell in spite of trimCells parking it
				-- first. Drop it rather than leave a hole the pool can never fill
				-- again.
				table.remove(pool, i)
			elseif vp.Parent == park then
				return vp
			end
		end
		if #pool >= POOL_CAP then
			return nil
		end
		local vp = petViewport(park)
		vp.ZIndex = 4
		table.insert(pool, vp)
		return vp
	end

	local function assign(i: number): boolean
		if live[i] then
			return true
		end
		local slot = slots[i]
		if not slot or not slot.petId then
			-- An undiscovered pet has no model to stand up, so it does not spend
			-- a viewport on being a silhouette of nothing.
			return true
		end
		local vp = freeViewport()
		if not vp then
			return false
		end
		vp.Parent = slot.host
		showPet(vp, slot.petId)
		slot.ph.Visible = false
		live[i] = vp
		return true
	end

	--[[
		THE GRID IS AUTHORED IN UNSCALED OFFSETS AND MEASURED IN REAL PIXELS, AND
		THE TWO ARE NOT THE SAME NUMBER.

		UiFit puts a UIScale over the whole HUD -- 0.77 on the window this was
		measured in, and the 0.6 floor on every phone -- so a cell authored 104
		wide renders 80 wide, while CanvasPosition and AbsoluteSize come back in
		the pixels it actually rendered at. Dividing the second by the first
		counted FOUR columns where there were six, and the error compounds with
		every row scrolled past: measured at the foot of a full 250-pet
		collection, the window pointed at slots 153-172 while the player was
		looking at 235-250, so not one of the sixteen tiles on screen had its pet
		in it. A wall of lettering -- which is the exact bug the header of this
		file claims the pool replaced.

		It only ever showed up in a big collection because near the top of the
		list the drift is still smaller than one row.

		THE SCALE IS TAKEN FROM A CELL, not by walking the UIScale chain: the
		grid has already laid one out at exactly CellSize x scale, so the cell IS
		the measurement, and it costs one property read instead of a walk to the
		ScreenGui on every frame of a drag.
	]]
	local function layoutScale(): number
		local probe = scroll:FindFirstChildWhichIsA("GuiObject")
		local authored = gridLay.CellSize.X.Offset
		if probe and authored > 0 and probe.AbsoluteSize.X > 0 then
			return probe.AbsoluteSize.X / authored
		end
		return 1
	end

	-- The range of slot indices that deserve a live model right now.
	local function window(): (number, number)
		local s = layoutScale()
		local padX = gridLay.CellPadding.X.Offset * s
		local stepX = math.max(gridLay.CellSize.X.Offset * s + padX, 1)
		local inner = scroll.AbsoluteSize.X
			- (gridPad.PaddingLeft.Offset + gridPad.PaddingRight.Offset) * s
		local cols = math.max(1, math.floor((inner + padX) / stepX))

		local cellH = gridLay.CellSize.Y.Offset * s
		local stepY = math.max(cellH + gridLay.CellPadding.Y.Offset * s, 1)
		local top = scroll.CanvasPosition.Y - gridPad.PaddingTop.Offset * s
		local band = scroll.AbsoluteSize.Y

		-- A row is in the band when its bottom is past the top of the view and
		-- its top is short of the bottom of it. The run-up is added after that,
		-- so a row is already standing before it is scrolled into.
		local firstRow = math.floor((top - cellH) / stepY) + 1 - POOL_RUNUP
		local lastRow = math.ceil((top + band) / stepY) - 1 + POOL_RUNUP
		return math.max(1, firstRow * cols + 1), (lastRow + 1) * cols
	end

	local function pass()
		local first, last = window()
		-- Let go of what has left the band FIRST, so those viewports are on the
		-- free list for the tiles that just entered it.
		for i in live do
			if i < first or i > last then
				release(i)
			end
		end
		for i = first, math.min(last, #slots) do
			if not assign(i) then
				break
			end
		end
	end

	-- ONE PASS PER FRAME, whatever asked for it. CanvasPosition changes every
	-- frame of a drag and AbsoluteSize every frame of the pop-in, and running
	-- the sweep per signal would do one frame's work several times over.
	local passQueued = false
	local function schedule()
		if passQueued then
			return
		end
		passQueued = true
		task.defer(function()
			passQueued = false
			if root.Visible then
				pass()
			end
		end)
	end

	-- Parented to the TRAY, not the scroll: inside a UIGridLayout these would
	-- each be cropped into one 104-wide cell.
	local emptyMsg = text(tray, "No pets yet", 24, Enum.Font.LuckiestGuy, darken(CREAM, 0.45))
	emptyMsg.AnchorPoint = Vector2.new(0.5, 0.5)
	emptyMsg.Position = UDim2.fromScale(0.5, 0.44)
	emptyMsg.Size = UDim2.new(1, -40, 0, 30)
	emptyMsg.ZIndex = 3
	emptyMsg.Visible = false

	local emptyHint = text(tray, "Hatch one at any egg station -- every island has them.",
		15, Enum.Font.GothamMedium, darken(CREAM, 0.35))
	emptyHint.AnchorPoint = Vector2.new(0.5, 0.5)
	emptyHint.Position = UDim2.fromScale(0.5, 0.53)
	emptyHint.Size = UDim2.new(1, -40, 0, 24)
	emptyHint.ZIndex = 3
	emptyHint.Visible = false

	--[[
		"I BOUGHT A PET AND I CAN'T USE IT."  Reported 2026-09-18 from a 764x384
		phone, one minute into a first session, rebirth 0.

		Nothing was broken and nothing was missing: tapping a tile toggles equip
		(see the send further down) and the server has handled it all along. What
		the panel never does is SAY so. The three things a new player can see are
		EQUIP BEST, TRADE and a big red TAKE OFF -- none of which is "use this
		one" -- and the gesture that does work has no affordance at all.

		SHOWN ONLY IN THE STUCK STATE: pets owned, none of them on. That is the
		exact position the reporter was in, it cannot be reached by anyone who
		has already worked it out, and it clears itself the instant they tap a
		pet -- so nobody who understands the panel ever sees it twice.

		Pinned to the BOTTOM of the tray rather than the middle: the middle is
		where emptyMsg lives, and a player in this state has tiles on screen for
		it to collide with. Its own backing plate, because it sits over them.
	]]
	local equipHint = Instance.new("Frame")
	equipHint.Name = "EquipHint"
	equipHint.AnchorPoint = Vector2.new(0.5, 1)
	equipHint.Position = UDim2.new(0.5, 0, 1, -8)
	equipHint.Size = UDim2.new(1, -28, 0, 26)
	equipHint.BackgroundColor3 = C.ink
	equipHint.BackgroundTransparency = 0.18
	equipHint.BorderSizePixel = 0
	equipHint.ZIndex = 8
	equipHint.Visible = false
	equipHint.Parent = tray
	corner(equipHint, 9)

	local equipHintLbl = text(equipHint, "Tap a pet to equip it",
		15, Enum.Font.GothamMedium, C.white)
	equipHintLbl.Size = UDim2.fromScale(1, 1)
	equipHintLbl.ZIndex = 9

	------------------------------------------------------------------
	-- LUCK, ALONG THE FOOT
	------------------------------------------------------------------
	--[[
		THE ONE NUMBER THE WHOLE PANEL IS ARITHMETIC ABOUT, and it had been
		sitting in a row of pills being read as one more chip. It is a caption
		on the panel now: the clover, then the total, in white on the well with
		NOTHING DRAWN BEHIND IT. No slab, no fill, no outline box -- the well is
		already the dark value this contrasts against, and a pill here would be
		a third rectangle competing with the tray above and the toolbar below.

		BOTTOM LEFT, FLUSH AT x=0, which is the same edge the tray above it and
		the TAKE OFF key below it are on. Three things sharing one margin reads
		as a column; the same three staggered reads as three separate decisions.

		The geometry it has to clear: the tray ends at 448, this occupies 452 to
		492, the toolbar starts at 496. All three come out of the 546 the body
		measures, so moving any one of them means moving TRAY_BOTTOM with it.
	]]
	-- The clover from the brief, keyed off its white ground and uploaded. An
	-- IMAGE on purpose -- see the note at the top about what a glyph does here.
	local CLOVER = "rbxassetid://82411464535798"

	local luckStrip = Instance.new("Frame")
	luckStrip.Name = "Luck"
	luckStrip.AnchorPoint = Vector2.new(0, 1)
	luckStrip.Position = UDim2.new(0, 0, 1, -54)
	luckStrip.Size = UDim2.new(1, 0, 0, 40)
	luckStrip.BackgroundTransparency = 1
	luckStrip.Parent = body

	local luckLay = Instance.new("UIListLayout")
	luckLay.FillDirection = Enum.FillDirection.Horizontal
	luckLay.HorizontalAlignment = Enum.HorizontalAlignment.Left
	luckLay.VerticalAlignment = Enum.VerticalAlignment.Center
	luckLay.Padding = UDim.new(0, 10)
	luckLay.SortOrder = Enum.SortOrder.LayoutOrder
	luckLay.Parent = luckStrip

	local clover = Instance.new("ImageLabel")
	clover.Name = "Clover"
	clover.LayoutOrder = 1
	clover.Size = UDim2.fromOffset(34, 34)
	clover.BackgroundTransparency = 1
	clover.Image = CLOVER
	clover.ScaleType = Enum.ScaleType.Fit
	clover.ZIndex = 5
	clover.Parent = luckStrip

	--[[
		AUTOMATICSIZE, so the pair stays centred as the number grows. In a fixed
		box the clover would sit still while "+5%" became "+140%" inside a
		centred string, and the two would drift apart. TextTruncate goes off with
		it: PanelKit.text sets AtEnd by default, and a box measured FROM the
		string that also truncates that string can only ever fight itself.
	]]
	local luckText = text(luckStrip, "+0% LUCK", 24, Enum.Font.LuckiestGuy, C.white)
	luckText.LayoutOrder = 2
	luckText.AutomaticSize = Enum.AutomaticSize.X
	luckText.Size = UDim2.fromOffset(0, 34)
	luckText.TextTruncate = Enum.TextTruncate.None
	punch(luckText, 3)

	------------------------------------------------------------------
	-- THE TOOLBAR
	------------------------------------------------------------------
	local toolRow = Instance.new("Frame")
	toolRow.Name = "Toolbar"
	toolRow.AnchorPoint = Vector2.new(0, 1)
	toolRow.Position = UDim2.new(0, 0, 1, 0)
	toolRow.Size = UDim2.new(1, 0, 0, 50)
	toolRow.BackgroundTransparency = 1
	toolRow.Parent = body

	-- LEFT: the red key, which is TAKE OFF. The reference puts a red button on
	-- this corner and "take everything off" is the destructive-looking global
	-- action this panel has, so it is the one that goes there.
	local offHolder, offFace = chunky(toolRow, 150, 44, C.coral, 13)
	offHolder.AnchorPoint = Vector2.new(0, 0.5)
	offHolder.Position = UDim2.new(0, 0, 0.5, 0)
	local offLbl = text(offFace, "TAKE OFF", 18, Enum.Font.LuckiestGuy, C.white)
	offLbl.Size = UDim2.fromScale(1, 1)
	punch(offLbl, 2)
	TouchFit.press(offFace, function()
		send({ action = "unequipAll" })
	end)

	-- MIDDLE: the icon row.
	--[[
		SIX KEYS NOW. 6 x 62 + 5 x 8 = 412, starting at x 164, so the row ends at
		576.

		THE TOOLBAR IS 718 WIDE, NOT 780, AND THE NOTE THAT SAID 780 COST A ROUND
		OF THIS. Sizing the sixth key off that figure put the row's end at 576 with
		the search field starting at 780 - 190 = 590, which looked like fourteen
		clear -- and measured in Play the field actually starts at 718 - 190 = 528
		and FUSE was sitting twenty pixels inside it. Measured, not inherited:
		toolbar 524px on screen at UiFit's 0.73, so 718 authored.

		So the search field ends at 718 and begins at 718 - 132 = 586, ten clear of
		the row.

		THE SEARCH FIELD COULD AFFORD IT AND THE KEYS COULD NOT. 132 still holds
		the placeholder and about ten characters, and a TextBox scrolls as you type
		past its width -- a filter is a few letters, not a whole name. Buying the
		room out of the keys instead would have taken all six of them under the
		44px touch target, which is the trade this file keeps refusing to make.
	]]
	local iconRow = Instance.new("Frame")
	iconRow.AnchorPoint = Vector2.new(0, 0.5)
	iconRow.Position = UDim2.new(0, 164, 0.5, 0)
	iconRow.Size = UDim2.fromOffset(412, 46)
	iconRow.BackgroundTransparency = 1
	iconRow.Parent = toolRow

	local iconLay = Instance.new("UIListLayout")
	iconLay.FillDirection = Enum.FillDirection.Horizontal
	iconLay.VerticalAlignment = Enum.VerticalAlignment.Center
	iconLay.Padding = UDim.new(0, 8)
	iconLay.SortOrder = Enum.SortOrder.LayoutOrder
	iconLay.Parent = iconRow

	local rebuild   -- forward-declared: the toolbar calls it

	-- TRASH: toggles release mode. The per-tile X used to be on every tile all
	-- the time, which is a delete button under the thumb on every single pet.
	-- Behind a mode it is deliberate, and the tiles are cleaner the rest of
	-- the time -- which is what the reference's tiles look like.
	local trashBtn = toolButton(iconRow, 1, "RELEASE", function(b)
		toolArt(b, "rbxassetid://95260864403061", 40)
	end)

	-- GRID: swaps Collection and Index, which is what the reference's window
	-- icon does in spirit -- change what the tray is showing.
	local viewBtn = toolButton(iconRow, 2, "INDEX", function(b)
		toolArt(b, "rbxassetid://102725814059798", 26)
	end)

	-- LOCK: equipped pets cannot be released, and this says so rather than
	-- leaving the player to find out by tapping one.
	local lockBtn = toolButton(iconRow, 3, "LOCKED", function(b)
		toolArt(b, "rbxassetid://108638930019827", 26)
	end)

	--[[
		TIDY: KEEP THE BEST N AND LET THE REST GO.

		THE ROW WAS ALREADY THE RIGHT WIDTH. Four 62-wide keys and three 8px gaps
		is 272, which is exactly what iconRow was authored at, so the fourth key
		costs nothing above it or beside it.

		DRAWN WITH star(), WHICH HAD BECOME DEAD CODE. It was written for the
		rarity badge and lost that job when the tier turned into a coloured strip
		across the foot of the tile -- it has had no call site since. A star is
		exactly what "best" means, and a drawn shape cannot fail to render on a
		device missing the glyph, which is the rule at the top of this file.
	]]
	--[[
		THE WARDROBE KEY, DRAWN RATHER THAN TYPED, which is the rule at the top of
		this file -- a glyph a device is missing renders as a box, and the four keys
		beside it are art or shapes for the same reason.

		Three stacked bands, the same shape the tiles themselves wear, so the key
		and the thing it opens are recognisably one idea. Colours are taken off the
		sea/lime/sun triad rather than any one skin's palette: a key wearing the
		driftwood browns would go wrong the moment somebody is wearing sea glass.
	]]
	local skinsBtn = toolButton(iconRow, 5, "SKINS", function(b)
		local bands = { C.sea, C.lime, C.sun }
		for i, col in ipairs(bands) do
			local band = Instance.new("Frame")
			band.AnchorPoint = Vector2.new(0.5, 0)
			band.Position = UDim2.new(0.5, 0, 0, 6 + (i - 1) * 8)
			band.Size = UDim2.fromOffset(26, 6)
			band.BackgroundColor3 = col
			band.BorderSizePixel = 0
			band.ZIndex = 7
			band.Parent = b
			corner(band, 2)
		end
	end)

	local tidyBtn = toolButton(iconRow, 4, "TIDY", function(b)
		local s = star(b, 26, C.sun, 7)
		s.AnchorPoint = Vector2.new(0.5, 0.5)
		s.Position = UDim2.new(0.5, 0, 0, 16)
	end)

	--[[
		FUSE: FIVE DUPLICATES BECOME ONE OF THE RUNG ABOVE.

		DRAWN, NOT TYPED, which is the rule at the top of this file and the reason
		TIDY is a star and SKINS is three bands: a glyph a device is missing renders
		as a box. Two small diamonds on the left and one larger on the right is the
		whole idea of the action in three frames -- several things becoming one
		bigger thing -- and it reads at 62px without a caption, which the caption
		underneath then confirms.

		Sun for the output and sea for the inputs, so the ONE is the thing the eye
		lands on. Both colours are already on this row (TIDY's star, the SKINS
		bands), so the key belongs to the same set rather than introducing a sixth
		hue to a row that is already busy.
	]]
	local fuseBtn = toolButton(iconRow, 6, "FUSE", function(b)
		local function pip(x: number, y: number, size: number, col: Color3)
			local q = Instance.new("Frame")
			q.AnchorPoint = Vector2.new(0.5, 0.5)
			q.Position = UDim2.fromOffset(x, y)
			q.Size = UDim2.fromOffset(size, size)
			q.BackgroundColor3 = col
			q.Rotation = 45
			q.BorderSizePixel = 0
			q.ZIndex = 7
			q.Parent = b
			corner(q, 3)
		end
		-- Inside y 4..30: the caption owns the bottom 13px of a 46-tall key.
		pip(18, 11, 10, C.sea)
		pip(18, 23, 10, C.sea)
		pip(42, 17, 16, C.sun)
	end)

	-- RIGHT: the search field.
	local searchBox = Instance.new("TextBox")
	searchBox.AnchorPoint = Vector2.new(1, 0.5)
	searchBox.Position = UDim2.new(1, 0, 0.5, 0)
	searchBox.Size = UDim2.fromOffset(132, 46)
	searchBox.BackgroundColor3 = CREAM
	searchBox.BorderSizePixel = 0
	searchBox.Font = Enum.Font.GothamBold
	searchBox.TextSize = 16
	searchBox.TextColor3 = INKED
	searchBox.PlaceholderText = "Search"
	searchBox.PlaceholderColor3 = darken(CREAM, 0.42)
	searchBox.Text = ""
	searchBox.ClearTextOnFocus = false
	searchBox.Parent = toolRow
	corner(searchBox, 14)
	do
		local st = outline(searchBox, 3)
		if st and st:IsA("UIStroke") then
			st.Color = RULE
		end
		local p = Instance.new("UIPadding")
		p.PaddingLeft = UDim.new(0, 14)
		p.PaddingRight = UDim.new(0, 14)
		p.Parent = searchBox
	end
	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		filter = string.lower(searchBox.Text)
		-- A different list: start at the top. See restoreScroll.
		rebuild(false)
	end)

	------------------------------------------------------------------
	-- PUTTING A chunky() KEY ON TOP OF A MODAL
	------------------------------------------------------------------
	--[[
		THIS ScreenGui RUNS ZIndexBehavior.Global, WHERE ZIndex IS ABSOLUTE.

		Not per-parent: a child at 1 renders BEHIND a parent at 40, which is the
		opposite of what Sibling mode does and the opposite of what anyone writing
		a button expects. PanelKit.chunky builds its slab, face, gloss and label at
		1..5, and that is correct everywhere they sit on the panel BODY -- the tray
		is at 1 and the toolbar keys have nothing opaque over them.

		It is wrong the moment a caller raises the holder to sit on a MODAL. Both
		cards below are opaque cream at 40 and 60, and setting only
		`holder.ZIndex = 42` left the slab and the face and the lettering down at
		1 -- so the key was built, positioned, visible and still clickable, and
		PAINTED UNDERNEATH THE CARD IT BELONGS TO. Nothing on screen to press.

		THE BUG THIS FIXES, reported from the game on 2026-09-09 as "in the Pet
		Index there is no way to dismiss just the selected pet's window". There
		was not: the CLOSE key was under the card. The release confirmation was
		worse and nobody had reported it yet -- BOTH its keys were under the card,
		so "RELEASE THIS PET? This cannot be undone." came up over a Legendary
		with no visible way to answer it either way.

		OFFSETS RATHER THAN A FLAT WRITE, so the ordering chunky authored inside
		the key survives: the face sits with the slab, the gloss above both, the
		lettering above that.

		CALL IT LAST, AFTER EVERY CHILD IS PARENTED. It walks the descendants that
		exist WHEN IT RUNS, so a label added on the next line keeps its authored
		ZIndex and drops behind the face it was meant to sit on -- which is a red
		key with no word on it, and how this fix looked on its first attempt.
	]]
	local function lift(holder: GuiObject, base: number)
		holder.ZIndex = base
		for _, d in holder:GetDescendants() do
			if d:IsA("GuiObject") then
				d.ZIndex = base + (d.ZIndex - 1)
			end
		end
	end

	------------------------------------------------------------------
	-- DETAIL CARD  (the panel's one other viewport)
	------------------------------------------------------------------
	--[[
		THE SCRIM, AND IT IS A BUTTON.

		The card had none: it was a 300x320 frame floating on the gui with a CLOSE
		key near its foot and nothing behind it, so the one gesture everybody tries
		first -- tap the screen anywhere else -- did nothing at all. A player said
		so on 2026-09-09: "in the pet index there is no way to close just the
		selected pet's window". The CLOSE key was there; what was missing was the
		way out they reached for.

		THE GAME ALREADY DOES THIS in MenuHud's own item Index, whose detail card
		sits on exactly this: a full-screen TextButton at 0.42 transparency wired
		straight to its close. So the Pet Index was the odd one out rather than the
		two being unspecified, which is the worst kind of inconsistency -- the
		player learns the gesture in one panel and it silently fails in the other.

		SIBLINGS, NOT PARENT AND CHILD -- and that is the one place this does NOT
		copy the item Index, which parents its card into its scrim.

		UiFit absorbs a ScreenGui's top-level children and scales them, but ONLY
		when both size axes are pure offset -- so this scrim, sized fromScale(1,1),
		is deliberately left alone at full screen, exactly as IntroCinema's backdrop
		is. Parenting the card into it therefore takes the CARD out of UiFit's reach
		too: measured, it went from 180x192 to its raw 300x320 on a 333px-tall
		viewport -- taller than the screen it is centred on.

		So the card stays a direct child of the gui where UiFit can still find it,
		and the two are shown and hidden together. openDetail and closeDetail are
		the only writers of either, which is what keeps them in step.
	]]
	local dim = Instance.new("TextButton")
	dim.Name = "PetDetailScrim"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.fromRGB(10, 14, 22)
	dim.BackgroundTransparency = 0.42
	dim.BorderSizePixel = 0
	dim.AutoButtonColor = false
	dim.Text = ""
	dim.Visible = false
	dim.ZIndex = 39
	dim.Parent = gui

	local detail = Instance.new("Frame")
	-- Parented to `gui`, NOT to `dim` -- see the note above; this is what keeps
	-- UiFit scaling the card down on a phone.
	detail.Name = "PetDetail"
	detail.AnchorPoint = Vector2.new(0.5, 0.5)
	detail.Position = UDim2.fromScale(0.5, 0.5)
	detail.Size = UDim2.fromOffset(300, 320)
	detail.BackgroundColor3 = CREAM
	detail.BorderSizePixel = 0
	detail.Visible = false
	detail.ZIndex = 40
	detail.Parent = gui
	corner(detail, 18)
	do
		local st = outline(detail, 4)
		if st and st:IsA("UIStroke") then
			st.Color = RULE
		end
	end

	local dVp = petViewport(detail)
	dVp.Size = UDim2.new(1, -24, 0, 176)
	dVp.Position = UDim2.fromOffset(12, 14)
	dVp.ZIndex = 41

	-- INKED, not white: the card is cream now, so the lettering reverses.
	local dName = text(detail, "", 22, Enum.Font.LuckiestGuy, INKED)
	dName.Size = UDim2.new(1, -20, 0, 30)
	dName.Position = UDim2.fromOffset(10, 196)
	dName.ZIndex = 42

	local dTier = text(detail, "", 15, Enum.Font.LuckiestGuy, INKED)
	dTier.Size = UDim2.new(1, -20, 0, 22)
	dTier.Position = UDim2.fromOffset(10, 226)
	dTier.ZIndex = 42

	local dLuck = text(detail, "", 15, Enum.Font.GothamBold, darken(INKED, -0.35))
	dLuck.Size = UDim2.new(1, -20, 0, 22)
	dLuck.Position = UDim2.fromOffset(10, 250)
	dLuck.ZIndex = 42

	local dCloseHolder, dCloseFace = chunky(detail, 110, 34, C.coral, 12)
	dCloseHolder.AnchorPoint = Vector2.new(0.5, 0)
	dCloseHolder.Position = UDim2.new(0.5, 0, 1, -44)
	local dCloseLbl = text(dCloseFace, "CLOSE", 15, Enum.Font.LuckiestGuy, C.white)
	dCloseLbl.Size = UDim2.fromScale(1, 1)
	lift(dCloseHolder, 42)

	--[[
		THE OTHER MODAL THIS PANEL OWNS, forward-declared because it is built
		below and has to be reachable from here.

		closeDetail is the ONE hook MenuHud calls when it hides a panel, and its
		note over there says exactly why it exists: a modal parented to `gui`
		rather than to the panel's root does not go away when the root is hidden,
		and is left standing over whatever opens next. The release confirmation is
		a second such modal, so it goes out through the same door -- a card asking
		"release this pet?" floating over the shop is the worst version of that
		bug rather than a cosmetic one.
	]]
	local dismissConfirm = nil
	-- The THIRD modal this panel owns, and it goes out through the same door for
	-- the same reason the release confirmation does: parented to `gui`, so hiding
	-- the panel root would leave it standing over whatever opens next.
	local dismissTidy = nil

	local function closeDetail()
		dim.Visible = false
		detail.Visible = false
		showPet(dVp, nil)
		if dismissConfirm then
			dismissConfirm()
		end
		if dismissTidy then
			dismissTidy()
		end
	end
	TouchFit.press(dCloseFace, closeDetail)
	-- Tap anywhere off the card. Registered on the scrim, which sits BELOW the
	-- card's own ZIndex, so a tap that lands on the card is still the card's.
	TouchFit.press(dim, closeDetail)
	panels.Pets.closeDetail = closeDetail

	local function openDetail(petId: string, known: boolean)
		local def = PetConfig.get(petId)
		if not def then
			return
		end
		local info = PetConfig.tierInfo(def.Tier)
		showPet(dVp, known and petId or nil)
		dName.Text = known and def.DisplayName or "???"
		dTier.Text = string.upper(def.Tier)
		dTier.TextColor3 = darken(info.color, 0.35)
		dLuck.Text = known
			and (PetConfig.luckText(def.Luck) .. " cleaning luck")
			or "Not discovered yet."
		dim.Visible = true
		detail.Visible = true
		PanelKit.popIn(detail, 300, 320)
	end

	------------------------------------------------------------------
	-- A LINE ALONG THE FOOT OF THE TRAY
	------------------------------------------------------------------
	-- Was written inline in the lock button's handler, which is the only place
	-- that used it. Three callers now, so it is a function -- and one of them is
	-- a refusal the player has to be able to act on.
	local saying = nil
	local function say(msg: string)
		if saying then
			saying:Destroy()
			saying = nil
		end
		local lbl = text(tray, msg, 15, Enum.Font.GothamBold, darken(CREAM, 0.5))
		lbl.AnchorPoint = Vector2.new(0.5, 1)
		lbl.Position = UDim2.new(0.5, 0, 1, -8)
		lbl.Size = UDim2.new(1, -40, 0, 22)
		lbl.ZIndex = 6
		saying = lbl
		task.delay(2.6, function()
			if lbl == saying then
				saying = nil
			end
			if lbl.Parent then
				lbl:Destroy()
			end
		end)
	end

	------------------------------------------------------------------
	-- THE RELEASE CONFIRMATION
	------------------------------------------------------------------
	--[[
		WHY THIS EXISTS, AND WHY IT IS NOT ON EVERY PET.

		Release mode is a STICKY toggle and a release is unrecoverable, so until
		this card existed the whole distance between a player's best pet and
		nothing was one tap on a tile. A player lost a Mythic that way on
		2026-09-09 -- they unequipped it, which removed the only guard there was,
		and the tap meant to put it back on destroyed it instead.

		The padlock is the real fix and this is the backstop for the pet that has
		not been locked yet. It is deliberately NOT on every release: the same
		player asked for bulk deletion in the same week, and a confirm card in
		front of every one of two hundred Commons is the opposite of that. So it
		asks about the tiers that are worth asking about and stays out of the way
		for the rest.

		PRECIOUS IS A TIER RANK, NOT A LIST OF NAMES. PetConfig.TierOrder is the
		one place tiers are ranked, so a tier added above Legendary is covered by
		this the day it is added and nobody has to remember to come here.
	]]
	local PRECIOUS = PetConfig.TierOrder.Legendary or 5

	local confirm = Instance.new("Frame")
	confirm.Name = "ReleaseConfirm"
	confirm.AnchorPoint = Vector2.new(0.5, 0.5)
	confirm.Position = UDim2.fromScale(0.5, 0.5)
	confirm.Size = UDim2.fromOffset(320, 194)
	confirm.BackgroundColor3 = CREAM
	confirm.BorderSizePixel = 0
	confirm.Visible = false
	confirm.ZIndex = 60
	confirm.Parent = gui
	corner(confirm, 18)
	do
		local st = outline(confirm, 4)
		if st and st:IsA("UIStroke") then
			st.Color = RULE
		end
	end

	local cTitle = text(confirm, "RELEASE THIS PET?", 21, Enum.Font.LuckiestGuy, INKED)
	cTitle.Size = UDim2.new(1, -20, 0, 28)
	cTitle.Position = UDim2.fromOffset(10, 16)
	cTitle.ZIndex = 61

	local cName = text(confirm, "", 17, Enum.Font.LuckiestGuy, INKED)
	cName.Size = UDim2.new(1, -20, 0, 24)
	cName.Position = UDim2.fromOffset(10, 48)
	cName.ZIndex = 61

	local cWarn = text(confirm, "This cannot be undone.", 15, Enum.Font.GothamBold,
		darken(INKED, -0.3))
	cWarn.Size = UDim2.new(1, -20, 0, 22)
	cWarn.Position = UDim2.fromOffset(10, 76)
	cWarn.TextWrapped = true
	cWarn.ZIndex = 61

	local pending = nil     -- the petId the card is asking about

	local function closeConfirm()
		pending = nil
		confirm.Visible = false
	end

	local cNoHolder, cNoFace = chunky(confirm, 130, 38, C.sea, 12)
	cNoHolder.AnchorPoint = Vector2.new(0, 1)
	cNoHolder.Position = UDim2.new(0, 18, 1, -18)
	local cNoLbl = text(cNoFace, "KEEP IT", 15, Enum.Font.LuckiestGuy, C.white)
	cNoLbl.Size = UDim2.fromScale(1, 1)
	lift(cNoHolder, 62)
	TouchFit.press(cNoFace, closeConfirm)

	local cYesHolder, cYesFace = chunky(confirm, 130, 38, C.coral, 12)
	cYesHolder.AnchorPoint = Vector2.new(1, 1)
	cYesHolder.Position = UDim2.new(1, -18, 1, -18)
	local cYesLbl = text(cYesFace, "RELEASE", 15, Enum.Font.LuckiestGuy, C.white)
	cYesLbl.Size = UDim2.fromScale(1, 1)
	lift(cYesHolder, 62)
	TouchFit.press(cYesFace, function()
		local petId = pending
		closeConfirm()
		if petId then
			send({ action = "release", petId = petId })
		end
	end)

	-- Handed to the forward declaration above, so MenuHud's single closeDetail
	-- hook takes both modals down. NOT published as a second entry on
	-- panels.Pets: that would be a hook nothing calls.
	dismissConfirm = closeConfirm

	-- Straight through for anything below the precious line, so tidying a tray
	-- of Commons is still one tap a tile.
	local function askRelease(petId: string)
		local def = PetConfig.get(petId)
		if not def then
			return
		end
		if (def.TierIndex or 1) < PRECIOUS then
			send({ action = "release", petId = petId })
			return
		end
		pending = petId
		cName.Text = string.upper(def.DisplayName) .. "  " .. PetConfig.luckText(def.Luck)
		cName.TextColor3 = darken(PetConfig.tierColor(def.Tier), 0.4)
		confirm.Visible = true
		PanelKit.popIn(confirm, 320, 194)
	end

	------------------------------------------------------------------
	-- TIDY  --  KEEP THE BEST N, RELEASE THE REST
	------------------------------------------------------------------
	--[[
		BULK RELEASE, ASKED FOR BY NAME on 2026-09-09 alongside the padlock:
		"\u{30da}\u{30c3}\u{30c8}\u{306e}\u{30ed}\u{30c3}\u{30af}\u{3068}\u{4e00}\u{6589}\u{524a}\u{9664}\u{306e}\u{5b9f}\u{88c5}\u{3092}\u{304a}\u{9858}\u{3044}\u{3057}\u{307e}\u{3059}\u{3002}"

		It is the answer to the grind behind the scroll report from the same week:
		at MaxOwned the game refuses to hatch and sends you here, and clearing
		space was two hundred and fifty separate taps down a list that was fighting
		you the whole way.

		WHAT THE PLAYER STATES IS WHAT SURVIVES, NOT WHAT DIES. A number misread
		too low keeps fewer pets than they meant; the same slip on a "release
		everything below X" control destroys more than they meant. Neither is
		recoverable, so which way the mistake falls IS the design.

		THE COUNT IS NAMED BEFORE THE TAP. "Releases 187" is the number that
		actually matters, and it is worked out here with PetConfig.bestOf -- the
		same function the server sweeps with, and the same one EQUIP BEST already
		uses, so "your best" means ONE thing in this game rather than two that
		disagree. The server re-derives the sweep from its own tables and never
		trusts this figure; it exists so the card cannot promise one thing and the
		button do another.
	]]
	local TIDY_STEPS = { 10, 25, 50 }
	local tidyKeep = TIDY_STEPS[2]

	-- MIRRORS PetServer.keepBest, LINE FOR LINE. Change one and change the other,
	-- or the card starts lying about what the key will do.
	local function tidyReleaseCount(keep: number): number
		local survive = {}
		for _, petId in PetConfig.bestOf(state.owned, keep) do
			survive[petId] = (survive[petId] or 0) + 1
		end
		for petId, count in state.owned do
			if state.locked[petId] then
				survive[petId] = count
			end
		end
		local worn = {}
		for _, petId in state.equipped do
			worn[petId] = (worn[petId] or 0) + 1
		end
		for petId, n in worn do
			if (survive[petId] or 0) < n then
				survive[petId] = n
			end
		end
		local released = 0
		for petId, count in state.owned do
			local left = math.min(count, survive[petId] or 0)
			if left < count then
				released += count - left
			end
		end
		return released
	end

	local tidy = Instance.new("Frame")
	tidy.Name = "TidyCard"
	tidy.AnchorPoint = Vector2.new(0.5, 0.5)
	tidy.Position = UDim2.fromScale(0.5, 0.5)
	tidy.Size = UDim2.fromOffset(360, 232)
	tidy.BackgroundColor3 = CREAM
	tidy.BorderSizePixel = 0
	tidy.Visible = false
	tidy.ZIndex = 70
	tidy.Parent = gui
	corner(tidy, 18)
	do
		local st = outline(tidy, 4)
		if st and st:IsA("UIStroke") then
			st.Color = RULE
		end
	end

	local tTitle = text(tidy, "KEEP YOUR BEST", 21, Enum.Font.LuckiestGuy, INKED)
	tTitle.Size = UDim2.new(1, -20, 0, 28)
	tTitle.Position = UDim2.fromOffset(10, 14)
	tTitle.ZIndex = 71

	-- THREE KEYS, NOT A NUMBER BOX. This panel is used on a phone more than
	-- anywhere else, and a typed field there is a keyboard over the card.
	local tRow = Instance.new("Frame")
	tRow.BackgroundTransparency = 1
	tRow.AnchorPoint = Vector2.new(0.5, 0)
	tRow.Position = UDim2.new(0.5, 0, 0, 48)
	tRow.Size = UDim2.fromOffset(320, 40)
	tRow.ZIndex = 71
	tRow.Parent = tidy
	local tLay = Instance.new("UIListLayout")
	tLay.FillDirection = Enum.FillDirection.Horizontal
	tLay.HorizontalAlignment = Enum.HorizontalAlignment.Center
	tLay.VerticalAlignment = Enum.VerticalAlignment.Center
	tLay.Padding = UDim.new(0, 10)
	tLay.SortOrder = Enum.SortOrder.LayoutOrder
	tLay.Parent = tRow

	local tLine = text(tidy, "", 16, Enum.Font.GothamBold, darken(INKED, -0.25))
	tLine.Size = UDim2.new(1, -24, 0, 22)
	tLine.Position = UDim2.fromOffset(12, 100)
	tLine.ZIndex = 71

	local tSafe = text(tidy, "Locked and equipped pets are always kept.", 14,
		Enum.Font.GothamMedium, darken(INKED, -0.45))
	tSafe.Size = UDim2.new(1, -24, 0, 20)
	tSafe.Position = UDim2.fromOffset(12, 126)
	tSafe.TextWrapped = true
	tSafe.ZIndex = 71

	local tGoLbl = nil        -- the count rides on the key itself; built below
	local chips = {}

	local function paintTidy()
		local released = tidyReleaseCount(tidyKeep)
		tLine.Text = string.format("Keeps your best %d. Releases %d.", tidyKeep, released)
		if tGoLbl then
			tGoLbl.Text = (released > 0) and ("RELEASE " .. released) or "NOTHING TO DO"
		end
		for n, c in chips do
			local on = (n == tidyKeep)
			c.face.BackgroundColor3 = on and C.sun or CREAM
			c.lbl.TextColor3 = on and C.white or RULE
			if c.slab then
				c.slab.BackgroundColor3 = on and darken(C.sun, 0.35) or darken(CREAM, 0.18)
			end
			local st = c.face:FindFirstChildWhichIsA("UIStroke")
			if st then
				st.Color = on and darken(C.sun, 0.35) or RULE
			end
		end
	end

	for i, n in TIDY_STEPS do
		local holder, face = chunky(tRow, 92, 36, CREAM, 11)
		holder.LayoutOrder = i
		local lbl = text(face, tostring(n), 18, Enum.Font.LuckiestGuy, RULE)
		lbl.Size = UDim2.fromScale(1, 1)
		lift(holder, 72)
		chips[n] = { face = face, lbl = lbl, slab = holder:FindFirstChild("Slab") }
		TouchFit.press(face, function()
			tidyKeep = n
			paintTidy()
		end)
	end

	local function closeTidy()
		tidy.Visible = false
	end
	dismissTidy = closeTidy

	local tNoHolder, tNoFace = chunky(tidy, 140, 40, C.sea, 12)
	tNoHolder.AnchorPoint = Vector2.new(0, 1)
	tNoHolder.Position = UDim2.new(0, 18, 1, -16)
	local tNoLbl = text(tNoFace, "CANCEL", 16, Enum.Font.LuckiestGuy, C.white)
	tNoLbl.Size = UDim2.fromScale(1, 1)
	lift(tNoHolder, 72)
	TouchFit.press(tNoFace, closeTidy)

	local tGoHolder, tGoFace = chunky(tidy, 168, 40, C.coral, 12)
	tGoHolder.AnchorPoint = Vector2.new(1, 1)
	tGoHolder.Position = UDim2.new(1, -18, 1, -16)
	tGoLbl = text(tGoFace, "RELEASE", 16, Enum.Font.LuckiestGuy, C.white)
	tGoLbl.Size = UDim2.fromScale(1, 1)
	lift(tGoHolder, 72)
	TouchFit.press(tGoFace, function()
		local released = tidyReleaseCount(tidyKeep)
		closeTidy()
		if released > 0 then
			send({ action = "keepBest", keep = tidyKeep })
		end
	end)

	local function openTidy()
		paintTidy()
		tidy.Visible = true
		PanelKit.popIn(tidy, 360, 232)
	end

	------------------------------------------------------------------
	-- TILES
	------------------------------------------------------------------
	--[[
		THE REFERENCE'S TILE, which is a square with its badges INSIDE it and
		its number written UNDERNEATH on the tray.

		  top left     rarity, as one star per tier rung
		  top right    a green tick when the pet is equipped
		  bottom right the count, when you hold more than one
		  under it    the pet's luck, which is the number that matters here

		The tile is light and the pet sits on a tier-tinted wash, so rarity is
		legible without reading a word and the model has something to be seen
		against.
	]]
	--[[
		BUILT ONCE AND RE-DRESSED, NOT REBUILT.

		A cell used to be made from scratch on every rebuild, and a rebuild
		happens on every snapshot -- so releasing ONE pet out of a full bag
		destroyed 250 cells and built 250 more, about 3,100 instances, measured
		here at 67ms of dead frame ON A DESKTOP. On a phone that is the better
		part of half a second with nothing on screen moving, and it lands on
		exactly the player who is doing nothing else: at MaxOwned the game
		refuses to hatch and tells you to go and clear some space, so the cap is
		the one moment a player releases pet after pet after pet.

		AND ON TOUCH IT IS WORSE THAN A HITCH. A ScrollingFrame's drag is
		cancelled when the instance under the finger is destroyed, so tearing the
		whole grid out from under a gesture is how this reads as "vertical
		scrolling becomes impossible once the bag is full" rather than as a
		stutter.

		So the grid is a pool of cells, the same way the viewports above it are a
		pool of scenes. `cells` holds the PARTS of cell i, which never change;
		`shown` holds WHAT cell i is saying right now, which a rebuild writes
		over. Nothing is destroyed unless the list actually got shorter.
	]]
	local cells = {}    -- i -> the parts of cell i, for the life of the panel
	local shown = {}    -- i -> { petId, known, equipped, locked }

	-- Re-dress ONE cell from what it is already wearing. Forward-declared
	-- because the tap handler is built before dressCell exists, and arming a
	-- tile has to redraw that tile WITHOUT a rebuild -- a rebuild is one of the
	-- things that disarms it. See the note over `armed`.  2026-09-09
	local redress

	local function buildCell(i: number)
		-- The cell: the square plus the caption under it.
		local cell = Instance.new("Frame")
		cell.BackgroundTransparency = 1
		cell.LayoutOrder = i
		cell.ZIndex = 2
		cell.Parent = scroll

		local card = Instance.new("TextButton")
		card.Name = "Face"
		card.AutoButtonColor = false
		card.Text = ""
		card.Size = UDim2.fromOffset(104, 112)
		card.BorderSizePixel = 0
		card.ZIndex = 3
		card.Parent = cell
		corner(card, 14)
		local stroke = outline(card, 3)

		-- WHERE THE PET GOES. Every tile cuts the hole; whether a viewport is
		-- standing in it this frame is the pool's business, and the pool only
		-- reaches as far as the player can see.
		local host = Instance.new("Frame")
		host.Name = "Art"
		host.BackgroundTransparency = 1
		host.Size = UDim2.new(1, -6, 1, -26)
		host.Position = UDim2.fromOffset(3, 1)
		host.ZIndex = 4
		host.Parent = card

		-- What stands in the hole meanwhile: the name, which is what the whole
		-- grid used to be. A discovered pet only ever wears this OFF SCREEN, so
		-- it is a safety net rather than a state anybody is meant to see; the
		-- undiscovered have no model to show and keep it for good.
		local ph = text(card, "", 14, Enum.Font.LuckiestGuy, darken(CREAM, 0.5))
		ph.Size = UDim2.new(1, -12, 1, -30)
		ph.Position = UDim2.fromOffset(6, 5)
		ph.TextWrapped = true
		ph.ZIndex = 4

		--[[
			RARITY IS A NAMED STRIP, NOT A ROW OF STARS.

			One small star per tier rung was five yellow lozenges overlapping in a
			sixteen-pixel corner, and at tile size they read as one smear -- you
			could not count them, which is the only thing a row of stars is for.
			A coloured band across the foot of the tile with the tier written on it
			is legible at a glance, carries the tier's own colour, and gives the
			viewport above it a base to sit on.
		]]
		local band = Instance.new("Frame")
		band.Name = "Tier"
		band.AnchorPoint = Vector2.new(0.5, 1)
		band.Position = UDim2.new(0.5, 0, 1, -4)
		band.Size = UDim2.new(1, -10, 0, 20)
		band.BorderSizePixel = 0
		band.ZIndex = 5
		band.Parent = card
		corner(band, 8)
		local bandLbl = text(band, "", 11, Enum.Font.LuckiestGuy, C.white)
		bandLbl.Size = UDim2.fromScale(1, 1)
		bandLbl.ZIndex = 6
		punch(bandLbl, 2)

		-- EQUIPPED, top right: the green tick disc. Built once and shown or
		-- hidden, because a tick created and destroyed on every rebuild is the
		-- churn this whole section exists to stop.
		local disc = Instance.new("Frame")
		disc.Name = "Equipped"
		disc.AnchorPoint = Vector2.new(1, 0)
		disc.Position = UDim2.new(1, -5, 0, 5)
		disc.Size = UDim2.fromOffset(24, 24)
		disc.BackgroundColor3 = C.lime
		disc.BorderSizePixel = 0
		disc.ZIndex = 6
		disc.Visible = false
		disc.Parent = card
		corner(disc, 12)
		do
			local st = outline(disc, 2)
			if st and st:IsA("UIStroke") then
				st.Color = C.limeDark
			end
		end
		local t = tick(disc, 18, C.white, 7)
		t.AnchorPoint = Vector2.new(0.5, 0.5)
		t.Position = UDim2.fromScale(0.5, 0.5)

		-- THE NUMBER UNDER THE TILE. The reference writes the pet's value there
		-- in outlined type; ours is luck, because that is the stat this game
		-- has and the one the whole panel is arithmetic about.
		local cap = text(cell, "", 17, Enum.Font.LuckiestGuy, C.white)
		cap.Position = UDim2.fromOffset(0, 116)
		cap.Size = UDim2.fromOffset(104, 22)
		cap.ZIndex = 5
		punch(cap, 3)

		local e = {
			cell = cell, card = card, stroke = stroke, host = host, ph = ph,
			band = band, bandLbl = bandLbl, disc = disc, cap = cap,
			mark = nil, markKind = nil,
		}
		cells[i] = e

		--[[
			ONE CONNECTION FOR THE LIFE OF THE CELL, reading `shown[i]` rather
			than closing over a pet: this cell is reused for a DIFFERENT pet on
			the next rebuild, so a captured petId would act on whatever the tile
			used to be.

			BOTH REFUSALS ARE ALSO ENFORCED SERVER-SIDE, and this is only the
			half that keeps them rare. PetServer.release checks the lock and the
			worn copy itself, because this panel is a drawing of a snapshot and a
			snapshot can be stale.

			The LOCK is said out loud where being equipped is not: a tile with the
			green tick on it already explains its own refusal, and a locked one
			has to say where the padlock comes off or the pet simply looks stuck.

			The Index is a catalogue, not a collection: a tap opens the card.
			Locking is offered there too, because a lock is allowed to run ahead
			of the pet (see PetServer.setLocked) and the Index is where a player
			looks at one they have not hatched yet.
		]]
		TouchFit.activated(card, function()
			local s = shown[i]
			if not s then
				return
			end
			local petId = s.petId
			--[[
				ANY TAP DISARMS, and only the branch below re-arms.  2026-09-09

				Taken down here, at the top, so every path out of this handler --
				lock, detail card, equip, either refusal -- cancels the armed tile
				on the way past. A tile left saying RELEASE? while the player went
				off to equip something is a tile whose next tap is a delete, which
				is the same shape of bug as the sticky mode itself.
			]]
			local wasArmed = armed
			if wasArmed then
				armed = nil
				redress(wasArmed.i)
			end
			if lockMode then
				send({ action = "lock", petId = petId, locked = not s.locked })
			elseif view == "Index" then
				openDetail(petId, s.known)
			elseif releaseMode then
				--[[
					TWO TAPS, NOT ONE.  2026-09-09

					An armed mode destroying a pet on a single tap is how a player
					lost a Mythic: the mode had been armed long before, nothing on
					screen was asking a question, and the tap meant to put the pet
					back on binned it. The first tap now turns the tile INTO the
					question and only the second one answers it.

					AND THE EQUIPPED REFUSAL SAYS SO OUT LOUD. It used to fall off
					the end of the `if` and do nothing whatever, which reads as a
					dead button -- and a player's fix for a dead button is to take
					the pet off, which is exactly what hands that tile to the X.
				]]
				if s.locked then
					say("That pet is locked. Tap the padlock button, then the pet, to unlock it.")
				elseif s.equipped then
					say("Take it off first.")
				elseif wasArmed and wasArmed.i == i and wasArmed.petId == petId then
					askRelease(petId)
				else
					armed = { i = i, petId = petId }
					redress(i)
					say("Tap it again to release it.")
				end
			elseif fuseMode then
				--[[
					THE SAME TWO TAPS RELEASE USES, and for the same reason: this
					spends five pets and there is no undo. The refusals are checked
					here so the player is told WHY rather than meeting a dead tile --
					the lesson in the release branch above -- but none of them is the
					security. PetServer.fuse re-tests every one of them, because this
					panel is a drawing of a snapshot.

					COUNTED OFF state.owned, NOT OFF THE TILE. A tile is ONE COPY --
					the ledger is expanded so n copies become n entries -- so the tile
					under the finger knows nothing about how many others there are.
					state.owned is the same petId -> count map the server sent, and the
					worn copies are counted out of state.equipped the way PetServer.fuse
					counts them out of d.equipped.
				]]
				local need = PetConfig.FuseCount
				local def = PetConfig.get(petId)
				local worn = 0
				for _, id in state.equipped do
					if id == petId then
						worn += 1
					end
				end
				local spare = (state.owned[petId] or 0) - worn
				if s.locked then
					say("That pet is locked. Tap the padlock button, then the pet, to unlock it.")
				elseif def and not PetConfig.nextTier(def.Tier) then
					say((def.DisplayName or "That pet") .. " is already as high as fusing goes.")
				elseif spare < need then
					say(("Fusing takes %d spare \226\128\148 you have %d."):format(need, math.max(0, spare)))
				elseif wasArmed and wasArmed.i == i and wasArmed.petId == petId then
					send({ action = "fuse", petId = petId })
				else
					armed = { i = i, petId = petId }
					redress(i)
					say(("Tap it again to fuse %d into one of the next tier."):format(need))
				end
			else
				send({ petId = petId, equip = not s.equipped })
			end
		end)

		return e
	end

	-- Point cell i at a pet. Everything a rebuild can change lives here;
	-- everything above is built once and never touched again.
	local function dressCell(i: number, petId: string, known: boolean,
			equipped: boolean, locked: boolean)
		--[[
			WHAT THE TILE WILL WEAR, WORKED OUT BEFORE ANYTHING IS WRITTEN, so a
			cell already saying exactly this can be left alone.

			The comparison earns its keep. Releasing one pet out of 250 shifts
			every index after it along by one, but a full bag is mostly adjacent
			COPIES OF THE SAME SPECIES at the same luck, so nearly every shifted
			index still wants the tile it already has. Measured over a release at
			the cap this turns a 250-cell redraw into a handful: 26ms of frame
			down to 3.

			`kind` is part of the comparison rather than checked further down,
			because arming release mode changes nothing about a pet and everything
			about what its tile says.
		]]
		local kind = nil
		if view == "Collection" then
			if locked then
				kind = "lock"
			elseif armed and armed.i == i and armed.petId == petId then
				-- ARMED OUTRANKS THE X, so the one tile whose next tap is final
				-- is the one tile that does not look like all the others. A mode
				-- that draws the same badge on two hundred tiles is a mode that
				-- has told the player nothing.  2026-09-09
				kind = "armed"
			elseif releaseMode and not equipped then
				kind = "x"
			end
		end

		local was = cells[i] and shown[i]
		if was and was.petId == petId and was.known == known
			and was.equipped == equipped and was.locked == locked
			and was.kind == kind then
			return
		end

		local e = cells[i] or buildCell(i)
		local def = PetConfig.get(petId)
		local info = PetConfig.tierInfo(def.Tier)

		e.cell.Name = petId
		e.cell.LayoutOrder = i

		e.card.BackgroundColor3 = known and info.color:Lerp(CREAM, 0.72)
			or darken(CREAM, 0.14)
		if e.stroke and e.stroke:IsA("UIStroke") then
			e.stroke.Thickness = equipped and 4 or 3
			e.stroke.Color = equipped and C.limeDark or RULE
		end

		e.ph.Text = known and def.DisplayName or "? ? ?"
		e.ph.TextColor3 = known and darken(info.color, 0.5) or darken(CREAM, 0.5)

		e.band.BackgroundColor3 = known and info.color or darken(CREAM, 0.3)
		e.bandLbl.Text = known and string.upper(def.Tier) or "???"

		e.disc.Visible = equipped
		e.cap.Text = known and PetConfig.luckText(def.Luck) or "???"

		--[[
			WHAT A TAP WILL DO, DRAWN BEFORE THE TAP.

			A locked tile wears the padlock INSTEAD of the X, and it wears it in
			every mode rather than only in release mode: the badge is what tells a
			player which of their pets are safe without having to arm the mode that
			could destroy them. So the one pet the mode cannot delete never shows
			the badge that says it can.

			Rebuilt only when the KIND changes, so a tile that keeps its padlock
			across a rebuild is not a padlock destroyed and built again.
		]]
		if kind ~= e.markKind then
			if e.mark then
				e.mark:Destroy()
			end
			e.mark, e.markKind = nil, kind
			if kind == "lock" then
				local lock = padlock(e.card, 22, C.sun, 6)
				lock.AnchorPoint = Vector2.new(0, 0)
				lock.Position = UDim2.fromOffset(6, 6)
				e.mark = lock
			elseif kind == "x" then
				local x = text(e.card, "X", 16, Enum.Font.LuckiestGuy, C.white)
				x.AnchorPoint = Vector2.new(0, 0)
				x.Position = UDim2.fromOffset(5, 5)
				x.Size = UDim2.fromOffset(24, 24)
				x.BackgroundColor3 = C.coralDark
				x.BackgroundTransparency = 0
				x.ZIndex = 6
				corner(x, 7)
				e.mark = x
			elseif kind == "armed" then
				-- ACROSS THE MIDDLE OF THE TILE, not a corner badge: this is a
				-- question, and a question the player can miss is worth nothing.
				-- It covers the model on purpose -- the tile stops being a pet and
				-- becomes a button for as long as it is armed.  2026-09-09
				local ask = text(e.card, "RELEASE?", 13, Enum.Font.LuckiestGuy, C.white)
				ask.AnchorPoint = Vector2.new(0.5, 0.5)
				ask.Position = UDim2.fromScale(0.5, 0.5)
				ask.Size = UDim2.fromOffset(92, 26)
				ask.BackgroundColor3 = C.coralDark
				ask.BackgroundTransparency = 0
				ask.ZIndex = 6
				corner(ask, 8)
				e.mark = ask
			end
		end

		shown[i] = { petId = petId, known = known, equipped = equipped,
			locked = locked, kind = kind }

		--[[
			THE MODEL ALREADY STANDING IN THIS CELL, RE-POINTED RATHER THAN
			PARKED. A reused cell keeps its viewport, and a viewport showing the
			pet that USED to be at this index is worse than no viewport at all --
			so it is told what it is now, in the same pass. Parking it instead
			would re-letter the whole visible grid for a frame after every
			release, which is the flicker this rewrite is meant to remove.
		]]
		local artId = known and petId or nil
		local slot = slots[i]
		if slot then
			slot.petId = artId
		else
			slot = { host = e.host, ph = e.ph, petId = artId }
			slots[i] = slot
		end
		if live[i] then
			if artId then
				showPet(live[i], artId)
				e.ph.Visible = false
			else
				release(i)
			end
		else
			e.ph.Visible = true
		end
	end

	-- Redraw one cell from the snapshot it is already wearing. `shown[i]` holds
	-- exactly dressCell's arguments, so arming a tile costs that one tile and
	-- nothing else -- which is the whole reason arming does not call rebuild.
	-- See the note over `armed`.  2026-09-09
	function redress(i: number)
		local s = shown[i]
		if s then
			dressCell(i, s.petId, s.known, s.equipped, s.locked)
		end
	end

	-- The only place a cell is ever destroyed: the list genuinely got shorter.
	-- The viewport goes back to the park FIRST, or the pool bleeds a scene every
	-- time a collection shrinks.
	local function trimCells(n: number)
		for i = #cells, n + 1, -1 do
			release(i)
			cells[i].cell:Destroy()
			cells[i] = nil
			shown[i] = nil
			slots[i] = nil
		end
	end

	------------------------------------------------------------------
	-- REBUILD
	------------------------------------------------------------------
	--[[
		WHERE THE PLAYER WAS IN THE LIST, KEPT ACROSS A REBUILD.

		THE HISTORY, because this used to be load-bearing and now is not.

		Reported from the game on 2026-09-09 as "when the pet count maxes at 250
		you can't scroll up or down any more". It was never the ScrollingFrame:
		ScrollingEnabled is true and setting CanvasPosition by hand works. What
		happened was that rebuild() destroyed all 250 cells and built them again,
		and while the scroll was momentarily empty AutomaticCanvasSize collapsed
		the canvas to the window height, which CLAMPED CanvasPosition to zero.
		The canvas came back a frame later; the position did not. So every pet
		action threw the player back to the top of the list.

		THE CELLS ARE NO LONGER DESTROYED -- see the note over `cells` -- so the
		canvas never collapses and this can no longer be the thing that moves the
		position. It stays as the belt to that pair of braces, and because a list
		that SHRANK is still clamped by the engine, which is a real case: release
		the pet you are looking at off the bottom of a full bag and the canvas
		loses a row underneath you.

		WRITTEN A FRAME LATE, because AutomaticCanvasSize is recomputed by the
		layout after the pass, not during it. It waits for a canvas tall enough
		to hold a scroll and then writes -- and gives up rather than looping if
		the list genuinely got shorter than the window.

		NOT KEPT WHEN THE LIST IS A DIFFERENT LIST. Switching Collection/Index or
		typing in the search box passes false: those change WHAT is on screen, and
		holding a scroll offset from the previous list would drop the player into
		the middle of results they have not seen. Everything else -- a snapshot
		arriving, a release, a lock, arming a mode -- keeps the place.
	]]
	local function restoreScroll(y: number)
		if y <= 0 then
			return
		end
		task.defer(function()
			for _ = 1, 4 do
				local room = scroll.AbsoluteCanvasSize.Y - scroll.AbsoluteWindowSize.Y
				if room > 0 then
					scroll.CanvasPosition = Vector2.new(0, math.min(y, room))
					return
				end
				RunService.Heartbeat:Wait()
			end
		end)
	end

	function rebuild(keepScroll)
		--[[
			A REBUILD DISARMS.  2026-09-09

			Every caller is a change to what the grid is showing -- a snapshot, a
			mode, a search, an open -- and an armed tile is a promise about "the
			pet at index i" that the next sort does not keep. Clearing it in the
			one place they all pass through means no caller has to remember to.
		]]
		armed = nil

		-- `~= false` so the ordinary no-argument call from apply(), the toolbar
		-- and panels.Pets.refresh all keep the place; only an explicit false
		-- resets.
		local keepY = (keepScroll ~= false) and scroll.CanvasPosition.Y or 0

		-- How many cells this pass ended up using. Everything past it is trimmed
		-- at the bottom; NOTHING is torn down before the pass, which is the whole
		-- point -- see the note over `cells`.
		local drawn = 0

		-- The toolbar reflects what it is about to draw.
		local function lit(btn, on, colour)
			btn.BackgroundColor3 = on and colour or CREAM
			local st = btn:FindFirstChildWhichIsA("UIStroke")
			if st then
				st.Color = on and darken(colour, 0.35) or RULE
			end
		end
		-- The filter line is not in the snapshot -- see paintFilterNote. This is the
		-- call that makes opening the panel enough to see the truth.
		paintFilterNote()
		lit(trashBtn, releaseMode, C.coral)
		lit(fuseBtn, fuseMode, C.sea)
		lit(viewBtn, view == "Index", C.grape)
		lit(skinsBtn, view == "Skins", C.sea)

		--[[
			THE WARDROBE TAKES THE TRAY, AND EVERYTHING BELOW IS SKIPPED.

			The two sheets are siblings in the same tray and exactly one is visible.
			Returning here rather than falling through is the point: everything past
			this line sorts pets, dresses cells and re-solves the viewport window,
			and none of it has anything to do with a palette. It also means the pet
			grid keeps its scroll position while the player is off looking at skins,
			which is what they will expect coming back to a bag of 250.

			The viewports are NOT parked on the way out. They are children of cells
			inside a frame whose Visible just went false, so they render nothing and
			cost nothing while the wardrobe is up; releasing them would only buy a
			rebuild of the window on every return.
		]]
		skinSheet.Visible = (view == "Skins")
		scroll.Visible = (view ~= "Skins")

		--[[
			AND EVERY PET CONTROL GOES WITH THE PET GRID.

			The first cut left them up and the wardrobe read as a half-finished
			panel: "250 PETS" over a sheet of rakes, a TRADE key that trades none of
			them, EQUIP BEST, TAKE OFF, a luck meter and a search box that filters a
			list nobody is looking at. None of them are wrong, exactly -- they are
			about something that is not on the screen, which is worse.

			The TOOL KEYS stay, because one of them is how you get back.
		]]
		local petChrome = (view ~= "Skins")
		countLbl.Visible = petChrome
		statRow.Visible = petChrome
		luckStrip.Visible = petChrome
		offHolder.Visible = petChrome
		searchBox.Visible = petChrome
		-- THE EMPTY-STATE TOO, and it is the one that actually showed. It is a
		-- child of the TRAY rather than of the grid -- it has to be, it is what
		-- stands in for the grid -- so hiding the grid left "No pets yet" and
		-- "Hatch one at any egg station" printed across a sheet of rakes for any
		-- player who has no pets. Which is exactly the new player this whole
		-- ladder is for.
		if not petChrome then
			emptyMsg.Visible = false
			emptyHint.Visible = false
		end
		if view == "Skins" then
			title.Text = "Your Skins!"
			paintSkins()
			if keepScroll == false then
				skinSheet.CanvasPosition = Vector2.new()
			end
			return
		end
		-- Back to what it has always said. The Index view deliberately keeps this
		-- title too -- that was true before the wardrobe and is not this change's
		-- to revisit.
		title.Text = "Your Pets!"
		-- LIT WHEN THE MODE IS ARMED, which it never was: this read a literal
		-- `false` while the button was a message rather than a mode.
		lit(lockBtn, lockMode, C.sun)

		local function matches(def)
			if filter == "" then
				return true
			end
			return string.find(string.lower(def.DisplayName), filter, 1, true) ~= nil
				or string.find(string.lower(def.Tier), filter, 1, true) ~= nil
		end

		if view == "Collection" then
			--[[
				ONE TILE PER PET, NOT PER SPECIES.

				`owned` is petId -> count, and the grid used to draw one tile
				for each KEY with an "x6" badge in the corner. So a player who
				opened a ten-pull and came away with eleven pets across three
				species saw three tiles under a header reading "11 Pets", and
				had no way to tell a display rule from a lost save. The
				reference is unambiguous about this: six pets, six tiles, three
				of them the same animal at different values.

				So the ledger is EXPANDED here -- n copies become n entries --
				and the first `worn` of each species carry the tick, because
				which physical copy is equipped is not a thing the server
				tracks and not a thing the player can mean.
			]]
			local copies = {}
			for petId, n in state.owned do
				local def = PetConfig.get(petId)
				if def and n > 0 and matches(def) then
					local worn = 0
					for _, id in state.equipped do
						if id == petId then
							worn += 1
						end
					end
					for i = 1, n do
						table.insert(copies, { petId = petId, def = def, equipped = i <= worn })
					end
				end
			end
			table.sort(copies, function(x, y)
				if x.equipped ~= y.equipped then
					return x.equipped
				end
				if x.def.Luck ~= y.def.Luck then
					return x.def.Luck > y.def.Luck
				end
				return x.def.PetId < y.def.PetId
			end)

			for i, copy in copies do
				dressCell(i, copy.petId, true, copy.equipped,
					state.locked[copy.petId] == true)
			end
			drawn = #copies

			local none = (#copies == 0)
			emptyMsg.Visible = none
			emptyHint.Visible = none and filter == ""
			-- Pets on the shelf and nothing worn. See the note where it is built.
			-- `#copies` rather than ownedCount, so a search that hides everything
			-- does not leave the line pointing at tiles that are not there.
			equipHint.Visible = (#copies > 0) and (#state.equipped == 0)
			if none and filter ~= "" then
				emptyMsg.Text = "Nothing matches that"
			else
				emptyMsg.Text = "No pets yet"
			end
		else
			emptyMsg.Visible = false
			emptyHint.Visible = false
			-- The Index view lists every species whether owned or not, so there is
			-- nothing here to equip and nothing to say about equipping.
			equipHint.Visible = false
			local i = 0
			for _, petId in PetConfig.Order do
				local def = PetConfig.get(petId)
				if def and matches(def) then
					i += 1
					dressCell(i, petId, state.discovered[petId] == true, false,
						state.locked[petId] == true)
				end
			end
			drawn = i
			emptyMsg.Visible = (i == 0)
			emptyMsg.Text = "Nothing matches that"
		end

		-- Only now, and only what the shorter list left over.
		trimCells(drawn)

		--[[
			Put the player back where they were -- or, for a DIFFERENT list, at the
			top of it.

			THE RESET IS SAID OUT LOUD NOW. It used to happen by accident: the
			tear-down collapsed the canvas, the engine clamped CanvasPosition to
			zero, and `rebuild(false)` simply declined to put it back. Nothing is
			torn down any more, so a switch to the Index from row thirty of a full
			collection landed thirty rows into a sixty-three-tile catalogue.

			Either way it happens BEFORE the models are filled in: window() reads
			CanvasPosition to decide which rows deserve a viewport, so standing
			them up first would stand up the wrong ones and immediately park them
			again.
		]]
		if keepScroll == false then
			scroll.CanvasPosition = Vector2.new()
		else
			restoreScroll(keepY)
		end

		-- The grid exists; the models follow on the next frame, once the layout
		-- has told the scroll how wide it ended up and therefore how many
		-- columns the arithmetic above is working in.
		schedule()
	end

	------------------------------------------------------------------
	-- TOOLBAR WIRING  (after rebuild exists)
	------------------------------------------------------------------
	-- ARMING ONE MODE DISARMS THE OTHER. See the note over `lockMode`: "delete"
	-- and "protect from deletion" being live at the same time is the ambiguity
	-- that makes a destructive tap a surprise.
	TouchFit.activated(trashBtn, function()
		releaseMode = not releaseMode
		if releaseMode then
			lockMode = false
			fuseMode = false
		end
		rebuild()
	end)

	-- THE THIRD MODE JOINS THE SAME RULE. Fuse and release both end with a pet
	-- gone, and two of those live at once is the ambiguity the note above names.
	TouchFit.activated(fuseBtn, function()
		fuseMode = not fuseMode
		if fuseMode then
			releaseMode = false
			lockMode = false
		end
		rebuild()
		say(fuseMode
			and ("Tap a pet you have " .. PetConfig.FuseCount
				.. " spare of to fuse it up a tier.")
			or "Fusing off.")
	end)
	TouchFit.activated(viewBtn, function()
		view = (view == "Collection") and "Index" or "Collection"
		-- A different list: start at the top. See restoreScroll.
		rebuild(false)
	end)
	--[[
		THE WARDROBE KEY, AND IT TOGGLES AGAINST COLLECTION RATHER THAN CYCLING.

		There are three views and two keys, which is the right way round: INDEX and
		SKINS each turn their own view on, and pressing either again drops back to
		the collection. A single key cycling Collection -> Index -> Skins would make
		the player press it twice to get somewhere and give the button no state to
		light, which is what `lit` exists for.
	]]
	TouchFit.activated(skinsBtn, function()
		view = (view == "Skins") and "Collection" or "Skins"
		rebuild(false)
	end)
	--[[
		IT IS A MODE NOW, AND IT WAS A LEAFLET.

		This button used to print "equipped pets cannot be released" and do
		nothing else -- a lock icon that described somebody else's rule rather
		than giving the player one of their own. The rule it described was also
		the only protection release mode had, and it is exactly the protection
		that evaporates the moment a pet is taken OFF: that is how a player lost a
		Mythic on 2026-09-09, and it is why this is a real switch now.

		Armed, a tap on any tile locks or unlocks that pet. The line along the
		foot says which, because a toolbar button that has silently changed what
		every tile does needs to announce itself once.
	]]
	TouchFit.activated(lockBtn, function()
		lockMode = not lockMode
		if lockMode then
			releaseMode = false
		end
		rebuild()
		say(lockMode
			and "Tap a pet to lock or unlock it. Locked pets cannot be released or traded."
			or "Done locking.")
	end)
	-- Opens a card rather than doing anything, which is the point: the sweep is
	-- irreversible and the card is where its size is said out loud first.
	TouchFit.activated(tidyBtn, openTidy)

	------------------------------------------------------------------
	-- APPLY A SNAPSHOT
	------------------------------------------------------------------
	local function apply(snap)
		state.owned = snap.owned or {}
		state.equipped = snap.equipped or {}
		state.discovered = snap.discovered or {}
		-- `or {}` for the same reason every other field here has one: a snapshot
		-- from a server that predates locks has no such field, and an indexing
		-- read of nil in the tile loop would take the whole rebuild down.
		state.locked = snap.locked or {}
		state.luck = snap.luck or 1
		state.ownedCount = snap.ownedCount or 0
		state.maxEquipped = snap.maxEquipped or PetConfig.MaxEquipped
		state.maxOwned = snap.maxOwned or PetConfig.MaxOwned

		-- The clover beside this label is an ImageLabel, not a character in the
		-- string. Anything typed in here is a glyph again, and a glyph is what
		-- broke twice -- see the note at the top of the file.
		luckText.Text = PetConfig.luckText(state.luck) .. " LUCK"

		local full = state.ownedCount >= state.maxOwned
		capText.Text = string.format("%d / %d", state.ownedCount, state.maxOwned)
		capText.TextColor3 = full and C.coralDark or C.ink

		eqText.Text = string.format("%d / %d EQUIPPED", #state.equipped, state.maxEquipped)

		countLbl.Text = string.format("%d Pets", state.ownedCount or 0)
		paintFilterNote()

		if root.Visible then
			rebuild()
		end
	end

	Net.get("PetSync").OnClientEvent:Connect(function(snap)
		if type(snap) == "table" then
			apply(snap)
		end
	end)

	--[[
		THE WARDROBE HAS NO SYNC OF ITS OWN, AND DOES NOT NEED ONE.

		SkinService publishes by writing `SkinChosen` and one `SkinOwn_<key>` per
		skin onto the Player, which is the same seam SkinClient reads to draw the
		tool -- so the attributes ARE the sync and a remote here would be a second
		copy of the same truth.

		Repainted rather than rebuilt, and only while the sheet is actually up: a
		skin claimed from the Rewards panel fires these while the wardrobe is shut,
		and paintSkins builds tiles on demand, so the work would be wasted and the
		first open would do it again anyway.

		One connection per skin is nine connections made once. GetAttributeChanged
		Signal has no wildcard, and AttributeChanged fires for every attribute on
		the player -- of which this game writes a great many.
	]]
	do
		local me = Players.LocalPlayer
		local function repaint()
			if skinSheet.Visible then
				paintSkins()
			end
		end
		me:GetAttributeChangedSignal(SkinConfig.ChosenAttribute):Connect(repaint)
		-- AND THE ACTIVE ONE, which this block used to leave out. It is the
		-- attribute that moves when a player walks through a room's door, so
		-- without it the sheet kept whatever it painted on the way in.
		me:GetAttributeChangedSignal(SkinConfig.ActiveAttribute):Connect(repaint)
		for _, skin in ipairs(SkinConfig.Skins) do
			me:GetAttributeChangedSignal(SkinConfig.OwnPrefix .. skin.key):Connect(repaint)
		end
	end

	------------------------------------------------------------------
	-- WHAT MOVES THE POOL
	------------------------------------------------------------------
	-- CanvasPosition is the scroll itself. AbsoluteSize is the pop-in tween on
	-- open, which changes the column count and the height of the band under the
	-- pool's feet while it runs. Visible is the open and close.
	scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(schedule)
	scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(schedule)
	root:GetPropertyChangedSignal("Visible"):Connect(schedule)

	-- Fill the art cache off the critical path. It is ~3ms for all 61 and it
	-- would happen on the first open regardless; doing it here means the first
	-- open is as cheap as every one after it.
	task.defer(prepareAll, PetConfig)

	panels.Pets.refresh = rebuild
	--[[
		RELEASE MODE DOES NOT SURVIVE A CLOSE.  2026-09-09

		It is a plain local that nothing ever reset, so a player who armed it to
		bin one Common, then closed the panel and came back later, found every
		tile still wearing the X and the next tap already meaning destroy. That
		is one half of the lost-Mythic report; the two-tap arming on the tile is
		the other.

		onOpen RATHER THAN refresh: MenuHud calls refresh on every repaint, and
		disarming the mode under a player who is halfway through clearing a full
		bag would be its own bug. See the note beside MenuHud's onOpen call for
		why the two hooks are deliberately not the same hook.

		Guarded, because onOpen runs just after MenuHud has already called
		refresh: the ordinary open, with the mode already off, must not pay for a
		second rebuild on top of that one. rebuild() clears `armed` itself.
	]]
	panels.Pets.onOpen = function()
		if releaseMode or fuseMode or armed then
			releaseMode = false
			fuseMode = false
			rebuild()
		end
	end
	rebuild()
	return panels.Pets
end

return PetsPanel