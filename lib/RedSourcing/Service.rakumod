unit module RedSourcing::Service;
use RedSourcing;
use RedSourcing::Service::Protocol;
use RedSourcing::Service::Context;
use RedSourcing::Service::Lease;
use RedSourcing::Journal;
use RedSourcing::Storage;
use RedSourcing::EventType;
use RedSourcing::Lifecycle;
use RedSourcing::IsService;
use RedSourcing::Context;
use RedSourcing::Query;
use RedSourcing::Config;
use Red::DB;
use JSON::Fast;
use nqp;

sub copy-data($value) { from-json(to-json($value, :!pretty)) }
my Lock $runtimes-lock .= new;
my %runtimes;
sub driver-key($driver --> Str) { nqp::where(nqp::decont($driver)).Str }
sub endpoint-runtime {
    return Nil if (try $*REDSOURCING-SERVICE-STORE) // False;
    my $key = driver-key(get-RED-DB());
    $runtimes-lock.protect({ %runtimes{$key} })
}
sub identity($proxy, Str $method --> Pair) {
    die "Unknown entity service '$method'" unless $proxy.^entity-type.HOW.^can('services')
        && ($proxy.^entity-type.^services{$method}:exists);
    my $definition = to-json([$proxy.^entity-type.^name, $proxy.^stream-name, $method], :!pretty);
    nqp::sha1($definition) => $definition
}

saga LifecycleSaga[:!cached, :!auto-snapshot] {
    has Str $.service-id is entity-id;
    has Hash $.definition = {};
    method APPLY(RedSourcing::Service::Protocol::Control $event where { .service-id eqv $!service-id }) {
        $!definition = copy-data($event.definition);
    }
    method REACT(RedSourcing::Service::Protocol::Control $event where { .service-id eqv $!service-id }) {
        if $event.operation eq any(<failed exited stop stop-initiated stop-unconfirmed>) {
            for self.^state<actions>.List -> $action {
                $action<status> = 'cancelled' if $action<status> eq any(<pending retry running blocked>);
            }
        }
        given $event.operation {
            when 'start' | 'touch' {
                self.set-timeout('idle', ($!definition<idle-deadline> - self.^now.Instant.to-posix.head.Num) max 0,
                    expire => \());
            }
            when 'claimed' {
                # An expired owner's unfinished adapter actions cannot be resumed
                # under a new generation. A fresh action is bound to this owner.
                for self.^state<actions>.List -> $action {
                    $action<status> = 'cancelled' if $action<status> eq any(<pending retry running blocked>);
                }
                self.^service('redsourcing-managed-services', 'launch', \(:service-id($!service-id)));
                self.set-timeout('ready', ($!definition<ready-deadline> - self.^now.Instant.to-posix.head.Num) max 0,
                    ready-expired => \());
            }
            when 'ready' { self.cancel-timeout('ready') }
            when 'stop' | 'stop-initiated' {
                self.cancel-timeout('idle'); self.cancel-timeout('ready'); self.cancel-timeout('retry');
                self.^service('redsourcing-managed-services', 'stop', \(:service-id($!service-id)));
            }
            when 'failed' {
                self.cancel-timeout('ready');
                if $!definition<desired> {
                    self.set-timeout('retry', ($!definition<retry-at> - self.^now.Instant.to-posix.head.Num) max 0,
                        retry-ready => \());
                } else { self.cancel-timeout('idle') }
            }
            when 'exited' | 'stop-unconfirmed' { self.cancel-timeout('idle'); self.cancel-timeout('ready'); self.cancel-timeout('retry') }
        }
    }
    method cancel-launch {
        for self.^state<actions>.List -> $action {
            $action<status> = 'cancelled' if $action<method> eq 'launch'
                && $action<status> eq any(<pending retry running blocked>);
        }
    }
    method expire {
        self.cancel-launch;
        self.^service('redsourcing-managed-services', 'expire', \(:service-id($!service-id)))
    }
    method ready-expired {
        self.cancel-launch;
        self.^service('redsourcing-managed-services', 'abort-start', \(:service-id($!service-id)))
    }
    method retry-ready { }
}

