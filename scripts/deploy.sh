#!/bin/sh
set -eu

SERVICE="mini-singbox.service"
OPENRC_SERVICE="mini-singbox"
SERVICE_USER="mini-singbox"
INSTALL_PATH="/usr/local/bin/mini-singbox"
CONTROL_PATH="/usr/local/bin/mini-singboxctl"
CONTAINER_CONTROL_PATH="/usr/local/bin/mini-singbox-containerctl"
UPDATE_PATH="/usr/local/bin/mini-singbox-update"
UNINSTALL_PATH="/usr/local/bin/mini-singbox-uninstall"
EXTERNAL_RUN_PATH="/usr/local/bin/mini-singbox-run"
CONFIG_DIR="/etc/mini-singbox"
SYSTEMD_UNIT_PATH="/etc/systemd/system/mini-singbox.service"
OPENRC_UNIT_PATH="/etc/init.d/mini-singbox"
OPENRC_LOG_DIR="/var/log/mini-singbox"
OPENRC_LOG_PATH="$OPENRC_LOG_DIR/service.log"
EXTERNAL_PID_FILE="/run/mini-singbox/mini-singbox.pid"
BACKUP_ROOT="/var/backups/mini-singbox"
REPOSITORY="XDuke/mini-singbox"

log() {
	printf '\n==> %s\n' "$*"
}

warn() {
	printf 'WARNING: %s\n' "$*" >&2
}

fail() {
	printf 'mini-singbox deploy: %s\n' "$*" >&2
	exit 1
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

find_supports_printf() {
	command_exists find && find / -maxdepth 0 -printf '' >/dev/null 2>&1
}

ps_supports_pid_filter() {
	command_exists ps && ps -o pid= -p "$$" >/dev/null 2>&1
}

running_in_container() {
	[ -f /.dockerenv ] || [ -f /run/.containerenv ] || \
		grep -Eqi '(docker|podman|lxc|openvz|containerd)' /proc/1/cgroup /proc/self/cgroup 2>/dev/null
}

openrc_is_running() {
	command_exists rc-service || return 1
	command_exists rc-update || return 1
	command_exists rc-status || return 1
	[ -d /run/openrc ] || return 1
	[ -r /proc/1/comm ] || return 1
	case "$(cat /proc/1/comm 2>/dev/null)" in
		init|openrc-init) ;;
		*) return 1 ;;
	esac
	rc-status >/dev/null 2>&1
}

detect_runtime() {
	case "$RUNTIME_REQUESTED" in
		auto|systemd|openrc|external) ;;
		*) fail "MINI_SINGBOX_RUNTIME must be auto, systemd, openrc, or external" ;;
	esac
	if [ "$RUNTIME_REQUESTED" != auto ]; then
		printf '%s\n' "$RUNTIME_REQUESTED"
		return 0
	fi
	if command_exists systemctl && [ -d /run/systemd/system ]; then
		printf 'systemd\n'
	elif openrc_is_running; then
		printf 'openrc\n'
	elif running_in_container; then
		printf 'external\n'
	else
		fail "no supported runtime detected; set MINI_SINGBOX_RUNTIME=external when another supervisor owns the process"
	fi
}

external_pid() {
	if [ ! -f "$EXTERNAL_PID_FILE" ] || [ -L "$EXTERNAL_PID_FILE" ]; then
		return 1
	fi
	pid="$(cat "$EXTERNAL_PID_FILE" 2>/dev/null || true)"
	case "$pid" in ''|*[!0-9]*|0) return 1 ;; esac
	kill -0 "$pid" 2>/dev/null || return 1
	printf '%s\n' "$pid"
}

runtime_is_active() {
	case "$RUNTIME" in
		systemd) systemctl is-active --quiet "$SERVICE" ;;
		openrc) rc-service "$OPENRC_SERVICE" status >/dev/null 2>&1 ;;
		external) external_pid >/dev/null ;;
	esac
}

runtime_is_enabled() {
	case "$RUNTIME" in
		systemd) systemctl is-enabled --quiet "$SERVICE" ;;
		openrc) rc-update show default 2>/dev/null | awk '$1 == "mini-singbox" { found = 1 } END { exit !found }' ;;
		external) return 1 ;;
	esac
}

runtime_main_pid() {
	case "$RUNTIME" in
		systemd) systemctl show "$SERVICE" -p MainPID --value ;;
		openrc)
			pgrep -o -u "$SERVICE_USER" mini-singbox 2>/dev/null || true
			;;
		external) external_pid || true ;;
	esac
}

runtime_stop() {
	case "$RUNTIME" in
		systemd) systemctl stop "$SERVICE" ;;
		openrc) rc-service "$OPENRC_SERVICE" stop ;;
		external) return 0 ;;
	esac
}

runtime_start() {
	case "$RUNTIME" in
		systemd) systemctl start "$SERVICE" ;;
		openrc) rc-service "$OPENRC_SERVICE" start ;;
		external) return 0 ;;
	esac
}

runtime_restart() {
	case "$RUNTIME" in
		systemd) systemctl restart "$SERVICE" ;;
		openrc) rc-service "$OPENRC_SERVICE" restart ;;
		external) return 0 ;;
	esac
}

runtime_enable() {
	case "$RUNTIME" in
		systemd) systemctl enable "$SERVICE" >/dev/null ;;
		openrc) rc-update add "$OPENRC_SERVICE" default >/dev/null ;;
		external) return 0 ;;
	esac
}

runtime_disable() {
	case "$RUNTIME" in
		systemd) systemctl disable "$SERVICE" >/dev/null 2>&1 || true ;;
		openrc) rc-update del "$OPENRC_SERVICE" default >/dev/null 2>&1 || true ;;
		external) return 0 ;;
	esac
}

runtime_reload() {
	if [ "$RUNTIME" = systemd ]; then
		systemctl daemon-reload >/dev/null 2>&1 || true
	fi
}

runtime_recent_logs() {
	case "$RUNTIME" in
		systemd) journalctl -u "$SERVICE" -n 50 --no-pager >&2 || true ;;
		openrc)
			if command_exists logread; then
				logread 2>/dev/null | grep 'mini-singbox' | tail -n 50 >&2 || true
			else
				rc-service "$OPENRC_SERVICE" status >&2 || true
			fi
			;;
		external) warn "external runtime logs are owned by the surrounding supervisor" ;;
	esac
}

prune_managed_backups() {
	unsorted_list="$WORK_DIR/managed-backups.unsorted"
	managed_list="$WORK_DIR/managed-backups.txt"
	candidate_list="$WORK_DIR/managed-backup-candidates.txt"
	current_name="${BACKUP_DIR#"$BACKUP_ROOT/"}"
	if ! find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
		-printf '%f\n' > "$unsorted_list"; then
		warn "could not enumerate deployment backups; retention was not changed"
		return 0
	fi
	grep -E '^20[0-9]{6}T[0-9]{6}Z-[0-9a-f]{12}-[0-9]+$' "$unsorted_list" | \
		LC_ALL=C sort > "$managed_list"
	managed_count="$(awk 'END { print NR + 0 }' "$managed_list")"
	if [ "$managed_count" -le "$BACKUP_KEEP" ]; then
		return 0
	fi
	remove_count=$((managed_count - BACKUP_KEEP))
	grep -Fvx "$current_name" "$managed_list" > "$candidate_list" || true
	log "Pruning $remove_count old managed deployment backup(s); keeping $BACKUP_KEEP"
	head -n "$remove_count" "$candidate_list" | while IFS= read -r backup_name; do
		if ! printf '%s\n' "$backup_name" | \
			grep -Eq '^20[0-9]{6}T[0-9]{6}Z-[0-9a-f]{12}-[0-9]+$'; then
			warn "ignoring unrecognized backup directory name: $backup_name"
			continue
		fi
		backup_path="$BACKUP_ROOT/$backup_name"
		case "$backup_path" in
			/var/backups/mini-singbox/20*) ;;
			*) warn "refusing unsafe backup path: $backup_path"; continue ;;
		esac
		if ! rm -rf -- "$backup_path"; then
			warn "could not remove old deployment backup: $backup_path"
		fi
	done
}

[ "$(id -u)" -eq 0 ] || fail "run as root (use sudo env ... ./scripts/deploy.sh)"
[ "$(uname -s)" = "Linux" ] || fail "this deployer supports Linux only"
RUNTIME_REQUESTED="${MINI_SINGBOX_RUNTIME:-auto}"
RUNTIME="$(detect_runtime)"
CONTAINERIZED=0
if running_in_container; then
	CONTAINERIZED=1
fi
case "$RUNTIME" in
	systemd)
		command_exists systemctl || fail "systemd runtime was selected but systemctl is unavailable"
		[ -d /run/systemd/system ] || fail "systemd runtime was selected but is not running"
		;;
	openrc)
		openrc_is_running || fail "OpenRC runtime was selected but OpenRC is not the active PID 1 service manager"
		;;
	external) running_in_container || warn "external runtime selected outside a detected container; another supervisor must own the process" ;;
esac

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
BUNDLE_DIR="${MINI_SINGBOX_BUNDLE_DIR:-}"
VERIFY_BUNDLE_FILES=0
if [ -n "$BUNDLE_DIR" ]; then
	SOURCE_DIR="$(CDPATH='' cd -- "$BUNDLE_DIR" && pwd -P)"
	CONTROL_SOURCE="$SOURCE_DIR/mini-singboxctl"
	CONTAINER_CONTROL_SOURCE="$SOURCE_DIR/mini-singbox-containerctl"
	UPDATE_SOURCE="$SOURCE_DIR/bootstrap.sh"
	UNINSTALL_SOURCE="$SOURCE_DIR/uninstall.sh"
	SYSTEMD_UNIT_SOURCE="$SOURCE_DIR/mini-singbox.service"
	SYSTEMD_CONTAINER_UNIT_SOURCE="$SOURCE_DIR/mini-singbox-container.service"
	OPENRC_UNIT_SOURCE="$SOURCE_DIR/mini-singbox"
	EXTERNAL_RUN_SOURCE="$SOURCE_DIR/mini-singbox-run"
	BUNDLE_MANIFEST="$SOURCE_DIR/SHA256SUMS"
	SOURCE_COMMIT="${MINI_SINGBOX_SOURCE_COMMIT:-}"
	RELEASE_TAG="${MINI_SINGBOX_RELEASE_TAG:-}"
	VERIFY_BUNDLE_FILES=1
