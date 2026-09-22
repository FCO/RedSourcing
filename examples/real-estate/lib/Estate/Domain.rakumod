use RedSourcing;
unit module Estate::Domain;

# Money stays Rat in handlers; JSON and HTML values are coerced at the boundary.
role ForProperty does Event is export { has Str $.property-id is required }
class PropertyRegistered does ForProperty is export {
    has Str $.name; has Str $.address; has Str $.kind; has UInt $.bedrooms;
    has Rat() $.monthly-rent;
}
class TenancyStarted does ForProperty is export {
    has Str $.tenant-id; has Str $.tenant-name; has Rat() $.monthly-rent;
}
class TenancyEnded does ForProperty is export { has Str $.tenant-id }
class RentCharged does ForProperty is export {
    has Str $.tenant-id; has Str $.period; has Rat() $.amount;
}
class RentReceived does ForProperty is export {
    has Str $.tenant-id; has Str $.period; has Rat() $.amount; has Str $.reference;
}
class TenantRegistered does Event is export {
    has Str $.tenant-id; has Str $.name; has Str $.email; has Str $.phone;
}
role ForRepair does Event is export { has Str $.repair-id is required }
class RepairRequested does ForRepair is export {
    has Str $.property-id; has Str $.tenant-id; has Str $.title;
    has Str $.description; has Str $.priority;
}
class RepairScheduled does ForRepair is export { has Str $.contractor; has Rat() $.estimate }
class RepairCompleted does ForRepair is export { has Rat() $.cost }
class RepairPaymentStarted does ForRepair is export { }
class RepairPaid does ForRepair is export { has Str $.payment-id; has Rat() $.amount }
class RepairPaymentReversed does ForRepair is export { has Str $.payment-id }
class RepairCancelled does ForRepair is export { has Str $.reason }
class MessagePosted does ForRepair is export {
    has Str $.message-id; has Str $.author; has Str $.body;
    has Str $.sent-at; has Bool $.notification = False;
}

our sub exists-in-store($proxy --> Bool) is export {
    so StoredEvent.^all.grep(*.stream eq $proxy.^stream-name).head
}

aggregate Tenant is export {
    has Str $.tenant-id is entity-id;
    has Str $.name = ''; has Str $.email = ''; has Str $.phone = '';
    method APPLY(TenantRegistered $e) { $!name = $e.name; $!email = $e.email; $!phone = $e.phone }
    method register(Str :$name! where *.trim.chars > 0,
                    Str :$email! where *.contains('@'), Str :$phone = '') is command {
        die 'Tenant is already registered' if $!name.chars;
        self.tenant-registered(:$name, :$email, :$phone);
        %(:$!tenant-id)
    }
}

