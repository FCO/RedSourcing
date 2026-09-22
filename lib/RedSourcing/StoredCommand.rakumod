use Red <refreshable>;
use Red::AST::Value;
use Red::Type::Json;
use RedSourcing::X::OptimisticLockFailed;
use JSON::Fast;
use RedSourcing::Utils;
use RedSourcing::Context;
use RedSourcing::Flow;
unit model RedSourcing::StoredCommand is table<red_sourcing_command>;

enum State <Pending Processing Done Failed>;

my constant CONFLICT-ATTEMPTS = 5;

has UInt     $.id         is serial;
has Str      $.stream     is column;
has Str      $.class      is column = self.^name;
has Str      $.method     is column;
has Str      $.entity     is column is required;
has Json     $.entity-ids is column is required;
has State    $.state      is column is rw = Pending;
has DateTime $.next-run   is column is rw = DateTime.now;
has UInt     $.tries      is column is rw = 0;
has Json     $.data       is column{ :nullable };
has Any      $.result     is column{ :nullable, :type<jsonb>, :inflate(&from-json), :deflate(&to-json) } is rw;
has Str      $.error      is column{ :nullable } is rw;

method run(::?CLASS:D: Bool :$wait) {
	assert-effect-allowed('command execution');
	my $flow-scope = flow-tracing-enabled;
	my $*REDSOURCING-FLOW-SCOPE = $flow-scope;
	my $failure;
	my $claimed = False;
	CATCH {
		when RedSourcing::X::OptimisticLockFailed { .rethrow }
		default {
			.rethrow unless $claimed;
			$failure = $_
		}
	}
	UNDO {
		with $failure {
			$!error = .message;
			$!state = Failed;
			$.^save;
			$failure.rethrow
		}
	}

	# Red has no savepoints. A nested command must let its transaction owner
	# roll back the complete batch before retrying.
	my $owns-transaction = !((try $*RED-TRANSACTION-RUNNING) // False);
	my UInt $conflicts = 0;
	my UInt $invocations = 0;
	loop {
		self.^refresh;
		return $!result if $!state == Done;
		die $!error if $!state == Failed;
		return unless $!state == Pending;

		if $wait {
			await Promise.at: $!next-run;
		} else {
			return if $!next-run > DateTime.now
		}

		my $again = False;
		my $conflict;
		{
			# Catch outside red-do so its UNDO has rolled back before the next
			# transaction starts (especially after a PostgreSQL unique violation).
			CATCH {
				when RedSourcing::X::OptimisticLockFailed {
					.rethrow unless $owns-transaction;
					$conflict = $_;
				}
			}
			red-do :transaction, {
				self.WHAT.^all.grep(*.id == $!id).map({ .state = .state }).save;
				self.^refresh;
				return $!result if $!state == Done;
				die $!error if $!state == Failed;
				return unless $!state == Pending;
				if $!next-run > DateTime.now {
					$again = True;
					False
				} else {
					self.state = Processing;
					self.^save;
					$claimed = True;
					require ::("RedSourcing::StoredEvent");
					my Mu $type = resolve-class($!entity);
					die 'Commands cannot target projections'
						if $type.HOW.^mro.grep(*.^name eq 'Metamodel::RedSourcing::ProjectionHOW').elems;
					my $entity = $type.^load(|$!entity-ids.Map, :$!stream);
					my $*COMMAND = self;
					$!tries += ++$invocations;
					$!result = $entity."$!method"(|$!data.Map);
					$!state = Done;
					$!error = Nil;
					self.^save;
					True
				}
			}
		}
		if $conflict.defined {
			$claimed = False;
			next if ++$conflicts < CONFLICT-ATTEMPTS;
			# Keep the record eligible for another worker pass. A conditional
			# update cannot overwrite a result committed by another executor.
			self.WHAT.^all.grep({ .id == $!id && .state == Pending })
				.map({ .tries += $invocations }).save if $invocations;
			self.^refresh;
			return $!result if $!state == Done;
			$conflict.rethrow;
		}
		next if $again;
		return $!result;
	}
}

method list-commands(
	UInt     :$from-id is copy,
	Str      :$stream,
	State()  :$state,
	*%_ where { .not },
) {
	my $rs = self.^all.sort(*.id);
	$rs   .= grep: *.id     >  $_ with $from-id;
	$rs   .= grep: *.stream eq $_ with $stream;
	$rs   .= grep: *.state  == $_ with $state;

	$rs.Seq
}
