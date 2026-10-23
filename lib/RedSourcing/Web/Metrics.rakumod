use RedSourcing;
use Red::DB;
use RedSourcing::Storage;
unit module RedSourcing::Web::Metrics;

# Rebuild from all visible facts, as the flow projection does. A persistent
# global serial-ID cursor could miss a lower-ID transaction committed later.
sub metrics-projection() is export {
    require ::('RedSourcing::Metrics::Projection');
    my $view = ::('RedSourcing::Metrics::Projection::MetricsProjection').^restore-state(
        Nil, :stream<red-sourcing-metrics>);
    $view.^replay;
    # Operational command state has no journal lifecycle events yet. Read only
    # its metric columns; never load command arguments, results or entity types.
    my $column = StoredCommand.^columns.first(*.name eq '$!state').column;
    for storage-query(get-RED-DB,
            'SELECT id, stream, state, tries FROM red_sourcing_command ORDER BY id') -> %row {
        my $state = %row<state>.defined
            ?? $column.inflate.(%row<state>, $column.attr.type) !! StoredCommand::Pending;
        $view.include-command(:id(%row<id>.UInt), :stream(%row<stream>),
            :state($state.Str), :tries((%row<tries> // 0).UInt));
    }
    $view
}

sub store-metrics(:@instances = [], UInt :$minutes = 60, DateTime :$now = DateTime.now) is export {
    die 'minutes must be between 1 and 1440' unless 1 <= $minutes <= 1440;
    metrics-projection().report(:@instances, :$minutes, :$now)
}
