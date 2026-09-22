use RedSourcing;
use JSON::Fast;
unit module RedSourcing::Web::Metrics;

# Read journal rows directly. No class loading, handlers, commands or adapters.
sub store-metrics(:@instances = [], UInt :$minutes = 60, DateTime :$now = DateTime.now) is export {
    die 'minutes must be between 1 and 1440' unless 1 <= $minutes <= 1440;
    my $end = $now.Instant.to-posix.head.Int div 60;
    my $start = $end - $minutes + 1;
    my @series = ($start..$end).map({
        %(minute => $_, time => DateTime.new($_ * 60).Str,
            events => 0, snapshots => 0, controls => 0, retries => 0)
    }).Array;
    my %entities;
    for @instances -> %instance {
        %entities{%instance<stream>} = %(
            stream => %instance<stream>, type => %instance<type>, kind => %instance<kind>,
            events => 0, snapshots => 0, controls => 0, commands => 0,
            failures => 0, retries => 0, saga-failures => 0, window-snapshots => 0,
            events-since-snapshot => 0, latest-snapshot => '',
        );
    }
    my %attempts;
    my %known;
    my %outcomes;
    my %runtime;
    my %totals = events => 0, snapshots => 0, controls => 0, commands => 0,
        failures => 0, retries => 0, saga-failures => 0, pending => 0, processing => 0, blocked => 0;
    for StoredEvent.^all.sort(*.id) -> $row {
        my $snapshot = $row.mro.contains('|Entity|');
        my $control = $row.mro.contains('|RedSourcing::Saga::Control|');
        my $metric = $snapshot ?? 'snapshots' !! $control ?? 'controls' !! 'events';
        %totals{$metric}++;
        my $bucket = ($row.created.Instant.to-posix.head.Int div 60) - $start;
        @series[$bucket]{$metric}++ if 0 <= $bucket < $minutes;
        if %entities{$row.stream}:exists {
            %entities{$row.stream}{$metric}++;
            if $snapshot {
                %entities{$row.stream}<events-since-snapshot> = 0;
                %entities{$row.stream}<latest-snapshot> = $row.created.Str;
                %entities{$row.stream}<window-snapshots>++ if 0 <= $bucket < $minutes;
            } elsif !$control { %entities{$row.stream}<events-since-snapshot>++ }
        }
        my %data = ($control || $snapshot) ?? from-json(to-json($row.data)) !! {};
        my $state = $control ?? %data<state> !! $snapshot ?? %data<saga-state> !! Nil;
        next unless $state ~~ Associative;
        %runtime{$row.stream} = $state;
        for ($state<actions> // []).List -> %action {
            my $key = $row.stream ~ '/' ~ %action<id>;
            my $previous = %attempts{$key} // 0;
            my $attempt = %action<attempts> // 0;
            # A snapshot establishes a baseline, not the time of past attempts.
            if $control && (%known{$key}:exists) && $attempt > $previous && $attempt > 1 {
                @series[$bucket]<retries> += $attempt - ($previous max 1)
                    if 0 <= $bucket < $minutes;
            }
            %known{$key} = True;
            %attempts{$key} = $previous max $attempt;
        }
        if $control && $row.class eq any('RedSourcing::Saga::StepFailed', 'RedSourcing::Saga::StepUncertain') {
            my $key = $row.stream ~ '/' ~ $row.data<action-id>;
            unless %outcomes{$key}:exists {
                %outcomes{$key} = True;
                %totals<saga-failures>++;
                %entities{$row.stream}<saga-failures>++ if %entities{$row.stream}:exists;
            }
        }
    }
    for %runtime.kv -> $stream, $state {
        for ($state<actions> // []).List -> %action {
            my $retries = ((%attempts{$stream ~ '/' ~ %action<id>} // 0) - 1) max 0;
            %totals<retries> += $retries;
            %entities{$stream}<retries> += $retries if %entities{$stream}:exists;
            %totals<blocked>++ if %action<status> eq 'blocked';
        }
    }
    for StoredCommand.^all -> $row {
        %totals<commands>++;
        my $failed = $row.state.Str eq 'Failed';
        %totals<failures>++ if $failed;
        %totals<pending>++ if $row.state.Str eq 'Pending';
        %totals<processing>++ if $row.state.Str eq 'Processing';
        my $retries = ($row.tries - 1) max 0;
        %totals<retries> += $retries;
        if %entities{$row.stream}:exists {
            %entities{$row.stream}<commands>++;
            %entities{$row.stream}<failures>++ if $failed;
            %entities{$row.stream}<retries> += $retries;
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
