use RedSourcing;
unit module ProxyQueryDomain;
our $LOCK = Lock.new;
our %CONTEXTS;
our %INITIAL;
class ProxyQueryFact does Event is export { has Str $.id; has Int $.amount }
aggregate ProxyQueryCounter is export {
    has Str $.id is entity-id;
    has Int $.total is query = 0;
    method APPLY(ProxyQueryFact $e) { $!total += $e.amount }
    method add(Int :$amount = 1) is command { self.proxy-query-fact(:$amount); $!total }
}
projection ProxyQueryView is export {
    has Str $.id is entity-id;
    has Int $.total is query = 0;
    has Hash $.details is query = {array => [1,2]};
    method APPLY(ProxyQueryFact $e where { .id eq $!id }) { $!total += $e.amount }
    method origin is query { ((try $*REDSOURCING-SERVICE-CONTEXT).service-id) }
    method typed is query { %(fraction => 1/3, date => DateTime.new('2026-01-01T00:00:00Z')) }
    method cross(Str $target) is query { ProxyQueryCounter.^with-ids(:id($target)).total }
    method bad is query {
        my $ctx = try $*REDSOURCING-SERVICE-CONTEXT;
        $ctx.command(ProxyQueryCounter.^with-ids(:id<target>), 'add')
    }
    method serve(ServiceContext $context) is service {
        my $proxy = self.WHAT.^with-ids(:$!id);
        start {
            $LOCK.protect({ %CONTEXTS{$context.service-id} = $context });
            my $initial = $proxy.total;
            $LOCK.protect({ %INITIAL{$context.service-id} = $initial });
            $context.ready;
            await $context.stopping;
        }
    }
}
