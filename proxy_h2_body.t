#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.
# (C) Zhidao HONG

# Tests for HTTP/2 backend returning response.

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

my $t = Test::Nginx->new()->has(qw/http http_v2 proxy ssi/);

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

        add_trailer X-Stub "";

        location / {
            proxy_pass http://127.0.0.1:8081;
        }
        location /inmemory.html {
            ssi on;
        }
    }
}

EOF

$t->write_file('inmemory.html',
	'<!--#include virtual="/ssi" set="one" --><!--#echo var="one" -->');

$t->run_daemon(\&http_daemon);
$t->waitforsocket('127.0.0.1:' . port(8081));

$t->try_run('no proxy_http_version 2')->plan(16);

###############################################################################

like(http_get('/'), qr/\x0d\x0aSEE-THIS$/s, 'body');
like(http_get('/inmemory.html'), qr/\x0d\x0aSEE-THIS$/s, 'body inmemory');

like(http_get('/padding'), qr/\x0d\x0aSEE-THIS$/s, 'body padding');
like(http_get('/padding/cl'), qr/\x0d\x0aSEE-THIS$/s, 'body padding length');

# A malformed Content-Length must abort the response.  The delivered prefix
# depends on raw-buffer publication, so check closure, the protocol error,
# and the absence of a complete successful response instead of a fixed prefix.

for my $case ('less', 'more') {
	for my $version ('1.0', '1.1') {
		my $name = "body $case HTTP/$version";
		my $log = length $t->read_file('error.log');
		my $s = http(<<EOF, start => 1);
GET /$case HTTP/$version
Host: localhost
Connection: close

EOF

		my $r = $s ? http('', socket => $s) : undef;
		ok($s && !$s->opened(), "$name closed");
		like(substr($t->read_file('error.log'), $log),
			$case eq 'less' ? qr/upstream prematurely closed stream/
			: qr/upstream sent response body larger than indicated content length/,
			"$name protocol error");
		unlike($r || '', $version eq '1.0'
			? qr/^HTTP\/1\.[01] 200 .*\x0d\x0a\x0d\x0a.{8}/s
			: qr/^HTTP\/1\.[01] 200 .*\x0d\x0a0\x0d\x0a\x0d\x0a$/s,
			"$name incomplete");
	}
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

		if ($uri eq '/padding') {
			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '200' },
			]}, $sid);
			$c->h2_body('SEE-THIS', { body_padding => 42 });

		} elsif ($uri eq '/padding/cl') {
			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '200' },
				{ name => 'content-length', value => 8 },
			]}, $sid);
			$c->h2_body('SEE-THIS', { body_padding => 42 });

		} elsif ($uri =~ '/head') {
			$c->new_stream({ headers => [
				{ name => ':status', value => '200' },
				{ name => 'content-length', value => 8 },
			]}, $sid);

		} elsif ($uri =~ '/less') {
			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '200' },
				{ name => 'content-length', value => 8 },
			]}, $sid);
			$c->h2_body('SEE-', { body_more => 1 });
			select undef, undef, undef, 0.2;
			$c->h2_body('');

		} elsif ($uri =~ '/more') {
			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '200' },
				{ name => 'content-length', value => 8 },
			]}, $sid);
			$c->h2_body('SEE-', { body_more => 1 });
			select undef, undef, undef, 0.2;
			$c->h2_body('THIS-AND-THIS');

		} else {
			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '200' },
			]}, $sid);
			$c->h2_body('SEE-THIS');

		}
	}
}

###############################################################################
