--[[
	SkinConfig  --  ReplicatedStorage.Modules.SkinConfig

	THE SIFTER'S WARDROBE. One skin per interior, plus the steel tool everybody
	starts with.

	A skin is a PALETTE, not a model. The sifter is assembled procedurally by
	CTB_Client.buildSifter -- a mesh floor, a rim, a blade and two barrow wheels
	-- and every one of those pieces reads its colour, its material and its
	reflectance out of the `pieces` table below. So a new skin is a table here
	and nothing else: no new geometry, no second build path, and no way for the
	tool you are holding to disagree with the one on the plinth.

	WHY THE ROOMS AND NOT THE SHOP. The three interiors are the only places in
	the game you have to be LET INTO -- the tomb at four rebirths, the shrine at
	thirteen, the magma chamber at twenty-six -- so they are the only three
	rewards that cannot be bought, rushed or missed by someone who plays. A
	fourth skin should come with a fourth room, not with a fourth price.

	TWO ATTRIBUTES, AND THEY ARE NOT THE SAME QUESTION
	--------------------------------------------------
		SkinChosen   what you wear everywhere. Persisted. Set by claiming a
		             plinth, and by walking up to one you have already claimed.
		SkinActive   what you are wearing RIGHT NOW. Derived, never saved:
		             SkinService drops the room's own skin over the top while
		             you are inside it and hands `SkinChosen` back at the door.

	Only ever read SkinActive to draw the tool. A client that drew SkinChosen
	would undo the whole point of walking into the tomb.

	OWNERSHIP IS ONE BOOLEAN PER SKIN -- `SkinOwn_<key>` on the Player --
	rather than one packed string, because attributes cannot hold tables and a
	packed string cannot be watched with GetAttributeChangedSignal. It is the
	shape ProgressionConfig's `Lv_<track>` already uses for the same reason.
]]

local SkinConfig = {}

--------------------------------------------------------------------------
-- NAMES THINGS ELSEWHERE SPELL
--------------------------------------------------------------------------
SkinConfig.OwnPrefix = "SkinOwn_"
SkinConfig.ChosenAttribute = "SkinChosen"
SkinConfig.ActiveAttribute = "SkinActive"

-- The tool as it has always looked. Owned by everybody, claimable nowhere, and
-- what every fallback in the system resolves to -- so a corrupt profile, an
-- unknown key or a missing attribute all end at the same honest steel sifter
-- rather than at a nil three lines later.
SkinConfig.DefaultKey = "standard"

-- How near the plinth counts as walking up to it.
--
-- FOURTEEN, and it is generous on purpose. Every plinth stands on the arrival
-- axis between the door and the rakeable square, so a player heading for the
-- sand walks THROUGH this circle without being asked to aim at anything --
-- which is what makes the unlock feel automatic rather than like an errand.
-- Tightening it to arm's length would turn the centrepiece into a button.
SkinConfig.ClaimRadius = 14

--[[
	THE CEREMONY'S CLOCK, and it is shared for the same reason Config.CINEMA is
	shared: the client runs the animation on its own clock and the server flips
	SkinActive on its own, so a dropped packet can make the handover slightly
	early or slightly late but can never leave a player watching a comet fly
	into a tool that never changes.

	`handoff` is the moment the comet lands. The server waits exactly that long
	before writing SkinActive, so the tool re-forges ON the impact rather than
	before the display has even lifted off its plinth.
]]
SkinConfig.Ceremony = {
	charge = 0.55,   -- the ring winds up, motes stream in
	lift = 0.85,     -- the display rises and stands upright
	burst = 0.30,    -- the flash it leaves behind
	travel = 0.55,   -- the comet's flight to the player
	settle = 0.70,   -- the tool's own white-hot cool-down
}
SkinConfig.Ceremony.handoff =
	SkinConfig.Ceremony.charge
	+ SkinConfig.Ceremony.lift
	+ SkinConfig.Ceremony.burst
	+ SkinConfig.Ceremony.travel

