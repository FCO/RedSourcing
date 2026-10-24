# Worker for benchmark-microblog.py. All stores are disposable benchmark stores.
use RedSourcing;
use Red;
use RedSourcing::Config;
use RedSourcing::Storage;
use RedSourcing::Journal;
use Microblog::Domain;
use JSON::Fast;

my ($driver, $database, $workdir, $history) = @*ARGS;
my $admin;
my $schema;
if $driver eq 'Pg' {
    require ::('DB::Pg');
    $admin = ::('DB::Pg').new(:conninfo("dbname=$database"));
    $schema = 'rs_microblog_bench_' ~ $*PID;
    $admin.execute("CREATE SCHEMA $schema");
    red-defaults :default(store-driver('Pg', $database, :connection{
        dbh => ::('DB::Pg').new(:conninfo("dbname=$database options='-csearch_path=$schema -cclient_min_messages=warning'"),
            :converters(<DateTime UUID Geometric>)) }));
    schema(StoredEvent, StoredCommand).create;
} else {
    red-sourcing-defaults(:driver<SQLite>, :database($workdir.IO.add('benchmark.db').Str), :!flow-tracing);
}
LEAVE $admin.execute("DROP SCHEMA $schema CASCADE") if $admin.defined;
initialize-tweets;
initialize-application('benchmark');
seed('benchmark');
my @users = <ana bruno clara>.map({ User.^with-ids(:application-id<benchmark>, :user-id($_)) });
@users[0].follow(:author-id<clara>);
for ^$history.Int -> $i { @users[$i % 3].tweet(:text("history $i")) }
my $author = UserTweets.^with-ids(:application-id<benchmark>, :user-id<ana>);
my $feed = UserTimeline.^with-ids(:application-id<benchmark>, :user-id<ana>);
my %counts;
my $phase = '';
my role ObserveStatement[Str $sql] {
    method execute(|args) {
        %counts{$phase}<all>++;
        if $sql.contains('microblog_tweet') {
            %counts{$phase}<tweet-select>++ if $sql.uc.starts-with('SELECT');
            %counts{$phase}<tweet-insert>++ if $sql.uc.starts-with('INSERT');
        }
        callsame
    }
}
my role ObserveDriver {
    multi method prepare(Str $sql, |args) {
        my $statement = callsame;
        $statement does ObserveStatement[$sql] unless $statement ~~ ObserveStatement[$sql];
        $statement
    }
}
sub reply($data) { say to-json($data, :!pretty); $*OUT.flush }
sub run-work(UInt $publish, UInt $reads, Str $label) {
    my %seconds;
    $phase = 'publish';
    my $start = now;
    for ^$publish -> $i { @users[0].tweet(:text("$label publication $i")) }
    %seconds<publish> = (now - $start).Numeric;
    my %last;
    for <author timeline cursor> -> $kind {
        $phase = $kind;
        my $proxy = $kind eq 'author' ?? $author !! $feed;
        my $before = $kind eq 'cursor' ?? $feed.^load.page<next>.Int !! 0;
        $start = now;
        for ^$reads {
            %last = $proxy.^load.page(:$before);
            die 'Expected a full page' unless %last<tweets>.elems == 50;
        }
        %seconds{$kind} = (now - $start).Numeric;
    }
    %(seconds => %seconds, page => %last<tweets>.map({ [.<author>, .<text>] }).Array)
}
# Warm all measured paths before telling the orchestrator that setup is done.
run-work(5, 20, 'warmup');
reply(%(ready => True, red => Red.^ver.Str, rakudo => $*RAKU.compiler.version.Str,
    history => $history.Int + 3, driver => $driver));
for $*IN.lines -> $line {
    my %request = from-json($line);
    last if %request<operation> eq 'quit';
    if %request<operation> eq 'profile' {
        # Install counters only AFTER timing, avoiding instrumentation overhead.
        my $db = journal-connection();
        $db does ObserveDriver;
        %counts = ();
        run-work(3, 3, 'profile');
        reply(%(counts => %counts));
    } else {
        reply(run-work(%request<publish>.UInt, %request<reads>.UInt, %request<label>));
    }
}
