import QtQuick
import Quickshell.Io

Item {
  id: root
  visible: false

  function localPath(url) {
    var value = String(url)
    return value.indexOf("file://") === 0 ? decodeURIComponent(value.slice(7)) : value
  }
  readonly property string speakBin: localPath(Qt.resolvedUrl("../bin/speak"))
  readonly property string voiceBin: localPath(Qt.resolvedUrl("../bin/speak-voice"))
  readonly property string bindingsBin: localPath(Qt.resolvedUrl("../bin/speak-bindings"))
  readonly property string setupBin: localPath(Qt.resolvedUrl("../bin/speak-setup"))
  property var info: ({ providers: [], voices: [], ocr: {}, sanitizer: {}, ui: {} })
  property var catalogue: []
  property bool catalogueLoading: false
  property var download: ({ status: "idle", voice: "", percent: 0 })
  property var bindings: ({ installed: false, bindings: {}, conflicts: [], canInstall: true })
  property var setup: ({ ready: false, engineReady: false, voiceReady: false })
  property bool setupLoaded: false
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
  property string pendingSpeech: ""
  property string pendingPreview: ""
  property string pendingConfigValue: ""
  property var statusSource: null
  property bool watchedSpeaking: false
  readonly property bool speaking: statusSource
                                   ? statusSource.speaking === true
                                   : watchedSpeaking
  readonly property bool setupCancellable:
    (setupJob.status === "starting" || setupJob.status === "running")
    && setupJob.cancellable !== false
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
  property bool catalogueQueued: false
  property bool previewQueued: false

  // A read started before a write can finish after it, and would then report
  // the value we just replaced - which is how a slider ends up showing the
  // old number again a moment after being moved. Each read records the write
  // count it started under; if that count has moved on, the answer describes
  // a config that no longer exists and is thrown away.
  property int writeEpoch: 0
  property int readEpoch: 0

  function refresh() {
    // A read that starts while a queued write is still running can carry the
    // new epoch but the old bytes, so the epoch check alone cannot reject it.
    if (infoProc.running || configProc.running || configQueue.length > 0) {
      infoQueued = true
      return
    }
    infoQueued = false
    readEpoch = writeEpoch
    infoProc.running = true
  }
  function refreshBindings() { if (!bindingsProc.running) bindingsProc.running = true }
  function refreshSetup() {
    if (!setupStatusProc.running) setupStatusProc.running = true
    if (!setupJobProc.running) setupJobProc.running = true
  }
  function refreshDownload() { if (!downloadStatusProc.running) downloadStatusProc.running = true }
  function loadCatalogue() {
    error = ""
    catalogueLoading = true
    if (catalogueProc.running) {
      catalogueQueued = true
      return
    }
    catalogueProc.running = true
  }
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
    pendingConfigValue = JSON.stringify(next.value)
    configProc.command = [speakBin, "--set-stdin-json", next.path]
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
  function speak(text) { error = ""; pendingSpeech = String(text).slice(0, 4096); speechProc.command = [speakBin, "--stdin-json"]; restart(speechProc) }
  function stop() { error = ""; speechProc.command = [speakBin, "--stop"]; restart(speechProc) }
  function selectProvider(name) { setConfig(".provider", name) }
  // Proving a backend takes seconds and makes no sound; `verifying` lets the
  // panel say so rather than appearing to have ignored the click.
  function verifyProvider(name) {
    error = ""
    if (verifyProc.running) { error = "Another backend test is still running."; return }
    verifying = name; verifyProc.command = [speakBin, "--verify", name]; verifyProc.running = true
  }
  function verifyOcrEngine(name) {
    error = ""
    if (verifyProc.running) { error = "Another backend test is still running."; return }
    verifying = "ocr:" + name; verifyProc.command = [speakBin, "--verify-ocr", name]; verifyProc.running = true
  }
  function selectOcrEngine(name) { setConfig(".ocr.engine", name) }
  function refreshUsage(name) {
    error = ""
    if (usageProc.running) { error = "Usage is already being refreshed."; return }
    refreshingUsage = name; usageProc.command = [speakBin, "--usage", name]; usageProc.running = true
  }
  property string refreshingLanguages: ""
  function refreshLanguages(engine) {
    error = ""
    if (languageRefreshProc.running) { error = "Languages are already being refreshed."; return }
    refreshingLanguages = engine
    languageRefreshProc.command = [speakBin, "--refresh-languages", engine]
    languageRefreshProc.running = true
  }
  function installLanguage(code) { startSetup("lang:" + code) }
  function refreshVoices(name) {
    error = ""
    if (voiceRefreshProc.running) { error = "Voices are already being refreshed."; return }
    refreshingVoices = name
    voiceRefreshProc.command = [speakBin, "--refresh-voices", name]
    voiceRefreshProc.running = true
  }
  function providerSupportsVoiceRefresh(name) {
    var providers = info.providers || []
    for (var i = 0; i < providers.length; ++i)
      if (providers[i].name === name) return providers[i].refreshVoices === true
    return false
  }
  function previewText(text) {
    pendingPreview = String(text).slice(0, 32768)
    if (previewProc.running) {
      previewQueued = true
      return
    }
    previewProc.command = [speakBin, "--preview-stdin-json"]
    previewProc.running = true
  }
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
    if (keyProc.running || keySaving) { error = "A key is already being saved."; return }
    error = ""
    pendingKey = key; pendingKeyProvider = provider; pendingKeyPurpose = purpose || "speech"
    keySaving = true; keyResult = { ok: false, message: "" }
    keyProc.command = [setupBin, "key-store", provider]; restart(keyProc)
  }
  function removeKey(provider) { if (["openai", "elevenlabs", "google", "gemini"].indexOf(provider) >= 0) action([setupBin, "key-remove", provider]) }

  Process {
    id: configProc; command: []; stdinEnabled: true
    onStarted: { write(root.pendingConfigValue + "\n"); root.pendingConfigValue = "" }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim()) root.error = text.trim() }
    onRunningChanged: if (!running) {
      if (root.configQueue.length > 0) Qt.callLater(root.runNextConfig)
      else root.refresh()
    }
  }
  Process {
    id: infoProc; command: [root.speakBin, "--info"]
    stdout: StdioCollector { id: infoStdout; waitForEnd: true }
    stderr: StdioCollector { id: infoStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
      var queued = root.infoQueued
      root.infoQueued = false
      if (root.readEpoch !== root.writeEpoch) {
        queued = true       // answered a question we have since changed
      } else if (exitCode !== 0) {
        root.error = String(infoStderr.text || "Could not read TTS settings.").trim()
      } else {
        try {
          var result = JSON.parse(String(infoStdout.text || ""))
          if (!result || typeof result !== "object" || !Array.isArray(result.providers))
            throw new Error("invalid settings response")
          root.info = result
          root.infoLoaded = true
        } catch (e) {
          root.error = "Could not read TTS settings."
        }
      }
      if (queued) Qt.callLater(root.refresh)
    }
  }
  Process {
    id: speechProc
    command: []
    stdinEnabled: true
    onStarted: {
      write(JSON.stringify(root.pendingSpeech) + "\n")
      root.pendingSpeech = ""
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim()) root.error = text.trim()
    }
  }
  // The bar already owns a status stream. Reuse it when hosted there, while
  // retaining a fallback for standalone panel development.
  Process { id: speechWatch; running: root.statusSource === null; command: [root.speakBin, "--watch-status"]; stdout: SplitParser { splitMarker: "\n"; onRead: function(data) { root.watchedSpeaking = data.trim() !== "idle" } } }
  Process {
    id: verifyProc; command: []
    stdout: StdioCollector { id: verifyStdout; waitForEnd: true }
    stderr: StdioCollector { id: verifyStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
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
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
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
  Process {
    id: previewProc
    command: []
    stdinEnabled: true
    onStarted: {
      write(JSON.stringify(root.pendingPreview) + "\n")
      root.pendingPreview = ""
    }
    stdout: StdioCollector { id: previewStdout; waitForEnd: true }
    stderr: StdioCollector { id: previewStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
      if (!root.previewQueued) {
        if (exitCode === 0) root.preview = String(previewStdout.text || "").trim()
        else if (exitCode === 1) root.preview = ""
        else root.error = String(previewStderr.text || "Could not prepare the spoken preview.").trim()
      }
      if (root.previewQueued) {
        root.previewQueued = false
        Qt.callLater(function() { root.previewText(root.pendingPreview) })
      }
    }
  }
  Process {
    id: catalogueProc; command: [root.voiceBin, "available", "--json"]
    stdout: StdioCollector { id: catalogueStdout; waitForEnd: true }
    stderr: StdioCollector { id: catalogueStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
      if (root.catalogueQueued) {
        root.catalogueQueued = false
        Qt.callLater(root.loadCatalogue)
        return
      }
      root.catalogueLoading = false
      if (exitCode !== 0) {
        root.error = String(catalogueStderr.text || "Could not load the voice catalogue. Check your connection and try again.").trim()
        return
      }
      try { root.catalogue = JSON.parse(String(catalogueStdout.text || "[]")) }
      catch (e) { root.error = "The voice catalogue response was unreadable." }
    }
  }
  Process {
    id: downloadStatusProc; command: [root.voiceBin, "status"]
    stdout: StdioCollector { id: downloadStatusStdout; waitForEnd: true }
    stderr: StdioCollector { id: downloadStatusStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
      var result = null
      try { result = JSON.parse(String(downloadStatusStdout.text || "")) } catch (e) {}
      if (exitCode !== 0 || !result || typeof result.status !== "string") {
        downloadPoll.running = false
        root.downloadStarting = false
        root.pendingDownloadVoice = ""
        root.error = String(downloadStatusStderr.text || "Could not read voice-download status.").trim()
        return
      }
      var wasActive = root.downloadStarting || root.pendingDownloadVoice !== ""
                      || ["starting", "downloading"].indexOf(root.download.status) >= 0
      root.download = result
      root.pendingDownloadVoice = ""
      if (["starting", "downloading"].indexOf(result.status) >= 0) {
        downloadPoll.running = true
      } else {
        downloadPoll.running = false
        if (wasActive && ["done", "error", "cancelled"].indexOf(result.status) >= 0) {
          root.loadCatalogue()
          root.refresh()
        }
      }
    }
  }
  Process {
    id: downloadStartProc; command: []
    stdout: StdioCollector { id: downloadStartStdout; waitForEnd: true }
    stderr: StdioCollector { id: downloadStartStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
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
  Process {
    id: bindingsProc; command: [root.bindingsBin, "status"]
    stdout: StdioCollector { id: bindingsStdout; waitForEnd: true }
    stderr: StdioCollector { id: bindingsStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
      try {
        if (exitCode !== 0) throw new Error("shortcut status failed")
        root.bindings = JSON.parse(String(bindingsStdout.text || ""))
      } catch (e) {
        root.bindings = { installed: false, bindings: {}, conflicts: [], canInstall: false }
        root.error = String(bindingsStderr.text || "Could not inspect current shortcuts.").trim()
      }
    }
  }
  Process {
    id: setupStatusProc; command: [root.setupBin, "status"]
    stdout: StdioCollector { id: setupStatusStdout; waitForEnd: true }
    stderr: StdioCollector { id: setupStatusStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
      var result = null
      try { result = JSON.parse(String(setupStatusStdout.text || "")) } catch (e) {}
      if (exitCode === 0 && result && result.ok === true) {
        root.setup = result
        root.setupLoaded = true
      } else {
        root.error = (result && result.message)
                     || String(setupStatusStderr.text || "Could not read TTS setup status.").trim()
      }
    }
  }
  Process {
    id: setupStartProc; command: []
    stdout: StdioCollector { id: setupStartStdout; waitForEnd: true }
    stderr: StdioCollector { id: setupStartStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
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
    stdout: StdioCollector { id: setupJobStdout; waitForEnd: true }
    stderr: StdioCollector { id: setupJobStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
      var result = null
      try { result = JSON.parse(String(setupJobStdout.text || "")) } catch (e) {}
      if (exitCode !== 0 || !result || typeof result.status !== "string") {
        setupJobPoll.running = false
        root.error = String(setupJobStderr.text || "Could not read setup progress.").trim()
        return
      }
      root.setupJob = result
      if (["starting", "running"].indexOf(result.status) >= 0) {
        setupJobPoll.running = true
      } else {
        setupJobPoll.running = false
        if (["done", "error", "cancelled"].indexOf(result.status) >= 0) {
          root.restart(setupStatusProc)
          root.refresh()
        }
      }
    }
  }
  Process {
    id: keyProc; command: []; stdinEnabled: true
    onStarted: { write(root.pendingKey + "\n"); root.pendingKey = "" }
    stdout: StdioCollector { id: keyStdout; waitForEnd: true }
    stderr: StdioCollector { id: keyStderr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      // A run this controller killed with restart() is not a result; the
      // replacement run reports. Treating the kill as a failure painted
      // "Could not read TTS setup status" over a working install.
      if (exitStatus !== 0) return
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
  Timer { id: downloadPoll; interval: 1000; repeat: true; running: false; onTriggered: if (!downloadStatusProc.running) downloadStatusProc.running = true }
  Timer { id: setupJobPoll; interval: 1200; repeat: true; running: false; onTriggered: if (!setupJobProc.running) setupJobProc.running = true }
}
