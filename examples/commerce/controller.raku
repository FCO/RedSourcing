#!/usr/bin/env raku
use lib $?FILE.IO.parent.add('lib').Str;
use RedSourcing;
use Commerce::App;

sub MAIN(Str :f(:$file) = $?FILE.IO.parent.add('red-sourcing.rakuconf').Str,
         Str :$database, Numeric :$interval where * > 0 = 1, Bool :$once = False) {
    my $settings = red-sourcing-defaults(:$file, :$database);
    my $shop = Shop.new.initialize;
    $shop.drain;
    return if $once;
    say "Commerce controller: {$settings.driver} / {$settings.database}";
    $*OUT.flush;
    my $stopped = Promise.new;
    my $tap = signal(SIGINT).tap({ $stopped.keep(True) unless $stopped.status });
    until $stopped.status {
        await Promise.anyof($stopped, Promise.in($interval));
        $shop.drain unless $stopped.status;
    }
    $tap.close;
}
