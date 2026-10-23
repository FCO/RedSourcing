use RedSourcing::Storage;
use RedSourcing::EventType;
use Red;
use Red::AST::Value;
use Red::Type::Json;
use RedSourcing::C;
use RedSourcing::Utils;
use RedSourcing::Event;
use RedSourcing::Predicate;
use RedSourcing::Tags;

# Successful resolutions and immutable attribute metadata only. Constructors
# and all payload/metadata instances remain local to each conversion.
my Lock $conversion-lock .= new;
my %conversion-types;
my %conversion-attributes;
sub conversion-type(Str $name) {
    my $cached = $conversion-lock.protect: {
        %conversion-types{$name}:exists ?? [%conversion-types{$name}] !! []
    };
    return $cached[0] if $cached.elems;
    # Loading code can recurse; do not hold the cache lock across require.
    my Mu $type = resolve-class($name);
    $conversion-lock.protect: { %conversion-types{$name} = $type };
    $type
}

model RedSourcing::StoredEvent is table<red_sourcing_event> {
	has UInt     $.id                   is serial;
	has Str      $.class                is column     is required;
	has Str      $.mro                  is column{ :inflate(&mro-string) } is required;
	has Str      $.stream               is unique<sv> is required;
	has UInt     $.version              is unique<sv> is rw;
	has DateTime $.created              is column                 .= now;
	has Json     $.data                 is column;
    has UInt $.command-id is column{ :nullable };
    has Str $.action-id is column{ :nullable };
	has UInt     $.event-schema-version is column is rw            = 0;
	# Projection checkpoints retain the consumed global ID, not their own row ID.
	has UInt     $.replay-cursor        is column{ :nullable };
	has $.stream-history is index{ .stream, .id };
	has $.snapshot-history is index{ .class, .stream, .id };

	multi pair-to-code(Mu:U $event, %values) {
		-> $record {
			[AND] (
				ast-value(Any ~~ $event)
				OR event-type-ast($record.mro, $event.^name)
			),
			|%values.kv.map: -> $k, $v {
                my @matches = tag-sources($event, $k).map({ $record.data{$_} eqv $v });
                @matches.elems == 1 ?? @matches.head !! [OR] @matches
			}
		}
	}

	multi pair-to-code(Mu:U $event, &code) {
		-> $record {
			my $obj = C.new: json => $record.data;
			(
				ast-value(Any ~~ $event)
				OR event-type-ast($record.mro, $event.^name)
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
        my $bounds = self.journal-filter(:$stream, :$from-id, :$through-id, :$after);
        my $filter = @filters ?? (@filters == 1 ?? @filters.head !! [OR] @filters) !! Nil;
        $filter = $filter.DEFINITE ?? Red::AST::AND.new($filter, $bounds) !! $bounds if $bounds.DEFINITE;
        my @rs := self.^all;
        @rs := @rs.where($filter) if $filter.DEFINITE;
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

    # Internal scalar bounds have a fixed AST shape and need no symbolic
    # execution of a Raku callback or repeated ResultSeq filter construction.
    method journal-filter(Str :$stream, Str :$class, UInt :$from-id,
            UInt :$through-id, DateTime :$after, UInt :$id, UInt :$version) {
        my $*RED-INTERNAL = True;
        my @filters;
        @filters.push(self.stream eq $stream) with $stream;
        @filters.push(self.class eq $class) with $class;
        @filters.push(self.id > $from-id) with $from-id;
        @filters.push(self.id <= $through-id) with $through-id;
        @filters.push(self.created > $after) with $after;
        @filters.push(self.id == $id) with $id;
        @filters.push(self.version == $version) with $version;
        return Nil unless @filters;
        my $filter = @filters.shift;
        $filter = Red::AST::AND.new($filter, $_) for @filters;
        $filter
    }

    # Share the compiled predicate between decision replay and conditional append.
    method event-filter(*@rules, Bool :$domain = False) {
        my $*RED-INTERNAL = True;
        my @filters = @rules.map: -> Pair (:$key, :$value) {
            predicate-ast(pair-to-code($key, $value), self)
        };
        my $filter = @filters ?? (@filters == 1 ?? @filters.head !! [OR] @filters)
            !! ast-value(False);
        $domain ?? self.domain-filter($filter) !! $filter
    }

    method domain-filter($filter) {
        my $*RED-INTERNAL = True;
        $filter AND event-type-ast(self.mro, 'Entity').not
            AND event-type-ast(self.mro, 'RedSourcing::Saga::Control').not
    }

	method streams {
		self.^all.classify(*.stream).keys
	}

	multi method COERCE(::?CLASS:D:) {
		self.COERCE: $!class
	}

	multi method COERCE(::?CLASS:D: Str $class) {
		self.COERCE: conversion-type($class)
	}

	multi method COERCE(::?CLASS:D: ::T Mu:U $class --> T) {
		die "Cannot coerce row to $class.^name()" unless $class.^name eq $!class;
		my $event = $class.bless: |$!data.Map, StoredEvent => self;
		# A domain TWEAK can override the role's hook. Journal metadata must
		# still be attached after its BUILD/TWEAK finish successfully.
        if $event ~~ Event {
            my $key = $class.WHICH.Str;
            my $attribute = $conversion-lock.protect: {
                %conversion-attributes{$key} //= $class.^attributes.first(*.name eq '$!StoredEvent')
            };
            $attribute.get_value($event) = self;
        }
		$event
	}
}

# Cache immutable column metadata instead of rebuilding it for every row/query.
INIT {
    RedSourcing::StoredEvent.HOW does CachedStorageRows;
    RedSourcing::StoredEvent.^cache-storage-columns;
}
