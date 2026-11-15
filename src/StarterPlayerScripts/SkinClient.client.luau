--[[
	SkinClient  --  StarterPlayer.StarterPlayerScripts.SkinClient

	THE CENTREPIECE, ALIVE. SkinPlinthBuilder puts up a stand and hangs a sifter
	over it; everything that MOVES on it happens here, and so does the ceremony
	when somebody walks up.

	WHY THE SERVER DOES NOT ANIMATE ANY OF THIS
	-------------------------------------------
	Two reasons, and the second is the one that decides it.

	The cheap one: the pieces are anchored parts in a replicated model, so moving
	them from the client costs nothing and replicates nothing -- the same note
	SiftClientController carries over its own cosmetic work.

	The real one: WHETHER THIS SKIN IS CLAIMED IS A DIFFERENT ANSWER FOR EVERY
	PERSON IN THE ROOM. A stand that has to look unclaimed to one player and
	settled to the player standing next to them cannot be driven by the server at
	all. So the server builds one neutral stand and each client dresses its own
	copy off its own attributes.

	NEON IS COLOURED, NEVER FADED
	-----------------------------
	Every pulse in here drives Color and leaves Transparency alone, because Neon
	ignores lighting and a transparent Neon surface renders near-BLACK under
	Future rather than dim -- VaultBuilder's skylight note records it, and the
	first build of the shrine's stand proved it again with a light column that
	photographed as an opaque red bar. Lerping a Neon part's colour toward black
	is what actually reads as "turning it down".

	THE CEREMONY RUNS ON ITS OWN CLOCK. SkinConfig.Ceremony is shared with
	SkinService, which waits exactly `handoff` seconds before writing SkinActive
	-- so the comet lands on the player at the same moment the tool in their
	hands re-forges. Neither side waits for the other; a dropped packet can make
	the handover early or late but can never strand anything.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer
local CTB = ReplicatedStorage:WaitForChild("CTB")
local Net = CTB:WaitForChild("Net")
local Modules = ReplicatedStorage:WaitForChild("Modules")
local SkinConfig = require(Modules:WaitForChild("SkinConfig"))
local AudioKit = require(Modules:WaitForChild("AudioKit"))
local ToastKit = require(Modules:WaitForChild("ToastKit"))

local TAG = "CTB_SkinPlinth"
local CER = SkinConfig.Ceremony

-- Past this the stand is scenery: no hover, no pulse, no label. The rooms are
-- 260 studs long and you can see the stand from the door, so this is generous.
local AWAKE = 170
local LABEL_GONE, LABEL_FULL = 62, 26

local fx = Instance.new("Folder")
fx.Name = "CTB_SkinFX"
fx.Parent = workspace

--------------------------------------------------------------------------
-- SMALL THINGS
--------------------------------------------------------------------------
local function outCubic(a: number): number
	local i = 1 - a
	return 1 - i * i * i
end

local function inCubic(a: number): number
	return a * a * a
end

local BLACK = Color3.new(0, 0, 0)
local WHITE = Color3.new(1, 1, 1)

-- Turn a Neon part up or down without touching its transparency. See the
-- header: on Neon, Transparency is not a dimmer.
local function emit(p: BasePart, tint: Color3, level: number)
	p.Color = BLACK:Lerp(tint, math.clamp(level, 0, 1))
end

local function spark(at: Vector3, tint: Color3, count: number, spread: number)
	local p = Instance.new("Part")
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
	p.Transparency = 1
	p.Size = Vector3.new(0.2, 0.2, 0.2)
	p.CFrame = CFrame.new(at)
	p.Parent = fx
	local e = Instance.new("ParticleEmitter")
	e.Color = ColorSequence.new(tint, WHITE)
	e.LightEmission = 1
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Lifetime = NumberRange.new(0.35, 0.9)
	e.Speed = NumberRange.new(spread * 0.4, spread)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Acceleration = Vector3.new(0, -14, 0)
	e.Rate = 0
	e.Parent = p
	e:Emit(count)
	Debris:AddItem(p, 2)
end

-- A flat ring that runs outward across the floor. Cylinder rather than a Ball:
-- a Roblox Ball ignores a non-uniform Size and draws at its SMALLEST axis,
-- which is the trap CTB_Client's windrow note records at length.
local function shockwave(at: Vector3, tint: Color3, reach: number, life: number)
	local p = Instance.new("Part")
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
	p.Shape = Enum.PartType.Cylinder
	p.Material = Enum.Material.Neon
	p.Color = tint
	p.Size = Vector3.new(0.4, 2, 2)
	p.CFrame = CFrame.new(at) * CFrame.Angles(0, 0, math.rad(90))
	p.Transparency = 0.25
	p.Parent = fx

	local t = 0
	local conn
	conn = RunService.RenderStepped:Connect(function(dt)
		t += dt
		local a = math.min(t / life, 1)
		local d = 2 + outCubic(a) * reach
		p.Size = Vector3.new(0.4, d, d)
		-- Fading a Neon ring IS wrong for the same reason everywhere else in
		-- this file, so it thins to black as it goes instead.
		emit(p, tint, 1 - a)
		if a >= 1 then
			conn:Disconnect()
			p:Destroy()
		end
	end)
end

--------------------------------------------------------------------------
-- THE LABEL
--
-- Built here rather than by the builder for the reason in the header: what it
-- says is a different answer for every player looking at the same stand.
--------------------------------------------------------------------------
local INK = Color3.fromRGB(26, 20, 34)

local function buildLabel(parent: BasePart, skin): (BillboardGui, TextLabel, TextLabel)
	local bb = Instance.new("BillboardGui")
	bb.Name = "SkinLabel"
	bb.Size = UDim2.fromOffset(340, 96)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 5.6, 0)
	bb.MaxDistance = LABEL_GONE + 8
	bb.LightInfluence = 0
	bb.AlwaysOnTop = false
	bb.Parent = parent

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 46)
	title.Font = Enum.Font.LuckiestGuy
	title.Text = skin.name
	title.TextColor3 = skin.tint
	title.TextScaled = true
	title.Parent = bb
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = 34
	cap.Parent = title
	local s1 = Instance.new("UIStroke")
	s1.Thickness = 3
	s1.Color = INK
	s1.Parent = title

	local sub = Instance.new("TextLabel")
	sub.BackgroundTransparency = 1
	sub.Position = UDim2.fromOffset(0, 48)
	sub.Size = UDim2.new(1, 0, 0, 26)
	sub.Font = Enum.Font.GothamBold
	sub.Text = ""
	sub.TextColor3 = Color3.fromRGB(238, 232, 222)
	sub.TextScaled = true
	sub.Parent = bb
	local cap2 = Instance.new("UITextSizeConstraint")
	cap2.MaxTextSize = 17
	cap2.Parent = sub
	local s2 = Instance.new("UIStroke")
	s2.Thickness = 2.5
	s2.Color = INK
	s2.Parent = sub

	bb.Enabled = false
	return bb, title, sub
