import QtQuick
import qs.Commons

// The same Bubble used by dictation, with simulated audio and no microphone.
// Unload the simulation when the panel closes; selecting a design starts its
// recording preview immediately rather than leaving it in the shared notice.
Item {
  id: root
  property bool active: false
  property string design: "classic"
  property var tr: function(source, args) { return source }
  property string noticeText: ""
  implicitHeight: active ? Style.space(60) : 0
  onDesignChanged: if (simulation && simulation.item) simulation.item.restart()

  Loader {
    id: simulation
    anchors.fill: parent
    active: root.active
    sourceComponent: Item {
      id: demo
      objectName: "dictationPreviewDemo"
      property real t: 0
      property var levels: [0.18, 0.4, 0.7, 0.35, 0.55]
      property real level: 0.55
      readonly property real phase: t % 9
      function restart() {
        t = 0
        levels = [0.18, 0.4, 0.7, 0.35, 0.55]
        level = 0.55
        sample.startedAt = Date.now()
        sample.seconds = 0
      }
      Timer {
        interval: 70; repeat: true; running: true
        onTriggered: {
          var voice = Math.max(0, Math.sin(demo.t * 1.3)) * Math.abs(Math.sin(demo.t * 4.1 + Math.sin(demo.t * 1.7)))
          demo.t += 0.07
          demo.level = 0.12 + 0.75 * voice + 0.04 * Math.random()
          demo.levels = demo.levels.concat([demo.level]).slice(-28)
        }
      }
      Bubble {
        id: sample
        objectName: "dictationPreviewBubble"
        anchors.centerIn: parent
        width: implicitWidth; height: implicitHeight
        design: root.design
        mode: demo.phase < 6 ? "recording" : demo.phase < 7.3 ? "transcribing" : "notice"
        levels: demo.levels
        level: demo.level
        notice: ({ kind: "inserted", text: root.noticeText })
        tr: root.tr
      }
    }
  }
}
