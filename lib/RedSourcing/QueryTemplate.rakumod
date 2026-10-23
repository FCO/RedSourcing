unit module RedSourcing::QueryTemplate;
use nqp;
use experimental :rakuast;
use Red;
use Red::AST;
use Red::AST::Value;
use Red::AST::Infixes;
use Red::AST::Unary;
use Red::Type::Json;
use Red::ColumnMethods;
use RedSourcing::C;
use RedSourcing::EventType;

# This registry is used only while composing a compilation unit. The resulting
# shapes, not the registry or compiler nodes, are saved with the projection HOW.
my @constraints;
sub constraint-variables(Mu $ast --> List) {
    my @references;
    my %seen;
    if $ast.^name.starts-with('QAST::') {
        sub walk(Mu $node, %outer, Bool $dynamic = False) {
            return unless nqp::can($node, 'ann');
            return if %seen{nqp::where(nqp::decont($node))}++;
            my %locals = %outer;
            if nqp::can($node, 'symbol') {
                # A block's symbol table includes declarations in that lexical
                # scope, but not captures from its outer scopes.
                my Mu $symbols := $node.symtable;
                for nqp::hllize($symbols).keys -> $name { %locals{$name} = True }
            }
            if nqp::can($node, 'scope') && nqp::can($node, 'name') {
                my $name = $node.name;
                @references.push($name)
                    if $node.scope eq any(<lexical contextual package>)
                    && $name.substr(0, 1) eq any('$', '@', '%', '&')
                    && !$node.decl && !(%locals{$name}:exists);
            }
            my $in-dynamic = $dynamic || (nqp::can($node, 'op') && $node.op eq 'call' && $node.name eq '&DYNAMIC');
            if $in-dynamic && $node.^name eq 'QAST::SVal' {
                my $name = $node.value;
                @references.push($name) unless %locals{$name}:exists;
            }
            # Qualified package variables are lowered to a stash lookup rather
            # than QAST::Var. Ordinary event/hash subscripts have no `who`.
            if nqp::can($node, 'op') && $node.op eq 'callmethod' && $node.name eq 'AT-KEY' {
                my @children = nqp::hllize($node.list).List;
                if @children.elems == 2 && nqp::can(@children[0], 'op')
                    && @children[0].op eq 'who' && nqp::can(@children[1], 'value') {
                    my Mu $name = @children[1].value;
                    @references.push($name) if $name ~~ Str && $name.substr(0, 1) eq any('$', '@', '%', '&');
                }
            }
            for nqp::hllize($node.list).List -> $child { walk($child, %locals, $in-dynamic.so) }
            my Mu $block := $node.ann('past_block');
            walk($block, %locals) if nqp::isconcrete($block);
        }
        walk($ast, {});
    } else {
        my @nodes;
        sub visit(Mu $node) {
            return if %seen{nqp::where(nqp::decont($node))}++;
            @nodes.push($node);
            $node.visit-children(-> Mu $child { visit($child) });
        }
        visit($ast);
        for @nodes -> $node {
            next unless $node ~~ RakuAST::Var::Lexical|RakuAST::Var::Dynamic|RakuAST::Var::Package;
            next if $node ~~ RakuAST::Var::Lexical && $node.is-resolved
                && @nodes.first({ $_ === $node.resolution }).defined;
            @references.push($node ~~ RakuAST::Var::Package
                ?? $node.sigil ~ $node.twigil ~ $node.name.canonicalize
                !! $node.name);
        }
    }
    @references.unique.List
}
sub record-query-constraint(Mu $code, Str $source, Mu :$ast) is export {
    @constraints.push([$code, $source, $ast.defined ?? constraint-variables($ast) !! ()]);
}
sub constraint-entry(Mu $code) {
    for @constraints.reverse -> $entry {
        my Mu $candidate = $entry[0];
        unless $candidate ~~ Code {
            $candidate = try {
                my $primed = $candidate.?IMPL-PRIMED;
                ($primed ?? $primed !! $candidate).meta-object
            };
        }
        return $entry if $candidate.defined && $candidate === $code;
    }
    Nil
}
sub constraint-source(Mu $code) { constraint-entry($code)[1] }