# Projection lifecycle controls belong to an infrastructure aggregate, never
# to the projection stream. The target remains the identity of the service.
aggregate ProjectionServiceOwner[:!cached, :!auto-snapshot] {
    has Str $.service-id is entity-id;
    method APPLY { }
    method control(Hash :$target!, Str :$operation!, Str :$service!,
            Hash :$arguments = {}, Numeric :$idle-timeout = 300, Hash :$report = {}) {
        control-service(self, :$target, :$operation, :$service, :$arguments, :$idle-timeout, :$report)
    }
}

sub saga-proxy(Str $id) { LifecycleSaga.^with-ids(:service-id($id)) }
sub load-saga(Str $id) { saga-proxy($id).^load }

sub submit-service-control($proxy, Str :$operation!, Str :$service!,
        Hash :$arguments = {}, Numeric :$idle-timeout = 300, Hash :$report = {}, Bool :$sync = True) is export {
    my $runtime = endpoint-runtime();
    return $runtime.serialize({ submit-service-control($proxy, :$operation, :$service,
        :$arguments, :$idle-timeout, :$report, :$sync) }) if $runtime.defined;
    assert-effect-allowed('command submission');
    identity($proxy, $service);
    die 'idle-timeout must be a positive finite number' unless 0 < $idle-timeout < Inf;
    my $fence = try $*REDSOURCING-SERVICE-FENCE;
    my $destination = $proxy;
    my $method = '_rs-service-control';
    my %data = :$operation, :$service, :$arguments, :$idle-timeout, :$report;
    my $projection = so $proxy.^entity-type.HOW.^mro.grep(*.^name eq 'Metamodel::RedSourcing::ProjectionHOW').elems;
    if $projection {
        my $id = identity($proxy, $service).key;
        $destination = ProjectionServiceOwner.^with-ids(:service-id($id));
        $method = 'control';
        %data<target> = %(entity => $proxy.^entity-type.^name, ids => $proxy.^ids-map.Hash);
    }
    my &submit = {
        my $row = StoredCommand.^create(:entity($destination.^entity-type.^name), :entity-ids($destination.^ids-map),
            :stream($destination.^stream-name), :$method, :class<RedSourcing::Service::Command>,
            :data(copy-data(%data)),
            |($fence.defined && $fence.elems ?? %(service-context => $fence) !! %()));
        $sync ?? $row.run !! $row
    };
    $projection ?? journal-do({
        $destination.^create unless StoredEvent.^all.grep(*.stream eq $destination.^stream-name).head.defined;
        submit()
    }) !! submit()

}

sub service-status($proxy, Str $method --> Hash) is export {
    my $runtime = endpoint-runtime();
    return $runtime.serialize({ service-status($proxy, $method) }) if $runtime.defined;
    my $id = identity($proxy, $method).key;
    my $saga = load-saga($id);
    my %status = copy-data($saga.definition);
    %status<service-id> = $id;
    %status<phase> //= 'absent';
    %status<desired> //= False;
    my $lease = read-lease(journal-connection(), $id);
    %status<lease> = $lease.defined ?? $lease.Hash !! {};
    %status
}

