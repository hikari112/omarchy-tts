import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.hikari112.tts"

  property bool speaking: false
  property string provider: "piper"

  readonly property string speakBin: String(Qt.resolvedUrl("bin/speak")).replace("file://", "")

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The bar host injects `bar` and `settings` into the widget, not into the
  // panel it loads, so they have to be handed down by hand.
  function injectPanel() {
    var p = panelLoader.item
    if (!p) return
    if ("bar" in p) p.bar = root.bar
    if ("settings" in p) p.settings = root.settings
    if ("anchorItem" in p) p.anchorItem = button
    if ("hostWidget" in p) p.hostWidget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // Shape the bar expects when routing summon/hide to a widget's panel.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // Long-lived status stream: `speak --watch-status` prints only on change.
  Process {
    command: [root.speakBin, "--watch-status"]
    running: true
    stdout: SplitParser {
      onRead: function (line) { root.speaking = (line.trim() === "speaking") }
    }
  }

  Process {
    id: providerReader
    command: [root.speakBin, "--current-provider"]
    running: true
    stdout: SplitParser {
      onRead: function (line) { if (line.trim() !== "") root.provider = line.trim() }
    }
  }

  Process { id: runner; running: false; command: [] }

  function run(args) {
    runner.running = false
    runner.command = [root.speakBin].concat(args)
    runner.running = true
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    text: "󰕾"
    active: root.speaking
    tooltipText: root.speaking
      ? "Speaking — right-click to stop"
      : "Text to speech (" + root.provider + ") — click for settings"

    opacity: root.speaking ? pulse.value : 1.0

    onPressed: function (btn) {
      if (btn === Qt.RightButton) {
        // Quick action, so speaking never requires opening the panel first.
        root.run(["--toggle"])
      } else {
        root.togglePanel()
      }
    }
  }

  QtObject {
    id: pulse
    property real value: 1.0
  }

  SequentialAnimation {
    running: root.speaking
    loops: Animation.Infinite
    alwaysRunToEnd: true
    NumberAnimation { target: pulse; property: "value"; from: 1.0; to: 0.45; duration: 700; easing.type: Easing.InOutQuad }
    NumberAnimation { target: pulse; property: "value"; from: 0.45; to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
    onStopped: pulse.value = 1.0
  }
}
