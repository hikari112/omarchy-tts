import QtQuick
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
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

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

  // One long-lived stream owns both pieces of live bar state and emits only on
  // change. This avoids independent status/config pollers on every monitor.
  Process {
    command: [root.speakBin, "--watch-state"]
    running: true
    stdout: SplitParser {
      onRead: function (line) {
        try {
          var state = JSON.parse(line)
          root.speaking = state.status === "speaking"
          if (state.provider) root.provider = state.provider
        } catch (e) {}
      }
    }
  }

  Process { id: runner; running: false; command: [] }

  function run(args) {
    // Only the idempotent quick toggle uses this runner. Replacing an older
    // invocation is intentional; the CLI owns the provider transition.
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
      : "Text to speech (" + root.provider + ") — click for settings, right-click to speak selection"

    opacity: root.speaking ? pulse.value : 1.0

    onPressed: function (btn) {
      if (btn === Qt.RightButton) {
        // Quick action, so speaking never requires opening the panel first.
        root.run(["--toggle"])
      } else {
        root.toggle()
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
