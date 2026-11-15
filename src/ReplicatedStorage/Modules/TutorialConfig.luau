--[[
	TutorialConfig  --  ReplicatedStorage.Modules.TutorialConfig

	The three facts the onboarding's two halves have to agree about, and nothing
	else. TutorialHud draws the cards on the client; TutorialServer guarantees
	the crusted find on the server. They never speak -- there is no remote in
	this feature at all -- so the only thing that can make them contradict each
	other is disagreeing about WHO IS NEW, and that is why that test lives here
	rather than twice.

	WHY "LOOKS NEW" IS THIS LOOSE
	-----------------------------
	Nothing earned, no rebirths, not already finished. Deliberately generous:
	on the client this puts a card in the corner with an X on it, so being wrong
	costs a returning player one click -- where being too strict costs a new
	player the whole tutorial. On the server it costs at most two finds that
	come up crusted instead of loose, which is a thing the beach does anyway.

	TIMING IS THE ONE TRAP. Every attribute below is written by SaveService's
	restore, which lands a moment AFTER the join -- so a returning player looks
	brand new for that window and this answers yes for them. Both callers wait
	it out rather than re-implementing the test: TutorialServer polls
	SaveService.isLoaded, and TutorialHud sits behind the fifteen second opening
	shot and re-tests on the far side of it.
]]

local TutorialConfig = {}

--[[
	SET ONCE, ON THE SERVER, AND PERSISTED. SaveService carries this field, so
	the tutorial is a once-per-ACCOUNT event rather than a once-per-session one.
	TutorialServer stamps it the moment the last step is provably done -- see
	its header for why a purchase is a thing the server can see for itself.
]]
TutorialConfig.DoneAttribute = "TutorialDone"

--[[
	HOW MANY FINDS THIS PLAYER IS STILL OWED AS LUMPS. Written by
	TutorialServer on the way in, spent one at a time by biasFind, and cleared
	when the tutorial finishes. A number rather than a boolean because the
	guarantee is a COUNT: one lump can be washed in twelve seconds and the step
	after it wants something to sell.
]]
TutorialConfig.LumpsAttribute = "TutorialLumps"

--[[
	ONE, AND IT IS A CEILING NOW AS WELL AS A FLOOR.

	The beach turns up a lump on about 7.4% of finds, and a starting 12 lb bag
	holds roughly twenty of them -- so an unlucky first bag genuinely contains
	nothing crusted about one time in five, and that player is sent to a wash
	bay with an empty bag by a tutorial that will then never advance. That is
	the entire reason this exists.

	IT WAS TWO, and the argument for the second one was that selling what came
	out of the crust should feel like a payout rather than like a single
	trinket. What that missed is the ORDER OF THE STEPS. The crust is the one
	thing in the bag the sell pad will not take, and the card sends the player
	to the pad BEFORE it sends them to the bay -- so every extra lump is dead
	weight in the bag at the exact step that is asking them to turn the bag
	into money. A player whose bag came up mostly crust stood on the pad
	watching nothing happen, with the card still saying SELL.

	So the guarantee is one. TutorialServer.capCrust enforces the other side of
	it -- the beach's own crusted finds, and the crusted litter lying loose on
	the sand, are held back while the player is already carrying a lump -- so
	"one" is what a first bag holds whatever the beach happens to roll.
]]
TutorialConfig.LumpGrant = 1

