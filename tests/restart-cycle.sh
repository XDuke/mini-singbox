#!/bin/sh
set -eu

IMAGE="${1:-}"
OUTPUT_DIRECTORY="${2:-}"
CYCLES="${3:-50}"

fail() {
	echo "restart-cycle: $*" >&2
	exit 1
}

[ -n "$IMAGE" ] && [ -n "$OUTPUT_DIRECTORY" ] || fail "usage: $0 IMAGE OUTPUT_DIRECTORY [CYCLES]"
case "$CYCLES" in *[!0-9]*|'') fail "cycles must be a positive integer" ;; esac
[ "$CYCLES" -gt 0 ] || fail "cycles must be greater than zero"
for command_name in docker date tee ls; do
	command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done
[ ! -d "$OUTPUT_DIRECTORY" ] || [ -z "$(ls -A "$OUTPUT_DIRECTORY")" ] || fail "evidence directory is not empty: $OUTPUT_DIRECTORY"
mkdir -p "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY="$(cd "$OUTPUT_DIRECTORY" && pwd)"
work_directory="$(mktemp -d)"
container_id=""
cleanup() {
	if [ -n "$container_id" ]; then docker rm -f "$container_id" >/dev/null 2>&1 || true; fi
	rm -rf "$work_directory"
}
trap cleanup EXIT HUP INT TERM

mkdir -m 0700 "$work_directory/config"
chown 65532:65532 "$work_directory/config"
docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
	-v "$work_directory/config:/output" "$IMAGE" generate --output /output \
	--protocols reality,hy2,anytls --listen 127.0.0.1 \
	--reality-server-name www.example.com --reality-handshake 192.0.2.1:443 --tls-san localhost \
	>"$OUTPUT_DIRECTORY/generate.log"

printf 'cycle\tstart_utc\tstop_utc\texit_code\n' >"$OUTPUT_DIRECTORY/cycles.tsv"
cycle=1
while [ "$cycle" -le "$CYCLES" ]; do
	start="$(date -u +%FT%TZ)"
	container_id="$(docker run -d --network none --read-only --cap-drop ALL \
		--security-opt no-new-privileges --pids-limit 64 --memory 128m --memory-swap 128m \
		-e GOMAXPROCS=1 -e GOMEMLIMIT=48MiB -e GOGC=70 \
		-v "$work_directory/config:/etc/mini-singbox:ro" "$IMAGE")"
	sleep 2
	test "$(docker inspect "$container_id" --format '{{.State.Running}}')" = true || fail "cycle $cycle exited before stop"
	docker stop --time 10 "$container_id" >/dev/null
	exit_code="$(docker inspect "$container_id" --format '{{.State.ExitCode}}')"
	stop="$(date -u +%FT%TZ)"
	printf '%s\t%s\t%s\t%s\n' "$cycle" "$start" "$stop" "$exit_code" >>"$OUTPUT_DIRECTORY/cycles.tsv"
	[ "$exit_code" -eq 0 ] || fail "cycle $cycle exit code $exit_code"
	docker rm "$container_id" >/dev/null
	container_id=""
	cycle=$((cycle + 1))
done

echo "restart-cycle PASS: $CYCLES clean SIGTERM start/stop cycles" | tee "$OUTPUT_DIRECTORY/summary.txt"
