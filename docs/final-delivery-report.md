# Final delivery report

## Architecture

`mini-singbox` reads at most 1 MiB of strict project-owned JSON, validates local
files and one credential per enabled protocol, converts the bounded schema to
official sing-box options, creates the minimum registry context, constructs one
Box, and waits for SIGINT/SIGTERM. The only registered inbounds are VLESS,
Hysteria2, and AnyTLS. The endpoint, service, and user-configurable outbound
registries are empty; only the required local DNS transport is registered.

## Removed surface

There is no panel/Xboard client, remote configuration, dynamic-user manager,
traffic counter, hook/tracker, statistics or health endpoint, limiter,
management listener/socket, subscription server, TUN registration, WireGuard,
arbitrary route/DNS/outbound/endpoint/service input, telemetry, or update loop.

## Configuration and secrets

Unknown fields, invalid ports/listeners/credentials, unsafe modes, mismatched
certificates, and invalid Reality material fail closed. Generated passwords use
32 random bytes; Short IDs use 8 random bytes; certificates are ECDSA P-256,
server-auth-only and valid for 365 days. Files are staged in the destination,
fsynced, atomically renamed, permission checked, reread and verified. Secrets
are silent by default.

## Build and supply chain

The module uses official sing-box v1.13.16 without `replace` and Go 1.26.5.
Linux releases are static amd64/arm64 builds. CI and Release enforce formatting,
module verification, vet, unit/race/fuzz tests, govulncheck, compiled dependency
and forbidden feature scans, shell analysis, container hardening, signed
checksums, SPDX SBOM and GitHub provenance.

## Runtime and delivery

The live 128 MiB validation is recorded in [validation.md](validation.md).
Deployment never compiles on the target, verifies exact immutable assets,
supports shared NAT, uses a dedicated non-root user, observes startup/listeners,
and retains a guarded rollback backup. `mini-singboxctl` provides on-demand
status, certificate, logs, version and explicit credential QR/link display.

## Remaining limitations

The service is intentionally single-user and exposes only three protocols.
Self-signed HY2/AnyTLS certificates require the generated client settings.
Automatic public-address and Reality selection depend on deployment-time
Internet access. Firewall and provider NAT configuration remain operator tasks.
