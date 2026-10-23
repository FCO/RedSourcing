#!/usr/bin/env raku
use RedSourcing;
use RedSourcing::Config;
use JSON::Fast;

sub MAIN(UInt :$iterations where * > 0 = 500) {
    my $*RED-DB = store-driver('SQLite', ':memory:');
    schema(StoredEvent, StoredCommand).create;
    my $time = DateTime.new('2026-01-01T00:00:00Z');
    my $sum = 0;
    my $start = now;
    for ^$iterations -> $i {
        my $row = StoredCommand.^create(:entity<InsertBenchmark>,
            :entity-ids{key => $i}, :method<perform>, :stream("insert-$i"),
            :data{amount => $i, flags => [True, False, Any]},
            :next-run($time), :parent-command-id($i + 1), :action-id("action-$i"));
        $sum += $row.id;
        die 'Unexpected command payload' unless $row.data<amount> == $i;
    }
    my $seconds = (now - $start).Num;
    die 'Unexpected command count' unless StoredCommand.^all.elems == $iterations;
    die 'Unexpected generated IDs' unless $sum == $iterations * ($iterations + 1) div 2;
    say to-json(%(:$iterations, :$sum, :$seconds), :!pretty);
}
