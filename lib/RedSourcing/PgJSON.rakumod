use Red::AST::JsonItem;
use Red::AST::Value;
use Red::AST::Infixes;
use Red::AST::Unary;
use JSON::Fast;
unit role RedSourcing::PgJSON;

# Red 0.2.7 owns path binding, including dynamic keys and array indexes.
# SQL casts of JSON strings must use their text value, without JSON quotes.
multi method translate(Red::AST::Cast $cast where .value ~~ Red::AST::JsonItem, $context?) {
    my ($sql, @bind) = do given self.translate($cast.value, $context) { .key, |.value };
    my %types = str => 'text', num => 'numeric', int => 'integer', boolean => 'boolean',
        datetime => 'timestamp', date => 'date';
    my $type = %types{$cast.type} // die "Unsupported JSON scalar cast: {$cast.type}";
    "(($sql) #>> ARRAY[]::text[])::$type" => @bind
}
# eqv produces an uncast equality. Compare JSONB to a JSON-encoded value,
# rather than asking PostgreSQL to parse a bare string such as seed-cedar.
multi method translate(Red::AST::Eq $eq where {
    (.left ~~ Red::AST::JsonItem && .right ~~ Red::AST::Value)
        || (.right ~~ Red::AST::JsonItem && .left ~~ Red::AST::Value)
}, $context?) {
    my $json = $eq.left ~~ Red::AST::JsonItem ?? $eq.left !! $eq.right;
    my $value = $eq.left ~~ Red::AST::JsonItem ?? $eq.right !! $eq.left;
    my ($sql, @bind) = do given self.translate($json, $context) { .key, |.value };
    "$sql = {self.wildcard}::jsonb" => [|@bind, to-json($value.get-value, :!pretty)]
}
