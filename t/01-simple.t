#!perl
use warnings;
use strict;
use Test::More tests => 30;
use Test::Exception;
use blib;
use Carp ();
use Guard;
use Encode();
use utf8;
$SIG{__DIE__} = \&Carp::confess;
$SIG{PIPE} = 'IGNORE';

BEGIN { use_ok('Socialtext::EvHttp') };

use IO::Socket::INET;
my $socket = IO::Socket::INET->new(
    LocalAddr => 'localhost:10203',
    Proto => 'tcp',
    Listen => 1024,
    Blocking => 0,
);
ok $socket, "made listen socket";
ok $socket->fileno, "has a fileno";

my $evh = Socialtext::EvHttp->new();
use AnyEvent;

lives_ok {
    $evh->use_socket($socket);
} 'assigned socket';

dies_ok {
    $evh->request_handler('foo');
} "can't assign regular scalar";

my $cb;
{
    my $g = guard { pass "cv recycled"; };
    $cb = sub { $g = $g; fail "old callback" };
}

lives_ok {
    $evh->request_handler($cb);
} "can assign code block";

undef $cb;
pass "after undef cb";

$cb = sub {
    pass "called back!";
    my $r = shift;
    isa_ok $r, 'Socialtext::EvHttp::Client', 'got an object!';
#     use Devel::Peek();
#     Devel::Peek::Dump($r);
    my %env;
    $r->env(\%env);
    ok %env, "got env";
    like $env{HTTP_USER_AGENT}, qr/AnyEvent-HTTP/, "got anyevent-http's UA";
    my $utf8 = exists $env{HTTP_X_UNICODE_PLEASE};
    eval {
        $r->send_response("200 OK", [
            'Content-Type' => 'text/plain'.($utf8 ? '; charset=UTF-8' : ''),
            'Connection' => 'close',
            'X-Client' => 0+$$r,
            'Content-Length' => 666, # should be ignored
        ], $utf8 ? 'Bāz!' : 'Baz!');
    }; warn $@ if $@;
    pass "done request handler";
};

lives_ok {
    $evh->request_handler($cb);
} "can assign another code block";

use AnyEvent::HTTP;

my $cv = AE::cv;
$cv->begin;
my $w = http_get 'http://localhost:10203/?qqqqq', timeout => 3,
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, "client 1 got 200";
    like $headers->{'x-client'}, qr/^\d+$/, 'got a custom x-client header';
    is $headers->{'content-length'}, 4, 'content-length was overwritten by the engine';
    is $headers->{'content-type'}, 'text/plain';
    is $body, 'Baz!', 'plain old body';
    $cv->end;
};

$cv->begin;
my $w2 = http_get 'http://localhost:10203/?zzzzz',
    headers => {
        'X-Unicode-Please'=> 1,
    },
    timeout => 3,
sub {
    my ($body, $headers) = @_;
    is $headers->{Status}, 200, "client 2 got 200";
    like $headers->{'x-client'}, qr/^\d+$/, 'got a custom x-client header';
    is $headers->{'content-length'}, 5, 'content-length was overwritten by the engine';
    is $headers->{'content-type'}, 'text/plain; charset=UTF-8';
    is Encode::decode_utf8($body), 'Bāz!', 'unicode body!';
    $cv->end;
};

$cv->recv;
pass "all done";