--[[
	THE TUTORIAL BAG, AND WHAT IS IN IT.

	Three numbers, one story: the first bag is SMALL (BagCap pounds against the
	ladder's twelve), it holds exactly ONE crusted lump (LumpGrant above, held
	to one by TutorialServer.capCrust), and the loose litter around it is worth
	enough that selling the bag pays the first rung of EVERY track -- the
	Sifter Width the card asks for, and the three rows that unlock the moment
	it is bought. A first-timer walks off the pad able to afford the thing the
	tutorial is pointing at, every time. An onboarding that can come up too
	poor for its own lesson is an onboarding with a random failure rate.

	TrashItems IS THE DIVISOR, NOT A CAP. A BagCap-pound bag around a 2 lb
	lump holds about four pounds of litter at about a pound a piece, so the
	per-item value TutorialServer publishes is sum-of-first-rungs / TrashItems.
	A light bag that fits a fifth piece overshoots -- headroom, not error.

	ALL OF IT ENDS WITH THE TUTORIAL. TutorialServer hands the bag back to the
	Bucket Size ladder and withdraws the value override in finish(), the same
	breath that clears the lump credit -- past the tutorial every number here
	is dead, and the starter loadout is exactly what it always was.
]]
TutorialConfig.BagCap = 6
TutorialConfig.TrashItems = 4
-- Written by TutorialServer while the tutorial is armed (the per-item coin
-- value for loose litter), read by CTBBridge at the pickup roll. Nil otherwise.
TutorialConfig.TrashValueAttribute = "TutorialTrashValue"

--[[
	THE SEND-OFF. Ticked by TutorialServer.finish -- and ONLY for a finish that
	ends a tutorial the player actually ran (the wasArmed guard), never for the
	join-time retirement of a restored veteran. A counter for the same reason
	ReplayAttribute is one: the client wants an EDGE it can watch, and a number
	nobody else writes cannot fire on an ordinary join. TutorialOutro watches it
	and takes the camera to the beach boatman for his pitch.
]]
TutorialConfig.CelebrateAttribute = "TutorialCelebrate"

--[[
	THE SEND-OFF'S SHOT LIST, IN CONFIG BECAUSE BOTH SIDES READ IT: the client
	(TutorialOutro) flies these orbits, and the server (TutorialServer) walks
	the player's ReplicationFocus down the same list so each stop streams in
	full detail before the curtain lifts -- this place runs StreamingEnabled,
	and a camera three thousand studs from the character otherwise films the
	imposter meshes. One table, so the tour and its streaming escort cannot
	disagree about where the stops are.

	THE THREE FERRY ISLANDS AND NOTHING ELSE. The interior chambers were tried
	twice -- filmed live (ceilingless floors over the void: skybox behind every
	wall) and as sterilised 1:1 sets sunk beneath the map -- and neither read
	as a place on camera, so the tour keeps to the shores the boatman actually
	sails to. `y`/`lift` are offsets from `centre`; `a0 -> a1` is the orbit in
	degrees at radius `r`; a second keyframe (`centre2`/`r2`/`y2`/`lift2`)
	turns an orbit into a pull-back, and `gate` is a stop's curtain budget.
]]
TutorialConfig.OutroStops = {
	{ port = 2, centre = Vector3.new(1500, 8, 0),    r = 150, y = 105, lift = 18,  a0 = 165, a1 = 200,
		container = "Island2" },
	{ port = 3, centre = Vector3.new(0, 6, 1596),    r = 150, y = 95,  lift = 14,  a0 = 255, a1 = 290,
		container = "Island3" },
	--[[
		ASHFALL IS A PULL-BACK, NOT AN ORBIT: the shot OPENS tight on the
		volcano (summit probed at y=188 over (-2180, 380)) and draws out and
		up until the whole island is in frame. The second keyframe carries its
		own centre, radius, height and look-lift (`centre2`/`r2`/`y2`/`lift2`);
		TutorialOutro tweens between the two lookAt frames, so the look point
		itself slides from the cone's upper slopes down to the island at large.
	]]
	{ port = 4, centre = Vector3.new(-2180, 3, 380), r = 120, y = 200, lift = 150, a0 = 260, a1 = 262,
		centre2 = Vector3.new(-2200, 3, -160), r2 = 560, y2 = 330, lift2 = 30,
		-- The longest hold on the tour, because it is the only stop that TRAVELS
		-- (summit to whole-island). It came down from 4.2 when the send-off was
		-- retimed around press-to-advance: nothing here has to be long enough
		-- for the slowest reader any more, since a press ends the shot.
		stream = 5, hold = 3.2, container = "Island4" },
	--[[
		PENGUIN ISLAND IS AN ORBIT FROM THE BEACH SIDE. The island is the biggest
		in the game (a landmass 1488 across on a frozen sea), so the camera
		stands off 760 studs and high, and swings round the north shore -- the
		liner, the ice cliffs and the colony pass under it. Angles 60-120 put it
		north of the island, which is the side the beach is on.
	]]
	{ port = 5, centre = Vector3.new(0, 3, -2700), r = 760, y = 330, lift = 30, a0 = 60, a1 = 120,
		stream = 5, hold = 3.0, container = "Island5" },
}

