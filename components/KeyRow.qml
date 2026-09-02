import QtQuick
import qs.Commons
import qs.Ui

Rectangle {
  id: root
  property string actionName: ""
  property string label: ""
  property string chord: ""
  property color foreground: Color.popups.text
  signal changeRequested(string actionName, string chord)
  width: parent ? parent.width : implicitWidth
  height: 34; radius: Style.space(5); color: "transparent"
  Text {
    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
    text: root.label; color: root.foreground; font.family: Style.font.family
    font.pixelSize: Style.font.body
  }
  Rectangle {
    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
    width: keyText.implicitWidth + 12; height: 24; radius: 4
    color: Color.background; border.width: 1; border.color: Color.popups.border
    Text {
      id: keyText; anchors.centerIn: parent; text: root.chord.replace(/ \+ /g, "  ")
      color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption
    }
  }
  MouseArea {
    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
    onClicked: root.changeRequested(root.actionName, root.chord)
  }
}
