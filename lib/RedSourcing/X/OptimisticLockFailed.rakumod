unit class RedSourcing::X::OptimisticLockFailed is Exception;

has Str  $.event-class;
has Str  $.stream;
has UInt $.version;
has UInt $.after;
has Str $.boundary;

method message {
	return "Optimistic lock failed: decision model {$!boundary} changed after journal position {$!after}"
		if $!boundary.defined;
	"Optimistic lock failed: cannot emit '{$!event-class}' to stream '{$!stream}' "
	~ "at version {$!version} — an event with this (stream, version) already exists"
}