--[[
	THE TUTORIAL'S WASH IS EASIER THAN THE GAME'S, AND ONLY THE TUTORIAL'S.

	Measured drop-off says players leave AT THE WASH BAY, and the arithmetic
	says the erosion is not what is slow: 22 chunks x ~0.59 work / 6 psi is
	about two and a half seconds of PERFECTLY AIMED jet. What actually costs
	the newcomer their first minute is everything around that number --
	the camera locks, the reticle is new, and at the first washer tier
	WasherSpread is 1, so a packet aimed at a clump that has already gone
	does NOTHING AT ALL (see the early return in WashServer.onAim). A player
	who has not yet learned to sweep spends most of their packets on holes.

	So the boost is not really "more pressure". It is FORGIVENESS, in three
	parts, and the third is the one that matters:

	  Pressure  the budget one packet carries, x3
	  Reach     how many clumps that budget may spill into, floored at 5
	  Aim       a packet aimed at a dead clump is redirected to the nearest
	            live one instead of being thrown away

	Together those turn a fumbled first wash into about a second of holding
	the trigger, without touching what the find is WORTH -- ValueCalculator
	never hears about any of this, so the tutorial pays exactly what it
	always did.

	IT IS A COUNT, NOT A FLAG, for the same reason LumpsAttribute above is:
	a boost that lasted "until the tutorial is done" would last forever for
	the player who simply never buys their first upgrade -- and wash speed is
	income. Four is the two guaranteed lumps plus room for a couple the beach
	turns up on its own during the same trip to the bay. It is spent one lump
	at a time by WashServer and it cannot be topped up.

	DELIBERATELY NOT CLEARED BY finish(). LumpsAttribute is cleared there
	because an unspent find-bias would keep rigging the beach; this expires by
	being SPENT, so clearing it would only ever cut short the wash the player
	is in the middle of at the moment they buy their first upgrade.
]]
TutorialConfig.WashBoostAttribute = "TutorialWashBoost"
TutorialConfig.WashBoostGrant = 4
TutorialConfig.WashBoostPressure = 3
TutorialConfig.WashBoostReach = 5

--[[
	THE RESTART TICK, for testing the onboarding on an account that has long
	since finished it.

	A NUMBER THAT ONLY EVER GOES UP, rather than a boolean or a re-read of
	TutorialDone. TutorialHud's card is raised once per session and latched;
	the thing it needs is an EDGE it can watch, and one that cannot possibly
	fire on an ordinary join -- which is exactly what a counter nobody writes
	except the restart path is. See TutorialServer.restart.
]]
TutorialConfig.ReplayAttribute = "TutorialReplay"

--[[
	THE HOLD: "this account is deliberately blank, and nothing may re-fill it
	until the tutorial is finished."

	The admin panel's ONBOARDING verb wipes an account back to what a new player
	has so the onboarding can be walked start to finish. Without a marker that
	survives a rejoin, the wipe lasts exactly as long as the session: DevGrant
	stamps a Studio account back to a billion coins and forty tides two seconds
	after every join, and it has no way to tell a blanked tester from a developer
	who wants their sandbox back.

	SO IT IS A FLAG WITH AN END CONDITION RATHER THAN A SWITCH. `finish` clears
	it -- the same function that stamps the tutorial done -- so the hold lifts on
	the purchase the card asks for and the next join restores the sandbox. There
	is nothing to remember to turn off.

	It also forces locksOtherTracks above: during a held run the shop is the
	one-row shop whatever the levels happen to say, so an account part-way
	through a reset still reads the way a new player's does.
]]
TutorialConfig.HoldAttribute = "TutorialHold"

