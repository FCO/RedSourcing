use Cro::HTTP::Router;
use RedSourcing::Web::HTML;
use RedSourcing::Web::Charts;
use RedSourcing::Web::Metrics;
use RedSourcing::Web::Presentation;
use RedSourcing::Web::Flows;
use JSON::Fast;
unit module RedSourcing::Web;

sub web-asset-routes is export {
    my $root = $?FILE.IO.parent.parent.parent.add('resources');
    my %files = <app.css live.js vendor/htmx-4.0.0.min.js>.map({
        # Distribution::Resources supports AT-KEY, not EXISTS-KEY. Resolve its
        # resource at runtime; precompiled paths must remain relocatable.
        my $resource = try %?RESOURCES{$_}.IO;
        $_ => ($resource.defined && $resource.f ?? $resource !! $root.add($_))
    });
    route {
        get -> *@path {
            my $name = @path.join('/');
            if %files{$name}:exists {
                content ($name.ends-with('.css') ?? 'text/css' !! 'application/javascript'),
                    %files{$name}.slurp(:bin);
            }
            else { not-found }
        }
    }
}

sub inspector-view(%report, Str :$kind = '', Str :$prefix = '/monitor', Str :$sort = 'events',
                   Bool :$live-refresh = True, Str :$heading = 'Inside the system') is export {
    my @instances = %report<instances>.grep({ !$kind.chars || .<kind> eq $kind });
    my $types = %report<types>.map(-> %t {
        '<div class="type-chip">' ~ pill(%t<kind>, %t<kind>) ~ '<span>' ~ name-link(%t<name>, detail-url('type', %t<name>, :$prefix), :label(%t<name>.split('::').tail))
            ~ '</span><small>' ~ escape-html(%t<ids>.join(', ') || 'global') ~ '</small></div>'
    }).join;
    my $cards = @instances.map(-> %i {
        my $data = %i<data> // {};
        my $runtime = $data<saga-state> // {};
        my $status = %i<status> // %i<state-source> // 'loaded';
        my $actions = ($runtime<actions> // []).map(-> %a {
            '<tr><td>' ~ name-link(%a<step>, detail-url('stream', %i<stream>, :$prefix)) ~ '<small title="' ~ escape-html(%a<target> ~ ' → ' ~ %a<method>) ~ '">' ~ escape-html(%a<target>) ~ ' → ' ~ escape-html(%a<method>)
                ~ '</small></td><td>' ~ pill(%a<status>, %a<status>) ~ '</td><td>' ~ escape-html(%a<attempts>)
                ~ ' / ' ~ escape-html(%a<retry><max>) ~ '</td></tr>'
        }).join;
        '<article class="instance"><div class="instance-heading">' ~ pill(%i<kind>, %i<kind>) ~ pill($status, $status)
            ~ '</div><h3>' ~ name-link(%i<type> || %i<stream>, detail-url('stream', %i<stream>, :$prefix), :label(%i<type>.split('::').tail || 'Unclassified stream')) ~ '</h3><code class="stream">' ~ name-link(%i<stream>, detail-url('stream', %i<stream>, :$prefix)) ~ '</code>'
            ~ '<div class="instance-meta"><span>Version <b>' ~ escape-html(%i<version> // '—') ~ '</b></span><span>Source cursor <b>' ~ escape-html(%i<cursor> // '—') ~ '</b></span></div>'
            ~ (%i<error>:exists ?? '<p class="error">' ~ escape-html(%i<error>) ~ '</p>' !! '')
            ~ (%i<state-source>:exists ?? '<p class="state-source">State: ' ~ escape-html(%i<state-source>)
                ~ ' · record #' ~ escape-html(%i<state-event-id> // '—') ~ ' · stream head v'
                ~ escape-html(%i<head-version> // '—') ~ '</p>' !! '')
            ~ (%i<kind> eq 'saga' ?? '<div class="saga-counts"><span>' ~ ($runtime<compensations> // []).elems ~ ' compensations</span><span>'
                ~ ($runtime<timers> // {}).elems ~ ' timeouts</span></div><table class="compact"><thead><tr><th>Action</th><th>State</th><th>Attempts</th></tr></thead><tbody>' ~ $actions ~ '</tbody></table>' !! '')
            ~ '<details><summary>Inspect persisted state</summary><pre>' ~ escape-html(to-json($data)) ~ '</pre></details></article>'
    }).join;
    my $events = %report<events>.map(-> %e {
        '<tr><td class="mono">' ~ name-link('#' ~ %e<id>, detail-url('event', %e<id>, :$prefix)) ~ '</td><td><strong>' ~ name-link(%e<type>, detail-url('event', %e<id>, :$prefix), :label(%e<type>.split('::').tail)) ~ '</strong><small>'
            ~ name-link(%e<stream>, detail-url('stream', %e<stream>, :$prefix)) ~ '</small></td><td>' ~ pill(%e<snapshot> ?? 'snapshot' !! %e<control> ?? 'control' !! 'event')
            ~ '</td><td class="mono">v' ~ %e<version> ~ '</td><td><details><summary>Payload</summary><pre>' ~ escape-html(to-json(%e<data>)) ~ '</pre></details></td></tr>'
    }).join;
    my $commands = %report<commands>.map(-> %c {
        '<tr><td class="mono">' ~ name-link('#' ~ %c<id>, detail-url('command', %c<id>, :$prefix)) ~ '</td><td><strong>' ~ name-link(%c<type>, detail-url('command', %c<id>, :$prefix), :label(%c<type>.split('::').tail)) ~ '</strong><small>' ~ name-link(%c<stream>, detail-url('stream', %c<stream>, :$prefix))
            ~ '</small></td><td>' ~ pill(%c<state>, %c<state>.lc) ~ '</td><td>' ~ %c<tries> ~ '</td><td><details><summary>'
            ~ (%c<error>.chars ?? 'Error & payload' !! 'Payload & result') ~ '</summary><pre>'
            ~ escape-html(to-json(%(data => %c<data>, result => %c<result>, error => %c<error>))) ~ '</pre></details></td></tr>'
    }).join;
    '<section id="monitor-view"' ~ ($live-refresh ?? ' hx-get="' ~ escape-html($prefix ~ '/fragment?sort=' ~ $sort ~ ($kind.chars ?? "&kind=$kind" !! ''))
        ~ '" hx-trigger="redsourcing:update from:body" hx-swap="outerMorph"' !! '') ~ '>'
        ~ '<div class="page-heading"><div><p class="eyebrow">REDSOURCING / OBSERVABILITY</p><h1>' ~ escape-html($heading) ~ '<span class="heading-dot">.</span></h1>'
        ~ '<p class="muted">Durable work and the events connecting it.</p></div><a class="button secondary" href="' ~ escape-html($prefix) ~ '/report">JSON report ' ~ icon('arrow') ~ '</a></div>'
        ~ (%report<stored-only> ?? '<p class="notice">Database-only inspection: aggregate and projection state is the last snapshot, '
            ~ 'not a replay of later events. Saga controls carry full persisted state. Types with no stored records are not discoverable.</p>' !! '')
        ~ (%report<store-error>:exists ?? '<p class="operation-error">' ~ escape-html(%report<store-error>)
            ~ ' <a class="text-link" href="/monitor/operations?operation=init">Initialize tables</a></p>' !! '')
        ~ (%report<metrics>:exists ?? metrics-view(%report<metrics>, :$prefix, :$kind, :$sort) !! '')
        ~ '<div class="metrics"><div><span>Persisted types</span><b>' ~ %report<types>.elems ~ '</b></div><div><span>Visible streams</span><b>' ~ @instances.elems
        ~ '</b></div><div><span>Recent events</span><b>' ~ %report<events>.elems ~ '</b></div><div><span>Recent commands</span><b>' ~ %report<commands>.elems ~ '</b></div></div>'
        ~ '<details class="type-catalog"><summary>Type catalog · IDs and entity kinds</summary><div class="type-list">' ~ $types ~ '</div></details>'
        ~ '<div class="section-heading"><h2>Entities</h2><span class="muted">Read only · no effects during inspection</span></div><div class="instance-grid">'
        ~ ($cards || '<p class="empty">No persisted instances yet.</p>') ~ '</div>'
        ~ '<section class="panel"><div class="panel-heading"><h2>Event journal</h2><span>Newest first · last 60</span></div><div class="table-scroll"><table><thead><tr><th>ID</th><th>Event / stream</th><th>Kind</th><th>Version</th><th>Data</th></tr></thead><tbody>' ~ $events ~ '</tbody></table></div></section>'
        ~ '<section class="panel"><div class="panel-heading"><h2>Commands</h2><span>Failures remain visible</span></div><div class="table-scroll"><table><thead><tr><th>ID</th><th>Command / stream</th><th>State</th><th>Tries</th><th>Data</th></tr></thead><tbody>' ~ $commands ~ '</tbody></table></div></section></section>'
}

# Mount in any Cro app. The host supplies synchronization and a change stream.
sub inspector-routes($inspector, :&synchronize = -> &work { work() },
                     :&report = -> { synchronize({ my %r = $inspector.report;
                         %r<metrics> = store-metrics(:instances(%r<instances>)); %r }) },
                     :&updates!, Str :$prefix = '/monitor', Str :$app-url = '/',
                     Str :$live-url = '/monitor/live', Str :$operations-url = '') is export {
    my sub secure-headers {
        header 'X-Content-Type-Options', 'nosniff';
        header 'Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'";
    }
    my sub detail(Str $view, Str $name) {
        return Nil if report()<store-error>:exists;
        my %related = %(types => [], instances => [], events => [], commands => []);
        my %record;
        given $view {
            when 'stream' | 'type' {
                my %all = report();
                if $view eq 'stream' {
                    my $item = %all<instances>.first(*.<stream> eq $name);
                    return Nil unless $item.defined;
                    %record = $item;
                    %related<instances> = [$item];
                    %related<types> = %all<types>.grep(*.<name> eq $item<type>).Array;
                    %related<events> = synchronize({ $inspector.events(:stream($name)) });
                    %related<commands> = synchronize({ $inspector.commands(:stream($name)) });
                } else {
                    my $type = %all<types>.first(*.<name> eq $name);
                    %record = $type // %(name => $name);
                    %related<types> = $type.defined ?? [$type] !! [];
                    %related<instances> = %all<instances>.grep(*.<type> eq $name).Array;
                    %related<events> = synchronize({ $inspector.events(:type($name)) });
                    %related<commands> = synchronize({ $inspector.commands(:type($name)) });
                    return Nil unless $type.defined || %related<events> || %related<commands>;
                }
                %related<stored-only> = %all<stored-only> // False;
            }
            when 'event' | 'command' {
                return Nil unless $name ~~ /^ <[0..9]>+ $/ && $name.UInt > 0;
                my $item = synchronize({ ($view eq 'event'
                    ?? $inspector.events(:id($name.UInt), :limit(1))
                    !! $inspector.commands(:id($name.UInt), :limit(1))).head });
                return Nil unless $item.defined;
                %record = $item;
            }
            default { return Nil }
        }
        my $title = $view eq any(<event command>) ?? $view.tc ~ ' #' ~ $name ~ ' · ' ~ %record<type> !! $name;
        my $facts = %record.keys.grep(* ne 'data').sort.map(-> $key {
            my $value = %record{$key};
            my $text = $value ~~ Associative | Positional ?? to-json($value) !! ($value // '—').Str;
            my $html = $key eq 'stream' ?? name-link($text, detail-url('stream', $text, :$prefix))
                !! $key eq any(<type entity>) && $text.chars ?? name-link($text, detail-url('type', $text, :$prefix))
                !! $key eq 'state-event-id' ?? name-link('#' ~ $text, detail-url('event', $text, :$prefix))
                !! $value ~~ Associative | Positional ?? value-view($value) !! escape-html($text);
            '<dt>' ~ escape-html($key) ~ '</dt><dd>' ~ $html ~ '</dd>'
        }).join;
        my $url = detail-url($view, $name, :$prefix).subst('/detail?', '/detail-fragment?');
        my $tools = '';
        if $operations-url.chars {
            my @actions = $view eq 'command' ?? <run-command>
                !! $view eq 'stream' ?? (%record<kind> eq 'saga' ?? <saga-status advance resolve-action load snapshot command> !! <load snapshot command>)
                !! $view eq 'type' ?? <describe create> !! <list-events>;
            @actions = @actions.grep(* ne 'command') if (%record<kind> // '') eq 'projection';
            $tools = '<div class="detail-operations" aria-label="Actions for this record">' ~ @actions.map(-> $operation {
                if $operation eq any(<command resolve-action create>) {
                    my $url = $operations-url ~ '/entity?view=' ~ query-value($view) ~ '&name=' ~ query-value($name) ~ '&operation=' ~ $operation;
                    '<a class="button secondary" data-operation="' ~ $operation ~ '" href="' ~ escape-html($url)
                        ~ '" hx-get="' ~ escape-html($url ~ '&fragment=1') ~ '" hx-target="#entity-action" hx-swap="innerHTML">'
                        ~ escape-html(operation-title($operation)) ~ '</a>'
                } else {
                    '<form class="entity-operation-form" hx-post="' ~ escape-html($operations-url ~ '/entity/submit')
                        ~ '" hx-target="#entity-result" hx-swap="innerHTML" hx-headers=\'{"X-RedSourcing-Console":"1"}\'>'
                        ~ '<input type="hidden" name="view" value="' ~ escape-html($view) ~ '">'
                        ~ '<input type="hidden" name="name" value="' ~ escape-html($name) ~ '">'
                        ~ '<input type="hidden" name="operation" value="' ~ $operation ~ '">'
                        ~ '<button class="button secondary" data-operation="' ~ $operation ~ '" type="submit">'
                        ~ escape-html(operation-title($operation)) ~ '</button></form>'
                }
            }).join ~ '</div>';
            $tools ~= '<a class="button secondary flow-shortcut" href="' ~ escape-html($prefix ~ '/flow?stream=' ~ query-value($name))
                ~ '">View flow ' ~ icon('arrow') ~ '</a>' if $view eq 'stream';
        }
        my $heading = '<a class="back-link" href="'
            ~ escape-html($prefix) ~ '">← All entities</a><div class="page-heading"><div><p class="eyebrow">'
            ~ escape-html($view.uc) ~ ' / PERSISTED DETAILS</p><h1 title="' ~ escape-html($title) ~ '">'
            ~ escape-html($title) ~ '</h1></div></div>';
        my $fragment = '<section id="monitor-detail" class="monitor-detail" hx-get="' ~ escape-html($url)
            ~ '" hx-trigger="redsourcing:update from:body" hx-swap="outerMorph"><section class="panel"><div class="panel-heading"><h2>Record details</h2></div>'
            ~ '<div class="panel-body"><dl class="record-facts">' ~ $facts ~ '</dl></div></section>'
            ~ (%record<data>:exists ?? '<section class="panel"><div class="panel-heading"><h2>'
                ~ ($view eq 'stream' ?? %record<state-source> eq 'observed replay' ?? 'Observed identity' !! 'Persisted state' !! 'Payload') ~ '</h2></div><div class="panel-body">'
                ~ ((%record<state-source> // '') eq 'observed replay'
                    ?? '<p class="operation-notice">Tracing recorded this instance’s identity, not its domain state. Use Load current state to reconstruct it.</p>' !! '')
                ~ result-view(%(data => %record<data>))
                ~ '<details class="execution-technical"><summary>Raw JSON</summary><pre>'
                ~ escape-html(to-json(%record<data>)) ~ '</pre></details></div></section>' !! '')
            ~ ($view eq any(<stream type>) ?? inspector-view(%related, :$prefix, :!live-refresh, :heading('Related records')) !! '')
            ~ '</section>';
        my $html = '<div class="monitor-detail">' ~ $heading ~ $tools
            ~ '<div id="entity-action" aria-live="polite"></div><div id="entity-result" aria-live="polite"></div>' ~ $fragment ~ '</div>';
        %(title => $title, :$html, :$fragment)
    }
    my sub render-detail(Str $view, Str $name, Bool :$fragment = False) {
        secure-headers();
        header 'Cache-Control', 'no-store';
        my $page = detail($view, $name);
        unless $page.defined {
            response.status = 404;
            content 'text/html', layout('Record not found', '<p class="empty">No matching persisted record.</p><a class="back-link" href="'
                ~ escape-html($prefix) ~ '">← All entities</a>', :brand<RedSourcing>, :$live-url, :$app-url, :monitor-url($prefix), :$operations-url);
            return;
        }
        content 'text/html', $fragment ?? $page<fragment> !! layout($page<title>, $page<html>,
            :brand<RedSourcing>, :subtitle('System console'), :section<monitor>, :$live-url, :$app-url, :monitor-url($prefix), :$operations-url);
    }
    route {
        get -> 'flow', Str :$stream = '', Str :$focus = '', Str :$internal = '' {
            secure-headers();
            header 'Cache-Control', 'no-store';
            my %all = report();
            my %flow = synchronize({ flow-report(%all, :$stream, :$focus, :internal($internal eq '1')) });
            content 'text/html', layout('Flows', flow-view(%flow, :instances(%all<instances>)),
                :brand<RedSourcing>, :subtitle('System console'), :section<flows>, :$live-url, :$app-url,
                :monitor-url($prefix), :$operations-url);
        }
        get -> 'flow-fragment', Str :$stream = '', Str :$focus = '', Str :$internal = '' {
            secure-headers();
            header 'Cache-Control', 'no-store';
            my %all = report();
            content 'text/html', flow-view(synchronize({ flow-report(%all, :$stream, :$focus, :internal($internal eq '1')) }), :instances(%all<instances>));
        }
        get -> 'detail', Str :$view = '', Str :$name = '' { render-detail($view, $name) }
        get -> 'detail-fragment', Str :$view = '', Str :$name = '' { render-detail($view, $name, :fragment) }
        get -> Str :$kind = '', Str :$sort = 'events' {
            secure-headers();
            content 'text/html', layout('RedSourcing',
                inspector-view(report(), :$kind, :$prefix, :$sort),
                :brand<RedSourcing>, :subtitle('System console'), :section($kind || 'monitor'),
                :$live-url, :$app-url, :monitor-url($prefix), :$operations-url);
        }
        get -> 'fragment', Str :$kind = '', Str :$sort = 'events' {
            secure-headers();
            header 'Cache-Control', 'no-store';
            content 'text/html', inspector-view(report(), :$kind, :$prefix, :$sort);
        }
        get -> 'report' {
            secure-headers();
            header 'Cache-Control', 'no-store';
            content 'application/json', report();
        }
        get -> 'live' {
            secure-headers();
            header 'Cache-Control', 'no-cache'; header 'X-Accel-Buffering', 'no';
            content 'text/event-stream', updates().map(*.encode('utf-8'));
        }
    }
}
