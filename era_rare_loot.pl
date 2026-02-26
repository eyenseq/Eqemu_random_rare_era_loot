package plugin;

use strict;
use warnings;
use DBI;

# ==========================================================
# Era Global Rare Loot Plugin
# Modified:
#   - named_only now uses npc_types.rare_spawn
#   - raid_target_only (and raid_only alias) uses npc_types.raid_target
#   - caches rare_spawn + raid_target once per zone process
# ==========================================================

our $EGL_DBH;
our $EGL_DB_HOST = $ENV{DB_HOST}     // '127.0.0.1';
our $EGL_DB_PORT = $ENV{DB_PORT}     // 3306;
our $EGL_DB_NAME = $ENV{DB_NAME}     // 'peq';
our $EGL_DB_USER = $ENV{DB_USER}     // 'eqemu';
our $EGL_DB_PASS = $ENV{DB_PASSWORD} // '';
our $EGL_DBI_EXTRA = $ENV{DBI_EXTRA} // 'mysql_enable_utf8=1';

# Existing caches
our %EGL_ZONE_ERA_CACHE;
our %EGL_ERA_POOL_CACHE;
our $EGL_HAS_ITEM_ERA;  # undef=unknown, 0=no, 1=yes

# NEW: Named/Raid caches
our %EGL_RARESPAWN_CACHE;
our %EGL_RAIDTARGET_CACHE;
our $EGL_NR_CACHE_LOADED = 0;

# ----------------------------------------------------------
# DB handle
# ----------------------------------------------------------
sub _egl_dbh {
    return $EGL_DBH if $EGL_DBH && eval { $EGL_DBH->ping };
    my $dsn = "DBI:mysql:database=$EGL_DB_NAME;host=$EGL_DB_HOST;port=$EGL_DB_PORT;$EGL_DBI_EXTRA";

    my $ok = eval {
        $EGL_DBH = DBI->connect(
            $dsn, $EGL_DB_USER, $EGL_DB_PASS,
            { RaiseError => 1, PrintError => 0, AutoCommit => 1 }
        );
    };
    return unless $ok && $EGL_DBH;
    return $EGL_DBH;
}

sub _egl_has_item_era_table {
    return $EGL_HAS_ITEM_ERA if defined $EGL_HAS_ITEM_ERA;

    my $dbh = _egl_dbh();
    if (!$dbh) {
        $EGL_HAS_ITEM_ERA = 0;
        return 0;
    }

    my $ok = eval {
        my $sth = $dbh->prepare("SHOW TABLES LIKE 'item_era'");
        $sth->execute();
        my ($t) = $sth->fetchrow_array();
        $sth->finish();
        $EGL_HAS_ITEM_ERA = $t ? 1 : 0;
        1;
    };

    $EGL_HAS_ITEM_ERA = 0 if !$ok;
    return $EGL_HAS_ITEM_ERA;
}

# ----------------------------------------------------------
# NEW: Load named/raid cache once
# ----------------------------------------------------------
sub _egl_load_named_raid_cache {
    return if $EGL_NR_CACHE_LOADED;

    my $dbh = _egl_dbh() or return;

    my $sth = $dbh->prepare(q{
        SELECT id, rare_spawn, raid_target
        FROM npc_types
        WHERE rare_spawn <> 0 OR raid_target <> 0
    });

    $sth->execute();

    %EGL_RARESPAWN_CACHE  = ();
    %EGL_RAIDTARGET_CACHE = ();

    while (my $r = $sth->fetchrow_hashref) {
        my $id = int($r->{id} || 0);
        next if $id <= 0;

        $EGL_RARESPAWN_CACHE{$id}  = 1 if int($r->{rare_spawn}  || 0) != 0;
        $EGL_RAIDTARGET_CACHE{$id} = 1 if int($r->{raid_target} || 0) != 0;
    }

    $EGL_NR_CACHE_LOADED = 1;
}

sub _egl_is_named_db {
    my ($npc_id) = @_;
    return 0 unless $npc_id;
    _egl_load_named_raid_cache();
    return $EGL_RARESPAWN_CACHE{$npc_id} ? 1 : 0;
}

sub _egl_is_raid_db {
    my ($npc_id) = @_;
    return 0 unless $npc_id;
    _egl_load_named_raid_cache();
    return $EGL_RAIDTARGET_CACHE{$npc_id} ? 1 : 0;
}