--[[
	ONE PURCHASE IS TAUGHT, AND UNTIL IT IS MADE IT IS THE ONLY ONE ON SALE.

	The shop opens on four rows and a first-timer has no way to tell which of
	them is worth the money they are holding -- TutorialHud's last step says so
	in its own note, and answers it by NAMING one row. This is the other half of
	that answer: while the card is asking for Sifter Width, the other three
	tracks are refused, and the row the card names is the one that is lit.

	WHY REFUSE RATHER THAN MERELY SUGGEST. The step completes on the Sifter
	Width level moving, so a player who spends their first coins on Bucket Size
	instead is left with a card pointing at a row they can no longer afford, and
	the tutorial stalls on a purchase they have already made the money for. That
	is a worse dead end than the one the wash step used to have, because there
	is no way out of it except earning a second bagful.

	IT IS THE CHEAPEST ROW AND THE ONLY ONE WHOSE EFFECT IS VISIBLE IN THE WORLD
	the moment it is bought -- the rake gets wider and the next pass turns up
	more -- which is exactly why the card picks it. Teaching "upgrades are the
	point of the loop" needs an upgrade the player can SEE.

	FirstTrack IS A KEY INTO ProgressionConfig.Tracks, named here rather than
	imported: this module is required by SaveService at boot and its own note
	there celebrates having no dependencies of its own, so the level is passed
	IN by callers -- who all hold ProgressionConfig already -- rather than
	looked up here.
]]
TutorialConfig.FirstTrack = "RollerWidth"

--[[
	THE EGG THE ONBOARDING ASKS FOR, and it is named here for exactly the reason
	FirstTrack is: A KEY, NOT AN IMPORT. This module is required by SaveService at
	boot and its own note there celebrates having no dependencies of its own, so
	any price lookup belongs to callers who already hold PetConfig. Today that is
	TutorialHud alone, pointing its card at the right tube.

	TutorialServer does NOT read this. Its purse floor was going to, until the
	arithmetic was measured on 2026-09-23: the first bag sells for about 1,440
	against 780 for the egg and the first upgrade together, so there is no gap to
	cover and no reason to hand every new account coins it does not need.

	The cheapest egg, at 500, and the only one a first-timer could reach: the next
	rung up is the Desert Egg at 15,000.
]]
TutorialConfig.FirstEgg = "Basic"

--[[
	Should every track EXCEPT FirstTrack be refused right now?

	⚠️ ONE IS THE FLOOR, NOT ZERO, AND THIS TEST USED TO SAY OTHERWISE.

	It read `<= 0`, under a note arguing that nil-or-0 was what "never bought"
	looked like and that levelOf's clamp to 1 would blur a fresh track together
	with one bought once. Both halves of that were wrong, and the cost was the
	whole feature: NOTHING IN THE GAME EVER WRITES A ZERO HERE.

		* ProgressionServer's join hook stamps every missing `Lv_` to 1
		* SaveService restores levels through math.clamp(lv, 1, MaxLevel)
		* a track starts at 1, so buying it once makes it 2 -- levelOf never
		  reports 1 for a track that has been bought, and the blur the old note
		  worried about does not exist

	So the gate was false for every player who has ever joined, and the steer it
	controls -- the pulsing Sifter Width row, the three LOCKED ones, and
	ProgressionServer's refusal to sell them -- has never once fired. Measured
	by hand: at level 0 the shop paints all of it, at level 1 (which is what
	everybody actually has) it paints none of it.

	LEVEL 1 IS NEVER BOUGHT, which is exactly what TutorialServer.hasBought has
	always said with its `> 1` test. The two now agree, which is the property
	that matters: one of them decides when the tutorial is finished and the
	other decides what the shop looks like while it is not.

	The raw attribute is still the right thing to pass -- it is what the caller
	has to hand and it costs nothing -- but levelOf's answer would now be correct
	too.
]]
function TutorialConfig.locksOtherTracks(player: Instance?, firstTrackLevel: any): boolean
	if typeof(player) ~= "Instance" then
		return false
	end
	if player:GetAttribute(TutorialConfig.DoneAttribute) then
		return false
	end
	if player:GetAttribute(TutorialConfig.HoldAttribute) then
		return true
	end
	return (tonumber(firstTrackLevel) or 1) <= 1
