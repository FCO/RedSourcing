unit module RedSourcing::CLI::Application;
use RedSourcing;
use JSON::Fast;
use RedSourcing::Inspector;
use RedSourcing::Web::Metrics;
use RedSourcing::Config;
use RedSourcing::Lifecycle;
use RedSourcing::CLI::Output;
use RedSourcing::CLI::Help;

my $cli-config = Settings.new;
my $cli-config-directory = IO::Path;
my %*CLI-OPTIONS;

# Reflect fields without running parameter defaults, configuration or imports.
our sub operation-schema() {
    cli-catalog().map(-> %group {
        %(group => %group<group>, commands => %group<commands>.map(-> %entry {
            my $candidate = &MAIN.candidates.first({
                .signature.params.head.constraint_list.head.Str eq %entry<name>
            });
            my @params = $candidate.signature.params.skip(1);
            %(|%entry, positionals => @params.grep(*.positional).map({
                %(name => .name.substr(1), required => !.optional, type => .type.^name)
            }).Array, options => @params.grep(*.named).map({
                %(name => .name.substr(1), type => .type.^name,
                    boolean => .type ~~ Bool, repeated => .name.starts-with('@'),
                    required => !.optional,
                    description => cli-option-description(.name.substr(1)))
            }).Array)
        }).Array)
    }).Array
}

sub initialize-cli() is export {
    # Handle help before configuration or command dispatch, even if all required
    # arguments were supplied. Raku's generated usage remains replaced on errors too.
    if !@*ARGS || @*ARGS.first(* eq any('--help', '-h')).defined {
        CATCH { default { note .message; exit 2 } }
        say format-cli-help(&MAIN.candidates, :command(cli-help-target(@*ARGS, &MAIN.candidates)));
        exit 0;
    }
    
    
    {
        CATCH {
            default {
                .rethrow if @*ARGS.first(* eq '--debug').defined;
                note .message;
                exit 1;
            }
        }
        my %loaded = load-cli-config(@*ARGS);
        $cli-config = %loaded<settings>;
        $cli-config-directory = %loaded<directory>;
    }
    
    
}

