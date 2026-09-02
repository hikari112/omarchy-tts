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
  property string pendingKey: ""
  property bool keySaving: false
  property bool speaking: false
  signal actionFinished

  function restart(process) { process.running = false; process.running = true }
  function refresh() { restart(infoProc) }
  function refreshBindings() { restart(bindingsProc) }
  function refreshSetup() { restart(setupStatusProc); restart(setupJobProc) }
  function loadCatalogue() { restart(catalogueProc) }
  function action(argv) { error = ""; actionProc.running = false; actionProc.command = argv; actionProc.running = true }
  function setConfig(path, value) { action([speakBin, "--set", path, String(value)]) }
  function speak(text) { speechProc.command = [speakBin, "--raw", "--", text]; restart(speechProc) }
  function stop() { speechProc.command = [speakBin, "--stop"]; restart(speechProc) }
  function selectProvider(name) { setConfig(".provider", name) }
  function previewText(text) { previewProc.command = [speakBin, "--preview-text", text]; restart(previewProc) }
  function downloadVoice(key) { action([voiceBin, "add", key, "--async"]); download = { status: "downloading", voice: key, percent: 0 }; downloadPoll.running = true }
  function cancelDownload() { action([voiceBin, "cancel"]); downloadPoll.running = false }
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
  function cancelSetup() { action([setupBin, "cancel"]); setupJobPoll.running = false }
  function storeKey(provider, key) {
    if ((provider !== "openai" && provider !== "elevenlabs") || key.length < 8) return
    pendingKey = key; keySaving = true; keyResult = { ok: false, message: "" }
    keyProc.command = [setupBin, "key-store", provider]; restart(keyProc)
  }
  function removeKey(provider) { if (provider === "openai" || provider === "elevenlabs") action([setupBin, "key-remove", provider]) }

  Process {
    id: infoProc; command: [root.speakBin, "--info"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: { try { root.info = JSON.parse(text); root.error = "" } catch (e) { root.error = "Could not read TTS settings" } } }
  }
  Process { id: speechProc; command: []; stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim()) root.error = text.trim() } }
  Process { id: speechWatch; running: true; command: [root.speakBin, "--watch-status"]; stdout: SplitParser { splitMarker: "\n"; onRead: function(data) { root.speaking = data.trim() === "speaking" } } }
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
    onRunningChanged: if (!running) { root.keySaving = false; root.refresh() }
  }
  Timer { id: downloadPoll; interval: 500; repeat: true; running: false; onTriggered: root.restart(downloadStatusProc) }
  Timer { id: setupJobPoll; interval: 650; repeat: true; running: false; onTriggered: root.restart(setupJobProc) }
}
