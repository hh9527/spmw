#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
target_dir="$repo_root/target"
windows_config="$script_dir/links/windows-config"
dev_config_tpl="$script_dir/dev-config.spmw.json.txt"
config_tpl="$script_dir/config.spmw.json.txt"
bootstrap_tpl="$script_dir/bootstrap.ps1"

if [[ ! -d "$windows_config" ]]; then
  echo "missing windows config directory: $windows_config" >&2
  exit 1
fi

if [[ ! -d "$repo_root/bin" ]]; then
  echo "missing bin directory: $repo_root/bin" >&2
  exit 1
fi

if [[ ! -f "$dev_config_tpl" ]]; then
  echo "missing dev config template: $dev_config_tpl" >&2
  exit 1
fi

if [[ ! -f "$config_tpl" ]]; then
  echo "missing config template: $config_tpl" >&2
  exit 1
fi

if [[ ! -f "$bootstrap_tpl" ]]; then
  echo "missing bootstrap template: $bootstrap_tpl" >&2
  exit 1
fi

mkdir -p "$target_dir"

pack_tarball() {
  local source_dir="$1"
  local name="$2"
  shift 2

  local tmp_tarball="$target_dir/.tmp.$name.tar.gz"
  local sha_file="$target_dir/$name.sha256.txt"

  rm -f "$tmp_tarball" "$sha_file"
  rm -f "$target_dir/$name.sha256" "$target_dir/$name.tar.gz" "$target_dir/$name.tar.gz.sha256"
  rm -f "$target_dir/$name-"*.tar.gz

  tar -C "$source_dir" -czf "$tmp_tarball" --exclude='./.git' "$@"
  local sha
  sha="$(sha256sum "$tmp_tarball" | awk '{ print $1 }')"
  local tarball="$target_dir/$name-$sha.tar.gz"

  printf '%s\n' "$sha" > "$sha_file"
  mv "$tmp_tarball" "$tarball"

  echo "wrote $tarball"
  echo "wrote $sha_file"
}

pack_tarball "$windows_config" "windows-config" .
pack_tarball "$repo_root" "spmw" bin

dev_config_tpl_target="$target_dir/dev-config.spmw.json.txt"
config_tpl_target="$target_dir/config.spmw.json.txt"
rm -f "$target_dir/.config.spmw.json"
rm -f "$target_dir/local-config.spmw.json.txt" "$target_dir/local-config.spmw.json.tpl"
cp "$dev_config_tpl" "$dev_config_tpl_target"
echo "wrote $dev_config_tpl_target"
cp "$config_tpl" "$config_tpl_target"
echo "wrote $config_tpl_target"

bootstrap="$target_dir/bootstrap.ps1"
cp "$bootstrap_tpl" "$bootstrap"
echo "wrote $bootstrap"
