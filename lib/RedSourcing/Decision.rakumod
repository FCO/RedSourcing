unit module RedSourcing::Decision;

use nqp;
use Red;
use Red::AST;
use RedSourcing::StoredEvent;
use RedSourcing::Utils;
use RedSourcing::Context;
use RedSourcing::Journal;
use RedSourcing::X::OptimisticLockFailed;

# Non-identity state must not silently become a constant in a boundary query.
my class DecisionState does Red::AST {
    has Str $.name;
    has Mu $.type;
    method args { () }
    method returns { $!type }
    method find-column-name { $!name }
}

sub decision-filter(Mu:U $type, %ids) {
    my $*RED-FALLBACK = False;
    CATCH { default {
        die "Cannot infer decision-model APPLY query for {$type.^name}; criteria must use IDs and constants, not mutable projection state: {.message}"
    } }
    my $receiver := nqp::create(nqp::decont($type));
    for $type.^attributes -> $attribute {
        my $name = $attribute.name.substr(2);
        die "native attribute $name is unsupported in decision models"
            if $attribute.type.^name eq any(<int num str uint int8 int16 int32 uint8 uint16 uint32 num32>);
        if %ids{$name}:exists {
            $attribute.set_value($receiver, %ids{$name});
        } else {
            my $symbol = DecisionState.new(:$name, :type($attribute.type));
            nqp::bindattr(nqp::decont($receiver), $attribute.package, $attribute.name, nqp::decont($symbol));
        }
    }
    my @rules = rules-from-func($receiver, $type.^find_method('APPLY'));
    my $filter = RedSourcing::StoredEvent.event-filter(|@rules, :domain);
    my @state = $filter.transpose-grep(* ~~ DecisionState);
    die 'predicate depends on mutable projection state: ' ~ @state».name.unique.join(', ')
        if @state;
    # Force translation now: an unsupported predicate must fail before the block.
    RedSourcing::StoredEvent.^all.where($filter).head(1).Seq.elems;
    $filter
}

# Proxies are supplied positionally; the last argument is the decision block.
sub decision-model(*@arguments) is export {
    my $*RED-FALLBACK = False;
    assert-effect-allowed('decision-model');
    die 'decision-model requires projection proxies followed by a block'
        unless @arguments.elems >= 2 && @arguments.tail ~~ Callable;
    my &work = @arguments.pop;
    for @arguments -> $proxy {
        die 'decision-model accepts only projection proxies'
            unless $proxy.HOW.^can('entity-type')
                && $proxy.^entity-type.HOW.^mro.grep(*.^name eq 'Metamodel::RedSourcing::ProjectionHOW');
    }
    journal-connection();
    red-do :transaction, {
        my $connection = journal-connection();
        if $connection.^mro.first(*.^name eq 'Red::Driver::Pg').defined {
            my $isolation = $connection.execute('SHOW transaction_isolation').row.head;
            die 'decision-model requires PostgreSQL READ COMMITTED isolation'
                unless $isolation eq 'read committed';
        }
        my $last = RedSourcing::StoredEvent.^all.sort(-*.id).head;
        my UInt $after = $last.defined ?? $last.id !! 0;
        my @views;
        my @filters;
        for @arguments -> $proxy {
            my Mu $type = $proxy.^entity-type;
            my %ids = $proxy.^ids-map;
            my $stream = $proxy.^stream-name;
            my $filter = decision-filter($type, %ids);
            @filters.push($filter);
            my $snapshot = RedSourcing::StoredEvent.^all.grep({
                .class eq $type.^name && .stream eq $stream
                    && .id <= $after && .replay-cursor <= $after
            }).sort(-*.id).head;
            my $view = $type.^restore-state($snapshot, :$stream, |%ids);
            for RedSourcing::StoredEvent.^all.where($filter)
                    .grep({ .id > $view.^current-id && .id <= $after }).sort(*.id).Seq -> $row {
                apply-event($view, $row.COERCE);
                $view.^record-applied(:at($row.created));
            }
            $view.^current-id = $after;
            @views.push($view);
        }
        my $boundary = @arguments.map(*.^entity-type.^name).join(', ');
        my $filter = @filters.elems == 1 ?? @filters.head !! [OR] @filters;
        my $decision = {
            :$after, validated => False,
            check => -> {
                my $changed = RedSourcing::StoredEvent.^all.where($filter).grep(*.id > $after).head;
                $changed.defined
                    ?? RedSourcing::X::OptimisticLockFailed.new(:$after, :$boundary)
                    !! Nil
            },
        };
        my $state = $connection.journal-state;
        $state<decisions>.push($decision);
        # Savepoint restoration clones entries, so remove by a stable scope ID.
        my $scope = $decision.WHICH.Str;
        $decision<scope> = $scope;
        do {
            LEAVE $state<decisions> = $state<decisions>.grep(*.<scope> ne $scope).Array;
            work(|@views)
        }
    }
}
