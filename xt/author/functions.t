#!perl

# this is the test of core functionalities. we test at the level of functions to
# skip the network and auth issues. auth is tested separately.

use 5.010;
use strict;
use warnings;

use CPANLists::Server;
use Test::More 0.98;
use Test::WithDB;

my $twdb = Test::WithDB->new;

my $env = {REMOTE_ADDR=>'127.0.0.1'};
CPANLists::Server::__env($env);

my $dbh = $twdb->create_db;
CPANLists::Server::__dbh($dbh);

CPANLists::Server::__init_db;

subtest create_user => sub {
    my $res;
    $res = CPANLists::Server::create_user(
        username=>"steven", email=>'steven@localhost', password=>"123456");
    is($res->[0], 200, "create_user succeeds");
    $res = CPANLists::Server::create_user(
        username=>"steven", email=>'steven2@localhost', password=>"123456");
    is($res->[0], 500, "duplicate username fails");
    $res = CPANLists::Server::create_user(
        username=>"steven2", email=>'steven@localhost', password=>"123456");
    is($res->[0], 500, "duplicate email fails");
    $res = CPANLists::Server::create_user(
        username=>"bob", email=>'bob@localhost', password=>"123456");
    is($res->[0], 200, "create_user (2) succeeds");
};

subtest get_user => sub {
    my $res;

    $res = CPANLists::Server::get_user(
        username=>"Steven");
    is($res->[0], 200, "get_user by username succeeds (case-insensitive)");
    is($res->[2]{username}, "steven");

    $res = CPANLists::Server::get_user(
        email=>'bob@localhost');
    is($res->[0], 200, "get_user by email succeeds");
    is($res->[2]{username}, "bob");

    $res = CPANLists::Server::get_user(
        email=>'blah@localhost');
    is($res->[0], 404, "get_user non-existent returns 404");
};

if (0) {

subtest auth_user => sub {
};

subtest create_list => sub {
};

subtest list_lists => sub {
};

subtest like_list => sub {
};

subtest unlike_list => sub {
};

subtest list_items => sub {
};

subtest get_list => sub {
};

subtest delete_list => sub {
};

subtest update_list => sub {
};

subtest add_item => sub {
};

subtest delete_item => sub {
};

subtest update_item => sub {
};

subtest get_list_comments => sub {
};

subtest list_list_comments => sub {
};

subtest add_list_comments => sub {
};

subtest update_list_comment => sub {
};

subtest delete_list_comment => sub {
};

} # if(0)

# XXX delete_user
# XXX set_user_password
# XXX update_user

# TODO func: get_bitcard_signin_url
# TODO func: verify_bitcard_signin
# TODO func: create_or_get_session
# TODO func: check_session

# XXX test activity log?

DONE_TESTING:
done_testing;
$twdb->done;
