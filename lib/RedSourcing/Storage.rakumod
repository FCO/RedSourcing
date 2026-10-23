unit module RedSourcing::Storage;
use Red::DB;
use RedSourcing::EventType;
use RedSourcing::QueryTemplate;
use Red::AST::Value;
use JSON::Fast;
use Red::AST::Insert;
use Red::Type::Json;

# Storage models are flat, fixed schemas. Resolve their columns/inflators once,
# rather than reflecting over every column for every value of every result row.
# Alias/structural projections retain Red's ordinary materialization path.
role CachedStorageRows is export {
    has %!storage-row-columns;
    has @!storage-row-attributes;
    has @!full-row-sources;
    has @!full-row-inflators;

    method create-indexes(\model, |args) {
        callsame;
        my $driver = optimize-storage-driver(get-RED-DB);
        if model.^name eq 'RedSourcing::StoredEvent' && pg-driver($driver) {
            my @type = storage-query($driver, q[SELECT a.atttypid::regtype::text AS native
                FROM pg_attribute a WHERE a.attrelid = 'red_sourcing_event'::regclass
                AND a.attname = 'mro' AND NOT a.attisdropped]);
            die 'PostgreSQL MRO must be text[]; run tools/migrate-pg-mro-array.sql and restart the application'
                unless @type && @type.head<native> eq 'text[]';
            $driver.execute('CREATE INDEX IF NOT EXISTS red_sourcing_event_mro_gin ON '
                ~ $driver.table-name-wrapper(model.^table) ~ ' USING GIN (mro)');
        }
    }

    method cache-storage-columns(\model) {
        for model.^columns -> $attribute {
            $attribute.create-column;
            my $column = $attribute.column;
            @!storage-row-attributes.push($column.attr-name);
            my %descriptor = name => $column.attr-name, type => $column.attr.type,
                inflate => $column.inflate, arity => $column.inflate.count;
            %!storage-row-columns{$column.name} = %descriptor;
            %!storage-row-columns{$column.attr-name} = %descriptor;
            my $source = $column.name;
            my $target = $column.attr-name;
            my $type = $column.attr.type;
            my &inflate = $column.inflate;
            my &column-inflate = &inflate.count > 1
                ?? -> $value { inflate($value, $type) }
                !! -> $value { inflate($value) };
            @!full-row-sources.push($source);
            @!full-row-inflators.push(-> $data, $driver, %values {
                my $value = $data{$source};
                if $value.defined {
                    %values{$target} = $driver.inflate(column-inflate($value), :to($type));
                }
            });
        }
    }

    # Red's generic refresh constructs a structural projection of every column.
    # A full row is cheaper here and has exactly the same fixed storage schema.
    method refresh-storage-row(\model) {
        my $fresh = model.^rs.head;
        return model.^refresh unless $fresh.DEFINITE;
        model.^set-attr($_, $fresh."$_"()) for @!storage-row-attributes;
        model.^clean-up;
        model
    }

    method new-from-data(\model, $data) {
        return callsame unless model.^orig === model && $data ~~ Associative;
        my $driver = get-RED-DB;
        my %values;
        if $data.elems == @!full-row-sources.elems
                && @!full-row-sources.map({ $data{$_}:exists }).all {
            .($data, $driver, %values) for @!full-row-inflators;
            return model.new(|%values);
        }
        return callsame unless $data.keys.map({ %!storage-row-columns{$_}:exists }).all;
        for $data.kv -> $key, $value {
            next unless $value.defined;
            my %column = %!storage-row-columns{$key};
            my $inflated = %column<inflate>($value,
                |(%column<type> if %column<arity> > 1));
            %values{%column<name>} = $driver.inflate($inflated, :to(%column<type>));
        }
        model.new(|%values)
    }
}

# Reuse a RETURNING row without changing the dynamically composed storage HOW.
# The copy plan holds column names only; objects and values stay execution-local.
my Lock $copy-plan-lock .= new;
my %copy-plans;
sub refresh-storage-data($model, Associative $data) is export {
    my $type = $model.WHAT;
    my $names = $copy-plan-lock.protect: {
        %copy-plans{$type.WHICH.Str} //= $type.^columns.map(*.column.attr-name).eager.List
    };
    my $fresh = $type.^new-from-data($data);
    $model.^set-attr($_, $fresh."$_"()) for $names.List;
    $model.^clean-up;
    $model
}

