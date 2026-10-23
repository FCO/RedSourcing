#!/usr/bin/env raku
use RedSourcing;
use RedSourcing::Config;
use RedSourcing::Counters;
use RedSourcing::Journal;
use JSON::Fast;

sub MAIN(Str :$kind where any(<read write>) = 'read', UInt :$iterations where * > 0 = 1000,
        UInt :$keys where * > 0 = 8) {
    my $*RED-DB = store-driver('SQLite', ':memory:');
    schema(StoredEvent, StoredCommand).create;
    initialize-counters;
    my $connection = journal-connection();
    my %definitions = (^$keys).map({ "bench-$_" => "definition-$_" });
    my %seed = %definitions.map(-> $entry {
        $entry.key => %(definition => $entry.value, increment => 1, expected => 0)
    });
    red-do :transaction, { update-counters(journal-connection(), %seed) };
    # Warm both SQL shapes before timing; guarded writes bind a fresh expectation.
    my UInt $version = 1;
    sub write {
        my %changes = %definitions.map(-> $entry {
            $entry.key => %(definition => $entry.value, increment => 1, expected => $version)
        });
        red-do :transaction, { update-counters(journal-connection(), %changes) };
        $version++;
    }
    read-counters($connection, %definitions);
    write();
    my $sum = 0;
    my $start = now;
    for ^$iterations {
        if $kind eq 'read' { $sum += [+] read-counters($connection, %definitions).values }
        else { write() }
    }
    my $seconds = (now - $start).Num;
    my %final = read-counters($connection, %definitions);
    die 'Unexpected counter version' unless %final.elems == $keys && %final.values.all == $version;
    die 'Unexpected read checksum' if $kind eq 'read' && $sum != $iterations * $keys * $version;
    say to-json(%(:$kind, :$iterations, :$keys, :$seconds, :$sum, :$version), :!pretty);
}
