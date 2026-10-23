use RedSourcing;
use Red::DB;
use RedSourcing::Storage;
use RedSourcing::EventType;
unit module RedSourcing::Flow::Projection;

# Raw journal rows keep the monitor independent of application class loading.
# No APPLY handler writes to a database or executes a domain handler.
projection FlowProjection is export {
    has %.connections;
    has %.saga-cursors;
    has UInt $.sequence = 0;
    has @!ordered-links;
    has %!outgoing;
    has %!incoming;

    method !index-links {
        return if @!ordered-links.elems == %!connections.elems;
        @!ordered-links = %!connections.values.sort(*.<sequence>);
        %!outgoing = (); %!incoming = ();
        for @!ordered-links -> %link {
            (%!outgoing{%link<source-kind>}{%link<source>} //= []).push(%link);
            (%!incoming{%link<target-kind>}{%link<target>} //= []).push(%link);
        }
    }

    method journal-records(UInt :$from-id = 0, UInt :$through-id) {
        my $pg = get-RED-DB.^mro.map(*.^name).first(* eq 'Red::Driver::Pg').defined;
        my @p = $pg ?? < $1 $2 > !! < ? ? >;
        my $cursor = $pg
            ?? q[jsonb_build_object('cursor', data -> 'cursor')]
            !! q[json_object('cursor', json_extract(data, '$.cursor'))];
        my $sql = q[SELECT id, class, mro, stream, version, created, command_id, action_id,
            event_schema_version, replay_cursor,
            CASE WHEN ] ~ event-type-sql(get-RED-DB, 'RedSourcing::Saga::Control') ~ ' THEN ' ~ $cursor
            ~ ' ELSE NULL END AS data FROM red_sourcing_event WHERE id > ' ~ @p[0];
        my @binds = $from-id;
        if $through-id.defined { $sql ~= ' AND id <= ' ~ @p[1]; @binds.push($through-id) }
        storage-model-rows(StoredEvent, $sql ~ ' ORDER BY id', |@binds)
    }

    method connect(Str $source-kind, Str $source, Str $target-kind, Str $target,
                   Str $relation, DateTime $created) {
        my $key = [$source-kind, $source, $target-kind, $target, $relation].raku;
        return if %!connections{$key}:exists;
        self!index-links;
        my %link = %( :$source-kind, :$source, :$target-kind, :$target,
            :$relation, recorded-at => $created.Str, sequence => ++$!sequence );
        %!connections{$key} = %link;
        @!ordered-links.push(%link);
        (%!outgoing{$source-kind}{$source} //= []).push(%link);
        (%!incoming{$target-kind}{$target} //= []).push(%link);
    }

    method APPLY(StoredEvent $row) {
        if $row.command-id.defined {
            self.connect('command', $row.command-id.Str, 'event', $row.id.Str, 'emitted', $row.created);
        } elsif $row.action-id.defined {
            self.connect('action', $row.action-id, 'event', $row.id.Str, 'emitted', $row.created);
        }
        self.connect('entity', $row.stream, 'event', $row.id.Str,
            $row.mro.contains('|Entity|') ?? 'checkpoint' !! 'published', $row.created);
        if $row.mro.contains('|RedSourcing::Saga::Control|') {
            my $cursor = $row.data<cursor> // 0;
            if $cursor > (%!saga-cursors{$row.stream} // 0) {
                self.connect('event', $cursor.Str, 'entity', $row.stream, 'consumed-saga', $row.created);
                %!saga-cursors{$row.stream} = $cursor;
            }
        }
    }

    method include-command(StoredCommand $row) {
        self.connect('command', $row.parent-command-id.Str, 'command', $row.id.Str,
            'submitted', $row.next-run) if $row.parent-command-id.defined;
        self.connect('action', $row.action-id, 'command', $row.id.Str,
            'submitted', $row.next-run) if $row.action-id.defined;
    }

    method links { self!index-links; @!ordered-links.Array }

    method find-links(Str :$source-kind, Str :$source, Str :$target-kind, Str :$target,
                      UInt :$limit = 500) {
        self!index-links;
        my $links = $source-kind.defined && $source.defined
            ?? (%!outgoing{$source-kind}{$source} // [])
            !! $target-kind.defined && $target.defined
                ?? (%!incoming{$target-kind}{$target} // []) !! @!ordered-links;
        my $matches = $links.reverse.Seq;
        $matches = $matches.grep(*.<source-kind> eq $source-kind) with $source-kind;
        $matches = $matches.grep(*.<source> eq $source) with $source;
        $matches = $matches.grep(*.<target-kind> eq $target-kind) with $target-kind;
        $matches = $matches.grep(*.<target> eq $target) with $target;
        $matches.head($limit).Array
    }
}
