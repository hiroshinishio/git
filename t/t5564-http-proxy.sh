#!/bin/sh

test_description="test fetching through http proxy"

TEST_PASSES_SANITIZE_LEAK=true
. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-httpd.sh

LIB_HTTPD_PROXY=1
start_httpd

test_expect_success 'setup repository' '
	test_commit foo &&
	git init --bare "$HTTPD_DOCUMENT_ROOT_PATH/repo.git" &&
	git push --mirror "$HTTPD_DOCUMENT_ROOT_PATH/repo.git"
'

setup_askpass_helper

# sanity check that our test setup is correctly using proxy
test_expect_success 'proxy requires password' '
	test_config_global http.proxy $HTTPD_DEST &&
	test_must_fail git clone $HTTPD_URL/smart/repo.git 2>err &&
	grep "error.*407" err
'

test_expect_success 'clone through proxy with auth' '
	test_when_finished "rm -rf clone" &&
	test_config_global http.proxy http://proxuser:proxpass@$HTTPD_DEST &&
	GIT_TRACE_CURL=$PWD/trace git clone $HTTPD_URL/smart/repo.git clone &&
	grep -i "Proxy-Authorization: Basic <redacted>" trace
'

test_expect_success 'clone can prompt for proxy password' '
	test_when_finished "rm -rf clone" &&
	test_config_global http.proxy http://proxuser@$HTTPD_DEST &&
	set_askpass nobody proxpass &&
	GIT_TRACE_CURL=$PWD/trace git clone $HTTPD_URL/smart/repo.git clone &&
	expect_askpass pass proxuser
'

start_socks() {
	mkfifo socks_output &&
	{
		"$PERL_PATH" "$TEST_DIRECTORY/socks4-proxy.pl" "$1" >socks_output &
		socks_pid=$!
	} &&
	read line <socks_output &&
	test "$line" = ready
}

test_expect_success PERL 'try to start SOCKS proxy' '
	# The %30 tests that the correct amount of percent-encoding is applied
	# to the proxy string passed to curl.
	if start_socks %30.sock
	then
		test_set_prereq SOCKS_PROXY
	fi
'

test_expect_success SOCKS_PROXY 'clone via Unix socket' '
	test_when_finished "rm -rf clone" &&
	test_config_global http.proxy "socks4://localhost$PWD/%2530.sock" && {
		{
			GIT_TRACE_CURL=$PWD/trace git clone "$HTTPD_URL/smart/repo.git" clone 2>err &&
			grep -i "SOCKS4 request granted." trace
		} ||
		grep "^fatal: libcurl 7\.84 or later" err
	}
'

test_expect_success SOCKS_PROXY 'stop SOCKS proxy' 'kill "$socks_pid"'

test_expect_success 'Unix socket requires socks*:' '
	! git clone -c http.proxy=localhost/path https://example.com/repo.git 2>err && {
		grep "^fatal: Invalid proxy URL '\''localhost/path'\'': only SOCKS proxies support paths" err ||
		grep "^fatal: libcurl 7\.84 or later" err
	}
'

test_expect_success 'Unix socket requires localhost' '
	! git clone -c http.proxy=socks4://127.0.0.1/path https://example.com/repo.git 2>err && {
		grep "^fatal: Invalid proxy URL '\''socks4://127\.0\.0\.1/path'\'': host must be localhost if a path is present" err ||
		grep "^fatal: libcurl 7\.84 or later" err
	}
'

test_done
