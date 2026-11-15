--[[
	ProductConfig  --  ReplicatedStorage.Modules.ProductConfig

	DEVELOPER PRODUCTS: what they are, what they grant, and what they cannot do
	until somebody creates them on the Creator Dashboard.

	ONE ROW IS LIVE: Quick Upgrade. The two coin packs below still carry id 0,
	which is not a product -- it is a blank waiting for a real one.
	`ProductConfig.all()` drops any row whose id is not a positive number, so an
	unfinished entry cannot reach a shop panel and cannot be granted, and the
	failure mode of forgetting to fill one in is a product that does not appear
	rather than a button that takes Robux for nothing.

	WHY THIS EXISTS BEFORE THE PRODUCTS DO
	--------------------------------------
	ShopConfig's own header sets the order and it is the right one:

		1. Write the receipt handler. It has to be IDEMPOTENT and it must
		   return PurchaseGranted only AFTER the grant is saved.
		2. Then list the product.

	That is step one, plus the table step two will fill in. ServerScriptService
	ProductServer is the handler; it reads this file and nothing else.

	TO TURN ONE ON
	--------------
		a. Create the developer product in the Creator Dashboard (Monetization ->
		   Developer Products) and copy its id.
		b. Paste the id into the row below. That is the whole change: the row
		   starts being granted by ProductServer and starts being drawn by
		   whatever lists ShopConfig.items().
		c. Check it in Studio with a test purchase before it goes near a player.

	A ROW'S SHAPE
	-------------
		key      stable internal name. Saved nowhere and safe to rename.
		id       the Roblox developer product id. 0 means "not created yet".
		name     as it reads on the product's own store page, so the button, the
		         toast and the dialog Roblox opens over them all agree.
		blurb    one line, the player's side of the screen.
		kind     which branch of ProductServer.grantOf runs. Adding a kind is a
		         change THERE as well as here -- a kind nothing implements is
		         refused at boot rather than at purchase time.
		amount   what `kind` means by "how much".
		scaled   coins only. See the note on it below.
		price    the Robux this row is INTENDED to cost. A fallback for the label,
		         never the truth -- see below.

	THE LIVE PRICE ALWAYS WINS, AND `price` IS ONLY WHAT TO DRAW UNTIL THERE IS
	ONE. The original rule here was that no price belongs in a config file at
	all, for the reason PassConfig gives: a number typed here is wrong the first
	time somebody runs a sale. That rule is intact -- nothing reads `price` when
	MarketplaceService has answered, and the moment a row has a real id the
	published figure replaces it everywhere.

	What the strict version cost was the shelf itself. A product that has not
	been created yet has no published price, so every row read "SOON" -- and a
	shop whose entire coin ladder says SOON is one nobody can design, price or
	judge, because the numbers that make it a ladder are the ones missing. This
	is the intended price, drawn so the shelf reads like a shelf, and overwritten
	by reality as soon as reality exists.

	IT DOES NOT MAKE A ROW BUYABLE. A row still needs a real id before its button
	does anything -- see the note on `id` above and the boot warning ProductServer
	prints. A price with no id is a label, not an offer.

	WHERE THEY ARE PUBLISHED, now that this is no longer a promise: ProductServer
	start() asks GetProductInfo for every live row and writes Price_<id> and
	ForSale_<id> into PassConfig.InfoFolder -- the SAME replicated folder the
	passes use. Read them back with PassConfig.price / PassConfig.onSale.

	THE FOLDER IS SHARED ON PURPOSE and the panel already assumed it would be:
	MenuHud's Robux shop has always read `PassConfig.price(item.id)` for a row
	whose kind is "product". It is keyed by ASSET ID and holds nothing
	pass-shaped, which is the same argument PassConfig's own header makes for why
	the wash pass moved into a folder named AtvPassInfo without a change. A second
	folder would be a second thing for a client to wait on and a second name to
	keep in step.
]]

local ProductConfig = {}

