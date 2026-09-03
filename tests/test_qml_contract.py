#!/usr/bin/env python3
"""Static contracts for UI races that do not require a running compositor."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class QmlContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.panel = (ROOT / "Panel.qml").read_text()
        cls.controller = (ROOT / "components" / "TtsController.qml").read_text()
        cls.key_dialog = (ROOT / "components" / "ApiKeyDialog.qml").read_text()
        cls.wizard = (ROOT / "components" / "FirstRunWizard.qml").read_text()

    def test_setup_cancel_requires_registered_worker_identity(self):
        self.assertIn("readonly property bool setupCancellable", self.controller)
        self.assertIn("Number(setupJob.pid || 0) > 1", self.controller)
        self.assertIn('String(setupJob.processIdentity || "") !== ""', self.controller)
        self.assertIn("visible: root.controller.setupCancellable", self.wizard)
        self.assertNotIn('setupJob = { status: "starting"',
                         next(line for line in self.controller.splitlines()
                              if "function startSetup" in line))

    def test_key_save_keeps_speech_and_ocr_purposes_distinct(self):
        self.assertIn('property string purpose: "speech"', self.key_dialog)
        self.assertIn("controller.storeKey(provider, keyField.text, purpose)", self.key_dialog)
        self.assertIn('purpose: "speech"', self.panel)
        self.assertIn('purpose: "ocr"', self.panel)
        self.assertIn('pendingKeyPurpose === "speech"', self.controller)

    def test_panel_scrolls_and_yields_non_tab_keys_to_controls(self):
        self.assertIn("ScrollView {", self.panel)
        self.assertIn("readonly property bool descendantControlActive", self.panel)
        self.assertIn("if (root.descendantControlActive) return", self.panel)

    def test_panel_tab_navigation_enters_real_controls(self):
        self.assertIn("function moveTabFocus(direction)", self.panel)
        self.assertIn("candidate.nextItemInFocusChain(forward)", self.panel)
        self.assertIn("candidate.forceActiveFocus", self.panel)
        self.assertIn("Keys.priority: Keys.BeforeItem", self.panel)
        self.assertIn("event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab", self.panel)

    def test_hidden_key_dialogs_do_not_retain_credentials(self):
        self.assertIn('else keyField.text = ""', self.key_dialog)
        self.assertIn('apiProvider = ""; apiVendor = ""', self.panel)
        self.assertIn('ocrApiProvider = ""; ocrApiVendor = ""', self.panel)

    def test_provider_actions_are_declared_by_backend_metadata(self):
        self.assertIn("root.activeProvider.refreshVoices === true", self.panel)
        self.assertIn("modelData.refreshUsage === true", self.panel)
        start = self.panel.index(
            "visible: root.activeProvider && Number(root.activeProvider.maxBytes || 0) > 0"
        )
        caption = self.panel[start:self.panel.index("color: root.dim", start)]
        self.assertIn("text: root.activeProvider", caption)
        self.assertIn(': ""', caption)
        self.assertNotIn('root.activeProvider.name === "elevenlabs" || root.activeProvider.name === "google"',
                         self.panel)

    def test_retryable_controller_actions_clear_stale_errors(self):
        for signature in (
                "function speak(text)", "function stop()",
                "function verifyProvider(name)", "function verifyOcrEngine(name)",
                "function refreshUsage(name)", "function refreshLanguages(engine)",
                "function refreshVoices(name)"):
            line = next(line for line in self.controller.splitlines()
                        if signature in line)
            self.assertIn('error = ""', line, signature)
        key_start = self.controller.index("function storeKey(provider, key, purpose)")
        key_body = self.controller[key_start:self.controller.index("function removeKey", key_start)]
        self.assertIn('error = ""', key_body)

    def test_duplicate_job_starts_reconnect_to_the_backend_owner(self):
        self.assertIn('result.code === "already_running"', self.controller)
        self.assertIn('stderr.indexOf("already running") >= 0', self.controller)
        self.assertIn("setupJobPoll.running = true", self.controller)
        self.assertIn("downloadPoll.running = true", self.controller)


if __name__ == "__main__":
    unittest.main(verbosity=2)
