package plugin;


use DBI;

# ==========================================================
# Era Global Rare Loot Plugin
#
#  - Builds an era-wide loot pool from existing zone loot.
#  - All "rare" items from any Classic zone can drop from
#    any NPC in Classic zones, etc.
#
# Usage from global_npc.pl:
#
#   sub EVENT_SPAWN {
#       plugin::era_global_rare_loot_on_spawn(
#           min_level       => 10,    # only affect mobs 10+
#           max_level       => 255,
#           named_only      => 1,     # only named mobs (heuristic)
#           min_loot_chance => 20.0,  # only include items with >= 20% base chance
#           proc_chance_pct => 3.0,   # % chance per spawn to even try for rare
#           rolls           => 1,     # max rares per spawn
#           debug           => 0      # set 1 while testing
#       );
#   }
#
# Env config (same pattern as other plugins):
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, DBI_EXTRA
# ==========================================================

our $EGL_DBH;
our $EGL_DB_HOST = $ENV{DB_HOST}     // '127.0.0.1';
our $EGL_DB_PORT = $ENV{DB_PORT}     // 3306;
our $EGL_DB_NAME = $ENV{DB_NAME}     // 'peq';
our $EGL_DB_USER = $ENV{DB_USER}     // 'eqemu';
our $EGL_DB_PASS = $ENV{DB_PASSWORD} // '';
our $EGL_DBI_EXTRA = $ENV{DBI_EXTRA} // 'mysql_enable_utf8=1';

# Caches
our %EGL_ZONE_ERA_CACHE;   # zonesn -> era
our %EGL_ERA_POOL_CACHE;   # "era:min" -> [ { item_id, chance }, ... ]

# ----------------------------------------------------------
# Internal: DB handle
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
    if (!$ok || !$EGL_DBH) {
        quest::debug("era_global_rare_loot: DB connect failed: $@") if $@;
        return;
    }
    return $EGL_DBH;
}

# ----------------------------------------------------------
# Internal: crude "named" heuristic (you can replace)
# ----------------------------------------------------------
sub _egl_is_named {
    my ($npc) = @_;
    return 0 if !$npc;
    my $name = $npc->GetName() // '';

    # Has a space: often named
    return 1 if $name =~ /\s/;

    # Capitalized but not ALLCAPS
    return 1 if $name =~ /^[A-Z][a-z]+/ && $name !~ /^[A-Z_]+$/;

    return 0;
}

# ----------------------------------------------------------
# Internal: zonesn for this NPC (via spawn2.id)
# ----------------------------------------------------------
sub _egl_zonesn_for_npc {
    my ($npc) = @_;
    my $dbh = _egl_dbh() or return;

    my $spawn2_id = eval { $npc->GetSpawnPointID() } || 0;
    return unless $spawn2_id;

    my $zonesn;
    eval {
        my $sth = $dbh->prepare("SELECT zone FROM spawn2 WHERE id = ? LIMIT 1");
        $sth->execute($spawn2_id);
        ($zonesn) = $sth->fetchrow_array();
        $sth->finish;
    };
    if ($@) {
        quest::debug("era_global_rare_loot: zonesn query failed: $@");
        return;
    }
    return $zonesn || undef;
}

# ----------------------------------------------------------
# Internal: era from zonesn via zone_era
# ----------------------------------------------------------
sub _egl_era_from_zone {
    my ($zonesn) = @_;
    return unless $zonesn;

    if (exists $EGL_ZONE_ERA_CACHE{$zonesn}) {
        return $EGL_ZONE_ERA_CACHE{$zonesn};
    }

    my $dbh = _egl_dbh() or return;
    my $era;

    eval {
        my $sth = $dbh->prepare(
            "SELECT era FROM zone_era WHERE zone_short = ? LIMIT 1"
        );
        $sth->execute($zonesn);
        ($era) = $sth->fetchrow_array();
        $sth->finish;
    };
    if ($@) {
        quest::debug("era_global_rare_loot: zone_era query failed: $@");
        return;
    }

    $EGL_ZONE_ERA_CACHE{$zonesn} = $era if defined $era;
    return $era;
}