sub USAGE() is export {
    my $target = cli-help-target(@*ARGS, &MAIN.candidates);
    my $text = try format-cli-help(&MAIN.candidates, :command($target));
    $*ERR.say($text // format-cli-help(&MAIN.candidates));
}


# Keep failures concise; --debug retains the original exception and SQL logging.
proto MAIN(|args) is export {
    my %*CLI-OPTIONS = args.hash;
    my $*REDSOURCING-CLI-OPERATION = args.list.head;
    CATCH {
        default {
            .rethrow if args.hash<debug> // $cli-config.debug;
            note .message;
            exit 1;
        }
    }
    {*}
}

sub with-store(Str $driver, Str $database, Bool $debug, &work) {
    my $*RED-FALLBACK = False;
    my $*RED-DEBUG = $debug;
    my $path = config-database($driver, $database, $cli-config-directory,
        :explicit(so %*CLI-OPTIONS<database>:exists));
    red-defaults :default(store-driver($driver, $path, :connection($cli-config.connection)));
    configure-lifecycles($cli-config.entities, :auto-snapshot($cli-config.auto-snapshot));
    work()
}

# Imports and type expressions share a scope. Data and identity JSON never
# become Raku source; include paths and symbolic names are quoted as literals.
sub imported-code(@includes, @modules, Str $expression) {
    my @paths = (|$cli-config.includes, |@includes).unique;
    my @imports = (|$cli-config.modules, |@modules).unique;
    my $source = (|@paths.map({ 'use lib ' ~ .raku ~ ';' }),
        |@imports.map({ "use $_;" }), $expression).join("\n");
    note "code: $source" if $*RED-DEBUG;
    $source.EVAL
}
sub trace-operation {
    enable-flow-tracing if $cli-config.flow-tracing && $*REDSOURCING-CLI-OPERATION
        eq any(<create load snapshot command run-command work advance advance-sagas resolve-action>);
}

sub json-object(Str $source, Str $option --> Hash) {
    my $value = from-json($source);
    die "$option must be a JSON object" unless $value ~~ Associative;
    $value.Hash
}

sub print-json($value) { say to-json($value, :!pretty) }

# Signature.gist deliberately replaces executable constraints with { ... }.
# Recover the declaration without evaluating predicates or default expressions.
# This is a conservative reader, not a Raku parser: unfamiliar quoting forms
# fall back to reflection rather than guessing where the signature ends.
sub command-declaration(&handler --> Hash) {
    my $file = &handler.file;
    my $line = &handler.line;
    my @paths = $file, $file.subst(/ \s+ '(' <-[()]>* ')' $ /, '');
    my $path = @paths.first({ .IO.f });
    return {} unless $path.defined && $line > 0;
    my $lines = try $path.IO.lines.Array;
    return {} unless $lines.defined;
    my @lines = $lines.List;
    my %origin = source => %(file => $path, line => $line);
    return %origin if $line > @lines.elems;
    my $source = @lines.skip($line - 1).join("\n");
    my $name = &handler.name;
    my $start = $source.match(/^ \h* [ 'multi' \s+ | 'only' \s+ ]? 'method' \s+ $name \s* <?before '('> /);
    return %origin unless $start;
    my $open = $start.to;
    my @closing;
    my $quote = '';
    my $escaped = False;
    my $comment = False;
    for $open ..^ $source.chars -> $offset {
        my $char = $source.substr($offset, 1);
        if $comment {
            $comment = False if $char eq "\n";
            next;
        }
        if $quote {
            if $escaped { $escaped = False }
            elsif $char eq '\\' { $escaped = True }
            elsif $char eq $quote { $quote = '' }
            # Interpolated code can contain its own strings and delimiters.
            elsif $quote eq '"' && $char eq any('{', '$', '@', '%', '&') { return %origin }
            next;
        }
        if $char eq '#' { $comment = True; next }
        if $char eq any("'", '"') { $quote = $char; next }
        # Regexes, heredocs and quote operators need the full Raku grammar.
        my $previous = $offset ?? $source.substr($offset - 1, 1) !! '';
        my $quote-operator = !$previous.match(/ <[\w$@%&\-']> /)
            && $source.substr($offset).match(/^ [ 'qq' | 'q' | 'Q' | 'rx' | 'm' | 's' | 'tr' ] \h* <?before <-[\w\s]>> /);
        return %origin if $char eq any('/', '`', '«', '»', '｢', '｣')
            || $quote-operator
            || ($char eq '<' && $source.substr($offset).match(/^ '<' \s* <-[\s\d$=]> /));
        if $char eq any('(', '[', '{') {
            @closing.push(%('(' => ')', '[' => ']', '{' => '}'){$char});
        } elsif $char eq any(')', ']', '}') {
            return %origin unless @closing && @closing.pop eq $char;
            unless @closing {
                # A ')' inside an unfamiliar literal must not look like the end
                # of a signature. Confirm the command trait follows it.
                return %origin unless $source.substr($offset + 1).match(/^ \s* 'is' \s+ 'command' <!before \w> /);
                return %(declaration => $start.Str.trim ~ $source.substr($open, $offset - $open + 1),
                    |%origin);
            }
        }
    }
    %origin
}

sub output($value, Bool $json, &human) {
    if $json { print-json($value) }
    else { say human($value) }
}

sub event-record($row) {
    %(id => $row.id, class => $row.class, stream => $row.stream,
        version => $row.version, created => $row.created.Str,
        event-schema-version => $row.event-schema-version,
        replay-cursor => $row.replay-cursor, data => $row.data)
}

sub command-record($row) {
    %(id => $row.id, class => $row.class, entity => $row.entity,
        entity-ids => $row.entity-ids, method => $row.method, stream => $row.stream,
        state => $row.state.Str, tries => $row.tries, next-run => $row.next-run.Str,
        data => $row.data, result => $row.result, error => $row.error)
}

sub entity-type(Str $name, @includes, @modules) {
    my Mu $type = imported-code(@includes, @modules, '::(' ~ $name.raku ~ ')');
    if $type ~~ Failure {
        $type.so;
        die "Unknown entity '$name'; load its module with -M";
    }
    die "'$name' is not an aggregate, projection or saga"
        unless $type.HOW ~~ Metamodel::RedSourcing::EntityHOW;
    trace-operation;
    $type
}

sub entity-proxy(Mu:U $type, Str $ids, @pairs) {
    die 'Use either --id=FIELD=VALUE or --ids=JSON, not both'
        if @pairs && (%*CLI-OPTIONS<ids>:exists);
    my %identity = @pairs ?? {} !! json-object($ids, '--ids');
    for @pairs -> $pair {
        my @parts = $pair.split('=', 2);
        die '--id must have the form FIELD=VALUE' unless @parts.elems == 2 && @parts[0].chars;
        my ($name, $value) = @parts;
        die "Duplicate entity ID: $name" if %identity{$name}:exists;
        %identity{$name} = $value;
    }
    my @ids = $type.^entity-id-names;
    my @missing = @ids.grep({ !(%identity{$_}:exists) });
    my @unknown = %identity.keys.grep({ $_ ne any(@ids) }).sort;
    die 'Missing entity IDs: ' ~ @missing.join(', ') if @missing;
    die 'Unknown entity IDs: ' ~ @unknown.join(', ') if @unknown;
    if @pairs {
        for $type.^entity-id-attrs -> $attribute {
            my $name = $attribute.name.substr(2);
            my $value = %identity{$name};
            if $attribute.type ~~ Str {
                # Preserve text exactly, including leading zeros and '='.
                next;
            } elsif $attribute.type ~~ Bool {
                die "Entity ID '$name' must be true or false" unless $value.lc eq any(<true false>);
                %identity{$name} = $value.lc eq 'true';
            } elsif $attribute.type ~~ Numeric {
                my $number = val($value);
                die "Entity ID '$name' must be numeric" unless $number ~~ Numeric;
                %identity{$name} = $number.Numeric;
            }
        }
    }
    $type.^with-ids(|%identity)
}

sub declarator-description($declaration --> Str) {
    $declaration.WHY.defined ?? $declaration.WHY.Str.trim !! ''
}

sub entity-record($entity) {
    %(entity => $entity.^name, stream => $entity.^stream,
        version => $entity.^version, cursor => $entity.^current-id,
        data => $entity.^data)
}

sub command-state(Str $state) {
    die 'Invalid command state; use Pending, Processing, Done or Failed'
        unless StoredCommand::State.enums{$state}:exists;
    StoredCommand::State(StoredCommand::State.enums{$state})
}

sub selected-commands(:$stream, :$state, :$from-id, :$entity, :$method, Bool :$due = False) {
    my $rows = StoredCommand.^all;
    $rows = $rows.grep(*.stream eq $stream) with $stream;
    $rows = $rows.grep(*.state == command-state($state)) with $state;
    $rows = $rows.grep(*.id > $from-id) with $from-id;
    $rows = $rows.grep(*.entity eq $entity) with $entity;
    $rows = $rows.grep(*.method eq $method) with $method;
    my $now = DateTime.now;
    $rows = $rows.grep(*.next-run <= $now) if $due;
    $rows.sort(*.id)
}

#| Create the event and command tables if missing, preserving existing data.
multi MAIN('init', Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    with-store $driver, $database, $debug, {
        enable-flow-tracing if $cli-config.flow-tracing;
        StoredEvent.^create-table(:unless-exists);
        StoredCommand.^create-table(:unless-exists);
        .^create-indexes for StoredEvent, StoredCommand;
    }
}

#| List persisted event stream names in sorted order.
multi MAIN('streams', Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db',
           Bool :$debug = $cli-config.debug, Bool :$json = False) {
    with-store $driver, $database, $debug, {
        my @streams = StoredEvent.^all.Seq.map(*.stream).unique.sort;
        if $json { print-json(@streams.Array) }
        else { .say for @streams }
    }
}

#| Validate and execute an entity command, or queue it with --async.
multi MAIN('command', Str $entity, Str $method,
           :I(:@includes), :M(:@modules), Str :$ids = '{}', :id(:@identity), Str :d(:$data) = '{}',
           Bool :$async = False, Bool :$dry-run = False, Bool :$json = False,
           Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    with-store $driver, $database, $debug, {
        my %arguments = json-object($data, '--data');
        my Mu $type = entity-type($entity, @includes, @modules);
        die "No command '$method' on {$type.^name}"
            unless $type.^commands{$method}:exists;
        my $proxy = entity-proxy($type, $ids, @identity);

        my @parameters = $type.^commands{$method}.signature.params.grep({ .named && !.slurpy });
        my @names = @parameters.map({ |.named_names }).Array;
        my @extra = %arguments.keys.grep({ $_ ne any(@names) || $_ eq 'sync' }).sort;
        die 'Unknown command arguments: ' ~ @extra.join(', ') if @extra;
        for @parameters -> $parameter {
            my @aliases = $parameter.named_names.grep({ %arguments{$_}:exists });
            die 'Missing command argument: ' ~ $parameter.named_names.head
                unless $parameter.optional || @aliases;
            die 'Pass only one of these argument aliases: ' ~ @aliases.join(', ') if @aliases > 1;
        }

        if $dry-run {
            my $prepared = $proxy.^prepare-command($method, |%arguments);
            my %payload = $prepared.^attributes.grep(*.has_accessor).map({
                .name.substr(2) => .get_value($prepared)
            });
            output(%(entity => $type.^name, entity-ids => $proxy.^ids-map,
                class => $prepared.^name, :$method, stream => $proxy.^stream-name,
                data => %payload, mode => $async ?? 'async' !! 'sync', dry-run => True),
                $json, -> $plan { format-details('Command preview', $plan) });
        } else {
            # Use the generated proxy API once, preserving default evaluation,
            # parameter normalization, persisted execution and domain validation.
            my $result = $proxy."$method"(|%arguments, :sync(!$async));
            output($async ?? command-record($result) !! $result, $json,
                -> $value {
                    $async ?? format-details('Queued command', $value)
                        !! $value.defined ?? format-details('Result', $value)
                        !! 'Command completed (no result).'
                });
        }
    }
}

#| List stored events and snapshots, with optional filters and payload details.
multi MAIN('list-events', :I(:@includes), :M(:@modules), :l(:@events), :c(:@classes),
           Str :$stream, Str :$after, UInt :$from-id,
           Str :$class-name, UInt :$schema-version, UInt :$limit = 0,
           Bool :$latest = False, Bool :$snapshots = False,
           Bool :$rows = False, Bool :$json = False, Bool :$details = False,
           Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    with-store $driver, $database, $debug, {
        my @expressions = |@events.map({ '::(' ~ .raku ~ ')' }), |@classes.map({ "($_)" });
        my Event @types;
        @types = |imported-code(@includes, @modules, '[' ~ @expressions.join(',') ~ ']')
            if @expressions || @includes || @modules;
        my DateTime $timestamp = DateTime.new($_) with $after;
        my $result = StoredEvent.list-events(
            |(:@types if @types), |(:$stream with $stream),
            |(:after($timestamp) with $timestamp), |(:$from-id with $from-id),
            :row,
        );
        $result = $result.grep(*.class eq $class-name) with $class-name;
        $result = $result.grep(*.event-schema-version == $schema-version) with $schema-version;
        $result = $result.grep(*.mro.contains('|Entity|')) if $snapshots;
        $result = $result.reverse if $latest;
        $result = $result.head($limit) if $limit;
        my @result = $result.Array;
        output(@result.map(&event-record).Array, $json,
            -> @items { format-events(@items, :$details) });
    }
}

#| List stored commands, execution states, results and errors.
multi MAIN('list-commands', Str :$stream, Str :$state, UInt :$from-id,
           Str :$entity, Str :$method, Bool :$due = False, UInt :$limit = 0, Bool :$latest = False,
           Bool :$json = False, Bool :$details = False, Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    with-store $driver, $database, $debug, {
        my $result = selected-commands(:$stream, :$state, :$from-id, :$entity, :$method, :$due).Seq;
        $result = $result.reverse if $latest;
        $result = $result.head($limit) if $limit;
        my @result = $result.Array;
        output(@result.map(&command-record).Array, $json,
            -> @items { format-commands(@items, :$details) });
    }
}

#| Migrate matching event payloads and schema versions atomically.
multi MAIN('update', Str :c(:$class)!, UInt :v(:$version)!,
           UInt :n(:$new-version) = $version + 1, Str :e(:$transformation)!,
           Str :$trans-signature = 'StoredEvent (:data($_), |)', :I(:@includes), :M(:@modules),
           Bool :$dry-run = False, Bool :$json = False, Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    with-store $driver, $database, $debug, {
        my &transform = imported-code(@includes, @modules, "-> $trans-signature \{ $transformation }");
        my @rows := StoredEvent.^all.grep({ .class eq $class && .event-schema-version == $version });
        my $affected = @rows.elems;
        if $debug {
            note 'Affected rows:';
            .note for @rows.Seq;
        }
        unless $dry-run {
            red-do :transaction, {
                for @rows.sort(*.id).Seq {
                    .&transform;
                    .^set-dirty(.^columns.first(*.name eq '$!data'));
                    .event-schema-version = $new-version;
                    .^save;
                    note 'transformed : ', $_ if $debug;
                }
                True
            }
        }
        output(%(:$class, from-version => $version, :$new-version, :$affected, :$dry-run),
            $json, -> $summary {
                ($dry-run ?? 'Would update ' !! 'Updated ') ~ $affected
                    ~ ($affected == 1 ?? ' event' !! ' events') ~ " of $class (schema $version → $new-version)."
            });
    }
}

#| Serve the independent web monitor from the selected database.
multi MAIN('web-monitor', Str :$database = $cli-config.database, Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$host = $cli-config.monitor.host // '127.0.0.1',
           UInt :$port = $cli-config.monitor.port // 3001,
           UInt :$minutes = $cli-config.monitor.minutes // 60, Str :$app-url = $cli-config.monitor.app-url // '', Bool :$debug = $cli-config.debug,
           :I(:@includes), :M(:@modules), :origin(:@origins), Bool :$allow-new-store = $cli-config.monitor.allow-new-store) {
    die '--database is required for web-monitor, either on the CLI or in configuration'
        unless $database.defined;
    my $path = config-database($driver, $database, $cli-config-directory,
        :explicit(so %*CLI-OPTIONS<database>:exists));
    my &monitor;
    {
        require ::('RedSourcing::Web::Monitor');
        &monitor = ::('RedSourcing::Web::Monitor::EXPORT::DEFAULT').WHO{'&run-monitor'};
    }
    monitor(:$driver, :database($path), :$host, :$port, :$minutes, :$app-url, :$debug,
        :connection($cli-config.connection), :settings($cli-config), :@includes, :@modules,
        :origins(@origins ?? @origins !! $cli-config.monitor.origins), :$allow-new-store);
}

# Database-only commands never import persisted names or invoke domain handlers.
#| List entity types discovered from stored records without loading domain code.
multi MAIN('types', Bool :$json = False, Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    with-store $driver, $database, $debug, {
        output(RedSourcing::Inspector.new(:stored-only).types, $json, &format-types);
    }
}

sub list-entities(Str $driver, Str $database, Bool $debug,
                  Str :$kind = '', Str :$type = '', Str :$stream = '', Str :$status = '',
                  UInt :$limit = 100, UInt :$offset = 0, Bool :$json = False) {
    die 'Invalid entity kind; use aggregate, projection, saga or entity'
        if $kind.chars && $kind ne any(<aggregate projection saga entity>);
    with-store $driver, $database, $debug, {
        my @items = RedSourcing::Inspector.new(:stored-only).instances.grep({
            .<type>.chars && (!$kind.chars || .<kind> eq $kind)
                && (!$type.chars || .<type> eq $type)
                && (!$stream.chars || .<stream> eq $stream)
                && (!$status.chars || (.<status> // '') eq $status)
        }).skip($offset).head($limit).Array;
        output(@items, $json, &format-entities);
    }
}

#| List persisted entity instances across all kinds without replaying handlers.
multi MAIN('list-entities', Str :$kind = '', Str :$type = '', Str :$stream = '', Str :$status = '',
           UInt :$limit = 100, UInt :$offset = 0, Bool :$json = False,
           Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    list-entities($driver, $database, $debug, :$kind, :$type, :$stream, :$status, :$limit, :$offset, :$json);
}

#| List persisted aggregate instances without replaying handlers.
multi MAIN('list-aggregates', Str :$type = '', Str :$stream = '', Str :$status = '',
           UInt :$limit = 100, UInt :$offset = 0, Bool :$json = False,
           Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    list-entities($driver, $database, $debug, :kind<aggregate>, :$type, :$stream, :$status, :$limit, :$offset, :$json);
}

#| List persisted projection instances without replaying handlers.
multi MAIN('list-projections', Str :$type = '', Str :$stream = '', Str :$status = '',
           UInt :$limit = 100, UInt :$offset = 0, Bool :$json = False,
           Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    list-entities($driver, $database, $debug, :kind<projection>, :$type, :$stream, :$status, :$limit, :$offset, :$json);
}

#| List persisted saga instances and their stored workflow status.
multi MAIN('list-sagas', Str :$type = '', Str :$stream = '', Str :$status = '',
           UInt :$limit = 100, UInt :$offset = 0, Bool :$json = False,
           Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    list-entities($driver, $database, $debug, :kind<saga>, :$type, :$stream, :$status, :$limit, :$offset, :$json);
}

#| Show persisted entity state and recent event and command history.
multi MAIN('inspect', Str :$stream, UInt :$limit = 60, Bool :$json = False,
           Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    with-store $driver, $database, $debug, {
        my $inspector = RedSourcing::Inspector.new(:stored-only);
        if $stream.defined {
            my $instance = $inspector.instances.first(*.<stream> eq $stream);
            die "Unknown stream '$stream'" unless $instance.defined;
            output(%(instance => $instance,
                events => $inspector.events(:$stream, :$limit),
                commands => $inspector.commands(:$stream, :$limit)), $json, &format-inspection);
        } else { output($inspector.report(:$limit), $json, &format-inspection) }
    }
}

#| Show a saga's committed state, next action, retries, timeouts and compensation stack.
multi MAIN('saga-status', Str $entity = '', Str :$stream, :I(:@includes), :M(:@modules),
           Str :$ids = '{}', :id(:@identity), Bool :$details = False, Bool :$json = False,
           Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    die 'Pass either a saga entity with its IDs or --stream'
        unless so($entity.chars) != $stream.defined;
    die '--stream cannot be combined with identity options'
        if $stream.defined && (@identity || (%*CLI-OPTIONS<ids>:exists));
    with-store $driver, $database, $debug, {
        my $selected = $stream;
        if $entity.chars {
            my Mu $type = entity-type($entity, @includes, @modules);
            die 'saga-status requires a saga' unless $type.HOW ~~ Metamodel::RedSourcing::SagaHOW;
            $selected = entity-proxy($type, $ids, @identity).^stream-name;
        } elsif @includes || @modules {
            imported-code(@includes, @modules, 'True');
        }
        output(RedSourcing::Inspector.new(:stored-only).saga-status(:stream($selected)), $json,
            -> %report { format-saga-status(%report, :$details) });
    }
}

#| Show journal rates, failures, retries and per-entity metrics.
multi MAIN('stats', UInt :$minutes = 60, Bool :$json = False,
           Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    with-store $driver, $database, $debug, {
        my @instances = |RedSourcing::Inspector.new(:stored-only).instances;
        output(store-metrics(:@instances, :$minutes), $json, &format-metrics);
    }
}

#| Show an entity description, identity fields and original command signatures.
multi MAIN('describe', Str $entity, :I(:@includes), :M(:@modules), Bool :$json = False,
           Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    with-store $driver, $database, $debug, {
        my Mu $type = entity-type($entity, @includes, @modules);
        output(%(entity => $type.^name, kind => RedSourcing::Inspector.new.kind($type),
            |(:description(declarator-description($type)) if $type.WHY.defined),
            ids => $type.^entity-id-names.Array,
            commands => $type.^commands.keys.sort.map(-> $name {
                my &handler = $type.^commands{$name};
                %(name => $name, signature => &handler.signature.gist,
                    |command-declaration(&handler),
                    |(:description(declarator-description(&handler)) if &handler.WHY.defined),
                    parameters => &handler.signature.params.grep({ !.invocant && !.slurpy }).map({
                        %(name => .name, aliases => .named_names.Array, type => .type.^name,
                            named => .named, optional => .optional)
                    }).Array)
            }).Array), $json, &format-description);
    }
}

#| Create an entity by storing its initial snapshot; reject existing streams.
multi MAIN('create', Str $entity, :I(:@includes), :M(:@modules),
           Str :$ids = '{}', :id(:@identity), Str :d(:$data) = '{}', Bool :$json = False,
           Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    with-store $driver, $database, $debug, {
        my Mu $type = entity-type($entity, @includes, @modules);
        my $proxy = entity-proxy($type, $ids, @identity);
        my %initial = json-object($data, '--data');
        my @allowed = $type.^attributes.grep(*.has_accessor).map(*.name.substr(2))
            .grep({ $_ ne any(|$type.^entity-id-names, 'stream', 'version', 'current-id', 'saga-state') });
        my @unknown = %initial.keys.grep({ $_ ne any(@allowed) }).sort;
        die 'Unknown initial fields: ' ~ @unknown.join(', ') if @unknown;
        # Never use create as an implicit reset of an existing entity.
        die 'Stream already exists: ' ~ $proxy.^stream-name
            if StoredEvent.^all.grep(*.stream eq $proxy.^stream-name).head;
        output(event-record($proxy.^create(|%initial)), $json,
            -> $row { format-details('Created entity', $row) });
    }
}

#| Restore an entity from its snapshot and replay events without writing records.
multi MAIN('load', Str $entity, :I(:@includes), :M(:@modules), Str :$ids = '{}', :id(:@identity), Bool :$json = False,
           Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    with-store $driver, $database, $debug, {
        my Mu $type = entity-type($entity, @includes, @modules);
        output(entity-record(entity-proxy($type, $ids, @identity).^load), $json,
            -> $record { format-details('Loaded entity', $record) });
    }
}

#| Restore an entity and store a new snapshot of its replayed state.
multi MAIN('snapshot', Str $entity, :I(:@includes), :M(:@modules), Str :$ids = '{}', :id(:@identity), Bool :$json = False,
           Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    with-store $driver, $database, $debug, {
        my Mu $type = entity-type($entity, @includes, @modules);
        my $loaded = entity-proxy($type, $ids, @identity).^load;
        output(event-record($loaded.^emit-snapshot), $json,
            -> $row { format-details('Snapshot stored', $row) });
    }
}

#| Execute an existing command by its stored numeric ID.
multi MAIN('run-command', UInt $id, :I(:@includes), :M(:@modules), Bool :$wait = False, Bool :$json = False,
           Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    with-store $driver, $database, $debug, {
        imported-code(@includes, @modules, 'True');
        trace-operation;
        my $row = StoredCommand.^all.grep(*.id == $id).head;
        die "Unknown command ID $id" unless $row;
        $row.run(:$wait);
        $row.^refresh;
        output(command-record($row), $json, -> $record { format-details('Command', $record) });
    }
}

#| Process due pending commands once, or poll continuously with --watch.
multi MAIN('work', :I(:@includes), :M(:@modules), Str :$stream, Str :$entity,
           UInt :$limit = $cli-config.worker.limit // 100,
           Bool :$watch = $cli-config.worker.watch, Numeric :$interval = $cli-config.worker.interval // 1, Bool :$json = False,
           Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    die 'limit and interval must be positive' unless $limit > 0 && $interval > 0;
    with-store $driver, $database, $debug, {
        imported-code(@includes, @modules, 'True');
        trace-operation;
        my $stopping = False;
        my $tap = signal(SIGINT).tap({ $stopping = True }) if $watch;
        LEAVE $tap.close if $tap.defined;
        my $first-pass = True;
        repeat {
            my @processed;
            my $failed = False;
            # Snapshot IDs before executing: newly enqueued work belongs to the next pass.
            my @rows = selected-commands(:$stream, :$entity, :state<Pending>, :due).head($limit).Seq;
            for @rows -> $row {
                last if $stopping;
                my $error;
                try {
                    CATCH { default { $error = .message; $failed = True } }
                    $row.run;
                }
                $row.^refresh;
                @processed.push(%(|command-record($row), |(:execution-error($error) with $error)));
            }
            if $json || @processed || $first-pass {
                output(%(processed => @processed.Array), $json, &format-work);
                $*OUT.flush;
            }
            $first-pass = False;
            exit 1 if $failed && !$watch;
            # Short waits keep Ctrl-C responsive even with a large polling interval.
            my $deadline = now + $interval;
            await Promise.in(0.1 min ($deadline - now)) while $watch && !$stopping && now < $deadline;
        } while $watch && !$stopping;
    }
}

#| Advance one saga through reactions, retries, compensations and due timeouts.
multi MAIN('advance', Str $entity, :I(:@includes), :M(:@modules), Str :$ids = '{}', :id(:@identity),
           UInt :$limit = 100, Str :$now, Bool :$json = False,
           Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    die 'limit must be positive' unless $limit > 0;
    with-store $driver, $database, $debug, {
        my Mu $type = entity-type($entity, @includes, @modules);
        die 'advance requires a saga' unless $type.HOW ~~ Metamodel::RedSourcing::SagaHOW;
        my $proxy = entity-proxy($type, $ids, @identity);
        my %options = :$limit;
        %options<now> = DateTime.new($now) with $now;
        output(entity-record($proxy.^advance(|%options)), $json,
            -> $record { format-details('Saga state', $record) });
    }
}

#| Discover and advance every active persisted saga, once or repeatedly.
multi MAIN('advance-sagas', :I(:@includes), :M(:@modules), UInt :$limit = 100,
           Str :$now, Bool :$watch = False, Numeric :$interval = 1, Bool :$json = False,
           Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    die 'limit and interval must be positive' unless $limit > 0 && $interval > 0;
    my %options = :$limit;
    %options<now> = DateTime.new($now) with $now;
    with-store $driver, $database, $debug, {
        imported-code(@includes, @modules, 'True');
        trace-operation;
        my $stopping = False;
        my $tap = signal(SIGINT).tap({ $stopping = True }) if $watch;
        LEAVE $tap.close if $tap.defined;
        my $first-pass = True;
        repeat {
            my %report = advance-sagas(|%options);
            if $json || %report<advanced> || %report<failed> || $first-pass {
                output(%report, $json, &format-saga-controller);
                $*OUT.flush;
            }
            $first-pass = False;
            exit 1 if %report<failed> && !$watch;
            my $deadline = now + $interval;
            await Promise.in(0.1 min ($deadline - now)) while $watch && !$stopping && now < $deadline;
        } while $watch && !$stopping;
    }
}

#| Record a confirmed result or error for a running or blocked saga action.
multi MAIN('resolve-action', Str $entity, Str $action-id, :I(:@includes), :M(:@modules),
           Str :$ids = '{}', :id(:@identity), Str :$result, Str :$error, Bool :$json = False,
           Str :f(:$file), Str :$driver = $cli-config.driver // 'SQLite', Str :$database = $cli-config.database // 'a.db', Bool :$debug = $cli-config.debug) {
    die 'Pass exactly one of --result (JSON) or --error'
        unless $result.defined != $error.defined;
    with-store $driver, $database, $debug, {
        my Mu $type = entity-type($entity, @includes, @modules);
        die 'resolve-action requires a saga' unless $type.HOW ~~ Metamodel::RedSourcing::SagaHOW;
        my $loaded = entity-proxy($type, $ids, @identity).^load;
        my %outcome;
        %outcome<result> = from-json($result) with $result;
        %outcome<error> = $error with $error;
        $loaded.^resolve-action($action-id, |%outcome);
        output(entity-record($loaded), $json,
            -> $record { format-details('Reconciled saga', $record) });
    }
}
