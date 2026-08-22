# Changelog

All notable changes to `mini-singbox` are recorded here. The project follows
Semantic Versioning.

## v1.2.0 - Unreleased

### Added

- Added native Alpine Linux 3.23/3.24 installation with an OpenRC
  `supervise-daemon` service, non-root identity, configuration pre-check,
  bounded respawn, startup observation, listener checks, and uninstall support.
- Added an explicit external-supervisor runtime for provider containers. It
  installs a privilege-dropping foreground runner without falsely claiming
  inner-container autostart or ownership of outer logs.
- Added a rootless Podman/Docker lifecycle helper with network-disabled
  generation and checks, hardened startup, transactional digest upgrades,
  image rollback, QR display, certificate renewal, and credential-preserving
  uninstall.
- Added Alpine external/OpenRC and rootless Podman CI acceptance gates plus
  multi-architecture GHCR publication and image provenance for formal releases.
- Added public-port provenance to deployment records and status output so
  container/shared-NAT installs distinguish explicit mappings from assumed
  listen-equals-public ports.
- Added authenticated AnyTLS exports for sing-box, Mihomo, and v2rayN. The
  v2rayN-specific link and QR embed the server certificate; the Mihomo export
  pins the complete leaf-certificate SHA-256 fingerprint.
- Added `export anytls <sing-box|mihomo|v2rayn>` to host and rootless-container
  control tools.

### Changed

- OpenRC auto-detection now distinguishes installed tooling from an active PID
  1 service manager. Full Alpine/OpenRC containers use an `openrc-container`
  profile, while provider containers without a real init remain external.
- Inactive deployments previously misclassified as external migrate
  transactionally to containerized OpenRC; active external processes and all
  other implicit cross-runtime changes remain blocked.
- Reworked bootstrap into an asset-first path for v1.2.0 and newer: stable
  releases verify the independently pinned minisign key, signed checksum
  manifest, release metadata, and each deployment asset without cloning Git on
  the target. A narrow verified legacy fallback remains for v1.1.1.
- Generalized deployment, status, logs, certificate renewal, rollback, update,
  and uninstall transactions across systemd, OpenRC, and external runtimes.
- `qr anytls` and `qr all` now render the authenticated v2rayN-specific QR,
  print its sensitive link underneath, and identify the sing-box and Mihomo
  alternatives without presenting the QR as Clash-compatible.
- Deployment, delivery refresh, certificate renewal, rollback, and post-install
  validation now manage all authenticated AnyTLS client artifacts together.
- OpenRC service output now uses a bounded root-owned private local log instead
  of an unverified syslog socket; only the service group can write it, and the
  control tool reads it without following symbolic links.
- Formal release bundles now include OpenRC/external/container helpers,
  release metadata, and the immutable OCI digest alongside binary checksums,
  SBOM, and provenance.
- Existing installations now stage the verified binary with a same-filesystem
  hard link when available, rename the installed binary directly into the
  rollback directory, and atomically switch the staged file. This removes two
  avoidable large-file copies and lowers upgrade page-cache pressure on
  128-MiB containers while retaining cross-filesystem fallback and rollback.

### Security

- Container/external deployments never apply host TCP sysctls, including
  OpenRC and systemd container profiles; direct and control-tool tuning paths
  reject known container virtualization.
- OpenRC uses a root-owned PID file, `no_new_privs`, restrictive umask, and an
  unprivileged service user. OCI runtime defaults remain read-only, capability
  free, `no-new-privileges`, 64-PID and 128-MiB bounded.
- Standard `anytls://` remains disabled by default because it cannot carry the
  self-signed certificate trust material. All new default AnyTLS artifacts are
  private (`0600`) and reject symbolic-link substitution during export.

## v1.1.1 - 2026-08-16

### Fixed

- Fixed `bootstrap.sh` stdin execution under `set -u` and added a regression
  test for the documented `curl | bash` path.
- Made forced multi-file generation transactional across the complete file set,
  including reverse-order rollback after a mid-commit failure.
- Added strict boolean validation and explicit historical-backup removal through
  `PURGE_BACKUPS=1`.
- Added certificate-only renewal with credential preservation, rebuilt client
  pins, guarded service restart, and full configuration rollback on failure.
- Made custom Compose protocol ports apply consistently to generation and both
  sides of each published port mapping.

### Changed

- AnyTLS self-signed delivery now defaults to an authenticated sing-box outbound
  with the server certificate embedded. The unauthenticated standard URI/QR is
  available only through an explicitly unsafe compatibility switch.
- Existing AnyTLS installations automatically refresh delivery files on upgrade
  when the authenticated outbound is missing or an old insecure share remains.
- The supported service manager is now systemd; the duplicate legacy installer
  and incomplete OpenRC release path were removed.
- Configuration, key, certificate, and delivery paths now consistently reject
  symbolic links.

### Security

- Bootstrap pins the minisign public key independently of the release tag before
  verifying the signed checksum manifest.
- Documentation now distinguishes v1.0.0 live 128 MiB evidence from later CI
  checks and distinguishes full-VM from container-compatible systemd hardening.

## v1.1.0 - 2026-08-15

### Added

- Short `bootstrap.sh` entry that resolves the latest stable mini-singbox release,
  verifies an exact annotated tag, and reuses the signed deployment chain.
- Signed on-demand `mini-singbox-update` and `mini-singbox-uninstall` commands.
- Offline, protocol-aware `mini-singbox tune` detection, planning, dry-run,
  transactional apply, verification, status, and ownership-safe rollback.
- Deployment-time safe-core TCP tuning with cgroup v1/v2 effective-memory
  detection and an explicit `MINI_SINGBOX_AUTO_TUNE=0` opt-out.
- Weekly Dependabot tracking limited to the official sing-box Go module; updates
  still require review, CI, and a new immutable mini-singbox release.

### Changed

- Updated the embedded official sing-box module from v1.13.16 to v1.13.18.
- Updated the pinned build toolchain from Go 1.26.5 to Go 1.26.6 for standard
  library security fixes.
- Re-running the bootstrap or update command preserves existing credentials and
  rollback state unless regeneration is explicitly requested.
- Hysteria2 remains explicitly outside TCP tuning; automatic tuning does not
  change buffers, RPS/RFS, routes, firewall, kernel, modules, or traffic shaping.

### Security

- Stable bootstrap rejects prerelease and lightweight tags, verifies the official
  origin, exact tag commit, and clean checkout, and never bypasses TLS checks.
- Target VMs continue to download verified static project binaries and never
  compile or directly replace an unverified upstream sing-box executable.

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
