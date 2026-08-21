#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2329
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

export MINI_SINGBOX_BOOTSTRAP_SOURCE_ONLY=1
# The sourced functions intentionally read variables and a mocked curl that are
# assigned later in this test file.
source bootstrap.sh
unset MINI_SINGBOX_BOOTSTRAP_SOURCE_ONLY

expect_failure() {
	if ("$@" >/dev/null 2>&1); then
		echo "expected failure: $*" >&2
		exit 1
	fi
}

for version in v0.0.0 v1.2.0 v12.34.56; do
	valid_stable_version "$version"
done
for version in v1.2 v1.2.0-rc1 1.2.0 v01.2.3 'v1.2.3/extra'; do
	expect_failure valid_stable_version "$version"
done

for version in candidate-0123456789ab candidate-abcdef012345; do
	valid_candidate_version "$version"
done
for version in candidate-0123456789 candidate-0123456789AB candidate-main candidate-0123456789abc; do
	expect_failure valid_candidate_version "$version"
done

MINI_SINGBOX_VERSION=v2.3.4
test "$(resolve_version)" = v2.3.4

MINI_SINGBOX_VERSION=candidate-0123456789ab
MINI_SINGBOX_ALLOW_CANDIDATE=1
test "$(resolve_version)" = candidate-0123456789ab

unset MINI_SINGBOX_ALLOW_CANDIDATE
expect_failure resolve_version

unset MINI_SINGBOX_VERSION
curl() {
	printf '%s\n' 'https://github.com/XDuke/mini-singbox/releases/tag/v9.8.7'
}
test "$(resolve_version)" = v9.8.7
unset -f curl

grep -Fq 'RWTdosnHY0/ogpyGB9SURrdhWQxdLkNxuNc9u08FwdA41OmoFI/zoSEg' bootstrap.sh
grep -Fq 'release-metadata.txt' bootstrap.sh
grep -Fq 'SHA256SUMS.minisig' bootstrap.sh
grep -Fq 'apk add --no-cache' bootstrap.sh
grep -Fq 'packages="ca-certificates coreutils curl"' bootstrap.sh
grep -Fq 'command_exists curl || missing=1' bootstrap.sh
grep -Fq 'MINI_SINGBOX_RUNTIME' bootstrap.sh
grep -Fq 'MINI_SINGBOX_BUNDLE_DIR' bootstrap.sh
grep -Fq 'mini-singbox-run minisign.pub' bootstrap.sh
grep -Fq 'v1.0.0|v1.1.0|v1.1.1' bootstrap.sh
grep -Fq 'runtime=' scripts/deploy.sh
grep -Fq 'openrc' scripts/deploy.sh
grep -Fq 'openrc-container' scripts/deploy.sh
grep -Fq 'migrating an inactive external deployment' scripts/deploy.sh
grep -Fq 'tuning_is_host_owned' scripts/mini-singboxctl
grep -Fq 'output_log="/var/log/mini-singbox/service.log"' packaging/openrc/mini-singbox
grep -Fq 'MINI_SINGBOX_OPENRC_LOG_PATH' scripts/mini-singboxctl
if grep -Fq 'output_logger=' packaging/openrc/mini-singbox; then
	echo 'OpenRC service must not depend on an unverified syslog socket' >&2
	exit 1
fi
grep -Fq 'external' scripts/deploy.sh
grep -Fq 'develop/v1.2.0-alpine' .github/workflows/candidate-binaries.yml
for asset in \
	release-metadata.txt deploy.sh mini-singboxctl mini-singbox-containerctl uninstall.sh bootstrap.sh \
	mini-singbox.service mini-singbox-container.service mini-singbox \
	mini-singbox-run minisign.pub; do
	grep -Fq "$asset" .github/workflows/candidate-binaries.yml
	grep -Fq "$asset" .github/workflows/release.yml
done

if grep -nE 'curl[^\n]*(--insecure|-k)([[:space:]]|$)|wget[^\n]*(--no-check-certificate)' bootstrap.sh; then
	echo 'bootstrap must not disable TLS verification' >&2
	exit 1
fi

POSIX_SHELL="${POSIX_SHELL:-/bin/sh}"
MINI_SINGBOX_BOOTSTRAP_SOURCE_ONLY=1 "$POSIX_SHELL" < bootstrap.sh
"$POSIX_SHELL" -n bootstrap.sh

echo 'bootstrap guardrail tests passed'
