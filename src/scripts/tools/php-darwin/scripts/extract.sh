#!/usr/bin/env bash

archive=${1:?}
prefix=${2:?}
exclude_file=${3:?}

[ -f "$archive" ] || {
  printf 'Archive not found: %s\n' "$archive" >&2
  exit 1
}
[ -d "$prefix" ] || {
  printf 'Extraction prefix not found: %s\n' "$prefix" >&2
  exit 1
}
[ -f "$exclude_file" ] || {
  printf 'Extraction exclusion list not found: %s\n' "$exclude_file" >&2
  exit 1
}

zstd -dc "$archive" | tar -xmpf - --no-same-owner -X "$exclude_file" -C "$prefix"
pipeline_status=("${PIPESTATUS[@]}")
[ "${pipeline_status[0]}" -eq 0 ] && [ "${pipeline_status[1]}" -eq 0 ]
