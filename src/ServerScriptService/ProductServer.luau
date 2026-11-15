--[[
	ProductServer  --  ServerScriptService.ProductServer

	THE ONE PLACE A DEVELOPER PRODUCT TURNS INTO ANYTHING.
	MarketplaceService.ProcessReceipt is assigned here and nowhere else -- it is
	a single-assignment callback, so a second file taking it silently replaces
	this one and every purchase in the game stops paying out.

	ONE PRODUCT IS ON SALE: Quick Upgrade. The two coin packs in ProductConfig
	still carry id 0 and ProductConfig.all() drops them, so this file can grant
	exactly one thing. ShopConfig's header set the order -- handler first, product
	second -- and it was followed: the handler below was written and tested before
	any button existed that could take a player's Robux.

	THE UPGRADE GRANT DOES NOT LIVE IN THIS FILE, and that is deliberate. A Quick
	Upgrade receipt names a product and a player but not WHICH rung was bought, so
	honouring one means re-deriving levels, ceilings and refusals -- all of which
	are ProgressionServer's, none of which belong in a receipt handler. grantOf
	calls into it and takes its boolean as the receipt decision.

	WHY A RECEIPT IS HARDER THAN A GAME PASS
	----------------------------------------
	A pass is self-enforcing: Roblox remembers who owns it and GamePassService
	just asks. A product is a one-off charge that Roblox remembers NOTHING about
	afterwards except an undelivered receipt, which it re-sends -- across
	servers, across sessions, for days -- until a handler returns
	PurchaseGranted. Two failure modes fall out of that and they are opposites:

		GRANT TOO EAGERLY   return PurchaseGranted before the grant is saved and
		                    a crash in that window loses it for good. Roblox has
		                    been told it was delivered and will never re-send.
		GRANT TOO OFTEN     return PurchaseGranted for a receipt already handled
		                    -- or fail to notice one -- and the same purchase
		                    pays out twice.

	BOTH ARE SOLVED BY ONE DECISION: the receipt log lives in the SAME PROFILE
	as the coins. SaveService writes one record, so the grant and the note that
	it happened are committed together or not at all. There is no window in
	which the profile says a player was paid but not credited, or credited but
	not paid -- which is exactly what a separate receipts DataStore would have
	created, and why this does not have one.

	THE THREE STATES A RECEIPT CAN BE IN
	------------------------------------
		durable   in the profile that was loaded on join, so it is on disk.
		          Answer PurchaseGranted immediately; the work is long done.
		session   granted this session, not yet confirmed written. Try to commit;
		          answer only on the result. NEVER re-grant -- the coins are
		          already on the player.
		unknown   not seen. Grant, record, commit, answer on the result.

	The unhappy path is safe in both directions: a commit that fails returns
	NotProcessedYet with the grant left standing in memory, so an ordinary
	periodic save can still land it; and if the server dies first, neither the
	coins nor the record were ever written, so the receipt Roblox re-sends to
	the next session finds a player who has neither and grants once, correctly.

	COMMITTING WITHOUT A CIRCULAR REQUIRE
	-------------------------------------
	SaveService requires this module (it is another persistence seam, the same
	shape as RewardsServer's exportFor/restore). So this module must not require
	SaveService back. It exposes `CommitProfile` instead and SaveService fills it
	in at boot -- the same injected-hook shape SaveService already uses for
	OnCoinsChanged and OnPetsChanged, and the reason the dependency runs one way.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local ProductConfig = require(Modules:WaitForChild("ProductConfig"))
-- For InfoFolder only -- the NAME of the replicated folder prices are published
-- into. Named there rather than spelled a second time here, which is the same
-- argument PassConfig's own header makes about the pass ids.
local PassConfig = require(Modules:WaitForChild("PassConfig"))
local Net = require(Modules:WaitForChild("Net"))

local SellServer = require(script.Parent:WaitForChild("SellServer"))
--[[
	The "upgrade" kind's grant. See the header: a rung is not this module's to
	understand, so it asks the module that owns levels and takes its answer.

	NO CYCLE, and it is worth stating because this file is itself required by
	SaveService. ProgressionServer reaches for ProgressionConfig, AtvConfig,
	PassConfig, ProductConfig, GameConfig, InventoryController, Net, SellServer and
	GamePassService -- and not one of them, nor it, requires this module back.
]]
local ProgressionServer = require(script.Parent:WaitForChild("ProgressionServer"))
--[[
	The "boost" kind's grant, and the same no-cycle argument holds one line at a
	time: BoostService reaches for BoostConfig and Net and nothing else. It does
	not pay coins, so it never touches SellServer, which is the require that would
	have made this interesting.
]]
local BoostService = require(script.Parent:WaitForChild("BoostService"))

local ProductServer = {}

--[[
	SET BY SaveService AT BOOT. Returns true once the player's profile is on
	disk. nil until then, and nil forever if SaveService is not running -- in
	which case nothing here can be committed and every receipt is answered
	NotProcessedYet, which is the correct behaviour for a server that cannot
	remember anything: Roblox keeps the receipt and tries again somewhere else.
]]
ProductServer.CommitProfile = nil

--------------------------------------------------------------------------
-- THE RECEIPT LOG
--------------------------------------------------------------------------

--[[
	HOW MANY RECEIPTS A PROFILE REMEMBERS.

	Roblox stops re-sending a receipt long before this, so the log only has to
	outlive the retry window rather than the account. It is bounded because a
	profile is a DataStore value with a hard size limit and an unbounded list of
	strings inside it is a save that eventually starts failing -- silently, and
	for a reason nobody would look for in a shop.
]]
local LOG_MAX = 200

-- [Player] = { durable = {id = true}, session = {id = true}, order = {id, ...} }
local logs = {}

local function logOf(player: Player)
	local l = logs[player]
	if not l then
		l = { durable = {}, session = {}, order = {} }
		logs[player] = l
	end
	return l
end

-- Newest last, oldest dropped. The set and the order list are kept in step so
-- a pruned id cannot linger as a claim nothing can be matched against.
local function remember(l, id: string)
	if l.durable[id] or l.session[id] then
		return
	end
	l.session[id] = true
	table.insert(l.order, id)
	while #l.order > LOG_MAX do
		local old = table.remove(l.order, 1)
		l.durable[old] = nil
		l.session[old] = nil
	end
end

--------------------------------------------------------------------------
-- WHAT A PRODUCT ACTUALLY DOES
--------------------------------------------------------------------------

--[[
	ONE BRANCH PER `kind`. Returns true only if the grant actually happened --
	a false here means the receipt is NOT consumed and Roblox will re-send it,
	which is the right answer for a product this build cannot honour.

	ADDING A KIND IS A CHANGE HERE AS WELL AS IN ProductConfig. A row naming a
	kind this function does not implement is refused at boot (see start()) so it
	is found by whoever added it rather than by the first player to buy it.
]]
local function grantOf(player: Player, product): boolean
	--[[
		ONE LEVEL ON THE RUNG THE PLAYER WAS LOOKING AT.

		Everything hard about this is over there: which rung was meant (the receipt
		cannot say, so the intent is recorded before the Robux moves), whether it is
		still buyable, and what to do when a receipt outlives the session that
		recorded it. grantQuickUpgrade's own header works through all three.

		WHAT MATTERS HERE IS THE BOOLEAN. It comes back true only after a level has
		actually been written, so passing it straight out is exactly right: a false
		leaves the receipt with Roblox to re-send rather than consuming it for a
		grant that did not happen.
	]]
	if product.kind == "upgrade" then
		return ProgressionServer.grantQuickUpgrade(player, product) == true
	end

	if product.kind == "coins" then
		local amount = product.amount
		-- Scaled by the run unless the row says otherwise. See the long note on
		-- `scaled` in ProductConfig for why the default is to scale.
		if product.scaled ~= false then
			local mult = player:GetAttribute("SellMultiplier")
			if type(mult) ~= "number" or mult ~= mult or mult <= 0 then
				mult = 1
			end
			amount = amount * mult
		end
		amount = math.floor(amount + 0.5)
		if amount < 1 then
			return false
		end
		-- THROUGH THE ONE GRANT PATH, never the Coins attribute: SellServer is
		-- what fires OnCoinsChanged, and that is what counts lifetime earnings,
		-- repaints open panels and marks the profile dirty.
		-- IAP rather than Gameplay: these coins were bought with Robux, and mixing
		-- them into the earned pile would make every payout curve in the report
		-- look healthier than it is.
		SellServer.addCoins(player, amount, "coinpack")
		pcall(function()
			Net.get("Notify"):FireClient(player, {
				text = string.format("%s  +%d coins", product.name, amount),
				kind = "pickup",
			})
		end)
		return true
	end

	--[[
		TIME AT A MULTIPLIER, and `amount` is SECONDS -- see the row in
		ProductConfig for why this product is a multiplier rather than a quantity.

		THE HARD PART IS NOT HERE, deliberately, the same way the upgrade branch
		leaves its rung to ProgressionServer. Whether this extends a running boost or
		starts a fresh one, what happens if a stronger one is already live, and how a
		deadline survives a rejoin are all BoostService.grant's -- and its header
		works through each.

		WHAT MATTERS HERE IS THE BOOLEAN. grant returns the new deadline or nil, and
		a nil has to leave the receipt with Roblox to re-send rather than consuming
		it for time that was never handed over.
	]]
	if product.kind == "boost" then
		local deadline = BoostService.grant(player, product.amount, product.multiplier)
		if not deadline then
			return false
		end
		pcall(function()
			Net.get("Notify"):FireClient(player, {
				text = string.format("%s  \u{2014}  double pay for %d minutes",
					product.name, math.max(1, (product.amount or 0) // 60)),
				kind = "good",
			})
		end)
		return true
	end

	warn("[ProductServer] no grant implemented for kind: " .. tostring(product.kind))
	return false
end

ProductServer.KINDS = { coins = true, upgrade = true, boost = true }

--------------------------------------------------------------------------
-- THE HANDLER
--------------------------------------------------------------------------

local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
local NOT_YET = Enum.ProductPurchaseDecision.NotProcessedYet

local function commit(player: Player): boolean
	local fn = ProductServer.CommitProfile
	if type(fn) ~= "function" then
		return false
	end
	local ok, wrote = pcall(fn, player)
	return ok and wrote == true
end

local function process(info): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(info.PlayerId)
	if not player then
		-- Gone before it landed. Roblox re-sends on their next join, where the
		-- profile is loaded and the whole thing runs properly.
		return NOT_YET
	end

	local id = tostring(info.PurchaseId)
	local l = logOf(player)

	if l.durable[id] then
		return GRANTED                    -- on disk. Long settled.
	end

	if l.session[id] then
		-- Granted already this session but the write had not landed. Do NOT
		-- grant again -- just try to settle it.
		if commit(player) then
			l.durable[id], l.session[id] = true, nil
			return GRANTED
		end
		return NOT_YET
	end

	local product = ProductConfig.byId(info.ProductId)
	if not product then
		--[[
			NOT PurchaseGranted, and this is the single most expensive line in the
			file to get wrong. An id this build does not know is almost always a
			product that exists on the Dashboard and has not been added to
			ProductConfig yet. Consuming the receipt would take the player's Robux
			and hand back nothing, permanently and unrecoverably. Refusing it
			leaves the receipt with Roblox, so the moment the id is pasted in the
			purchase pays out by itself.
		]]
		warn(string.format("[ProductServer] receipt for unknown product %s -- "
			.. "NOT consumed. Add it to ProductConfig and it will pay out on retry.",
			tostring(info.ProductId)))
		return NOT_YET
	end

	local ok, granted = pcall(grantOf, player, product)
	if not (ok and granted) then
		if not ok then
			warn("[ProductServer] grant threw for " .. product.key .. ": " .. tostring(granted))
		end
		return NOT_YET
	end

	remember(l, id)
	if commit(player) then
		l.durable[id], l.session[id] = true, nil
		return GRANTED
	end

	-- Written down and paid out, but not yet on disk. The grant stays; an
	-- ordinary periodic save can still land it, and if the server dies first
	-- neither half was ever written, so the re-sent receipt finds a clean player.
	return NOT_YET
end

--------------------------------------------------------------------------
-- THE PERSISTENCE SEAM  (SaveService is the only caller)
--------------------------------------------------------------------------

-- The whole log, oldest first. Session ids are included deliberately: this IS
-- how they become durable, and a save that omitted them would leave a granted
-- receipt unrecorded on disk -- the double-pay case.
function ProductServer.exportFor(player: Player)
	local l = logs[player]
	if not l then
		return nil
	end
	return table.clone(l.order)
end

function ProductServer.restore(player: Player, list)
	local l = logOf(player)
	l.durable, l.session, l.order = {}, {}, {}
	if type(list) ~= "table" then
		return
	end
	for _, id in ipairs(list) do
		-- Strings only, and bounded. A profile written by an older build, or a
		-- corrupt one, must degrade to "no receipts remembered" rather than to an
		-- error three lines into a join.
		if type(id) == "string" and #id > 0 and #l.order < LOG_MAX then
			if not l.durable[id] then
				l.durable[id] = true
				table.insert(l.order, id)
			end
		end
	end
end

--------------------------------------------------------------------------
-- PUBLISHING WHAT A PRODUCT COSTS
--------------------------------------------------------------------------
--[[
	WHAT A PANEL READS TO DRAW A ROBUX PRICE, and it is the same folder and the
	same two attribute names GamePassService already publishes the passes into.

	ProductConfig's header used to promise this ("MarketplaceService is asked at
	boot and the answer is published, exactly the way GamePassService already does
	it for the passes") and nothing did it, so every product row in the shop drew
	SOON however real the product was. MenuHud has always READ it -- its Robux shop
	calls PassConfig.price(item.id) for a row whose kind is "product" -- so this is
	the missing half of a seam rather than a new one.

	A FOLDER OF ATTRIBUTES RATHER THAN A PUSH, for GamePassService's reason: it
	replicates on its own, it is there before any client asks, and a client joining
	late gets it for free.

	PRICE IS ALLOWED TO BE ABSENT and every caller copes -- see PassConfig.price.
	SetAttribute(nil) CLEARS, which is what a product taken off sale should do to a
	stale price.
]]
local function publishProductInfo()
	local folder = ReplicatedStorage:FindFirstChild(PassConfig.InfoFolder)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = PassConfig.InfoFolder
		folder.Parent = ReplicatedStorage
	end

	local offSale = {}
	for _, p in ProductConfig.all() do
		local key = tostring(p.id)
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(p.id, Enum.InfoType.Product)
		end)
		if ok and type(info) == "table" then
			local price = (type(info.PriceInRobux) == "number" and info.PriceInRobux > 0)
				and info.PriceInRobux or nil
			--[[
				THE PRICE IS THE TEST, NOT IsForSale, and that is the one place this
				differs from the pass version.

				A pass that is off sale reports IsForSale = false and that is the
				answer. A developer product does not have the same switch in the
				Creator Dashboard, and what it reports is not something to hang a
				live button on either way. A product with a real Robux price is one
				Roblox will sell; a product with no price is not, whatever the flag
				says. An explicit `false` is still honoured -- it can only ever mean
				something has genuinely been withdrawn.
			]]
			local forSale = price ~= nil and info.IsForSale ~= false
			folder:SetAttribute("Name_" .. key, tostring(info.Name))
			folder:SetAttribute("ForSale_" .. key, forSale)
			folder:SetAttribute("Price_" .. key, price)
			if not forSale then
				table.insert(offSale, string.format("%s (%d) -- no Robux price",
					tostring(info.Name), p.id))
			end
		else
			folder:SetAttribute("ForSale_" .. key, false)
			folder:SetAttribute("Price_" .. key, nil)
			table.insert(offSale, string.format("%s (%d) -- LOOKUP FAILED: %s",
				tostring(p.key), p.id, tostring(info)))
		end
	end

	if #offSale > 0 then
		warn("[ProductServer] these developer products cannot be bought. The button")
		warn("[ProductServer] draws SOON and opens no dialog until a price exists:")
		for _, line in offSale do
			warn("[ProductServer]     " .. line)
		end
		warn("[ProductServer] Fix: Creator Dashboard -> this experience ->")
		warn("[ProductServer] Monetization -> Developer Products -> set a price.")
	end
end

--------------------------------------------------------------------------
-- BOOT
--------------------------------------------------------------------------

local started = false
function ProductServer.start()
	assert(RunService:IsServer(), "[ProductServer] server-only")
	if started then
		return
	end
	started = true

	-- A row naming a kind nothing implements is found HERE, at boot, by whoever
	-- added it -- not at purchase time by whoever bought it.
	for _, p in ProductConfig.all() do
		if not ProductServer.KINDS[p.kind] then
			warn(string.format("[ProductServer] product '%s' names kind '%s', which "
				.. "nothing implements. It will refuse every receipt.",
				tostring(p.key), tostring(p.kind)))
		end
	end

	--[[
		AND THE ROWS THAT ARE STILL WAITING FOR AN ID.

		ProductConfig.all() DROPS a row whose id is 0, which is what makes an
		unfinished product harmless -- but it also makes it silent, and a silently
		missing shop is indistinguishable from a broken one. Somebody writes five
		coin packs, sees no coin packs, and goes looking for the bug.

		So say it out loud, in the same voice and with the same instructions
		GamePassService already uses for a pass that has not been created yet.
		This is a to-do list, not an error: the correct state of a fresh product
		row is exactly this.
	]]
	local waiting = {}
	for _, p in ProductConfig.Products do
		if type(p.id) ~= "number" or p.id <= 0 then
			table.insert(waiting, string.format("%s (%s)", tostring(p.name), tostring(p.key)))
		end
	end
	if #waiting > 0 then
		warn(string.format("[ProductServer] %d product%s written but not yet created on the "
			.. "Creator Dashboard, so %s cannot appear in the shop or be bought: %s. "
			.. "Create each one (Monetization -> Developer Products), paste its id into "
			.. "ProductConfig and set a price -- no code change is needed after that.",
			#waiting, #waiting == 1 and " is" or "s are",
			#waiting == 1 and "it" or "they", table.concat(waiting, ", ")))
	end

	-- On a thread: one web call per live product, and nothing below waits on the
	-- answer. The panel copes with a price landing late (it watches the folder's
	-- AttributeChanged) and with one never landing at all.
	task.spawn(publishProductInfo)

	Players.PlayerRemoving:Connect(function(plr)
		logs[plr] = nil
	end)

	MarketplaceService.ProcessReceipt = function(info)
		-- Wrapped, because a THROW here is read by Roblox as "not processed" and
		-- the receipt is re-sent forever -- an infinite retry loop that never
		-- pays out and never stops. An explicit NotProcessedYet is the same
		-- answer without the loop being invisible.
		local ok, decision = pcall(process, info)
		if not ok then
			warn("[ProductServer] ProcessReceipt threw: " .. tostring(decision))
			return NOT_YET
		end
		return decision
	end

	local live = #ProductConfig.all()
	print(string.format("[ProductServer] receipts online -- %d product%s live%s",
		live, live == 1 and "" or "s",
		live == 0 and " (every id in ProductConfig is still 0)" or ""))
end

return ProductServer
