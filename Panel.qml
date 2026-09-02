import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.hikari112.tts"
  ipcTarget: "io.github.hikari112.tts"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string speakBin: "$HOME/.local/bin/speak"

  property var info: ({ providers: [], voices: [], ocr: {} })
  property int currentTab: 0
  readonly property var tabNames: ["Provider", "Voice", "Screen"]
  property bool speaking: false
  property string sampleText: "Highlight any text and press the key. This is how it sounds right now."

  readonly property color fg: Color.popups.text
  readonly property color dim: Color.muted
  readonly property string ff: bar ? bar.fontFamily : Style.font.family

  // accent at low alpha: the "selected" fill, without inventing a colour.
  function tint(a) { return Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, a) }

  readonly property var activeProvider: {
    var ps = info.providers || []
    for (var i = 0; i < ps.length; i++) if (ps[i].name === info.provider) return ps[i]
    return null
  }
  readonly property bool activeIsCloud: activeProvider && activeProvider.kind === "cloud"

  function refresh() { infoProc.running = false; infoProc.running = true }

  function run(args) {
    runner.running = false
    runner.command = ["bash", "-c", "exec " + root.speakBin + " " + args]
    runner.running = true
  }

  function setCfg(path, value) {
    run("--set " + path + " " + value)
    Qt.callLater(root.refresh)
  }

  // Land on Provider every time. This panel is opened rarely and for a
  // reason; a remembered tab means guessing which reason it was.
  onOpenedChanged: if (opened) { currentTab = 0; refresh() }

  Process {
    id: infoProc
    command: ["bash", "-c", "exec " + root.speakBin + " --info"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          root.info = parsed
          root.speaking = parsed.speaking === true
        } catch (e) { /* keep the last good state rather than blanking the panel */ }
      }
    }
  }

  Process { id: runner; running: false; command: [] }

  KeyboardPanel {
    id: panelCard
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panelCard.fittedContentWidth(Style.space(420))
    contentHeight: panelCard.fittedContentHeight(body.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Left) {
          root.currentTab = (root.currentTab + root.tabNames.length - 1) % root.tabNames.length
          event.accepted = true
        } else if (event.key === Qt.Key_Right) {
          root.currentTab = (root.currentTab + 1) % root.tabNames.length
          event.accepted = true
        } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_3) {
          root.currentTab = event.key - Qt.Key_1
          event.accepted = true
        }
      }

      Column {
        id: body
        width: parent.width
        spacing: Style.space(12)

        // ---------- header ----------
        Item {
          width: parent.width
          height: Math.max(hdrIcon.implicitHeight, hdrText.implicitHeight)

          Text {
            id: hdrIcon
            text: "󰕾"
            color: root.speaking ? Color.accent : root.fg
            font.family: root.ff
            font.pixelSize: Style.fontPx(1.3)
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            id: hdrText
            anchors.left: hdrIcon.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: "Text to speech"
            color: root.fg
            font.family: root.ff
            font.pixelSize: Style.font.subtitle
          }
          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Super + Alt + E"
            color: root.dim
            font.family: root.ff
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- tabs ----------
        Row {
          width: parent.width
          spacing: Style.space(14)

          Repeater {
            model: root.tabNames
            delegate: Item {
              required property string modelData
              required property int index
              width: tabLabel.implicitWidth
              height: tabLabel.implicitHeight + Style.space(6)

              Text {
                id: tabLabel
                text: parent.modelData
                color: root.currentTab === parent.index ? root.fg : root.dim
                font.family: root.ff
                font.pixelSize: Style.font.body
              }
              Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 2
                color: Color.accent
                visible: root.currentTab === parent.index
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.currentTab = parent.index
              }
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // ---------- tab: provider ----------
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.currentTab === 0

          Item {
            width: parent.width
            height: legend.implicitHeight
            PanelSectionHeader { text: "Speech provider"; foreground: root.fg }
            Text {
              id: legend
              anchors.right: parent.right
              text: "󰅟 = text leaves this machine"
              color: root.dim
              font.family: root.ff
              font.pixelSize: Style.font.caption
            }
          }

          Repeater {
            model: root.info.providers || []
            delegate: Rectangle {
              required property var modelData
              readonly property bool isActive: modelData.name === root.info.provider
              readonly property bool isReady: modelData.status === "ready"
              readonly property bool isCloud: modelData.kind === "cloud"

              width: parent.width
              height: rowCol.implicitHeight + Style.space(12)
              radius: Style.space(6)
              color: isActive ? root.tint(0.10) : "transparent"
              border.width: isActive ? 1 : 0
              border.color: isActive ? root.tint(0.45) : "transparent"

              Column {
                id: rowCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(2)

                Item {
                  width: parent.width
                  height: nameText.implicitHeight

                  Text {
                    id: radioGlyph
                    text: parent.parent.parent.isActive ? "󰝥" : "󰝦"
                    color: parent.parent.parent.isActive ? Color.accent
                         : (parent.parent.parent.isReady ? root.fg : root.dim)
                    font.family: root.ff
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    id: nameText
                    anchors.left: radioGlyph.right
                    anchors.leftMargin: Style.space(8)
                    text: parent.parent.parent.modelData.name
                    color: parent.parent.parent.isReady ? root.fg : root.dim
                    font.family: root.ff
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    anchors.left: nameText.right
                    anchors.leftMargin: Style.space(6)
                    anchors.baseline: nameText.baseline
                    text: parent.parent.parent.modelData.kind
                    color: root.dim
                    font.family: root.ff
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: {
                      var s = parent.parent.parent.modelData.status
                      if (s === "ready") return parent.parent.parent.isCloud ? "● Key stored" : "● Ready"
                      if (s === "nokey") return "No API key"
                      return "Not installed"
                    }
                    // Absence is not an emergency: muted, never urgent.
                    color: parent.parent.parent.isReady ? Color.accent : root.dim
                    font.family: root.ff
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  visible: parent.parent.isCloud
                  text: "󰅟 Sends highlighted text off this machine · paid"
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                anchors.fill: parent
                enabled: parent.isReady
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                  root.run("--stop")
                  root.setCfg(".provider", parent.modelData.name)
                }
              }
            }
          }
        }

        // ---------- tab: voice ----------
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.currentTab === 1

          PanelSectionHeader { text: "Voice"; foreground: root.fg }

          Dropdown {
            width: parent.width
            showLabel: false
            options: (root.info.voices && root.info.voices.length > 0)
                     ? root.info.voices : ["No voice installed"]
            value: root.info.voice || ""
            foreground: root.fg
            onValueChanged: {
              if (value && value !== root.info.voice && value !== "No voice installed")
                root.setCfg(".piper.voice", value)
            }
          }

          Item {
            width: parent.width
            height: speedHdr.implicitHeight
            PanelSectionHeader { id: speedHdr; text: "Speed"; foreground: root.fg }
            Text {
              anchors.right: parent.right
              text: (root.info.rate || 1).toFixed(2) + "×"
              color: root.fg
              font.family: root.ff
              font.pixelSize: Style.font.caption
            }
          }

          PanelSlider {
            width: parent.width
            bar: root.bar
            minimum: 0.5
            maximum: 2.0
            step: 0.05
            value: root.info.rate || 1.0
            onValueChanged: if (!dragging) root.setCfg(".rate", value.toFixed(2))
          }

          Item {
            width: parent.width
            height: limitHdr.implicitHeight
            PanelSectionHeader { id: limitHdr; text: "Length limit"; foreground: root.fg }
            Text {
              anchors.right: parent.right
              text: (root.info.maxChars > 0)
                    ? root.info.maxChars + " characters"
                    : "unlimited"
              color: root.dim
              font.family: root.ff
              font.pixelSize: Style.font.caption
            }
          }

          PanelSlider {
            width: parent.width
            bar: root.bar
            minimum: 0
            maximum: 4000
            step: 250
            integer: true
            value: root.info.maxChars || 0
            onValueChanged: if (!dragging) root.setCfg(".maxChars", Math.round(value))
          }
        }

        // ---------- tab: screen (OCR) ----------
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.currentTab === 2

          PanelSectionHeader { text: "Reading the screen"; foreground: root.fg }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Super + Alt + R drags a box. Super + Alt + W reads the focused "
                + "window and needs no pointer."
            color: root.dim
            font.family: root.ff
            font.pixelSize: Style.font.caption
          }

          Item {
            width: parent.width
            height: confHdr.implicitHeight
            PanelSectionHeader { id: confHdr; text: "Confidence floor"; foreground: root.fg }
            Text {
              anchors.right: parent.right
              text: (root.info.ocr && root.info.ocr.minConfidence > 0)
                    ? root.info.ocr.minConfidence + "%" : "keep everything"
              color: root.fg
              font.family: root.ff
              font.pixelSize: Style.font.caption
            }
          }

          PanelSlider {
            width: parent.width
            bar: root.bar
            minimum: 0
            maximum: 95
            step: 5
            integer: true
            value: (root.info.ocr && root.info.ocr.minConfidence !== undefined)
                   ? root.info.ocr.minConfidence : 60
            onValueChanged: if (!dragging) root.setCfg(".ocr.minConfidence", Math.round(value))
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Words the OCR engine is less sure of than this are dropped rather "
                + "than spoken. Nothing warns you about a word that was never there."
            color: root.dim
            font.family: root.ff
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // ---------- test dock (every tab) ----------
        Column {
          width: parent.width
          spacing: Style.space(8)

          Item {
            width: parent.width
            height: testHdr.implicitHeight
            PanelSectionHeader { id: testHdr; text: "Test"; foreground: root.fg }
            Text {
              anchors.right: parent.right
              text: root.activeIsCloud ? "󰅟 sample will be sent off-machine" : "runs locally"
              color: root.dim
              font.family: root.ff
              font.pixelSize: Style.font.caption
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: sampleField
              width: parent.width - speakBtn.width - Style.space(8)
              text: root.sampleText
              foreground: root.fg
              onTextChanged: root.sampleText = text
            }

            Button {
              id: speakBtn
              text: root.speaking ? "Stop" : "Speak"
              iconText: root.speaking ? "󰓛" : "󰐊"
              bordered: true
              foreground: root.speaking ? Color.urgent : root.fg
              accent: root.speaking ? Color.urgent : Color.accent
              onClicked: {
                if (root.speaking) {
                  root.run("--stop")
                } else {
                  // Single-quote the sample so punctuation cannot reach the shell.
                  var safe = String(root.sampleText).replace(/'/g, "'\\''")
                  root.run("--raw -- '" + safe + "'")
                }
              }
            }
          }

          Text {
            width: parent.width
            elide: Text.ElideRight
            text: (root.speaking ? "Speaking · " : "")
                + (root.info.provider || "")
                + (root.info.voice ? " · " + root.info.voice : "")
                + " · " + (root.info.rate || 1).toFixed(2) + "×"
            color: root.speaking ? Color.accent : root.dim
            font.family: root.ff
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