else
	SOURCE_DIR="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)"
	[ -f "$SOURCE_DIR/go.mod" ] || fail "go.mod not found next to the deployment script"
	CONTROL_SOURCE="$SOURCE_DIR/scripts/mini-singboxctl"
	CONTAINER_CONTROL_SOURCE="$SOURCE_DIR/scripts/mini-singbox-containerctl"
	UPDATE_SOURCE="$SOURCE_DIR/bootstrap.sh"
	UNINSTALL_SOURCE="$SOURCE_DIR/scripts/uninstall.sh"
	SYSTEMD_UNIT_SOURCE="$SOURCE_DIR/packaging/systemd/mini-singbox.service"
	SYSTEMD_CONTAINER_UNIT_SOURCE="$SOURCE_DIR/packaging/systemd/mini-singbox-container.service"
	OPENRC_UNIT_SOURCE="$SOURCE_DIR/packaging/openrc/mini-singbox"
	EXTERNAL_RUN_SOURCE="$SOURCE_DIR/packaging/external/mini-singbox-run"
	command_exists git || fail "git is required when deploy.sh is run from a source checkout"
	git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "run this script from a Git checkout"
	[ -z "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=no)" ] || \
		fail "tracked source files are modified; commit or restore them before deployment"
	SOURCE_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
	SHORT_COMMIT="$(printf '%s' "$SOURCE_COMMIT" | cut -c1-12)"
	EXACT_RELEASE_TAG="$(git -C "$SOURCE_DIR" tag --points-at "$SOURCE_COMMIT" | \
		grep -E '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$' | \
		sort -V | tail -n 1 || true)"
	RELEASE_TAG="${MINI_SINGBOX_RELEASE_TAG:-${EXACT_RELEASE_TAG:-candidate-$SHORT_COMMIT}}"
fi

printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || fail "source commit must be a full hexadecimal Git commit"
SHORT_COMMIT="$(printf '%s' "$SOURCE_COMMIT" | cut -c1-12)"
MINISIGN_PUBLIC_KEY="${MINI_SINGBOX_MINISIGN_PUBKEY_FILE:-$SOURCE_DIR/release/minisign.pub}"
SIGNED_RELEASE=0
case "$RELEASE_TAG" in
	v[0-9]*.[0-9]*.[0-9]*) SIGNED_RELEASE=1 ;;
	"candidate-$SHORT_COMMIT") ;;
	*) fail "release tag must be a stable version or candidate-$SHORT_COMMIT" ;;
esac
if [ -z "$BUNDLE_DIR" ] && [ "$SIGNED_RELEASE" -eq 1 ]; then
	[ "$RELEASE_TAG" = "$EXACT_RELEASE_TAG" ] || \
		fail "release tag $RELEASE_TAG does not point at source commit $SOURCE_COMMIT"
fi
if [ -n "$BUNDLE_DIR" ]; then
	if [ ! -f "$BUNDLE_MANIFEST" ] || [ -L "$BUNDLE_MANIFEST" ]; then
		fail "bundle checksum manifest is missing or unsafe"
	fi
fi

case "$RUNTIME" in
	systemd)
		UNIT_SOURCE="$SYSTEMD_UNIT_SOURCE"
		UNIT_PATH="$SYSTEMD_UNIT_PATH"
		UNIT_PROFILE="full"
		if command_exists systemd-detect-virt && systemd-detect-virt --container --quiet; then
			UNIT_SOURCE="$SYSTEMD_CONTAINER_UNIT_SOURCE"
			UNIT_PROFILE="container-compatible"
			warn "container virtualization detected; using the container-compatible systemd sandbox"
		fi
		;;
	openrc)
		UNIT_SOURCE="$OPENRC_UNIT_SOURCE"
		UNIT_PATH="$OPENRC_UNIT_PATH"
		UNIT_PROFILE="openrc"
		if [ "$CONTAINERIZED" -eq 1 ]; then
			UNIT_PROFILE="openrc-container"
			warn "containerized OpenRC detected; OpenRC will own the service while host TCP tuning stays disabled"
		fi
		;;
	external) UNIT_SOURCE="$EXTERNAL_RUN_SOURCE"; UNIT_PATH="$EXTERNAL_RUN_PATH"; UNIT_PROFILE="external-supervisor" ;;
esac
for required_source in "$CONTROL_SOURCE" "$CONTAINER_CONTROL_SOURCE" "$UPDATE_SOURCE" "$UNINSTALL_SOURCE" "$UNIT_SOURCE" "$EXTERNAL_RUN_SOURCE"; do
	if [ ! -f "$required_source" ] || [ -L "$required_source" ]; then
		fail "required deployment asset is missing or unsafe: $required_source"
	fi
done

PROTOCOLS="${MINI_SINGBOX_PROTOCOLS:-reality,hy2,anytls}"
LISTEN_ADDRESS="${MINI_SINGBOX_LISTEN:-::}"
REALITY_PORT="${MINI_SINGBOX_REALITY_PORT:-20001}"
HY2_PORT="${MINI_SINGBOX_HY2_PORT:-20002}"
ANYTLS_PORT="${MINI_SINGBOX_ANYTLS_PORT:-20003}"
REALITY_SERVER_NAME="${MINI_SINGBOX_REALITY_SERVER_NAME:-}"
REALITY_HANDSHAKE="${MINI_SINGBOX_REALITY_HANDSHAKE:-}"
TLS_SAN="${MINI_SINGBOX_TLS_SAN:-}"
PUBLIC_ADDRESS="${MINI_SINGBOX_PUBLIC_ADDRESS:-}"
PUBLIC_REALITY_PORT="${MINI_SINGBOX_PUBLIC_REALITY_PORT:-}"
PUBLIC_HY2_PORT="${MINI_SINGBOX_PUBLIC_HY2_PORT:-}"
PUBLIC_ANYTLS_PORT="${MINI_SINGBOX_PUBLIC_ANYTLS_PORT:-}"
REALITY_PUBLIC_PORT_SOURCE=assumed
HY2_PUBLIC_PORT_SOURCE=assumed
ANYTLS_PUBLIC_PORT_SOURCE=assumed
[ -n "$PUBLIC_REALITY_PORT" ] && REALITY_PUBLIC_PORT_SOURCE=explicit
[ -n "$PUBLIC_HY2_PORT" ] && HY2_PUBLIC_PORT_SOURCE=explicit
[ -n "$PUBLIC_ANYTLS_PORT" ] && ANYTLS_PUBLIC_PORT_SOURCE=explicit
REFRESH_DELIVERY="${MINI_SINGBOX_REFRESH_DELIVERY:-0}"
AUTO_DETECT="${MINI_SINGBOX_AUTO_DETECT:-1}"
AUTO_TUNE="${MINI_SINGBOX_AUTO_TUNE:-1}"
REGENERATE="${MINI_SINGBOX_REGENERATE:-0}"
ALLOW_INSECURE_ANYTLS_SHARE="${MINI_SINGBOX_ALLOW_INSECURE_ANYTLS_SHARE:-0}"
BACKUP_KEEP="${MINI_SINGBOX_BACKUP_KEEP:-5}"
IP_FAMILY="${MINI_SINGBOX_IP_FAMILY:-auto}"
REALITY_CANDIDATES="${MINI_SINGBOX_REALITY_CANDIDATES:-www.microsoft.com,www.amazon.com,www.mozilla.org,www.cloudflare.com}"
NEEDS_GENERATION=0
AUTO_TUNE_DISABLED_REASON=""

if [ -f "$CONFIG_DIR/deployment-info.txt" ] && [ ! -L "$CONFIG_DIR/deployment-info.txt" ]; then
	if [ "$REALITY_PUBLIC_PORT_SOURCE" = assumed ]; then
		previous_source="$(awk -F= '$1 == "vless_reality_public_port_source" { print $2 }' "$CONFIG_DIR/deployment-info.txt")"
		case "$previous_source" in explicit|assumed) REALITY_PUBLIC_PORT_SOURCE="$previous_source" ;; esac
	fi
	if [ "$HY2_PUBLIC_PORT_SOURCE" = assumed ]; then
		previous_source="$(awk -F= '$1 == "hysteria2_public_port_source" { print $2 }' "$CONFIG_DIR/deployment-info.txt")"
		case "$previous_source" in explicit|assumed) HY2_PUBLIC_PORT_SOURCE="$previous_source" ;; esac
	fi
	if [ "$ANYTLS_PUBLIC_PORT_SOURCE" = assumed ]; then
		previous_source="$(awk -F= '$1 == "anytls_public_port_source" { print $2 }' "$CONFIG_DIR/deployment-info.txt")"
		case "$previous_source" in explicit|assumed) ANYTLS_PUBLIC_PORT_SOURCE="$previous_source" ;; esac
	fi
fi

if [ "$RUNTIME" = external ] || [ "$CONTAINERIZED" -eq 1 ]; then
	if [ "$RUNTIME" = external ]; then
		AUTO_TUNE_DISABLED_REASON="the external runtime does not own the host kernel"
	else
		AUTO_TUNE_DISABLED_REASON="the $UNIT_PROFILE runtime shares its host kernel"
	fi
	if [ "$AUTO_TUNE" = "1" ] && [ "${MINI_SINGBOX_AUTO_TUNE+x}" = "x" ]; then
		warn "$AUTO_TUNE_DISABLED_REASON; MINI_SINGBOX_AUTO_TUNE=1 was ignored"
	fi
	AUTO_TUNE=0
fi

case "$PROTOCOLS" in
	*[[:space:]]*) fail "MINI_SINGBOX_PROTOCOLS must not contain whitespace" ;;
esac
case "$IP_FAMILY" in
	auto|4|6) ;;
	*) fail "MINI_SINGBOX_IP_FAMILY must be auto, 4, or 6" ;;
esac
case "$REFRESH_DELIVERY" in
	0|1) ;;
	*) fail "MINI_SINGBOX_REFRESH_DELIVERY must be 0 or 1" ;;
