--[[
	FeedbackReader  --  ServerStorage.FeedbackReader  (ModuleScript)

	Reads the PlayerFeedback store and prints it in a form a person can actually
	scan, instead of one JSON blob per key in the dashboard.

	IN SERVERSTORAGE, so nothing runs it by accident -- it is a tool, not part of
	the game. Run it from the Studio Command Bar:

		require(game.ServerStorage.FeedbackReader).print()      -- newest 25
		require(game.ServerStorage.FeedbackReader).print(100)   -- newest 100
		require(game.ServerStorage.FeedbackReader).json()       -- for export

	require() CACHES, so after editing this file use:

		require(game.ServerStorage.FeedbackReader:Clone()).print()

	NEEDS API ACCESS. Game Settings -> Security -> Enable Studio Access to API
	Services, the same switch the writing half needs.

	DELETED KEYS LINGER. ListKeysAsync keeps returning a key for a while after
	RemoveAsync -- the listing is eventually consistent and the entry is not.
	Every key is fetched and a nil result is skipped rather than counted, which
	is why the "read" total can be lower than the "listed" one.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local FeedbackReader = {}

local STORE_NAME = "PlayerFeedback"

local function comma(n: any): string
	if type(n) ~= "number" then
		return tostring(n)
	end
	local s = tostring(math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (s:gsub("^,", ""))
end

local function yn(v: any): string
	if v == nil then
		return "?"
	end
	return v and "ON" or "off"
end

--[[
	Newest first. The keys are "<unixtime>_<userId>" and os.time() is ten digits
	wide until 2286, so a plain descending string sort IS newest-first for the
	life of this game -- no need to parse a timestamp out to order them.
]]
function FeedbackReader.fetch(limit: number?)
	local store = DataStoreService:GetDataStore(STORE_NAME)
	local pages = store:ListKeysAsync("", 100)

	local keys = {}
	repeat
		for _, k in pages:GetCurrentPage() do
			keys[#keys + 1] = k.KeyName
		end
		if pages.IsFinished then
			break
		end
		if not pcall(function() pages:AdvanceToNextPageAsync() end) then
			break
		end
	until false

	table.sort(keys, function(a, b) return a > b end)

	local want = limit or 25
	local entries, listed = {}, #keys
	for _, key in keys do
		if #entries >= want then
			break
		end
		local ok, value = pcall(function() return store:GetAsync(key) end)
		-- nil is a tombstone from a RemoveAsync the listing has not caught up
		-- with; a non-table is something that was not written by this system.
		if ok and type(value) == "table" then
			value._key = key
			entries[#entries + 1] = value
		end
	end
	return entries, listed
end

function FeedbackReader.print(limit: number?)
	local ok, entries, listed = pcall(function()
		return FeedbackReader.fetch(limit)
	end)
	if not ok then
		warn("[FeedbackReader] " .. tostring(entries))
		warn("[FeedbackReader] if that mentions API services, it is Game Settings "
			.. "-> Security -> Enable Studio Access to API Services.")
		return
	end
	local rule = string.rep("-", 76)
	print(rule)
	-- "of N listed" is not padding: the gap between the two is deleted keys the
	-- listing has not caught up with, and seeing 3 of 5 is how you know that is
	-- what you are looking at rather than a read that half failed.
	print(string.format("  PLAYER FEEDBACK  --  %d shown of %d listed", #entries, listed or #entries))
	print(rule)

	if #entries == 0 then
		print("  Nothing yet.")
		print(rule)
		return
	end

	for i, e in entries do
		local c = e.client or {}
		local s = e.server or {}

		print(string.format("#%-3d %s%s", i, e.when or "?", e.studio and "   [studio test]" or ""))
		print(string.format("     %s  (%s, id %s)",
			e.displayName or e.name or "?", e.name or "?", tostring(e.userId)))
		print(string.format('     "%s"', e.text or ""))

		local dev = {}
		if c.platform then dev[#dev+1] = c.platform end
		if c.viewport then dev[#dev+1] = c.viewport end
		if c.quality then dev[#dev+1] = "quality " .. tostring(c.quality) end
		if c.fps then
			dev[#dev+1] = c.fpsLow
				and string.format("%d fps (low %d)", c.fps, c.fpsLow)
				or string.format("%d fps", c.fps)
		end
		if c.memoryMb then dev[#dev+1] = string.format("%d MB", c.memoryMb) end
		if #dev > 0 then
			print("     device    " .. table.concat(dev, "  |  "))
		end

		local input = {}
		for _, f in { { "touch", c.touch }, { "keyboard", c.keyboard }, { "mouse", c.mouse },
			{ "gamepad", c.gamepad }, { "vr", c.vr }, { "console", c.tenFoot } } do
			if f[2] then input[#input+1] = f[1] end
		end
		print("     input     " .. (#input > 0 and table.concat(input, ", ") or "none reported"))

		local who = {}
		if s.accountAge then who[#who+1] = s.accountAge .. "d old" end
		if s.membership then who[#who+1] = s.membership end
		if c.locale then who[#who+1] = "lang " .. c.locale end
		if c.systemLocale and c.systemLocale ~= c.locale then who[#who+1] = "device " .. c.systemLocale end
		if s.sessionMin then who[#who+1] = s.sessionMin .. " min into the session" end
		if #who > 0 then
			print("     player    " .. table.concat(who, "  |  "))
		end

		local prog = {}
		if s.coins then prog[#prog+1] = comma(s.coins) .. " coins" end
		if s.rebirths then prog[#prog+1] = "rebirth " .. tostring(s.rebirths) end
		if s.totalEarned then prog[#prog+1] = comma(s.totalEarned) .. " earned" end
		if s.carrying then prog[#prog+1] = "carrying " .. tostring(s.carrying) end
		if #prog > 0 then
			print("     progress  " .. table.concat(prog, "  |  "))
		end

		if type(s.levels) == "table" then
			local names = {}
			for k in s.levels do names[#names+1] = k end
			table.sort(names)
			local bits = {}
			for _, k in names do bits[#bits+1] = string.format("%s %s", k, tostring(s.levels[k])) end
			if #bits > 0 then
				print("     levels    " .. table.concat(bits, "  "))
			end
		end

		if type(c.settings) == "table" then
			local names = {}
			for k in c.settings do names[#names+1] = k end
			table.sort(names)
			local bits = {}
			for _, k in names do bits[#bits+1] = string.format("%s %s", k, yn(c.settings[k])) end
			print("     settings  " .. table.concat(bits, "  "))
		end

		print(string.format("     key       %s", tostring(e._key)))
		print(rule)
	end
end

-- The whole set as JSON, for anything that wants to render it outside Studio.
function FeedbackReader.json(limit: number?): string
	local entries = FeedbackReader.fetch(limit or 500)
	return HttpService:JSONEncode(entries)
end

return FeedbackReader
