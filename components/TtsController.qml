import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root
  visible: false

  readonly property string home: Quickshell.env("HOME")
  // Run the plugin-local tools so the panel works even before optional CLI
  // symlinks are created in ~/.local/bin.
  readonly property string speakBin: String(Qt.resolvedUrl("../bin/speak")).replace("file://", "")
  readonly property string voiceBin: String(Qt.resolvedUrl("../bin/speak-voice")).replace("file://", "")
  readonly property string bindingsBin: String(Qt.resolvedUrl("../bin/speak-bindings")).replace("file://", "")

  property var info: ({ providers: [], voices: [], ocr: {}, sanitizer: {}, ui: {} })
  property var catalogue: []
  property var download: ({ status: "idle", voice: "", percent: 0 })
  property var bindings: ({ installed: false, bindings: {} })
  property string preview: ""
  property string selectionText: ""
  property string error: ""

  signal actionFinished

  function restart(process) { process.running = false; process.running = true }
  function refresh() { restart(infoProc) }
  function refreshBindings() { restart(bindingsProc) }
  function loadCatalogue() { restart(catalogueProc) }
  function loadSelection() { restart(selectionProc) }

  function action(argv) {
    error = ""
    actionProc.running = false
    actionProc.command = argv
    actionProc.running = true
  }
  function setConfig(path, value) { action([speakBin, "--set", path, String(value)]) }
  function speak(text) { action([speakBin, "--raw", "--", text]) }
  function stop() { action([speakBin, "--stop"]) }
  function selectProvider(name) { setConfig(".provider", name) }
  function previewText(text) {
    previewProc.running = false
    previewProc.command = [speakBin, "--preview-text", text]
    previewProc.running = true
  }
  function downloadVoice(key) {
    action([voiceBin, "add", key, "--async"])
    download = { status: "downloading", voice: key, percent: 0 }
    downloadPoll.running = true
  }
  function installBindings() { action([bindingsBin, "install"]) }
  function removeBindings() { action([bindingsBin, "remove"]) }
  function setBinding(actionName, chord) { action([bindingsBin, "set", actionName, chord]) }
  function installProvider(command) {
    if (!command) return
    Quickshell.execDetached(["omarchy", "launch", "terminal", "bash", "-lc",
      command + "; printf '\\nPress Enter to close…'; read -r"])
  }
  function storeKey(provider) {
    var safe = provider === "openai" ? "openai" : (provider === "elevenlabs" ? "elevenlabs" : "")
    if (!safe) return
    var script = "read -rsp 'Paste API key: ' key; echo; "
      + "printf '%s' \"$key\" | secret-tool store --label='omarchy-tts " + safe
      + "' service omarchy-tts key " + safe
      + " && echo 'Key stored in the system keyring.' || echo 'Could not store the key.'; "
      + "unset key; read -rp 'Press Enter to close…'"
    Quickshell.execDetached(["omarchy", "launch", "terminal", "bash", "-lc", script])
  }
  function removeKey(provider) {
    if (provider !== "openai" && provider !== "elevenlabs") return
    action(["secret-tool", "clear", "service", "omarchy-tts", "key", provider])
  }

  Process {
    id: selectionProc
    command: ["wl-paste", "--primary", "--no-newline"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim()) root.selectionText = text
    }
  }
  Process {
    id: infoProc
    command: [root.speakBin, "--info"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.info = JSON.parse(text); root.error = "" }
        catch (e) { root.error = "Could not read TTS settings" }
      }
    }
  }
  Process {
    id: actionProc
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim()) root.error = text.trim()
    }
    onRunningChanged: if (!running) {
      root.refresh(); root.refreshBindings(); root.actionFinished()
    }
  }
  Process {
    id: previewProc
    command: []
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.preview = text.trim()
    }
  }
  Process {
    id: catalogueProc
    command: [root.voiceBin, "available", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.catalogue = JSON.parse(text) }
        catch (e) { root.catalogue = [] }
      }
    }
  }
  Process {
    id: downloadStatusProc
    command: [root.voiceBin, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.download = JSON.parse(text)
          if (root.download.status === "done" || root.download.status === "error") {
            downloadPoll.running = false; root.loadCatalogue(); root.refresh()
          }
        } catch (e) {}
      }
    }
  }
  Process {
    id: bindingsProc
    command: [root.bindingsBin, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.bindings = JSON.parse(text) }
        catch (e) { root.bindings = { installed: false, bindings: {} } }
      }
    }
  }
  Timer {
    id: downloadPoll
    interval: 500; repeat: true; running: false
    onTriggered: root.restart(downloadStatusProc)
  }
}
