unit role Entity;
use X::Red::Exceptions;

has UInt $!version    = 0;
has UInt $!current-id = 0;
has      $!stream;

submethod TWEAK(:$StoredEvent, :$stream, :$saga-state, |) {
	self.^initialize-state($saga-state) if self.HOW.^can('initialize-state') && $saga-state.defined;
	with $StoredEvent {
		$!current-id = .replay-cursor // .id;
		$!version    = .version;
		$!stream     = .stream;
	} else {
		$!stream = $stream
	}
}

method new {
	die "Please do not construct a entity directly"
}

method APPLY {...}
