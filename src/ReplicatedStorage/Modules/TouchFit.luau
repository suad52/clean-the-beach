--[[

	TouchFit  --  ReplicatedStorage.Modules.TouchFit


	A 44-PIXEL TOUCH TARGET UNDER A CONTROL THAT DOES NOT CHANGE SIZE.


	WHY THIS EXISTS. UiFit scales the whole HUD by
	clamp(min(vx/1280, vy/720), 0.6, 1) and EVERY phone lands on the 0.6 floor;
	anything in the left column takes HudKit's 0.86 column multiplier on top of
	that, so it renders at 0.516 of its authored size. A 46px close button is
	27.6 real pixels on a phone. Apple and Android both put the minimum at 44.
	Measured on a live 801x392 client, 51 of 64 distinct controls were under it.

	The honest fix is to redraw the compact layouts so the controls are genuinely
	bigger -- MenuHud's rail already does it right, hiding its captions instead of
	shrinking its keys. That is a pass over every panel and a visible change. This
	module is the other half: it makes the controls HITTABLE without moving a
	single pixel of art, so a mis-tap stops being the reason a player cannot open
	a panel. IT DOES NOT MAKE 6PX TEXT READABLE and is not pretending to.


	HOW. A GuiButton's clickable region IS its rect -- Roblox has no hit-slop
	property -- so the only way to widen it without widening the art is a second,
	invisible button. That button is a PAD: transparent, sized so it measures at
	least 44 REAL pixels once the scale chain is applied, centred on the control,
	and carrying a LOWER ZIndex than everything around it.

	THE LOW ZIndex IS THE WHOLE SAFETY ARGUMENT. A pad is often much larger than
	the control it serves -- at 0.516 scale a 22px close button needs an 85px pad
	-- so it WILL overlap its neighbours. Sitting underneath them, it only ever
	catches taps that would otherwise have hit nothing at all. A real control on
	top still wins its own pixels. That is what makes it safe to be generous.


	WHY THE CALLER HANDS US THE FUNCTION. There is no way to fire a GuiButton's
	Activated from a script, so a pad cannot forward a tap to the button it
	serves -- it has to be wired to the same handler. Hence `press(button, fn)`
	in place of `button.MouseButton1Click:Connect(fn)`: one substitution per call
	site, and the closing bracket is already in the right place.


	NOTHING IS DECIDED AT BUILD TIME, AND THAT IS THE POINT.

	The first version of this module asked "is this control already big enough?"
	when `press` was called and returned early if it was. That is wrong on
	exactly the devices it exists for. A panel builds itself at whatever scale is
	current, and UiFit only absorbs a ScreenGui's children into a FitRoot
	carrying the 0.6 UIScale AFTERWARDS -- so a 46px close button measures 46 at
	the moment it asks, passes, is skipped forever, and then renders at 27.6 on
	the phone. Every judgement here is therefore made from the control's LIVE
	AbsoluteSize and remade whenever that changes, which is the same signal for
	layout resolving, for UiFit arriving overhead, and for the player rotating
	the phone.


	WHERE THE PAD IS PARENTED, which is not a free choice:

	  * Normally a SIBLING of the control. Nothing clips it, and a sibling with a
	    lower ZIndex sorts below in both ZIndexBehavior modes.

	  * If the parent runs a UIListLayout or UIGridLayout, a sibling would be
	    LAID OUT -- it would take a slot in the list and shove everything after it
	    along. There the pad goes inside the control instead. That only sorts
	    correctly under ZIndexBehavior.Global, where a child may sit below its
	    parent; under Sibling a child always renders above. Every layout-managed
	    control in this game lives in BeachMenuHud, which is Global, so the case
	    is handled rather than theoretical -- and if a Sibling one ever appears,
	    the pad still works, it just eats the control's press animation, and this
	    module says so out loud rather than leaving someone to find it.

]]

local UserInputService = game:GetService("UserInputService")

local TouchFit = {}

-- The Apple HIG and Material both land on 44. REAL screen pixels, after every
-- UIScale between the control and its ScreenGui.
TouchFit.MIN = 44

-- How far a pad may outgrow the control it serves, as a multiple of that
-- control's own size. Without a ceiling a 1px control would claim a 44px pad
-- and a HUD full of those is a minefield of invisible buttons. Four carries the
-- worst real case in this game (a 22px close at 0.516 scale wants 3.87x).
local MAX_GROWTH = 4

local PAD_NAME = "TouchPad"


--[[
	Only touch devices get pads. A mouse is exact, and an invisible button
	spreading out under a desktop HUD is a way to click things you did not mean
	to click.

	Deliberately NOT `TouchEnabled and not KeyboardEnabled`: Studio's device
	emulator leaves KeyboardEnabled true, so that form of the test can never be
	exercised in Studio, and a real tablet with a keyboard paired still wants
	the pads.
]]
function TouchFit.wanted(): boolean
	return UserInputService.TouchEnabled
