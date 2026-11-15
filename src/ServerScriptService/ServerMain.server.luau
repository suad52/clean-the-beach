--[[
	ServerMain  --  ServerScriptService.ServerMain  (Script)

	CLEAN THE BEACH BUILD. Boots the sift/sell loop as an ADD-ON to the existing
	game. What it deliberately does NOT start:

		RollerServer      CTB already has its own beach sifter, a buried field
		                  and an upgrade path. Ours would be a second, competing
		                  collection loop. (Retired to variants/.)
		Beach geometry    CTB's beach is real Roblox Terrain; a flat part at the
		                  origin would cut straight through it.
		SellCounter       CTB's Beach.SellArea already exists and its SellPad is
		                  the trigger. CTBBridge routes that pad into
		                  SellServer.sellAll.

	The sifting bay is the ONE object this system adds to the world.

	ORDER MATTERS:
		0. Collision  -- registers the groups and binds PlayerAdded. FIRST, so
		                 the rules exist before any part in the game is built and
		                 before any player can join into them.
		1. Net        -- creates the remotes folder clients are waiting on.
		2. Inventory  -- must exist before anything can add to it.
		3. Bay        -- must be tagged before SiftServer binds to the tag.
		4a. Currency  -- the bridge names the store BEFORE Sell starts, or Sell
		                 builds a rival leaderstats balance nothing ever writes.
		4. Sell       -- SiftScreen spends coins through it, so it comes first.
		5. Screen     -- deck tiers + the kiosk upgrade prompt.
		6. Sift       -- reads rateFor() on every reversal.
		7. Bridge     -- last: it takes over the bag, so everything it talks to
		                 must be up. (Its currency claim is pulled forward to 4a.)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")

--[[
	0. WHO BUMPS INTO WHOM -- players and machines pass through each other and
	through their own kind. See the module header for the three rules and for
	why this does not break boarding a machine.

	First in the file on purpose. Registering a collision group is global state,
	and `apply` is only ever called on things built after this line.
]]
local CollisionGroups = require(script.Parent:WaitForChild("CollisionGroups"))
CollisionGroups.start()

-- 1. Remotes.
require(Modules:WaitForChild("Net"))

-- 2. Authoritative state.
local InventoryController = require(Modules:WaitForChild("InventoryController"))
InventoryController.Server.start()

-- 3. The sifting bay.
--
-- Placed on the built strip behind spawn. Every part of that is load-bearing:
--   * CTB's rakeable field spans -HALF..HALF on X and Z, so anything inside it
--     would sit on terrain the player rakes flat. HALF is now 128 (the field
--     went 32x32 -> 64x64 for multiplayer), which is why this whole row sits at
--     Z = -166..-173 rather than the -75..-88 it used to.
--   * The strip holds three buildings in a row, evenly spaced with an 8.8 stud
--     alley between each: sifting bay (-30), SellArea (-3), and the Beach Shop
--     under the UpgradeKiosk sign (27). The row spans -37.8 .. +37.8, centred
--     on X = 0 so it reads as one frontage rather than two clumps.
--   * SpawnLocation is at (0, -139), IN FRONT of the row and invisible: it is a
--     14x14 WoodPlanks slab, and left visible on open sand it reads as a random
--     wooden square nobody built. Buried to the sand line, still collidable.
--
--     It was at -150, which put the DEFAULT CAMERA -- 12.5 studs behind a player
--     facing +Z, so about z -162 -- inside SellArea's own bounding box. Fourteen
--     parts sat within nine studs of it, the awning and roof among them, so the
--     first thing anyone saw on joining was the underside of the sell shop's
--     tent. Line of sight to the character was never blocked, which is why this
--     read as a camera bug rather than an obstruction.
--
--     It then sat at -135 for the same reason, and moved back to -139 when the
--     spawn was asked to sit further back. FOUR STUDS IS THE WHOLE BUDGET, and
--     the ceiling is the camera, not the pad: moving the pad back moves the
--     camera back with it, at the sell shop. Measured against the nine-stud
--     rule above, with the camera at padZ - 12.5:
--
--         back  0 (-135)  nearest 6.8   SellPad and PadGlow only
--         back  4 (-139)  nearest 4.1   SellPad and PadGlow only
--         back  6 (-141)  nearest 3.6   THE AWNING RE-ENTERS at 9.0
--         back 15 (-150)  nearest 2.8   the original bug, exactly
--
--     SellPad and PadGlow are flat ground and were already inside the rule at
--     -135, so they are not what it guards; the awning is. -139 is therefore the
--     last whole stud before this regresses to the tent-underside shot.
--
--     The field constraint is unaffected. At -135 the pad's front edge (z -128)
--     sat exactly on the rakeable boundary; at -139 it is at -132, further
--     outside it, so the slab still never overlaps terrain the player rakes
--     flat. Moving the pad FORWARD is what that constraint bounds.
--   * Ground there is Y = 3.2 (the SellPad surface height).
--
-- If Config.HALF changes again, this row has to move with it or the buildings
-- end up standing in the rakeable field.
local BayBuilder = require(script.Parent:WaitForChild("BayBuilder"))
-- Second from the right, one even alley off the sell counter.
--
-- This is a FALLBACK origin: Beach.WashBay is authored and tagged in the place,
-- so ensureWashBay adopts that and never runs this. It is kept in step with the
-- authored model anyway, because the day someone deletes the model this is the
-- only thing that decides where it comes back.
--
-- THE ROW, left to right: car pad, SHOP, WASH BAY, sell counter, index. The
-- middle two traded places (2026-08-28) because the tutorial walks sell -> wash
-- -> shop, and the shop standing between the other two made the first of those
-- legs a 51 stud hike past a building the player had no reason to visit yet.
-- Swapping them rather than inserting anything kept every alley width and the
-- row's total length exactly as they were, so the sell counter and the index
-- did not move at all. Wash bay to sell pad is 23.5 studs now.
--
-- y = 2.84, not the 3.2 it was: the sand under the new slot probes 0.36 lower
-- than under the old one, and the shack is authored to sit flush on it.
--
-- No rotation, so the shack faces +Z -- the same way as the sell counter, out
-- toward the beach.
BayBuilder.ensureWashBay(CFrame.new(-1.48, 2.84, -171.15))

--[[
	3a. The car spawner, at the end of the row past the wash bay. Same adoption
	contract as the bays: if a tagged pad is already in the place this does
	nothing at all.

	THE SHOWROOM ONE. `showroom` widens it from one bay to one per machine on
	sale plus one to deliver yours into -- 53 x 36 rather than 16 x 22 -- and
	AtvServer stands the actual stock on it at boot.

	x = -69, MOVED 17 STUDS WEST, and the move is what pays for the width. The
	pad grew 37 studs and there was nowhere to put them going east: its eastern
	neighbour's left wall is at -37.6 and the row's alley was already only 6
	studs. (That neighbour is the SHOP since the 2026-08-28 swap; it was the wash
	bay when this was written, and the wall is in the same place either way.)
	Going west there was nothing until the palms at -91.4, so the pad now runs
	-95.5 to -42.5 and KEEPS a 3.8 stud alley off it. Measured, not
	estimated -- the ground under that whole footprint probes 2.52 to 3.45,
	which is why the showroom slab is 3.0 thick where the plain one is 1.6.

	y = 3.2 is the sand there (probed).
]]
local CarSpawnerBuilder = require(script.Parent:WaitForChild("CarSpawnerBuilder"))
CarSpawnerBuilder.ensureWorld(CFrame.new(-69, 3.2, -172.25), { showroom = true })

-- 3b. The shop, at Clean the Beach's own sign. Same adoption contract as the bay:
-- if Beach.Store is already authored this does nothing.
--
-- THIS ONE WAS THIRTY STUDS STALE and had been for a while: the shop was moved
-- in the place file and its fallback origin was not, so a rebuild would have put
-- the Beach Shop down on top of the sell counter. Adoption is what hid it --
-- ensureWorld finds Beach.Store and returns before it ever reads this.
-- y = 3.0 is still the floor height; the sand there is terrain at ~2.67.
local StoreBuilder = require(script.Parent:WaitForChild("StoreBuilder"))
StoreBuilder.ensureWorld(CFrame.new(-27.6, 3.0, -173.05))

-- 4-6. Systems.
local SellServer = require(script.Parent:WaitForChild("SellServer"))

--[[
	THE SIFT SYSTEM IS REMOVED (2026-08), not just switched off. SiftScreen,
	SiftServer and SiftClientController are parked -- anti-cheat design notes
	intact -- in ServerStorage.SiftSystem_BACKUP_2026_08_24, and everything
	that existed only to serve them went too: GameConfig.Sifting and
	GameConfig.Screen, the SiftBay tag, BayBuilder.buildSiftBay/ensureWorld,
	and six of the seven Sift* remote names in Net. The one survivor is
	SiftItemCleaned: RevealPopup and MenuHud connect to it at client boot and
	Net.get asserts on unknown names, so the name stays (nothing fires it).

	Restoring the feature is: move the three modules back where the backup
	folder's README says, restore the config tables and remote names it lists,
	and re-add the two start() calls after SellServer.start() below.
]]

-- 4a. WHO OWNS THE MONEY -- decided before anything can pay anybody.
--
-- CTB keeps the balance on a player attribute. SellServer asks "has somebody
-- claimed the currency?" exactly once, inside start(), and builds its OWN
-- leaderstats balance if the answer is no. The bridge used to answer at step 7,
-- three calls too late, so every player ended up with a second "Coins" on the
-- player list that was created at 0 and never written again -- one number on
-- the leaderboard, a completely different one on the HUD.
--
-- The rest of the bridge still starts at step 7; this is only the claim.
local CTBBridge = require(script.Parent:WaitForChild("CTBBridge"))
CTBBridge.claimCurrency()

SellServer.start()

--[[
	6b. THE GAME PASSES, and they are started HERE now rather than only from
	AtvServer.

	They used to be started at step 9, from AtvServer.start(), because the only
	passes in the game were the two machines that file sells. The wash bay's
	Instant Wash pass broke that: it is resolved by the same module, and hanging
	it off the car spawner means a place that never reaches step 9 -- an error
	in AtvServer, the showroom disabled, a test map with no pad -- has a wash
	HUD whose pass button never learns that anybody owns anything.

	start() is guarded, so AtvServer's call is now a no-op and has been left
	where it is rather than moved: it documents an ordering that still matters
	to the showroom, and deleting it would only invite the ordering back.

	Before WashServer, so the join sweep is already running by the time the
	first player can stand at a bay. It does not have to be -- ownsFlat re-asks
	Roblox on a miss -- but a first tap that answers from the record beats one
	that waits on a web call.
]]
local GamePassService = require(script.Parent:WaitForChild("GamePassService"))
GamePassService.start()

local WasherTool = require(script.Parent:WaitForChild("WasherTool"))
local WashServer = require(script.Parent:WaitForChild("WashServer"))
WasherTool.start()
WashServer.start()

-- 7. The CTB seam (required and asked for the currency back at 4a).
--
-- Give the coin-shower FX a world anchor: CTB's own sell pad.
local beach = workspace:FindFirstChild("Beach")
local sellPad = beach and beach:FindFirstChild("SellPad", true)
if sellPad and sellPad:IsA("BasePart") then
	CTBBridge.counter = { anchor = sellPad }
end

CTBBridge.start()

-- 8. Progression LAST: it claims SellServer.OnCoinsChanged to track lifetime
-- earnings, so it has to be the final owner of that hook.
local ProgressionServer = require(script.Parent:WaitForChild("ProgressionServer"))
ProgressionServer.fxAnchor = sellPad
ProgressionServer.start()

local RewardsServer = require(script.Parent:WaitForChild("RewardsServer"))
RewardsServer.start()

-- 9. The ATVs. AFTER SellServer (it spends through the one grant path) and
-- after ProgressionServer (it reads Rebirths), and it binds its prompt to the
-- CarSpawner pad built back at 3a.
local AtvServer = require(script.Parent:WaitForChild("AtvServer"))
AtvServer.start()

-- 9b. THE PETS. After SellServer, because an egg is bought through the one
-- grant path, and after every world pass above, because the plazas find their
-- ground by raycast and everything else is already standing on it.
--
-- Builder first, server second. PetServer binds to the PetStation tag and would
-- pick up a later station through CollectionService either way, but building
-- first means the prompts are live on the first frame rather than the second --
-- the difference between walking up to a station and walking up to a plinth.
local PetStationBuilder = require(script.Parent:WaitForChild("PetStationBuilder"))
PetStationBuilder.ensureWorld()

local PetServer = require(script.Parent:WaitForChild("PetServer"))
PetServer.start()

--[[
	9b-b. THE SIFTER'S WARDROBE. Which skins an account has claimed, which one it
	is wearing, and the walk-up test at each of the three centrepieces.

	BEFORE SaveService, and that IS a hard requirement rather than tidiness:
	that module requires this one for its persistence seam (exportFor / restore)
	and WRAPS SkinService.OnSkinsChanged rather than assigning it -- the same
	contract it has with SellServer and PetServer -- so this has to have claimed
	its own hook first.

	It depends on nothing above it. The plinths themselves are put up by
	CTB_Server once the three rooms exist, and they register themselves here;
	until they do, the walk-up test simply finds no claim points and costs a
	distance check against an empty table.
]]
local SkinService = require(script.Parent:WaitForChild("SkinService"))
SkinService.start()

-- 9c. PERSISTENCE. After ProgressionServer and PetServer, and that is a hard
-- requirement rather than tidiness: SaveService WRAPS SellServer.OnCoinsChanged
-- and PetServer.OnPetsChanged rather than assigning them, so both owners have to
-- have claimed theirs first. Started before TrashSeeder only because nothing
-- below this line touches a player.
local SaveService = require(script.Parent:WaitForChild("SaveService"))
SaveService.start()

--[[
	9c-b. DEVELOPER-PRODUCT RECEIPTS. Immediately after SaveService, because that
	is what fills in ProductServer.CommitProfile -- and a receipt that arrives
	before the hook exists is answered NotProcessedYet and held by Roblox rather
	than being paid out against a profile nothing can write.

	NOTHING IS ON SALE THROUGH IT YET. Every id in ProductConfig is 0, which
	ProductConfig.all() drops, so this starts, assigns MarketplaceService
	ProcessReceipt and prints that it has nothing to sell. That is the order
	ShopConfig's header asks for -- the handler exists and is tested before any
	button can take a player's Robux -- and turning a product on is then a matter
	of pasting its id into ProductConfig and nothing else.

	IT MUST BE THE ONLY ASSIGNMENT OF ProcessReceipt IN THE GAME. It is a single
	callback, not an event: a second file taking it silently replaces this one,
	and every purchase stops paying out with no error anywhere.
]]
local ProductServer = require(script.Parent:WaitForChild("ProductServer"))
ProductServer.start()

-- 9d. THE ONBOARDING'S SERVER HALF. After SaveService, and that is the same
-- hard requirement 9c has: every attribute it tests to decide whether a player
-- is new -- TotalEarned, Rebirths, TutorialDone -- is written by that module's
-- restore, so arming before it exists would answer "new" for a returning
-- player with twenty rebirths. It waits on SaveService.isLoaded per player
-- rather than on this ordering alone; the ordering is what makes that wait
-- resolvable at all.
--
-- CTB_Server calls into this module too, once per find. Requiring the same
-- ModuleScript from both scripts hands back the same table, so there is one
-- lump ledger rather than two.
local TutorialServer = require(script.Parent:WaitForChild("TutorialServer"))
TutorialServer.start()

-- 9d-b. THE FIRST-REBIRTH NUDGE'S SERVER HALF. After SaveService for the same
-- reason 9d is: RebirthPromptConfig.SeenAttribute arrives with the restored
-- profile, and this module only ever STAMPS it -- it never reads it to decide
-- anything -- so the ordering is a courtesy here rather than a hard
-- requirement. Grouped with the onboarding step above it anyway, since it is
-- the same shape of once-per-account card.
local RebirthPromptServer = require(script.Parent:WaitForChild("RebirthPromptServer"))
RebirthPromptServer.start()

--[[
	9d-c. THE FUNNELS -- the onboarding, the map ladder and the tide. The one
	place in the game that talks to AnalyticsService.

	AFTER SaveService for the hard reason 9d and 9e have, and it is the same
	sentence: every attribute it reads to decide where a player stands --
	Rebirths, TotalEarned, TutorialDone -- arrives with the restored profile, so
	measuring before it lands opens an onboarding funnel on a veteran and files
	their map rung as the home beach. It waits on SaveService.isLoaded per player
	rather than trusting this ordering alone; the ordering is what makes that
	wait resolvable.

	AFTER TutorialServer (9d) by preference rather than by requirement. The two
	are independent -- neither calls the other, and both ask TutorialConfig the
	same question about the same player -- but this one is the observer of that
	one, and reading them in that order is how the next person finds it.

	IT ADDS NOTHING TO THE WORLD and takes nothing from anything above: no
	geometry, no remote, no attribute of its own. Its failure mode is a missing
	statistic, which is why it sits down here with the other things whose worst
	day should not be anybody else's.
]]
local FunnelServer = require(script.Parent:WaitForChild("FunnelServer"))
FunnelServer.start()

-- 9e. THE STARTER PACK. After SaveService for the same hard reason 9d has, and
-- it is worth more here than a wrong answer usually is: the flag that says this
-- account has already been paid arrives with the profile, so a grant that ran
-- before it would hand 20,000 coins to somebody who was paid on their last join.
-- It waits on SaveService.isLoaded per player rather than trusting this ordering
-- alone; the ordering is what makes that wait resolvable.
--
-- Also after PetServer (9b) and SellServer (4a): the pack hands over one of
-- each, through their own APIs, rather than writing an attribute itself.
local StarterPackService = require(script.Parent:WaitForChild("StarterPackService"))
StarterPackService.start()

-- 9f. THE FREE REWARD. After SaveService for the same reason 9d and 9e are: the
-- "already claimed" flag arrives with the profile, and a grant that ran before it
-- would pay a returning player their 1,000 coins a second time. It waits on
-- SaveService.isLoaded per player rather than trusting this ordering alone.
--
-- The BOARD is built here too, and after the world passes above so its raycast
-- lands on real sand rather than on nothing. It mirrors the leaderboards, which
-- go up at step 13 -- it does not depend on them, only on their config.
local FreeRewardService = require(script.Parent:WaitForChild("FreeRewardService"))
FreeRewardService.start()

-- AFTER SkinService and PetServer, both of which it hands work to, and after
-- SaveService for the same reason StarterPackService is: the pet is a one-time
-- grant and its flag arrives with the profile.
local VipService = require(script.Parent:WaitForChild("VipService"))
VipService.start()
local FreeRewardBoard = require(script.Parent:WaitForChild("FreeRewardBoard"))
local okBoard, boardErr = pcall(FreeRewardBoard.build)
if not okBoard then
	-- A sign failing to go up must never take the reward with it: the panel and
	-- the grant are both reachable without it.
	warn("[FreeReward] board failed to build:", boardErr)
end


-- The beach had nothing on it: workspace.Trash was empty and nothing carried
-- the CollectibleTrash tag, so the WeightSystem had nothing to pick up and the
-- wash bay could never be handed a crusted find. This fills the sand; it only
-- seeds when the folder is bare, so hand-placed props are never doubled.
local TrashSeeder = require(script.Parent:WaitForChild("TrashSeeder"))
TrashSeeder.start()

-- 10. The signs, LAST of the world passes: it re-asserts one lettering style
-- over every board standing in the row, whether that board was authored in the
-- place file or built above. Anything that puts up a sign has to have run first.
local SignDresser = require(script.Parent:WaitForChild("SignDresser"))
SignDresser.start()

--[[
	10b. THE HOME BEACH'S SHADOW PASS -- the one every other island already had.

	Island3Builder.finalSweeps and Island4Builder do this to their own work and
	report it ("617 shadow casters trimmed"). The beach never did, because it is
	ADOPTED from the place file rather than built by a module with a finalSweeps
	of its own -- so nothing owned the pass. Measured on the client, the beach
	was 916 parts of which 916 cast shadows, against the cove's 240 of 916.

	That is the wrong island to skip. It is the one every player loads first, the
	one they spend the most time on, and the one a phone meets before it has any
	reason to trust the game.

	THE RULE IS COPIED FROM finalSweeps DELIBERATELY, not reinvented: anything
	under a stud on its smallest axis (rope, straps, slats, sign trim -- their
	shadow is thinner than a pixel), anything Neon (a surface that is supposed to
	be emitting light should not also cast a hard black shadow), and anything more
	than half transparent (Roblox shadows those as solid). Nothing that reads as
	an object at arm's length loses its shadow.

	RUN LAST, after every builder and after SignDresser, so it catches boards and
	props that were put up above rather than only what was in the file.

	Scoped to the home island. The other four run their own pass, and their parts
	are streamed out from here anyway.
]]
--[[
	THE EXCLUSION LIST IS GONE AND THE PASS RUNS EVERYWHERE.  2026-09-19.

	It used to skip ten folders on the grounds that each "runs its own pass".
	Four of them genuinely do -- Island3, Island4, Island5 and FrozenWreck report
	their own trims at boot and measure 6-46% casters afterwards. The others were
	excluded on a promise nothing kept, and the numbers say so plainly. Measured
	in Play, casters as a share of parts:

		Island2 (Dunes)    3,528 of 3,554   99%   <- and no trim line at boot
		AfkShore             797 of   797  100%
		DuelArenas           128 of   128  100%
		Vault                852 of   949   89%
		PetStations          277 of   322   86%
		Ferries              511 of   672   76%
		...against Island3 32%, Island4 46%, Island5 26%, FrozenWreck 6%

	That is 4,453 casters in the first three alone -- a third of the game's total
	-- held out of the one pass that would have caught them. Dunes is the worst of
	it and the reason is visible in Island2Builder, which sets CastShadow = true
	on its props and has no sweep afterwards.

	WHY IT IS SAFE TO RUN OVER EVERYTHING. The rule below only removes shadows
	that were never visible: under a stud on the smallest axis, Neon, or more than
	half transparent. A folder that already swept itself is a no-op here, because
	the `if p.CastShadow` test skips what it already turned off. So the worst case
	of dropping the list is one extra walk of parts at boot, once, on the server.
	The worst case of KEEPING it is what the table above shows.

	IT REPORTS PER AREA NOW, which is the part that stops this recurring. A single
	total is what let "Island2 is excluded and trims nothing" hide for as long as
	it did; a line per folder makes an untrimmed island obvious in the boot log.

	WHY THIS MATTERS ON A PHONE, from the game's own feedback telemetry: mobile
	players who sit at graphics quality 0 hold 60 fps, and the one who reported
	from quality 10 measured 40 fps with a low of 9. The game currently survives
	on phones largely because Roblox turns this work off for them.
]]
--[[
	IT RUNS TWICE, AND THE SECOND ONE IS NOT BELT AND BRACES.  2026-09-19.

	The note above says "RUN LAST, after every builder". This line is not last and
	cannot be: the big islands -- Ashfall, the Shrine, Magma, Penguin, the Wreck --
	are built by their own Scripts, not from this file, so they are RACING this
	pass rather than ordered against it. Whoever wins varies per boot.

	Measured across two boots of the same place, counting live casters afterwards:

		boot A   10,386 casters   (the pass caught Island4: 483 trimmed)
		boot B   11,268 casters   (it did not)

	-- an 880-caster swing decided by scheduling. A saving that only sometimes
	happens is worse than a smaller one that always does, because nobody can tell
	which boot they are looking at when the reports come in.

	SO: ONCE NOW, for everything already standing, and once on a delay for
	whatever finished after. The second pass is free when there is nothing to do
	-- `if p.CastShadow` skips what is already off, so a part trimmed by the first
	sweep costs one boolean read -- and it is what makes the number the same every
	time.

	TWENTY SECONDS, against a world that logs "[Intro] world ready" at about four.
	Generous on purpose: this is a one-off walk of a few thousand parts on the
	server, nobody is waiting on it, and being late costs nothing while being
	early costs the whole point.
]]
do
	--[[
		PLAYER CHARACTERS ARE LEFT ALONE, and that is the late pass's doing rather
		than a rule the first one needed.

		Caught in the log: "IsABigBot 15/17" -- the sweep had walked an avatar and
		taken the shadows off fifteen of its thin accessory parts. The rule is not
		wrong about them (a strap's shadow really is thinner than a pixel), but the
		TIMING is: only characters that happen to be standing at the twenty second
		mark get it. Somebody who joins at minute ten does not, and neither does
		anybody after they respawn.

		A cosmetic rule that applies to some players and not others, decided by when
		they happened to join, is worse than not applying it at all -- so the sweep
		is scenery only, which is what it was always described as.
	]]
	local Players = game:GetService("Players")
	local function isCharacter(inst: Instance): boolean
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr.Character == inst then
				return true
			end
		end
		return false
	end

	local function shadowPass(label: string)
		local rows, trimmed, seen = {}, 0, 0
		for _, top in ipairs(workspace:GetChildren()) do
			if not top:IsA("Terrain") and not isCharacter(top) then
				local cut, had = 0, 0
				for _, p in ipairs(top:GetDescendants()) do
					if p:IsA("BasePart") then
						seen += 1
						if p.CastShadow then
							had += 1
							local s = p.Size
							if math.min(s.X, s.Y, s.Z) < 1.0
								or p.Material == Enum.Material.Neon
								or p.Transparency > 0.5 then
								p.CastShadow = false
								cut += 1
								trimmed += 1
							end
						end
					end
				end
				if cut > 0 then
					table.insert(rows, string.format("%s %d/%d", top.Name, cut, had))
				end
			end
		end
		print(string.format("[CleanTheBeach] shadow pass (%s): %d of %d parts trimmed",
			label, trimmed, seen))
		if #rows > 0 then
			print(string.format("[CleanTheBeach] shadow pass (%s) by area (cut/had): %s",
				label, table.concat(rows, ", ")))
		end
		return trimmed
	end

	shadowPass("boot")
	-- Spawned, so nothing below this line waits twenty seconds to start.
	task.delay(20, function()
		shadowPass("late")
	end)
end

-- 11. THE LONG SHORE, the idle area. After SignDresser on purpose: it puts up
-- five boards of its own and wants the same lettering pass over them. It is
-- also last because nothing else in the game depends on it -- the shore is
-- eight thousand studs away and the only thing that reaches it is the prompt
-- on the beach shelter it builds.
local AfkService = require(script.Parent:WaitForChild("AfkService"))
AfkService.start()

-- 12. THE CLEAN-OFF, the 1v1 arenas. After AfkService because beginMatch wakes
-- an idler through AfkBus before it moves them, and the bus has to have a
-- provider registered by then. Like the shore, nothing else depends on it: the
-- arenas are twelve thousand studs out and the only way in is a challenge.
local DuelService = require(script.Parent:WaitForChild("DuelService"))
DuelService.start()

-- 12b. PET TRADING. After PetServer, because the exchange is one call into it
-- (PetServer.applyTrade), and after ProgressionServer because the door is the
-- Rebirths attribute and that is ProgressionServer's to write. Nothing else
-- depends on this: it adds no geometry and touches no other system.
local TradeService = require(script.Parent:WaitForChild("TradeService"))
TradeService.start()
--[[
	PERSISTENCE  --  BUILT. See ServerScriptService.SaveService.

	This note used to describe the seams and ask somebody to wire them up. They
	are wired: SaveService (step 9c above) persists coins, every Lv_ track,
	Rebirths, TideEarned, TotalEarned, AtvTier and the whole pet collection to a
	session-locked DataStore, through those very seams and without reaching past
	any owner into its private state.

	Two things it deliberately still does NOT save, and both are unchanged:

		Carried items. A crusted lump has no rolled value and no revealed
		identity, so there is nothing meaningful to write down until it has been
		through a wash bay.

		WasherLevel / WasherPressure / WasherSpread / WasherLabel. All four are
		DERIVED -- ProgressionServer.applyAll writes them from the Pressure track,
		and SaveService calls applyAll after a restore. Saving them as well would
		be a second copy of a number that already has an owner.

	IN STUDIO it needs Game Settings -> Security -> Enable Studio Access to API
	Services. Without it SaveService warns once and runs as a no-op, which is why
	a Studio session still behaves exactly as it did before.
]]

-- 12. FEEDBACK. Last, and independent of everything above it: it owns one
-- DataStore and one pair of remotes, talks to nothing else in the game, and the
-- Settings panel degrades to an honest "offline" message if it never starts. It
-- is the one system here whose failure should not take anything else down.
local FeedbackServer = require(script.Parent:WaitForChild("FeedbackServer"))
FeedbackServer.start()

--[[
	13. THE WORLD LEADERBOARDS. Three OrderedDataStores and three boards by the
	spawn: most money, most trash picked up, most rebirths.

	AFTER SaveService, and that ordering is the one thing about this step that
	matters. Every value it publishes is read live off the player, and a player
	whose profile has not loaded yet reads as zero -- so it gates every write on
	SaveService.isLoaded, which means SaveService has to exist by the time the
	first publish cycle runs. See note 1 in LeaderboardService's header for what
	publishing a zero would actually cost somebody.

	Last in the file with FeedbackServer, and for the same reason: it owns its
	own stores, talks to nothing that talks back, and a place with no API access
	gets three boards saying so and a game that is otherwise unaffected.
]]
local LeaderboardService = require(script.Parent:WaitForChild("LeaderboardService"))
LeaderboardService.start()

--[[
	14. THE SANDBOT, the deployable drone.

	AFTER CTB_Server, and that is the one ordering constraint it has. The drone
	does not rake: it asks CTBBridge to, and CTB_Server is what installs the rake
	there (Bridge.setDroneSweep / setDroneDirty, next to the sweep loop). Started
	before that, a drone deployed in the first moments of a server would drive
	around sweeping nothing until CTB_Server got round to it.

	That is a weak constraint rather than a race, because CTB_Server is a Script
	that runs on its own and this is the last line of ServerMain -- but it is the
	reason this is last rather than filed next to GamePassService with the other
	monetisation.

	IT PUTS UP THE SANDBOT HOMES, and that is new: start() calls
	SandbotDockBuilder.ensureAll, which stands a dock beside every car spawner in
	the game and binds one ProximityPrompt to each. The drone used to be sent out
	from a key on the HUD and is sent out from those now.

	That is ANOTHER reason for this to be last rather than merely a tolerable
	place for it: the sweep wants as much of the world standing as it can get.
	It does not get all of it -- the dunes, the cove and Ashfall are built by
	CTB_Server AFTER this line prints -- which is why the builder also watches
	the CarSpawner tag rather than trusting one pass. Ashfall in particular
	destroys and rebuilds its whole island, dock included.

	Nothing else depends on it. It puts up no sign pass of its own (the dock
	letters its own board through SignKit, the way the car pad does) and takes
	nothing from anything above.
]]
local SandbotService = require(script.Parent:WaitForChild("SandbotService"))
SandbotService.start()

--[[
	14b. THE PENGUINS. Pet one, get a coin -- PenguinService binds a prompt to
	every Model tagged Penguin (Island5Builder tags them, and it runs after this
	script, so the service binds by GetInstanceAddedSignal) and pays through
	SellServer.addCoins like everything else. Same shape as the sandbot service
	above it and nothing below depends on it.
]]
local PenguinService = require(script.Parent:WaitForChild("PenguinService"))
PenguinService.start()

--[[
	15. THE TEN-MINUTE CLOCK, and it goes last because it acts on almost
	everything above it.

	One rotating server event every ten minutes -- Golden Hour, Scrap Rush and
	Golden Cans today. It needs SellServer (coins, and the multiplier it reads
	through EventConfig rather than through a require) and WeightService (the bag
	lift), both of which are up long before this line.

	It is a RECONCILER: it asks EventConfig what should be happening once a
	second and makes that true, so starting it here rather than at the top costs
	nothing at all -- a server that boots into the middle of an event picks that
	event up on its first tick.

	The timetable is arithmetic on os.time(), so every server in the game runs
	the same event in the same minute without any of them talking to each other.
]]
local EventService = require(script.Parent:WaitForChild("EventService"))
EventService.start()

--[[
	16. THE BOUGHT GOLDEN HOUR, beside the clock it copies.

	One developer product: fifteen minutes at double pay, per player, stacking on
	top of the rebirth multiplier, the 2x Cash pass and whatever the clock above
	is running. SellServer applies it; this only starts the sweep that ends one.

	ORDER-INDEPENDENT, and later than it needs to be on purpose. Nothing above
	this line reads a boost, and the two things that DO -- SellServer's till and
	ProductServer's receipt handler -- both go through BoostConfig, which is
	replicated data that needs no service running. A boost restored by SaveService
	minutes before this line is already being paid at the till; all start() adds
	is the tidy-up that clears an expired one and says so.
]]
local BoostService = require(script.Parent:WaitForChild("BoostService"))
BoostService.start()

--[[
	16b. BEACH BUDDIES, beside the two multipliers above it because it is a third
	one of the same shape.

	Counts how many people on this server are on your friends list and writes it
	to an attribute; SellServer reads that through BuddyConfig and pays a tenth
	extra per friend, capped at four. The service pays nothing itself.

	ORDER-INDEPENDENT for the same reason BoostService above is: the till reads
	the attribute through replicated config, not through this module, so a server
	that has not reached this line yet simply pays x1 -- which is the correct
	answer before anybody has been counted. All start() adds is the counting.

	LAST of the paying services on purpose. Its recount yields on IsFriendsWith,
	which is a web call, and nothing above this line should wait on the network.
]]
local BuddyService = require(script.Parent:WaitForChild("BuddyService"))
BuddyService.start()

--[[
	16c. REDEEMABLE CODES, and it goes here because it pays through SellServer
	like the two above and needs nothing else at all.

	Owns one remote. The codes, what they pay and how a typed string becomes a key
	all live in CodeConfig, which is replicated -- so retiring a code is deleting
	one row there and touching nothing here.

	SaveService already persists a redemption (one Code_<KEY> attribute per code,
	folded into the profile on save and put back on load), so a code survives a
	rejoin without this service being involved in a save at all.
]]
local CodeService = require(script.Parent:WaitForChild("CodeService"))
CodeService.start()

--[[
	16d. BADGES, and they go last of all because nothing depends on them and they
	are the only thing in this file that can be entirely inert.

	Every id in BadgeConfig starts at 0. A badge cannot be created from code -- it
	is made in the Creator Dashboard at 100 Robux each -- so until somebody pastes
	an id in, this service watches two attributes and awards nothing. It says so
	at boot, naming each uncreated badge, the same way ProductServer names the
	developer product it cannot sell.

	IT WATCHES `Rebirths` AND `AtvTier` rather than hooking the code that moves
	them, so a rebirth cannot be interrupted by a badge web call. Every award is
	spawned and pcall'd for the same reason.
]]
local BadgeService = require(script.Parent:WaitForChild("BadgeService"))
BadgeService.start()

--[[
	17. THE ONE SETTING THAT IS KEPT.

	Owns the SettingSave remote and the whitelist behind it. SaveService already
	requires this module for its exportFor/restore pair, so by this line it is
	long since loaded -- all start() adds is the remote handler.

	ORDER-INDEPENDENT: restoring a saved setting is SaveService's job and happens
	on join, whether or not the remote is listening yet, and the only thing that
	fires the remote is a player pressing a button in a menu.
]]
local SettingsServer = require(script.Parent:WaitForChild("SettingsServer"))
SettingsServer.start()

print("[BeachCleanup] sift/sell online -- bolted onto Clean the Beach")
