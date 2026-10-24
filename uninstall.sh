#!/usr/bin/env bash
# Remove Omarchy Dictation from Omarchy: the shortcut line, the bar entry and
# the plugin link. Settings and downloaded models stay (delete
# ~/.config/omarchy-dictation and ~/.local/share/omarchy-dictation to drop them).
set -euo pipefail
id=io.github.avillagran.omarchy-dictation
bindings=$HOME/.config/hypr/bindings.lua
if [[ -f $bindings && ! -L $bindings ]] && grep -qF -- "$id/hypr/bindings.lua" "$bindings"; then
  tmp=$(mktemp "$(dirname -- "$bindings")/.dictation.XXXXXX")
  grep -vF -e "$id/hypr/bindings.lua" -e '-- Omarchy Dictation: Ctrl+Space' -- "$bindings" > "$tmp" || true
  chmod --reference="$bindings" "$tmp"
  mv -f -- "$tmp" "$bindings"
fi
if command -v omarchy >/dev/null; then omarchy plugin disable "$id" >/dev/null 2>&1 || true; fi
link=$HOME/.config/omarchy/plugins/$id
[[ ! -L $link ]] || rm -f -- "$link"
omarchy-shell -q shell rescanPlugins
hyprctl reload config-only >/dev/null
printf '%s\n' 'Omarchy Dictation removed.'