sub control-service($entity, Str :$operation!, Str :$service!, Hash :$arguments = {},
        Numeric :$idle-timeout = 300, Hash :$report = {}, Hash :$target) is export {
    my $subject = $entity;
    if $target.defined {
        my $type = resolve-class($target<entity>);
        my $proxy = $type.^with-ids(|$target<ids>);
        $subject = $type.^restore-and-replay(:stream($proxy.^stream-name), |$proxy.^ids-map)<entity>;
    }
    my $proxy = $subject.WHAT.^with-ids(|$subject.^entity-id-map);
    my ($id, $key) = identity($proxy, $service).kv;
    my $db = journal-connection();
    my $now = database-now($db);
    my $saga = load-saga($id);
    my %next = copy-data($saga.definition);
    die 'Service identity collision' if %next<key>.defined && %next<key> ne $key;
    if $operation eq 'start' {
        if %next<desired> {
            die 'Stop the service before changing its arguments or timeout'
                unless %next<arguments> eqv copy-data($arguments) && %next<idle-timeout> == $idle-timeout;
            return %(service-id => $id, phase => %next<phase>, desired => True);
        }
        die 'Service is still stopping' if (%next<phase> // '') eq 'stopping';
        my $method = $subject.^services{$service};
        die 'Service arguments do not match its signature'
            unless \($subject, nqp::create(ServiceContext), |$arguments) ~~ $method.signature;
        %next = service-id => $id, key => $key, entity => $subject.^name,
            ids => $subject.^entity-id-map.Hash, stream => $subject.^stream, method => $service,
            arguments => copy-data($arguments), desired => True, phase => 'requested', failures => 0,
            idle-timeout => $idle-timeout, idle-deadline => $now + $idle-timeout,
            generation => 0, owner => '', error => '', revision => (($saga.definition<revision> // 0) + 1);
        unless $saga.^version {
            # Snapshot exists before the source event, and shares its transaction.
            saga-proxy($id).^create;
            $saga = load-saga($id);
        }
    } elsif $operation eq 'touch' {
        die 'Service is not active or requested' unless %next<desired>;
        %next<idle-deadline> = $now + %next<idle-timeout>;
    } elsif $operation eq 'stop' {
        return %(service-id => $id, phase => (%next<phase> // 'absent'), desired => False)
            unless %next<desired>;
        %next<desired> = False; %next<phase> = 'stopping'; %next<reason> = 'requested';
    } else {
        my $fence = try $*REDSOURCING-SERVICE-FENCE;
        die 'Executor reports require a service fence' unless $fence.defined && $fence<service-id> eq $id;
        assert-service-fence($db, $fence.Hash);
        given $operation {
            when 'claimed' {
                die 'Service no longer requested' unless %next<desired>;
                %next<generation> = $fence<generation>; %next<owner> = $fence<owner>;
                %next<phase> = 'starting'; %next<ready-deadline> = $now + $report<ready-timeout>;
            }
            when 'stop-claimed' {
                die 'Service is not stopping' unless !%next<desired> && %next<phase> eq 'stopping';
                %next<generation> = $fence<generation>; %next<owner> = $fence<owner>;
            }
            when 'ready' {
                die 'Service is stopping' unless %next<desired> && %next<generation> == $fence<generation>;
                %next<phase> = 'active';
            }
            when 'stop-initiated' {
                %next<desired> = False; %next<phase> = 'stopping'; %next<reason> = $report<reason> // 'idle';
            }
            when 'failed' {
                %next<failures>++;
                %next<error> = $report<error> // 'Service failed';
                %next<desired> = False if %next<failures> > $report<max-restarts>;
                %next<phase> = %next<desired> ?? 'retry' !! 'failed';
                %next<retry-at> = $now + 2 ** ((%next<failures> - 1) min 30);
            }
            when 'exited' { %next<desired> = False; %next<phase> = 'stopped'; %next<reason> //= 'completed' }
            when 'stop-unconfirmed' {
                %next<desired> = False; %next<phase> = 'unconfirmed-stop';
                %next<error> = 'Service or cleanup did not finish within stop-grace';
            }
            default { die "Unknown service operation '$operation'" }
        }
    }
    my $row = RedSourcing::Service::Protocol::Control.new(:service-id($id), :$operation,
        :definition(%next.Hash)).emit(:stream($entity.^stream), :version($entity.^version + 1));
    $entity.^version = $row.version; $entity.^current-id = $row.id;
    publish-entity($entity);
    my $*REDSOURCING-SERVICE-CONTROL = True;
    # Consume and persist intents/timers, but never execute an adapter in a command.
    $saga.^advance(:now(DateTime.new($now)), :limit(0));
    %(service-id => $id, phase => %next<phase>, desired => %next<desired>)
}

class ServiceRuntime is export {
    has Str $.owner-id = "{$*PID}-" ~ now.Int ~ '-' ~ (2**63).rand.Int;
    has Numeric $.lease-seconds = 30;
    has Numeric $.heartbeat-seconds = 10;
    has Numeric $.poll-interval = 1;
    has Numeric $.ready-timeout = 30;
    has Numeric $.stop-grace = 10;
    has UInt $.max-restarts = 3;
    has &.connection-factory;
    has $!root;
    has $!registration-root;
    has Str $!registration-key;
    has Lock $!store-lock .= new;
    has %!runs;
    has %!unstarted-stops;
    has Bool $!shutdown = False;
    has Promise $!controller;
    has Bool $!initialized = False;
    has UInt $!store-thread;
    has Channel $!requests .= new;
    has Lock $!requests-lock .= new;
    has Bool $!closed = False;
    has Lock $!wake-lock .= new;
    has Promise $!wakeup .= new;

    method initialize {
        die 'Initialize runtime outside a transaction' if (try $*RED-TRANSACTION-RUNNING) // False;
        die 'Invalid service runtime intervals' unless $!lease-seconds > $!heartbeat-seconds > 0
            && 0 < $!poll-interval < $!lease-seconds && $!ready-timeout > 0 && $!stop-grace >= 0
            && ($!lease-seconds, $!heartbeat-seconds, $!poll-interval, $!ready-timeout, $!stop-grace).all < Inf
            && $!owner-id.chars;
        $!root = get-RED-DB;
        $!registration-root = $!root;
        $!registration-key = driver-key($!root);
        $!store-thread = $*THREAD.id;
        self.with-store({ initialize-service-storage(journal-connection()) });
        $runtimes-lock.protect({
            die 'Only one local ServiceRuntime may own a driver; use separate processes for distributed execution'
                if %runtimes{$!registration-key}.defined && !(%runtimes{$!registration-key} === self);
            %runtimes{$!registration-key} = self;
        });
        $!initialized = True;
        self
    }
    method with-store(&work) {
        self.serialize({
            my $db = &!connection-factory.defined ?? &!connection-factory() !! $!root;
            die 'Service runtime has no store' unless $db.defined;
            my $*RED-DB = $db;
            my $*RED-TRANSACTION-DB = $db;
            my $*RED-TRANSACTION-RUNNING = False;
            my $*REDSOURCING-PHASE = 'EXECUTE';
            work()
        })
    }
    method serialize(&work) {
        $!store-lock.protect({
            my $*REDSOURCING-SERVICE-STORE = True;
            my $*REDSOURCING-SERVICE-EXECUTOR = self.WHICH.Str;
            work()
        })
    }
    method context-command(ServiceContext $context, Str $method, Capture $args, :$target = $context.proxy) {
        die 'command submission is forbidden in QUERY' if ((try $*REDSOURCING-PHASE) // '') eq 'QUERY';
        self.context-work({
            my $*REDSOURCING-PHASE = 'EXECUTE';
            my $*REDSOURCING-SERVICE-CONTEXT = $context;
            my $*REDSOURCING-SERVICE-FENCE = $context.fence;
            die "Not an aggregate command: $method" unless $target.^entity-type.^commands{$method}:exists;
            $target."$method"(|$args)
        })
    }
    method context-state(ServiceContext $context, :$target = $context.proxy, Str :$method, Hash :$arguments = {}) {
        my $read-phase = ((try $*REDSOURCING-PHASE) // '') eq 'QUERY' ?? 'QUERY' !! 'SERVICE-READ';
        self.context-work({ journal-do {
            assert-service-fence(journal-connection(), $context.fence);
            my $entity = $target.^entity-type.^restore-and-replay(:stream($target.^stream-name),
                |$target.^ids-map)<entity>;
            if $method.defined {
                die "Cannot invoke a command or service as a read: $method"
                    if ($entity.^commands{$method}:exists) || ($entity.^services{$method}:exists);
                my $*REDSOURCING-PHASE = $read-phase;
                copy-data($entity."$method"(|$arguments))
            } else { $entity }
        } })
    }
    method context-query(ServiceContext $context, $target, Str $method, Capture $arguments) {
        self.context-work({
            my $*REDSOURCING-PHASE = 'EXECUTE';
            my $*REDSOURCING-SERVICE-CONTEXT = $context;
            # The envelope also commits maintenance when a query returns Nil.
            my $result = journal-do {
                assert-service-fence(journal-connection(), $context.fence);
                die "Not a declared query: $method" unless $target.^entity-type.^queries{$method}:exists;
                my $entity = $target.^entity-type.^restore-and-replay(:stream($target.^stream-name),
                    |$target.^ids-map)<entity>;
                %(value => query-invoke($entity, $method, $arguments))
            };
            $result<value>
        })
    }
    method context-report(ServiceContext $context, Str $operation) {
        self.context-work({ self.report($context, $operation) })
    }
    method context-work(&work) {
        die 'Service runtime is closed' if $!closed;
        return work() if ((try $*REDSOURCING-SERVICE-EXECUTOR) // '') eq self.WHICH.Str;
        return self.with-store(&work) if $*THREAD.id == $!store-thread;
        # Background methods never share an ORM connection/transaction with
        # another thread. The executor owns all context-originated database work.
        my $reply = Promise.new;
        $!requests-lock.protect({
            die 'Service runtime is closed' if $!closed;
            $!requests.send(%(work => &work, :$reply));
        });
        self.wake;
        await $reply
    }
    method wake { $!wake-lock.protect({ $!wakeup.keep(True) if $!wakeup.status == Planned }) }
    method drain-requests {
        loop {
            my $request = $!requests.poll;
            last unless $request.defined;
            {
                CATCH { default { $request<reply>.break($_) } }
                my $result = $request<work>();
                $request<reply>.keep($result);
            }
        }
    }
    method report(ServiceContext $context, Str $operation, *%report) {
        my $*REDSOURCING-SERVICE-FENCE = $context.fence;
        submit-service-control($context.proxy, :$operation,
            :service(self.method-for($context.service-id)),
            :report(%report.Hash))
    }
    method method-for(Str $id) { load-saga($id).definition<method> }
    method context-for(%definition, %lease) {
        my $type = resolve-class(%definition<entity>);
        ServiceContext.new(:executor(self), :proxy($type.^with-ids(|%definition<ids>)),
            :service-id(%definition<service-id>), :owner($!owner-id), :generation(%lease<generation>.UInt))
    }
    method effect(Str $operation, Str $id) {
        my $definition = load-saga($id).definition;
        my $fence = (try $*REDSOURCING-SERVICE-FENCE) // {};
        die 'Service adapter requires its runtime lease' unless $fence<service-id> eq $id;
        journal-do { assert-service-fence(journal-connection(), $fence.Hash) };
        die 'Stale service adapter generation' unless $definition<generation> == $fence<generation>;
        if $operation eq 'launch' {
            if %!runs{$id}.defined && %!runs{$id}<context>.generation == $fence<generation> {
                return PendingStart.new(:ready(%!runs{$id}<context>.readiness), :result(%(generation => $fence<generation>)));
            }
            die 'An earlier local execution has not stopped' if %!runs{$id}.defined;
            my $context = self.context-for($definition, $fence);
            my $receiver = $context.proxy.^entity-type.^restore-and-replay(
                :stream($context.proxy.^stream-name), |$context.proxy.^ids-map)<entity>;
            my $method = $definition<method>;
            my %arguments = copy-data($definition<arguments>);
            my $promise = start {
                my $*REDSOURCING-SERVICE-CONTEXT = $context;
                my $*REDSOURCING-PHASE = 'SERVICE';
                my $*RED-TRANSACTION-RUNNING = False;
                my $*COMMAND = Any;
                my $result = $receiver."$method"($context, |%arguments);
                die 'A service method must return a Promise' unless $result ~~ Promise;
                await $result;
                True
            };
            %!runs{$id} = %( :$context, :$promise, heartbeat => database-now(journal-connection()), reason => '');
            return PendingStart.new(:ready($context.readiness), :result(%(generation => $fence<generation>)));
        } else {
            if %!runs{$id}.defined {
                my $run = %!runs{$id};
                $run<reason> = $operation eq 'abort-start' ?? 'ready-timeout'
                    !! $operation eq 'expire' ?? 'idle' !! 'requested';
                $run<stop-at> //= database-now(journal-connection());
                $run<context>.request-stop;
            } else { %!unstarted-stops{$id} = %(:$operation, generation => $fence<generation>) }
        }
        %(generation => $fence<generation>)
    }
    method tick {
        die 'Run the service controller outside a transaction' if (try $*RED-TRANSACTION-RUNNING) // False;
        die 'Service runtime is not initialized' unless $!initialized;
        die 'Service runtime is shut down' if $!shutdown;
        self.with-store({
            $!store-thread = $*THREAD.id;
            self.drain-requests;
            my $db = journal-connection();
            my $now = database-now($db);
            my @rows = storage-query($db, q[SELECT MAX(id) AS id FROM red_sourcing_event WHERE stream LIKE 'RedSourcing::Service::LifecycleSaga: %' GROUP BY stream ORDER BY MAX(id)]);
            my @results;
            my $*REDSOURCING-SERVICE-RUNTIME = self;
            for @rows -> $header {
                CATCH {
                    default { @results.push(%(phase => 'error', error => .message)); }
                }
                my $row = storage-model-rows(StoredEvent, 'SELECT * FROM red_sourcing_event WHERE id = '
                    ~ parameters($db, 1)[0], $header<id>).head;
                my $saga = LifecycleSaga.^load(:stream($row.stream));
                my $id = $saga.service-id;
                my %definition = copy-data($saga.definition);
                next unless %definition;
                my $run = %!runs{$id};
                my $lease = read-lease($db, $id);
                if $run.defined {
                    my $context = $run<context>;
                    my $owned = $lease.defined && $lease<owner> eq $!owner-id
                        && $lease<generation> == $context.generation && $lease<expires> > $now;
                    unless $owned {
                        $run<reason> = 'ownership-lost'; $run<stop-at> //= $now;
                        $context.request-stop;
                        %!runs{$id}:delete if $run<promise>.status ne Planned && $context.cleanup.status ne Planned;
                        @results.push(%(service-id => $id, phase => 'ownership-lost'));
                        next;
                    }
                    if $run<promise>.status ne Planned {
                        $context.request-stop;
                        $run<stop-at> //= $now;
                        if $context.cleanup.status == Planned {
                            if $now - $run<stop-at> >= $!stop-grace {
                                self.report($context, 'stop-unconfirmed');
                                release-lease($db, $context.fence);
                                @results.push(%(service-id => $id, phase => 'unconfirmed-stop'));
                            } else {
                                renew-lease($db, $context.fence, $!lease-seconds);
                            }
                            next;
                        }
                        my $broken = $run<promise>.status == Broken;
                        my $cleanup-failed = $context.cleanup.status == Broken || so $context.late-cleanup-error.chars;
                        my $error = $context.late-cleanup-error.chars ?? $context.late-cleanup-error
                            !! $cleanup-failed ?? $context.cleanup.cause.message
                            !! $broken ?? $run<promise>.cause.message
                            !! $context.readiness.status != Kept ?? 'Service ended before readiness' !! '';
                        my $failed = $cleanup-failed || $run<reason> eq 'ready-timeout'
                            || ($broken && !$run<reason>) || (!$run<reason> && $context.readiness.status != Kept);
                        if !$failed && $run<reason> && %definition<desired> {
                            self.report($context, 'stop-initiated', :reason($run<reason>));
                        }
                        self.report($context, $failed ?? 'failed' !! 'exited',
                            :$error, :max-restarts($cleanup-failed ?? 0 !! $!max-restarts));
                        release-lease($db, $context.fence);
                        %!runs{$id}:delete;
                        @results.push(%(service-id => $id, phase => ($failed ?? 'failed' !! 'stopped')));
                        next;
                    }
                    if $run<reason> && $run<reason> ne 'ready-timeout' && %definition<desired> {
                        self.report($context, 'stop-initiated', :reason($run<reason>));
                        %definition = copy-data(load-saga($id).definition);
                    }
                    if $run<stop-at>.defined && $now - $run<stop-at> >= $!stop-grace {
                        self.report($context, 'stop-unconfirmed');
                        release-lease($db, $context.fence);
                        @results.push(%(service-id => $id, phase => 'unconfirmed-stop'));
                        next;
                    }
                    if $now - $run<heartbeat> >= $!heartbeat-seconds {
                        renew-lease($db, $context.fence, $!lease-seconds);
                        $run<heartbeat> = $now;
                    }
                }
                my $pending = $saga.^pending-actions.first(*.<status> eq any(<pending retry running blocked>)).defined;
                next unless %definition<desired> || $run.defined || $pending || %definition<phase> eq 'stopping';
                next if (%definition<phase> // '') eq 'retry' && %definition<retry-at> > $now;
                $lease = acquire-lease($db, $id, %definition<key>, $!owner-id, $!lease-seconds);
                next unless $lease.defined;
                my $context = self.context-for(%definition, $lease);
                my $*REDSOURCING-SERVICE-FENCE = $context.fence;
                if %definition<desired> && !%!runs{$id}.defined
                        && (%definition<generation> != $lease<generation> || %definition<phase> eq any(<requested retry>)) {
                    self.report($context, 'claimed', :ready-timeout($!ready-timeout));
                }
                if !%!runs{$id}.defined && !%definition<desired> && %definition<phase> eq 'stopping' {
                    # A never-claimed request has no resources to close. For an
                    # earlier owner, a replacement cannot confirm external stop.
                    my $never-started = %definition<generation> == 0;
                    self.report($context, 'stop-claimed');
                    self.report($context, $never-started ?? 'exited' !! 'stop-unconfirmed');
                    release-lease($db, $context.fence);
                    @results.push(%(service-id => $id, phase => $never-started ?? 'stopped' !! 'unconfirmed-stop'));
                    next;
                }
                load-saga($id).^advance(:now(DateTime.new($now)));
                my $unstarted = %!unstarted-stops{$id}:delete;
                if $unstarted.defined && $unstarted<generation> == $context.generation {
                    if $unstarted<operation> eq 'abort-start' {
                        self.report($context, 'failed', :error('Service did not become ready before its deadline'),
                            :max-restarts($!max-restarts));
                    } else {
                        self.report($context, 'stop-initiated', :reason($unstarted<operation> eq 'expire' ?? 'idle' !! 'requested'));
                        self.report($context, 'exited');
                    }
                    release-lease($db, $context.fence);
                }
                @results.push(%(service-id => $id, phase => load-saga($id).definition<phase>));
            }
            %(services => @results.Array)
        })
    }
    method run {
        return $!controller if $!controller.defined;
        die 'Initialize runtime before run' unless $!initialized;
        die 'Service runtime is closed' if $!closed;
        if !&!connection-factory.defined && !pg-driver($!root) {
            my $database = $!root.?database;
            die 'Background SQLite execution needs a file store or an independent connection-factory; use tick for :memory:'
                unless $database.defined && $database ne ':memory:';
            # An application's uncommitted transaction must never be observed
            # by the background controller through the same SQLite connection.
            $!root = store-driver('SQLite', $database);
        }
        $!store-thread = 0;
        $!controller = start {
            $!store-thread = $*THREAD.id;
            until $!shutdown {
                { CATCH { default { .rethrow unless $!shutdown } }; self.tick }
                my $signal = $!wake-lock.protect({ $!wakeup });
                await Promise.anyof($signal, Promise.in($!poll-interval));
                $!wake-lock.protect({ $!wakeup = Promise.new if $!wakeup === $signal });
            }
            True
        }
    }
    method shutdown {
        return True if $!closed;
        $!shutdown = True;
        self.wake;
        self.with-store({
            for %!runs.values -> $run {
                $run<context>.request-stop;
            }
        });
        my $end = now + $!stop-grace;
        while now < $end && %!runs.values.first({ .<promise>.status == Planned || .<context>.cleanup.status == Planned }).defined {
            self.with-store({ self.drain-requests });
            await Promise.in(0.01);
        }
        self.with-store({
            self.drain-requests;
            for %!runs.values -> $run {
                my $context = $run<context>;
                my $definition = load-saga($context.service-id).definition;
                unless $definition<desired> {
                    my $lease = read-lease(journal-connection(), $context.service-id);
                    if $lease.defined && $lease<owner> eq $context.owner
                            && $lease<generation> == $context.generation && $lease<expires> > database-now(journal-connection()) {
                        if $context.cleanup.status == Broken || $context.late-cleanup-error.chars {
                            self.report($context, 'failed', :max-restarts(0),
                                :error($context.late-cleanup-error || $context.cleanup.cause.message));
                        } elsif $run<promise>.status != Planned && $context.cleanup.status == Kept {
                            self.report($context, 'exited');
                        } else {
                            self.report($context, 'stop-unconfirmed');
                        }
                    }
                }
                release-lease(journal-connection(), $context.fence);
            }
            $!requests-lock.protect({
                $!closed = True;
                loop {
                    my $request = $!requests.poll;
                    last unless $request.defined;
                    $request<reply>.break(X::AdHoc.new(payload => 'Service runtime is closed'));
                }
            });
            my $key = $!registration-key;
            $runtimes-lock.protect({
                %runtimes{$key}:delete if %runtimes{$key}.defined && %runtimes{$key} === self;
            });
            for %!runs.keys -> $id {
                %!runs{$id}:delete if %!runs{$id}<promise>.status != Planned
                    && %!runs{$id}<context>.cleanup.status != Planned;
            }
        });
        True
    }
}

register-service('redsourcing-managed-services', -> Str $operation, Capture $arguments, Str :$idempotency-key! {
    my $runtime = try $*REDSOURCING-SERVICE-RUNTIME;
    die 'Managed service actions require ServiceRuntime' unless $runtime.defined;
    $runtime.effect($operation, $arguments.hash<service-id>)
});
