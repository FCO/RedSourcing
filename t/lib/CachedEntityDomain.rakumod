unit module CachedEntityDomain;
use RedSourcing;
class CacheAdded does Event is export { has Int $.id; has Int $.amount }
aggregate CacheAccount[:2cached, :!auto-snapshot] is export {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    has @.seen;
    method APPLY(CacheAdded $e) { $!amount += $e.amount; @!seen.push($e.amount) }
    method add(Int :$amount!, Bool :$fail = False) is command {
        self.cache-added(:$amount);
        die 'reject' if $fail;
        $!amount
    }
}
aggregate CacheOther[:3cached] is export { has Int $.id is entity-id; method APPLY {} }
aggregate CacheDefault is export { has Int $.id is entity-id; method APPLY {} }
aggregate CacheOff[:!cached] is export { has Int $.id is entity-id; method APPLY {} }
aggregate CacheZero[:0cached] is export { has Int $.id is entity-id; method APPLY {} }
projection CacheTotal[:2cached, :!auto-snapshot] is export {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    method APPLY(CacheAdded $e where { .id == $!id }) is transactional { $!amount += $e.amount }
}
saga CacheSaga[:cached, :!auto-snapshot] is export {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    method APPLY(CacheAdded $e where { .id == $!id }) { $!amount += $e.amount }
    method REACT(CacheAdded $) { die 'replay must be passive' }
}

projection CacheBounded[:cached, :!auto-snapshot] is export {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    method APPLY(CacheAdded $e where { .id == $!id }) { $!amount += $e.amount }
}

class CacheSnapshotFact does Event is export { has Int $.id; has Int $.amount }
aggregate CacheCheckpoint[:1cached, :auto-snapshot{ :100count }] is export {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    method APPLY(CacheSnapshotFact $e) { $!amount += $e.amount }
    method add(Int :$amount!) is command { self.cache-snapshot-fact(:$amount); $!amount }
}
projection CacheCheckpointView[:1cached, :auto-snapshot{ :100count }] is export {
    has Int $.id is entity-id;
    has Int $.amount = 0;
    method APPLY(CacheSnapshotFact $e where { .id == $!id }) { $!amount += $e.amount }
}
saga CacheCheckpointSaga[:1cached, :auto-snapshot{ :100count }] is export {
    has Int $.id is entity-id;
    method APPLY(CacheSnapshotFact $) { }
    method finish { self.^complete }
    method pressure {
        self.set-timeout('second', 3600, finish => \());
        CacheOther.^with-ids(:id(99)).^load;
    }
}
