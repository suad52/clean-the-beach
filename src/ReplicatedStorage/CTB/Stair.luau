--[[
	THE ASHEN STAIR AS A CLEANABLE SURFACE.

	The shared description of the ash lying on the volcano's road: how it is cut
	into cells, where each cell is in the world, and which cells a sweep covers.
	CTB_Server rakes it, StairClient draws it, and both read this file so neither
	has to be told where anything is.

	========================================================================
	WHY THIS IS NOT JUST ANOTHER ISLAND
	========================================================================

	Every rakeable surface in this game up to now has been a flat boolean grid at
	ONE height, and the stair is none of those things. Three separate parts of
	Config make it impossible to express as ISLANDS[8]:

	  Config.fieldAt matches on XZ ALONE and returns the FIRST row that contains
	  the point. The stair spirals up a cone whose footprint overlaps nothing --
	  but the moment it were a row in that table, a player standing at the top of
	  it at y = 185 and a player standing on the sand 180 studs below would be
	  indistinguishable.

	  Config.surfaceY hands back one height per island. These 34 treads climb
	  from y = 7.3 to y = 185.4 on a 34-degree slope and each one is ROTATED to
	  face along the road.

	  Config.writeField rewrites terrain voxels between Y_MIN and Y_MAX. The
	  stair is not terrain at all -- it is 34 anchored Slate parts standing on
	  the analytic surface of the cone.

	So the stair keeps its own state, its own counter and its own bonus, and
	CRITICALLY it is not folded into Ashfall's resetAt. That is a safety property
	rather than a convenience: resetAt is 1.0, so if the stair's cells counted
	toward Ashfall's turnover, one tread a player could not reach -- a tread
	inside the caldera's smoke, a tread a lava plate had drifted onto -- would
	brick the island's tide permanently and silently.

	========================================================================
	THE CELL LAYOUT
	========================================================================

	Each tread carries a grid in ITS OWN frame: ACROSS cells wide, and as many
	along the road as its span will take at CELL studs each.

	ACROSS is 3, not 4. The tread is 13 studs wide and the kerb takes 1.4 of
	them off one side, so three 4-stud cells centred on the middle put their
	centres at local x -4, 0 and +4 -- all three comfortably inside the kerb,
	which starts at 5.8. A fourth column would have its centre under the kerb
	itself, and a cell whose centre cannot be reached is a cell that never
	cleans.

	THE SPAN IS NOT Size.Z. Island4Builder stretches every tread to 1.2x its
	true length so consecutive treads bite into each other and the road has no
	gaps in it. Ash laid over Size.Z would therefore overlap its neighbour at
	every one of the 33 joins and z-fight the whole way up. The builder stamps
	the true length as the StairSpan attribute; this file uses that and falls
	back to Size.Z / 1.2 if it is ever missing.
]]

local Stair = {}

-- Where the model lives. Island4Builder rebuilds Ashfall from code on every
-- boot, so this is looked up rather than held.
Stair.ISLAND = "Island4"
Stair.MODEL = "AshenStair"
Stair.PART = "Tread"

-- Config.ISLANDS id of the island the stair stands on. The ash goes back when
-- THAT field turns over: an eruption that re-buries the whole strand has
-- obviously re-buried the road up the mountain as well, and it gives the stair a
-- cadence -- one sweep per tide -- rather than making it a thing you do once.
Stair.ISLAND_ID = 5

Stair.CELL = 4                -- studs, matching Config.TILE so the two read alike
Stair.ACROSS = 3              -- cells across a tread -- see the note above

-- How far the ash stands over the tread's top face, and how far it carries on
-- below it. Config.CRUST's own numbers: the rise is what the player wades
-- through and the bury is what stops the underside z-fighting the stone.
Stair.RISE = 0.5
Stair.BURY = 0.3

-- Toward white off the ash tone, exactly as Config.CRUST.lighten does for sand.
Stair.LIGHTEN = 0.10

