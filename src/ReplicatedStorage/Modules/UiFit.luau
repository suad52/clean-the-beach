--[[
	UiFit  --  ReplicatedStorage.Modules.UiFit  (client)

	Makes the HUDs fit a screen that is not a desktop window.

	THE PROBLEM
	-----------
	Every GUI in this game is built in code out of UDim2.fromOffset -- pixels.
	That is fine on the window they were authored against and wrong everywhere
	else, because a pixel is a much larger share of a phone. The rail is the
	clearest case: five 92px keys plus padding come to 527px tall, and a phone in
	landscape has around 414px of screen. It did not merely look big, it did not
	fit at all -- the top and bottom keys ran off the screen.

	HOW IT WORKS
	------------
	One UIScale per ScreenGui, on a full-screen "FitRoot" frame that every
	pixel-sized top-level child is moved into. Scaling the children individually
	would not work: several already carry their own UIScale, animated by their
	owning script (the wash card's pop, the coin pill's pulse, the rail icon's
	bob), and an object only honours one. Nesting them under a scaled parent
	multiplies instead of fighting, so those animations keep working untouched.

	THE 1/scale ON FITROOT IS NOT A TYPO
	------------------------------------
	A UIScale scales the object it sits on as well as everything under it. A
	FitRoot sized fromScale(1, 1) would therefore shrink to 60% of the screen,
	and every child positioned in SCALE against it -- the rail sits at
	Position(1, -20, 0.5, 0), hard right -- would anchor to 60% across and drift
	inward. Sizing it 1/scale first cancels that exactly: 1/s * s == 1, so the
	frame still measures the full viewport while its contents come out scaled.

	WHAT IT DELIBERATELY DOES NOT TOUCH
	-----------------------------------
	Anything with a Scale component in its Size is already responsive, and
	scaling it again is actively wrong -- a full-screen backdrop at 0.6 stops
	covering the screen and leaves a border of live game around a modal. So the
	test for "is this mine to scale" is that BOTH size axes are pure offset. That
	leaves the vault's letterbox bars, the reveal flash, the index detail sheet
	and the ATV panel's click-off backdrop exactly as they were.
]]

local Players = game:GetService("Players")

local UiFit = {}

-- The window the HUDs were authored against.
local BASE = Vector2.new(1280, 720)

-- Floor and ceiling. The ceiling is 1 because the desktop look is the intended
-- one and there is no reason to inflate it on a big monitor. The floor is where
-- 44px touch targets start to be at risk: the rail's 92px key at 0.6 is 55px,
-- which is still comfortably tappable, and below about 0.55 it is not.
local MIN_SCALE, MAX_SCALE = 0.6, 1.0

