use Red::AST::JsonItem;

class C {...}

my role JsonMethods {
	method FALLBACK($name) {
		json-view(self{$name})
	}
}

sub json-view($value) {
	given $value {
		when Red::AST::JsonItem { $_ but JsonMethods }
		when Associative        { C.new: :json($_)   }
		default                 { $_                 }
	}
}

class C {
	has $.json;
	method AT-KEY($key)    { json-view($!json{$key}) }
	method FALLBACK($name) { self.AT-KEY: $name      }
}

multi infix:<eqv>(C $a,   $b) is export { $a.json eqv $b      }
multi infix:<eqv>(  $a, C $b) is export { $a      eqv $b.json }
multi infix:<eqv>(C $a, C $b) is export { $a.json eqv $b.json }