esac
case "$AUTO_DETECT" in
	0|1) ;;
	*) fail "MINI_SINGBOX_AUTO_DETECT must be 0 or 1" ;;
esac
case "$AUTO_TUNE" in
	0|1) ;;
	*) fail "MINI_SINGBOX_AUTO_TUNE must be 0 or 1" ;;
esac
case "$REGENERATE" in
	0|1) ;;
	*) fail "MINI_SINGBOX_REGENERATE must be 0 or 1" ;;
esac
case "$ALLOW_INSECURE_ANYTLS_SHARE" in
	0|1) ;;
	*) fail "MINI_SINGBOX_ALLOW_INSECURE_ANYTLS_SHARE must be 0 or 1" ;;
esac
case "$BACKUP_KEEP" in
	''|*[!0-9]*) fail "MINI_SINGBOX_BACKUP_KEEP must be an integer from 1 to 50" ;;
esac
if [ "$BACKUP_KEEP" -lt 1 ] || [ "$BACKUP_KEEP" -gt 50 ]; then
	fail "MINI_SINGBOX_BACKUP_KEEP must be in range 1-50"
fi
if [ ! -f "$CONFIG_DIR/config.json" ] || [ "$REGENERATE" = "1" ]; then
	NEEDS_GENERATION=1
fi
MIGRATION_FROM_RUNTIME=""
if [ -f "$CONFIG_DIR/deployment-info.txt" ] && [ ! -L "$CONFIG_DIR/deployment-info.txt" ]; then
	EXISTING_RUNTIME="$(awk -F= '$1 == "runtime" { print $2 }' "$CONFIG_DIR/deployment-info.txt")"
	if [ -z "$EXISTING_RUNTIME" ] && grep -q '^systemd_profile=' "$CONFIG_DIR/deployment-info.txt"; then
		EXISTING_RUNTIME=systemd
	fi
	if [ -n "$EXISTING_RUNTIME" ] && [ "$EXISTING_RUNTIME" != "$RUNTIME" ]; then
		if [ "$EXISTING_RUNTIME" = external ] && [ "$RUNTIME" = openrc ] && \
			[ "$CONTAINERIZED" -eq 1 ] && openrc_is_running; then
			if external_pid >/dev/null; then
				fail "the existing external process is active; stop its supervisor before migrating to OpenRC"
			fi
			MIGRATION_FROM_RUNTIME=external
			warn "migrating an inactive external deployment to the active containerized OpenRC service manager"
		else
			fail "existing installation uses $EXISTING_RUNTIME; refusing an implicit runtime migration to $RUNTIME"
		fi
	fi
fi

case "$(uname -m)" in
	x86_64|amd64)
		ARCH="amd64"
		;;
	aarch64|arm64)
		ARCH="arm64"
		;;
	*)
		fail "unsupported architecture $(uname -m); only amd64 and arm64 are supported"
		;;
esac

if command_exists apt-get; then
	missing_packages=""
	command_exists curl || missing_packages="$missing_packages curl"
	if ! command_exists sha256sum || ! command_exists timeout; then
		missing_packages="$missing_packages coreutils"
	fi
	command_exists runuser || missing_packages="$missing_packages util-linux"
	find_supports_printf || missing_packages="$missing_packages findutils"
	if ! command_exists ss || ! command_exists ip; then
		missing_packages="$missing_packages iproute2"
	fi
	command_exists useradd || missing_packages="$missing_packages passwd"
	command_exists groupadd || missing_packages="$missing_packages passwd"
	command_exists usermod || missing_packages="$missing_packages passwd"
	command_exists getent || missing_packages="$missing_packages libc-bin"
	ps_supports_pid_filter || missing_packages="$missing_packages procps"
	command_exists openssl || missing_packages="$missing_packages openssl"
	command_exists qrencode || missing_packages="$missing_packages qrencode"
	command_exists jq || missing_packages="$missing_packages jq"
	command_exists file || missing_packages="$missing_packages file"
	command_exists readelf || missing_packages="$missing_packages binutils"
	if [ "$RUNTIME" = openrc ]; then
		command_exists logger || missing_packages="$missing_packages logger"
	fi
	if [ "$SIGNED_RELEASE" -eq 1 ]; then
		command_exists minisign || missing_packages="$missing_packages minisign"
	fi
	if [ -n "$missing_packages" ] || [ ! -e /etc/ssl/certs/ca-certificates.crt ]; then
		log "Installing required Debian/Ubuntu packages"
		export DEBIAN_FRONTEND=noninteractive
		apt-get update
		# ca-certificates is intentionally installed even when the bundle exists.
		# missing_packages contains only the fixed package names assigned above.
		# shellcheck disable=SC2086
		apt-get install -y --no-install-recommends ca-certificates $missing_packages
	fi
elif command_exists apk; then
	missing_packages=""
	command_exists curl || missing_packages="$missing_packages curl"
	if ! command_exists sha256sum || ! command_exists timeout; then
		missing_packages="$missing_packages coreutils"
	fi
	command_exists runuser || missing_packages="$missing_packages runuser"
	find_supports_printf || missing_packages="$missing_packages findutils"
	if ! command_exists ss || ! command_exists ip; then
		missing_packages="$missing_packages iproute2"
	fi
	command_exists useradd || missing_packages="$missing_packages shadow"
	if ! ps_supports_pid_filter || ! command_exists pgrep; then
		missing_packages="$missing_packages procps-ng"
	fi
	command_exists openssl || missing_packages="$missing_packages openssl"
	command_exists qrencode || missing_packages="$missing_packages libqrencode-tools"
	command_exists jq || missing_packages="$missing_packages jq"
	command_exists file || missing_packages="$missing_packages file"
	command_exists readelf || missing_packages="$missing_packages binutils"
	if [ "$RUNTIME" = openrc ]; then
		command_exists logger || missing_packages="$missing_packages logger"
	fi
	if [ "$SIGNED_RELEASE" -eq 1 ]; then
		command_exists minisign || missing_packages="$missing_packages minisign"
	fi
	if [ -n "$missing_packages" ] || [ ! -e /etc/ssl/certs/ca-certificates.crt ]; then
		log "Installing required Alpine packages"
		# ca-certificates is intentionally installed even when the bundle exists.
		# missing_packages contains only the fixed package names assigned above.
		# shellcheck disable=SC2086
		apk add --no-cache ca-certificates $missing_packages
	fi
else
	required_commands="curl sha256sum runuser find ss ip useradd groupadd usermod ps pgrep openssl qrencode jq timeout file readelf"
	if [ "$SIGNED_RELEASE" -eq 1 ]; then
		required_commands="$required_commands minisign"
	fi
	for required_command in $required_commands; do
		command_exists "$required_command" || \
			fail "missing $required_command; automatic package installation is supported only with apt or apk"
	done
fi
find_supports_printf || fail "find must support -printf (install GNU findutils)"
ps_supports_pid_filter || fail "ps must support -p and custom output (install procps/procps-ng)"

valid_ipv4() {
	printf '%s\n' "$1" | awk -F. '
		NF != 4 { exit 1 }
		{
			for (i = 1; i <= 4; i++) {
				if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
			}
		}
	'
}

normalize_ipv6() {
	value="$1"
	case "$value" in
		""|*%*|*.*|*[!0-9A-Fa-f:]*) return 1 ;;
		*:*) ;;
		*) return 1 ;;
	esac
	normalized="$(ip -6 route get "$value" 2>/dev/null | awk '
		NR == 1 && $1 == "local" { print $2; exit }
		NR == 1 { print $1; exit }
	')"
	case "$normalized" in
		""|*%*|*[!0-9A-Fa-f:]*) return 1 ;;
		*:*) printf '%s\n' "$normalized" ;;
		*) return 1 ;;
	esac
}

fetch_public_ipv4() {
	ipify="$(curl --silent --show-error --noproxy '*' --ipv4 \
		--connect-timeout 4 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
	aws="$(curl --silent --show-error --noproxy '*' --ipv4 \
		--connect-timeout 4 --max-time 8 https://checkip.amazonaws.com 2>/dev/null || true)"
	cloudflare="$(curl --silent --show-error --noproxy '*' --ipv4 \
		--connect-timeout 4 --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | \
		awk -F= '$1 == "ip" { print $2; exit }' || true)"

	ipify="$(printf '%s' "$ipify" | tr -d '[:space:]')"
	aws="$(printf '%s' "$aws" | tr -d '[:space:]')"
	cloudflare="$(printf '%s' "$cloudflare" | tr -d '[:space:]')"
	valid_ipv4 "$ipify" || ipify=""
	valid_ipv4 "$aws" || aws=""
	valid_ipv4 "$cloudflare" || cloudflare=""

	if [ -n "$ipify" ] && { [ "$ipify" = "$aws" ] || [ "$ipify" = "$cloudflare" ]; }; then
		printf '%s\n' "$ipify"
		return 0
	fi
	if [ -n "$aws" ] && [ "$aws" = "$cloudflare" ]; then
		printf '%s\n' "$aws"
		return 0
	fi

	valid_count=0
	only_value=""
	for detected_ip in "$ipify" "$aws" "$cloudflare"; do
		if [ -n "$detected_ip" ]; then
			valid_count=$((valid_count + 1))
			only_value="$detected_ip"
		fi
	done
	if [ "$valid_count" -eq 1 ]; then
		warn "only one public IPv4 provider responded; using $only_value"
		printf '%s\n' "$only_value"
		return 0
	fi
	if [ "$valid_count" -gt 1 ]; then
		warn "public IPv4 providers disagreed: ipify=${ipify:-unavailable}, aws=${aws:-unavailable}, cloudflare=${cloudflare:-unavailable}"
	fi
	return 1
}

