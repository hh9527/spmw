#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: scripts/make-dist.sh release|dev [<target-dir>]" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

mode="$1"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"

case "$mode" in
  release)
    target_dir="${2:-$repo_root/dist}"
    ;;
  dev)
    target_dir="${2:-$repo_root/target}"
    ;;
  *)
    usage
    exit 2
    ;;
esac

if [[ ! -d "$repo_root/bin" ]]; then
  echo "missing bin directory: $repo_root/bin" >&2
  exit 1
fi

mkdir -p "$target_dir"

tmp_tarball="$target_dir/.tmp.tarball.tar.gz"
rm -f "$tmp_tarball"

tar -C "$repo_root" -czf "$tmp_tarball" bin
sha="$(sha256sum "$tmp_tarball" | awk '{ print $1 }')"
printf '%s\n' "$sha" > "$target_dir/sha256.txt"

case "$mode" in
  release)
    mv "$tmp_tarball" "$target_dir/tarball.tar.gz"
    version="${GITHUB_REF_NAME:-}"
    if [[ -z "$version" ]]; then
      version="$(git -C "$repo_root" describe --tags --exact-match 2>/dev/null || true)"
    fi
    if [[ -z "$version" ]]; then
      echo "missing version: set GITHUB_REF_NAME or run on a git tag" >&2
      exit 1
    fi
    printf '%s\n' "$version" > "$target_dir/VERSION.txt"
    echo "wrote $target_dir/tarball.tar.gz"
    echo "wrote $target_dir/sha256.txt"
    echo "wrote $target_dir/VERSION.txt"
    ;;
  dev)
    tarball="$target_dir/tarball.$sha.tar.gz"
    rm -f "$target_dir"/tarball.*.tar.gz
    mv "$tmp_tarball" "$tarball"
    echo "wrote $tarball"
    echo "wrote $target_dir/sha256.txt"
    ;;
esac
