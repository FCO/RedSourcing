unit module RedSourcing::Journal;
use Red;
use Red::DB;

sub empty-state() {
    { gated => False, working => {}, publish => {}, retained => {},
        snapshot-candidates => {}, savepoints => [] }
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
    { gated => $state<gated>, :%maps, :%objects }
}

sub restore-checkpoint(Hash $state, Hash $checkpoint) {
    for $checkpoint<objects>.values -> $pair {
        lifecycle-helper('&entity-adopt')($pair[0], $pair[1]);
    }
    $state<gated> = $checkpoint<gated>;
    $state{$_} = $checkpoint<maps>{$_}.clone for <working publish retained snapshot-candidates>;
}

# Install hooks on the transaction driver, including transactions owned by a
# caller's red-do. A lexical KEEP around an individual emit would publish early.
my role JournalConnection {
    has Str $!journal-store;
    has Hash $!journal-state;

    method journal-initialize(Str $store, Hash :$state = empty-state()) {
        $!journal-store = $store;
        $!journal-state = $state;
        self
    }
    method journal-store { $!journal-store }
    method journal-state { $!journal-state }
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
        my @publish = $!journal-state<publish>.values;
        my $result = callsame;
        $!journal-state = empty-state();
        .() for @publish;
        $result
    }
    method rollback {
        return callsame if self.?transaction-guard.defined;
        LEAVE $!journal-state = empty-state();
        callsame
    }
}

sub journal-connection() is export {
    my $connection = get-RED-DB;
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
            return $connection.journal-initialize($native.journal-store, :state($native.journal-state));
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

sub journal-gate() is export {
    die 'Journal append requires a transaction' unless (try $*RED-TRANSACTION-RUNNING) // False;
    my $connection = journal-connection();
    return if $connection.journal-state<gated>;
    my @drivers = $connection.^mro.map(*.^name);
    if @drivers.first(* eq 'Red::Driver::Pg').defined {
        # The table OID scopes the gate to a store/schema in this database. All
        # journal writers acquire it before a sequence allocates their row ID.
        $connection.execute("SELECT pg_advisory_xact_lock(1381188434, 'red_sourcing_event'::regclass::oid::integer)").row;
    } elsif !@drivers.first(* eq 'Red::Driver::SQLite').defined {
        die 'Transactional journal appends require SQLite or PostgreSQL';
    }
    # SQLite's first INSERT already holds the database write lock through commit.
    $connection.journal-state<gated> = True;
}

sub transaction-do(&work) is export {
    journal-connection();
    if (try $*RED-TRANSACTION-RUNNING) // False {
        return work();
    }
    red-do :transaction, { work() }
}

sub journal-do(&work) is export { transaction-do { journal-gate(); work() } }

sub journal-working(Str $key, &restore) is export {
    journal-connection().journal-state<working>{$key} //= restore()
}

sub journal-publish(Str $key, &publish) is export {
    journal-connection().journal-state<publish>{$key} = &publish;
}