aggregate Property is export {
    has Str $.property-id is entity-id;
    has Str $.name = ''; has Str $.address = ''; has Str $.kind = 'Apartment';
    has UInt $.bedrooms = 1; has Rat() $.monthly-rent = 0.0;
    has Str $.tenant-id = ''; has Str $.tenant-name = '';
    has Hash $.bills = {};
    multi method APPLY(PropertyRegistered $e) {
        $!name = $e.name; $!address = $e.address; $!kind = $e.kind;
        $!bedrooms = $e.bedrooms; $!monthly-rent = $e.monthly-rent;
    }
    multi method APPLY(TenancyStarted $e) {
        $!tenant-id = $e.tenant-id; $!tenant-name = $e.tenant-name;
        $!monthly-rent = $e.monthly-rent;
    }
    multi method APPLY(TenancyEnded) { $!tenant-id = ''; $!tenant-name = '' }
    multi method APPLY(RentCharged $e) {
        $!bills{$e.period} = %(amount => $e.amount, paid => 0.0, tenant-id => $e.tenant-id);
    }
    multi method APPLY(RentReceived $e) { $!bills{$e.period}<paid> += $e.amount }
    method register(Str :$name! where *.trim.chars > 0,
                    Str :$address! where *.trim.chars > 0,
                    Rat() :$monthly-rent! where * > 0,
                    Str :$kind = 'Apartment', UInt :$bedrooms = 1) is command {
        die 'Property is already registered' if $!name.chars;
        self.property-registered(:$name, :$address, :$kind, :$bedrooms, :$monthly-rent);
        %(:$!property-id)
    }
    method start-tenancy(Str :$tenant-id!) is command {
        die 'Register the property first' unless $!name.chars;
        die 'This property already has a tenant' if $!tenant-id.chars;
        my $p = Tenant.^with-ids(:$tenant-id);
        die 'Tenant does not exist' unless exists-in-store($p) && $p.^load.name.chars;
        self.tenancy-started(:$tenant-id, :tenant-name($p.^load.name), :monthly-rent($!monthly-rent));
        %(:$!property-id, :$tenant-id)
    }
    method end-tenancy is command {
        die 'There is no active tenancy' unless $!tenant-id.chars;
        die 'Settle outstanding rent before ending the tenancy'
            if $!bills.values.first({ .<paid>.Rat < .<amount>.Rat });
        self.tenancy-ended(:tenant-id($!tenant-id));
        %(:$!property-id)
    }
    method charge-rent(Str :$period! where /^ \d ** 4 '-' \d ** 2 $/) is command {
        die 'There is no active tenancy' unless $!tenant-id.chars;
        die 'Rent has already been charged for this month' if $!bills{$period}:exists;
        my $month = $period.substr(5).Int;
        die 'Month must be between 01 and 12' unless 1 <= $month <= 12;
        self.rent-charged(:tenant-id($!tenant-id), :$period, :amount($!monthly-rent));
        %(:$period, :amount($!monthly-rent))
    }
    method receive-rent(Str :$period!, Rat() :$amount! where * > 0,
                        Str :$reference! where *.trim.chars > 0) is command {
        die 'Charge rent for this month first' unless $!bills{$period}:exists;
        my %bill = $!bills{$period};
        die 'Payment exceeds the outstanding balance' if $amount > %bill<amount>.Rat - %bill<paid>.Rat;
        die 'Payment reference has already been used' if StoredEvent.list-events(
            :row, :stream(self.^stream), (RentReceived) => %(reference => $reference)).head;
        self.rent-received(:tenant-id(%bill<tenant-id>), :$period, :$amount, :$reference);
        %(:$!property-id, :$period, :$amount)
    }
}

aggregate Repair is export {
    has Str $.repair-id is entity-id;
    has Str $.property-id = ''; has Str $.tenant-id = ''; has Str $.title = '';
    has Str $.description = ''; has Str $.priority = 'normal'; has Str $.status = 'new';
    has Str $.contractor = ''; has Rat() $.estimate = 0.0; has Rat() $.cost = 0.0;
    has Str $.payment-id = '';
    multi method APPLY(RepairRequested $e) {
        $!property-id = $e.property-id; $!tenant-id = $e.tenant-id;
        $!title = $e.title; $!description = $e.description; $!priority = $e.priority; $!status = 'requested';
    }
    multi method APPLY(RepairScheduled $e) { $!contractor = $e.contractor; $!estimate = $e.estimate; $!status = 'scheduled' }
    multi method APPLY(RepairCompleted $e) { $!cost = $e.cost; $!status = 'completed' }
    multi method APPLY(RepairPaymentStarted) { $!status = 'payment-pending' }
    multi method APPLY(RepairPaid $e) { $!payment-id = $e.payment-id; $!status = 'paid' }
    multi method APPLY(RepairPaymentReversed) { $!payment-id = ''; $!status = 'payment-reversed' }
    multi method APPLY(RepairCancelled) { $!status = 'cancelled' }
    method request-repair(Str :$property-id!, Str :$title! where *.trim.chars > 0,
                          Str :$description = '', Str :$priority = 'normal') is command {
        die 'Repair has already been requested' unless $!status eq 'new';
        die 'Choose normal or urgent priority' unless $priority eq any(<normal urgent>);
        my $p = Property.^with-ids(:$property-id);
        die 'Property does not exist' unless exists-in-store($p) && $p.^load.name.chars;
        self.repair-requested(:$property-id, :tenant-id($p.^load.tenant-id), :$title, :$description, :$priority);
        %(:$!repair-id)
    }
    method schedule(Str :$contractor! where *.trim.chars > 0, Rat() :$estimate! where * > 0) is command {
        die 'Only requested repairs can be scheduled' unless $!status eq 'requested';
        self.repair-scheduled(:$contractor, :$estimate); %(:$!repair-id)
    }
    method finish(Rat() :$cost! where * > 0) is command {
        die 'Schedule the repair before completing it' unless $!status eq 'scheduled';
        self.repair-completed(:$cost); %(:$!repair-id, :$cost)
    }
    method pay-contractor is command {
        die 'Only completed repairs can be paid' unless $!status eq 'completed';
        self.repair-payment-started; %(:$!repair-id)
    }
    method record-payment(Str :$payment-id!, Rat() :$amount!) is command {
        die 'Repair payment was not requested' unless $!status eq 'payment-pending';
        die 'Payment does not match the repair cost' unless $amount == $!cost;
        self.repair-paid(:$payment-id, :$amount); %(:$!repair-id, :$payment-id)
    }
    method reverse-payment(Str :$payment-id!) is command {
        die 'Payment does not match' unless $!status eq 'paid' && $payment-id eq $!payment-id;
        self.repair-payment-reversed(:$payment-id); %(:$!repair-id)
    }
    method cancel(Str :$reason!) is command {
        die 'This repair cannot be cancelled' unless $!status eq any(<requested scheduled>);
        self.repair-cancelled(:$reason); %(:$!repair-id)
    }
}

