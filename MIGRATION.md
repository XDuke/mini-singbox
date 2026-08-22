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

`v1.1.1` keeps the official sing-box `v1.13.18` kernel and focuses on safer
delivery and recovery. Ordinary upgrades preserve UUIDs, protocol passwords,
the Reality private key, and the current TLS certificate. Existing AnyTLS
installations automatically replace an old unauthenticated URI/QR with
`/etc/mini-singbox/client-anytls-sing-box-outbound.json`, which embeds the
server certificate and keeps certificate verification enabled. Re-import that
AnyTLS outbound after upgrading; Reality and Hysteria2 clients do not need to
be re-imported during an ordinary upgrade.

In v1.1.1 the supported host service manager is systemd; the incomplete old
OpenRC path was deliberately not a release asset. Configuration, key,
certificate, and delivery paths must not be symbolic links.

`v1.2.0` adds a newly implemented and CI-tested OpenRC backend for Alpine Linux,
an external-supervisor backend for provider containers, and a separate rootless
Podman/Docker lifecycle helper. This is not a restoration of the old incomplete
installer: all three paths share the current signed assets, strict config,
transactional credentials, control commands, architecture checks, and release
identity.

The `v1.2.0` upgrade path also reduces transient memory pressure on small
containers. After verification, it stages the candidate on the installation
filesystem, renames the previous binary into the rollback directory, and
switches the staged binary without keeping multiple copied executables in page
cache. The configuration and credential-preserving rollback contract is
unchanged.

`v1.2.0` also replaces the single AnyTLS delivery with three authenticated
client choices. Re-running the installer rebuilds delivery files without
rotating the server password or certificate:

```text
/etc/mini-singbox/client-anytls-sing-box-outbound.json
/etc/mini-singbox/client-anytls-mihomo.yaml
/etc/mini-singbox/share-anytls-v2rayn.txt
/etc/mini-singbox/share-anytls-v2rayn.png
```

Use `sudo mini-singboxctl qr anytls` for v2rayN, or
`sudo mini-singboxctl export anytls sing-box|mihomo|v2rayn` for an explicit
format. The v2rayN QR is not compatible with Clash/Mihomo; original Clash does
not support AnyTLS. Delete any previously copied unauthenticated standard
`anytls://` profile after importing one of the authenticated replacements.

The selected host runtime is written as `runtime=systemd`, `runtime=openrc`, or
`runtime=external` in `deployment-info.txt`. Ordinary upgrades refuse to change
that value implicitly. To move between init systems, stop and disable the old
service, preserve `/etc/mini-singbox` and `/var/lib/mini-singbox`, remove the old
unit, then perform an explicitly reviewed clean deployment in the new host.
Never run two runtime backends against the same configuration and ports.

The OCI helper keeps its configuration under
`${XDG_STATE_HOME:-$HOME/.local/state}/mini-singbox-container` and does not
automatically import `/etc/mini-singbox`. Migrating a host installation into OCI
therefore requires an offline backup and ownership review; do not copy active
tuning state because container/external modes cannot own host sysctls.

Use `sudo mini-singboxctl certificate renew` to renew only the TLS certificate.
The command preserves protocol credentials, rebuilds delivery pins, validates
the service, and rolls the complete configuration back on failure. A successful
renewal changes the certificate pin, so both Hysteria2 and AnyTLS clients must
then import the new delivery files.

Do not copy panel, multi-user, subscription, traffic-accounting, arbitrary
sing-box, TUN, route, outbound, DNS, endpoint, or service configuration into
this project. The strict schema intentionally rejects them.

For a clean installation after the formal `v1.2.0` release, import the Reality
and Hysteria2 QR codes, then select the AnyTLS export matching the client.
For an early pre-v1 candidate, keep a private backup, stop its service, and copy
only the candidate's local `config.json`, Reality private key, TLS key, and TLS
certificate into `/etc/mini-singbox` with the new service-user ownership. Run
`mini-singbox check` before starting the new unit.

To intentionally rotate every credential after migration:

```sh
MINI_SINGBOX_REGENERATE=1 bash -c 'set -o pipefail; curl -fsSL --proto =https --tlsv1.2 https://raw.githubusercontent.com/XDuke/mini-singbox/main/bootstrap.sh | bash'
```

Existing clients stop working after regeneration. Ordinary upgrades preserve
credentials and create a rollback backup automatically.

Uninstall keeps historical deployment backups by default. To permanently
remove both current credentials and matching managed backup directories, use
`sudo env PURGE=1 PURGE_BACKUPS=1 mini-singbox-uninstall` only after preserving
anything still needed for rollback. This deletion cannot be undone.