# ----------------------------------------------------------
# Internal: era-global loot pool (all zones in that era)
# ----------------------------------------------------------
# ----------------------------------------------------------
# Internal: era-global loot pool (all zones in that era)
#   Only items that:
#     - are equipable (i.slots != 0)
#     - have real stats (HP/Mana/Endur or hero stats)
# ----------------------------------------------------------
sub _egl_era_pool {
    my ($era, $min_chance) = @_;
    $min_chance //= 0;

    return [] unless $era;

    my $key = join(":", $era, $min_chance, "realstats");
    if (exists $EGL_ERA_POOL_CACHE{$key}) {
        return $EGL_ERA_POOL_CACHE{$key};
    }

    my $dbh = _egl_dbh() or do {
        $EGL_ERA_POOL_CACHE{$key} = [];
        return $EGL_ERA_POOL_CACHE{$key};
    };

    my $sql = qq{
        SELECT DISTINCT
            ld.item_id,
            ld.chance
        FROM npc_types          AS n
        JOIN loottable_entries  AS lt  ON lt.loottable_id = n.loottable_id
        JOIN lootdrop_entries   AS ld  ON ld.lootdrop_id  = lt.lootdrop_id
        JOIN items              AS i   ON i.id            = ld.item_id
        JOIN spawnentry         AS se  ON se.npcID        = n.id
        JOIN spawn2             AS s2  ON s2.spawngroupID = se.spawngroupID
        JOIN zone_era           AS ze  ON ze.zone_short   = s2.zone
        WHERE ze.era    = ?
          AND ld.chance >= ?
          -- must be equipable
          AND i.slots != 0
          -- MUST have real stats: hp/mana/end or hero stats.
          -- (AC alone does NOT count as stats here)
          AND (
                i.hp   > 0 OR
                i.mana > 0 OR
                i.endur > 0 OR
                i.astr  > 0 OR
                i.asta  > 0 OR
                i.adex  > 0 OR
                i.aagi  > 0 OR
                i.aint  > 0 OR
                i.awis  > 0 OR
                i.acha  > 0
          )
    };

    my $rows = [];
    eval {
        my $sth = $dbh->prepare($sql);
        $sth->execute($era, $min_chance);
        while (my $r = $sth->fetchrow_hashref) {
            push @$rows, $r;
        }
        $sth->finish;
    };
    if ($@) {
        quest::debug("era_global_rare_loot: era pool query failed: $@");
    }

    $EGL_ERA_POOL_CACHE{$key} = $rows;
    return $rows;
}


# ----------------------------------------------------------
# Internal: weighted random pick by 'chance'
# ----------------------------------------------------------
sub _egl_pick_weighted {
    my ($rows, $chance_col) = @_;
    $chance_col //= 'chance';
    return undef unless $rows && @$rows;

    my $total = 0;
    for my $r (@$rows) {
        my $w = $r->{$chance_col} || 0;
        $total += $w if $w > 0;
    }
    return undef if $total <= 0;

    my $roll = rand($total);
    my $acc  = 0;
    for my $r (@$rows) {
        my $w = $r->{$chance_col} || 0;
        next if $w <= 0;
        $acc += $w;
        return $r if $roll <= $acc;
    }

    return $rows->[-1]; # fallback
}

# ----------------------------------------------------------
# Internal: should we even consider this NPC for era loot?
# ----------------------------------------------------------
sub _egl_is_valid_target {
    my ($npc, $opt) = @_;
    $opt ||= {};

    return 0 if !$npc;

    my $include_merchants  = $opt->{include_merchants}  // 0;
    my $include_bankers    = $opt->{include_bankers}    // 0;
    my $include_gmasters   = $opt->{include_guildmasters} // 0;
    my $include_adv        = $opt->{include_adv_merchants} // 0;
    my $include_tribute    = $opt->{include_tribute} // 0;
    my $include_mounts     = $opt->{include_mounts}   // 0;
    my $include_triggers   = $opt->{include_triggers} // 0;
    my $include_noloot     = $opt->{include_noloot}   // 0;

    # Pets / Owned NPC
    return 0 if $npc->IsPet();
    return 0 if $npc->GetOwnerID() != 0;

    # Merchant / Banker / Guildmaster checks (no IsMerchant in older builds)
    my $npc_class = $npc->GetClass();

    return 0 if !$include_merchants  && $npc_class == 41;  # Merchant
    return 0 if !$include_bankers    && $npc_class == 40;  # Banker
    return 0 if !$include_gmasters   && $npc_class == 20;  # Guildmaster
    return 0 if !$include_adv        && $npc_class == 61;  # Adv Merchant
    return 0 if !$include_tribute    && $npc_class == 63;  # Tribute

    # Skip invisible men / triggers
    my $race = $npc->GetRace();
    return 0 if !$include_triggers && defined $race && $race == 127;

    # Mounts: some servers use horse bodytype 11, others rely on name
    my $body = $npc->GetBodyType();
    return 0 if !$include_mounts && ($body == 11 || $npc->IsHorse());

    # Skip NPCs with no loottable
    my $ltid = $npc->GetLoottableID() || 0;
    return 0 if !$include_noloot && $ltid == 0;

    return 1;
}


