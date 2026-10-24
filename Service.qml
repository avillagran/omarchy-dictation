import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

// Omarchy Dictation: press a shortcut (Ctrl+Space by default) in any app and
// speak; the text goes in where you were typing. omarchy-shell mounts this
// service at start. At rest it holds no window and no timer, only the IPC
// target and, when fcitx5 can tell, a small `omarchy-dictate caret` that
// remembers where the text cursor is. A dictation records with
// bin/omarchy-dictate (whisper.cpp, on this computer), shows a bubble next to
// the text cursor (or the mouse pointer) and inserts into the window that was
// focused when it started (bin/omarchy-dictation-insert).
//
//   omarchy-shell omarchy-dictation toggle|press|release|start|stop|cancel|status
Item {
  id: service
  visible: false
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string pluginId: "io.github.avillagran.omarchy-dictation"
  readonly property string pluginRoot: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string binary: Quickshell.env("OMARCHY_DICTATION_ENGINE") || pluginRoot + "/bin/omarchy-dictate"
  readonly property string inserter: Quickshell.env("OMARCHY_DICTATION_INSERT") || pluginRoot + "/bin/omarchy-dictation-insert"
  readonly property string escaper: Quickshell.env("OMARCHY_DICTATION_ESCAPE") || pluginRoot + "/bin/omarchy-dictation-escape"
  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy-dictation"

  // ------------------------------------------------------------ settings
  // ~/.config/omarchy-dictation/settings.json, written by the bar panel
  // (Panel.qml) and read by hypr/bindings.lua. Missing keys take these.
  readonly property var defaults: ({
    enabled: true, shortcut: "CTRL + SPACE",
    // Apps with their own Ctrl+Space dictation keep the key (Omarchy T3 Code's composer).
    passthrough: ["io.github.avillagran.omarchy-t3-code"],
    model: "", language: "auto", vocabulary: "", method: "paste", restoreClipboard: true,
    caret: true, uiLanguage: "system"
  })
  property var stored: ({})
  readonly property var settings: Object.assign({}, defaults, stored)
  FileView {
    id: settingsFile
    path: service.configDir + "/settings.json"
    watchChanges: true; printErrors: false; atomicWrites: true
    onLoaded: { try { var v = JSON.parse(text()); service.stored = v && typeof v === "object" ? v : ({}) } catch (_) { service.stored = ({}) } }
    onLoadFailed: service.stored = ({})
    onFileChanged: reload()
  }
  // Saves a change from the panel; a new shortcut reloads Hyprland's bindings.
  function save(patch) {
    var next = Object.assign({}, stored, patch)
    var keys = ["enabled", "shortcut", "passthrough"]
    var rebind = keys.some(function(k) { return JSON.stringify(settings[k]) !== JSON.stringify(Object.assign({}, defaults, next)[k]) })
    stored = next
    settingsFile.setText(JSON.stringify(next, null, 2) + "\n")
    if (rebind) reloadBindings.restart()
  }
  // The panel's first save needs the folder.
  Component.onCompleted: Quickshell.execDetached(["mkdir", "-p", configDir])
  Timer { id: reloadBindings; interval: 250; onTriggered: Quickshell.execDetached(["hyprctl", "reload", "config-only"]) }

  readonly property Strings strings: Strings { language: service.settings.uiLanguage }
  onPhaseChanged: if (phase !== "idle") strings.wanted = true
  function tr(source, args) { return strings.tr(source, args) }
  readonly property var languageNames: ({ es: "Español", en: "English", pt: "Português", fr: "Français", de: "Deutsch", it: "Italiano", nl: "Nederlands", pl: "Polski", ru: "Русский", uk: "Українська", ja: "日本語", ko: "한국어", zh: "中文", ar: "العربية", tr: "Türkçe", sv: "Svenska", da: "Dansk", no: "Norsk", fi: "Suomi", cs: "Čeština", ca: "Català" })
  function languageName(code) { return languageNames[code] || String(code || "").toUpperCase() }

  // --------------------------------------------------------------- state
  // idle, probing, session, inserting or notice.
  property string phase: "idle"
  property string intent: ""
  property var target: ({})
  property var anchor: null
  property var catalog: ({ loaded: false, models: [], default: "small", recorder: false })
  property int probes: 0
  property double pressedAt: 0
  property var notice: ({})
  property var download: ({ busy: false, model: "", bytes: 0, total: 0 })
  property string pendingText: ""
  property string language: ""
  readonly property string mode: phase === "session" ? (session.state === "cancelling" || session.state === "idle" ? "hidden" : session.state)
    : phase === "inserting" ? "inserting" : phase === "notice" ? "notice" : "hidden"
  readonly property bool listening: phase === "session" && (session.state === "starting" || session.state === "recording")
  readonly property alias session: session
  function refreshCatalog() { if (!catalogProcess.running) catalogProcess.running = true }

  // ----------------------------------------------------------- text cursor
  // fcitx5 reports the text cursor to `omarchy-dictate caret`; the bubble goes
  // there when it belongs to the window being dictated into.
  property var caret: ({})
  property string caretUnavailable: ""
  Process {
    id: caretProcess
    command: [service.binary, "caret"]
    running: service.settings.enabled === true && service.settings.caret !== false && !service.caretUnavailable
    stdout: SplitParser {
      onRead: function(line) {
        var e; try { e = JSON.parse(line) } catch (_) { return }
        if (e.type === "caret") service.caret = e
        else if (e.type === "unavailable") service.caretUnavailable = String(e.reason || "unavailable")
      }
    }
  }

  // ---------------------------------------------------------------- keys
  function toggle() {
    pressedAt = 0
    if (listening) { session.stop(); return "stopping" }
    if (phase === "session" || phase === "inserting" || phase === "probing") return phase
    return begin("toggle")
  }
  // Push to talk: held past ~450 ms it stops on release; a tap keeps
  // recording until the next press.
  function press() {
    if (listening) { pressedAt = 0; session.stop(); return "stopping" }
    if (phase === "session" || phase === "inserting" || phase === "probing") return phase
    pressedAt = Date.now()
    return begin("press")
  }
  function release() {
    if (!pressedAt) return "idle"
    var held = Date.now() - pressedAt > 450; pressedAt = 0
    if (held) { if (listening) session.stop(); else if (phase === "probing") intent = "cancel"; return "stopping" }
    return "recording"
  }
  function start() { pressedAt = 0; return listening ? "recording" : phase === "idle" || phase === "notice" ? begin("toggle") : phase }
  function stop() { pressedAt = 0; if (listening) session.stop(); return phase }
  function cancel() {
    pressedAt = 0
    if (phase === "session") { session.cancel(); return "cancelled" }
    if (phase === "probing") { intent = "cancel"; return "cancelled" }
    if (download.busy) { downloadProcess.signal(15); return "cancelled" }
    if (phase === "notice") { dismiss(); return "cancelled" }
    return "idle"
  }
  function status() {
    return JSON.stringify({ phase: phase, state: session.state, enabled: settings.enabled === true, notice: notice.kind || "",
      download: download.busy, caret: caretUnavailable ? caretUnavailable : caretProcess.running ? "listening" : "off",
      // Where the text cursor was last seen (no text), for diagnosis.
      lastCaret: caret.address ? { address: caret.address, x: caret.x, y: caret.y, h: caret.h } : null })
  }

  IpcHandler {
    target: "omarchy-dictation"
    function toggle(): string { return service.toggle() }
    function press(): string { return service.press() }
    function release(): string { return service.release() }
    function start(): string { return service.start() }
    function stop(): string { return service.stop() }
    function cancel(): string { return service.cancel() }
    // Esc while it records (bin/omarchy-dictation-escape); anything else gives Esc back.
    function escapeKey(): string { return service.phase === "session" || service.phase === "probing" || service.phase === "notice" ? service.cancel() : "idle" }
    function status(): string { return service.status() }
  }

  // ------------------------------------------------------------ starting
  // Where the text goes and which model: read now, not kept around at rest.
  function begin(how) {
    if (settings.enabled !== true) return "disabled"
    if (download.busy) return "downloading"
    if (phase === "notice") { noticeTimer.stop(); notice = ({}) }
    intent = how; phase = "probing"; probes = 2
    targetProcess.running = true; catalogProcess.running = true
    return "starting"
  }
  function probed() {
    if (phase !== "probing" || --probes > 0) return
    var how = intent; intent = ""
    if (how === "cancel") { phase = "idle"; return }
    anchor = placement()
    if (!catalog.loaded) { showNotice("error", tr("The dictation engine is not installed. Run the plugin's install.sh.")); return }
    if (!catalog.recorder) { showNotice("error", tr("Dictation needs PipeWire's pw-record to use the microphone.")); return }
    var id = settings.model || catalog.default, info = catalog.models.find(function(m) { return m.id === id })
    if (!info) { showNotice("error", tr("Dictation failed.")); return }
    if (!info.installed) { modelNotice(info); return }
    if (!target.address) { showNotice("error", tr("No window to dictate into.")); return }
    if (!session.start(id, settings.language || "auto", prompt())) { phase = "idle"; return }
    phase = "session"
    Quickshell.execDetached([escaper, "bind"])
  }
  // The text cursor of the target window, else the mouse pointer, else the
  // bottom of the screen.
  function placement() {
    if (caret.address && caret.address === target.address)
      return { x: Number(caret.x), y: Number(caret.y), h: Math.max(1, Number(caret.h) || 0), from: "caret" }
    var p = target.pointer || {}
    if (typeof p.x === "number" && typeof p.y === "number") return { x: p.x, y: p.y, h: Style.space(20), from: "pointer" }
    return null
  }
  // Names Whisper would otherwise misspell: the vocabulary and the window's
  // title as a hint. Everything stays on this computer.
  function prompt() {
    var words = [String(settings.vocabulary || "").trim(), String(target.title || "").slice(0, 100)].filter(function(w) { return !!w })
    return words.length ? words.join(", ").slice(0, 600) : ""
  }

  Process {
    id: targetProcess
    command: [service.inserter, "target"]
    stdout: StdioCollector { onStreamFinished: { try { service.target = JSON.parse(text) || ({}) } catch (_) { service.target = ({}) } } }
    onExited: service.probed()
  }
  Process {
    id: catalogProcess
    command: [service.binary, "models"]
    stdout: StdioCollector { onStreamFinished: { try { var c = JSON.parse(text); service.catalog = { loaded: true, models: c.models || [], default: c.default || "small", recorder: c.recorder === true } } catch (_) { service.catalog = ({ loaded: false, models: [], default: "small", recorder: false }) } } }
    onExited: service.probed()
  }

  // ------------------------------------------------------------- session
  Session {
    id: session
    binary: service.binary
    onFinished: function(text, language) {
      Quickshell.execDetached([service.escaper, "unbind"])
      if (!text.trim()) { service.phase = "idle"; return }
      service.language = language; service.pendingText = text; service.phase = "inserting"
      var args = [service.inserter, "insert", "--address", String(service.target.address || ""), "--method", service.settings.method === "type" ? "type" : "paste"]
      if (service.settings.restoreClipboard === false) args.push("--no-restore")
      insertProcess.command = args; insertProcess.stdinEnabled = true; insertProcess.running = true
    }
    onFailed: function(code) {
      Quickshell.execDetached([service.escaper, "unbind"])
      if (code === "model_missing") { var info = service.catalog.models.find(function(m) { return m.id === (service.settings.model || service.catalog.default) }); if (info) { service.modelNotice(info); return } }
      service.showNotice("error", service.tr({ model_invalid: "The dictation model could not be loaded. Remove it and download it again in the settings.", recorder_unavailable: "Dictation needs PipeWire's pw-record to use the microphone." }[code] || "Dictation failed."))
    }
    onCancelled: { Quickshell.execDetached([service.escaper, "unbind"]); service.phase = "idle" }
  }
  Process {
    id: insertProcess
    // The text goes over stdin, never argv, and is dropped once written.
    onStarted: { write(service.pendingText); service.pendingText = ""; stdinEnabled = false }
    stdout: StdioCollector { id: insertOutput }
    onExited: function(code) {
      var result = insertOutput.text.trim()
      if (result === "pasted" || result === "typed") service.showNotice("inserted", service.language ? service.tr("Inserted · {language}", { language: service.languageName(service.language) }) : service.tr("Inserted"), 1100)
      else if (result === "copied") service.showNotice("copied", service.tr("Dictation copied to the clipboard"), 2600)
      else if (result === "nothing") service.phase = "idle"
      else service.showNotice("error", service.tr("The dictated text could not be inserted."))
    }
  }

  // ------------------------------------------------------------- notices
  function showNotice(kind, text, ms) {
    notice = { kind: kind, text: text }; phase = "notice"
    noticeTimer.interval = ms || (kind === "model" ? 12000 : 4500); noticeTimer.restart()
  }
  function dismiss() { noticeTimer.stop(); notice = ({}); if (phase === "notice") phase = "idle" }
  Timer { id: noticeTimer; onTriggered: if (!service.download.busy) service.dismiss() }
  function modelNotice(info) {
    showNotice("model", tr("Download the dictation model ({size}), then dictate", { size: Math.round((info.sizeBytes || 0) / 1048576) + " MB" }))
    notice = Object.assign({}, notice, { model: info.id, sizeBytes: info.sizeBytes || 0 })
  }
  // From the bubble (model) or the panel (any model id).
  function startDownload(id) {
    var model = id || notice.model
    if (download.busy || !model) return
    var info = catalog.models.find(function(m) { return m.id === model }) || {}
    noticeTimer.stop()
    download = { busy: true, model: model, bytes: 0, total: info.sizeBytes || notice.sizeBytes || 0 }
    if (!id) notice = { kind: "downloading", text: tr("Downloading the dictation model… {percent}%", { percent: 0 }) }
    downloadProcess.command = [binary, "download", model]; downloadProcess.running = true
  }
  function cancelDownload() { if (downloadProcess.running) downloadProcess.signal(15) }
  function removeModel(id) { if (!download.busy && phase === "idle") { removeProcess.command = [binary, "remove", id]; removeProcess.running = true } }
  Process { id: removeProcess; onExited: service.refreshCatalog() }
  function openSettings() { dismiss(); Quickshell.execDetached(["omarchy-shell", "-q", pluginId, "open"]) }
  Process {
    id: downloadProcess
    stdout: SplitParser { onRead: function(line) { try { var e = JSON.parse(line); if (e.type === "progress") { service.download = Object.assign({}, service.download, { bytes: e.bytes, total: e.total }); if (service.notice.kind === "downloading") service.notice = { kind: "downloading", text: service.tr("Downloading the dictation model… {percent}%", { percent: Math.floor(100 * e.bytes / Math.max(1, e.total)) }) } } } catch (_) {} } }
    stderr: StdioCollector { id: downloadErrors }
    onExited: function(code) {
      var failure = downloadErrors.text.trim().split("\n").pop(), fromBubble = service.notice.kind === "downloading"
      service.download = { busy: false, model: "", bytes: 0, total: 0, error: code === 0 || code === 130 ? "" : failure || "download_failed" }
      service.refreshCatalog()
      if (!fromBubble) return
      if (code === 0) service.showNotice("inserted", service.tr("The dictation model is ready. Press the shortcut to dictate."), 3500)
      else if (code === 130) service.dismiss()
      else service.showNotice("error", service.tr(failure === "download_corrupt" ? "The download did not match the model's checksum and was removed." : "The model could not be downloaded."))
    }
  }

  // The microphone never stays open behind a shell restart, nor Esc bound.
  Component.onDestruction: { if (session.busy) session.cancel(); Quickshell.execDetached([escaper, "unbind"]) }

  // -------------------------------------------------------------- bubble
  // Created only while it shows, on the screen with the cursor, over
  // everything and without keyboard focus so the target window keeps it.
  readonly property var screen: {
    var a = anchor, list = Quickshell.screens
    if (a) for (var i = 0; i < list.length; i++) { var s = list[i]; if (a.x >= s.x && a.x < s.x + s.width && a.y >= s.y && a.y < s.y + s.height) return s }
    return list[0] || null
  }
  property bool bubbleWanted: mode !== "hidden"
  onBubbleWantedChanged: if (bubbleWanted) bubbleLinger.stop(); else bubbleLinger.restart()
  // Long enough for the bubble to fold away.
  Timer { id: bubbleLinger; interval: 240 }
  LazyLoader {
    id: bubbleLoader
    active: service.bubbleWanted || bubbleLinger.running
    PanelWindow {
      id: bubbleWindow
      objectName: "dictationWindow"
      screen: service.screen
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "omarchy-dictation"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      // Click-through everywhere but the bubble.
      mask: Region { item: bubble }
      Bubble {
        id: bubble
        readonly property var a: service.anchor
        readonly property real margin: Style.space(8)
        readonly property real sx: service.screen ? service.screen.x : 0
        readonly property real sy: service.screen ? service.screen.y : 0
        // Just under the cursor's line with the red dot at the cursor; above
        // it near the bottom of the screen; inside the screen always.
        x: a ? Math.max(margin, Math.min(bubbleWindow.width - width - margin, a.x - sx - Style.space(20))) : (bubbleWindow.width - width) / 2
        y: a ? (a.y - sy + a.h + Style.space(6) + height < bubbleWindow.height - margin ? a.y - sy + a.h + Style.space(6) : Math.max(margin, a.y - sy - height - Style.space(6)))
             : bubbleWindow.height - height - Style.space(67)
        width: implicitWidth; height: implicitHeight
        mode: service.mode
        levels: session.levels
        level: session.level
        count: session.waveLength
        muted: session.muted
        notice: service.notice
        tr: service.tr
        onCancelRequested: service.cancel()
        onUnmuteRequested: session.unmute()
        onDownloadRequested: service.startDownload("")
        onSettingsRequested: service.openSettings()
        onDismissRequested: service.dismiss()
      }
    }
  }
  readonly property var bubbleWindow: bubbleLoader.item
}
