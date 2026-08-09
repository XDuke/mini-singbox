#!/bin/sh
set -eu

SERVICE="mini-singbox.service"
SERVICE_USER="mini-singbox"
INSTALL_PATH="/usr/local/bin/mini-singbox"
CONTROL_PATH="/usr/local/bin/mini-singboxctl"
CONFIG_DIR="/etc/mini-singbox"
UNIT_PATH="/etc/systemd/system/mini-singbox.service"
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

[ "$(id -u)" -eq 0 ] || fail "run as root (use sudo env ... ./scripts/deploy.sh)"
[ "$(uname -s)" = "Linux" ] || fail "this deployer supports Linux only"
command_exists systemctl || fail "systemd is required; use the OpenRC packaging manually on non-systemd systems"
[ -d /run/systemd/system ] || fail "systemd is not running"

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SOURCE_DIR="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)"
[ -f "$SOURCE_DIR/go.mod" ] || fail "go.mod not found next to the deployment script"
[ -f "$SOURCE_DIR/packaging/systemd/mini-singbox.service" ] || fail "packaged systemd unit is missing"
[ -f "$SOURCE_DIR/scripts/mini-singboxctl" ] || fail "control tool is missing"

UNIT_SOURCE="$SOURCE_DIR/packaging/systemd/mini-singbox.service"
CONTROL_SOURCE="$SOURCE_DIR/scripts/mini-singboxctl"
UNIT_PROFILE="full"
if command_exists systemd-detect-virt && systemd-detect-virt --container --quiet; then
	UNIT_SOURCE="$SOURCE_DIR/packaging/systemd/mini-singbox-container.service"
	UNIT_PROFILE="container-compatible"
	[ -f "$UNIT_SOURCE" ] || fail "container-compatible systemd unit is missing"
	warn "container virtualization detected; using the container-compatible systemd sandbox"
fi

if ! command_exists git; then
	fail "git is required; clone the repository before running this script"
fi
git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "run this script from a Git checkout"
[ -z "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=no)" ] || \
	fail "tracked source files are modified; commit or restore them before deployment"

SOURCE_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
SHORT_COMMIT="$(printf '%s' "$SOURCE_COMMIT" | cut -c1-12)"
EXACT_RELEASE_TAG="$(git -C "$SOURCE_DIR" tag --points-at "$SOURCE_COMMIT" | \
	grep -E '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$' | \
	sort -V | tail -n 1 || true)"
RELEASE_TAG="${MINI_SINGBOX_RELEASE_TAG:-${EXACT_RELEASE_TAG:-candidate-$SHORT_COMMIT}}"
MINISIGN_PUBLIC_KEY="${MINI_SINGBOX_MINISIGN_PUBKEY_FILE:-$SOURCE_DIR/release/minisign.pub}"
SIGNED_RELEASE=0
case "$RELEASE_TAG" in
	v[0-9]*.[0-9]*.[0-9]*)
		[ "$RELEASE_TAG" = "$EXACT_RELEASE_TAG" ] || \
			fail "release tag $RELEASE_TAG does not point at source commit $SOURCE_COMMIT"
		SIGNED_RELEASE=1
		;;
	"candidate-$SHORT_COMMIT") ;;
	*) fail "release tag must be the exact source tag or candidate-$SHORT_COMMIT" ;;
esac

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
REFRESH_DELIVERY="${MINI_SINGBOX_REFRESH_DELIVERY:-0}"
AUTO_DETECT="${MINI_SINGBOX_AUTO_DETECT:-1}"
IP_FAMILY="${MINI_SINGBOX_IP_FAMILY:-auto}"
REALITY_CANDIDATES="${MINI_SINGBOX_REALITY_CANDIDATES:-www.microsoft.com,www.amazon.com,www.mozilla.org,www.cloudflare.com}"
NEEDS_GENERATION=0

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
if [ ! -f "$CONFIG_DIR/config.json" ] || [ "${MINI_SINGBOX_REGENERATE:-0}" = "1" ]; then
	NEEDS_GENERATION=1
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
	if ! command_exists ss || ! command_exists ip; then
		missing_packages="$missing_packages iproute2"
	fi
	command_exists useradd || missing_packages="$missing_packages passwd"
	command_exists groupadd || missing_packages="$missing_packages passwd"
	command_exists usermod || missing_packages="$missing_packages passwd"
	command_exists getent || missing_packages="$missing_packages libc-bin"
	command_exists ps || missing_packages="$missing_packages procps"
	command_exists openssl || missing_packages="$missing_packages openssl"
	command_exists qrencode || missing_packages="$missing_packages qrencode"
	command_exists jq || missing_packages="$missing_packages jq"
	command_exists file || missing_packages="$missing_packages file"
	command_exists readelf || missing_packages="$missing_packages binutils"
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
else
	required_commands="curl sha256sum runuser ss ip useradd groupadd usermod getent ps openssl qrencode jq timeout file readelf"
	if [ "$SIGNED_RELEASE" -eq 1 ]; then
		required_commands="$required_commands minisign"
	fi
	for required_command in $required_commands; do
		command_exists "$required_command" || \
			fail "missing $required_command; automatic package installation is supported only on Debian/Ubuntu"
	done
