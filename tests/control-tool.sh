#!/bin/sh
set -eu

[ "$#" -eq 2 ] || {
	echo "usage: $0 CONTROL_TOOL MINI_SINGBOX_BINARY" >&2
	exit 2
}

CONTROL_TOOL="$1"
BINARY="$2"
[ -x "$CONTROL_TOOL" ] || {
	echo "control tool is not executable: $CONTROL_TOOL" >&2
	exit 1
}
[ -x "$BINARY" ] || {
	echo "binary is not executable: $BINARY" >&2
	exit 1
}

WORK_DIRECTORY="$(mktemp -d)"
cleanup() {
	case "$WORK_DIRECTORY" in
		/tmp/*) rm -rf "$WORK_DIRECTORY" ;;
		*) echo "refusing to remove unexpected test directory: $WORK_DIRECTORY" >&2 ;;
	esac
}
trap cleanup EXIT HUP INT TERM

CONFIG_DIRECTORY="$WORK_DIRECTORY/config"
mkdir "$CONFIG_DIRECTORY"
chmod 0700 "$CONFIG_DIRECTORY"

"$BINARY" generate \
	--output "$CONFIG_DIRECTORY" \
	--protocols reality,hy2,anytls \
	--listen 127.0.0.1 \
	--public-address 2001:db8::10 \
	--public-reality-port 51165 \
	--public-hy2-port 25421 \
	--public-anytls-port 36279 \
	--reality-server-name www.example.com \
	--reality-handshake www.example.com:443 \
	--tls-san 2001:db8::10 \
	--allow-insecure-anytls-share >/dev/null

grep -Fq '"public_address": "2001:db8::10"' "$CONFIG_DIRECTORY/client-info.json"
grep -Fq '@[2001:db8::10]:51165' "$CONFIG_DIRECTORY/share-reality.txt"
grep -Fq '@[2001:db8::10]:25421' "$CONFIG_DIRECTORY/share-hysteria2.txt"
grep -Fq 'insecure=1' "$CONFIG_DIRECTORY/share-hysteria2.txt"
grep -Fq 'pinSHA256=' "$CONFIG_DIRECTORY/share-hysteria2.txt"
grep -Fq '@[2001:db8::10]:36279' "$CONFIG_DIRECTORY/share-anytls.txt"

FAKE_SYSTEMCTL="$WORK_DIRECTORY/systemctl"
FAKE_RC_SERVICE="$WORK_DIRECTORY/rc-service"
FAKE_SS="$WORK_DIRECTORY/ss"
FAKE_QRENCODE="$WORK_DIRECTORY/qrencode"

cat > "$FAKE_SYSTEMCTL" <<'EOF'
#!/bin/sh
case "$*" in
	'is-active --quiet mini-singbox.service') exit 0 ;;
	'stop mini-singbox.service'|'start mini-singbox.service') exit 0 ;;
	'show mini-singbox.service -p MainPID --value') printf '4242\n' ;;
	'show mini-singbox.service -p MemoryCurrent --value') printf '4194304\n' ;;
	'show mini-singbox.service -p TasksCurrent --value') printf '6\n' ;;
	'status mini-singbox.service --no-pager --lines 7') printf 'mock service log\n' ;;
	*) printf 'unexpected mock systemctl invocation: %s\n' "$*" >&2; exit 1 ;;
esac
EOF

cat > "$FAKE_RC_SERVICE" <<'EOF'
#!/bin/sh
[ "$1" = mini-singbox ] && [ "$2" = status ] || exit 1
printf 'mock OpenRC service active\n'
EOF

cat > "$FAKE_SS" <<'EOF'
#!/bin/sh
case "$*" in
	-lntH)
		printf 'LISTEN 0 4096 127.0.0.1:20001 0.0.0.0:*\n'
		printf 'LISTEN 0 4096 127.0.0.1:20003 0.0.0.0:*\n'
		;;
	-lnuH) printf 'UNCONN 0 0 127.0.0.1:20002 0.0.0.0:*\n' ;;
	*) printf 'unexpected mock ss invocation: %s\n' "$*" >&2; exit 1 ;;
esac
EOF

cat > "$FAKE_QRENCODE" <<'EOF'
#!/bin/sh
case "$*" in
	'-t ANSIUTF8')
		IFS= read -r payload
		[ -n "$payload" ] || exit 1
		printf '[mock QR rendered]\n'
		;;
	-l\ M\ -t\ PNG\ -o\ *)
		[ "$#" -eq 6 ] || exit 1
		IFS= read -r payload
		[ -n "$payload" ] || exit 1
		printf '[mock PNG for %s]\n' "$payload" > "$6"
		;;
	*) exit 1 ;;
esac
EOF

chmod 0755 "$FAKE_SYSTEMCTL" "$FAKE_RC_SERVICE" "$FAKE_SS" "$FAKE_QRENCODE"

run_control() {
	env \
		MINI_SINGBOX_BINARY="$BINARY" \
		MINI_SINGBOX_CONFIG_DIR="$CONFIG_DIRECTORY" \
		MINI_SINGBOX_TUNE_STATE_DIR="$WORK_DIRECTORY/tune" \
		MINI_SINGBOX_SERVICE_USER=mini-singbox-control-test-user \
		MINI_SINGBOX_SYSTEMCTL="$FAKE_SYSTEMCTL" \
		MINI_SINGBOX_SS="$FAKE_SS" \
		MINI_SINGBOX_QRENCODE="$FAKE_QRENCODE" \
		MINI_SINGBOX_INIT_SYSTEM=systemd \
		"$CONTROL_TOOL" "$@"
}

run_control_openrc() {
	env \
		MINI_SINGBOX_BINARY="$BINARY" \
		MINI_SINGBOX_CONFIG_DIR="$CONFIG_DIRECTORY" \
		MINI_SINGBOX_SERVICE_USER=mini-singbox-control-test-user \
		MINI_SINGBOX_RC_SERVICE="$FAKE_RC_SERVICE" \
		MINI_SINGBOX_OPENRC_LOG_PATH="$WORK_DIRECTORY/openrc-service.log" \
		MINI_SINGBOX_INIT_SYSTEM=openrc \
		"$CONTROL_TOOL" "$@"
}

run_control check >/dev/null
run_control version | grep -Fq 'mini-singbox '
run_control certificate | grep -Fq 'valid beyond 30 days'
run_control status > "$WORK_DIRECTORY/status.txt"
grep -Fq 'configuration: valid' "$WORK_DIRECTORY/status.txt"
grep -Fq 'service:      active (systemd)' "$WORK_DIRECTORY/status.txt"
grep -Fq 'memory 4.0 MiB, tasks 6' "$WORK_DIRECTORY/status.txt"
grep -Fq 'public address: 2001:db8::10' "$WORK_DIRECTORY/status.txt"
grep -Fq 'Reality:     tcp/20001, listening' "$WORK_DIRECTORY/status.txt"
grep -Fq 'Reality public: tcp/51165' "$WORK_DIRECTORY/status.txt"
grep -Fq 'Hysteria2:   udp/20002, listening' "$WORK_DIRECTORY/status.txt"
grep -Fq 'Hysteria2 public: udp/25421' "$WORK_DIRECTORY/status.txt"
grep -Fq 'AnyTLS:      tcp/20003, listening' "$WORK_DIRECTORY/status.txt"
grep -Fq 'AnyTLS public: tcp/36279' "$WORK_DIRECTORY/status.txt"
run_control logs 7 | grep -Fq 'mock service log'
printf 'line one\nline two\nline three\n' > "$WORK_DIRECTORY/openrc-service.log"
run_control_openrc logs 2 > "$WORK_DIRECTORY/openrc-logs.txt"
grep -Fxq 'line two' "$WORK_DIRECTORY/openrc-logs.txt"
grep -Fxq 'line three' "$WORK_DIRECTORY/openrc-logs.txt"
if grep -Fq 'line one' "$WORK_DIRECTORY/openrc-logs.txt"; then
	echo 'OpenRC logs ignored the requested line limit' >&2
	exit 1
fi
mv "$WORK_DIRECTORY/openrc-service.log" "$WORK_DIRECTORY/openrc-service.log.real"
ln -s "$WORK_DIRECTORY/openrc-service.log.real" "$WORK_DIRECTORY/openrc-service.log"
if run_control_openrc logs 2 >/dev/null 2>&1; then
	echo 'OpenRC logs followed an unsafe symbolic link' >&2
	exit 1
fi
rm "$WORK_DIRECTORY/openrc-service.log"
mv "$WORK_DIRECTORY/openrc-service.log.real" "$WORK_DIRECTORY/openrc-service.log"
run_control tune plan | grep -Fq 'Plan'
run_control tune apply --dry-run | grep -Fq 'Result: dry run; no system state changed'
run_control qr all > "$WORK_DIRECTORY/qr-all.txt"
[ "$(grep -Fc '[mock QR rendered]' "$WORK_DIRECTORY/qr-all.txt")" -eq 3 ]
[ "$(grep -Fc 'link (sensitive): ' "$WORK_DIRECTORY/qr-all.txt")" -eq 3 ]
grep -Fq "link (sensitive): $(cat "$CONFIG_DIRECTORY/share-reality.txt")" "$WORK_DIRECTORY/qr-all.txt"
grep -Fq "link (sensitive): $(cat "$CONFIG_DIRECTORY/share-hysteria2.txt")" "$WORK_DIRECTORY/qr-all.txt"
grep -Fq "link (sensitive): $(cat "$CONFIG_DIRECTORY/share-anytls-v2rayn.txt")" "$WORK_DIRECTORY/qr-all.txt"
grep -Fq 'anytls (v2rayN only)' "$WORK_DIRECTORY/qr-all.txt"
grep -Fq "Mihomo export:  $CONFIG_DIRECTORY/client-anytls-mihomo.yaml" "$WORK_DIRECTORY/qr-all.txt"

cp "$CONFIG_DIRECTORY/share-anytls-v2rayn.txt" "$CONFIG_DIRECTORY/share-anytls-v2rayn.txt.valid"
printf 'v2rayn://anytls/example\nsecond-line\n' > "$CONFIG_DIRECTORY/share-anytls-v2rayn.txt"
if run_control qr anytls >/dev/null 2>&1; then
	echo 'qr accepted a multi-line share link' >&2
	exit 1
fi
printf 'anytls://example.invalid\n' > "$CONFIG_DIRECTORY/share-anytls-v2rayn.txt"
if run_control qr anytls >/dev/null 2>&1; then
	echo 'qr accepted a share link with the wrong protocol scheme' >&2
	exit 1
fi
mv "$CONFIG_DIRECTORY/share-anytls-v2rayn.txt.valid" "$CONFIG_DIRECTORY/share-anytls-v2rayn.txt"

mv "$CONFIG_DIRECTORY/share-anytls-v2rayn.txt" "$CONFIG_DIRECTORY/share-anytls-v2rayn.txt.missing"
if run_control qr all >/dev/null 2>&1; then
	echo 'qr all ignored a missing enabled-protocol share link' >&2
	exit 1
fi
mv "$CONFIG_DIRECTORY/share-anytls-v2rayn.txt.missing" "$CONFIG_DIRECTORY/share-anytls-v2rayn.txt"

run_control qr anytls > "$WORK_DIRECTORY/qr-anytls-secure.txt"
grep -Fq 'anytls (v2rayN only)' "$WORK_DIRECTORY/qr-anytls-secure.txt"
[ "$(grep -Fc '[mock QR rendered]' "$WORK_DIRECTORY/qr-anytls-secure.txt")" -eq 1 ]
run_control export anytls sing-box > "$WORK_DIRECTORY/export-sing-box.json"
cmp "$CONFIG_DIRECTORY/client-anytls-sing-box-outbound.json" "$WORK_DIRECTORY/export-sing-box.json"
run_control export anytls mihomo > "$WORK_DIRECTORY/export-mihomo.yaml"
cmp "$CONFIG_DIRECTORY/client-anytls-mihomo.yaml" "$WORK_DIRECTORY/export-mihomo.yaml"
run_control export anytls v2rayn > "$WORK_DIRECTORY/export-v2rayn.txt"
cmp "$CONFIG_DIRECTORY/share-anytls-v2rayn.txt" "$WORK_DIRECTORY/export-v2rayn.txt"
mv "$CONFIG_DIRECTORY/client-anytls-mihomo.yaml" "$CONFIG_DIRECTORY/client-anytls-mihomo.yaml.real"
ln -s "$CONFIG_DIRECTORY/client-anytls-mihomo.yaml.real" "$CONFIG_DIRECTORY/client-anytls-mihomo.yaml"
if run_control export anytls mihomo >/dev/null 2>&1; then
	echo 'export followed a symbolic link' >&2
	exit 1
fi
rm "$CONFIG_DIRECTORY/client-anytls-mihomo.yaml"
mv "$CONFIG_DIRECTORY/client-anytls-mihomo.yaml.real" "$CONFIG_DIRECTORY/client-anytls-mihomo.yaml"
if run_control export anytls invalid >/dev/null 2>&1; then
	echo 'export accepted an invalid AnyTLS format' >&2
	exit 1
fi

if run_control logs 0 >/dev/null 2>&1; then
	echo 'logs accepted an invalid line count' >&2
	exit 1
fi
if run_control qr invalid >/dev/null 2>&1; then
	echo 'qr accepted an invalid protocol' >&2
	exit 1
fi

cp "$CONFIG_DIRECTORY/client-info.json" "$WORK_DIRECTORY/client-info.before-renew.json"
cp "$CONFIG_DIRECTORY/tls.crt" "$WORK_DIRECTORY/tls.before-renew.crt"
jq -S '{reality:.vless_reality.uuid,hy2:.hysteria2.password,anytls:.anytls.password}' \
	"$CONFIG_DIRECTORY/client-info.json" > "$WORK_DIRECTORY/credentials.before.json"
chmod 0711 "$WORK_DIRECTORY"
sudo chown -R nobody:nogroup "$CONFIG_DIRECTORY"
renew_output="$(sudo env \
	MINI_SINGBOX_BINARY="$BINARY" \
	MINI_SINGBOX_CONFIG_DIR="$CONFIG_DIRECTORY" \
	MINI_SINGBOX_SERVICE_USER=nobody \
	MINI_SINGBOX_SERVICE_GROUP=nogroup \
	MINI_SINGBOX_SYSTEMCTL="$FAKE_SYSTEMCTL" \
	MINI_SINGBOX_QRENCODE="$FAKE_QRENCODE" \
	MINI_SINGBOX_INIT_SYSTEM=systemd \
	"$CONTROL_TOOL" certificate renew)"
printf '%s\n' "$renew_output" > "$WORK_DIRECTORY/renew.txt"
grep -Fq 'protocol credentials and Reality keys were preserved' "$WORK_DIRECTORY/renew.txt"
sudo jq -S '{reality:.vless_reality.uuid,hy2:.hysteria2.password,anytls:.anytls.password}' \
	"$CONFIG_DIRECTORY/client-info.json" | \
	cmp "$WORK_DIRECTORY/credentials.before.json" -
if sudo cmp -s "$WORK_DIRECTORY/tls.before-renew.crt" "$CONFIG_DIRECTORY/tls.crt"; then
	echo 'certificate renewal did not replace the TLS certificate' >&2
	exit 1
fi
sudo jq -e '(.tls.certificate | type) == "array" and (.tls.certificate | length) == 1 and (.tls.certificate[0] | startswith("-----BEGIN CERTIFICATE-----"))' \
	"$CONFIG_DIRECTORY/client-anytls-sing-box-outbound.json" >/dev/null
sudo grep -Fq 'type: anytls' "$CONFIG_DIRECTORY/client-anytls-mihomo.yaml"
sudo grep -Fq 'skip-cert-verify: true' "$CONFIG_DIRECTORY/client-anytls-mihomo.yaml"
sudo grep -Eq '^v2rayn://anytls/[A-Za-z0-9_-]+$' "$CONFIG_DIRECTORY/share-anytls-v2rayn.txt"
sudo test -s "$CONFIG_DIRECTORY/share-anytls-v2rayn.png"
sudo chown -R "$(id -u):$(id -g)" "$CONFIG_DIRECTORY"

FAILING_SYSTEMCTL="$WORK_DIRECTORY/failing-systemctl"
cat > "$FAILING_SYSTEMCTL" <<'EOF'
#!/bin/sh
set -eu
case "$*" in
	'is-active --quiet mini-singbox.service'|'stop mini-singbox.service') exit 0 ;;
	'start mini-singbox.service')
		if [ ! -e "$MINI_SINGBOX_FAIL_START_STATE" ]; then
			: > "$MINI_SINGBOX_FAIL_START_STATE"
			exit 1
		fi
		exit 0
		;;
	*) exit 1 ;;
esac
EOF
chmod 0755 "$FAILING_SYSTEMCTL"
cp "$CONFIG_DIRECTORY/tls.crt" "$WORK_DIRECTORY/tls.before-failed-renew.crt"
sudo chown -R nobody:nogroup "$CONFIG_DIRECTORY"
if sudo env \
	MINI_SINGBOX_BINARY="$BINARY" \
	MINI_SINGBOX_CONFIG_DIR="$CONFIG_DIRECTORY" \
	MINI_SINGBOX_SERVICE_USER=nobody \
	MINI_SINGBOX_SERVICE_GROUP=nogroup \
	MINI_SINGBOX_SYSTEMCTL="$FAILING_SYSTEMCTL" \
	MINI_SINGBOX_FAIL_START_STATE="$WORK_DIRECTORY/fail-start.state" \
	MINI_SINGBOX_QRENCODE="$FAKE_QRENCODE" \
	MINI_SINGBOX_INIT_SYSTEM=systemd \
	"$CONTROL_TOOL" certificate renew >/dev/null 2>"$WORK_DIRECTORY/failed-renew.stderr"; then
	echo 'certificate renewal unexpectedly succeeded when service restart failed' >&2
	exit 1
fi
grep -Fq 'restoring the previous configuration' "$WORK_DIRECTORY/failed-renew.stderr"
sudo cmp "$WORK_DIRECTORY/tls.before-failed-renew.crt" "$CONFIG_DIRECTORY/tls.crt"
sudo chown -R "$(id -u):$(id -g)" "$CONFIG_DIRECTORY"

echo 'control tool, certificate renewal rollback, offline tune plan, and IPv6 delivery checks passed'
