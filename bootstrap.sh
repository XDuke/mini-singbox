#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPOSITORY="XDuke/mini-singbox"
readonly REPOSITORY_URL="https://github.com/${REPOSITORY}.git"
readonly LATEST_RELEASE_URL="https://github.com/${REPOSITORY}/releases/latest"
temporary_directory=""

fail() {
	printf 'mini-singbox bootstrap: %s\n' "$*" >&2
	exit 1
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

valid_stable_version() {
	[[ "$1" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

resolve_version() {
	local version effective_url expected_prefix
	if [[ -n "${MINI_SINGBOX_VERSION:-}" ]]; then
		version="$MINI_SINGBOX_VERSION"
	else
		effective_url="$(curl --fail --silent --show-error --location \
			--proto '=https' --tlsv1.2 --retry 3 --connect-timeout 20 --max-time 60 \
			--output /dev/null --write-out '%{url_effective}' "$LATEST_RELEASE_URL")" || \
			fail "cannot resolve the latest formal release"
		expected_prefix="https://github.com/${REPOSITORY}/releases/tag/"
		[[ "$effective_url" == "$expected_prefix"* ]] || \
			fail "unexpected latest-release redirect: $effective_url"
		version="${effective_url#"$expected_prefix"}"
		[[ "$version" != */* ]] || fail "invalid latest-release redirect: $effective_url"
	fi
	valid_stable_version "$version" || \
		fail "version must be a stable tag such as v1.0.0: $version"
	printf '%s\n' "$version"
}

root_prefix() {
	if ((EUID == 0)); then
		return 0
	fi
	command_exists sudo || fail "run as root or install sudo"
	printf '%s\n' sudo
}

install_git_if_needed() {
	local -a root_command=("$@")
	command_exists git && return 0
	command_exists apt-get || \
		fail "git is required; automatic installation is supported only on Debian/Ubuntu"
	printf '\n==> Installing the Git bootstrap dependency\n'
	"${root_command[@]}" env DEBIAN_FRONTEND=noninteractive apt-get update
	"${root_command[@]}" env DEBIAN_FRONTEND=noninteractive \
		apt-get install -y --no-install-recommends ca-certificates git
	command_exists git || fail "git installation did not provide the git command"
}

forward_deployment_environment() {
	local name
	local -a names=(
		MINI_SINGBOX_PROTOCOLS
		MINI_SINGBOX_LISTEN
		MINI_SINGBOX_REALITY_PORT
		MINI_SINGBOX_HY2_PORT
		MINI_SINGBOX_ANYTLS_PORT
		MINI_SINGBOX_PUBLIC_ADDRESS
		MINI_SINGBOX_PUBLIC_REALITY_PORT
		MINI_SINGBOX_PUBLIC_HY2_PORT
		MINI_SINGBOX_PUBLIC_ANYTLS_PORT
		MINI_SINGBOX_IP_FAMILY
		MINI_SINGBOX_REALITY_SERVER_NAME
		MINI_SINGBOX_REALITY_HANDSHAKE
		MINI_SINGBOX_REALITY_CANDIDATES
		MINI_SINGBOX_TLS_SAN
		MINI_SINGBOX_AUTO_DETECT
		MINI_SINGBOX_AUTO_TUNE
		MINI_SINGBOX_REGENERATE
		MINI_SINGBOX_REFRESH_DELIVERY
	)
	for name in "${names[@]}"; do
		if [[ -v "$name" ]]; then
			printf '%s=%s\0' "$name" "${!name}"
		fi
	done
}

cleanup() {
	if [[ -n "${temporary_directory:-}" && -d "$temporary_directory" ]]; then
		rm -rf -- "$temporary_directory"
	fi
}

main() {
	local version checkout_directory tag_ref tag_type
	local tag_commit checkout_commit root_name
	local -a root_command=() deployment_environment=()

	[[ "$#" -eq 0 ]] || fail "this command does not accept arguments; use MINI_SINGBOX_* variables"
	[[ "$(uname -s)" == Linux ]] || fail "this bootstrap supports Linux only"
	command_exists curl || fail "curl is required"
	command_exists mktemp || fail "mktemp is required"
	command_exists env || fail "env is required"
	[[ -d /run/systemd/system ]] || fail "a running systemd environment is required"

	root_name="$(root_prefix)"
	if [[ -n "$root_name" ]]; then
		root_command=("$root_name")
	fi
	install_git_if_needed "${root_command[@]}"

	version="$(resolve_version)"
	temporary_directory="$(mktemp -d)" || fail "cannot create a temporary directory"
	[[ -n "$temporary_directory" && -d "$temporary_directory" ]] || \
		fail "mktemp returned an unsafe directory"
	trap cleanup EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	checkout_directory="$temporary_directory/source"

	printf '\n==> Resolving mini-singbox %s\n' "$version"
	GIT_TERMINAL_PROMPT=0 git -c advice.detachedHead=false clone --quiet \
		--branch "$version" --depth 1 --single-branch -- "$REPOSITORY_URL" "$checkout_directory" || \
		fail "cannot clone exact release tag $version"

	[[ "$(git -C "$checkout_directory" remote get-url origin)" == "$REPOSITORY_URL" ]] || \
		fail "checkout origin does not match the official repository"
	tag_ref="refs/tags/$version"
	git -C "$checkout_directory" show-ref --verify --quiet "$tag_ref" || \
		fail "exact release tag is missing after clone: $version"
	tag_type="$(git -C "$checkout_directory" cat-file -t "$tag_ref")"
	[[ "$tag_type" == tag ]] || fail "formal release tag is not an annotated tag: $version"
	tag_commit="$(git -C "$checkout_directory" rev-parse "$tag_ref^{}")"
	checkout_commit="$(git -C "$checkout_directory" rev-parse HEAD)"
	[[ "$checkout_commit" == "$tag_commit" ]] || \
		fail "checkout commit does not match the annotated tag"
	[[ -z "$(git -C "$checkout_directory" status --porcelain)" ]] || \
		fail "release checkout is not clean"

	while IFS= read -r -d '' root_name; do
		deployment_environment+=("$root_name")
	done < <(forward_deployment_environment)
	deployment_environment+=("MINI_SINGBOX_RELEASE_TAG=$version")

	printf '    source commit: %s\n' "$tag_commit"
	printf '    existing credentials are preserved unless MINI_SINGBOX_REGENERATE=1\n'
	"${root_command[@]}" env "${deployment_environment[@]}" \
		"$checkout_directory/scripts/deploy.sh"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
