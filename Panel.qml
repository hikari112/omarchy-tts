import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "components"

Panel {
  id: root
  moduleName: "io.github.hikari112.tts"
  ipcTarget: moduleName
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property color fg: Color.popups.text
  readonly property color dim: Color.muted
  readonly property string ff: bar ? bar.fontFamily : Style.font.family
  property int currentTab: 0
  readonly property var tabNames: ["Provider", "Voice", "Text", "Screen", "Keys"]
  property bool browsing: false
  property string voiceFilter: ""
  property string previewSource: "Visit https://omarchy.org in ~2s and run `speak --help`."
  property string sampleText: "Highlight any text and press the key. This is how it sounds right now."
  property string captureAction: ""
  property string capturedChord: ""
  property string confirmInstall: ""
  property string confirmProvider: ""
  property string confirmKeyRemove: ""

  function tint(a) { return Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, a) }
  function keyName(event) {
    var key = event.text ? event.text.toUpperCase() : ""
    if (event.key === Qt.Key_BracketLeft) key = "BRACKETLEFT"
    else if (event.key === Qt.Key_BracketRight) key = "BRACKETRIGHT"
    else if (event.key === Qt.Key_Space) key = "SPACE"
    else if (event.key === Qt.Key_Tab) key = "TAB"
    else if (event.key === Qt.Key_Escape) key = "ESCAPE"
    return key
  }
  function chordFromEvent(event) {
    var parts = []
    if (event.modifiers & Qt.MetaModifier) parts.push("SUPER")
    if (event.modifiers & Qt.ControlModifier) parts.push("CTRL")
    if (event.modifiers & Qt.AltModifier) parts.push("ALT")
    if (event.modifiers & Qt.ShiftModifier) parts.push("SHIFT")
    var key = keyName(event)
    if (!key || key === "ESCAPE") return ""
    parts.push(key)
    return parts.join(" + ")
  }
  readonly property var activeProvider: {
    var all = controller.info.providers || []
    for (var i = 0; i < all.length; ++i)
      if (all[i].name === controller.info.provider) return all[i]
    return null
  }
  readonly property bool activeIsCloud: activeProvider && activeProvider.kind === "cloud"
  readonly property var filteredVoices: {
    var q = voiceFilter.toLowerCase().trim(), all = controller.catalogue || [], out = []
    if (!q) return all
    for (var i = 0; i < all.length; ++i) {
      var value = all[i]
      if (String(value.key).toLowerCase().indexOf(q) >= 0
          || String(value.lang).toLowerCase().indexOf(q) >= 0
          || String(value.country).toLowerCase().indexOf(q) >= 0) out.push(value)
    }
    return out
  }

  TtsController { id: controller }
  Connections {
    target: controller
    function onSelectionTextChanged() {
      if (controller.selectionText.trim()) root.previewSource = controller.selectionText.slice(0, 4000)
    }
  }
  Timer { interval: 750; repeat: true; running: root.opened; onTriggered: controller.refresh() }

  onOpenedChanged: if (opened) {
    controller.refresh(); controller.refreshBindings(); controller.loadSelection()
    Qt.callLater(function() {
      root.currentTab = Math.max(0, Math.min(4, Number(controller.info.ui?.lastTab || 0)))
      root.sampleText = String(controller.info.ui?.sampleText || root.sampleText)
      controller.previewText(root.previewSource)
    })
  }
  onCurrentTabChanged: if (opened) controller.setConfig(".ui.lastTab", currentTab)

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
      onCloseRequested: {
        if (root.captureAction !== "") { root.captureAction = ""; root.capturedChord = "" }
        else root.close()
      }
      Keys.onPressed: function(event) {
        if (root.captureAction !== "") {
          if (event.key === Qt.Key_Escape) { root.captureAction = ""; root.capturedChord = "" }
          else { var chord = root.chordFromEvent(event); if (chord) root.capturedChord = chord }
          event.accepted = true; return
        }
        if (event.key === Qt.Key_Left) root.currentTab = (root.currentTab + 4) % 5
        else if (event.key === Qt.Key_Right) root.currentTab = (root.currentTab + 1) % 5
        else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_5) root.currentTab = event.key - Qt.Key_1
        else return
        event.accepted = true
      }

      Column {
        id: body
        width: parent.width
        spacing: Style.space(12)

        Item {
          width: parent.width; height: Math.max(headerIcon.implicitHeight, headerTitle.implicitHeight)
          Text { id: headerIcon; text: "󰕾"; color: controller.info.speaking ? Color.accent : root.fg; font.family: root.ff; font.pixelSize: Style.fontPx(1.3); anchors.verticalCenter: parent.verticalCenter }
          Text { id: headerTitle; anchors.left: headerIcon.right; anchors.leftMargin: Style.space(8); anchors.verticalCenter: parent.verticalCenter; text: "Text to speech"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.subtitle }
          Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: root.activeIsCloud ? "󰅟 text leaves this machine" : "on-demand accessibility"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
        }
        Row {
          width: parent.width; spacing: Style.space(14)
          Repeater {
            model: root.tabNames
            delegate: Item {
              required property string modelData
              required property int index
              width: tabLabel.implicitWidth; height: tabLabel.implicitHeight + Style.space(6)
              Text { id: tabLabel; text: parent.modelData; color: root.currentTab === parent.index ? root.fg : root.dim; font.family: root.ff; font.pixelSize: Style.font.body }
              Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 2; color: Color.accent; visible: root.currentTab === parent.index }
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.currentTab = parent.index }
            }
          }
        }
        PanelSeparator { width: parent.width; foreground: root.fg }

        // Provider ---------------------------------------------------------
        Column {
          width: parent.width; spacing: Style.space(4); visible: root.currentTab === 0
          Item {
            width: parent.width; height: providerHeader.implicitHeight
            PanelSectionHeader { id: providerHeader; text: "Speech provider"; foreground: root.fg }
            Text { anchors.right: parent.right; text: "󰅟 = cloud provider"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
          }
          Repeater {
            model: controller.info.providers || []
            delegate: Rectangle {
              required property var modelData
              readonly property bool selected: modelData.name === controller.info.provider
              readonly property bool ready: modelData.status === "ready"
              readonly property bool cloud: modelData.kind === "cloud"
              width: parent.width; height: providerCopy.implicitHeight + Style.space(12); radius: Style.space(6)
              color: selected ? root.tint(0.10) : "transparent"; border.width: selected ? 1 : 0; border.color: root.tint(0.45)
              Column {
                id: providerCopy; z: 1; anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8); spacing: 2
                Item {
                  width: parent.width; height: providerName.implicitHeight
                  Text { id: providerRadio; text: parent.parent.parent.selected ? "󰝥" : "󰝦"; color: parent.parent.parent.ready ? (parent.parent.parent.selected ? Color.accent : root.fg) : root.dim; font.family: root.ff; font.pixelSize: Style.font.body }
                  Text { id: providerName; anchors.left: providerRadio.right; anchors.leftMargin: 8; text: parent.parent.parent.modelData.name; color: parent.parent.parent.ready ? root.fg : root.dim; font.family: root.ff; font.pixelSize: Style.font.body }
                  Text { anchors.left: providerName.right; anchors.leftMargin: 6; anchors.baseline: providerName.baseline; text: parent.parent.parent.modelData.kind; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
                  Text { anchors.right: providerAction.left; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; text: parent.parent.parent.ready ? (parent.parent.parent.cloud ? (parent.parent.parent.modelData.keySource === "keyring" ? "● Key stored" : "● Key available") : "● Ready") : (parent.parent.parent.modelData.status === "nokey" ? "No API key" : "Not installed"); color: parent.parent.parent.ready ? Color.accent : root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
                  Text {
                    id: providerAction; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; visible: (parent.parent.parent.cloud && parent.parent.parent.modelData.keySource === "keyring") || !parent.parent.parent.ready
                    text: parent.parent.parent.cloud && parent.parent.parent.ready ? "Remove key" : (parent.parent.parent.modelData.status === "nokey" ? "Add key" : "Install"); color: Color.accent; font.family: root.ff; font.pixelSize: Style.font.caption
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { var row = parent.parent.parent.parent; if (row.cloud && row.ready) root.confirmKeyRemove = row.modelData.name; else if (row.modelData.status === "nokey") controller.storeKey(row.modelData.name); else { root.confirmProvider = row.modelData.name; root.confirmInstall = row.modelData.install } } }
                  }
                }
                Text { visible: parent.parent.cloud; text: "󰅟 Sends highlighted text to " + (parent.parent.modelData.vendor || parent.parent.modelData.name) + " · paid"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
                Text { visible: parent.parent.modelData.name === "kokoro"; text: "Heavy · slow first start after boot"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
              }
              MouseArea { anchors.fill: parent; enabled: parent.ready; z: 0; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: controller.selectProvider(parent.modelData.name) }
            }
          }
          Rectangle {
            width: parent.width; height: installCol.implicitHeight + 16; radius: 6; visible: root.confirmInstall !== ""; color: root.tint(0.08); border.width: 1; border.color: Color.popups.border
            Column {
              id: installCol; anchors.fill: parent; anchors.margins: 8; spacing: 6
              Text { text: "Install " + root.confirmProvider + "?"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.body }
              Text { width: parent.width; text: root.confirmInstall; wrapMode: Text.WrapAnywhere; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
              Row { spacing: 8
                Button { text: "Cancel"; bordered: true; onClicked: { root.confirmInstall = ""; root.confirmProvider = "" } }
                Button { text: "Open terminal"; bordered: true; foreground: Color.accent; onClicked: { controller.installProvider(root.confirmInstall); root.confirmInstall = ""; root.confirmProvider = "" } }
              }
            }
          }
          Rectangle {
            width: parent.width; height: keyRemoveRow.implicitHeight + 16; radius: 6
            visible: root.confirmKeyRemove !== ""; color: root.tint(0.08)
            border.width: 1; border.color: Color.popups.border
            Row {
              id: keyRemoveRow; anchors.fill: parent; anchors.margins: 8; spacing: 8
              Text { text: "Remove the " + root.confirmKeyRemove + " API key?"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.body }
              Button { text: "Cancel"; bordered: true; onClicked: root.confirmKeyRemove = "" }
              Button { text: "Remove"; bordered: true; foreground: Color.urgent; onClicked: { controller.removeKey(root.confirmKeyRemove); root.confirmKeyRemove = "" } }
            }
          }
        }

        // Voice ------------------------------------------------------------
        Column {
          width: parent.width; spacing: Style.space(10); visible: root.currentTab === 1 && !root.browsing
          PanelSectionHeader { text: "Voice"; foreground: root.fg }
          Dropdown { width: parent.width; showLabel: false; foreground: root.fg; options: controller.info.voices?.length ? controller.info.voices : ["No voice installed"]; value: controller.info.voice || ""; onValueChanged: if (value && value !== controller.info.voice && value !== "No voice installed") controller.setConfig(controller.info.voicePath || ".piper.voice", value) }
          Button { width: parent.width; text: controller.info.voices?.length ? "Browse all voices" : "Download a voice"; iconText: "󰇚"; bordered: true; foreground: controller.info.voices?.length ? root.fg : Color.accent; visible: !root.activeProvider || root.activeProvider.voices === "downloadable"; onClicked: { root.browsing = true; root.voiceFilter = ""; controller.loadCatalogue() } }
          Item { width: parent.width; height: speedHeader.implicitHeight; PanelSectionHeader { id: speedHeader; text: "Speed"; foreground: root.fg }; Text { anchors.right: parent.right; text: Number(controller.info.rate || 1).toFixed(2) + "×"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption } }
          Row { width: parent.width; spacing: 8
            Button { width: 32; text: "−"; bordered: true; onClicked: controller.setConfig(".rate", Math.max(.5, Number(controller.info.rate)-.1).toFixed(2)) }
            PanelSlider { width: parent.width - 80; bar: root.bar; minimum: .5; maximum: 2; step: .05; value: controller.info.rate || 1; onValueChanged: if (!dragging && Math.abs(value - Number(controller.info.rate || 1)) > .001) controller.setConfig(".rate", value.toFixed(2)) }
            Button { width: 32; text: "+"; bordered: true; onClicked: controller.setConfig(".rate", Math.min(2, Number(controller.info.rate)+.1).toFixed(2)) }
          }
          Item { width: parent.width; height: limitHeader.implicitHeight; PanelSectionHeader { id: limitHeader; text: "Length limit"; foreground: root.fg }; Text { anchors.right: parent.right; text: controller.info.maxChars > 0 ? "~" + Math.max(1, Math.round(controller.info.maxChars / 900)) + " min" : "unlimited"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption } }
          Row { width: parent.width; spacing: 8
            Button { width: 48; text: "−500"; bordered: true; onClicked: controller.setConfig(".maxChars", Math.max(0, Number(controller.info.maxChars)-500)) }
            TextField { width: parent.width - 112; text: String(controller.info.maxChars || 0); foreground: root.fg; onEditingFinished: controller.setConfig(".maxChars", Math.max(0, Number(text)||0)) }
            Button { width: 48; text: "+500"; bordered: true; onClicked: controller.setConfig(".maxChars", Number(controller.info.maxChars||0)+500) }
          }
        }
        Column {
          width: parent.width; spacing: 8; visible: root.currentTab === 1 && root.browsing
          Item { width: parent.width; height: browseHeader.implicitHeight; PanelSectionHeader { id: browseHeader; text: "Browse voices · Piper"; foreground: root.fg }; Text { anchors.right: parent.right; text: "Done"; color: Color.accent; font.family: root.ff; font.pixelSize: Style.font.caption; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.browsing = false } } }
          TextField { width: parent.width; text: root.voiceFilter; foreground: root.fg; onTextChanged: root.voiceFilter = text }
          ListView {
            width: parent.width; height: Style.space(240); clip: true; model: root.filteredVoices; spacing: 2
            delegate: Rectangle {
              required property var modelData
              readonly property bool busy: controller.download.status === "downloading" && controller.download.voice === modelData.key
              width: ListView.view.width; height: 42; radius: 5; color: modelData.installed ? root.tint(.07) : "transparent"
              Text { anchors.left: parent.left; anchors.leftMargin: 8; anchors.verticalCenter: parent.verticalCenter; text: parent.modelData.name + " · " + parent.modelData.quality + " · " + parent.modelData.lang; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption }
              Text { anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; text: parent.modelData.installed ? "󰄬 Installed" : (parent.busy ? controller.download.percent + "%" : "󰇚 " + parent.modelData.sizeMB + " MB"); color: parent.modelData.installed || parent.busy ? Color.accent : root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
              MouseArea { anchors.fill: parent; enabled: !parent.modelData.installed && !parent.busy; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: controller.downloadVoice(parent.modelData.key) }
            }
          }
          Text { text: "Storage: ~/.local/share/piper-voices"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
        }

        // Text -------------------------------------------------------------
        Column {
          width: parent.width; spacing: 8; visible: root.currentTab === 2
          PanelSectionHeader { text: "What gets spoken"; foreground: root.fg }
          Row {
            width: parent.width; spacing: 8
            Rectangle { width: (parent.width - 8) / 2; height: 94; radius: 6; color: Color.background; border.width: 1; border.color: Color.popups.border; TextArea { anchors.fill: parent; anchors.margins: 6; text: root.previewSource; color: root.dim; wrapMode: TextEdit.Wrap; background: null; onTextChanged: { root.previewSource = text; previewDelay.restart() } } }
            Rectangle { width: (parent.width - 8) / 2; height: 94; radius: 6; color: root.tint(.06); border.width: 1; border.color: Color.popups.border; Text { anchors.fill: parent; anchors.margins: 6; text: controller.preview || "Spoken preview"; color: root.fg; wrapMode: Text.WordWrap; font.family: root.ff; font.pixelSize: Style.font.caption } }
          }
          SettingToggle { label: "Read URLs as ‘link’"; checked: controller.info.sanitizer?.urls === "link"; foreground: root.fg; onToggled: controller.setConfig(".sanitizer.urls", value ? "link" : "domain") }
          SettingToggle { label: "Read inline code"; checked: controller.info.sanitizer?.inlineCode !== false; foreground: root.fg; onToggled: controller.setConfig(".sanitizer.inlineCode", value) }
          SettingToggle { label: "Announce skipped code blocks"; checked: controller.info.sanitizer?.announceCodeBlocks !== false; foreground: root.fg; onToggled: controller.setConfig(".sanitizer.announceCodeBlocks", value) }
          SettingToggle { label: "Strip Markdown symbols"; checked: controller.info.sanitizer?.stripMarkdown !== false; foreground: root.fg; onToggled: controller.setConfig(".sanitizer.stripMarkdown", value) }
          SettingToggle { label: "Expand abbreviations and units"; checked: controller.info.sanitizer?.expandUnits !== false; foreground: root.fg; onToggled: controller.setConfig(".sanitizer.expandUnits", value) }
          Timer { id: previewDelay; interval: 180; onTriggered: controller.previewText(root.previewSource) }
        }

        // Screen -----------------------------------------------------------
        Column {
          width: parent.width; spacing: 10; visible: root.currentTab === 3
          PanelSectionHeader { text: "Reading the screen"; foreground: root.fg }
          Text { width: parent.width; wrapMode: Text.WordWrap; text: "Region, focused-window and focused-monitor OCR stay local. Recognised text only leaves your computer when a cloud speech provider is active."; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
          Item { width: parent.width; height: ocrHeader.implicitHeight; PanelSectionHeader { id: ocrHeader; text: "Confidence floor"; foreground: root.fg }; Text { anchors.right: parent.right; text: controller.info.ocr?.minConfidence > 0 ? controller.info.ocr.minConfidence + "%" : "keep everything"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption } }
          PanelSlider { width: parent.width; bar: root.bar; minimum: 0; maximum: 95; step: 5; integer: true; value: controller.info.ocr?.minConfidence ?? 60; onValueChanged: if (!dragging && Math.round(value) !== Number(controller.info.ocr?.minConfidence ?? 60)) controller.setConfig(".ocr.minConfidence", Math.round(value)) }
          TextField { width: parent.width; text: controller.info.ocr?.langs || "eng"; foreground: root.fg; onEditingFinished: controller.setConfig(".ocr.langs", text) }
          Text { width: parent.width; wrapMode: Text.WordWrap; text: "Tesseract language codes joined with + (for example eng+fra). Install the corresponding language data first."; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
        }

        // Keys -------------------------------------------------------------
        Column {
          width: parent.width; spacing: 4; visible: root.currentTab === 4
          Item { width: parent.width; height: keysHeader.implicitHeight; PanelSectionHeader { id: keysHeader; text: "Keybindings"; foreground: root.fg }; Text { anchors.right: parent.right; text: controller.bindings.installed ? "● Installed" : "Not installed"; color: controller.bindings.installed ? Color.accent : root.dim; font.family: root.ff; font.pixelSize: Style.font.caption } }
          Repeater {
            model: ["selection", "clipboard", "stop", "snip", "window", "screen"]
            delegate: KeyRow {
              required property string modelData
              readonly property var binding: controller.bindings.bindings?.[modelData] || ({})
              actionName: modelData; label: binding.label || modelData; chord: binding.chord || ""; foreground: root.fg
              onChangeRequested: { root.captureAction = actionName; root.capturedChord = chord; keyCatcher.forceActiveFocus() }
            }
          }
          Row { width: parent.width; spacing: 8
            Button { width: (parent.width - 8)/2; text: controller.bindings.installed ? "Apply changes" : "Install bindings"; bordered: true; foreground: Color.accent; onClicked: controller.installBindings() }
            Button { width: (parent.width - 8)/2; text: "Remove TTS bindings"; bordered: true; enabled: controller.bindings.installed; onClicked: controller.removeBindings() }
          }
          Text { width: parent.width; wrapMode: Text.WordWrap; text: "Only the marked omarchy-tts block in bindings.lua is managed. Every write is backed up and rolled back if Hyprland reports an error."; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
        }

        Rectangle {
          width: parent.width; height: captureColumn.implicitHeight + 16; radius: 7; visible: root.captureAction !== ""; color: Color.background; border.width: 1; border.color: Color.accent
          Column { id: captureColumn; anchors.fill: parent; anchors.margins: 8; spacing: 6
            Text { text: "Press the new shortcut for “" + root.captureAction + "”"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.body }
            Text { text: root.capturedChord || "Waiting for keys…"; color: Color.accent; font.family: root.ff; font.pixelSize: Style.font.subtitle }
            Row { spacing: 8
              Button { text: "Cancel"; bordered: true; onClicked: { root.captureAction = ""; root.capturedChord = "" } }
              Button { text: "Use shortcut"; bordered: true; enabled: root.capturedChord !== ""; foreground: Color.accent; onClicked: controller.setBinding(root.captureAction, root.capturedChord) }
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }
        Column {
          width: parent.width; spacing: 8
          Item { width: parent.width; height: testHeader.implicitHeight; PanelSectionHeader { id: testHeader; text: "Test"; foreground: root.fg }; Text { anchors.right: parent.right; text: root.activeIsCloud ? "󰅟 sample sent to " + (root.activeProvider.vendor || root.activeProvider.name) : "runs locally"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption } }
          Row { width: parent.width; spacing: 8
            TextField { id: sampleField; width: parent.width - testButton.width - 8; text: root.sampleText; foreground: root.fg; onTextChanged: root.sampleText = text; onEditingFinished: controller.setConfig(".ui.sampleText", text) }
            Button { id: testButton; width: 96; text: controller.info.speaking ? "Stop" : "Speak"; iconText: controller.info.speaking ? "󰓛" : "󰐊"; bordered: true; foreground: controller.info.speaking ? Color.urgent : root.fg; accent: controller.info.speaking ? Color.urgent : Color.accent; onClicked: controller.info.speaking ? controller.stop() : controller.speak(root.sampleText) }
          }
          Text { width: parent.width; elide: Text.ElideRight; text: (controller.info.speaking ? "● Speaking · " : "") + (controller.info.provider || "") + (controller.info.voice ? " · " + controller.info.voice : "") + " · " + Number(controller.info.rate || 1).toFixed(2) + "×" + (controller.info.maxChars > 0 ? " · ≤" + controller.info.maxChars + " chars" : ""); color: controller.info.speaking ? Color.accent : root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
          Text { width: parent.width; visible: controller.error !== ""; text: controller.error; wrapMode: Text.WordWrap; color: Color.urgent; font.family: root.ff; font.pixelSize: Style.font.caption }
        }
      }
    }
  }
}
