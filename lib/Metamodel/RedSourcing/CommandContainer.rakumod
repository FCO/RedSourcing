unit role Metamodel::RedSourcing::CommandContainer;
use RedSourcing::IsCommand;

has %!commands;

method commands(Mu \entity) { %!commands }

multi method add_method(Mu $, Str $name, IsCommand $method) {
	%!commands{$name} = $method;
	nextsame
}

multi method add_method(Mu $, Str $name, $method) {
	nextsame
}