end

--------------------------------------------------------------------------
-- THE STANDS
--------------------------------------------------------------------------
-- [Model] = entry. Keyed on the instance because StreamingEnabled takes these
-- rooms away and hands them back, and the entry has to go with them.
local stands = {}

local function adopt(model: Model)
	if stands[model] then
		return
	end
	local key = model:GetAttribute("SkinKey")
	if type(key) ~= "string" then
		return
	end
	local display = model:FindFirstChild("Display")
	local halo = model:FindFirstChild("Halo")
	-- Streaming can hand over the model before every child has landed. Bail
	-- rather than adopting a half a stand; the retry sweep below picks it up.
	if not (display and display.PrimaryPart and halo) then
		return
	end

	local skin = SkinConfig.get(key)
	local runes = {}
	local ring = model:FindFirstChild("Ring")
	if ring then
		for _, p in ipairs(ring:GetChildren()) do
			if p:IsA("BasePart") then
				table.insert(runes, p)
			end
		end
	end
	local sleeves = {}
	local beam = model:FindFirstChild("Beam")
	if beam then
		for _, p in ipairs(beam:GetChildren()) do
			if p:IsA("BasePart") then
				table.insert(sleeves, p)
			end
		end
	end

	-- Every piece of the showpiece, with the transparency it was BUILT at.
	-- The burst hides the whole thing and the settle brings it back, and
	-- restoring from a snapshot is the only way the ember skin's 0.25 coals
	-- come back at 0.25 rather than at 0 with everything else.
	local pieces = {}
	for _, p in ipairs(display:GetDescendants()) do
		if p:IsA("BasePart") and p ~= display.PrimaryPart then
			table.insert(pieces, { part = p, t = p.Transparency })
		end
	end

	local home = display:GetPivot()
	local bb, title, sub = buildLabel(halo, skin)

	stands[model] = {
		model = model,
		key = key,
		skin = skin,
		display = display,
		pieces = pieces,
		-- Split so the hover can spin about WORLD up while keeping the pose the
		-- builder tilted it into. Multiplying the whole home CFrame by a yaw
		-- would spin it about its own tilted axis and make it wobble.
		homePos = home.Position,
		homeRot = home.Rotation,
		runes = runes,
		sleeves = sleeves,
		halo = halo,
		light = halo:FindFirstChildOfClass("PointLight"),
		motes = model:FindFirstChild("Cap") and model.Cap:FindFirstChild("Motes") or nil,
		gui = bb,
		title = title,
		sub = sub,
		t = 0,
		spin = 0,
		lift = 0,
		glow = 0,
		cer = nil,
	}
