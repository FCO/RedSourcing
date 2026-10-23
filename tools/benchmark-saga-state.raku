#!/usr/bin/env raku
use RedSourcing;
use RedSourcing::Flow;
use JSON::Fast;

saga StateBenchmark {
    has Str $.key is entity-id;
    method APPLY(Event $event) { }
    method queue(UInt $count) {
        self.^service('benchmark-only', 'noop', \(:payload(%(label => 'x' x 128, items => [1..8]))),
            :!compensation) for ^$count;
    }
    method pulse(UInt $index) { self.^state<actions>[$index % self.^state<actions>.elems]<attempts>++ }
}

sub MAIN(UInt :$actions = 12, UInt :$controls = 8, UInt :$reads = 12, UInt :$clones = 12) {
    die 'all counts must be positive' unless $actions && $controls && $reads && $clones;
    red-sourcing-defaults(:driver<SQLite>, :database(':memory:'));
    register-service('benchmark-only', -> | { die 'benchmark adapter must not execute' });
    my $workflow = StateBenchmark.^with-ids(:key<benchmark>); $workflow.^create;
    my @phases;
    sub measure(Str $phase, UInt $operations, &work) {
        my $start = now;
        my $result = work();
        @phases.push(%(:$phase, :$operations, seconds => (now - $start).Num, :$result));
    }
    measure 'plan-actions', $actions, { $workflow.^load.queue($actions); $workflow.^load.^state<actions>.elems };
    measure 'commit-controls', $controls, {
        $workflow.^load.pulse($_) for ^$controls;
        [+] $workflow.^load.^state<actions>.map(*.<attempts>)
    };
    measure 'restore-state', $reads, {
        [+] (^$reads).map({ $workflow.^load.^state<actions>.elems })
    };
    my $loaded = $workflow.^load;
    measure 'clone-state', $clones, {
        [+] (^$clones).map({ $loaded.^clone-state.^state<actions>.elems })
    };
    flow-projection(); # Exclude lazy module loading from repeated graph reads.
    measure 'read-flow', $reads, {
        [+] (^$reads).map({ flow-projection().links.elems })
    };
    say to-json(%(:$actions, :$controls, :$reads, :$clones, phases => @phases), :!pretty);
}