fetch_public_ipv6() {
	ipify="$(curl --silent --show-error --noproxy '*' --ipv6 \
		--connect-timeout 4 --max-time 8 https://api6.ipify.org 2>/dev/null || true)"
	icanhazip="$(curl --silent --show-error --noproxy '*' --ipv6 \
		--connect-timeout 4 --max-time 8 https://ipv6.icanhazip.com 2>/dev/null || true)"
	cloudflare="$(curl --silent --show-error --noproxy '*' --ipv6 \
		--connect-timeout 4 --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | \
		awk -F= '$1 == "ip" { print $2; exit }' || true)"

	ipify="$(printf '%s' "$ipify" | tr -d '[:space:]')"
	icanhazip="$(printf '%s' "$icanhazip" | tr -d '[:space:]')"
	cloudflare="$(printf '%s' "$cloudflare" | tr -d '[:space:]')"
	ipify="$(normalize_ipv6 "$ipify" || true)"
	icanhazip="$(normalize_ipv6 "$icanhazip" || true)"
	cloudflare="$(normalize_ipv6 "$cloudflare" || true)"

	if [ -n "$ipify" ] && { [ "$ipify" = "$icanhazip" ] || [ "$ipify" = "$cloudflare" ]; }; then
		printf '%s\n' "$ipify"
		return 0
	fi
	if [ -n "$icanhazip" ] && [ "$icanhazip" = "$cloudflare" ]; then
		printf '%s\n' "$icanhazip"
		return 0
	fi

	valid_count=0
	only_value=""
	for detected_ip in "$ipify" "$icanhazip" "$cloudflare"; do
		if [ -n "$detected_ip" ]; then
			valid_count=$((valid_count + 1))
			only_value="$detected_ip"
		fi
	done
	if [ "$valid_count" -eq 1 ]; then
		warn "only one public IPv6 provider responded; using $only_value"
		printf '%s\n' "$only_value"
		return 0
	fi
	if [ "$valid_count" -gt 1 ]; then
		warn "public IPv6 providers disagreed: ipify=${ipify:-unavailable}, icanhazip=${icanhazip:-unavailable}, cloudflare=${cloudflare:-unavailable}"
	fi
	return 1
}

detect_public_address() {
	case "$IP_FAMILY" in
		4) fetch_public_ipv4 ;;
		6) fetch_public_ipv6 ;;
		auto)
			fetch_public_ipv4 || fetch_public_ipv6
			;;
	esac
}

set_probe_family() {
	PROBE_CURL_FLAG="--ipv4"
	PROBE_OPENSSL_FLAG="-4"
	if [ "$IP_FAMILY" = "6" ]; then
		PROBE_CURL_FLAG="--ipv6"
		PROBE_OPENSSL_FLAG="-6"
	elif [ "$IP_FAMILY" = "auto" ]; then
		case "$PUBLIC_ADDRESS" in
			*:*) PROBE_CURL_FLAG="--ipv6"; PROBE_OPENSSL_FLAG="-6" ;;
		esac
	fi
}

valid_reality_candidate() {
	case "$1" in
		""|.*|*.|*..*|*[!A-Za-z0-9.-]*) return 1 ;;
		*) return 0 ;;
	esac
}

select_reality_target() {
	best_host=""
	best_score=""
	checked=0
	old_ifs="$IFS"
	IFS=,
	for candidate in $REALITY_CANDIDATES; do
		IFS="$old_ifs"
		checked=$((checked + 1))
		[ "$checked" -le 12 ] || break
		if ! valid_reality_candidate "$candidate"; then
			warn "skipping invalid Reality candidate $candidate"
			IFS=,
			continue
		fi

		probe_start="$(date +%s%3N)"
		probe="$(timeout 8 openssl s_client \
			"$PROBE_OPENSSL_FLAG" \
			-connect "$candidate:443" -servername "$candidate" \
			-verify_hostname "$candidate" -verify_return_error \
			-tls1_3 -alpn h2 </dev/null 2>&1 || true)"
		probe_end="$(date +%s%3N)"
		if ! printf '%s\n' "$probe" | grep -Fq 'TLSv1.3' || \
			! printf '%s\n' "$probe" | grep -Fq 'ALPN protocol: h2' || \
			! printf '%s\n' "$probe" | grep -Fq 'Verify return code: 0 (ok)'; then
			warn "Reality candidate $candidate did not complete a verified TLS 1.3/H2 probe"
			IFS=,
			continue
		fi

		http_code="$(curl --silent --show-error --noproxy '*' "$PROBE_CURL_FLAG" \
			--connect-timeout 4 --max-time 8 --head \
			--output /dev/null --write-out '%{http_code}' \
			"https://$candidate/" 2>/dev/null || true)"
		case "$http_code" in
			2??|4??) ;;
			*) IFS=,; continue ;;
		esac
		score=$((probe_end - probe_start))

		printf 'Reality candidate: %s, verified TLS handshake %sms\n' "$candidate" "$score" >&2
		if [ -z "$best_host" ] || \
			[ "$score" -lt "$best_score" ]; then
			best_host="$candidate"
			best_score="$score"
		fi
		IFS=,
	done
	IFS="$old_ifs"
	[ -n "$best_host" ] || return 1
	printf '%s\n' "$best_host"
}

port_has_foreign_listener() {
	transport="$1"
	port="$2"
	owner_pid="$3"
	allow_unattributed_current="$4"
	case "$transport" in
		tcp) listeners="$(ss -lntpH)" ;;
		udp) listeners="$(ss -lnupH)" ;;
		*) fail "internal preflight transport error: $transport" ;;
	esac
	printf '%s\n' "$listeners" | awk \
		-v port="$port" \
		-v owner_pid="$owner_pid" \
		-v allow_unattributed_current="$allow_unattributed_current" '
		$4 ~ (":" port "$") {
			found = 1
			owned = owner_pid != "0" && index($0, "pid=" owner_pid ",") != 0
			has_attribution = index($0, "pid=") != 0
			if (has_attribution && !owned) foreign = 1
			if (!has_attribution && allow_unattributed_current != "1") foreign = 1
		}
		END { exit !(found && foreign) }
	'
}

preflight_requested_ports() {
	owner_pid="0"
	current_service_active=0
	if runtime_is_active; then
		current_service_active=1
		candidate_pid="$(runtime_main_pid)"
		case "$candidate_pid" in
			''|*[!0-9]*) ;;
			*) [ "$candidate_pid" -gt 0 ] && owner_pid="$candidate_pid" ;;
		esac
	fi
	requested_ports=""
	for protocol_port in \
		"reality:tcp:$REALITY_PORT" "hy2:udp:$HY2_PORT" "anytls:tcp:$ANYTLS_PORT"; do
		protocol="${protocol_port%%:*}"
		remainder="${protocol_port#*:}"
		transport="${remainder%%:*}"
		port="${remainder#*:}"
		case ",$PROTOCOLS," in
			*,"$protocol",*) ;;
			*) continue ;;
		esac
		case "$port" in
			''|*[!0-9]*) fail "$protocol port must be an integer" ;;
		esac
		if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
			fail "$protocol port must be in range 1024-65535"
		fi
		case ",$requested_ports," in
			*,"$port",*) fail "$protocol port $port conflicts with another enabled protocol" ;;
		esac
		requested_ports="${requested_ports:+$requested_ports,}$port"
		allow_unattributed_current=0
		if [ "$current_service_active" -eq 1 ] && [ -f "$CONFIG_DIR/config.json" ]; then
			case "$protocol" in
				reality) config_key=vless_reality ;;
				hy2) config_key=hysteria2 ;;
				anytls) config_key=anytls ;;
			esac
			current_port="$(jq -er ".${config_key}.port // empty" "$CONFIG_DIR/config.json" 2>/dev/null || true)"
			if [ "$current_port" = "$port" ]; then
				allow_unattributed_current=1
			fi
		fi
		if port_has_foreign_listener \
			"$transport" "$port" "$owner_pid" "$allow_unattributed_current"; then
			fail "$protocol port $transport/$port is already used by another process"
		fi
	done
	log "Requested protocol ports passed the local listener preflight"
}

if [ "$NEEDS_GENERATION" -eq 0 ] && \
	jq -e '.anytls' "$CONFIG_DIR/config.json" >/dev/null 2>&1; then
	if [ ! -f "$CONFIG_DIR/client-anytls-sing-box-outbound.json" ] || \
		[ -L "$CONFIG_DIR/client-anytls-sing-box-outbound.json" ] || \
		{ [ "$ALLOW_INSECURE_ANYTLS_SHARE" -eq 0 ] && \
			{ [ -e "$CONFIG_DIR/share-anytls.txt" ] || [ -L "$CONFIG_DIR/share-anytls.txt" ] || \
				[ -e "$CONFIG_DIR/share-anytls.png" ] || [ -L "$CONFIG_DIR/share-anytls.png" ]; }; }; then
		REFRESH_DELIVERY=1
		log "Refreshing AnyTLS delivery to enforce authenticated TLS defaults"
	fi
fi

if [ "$REFRESH_DELIVERY" -eq 1 ] && [ "$NEEDS_GENERATION" -eq 0 ]; then
	[ -f "$CONFIG_DIR/config.json" ] || fail "cannot refresh delivery without $CONFIG_DIR/config.json"
	if [ -f "$CONFIG_DIR/client-info.json" ]; then
		[ -n "$PUBLIC_ADDRESS" ] || \
			PUBLIC_ADDRESS="$(jq -r '.public_address // empty' "$CONFIG_DIR/client-info.json" 2>/dev/null || true)"
		[ -n "$PUBLIC_REALITY_PORT" ] || \
			PUBLIC_REALITY_PORT="$(jq -r '.vless_reality.port // empty' "$CONFIG_DIR/client-info.json" 2>/dev/null || true)"
		[ -n "$PUBLIC_HY2_PORT" ] || \
			PUBLIC_HY2_PORT="$(jq -r '.hysteria2.port // empty' "$CONFIG_DIR/client-info.json" 2>/dev/null || true)"
		[ -n "$PUBLIC_ANYTLS_PORT" ] || \
			PUBLIC_ANYTLS_PORT="$(jq -r '.anytls.port // empty' "$CONFIG_DIR/client-info.json" 2>/dev/null || true)"
	fi
fi

