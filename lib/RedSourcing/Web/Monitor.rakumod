use RedSourcing;
use RedSourcing::Inspector;
use RedSourcing::Web;
use RedSourcing::Web::Server;
use RedSourcing::Web::Metrics;
use RedSourcing::Web::Operations;
use RedSourcing::Web::Console;
use RedSourcing::Config;
use RedSourcing::Flow;
use Cro::HTTP::Router;
unit module RedSourcing::Web::Monitor;

sub run-monitor(Str :$driver = 'SQLite', Str :$database!, Str :$host = '127.0.0.1',
                UInt :$port = 3001, UInt :$minutes = 60, Str :$app-url = '', Bool :$debug = False,
                :%connection = {}, :@includes = [], :@modules = [],
                Settings :$settings = Settings.new, Bool :$allow-new-store = False,
                :@origins = []) is export {
    die 'minutes must be between 1 and 1440' unless 1 <= $minutes <= 1440;
    die 'Database does not exist; point the monitor at an existing store'
        if !$allow-new-store && $driver eq 'SQLite' && !$database.IO.f;
    die 'The operations console requires a persistent database, not SQLite :memory:'
        if $driver eq 'SQLite' && $database eq ':memory:';
    my $*RED-FALLBACK = False;
    my $*RED-DEBUG = $debug;
    my $uninitialized = $allow-new-store && $driver eq 'SQLite' && !$database.IO.f;
    my $connected = !$uninitialized;
    red-defaults :default(store-driver($driver, $database, :%connection)) if $connected;
    my $inspector = RedSourcing::Inspector.new(:stored-only);
    my $lock = Lock.new;
    my $changes = Supplier.new;
    my $cached;
    my $stamp = '';
    my $stopping = False;
    my $operations = RedSourcing::Web::Operations.new(:settings($settings.clone(:$driver,
        :database($driver eq 'SQLite' ?? $database.IO.absolute.Str !! $database), :$debug,
        :includes((|$settings.includes, |@includes.map(*.IO.absolute.Str)).unique.Array),
        :modules((|$settings.modules, |@modules).unique.Array), :connection(%connection))));
    LEAVE $operations.close if $operations.defined;
    my sub current-stamp {
        return 'uninitialized' if $uninitialized && !$database.IO.f;
        unless $connected {
            red-defaults :default(store-driver($driver, $database, :%connection));
            $connected = True;
        }
        if $allow-new-store {
            my $revision = try $inspector.revision;
            return 'uninitialized' unless $revision.defined;
            return $revision ~ '/' ~ flow-revision() ~ '/' ~ (now.to-posix.head.Int div 60);
        }
        $inspector.revision ~ '/' ~ flow-revision() ~ '/' ~ (now.to-posix.head.Int div 60)
    }
    my sub report {
        $lock.protect({
            my $current = current-stamp();
            if $current eq 'uninitialized' {
                $stamp = $current;
                return %(types => [], instances => [], events => [], commands => [], stored-only => True,
                    store-error => 'The selected store is not initialized. Use init to create its event and command tables.');
            }
            if !$cached.defined || $current ne $stamp {
                $cached = $inspector.report;
                $cached<metrics> = store-metrics(:instances($cached<instances>), :$minutes);
                $stamp = $current;
            }
            $cached
        })
    }
    report(); # Check the schema before binding a port; never create tables.
    my $address = $host.contains(':') ?? "[$host]" !! $host;
    my @allowed-origins = @origins ?? @origins.List !! $host eq any(<127.0.0.1 localhost 0.0.0.0>)
        ?? ("http://127.0.0.1:$port", "http://localhost:$port") !! ("http://$address:$port",);
    my &updates = -> {
        supply {
            emit "retry: 1500\nevent: refresh\ndata: connected\n\n";
            whenever $changes.Supply { emit "event: refresh\ndata: changed\n\n" }
            whenever Supply.interval(15) { emit ": keepalive\n\n" }
        }
    };
    my $routes = route {
        get -> { redirect '/monitor', :see-other }
        include assets => web-asset-routes;
        include monitor => route {
            include operations => console-routes($operations, :&report, :origins(@allowed-origins), :$app-url,
                :lookup(-> $view, $name {
                    return Nil unless $name ~~ /^ <[0..9]>+ $/ && $name.UInt > 0;
                    $lock.protect({ ($view eq 'command' ?? $inspector.commands(:id($name.UInt), :limit(1))
                        !! $inspector.events(:id($name.UInt), :limit(1))).head })
                }));
        };
        include monitor => inspector-routes($inspector, :&updates, :&report,
            :$app-url, :operations-url('/monitor/operations'), :synchronize(-> &work { $lock.protect(&work) }));
    };
    my $server = web-server(:$host, :$port, :application($routes));
    $server.start;
    my $poller = start {
        until $stopping {
            await Promise.in(1);
            last if $stopping;
            try {
                CATCH { default { note 'Monitor refresh failed: ' ~ .message } }
                my $changed = $lock.protect({ current-stamp() ne $stamp });
                $changes.emit(True) if $changed;
            }
        }
    };
    say "RedSourcing monitor: http://{$host}:{$port}/monitor";
    say "Store: $driver / $database (database-only inspection)";
    $*OUT.flush;
    react whenever signal(SIGINT) { done }
    $stopping = True;
    await $poller;
    $changes.done;
    $server.stop;
}
