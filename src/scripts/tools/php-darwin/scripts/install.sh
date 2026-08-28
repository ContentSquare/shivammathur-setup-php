#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$script_dir/lib.sh"

version=${1:-8.5}
build=${2:-release}
ts=${3:-nts}
local_archive=${4:-}
arch=$(php_darwin_normalize_arch "$(uname -m)")
formula=$(php_darwin_formula "$version" "$build" "$ts")
requested_formula=$(php_darwin_requested_formula "$version" "$build" "$ts")
asset=$(php_darwin_asset "$version" "$build" "$ts" "$arch")
expected_prefix=$(php_darwin_expected_prefix "$arch")
tap=$(php_darwin_package_config tap)
archive_roots="$script_dir/../conf/archive-paths"

[ "$(uname -s)" = Darwin ] || php_darwin_die 'the cache installer only supports macOS'
command -v brew >/dev/null 2>&1 || php_darwin_die 'Homebrew is required'
brew_prefix=$(brew --prefix)
[ "$brew_prefix" = "$expected_prefix" ] || php_darwin_die "architecture $arch requires Homebrew at $expected_prefix, found $brew_prefix"
command -v zstd >/dev/null 2>&1 || php_darwin_die 'zstd is required to extract the cache'
macos_version=$(sw_vers -productVersion) || php_darwin_die 'could not determine the macOS version'
macos_major=${macos_version%%.*}

while IFS= read -r managed_dir extra; do
  [ -n "$managed_dir" ] || continue
  case "$managed_dir" in \#*) continue ;; esac
  [ -z "$extra" ] || php_darwin_die "invalid archive root: $managed_dir $extra"
  case "$managed_dir" in Cellar|etc|opt|var) ;; *) php_darwin_die "unsafe archive root: $managed_dir" ;; esac
  [ -d "$brew_prefix/$managed_dir" ] || mkdir -p "$brew_prefix/$managed_dir" || \
    php_darwin_die "could not create Homebrew directory: $brew_prefix/$managed_dir"
  [ -w "$brew_prefix/$managed_dir" ] || \
    php_darwin_die "Homebrew directory is not writable: $brew_prefix/$managed_dir"
done < "$archive_roots"

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
export HOMEBREW_NO_INSTALL_FROM_API=1

# Use Homebrew to establish the formula source and trust state. In setup-php the
# tap is already present, so this is a local no-op and adds no install request.
brew tap "$tap" || php_darwin_die "could not tap $tap"
brew trust "$tap" || php_darwin_die "could not trust $tap"
brew formula "$tap/$requested_formula" >/dev/null || php_darwin_die "could not resolve $tap/$requested_formula"

tmp_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-install.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT
archive="$tmp_dir/$asset"
external_metadata=

if [ -n "$local_archive" ]; then
  archive=$local_archive
  checksum="$local_archive.sha256"
  external_metadata="$(dirname "$local_archive")/${asset%.tar.zst}.json"
  [ -f "$archive" ] || php_darwin_die "archive not found: $archive"
  [ -f "$checksum" ] || php_darwin_die "checksum not found: $checksum"
  [ -f "$external_metadata" ] || php_darwin_die "metadata not found: $external_metadata"
  expected_hash=$(awk -v name="$asset" '$2 == name { print $1; found=1; exit } END { exit !found }' "$checksum") || \
    php_darwin_die "checksum file does not contain $asset"
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || php_darwin_die "checksum is invalid for $asset"
  actual_hash=$(php_darwin_sha256 "$archive") || php_darwin_die "could not hash $asset"
  [ "$actual_hash" = "$expected_hash" ] || php_darwin_die "checksum mismatch for $asset"
