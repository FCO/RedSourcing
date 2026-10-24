#!/usr/bin/env raku
# Compare the same executor query boundary with and without proxy dispatch.
use lib $?FILE.IO.parent.parent.add('examples/microblog/lib').Str;
use RedSourcing;
use Red;
use RedSourcing::Service;
use RedSourcing::Config;
use RedSourcing::Journal;
use Microblog::Domain;
use JSON::Fast;

my $context-ready = Promise.new;
projection ProxyBenchmarkHost {
    has Str $.application-id is entity-id;
    method APPLY(UserRegistered $e where { .application-id eq $!application-id }) { }
    method serve(ServiceContext $ctx) is service {
        start { $ctx.ready; $context-ready.keep($ctx); await $ctx.stopping }
    }
}
my %observed;
my role ObservedStatement[Str $sql] {
    method execute(|args) {
        my $tag = try $*PROXY-BENCH-PROFILE;
        if $tag.defined {
            %observed{$tag}<all>++;
            %observed{$tag}<tweets>++ if $sql.contains('microblog_tweet');
        }
        callsame
    }
}
my role ObservedDriver {
    multi method prepare(Str $sql, |args) {
        my $stmt = callsame;
        $stmt does ObservedStatement[$sql] unless $stmt ~~ ObservedStatement[$sql];
        $stmt
    }
}
sub MAIN(Str :$driver = 'SQLite', Str :$database = 'postgres', Str :$output!,
        UInt :$history = 150, UInt :$reads = 20, UInt :$rounds = 5) {
    die 'Use SQLite or Pg' unless $driver eq any(<SQLite Pg>);
    die 'history >= 150 and nonzero reads/rounds required' unless $history >= 150 && $reads && $rounds;
    my $file = $*TMPDIR.add('proxy-query-bench-' ~ $*PID ~ '-' ~ (2**63).rand.Int ~ '.db');
    LEAVE $file.unlink if $file.e;
    my $admin;
    my $schema = 'rs_proxy_query_bench_' ~ $*PID;
    if $driver eq 'Pg' {
        require ::('DB::Pg');
        $admin = ::('DB::Pg').new(:conninfo("dbname=$database"));
        $admin.execute("CREATE SCHEMA $schema");
        red-defaults :default(store-driver('Pg', $database, :connection{
            dbh => ::('DB::Pg').new(:conninfo("dbname=$database options='-csearch_path=$schema -cclient_min_messages=warning'"),
                :converters(<DateTime UUID Geometric>)) }));
        schema(StoredEvent, StoredCommand).create;
    } else {
        red-sourcing-defaults(:driver<SQLite>, :database($file.Str), :!flow-tracing);
    }
    LEAVE $admin.execute("DROP SCHEMA $schema CASCADE") if $admin.defined;
    initialize-tweets; initialize-application('benchmark'); seed('benchmark');
    my @users = <ana bruno clara>.map({ User.^with-ids(:application-id<benchmark>, :user-id($_)) });
    for ^$history -> $i { @users[$i % 3].tweet(:text("history $i")) }
    my $runtime = ServiceRuntime.new(:poll-interval(.05), :stop-grace(1)).initialize;
    LEAVE $runtime.shutdown;
    my $host = ProxyBenchmarkHost.^with-ids(:application-id<benchmark>);
    $host.^start-service('serve', :idle-timeout(3600));
    my $controller = $runtime.run;
    await Promise.anyof($context-ready, Promise.in(15));
    die 'Context readiness timed out' unless $context-ready.status == Kept;
    my $ctx = $context-ready.result;
    my %targets = list => Directory.^with-ids(:application-id<benchmark>),
        page => UserTweets.^with-ids(:application-id<benchmark>, :user-id<ana>);
    sub invocation(Str $mode, Str $kind --> Callable) {
        my $proxy = %targets{$kind};
        given $mode {
            when 'legacy-json' { -> { $ctx.read($proxy, :method($kind)) } }
            when 'typed-direct' { -> { $ctx.executor.context-query($ctx, $proxy, $kind, \()) } }
            default { $ctx.bind({ $proxy."$kind"() }) }
        }
    }
    my @modes = <legacy-json typed-direct proxy>;
    my %expected;
    for <list page> -> $kind {
        for @modes -> $mode {
            my &call = invocation($mode, $kind);
            for ^10 {
                my $result = call();
                %expected{$kind} //= $result;
                die "Result mismatch: $mode/$kind" unless $result eqv %expected{$kind};
            }
        }
    }
    my %samples;
    my @orders = [<legacy-json typed-direct proxy>], [<proxy typed-direct legacy-json>],
        [<typed-direct legacy-json proxy>], [<legacy-json proxy typed-direct>], [<proxy legacy-json typed-direct>];
    for ^$rounds -> $round {
        for @orders[$round % @orders.elems].List -> $mode {
            for <list page> -> $kind {
                my &call = invocation($mode, $kind);
                my $start = now;
                for ^$reads { call() }
                my $seconds = (now - $start).Numeric;
                (%samples{$mode}{$kind} //= []).push($seconds);
                say "$driver round {$round + 1} $mode/$kind: $seconds";
                $*OUT.flush;
            }
        }
    }
    $runtime.with-store({ journal-connection() does ObservedDriver });
    for @modes -> $mode {
        for <list page> -> $kind {
            my &call = invocation($mode, $kind);
            for ^3 {
                $runtime.context-work({ my $*PROXY-BENCH-PROFILE = "$mode/$kind"; call() });
            }
        }
    }
    my %milliseconds;
    for @modes -> $mode {
        for <list page> -> $kind {
            my @sorted = %samples{$mode}{$kind}.sort;
            my $middle = @sorted.elems div 2;
            my $median = @sorted.elems % 2 ?? @sorted[$middle] !! (@sorted[$middle - 1] + @sorted[$middle]) / 2;
            %milliseconds{$mode}{$kind} = $median * 1000 / $reads;
        }
    }
    my %result = :$driver, :$history, :$reads, :$rounds, red => Red.^ver.Str,
        rakudo => $*RAKU.compiler.version.Str, medians_ms => %milliseconds,
        samples_seconds => %samples, statement_counts_for_three_calls => %observed,
        methodology => 'Same live executor and fixed store; warmed, rotating mode order; measured from caller including queue and generation check. typed-direct and proxy share typed copy and query implementation; legacy-json keeps the existing helper contract. SQL counted only afterwards inside a tagged executor operation, excluding controller polling.';
    $output.IO.spurt(to-json(%result, :pretty));
    $host.^stop-service('serve');
    my $until = now + 10;
    until $host.^service-status('serve')<phase> eq 'stopped' { die 'Stop timed out' if now > $until; await Promise.in(.02) }
    $runtime.shutdown; await $controller;
    say to-json(%milliseconds, :!pretty);
}
