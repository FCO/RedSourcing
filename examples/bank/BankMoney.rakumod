unit module BankMoney;

# Rat arithmetic is exact. Use monetary values with at most two decimal places
# so the JSON decimal representation preserves every amount in this example.
sub positive-money(Rat $amount --> Bool) is export {
    $amount > 0 && ($amount * 100).denominator == 1
}
