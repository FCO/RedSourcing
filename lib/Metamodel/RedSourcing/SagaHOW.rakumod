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
use RedSourcing::Journal;
use RedSourcing::Lifecycle;
use RedSourcing::Storage;
use RedSourcing::EventType;
use Red::DB;

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

method values(\entity) {
    # Domain values do not include runtime state. Do not deep-copy that entire
    # state just to discard it from the result.
    self.Metamodel::RedSourcing::EntityHOW::data(entity).Hash
}

method restore-state(Mu:U \type, $snapshot, Str :$stream!, *%initial) {
    $snapshot ?? $snapshot.COERCE(type) !! type.bless(|%initial, :$stream)
}

# Loading reads only committed controls. It never calls REACT or an adapter.
method replay(\entity) {
    my $connection = get-RED-DB;
    my $pg = $connection.^mro.map(*.^name).first(* eq 'Red::Driver::Pg').defined;
    my @p = $pg ?? < $1 $2 $3 > !! < ? ? ? >;
    my @headers = storage-query($connection,
        'SELECT id, version, class, mro, created FROM red_sourcing_event WHERE stream = ' ~ @p[0]
        ~ ' AND version > ' ~ @p[1] ~ ' AND (class = ' ~ @p[2]
        ~ ' OR ' ~ event-type-sql($connection, 'RedSourcing::Saga::Control') ~ ') ORDER BY id',
        entity.^stream, entity.^version, entity.^name);
    my $version = entity.^version;
    my $events = entity.^snapshot-events;
    my $at = entity.^snapshot-at;
    my $last;
    for @headers -> %row {
        next if %row<version> <= $version;
        $last = %row<id>;
        $version = %row<version>;
        if %row<class> eq entity.^name {
            $events = 0;
            $at = (%row<created> ~~ DateTime ?? %row<created> !! DateTime.new(%row<created>)).Instant.Num;
        } else {
            $events++;
            $at = (%row<created> ~~ DateTime ?? %row<created> !! DateTime.new(%row<created>)).Instant.Num unless $at;
        }
    }
    return unless $last.defined;
    # Every native control stores complete values/state/cursor. Historical
    # headers preserve version and snapshot accounting; only the final payload
    # must be inflated, copied and adopted. No APPLY/REACT is executed here.
    my $row = RedSourcing::StoredEvent.^all.where(
        RedSourcing::StoredEvent.journal-filter(:id($last))).head;
    if $row.class eq entity.^name {
        my $snapshot = $row.COERCE(entity.WHAT);
        entity.^adopt($snapshot.^values, $snapshot.^state, $snapshot.^current-id);
    } else {
        my $control = $row.COERCE;
        entity.^adopt($control.values, $control.state, $control.cursor);
    }
    entity.^version = $version;
    entity.^snapshot-events = $events;
    entity.^snapshot-at = $at;
}

method adopt(\entity, %values, %state, UInt $cursor) {
    for entity.^attributes.grep(*.has_accessor) -> $attr {
        $attr.set_value(entity, %values{$attr.name.substr(2)});
    }
    $!state-attr.set_value(entity, copy-data(%state));
    entity.^current-id = $cursor;
}

method clone-state(\entity) {
    # Entity.TWEAK copies saga-state when initializing the new instance. Copy
    # domain values once and let that initializer isolate runtime state once.
    my $copy = entity.WHAT.bless(|copy-data(entity.^values).Hash,
        :saga-state(entity.^state), :stream(entity.^stream));
    $copy.^version = entity.^version;
    $copy.^current-id = entity.^current-id;
    $copy.^snapshot-events = entity.^snapshot-events;
    $copy.^snapshot-at = entity.^snapshot-at;
    $copy
}

method commit(\entity, $copy, Mu:U $type = RedSourcing::Saga::StateChanged, *%fields) {
    my $*REDSOURCING-PHASE = 'CONTROL';
    journal-do {
      my $row = $type.new(
        :state(copy-data($copy.^state)), :values(copy-data($copy.^values)),
        :cursor($copy.^current-id), |%fields,
    ).emit(:stream(entity.^stream), :version(entity.^version + 1));
    entity.^adopt($copy.^values, $copy.^state, $copy.^current-id);
    entity.^version = $row.version;
    entity.^record-applied(:at($row.created));
    entity.^maybe-auto-snapshot;
    publish-entity(entity);
    $row
    }
}

method plan(\entity, &code) {
    entity-operation(entity, -> $working { $working.^plan-operation(&code) })
}

method plan-operation(\entity, &code) {
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
    entity-operation(entity, -> $working {
      journal-do {
        $working.^replay;
        my $row = $working.^write-snapshot(:version($working.^version + 1),
            :replay-cursor($working.^current-id));
        $working.^version = $row.version;
        publish-entity($working);
        $row
      }
    })
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
    entity-operation(entity, -> $working { $working.^resolve-operation($id, |%outcome) })
}

method resolve-operation(\entity, Str $id, *%outcome) {
    die 'Resolution requires exactly one of result or error'
        unless %outcome.elems == 1 && %outcome.keys.head eq any(<result error>);
    my %action = entity.^state<actions>.first(*.<id> eq $id) // die "No saga action '$id'";
    die 'Only blocked or running operations can be resolved'
        unless %action<status> eq any(<blocked running>);
    entity.^finish-action($id, |%outcome);
}

method run-action(\entity, Str $id, DateTime $now) {
    my $*REDSOURCING-ACTION = $id;
    my %action := entity.^state<actions>.first(*.<id> eq $id);
    # Claim and record the child command atomically before executing it.
    if %action<status> ne 'running' {
        my $copy = entity.^clone-state;
        my %next := $copy.^state<actions>.first(*.<id> eq $id);
        transaction-do {
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
    {
        CATCH { default { $failure = $_ } }
        if %action<kind> eq 'command' {
            my $row = RedSourcing::StoredCommand.^all.grep(*.id == %action<row-id>).head;
            $result = $row.run;
            $row.^refresh-storage-row;
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
    entity-operation(entity, -> $working { $working.^advance-operation(:$now, :$limit) })
}

method advance-operation(\entity, DateTime :$now = DateTime.now, UInt :$limit = 100) {
    assert-effect-allowed('saga advance');
    my $*REDSOURCING-NOW = $now;
    entity.^replay;
    # Observe committed domain facts before deciding whether a timer has expired.
    my @rules = rules-from-methods(entity, <APPLY REACT>);
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
