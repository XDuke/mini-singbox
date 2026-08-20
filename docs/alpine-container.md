# Alpine Linux and container runtimes

mini-singbox supports three host lifecycle backends and one OCI lifecycle
helper. They deliberately have different ownership boundaries.

| Mode | Intended environment | Lifecycle owner | Host TCP tuning |
|---|---|---|---|
| `systemd` | Debian/Ubuntu host or systemd VM | systemd | supported |
| `openrc` | Native Alpine Linux host | OpenRC `supervise-daemon` | supported |
| `openrc-container` profile | Alpine container with OpenRC as PID 1 | OpenRC `supervise-daemon` | blocked |
| `external` | provider container with an existing supervisor | provider supervisor | blocked |
| OCI | rootless Podman or Docker | container engine/helper | blocked |

`MINI_SINGBOX_RUNTIME=auto` is the default. A running systemd host is selected
first. OpenRC is selected only when its commands and runtime directory exist,
PID 1 is `init`/`openrc-init`, and `rc-status` succeeds. A container with merely
installed OpenRC tools therefore remains external, while a full Alpine/OpenRC
container receives the `openrc-container` profile and a real OpenRC service.
Other provider containers remain external.

Existing installations normally refuse implicit cross-runtime upgrades. The
single automatic exception repairs older detection: an inactive external
deployment may migrate transactionally to `openrc-container` when the active
PID 1 service manager is provably OpenRC. An active external process still has
to be stopped first. On success the obsolete external runner is removed; on
failure the old binary, configuration, deployment record and runner are
restored.

## Native Alpine host

Alpine Linux 3.23 and 3.24 use the same public one-line installer as the other
supported hosts:

```sh
sh -c 'set -o pipefail; wget -qO- https://raw.githubusercontent.com/XDuke/mini-singbox/main/bootstrap.sh | sh'
```

BusyBox `wget` is used only for the first bootstrap hop. The bootstrap then
installs missing `apk` packages including `curl` and CA certificates, verifies the signed Release
bundle, and downloads the matching static amd64 or arm64 binary. It does not
compile on the target. The OpenRC unit:

- validates the configuration before every start;
- launches the process as `mini-singbox:mini-singbox`;
- uses a root-owned PID file and OpenRC `supervise-daemon`;
- sets `no_new_privs`, a restrictive umask, bounded respawn, and TERM/KILL stop
  timing;
- logs stdout and stderr through `logger`;
- enables the service in the default runlevel only after configuration checks.

Useful commands:

```sh
sudo rc-service mini-singbox status
sudo rc-service mini-singbox restart
sudo rc-service mini-singbox stop
sudo rc-service mini-singbox start
sudo rc-update show default | grep mini-singbox
sudo mini-singboxctl status
sudo mini-singboxctl logs 100
```

OpenRC does not provide the systemd `MemoryMax` or `TasksMax` cgroup controls.
`GOMEMLIMIT=48MiB`, `GOMAXPROCS=1`, and `GOGC=70` remain active, but they are
runtime settings rather than a hard container memory ceiling. Set host/container
limits in the provider control plane when a hard 128 MiB limit is required.
In an `openrc-container` profile, deployment-time tuning and
`mini-singboxctl tune apply` are blocked because the surrounding container
engine owns the kernel and `/proc/sys` may be read-only.

## Provider container with an external supervisor

When PID 1 and service restart policy belong to a provider, mini-singbox does
not install a fake inner init service. Deployment installs and validates:

```text
/usr/local/bin/mini-singbox
/usr/local/bin/mini-singbox-run
/etc/mini-singbox/config.json
```

Configure the provider supervisor to run `/usr/local/bin/mini-singbox-run`.
Prefer user `mini-singbox`. If the platform can start commands only as root,
the runner immediately drops to the service account with `runuser`. The runner
tracks the child PID, forwards termination, removes a stale PID file, and
refuses a duplicate process.

The deployment intentionally does not auto-start external mode. Stop the outer
supervisor before an update or `mini-singboxctl certificate renew`, then restart
it after the command succeeds. `mini-singboxctl logs` is unavailable because the
outer platform owns logs.

Both deployment-time automatic TCP tuning and `mini-singboxctl tune apply` are
disabled in every detected container profile, including external,
`openrc-container`, and container-compatible systemd. Containers share the host
kernel, so an inner process must not claim ownership of host sysctls.

## Rootless Podman or Docker

The formal image is `ghcr.io/xduke/mini-singbox`. Always select the exact digest
from the matching Release `oci-digests.txt`:

```sh
export MINI_SINGBOX_IMAGE='ghcr.io/xduke/mini-singbox@sha256:REPLACE_ME'
```

The image is scratch-based, multi-architecture, and runs without a shell as UID
and GID 65532. `mini-singbox-containerctl` prefers Podman, supports Docker, and
uses the calling user through Podman `keep-id` or Docker's explicit numeric user.
It verifies that the selected engine is actually rootless; membership in a
rootful Docker daemon's `docker` group is intentionally rejected.
It never mounts a container-engine socket into the service.

Required initialization values:

```sh
export MINI_SINGBOX_PUBLIC_ADDRESS='proxy.example.com'
export MINI_SINGBOX_REALITY_SERVER_NAME='www.example.com'
export MINI_SINGBOX_REALITY_HANDSHAKE='www.example.com:443'
export MINI_SINGBOX_TLS_SAN='proxy.example.com'
mini-singbox-containerctl init
mini-singbox-containerctl up
```

The runtime uses a read-only root filesystem, drops all capabilities, enables
`no-new-privileges`, limits the container to 64 PIDs and 128 MiB, and mounts the
private configuration read-only. `init`, `check`, certificate generation and
renewal run with networking disabled. Enabled protocol ports are read from the
validated configuration and published with the correct TCP/UDP transport.

Lifecycle commands:

```sh
mini-singbox-containerctl status
mini-singbox-containerctl logs 100
mini-singbox-containerctl check
mini-singbox-containerctl qr all
mini-singbox-containerctl certificate renew
mini-singbox-containerctl upgrade IMAGE_AT_NEW_DIGEST
mini-singbox-containerctl rollback
mini-singbox-containerctl down
mini-singbox-containerctl uninstall
```

An upgrade pulls and checks the new image before stopping the current container,
then observes the replacement. Failed startup restores the previous image ID.
Certificate renewal stops the container, copies the complete configuration,
generates new TLS material without network access, checks the result, and
restores the old directory on failure. Credentials and Reality keys are not
rotated. Hysteria2 and AnyTLS clients must be re-imported after a successful
renewal because their certificate pins change.

`uninstall` keeps configuration by default. `PURGE=1
mini-singbox-containerctl uninstall` permanently removes the helper state and
credentials; the helper cannot recover them.

## Acceptance gates

CI builds the exact candidate static binary and then tests it in:

- Alpine 3.23 and 3.24 external-supervisor containers;
- a privileged Alpine 3.24 fixture booted with OpenRC, including automatic
  container-profile detection and inactive external-to-OpenRC migration;
- rootless Podman with the read-only/capability/PID/memory policies;
- Docker scratch-container generation, configuration check, idle startup and
  clean SIGTERM.

These gates establish installation and short-run lifecycle behavior. They do
not replace the user's real provider networking, NAT mapping, firewall, clean
client network, throughput, or long-duration protocol validation.
