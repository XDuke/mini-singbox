# v1.0.0 validation record

This document records the sanitized release evidence for `mini-singbox
v1.0.0`. It contains no server address, credential, private key, sharing URI,
or QR image.

## Locked inputs

- Go: `go1.26.5`
- Official sing-box module: `github.com/sagernet/sing-box v1.13.16`
- Release platforms: `linux/amd64`, `linux/arm64`
- Build mode: `CGO_ENABLED=0`, `with_utls`, `-trimpath`, empty build ID
- Runtime target: one process, one Box, one credential per enabled protocol

## Automated gates

Every branch and tag workflow runs formatting, module verification, vet, unit
tests, race tests, decoder fuzzing, govulncheck, static cross-builds, compiled
dependency checks, forbidden implementation/string scans, shell syntax,
ShellCheck, hardened container generation/check/start/stop, and exact file-mode
checks. The tag workflow reruns the gates before it builds release assets.

The release dependency gate excludes gVisor, the sing-box TUN inbound, and
WireGuard endpoint/transport implementations. The public schema has no route,
outbound, endpoint, service, management API, panel, multi-user, subscription,
statistics, limiter, TUN, or WireGuard configuration path.

## Live protocol and 128 MiB evidence

Reference environment: 1 vCPU, 128 MiB RAM, 128 MiB swap, shared-NAT Linux
container, three simultaneous protocol listeners, CI-built static amd64 binary.

Observed during repeated real-client video/data-plane traffic:

| Metric | Result |
|---|---:|
| Receive throughput peak | 57.20 Mbps |
| Transmit throughput peak | 72.17 Mbps |
| Service CPU peak | 18% |
| Service memory peak during traffic | 41.4 MiB |
| Minimum system available memory | 69.6 MiB |
| Swap used | 0 MiB |
| TCP retransmit ratio | 0.0610% |
| UDP receive/send/buffer errors | 0 |
| IP and interface drops/errors | 0 |
| Service interruptions/restarts | 0 |
| Service warnings/errors | 0 |
| OOM events | 0 |

Reality, Hysteria2, and AnyTLS were all enabled; their client links were
validated without publishing credentials. The maintainer confirmed completion
of the remaining extended runtime checks before authorizing the independent
formal release. Raw provider and client artifacts remain private because they
contain instance metadata.

## Delivery and rollback

The deployment path downloads an immutable release for the exact checked-out
tag. Stable releases require minisign verification before SHA-256 parsing, then
verify ELF type, static linking, architecture, version, full Git commit, and
clean-build identity. Installation uses a dedicated non-root account, validates
configuration before restart, observes startup, verifies each enabled socket,
and retains a mode-0700 rollback backup.

## Release artifacts

The release workflow publishes two static binaries, signed checksums, SPDX JSON
SBOM, GitHub build provenance, license/notice, security policy, migration guide,
example configuration, deployment/control/uninstall scripts, and service files.
