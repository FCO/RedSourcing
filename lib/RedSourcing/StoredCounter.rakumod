use Red;
use RedSourcing::Storage;
unit model RedSourcing::StoredCounter is table<red_sourcing_counter>;

has Str $.key is id;
has Str $.definition is column{ :type<text> } is required;
has UInt $.version is column is rw = 0;

# Cache immutable column metadata instead of rebuilding it for every row/query.
INIT {
    RedSourcing::StoredCounter.HOW does CachedStorageRows;
    RedSourcing::StoredCounter.^cache-storage-columns;
}
