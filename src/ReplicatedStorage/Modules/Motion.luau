--!strict
--[[
	MOTION TOKENS, AND THE ONE ACCESSIBILITY SETTING THIS GAME WAS NOT READING.

	There were 165 TweenInfo call sites across the client and no shared vocabulary
	between them: every curve and duration was typed at the point of use. That is
	the condition this module exists to end -- not to restyle the game, which has
	a voice of its own and keeps it (see Ease.pop).

	The tables below are Emil Kowalski's animation rules mapped onto Roblox's
	easing set. Two of them are the reason this file exists:

	  NEVER EASE-IN ON UI. An ease-in starts slow, which delays the exact moment
	  the user is watching -- and on an EXIT that is the moment they have already
	  decided about. ease-out at 200ms reads as faster than ease-in at 200ms.
	  Entering and exiting both want `out`.

	  UI STAYS UNDER 300ms. A 180ms menu feels more responsive than a 400ms one.
	  Cinematics and first-time celebrations are exempt -- that is where the
	  delight budget lives -- so nothing here is imposed on them.

	WHAT IS DELIBERATELY NOT ADOPTED. The rules are written for productivity
	interfaces (Linear, Vercel) and two of them read differently here:

	  * "start from scale 0.9-0.97" -- PanelKit.popIn punches in from 0.70 and
	    keeps doing so. Its own note argues the case: every panel in the game
	    arrives this way and one that merely appeared would read as another
	    app's menu. That is character, not sloppiness.
	  * "avoid bounce in most UI" -- Back/Out IS this game's house curve. Kept,
	    and named `pop` so a caller reaching for it is choosing it on purpose.

	WHY THIS IS THE GAME'S OWN SETTING AND NOT ROBLOX'S. The obvious answer is
	UserGameSettings.ReducedMotion, which the player has already given once in
	Roblox's accessibility menu. Game code cannot read it:

	  The current thread cannot read 'ReducedMotion' (lacking capability
	  RobloxScript)

	That is RobloxScriptSecurity -- CoreScripts only, and no game LocalScript
	has it. PreferredTransparency, MasterVolume and GraphicsQualityLevel are the
	same; MenuHud had already recorded that about MasterVolume. So the toggle
	lives beside ScreenShake and Flash in this game's own Settings panel and is
	read off the attribute SettingsServer saves, like every other preference.
]]

local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local Motion = {}

--------------------------------------------------------------------------
-- CURVES
--------------------------------------------------------------------------
--[[
	Roblox has no cubic-bezier, so these are the nearest members of its own set
	to the curves the rules name:

	  ease-out    cubic-bezier(0.23, 1, 0.32, 1)      -> Quint/Out
	  ease-in-out cubic-bezier(0.77, 0, 0.175, 1)     -> Quart/InOut
	  ease        (hover, colour)                     -> Sine/Out

	Quint rather than Quad for `out`: the built-in easings are too weak, which is
	the same complaint the rules make about CSS's own keywords.
]]
export type Curve = { Enum.EasingStyle | Enum.EasingDirection }

Motion.Ease = {
	-- Entering or exiting. The default, and the answer whenever unsure.
	out = { Enum.EasingStyle.Quint, Enum.EasingDirection.Out },
	-- Moving or morphing something already on screen.
	inOut = { Enum.EasingStyle.Quart, Enum.EasingDirection.InOut },
	-- Hover, tint, a colour settling.
	hover = { Enum.EasingStyle.Sine, Enum.EasingDirection.Out },
	-- Constant motion: a marquee, a drift, a progress bar.
	linear = { Enum.EasingStyle.Linear, Enum.EasingDirection.InOut },
	-- THE HOUSE CURVE. Overshoot, on purpose. For a panel or a card arriving,
	-- never for something leaving.
	pop = { Enum.EasingStyle.Back, Enum.EasingDirection.Out },
}

--------------------------------------------------------------------------
-- DURATIONS
--------------------------------------------------------------------------
-- Straight from the rules' table. `panel` sits at the 300ms ceiling rather
-- than inside the 200-500ms modal band, because this game's panels are menus
-- the player opens dozens of times a run, not modals they meet twice.
Motion.Dur = {
	press = 0.12,   -- button press feedback   (100-160ms)
	tip = 0.16,     -- tooltips, small popovers (125-200ms)
	menu = 0.20,    -- dropdowns, selects       (150-250ms)
	panel = 0.30,   -- panels and drawers       (held at the UI ceiling)
}