--[[
	WHAT SWEEPING THE WHOLE STAIR PAYS, AND WHY IT IS 1200.

	The stair works out at about 560 cells. Ashfall pays 0.50 a column
	(12800 / 25600), so at the island's own rate the stair is worth 280.

	It pays more than double that because a column up here costs more than a
	column down there and the ladder in Config.ISLANDS is written in coins per
	COLUMN, not coins per second. The road is 13 studs wide, so a 48-stud sifter
	sweeps a fraction of its width and the rest of the band hangs over a cliff;
	there is no lane packing, no straight line and no shortcut; and it is a
	900-stud climb from the field to the rim and back. 1200 is 2.14 a cell,
	which sits between the Inner Shrine's 1.76 and the Magma Chamber's 2.50 --
	the two other places in the game where a small, awkward, gated space pays
	well above the beach it stands on.

	It is a BONUS, not a field: nothing is buried in the ash and nothing is
	collected off it. The stair is a job you finish, not a job you farm.
]]
Stair.BONUS = 1200
Stair.NAME = "ASHEN STAIR"
Stair.BANNER = "SWEPT"

-- How far above or below a cell the tool may be and still count as being on it.
-- The stair doubles back on itself twice, and flights pass within about 30 studs
-- of each other vertically; 6 is comfortably inside that and comfortably outside
-- the couple of studs of bob a character has while walking.
Stair.REACH_Y = 6

local cache = nil

-- The model, or nil if this side of the wire has not seen it yet. Never waits:
-- the server builds it during boot and the client streams it in, and neither
-- caller can afford to block a Heartbeat on it.
function Stair.model(): Model?
	local isl = workspace:FindFirstChild(Stair.ISLAND)
	if not isl then
		return nil
	end
	local m = isl:FindFirstChild(Stair.MODEL)
	return (m and m:IsA("Model")) and m or nil
end

