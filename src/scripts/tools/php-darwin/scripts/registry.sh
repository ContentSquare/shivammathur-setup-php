#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$script_dir/lib.sh"

manifest_media_type=$(php_darwin_package_config registry_manifest_media_type)
artifact_type=$(php_darwin_package_config artifact_type)
archive_media_type=$(php_darwin_package_config archive_media_type)
configured_layer_count=$(jq 'keys | length' "$script_dir/../conf/platforms.json") || \
  php_darwin_die 'could not read the configured platform count'

registry_auth() {
  registry_image=$1
  [[ "$registry_image" =~ ^[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+$ ]] || \
    php_darwin_die "invalid registry image: $registry_image"
  case "$registry_image" in *..*) php_darwin_die "invalid registry image: $registry_image" ;; esac
  registry_host=${registry_image%%/*}
  registry_repository=${registry_image#*/}
  registry_token_url="https://$registry_host/token"
  registry_token_args=(--retry 3 --retry-all-errors -fsSLG)
  registry_credential=${GHCR_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}
  [ -z "$registry_credential" ] || registry_token_args+=(-u "${GITHUB_ACTOR:-token}:$registry_credential")
  registry_token_response=$(curl "${registry_token_args[@]}" "$registry_token_url" \
    --data-urlencode "service=$registry_host" \
    --data-urlencode "scope=repository:$registry_repository:pull") || \
    php_darwin_die "could not get a registry token for $registry_image"
  registry_token=$(jq -er '.token // .access_token' <<< "$registry_token_response") || \
    php_darwin_die "registry token response was invalid for $registry_image"
}

