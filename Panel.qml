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
  property string confirmVoiceRemove: ""
  property string apiProvider: ""
  property string apiVendor: ""
  property bool setupSkipped: false
  readonly property bool hasReadyProvider: {
    var all = controller.info.providers || []
    for (var i = 0; i < all.length; ++i) if (all[i].status === "ready") return true
    return false
  }
  readonly property bool needsSetup: controller.infoLoaded && !controller.setup.ready
                                     && !hasReadyProvider && !setupSkipped

  function tint(a) { return Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, a) }
  function keyName(event) {
    var key = event.text ? event.text.toUpperCase() : ""
    if (event.key === Qt.Key_BracketLeft) key = "BRACKETLEFT"
    else if (event.key === Qt.Key_BracketRight) key = "BRACKETRIGHT"
    else if (event.key === Qt.Key_Comma) key = "COMMA"
    else if (event.key === Qt.Key_Period) key = "PERIOD"
    else if (event.key === Qt.Key_Slash) key = "SLASH"
    else if (event.key === Qt.Key_Backslash) key = "BACKSLASH"
    else if (event.key === Qt.Key_Semicolon) key = "SEMICOLON"
    else if (event.key === Qt.Key_Apostrophe) key = "APOSTROPHE"
    else if (event.key === Qt.Key_Minus) key = "MINUS"
    else if (event.key === Qt.Key_Equal) key = "EQUAL"
    else if (event.key === Qt.Key_QuoteLeft) key = "GRAVE"
    else if (event.key === Qt.Key_Space) key = "SPACE"
    else if (event.key === Qt.Key_Tab) key = "TAB"
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) key = "RETURN"
    else if (event.key === Qt.Key_Backspace) key = "BACKSPACE"
    else if (event.key === Qt.Key_Delete) key = "DELETE"
    else if (event.key === Qt.Key_Left) key = "LEFT"
    else if (event.key === Qt.Key_Right) key = "RIGHT"
    else if (event.key === Qt.Key_Up) key = "UP"
    else if (event.key === Qt.Key_Down) key = "DOWN"
    else if (event.key >= Qt.Key_F1 && event.key <= Qt.Key_F35)
      key = "F" + String(event.key - Qt.Key_F1 + 1)
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
  property string voiceSort: "lang"
  readonly property var voiceSorts: [
    { key: "lang", label: "Language" },
    { key: "name", label: "Name" },
    { key: "size", label: "Size" },
    { key: "quality", label: "Quality" }
  ]

  // Voices are stored as filenames like "en_US-amy-medium". That is an
  // identifier, not a name, and it is what the dropdown and the status line
  // were showing. Providers whose voice names are already words - kokoro's
  // af_heart, OpenAI's alloy - are left exactly as they are.
  function titleCase(word) {
    var w = String(word)
    return w.length ? w.charAt(0).toUpperCase() + w.slice(1) : w
  }

  function voiceName(key) {
    var parts = String(key).split("-")
    if (parts.length >= 3 && /^[a-z]{2,3}_[A-Za-z]{2,4}$/.test(parts[0]))
      return root.titleCase(parts[1].replace(/_/g, " "))
    return String(key)
  }

  function voiceLabel(key) {
    var parts = String(key).split("-")
    if (parts.length >= 3 && /^[a-z]{2,3}_[A-Za-z]{2,4}$/.test(parts[0]))
      return root.voiceName(key) + " · " + parts[0] + " · " + parts.slice(2).join("-")
    return String(key)
  }

  // PanelSlider ends a drag with `liveValue = value`, assuming the owner has
  // already applied the new number. Ours is written to disk and read back,
  // which takes about 200 ms, so `value` still held the old number and the
  // knob snapped back to it before jumping forward again. These hold the
  // value the user just chose so `value` is already correct at that instant;
  // they are cleared as soon as a settings read confirms the write.
  property real rateOverride: -1
  property int confidenceOverride: -1

  readonly property real rateValue:
    rateOverride >= 0 ? rateOverride : Number(controller.info.rate || 1)
  readonly property int confidenceValue:
    confidenceOverride >= 0 ? confidenceOverride
                            : Number(controller.info.ocr?.minConfidence ?? 60)

  readonly property int adoptableCount: (controller.bindings.adoptable || []).length

  readonly property int removeSizeMB: {
    var all = controller.catalogue || []
    for (var i = 0; i < all.length; ++i)
      if (all[i].key === root.confirmVoiceRemove) return Number(all[i].sizeMB || 0)
    return 0
  }

  // A provider addressed by filename (piper) sends plain keys and we make them
  // readable here; one addressed by opaque id (ElevenLabs) sends the names its
  // own service gave them, because only the service knows them.
  readonly property var voiceOptions: {
    var list = controller.info.voices || [], out = []
    for (var i = 0; i < list.length; ++i) {
      var v = list[i]
      if (v && typeof v === "object")
        out.push({ label: String(v.label || v.value), value: String(v.value) })
      else
        out.push({ label: root.voiceLabel(v), value: String(v) })
    }
    return out
  }

  // What to call the active voice: the provider's own name for it if we were
  // given one, otherwise the identifier tidied up.
  function activeVoiceLabel() {
    var opts = root.voiceOptions, current = String(controller.info.voice || "")
    for (var i = 0; i < opts.length; ++i)
      if (opts[i].value === current) return opts[i].label
    return root.voiceName(current)
  }

  function qualityRank(q) {
    return ({ "x_low": 0, "low": 1, "medium": 2, "high": 3 })[String(q)] ?? 1
  }

  readonly property int installedCount: {
    var all = controller.catalogue || [], n = 0
    for (var i = 0; i < all.length; ++i) if (all[i].installed) n++
    return n
  }

  readonly property var filteredVoices: {
    var q = voiceFilter.toLowerCase().trim(), all = controller.catalogue || [], out = []
    for (var i = 0; i < all.length; ++i) {
      var value = all[i]
      if (!q || String(value.key).toLowerCase().indexOf(q) >= 0
             || String(value.lang).toLowerCase().indexOf(q) >= 0
             || String(value.country).toLowerCase().indexOf(q) >= 0) out.push(value)
    }
    var mode = root.voiceSort
    out.sort(function (a, b) {
      // Installed always leads, so the list you can act on is never buried
      // under a hundred you have not downloaded.
      if (a.installed !== b.installed) return a.installed ? -1 : 1
      if (mode === "name") return String(a.name).localeCompare(String(b.name))
      if (mode === "size") return (b.sizeMB - a.sizeMB) || String(a.name).localeCompare(String(b.name))
      if (mode === "quality") return (root.qualityRank(b.quality) - root.qualityRank(a.quality))
                                     || String(a.name).localeCompare(String(b.name))
      return String(a.lang).localeCompare(String(b.lang))
             || String(a.name).localeCompare(String(b.name))
    })
    // ListView sections need the group on the item itself.
    var grouped = []
    for (var j = 0; j < out.length; ++j) {
      var v = out[j]
      grouped.push({ key: v.key, name: v.name, lang: v.lang, country: v.country,
                     quality: v.quality, sizeMB: v.sizeMB, installed: v.installed,
                     group: v.installed ? "Installed" : "Available" })
    }
    return grouped
  }

  TtsController { id: controller }
  // Restoring the tab used to run on a callLater, which fires long before the
  // 200 ms settings read returns - so it restored from whatever was loaded
  // last time and the panel opened on the wrong tab. Wait for real data.
  property bool restorePending: false

  onOpenedChanged: if (opened) {
    restorePending = true
    controller.refresh(); controller.refreshBindings(); controller.refreshSetup()
    controller.loadCatalogue()   // cached: ~30 ms, and the Voice tab needs it
  }

  function restoreFromInfo() {
    if (!restorePending || !controller.infoLoaded) return
    restorePending = false
    currentTab = Math.max(0, Math.min(4, Number(controller.info.ui?.lastTab || 0)))
    sampleText = String(controller.info.ui?.sampleText || sampleText)
    controller.previewText(previewSource)
  }
  Connections {
    target: controller
    function onInfoChanged() {
      // The controller discards reads older than the last write, so anything
      // arriving here already reflects it.
      root.rateOverride = -1
      root.confidenceOverride = -1
      root.restoreFromInfo()
      if (!sampleField.activeFocus) {
        root.sampleText = String(controller.info.ui?.sampleText || root.sampleText)
        Qt.callLater(function() { sampleField.cursorPosition = 0 })
      }
    }
    function onKeyResultChanged() {
      if (controller.keyResult.ok) {
        root.apiProvider = ""
        root.apiVendor = ""
      }
    }
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
          Text { id: headerIcon; text: "󰕾"; color: controller.speaking ? Color.accent : root.fg; font.family: root.ff; font.pixelSize: Style.fontPx(1.3); anchors.verticalCenter: parent.verticalCenter }
          Text { id: headerTitle; anchors.left: headerIcon.right; anchors.leftMargin: Style.space(8); anchors.verticalCenter: parent.verticalCenter; text: "Text to speech"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.subtitle }
          Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; // The shortcut is the whole point of the tool; the panel is where
                 // someone finds out what it is.
                 text: { if (root.activeIsCloud) return "󰅟 text leaves this machine"
                         var b = controller.bindings.bindings
                         if (b && b.selection && b.selection.chord) return b.selection.chord
                         return "on-demand accessibility" }
                 color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
        }
        Row {
          width: parent.width; spacing: Style.space(14); visible: !root.needsSetup
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

        FirstRunWizard {
          width: parent.width; visible: root.needsSetup; controller: controller; foreground: root.fg
          onSkipped: root.setupSkipped = true
        }

        // Provider ---------------------------------------------------------
        Column {
          width: parent.width; spacing: Style.space(4); visible: !root.needsSetup && root.currentTab === 0
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
              readonly property bool failing: modelData.status === "failing"
              readonly property bool untested: modelData.status === "untested"
              readonly property string cloudError: String((((modelData.usage || {}).lastRequest || {}).errorCode) || "")
              // Installed means "present", which is not the same as usable.
              // Unproven is not unusable. A provider that is installed, or a
              // cloud one with a key, can be selected; only one proven unable
              // to speak is refused. Requiring `ready` meant a freshly keyed
              // cloud provider could never be turned on.
              readonly property bool usable: ready || untested
              readonly property bool cloud: modelData.kind === "cloud"
              width: parent.width; height: providerCopy.implicitHeight + Style.space(12); radius: Style.space(6)
              color: selected ? root.tint(0.10) : "transparent"; border.width: selected ? 1 : 0; border.color: root.tint(0.45)
              Column {
                id: providerCopy; z: 1; anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8); spacing: 2
                Item {
                  width: parent.width; height: providerName.implicitHeight
                  Text { id: providerRadio; text: parent.parent.parent.selected ? "󰝥" : "󰝦"; color: parent.parent.parent.ready ? (parent.parent.parent.selected ? Color.accent : root.fg) : root.dim; font.family: root.ff; font.pixelSize: Style.font.body }
                  Text { id: providerName; anchors.left: providerRadio.right; anchors.leftMargin: 8; text: parent.parent.parent.modelData.name; color: parent.parent.parent.usable ? root.fg : root.dim; font.family: root.ff; font.pixelSize: Style.font.body }
                  Text { anchors.left: providerName.right; anchors.leftMargin: 6; anchors.baseline: providerName.baseline; text: parent.parent.parent.modelData.kind; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
                  Text { anchors.right: providerAction.left; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; text: { var d = parent.parent.parent
                            if (d.failing) return d.cloudError === "auth" ? "API key rejected" : "Not working"
                            if (d.untested) return "Untested"
                            if (d.ready) return d.cloud ? (d.modelData.keySource === "keyring" ? "● Key stored" : "● Key available") : "● Ready"
                            return d.modelData.status === "nokey" ? "No API key" : "Not installed" }
                    // urgent is otherwise reserved for Stop, but a backend that is
                    // present and cannot speak is a genuine fault, not an absence.
                    color: { var d = parent.parent.parent
                             if (d.failing) return Color.urgent
                             if (d.ready) return Color.accent
                             return root.dim }
                    font.family: root.ff
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    id: providerAction; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; visible: !parent.parent.parent.ready || (parent.parent.parent.cloud && parent.parent.parent.modelData.keySource === "keyring")
                    text: { var d = parent.parent.parent
                            if (controller.verifying === d.modelData.name) return "Testing…"
                            if (d.modelData.status === "nokey") return "Add key"
                            // A cloud provider that cannot speak is almost always
                            // a bad key, and testing it again proves nothing.
                            if (d.cloud && d.failing) return "Replace key"
                            if (d.failing || d.untested) return "Test"
                            if (d.cloud && d.modelData.keySource === "keyring") return "Remove key"
                            return "Install" }
                    color: Color.accent
                    font.family: root.ff
                    font.pixelSize: Style.font.caption
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: {
                        var row = parent.parent.parent.parent
                        if (row.modelData.status === "nokey" || (row.cloud && row.failing)) {
                          root.apiProvider = row.modelData.name
                          root.apiVendor = row.modelData.vendor || row.modelData.name
                          controller.keyResult = ({ ok: false, message: "" })
                        } else if (row.failing || row.untested) {
                          controller.verifyProvider(row.modelData.name)
                        } else if (row.cloud && row.modelData.keySource === "keyring") {
                          root.confirmKeyRemove = row.modelData.name
                        } else {
                          root.confirmProvider = row.modelData.name
                          root.confirmInstall = row.modelData.install
                        }
                      } }
                  }
                }
                Text { visible: parent.parent.cloud; text: "󰅟 Sends highlighted text to " + (parent.parent.modelData.vendor || parent.parent.modelData.name) + " · " + (parent.parent.modelData.model || "paid API"); color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
                Item {
                  width: parent.width; height: cloudUsage.implicitHeight; visible: parent.parent.cloud && parent.parent.modelData.status !== "nokey"
                  Text {
                    id: cloudUsage; anchors.left: parent.left; anchors.right: refreshUsage.left; anchors.rightMargin: 8
                    elide: Text.ElideRight; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
                    text: { var u = parent.parent.parent.modelData.usage || {}; var a = u.account || {}; var l = u.localObserved || {}; var r = (u.rateLimits || {}).requests || {}; var last = u.lastRequest || {}
                            if (last.outcome === "error") return (last.errorCode === "concurrency_limit" ? "Concurrency limit reached" : last.errorCode === "rate_limit" ? "Rate limit reached" : last.errorCode === "quota" ? "Credits or billing limit reached" : "Last request failed") + (last.retryAfter ? " · retry after " + last.retryAfter : "")
                            if (a.limit !== undefined) return (a.tier || "Plan") + " · " + a.used + " / " + a.limit + " characters" + (a.resetAt ? " · resets " + new Date(a.resetAt * 1000).toLocaleDateString() : "")
                            if (r.remaining !== undefined) return r.remaining + " / " + r.limit + " requests remain · resets " + r.reset
                            if (l.requests) return l.requests + " local requests · " + l.characters + " characters observed"
                            return "Usage appears after the first request" }
                  }
                  Text {
                    id: refreshUsage; anchors.right: parent.right; text: parent.parent.parent.modelData.name === "elevenlabs" ? (controller.refreshingUsage === parent.parent.parent.modelData.name ? "Refreshing…" : "Refresh usage") : "Updates after speech"
                    color: Color.accent; font.family: root.ff; font.pixelSize: Style.font.caption
                    MouseArea { anchors.fill: parent; enabled: parent.parent.parent.parent.modelData.name === "elevenlabs" && controller.refreshingUsage === ""; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: controller.refreshUsage(parent.parent.parent.parent.modelData.name) }
                  }
                }
                Text { visible: parent.parent.failing; width: parent.width; wrapMode: Text.WordWrap; text: parent.parent.cloudError === "auth" ? "The API key was rejected. Remove it and add a valid key, then test again." : "Installed, but it produced no audio when tested. Press Test to try again."; color: Color.urgent; font.family: root.ff; font.pixelSize: Style.font.caption }
                Text { visible: parent.parent.modelData.name === "kokoro" && !parent.parent.failing; text: "Heavy · slow first start after boot"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
              }
              MouseArea { anchors.fill: parent; enabled: parent.usable; z: 0; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: controller.selectProvider(parent.modelData.name) }
            }
          }
          Rectangle {
            width: parent.width; height: installCol.implicitHeight + 16; radius: 6; visible: root.confirmInstall !== ""; color: root.tint(0.08); border.width: 1; border.color: Color.popups.border
            Column {
              id: installCol; anchors.fill: parent; anchors.margins: 8; spacing: 6
              Text { text: "Install " + root.confirmProvider + "?"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.body }
              Text { width: parent.width; text: "The required packages will be installed for you. Administrator approval may appear for system packages."; wrapMode: Text.WordWrap; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
              Row { spacing: 8
                Button { text: "Cancel"; bordered: true; onClicked: { root.confirmInstall = ""; root.confirmProvider = "" } }
                Button { text: "Install"; bordered: true; foreground: Color.accent; onClicked: { controller.installProvider(root.confirmProvider); root.confirmInstall = ""; root.confirmProvider = "" } }
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
          ApiKeyDialog {
            width: parent.width; visible: root.apiProvider !== ""
            controller: controller; provider: root.apiProvider; vendor: root.apiVendor; foreground: root.fg
            onClosed: { root.apiProvider = ""; root.apiVendor = "" }
          }
          Text {
            width: parent.width
            visible: controller.setupJob.status === "running" || controller.setupJob.status === "starting" || controller.setupJob.status === "error"
            text: controller.setupJob.message; wrapMode: Text.WordWrap
            color: controller.setupJob.status === "error" ? Color.urgent : root.dim
            font.family: root.ff; font.pixelSize: Style.font.caption
          }
        }

        // Voice ------------------------------------------------------------
        Column {
          width: parent.width; spacing: Style.space(10); visible: !root.needsSetup && root.currentTab === 1 && !root.browsing
          PanelSectionHeader { text: "Voice"; foreground: root.fg }
          Dropdown { width: parent.width; showLabel: false; foreground: root.fg; options: root.voiceOptions.length ? root.voiceOptions : [{ label: "No voice installed", value: "" }]; value: controller.info.voice || ""; onValueChanged: if (value && value !== controller.info.voice && value !== "No voice installed") controller.setConfig(controller.info.voicePath || ".piper.voice", value) }
          Button { width: parent.width; text: controller.info.voices?.length ? "Browse all voices" : "Download a voice"; iconText: "󰇚"; bordered: true; foreground: controller.info.voices?.length ? root.fg : Color.accent; visible: !root.activeProvider || root.activeProvider.voices === "downloadable"; onClicked: { root.browsing = true; root.voiceFilter = ""; controller.loadCatalogue() } }
          Button { width: parent.width; text: controller.refreshingVoices ? "Refreshing voices…" : "Refresh cloud voices"; iconText: "󰑐"; bordered: true; foreground: root.fg; visible: root.activeProvider && root.activeProvider.name === "elevenlabs"; enabled: controller.refreshingVoices === ""; onClicked: controller.refreshVoices(root.activeProvider.name) }
          Item {
            width: parent.width; height: speedHeader.implicitHeight
            PanelSectionHeader { id: speedHeader; text: "Speed"; foreground: root.fg }
            Text { anchors.right: parent.right; text: root.rateValue.toFixed(2) + "×"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption }
          }
          Row { width: parent.width; spacing: 8
            Button { width: 32; text: "−"; bordered: true; onClicked: { var s = Math.max(.5, Math.round((root.rateValue - .1) * 20) / 20); root.rateOverride = s; controller.setConfig(".rate", s.toFixed(2)) } }
            // The knob tracks the raw pointer while the label shows the snapped
            // value, so on release it drifts to the step and eases there once
            // the config round-trip returns. Snapping liveValue as we go keeps
            // knob, label and stored value identical at every instant.
            PanelSlider {
              id: speedSlider
              width: parent.width - 80; bar: root.bar
              minimum: .5; maximum: 2; step: .05
              value: root.rateValue
              function snap(v) { return Math.round(v * 20) / 20 }
              // Track the drag in the override too: the label reads it, and it
              // makes `value` already correct when the drag ends.
              onMoved: function(v) { var s = speedSlider.snap(v); root.rateOverride = s; speedSlider.liveValue = s }
              onReleased: function(v) {
                var s = speedSlider.snap(v)
                root.rateOverride = s          // value is correct before liveValue resets to it
                controller.setConfig(".rate", s.toFixed(2))
              }
            }
            Button { width: 32; text: "+"; bordered: true; onClicked: { var s = Math.min(2, Math.round((root.rateValue + .1) * 20) / 20); root.rateOverride = s; controller.setConfig(".rate", s.toFixed(2)) } }
          }
          Item {
            width: parent.width; height: limitHeader.implicitHeight
            PanelSectionHeader { id: limitHeader; text: "Length limit"; foreground: root.fg }
            Text { anchors.right: parent.right; text: controller.info.maxChars > 0 ? "~" + Math.max(1, Math.round(controller.info.maxChars / 900)) + " min" : "unlimited"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
          }
          Row { width: parent.width; spacing: 8
            Button { width: 48; text: "−500"; bordered: true; onClicked: controller.setConfig(".maxChars", Math.max(0, Number(controller.info.maxChars)-500)) }
            TextField { width: parent.width - 112; text: String(controller.info.maxChars || 0); foreground: root.fg; onEditingFinished: controller.setConfig(".maxChars", Math.max(0, Number(text)||0)) }
            Button { width: 48; text: "+500"; bordered: true; onClicked: controller.setConfig(".maxChars", Number(controller.info.maxChars||0)+500) }
          }
        }
        Column {
          width: parent.width; spacing: 8; visible: !root.needsSetup && root.currentTab === 1 && root.browsing
          Item {
            width: parent.width; height: browseHeader.implicitHeight
            PanelSectionHeader { id: browseHeader; text: root.installedCount + " installed · " + ((controller.catalogue || []).length - root.installedCount) + " available"; foreground: root.fg }
            Text { anchors.right: parent.right; text: "Done"; color: Color.accent; font.family: root.ff; font.pixelSize: Style.font.caption; MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.browsing = false } }
          }
          TextField { width: parent.width; text: root.voiceFilter; foreground: root.fg; onTextChanged: root.voiceFilter = text }

          Row {
            width: parent.width; spacing: Style.space(12)
            Text { text: "Sort"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
                   anchors.verticalCenter: parent.verticalCenter }
            Repeater {
              model: root.voiceSorts
              delegate: Text {
                required property var modelData
                text: modelData.label
                color: root.voiceSort === modelData.key ? Color.accent : root.dim
                font.family: root.ff; font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: root.voiceSort = parent.modelData.key }
              }
            }
          }

          ListView {
            width: parent.width; height: Style.space(240); clip: true; model: root.filteredVoices; spacing: 2
            section.property: "group"
            section.criteria: ViewSection.FullString
            section.delegate: Item {
              required property string section
              width: ListView.view ? ListView.view.width : 0
              height: sectionLabel.implicitHeight + Style.space(10)
              Text {
                id: sectionLabel
                anchors.left: parent.left; anchors.leftMargin: Style.space(8)
                anchors.bottom: parent.bottom
                text: parent.section === "Installed"
                      ? "Installed — click to use, Remove to delete"
                      : "Available to download"
                color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
              }
            }
            delegate: Rectangle {
              required property var modelData
              readonly property bool busy: controller.download.status === "downloading" && controller.download.voice === modelData.key
              width: ListView.view.width; height: 42; radius: 5; color: modelData.installed ? root.tint(.07) : "transparent"
              Text { anchors.left: parent.left; anchors.right: parent.right; anchors.rightMargin: 112; anchors.leftMargin: 8; anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight; text: root.titleCase(String(parent.modelData.name).replace(/_/g, " ")) + " · " + parent.modelData.lang + " · " + parent.modelData.quality; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption }
              Text {
                id: voiceAction; z: 2; anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter
                text: parent.modelData.installed ? (parent.modelData.key === controller.info.voice ? "󰄬 Active" : "Remove") : (parent.busy ? controller.download.percent + "% · Cancel" : "󰇚 " + parent.modelData.sizeMB + " MB")
                color: parent.modelData.installed || parent.busy ? Color.accent : root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
                MouseArea { anchors.fill: parent; enabled: parent.parent.modelData.key !== controller.info.voice; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: { var row = parent.parent; if (row.busy) controller.cancelDownload(); else if (row.modelData.installed) root.confirmVoiceRemove = row.modelData.key; else controller.downloadVoice(row.modelData.key) } }
              }
              MouseArea { anchors.fill: parent; z: 1; enabled: parent.modelData.installed && parent.modelData.key !== controller.info.voice; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: controller.useVoice(parent.modelData.key) }
            }
          }
          Rectangle {
            width: parent.width; height: voiceRemoveRow.implicitHeight + 16; radius: 6
            visible: root.confirmVoiceRemove !== ""; color: root.tint(0.08); border.width: 1; border.color: Color.popups.border
            Row {
              id: voiceRemoveRow; anchors.fill: parent; anchors.margins: 8; spacing: 8
              Text { width: parent.width - cancelVoice.width - removeVoice.width - 24; elide: Text.ElideMiddle; text: "Remove " + root.voiceLabel(root.confirmVoiceRemove) + "?" + (root.removeSizeMB > 0 ? "  Frees " + root.removeSizeMB + " MB." : ""); color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption }
              Button { id: cancelVoice; text: "Cancel"; bordered: true; onClicked: root.confirmVoiceRemove = "" }
              Button { id: removeVoice; text: "Remove"; bordered: true; foreground: Color.urgent; onClicked: { controller.removeVoice(root.confirmVoiceRemove); root.confirmVoiceRemove = "" } }
            }
          }
          Text { text: "Storage: ~/.local/share/omarchy-tts/voices/piper"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
        }

        // Text -------------------------------------------------------------
        Column {
          width: parent.width; spacing: 8; visible: !root.needsSetup && root.currentTab === 2
          PanelSectionHeader { text: "What gets spoken"; foreground: root.fg }
          Row {
            width: parent.width; spacing: 8
            Rectangle { width: (parent.width - 8) / 2; height: 94; radius: 6; clip: true; color: Color.background; border.width: 1; border.color: Color.popups.border; TextArea { anchors.fill: parent; anchors.margins: 6; text: root.previewSource; color: root.dim; wrapMode: TextEdit.Wrap; clip: true; background: null; onTextChanged: { root.previewSource = text; previewDelay.restart() } } }
            Rectangle { width: (parent.width - 8) / 2; height: 94; radius: 6; clip: true; color: root.tint(.06); border.width: 1; border.color: Color.popups.border; Text { anchors.fill: parent; anchors.margins: 6; text: controller.preview || "Spoken preview"; color: root.fg; wrapMode: Text.WordWrap; clip: true; elide: Text.ElideRight; maximumLineCount: 5; font.family: root.ff; font.pixelSize: Style.font.caption } }
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
          width: parent.width; spacing: 10; visible: !root.needsSetup && root.currentTab === 3
          PanelSectionHeader { text: "Reading the screen"; foreground: root.fg }
          Text { width: parent.width; wrapMode: Text.WordWrap; text: "Region, focused-window and focused-monitor OCR stay local. Recognised text only leaves your computer when a cloud speech provider is active."; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
          Item {
            width: parent.width; height: ocrHeader.implicitHeight
            PanelSectionHeader { id: ocrHeader; text: "Confidence floor"; foreground: root.fg }
            Text { anchors.right: parent.right; text: root.confidenceValue > 0 ? root.confidenceValue + "%" : "keep everything"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.caption }
          }
          PanelSlider {
            id: confidenceSlider
            width: parent.width; bar: root.bar
            minimum: 0; maximum: 95; step: 5; integer: true
            value: root.confidenceValue
            function snap(v) { return Math.round(v / 5) * 5 }
            onMoved: function(v) { var s = confidenceSlider.snap(v); root.confidenceOverride = s; confidenceSlider.liveValue = s }
            onReleased: function(v) {
              var s = confidenceSlider.snap(v)
              root.confidenceOverride = s
              controller.setConfig(".ocr.minConfidence", s)
            }
          }
          TextField { width: parent.width; text: controller.info.ocr?.langs || "eng"; foreground: root.fg; onEditingFinished: controller.setConfig(".ocr.langs", text) }
          Text { width: parent.width; wrapMode: Text.WordWrap; text: "Tesseract language codes joined with + (for example eng+fra). Install the corresponding language data first."; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
        }

        // Keys -------------------------------------------------------------
        Column {
          width: parent.width; spacing: 4; visible: !root.needsSetup && root.currentTab === 4
          Item {
            width: parent.width; height: keysHeader.implicitHeight
            PanelSectionHeader { id: keysHeader; text: "Keybindings"; foreground: root.fg }
            Text {
              anchors.right: parent.right
              // "Not installed" beside six shortcuts that plainly work is a
              // contradiction. Unmanaged is a third state, not a broken one.
              text: controller.bindings.installed ? "● Managed"
                    : (root.adoptableCount > 0
                       ? root.adoptableCount + " already set up"
                       : "Not set up")
              color: controller.bindings.installed ? Color.accent
                     : (root.adoptableCount > 0 ? root.fg : root.dim)
              font.family: root.ff; font.pixelSize: Style.font.caption
            }
          }
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
            Button {
              width: controller.bindings.installed ? (parent.width - 8)/2 : parent.width
              text: controller.bindings.installed ? "Apply changes"
                    : (root.adoptableCount > 0 ? "Take over these shortcuts" : "Set up shortcuts")
              bordered: true; foreground: Color.accent
              enabled: controller.bindings.canInstall !== false
              onClicked: controller.installBindings()
            }
            Button {
              width: (parent.width - 8)/2
              visible: controller.bindings.installed
              text: "Remove shortcuts"; bordered: true; foreground: Color.urgent
              onClicked: controller.removeBindings()
            }
          }
          Text {
            width: parent.width; wrapMode: Text.WordWrap
            visible: !controller.bindings.installed && root.adoptableCount > 0
            text: "These shortcuts already work; they were written by hand rather than by this panel. Taking them over lets you change them here. Nothing is duplicated."
            color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption
          }
          Text { width: parent.width; wrapMode: Text.WordWrap; text: "Only the marked omarchy-tts block in bindings.lua is managed. Every write is backed up and rolled back if Hyprland reports an error."; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
          Text { width: parent.width; visible: (controller.bindings.conflicts || []).length > 0; wrapMode: Text.WordWrap; text: "Resolve these shortcuts first: " + controller.bindings.conflicts.join(", "); color: Color.urgent; font.family: root.ff; font.pixelSize: Style.font.caption }
        }

        Rectangle {
          width: parent.width; height: captureColumn.implicitHeight + 16; radius: 7; visible: root.captureAction !== ""; color: Color.background; border.width: 1; border.color: Color.accent
          Column { id: captureColumn; anchors.fill: parent; anchors.margins: 8; spacing: 6
            Text { text: "Press the new shortcut for “" + root.captureAction + "”"; color: root.fg; font.family: root.ff; font.pixelSize: Style.font.body }
            Text { text: root.capturedChord || "Waiting for keys…"; color: Color.accent; font.family: root.ff; font.pixelSize: Style.font.subtitle }
            Row { spacing: 8
              Button { text: "Cancel"; bordered: true; onClicked: { root.captureAction = ""; root.capturedChord = "" } }
              Button { text: "Use shortcut"; bordered: true; enabled: root.capturedChord !== ""; foreground: Color.accent; onClicked: { controller.setBinding(root.captureAction, root.capturedChord); root.captureAction = ""; root.capturedChord = "" } }
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }
        Column {
          width: parent.width; spacing: 8; visible: !root.needsSetup
          Item {
            width: parent.width; height: testHeader.implicitHeight
            PanelSectionHeader { id: testHeader; text: "Test"; foreground: root.fg }
            Text { anchors.right: parent.right; text: root.activeIsCloud ? "󰅟 sample sent to " + (root.activeProvider.vendor || root.activeProvider.name) : "runs locally"; color: root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
          }
          Row { width: parent.width; spacing: 8
            TextField { id: sampleField; width: parent.width - testButton.width - 8; text: root.sampleText; foreground: root.fg; selectByMouse: true; onTextChanged: root.sampleText = text; onEditingFinished: controller.setConfig(".ui.sampleText", text) }
            Button { id: testButton; width: 96; text: controller.speaking ? "Stop" : "Speak"; iconText: controller.speaking ? "󰓛" : "󰐊"; bordered: true; foreground: controller.speaking ? Color.urgent : root.fg; accent: controller.speaking ? Color.urgent : Color.accent; onClicked: controller.speaking ? controller.stop() : controller.speak(root.sampleText) }
          }
          Text { width: parent.width; elide: Text.ElideRight; text: (controller.speaking ? "● Speaking · " : "") + (controller.info.provider || "") + (controller.info.voice ? " · " + root.activeVoiceLabel() : "") + " · " + Number(controller.info.rate || 1).toFixed(2) + "×" + (controller.info.maxChars > 0 ? " · ≤" + controller.info.maxChars + " chars" : ""); color: controller.speaking ? Color.accent : root.dim; font.family: root.ff; font.pixelSize: Style.font.caption }
          Text { width: parent.width; visible: controller.error !== ""; text: controller.error; wrapMode: Text.WordWrap; color: Color.urgent; font.family: root.ff; font.pixelSize: Style.font.caption }
        }
      }
    }
  }
}
