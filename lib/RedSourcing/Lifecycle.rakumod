unit module RedSourcing::Lifecycle;
use nqp;
use RedSourcing::Journal;
use RedSourcing::Context;
use RedSourcing::Storage;

enum EntityLifecycle is export <OnDemand Retained Cached>;

my %retained;
my %configuration;
my %used;
my %snapshot-defaults;
my %cached;
my %cache-limits;
my %cache-epochs;
my Int $cache-clock = 0;
my $cache-lock = Lock.new;

sub default-auto-snapshot() is export { Map.new(count => 100) }

sub snapshot-policy($value) is export {
    return Map if !$value.defined || ($value ~~ Bool && !$value);
    die 'auto-snapshot must be Nil, False or a nonempty policy with count/seconds'
        unless $value ~~ Associative && $value.elems
            && !$value.keys.grep({ $_ ne any(<count seconds>) });
    if $value<count>:exists {
        die 'count must be a positive integer'
            unless $value<count> ~~ Int && $value<count> !~~ Bool && $value<count> > 0;
    }
    if $value<seconds>:exists {
        die 'seconds must be a positive finite number'
            unless $value<seconds> ~~ Real && $value<seconds> !~~ Bool
                && 0 < $value<seconds> < Inf;
    }
    Map.new($value.pairs)
}

sub cache-capacity($value --> Int) is export {
    die 'cache size must be a nonnegative integer'
        unless $value ~~ Int && $value !~~ Bool && $value >= 0;
    $value
}

sub lifecycle-options(%settings --> Hash) is export {
    die 'Entity lifecycle options accept only retained, cached, lifecycle and auto-snapshot'
        if %settings.keys.grep({ $_ ne any(<retained cached lifecycle auto-snapshot>) });
    die 'Choose only one of retained, cached or lifecycle'
        if <retained cached lifecycle>.grep({ %settings{$_}:exists }).elems > 1;
    my %entry;
    if %settings<cached>:exists {
        my $value = %settings<cached>;
        %entry<lifecycle> = $value ~~ Bool && !$value ?? OnDemand !! Cached;
        %entry<cache-size> = $value ~~ Bool ?? 100 !! cache-capacity($value);
    }
    if %settings<retained>:exists {
        die 'retained must be a Bool' unless %settings<retained> ~~ Bool;
        %entry<lifecycle> = %settings<retained> ?? Retained !! OnDemand;
    }
    if %settings<lifecycle>:exists {
        my $value = %settings<lifecycle>;
        die "Unknown entity lifecycle '$value': expected OnDemand, Retained or Cached"
            unless $value.defined && $value.Str eq any(<OnDemand Retained Cached>);
        %entry<lifecycle> = { OnDemand => OnDemand, Retained => Retained, Cached => Cached }{$value.Str};
    }
    %entry<auto-snapshot> = snapshot-policy(%settings<auto-snapshot>)
        if %settings<auto-snapshot>:exists;
    %entry
}

sub lifecycle-settings(%entries --> Hash) is export {
    my %normalized;
    for %entries.kv -> $name, $settings {
        die "Entity settings for '$name' must be a nonempty map"
            unless $settings ~~ Associative && $settings.elems;
        %normalized{$name} = lifecycle-options($settings.Hash);
    }
    %normalized
}

