unit class Metamodel::RedSourcing::SagaHOW;
use Metamodel::RedSourcing::EntityHOW;
use Metamodel::RedSourcing::AggregateHOW;
use RedSourcing::Saga;
use RedSourcing::Utils;
use RedSourcing::Context;
use RedSourcing::Flow;
use RedSourcing::StoredEvent;
use RedSourcing::StoredCommand;
use RedSourcing::X::OptimisticLockFailed;
use JSON::Fast;
use Red;

also is Metamodel::RedSourcing::EntityHOW;

has $!state-attr;
has %!handlers;

sub copy-data($value) { from-json(to-json($value)) }
sub phase { (try $*REDSOURCING-PHASE) // '' }
sub clock { (try $*REDSOURCING-NOW) // DateTime.now }

method compose(Mu \entity, |) {
    die "'saga-state' is reserved for saga persistence"
        if entity.^attributes.first(*.name eq '$!saga-state');
    entity.^add_role(RedSourcing::Saga::Runtime);
    callsame;
    my %methods = entity.^method_table;
    $!state-attr = entity.^attributes.first(*.name eq '$!saga-state');
    my %accessors = entity.^attributes.grep(*.has_accessor).map({ .name.substr(2) => True });
    for %methods.kv -> $name, &handler {
        next if $name eq any(<APPLY new BUILD TWEAK set-timeout cancel-timeout>) || (%accessors{$name}:exists);
        %!handlers{$name} = &handler;
        &handler.wrap(my method (Mu:D \SELF: |c) {
            my $*REDSOURCING-SAGA-METHOD = $name;
            if phase() eq 'REACT' {
                callsame
            } else {
                die "Saga method '$name' is forbidden in APPLY" if phase() eq 'APPLY';
                SELF.^plan(-> $copy { $copy."$name"(|c) })
            }
        });
    }
}

method state(\entity) { $!state-attr.get_value(entity) }
method initialize-state(\entity, %state) { $!state-attr.set_value(entity, copy-data(%state)) }
method now(\entity --> DateTime) { clock() }
method status(\entity) { entity.^state<status> }
method pending-actions(\entity) { copy-data(entity.^state<actions>) }

method data(\entity) {
    Map(callsame, 'saga-state' => copy-data(entity.^state))
}

method values(\entity) { entity.^data.Hash.grep(*.key ne 'saga-state').Hash }

method restore-state(Mu:U \type, $snapshot, Str :$stream!, *%initial) {
    $snapshot ?? $snapshot.COERCE(type) !! type.bless(|%initial, :$stream)
}

# Loading reads only committed controls. It never calls REACT or an adapter.
method replay(\entity) {
    for RedSourcing::StoredEvent.list-events(:row, :stream(entity.^stream)) -> $row {
        next if $row.version <= entity.^version;
        next unless $row.mro.contains('|RedSourcing::Saga::Control|');
        my $control = $row.COERCE;
        entity.^adopt($control.values, $control.state, $control.cursor);
        entity.^version = $row.version;
    }
}

method adopt(\entity, %values, %state, UInt $cursor) {
    for entity.^attributes.grep(*.has_accessor) -> $attr {
        $attr.set_value(entity, %values{$attr.name.substr(2)});
    }
    $!state-attr.set_value(entity, copy-data(%state));
    entity.^current-id = $cursor;
}

method clone-state(\entity) {
    my $copy = entity.WHAT.bless(|copy-data(entity.^data).Hash, :stream(entity.^stream));
    $copy.^version = entity.^version;
    $copy.^current-id = entity.^current-id;
    $copy
}

method commit(\entity, $copy, Mu:U $type = RedSourcing::Saga::StateChanged, *%fields) {
    my $*REDSOURCING-PHASE = 'CONTROL';
    my $row = $type.new(
        :state(copy-data($copy.^state)), :values(copy-data($copy.^values)),
        :cursor($copy.^current-id), |%fields,
    ).emit(:stream(entity.^stream), :version(entity.^version + 1));
    entity.^adopt($copy.^values, $copy.^state, $copy.^current-id);
    entity.^version = $row.version;
    $row
}

method plan(\entity, &code) {
    die 'Saga effects are forbidden in APPLY' if phase() eq 'APPLY';
    my $copy = entity.^clone-state;
    my %before = copy-data($copy.^values);
    my $result = do {
        my $*REDSOURCING-PHASE = 'REACT';
        code($copy)
    };
    die 'REACT cannot change persisted domain state; use APPLY'
        unless %before eqv copy-data($copy.^values);
    entity.^commit($copy);
    $result
}

method react(\entity, $event) {
    my $handler = entity.^find_method('REACT');
    return unless $handler && $handler.cando(\(entity, $event));
    my %before = copy-data(entity.^values);
    my $*REDSOURCING-PHASE = 'REACT';
    entity.REACT($event);
    die 'REACT cannot change persisted domain state; use APPLY'
        unless %before eqv copy-data(entity.^values);
}

method apply(\entity, $event) {
    my $handler = entity.^find_method('APPLY');
    apply-event(entity, $event) if $handler && $handler.cando(\(entity, $event));
}

method emit-snapshot(\entity) {
    entity.^replay;
    my $row = entity.^write-snapshot(:version(entity.^version + 1),
        :replay-cursor(entity.^current-id));
    entity.^version = $row.version;
    $row
}

method policy($, %input) {
    die 'Unknown retry option' if %input.keys.grep({
        $_ ne any(<max max-attempts delay init-delay max-delay backoff>)
    });
    my $max = %input<max-attempts> // %input<max> // 1;
    die 'max-attempts must be a positive integer' unless $max ~~ Int && $max > 0;
    my $delay = %input<init-delay> // %input<delay> // 0;
    my $cap = %input<max-delay> // $delay;
    die 'Retry delays must be nonnegative' unless $delay ~~ Numeric && $cap ~~ Numeric
        && $delay >= 0 && $cap >= $delay;
    my $backoff = %input<backoff>;
    die 'Unsupported backoff' unless $backoff === Any || $backoff === Exponential;
    %(max => $max, delay => $delay, cap => $cap,
        exponential => $backoff === Exponential)
}

method enqueue(\entity, Str $kind, Str $target, %ids, Str $method, Capture $args,
               :%retry = {}, :$compensation) {
    die 'Saga effects are forbidden in APPLY' if phase() eq 'APPLY';
    die 'Cannot start a forward operation after completion or compensation'
        unless entity.^status eq 'running' || (try $*REDSOURCING-COMPENSATION).so;
    my $origin = (try $*REDSOURCING-SAGA-METHOD) // $method;
    my $undo = $compensation;
    $undo = "compensate-$origin" if !$undo.defined && entity.^can("compensate-$origin");
    $undo = '' if $undo === False || (try $*REDSOURCING-COMPENSATION).so;
    die "No compensation method '$undo'" if $undo && !entity.^can($undo);
    my %policy = entity.^policy(%retry);
    my $id = entity.^stream ~ '/action/' ~ ++entity.^state<serial>;
    my %action = :$id, :$kind, :$target, ids => copy-data(%ids), :$method,
        step => $origin, args => %(positional => copy-data($args.list.Array),
        named => copy-data($args.hash.Hash)), retry => %policy,
        compensation => ($undo // ''), status => 'pending', attempts => 0,
        context => copy-data(entity.^values),
        source-event-id => ((try $*REDSOURCING-SOURCE-EVENT) // 0),
        source-action-id => ((try $*REDSOURCING-ACTION) // ''),
        due => clock().Instant.Num, row-id => 0,
        undo-entry => ((try $*REDSOURCING-COMPENSATION) // '');
    entity.^state<actions>.push(%action);
    $id
}

method command(\entity, $target, Str $method, Capture $args, |options) {
    return entity.^plan(-> $copy { $copy.^command($target, $method, $args, |options) })
        unless phase() eq 'REACT';
    my $proxy = $target.DEFINITE ?? $target !! $target.^from(entity);
    die 'Saga commands require an aggregate target'
        unless $proxy.HOW.^can('entity-type') && $proxy.^entity-type.HOW ~~ Metamodel::RedSourcing::AggregateHOW;
    die 'Aggregate commands accept named arguments only' if $args.list;
    die "No command '$method' on {$proxy.^entity-type.^name}"
        unless $proxy.^entity-type.^commands{$method}:exists;
    my $command = $proxy.^prepare-command($method, |$args.hash);
    my %normalized = $command.^attributes.grep(*.has_accessor).map({
        .name.substr(2) => .get_value($command)
    });
    entity.^enqueue('command', $proxy.^entity-type.^name, $proxy.^ids-map.Hash,
        $method, \(|%normalized), |options)
}

method service(\entity, Str $target, Str $method, Capture $args, |options) {
    return entity.^plan(-> $copy { $copy.^service($target, $method, $args, |options) })
        unless phase() eq 'REACT';
    RedSourcing::Saga::service-adapter($target);
    entity.^enqueue('service', $target, {}, $method, $args, |options)
}

method set-timeout(\entity, Str $name, Numeric $interval, *%command) {
    return entity.^plan(-> $copy { $copy.^set-timeout($name, $interval, |%command) })
        unless phase() eq 'REACT';
    die 'Timeout needs a nonnegative interval and exactly one method => Capture'
        unless $interval >= 0 && %command.elems == 1 && %command.values.head ~~ Capture;
    my $method = %command.keys.head;
    die "No timeout method '$method'" unless entity.^can($method);
    die 'Cannot schedule a timeout after completion' unless entity.^status eq 'running';
    my $args = %command{$method};
    entity.^state<timers>{$name} = %(due => clock().later(:seconds($interval)).Instant.Num,
        :$method, positional => copy-data($args.list.Array), named => copy-data($args.hash.Hash));
    $name
}

method cancel-timeout(\entity, Str $name) {
    return entity.^plan(-> $copy { $copy.^cancel-timeout($name) }) unless phase() eq 'REACT';
    entity.^state<timers>{$name}:delete;
    $name
}

method compensate(\entity, Str :$reason = 'Saga failed') {
    return entity.^plan(-> $copy { $copy.^compensate(:$reason) }) unless phase() eq 'REACT';
    return if entity.^status eq any(<completed compensated compensating>);
    entity.^state<status> = 'compensating';
    entity.^state<reason> = $reason;
    entity.^state<timers> = {};
    for entity.^state<actions>.grep({ .<status> eq any(<pending retry>) }) -> %action {
        %action<status> = %action<uncertain> ?? 'blocked' !! 'cancelled';
    }
}

method complete(\entity) {
    return entity.^plan(-> $copy { $copy.^complete }) unless phase() eq 'REACT';
    die 'Cannot complete with unresolved operations' if entity.^state<actions>.grep({
        .<status> ne any(<done failed cancelled>)
    });
    die 'Cannot complete a compensating saga' unless entity.^status eq 'running';
    entity.^state<status> = 'completed';
    entity.^state<timers> = {};
    entity.^state<compensations> = [];
}

method finish-action(\entity, Str $id, :$result, :$error is copy, Bool :$uncertain = False) {
    my $copy = entity.^clone-state;
    my %action := $copy.^state<actions>.first(*.<id> eq $id);
    my Mu $type = StepSucceeded;
    if $error.defined {
        %action<error> = $error.Str;
        if $uncertain {
            %action<status> = 'blocked';
            $type = StepUncertain;
        } else {
            %action<status> = 'failed';
            $type = StepFailed;
        }
    } else {
        %action<result> = copy-data($result);
        %action<uncertain> = False;
        %action<status> = 'done';
        if %action<compensation> {
            # Save the invocation; do not run the compensator on success.
            my &handler = %!handlers{%action<compensation>};
            my $invocation = $copy.^clone-state;
            $invocation.^adopt(%action<context>, $copy.^state, $copy.^current-id);
            my $binds = do {
                my $*REDSOURCING-PHASE = 'REACT';
                $result ~~ Associative && \($invocation, |$result.Hash) ~~ &handler.signature
            };
            if $binds {
                $copy.^state<compensations>.push(%(id => $id, method => %action<compensation>,
                    result => copy-data($result), context => %action<context>, action-id => ''));
            } else {
                %action<status> = 'blocked';
                %action<error> = "Result does not bind to compensation '%action<compensation>'";
                $error = %action<error>;
                $type = StepUncertain;
            }
        }
        if %action<undo-entry> {
            die 'Compensation stack order changed' unless $copy.^state<compensations>.tail<id> eq %action<undo-entry>;
            $copy.^state<compensations>.pop;
            $type = CompensationSucceeded;
        }
    }
    my $event = $type.new(:state($copy.^state), :values($copy.^values), :cursor($copy.^current-id),
        :step(%action<step>), :action-id($id), :$result, :error($error // ''));
    $copy.^apply($event);
    $copy.^react($event) unless $copy.^status eq 'compensating' && $type === StepSucceeded;
    entity.^commit($copy, $type, :step(%action<step>), :action-id($id), :$result, :error($error // ''));
}

method resolve-action(\entity, Str $id, *%outcome) {
    die 'Resolution requires exactly one of result or error'
        unless %outcome.elems == 1 && %outcome.keys.head eq any(<result error>);
    my %action = entity.^state<actions>.first(*.<id> eq $id) // die "No saga action '$id'";
    die 'Only blocked or running operations can be resolved'
        unless %action<status> eq any(<blocked running>);
    entity.^finish-action($id, |%outcome);
}

method run-action(\entity, Str $id, DateTime $now) {
    my $flow-scope = flow-tracing-enabled;
    my $*REDSOURCING-FLOW-SCOPE = $flow-scope;
    my %action := entity.^state<actions>.first(*.<id> eq $id);
    # Claim and record the child command atomically before executing it.
    if %action<status> ne 'running' {
        my $copy = entity.^clone-state;
        my %next := $copy.^state<actions>.first(*.<id> eq $id);
        red-do :transaction, {
            my $*REDSOURCING-PHASE = 'EXECUTE';
            %next<status> = 'running';
            %next<attempts>++;
            if %next<kind> eq 'command' {
                my $proxy = resolve-class(%next<target>).^with-ids(|%next<ids>);
                my $row = $proxy."{%next<method>}"(|%next<args><named>, :!sync);
                %next<row-id> = $row.id;
            }
            entity.^commit($copy);
            True
        }
        %action := entity.^state<actions>.first(*.<id> eq $id);
    }
    my ($result, $failure);
    my $*REDSOURCING-ACTION = $id;
    {
        CATCH { default { $failure = $_ } }
        if %action<kind> eq 'command' {
            my $row = RedSourcing::StoredCommand.^all.grep(*.id == %action<row-id>).head;
            $result = $row.run;
            $row.^refresh;
            return unless $row.state == RedSourcing::StoredCommand::State::Done;
        } else {
            my &adapter = RedSourcing::Saga::service-adapter(%action<target>);
            $result = adapter(%action<method>,
                \(|%action<args><positional>.List, |%action<args><named>), :idempotency-key($id));
        }
    }
    if $failure {
        # The command rolled back and remains Pending after exhausting its
        # immediate conflict retries. Resume this same row on another advance;
        # do not consume business retries or emit StepFailed/compensations.
        return if %action<kind> eq 'command'
            && $failure ~~ RedSourcing::X::OptimisticLockFailed;
        my $uncertain = $failure ~~ Uncertain || (%action<kind> eq 'service'
            && !($failure ~~ Permanent || $failure ~~ Retryable));
        if !($failure ~~ Permanent) && %action<attempts> < %action<retry><max> {
            my $copy = entity.^clone-state;
            my %next := $copy.^state<actions>.first(*.<id> eq $id);
            my $delay = %next<retry><delay> * (%next<retry><exponential> ?? 2 ** (%next<attempts> - 1) !! 1);
            %next<due> = $now.later(:seconds($delay min %next<retry><cap>)).Instant.Num;
            %next<status> = 'retry';
            %next<error> = $failure.message;
            %next<uncertain> = $uncertain;
            entity.^commit($copy);
        } else {
            entity.^finish-action($id, :error($failure.message),
                :$uncertain);
        }
    } else {
        entity.^finish-action($id, :$result);
    }
}

method advance(\entity, DateTime :$now = DateTime.now, UInt :$limit = 100) {
    assert-effect-allowed('saga advance');
    my $*REDSOURCING-NOW = $now;
    entity.^replay;
    # Observe committed domain facts before deciding whether a timer has expired.
    my @rules;
    for <APPLY REACT> -> $method {
        my $handler = entity.^find_method($method);
        @rules.append(rules-from-func(entity, $handler)) if $handler;
    }
    # Native controls are replayed from this saga's stream or dispatched by
    # finish-action. Their handlers cannot match source events, so do not trace
    # their signatures into the global subscription query.
    @rules = @rules.grep({ !.key.^isa(RedSourcing::Saga::Control) });
    if @rules && entity.^status eq 'running' {
        for RedSourcing::StoredEvent.list-events(:row, :from-id(entity.^current-id), |@rules) -> $row {
            next if $row.mro.contains('|Entity|') || $row.mro.contains('|RedSourcing::Saga::Control|');
            my $copy = entity.^clone-state;
            my $event = $row.COERCE;
            my $*REDSOURCING-SOURCE-EVENT = $row.id;
            $copy.^apply($event);
            $copy.^react($event);
            $copy.^current-id = $row.id;
            entity.^commit($copy);
            observe-flow-entity(entity, 'saga');
            flow-link('event', $row.id.Str, 'entity', entity.^stream, 'consumed-saga');
            last unless entity.^status eq 'running';
        }
    }
    for entity.^state<timers>.keys.sort -> $name {
        next unless entity.^state<timers>{$name}:exists;
        my %timer = entity.^state<timers>{$name};
        next if %timer<due> > $now.Instant.Num;
        my $copy = entity.^clone-state;
        $copy.^state<timers>{$name}:delete;
        my $*REDSOURCING-PHASE = 'REACT';
        my %before = copy-data($copy.^values);
        $copy."{%timer<method>}"(|%timer<positional>.List, |%timer<named>);
        die 'REACT cannot change persisted domain state; use APPLY'
            unless %before eqv copy-data($copy.^values);
        entity.^commit($copy, RedSourcing::Saga::TimeoutTriggered, :step($name));
    }
    for ^$limit {
        if entity.^status eq 'compensating' {
            my @unsettled = entity.^state<actions>.grep({ .<status> eq any(<running blocked>) && !.<undo-entry> });
            if @unsettled {
                last if @unsettled.first(*.<status> eq 'blocked');
                my $id = @unsettled.head<id>;
                entity.^run-action($id, $now);
                last if entity.^state<actions>.first(*.<id> eq $id)<status> eq 'running';
                next;
            }
            unless entity.^state<compensations> {
                my $copy = entity.^clone-state;
                $copy.^state<status> = 'compensated';
                entity.^commit($copy);
                last;
            }
            my %entry = entity.^state<compensations>.tail;
            unless %entry<action-id> {
                my $copy = entity.^clone-state;
                my $*REDSOURCING-PHASE = 'REACT';
                my $*REDSOURCING-COMPENSATION = %entry<id>;
                my $invocation = $copy.^clone-state;
                $invocation.^adopt(%entry<context>, $copy.^state, $copy.^current-id);
                my %before = copy-data($invocation.^values);
                my $count = $copy.^state<actions>.elems;
                $invocation."{%entry<method>}"(|%entry<result>);
                $copy.^initialize-state($invocation.^state);
                die 'A compensation method must schedule exactly one operation'
                    unless $copy.^state<actions>.elems == $count + 1;
                die 'REACT cannot change persisted domain state; use APPLY'
                    unless %before eqv copy-data($invocation.^values);
                $copy.^state<compensations>.tail<action-id> = $copy.^state<actions>.tail<id>;
                entity.^commit($copy);
            }
        }
        my %ready = entity.^state<actions>.first({ .<status> eq any(<running pending retry blocked>) }) // {};
        last unless %ready;
        last if %ready<status> eq 'blocked' || (%ready<status> ne 'running' && %ready<due> > $now.Instant.Num);
        entity.^run-action(%ready<id>, $now);
        # A command owned by another executor remains running; avoid a busy loop.
        last if entity.^state<actions>.first(*.<id> eq %ready<id>)<status> eq 'running';
    }
    entity
}

method check-timeouts(\entity, |c) { entity.^advance(|c) }