--------------------------------------------------------------------------
-- THE PIECES A SKIN HAS TO ANSWER FOR
--
-- Every key below is read by BOTH buildSifter (the tool in your hands) and
-- SkinPlinthBuilder (the showpiece on the stand), which is the whole reason
-- they cannot look like two different objects.
--
--   mesh      the wire floor and the wired back wall
--   frame     the rim, the side rails and the uprights
--   blade     the cutting lip
--   tine      the comb ahead of it -- separate from `blade` so a skin can
--             light the tips without lighting the whole edge
--   tyre      barrow wheel
--   hub / spoke
--   steel     axle, handle rails, crossbar -- the tool's plumbing
--   grip      what the hands are actually on
--
-- Each is { c = Color3, m = Enum.Material, r = reflectance? }.
--------------------------------------------------------------------------

local function P(c: Color3, m: Enum.Material, r: number?)
	return { c = c, m = m, r = r or 0 }
end

local RGB = Color3.fromRGB

--------------------------------------------------------------------------
-- THE CATALOGUE
--------------------------------------------------------------------------
--[[
	ORDER IS THE LADDER, and it is the ladder the ROOMS are on rather than one
	of its own: standard, then the tomb (4 rebirths), the shrine (13) and the
	magma chamber (26). Anything that lists skins should list them in this
	order, so the collection reads as a journey west and down.
]]
SkinConfig.Skins = {
	{
		key = "standard",
		name = "BEACH STANDARD",
		short = "Beach Standard",
		-- No island: this one is not claimed anywhere and no plinth carries it.
		island = nil,
		room = "",
		blurb = "Galvanised, honest, and yours from the first tide.",
		how = "Yours from the start.",
		tint = RGB(196, 200, 206),
		pieces = {
			mesh = P(RGB(178, 184, 192), Enum.Material.Metal),
			frame = P(RGB(146, 152, 160), Enum.Material.Metal),
			blade = P(RGB(222, 226, 232), Enum.Material.Metal),
			tine = P(RGB(222, 226, 232), Enum.Material.Metal),
			tyre = P(RGB(98, 108, 98), Enum.Material.SmoothPlastic),
			hub = P(RGB(196, 200, 206), Enum.Material.Metal),
			spoke = P(RGB(74, 82, 76), Enum.Material.SmoothPlastic),
			steel = P(RGB(196, 200, 206), Enum.Material.Metal),
			grip = P(RGB(46, 48, 54), Enum.Material.Fabric),
		},
		-- The sand it throws up. Unchanged from what the tool has always
		-- emitted -- these two are the defaults every other skin tints away
		-- from rather than numbers picked for this row.
		dust = { RGB(238, 220, 180), RGB(212, 190, 148) },
		sift = RGB(228, 206, 164),
		glow = nil,
		charm = nil,
	},

	--[[
		THE FIRST WEEK  --  three rungs of one tool, 2026-09-11.

		WHY THESE EXIST. The four room skins gate on islands 3, 6, 7 and 9, which
		the live funnel reaches at 4.54%, 0.45%, 0.01% and not at all. So 95% of
		the people playing this game never unlock a single cosmetic, and the
		wardrobe they open is a room full of padlocks. These three are the ladder
		underneath that one: the first lands inside the opening session, the other
		two are the reason to come back on day three and day seven.

		THEY ARE ONE TOOL BEING FINISHED, not three tools. Same driftwood frame
		all the way up -- what changes is that it gains a rope grip and copper
		fittings, and then sea glass. A player who has the first one can SEE what
		the second one is going to be, which is the entire retention argument: an
		unfinished object in your hands pulls harder than a number in a panel.

		ISLAND = NIL, the same seam `standard` and `vip` already use. These are
		handed over by RewardsServer when the rung is met, so `forIsland` skips
		them, `claimable()` leaves them out of the collection walk, and no plinth
		carries them. Nothing in the room-claim path changes at all.

		NO CHARMS, deliberately. A charm is procedural geometry drawn by an
		if/elseif chain in BOTH CTB_Client and SkinPlinthBuilder, so an unknown
		charm name silently draws nothing. A shell on the last rung would be a
		nice finish and it is two real geometry branches, not a config line --
		worth doing on its own, not worth half-doing here.

		THEY STAY HUMBLE ON PURPOSE. The tomb skin glows at 0.9 and is gold on
		obsidian; if the day-seven rake out-dressed it the ladder would read
		downward. Wood, worn metal and one cool accent is the ceiling here.
	]]

	--[[
		RUNG ONE -- ten minutes in. Bare salvage: weathered timber, twine, and one
		piece of worn steel for the cutting edge. It is meant to look MADE rather
		than issued, which is what separates it from the galvanised tool above it.

		SILVERED GREY-BROWN, NOT PALE TAN, AND THAT WAS A CORRECTION. The first
		pass used sun-bleached driftwood colours around RGB(198, 182, 154) and it
		failed in Play for two reasons at once: it is within a few points of the
		SAND, so the tool half-vanished into the beach it is dragged across, and
		the rest of it still read as the steel rake. Real driftwood is darker and
		greyer than sand anyway. Do not lighten these back up.

		`steel` IS TIMBER HERE, and that is the change that made the skin read at
		all. It is the axle, the crossbar and THE LONG HANDLE RAIL -- the single
		biggest piece of the tool on screen and the one the camera looks straight
		down. Leaving it grey kept every rung below the sea glass looking like the
		starter tool with a brown frame. On a rake somebody lashed together out of
		what washed up, the rails being wood is also just what it would be.
	]]
	{
		key = "driftwood",
		name = "DRIFTWOOD RAKE",
		short = "Driftwood Rake",
		island = nil,
		room = "",
		blurb = "Built from what the last tide left.",
		how = "Rewards \u{2192} Quests: play 10 minutes.",
		tint = RGB(138, 120, 98),
		pieces = {
			mesh = P(RGB(138, 120, 98), Enum.Material.Wood),
			frame = P(RGB(112, 96, 76), Enum.Material.Wood),
			-- The one salvaged metal part, and it is dull: nothing on this rung
			-- is polished, because the next two rungs are where the shine arrives.
			blade = P(RGB(176, 172, 162), Enum.Material.Metal, 0.08),
			tine = P(RGB(176, 172, 162), Enum.Material.Metal, 0.08),
			tyre = P(RGB(58, 54, 50), Enum.Material.SmoothPlastic),
			hub = P(RGB(112, 96, 76), Enum.Material.Wood),
			spoke = P(RGB(138, 120, 98), Enum.Material.Wood),
			steel = P(RGB(120, 100, 78), Enum.Material.Wood),
			grip = P(RGB(168, 150, 118), Enum.Material.Fabric),
		},
		dust = { RGB(236, 220, 184), RGB(208, 188, 150) },
		sift = RGB(226, 206, 168),
		glow = nil,
		charm = nil,
	},

	--[[
		RUNG TWO -- three days in. The rope grip and the copper arrive together,
		and they are the whole read: the frame has not changed, so what a player
		sees is the same tool with work done to it rather than a replacement.

		VERDIGRIS ON THE HUBS, copper on the edge. Two ages of the same metal on
		one object is what sells it as salvage that has been out in the salt --
		and it sets up the last rung, where the verdigris stays and the sea glass
		joins it.
	]]
	{
		key = "beachcomber",
		name = "BEACHCOMBER'S RAKE",
		short = "Beachcomber's Rake",
		island = nil,
		room = "",
		blurb = "Three days of salt, and it has started to look like yours.",
		how = "Rewards \u{2192} Quests: come back on 3 days.",
		tint = RGB(198, 124, 74),
		pieces = {
			-- The same timber as the rung below, unchanged on purpose: what the
			-- player should read is work done TO their tool, not a new one.
			mesh = P(RGB(142, 124, 102), Enum.Material.Wood),
			frame = P(RGB(116, 100, 80), Enum.Material.Wood),
			blade = P(RGB(198, 124, 74), Enum.Material.Metal, 0.18),
			tine = P(RGB(214, 142, 92), Enum.Material.Metal, 0.18),
			tyre = P(RGB(56, 52, 48), Enum.Material.SmoothPlastic),
			hub = P(RGB(92, 156, 136), Enum.Material.Metal, 0.10),
			spoke = P(RGB(142, 124, 102), Enum.Material.Wood),
			-- THE HANDLE RAIL IS THE WHOLE READ on this rung -- see the note on
			-- `steel` above. Copper here is what a player sees change when the
			-- third day lands, from the one angle they spend the session at.
			steel = P(RGB(166, 104, 62), Enum.Material.Metal, 0.14),
			-- Rope, and it is the piece the player's hands are actually on.
			grip = P(RGB(206, 184, 142), Enum.Material.Fabric),
		},
		dust = { RGB(240, 222, 186), RGB(214, 186, 142) },
		sift = RGB(230, 206, 162),
		glow = nil,
		charm = nil,
	},

	--[[
		RUNG THREE -- seven days in, and it is the only one of the three that is
		allowed to be pretty.

		SEA GLASS IN THE MESH is the finish, and it goes in the mesh rather than
		the frame for the reason the tomb skin puts turquoise on the spokes and
		nowhere else: one surface, used once, stays an accent. The floor is also
		the biggest flat area on the tool and the one the sand pours through, so
		it is where a translucent material actually reads.

		THE TINES ARE LIT, the blade is not -- which is exactly what `tine` is a
		separate key for (see the piece list above). Lighting the whole edge would
		have put a neon bar across the front of a wooden rake.

		The glow is 0.65 against the tomb's 0.9. It is a finish, not a trophy.
	]]
	{
		key = "longshore",
		name = "LONG SHORE RAKE",
		short = "Long Shore Rake",
		island = nil,
		room = "",
		blurb = "A week of tides, and the sea has paid you in glass.",
		how = "Rewards \u{2192} Quests: come back on 7 days.",
		tint = RGB(126, 196, 184),
		pieces = {
			-- Glass renders this brighter and bluer than the swatch reads on
			-- paper -- measured in Play, it comes out close to a lit cyan. That is
			-- the reason this rung works from across the beach, so the number is
			-- chosen for how it RENDERS rather than for how it looks in a picker.
			mesh = P(RGB(126, 196, 184), Enum.Material.Glass, 0.25),
			frame = P(RGB(146, 126, 102), Enum.Material.Wood),
			blade = P(RGB(214, 148, 100), Enum.Material.Metal, 0.30),
			tine = P(RGB(158, 220, 206), Enum.Material.Neon),
			tyre = P(RGB(70, 68, 64), Enum.Material.SmoothPlastic),
			hub = P(RGB(110, 168, 148), Enum.Material.Metal, 0.16),
			spoke = P(RGB(196, 180, 152), Enum.Material.Wood),
			steel = P(RGB(162, 108, 72), Enum.Material.Metal, 0.16),
			grip = P(RGB(214, 194, 154), Enum.Material.Fabric),
		},
		-- Cooler than every rung below it: the sand coming off this one carries
		-- the glass, which is the cheapest way to make the finish visible while
		-- the player is doing the thing they spend the session doing.
		dust = { RGB(226, 238, 226), RGB(190, 214, 202) },
		sift = RGB(214, 230, 214),
		glow = { c = RGB(150, 214, 200), range = 11, brightness = 0.65 },
		charm = nil,
	},

	--[[
		THE FOURTEEN-DAY RUNG, and the one that has to read as a step ABOVE the
		Long Shore rake without straying into the paid skins' territory.

		Long Shore is lit cyan glass -- fair weather, a week of ordinary tides.
		This is the storm that followed: the same sea glass gone deep indigo,
		with the tines carrying the only bright colour on the tool. That keeps
		the two legible side by side, which matters because a player who reaches
		this rung owns both and is choosing between them.

		DELIBERATELY NOT GOLD OR WHITE. Pharaoh's Sieve and the VIP rake own
		those, and they are SOLD. A free loyalty rung that glittered like the
		pass would quietly devalue the pass, so this one is dark and cold and
		wins on shape rather than on shine.
	]]
	{
		key = "stormglass",
		name = "STORMGLASS RAKE",
		short = "Stormglass Rake",
		island = nil,
		room = "",
		blurb = "A fortnight of tides, and the sea has paid you in weather.",
		how = "Rewards \u{2192} Quests: come back on 14 days.",
		tint = RGB(118, 132, 198),
		pieces = {
			-- Glass again, and darker than the swatch reads for the same reason
			-- Long Shore's is lighter: the material lifts it. Measured in Play,
			-- this lands as a deep storm blue rather than the near-black the
			-- number suggests on paper.
			mesh = P(RGB(84, 98, 158), Enum.Material.Glass, 0.28),
			frame = P(RGB(74, 70, 86), Enum.Material.Wood),
			blade = P(RGB(168, 178, 202), Enum.Material.Metal, 0.34),
			-- The one bright thing on the tool. Neon carries at distance, which
			-- is what makes this rung visible from across the beach the way the
			-- cyan one is.
			tine = P(RGB(200, 226, 255), Enum.Material.Neon),
			tyre = P(RGB(48, 48, 58), Enum.Material.SmoothPlastic),
			hub = P(RGB(112, 126, 172), Enum.Material.Metal, 0.18),
			spoke = P(RGB(146, 150, 170), Enum.Material.Wood),
			steel = P(RGB(126, 138, 166), Enum.Material.Metal, 0.18),
			grip = P(RGB(158, 166, 192), Enum.Material.Fabric),
		},
		-- Cold and pale against the dark tool, so the sand coming off it reads
		-- as spray rather than as dust.
		dust = { RGB(214, 226, 244), RGB(176, 192, 220) },
		sift = RGB(198, 214, 238),
		glow = { c = RGB(142, 176, 244), range = 12, brightness = 0.7 },
		charm = nil,
	},

	--[[
		THE TOMB. Gold on obsidian with lapis at the grip and one turquoise
		accent, which is VaultBuilder's own palette read straight off its
		walls -- the skin has to look like it was lifted out of that room, not
		like a gold texture applied to a garden tool.

		Turquoise is the room's rarest colour (the doorway veil and nothing
		else), so it is used here exactly once: the wheel spokes. A second
		place and it stops being the accent.
	]]
	--[[
		THE VIP SKIN, and the only one in this table with NO ISLAND.

		Every other skin is claimed by walking to a plinth in a room; this one
		arrives with a game pass, so `island = nil` and no plinth carries it --
		which is the same seam the standard steel one already uses. `forIsland`
		skips it, `claimable()` leaves it out of the collection walk, and
		SkinService.step therefore never tries to hand it over at a stand.

		IT IS NOT A SECOND PHARAOH'S SIEVE, and it took some care not to be. That
		one is antique gold on obsidian with lapis -- treasure dug out of a tomb.
		This is POLISHED gold on white with an amethyst grip: jewellery, not
		archaeology. The two read as different objects at a glance, which they
		have to, because a player can own both and swap between them.

		The amethyst is the tie to the pet the same pass hands over -- the gilded
		unicorn carries three of them down its centre line.
	]]
	{
		key = "vip",
		name = "GILDED RAKE",
		short = "Gilded Rake",
		island = nil,
		room = "",
		blurb = "Polished gold, and it never leaves your hands.",
		how = "Comes with the VIP pass.",
		tint = RGB(255, 201, 66),
		pieces = {
			mesh = P(RGB(255, 208, 84), Enum.Material.Metal, 0.35),
			frame = P(RGB(232, 176, 40), Enum.Material.Metal, 0.45),
			-- The blade and tines are the brightest thing on it: they are what
			-- the player watches while they rake, so they get the polish.
			blade = P(RGB(255, 240, 176), Enum.Material.Metal, 0.60),
			tine = P(RGB(255, 240, 176), Enum.Material.Metal, 0.60),
			tyre = P(RGB(250, 248, 242), Enum.Material.SmoothPlastic),
			hub = P(RGB(255, 208, 84), Enum.Material.Metal, 0.50),
			spoke = P(RGB(198, 148, 46), Enum.Material.Metal, 0.30),
			steel = P(RGB(214, 158, 34), Enum.Material.Metal, 0.40),
			grip = P(RGB(102, 26, 158), Enum.Material.Fabric),
		},
		dust = { RGB(255, 238, 186), RGB(232, 198, 118) },
		sift = RGB(252, 226, 150),
		glow = { c = RGB(255, 222, 140), range = 14, brightness = 1.0 },
		charm = nil,
	},

	{
		key = "gilded",
		name = "PHARAOH'S SIEVE",
		short = "Pharaoh's Sieve",
		island = 3,
		room = "The Tomb",
		blurb = "Cast for a king who never once had to sweep.",
		tint = RGB(242, 196, 84),
		pieces = {
			mesh = P(RGB(232, 190, 96), Enum.Material.Metal, 0.20),
			frame = P(RGB(242, 196, 84), Enum.Material.Metal, 0.35),
			blade = P(RGB(255, 232, 150), Enum.Material.Metal, 0.45),
			tine = P(RGB(255, 232, 150), Enum.Material.Metal, 0.45),
			tyre = P(RGB(24, 22, 26), Enum.Material.SmoothPlastic),
			hub = P(RGB(242, 196, 84), Enum.Material.Metal, 0.40),
			spoke = P(RGB(46, 182, 178), Enum.Material.Neon),
			steel = P(RGB(198, 148, 46), Enum.Material.Metal, 0.30),
			grip = P(RGB(40, 78, 150), Enum.Material.Fabric),
		},
		dust = { RGB(255, 232, 168), RGB(226, 186, 104) },
		sift = RGB(248, 220, 140),
		glow = { c = RGB(255, 214, 130), range = 13, brightness = 0.9 },
		charm = "scarab",
	},

	--[[
		THE INNER SHRINE. Vermilion and dark timber with gold fittings, which
		is ShrineBuilder's Inari palette. The one thing that makes it read as a
		shrine object rather than as a red rake is the SHIDE -- the folded
		white paper hung on anything consecrated -- so the charm is not
		decoration here, it is the whole identity.

		The blade stays bright steel. Every other surface went warm and matt,
		and with nothing polished left on it the tool stopped reading as a tool.
	]]
	{
		key = "vermilion",
		name = "KAGURA SIFTER",
		short = "Kagura Sifter",
		island = 6,
		room = "The Inner Shrine",
		blurb = "Blessed at the altar, then handed straight back to work.",
		tint = RGB(198, 66, 48),
		pieces = {
			mesh = P(RGB(214, 186, 132), Enum.Material.Wood),
			frame = P(RGB(198, 66, 48), Enum.Material.Wood),
			blade = P(RGB(238, 240, 236), Enum.Material.Metal, 0.28),
			tine = P(RGB(226, 182, 92), Enum.Material.Metal, 0.30),
			tyre = P(RGB(96, 64, 44), Enum.Material.Wood),
			hub = P(RGB(226, 182, 92), Enum.Material.Metal, 0.35),
			spoke = P(RGB(178, 136, 54), Enum.Material.Metal, 0.25),
			steel = P(RGB(62, 42, 30), Enum.Material.Wood),
			grip = P(RGB(150, 36, 28), Enum.Material.Fabric),
		},
		-- Blossom, not grit. The cove drops it on this room every spring and
		-- the sifter is the thing combing it out of the boards.
		dust = { RGB(255, 214, 226), RGB(246, 176, 196) },
		sift = RGB(255, 226, 236),
		glow = { c = RGB(255, 208, 150), range = 11, brightness = 0.75 },
		charm = "shide",
	},

	--[[
		THE MAGMA CHAMBER. Black rock and one hot colour, which is the rule
		MagmaBuilder's own palette note lays down for that room -- "if this
		room reaches for a second accent it stops being a hole in a volcano".
		The skin obeys it: everything is charred iron except the edge, the hubs
		and the glowing grate, and all three of those are the same orange.

		The blade is NEON. It is the only skin that lights its own cutting edge
		and it is what makes this one worth twenty-six tides.
	]]
	{
		key = "ember",
		name = "EMBERFORGE SIFTER",
		short = "Emberforge Sifter",
		island = 7,
		room = "The Magma Chamber",
		blurb = "Quenched once, and never quite cooled since.",
		tint = RGB(255, 138, 42),
		pieces = {
			mesh = P(RGB(52, 44, 44), Enum.Material.Metal),
			frame = P(RGB(26, 24, 28), Enum.Material.Slate),
			blade = P(RGB(255, 138, 42), Enum.Material.Neon),
			tine = P(RGB(255, 110, 30), Enum.Material.Neon),
			tyre = P(RGB(18, 16, 18), Enum.Material.SmoothPlastic),
			hub = P(RGB(255, 110, 30), Enum.Material.Neon),
			spoke = P(RGB(120, 40, 18), Enum.Material.Metal, 0.15),
			steel = P(RGB(34, 32, 36), Enum.Material.Metal, 0.10),
			grip = P(RGB(58, 40, 32), Enum.Material.Fabric),
		},
		dust = { RGB(255, 176, 96), RGB(196, 84, 32) },
		sift = RGB(255, 150, 60),
		glow = { c = RGB(255, 120, 40), range = 16, brightness = 1.5 },
		charm = "ember",
	},
	--[[
		THE FROZEN WRECK's, and the top of the ladder now: rebirth 40 opens the
		hold and this stands in the purser's end of it. Cut from the liner's own
		plate -- blue-white ice over dark iron, the tines lit like the daylight
		that comes down through the deck, and a red grip because the man who
		sleighs you over is who he is.
	]]
	{
		key = "icebreaker",
		name = "ICEBREAKER SIFTER",
		short = "Icebreaker Sifter",
		island = 9,
		room = "The Frozen Wreck",
		blurb = "Cut from a hull that never got home, and still cold to the touch.",
		tint = RGB(150, 226, 255),
		pieces = {
			mesh = P(RGB(176, 212, 236), Enum.Material.Ice, 0.20),
			frame = P(RGB(52, 56, 64), Enum.Material.Metal, 0.10),
			blade = P(RGB(178, 226, 255), Enum.Material.Neon),
			tine = P(RGB(214, 240, 255), Enum.Material.Neon),
			tyre = P(RGB(28, 30, 36), Enum.Material.SmoothPlastic),
			hub = P(RGB(178, 226, 255), Enum.Material.Neon),
			spoke = P(RGB(196, 158, 78), Enum.Material.Metal, 0.25),
			steel = P(RGB(120, 128, 140), Enum.Material.Metal, 0.30),
			grip = P(RGB(196, 44, 48), Enum.Material.Fabric),
		},
		dust = { RGB(224, 240, 255), RGB(160, 200, 240) },
		sift = RGB(190, 230, 255),
		glow = { c = RGB(170, 220, 255), range = 16, brightness = 1.4 },
		charm = "frost",
	},
}

