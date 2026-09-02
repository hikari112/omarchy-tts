import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root
  property string label: ""
  property string description: ""
  property bool checked: false
  property color foreground: Color.popups.text
  signal toggled(bool value)
  width: parent ? parent.width : implicitWidth
  height: Math.max(copy.implicitHeight, 24)

  Column {
    id: copy
    width: parent.width - 42
    spacing: 1
    Text { text: root.label; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body }
    Text {
      width: parent.width; visible: root.description !== ""; text: root.description
      wrapMode: Text.WordWrap; color: Color.muted; font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
  Rectangle {
    width: 30; height: 16; radius: 8; anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    color: root.checked ? Color.accent : Color.muted
    opacity: root.checked ? 1 : 0.45
    Rectangle {
      width: 12; height: 12; radius: 6; anchors.verticalCenter: parent.verticalCenter
      x: root.checked ? parent.width - width - 2 : 2
      color: root.checked ? Color.popups.background : root.foreground
      Behavior on x { NumberAnimation { duration: 150 } }
    }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.toggled(!root.checked) }
  }
}
