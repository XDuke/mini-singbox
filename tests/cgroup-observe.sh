#!/bin/sh
set -eu

IMAGE="${1:-}"
OUTPUT_DIRECTORY="${2:-}"
DURATION="${3:-1800}"
INTERVAL="${4:-10}"

fail() {
	echo "cgroup-observe: $*" >&2
	exit 1
}

[ -n "$IMAGE" ] || fail "usage: $0 IMAGE OUTPUT_DIRECTORY [DURATION_SECONDS] [INTERVAL_SECONDS]"
[ -n "$OUTPUT_DIRECTORY" ] || fail "an evidence output directory is required"
[ "$(id -u)" -eq 0 ] || fail "run as root to read process and cgroup metrics"
case "$DURATION:$INTERVAL" in *[!0-9:]*|:*|*:) fail "duration and interval must be positive integers" ;; esac
[ "$DURATION" -gt 0 ] && [ "$INTERVAL" -gt 0 ] || fail "duration and interval must be greater than zero"
for command_name in docker awk date uname stat find wc nsenter ss cp cat tee ls; do
	command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done
test "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs || fail "cgroup v2 is required"

[ ! -d "$OUTPUT_DIRECTORY" ] || [ -z "$(ls -A "$OUTPUT_DIRECTORY")" ] || fail "evidence directory is not empty: $OUTPUT_DIRECTORY"
mkdir -p "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY="$(cd "$OUTPUT_DIRECTORY" && pwd)"
work_directory="$(mktemp -d)"
container_id=""

cleanup() {
	if [ -n "$container_id" ]; then
		docker rm -f "$container_id" >/dev/null 2>&1 || true
	fi
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

container_id="$(docker run -d --network none --read-only --cap-drop ALL \
	--security-opt no-new-privileges --pids-limit 64 --memory 128m --memory-swap 128m \
	-e GOMAXPROCS=1 -e GOMEMLIMIT=48MiB -e GOGC=70 \
	-e GODEBUG=gctrace=1,schedtrace=60000,scheddetail=1 \
	-v "$work_directory/config:/etc/mini-singbox:ro" "$IMAGE")"
pid="$(docker inspect "$container_id" --format '{{.State.Pid}}')"
cgroup_relative="$(awk -F: '$1 == "0" {print $3}' "/proc/$pid/cgroup")"
cgroup_directory="/sys/fs/cgroup$cgroup_relative"
[ -r "$cgroup_directory/memory.current" ] || fail "cannot read cgroup memory metrics at $cgroup_directory"

{
	echo "timestamp=$(date -u +%FT%TZ)"
	echo "kernel=$(uname -srvmo)"
	echo "architecture=$(uname -m)"
	echo "cpu=$(awk -F: '/model name/ {sub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo)"
	echo "docker=$(docker version --format '{{.Server.Version}}')"
	echo "image=$IMAGE"
	echo "image_id=$(docker image inspect "$IMAGE" --format '{{.Id}}')"
	echo "image_repo_digests=$(docker image inspect "$IMAGE" --format '{{join .RepoDigests ","}}')"
	echo "container=$container_id"
	echo "pid=$pid"
	echo "cgroup=$cgroup_relative"
	docker run --rm --network none "$IMAGE" version
} >"$OUTPUT_DIRECTORY/environment.txt"

printf 'timestamp\trss_kib\tpss_kib\tfd\tthreads\tmemory_current\tmemory_peak\tsock\ttcp_established\tudp_sockets\n' >"$OUTPUT_DIRECTORY/samples.tsv"
end_time=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$end_time" ]; do
	timestamp="$(date -u +%FT%TZ)"
	rss="$(awk '/VmRSS:/ {print $2}' "/proc/$pid/status")"
	pss="$(awk '/^Pss:/ {print $2}' "/proc/$pid/smaps_rollup" 2>/dev/null || echo unavailable)"
	fd_count="$(find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | awk '{print $1}')"
	threads="$(awk '/^Threads:/ {print $2}' "/proc/$pid/status")"
	memory_current="$(cat "$cgroup_directory/memory.current")"
	memory_peak="$(cat "$cgroup_directory/memory.peak")"
	sock="$(awk '$1 == "sock" {print $2}' "$cgroup_directory/memory.stat")"
	tcp_count="$(nsenter -t "$pid" -n ss -H -nt state established 2>/dev/null | wc -l | awk '{print $1}')"
	udp_count="$(nsenter -t "$pid" -n ss -H -uap 2>/dev/null | wc -l | awk '{print $1}')"
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$timestamp" "$rss" "$pss" "$fd_count" "$threads" "$memory_current" "$memory_peak" "$sock" "$tcp_count" "$udp_count" >>"$OUTPUT_DIRECTORY/samples.tsv"
	sleep "$INTERVAL"
done

cp "$cgroup_directory/memory.events" "$OUTPUT_DIRECTORY/memory.events"
cp "$cgroup_directory/memory.stat" "$OUTPUT_DIRECTORY/memory.stat.final"
docker stop --time 10 "$container_id" >"$OUTPUT_DIRECTORY/stop.log"
test "$(docker inspect "$container_id" --format '{{.State.ExitCode}}')" = 0 || fail "container did not stop cleanly"
docker logs "$container_id" >"$OUTPUT_DIRECTORY/runtime-metrics.log" 2>&1
docker inspect "$container_id" >"$OUTPUT_DIRECTORY/container-inspect.json"
docker rm "$container_id" >/dev/null
container_id=""

awk -F '\t' 'NR > 1 {if ($2 > rss) rss=$2; if ($6 > current) current=$6; if ($7 > peak) peak=$7; if ($8 > sock) sock=$8} END {printf "max_rss_kib=%d\nmax_memory_current=%d\nmax_memory_peak=%d\nmax_sock=%d\n", rss, current, peak, sock}' "$OUTPUT_DIRECTORY/samples.tsv" | tee "$OUTPUT_DIRECTORY/summary.txt"