--[[
	THE TREAD TABLE, built once and rebuilt if the stair is ever replaced.

	One record per tread, in order up the mountain:
	  part   the tread itself
	  seat   its CFrame -- +X across the road, +Z along it, +Y out of its face
	  top    studs from the seat to the walking surface (half its thickness)
	  span   its true length along the road (see the header)
	  nz     cells along it
	  step   span / nz
	  base   the linear index of its first cell, minus one
	and Stair.cells is the total.
]]
local function build()
	local model = Stair.model()
	if not model then
		return nil
	end
	local list = {}
	for _, p in ipairs(model:GetChildren()) do
		if p:IsA("BasePart") and p.Name == Stair.PART then
			local step = tonumber(p:GetAttribute("StairStep"))
			local span = tonumber(p:GetAttribute("StairSpan")) or (p.Size.Z / 1.2)
			list[#list + 1] = { part = p, order = step or p.Position.Y, span = span }
		end
	end
	if #list == 0 then
		return nil
	end

	--[[
		ALL OF IT, OR NONE OF IT. This place runs with StreamingEnabled, so a
		client acquires the AshenStair MODEL long before its parts and picks the
		treads up in whatever order the streamer sends them.

		Half a stair is worse than no stair: the cell indices are laid out by
		summing the treads in order, so a layout built from nine of them assigns
		completely different indices to the same cells than the server's -- and
		the server's StairClean messages would then cut ash off the wrong treads.

		Island4Builder stamps how many it made. Until that many have arrived this
		returns nil, and the caller simply tries again.
	]]
	local expect = tonumber(model:GetAttribute("StairTreads"))
	if expect and #list < expect then
		return nil
	end
	table.sort(list, function(a, b)
		return a.order < b.order
	end)

	local total = 0
	local built = #list
	for _, t in ipairs(list) do
		t.seat = t.part.CFrame
		t.top = t.part.Size.Y * 0.5
		t.nz = math.max(1, math.floor(t.span / Stair.CELL + 0.5))
		t.step = t.span / t.nz
		t.base = total
		total += Stair.ACROSS * t.nz
		t.order = nil
	end
	return { model = model, treads = list, cells = total, built = built }
end

-- The tread table, or nil while the stair has not arrived. Rebuilds itself if
-- the model is replaced (Island4Builder destroys and repours its island).
function Stair.treads()
	--[[
		ONCE IT IS BUILT IT STAYS BUILT, and under StreamingEnabled that is the
		whole trick rather than laziness.

		The layout is a pure function of thirty-four CFrames and sizes, and treads
		do not move. Every field of a tread record that anything reads afterwards
		-- seat, span, nz, step, base -- is a COPY, so the layout stays correct
		when the streamer takes the parts away again, which it does the moment the
		player walks back down to the beach.

		Re-validating on the tread COUNT was tried and is wrong: it correctly
		refused a half-streamed stair, and then also threw the finished layout
		away every time a tread streamed out -- after which markClean could not
		resolve an index and the ash silently stopped being cut. build() already
		refuses to produce a partial layout (see StairTreads), so a cache that
		exists is a complete one and only a REBUILD of the island can invalidate
		it -- which is exactly what comparing the model instance catches.
	]]
	if cache and cache.model.Parent and cache.model == Stair.model() then
		return cache.treads, cache.cells
	end
	cache = build()
	if not cache then
		return nil, 0
	end
	return cache.treads, cache.cells
end

-- Total cells over the whole stair, or 0 if it is not up yet.
function Stair.count(): number
	local _, n = Stair.treads()
	return n
end

-- The linear index of one cell. ix is 0..ACROSS-1 across the road, iz is
-- 0..t.nz-1 up it. One-based, so it can index a table.create array directly.
function Stair.index(t, ix: number, iz: number): number
	return t.base + iz * Stair.ACROSS + ix + 1
end

-- Where a cell sits in the tread's own frame. y is the WALKING surface; callers
-- add their own rise.
function Stair.localCF(t, ix: number, iz: number): CFrame
	return CFrame.new(
		(ix - (Stair.ACROSS - 1) * 0.5) * Stair.CELL,
		t.top,
		(iz + 0.5) * t.step - t.span * 0.5)
end

-- ...and in the world.
function Stair.cellCF(t, ix: number, iz: number): CFrame
	return t.seat * Stair.localCF(t, ix, iz)
end

--[[
	WHICH CELLS A SWEEP COVERS.

	The same test the sand uses -- a rotated rectangle hw wide and hd deep about
	the tool point, measured with two dot products -- plus the Y term the sand
	does not need. CTB_Server flattens its tool point to y = 0 before it does
	anything else, so this is handed the point BEFORE that happens.

	The Y gate is what stops a player at the top of the stair sweeping the flight
	they climbed twenty minutes ago, forty studs below their feet.

	Treads are culled first by a cheap distance test against their own centres,
	so a player anywhere else on the island pays 34 subtractions a tick and
	nothing else.
]]
function Stair.covered(point: Vector3, look: Vector3, right: Vector3,
	hw: number, hd: number, into: { number })
	local treads = Stair.treads()
	if not treads then
		return into
	end
	local reach = hw + hd
	for _, t in ipairs(treads) do
		local c = t.seat.Position
		local cull = reach + t.span * 0.5 + Stair.CELL
		if math.abs(c.Y - point.Y) <= Stair.REACH_Y + t.span
			and math.abs(c.X - point.X) <= cull
			and math.abs(c.Z - point.Z) <= cull then
			for iz = 0, t.nz - 1 do
				for ix = 0, Stair.ACROSS - 1 do
					local w = (t.seat * Stair.localCF(t, ix, iz)).Position
					if math.abs(w.Y - point.Y) <= Stair.REACH_Y then
						local dx, dz = w.X - point.X, w.Z - point.Z
						local u = dx * right.X + dz * right.Z
						local v = dx * look.X + dz * look.Z
						if math.abs(u) <= hw and math.abs(v) <= hd then
							into[#into + 1] = Stair.index(t, ix, iz)
						end
					end
				end
			end
		end
	end
	return into
end

-- Is this point anywhere near the stair at all? The HUD uses it to decide
-- whether to show the stair's progress instead of the island's.
function Stair.near(point: Vector3, pad: number?): boolean
	local treads = Stair.treads()
	if not treads then
		return false
	end
	local r = pad or 40
	for _, t in ipairs(treads) do
		local c = t.seat.Position
		local reach = r + t.span * 0.5
		if math.abs(c.X - point.X) <= reach
			and math.abs(c.Z - point.Z) <= reach
			and math.abs(c.Y - point.Y) <= r then
			return true
		end
	end
	return false
end

return Stair
