#!/usr/bin/env raku
use RedSourcing;
use RedSourcing::Config;
use JSON::Fast;

my $applied = 0;
class DecisionSnapshotBenchFact does Event { has Int $.key; has Int $.amount }
projection DecisionSnapshotBenchTotal[:!auto-snapshot] {
    has Int $.key is entity-id;
    has Int $.total = 0;
    method APPLY(DecisionSnapshotBenchFact $event where { .key eqv $!key }) {
        $applied++;
        $!total += $event.amount;
    }
}
projection DecisionSnapshotBenchMirror is DecisionSnapshotBenchTotal { }

sub MAIN(UInt :$iterations where * > 0 = 50, UInt :$streams where * > 0 = 4,
        UInt :$history = 100, UInt :$tail = 2, Bool :$checkpoint = True) {
    my $*RED-DB = store-driver('SQLite', ':memory:');
    schema(StoredEvent, StoredCommand).create;
    for ^$streams -> $key {
        DecisionSnapshotBenchFact.emit(:$key, :amount(1), :stream("bench-$key"), :version($_ + 1)) for ^$history;
        if $checkpoint && $history {
            .^with-ids(:$key).^load.^emit-snapshot for DecisionSnapshotBenchTotal, DecisionSnapshotBenchMirror;
        }
        DecisionSnapshotBenchFact.emit(:$key, :amount(1), :stream("bench-$key"), :version($history + $_ + 1)) for ^$tail;
    }
    sub read($index) {
        decision-model (DecisionSnapshotBenchTotal) => %(:key($index % $streams)),
            (DecisionSnapshotBenchMirror) => %(:key(($index + 1) % $streams)),
            -> $first, $second { $first.total + $second.total }
    }
    read($_) for ^$streams; # Warm templates and native statement caches.
    $applied = 0;
    my $sum = 0;
    my $start = now;
    $sum += read($_) for ^$iterations;
    my $seconds = (now - $start).Num;
    die 'Unexpected decision state' unless $sum == 2 * $iterations * ($history + $tail);
    say to-json(%(:$iterations, :$streams, :$history, :$tail, :$checkpoint, :$seconds, :$sum, :$applied), :!pretty);
}