# ----------------------------------------------------------
# Zone + version (UNCHANGED — already correct)
# ----------------------------------------------------------
sub _egl_zoneinfo_for_npc {
    my ($npc) = @_;
    my $dbh = _egl_dbh() or return;

    my $spawn2_id = eval { $npc->GetSpawnPointID() } || 0;
    return unless $spawn2_id;

    my ($zonesn, $version);
    my $sth = $dbh->prepare("SELECT zone, version FROM spawn2 WHERE id = ? LIMIT 1");
    $sth->execute($spawn2_id);
    ($zonesn, $version) = $sth->fetchrow_array();
    $sth->finish;

    return ($zonesn // undef, defined $version ? $version : undef);
}

# Prefer live zone vars (works even for pets / quest spawns), fallback to spawn2 lookup
sub _egl_zoneinfo_live {
    my ($npc) = @_;

    # These are always correct for the *current zone instance*
    my $zonesn      = plugin::val('zonesn');
    my $zoneversion = plugin::val('zoneversion');

    $zonesn = undef if (!defined($zonesn) || $zonesn eq '');

    # plugin::val can return undef sometimes; normalize
    $zoneversion = undef if (!defined($zoneversion) || $zoneversion eq '');

    # If we have live zonesn, trust it
    if (defined $zonesn) {
        # zoneversion might still be undef on some setups; default to 0
        $zoneversion = 0 if !defined $zoneversion;
        return ($zonesn, $zoneversion);
    }

    # Fallback: old behavior (spawn2 lookup)
    return _egl_zoneinfo_for_npc($npc);
}

# ----------------------------------------------------------
# ERA lookup (UNCHANGED)
# ----------------------------------------------------------
sub _egl_era_from_zone {
    my ($zonesn) = @_;
    return unless $zonesn;

    return $EGL_ZONE_ERA_CACHE{$zonesn}
        if exists $EGL_ZONE_ERA_CACHE{$zonesn};

    my $dbh = _egl_dbh() or return;

    my $sth = $dbh->prepare(
        "SELECT era FROM zone_era WHERE zone_short = ? LIMIT 1"
    );
    $sth->execute($zonesn);
    my ($era) = $sth->fetchrow_array();
    $sth->finish;

    $EGL_ZONE_ERA_CACHE{$zonesn} = $era if defined $era;
    return $era;
}

# ----------------------------------------------------------
# Era pool (UNCHANGED)
# ----------------------------------------------------------
sub _egl_era_pool {
    my ($era, $min_chance, $max_chance, $blacklist_versions) = @_;
    $min_chance //= 0;
    $max_chance = 100000 if !defined $max_chance;  # effectively no ceiling

    $blacklist_versions ||= [];
    $blacklist_versions = [] if ref($blacklist_versions) ne 'ARRAY';

    # Normalize blacklist values to ints
    my @bl = map { int($_) } grep { defined($_) } @$blacklist_versions;
    @bl = grep { $_ >= 0 } @bl;

    return [] unless $era;

    # Include blacklist in cache key so different blacklists don't reuse same pool
    my $bl_key = @bl ? join(",", @bl) : "none";
    my $key = join(":", $era, $min_chance, $max_chance, "bl=$bl_key", "realstats");
    return $EGL_ERA_POOL_CACHE{$key} if exists $EGL_ERA_POOL_CACHE{$key};

    my $dbh = _egl_dbh() or return [];

    # Build optional blacklist clause (only if @bl has values)
    my $bl_clause = '';
    if (@bl) {
        $bl_clause = ' AND COALESCE(s2.version,0) NOT IN (' . join(',', ('?') x @bl) . ') ';
    }

    my $rows = [];

    # -------------------------------
    # PRIMARY: item_era-restricted pool (strict era purity)
    # -------------------------------
    if (_egl_has_item_era_table()) {

        my $sql_item_era = qq{
            SELECT DISTINCT ld.item_id, ld.chance
            FROM npc_types n
            JOIN loottable_entries lt ON lt.loottable_id = n.loottable_id
            JOIN lootdrop_entries ld ON ld.lootdrop_id = lt.lootdrop_id
            JOIN items i ON i.id = ld.item_id
            JOIN spawnentry se ON se.npcID = n.id
            JOIN spawn2 s2 ON s2.spawngroupID = se.spawngroupID
            JOIN zone_era ze ON ze.zone_short = s2.zone
            JOIN item_era ie ON ie.item_id = ld.item_id
            WHERE ze.era = ?
              AND ie.era = ?                 -- STRICT: item must be tagged to this era
              __BL_CLAUSE__
              AND ld.chance >= ?
              AND ld.chance <= ?
              AND i.slots != 0
              AND (
                    i.hp > 0 OR i.mana > 0 OR i.endur > 0 OR
                    i.astr > 0 OR i.asta > 0 OR i.adex > 0 OR
                    i.aagi > 0 OR i.aint > 0 OR i.awis > 0 OR i.acha > 0
              )
        };

        $sql_item_era =~ s/__BL_CLAUSE__/$bl_clause/;

        my $sth = $dbh->prepare($sql_item_era);

        # Bind order must match placeholders:
        # ze.era, ie.era, (bl...), min, max
        my @bind = ($era, $era);
        push @bind, @bl if @bl;
        push @bind, ($min_chance, $max_chance);

        my $ok = eval { $sth->execute(@bind); 1; };

        if ($ok) {
            while (my $r = $sth->fetchrow_hashref) {
                push @$rows, $r;
            }
        }
        $sth->finish() if $sth;

        if ($rows && @$rows) {
            $EGL_ERA_POOL_CACHE{$key} = $rows;
            return $rows;
        }
        # else fall through to legacy method
    }

    # -------------------------------
    # FALLBACK: legacy inferred pool (no item_era or empty)
    # -------------------------------
    my $sql_legacy = qq{
        SELECT DISTINCT ld.item_id, ld.chance
        FROM npc_types n
        JOIN loottable_entries lt ON lt.loottable_id = n.loottable_id
        JOIN lootdrop_entries ld ON ld.lootdrop_id = lt.lootdrop_id
        JOIN items i ON i.id = ld.item_id
        JOIN spawnentry se ON se.npcID = n.id
        JOIN spawn2 s2 ON s2.spawngroupID = se.spawngroupID
        JOIN zone_era ze ON ze.zone_short = s2.zone
        WHERE ze.era = ?
          __BL_CLAUSE__
          AND ld.chance >= ?
          AND ld.chance <= ?
          AND i.slots != 0
          AND (
                i.hp > 0 OR i.mana > 0 OR i.endur > 0 OR
                i.astr > 0 OR i.asta > 0 OR i.adex > 0 OR
                i.aagi > 0 OR i.aint > 0 OR i.awis > 0 OR i.acha > 0
          )
    };

    $sql_legacy =~ s/__BL_CLAUSE__/$bl_clause/;

    my $sth2 = $dbh->prepare($sql_legacy);

    my @bind2 = ($era);
    push @bind2, @bl if @bl;
    push @bind2, ($min_chance, $max_chance);

    $sth2->execute(@bind2);

    $rows = [];
    while (my $r = $sth2->fetchrow_hashref) {
        push @$rows, $r;
    }
    $sth2->finish();

    $EGL_ERA_POOL_CACHE{$key} = $rows;
    return $rows;


    # -------------------------------
    # FALLBACK: legacy inferred pool (no item_era)
    # (Still excludes version 2, because you want that)
    # -------------------------------
    my $sql_legacy = qq{
        SELECT DISTINCT ld.item_id, ld.chance
        FROM npc_types n
        JOIN loottable_entries lt ON lt.loottable_id = n.loottable_id
        JOIN lootdrop_entries ld ON ld.lootdrop_id = lt.lootdrop_id
        JOIN items i ON i.id = ld.item_id
        JOIN spawnentry se ON se.npcID = n.id
        JOIN spawn2 s2 ON s2.spawngroupID = se.spawngroupID
        JOIN zone_era ze ON ze.zone_short = s2.zone
        WHERE ze.era = ?
          AND (s2.version IS NULL OR s2.version <> 2)
          AND ld.chance >= ?
          AND ld.chance <= ?
          AND i.slots != 0
          AND (
                i.hp > 0 OR i.mana > 0 OR i.endur > 0 OR
                i.astr > 0 OR i.asta > 0 OR i.adex > 0 OR
                i.aagi > 0 OR i.aint > 0 OR i.awis > 0 OR i.acha > 0
          )
    };

    my $sth2 = $dbh->prepare($sql_legacy);
    $sth2->execute($era, $min_chance, $max_chance);

    $rows = [];
    while (my $r = $sth2->fetchrow_hashref) {
        push @$rows, $r;
    }
    $sth2->finish();

    $EGL_ERA_POOL_CACHE{$key} = $rows;
    return $rows;
}

# ----------------------------------------------------------
# Weighted pick (UNCHANGED)
# ----------------------------------------------------------
sub _egl_pick_weighted {
    my ($rows) = @_;
    return unless $rows && @$rows;

    my $total = 0;
    $total += ($_->{chance} || 0) for @$rows;
    return unless $total > 0;

    my $roll = rand($total);
    my $acc  = 0;

    for my $r (@$rows) {
        $acc += ($r->{chance} || 0);
        return $r if $roll <= $acc;
    }

    return $rows->[-1];
}

# ----------------------------------------------------------
# PUBLIC ENTRY
# ----------------------------------------------------------
sub era_global_rare_loot_on_spawn {
    my (%opt) = @_;

    my $npc = plugin::val('npc');
    return unless $npc;

    my $level = $npc->GetLevel();
    my $npc_id = $npc->GetNPCTypeID();
    my $npc_name = $npc->GetName();

    my $min_level  = $opt{min_level} // 1;
    my $max_level  = $opt{max_level} // 255;
    my $named_only = $opt{named_only} // 0;

    # NEW
    my $raid_target_only = ($opt{raid_target_only} // $opt{raid_only} // 0);

    my $rolls_cap  = $opt{rolls} // 1;
    my $debug      = $opt{debug} // 0;

	my $include_noloot = $opt{include_noloot} // 0;


    my $proc_chance_pct = $opt{proc_chance_pct} // 5.0;
    my $min_loot_chance = $opt{min_loot_chance} // 25.0;
	my $max_loot_chance = $opt{max_loot_chance};
    return if $level < $min_level || $level > $max_level;

	# Skip NPCs with no base loottable unless explicitly allowed
	if (!$include_noloot) {
		my $ltid = int(eval { $npc->GetLoottableID() } || 0);
		if ($ltid <= 0) {
			quest::shout("[EraGlobalLoot] SKIP NO LOOTTABLE: $npc_name") if $debug;
			return;
		}
	}
        # Named/Raid gate (OR when both flags set)
    my $is_named = _egl_is_named_db($npc_id) ? 1 : 0;  # npc_types.rare_spawn
    my $is_raid  = _egl_is_raid_db($npc_id)  ? 1 : 0;  # npc_types.raid_target

    # If BOTH enabled: allow named OR raid
    if ($named_only && $raid_target_only) {
        if (!($is_named || $is_raid)) {
            quest::shout("[EraGlobalLoot] NOT NAMED_OR_RAID: $npc_name") if $debug;
            return;
        }
    }
    # Only named
    elsif ($named_only) {
        if (!$is_named) {
            quest::shout("[EraGlobalLoot] NOT RARE_SPAWN: $npc_name") if $debug;
            return;
        }
    }
    # Only raid
    elsif ($raid_target_only) {
        if (!$is_raid) {
            quest::shout("[EraGlobalLoot] NOT RAID_TARGET: $npc_name") if $debug;
            return;
        }
    }

    my ($zonesn, $version) = _egl_zoneinfo_live($npc);

    if ($debug) {
        quest::shout(
            "[EraGlobalLoot] zone="
            . ($zonesn // 'UNKNOWN')
            . " version="
            . (defined $version ? $version : 'NULL')
        );
    }

    my $era = _egl_era_from_zone($zonesn);
    return unless $era;

    my $bl_versions = $opt{blacklist_any_versions} // [];
	my $pool = _egl_era_pool($era, $min_loot_chance, $max_loot_chance, $bl_versions);
    return unless $pool && @$pool;

    if ($proc_chance_pct > 0 && rand(100) > $proc_chance_pct) {
        return;
    }

    my $added = 0;
    while ($added < $rolls_cap) {
        my $pick = _egl_pick_weighted($pool);
        last unless $pick;

        quest::addloot($pick->{item_id}, 1);
        $added++;
    }
}

1;