# Decision models and dynamic consistency boundaries

`decision-model` combines projections into a temporary consistency boundary.
Use it inside an aggregate command when a rule depends on events from several
streams. A single event can then update several views without being duplicated.

## A student takes at most 10 classes; a class has at most 30 students

The [complete school example](../examples/school/README.md) has an enrollment
aggregate identified by student and class. Its command uses two projections:

```raku
method enroll is command {
    decision-model(
        StudentClasses.^with-ids(:$!student-id),
        ClassRoster.^with-ids(:$!class-id),
        -> $student, $class {
            die 'Unknown student' unless $student.exists;
            die 'Unknown class' unless $class.exists;
            do if $!active { False } else {
                die 'Student already participates in 10 classes'
                    if $student.class-count >= 10;
                die 'Class already has 30 students'
                    if $class.student-count >= 30;
                self.student-enrolled;
                True
            }
        },
    )
}
```

The projections select the same enrollment fact independently:

```raku
# StudentClasses, identified by student-id:
multi method APPLY(StudentEnrolled $event where {
    .student-id eqv $!student-id
}) { %!classes{$event.class-id} = True }

# ClassRoster, identified by class-id:
multi method APPLY(StudentEnrolled $event where {
    .class-id eqv $!class-id
}) { %!students{$event.student-id} = True }
```

The registration and cancellation handlers are dependencies too. Their queries
are inferred automatically; neither explicit tags nor a second query definition
is needed. A projection with no ID filter creates a broader boundary and may
conflict with more writers.

## Read, decide, append

The function takes one or more projection proxies followed by a block. The block
receives isolated, loaded projection instances in the same order. Its result is
returned unchanged. Instances are isolated even when the declared lifecycle is
`Retained`; changing a decision instance does not publish changes to the cache.

All projections are reconstructed through one global journal position `P`, from
an eligible snapshot plus source events through `P`. Their frozen `APPLY` queries
are combined with OR. Snapshots and saga control records are not source facts.
An empty projection is still protected: a concurrent first matching event
invalidates the decision just as a change to an existing model does.

A nickname boundary can select both sides of a rename directly from the payload:

```raku
projection NickUsage {
    has Str $.nick is entity-id;
    has Bool $.used = False;
    method APPLY(NickChanged $event where {
        .old-nick eqv $!nick || .new-nick eqv $!nick
    }) { $!used = $event.new-nick eq $!nick }
}
```

Here `NickChanged` has `old-nick` and `new-nick` fields. The command supplies
`NickUsage.^with-ids(:nick($desired))` to `decision-model` and checks `.used` before
emitting the rename. Registration and release events should have corresponding
handlers too if the domain models those as separate event types.

Before the first append, the journal acquires its transactional write gate and
checks for matching events after `P`. If one exists, the decision fails with
`RedSourcing::X::OptimisticLockFailed`. Otherwise the gate is held through commit.
Every event emitted by the block participates, including emissions through
other aggregates. Several appends are atomic and do not conflict with themselves.
Nested decisions use savepoints within the same transaction; a failed decision
does not leave a partial batch even if its caller catches the exception.

## Conflicts and retries

Inside a stored command, the existing executor retries the **whole command**,
including aggregate loading and all decision models, up to five attempts.
A retry can discover that a business rule now rejects the request. After the
retry limit, the optimistic conflict propagates and the command remains Pending
for a later worker pass. Nested commands let the transaction owner handle retry.

Called directly, the function opens a transaction and propagates conflicts after
rollback; it does not rerun only the block. Blocks must tolerate command retries.
External effects are not rolled back. Asynchronous commands executed after the
block are separate decisions and do not inherit its boundary.

## Supported predicates and databases

Only the supplied projections are protected. Their `APPLY` selection criteria
must translate to SQL and use their IDs and stable constants, rather than mutable
projection state. Unsupported predicates fail before the decision block runs.
Native attributes are currently unsupported in decision projections; use boxed
types such as `Int`, `Num` and `Str`. Keep query predicates deterministic and
free of external reads or effects, as with ordinary projection replay.

PostgreSQL requires READ COMMITTED isolation and uses the journal's existing
transaction advisory lock. SQLite reserves the write lock before checking; a
stale read snapshot that cannot be promoted to a writer is an optimistic conflict.
The write gate currently serializes appends within a store. Unrelated events do
not invalidate a decision, but this is not a claim of lock-free writing.

The guarantee applies to appends through RedSourcing, not direct ORM inserts or
SQL changes. Administrative payload updates must run with application writers
stopped.

See the [DCB specification](https://dcb.events/specification/) and
[Axoniq's introduction](https://www.axoniq.io/concepts/dynamic-consistency-boundary)
for the conditional-append model.
