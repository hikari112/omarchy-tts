import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root
  visible: false

  readonly property string speakBin: String(Qt.resolvedUrl("../bin/speak")).replace("file://", "")
  readonly property string voiceBin: String(Qt.resolvedUrl("../bin/speak-voice")).replace("file://", "")
  readonly property string bindingsBin: String(Qt.resolvedUrl("../bin/speak-bindings")).replace("file://", "")
  readonly property string setupBin: String(Qt.resolvedUrl("../bin/speak-setup")).replace("file://", "")
  property var info: ({ providers: [], voices: [], ocr: {}, sanitizer: {}, ui: {} })
  property var catalogue: []
  property var download: ({ status: "idle", voice: "", percent: 0 })
  property var bindings: ({ installed: false, bindings: {}, conflicts: [], canInstall: true })
  property var setup: ({ ready: false, engineReady: false, voiceReady: false })
  property var setupJob: ({ status: "idle", step: "", progress: 0, message: "" })
  property var keyResult: ({ ok: false, message: "" })
  property string preview: ""
  property string error: ""
  property string verifying: ""
  property string refreshingUsage: ""
  property string refreshingVoices: ""
  property string pendingKey: ""
  property string pendingKeyProvider: ""
  property bool keySaving: false
  property bool speaking: false
  signal actionFinished

  function restart(process) { process.running = false; process.running = true }

  // `speak --info` takes about 200 ms. Restarting it while it is still
  // writing truncates its output, and half a JSON document does not parse -
  // which is how moving a slider twice in quick succession produced "Could
  // not read TTS settings". Reads are queued instead of killed.
  property bool infoQueued: false
  property bool infoLoaded: false

  // A read started before a write can finish after it, and would then report
  // the value we just replaced - which is how a slider ends up showing the
  // old number again a moment after being moved. Each read records the write
  // count it started under; if that count has moved on, the answer describes
  // a config that no longer exists and is thrown away.
  property int writeEpoch: 0
  property int readEpoch: 0

  function refresh() {
    if (infoProc.running) { infoQueued = true; return }
    readEpoch = writeEpoch
    infoProc.running = true
  }
  function refreshBindings() { if (!bindingsProc.running) bindingsProc.running = true }
  function refreshSetup() {
    if (!setupStatusProc.running) setupStatusProc.running = true
    if (!setupJobProc.running) setupJobProc.running = true
  }
  function loadCatalogue() { restart(catalogueProc) }
  function action(argv) {
    if (actionProc.running) {
      error = "Another TTS action is still finishing. Please try again."
      return false
    }
    error = ""
    actionProc.command = argv
    actionProc.running = true
    return true
  }
  // Writing a setting cannot change keybindings or install state, so only the
  // settings themselves are re-read. Three processes per slider release was
  // most of what made the race easy to hit.
  property var configQueue: []
  function runNextConfig() {
    if (configProc.running || configQueue.length === 0) return
    var queue = configQueue.slice()
    var next = queue.shift()
    configQueue = queue
    configProc.command = [speakBin, "--set", next.path, next.value]
    configProc.running = true
  }
  function setConfig(path, value) {
    error = ""
    writeEpoch++
    var queue = configQueue.slice()
    // Slider drags can enqueue the same property repeatedly. Keep the newest
    // pending value while preserving writes to unrelated settings.
    for (var i = queue.length - 1; i >= 0; --i) {
      if (queue[i].path === path) { queue.splice(i, 1); break }
    }
    queue.push({ path: path, value: String(value) })
    configQueue = queue
    runNextConfig()
  }
  function speak(text) { speechProc.command = [speakBin, "--raw", "--", text]; restart(speechProc) }
  function stop() { speechProc.command = [speakBin, "--stop"]; restart(speechProc) }
  function selectProvider(name) { setConfig(".provider", name) }
  // Proving a backend takes seconds and makes no sound; `verifying` lets the
  // panel say so rather than appearing to have ignored the click.
  function verifyProvider(name) { verifying = name; verifyProc.command = [speakBin, "--verify", name]; restart(verifyProc) }
  function refreshUsage(name) { refreshingUsage = name; usageProc.command = [speakBin, "--usage", name]; restart(usageProc) }
  function refreshVoices(name) { refreshingVoices = name; voiceRefreshProc.command = [speakBin, "--refresh-voices", name]; restart(voiceRefreshProc) }
  function previewText(text) { previewProc.command = [speakBin, "--preview-text", text]; restart(previewProc) }
  function downloadVoice(key) { if (action([voiceBin, "add", key, "--async"])) { download = { status: "downloading", voice: key, percent: 0 }; downloadPoll.running = true } }
  function cancelDownload() { action([voiceBin, "cancel"]) }
  function useVoice(key) { action([voiceBin, "use", key]) }
  function removeVoice(key) { action([voiceBin, "remove", key]) }
  function installBindings() { action([bindingsBin, "install"]) }
  function removeBindings() { action([bindingsBin, "remove"]) }
  function setBinding(actionName, chord) { action([bindingsBin, "set", actionName, chord]) }
  function startSetup(target) { error = ""; setupStartProc.command = [setupBin, "start", target]; restart(setupStartProc); setupJob = { status: "starting", step: "prepare", progress: 1, message: "Preparing setup" }; setupJobPoll.running = true }
  function installProvider(provider) {
    var targets = ({ "piper": "piper", "kokoro": "kokoro", "espeak-ng": "espeak-ng", "spd": "spd" })
    if (targets[provider]) startSetup(targets[provider])
  }
  function cancelSetup() { action([setupBin, "cancel"]) }
  function storeKey(provider, key) {
    if ((provider !== "openai" && provider !== "elevenlabs") || key.length < 8) return
    pendingKey = key; pendingKeyProvider = provider; keySaving = true; keyResult = { ok: false, message: "" }
    keyProc.command = [setupBin, "key-store", provider]; restart(keyProc)
  }
  function removeKey(provider) { if (provider === "openai" || provider === "elevenlabs") action([setupBin, "key-remove", provider]) }

  Process {
    id: configProc; command: []
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim()) root.error = text.trim() }
    onRunningChanged: if (!running) {
      if (root.configQueue.length > 0) Qt.callLater(root.runNextConfig)
      else root.refresh()
    }
  }
  Process {
    id: infoProc; command: [root.speakBin, "--info"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.readEpoch !== root.writeEpoch) {
          root.infoQueued = true      // answered a question we have since changed
          return
        }
        try {
          root.info = JSON.parse(text)
          root.infoLoaded = true
          root.error = ""
        } catch (e) {
          // Only alarm the user if we have never managed to read settings at
          // all; a transient truncation just gets retried.
          if (!root.infoLoaded) root.error = "Could not read TTS settings"
          root.infoQueued = true
        }
      }
    }
    onRunningChanged: if (!running && root.infoQueued) { root.infoQueued = false; Qt.callLater(root.refresh) }
  }
  Process { id: speechProc; command: []; stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim()) root.error = text.trim() } }
  Process { id: speechWatch; running: true; command: [root.speakBin, "--watch-status"]; stdout: SplitParser { splitMarker: "\n"; onRead: function(data) { root.speaking = data.trim() === "speaking" } } }
  Process {
    id: verifyProc; command: []
    stderr: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) { root.verifying = ""; root.refresh() }
  }
  Process {
    id: usageProc; command: []
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim()) root.error = text.trim() }
    onRunningChanged: if (!running) { root.refreshingUsage = ""; root.refresh() }
  }
  Process {
    id: voiceRefreshProc; command: []
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim()) root.error = text.trim() }
    onRunningChanged: if (!running) { root.refreshingVoices = ""; root.refresh() }
  }
  Process {
    id: actionProc; command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim()) root.error = text.trim() }
    onRunningChanged: if (!running) { root.refresh(); root.refreshBindings(); root.refreshSetup(); root.actionFinished() }
  }
  Process { id: previewProc; command: []; stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.preview = text.trim() } }
  Process { id: catalogueProc; command: [root.voiceBin, "available", "--json"]; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { try { root.catalogue = JSON.parse(text) } catch (e) { root.catalogue = [] } } } }
  Process {
    id: downloadStatusProc; command: [root.voiceBin, "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: { try { root.download = JSON.parse(text); if (["done", "error", "cancelled"].indexOf(root.download.status) >= 0) { downloadPoll.running = false; root.loadCatalogue(); root.refresh() } } catch (e) {} } }
  }
  Process { id: bindingsProc; command: [root.bindingsBin, "status"]; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { try { root.bindings = JSON.parse(text) } catch (e) { root.bindings = { installed: false, bindings: {}, conflicts: [], canInstall: false } } } } }
  Process { id: setupStatusProc; command: [root.setupBin, "status"]; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { try { root.setup = JSON.parse(text) } catch (e) {} } } }
  Process { id: setupStartProc; command: []; stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim()) root.error = text.trim() } }
  Process {
    id: setupJobProc; command: [root.setupBin, "job"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: { try { root.setupJob = JSON.parse(text); if (["done", "error", "cancelled"].indexOf(root.setupJob.status) >= 0) { setupJobPoll.running = false; root.restart(setupStatusProc); root.refresh(); root.loadCatalogue() } } catch (e) {} } }
  }
  Process {
    id: keyProc; command: []; stdinEnabled: true
    onStarted: { write(root.pendingKey + "\n"); root.pendingKey = "" }
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: { try { var result = JSON.parse(text); root.keyResult = { ok: result.ok === true, message: result.ok ? "Key saved securely." : (result.message || "Could not save the key.") } } catch (e) { root.keyResult = { ok: false, message: "Could not save the key." } } } }
    onRunningChanged: if (!running) { root.keySaving = false; if (root.keyResult.ok && root.pendingKeyProvider === "elevenlabs") root.refreshVoices(root.pendingKeyProvider); root.pendingKeyProvider = ""; root.refresh() }
  }
  Timer { id: downloadPoll; interval: 500; repeat: true; running: false; onTriggered: root.restart(downloadStatusProc) }
  Timer { id: setupJobPoll; interval: 650; repeat: true; running: false; onTriggered: root.restart(setupJobProc) }
}
