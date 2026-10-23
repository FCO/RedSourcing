unit module RedSourcing::Journal;
use Red;
use Red::DB;
use RedSourcing::Storage;
use RedSourcing::X::OptimisticLockFailed;
use RedSourcing::Counters;

sub empty-state() {
    { working => {}, publish => {}, retained => {},
        snapshot-candidates => {}, savepoints => [], decisions => [],
        counter-increments => {}, decision-conflict => Nil }
}

# Lifecycle depends on Journal. Resolve its copy helpers only when a savepoint
# actually contains entities, after both modules have finished loading.
sub lifecycle-helper(Str $name --> Callable) {
    require ::('RedSourcing::Lifecycle');
    ::('RedSourcing::Lifecycle::EXPORT::DEFAULT').WHO{$name}
}

sub checkpoint(Hash $state --> Hash) {
    my %maps = <working publish retained snapshot-candidates>.map({
        $_ => ($state{$_} // {}).Hash.clone
    });
    my %objects;
    for <working retained snapshot-candidates> -> $map {
        for %maps{$map}.values -> $entity {
            next if %objects{$entity.WHICH.Str}:exists;
            %objects{$entity.WHICH.Str} = [$entity,
                lifecycle-helper('&entity-copy')($entity)];
        }
    }
    { :%maps, :%objects,
        decisions => $state<decisions>.map(*.clone).Array,
        counter-increments => $state<counter-increments>.clone,
        decision-conflict => $state<decision-conflict> }
}

sub restore-checkpoint(Hash $state, Hash $checkpoint) {
    for $checkpoint<objects>.values -> $pair {
        lifecycle-helper('&entity-adopt')($pair[0], $pair[1]);
    }
    $state{$_} = $checkpoint<maps>{$_}.clone for <working publish retained snapshot-candidates>;
    $state<decisions> = $checkpoint<decisions>.map(*.clone).Array;
    $state<counter-increments> = $checkpoint<counter-increments>.clone;
    $state<decision-conflict> = $checkpoint<decision-conflict>;
}

# Install hooks on the transaction driver, including transactions owned by a
# caller's red-do. A lexical KEEP around an individual emit would publish early.
my role JournalConnection {
    has Str $!journal-store;
    has Hash $!journal-state;
    has Hash $!journal-storage;

    method journal-initialize(Str $store, Hash :$state = empty-state(), Hash :$storage) {
        $!journal-storage = $storage // $!journal-storage // {};
        $!journal-store = $store;
        $!journal-state = $state;
        self
    }
    method journal-store { $!journal-store }
    method journal-state { $!journal-state }
    method journal-storage { $!journal-storage }
    method journal-ensure-counters {
        unless $!journal-storage<counters-ready> {
            initialize-counters();
            $!journal-storage<counters-ready> = True;
        }
    }
    method journal-savepoint(Str $name) {
        $!journal-state<savepoints>.push({ :$name, state => checkpoint($!journal-state) });
    }
    method savepoint(Str $name) {
        my $checkpoint = checkpoint($!journal-state);
        my $result = callsame;
        $!journal-state<savepoints>.push({ :$name, state => $checkpoint });
        $result
    }
    method !savepoint-index(Str $name) {
        $!journal-state<savepoints>.keys.reverse.first({
            $!journal-state<savepoints>[$_]<name> eq $name
        })
    }
    method rollback-to-savepoint(Str $name) {
        my $index = self!savepoint-index($name);
        die "Unknown journal savepoint: $name" unless $index.defined;
        my $result = callsame;
        restore-checkpoint($!journal-state, $!journal-state<savepoints>[$index]<state>);
        $!journal-storage<counters-ready> = False;
        $!journal-state<savepoints>.splice($index + 1);
        $result
    }
    method release-savepoint(Str $name) {
        my $index = self!savepoint-index($name);
        die "Unknown journal savepoint: $name" unless $index.defined;
        my $result = callsame;
        $!journal-state<savepoints>.splice($index);
        $result
    }
    method begin {
        return callsame if self.?transaction-guard.defined;
        my $connection = callsame;
        $connection does JournalConnection unless $connection ~~ JournalConnection;
        $connection.journal-initialize($!journal-store)
    }
    method commit {
        return callsame if self.?transaction-guard.defined;
        $!journal-state<decision-conflict>.throw if $!journal-state<decision-conflict>.defined;
        my @publish = $!journal-state<publish>.values;
        my $result = callsame;
        $!journal-state = empty-state();
        my $*REDSOURCING-COMMITTED-DRIVER = self;
        .() for @publish;
        $result
    }
    method rollback {
        return callsame if self.?transaction-guard.defined;
        # Native rollback hooks may re-enter the journal before this method
        # returns. DDL from the rejected transaction may already be gone then.
        $!journal-storage<counters-ready> = False;
        LEAVE { $!journal-state = empty-state() }
        callsame
    }
}

sub journal-connection() is export {
    my $connection = optimize-storage-driver(get-RED-DB);
    unless $connection ~~ JournalConnection {
        # Red 0.2.7 scopes use cloned drivers. Hooks must also be attached to
        # the native transaction driver, where Guard commits and rolls back.
        my $guard = $connection.?transaction-guard;
        if $guard.defined {
            my &attribute = -> $object, $name {
                $object.^attributes.first(*.name eq $name).get_value($object)
            };
            my $native = attribute($guard.root, '$!driver');
            unless $native ~~ JournalConnection {
                my $handle-attribute = $native.^attributes.first(*.name eq '$!dbh');
                my $handle = $handle-attribute.defined ?? $handle-attribute.get_value($native) !! $native;
                $native does JournalConnection;
                $native.journal-initialize(($handle.?dbpg // $handle).WHICH.Str);
                # These savepoints predate the first journal access and have
                # no provisional journal work to preserve.
                my @names;
                my $scope = $guard;
                while attribute($scope, '$!parent').defined {
                    @names.unshift(attribute($scope, '$!name'));
                    $scope = attribute($scope, '$!parent');
                }
                $native.journal-savepoint($_) for @names;
            }
            $connection does JournalConnection;
            return $connection.journal-initialize($native.journal-store, :state($native.journal-state), :storage($native.journal-storage));
        }
        my $attribute = $connection.^attributes.first(*.name eq '$!dbh');
        my $handle = $attribute.defined ?? $attribute.get_value($connection) !! $connection;
        my $key = ($handle.?dbpg // $handle).WHICH.Str;
        $connection does JournalConnection;
        $connection.journal-initialize($key);
    }
    $connection
}

sub journal-store() is export { journal-connection().journal-store }

# The dynamic condition is supplied by Decision, not inferred by emit.
sub journal-decision-condition() is export {
    my $state = journal-connection().journal-state;
    my %guards;
    for $state<decisions>.grep({ !.<validated> }) -> %decision {
        for %decision<keys>.kv -> $key, $definition {
            my $expected = %decision<versions>{$key}
                + ($state<counter-increments>{$key} // 0)
                - (%decision<own>{$key} // 0);
            if %guards{$key}:exists {
                RedSourcing::X::OptimisticLockFailed.new(:boundary<event-tags>).throw
                    unless %guards{$key}<expected> == $expected;
            }
            %guards{$key} = { :$definition, :$expected };
        }
    }
    %guards
}

sub journal-append(%keys, &work) is export {
    # Bootstrap the counter schema even for the first snapshot. Deferring DDL
    # until a domain fact inside a command can make independent Pg writers wait
    # on transactional CREATE TABLE, and leaves no table after rollback.
    journal-connection().journal-ensure-counters;
    transaction-do {
        my $connection = journal-connection();
        my $state = $connection.journal-state;
        $state<decision-conflict>.throw if $state<decision-conflict>.defined;
        CATCH {
            default {
                my $failure = $_;
                if $failure ~~ RedSourcing::X::OptimisticLockFailed || retryable-journal-error($failure) {
                    my $conflict = $failure ~~ RedSourcing::X::OptimisticLockFailed
                        ?? $failure !! RedSourcing::X::OptimisticLockFailed.new(:boundary<transaction-conflict>);
                    $state<decision-conflict> = $conflict;
                    $conflict.throw;
                }
                $failure.rethrow;
            }
        }
        my $condition = try &*REDSOURCING-APPEND-CONDITION;
        my %guards = $condition.defined ?? $condition() !! %();
        my %changes;
        for (|%keys.keys, |%guards.keys).unique -> $key {
            %changes{$key} = {
                increment => ((%keys{$key}:exists) ?? 1 !! 0),
                definition => (%keys{$key} // %guards{$key}<definition>),
                expected => (%guards{$key}<expected> // Any)
            };
        }
        update-counters($connection, %changes);
        for %changes.kv -> $key, %change {
            $state<counter-increments>{$key} = ($state<counter-increments>{$key} // 0) + %change<increment>;
        }
        $_<validated> = True for $state<decisions>.List;
        work()
    }
}

sub transaction-do(&work) is export {
    journal-connection();
    if (try $*RED-TRANSACTION-RUNNING) // False {
        return work();
    }
    red-do :transaction, { work() }
}

sub journal-do(&work) is export { transaction-do { work() } }

sub journal-working(Str $key, &restore) is export {
    journal-connection().journal-state<working>{$key} //= restore()
}

sub journal-publish(Str $key, &publish) is export {
    journal-connection().journal-state<publish>{$key} = &publish;
}
