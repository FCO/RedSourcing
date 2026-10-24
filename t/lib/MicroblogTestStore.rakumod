use RedSourcing::Config;
unit module MicroblogTestStore;
my @cleanup;
END { try $_() for @cleanup }
sub test-store(Str $name) is export {
    my $database = %*ENV<RED_SOURCING_TEST_PG_DATABASE>;
    return store-driver('SQLite', ':memory:') unless $database.defined;
    require ::('DB::Pg');
    my $admin = ::('DB::Pg').new(:conninfo("dbname=$database"));
    my $schema = 'rs_microblog_' ~ $name ~ '_' ~ $*PID;
    $admin.execute("CREATE SCHEMA $schema");
    @cleanup.push({ $admin.execute("DROP SCHEMA $schema CASCADE") });
    store-driver('Pg', $database, :connection{
        dbh => ::('DB::Pg').new(:conninfo("dbname=$database options='-csearch_path=$schema -cclient_min_messages=warning'"),
            :converters(<DateTime UUID Geometric>)) })
}
