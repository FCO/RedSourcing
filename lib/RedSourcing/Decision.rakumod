unit module RedSourcing::Decision;

use nqp;
use Red;
use Red::AST;
use Red::AST::Infixes;
use Red::AST::Unary;
use Red::AST::JsonItem;
use Red::AST::Value;
use RedSourcing::Counters;
use RedSourcing::Tags;
use RedSourcing::StoredEvent;
use RedSourcing::Utils;
use RedSourcing::QueryTemplate;
use RedSourcing::Storage;
use RedSourcing::Context;
use RedSourcing::Journal;
use RedSourcing::Lifecycle;
use RedSourcing::X::OptimisticLockFailed;

# Non-identity state must not silently become a constant in a boundary query.
my class DecisionState does Red::AST {
    has Str $.name;
    has Mu $.type;
    method args { () }
    method returns { $!type }
    method find-column-name { $!name }
}

# Only immutable metadata and unbound dependency recipes are retained. No IDs,
# receivers or versions enter these process-local caches. Lists preserve both order and repetitions.
my Lock $plan-lock .= new;
my %list-plans;
my %counter-plans;

sub descriptor(Mu:U $type) {
    die 'decision-model accepts projection type => IDs pairs'
        unless $type.HOW.^mro.grep(*.^name eq 'Metamodel::RedSourcing::ProjectionHOW').elems;
    my $descriptor = $type.^projection-descriptor;
    die "native attribute {$descriptor<native-attributes>.head} is unsupported in decision models"
        if $descriptor<native-attributes>.elems;
    die $descriptor<rule-error> if $descriptor<rule-error>.defined;
    $descriptor
}

sub decision-plan(@types) {
    # Length-prefixed identities cannot collide through delimiter ambiguity.
    my $key = @types.map({ my $id = .WHICH.Str; $id.chars ~ ':' ~ $id }).join;
    # Force the maps here: lazy descriptor construction would escape the lock.
    $plan-lock.protect: {
        %list-plans{$key} //= @types.map({
            descriptor($_)
        }).eager.List
    }
}

# Positional identity prevents equal attribute names on repeated types from
# being folded together while composing the shared boolean expression.
my class DecisionParameter is ReceiverParameter {
    has Int $.position;
    method args { |callsame, $!position }
}
my class DecisionCursor is ReceiverParameter {
    has Int $.position;
    method args { $!position }
    method returns { UInt }
}
my %combined-plans;
sub combined-plan(@descriptors) {
    my $*RED-INTERNAL = True;
    my $key = @descriptors.map({ my $id = .<type>.WHICH.Str; $id.chars ~ ':' ~ $id }).join;
    $plan-lock.protect: {
        return %combined-plans{$key} if %combined-plans{$key}:exists;
        # Arbitrary runtime constraints retain the original inference path.
        return Nil if @descriptors.grep({ .<templates>.grep({ !($_<ast>:exists) }).elems }).elems;
        my @filters;
        my @dependencies;
        for @descriptors.kv -> $position, $descriptor {
            my @predicates;
            for $descriptor<templates>.kv -> $i, $template {
                die 'predicate depends on mutable projection state'
                    if $template<parameters>.grep({ !($descriptor<ids>{.name}:exists) }).elems;
                @predicates.push(bind-query-template($template<bindings>, -> $parameter {
                    $parameter ~~ EventColumn ?? $parameter !! DecisionParameter.new(
                        :$position, :name($parameter.name), :type($parameter.type), :attribute($parameter.attribute))
                }));
                @dependencies.push(%(:$position,
                    recipe => rule-counter-plan($descriptor<event-types>[$i], $template<ast>)));
            }
            my $filter = @predicates ?? (@predicates.elems == 1 ?? @predicates.head !! [OR] @predicates)
                !! ast-value(False);
            @filters.push(RedSourcing::StoredEvent.domain-filter($filter)
                AND (RedSourcing::StoredEvent.id > DecisionCursor.new(:$position)));
        }
        my $filter = @filters.elems == 1 ?? @filters.head !! [OR] @filters;
        %combined-plans{$key} = %(bindings => prepare-query-bindings($filter), dependencies => @dependencies.List);
    }
}

sub combined-counter-keys($plan, @models, %keys) {
    .<keys> = {} for @models;
    for $plan<dependencies>.List -> $entry {
        my %dependencies = bind-counter-plan($entry<recipe>, -> $constant {
            $constant ~~ ReceiverParameter
                ?? @models[$entry<position>]<ids>{$constant.name} !! $constant.value
        });
        for %dependencies.kv -> $key, $definition {
            %keys{$key} = $definition;
            @models[$entry<position>]<keys>{$key} = $definition;
        }
    }
}

