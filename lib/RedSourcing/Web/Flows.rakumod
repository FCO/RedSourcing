use RedSourcing;
use RedSourcing::Flow;
use RedSourcing::Storage;
use RedSourcing::Web::HTML;
unit module RedSourcing::Web::Flows;

sub preview($value, UInt $depth = 0 --> Str) {
    return 'Not set' unless $value.defined;
    return '…' if $depth > 2;
    if $value ~~ Associative {
        my @keys = $value.keys.sort;
        return @keys.head(6).map({ "$_: " ~ preview($value{$_}, $depth + 1) }).join('; ')
            ~ (@keys.elems > 6 ?? '; …' !! '');
    }
    if $value ~~ Positional {
        return $value.head(3).map({ preview($_, $depth + 1) }).join(', ')
            ~ ($value.elems > 3 ?? ', …' !! '');
    }
    $value.Str.substr(0, 350) ~ ($value.Str.chars > 350 ?? '…' !! '')
}
sub timestamp($value --> Str) { $value.defined ?? DateTime.new($value.Str).utc.Str !! '' }

# Actions are persisted saga work, not methods discovered by running handlers.
sub flow-actions(%report --> Array) is export {
    my @actions;
    for (%report<instances> // []).List -> %instance {
        next unless %instance<kind> eq 'saga';
        for (%instance<data><saga-state><actions> // []).List -> %action {
            @actions.push(%(|%action, owner => %instance<stream>));
        }
    }
    @actions.Array
}

# Order by causality rather than record type. A closing edge in cyclic telemetry
# ends at an explicit reference card: it does not imply another execution.
sub causal-layout(%nodes, @edges --> Array) {
    my %visiting;
    my %done;
    my @ordered;
    my UInt $references = 0;
    sub visit(Str $id) {
        return if %done{$id};
        %visiting{$id} = True;
        for @edges.grep(*.<source> eq $id) -> %edge {
            my $target = %edge<target>;
            if %visiting{$target} {
                my $reference = 'reference:' ~ ++$references;
                %nodes{$reference} = %(|%nodes{$target}, id => $reference,
                    label => %nodes{$target}<label> ~ ' (reference)',
                    details => %(|%nodes{$target}<details>, reference => $target));
                %edge<target> = $reference;
            } else {
                visit($target);
            }
        }
        %visiting{$id}:delete;
        %done{$id} = True;
        @ordered.unshift($id);
    }
    visit($_) for %nodes.keys.sort;
    %nodes{$_}<stage> = 0 for %nodes.keys;
    for @ordered -> $id {
        for @edges.grep(*.<source> eq $id) -> %edge {
            %nodes{%edge<target>}<stage> max= %nodes{$id}<stage> + 1;
        }
    }
    @edges.Array
}

