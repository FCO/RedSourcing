#!/usr/bin/env raku
use RedSourcing;
use RedSourcing::Config;
use JSON::Fast;

aggregate ClaimBenchmark {
    has Str $.key is entity-id;
    method APPLY(Event $) { }
    method answer(Int :$value!) is command { $value }
}
my $reads = 0;
my $claims = 0;
my role CountCommandSQL {
    multi method prepare(Str $sql, |args) {
        $reads++ if $sql.starts-with('SELECT') && $sql.contains('red_sourcing_command');
        $claims++ if $sql.starts-with('UPDATE red_sourcing_command SET state');
        callsame
    }
}
sub MAIN(UInt :$iterations where * > 0 = 100) {
    my $*RED-DB = store-driver('SQLite', ':memory:');
    $*RED-DB does CountCommandSQL;
    schema(StoredEvent, StoredCommand).create;
    my $aggregate = ClaimBenchmark.^with-ids(:key<claims>); $aggregate.^create;
    $aggregate.answer(:value(0));
    my @commands = (^$iterations).map({ $aggregate.answer(:value($_), :!sync) }).eager;
    ($reads, $claims) = 0, 0;
    my $sum = 0;
    my $start = now;
    $sum += .run for @commands;
    my $seconds = (now - $start).Num;
    die 'Unexpected claim results' unless $sum == $iterations * ($iterations - 1) div 2;
    say to-json(%(:$iterations, :$sum, :$seconds, command_selects => $reads, :$claims), :!pretty);
}
