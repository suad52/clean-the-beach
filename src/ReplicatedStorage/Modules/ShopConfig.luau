--[[
	ShopConfig  --  ReplicatedStorage.Modules.ShopConfig

	WHAT THE ROBUX SHOP SELLS, in the order the panel draws it.

	IT TYPES NO PASS ID. Every entry is assembled out of a config that already
	owned the number -- PassConfig for the passes that unlock a VERB, AtvConfig
	for the two that unlock a MACHINE -- because the one failure a file like this
	can introduce is a third copy of an id that is already written down twice. An
	id typed twice is an id that gets corrected once.

	WHY IT EXISTS, given that it mostly concatenates two tables. Until it did,
	nothing in the game could answer "what can a player buy with Robux". Each
	place that sold something knew only about its own: the wash HUD knew the wash
	pass, the car showroom knew the two machines, and the rail knew none of them.
	A shop BUTTON needs the whole list, and the whole list is config rather than
	layout -- so it lives here and MenuHud draws it.

	WHAT IS DELIBERATELY NOT IN HERE
	--------------------------------
	PRICES. GamePassService reads them off Roblox at boot and publishes them into
	a replicated folder; PassConfig.price / PassConfig.onSale read them back. A
	price written into a config file is a price that is wrong the first time
	somebody runs a sale, and "R$ 0" is the one thing a price label must never
	say.

	OWNERSHIP, beyond the name of the attribute to watch. The attribute is the
	client's copy and is only ever good enough to decide what a button says; the
	server asks Roblox. See PassConfig's note on `owns`.

	ART. Glyphs and tints are MenuHud's, next to the rest of the drawing, the
	same way TRACK_EMOJI sits with the stock list rather than with the tracks.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local AtvConfig = require(ReplicatedStorage:WaitForChild("AtvConfig"))
local PassConfig = require(Modules:WaitForChild("PassConfig"))
local ProductConfig = require(Modules:WaitForChild("ProductConfig"))

local ShopConfig = {}

----------------------------------------------------------------
-- DEVELOPER PRODUCTS
----------------------------------------------------------------
--[[
	THIS TABLE IS STILL EMPTY, AND IT IS NO LONGER EMPTY FOR THE ORIGINAL REASON.

	It used to say there was no ProcessReceipt handler anywhere in the game and no
	product id in any file. Both are now false: ServerScriptService.ProductServer
	is the handler, and ProductConfig carries one live product -- Quick Upgrade.

	IT IS DELIBERATELY NOT LISTED HERE. Every row this panel draws has to be
	complete on its own: a name, a price, and a thing you get. Quick Upgrade is not
	-- it buys the next level of ONE upgrade track, and a receipt names a product
	and a player but never a track. Sold from this list it would be a button that
	takes Robux and then has to guess what the player meant. So it is sold from the
	upgrade rows in the Beach Shop, where the player has already pointed at a rung,
	and ProgressionServer records which one before the dialog opens.

	THE ORDER FOR ANYTHING ADDED HERE IS UNCHANGED, and it is what ProductServer
	was written against:

	  1. Write the grant. It has to be IDEMPOTENT and it must return
	     PurchaseGranted only AFTER the grant is saved -- Roblox re-delivers a
	     receipt it was not told about, across servers and across sessions, so a
	     handler that grants first and saves later hands out the reward twice and
	     one that returns NotProcessedYet forever charges nobody.
	  2. Then list the product here.

	Doing it the other way round draws a live buy button in front of players and
	takes their Robux for nothing, which is the one bug in a shop that cannot be
	apologised away. ShopConfig.items() below is what the panel iterates, so an
	entry added here is on screen the moment it is saved.

	A GAME PASS IS SELF-ENFORCING: Roblox remembers who owns it for good, and
	GamePassService just asks. A DEVELOPER PRODUCT IS NOT. It is a one-off charge,
	Roblox remembers nothing about it afterwards, and the only place a purchase can
	be turned into anything at all is MarketplaceService.ProcessReceipt.

	The shape an entry wants:

		{ key = "", id = 0, name = "", blurb = "" }

	PRICES STILL DO NOT BELONG IN IT. ProductServer publishes them into the same
	folder GamePassService uses, and the row painter below already reads a product
	price back through PassConfig.price.
]]
--[[
	THE LIST IS ProductConfig'S, NOT A SECOND COPY OF IT.

	This used to be an empty table waiting to be filled in by hand, which would
	have made it the third place a product id is written down -- and the note at
	the top of this file is about exactly that mistake for pass ids. A product is
	already fully described where it is granted from; a shop only decides whether
	to put it on a shelf.

	`shelf()` rather than `all()`, and the difference matters: not every live
	product is complete on its own. Quick Upgrade is meaningless without a track
	attached and is sold from the upgrade row the player already chose, so it is
	deliberately not a shelf kind. See ProductConfig.ShelfKinds.
]]
function ShopConfig.products()
	return ProductConfig.shelf()
end

function ShopConfig.hasProducts(): boolean
	return #ProductConfig.shelf() > 0
end

----------------------------------------------------------------
-- THE FEATURED OFFER
----------------------------------------------------------------
--[[
	ONE pass is drawn as a BANNER across the top of the shop instead of as a row
	in the list, and `items()` below leaves it out so it is not sold twice on one
	screen.

	It is named here rather than in MenuHud because which offer is featured is a
	merchandising decision, not a layout one -- the panel should be able to draw
	whatever the shop says is featured without knowing that today that means the
	starter pack.

	The artwork is the banner the offer was designed around: it already says the
	price, the coins and the pet, so the panel draws the image and a buy button
	and nothing else. Set `image` to nil and the banner simply does not appear --
	the rows still work, which is what makes an unmoderated or deleted asset a
	cosmetic problem rather than a broken shop.
]]
ShopConfig.Feature = {
	key = PassConfig.StarterPackKey,
	image = "rbxassetid://95429803022900",
	-- 1024 x 253 as uploaded; the panel scales to its own width off this.
	aspect = 1024 / 253,
}

-- The featured pass as a full shop item, or nil if it is missing or has no
-- artwork. Same shape as an `items()` row, so the panel's paint code is shared.
function ShopConfig.feature()
	local f = ShopConfig.Feature
	if not (f and f.key and f.image) then
		return nil
	end
	local entry = PassConfig.get(f.key)
	if not entry then
		return nil
	end
	return {
		kind = "pass",
		key = entry.key,
		id = entry.id,
		name = entry.name,
		blurb = entry.blurb,
		attribute = entry.attribute,
		image = f.image,
		aspect = f.aspect,
	}
end

----------------------------------------------------------------
-- ROW ARTWORK
----------------------------------------------------------------
--[[
	A BANNER PER SHOP ROW, drawn instead of the icon-and-blurb layout.

	Each one already carries its own icon, name, one-line pitch, kind badge and
	price, so where there is artwork the panel draws the picture and nothing else.
	A key with no entry here keeps the classic row -- which is not a fallback
	nobody uses.

	⚠️ THE PRICE IS PAINTED INTO THE IMAGE. Every one of these was checked against
	its live PriceInRobux before it went in (99 / 99 / 99 / 249 / 299 / 499).
	Change a price on the Creator Dashboard and the artwork is lying until it is
	redrawn -- the classic row read the price live and could not have this
	problem, so it is the cost of the look and it is worth writing down.

	THE SANDBOT IS THE CASE THAT WARNING DESCRIBES, AND IT HAS ALREADY HAPPENED
	ONCE. Its first banner was generated while the pass was unpublished, so it
	carried SOON where the number goes, and it was drawn under an earlier working
	name, so it did not even say SandBot. The pass went live at R$ 99 on
	2026-08-23 and the artwork was wrong on both counts from that moment; the row
	spent a week on the classic layout rather than on a handsome lying banner.
	Redrawn and back on the list 2026-08-24, at the live name and the live price,
	with an icon built from SandbotBuilder's own palette instead of the stock
	household-robot shape the first one used.

	The Coins banner carries no price at all, and should not: it is the front of a
	five-rung shelf and its badge says 5 SIZES. The prices live on the rungs, are
	read live off the Dashboard by the panel behind it, and nothing about them is
	painted into anything.

	⚠️ THESE ASSETS MUST BELONG TO THE GROUP THAT OWNS THE PLACE (4620487).
	An image uploaded to a personal account does not load in a group-owned
	experience -- for everyone except the uploader it simply never appears, with
	no error anywhere. The ids below were uploaded from Studio, which files them
	under the signed-in USER, so they must be re-uploaded under the group and the
	ids replaced here. Until then every row falls back to the classic layout for
	players, which is why that fallback is drawn underneath rather than instead.
	ShopConfig.Feature.image above has exactly the same problem and the same fix.
]]
--
-- EVERY ROW GETS ONE. The four sold offers were drawn by hand; the two that are
-- not on sale yet were generated to match by make_shop_banners.py in the repo
-- root, which is also how the next pass should get its banner -- add a row to
-- ROWS there, run it, upload, paste the id in. A pass with no entry here still
-- works, it just falls back to the plain icon-and-blurb row.
--
-- The key the coin shelf's single row is drawn under. Not a product key: the
-- row is a door, and the products are behind it. See items().
ShopConfig.CoinShelfKey = "Coins"

--[[
	WHICH ROW GETS THE GOLD TREATMENT instead of a banner -- one key, or nil for
	none. MenuHud reads it into a per-item `style` and draws that row itself: gold
	plate, sunburst, sparkles, the live pet on a turntable and a gold price pill.

	IT IS A KEY HERE RATHER THAN A FLAG IN MenuHud because this file already owns
	WHICH offer looks like what -- Art above, Feature above that. A second file
	deciding it is how a row ends up with a banner and a gold plate at once.

	The row named here must NOT also have an Art entry; see the note in Art.
]]
ShopConfig.GoldKey = "VIP"

ShopConfig.Art = {
	--[[
		VIP IS DELIBERATELY NOT IN HERE ANY MORE.

		Its banner was "rbxassetid://81399054052408" -- the only one whose icon was a
		RENDER rather than flat vector art, the pet keyed out of its studio backdrop
		(icon_vip in make_shop_banners.py). RETIRED, not replaced.

		WHY: the group-ownership warning above was CONFIRMED BY MEASUREMENT on
		2026-08-24. GetProductInfo reports every id in this table -- and the feature
		banner's -- as owned by USER 254153724, against a place owned by GROUP
		4620487. So this image has never drawn for a player, only for the uploader in
		Studio, and a re-drawn golden one uploaded the same way would be invisible in
		exactly the same way.

		The row is drawn in code instead, in gold, with the real GildedUnicorn on a
		turntable -- see MenuHud's goldenRow. Nothing about that can be defeated by
		an upload account.

		TO PUT ARTWORK BACK: add the id here AND clear GoldKey below. The two are
		alternatives, not layers: a banner covers the row completely, so leaving both
		on means drawing a card nobody can see.
	]]
	-- Redrawn 2026-08-24: says SandBot, says 99, and the icon is the drone from
	-- SandbotBuilder rather than a generic robot. The asset it replaces
	-- (130356478982403) is stale on both counts -- do not put it back.
	Sandbot     = "rbxassetid://120560197729649",
	DoubleCash  = "rbxassetid://124390423299929",
	Coins       = "rbxassetid://131100494484958",
	QuickSell   = "rbxassetid://104371107173682",
	InstantWash = "rbxassetid://102875956963015",
	Sandhog     = "rbxassetid://71294674959644",
	Tidebreaker = "rbxassetid://133687977029306",
}

-- 2000 x 495 as uploaded. One number for the set: the panel derives each row's
-- height from its own width and this, so a re-crop cannot leave a row stretched
-- -- but a re-crop to a DIFFERENT shape has to change this line.
ShopConfig.ArtAspect = 2000 / 495

----------------------------------------------------------------
-- THE STOCK
----------------------------------------------------------------
--[[
	Everything buyable for Robux, as one list, in draw order:

		kind        "pass" or "product". The panel prompts a different
		            MarketplaceService call for each, and only a pass can ever be
		            OWNED -- a product is a one-off and is buyable forever.
		id          the Roblox asset. Public the moment a button is drawn.
		attribute   what GamePassService writes on the Player when it has an
		            answer -- the only thing a client may read to decide what to
		            draw, and what the panel watches to repaint itself. nil for a
		            product, which is never owned.
		tint        a colour the entry brought with it (the machines carry their
		            own livery); nil means the panel picks one.

	VERBS BEFORE MACHINES. The flat passes go first because they are the cheap
	broadly-useful ones and a shop opens on what most players might buy, not on
	its two most expensive lines.
]]
function ShopConfig.items()
	local out = {}

	local featured = ShopConfig.Feature and ShopConfig.Feature.key
	for _, entry in PassConfig.all() do
		-- The featured offer is the banner across the top; listing it here as well
		-- would put the same pass on the same screen twice, at two different sizes.
		-- Skipped only when the banner will ACTUALLY draw -- feature() returns nil
		-- if the artwork is missing, and in that case the pass falls back to being
		-- an ordinary row rather than disappearing from the shop altogether.
		if not (entry.key == featured and ShopConfig.feature() ~= nil) then
			table.insert(out, {
				kind = "pass",
				key = entry.key,
				id = entry.id,
				name = entry.name,
				blurb = entry.blurb,
				attribute = entry.attribute,
				image = ShopConfig.Art[entry.key],
				aspect = ShopConfig.ArtAspect,
				-- "gold" or nil. Only the passes can carry it: the machines bring their
				-- own livery down from AtvConfig and the coin shelf is a door.
				style = (entry.key == ShopConfig.GoldKey) and "gold" or nil,
			})
		end
	end

	for _, entry in AtvConfig.allPasses() do
		local tier = entry.tier
		table.insert(out, {
			kind = "pass",
			key = tier.key,
			id = entry.id,
			name = tier.name,
			blurb = tier.blurb,
			attribute = AtvConfig.passAttribute(tier),
			-- The machine's own body colour, so its tile in the shop is the colour
			-- of the thing that turns up on the pad. Still set even where there is
			-- artwork: it is what the row underneath is painted with.
			tint = tier.body,
			image = ShopConfig.Art[tier.key],
			aspect = ShopConfig.ArtAspect,
		})
	end

	--[[
		THE COIN LADDER IS ONE ROW, NOT FIVE.

		Five packs listed flat is the arrangement that sells the SMALL one: the
		player meets the cheapest first, buys it, and never reads far enough to
		find out the big one is three times the rate. It also spends five banners
		of a shop that has four other things in it.

		So the shelf gets a single front, and the sizes are the thing you find
		behind it -- where they are next to each other and the ladder can be read
		as a ladder. `kind` is its own so the panel knows this row OPENS something
		rather than prompting a purchase; it has no id and can never be owned.

		The rungs come from ladder() rather than shelf(), so all five show from the
		day they are written and the unpublished ones paint SOON -- the way the
		Sandbot's row behaved on the shelf until its pass went live.
	]]
	local ladder = ProductConfig.ladder()
	if #ladder > 0 then
		table.insert(out, {
			kind = "coinshelf",
			key = ShopConfig.CoinShelfKey,
			name = "Coins",
			blurb = "Five sizes, from a bucket to a shipwreck hoard.",
			tiers = ladder,
			image = ShopConfig.Art[ShopConfig.CoinShelfKey],
			aspect = ShopConfig.ArtAspect,
		})
	end

	-- Anything else on the shelf still lists itself. Nothing does today -- coins
	-- are the only ShelfKind -- but a future shelf product should not have to
	-- discover that this loop quietly stopped drawing it.
	for _, p in ShopConfig.products() do
		if p.kind ~= "coins" then
			table.insert(out, {
				kind = "product",
				key = p.key,
				id = p.id,
				name = p.name,
				blurb = p.blurb,
				tint = p.tint,
				image = ShopConfig.Art[p.key],
				aspect = ShopConfig.ArtAspect,
			})
		end
	end

	return out
end

return ShopConfig
