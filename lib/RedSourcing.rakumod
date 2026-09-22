use Red;
use RedSourcing::Config;
use RedSourcing::Flow;
use RedSourcing::C;
use RedSourcing::Utils;
use RedSourcing::Event;
use RedSourcing::Command;
use RedSourcing::Traits;
use RedSourcing::StoredCommand;
use RedSourcing::X::OptimisticLockFailed;

use RedSourcing::StoredEvent;
use RedSourcing::Saga;

module RedSourcing { }

my package EXPORTHOW {
	package DECLARE {
		use Metamodel::RedSourcing::AggregateHOW;
		use Metamodel::RedSourcing::ProjectionHOW;
		use Metamodel::RedSourcing::SagaHOW;

		constant aggregate = Metamodel::RedSourcing::AggregateHOW;
		constant projection = Metamodel::RedSourcing::ProjectionHOW;
		constant saga = Metamodel::RedSourcing::SagaHOW;
	}
}

sub EXPORT {
	Map(
		Red.exports([]),
		RedSourcing::Traits::EXPORT::ALL::,
		RedSourcing::Utils::EXPORT::ALL::,
		RedSourcing::Saga::EXPORT::ALL::,
		'&config' => &config,
		'&red-sourcing-defaults' => &red-sourcing-defaults,
		'&enable-flow-tracing' => &enable-flow-tracing,
		'RedSourcing' => RedSourcing,
		'StoredEvent' => RedSourcing::StoredEvent,
		'StoredCommand' => RedSourcing::StoredCommand,
		'Event' => Event,
		'Command' => Command,
		'RedSourcing::X::OptimisticLockFailed' => RedSourcing::X::OptimisticLockFailed,
		# Preserve the merged dispatchers for Red and the event-store candidates.
		'&trait_mod:<is>' => &trait_mod:<is>,
		'&infix:<eqv>' => &infix:<eqv>,
	)
}

=begin pod

=head1 NAME

RedSourcing - event sourcing, projections and sagas for Raku, built on Red

=head1 SYNOPSIS

=begin code :lang<raku>

use RedSourcing;
red-defaults 'SQLite', :database(':memory:');
schema(StoredEvent, StoredCommand).create;

class CounterIncremented does Event {
    has Int $.id is required;
    has Int $.amount is required;
}
aggregate Counter {
    has Int $.id is entity-id;
    has Int $.value = 0;
    method APPLY(CounterIncremented $event) { $!value += $event.amount }
    method increment(Int :$amount where * > 0 = 1) is command {
        self.counter-incremented(:$amount);
        $!value
    }
}
my $counter = Counter.^with-ids(:id(1));
$counter.^create;
say $counter.increment(:amount(2));
my $pending = $counter.increment(:amount(3), :!sync);
say $pending.run;
say $pending.run;

=end code

=head1 PUBLIC API

C<use RedSourcing> imports C<aggregate>, C<projection>, C<saga>, the C<Event> and
C<Command> roles, C<is entity-id>, C<is entity-id-map>, C<is command>, storage aliases
C<StoredEvent>/C<StoredCommand>, saga helpers, configuration and Red database/schema
helpers. Import Red separately when declaring custom Red models or experimentals.

Aggregates replay their own stream from a required initial snapshot. Projections
select domain events across streams using SQL-translatable C<APPLY> signatures
and restore an optional checkpoint. Sagas restore committed controls without
executing effects; an external controller calls C<.^advance> to consume source
facts, run eligible actions and check persisted timeouts. C<advance-sagas> performs
one pass over every persisted running or compensating saga on the current connection.
Projections reject C<is command>; query an ordinary method on C<.^load> instead.
Application domain events should only be emitted by aggregate command handlers.

Domain commands use ordinary proxy methods. Creation, loading, identity, replay,
checkpoint and workflow helpers use C<.^>. Events emit at the next stream version
through generated aggregate methods. C<(stream, version)> is unique. Commands
persist before execution; a completed command reuses its result, and a failed
command retains its failure. Sagas submit retries explicitly.

=head1 CONFIGURATION

=begin code :lang<raku>

use RedSourcing;
my $settings = red-sourcing-defaults;
my $*RED-DEBUG = $settings.debug;

=end code

C<red-sourcing-defaults> reads the nearest C<red-sourcing.rakuconf> from the current
directory or its parents and configures Red's default connection. C<:file> selects
an explicit file; C<:driver>, C<:database>, C<:debug> and C<:connection> override its
values. It returns effective C<RedSourcing::Config::Settings> and creates missing
storage tables by default; pass C<:!initialize> to suppress table/index creation.
It does not migrate existing schemas. Imports and controller startup remain explicit.
Importing RedSourcing alone has
no configuration or connection effect.

Configuration files use C<use RedSourcing::Config; config { ... }>. The same file
provides CLI imports and worker/monitor defaults. PostgreSQL requires DB::Pg,
libpq and an existing database; initialization creates tables inside it.

=head1 CLI AND MONITOR

The installed CLI is C<red-sourcing>. In a checkout, run
C<raku -Ilib bin/red-sourcing.raku --help>. Help groups operations and shows examples.
Human-readable output is the default; C<--json> supports scripts. C<-f>,
C<--driver>, C<--database> and C<--debug> are universal options.

Use C<init>, C<command>, C<work>, entity creation/replay/checkpoints, history,
C<saga-status>, C<advance>, C<resolve-action>, C<stats> and C<web-monitor> to manage
a store. C<describe> reports identities, signatures and declarator documentation.
The standalone Cro/HTMX monitor discovers stored state without application
registration and exposes CLI operations through isolated jobs.

=head1 GUIDES

The maintained README and guides live in the distribution's repository:

=item C<README.md>: install, quick start, shared configuration, CLI, monitor and examples.
=item C<docs/configuration.md>: discovery, overrides, imports and PostgreSQL setup.
=item C<docs/api.md>: event/command storage, identity, replay, snapshots and migrations.
=item C<docs/sagas.md>: state/reaction scopes, services, compensation and deadlines.
=item C<docs/cli.md>: all CLI operations and reconciliation.
=item C<docs/web-monitor.md>: live inspection, charts and Operations.
=item C<docs/tutorials/food-delivery.md>: a step-by-step application.
=item C<docs/testing.md> and C<docs/next-steps.md>: validation and remaining work.

=head1 AUTHOR AND LICENSE

Fernando Correa de Oliveira. Copyright 2026.
Distributed under the Artistic License 2.0. Bundled web assets have their own licenses.

=end pod
