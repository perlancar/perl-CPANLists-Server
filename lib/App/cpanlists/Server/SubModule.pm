package App::cpanlists::Server::SubModule;

# just a test for Riap 'list' action

use 5.010;
use strict;
use warnings;

# VERSION

our %SPEC;

$SPEC{''} = {
    v => 1.1,
    summary => 'Example summary',
};

$SPEC{test} = {
    v => 1.1,
    summary => 'Just a dummy function',
};
sub test {
    [200, "OK", "This is an example response"];
}

1;
# ABSTRACT: Test module
