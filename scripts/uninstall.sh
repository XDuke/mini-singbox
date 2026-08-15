#!/bin/sh
set -eu

[ "$(id -u)" -eq 0 ] || {
	echo "mini-singbox uninstaller: run as root" >&2
	exit 1
}

if [ -f /var/lib/mini-singbox/tune/active.json ]; then
	[ -x /usr/local/bin/mini-singbox ] || {
		echo "mini-singbox uninstaller: cannot rollback managed TCP tuning because the binary is missing" >&2
		exit 1
	}
	/usr/local/bin/mini-singbox tune rollback \
		-c /etc/mini-singbox/config.json --state-dir /var/lib/mini-singbox/tune || {
		echo "mini-singbox uninstaller: TCP tuning rollback failed; installation was kept" >&2
		exit 1
	}
fi

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
	systemctl disable --now mini-singbox.service 2>/dev/null || true
	rm -f /etc/systemd/system/mini-singbox.service
	systemctl daemon-reload
fi
if command -v rc-service >/dev/null 2>&1; then
	rc-service mini-singbox stop 2>/dev/null || true
	rc-update del mini-singbox default 2>/dev/null || true
	rm -f /etc/init.d/mini-singbox
fi

rm -f /usr/local/bin/mini-singbox \
	/usr/local/bin/mini-singboxctl /usr/local/bin/mini-singbox-update \
	/usr/local/bin/mini-singbox-uninstall

if [ "${PURGE:-0}" = "1" ]; then
	rm -rf /etc/mini-singbox
	rm -rf /var/lib/mini-singbox
	echo "removed /etc/mini-singbox and /var/lib/mini-singbox; this cannot be recovered by the uninstaller"
else
	echo "kept /etc/mini-singbox and /var/lib/mini-singbox; set PURGE=1 to remove configuration, keys, and tune history"
fi

echo "mini-singbox uninstalled"
