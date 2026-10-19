use Red;
use Red::AST::Value;
use Red::Type::Json;
use RedSourcing::C;
use RedSourcing::Utils;
use RedSourcing::Event;
use RedSourcing::Predicate;

model RedSourcing::StoredEvent is table<red_sourcing_event> {
	has UInt     $.id                   is serial;
	has Str      $.class                is column     is required;
	has Str      $.mro                  is column     is required;
	has Str      $.stream               is unique<sv> is required;
	has UInt     $.version              is unique<sv> is rw;
	has DateTime $.created              is column                 .= now;
	has Json     $.data                 is column;
	has UInt     $.event-schema-version is column is rw            = 0;
	# Projection checkpoints retain the consumed global ID, not their own row ID.
	has UInt     $.replay-cursor        is column{ :nullable };
	has $.stream-history is index{ .stream, .id };
	has $.snapshot-history is index{ .class, .stream, .id };

	multi pair-to-code(Mu:U $event, %values) {
		-> $record {
			[AND] (
				ast-value(Any ~~ $event)
				OR $record.mro.contains: "|{ $event.^name }|"
			),
			|%values.kv.map: -> $k, $v {
				$record.data{$k} eqv $v
			}
		}
	}

	multi pair-to-code(Mu:U $event, &code) {
		-> $record {
			my $obj = C.new: json => $record.data;
			(
				ast-value(Any ~~ $event)
				OR $record.mro.contains: "|{ $event.^name }|"
			)
				AND ast-value code $obj
		}
	}

	method map-list-events(*@maps, :$data) {
		my &list = -> $data {
			-> |c {
				my @rules = @maps.map: -> Pair (Mu:U :$key, :value(%map)) {
					($key) => %(%map.kv.map: -> $k, $v {
						$k => $v ~~ Callable
							?? $v.($data)
							!! $data ~~ Associative ?? $data{$v} !! $data."$v"()
						}
					)
				}
				self.list-events: @rules, |c
			}
		}
		return list $_ with $data;
		&list
	}

	method list-events(
		UInt     :$from-id is copy,
		UInt     :$through-id,
		Mu:U     :$from-snapshot-of-type = C,
		Str      :$stream,
		DateTime :$after,
			 :@types,
		Bool     :$row,
		*@rules is copy,
		*%_ where { .not },
	) {
		my $*RED-FALLBACK = False;
		@rules ||= @types.map: -> Mu:U $_ { |(($_) => -> $ { True }) }
		unless $from-snapshot-of-type.^isa: C {
			die "from-id and from-snapshot-of-type are incompatible" with $from-id;
			my @states := self.^all.grep(*.class eq $from-snapshot-of-type.^name); # TODO: lock for update
			@states := @states.grep(*.stream eq $stream) with $stream;
			if @states.sort(-*.id).head -> $state {
				$from-id = $state.id - 1;
				@rules.unshift: ($from-snapshot-of-type) => -> $ { True } if @rules
			}
		}
		my %types   = @rules.map: -> Pair (:key($_), :$value) { .^name => $_ }
		# Compile each predicate independently before combining their ASTs. Binder
		# constraints use boolean branches; tracing all rules together can add
		# negated conditions on JSON fields absent from another event type.
		my @filters = @rules.map: -> Pair (:$key, :$value) {
			predicate-ast(pair-to-code($key, $value), self)
		}
		my @rs     := self.^all;
		@rs := @rs.where(@filters == 1 ?? @filters.head !! [OR] @filters) if @filters;
		@rs := @rs.grep: *.id > $_           with $from-id;
		@rs := @rs.grep: *.id <= $_          with $through-id;
		@rs := @rs.grep: *.stream eq $stream with $stream;
		@rs := @rs.grep: *.created > $after  with $after;
		do for @rs.sort(*.id).Seq {
			do if $row {
				$_
			} else {
				my Mu $class = ::(.class);
				do if $class ~~ Failure {
					# A class loaded in another lexical scope may only be in %types.
					$class.so;
					do if %types{.class}:exists {
						.COERCE: %types{.class}
					} else {
						$_
					}
				} else {
					.COERCE: $class
				}
			}
		}
	}

    # Share the compiled predicate between decision replay and conditional append.
    method event-filter(*@rules, Bool :$domain = False) {
        my $*RED-INTERNAL = True;
        my @filters = @rules.map: -> Pair (:$key, :$value) {
            predicate-ast(pair-to-code($key, $value), self)
        };
        my $filter = @filters ?? (@filters == 1 ?? @filters.head !! [OR] @filters)
            !! ast-value(False);
        if $domain {
            $filter = $filter AND self.mro.contains('|Entity|').not
                AND self.mro.contains('|RedSourcing::Saga::Control|').not;
        }
        $filter
    }

	method streams {
		self.^all.classify(*.stream).keys
	}

	multi method COERCE(::?CLASS:D:) {
		self.COERCE: $!class
	}

	multi method COERCE(::?CLASS:D: Str $class) {
		self.COERCE: resolve-class($class)
	}

	multi method COERCE(::?CLASS:D: ::T Mu:U $class --> T) {
		die "Cannot coerce row to $class.^name()" unless $class.^name eq $!class;
		my $event = $class.bless: |$!data.Map, StoredEvent => self;
		# A domain TWEAK can override the role's hook. Journal metadata must
		# still be attached after its BUILD/TWEAK finish successfully.
		$class.^attributes.first(*.name eq '$!StoredEvent').get_value($event) = self
			if $event ~~ Event;
		$event
	}
}
