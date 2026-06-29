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
    target_dir="${2:-$repo_root/dev-dist}"
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
if [[ ! -d "$repo_root/source" ]]; then
  echo "missing source directory: $repo_root/source" >&2
  exit 1
fi
if [[ ! -f "$repo_root/bootstrap.ps1" ]]; then
  echo "missing bootstrap script: $repo_root/bootstrap.ps1" >&2
  exit 1
fi

mkdir -p "$target_dir"

tmp_tarball="$target_dir/.tmp.spmw.tar.gz"
tmp_config_dir="$target_dir/.tmp.spmw-config"
rm -f "$tmp_tarball"
rm -f "$target_dir/spmw-source.tar.gz" "$target_dir/spmw-source.tar.gz.sha256"
rm -rf "$tmp_config_dir"

mkdir -p "$tmp_config_dir"
cp "$repo_root/source/config.spmw.json" "$tmp_config_dir/config.spmw.json"
if [[ "$mode" == "dev" ]]; then
  sed -i \
    -e 's#https://github.com/hh9527/spmw/releases/download/latest/VERSION.txt#http://127.0.0.1:10922/spmw/latest/VERSION.txt#' \
    -e 's#https://github.com/hh9527/spmw/releases/download/#http://127.0.0.1:10922/spmw/#g' \
    "$tmp_config_dir/config.spmw.json"
fi
tar -czf "$tmp_tarball" -C "$tmp_config_dir" config.spmw.json -C "$repo_root" bin
rm -rf "$tmp_config_dir"
sha="$(sha256sum "$tmp_tarball" | awk '{ print $1 }')"
printf '%s\n' "$sha" > "$target_dir/spmw.tar.gz.sha256"

case "$mode" in
  release)
    mv "$tmp_tarball" "$target_dir/spmw.tar.gz"
    version="${GITHUB_REF_NAME:-}"
    if [[ -z "$version" ]]; then
      version="$(git -C "$repo_root" describe --tags --exact-match 2>/dev/null || true)"
    fi
    if [[ -z "$version" ]]; then
      echo "missing version: set GITHUB_REF_NAME or run on a git tag" >&2
      exit 1
    fi
    printf '%s\n' "$version" > "$target_dir/VERSION.txt"
    cp "$repo_root/bootstrap.ps1" "$target_dir/bootstrap.ps1"
    echo "wrote $target_dir/spmw.tar.gz"
    echo "wrote $target_dir/spmw.tar.gz.sha256"
    echo "wrote $target_dir/VERSION.txt"
    echo "wrote $target_dir/bootstrap.ps1"
    ;;
  dev)
    version="unrelease-${sha:0:9}"
    latest_dir="$target_dir/latest"
    version_dir="$target_dir/$version"
    spmw_dir="$target_dir/spmw"
    rm -rf "$latest_dir" "$version_dir" "$spmw_dir"
    rm -f "$target_dir/bootstrap.ps1"
    find "$target_dir" -maxdepth 1 -type l -name 'unrelease-*' -delete
    mkdir -p "$latest_dir"
    mv "$tmp_tarball" "$latest_dir/spmw.tar.gz"
    mv "$target_dir/spmw.tar.gz.sha256" "$latest_dir/spmw.tar.gz.sha256"
    printf '%s\n' "$version" > "$latest_dir/VERSION.txt"
    cp "$repo_root/bootstrap.ps1" "$latest_dir/bootstrap.ps1"
    ln -s latest "$version_dir"
    ln -s . "$spmw_dir"
    echo "wrote $latest_dir/spmw.tar.gz"
    echo "wrote $latest_dir/spmw.tar.gz.sha256"
    echo "wrote $latest_dir/VERSION.txt"
    echo "wrote $latest_dir/bootstrap.ps1"
    echo "linked $version_dir -> latest"
    echo "linked $spmw_dir -> ."
    ;;
esac
