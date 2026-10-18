unit role Entity;
use X::Red::Exceptions;

has UInt $!version    = 0;
has UInt $!current-id = 0;
has UInt $!checkpoint-cursor = 0;
has UInt $!snapshot-events = 0;
has Numeric $!snapshot-at = 0;
has      $!stream;

submethod TWEAK(:$StoredEvent, :$stream, :$saga-state, |) {
	self.^initialize-state($saga-state) if self.HOW.^can('initialize-state') && $saga-state.defined;
	with $StoredEvent {
		$!current-id = .replay-cursor // .id;
		$!checkpoint-cursor = .replay-cursor // 0;
		$!version    = .version;
		$!stream     = .stream;
		$!snapshot-at = .created.Instant.Num;
	} else {
		$!stream = $stream
	}
}

method new {
	die "Please do not construct a entity directly"
}

method APPLY {...}