# Keep native cursors scoped even when a statement fails inside a transaction.
sub storage-query($connection, Str $sql, *@binds --> Array) is export {
    my $statement = $connection.prepare($sql);
    LEAVE { try $statement.statement.?finish; try $statement.finish-transaction }
    $statement.execute(|@binds);
    my @rows;
    loop {
        my $row = $statement.row;
        last unless $row ~~ Associative && $row.elems;
        $row<mro> = mro-string($row<mro>) if $row<mro>:exists;
        @rows.push($row);
    }
    @rows
}

sub storage-model-rows(Mu:U $model, Str $sql, *@binds --> Array) is export {
    storage-query(get-RED-DB, $sql, |@binds).map(-> %data {
        my $row = $model.^new-from-data(%data);
        $row.^clean-up;
        $row.^saved-on-db;
        $row
    }).Array
}

sub storage-read-ids(Mu:U $model, *@ids --> Array) is export {
    my $connection = get-RED-DB;
    my $pg = $connection.^mro.map(*.^name).first(* eq 'Red::Driver::Pg').defined;
    my @rows;
    for @ids.map(*.UInt).unique.rotor(128, :partial) -> @chunk {
        my @p = $pg ?? (1..@chunk.elems).map({ '$' ~ $_ }) !! ('?' xx @chunk.elems);
        @rows.append(storage-model-rows($model, 'SELECT * FROM '
            ~ $connection.table-name-wrapper($model.^table) ~ ' WHERE id IN (' ~ @p.join(',') ~ ')', |@chunk));
    }
    @rows
}

# SQLite supports the same INSERT ... RETURNING contract used by Red's Pg
# driver. Restrict it to our storage tables and preserve Red's create hooks,
# model construction and dirty tracking. Stable column order also keeps the
# prepared SQL shape independent of Hash iteration order.
role SQLiteStorageReturning is export {
    multi method translate(Red::AST::Insert $insert, $context?) {
        return callsame unless $insert.into.^name eq any(
            <RedSourcing::StoredEvent RedSourcing::StoredCommand RedSourcing::StoredCounter>);
        my @values = $insert.values.pairs.grep({
            .value.value.defined || (.value.column.DEFINITE
                && .value.column.attr.type ~~ Json && !(.value.value === Json))
        }).sort(*.key);
        my $table = self.table-name-wrapper($insert.into.^table);
        return "INSERT INTO $table DEFAULT VALUES RETURNING *" => [] unless @values;
        my @binds = @values.map({ self.wildcard-value(.value) });
        'INSERT INTO ' ~ $table ~ ' (' ~ @values.map({ self.table-name-wrapper(.key) }).join(',')
            ~ ') VALUES (' ~ ('?' xx @values.elems).join(',') ~ ') RETURNING *' => @binds
    }
}

sub optimize-storage-driver($driver) is export {
    if $driver.^mro.map(*.^name).first(* eq 'Red::Driver::SQLite').defined {
        $driver does SQLiteStorageReturning unless $driver ~~ SQLiteStorageReturning;
    }
    install-read-cache($driver);
    $driver
}

# SQL and bind layouts belong to the driver context. Values and execution
# wrappers do not. Cloned transaction drivers may share immutable SQL entries.
my Lock $read-install-lock .= new;

