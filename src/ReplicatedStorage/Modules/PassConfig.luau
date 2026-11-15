--[[
	PassConfig  --  ReplicatedStorage.Modules.PassConfig

	Every game pass that is NOT a vehicle.

	WHY THIS IS NOT IN AtvConfig, AND NOT IN GamePassService EITHER
	---------------------------------------------------------------
	AtvConfig carries the two car passes because a pass there belongs to a TIER
	-- it is one field on a machine, and it means "you own that machine". A pass
	that unlocks a verb has no tier to hang off, and bolting a fake one onto
	AtvConfig would put a wash button in the car showroom's table.

	GamePassService is the other obvious home and it is the wrong one for a
	different reason: it is SERVER-ONLY, and the client needs two of these
	fields. It needs the ID, because PromptGamePassPurchase is a client call
	and there is no server-side way to open a purchase dialog. And it needs the
	ATTRIBUTE NAME, because that is what it paints its button off. Hard-coding
	either one on the client is how the two halves drift: a pass id typed twice
	is a pass id that gets corrected once.

	So the numbers live here, replicated, and both sides read the same table.

	WHAT IS DELIBERATELY NOT IN HERE
	--------------------------------
	Whether anybody OWNS one. `owns` below reads a replicated attribute, which
	is the client's copy and is only ever good enough to decide what a button
	says. The server never consults it -- GamePassService.ownsPassId asks Roblox
	and answers off its own record. See the note on `owns`.

	The PRICE is not in here either, for the same reason it is not in AtvConfig:
	a price typed into a config file is a price that goes stale the first time
	somebody runs a sale. GamePassService reads it off Roblox at boot and
	publishes it into the info folder; `price` and `onSale` below read it back.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PassConfig = {}

--[[
	THE FOLDER NAME IS HISTORICAL AND IS LEFT ALONE ON PURPOSE.

	GamePassService published the two car passes into `AtvPassInfo` when they
	were the only passes in the game, and AtvClient waits on that name. It is
	keyed by pass ID rather than by anything car-shaped, so it took the wash
	pass with no change at all -- and renaming it would be a rename in three
	files to fix a word nobody sees.
]]
PassConfig.InfoFolder = "AtvPassInfo"

--[[
	id          the Roblox game pass. `Instant Wash` and `Quick Sell` are both
	            on sale in this place.
	attribute   what GamePassService writes on the Player when it has an answer,
	            and the ONLY thing a client may read to decide what to draw.
	name        as it reads on the store page, so a button and a toast agree
	            with the dialog Roblox opens over them.

	supersedesTrack / supersededNote
	            the upgrade track this pass makes pointless, and the line the
	            shop prints in place of that row's stat. See the note on
	            `supersederOf` -- this is a DISPLAY-AND-REFUSE pair, and it is
	            emphatically not an instruction to write anybody's level.

	payMultiplier
	            what a sale at the counter is multiplied by for a holder. Absent
	            on every pass but one. See the note on `paying` -- the NUMBER is
	            here rather than in SellServer for the same reason the id is here
	            rather than in the HUD.
]]
--[[
	THE STARTER PACK IS A THIRD KIND OF PASS, and it is in this table anyway.

	The two kinds the game had were TIER passes (own a machine) and FLAT passes
	(unlock a verb). This is neither: it is a BUNDLE -- 20,000 coins and one
	exclusive pet, handed over once and never again.

	It lives in `Passes` regardless, because everything a pass needs is already
	wired off this table and none of it cares what the pass DOES: GamePassService
	publishes its price, sweeps ownership on join, re-resolves it on purchase, and
	writes `attribute`. Inventing a third table would mean a third copy of all of
	that for one row.

	WHAT IT DOES NOT GET FROM HERE IS THE GRANT. `attribute` answers "do they own
	the pass", which is TRUE FOREVER once bought and re-resolved on every single
	join -- so a grant hung off it would pay the 20,000 out again every time the
	player rejoined. The pack is handed over by StarterPackService, which gates on
	a SAVED flag instead. See ClaimedAttribute below.
]]
PassConfig.Passes = {
	StarterPack = {
		key = "StarterPack",
		id = 1954531042,
		name = "Starter Pack",
		attribute = "OwnsStarterPack",
		blurb = "20,000 coins and the exclusive Kingsmane pet.",
	},
	InstantWash = {
		key = "InstantWash",
		id = 1955646783,
		name = "Instant Wash",
		attribute = "OwnsInstantWash",
		-- "the whole crust" was the old promise, and the button outgrew it: one
		-- tap now finishes the rock on the stand AND every other crusted find in
		-- the bag (WashServer.bulkWash). The blurb is what the shop row prints,
		-- so this string is the only place most players will ever read the
		-- feature -- keep it about the BAG, which is what is being sold.
		blurb = "One tap washes every crusted find in your bag.",
		-- Water Pressure buys a shorter wash, and this pass removes the wait
		-- outright -- every clump comes off the instant the jet touches it,
		-- whether they use the button or wash by hand. So every rung of that
		-- ladder is worth exactly nothing to a pass holder, and the shop should
		-- say so rather than take their coins for it.
		supersedesTrack = "Pressure",
		supersededNote = "Instant \u{2014} clumps pop on contact",
	},
	--[[
		QUICK SELL. The HUD's own key, top left, beside the backpack.

		NO supersedesTrack, and there is nothing to put there: this pass removes
		the WALK to the pad, and no rung of any ladder in the game shortens that
		walk. It does not raise the payout either -- the batch bonus and the
		rebirth multiplier land exactly as they do at the counter -- so it takes
		nothing away from Bucket Size or from a rebirth, and there is no shop row
		it should be drawing as finished.
	]]
	QuickSell = {
		key = "QuickSell",
		id = 1955496832,
		name = "Quick Sell",
		attribute = "OwnsQuickSell",
		blurb = "Empty the whole bag from anywhere \u{2014} no walk back to the pad.",
	},
	--[[
		2x CASH. A FOURTH KIND OF PASS: it does not unlock a machine, it does not
		unlock a verb, and it hands nothing over. It changes what an action the
		player already performs is WORTH.

		THE NAME IS "2x Cash" BECAUSE THAT IS WHAT THE STORE PAGE SAYS. Asked of
		Roblox rather than chosen here (GetProductInfo on 1954441205), for the
		reason stated at the top of this table: the button, the toast and the
		dialog Roblox opens over them have to agree, and Roblox's dialog is the
		one this file cannot edit.

		IT IS OFF SALE AS THIS IS WRITTEN -- IsForSale is false and there is no
		PriceInRobux, exactly the state GamePassService's header records the two
		car passes being in. No amount of code fixes that: Roblox will not sell an
		off-sale pass, so the shop draws SOON rather than a price and
		checkForSale() names it at every boot until somebody sets a price in the
		Creator Dashboard. Nothing else has to change on the day it goes live.

		WHAT IT MULTIPLIES, AND WHAT IT DELIBERATELY DOES NOT.

			SELLING AT THE COUNTER      doubled. SellServer.sellAll is the one
			                            place a find becomes cash, so it is the
			                            one place this can be applied without a
			                            second code path.

			EVERYTHING ELSE            untouched. Bounties, the idle shore, the
			                            free reward and the coin packs all pay what
			                            they say. The clean-off is off this list
			                            entirely -- it pays nothing to multiply.

		The temptation is to put it in SellServer.addCoins instead -- "the one
		grant path", which would catch all of those at once. THAT WOULD BE A BUG
		AND NOT A SMALL ONE: addCoins is also how coins are SPENT (every purchase
		passes a negative) and how SaveService RESTORES a returning player's
		balance. A multiplier there would double the balance on every join, for
		ever, and halve the effective price of everything in the game.

		The blurb says "at the counter" for that reason. It is the promise this
		pass can actually keep.
	]]
	DoubleCash = {
		key = "DoubleCash",
		id = 1954441205,
		name = "2x Cash",
		attribute = "OwnsDoubleCash",
		blurb = "Every sale at the counter pays double \u{2014} on top of your tide bonus.",
		payMultiplier = 2,
	},
	--[[
		THE SANDBOT. A flat pass like the two above -- it unlocks a verb,
		not a machine and not a bundle -- and the verb is "send a second worker
		out onto the sand".

		IT IS LIVE. Created on the Creator Dashboard on 2026-08-23 and pasted in
		here; R$ 99, IsForSale true, owned by the Speedy Clothes group (4620487).
		This row carried id = 0 until then, and everything in the game that draws
		it -- the shop row, the dock's prompt -- turned itself from SOON into a
		live price on that one line, with no other change anywhere.

		THE NAME IS "SandBot" WITH A CAPITAL B BECAUSE THAT IS WHAT THE STORE PAGE
		SAYS. Asked of Roblox rather than chosen here (GetProductInfo on
		1955383241, InfoType.GamePass), for the reason at the top of this table: the
		shop row, the toast and the purchase dialog Roblox opens over them have to
		agree, and Roblox's dialog is the one this file cannot edit. Everything the
		PLACE says is "Sandbot" or all-caps "SANDBOT HOME", so the only visible
		difference is that one letter; renaming the pass on the Dashboard and
		correcting this line is the way to settle it, not editing this line alone.

		⚠️ LOOK IT UP AS A GAME PASS, NOT AS AN ASSET. GetProductInfo defaults to
		InfoType.Asset, and this id answers as "SolidModel by John_Johnoveh" that
		way -- somebody else's unrelated model. That is how a perfectly good id
		gets declared wrong.

		THE CREATOR ACCOUNT ALREADY OWNS IT, WHICH IS NOT WHAT THE OTHER PASSES DO.
		MEASURED, because the obvious assumption is wrong in both directions and
		guessing wasted a testing pass: with DevUnlock off,
		UserOwnsGamePassAsync(139112508, 1955383241) answers TRUE, the join sweep
		writes OwnsSandbot = true, and the dock paints DEPLOY.

		That is the opposite of what DevGrant's header records for the two car
		passes, where the group's ownership left the seller unable to own them --
		which is exactly why this is written down rather than reasoned about. ASK
		ROBLOX before believing either story about any new pass.

		The consequence for testing is inverted too: the OWNED half needs no trick
		on this account, and it is the STOREFRONT that is now hard to see. A second
		account is the honest way; setting the OwnsSandbot attribute false from the
		client shows the un-owned painting locally without touching the server.

		NO supersedesTrack. The drone rakes through the player's OWN sweep at the
		player's own RollerWidth (see rakeRect in CTB_Server), so every rung of
		every ladder is worth exactly as much to a drone owner as to anybody else.
		There is no shop row this pass finishes.
	]]
	--[[
		VIP. THREE THINGS AT ONCE, which makes it the only pass in this table that
		hands over a bundle rather than a verb:

		  a tag over the head    seen by everyone, which is the whole point of it
		  the Gilded Rake skin   worn from the moment it lands (SkinConfig.vip)
		  the Gilded Unicorn     a Legendary exclusive, once per account

		The pet is the only one of the three that has to be given ONCE and
		remembered -- the other two are states, not grants, and are re-derived on
		every join from the pass itself. That split is why VipService looks the
		way it does: a saved flag guards the pet and nothing else.
	]]
	VIP = {
		key = "VIP",
		id = 1953715528,
		name = "VIP",
		attribute = "OwnsVIP",
		blurb = "A tag over your head, the Gilded Rake, and the Gilded Unicorn.",
	},
	Sandbot = {
		key = "Sandbot",
		id = 1955383241,
		name = "SandBot",
		attribute = "OwnsSandbot",
		blurb = "A little robot that rakes and collects for you while you work.",
	},
}

--[[
	IS THIS A PASS THAT ACTUALLY EXISTS?

	A row with id = 0 is a feature written before its pass was created -- a
	placeholder, not a product. Anything that would TALK TO ROBLOX about a pass
	has to check this first, because Roblox's answer for id 0 is an error:
	GetProductInfo throws, so the boot sweep prints LOOKUP FAILED at every start,
	and UserOwnsGamePassAsync throws three times with backoff on every join, per
	player, forever.

	ANYTHING THAT ONLY DRAWS A BUTTON DELIBERATELY DOES NOT CHECK IT. The shop
	and the HUD key both already have an honest answer for a pass with no
	published price -- "SOON", inert -- and that is exactly the right thing to
	show for a pass that has not been made yet. Hiding the row instead would mean
	the feature is invisible until the moment it goes on sale, which is the one
	time you most want to have already seen how it looks.

	Same shape ProductConfig.all() uses on its own unfinished rows, and for the
	same reason: the failure mode of forgetting to fill one in should be a button
	that cannot be pressed, never a button that takes Robux for nothing.
]]
function PassConfig.isLive(entry): boolean
	return type(entry) == "table" and type(entry.id) == "number" and entry.id > 0
end

-- Sorted by id rather than left in hash order: this feeds the boot-time
-- price sweep and its warnings, and a list that reorders itself between runs
-- is a diff nobody can read.
function PassConfig.all()
	local out = {}
	for _, entry in PassConfig.Passes do
		table.insert(out, entry)
	end
	table.sort(out, function(a, b)
		--[[
			A PASS THAT DOES NOT EXIST YET SORTS LAST, whatever its id.

			This list is DRAW ORDER for the shop as well as the order of the boot
			sweep, and an unmade pass carries id 0 -- which sorts ahead of every
			real one. That put an inert SOON row at the very top of the shop, above
			everything a player can actually buy, purely because it had not been
			created yet. Measured on screen before this line existed.

			Live passes keep their id order among themselves, so the list is still
			stable between runs and still a diff a person can read -- and the moment
			a real id is pasted in, the row takes its natural place with no other
			change anywhere.
		]]
		local aLive, bLive = PassConfig.isLive(a), PassConfig.isLive(b)
		if aLive ~= bLive then
			return aLive
		end
		return a.id < b.id
	end)
	return out
end

function PassConfig.get(key: string)
	return PassConfig.Passes[key]
end

--[[
	Every pass that multiplies a sale, in id order. One row today; a list because
	the caller is a LOOP rather than an `if`, and that is what makes a second one
	a line in this file instead of a change in SellServer.

	THE CALLER MUST ASK THE SERVER WHO OWNS THESE, NOT `owns` BELOW. This returns
	the rows and their multipliers and nothing about anybody -- ownership is
	GamePassService.ownsPassId's answer, off its own record, because the number
	this feeds into is a payout rather than a button.

	They MULTIPLY TOGETHER if there is ever more than one, which is the only
	honest way to combine them: two "double it" passes that came to 3x would make
	the second one a worse deal than the first.
]]
function PassConfig.paying()
	local out = {}
	for _, entry in PassConfig.Passes do
		if type(entry.payMultiplier) == "number" and entry.payMultiplier > 1 then
			table.insert(out, entry)
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

--------------------------------------------------------------------------
-- THE STARTER PACK'S SECOND FLAG
--------------------------------------------------------------------------
--[[
	TWO ATTRIBUTES, AND THE DIFFERENCE BETWEEN THEM IS THE WHOLE DESIGN.

		OwnsStarterPack      do they own the PASS. Written by GamePassService off
		                     Roblox's answer, re-resolved on every join, and true
		                     for the rest of the account's life once bought.

		StarterPackClaimed   have they been GIVEN the goods. Written once by
		                     StarterPackService and PERSISTED by SaveService, in
		                     exactly the way `tutorialDone` is.

	Paying out on the first would pay out on every rejoin, forever -- 20,000 coins
	a login. The second is what makes it a one-off, and it has to be a SAVED field
	rather than a session flag for the same reason the tutorial's is: a session
	flag is a fresh false on every server the player ever joins.

	Named here rather than typed into three files, for the reason SaveService
	gives about TutorialConfig.DoneAttribute: a string spelled twice is a string
	that gets corrected once.
]]
PassConfig.StarterPackKey = "StarterPack"
PassConfig.ClaimedAttribute = "StarterPackClaimed"

-- The exclusive pet the pack hands over. PetConfig owns what it IS; this is
-- only the id, so the grant and the shop copy cannot name two different pets.
PassConfig.StarterPackPetId = "Kingsmane"

-- VIP's three pieces, named here rather than spelled into VipService, for the
-- reason StarterPackKey above gives: a string in three files is a string that
-- gets corrected in one of them.
PassConfig.VipKey = "VIP"
PassConfig.VipClaimedAttribute = "VipPetClaimed"
PassConfig.VipPetId = "GildedUnicorn"
PassConfig.VipSkinKey = "vip"
-- What the billboard over their head says. Kept with the pass rather than in
-- the builder so the shop copy and the tag cannot drift apart.
PassConfig.VipTagText = "VIP"
PassConfig.StarterPackCoins = 20000

--[[
	Which pass, if any, finishes this upgrade track -- nil for nearly all of
	them. Two callers, and BOTH ARE ABOUT THE SHOP, not about the mechanic:

	  ProgressionServer.snapshot   draws the row finished
	  ProgressionServer.onBuy      refuses to sell it

	NOTHING WRITES THE PLAYER'S LEVEL, and that is the whole design. A pass that
	stamped Lv_Pressure to the ceiling would be indistinguishable, in the save
	file and afterwards, from a player who had bought sixty rungs -- and there
	is no way back from it if the track is ever rebalanced, split or removed.
	The pass changes what the jet DOES (WashServer.onAim) and what the row SAYS;
	the ladder underneath is left exactly where the player left it.
]]
function PassConfig.supersederOf(trackKey: string?)
	if type(trackKey) ~= "string" then
		return nil
	end
	for _, entry in PassConfig.Passes do
		if entry.supersedesTrack == trackKey then
			return entry
		end
	end
	return nil
end

-- FindFirstChild, never WaitForChild: this is called from render paths and
-- from button handlers, and neither may yield. A caller that needs the folder
-- to exist waits for it once itself.
local function infoFolder(): Folder?
	local folder = ReplicatedStorage:FindFirstChild(PassConfig.InfoFolder)
	return (folder and folder:IsA("Folder")) and folder or nil
end

PassConfig.info = infoFolder

--[[
	PRICE IS ALLOWED TO BE ABSENT, and every caller has to cope.

	An off-sale pass has no PriceInRobux at all, and a pass whose lookup failed
	has nothing published for it either. Returning nil for both is what lets a
	button draw without a figure rather than drawing "R$ 0" -- which reads as
	free and is the one wrong thing a price label can say.
]]
function PassConfig.price(id: number?): number?
	local folder = infoFolder()
	if not (folder and id) then
		return nil
	end
	local n = folder:GetAttribute("Price_" .. tostring(id))
	return (type(n) == "number" and n > 0) and n or nil
end

function PassConfig.onSale(id: number?): boolean
	local folder = infoFolder()
	if not (folder and id) then
		return false
	end
	return folder:GetAttribute("ForSale_" .. tostring(id)) == true and PassConfig.price(id) ~= nil
end

--[[
	THE CLIENT'S COPY, AND IT IS ONLY EVER GOOD ENOUGH TO PAINT A BUTTON.

	This reads a replicated attribute. A client cannot write one -- attribute
	writes do not replicate upward -- so it is not forgeable from a normal
	client, but an exploiter's own screen is not the thing being defended and
	the server must never take this as an answer.

	The rule the whole design rests on: a `false` here draws a BUY button and
	a `true` draws a USE button, and pressing the use button still has to get
	past GamePassService.ownsPassId on the server, which asks Roblox. Getting
	this wrong costs a wrong-looking button and nothing else.
]]
function PassConfig.owns(player: Player, key: string): boolean
	local entry = PassConfig.Passes[key]
	return entry ~= nil and player:GetAttribute(entry.attribute) == true
end

return PassConfig
