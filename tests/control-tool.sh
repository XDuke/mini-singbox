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
	--tls-san 2001:db8::10 >/dev/null

grep -Fq '"public_address": "2001:db8::10"' "$CONFIG_DIRECTORY/client-info.json"
grep -Fq '@[2001:db8::10]:51165' "$CONFIG_DIRECTORY/share-reality.txt"
grep -Fq '@[2001:db8::10]:25421' "$CONFIG_DIRECTORY/share-hysteria2.txt"
grep -Fq 'insecure=1' "$CONFIG_DIRECTORY/share-hysteria2.txt"
grep -Fq 'pinSHA256=' "$CONFIG_DIRECTORY/share-hysteria2.txt"
grep -Fq '@[2001:db8::10]:36279' "$CONFIG_DIRECTORY/share-anytls.txt"

FAKE_SYSTEMCTL="$WORK_DIRECTORY/systemctl"
FAKE_SS="$WORK_DIRECTORY/ss"
FAKE_QRENCODE="$WORK_DIRECTORY/qrencode"

cat > "$FAKE_SYSTEMCTL" <<'EOF'
#!/bin/sh
case "$*" in
	'is-active --quiet mini-singbox.service') exit 0 ;;
	'show mini-singbox.service -p MainPID --value') printf '4242\n' ;;
	'show mini-singbox.service -p MemoryCurrent --value') printf '4194304\n' ;;
	'show mini-singbox.service -p TasksCurrent --value') printf '6\n' ;;
	'status mini-singbox.service --no-pager --lines 7') printf 'mock service log\n' ;;
	*) printf 'unexpected mock systemctl invocation: %s\n' "$*" >&2; exit 1 ;;
esac
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
[ "$*" = '-t ANSIUTF8' ] || exit 1
IFS= read -r payload
[ -n "$payload" ] || exit 1
printf '[mock QR rendered]\n'
EOF

chmod 0755 "$FAKE_SYSTEMCTL" "$FAKE_SS" "$FAKE_QRENCODE"

run_control() {
	env \
		MINI_SINGBOX_BINARY="$BINARY" \
		MINI_SINGBOX_CONFIG_DIR="$CONFIG_DIRECTORY" \
		MINI_SINGBOX_SERVICE_USER=mini-singbox-control-test-user \
		MINI_SINGBOX_SYSTEMCTL="$FAKE_SYSTEMCTL" \
		MINI_SINGBOX_SS="$FAKE_SS" \
		MINI_SINGBOX_QRENCODE="$FAKE_QRENCODE" \
		MINI_SINGBOX_INIT_SYSTEM=systemd \
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
run_control qr all > "$WORK_DIRECTORY/qr-all.txt"
[ "$(grep -Fc '[mock QR rendered]' "$WORK_DIRECTORY/qr-all.txt")" -eq 3 ]
[ "$(grep -Fc 'link (sensitive): ' "$WORK_DIRECTORY/qr-all.txt")" -eq 3 ]
grep -Fq "link (sensitive): $(cat "$CONFIG_DIRECTORY/share-reality.txt")" "$WORK_DIRECTORY/qr-all.txt"
grep -Fq "link (sensitive): $(cat "$CONFIG_DIRECTORY/share-hysteria2.txt")" "$WORK_DIRECTORY/qr-all.txt"
grep -Fq "link (sensitive): $(cat "$CONFIG_DIRECTORY/share-anytls.txt")" "$WORK_DIRECTORY/qr-all.txt"

cp "$CONFIG_DIRECTORY/share-anytls.txt" "$CONFIG_DIRECTORY/share-anytls.txt.valid"
printf 'anytls://example.invalid\nsecond-line\n' > "$CONFIG_DIRECTORY/share-anytls.txt"
if run_control qr anytls >/dev/null 2>&1; then
	echo 'qr accepted a multi-line share link' >&2
	exit 1
fi
printf 'vless://example.invalid\n' > "$CONFIG_DIRECTORY/share-anytls.txt"
if run_control qr anytls >/dev/null 2>&1; then
	echo 'qr accepted a share link with the wrong protocol scheme' >&2
	exit 1
fi
mv "$CONFIG_DIRECTORY/share-anytls.txt.valid" "$CONFIG_DIRECTORY/share-anytls.txt"

mv "$CONFIG_DIRECTORY/share-anytls.txt" "$CONFIG_DIRECTORY/share-anytls.txt.missing"
if run_control qr all >/dev/null 2>&1; then
	echo 'qr all ignored a missing enabled-protocol share link' >&2
	exit 1
fi
mv "$CONFIG_DIRECTORY/share-anytls.txt.missing" "$CONFIG_DIRECTORY/share-anytls.txt"

if run_control logs 0 >/dev/null 2>&1; then
	echo 'logs accepted an invalid line count' >&2
	exit 1
fi
if run_control qr invalid >/dev/null 2>&1; then
	echo 'qr accepted an invalid protocol' >&2
	exit 1
fi

echo 'control tool and IPv6 delivery checks passed'
