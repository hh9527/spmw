#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: scripts/make-dist.sh dev [<target-dir>]" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

mode="$1"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"

case "$mode" in
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
if [[ ! -f "$repo_root/config.spmw.json" ]]; then
  echo "missing source config: $repo_root/config.spmw.json" >&2
  exit 1
fi
if [[ ! -f "$repo_root/bootstrap.ps1" ]]; then
  echo "missing bootstrap script: $repo_root/bootstrap.ps1" >&2
  exit 1
fi

mkdir -p "$target_dir"

tmp_dev_dir="$target_dir/.tmp.dev"
tmp_tarball="$tmp_dev_dir/spmw.tar.gz"
tmp_config_dir="$target_dir/.tmp.spmw-config"
tmp_payload_dir="$tmp_config_dir/spmw-dev"
rm -rf "$tmp_dev_dir"
rm -rf "$tmp_config_dir"

mkdir -p "$tmp_dev_dir"
mkdir -p "$tmp_payload_dir"
cp "$repo_root/config.spmw.json" "$tmp_payload_dir/config.spmw.json"
cp -R "$repo_root/bin" "$tmp_payload_dir/bin"
tar -czf "$tmp_tarball" -C "$tmp_config_dir" spmw-dev
rm -rf "$tmp_config_dir"
sha="$(sha256sum "$tmp_tarball" | awk '{ print $1 }')"
short_sha="${sha:0:16}"
printf '%s\n' "$sha" > "$tmp_dev_dir/spmw.tar.gz.sha256"

case "$mode" in
  dev)
    final_dir="$target_dir/$short_sha"
    channel_dir="$target_dir/channels"
    rm -rf "$final_dir"
    mv "$tmp_dev_dir" "$final_dir"
    mkdir -p "$channel_dir"
    cp "$repo_root/bootstrap.ps1" "$target_dir/bootstrap.ps1"
    printf '../%s/spmw.tar.gz\n' "$short_sha" > "$channel_dir/dev.txt"
    echo "wrote $final_dir/spmw.tar.gz"
    echo "wrote $final_dir/spmw.tar.gz.sha256"
    echo "wrote $target_dir/bootstrap.ps1"
    echo "wrote $channel_dir/dev.txt"
    ;;
esac
