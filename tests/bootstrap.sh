#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
source bootstrap.sh

test_failure() {
	if ("$@" >/dev/null 2>&1); then
		printf 'expected failure: %s\n' "$*" >&2
		exit 1
	fi
}

for version in v0.0.0 v1.0.0 v12.34.56; do
	valid_stable_version "$version"
done
for version in 1.0.0 v01.0.0 v1.02.3 v1.2 v1.2.3-rc.1 v1.2.3/latest; do
	test_failure valid_stable_version "$version"
done

export MINI_SINGBOX_VERSION=v2.3.4
[[ "$(resolve_version)" == v2.3.4 ]]
unset MINI_SINGBOX_VERSION

curl() {
	printf '%s' "$MOCK_EFFECTIVE_URL"
}

MOCK_EFFECTIVE_URL=https://github.com/XDuke/mini-singbox/releases/tag/v3.4.5
[[ "$(resolve_version)" == v3.4.5 ]]
MOCK_EFFECTIVE_URL=https://example.com/XDuke/mini-singbox/releases/tag/v3.4.5
test_failure resolve_version
MOCK_EFFECTIVE_URL=https://github.com/XDuke/mini-singbox/releases/tag/v3.4.5-rc.1
test_failure resolve_version

grep -Fq -- "--proto '=https'" bootstrap.sh
grep -Fq "refs/tags/\$version" bootstrap.sh
grep -Fq "cat-file -t \"\$tag_ref\"" bootstrap.sh
grep -Fq "MINI_SINGBOX_RELEASE_TAG=\$version" bootstrap.sh
grep -Fq 'status --porcelain' bootstrap.sh
grep -Fq "verify_signed_checkout_file \"\$UPDATE_SOURCE\" bootstrap.sh" scripts/deploy.sh
grep -Fq "verify_signed_checkout_file \"\$UNINSTALL_SOURCE\" scripts/uninstall.sh" scripts/deploy.sh
grep -Fq "install -m 0755 \"\$UPDATE_SOURCE\" \"\$UPDATE_PATH\"" scripts/deploy.sh
grep -Fq "install -m 0755 \"\$UNINSTALL_SOURCE\" \"\$UNINSTALL_PATH\"" scripts/deploy.sh
if [[ "$(grep -c '^            bootstrap\.sh$' .github/workflows/release.yml)" -ne 2 ]]; then
	printf 'bootstrap must be signed and staged exactly once per release list\n' >&2
	exit 1
fi
if grep -Eq -- '--insecure|(^|[[:space:]])-k([[:space:]]|$)|releases/latest/download/mini-singbox' bootstrap.sh; then
	printf 'unsafe bootstrap download pattern found\n' >&2
	exit 1
fi

printf 'bootstrap tests passed\n'