class ReadArgument {
    has Int $.index;
    has Str $.encoding = '';
}
class ReadSqlCache {
    has Lock $!lock .= new;
    has %!sql;
    has @!order;
    method get(Str $key, &compile) {
        $!lock.protect: {
            if %!sql{$key}:exists {
                @!order = @!order.grep(* ne $key);
                @!order.push($key);
                return %!sql{$key};
            }
            my $result = compile();
            @!order.push($key);
            %!sql{@!order.shift}:delete while @!order > 128;
            %!sql{$key} = $result;
        }
    }
}
role CompiledReads {
    multi method translate(SnapshotCursor $cursor, $context?) {
        '(SELECT CASE WHEN COALESCE(s.version, 0) = r.__rs_cached_version'
            ~ ' AND r.__rs_cached_cursor > COALESCE(s.__rs_cursor, 0)'
            ~ ' THEN r.__rs_cached_cursor ELSE COALESCE(s.__rs_cursor, 0) END'
            ~ ' FROM __rs_decision_requested r LEFT JOIN __rs_decision_snapshots s'
            ~ ' ON s.__rs_position = r.__rs_position WHERE r.__rs_position = '
            ~ $cursor.position ~ ')' => []
    }
    multi method translate(EventTypeMembership $node, $context?) {
        my ($column, @binds) := self.translate($node.column, 'table-dot-column').kv;
        my $literal = $node.name;
        my $placeholder = self.wildcard;
        pg-driver(self)
            ?? ("($column \@> ARRAY[$placeholder]::text[])" => [|@binds, $literal])
            !! ("$column LIKE $placeholder" => [|@binds, '%|' ~ $literal ~ '|%'])
    }
    has ReadSqlCache $!read-cache .= new;
    multi method translate(ExactEq $comparison, $context?) {
        my $field = $comparison.left ~~ Red::AST::JsonItem ?? $comparison.left
            !! $comparison.right ~~ Red::AST::JsonItem ?? $comparison.right !! Nil;
        return callsame unless $field.defined;
        my $argument = $comparison.left === $field ?? $comparison.right !! $comparison.left;
        return callsame unless $argument ~~ QueryBind || $argument ~~ Red::AST::Value;
        my $pg = self.^mro.map(*.^name).first(* eq 'Red::Driver::Pg').defined;
        if $pg {
            my ($left, @lb) := self.translate($field, 'json-value').kv;
            my $right = self.wildcard;
            my $bind = $argument ~~ QueryBind
                ?? ReadArgument.new(:index($argument.index), :encoding<json>)
                !! to-json($argument.value, :!pretty);
            return "($left = ($right)::text::jsonb)" => [|@lb, $bind];
        }
        my ($base, @base-binds) := self.translate($field.left, 'json-source').kv;
        my ($path, @path-binds) := self.sqlite-json-path($field.right).kv;
        my $value = $argument.value;
        if !$value.defined || $value ~~ Str || $value ~~ Bool || $value ~~ Numeric {
            my $kind = !$value.defined ?? "'null'" !! $value ~~ Bool ?? "'true','false'"
                !! $value ~~ Numeric ?? "'integer','real'" !! "'text'";
            my $placeholder = self.wildcard;
            my $bind = $argument ~~ QueryBind ?? ReadArgument.new(:index($argument.index)) !! $value;
            my $operator = $value.defined ?? '=' !! 'IS';
            return "(JSON_TYPE($base, $path) IN ($kind) AND JSON_EXTRACT($base, $path) $operator $placeholder)"
                => [|@base-binds, |@path-binds, |@base-binds, |@path-binds, $bind];
        }
        # JSON_TREE paths preserve array order and ignore object member order;
        # normalize integer/real so equivalent JSON numbers still compare equal.
        my ($left, @lb) := self.translate($field, 'json-value').kv;
        my $right = self.wildcard;
        my $bind = $argument ~~ QueryBind
            ?? ReadArgument.new(:index($argument.index), :encoding<json>) !! to-json($value, :!pretty);
        my $columns = "fullkey, CASE WHEN type IN ('integer','real') THEN 'number' ELSE type END, atom";
        my $l = "SELECT $columns FROM JSON_TREE($left)";
        my $r = "SELECT $columns FROM JSON_TREE($right)";
        "(NOT EXISTS ($l EXCEPT $r) AND NOT EXISTS ($r EXCEPT $l))" => [|@lb, $bind, $bind, |@lb]
    }
    multi method translate(QueryBind $value, $context?) {
        my $pg = self.^mro.map(*.^name).first(* eq 'Red::Driver::Pg').defined;
        my $json = $value.returns ~~ Json;
        my $sql = self.wildcard;
        my $encoding = '';
        if $pg && ($context // '') eq 'json-value' {
            my $type = $json ?? 'jsonb' !! $value.returns ~~ Bool ?? 'boolean'
                !! $value.returns ~~ Numeric ?? 'numeric' !! 'text';
            $sql = "($sql)::$type";
            $encoding = $json ?? 'json' !! $value.returns ~~ Bool ?? 'boolean' !! '';
        } elsif $json {
            $sql = $pg ?? "($sql)::text::jsonb" !! "JSON($sql)";
            $encoding = 'json';
        }
        $sql => [ReadArgument.new(:index($value.index), :$encoding)]
    }
    method read-sql(Str $key, &compile) { $!read-cache.get($key, &compile) }

}

