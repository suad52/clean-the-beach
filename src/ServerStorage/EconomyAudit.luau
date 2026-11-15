--[[
	EconomyAudit  --  ServerStorage.EconomyAudit

	DEV-ONLY. Never required by anything that ships; it lives in ServerStorage
	so it cannot reach a client and no server script boots it. Run it from the
	command bar (or the MCP bridge) after touching ANY economy dial:

		print(require(game.ServerStorage.EconomyAudit).run())

	WHAT IT IS. The rebirth curve is pitched against INCOME (see the Rebirth
	block in ProgressionConfig), and income is five compounding terms: the sell
	multiplier, the ceiling's new levels, the island premiums, pets, and the
	batch bonus. No comment can keep a table of that honest by hand -- this
	module re-derives it from the LIVE config every time it runs, prints the
	tide-by-tide table, and flags the failure modes that have actually shipped
	here before (a gate that income cancels; a gate that outruns income into a
	wall; a ceiling that dies with a third of the game left; an upgrade rung
	that buys nothing).

	THE INCOME MODEL'S ASSUMPTIONS, stated rather than hidden:

	  * BASE_RATE 262 coins/min is the measured tide-0 active rate from
	    AfkConfig's own benchmark note (rake + wash + sell, best case) --
	    measured when the old cheap shop was effectively maxed at tide 0,
	    which is why the affordability term below correctly drags tide 0
	    down to ~175/min under the 2026-08 quadrupled bases.
	  * LEVEL_STEP 1.16 per two levels OWNED is ProgressionConfig's own
	    long-standing figure for what the levels are worth.
	  * A PLAYER OWNS WHAT THEY CAN AFFORD, NOT THE CEILING. Each tide the
	    model spends ALPHA (0.75) of that tide's gate on the ladder and
	    derives the level that money buys; at the 4x bases that sits well
	    under the ceiling for the whole run, which is why income keeps
	    growing even after the ceiling caps at rebirth 36.
	  * The island premium steps are ItemConfig's measured head-to-heads
	    (its ISLAND_PREMIUM note): each field beats the previous by that
	    factor, riding, same ceiling and pets.
	  * Pets ramp linearly to a scenario cap by rebirth 20 (weak 1.0x flat,
	    typical 2.0x, strong 3.0x) -- a smoothing of the luck ladder + skew.
	  * Every figure is BEST-CASE; real play runs ~1.5-2x longer (GameConfig
	    measured real washes at ~3.5x the ideal).

	THE CURVE IS PITCHED AGAINST THE "typical" SCENARIO. Run "weak" and expect
	H1 to flag sustained tide growth through the early teens -- that is not a
	config defect, it is the egg pressure showing: a player who never buys a
	pet is the player the Desert and Prestige shelves exist to convert.

	If a system this reads moves (a gate, a premium, the luck constants), the
	table moves with it; only the four assumption constants above are frozen.

	IT AUDITS TIDES 0 TO LadderTides AND THAT IS THE RIGHT WINDOW, even though
	the ladder itself has had no cap since 2026-09-11. Everything this file
	tests is a PACING claim -- tides that neither shrink nor wall, a ceiling
	that dies late, a last room with tides to spare -- and those are claims
	about the authored run. Past it the curves are deliberately a straight
	extrapolation of the tail (see ProgressionConfig.Rebirth.LadderTides): each
	tide ~1.09x longer than the last, for ever, with nothing new unlocking. That
	is intended, so flagging it as sustained growth would be H1 failing the
	design rather than catching a defect.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Modules = ReplicatedStorage:WaitForChild("Modules")

--[[
	FRESH-REQUIRED, NOT CACHED. This tool exists to be run right after editing
	a config, and Roblox's require cache hands back the module as it was the
	FIRST time anything required it this session -- an audit that quietly
	reports the numbers from before your edit is worse than no audit. Each
	dependency is therefore required off a throwaway clone, which always
	compiles the CURRENT Source. These are pure data modules; cloning them has
	no side effects. (Run the audit itself off a clone too, for the same
	reason: require(game.ServerStorage.EconomyAudit:Clone()).run())
]]
local function freshRequire(inst: ModuleScript)
	local c = inst:Clone()
	c.Parent = script
	local ok, mod = pcall(require, c)
	c:Destroy()
	if ok then
		return mod
	end
	warn("[EconomyAudit] fresh require failed for " .. inst.Name .. "; using the session-cached copy")
	return require(inst)
end

local ProgressionConfig = freshRequire(Modules.ProgressionConfig)
local PetConfig = freshRequire(Modules.PetConfig)
local FerryConfig = freshRequire(ReplicatedStorage.FerryConfig)
local AtvConfig = freshRequire(ReplicatedStorage.AtvConfig)

local EconomyAudit = {}

-- Frozen model constants (see header).
local BASE_RATE = 262
local LEVEL_STEP = 1.16
local OVERHEAD_MIN = 1.5
local ALPHA = 0.75 -- share of a tide's gate spent on the upgrade ladder
local PET_SCENARIOS = { weak = 0.0, typical = 0.05, strong = 0.10 }

--[[
	H8's FLOOR: how little of a played minute an idle minute may be worth before
	the shore counts as having decayed out of use.

	WAS 0.20, RE-PITCHED TO 0.10 ON 2026-08-26 when AfkConfig's BaseRate and
	SessionCap were cut x0.6 to stop a capped session being worth up to 57% of
	the rebirth it was earned in. It is a re-pitch and NOT a silenced guard: the
	shore's share band is about 3:1 wide (34% on the tutorial tide, 11% through
	the rb 8-16 trough) because a single TideGrowth exponent cannot track the
	step the Dunes premium puts in F(n), so any purely vertical cut to the mode
	moves the floor down with the ceiling. 0.10 is the new band's own floor with
	nothing to spare, so a further cut, or a real decay, still trips this.

	IF THIS EVER NEEDS RAISING BACK, the honest fix is not a bigger exponent --
	see the ⚠️ on AfkConfig.TideGrowth, which records the measurement that
	raising it tilts the rb 40 tail (and fails H8's peak test) while leaving the
	trough where it is. It is BaseRate that lifts the whole curve.
]]
local SHORE_FLOOR = 0.10

-- The measured island steps, keyed by which gate unlocks the field.
local PREMIUM_STEPS = {
	{ name = "Dunes",   step = 2.31 },
	{ name = "Vault",   step = 1.25 },
	{ name = "Cove",    step = 1.44 },
	{ name = "Shrine",  step = 1.14 },
	{ name = "Ashfall", step = 1.24 },
	{ name = "Magma",   step = 1.24 },
	{ name = "Penguin", step = 1.25 },   -- 702 / 563 coins a find
	{ name = "Wreck",   step = 1.23 },   -- 864 / 702
}

local function doorGate(moduleName: string): number?
	local inst = ServerScriptService:FindFirstChild(moduleName)
	if not inst then return nil end
	local ok, mod = pcall(require, inst)
	if ok and type(mod) == "table" and type(mod.REBIRTHS) == "number" then
		return mod.REBIRTHS
	end
	-- Builders that resist requiring outside a live boot still declare the
	-- constant as a single assignment; read it off the source.
	local n = string.match(inst.Source, "%.REBIRTHS%s*=%s*(%d+)")
	return n and tonumber(n) or nil
end

function EconomyAudit.gates(): { [string]: number }
	local g = {}
	for _, port in ipairs(FerryConfig.Ports) do
		if port.requireLevel > 0 then
			g[port.key] = port.requireLevel
		end
	end
	g.Vault = doorGate("VaultBuilder") or -1
	g.Shrine = doorGate("ShrineBuilder") or -1
	g.Magma = doorGate("MagmaBuilder") or -1
	g.Wreck = doorGate("FrozenWreckBuilder") or -1
	return g
end

function EconomyAudit.ladderCost(ceiling: number): number
	local total = 0
	for _, t in ProgressionConfig.Tracks do
		for level = 1, ceiling - 1 do
			total += ProgressionConfig.costFor(t, level) or 0
		end
	end
	return total
end

local function orderedGateSteps()
	local g = EconomyAudit.gates()
	local byName = { Dunes = g.Dunes, Vault = g.Vault, Cove = g.Cove, Shrine = g.Shrine, Ashfall = g.Ashfall, Magma = g.Magma,
		Penguin = g.Penguin, Wreck = g.Wreck }
	local out = {}
	for _, row in ipairs(PREMIUM_STEPS) do
		table.insert(out, { name = row.name, gate = byName[row.name] or math.huge, step = row.step })
	end
	return out
end

local function premiumAt(n: number, steps): number
	local p = 1.0
	for _, row in ipairs(steps) do
		if n >= row.gate then p *= row.step end
	end
	return p
end

-- One four-track geometric-series unit, derived from the LIVE bases so a base
-- retune moves the whole model: ladder cost to level k ~= backbone*(CG^(k-1)-1).
local function ladderBackbone(): number
	local s = 0
	for _, t in ProgressionConfig.Tracks do
		s += (t.base or 0)
	end
	return s / (ProgressionConfig.CostGrowth - 1)
end

-- The level a player who puts `spend` coins into the ladder actually owns,
-- capped by the tide's ceiling. Inverts the ladder-cost series above.
local function levelsAffordable(spend: number, cap: number): number
	if spend <= 0 then
		return 1
	end
	local k = 1 + math.log(spend / ladderBackbone() + 1) / math.log(ProgressionConfig.CostGrowth)
	return math.min(cap, math.max(1, k))
end

-- Estimated coins/min during the tide played at `n` rebirths, given the gate
-- that tide is chasing -- affordability feeds back off it. Returns the rate
-- and the level the model says the player is running at.
function EconomyAudit.incomeRate(n: number, petRamp: number, steps, gate: number): (number, number)
	local cap = ProgressionConfig.Rebirth.levelCeiling(n)
	local k = levelsAffordable(ALPHA * gate, cap)
	local levels = LEVEL_STEP ^ ((k - 8) / 2)
	local pets = 1 + math.min(n, 20) * petRamp
	return BASE_RATE * ProgressionConfig.Rebirth.multiplier(n) * levels * premiumAt(n, steps) * pets, k
end

local function money(v: number): string
	if v >= 1e9 then return string.format("%.2fB", v / 1e9) end
	if v >= 1e6 then return string.format("%.2fM", v / 1e6) end
	if v >= 1e3 then return string.format("%.1fK", v / 1e3) end
	return tostring(math.floor(v + 0.5))
end

function EconomyAudit.run(scenario: string?): string
	local petRamp = PET_SCENARIOS[scenario or "typical"] or PET_SCENARIOS.typical
	local R = ProgressionConfig.Rebirth
	local steps = orderedGateSteps()
	local gateByTide = {}
	for _, row in ipairs(steps) do
		if row.gate ~= math.huge then gateByTide[row.gate] = row.name end
	end

	local out = { "ECONOMY AUDIT  (scenario: " .. (scenario or "typical") .. " pets; best-case rates; real play ~1.5-2x longer)" }
	table.insert(out, string.format("%3s %5s %5s %11s %11s %6s %9s %12s %8s %7s  %s",
		"rb", "ceil", "owned", "gate", "ladder", "ratio", "mult", "coins/min", "tide min", "cum h", "unlocks"))

	local warnings = {}
	local cum = 0
	local prevMins = nil
	local highGrowthStreak = 0
	for n = 1, R.LadderTides do
		local ceilDuring = R.levelCeiling(n - 1)
		local need = R.requirement(n)
		local ladder = EconomyAudit.ladderCost(ceilDuring)
		local rate, kOwn = EconomyAudit.incomeRate(n - 1, petRamp, steps, need)
		local mins = need / rate + OVERHEAD_MIN
		cum += mins
		local mark = gateByTide[n] and ("<- " .. gateByTide[n]) or ""
		table.insert(out, string.format("%3d %5d %5.1f %11s %11s %6.2f %8.2fx %12s %8.1f %7.2f  %s",
			n, R.levelCeiling(n), kOwn, money(need), money(ladder), need / ladder,
			R.multiplier(n), money(rate), mins, cum / 60, mark))

		-- H1: tide-length drift. Shrinking tides mean income cancelled the gate
		-- (the pre-2026-08 failure). Growth is a WALL only when it is sustained
		-- -- the old tail held 1.17x for fourteen straight tides -- so a single
		-- seam tide over 1.15 passes, two in a row or any tide over 1.25 does
		-- not. Checks start at rebirth 10: the first eight gates are authored
		-- to a deliberate shape (one long tutorial tide, then quick ones), not
		-- to smooth growth.
		if prevMins and n > 9 then
			local g = mins / prevMins
			if g < 0.99 and not gateByTide[n - 1] then
				table.insert(warnings, string.format("H1 rb %d: tides SHRINKING (%.2fx) -- income outgrows the gate here", n, g))
			elseif g > 1.25 then
				table.insert(warnings, string.format("H1 rb %d: tide grew %.2fx -- over the hard 1.25 threshold", n, g))
			elseif g > 1.15 and highGrowthStreak >= 1 then
				table.insert(warnings, string.format("H1 rb %d: second consecutive tide over 1.15x growth (%.2fx) -- sustained wall drift", n, g))
			end
			highGrowthStreak = (g > 1.15) and (highGrowthStreak + 1) or 0
		end
		prevMins = mins
	end

	-- H2: the ceiling must die late but not on the last tide.
	local capTide
	for n = 0, R.LadderTides do
		if R.levelCeiling(n) >= ProgressionConfig.MaxLevel then capTide = n break end
	end
	if not capTide then
		table.insert(warnings, "H2: ceiling NEVER reaches MaxLevel -- tracks cannot be finished")
	elseif capTide < R.LadderTides * 0.6 then
		table.insert(warnings, string.format("H2: ceiling caps at rb %d -- more than 40%% of the run has a frozen shop", capTide))
	elseif capTide >= R.LadderTides then
		table.insert(warnings, string.format("H2: ceiling caps on the last authored tide (%d) -- max level is never played", capTide))
	end

	-- H3: monotonicity.
	for n = 2, R.LadderTides do
		if R.requirement(n) <= R.requirement(n - 1) then
			table.insert(warnings, "H3: requirement not strictly increasing at rb " .. n)
		end
		if R.levelCeiling(n) < R.levelCeiling(n - 1) then
			table.insert(warnings, "H3: ceiling decreases at rb " .. n)
		end
	end

	-- H4: no dead rungs -- every level must change its stat (the TideLuck rule).
	for _, t in ProgressionConfig.Tracks do
		for level = 1, ProgressionConfig.MaxLevel - 1 do
			if t.effect(level + 1) <= t.effect(level) then
				table.insert(warnings, string.format("H4: %s level %d -> %d buys nothing (%.3f -> %.3f)",
					t.key, level, level + 1, t.effect(level), t.effect(level + 1)))
			end
		end
	end

	-- H5: the map ladder must climb and finish with tides to spare.
	local g = EconomyAudit.gates()
	local ladder = { g.Dunes, g.Vault, g.Cove, g.Shrine, g.Ashfall, g.Magma, g.Penguin, g.Wreck }
	for i = 2, #ladder do
		if not ladder[i] or not ladder[i - 1] or ladder[i] <= ladder[i - 1] then
			table.insert(warnings, "H5: map gates not strictly increasing: " .. table.concat(ladder, ","))
			break
		end
	end
	if (g.Wreck or 0) > R.LadderTides - 4 then
		table.insert(warnings, string.format("H5: Wreck gate %d strands the last room at the top of the ladder (authored to %d)", g.Wreck or -1, R.LadderTides))
	end

	-- H6: the luck ceiling must stay unreachable (LuckService's own invariant).
	local ls = ServerScriptService:FindFirstChild("LuckService")
	if ls then
		local src = ls.Source
		local perLuck = tonumber(string.match(src, "RUNG_CHANCE_PER_LUCK%s*=%s*([%d%.]+)"))
		local maxChance = tonumber(string.match(src, "MAX_RUNG_CHANCE%s*=%s*([%d%.]+)"))
		-- The best loadout the game can assemble: duplicates are equippable, so
		-- it is one copy of the best one-off pet (the VIP grant) plus copies of
		-- the best HATCHABLE pet in every other slot -- 1 VIP + 4 Mythics today,
		-- which is the 16.2 LuckService's own note reasons against.
		local bestOneOff, bestHatchable = 1, 1
		for _, def in PetConfig.Pets do
			local luck = def.Luck or 1
			if def.Tier == "VIP" then
				bestOneOff = math.max(bestOneOff, luck)
			else
				bestHatchable = math.max(bestHatchable, luck)
			end
		end
		local sum = 1 + (bestOneOff - 1) + (PetConfig.MaxEquipped - 1) * (bestHatchable - 1)
		if perLuck and maxChance then
			local atBest = (sum - 1) * perLuck
			table.insert(out, string.format("\nluck: best loadout %.2f -> rung chance %.3f (cap %.2f) -- %s",
				sum, atBest, maxChance, atBest < maxChance and "cap unreachable, every pet pays" or "SATURATED"))
			if atBest >= maxChance then
				table.insert(warnings, string.format("H6: luck saturates below the best loadout (%.2f x %.3f >= %.2f) -- top pets buy nothing", sum, perLuck, maxChance))
			end
		end
	end

	-- H7: vehicle gates ride with their islands.
	for _, tier in AtvConfig.Tiers do
		local want = (tier.key == "Sandhog") and g.Shrine or (tier.key == "Tidebreaker") and g.Ashfall or nil
		if want and tier.minRebirths ~= want then
			table.insert(warnings, string.format("H7: %s minRebirths %d != its island gate %d", tier.key, tier.minRebirths, want))
		end
	end

	-- Affordability: first tide whose GATE alone covers the price, and minutes
	-- of best-case farming at the gate tide it is anchored to.
	table.insert(out, "\naffordability (one tide's gate >= price / minutes at anchor tide):")
	local probes = {}
	for _, egg in ipairs(PetConfig.Eggs) do
		table.insert(probes, { name = egg.name, price = egg.cost, anchor = nil })
	end
	for _, tier in AtvConfig.Tiers do
		table.insert(probes, { name = tier.name, price = tier.price, anchor = tier.minRebirths })
	end
	for _, probe in ipairs(probes) do
		local firstTide
		for n = 1, R.LadderTides do
			if R.requirement(n) >= probe.price then firstTide = n break end
		end
		local anchor = probe.anchor or firstTide or R.LadderTides
		local anchorGate = R.requirement(math.min(anchor + 1, R.LadderTides))
		local rateAt = EconomyAudit.incomeRate(anchor, petRamp, steps, anchorGate)
		local mins = probe.price / rateAt
		table.insert(out, string.format("  %-16s %10s  gate covers it at rb %s; ~%.0f min at rb %d",
			probe.name, money(probe.price), firstTide and tostring(firstTide) or ">max", mins, anchor))
	end

	--[[
		THE LONG SHORE, and it is audited HERE rather than in AfkConfig for the
		same reason everything else in this file is: the only interesting thing
		about an idle wage is its RATIO to a played minute, and the income model
		that knows what a played minute is worth lives up there.

		TWO NUMBERS. What an idle minute is worth against a played one, and what
		a whole capped session is worth in played minutes -- the second is the
		one a player feels, since the cap is what bounds the mode.

		THE BAND IS DELIBERATELY NOT SYMMETRIC. The shore is at its most generous
		on tide 0 on purpose (a break during the tutorial tide is cheap to give),
		so the test is: it must PEAK at rb 0, and it must never fall so far below
		that peak that walking to the hut stops being worth doing. SHORE_FLOOR is
		that floor and its note carries why it is where it is.

		A THIRD FIGURE IS PRINTED AND NOT TESTED: a capped session as a share of
		the REBIRTH GATE it is earned against. It is the one a player actually
		feels -- "an idle session is a fifth of a tide" -- and it is what showed
		the pre-2026-08-26 shore was overpaying: 57% of a whole tide at rb 2, for
		standing still. Left untested because the gate curve and the income curve
		are pitched against each other elsewhere in this file; it is here to be
		read when the two dials are being set.

		The failure this catches is the one that shipped: pay scaled by
		SellMultiplier alone, against income that also compounds the ceiling, the
		island premiums and pets. It looked scaled and decayed by ~1.18x a tide,
		and by Ashfall the shore paid a tenth of a per cent of playing.
	]]
	local Afk = freshRequire(Modules.AfkConfig)
	local capped = type(Afk.SessionCap) == "number" and Afk.SessionCap > 0
	table.insert(out, "\nthe long shore (AfkConfig):")
	table.insert(out, string.format("  %3s %11s %12s %9s %13s %11s %9s",
		"rb", "coins/sec", "per min", "% active", "session cap", "= act. min", "% of tide"))
	local shoreLo, shoreHi, shoreLoN, shoreHiN = math.huge, 0, 0, 0
	for n = 0, R.LadderTides do
		local scale = Afk.scaleAt(n)
		local rate = Afk.BaseRate * scale
		local inc = EconomyAudit.incomeRate(n, petRamp, steps, R.requirement(n + 1))
		local share = rate * 60 / inc
		if share < shoreLo then shoreLo, shoreLoN = share, n end
		if share > shoreHi then shoreHi, shoreHiN = share, n end
		if n % 8 == 0 or n == R.LadderTides then
			local cap = capped and (Afk.SessionCap * scale) or nil
			-- Against the gate for the NEXT rebirth, which is the one the tide
			-- played at n is actually chasing -- the same requirement(n + 1) the
			-- income model above is handed for this tide.
			local gate = R.requirement(n + 1)
			table.insert(out, string.format("  %3d %11s %12s %8.1f%% %13s %11s %8.1f%%",
				n, money(rate), money(rate * 60), share * 100,
				cap and money(cap) or "none",
				cap and string.format("%.1f", cap / inc) or "-",
				cap and (cap / gate * 100) or 0))
		end
	end
	table.insert(out, string.format("  share band %.1f%% (rb %d) .. %.1f%% (rb %d)  --  TideGrowth %.3f",
		shoreLo * 100, shoreLoN, shoreHi * 100, shoreHiN, Afk.TideGrowth))
	if shoreHiN ~= 0 then
		table.insert(warnings, string.format(
			"H8: the shore peaks at rb %d, not rb 0 -- idling outgrows the run; lower AfkConfig.TideGrowth", shoreHiN))
	end
	if shoreLo < SHORE_FLOOR then
		table.insert(warnings, string.format(
			"H8: the shore is worth %.1f%% of playing at rb %d -- under the %.0f%% floor, "
				.. "it decays out of use; raise AfkConfig.BaseRate (NOT TideGrowth -- see its note)",
			shoreLo * 100, shoreLoN, SHORE_FLOOR * 100))
	end

	if #warnings == 0 then
		table.insert(out, "\nHEALTH: all checks pass")
	else
		table.insert(out, "\nHEALTH: " .. #warnings .. " warning(s)")
		for _, w in ipairs(warnings) do
			table.insert(out, "  ! " .. w)
		end
	end
	return table.concat(out, "\n")
end

return EconomyAudit