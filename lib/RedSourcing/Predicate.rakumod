unit module RedSourcing::Predicate;
use Red::AST;
use Red::AST::Infixes;
use Red::AST::Unary;
use Red::AST::Value;
use CX::Red::Bool;

sub boolean-ast(Red::AST $ast --> Red::AST) {
    return $ast.clone(:value(boolean-ast($ast.value))) if $ast ~~ Red::AST::Not || $ast ~~ Red::AST::So;
    return $ast.clone(:left(boolean-ast($ast.left)), :right(boolean-ast($ast.right)))
        if $ast ~~ Red::AST::AND || $ast ~~ Red::AST::OR;
    $ast.returns ~~ Bool ?? $ast !! Red::AST::Cast.new($ast, 'boolean')
}

# Explore only the decisions actually reached on each path. Signature binding
# can short-circuit; a truth table assembled from unrelated paths loses cases.
sub predicate-ast(&predicate, $argument --> Red::AST) is export {
    my $*RED-INTERNAL = True;
    my $*REDSOURCING-PHASE = 'APPLY';
    my @pending = %().item;
    my @accepted;
    my $runs = 0;
    while @pending {
        die 'APPLY predicate exceeds 256 symbolic branches' if ++$runs > 256;
        my %choices{Red::AST} = @pending.shift;
        my %*VALS{Red::AST} = %choices;
        my $accepted;
        {
            CONTROL {
                when CX::Red::Bool {
                    unless %choices{.ast}:exists {
                        my %other{Red::AST} = %choices;
                        %other{.ast} = True;
                        @pending.push(%other.item);
                        %choices{.ast} = False;
                    }
                    %*VALS{.ast} = %choices{.ast};
                    .resume;
                }
            }
            $accepted = so predicate($argument);
        }
        if $accepted {
            my @clauses = %choices.kv.map(-> $ast, $truth {
                # A JSON boolean is still typed Json in Red's AST. PostgreSQL
                # requires an explicit boolean scalar in WHERE/AND/NOT.
                my $boolean = boolean-ast($ast);
                $truth ?? $boolean !! $boolean.not
            });
            my $branch = @clauses ?? @clauses.head !! ast-value(True);
            $branch = Red::AST::AND.new($branch, $_) for @clauses.skip;
            @accepted.push($branch);
        }
    }
    my $result = @accepted ?? @accepted.head !! ast-value(False);
    $result = Red::AST::OR.new($result, $_) for @accepted.skip;
    $result
}
