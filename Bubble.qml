import QtQuick
import qs.Commons

// The dictation bubble, drawn by Service.qml next to the text cursor (or the
// mouse pointer). While it records: a beating red dot, the last two seconds of
// microphone level against the room's noise (flat = nothing heard, tall red
// bars = a voice) and the time. Then Transcribing…, Inserted with the
// detected language, or a notice. It never takes keyboard focus; clicks work.
Item {
  id: root
  objectName: "dictationBubble"
  // starting, recording, transcribing, inserting, notice or hidden.
  property string mode: "hidden"
  property var levels: []
  property real level: 0
  property int count: 28
  property bool muted: false
  // {kind: inserted|copied|error|model|downloading, text}
  property var notice: ({})
  property var tr: function(s, args) { return s }
  signal cancelRequested()
  signal unmuteRequested()
  signal downloadRequested()
  signal settingsRequested()
  signal dismissRequested()

  readonly property bool listening: mode === "starting" || mode === "recording"
  readonly property bool busy: mode === "transcribing" || mode === "inserting" || (mode === "notice" && notice.kind === "downloading")
  readonly property bool shown: mode !== "hidden"
  readonly property color red: Color.urgent
  readonly property color ink: Color.popups.text
  readonly property real floor: Math.min(0.5, levels.reduce(function(low, v) { return Math.min(low, v) }, 1))
  function bar(v) { return Math.max(0, Math.min(1, (v - floor) / Math.max(0.2, 0.85 - floor))) }
  function clamp(v) { return Math.max(0, Math.min(1, v)) }
  readonly property string message: mode === "transcribing" || mode === "inserting" ? tr("Transcribing…")
    : listening && muted ? tr("Microphone muted · click to turn it on")
    : mode === "notice" ? String(notice.text || "") : ""
  readonly property bool cancellable: listening || mode === "transcribing" || (mode === "notice" && (notice.kind === "model" || notice.kind === "downloading"))
  // Nerd Font glyphs, as Omarchy's OSD draws its icons.
  readonly property string glyph: notice.kind === "inserted" ? "\u{F012C}" : notice.kind === "copied" ? "\u{F018F}"
    : notice.kind === "error" ? "\u{F0026}" : notice.kind === "model" || notice.kind === "downloading" ? "\u{F01DA}" : "\u{F036C}"

  property real startedAt: 0
  property int seconds: 0
  onListeningChanged: if (listening && !startedAt) { startedAt = Date.now(); seconds = 0 } else if (!listening) startedAt = 0
  Timer { interval: 250; repeat: true; running: root.listening; onTriggered: root.seconds = Math.floor((Date.now() - root.startedAt) / 1000) }

  // It grows out of a dot at the cursor into the full width, with a small overshoot.
  property real grow: shown ? 1 : 0
  Behavior on grow { NumberAnimation { duration: root.shown ? 480 : 180; easing.type: root.shown ? Easing.OutBack : Easing.InCubic; easing.overshoot: 1.4 } }
  readonly property real tall: Style.space(38)
  readonly property real full: content.implicitWidth + Style.space(30)
  implicitWidth: full + Style.space(8)
  implicitHeight: tall + Style.space(8)
  visible: grow > 0.01

  Rectangle {
    anchors.fill: card; anchors.margins: -Style.space(4)
    radius: height / 2; opacity: card.opacity
    color: Qt.rgba(root.red.r, root.red.g, root.red.b, root.listening ? 0.05 + 0.16 * root.level : 0)
    Behavior on color { ColorAnimation { duration: 120 } }
  }
  Rectangle {
    id: card
    objectName: "dictationBubbleCard"
    readonly property real m: Math.max(0, (root.grow - 0.2) / 0.8)
    x: Style.space(4)
    width: root.tall + (root.full - root.tall) * m
    height: root.tall
    anchors.verticalCenter: parent.verticalCenter
    radius: height / 2
    opacity: root.clamp(m * 2.5)
    color: Util.alpha(Color.background, 0.97)
    border.width: Math.max(1, Style.space(2))
    border.color: root.listening ? Qt.rgba(root.red.r, root.red.g, root.red.b, 0.35 + 0.45 * root.level)
      : root.mode === "notice" && root.notice.kind === "error" ? root.red : Color.popups.border
    Behavior on border.color { ColorAnimation { duration: 120 } }
    clip: true
    MouseArea {
      anchors.fill: parent
      cursorShape: root.listening && root.muted || root.mode === "notice" ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: {
        if (root.listening && root.muted) root.unmuteRequested()
        else if (root.mode === "notice" && root.notice.kind === "model") root.downloadRequested()
        else if (root.mode === "notice" && root.notice.kind !== "downloading") root.dismissRequested()
      }
    }
    Row {
      id: content
      x: Style.space(14)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)
      opacity: root.clamp((card.m - 0.6) / 0.4)
      // The beating red dot of an open microphone.
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.listening
        width: Style.space(9); height: width; radius: width / 2; color: root.red
        SequentialAnimation on opacity {
          running: root.listening; loops: Animation.Infinite
          NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
          NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
        }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.listening
        text: root.busy ? "\u{F0453}" : root.glyph
        color: root.notice.kind === "error" && !root.busy ? root.red : root.notice.kind === "inserted" || root.busy ? Color.accent : root.ink
        font.family: Style.font.family; font.pixelSize: Style.font.iconLarge
        textFormat: Text.PlainText
        RotationAnimation on rotation { running: root.busy; from: 0; to: 360; duration: 900; loops: Animation.Infinite }
        onVisibleChanged: rotation = 0
      }
      Row {
        objectName: "dictationBubbleWave"
        anchors.verticalCenter: parent.verticalCenter
        visible: root.listening && !root.muted
        height: root.tall - Style.space(16); spacing: Style.space(2)
        Repeater {
          model: root.count
          Rectangle {
            readonly property int at: index - (root.count - root.levels.length)
            readonly property real value: at >= 0 ? root.bar(root.levels[at]) : 0
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(3); radius: width / 2
            height: Math.max(width, parent.height * value)
            color: Qt.rgba(root.red.r, root.red.g, root.red.b, 0.25 + 0.75 * value)
            Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
          }
        }
      }
      Text {
        objectName: "dictationBubbleText"
        anchors.verticalCenter: parent.verticalCenter
        visible: root.message !== ""
        text: root.message
        color: root.listening && root.muted || root.notice.kind === "error" && root.mode === "notice" ? root.red : root.ink
        font.family: Style.font.family; font.pixelSize: Style.font.subtitle
        textFormat: Text.PlainText; elide: Text.ElideRight; maximumLineCount: 1
        width: Math.min(implicitWidth, Style.space(420))
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.listening
        text: Math.floor(root.seconds / 60) + ":" + ("0" + root.seconds % 60).slice(-2)
        color: Util.alpha(root.ink, 0.7); font.family: Style.font.family; font.pixelSize: Style.font.subtitle; font.features: { "tnum": 1 }
        textFormat: Text.PlainText
      }
      // Model missing: the settings panel, instead of downloading here.
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.mode === "notice" && root.notice.kind === "model"
        text: root.tr("Settings"); color: Color.accent
        font.family: Style.font.family; font.pixelSize: Style.font.subtitle; font.underline: settingsArea.containsMouse
        textFormat: Text.PlainText
        MouseArea { id: settingsArea; anchors.fill: parent; anchors.margins: -Style.space(4); hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.settingsRequested() }
      }
      // ✕ cancels: nothing is inserted and the microphone closes.
      Rectangle {
        objectName: "dictationBubbleCancel"
        anchors.verticalCenter: parent.verticalCenter
        visible: root.cancellable
        width: Style.space(24); height: width; radius: width / 2
        color: cancelArea.containsMouse ? Util.alpha(root.ink, 0.12) : "transparent"
        Text { anchors.centerIn: parent; text: "\u{F0156}"; color: root.ink; font.family: Style.font.family; font.pixelSize: Style.font.title; textFormat: Text.PlainText }
        MouseArea { id: cancelArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.cancelRequested() }
      }
    }
  }
}
