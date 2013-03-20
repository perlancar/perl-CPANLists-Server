#!/usr/bin/perl

use 5.010;
use strict;
use warnings;

use App::cpanlists::Server;
use DBI;
use File::Slurp;
use JSON;
use Plack::Request;
use Plack::Response;
use Routes::Tiny;

my $json = JSON->new->allow_nonref;
my $home = (getpwuid($>))[7];  # $ENV{HOME} is empty if via fcgi
my $conf = $json->decode(~~read_file("$home/cpanlists-server.conf.json"));
my $dbh  = DBI->connect("dbi:Pg:dbname=$conf->{dbname};host=localhost",
    $conf->{dbuser}, $conf->{dbpass});
App::cpanlists::Server::__dbh($dbh);

my $routes = Routes::Tiny->new;
$routes->add_route(
    '/list/:id(/:action)?',
    constraints => {id=>qr/\d+/, action=>qr/create|view|delete/},
    defaults    => {controller=>'list', action => 'view'},
);
$routes->add_route(
    '/search',
    defaults => {controller=>'search'},
);
#$routes->add_route(
#    '/module/:name',
#    constraints => {name=>qr/\w+(::\w+)*/},
#);
#$routes->add_route(
#    '/author/:name',
#    constraints => {name=>qr/\w+(::\w+)*/}.
#);
#$routes->add_route(
#    '/release/:name',
#    constraints => {name=>qr/\w+(-\w+)*/});
$routes->add_route(
    '/lists(/:mode)?(/page/:page)?',
    constraints => {mode => qr/^(newest|most_liked|most_commented|mine|liked|commented)$/},
    defaults    => {controller=>'lists', mode=>'newest', page=>1},
);
$routes->add_route(
    '/',
    defaults => {controller=>'lists', mode=>'newest'},
);
$routes->add_route(
    '/account(/:action)',
    constraints => {action => qr/(login_bitcard|verify_bitcard)/},
    defaults    => {controller=>'account'},
);

my $app = sub {
    my $env = shift;
    my $req = Plack::Request->new($env);
    my $res = Plack::Response->new(200);
    $res->content_type("text/html");

    my $pi = $req->path_info;
    $pi =~ s!^/app\.psgi/!/!;

    my $match = $routes->match($pi);
    if ($match) {
        require Data::Dump;
        $res->body("match: ", Data::Dump::dump($match));
    } else {
        $res->body("Not found");
    }

    $res->finalize;
};

=head1 SYNOPSIS

To deploy as FastCGI script, see INSTALL.org. This will require a restart
(killing the FCGI process) whenever we modify the application.

For testing, you can run:

 % plackup app.psgi


=head1 DESCRIPTION

=cut
