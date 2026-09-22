unit module RedSourcing::CLI::Help;

my @groups =
    'Database maintenance' => <init update>,
    'Discovery and inspection' => <types list-entities list-aggregates list-projections list-sagas describe inspect>,
    'Event and command history' => <streams list-events list-commands>,
    'Entity state' => <create load snapshot>,
    'Command execution and workers' => <command run-command work>,
    'Saga workflows' => <saga-status advance resolve-action>,
    'Monitoring' => <stats web-monitor>;

# Examples assume the application's modules are supplied by configuration.
# These are documentation strings: help never evaluates code or defaults.
my %commands =
    init => {
        usage => 'init',
        description => 'Create the event and command tables if they are missing. Existing records are preserved. This is the first operation for a new store.',
        examples => ['red-sourcing --database=events.db init'] },
    update => {
        usage => 'update --class=CLASS --version=N --transformation=CODE',
        description => 'Migrate the JSON payloads and schema version of matching stored events in one transaction. The transformation is Raku code; --dry-run counts matching rows without executing it or writing changes.',
        examples => [q|red-sourcing update -c=MyApp::Renamed -v=0 -e='.<name> ~= "!"' --dry-run|,
                     q|red-sourcing update -c=MyApp::Renamed -v=0 -e='.<name> ~= "!"'|] },
    types => {
        usage => 'types',
        description => 'Discover entity types observed in stored records, including their kind, IDs and observed commands. This is a database catalog, so types that have never been persisted are absent. It does not import application modules.',
        examples => ['red-sourcing types', 'red-sourcing types --json'] },
    list-entities => {
        usage => 'list-entities',
        description => 'List persisted instances across entity kinds, with their stream, checkpoint and saved status. Use exact filters and pagination to narrow the list. Reads stored state without replaying handlers or importing application modules.',
        examples => ['red-sourcing list-entities --kind=aggregate --limit=20',
                     'red-sourcing list-entities --type=MyApp::Account --offset=20'] },
    list-aggregates => {
        usage => 'list-aggregates',
        description => 'List persisted aggregate instances. Supports the same type, stream, status and pagination filters as list-entities, with the kind fixed to aggregate. Does not replay handlers.',
        examples => ['red-sourcing list-aggregates --type=MyApp::Account --limit=20'] },
    list-projections => {
        usage => 'list-projections',
        description => 'List persisted projection instances and their saved checkpoints. The list describes stored state; it does not consume newer source events or rebuild projections.',
        examples => ['red-sourcing list-projections --limit=20 --offset=20'] },
    list-sagas => {
        usage => 'list-sagas',
        description => 'List persisted saga instances and their saved workflow status. Use saga-status to investigate one workflow, or advance to process its pending work.',
        examples => ['red-sourcing list-sagas --status=running',
                     'red-sourcing list-sagas --status=compensating --json'] },
    describe => {
        usage => 'describe ENTITY',
        description => 'Load an entity definition to show its kind, identity fields, native documentation and commands. Source declarations preserve where predicates, aliases and defaults when available. Does not instantiate the entity or execute handlers.',
        examples => ['red-sourcing describe Account -I=lib -M=MyApp::Domain'] },
    inspect => {
        usage => 'inspect',
        description => 'Show the stored entity catalog and recent event/command history, or inspect one exact stream. State comes from persisted snapshots and controls; inspection does not replay domain handlers or run pending work.',
        examples => ['red-sourcing inspect --limit=10',
                     q|red-sourcing inspect --stream='MyApp::Account: account-id = a1'|] },
    streams => {
        usage => 'streams',
        description => 'List distinct event stream names in sorted order. Each name is printed in full and can be copied into --stream filters. No application modules are needed.',
        examples => ['red-sourcing streams', 'red-sourcing streams --json'] },
    list-events => {
        usage => 'list-events',
        description => 'Read stored events and snapshots with metadata filters. --details expands payloads; --snapshots restricts the result to snapshots. Raw class-name filters need no imports, while -l/-c filters can use loaded event types or Raku expressions.',
        examples => ['red-sourcing list-events --latest --limit=10 --details',
                     'red-sourcing list-events --class-name=MyApp::Renamed --from-id=100'] },
    list-commands => {
        usage => 'list-commands',
        description => 'Read persisted command requests, states, attempts, results and errors. --due selects commands whose scheduled time has arrived; combine it with --state=Pending for ready work. Listing does not execute commands.',
        examples => ['red-sourcing list-commands --state=Failed --details',
                     'red-sourcing list-commands --state=Pending --due --limit=20'] },
    create => {
        usage => 'create ENTITY',
        description => 'Create an entity by storing its initial snapshot. Supply all declared IDs and optional public initial fields as a JSON object. An existing stream is rejected, so create cannot reset an entity.',
        examples => [q|red-sourcing create Account --id=account-id=a1 --data='{"name":"Ana"}'|] },
    load => {
        usage => 'load ENTITY',
        description => 'Restore an entity from its snapshot and replay events without writing records. Application handlers are required. The output contains the current reconstructed state; inspect instead reads only persisted state.',
        examples => ['red-sourcing load Account --id=account-id=a1',
                     'red-sourcing load Repair --id=repair-id=r1 --id=tenant-id=t1 --json'] },
    snapshot => {
        usage => 'snapshot ENTITY',
        description => 'Load and replay an existing entity, then persist a fresh snapshot of the reconstructed state. This writes a checkpoint to the event journal; it does not change earlier events.',
        examples => ['red-sourcing snapshot Account --id=account-id=a1'] },
    command => {
        usage => 'command ENTITY METHOD',
        description => 'Validate arguments against an entity command and execute it synchronously, returning its result. --async stores a pending request for later execution. --dry-run prepares and validates arguments without storing or running the command.',
        examples => [q|red-sourcing command Account rename --id=account-id=a1 --data='{"name":"Ana"}'|,
                     q|red-sourcing command Account rename --id=account-id=a1 --data='{"name":"Ana"}' --async|] },
    run-command => {
        usage => 'run-command ID',
        description => 'Execute an already stored command by its numeric row ID and display its persisted outcome. Completed commands reuse their saved result. Future requests remain pending unless --wait is passed. ID here is a command row ID, not an entity ID.',
        examples => ['red-sourcing run-command 42', 'red-sourcing run-command 42 --wait'] },
    work => {
        usage => 'work',
        description => 'Process a bounded batch of due Pending commands. The default performs one pass; --watch polls repeatedly until Ctrl-C. Failed handlers are recorded and do not prevent later commands in the batch from running. Import domain and service modules needed by the requests.',
        examples => ['red-sourcing work --limit=50',
                     'red-sourcing work -M=MyApp::Domain --watch --interval=0.5'] },
    saga-status => {
        usage => 'saga-status [SAGA] [--stream=NAME]',
        description => 'Diagnose a saga\'s committed state, next action, retries, timeouts and compensation stack without advancing it. Select either a saga type with IDs, or an exact stored stream. --details includes action history and saved arguments/results. An empty queue does not imply completion.',
        examples => ['red-sourcing saga-status OrderSaga --id=order-id=o1 --details',
                     q|red-sourcing saga-status --stream='MyApp::OrderSaga: order-id = o1'|] },
    advance => {
        usage => 'advance SAGA',
        description => 'Replay new saga input and process reactions, ready actions, retries, compensations and due timeouts. This can execute aggregate commands and external services. The limit bounds actions processed in this pass; inspect first with saga-status when diagnosing a workflow.',
        examples => ['red-sourcing advance OrderSaga --id=order-id=o1 --limit=10'] },
    resolve-action => {
        usage => 'resolve-action SAGA ACTION-ID',
        description => 'Record a confirmed result or error for a running or blocked saga action, without reissuing the external operation. Find ACTION-ID through saga-status --details. Pass exactly one of --result (JSON) or --error, then advance the saga to continue.',
        examples => [q|red-sourcing resolve-action OrderSaga a1 --id=order-id=o1 --result='{"payment-id":"p1"}'|,
                     q|red-sourcing resolve-action OrderSaga a1 --id=order-id=o1 --error='Payment rejected'|] },
    stats => {
        usage => 'stats',
        description => 'Show journal rates and per-entity totals, including events, failures, retries, snapshots and events since the last checkpoint. The time window applies to activity rates. Reads the database without loading application modules.',
        examples => ['red-sourcing stats --minutes=15', 'red-sourcing stats --minutes=60 --json'] },
    web-monitor => {
        usage => 'web-monitor',
        description => 'Serve the independent Cro/HTMX system console with live discovery, history, health charts and CLI operations. The application and monitor run independently. Inspection needs no application modules; execution uses configured modules or -I/-M. Requires an existing database unless --allow-new-store enables explicit initialization in the console.',
        examples => ['red-sourcing web-monitor --database=events.db --port=3001',
                     'red-sourcing web-monitor -f=deployment.rakuconf --minutes=120'] };

