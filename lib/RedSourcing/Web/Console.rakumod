use Cro::HTTP::Router;
use RedSourcing::Web::HTML;
use RedSourcing::Web::Presentation;
use JSON::Fast;
unit module RedSourcing::Web::Console;

sub job-view(%job, Str :$prefix = '/monitor/operations' --> Str) is export {
    my $active = %job<state> eq any(<running stopping>);
    my $text = %job<stdout>.trim;
    my $json-start = $text ~~ /^ [ <[\{\[\"0..9\-]> | 'true' | 'false' | 'null' ] /;
    my $parsed = $json-start ?? (try from-json($text)) !! Nil;
    my $output = $parsed.defined ?? result-view($parsed, :operation(%job<operation>))
        !! %job<stdout>.chars ?? '<p class="value-scalar">' ~ escape-html(%job<stdout>) ~ '</p>'
        !! '<p class="empty-value">' ~ ($active ?? 'Working…' !! %job<state> eq 'succeeded'
            ?? 'Completed without output.' !! 'No result was produced.') ~ '</p>';
    # Watching workers emit successive JSON documents. Render each completed pass.
    if !$parsed.defined && %job<operation> eq 'work' && %job<stdout>.chars {
        my @passes = %job<stdout>.lines.map({ try from-json($_) }).grep(*.defined);
        $output = @passes.map({ result-view($_) }).join if @passes;
    }
    my $diagnostic = %job<stderr>.lines.first(*.trim.chars) // '';
    '<section class="panel execution-result" id="execution-' ~ %job<id> ~ '"'
        ~ ($active ?? ' hx-get="' ~ $prefix ~ '/job/' ~ %job<id>
            ~ '" hx-trigger="every 1s" hx-swap="outerMorph"' !! '')
        ~ ' aria-live="polite"><div class="panel-heading"><h2>'
        ~ escape-html(operation-title(%job<operation>)) ~ '</h2>'
        ~ pill(%job<state>, %job<state> eq 'succeeded' ?? 'done' !! %job<state>) ~ '</div>'
        ~ '<div class="panel-body"><p class="muted">Started ' ~ escape-html(%job<started>)
        ~ (%job<ended>.chars ?? ' · finished ' ~ escape-html(%job<ended>) !! '') ~ '</p>'
        ~ (%job<context><name> ?? '<p class="execution-target">' ~ escape-html(%job<context><name>) ~ '</p>' !! '')
        ~ '<div class="execution-output">' ~ $output ~ '</div>'
        ~ ($diagnostic.chars ?? '<div class="execution-errors" role="alert"><strong>'
            ~ (%job<state> eq 'failed' ?? 'Action failed' !! 'Diagnostics') ~ '</strong><p>'
            ~ escape-html($diagnostic) ~ '</p></div>' !! '')
        ~ '<details class="execution-technical"><summary>Technical details · execution #' ~ %job<id> ~ '</summary>'
        ~ '<pre class="execution-argv">red-sourcing ' ~ escape-html(%job<arguments>.map(*.raku).join(' ')) ~ '</pre>'
        ~ '<h3>Raw result</h3><pre>' ~ escape-html(%job<stdout>) ~ '</pre>'
        ~ (%job<stderr>.chars ?? '<h3>Diagnostics</h3><pre>' ~ escape-html(%job<stderr>) ~ '</pre>' !! '') ~ '</details>'
        ~ (%job<truncated> ?? '<p class="operation-notice">Output was truncated at the console limit. Stored records are available in the inspector.</p>' !! '')
        ~ ($active ?? '<form hx-post="' ~ $prefix ~ '/stop/' ~ %job<id>
            ~ '" hx-target="#execution-' ~ %job<id> ~ '" hx-swap="outerMorph" hx-headers=\'{"X-RedSourcing-Console":"1"}\'>'
            ~ '<button class="button secondary" type="submit">Stop execution</button></form>' !! '')
        ~ '</div></section>'
}

sub console-routes($operations, :&report!, :@origins!, :&lookup = -> $view, $name { Nil }, Str :$app-url = '',
                   Str :$prefix = '/monitor/operations', Str :$monitor-url = '/monitor') is export {
    my @catalog = $operations.catalog;
    my %definitions;
    my Lock $definition-lock .= new;
    my sub definition(Str $entity) {
        $definition-lock.protect({ %definitions{$entity} //= $operations.describe($entity) })
    }
    my sub context(Str $view, Str $name) {
        my %r = report();
        my $record = $view eq 'stream' ?? (%r<instances> // []).first(*.<stream> eq $name)
            !! $view eq 'type' ?? (%r<types> // []).first(*.<name> eq $name)
            !! $view eq any(<command event>) ?? lookup($view, $name) !! Nil;
        die 'The selected record is no longer available.' unless $record.defined;
        %($record)
    }
    my sub allowed(%record, Str $view) {
        $view eq 'stream' ?? (%record<kind> eq 'saga'
            ?? <saga-status advance resolve-action load snapshot command> !! <load snapshot command>)
            !! $view eq 'type' ?? <describe create> !! $view eq 'command' ?? <run-command> !! <list-events>
    }
    my sub identity(%record) {
        my %definition = definition(%record<type>);
        my %ids;
        for %definition<ids>.List -> $id {
            die "Identity '$id' is unavailable in persisted state. Load the application with its configured modules."
                unless (%record<identity>{$id}:exists) || (%record<data>{$id}:exists);
            %ids{$id} = %record<identity>{$id}:exists ?? %record<identity>{$id} !! %record<data>{$id};
        }
        to-json(%ids, :!pretty)
    }
    my sub hidden(Str $key, Str $value) {
        '<input type="hidden" name="' ~ escape-html($key) ~ '" value="' ~ escape-html($value) ~ '">'
    }
    my sub context-form(Str $view, Str $name, Str $operation, Str $method, Str $action-id) {
        my %record = context($view, $name);
        die 'This action is unavailable for the selected record.' unless $operation eq any(allowed(%record, $view));
        die 'This action runs directly from the detail page.' unless $operation eq any(<command resolve-action create>);
        my $entity = %record<type> // %record<name>;
        my $base = $prefix ~ '/entity?view=' ~ query-value($view) ~ '&name=' ~ query-value($name) ~ '&operation=' ~ $operation;
        my $fields = '';
        my $note = '';
        if $operation eq 'command' {
            my %def = definition($entity);
            unless $method.chars {
                return '<section class="panel contextual-panel"><div class="panel-heading"><h2>Choose a command</h2></div><div class="panel-body">'
                    ~ '<p class="context-identity">' ~ escape-html($name) ~ '</p><div class="command-choices">'
                    ~ (%def<commands>.elems ?? %def<commands>.map(-> %cmd {
                        my $url = $base ~ '&method=' ~ query-value(%cmd<name>);
                        '<a class="command-choice" href="' ~ escape-html($url) ~ '" hx-get="'
                            ~ escape-html($url ~ '&fragment=1') ~ '" hx-target="#entity-action" hx-swap="innerHTML">'
                            ~ '<strong>' ~ escape-html(%cmd<name>) ~ '</strong><span>'
                            ~ escape-html(%cmd<description> // 'Open command parameters') ~ '</span>' ~ icon('arrow') ~ '</a>'
                    }).join !! '<p class="empty-value">This entity has no commands.</p>') ~ '</div></div></section>';
            }
            my %cmd = %def<commands>.first(*.<name> eq $method) // die 'Unknown entity command';
            $note = '<p class="operation-description">' ~ escape-html(%cmd<description> // 'Send this command to the selected instance.') ~ '</p>';
            $fields = hidden('method', $method) ~ '<div class="operation-fields">'
                ~ %cmd<parameters>.map(-> %param {
                    my $key = %param<aliases>.head // %param<name>.substr(1);
                    my $type = %param<type>;
                    my $required = %param<optional> ?? '' !! ' required';
                    my $input = $type eq 'Bool'
                        ?? '<select name="arg-' ~ escape-html($key) ~ '" id="arg-' ~ escape-html($key) ~ '"' ~ $required
                            ~ '><option value="">Default</option><option value="true">Yes</option><option value="false">No</option></select>'
                        !! $type eq any(<Array Hash List Map Associative Positional>)
                            ?? '<textarea name="arg-' ~ escape-html($key) ~ '" id="arg-' ~ escape-html($key) ~ '" rows="3"' ~ $required ~ '></textarea>'
                            !! '<input name="arg-' ~ escape-html($key) ~ '" id="arg-' ~ escape-html($key) ~ '"' ~ $required ~ '>';
                    '<div class="operation-field"><label for="arg-' ~ escape-html($key) ~ '">' ~ escape-html($key)
                        ~ (%param<optional> ?? '' !! ' <span class="required">required</span>') ~ '</label>' ~ $input
                        ~ '<small>' ~ escape-html($type) ~ (%param<optional> ?? ' · Leave empty to use the default.' !! '') ~ '</small></div>'
                }).join ~ '</div><details class="operation-advanced"><summary>Validation rules</summary><code class="command-signature">'
                ~ escape-html(%cmd<declaration> // %cmd<signature>) ~ '</code></details>';
        } elsif $operation eq 'resolve-action' {
            my @actions = (%record<data><saga-state><actions> // []).grep({ .<status> eq any(<blocked running>) });
            die 'No running or blocked actions need reconciliation.' unless @actions;
            $fields = '<div class="operation-fields"><div class="operation-field"><label for="resolve-id">Action</label><select id="resolve-id" name="action-id" required>'
                ~ @actions.map({ '<option value="' ~ escape-html(.<id>) ~ '"' ~ (.<id> eq $action-id ?? ' selected' !! '') ~ '>'
                    ~ escape-html(.<step> ~ ' · ' ~ .<status> ~ ' · ' ~ .<id>) ~ '</option>' }).join ~ '</select></div>'
                ~ '<div class="operation-field"><label for="resolve-outcome">Confirmed outcome</label><select id="resolve-outcome" name="outcome"><option value="success">Succeeded</option><option value="failure">Failed</option></select></div>'
                ~ '<div class="operation-field"><label for="resolve-result">Confirmed result (JSON)</label><textarea id="resolve-result" name="result" rows="3">{}</textarea></div>'
                ~ '<div class="operation-field"><label for="resolve-error">Failure reason</label><textarea id="resolve-error" name="error" rows="3"></textarea></div></div>';
            $note = '<p class="operation-description">Check the recorded action with its provider before confirming its outcome. This records the result for this saga.</p>';
        } else {
            my %def = definition($entity);
            $fields = '<div class="operation-fields">' ~ %def<ids>.map({
                '<div class="operation-field"><label for="id-' ~ escape-html($_) ~ '">' ~ escape-html($_)
                    ~ '</label><input id="id-' ~ escape-html($_) ~ '" name="id-' ~ escape-html($_) ~ '" required></div>'
            }).join ~ '</div><details class="operation-advanced"><summary>Initial values</summary><label for="initial-values">Initial values (JSON object)</label>'
                ~ '<textarea id="initial-values" name="data" rows="3">{}</textarea></details>';
        }
        '<section class="panel contextual-panel"><div class="panel-heading"><h2>' ~ escape-html($method.chars ?? $method !! operation-title($operation))
            ~ '</h2>' ~ pill(%record<kind> // $view) ~ '</div><div class="panel-body"><p class="context-identity">'
            ~ escape-html($name) ~ '</p>' ~ $note ~ '<form class="entity-operation-form" hx-post="' ~ $prefix ~ '/entity/submit"'
            ~ ' hx-target="#entity-result" hx-swap="innerHTML" hx-headers=\'{"X-RedSourcing-Console":"1"}\'>'
            ~ hidden('view', $view) ~ hidden('name', $name) ~ hidden('operation', $operation) ~ $fields
            ~ '<div class="operation-submit"><button class="button" type="submit">' ~ escape-html(operation-title($operation))
            ~ '</button><span class="muted">Applies to this ' ~ escape-html(%record<kind> // $view) ~ '</span></div></form></div></section>'
    }
    my sub headers() {
        header 'Cache-Control', 'no-store';
        header 'X-Content-Type-Options', 'nosniff';
        header 'Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'";
    }
    my sub authorize() {
        # Browsers cannot send this custom header cross-origin without a CORS
        # preflight. Also pin Origin to the configured server, defeating rebinding.
        my $origin = request.header('Origin') // '';
        (request.header('X-RedSourcing-Console') // '') eq '1'
            && $origin eq any(@origins)
            && (request.header('Sec-Fetch-Site') // '') ne 'cross-site'
    }
    my sub error(Str $message, UInt $code = 400) {
        response.status = $code;
        content 'text/html', '<div class="operation-error" role="alert">' ~ escape-html($message) ~ '</div>';
    }
    my sub field(%field, Str $name, Str $value = '', Bool :$positional = False) {
        my $label = %field<name> eq 'identity' ?? 'Entity IDs (one FIELD=VALUE per line)'
            !! %field<name> eq 'json' ?? 'Output format' !! %field<name>;
        my $required = %field<required> ?? ' required' !! '';
        my $id = 'field-' ~ $name;
        my $input = %field<boolean>
            ?? '<select id="' ~ $id ~ '" name="' ~ $name ~ '">'
                ~ (%field<name> eq 'json'
                    ?? '<option value="false">Readable text</option><option value="true">JSON</option>'
                    !! '<option value="">Default</option><option value="true">Yes</option><option value="false">No</option>') ~ '</select>'
            !! %field<repeated> || %field<name> eq any(<data ids result transformation trans-signature>)
                ?? '<textarea id="' ~ $id ~ '" name="' ~ $name ~ '" rows="'
                    ~ (%field<name> eq 'transformation' ?? 5 !! 3) ~ '"' ~ $required
                    ~ ' spellcheck="false">' ~ escape-html($value) ~ '</textarea>'
                !! '<input id="' ~ $id ~ '" name="' ~ $name ~ '" value="' ~ escape-html($value)
                    ~ '"' ~ $required ~ ($positional && %field<name> eq 'entity' ?? ' list="entity-names"' !! '') ~ '>';
        '<div class="operation-field"><label for="' ~ $id ~ '">' ~ escape-html($label)
            ~ (%field<required> ?? ' <span class="required">required</span>' !! '') ~ '</label>' ~ $input
            ~ '<small>' ~ escape-html(%field<description> // %field<type>)
            ~ (%field<repeated> && %field<name> ne 'identity' ?? ' One value per line.' !! '') ~ '</small></div>'
    }
    my sub history() {
        my @jobs = $operations.jobs;
        '<section id="execution-history" class="panel" hx-get="' ~ $prefix
            ~ '/jobs" hx-trigger="every 2s" hx-swap="outerMorph"><div class="panel-heading"><h2>Execution history</h2>'
            ~ '<span class="muted">This monitor session</span></div><div class="panel-body">'
            ~ (@jobs ?? '<div class="execution-history">' ~ @jobs.map({
                '<a href="' ~ $prefix ~ '?job=' ~ .<id> ~ '"><span>#' ~ .<id> ~ ' '
                    ~ escape-html(.<operation>) ~ '</span>' ~ pill(.<state>) ~ '<time>'
                    ~ escape-html(.<started>) ~ '</time></a>'
            }).join ~ '</div>' !! '<p class="empty">Run an operation to see its result here.</p>') ~ '</div></section>'
    }
    my sub page(Str $operation, Str $entity, Str $ids, Str $method, UInt $command-id, UInt $job) {
        my %definition = $operations.definition($operation);
        my %config = $operations.configuration;
        my $navigation = @catalog.map(-> %group {
            '<div class="operation-group"><h2>' ~ escape-html(%group<group>) ~ '</h2>'
                ~ %group<commands>.map({ '<a href="' ~ $prefix ~ '?operation=' ~ .<name>
                    ~ '" class="' ~ (.<name> eq $operation ?? 'active' !! '') ~ '">'
                    ~ escape-html(.<name> eq 'web-monitor' ?? 'Monitor settings' !! .<name>) ~ '</a>' }).join ~ '</div>'
        }).join;
        my $settings = '<section class="panel"><div class="panel-heading"><h2>Connected store</h2></div><div class="panel-body">'
            ~ '<dl class="record-facts">' ~ %config.keys.sort.map({ '<dt>' ~ escape-html($_) ~ '</dt><dd>'
                ~ escape-html(%config{$_} ~~ Positional ?? %config{$_}.join(', ') !! %config{$_}) ~ '</dd>' }).join
            ~ '</dl><p class="operation-notice">Connection options are fixed at startup. Restart the monitor with -f, -I or -M to change its configuration. Additional imports below apply only to the selected operation.</p></div></section>';
        my %seed = entity => $entity, method => $method, ids => $ids,
            id => $command-id ?? $command-id.Str !! '';
        my @fields = %definition<options>.grep({ .<name> ne any(<file driver database json>) }).List;
        my @advanced = @fields.grep({ .<name> eq any(<includes modules debug ids>) }).List;
        my @main = @fields.grep({ .<name> ne any(<includes modules debug ids>) }).List;
        my $form = $operation eq 'web-monitor' ?? $settings
            !! '<section class="panel operation-panel"><div class="panel-heading"><h2>' ~ escape-html(%definition<usage>)
                ~ '</h2></div><div class="panel-body"><p class="operation-description">' ~ escape-html(%definition<description>)
                ~ '</p><form id="operation-form" hx-post="' ~ $prefix ~ '/submit" hx-target="#operation-result" hx-swap="innerHTML"'
                ~ ' hx-headers=\'{"X-RedSourcing-Console":"1"}\'>'
                ~ '<input type="hidden" name="operation" value="' ~ $operation ~ '">'
                ~ '<div class="operation-fields">' ~ %definition<positionals>.map({
                    field($_, 'p-' ~ .<name>, %seed{.<name>} // '', :positional)
                }).join ~ @main.map({ field($_, 'o-' ~ .<name>, %seed{.<name>} // '') }).join ~ '</div>'
                ~ (@advanced ?? '<details class="operation-advanced"><summary>Advanced options &amp; imports</summary><div class="operation-fields">'
                    ~ @advanced.map({ field($_, 'o-' ~ .<name>, %seed{.<name>} // '') }).join ~ '</div></details>' !! '')
                ~ '<div class="operation-submit"><button class="button" type="submit">Run ' ~ escape-html($operation)
                ~ '</button><span class="muted">' ~ escape-html(%config<driver> ~ ' · ' ~ %config<database>) ~ '</span></div></form>'
                ~ '<details class="operation-examples"><summary>CLI examples</summary><pre>'
                ~ escape-html(%definition<examples>.join("\n")) ~ '</pre></details></div></section>';
        my $result = $job ?? $operations.job($job) !! Nil;
        my %report = report();
        '<div class="page-heading"><div><p class="eyebrow">REDSOURCING / OPERATIONS</p><h1>Work with the journal<span class="heading-dot">.</span></h1>'
            ~ '<p class="muted">Inspect state, execute commands and manage workflows in the connected store.</p></div></div>'
            ~ '<div class="operation-workspace"><nav class="operation-navigation" aria-label="Operations">' ~ $navigation
            ~ '</nav><div class="operation-content"><p class="operation-target" title="' ~ escape-html(%config<database>) ~ '">'
            ~ escape-html(%config<driver>) ~ ' / ' ~ escape-html(%config<database>) ~ '</p>' ~ $form
            ~ '<datalist id="entity-names">' ~ (%report<types> // []).map({ '<option value="' ~ escape-html(.<name>) ~ '">' }).join
            ~ '</datalist><div id="operation-result">' ~ ($result.defined ?? job-view($result, :$prefix) !! '')
            ~ '</div>' ~ history() ~ '</div></div>'
    }
    route {
        get -> 'entity', Str :$view!, Str :$name!, Str :$operation!, Str :$method = '',
               Str :$action-id = '', UInt :$fragment = 0 {
            headers();
            CATCH { default { error(.message, 404) } }
            my $form = context-form($view, $name, $operation, $method, $action-id);
            content 'text/html', $fragment ?? $form !! layout(operation-title($operation),
                '<a class="back-link" href="' ~ escape-html(detail-url($view, $name, :prefix($monitor-url)))
                ~ '">← Back to selected record</a><div id="entity-action">' ~ $form ~ '</div><div id="entity-result"></div>',
                :brand<RedSourcing>, :section<monitor>, :$app-url, :$monitor-url,
                :live-url($monitor-url ~ '/live'), :operations-url($prefix));
        }
        post -> 'entity', 'submit' {
            headers();
            if !authorize() { error('Actions require a same-origin console request.', 403) }
            else { request-body -> %body {
                CATCH { default { error(.message) } }
                for <view name operation> -> $key { die "Missing $key" unless (%body{$key} // '') ~~ Str && %body{$key}.chars }
                my ($view, $name, $operation) = %body<view name operation>;
                my %record = context($view, $name);
                die 'This action is unavailable for the selected record.' unless $operation eq any(allowed(%record, $view));
                my @positionals;
                my %options = json => True;
                my %accepted = view => True, name => True, operation => True;
                my $entity = %record<type> // %record<name>;
                if $view eq 'stream' {
                    if $operation eq 'saga-status' { %options<stream> = $name }
                    else { @positionals.push($entity); %options<ids> = identity(%record) }
                } elsif $view eq 'type' { @positionals.push($entity) }
                elsif $view eq 'command' { @positionals.push($name) }
                else { %options<stream> = %record<stream> }
                if $operation eq 'command' {
                    %accepted<method> = True;
                    my $method = %body<method> // '';
                    die 'Choose a command.' unless $method ~~ Str && $method.chars;
                    my %cmd = definition($entity)<commands>.first(*.<name> eq $method) // die 'Unknown entity command';
                    @positionals.push($method);
                    my %data;
                    for %cmd<parameters>.List -> %param {
                        my $key = %param<aliases>.head // %param<name>.substr(1);
                        my $field = "arg-$key";
                        %accepted{$field} = True;
                        my $input = %body{$field} // '';
                        die "Invalid $key" unless $input ~~ Str;
                        next unless $input.chars;
                        %data{$key} = %param<type> eq any(<Bool Int UInt Rat Num Numeric Real Array Hash List Map Associative Positional>)
                            ?? from-json($input) !! $input;
                    }
                    %options<data> = to-json(%data, :!pretty);
                } elsif $operation eq 'resolve-action' {
                    %accepted{$_} = True for <action-id outcome result error>;
                    my $id = %body<action-id> // '';
                    die 'Select a running or blocked action.' unless $id ~~ Str && (%record<data><saga-state><actions> // [])
                        .first({ .<id> eq $id && .<status> eq any(<blocked running>) }).defined;
                    @positionals.push($id);
                    if %body<outcome> eq 'success' {
                        die 'Result must be JSON text.' unless (%body<result> // '') ~~ Str;
                        from-json(%body<result> // '{}');
                        %options<result> = %body<result> // '{}';
                    } elsif %body<outcome> eq 'failure' {
                        die 'Enter the confirmed failure reason.' unless (%body<error> // '') ~~ Str && %body<error>.chars;
                        %options<error> = %body<error>;
                    } else { die 'Choose the confirmed outcome.' }
                } elsif $operation eq 'create' {
                    my @ids;
                    for definition($entity)<ids>.List -> $id {
                        %accepted{"id-$id"} = True;
                        die "Enter $id" unless (%body{"id-$id"} // '') ~~ Str && %body{"id-$id"}.chars;
                        @ids.push("$id={%body{"id-$id"}}");
                    }
                    %options<identity> = @ids.Array;
                    %accepted<data> = True;
                    die 'Initial values must be a JSON object.' unless (%body<data> // '{}') ~~ Str
                        && from-json(%body<data> // '{}') ~~ Associative;
                    %options<data> = %body<data> // '{}';
                }
                die 'Unexpected action fields.' if %body.keys.first({ !(%accepted{$_}:exists) }).defined;
                my %job = $operations.submit($operation, :@positionals, :%options, :context(%(:$view, :$name)));
                response.status = 202;
                content 'text/html', job-view(%job, :$prefix);
            } }
        }
        get -> Str :$operation = 'command', Str :$entity = '', Str :$ids = '', Str :$method = '',
               UInt :$command-id = 0, UInt :$job = 0 {
            headers();
            CATCH { default { error(.message, 404) } }
            content 'text/html', layout('Operations', page($operation, $entity, $ids, $method, $command-id, $job),
                :brand<RedSourcing>, :subtitle('System console'), :section<operations>, :$app-url,
                :monitor-url($monitor-url), :live-url($monitor-url ~ '/live'), :operations-url($prefix));
        }
        get -> 'catalog' { headers(); content 'application/json', @catalog }
        get -> 'jobs' { headers(); content 'text/html', history() }
        get -> 'job', UInt $id {
            headers();
            my $job = $operations.job($id);
            $job.defined ?? content('text/html', job-view($job, :$prefix)) !! error('Execution not found.', 404);
        }
        post -> 'submit' {
            headers();
            if !authorize() { error('Operations require a same-origin console request.', 403) }
            else { request-body -> %body {
                CATCH { default { error(.message) } }
                my $operation = %body<operation> // die 'Select an operation';
                my %definition = $operations.definition($operation);
                my %allowed = operation => True;
                my @positionals;
                my %options;
                for %definition<positionals>.List -> %param {
                    my $name = 'p-' ~ %param<name>;
                    %allowed{$name} = True;
                    my $value = %body{$name} // '';
                    die "Invalid $name" unless $value ~~ Str;
                    @positionals.push($value) if $value.chars || %param<required>;
                }
                for %definition<options>.grep({ .<name> ne any(<file driver database>) }) -> %param {
                    my $name = 'o-' ~ %param<name>;
                    %allowed{$name} = True;
                    my $value = %body{$name} // '';
                    die "Invalid $name" unless $value ~~ Str;
                    next unless $value.chars;
                    if %param<boolean> {
                        die "Invalid $name" unless $value eq any(<true false>);
                        %options{%param<name>} = $value eq 'true';
                    } elsif %param<repeated> {
                        %options{%param<name>} = $value.lines.grep(*.chars).Array;
                    } else { %options{%param<name>} = $value }
                }
                die 'Unknown form fields' if %body.keys.first({ !(%allowed{$_}:exists) }).defined;
                %options<json> = True if %definition<options>.first(*.<name> eq 'json').defined;
                my %job = $operations.submit($operation, :@positionals, :%options);
                response.status = 202;
                content 'text/html', job-view(%job, :$prefix);
            } }
        }
        post -> 'stop', UInt $id {
            headers();
            CATCH { default { error(.message, 404) } }
            if !authorize() { error('Operations require a same-origin console request.', 403) }
            else { content 'text/html', job-view($operations.stop($id), :$prefix) }
        }
    }
}
