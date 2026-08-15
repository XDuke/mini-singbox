#!/bin/sh
set -eu

REPOSITORY="XDuke/mini-singbox"
VERSION="${MINI_SINGBOX_VERSION:-}"
PUBLIC_KEY_FILE="${MINI_SINGBOX_MINISIGN_PUBKEY_FILE:-}"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/mini-singbox"
SERVICE_USER="mini-singbox"
AUTO_TUNE="${MINI_SINGBOX_AUTO_TUNE:-1}"

fail() {
	echo "mini-singbox installer: $*" >&2
	exit 1
}

[ "$(id -u)" -eq 0 ] || fail "run as root"
[ -n "$VERSION" ] || fail "set MINI_SINGBOX_VERSION to an exact tag such as v1.0.0"
echo "$VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' || fail "invalid exact version: $VERSION"
[ -n "$PUBLIC_KEY_FILE" ] || fail "set MINI_SINGBOX_MINISIGN_PUBKEY_FILE to the pinned official release public key"
[ -f "$PUBLIC_KEY_FILE" ] || fail "minisign public key file not found: $PUBLIC_KEY_FILE"
case "$AUTO_TUNE" in
	0|1) ;;
	*) fail "MINI_SINGBOX_AUTO_TUNE must be 0 or 1" ;;
esac

case "$(uname -m)" in
	x86_64|amd64) ARCH="amd64" ;;
	aarch64|arm64) ARCH="arm64" ;;
	*) fail "unsupported architecture: $(uname -m)" ;;
esac

for command_name in minisign sha256sum file readelf; do
	command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done

download() {
	url="$1"
	output="$2"
	if command -v curl >/dev/null 2>&1; then
		curl --fail --location --proto '=https' --tlsv1.2 --output "$output" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget --https-only --output-document="$output" "$url"
	else
		fail "curl or wget is required"
	fi
}

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
asset="mini-singbox-linux-$ARCH"
release_base="https://github.com/$REPOSITORY/releases/download/$VERSION"
download "$release_base/$asset" "$temporary_directory/$asset"
download "$release_base/SHA256SUMS" "$temporary_directory/SHA256SUMS"
download "$release_base/SHA256SUMS.minisig" "$temporary_directory/SHA256SUMS.minisig"

minisign -Vm "$temporary_directory/SHA256SUMS" \
	-x "$temporary_directory/SHA256SUMS.minisig" \
	-p "$PUBLIC_KEY_FILE" >/dev/null

expected_hash="$(awk -v asset="$asset" '$2 == asset || $2 == "*" asset { print $1 }' "$temporary_directory/SHA256SUMS")"
[ -n "$expected_hash" ] || fail "release checksum does not contain $asset"
actual_hash="$(sha256sum "$temporary_directory/$asset" | awk '{ print $1 }')"
[ "$actual_hash" = "$expected_hash" ] || fail "SHA-256 mismatch for $asset"

verify_release_file() {
	file_path="$1"
	checksum_name="$2"
	expected="$(awk -v asset="$checksum_name" '$2 == asset || $2 == "*" asset { print $1 }' "$temporary_directory/SHA256SUMS")"
	[ -n "$expected" ] || fail "release checksum does not contain $checksum_name"
	actual="$(sha256sum "$file_path" | awk '{ print $1 }')"
	[ "$actual" = "$expected" ] || fail "SHA-256 mismatch for local release file $checksum_name"
}

script_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
control_source="$script_root/scripts/mini-singboxctl"
update_source="$script_root/bootstrap.sh"
uninstall_source="$script_root/scripts/uninstall.sh"
[ -f "$control_source" ] || fail "control tool missing from release package"
[ -f "$update_source" ] || fail "update tool missing from release package"
[ -f "$uninstall_source" ] || fail "uninstall tool missing from release package"
verify_release_file "$control_source" "scripts/mini-singboxctl"
verify_release_file "$update_source" "bootstrap.sh"
verify_release_file "$uninstall_source" "scripts/uninstall.sh"

file "$temporary_directory/$asset" | grep -q 'ELF' || fail "download is not an ELF binary"
file "$temporary_directory/$asset" | grep -Eq 'statically linked|static-pie linked' || fail "binary is not static"
case "$ARCH" in
	amd64) readelf -h "$temporary_directory/$asset" | grep -q 'Advanced Micro Devices X86-64' || fail "ELF architecture mismatch" ;;
	arm64) readelf -h "$temporary_directory/$asset" | grep -q 'AArch64' || fail "ELF architecture mismatch" ;;
