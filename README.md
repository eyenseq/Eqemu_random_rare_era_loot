# Eqemu_random_rare_era_loot
Assigns random loot by era

## Usage in global_npc.pl
```
plugin::era_global_rare_loot_on_spawn(
		min_level       => 1,
		max_level       => 255,
		named_only      => 0,    #named only or not
		min_loot_chance => 40.0,  #min rare chance
		proc_chance_pct => 100.0,  #chance to add
		rolls           => 2,    #items to add
		debug           => 0,
		include_noloot  => 0,   # allow NPCs with no base loottable
		# include_merchants => 1, # if you ever go full chaos mode
	);
```
## Included sql to add needed table adjust era's if needed

