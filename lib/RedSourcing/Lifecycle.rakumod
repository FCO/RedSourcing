unit module RedSourcing::Lifecycle;
use nqp;
use RedSourcing::Journal;
use RedSourcing::Context;

enum EntityLifecycle is export <OnDemand Retained>;

my %retained;
my %configuration;
my %used;
my %snapshot-defaults;
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

sub lifecycle-settings(%entries --> Hash) is export {
    my %normalized;
    for %entries.kv -> $name, $settings {
        die "Entity settings for '$name' accept only retained, lifecycle and auto-snapshot"
            unless $settings ~~ Associative && $settings.elems
                && !$settings.keys.grep({ $_ ne any(<retained lifecycle auto-snapshot>) });
        my %entry;
        die "Choose retained or lifecycle for '$name', not both"
            if ($settings<retained>:exists) && ($settings<lifecycle>:exists);
        if $settings<retained>:exists {
            die "retained must be a Bool for '$name'" unless $settings<retained> ~~ Bool;
            %entry<lifecycle> = $settings<retained> ?? Retained !! OnDemand;
        }
        if $settings<lifecycle>:exists {
            my $value = $settings<lifecycle>;
            die "Unknown entity lifecycle '$value' for '$name': expected OnDemand or Retained"
                unless $value.defined && $value.Str eq any(<OnDemand Retained>);
            %entry<lifecycle> = $value.Str eq 'Retained' ?? Retained !! OnDemand;
        }
        %entry<auto-snapshot> = snapshot-policy($settings<auto-snapshot>)
            if $settings<auto-snapshot>:exists;
        %normalized{$name} = %entry;
    }
    %normalized
}

sub configure-lifecycles(%entries, :$auto-snapshot = default-auto-snapshot()) is export {
    assert-effect-allowed('entity lifecycle configuration');
    my %normalized = lifecycle-settings(%entries);
    my $policy = snapshot-policy($auto-snapshot);
    my $store = journal-store();
    $cache-lock.protect({
        for (%used{$store} // {}).kv -> $name, %entry {
            my $next = %normalized{$name}<lifecycle> // %entry<declared>;
            die "Entity lifecycle must be configured before first use: $name"
                if $next != %entry<effective>;
            my $snapshot = (%normalized{$name}<auto-snapshot>:exists)
                ?? %normalized{$name}<auto-snapshot>
                !! %entry<snapshot-explicit> ?? %entry<snapshot-declared> !! $policy;
            die "Auto snapshot must be configured before first use: $name"
                unless $snapshot eqv %entry<snapshot-effective>;
        }
        %configuration{$store} = %normalized;
        %snapshot-defaults{$store} = $policy;
    });
}

sub effective-lifecycle(Mu:U $type, EntityLifecycle $declared --> EntityLifecycle) is export {
    my $store = try journal-store();
    return $declared unless $store.defined;
    $cache-lock.protect({ %configuration{$store}{$type.^name}<lifecycle> // $declared })
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
    $cache-lock.protect({
        %used{$store}{$type.^name} //= {
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
    $cache-lock.protect({ %retained{$store}{entity-key($type, $stream)}:delete });
}

sub entity-working($entity) is export {
    my $type = $entity.WHAT;
    my $key = entity-key($type, $entity.^stream);
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
    return work($entity) unless $entity.^lifecycle == Retained;
    my $owner = retained-owner($entity);
    return work($entity) unless $owner.defined && $owner === $entity;
    my $working = ((try $*RED-TRANSACTION-RUNNING) // False)
        ?? entity-working($entity) !! fresh-copy($entity);
    $working.^replay;
    work($working)
}
