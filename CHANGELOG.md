# Changelog

All notable changes to `mini-singbox` are recorded here. The project follows
Semantic Versioning.

## v1.0.0 - 2026-08-09

### Added

- Single-process VLESS Reality, Hysteria2, and AnyTLS server using official
  sing-box v1.13.16.
- Strict local schema, secure credential/certificate generation, configuration
  validation, and credential-preserving delivery refresh.
- Independent public ports for shared-NAT deployments.
- Per-protocol standard sharing links, PNG QR images, and terminal QR/link
  output through `mini-singboxctl`.
- Automatic public-address detection and verified Reality target selection.
- Signed, checksum-verified amd64/arm64 release installation without compiling
  on the target VM.
- Hardened systemd, container-compatible systemd, OpenRC, and scratch-container
  profiles for 128 MiB environments.
- SBOM, GitHub build provenance, dependency/forbidden-feature audits, rollback,
  and reproducible release documentation.

### Security

- No panel, remote control, multi-user lifecycle, subscription server, traffic
  accounting, management API, update daemon, limiter, TUN, or WireGuard path.
- Private configuration, keys, sharing links, and QR images use restrictive
  permissions and are never printed by default.