--[[
	SHOULD A COIN PACK SCALE WITH THE RUN?

	It is the one genuinely awkward question in this file and it is left as a
	per-row flag rather than decided globally, because the honest answer differs
	by product.

	The economy multiplies everything a player earns by SellMultiplier, which
	reaches x1,469 at forty rebirths. So a FLAT pack is worth a fortune on tide
	zero and is beneath notice by tide twenty -- the same defect RewardsServer's
	`scaled` note describes for the bounties, and the reason those are scaled.

		scaled = true    the pack is worth the same NUMBER OF BAGS at every
		                 tide. Fair for ever, and the figure on the button has
		                 to be drawn from the player's own multiplier rather
		                 than printed as a constant.
		scaled = false   the pack is a fixed pile of coins. Honest to advertise
		                 and easy to price, but it is a starter product only --
		                 it will be worthless within a couple of hours of play
		                 and should be described that way.

	Defaulting to true is deliberate: a product that quietly stops being worth
	anything is the version that generates refund requests.
]]
ProductConfig.Products = {
	--[[
		QUICK UPGRADE  --  the first live product in this place, and the only one
		in the file that does not hand over a quantity of something.

		WHAT IT IS. Every upgrade row in the Beach Shop has a coin price. This buys
		the SAME rung for Robux instead: one level on the track the player pressed
		it on, on either ladder. It is an alternative payment, not a shortcut past
		anything -- which is the whole design, and grantQuickUpgrade states it again
		at the point where it would be easiest to break.

		IT DOES NOT LIFT THE TIDE CEILING. A player stopped at this tide's cap
		cannot buy past it with Robux any more than with coins; the row goes dead
		for both, and ProgressionServer refuses the intent before a dialog ever
		opens. The ceiling is what paces the whole game -- see ProgressionConfig's
		note on levelCeiling -- and selling around it would be selling the pacing.

		IT IS NOT IN ShopConfig.Products, AND MUST NOT BE. Every other row in a
		Robux shop is complete on its own; this one is meaningless without a track
		attached, because the receipt cannot say which rung was meant. It is sold
		from the upgrade rows, where the player has already chosen one.

		`amount` IS LEVELS, not coins. One rung per purchase, which is what makes
		it a straight substitute for the button beside it. Raising it is one number
		-- grantQuickUpgrade applies them one at a time and stops the moment the
		next one would be refused, so it can never overshoot the ceiling.

		`scaled` is absent and would mean nothing here: a level is a level at every
		tide. The row it is bought from gets better value on its own, because the
		coin price beside it grows by CostGrowth every rung.
	]]
	{
		key = "QuickUpgrade",
		id = 3709560765,
		-- As it reads on the product's own store page (asked of GetProductInfo,
		-- not chosen here) so the button, the toast and Roblox's own dialog agree.
		name = "Quick Upgrade",
		blurb = "Buy the next level with Robux instead of coins.",
		kind = "upgrade",
		amount = 1,
	},
	--[[
		THE COIN LADDER -- five sizes, flat amounts, and the ladder is the point.

			                coins        R$     coins per R$
			Bucket         10,000        49          204
			Barrow         50,000        99          505
			Cartload      150,000       199          754
			Chest         400,000       499          802
			Hoard       1,000,000       999        1,001

		The R$ column is what the products were actually created at on the
		Dashboard, copied back here so the fallback and the live figure agree. If
		they are ever changed there, change them here too -- nothing breaks if they
		drift (the live price wins) but this table stops being the truth, and it is
		the table anybody reasons about the ladder from.

		FLAT, NOT SCALED, and that is a deliberate reversal -- `scaled = false` on
		every row. The long note above sets out the case for scaling and it is a
		real one; what it costs is that no pack can state what it gives you. A
		scaled pack's figure is different for every player looking at it, so the
		button cannot say a number, the store page cannot say a number, and the
		player finds out what they bought after they have bought it. "1,000,000
		COINS" is a product. "About 550 bags, depending on your multiplier" is a
		terms-and-conditions page.

		WHAT THAT COSTS, written down so nobody has to rediscover it: a flat pack
		is worth progressively less as the run goes on. At tide zero the Hoard is
		about 1,800 full bags; against a x1,469 multiplier it is under two. These
		are EARLY AND MID GAME products and they should be priced, described and
		judged as such. If they ever need to matter at forty rebirths the answer is
		a new top rung, not turning scaling back on.

		VALUE PER ROBUX CLIMBS WITH THE TIER -- 400 up to 1,001, two and a half
		times the rate at the top. A flat rate would make the Hoard a worse buy
		than forty Buckets, which is the arrangement that teaches players not to
		buy the big one.

		THE ROUND NUMBERS ARE THE PRODUCT. 10k / 50k / 150k / 400k / 1M against
		25 / 99 / 249 / 499 / 999 -- both columns are numbers a player can hold in
		their head and compare, which is the whole job of a ladder like this.
	]]
	--[[
		GOLDEN HOUR IN A BOTTLE  --  the answer to the paragraph above, and the
		only thing on this shelf that does not decay.

		The coin ladder's note works out that a flat pack is worth progressively
		less as the run goes on, and closes by ruling scaling back OUT: a scaled
		pack cannot print what it gives you, and a product that cannot print what it
		gives you is a terms page. Both halves of that are right, and together they
		leave the back half of the game with nothing on the shelf worth buying --
		the Hoard is 16% of one tide at rebirth 22 and 0.05% at rebirth 40.

		A MULTIPLIER IS THE SHAPE THAT ESCAPES BOTH. "Everything sells for double
		for fifteen minutes" is a fixed printable promise the button, the store page
		and the player all agree on -- AND it is worth proportionally the same at
		tide 1 and tide 40, because it multiplies whatever the run already makes.
		That is why this is the product for the back half and the packs are not.

		IT IS A PRODUCT, NOT A PASS, and that is the whole business case. 2x Cash
		is the pass -- bought once, owned forever. This is bought again every time
		somebody sits down for a session, and it STACKS on top of that pass rather
		than duplicating it, so owning the pass is a reason to buy one rather than a
		reason not to.

		`amount` IS SECONDS, which is the quantity this row hands over -- the same
		way the coin rows below carry coins and Quick Upgrade above carries levels.
		The multiplier is not here: it lives in BoostConfig with the reading and
		expiry rules, so there is one place to look at what a boost IS.

		`scaled` is absent and would mean nothing -- fifteen minutes is fifteen
		minutes at every tide, and the multiplier does the scaling by construction.

		⚠️ id = 0 UNTIL THE PRODUCT IS CREATED. ProductConfig.all() drops any row
		without a real id, so until then this is invisible everywhere -- no shelf
		row, no purchase dialog, and ProductServer never sees a receipt for it. Make
		it on the Creator Dashboard (Monetization -> Developer Products), name it
		exactly as below so the button and Roblox's own dialog agree, and paste the
		id here. Nothing else needs touching.
	]]
	{
		key = "BoostGolden",
		id = 0,
		name = "Golden Hour in a Bottle",
		blurb = "Every sale pays double for 15 minutes. Stacks with 2x Cash.",
		kind = "boost",
		amount = 900,
		price = 99,
	},
	{
		key = "CoinsBucket",
		id = 3709568373,
		name = "Bucket of Coins",
		blurb = "10,000 coins. A pocketful to get the next upgrade moving.",
		kind = "coins",
		amount = 10000,
		scaled = false,
		price = 49,
	},
	{
		key = "CoinsBarrow",
		id = 3709568420,
		name = "Barrow of Coins",
		blurb = "50,000 coins. A solid top-up -- a few rungs on any track.",
		kind = "coins",
		amount = 50000,
		scaled = false,
		price = 99,
	},
	{
		key = "CoinsCart",
		id = 3709568539,
		name = "Cartload of Coins",
		blurb = "150,000 coins. Enough to rebuild the whole shop in one go.",
		kind = "coins",
		amount = 150000,
		scaled = false,
		price = 199,
	},
	{
		key = "CoinsChest",
		id = 3709568642,
		name = "Treasure Chest",
		blurb = "400,000 coins. A serious haul -- buy the machine you have been saving for.",
		kind = "coins",
		amount = 400000,
		scaled = false,
		price = 499,
	},
	{
		key = "CoinsHoard",
		id = 3709568672,
		name = "Shipwreck Hoard",
		blurb = "1,000,000 coins. The lot, at the best rate on the shelf.",
		kind = "coins",
		amount = 1000000,
		scaled = false,
		price = 999,
	},
}

