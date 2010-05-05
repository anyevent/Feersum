#!perl
use warnings;
use strict;
use constant CLIENTS => 10;
use Test::More tests => 7 + 15 * CLIENTS;
use Test::Exception;
use Test::Differences;
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
        fail "Died during request handler: $err";
    };
}

my $cv = AE::cv;
my $started = 0;
my $finished = 0;
$evh->request_handler(sub {
    my $r = shift;
    isa_ok $r, 'Socialtext::EvHttp::Client', 'got an object!';
    my $env = {};
    $r->env($env);
    ok $env && ref($env) eq 'HASH';

    ok $env->{'psgi.streaming'}, 'got psgi.streaming';
    my $cnum = $env->{HTTP_X_CLIENT};
    ok $cnum, "got client number";

    dies_ok {
        $r->write("some junk");
    } "calling write too early is wrong $cnum";

    $cv->begin;
    my $cb = $r->initiate_streaming(sub {
        $started++;
        my $start = shift;
        is ref($start), 'CODE', "streaming handler got a code ref $cnum";
        my $w = $start->("200 OK", ['Content-Type' => 'text/plain']);
        ok blessed($w) && $w->can('write'),
            "after starting, writer can write $cnum";
        my $n = 0;
        my $t; $t = AE::timer rand(),rand(), sub {
            eval {
                ok blessed($w), "still blessed? $cnum";
                if ($n++ < 2) {
                    $w->write("Hello streaming world! chunk $n\n");
                    pass "wrote chunk $n $cnum";
                }
                else {
                    $w->write(undef);
                    pass "async writer finished $cnum";
                    dies_ok {
                        $w->write("after completion");
                    } "can't write after completion $cnum";
                    $finished++;
                    $cv->end;
                    undef $t; # important ref
                }
            }; if ($@) {
                warn "oshit $cnum $@";
            }
        };
    });
});

lives_ok {
    $evh->use_socket($socket);
} 'assigned socket';

my @got;
sub client {
    my $client_no = shift;
    my $data;
    $cv->begin;
    my $h1; $h1 = AnyEvent::Handle->new(
        connect => ["localhost", 10203],
        on_connect => sub {
            my $to_write = qq{GET /foo HTTP/1.1\nAccept: */*\nX-Client: $client_no\n\n};
            $to_write =~ s/\n/\015\012/smg;
            $h1->push_write($to_write);
            undef $to_write;
            $h1->on_read(sub {
#             diag "GOT $h1->{rbuf}";
                $data .= delete $h1->{rbuf};
            });
            $h1->on_eof(sub {
                $cv->end;
                push @got, $data;
            });
        },
    );
}


client($_) for (1..CLIENTS);

$cv->recv;
is $started, CLIENTS, 'handlers started';
is $finished, CLIENTS, 'handlers finished';

use Test::Differences;
my $expect = join("\015\012",
    "HTTP/1.1 200 OK",
    "Content-Type: text/plain",
    "Transfer-Encoding: chunked",
    "",
    "1f",
    "Hello streaming world! chunk 1\n",
    "1f",
    "Hello streaming world! chunk 2\n",
    "0"
);
$expect .= "\015\012\015\012";
for my $data (@got) {
    eq_or_diff $data, $expect, "got correctly formatted chunked encoding";
}

pass "all done";