my %options =
    file => ['-f, --file=FILE', 'Read this configuration file. Otherwise search for red-sourcing.rakuconf in the current directory and its parents.'],
    driver => ['--driver=DRIVER', 'Red database driver; default: SQLite. CLI values override configuration.'],
    database => ['--database=DATABASE', 'Database path or name; default: a.db. web-monitor requires an explicit or configured database.'],
    debug => ['--debug, --/debug', 'Enable SQL logging and exception details, or disable configured debugging.'],
    json => ['--json', 'Emit machine-readable JSON instead of the default human-readable output.'],
    includes => ['-I, --includes=PATH (repeatable)', 'Add an application library directory to configured include paths.'],
    modules => ['-M, --modules=MODULE (repeatable)', 'Import an application, event or service module in addition to configured modules.'],
    identity => ['--id=FIELD=VALUE (repeatable)', 'Supply each declared entity ID. Values follow the declared type. --identity is an alias.'],
    ids => ['--ids=JSON', 'Supply the identity as a JSON object instead of --id. Do not combine both forms.'],
    data => ['-d, --data=JSON', 'JSON object containing command arguments or initial public entity fields; default: {}.'],
    async => ['--async', 'Store a pending command instead of executing it synchronously.'],
    dry-run => ['--dry-run', 'Preview without writes: command validates/prepares arguments; update counts matching rows without running the transformation.'],
    events => ['-l, --events=TYPE (repeatable)', 'Filter by a loaded event type name. Supply its module with -M if needed.'],
    classes => ['-c, --classes=EXPRESSION (repeatable)', 'Filter using a trusted Raku type or rule expression evaluated with loaded modules.'],
    stream => ['--stream=NAME', 'Select an exact stored stream name, including its identity fields.'],
    after => ['--after=DATETIME', 'Select events emitted strictly after an ISO 8601 timestamp.'],
    from-id => ['--from-id=N', 'Select records whose numeric journal ID is strictly greater than N.'],
    class-name => ['--class-name=NAME', 'Match the exact persisted event class name, without importing its module.'],
    schema-version => ['--schema-version=N', 'Match the stored event payload schema version.'],
    limit => ['--limit=N', 'Bound the number of returned records or processed actions.'],
    offset => ['--offset=N', 'Skip N matching entity instances for pagination; default: 0.'],
    latest => ['--latest', 'Return newest records first; the limit is applied after ordering.'],
    snapshots => ['--snapshots', 'Return only snapshot records. Without this flag, history includes events and snapshots.'],
    rows => ['--rows', 'Compatibility option; history already returns stored records and metadata.'],
    details => ['--details', 'Expand history payloads, results and errors; for saga-status include action history and saved arguments.'],
    state => ['--state=STATE', 'Filter command state: Pending, Processing, Done or Failed.'],
    entity => ['--entity=NAME', 'Filter by the exact persisted entity type name.'],
    method => ['--method=NAME', 'Filter by the command method name.'],
    due => ['--due', 'Select commands whose next-run time has arrived. Combine with --state=Pending for ready work.'],
    class => ['-c, --class=CLASS (required)', 'Exact persisted class name of the events to migrate.'],
    version => ['-v, --version=N (required)', 'Source payload schema version to migrate.'],
    new-version => ['-n, --new-version=N', 'Target payload schema version; default: source version + 1.'],
    transformation => ['-e, --transformation=CODE (required)', 'Trusted Raku code to run for each matching event during migration.'],
    trans-signature => ['--trans-signature=SIGNATURE', 'Transformation signature; default: StoredEvent (:data($_), |), binding $_ to the JSON payload.'],
    host => ['--host=ADDRESS', 'Monitor bind address; default: 127.0.0.1, unless configured.'],
    port => ['--port=N', 'Monitor HTTP port; default: 3001, unless configured.'],
    minutes => ['--minutes=N', 'Activity window in minutes; default: 60, unless configured for the monitor.'],
    app-url => ['--app-url=URL', 'Optional application URL linked from the monitor; default: no link.'],
    origins => ['--origin=URL (repeatable)', 'Allowed browser origins for console operations. Defaults to the bound address; loopback also accepts localhost. Set the external URL when using a reverse proxy.'],
    allow-new-store => ['--allow-new-store', 'Allow the console to open before a store is initialized. Tables are created only when you explicitly run init. Default: disabled.'],
    kind => ['--kind=KIND', 'Filter entity kind: aggregate, projection, saga or entity.'],
    type => ['--type=NAME', 'Filter the exact persisted entity type name.'],
    status => ['--status=STATUS', 'Filter the exact saved entity/workflow status, such as running or compensating.'],
    wait => ['--wait', 'Wait until a future command is scheduled to run instead of leaving it pending.'],
    watch => ['--watch, --/watch', 'Poll continuously until Ctrl-C, or override configured watch mode with one pass.'],
    interval => ['--interval=SECONDS', 'Delay between worker passes; default: 1 second, unless configured. Must be positive.'],
    result => ['--result=JSON', 'Confirmed action result, as any JSON value. Pass either --result or --error, not both.'],
    error => ['--error=MESSAGE', 'Confirmed action failure. Pass either --error or --result, not both.'],
    now => ['--now=DATETIME', 'Override the saga controller clock with an ISO 8601 timestamp for this pass.'];

