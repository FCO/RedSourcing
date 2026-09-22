use RedSourcing;
unit module BankEvents;

role TimedAmount {
    has Rat()    $.amount is required;
    has DateTime() $.timestamp is required;
    method period { .year * 100 + .month given $!timestamp }
}

class Deposited is export does Event does TimedAmount {
    has Int $.client-id is required;
}

# The canonical transfer, written once in the sender's stream.
class Transaction is export does Event does TimedAmount {
    has Int $.from-client is required;
    has Int $.to-client is required;
}

# The recipient's stream records its credit and references the canonical row.
class TransferReceived is export does Event does TimedAmount {
    has Int $.from-client is required;
    has Int $.to-client is required;
    has UInt $.transaction-id is required;
}
