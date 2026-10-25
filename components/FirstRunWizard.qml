import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Rectangle {
  id: root
  required property var controller
  property color foreground: Commons.Color.popups.text
  signal skipped
  width: parent ? parent.width : implicitWidth
  height: content.implicitHeight + Style.space(24)
  radius: Style.space(8)
  color: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.08)
  border.width: 1
  border.color: Commons.Color.popups.border

  readonly property bool busy: controller.setupStarting
                               || controller.setupJob.status === "starting"
                               || controller.setupJob.status === "running"

  Column {
    id: content
    anchors.fill: parent
    anchors.margins: Style.space(12)
    spacing: Style.space(10)

    Text {
      text: root.controller.setup.ready ? "Setup complete" : "Welcome to Text to Speech"
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
    }
    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      text: root.controller.setup.ready
        ? "The recommended local voice is ready. Text stays on this computer."
        : "Set up a natural local voice with one click. The engine and voice are kept inside the plugin’s data folder, and highlighted text never leaves this computer."
      color: Commons.Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
    Rectangle {
      width: parent.width
      height: 6
      radius: 3
      visible: root.busy
      color: Commons.Color.popups.border
      Rectangle {
        height: parent.height
        width: parent.width * Math.max(0.02, Math.min(1, root.controller.setupJob.progress / 100))
        radius: parent.radius
        color: Commons.Color.accent
      }
    }
    Text {
      width: parent.width
      visible: root.busy || root.controller.setupJob.status === "error"
      textFormat: Text.PlainText
      text: root.controller.setupStarting
            ? "Starting setup safely…"
            : (root.controller.setupJob.message || "Preparing setup")
      color: root.controller.setupJob.status === "error" ? Commons.Color.urgent : Commons.Color.muted
      wrapMode: Text.WordWrap
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    Row {
      spacing: Style.space(8)
      Button {
        text: root.controller.setup.ready ? "Continue" : (root.controller.setupJob.status === "error" ? "Try again" : "Set up local voice")
        iconText: root.controller.setup.ready ? "󰄬" : "󰐊"
        bordered: true; focusable: true
        foreground: Commons.Color.accent
        enabled: !root.busy
        onClicked: root.controller.setup.ready ? root.skipped() : root.controller.startSetup("recommended")
      }
      Button {
        visible: root.controller.setupCancellable
        text: "Cancel"
        bordered: true; focusable: true
        onClicked: root.controller.cancelSetup()
      }
      Button {
        visible: !root.busy && !root.controller.setup.ready
        text: "Choose another provider"
        bordered: true; focusable: true
        onClicked: root.skipped()
      }
    }
  }
}