my @common = <file driver database debug>;
my @shared = <json includes modules identity ids>;

# The web console uses the same explanations as terminal help.
sub cli-catalog() is export {
    @groups.map(-> $group {
        %(group => $group.key, commands => $group.value.map(-> $name {
            %(name => $name, |%commands{$name})
        }).Array)
    }).Array
}
sub cli-option-description(Str $name --> Str) is export {
    %options{$name}[1] // die "Missing CLI option documentation: $name"
}

sub wrapped(Str $text, UInt :$indent = 0 --> Str) {
    my @lines;
    my $line = ' ' x $indent;
    for $text.words -> $word {
        if $line.chars > $indent && $line.chars + 1 + $word.chars > 80 {
            @lines.push($line);
            $line = ' ' x $indent;
        }
        $line ~= ' ' if $line.chars > $indent;
        $line ~= $word;
    }
    @lines.push($line);
    @lines.join("\n")
}

sub candidates-by-name(@candidates --> Hash) {
    @candidates.map({ .signature.params.head.constraint_list.head.Str => $_ }).Hash
}

sub option-names($candidate) {
    $candidate.signature.params.grep(*.named).map(*.name.substr(1)).Array
}

# Skip option values so --database=load and --database load do not select the
# load help page. Only the first positional argument identifies a command.
sub cli-help-target(@arguments, @candidates --> Str) is export {
    my %values;
    for @candidates -> $candidate {
        for $candidate.signature.params.grep({ .named && .type !~~ Bool }) -> $param {
            %values{$_} = True for $param.named_names;
        }
    }
    my $index = 0;
    while $index < @arguments.elems {
        my $argument = @arguments[$index++];
        return @arguments[$index] // '' if $argument eq '--';
        if $argument.starts-with('-') {
            my $name = $argument.subst(/^ '-' ** 1..2 /, '');
            $index++ if !($name.contains('=')) && (%values{$name}:exists);
        } else { return $argument }
    }
    ''
}

