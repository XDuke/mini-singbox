# Security policy

## Supported versions

| Version | Supported |
|---|---|
| Latest stable GitHub Release | Yes |
| Superseded stable releases | No |
| Candidates and branch builds | No |

Only immutable GitHub Releases with a minisign-verified checksum manifest are
supported. Commit-specific candidate binaries are testing artifacts.

## Reporting a vulnerability

Open a private GitHub security advisory for `XDuke/mini-singbox`. Do not put
private keys, passwords, live addresses, sharing links, QR images, or client
files in a public issue. Include the affected version/commit, platform,
reproduction steps, and the smallest non-secret configuration possible.

## Security boundaries

The service has no management API, remote configuration, telemetry, dynamic
users, traffic accounting, subscription server, or background update checker.
The signed `mini-singbox-update` tool makes network requests only when a user
explicitly runs it. `version`, `check`, `generate`, and idle service operation do
not make project-initiated
outbound connections. Authenticated proxy traffic and Reality handshakes are
normal data-plane traffic and are outside that idle guarantee.

VM deployment uses the network only to download an exact official release,
detect a requested public address, and select a Reality target when automatic
detection is enabled. Those operations occur before the daemon starts.

The post-deployment TCP tuner is offline. It does not measure against a public
peer, download a kernel/module, or change firewall, DNS, routes, RPS, buffers,
or traffic shaping. It writes only high-confidence sysctls that the running
kernel and current namespace expose. Original values are captured before the
first write, applied values are read back, and the dedicated sysctl file is
protected by an ownership hash. Rollback refuses to overwrite later external
changes. Set `MINI_SINGBOX_AUTO_TUNE=0` to disable deployment-time tuning.

`client-info.json`, private keys, sharing links, and QR images are credentials.
`mini-singboxctl qr` is an explicit local disclosure command and warns before
rendering them. Do not capture its output in public logs.

`GOMEMLIMIT` constrains Go-managed memory. It is not a container hard limit and
does not include all kernel socket memory; keep the cgroup/systemd memory limit.
