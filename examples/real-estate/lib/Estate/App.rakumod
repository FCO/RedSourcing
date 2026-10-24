use RedSourcing;
use Red;
use Estate::Domain;
use JSON::Fast;
unit module Estate::App;

# View copies keep callers from mutating cached state; money remains Rat.
multi sub copy-view(Associative $value) { $value.kv.map(-> $k, $v { $k => copy-view($v) }).Hash }
multi sub copy-view(Positional $value) { $value.map({ copy-view($_) }).Array }
multi sub copy-view($value) { $value }

# A local, durable stand-in for a payment provider's idempotency ledger.
model ProviderReceipt is table<estate_demo_provider_receipt> {
    has UInt $.id is serial;
    has Str $.key is column is unique is required;
    has Str $.operation is column is required;
    has Str $.arguments is column is required;
    has Str $.response is column is rw = '{}';
    has UInt $.attempts is column is rw = 0;
    has Bool $.done is column is rw = False;
}
model ProviderSettings is table<estate_demo_provider_settings> {
    has UInt $.id is id;
    has UInt $.failures-left is column is rw = 0;
}

class App is export {
    has Lock $!lock .= new;
    has Str $.controller-error is rw = '';
    has Promise $!controller;
    has Bool $!stopping = True;
    has Supplier $!updates .= new;
    has Str $!revision = '';
    has UInt $!controller-cursor = 0;
    has %!next-work;
    has %!workflow-versions;
    has %!models;
    has UInt $!model-cursor = 0;
    has Str $.csrf-token = (1..32).map({ ('a'..'z', 'A'..'Z', '0'..'9').flat.pick }).join;

