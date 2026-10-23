#!/usr/bin/env raku
use RedSourcing;
use RedSourcing::Config;
use JSON::Fast;

class AggregateLoadFact does Event { has Int $.amount }
aggregate AggregateLoadTotal {
    has Str $.key is entity-id;
    has Int $.total = 0;
    method APPLY(AggregateLoadFact $event) { $!total += $event.amount }
}

sub MAIN(UInt :$iterations where * > 0 = 200, UInt :$streams where * > 0 = 10) {
    my $*RED-DB = store-driver('SQLite', ':memory:');
    schema(StoredEvent, StoredCommand).create;
    my @proxies;
    for ^$streams -> $i {
        my $proxy = AggregateLoadTotal.^with-ids(:key("load-$i"));
        my $snapshot = $proxy.^create;
        AggregateLoadFact.emit(:stream($snapshot.stream), :version(2), :amount($i + 1));
        @proxies.push($proxy);
    }
    .^load for @proxies;
    my $sum = 0;
    my $start = now;
    $sum += @proxies[$_ % $streams].^load.total for ^$iterations;
    my $seconds = (now - $start).Num;
    my $expected = [+] (^$iterations).map({ $_ % $streams + 1 });
    die 'Unexpected aggregate replay result' unless $sum == $expected;
    say to-json(%(:$iterations, :$streams, :$sum, :$seconds), :!pretty);
}
