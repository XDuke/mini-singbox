#!/bin/sh
set -eu

[ "$(id -u)" -eq 0 ] || {
	echo "mini-singbox uninstaller: run as root" >&2
	exit 1
}

PURGE="${PURGE:-0}"
PURGE_BACKUPS="${PURGE_BACKUPS:-0}"
case "$PURGE" in
	0|1) ;;
	*)
		echo "mini-singbox uninstaller: PURGE must be 0 or 1" >&2
		exit 1
		;;
esac
case "$PURGE_BACKUPS" in
	0|1) ;;
	*)
		echo "mini-singbox uninstaller: PURGE_BACKUPS must be 0 or 1" >&2
		exit 1
		;;
esac

echo "mini-singbox uninstaller: program and service files will be removed"
if [ "$PURGE" = "1" ]; then
	echo "mini-singbox uninstaller: PURGE=1 will remove configuration, tune state, and service logs"
	OPENRC_LOG_DIR=/var/log/mini-singbox
	[ "$OPENRC_LOG_DIR" = "/var/log/mini-singbox" ] || {
		echo "mini-singbox uninstaller: refusing unsafe log path" >&2
		exit 1
	}
	if [ -L "$OPENRC_LOG_DIR" ]; then
		echo "mini-singbox uninstaller: refusing symbolic-link log path: $OPENRC_LOG_DIR" >&2
		exit 1
	fi
fi

RUNTIME=""
if [ -f /etc/mini-singbox/deployment-info.txt ] && [ ! -L /etc/mini-singbox/deployment-info.txt ]; then
	RUNTIME="$(awk -F= '$1 == "runtime" { print $2 }' /etc/mini-singbox/deployment-info.txt)"
	if [ -z "$RUNTIME" ] && grep -q '^systemd_profile=' /etc/mini-singbox/deployment-info.txt; then
		RUNTIME=systemd
	fi
fi
if [ "$PURGE_BACKUPS" = "1" ]; then
	echo "mini-singbox uninstaller: PURGE_BACKUPS=1 will remove /var/backups/mini-singbox"
fi

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

if [ "$RUNTIME" = external ] && [ -f /run/mini-singbox/mini-singbox.pid ] && \
	[ ! -L /run/mini-singbox/mini-singbox.pid ]; then
	pid="$(cat /run/mini-singbox/mini-singbox.pid 2>/dev/null || true)"
	case "$pid" in
		''|*[!0-9]*|0) ;;
		*)
			if kill -0 "$pid" 2>/dev/null; then
				kill -TERM "$pid" 2>/dev/null || true
				attempt=0
				while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 10 ]; do
					sleep 1
					attempt=$((attempt + 1))
				done
				kill -0 "$pid" 2>/dev/null && {
					echo "mini-singbox uninstaller: external supervisor restarted or did not stop the process; installation was kept" >&2
					exit 1
				}
			fi
			;;
	esac
fi

rm -f /usr/local/bin/mini-singbox \
	/usr/local/bin/mini-singboxctl /usr/local/bin/mini-singbox-update \
	/usr/local/bin/mini-singbox-uninstall /usr/local/bin/mini-singbox-run \
	/usr/local/bin/mini-singbox-containerctl
if [ -d /run/mini-singbox ] && [ ! -L /run/mini-singbox ]; then
	rm -rf /run/mini-singbox
fi

if [ "$PURGE" = "1" ]; then
	rm -rf /etc/mini-singbox
	rm -rf /var/lib/mini-singbox
	rm -rf "$OPENRC_LOG_DIR"
	echo "removed /etc/mini-singbox, /var/lib/mini-singbox, and /var/log/mini-singbox; this cannot be recovered by the uninstaller"
else
	echo "kept configuration, tune history, and service logs; set PURGE=1 to remove them"
fi

if [ "$PURGE_BACKUPS" = "1" ]; then
	BACKUP_ROOT=/var/backups/mini-singbox
	[ "$BACKUP_ROOT" = "/var/backups/mini-singbox" ] || {
		echo "mini-singbox uninstaller: refusing unsafe backup path" >&2
		exit 1
	}
	rm -rf "$BACKUP_ROOT"
	echo "removed /var/backups/mini-singbox; historical credentials and rollback copies cannot be recovered by the uninstaller"
elif [ -d /var/backups/mini-singbox ]; then
	echo "kept /var/backups/mini-singbox; backups may contain old credentials; set PURGE_BACKUPS=1 to remove them"
fi

echo "mini-singbox uninstalled"
