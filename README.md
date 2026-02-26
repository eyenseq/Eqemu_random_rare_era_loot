# Era Global Rare Loot Plugin

A dynamic era-based rare loot system for EQEmu servers

## 📌 Overview

The Era Global Rare Loot Plugin expands EverQuest gameplay by enabling era-wide rare loot pools.
Instead of rare items only dropping in a single zone, this plugin merges all qualifying rare loot from every zone in the same era and gives NPCs a configurable chance to drop from that shared pool.

This provides:

More exciting loot from any mob in the same era

Wider exploration value

More organic progression

Fully customizable filtering and rarity settings

The plugin is lightweight, cached, and highly configurable.

## ✨ Features

Builds era-wide global loot pools

Filters by minimum loot chance (e.g., only ≥20% drop chance)

Skips merchants, bankers, guildmasters, pets, triggers, etc.

Named-only mode (optional)

Weighted random selection

Configurable % chance per spawn

Caches zone/era for performance

Full debugging output option

Optional manual era override

Optional Blacklists

## 📂 Requirements
1. EQEmu server with Perl quest support

Place this plugin in your quests/plugins/ directory.

2. SQL tables: zone_era, era_order, item era

Run the provide sql files to create tables.

zone_era    =>    Used to define what zones belong in what era (fallback method. used in item_era query.)

era_order   =>    Era's expansion order (used in item_era query.)

item_era    =>    List of all drop items_id tagged with era

You define what each zone short name means (Classic, Kunark, Velious, etc.).

3. (Optional) Environment variables

The plugin reads DB credentials automatically from:

DB_HOST
DB_PORT
DB_NAME
DB_USER
DB_PASSWORD
DBI_EXTRA


Defaults match a normal EQEmu install.

## 🛠 Installation

Save the plugin as:

quests/plugins/era_global_rare_loot.pl


Add/Import the SQL files.

Populate the table with your era mapping (examples below).

## 📜 Usage

Add this to your global NPC script (global_npc.pl):

```perl
sub EVENT_SPAWN {
    plugin::era_global_rare_loot_on_spawn(
        min_level       => 10,    # only affect mobs 10+
        max_level       => 255,
        named_only      => 0,     # only named mobs 0 no 1 yes
        raid_only       => 0,     # NEW only raid mobs 0 no 1 yes
        min_loot_chance => 20.0,  # only include items with >=20% base drop %
        max_loot_chance => 80.0,  # NEW  only include items with <=80% base drop %
        proc_chance_pct => 35.0,   # spawn has 35% chance to roll for rare loot
        rolls           => 1,     # maximum rare items added
        include_noloot   => 0,    # Include NPC's with no loot 0 no 1 yes
        ## Optional params ##
        debug           => 0,      # enable debug while testing
        # This line turns the plugin OFF for ANY spawn2 row whose version=1
        blacklist_any_versions => [1],
        # This line turns the plugin OFF for ANY spawn2 whose zonesn = listed zone
        blacklist_zones => [ 'poknowledge', 'guildlobby' ],
        # This line turns the plugin OFF for ANY spawn2 whose zonesn and version = listed zonesn, version
        blacklist_zone_versions => {
        soldungb => [2],
    );
}
```
#Optional

this will build an item list with items era tagged (have to have table item_era) If doesn't exist will fall back to another method.
```
REPLACE INTO item_era (item_id, era)
SELECT
  x.item_id,
  eo.era
FROM (
  SELECT
    ld.item_id,
    MIN(eo.ord) AS min_ord
  FROM npc_types n
  JOIN loottable_entries lt ON lt.loottable_id = n.loottable_id
  JOIN lootdrop_entries ld ON ld.lootdrop_id = lt.lootdrop_id
  JOIN spawnentry se ON se.npcID = n.id
  JOIN spawn2 s2 ON s2.spawngroupID = se.spawngroupID
  JOIN zone_era ze ON ze.zone_short = s2.zone
  JOIN era_order eo ON eo.era = ze.era
  GROUP BY ld.item_id
) x
JOIN era_order eo ON eo.ord = x.min_ord;
```
and if you need to exclude zone versions
```
REPLACE INTO item_era (item_id, era)
SELECT
  x.item_id,
  eo.era
FROM (
  SELECT
    ld.item_id,
    MIN(eo.ord) AS min_ord
  FROM npc_types n
  JOIN loottable_entries lt ON lt.loottable_id = n.loottable_id
  JOIN lootdrop_entries ld ON ld.lootdrop_id = lt.lootdrop_id
  JOIN spawnentry se ON se.npcID = n.id
  JOIN spawn2 s2 ON s2.spawngroupID = se.spawngroupID
  JOIN zone_era ze ON ze.zone_short = s2.zone
  JOIN era_order eo ON eo.era = ze.era
  WHERE COALESCE(s2.version,0) NOT IN (2)
  GROUP BY ld.item_id
) x
JOIN era_order eo ON eo.ord = x.min_ord;
```
and if you need to exclude zones
```
REPLACE INTO item_era (item_id, era)
SELECT
  x.item_id,
  eo.era
FROM (
  SELECT
    ld.item_id,
    MIN(eo.ord) AS min_ord
  FROM npc_types n
  JOIN loottable_entries lt ON lt.loottable_id = n.loottable_id
  JOIN lootdrop_entries ld ON ld.lootdrop_id = lt.lootdrop_id
  JOIN spawnentry se ON se.npcID = n.id
  JOIN spawn2 s2 ON s2.spawngroupID = se.spawngroupID
  JOIN zone_era ze ON ze.zone_short = s2.zone
  JOIN era_order eo ON eo.era = ze.era
  WHERE s2.zone NOT IN ('soldunga','soldungb')
  GROUP BY ld.item_id
) x
JOIN era_order eo ON eo.ord = x.min_ord;
```

Once added, every NPC spawn will automatically evaluate rare-era loot.

## 💾 How Loot Is Selected

NPC spawns

Plugin finds zone shortname

Looks up era via zone_era

Builds (or loads cached) rare-item pool:

Equipable items only

Must have real stats (HP/mana/end or heroic stats)

Must meet the minimum chance requirement

Runs weighted random selection

Adds selected item(s) via quest::addloot

## 🧪 Debugging

Enable:

debug => 1


Displays:

Zone shortname

Era result

Pool size

Items added

Reasons mobs were skipped

Example:

[EraGlobalLoot] CALLED for a_goblin (12345) level 18
[EraGlobalLoot] zonesn=runnyeye
[EraGlobalLoot] ERA=1 min_loot_chance=20
[EraGlobalLoot] POOL SIZE for era=1 = 142
[EraGlobalLoot] ADD a_goblin(12345) -> item 5012

## 📅 Suggested Era Mapping
Era	Expansion

Classic

Kunark

Velious

Luclin

Planes of Power

Loy

Ldon

God

Oow

Custom server eras

## 📝 Notes

Ignores NPCs with no loottable unless include_noloot => 1

Pets, bankers, merchants, guildmasters, and triggers are excluded by default

Very low overhead thanks to caching

Safe to use with custom eras and zones
