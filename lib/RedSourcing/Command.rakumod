use RedSourcing::StoredCommand;
use RedSourcing::Context;
use RedSourcing::Flow;
unit role Command;
has $!StoredCommand;

method StoredCommand {
	return $!StoredCommand
}

submethod TWEAK (:$StoredCommand, |) {
	$!StoredCommand = $StoredCommand
}

method !data (--> Map()) {
	self.^attributes.map({
		next if .name eq "\$!StoredCommand";
		next unless .has_accessor;
		my $name = .name.substr(2);
		$name => self."$name"()
	})
}

method stream-name {
	my %ids = self.^entity-id-map;
	self.^name ~ ": " ~ join ", ", do for %ids.keys.sort -> $id { "$id: %ids{$id}" }
}

multi method emit (::?CLASS: *%_ where {
	.not
}) {
	callsame
}

multi method emit (::?CLASS:D: Str :$entity!, :%entity-ids!, Str :$method!, Str :$stream!, *%_ where {
	.not
}) {
	self.WHAT.emit(:$entity, :%entity-ids, :$method, :$stream, :data(self!data))
}

multi method emit (::?CLASS:U: Str :$entity!, :%entity-ids!, Str :$method!, Str :$stream!, *%data where {
	!(.<data>:exists)
}) {
	self.emit(:$entity, :%entity-ids, :$method, :$stream, :%data)
}

multi method emit (::?CLASS:U: Str :$entity!, :%entity-ids!, Str :$method!, Str :$stream!, :%data!, *%_ where {
	.not
}) {
	assert-effect-allowed('command submission');
	my $row = RedSourcing::StoredCommand.^create(:$entity, :%entity-ids, :$method, :$stream, :class(self.^name), :%data);
	my $parent = try $*COMMAND;
	flow-link('command', $parent.id.Str, 'command', $row.id.Str, 'submitted') if $parent.defined;
	$row
}
