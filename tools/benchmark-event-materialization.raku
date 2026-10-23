#!/usr/bin/env raku
use RedSourcing;
use RedSourcing::Storage;
use RedSourcing::Journal;
use JSON::Fast;

class MaterializationFact does Event {
    has Int $.amount;
    has $.payload;
}

# Isolate row hydration and domain construction from SQL and event appends.
sub MAIN(UInt :$iterations where * > 0 = 2000) {
    my $*RED-DB = database 'SQLite', :database(':memory:');
    schema(StoredEvent, StoredCommand).create;
    my $stored = MaterializationFact.emit(:amount(7),
        :payload(%(text => '1', number => 1, flag => True, null => Any, array => [1, False])),
        :stream<materialization>, :version(1));
    my $raw = storage-query(journal-connection(), 'SELECT * FROM red_sourcing_event WHERE id = ' ~ $stored.id).head;
    for ^20 { StoredEvent.^new-from-data($raw); $stored.COERCE }
    my $sum = 0;
    my $start = now;
    for ^$iterations { $sum += StoredEvent.^new-from-data($raw).data<amount> }
    my $hydration = (now - $start).Num;
    $start = now;
    for ^$iterations { $sum += $stored.COERCE.amount }
    my $conversion = (now - $start).Num;
    die 'Unexpected materialization result' unless $sum == $iterations * 14;
    say to-json(%(:$iterations, :$sum, hydration_seconds => $hydration,
        conversion_seconds => $conversion), :!pretty);
}
