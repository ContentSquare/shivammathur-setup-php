#!/usr/bin/env bash

php_darwin_root=${PHP_DARWIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

php_darwin_die() {
  printf 'php-darwin: %s\n' "$*" >&2
  exit 1
}

php_darwin_validate_version() {
  awk '!/^#/ && $2 == version { found=1 } END { exit !found }' version="${1:-}" "$php_darwin_root/conf/versions" || \
    php_darwin_die "unsupported PHP version: ${1:-<empty>}"
}

php_darwin_version_channel() {
  awk '!/^#/ && $2 == version { print $1; found=1; exit } END { exit !found }' \
    version="${1:-}" "$php_darwin_root/conf/versions" || \
    php_darwin_die "unsupported PHP version: ${1:-<empty>}"
}

php_darwin_validate_channel() {
  local version=${1:-}
  local expected=${2:-}
  local actual

  case "$expected" in stable|nightly) ;; *) php_darwin_die "unsupported release channel: ${expected:-<empty>}" ;; esac
  actual=$(php_darwin_version_channel "$version")
  [ "$actual" = "$expected" ] || php_darwin_die "PHP $version is $actual, not $expected"
}

php_darwin_validate_build() {
  case "${1:-}" in
    release|debug) ;;
    *) php_darwin_die "build must be release or debug: ${1:-<empty>}" ;;
  esac
}

php_darwin_validate_ts() {
  case "${1:-}" in
    nts|zts) ;;
    *) php_darwin_die "thread safety must be nts or zts: ${1:-<empty>}" ;;
  esac
}

php_darwin_normalize_arch() {
  case "${1:-$(uname -m)}" in
    arm64|aarch64) printf 'arm64\n' ;;
    x86_64|amd64) printf 'x86_64\n' ;;
    *) php_darwin_die "unsupported architecture: ${1:-<empty>}" ;;
  esac
}

php_darwin_expected_prefix() {
  jq -er --arg arch "$(php_darwin_normalize_arch "${1:-}")" '.[$arch].brew_prefix' \
    "$php_darwin_root/conf/platforms.json" || php_darwin_die 'Homebrew prefix is not configured'
}

php_darwin_package_config() {
  jq -er --arg key "$1" '.[$key]' "$php_darwin_root/conf/package.json" || \
    php_darwin_die "package configuration is missing: $1"
}

php_darwin_formula_suffix() {
  local build=${1:-release}
  local ts=${2:-nts}
  local suffix=

  php_darwin_validate_build "$build"
  php_darwin_validate_ts "$ts"
  [ "$build" = debug ] && suffix=-debug
  [ "$ts" = zts ] && suffix="$suffix-zts"
  printf '%s\n' "$suffix"
}

php_darwin_formula() {
  local version=$1
  local current_version
  local suffix

  php_darwin_validate_version "$version"
  suffix=$(php_darwin_formula_suffix "${2:-release}" "${3:-nts}")
  current_version=$(php_darwin_package_config current_version)
  if [ "$version" = "$current_version" ]; then
    printf 'php%s\n' "$suffix"
  else
    printf 'php@%s%s\n' "$version" "$suffix"
  fi
}

php_darwin_requested_formula() {
  local version=$1
  local suffix

  php_darwin_validate_version "$version"
  suffix=$(php_darwin_formula_suffix "${2:-release}" "${3:-nts}")
  printf 'php@%s%s\n' "$version" "$suffix"
}

php_darwin_asset() {
  local version=$1
  local version_major
  local version_minor
  local build=${2:-release}
  local ts=${3:-nts}
  local arch

  IFS=. read -r version_major version_minor _ <<< "$version"
  php_darwin_validate_version "$version_major.$version_minor"
  php_darwin_validate_build "$build"
  php_darwin_validate_ts "$ts"
  arch=$(php_darwin_normalize_arch "${4:-}")
  printf 'php_%s-%s-%s+darwin_%s.tar.zst\n' "$version" "$ts" "$build" "$arch"
}

php_darwin_sha256() {
  local hash_output

  if command -v sha256sum >/dev/null 2>&1; then
    hash_output=$(sha256sum "$1") || return 1
  else
    hash_output=$(shasum -a 256 "$1") || return 1
  fi
  printf '%s\n' "${hash_output%% *}"
}
