use RedSourcing;
use Red::DB;
use RedSourcing::Storage;
use RedSourcing::EventType;
unit module RedSourcing::Metrics::Projection;

# All journal-derived state belongs to an ordinary raw-record projection. No
# application classes or handlers are loaded, and APPLY never writes records.
projection MetricsProjection is export {
    has %.counts = %(events => 0, snapshots => 0, controls => 0, saga-failures => 0);
    has %.streams;
    has %.buckets;
    has %.snapshot-minutes;
    has %.attempts;
    has %.known;
    has %.outcomes;
    has %.runtime;
    has %.command-states;

    method journal-records(UInt :$from-id = 0, UInt :$through-id) {
        my $connection = get-RED-DB;
        my $pg = $connection.^mro.map(*.^name).first(* eq 'Red::Driver::Pg').defined;
        my @p = $pg ?? < $1 $2 > !! < ? ? >;
        my $control = $pg
            ?? q[jsonb_build_object('state', data -> 'state', 'action-id', data -> 'action-id')]
            !! q[json_object('state', json_extract(data, '$.state'), 'action-id', json_extract(data, '$."action-id"'))];
        my $snapshot = $pg
            ?? q[jsonb_build_object('saga-state', data -> 'saga-state')]
            !! q[json_object('saga-state', json_extract(data, '$."saga-state"'))];
        my $sql = q[SELECT id, class, mro, stream, version, created,
            CASE WHEN ] ~ event-type-sql($connection, 'Entity') ~ ' THEN ' ~ $snapshot
            ~ ' WHEN ' ~ event-type-sql($connection, 'RedSourcing::Saga::Control') ~ ' THEN ' ~ $control
            ~ ' ELSE NULL END AS data FROM red_sourcing_event WHERE id > ' ~ @p[0];
        my @binds = $from-id;
        if $through-id.defined { $sql ~= ' AND id <= ' ~ @p[1]; @binds.push($through-id) }
        storage-model-rows(StoredEvent, $sql ~ ' ORDER BY id', |@binds)
    }

    method APPLY(StoredEvent $row) {
        my $snapshot = $row.mro.contains('|Entity|');
        my $control = $row.mro.contains('|RedSourcing::Saga::Control|');
        my $metric = $snapshot ?? 'snapshots' !! $control ?? 'controls' !! 'events';
        %!counts{$metric}++;
        my $minute = $row.created.Instant.to-posix.head.Int div 60;
        %!buckets{$minute}{$metric}++;
        my %stream := (%!streams{$row.stream} //= %(
            events => 0, snapshots => 0, controls => 0, saga-failures => 0,
            events-since-snapshot => 0, latest-snapshot => ''));
        %stream{$metric}++;
        if $snapshot {
            %stream<events-since-snapshot> = 0;
            %stream<latest-snapshot> = $row.created.Str;
            %!snapshot-minutes{$row.stream}{$minute}++;
        } elsif !$control { %stream<events-since-snapshot>++ }
        return unless $control || $snapshot;
        my $state = $control ?? $row.data<state> !! $row.data<saga-state>;
        return unless $state ~~ Associative;
        my @actions = ($state<actions> // []).List;
        # Retain only the current action IDs/statuses, not historical payloads.
        %!runtime{$row.stream} = @actions.map({ %(id => .<id>, status => .<status>) }).Array;
        for @actions -> %action {
            my $key = $row.stream ~ '/' ~ %action<id>;
            my $previous = %!attempts{$key} // 0;
            my $attempt = %action<attempts> // 0;
            # Snapshots establish a baseline, not the time of past attempts.
            if $control && (%!known{$key}:exists) && $attempt > $previous && $attempt > 1 {
                %!buckets{$minute}<retries> += $attempt - ($previous max 1);
            }
            %!known{$key} = True;
            %!attempts{$key} = $previous max $attempt;
        }
        if $control && $row.class eq any('RedSourcing::Saga::StepFailed', 'RedSourcing::Saga::StepUncertain') {
            my $key = $row.stream ~ '/' ~ $row.data<action-id>;
            unless %!outcomes{$key}:exists {
                %!outcomes{$key} = True;
                %!counts<saga-failures>++;
                %stream<saga-failures>++;
            }
        }
    }

    # Commands are mutable operational records, not journal facts. Replace each
    # command's contribution by ID so refreshing its status cannot double count.
    method include-command(UInt :$id!, Str :$stream!, Str :$state!, UInt :$tries = 0) {
        %!command-states{$id} = %(:$stream, :$state, :$tries);
    }

    method report(:@instances = [], UInt :$minutes = 60, DateTime :$now = DateTime.now --> Hash) {
        die 'minutes must be between 1 and 1440' unless 1 <= $minutes <= 1440;
        my $end = $now.Instant.to-posix.head.Int div 60;
        my $start = $end - $minutes + 1;
        my @series = ($start..$end).map(-> $minute {
            %( :$minute, time => DateTime.new($minute * 60).Str,
                |<events snapshots controls retries>.map({ $_ => (%!buckets{$minute}{$_} // 0) }) )
        }).Array;
        my %entities;
        for @instances -> %instance {
            my $stream = %instance<stream>;
            my %item = %( :$stream, type => %instance<type>, kind => %instance<kind>,
                commands => 0, failures => 0, retries => 0, window-snapshots => 0,
                |<events snapshots controls saga-failures events-since-snapshot>.map({
                    $_ => (%!streams{$stream}{$_} // 0)
                }), latest-snapshot => (%!streams{$stream}<latest-snapshot> // '') );
            %item<window-snapshots> = [+] ($start..$end).map({ %!snapshot-minutes{$stream}{$_} // 0 });
            %entities{$stream} = %item;
        }
        my %totals = %(|%!counts, commands => 0, failures => 0, retries => 0,
            pending => 0, processing => 0, blocked => 0);
        for %!runtime.kv -> $stream, $actions {
            for $actions.List -> %action {
                my $retries = ((%!attempts{$stream ~ '/' ~ %action<id>} // 0) - 1) max 0;
                %totals<retries> += $retries;
                %entities{$stream}<retries> += $retries if %entities{$stream}:exists;
                %totals<blocked>++ if %action<status> eq 'blocked';
            }
        }
        for %!command-states.values -> %command {
            %totals<commands>++;
            my $failed = %command<state> eq 'Failed';
            %totals<failures>++ if $failed;
            %totals<pending>++ if %command<state> eq 'Pending';
            %totals<processing>++ if %command<state> eq 'Processing';
            my $retries = (%command<tries> - 1) max 0;
            %totals<retries> += $retries;
            if %entities{%command<stream>}:exists {
                my %item := %entities{%command<stream>};
                %item<commands>++;
                %item<failures>++ if $failed;
                %item<retries> += $retries;
            }
        }
        for %entities.values -> %entity {
            %entity<failure-total> = %entity<failures> + %entity<saga-failures>;
            %entity<failure-percent> = %entity<commands> ?? 100 * %entity<failures> / %entity<commands> !! 0;
            %entity<snapshots-per-minute> = %entity<window-snapshots> / $minutes;
        }
        my @identified = %entities.values.grep(*.<type>.chars);
        %(window-minutes => $minutes, as-of => $now.Str, series => @series, totals => %totals,
            events-per-minute => ([+] @series.map(*.<events>)) / $minutes,
            mean-events-per-entity => @identified ?? ([+] @identified.map(*.<events>)) / @identified.elems !! 0,
            entities => %entities.keys.sort.map({ %entities{$_} }).Array)
    }
}
