#!/usr/bin/env raku
use lib $?FILE.IO.parent.add('lib').Str;
use RedSourcing;
use CounterDemo;
red-sourcing-defaults(:file($?FILE.IO.parent.add('red-sourcing.rakuconf')),
    :database(%*ENV<REDSOURCING_EXAMPLE_DATABASE> // ':memory:'));
my $counter = Counter.^with-ids(:id(1));
$counter.^create;
say $counter.increment(:amount(2));
my $pending = $counter.increment(:amount(3), :!sync);
say $pending.state;
say $pending.run;
say $pending.run;
say CounterTotal.^with-ids(:1id).value;
