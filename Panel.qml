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
  onOpenedChanged: if (opened) { currentTab = 0; browsing = false; refresh() }

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

  readonly property string voiceBin: "$HOME/.local/bin/speak-voice"

  property bool browsing: false
  property var catalogue: []
  property string voiceFilter: ""
  property var dl: ({ status: "idle", voice: "", percent: 0 })

  readonly property var filteredVoices: {
    var q = String(root.voiceFilter).toLowerCase().trim()
    var all = root.catalogue || []
    if (!q) return all
    var out = []
    for (var i = 0; i < all.length; i++) {
      var v = all[i]
      if (String(v.key).toLowerCase().indexOf(q) >= 0
          || String(v.lang).toLowerCase().indexOf(q) >= 0
          || String(v.country).toLowerCase().indexOf(q) >= 0) out.push(v)
    }
    return out
  }

  function loadCatalogue() { catalogueProc.running = false; catalogueProc.running = true }

  function getVoice(key) {
    runner.running = false
    runner.command = ["bash", "-c", "exec " + root.voiceBin + " add " + key + " --async"]
    runner.running = true
    root.dl = { status: "downloading", voice: key, percent: 0 }
    dlPoll.running = true
  }

  Process {
    id: catalogueProc
    command: ["bash", "-c", "exec " + root.voiceBin + " available --json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.catalogue = JSON.parse(text) } catch (e) { root.catalogue = [] }
      }
    }
  }

  Process {
    id: dlStatusProc
    command: ["bash", "-c", "exec " + root.voiceBin + " status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var st = JSON.parse(text)
          root.dl = st
          if (st.status === "done" || st.status === "error") {
            dlPoll.running = false
            root.loadCatalogue()
            root.refresh()
          }
        } catch (e) { /* keep polling */ }
      }
    }
  }

  Timer {
    id: dlPoll
    interval: 500
    repeat: true
    running: false
    onTriggered: { dlStatusProc.running = false; dlStatusProc.running = true }
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
          visible: root.currentTab === 1 && !root.browsing

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

          Button {
            width: parent.width
            text: (root.info.voices && root.info.voices.length > 0)
                  ? "Browse all voices" : "Download a voice"
            iconText: "󰇚"
            bordered: true
            // Primary when there is nothing installed: it is the only way out.
            foreground: (root.info.voices && root.info.voices.length > 0) ? root.fg : Color.accent
            onClicked: { root.browsing = true; root.voiceFilter = ""; root.loadCatalogue() }
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
              text: (root.info.maxChars > 0) ? root.info.maxChars + " characters" : "unlimited"
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

        // ---------- voice browser ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.currentTab === 1 && root.browsing

          Item {
            width: parent.width
            height: browseHdr.implicitHeight

            PanelSectionHeader { id: browseHdr; text: "Browse voices"; foreground: root.fg }

            Text {
              anchors.right: backBtn.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: root.catalogue.length > 0
                    ? root.filteredVoices.length + " of " + root.catalogue.length
                    : "loading…"
              color: root.dim
              font.family: root.ff
              font.pixelSize: Style.font.caption
            }

            Text {
              id: backBtn
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "Done"
              color: Color.accent
              font.family: root.ff
              font.pixelSize: Style.font.caption
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.browsing = false
              }
            }
          }

          TextField {
            width: parent.width
            text: root.voiceFilter
            foreground: root.fg
            onTextChanged: root.voiceFilter = text
          }

          ListView {
            width: parent.width
            height: Style.space(240)
            clip: true
            spacing: Style.space(2)
            model: root.filteredVoices
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              required property var modelData
              readonly property bool busy: root.dl.status === "downloading"
                                           && root.dl.voice === modelData.key
              width: ListView.view ? ListView.view.width : 0
              height: vrow.implicitHeight + Style.space(10)
              radius: Style.space(5)
              color: modelData.installed ? root.tint(0.07) : "transparent"

              Column {
                id: vrow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(1)

                Item {
                  width: parent.width
                  height: vname.implicitHeight

                  Text {
                    id: vname
                    text: parent.parent.parent.modelData.name
                    color: root.fg
                    font.family: root.ff
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    anchors.left: vname.right
                    anchors.leftMargin: Style.space(6)
                    anchors.baseline: vname.baseline
                    text: parent.parent.parent.modelData.quality
                    color: root.dim
                    font.family: root.ff
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: {
                      var d = parent.parent.parent
                      if (d.modelData.installed) return "󰄬 Installed"
                      if (d.busy) return root.dl.percent + "%"
                      return "󰇚 " + d.modelData.sizeMB + " MB"
                    }
                    color: {
                      var d = parent.parent.parent
                      return (d.modelData.installed || d.busy) ? Color.accent : root.dim
                    }
                    font.family: root.ff
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  text: parent.parent.modelData.lang
                      + (parent.parent.modelData.country ? " · " + parent.parent.modelData.country : "")
                  color: root.dim
                  font.family: root.ff
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                anchors.fill: parent
                enabled: !parent.modelData.installed && !parent.busy
                         && root.dl.status !== "downloading"
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.getVoice(parent.modelData.key)
              }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: root.dl.status === "downloading" || root.dl.status === "error"
            text: root.dl.status === "error"
                  ? ("Could not download " + root.dl.voice + (root.dl.message ? " — " + root.dl.message : ""))
                  : ("Downloading " + root.dl.voice + " · " + root.dl.percent + "%")
            color: root.dl.status === "error" ? Color.urgent : root.dim
            font.family: root.ff
            font.pixelSize: Style.font.caption
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
