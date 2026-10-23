# EU4 tech

How Europa Universalis IV's land units and technology evolve, read straight from the game files:

- **Countries:** a list on the left with every country at each of the game's start dates (1444 to 1792): ruler and heir with their adm/dip/mil, government, religion, culture, provinces and total base tax / production / manpower, trade goods and religions by development, historical rivals and friends, alliances, subjects and overlord, **national ideas** and **mission trees**. For the 1444 start there are also **armies and fleets**, manpower, treasury, monthly income by source, tradition, prestige and stability, read from a save.
- **Military units:** the strongest infantry, cavalry and artillery each unit group can recruit at every mil tech level (total pips, groups side by side), what mil tech multiplies (fire/shock damage, morale, tactics, combat width), and every unit of a group with its six pips on the mil tech axis.
- **Adm / Dip / Mil tech:** each effect's value at every level, by the year the game expects it, plus what each level unlocks.

Live at https://eu4tech.jane.berlin/ (the cog button on eu4.jane.berlin leads here). A push to `main` uploads the page through GitHub Actions; the game data (`data.json`, `countries.json`, `missions.json`, `ideas.json`, `flags/`, `icons/`) only goes up from a full local deploy (`./deploy.sh`), since only a machine with EU4 installed can generate it. The page started in the [vic3tech](https://github.com/jane-natucci/vic3tech) repo and shares no code with it.

```bash
ruby extract.rb             # writes data.json from the default Steam install (gitignored: Paradox's data)
ruby extract_countries.rb   # countries.json, missions.json, ideas.json, flags/ and icons/ (also gitignored)
ruby extract_save.rb "/path/to/Save.eu4"   # forces.json from a non-Ironman save made on the first day of 1444 (gitignored)
./deploy.sh                 # full deploy: page, data and flags
bundle exec ruby -run -e httpd . -p 8000   # then open http://localhost:8000/
```

Both extractors take the game path as their first argument if EU4 is installed elsewhere. Re-run it after a game patch.

## How the numbers work

- Pips come from `common/units/*.txt`; a unit is available from the mil tech level whose `enable = <unit>` names it. Artillery has no unit group: every group shares it.
- Tech effects add up level by level, on top of the game's base values (`BASE_COMBAT_WIDTH` in `defines.lua`, `base_values` in `static_modifiers`). `allowed_idea_groups` is the exception: each level sets it outright.
- "Strongest" means most total pips. That's a simplification: which pips matter depends on the phase (fire vs shock) and on what you fight.

## How the country data works

- Provinces: `history/provinces` gives each province's starting values and dated changes; the owner, base tax / production / manpower and trade good at a bookmark date are the initial values with every change up to that date applied. A country exists at a date if it owns a province.
- Countries: `history/countries` and `history/diplomacy` the same way (government, religion, ruler and heir from the latest block up to the date; ties that are active on the date).
- Missions: series in `missions/` are attached to the countries their `potential` names, evaluating the DLC conditions as a player who owns every DLC; a country's series are merged into one tree per slot. Conditions the extractor can't evaluate (map settings, flags) are treated as unknown, so alternative branches all appear.
- National ideas come from `common/ideas`. EU4 has no file saying which modifiers are percentages, so that is a best guess.
- Armies, fleets and the economy figures come from a save, not from files: a campaign builds starting forces from each country's force limit (`STARTING_ARMY_SIZE` in `defines.lua`), so the result only exists in a running game. `extract_save.rb` reads a non-Ironman text save made on the first day of a campaign (a zip of plain text) and keeps, per country, its regiments and ships by type, armies and fleets with their location, manpower and sailors, treasury, last month's income split into tax / production / trade / other, tradition, prestige, stability and tech levels. It is one campaign's start: its DLC and settings shape it, it covers only the date it was made on (shown on the page), and the three income categories are the first three entries of the game's ledger table.
- Icons: a mission's own icon (the sprite its `icon` names in `interface/*.gfx`) and, for national ideas, the icon of each modifier (`gfx/interface/ideas_EU4/<modifier>.dds`); an idea's header icon is its first modifier's. Flags are kept at 64 px for the list and 128 px for a country's page.
- Text with game variables (`[Root.GetName]`) has the variable removed, so a few mission texts read oddly.

## Later

- Load a melted save (pdx.tools melts EU4 too): each country's mil tech, unit group, the units it fields vs the best it could have.
