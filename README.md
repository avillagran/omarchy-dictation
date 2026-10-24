# Omarchy Dictation

Dictate into any app on [Omarchy](https://omarchy.org): press **Ctrl+Space**,
speak, and the text goes in where you are typing: terminals, browsers, GTK, Qt
and Electron apps. Speech is turned into text on this computer with
[whisper.cpp](https://github.com/ggml-org/whisper.cpp); no audio leaves it.

- **Hold** Ctrl+Space to talk and let go to insert, or **tap** it to start and
  tap again. **Esc** or the bubble's **✕** cancels.
- A bubble appears **at your text cursor** while the microphone is open: a red
  dot, the live level of your voice and the time, then *Transcribing…* and
  *Inserted* with the language it heard.
- A **microphone in the bar** turns red while you dictate; click it for the
  settings: on/off, the shortcut (click and press the new keys), the model,
  the language, a vocabulary, and paste or type.

## Install

```sh
git clone https://github.com/avillagran/omarchy-dictation ~/Work/omarchy-dictation
~/Work/omarchy-dictation/install.sh
```

`install.sh` builds the engine (Rust, CMake and a C++ compiler:
`sudo pacman -S --needed rust cmake base-devel`), links the plugin into
`~/.config/omarchy/plugins`, adds one line to `~/.config/hypr/bindings.lua`
(after a backup) and puts the microphone in the bar. The first dictation offers
to download the speech model: **Accurate** (264 MB, the default) or **Fast**
(82 MB). Models already downloaded by Omarchy T3 Code are used in place.
`uninstall.sh` removes it again; settings and models stay.

## How it works

- **Light at rest.** omarchy-shell runs the plugin's service: an IPC target
  (`omarchy-shell omarchy-dictation toggle|press|release|cancel|status`) and a
  watched settings file. The recorder and Whisper run only while you dictate;
  the bubble's window exists only while it shows.
- **At the text cursor.** Wayland tells only the input method where the cursor
  is. Omarchy's fcitx5 passes it to a KDE-style panel (its *kimpanel* addon), so
  a small `omarchy-dictate caret` process plays that panel and remembers the
  position. fcitx5 then shows no popups of its own, which matters only for input
  methods with candidate windows (Japanese, Chinese, Korean…): with any of those
  configured it stays off. Without a position the bubble appears at the mouse
  pointer. Turn it off in the settings.
- **Inserting.** By default it pastes the way Omarchy's universal paste does:
  the text goes on the clipboard marked sensitive (kept out of clipboard
  history), Hyprland sends Ctrl+V, or Shift+Insert to terminals, with explicit
  modifiers so a key still held from the shortcut cannot mix in, and the
  previous clipboard (text, an image or files, up to 16 MB) comes back. *Type*
  uses wtype instead and never touches the clipboard. Enter is never sent.
- **Where it goes.** The window focused when you started. If the focus moved
  by the time the text is ready, nothing is typed: it is copied to the
  clipboard and the bubble says so.
- **Esc** is bound in Hyprland only while it records, and never stays captured:
  the bind expires on its own, a press with nothing to cancel gives Esc back to
  the window, and a user's own plain Esc bind is left alone.
- **Omarchy T3 Code** has its own Ctrl+Space dictation in its composer; while
  it is focused, the key goes to it. Other apps can be listed under
  `passthrough` in the settings file.
- Not on the lock screen: the shortcut is not a locked bind.

Settings live in `~/.config/omarchy-dictation/settings.json`:

```json
{
  "enabled": true,
  "shortcut": "CTRL + SPACE",
  "passthrough": ["io.github.avillagran.omarchy-t3-code"],
  "model": "small",
  "language": "auto",
  "vocabulary": "Omarchy, Hyprland",
  "method": "paste",
  "restoreClipboard": true,
  "caret": true
}
```

## Development

- `tools/test-qml`: the service with stand-ins for the engine and the inserter
  (states, the bubble at the cursor or the pointer, push to talk, ✕, a muted
  microphone, the model download, a window that lost focus, settings).
- `tools/test-insert`: the inserter with stand-ins for hyprctl, wl-copy,
  wl-paste and wtype.
- `tools/test-bindings`: the Hyprland bindings with a stand-in Lua API.
- `tools/check-i18n`: every text translated in all 20 languages.
- `cargo test --release --manifest-path native/Cargo.toml`: the engine.

The engine is the dictation helper of
[Omarchy T3 Code](https://github.com/avillagran/omarchy-t3-code) (same
author), with the caret listener added.

## License

MIT