fi

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
	if systemctl is-active --quiet "$SERVICE"; then
		current_service_active=1
		candidate_pid="$(systemctl show "$SERVICE" -p MainPID --value)"
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
HAD_UNIT=0
HAD_CONFIG=0
WAS_ACTIVE=0
WAS_ENABLED=0
DELIVERY_REPLACED=0
DEPLOYMENT_INFO_REWRITTEN=0
BACKUP_DIR=""

rollback() {
	warn "deployment failed after installation began; restoring the previous state"
	systemctl stop "$SERVICE" >/dev/null 2>&1 || true

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

	if [ "$HAD_UNIT" -eq 1 ]; then
		install -m 0644 "$BACKUP_DIR/mini-singbox.service" "$UNIT_PATH"
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
				client-info.json share-reality.txt share-hysteria2.txt share-anytls.txt \
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

	systemctl daemon-reload >/dev/null 2>&1 || true
	if [ "$WAS_ENABLED" -eq 1 ] && [ "$HAD_UNIT" -eq 1 ]; then
		systemctl enable "$SERVICE" >/dev/null 2>&1 || true
	else
		systemctl disable "$SERVICE" >/dev/null 2>&1 || true
	fi
	if [ "$WAS_ACTIVE" -eq 1 ] && [ "$HAD_UNIT" -eq 1 ] && [ "$HAD_BINARY" -eq 1 ]; then
		systemctl start "$SERVICE" >/dev/null 2>&1 || true
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
	[ -f "$MINISIGN_PUBLIC_KEY" ] && [ ! -L "$MINISIGN_PUBLIC_KEY" ] || \
		fail "pinned minisign public key is missing or unsafe: $MINISIGN_PUBLIC_KEY"
	curl --fail --location --proto '=https' --tlsv1.2 \
		--retry 3 --connect-timeout 20 --output "$CHECKSUM_SIGNATURE" \
		"$RELEASE_BASE/SHA256SUMS.minisig"
	minisign -Vm "$CHECKSUMS" -x "$CHECKSUM_SIGNATURE" -p "$MINISIGN_PUBLIC_KEY" >/dev/null || \
		fail "release checksum signature verification failed"
fi

verify_signed_checkout_file() {
	local_file="$1"
	manifest_name="$2"
	[ -f "$local_file" ] && [ ! -L "$local_file" ] || \
		fail "release checkout file is missing or unsafe: $manifest_name"
	expected="$(awk -v asset="$manifest_name" '$2 == asset || $2 == "*" asset { print $1 }' "$CHECKSUMS")"
	printf '%s\n' "$expected" | grep -Eq '^[0-9a-f]{64}$' || \
		fail "signed checksum manifest does not contain one valid SHA-256 for $manifest_name"
	actual="$(sha256sum "$local_file" | awk '{ print $1 }')"
	[ "$actual" = "$expected" ] || fail "signed checkout verification failed for $manifest_name"
}

if [ "$SIGNED_RELEASE" -eq 1 ]; then
	verify_signed_checkout_file "$SOURCE_DIR/scripts/deploy.sh" scripts/deploy.sh
	verify_signed_checkout_file "$CONTROL_SOURCE" scripts/mini-singboxctl
	case "$UNIT_PROFILE" in
		full) unit_manifest_name=packaging/systemd/mini-singbox.service ;;
		container-compatible) unit_manifest_name=packaging/systemd/mini-singbox-container.service ;;
		*) fail "internal systemd profile error: $UNIT_PROFILE" ;;
	esac
	verify_signed_checkout_file "$UNIT_SOURCE" "$unit_manifest_name"
	verify_signed_checkout_file "$MINISIGN_PUBLIC_KEY" release/minisign.pub
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

