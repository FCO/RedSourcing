use X::Red::Exceptions;
use RedSourcing::X::OptimisticLockFailed;
use RedSourcing::Context;
use RedSourcing::Flow;
use RedSourcing::Journal;
use RedSourcing::Tags;
use RedSourcing::Projection;
unit role Event;
has $!StoredEvent;

method StoredEvent {
	return $!StoredEvent
}

# Emission metadata belongs to the journal, independently of domain timestamps.
# It is undefined until the event has been written successfully.
method emitted-at (--> DateTime) {
	$!StoredEvent.defined ?? $!StoredEvent.created !! DateTime
}

submethod TWEAK (:$StoredEvent, |) {
	$!StoredEvent = $StoredEvent
}

method !data (--> Map()) {
	self.^attributes.map({
		next if .name eq "\$!StoredEvent";
		next unless .has_accessor;
		my $name = .name.substr(2);
		$name => self."$name"()
	})
}

multi method emit (::?CLASS: *%_ where {
	.not
}) {
	callsame
}

multi method emit (::?CLASS:D: UInt :$version!, Str :$stream!, *%_ where {
	.not
}) {
    my $*REDSOURCING-EMITTED-EVENT = self;
	$!StoredEvent = self.WHAT.emit(:version($version), :stream($stream), :data(self!data))
}

multi method emit (::?CLASS:U: UInt :$version!, Str :$stream!, *%data where {
	!(.<data>:exists)
}) {
	self.emit(:version($version), :stream($stream), :data(%data))
}

multi method emit (::?CLASS:U: UInt :$version!, Str :$stream!, :%data!, *%_ where {
	.not
}) {
	assert-effect-allowed('event emission');
	CATCH {
		when X::Red::Driver::Mapped::Unique {
			RedSourcing::X::OptimisticLockFailed.new(:event-class(self.^name), :stream($stream), :version($version)).throw
		}
	}
	require ::("RedSourcing::StoredEvent");
	my Mu $stored-event = ::("RedSourcing::StoredEvent");
	my $event-schema-version = self.^api.UInt // 0;
	my $mro                  = "|" ~ [|self.^mro, |self.^roles].map(*.^name).grep({ $_ !~~ /"<anon|" \d+ ">"/ }).join("|") ~ "|";
    my %payload = normalize-event-data(%data);
    # Decision queries exclude checkpoints and native saga controls. Counting
    # their internal state adds contention and false conflicts without protecting
    # any eligible decision fact.
    my %keys = ($mro.contains('|Entity|') || $mro.contains('|RedSourcing::Saga::Control|'))
        ?? %() !! event-counter-keys(self, %payload, :normalized);
    journal-append %keys, {
        my $row = $stored-event.^create(:event-schema-version($event-schema-version), :version($version), :stream($stream), :class(self.^name), :mro($mro), :data(%payload), |emission-causality());
        advance-transactional-projections(self, $row);
        $row
    }
}