sub bind-combined-plan($plan, @models, @values) {
    my $*RED-INTERNAL = True;
    bind-query-template($plan<bindings>, -> $parameter {
        if $parameter ~~ EventColumn {
            RedSourcing::StoredEvent."{$parameter.name}"()
        } elsif $parameter ~~ DecisionCursor {
            SnapshotCursor.new(:position($parameter.position))
        } else {
            my $value = @models[$parameter.position]<ids>{$parameter.name};
            my $slot = QueryBind.new(:index(@values.elems), :$value);
            @values.push($value);
            $slot
        }
    })
}

sub decision-filter($descriptor, %ids, %keys, @values) {
    my $*RED-FALLBACK = False;
    my $type = $descriptor<type>;
    CATCH { default {
        die "Cannot infer decision-model APPLY query for {$type.^name}; criteria must use IDs and constants, not mutable projection state: {.message}"
    } }
    my $receiver := nqp::create(nqp::decont($type));
    for $descriptor<attributes>.List -> $entry {
        my $name = $entry.key;
        my $attribute = $entry.value;
        if %ids{$name}:exists {
            $attribute.set_value($receiver, %ids{$name});
        } else {
            my $symbol = DecisionState.new(:$name, :type($attribute.type));
            nqp::bindattr(nqp::decont($receiver), $attribute.package, $attribute.name, nqp::decont($symbol));
        }
    }
    for $descriptor<templates>.List -> $template {
        next unless $template<ast>:exists;
        die 'predicate depends on mutable projection state'
            if $template<parameters>.grep({ !(%ids{.name}:exists) }).elems;
    }
    my @predicates = projection-query-filters(RedSourcing::StoredEvent, $descriptor, $receiver, @values);
    for @predicates.kv -> $i, $predicate {
        die 'predicate depends on mutable projection state'
            if $predicate.transpose-grep(* ~~ DecisionState).elems;
        my $template = $descriptor<templates>[$i];
        my %dependencies;
        if $template<ast>:exists {
            my $key = $type.WHICH.Str ~ ':' ~ $i;
            my $recipe = $plan-lock.protect: {
                %counter-plans{$key} //= rule-counter-plan($descriptor<event-types>[$i], $template<ast>)
            };
            %dependencies = bind-counter-plan($recipe, -> $constant {
                $constant ~~ ReceiverParameter ?? %ids{$constant.name} !! $constant.value
            });
        } else {
            %dependencies = rule-counter-keys($descriptor<event-types>[$i], $predicate);
        }
        for %dependencies.kv -> $key, $definition { %keys{$key} = $definition }
    }
    my $filter = @predicates ?? (@predicates.elems == 1 ?? @predicates.head !! [OR] @predicates)
        !! ast-value(False);
    $filter = RedSourcing::StoredEvent.domain-filter($filter);
    my @state = $filter.transpose-grep(* ~~ DecisionState);
    die 'predicate depends on mutable projection state: ' ~ @state».name.unique.join(', ')
        if @state;
    $filter
}

# Expand boolean alternatives while retaining the polarity of each comparison.
# The type tests added by pair-to-code are not counter dependencies.
sub alternatives($node, Bool $negative = False --> Array) {
    return alternatives($node.value, $negative) if $node ~~ Red::AST::Cast || $node ~~ Red::AST::So;
    return alternatives($node.value, !$negative) if $node ~~ Red::AST::Not;
    if $node ~~ Red::AST::AND || $node ~~ Red::AST::OR {
        my @left = alternatives($node.left, $negative);
        my @right = alternatives($node.right, $negative);
        return [|@left, |@right] if ($node ~~ Red::AST::OR) != $negative;
        return [gather for @left -> @a { for @right -> @b { take [|@a, |@b] } }];
    }
    if $node ~~ Red::AST::Value {
        return (so $node.value != $negative) ?? [[],] !! [];
    }
    [[$node => $negative],]
}

sub unwrap($node is copy) {
    $node = $node.value while $node ~~ Red::AST::Cast || $node ~~ Red::AST::So;
    $node
}

sub json-path($node is copy) {
    $node = unwrap($node);
    return Nil unless $node ~~ Red::AST::JsonItem;
    my $path = $node.right.value;
    my @path = $path ~~ Positional ?? $path.List !! ($path,);
    [@path.map({ $_ ~~ Red::AST::Value ?? .value !! $_ })]
}

