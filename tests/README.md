# Linux acceptance harnesses

These scripts collect evidence; their presence is not evidence that a release
gate passed. Run them on a dedicated Linux host and retain the complete output
directory with the commit and image digest.

## Fast local control and IPv6 delivery check

After building a Linux binary, run:

```sh
tests/control-tool.sh scripts/mini-singboxctl ./mini-singbox-linux-amd64
```

This offline check generates a three-protocol IPv6 client configuration and
verifies bracketed IPv6 share URIs plus the on-demand `check`, `version`,
`certificate`, `status`, `logs`, offline tuning plan/dry-run, and QR paths with
mocked init and socket state.

## No active egress

Build the static binary, install `iproute2`, `tcpdump`, and `strace`, then run:

```sh
sudo tests/no-egress.sh ./mini-singbox evidence/no-egress 600
```

The isolated-namespace run also traces `tune plan` for every protocol set and
fails if detection or planning attempts a network operation.

The script creates a network namespace with only loopback, captures all
packets, traces network syscalls, and runs `version`, `generate`, `check`, and
idle Reality, Hysteria2, AnyTLS, and combined configurations. Each idle service
runs for at least 600 seconds. Any packet, established socket, outbound
`connect`, `sendto`, or `sendmsg`, early exit, or unclean SIGTERM is a failure.
The evidence directory is created with mode `0700` and contains throwaway test
credentials; retain it securely and redact credentials before publication.

## 128 MiB cgroup and soak observation

`cgroup-observe.sh` requires root, Docker, cgroup v2, `nsenter`, and `ss`. It
starts the hardened three-protocol container with a 128 MiB memory and swap
ceiling, then records RSS, PSS, FD count, threads, `memory.current`,
`memory.peak`, `memory.stat sock`, TCP connections, and UDP sockets.
`GODEBUG` GC and detailed scheduler traces are captured once per minute in
`runtime-metrics.log` for Go heap, GC, and goroutine analysis.

Build the reviewed source locally as a container image, then run the harness:

```sh
docker build --build-arg VERSION=v1.0.0 -t mini-singbox:v1.0.0 .
sudo tests/cgroup-observe.sh mini-singbox:v1.0.0 evidence/idle-30m 1800 10
sudo tests/cgroup-observe.sh mini-singbox:v1.0.0 evidence/soak-24h 86400 60
```

The 24-hour command is an idle baseline only. The specification's light-load
and pressure tests require an external traffic driver, client-side measurements,
and a documented network topology. Do not treat the idle result as a substitute.

## Restart cycle

```sh
sudo tests/restart-cycle.sh mini-singbox:v1.0.0 evidence/restart-50 50
```

This validates 50 clean container starts and SIGTERM stops under the same
128 MiB hardening settings. Authentication failures, active-connection SIGTERM,
traffic load, protocol combinations, IPv4/IPv6, and domain/IP targets remain
separate live integration gates and must be reported from the actual test lab.

The sanitized `v1.0.0` live-integration and 128 MiB results are recorded in
`docs/validation.md`. A new stable tag must still rerun every automated release
gate and publish fresh signing, SBOM, and provenance evidence.

## Alpine and rootless Podman

`alpine-runtime.sh` is a destructive, disposable-fixture acceptance harness. It
installs the exact CI candidate through the normal deployer and checksum path,
then exercises either:

- Alpine external-supervisor start/status, blocked container tuning, non-root
  identity, transactional certificate renewal, restart and purge; or
- a booted OpenRC service with automatic container-profile detection,
  default-runlevel enablement, blocked host tuning, restart, status, logs and
  purge; and
- transactional migration from an inactive legacy external deployment to the
  detected containerized OpenRC service, including retirement of the obsolete
  foreground runner.

CI runs external mode on Alpine 3.23 and 3.24 and OpenRC mode in a privileged
Alpine 3.24 fixture, covering both a clean automatic install and migration. Do
not run the harness on a host containing a real
`/etc/mini-singbox`; it intentionally uninstalls and purges the fixture.

The `rootless-podman` CI job separately builds the scratch image, imports it into
the unprivileged Podman store, then validates helper-driven generation, check,
start, status, read-only root, PID/memory limits, image upgrade, rollback and
stop. These are short lifecycle gates, not long-duration or real-client proof.