# This cache is on the physical SQLite connection, not on a transaction clone.
# A busy handle is absent from the idle pool and therefore cannot be reused.
role SQLiteReadHandles {
    has Lock $!handle-lock .= new;
    has %!idle-reads;
    has @!idle-order;
    method teardown-connection-state() {
        $!handle-lock.protect: {
            .dispose for %!idle-reads.values;
            %!idle-reads = (); @!idle-order = ();
        }
        callsame
    }
    method acquire-read(Str $sql, &prepare) {
        my $handle = $!handle-lock.protect: {
            @!idle-order = @!idle-order.grep(* ne $sql);
            %!idle-reads{$sql}:delete
        };
        $handle // prepare()
    }
    method release-read(Str $sql, $handle, Bool $success) {
        $handle.finish;
        unless $success { $handle.dispose; return }
        $!handle-lock.protect: {
            if %!idle-reads{$sql}:exists { $handle.dispose; return }
            %!idle-reads{$sql} = $handle;
            @!idle-order.push($sql);
            while @!idle-order > 128 {
                my $old = %!idle-reads{@!idle-order.shift}:delete;
                $old.dispose;
            }
        }
    }
}

sub storage-template-rows(Mu:U $model, Str $key, Red::AST $filter, @values, Bool :$cache = True --> Array) is export {
    my $connection = get-RED-DB;
    my $*RED-INTERNAL = True;
    my &compile = {
        my $query = $model.^all.where($filter).sort(*.id).ast;
        my @translated = $connection.translate($connection.optimize($query));
        die 'Expected one SELECT for a projection replay' unless @translated.elems == 1;
        @translated.head
    };
    cached-storage-query($connection, $key, &compile, @values, :$cache).map(-> %data {
        materialize-storage-row($model, %data)
    }).Array
}

sub materialize-storage-row(Mu:U $model, %data) {
    my $row = $model.^new-from-data(%data);
    $row.^clean-up;
    $row.^saved-on-db;
    $row
}

# Shared SQL/bind cache and physical statement leases, also used by CTE reads.
sub cached-storage-query($connection, Str $key, &compile, @values, Bool :$cache = True --> Array) {
    $read-install-lock.protect: { $connection does CompiledReads unless $connection ~~ CompiledReads };
    my $types = @values.map({ .WHAT.^name ~ ':' ~ .defined.Int }).join('|');
    my $entry = $cache ?? $connection.read-sql($key ~ '|' ~ $types, &compile) !! compile();
    my @binds = $entry.value.map: -> $argument {
        my $value = $argument ~~ ReadArgument ?? @values[$argument.index] !! $argument;
        if $argument ~~ ReadArgument {
            given $argument.encoding {
                when 'json' {  $value = to-json($value, :!pretty) }
                when 'boolean' { $value = $value ?? 'true' !! 'false' }
            }
        }
        $connection.deflate($value)
    };
    $connection.^mro.map(*.^name).first(* eq 'Red::Driver::SQLite').defined
        ?? sqlite-storage-query($connection, $entry.key, @binds, :$cache)
        !! storage-query($connection, $entry.key, |@binds)
}

# Explicit opt-in for trusted statement shapes. Raw binds are deflated exactly
# once; PostgreSQL retains its driver's existing prepared-statement cache.
sub storage-prepared-query($connection, Str $sql, *@binds --> Array) is export {
    return storage-query($connection, $sql, |@binds)
        unless $connection.^mro.map(*.^name).first(* eq 'Red::Driver::SQLite').defined;
    sqlite-storage-query($connection, $sql, @binds.map({ $connection.deflate($_) }).Array)
}

# Existence stays a live database read: only the statement is reusable. In
# particular a negative answer must not survive an append or a rollback.
sub storage-stream-exists($connection, Str $class, Str $stream --> Bool) is export {
    my @binds = pg-driver($connection) ?? < $1 $2 > !! < ? ? >;
    so storage-prepared-query($connection,
        'SELECT id FROM red_sourcing_event WHERE class = ' ~ @binds[0]
        ~ ' AND stream = ' ~ @binds[1] ~ ' LIMIT 1', $class, $stream)
}

sub sqlite-storage-query($connection, Str $sql, @binds, Bool :$cache = True --> Array) {
    my @rows;
    my $attribute = $connection.^attributes.first(*.name eq '$!dbh');
    my $native = $attribute.get_value($connection);
    $read-install-lock.protect: { $native does SQLiteReadHandles unless $native ~~ SQLiteReadHandles };
    my &read = {
        CATCH { default { $connection.map-exception($_).throw } }
        my $success = False;
        my $handle = $cache
            ?? $native.acquire-read($sql, { $connection.prepare($sql).statement })
            !! $connection.prepare($sql).statement;
        LEAVE $native.release-read($sql, $handle, $success && $cache) if $handle.defined;
        $handle.execute(|@binds);
        loop {
            my $row = $handle.row(:hash);
            last unless $row ~~ Associative && $row.elems;
            @rows.push($row);
        }
        $success = True;
    };
    my $guard = $connection.?transaction-guard;
    $guard.defined ?? $guard.protect(&read) !! read();
    @rows
}

