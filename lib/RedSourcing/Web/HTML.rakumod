unit module RedSourcing::Web::HTML;

sub escape-html($value --> Str) is export {
    ($value // '').Str.trans(['&', '<', '>', '"', "'"] => ['&amp;', '&lt;', '&gt;', '&quot;', '&#39;'])
}
sub query-value(Str $value --> Str) is export {
    $value.encode('utf-8').list.map({
        (48 <= $_ <= 57 || 65 <= $_ <= 90 || 97 <= $_ <= 122 || $_ == any(45, 46, 95, 126))
            ?? .chr !! '%' ~ .fmt('%02X')
    }).join
}
sub detail-url(Str $view, $name, Str :$prefix = '/monitor' --> Str) is export {
    $prefix ~ '/detail?view=' ~ query-value($view) ~ '&name=' ~ query-value($name.Str)
}
sub name-link($name, Str $href, :$label = $name --> Str) is export {
    '<a class="name-link" href="' ~ escape-html($href) ~ '" title="' ~ escape-html($name)
        ~ '" aria-label="' ~ escape-html($name) ~ '">' ~ escape-html($label) ~ '</a>'
}
sub icon(Str $name --> Str) is export {
    my %paths = (
        home => '<path d="m3 10 9-7 9 7v10H3z"/><path d="M9 20v-7h6v7"/>',
        grid => '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
        people => '<circle cx="9" cy="8" r="3"/><path d="M3 21v-3a6 6 0 0 1 12 0v3M17 5a3 3 0 0 1 0 6M21 21v-3a6 6 0 0 0-4-5"/>',
        money => '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18M7 15h4"/>',
        tool => '<path d="M14 6a5 5 0 0 0-6 6L3 17a3 3 0 0 0 4 4l5-5a5 5 0 0 0 6-6l-4 3-3-3z"/>',
        pulse => '<path d="M2 12h5l3-8 4 16 3-8h5"/>',
        arrow => '<path d="M5 12h14m-5-5 5 5-5 5"/>',
        chat => '<path d="M21 11a8 8 0 0 1-8 8H4l-2 3V11a9 9 0 1 1 19 0Z"/><path d="M7 10h9M7 14h6"/>',
        check => '<path d="m5 12 4 4L19 6"/>',
    );
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
        ~ (%paths{$name} // %paths<grid>) ~ '</svg>'
}
sub pill($text, Str $tone = '' --> Str) is export {
    '<span class="pill ' ~ escape-html($tone) ~ '">' ~ escape-html($text) ~ '</span>'
}
sub layout(Str $title, Str $body, Str :$section = 'overview', Str :$brand = 'Hearth',
           Str :$subtitle = 'Property management', Str :$live-url = '/live',
           Str :$app-url = '/', Str :$monitor-url = 'http://127.0.0.1:3001/monitor',
           Str :$operations-url = '') is export {
    my @links = $brand eq 'Hearth'
        ?? (('overview', '/', 'Overview', 'grid'), ('properties', '/properties', 'Properties', 'home'),
            ('tenants', '/tenants', 'Tenants', 'people'), ('rent', '/rent', 'Rent & payments', 'money'),
            ('repairs', '/repairs', 'Repairs & chat', 'tool'))
        !! (('monitor', $monitor-url, 'All entities', 'grid'),
            ('aggregate', "$monitor-url?kind=aggregate", 'Aggregates', 'home'),
            ('projection', "$monitor-url?kind=projection", 'Projections', 'pulse'),
            ('saga', "$monitor-url?kind=saga", 'Sagas', 'tool'));
    @links.push(('flows', "$monitor-url/flow", 'Flows', 'arrow')) if $brand ne 'Hearth';
    @links.push(('operations', $operations-url, 'Operations', 'arrow'))
        if $brand ne 'Hearth' && $operations-url.chars;
    my $nav = @links.map(-> @l {
        '<a class="nav-link ' ~ ($section eq @l[0] ?? 'active' !! '') ~ '" href="' ~ escape-html(@l[1]) ~ '">'
            ~ icon(@l[3]) ~ '<span>' ~ @l[2] ~ '</span></a>'
    }).join;
    my $other = $brand eq 'Hearth'
        ?? '<a class="nav-link" href="' ~ escape-html($monitor-url) ~ '">' ~ icon('pulse') ~ '<span>RedSourcing console</span>' ~ icon('arrow') ~ '</a>'
        !! ($app-url.chars ?? '<a class="nav-link" href="' ~ escape-html($app-url) ~ '">' ~ icon('home') ~ '<span>Back to application</span>' ~ icon('arrow') ~ '</a>' !! '');
    my $brand-url = $brand eq 'Hearth' ?? $app-url !! $monitor-url;
    my $profile = $brand eq 'Hearth'
        ?? '<span class="avatar">HB</span><div>Hearth Bristol<small>Local demonstration</small></div>'
        !! '<span class="avatar">RS</span><div>RedSourcing<small>'
            ~ ($operations-url.chars ?? 'System console' !! 'Read-only console') ~ '</small></div>';
    '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
        ~ '<title>' ~ escape-html($title) ~ ' · ' ~ escape-html($brand) ~ '</title>'
        ~ '<link rel="stylesheet" href="/assets/app.css"><script defer src="/assets/vendor/htmx-4.0.0.min.js"></script>'
        ~ '<script defer src="/assets/live.js"></script></head><body data-live-url="' ~ escape-html($live-url) ~ '">'
        ~ '<aside class="sidebar"><a class="brand" href="' ~ escape-html($brand-url) ~ '"><span class="brand-symbol">' ~ icon('home') ~ '</span>'
        ~ '<span>' ~ escape-html($brand) ~ '<small>' ~ escape-html($subtitle) ~ '</small></span></a>'
        ~ '<div class="nav-caption">' ~ ($brand eq 'Hearth' ?? 'WORKSPACE' !! 'ENTITY EXPLORER') ~ '</div><nav aria-label="Main">' ~ $nav ~ '</nav>'
        ~ '<div class="sidebar-bottom">' ~ $other ~ '<div class="profile">' ~ $profile ~ '</div></div></aside>'
        ~ '<div class="main-shell"><header class="topbar"><span class="breadcrumb" title="' ~ escape-html($subtitle ~ ' / ' ~ $title) ~ '">' ~ escape-html($subtitle) ~ ' <span>/</span> ' ~ escape-html($title)
        ~ '</span><span class="live-status" role="status"><i></i><span id="connection-state">Connecting</span></span></header>'
        ~ '<main id="workspace">' ~ $body ~ '</main><footer>Built with RedSourcing · Cro · HTMX 4 <span>'
        ~ ($brand eq 'Hearth' ?? 'Persistent local demo' !! 'Journal-backed observability') ~ '</span></footer></div></body></html>'
}
