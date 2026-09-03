import QtQuick

Text {
  id: root
  signal triggered()

  textFormat: Text.PlainText
  activeFocusOnTab: visible && enabled
  Accessible.role: Accessible.Button
  Accessible.name: text
  Accessible.onPressAction: if (root.enabled) root.triggered()
  font.underline: activeFocus

  Keys.onSpacePressed: if (root.enabled) root.triggered()
  Keys.onReturnPressed: if (root.enabled) root.triggered()
  Keys.onEnterPressed: if (root.enabled) root.triggered()

  MouseArea {
    anchors.fill: parent
    enabled: root.enabled
    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: root.triggered()
  }
}