# Only stored records are used. Never resolve event classes or call handlers to
# guess subscriptions: cursor position is not proof that an event was consumed.
sub flow-report(%report, Str :$stream = '', Str :$focus = '', Bool :$internal = False, UInt :$limit = 200 --> Hash) is export {
    my @instances = (%report<instances> // []).List;
    my $action = $focus.starts-with('action:') ?? $focus.substr(7) !! '';
    my $owner = $action.chars ?? flow-actions(%report).first(*.<id> eq $action)<owner> // '' !! '';
    my $requested = $focus.starts-with('entity:') ?? $focus.substr(7) !! $stream;
    my $selected = $action.chars ?? $owner !! $requested.chars ?? $requested !! (@instances.first(*.<kind> eq 'saga')<stream> // @instances.head<stream> // '');
    my $selection = $action.chars ?? 'action:' ~ $action !! 'entity:' ~ $selected;
    my $root = @instances.first(*.<stream> eq $selected);
    return %(stream => $selected, focus => $selection, :$internal, nodes => [], edges => [], available => False, truncated => False) unless $root.defined;
    my $*REDSOURCING-FLOW-PROJECTION = try flow-projection();
    my %nodes;
    my %edges;
    my $truncated = False;
    my $available = True;
    my sub node(Str $id, Str $kind, Str $label, UInt $stage, Str $href = '', Str $status = '',
            Str :$at = '', Str :$time-label = '', :%details = {}) {
        return $id if %nodes{$id}:exists;
        if %nodes.elems >= $limit { $truncated = True; return '' }
        my $sequence = $kind eq any(<action service>) ?? $id.split('/').tail.UInt
            !! $kind eq any(<event snapshot command>) ?? $id.split(':').tail.UInt !! 0;
        %nodes{$id} = %(:$id, :$kind, :$label, :$stage, :$href, :$status, :$sequence,
            :$at, :$time-label, :%details);
        $id
    }
    my sub edge(Str $source, Str $target, Str $relation) {
        return unless $source.chars && $target.chars;
        %edges{"$source\0$target"} //= %(:$source, :$target, :$relation);
    }
    my sub links(*%options) {
        my $result = try flow-links(:limit($limit), |%options);
        unless $result.defined { $available = False; return [] }
        $truncated = True if $result.elems >= $limit;
        $result
    }
    # Bound row caches to this report. Seed stream history and action references
    # in batches, rather than rebuilding a SQL query for every displayed card.
    my @stream-rows = StoredEvent.^all.where(StoredEvent.journal-filter(:stream($selected)))
        .sort(-*.id).head($limit).Seq.Array;
    my @stream-commands = $root<kind> eq 'saga' ?? () !! StoredCommand.^all
        .grep(*.stream eq $selected).sort(-*.id).head($limit).Seq.Array;
    my $first = StoredEvent.^all.where(StoredEvent.journal-filter(:stream($selected), :version(1))).head;
    my %event-rows = @stream-rows.map({ .id => $_ });
    %event-rows{$first.id} = $first if $first.DEFINITE;
    my %command-rows = @stream-commands.map({ .id => $_ });
    my %command-ids;
    my %event-ids;
    my %action-ids;
    for @stream-rows -> $row {
        my %state = $row.mro.contains('|RedSourcing::Saga::Control|') ?? ($row.data<state> // {})
            !! ($row.data<saga-state> // {});
        for (%state<actions> // []).List -> %action {
            %command-ids{%action<row-id>} = True if %action<kind> eq 'command' && %action<row-id>;
            %event-ids{%action<source-event-id>} = True if %action<source-event-id>;
            %action-ids{%action<id>} = True;
        }
    }
    my @missing-commands = %command-ids.keys.grep({ !(%command-rows{$_}:exists) }).head($limit);
    %command-rows{.id} = $_ for storage-read-ids(StoredCommand, |@missing-commands);
    if $*REDSOURCING-FLOW-PROJECTION.DEFINITE {
        for %command-rows.keys -> $id {
            for $*REDSOURCING-FLOW-PROJECTION.find-links(:source-kind<command>, :source($id.Str), :$limit).List -> %link {
                %event-ids{%link<target>} = True if %link<target-kind> eq 'event';
            }
        }
        for %action-ids.keys -> $id {
            for $*REDSOURCING-FLOW-PROJECTION.find-links(:source-kind<action>, :source($id.Str), :$limit).List -> %link {
                %event-ids{%link<target>} = True if %link<target-kind> eq 'event';
            }
        }
    }
    my @missing-events = %event-ids.keys.grep({ !(%event-rows{$_}:exists) }).head($limit);
    %event-rows{.id} = $_ for storage-read-ids(StoredEvent, |@missing-events);
    my %checkpoints;
    my sub checkpoint($instance --> Str) {
        return '' unless $instance<state-event-id>;
        return timestamp($instance<state-event-at>) if $instance<state-event-at>.defined;
        %checkpoints{$instance<state-event-id>} //= do {
            my $id = $instance<state-event-id>;
            my $row = %event-rows{$id} //= StoredEvent.^all.where(StoredEvent.journal-filter(:$id)).head;
            $row.defined ?? timestamp($row.created) !! ''
        }
    }
    my sub entity-details($instance --> Hash) {
        %(identity => $instance<identity> // {}, version => $instance<version>,
            cursor => $instance<cursor>, state-source => $instance<state-source>,
            state => $instance<data> // {})
    }
    my $root-id = node('root', $root<kind>, $selected, 0, detail-url('stream', $selected), $root<status> // '',
        :at(checkpoint($root)), :time-label<Checkpoint>, :details(entity-details($root)));
    my %event-seen;
    my sub event(UInt $id, Str $parent = '', Str $relation = 'emitted', UInt :$stage = 3) {
        if %event-seen{$id}:exists {
            my $key = %nodes{"event:$id"}:exists ?? "event:$id" !! '';
            edge($parent, $key, $relation) if $parent.chars;
            return $key;
        }
        %event-seen{$id} = True;
        if %nodes.elems >= $limit { $truncated = True; return '' }
        my $row = %event-rows{$id} //= StoredEvent.^all.where(StoredEvent.journal-filter(:$id)).head;
        return '' unless $row.defined;
        # Keep domain flow legible; raw controls remain in the journal detail.
        return '' if $row.mro.contains('|RedSourcing::Saga::Control|');
        return '' if !$internal && $row.mro.contains('|Entity|');
        my $key = node("event:$id", $row.mro.contains('|Entity|') ?? 'snapshot' !! 'event',
            "#{$row.id} {$row.class}", $stage, detail-url('event', $id),
            :at(timestamp($row.created)), :time-label<Emitted>,
            :details(%(stream => $row.stream, version => $row.version, payload => $row.data)));
        edge($parent, $key, $relation) if $parent.chars;
        for links(target-kind => 'event', target => $id.Str).List -> %link {
            # Publishing stream metadata is already shown on event detail.
            next unless %link<source-kind> eq 'command';
            command(%link<source>.UInt);
        }
        for links(source-kind => 'event', source => $id.Str).List -> %link {
            next unless %link<target-kind> eq 'entity';
            my $consumer = @instances.first(*.<stream> eq %link<target>);
            my $kind = $consumer<kind> // (%link<relation>.starts-with('applied-')
                ?? %link<relation>.substr(8) !! 'saga');
            next if !$internal && $kind eq 'aggregate' && %link<target> eq $row.stream;
            my $checkpoint = checkpoint($consumer);
            my $target = node('consumer:' ~ %link<target>, $kind, %link<target>, 4,
                detail-url('stream', %link<target>), $consumer<status> // '',
                :at($checkpoint || timestamp(%link<recorded-at>)),
                :time-label($checkpoint ?? 'Checkpoint' !! 'Observed'),
                :details(entity-details($consumer)));
            edge($key, $target, %link<relation>.starts-with('applied-') ?? 'applied' !! 'consumed');
        }
        $key
    }
    my %command-seen;
    my sub command(UInt $id, Str $parent = '') {
        if %command-seen{$id}:exists {
            my $key = %nodes{"command:$id"}:exists ?? "command:$id" !! '';
            edge($parent, $key, 'submitted') if $parent.chars;
            return $key;
        }
        %command-seen{$id} = True;
        if %nodes.elems >= $limit { $truncated = True; return '' }
        my $row = %command-rows{$id} //= StoredCommand.^all.grep(*.id == $id).head;
        return '' unless $row.defined;
        my $key = node("command:$id", 'command', "#$id {$row.entity}.{$row.method}", 2,
            detail-url('command', $id), $row.state.Str,
            :at(timestamp($row.next-run)), :time-label<Scheduled>,
            :details(%(stream => $row.stream, identity => $row.entity-ids, arguments => $row.data,
                tries => $row.tries, result => $row.result, error => $row.error)));
        edge($parent, $key, 'submitted') if $parent.chars;
        for links(source-kind => 'command', source => $id.Str).List -> %link {
            event(%link<target>.UInt, $key) if %link<target-kind> eq 'event';
            command(%link<target>.UInt, $key) if %link<target-kind> eq 'command';
        }
        $key
    }
    event($first.id, $root-id, 'created', :stage(0)) if $first.defined;
    # Controls retain attempted child row IDs, including earlier retry records.
    my %actions;
    for @stream-rows -> $row {
        my %state = $row.mro.contains('|RedSourcing::Saga::Control|') ?? ($row.data<state> // {})
            !! ($row.data<saga-state> // {});
        for (%state<actions> // []).List -> %action {
            my $action-id = %action<id>;
            my $key = node("action:$action-id", %action<kind> eq 'service' ?? 'service' !! 'action',
                "%action<step> → %action<target>.%action<method>", 1, detail-url('stream', $selected), %action<status>,
                :at(timestamp($row.created)), :time-label<Recorded>, :details(%action));
            # Newest state supplies details; the earliest retained occurrence
            # supplies the recording time. This is not an execution timestamp.
            %nodes{$key}<at> = timestamp($row.created) if $key.chars;
            edge($root-id, $key, 'scheduled') if $internal
                || !(%action<source-event-id> || %action<source-action-id> || %action<undo-entry>);
            if %action<source-event-id> {
                my $source = event(%action<source-event-id>.UInt, :stage(0));
                edge($source, $key, 'triggered');
            }
            edge('action:' ~ %action<source-action-id>, $key, 'continued') if %action<source-action-id>;
            edge('action:' ~ %action<undo-entry>, $key, 'compensates') if %action<undo-entry>;
            command(%action<row-id>.UInt, $key) if %action<kind> eq 'command' && %action<row-id>;
            next if %actions{$action-id}++;
            for links(source-kind => 'action', source => $action-id).List -> %link {
                event(%link<target>.UInt, $key) if %link<target-kind> eq 'event';
            }
        }
    }
    unless $root<kind> eq 'saga' {
        command($_.id, $root-id) for @stream-commands;
        for links(target-kind => 'entity', target => $selected).List -> %link {
            event(%link<source>.UInt) if %link<source-kind> eq 'event';
        }
        for links(source-kind => 'entity', source => $selected).List -> %link {
            event(%link<target>.UInt, $root-id, %link<relation>) if %link<target-kind> eq 'event';
        }
    }
    my @edges = %edges.values.grep({ (%nodes{.<source>}:exists) && (%nodes{.<target>}:exists) }).Array;
    unless $internal {
        # Publication and self-consumption are still available in stored links.
        # Prefer the command as emitter when that causal evidence exists.
        my $emitted = @edges.grep({ .<source>.starts-with('command:') && .<target>.starts-with('event:') })>>.<target>.Set;
        my $submitted = @edges.grep({ .<source>.starts-with('command:') || .<source>.starts-with('action:') })>>.<target>.Set;
        my $reacted = @edges.grep({ .<relation> eq 'triggered' })>>.<source>.Set;
        @edges = @edges.grep({
            !(.<source> eq 'root' && ($emitted{.<target>} || $submitted{.<target>}))
                && !(.<target> eq 'consumer:' ~ $selected && $reacted{.<source>})
        }).Array;
        my $connected = @edges.map({ .<source>, .<target> }).flat.Set;
        %nodes<root>:delete if !($connected<root>) && %nodes.elems > 1;
        for %nodes.keys.grep(*.starts-with('consumer:')) -> $id {
            %nodes{$id}:delete unless $connected{$id};
        }
    }
    if $action.chars {
        my %reachable = 'action:' ~ $action => True;
        my @pending = 'action:' ~ $action;
        while @pending {
            my $id = @pending.shift;
            for @edges.grep(*.<source> eq $id)>>.<target> -> $target {
                next if %reachable{$target}++;
                @pending.push($target);
            }
        }
        %nodes{$_}:delete for %nodes.keys.grep({ !%reachable{$_} });
        @edges = @edges.grep({ %reachable{.<source>} && %reachable{.<target>} }).Array;
    }
    @edges = causal-layout(%nodes, @edges);
    %(:stream($selected), focus => $selection, :$internal,
        nodes => %nodes.values.sort({ $^a<stage> <=> $^b<stage>
            || $^a<sequence> <=> $^b<sequence> || $^a<id> cmp $^b<id> }).Array,
        edges => @edges, :$available, :$truncated)
}

sub flow-view(%flow, :@instances = [] --> Str) is export {
    my %labels = aggregate => 'Aggregates', projection => 'Projections', saga => 'Sagas', other => 'Other entities';
    my $known-kinds = <aggregate projection saga>.Set;
    my $options = <aggregate projection saga other>.map(-> $kind {
        my @items = @instances.grep({
            $kind eq 'other' ?? !$known-kinds{.<kind> // ''}
                !! (.<kind> // '') eq $kind
        }).sort(*.<stream>);
        @items.elems ?? '<optgroup label="' ~ %labels{$kind} ~ '">'
            ~ @items.map({ '<option value="' ~ escape-html('entity:' ~ .<stream>) ~ '"'
                ~ ('entity:' ~ .<stream> eq %flow<focus> ?? ' selected' !! '')
                ~ '>' ~ escape-html(.<stream>) ~ '</option>' }).join ~ '</optgroup>' !! ''
    }).join;
    my @actions = flow-actions(%(instances => @instances)).sort({ $^a<owner> cmp $^b<owner> || $^a<id> cmp $^b<id> });
    $options ~= '<optgroup label="Actions">' ~ @actions.map({
        '<option value="' ~ escape-html('action:' ~ .<id>) ~ '"'
            ~ ('action:' ~ .<id> eq %flow<focus> ?? ' selected' !! '') ~ '>'
            ~ escape-html((.<kind> eq 'command' ?? 'Command' !! 'Service') ~ ' · '
                ~ .<step> ~ ' → ' ~ .<target> ~ '.' ~ .<method> ~ ' · ' ~ .<owner> ~ ' · ' ~ .<id>)
            ~ '</option>'
    }).join ~ '</optgroup>' if @actions;
    my $stages = (%flow<nodes>.map(*.<stage>).max // 0) + 1;
    '<section id="flow-view" data-flow-focus="' ~ escape-html(%flow<focus> // '')
        ~ '" data-flow-internal="' ~ (%flow<internal> ?? '1' !! '0') ~ '" hx-sync="#flow-view:drop" hx-get="/monitor/flow-fragment?focus=' ~ query-value(%flow<focus> // '')
        ~ '&amp;internal=' ~ (%flow<internal> ?? '1' !! '0')
        ~ '" hx-trigger="redsourcing:update from:body" hx-swap="outerMorph"><div class="page-heading"><div>'
        ~ '<p class="eyebrow">REDSOURCING / FLOWS</p><h1>Follow the work<span class="heading-dot">.</span></h1>'
        ~ '<p class="muted">Recorded actions, emitted facts and the entities that applied them.</p></div></div>'
        ~ '<form class="flow-filter" hx-sync="#flow-view:replace" hx-get="/monitor/flow-fragment" hx-target="#flow-view" hx-swap="outerMorph">'
        ~ '<label for="flow-stream">Focus</label><select id="flow-stream" name="focus">'
        ~ $options ~ '</select><button class="button secondary">Show flow</button><label class="flow-internal"><input type="checkbox" name="internal" value="1"'
        ~ (%flow<internal> ?? ' checked' !! '') ~ '> Show internal links and snapshots</label></form>'
        ~ '<p class="flow-focus">Focus: ' ~ name-link(%flow<stream>, detail-url('stream', %flow<stream>)) ~ '</p>'
        ~ '<p class="flow-note">Edges represent stored evidence. Events written before tracing was enabled, and entities never observed by tracing, have incomplete connections. Cards follow recorded causality from left to right. Causes may precede the focused entity; selecting an action shows its downstream work. Redundant publication, own-aggregate replay and snapshot links are hidden by default. Applying a projection is recorded when the application actually loads/replays it.</p>'
        ~ (!%flow<available> ?? '<p class="notice">Flow tracing is not initialized. Enable flow-tracing in the application configuration to record new connections.</p>' !! '')
        ~ (%flow<truncated> ?? '<p class="notice">This view reached its record limit. Open a linked entity to inspect a smaller flow.</p>' !! '')
        ~ (!%flow<nodes>.elems ?? '<p class="empty-value">No matching persisted entity or action. Choose recorded work from the selector.</p>' !! '')
        ~ '<div class="flow-workspace"><div class="flow-scroll" tabindex="0" aria-label="Workflow diagram"><div class="flow-board" style="--flow-columns:' ~ $stages ~ '"><svg class="flow-connectors" aria-hidden="true"></svg>'
        ~ (^$stages).map(-> $stage {
            '<section class="flow-stage" style="grid-column:' ~ (2 * $stage + 1) ~ '"><h2>' ~ ($stage == 0 ?? 'Cause' !! 'Step ' ~ $stage) ~ '</h2>'
                ~ %flow<nodes>.grep(*.<stage> == $stage).map(-> %node {
                    my $count = %flow<edges>.grep(*.<source> eq %node<id>).elems;
                    '<div class="flow-card"><a class="flow-node" data-flow-node="' ~ escape-html(%node<id>)
                        ~ '" data-flow-stage="' ~ $stage ~ '" href="' ~ escape-html(%node<href>)
                        ~ '" aria-label="' ~ escape-html(%node<label>) ~ '" title="' ~ escape-html(%node<label>) ~ '">'
                        ~ '<div class="flow-node-heading">' ~ pill(%node<kind> eq 'action' ?? 'command action' !! %node<kind> eq 'service' ?? 'service action' !! %node<kind>, %node<kind>)
                        ~ (%node<at>.chars ?? '<time datetime="' ~ escape-html(%node<at>) ~ '" title="'
                            ~ escape-html(%node<time-label> ~ ': ' ~ %node<at>) ~ '"><span>'
                            ~ escape-html(%node<time-label>) ~ '</span> '
                            ~ escape-html(%node<at>.substr(5, 14).subst('T', ' ')) ~ '</time>'
                            !! '<span class="flow-time-unknown">Time unavailable</span>') ~ '</div>'
                        ~ '<strong>' ~ escape-html(%node<label>) ~ '</strong>'
                        ~ (%node<status>.chars ?? pill(%node<status>, %node<status>.lc) !! '')
                        ~ '<small>' ~ $count ~ ' recorded outgoing links</small></a>'
                        ~ '<div class="flow-node-details" hidden><strong>' ~ escape-html(%node<label>) ~ '</strong>'
                        ~ '<p class="muted">' ~ escape-html(%node<at>.chars
                            ?? %node<time-label> ~ ': ' ~ %node<at> !! 'No persisted timestamp') ~ '</p><dl>'
                        ~ %node<details>.keys.sort.map({ '<div><dt>' ~ escape-html($_.subst('-', ' ', :g).tc)
                            ~ '</dt><dd>' ~ escape-html(preview(%node<details>{$_})) ~ '</dd></div>' }).join
                        ~ '</dl><p class="muted">Open the card for full details.</p></div></div>'
                }).join ~ '</section>'
        }).join ~ %flow<edges>.map({ '<span hidden data-flow-source="' ~ escape-html(.<source>)
            ~ '" data-flow-target="' ~ escape-html(.<target>) ~ '" data-flow-relation="' ~ escape-html(.<relation>) ~ '"></span>' }).join
        ~ '</div></div><aside class="flow-preview" aria-label="Card preview"><div class="flow-preview-heading">'
        ~ '<h2>Card preview</h2><button class="flow-preview-close" type="button" aria-label="Clear card preview" hidden>×</button></div>'
        ~ '<p class="flow-preview-empty">Hover or focus a card to inspect its details here. The preview stays outside the diagram.</p>'
        ~ '<div id="flow-inspector" class="flow-inspector" role="region" aria-label="Selected card details" hidden></div>'
        ~ '</aside></div><section class="panel"><div class="panel-heading"><h2>Recorded connections</h2><span>'
        ~ %flow<edges>.elems ~ ' links</span></div><div class="table-scroll"><table><thead><tr><th>From</th><th>Relation</th><th>To</th></tr></thead><tbody>'
        ~ %flow<edges>.map(-> %edge {
            my %source = %flow<nodes>.first(*.<id> eq %edge<source>);
            my %target = %flow<nodes>.first(*.<id> eq %edge<target>);
            '<tr><td>' ~ name-link(%source<label>, %source<href>) ~ '</td><td>' ~ escape-html(%edge<relation>)
                ~ '</td><td>' ~ name-link(%target<label>, %target<href>) ~ '</td></tr>'
        }).join ~ '</tbody></table></div></section></section>'
}
