# Reproducible build and release procedure

Only an exact semantic-version tag may publish a stable release. Release assets
are immutable; a failed release must use a new version after correction.

## Candidate verification

Use Go 1.26.5 on Linux and a clean tree:

```sh
test "$(go env GOVERSION)" = go1.26.5
test -z "$(git status --porcelain)"
test -z "$(gofmt -l .)"
go mod verify
go vet -tags with_utls ./...
go test -tags with_utls ./...
go test -race -tags with_utls ./...
go test -tags fuzz -run '^$' -fuzz=FuzzDecode -fuzztime=30s ./internal/config
govulncheck -tags with_utls ./...
```

CI additionally performs static amd64/arm64 builds, dependency and forbidden
feature scans, shell analysis, file-mode tests, hardened container generation,
configuration checks, startup and clean SIGTERM.

## Signing key

The dedicated minisign private key is stored only as the protected GitHub
environment secrets `MINISIGN_PRIVATE_KEY` and `MINISIGN_PASSWORD`. Its public
key is pinned at `release/minisign.pub`. Never commit the private key or reuse it
for another project.

## Publication

Create an annotated tag on the reviewed commit and push only that tag:

```sh
git tag -a v1.0.0 -m 'mini-singbox v1.0.0'
git push origin v1.0.0
```

The tag workflow reruns all gates and creates:

- `mini-singbox-linux-amd64`
- `mini-singbox-linux-arm64`
- `SHA256SUMS` and `SHA256SUMS.minisig`
- `SBOM.spdx.json`
- `provenance.intoto.jsonl`
- Go build metadata and compiled-dependency audit evidence
- source, license/notice, security, migration, deployment and service files

Builds use `CGO_ENABLED=0`, `-trimpath`, an empty build ID, the tag as version,
the exact commit, and the commit timestamp. GitHub provenance records the hosted
build context.

## Consumer verification

```sh
minisign -Vm SHA256SUMS -x SHA256SUMS.minisig -p release/minisign.pub
sha256sum -c SHA256SUMS --ignore-missing
go version -m mini-singbox-linux-amd64
```

The deployer performs the same signature/checksum checks and additionally
validates ELF architecture, static linking, version, full commit, clean build,
configuration, process identity, startup stability, and listening sockets.
