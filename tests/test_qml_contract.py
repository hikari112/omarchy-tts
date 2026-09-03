#!/usr/bin/env python3
"""Static contracts for UI races that do not require a running compositor."""
import re
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
        cls.inline_action = (ROOT / "components" / "InlineAction.qml").read_text()
        cls.key_row = (ROOT / "components" / "KeyRow.qml").read_text()
        cls.setting_toggle = (ROOT / "components" / "SettingToggle.qml").read_text()

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
            start = self.controller.index(signature)
            following = self.controller.find("\n  function ", start + len(signature))
            body = self.controller[start:following if following >= 0 else None]
            self.assertIn('error = ""', body, signature)
        key_start = self.controller.index("function storeKey(provider, key, purpose)")
        key_body = self.controller[key_start:self.controller.index("function removeKey", key_start)]
        self.assertIn('error = ""', key_body)

    def test_duplicate_job_starts_reconnect_to_the_backend_owner(self):
        self.assertIn('result.code === "already_running"', self.controller)
        self.assertIn('stderr.indexOf("already running") >= 0', self.controller)
        self.assertIn("setupJobPoll.running = true", self.controller)
        self.assertIn("downloadPoll.running = true", self.controller)

    def test_user_text_uses_bounded_stdin_protocols_not_process_arguments(self):
        self.assertIn('speechProc.command = [speakBin, "--stdin-json"]', self.controller)
        self.assertIn('write(JSON.stringify(root.pendingSpeech) + "\\n")', self.controller)
        self.assertIn('[speakBin, "--preview-stdin-json"]', self.controller)
        self.assertIn('[speakBin, "--set-stdin-json", next.path]', self.controller)
        self.assertNotIn('[speakBin, "--preview-text",', self.controller)

    def test_opening_panel_does_not_fetch_download_catalogue(self):
        opened = self.panel[self.panel.index("onOpenedChanged:"):
                            self.panel.index("function restoreFromInfo")]
        self.assertNotIn("loadCatalogue", opened)
        self.assertIn("onClicked: { root.browsing = true; root.voiceFilter = \"\"; controller.loadCatalogue() }",
                      self.panel)

    def test_config_refresh_waits_for_all_pending_writes(self):
        refresh = self.controller[self.controller.index("function refresh()"):
                                  self.controller.index("function refreshBindings")]
        self.assertIn("configProc.running", refresh)
        self.assertIn("configQueue.length > 0", refresh)
        self.assertIn("infoQueued = true", refresh)

    def test_interactive_custom_controls_expose_keyboard_and_accessibility(self):
        for source in (self.inline_action, self.key_row, self.setting_toggle):
            self.assertIn("activeFocusOnTab", source)
            self.assertIn("Accessible.role", source)
            self.assertIn("Accessible.onPressAction", source)
            self.assertIn("Keys.onSpacePressed", source)

    def test_length_limit_is_bounded_in_the_panel(self):
        self.assertIn("IntValidator { bottom: 0; top: 1048576 }", self.panel)
        self.assertIn("Math.min(1048576", self.panel)

    def test_first_run_counts_only_locally_usable_or_credentialed_providers(self):
        self.assertIn("readonly property bool hasUsableProvider", self.panel)
        self.assertIn('all[i].status === "ready" || all[i].status === "untested"',
                      self.panel)
        self.assertIn("controller.setupLoaded", self.panel)
        self.assertIn("!hasUsableProvider", self.panel)

    def test_setup_status_requires_a_successful_backend_response(self):
        start = self.controller.index("id: setupStatusProc")
        block = self.controller[start:self.controller.index("id: setupStartProc", start)]
        self.assertIn("id: setupStatusStderr", block)
        self.assertIn("onExited: function(exitCode, exitStatus)", block)
        self.assertIn("exitCode === 0 && result && result.ok === true", block)
        self.assertNotIn("onStreamFinished", block)

    def test_preview_and_catalogue_reads_are_queued_not_killed(self):
        self.assertIn("property bool previewQueued", self.controller)
        self.assertIn("property bool catalogueQueued", self.controller)
        preview = self.controller[self.controller.index("function previewText"):
                                  self.controller.index("function downloadVoice")]
        catalogue = self.controller[self.controller.index("function loadCatalogue"):
                                    self.controller.index("function action")]
        self.assertNotIn("restart(", preview)
        self.assertNotIn("restart(", catalogue)
        self.assertIn("if (previewProc.running)", preview)
        self.assertIn("if (catalogueProc.running)", catalogue)

    def test_state_read_failures_stop_polling_and_surface_errors(self):
        self.assertIn("id: downloadStatusStderr", self.controller)
        self.assertIn("downloadPoll.running = false", self.controller)
        self.assertIn("id: setupJobStderr", self.controller)
        self.assertIn("setupJobPoll.running = false", self.controller)

    def test_info_failure_does_not_create_an_unbounded_retry_loop(self):
        start = self.controller.index("id: infoProc")
        block = self.controller[start:self.controller.index("id: speechProc", start)]
        self.assertIn("id: infoStderr", block)
        self.assertIn("onExited: function(exitCode, exitStatus)", block)
        self.assertNotIn("root.infoQueued = true", block)

    def test_cloud_backend_operations_are_not_killed_and_restarted(self):
        start = self.controller.index("function verifyProvider")
        block = self.controller[start:self.controller.index("function providerSupportsVoiceRefresh", start)]
        self.assertIn("if (verifyProc.running)", block)
        self.assertIn("if (usageProc.running)", block)
        self.assertIn("if (voiceRefreshProc.running)", block)
        self.assertNotIn("restart(", block)

    def test_executable_urls_support_encoded_install_paths(self):
        self.assertIn("decodeURIComponent(value.slice(7))", self.controller)

    def test_user_and_remote_content_is_never_auto_detected_as_rich_text(self):
        self.assertIn("textFormat: Text.PlainText", self.inline_action)
        preview = self.panel[self.panel.index('text: controller.preview || "Spoken preview"') - 120:
                             self.panel.index('text: controller.preview || "Spoken preview"') + 80]
        self.assertIn("textFormat: Text.PlainText", preview)
        error = self.panel[self.panel.index('visible: controller.error !== ""'):]
        self.assertIn("textFormat: Text.PlainText", error[:180])
        self.assertIn("textFormat: TextEdit.PlainText", self.panel)




class ProcessExitContractTests(unittest.TestCase):
    def test_every_controller_exit_handler_ignores_killed_runs(self):
        """restart() kills an in-flight process; its non-zero exit is not a
        failure of anything and must not surface as an error."""
        source = (ROOT / "components" / "TtsController.qml").read_text()
        handlers = re.findall(r"onExited: function\(([^)]*)\) \{\n((?:.*\n){1,5})", source)
        self.assertTrue(handlers, "no onExited handlers found")
        for params, body in handlers:
            self.assertIn("exitStatus", params)
            self.assertIn("if (exitStatus !== 0) return", body)


if __name__ == "__main__":
    unittest.main()