aggregate Conversation is export {
    has Str $.repair-id is entity-id;
    has Array $.messages = [];
    method APPLY(MessagePosted $e) {
        $!messages.push: %(message-id => $e.message-id, author => $e.author,
            body => $e.body, sent-at => $e.sent-at, notification => $e.notification);
    }
    method post-message(Str :$author! where *.trim.chars > 0,
                        Str :$body! where *.trim.chars > 0,
                        Str :$message-id!, Bool :$notification = False) is command {
        die 'Repair does not exist' unless exists-in-store(Repair.^with-ids(:repair-id($!repair-id)));
        # Stable IDs make a retry after a lost acknowledgement harmless.
        return %(message-id => $message-id) if $!messages.first(*.<message-id> eq $message-id);
        die 'Messages must have at most 2000 characters' if $body.chars > 2000;
        self.message-posted(:$author, :$body, :$message-id, :$notification, :sent-at(DateTime.now.Str));
        %(:$message-id)
    }
}

# These read models consume domain events across aggregate streams.
projection Portfolio is export {
    has Hash $.properties = {};
    multi method APPLY(PropertyRegistered $e) {
        $!properties{$e.property-id} = %(property-id => $e.property-id, name => $e.name,
            address => $e.address, kind => $e.kind, bedrooms => $e.bedrooms,
            monthly-rent => $e.monthly-rent, tenant-id => '', tenant-name => '');
    }
    multi method APPLY(TenancyStarted $e) {
        $!properties{$e.property-id}<tenant-id> = $e.tenant-id;
        $!properties{$e.property-id}<tenant-name> = $e.tenant-name;
    }
    multi method APPLY(TenancyEnded $e) {
        $!properties{$e.property-id}<tenant-id> = ''; $!properties{$e.property-id}<tenant-name> = '';
    }
}
projection TenantDirectory is export {
    has Hash $.tenants = {};
    method APPLY(TenantRegistered $e) {
        $!tenants{$e.tenant-id} = %(tenant-id => $e.tenant-id, name => $e.name, email => $e.email, phone => $e.phone);
    }
}
projection RentLedger is export {
    has Hash $.bills = {}; has Rat() $.received = 0.0;
    multi method APPLY(RentCharged $e) {
        $!bills{"{$e.property-id}/{$e.period}"} = %(property-id => $e.property-id,
            tenant-id => $e.tenant-id, period => $e.period, amount => $e.amount, paid => 0.0);
    }
    multi method APPLY(RentReceived $e) {
        $!bills{"{$e.property-id}/{$e.period}"}<paid> += $e.amount; $!received += $e.amount;
    }
}
projection RepairBoard is export {
    has Hash $.repairs = {};
    method APPLY(ForRepair $e) {
        return if $e ~~ MessagePosted;
        my $id = $e.repair-id;
        given $e {
            when RepairRequested {
                $!repairs{$id} = %(repair-id => $id, property-id => .property-id, title => .title,
                    description => .description, priority => .priority, status => 'requested',
                    contractor => '', estimate => 0.0, cost => 0.0, payment-id => '');
            }
            when RepairScheduled { $!repairs{$id}<contractor> = .contractor; $!repairs{$id}<estimate> = .estimate; $!repairs{$id}<status> = 'scheduled' }
            when RepairCompleted { $!repairs{$id}<cost> = .cost; $!repairs{$id}<status> = 'completed' }
            when RepairPaymentStarted { $!repairs{$id}<status> = 'payment-pending' }
            when RepairPaid { $!repairs{$id}<status> = 'paid'; $!repairs{$id}<payment-id> = .payment-id }
            when RepairPaymentReversed { $!repairs{$id}<status> = 'payment-reversed'; $!repairs{$id}<payment-id> = '' }
            when RepairCancelled { $!repairs{$id}<status> = 'cancelled' }
        }
    }
}
projection RepairChat is export {
    has Str $.repair-id is entity-id;
    has Array $.messages = [];
    method APPLY(MessagePosted $e where { .repair-id eq $!repair-id }) {
        $!messages.push: %(message-id => $e.message-id, author => $e.author,
            body => $e.body, sent-at => $e.sent-at, notification => $e.notification);
    }
}