--[[
	WHICH PRODUCTS A SHOP SHELF MAY LIST BY ITSELF.

	Not every product is complete on its own. QuickUpgrade above is the standing
	example and its note says why: a receipt for it is meaningless without a
	track attached, so it is sold from the upgrade row the player already chose
	and must never appear as a shop row. Anything sold that way is a KIND that is
	not on this list.

	A KIND, rather than a flag on each row, so the rule is stated once. The day
	somebody adds a sixth coin pack they get the shelf for free; the day somebody
	adds another context-dependent product they have to come here and think about
	it, which is the right way round.
]]
--[[
	THE ART FOR EACH RUNG, keyed the same way ShopConfig.Art is.

	Drawn by make_coin_icons.py in the repo root -- run it, upload, paste the id
	here. They were Frames and UICorners first, which is what the rest of the
	panels are drawn in; it is the wrong tool for this one job, because a rounded
	rectangle cannot have a stave seam, a spoke, a rivet or a coin edge, and
	every rung came out as two or three blocks.

	A missing entry is not a failure: MenuHud draws the block version underneath
	and lays the image over it, so an id that is wrong, unmoderated or owned by
	the wrong creator degrades to what was there before rather than to an empty
	tile. Same arrangement, and the same reason, as the shop banners.

	⚠️ These must belong to the group that owns the place, or players will only
	ever see the fallback. See ShopConfig.Art's note.
]]
ProductConfig.Art = {
	CoinsBucket = "rbxassetid://80978617125307",
	CoinsBarrow = "rbxassetid://82699823520428",
	CoinsCart   = "rbxassetid://122137800699918",
	CoinsChest  = "rbxassetid://86191346908300",
	CoinsHoard  = "rbxassetid://121909009328911",
}

