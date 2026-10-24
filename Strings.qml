import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// The plugin's text in the user's language (i18n.json; English is the key).
// The catalog loads once `wanted` (the first dictation or the panel opening).
QtObject {
  id: root
  // "system" follows LANGUAGE/LC_ALL/LC_MESSAGES/LANG, or a locale code.
  property string language: "system"
  property bool wanted: false
  property var catalog: ({})
  // Newer shells register the plugin's i18n.json and own system gettext,
  // domain precedence and reactivity. Older shells have no I18n singleton.
  readonly property var shared: typeof I18n !== "undefined" ? I18n : null
  readonly property bool systemLanguage: !language || language === "system"
  readonly property var translator: shared && systemLanguage && !Quickshell.env("OMARCHY_DICTATION_LANGUAGE")
    ? shared.domain("io.github.avillagran.omarchy-dictation") : null
  // Compatibility with omarchy-i18n's I18nModel.localeCandidates: regional
  // then base, LANGUAGE order, stop at English, C/POSIX are source text.
  function localeCandidates(raw) {
    var result = []
    String(raw || "").split(":").forEach(function(value) {
      if (result.indexOf("en") !== -1) return
      var l = value.trim().split(/[.@]/)[0].replace(/-/g, "_")
      if (!l || l === "C" || l === "POSIX") return
      var parts = l.split("_"); var base = parts[0].toLowerCase(); var region = ""
      for (var i = 1; i < parts.length; i++) {
        if (/^[A-Za-z]{2}$/.test(parts[i]) || /^\d{3}$/.test(parts[i])) { region = parts[i].toLowerCase(); break }
      }
      var normalized = base + (region ? "-" + region : "")
      if (result.indexOf(normalized) === -1) result.push(normalized)
      if (result.indexOf(base) === -1) result.push(base)
    })
    return result
  }
  readonly property var candidates: localeCandidates(systemLanguage
    ? (Quickshell.env("OMARCHY_DICTATION_LANGUAGE") || Quickshell.env("LANGUAGE") || Quickshell.env("LC_ALL") || Quickshell.env("LC_MESSAGES") || Quickshell.env("LANG")) : language)
  readonly property string locale: candidates[0] || "en"
  function localText(source) {
    for (var i = 0; i < candidates.length; i++) {
      var key = candidates[i]; var base = key.split("-")[0]
      var entry = catalog[key] || catalog[key.replace(/-([a-z]{2})$/, function(_, region) { return "_" + region.toUpperCase() })]
      if (!entry && (base === "nb" || base === "nn")) entry = catalog.no
      if (entry && entry[source]) return entry[source]
    }
    return source
  }
  function tr(source, args) {
    return String(translator ? translator.tr(source) : localText(source)).replace(/\{([A-Za-z_][A-Za-z0-9_]*)\}/g, function(full, key) {
      return args && args[key] !== undefined ? String(args[key]) : full
    })
  }
  property FileView file: FileView {
    path: root.wanted ? Qt.resolvedUrl("i18n.json").toString().replace(/^file:\/\//, "") : ""
    printErrors: false
    onLoaded: { try { root.catalog = JSON.parse(text()) || ({}) } catch (_) { root.catalog = ({}) } }
  }
}