if [ "$NEEDS_GENERATION" -eq 1 ] || [ "$REFRESH_DELIVERY" -eq 1 ]; then
	case "$PUBLIC_ADDRESS" in
		*[!A-Za-z0-9.:-]*) fail "MINI_SINGBOX_PUBLIC_ADDRESS contains unsupported characters" ;;
	esac
	if [ "$AUTO_DETECT" = "1" ]; then
		if [ -z "$PUBLIC_ADDRESS" ]; then
			log "Detecting the VM public address (family: $IP_FAMILY)"
			if PUBLIC_ADDRESS="$(detect_public_address)"; then
				case "$PUBLIC_ADDRESS" in *:*) detected_family=IPv6 ;; *) detected_family=IPv4 ;; esac
				log "Detected public $detected_family: $PUBLIC_ADDRESS"
			else
				warn "public address auto-detection failed; set MINI_SINGBOX_PUBLIC_ADDRESS manually"
			fi
		fi
	fi
	[ -n "$PUBLIC_ADDRESS" ] || \
		fail "public address is required for client delivery; set MINI_SINGBOX_PUBLIC_ADDRESS"
	for public_port in "$PUBLIC_REALITY_PORT" "$PUBLIC_HY2_PORT" "$PUBLIC_ANYTLS_PORT"; do
		[ -z "$public_port" ] && continue
		case "$public_port" in
			*[!0-9]*) fail "public ports must be integers" ;;
		esac
		if [ "$public_port" -lt 1 ] || [ "$public_port" -gt 65535 ]; then
			fail "public ports must be in range 1-65535"
		fi
	done
	if [ "$CONTAINERIZED" -eq 1 ]; then
		assumed_public_ports=""
		case ",$PROTOCOLS," in
			*,reality,*) [ "$REALITY_PUBLIC_PORT_SOURCE" = explicit ] || assumed_public_ports="Reality TCP/$REALITY_PORT" ;;
		esac
		case ",$PROTOCOLS," in
			*,hy2,*) [ "$HY2_PUBLIC_PORT_SOURCE" = explicit ] || assumed_public_ports="${assumed_public_ports:+$assumed_public_ports, }Hysteria2 UDP/$HY2_PORT" ;;
		esac
		case ",$PROTOCOLS," in
			*,anytls,*) [ "$ANYTLS_PUBLIC_PORT_SOURCE" = explicit ] || assumed_public_ports="${assumed_public_ports:+$assumed_public_ports, }AnyTLS TCP/$ANYTLS_PORT" ;;
		esac
		if [ -n "$assumed_public_ports" ]; then
			warn "container/shared-NAT deployment: public forwarding cannot be inferred from the detected IP"
			warn "assuming the public ports equal the listen ports for: $assumed_public_ports"
			warn "verify the provider panel mappings or set MINI_SINGBOX_PUBLIC_REALITY_PORT, MINI_SINGBOX_PUBLIC_HY2_PORT, and MINI_SINGBOX_PUBLIC_ANYTLS_PORT"
		fi
	fi
fi

if [ "$NEEDS_GENERATION" -eq 1 ]; then
	set_probe_family
	if [ "$AUTO_DETECT" = "1" ]; then

		case ",$PROTOCOLS," in
			*,reality,*)
				if [ -z "$REALITY_SERVER_NAME" ] && [ -z "$REALITY_HANDSHAKE" ]; then
					log "Selecting a Reality target by verified TLS 1.3/H2 handshake latency"
					REALITY_SERVER_NAME="$(select_reality_target)" || \
						fail "no Reality candidate passed; set MINI_SINGBOX_REALITY_SERVER_NAME manually"
					REALITY_HANDSHAKE="$REALITY_SERVER_NAME:443"
				elif [ -n "$REALITY_SERVER_NAME" ] && [ -z "$REALITY_HANDSHAKE" ]; then
					REALITY_HANDSHAKE="$REALITY_SERVER_NAME:443"
				elif [ -z "$REALITY_SERVER_NAME" ]; then
					fail "set MINI_SINGBOX_REALITY_SERVER_NAME when MINI_SINGBOX_REALITY_HANDSHAKE is provided"
				fi
				log "Selected Reality target: $REALITY_HANDSHAKE"
				;;
		esac
	fi
	case ",$PROTOCOLS," in
		*,reality,*)
			if [ -n "$REALITY_SERVER_NAME" ] && [ -z "$REALITY_HANDSHAKE" ]; then
				REALITY_HANDSHAKE="$REALITY_SERVER_NAME:443"
			fi
			;;
	esac

	case ",$PROTOCOLS," in
		*,reality,*)
			[ -n "$REALITY_SERVER_NAME" ] || fail "set MINI_SINGBOX_REALITY_SERVER_NAME or enable auto-detection"
			[ -n "$REALITY_HANDSHAKE" ] || fail "set MINI_SINGBOX_REALITY_HANDSHAKE or enable auto-detection"
			;;
	esac
	case ",$PROTOCOLS," in
		*,hy2,*|*,anytls,*)
			if [ -z "$TLS_SAN" ]; then
				[ -n "$PUBLIC_ADDRESS" ] || \
					fail "set MINI_SINGBOX_TLS_SAN or MINI_SINGBOX_PUBLIC_ADDRESS because public address detection failed"
				TLS_SAN="$PUBLIC_ADDRESS"
			fi
			;;
	esac
	preflight_requested_ports
fi

PUBLIC_REALITY_PORT="${PUBLIC_REALITY_PORT:-0}"
PUBLIC_HY2_PORT="${PUBLIC_HY2_PORT:-0}"
PUBLIC_ANYTLS_PORT="${PUBLIC_ANYTLS_PORT:-0}"

WORK_DIR="$(mktemp -d /var/tmp/mini-singbox-deploy.XXXXXX)"
# The service user must traverse this parent to execute the verified binary and
# reach its own 0700 generated directory. Directory listing remains forbidden.
chmod 0711 "$WORK_DIR"
DEPLOYMENT_STARTED=0
DEPLOYMENT_SUCCEEDED=0
HAD_BINARY=0
HAD_CONTROL=0
HAD_CONTAINER_CONTROL=0
HAD_UPDATE=0
HAD_UNINSTALL=0
HAD_UNIT=0
HAD_EXTERNAL_RUN=0
HAD_CONFIG=0
WAS_ACTIVE=0
WAS_ENABLED=0
DELIVERY_REPLACED=0
DEPLOYMENT_INFO_REWRITTEN=0
EXTERNAL_RUN_REMOVED=0
BACKUP_DIR=""

rollback() {
	warn "deployment failed after installation began; restoring the previous state"
	runtime_stop >/dev/null 2>&1 || true

	if [ "$HAD_BINARY" -eq 1 ]; then
		install -m 0755 "$BACKUP_DIR/mini-singbox" "$INSTALL_PATH"
	else
		rm -f "$INSTALL_PATH"
	fi
	if [ "$HAD_CONTROL" -eq 1 ]; then
		install -m 0755 "$BACKUP_DIR/mini-singboxctl" "$CONTROL_PATH"
	else
		rm -f "$CONTROL_PATH"
	fi
	if [ "$HAD_CONTAINER_CONTROL" -eq 1 ]; then
		install -m 0755 "$BACKUP_DIR/mini-singbox-containerctl" "$CONTAINER_CONTROL_PATH"
	else
		rm -f "$CONTAINER_CONTROL_PATH"
	fi
	if [ "$HAD_UPDATE" -eq 1 ]; then
		install -m 0755 "$BACKUP_DIR/mini-singbox-update" "$UPDATE_PATH"
	else
		rm -f "$UPDATE_PATH"
	fi
	if [ "$HAD_UNINSTALL" -eq 1 ]; then
		install -m 0755 "$BACKUP_DIR/mini-singbox-uninstall" "$UNINSTALL_PATH"
	else
		rm -f "$UNINSTALL_PATH"
	fi
	if [ "$EXTERNAL_RUN_REMOVED" -eq 1 ]; then
		if [ "$HAD_EXTERNAL_RUN" -eq 1 ]; then
			install -m 0755 "$BACKUP_DIR/mini-singbox-run" "$EXTERNAL_RUN_PATH"
		else
			rm -f "$EXTERNAL_RUN_PATH"
		fi
	fi

	if [ "$HAD_UNIT" -eq 1 ]; then
		case "$RUNTIME" in systemd) unit_mode=0644 ;; *) unit_mode=0755 ;; esac
		install -m "$unit_mode" "$BACKUP_DIR/runtime-unit" "$UNIT_PATH"
	else
		rm -f "$UNIT_PATH"
	fi
	if [ "${CONFIG_REPLACED:-0}" -eq 1 ]; then
		[ "$CONFIG_DIR" = "/etc/mini-singbox" ] || fail "unsafe rollback config path"
		rm -rf "$CONFIG_DIR"
		if [ "$HAD_CONFIG" -eq 1 ]; then
			cp -a "$BACKUP_DIR/config" "$CONFIG_DIR"
		fi
	fi
	if [ "${CONFIG_REPLACED:-0}" -eq 0 ] && [ "$HAD_CONFIG" -eq 1 ]; then
		if [ "${DELIVERY_REPLACED:-0}" -eq 1 ]; then
			for delivery_file in \
				client-info.json client-anytls-sing-box-outbound.json \
				share-reality.txt share-hysteria2.txt share-anytls.txt \
				share-reality.png share-hysteria2.png share-anytls.png; do
				if [ -f "$BACKUP_DIR/config/$delivery_file" ]; then
					cp -a "$BACKUP_DIR/config/$delivery_file" "$CONFIG_DIR/$delivery_file"
				else
					rm -f "$CONFIG_DIR/$delivery_file"
				fi
			done
		fi
		if [ "${DEPLOYMENT_INFO_REWRITTEN:-0}" -eq 1 ]; then
			if [ -f "$BACKUP_DIR/config/deployment-info.txt" ]; then
				cp -a "$BACKUP_DIR/config/deployment-info.txt" "$CONFIG_DIR/deployment-info.txt"
			else
				rm -f "$CONFIG_DIR/deployment-info.txt"
			fi
		fi
	fi

	runtime_reload
	if [ "$WAS_ENABLED" -eq 1 ] && [ "$HAD_UNIT" -eq 1 ]; then
		runtime_enable >/dev/null 2>&1 || true
	else
		runtime_disable
	fi
	if [ "$WAS_ACTIVE" -eq 1 ] && [ "$HAD_UNIT" -eq 1 ] && [ "$HAD_BINARY" -eq 1 ]; then
		runtime_start >/dev/null 2>&1 || true
	fi
	warn "rollback finished; backup retained at $BACKUP_DIR"
}

