#!/usr/bin/env bash
# Install Omarchy Dictation: build the engine, link the plugin into Omarchy,
# add the shortcut to Hyprland and put the microphone in the bar. Run it again
# to update; uninstall.sh undoes it (models are kept).
set -euo pipefail
fail() { printf 'omarchy-dictation: %s\n' "$*" >&2; exit 1; }
[[ $EUID -ne 0 ]] || fail 'Run as your desktop user, not root.'
command -v omarchy-shell >/dev/null || fail 'The Omarchy shell must be installed and running.'
command -v hyprctl >/dev/null || fail 'Hyprland is required.'
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
id=io.github.avillagran.omarchy-dictation

# The engine: whisper.cpp through Rust, built once for this computer.
if [[ ! -x $here/bin/omarchy-dictate || ${OMARCHY_DICTATION_REBUILD:-0} == 1 ]]; then
  command -v cargo >/dev/null && command -v cmake >/dev/null && command -v c++ >/dev/null \
    || fail 'Building the engine needs Rust, CMake and a C++ compiler: sudo pacman -S --needed rust cmake base-devel'
  if [[ ${OMARCHY_DICTATION_PORTABLE:-0} == 1 ]]; then
    # Release builds: every CPU of the architecture, not only this one.
    export GGML_NATIVE=OFF
    case $(uname -m) in
      aarch64) export GGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16 ;;
      x86_64) export GGML_AVX=ON GGML_AVX2=ON GGML_FMA=ON GGML_F16C=ON ;;
    esac
  fi
  cargo build --release --locked --manifest-path "$here/native/Cargo.toml"
  install -m755 "$here/native/target/release/omarchy-dictate" "$here/bin/omarchy-dictate"
fi

# The plugin, linked where Omarchy looks for plugins.
plugins=$HOME/.config/omarchy/plugins
link=$plugins/$id
mkdir -p -- "$plugins"
if [[ $(readlink -f -- "$link" 2>/dev/null) != "$here" ]]; then
  [[ ! -e $link || -L $link ]] || fail "$link exists and is not this checkout; remove it first."
  ln -sfn -- "$here" "$link"
fi

# The shortcut: one dofile line in ~/.config/hypr/bindings.lua, written to a
# temporary file and moved into place (never appended through a symlink).
bindings=$HOME/.config/hypr/bindings.lua
line="dofile(\"$link/hypr/bindings.lua\")"
if [[ -f $bindings && ! -L $bindings ]]; then
  if ! grep -qF -- "$id/hypr/bindings.lua" "$bindings"; then
    cp -p -- "$bindings" "$bindings.dictation-backup-$(date +%Y%m%d%H%M%S)"
    tmp=$(mktemp "$(dirname -- "$bindings")/.dictation.XXXXXX")
    { cat -- "$bindings"; printf '\n-- Omarchy Dictation: Ctrl+Space (change it from the microphone in the bar).\n%s\n' "$line"; } > "$tmp"
    chmod --reference="$bindings" "$tmp"
    mv -f -- "$tmp" "$bindings"
  fi
else
  printf 'Add this line to your Hyprland Lua bindings to get the shortcut:\n  %s\n' "$line"
fi

# The microphone in the bar enables the plugin (and with it the service).
omarchy-shell -q shell rescanPlugins
if command -v omarchy >/dev/null; then omarchy plugin enable "$id" >/dev/null || true; fi
hyprctl reload config-only >/dev/null
errors=$(hyprctl configerrors)
[[ -z ${errors//[[:space:]]/} ]] || fail "Hyprland configuration errors: $errors"
printf '%s\n' 'Installed. Press Ctrl+Space in any app and speak; the microphone in the bar has the settings.' \
  'The first dictation offers to download the speech model (264 MB, or 82 MB for Fast).'