--[[
	THE PLAYER'S OWN SAY, on top of the fit above.

	The fit answers "will this LAND ON the screen", which is a different question
	from "is this the size I want it". A 4K desktop clamps to MAX_SCALE and gets
	the authored 1280x720 pixel sizes on a screen three times that wide, which
	fits perfectly and is tiny; a phone player may happily trade some screen for
	something they can actually hit. Neither is a bug in the fit, and neither can
	be guessed from the viewport -- so it is a setting (MenuHud's Settings panel).

	A MULTIPLIER, NOT AN OVERRIDE, which is what lets one preference be right on
	both of a player's devices: it rides on top of whatever the fit worked out
	rather than replacing it, so "a bit bigger than normal" means the same thing
	on a phone and on a monitor.

	THE ABSOLUTE BOUNDS ARE WIDER THAN THE FIT'S, and they have to be or the
	setting would do nothing where it is most wanted: MAX_SCALE is 1.0 because
	there is no reason to INFER that a big monitor wants big UI, but a player
	asking for it is exactly the reason that note was missing.

	1.35 IS NOT ARBITRARY. The rail is the tallest thing in the game at 527px
	authored; at the phone floor of 0.6 the largest step (x1.3) comes out at 0.78,
	which is 411px against the ~414 a phone has in landscape. So even the biggest
	setting on the smallest screen still fits -- barely, and deliberately: past
	this the top and bottom keys start running off, which is the exact failure
	this whole module exists to fix.
]]
local ABS_MIN, ABS_MAX = 0.5, 1.35

--[[
	The steps the settings panel offers, in order. Named here rather than in the
	panel so there is one list: the panel draws `label` and this file does the
	arithmetic, and neither can drift from the other.

	FOUR, NOT A SLIDER. A slider is a drag, and a drag on a phone inside a panel
	that can itself be scrolled is a fight over the same gesture -- see TouchFit's
	notes on how little room these controls have. Four taps cover the range that
	matters and every one of them is a 44px target.
]]
UiFit.STEPS = {
	{ key = "S", label = "SMALL", mult = 0.85 },
	{ key = "M", label = "NORMAL", mult = 1.00 },
	{ key = "L", label = "LARGE", mult = 1.15 },
	{ key = "XL", label = "HUGE", mult = 1.30 },
}
UiFit.DEFAULT_STEP = "M"

-- Under this, small type stops being readable at any size the layout can
-- afford, so HUDs with a compact mode switch into it rather than shrinking text
-- nobody can read. See MenuHud's rail captions.
UiFit.COMPACT_BELOW = 0.82

local scale = 1
local userMult = 1
local lastViewport = nil
local roots = {}       -- [ScreenGui] = FitRoot
local listeners = {}

function UiFit.scaleFor(v: Vector2): number
	if v.X <= 0 or v.Y <= 0 then
		return 1
	end
	return math.clamp(math.min(v.X / BASE.X, v.Y / BASE.Y), MIN_SCALE, MAX_SCALE)
end

function UiFit.get(): number
	return scale
end

function UiFit.userScale(): number
	return userMult
end

function UiFit.stepFor(key: string?)
	for _, s in ipairs(UiFit.STEPS) do
		if s.key == key then
			return s
		end
	end
	return UiFit.stepFor(UiFit.DEFAULT_STEP)
end

--[[
	Set the player's preference and re-fit everything on the spot.

	TAKES THE MULTIPLIER, NOT THE FINAL SCALE, so the fit stays in charge of the
	viewport and this stays in charge of taste -- and a player who then rotates
	their phone gets both applied rather than their preference overwriting the
	measurement.

	It goes through `refresh`, which is the one place that writes `scale`, moves
	every FitRoot and calls the listeners. So a scale change from the settings
	panel is indistinguishable from a window resize, and everything that already
	handles one -- MenuHud's caption rail, EventHud's refit -- handles this for
	free.
]]
function UiFit.setUserScale(mult: number)
	local m = tonumber(mult)
	if not m or m ~= m or m <= 0 then
		return
	end
	if math.abs(m - userMult) < 0.001 then
		return
	end
	userMult = m
	UiFit.refresh(lastViewport or workspace.CurrentCamera.ViewportSize)
end

function UiFit.compact(): boolean
	return scale < UiFit.COMPACT_BELOW
end

-- Called immediately with the current value as well as on every change, so a
-- caller never has to handle "not measured yet" separately.
function UiFit.onChanged(fn: (number) -> ())
	table.insert(listeners, fn)
	local ok, err = pcall(fn, scale)
	if not ok then
		warn("[UiFit] listener errored on first call: " .. tostring(err))
	end
end

--------------------------------------------------------------------------
-- WRAPPING
--------------------------------------------------------------------------

local function eligible(c: Instance): boolean
	if not c:IsA("GuiObject") or c.Name == "FitRoot" then
		return false
	end
	-- Pure offset on both axes. See the note at the top.
	return c.Size.X.Scale == 0 and c.Size.Y.Scale == 0
end

local function applyTo(root: Frame)
	local s = root:FindFirstChildOfClass("UIScale")
	if s then
		s.Scale = scale
	end
	root.Size = UDim2.fromScale(1 / scale, 1 / scale)
end

local function rootFor(gui: ScreenGui): Frame
	local root = roots[gui]
	if root and root.Parent == gui then
		return root
	end
	root = Instance.new("Frame")
	root.Name = "FitRoot"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	-- Off every spatial query the UI does; it is a container, not a surface.
	root.Active = false
	root.ZIndex = 1
	local s = Instance.new("UIScale")
	s.Parent = root
	root.Parent = gui
	roots[gui] = root
	applyTo(root)
	return root
end

local function absorb(gui: ScreenGui)
	local pending = {}
	for _, c in ipairs(gui:GetChildren()) do
		if eligible(c) then
			table.insert(pending, c)
		end
	end
	if #pending == 0 then
		return
	end

	local root = rootFor(gui)
	-- Under Sibling ZIndexBehavior the container's own ZIndex decides where its
	-- whole subtree sits against the children left outside it, so it has to take
	-- the highest of what it swallowed or a panel can fall behind its backdrop.
	local top = root.ZIndex
	for _, c in ipairs(pending) do
		top = math.max(top, c.ZIndex)
		c.Parent = root
	end
	root.ZIndex = top
end

--------------------------------------------------------------------------
-- PANELS THAT ARE TALLER THAN THE SCREEN  --  NOT HERE ANY MORE
--------------------------------------------------------------------------
--[[
	clampPanel IS GONE, AND IT NEVER WORKED.  Removed 2026-09-18.

	From 2026-09-12 this file carried a second, per-panel UIScale named
	`UiFitClamp`, written by `UiFit.clampPanel(obj, w, h)` and called from
	MenuHud's makePanel and AtvClient. It answered a real report -- "The ui is
	off the screen", from a 750x390 phone, where the Ferry board, Pets & Skins
	and the Car Spawner all hung off the top AND bottom -- and it answered it
	with an extra squeeze on any panel too big for its canvas.

	IT HAD NO EFFECT ON ANY PANEL, EVER. Roblox honours ONE UIScale per
	GuiObject -- the FIRST child -- and they do not compound. Every panel
	clampPanel was called on is a PanelKit.card, and card() builds its own
	`SafeFit` UIScale before it returns, so the UiFitClamp written afterwards
	arrived second and was ignored. Proved in Play rather than argued: setting
	UiFitClamp to 0.10 on the open Pets card moved its AbsoluteSize not at all
	(190.3 x 151.3 before and after), while halving SafeFit halved it exactly.
	All 18 cards tagged CTB_Panel were SafeFit-first, so that was every caller.

	It was also wrong on its own terms, which is how it survived being read: it
	divided the FitRoot's AbsoluteSize -- SCREEN pixels -- by the caller's
	authored w and h, which are DESIGN units. That is a uniform factor of `scale`
	too small. Nobody saw it because nothing it wrote was ever applied.

	PanelKit.fitToSafeArea DOES THE JOB AND DOES IT BETTER. It solves the two
	halves of the card separately, knows the banner hangs over the top edge, and
	centres the card in the safe area rather than in the window. Anything that
	needs a panel fitted to the screen belongs there, not here -- and a second
	mechanism in this file would be a second UIScale fighting for the same slot,
	which is the whole reason this one did nothing.
]]

function UiFit.fit(gui: ScreenGui)
	if not gui:IsA("ScreenGui") then
		return
	end
	absorb(gui)
	-- HUDs build over several frames and some rebuild panels on demand, so new
	-- top-level children have to be caught as they arrive rather than once.
	gui.ChildAdded:Connect(function()
		task.defer(absorb, gui)
	end)
end

--------------------------------------------------------------------------
-- MEASURING
--------------------------------------------------------------------------

function UiFit.refresh(viewport: Vector2)
	lastViewport = viewport
	-- The fit, then the player's say, then the bounds that keep the rail on the
	-- screen. `scaleFor` stays the pure measurement -- it is public and a caller
	-- asking what a viewport needs is not asking what this player prefers.
	local want = math.clamp(UiFit.scaleFor(viewport) * userMult, ABS_MIN, ABS_MAX)
	--[[
		THE EARLY RETURN BELOW IS SAFE ONLY BECAUSE PANELS NO LONGER DEPEND ON IT.

		Both of scaleFor's ratios spend most of their range pinned to MIN_SCALE or
		MAX_SCALE, so quite large viewport changes produce no scale change at all
		and this returns without notifying anybody. The clamp that used to live in
		this file had to be refreshed above the return for that reason -- a ferry
		board was caught sitting at the height it had chosen for a window two sizes
		ago.

		PanelKit's SafeFit does not come through here. It subscribes to the camera's
		ViewportSize directly as well as to onChanged, so it re-solves on a resize
		the scale slept through. If anything else is ever hung off onChanged that
		must track the VIEWPORT rather than the SCALE, it needs the same treatment.
	]]
	if math.abs(want - scale) < 0.001 then
		return
	end
	scale = want
	for gui, root in pairs(roots) do
		if root.Parent then
			applyTo(root)
		else
			roots[gui] = nil
		end
	end
	for _, fn in ipairs(listeners) do
		local ok, err = pcall(fn, scale)
		if not ok then
			warn("[UiFit] listener errored: " .. tostring(err))
		end
	end
end

local started = false
function UiFit.start()
	if started then
		return
	end
	started = true

	local camera = workspace.CurrentCamera

	--[[
		WAIT FOR A REAL MEASUREMENT FIRST.

		The camera reports a 1x1 ViewportSize for the first frames of a client's
		life, before the render pipeline has measured the window. Taken at face
		value that clamps straight to the floor, and every HUD in the game boots
		into compact mode on a desktop -- captions hidden, everything at 60%.

		The ViewportSize listener below does correct it once a change arrives, and
		in practice one does. But that is luck: the failure case is a first reading
		of 1x1 followed by no change at all, which leaves the whole UI wrong for
		the session with nothing to nudge it. Cheaper to wait for a number worth
		using than to depend on being corrected.
	--]]
	local waited = 0
	while camera.ViewportSize.Y <= 1 and waited < 5 do
		waited += task.wait()
	end

	UiFit.refresh(camera.ViewportSize)
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		UiFit.refresh(camera.ViewportSize)
	end)
	-- The camera instance itself is replaced on some respawns, and the old
	-- connection goes with it.
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local c = workspace.CurrentCamera
		if c then
			camera = c
			UiFit.refresh(c.ViewportSize)
			c:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				UiFit.refresh(c.ViewportSize)
			end)
		end
	end)

	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	for _, g in ipairs(pg:GetChildren()) do
		if g:IsA("ScreenGui") then
			UiFit.fit(g)
		end
	end
	pg.ChildAdded:Connect(function(g)
		if g:IsA("ScreenGui") then
			-- deferred so the owning script gets to populate it first
			task.defer(UiFit.fit, g)
		end
	end)
end

return UiFit
