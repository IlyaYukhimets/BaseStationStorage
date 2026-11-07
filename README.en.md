# Base Station Storage

Server-side registry of base storages for Project Zomboid Build 42: crates, fridges, cabinets and shelves that the safehouse owner marks once, after which the game pulls ingredients out of them and puts items back in.

Replaces the Craft From Containers mod on our server: no craft zones, no button in the safehouse panel, no waiting for the game to finish scanning a zone.

## Features

- **Crafting from the base.** Registered containers are appended to the same source list that vanilla crafting and Neat_Crafting use. The mod adds no crafting window of its own.
- **Cooking from the fridge.** Ingredients come from the same registered containers, fridges and freezers included. Evolved recipes (salads, soups, burgers) and the B42 craft recipes both resolve their items through that one funnel, so no extra hook is needed.
- **Auto-sort.** "Distribute over base" sends items from a container or your inventory into the registered storages: same item type first, then the first container with room.
- **Per-container roles.** "Supply ingredients" and "accept items on sort" toggle independently, so a fridge can feed cooking without being filled with nails.
- The registry lives on the server, is saved with the world and synced to clients, so it survives restarts and is the same for every player.

## Install

```sh
scripts/check.sh              # Lua 5.1 syntax, translation JSON, unit tests
scripts/deploy.sh --dry-run   # build the package and verify transport, server untouched
scripts/deploy.sh --restart   # install and restart the container
scripts/verify.sh             # inspect the deployed copy (read-only)
```


The server must have safehouses enabled: `PlayerSafehouse=true` or `AdminSafehouse=true` in `servertest.ini`. Without them the mod refuses registration — otherwise anyone could declare any container "base storage".

## In game

1. Claim a safehouse (right-click the floor inside a building -> Claim safehouse).
2. Right-click a crate, fridge or cabinet -> **Base** -> **Add to base**.
3. The same submenu toggles roles and removes the registration; "Show base list" prints the registry to the client console.
4. Crafting and cooking immediately see the contents of those containers, as if they were open next to you.
5. "Distribute over base" on a source container, or "Distribute my inventory over base" in the inventory menu.

Registration is available to the safehouse owner and residents, plus admins and moderators. The check runs against **the container's square**, not the player's position: standing next door does not let you register someone else's fridge.

## Trust model

The client only asks; the server decides:

- `server/BSSServer.lua` handles `add`/`remove`/`toggle`/`sync`, validates coordinates, container existence, safehouse and permissions, and only then writes global `ModData` and transmits it.
- `server/BSSGuard.lua` closes the second hole: vanilla `ISHandcraftAction:serverStart()` rebuilds the craft logic from the container list the client sent, and Java never validates `manualInputs` at all — it resolves an item by ID in any container in the world. The wrapper rejects a container that is neither registered nor within 3 tiles, and strips such items from manual inputs. Containers without a world square (bags, vehicles, corpses) are left alone, otherwise vanilla behaviour would break.
- The same file solves the opposite problem: Java's `BaseCraftingLogic.isContainersAccessible()` refuses any container further than 2.5 tiles from the player, and it cannot be overridden from Lua. For registered donors `performRecipe` therefore runs our code: `updateFloorContainer` -> `recipeData:perform(...)` -> outputs via `Actions.addOrDropItem` -> `luaCallOnCreate` -> `processDestroyAndUsedItems`, i.e. the vanilla tail without the distance check. A failure there is only logged: there is no vanilla retry, so items can never be consumed twice.

The 3-tile radius is not decoration: it is the distance at which the game shows container contents at all, so the wrapper can only add sources and never remove what the player already had.

## Limitations

- The mod must be installed **on the client and on the server**. It is a local mod, not a Workshop item: the server does not hand it out, so the files have to be given to the players (archive) — otherwise the client sees neither the menu nor the shared containers.
- Multiplayer only: there is no server side in single player, so the mod stays inactive.
- Containers in unloaded chunks supply nothing: the client does not know their contents. The base has to be in loaded terrain.
- **Heating food stays vanilla.** Assembling a dish (salad, soup, burger) out of a registered fridge works; frying raw meat "from across the room" does not — heating lives in Java and needs the food physically inside the stove's container with the stove switched on.
- Auto-sort runs through the vanilla `ISInventoryPane:transferItemsByWeight`: one ordinary transfer action per item, exactly like the "Transfer all" button.
- A container's identity is its square plus its container type. Tear the object down and build another of the same type in the same place and it inherits the registration.
- Building (`ISBuildIsoEntity`) rebuilds its logic from the client container list just like crafting, but that path is not covered by our guard — the same class of hole crafting had before this mod.
- The timed action packet only checks `id != -1` (`IDShort.isConsistent`), so a forged packet can claim another character. Not fixable from Lua: an engine limitation, not this mod's.

## Layout

```
mod.info
media/lua/shared/BaseStationStorage/BSS.lua         constants and pure helpers
media/lua/shared/BaseStationStorage/BSSData.lua     registry in ModData, world binding
media/lua/shared/Translate/{RU,EN}/UI.json          UI strings
media/lua/server/BaseStationStorage/BSSServer.lua   authoritative side: commands, checks, writes
media/lua/server/BaseStationStorage/BSSGuard.lua    craft container list validation
media/lua/client/BaseStationStorage/BSSClient.lua   menus, requests, server replies
media/lua/client/BaseStationStorage/BSSContainers.lua  craft UI integration (single point)
media/lua/client/BaseStationStorage/BSSSort.lua     auto-sort
tests/logic_test.lua                                unit tests for the pure logic
scripts/{check,deploy,verify}.sh                    gate, deploy, verify
```

## Development

```sh
apk add lua5.1      # luac5.1 is the dialect Kahlua actually runs
scripts/check.sh
```

`check.sh` is the mandatory gate: `luac5.1 -p` on every file, translation JSON parsing, `mod.info` sanity (id matches the folder, no `require=`), and the unit tests. A syntax error in a mod never shows up in the server log — the mod is silently dropped from the list, which is why the gate matters more than the log.
