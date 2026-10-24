unit module RedSourcing::Query;
use nqp;

role IsQuery is export { }
role QueryAttribute is export { }
role QueryGuarded is export { }
role CommandGuarded is export { }

# The return boundary carries values, never live database resources. In
# particular, don't serialize through JSON: Rat and typed collections matter.
sub query-copy($value) is export {
    my %active;
    my %copies;
    sub copy($item) {
        $item.throw if $item ~~ Failure;
        return $item unless $item.defined;
        return $item if $item ~~ Str|Numeric|Bool;
        return $item.Mu::clone if $item ~~ Dateish|Instant|Duration;
        my $name = $item.^name;
        die "Query must return materialized data, not $name"
            if $name.starts-with('Red::') || $item.HOW.^mro.grep({ .^name.starts-with('MetamodelX::Red::') }).elems;
        my $key = nqp::where(nqp::decont($item)).Str;
        die 'Query results must be acyclic data' if %active{$key};
        return %copies{$key} if %copies{$key}:exists;
        %active{$key} = True;
        LEAVE %active{$key}:delete if $key.defined;
        my $result = do given $item {
            when Array {
                my $out = .clone;
                $out[$_] = copy($item[$_]) for .keys;
                $out
            }
            when Hash {
                my $out = .clone;
                $out{$_} = copy($item{$_}) for .keys;
                $out
            }
            when Map { Map.new(.pairs.map({ .key => copy(.value) })) }
            when Pair { copy(.key) => copy(.value) }
            when List { .map({ copy($_) }).eager.List }
            when Seq { .map({ copy($_) }).eager.Seq }
            when Set|SetHash|Bag|BagHash|Mix|MixHash {
                die 'Query set/bag keys must be scalar data' if .keys.first({ $_ !~~ Str|Numeric|Bool }).defined;
                .clone
            }
            default { die "Unsupported query result $name; return scalar values and data collections" }
        };
        %copies{$key} = $result;
        $result
    }
    copy($value)
}

sub query-invoke($entity, Str $method, Capture $arguments) is export {
    my $*REDSOURCING-PHASE = 'QUERY';
    query-copy($entity."$method"(|$arguments))
}

sub proxy-query($proxy, Str $method, Capture $arguments) is export {
    my $context = try $*REDSOURCING-SERVICE-CONTEXT;
    if $context.defined {
        return $context.executor.context-query($context, $proxy, $method, $arguments);
    }
    my $phase = (try $*REDSOURCING-PHASE) // '';
    die 'Service query requires a bound ServiceContext' if $phase eq any('SERVICE', 'SERVICE-READ');
    my $entity = do {
        # Internal reconstruction may maintain checkpoints; the query body may not.
        my $*REDSOURCING-PHASE = $phase eq 'QUERY' ?? 'EXECUTE' !! $phase;
        $proxy.^load
    };
    query-invoke($entity, $method, $arguments)
}
