#!/usr/bin/env raku
use RedSourcing;
use RedSourcing::Config;
use RedSourcing::Storage;
use DB::Pg;
use JSON::Fast;

class MroBenchmarkRare does Event { has Int $.amount }
projection MroBenchmarkView {
    has Int $.total = 0;
    method APPLY(MroBenchmarkRare $event) { $!total += $event.amount }
}
# PGHOST/PGPORT/PGUSER select the server. Every run owns a disposable schema.
sub MAIN(Str :$database = 'postgres', UInt :$rows = 50000,
        UInt :$queries = 100, UInt :$appends = 100) {
    my $schema = 'rs_mro_bench_' ~ $*PID;
    my $admin = DB::Pg.new(:conninfo("dbname=$database"));
    $admin.execute("CREATE SCHEMA $schema");
    LEAVE $admin.execute("DROP SCHEMA $schema CASCADE");
    my $*RED-DB = store-driver('Pg', $database, :connection{
        dbh => DB::Pg.new(:conninfo("dbname=$database options='-csearch_path=$schema -cclient_min_messages=warning'"),
            :converters(<DateTime UUID Geometric>))
    });
    schema(StoredEvent, StoredCommand).create;
    my $native = storage-query($*RED-DB,
        q[SELECT atttypid::regtype::text AS type FROM pg_attribute
          WHERE attrelid = 'red_sourcing_event'::regclass AND attname = 'mro']).head<type> eq 'text[]';
    my $mro = $native
        ?? q[ARRAY[CASE WHEN g % 1000 = 0 THEN 'MroBenchmarkRare' ELSE 'MroBenchmarkNoise' END, 'Event']::text[]]
        !! q['|' || CASE WHEN g % 1000 = 0 THEN 'MroBenchmarkRare' ELSE 'MroBenchmarkNoise' END || '|Event|'];
    $*RED-DB.execute('INSERT INTO red_sourcing_event (class,mro,stream,version,created,data,event_schema_version) '
        ~ "SELECT CASE WHEN g % 1000 = 0 THEN 'MroBenchmarkRare' ELSE 'MroBenchmarkNoise' END, $mro, "
        ~ "'bulk-' || g, 1, now(), " ~ q['{"amount":1}'::jsonb]
        ~ ", 0 FROM generate_series(1,$rows) g");
    $*RED-DB.execute('VACUUM ANALYZE red_sourcing_event');
    my $predicate = $native ?? q[mro @> ARRAY[$1]::text[]] !! q[mro LIKE $1];
    my $argument = $native ?? 'MroBenchmarkRare' !! '%|MroBenchmarkRare|%';
    my $query = "SELECT count(*) AS count FROM red_sourcing_event WHERE $predicate";
    storage-query($*RED-DB, $query, $argument);
    my $start = now;
    my $count = 0;
    for ^$queries { $count += storage-query($*RED-DB, $query, $argument).head<count> }
    my $query-seconds = (now - $start).Num;
    MroBenchmarkView.^with-ids.^load;
    $start = now;
    my $replay-total = 0;
    for ^10 { $replay-total += MroBenchmarkView.^with-ids.^load.total }
    my $replay-seconds = (now - $start).Num;
    MroBenchmarkRare.emit(:amount(1), :stream<warm-append>, :version(1));
    $start = now;
    for ^$appends -> $i {
        MroBenchmarkRare.emit(:amount(1), :stream("append-$i"), :version(1));
    }
    my $append-seconds = (now - $start).Num;
    my $plan = storage-query($*RED-DB, "EXPLAIN (FORMAT JSON) $query", $argument).head{'QUERY PLAN'};
    my $index-bytes = $native ?? storage-query($*RED-DB,
        q[SELECT pg_relation_size('red_sourcing_event_mro_gin') AS bytes]).head<bytes> !! 0;
    say to-json(%(:$native, :$rows, :$queries, :$appends, :$count, :$replay-total,
        :$query-seconds, :$replay-seconds, :$append-seconds, :$index-bytes,
        plan => from-json($plan)), :!pretty);
}