sub configure-lifecycles(%entries, :$auto-snapshot = default-auto-snapshot(), :$entity-cache-size = 100) is export {
    assert-effect-allowed('entity lifecycle configuration');
    my %normalized = lifecycle-settings(%entries);
    my $policy = snapshot-policy($auto-snapshot);
    my $limit = cache-capacity($entity-cache-size);
    my $store = journal-store();
    $cache-lock.protect({
        die "Entity cache size must be configured before first use"
            if (%used{$store} // {}).values.grep(*<effective> == Cached).elems
                && $limit != (%cache-limits{$store} // 100);
        for (%used{$store} // {}).kv -> $name, %entry {
            my $next = %normalized{$name}<lifecycle> // %entry<declared>;
            die "Entity lifecycle must be configured before first use: $name"
                if $next != %entry<effective>;
            my $size = %normalized{$name}<cache-size> // %entry<cache-declared>;
            die "Entity cache size must be configured before first use: $name"
                if $size != %entry<cache-effective>;
            my $snapshot = (%normalized{$name}<auto-snapshot>:exists)
                ?? %normalized{$name}<auto-snapshot>
                !! %entry<snapshot-explicit> ?? %entry<snapshot-declared> !! $policy;
            die "Auto snapshot must be configured before first use: $name"
                unless $snapshot eqv %entry<snapshot-effective>;
        }
        %configuration{$store} = %normalized;
        %snapshot-defaults{$store} = $policy;
        %cache-limits{$store} = $limit;
    });
}

sub effective-lifecycle(Mu:U $type, EntityLifecycle $declared --> EntityLifecycle) is export {
    my $store = try journal-store();
    return $declared unless $store.defined;
    $cache-lock.protect({ %configuration{$store}{$type.^name}<lifecycle> // $declared })
}

sub effective-cache-size(Mu:U $type, Int $declared --> Int) is export {
    my $store = try journal-store();
    return $declared unless $store.defined;
    $cache-lock.protect({ %configuration{$store}{$type.^name}<cache-size> // $declared })
}

sub effective-auto-snapshot(Mu:U $type, $declared, Bool $explicit) is export {
    my $store = try journal-store();
    return $explicit ?? $declared !! default-auto-snapshot() unless $store.defined;
    $cache-lock.protect({
        (%configuration{$store}{$type.^name}<auto-snapshot>:exists)
            ?? %configuration{$store}{$type.^name}<auto-snapshot>
            !! $explicit ?? $declared
            !! (%snapshot-defaults{$store}:exists) ?? %snapshot-defaults{$store} !! default-auto-snapshot()
    })
}

sub mark-entity-used(Mu:U $type) is export {
    my $store = journal-store();
    my $declared = $type.^lifecycle(:declared);
    my $snapshot-declared = snapshot-policy($type.^auto-snapshot(:declared));
    my $snapshot-explicit = $type.^auto-snapshot(:explicit);
    my $cache-declared = $type.^cache-size(:declared);
    $cache-lock.protect({
        %used{$store}{$type.^name} //= {
            :$cache-declared, cache-effective => %configuration{$store}{$type.^name}<cache-size> // $cache-declared,
            :$declared, effective => %configuration{$store}{$type.^name}<lifecycle> // $declared,
            :$snapshot-declared, :$snapshot-explicit,
            snapshot-effective => (%configuration{$store}{$type.^name}<auto-snapshot>:exists)
                ?? %configuration{$store}{$type.^name}<auto-snapshot>
                !! $snapshot-explicit ?? $snapshot-declared
                !! (%snapshot-defaults{$store}:exists) ?? %snapshot-defaults{$store} !! default-auto-snapshot(),
        };
    });
}

sub entity-key(Mu:U $type, Str $stream --> Str) is export {
    $type.WHICH.Str ~ '|' ~ $stream
}

sub entity-copy($entity) is export {
    my $copy = $entity.Mu::clone;
    for $entity.^attributes -> $attribute {
        assign-attribute($attribute, $copy, copy-value($attribute.get_value($entity)));
    }
    $copy
}

sub copy-value($value) {
    given $value {
        when Hash {
            my $copy = .clone;
            $copy{$_} = copy-value($value{$_}) for .keys;
            $copy
        }
        when Array {
            my $copy = .clone;
            $copy[$_] = copy-value($value[$_]) for .keys;
            $copy
        }
        when Map { Map.new(.pairs.map({ .key => copy-value(.value) })) }
        default { $_ }
    }
}

sub entity-adopt($target, $source) is export {
    for $source.^attributes -> $attribute {
        assign-attribute($attribute, $target, copy-value($attribute.get_value($source)));
    }
    $target
}

sub adopt-committed($target, $source) {
    # Commit releases the database lock before publication. Another executor
    # can publish a later version first; never move the cache backwards.
    $cache-lock.protect({
        entity-adopt($target, $source)
            if $source.^version > $target.^version
                || ($source.^version == $target.^version && $source.^current-id >= $target.^current-id);
    });
}

sub assign-attribute($attribute, $target, $value) {
    if $attribute.type.^name eq any(<int num str uint int8 int16 int32 uint8 uint16 uint32 num32>) {
        $attribute.set_value($target, $value);
    } elsif $attribute.name.starts-with('$') {
        $attribute.get_value($target) = $value;
    } else {
        # @/% containers are shared by Mu.clone. Replace, rather than assign
        # into, the container so an aborted working copy cannot mutate its owner.
        nqp::bindattr(nqp::decont($target), $attribute.package, $attribute.name, nqp::decont($value));
    }
}

# One bounded pool per journal store. The global epoch invalidates pending cold
# admissions after release/eviction without keeping an unbounded tombstone map.
sub remove-cached(Str $store, Str $key) {
    my $entry = %cached{$store}{$key}:delete;
    %cache-epochs{$store} = (%cache-epochs{$store} // 0) + 1;
    return Nil unless $entry.defined;
    if ($entry<active> // 0) > 0 {
        $entry<pending-snapshot> = True;
        return Nil;
    }
    $entry<entity>;
}

sub publish-cached(Str $store, Str $key, $entity, $entry, Int $epoch, Int $size, Int $access = 0, :$decision) {
    my @evicted;
    $cache-lock.protect({
        my $current = %cached{$store}{$key};
        return if $entry.defined && !($current.defined && $current === $entry);
        if $current.defined {
            $current<access> max= $access;
            my $owner = $current<entity>;
            if $entity.^version > $owner.^version
                    || ($entity.^version == $owner.^version && $entity.^current-id >= $owner.^current-id) {
                entity-adopt($owner, $entity);
                $decision.defined ?? ($current<decision> = $decision) !! ($current<decision>:delete);
            }
            return;
        }
        return if $epoch != (%cache-epochs{$store} // 0);
        my $limit = %cache-limits{$store} // 100;
        return unless $size && $limit;
        my $stamp = $access || ++$cache-clock;
        my $type = $entity.WHAT;
        my @same = (%cached{$store} // {}).pairs.grep({ .value<type> === $type }).sort(*.value<access>);
        # A late cold-load commit must not evict entities accessed after it.
        return if @same.elems >= $size && @same[0].value<access> > $stamp;
        return if (%cached{$store} // {}).elems >= $limit
            && %cached{$store}.values.min(*<access>)<access> > $stamp;
        @evicted.push(remove-cached($store, @same.shift.key)) while @same.elems >= $size;
        while (%cached{$store} // {}).elems >= $limit {
            my $oldest = %cached{$store}.pairs.min(*.value<access>).key;
            @evicted.push(remove-cached($store, $oldest));
        }
        %cached{$store}{$key} = { :$type, :$entity, access => $stamp };
        %cached{$store}{$key}<decision> = $decision if $decision.defined;
    });
    snapshot-evicted($_) for @evicted;
}

sub cached-copy($entity) {
    my $type = $entity.WHAT;
    my $copy = $cache-lock.protect({ entity-copy($entity) });
    my $version = storage-checkpoint-version($type.^name, $copy.^stream);
    return $type.^restore(:stream($copy.^stream), |$copy.^entity-id-map)
        if $version > $copy.^version;
    $copy
}

# Eviction is a memory optimization. Checkpointing must never fail an operation
# whose physical commit has already succeeded, or read/write through its old guard.
sub snapshot-evicted($entity, Bool :$refresh = False) {
    return unless $entity.defined && ($refresh || $entity.^snapshot-events) && $entity.^auto-snapshot.defined;
    return if ((try $*REDSOURCING-PHASE) // '') eq any(<APPLY REACT>);
    my $committed = try $*REDSOURCING-COMMITTED-DRIVER;
    if ((try $*RED-TRANSACTION-RUNNING) // False) && !$committed.defined {
        journal-publish('eviction-snapshot|' ~ entity-key($entity.WHAT, $entity.^stream), {
            snapshot-evicted($entity, :$refresh)
        });
        return;
    }
    my $driver = $committed // journal-connection();
    my $storage = $driver.journal-storage;
    try {
        # Pg's committing native driver owns a finished session; start the new
        # transaction from its pool. SQLite keeps the same unscoped native driver.
        my $pool = try $driver.?dbh.?dbpg;
        $driver = $driver.new-connection($pool) if $pool.defined;
        my $*RED-DB = $driver;
        my $*RED-TRANSACTION-RUNNING = False;
        my $*RED-TRANSACTION-DB = $driver;
        my $*REDSOURCING-EVICTION-SNAPSHOT = True;
        journal-do {
            my $fresh = cached-copy($entity);
            $fresh.^replay;
            $fresh.^emit-snapshot if $fresh.^snapshot-events;
        };
        CATCH {
            default {
                $cache-lock.protect({
                    $storage<eviction-snapshot-failures> = ($storage<eviction-snapshot-failures> // 0) + 1;
                    $storage<eviction-snapshot-error> = .message;
                });
            }
        }
    }
}

sub cache-enabled(Mu:U $type) {
    return False if (try $*REDSOURCING-EVICTION-SNAPSHOT) // False;
    return False if $type.HOW.^can('projection-descriptor')
        && !$type.^projection-descriptor<instance-cacheable>;
    my $store = journal-store();
    my $size = $type.^cache-size;
    $cache-lock.protect({ $size && (%cache-limits{$store} // 100) })
}

# Decision bases are detached from both public cache references and user blocks.
# They share the ordinary bounded pool, release/epoch rules and commit hooks.
sub decision-cache-read(Mu:U $type, Str $stream) is export {
    return Nil unless $type.^lifecycle == Cached && cache-enabled($type);
    my $store = journal-store();
    $cache-lock.protect({
        my $entry = %cached{$store}{entity-key($type, $stream)};
        return Nil unless $entry.defined && $entry<decision>.defined;
        $entry<access> = ++$cache-clock;
        %(entity => entity-copy($entry<decision><entity>),
            versions => $entry<decision><versions>.Hash.clone)
    })
}

sub decision-cache-stage($entity, %versions) is export {
    my $type = $entity.WHAT;
    return unless $type.^lifecycle == Cached && cache-enabled($type);
    $type.^use-lifecycle;
    # Tiny reconstructions cost less than copying and admitting their state.
    # Avoid filling the shared pool with one-off views and evicting useful owners.
    return if $entity.^snapshot-events < 4;
    # entity-copy detaches JSON-shaped containers, not arbitrary domain objects.
    # Keep reconstruction semantics for state that cannot be safely detached.
    my %seen;
    return unless $type.^attributes.map({ decision-copyable(.get_value($entity), %seen) }).all;
    my $store = journal-store();
    my $key = entity-key($type, $entity.^stream);
    my ($entry, $epoch, $access);
    $cache-lock.protect({
        $entry = %cached{$store}{$key};
        $epoch = %cache-epochs{$store} // 0;
        $access = ++$cache-clock;
    });
    my $copy = entity-copy($entity);
    my $decision = %(entity => entity-copy($copy), versions => %versions.Hash.clone);
    my $size = $type.^cache-size;
    journal-publish('decision|' ~ $key, {
        publish-cached($store, $key, $copy, $entry, $epoch, $size, $access, :$decision)
    });
}

sub decision-copyable($value, %seen --> Bool) {
    return True unless $value.defined;
    return True if $value ~~ Str|Bool|Int|Rat|FatRat|Num|Complex|Date|DateTime|Instant|Version;
    if $value ~~ Hash|Array|Map {
        return False if %seen{$value.WHICH.Str}++;
        return $value.values.map({ decision-copyable($_, %seen) }).all.so;
    }
    False
}

sub cached-load(Mu:U $type, Str $stream, &load, Bool :$replay = True) is export {
    my $store = journal-store();
    my $key = entity-key($type, $stream);
    my $size = $type.^cache-size;
    my $enabled = cache-enabled($type);
    return load() unless $enabled;
    unless (try $*RED-TRANSACTION-RUNNING) // False {
        my $working = journal-do { cached-load($type, $stream, &load, :$replay) };
        return $cache-lock.protect({ %cached{$store}{$key}<entity> // $working });
    }
    my $working = journal-connection().journal-state<working>{$key};
    if $working.defined {
        $working.^replay if $replay;
        return $working;
    }
    my $epoch;
    my $access;
    my $entry = $cache-lock.protect({
        $epoch = %cache-epochs{$store} // 0;
        my $found = %cached{$store}{$key};
        $access = ++$cache-clock;
        $found<access> = $access if $found.defined;
        $found
    });
    $working = journal-working($key, {
        if $entry.defined {
            my $copy = cached-copy($entry<entity>);
            $copy.^replay if $replay;
            $copy
        } else { load() }
    });
    journal-publish('cached|' ~ $key, {
        publish-cached($store, $key, $working, $entry, $epoch, $size, $access)
    });
    $working
}

sub retained-load(Mu:U $type, Str $stream, &load) is export {
    my $store = journal-store();
    my $key = entity-key($type, $stream);
    my $existing = $cache-lock.protect({ %retained{$store}{$key} });
    my $transaction = (try $*RED-TRANSACTION-RUNNING) // False;
    return $transaction ?? entity-working($existing) !! $existing if $existing.defined;
    # Do not register or expose an object before its loading transaction commits.
    my $entity = $transaction ?? journal-working($key, &load) !! load();
    if $transaction {
        journal-connection().journal-state<retained>{$key} = $entity;
        journal-publish('retain|' ~ $key, {
            $cache-lock.protect({ %retained{$store}{$key} //= $entity });
        });
    } else {
        $entity = $cache-lock.protect({ %retained{$store}{$key} //= $entity });
    }
    $entity
}

sub release-entity(Mu:U $type, Str $stream) is export {
    my $store = journal-store();
    my $evicted = $cache-lock.protect({
        my $key = entity-key($type, $stream);
        %retained{$store}{$key}:delete;
        remove-cached($store, $key)
    });
    snapshot-evicted($evicted);
}

sub entity-working($entity, Bool :$replay = True) is export {
    my $type = $entity.WHAT;
    my $key = entity-key($type, $entity.^stream);
    if $type.^lifecycle == Cached && cache-enabled($type) {
        return cached-load($type, $entity.^stream, {
            my $copy = cached-copy($entity);
            $copy.^replay if $replay;
            $copy
        }, :$replay);
    }
    my $working = journal-working($key, {
        # A checkpoint written by another process supersedes the local cache.
        $type.^lifecycle == Retained ?? fresh-copy($entity) !! entity-copy($entity)
    });
    journal-publish('state|' ~ $key, { adopt-committed($entity, $working) })
        unless $entity === $working;
    $working
}


sub retained-instances(Mu:U $type) is export {
    my $store = journal-store();
    my @instances = $cache-lock.protect({ (%retained{$store} // {}).values.grep({ .WHAT === $type }).Array });
    @instances.append(journal-connection().journal-state<retained>.values.grep({ .WHAT === $type }));
    @instances
}

sub retained-owner($entity) {
    my $store = journal-store();
    $cache-lock.protect({ %retained{$store}{entity-key($entity.WHAT, $entity.^stream)} })
}

sub fresh-copy($entity) {
    my $fresh = $entity.WHAT.^restore(:stream($entity.^stream), |$entity.^entity-id-map);
    $fresh.defined && $fresh.^version > $entity.^version ?? $fresh !! entity-copy($entity)
}

sub publish-entity($entity) is export {
    if $entity.^lifecycle == Cached {
        my $store = journal-store();
        my $key = entity-key($entity.WHAT, $entity.^stream);
        my $entry = $cache-lock.protect({ %cached{$store}{$key} });
        return unless $entry.defined;
        my $size = $entity.^cache-size;
        journal-publish('cached|' ~ $key, { publish-cached($store, $key, $entity, $entry, 0, $size) });
        return;
    }
    return unless $entity.^lifecycle == Retained;
    my $owner = retained-owner($entity);
    if $owner.defined && !($owner === $entity) {
        journal-publish('state|' ~ entity-key($entity.WHAT, $entity.^stream), {
            adopt-committed($owner, $entity)
        });
    }
}

# Saga operations retain their existing transaction boundaries: services execute
# after the durable claim, while each committed control publishes its own state.
sub entity-operation($entity, &work) is export {
    $entity.^use-lifecycle;
    if $entity.^lifecycle == Cached {
        return work($entity) unless cache-enabled($entity.WHAT);
        my $store = journal-store();
        my $key = entity-key($entity.WHAT, $entity.^stream);
        my $entry = $cache-lock.protect({
            my $found = %cached{$store}{$key};
            if $found.defined {
                $found<active> = ($found<active> // 0) + 1;
                $found<access> = ++$cache-clock;
            }
            $found
        });
        LEAVE {
            if $entry.defined {
                my $snapshot = $cache-lock.protect({
                    $entry<active>--;
                    my $pending = !$entry<active> && $entry<pending-snapshot>;
                    $entry<pending-snapshot> = False if $pending;
                    $pending
                });
                snapshot-evicted($entry<entity>, :refresh) if $snapshot;
            }
        }
        my $owner = $entry.defined ?? $entry<entity> !! Nil;
        # Detached restores, newly created objects and transaction working copies
        # already own their state. Only a shared cache owner needs detaching.
        unless $owner.defined && $owner === $entity {
            my $transaction = (try $*RED-TRANSACTION-RUNNING) // False;
            my $working = $transaction ?? journal-connection().journal-state<working>{$key} !! Nil;
            # An evicted reference can cross a checkpoint containing state that
            # has no domain fact. Refresh that state before replay skips the row.
            if $entity.^version && !($working.defined && $working === $entity)
                    && storage-checkpoint-version($entity.^name, $entity.^stream) > $entity.^version {
                my $fresh = $entity.WHAT.^restore(:stream($entity.^stream), |$entity.^entity-id-map);
                $fresh.^replay;
                entity-adopt($entity, $fresh);
            }
            return work($entity);
        }
        my $working = ((try $*RED-TRANSACTION-RUNNING) // False)
            ?? entity-working($entity) !! do { my $copy = cached-copy($entity); $copy.^replay; $copy };
        my $result = work($working);
        unless (try $*RED-TRANSACTION-RUNNING) // False {
            return $owner if $result === $working
                && $cache-lock.protect({ %cached{$store}{$key}.defined && %cached{$store}{$key} === $entry });
        }
        return $result;
    }
    return work($entity) unless $entity.^lifecycle == Retained;
    my $owner = retained-owner($entity);
    return work($entity) unless $owner.defined && $owner === $entity;
    my $working = ((try $*RED-TRANSACTION-RUNNING) // False)
        ?? entity-working($entity) !! fresh-copy($entity);
    $working.^replay;
    work($working)
}