sub storage-stream-tail(Mu:U $model, Str $stream, UInt $cursor) is export {
    my $connection = get-RED-DB;
    return Nil unless pg-driver($connection)
        || $connection.^mro.map(*.^name).first(* eq 'Red::Driver::SQLite').defined;
    my &compile = {
        my @p = pg-driver($connection) ?? < $1 $2 > !! < ? ? >;
        'SELECT * FROM ' ~ $connection.table-name-wrapper($model.^table)
            ~ ' WHERE stream = ' ~ @p[0] ~ ' AND id > ' ~ @p[1] ~ ' ORDER BY id'
            => [ReadArgument.new(:index(0)), ReadArgument.new(:index(1))]
    };
    cached-storage-query($connection, 'entity-cache:stream-tail', &compile, [$stream, $cursor])
        .map({ materialize-storage-row($model, $_) }).Array
}

# A cache hit needs checkpoint metadata, not a hydrated snapshot payload.
sub storage-checkpoint-version(Str $class, Str $stream --> UInt) is export {
    my $connection = get-RED-DB;
    my $pg = pg-driver($connection);
    my @p = $pg ?? < $1 $2 > !! < ? ? >;
    my $sql = 'SELECT version FROM red_sourcing_event WHERE class = ' ~ @p[0]
        ~ ' AND stream = ' ~ @p[1] ~ ' ORDER BY id DESC LIMIT 1';
    my @rows = cached-storage-query($connection, 'entity-cache:checkpoint',
        -> { $sql => [ReadArgument.new(:index(0)), ReadArgument.new(:index(1))] }, [$class, $stream]);
    (@rows ?? @rows[0]<version> !! 0).UInt
}

# The checkpoint CTE and fact SELECT share one statement snapshot. Each cursor
# is positional, so repeated types and overlapping predicates keep their tails.
sub storage-decision-rows(Mu:U $model, Str $key, @identities, Red::AST $filter,
        @values, Bool :$cache = True --> Hash) is export {
    my $connection = get-RED-DB;
    my $pg = pg-driver($connection);
    die 'Decision reads require SQLite or PostgreSQL' unless $pg
        || $connection.^mro.map(*.^name).first(* eq 'Red::Driver::SQLite').defined;
    my $*RED-INTERNAL = True;
    my $identity-offset = @values.elems;
    my @all-values = |@values, |@identities.map({ .<type>.^name, .<stream>,
        (.<base><entity>.defined ?? .<base><entity>.^current-id !! 0),
        (.<base><entity>.defined ?? .<base><entity>.^version !! 0) }).flat;
    my &compile = {
        my $query = $model.^all.where($filter).sort(*.id).ast;
        my @translated = $connection.translate($connection.optimize($query));
        die 'Expected one SELECT for a decision replay' unless @translated.elems == 1;
        my $events = @translated.head;
        my @event-binds = $events.value.List;
        my @identity-binds;
        my $table = $connection.table-name-wrapper($model.^table);
        my %names = $model.^columns.map({ .column.attr-name => $connection.table-name-wrapper(.column.name) });
        my &columns = -> $alias, Bool :$snapshot = False {
            $model.^columns.map(-> $attribute {
                my $name = $attribute.column.attr-name;
                my $column = %names{$name};
                # Red aliases SELECT columns to attribute names (command-id),
                # whereas native checkpoint rows use SQL names (command_id).
                my $source = $snapshot ?? $column !! $connection.table-name-wrapper($name);
                $snapshot && $name eq 'mro' && $pg
                    ?? "('|' || array_to_string($alias.$column, '|') || '|') AS $column"
                    !! $snapshot && $pg && $attribute.column.attr.type ~~ Json
                    ?? "CAST($alias.$column AS text) AS $column"
                    !! "$alias.$source AS $column"
            }).join(', ')
        };
        my @requested = @identities.keys.map(-> $i {
            my @p = $pg
                ?? (1..4).map({ '$' ~ (@event-binds.elems + 4*$i + $_) })
                !! ('?' xx 4);
            @identity-binds.append((^4).map({ ReadArgument.new(:index($identity-offset + 4*$i + $_)) }));
            "($i, {@p[0]}, {@p[1]}, CAST({@p[2]} AS BIGINT), CAST({@p[3]} AS BIGINT))"
        });
        my $sql = 'WITH __rs_decision_requested (__rs_position, __rs_class, __rs_stream, __rs_cached_cursor, __rs_cached_version) AS (VALUES '
            ~ @requested.join(', ') ~ '), __rs_decision_snapshots AS ('
            ~ "SELECT r.__rs_position, e.{%names<replay-cursor>} AS __rs_cursor, e.*"
            ~ " FROM __rs_decision_requested r JOIN $table e ON e.{%names<id>} = ("
            ~ "SELECT t.{%names<id>} FROM $table t WHERE t.{%names<class>} = r.__rs_class"
            ~ " AND t.{%names<stream>} = r.__rs_stream ORDER BY t.{%names<id>} DESC LIMIT 1)), "
            ~ '__rs_decision_events AS (' ~ $events.key ~ ') SELECT '
            ~ columns('s', :snapshot) ~ ', 0 AS __rs_phase FROM __rs_decision_snapshots s UNION ALL SELECT '
            ~ columns('e') ~ ', 1 AS __rs_phase FROM __rs_decision_events e ORDER BY __rs_phase, '
            ~ %names<id>;
        # Pg placeholders are numbered independently of textual order. SQLite's
        # anonymous placeholders consume the checkpoint CTE's binds first.
        $sql => ($pg ?? [|@event-binds, |@identity-binds] !! [|@identity-binds, |@event-binds])
    };
    my %snapshots;
    my @events;
    for cached-storage-query($connection, 'combined-' ~ $key, &compile, @all-values, :$cache) -> %data {
        my $phase = %data<__rs_phase>:delete;
        my $row = materialize-storage-row($model, %data);
        $phase == 0 ?? (%snapshots{$row.class}{$row.stream} = $row) !! @events.push($row);
    }
    %( :%snapshots, :@events )
}

