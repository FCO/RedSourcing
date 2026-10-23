use RedSourcing::Event;
use RedSourcing::EventType;
use Red;
use Red::DB;
use RedSourcing::StoredEvent;
use RedSourcing::Utils;
use RedSourcing::Context;
unit module RedSourcing::Saga;

# Adapters must distinguish a known rejection from an unknown external outcome.
class Permanent is Exception is export {
    has Str $.message = 'Operation rejected';
}
class Uncertain is Exception is export {
    has Str $.message = 'External outcome is unknown';
}
class Retryable is Exception is export {
    has Str $.message = 'Operation failed without taking effect';
}
class Exponential is export { }

class Control does Event {
    has Hash $.state is required;
    has Hash $.values is required;
    has UInt $.cursor is required;
    has Str $.step = '';
    has Str $.action-id = '';
    has $.result;
    has Str $.error = '';
}
class StateChanged is Control { }
class StepSucceeded is Control is export { }
class StepFailed is Control is export { }
class StepUncertain is Control is export { }
class CompensationSucceeded is Control is export { }
class TimeoutTriggered is Control { }

my %services;
sub register-service(Str $name, &adapter) is export { %services{$name} = &adapter }
our sub service-adapter(Str $name) {
    die "No saga service adapter '$name'" unless %services{$name}:exists;
    %services{$name}
}

# One controller pass over persisted instances, not just loaded proxy objects.
sub advance-sagas(DateTime :$now = DateTime.now, UInt :$limit = 100 --> Hash) is export {
    assert-effect-allowed('saga controller');
    my $table = RedSourcing::StoredEvent.^table.subst('"', '""', :g);
    # Transfer only the latest snapshot/control ID per stream instead of every
    # historical full-state payload. The query works on SQLite and PostgreSQL.
    my $runtime-type = event-type-sql(get-RED-DB, 'RedSourcing::Saga::Runtime');
    my $control-type = event-type-sql(get-RED-DB, 'RedSourcing::Saga::Control');
    my $query = get-RED-DB.execute(qq:to/SQL/);
        SELECT MAX(id) AS id FROM "$table"
        WHERE $runtime-type OR $control-type
        GROUP BY stream ORDER BY MAX(id)
        SQL
    my @ids;
    loop {
        my $row = $query.row;
        # Pg returns IterationEnd; SQLite returns an empty hash at exhaustion.
        last unless $row ~~ Associative && $row.elems;
        @ids.push($row<id>);
    }

    my @results;
    my $advanced = 0;
    my $failed = 0;
    for @ids -> $id {
        my $row = RedSourcing::StoredEvent.^all.grep(*.id == $id).head;
        next unless $row.defined;
        my $control = $row.mro.contains('|RedSourcing::Saga::Control|');
        my $state = $control ?? $row.data<state> !! $row.data<saga-state>;
        next unless $state<status> eq any(<running compensating>);
        my $name = $control ?? $row.stream.split(': ', 2).head !! $row.class;
        my %result = stream => $row.stream, type => $name, status => $state<status>;
        my $entity;
        my $selected = False;
        {
            CATCH {
                default {
                    %result<error> = .message;
                    %result<status> = $entity.^status if $entity.defined;
                    $selected = True;
                    $failed++;
                }
            }
            my Mu $type = resolve-class($name);
            die "'$name' is not a saga"
                unless $type.HOW.^mro.grep(*.^name eq 'Metamodel::RedSourcing::SagaHOW').elems;
            $entity = $type.^load(:stream($row.stream));
            # Another executor may have completed it since discovery.
            if $entity.^status eq any(<running compensating>) {
                $selected = True;
                $entity.^advance(:$now, :$limit);
                %result<status> = $entity.^status;
                $advanced++;
            }
        }
        @results.push(%result) if $selected;
    }
    %(advanced => $advanced, failed => $failed, sagas => @results.Array)
}

role Runtime {
    has Hash $!saga-state = %(
            serial => 0, status => 'running', actions => [],
            compensations => [], timers => {},
        );

    method set-timeout(Str $name, Numeric $interval, *%command) {
        self.^set-timeout($name, $interval, |%command)
    }
    method cancel-timeout(Str $name) { self.^cancel-timeout($name) }
}