if ! getent group "$SERVICE_USER" >/dev/null 2>&1; then
	log "Creating dedicated service group"
	groupadd --system "$SERVICE_USER"
fi
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
	log "Creating dedicated service user"
	NOLOGIN_SHELL="$(command -v nologin 2>/dev/null || printf '/usr/sbin/nologin')"
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
		--tls-san "$TLS_SAN"
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
			--anytls-port "$PUBLIC_ANYTLS_PORT"
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
if [ -f "$UNIT_PATH" ]; then
	HAD_UNIT=1
	cp -a "$UNIT_PATH" "$BACKUP_DIR/mini-singbox.service"
fi
if [ -d "$CONFIG_DIR" ]; then
	HAD_CONFIG=1
	cp -a "$CONFIG_DIR" "$BACKUP_DIR/config"
fi
if systemctl is-active --quiet "$SERVICE"; then
	WAS_ACTIVE=1
fi
if systemctl is-enabled --quiet "$SERVICE"; then
	WAS_ENABLED=1
fi

DEPLOYMENT_STARTED=1
log "Installing the binary, on-demand control tool, configuration, and hardened systemd unit"
systemctl stop "$SERVICE" >/dev/null 2>&1 || true
install -m 0755 "$BUILD_BINARY" "$INSTALL_PATH"
install -m 0755 "$CONTROL_SOURCE" "$CONTROL_PATH"
install -m 0644 "$UNIT_SOURCE" "$UNIT_PATH"

if [ "$CONFIG_REPLACED" -eq 1 ]; then
	[ "$CONFIG_DIR" = "/etc/mini-singbox" ] || fail "unsafe config path"
	rm -rf "$CONFIG_DIR"
	install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$CONFIG_DIR"
	for generated_file in \
		config.json client-info.json reality.key tls.key tls.crt \
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
		client-info.json share-reality.txt share-hysteria2.txt share-anytls.txt \
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
	printf 'systemd_profile=%s\n' "$UNIT_PROFILE"
	printf 'public_address=%s\n' "$CURRENT_PUBLIC_ADDRESS"
	if jq -e '.vless_reality' "$CONFIG_DIR/config.json" >/dev/null; then
		printf 'reality_listen_port=%s/tcp\n' "$(jq -r '.vless_reality.port' "$CONFIG_DIR/config.json")"
		printf 'reality_public_port=%s/tcp\n' "$(jq -r '.vless_reality.port' "$CONFIG_DIR/client-info.json")"
		printf 'reality_target=%s:%s\n' \
			"$(jq -r '.vless_reality.handshake_server' "$CONFIG_DIR/config.json")" \
			"$(jq -r '.vless_reality.handshake_port' "$CONFIG_DIR/config.json")"
	fi
	if jq -e '.hysteria2' "$CONFIG_DIR/config.json" >/dev/null; then
		printf 'hysteria2_listen_port=%s/udp\n' "$(jq -r '.hysteria2.port' "$CONFIG_DIR/config.json")"
		printf 'hysteria2_public_port=%s/udp\n' "$(jq -r '.hysteria2.port' "$CONFIG_DIR/client-info.json")"
	fi
	if jq -e '.anytls' "$CONFIG_DIR/config.json" >/dev/null; then
		printf 'anytls_listen_port=%s/tcp\n' "$(jq -r '.anytls.port' "$CONFIG_DIR/config.json")"
		printf 'anytls_public_port=%s/tcp\n' "$(jq -r '.anytls.port' "$CONFIG_DIR/client-info.json")"
	fi
} > "$WORK_DIR/deployment-info.txt"
install -m 0600 -o "$SERVICE_USER" -g "$SERVICE_USER" \
	"$WORK_DIR/deployment-info.txt" "$CONFIG_DIR/deployment-info.txt"
DEPLOYMENT_INFO_REWRITTEN=1

runuser -u "$SERVICE_USER" -- "$INSTALL_PATH" check -c "$CONFIG_DIR/config.json"
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null
systemctl restart "$SERVICE"

