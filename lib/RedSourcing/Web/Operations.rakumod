use RedSourcing::CLI::Application ();
use RedSourcing::Config;
use JSON::Fast;

unit class RedSourcing::Web::Operations;

# Jobs run the actual CLI dispatcher in a separate Raku process. The monitor's
# stored-only connection, dynamic Red defaults and polling loop stay isolated.
has Settings $.settings is required;
has IO::Path $.directory = $*CWD;
has UInt $.max-running = 4;
has UInt $.history-limit = 32;
has UInt $.output-limit = 1048576;
has Lock $!lock .= new;
has %!jobs;
has UInt $!next-id = 0;
has Bool $!closed = False;
has IO::Path $!temporary;
has IO::Path $!config;
has @!repositories;
has @!catalog;

submethod TWEAK {
    @!catalog = RedSourcing::CLI::Application::operation-schema();
    @!repositories = $*REPO.repo-chain.grep({
        $_ ~~ CompUnit::Repository::FileSystem | CompUnit::Repository::Installation
    }).map({ '-I' ~ ($_ ~~ CompUnit::Repository::Installation ?? 'inst#' !! '') ~ .prefix.Str }).unique;
    # A private configuration freezes the selected store and connection options.
    # Children never discover a different parent configuration after startup.
    $!temporary = $*TMPDIR.add("red-sourcing-console-{$*PID}-{now.Int}-{(2**53).rand.Int}");
    $!temporary.mkdir(:mode(0o700));
    $!config = $!temporary.add('console.rakuconf');
    $!config.spurt('use RedSourcing::Config; config {'
        ~ '.driver = ' ~ $!settings.driver.raku ~ ';'
        ~ '.database = ' ~ $!settings.database.raku ~ ';'
        ~ '.debug = ' ~ $!settings.debug.raku ~ ';'
        ~ '.flow-tracing = ' ~ $!settings.flow-tracing.raku ~ ';'
        ~ '.includes = ' ~ $!settings.includes.Array.raku ~ ';'
        ~ '.modules = ' ~ $!settings.modules.Array.raku ~ ';'
        ~ '.connection = ' ~ $!settings.connection.raku ~ ';'
        ~ '.entities = ' ~ $!settings.entities.raku ~ ';'
        ~ '.auto-snapshot = ' ~ ($!settings.auto-snapshot.defined ?? $!settings.auto-snapshot.raku !! 'Nil') ~ ';'
        ~ '.worker: { .limit = ' ~ ($!settings.worker.limit // 100)
        ~ '; .interval = ' ~ ($!settings.worker.interval // 1) ~ '; .watch = False } }');
    $!config.chmod(0o600);
}

method catalog() { @!catalog }
method configuration() {
    %(driver => $!settings.driver, database => $!settings.database,
        includes => $!settings.includes.Array, modules => $!settings.modules.Array,
        flow-tracing => $!settings.flow-tracing,
        worker-limit => $!settings.worker.limit // 100,
        worker-interval => $!settings.worker.interval // 1,
        max-running => $!max-running, history-limit => $!history-limit)
}
method definition(Str $operation --> Hash) {
    for @!catalog -> %group {
        for %group<commands>.List -> %command {
            return %command if %command<name> eq $operation;
        }
    }
    die "Unknown operation '$operation'"
}
method arguments(Str $operation, :@positionals = [], :%options = {} --> Array) {
    die 'The monitor is already running; use its settings page'
        if $operation eq 'web-monitor';
    my %definition = self.definition($operation);
    my @params = %definition<positionals>.List;
    die 'Too many positional arguments' if @positionals > @params;
    for @params.kv -> $index, %param {
        die "Missing {%param<name>}" if %param<required> && !(@positionals[$index] // '').chars;
    }
    die 'Positional arguments must be nonempty strings and cannot begin with a dash'
        if @positionals.first({ $_ !~~ Str || !.chars || .starts-with('-') }).defined;
    my %fields = %definition<options>.map({ .<name> => $_ }).Hash;
    my @arguments = $operation, |@positionals;
    for %options.keys.sort -> $name {
        die "Unknown option '$name' for $operation" unless %fields{$name}:exists;
        die "The monitor fixes --$name at startup" if $name eq any(<file driver database>);
        my $value = %options{$name};
        my %field = %fields{$name};
        if %field<boolean> {
            die "--$name must be a boolean" unless $value ~~ Bool;
            @arguments.push($value ?? "--$name" !! "--/$name");
        } elsif %field<repeated> {
            die "--$name must be an array of strings" unless $value ~~ Positional
                && !$value.first(* !~~ Str).defined;
            @arguments.append($value.map({ "--$name=$_" }));
        } else {
            die "--$name must be a string" unless $value ~~ Str;
            @arguments.push("--$name=$value");
        }
    }
    for %fields.values.grep(*.<required>) -> %field {
        die "Missing --{%field<name>}" unless %options{%field<name>}:exists;
    }
    # Continuous work is opt-in in the browser, even if the CLI config watches.
    @arguments.push('--/watch') if $operation eq any(<work advance-sagas>) && !(%options<watch>:exists);
    @arguments.Array
}

method !public(%job --> Hash) {
    %job.grep({ .key ne any(<process finished completed>) }).Hash
}
method jobs() { $!lock.protect({ %!jobs.values.sort(-*.<id>).map({ self!public($_) }).Array }) }
method job(UInt $id) { $!lock.protect({ %!jobs{$id}:exists ?? self!public(%!jobs{$id}) !! Nil }) }
method !append(UInt $id, Str $field, Str $chunk) {
    $!lock.protect({
        my %job := %!jobs{$id};
        my $space = $!output-limit - %job{$field}.chars;
        %job{$field} ~= $chunk.substr(0, $space) if $space > 0;
        %job<truncated> = True if $chunk.chars > $space;
    });
}
method submit(Str $operation, :@positionals = [], :%options = {}, :%context = {} --> Hash) {
    my @arguments = self.arguments($operation, :@positionals, :%options);
    my $id;
    my $proc;
    my $finished;
    $!lock.protect({
        die 'The console is shutting down' if $!closed;
        die "All {$!max-running} execution slots are busy; stop a worker or wait for a job"
            if %!jobs.values.grep({ .<state> eq any(<running stopping>) }).elems >= $!max-running;
        # Retain active jobs; prune only completed history.
        while %!jobs.elems >= $!history-limit {
            my $old = %!jobs.values.sort(*.<id>).first({ .<state> ne any(<running stopping>) });
            last unless $old.defined;
            %!jobs{$old<id>}:delete;
        }
        $id = ++$!next-id;
        $proc = Proc::Async.new($*EXECUTABLE.Str, |@!repositories, '-e',
            'use RedSourcing::CLI::Application; my %*SUB-MAIN-OPTS = :named-anywhere, :coerce-allomorphs-to(Numeric); initialize-cli();',
            |@arguments, "--file=$!config");
        %!jobs{$id} = %( :$id, :$operation, arguments => @arguments, context => %context,
            state => 'running', started => DateTime.now.Str, ended => '',
            stdout => '', stderr => '', truncated => False, process => $proc);
        $proc.stdout.tap(-> $chunk { self!append($id, 'stdout', $chunk) });
        $proc.stderr.tap(-> $chunk { self!append($id, 'stderr', $chunk) });
        $finished = $proc.start(:cwd($!directory));
        %!jobs{$id}<finished> = $finished;
    });
    my $completed = $finished.then(-> $promise {
        $!lock.protect({
            my %job := %!jobs{$id};
            try {
                CATCH { default { %job<stderr> ~= .message; %job<state> = 'failed' } }
                my $result = $promise.result;
                %job<exit-code> = $result.exitcode;
                %job<signal> = $result.signal;
                %job<state> = %job<state> eq 'stopping' ?? 'cancelled'
                    !! $result.exitcode == 0 && $result.signal == 0 ?? 'succeeded' !! 'failed';
            }
            %job<ended> = DateTime.now.Str;
        });
    });
    $!lock.protect({ %!jobs{$id}<completed> = $completed });
    self.job($id)
}
method describe(Str $entity --> Hash) {
    my %job = self.submit('describe', :positionals([$entity]), :options{:json});
    my $completed = $!lock.protect({ %!jobs{%job<id>}<completed> });
    await $completed;
    %job = self.job(%job<id>);
    die 'Entity definition unavailable. Configure the application modules in the monitor settings.'
        unless %job<state> eq 'succeeded' && !%job<truncated>;
    from-json(%job<stdout>)
}
method stop(UInt $id --> Hash) {
    my ($proc, $finished);
    $!lock.protect({
        die "Unknown job $id" unless %!jobs{$id}:exists;
        my %job := %!jobs{$id};
        if %job<state> eq 'running' {
            %job<state> = 'stopping';
            $proc = %job<process>;
            $finished = %job<finished>;
        }
    });
    if $proc.defined {
        try $proc.kill(SIGINT);
        start {
            await Promise.anyof($finished, Promise.in(3));
            try $proc.kill(SIGKILL) if $finished.status == Planned;
        }
    }
    self.job($id)
}
method close() {
    my @ids = $!lock.protect({ $!closed = True;
        %!jobs.values.grep(*.<state> eq 'running').map(*.<id>).Array });
    self.stop($_) for @ids;
    my @finished = $!lock.protect({ %!jobs.values.map(*.<finished>).grep(*.defined).Array });
    await Promise.anyof(Promise.allof(@finished), Promise.in(5)) if @finished;
    $!config.unlink if $!config.defined && $!config.f;
    $!temporary.rmdir if $!temporary.defined && $!temporary.d;
}
