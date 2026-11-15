--[[
	CodeConfig  --  ReplicatedStorage.Modules.CodeConfig

	REDEEMABLE CODES. The game had none, which left no way to reward a social
	follow, announce anything, or reach a lapsed player -- codes are the only
	reactivation tool on Roblox that costs nothing per use.

	EDIT THE TABLE AT THE BOTTOM AND NOTHING ELSE. Adding a code is one row.
	Retiring one is deleting its row, and a player who had already redeemed it
	keeps what it paid -- the payout happened once, at redemption.

	CASE AND SPACING DO NOT MATTER. `normalise` upper-cases and drops anything
	that is not a letter or a digit, so "sunny day", "SUNNY-DAY" and " SunnyDay "
	are all the same code. Players type these off a video or a Discord message;
	being strict about punctuation only ever costs a redemption.

	THE REWARD IS SCALED BY THE RUN, exactly the way RewardsServer scales its
	daily ladder and its playtime tiers, and for the reason its note gives: in an
	economy whose sell multiplier reaches 819x, a flat coin amount "is a fair
	bounty on a first tide and a rounding error by the fourth". A code worth
	2,500 is worth 2,500 to a new player and just over two million at tide 48.

	ONCE PER ACCOUNT, tracked as one attribute per code (Code_<CODE>) rather than
	a list, because that is how every other per-player fact in this game is
	stored -- Pass_<id>, Set_<key>, Lv_<track> -- and SaveService already knows
	how to fold a prefixed attribute into a profile and put it back.

	WHAT A CLIENT MAY SEND is a short string and nothing else. CodeService bounds
	the length before it looks at the contents; this module never trusts its
	input either, which is why normalise is written to be total rather than to
	assume.
]]

local CodeConfig = {}

-- Where a redemption is recorded on the player. See the header.
CodeConfig.AttrPrefix = "Code_"

-- Longer than any sensible code, short enough that a megabyte of junk on the
-- remote is rejected before anything looks at it.
CodeConfig.MaxLength = 24

--[[
	Fold whatever the player typed into the one form the table is keyed by.
	Total: any input, including nil and non-strings, comes back as a string.
]]
function CodeConfig.normalise(input: any): string
	if type(input) ~= "string" then
		return ""
	end
	return (input:upper():gsub("[^%u%d]", ""))
end

function CodeConfig.attributeFor(code: string): string
	return CodeConfig.AttrPrefix .. CodeConfig.normalise(code)
end

--[[
	THE CODES.

	  code    what the player types, in any case and with any punctuation
	  coins   the payout BEFORE the run multiplier (see the header)
	  note    what the toast says; keep it short, it shares a line with the sum

	These three are a starting set -- change them, they are meant to be changed.
	A code is only worth having if it is announced somewhere, so the sensible
	rhythm is one per post.
]]
CodeConfig.Codes = {
	-- Real codes removed from the public repo.
	{ code = "EXAMPLECODE", coins = 1000, note = "Example reward!" },
}

-- Built once, keyed by the normalised form, so a lookup is not a scan.
CodeConfig.ByCode = {}
for _, entry in CodeConfig.Codes do
	local key = CodeConfig.normalise(entry.code)
	if key ~= "" then
		CodeConfig.ByCode[key] = entry
	end
end

--[[
	The entry for what the player typed, or nil.

	nil covers both "no such code" and "you sent rubbish", and the caller says
	the same thing for both on purpose: telling somebody their guess was the
	right SHAPE is how a code table gets brute forced.
]]
function CodeConfig.find(input: any)
	local key = CodeConfig.normalise(input)
	if key == "" or #key > CodeConfig.MaxLength then
		return nil, ""
	end
	return CodeConfig.ByCode[key], key
end

return CodeConfig
