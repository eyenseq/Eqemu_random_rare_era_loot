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

2. SQL table: zone_era

Used to map zone shortnames to an era.
```sql
CREATE TABLE IF NOT EXISTS `zone_era` (
  `zone_short` varchar(32) NOT NULL,
  `era` varchar(32) NOT NULL,
  PRIMARY KEY (`zone_short`),
  KEY `idx_era` (`era`)
  );
```

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


Add/Import the SQL file for zone_era.

Populate the table with your era mapping (examples below).

## 📜 Usage

Add this to your global NPC script (global_npc.pl):

```perl
sub EVENT_SPAWN {
    plugin::era_global_rare_loot_on_spawn(
        min_level       => 10,    # only affect mobs 10+
        max_level       => 255,
        named_only      => 1,     # only named mobs
        min_loot_chance => 20.0,  # only include items with >=20% base drop %
        proc_chance_pct => 3.0,   # spawn has 3% chance to roll for rare loot
        rolls           => 1,     # maximum rare items added
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

Once added, every NPC spawn will automatically evaluate rare-era loot.

## ⚙ Configuration Options

Option	Default	Description
min_level	1	Ignore NPCs below this level
max_level	255	Ignore NPCs above this level
named_only	0	Only apply to named NPCs (name-based heuristic)
min_loot_chance	25.0	Only pool items with base chance ≥ this value
proc_chance_pct	5.0	% chance per spawn to attempt a rare roll
rolls	1	Maximum number of rare items added
debug	0	Print detailed debug messages
era	undef	Manually override era if needed

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

## 🧱 Example SQL for Assigning Eras
```sql
INSERT INTO zone_era (zone_short, era) VALUES
('qeynos', classic),
('qeynos2', classic),
('blackburrow', classic),
('gfaydark', classic),
('crushbone', classic),

('wakening', velious),
('velketor', velious);
```

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
