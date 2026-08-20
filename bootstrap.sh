#!/bin/sh
set -eu

readonly REPOSITORY="XDuke/mini-singbox"
readonly REPOSITORY_URL="https://github.com/${REPOSITORY}.git"
readonly LATEST_RELEASE_URL="https://github.com/${REPOSITORY}/releases/latest"
readonly PINNED_MINISIGN_PUBLIC_KEY="RWTdosnHY0/ogpyGB9SURrdhWQxdLkNxuNc9u08FwdA41OmoFI/zoSEg"
temporary_directory=""

fail() {
	printf 'mini-singbox bootstrap: %s\n' "$*" >&2
	exit 1
}

warn() {
	printf 'WARNING: %s\n' "$*" >&2
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

valid_stable_version() {
	printf '%s\n' "$1" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}

valid_candidate_version() {
	printf '%s\n' "$1" | grep -Eq '^candidate-[0-9a-f]{12}$'
}

resolve_version() {
	if [ -n "${MINI_SINGBOX_VERSION:-}" ]; then
		version="$MINI_SINGBOX_VERSION"
	else
		effective_url="$(curl --fail --silent --show-error --location \
			--proto '=https' --tlsv1.2 --retry 3 --connect-timeout 20 --max-time 60 \
			--output /dev/null --write-out '%{url_effective}' "$LATEST_RELEASE_URL")" || \
			fail "cannot resolve the latest formal release"
		expected_prefix="https://github.com/${REPOSITORY}/releases/tag/"
		case "$effective_url" in
			"$expected_prefix"*) version="${effective_url#"$expected_prefix"}" ;;
			*) fail "unexpected latest-release redirect: $effective_url" ;;
		esac
		case "$version" in */*) fail "invalid latest-release redirect: $effective_url" ;; esac
	fi
	if valid_stable_version "$version"; then
		printf '%s\n' "$version"
		return 0
	fi
	if [ "${MINI_SINGBOX_ALLOW_CANDIDATE:-0}" = "1" ] && valid_candidate_version "$version"; then
		printf '%s\n' "$version"
		return 0
	fi
	fail "version must be a stable tag such as v1.2.0; candidates require MINI_SINGBOX_ALLOW_CANDIDATE=1"
}

run_root() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	elif command_exists doas; then
		doas "$@"
	else
		command_exists sudo || fail "run as root or install sudo/doas"
		sudo "$@"
	fi
}

install_bootstrap_dependencies() {
	need_minisign="$1"
	missing=0
	command_exists curl || missing=1
	command_exists sha256sum || missing=1
	if [ "$need_minisign" = "1" ] && ! command_exists minisign; then
		missing=1
	fi
	[ "$missing" -eq 0 ] && return 0

	if command_exists apt-get; then
		printf '\n==> Installing bootstrap verification dependencies\n'
		run_root env DEBIAN_FRONTEND=noninteractive apt-get update
		packages="ca-certificates coreutils curl"
		[ "$need_minisign" = "1" ] && packages="$packages minisign"
		# shellcheck disable=SC2086
		run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $packages
	elif command_exists apk; then
		printf '\n==> Installing Alpine bootstrap verification dependencies\n'
		packages="ca-certificates coreutils curl"
		[ "$need_minisign" = "1" ] && packages="$packages minisign"
		# shellcheck disable=SC2086
		run_root apk add --no-cache $packages
	else
		fail "curl, sha256sum and release verification tools are required; automatic setup supports apt or apk"
	fi
	command_exists curl || fail "dependency installation did not provide curl"
	command_exists sha256sum || fail "dependency installation did not provide sha256sum"
	if [ "$need_minisign" = "1" ]; then
		command_exists minisign || fail "dependency installation did not provide minisign"
	fi
}

install_git_for_legacy_release() {
	command_exists git && return 0
	if command_exists apt-get; then
		run_root env DEBIAN_FRONTEND=noninteractive apt-get update
		run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates git
	elif command_exists apk; then
		run_root apk add --no-cache ca-certificates git
	else
		fail "git is required only for pre-v1.2.0 releases; automatic setup supports apt or apk"
	fi
	command_exists git || fail "dependency installation did not provide git"
}

curl_download() {
	output="$1"
	url="$2"
	curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
		--retry 3 --connect-timeout 20 --max-time 120 --output "$output" "$url"
}

manifest_sha() {
	manifest="$1"
	asset="$2"
	awk -v asset="$asset" '$2 == asset || $2 == "*" asset { print $1 }' "$manifest"
}

verify_manifest_file() {
	manifest="$1"
	file="$2"
	asset="$3"
	if [ ! -f "$file" ] || [ -L "$file" ]; then
		fail "downloaded asset is missing or unsafe: $asset"
	fi
	expected="$(manifest_sha "$manifest" "$asset")"
	printf '%s\n' "$expected" | grep -Eq '^[0-9a-f]{64}$' || \
		fail "checksum manifest does not contain exactly one valid SHA-256 for $asset"
	actual="$(sha256sum "$file" | awk '{ print $1 }')"
	[ "$actual" = "$expected" ] || fail "SHA-256 verification failed for $asset"
}

write_pinned_public_key() {
	pinned_public_key_file="$1"
	(
		umask 077
		printf '%s\n%s\n' \
			'untrusted comment: minisign public key 82E84F63C7C9A2DD' \
			"$PINNED_MINISIGN_PUBLIC_KEY" > "$pinned_public_key_file"
	)
}

append_deployment_environment() {
	is_set=""
	value=""
	for name in \
		MINI_SINGBOX_PROTOCOLS MINI_SINGBOX_LISTEN \
		MINI_SINGBOX_REALITY_PORT MINI_SINGBOX_HY2_PORT MINI_SINGBOX_ANYTLS_PORT \
		MINI_SINGBOX_PUBLIC_ADDRESS MINI_SINGBOX_PUBLIC_REALITY_PORT \
		MINI_SINGBOX_PUBLIC_HY2_PORT MINI_SINGBOX_PUBLIC_ANYTLS_PORT \
		MINI_SINGBOX_IP_FAMILY MINI_SINGBOX_REALITY_SERVER_NAME \
		MINI_SINGBOX_REALITY_HANDSHAKE MINI_SINGBOX_REALITY_CANDIDATES \
		MINI_SINGBOX_TLS_SAN MINI_SINGBOX_AUTO_DETECT MINI_SINGBOX_AUTO_TUNE \
		MINI_SINGBOX_REGENERATE MINI_SINGBOX_REFRESH_DELIVERY \
		MINI_SINGBOX_ALLOW_INSECURE_ANYTLS_SHARE MINI_SINGBOX_BACKUP_KEEP \
		MINI_SINGBOX_RUNTIME; do
		eval "is_set=\${$name+x}"
		if [ "$is_set" = "x" ]; then
			eval "value=\${$name}"
			set -- "$@" "$name=$value"
		fi
	done
	DEPLOY_ENV_FILE="$temporary_directory/deployment-environment"
	: > "$DEPLOY_ENV_FILE"
	for assignment in "$@"; do
		printf '%s\n' "$assignment" >> "$DEPLOY_ENV_FILE"
	done
}

run_deployer() {
	deployer="$1"
	bundle="$2"
	version="$3"
	commit="$4"
	pinned_key="$5"
	set -- env \
		"MINI_SINGBOX_BUNDLE_DIR=$bundle" \
		"MINI_SINGBOX_RELEASE_TAG=$version" \
		"MINI_SINGBOX_SOURCE_COMMIT=$commit" \
		"MINI_SINGBOX_MINISIGN_PUBKEY_FILE=$pinned_key"
	while IFS= read -r assignment; do
		[ -n "$assignment" ] && set -- "$@" "$assignment"
	done < "$DEPLOY_ENV_FILE"
	set -- "$@" "$deployer"
	run_root "$@"
}

legacy_checkout_deploy() {
	version="$1"
	pinned_key="$2"
	install_git_for_legacy_release
	checkout="$temporary_directory/legacy-source"
	printf '\n==> Using the verified legacy checkout path for %s\n' "$version"
	GIT_TERMINAL_PROMPT=0 git -c advice.detachedHead=false clone --quiet \
		--branch "$version" --depth 1 --single-branch -- "$REPOSITORY_URL" "$checkout" || \
		fail "cannot clone exact legacy release tag $version"
	[ "$(git -C "$checkout" remote get-url origin)" = "$REPOSITORY_URL" ] || fail "legacy checkout origin mismatch"
	tag_ref="refs/tags/$version"
	git -C "$checkout" show-ref --verify --quiet "$tag_ref" || fail "legacy release tag is missing"
	[ "$(git -C "$checkout" cat-file -t "$tag_ref")" = tag ] || fail "legacy formal release tag is not annotated"
	commit="$(git -C "$checkout" rev-parse "$tag_ref^{}")"
	[ "$(git -C "$checkout" rev-parse HEAD)" = "$commit" ] || fail "legacy checkout commit mismatch"
	[ -z "$(git -C "$checkout" status --porcelain)" ] || fail "legacy release checkout is not clean"
	set -- env "MINI_SINGBOX_RELEASE_TAG=$version" \
		"MINI_SINGBOX_MINISIGN_PUBKEY_FILE=$pinned_key"
	while IFS= read -r assignment; do
		[ -n "$assignment" ] && set -- "$@" "$assignment"
	done < "$DEPLOY_ENV_FILE"
	set -- "$@" "$checkout/scripts/deploy.sh"
	run_root "$@"
}

cleanup() {
	status=$?
	trap - EXIT HUP INT TERM
	case "${temporary_directory:-}" in
		/tmp/mini-singbox-bootstrap.*|/var/tmp/mini-singbox-bootstrap.*) rm -rf -- "$temporary_directory" ;;
		"") ;;
		*) warn "refusing to remove unexpected temporary directory $temporary_directory" ;;
	esac
	exit "$status"
}

main() {
	[ "$#" -eq 0 ] || fail "this command does not accept arguments; use MINI_SINGBOX_* variables"
	[ "$(uname -s)" = Linux ] || fail "this bootstrap supports Linux only"
	command_exists mktemp || fail "mktemp is required"
	command_exists env || fail "env is required"
	case "${MINI_SINGBOX_ALLOW_CANDIDATE:-0}" in 0|1) ;; *) fail "MINI_SINGBOX_ALLOW_CANDIDATE must be 0 or 1" ;; esac

	need_minisign=1
	if [ "${MINI_SINGBOX_ALLOW_CANDIDATE:-0}" = 1 ] && \
		valid_candidate_version "${MINI_SINGBOX_VERSION:-}"; then
		need_minisign=0
	fi
	install_bootstrap_dependencies "$need_minisign"
	version="$(resolve_version)"

	temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/mini-singbox-bootstrap.XXXXXX")" || fail "cannot create temporary directory"
	case "$temporary_directory" in
		/tmp/mini-singbox-bootstrap.*|/var/tmp/mini-singbox-bootstrap.*) ;;
		*) fail "mktemp returned an unexpected directory: $temporary_directory" ;;
	esac
	trap cleanup EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	append_deployment_environment
	pinned_key="$temporary_directory/minisign.pub"
	write_pinned_public_key "$pinned_key"

	release_base="https://github.com/$REPOSITORY/releases/download/$version"
	bundle="$temporary_directory/bundle"
	mkdir -m 0700 "$bundle"
	printf '\n==> Resolving mini-singbox %s deployment bundle\n' "$version"
	case "$version" in
	v1.0.0|v1.1.0|v1.1.1)
		if ! curl_download "$bundle/release-metadata.txt" "$release_base/release-metadata.txt" 2>/dev/null; then
			legacy_checkout_deploy "$version" "$pinned_key"
			return 0
		fi
		;;
	*)
		curl_download "$bundle/release-metadata.txt" "$release_base/release-metadata.txt" || \
			fail "release does not contain the required asset-first metadata"
		;;
	esac
	curl_download "$bundle/SHA256SUMS" "$release_base/SHA256SUMS"
	if [ "$need_minisign" -eq 1 ]; then
		curl_download "$bundle/SHA256SUMS.minisig" "$release_base/SHA256SUMS.minisig"
		minisign -Vm "$bundle/SHA256SUMS" -x "$bundle/SHA256SUMS.minisig" -p "$pinned_key" >/dev/null || \
			fail "release checksum signature verification failed"
	else
		warn "installing an explicitly selected unsigned CI candidate; do not use it as a formal release"
	fi
	verify_manifest_file "$bundle/SHA256SUMS" "$bundle/release-metadata.txt" release-metadata.txt
	metadata_version="$(awk -F= '$1 == "version" { print $2 }' "$bundle/release-metadata.txt")"
	metadata_commit="$(awk -F= '$1 == "commit" { print $2 }' "$bundle/release-metadata.txt")"
	[ "$metadata_version" = "$version" ] || fail "release metadata version mismatch"
	printf '%s\n' "$metadata_commit" | grep -Eq '^[0-9a-f]{40}$' || fail "release metadata commit is invalid"
	case "$version" in
		candidate-*) [ "$(printf '%s' "$metadata_commit" | cut -c1-12)" = "${version#candidate-}" ] || fail "candidate commit mismatch" ;;
	esac

	for asset in \
		deploy.sh mini-singboxctl mini-singbox-containerctl uninstall.sh bootstrap.sh \
		mini-singbox.service mini-singbox-container.service mini-singbox \
		mini-singbox-run minisign.pub; do
		curl_download "$bundle/$asset" "$release_base/$asset"
		verify_manifest_file "$bundle/SHA256SUMS" "$bundle/$asset" "$asset"
	done
	[ "$(tail -n 1 "$bundle/minisign.pub")" = "$PINNED_MINISIGN_PUBLIC_KEY" ] || \
		fail "downloaded minisign public key does not match the independent trust root"
	chmod 0755 "$bundle/deploy.sh" "$bundle/mini-singboxctl" "$bundle/mini-singbox-containerctl" "$bundle/uninstall.sh" \
		"$bundle/bootstrap.sh" "$bundle/mini-singbox" "$bundle/mini-singbox-run"
	printf '    source commit: %s\n' "$metadata_commit"
	printf '    existing credentials are preserved unless MINI_SINGBOX_REGENERATE=1\n'
	run_deployer "$bundle/deploy.sh" "$bundle" "$version" "$metadata_commit" "$pinned_key"
}

if [ "${MINI_SINGBOX_BOOTSTRAP_SOURCE_ONLY:-0}" != "1" ]; then
	main "$@"
fi
