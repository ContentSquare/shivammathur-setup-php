#!/usr/bin/env bash

prefix=${1:?}
output=${2:?}
roots_file=${3:?}
path_list="$output.paths.$$"
trap 'rm -f "$path_list"' EXIT

[ -d "$prefix" ] || {
  printf 'Missing Homebrew prefix: %s\n' "$prefix" >&2
  exit 1
}
[ -f "$roots_file" ] || {
  printf 'Missing archive roots: %s\n' "$roots_file" >&2
  exit 1
}

: > "$output" || exit 1
while IFS= read -r managed_dir extra; do
  [ -n "$managed_dir" ] || continue
  case "$managed_dir" in \#*) continue ;; esac
  [ -z "$extra" ] || {
    printf 'Invalid archive root: %s %s\n' "$managed_dir" "$extra" >&2
    exit 1
  }
  case "$managed_dir" in Cellar|etc|opt|var) ;; *)
    printf 'Unsafe archive root: %s\n' "$managed_dir" >&2
    exit 1
    ;;
  esac
  if [ "$managed_dir" = Cellar ]; then
    # One exclusion per existing keg protects its complete subtree and keeps
    # the pattern file small even on runner images with hundreds of formulae.
    find "$prefix/Cellar" -mindepth 2 -maxdepth 2 -print0 > "$path_list" || exit 1
  else
    find "$prefix/$managed_dir" ! -type d -print0 > "$path_list" || exit 1
  fi
  while IFS= read -r -d '' existing_path; do
    relative_path=${existing_path#"$prefix"/}
    case "$relative_path" in *$'\n'*|*$'\r'*)
      printf 'Unsupported Homebrew path: %s\n' "$relative_path" >&2
      exit 1
      ;;
    esac
    tar_pattern=${relative_path//\\/\\\\}
    tar_pattern=${tar_pattern//\[/\\[}
    tar_pattern=${tar_pattern//\]/\\]}
    tar_pattern=${tar_pattern//\*/\\*}
    tar_pattern=${tar_pattern//\?/\\?}
    printf '%s\n' "$tar_pattern" >> "$output" || exit 1
  done < "$path_list"
done < "$roots_file"
