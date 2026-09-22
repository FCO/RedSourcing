use Cro::HTTP::Router;
use RedSourcing::Web;
use RedSourcing::Web::HTML;
use Estate::View;
unit module Estate::Routes;

sub estate-routes($app, IO::Path :$assets) is export {
    my sub page(Str $section, Bool :$fragment = False, Str :$repair-id = '') {
        my %model = $app.read-model;
        if $repair-id.chars && !(%model<repairs>{$repair-id}:exists) {
            not-found 'text/html', '<p class="notice error">Repair was not found. <a href="/repairs">Return to repairs</a>.</p>';
            return;
        }
        my @messages = $repair-id.chars ?? $app.chat($repair-id) !! [];
        my $html = view($section, %model, $app.csrf-token, :$repair-id, :@messages);
        content 'text/html', $fragment ?? $html !! layout(
            $section eq 'repair' ?? 'Repair conversation' !! $section.tc,
            $html, :section($section eq 'repair' ?? 'repairs' !! $section));
    }
    route {
        after {
            header 'Cache-Control', 'no-store';
            header 'X-Content-Type-Options', 'nosniff';
            header 'Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'self'";
        }
        get -> { page('overview') }
        get -> Str $section where * eq any(<properties tenants rent repairs>) { page($section) }
        get -> 'repairs', Str $repair-id { page('repair', :$repair-id) }
        get -> 'fragments', Str $section where * eq any(<overview properties tenants rent repairs>) { page($section, :fragment) }
        get -> 'fragments', 'repair', Str $repair-id { page('repair', :fragment, :$repair-id) }
        if $assets.defined {
            get -> 'assets', *@path { static $assets, |@path }
        } else {
            include assets => web-asset-routes;
        }
        get -> 'live' {
            header 'X-Accel-Buffering', 'no';
            content 'text/event-stream', $app.updates.map(*.encode('utf-8'));
        }
        get -> 'health' { content 'application/json', %(ok => !$app.controller-error.chars, controller-error => $app.controller-error) }
        post -> 'actions', Str $action {
            request-body -> %data {
                if (%data<csrf> // '') ne $app.csrf-token {
                    response.status = 403;
                    content 'text/html', '<p class="notice error">This form has expired. Reload the page and try again.</p>';
                } else {
                    try {
                        CATCH {
                            default {
                                response.status = 422;
                                content 'text/html', '<p class="notice error">' ~ escape-html(.message) ~ '</p>';
                            }
                        }
                        $app.execute($action, %data);
                        # Controller owns effects. A request merely commits a command.
                        header 'HX-Trigger', 'redsourcing:update';
                        if request.header('HX-Request') {
                            content 'text/html', '<p class="notice">Saved. Any scheduled work will continue in the background.</p>';
                        } else {
                            redirect '/', :see-other;
                        }
                    }
                }
            }
        }
    }
}