# ----------------------------------------------------------
# Public: call from EVENT_SPAWN
# ----------------------------------------------------------
sub era_global_rare_loot_on_spawn {
    my (%opt) = @_;

    my $npc = plugin::val('npc');
    return unless $npc;

    my $level      = $npc->GetLevel();
    my $min_level  = defined $opt{min_level} ? $opt{min_level} : 1;
    my $max_level  = defined $opt{max_level} ? $opt{max_level} : 255;
    my $named_only = $opt{named_only}       // 0;
    my $rolls_cap  = $opt{rolls}            // 1;
    my $debug      = $opt{debug}            // 0;

    my $proc_chance_pct = $opt{proc_chance_pct} // 5.0;
    my $min_loot_chance = $opt{min_loot_chance} // 25.0;
    my $era_override    = $opt{era};  # optional manual override

    my $npc_name = $npc->GetName();
    my $npc_id   = $npc->GetNPCTypeID();

    # First: filter out non-combat / utility NPCs
    my %target_flags = (
        include_merchants    => $opt{include_merchants},
        include_bankers      => $opt{include_bankers},
        include_trainers     => $opt{include_trainers},
        include_guildmasters => $opt{include_guildmasters},
        include_mounts       => $opt{include_mounts},
        include_triggers     => $opt{include_triggers},
        include_noloot       => $opt{include_noloot},
    );

    unless (_egl_is_valid_target($npc, \%target_flags)) {
        quest::shout("[EraGlobalLoot] SKIP non-combat NPC $npc_name ($npc_id)") if $debug;
        return;
    }

    # Early debug so we KNOW the plugin ran
    if ($debug) {
        quest::shout(
            sprintf(
                "[EraGlobalLoot] CALLED for %s (%d) level %d",
                $npc_name, $npc_id, $level
            )
        );
    }

    # Level gate
    if ($level < $min_level || $level > $max_level) {
        quest::shout("[EraGlobalLoot] LEVEL GATE: $level outside $min_level-$max_level") if $debug;
        return;
    }

    # Named-only gate
    if ($named_only && !_egl_is_named($npc)) {
        quest::shout("[EraGlobalLoot] NAMED GATE: '$npc_name' not considered named") if $debug;
        return;
    }

    # % chance to even attempt rare on this spawn
    if ($proc_chance_pct > 0) {
        my $r = rand(100);
        if ($r > $proc_chance_pct) {
            quest::shout("[EraGlobalLoot] PROC GATE: roll=$r > $proc_chance_pct") if $debug;
            return;
        }
    }

    # Determine zone + era
    my $zonesn = _egl_zonesn_for_npc($npc);
    if ($debug) {
        quest::shout("[EraGlobalLoot] zonesn=" . ($zonesn // 'UNKNOWN'));
    }

    my $era = $era_override || _egl_era_from_zone($zonesn);
    if (!$era) {
        quest::shout("[EraGlobalLoot] ERA LOOKUP FAILED for zonesn=" . ($zonesn // 'UNKNOWN')) if $debug;
        return;
    }

    quest::shout("[EraGlobalLoot] ERA=$era min_loot_chance=$min_loot_chance") if $debug;

    my $pool = _egl_era_pool($era, $min_loot_chance);
    my $pool_count = ($pool && ref($pool) eq 'ARRAY') ? scalar(@$pool) : 0;

    quest::shout("[EraGlobalLoot] POOL SIZE for era=$era = $pool_count") if $debug;
    return unless $pool && @$pool;

    my $added = 0;
    while ($added < $rolls_cap) {
        my $pick = _egl_pick_weighted($pool, 'chance');
        last unless $pick;

        my $item_id = $pick->{item_id};
        my $charges = $pick->{charges} || 1;  # default 1

        quest::addloot($item_id, $charges);
        $added++;

        if ($debug) {
            my $msg = sprintf(
                "[EraGlobalLoot] ADD %s(%d) lvl %d in %s era=%s -> item %d",
                $npc_name, $npc_id, $level,
                ($zonesn // 'unknown'),
                ($era    // 'unknown'),
                $item_id
            );
            quest::shout($msg);
            quest::ze(15, $msg);
        }
    }

    if ($debug && $added == 0) {
        my $msg = sprintf(
            "[EraGlobalLoot] NO RARE for %s(%d) in %s era=%s (pool_size=%d)",
            $npc_name, $npc_id,
            ($zonesn // 'unknown'),
            ($era    // 'unknown'),
            $pool_count
        );
        quest::shout($msg);
        quest::ze(15, $msg);
    }
}

1;
