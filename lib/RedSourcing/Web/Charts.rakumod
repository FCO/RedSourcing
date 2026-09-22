use RedSourcing::Web::HTML;
unit module RedSourcing::Web::Charts;

sub minute-chart(@series, Str $metric, Str $label --> Str) {
    my $peak = @series.map(*.{$metric}).max max 1;
    my $step = 570 / (@series.elems max 1);
    my $bars = @series.kv.map(-> $i, %bin {
        my $height = 112 * %bin{$metric} / $peak;
        '<rect x="' ~ (45 + $i * $step).fmt('%.2f') ~ '" y="' ~ (142 - $height).fmt('%.2f')
            ~ '" width="' ~ ($step * 0.72).fmt('%.2f') ~ '" height="' ~ $height.fmt('%.2f') ~ '"><title>'
            ~ escape-html(%bin<time>) ~ ' · ' ~ %bin{$metric} ~ ' ' ~ escape-html($metric) ~ '</title></rect>'
    }).join;
    '<article class="panel chart-panel"><div class="panel-heading"><h2>' ~ escape-html($label)
        ~ '</h2><span>Peak ' ~ @series.map(*.{$metric}).max ~ '</span></div><svg class="minute-chart ' ~ $metric
        ~ '" viewBox="0 0 640 180" role="img" aria-label="' ~ escape-html($label) ~ '">'
        ~ '<path class="chart-grid" d="M45 30H620M45 86H620M45 142H620"/>'
        ~ '<text x="8" y="34">' ~ $peak ~ '</text><text x="25" y="146">0</text>' ~ $bars
        ~ '<text x="45" y="170">' ~ escape-html(@series.head<time>.substr(11, 5)) ~ ' UTC</text>'
        ~ '<text x="555" y="170">' ~ escape-html(@series.tail<time>.substr(11, 5)) ~ ' UTC</text></svg></article>'
}
sub entity-chart(@entities, Str $metric, Str $label, Str :$prefix = '/monitor' --> Str) {
    my @rows = @entities.sort(-*.{$metric}).head(8).Array;
    my $peak = (@rows.map(*.{$metric}).max // 0) max 1;
    my $height = (40 + @rows.elems * 35) max 85;
    my $bars = @rows.kv.map(-> $i, %entity {
        my $y = 20 + 35 * $i;
        '<a href="' ~ escape-html(detail-url('stream', %entity<stream>, :$prefix)) ~ '" aria-label="' ~ escape-html(%entity<stream>) ~ '"><title>' ~ escape-html(%entity<stream>) ~ '</title><text x="8" y="' ~ ($y + 15) ~ '">' ~ escape-html(%entity<stream>.chars > 35
            ?? %entity<stream>.substr(0,32) ~ '…' !! %entity<stream>) ~ '</text>'
            ~ '<rect x="290" y="' ~ $y ~ '" height="22" rx="3" width="'
            ~ (280 * %entity{$metric} / $peak).fmt('%.2f') ~ '"><title>'
            ~ escape-html(%entity<stream>) ~ ' · ' ~ %entity{$metric} ~ '</title></rect>'
            ~ '<text x="585" y="' ~ ($y + 15) ~ '">' ~ %entity{$metric} ~ '</text></a>'
    }).join;
    '<article class="panel chart-panel"><div class="panel-heading"><h2>' ~ escape-html($label)
        ~ '</h2><span>Top 8 · all time</span></div><svg class="entity-chart ' ~ $metric
        ~ '" viewBox="0 0 640 ' ~ $height ~ '" role="group" aria-label="' ~ escape-html($label)
        ~ '">' ~ $bars ~ '</svg></article>'
}
sub metrics-view(%metrics, Str :$sort = 'events', Str :$prefix = '/monitor', Str :$kind = '' --> Str) is export {
    my %totals = %metrics<totals>;
    my @entities = %metrics<entities>.grep({ !$kind.chars || .<kind> eq $kind }).Array;
    my $by = $sort eq any(<events failures retries snapshots events-since-snapshot>) ?? $sort !! 'events';
    my $rank = $by eq 'failures' ?? 'failure-total' !! $by;
    my $rows = @entities.sort(-*.{$rank}).head(30).map(-> %entity {
        '<tr><td><strong>' ~ name-link(%entity<type> || %entity<stream>, detail-url('stream', %entity<stream>, :$prefix), :label(%entity<type> || 'Unclassified stream')) ~ '</strong><small>'
            ~ name-link(%entity<stream>, detail-url('stream', %entity<stream>, :$prefix)) ~ '</small></td><td>' ~ %entity<events> ~ '</td><td>'
            ~ %entity<failure-total> ~ '<small>' ~ %entity<failures> ~ ' commands · ' ~ %entity<saga-failures>
            ~ ' saga outcomes</small><small>' ~ %entity<failure-percent>.fmt('%.1f') ~ '% of commands</small></td><td>'
            ~ %entity<retries> ~ '</td><td>' ~ %entity<snapshots> ~ '<small>'
            ~ %entity<snapshots-per-minute>.fmt('%.3f') ~ '/min in window</small></td><td>'
            ~ %entity<events-since-snapshot> ~ '</td></tr>'
    }).join;
    my $links = <events failures retries snapshots events-since-snapshot>.map(-> $field {
        '<a class="button secondary metric-sort" href="' ~ escape-html($prefix ~ '?sort=' ~ $field
            ~ ($kind.chars ?? '&kind=' ~ $kind !! '')) ~ '">' ~ escape-html($field.subst('-', ' ', :g).tc) ~ '</a>'
    }).join;
    '<section class="telemetry" aria-label="Store health"><div class="section-heading"><h2>Store health</h2><span class="muted">'
        ~ 'Last ' ~ %metrics<window-minutes> ~ ' minutes · UTC</span></div><div class="metrics telemetry-totals">'
        ~ '<div><span>Events / min</span><b>' ~ %metrics<events-per-minute>.fmt('%.2f') ~ '</b><small>Window average · domain events</small></div>'
        ~ '<div><span>Events / entity</span><b>' ~ %metrics<mean-events-per-entity>.fmt('%.1f') ~ '</b><small>All-time mean · owning streams</small></div>'
        ~ '<div><span>Failed commands</span><b>' ~ %totals<failures> ~ '</b><small>' ~ %totals<saga-failures> ~ ' final saga failures</small></div>'
        ~ '<div><span>Retries</span><b>' ~ %totals<retries> ~ '</b><small>Additional persisted attempts</small></div></div>'
        ~ '<div class="health-backlog">' ~ pill(%totals<pending> ~ ' pending') ~ pill(%totals<processing> ~ ' processing')
        ~ pill(%totals<blocked> ~ ' blocked saga actions', %totals<blocked> ?? 'failed' !! '') ~ '</div><div class="chart-grid-layout">'
        ~ minute-chart(%metrics<series>, 'events', 'Domain events / minute')
        ~ minute-chart(%metrics<series>, 'snapshots', 'Snapshots / minute')
        ~ minute-chart(%metrics<series>, 'retries', 'Saga retries / minute')
        ~ minute-chart(%metrics<series>, 'controls', 'Saga controls / minute')
        ~ entity-chart(@entities, 'events', 'Event volume by entity', :$prefix)
        ~ entity-chart(@entities, 'failure-total', 'Failures by entity', :$prefix) ~ '</div>'
        ~ '<section class="panel"><div class="panel-heading"><h2>Where to look first</h2><span>Top 30 · sorted by '
        ~ escape-html($by) ~ '</span></div><div class="metric-sort-links">' ~ $links ~ '</div><div class="table-scroll"><table><thead><tr>'
        ~ '<th>Entity / stream</th><th>Events</th><th>Failures</th><th>Retries</th><th>Snapshots</th><th>Events since snapshot</th>'
        ~ '</tr></thead><tbody>' ~ ($rows || '<tr><td colspan="6">No persisted streams yet.</td></tr>') ~ '</tbody></table></div>'
        ~ '<p class="metric-note">Events count their emitting stream; projection consumption cannot be inferred without APPLY rules. '
        ~ 'Events since snapshot describes only that stream, not a projection’s cross-stream replay gap. Retry timing comes from saga '
        ~ 'attempt transitions; command counters and snapshot-only history supply totals but no attempt timestamps.</p></section></section>'
}