saga RepairWorkflow is export {
    has Str $.repair-id is entity-id;
    has Rat() $.cost = 0.0; has Str $.title = ''; has Str $.property-id = '';
    has Str $.payment-id = ''; has Str $.last-notification = '';
    multi method APPLY(RepairRequested $e where { .repair-id eq $!repair-id }) {
        $!title = $e.title; $!property-id = $e.property-id;
    }
    multi method APPLY(RepairCompleted $e where { .repair-id eq $!repair-id }) { $!cost = $e.cost }
    # Native controls are delivered only to the owning saga; replay uses its stream.
    multi method APPLY(StepSucceeded $e where { .step eq 'send-payment' }) { $!payment-id = $e.result<payment-id> }
    multi method APPLY(StepSucceeded $e where { .step eq 'notify' }) { $!last-notification = $e.result<message-id> }
    multi method REACT(RepairRequested $e where { .repair-id eq $!repair-id }) {
        self.notify(:body("Repair opened: {$e.title}. Our team will arrange a contractor."));
        self.set-timeout('repair-follow-up', 24 * 60 * 60, remind => \());
    }
    multi method REACT(RepairScheduled $e where { .repair-id eq $!repair-id }) {
        self.notify(:body("{$e.contractor} is booked. Estimated cost: £{$e.estimate.fmt('%.2f')}."));
    }
    multi method REACT(RepairCompleted $e where { .repair-id eq $!repair-id }) {
        self.cancel-timeout('repair-follow-up');
        self.notify(:body("Work completed. Final cost: £{$e.cost.fmt('%.2f')}. Awaiting payment approval."));
    }
    multi method REACT(RepairCancelled $e where { .repair-id eq $!repair-id }) {
        self.cancel-timeout('repair-follow-up');
        self.notify(:body("Repair cancelled: {$e.reason}"));
    }
    multi method REACT(RepairPaymentStarted $e where { .repair-id eq $!repair-id }) { self.send-payment }
    multi method REACT(StepSucceeded $e where { .step eq 'send-payment' }) {
        self.record-payment(:payment-id($e.result<payment-id>), :amount($e.result<amount>.Rat));
    }
    multi method REACT(StepSucceeded $e where { .step eq 'record-payment' }) {
        self.notify(:body('Contractor payment confirmed. Thank you for your patience.'));
    }
    multi method REACT(StepFailed $e) { self.^compensate(:reason($e.error)) }
    method notify(Str :$body!) {
        self.^service('estate-notifications', 'deliver', \(:repair-id($.repair-id), :$body),
            :retry{:3max, :1delay}, :!compensation);
    }
    method remind {
        self.notify(:body('Your repair is still open. Please use this chat if you need an update.'));
    }
    method send-payment {
        self.^service('estate-payments', 'pay', \(:repair-id($.repair-id), :amount($.cost)),
            :retry{:3max, :backoff(Exponential), :1init-delay, :4max-delay});
    }
    method compensate-send-payment(Str :$payment-id!, |) {
        self.^service('estate-payments', 'refund', \(:$payment-id), :retry{:5max, :2delay});
    }
    method record-payment(Str :$payment-id!, Rat() :$amount!) {
        self.^command(Repair, 'record-payment', \(:$payment-id, :$amount), :retry{:3max, :1delay});
    }
    method compensate-record-payment(Str :$payment-id!, |) {
        self.^command(Repair, 'reverse-payment', \(:$payment-id), :retry{:5max, :2delay});
    }
}
