use RedSourcing::Web::HTML;
unit module RedSourcing::Web::Presentation;

sub operation-title(Str $name --> Str) is export {
    %(load => 'Load current state', snapshot => 'Save checkpoint', command => 'Send command',
      advance => 'Advance saga', advance-sagas => 'Advance active sagas', saga-status => 'View saga progress', resolve-action => 'Resolve action',
      describe => 'Describe entity', create => 'Create instance', run-command => 'Run stored command',
      list-events => 'View event history'){$name} // $name.subst('-', ' ', :g).tc
}
sub label(Str $key --> Str) { $key.subst('-', ' ', :g).tc }

# Recursive HTML also handles application-specific return values without assuming
# a domain schema. Data never becomes markup, CSS classes or executable URLs.
sub value-view($value, UInt :$depth = 0 --> Str) is export {
    return '<span class="muted">Not set</span>' unless $value.defined;
    return '<span class="muted">Nested data omitted</span>' if $depth > 12;
    if $value ~~ Associative {
        return '<p class="empty-value">No fields.</p>' unless $value.elems;
        return '<dl class="value-fields">' ~ $value.keys.sort.map(-> $key {
            '<div><dt>' ~ escape-html(label($key)) ~ '</dt><dd>'
                ~ ($key eq any(<status state kind>) && $value{$key} ~~ Str
                    ?? pill($value{$key}, $value{$key}.lc)
                    !! value-view($value{$key}, :depth($depth + 1))) ~ '</dd></div>'
        }).join ~ '</dl>';
    }
    if $value ~~ Positional {
        return '<p class="empty-value">No items.</p>' unless $value.elems;
        if $value.grep(* !~~ Associative).elems == 0 {
            my @keys = $value.map({ |.keys }).unique.sort;
            return '<div class="table-scroll result-table"><table><thead><tr>'
                ~ @keys.map({ '<th>' ~ escape-html(label($_)) ~ '</th>' }).join ~ '</tr></thead><tbody>'
                ~ $value.map(-> $row { '<tr>' ~ @keys.map({ '<td>'
                    ~ value-view($row{$_}, :depth($depth + 1)) ~ '</td>' }).join ~ '</tr>' }).join
                ~ '</tbody></table></div>';
        }
        return '<ul class="value-list">' ~ $value.map({ '<li>' ~ value-view($_, :depth($depth + 1)) ~ '</li>' }).join ~ '</ul>';
    }
    return pill($value ?? 'Yes' !! 'No', $value ?? 'done' !! '') if $value ~~ Bool;
    '<span class="value-scalar">' ~ escape-html($value) ~ '</span>'
}
sub section(Str $title, Str $body --> Str) {
    '<section class="result-section"><h3>' ~ escape-html($title) ~ '</h3>' ~ $body ~ '</section>'
}
sub saga-view(%record --> Str) is export {
    my %state = %record<data><saga-state> // %record;
    my @actions = (%state<actions> // []).List;
    my @timers = %state<timers> ~~ Associative
        ?? %state<timers>.keys.sort.map({ %(name => $_, |%state<timers>{$_}) }).Array
        !! (%state<timers> // []).Array;
    my @compensations = (%state<compensations> // []).List;
    my $summary = '<div class="workflow-summary">'
        ~ [['Completed', @actions.grep(*.<status> eq 'done').elems],
           ['Pending', @actions.grep({ .<status> eq any(<pending retry running blocked>) }).elems],
           ['Failed', @actions.grep(*.<status> eq 'failed').elems], ['Timeouts', @timers.elems]].map({
            '<div><span>' ~ .[0] ~ '</span><strong>' ~ .[1] ~ '</strong></div>' }).join ~ '</div>';
    my $actions = @actions ?? '<div class="table-scroll"><table class="workflow-actions"><thead><tr>'
        ~ '<th>Step / target</th><th>Status</th><th>Attempts</th><th>Schedule / outcome</th><th>Arguments</th>'
        ~ '</tr></thead><tbody>' ~ @actions.map(-> %a {
            my $due = %a<due-at> // (%a<due>.defined
                ?? DateTime.now.utc.later(:seconds(%a<due> - now.Num)).Str !! '');
            '<tr><td><strong>' ~ escape-html(%a<step>) ~ '</strong><small>'
                ~ escape-html(%a<target> ~ ' → ' ~ %a<method>) ~ '</small><small class="mono">'
                ~ escape-html(%a<id>) ~ '</small></td><td>' ~ pill(%a<status>, %a<status>)
                ~ '</td><td>' ~ escape-html(%a<attempts> ~ ' / ' ~ (%a<retry><max> // '—'))
                ~ '</td><td><time>' ~ escape-html($due) ~ '</time>'
                ~ (%a<error> ?? '<p class="error">' ~ escape-html(%a<error>) ~ '</p>' !! '')
                ~ (%a<result>.defined ?? '<details><summary>Saved result</summary>' ~ value-view(%a<result>) ~ '</details>' !! '')
                ~ '</td><td><details><summary>Arguments</summary>' ~ value-view(%a<args>) ~ '</details></td></tr>'
        }).join ~ '</tbody></table></div>' !! '<p class="empty-value">No recorded actions. Waiting for input.</p>';
    $summary ~ (%record<message> ?? '<p class="workflow-message">' ~ escape-html(%record<message>) ~ '</p>' !! '')
        ~ section('Actions', $actions) ~ section('Timeouts', value-view(@timers))
        ~ section('Compensations', value-view(@compensations))
}
sub result-view($value, Str :$operation = '' --> Str) is export {
    if $value ~~ Associative {
        if ($value<actions>:exists) && ($value<status>:exists) {
            return value-view($value.grep({ .key eq any(<entity stream status activity reason version cursor>) }).Hash)
                ~ saga-view($value) ~ section('Domain state', value-view($value<data> // {}));
        }
        if ($value<data> ~~ Associative) && ($value<data><saga-state>:exists) {
            return value-view($value.grep(*.key ne 'data').Hash) ~ saga-view($value)
                ~ section('Domain state', value-view($value<data>.grep(*.key ne 'saga-state').Hash));
        }
        if $value<data> ~~ Associative {
            return value-view($value.grep(*.key ne 'data').Hash)
                ~ section(($operation eq 'load' ?? 'Current state' !! 'Data'), value-view($value<data>));
        }
    }
    value-view($value)
}
