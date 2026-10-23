unit module RedSourcing::Projection;
use nqp;
use Red;
use Red::AST;
use Red::AST::Infixes;
use Red::AST::Unary;
use Red::AST::JsonItem;
use Red::AST::Value;
use RedSourcing::C;
use RedSourcing::Utils;
use RedSourcing::Predicate;
use RedSourcing::Journal;
use RedSourcing::IsTransactional;

use RedSourcing::Lifecycle;
constant ProjectionLifecycle is export = EntityLifecycle;

my %subscriptions;
my $registry-lock = Lock.new;
my %discovered-units;
my $discovery-lock = Lock.new;
my $routing-lock = Lock.new;

my class ReceiverSymbol does Red::AST {
    has Str $.name;
    has Mu $.type;
    has Bool $.identity;
    method args { $!name, $!identity }
    method returns { $!type }
    method find-column-name { $!name }
}

sub register-projection(Mu:U $type, @handlers) is export {
    my @descriptors;
    for @handlers -> &handler {
        my @params = &handler.signature.params.grep({ !.invocant && !.slurpy });
        die 'A transactional APPLY requires one positional event parameter'
            unless @params.elems == 1 && @params.head.positional;
        @descriptors.push({ :$type, :&handler, event => @params.head.type });
    }
    $registry-lock.protect({ %subscriptions{$type.WHICH.Str} //= @descriptors });
}

# HOW metadata is serialized with its domain type; mutations to another module's
# registry during compose are not. Recover package-scoped types from each newly
# loaded unit once, independently of the compiler's legacy/RakuAST frontend.
sub discover-projections() {
    $discovery-lock.protect({ discover-loaded-projections() });
}

sub discover-loaded-projections() {
    my %visited;
    sub visit(Mu $value) {
        return unless nqp::istype(nqp::decont($value), Mu) && !nqp::isconcrete(nqp::decont($value));
        return if %visited{$value.WHICH.Str}++;
        my $how := nqp::how(nqp::decont($value));
        if nqp::can($how, 'transactional-handlers') {
            my $known = $registry-lock.protect({ %subscriptions{$value.WHICH.Str}:exists });
            $value.^subscribe unless $known;
        }
        my $who := nqp::who(nqp::decont($value));
        return if nqp::isnull($who);
        if nqp::istype($who, Associative) {
            visit($_) for $who.values;
            return;
        }
        my $iterator := nqp::iterator($who);
        while nqp::istrue($iterator) {
            nqp::shift($iterator);
            visit(nqp::iterval($iterator));
        }
    }
    for $*REPO.repo-chain -> $repository {
        for $repository.loaded -> $unit {
            next if %discovered-units{$unit.WHICH.Str}++;
            my $context := $unit.handle.unit;
            next unless nqp::isconcrete($context);
            my $iterator := nqp::iterator(nqp::ctxlexpad($context));
            while nqp::istrue($iterator) {
                nqp::shift($iterator);
                my $key = nqp::iterkey_s($iterator);
                next if $key.starts-with(any(<$ @ % & !>));
                visit(nqp::iterval($iterator));
            }
        }
    }
}

sub routing-ast(Mu:U $type, &handler --> Red::AST) {
    my $receiver := nqp::create(nqp::decont($type));
    my %ids = $type.^entity-id-names.map({ $_ => True });
    for $type.^attributes -> $attribute {
        die "Cannot infer {$type.^name} identity with native attribute {$attribute.name}; use Retained lifecycle"
            if $attribute.type.^name eq any(<int num str uint int8 int16 int32 uint8 uint16 uint32 num32>);
        my $name = $attribute.name.substr(2);
        my $symbol = ReceiverSymbol.new(:$name, :type($attribute.type), :identity(so %ids{$name}));
        nqp::bindattr(nqp::decont($receiver), $attribute.package, $attribute.name, nqp::decont($symbol));
    }
    my $rule = rules-from-func($receiver, &handler).head;
    require ::('RedSourcing::StoredEvent');
    predicate-ast(-> $row { $rule.value.(C.new(:json($row.data))) }, ::('RedSourcing::StoredEvent'))
}

sub branches(Red::AST $node --> Array) {
    return branches($node.value) if $node ~~ Red::AST::So;
    if $node ~~ Red::AST::AND {
        return [gather for branches($node.left) -> $left {
            for branches($node.right) -> $right { take [|$left, |$right] }
        }];
    }
    return [|branches($node.left), |branches($node.right)] if $node ~~ Red::AST::OR;
    return [] if $node ~~ Red::AST::Value && !$node.value;
    [[$node],]
}

sub symbols(Red::AST $node) { $node.transpose-grep(* ~~ ReceiverSymbol) }

sub expression-value(Red::AST $expression, $row) {
    return $expression.value if $expression ~~ Red::AST::Value;
    if $expression ~~ Red::AST::JsonItem && $expression.left ~~ Red::Column {
        my $path = $expression.right.value;
        my $value = $row.data;
        for ($path ~~ Positional ?? $path.List !! ($path,)) -> $part {
            my $key = $part ~~ Red::AST::Value ?? $part.value !! $part;
            return Any unless $value ~~ Associative || $value ~~ Positional;
            $value = $value ~~ Associative ?? $value{$key} !! $value[$key];
        }
        return $value;
    }
    require ::('RedSourcing::StoredEvent');
    ::('RedSourcing::StoredEvent').^all.grep(*.id == $row.id).map(-> $ { $expression }).head
}

sub normalize-ids(Mu:U $type, %values --> Hash) {
    my %ids;
    for $type.^entity-id-attrs -> $attribute {
        my $name = $attribute.name.substr(2);
        my $value = %values{$name};
        die "Missing transactional projection ID '$name' for {$type.^name}" unless $value.defined;
        unless $value ~~ $attribute.type {
            my $coercion = $attribute.type.^name;
            $value = $value."$coercion"() if $coercion eq any(<Str Int UInt Rat Num Bool>);
        }
        die "Invalid transactional projection ID '$name' for {$type.^name}"
            unless $value ~~ $attribute.type;
        %ids{$name} = $value;
    }
    %ids
}

sub inferred-targets(%descriptor, $row --> Array) {
    my $type = %descriptor<type>;
    my $ast = $routing-lock.protect({ %descriptor<ast> //= routing-ast($type, %descriptor<handler>) });
    my @ids = $type.^entity-id-names;
    my @targets;
    for branches($ast) -> @clauses {
        my %bindings;
        my @residual;
        for @clauses -> $clause {
            if $clause ~~ Red::AST::Eq {
                my ($target, $source) = $clause.left ~~ ReceiverSymbol
                    ?? ($clause.left, $clause.right) !! ($clause.right, $clause.left);
                if $target ~~ ReceiverSymbol && $target.identity && !symbols($source).elems {
                    (%bindings{$target.name} //= []).push($source);
                    @residual.push($clause);
                    next;
                }
            }
            @residual.push($clause);
        }
        die "Cannot infer all IDs of {$type.^name} from transactional APPLY; use Retained lifecycle"
            unless @ids.map({ %bindings{$_}:exists }).all;
        my %values;
        for @ids -> $id {
            %values{$id} = expression-value(%bindings{$id}.head, $row);
        }
        my %normalized = normalize-ids($type, %values);
        my @tests;
        for @residual -> $expression is copy {
            for symbols($expression) -> $symbol {
                die "Transactional identity discovery cannot depend on {$type.^name}.{$symbol.name}; use Retained lifecycle"
                    unless $symbol.identity;
                $expression = $expression.replace($symbol, ast-value(%normalized{$symbol.name}));
            }
            @tests.push($expression);
        }
        my $filter = @tests ?? @tests.head !! ast-value(True);
        $filter = Red::AST::AND.new($filter, $_) for @tests.skip;
        require ::('RedSourcing::StoredEvent');
        # Validate every equality again after normalization, including duplicate
        # assignments. One SQL predicate also preserves JSON/null semantics.
        my $accepted = ::('RedSourcing::StoredEvent').^all.where($filter)
            .grep(*.id == $row.id).map(*.id).head.defined;
        @targets.push(%normalized) if $accepted;
    }
    @targets
}

sub advance-transactional-projections(Mu:U $event-type, $row) is export {
    return if $row.mro.contains('|RedSourcing::Saga::Control|');
    discover-projections();
    my @subscriptions = $registry-lock.protect({
        [gather for %subscriptions.values -> $descriptors {
            take $_ for $descriptors.List;
        }]
    });
    my %targets;
    my $event;
    my $event-attribute;
    my $previous-row;
    LEAVE $event-attribute.get_value($event) = $previous-row if $event-attribute.defined;
    for @subscriptions -> %descriptor {
        next unless nqp::istype(nqp::decont($event-type), nqp::decont(%descriptor<event>));
        my $type = %descriptor<type>;
        if $type.^lifecycle == Retained {
            my @instances = retained-instances($type);
            if @instances && !$event.defined {
                $event = (try $*REDSOURCING-EMITTED-EVENT) // $row.COERCE($event-type);
                $event-attribute = $event.^attributes.first(*.name eq '$!StoredEvent');
                $previous-row = $event-attribute.get_value($event);
                $event-attribute.get_value($event) = $row;
            }
            for @instances -> $instance {
                my $working = entity-working($instance);
                my $*REDSOURCING-PHASE = 'APPLY';
                next unless %descriptor<handler>.signature.ACCEPTS(\($working, $event));
                %targets{entity-key($type, $working.^stream)} = $working;
            }
        } else {
            for inferred-targets(%descriptor, $row) -> %ids {
                my $proxy = $type.^with-ids(|%ids);
                my $key = entity-key($type, $proxy.^stream-name);
                %targets{$key} //= journal-working($key, {
                    $type.^lifecycle == Cached
                        ?? cached-load($type, $proxy.^stream-name, {
                            $type.^restore(:stream($proxy.^stream-name), |%ids)
                        }, :!replay)
                        !! $type.^restore(:stream($proxy.^stream-name), |%ids)
                });
            }
        }
    }
    for %targets.values -> $target {
        $target.^advance(:through-id($row.id), :checkpoint);
    }
}