esac
chmod 0755 "$temporary_directory/$asset"
"$temporary_directory/$asset" version | grep -Fq "mini-singbox $VERSION" || fail "binary version output does not match $VERSION"

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
	if command -v useradd >/dev/null 2>&1; then
		useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"
	elif command -v adduser >/dev/null 2>&1; then
		adduser -S -H -h /nonexistent -s /sbin/nologin "$SERVICE_USER"
	else
		fail "cannot create service user"
	fi
fi

install -d -m 0755 "$INSTALL_DIR"
install -m 0755 "$temporary_directory/$asset" "$INSTALL_DIR/mini-singbox"
install -m 0755 "$control_source" "$INSTALL_DIR/mini-singboxctl"
install -m 0755 "$update_source" "$INSTALL_DIR/mini-singbox-update"
install -m 0755 "$uninstall_source" "$INSTALL_DIR/mini-singbox-uninstall"
install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$CONFIG_DIR"

if [ ! -f "$CONFIG_DIR/config.json" ]; then
	protocols="${MINI_SINGBOX_PROTOCOLS:-reality,hy2,anytls}"
	listen_address="${MINI_SINGBOX_LISTEN:-::}"
	reality_server_name="${MINI_SINGBOX_REALITY_SERVER_NAME:-}"
	reality_handshake="${MINI_SINGBOX_REALITY_HANDSHAKE:-}"
	tls_san="${MINI_SINGBOX_TLS_SAN:-}"
	"$INSTALL_DIR/mini-singbox" generate \
		--output "$CONFIG_DIR" \
		--protocols "$protocols" \
		--listen "$listen_address" \
		--reality-server-name "$reality_server_name" \
		--reality-handshake "$reality_handshake" \
		--tls-san "$tls_san"
	chown "$SERVICE_USER:$SERVICE_USER" "$CONFIG_DIR"/*
fi

if command -v runuser >/dev/null 2>&1; then
	runuser -u "$SERVICE_USER" -- "$INSTALL_DIR/mini-singbox" check -c "$CONFIG_DIR/config.json"
else
	su -s /bin/sh -c "$INSTALL_DIR/mini-singbox check -c $CONFIG_DIR/config.json" "$SERVICE_USER"
fi

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
	[ -f "$script_root/packaging/systemd/mini-singbox.service" ] || fail "systemd unit missing from release package"
	verify_release_file "$script_root/packaging/systemd/mini-singbox.service" "packaging/systemd/mini-singbox.service"
	install -m 0644 "$script_root/packaging/systemd/mini-singbox.service" /etc/systemd/system/mini-singbox.service
	systemctl daemon-reload
	systemctl enable --now mini-singbox.service
elif command -v rc-service >/dev/null 2>&1; then
	[ -f "$script_root/packaging/openrc/mini-singbox" ] || fail "OpenRC service missing from release package"
	verify_release_file "$script_root/packaging/openrc/mini-singbox" "packaging/openrc/mini-singbox"
	install -m 0755 "$script_root/packaging/openrc/mini-singbox" /etc/init.d/mini-singbox
	rc-update add mini-singbox default
	rc-service mini-singbox start
else
	fail "neither systemd nor OpenRC was detected"
fi

if [ "$AUTO_TUNE" -eq 1 ]; then
	if ! "$INSTALL_DIR/mini-singbox" tune apply -c "$CONFIG_DIR/config.json" --state-dir /var/lib/mini-singbox/tune; then
		echo "mini-singbox installer: automatic TCP tuning was skipped or recovered after an error" >&2
	elif ! "$INSTALL_DIR/mini-singbox" tune verify -c "$CONFIG_DIR/config.json" --state-dir /var/lib/mini-singbox/tune; then
		echo "mini-singbox installer: TCP tuning verification reported drift" >&2
	fi
fi

echo "installed mini-singbox $VERSION"
echo "configuration: $CONFIG_DIR/config.json"
echo "client information: $CONFIG_DIR/client-info.json"
echo "control: sudo mini-singboxctl status"
echo "TCP tuning: sudo mini-singboxctl tune status"
echo "update: sudo mini-singbox-update"
echo "uninstall: sudo mini-singbox-uninstall"
