use Red::AST::JsonItem;
use Red::AST::Value;
use Red::AST::Infixes;
use Red::AST::Unary;
use JSON::Fast;
unit role RedSourcing::PgJSON;

# Red's Pg JSON path translation interpolates away the array braces. Bind each
# path component instead, preserving punctuation and avoiding SQL literals.
method !json-path(Red::AST::JsonItem $item, $context, Str $operator) {
    my ($left, @bind) = do given self.translate($item.left, $context) { .key, |.value };
    my @parts = gather {
        sub component($value) {
            given $value {
                when Red::AST::Value { component(.value) }
                when Positional { component($_) for .List }
                default { take .Str }
            }
        }
        component($item.right.value);
    };
    my $array = @parts.map({ self.wildcard }).join(', ');
    "($left $operator ARRAY[$array]::text[])" => [|@bind, |@parts.map(*.Str)]
}
multi method translate(Red::AST::JsonItem $item, $context?) {
    self!json-path($item, $context, '#>')
}
# SQL casts of JSON strings must use their text value, without JSON quotes.
multi method translate(Red::AST::Cast $cast where .value ~~ Red::AST::JsonItem, $context?) {
    my ($sql, @bind) = do given self!json-path($cast.value, $context, '#>>') { .key, |.value };
    my %types = str => 'text', num => 'numeric', int => 'integer', boolean => 'boolean',
        datetime => 'timestamp', date => 'date';
    my $type = %types{$cast.type} // die "Unsupported JSON scalar cast: {$cast.type}";
    "($sql)::$type" => @bind
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
