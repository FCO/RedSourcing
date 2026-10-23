unit module SchoolDemoTiming;
use RedSourcing;
use RedSourcing::Config;
use RedSourcing::Journal;
use RedSourcing::Counters;
use RedSourcing::Tags;
use RedSourcing::Storage;
use RedSourcing::Decision;
use RedSourcing::Utils;
use RedSourcing::Predicate;
use RedSourcing::Context;
use RedSourcing::Projection;
use School;
use JSON::Fast;

my $origin;
my @records;
my @stack;
my @handles;
my %wrapped;
sub stamp { (now - $origin).Num * 1000 }
sub start-record(Str $name, :@arguments = []) {
    my %record = id => @records.elems + 1, parent => (@stack.tail // 0),
        :$name, start_ms => stamp(), :@arguments;
    @records.push(%record);
    %record
}
sub instrument(Callable $routine, Str $name, Bool :$arguments = False) {
    return if %wrapped{$routine.WHICH.Str}++;
    @handles.push($routine.wrap(-> |capture {
        my %record := start-record($name, :arguments($arguments
            ?? capture.list.skip(1).map(*.Str).Array !! []));
        @stack.push(%record<id>);
        %record<success> = True;
        CATCH { default { %record<success> = False; .rethrow } }
        LEAVE {
            %record<duration_ms> = stamp() - %record<start_ms>;
            @stack.pop;
        }
        # Preserve list/rw return semantics: scalar assignment would itemize
        # routines such as rules-from-methods and change the demo's behavior.
        callsame
    }));
}

my role TimedStatement {
    has Str $.timing-sql is rw;
    has Num $.timing-prepare-ms is rw = 0e0;
    has Hash $.timing-record is rw;
    method execute(|args) {
        $!timing-record = start-record('SQL');
        $!timing-record<sql> = $!timing-sql;
        $!timing-record<prepare_ms> = $!timing-prepare-ms;
        $!timing-prepare-ms = 0e0;
        $!timing-record<fetch_ms> = 0;
        $!timing-record<rows> = 0;
        my $start = now;
        LEAVE $!timing-record<execute_ms> = (now - $start).Num * 1000;
        callsame
    }
    method row(|args) {
        my $start = now;
        LEAVE $!timing-record<fetch_ms> += (now - $start).Num * 1000;
        my $row = callsame;
        $!timing-record<rows>++ if $row ~~ Associative && $row.elems;
        $row
    }
}
my role TimedDriver {
    method begin(|args) {
        my %record := start-record('DB.begin');
        @stack.push(%record<id>);
        my $success = False;
        LEAVE {
            %record<duration_ms> = stamp() - %record<start_ms>;
            %record<success> = $success;
            @stack.pop;
        }
        my $result = callsame;
        $success = True;
        $result
    }
    method commit(|args) {
        my %record := start-record('DB.commit');
        @stack.push(%record<id>);
        my $success = False;
        LEAVE {
            %record<duration_ms> = stamp() - %record<start_ms>;
            %record<success> = $success;
            @stack.pop;
        }
        my $result = callsame;
        $success = True;
        $result
    }
    method rollback(|args) {
        my %record := start-record('DB.rollback');
        @stack.push(%record<id>);
        my $success = False;
        LEAVE {
            %record<duration_ms> = stamp() - %record<start_ms>;
            %record<success> = $success;
            @stack.pop;
        }
        my $result = callsame;
        $success = True;
        $result
    }
    method savepoint(|args) {
        my %record := start-record('DB.savepoint');
        @stack.push(%record<id>);
        my $success = False;
        LEAVE {
            %record<duration_ms> = stamp() - %record<start_ms>;
            %record<success> = $success;
            @stack.pop;
        }
        my $result = callsame;
        $success = True;
        $result
    }
    method release-savepoint(|args) {
        my %record := start-record('DB.release-savepoint');
        @stack.push(%record<id>);
        my $success = False;
        LEAVE {
            %record<duration_ms> = stamp() - %record<start_ms>;
            %record<success> = $success;
            @stack.pop;
        }
        my $result = callsame;
        $success = True;
        $result
    }
    method rollback-to-savepoint(|args) {
        my %record := start-record('DB.rollback-to-savepoint');
        @stack.push(%record<id>);
        my $success = False;
        LEAVE {
            %record<duration_ms> = stamp() - %record<start_ms>;
            %record<success> = $success;
            @stack.pop;
        }
        my $result = callsame;
        $success = True;
        $result
    }
    multi method prepare(Str $sql, |args) {
        my $start = now;
        my $statement = callsame;
        my $elapsed = (now - $start).Num * 1000;
        # SQLite's read pool executes the native handle directly on reuse.
        # Observe that handle so each execution gets its current parent/binds.
        my $executor = self.^mro.map(*.^name).first(* eq 'Red::Driver::SQLite').defined
            ?? $statement.statement !! $statement;
        $executor does TimedStatement unless $executor ~~ TimedStatement;
        $executor.timing-sql = $sql;
        $executor.timing-prepare-ms = $elapsed;
        $statement
    }
}

INIT {
    for <initialize add-student add-class enroll cancel student classroom> -> $name {
        instrument(School::App.^find_method($name), "App.$name", :arguments);
    }
    instrument(StoredCommand.^find_method('run'), 'Command.run');
    for <load write-snapshot> -> $name {
        instrument(Metamodel::RedSourcing::EntityHOW.^find_method($name), "Entity.$name");
    }
    instrument(Metamodel::RedSourcing::EntityHOW.^find_method('restore-and-replay'), 'Entity.restore');
    instrument(Metamodel::RedSourcing::AggregateHOW.^find_method('restore-and-replay'), 'Entity.restore');
    instrument(Metamodel::RedSourcing::ProjectionHOW.^find_method('apply-new-applyable-events'), 'Projection.replay');
    instrument(&decision-model, 'Decision.model');
    instrument(&rules-from-methods, 'Rules.signatures');
    instrument(&predicate-ast, 'Rules.predicate-ast');
    instrument(StoredEvent.^find_method('event-filter'), 'Rules.event-filter');
    instrument(StoredEvent.^find_method('COERCE'), 'Event.inflate');
    instrument(&apply-event, 'Projection.APPLY');
    instrument(&normalize-event-data, 'Event.normalize');
    instrument(&advance-transactional-projections, 'Projection.transactional');
    instrument(&journal-decision-condition, 'Counters.guards');
    instrument(StoredCommand.HOW.^find_method('refresh-storage-row'), 'Command.refresh');
    instrument(StoredEvent.HOW.^find_method('new-from-data'), 'Storage.hydrate');
    instrument(StoredEvent.HOW.^find_method('create'), 'Storage.create');
    instrument(StoredEvent.HOW.^find_method('save'), 'Storage.save');
    instrument(&journal-append, 'Journal.append');
    instrument(&event-counter-keys, 'Tags.keys');
    instrument(&read-counters, 'Counters.read');
    instrument(&update-counters, 'Counters.CAS');
    instrument(&storage-decision-rows, 'Storage.decision-rows');
    instrument(&storage-aggregate-rows, 'Storage.aggregate-rows');
    instrument(Metamodel::RedSourcing::ProxyHOW.^find_method('create'), 'Entity.create');
    @handles.push(&optimize-storage-driver.wrap(-> |capture {
        my $driver = callsame;
        $driver does TimedDriver unless $driver ~~ TimedDriver;
        $driver
    }));
    $origin = now;
}
END {
    if $origin.defined && %*ENV<SCHOOL_TIMING_OUTPUT>.defined {
        my $elapsed = stamp();
        for @records.grep(*.<name> eq 'SQL') -> %record {
            %record<duration_ms> = %record<prepare_ms> + %record<execute_ms> + %record<fetch_ms>;
        }
        %*ENV<SCHOOL_TIMING_OUTPUT>.IO.spurt(to-json(%(duration_ms => $elapsed, origin_posix => $origin.to-posix.head.Num,
            end_posix => now.to-posix.head.Num, records => @records), :!pretty));
    }
}
