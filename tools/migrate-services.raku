#!/usr/bin/env raku
use RedSourcing::Config;
use RedSourcing::Storage;
use RedSourcing::EventType;
use RedSourcing::Service::Lease;
use Red::DB;

sub MAIN(Str :$file, Str :$driver, Str :$database) {
    die 'Run this migration with application writers stopped' if (try $*RED-TRANSACTION-RUNNING) // False;
    red-sourcing-defaults(:$file, :$driver, :$database, :!initialize);
    my $db = get-RED-DB;
    my @columns = pg-driver($db)
        ?? storage-query($db, q[SELECT column_name AS name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'red_sourcing_command'])
        !! storage-query($db, 'PRAGMA table_info(red_sourcing_command)');
    die 'Create or select an existing RedSourcing store first' unless @columns;
    unless @columns.first(*.<name> eq 'service_context').defined {
        storage-query($db, 'ALTER TABLE red_sourcing_command ADD COLUMN service_context '
            ~ (pg-driver($db) ?? 'JSONB' !! 'TEXT'));
    }
    initialize-service-storage($db);
    say 'Managed service schema is ready';
}
