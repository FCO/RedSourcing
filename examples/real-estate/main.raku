#!/usr/bin/env raku
use Cro::HTTP::Server;
use RedSourcing::Web::Server;
use RedSourcing;
use Estate::App;
use Estate::Routes;

# Run from the repository root; see README for installation and overrides.
sub MAIN(Str :f(:$file) = $?FILE.IO.parent.add('red-sourcing.rakuconf').absolute.Str,
         Str :$driver, Str :$database,
         Str :$host = '127.0.0.1', UInt :$port = 3000, Bool :$seed = True) {
    my $settings = red-sourcing-defaults(:$file, :$driver, :$database);
    my $*RED-FALLBACK = False;
    my $*RED-DEBUG = $settings.debug;
    my $app = App.new.initialize(:$seed).start-controller;
    my $server = web-server(:$host, :$port,
        :application(estate-routes($app)));
    $server.start;
    say "Hearth: http://{$host}:{$port}/";
    say "Store: {$settings.driver} / {$settings.database}";
    $*OUT.flush;
    react whenever signal(SIGINT) {
        $app.stop-controller;
        $server.stop;
        done;
    }
}
