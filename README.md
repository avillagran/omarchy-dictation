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
omarchy plugin add https://github.com/avillagran/omarchy-dictation --enable
```

Then click the microphone in the bar and press **Set up**. That runs
`bin/omarchy-dictation-configure`, which you can also run yourself:

1. builds the speech engine on this computer from `native/` (Rust with
   `Cargo.lock`, whisper.cpp inside it). It needs Rust, CMake and a C++
   compiler: the Arch packages `rust`, `cmake` and `base-devel`;
2. adds one `dofile(...)` line for `hypr/bindings.lua` to
   `~/.config/hypr/bindings.lua`, after saving a dated backup next to it;
3. enables the plugin and reloads Hyprland.

The first dictation then offers to download the speech model: **Accurate**
(264 MB, the default) or **Fast** (82 MB). Models already downloaded by Omarchy
T3 Code are used in place.

## Remove

```sh
~/.config/omarchy/plugins/io.github.avillagran.omarchy-dictation/bin/omarchy-dictation-remove
omarchy plugin remove io.github.avillagran.omarchy-dictation
```

The first command takes the line out of `bindings.lua`, takes the microphone
off the bar and reloads Hyprland. Settings and models stay until you delete
`~/.config/omarchy-dictation` and `~/.local/share/omarchy-dictation`.

## What it touches

- **Runs as your user only.** No root, no services, no daemons of its own.
- **Writes** `~/.config/omarchy-dictation/settings.json` (through
  `bin/omarchy-dictation-settings`: bounded, normalized, never through a
  symlink), models in `~/.local/share/omarchy-dictation/models`, the one line
  in `~/.config/hypr/bindings.lua`, and, only while a paste is in flight, the
  previous clipboard in `$XDG_RUNTIME_DIR/omarchy-dictation` (0700).
- **Downloads** the Rust crates pinned by `native/Cargo.lock` while building,
  and the model you choose from a pinned revision of
  [ggerganov/whisper.cpp on Hugging Face](https://huggingface.co/ggerganov/whisper.cpp),
  checked by size and SHA-256 before use. Nothing you say leaves the computer.
- **Keys**: the shortcut (Ctrl+Space by default), and plain Esc only while it
  records; neither works on the lock screen.
- **fcitx5**: while the plugin runs, `omarchy-dictate caret` serves fcitx5's
  KDE panel interface to learn where the text cursor is (see below).

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
- `tools/test-static`: what the marketplace reads (no privilege, installer
  names or shared temp dir; plain-text `Text`).
- `cargo test --release --manifest-path native/Cargo.toml`: the engine.

The engine is the dictation helper of
[Omarchy T3 Code](https://github.com/avillagran/omarchy-t3-code) (same
author), with the caret listener added.

## License

MIT
