#!/usr/bin/env raku
use lib $?FILE.IO.parent.parent.add('examples/school/lib').Str;
use RedSourcing;
use RedSourcing::Config;
use RedSourcing::Flow;
use RedSourcing::Inspector;
use RedSourcing::Web::Flows;
use JSON::Fast;
use School;

class PerformanceFact does Event { has Str $.key; has Int $.amount }
class PerformancePayload does Event { has Str $.key; has Hash $.payload }
aggregate PerformanceAccount {
    has Str $.key is entity-id;
    has Int $.balance = 0;
    method APPLY(PerformanceFact $event) { $!balance += $event.amount }
    method credit is command { self.performance-fact(:amount(1)); $!balance }
}
projection PerformanceView {
    has Str $.key is entity-id;
    has Int $.balance = 0;
    method APPLY(PerformanceFact $event where { .key eqv $!key }) { $!balance += $event.amount }
}
saga PerformanceSaga {
    has Str $.key is entity-id;
    multi method APPLY(PerformanceFact $event where { .key eqv $!key }) { }
    multi method REACT(PerformanceFact $event where { .key eqv $!key }) { self.^complete }
}

my $prepares = 0;
my %sql;
my role MeasureQueries {
    multi method prepare(Str $statement, |args) {
        $prepares++;
        %sql{$statement}++;
        callsame
    }
}

sub MAIN(UInt :$events = 200, UInt :$iterations = 20, Str :$driver = 'SQLite',
         Str :$database = ':memory:', Bool :$queries = False, Bool :$school = True) {
    die 'events and iterations must be positive' unless $events && $iterations;
    my $admin;
    my $schema;
    LEAVE $admin.execute("DROP SCHEMA $schema CASCADE") if $admin.defined;
    my $db;
    if $driver eq 'Pg' {
        require ::('DB::Pg');
        die 'Use a simple database name' unless $database ~~ /^ <[\w\-]>+ $/;
        $admin = ::('DB::Pg').new(:conninfo("dbname=$database"));
        $schema = 'rs_performance_' ~ $*PID;
        $admin.execute("CREATE SCHEMA $schema");
        my $pool = ::('DB::Pg').new(:conninfo("dbname=$database options='-csearch_path=$schema -cclient_min_messages=warning'"),
            :converters(<DateTime UUID Geometric>));
        $db = store-driver('Pg', $database, :connection{ dbh => $pool });
    } else { $db = store-driver('SQLite', $database) }
    my $*RED-DB = $db but MeasureQueries;
    my @measurements;
    sub measure(Str $phase, UInt $operations, &work) {
        my $before = $prepares;
        %sql = ();
        my $start = now;
        my $result = work();
        @measurements.push(%(:$phase, :$operations, seconds => (now - $start).Num,
            prepares => $prepares - $before, :$result,
            |($queries ?? (queries => %sql.Hash.clone) !! ())));
    }
    measure 'bootstrap', 1, { red-sourcing-defaults; True };
    measure 'emit', $events, {
        for 1..$events -> $version {
            PerformanceFact.emit(:stream<raw>, :$version, :key('k' ~ $version % 10), :amount(1));
        }
        StoredEvent.^all.elems
    };
    my $wide = ($events div 4) max 1;
    measure 'emit-wide', $wide, {
        for 1..$wide -> $version {
            PerformancePayload.emit(:stream<wide>, :$version, :key<wide>,
                :payload(%(profile => %(city => 'Lisbon', score => $version), values => [1..12], description => 'x' x 256)));
        }
        $wide
    };
    measure 'stream-query', $iterations, {
        [+] (^$iterations).map({ StoredEvent.list-events(:stream<raw>, :row).elems })
    };
    measure 'projection-replay', $iterations, {
        [+] (^$iterations).map({ PerformanceView.^with-ids(:key<k1>).^load.balance })
    };
    measure 'decision-read', $iterations, {
        [+] (^$iterations).map({ decision-model((PerformanceView) => %(:key<k1>), -> $v { $v.balance }) })
    };
    my $account = PerformanceAccount.^with-ids(:key<account>);
    $account.^create;
    measure 'commands', $iterations, {
        $account.credit for ^$iterations;
        $account.^load.balance
    };
    measure 'decision-append', $iterations, {
        for 1..$iterations -> $version {
            decision-model((PerformanceView) => %(:key<decision>), -> $v {
                PerformanceFact.emit(:stream<decision>, :$version, :key<decision>, :amount(1));
            });
        }
        PerformanceView.^with-ids(:key<decision>).^load.balance
    };
    my $sagas = ($iterations div 4) max 1;
    measure 'sagas', $sagas, {
        for 1..$sagas -> $index {
            my $saga = PerformanceSaga.^with-ids(:key("saga-$index"));
            $saga.^create;
            PerformanceFact.emit(:stream("saga-source-$index"), :version(1), :key("saga-$index"), :amount(1));
            die 'Saga did not complete' unless $saga.^advance.^status eq 'completed';
        }
        $sagas
    };
    # Warm the lazily loaded read model separately from repeated reconstruction.
    measure 'flow-first-read', 1, { flow-projection().links.elems };
    my $reads = ($iterations div 4) max 1;
    measure 'flow-read', $reads, { [+] (^$reads).map({ flow-projection().links.elems }) };
    my $inspector = RedSourcing::Inspector.new(:stored-only);
    measure 'inspector', $reads, { [+] (^$reads).map({ $inspector.report<instances>.elems }) };
    my %report = $inspector.report;
    measure 'monitor-flow', $reads, {
        [+] (^$reads).map({ flow-report(%report, :stream($account.^stream-name))<nodes>.elems })
    };
    if $school {
        measure 'school', 21, {
            my $school = School::App.new.initialize;
            $school.add-class('performance-math', 'Math');
            for 1..10 -> $index {
                $school.add-student("performance-$index", "Student $index");
                $school.enroll("performance-$index", 'performance-math');
            }
            $school.classroom('performance-math').student-count
        };
    }
    measure 'rebuild-counters', 1, { rebuild-event-counters() };
    say to-json(%(:$driver, :$events, :$iterations, phases => @measurements), :!pretty);
}
