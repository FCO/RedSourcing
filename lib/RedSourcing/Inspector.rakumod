use RedSourcing;
use JSON::Fast;
use RedSourcing::Flow;
use Red::DB;
use RedSourcing::Storage;
use RedSourcing::EventType;
unit class RedSourcing::Inspector;

# No web dependency and no commands/advance calls: inspecting cannot run effects.
# Register types explicitly so persisted names are never dynamically imported by a UI.
has %!types;
has %!proxies;
has Bool $.stored-only = False;

# Database-only inspection never resolves or instantiates persisted class names.
# Domain APPLY code is not stored in the journal, so state is shown at its last
# checkpoint. Saga control records already contain complete state and values.
method !stored-view {
    my %streams;
    # Transfer the latest head and latest restorable state per stream, not every
    # historical payload. Unknown event classes remain strictly data-only.
    my @heads = storage-query(get-RED-DB, q[
        WITH heads AS (SELECT stream, MAX(id) AS id FROM red_sourcing_event GROUP BY stream),
        states AS (SELECT stream, MAX(id) AS id FROM red_sourcing_event
            WHERE ] ~ event-type-sql(get-RED-DB, 'Entity') ~ ' OR '
            ~ event-type-sql(get-RED-DB, 'RedSourcing::Saga::Control') ~ q[ GROUP BY stream)
        SELECT head.stream AS head_stream, head.id AS head_id, head.version AS head_version, state.*
        FROM heads JOIN red_sourcing_event head ON head.id = heads.id
        LEFT JOIN states ON states.stream = heads.stream
        LEFT JOIN red_sourcing_event state ON state.id = states.id ORDER BY head.id]);
    for @heads -> %head {
        my $stream = %head<head_stream>;
        my %item := (%streams{$stream} //= %( :$stream, kind => 'stream',
            type => '', ids => [], commands => [], data => {}, state-source => 'unavailable'));
        %item<latest-event-id> = %head<head_id>;
        %item<head-version> = %head<head_version>;
        next unless %head<id>.defined;
        my %data = %head.grep({ !.key.starts-with('head_') }).Hash;
        my $row = StoredEvent.^new-from-data(%data);
        %item<state-event-at> = $row.created.Str;
        if $row.mro.contains('|RedSourcing::Saga::Control|') {
            my %data = $row.data.Hash;
            %item<type> = $row.stream.split(': ').head;
            %item<kind> = 'saga';
            %item<data> = %(|%data<values>, saga-state => %data<state>);
            %item<status> = %data<state><status>;
            %item<cursor> = %data<cursor>;
            %item<state-source> = 'control';
            %item<state-event-id> = $row.id;
            %item<version> = $row.version;
        } elsif $row.mro.contains('|Entity|') {
            %item<type> = $row.class;
            %item<data> = $row.data.Hash;
            %item<kind> = (%item<data><saga-state>:exists) ?? 'saga'
                !! $row.replay-cursor.defined ?? 'projection' !! 'aggregate';
            %item<status> = %item<data><saga-state><status> if %item<kind> eq 'saga';
            %item<cursor> = $row.replay-cursor // $row.id;
            %item<state-source> = 'snapshot';
            %item<state-event-id> = $row.id;
            %item<version> = $row.version;
        }
    }
    for storage-query(get-RED-DB,
            'SELECT stream, entity, entity_ids, method FROM red_sourcing_command ORDER BY id') -> %row {
        my $stream = %row<stream>;
        my %identity = %row<entity_ids> ~~ Str ?? from-json(%row<entity_ids>) !! %row<entity_ids>.Hash;
        my %item := (%streams{$stream} //= %( :$stream, kind => 'entity',
            type => %row<entity>, ids => [], commands => [], data => {}, state-source => 'unavailable'));
        %item<type> ||= %row<entity>;
        %item<ids> = %identity.keys.sort.Array;
        %item<identity> = %identity;
        %item<commands>.push(%row<method>) unless %row<method> eq any(%item<commands>.List);
    }
    my %types;
    for %streams.values -> %item {
        next unless %item<type>.chars;
        my %type := (%types{%item<type>} //= %(name => %item<type>, kind => %item<kind>, ids => [], commands => []));
        %type<kind> = %item<kind> unless %item<kind> eq 'entity';
        %type<ids> = (|%type<ids>, |%item<ids>).unique.sort.Array;
        %type<commands> = (|%type<commands>, |%item<commands>).unique.sort.Array;
    }
    %(types => %types.keys.sort.map({ %types{$_} }).Array,
        instances => %streams.keys.sort.map({ %streams{$_} }).Array)
}