registry_manifest() {
  manifest_tag=$1
  manifest_output=$2
  manifest_headers=$3
  [[ "$manifest_tag" =~ ^[A-Za-z0-9._-]+$ ]] || php_darwin_die "invalid OCI tag: $manifest_tag"
  curl --retry 3 --retry-all-errors -fsSL \
    -H "Authorization: Bearer $registry_token" \
    -H "Accept: $manifest_media_type" \
    -D "$manifest_headers" \
    "https://$registry_host/v2/$registry_repository/manifests/$manifest_tag" \
    -o "$manifest_output" || return 1

  jq -e --arg archive_media_type "$archive_media_type" --arg artifact_type "$artifact_type" \
    --arg media_type "$manifest_media_type" --argjson layer_count "$configured_layer_count" \
    '.schemaVersion == 2 and .mediaType == $media_type and .artifactType == $artifact_type and
     (.layers | type == "array" and length == $layer_count) and
     all(.layers[];
       .mediaType == $archive_media_type and
       (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
       (.size | type == "number" and . >= 0 and . == floor) and
       (.annotations["org.opencontainers.image.title"] | type == "string" and
        test("^php_[0-9]+\\.[0-9]+-(nts|zts)-(debug|release)\\+darwin_(arm64|x86_64)\\.tar\\.zst$"))) and
     ([.layers[].annotations["org.opencontainers.image.title"]] | unique | length) == $layer_count and
     any(.layers[]; .annotations["org.opencontainers.image.title"] | endswith("_arm64.tar.zst")) and
     any(.layers[]; .annotations["org.opencontainers.image.title"] | endswith("_x86_64.tar.zst"))' \
    "$manifest_output" >/dev/null || \
    php_darwin_die 'registry returned an invalid php-darwin OCI manifest'

  header_digest=$(awk 'tolower($1) == "docker-content-digest:" {gsub("\\r", "", $2); digest=$2} END {print digest}' "$manifest_headers") || \
    php_darwin_die 'could not read the registry manifest digest header'
  manifest_hash=$(php_darwin_sha256 "$manifest_output") || php_darwin_die 'could not hash the OCI manifest'
  manifest_digest="sha256:$manifest_hash"
  [ -z "$header_digest" ] || [[ "$header_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || \
    php_darwin_die 'registry returned an invalid manifest digest header'
  [ -z "$header_digest" ] || [ "$header_digest" = "$manifest_digest" ] || \
    php_darwin_die "registry manifest digest mismatch: expected $header_digest, got $manifest_digest"
}

registry_inspect() {
  inspect_image=$1
  inspect_tag=$2
  inspect_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-registry.XXXXXX")
  trap 'rm -rf "$inspect_dir"' EXIT
  registry_auth "$inspect_image"
  registry_manifest "$inspect_tag" "$inspect_dir/manifest.json" "$inspect_dir/headers" || return 1
  jq -n --arg digest "$manifest_digest" --slurpfile manifest "$inspect_dir/manifest.json" \
    '{digest:$digest,manifest:$manifest[0]}'
}

registry_inspect_many() {
  inspect_image=$1
  shift
  inspect_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-registry.XXXXXX")
  trap 'rm -rf "$inspect_dir"' EXIT
  inspect_jsonl="$inspect_dir/manifests.jsonl"
  : > "$inspect_jsonl"
  registry_auth "$inspect_image"
  inspect_index=0
  for inspect_tag in "$@"; do
    [[ "$inspect_tag" =~ ^[A-Za-z0-9._-]+$ ]] || php_darwin_die "invalid OCI tag: $inspect_tag"
    inspect_index=$((inspect_index + 1))
    registry_manifest "$inspect_tag" "$inspect_dir/manifest-$inspect_index.json" "$inspect_dir/headers-$inspect_index" || return 1
    jq -cn --arg tag "$inspect_tag" --arg digest "$manifest_digest" \
      --slurpfile manifest "$inspect_dir/manifest-$inspect_index.json" \
      '{key:$tag,value:{digest:$digest,manifest:$manifest[0]}}' >> "$inspect_jsonl" || \
      php_darwin_die "could not record OCI manifest $inspect_tag"
  done
  jq -s 'from_entries' "$inspect_jsonl" || php_darwin_die 'could not combine OCI manifests'
}

registry_pull() {
  pull_image=$1
  pull_tag=$2
  pull_asset=$3
  pull_output=$4
  pull_descriptor=$5
  pull_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/php-darwin-registry.XXXXXX")
  trap 'rm -rf "$pull_dir"' EXIT
  registry_auth "$pull_image"
  registry_manifest "$pull_tag" "$pull_dir/manifest.json" "$pull_dir/headers" || \
    php_darwin_die "could not fetch $pull_image:$pull_tag"

  jq -c --arg asset "$pull_asset" \
    '[.layers[] | select(.annotations["org.opencontainers.image.title"] == $asset)]' \
    "$pull_dir/manifest.json" > "$pull_dir/layers.json" || php_darwin_die 'could not parse OCI layers'
  [ "$(jq 'length' "$pull_dir/layers.json")" -eq 1 ] || \
    php_darwin_die "expected one $pull_asset layer in $pull_tag"
  layer_digest=$(jq -er '.[0].digest' "$pull_dir/layers.json") || php_darwin_die 'OCI layer digest is missing'
  layer_size=$(jq -er '.[0].size' "$pull_dir/layers.json") || php_darwin_die 'OCI layer size is missing'
  [[ "$layer_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || php_darwin_die 'OCI layer digest is invalid'
  [[ "$layer_size" =~ ^[0-9]+$ ]] || php_darwin_die 'OCI layer size is invalid'

  curl --retry 3 --retry-all-errors -fsSL \
    -H "Authorization: Bearer $registry_token" \
    "https://$registry_host/v2/$registry_repository/blobs/$layer_digest" \
    -o "$pull_output" || php_darwin_die "could not download $pull_asset"
  actual_hash=$(php_darwin_sha256 "$pull_output") || php_darwin_die 'could not hash the OCI archive layer'
  actual_digest="sha256:$actual_hash"
  [ "$actual_digest" = "$layer_digest" ] || \
    php_darwin_die "registry blob digest mismatch: expected $layer_digest, got $actual_digest"
  actual_size=$(wc -c < "$pull_output")
  actual_size=${actual_size//[[:space:]]/}
  [ "$actual_size" = "$layer_size" ] || \
    php_darwin_die "registry blob size mismatch: expected $layer_size, got $actual_size"

  jq --arg manifest_digest "$manifest_digest" \
    --slurpfile manifest "$pull_dir/manifest.json" \
    --slurpfile layers "$pull_dir/layers.json" \
    '.manifest_digest=$manifest_digest |
     .schema_version=$manifest[0].schemaVersion |
     .manifest_media_type=$manifest[0].mediaType |
     .artifact_type=$manifest[0].artifactType |
     .annotations=($manifest[0].annotations // {}) |
     .layer=$layers[0][0]' \
    "$script_dir/../templates/oci-descriptor.json" \
    > "$pull_descriptor" || php_darwin_die 'could not write the OCI descriptor'
}

case "${1:-}" in
  inspect)
    [ "$#" -eq 3 ] || php_darwin_die 'usage: registry.sh inspect IMAGE TAG'
    registry_inspect "$2" "$3"
    ;;
  inspect-many)
    [ "$#" -ge 4 ] || php_darwin_die 'usage: registry.sh inspect-many IMAGE TAG TAG [...]'
    registry_inspect_many "$2" "${@:3}"
    ;;
  pull)
    [ "$#" -eq 6 ] || php_darwin_die 'usage: registry.sh pull IMAGE TAG ASSET OUTPUT DESCRIPTOR'
    registry_pull "$2" "$3" "$4" "$5" "$6"
    ;;
  *) php_darwin_die 'usage: registry.sh inspect|inspect-many|pull ...' ;;
esac
