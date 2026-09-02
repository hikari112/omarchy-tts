import QtQuick
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "hikari.tts"

  property bool speaking: false
  property string provider: "piper"

  readonly property string speakBin: "$HOME/.local/bin/speak"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Long-lived status stream: `speak --watch-status` prints only on change.
  Process {
    id: statusWatcher
    command: ["bash", "-c", "exec " + root.speakBin + " --watch-status"]
    running: true
    stdout: SplitParser {
      onRead: function (line) {
        root.speaking = (line.trim() === "speaking")
      }
    }
  }

  Process {
    id: providerReader
    command: ["bash", "-c", "exec " + root.speakBin + " --current-provider"]
    running: true
    stdout: SplitParser {
      onRead: function (line) {
        if (line.trim() !== "") root.provider = line.trim()
      }
    }
  }

  Process { id: runner; running: false; command: [] }

  function run(args) {
    runner.running = false
    runner.command = ["bash", "-c", "exec " + root.speakBin + " " + args]
    runner.running = true
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    text: "󰕾"
    active: root.speaking
    tooltipText: root.speaking
      ? "Speaking — click to stop"
      : "Speak selection (" + root.provider + ")"

    // Gentle pulse so it reads as "busy" without stealing attention.
    opacity: root.speaking ? pulse.value : 1.0

    onPressed: function (btn) {
      if (btn === Qt.RightButton) {
        root.run("--cycle-provider")
        providerReader.running = false
        providerReader.running = true
      } else {
        root.run("--toggle")
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