end


--[[
	VERIFIED, and here is how, because none of it can be checked by looking.

	Studio cannot be put into touch mode from a script and its device emulator
	cannot be driven over the bridge, so this module was proved by forcing
	`wanted` true, booting, and then dropping every FitRoot's UIScale to the 0.6
	floor a phone actually gets:

	  49 pads at scale 1.00  ->  94 at 0.60

	The 45 that appeared on the way down are the whole argument for deciding late
	rather than at build time. All 94 measured at least 44 real pixels, none hit
	the MAX_GROWTH ceiling, and every one centred on its control to within 1.5px.

	Then, panel by panel with only one ScreenGui enabled at a time (all of them
	at once is a false negative -- each panel's full-screen scrim covers its
	neighbours), a point in each pad's margin was put through
	GetGuiObjectsAtPosition: 67 reached the pad, 3 were claimed by a real control
	sitting on top, which is the design working, and 8 were rows scrolled outside
	their ScrollingFrame's viewport, where the control itself is not hittable
	either.

	THE ONE REAL LIMIT that found: a pad inside a ScrollingFrame is clipped by
	the viewport like anything else, so a control against the top or bottom edge
	of a scrolling list gets less margin than one in the middle.
]]


--[[
	The product of every UIScale between `o` and its ScreenGui.

	Needed even though AbsoluteSize already has the scale baked in, because a
	pad's Size is authored in UNSCALED offset: to render 44 pixels through a
	0.6 chain the offset has to be 44 / 0.6.
]]
local function chainScale(o: Instance): number
	local s, n = 1, o
	while n and not n:IsA("LayerCollector") do
		--[[
			ONE PER OBJECT, BECAUSE THAT IS WHAT ROBLOX APPLIES.

			A GuiObject honours a single UIScale -- the first child of that
			class -- and silently ignores any other. Multiplying all of them
			here read a panel carrying BOTH PanelKit's SafeFit and UiFit's
			UiFitClamp as 0.575 * 0.556 = 0.32 while the renderer was using
			0.575 alone, so every pad on that panel was sized against a scale
			1.8x too small and came out 1.8x too big.

			Measured on Pets at 854x345: a 140x34 WEAR button renders 48x12,
			which is 0.575 * 0.6 exactly -- SafeFit, the earlier-built child.
			At the old reading the pad wanted 44 / 0.192 = 229 unscaled, which
			is 79 real pixels on a grid whose rows are 41 apart: every pad
			overlapped its neighbour by half a row, all at the same ZIndex, so
			which one caught a tap fell to tree order. Tapping WEAR could
			equip a different skin, or land on a locked one and do nothing --
			reported from a phone as "can't equip a different skin".
		]]
		local scale = n:FindFirstChildWhichIsA("UIScale")
		if scale then
			s *= scale.Scale
		end
		n = n.Parent
	end
	return s > 0 and s or 1
end


local function hasLayout(parent: Instance): boolean
	for _, c in ipairs(parent:GetChildren()) do
		if c:IsA("UIGridStyleLayout") then
			return true
		end
	end
	return false
end


--[[
	One registration per control. `fns` rather than one function because two
	call sites may legitimately wire the same control, and both have to fire
	from the pad as well.
]]
type Entry = {
	button: GuiObject,
	fns: { { kind: string, fn: (...any) -> () } },
	pad: GuiObject?,
	warned: boolean?,
}

local entries: { [GuiObject]: Entry } = setmetatable({}, { __mode = "k" }) :: any


-- Size and centre the pad from the control's LIVE geometry. Recomputed rather
-- than remembered: a pad sized for a landscape phone is wrong in portrait.
local function fit(e: Entry)
	local button, pad = e.button, e.pad
	if not pad then
		return
	end
	local parent = button.Parent
	if not (parent and parent:IsA("GuiObject")) then
		return
	end

	local scale = chainScale(button)
	local abs = button.AbsoluteSize
	if abs.X <= 0 or abs.Y <= 0 then
		return
	end

	-- Back out of rendered pixels into the unscaled units a Size offset is in.
	local cw, ch = abs.X / scale, abs.Y / scale
	local want = TouchFit.MIN / scale
	pad.Size = UDim2.fromOffset(
		math.ceil(math.min(math.max(cw, want), cw * MAX_GROWTH)),
		math.ceil(math.min(math.max(ch, want), ch * MAX_GROWTH)))

	if pad.Parent == button then
		pad.Position = UDim2.fromScale(0.5, 0.5)
	else
		-- Sibling: sit on the control's own centre, whatever mix of scale,
		-- offset, AnchorPoint or layout put it where it is. Taken from absolute
		-- geometry rather than reconstructed from Position, because a
		-- layout-managed control's Position says nothing about where it is.
		local c = button.AbsolutePosition + button.AbsoluteSize * 0.5 - parent.AbsolutePosition
		pad.Position = UDim2.fromOffset(c.X / scale, c.Y / scale)
	end
