unit module RedSourcing::Tags;
use JSON::Fast;
use nqp;

role NotATagAttribute is export { }

role TaggedAttribute is export {
    has Str @.tag-aliases;
}
role TagFieldAttribute is export {
    method is-tag-field { True }
}

sub attribute-tag-names(Attribute $attribute --> List) is export {
    return ().List if $attribute ~~ NotATagAttribute;
    ($attribute.name.substr(2), |($attribute.?tag-aliases // ())).unique.List
}

# JSON numbers compare by value in both supported databases. In particular,
# Bool must not collapse into Int, and Str("1") must not collapse into 1.
sub normalize-event-data(%data --> Hash) is export {
    from-json(to-json(%data, :!pretty)).Hash
}

# Parse the JSON decimal representation exactly. Num.Rat's default tolerance
# would, for example, collapse 0.9999999e0 to 1 and disagree with a Rat key.
sub canonical-number(Numeric $value --> Array) {
    die 'Non-finite numbers cannot be event tags'
        if $value ~~ Num && !($value.abs < Inf);
    my ($mantissa, $exponent) = to-json($value, :!pretty).lc.split('e', 2);
    my ($whole, $fraction) = $mantissa.split('.', 2);
    $fraction //= '';
    my $numerator = ($whole ~ $fraction).Int;
    my $power = ($exponent // 0).Int - $fraction.chars;
    my $denominator = 1;
    if $power >= 0 { $numerator *= 10 ** $power }
    else { $denominator = 10 ** -$power }
    my $divisor = $numerator.abs gcd $denominator;
    ['number', ($numerator div $divisor).Str, ($denominator div $divisor).Str]
}

sub canonical-value($value) {
    return ['null'] unless $value.defined;
    given $value {
        when Bool { ['bool', .Bool] }
        when Str { ['str', .Str] }
        when Numeric { canonical-number($_) }
        when Associative { ['object', [.keys.sort.map({ [$_, canonical-value($value{$_})] })]] }
        when Positional { ['array', [.list.map({ canonical-value($_) })]] }
        default { canonical-value(from-json(to-json($value, :!pretty))) }
    }
}

sub normalized-counter-key(@path, $value?, Bool :$field = False --> Pair) {
    my $definition = to-json([$field ?? 'field' !! 'value', @path.Array,
        |($field ?? () !! (canonical-value($value),))], :!pretty);
    # B-tree keys have a size limit. Keep arbitrary JSON/string values out of
    # the index; every database operation checks the unhashed definition too.
    nqp::sha1($definition) => $definition
}

sub counter-key(@path, $value?, Bool :$field = False --> Pair) is export {
    normalized-counter-key(@path, ($field ?? Any !! from-json(to-json($value, :!pretty))), :$field)
}

sub tag-path-supported(Mu:U $type, @path --> Bool) is export {
    my $attribute = $type.^attributes.first(*.name.substr(2) eq @path.head);
    !($attribute ~~ NotATagAttribute)
}

sub tag-field-supported(Mu:U $type, @path --> Bool) is export {
    so $type.^attributes.first({
        $_ ~~ TagFieldAttribute && attribute-tag-names($_).first(* eq @path.head).defined
    })
}

sub event-counter-keys(Mu:U $type, %data, Bool :$normalized = False --> Hash) is export {
    my %payload = $normalized ?? %data !! normalize-event-data(%data);
    my %keys;
    my %attributes = $type.^attributes.map({ .name.substr(2) => $_ });
    sub visit(@path, $value, Bool $field) {
        my $value-key = normalized-counter-key(@path, $value);
        %keys{$value-key.key} = $value-key.value;
        if $field {
            my $key = normalized-counter-key(@path, :field);
            %keys{$key.key} = $key.value;
        }
        if $value ~~ Associative {
            visit([|@path, $_], $value{$_}, $field) for $value.keys;
        } elsif $value ~~ Positional {
            visit([|@path, $_], $value[$_], $field) for $value.keys;
        }
    }
    for %payload.kv -> $name, $value {
        my $attribute = %attributes{$name};
        next if $attribute ~~ NotATagAttribute;
        my @names = $attribute.defined ?? attribute-tag-names($attribute) !! ($name,);
        visit([$_], $value, so ($attribute ~~ TagFieldAttribute)) for @names;
    }
    %keys
}

# Map-style list-events rules may use an alias shared by several attributes.
sub tag-sources(Mu:U $type, Str $name --> List) is export {
    my @sources = $type.^attributes.grep({ attribute-tag-names($_).first(* eq $name).defined })
        .map(*.name.substr(2));
    (@sources ?? @sources !! ($name,)).unique.List
}
