#!/usr/bin/env raku
use RedSourcing;
use RedSourcing::Config;
use RedSourcing::Flow;
use RedSourcing::Counters;
use JSON::Fast;
use DB::Pg;

class ConcurrentFact does Event { has Str $.key }
projection ConcurrentConsumption {
    has %.seen;
    method APPLY(ConcurrentFact $event) { %!seen{$event.key} = True }
}

# Each invocation owns a temporary schema; the database must already exist.
sub MAIN(Str :$database = (%*ENV<RED_SOURCING_TEST_PG_DATABASE> // 'postgres'),
        UInt :$writers = 4, UInt :$events = 25, Bool :$trace = False,
        UInt :$worker, Str :$schema) {
    die 'Use a simple database name' unless $database ~~ /^ <[\w\-]>+ $/;
    die 'writers and events must be positive' unless $writers && $events;
    my $admin = DB::Pg.new(:conninfo("dbname=$database"));
    my $selected-schema = $schema // 'rs_bench_' ~ $*PID;
    die 'Use a simple schema name' unless $selected-schema ~~ /^ \w+ $/;
    $admin.execute("CREATE SCHEMA $selected-schema") unless $worker.defined;
    LEAVE $admin.execute("DROP SCHEMA $selected-schema CASCADE") unless $worker.defined;
    my $pool = DB::Pg.new(:conninfo("dbname=$database options='-csearch_path=$selected-schema -cclient_min_messages=warning'"),
        :converters(<DateTime UUID Geometric>));
    my $*RED-DB = store-driver('Pg', $database, :connection{ dbh => $pool });
    if $worker.defined {
        enable-flow-tracing(:!initialize) if $trace;
        my $errors = 0;
        for ^$events -> $index {
            try {
                ConcurrentFact.emit(:key("{$worker}:$index"), :stream("worker-$worker"), :version($index + 1));
                CATCH { default { $errors++; note .message } }
            }
        }
        say to-json({ :$worker, database-errors => $errors }, :!pretty);
        exit($errors ?? 1 !! 0);
    }
    schema(StoredEvent, StoredCommand).create;
    initialize-counters();
    enable-flow-tracing if $trace;
    my $view = ConcurrentConsumption.^with-ids.^load;
    my @processes;
    my $started = now;
    for ^$writers -> $number {
        my @args = $*EXECUTABLE.Str, '-Ilib', $*PROGRAM-NAME,
            "--database=$database", "--worker=$number", "--events=$events", "--schema=$selected-schema";
        @args.push('--trace') if $trace;
        my $process = Proc::Async.new(|@args);
        my ($out, $err) = '', '';
        $process.stdout.tap(-> $chunk { $out ~= $chunk });
        $process.stderr.tap(-> $chunk { $err ~= $chunk });
        @processes.push({ :$process, finished => $process.start,
            output => -> { $out }, errors => -> { $err } });
    }
    LEAVE { for @processes -> %process { %process<process>.kill if %process<finished>.status ~~ Planned } }
    my $deadline = now + 120;
    while @processes.first({ .<finished>.status ~~ Planned }).defined {
        die 'Benchmark workers timed out' if now > $deadline;
        $view.^advance(:checkpoint);
        await Promise.in(0.01);
    }
    my $database-errors = 0;
    my $worker-errors = '';
    for @processes -> %process {
        $worker-errors ~= %process<errors>();
        my %result = from-json(%process<output>());
        $database-errors += %result<database-errors>;
    }
    $view.^advance(:checkpoint);
    my @persisted = StoredEvent.list-events(:types[ConcurrentFact]);
    my @missing = @persisted.grep({ !($view.seen{.key}:exists) }).map(*.key);
    say to-json({ :$writers, events-per-writer => $events, :$trace,
        seconds => (now - $started).Num, persisted => @persisted.elems,
        consumed => $view.seen.elems, cursor-misses => @missing.elems,
        :$database-errors, diagnostics => $worker-errors, missing => @missing.Array }, :!pretty);
    exit 1 if $database-errors;
}
