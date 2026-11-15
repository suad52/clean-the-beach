--[[
	LastFew_Client  --  StarterPlayer.StarterPlayerScripts.LastFew_Client

	A MARKER ON EVERY SQUARE STILL TO DO, once a field is nearly finished.

	Every field in the game turns over only when all of it is raked (resetAt is
	1.0 on all seven), and the last handful are the worst part of the job -- one
	four-stud square of messy sand in four thousand, or in twenty-five thousand on
	Ashfall, and nothing to tell you where. The long argument for the threshold is
	over Config.LAST_FEW; this file is just the picture.

	THE SERVER SAYS WHERE, and it has to. This client is told which columns go
	CLEAN and never which stay messy, so working the stragglers out here would
	mean keeping a shadow copy of the whole grid and trusting it never drifted --
	and a marker standing on a square the player has already raked is worse than
	no marker at all. CTB_Server sends the list once it is short enough to be
	fifteen integers.

	THREE PARTS TO A MARKER, and each answers a different half of "where is it":

	  TILE    a glowing square lying on the cell, the size of the cell. This is
	          the one that says WHICH square, once you are standing over it.
	  POST    a column of light out of it, so it clears the litter and the props.
	  BEACON  a billboard diamond, AlwaysOnTop, so it is visible THROUGH the
	          palms, the boards and the shop from anywhere on the island. This is
	          the one that actually solves the problem -- a post you can only see
	          when nothing is in front of it does not help you find anything.

	Its own script rather than part of CTB_Client, for the reason the note over
	remessField gives there: that chunk is one statement under Luau's
	200-locals-per-function ceiling, and going over stops the whole file
	compiling. Every other thing that listens on this remote is its own script
	too.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CTB = ReplicatedStorage:WaitForChild("CTB")
local Config = require(CTB:WaitForChild("Config"))
local net = CTB:WaitForChild("Net")

-- Destroyed and rebuilt, so reloading this script in a live session leaves one
-- set of markers rather than two standing in the same squares.
local old = workspace:FindFirstChild("LastFew_FX")
if old then
	old:Destroy()
end
local fx = Instance.new("Folder")
fx.Name = "LastFew_FX"
fx.Parent = workspace

--------------------------------------------------------------------------
-- ONE MARKER
--------------------------------------------------------------------------
local GOLD = Color3.fromRGB(255, 208, 40)
local INK = Color3.fromRGB(56, 36, 20)
local TILE_LIFT = 0.12
local POST_H, POST_W = 10, 0.4
-- Far enough to see one from the opposite corner of the biggest field (Ashfall
-- is 640 across, so 460 covers a corner-to-centre walk) and near enough that
-- markers on an island the player is not standing on cannot punch through the
-- sky at them -- an AlwaysOnTop billboard has no other range limit.
local SEE_FROM = 600 -- was 460; Penguin Island's field is 768 across and the far corner was out of range

-- A FLOOR UNDER A BAD LIST, deliberately not Config.LAST_FEW. The threshold is
-- the server's business and somebody will raise it one day; this is the number
-- of parts this file is willing to put in the world whatever arrives, so that a
-- mistake at the other end is fifteen too many markers rather than four
-- thousand parts and a frozen client.
local MAX_MARKERS = 24

--[[
	NEON, AND THEREFORE ALWAYS AT TRANSPARENCY 0.

	Above zero a Neon part renders near-black in this place under Future
	lighting, so a marker that "fades out" fades to a dark smear on the sand.
	That rules out the obvious way to hide one, and is why the code below takes a
	marker away by DESTROYING it.

	Neon is also what makes the thing readable at all: the sand here is a pale
	warm yellow, and a lit yellow marker on it is the same trap the tide's foam
	hit -- see Tide_Client. An emissive part does not care what the sun is doing.
]]
local function neon(name: string, size: Vector3, parent: Instance): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = GOLD
	p.Transparency = 0
	p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function buildMarker(parent: Instance, phase: number)
	local model = Instance.new("Model")
	model.Name = "Marker"
	model.Parent = parent

	-- A shade under the cell so two markers in neighbouring squares still read as
	-- two squares rather than as one strip.
	local tile = neon("Tile", Vector3.new(Config.TILE - 0.5, 0.18, Config.TILE - 0.5), model)
	local post = neon("Post", Vector3.new(POST_W, POST_H, POST_W), model)

	local gui = Instance.new("BillboardGui")
	gui.Name = "Beacon"
	-- SIZED IN PIXELS, not studs: a beacon whose job is to be findable from the
	-- far side of the field must not shrink with distance the way the post does.
	gui.Size = UDim2.fromOffset(42, 42)
	gui.StudsOffsetWorldSpace = Vector3.new(0, POST_H * 0.5 + 1.7, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = SEE_FROM
	gui.Adornee = post
	gui.Parent = post

	-- A diamond drawn from a rotated Frame rather than a glyph: this game's own
	-- notes record that a TextLabel emoji Roblox cannot find comes back looking
	-- like a BROKEN ICON, which is the last thing a "look here" marker should do.
	local diamond = Instance.new("Frame")
	diamond.AnchorPoint = Vector2.new(0.5, 0.5)
	diamond.Position = UDim2.fromScale(0.5, 0.5)
	diamond.Size = UDim2.fromScale(0.6, 0.6)
	diamond.Rotation = 45
	diamond.BackgroundColor3 = GOLD
	diamond.BorderSizePixel = 0
	diamond.Parent = gui

	-- Outlined, because the beacon is drawn over whatever happens to be behind it
	-- -- and half of that is a bright sky a gold diamond disappears into.
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = INK
	stroke.Parent = diamond

	return { model = model, tile = tile, post = post, diamond = diamond, phase = phase }
end

--------------------------------------------------------------------------
-- THE SET ON ONE ISLAND
--------------------------------------------------------------------------
local shown = {}       -- [islandId] = { folder = Folder, rigs = { marker } }

local function clearIsland(islandId: number)
	local set = shown[islandId]
	if not set then
		return
	end
	set.folder:Destroy()
	shown[islandId] = nil
end

local function setMarkers(islandId: number, indices: { number }?)
	local isl = Config.island(islandId)
	if not isl or type(indices) ~= "table" or #indices == 0 then
		clearIsland(islandId)
		return
	end

	local set = shown[islandId]
	if not set then
		local folder = Instance.new("Folder")
		folder.Name = isl.name
		folder.Parent = fx
		set = { folder = folder, rigs = {} }
		shown[islandId] = set
	end

	-- The TOP of the messy sand, which on a field with a crust is half a stud
	-- above the raked surface. A marker sunk into the crust is a marker you can
	-- only see from directly overhead.
	local y = Config.crustY(isl)
	local want = math.min(#indices, MAX_MARKERS)
	for i = 1, want do
		local rig = set.rigs[i]
		if not rig then
			rig = buildMarker(set.folder, i * 0.7)
			set.rigs[i] = rig
		end
		local c = Config.centreOf(isl, indices[i])
		rig.tile.Position = Vector3.new(c.X, y + TILE_LIFT, c.Z)
		rig.post.Position = Vector3.new(c.X, y + POST_H * 0.5, c.Z)
	end

	-- Surplus markers are DESTROYED, not hidden -- see the note over `neon`. The
	-- list only ever shrinks inside a field, so this is the common path: every
	-- rake takes one or two markers off the board.
	for i = #set.rigs, want + 1, -1 do
		set.rigs[i].model:Destroy()
		set.rigs[i] = nil
	end
end

--------------------------------------------------------------------------
-- WIRING
--------------------------------------------------------------------------
net.OnClientEvent:Connect(function(action, a, b)
	if action == "LastFew" then
		setMarkers(a, b)
	elseif action == "Tide" or action == "Wipe" then
		-- That field has just gone back to messy underneath them. The server will
		-- send a fresh list when it is nearly done again; until then there is
		-- nothing to point at, and markers left standing would be pointing at
		-- squares that are no longer the last ones.
		clearIsland(a)
	end
end)

-- Costs a `next` on an empty table per frame for every player who is not near
-- the end of a field, which is almost all of them almost all of the time.
RunService.Heartbeat:Connect(function()
	if next(shown) == nil then
		return
	end
	local t = os.clock()
	for _, set in pairs(shown) do
		for _, rig in ipairs(set.rigs) do
			-- Breathing and rocking rather than blinking. A marker that switches off
			-- is a marker the player is looking straight at when it is not there.
			local s = 0.6 + 0.09 * math.sin(t * 3.2 + rig.phase)
			rig.diamond.Size = UDim2.fromScale(s, s)
			rig.diamond.Rotation = 45 + 11 * math.sin(t * 1.4 + rig.phase)
		end
	end
end)

print(string.format("[LastFew] client ready -- markers on the last %d squares of any field",
	Config.LAST_FEW))
