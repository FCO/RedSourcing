unit module RedSourcing::CLI::Output;

# Plain terminal output: keep complete names and escape control characters in
# persisted values. JSON output is handled separately by the CLI.
sub safe-text($value --> Str) {
    return '—' unless $value.defined;
    $value.Str.ords.map({
        $_ == 10 ?? "\n" !! $_ == 9 ?? '\t' !! $_ == 13 ?? '\r'
            !! ($_ < 32 || $_ == 127) ?? '\x[' ~ .fmt('%02X') ~ ']' !! .chr
    }).join
}

sub format-value($value, UInt :$indent = 0 --> Str) is export {
    my $prefix = ' ' x $indent;
    if $value ~~ Associative {
        return $prefix ~ '(empty object)' unless $value.elems;
        return $value.keys.sort.map(-> $key {
            my $item = $value{$key};
            my $label = $prefix ~ safe-text($key).subst("\n", '\n', :g) ~ ':';
            $item ~~ Associative | Positional
                ?? $label ~ "\n" ~ format-value($item, :indent($indent + 2))
                !! $label ~ ' ' ~ format-value($item).subst("\n", "\n$prefix  ", :g)
        }).join("\n");
    }
    if $value ~~ Positional {
        return $prefix ~ '(empty list)' unless $value.elems;
        return $value.map({
            $prefix ~ '- ' ~ format-value($_).subst("\n", "\n$prefix  ", :g)
        }).join("\n");
    }
    $prefix ~ safe-text($value).subst("\n", "\n$prefix", :g)
}

