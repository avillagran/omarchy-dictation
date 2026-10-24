import QtQuick
import Quickshell
import Quickshell.Io

// One run of `bin/omarchy-dictate listen` for Service.qml. JSON lines on
// stdout; SIGINT transcribes, SIGTERM cancels, and the helper dies with
// omarchy-shell. Never keeps the text after `finished`.
Item {
  id: root
  visible: false
  property string binary: ""
  // idle, starting, recording, transcribing or cancelling.
  property string state: "idle"
  property real level: 0
  property var levels: []
  property bool muted: false
  // The last ~2 s of microphone levels (one every 70 ms).
  readonly property int waveLength: 28
  readonly property bool busy: state !== "idle"
  signal finished(string text, string language)
  signal failed(string code)
  signal cancelled()

  function start(model, language, prompt, chinese) {
    if (state !== "idle" || process.running) return false
    var args = [binary, "listen", "--model", model, "--language", language || "auto"]
    if (prompt) args.push("--prompt", prompt)
    if (chinese) args.push("--chinese", chinese)
    output.result = null
    state = "starting"; level = 0; levels = []; muted = false
    process.command = args; process.running = true
    return true
  }
  function stop() { if (process.running && (state === "starting" || state === "recording")) { state = "transcribing"; level = 0; process.signal(2) } }
  function cancel() { if (process.running && state !== "cancelling") { state = "cancelling"; level = 0; process.signal(15) } }
  // A muted source records only zeros; the bubble offers this.
  function unmute() { if (state === "recording" && !unmuteProcess.running) { unmuteProcess.running = true; muted = false } }

  function line(text) {
    var event; try { event = JSON.parse(text) } catch (_) { return }
    if (event.type === "recording" && state === "starting") { state = "recording"; muted = event.muted === true }
    else if (event.type === "level" && state === "recording") {
      var value = Number(event.value) || 0
      level = value; muted = muted && value <= 0
      levels = levels.concat([value]).slice(-waveLength)
    } else if (event.type === "text") output.result = event
  }

  Process { id: unmuteProcess; command: ["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "0"] }
  Process {
    id: process
    stdout: SplitParser { id: output; property var result: null; onRead: function(data) { root.line(data) } }
    stderr: StdioCollector { id: errors }
    onExited: function(code) {
      var was = root.state, result = output.result, failure = errors.text.trim().split("\n").pop()
      output.result = null
      root.state = "idle"; root.level = 0; root.levels = []; root.muted = false
      if (was === "cancelling" || code === 130) root.cancelled()
      else if (code !== 0) root.failed(failure || "failed")
      else root.finished(result && result.text ? String(result.text) : "", result && result.language ? String(result.language) : "")
    }
  }
}