sub validate-handler-constraints(Mu:U $entity, @trusted --> List) is export {
    my @validated;
    for <APPLY REACT> -> $method {
        my $handler = $entity.^find_method($method);
        next unless $handler.defined;
        for $handler.candidates -> &candidate {
            @validated.push(&candidate);
            next if @trusted.first({ $_ === &candidate }).defined;
            sub parameters($signature) {
                gather for $signature.params -> $parameter {
                    take $parameter;
                    if $parameter.sub_signature {
                        take $_ for parameters($parameter.sub_signature);
                    }
                }
            }
            my @parameters = parameters(&candidate.signature);
            my %allowed = @parameters.map({ .name => True });
            %allowed<$_> = True;
            for @parameters -> $parameter {
                my $constraints := nqp::getattr(nqp::decont($parameter), Parameter, '@!post_constraints');
                next if nqp::isnull($constraints);
                for ^nqp::elems($constraints) -> $i {
                    my Mu $constraint := nqp::atpos($constraints, $i);
                    my $entry = constraint-entry($constraint);
                    unless $entry.defined {
                        die "{$entity.^name}.$method where cannot be validated: constraint source unavailable; declare the filter on the entity"
                            if $constraint ~~ Code;
                        next;
                    }
                    for $entry[2].List -> $name {
                        die "{$entity.^name}.$method where cannot capture external variable $name; use an event parameter or an entity attribute"
                            unless %allowed{$name}:exists;
                    }
                }
            }
        }
    }
    @validated.List
}

