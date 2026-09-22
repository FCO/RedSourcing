unit class RedSourcing::X::OptimisticLockFailed is Exception;

has Str  $.event-class;
has Str  $.stream;
has UInt $.version;

method message {
	"Optimistic lock failed: cannot emit '{$!event-class}' to stream '{$!stream}' "
	~ "at version {$!version} — an event with this (stream, version) already exists"
}
