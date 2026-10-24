use RedSourcing;
use ServiceDomain;
unit module ProjectionServiceDomain;
projection SharedProjection is export {
    has Str $.room-id is entity-id;
    has @.messages is query;
    method APPLY(ServiceMessage $e where { .room-id eq $!room-id }) { @!messages.push($e.text) }
    method serve(ServiceContext $context) is service {
        start {
            $ServiceDomain::LOCK.protect({ $ServiceDomain::STARTS++; %ServiceDomain::CONTEXTS{$context.service-id} = $context });
            $context.ready;
            await $context.stopping;
        }
    }
}
