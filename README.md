# RecipeProfit

Shows whether a recipe is worth buying before you buy it. Hover any recipe at the auction house or in your bags,
and its tooltip shows what the craft costs, what the result sells for and the profit. It also shows where else to
get the recipe.

**Requires [Auctionator](https://www.curseforge.com/wow/addons/auctionator)**: its AH and vendor prices come first.
Made for WoW Forever.

## Features

- **Recipe tooltips**: each reagent's cost (vendor reagents marked), the crafted item's price after the AH cut,
  and the profit. Old prices show their age, and a `!` marks a reagent that's been undercut.
- **Prices from Auctionator, gaps filled by a scan**: recipe tooltips use Auctionator's prices. When you
  search the auction house for recipes, a bar under the results list says whether any of their reagents or
  crafted items have no price. Click **Scan** beside it to search the AH for them: 25 items at a time, so it
  takes seconds (the list shows those items briefly, then your search comes back), then each reagent's full
  listings in the background, for the real cost of buying several and to flag undercuts. Items already priced
  today are skipped; shift-click Scan, or click it when every price is already known, to search everything
  again.
- **Recipe sources**: vendors you've visited, mobs you've looted and quest rewards you've been offered. Saved
  account-wide. With ForeverDungeonJournal installed, it adds dungeon
  drops and quest rewards too.
- Works on its own or alongside [ProfessionProfit](https://github.com/TLWoodJr/ProfessionProfit).

## Commands

| Command | What it does |
| --- | --- |
| `/rp scan` | Search the AH for every recipe in the current results, even items priced today |
| `/rp price <item name>` | Show the price used for an item |
| `/rp debug` | Print raw recipe tooltip lines (for bug reports) |
| `/rp reset` | Clear saved item names |

## Bugs and requests

Open an issue at <https://github.com/TLWoodJr/RecipeProfit/issues> with the recipe, what you expected, and your
Auctionator version.

## Licence

GPL-3.0. See [LICENSE](LICENSE). Uses [LibCraftProfit-1.0](https://github.com/TLWoodJr/LibCraftProfit-1.0),
LibStub and CallbackHandler-1.0.
