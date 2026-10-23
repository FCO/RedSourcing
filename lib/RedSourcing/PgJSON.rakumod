use Red::AST::JsonItem;
use Red::AST::Value;
use Red::AST::Insert;
use Red::Type::Json;
use Red::AST::Infixes;
use Red::AST::Unary;
use JSON::Fast;
unit role RedSourcing::PgJSON;

sub mro-column($column) {
    $column ~~ Red::Column && $column.name eq 'mro'
        && $column.model.^orig.^name eq 'RedSourcing::StoredEvent'
}
multi method translate(Red::Column $column where { mro-column($_) }, 'column-type') {
    'text[]' => []
}
# ORM readers expect the logical string, so let Pg render it directly instead
# of parsing an array in DB::Pg and joining it again for every hydrated row.
multi method translate(Red::Column $column where { mro-column($_) }, 'select',
    Str :$RED-OVERRIDE-COLUMN-AS-PREFIX) {
    return callsame if $column.computation.DEFINITE;
    my $table = self.table-name-wrapper($column.model.^as);
    my $name = self.table-name-wrapper($column.name);
    my $alias = ($RED-OVERRIDE-COLUMN-AS-PREFIX.defined ?? "$RED-OVERRIDE-COLUMN-AS-PREFIX." !! '')
        ~ $column.attr-name;
    my $inside = try so $*RED-INSIDE-COMPUTATION;
    "('|' || array_to_string($table.$name, '|') || '|')"
        ~ ($inside ?? '' !! ' AS ' ~ self.table-name-wrapper($alias)) => []
}
# Preserve existing ORM string membership expressions. Optimized framework
# predicates use EventTypeMembership and operate on the native column instead.
multi method translate(Red::AST::Like $like where { mro-column(.left) }, $context?) {
    my ($column, @cb) := self.translate($like.left, 'table-dot-column').kv;
    my ($pattern, @pb) := self.translate($like.right, $context).kv;
    "('|' || array_to_string($column, '|') || '|') LIKE $pattern" => [|@cb, |@pb]
}
multi method translate(Red::AST::Value $value where {
    .type ~~ Pair && mro-column(.value.key)
}, 'update') {
    my $column = self.translate($value.value.key, 'update-lval').key;
    my ($sql, @binds) := self.translate($value.value.value, 'update-rval').kv;
    "$column = string_to_array(trim(both '|' from ($sql)::text), '|')" => @binds
}

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

# Keep storage INSERT plans stable across Hash iteration order, retaining Pg's
# JSON parameter casts and RETURNING contract.
multi method translate(Red::AST::Insert $insert, $context?) {
    return callsame unless $insert.into.^name eq any(
        <RedSourcing::StoredEvent RedSourcing::StoredCommand RedSourcing::StoredCounter>);
    my Int $*bind-counter;
    my @values = $insert.values.pairs.grep({
        .value.value.defined || (.value.column.DEFINITE
            && .value.column.attr.type ~~ Json && !(.value.value === Json))
    }).sort(*.key);
    my $table = self.table-name-wrapper($insert.into.^table);
    return "INSERT INTO $table DEFAULT VALUES RETURNING *" => [] unless @values;
    my @binds = @values.map({ self.wildcard-value(.value) });
    my @placeholders = @values.map({
        my $placeholder = self.wildcard;
        mro-column(.value.column)
            ?? "string_to_array(trim(both '|' from ($placeholder)::text), '|')"
            !! .value.column.attr.type ~~ Json ?? "$placeholder\::text::jsonb" !! $placeholder
    });
    'INSERT INTO ' ~ $table ~ ' (' ~ @values.map({ self.table-name-wrapper(.key) }).join(',')
        ~ ') VALUES (' ~ @placeholders.join(',') ~ ') RETURNING *' => @binds
}