else
  image=${PHP_DARWIN_IMAGE:-$(php_darwin_package_config image)}
  tag="php-$version-$ts-$build"
  descriptor="$tmp_dir/descriptor.json"
  bash "$script_dir/registry.sh" pull "$image" "$tag" "$asset" "$archive" "$descriptor" || \
    php_darwin_die "could not pull $image:$tag"
  if ! jq -e --arg version "$version" --arg build "$build" --arg ts "$ts" \
    --arg artifact_type "$(php_darwin_package_config artifact_type)" \
    --arg manifest_media_type "$(php_darwin_package_config registry_manifest_media_type)" \
    --arg media_type "$(php_darwin_package_config archive_media_type)" \
    --argjson macos_major "$macos_major" \
    '.annotations["com.setup-php.php-darwin.php-version"] == $version and
     .annotations["com.setup-php.php-darwin.build"] == $build and
     .annotations["com.setup-php.php-darwin.thread-safety"] == $ts and
     (.annotations["com.setup-php.php-darwin.minimum-macos"] | tonumber) <= $macos_major and
     (.annotations["com.setup-php.php-darwin.homebrew-php-commit"] |
       type == "string" and test("^[0-9a-f]{40}$")) and
     (.annotations["com.setup-php.php-darwin.source-hash"] |
       type == "string" and test("^[0-9a-f]{64}$")) and
     (.annotations["org.opencontainers.image.version"] |
       type == "string" and startswith($version + ".") and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
     .schema_version == 2 and .artifact_type == $artifact_type and
     .manifest_media_type == $manifest_media_type and
     .layer.mediaType == $media_type' "$descriptor" >/dev/null; then
    php_darwin_die 'OCI manifest annotations did not match the request'
  fi
  tap_path=$(brew --repository "$tap") || php_darwin_die "could not resolve the $tap repository"
  current_source_hash=$(HOMEBREW_PHP_PATH="$tap_path" bash "$script_dir/source-hash.sh" "$version") || \
    php_darwin_die "could not compute the installed $tap source hash"
  cached_source_hash=$(jq -er '.annotations["com.setup-php.php-darwin.source-hash"]' "$descriptor") || \
    php_darwin_die 'OCI manifest source hash is missing'
  [ "$cached_source_hash" = "$current_source_hash" ] || \
    php_darwin_die "cache is stale for the installed $tap formulae"
fi

if [ -n "$external_metadata" ]; then
  if ! jq -e --arg version "$version" --arg build "$build" --arg ts "$ts" \
    --arg arch "$arch" --arg brew_prefix "$brew_prefix" --arg asset "$asset" --arg formula "$formula" \
    --arg expected_commit "${HOMEBREW_PHP_COMMIT:-}" --arg requested_formula "$requested_formula" \
    --argjson macos_major "$macos_major" \
    '.schema == 1 and .php_version == $version and .build == $build and
     .thread_safety == $ts and .architecture == $arch and .brew_prefix == $brew_prefix and
     .archive == $asset and .formula == $formula and .requested_formula == $requested_formula and
     .minimum_macos <= $macos_major and
     (.homebrew_php_commit | type == "string" and test("^[0-9a-f]{40}$")) and
     ($expected_commit == "" or .homebrew_php_commit == $expected_commit) and
     (.formula_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
     (.php_semver | type == "string" and startswith($version + ".") and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
     (.packages | type == "array" and length > 0) and any(.packages[]; .name == $formula)' \
    "$external_metadata" >/dev/null; then
    php_darwin_die 'archive metadata did not match the runner or request'
  fi
fi

# Let Homebrew remove only the requested PHP formula, then build a literal
# exclusion list for every remaining file and symlink. The archive has no
# directory entries, so tar can stream it straight into the prefix without
# reading, copying, chmodding, or replacing any existing Homebrew path.
if brew list --versions "$formula" >/dev/null 2>&1; then
  brew uninstall --force --ignore-dependencies "$formula" >/dev/null || \
    php_darwin_die "could not remove the existing $formula keg"
fi
exclude_file="$tmp_dir/existing-paths.txt"
bash "$script_dir/existing-paths.sh" "$brew_prefix" "$exclude_file" "$archive_roots" || \
  php_darwin_die 'could not record existing Homebrew paths'
bash "$script_dir/extract.sh" "$archive" "$brew_prefix" "$exclude_file" || \
  php_darwin_die "could not extract $asset into Homebrew"

brew link --overwrite --force "$formula" >/dev/null || php_darwin_die "could not link $formula"
missing=$(brew missing "$formula" 2>&1)
missing_status=$?
[ "$missing_status" -eq 0 ] || [ -n "$missing" ] || php_darwin_die 'Homebrew dependency validation failed without diagnostics'
[ -z "$missing" ] || php_darwin_die "cache has missing Homebrew dependencies: $missing"

php_bin="$brew_prefix/opt/$formula/bin/php"
[ -x "$php_bin" ] || php_darwin_die "PHP binary missing after cache extraction: $php_bin"
installed_semver=$($php_bin -r 'echo PHP_VERSION;') || php_darwin_die 'cached PHP could not report its version'
[ "${installed_semver%.*}" = "$version" ] || php_darwin_die "cache installed PHP $installed_semver for requested $version"

if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n%s\n' "$brew_prefix/opt/$formula/bin" "$brew_prefix/opt/$formula/sbin" >> "$GITHUB_PATH"
fi
printf 'Installed PHP %s (%s, %s, %s) from %s\n' "$installed_semver" "$build" "$ts" "$arch" "$asset"
