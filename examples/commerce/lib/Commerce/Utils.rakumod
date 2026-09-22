use RedSourcing;
unit module Commerce::Utils;
sub entity-exists($proxy --> Bool) is export {
    so StoredEvent.^all.grep({ .stream eq $proxy.^stream-name && .class eq $proxy.^entity-type.^name }).head
}
