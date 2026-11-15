--[[
	THE SIFT SYSTEM, removed from the running game 2026-08-24 as part of the
	economy rebalance. It had been switched off for a long time (ServerMain's
	start() calls were commented out and the requires deleted); everything in
	this folder is the switched-off feature, parked so the anti-cheat design in
	SiftServer's header is not lost.

	WHAT WAS REMOVED ELSEWHERE, should anyone restore this:

	  ServerMain            the two start() calls after SellServer.start(), and
	                        the two require lines above them (deleted earlier)
	  Net.EVENT_NAMES       "SiftBegin", "SiftEnd", "SiftProgress",
	                        "SiftChunkGone", "ScreenChanged" (server->client)
	                        and "SiftShake", "SiftEndRequest" (client->server).
	                        "SiftItemCleaned" was KEPT -- RevealPopup and
	                        MenuHud connect to it at boot and Net.get asserts
	                        on unknown names.
	  GameConfig            the Sifting table (cadence curve, ChunkWork 0.95 --
	                        held equal to Washing.ChunkWork -- packet limits,
	                        ShakeGrace 0.4, BayRange 18), the Screen table
	                        (12 deck tiers, every cost 0), Tags.SiftBay, and
	                        Inventory.ScreenCapacity (read by nothing).
	  BayBuilder            buildSiftBay (the shack + sprung deck + catch bin)
	                        and ensureWorld, its only caller. Nothing else
	                        called either.

	KNOWN STALE BITS INSIDE THE PARKED FILES (fix on revival):
	  * SiftClientController derives SAND_PER_CHUNK against a 34-chunk crust;
	    ItemConfig.CrustChunkCount is 22.
	  * SiftScreen.applyTier writes the four Washer* attributes and would fight
	    ProgressionServer.applyAll, which owns them for the live washer.
	  * The Screen tier table's rate/cost columns were already dead when it was
	    parked; the Pressure track (WasherPressure attribute) is the live rate.
]]
return {}