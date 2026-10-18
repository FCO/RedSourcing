unit module RedSourcing::Declaration;

use nqp;
use experimental :rakuast;
use RedSourcing::Lifecycle;

# Reuse the package trait hook so configuration happens before composition.
# The compiler's cursor and declarand may be NQP objects, hence Mu parameters.
my class LifecycleTrait {
    has $.lifecycle;
    method apply(Mu $type) { $type.^lifecycle($!lifecycle) }
}

sub declaration-options($values --> Hash) {
    my %options;
    for $values.List -> $pair {
        die 'Entity declaration parameters must be named' unless $pair ~~ Pair;
        die "Duplicate entity parameter '{$pair.key}'" if %options{$pair.key}:exists;
        %options{$pair.key} = $pair.value;
    }
    %options
}

my class OptionsTrait {
    has %.options;
    method apply(Mu $type) { $type.^lifecycle(|%!options) }
}

my class ASTOptionsTrait is RakuAST::Trait {
    has $.arguments;
    method PRODUCE-IMPLICIT-LOOKUPS() { nqp::list() }
    method IMPL-TRAIT-NAME() { 'entity-options' }
    method apply(Mu $resolver, Mu $context, Mu $target, *%_) {
        $!arguments.to-begin-time($resolver, $context);
        my $values = $target.IMPL-BEGIN-TIME-EVALUATE($!arguments, $resolver, $context);
        $target.compile-time-value.^lifecycle(|declaration-options($values));
        self.mark-applied;
    }
}

my class ASTLifecycleTrait is RakuAST::Trait {
    has $.lifecycle;
    method PRODUCE-IMPLICIT-LOOKUPS() { nqp::list() }
    method IMPL-TRAIT-NAME() { 'entity-lifecycle' }
    method apply(Mu $, Mu $, Mu $target, *%_) {
        $target.compile-time-value.^lifecycle($!lifecycle);
        self.mark-applied;
    }
}

my role DeclarationGrammar {
    rule trait_mod:sym<entity-options> {
        <?{ nqp::isstr(nqp::getlexdyn('$*PKGDECL'))
            && nqp::getlexdyn('$*PKGDECL') eq any(<aggregate projection saga>) }>
        <before '[' \s* ':'> <circumfix>
    }
    rule trait_mod:sym<entity-lifecycle> {
        <?{ nqp::isstr(nqp::getlexdyn('$*PKGDECL'))
            && nqp::getlexdyn('$*PKGDECL') eq any(<aggregate projection saga>) }>
        '[' <identifier> ']'
    }
}

my role DeclarationActions {
    method trait_mod:sym<entity-options>(Mu $/) {
        my Mu $arguments := nqp::atkey($/.hash, 'circumfix').ast;
        if nqp::can(self, 'attach') {
            self.attach($/, ASTOptionsTrait.new(:$arguments));
        } else {
            my Mu $world := nqp::getlexdyn('$*W');
            my $values = $world.create_thunk($/, $arguments)();
            $/.make(OptionsTrait.new(:options(declaration-options($values))));
        }
    }
    method trait_mod:sym<entity-lifecycle>(Mu $/) {
        my $name = nqp::atkey($/.hash, 'identifier').Str;
        my $lifecycle = do given $name {
            when 'Retained' { Retained }
            when 'OnDemand' { OnDemand }
            default { die "Unknown entity lifecycle '$name': expected OnDemand or Retained" }
        };
        if nqp::can(self, 'attach') {
            self.attach($/, ASTLifecycleTrait.new(:$lifecycle));
        } else {
            $/.make(LifecycleTrait.new(:$lifecycle));
        }
    }
}

sub install-entity-declarations() is export {
    # Instrumentation may wrap EXPORT, so find the compiler's importing match
    # rather than relying on a fixed number of caller frames.
    my Mu $frame := nqp::ctxcaller(nqp::ctxcaller(nqp::ctx()));
    my Mu $cursor;
    loop {
        $cursor := nqp::getlexrel($frame, '$/');
        last if nqp::can($cursor, 'refine_slang');
        $frame := nqp::ctxcaller($frame);
        die 'Cannot find the importing Raku parser' if nqp::isnull($frame);
    }
    # Refine the importing cursor itself. Red's operators and EXPORTHOW extend
    # that cursor after EXPORT returns; refining only $*LANG loses our changes.
    $cursor.HOW.mixin($cursor, DeclarationGrammar);
    $cursor.refine_slang('MAIN', DeclarationGrammar, DeclarationActions);
    # Older Rakudo frontends also keep this table outside the cursor's braid.
    my Mu $languages := nqp::getlexdyn('%*LANG');
    if nqp::ishash($languages) {
        nqp::bindkey($languages, 'MAIN', $cursor.WHAT);
        nqp::bindkey($languages, 'MAIN-actions', $cursor.slang_actions('MAIN'));
    }
    $cursor.set_actions($cursor.slang_actions('MAIN'));
}