end

local function drop(model: Model)
	stands[model] = nil
end

for _, m in ipairs(CollectionService:GetTagged(TAG)) do
	adopt(m)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(adopt)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(drop)

-- The added signal fires the moment the MODEL arrives, which on a streaming
-- client is often a beat before its parts do. One cheap sweep a second catches
-- whatever `adopt` refused.
task.spawn(function()
	while true do
		task.wait(1)
		for _, m in ipairs(CollectionService:GetTagged(TAG)) do
			if not stands[m] then
				adopt(m)
			end
		end
	end
end)

--------------------------------------------------------------------------
-- WHAT THIS PLAYER HAS
--------------------------------------------------------------------------
local function owns(key: string): boolean
	return player:GetAttribute(SkinConfig.OwnPrefix .. key) == true
end

local function isChosen(key: string): boolean
	return player:GetAttribute(SkinConfig.ChosenAttribute) == key
end

--------------------------------------------------------------------------
-- IDLE
--------------------------------------------------------------------------
local function applyStand(s, dt: number, here: Vector3)
	local display = s.display
	if not (display.Parent and display.PrimaryPart) then
		return
	end

	-- The hover. Yaw is applied about WORLD up and the builder's tilt is put
	-- back afterwards -- see homePos/homeRot.
	local bob = math.sin(s.t * 1.05) * 0.32
	display:PivotTo(CFrame.new(s.homePos + Vector3.new(0, bob + s.lift, 0))
		* CFrame.Angles(0, s.spin, 0) * s.homeRot)

	local tint = s.skin.tint
	for i, r in ipairs(s.runes) do
		-- A chase rather than a pulse: every rune on the same phase reads as the
		-- whole ring blinking, which looks like a fault light.
		local k = 0.5 + 0.5 * math.sin(s.t * 2.4 - i * 0.55)
		emit(r, tint, s.glow * (0.3 + 0.7 * k))
	end
	for _, sl in ipairs(s.sleeves) do
		emit(sl, tint, s.glow * 0.8)
	end
	if s.light then
		local base = ((s.skin.glow and s.skin.glow.brightness) or 1.0) + 0.5
		s.light.Brightness = base * (0.45 + 0.75 * s.glow)
	end
	if s.motes then
		s.motes.Rate = 4 + 30 * s.glow
	end

	--[[
		THE LABEL, and the three states it has to tell apart.

		The middle one is the one worth having: a skin you own but are not
		wearing outside this room. Entering the room equips it either way
		(SkinService does that), so without this line there would be no way to
		learn that walking up again makes it your everyday tool.
	]]
	local alpha = math.clamp((LABEL_GONE - (s.homePos - here).Magnitude)
		/ (LABEL_GONE - LABEL_FULL), 0, 1)
	if alpha > 0.01 then
		local line
		if not owns(s.key) then
			line = "NEW SKIN  \u{2014}  WALK UP TO CLAIM IT"
		elseif isChosen(s.key) then
			line = "YOURS  \u{2014}  WORN EVERYWHERE"
		else
			line = "WALK UP TO WEAR IT EVERYWHERE"
		end
		if s.sub.Text ~= line then
			s.sub.Text = line
		end
		s.gui.Enabled = true
		s.title.TextTransparency = 1 - alpha
		s.sub.TextTransparency = 1 - alpha
		for _, l in ipairs({ s.title, s.sub }) do
			local st = l:FindFirstChildOfClass("UIStroke")
			if st then
				st.Transparency = 1 - alpha
			end
		end
	elseif s.gui.Enabled then
		s.gui.Enabled = false
	end
