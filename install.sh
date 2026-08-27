#!/usr/bin/env bash
# Install (or reinstall) the F1 Live plugin into the Omarchy shell.
#
#   ./install.sh              copy the plugin into ~/.config/omarchy/plugins
#   ./install.sh --link       symlink it instead, for development
#   ./install.sh --remove     uninstall, and delete the cache and state it wrote
#   ./install.sh --keep-data  with --remove, leave the cache and state in place
#
# Adding it to the bar is a separate, reversible step:
#   omarchy plugin enable nocram.f1
#   omarchy bar move nocram.f1 --section right

set -euo pipefail

id="nocram.f1"
source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$id"
# Everything the plugin writes outside its own directory, so uninstalling can
# put the machine back exactly as it found it.
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/f1"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/f1"
mode="copy"
keep_data="no"

for arg in "$@"; do
  case "$arg" in
  --link) mode="link" ;;
  --remove) mode="remove" ;;
  --keep-data) keep_data="yes" ;;
  -h | --help)
    sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    exit 0
    ;;
  *)
    echo "unknown option: $arg" >&2
    exit 1
    ;;
  esac
done

rescan() {
  if command -v omarchy-shell >/dev/null 2>&1 && omarchy-shell shell ping >/dev/null 2>&1; then
    omarchy-shell shell rescanPlugins >/dev/null
    echo "shell rescanned"
  else
    echo "shell not running — it will pick the plugin up on next start"
  fi
}

if [[ $mode == remove ]]; then
  rm -rf "$target_dir"
  echo "removed $target_dir"
  if [[ $keep_data == yes ]]; then
    echo "kept $cache_dir and $state_dir"
  else
    for dir in "$cache_dir" "$state_dir"; do
      if [[ -d $dir ]]; then
        rm -rf "$dir"
        echo "removed $dir"
      fi
    done
  fi
  rescan
  exit 0
fi

mkdir -p "$(dirname "$target_dir")"
rm -rf "$target_dir"

if [[ $mode == link ]]; then
  ln -s "$source_dir" "$target_dir"
  echo "linked $target_dir -> $source_dir"
else
  mkdir -p "$target_dir"
  # Ship only what the shell loads: the manifest, the QML, the JS modules, and
  # the circuit maps the panel renders.
  cp "$source_dir/manifest.json" "$target_dir/"
  cp "$source_dir"/*.qml "$target_dir/"
  cp "$source_dir"/*.js "$target_dir/"
  cp -r "$source_dir/circuits" "$target_dir/"
  echo "installed $target_dir"
fi

rescan

cat <<EOF

Next:
  omarchy plugin enable $id        # add it to the bar
  omarchy bar move $id --section right
EOF
