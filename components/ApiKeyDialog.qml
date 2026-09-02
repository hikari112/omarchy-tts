import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

Rectangle {
  id: root
  required property var controller
  property string provider: ""
  property string vendor: provider
  property color foreground: Color.popups.text
  signal closed
  width: parent ? parent.width : implicitWidth
  height: content.implicitHeight + Style.space(24)
  radius: Style.space(8)
  color: Color.background
  border.width: 1
  border.color: Color.accent

  Column {
    id: content
    anchors.fill: parent
    anchors.margins: Style.space(12)
    spacing: Style.space(8)
    Text { text: "Add " + root.vendor + " API key"; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.subtitle }
    Text {
      width: parent.width; wrapMode: Text.WordWrap
      text: "The key is saved in the system keyring and is never written to settings or logs. Highlighted text and test samples will be sent to " + root.vendor + " and may incur charges."
      color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption
    }
    TextField {
      id: keyField
      width: parent.width
      password: true
      placeholderText: "Paste API key"
      foreground: root.foreground
      selectByMouse: true
    }
    Text {
      width: parent.width; visible: root.controller.keyResult.message !== ""
      text: root.controller.keyResult.message
      color: root.controller.keyResult.ok ? Color.accent : Color.urgent
      font.family: Style.font.family; font.pixelSize: Style.font.caption
    }
    Row {
      spacing: Style.space(8)
      Button { text: "Cancel"; bordered: true; onClicked: { keyField.text = ""; root.closed() } }
      Button {
        text: "Save key"; bordered: true; foreground: Color.accent
        enabled: keyField.text.length >= 8 && !root.controller.keySaving
        onClicked: { root.controller.storeKey(root.provider, keyField.text); keyField.text = "" }
      }
    }
  }
}