end

--------------------------------------------------------------------------
-- THE CEREMONY
--
-- Five beats off SkinConfig.Ceremony, and the fourth of them is the contract:
-- the comet lands at `handoff`, which is the same number SkinService waits
-- before it writes SkinActive and CTB_Client re-forges the tool.
--------------------------------------------------------------------------
local T1 = CER.charge
local T2 = T1 + CER.lift
local T3 = T2 + CER.burst
local T4 = T3 + CER.travel          -- == CER.handoff
local T5 = T4 + CER.settle
local T6 = T5 + 1.2                 -- the display coming back

-- Where the player's own sifter is riding. CTB_Client owns the real number;
-- this is the same arithmetic (ROLLER_DIST ahead, about a wheel under the
-- root) and it is re-read every frame because the player is usually walking.
local function toolPoint(): Vector3?
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return nil
	end
	return hrp.Position + hrp.CFrame.LookVector * 4.6 - Vector3.new(0, 1.4, 0)
end

local function makeComet(at: Vector3, tint: Color3): BasePart
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(1.2, 1.2, 1.2)
	p.Material = Enum.Material.Neon
	p.Color = tint:Lerp(WHITE, 0.55)
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
	p.CFrame = CFrame.new(at)
	p.Parent = fx

	local l = Instance.new("PointLight")
	l.Color = tint
	l.Range = 18
	l.Brightness = 3
	l.Shadows = false
	l.Parent = p

	local e = Instance.new("ParticleEmitter")
	e.Color = ColorSequence.new(tint, WHITE)
	e.LightEmission = 1
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.9),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Lifetime = NumberRange.new(0.24, 0.44)
	e.Speed = NumberRange.new(0, 1)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Rate = 190
	e.Parent = p
	return p
end

local function stepCeremony(s, dt: number): boolean
	local c = s.cer
	c.t += dt
	local t = c.t
	local tint = s.skin.tint

	if t < T1 then
		-- CHARGE. The ring winds up and the piece lifts off its cap.
		local a = t / CER.charge
		s.spin += (0.8 + a * 9) * dt
		s.lift = outCubic(a) * 1.3
		s.glow = 1 + a * 1.4

	elseif t < T2 then
		-- LIFT. It climbs and the spin runs away with it.
		local a = (t - T1) / CER.lift
		s.spin += (9 + a * 17) * dt
		s.lift = 1.3 + inCubic(a) * 3.6
		s.glow = 2.4 + a * 0.9
		if not c.rise and a > 0.5 then
			c.rise = true
			AudioKit.play("SwingWhoosh", nil, 1.4, 0.55)
		end

	elseif t < T3 then
		-- BURST. One frame of work, then a held flash.
		if not c.burst then
			c.burst = true
			c.from = s.display:GetPivot().Position
			for _, e in ipairs(s.pieces) do
				e.part.Transparency = 1
			end
			spark(c.from, tint, 110, 38)
			shockwave(s.homePos - Vector3.new(0, 6.6, 0), tint, 52, 0.75)
			AudioKit.play("LegendaryHit")
			c.comet = makeComet(c.from, tint)
		end
		s.lift, s.glow = 4.9, 3.4

	elseif t < T4 then
		-- TRAVEL. Ground track eases IN -- it should arrive fast -- while the
		-- height lofts and drops, which is the same two-axis split CTB_Client's
		-- sweep uses to throw litter into the cart.
		local a = (t - T3) / CER.travel
		s.lift, s.glow = 4.9, 3.4 - a * 2.2
		local target = toolPoint() or (c.from - Vector3.new(0, 4, 0))
		if c.comet then
			local ease = inCubic(a)
			local apex = math.max(c.from.Y, target.Y) + 3
			local y
			if a < 0.45 then
				local r = a / 0.45
				y = c.from.Y + (apex - c.from.Y) * (1 - (1 - r) * (1 - r))
			else
				local r = (a - 0.45) / 0.55
				y = apex + (target.Y - apex) * (r * r)
			end
			c.comet.CFrame = CFrame.new(
				c.from.X + (target.X - c.from.X) * ease, y,
				c.from.Z + (target.Z - c.from.Z) * ease)
		end

	elseif t < T5 then
		-- SETTLE. The tool re-forges in the player's hands on this beat; all
		-- this half owes is the noise and the card.
		if not c.landed then
			c.landed = true
			local at = (c.comet and c.comet.Position) or c.from
			if c.comet then
				c.comet:Destroy()
				c.comet = nil
			end
			spark(at, tint, 70, 20)
			AudioKit.stack("Upgrade", "FairyDust", nil, 0.12)
			ToastKit.banner(s.skin.name .. "  UNLOCKED", "level", 2.8)
		end
		s.lift, s.glow = 4.9, 1.1

	else
		-- The stand does not stay empty. The piece fades back in and sinks to
		-- its cap, and from here on it is somebody's trophy rather than a prize.
		local a = math.min((t - T5) / 1.2, 1)
		for _, e in ipairs(s.pieces) do
			e.part.Transparency = 1 - (1 - e.t) * outCubic(a)
		end
		s.spin += (6 - a * 5.5) * dt
		s.lift = 4.9 * (1 - outCubic(a))
		s.glow = 1.1 - a * 0.6
		if t >= T6 then
			return false
		end
	end
	return true