method register(Mu:U $type, *@proxies) {
    die 'Inspector requires an aggregate, projection or saga type'
        unless $type.HOW ~~ Metamodel::RedSourcing::EntityHOW;
    %!types{$type.^name} = $type;
    self.watch($_) for @proxies;
    self
}
method watch($proxy) {
    my $type = $proxy.^entity-type;
    die 'Register the entity type before watching an instance' unless %!types{$type.^name}:exists;
    %!proxies{$proxy.^stream-name} = $proxy;
    self
}
method kind(Mu:U $type --> Str) {
    return 'saga' if $type.HOW ~~ Metamodel::RedSourcing::SagaHOW;
    return 'aggregate' if $type.HOW ~~ Metamodel::RedSourcing::AggregateHOW;
    'projection'
}
method types {
    return self!stored-view<types> if $!stored-only;
    %!types.keys.sort.map(-> $name {
        my $type = %!types{$name};
        %(name => $name, kind => self.kind($type), ids => $type.^entity-id-names.Array,
            commands => $type.^commands.keys.sort.Array)
    }).Array
}
method instances {
    return self!stored-view<instances> if $!stored-only;
    my %instances;
    # Snapshots and saga controls both carry sufficient identity and state.
    for StoredEvent.^all.sort(*.id) -> $row {
        my $is-control = $row.mro.contains('|RedSourcing::Saga::Control|');
        my $name = $is-control ?? $row.stream.split(': ').head !! $row.class;
        next unless %!types{$name}:exists;
        next unless $is-control || $row.mro.contains('|Entity|');
        %instances{$row.stream} = %(type => %!types{$name}, stream => $row.stream);
    }
    for %!proxies.kv -> $stream, $proxy {
        %instances{$stream} = %(type => $proxy.^entity-type, :$stream, :$proxy);
    }
    %instances.keys.sort.map(-> $stream {
        my %i = %instances{$stream};
        my $type = %i<type>;
        my %item = %(type => $type.^name, kind => self.kind($type), :$stream);
        try {
            CATCH { default { %item<error> = .message } }
            my $entity = %i<proxy>:exists ?? %i<proxy>.^load !! $type.^load(:$stream);
            %item<version> = $entity.^version;
            %item<cursor> = $entity.^current-id;
            %item<data> = from-json(to-json($entity.^data));
            %item<status> = $entity.^status if %item<kind> eq 'saga';
        }
        %item
    }).Array
}

