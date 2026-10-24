unit module RedSourcing::Service::Protocol;
use RedSourcing::Event;

class Control does Event is export {
    has Str $.service-id is required;
    has Str $.operation is required;
    has Hash $.definition is required;
}

# An adapter may defer its durable acknowledgement without storing a Promise.
class PendingStart is export {
    has Promise $.ready is required;
    has Hash $.result is required;
}

# Avoid loading the optional saga/runtime while composing application types.
sub service-call(Str $name, |arguments) is export {
    require ::('RedSourcing::Service');
    ::('RedSourcing::Service::EXPORT::DEFAULT').WHO{'&' ~ $name}(|arguments)
}
