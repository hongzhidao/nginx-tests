#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for HTTP/2 backend returning response with control frames.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v2 proxy/);

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        proxy_http_version 2;

        location / {
            proxy_pass http://127.0.0.1:8081;
        }
    }
}

EOF

$t->run_daemon(\&http_daemon);
$t->waitforsocket('127.0.0.1:' . port(8081));

$t->try_run('no proxy_http_version 2')->plan(11);

###############################################################################

# receiving response with various control frames

like(http_get('/window'), qr/\x0d\x0aSEE-THIS$/s, 'window update');
like(http_get('/noerror'), qr/\x0d\x0aSEE-THIS$/s,
	'rst no error after end stream');
like(http_get('/many'), qr/\x0d\x0aSEE-THIS$/s,
	'rst no error many after end stream');
like(http_get('/error'), qr/\x0d\x0aSEE-THIS$/s,
	'rst error after end stream');
like(http_get('/ping'), qr/\x0d\x0aSEE-THIS$/s, 'ping');

# a reset before END_STREAM must not complete the response;
# check the reset error and reject successful chunked response completion

for my $error ('noerror', 'error') {
	my $code = $error eq 'noerror' ? 0 : 8;
	my $log = length $t->read_file('error.log');
	my $s = http(<<EOF, start => 1);
GET /incomplete/$error HTTP/1.1
Host: localhost
Connection: close

EOF

	my $r = $s ? http('', socket => $s) : undef;
	ok($s && !$s->opened(), "rst $error response closed");
	like(substr($t->read_file('error.log'), $log),
		qr/upstream rejected request with error $code\b/,
		"rst $error incomplete response");
	unlike($r || '', qr/^HTTP\/1\.1 200 .*\x0d\x0a0\x0d\x0a\x0d\x0a$/s,
		"rst $error before end stream");
}

###############################################################################

sub http_daemon {
	my $client;
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalAddr => '127.0.0.1:' . port(8081),
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	while ($client = $server->accept()) {
		$client->autoflush(1);
		$client->sysread(my $buf, 24) == 24 or next; # preface

		my $c = Test::Nginx::HTTP2->new(1, socket => $client,
			pure => 1, preface => "") or next;

		$c->h2_settings(0);
		$c->h2_settings(1);

		my $frames = $c->read(all => [{ fin => 4 }]);
		my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
		my $sid = $frame->{sid};
		my $uri = $frame->{headers}{':path'};

		# the backend handles one request per connection

		$c->h2_goaway(0, $sid, 0);

		if ($uri eq '/window') {
			$c->start_chain();
			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '200' },
			]}, $sid);
			$c->h2_body('SEE-THIS');
			$c->h2_window(42, $sid);
			$c->send_chain();

		} elsif ($uri eq '/noerror') {
			$c->start_chain();
			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '200' },
			]}, $sid);
			$c->h2_body('SEE-THIS');
			$c->h2_rst($sid, 0);
			$c->send_chain();

		} elsif ($uri eq '/many') {
			$c->start_chain();
			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '200' },
			]}, $sid);
			$c->h2_body('SEE-THIS');
			$c->h2_rst($sid, 0);
			$c->h2_rst($sid, 0);
			$c->send_chain();

		} elsif ($uri eq '/error') {
			$c->start_chain();
			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '200' },
			]}, $sid);
			$c->h2_body('SEE-THIS');
			$c->h2_rst($sid, 8);
			$c->send_chain();

		} elsif ($uri =~ m{^/incomplete/(noerror|error)$}) {
			my $error = $1 eq 'noerror' ? 0 : 8;
			$c->start_chain();
			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '200' },
			]}, $sid);
			$c->h2_body('SEE-THIS', { body_more => 1 });
			$c->h2_rst($sid, $error);
			$c->send_chain();

		} elsif ($uri eq '/ping') {
			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '200' },
			]}, $sid);
			$c->h2_ping('SEE-THIS');
			$frames = $c->read(all => [{ type => 'PING' }]);
			($frame) = grep { $_->{type} eq "PING" } @$frames;
			$c->h2_body($frame->{value} || '');
		}
	}
}

###############################################################################