# Saga controls carry the full committed workflow state. Reporting it does not
# replay source events, call handlers or invoke service adapters.
method saga-status(Str :$stream!, DateTime :$now = DateTime.now --> Hash) {
    my $instance = self!stored-view<instances>.first(*.<stream> eq $stream);
    die "Unknown stream '$stream'" unless $instance.defined;
    die "Stream '$stream' is not a saga" unless $instance<kind> eq 'saga';
    my %state = $instance<data><saga-state>;
    my $status = %state<status> // 'running';
    my $clock = $now.Instant.Num;
    my &schedule = -> $due {
        %(due-at => $now.utc.later(:seconds($due - $clock)).Str,
            remaining-seconds => (0 max ($due - $clock)), ready => $due <= $clock)
    };
    my @actions = (%state<actions> // []).map({
        %(|$_, |(schedule(.<due>) if .<due>.defined))
    }).Array;
    # Keep the runtime's original ordering: the first unfinished action gates
    # later actions even when those later actions are already due.
    my @pending = @actions.grep({ .<status> eq any(<pending retry running blocked>) }).Array;
    my @failed = @actions.grep(*.<status> eq 'failed').Array;
    my @compensations = (%state<compensations> // []).reverse.Array;
    my %timers = %state<timers> // {};
    my @timers = %timers.keys.map(-> $name {
        %(:$name, |%timers{$name}, |schedule(%timers{$name}<due>))
    }).sort({ $^a<due> <=> $^b<due> || $^a<name> cmp $^b<name> }).Array;
    my %next = @pending ?? @pending.head.Hash !! {};
    if $status eq 'compensating' {
        my @unsettled = @pending.grep({ !.<undo-entry> && .<status> eq any(<running blocked>) });
        if @unsettled {
            %next = (@unsettled.first(*.<status> eq 'blocked') // @unsettled.head).Hash;
        } elsif @compensations && @compensations.head<action-id> {
            %next = (@actions.first(*.<id> eq @compensations.head<action-id>) // {}).Hash;
        }
    }
    my $terminal = so $status eq any(<completed compensated>);
    my ($activity, $message);
    if $terminal {
        ($activity, $message) = $status, $status eq 'completed' ?? 'Saga completed.' !! 'Saga compensation completed.';
    } elsif %next && %next<status> eq 'blocked' {
        ($activity, $message) = 'blocked', 'Reconcile the action with its provider, then use resolve-action with the confirmed outcome.';
    } elsif %next && %next<status> eq 'running' {
        ($activity, $message) = 'running-action', 'An action is recorded as running; inspect its command/provider outcome before proceeding.';
    } elsif %next && %next<status> eq 'failed' {
        ($activity, $message) = 'failed-compensation', 'The active compensation failed; it cannot continue automatically.';
    } elsif %next {
        ($activity, $message) =
            (%next<ready> ?? 'ready' !! %next<status> eq 'retry' ?? 'waiting-retry' !! 'scheduled-action'),
            (%next<ready> ?? 'The next action is due; advance can process it.' !! 'The next action is scheduled for a future time.');
    } elsif $status eq 'compensating' {
        ($activity, $message) = 'compensating', @compensations ?? 'Advance can start the next compensation.' !! 'Advance can mark compensation complete.';
    } elsif @timers {
        ($activity, $message) = (@timers.head<ready> ?? 'ready-timeout' !! 'waiting-timeout'),
            (@timers.head<ready> ?? 'A timeout is due; advance can process it.' !! 'Waiting for input or a scheduled timeout.');
    } else {
        ($activity, $message) = 'waiting', 'No queued action. Waiting for input or saga code to declare completion; future steps are not known.';
    }
    %(entity => $instance<type>, :$stream, :$status, :$terminal, :$activity, :$message,
        as-of => $now.utc.Str, state-source => $instance<state-source>,
        version => $instance<version>, cursor => $instance<cursor>, reason => (%state<reason> // ''),
        next-action => %next, pending-actions => @pending.Array, failed-actions => @failed.Array,
        completed-actions => @actions.grep(*.<status> eq 'done').elems,
        compensations-active => $status eq 'compensating', compensations => @compensations.Array,
        timers => @timers.Array, actions => @actions.Array,
        data => $instance<data>.Hash.grep(*.key ne 'saga-state').Hash)
}

method events(UInt :$limit = 60, Str :$stream = '', Str :$type = '', UInt :$id = 0) {
    my $rows = StoredEvent.^all;
    $rows = $rows.grep(*.stream eq $stream) if $stream.chars;
    $rows = $rows.grep(*.class eq $type) if $type.chars;
    $rows = $rows.grep(*.id == $id) if $id;
    $rows.sort(-*.id).head($limit).Seq.map(-> $e {
        %(id => $e.id, type => $e.class, stream => $e.stream, version => $e.version,
            created => $e.created.Str, data => from-json(to-json($e.data)),
            mro => $e.mro, schema-version => $e.event-schema-version,
            replay-cursor => $e.replay-cursor,
            snapshot => $e.mro.contains('|Entity|'),
            control => $e.mro.contains('|RedSourcing::Saga::Control|'))
    }).Array
}
method commands(UInt :$limit = 60, Str :$stream = '', Str :$type = '', UInt :$id = 0) {
    my $rows = StoredCommand.^all;
    $rows = $rows.grep(*.stream eq $stream) if $stream.chars;
    $rows = $rows.grep({ .class eq $type || .entity eq $type }) if $type.chars;
    $rows = $rows.grep(*.id == $id) if $id;
    $rows.sort(-*.id).head($limit).Seq.map(-> $c {
        %(id => $c.id, type => $c.class, stream => $c.stream, state => $c.state.Str,
            entity => $c.entity, method => $c.method, entity-ids => from-json(to-json($c.entity-ids)),
            tries => $c.tries, next-run => $c.next-run.Str, error => ($c.error // ''),
            data => from-json(to-json($c.data)), result => from-json(to-json($c.result)))
    }).Array
}
method revision(--> Str) {
    my $last = storage-query(get-RED-DB, 'SELECT MAX(id) AS id FROM red_sourcing_event').head<id> // 0;
    my $column = StoredCommand.^columns.first(*.name eq '$!state').column;
    my @commands = storage-query(get-RED-DB, 'SELECT id, state, tries FROM red_sourcing_command ORDER BY id');
    $last ~ ':' ~ @commands.map({
        my $state = .<state>.defined ?? $column.inflate.(.<state>, $column.attr.type) !! StoredCommand::Pending;
        "{.<id>}/{$state.Str}/{.<tries> // 0}"
    }).join(',')
}

method report(UInt :$limit = 60) {
    if $!stored-only {
        my %stored = self!stored-view;
        return %(revision => self.revision, |%stored, stored-only => True,
            events => self.events(:$limit), commands => self.commands(:$limit));
    }
    %(revision => self.revision, types => self.types, instances => self.instances,
        events => self.events(:$limit), commands => self.commands(:$limit))
}
