-- Run with psql -v ON_ERROR_STOP=1 -f tools/migrate-pg-mro-array.sql.
-- Set search_path to the application's schema first. Stop application writers
-- before running; ALTER TABLE requires an exclusive lock. Restart every client
-- afterwards to discard prepared SQL/result metadata for the previous type.
BEGIN;
DO $migration$
DECLARE
    event_table regclass := 'red_sourcing_event'::regclass;
    mro_type oid;
BEGIN
    SELECT atttypid INTO mro_type FROM pg_attribute
      WHERE attrelid = event_table AND attname = 'mro' AND NOT attisdropped;
    IF mro_type IN ('text'::regtype, 'varchar'::regtype) THEN
        EXECUTE format(
            'ALTER TABLE %s ALTER COLUMN mro TYPE text[] USING string_to_array(trim(both ''|'' from mro), ''|'')',
            event_table);
    ELSIF mro_type IS DISTINCT FROM 'text[]'::regtype THEN
        RAISE EXCEPTION 'Unsupported or missing MRO column type: %', mro_type::regtype;
    END IF;
    EXECUTE format('CREATE INDEX IF NOT EXISTS red_sourcing_event_mro_gin ON %s USING GIN (mro)', event_table);
END
$migration$;
COMMIT;