sub predicate-for-rule(Pair $rule) {
    RedSourcing::StoredEvent.event-filter($rule)
}

sub rule-counter-plan(Mu:U $event, $predicate --> Hash) {
    my @checks;
    my @dependencies;
    for alternatives($predicate) -> @branch {
        my @equalities;
        my @fields;
        for @branch -> $literal {
            my $node = unwrap($literal.key);
            my $negative = $literal.value;
            my @items = $node.transpose-grep(* ~~ Red::AST::JsonItem);
            next unless @items;
            my $left = json-path($node.left);
            my $right = json-path($node.right);
            my $path = $left // $right;
            my $constant = unwrap($left.defined ?? $node.right !! $node.left);
            die 'Decision predicates require a field compared with a constant or ID'
                unless $path.defined && ($constant ~~ Red::AST::Value || $constant ~~ QueryBind || $constant ~~ ReceiverParameter)
                    && ($node ~~ Red::AST::Eq || $node ~~ Red::AST::Ne
                        || $node ~~ Red::AST::Lt || $node ~~ Red::AST::Le
                        || $node ~~ Red::AST::Gt || $node ~~ Red::AST::Ge);
            @checks.push($constant);
            next unless tag-path-supported($event, $path);
            my $field-expression = $left.defined ?? $node.left !! $node.right;
            # A cast can make distinct JSON types compare equal (e.g. 1 and
            # "1"). Such comparisons need field-wide protection, not an exact
            # value key, unless another equality covers the conjunction.
            if !( $field-expression ~~ Red::AST::Cast )
                    && (($node ~~ Red::AST::Eq && !$negative) || ($node ~~ Red::AST::Ne && $negative)) {
                @equalities.push(%(:$path, :$constant));
            } elsif tag-field-supported($event, $path) {
                @fields.push(%(:$path, field => True));
            }
        }
        # One positive equality already covers every possible event in this
        # conjunction. This also handles the !A && B path generated for A || B.
        die 'Each decision query alternative needs an equality or an is tag-field dependency'
            unless @equalities || @fields;
        @dependencies.append(|@equalities, |@fields);
    }
    %(checks => @checks.List, dependencies => @dependencies.flat.List)
}

sub bind-counter-plan($plan, &value --> Hash) {
    for $plan<checks>.List -> $constant {
        die 'Null decision comparisons cannot protect absent JSON paths' unless value($constant).defined;
    }
    my %keys;
    for $plan<dependencies>.List -> $entry {
        my $key = $entry<field> ?? counter-key($entry<path>, :field)
            !! counter-key($entry<path>, value($entry<constant>));
        %keys{$key.key} = $key.value;
    }
    %keys
}

sub rule-counter-keys(Mu:U $event, $predicate --> Hash) {
    bind-counter-plan(rule-counter-plan($event, $predicate), -> $constant { $constant.value })
}