sub format-table(@headers, @rows --> Str) is export {
    return '(none)' unless @rows;
    my @cells = @rows.map({ .map({ safe-text($_).subst("\n", '\n', :g) }).Array }).Array;
    my @widths = @headers.kv.map(-> $i, $label {
        $label.chars max (@cells.map({ .[$i].chars }).max // 0)
    });
    my &line = -> @cells { @cells.kv.map(-> $i, $cell {
        $cell ~ (' ' x (@widths[$i] - $cell.chars))
    }).join('  ').trim-trailing };
    (line(@headers), @widths.map({ '-' x $_ }).join('  '), |@cells.map({ line($_) })).join("\n")
}

sub format-details(Str $title, $value --> Str) is export {
    $title ~ "\n" ~ format-value($value, :indent(2))
}

sub format-types(@items --> Str) is export {
    format-table(<KIND TYPE IDS COMMANDS>, @items.map({
        [.<kind>, .<name>, .<ids>.join(', '), .<commands>.join(', ')]
    }).Array)
}

sub format-entities(@items --> Str) is export {
    format-table(['KIND', 'TYPE', 'STREAM', 'VERSION', 'STATE SOURCE', 'STATUS'], @items.map({
        [.<kind>, .<type>, .<stream>, .<version>, .<state-source>, .<status>]
    }).Array)
}

sub format-events(@items, Bool :$details = False --> Str) is export {
    return @items ?? @items.map({ format-details("Event #{.<id>}", $_) }).join("\n\n") !! '(none)' if $details;
    format-table(<ID EVENT VERSION STREAM CREATED>, @items.map({
        [.<id>, .<class> // .<type>, .<version>, .<stream>, .<created>]
    }).Array)
}

sub format-commands(@items, Bool :$details = False --> Str) is export {
    return @items ?? @items.map({ format-details("Command #{.<id>}", $_) }).join("\n\n") !! '(none)' if $details;
    format-table(<ID STATE ENTITY METHOD TRIES STREAM ERROR>, @items.map({
        [.<id>, .<state>, .<entity>, .<method>, .<tries>, .<stream>, .<execution-error> // .<error>]
    }).Array)
}

sub format-inspection(%report --> Str) is export {
    my @sections;
    if %report<instance>:exists {
        @sections.push(format-details('Persisted entity state', %report<instance>));
    } else {
        @sections.push('Entity types' ~ "\n" ~ format-types(%report<types>.List));
        @sections.push('Entity instances' ~ "\n" ~ format-entities(%report<instances>.List));
    }
    @sections.push('Recent events' ~ "\n" ~ format-events(%report<events>.List));
    @sections.push('Recent commands' ~ "\n" ~ format-commands(%report<commands>.List));
    @sections.join("\n\n")
}

sub format-description(%record --> Str) is export {
    format-details('Entity definition', %(
        entity => %record<entity>, kind => %record<kind>, ids => %record<ids>,
        |(:description(%record<description>) if %record<description>:exists)))
        ~ "\n\nCommands\n" ~ (%record<commands>.elems ?? %record<commands>.map({
            my $text = .<declaration> // .<signature>;
            my $block = safe-text(.<name>) ~ "\n" ~ format-value($text, :indent(2));
            $block ~= "\n" ~ format-value(.<description>, :indent(2)) if .<description>:exists;
            if .<source>:exists {
                $block ~= "\n  Source: " ~ safe-text(.<source><file>) ~ ':' ~ .<source><line>;
            }
            if !(.<declaration>:exists) && $text.contains('where { ... }') {
                $block ~= "\n  Exact declaration unavailable; Raku hides predicate bodies in this signature.";
            }
            $block
        }).join("\n\n") !! '(none)')
}

sub format-saga-status(%report, Bool :$details = False --> Str) is export {
    my @sections = format-details('Saga status', %report{<entity stream status activity message as-of state-source version cursor reason>}:p.Hash);
    @sections.push(format-details('Progress', %(
        completed-actions => %report<completed-actions>, pending-actions => %report<pending-actions>.elems,
        failed-actions => %report<failed-actions>.elems, timers => %report<timers>.elems,
        compensations => %report<compensations>.elems,
        next-action => (%report<next-action><id> // '(none)'))));
    for 'Pending actions' => %report<pending-actions>, 'Failed actions' => %report<failed-actions> -> $section {
        @sections.push($section.key ~ "\n" ~ format-table(
            ['ID', 'STEP', 'KIND', 'TARGET', 'METHOD', 'STATE', 'ATTEMPTS', 'DUE AT', 'ERROR'],
            $section.value.map({
                [.<id>, .<step>, .<kind>, .<target>, .<method>, .<status>,
                    "{.<attempts>}/{.<retry><max>}", .<due-at>, .<error> // '']
            }).Array));
    }
    @sections.push("Timeouts\n" ~ format-table(['NAME', 'METHOD', 'DUE AT', 'READY'],
        %report<timers>.map({ [.<name>, .<method>, .<due-at>, .<ready>] }).Array));
    my $label = %report<compensations-active> ?? 'Compensation stack (active, next first)'
        !! 'Compensation stack (available on failure, next first)';
    @sections.push($label ~ "\n" ~ format-table(<ID METHOD ACTION>,
        %report<compensations>.map({ [.<id>, .<method>, .<action-id> // ''] }).Array));
    @sections.push(format-details('Domain state', %report<data>));
    @sections.push(format-details('Action history and saved compensation arguments',
        %(actions => %report<actions>, compensations => %report<compensations>, timers => %report<timers>))) if $details;
    @sections.join("\n\n")
}

sub format-metrics(%record --> Str) is export {
    format-details("Journal metrics (last {%record<window-minutes>} minutes)", %(
        as-of => %record<as-of>, totals => %record<totals>,
        events-per-minute => %record<events-per-minute>.fmt('%.2f'),
        mean-events-per-entity => %record<mean-events-per-entity>.fmt('%.2f')))
        ~ "\n\nBy entity\n" ~ format-table(['TYPE', 'STREAM', 'EVENTS', 'SNAPSHOTS', 'COMMANDS', 'FAILURES', 'RETRIES', 'EVENTS SINCE SNAPSHOT'],
            %record<entities>.map({
                [.<type>, .<stream>, .<events>, .<snapshots>, .<commands>, .<failure-total>, .<retries>, .<events-since-snapshot>]
            }).Array)
        ~ "\n\nActive minutes\n" ~ format-table(<TIME EVENTS SNAPSHOTS CONTROLS RETRIES>,
            %record<series>.grep({ [+] .{<events snapshots controls retries>} }).map({
                [.<time>, .<events>, .<snapshots>, .<controls>, .<retries>]
            }).Array)
}

sub format-saga-controller(%report --> Str) is export {
    return 'No active sagas.' unless %report<sagas>;
    "Advanced {%report<advanced>} sagas ({%report<failed>} failed).\n"
        ~ format-table(<TYPE STREAM STATUS ERROR>,
            %report<sagas>.map({ [.<type>, .<stream>, .<status>, .<error> // ''] }).Array)
}

sub format-work(%record --> Str) is export {
    my @items = %record<processed>.List;
    return 'No due commands.' unless @items;
    my $failed = @items.grep({ .<state> eq 'Failed' || .<execution-error>.defined }).elems;
    my $noun = @items.elems == 1 ?? 'command' !! 'commands';
    "Processed {@items.elems} $noun ($failed failed).\n" ~ format-commands(@items)
}