end

-- How many lumps this player is still owed an easy wash on, or 0.
function TutorialConfig.washBoostOf(player: Instance?): number
	if typeof(player) ~= "Instance" then
		return 0
	end
	local n = tonumber(player:GetAttribute(TutorialConfig.WashBoostAttribute)) or 0
	return (n > 0) and n or 0
end

-- The one question WashServer and WashClientController both ask, so the jet
-- the server erodes with and the jet the client draws can never disagree.
function TutorialConfig.washIsEasy(player: Instance?): boolean
	return TutorialConfig.washBoostOf(player) > 0
end

--[[
	"THE SERVER HAS FINISHED DECIDING WHO YOU ARE."

	Written once per join by SaveService, on EVERY outcome it can reach with the
	player still in the game -- a restored profile, a profile that would not load,
	and a place with no API access at all. It does not mean the load SUCCEEDED.
	It means the answer, whatever it is, is now on the player.

	WHY IT HAD TO EXIST (2026-09-10). looksNew below reads three attributes, and
	before the profile lands ALL THREE ARE MISSING -- which reads as nothing
	earned, no rebirths, not done, i.e. a brand-new player. So the test does not
	distinguish "new" from "not told yet", and every veteran looks new for the
	length of their own load.

	TutorialHud covered that with a wait on the opening shot, and the cover had a
	hole in it: awaitIntro gives the CURTAIN eight seconds to go up, and on a
	phone the loading screen routinely outlasts that. When it does, the wait falls
	through after 1.2s and the card goes up in front of somebody with three
	rebirths. Two players reported exactly that on 2026-09-10, both on mobile,
	both with rebirths -- "Step 4 of 4 buy sifter width will not get off my
	screen" and "Last part of the tutorial is stuck on my screen".

	THE INTRO WAIT IS THE WRONG QUESTION. It asks "has the cinematic finished",
	which was only ever a proxy for "has enough time passed for the profile to
	arrive". This asks the real one, and it is a fact rather than a stopwatch.

	STILL A CLIENT-READABLE ATTRIBUTE RATHER THAN A REMOTE, so this file's
	header stays true: the two halves of the onboarding do not speak. They both
	read the same facts off the same Player.
]]
TutorialConfig.ProfileAttribute = "ProfileSettled"

function TutorialConfig.profileSettled(player: Instance?): boolean
	if typeof(player) ~= "Instance" then
		return false
	end
	return player:GetAttribute(TutorialConfig.ProfileAttribute) == true
end

-- Nothing earned, no rebirths, not already done. See the header for why every
-- one of those is read off the player rather than asked of a system.
--
-- ⚠️ MEANINGLESS UNTIL profileSettled IS TRUE. Every attribute it reads arrives
-- with the restore, and a missing attribute is indistinguishable from a zero --
-- so before the profile lands this answers YES for absolutely everybody. Callers
-- wait for the settle first; see the note over ProfileAttribute for what it cost
-- when one of them only waited for a cinematic instead.
function TutorialConfig.looksNew(player: Instance?): boolean
	if typeof(player) ~= "Instance" then
		return false
	end
	if player:GetAttribute(TutorialConfig.DoneAttribute) then
		return false
	end
	return (tonumber(player:GetAttribute("TotalEarned")) or 0) <= 0
		and (tonumber(player:GetAttribute("Rebirths")) or 0) <= 0
end

return TutorialConfig
