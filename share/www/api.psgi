#!/usr/bin/perl

use 5.010;
use strict;
use warnings;

use DBI;
use File::Slurp::Tiny qw(read_file);
use File::Write::Rotate;
use JSON;
use Perinci::Access::Base::Patch::PeriAHS;
use Plack::Builder;
use Plack::Util::PeriAHS qw(errpage);
use CPANLists::Server;

my $json = JSON->new->allow_nonref;
my $home = (getpwuid($>))[7];  # $ENV{HOME} is empty if via fcgi
my $conf = $json->decode(~~read_file("$home/cpanlists-server.conf.json"));
my $dbh  = DBI->connect($conf->{dbdsn} ? $conf->{dbdsn} :
                            "dbi:Pg:dbname=$conf->{dbname};host=localhost",
                        $conf->{dbuser}, $conf->{dbpass}, {RaiseError=>0});
CPANLists::Server::__dbh($dbh);
CPANLists::Server::__init_db();
CPANLists::Server::__conf($conf); # XXX for security, in the future it's better to not let webapp see db credentials

my $fwr = File::Write::Rotate->new(
    dir       => $conf->{riap_access_log_dir},
    prefix    => $conf->{riap_access_log_prefix},
    size      => $conf->{riap_access_log_size},
    histories => $conf->{riap_access_log_histories},
);

my $app = builder {
    enable(
        "PeriAHS::LogAccess",
        dest => $fwr,
    );

    #enable "PeriAHS::CheckAccess";

    enable(
        "PeriAHS::ParseRequest",
        #parse_path_info => $args{parse_path_info},
        #parse_form      => $args{parse_form},
        #parse_reform    => $args{parse_reform},
        riap_uri_prefix  => '/CPANLists/Server',
    );

    enable_if(
        sub {
            my $env = shift;
            my $rreq = $env->{'riap.request'};
            my $action = $rreq->{action};
            my ($mod, $func) = $rreq->{uri} =~ m!\A(?:pl:)?/(.+)/(.+)!;
            $mod //= ""; $func //= "";

            # public actions that need not authentication
            if ($action =~ /^(meta|info|actions|list|child_metas)$/ ||
                    $action eq 'call' && $mod eq 'CPANLists/Server' && $func =~ /\A(get_bitcard_signin_url|verify_bitcard_signin|get_list|list_lists|list_items|get_list_comment|list_list_comments)\z/) {
                $env->{"app.needs_auth"} = 0;
                return 0;
            } else {
                $env->{"app.needs_auth"} = 1;
                return 1;
            }
        },
        "Auth::Basic",
        authenticator => sub {
            my ($user, $pass, $env) = @_;

            #my $role;
            #my $res = CPANLists::Server::auth_user(
            #    username => $user, password=>$pass);
            my $res = CPANLists::Server::check_session(
                username => $user, id => $pass);
            if ($res->[0] == 200) {
                $env->{"REMOTE_USER"} = $user; # isn't this already done by webserver?
                $env->{"app.user_id"} = $res->[2]{userid};
                return 1;
            }
            return 0;
        }
    );

    enable(
        sub {
            my $app = shift;
            sub {
                my $env = shift;
                my $rreq = $env->{'riap.request'};

                $rreq->{uri} =~ s!\Apl:/api/!pl:/!;

                my ($mod, $func) = $rreq->{uri} =~ m!\A(?:pl:)?/(.+)/(.+)!;
                $mod =~ s!/!::!g;

                # authz
                {
                    last unless $env->{"app.needs_auth"};

                    my $uid  = $env->{"app.user_id"};
                    my $user = $env->{REMOTE_USER};
                    #my $role = $env->{"app.user_role"};

                    # everybody can create/comment/like/unlike lists
                    last if $func =~ /^(create_list|add_list_comment|like_list|unlike_list)$/;

                    # user can add item/update/delete item of lists he created
                    if ($func =~ /^(delete_list|update_list|add_item|delete_item|update_item)$/) {
                        my $lid = $func =~ /^(delete_list|update_list)$/ ? $rreq->{args}{id} : $rreq->{args}{list_id};
                        my $res = CPANLists::Server::get_list(id => $lid, items=>0);
                        return errpage($env, $res) if $res->[0] != 200;
                        return errpage($env, [403, "List is not yours"])
                            unless $res->[2]{creator} eq $user;
                        last;
                    }

                    # user can update/delete his own list comments
                    if ($func =~ /^(delete_list_comment|update_list_comment)$/) {
                        my $cid = $rreq->{args}{id};
                        my $res = CPANLists::Server::get_list_comment(id => $cid);
                        return errpage($env, $res) if $res->[0] != 200;
                        return errpage($env, [403, "List comment is not yours"])
                            unless $res->[2]{creator} eq $user;
                        last;
                    }

                    # no other functions are available
                    return errpage($env, [403, "Unauthorized"]);
                }

                CPANLists::Server::__env($env);
                $app->($env);
            };
        },
    );

    enable "PeriAHS::Respond";
};

=head1 SYNOPSIS

To deploy as FastCGI script, see INSTALL.org. This will require a restart
(killing the FCGI process) whenever we modify the application.

For testing, you can run:

 % plackup api.psgi

To test the app:

 # first sign in via bitcard
 % curl http://localhost:5000/api/get_bitcard_signin_url
 https://www.bitcard.org/...

 # follow the URL in the browser
 % curl https://www.bitcard.org/...

 # you will be returned to https://cpanlists.org/api/verify_bitcard_signin?...
 # replace the host with the test host and follow it
 % curl http://localhost:5000/api/verify_bitcard_signin?...

 # you will retrieve session ID (SESSID) which will be required to perform
 # functions that need authentication.

 % curl http://localhost:5000/api/list_lists
 % curl -u USER:SESSID 'http://localhost:5000/api/like_list?id=1'
 % curl -u USER:SESSID 'http://localhost:5000/api/unlike_list?id=1'


=head1 DESCRIPTION

=cut
