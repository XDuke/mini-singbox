#!/bin/sh
set -eu

[ -f "${MINI_SINGBOX_TEST_BINARY:-}" ] || {
	echo 'fake release curl: MINI_SINGBOX_TEST_BINARY is missing' >&2
	exit 1
}
[ -f "${MINI_SINGBOX_TEST_SUMS:-}" ] || {
	echo 'fake release curl: MINI_SINGBOX_TEST_SUMS is missing' >&2
	exit 1
}

output=""
url=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--output|-o)
			[ "$#" -ge 2 ] || exit 2
			output="$2"
			shift 2
			;;
		https://*) url="$1"; shift ;;
		*) shift ;;
	esac
done

[ -n "$output" ] && [ -n "$url" ] || {
	echo 'fake release curl: expected --output PATH and an HTTPS URL' >&2
	exit 2
}

case "$url" in
	*/mini-singbox-linux-amd64|*/mini-singbox-linux-arm64)
		cp "$MINI_SINGBOX_TEST_BINARY" "$output"
		;;
	*/SHA256SUMS)
		cp "$MINI_SINGBOX_TEST_SUMS" "$output"
		;;
	*)
		printf 'fake release curl: unexpected URL %s\n' "$url" >&2
		exit 1
		;;
esac
