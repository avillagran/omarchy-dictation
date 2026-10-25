# Omarchy Dictation

Dictate into any app on [Omarchy](https://omarchy.org): press **Ctrl+Space**,
speak, and the text goes in where you are typing: terminals, browsers, GTK, Qt
and Electron apps. Speech is turned into text on this computer with
[whisper.cpp](https://github.com/ggml-org/whisper.cpp); no audio leaves it.

- **Hold** Ctrl+Space to talk and let go to insert, or **tap** it to start and
  tap again. **Esc** or the bubble's **✕** cancels.
- A bubble shows while the microphone is open, by the mouse pointer when it is
  over the window you dictate into (otherwise at the bottom of that window): a
  red dot, the live level of your voice and the time, then *Transcribing…* and
  *Inserted* with the language it heard.
- A **microphone in the bar** turns red while you dictate; click it for the
  settings: on/off, the shortcut (click and press the new keys), the model,
  the model (Fast, Accurate or Maximum), the language, a vocabulary, and paste
  or type.

## Install

```sh
omarchy plugin add https://github.com/avillagran/omarchy-dictation --enable
```

After updating an existing installation, **Set up** rebuilds the engine when
its version differs from the plugin. This update uses engine version 0.1.1.

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

## How it works

- **Nothing at rest.** omarchy-shell runs the plugin's service: an IPC target
  (`omarchy-shell omarchy-dictation toggle|press|release|cancel|status`) and
  the settings. No daemon, no model in memory: the recorder and Whisper run
  only while you dictate (the model loads while you speak), and the bubble's
  window exists only while it shows.
- **Why not at the text cursor.** On Hyprland only the compositor learns
  where an app's text cursor is (it uses it to place input-method popups);
  neither fcitx5 nor a plugin can ask for it, so the bubble follows the pointer
  or the window instead.
- **Long dictations.** Silence is trimmed and internal pauses shortened to 0.6 seconds.
  Speech is decoded in consecutive pieces of at most 25 seconds, with the
  detected language kept across pieces. Empty speech pieces get a beam-search
  retry. See [accuracy and resource measurements](docs/ACCURACY.md) for the
  six-language comparison, source audio, limitations and reproduction commands.
- **Languages.** Detected on every dictation. Chinese comes out in simplified
  characters with punctuation (traditional when the interface is zh-TW/HK/MO).
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
  "restoreClipboard": true
}
```

## Compared with Voxtype

Voxtype (which Omarchy binds when it is installed) also uses whisper.cpp, but as
a daemon that keeps its model loaded. Measured on an M2 Pro under Asahi, CPU
only, with the same recordings (Chilean Spanish from
[OpenSLR 71](https://www.openslr.org/71/), Mandarin from FLEURS):

| | At rest | While transcribing | 18–26 s of Chilean Spanish | 8–16 s of Mandarin |
|---|---|---|---|---|
| Omarchy Dictation, Accurate (small) | no process | ~565 MB | 1.5–1.9 s | 1.8–2.0 s |
| Omarchy Dictation, Fast (base) | no process | ~275 MB | 0.7 s | 0.6–0.8 s |
| Voxtype, large-v3 daemon | ~370 MB resident | ~1.8–1.9 GB | 90–133 s | 77–100 s |
| Voxtype, same small model | model resident | ~650 MB | 5.9–6.5 s | 6.1 s |

Times include loading the model; in a real dictation it loads while you speak.
Both detected every language correctly. Maximum (large-v3-turbo) wrote the
hardest Chilean sentences best at about 5–7 s for the same clips.

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
author).

## Interface language

The interface follows the system language, independently of the speech
recognition language. On shells with `qs.Commons.I18n`, it uses the shared
`omarchy-i18n` translator in this plugin's domain (system gettext and the
plugin's `i18n.json`). On older shells, the bundled catalog provides a
compatibility fallback: `LANGUAGE` > `LC_ALL` > `LC_MESSAGES` > `LANG`,
regional then base translations, and the ordered `LANGUAGE` chain per text,
ending at English. C/POSIX use the source text.

An explicit `uiLanguage` setting or `OMARCHY_DICTATION_LANGUAGE` environment
override uses the bundled catalog. System gettext and the shared startup
cache require a shell with `qs.Commons.I18n`.

## License

MIT
