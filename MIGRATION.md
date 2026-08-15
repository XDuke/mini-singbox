# Migration guide

`mini-singbox v1.0.0` is the first supported release and uses these identities:

```text
binary:       /usr/local/bin/mini-singbox
control:      /usr/local/bin/mini-singboxctl
service:      mini-singbox.service
service user: mini-singbox
configuration:/etc/mini-singbox
backups:      /var/backups/mini-singbox
```

`v1.1.0` additionally installs
`/usr/local/bin/mini-singbox-update` and `/usr/local/bin/mini-singbox-uninstall`.

`v1.1.0` also runs conservative, offline TCP tuning after a successful
deployment. It snapshots original values and owns only its dedicated
`/etc/sysctl.d/90-mini-singbox-tune.conf`; root-only baselines and history live
under `/var/lib/mini-singbox/tune`. Set `MINI_SINGBOX_AUTO_TUNE=0` before the
bootstrap command to opt out. Use `sudo mini-singboxctl tune status` to inspect
the plan and `sudo mini-singboxctl tune rollback` to restore the exact pre-tune
values. Hysteria2-only deployments do not change TCP settings.

Do not copy panel, multi-user, subscription, traffic-accounting, arbitrary
sing-box, TUN, route, outbound, DNS, endpoint, or service configuration into
this project. The strict schema intentionally rejects them.

For a clean installation, deploy `v1.1.0` and import the newly generated
per-protocol QR codes. For an early pre-v1 candidate, keep a private backup,
stop its service, and copy only the candidate's local `config.json`, Reality
private key, TLS key, and TLS certificate into `/etc/mini-singbox` with the new
service-user ownership. Run `mini-singbox check` before starting the new unit.

To intentionally rotate every credential after migration:

```sh
MINI_SINGBOX_REGENERATE=1 bash -c 'set -o pipefail; curl -fsSL --proto =https --tlsv1.2 https://raw.githubusercontent.com/XDuke/mini-singbox/main/bootstrap.sh | bash'
```

Existing clients stop working after regeneration. Ordinary upgrades preserve
credentials and create a rollback backup automatically.
