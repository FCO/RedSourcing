#!/usr/bin/env raku
use lib $?FILE.IO.parent.add('lib').Str;
use RedSourcing;
use RedSourcing::Service;
use Microblog::Domain;

sub MAIN(Str :$file = $?FILE.IO.parent.add('red-sourcing.rakuconf').Str,
        Str :$driver, Str :$database, Str :$application = 'microblog',
        Str :$host = '127.0.0.1', Int :$port = 3090,
        Bool :$seed = True, Bool :$rebuild = False) {
    my $settings = red-sourcing-defaults(:$file, :$driver, :$database);
    initialize-tweets;
    initialize-application($application);
    if $rebuild { rebuild-tweets($application); say 'Tweet index rebuilt; journal preserved.'; return }
    seed($application) if $seed;
    my $runtime = ServiceRuntime.new(:poll-interval(.1)).initialize;
    LEAVE $runtime.shutdown;
    my $server = TweetIndex.^with-ids: :application-id($application);
    my $recover-until = now + 35;
    while $server.^service-status('serve')<phase> eq 'stopping' {
        $runtime.tick;
        die 'Previous service is still stopping' if now > $recover-until;
        await Promise.in: .05;
    }
    $server.^start-service: 'serve', :args(%(:$host, :$port,
        assets => $?FILE.IO.parent.add('public').absolute.Str)), :idle-timeout(3600);
    my $controller = $runtime.run;
    my $deadline = now + 30;
    until $server.^service-status('serve')<phase> eq 'active' {
        die 'HTTP did not start: ' ~ $server.^service-status('serve').raku if now > $deadline;
        await Promise.in: .05;
    }
    say "Pio: http://{$host}:{$port}/";
    say "Store: {$settings.driver} / {$settings.database}";
    $*OUT.flush;
    react {
        whenever signal(SIGINT) { done }
        whenever signal(SIGTERM) { done }
        whenever $controller { done }
    }
    $server.^stop-service: 'serve';
    my $stop-until = now + 12;
    while $server.^service-status('serve')<phase> eq 'stopping' && now < $stop-until {
        await Promise.in: .05;
    }
    $runtime.shutdown;
    await $controller;
}
