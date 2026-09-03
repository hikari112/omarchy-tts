import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

Rectangle {
  id: root
  required property var controller
  property string provider: ""
  property string vendor: provider
  property string purpose: "speech"
  // What this key lets the plugin send. A speech key sends text; an OCR key
  // sends pictures of the screen, and the dialog must say which.
  property string sends: "Highlighted text and test samples"
  property color foreground: Color.popups.text
  readonly property bool editing: visible && keyField.activeFocus
  signal closed
  width: parent ? parent.width : implicitWidth
  height: content.implicitHeight + Style.space(24)
  radius: Style.space(8)
  color: Color.background
  border.width: 1
  border.color: Color.accent

  function saveKey() {
    if (keyField.text.length < 8 || controller.keySaving) return
    controller.storeKey(provider, keyField.text, purpose)
    keyField.text = ""
  }

  onVisibleChanged: {
    if (visible) Qt.callLater(function() { keyField.forceActiveFocus() })
    else keyField.text = ""
  }

  Column {
    id: content
    anchors.fill: parent
    anchors.margins: Style.space(12)
    spacing: Style.space(8)
    Text { text: "Add " + root.vendor + " API key"; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.subtitle }
    Text {
      width: parent.width; wrapMode: Text.WordWrap
      text: "The key is saved in the system keyring and is never written to settings or logs. " + root.sends + " will be sent to " + root.vendor + " and may incur charges."
      color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption
    }
    TextField {
      id: keyField
      width: parent.width
      password: true
      placeholderText: "Paste API key"
      foreground: root.foreground
      selectByMouse: true
      maximumLength: 4096
      onAccepted: root.saveKey()
    }
    Text {
      width: parent.width; visible: root.controller.keyResult.message !== ""
      text: root.controller.keyResult.message
      color: root.controller.keyResult.ok ? Color.accent : Color.urgent
      font.family: Style.font.family; font.pixelSize: Style.font.caption
    }
    Row {
      spacing: Style.space(8)
      Button { text: "Cancel"; bordered: true; focusable: true; onClicked: { keyField.text = ""; root.closed() } }
      Button {
        text: "Save key"; bordered: true; focusable: true; foreground: Color.accent
        enabled: keyField.text.length >= 8 && !root.controller.keySaving
        onClicked: root.saveKey()
      }
    }
  }
}