cleanup() {
	status=$?
	trap - EXIT HUP INT TERM
	if [ "$status" -ne 0 ] && [ "$DEPLOYMENT_STARTED" -eq 1 ] && [ "$DEPLOYMENT_SUCCEEDED" -eq 0 ]; then
		rollback
	fi
	case "${WORK_DIR:-}" in
		/var/tmp/mini-singbox-deploy.*) rm -rf "$WORK_DIR" ;;
		"") ;;
		*) warn "refusing to remove unexpected work directory $WORK_DIR" ;;
	esac
	exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

ASSET="mini-singbox-linux-$ARCH"
BUILD_BINARY="$WORK_DIR/$ASSET"
CHECKSUMS="$WORK_DIR/SHA256SUMS"
CHECKSUM_SIGNATURE="$WORK_DIR/SHA256SUMS.minisig"
RELEASE_BASE="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG"

case "$RELEASE_TAG" in
	""|*[!A-Za-z0-9._-]*) fail "invalid MINI_SINGBOX_RELEASE_TAG" ;;
esac

log "Downloading linux/$ARCH asset from immutable release $RELEASE_TAG"
curl --fail --location --proto '=https' --tlsv1.2 \
	--retry 3 --connect-timeout 20 --output "$BUILD_BINARY" "$RELEASE_BASE/$ASSET"
curl --fail --location --proto '=https' --tlsv1.2 \
	--retry 3 --connect-timeout 20 --output "$CHECKSUMS" "$RELEASE_BASE/SHA256SUMS"
if [ "$SIGNED_RELEASE" -eq 1 ]; then
	if [ ! -f "$MINISIGN_PUBLIC_KEY" ] || [ -L "$MINISIGN_PUBLIC_KEY" ]; then
		fail "pinned minisign public key is missing or unsafe: $MINISIGN_PUBLIC_KEY"
	fi
	curl --fail --location --proto '=https' --tlsv1.2 \
		--retry 3 --connect-timeout 20 --output "$CHECKSUM_SIGNATURE" \
		"$RELEASE_BASE/SHA256SUMS.minisig"
	minisign -Vm "$CHECKSUMS" -x "$CHECKSUM_SIGNATURE" -p "$MINISIGN_PUBLIC_KEY" >/dev/null || \
		fail "release checksum signature verification failed"
fi

verify_signed_checkout_file() {
	local_file="$1"
	manifest_name="$2"
	if [ ! -f "$local_file" ] || [ -L "$local_file" ]; then
		fail "release checkout file is missing or unsafe: $manifest_name"
	fi
	expected="$(awk -v asset="$manifest_name" '$2 == asset || $2 == "*" asset { print $1 }' "$CHECKSUMS")"
	printf '%s\n' "$expected" | grep -Eq '^[0-9a-f]{64}$' || \
		fail "signed checksum manifest does not contain one valid SHA-256 for $manifest_name"
	actual="$(sha256sum "$local_file" | awk '{ print $1 }')"
	[ "$actual" = "$expected" ] || fail "signed checkout verification failed for $manifest_name"
}

if [ "$SIGNED_RELEASE" -eq 1 ] || [ "$VERIFY_BUNDLE_FILES" -eq 1 ]; then
	if [ "$VERIFY_BUNDLE_FILES" -eq 1 ]; then
		deploy_manifest_name=deploy.sh
		control_manifest_name=mini-singboxctl
		container_control_manifest_name=mini-singbox-containerctl
		uninstall_manifest_name=uninstall.sh
		openrc_manifest_name=mini-singbox
		external_manifest_name=mini-singbox-run
		key_manifest_name=minisign.pub
	else
		deploy_manifest_name=scripts/deploy.sh
		control_manifest_name=scripts/mini-singboxctl
		container_control_manifest_name=scripts/mini-singbox-containerctl
		uninstall_manifest_name=scripts/uninstall.sh
		openrc_manifest_name=packaging/openrc/mini-singbox
		external_manifest_name=packaging/external/mini-singbox-run
		key_manifest_name=release/minisign.pub
	fi
	verify_signed_checkout_file "$SCRIPT_DIR/deploy.sh" "$deploy_manifest_name"
	verify_signed_checkout_file "$CONTROL_SOURCE" "$control_manifest_name"
	verify_signed_checkout_file "$CONTAINER_CONTROL_SOURCE" "$container_control_manifest_name"
	verify_signed_checkout_file "$UPDATE_SOURCE" bootstrap.sh
	verify_signed_checkout_file "$UNINSTALL_SOURCE" "$uninstall_manifest_name"
	case "$UNIT_PROFILE" in
		full) unit_manifest_name=packaging/systemd/mini-singbox.service ;;
		container-compatible) unit_manifest_name=packaging/systemd/mini-singbox-container.service ;;
		openrc|openrc-container) unit_manifest_name="$openrc_manifest_name" ;;
		external-supervisor) unit_manifest_name="$external_manifest_name" ;;
		*) fail "internal runtime profile error: $UNIT_PROFILE" ;;
	esac
	if [ "$VERIFY_BUNDLE_FILES" -eq 1 ]; then
		unit_manifest_name="$(basename "$UNIT_SOURCE")"
	fi
	verify_signed_checkout_file "$UNIT_SOURCE" "$unit_manifest_name"
	verify_signed_checkout_file "$EXTERNAL_RUN_SOURCE" "$external_manifest_name"
	verify_signed_checkout_file "$MINISIGN_PUBLIC_KEY" "$key_manifest_name"
fi

EXPECTED_SHA256="$(awk -v asset="$ASSET" '$2 == asset || $2 == "*" asset { print $1 }' "$CHECKSUMS")"
printf '%s\n' "$EXPECTED_SHA256" | grep -Eq '^[0-9a-f]{64}$' || \
	fail "release checksum does not contain one valid SHA-256 for $ASSET"
ACTUAL_SHA256="$(sha256sum "$BUILD_BINARY" | awk '{ print $1 }')"
[ "$ACTUAL_SHA256" = "$EXPECTED_SHA256" ] || \
	fail "SHA-256 mismatch for $ASSET"

file "$BUILD_BINARY" | grep -q 'ELF' || fail "downloaded asset is not an ELF binary"
file "$BUILD_BINARY" | grep -Eq 'statically linked|static-pie linked' || \
	fail "downloaded asset is not statically linked"
case "$ARCH" in
	amd64) readelf -h "$BUILD_BINARY" | grep -q 'Advanced Micro Devices X86-64' || fail "ELF architecture mismatch" ;;
	arm64) readelf -h "$BUILD_BINARY" | grep -q 'AArch64' || fail "ELF architecture mismatch" ;;
esac

chmod 0755 "$BUILD_BINARY"
VERSION_OUTPUT="$("$BUILD_BINARY" version)"
printf '%s\n' "$VERSION_OUTPUT"
printf '%s\n' "$VERSION_OUTPUT" | grep -Fxq "mini-singbox $RELEASE_TAG" || \
	fail "downloaded binary version does not match release $RELEASE_TAG"
printf '%s\n' "$VERSION_OUTPUT" | grep -Fxq "git_commit $SOURCE_COMMIT" || \
	fail "downloaded binary full commit does not match source checkout"
printf '%s\n' "$VERSION_OUTPUT" | grep -Fxq "target linux/$ARCH" || \
	fail "downloaded binary architecture does not match this VM"
printf '%s\n' "$VERSION_OUTPUT" | grep -Fxq 'dirty_build false' || \
	fail "downloaded binary is marked dirty"

group_exists() {
	if command_exists getent; then
		getent group "$1" >/dev/null 2>&1
	else
		awk -F: -v group="$1" '$1 == group { found = 1 } END { exit !found }' /etc/group
	fi
}

if ! group_exists "$SERVICE_USER"; then
	log "Creating dedicated service group"
	groupadd --system "$SERVICE_USER"
fi
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
	log "Creating dedicated service user"
	NOLOGIN_SHELL="$(command -v nologin 2>/dev/null || printf '/sbin/nologin')"
	useradd --system --gid "$SERVICE_USER" --home-dir /nonexistent --shell "$NOLOGIN_SHELL" "$SERVICE_USER"
elif [ "$(id -gn "$SERVICE_USER")" != "$SERVICE_USER" ]; then
	log "Assigning the existing service user to its dedicated primary group"
	usermod -g "$SERVICE_USER" "$SERVICE_USER"
fi

CONFIG_REPLACED=0

if [ "$NEEDS_GENERATION" -eq 1 ]; then
	GENERATED_DIR="$WORK_DIR/generated"
	install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$GENERATED_DIR"
	log "Generating a new local configuration without printing credentials"
	runuser -u "$SERVICE_USER" -- "$BUILD_BINARY" generate \
		--output "$GENERATED_DIR" \
		--protocols "$PROTOCOLS" \
		--listen "$LISTEN_ADDRESS" \
		--public-address "$PUBLIC_ADDRESS" \
		--reality-port "$REALITY_PORT" \
		--hy2-port "$HY2_PORT" \
		--anytls-port "$ANYTLS_PORT" \
		--public-reality-port "$PUBLIC_REALITY_PORT" \
		--public-hy2-port "$PUBLIC_HY2_PORT" \
		--public-anytls-port "$PUBLIC_ANYTLS_PORT" \
		--reality-server-name "$REALITY_SERVER_NAME" \
		--reality-handshake "$REALITY_HANDSHAKE" \
		--tls-san "$TLS_SAN" \
		--allow-insecure-anytls-share="$ALLOW_INSECURE_ANYTLS_SHARE"
	runuser -u "$SERVICE_USER" -- "$BUILD_BINARY" check -c "$GENERATED_DIR/config.json"
	if [ -f "$GENERATED_DIR/share-reality.txt" ] || \
		[ -f "$GENERATED_DIR/share-hysteria2.txt" ] || \
		[ -f "$GENERATED_DIR/share-anytls.txt" ]; then
		log "Rendering local QR images without printing credentials"
		for qr_source in share-reality share-hysteria2 share-anytls; do
			if [ -f "$GENERATED_DIR/$qr_source.txt" ]; then
				qrencode -l M -t PNG -o "$GENERATED_DIR/$qr_source.png" < "$GENERATED_DIR/$qr_source.txt"
				chown "$SERVICE_USER:$SERVICE_USER" "$GENERATED_DIR/$qr_source.png"
				chmod 0600 "$GENERATED_DIR/$qr_source.png"
			fi
		done
	fi
	CONFIG_REPLACED=1
