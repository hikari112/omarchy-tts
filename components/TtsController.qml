import QtQuick
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
  property bool downloadStarting: false
  property string pendingDownloadVoice: ""
  property bool setupStarting: false
  property string pendingKey: ""
  property string pendingKeyProvider: ""
  property string pendingKeyPurpose: "speech"
  property bool keySaving: false
  property var statusSource: null
  property bool watchedSpeaking: false
  readonly property bool speaking: statusSource
                                   ? statusSource.speaking === true
                                   : watchedSpeaking
  readonly property bool setupCancellable:
    (setupJob.status === "starting" || setupJob.status === "running")
    && Number(setupJob.pid || 0) > 1 && String(setupJob.processIdentity || "") !== ""
  readonly property bool downloadCancellable:
    (download.status === "starting" || download.status === "downloading")
    && Number(download.pid || 0) > 1 && String(download.processIdentity || "") !== ""
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
  function speak(text) { error = ""; speechProc.command = [speakBin, "--", text]; restart(speechProc) }
  function stop() { error = ""; speechProc.command = [speakBin, "--stop"]; restart(speechProc) }
  function selectProvider(name) { setConfig(".provider", name) }
  // Proving a backend takes seconds and makes no sound; `verifying` lets the
  // panel say so rather than appearing to have ignored the click.
  function verifyProvider(name) { error = ""; verifying = name; verifyProc.command = [speakBin, "--verify", name]; restart(verifyProc) }
  function verifyOcrEngine(name) { error = ""; verifying = "ocr:" + name; verifyProc.command = [speakBin, "--verify-ocr", name]; restart(verifyProc) }
  function selectOcrEngine(name) { setConfig(".ocr.engine", name) }
  function refreshUsage(name) { error = ""; refreshingUsage = name; usageProc.command = [speakBin, "--usage", name]; restart(usageProc) }
  property string refreshingLanguages: ""
  function refreshLanguages(engine) { error = ""; refreshingLanguages = engine; languageRefreshProc.command = [speakBin, "--refresh-languages", engine]; restart(languageRefreshProc) }
  function installLanguage(code) { startSetup("lang:" + code) }
  function refreshVoices(name) { error = ""; refreshingVoices = name; voiceRefreshProc.command = [speakBin, "--refresh-voices", name]; restart(voiceRefreshProc) }
  function providerSupportsVoiceRefresh(name) {
    var providers = info.providers || []
    for (var i = 0; i < providers.length; ++i)
      if (providers[i].name === name) return providers[i].refreshVoices === true
    return false
  }
  function previewText(text) { previewProc.command = [speakBin, "--preview-text", text]; restart(previewProc) }
  function downloadVoice(key) {
    if (downloadStartProc.running || actionProc.running) {
      error = "Another TTS action is still finishing. Please try again."
      return
    }
    error = ""
    downloadStarting = true
    pendingDownloadVoice = key
    downloadStartProc.command = [voiceBin, "add", key, "--async"]
    downloadStartProc.running = true
  }
  function cancelDownload() {
    if (downloadCancellable) action([voiceBin, "cancel"])
  }
  function useVoice(key) { action([voiceBin, "use", key]) }
  function removeVoice(key) { action([voiceBin, "remove", key]) }
  function installBindings() { action([bindingsBin, "install"]) }
  function removeBindings() { action([bindingsBin, "remove"]) }
  function setBinding(actionName, chord) { action([bindingsBin, "set", actionName, chord]) }
  function startSetup(target) {
    if (setupStartProc.running || setupStarting) return
    error = ""
    setupStarting = true
    setupStartProc.command = [setupBin, "start", target]
    setupStartProc.running = true
  }
  function installProvider(provider) {
    var targets = ({ "piper": "piper", "kokoro": "kokoro", "easyocr": "easyocr" })
    if (targets[provider]) startSetup(targets[provider])
  }
  function cancelSetup() { if (setupCancellable) action([setupBin, "cancel"]) }
  function storeKey(provider, key, purpose) {
    if (["openai", "elevenlabs", "google", "gemini"].indexOf(provider) < 0 || key.length < 8) return
    error = ""
    pendingKey = key; pendingKeyProvider = provider; pendingKeyPurpose = purpose || "speech"
    keySaving = true; keyResult = { ok: false, message: "" }
    keyProc.command = [setupBin, "key-store", provider]; restart(keyProc)
  }
  function removeKey(provider) { if (["openai", "elevenlabs", "google", "gemini"].indexOf(provider) >= 0) action([setupBin, "key-remove", provider]) }

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
  // The bar already owns a status stream. Reuse it when hosted there, while
  // retaining a fallback for standalone panel development.
  Process { id: speechWatch; running: root.statusSource === null; command: [root.speakBin, "--watch-status"]; stdout: SplitParser { splitMarker: "\n"; onRead: function(data) { root.watchedSpeaking = data.trim() === "speaking" } } }
  Process {
    id: verifyProc; command: []
    stdout: StdioCollector { id: verifyStdout; waitForEnd: true }
    stderr: StdioCollector { id: verifyStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.error = String(verifyStderr.text || verifyStdout.text || "Test failed").trim()
      root.verifying = ""; root.refresh()
    }
  }
  Process {
    id: usageProc; command: []
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim()) root.error = text.trim() }
    onRunningChanged: if (!running) { root.refreshingUsage = ""; root.refresh() }
  }
  Process {
    id: languageRefreshProc; command: []
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim()) root.error = text.trim() }
    onRunningChanged: if (!running) { root.refreshingLanguages = ""; root.refresh() }
  }
  Process {
    id: voiceRefreshProc; command: []
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim()) root.error = text.trim() }
    onRunningChanged: if (!running) { root.refreshingVoices = ""; root.refresh() }
  }
  Process {
    id: actionProc; command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var stdout = String(actionStdout.text || "").trim()
      var stderr = String(actionStderr.text || "").trim()
      if (exitCode !== 0) root.error = stderr || stdout || "The TTS action failed."
      else if (stdout.charAt(0) === "{") {
        try {
          var result = JSON.parse(stdout)
          if (result.ok === false) root.error = result.message || "The TTS action failed."
        } catch (e) {}
      }
      root.refresh(); root.refreshBindings(); root.refreshSetup(); root.actionFinished()
    }
  }
  Process { id: previewProc; command: []; stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.preview = text.trim() } }
  Process { id: catalogueProc; command: [root.voiceBin, "available", "--json"]; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { try { root.catalogue = JSON.parse(text) } catch (e) { root.catalogue = [] } } } }
  Process {
    id: downloadStatusProc; command: [root.voiceBin, "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: { try { root.download = JSON.parse(text); root.pendingDownloadVoice = ""; if (["done", "error", "cancelled"].indexOf(root.download.status) >= 0) { downloadPoll.running = false; root.loadCatalogue(); root.refresh() } } catch (e) {} } }
  }
  Process {
    id: downloadStartProc; command: []
    stdout: StdioCollector { id: downloadStartStdout; waitForEnd: true }
    stderr: StdioCollector { id: downloadStartStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.downloadStarting = false
      var stdout = String(downloadStartStdout.text || "").trim()
      var stderr = String(downloadStartStderr.text || "").trim()
      if (exitCode !== 0 || stdout !== "started") {
        // The backend is authoritative. If another panel invocation already
        // owns the job, reconnect to it instead of presenting a false failure.
        if (stderr.indexOf("already running") >= 0) {
          root.pendingDownloadVoice = ""
          root.restart(downloadStatusProc)
          downloadPoll.running = true
          return
        }
        root.error = stderr || "Could not start the voice download."
        root.pendingDownloadVoice = ""
        return
      }
      root.restart(downloadStatusProc)
      downloadPoll.running = true
    }
  }
  Process { id: bindingsProc; command: [root.bindingsBin, "status"]; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { try { root.bindings = JSON.parse(text) } catch (e) { root.bindings = { installed: false, bindings: {}, conflicts: [], canInstall: false } } } } }
  Process { id: setupStatusProc; command: [root.setupBin, "status"]; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { try { root.setup = JSON.parse(text) } catch (e) {} } } }
  Process {
    id: setupStartProc; command: []
    stdout: StdioCollector { id: setupStartStdout; waitForEnd: true }
    stderr: StdioCollector { id: setupStartStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.setupStarting = false
      var result = null
      try { result = JSON.parse(String(setupStartStdout.text || "")) } catch (e) {}
      if (exitCode !== 0 || !result || result.ok !== true) {
        if (result && result.code === "already_running") {
          root.restart(setupJobProc)
          setupJobPoll.running = true
          return
        }
        root.error = (result && result.message) || String(setupStartStderr.text || "Could not start setup.").trim()
        root.setupJob = { status: "error", step: "failed", progress: 0, message: root.error }
        return
      }
      root.setupJob = { status: "starting", step: "prepare", progress: 1,
                        message: "Preparing setup", pid: result.pid,
                        processIdentity: result.processIdentity || "" }
      root.restart(setupJobProc)
      setupJobPoll.running = true
    }
  }
  Process {
    id: setupJobProc; command: [root.setupBin, "job"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: { try { root.setupJob = JSON.parse(text); if (["done", "error", "cancelled"].indexOf(root.setupJob.status) >= 0) { setupJobPoll.running = false; root.restart(setupStatusProc); root.refresh(); root.loadCatalogue() } } catch (e) {} } }
  }
  Process {
    id: keyProc; command: []; stdinEnabled: true
    onStarted: { write(root.pendingKey + "\n"); root.pendingKey = "" }
    stdout: StdioCollector { id: keyStdout; waitForEnd: true }
    stderr: StdioCollector { id: keyStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var result = null
      try { result = JSON.parse(String(keyStdout.text || "")) } catch (e) {}
      var ok = exitCode === 0 && result && result.ok === true
      root.keyResult = {
        ok: ok,
        message: ok ? ("Key saved securely." + (result.warning ? " " + result.warning : ""))
                    : ((result && result.message) || String(keyStderr.text || "Could not save the key.").trim())
      }
      root.keySaving = false
      if (ok && root.pendingKeyPurpose === "speech"
          && root.providerSupportsVoiceRefresh(root.pendingKeyProvider))
        root.refreshVoices(root.pendingKeyProvider)
      root.pendingKey = ""
      root.pendingKeyProvider = ""
      root.pendingKeyPurpose = "speech"
      root.refresh()
    }
  }
  Timer { id: downloadPoll; interval: 500; repeat: true; running: false; onTriggered: root.restart(downloadStatusProc) }
  Timer { id: setupJobPoll; interval: 650; repeat: true; running: false; onTriggered: root.restart(setupJobProc) }
}
