import QtQuick
import qs.Commons

// The dictation bubble, drawn by Service.qml next to the mouse pointer (or at
// the bottom of the window). While it records: the microphone level against
// the room's noise (flat = nothing heard, tall = a voice) and the time. Then
// Transcribing…, Inserted with the detected language, or a notice. It never
// takes keyboard focus; clicks work. `design` picks one of ten looks, chosen
// in the panel; every one follows the theme's colours.
Item {
  id: root
  objectName: "dictationBubble"
  // starting, recording, transcribing, inserting, notice or hidden.
  property string mode: "hidden"
  property var levels: []
  property real level: 0
  property int count: 28
  property bool muted: false
  // {kind: inserted|copied|error|model|downloading|setup, text}
  property var notice: ({})
  property var tr: function(s, args) { return s }
  property string design: "classic"
  signal cancelRequested()
  signal unmuteRequested()
  signal downloadRequested()
  signal settingsRequested()
  signal dismissRequested()

  readonly property var designs: ["classic", "minimal", "equalizer", "line", "dots", "orb", "terminal", "accent", "ring", "meter"]
  readonly property string look: designs.indexOf(design) >= 0 ? design : "classic"
  readonly property bool listening: mode === "starting" || mode === "recording"
  readonly property bool busy: mode === "transcribing" || mode === "inserting" || (mode === "notice" && notice.kind === "downloading")
  readonly property bool shown: mode !== "hidden"
  // Accent is a card of the theme's accent colour, its marks in the background colour.
  readonly property bool filled: look === "accent"
  readonly property color red: Color.urgent
  readonly property color tone: filled ? Color.background : red
  readonly property color ink: filled ? Color.background : Color.popups.text
  readonly property color highlight: filled ? Color.background : Color.accent
  // Orb listens as a round card with only the beating core.
  readonly property bool round: look === "orb" && listening && !muted
  readonly property bool dot: listening && ["classic", "minimal", "equalizer", "line", "accent", "meter"].indexOf(look) >= 0
  readonly property real floor: Math.min(0.5, levels.reduce(function(low, v) { return Math.min(low, v) }, 1))
  function bar(v) { return Math.max(0, Math.min(1, (v - floor) / Math.max(0.2, 0.85 - floor))) }
  function clamp(v) { return Math.max(0, Math.min(1, v)) }
  // The i-th of the last n levels, 0 before there are enough.
  function sample(i, n) { var at = levels.length - n + i; return at >= 0 ? bar(levels[at]) : 0 }
  property real eased: listening ? bar(level) : 0
  Behavior on eased { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
  readonly property string message: mode === "transcribing" || mode === "inserting" ? tr("Transcribing…")
    : listening && muted ? tr("Microphone muted · click to turn it on")
    : mode === "notice" ? String(notice.text || "") : ""
  readonly property bool cancellable: listening || mode === "transcribing" || (mode === "notice" && (notice.kind === "model" || notice.kind === "downloading"))
  // Nerd Font glyphs, as Omarchy's OSD draws its icons.
  readonly property string glyph: notice.kind === "inserted" ? "\u{F012C}" : notice.kind === "copied" ? "\u{F018F}"
    : notice.kind === "error" ? "\u{F0026}" : notice.kind === "model" || notice.kind === "downloading" ? "\u{F01DA}" : notice.kind === "setup" ? "\u{F0493}" : "\u{F036C}"

  property real startedAt: 0
  property int seconds: 0
  onListeningChanged: if (listening && !startedAt) { startedAt = Date.now(); seconds = 0 } else if (!listening) startedAt = 0
  Timer { interval: 250; repeat: true; running: root.listening; onTriggered: root.seconds = Math.floor((Date.now() - root.startedAt) / 1000) }

  // It grows out of a dot at the cursor into the full width, with a small overshoot.
  property real grow: shown ? 1 : 0
  Behavior on grow { NumberAnimation { duration: root.shown ? 480 : 180; easing.type: root.shown ? Easing.OutBack : Easing.InCubic; easing.overshoot: 1.4 } }
  readonly property real tall: Style.space(look === "orb" ? 46 : 38)
  readonly property real full: round ? tall : content.implicitWidth + Style.space(30)
  implicitWidth: full + Style.space(8)
  implicitHeight: tall + Style.space(8)
  visible: grow > 0.01

  // A halo that brightens with the voice.
  Rectangle {
    anchors.fill: card; anchors.margins: -Style.space(root.round ? 2 + 6 * root.eased : 4)
    visible: root.look !== "terminal" && root.look !== "minimal"
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
    radius: root.look === "terminal" ? Math.min(Style.space(4), height / 2) : height / 2
    opacity: root.clamp(m * 2.5)
    color: root.filled ? Util.alpha(Color.accent, 0.97) : Util.alpha(Color.background, 0.97)
    border.width: Math.max(1, Style.space(2))
    border.color: root.look === "terminal" ? Util.alpha(root.listening ? Color.accent : Color.popups.border, root.listening ? 0.5 + 0.5 * root.eased : 1)
      : root.listening ? Qt.rgba(root.red.r, root.red.g, root.red.b, 0.35 + 0.45 * root.level)
      : root.mode === "notice" && root.notice.kind === "error" ? root.red : root.filled ? Util.alpha(Color.background, 0.3) : Color.popups.border
    Behavior on border.color { ColorAnimation { duration: 120 } }
    clip: true
    MouseArea {
      anchors.fill: parent
      cursorShape: root.listening && root.muted || root.mode === "notice" || root.round ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: {
        if (root.round) root.cancelRequested()
        else if (root.listening && root.muted) root.unmuteRequested()
        else if (root.mode === "notice" && root.notice.kind === "model") root.downloadRequested()
        else if (root.mode === "notice" && root.notice.kind === "setup") root.settingsRequested()
        else if (root.mode === "notice" && root.notice.kind !== "downloading") root.dismissRequested()
      }
    }
    Row {
      id: content
      x: root.round ? (card.width - implicitWidth) / 2 : Style.space(14)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)
      opacity: root.clamp((card.m - 0.6) / 0.4)
      // The beating dot of an open microphone; Minimal's also swells with the voice.
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.dot
        width: Style.space(9); height: width; radius: width / 2; color: root.tone
        scale: root.look === "minimal" ? 1 + 0.7 * root.eased : 1
        SequentialAnimation on opacity {
          running: root.dot; loops: Animation.Infinite
          NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
          NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
        }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.listening
        text: root.busy ? "\u{F0453}" : root.glyph
        color: root.notice.kind === "error" && !root.busy ? root.red : root.notice.kind === "inserted" || root.busy ? root.highlight : root.ink
        font.family: Style.font.family; font.pixelSize: Style.font.iconLarge
        textFormat: Text.PlainText
        RotationAnimation on rotation { running: root.busy; from: 0; to: 360; duration: 900; loops: Animation.Infinite }
        onVisibleChanged: rotation = 0
      }
      // What the microphone hears, drawn the design's way.
      Loader {
        objectName: "dictationBubbleWave"
        anchors.verticalCenter: parent.verticalCenter
        visible: root.listening && !root.muted && root.look !== "minimal"
        active: visible
        sourceComponent: ({ classic: wave, accent: wave, equalizer: equalizer, line: line, dots: dots, orb: orb, terminal: terminal, ring: ring, meter: meter })[root.look] || null
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
        visible: root.listening && !root.round
        text: Math.floor(root.seconds / 60) + ":" + ("0" + root.seconds % 60).slice(-2)
        color: root.look === "terminal" ? Color.accent : Util.alpha(root.ink, 0.7)
        font.family: Style.font.family; font.pixelSize: Style.font.subtitle; font.features: { "tnum": 1 }
        textFormat: Text.PlainText
      }
      // Model missing: the settings panel, instead of downloading here.
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.mode === "notice" && root.notice.kind === "model"
        text: root.tr("Settings"); color: root.highlight
        font.family: Style.font.family; font.pixelSize: Style.font.subtitle; font.underline: settingsArea.containsMouse
        textFormat: Text.PlainText
        MouseArea { id: settingsArea; anchors.fill: parent; anchors.margins: -Style.space(4); hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.settingsRequested() }
      }
      // ✕ cancels: nothing is inserted and the microphone closes. (Orb: a click on it.)
      Rectangle {
        objectName: "dictationBubbleCancel"
        anchors.verticalCenter: parent.verticalCenter
        visible: root.cancellable && !root.round
        width: Style.space(24); height: width; radius: root.look === "terminal" ? Style.space(3) : width / 2
        color: cancelArea.containsMouse ? Util.alpha(root.ink, 0.12) : "transparent"
        Text { anchors.centerIn: parent; text: "\u{F0156}"; color: root.ink; font.family: Style.font.family; font.pixelSize: Style.font.title; textFormat: Text.PlainText }
        MouseArea { id: cancelArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.cancelRequested() }
      }
    }
  }

  // ------------------------------------------------------------- designs
  readonly property real markHeight: Style.space(22)
  // Classic and Accent: the last two seconds as bars around the middle.
  Component {
    id: wave
    Row {
      height: root.markHeight; spacing: Style.space(2)
      Repeater {
        model: root.count
        Rectangle {
          readonly property real value: root.sample(index, root.count)
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(3); radius: width / 2
          height: Math.max(width, parent.height * value)
          color: Qt.rgba(root.tone.r, root.tone.g, root.tone.b, 0.25 + 0.75 * value)
          Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
        }
      }
    }
  }
  // Equalizer: one second as wide bars standing on a line, accent turning red when loud.
  Component {
    id: equalizer
    Row {
      height: root.markHeight; spacing: Style.space(3)
      Repeater {
        model: 14
        Rectangle {
          readonly property real value: root.sample(index, 14)
          anchors.bottom: parent.bottom
          width: Style.space(5); radius: Style.space(1)
          height: Math.max(Style.space(2), parent.height * value)
          color: Qt.tint(Color.accent, Qt.rgba(root.red.r, root.red.g, root.red.b, value))
          Behavior on height { NumberAnimation { duration: 110; easing.type: Easing.OutQuad } }
        }
      }
    }
  }
  // Line: the last two seconds as a soft oscillating trace.
  Component {
    id: line
    Canvas {
      width: Style.space(140); height: root.markHeight
      readonly property var values: root.levels
      onValuesChanged: requestPaint()
      onPaint: {
        var c = getContext("2d"); c.reset()
        var n = root.count, mid = height / 2, step = width / (n - 1)
        var y = function(i) { return mid + (i % 2 ? 1 : -1) * root.sample(i, n) * (mid - 1.5) }
        c.lineWidth = Math.max(1.5, Style.space(2)); c.lineJoin = "round"; c.lineCap = "round"
        c.strokeStyle = root.tone
        c.beginPath(); c.moveTo(0, y(0))
        for (var i = 1; i < n; i++) c.quadraticCurveTo((i - 0.5) * step, y(i - 1), i * step - step / 2, (y(i - 1) + y(i)) / 2)
        c.lineTo(width, y(n - 1)); c.stroke()
      }
    }
  }
  // Dots: five dots, the newest on the right, that swell with each syllable.
  Component {
    id: dots
    Row {
      height: root.markHeight; spacing: Style.space(6)
      Repeater {
        model: 5
        Rectangle {
          readonly property real value: Math.max(root.sample(index * 2, 10), root.sample(index * 2 + 1, 10))
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(7) + Style.space(9) * value; height: width; radius: width / 2
          color: Qt.rgba(root.red.r, root.red.g, root.red.b, 0.35 + 0.65 * value)
          Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutBack } }
        }
      }
    }
  }
  // Orb: a round card whose core beats with the voice.
  Component {
    id: orb
    Item {
      width: Style.space(26); height: width
      Rectangle {
        anchors.centerIn: parent
        width: parent.width * (1 + 0.6 * root.eased); height: width; radius: width / 2
        color: Qt.rgba(root.red.r, root.red.g, root.red.b, 0.18)
      }
      Rectangle {
        anchors.centerIn: parent
        width: parent.width * (0.55 + 0.3 * root.eased); height: width; radius: width / 2
        color: root.red
      }
    }
  }
  // Terminal: REC and the level in block characters.
  Component {
    id: terminal
    Row {
      spacing: Style.space(8)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "● REC"; color: root.red
        font.family: Style.font.family; font.pixelSize: Style.font.subtitle; font.bold: true
        textFormat: Text.PlainText
        SequentialAnimation on opacity {
          running: true; loops: Animation.Infinite
          NumberAnimation { to: 0.45; duration: 530; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 1; duration: 530; easing.type: Easing.InOutQuad }
        }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        readonly property string blocks: "▁▂▃▄▅▆▇█"
        text: { var s = ""; for (var i = 0; i < 14; i++) s += blocks.charAt(Math.min(7, Math.floor(root.sample(i, 14) * 8))); return s }
        color: Color.accent; font.family: Style.font.family; font.pixelSize: Style.font.subtitle
        textFormat: Text.PlainText
      }
    }
  }
  // Ring: the microphone inside a ring that fills with the voice.
  Component {
    id: ring
    Item {
      width: Style.space(28); height: width
      Canvas {
        id: arc
        anchors.fill: parent
        readonly property real value: root.eased
        onValueChanged: requestPaint()
        onPaint: {
          var c = getContext("2d"); c.reset()
          var w = Math.max(2, Style.space(3)), r = width / 2 - w / 2
          c.lineWidth = w; c.lineCap = "round"
          c.strokeStyle = Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.15)
          c.beginPath(); c.arc(width / 2, height / 2, r, 0, 2 * Math.PI); c.stroke()
          c.strokeStyle = root.red
          c.beginPath(); c.arc(width / 2, height / 2, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * Math.max(0.04, value)); c.stroke()
        }
      }
      Text {
        anchors.centerIn: parent
        text: "\u{F036C}"; color: root.red
        font.family: Style.font.family; font.pixelSize: Style.font.subtitle
        textFormat: Text.PlainText
      }
    }
  }
  // Meter: a level bar with a peak mark that falls slowly.
  Component {
    id: meter
    Item {
      id: track
      width: Style.space(150); height: Style.space(8)
      property real peak: 0
      Timer { interval: 70; repeat: true; running: true; onTriggered: track.peak = Math.max(root.eased, track.peak - 0.025) }
      Rectangle { anchors.fill: parent; radius: height / 2; color: Util.alpha(root.ink, 0.12) }
      Rectangle {
        width: Math.max(height, parent.width * root.eased); height: parent.height; radius: height / 2
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0; color: Color.accent }
          GradientStop { position: 1; color: root.red }
        }
      }
      Rectangle {
        x: Math.max(0, Math.min(parent.width - width, parent.width * track.peak - width / 2))
        width: Style.space(3); height: parent.height + Style.space(6); radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: root.ink; opacity: 0.8
      }
    }
  }
}
