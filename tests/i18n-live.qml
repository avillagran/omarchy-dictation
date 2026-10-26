import QtQuick
import Quickshell
import Quickshell.Io
import "UnderTest" as Test
ShellRoot {
  id: root
  property int phase: 0
  function check(ok, message) { if (!ok) { console.error("I18N_FAIL: " + message); Qt.exit(1) } }
  Test.Strings {
    id: strings
    languageOverride: ""
    environment: ({ LANG: "es_CL.UTF-8" })
    systemLocalePath: Quickshell.env("HOME") + "/locale.conf"
    catalog: ({ es: { Dictation: "Dictado" }, fr: { Dictation: "Dictée", Fallback: "Repli" } })
  }
  FileView { id: config; path: strings.systemLocalePath }
  Timer {
    interval: 80; repeat: true; running: true
    onTriggered: {
      if (root.phase === 0) {
        if (strings.locale !== "en-us") return
        root.check(strings.tr("Dictation") === "Dictation", "saved en_US wins over stale session es_CL")
        config.setText("LANG='fr_FR.UTF-8'\n"); root.phase = 1
      } else if (root.phase === 1) {
        if (strings.locale !== "fr-fr") return
        root.check(strings.tr("Dictation") === "Dictée", "live file change updates translation without restart")
        config.setText('LANG=en_US.UTF-8\nLANGUAGE="es_CL:fr:en"\n'); root.phase = 2
      } else if (root.phase === 2) {
        if (strings.locale !== "es-cl") return
        root.check(strings.tr("Dictation") === "Dictado" && strings.tr("Fallback") === "Repli", "saved LANGUAGE chain and regional fallback")
        strings.environment = { LANGUAGE: "en_US", LANG: "es_CL.UTF-8" }
        root.check(strings.tr("Dictation") === "Dictation", "explicit LANGUAGE remains authoritative")
        strings.environment = { LC_ALL: "de_DE.UTF-8", LANG: "es_CL.UTF-8" }
        config.setText('LANG="en_US.UTF-8"\n'); root.phase = 3
      } else if (root.phase === 3) {
        if (strings.systemEnvironment.LANGUAGE) return
        root.check(strings.locale === "de-de", "explicit LC_ALL precedes saved LANG")
        strings.language = "es"
        root.check(strings.tr("Dictation") === "Dictado", "explicit plugin language precedes system")
        root.check(!strings.parseLocaleConfig('LANG="$(touch bad)"\n').LANG, "locale config is parsed as data")
        root.check(Object.keys(strings.parseLocaleConfig("x".repeat(16385))).length === 0, "locale read is bounded")
        console.log("I18N_PASS: stale session, live changes, gettext precedence, fallback chain, bounded config")
        Qt.quit()
      }
    }
  }
}
