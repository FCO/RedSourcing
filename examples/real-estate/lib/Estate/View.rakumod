use RedSourcing::Web::HTML;
unit module Estate::View;

sub money($amount --> Str) { '£' ~ ($amount // 0).Rat.fmt: '%.2f' }
sub short-date($value --> Str) { ($value // '').Str.substr(0, (($value // '').Str.chars min 16)).subst: 'T', ' ' }
sub input(Str $name, Str $label, Str :$type = 'text', Str :$value = '', Str :$extra = '', Bool :$required = True) {
    '<label>' ~ escape-html($label) ~ '<input name="' ~ $name ~ '" type="' ~ $type ~ '" value="' ~ escape-html($value)
        ~ '" ' ~ ($required ?? 'required' !! '') ~ ' ' ~ $extra ~ '></label>'
}
sub select(Str $name, Str $label, @options) {
    '<label>' ~ escape-html($label) ~ '<select name="' ~ $name ~ '" required><option value="">Choose…</option>'
        ~ @options.map(-> @o { '<option value="' ~ escape-html(@o[0]) ~ '">' ~ escape-html(@o[1]) ~ '</option>' }).join ~ '</select></label>'
}
sub hidden(Str $name, $value) { '<input type="hidden" name="' ~ $name ~ '" value="' ~ escape-html($value) ~ '">' }
sub form(Str $action, Str $fields, Str $token, Str $submit, Str :$id = $action,
         Str :$class = 'form-grid', Bool :$reset = True) {
    '<form id="form-' ~ escape-html($id) ~ '" class="' ~ $class ~ '" method="post" action="/actions/' ~ $action
        ~ '" hx-post="/actions/' ~ $action ~ '" hx-target="#feedback" hx-swap="innerHTML" data-reset="' ~ $reset.Str.lc ~ '">'
        ~ hidden('csrf', $token) ~ $fields ~ '<button class="button" type="submit">' ~ escape-html($submit) ~ '</button></form>'
}
sub drawer(Str $label, Str $content, Str :$id) {
    '<details class="drawer" id="drawer-' ~ escape-html($id // $label) ~ '" hx-preserve><summary class="button">+ '
        ~ escape-html($label) ~ '</summary><div class="drawer-body">' ~ $content ~ '</div></details>'
}
sub heading(Str $title, Str $description, Str $action = '') {
    '<div class="page-heading"><div><p class="eyebrow">HEARTH / BRISTOL PORTFOLIO</p><h1>' ~ escape-html($title)
        ~ '<span class="heading-dot">.</span></h1><p class="muted">' ~ escape-html($description) ~ '</p></div>' ~ $action ~ '</div>'
}
sub property-options(%model) { %model<properties>.keys.sort.map({ [$_, %model<properties>{$_}<name>] }).Array }
sub tenant-options(%model) { %model<tenants>.keys.sort.map({ [$_, %model<tenants>{$_}<name>] }).Array }
sub property-name(%model, Str $id) { %model<properties>{$id}<name> // $id }

sub building(UInt $index, Str $name) {
    my @colors = <#c7d9e9 #cfdfd8 #dad5e9 #d2ddea>;
    my $color = @colors[$index % 4];
    '<svg viewBox="0 0 340 160" role="img" aria-label="' ~ escape-html($name) ~ ' architectural illustration">'
        ~ '<rect width="340" height="160" fill="' ~ $color ~ '"/><circle cx="275" cy="35" r="16" fill="#f6f8f1"/>'
        ~ '<path d="M0 145H340" stroke="#9fb5c4"/><rect x="100" y="51" width="140" height="94" fill="#edf2f6"/>'
        ~ '<path d="M87 54 170 17l83 37Z" fill="#42617a"/><path d="M170 17v128" stroke="#c1ced7"/>'
        ~ '<g fill="#769bb5" stroke="#edf2f6" stroke-width="3"><rect x="115" y="70" width="28" height="25"/><rect x="190" y="70" width="28" height="25"/>'
        ~ '<rect x="115" y="108" width="28" height="25"/><rect x="190" y="108" width="28" height="25"/></g>'
        ~ '<rect x="154" y="107" width="27" height="38" fill="#42617a"/><circle cx="174" cy="127" r="2" fill="#d4e5e9"/>'
        ~ '<path d="M65 145v-36" stroke="#6f8b83" stroke-width="5"/><ellipse cx="65" cy="95" rx="24" ry="28" fill="#86a999"/>'
        ~ '<path d="M269 145v-25" stroke="#6f8b83" stroke-width="4"/><ellipse cx="269" cy="110" rx="18" ry="21" fill="#86a999"/></svg>'
}
sub property-cards(%model) {
    %model<properties>.keys.sort.kv.map(-> $index, $id {
        my %p = %model<properties>{$id};
        '<article class="property-card"><div class="property-art">' ~ building($index, %p<name>)
            ~ pill(%p<tenant-id>.chars ?? 'Occupied' !! 'Available', %p<tenant-id>.chars ?? 'done' !! 'available') ~ '</div>'
            ~ '<div class="property-body"><div class="property-type">' ~ escape-html(%p<kind>) ~ ' · ' ~ %p<bedrooms> ~ ' bed</div><h3>'
            ~ escape-html(%p<name>) ~ '</h3><p class="muted">' ~ escape-html(%p<address>) ~ '</p><div class="property-rent"><b>' ~ money(%p<monthly-rent>)
            ~ '</b><span>/ month</span></div><div class="property-tenant">' ~ icon('people') ~ escape-html(%p<tenant-name> || 'Ready for a new tenant') ~ '</div></div></article>'
    }).join
}
sub repair-card(%r, %model) {
    my $tone = %r<status> eq 'paid' ?? 'done' !! %r<priority> eq 'urgent' ?? 'urgent' !! 'pending';
    '<a class="repair-card" href="/repairs/' ~ escape-html(%r<repair-id>) ~ '"><div class="repair-card-top">' ~ pill(%r<status>.subst('-', ' ', :g), $tone)
        ~ (%r<priority> eq 'urgent' ?? '<span class="priority">Urgent</span>' !! '') ~ '</div><h3>' ~ escape-html(%r<title>) ~ '</h3><p class="muted">'
        ~ escape-html(property-name(%model, %r<property-id>)) ~ '</p><div class="repair-card-bottom"><span>' ~ escape-html(%r<contractor> || 'Awaiting contractor')
        ~ '</span>' ~ icon('arrow') ~ '</div></a>'
}
sub rent-table(%model) {
    my $rows = %model<rent>.keys.sort.map(-> $key {
        my %b = %model<rent>{$key};
        my $due = %b<amount>.Rat - %b<paid>.Rat;
        '<tr><td><strong>' ~ escape-html(property-name(%model, %b<property-id>)) ~ '</strong><small>'
            ~ escape-html(%model<tenants>{%b<tenant-id>}<name> // %b<tenant-id>) ~ '</small></td><td class="mono">' ~ escape-html(%b<period>)
            ~ '</td><td class="numeric">' ~ money(%b<amount>) ~ '</td><td class="numeric">' ~ money(%b<paid>) ~ '</td><td class="numeric">' ~ money($due)
            ~ '</td><td>' ~ pill($due == 0 ?? 'Paid' !! %b<paid> > 0 ?? 'Partial' !! 'Awaiting', $due == 0 ?? 'done' !! 'pending') ~ '</td></tr>'
    }).join;
    '<div class="table-scroll"><table><thead><tr><th>Property / tenant</th><th>Month</th><th class="numeric">Charged</th><th class="numeric">Received</th><th class="numeric">Outstanding</th><th>Status</th></tr></thead><tbody>'
        ~ ($rows || '<tr><td colspan="6" class="empty">Charge the first month of rent to start the ledger.</td></tr>') ~ '</tbody></table></div>'
}

sub view(Str $section, %model, Str $token, Str :$repair-id = '', :@messages = []) is export {
    my $content;
    given $section {
        when 'overview' {
            my $occupied = %model<properties>.values.grep(*.<tenant-id>.chars).elems;
            my $charged = [+] %model<rent>.values.map: *.<amount>.Rat;
            my $received = %model<received>.Rat;
            my $due = $charged - $received;
            my @open = %model<repairs>.values.grep({ .<status> ne any(<paid cancelled>) }).sort: *.<repair-id>;
            my $pct = $charged > 0 ?? (($received / $charged * 100).Int min 100) !! 0;
            $content = heading('A little more settled', 'A clear view of your homes, your people and what needs attention.')
                ~ '<div class="metrics"><div><span>Homes in your care</span><b>' ~ %model<properties>.elems ~ '</b><small>' ~ $occupied ~ ' occupied · '
                ~ (%model<properties>.elems - $occupied) ~ ' available</small></div><div><span>Rent received</span><b>' ~ money($received)
                ~ '</b><small>Against recorded rent charges</small></div><div><span>Rent outstanding</span><b>' ~ money($due)
                ~ '</b><small>Includes partial payments</small></div><div><span>Open repairs</span><b>' ~ @open.elems ~ '</b><small>'
                ~ @open.grep(*.<priority> eq 'urgent').elems ~ ' marked urgent</small></div></div>'
                ~ '<div class="overview-columns"><section class="collection-panel"><p class="eyebrow">RENT COLLECTION</p><div class="collection-number">' ~ $pct
                ~ '<span>% received</span></div><div class="progress" role="progressbar" aria-label="Rent collected" aria-valuenow="' ~ $pct
                ~ '" aria-valuemin="0" aria-valuemax="100"><span style="width:' ~ $pct ~ '%"></span></div><div class="collection-caption"><span>' ~ money($received)
                ~ ' received</span><span>' ~ money($charged) ~ ' charged</span></div><a href="/rent" class="text-link">Open rent ledger ' ~ icon('arrow')
                ~ '</a></section><section class="care-note"><span class="care-icon">' ~ icon('chat') ~ '</span><div><p class="eyebrow">KEEP EVERYONE IN THE LOOP</p><h2>A repair is a conversation.</h2>'
                ~ '<p>Tenant messages, contractor updates and payment confirmations stay together, attached to the work.</p><a class="text-link" href="/repairs">Go to repairs ' ~ icon('arrow') ~ '</a></div></section></div>'
                ~ '<div class="section-heading"><h2>The portfolio</h2><a class="text-link" href="/properties">Manage properties ' ~ icon('arrow') ~ '</a></div><div class="property-grid">' ~ property-cards(%model) ~ '</div>'
                ~ '<div class="section-heading"><h2>Needs a little attention</h2><a class="text-link" href="/repairs">All repairs ' ~ icon('arrow') ~ '</a></div><div class="repair-grid">'
                ~ (@open.map({ repair-card($_, %model) }).join || '<p class="empty">All repairs are settled.</p>') ~ '</div>';
        }
        when 'properties' {
            my $fields = input('name', 'Property name') ~ input('address', 'Address')
                ~ select('kind', 'Type', [<Apartment Apartment>, <Townhouse Townhouse>, <Studio Studio>])
                ~ input('bedrooms', 'Bedrooms', :type<number>, :value<1>, :extra('min="0" max="20" step="1"'))
                ~ input('monthly-rent', 'Monthly rent (£)', :type<number>, :extra('min="0.01" step="0.01"'));
            $content = heading('Room to call home', 'Manage properties and their current tenancies.',
                drawer('Add property', form('property', $fields, $token, 'Save property'), :id<property>))
                ~ '<div class="property-grid">' ~ property-cards(%model) ~ '</div>'
                ~ '<section class="panel"><div class="panel-heading"><h2>Start a tenancy</h2><span>One active tenant per property</span></div><div class="panel-body">'
                ~ form('tenancy', select('property-id', 'Property', property-options(%model)) ~ select('tenant-id', 'Tenant', tenant-options(%model)), $token, 'Start tenancy')
                ~ '</div></section><details class="panel"><summary>End a tenancy</summary><div class="panel-body">'
                ~ form('end-tenancy', select('property-id', 'Property', property-options(%model)), $token, 'End tenancy') ~ '</div></details>';
        }
        when 'tenants' {
            my $fields = input('name', 'Full name') ~ input('email', 'Email', :type<email>) ~ input('phone', 'Phone', :type<tel>, :!required);
            my $rows = %model<tenants>.keys.sort.map(-> $id {
                my %t = %model<tenants>{$id};
                my @homes = %model<properties>.values.grep: *.<tenant-id> eq $id;
                '<tr><td><div class="person"><span class="avatar">' ~ escape-html(%t<name>.words.map(*.substr(0,1)).head(2).join)
                    ~ '</span><strong>' ~ escape-html(%t<name>) ~ '</strong></div></td><td>' ~ escape-html(%t<email>) ~ '<small>' ~ escape-html(%t<phone>)
                    ~ '</small></td><td>' ~ escape-html(@homes.map(*.<name>).join(', ') || 'No active tenancy') ~ '</td><td>' ~ pill(@homes ?? 'Resident' !! 'Registered', @homes ?? 'done' !! '') ~ '</td></tr>'
            }).join;
            $content = heading('The people behind the doors', 'Contact details and current homes, in one place.',
                drawer('Add tenant', form('tenant', $fields, $token, 'Save tenant'), :id<tenant>))
                ~ '<section class="panel"><div class="table-scroll"><table><thead><tr><th>Tenant</th><th>Contact</th><th>Home</th><th>Status</th></tr></thead><tbody>'
                ~ ($rows || '<tr><td colspan="4" class="empty">Add your first tenant.</td></tr>') ~ '</tbody></table></div></section>';
        }
        when 'rent' {
            my $charge = form('charge-rent', select('property-id', 'Property', property-options(%model))
                ~ input('period', 'Rent month', :type<month>, :value(Date.today.Str.substr(0,7))), $token, 'Charge rent');
            my $receive = form('receive-rent', select('property-id', 'Property', property-options(%model))
                ~ input('period', 'Rent month', :type<month>, :value(Date.today.Str.substr(0,7)))
                ~ input('amount', 'Received (£)', :type<number>, :extra('min="0.01" step="0.01"'))
                ~ input('reference', 'Bank reference'), $token, 'Record payment');
            $content = heading('Every payment accounted for', 'Charge monthly rent and record full or partial receipts.',
                drawer('Record payment', $receive, :id<receive-rent>))
                ~ '<section class="panel"><div class="panel-heading"><h2>Rent ledger</h2><span>Received ' ~ money(%model<received>) ~ '</span></div>'
                ~ rent-table(%model) ~ '</section><section class="panel"><div class="panel-heading"><h2>Charge a month of rent</h2><span>Uses the current tenancy rent</span></div><div class="panel-body">'
                ~ $charge ~ '</div></section>';
        }
        when 'repairs' {
            my $fields = select('property-id', 'Property', property-options(%model)) ~ input('title', 'What needs fixing?')
                ~ select('priority', 'Priority', [<normal Normal>, <urgent Urgent>])
                ~ '<label class="full">Description<textarea name="description" rows="3"></textarea></label>';
            $content = heading('Care for the details', 'Track the work, talk to the people and settle the contractor.',
                drawer('Request repair', form('repair', $fields, $token, 'Request repair'), :id<repair>))
                ~ '<div class="repair-grid">' ~ (%model<repairs>.keys.sort.map({ repair-card(%model<repairs>{$_}, %model) }).join
                    || '<p class="empty">No repairs yet. Request one when a property needs attention.</p>') ~ '</div>'
                ~ '<details class="panel"><summary>Demo payment controls</summary><div class="panel-body"><p class="muted">Make the next contractor payment fail once. The repair workflow retries it automatically.</p>'
                ~ form('fail-next-payment', '', $token, 'Fail next payment once', :class<inline-form>) ~ '</div></details>';
        }
        when 'repair' {
            my %r = %model<repairs>{$repair-id} // die 'Repair was not found';
            my $actions = '';
            given %r<status> {
                when 'requested' {
                    $actions = form('schedule', hidden('repair-id', $repair-id) ~ input('contractor', 'Contractor')
                        ~ input('estimate', 'Estimate (£)', :type<number>, :extra('min="0.01" step="0.01"')), $token, 'Schedule repair', :id("schedule-$repair-id"));
                }
                when 'scheduled' {
                    $actions = form('finish', hidden('repair-id', $repair-id) ~ input('cost', 'Final cost (£)', :type<number>,
                        :value(%r<estimate>.Str), :extra('min="0.01" step="0.01"')), $token, 'Mark completed', :id("finish-$repair-id"));
                }
                when 'completed' { $actions = form('pay-repair', hidden('repair-id', $repair-id), $token, 'Pay contractor', :class<inline-form>) }
                when 'payment-pending' { $actions = '<p class="muted">The payment workflow is running. This page updates when the provider responds.</p>' }
                when 'payment-reversed' { $actions = '<p class="muted">The payment was reversed and the workflow is closed. Request a new repair to arrange another payment.</p>' }
                when 'paid' { $actions = '<p class="muted">Payment ' ~ escape-html(%r<payment-id>) ~ ' confirmed.</p>'
                    ~ form('compensate', hidden('repair-id', $repair-id), $token, 'Reverse contractor payment', :class<inline-form>) }
            }
            if %r<status> eq any(<requested scheduled>) {
                $actions ~= '<details><summary>Cancel this repair</summary>' ~ form('cancel-repair', hidden('repair-id', $repair-id)
                    ~ input('reason', 'Reason'), $token, 'Cancel repair', :id("cancel-$repair-id")) ~ '</details>';
            }
            my $messages = @messages.map(-> %m {
                '<article class="message ' ~ (%m<notification> ?? 'notification' !! %m<author> eq 'Agency' ?? 'agency' !! '') ~ '"><div class="message-meta"><strong>'
                    ~ escape-html(%m<author>) ~ '</strong><time>' ~ escape-html(short-date(%m<sent-at>)) ~ '</time></div><p>' ~ escape-html(%m<body>) ~ '</p></article>'
            }).join;
            my $message-form = form('message', hidden('repair-id', $repair-id)
                ~ select('author', 'Send as', [<Agency Agency>, <Tenant Tenant>, <Contractor Contractor>])
                ~ '<label class="full">Message<textarea name="body" rows="3" required maxlength="2000" placeholder="Write an update…"></textarea></label>',
                $token, 'Send message', :id("message-$repair-id"), :class<chat-form>);
            $content = '<a class="back-link" href="/repairs">← All repairs</a>' ~ heading(%r<title>, property-name(%model, %r<property-id>))
                ~ '<div class="repair-detail"><section class="panel"><div class="panel-heading"><h2>Work details</h2>' ~ pill(%r<status>, %r<status> eq 'paid' ?? 'done' !! 'pending')
                ~ '</div><div class="panel-body"><p>' ~ escape-html(%r<description>) ~ '</p><dl class="facts"><dt>Priority</dt><dd>' ~ escape-html(%r<priority>)
                ~ '</dd><dt>Contractor</dt><dd>' ~ escape-html(%r<contractor> || 'Not assigned') ~ '</dd><dt>Estimate</dt><dd>' ~ money(%r<estimate>)
                ~ '</dd><dt>Final cost</dt><dd>' ~ money(%r<cost>) ~ '</dd></dl><div class="work-actions">' ~ $actions ~ '</div></div></section>'
                ~ '<section class="panel chat-panel"><div class="panel-heading"><h2>One conversation</h2><span>Tenant · agency · contractor</span></div><div class="messages" id="messages">'
                ~ ($messages || '<p class="empty">Start the conversation. Automatic repair updates will appear here too.</p>')
                ~ '</div><div class="chat-composer" id="composer-' ~ escape-html($repair-id) ~ '" hx-preserve>' ~ $message-form ~ '</div></section></div>';
        }
        default { die 'Page was not found' }
    }
    my $url = '/fragments/' ~ $section ~ ($repair-id.chars ?? "/$repair-id" !! '');
    '<section id="page-view" hx-get="' ~ escape-html($url) ~ '" hx-trigger="redsourcing:update from:body" hx-swap="outerMorph">'
        ~ '<div id="feedback" role="status" aria-live="polite" hx-preserve></div>'
        ~ (%model<controller-error>.chars ?? '<p class="notice error">Controller: ' ~ escape-html(%model<controller-error>) ~ '</p>' !! '')
        ~ $content ~ '</section>'
}