end


local function build(e: Entry)
	local button = e.button
	local parent = button.Parent
	if not (parent and parent:IsA("GuiObject")) then
		return
	end

	local inside = hasLayout(parent)
	if inside and not e.warned then
		e.warned = true
		local screen = button:FindFirstAncestorWhichIsA("LayerCollector")
		if screen and screen:IsA("ScreenGui")
			and screen.ZIndexBehavior ~= Enum.ZIndexBehavior.Global then
			warn(("[TouchFit] %s is laid out inside a Sibling-ZIndex ScreenGui, so its "
				.. "pad sits ON it and will swallow its press animation.")
				:format(button:GetFullName()))
		end
	end

	local pad = Instance.new("TextButton")
	pad.Name = PAD_NAME
	pad.BackgroundTransparency = 1
	pad.Text = ""
	pad.AutoButtonColor = false
	pad.BorderSizePixel = 0
	pad.AnchorPoint = Vector2.new(0.5, 0.5)
	-- Below the control and below its neighbours: a pad may only ever catch a
	-- tap that was going to hit nothing at all.
	pad.ZIndex = button.ZIndex - 1
	pad.Visible = button.Visible
	pad.Parent = inside and button or parent
	e.pad = pad

	for _, h in ipairs(e.fns) do
		if h.kind == "activated" then
			(pad :: any).Activated:Connect(h.fn)
		else
			(pad :: any).MouseButton1Click:Connect(h.fn)
		end
	end

	button:GetPropertyChangedSignal("Visible"):Connect(function()
		pad.Visible = button.Visible
	end)
end


--[[
	Decide, from what the control measures RIGHT NOW, whether it needs a pad --
	and build one the first time the answer is yes. Never tears one down: a pad
	that has become unnecessary is already sized exactly to its control and
	sitting underneath it, which costs nothing.
]]
local function ensure(e: Entry)
	local button = e.button
	if not button.Parent then
		return
	end
	local abs = button.AbsoluteSize
	if abs.X <= 0 or abs.Y <= 0 then
		return    -- not laid out yet; the AbsoluteSize listener will be back
	end
	if not e.pad then
		if abs.X >= TouchFit.MIN and abs.Y >= TouchFit.MIN then
			return
		end
		build(e)
	end
	fit(e)
end


local function register(button: GuiObject, kind: string, fn: (...any) -> ())
	if not TouchFit.wanted() then
		return
	end
	local e = entries[button]
	if e then
		table.insert(e.fns, { kind = kind, fn = fn })
		if e.pad then
			if kind == "activated" then
				(e.pad :: any).Activated:Connect(fn)
			else
				(e.pad :: any).MouseButton1Click:Connect(fn)
			end
		end
		return
	end

	e = { button = button, fns = { { kind = kind, fn = fn } } }
	entries[button] = e
	button:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		ensure(e)
	end)
	-- Deferred, not immediate: a control asked about on the line after it was
	-- created has not been laid out yet and measures zero.
	task.defer(ensure, e)
end


--[[
	THE ONE CALLERS USE.

	  TouchFit.press(btn, function() ... end)

	in place of

	  btn.MouseButton1Click:Connect(function() ... end)

	Same arguments, same closing bracket, and the handler runs whether the tap
	landed on the control or in the margin around it. Returns the control's own
	connection so a caller that used to keep one still can.
]]
function TouchFit.press(button: GuiObject, fn: (...any) -> ()): RBXScriptConnection
	local conn = (button :: any).MouseButton1Click:Connect(fn)
	register(button, "press", fn)
	return conn
end


--[[
	The same substitution for a call site that used `Activated`.

	Kept as its own name rather than folding both into `press`, because the two
	signals are NOT interchangeable: Activated also fires for gamepad and
	keyboard activation of a selected button, and it hands the listener
	(inputObject, clickCount) where MouseButton1Click hands it (x, y). Rewriting
	one into the other would quietly change what a handler receives.
]]
function TouchFit.activated(button: GuiObject, fn: (...any) -> ()): RBXScriptConnection
	local conn = (button :: any).Activated:Connect(fn)
	register(button, "activated", fn)
	return conn
end


-- The same thing for a control already wired up elsewhere: give it a pad and
-- point the pad at `fn`, without adding a second connection to the control.
function TouchFit.also(button: GuiObject, fn: (...any) -> ())
	register(button, "press", fn)
end


-- What is actually padded, for a console that wants to check rather than trust.
function TouchFit.report(): (number, number)
	local n, padded = 0, 0
	for _, e in pairs(entries :: any) do
		n += 1
		if e.pad then
			padded += 1
		end
	end
	return n, padded
end


return TouchFit
