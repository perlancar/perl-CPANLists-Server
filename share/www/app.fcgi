#!/usr/bin/perl

use Mojolicious::Lite;

use CPANLists::Server;
use Data::Dump;
use DBI;
use File::Slurp;
use JSON;

my $json = JSON->new->allow_nonref;
my $home = (getpwuid($>))[7];  # $ENV{HOME} is empty if via fcgi
my $conf = $json->decode(~~read_file("$home/cpanlists-server.conf.json"));
my $dbh  = DBI->connect($conf->{dbdsn} ? $conf->{dbdsn} :
                            "dbi:Pg:dbname=$conf->{dbname};host=localhost",
                        $conf->{dbuser}, $conf->{dbpass});
CPANLists::Server::__dbh($dbh);
CPANLists::Server::__init_db();

app->secret($conf->{'app_secret'} // rand());

get '/' => {text=>'hello, world!'};
get '/test1';

# the rest should go to static files
any ["/assets/*", "images/*"] => sub {
    my $self = shift;
    my $rel = $self->req->url->to_rel;
    my $path = ".$rel";
    if (-e $path) {
        $self->render_static($path);
    } else {
        $self->render_text('not found');
        $self->rendered(404);
    }
};

# this script is meant to be run as fastcgi, or under 'morbo' or 'plackup'
@ARGV = ('fastcgi') unless $ENV{PLACK_ENV} || $ENV{MORBO_REV};
app->start;

=head1 SYNOPSIS

For testing, you can run:

 % morbo app

For deployment, run as FastCGI (.htaccess for Apache provided).


=head1 DESCRIPTION

=cut
