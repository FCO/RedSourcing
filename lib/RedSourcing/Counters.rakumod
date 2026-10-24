unit module RedSourcing::Counters;
use Red;
use Red::DB;
use RedSourcing::Storage;
use RedSourcing::StoredCounter;
use RedSourcing::Tags;
use RedSourcing::Utils;
use RedSourcing::X::OptimisticLockFailed;

sub is-pg($connection --> Bool) is export {
    $connection.^mro.map(*.^name).first(* eq 'Red::Driver::Pg').defined
}

sub placeholders($connection, Int $count --> List) {
    (is-pg($connection) ?? (1..$count).map({ '$' ~ $_ }) !! ('?' xx $count)).List
}

# Always close even failed SQLite cursors: otherwise a rolled-back WAL read
# snapshot can survive in a cached native statement.
sub counter-sql($connection, Str $sql, *@binds --> Array) is export {
    storage-query($connection, $sql, |@binds)
}

sub initialize-counters() is export {
    my $connection = get-RED-DB;
    die 'Event counters require SQLite or PostgreSQL'
        unless is-pg($connection) || $connection.^mro.map(*.^name).first(* eq 'Red::Driver::SQLite').defined;
    # Red 0.2.7 implements :unless-exists by catching a failed CREATE, which
    # poisons an already-open PostgreSQL transaction. Probe without an error.
    my @existing = is-pg($connection)
        ?? counter-sql($connection, "SELECT to_regclass('red_sourcing_counter') AS name")
        !! counter-sql($connection, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'red_sourcing_counter'");
    return if @existing && @existing.head<name>.defined;
    counter-sql($connection, 'CREATE TABLE IF NOT EXISTS red_sourcing_counter ('
        ~ 'key TEXT NOT NULL PRIMARY KEY, definition TEXT NOT NULL, '
        ~ 'version BIGINT NOT NULL DEFAULT 0 CHECK (version >= 0))');
}

sub read-counters($connection, %keys --> Hash) is export {
    my %versions = %keys.keys.map({ $_ => 0 });
    for %keys.keys.sort.rotor(128, :partial) -> @chunk {
        my @binds = placeholders($connection, @chunk.elems);
        for storage-prepared-query($connection,
                'SELECT key, definition, version FROM red_sourcing_counter WHERE key IN ('
                ~ @binds.join(',') ~ ')', |@chunk) -> %row {
            die 'Event counter key collision' unless %keys{%row<key>} eq %row<definition>;
            %versions{%row<key>} = %row<version>.UInt;
        }
    }
    %versions
}

# A checked UPSERT is also the CAS for a missing row (expected version zero).
# Validations use increment=0; only actual emitted events advance a counter.
sub update-counter($connection, Str $key, Str $definition, UInt $increment,
        UInt :$expected --> UInt) is export {
    my @p = placeholders($connection, $expected.defined ?? 4 !! 3);
    my $sql = 'INSERT INTO red_sourcing_counter (key, definition, version) VALUES ('
        ~ @p[0..2].join(',') ~ ') ON CONFLICT (key) DO UPDATE SET version = '
        ~ 'red_sourcing_counter.version + excluded.version WHERE '
        ~ 'red_sourcing_counter.definition = excluded.definition';
    $sql ~= ' AND red_sourcing_counter.version = ' ~ @p[3] if $expected.defined;
    $sql ~= ' RETURNING definition, version';
    # A missing row can satisfy only expected=0. Never seed an arbitrary version.
    if $expected.defined && $expected > 0 {
        my @q = placeholders($connection, 4);
        $sql = 'UPDATE red_sourcing_counter SET version = version + ' ~ @q[0]
            ~ ' WHERE key = ' ~ @q[1] ~ ' AND definition = ' ~ @q[2]
            ~ ' AND version = ' ~ @q[3] ~ ' RETURNING definition, version';
        my @rows = storage-prepared-query($connection, $sql, $increment, $key, $definition, $expected);
        RedSourcing::X::OptimisticLockFailed.new(:boundary<event-tags>).throw unless @rows;
        return @rows.head<version>.UInt;
    }
    my @values = $key, $definition, $increment;
    @values.push($expected) if $expected.defined;
    my @rows = storage-prepared-query($connection, $sql, |@values);
    RedSourcing::X::OptimisticLockFailed.new(:boundary<event-tags>).throw unless @rows;
    die 'Event counter key collision' unless @rows.head<definition> eq $definition;
    @rows.head<version>.UInt
}

# Update a sorted batch in one statement. A guarded row that disappeared or
# changed produces no RETURNING row; the caller rolls back the complete append.
sub update-counters($connection, %changes --> Hash) is export {
    counter-batches($connection, %changes, :prepared)
}

sub counter-batches($connection, %changes, Bool :$prepared = False --> Hash) {
    my %versions;
    for %changes.keys.sort.rotor(128, :partial) -> @keys {
        my @values;
        my @tuples;
        for @keys -> $key {
            my %change = %changes{$key};
            my @parameters = is-pg($connection)
                ?? (@values.elems + 1 .. @values.elems + 4).map({ '$' ~ $_ })
                !! ('?' xx 4);
            @tuples.push('(' ~ @parameters[0..1].join(',') ~ ',CAST(' ~ @parameters[2]
                ~ ' AS BIGINT),CAST(' ~ @parameters[3] ~ ' AS BIGINT))');
            @values.append($key, %change<definition>, %change<increment>, %change<expected>);
        }
        my $sql = 'WITH changes(key, definition, increment, expected) AS (VALUES '
            ~ @tuples.join(',') ~ ') INSERT INTO red_sourcing_counter (key, definition, version) '
            ~ 'SELECT key, definition, increment FROM changes WHERE expected IS NULL OR expected = 0 '
            ~ 'OR EXISTS (SELECT 1 FROM red_sourcing_counter c WHERE c.key = changes.key) '
            ~ 'ORDER BY key ON CONFLICT (key) DO UPDATE SET version = '
            ~ 'red_sourcing_counter.version + excluded.version WHERE '
            ~ 'red_sourcing_counter.definition = excluded.definition AND '
            ~ '((SELECT expected FROM changes WHERE changes.key = excluded.key) IS NULL OR '
            ~ 'red_sourcing_counter.version = (SELECT expected FROM changes WHERE changes.key = excluded.key)) '
            ~ 'RETURNING key, definition, version';
        my @rows = $prepared ?? storage-prepared-query($connection, $sql, |@values)
            !! counter-sql($connection, $sql, |@values);
        RedSourcing::X::OptimisticLockFailed.new(:boundary<event-tags>).throw
            unless @rows.elems == @keys.elems;
        for @rows -> %row {
            die 'Event counter key collision' unless %changes{%row<key>}<definition> eq %row<definition>;
            %versions{%row<key>} = %row<version>.UInt;
        }
    }
    %versions
}

sub retryable-journal-error(Exception $failure --> Bool) is export {
    my $native = $failure;
    $native = $native.orig-exception while $native.^can('orig-exception');
    return True if $native.^name eq 'X::DBDish::DBError'
        && (($native.code +& 255) == any(5, 6));
    my $state = (try $native.sqlstate) // (try $native.state) // (try $native.code) // '';
    so ($state.Str eq any(<40P01 40001>))
}

# Maintenance operation: application writers must be stopped. The event log is
# untouched, and a failed rebuild restores the previous counter table contents.
sub rebuild-event-counters(--> UInt) is export {
    die 'Rebuild event counters outside application transactions, with writers stopped'
        if (try $*RED-TRANSACTION-RUNNING) // False;
    require ::('RedSourcing::StoredEvent');
    initialize-counters();
    my UInt $events = 0;
    red-do :transaction, {
        my $connection = get-RED-DB;
        counter-sql($connection, 'DELETE FROM red_sourcing_counter');
        my %pending;
        sub flush {
            counter-batches($connection, %pending);
            %pending = ();
        }
        for ::('RedSourcing::StoredEvent').^all.sort(*.id).Seq -> $row {
            $events++;
            next if $row.mro.contains('|Entity|') || ($row.mro.contains('|RedSourcing::Saga::Control|') || $row.mro.contains('|RedSourcing::Service::Protocol::Control|'));
            my $type = resolve-class($row.class);
            my %keys = event-counter-keys($type, $row.data.Hash, :normalized);
            for %keys.kv -> $key, $definition {
                if %pending{$key}:exists {
                    die 'Event counter key collision' unless %pending{$key}<definition> eq $definition;
                    %pending{$key}<increment>++;
                } else { %pending{$key} = { :$definition, increment => 1 } }
            }
            flush() if %pending.elems >= 512;
        }
        flush() if %pending;
    }
    $events
}
