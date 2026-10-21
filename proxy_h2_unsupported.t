#!/usr/bin/perl

# (C) Zhidao HONG

# Tests for unsupported response modes with HTTP/2 proxying.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v2 proxy cache rewrite/)->plan(16);

$t->write_file('error.log', '');

my @unsupported = (
	[ 'proxy_buffering off', 'proxy_buffering off;' ],
	[ 'proxy_cache', 'proxy_cache NAME;' ],
	[ 'proxy_limit_rate', 'proxy_limit_rate 1k;' ],
);

###############################################################################

# Validate direct settings and inheritance into a variable proxy_pass.

for my $scope ('direct', 'inherited') {
	for my $case (@unsupported) {
		my ($name, $directive) = @$case;
		my $settings = "proxy_http_version 2;\n        $directive";
		if ($scope eq 'direct') {
			config($t, '', $settings, 'http://127.0.0.1:8081');
		} else {
			config($t, $settings, '', 'http://$backend');
		}

		my $output = $t->dump_config();
		isnt($?, 0, "$scope $name rejected");
		like($output,
			qr/"\Q$name\E" is not supported with "proxy_http_version 2"/,
			"$scope $name diagnostic");
	}
}

# The restrictions are specific to HTTP/2 proxying.

for my $case (@unsupported) {
	my ($name, $directive) = @$case;
	config($t, '', "proxy_http_version 1.1;\n        $directive",
		'http://127.0.0.1:8081');
	my $output = $t->dump_config();
	is($?, 0, "HTTP/1.1 $name allowed") or diag($output);
}

# Disabled cache/rate limiting and streaming request bodies remain valid.

config($t, '', <<'EOF', 'http://$backend');
proxy_http_version 2;
proxy_buffering on;
proxy_cache off;
proxy_limit_rate 0;
proxy_request_buffering off;
EOF

my $output = $t->dump_config();
is($?, 0, 'buffered HTTP/2 with streaming request body allowed') or diag($output);

###############################################################################

sub config {
	my ($t, $server, $location, $pass) = @_;

	$t->write_file_expand('nginx.conf', <<EOF);

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path %%TESTDIR%%/cache keys_zone=NAME:1m;

    server {
        listen 127.0.0.1:8080;
        server_name localhost;

        set \$backend 127.0.0.1:8081;
        $server

        location / {
            $location
            proxy_pass $pass;
        }
    }
}

EOF
}

###############################################################################