-- `boost` is a shelf kind and `upgrade` is not: a boost is complete on its own
-- (fifteen minutes at double, whoever is looking at it), where Quick Upgrade is
-- meaningless without a track attached. See the note over the Quick Upgrade row.
ProductConfig.ShelfKinds = { coins = true, boost = true }

--[[
	The rows that are actually usable: a real id, a kind, and a sane amount.

	EVERY CALLER GOES THROUGH THIS rather than reading Products directly, which
	is what makes an unfinished row harmless. Sorted by id so the boot-time
	price sweep and its warnings produce a diff a person can read, the same way
	PassConfig.all() does.
]]
function ProductConfig.all()
	local out = {}
	for _, p in ProductConfig.Products do
		if type(p.id) == "number" and p.id > 0
			and type(p.kind) == "string"
			and type(p.amount) == "number" and p.amount > 0
		then
			table.insert(out, p)
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

-- nil for an id that is not a live product. Fed straight from a receipt, so an
-- unknown id has to be an answer rather than a throw -- see ProductServer for
-- what it does with the nil, which is NOT to consume the receipt.
function ProductConfig.byId(id: any)
	if type(id) ~= "number" then
		return nil
	end
	for _, p in ProductConfig.all() do
		if p.id == id then
			return p
		end
	end
	return nil
end

-- The live products a shop panel may draw on its own. ShopConfig.items() is the
-- only caller; see ShelfKinds above for what it leaves out and why.
function ProductConfig.shelf()
	local out = {}
	for _, p in ProductConfig.all() do
		if ProductConfig.ShelfKinds[p.kind] then
			table.insert(out, p)
		end
	end
	return out
end

--[[
	THE COIN LADDER AS DESIGNED, ids or no ids, IN THE ORDER IT WAS WRITTEN.

	The difference between this and shelf() above is the whole reason both exist:

	  shelf()   what may be SOLD. Filtered through all(), so a row with no id is
	            not in it -- you cannot take money for a product Roblox has never
	            heard of.
	  ladder()  what may be SHOWN. The panel draws all five rungs and paints the
	            unpublished ones SOON, which is what the rest of this shop already
	            does for the Sandbot.

	And it is NOT sorted by id. all() sorts that way so the boot-time price sweep
	 logs a readable diff; a ladder sorted by asset id would put the packs in
	whatever order they happened to be created on the Dashboard, which for a
	size ladder is no order at all. Declaration order IS the design.
]]
function ProductConfig.ladder()
	local out = {}
	for _, p in ProductConfig.Products do
		if ProductConfig.ShelfKinds[p.kind] then
			-- A COPY, with the artwork attached. The panel that draws these needs
			-- the icon id, and handing it the row is cheaper than making a UI file
			-- require this one -- MenuHud is a client module and every top-level
			-- local it grows is a local it may not have room for.
			--
			-- Copied rather than mutated in place: byId() and get() hand out the
			-- real rows to the receipt path, and a display field bolted onto those
			-- would be a field the grant code could start reading by accident.
			local row = table.clone(p)
			row.art = ProductConfig.Art[p.key]
			table.insert(out, row)
		end
	end
	return out
end

function ProductConfig.get(key: string)
	for _, p in ProductConfig.Products do
		if p.key == key then
			return p
		end
	end
	return nil
end

--[[
	The one product other code asks for BY NAME rather than by iterating.

	Three callers want it -- the shop row that draws the button, the remote
	handler that records the intent, and the grant that honours it -- and a string
	spelled in three files is a string that gets corrected in one. Same argument
	PassConfig.StarterPackKey and TutorialConfig.DoneAttribute are named for.
]]
ProductConfig.QuickUpgradeKey = "QuickUpgrade"

--[[
	The row, but only once it is a REAL product -- nil for an id still waiting to
	be filled in.

	Anything about to draw a buy button or open a dialog wants this rather than
	`get`, which answers for a blank row too. That difference is what keeps an
	unfinished product visible to whoever is filling it in and invisible to every
	player, which is the guarantee the header opens with.
]]
function ProductConfig.live(key: string)
	local p = ProductConfig.get(key)
	if not (p and type(p.id) == "number" and p.id > 0) then
		return nil
	end
	return p
end

return ProductConfig
