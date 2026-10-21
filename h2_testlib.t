#!/usr/bin/perl

# (C) Zhidao HONG

# Tests for HTTP/2 fixture flow control and pending frame delivery.

###############################################################################

use warnings;
use strict;

use Test::More;
use IO::Select;
use IO::Socket;
use Socket qw/ AF_UNIX SOCK_STREAM PF_UNSPEC /;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx::HTTP2;

###############################################################################

my ($socket, $peer) = IO::Socket->socketpair(AF_UNIX, SOCK_STREAM, PF_UNSPEC)
	or plan(skip_all => 'socketpair not available');

my $c = Test::Nginx::HTTP2->new(1, socket => $socket, pure => 1, preface => '');

# Exhaust the connection window on the wire before testing incremental credit.

$c->new_stream({ body_more => 1 });
frame($peer);
my $sent = 0;
for my $length (16384, 16384, 16384, 16383) {
	$c->h2_body('x' x $length, { body_more => 1 });
	$sent += frame($peer)->{length};
}
is($sent, 65535, 'connection window exhausted');

$peer->syswrite(pack('x2C3NnN', 6, 4, 0, 0, 4, 0));
is($c->read()->[0]->{4}, 0, 'zero initial stream window');

$c->start_chain();
$c->new_stream({ body_more => 1 });

# A SETTINGS ACK and another stream's credit precede several updates needed
# by this send.  Padding consumes credit in both windows as well.

$peer->syswrite(pack('x2C3N', 0, 4, 1, 0)
	. window(8, 1) . window(3, 3) . window(4, 0)
	. window(5, 3) . window(4, 0));
$c->h2_body('DATA', { body_padding => 3 });
is(frame($peer)->{type}, 1, 'queued HEADERS flushed before waiting');
ok(!IO::Select->new($peer)->can_read(0), 'DATA remains chained');
$c->h2_ping('tailtail');
$c->send_chain();

my $data = frame($peer);
is_deeply($data, { type => 0, flags => 9, sid => 3, length => 8,
	body => "\3DATA\0\0\0" }, 'padded DATA sent with accumulated credit');
is(frame($peer)->{body}, 'tailtail', 'chained control frame follows DATA');

my @frames = map { $c->read()->[0] } 1 .. 6;
is_deeply([map { [$_->{type}, $_->{sid}, $_->{flags}, $_->{wdelta}] } @frames],
	[['SETTINGS', 0, 1, undef], ['WINDOW_UPDATE', 1, 0, 8],
	 ['WINDOW_UPDATE', 3, 0, 3], ['WINDOW_UPDATE', 0, 0, 4],
	 ['WINDOW_UPDATE', 3, 0, 5], ['WINDOW_UPDATE', 0, 0, 4]],
	'frames consumed by flow control delivered in wire order');
is($c->{conn_window}, 0, 'queued connection credit applied once');
is($c->{streams}{3}, 0, 'queued stream credit applied once');

$peer->syswrite(pack('x2C3Na8', 8, 6, 1, 0, 'freshone'));
is($c->read()->[0]->{value}, 'freshone', 'read resumes after pending frames');

# Zero-length DATA must not wait for credit, even with a zero connection window.

$c->new_stream({ body_more => 1 });
frame($peer);
$c->h2_body('');
is_deeply(frame($peer), { type => 0, flags => 1, sid => 5, length => 0,
	body => '' }, 'empty END_STREAM at zero credit');

# A reset terminates the wait and is still reported to the fixture.

$c->new_stream({ body_more => 1 });
frame($peer);
$peer->syswrite(pack('x2C3NN', 4, 3, 0, 7, 8));
$c->h2_body('unsent');
ok(!IO::Select->new($peer)->can_read(0), 'no DATA after reset while waiting');
is($c->read()->[0]->{code}, 8, 'reset preserved for reader');

# Every explicitly split DATA frame has its own padding overhead.

$c->new_stream({ body_more => 1 });
frame($peer);
$peer->syswrite(window(10, 0) . window(10, 9));
$c->h2_body('ABCD', { body_split => [2], body_padding => 2 });
is_deeply(frame($peer), { type => 0, flags => 8, sid => 9, length => 5,
	body => "\2AB\0\0" }, 'first padded body fragment');
is_deeply(frame($peer), { type => 0, flags => 9, sid => 9, length => 5,
	body => "\2CD\0\0" }, 'last padded body fragment');
is($c->{conn_window}, 0, 'all fragment padding charged to connection');
is($c->{streams}{9}, 0, 'all fragment padding charged to stream');

done_testing();

###############################################################################

sub window {
	my ($delta, $sid) = @_;
	return pack('x2C3NN', 4, 8, 0, $sid, $delta);
}

sub frame {
	my ($socket) = @_;
	my $header = read_bytes($socket, 9);
	my $length = unpack('N', "\0" . substr($header, 0, 3));
	my ($type, $flags, $sid) = unpack('x3CCN', $header);
	return { length => $length, type => $type, flags => $flags, sid => $sid,
		body => read_bytes($socket, $length) };
}

sub read_bytes {
	my ($socket, $length) = @_;
	my $buf = '';
	while (length($buf) < $length) {
		IO::Select->new($socket)->can_read(1) or die 'frame read timeout';
		$socket->sysread(my $part, $length - length($buf)) or die 'frame EOF';
		$buf .= $part;
	}
	return $buf;
}

###############################################################################