# A cursor is not a commit watermark on Pg. Every changed guard must be fully
# accounted for by fetched facts; otherwise a lower-ID late commit (or a broad
# dependency outside this query) requires a fresh reconstruction.
sub complete-cache-tail(@models, $batch, %versions --> Bool) {
    my @cached = @models.grep({ .<base>.defined
        && (.<base><entity>.^version == ($batch<snapshots>{.<type>.^name}{.<stream>}.?version // 0)) });
    return True unless @cached;
    my @facts = $batch<events>.List.map(-> $row {
        %(id => $row.id, keys => event-counter-keys($row.COERCE.WHAT, $row.data, :normalized))
    });
    for @cached -> $model {
        my %counts;
        for @facts.grep({ .<id> > $model<base><entity>.^current-id }) -> $fact {
            %counts{$_}++ for $fact<keys>.keys;
        }
        for $model<keys>.keys -> $key {
            return False unless (%versions{$key} - ($model<base><versions>{$key} // 0)) == (%counts{$key} // 0);
        }
    }
    True
}

# Explicit type => IDs pairs avoid creating/loading proxies just to describe a read.
sub decision-model(*@arguments) is export {
    my $*RED-FALLBACK = False;
    assert-effect-allowed('decision-model');
    die 'decision-model requires projection type => IDs pairs followed by a block'
        unless @arguments.elems >= 2 && @arguments.tail ~~ Callable;
    my &work = @arguments.pop;
    my @models;
    for @arguments -> $argument {
        die 'decision-model accepts projection type => IDs pairs'
            unless $argument ~~ Pair && !$argument.key.DEFINITE && $argument.value ~~ Associative;
    }
    my @plan = decision-plan(@arguments.map(*.key)).List;
    for @arguments.kv -> $position, $argument {
        my $type = $argument.key;
        my %ids = $argument.value.Hash;
        die "decision-model IDs do not match {$type.^name}"
            unless %ids.keys.Set eqv @plan[$position]<ids>;
        # Reuse normal identity validation/stream naming without loading state.
        my $proxy = $type.^with-ids(|%ids);
        @models.push({ :$type, :%ids, descriptor => @plan[$position], stream => $proxy.^stream-name });
    }
    my $combined = combined-plan(@plan);
    journal-connection().journal-ensure-counters;
    red-do :transaction, {
        my $connection = journal-connection();
        if is-pg($connection) {
            my @isolation = counter-sql($connection, 'SHOW transaction_isolation');
            die 'decision-model requires PostgreSQL READ COMMITTED isolation'
                unless @isolation.head.values.head eq 'read committed';
        }
        my %keys;
        my @values;
        my @filters;
        if $combined.defined {
            combined-counter-keys($combined, @models, %keys);
        } else {
            @filters = @models.map({
                my %local;
                my $filter = decision-filter(.<descriptor>, .<ids>, %local, @values);
                .<keys> = %local.Hash;
                %keys{$_} = %local{$_} for %local.keys;
                $filter
            });
        }
        my %versions = read-counters($connection, %keys);
        my $state = $connection.journal-state;
        my %own = $state<counter-increments>.Hash;
        if $combined.defined {
            .<base> = decision-cache-read(.<type>, .<stream>) for @models;
        }
        my $filter;
        if $combined.defined {
            $filter = bind-combined-plan($combined, @models, @values);
        } else {
            my $*RED-INTERNAL = True;
            @filters = @filters.kv.map(-> $i, $predicate {
                $predicate AND (RedSourcing::StoredEvent.id > SnapshotCursor.new(:position($i)))
            }).Array;
            $filter = @filters.elems == 1 ?? @filters.head !! [OR] @filters;
        }
        my $key = 'decision:' ~ @models.map(*.<type>.WHICH.Str).join('|');
        my $has-fallback = !$combined.defined;
        my $batch = storage-decision-rows(RedSourcing::StoredEvent, $key, @models,
            $filter, @values, :cache(!$has-fallback));
        unless complete-cache-tail(@models, $batch, %versions) {
            .<base>:delete for @models;
            $batch = storage-decision-rows(RedSourcing::StoredEvent, $key, @models,
                $filter, @values, :cache(!$has-fallback));
        }
        my %restored;
        my @views = @models.map({
            my $snapshot = $batch<snapshots>{.<type>.^name}{.<stream>};
            if .<base>.defined && .<base><entity>.^version == ($snapshot.?version // 0) {
                .<base><entity>
            } elsif $snapshot.defined && (%restored{$snapshot.id}:exists) {
                # The same row's decoded nested containers must not leak
                # between repeated positions in a decision.
                entity-copy(%restored{$snapshot.id})
            } else {
                my $view = .<type>.^restore-state($snapshot, :stream(.<stream>), |.<ids>);
                %restored{$snapshot.id} = $view if $snapshot.defined;
                $view
            }
        });
        for @models.kv -> $i, $model { $model<cursor> = @views[$i].^current-id }
        for $batch<events>.List -> $row {
            my $event = $row.COERCE;
            for @views.kv -> $i, $view {
                next if $row.id <= @models[$i]<cursor>;
                next unless $view.^find_method('APPLY').cando(\($view, $event)).elems;
                apply-event($view, $event);
                $view.^record-applied(:at($row.created));
                $view.^current-id = $row.id;
            }
        }
        if $combined.defined {
            for @views.kv -> $i, $view {
                my %local = @models[$i]<keys>.keys.map({ $_ => %versions{$_} });
                decision-cache-stage($view, %local);
            }
        }
        my $decision = { :%keys, :%versions, :%own, validated => False };
        my $scope = $decision.WHICH.Str;
        $decision<scope> = $scope;
        $state<decisions>.push($decision);
        my &*REDSOURCING-APPEND-CONDITION = &journal-decision-condition;
        do {
            LEAVE $state<decisions> = $state<decisions>.grep(*.<scope> ne $scope).Array;
            work(|@views)
        }
    }
}