sub storage-aggregate-rows(Mu:U $model, Str $class, Str $stream --> Hash) is export {
    my $connection = get-RED-DB;
    return %(unsupported => True) unless pg-driver($connection)
        || $connection.^mro.map(*.^name).first(* eq 'Red::Driver::SQLite').defined;
    my &compile = {
        my $table = $connection.table-name-wrapper($model.^table);
        my %names = $model.^columns.map({ .column.attr-name => $connection.table-name-wrapper(.column.name) });
        my &columns = -> $alias {
            $model.^columns.map(-> $attribute {
                my $name = $attribute.column.attr-name;
                my $column = %names{$name};
                $name eq 'mro' && pg-driver($connection)
                    ?? "('|' || array_to_string($alias.$column, '|') || '|') AS $column"
                    !! "$alias.$column AS $column"
            }).join(', ')
        };
        my @p = pg-driver($connection) ?? < $1 $2 > !! < ? ? >;
        my $sql = "WITH snapshot AS (SELECT * FROM $table WHERE {%names<class>} = {@p[0]}"
            ~ " AND {%names<stream>} = {@p[1]} ORDER BY {%names<id>} DESC LIMIT 1) "
            ~ 'SELECT ' ~ columns('s') ~ ', 0 AS __rs_initial FROM snapshot s UNION ALL SELECT '
            ~ columns('e') ~ ", 1 AS __rs_initial FROM snapshot s CROSS JOIN $table e"
            ~ " WHERE e.{%names<stream>} = s.{%names<stream>}"
            ~ " AND e.{%names<id>} > COALESCE(s.{%names<replay-cursor>}, s.{%names<id>})"
            ~ " ORDER BY __rs_initial, {%names<id>}";
        $sql => [ReadArgument.new(:index(0)), ReadArgument.new(:index(1))]
    };
    my $snapshot;
    my @events;
    for cached-storage-query($connection, 'aggregate-restore:' ~ $model.WHICH.Str,
            &compile, [$class, $stream]) -> %data {
        my $phase = %data<__rs_initial>:delete;
        my $row = materialize-storage-row($model, %data);
        $phase == 0 ?? ($snapshot = $row) !! @events.push($row);
    }
    %( :$snapshot, events => @events )
}

sub install-read-cache($connection) {
    $read-install-lock.protect: { $connection does CompiledReads unless $connection ~~ CompiledReads };
}