else
	log "Preserving and validating existing $CONFIG_DIR/config.json"
	runuser -u "$SERVICE_USER" -- "$BUILD_BINARY" check -c "$CONFIG_DIR/config.json"
	if [ "$REFRESH_DELIVERY" -eq 1 ]; then
		DELIVERY_DIR="$WORK_DIR/delivery"
		install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$DELIVERY_DIR"
		log "Rebuilding client delivery files without changing server credentials"
		runuser -u "$SERVICE_USER" -- "$BUILD_BINARY" deliver \
			-c "$CONFIG_DIR/config.json" \
			--output "$DELIVERY_DIR" \
			--public-address "$PUBLIC_ADDRESS" \
			--reality-port "$PUBLIC_REALITY_PORT" \
			--hy2-port "$PUBLIC_HY2_PORT" \
			--anytls-port "$PUBLIC_ANYTLS_PORT" \
			--allow-insecure-anytls-share="$ALLOW_INSECURE_ANYTLS_SHARE"
		log "Rendering refreshed local QR images without printing credentials"
		for qr_source in share-reality share-hysteria2 share-anytls; do
			if [ -f "$DELIVERY_DIR/$qr_source.txt" ]; then
				qrencode -l M -t PNG -o "$DELIVERY_DIR/$qr_source.png" < "$DELIVERY_DIR/$qr_source.txt"
				chown "$SERVICE_USER:$SERVICE_USER" "$DELIVERY_DIR/$qr_source.png"
				chmod 0600 "$DELIVERY_DIR/$qr_source.png"
			fi
		done
		DELIVERY_REPLACED=1
	fi
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP-$SHORT_COMMIT-$$"
install -d -m 0700 "$BACKUP_ROOT"
install -d -m 0700 "$BACKUP_DIR"

if [ -f "$INSTALL_PATH" ]; then
	HAD_BINARY=1
	cp -a "$INSTALL_PATH" "$BACKUP_DIR/mini-singbox"
fi
if [ -f "$CONTROL_PATH" ]; then
	HAD_CONTROL=1
	cp -a "$CONTROL_PATH" "$BACKUP_DIR/mini-singboxctl"
fi
if [ -f "$CONTAINER_CONTROL_PATH" ]; then
	HAD_CONTAINER_CONTROL=1
	cp -a "$CONTAINER_CONTROL_PATH" "$BACKUP_DIR/mini-singbox-containerctl"
fi
if [ -f "$UPDATE_PATH" ]; then
	HAD_UPDATE=1
	cp -a "$UPDATE_PATH" "$BACKUP_DIR/mini-singbox-update"
fi
if [ -f "$UNINSTALL_PATH" ]; then
	HAD_UNINSTALL=1
	cp -a "$UNINSTALL_PATH" "$BACKUP_DIR/mini-singbox-uninstall"
fi
if [ "$MIGRATION_FROM_RUNTIME" = external ] && [ -f "$EXTERNAL_RUN_PATH" ]; then
	HAD_EXTERNAL_RUN=1
	cp -a "$EXTERNAL_RUN_PATH" "$BACKUP_DIR/mini-singbox-run"
fi
if [ -f "$UNIT_PATH" ]; then
	HAD_UNIT=1
	cp -a "$UNIT_PATH" "$BACKUP_DIR/runtime-unit"
fi
if [ -d "$CONFIG_DIR" ]; then
	HAD_CONFIG=1
	cp -a "$CONFIG_DIR" "$BACKUP_DIR/config"
fi
if runtime_is_active; then
	WAS_ACTIVE=1
fi
if runtime_is_enabled; then
	WAS_ENABLED=1
fi

if [ "$RUNTIME" = external ] && [ "$WAS_ACTIVE" -eq 1 ]; then
	fail "external process is active; stop the surrounding supervisor before upgrading"
fi

DEPLOYMENT_STARTED=1
log "Installing the binary, on-demand tools, configuration, and $RUNTIME runtime"
runtime_stop >/dev/null 2>&1 || true
install -m 0755 "$BUILD_BINARY" "$INSTALL_PATH"
install -m 0755 "$CONTROL_SOURCE" "$CONTROL_PATH"
install -m 0755 "$CONTAINER_CONTROL_SOURCE" "$CONTAINER_CONTROL_PATH"
install -m 0755 "$UPDATE_SOURCE" "$UPDATE_PATH"
install -m 0755 "$UNINSTALL_SOURCE" "$UNINSTALL_PATH"
case "$RUNTIME" in
	systemd) install -m 0644 "$UNIT_SOURCE" "$UNIT_PATH" ;;
	openrc|external) install -m 0755 "$UNIT_SOURCE" "$UNIT_PATH" ;;
esac
if [ "$RUNTIME" = openrc ]; then
	if [ -L "$OPENRC_LOG_DIR" ] || { [ -e "$OPENRC_LOG_DIR" ] && [ ! -d "$OPENRC_LOG_DIR" ]; }; then
		fail "OpenRC log directory is missing or unsafe: $OPENRC_LOG_DIR"
	fi
	install -d -m 0710 -o root -g "$SERVICE_USER" "$OPENRC_LOG_DIR"
	if [ -e "$OPENRC_LOG_PATH" ]; then
		if [ ! -f "$OPENRC_LOG_PATH" ] || [ -L "$OPENRC_LOG_PATH" ]; then
			fail "OpenRC log file is unsafe: $OPENRC_LOG_PATH"
		fi
		chown "root:$SERVICE_USER" "$OPENRC_LOG_PATH"
		chmod 0620 "$OPENRC_LOG_PATH"
	else
		install -m 0620 -o root -g "$SERVICE_USER" /dev/null "$OPENRC_LOG_PATH"
	fi
fi
if [ "$RUNTIME" = external ]; then
	install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" /run/mini-singbox
fi

if [ "$CONFIG_REPLACED" -eq 1 ]; then
	[ "$CONFIG_DIR" = "/etc/mini-singbox" ] || fail "unsafe config path"
	rm -rf "$CONFIG_DIR"
	install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$CONFIG_DIR"
	for generated_file in \
		config.json client-info.json reality.key tls.key tls.crt \
		client-anytls-sing-box-outbound.json \
		share-reality.txt share-hysteria2.txt share-anytls.txt \
		share-reality.png share-hysteria2.png share-anytls.png; do
		if [ -f "$GENERATED_DIR/$generated_file" ]; then
			case "$generated_file" in
				tls.crt) mode=0644 ;;
				*) mode=0600 ;;
			esac
			install -m "$mode" -o "$SERVICE_USER" -g "$SERVICE_USER" \
				"$GENERATED_DIR/$generated_file" "$CONFIG_DIR/$generated_file"
		fi
	done
fi

if [ "$DELIVERY_REPLACED" -eq 1 ]; then
	for delivery_file in \
		client-info.json client-anytls-sing-box-outbound.json \
		share-reality.txt share-hysteria2.txt share-anytls.txt \
		share-reality.png share-hysteria2.png share-anytls.png; do
		if [ -f "$DELIVERY_DIR/$delivery_file" ]; then
			install -m 0600 -o "$SERVICE_USER" -g "$SERVICE_USER" \
				"$DELIVERY_DIR/$delivery_file" "$CONFIG_DIR/$delivery_file"
		else
			rm -f "$CONFIG_DIR/$delivery_file"
		fi
	done
fi

CURRENT_PROTOCOLS="$(jq -r '[
	if .vless_reality then "reality" else empty end,
	if .hysteria2 then "hy2" else empty end,
	if .anytls then "anytls" else empty end
] | join(",")' "$CONFIG_DIR/config.json")"
CURRENT_PUBLIC_ADDRESS="$(jq -r '.public_address // "unknown"' "$CONFIG_DIR/client-info.json")"
{
	printf 'source_commit=%s\n' "$SOURCE_COMMIT"
	printf 'protocols=%s\n' "$CURRENT_PROTOCOLS"
	printf 'runtime=%s\n' "$RUNTIME"
	printf 'runtime_profile=%s\n' "$UNIT_PROFILE"
	printf 'containerized=%s\n' "$CONTAINERIZED"
	printf 'public_address=%s\n' "$CURRENT_PUBLIC_ADDRESS"
	if jq -e '.vless_reality' "$CONFIG_DIR/config.json" >/dev/null; then
		printf 'reality_listen_port=%s/tcp\n' "$(jq -r '.vless_reality.port' "$CONFIG_DIR/config.json")"
		printf 'reality_public_port=%s/tcp\n' "$(jq -r '.vless_reality.port' "$CONFIG_DIR/client-info.json")"
		printf 'vless_reality_public_port_source=%s\n' "$REALITY_PUBLIC_PORT_SOURCE"
		printf 'reality_target=%s:%s\n' \
			"$(jq -r '.vless_reality.handshake_server' "$CONFIG_DIR/config.json")" \
			"$(jq -r '.vless_reality.handshake_port' "$CONFIG_DIR/config.json")"
	fi
	if jq -e '.hysteria2' "$CONFIG_DIR/config.json" >/dev/null; then
		printf 'hysteria2_listen_port=%s/udp\n' "$(jq -r '.hysteria2.port' "$CONFIG_DIR/config.json")"
		printf 'hysteria2_public_port=%s/udp\n' "$(jq -r '.hysteria2.port' "$CONFIG_DIR/client-info.json")"
		printf 'hysteria2_public_port_source=%s\n' "$HY2_PUBLIC_PORT_SOURCE"
	fi
	if jq -e '.anytls' "$CONFIG_DIR/config.json" >/dev/null; then
		printf 'anytls_listen_port=%s/tcp\n' "$(jq -r '.anytls.port' "$CONFIG_DIR/config.json")"
		printf 'anytls_public_port=%s/tcp\n' "$(jq -r '.anytls.port' "$CONFIG_DIR/client-info.json")"
		printf 'anytls_public_port_source=%s\n' "$ANYTLS_PUBLIC_PORT_SOURCE"
	fi
} > "$WORK_DIR/deployment-info.txt"
install -m 0600 -o "$SERVICE_USER" -g "$SERVICE_USER" \
	"$WORK_DIR/deployment-info.txt" "$CONFIG_DIR/deployment-info.txt"
