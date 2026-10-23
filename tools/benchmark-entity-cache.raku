#!/usr/bin/env raku
use RedSourcing;
use RedSourcing::Config;
use RedSourcing::Lifecycle;
use JSON::Fast;

class CacheBenchFact does Event { has Int $.id; has Int $.amount }
aggregate CacheBenchAggregate[:!auto-snapshot] {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    method APPLY(CacheBenchFact $e) { $!amount += $e.amount }
}
projection CacheBenchProjection[:!auto-snapshot] {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    method APPLY(CacheBenchFact $e where { .id == $!id }) { $!amount += $e.amount }
}
saga CacheBenchSaga[:!auto-snapshot] {
    has Int $.id is entity-id;
    method APPLY(CacheBenchFact $) { }
    method finish { self.^complete }
}

sub MAIN(Str :$kind where any(<aggregate projection saga>) = 'aggregate',
        Str :$lifecycle = 'Cached', UInt :$iterations where * > 0 = 200,
        UInt :$streams where * > 0 = 10, UInt :$events where * > 0 = 20) {
    my $*RED-DB = store-driver('SQLite', ':memory:');
    schema(StoredEvent, StoredCommand).create;
    my @types = CacheBenchAggregate, CacheBenchProjection, CacheBenchSaga;
    configure-lifecycles(@types.map({ .^name => { :$lifecycle } }).Hash);
    my $type = $kind eq 'aggregate' ?? CacheBenchAggregate
        !! $kind eq 'projection' ?? CacheBenchProjection !! CacheBenchSaga;
    my @proxies;
    for ^$streams -> $id {
        my $p = $type.^with-ids(:$id);
        if $kind eq 'saga' {
            $p.^create;
            my $view = $p.^load;
            $view.set-timeout("timer-$_", 3600, finish => \()) for ^$events;
        } else {
            my $a = CacheBenchAggregate.^with-ids(:$id);
            my $snapshot = $a.^create;
            CacheBenchFact.emit(:$id, :amount(1), :stream($snapshot.stream), :version($_ + 2)) for ^$events;
        }
        $p.^load;
        @proxies.push($p);
    }
    my $sum = 0;
    my $start = now;
    for ^$iterations -> $i {
        my $entity = @proxies[$i % $streams].^load;
        $sum += $kind eq 'saga' ?? $entity.^state<timers>.elems !! $entity.amount;
    }
    my $seconds = (now - $start).Num;
    die 'Unexpected reconstructed state' unless $sum == $iterations * $events;
    say to-json(%(:$kind, :$lifecycle, :$iterations, :$streams, :$events, :$sum, :$seconds), :!pretty);
}
