import QtQuick
import Quickshell
import Quickshell.Io

// The plugin's text in the user's language (i18n.json; English is the key).
// The catalog loads once `wanted` (the first dictation or the panel opening).
QtObject {
  id: root
  // "system" follows LANGUAGE/LC_ALL/LC_MESSAGES/LANG, or a locale code.
  property string language: "system"
  property bool wanted: false
  property var catalog: ({})
  readonly property string locale: {
    var raw = language && language !== "system" ? language
      : (Quickshell.env("OMARCHY_DICTATION_LANGUAGE") || Quickshell.env("LANGUAGE") || Quickshell.env("LC_ALL") || Quickshell.env("LC_MESSAGES") || Quickshell.env("LANG") || "en")
    var l = String(raw).split(":")[0].split(/[.@]/)[0].replace(/_/g, "-").toLowerCase()
    var base = l.split("-")[0]
    return base === "nb" || base === "nn" ? "no" : l
  }
  readonly property var strings: catalog[locale] || catalog[locale.split("-")[0]] || ({})
  function tr(source, args) {
    return String(strings[source] || source).replace(/\{([A-Za-z_][A-Za-z0-9_]*)\}/g, function(full, key) {
      return args && args[key] !== undefined ? String(args[key]) : full
    })
  }
  property FileView file: FileView {
    path: root.wanted ? Qt.resolvedUrl("i18n.json").toString().replace(/^file:\/\//, "") : ""
    printErrors: false
    onLoaded: { try { root.catalog = JSON.parse(text()) || ({}) } catch (_) { root.catalog = ({}) } }
  }
}
