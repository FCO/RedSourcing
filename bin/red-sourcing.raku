#!/usr/bin/env raku
use RedSourcing::CLI::Application;
my %*SUB-MAIN-OPTS = :named-anywhere, :coerce-allomorphs-to(Numeric);
initialize-cli();
