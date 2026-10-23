unit module RedSourcing::Utils;

use nqp;
use RedSourcing::C;

# `use` exposes a unit type in the caller's lexical scope, which may differ
# from the executor's scope. Require its module here to bind that name locally.
# A class inside a module (BankEvents::Transaction) may need the parent module.
sub resolve-class(Str $name --> Mu:U) is export {
	my Mu $type = ::($name);
	return $type unless $type ~~ Failure;
	$type.so;
	my @parts = $name.split('::');
	my $missing;
	while @parts {
		my $module = @parts.join('::');
		{
			CATCH {
				when X::CompUnit::UnsatisfiedDependency {
					.rethrow unless .specification.short-name eq $module;
					$missing = $_;
				}
			}
			require ::($module);
			$type = ::($name);
			return $type unless $type ~~ Failure;
			$type.so;
		}
		@parts.pop;
	}
	$missing.rethrow if $missing;
	die "No class '$name' in its loaded module"
}

# Destructuring binds through Capture. Supply only the fields requested by the
# signature instead of trying to enumerate keys in a JSON SQL expression.
my class SignatureView is C {
	has Signature $.sub-signature;

	method Capture {
		my %args;
		for $!sub-signature.params -> $param {
			my $name = $param.named_names.head;
			my $value = self{$name};
			%args{$name} = $param.sub_signature
				?? SignatureView.new(:json($value), :sub-signature($param.sub_signature))
				!! $value;
		}
		\(|%args)
	}
}

multi sub rules-from-func(&func) is export {
	&func.candidates.map: { signature-to-pair(.signature, Mu, False) }
}

multi sub rules-from-func($invocant, &func) is export {
	&func.candidates.map: { signature-to-pair(.signature, $invocant, True) }
}

sub rules-from-methods($receiver, @names) is export {
    my @rules;
    for @names -> $name {
        my $method = $receiver.^find_method($name);
        @rules.append(rules-from-func($receiver, $method)) if $method.defined;
    }
    @rules
}

sub validate-sub-signature(Signature $signature) {
	for $signature.params -> $param {
		die "Sub-signatures only accept named scalar parameters"
			unless $param.named && !$param.slurpy && $param.sigil eq '$';
		die "Sub-signature aliases are not supported"
			unless $param.named_names.elems == 1;
		die "Sub-signature defaults are not supported"
			if $param.default.defined;
		die "Typed sub-signature parameters are not supported in SQL rules"
			unless $param.type === Any || $param.type === Mu;
		validate-sub-signature($param.sub_signature) if $param.sub_signature;
	}
}

# Keep the method's code context so the binder captures `self` for its where
# blocks. Clone the parameter list and event parameter before changing the type;
# neither the original signature nor its shared Parameter objects may be mutated.
sub query-signature(Signature $original, Int $index --> Signature) {
	my $signature := nqp::clone($original);
	my $params    := nqp::clone(nqp::getattr($signature, Signature, '@!params'));
	my $param     := nqp::clone(nqp::atpos($params, $index));
	nqp::bindattr($param, Parameter, '$!type', C);
	nqp::bindpos($params, $index, $param);
	nqp::bindattr($signature, Signature, '@!params', $params);
	$signature
}

sub signature-to-pair(Signature $original, Mu $invocant, Bool $bound --> Pair()) {
    prepare-rule($original, $bound)($invocant)
}

# Prepare immutable signature metadata once; bind a fresh receiver on every use.
sub prepare-rule(Signature $original, Bool $bound = True) is export {
	my @params = $original.params;
	my @indexes = @params.keys.grep: {
		!@params[$_].invocant && !@params[$_].slurpy
	};
	die "Expected a single positional event parameter"
		unless @indexes.elems == 1 && @params[@indexes.head].positional;
	my $receiver = @params.first(*.invocant);
	die "Method rules require an invocant: rules-from-func(\$instance, &method)"
		if $receiver.defined && !$bound;
	die "A subroutine rule does not accept an invocant" if !$receiver.defined && $bound;

	my $index = @indexes.head;
	my $param = @params[$index];
	my $sub-signature = $param.sub_signature;
	validate-sub-signature($sub-signature) if $sub-signature;
	my $signature = query-signature($original, $index);
	-> Mu $invocant {
		die "The invocant does not match the method's type"
			if $receiver.defined && !($invocant ~~ $receiver.type);
		$param.type => -> $event-view {
			my $view = $sub-signature
				?? SignatureView.new(:json($event-view.json), :$sub-signature)
				!! $event-view;
			$signature.ACCEPTS($receiver.defined ?? \($invocant, $view) !! \($view))
		}
	}
}