sub option-block(@names, Str :$command = '' --> Str) {
    @names.map(-> $name {
        die "Missing CLI option documentation: $name" unless %options{$name}:exists;
        my ($label, $description) = %options{$name}.List;
        if $name eq 'limit' {
            $description ~= $command eq any(<list-events list-commands>) ?? ' Default: 0 (unlimited).'
                !! $command eq 'inspect' ?? ' Default: 60.'
                !! $command eq 'work' ?? ' Default: 100, unless configured. Must be positive.'
                !! $command eq 'advance' ?? ' Default: 100. Must be positive.'
                !! ' Default: 100.';
        }
        '  ' ~ $label ~ "\n" ~ wrapped($description, :indent(4))
    }).join("\n")
}

sub command-block(Str $name --> Str) {
    my %entry = %commands{$name};
    '  ' ~ %entry<usage> ~ "\n" ~ wrapped(%entry<description>, :indent(4))
        ~ "\n    Examples:\n" ~ %entry<examples>.map({ '      ' ~ $_ }).join("\n")
}

sub format-cli-help(@candidates, Str :$command = '' --> Str) is export {
    my %available = candidates-by-name(@candidates);
    die "Unknown command '$command'. Run red-sourcing --help to list commands."
        if $command.chars && !(%available{$command}:exists);
    for %available.keys -> $name {
        die "Missing CLI command documentation: $name" unless %commands{$name}:exists;
    }
    my @sections = 'RedSourcing — event sourcing tools',
        'Usage: red-sourcing [COMMON OPTIONS] ' ~ ($command.chars ?? %commands{$command}<usage> !! 'COMMAND') ~ ' [OPTIONS]',
        "Common options (all commands; accepted before or after the command)\n"
            ~ option-block(@common) ~ "\n  -h, --help\n    Show this help; COMMAND --help shows only that command.\n    Help does not read configuration, import application modules or open a store.";
    if $command.chars {
        my @names = option-names(%available{$command});
        my @shared-options = @shared.grep({ $_ eq any(@names) });
        my @specific = @names.grep({ $_ ne any(|@common, |@shared) });
        @sections.push("Shared options for $command\n" ~ option-block(@shared-options, :$command)) if @shared-options;
        @sections.push("Command options\n" ~ option-block(@specific, :$command)) if @specific;
        @sections.push('Application types in examples are illustrative. Supply their modules through configuration or -I=PATH and -M=MODULE.')
            if 'modules' eq any(@names);
        @sections.push("Command\n" ~ command-block($command));
    } else {
        @sections.push("Output (data-producing commands)\n" ~ option-block(['json']));
        @sections.push("Application imports (entity operations, execution, sagas and typed history/migrations)\n"
            ~ option-block(<includes modules>));
        @sections.push("Entity identity (create, load, snapshot, command, advance, saga-status, resolve-action)\n"
            ~ option-block(<identity ids>));
        @sections.push('Examples below use illustrative application types. Configure their modules in red-sourcing.rakuconf, or add -I=PATH and -M=MODULE to application-aware commands.');
        for @groups -> $group {
            @sections.push($group.key ~ "\n" ~ $group.value.map({ command-block($_) }).join("\n\n"));
        }
    }
    @sections.push('Use red-sourcing COMMAND --help for all command-specific options and examples.');
    @sections.map({ .lines.map({
        .chars > 80 && !.starts-with('      red-sourcing')
            ?? wrapped($_, :indent(.match(/^ \h* /).chars)) !! $_
    }).join("\n") }).join("\n\n")
}