--------------------------------------------------------------------------
-- LOOKUPS
--------------------------------------------------------------------------
local byKey, byIsland = {}, {}
for _, s in ipairs(SkinConfig.Skins) do
	byKey[s.key] = s
	if s.island then
		byIsland[s.island] = s
	end
end

-- Never nil. See DefaultKey: an unknown key is a profile written by another
-- build, not an error worth throwing three lines into somebody's join.
function SkinConfig.get(key: string?)
	return byKey[key or ""] or byKey[SkinConfig.DefaultKey]
end

-- Is this a key this build knows? The one place that DOES care about the
-- difference, because a profile restore must not resurrect a retired skin.
function SkinConfig.exists(key: any): boolean
	return type(key) == "string" and byKey[key] ~= nil
end

-- The skin claimable in this island's room, or nil for the four open shores.
function SkinConfig.forIsland(id: number?)
	return id and byIsland[id] or nil
end

--[[
	WHAT A PLAYER WHO DOES NOT OWN THIS HAS TO DO, one line, for the wardrobe.

	DERIVED WHERE IT CAN BE. A skin with a room is claimed at that room's plinth
	and there is nothing else to say, so those rows carry no `how` at all -- the
	room name is already the answer and stating it twice is two places to update.
	`how` is only written where the answer is NOT a room: the starter tool, the
	pass, and the four wardrobe rungs.

	Empty string rather than nil for the unanswerable case, so a caller can print
	it without a guard.
]]
function SkinConfig.howToGet(skin): string
	if type(skin) ~= "table" then
		return ""
	end
	if type(skin.how) == "string" and skin.how ~= "" then
		return skin.how
	end
	if type(skin.room) == "string" and skin.room ~= "" then
		return "Claimed in " .. skin.room
	end
	return ""
end

-- Every skin with a room behind it, in ladder order. What the plinth builder
-- iterates, so adding a row above is the only edit a fourth room needs.
function SkinConfig.claimable()
	local out = {}
	for _, s in ipairs(SkinConfig.Skins) do
		if s.island then
			table.insert(out, s)
		end
	end
	return out
end

return SkinConfig