--------------------------------------------------------------------------
-- REDUCED MOTION
--------------------------------------------------------------------------
--[[
	The game's ScreenShake and Flash toggles each cover one symptom. This is the
	general answer, and the header explains why it cannot simply be taken from
	Roblox's own accessibility menu.

	CACHED, NOT POLLED. An attribute read per tween is a property lookup on a
	hot path; this reads once and listens for the change -- the same shape every
	other Set_* preference is consumed in.

	SERVER-SAFE. Motion sits in ReplicatedStorage beside the other kits, so a
	server-side require must not fault on a missing LocalPlayer. It reports that
	motion is fine, which is true there: nothing is being animated.
]]
Motion.Attribute = "Set_ReducedMotion"

local reduced = false

--[[
	LOOPS REGISTER HERE, AND THE REASON IS A RACE THAT WAS MEASURED, NOT GUESSED.

	Gating a looping tween at its call site does not work. MenuHud builds its
	rail while the profile is still loading, so Set_ReducedMotion has not
	arrived yet and `if not Motion.reduced()` reads false at exactly the moment
	the decision is taken. Verified: with the setting ON and persisted across a
	restart, the shop icon was still bobbing -- one of twenty-eight UIScales on
	the HUD, still moving 1.0289 -> 1.0601 a second after the rail was built.

	It is also what a player expects from the switch itself. A pulse started ten
	minutes ago should stop when they ask for it, not at the next rebuild.

	So a loop is handed over rather than gated, and Motion plays or cancels it
	whenever the answer changes -- including the moment the answer first arrives.

	HELD STRONGLY, AND THAT WAS THE SECOND BUG. This started as a weak-keyed
	table so a destroyed GUI's tween would fall out on its own. A Tween has no
	parent and is kept alive only by references to it, so weak keys let the
	registry lose the very tweens it exists to be able to cancel -- the sweep
	then ran over an empty table and stopped nothing, which is exactly what the
	shop icon did when the setting was forced to change. Entries are dropped in
	the sweep instead, by asking whether the thing being animated is still in the
	tree.
]]
local loops: { [Tween]: any } = {}

local function applyLoop(tween: Tween, rest: any)
	-- Wrapped: the tween's instance can be destroyed between registering and a
	-- later change of the setting, and a dead tween must not take the sweep with
	-- it. The weak table drops it on the next collection either way.
	pcall(function()
		if reduced then
			tween:Cancel()
			if type(rest) == "function" then
				rest()
			end
		else
			tween:Play()
		end
	end)
end

-- Still in the tree, and therefore still worth driving. A Tween whose target
-- has been destroyed is dead weight in a table that is otherwise never emptied.
local function stillAlive(tween: Tween): boolean
	local ok, inst = pcall(function()
		return tween.Instance
	end)
	return ok and inst ~= nil and inst.Parent ~= nil
end

local function readSetting()
	local plr = Players.LocalPlayer
	local was = reduced
	reduced = plr ~= nil and plr:GetAttribute(Motion.Attribute) == true
	if reduced == was then
		return
	end
	for tween, rest in pairs(loops) do
		if stillAlive(tween) then
			applyLoop(tween, rest)
		else
			loops[tween] = nil
		end
	end
end

if Players.LocalPlayer then
	readSetting()
	Players.LocalPlayer:GetAttributeChangedSignal(Motion.Attribute):Connect(readSetting)
end

--[[
	Hand a looping tween over instead of starting it.

	`rest` puts the thing back where it belongs when the loop is stopped -- a
	UIScale back to 1, a Rotation back to 0. Without it a cancelled loop freezes
	wherever it happened to be, which for a breathing scale means a button that
	is permanently 4% too big.
]]
function Motion.loop(tween: Tween, rest: (() -> ())?): Tween
	loops[tween] = rest or true
	applyLoop(tween, rest)
	return tween
end

-- Whether this player has asked for less motion. Callers that move something a
-- long way across the screen should ask, and simply place it instead.
function Motion.reduced(): boolean
	return reduced
end