attempt=0
while [ "$attempt" -lt 15 ]; do
	if systemctl is-active --quiet "$SERVICE"; then
		break
	fi
	attempt=$((attempt + 1))
	sleep 1
done

if ! systemctl is-active --quiet "$SERVICE"; then
	journalctl -u "$SERVICE" -n 50 --no-pager >&2 || true
	fail "service did not become active"
fi

# Catch immediate post-start failures instead of accepting a transient active state.
sleep 5
if ! systemctl is-active --quiet "$SERVICE"; then
	journalctl -u "$SERVICE" -n 50 --no-pager >&2 || true
	fail "service exited during the five-second startup observation"
fi

MAIN_PID="$(systemctl show "$SERVICE" -p MainPID --value)"
case "$MAIN_PID" in
	''|*[!0-9]*|0) fail "systemd did not report a valid main PID" ;;
esac
PROCESS_USER="$(ps -o user= -p "$MAIN_PID" | awk '{$1=$1; print}')"
[ "$PROCESS_USER" = "$SERVICE_USER" ] || fail "service is running as unexpected user $PROCESS_USER"

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
		journalctl -u "$SERVICE" -n 50 --no-pager >&2 || true
		fail "$label is not listening on $transport/$port"
	fi
	printf '%-10s %s/%s  %s\n' "$label" "$transport" "$port" "$matched_socket"
}

log "Verifying listening sockets"
LISTENER_PROTOCOLS="$CURRENT_PROTOCOLS"
if jq -e '.vless_reality' "$CONFIG_DIR/config.json" >/dev/null; then
	verify_listener tcp "$(jq -r '.vless_reality.port' "$CONFIG_DIR/config.json")" Reality
fi
if jq -e '.hysteria2' "$CONFIG_DIR/config.json" >/dev/null; then
	verify_listener udp "$(jq -r '.hysteria2.port' "$CONFIG_DIR/config.json")" Hysteria2
fi
if jq -e '.anytls' "$CONFIG_DIR/config.json" >/dev/null; then
	verify_listener tcp "$(jq -r '.anytls.port' "$CONFIG_DIR/config.json")" AnyTLS
fi

HAS_SHARE_LINKS=0
MISSING_SHARE_LINKS=0
for protocol_and_source in \
	"reality:share-reality" "hy2:share-hysteria2" "anytls:share-anytls"; do
	protocol="${protocol_and_source%%:*}"
	qr_source="${protocol_and_source#*:}"
	case ",$LISTENER_PROTOCOLS," in
		*,"$protocol",*)
			if [ -f "$CONFIG_DIR/$qr_source.txt" ] && [ -f "$CONFIG_DIR/$qr_source.png" ]; then
				HAS_SHARE_LINKS=1
			else
				MISSING_SHARE_LINKS=1
				warn "missing share link or QR image for enabled protocol $protocol"
			fi
			;;
	esac
done
if [ "$CONFIG_REPLACED" -eq 1 ] && [ "$MISSING_SHARE_LINKS" -eq 1 ]; then
	fail "new configuration did not produce every enabled protocol QR image"
fi

DEPLOYMENT_SUCCEEDED=1
log "Deployment succeeded"
printf 'source commit: %s\n' "$SOURCE_COMMIT"
printf 'service:       active as %s (PID %s)\n' "$PROCESS_USER" "$MAIN_PID"
printf 'unit profile:  %s\n' "$UNIT_PROFILE"
printf 'configuration: %s/config.json\n' "$CONFIG_DIR"
printf 'client info:   %s/client-info.json (sensitive)\n' "$CONFIG_DIR"
printf 'control:       sudo mini-singboxctl status\n'
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
	warn "share links or QR images are absent; use MINI_SINGBOX_REGENERATE=1 once to generate them"
fi
if [ -f "$CONFIG_DIR/deployment-info.txt" ]; then
	printf 'deployment:    %s/deployment-info.txt\n' "$CONFIG_DIR"
fi
printf 'backup:        %s\n' "$BACKUP_DIR"
printf 'logs:          sudo mini-singboxctl logs 100\n'

printf '\nFirewall/security-group ports are not changed by this script.\n'
printf 'Open only the enabled protocol ports: Reality TCP, Hysteria2 UDP, AnyTLS TCP.\n'
