unit module RedSourcing::EventType;
use Red::AST;
use Red::AST::Unary;

# A semantic predicate: templates do not depend on the storage driver's format.
class EventTypeMembership does Red::AST is export {
    has Red::AST $.column is required;
    has Str $.name is required;
    method args { $!column, $!name }
    method returns { Bool }
    method find-column-name { $!column.find-column-name }
    method not { Red::AST::Not.new(self) }
}
sub event-type-ast(Red::AST $column, Str $name) is export {
    EventTypeMembership.new(:$column, :$name)
}
sub pg-driver($driver --> Bool) is export {
    so $driver.^mro.map(*.^name).first(* eq 'Red::Driver::Pg').defined
}
sub mro-string($value) is export {
    $value ~~ Positional:D ?? '|' ~ $value.join('|') ~ '|' !! $value
}
# For internal SQL with constant type names. Column identifiers are framework
# literals; quote names as values, never interpolate them as SQL syntax.
sub event-type-sql($driver, Str $name, Str $column = 'mro' --> Str) is export {
    my $quoted = $name.subst("'", "''", :g);
    pg-driver($driver) ?? "$column \@> ARRAY['$quoted']::text[]"
        !! "$column LIKE '%|$quoted|%'"
}
