#!/usr/bin/perl

use Plack::App::Apache::ActionWrapper;
my $app = Plack::App::Apache::ActionWrapper->new->to_app;

use Plack::Handler::FCGI;
Plack::Handler::FCGI->new->run($app);
