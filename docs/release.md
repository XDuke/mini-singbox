# Reproducible build and release procedure

Only an exact semantic-version tag may publish a stable release. Release assets
are immutable; a failed release must use a new version after correction.

## Candidate verification

Use Go 1.26.6 on Linux and a clean tree:

```sh
test "$(go env GOVERSION)" = go1.26.6
test -z "$(git status --porcelain)"
test -z "$(gofmt -l .)"
bash -n bootstrap.sh tests/bootstrap.sh
shellcheck --shell bash bootstrap.sh tests/bootstrap.sh
tests/bootstrap.sh
go mod verify
go vet -tags with_utls ./...
go test -tags with_utls ./...
go test -race -tags with_utls ./...
go test -tags fuzz -run '^$' -fuzz=FuzzDecode -fuzztime=30s ./internal/config
govulncheck -tags with_utls ./...
```

CI additionally performs static amd64/arm64 builds, dependency and forbidden
feature scans, shell analysis, file-mode tests, hardened container generation,
configuration checks, startup and clean SIGTERM. v1.2.0 and newer also run the
exact candidate through Alpine 3.23/3.24 external-supervisor deployment, a
booted Alpine 3.24 OpenRC fixture, and rootless Podman lifecycle, resource-limit,
upgrade and rollback tests.

## Signing key

The dedicated minisign private key is stored only as the protected GitHub
environment secrets `MINISIGN_PRIVATE_KEY` and `MINISIGN_PASSWORD`. Its public
key is pinned at `release/minisign.pub`. Never commit the private key or reuse it
for another project.

Formal publication can additionally use the protected environment secret
`RELEASE_GITHUB_TOKEN`. Use a dedicated fine-grained user token limited to this
repository with Contents write access. The default Actions integration may be
unable to publish a Release for a protected formal tag even when the workflow's
`GITHUB_TOKEN` reports Contents write permission.

## Publication

Create an annotated tag on the reviewed commit and push only that tag:

```sh
version=v1.2.0
git tag -a "$version" -m "mini-singbox $version"
git push origin "$version"
```

Enable release immutability in the repository before publishing. GitHub applies
that setting only to future releases. The tag workflow reruns all gates and
creates:

- `mini-singbox-linux-amd64`
- `mini-singbox-linux-arm64`
- `SHA256SUMS` and `SHA256SUMS.minisig`
- `SBOM.spdx.json`
- `provenance.intoto.jsonl`
- Go build metadata and compiled-dependency audit evidence
- `release-metadata.txt` and `oci-digests.txt`
- signed bootstrap, source, license/notice, security, migration, deployment,
  systemd, OpenRC, external-supervisor and container-control files
- a scratch-based `linux/amd64` + `linux/arm64` image under
  `ghcr.io/xduke/mini-singbox`, addressed by the recorded immutable digest and
  covered by GitHub provenance

The workflow always preserves these 35 files as a flat signed Actions artifact
named `release-bundle-<tag>`. When `RELEASE_GITHUB_TOKEN` is configured, it also
creates the GitHub Release automatically. Without that secret, the workflow
finishes with a notice instead of failing after a successful build: an
authorized maintainer must create a draft for the existing annotated tag,
upload every file from the flat bundle, verify the 35-file count, and publish
the draft. GitHub then freezes the tag and assets.

Builds use `CGO_ENABLED=0`, `-trimpath`, an empty build ID, the tag as version,
the exact commit, and the commit timestamp. GitHub provenance records the hosted
build context. The formal OCI version tag is checked for prior existence before
publication so a rerun cannot silently replace it; moving major/minor and
`latest` tags are convenience pointers only.

## Consumer verification

```sh
minisign -Vm SHA256SUMS -x SHA256SUMS.minisig -p release/minisign.pub
sha256sum -c SHA256SUMS --ignore-missing
go version -m mini-singbox-linux-amd64
gh attestation verify "oci://$(cat oci-digests.txt)" -R XDuke/mini-singbox
```

The deployer performs the same signature/checksum checks and additionally
validates ELF architecture, static linking, version, full commit, clean build,
configuration, process identity, startup stability, and listening sockets.
