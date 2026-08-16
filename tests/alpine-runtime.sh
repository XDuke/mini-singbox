#!/bin/sh
set -eu

[ "$(id -u)" -eq 0 ] || {
	echo 'alpine runtime test must run as root' >&2
	exit 1
}
[ -f /etc/alpine-release ] || {
	echo 'alpine runtime test requires Alpine Linux' >&2
	exit 1
}

RUNTIME="${1:-}"
case "$RUNTIME" in external|openrc) ;; *) echo 'usage: alpine-runtime.sh external|openrc' >&2; exit 2 ;; esac

REPOSITORY="${MINI_SINGBOX_TEST_REPOSITORY:-/workspace}"
BINARY="${MINI_SINGBOX_TEST_BINARY:-/artifacts/mini-singbox-linux-amd64}"
[ -x "$BINARY" ] || {
	echo "test binary is unavailable: $BINARY" >&2
	exit 1
}

apk add --no-cache git >/dev/null
git config --global --add safe.directory "$REPOSITORY"
commit="$(git -C "$REPOSITORY" rev-parse HEAD)"
short_commit="$(printf '%s' "$commit" | cut -c1-12)"
version="candidate-$short_commit"
"$BINARY" version | grep -Fx "mini-singbox $version"
"$BINARY" version | grep -Fx "git_commit $commit"

test_root="$(mktemp -d /var/tmp/mini-singbox-alpine-test.XXXXXX)"
cleanup() {
	status=$?
	trap - EXIT HUP INT TERM
	if [ -f /run/mini-singbox/mini-singbox.pid ]; then
		pid="$(cat /run/mini-singbox/mini-singbox.pid 2>/dev/null || true)"
		case "$pid" in ''|*[!0-9]*) ;; *) kill -TERM "$pid" 2>/dev/null || true ;; esac
	fi
	case "$test_root" in /var/tmp/mini-singbox-alpine-test.*) rm -rf "$test_root" ;; esac
	exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

sums="$test_root/SHA256SUMS"
asset="mini-singbox-linux-amd64"
case "$(uname -m)" in aarch64) asset=mini-singbox-linux-arm64 ;; esac
printf '%s  %s\n' "$(sha256sum "$BINARY" | awk '{ print $1 }')" "$asset" > "$sums"
mkdir "$test_root/bin"
install -m 0755 "$REPOSITORY/tests/fake-release-curl.sh" "$test_root/bin/curl"

export PATH="$test_root/bin:$PATH"
export MINI_SINGBOX_TEST_BINARY="$BINARY"
export MINI_SINGBOX_TEST_SUMS="$sums"
export MINI_SINGBOX_RUNTIME="$RUNTIME"
export MINI_SINGBOX_RELEASE_TAG="$version"
export MINI_SINGBOX_AUTO_DETECT=0
export MINI_SINGBOX_AUTO_TUNE=0
export MINI_SINGBOX_PUBLIC_ADDRESS=203.0.113.10
export MINI_SINGBOX_REALITY_SERVER_NAME=www.example.com
export MINI_SINGBOX_REALITY_HANDSHAKE=www.example.com:443
export MINI_SINGBOX_TLS_SAN=203.0.113.10
export MINI_SINGBOX_REALITY_PORT=31001
export MINI_SINGBOX_HY2_PORT=31002
export MINI_SINGBOX_ANYTLS_PORT=31003

"$REPOSITORY/scripts/deploy.sh" > "$test_root/deploy.log"
grep -Fx "runtime=$RUNTIME" /etc/mini-singbox/deployment-info.txt
/usr/local/bin/mini-singbox check -c /etc/mini-singbox/config.json
test "$(stat -c '%a' /etc/mini-singbox/config.json)" = 600
test "$(stat -c '%a' /etc/mini-singbox/tls.key)" = 600

if [ "$RUNTIME" = openrc ]; then
	rc-service mini-singbox status
	rc-update show default | grep -F mini-singbox
	mini-singboxctl status > "$test_root/status.log"
	grep -Fq 'service:      active (openrc)' "$test_root/status.log"
	rc-service mini-singbox restart
	sleep 2
	rc-service mini-singbox status
	mini-singboxctl logs 10 >/dev/null
	PURGE=1 PURGE_BACKUPS=1 mini-singbox-uninstall >/dev/null
	test ! -e /etc/init.d/mini-singbox
	printf 'Alpine %s OpenRC deployment test passed\n' "$(cat /etc/alpine-release)"
	exit 0
fi

test -x /usr/local/bin/mini-singbox-run
test ! -f /var/lib/mini-singbox/tune/active.json
/usr/local/bin/mini-singbox-run > "$test_root/external.log" 2>&1 &
runner_pid=$!
attempt=0
while [ "$attempt" -lt 15 ] && ! mini-singboxctl status > "$test_root/status.log" 2>/dev/null; do
	attempt=$((attempt + 1))
	sleep 1
done
grep -Fq 'service:      active (external)' "$test_root/status.log"
if mini-singboxctl tune apply >/dev/null 2>&1; then
	echo 'external runtime unexpectedly allowed TCP tuning' >&2
	exit 1
fi
child_pid="$(cat /run/mini-singbox/mini-singbox.pid)"
test "$(ps -o user= -p "$child_pid" | awk '{$1=$1; print}')" = mini-singbox
kill -TERM "$child_pid"
wait "$runner_pid"
test ! -e /run/mini-singbox/mini-singbox.pid
mini-singboxctl certificate renew > "$test_root/renew.log"
grep -Fq 'Restart the surrounding supervisor' "$test_root/renew.log"
/usr/local/bin/mini-singbox-run > "$test_root/external-after-renew.log" 2>&1 &
runner_pid=$!
sleep 3
mini-singboxctl status >/dev/null
kill -TERM "$(cat /run/mini-singbox/mini-singbox.pid)"
wait "$runner_pid"
PURGE=1 PURGE_BACKUPS=1 mini-singbox-uninstall >/dev/null
test ! -e /usr/local/bin/mini-singbox
test ! -e /etc/mini-singbox
printf 'Alpine %s external-supervisor deployment test passed\n' "$(cat /etc/alpine-release)"
