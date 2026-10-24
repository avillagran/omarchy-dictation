import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui

// The bar's microphone: red while it records; a click opens the settings.
// Everything is saved to ~/.config/omarchy-dictation/settings.json through
// the service (Service.qml), which applies it at once.
Panel {
  id: root
  moduleName: "io.github.avillagran.omarchy-dictation"
  ipcTarget: "io.github.avillagran.omarchy-dictation"

  // The service of this same plugin, mounted by omarchy-shell.
  readonly property var shellRef: bar && bar.shell ? bar.shell : null
  readonly property var service: shellRef && typeof shellRef.serviceFor === "function" ? shellRef.serviceFor(moduleName) : null
  readonly property var s: service ? service.settings : ({})
  readonly property var catalog: service ? service.catalog : ({ loaded: false, models: [] })
  readonly property var download: service ? service.download : ({ busy: false })
  readonly property string modelId: s.model || catalog.default || "small"
  readonly property var modelInfo: (catalog.models || []).find(function(m) { return m.id === root.modelId }) || null
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool recording: !!service && service.listening
  function tr(text, args) { return service ? service.tr(text, args) : text }
  function save(patch) { if (service) service.save(patch) }
  // "CTRL + SPACE" → "Ctrl+Space"
  function keysLabel(keys) {
    return String(keys || "").split(" + ").map(function(k) { return k === "SUPER" ? "Super" : k === "CTRL" ? "Ctrl" : k === "ALT" ? "Alt" : k === "SHIFT" ? "Shift" : k.length > 1 ? k.charAt(0) + k.slice(1).toLowerCase() : k }).join("+")
  }
  function validKeys(v) { return /^((SUPER|CTRL|ALT|SHIFT) \+ ){0,4}[A-Z0-9_]{1,16}$/.test(v) && !/(^|\+ )(SUPER|CTRL|ALT|SHIFT)$/.test(v) }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onOpenedChanged: if (opened && service) { service.strings.wanted = true; service.refreshCatalog() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: s.enabled === false ? "\u{F036D}" : "\u{F036C}"
    active: root.recording
    dimmed: s.enabled === false
    tooltipText: root.tr("Dictation") + " · " + root.keysLabel(s.shortcut)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton && root.service) root.service.toggle()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: capture.active
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: root.tr("Dictation")
            meta: !root.service ? root.tr("Restart the shell to finish installing.")
              : root.recording ? root.tr("Listening…")
              : root.s.enabled === false ? root.tr("Off")
              : root.tr("Press {keys} in any app and speak", { keys: root.keysLabel(root.s.shortcut) })
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text { text: "\u{F036C}"; color: root.recording ? Color.urgent : root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.display; textFormat: Text.PlainText }
            }
            trailingControl: Component {
              ToggleSwitch {
                objectName: "dictationEnabled"
                checked: root.s.enabled !== false
                foreground: hero.foreground
                onToggled: root.save({ enabled: !checked })
              }
            }
          }

          Text {
            width: parent.width
            text: root.tr("Speech becomes text on this computer with whisper.cpp; no audio leaves it. The microphone is open only while the bubble shows.")
            color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap; textFormat: Text.PlainText
          }

          PanelSeparator { foreground: root.foreground }

          // ------------------------------------------------------ shortcut
          Column {
            width: parent.width
            spacing: Style.space(8)
            PanelSectionHeader { text: root.tr("Shortcut").toUpperCase(); foreground: root.foreground; fontFamily: root.fontFamily }
            Row {
              width: parent.width
              spacing: Style.space(8)
              // Click, then press the keys; Hyprland's form also types in.
              Rectangle {
                id: capture
                objectName: "dictationShortcut"
                property bool active: false
                width: parent.width - resetButton.width - parent.spacing
                height: Style.spacing.controlHeight
                radius: Style.cornerRadius
                color: "transparent"
                border.width: Style.normalBorderWidth
                border.color: active ? Color.accent : Util.alpha(root.foreground, captureArea.containsMouse ? 0.5 : 0.25)
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  x: Style.spacing.controlPaddingX
                  text: capture.active ? root.tr("Press the new keys… (Esc keeps the current ones)") : root.keysLabel(root.s.shortcut)
                  color: capture.active ? root.dim : root.foreground
                  font.family: root.fontFamily; font.pixelSize: Style.font.body; textFormat: Text.PlainText
                }
                MouseArea { id: captureArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { capture.active = true; capture.forceActiveFocus() } }
                Keys.onPressed: function(event) {
                  if (!capture.active) return
                  event.accepted = true
                  if (event.key === Qt.Key_Escape) { capture.active = false; keyCatcher.forceActiveFocus(); return }
                  var name = event.key >= Qt.Key_A && event.key <= Qt.Key_Z ? String.fromCharCode(event.key)
                    : event.key >= Qt.Key_0 && event.key <= Qt.Key_9 ? String.fromCharCode(event.key)
                    : event.key >= Qt.Key_F1 && event.key <= Qt.Key_F24 ? "F" + (event.key - Qt.Key_F1 + 1)
                    : event.key === Qt.Key_Space ? "SPACE" : ""
                  if (!name) return
                  var mods = []
                  if (event.modifiers & Qt.MetaModifier) mods.push("SUPER")
                  if (event.modifiers & Qt.ControlModifier) mods.push("CTRL")
                  if (event.modifiers & Qt.AltModifier) mods.push("ALT")
                  if (event.modifiers & Qt.ShiftModifier) mods.push("SHIFT")
                  // A plain letter or space would stop you typing it.
                  if (!mods.length && name.charAt(0) !== "F") return
                  var keys = mods.concat([name]).join(" + ")
                  if (root.validKeys(keys)) root.save({ shortcut: keys })
                  capture.active = false; keyCatcher.forceActiveFocus()
                }
                onActiveFocusChanged: if (!activeFocus) active = false
              }
              PanelActionButton {
                id: resetButton
                iconText: "\u{F0450}"
                tooltipText: root.tr("Back to Ctrl+Space")
                foreground: root.foreground
                anchors.verticalCenter: parent.verticalCenter
                visible: root.s.shortcut !== "CTRL + SPACE"
                onClicked: root.save({ shortcut: "CTRL + SPACE" })
              }
            }
            Text {
              width: parent.width
              text: root.tr("Hold to talk, or tap to start and tap again. Esc or ✕ cancels. Omarchy T3 Code keeps Ctrl+Space for its own dictation.")
              color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap; textFormat: Text.PlainText
            }
          }

          PanelSeparator { foreground: root.foreground }

          // --------------------------------------------------------- model
          Column {
            width: parent.width
            spacing: Style.space(8)
            PanelSectionHeader { text: root.tr("Speech").toUpperCase(); foreground: root.foreground; fontFamily: root.fontFamily }
            Dropdown {
              objectName: "dictationModel"
              width: parent.width
              label: root.tr("Model")
              value: root.modelId
              fontFamily: root.fontFamily
              options: (root.catalog.models || []).map(function(m) { return { value: m.id, label: root.tr(m.id === "base" ? "Fast" : "Accurate") + " · " + Math.round(m.sizeBytes / 1048576) + " MB" + (m.installed ? " ✓" : "") } })
              onChanged: function(value) { root.save({ model: value }) }
            }
            Row {
              spacing: Style.space(10)
              visible: !!root.modelInfo
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.download.busy ? root.tr("Downloading… {percent}%", { percent: Math.floor(100 * (root.download.bytes || 0) / Math.max(1, root.download.total || 0)) })
                  : root.modelInfo && root.modelInfo.installed ? (root.modelInfo.shared ? root.tr("Downloaded (shared with Omarchy T3 Code)") : root.tr("Downloaded"))
                  : root.tr("Not downloaded yet")
                color: root.download.error ? Color.urgent : root.dim
                font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; textFormat: Text.PlainText
              }
              Text {
                objectName: "dictationModelAction"
                anchors.verticalCenter: parent.verticalCenter
                readonly property string action: root.download.busy ? "cancel" : !root.modelInfo || !root.modelInfo.installed ? "download" : root.modelInfo.shared ? "" : "remove"
                visible: action !== ""
                text: root.tr(action === "cancel" ? "Cancel" : action === "download" ? "Download" : "Remove")
                color: Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.underline: actionArea.containsMouse
                textFormat: Text.PlainText
                MouseArea {
                  id: actionArea; anchors.fill: parent; anchors.margins: -Style.space(4); hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                  onClicked: parent.action === "cancel" ? root.service.cancelDownload() : parent.action === "download" ? root.service.startDownload(root.modelId) : root.service.removeModel(root.modelId)
                }
              }
            }
            Dropdown {
              objectName: "dictationLanguage"
              width: parent.width
              label: root.tr("Language")
              value: root.s.language || "auto"
              fontFamily: root.fontFamily
              options: [{ value: "auto", label: root.tr("Automatic") }, { value: "es", label: "Español" }, { value: "en", label: "English" }, { value: "pt", label: "Português" }, { value: "fr", label: "Français" }, { value: "de", label: "Deutsch" }, { value: "it", label: "Italiano" }]
              onChanged: function(value) { root.save({ language: value }) }
            }
            Text {
              width: parent.width
              text: root.tr("Automatic detects each dictation's language. A fixed one helps very short phrases, but speech in another language is then translated into it.")
              color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap; textFormat: Text.PlainText
            }
            TextField {
              id: vocabulary
              objectName: "dictationVocabulary"
              width: parent.width
              foreground: root.foreground
              placeholderText: root.tr("Vocabulary: Omarchy, Hyprland, names…")
              text: root.s.vocabulary || ""
              maximumLength: 600
              onEditingFinished: { var v = text.replace(/[\r\n]+/g, " ").trim(); if (v !== (root.s.vocabulary || "")) root.save({ vocabulary: v }) }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ----------------------------------------------------- inserting
          Column {
            width: parent.width
            spacing: Style.space(10)
            PanelSectionHeader { text: root.tr("Inserting").toUpperCase(); foreground: root.foreground; fontFamily: root.fontFamily }
            ButtonGroup {
              objectName: "dictationMethod"
              width: parent.width
              value: root.s.method === "type" ? "type" : "paste"
              foreground: root.foreground
              fontFamily: root.fontFamily
              options: [{ value: "paste", label: root.tr("Paste") }, { value: "type", label: root.tr("Type") }]
              onChanged: function(value) { root.save({ method: value }) }
            }
            Text {
              width: parent.width
              text: root.s.method === "type" ? root.tr("Types with wtype; never touches the clipboard, but is slower.")
                : root.tr("Pastes like Omarchy's universal paste (Shift+Insert in terminals) and puts the clipboard back afterwards.")
              color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap; textFormat: Text.PlainText
            }
            SettingSwitch {
              objectName: "dictationRestore"
              visible: root.s.method !== "type"
              label: root.tr("Restore the clipboard")
              checked: root.s.restoreClipboard !== false
              onToggled: root.save({ restoreClipboard: !checked })
            }
            SettingSwitch {
              objectName: "dictationCaret"
              label: root.tr("Bubble at the text cursor")
              detail: root.service && root.service.caretUnavailable === "input_method" ? root.tr("Not with input methods that show candidates; it appears at the mouse pointer.")
                : root.service && root.service.caretUnavailable === "no_fcitx5" ? root.tr("Needs fcitx5; it appears at the mouse pointer.")
                : root.tr("fcitx5 tells where you type; otherwise it appears at the mouse pointer.")
              checked: root.s.caret !== false
              onToggled: root.save({ caret: !checked })
            }
          }
        }
      }
    }
  }

  component SettingSwitch: Item {
    id: row
    property string label: ""
    property string detail: ""
    property bool checked: false
    signal toggled()
    width: parent ? parent.width : 0
    implicitHeight: Math.max(toggle.implicitHeight, texts.implicitHeight)
    Column {
      id: texts
      anchors.left: parent.left; anchors.right: toggle.left; anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
      Text { width: parent.width; text: row.label; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; wrapMode: Text.WordWrap; textFormat: Text.PlainText }
      Text { width: parent.width; visible: row.detail !== ""; text: row.detail; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap; textFormat: Text.PlainText }
    }
    ToggleSwitch {
      id: toggle
      anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      checked: row.checked
      foreground: root.foreground
      onToggled: row.toggled()
    }
  }
}
