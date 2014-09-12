#!perl

use 5.010;
use strict;
use warnings;

use DBIx::Diff::Struct qw(diff_db_struct);
use SQL::Schema::Versioned qw(create_or_update_db_schema);
use Test::Exception;
use Test::More 0.98;

# TODO

ok 1;
done_testing;

__END__

# we test database migration by creating 2 versions of database. the first
# database is created from the earliest supported version and upgraded to the
# latest, while the second database installs directly to the latest version.
# both database should have the same structure.

$dbh1 = ...;

create_or_update_db_schema(
    dbh => $dbh1,
    spec => $spec,
    create_from_version => 2,
);

$dbh2 = ...;

create_or_update_db_schema(
    dbh => $dbh2,
    spec => $spec,
);

my $res = diff_db_struct($dbh1, $dbh2);
is_deeply($res, {}) or diag explain $res;