--------------------------------------------------------------------------
-- SCREEN SHAKE
--------------------------------------------------------------------------
--[[
	THE SETTING THAT WAS IN THE PANEL AND IN NOTHING ELSE.

	Set_ScreenShake has been in Settings since the panel was built, is saved by
	SettingsServer and is printed in the feedback report -- and until now was
	read by exactly NOTHING. MenuHud's own note beside it says "ScreenShake is
	read by whoever shakes", which was an assumption rather than a fact: a grep
	for the attribute across the whole game returned a single hit, and that hit
	was the feedback panel reporting the value back to us.

	So the toggle moved and the camera carried on shaking -- everywhere, for
	every player who ever turned it off. Found by a player who had worked out
	that much unaided: "i tried turning on and off the screen shakes effect but
	it still does shakes anyway."

	OFF WHEN EITHER SWITCH SAYS OFF. Reduced Motion is the general answer and
	this is one of its symptoms -- the header above says exactly that -- so a
	player who asked for less motion has already asked for this, and should not
	have to find a second toggle to be taken seriously.

	DEFAULTS ON, via `~= false` rather than `== true`: the shape Set_Flash is
	already read in. A preference that has not replicated yet is not a
	preference for stillness, and the sea is meant to move.
]]
Motion.ShakeAttribute = "Set_ScreenShake"

local shakeWanted = true

local function readShake()
	local plr = Players.LocalPlayer
	shakeWanted = plr == nil or plr:GetAttribute(Motion.ShakeAttribute) ~= false
end

if Players.LocalPlayer then
	readShake()
	Players.LocalPlayer:GetAttributeChangedSignal(Motion.ShakeAttribute):Connect(readShake)
end

--[[
	May the camera move on its own right now?

	ASKED EVERY FRAME by the three things that shake, rather than read once when
	a crossing or an eruption begins. A player reaching for this switch mid-
	voyage is reaching for it BECAUSE of what is happening to them, and a value
	latched at the quay would make them sit out the whole thing they just asked
	to stop. It is two booleans and a branch; there is no reason to cache it
	harder than the setting itself already is.
]]
function Motion.shake(): boolean
	return shakeWanted and not reduced
end

--------------------------------------------------------------------------
-- THE ONE CONSTRUCTOR
--------------------------------------------------------------------------
--[[
	Under reduced motion this collapses to a near-instant linear step rather
	than to zero. Zero would be a property write with no tween, and every caller
	that expects a Tween object back -- to :Play(), to hold, to Cancel -- would
	need a second code path. 60ms is below the threshold at which the movement
	reads as movement, while keeping one shape for every call site.

	The fade is deliberately NOT stripped. Reduced motion means less travel and
	less spin, not a screen that changes with no transition at all.
]]
function Motion.info(duration: number, curve: Curve?): TweenInfo
	local ease = curve or Motion.Ease.out
	if reduced then
		return TweenInfo.new(0.06, Enum.EasingStyle.Linear, Enum.EasingDirection.Out)
	end
	return TweenInfo.new(duration, ease[1] :: any, ease[2] :: any)
end

--[[
	AND THE OTHER HALF: A FADE IS NOT MOTION.

	Reduced motion means stop things MOVING -- sliding, scaling, spinning. It
	does not mean the screen should change with no transition at all; a cut is
	harsher than a cross-fade and helps nobody. So a transparency tween keeps
	its full duration whatever the setting says, and only `info` collapses.

	THIS CORRECTS A FIRST PASS THAT HAD FADES SHARING info's TweenInfo. The
	reasoning then was that a transform and its fade must not drift apart -- but
	the conclusion was backwards. Under reduced motion they SHOULD differ: the
	transform is the part being taken away and the fade is the part standing in
	for it. A hatch backdrop that cuts to black instead of fading is exactly the
	harshness this setting exists to avoid.

	The curve is fixed rather than a parameter: a fade has one right answer and
	a caller choosing Back for an opacity ramp is choosing wrong.
]]
function Motion.fade(duration: number): TweenInfo
	return TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
end

-- The common case, so a call site is one line and cannot forget the curve.
function Motion.tween(object: Instance, duration: number, curve: Curve?, props: { [string]: any }): Tween
	local t = TweenService:Create(object, Motion.info(duration, curve), props)
	t:Play()
	return t
end

return Motion
