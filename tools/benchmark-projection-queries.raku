#!/usr/bin/env raku
use RedSourcing;
use JSON::Fast;

class QueryBenchmarkFact does Event { has Str $.key; has Int $.amount }
projection QueryBenchmarkTotal {
    has Str $.key is entity-id;
    has Int $.total = 0;
    method APPLY(QueryBenchmarkFact $e where { .key eqv $!key }) { $!total += $e.amount }
}

# Time warm, ordinary projection loads with alternating IDs. Startup, schema
# creation and event appends are deliberately outside the measured interval.
sub MAIN(UInt :$iterations = 200, UInt :$events where * > 0 = 10) {
    my $*RED-DB = database 'SQLite', :database(':memory:');
    schema(StoredEvent, StoredCommand).create;
    for ^$events -> $i {
        QueryBenchmarkFact.emit(:key('key-' ~ $i), :amount($i), :stream($i.Str), :version(1));
    }
    QueryBenchmarkTotal.^with-ids(:key('key-0')).^load;
    my $start = now;
    my $sum = 0;
    for ^$iterations -> $i {
        $sum += QueryBenchmarkTotal.^with-ids(:key('key-' ~ ($i % $events))).^load.total;
    }
    say to-json(%(seconds => (now - $start).Num, :$sum, :$events, :$iterations), :!pretty);
}