end

--------------------------------------------------------------------------
-- THE LOOP
--------------------------------------------------------------------------
local TWO_PI = math.pi * 2

local function standFor(key: string)
	for _, s in pairs(stands) do
		if s.key == key then
			return s
		end
	end
	return nil
end

RunService.RenderStepped:Connect(function(dt)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local here = hrp and hrp.Position or Vector3.zero

	for model, s in pairs(stands) do
		if not model.Parent then
			-- Streamed out between the tag signal and now.
			stands[model] = nil
		elseif s.cer or (s.homePos - here).Magnitude <= AWAKE then
			s.t += dt
			if s.cer then
				if not stepCeremony(s, dt) then
					s.cer = nil
				end
			else
				-- UNCLAIMED TURNS FASTER AND BURNS BRIGHTER, and that is the
				-- whole read: from the door you can tell across 200 studs
				-- whether there is something here for you.
				local owned = owns(s.key)
				s.spin += (owned and 0.35 or 0.85) * dt
				if s.spin > TWO_PI then
					s.spin -= TWO_PI
				end
				local want = owned and 0.5 or (0.76 + 0.24 * math.sin(s.t * 1.8))
				local k = math.min(dt * 3.5, 1)
				s.lift += (0 - s.lift) * k
				s.glow += (want - s.glow) * k
			end
			applyStand(s, dt, here)
		elseif s.gui.Enabled then
			s.gui.Enabled = false
		end
	end
end)

--------------------------------------------------------------------------
-- WIRING
--------------------------------------------------------------------------
Net.OnClientEvent:Connect(function(action, a, _b)
	if action == "SkinUnlock" then
		local s = standFor(a)
		if s then
			s.cer = { t = 0 }
			AudioKit.play("SwingWhoosh", nil, 1.2, 0.7)
		else
			-- The grant is the server's and it has already happened; the stand
			-- simply is not on this client (streamed out, or it failed to
			-- build). Announce it anyway, on the beat the tool changes, rather
			-- than hand somebody a new skin with no acknowledgement at all.
			task.delay(CER.handoff, function()
				ToastKit.banner(SkinConfig.get(a).name .. "  UNLOCKED", "level", 2.8)
			end)
		end

	elseif action == "SkinPick" then
		local skin = SkinConfig.get(a)
		local s = standFor(a)
		if s then
			-- Written straight into `glow`; the idle smoothing takes it back
			-- down over the next second, which IS the flourish.
			s.glow = 2.8
			spark(s.homePos + Vector3.new(0, 1, 0), skin.tint, 34, 14)
		end
		AudioKit.play("Mount", nil, 1, 1.12)
		ToastKit.toast("Now carrying the " .. skin.short .. " everywhere", "level", 2.6)
	end
end)

print("[Skins] client ready \u{2014} centrepieces armed")
