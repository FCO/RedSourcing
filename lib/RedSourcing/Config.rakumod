use Configuration;
use Red;
use Red::Database;
use RedSourcing::Flow;
use RedSourcing::StoredEvent;
use RedSourcing::StoredCommand;
use RedSourcing::Lifecycle;
unit module RedSourcing::Config;

class MonitorSettings does Configuration::Node {
    has Str $.host;
    has UInt $.port;
    has UInt $.minutes;
    has Str $.app-url;
    has Str @.origins;
    has Bool $.allow-new-store = False;
}
class WorkerSettings does Configuration::Node {
    has UInt $.limit;
    has Numeric $.interval;
    has Bool $.watch = False;
}
class Settings does Configuration::Node is export {
    has Str $.driver;
    has Str $.database;
    has Bool $.debug = False;
    has Bool $.flow-tracing = False;
    has Str @.includes;
    has Str @.modules;
    has %.connection;
    has %.entities;
    has $.auto-snapshot;
    has MonitorSettings $.monitor .= new;
    has WorkerSettings $.worker .= new;
    submethod TWEAK(|args) {
        $!auto-snapshot = default-auto-snapshot() unless args.hash<auto-snapshot>:exists;
    }
}

# Export the builder DSL without Configuration's process-global discovery.
# Each call reads exactly one explicitly selected or nearest configuration file.
sub config(&block) is export {
    Configuration.new(:root(Settings), :block(-> { Nil })).generate-config.(&block)
}

sub find-config(IO::Path $directory = $*CWD --> IO::Path) is export {
    my $current = $directory.absolute.IO;
    loop {
        my $candidate = $current.add('red-sourcing.rakuconf');
        if $candidate.e {
            die "Configuration path is not a file: $candidate" unless $candidate.f;
            return $candidate;
        }
        my $parent = $current.parent;
        return IO::Path if $parent eq $current;
        $current = $parent;
    }
}

sub load-cli-config(@arguments, IO::Path :$directory = $*CWD --> Hash) is export {
    # Help must remain usable even with a broken configuration in a parent.
    return %(settings => Settings.new, directory => IO::Path)
        if @arguments.first(* eq any('--help', '-h')).defined;
    my @files;
    for @arguments.kv -> $index, $argument {
        if $argument eq any('-f', '--file') {
            my $value = @arguments[$index + 1];
            die "$argument requires a configuration filename"
                unless $value.defined && $value.chars && !$value.starts-with('-');
            @files.push($value);
        } elsif $argument.starts-with('-f=') || $argument.starts-with('--file=') {
            my $value = $argument.split('=', 2).tail;
            die 'Configuration filename must not be empty' unless $value.chars;
            @files.push($value);
        }
    }
    die 'Pass only one configuration file' if @files > 1;
    load-config(:file(@files.head), :$directory)
}

sub load-config(IO() :$file, IO::Path :$directory = $*CWD --> Hash) is export {
    my $selected = $file.defined ?? absolute-path($directory, $file.Str) !! find-config($directory);
    return %(settings => Settings.new, directory => IO::Path) unless $selected.defined;
    die "Configuration file does not exist: $selected" unless $selected.f;
    my $settings = Configuration.new(:root(Settings), :file($selected)).single-run;
    die "Configuration file must return a RedSourcing config block: $selected"
        unless $settings ~~ Settings;
    validate-connection($settings.connection);
    lifecycle-settings($settings.entities);
    snapshot-policy($settings.auto-snapshot);
    my @paths = $settings.includes.map({ absolute-path($selected.parent, $_).Str });
    %(settings => $settings.clone(:includes(@paths)), directory => $selected.parent)
}

sub validate-connection(%connection) {
    for <driver database debug includes modules entities auto-snapshot> -> $reserved {
        die "Set '$reserved' at the top level, not in connection"
            if %connection{$reserved}:exists;
    }
}

# Explicit initialization keeps ordinary domain imports free of connection changes.
# Scoped $*RED-DEBUG values override the configured process default.
sub red-sourcing-defaults(IO() :$file, IO::Path :$directory = $*CWD,
        Str :$driver, Str :$database, Bool :$debug, Bool :$flow-tracing,
        Bool :$initialize = True, :%connection = {} --> Settings) is export {
    my %loaded = load-config(:$file, :$directory);
    my $settings = %loaded<settings>;
    my $selected-driver = $driver // $settings.driver // 'SQLite';
    my $selected-database = config-database($selected-driver,
        $database // $settings.database // 'a.db', %loaded<directory>, :explicit($database.defined));
    my %options = |$settings.connection, |%connection;
    validate-connection(%options);
    my $effective = $settings.clone(:driver($selected-driver), :database($selected-database),
        :debug($debug // $settings.debug), :flow-tracing($flow-tracing // $settings.flow-tracing), :connection(%options));
    red-defaults :default(store-driver($selected-driver, $selected-database, :connection(%options)));
    configure-lifecycles($effective.entities, :auto-snapshot($effective.auto-snapshot));
    $PROCESS::RED-DEBUG = $effective.debug;
    if $initialize {
        .^create-table(:unless-exists) for RedSourcing::StoredEvent, RedSourcing::StoredCommand;
        .^create-indexes for RedSourcing::StoredEvent, RedSourcing::StoredCommand;
    }
    enable-flow-tracing(:$initialize) if $effective.flow-tracing;
    $effective
}

sub absolute-path(IO::Path $directory, Str $path --> IO::Path) {
    $path.IO.is-absolute ?? $path.IO.absolute.IO !! $directory.add($path).absolute.IO
}

sub config-database(Str $driver, Str $database, IO::Path $directory, Bool :$explicit = False --> Str) is export {
    return $database if $explicit || !$directory.defined || $driver ne 'SQLite'
        || $database eq ':memory:' || $database.starts-with('file:') || $database.IO.is-absolute;
    $directory.add($database).absolute.Str
}

# Red passes constructor options through verbatim; Pg names its database dbname.
# The selected database wins over any driver-specific value in the connection.
sub store-connection-options(Str $driver, Str $database, :%connection = {} --> Hash) is export {
    my %options = %connection;
    if $driver eq 'Pg' {
        %options<database>:delete;
        %options<dbname> = $database;
    } else {
        %options<database> = $database;
    }
    %options
}

sub store-driver(Str $driver, Str $database, :%connection = {}) is export {
    my %options = store-connection-options($driver, $database, :%connection);
    if $driver eq 'Pg' {
        require ::('RedSourcing::PgJSON');
        require ::('DB::Pg');
        unless %options<dbh>:exists {
            # Red already encodes/inflates JSON. DB::Pg's JSON converter would
            # encode it a second time, storing strings instead of JSON objects.
            %options<host> //= '127.0.0.1';
            %options<port> //= 5432;
            my $info = %options.keys.sort.grep({ %options{$_}.defined }).map({
                my $value = %options{$_}.Str.subst('\\', '\\\\', :g).subst("'", "\\'", :g);
                "$_='$value'"
            }).join(' ');
            %options<dbh> = ::('DB::Pg').new(:conninfo($info), :converters(<DateTime UUID Geometric>));
        }
        return database($driver, |%options) but ::('RedSourcing::PgJSON');
    }
    database($driver, |%options)
}