    method locked(&work) { $!lock.protect(&work) }
    method !publish(Bool :$force = False) {
        my $last = StoredEvent.^all.sort(-*.id).head;
        my $revision = ($last ?? $last.id !! 0).Str;
        if $force || $revision ne $!revision {
            $!revision = $revision;
            $!updates.emit($revision);
        }
    }
    method updates {
        supply {
            emit "retry: 1500\nevent: refresh\ndata: connected\n\n";
            whenever $!updates.Supply -> $revision {
                emit "event: refresh\ndata: {$revision}\n\n";
            }
            whenever Supply.interval(15) { emit ": keepalive\n\n" }
        }
    }
    method initialize(Bool :$seed = True) {
        $_.^create-table(:unless-exists) for StoredEvent, StoredCommand, ProviderReceipt, ProviderSettings;
        ProviderSettings.^create(:id(1)) unless ProviderSettings.^all.head;
        self!adapters;
        self.seed if $seed && !StoredEvent.^all.head;
        self.tick;
        self
    }
    method !adapters {
        my $app = self;
        register-service 'estate-payments', sub (Str $operation, Capture $args, Str :$idempotency-key!) {
            my %args = $args.hash;
            my $receipt = ProviderReceipt.^all.grep(*.key eq $idempotency-key).head;
            if $receipt {
                die Permanent.new(:message('Idempotency key reused for a different payment'))
                    unless $receipt.operation eq $operation && from-json($receipt.arguments) eqv from-json(to-json(%args));
                return from-json($receipt.response) if $receipt.done;
            } else {
                $receipt = ProviderReceipt.^create(:key($idempotency-key), :$operation, :arguments(to-json(%args)));
            }
            $receipt.attempts++;
            $receipt.^save;
            my $settings = ProviderSettings.^all.head;
            if $operation eq 'pay' && $settings.failures-left > 0 {
                $settings.failures-left--; $settings.^save;
                die Retryable.new(:message('Demo provider temporarily unavailable; no payment was made'));
            }
            my %result;
            given $operation {
                when 'pay' {
                    die Permanent.new(:message('Payment must be positive')) unless %args<amount>.Rat > 0;
                    %result = %(payment-id => "payment-{$receipt.id}", amount => %args<amount>.Rat);
                }
                when 'refund' {
                    my $original = ProviderReceipt.^all.grep(*.operation eq 'pay').grep(*.done).Seq.first({
                        from-json(.response)<payment-id> eq %args<payment-id>
                    });
                    die Permanent.new(:message('Original payment was not found')) unless $original;
                    %result = %(payment-id => %args<payment-id>, refunded => True);
                }
                default { die Permanent.new(:message("Unknown payment operation '$operation'")) }
            }
            $receipt.response = to-json(%result); $receipt.done = True; $receipt.^save;
            %result
        };
        register-service 'estate-notifications', sub (Str $operation, Capture $args, Str :$idempotency-key!) {
            die Permanent.new(:message('Unknown notification operation')) unless $operation eq 'deliver';
            my %args = $args.hash;
            my $chat = Conversation.^with-ids(:repair-id(%args<repair-id>));
            $chat.^create unless exists-in-store($chat);
            $chat.post-message(:author('Hearth · updates'), :body(%args<body>),
                :message-id($idempotency-key), :notification);
        };
    }
    method tick(DateTime :$now = DateTime.now) {
        self.locked({
            try {
                CATCH { default { $!controller-error = .message } }
                $!controller-error = '';
                my @recent = StoredEvent.^all.grep(*.id > $!controller-cursor).sort(*.id).Seq.Array;
                my %affected;
                for @recent -> $row {
                    if $row.class eq any((RepairRequested, RepairScheduled, RepairCompleted,
                            RepairPaymentStarted, RepairCancelled).map(*.^name)) {
                        my $id = $row.data<repair-id>;
                        %affected{$id} = True;
                        %!next-work{$id} //= 0;
                    } elsif $row.stream.starts-with(RepairWorkflow.^name ~ ': ') {
                        my $id = $row.data<values><repair-id> // $row.data<repair-id>;
                        next unless $id.defined;
                        next if $row.version <= (%!workflow-versions{$id} // 0);
                        %affected{$id} = True;
                        %!next-work{$id} //= 0;
                    }
                }
                # Chat, rent and unrelated repairs never recompile this saga's
                # subscription rules. Retries and timers wake it independently.
                for %!next-work.keys.sort -> $id {
                    next unless %affected{$id} || %!next-work{$id} <= $now.Instant.Num;
                    my $workflow = RepairWorkflow.^with-ids(:repair-id($id)).^advance(:$now);
                    my @due = $workflow.^state<timers>.values.map(*.<due>);
                    my $action = $workflow.^state<actions>.first({ .<status> eq any(<running pending retry blocked>) });
                    @due.push($action<status> eq 'running' ?? 0 !! $action<due>)
                        if $action && $action<status> ne 'blocked';
                    @due.push(0) if $workflow.^status eq 'compensating'
                        && !$workflow.^state<actions>.first(*.<status> eq 'blocked');
                    %!next-work{$id} = @due ?? @due.min !! Inf;
                    %!workflow-versions{$id} = $workflow.^version;
                }
                $!controller-cursor = @recent.tail.id if @recent;
            }
            self!publish;
        });
    }
    method start-controller {
        die 'Controller is already running' unless $!stopping;
        $!stopping = False;
        # Wait after each pass: slow replay cannot accumulate interval callbacks
        # that compete with HTTP requests for the database lock.
        $!controller = start {
            until $!stopping {
                await Promise.in(1);
                self.tick unless $!stopping;
            }
        };
        self
    }
    method stop-controller {
        $!stopping = True;
        await $!controller if $!controller.defined;
    }
    method read-model {
        self.locked({
            my $last = StoredEvent.^all.sort(-*.id).head;
            my $cursor = $last ?? $last.id !! 0;
            if !%!models || $cursor != $!model-cursor {
                my $rent = RentLedger.^with-ids.^load;
                %!models = %(properties => Portfolio.^with-ids.properties,
                    tenants => TenantDirectory.^with-ids.tenants,
                    rent => $rent.bills, received => $rent.received,
                    repairs => RepairBoard.^with-ids.repairs);
                $!model-cursor = $cursor;
            }
            %(|copy-view(%!models), receipts => ProviderReceipt.^all.sort(*.id).Seq.map({
                    %(id => .id, operation => .operation, attempts => .attempts, done => .done,
                        result => from-json(.response))
                }).Array, controller-error => $!controller-error)
        })
    }
    method chat(Str $repair-id) {
        self.locked({ RepairChat.^with-ids(:$repair-id).messages.list })
    }
    method id(Str $prefix --> Str) { "$prefix-{DateTime.now.Instant.to-posix.head.Int}-{(100000..999999).pick}" }
    method execute(Str $action, %data) {
        self.locked({
            LEAVE self!publish(:force);
            given $action {
                when 'property' {
                    my $p = Property.^with-ids(:property-id(self.id('property'))); $p.^create;
                    $p.register(:name(%data<name>), :address(%data<address>),
                        :monthly-rent(%data<monthly-rent>.Rat), :bedrooms(%data<bedrooms>.Int), :kind(%data<kind>));
                }
                when 'tenant' {
                    my $p = Tenant.^with-ids(:tenant-id(self.id('tenant'))); $p.^create;
                    $p.register(:name(%data<name>), :email(%data<email>), :phone(%data<phone> // ''));
                }
                when 'tenancy' { Property.^with-ids(:property-id(%data<property-id>)).start-tenancy(:tenant-id(%data<tenant-id>)) }
                when 'end-tenancy' { Property.^with-ids(:property-id(%data<property-id>)).end-tenancy }
                when 'charge-rent' { Property.^with-ids(:property-id(%data<property-id>)).charge-rent(:period(%data<period>)) }
                when 'receive-rent' {
                    Property.^with-ids(:property-id(%data<property-id>)).receive-rent(
                        :period(%data<period>), :amount(%data<amount>.Rat), :reference(%data<reference>));
                }
                when 'repair' {
                    my $p = Repair.^with-ids(:repair-id(self.id('repair'))); $p.^create;
                    $p.request-repair(:property-id(%data<property-id>), :title(%data<title>),
                        :description(%data<description> // ''), :priority(%data<priority> // 'normal'));
                }
                when 'schedule' {
                    Repair.^with-ids(:repair-id(%data<repair-id>)).schedule(
                        :contractor(%data<contractor>), :estimate(%data<estimate>.Rat));
                }
                when 'finish' { Repair.^with-ids(:repair-id(%data<repair-id>)).finish(:cost(%data<cost>.Rat)) }
                when 'pay-repair' { Repair.^with-ids(:repair-id(%data<repair-id>)).pay-contractor }
                when 'cancel-repair' { Repair.^with-ids(:repair-id(%data<repair-id>)).cancel(:reason(%data<reason>)) }
                when 'message' {
                    my $p = Conversation.^with-ids(:repair-id(%data<repair-id>));
                    $p.^create unless exists-in-store($p);
                    # Author identity is one of the explicit demo roles, not free text.
                    die 'Choose an agency, tenant or contractor role' unless %data<author> eq any(<Agency Tenant Contractor>);
                    $p.post-message(:author(%data<author>), :body(%data<body>), :message-id(self.id('message')));
                }
                when 'fail-next-payment' { my $s = ProviderSettings.^all.head; $s.failures-left = 1; $s.^save }
                when 'compensate' {
                    RepairWorkflow.^with-ids(:repair-id(%data<repair-id>)).^load.^compensate(:reason('Agency requested reversal'));
                }
                when 'checkpoint' {
                    $_.^with-ids.^load.^emit-snapshot for Portfolio, TenantDirectory, RentLedger, RepairBoard;
                    for StoredEvent.list-events(:types[RepairRequested]) -> $e {
                        RepairWorkflow.^with-ids(:repair-id($e.repair-id)).^load.^emit-snapshot;
                    }
                }
                default { die "Unknown action '$action'" }
            }
        })
    }
    method seed {
        my @tenants = ('tenant-ana', 'Ana Martins', 'ana@example.test', '07700 900101'),
                      ('tenant-james', 'James Wilson', 'james@example.test', '07700 900102'),
                      ('tenant-maya', 'Maya Patel', 'maya@example.test', '07700 900103');
        for @tenants -> @t {
            my $p = Tenant.^with-ids(:tenant-id(@t[0])); $p.^create;
            $p.register(:name(@t[1]), :email(@t[2]), :phone(@t[3]));
        }
        my @properties = ('p-cedar', 'Cedar House', '18 Cedar Lane, Bristol', 'Townhouse', 3, 1650.0, 'tenant-ana'),
                         ('p-dock', 'Dockside Loft', '42 Harbour Walk, Bristol', 'Apartment', 2, 1425.0, 'tenant-james'),
                         ('p-garden', 'Garden Studio', '7 Willow Mews, Bristol', 'Studio', 1, 975.0, 'tenant-maya'),
                         ('p-park', 'Park View', '23 Clifton Road, Bristol', 'Apartment', 2, 1350.0, '');
        my $period = Date.today.Str.substr(0, 7);
        for @properties -> @p {
            my $p = Property.^with-ids(:property-id(@p[0])); $p.^create;
            $p.register(:name(@p[1]), :address(@p[2]), :kind(@p[3]), :bedrooms(@p[4]), :monthly-rent(@p[5]));
            if @p[6].chars { $p.start-tenancy(:tenant-id(@p[6])); $p.charge-rent(:$period) }
        }
        Property.^with-ids(:property-id<p-cedar>).receive-rent(:$period, :amount(1650.0), :reference<seed-cedar>);
        Property.^with-ids(:property-id<p-garden>).receive-rent(:$period, :amount(500.0), :reference<seed-garden>);
        my @repairs = ('r-boiler', 'p-cedar', 'Boiler losing pressure', 'The heating cuts out in the evening.', 'urgent'),
                      ('r-window', 'p-dock', 'Bedroom window seal', 'A draught around the frame on windy days.', 'normal');
        for @repairs -> @r {
            my $p = Repair.^with-ids(:repair-id(@r[0])); $p.^create;
            $p.request-repair(:property-id(@r[1]), :title(@r[2]), :description(@r[3]), :priority(@r[4]));
        }
        Repair.^with-ids(:repair-id<r-boiler>).schedule(:contractor('Harris Heating'), :estimate(185.0));
        my $chat = Conversation.^with-ids(:repair-id<r-boiler>); $chat.^create;
        $chat.post-message(:author<Tenant>, :body('I am home after 4pm if the engineer needs access.'), :message-id<seed-chat-1>);
        $chat.post-message(:author<Agency>, :body('Thanks Ana. Harris Heating will visit tomorrow after 4pm.'), :message-id<seed-chat-2>);
    }
}