# A deliberately closed expression grammar. No captured variables, calls,
# interpolation, declarations or arbitrary Raku are evaluated by this compiler.
grammar FilterSyntax {
    token identifier { <[a..z A..Z _]> <[\w \-]>* }
    rule TOP { [ '{' <disjunction> ';'? '}' | <disjunction> ] }
    rule disjunction { <conjunction>+ % '||' }
    rule conjunction { <comparison>+ % '&&' }
    rule comparison { <operand> [ <operator> <operand> ]? }
    token operator { 'eqv' | 'eq' | 'ne' | '==' | '!=' | '<=' | '>=' | '<' | '>' }
    rule operand { [ '!' <operand> | '(' <disjunction> ')' | <receiver> | <field> | <literal> ] }
    token receiver { '$!' <identifier> }
    token field { [ '$' $<variable>=[ <identifier> | '_' ] ]? '.' <identifier> }
    token literal { <number> | <single> | <double> | <boolean> }
    token number { '-'? \d+ [ '.' \d+ ]? }
    token single { "'" $<text>=[ <-['\\]>* ] "'" }
    token double { '"' $<text>=[ <-["\\$@%{]>* ] '"' }
    token boolean { 'True' | 'False' }
}
class FilterActions {
    method TOP($/) { make $<disjunction>.made }
    method disjunction($/) { make ['or', |$<conjunction>».made] }
    method conjunction($/) { make ['and', |$<comparison>».made] }
    method comparison($/) {
        make $<operator> ?? [$<operator>.Str, |$<operand>».made] !! $<operand>[0].made
    }
    method operand($/) {
        make $<operand> ?? ['not', $<operand>.made]
            !! $<disjunction> ?? $<disjunction>.made
            !! $<receiver> ?? $<receiver>.made
            !! $<field> ?? $<field>.made !! $<literal>.made
    }
    method receiver($/) { make ['receiver', $<identifier>.Str] }
    method field($/) { make ['field', $<identifier>.Str, ($<variable> ?? $<variable>.Str !! '')] }
    method literal($/) {
        make ['literal', $<number> ?? +$<number>.Str
            !! $<single> ?? $<single><text>.Str
            !! $<double> ?? $<double><text>.Str !! ($<boolean>.Str eq 'True')]
    }
}

class EventColumn does Red::AST does Red::ColumnMethods is export {
    has Str $.name;
    method args { $!name }
    method returns { $!name eq 'data' ?? Json !! Str }
    method find-column-name { $!name }
}

class ExactEq is Red::AST::Eq is export {
    method not { Red::AST::Not.new(self) }
}

class ReceiverParameter does Red::AST does Red::ColumnMethods is export {
    has Str $.name;
    has Mu $.type;
    has Attribute $.attribute;
    method args { $!name, $!attribute.package.^name }
    method returns { $!type }
    method find-column-name { $!name }
}

# Cursor resolved by the decision read's checkpoint CTE, never a runtime bind.
class SnapshotCursor does Red::AST is export {
    has Int $.position;
    method args { $!position }
    method returns { UInt }
    method find-column-name { }
}

sub shape-nodes($shape) {
    gather {
        take $shape;
        for $shape.list.skip(1).grep(* ~~ Array) -> $child {
            take $_ for shape-nodes($child);
        }
    }
}

sub query-shape(&candidate, @inherited --> Hash) is export {
    # Inherited methods from an already-precompiled module carry their shape on
    # the parent's descriptor; compiler registry mutations do not cross units.
    for @inherited -> $entry {
        return $entry<shape> if $entry<candidate> === &candidate;
    }
    my @parameters = &candidate.signature.params.grep({ !.invocant && !.slurpy });
    return %( reason => 'unsupported event signature' )
        unless @parameters.elems == 1 && @parameters.head.positional;
    my $parameter = @parameters.head;
    return %( reason => 'sub-signature uses runtime binding' ) if $parameter.sub_signature;
    my $constraints := nqp::getattr(nqp::decont($parameter), Parameter, '@!post_constraints');
    return %( expression => ['literal', True] )
        if nqp::isnull($constraints) || !nqp::elems($constraints);
    my @expressions;
    for ^nqp::elems($constraints) -> $i {
        my $source = constraint-source(nqp::atpos($constraints, $i));
        return %( reason => 'constraint source unavailable' ) unless $source.defined;
        my $match = FilterSyntax.parse($source, :actions(FilterActions.new));
        return %( reason => 'expression outside the compiled filter subset' ) unless $match;
        my $shape = $match.made;
        for shape-nodes($shape).grep({ $_[0] eq 'field' }) -> $field {
            return %( reason => 'field receiver is not the event parameter' )
                if $field[2] ne '' && ('$' ~ $field[2]) ne $parameter.name && $field[2] ne '_';
        }
        @expressions.push($shape);
    }
    %( expression => ['and', |@expressions] )
}

sub filter-boolean($value) {
    my $ast = ast-value($value);
    $ast.returns ~~ Bool ?? $ast !! Red::AST::Cast.new($ast, 'boolean')
}

sub shape-expression($shape, $view, %parameters) {
    my $op = $shape[0];
    my @args = $shape.list.skip(1);
    given $op {
        when 'literal' { @args[0] }
        when 'field' { $view{@args[0]} }
        when 'receiver' { %parameters{@args[0]} // die "Unknown receiver attribute {@args[0]}" }
        when 'and' | 'or' {
            my @values = @args.map({ filter-boolean(shape-expression($_, $view, %parameters)) });
            my $result = @values.shift;
            for @values -> $value {
                $result = $op eq 'and' ?? Red::AST::AND.new($result, $value)
                    !! Red::AST::OR.new($result, $value);
            }
            $result
        }
        when 'not' { filter-boolean(shape-expression(@args[0], $view, %parameters)).not }
        default {
            my $left = shape-expression(@args[0], $view, %parameters);
            my $right = shape-expression(@args[1], $view, %parameters);
            my %operators = eqv => Red::AST::Eq, eq => Red::AST::Eq, ne => Red::AST::Ne,
                '==' => Red::AST::Eq, '!=' => Red::AST::Ne,
                '<' => Red::AST::Lt, '>' => Red::AST::Gt, '<=' => Red::AST::Le, '>=' => Red::AST::Ge;
            $op eq 'eqv'
                ?? ExactEq.Mu::new(:left(ast-value($left)), :right(ast-value($right)))
                !! %operators{$op}.new(
                    Red::AST::Cast.new(ast-value($left), $op eq any(<eq ne>) ?? 'str' !! 'num'),
                    Red::AST::Cast.new(ast-value($right), $op eq any(<eq ne>) ?? 'str' !! 'num'))
        }
    }
}

sub compile-query-template(Mu $stored, Mu:U $event, %shape, @attributes) is export {
    return %shape unless %shape<expression>:exists;
    my %fields = $event.^attributes.map({ .name.substr(2) => True });
    for shape-nodes(%shape<expression>).grep({ $_[0] eq 'field' }) -> $node {
        return %( reason => "event accessor {$node[1]} is not a stored attribute" )
            unless %fields{$node[1]}:exists;
    }
    my %parameters;
    for shape-nodes(%shape<expression>).grep({ $_[0] eq 'receiver' }) -> $node {
        my $name = $node[1];
        my @matches = @attributes.grep(*.key eq $name);
        return %( reason => "ambiguous receiver attribute $name" ) unless @matches.elems == 1;
        my $attribute = @matches.head.value;
        %parameters{$name} = ReceiverParameter.new(:$name, :$attribute, :type($attribute.type));
    }
    my $*RED-INTERNAL = True;
    my $view = C.new(:json(EventColumn.new(:name<data>)));
    my $condition = filter-boolean(shape-expression(%shape<expression>, $view, %parameters));
    my $type-filter = ast-value(Any ~~ $event) OR event-type-ast(EventColumn.new(:name<mro>), $event.^name);
    my $ast = $type-filter AND $condition;
    my $frozen = freeze-query-ast($ast);
    %( ast => $frozen, bindings => prepare-query-bindings($frozen),
        parameters => %parameters.values.eager.List )
}

# Compile the clone paths once as well. Runtime binding walks only these paths;
# it never reflects over AST attributes or clones constant-only subtrees.
sub prepare-query-bindings($ast) is export {
    return %(node => $ast, parameter => True)
        if $ast ~~ ReceiverParameter || $ast ~~ EventColumn;
    my %children;
    for $ast.^attributes -> $attribute {
        my $original = $attribute.get_value($ast);
        my $name = $attribute.name.substr(2);
        if $original ~~ Red::AST:D {
            my $child = prepare-query-bindings($original);
            %children{$name} = $child if $child<parameter> || $child<children>.elems;
        } elsif $original ~~ Positional {
            my @items = $original.map({ $_ ~~ Red::AST:D
                ?? prepare-query-bindings($_) !! %(node => $_, children => Map.new) });
            %children{$name} = %(items => @items.List)
                if @items.grep({ .<parameter> || .<children>.elems }).elems;
        }
    }
    %(node => $ast, children => %children.Map)
}

sub bind-query-template($plan, &value) is export {
    return ast-value(value($plan<node>)) if $plan<parameter>;
    return $plan<items>.map({ bind-query-template($_, &value) }).Array if $plan<items>:exists;
    return $plan<node> unless $plan<children>.elems;
    my %changes = $plan<children>.map({ .key => bind-query-template(.value, &value) });
    $plan<node>.clone(|%changes)
}

# Execution-local slot. Its value is never serialized or included in the shared
# AST. Unlike Value, optimizers cannot constant-fold it based on one execution.
class QueryBind does Red::AST is export {
    has Int $.index;
    has Mu $.value;
    method args { $!index, $!value.WHAT.^name, $!value.defined }
    method returns { $!value.WHAT }
    method find-column-name { }
}

sub projection-query-filters($stored, $descriptor, $receiver, @values --> Array) is export {
    my $*RED-INTERNAL = True;
    die $descriptor<rule-error> if $descriptor<rule-error>.defined;
    my @filters;
    for $descriptor<rules>.kv -> $i, &bind {
        my $template = $descriptor<templates>[$i];
        if $template<ast>:exists {
            @filters.push(bind-query-template($template<bindings>, -> $parameter {
                if $parameter ~~ EventColumn {
                    $stored."{$parameter.name}"()
                } else {
                    my $value = $parameter.attribute.get_value($receiver);
                    my $slot = QueryBind.new(:index(@values.elems), :$value);
                    @values.push($value);
                    $slot
                }
            }));
        } else {
            @filters.push($stored.event-filter(bind($receiver)));
        }
    }
    @filters
}

sub freeze-query-ast(Mu $value) {
    if $value ~~ Red::AST:D && $value !~~ Red::Column {
        my $base = $value.^mro.first({ !.^name.contains('+{') && .^name.starts-with(any('Red::AST::', 'RedSourcing::QueryTemplate::', 'RedSourcing::EventType::')) });
        return $value unless $base ~~ Mu:U && $base !~~ Nil;
        return $value unless $base.^name.starts-with(any('Red::AST::', 'RedSourcing::QueryTemplate::', 'RedSourcing::EventType::'));
        my %args;
        for $base.^attributes -> $attribute {
            %args{$attribute.name.substr(2)} = freeze-query-ast($attribute.get_value($value));
        }
        return $base.Mu::new(|%args);
    }
    return $value.map({ freeze-query-ast($_) }).Array if $value ~~ Positional;
    $value
}
