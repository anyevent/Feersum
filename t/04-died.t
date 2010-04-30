#!perl
use warnings;
use strict;
use Test::More tests => 9;
use Test::Exception;
use blib;
use Carp ();
use Encode;
use utf8;
use bytes; no bytes;
use Scalar::Util qw/blessed/;
$SIG{__DIE__} = \&Carp::confess;
$SIG{PIPE} = 'IGNORE';

BEGIN { use_ok('Socialtext::EvHttp') };

use IO::Socket::INET;
use AnyEvent;
use AnyEvent::HTTP;

my $socket = IO::Socket::INET->new(
    LocalAddr => 'localhost:10203',
    Proto => 'tcp',
    Listen => 1024,
    Blocking => 0,
);
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $evh = Socialtext::EvHttp->new();

{
    no warnings 'redefine';
    *Socialtext::EvHttp::DIED = sub {
        my $err = shift;
        pass 'DIED was called';
        diag "Died during request handler: $err";
    };
}

$evh->request_handler(sub {
    my $r = shift;
    die "holy crap!";
});

lives_ok {
    $evh->use_socket($socket);
} 'assigned socket';

my $cv = AE::cv;
$cv->begin;
my $w = http_get 'http://localhost:10203/?blar', timeout => 3, sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 500, "client got 500";
    is $headers->{'content-type'}, 'text/plain';
    is $body, "Request handler threw an exception.\n", 'got expected body';
    $cv->end;
};

$cv->recv;
pass "all done";
