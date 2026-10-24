unit module RedSourcing::Service::Lease;
use RedSourcing::Storage;
use RedSourcing::Journal;
use RedSourcing::EventType;

sub parameters($db, UInt $n) is export {
    (pg-driver($db) ?? (1..$n).map({ '$' ~ $_ }) !! ('?' xx $n)).List
}
sub database-now($db --> Numeric) is export {
    storage-query($db, pg-driver($db)
        ?? 'SELECT EXTRACT(EPOCH FROM clock_timestamp())::double precision AS time'
        !! q[SELECT (julianday('now') - 2440587.5) * 86400.0 AS time]).head<time>.Numeric
}
sub initialize-service-storage($db) is export {
    storage-query($db, 'CREATE TABLE IF NOT EXISTS red_sourcing_service_lease ('
        ~ 'service_id TEXT PRIMARY KEY, definition TEXT NOT NULL, owner TEXT NOT NULL DEFAULT '
        ~ "'', generation BIGINT NOT NULL DEFAULT 0, expires DOUBLE PRECISION NOT NULL DEFAULT 0)");
    my @columns = pg-driver($db)
        ?? storage-query($db, q[SELECT column_name AS name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'red_sourcing_command'])
        !! storage-query($db, 'PRAGMA table_info(red_sourcing_command)');
    die 'Missing service_context column; apply the service migration before enabling services'
        unless @columns.first(*.<name> eq 'service_context').defined;
}
sub read-lease($db, Str $id) is export {
    my @p = parameters($db, 1);
    storage-query($db, 'SELECT * FROM red_sourcing_service_lease WHERE service_id = ' ~ @p[0], $id).head
}
sub assert-service-fence($db, %fence) is export {
    die 'Invalid service command context' unless %fence<service-id> ~~ Str && %fence<owner> ~~ Str
        && %fence<generation> ~~ Int && %fence<generation> > 0;
    my @p = parameters($db, 3);
    # A conditional no-op UPDATE holds the lease row through the caller's write
    # transaction on both drivers. Takeover cannot race a validated command.
    my @rows = storage-query($db, 'UPDATE red_sourcing_service_lease SET expires = expires'
        ~ ' WHERE service_id = ' ~ @p[0] ~ ' AND owner = ' ~ @p[1]
        ~ ' AND generation = ' ~ @p[2] ~ ' AND expires > '
        ~ (pg-driver($db) ?? 'EXTRACT(EPOCH FROM clock_timestamp())' !! "(julianday('now') - 2440587.5) * 86400.0")
        ~ ' RETURNING generation', %fence<service-id>, %fence<owner>, %fence<generation>);
    die 'Service ownership expired or superseded' unless @rows;
    True
}
sub acquire-lease($db, Str $id, Str $definition, Str $owner, Numeric $seconds) is export {
    my @p = parameters($db, 4);
    my $now = database-now($db);
    my @rows = storage-query($db, 'INSERT INTO red_sourcing_service_lease (service_id,definition,owner,generation,expires)'
        ~ ' VALUES (' ~ @p[0..2].join(',') ~ ',1,' ~ @p[3] ~ ') ON CONFLICT(service_id) DO UPDATE SET'
        ~ ' owner = excluded.owner, generation = red_sourcing_service_lease.generation + 1, expires = excluded.expires'
        ~ ' WHERE red_sourcing_service_lease.definition = excluded.definition AND red_sourcing_service_lease.expires <= '
        ~ $now.Str ~ ' RETURNING *', $id, $definition, $owner, $now + $seconds);
    return @rows.head if @rows;
    my $row = read-lease($db, $id);
    die 'Service identity collision' if $row.defined && $row<definition> ne $definition;
    $row.defined && $row<owner> eq $owner && $row<expires> > $now ?? $row !! Nil
}
sub renew-lease($db, %fence, Numeric $seconds --> Bool) is export {
    my @p = parameters($db, 5);
    my $now = database-now($db);
    so storage-query($db, 'UPDATE red_sourcing_service_lease SET expires = ' ~ @p[0]
        ~ ' WHERE service_id = ' ~ @p[1] ~ ' AND owner = ' ~ @p[2] ~ ' AND generation = ' ~ @p[3]
        ~ ' AND expires > ' ~ @p[4] ~ ' RETURNING generation', $now + $seconds,
        %fence<service-id>, %fence<owner>, %fence<generation>, $now)
}
sub release-lease($db, %fence) is export {
    my @p = parameters($db, 3);
    storage-query($db, "UPDATE red_sourcing_service_lease SET owner = '', expires = 0 WHERE service_id = "
        ~ @p[0] ~ ' AND owner = ' ~ @p[1] ~ ' AND generation = ' ~ @p[2],
        %fence<service-id>, %fence<owner>, %fence<generation>);
}
