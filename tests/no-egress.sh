#!/bin/sh
set -eu

BINARY="${1:-./mini-singbox}"
OUTPUT_DIRECTORY="${2:-}"
DURATION="${3:-600}"

fail() {
	echo "no-egress: $*" >&2
	exit 1
}

[ "$(id -u)" -eq 0 ] || fail "run as root so a private network namespace can be created"
[ -x "$BINARY" ] || fail "binary is not executable: $BINARY"
[ -n "$OUTPUT_DIRECTORY" ] || fail "usage: $0 BINARY OUTPUT_DIRECTORY [DURATION_SECONDS]"
case "$DURATION" in *[!0-9]*|'') fail "duration must be a positive integer" ;; esac
[ "$DURATION" -gt 0 ] || fail "duration must be greater than zero"
for command_name in ip tcpdump timeout strace ss awk wc date grep tr; do
	command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

BINARY="$(cd "$(dirname "$BINARY")" && pwd)/$(basename "$BINARY")"
[ ! -e "$OUTPUT_DIRECTORY" ] || fail "refusing to overwrite evidence directory: $OUTPUT_DIRECTORY"
mkdir -m 0700 "$OUTPUT_DIRECTORY"
work_directory="$(cd "$OUTPUT_DIRECTORY" && pwd)"
namespace="mini-singbox-no-egress-$$"
capture_pid=""

cleanup() {
	if [ -n "$capture_pid" ]; then
		kill -INT "$capture_pid" 2>/dev/null || true
		wait "$capture_pid" 2>/dev/null || true
	fi
	ip netns delete "$namespace" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

ip netns add "$namespace"
ip -n "$namespace" link set lo up
ip netns exec "$namespace" tcpdump -U -n -i any -w "$work_directory/idle.pcap" >"$work_directory/tcpdump.log" 2>&1 &
capture_pid=$!
sleep 1

ip netns exec "$namespace" strace -f -qq -e trace=network -o "$work_directory/version.strace" \
	"$BINARY" version >"$work_directory/version.log"

for protocols in reality hy2 anytls reality,hy2,anytls; do
	case "$protocols" in
		reality) extra="--reality-server-name www.example.com --reality-handshake 192.0.2.1:443" ;;
		hy2|anytls) extra="--tls-san localhost" ;;
		*) extra="--reality-server-name www.example.com --reality-handshake 192.0.2.1:443 --tls-san localhost" ;;
	esac
	output="$work_directory/$(echo "$protocols" | tr ',' '-')"
	mkdir -m 0700 "$output"
	# shellcheck disable=SC2086
	ip netns exec "$namespace" strace -f -qq -e trace=network -o "$output/generate.strace" \
		"$BINARY" generate --output "$output" --protocols "$protocols" --listen 127.0.0.1 $extra >"$output/generate.log"
	ip netns exec "$namespace" strace -f -qq -e trace=network -o "$output/check.strace" "$BINARY" check -c "$output/config.json" >"$output/check.log"
	if grep -E 'connect\(|sendto\(|sendmsg\(|bind\(|listen\(' "$output/generate.strace" "$output/check.strace"; then
		fail "$protocols generate or check performed a forbidden network operation"
	fi
done

if grep -E 'connect\(|sendto\(|sendmsg\(|bind\(|listen\(' "$work_directory/version.strace"; then
	fail "version performed a forbidden network operation"
fi

for protocols in reality hy2 anytls reality-hy2-anytls; do
	output="$work_directory/$protocols"
	start_time="$(date -u +%FT%TZ)"
	set +e
	ip netns exec "$namespace" timeout --signal=TERM --kill-after=10s "$DURATION" \
		strace -f -qq -e trace=connect,sendto,sendmsg -o "$output/idle.strace" \
		"$BINARY" run -c "$output/config.json" >"$output/run.log" 2>&1
	status=$?
	set -e
	[ "$status" -eq 124 ] || fail "$protocols idle run exited early with status $status (started $start_time)"
	if grep -E 'connect\(|sendto\(|sendmsg\(' "$output/idle.strace"; then
		fail "$protocols attempted an outbound network operation while idle"
	fi
done

ss_output="$(ip netns exec "$namespace" ss -H -ntup state established || true)"
[ -z "$ss_output" ] || fail "established socket found after idle runs: $ss_output"
kill -INT "$capture_pid"
wait "$capture_pid" || true
capture_pid=""
packet_count="$(tcpdump -n -r "$work_directory/idle.pcap" 2>/dev/null | wc -l | awk '{print $1}')"
[ "$packet_count" -eq 0 ] || fail "captured $packet_count packets in the isolated namespace"

echo "no-egress PASS: version, generate, check, and four idle protocol sets; duration=${DURATION}s each; packets=0"
echo "Evidence is retained in $work_directory; generated test credentials must not be published."
