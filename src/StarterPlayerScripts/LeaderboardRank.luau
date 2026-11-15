--[[
	LeaderboardRank  --  StarterPlayerScripts.LeaderboardRank  (ModuleScript)


	WHERE *YOU* STAND, on a plaque above each world board.

	The board answers "who is winning". For everybody outside the top ten -- which
	is very nearly everybody -- that is a poster rather than a goal, because there
	is no number on it that has anything to do with them. This is the other half:

		YOU'RE 4TH          310 behind SandyPaws
		NOT ON THE BOARD    1,240 more to make the top 10

	The second of those is the one that does the work. "You are 4,318th" is a
	statistic; "1,240 more" is an afternoon.


	IT READS ATTRIBUTES AND OWNS NO STATE. LeaderboardService writes three per
	ranking (see LeaderboardConfig's WHERE YOU STAND note for why attributes
	rather than a remote); everything here is formatting. That means no request on
	join, nothing to re-sync after a respawn, and a card that is already correct
	the first time it is drawn.


	A BILLBOARD, NOT A HUD, AND THAT IS THE WHOLE PLACEMENT ARGUMENT.

	It cannot go on the board's own face: that SurfaceGui is drawn ON THE SERVER
	and every player sees the same one, which is exactly the rule that makes the
	top ten cheap (LeaderboardService's header). A personal line on a shared
	surface is a contradiction.

	So it could have been a corner of the screen -- and that would have cost HUD
	real estate permanently, on a screen that already carries the event pill, the
	tip card, the duel invite and the toast ladder, to say something that only
	means anything while a board is in front of you. Standing it over the board
	instead makes it appear exactly when it is relevant and cost nothing when it
	is not, and MaxDistance does the appearing for free.

	TWELVE OF THEM, one per board, and they are not all in the air at once: at 90
	studs only the row you have walked up to is drawn. The board itself reaches
	420 because it has to be readable from the far edge of the field; a line about
	you is not something anybody reads from across the sand.

	ALWAYS-ON-TOP IS OFF, for the reason LeaderboardBuilder gives for the board
	under it: this is a thing standing on the beach, and one drawn through the
	palm in front of it stops reading that way.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local LeaderboardConfig = require(Modules:WaitForChild("LeaderboardConfig"))

local player = Players.LocalPlayer

local LeaderboardRank = {}

-- PanelKit's palette, written out for the reason LeaderboardConfig.Boards gives
-- for the tints: this needs three colours, not a UI kit.
local INK       = Color3.fromRGB(56, 36, 20)
local SAND      = Color3.fromRGB(255, 240, 205)
local WOOD_DARK = Color3.fromRGB(92, 58, 32)

local NEAR = 90                 -- studs; see the header

local cards = {}                -- [board model] = { gui, def, rank, note }
local started = false

-- TWO SEPARATE DEBOUNCES, and they must stay separate. They were one flag until
-- it was tested: a refresh happens to be pending every five seconds when the
-- standings land, and sharing the flag meant any board that replicated during
-- one of those windows had its DescendantAdded DROPPED and never got a card. In
-- practice that was three islands out of four -- the beach was up before the
-- first standings pass and the other three were not.
local refreshPending = false
local scanPending = false

--------------------------------------------------------------------------
-- WORDS
--------------------------------------------------------------------------
local function ordinal(n: number): string
	-- 11th, 12th and 13th are the exceptions that make this more than a lookup on
	-- the last digit.
	local hundred = n % 100
	if hundred >= 11 and hundred <= 13 then
		return n .. "TH"
	end
	local last = n % 10
	if last == 1 then
		return n .. "ST"
	elseif last == 2 then
		return n .. "ND"
	elseif last == 3 then
		return n .. "RD"
	end
	return n .. "TH"
end

--[[
	The two lines, or nil to draw nothing at all.

	NOTHING IS THE RIGHT ANSWER MORE OFTEN THAN IT LOOKS: before the first poll
	lands, while a profile is still loading, and on a ranking nobody has entered
	yet. A card that says "YOU'RE 1ST" because every number it can see is zero
	would be worse than no card.
]]
local function linesFor(def): (string?, string?)
	local rank = tonumber(player:GetAttribute(LeaderboardConfig.rankAttribute(def.key)))
	local gap = tonumber(player:GetAttribute(LeaderboardConfig.gapAttribute(def.key)))
	local ahead = player:GetAttribute(LeaderboardConfig.aheadAttribute(def.key))
	if type(ahead) ~= "string" or ahead == "" then
		ahead = nil
	end

	local function amount(n: number): string
		return LeaderboardConfig.formatValue(n, def.format)
	end

	if not rank then
		if not gap then
			return nil, nil
		end
		-- Past the last row the board shows. The rank is deliberately not claimed --
		-- see the standings note in LeaderboardService -- so the line is the reachable
		-- target instead, which is the more useful half anyway.
		return "NOT ON THE BOARD", string.format("%s more to make the top %d",
			amount(gap), LeaderboardConfig.TopN)
	end

	if rank == 1 then
		if not ahead then
			return "YOU'RE 1ST", "nobody else is ranked yet"
		end
		if gap and gap > 0 then
			return "YOU'RE 1ST", amount(gap) .. " clear of " .. ahead
		end
		-- A zero gap at the top is a TIE, not a lead -- which the rebirth board will
		-- produce plenty of once accounts reach the 40 ceiling.
		return "YOU'RE 1ST", "level with " .. ahead
	end

	if not ahead then
		return "YOU'RE " .. ordinal(rank), ""
	end
	return "YOU'RE " .. ordinal(rank), amount(gap or 0) .. " behind " .. ahead
end

--------------------------------------------------------------------------
-- THE PLAQUE
--------------------------------------------------------------------------
local function defFor(key: string)
	for _, def in ipairs(LeaderboardConfig.Boards) do
		if def.key == key then
			return def
		end
	end
	return nil
end

local function buildCard(model: Model, def)
	-- The board's face part, not the ImageLabel of the same name inside a row --
	-- which is why this is a non-recursive lookup.
	local face = model:FindFirstChild("Face")
	if not (face and face:IsA("BasePart")) then
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "LeaderboardRank_" .. def.key
	gui.Adornee = face
	-- A BillboardGui's Scale is in STUDS, so this is 18 across a 20-stud board:
	-- narrower than the thing under it, which is what makes it read as belonging
	-- to that board rather than floating near it.
	gui.Size = UDim2.fromScale(18, 3.4)
	-- Above the top edge. The face is centred, so half the board plus clearance --
	-- and all four sites are open shores, so there is nothing up there to foul.
	gui.StudsOffsetWorldSpace = Vector3.new(0, LeaderboardConfig.BoardHeight * 0.5 + 2.4, 0)
	gui.MaxDistance = NEAR
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = WOOD_DARK
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0, 14)
	round.Parent = frame

	local edge = Instance.new("UIStroke")
	edge.Thickness = 4
	edge.Color = INK
	edge.Parent = frame

	local rank = Instance.new("TextLabel")
	rank.BackgroundTransparency = 1
	rank.Size = UDim2.new(1, -20, 0.52, 0)
	rank.Position = UDim2.new(0, 10, 0.05, 0)
	rank.Font = Enum.Font.LuckiestGuy
	rank.TextColor3 = def.tint
	rank.TextScaled = true
	-- NOT WRAPPED. A long username on the line below is handled by scaling that
	-- label down; letting either of them wrap would shrink the type to fit two
	-- rows into a box built for one.
	rank.TextWrapped = false
	rank.Text = ""
	rank.Parent = frame

	local rankEdge = Instance.new("UIStroke")
	rankEdge.Thickness = 4
	rankEdge.Color = INK
	rankEdge.Parent = rank

	local note = Instance.new("TextLabel")
	note.BackgroundTransparency = 1
	note.Size = UDim2.new(1, -20, 0.3, 0)
	note.Position = UDim2.new(0, 10, 0.6, 0)
	note.Font = Enum.Font.GothamBold
	note.TextColor3 = SAND
	note.TextScaled = true
	note.TextWrapped = false
	note.Text = ""
	note.Parent = frame

	cards[model] = { gui = gui, def = def, rank = rank, note = note }
end

--[[
	STREAMING IS WHY THIS IS A SWEEP AND NOT A ONE-SHOT.

	The place has StreamingEnabled, so eleven of the twelve boards are not on this
	client when the game starts: the MODELS replicate, their parts do not, and a
	board 1,500 studs away is an empty Model with a Podium in it. The parts arrive
	when the player does, as DescendantAdded on the folder.

	AND THEY LEAVE AGAIN, which is the half that had to be tested for rather than
	reasoned about. Walk off an island and its Face is DESTROYED under a card that
	is still pointing at it; walk back and a BRAND NEW Face streams in. A sweep
	that only asked "does this model have a card" would skip that model forever
	and its plaque would never render again for the rest of the session -- so an
	existing card is re-pointed rather than passed over.
]]
local function scan()
	local folder = workspace:FindFirstChild("Leaderboards")
	if not folder then
		return
	end
	-- One folder per island, one model per ranking inside it.
	for _, site in ipairs(folder:GetChildren()) do
		for _, model in ipairs(site:GetChildren()) do
			if model:IsA("Model") then
				local key = model.Name:match("^Leaderboard_(.+)$")
				local def = key and defFor(key)
				if def then
					local card = cards[model]
					if not card then
						buildCard(model, def)
					else
						local face = model:FindFirstChild("Face")
						if face and face:IsA("BasePart") and card.gui.Adornee ~= face then
							card.gui.Adornee = face
						end
					end
				end
			end
		end
	end
end

local function refresh()
	for model, card in pairs(cards) do
		local adornee = card.gui.Adornee
		if not model.Parent then
			-- The board itself is gone, which streaming does not do -- only a rebuild
			-- would. Drop the card with it.
			card.gui:Destroy()
			cards[model] = nil
		elseif not (adornee and adornee.Parent) then
			-- Streamed out from under us. Nothing renders off a destroyed adornee
			-- anyway; switching it off keeps "enabled" meaning "on screen", and scan
			-- re-points it when the island comes back.
			card.gui.Enabled = false
		else
			local big, small = linesFor(card.def)
			if big then
				card.rank.Text = big
				card.note.Text = small or ""
				card.gui.Enabled = true
			else
				card.gui.Enabled = false
			end
		end
	end
end

-- One standings pass moves up to nine attributes, and each one arrives as its
-- own event. Coalesced onto the next frame so a pass costs one redraw of twelve
-- labels rather than nine.
local function queueRefresh()
	if refreshPending then
		return
	end
	refreshPending = true
	task.defer(function()
		refreshPending = false
		local ok, err = pcall(refresh)
		if not ok then
			warn("[LeaderboardRank] refresh failed: " .. tostring(err))
		end
	end)
end

-- A row replicates part by part, so one board arriving is a burst of events.
-- Coalesced onto the next frame, but never DROPPED -- a sweep that does not run
-- is a board with no card on it for the rest of the session.
local function queueScan()
	if scanPending then
		return
	end
	scanPending = true
	task.defer(function()
		scanPending = false
		local ok, err = pcall(scan)
		if not ok then
			warn("[LeaderboardRank] scan failed: " .. tostring(err))
		end
		queueRefresh()
	end)
end

function LeaderboardRank.start()
	if started then
		return
	end
	started = true

	-- One connection rather than nine signals: every attribute this file reads is
	-- prefixed, and anything else moving on the player is none of its business.
	player.AttributeChanged:Connect(function(name)
		if name:sub(1, 2) == "Lb" then
			queueRefresh()
		end
	end)

	task.spawn(function()
		-- The boards are built by the server at boot and this file starts before
		-- that finishes. If they never arrive there is nothing to stand a card over
		-- and nothing to say about it either -- LeaderboardBuilder logs its own
		-- failures, and a second warning here would only ever be noise.
		local folder = workspace:WaitForChild("Leaderboards", 120)
		if not folder then
			return
		end
		-- CONNECTED BEFORE THE FIRST SWEEP, not after it. WaitForChild returns the
		-- instant the FOLDER appears, which is while the server is still parenting
		-- the twelve boards into it -- so a sweep on its own sees whichever island
		-- happened to be first and nothing else.
		--
		-- The four rows go up once, at boot, so this fires a handful of times and
		-- then never again.
		folder.DescendantAdded:Connect(queueScan)
		scan()
		queueRefresh()
	end)
end

return LeaderboardRank