DEPLOYMENT_INFO_REWRITTEN=1

runuser -u "$SERVICE_USER" -- "$INSTALL_PATH" check -c "$CONFIG_DIR/config.json"
LISTENER_PROTOCOLS="$CURRENT_PROTOCOLS"
MAIN_PID=""
PROCESS_USER="$SERVICE_USER"
if [ "$RUNTIME" != external ]; then
	runtime_reload
	runtime_enable
	runtime_start

	attempt=0
	while [ "$attempt" -lt 15 ]; do
		if runtime_is_active; then
			break
		fi
		attempt=$((attempt + 1))
		sleep 1
	done

	if ! runtime_is_active; then
		runtime_recent_logs
		fail "$RUNTIME service did not become active"
	fi

	# Catch immediate post-start failures instead of accepting a transient active state.
	sleep 5
	if ! runtime_is_active; then
		runtime_recent_logs
		fail "$RUNTIME service exited during the five-second startup observation"
	fi

	MAIN_PID="$(runtime_main_pid)"
	case "$MAIN_PID" in
		''|*[!0-9]*|0) fail "$RUNTIME did not report a valid mini-singbox PID" ;;
	esac
	PROCESS_USER="$(ps -o user= -p "$MAIN_PID" | awk '{$1=$1; print}')"
	[ "$PROCESS_USER" = "$SERVICE_USER" ] || fail "service is running as unexpected user $PROCESS_USER"
else
	log "External runtime prepared; the surrounding platform must launch $EXTERNAL_RUN_PATH"
fi

verify_listener() {
	transport="$1"
	port="$2"
	label="$3"
	case "$port" in
		""|*[!0-9]*) fail "invalid recorded $label port: $port" ;;
	esac
	case "$transport" in
		tcp) socket_output="$(ss -lntH)" ;;
		udp) socket_output="$(ss -lnuH)" ;;
		*) fail "internal listener transport error: $transport" ;;
	esac
	if ! matched_socket="$(printf '%s\n' "$socket_output" | awk -v port="$port" '
		$4 ~ (":" port "$") { print; found = 1 }
		END { if (!found) exit 1 }
	')"; then
		runtime_recent_logs
		fail "$label is not listening on $transport/$port"
	fi
	printf '%-10s %s/%s  %s\n' "$label" "$transport" "$port" "$matched_socket"
}

if [ "$RUNTIME" != external ]; then
	log "Verifying listening sockets"
	if jq -e '.vless_reality' "$CONFIG_DIR/config.json" >/dev/null; then
		verify_listener tcp "$(jq -r '.vless_reality.port' "$CONFIG_DIR/config.json")" Reality
	fi
	if jq -e '.hysteria2' "$CONFIG_DIR/config.json" >/dev/null; then
		verify_listener udp "$(jq -r '.hysteria2.port' "$CONFIG_DIR/config.json")" Hysteria2
	fi
	if jq -e '.anytls' "$CONFIG_DIR/config.json" >/dev/null; then
		verify_listener tcp "$(jq -r '.anytls.port' "$CONFIG_DIR/config.json")" AnyTLS
	fi
fi

HAS_SHARE_LINKS=0
MISSING_DELIVERY=0
for protocol_and_source in \
	"reality:share-reality" "hy2:share-hysteria2"; do
	protocol="${protocol_and_source%%:*}"
	qr_source="${protocol_and_source#*:}"
	case ",$LISTENER_PROTOCOLS," in
		*,"$protocol",*)
			if [ -f "$CONFIG_DIR/$qr_source.txt" ] && [ ! -L "$CONFIG_DIR/$qr_source.txt" ] && \
				[ -f "$CONFIG_DIR/$qr_source.png" ] && [ ! -L "$CONFIG_DIR/$qr_source.png" ]; then
				HAS_SHARE_LINKS=1
			else
				MISSING_DELIVERY=1
				warn "missing share link or QR image for enabled protocol $protocol"
			fi
			;;
	esac
done
case ",$LISTENER_PROTOCOLS," in
	*,anytls,*)
		if [ ! -f "$CONFIG_DIR/client-anytls-sing-box-outbound.json" ] || \
			[ -L "$CONFIG_DIR/client-anytls-sing-box-outbound.json" ]; then
			MISSING_DELIVERY=1
			warn "missing authenticated AnyTLS sing-box outbound file"
		fi
		if [ "$ALLOW_INSECURE_ANYTLS_SHARE" -eq 1 ]; then
			if [ -f "$CONFIG_DIR/share-anytls.txt" ] && [ ! -L "$CONFIG_DIR/share-anytls.txt" ] && \
				[ -f "$CONFIG_DIR/share-anytls.png" ] && [ ! -L "$CONFIG_DIR/share-anytls.png" ]; then
				HAS_SHARE_LINKS=1
			else
				MISSING_DELIVERY=1
				warn "explicitly requested insecure AnyTLS share link or QR image is missing"
			fi
		elif [ -e "$CONFIG_DIR/share-anytls.txt" ] || [ -L "$CONFIG_DIR/share-anytls.txt" ] || \
			[ -e "$CONFIG_DIR/share-anytls.png" ] || [ -L "$CONFIG_DIR/share-anytls.png" ]; then
			MISSING_DELIVERY=1
			warn "unauthenticated AnyTLS share artifacts remain while insecure sharing is disabled"
		fi
		;;
esac
if { [ "$CONFIG_REPLACED" -eq 1 ] || [ "$DELIVERY_REPLACED" -eq 1 ]; } && \
	[ "$MISSING_DELIVERY" -eq 1 ]; then
	fail "new client delivery files did not satisfy the authenticated delivery policy"
fi

if [ "$AUTO_TUNE" -eq 1 ]; then
	log "Applying conservative, reversible TCP tuning"
	if "$INSTALL_PATH" tune apply -c "$CONFIG_DIR/config.json" --state-dir /var/lib/mini-singbox/tune; then
		"$INSTALL_PATH" tune verify -c "$CONFIG_DIR/config.json" --state-dir /var/lib/mini-singbox/tune || \
			warn "TCP tuning verification reported drift; inspect with: sudo mini-singboxctl tune status"
	else
		warn "automatic TCP tuning was skipped or recovered after an error; inspect with: sudo mini-singboxctl tune status"
	fi
else
	if [ -n "$AUTO_TUNE_DISABLED_REASON" ]; then
		log "Automatic TCP tuning disabled: $AUTO_TUNE_DISABLED_REASON"
	else
		log "Automatic TCP tuning disabled by MINI_SINGBOX_AUTO_TUNE=0"
	fi
fi

if ! prune_managed_backups; then
	warn "backup retention encountered an error; existing backups were left in place"
fi

if [ "$MIGRATION_FROM_RUNTIME" = external ]; then
	EXTERNAL_RUN_REMOVED=1
	rm -f "$EXTERNAL_RUN_PATH"
	log "Retired the external runner after successful migration to OpenRC"
fi

DEPLOYMENT_SUCCEEDED=1
log "Deployment succeeded"
printf 'source commit: %s\n' "$SOURCE_COMMIT"
if [ "$RUNTIME" = external ]; then
	printf 'service:       prepared for an external supervisor; not started automatically\n'
	printf 'start command: %s\n' "$EXTERNAL_RUN_PATH"
else
	printf 'service:       active as %s (PID %s)\n' "$PROCESS_USER" "$MAIN_PID"
fi
printf 'runtime:       %s (%s)\n' "$RUNTIME" "$UNIT_PROFILE"
printf 'configuration: %s/config.json\n' "$CONFIG_DIR"
printf 'client info:   %s/client-info.json (sensitive)\n' "$CONFIG_DIR"
printf 'control:       sudo mini-singboxctl status\n'
printf 'TCP tuning:    sudo mini-singboxctl tune status\n'
printf 'update:        sudo mini-singbox-update\n'
printf 'uninstall:     sudo mini-singbox-uninstall\n'
if [ "$HAS_SHARE_LINKS" -eq 1 ]; then
	printf 'share links:   %s/share-*.txt (sensitive)\n' "$CONFIG_DIR"
	printf 'QR images:     %s/share-*.png (sensitive)\n' "$CONFIG_DIR"
	for qr_source in share-reality share-hysteria2 share-anytls; do
		if [ -f "$CONFIG_DIR/$qr_source.txt" ]; then
			case "$qr_source" in
				share-reality) qr_protocol=reality ;;
				share-hysteria2) qr_protocol=hy2 ;;
				share-anytls) qr_protocol=anytls ;;
			esac
			printf 'terminal QR:   sudo mini-singboxctl qr %s\n' "$qr_protocol"
			break
		fi
	done
else
	warn "no QR-compatible share links are available for the enabled protocols"
fi
if [ -f "$CONFIG_DIR/client-anytls-sing-box-outbound.json" ]; then
	printf 'AnyTLS client: %s/client-anytls-sing-box-outbound.json (authenticated sing-box outbound; sensitive)\n' "$CONFIG_DIR"
fi
if [ -f "$CONFIG_DIR/deployment-info.txt" ]; then
	printf 'deployment:    %s/deployment-info.txt\n' "$CONFIG_DIR"
fi
printf 'backup:        %s\n' "$BACKUP_DIR"
if [ "$RUNTIME" = external ]; then
	printf 'logs:          use the surrounding platform or supervisor\n'
else
	printf 'logs:          sudo mini-singboxctl logs 100\n'
fi

printf '\nFirewall/security-group ports are not changed by this script.\n'
printf 'Open only the enabled protocol ports: Reality TCP, Hysteria2 UDP, AnyTLS TCP.\n'
