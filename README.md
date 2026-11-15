# Clean the Beach

A Roblox game about cleaning up beaches, with its source managed through [Rojo](https://rojo.space).

Play it on Roblox: https://www.roblox.com/games/98491176124242

## What's here

- `src/ServerScriptService` - server game logic and services
- `src/ReplicatedStorage` - shared modules, configs and asset models
- `src/StarterPlayerScripts` - client scripts and UI
- `src/ReplicatedFirst`, `src/ServerStorage`
- `default.project.json` - Rojo project file

Some asset folders are stored as `.rbxm` models because Rojo can't represent them as plain files (for example folders with duplicate-named children). The world map and terrain in Workspace are not included in this repo, and the real redeem codes have been replaced with a placeholder.

## Using it

```
rojo build -o CleanTheBeach.rbxlx
```

Or run `rojo serve` and connect from the Rojo plugin in Studio.
