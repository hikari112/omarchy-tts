#!/usr/bin/env python3
"""Small integration checks for the public CLI/config boundary."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEAK = ROOT / "bin" / "speak"
BINDINGS = ROOT / "bin" / "speak-bindings"
SETUP = ROOT / "bin" / "speak-setup"


class CliConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.env = {**os.environ, "XDG_CONFIG_HOME": self.temp.name,
                    "XDG_RUNTIME_DIR": self.temp.name}
        self.env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)

    def tearDown(self):
        self.temp.cleanup()

    def run_speak(self, *args, input_text=None, check=True):
        return subprocess.run([SPEAK, *args], input=input_text, text=True,
                              capture_output=True, env=self.env, check=check)

    def test_fresh_info_creates_complete_private_config(self):
        info = json.loads(self.run_speak("--info").stdout)
        config = Path(self.temp.name, "omarchy-tts", "config.json")
        self.assertEqual(info["provider"], "piper")
        self.assertTrue(info["sanitizer"]["stripMarkdown"])
        self.assertEqual(config.stat().st_mode & 0o777, 0o600)

    def test_set_accepts_known_path_and_rejects_unknown_path(self):
        self.run_speak("--set", ".rate", "1.25")
        self.assertEqual(json.loads(self.run_speak("--info").stdout)["rate"], 1.25)
        result = self.run_speak("--set", ".apiKeys.openai", "secret", check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_preview_uses_persisted_sanitizer_options(self):
        self.run_speak("--set", ".sanitizer.urls", "link")
        result = self.run_speak("--preview-text", "See https://example.com in 2s")
        self.assertEqual(result.stdout, "See link in 2 seconds")

    def test_binding_manager_owns_only_its_marked_block(self):
        hypr = Path(self.temp.name, "hypr")
        hypr.mkdir()
        target = hypr / "bindings.lua"
        target.write_text('o.bind("SUPER + B", "Browser", "browser")\n')
        subprocess.run([BINDINGS, "install"], env=self.env, check=True,
                       capture_output=True, text=True)
        installed = target.read_text()
        self.assertIn("-- >>> omarchy-tts bindings", installed)
        self.assertIn('"Browser"', installed)
        subprocess.run([BINDINGS, "remove"], env=self.env, check=True,
                       capture_output=True, text=True)
        self.assertEqual(target.read_text().strip(),
                         'o.bind("SUPER + B", "Browser", "browser")')

    def test_binding_manager_adopts_legacy_documented_bindings(self):
        hypr = Path(self.temp.name, "hypr")
        hypr.mkdir()
        target = hypr / "bindings.lua"
        target.write_text('o.bind("SUPER + ALT + E", "Speak selection", "speak --toggle")\n')
        status = subprocess.run([BINDINGS, "status"], env=self.env, check=True,
                                capture_output=True, text=True)
        self.assertTrue(json.loads(status.stdout)["canInstall"])
        subprocess.run([BINDINGS, "install"], env=self.env, check=True,
                       capture_output=True, text=True)
        installed = target.read_text()
        self.assertEqual(installed.count("Speak selection"), 1)
        self.assertIn("-- >>> omarchy-tts bindings", installed)

    def test_setup_backend_status_and_allowlist(self):
        self.env["XDG_DATA_HOME"] = str(Path(self.temp.name, "data"))
        status = subprocess.run([SETUP, "status"], env=self.env, check=True,
                                capture_output=True, text=True)
        payload = json.loads(status.stdout)
        self.assertFalse(payload["ready"])
        self.assertEqual(payload["defaultVoice"], "en_US-amy-medium")
        rejected = subprocess.run([SETUP, "start", "anything-else"], env=self.env,
                                  check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(rejected.stdout)["code"], "unknown_target")

    def test_setup_rejects_short_or_unknown_keys_without_storing(self):
        for provider, value, code in (("openai", "short", "invalid_key"),
                                      ("other", "long-enough-key", "unknown_provider")):
            result = subprocess.run([SETUP, "key-store", provider], input=value + "\n",
                                    env=self.env, check=True, capture_output=True, text=True)
            self.assertEqual(json.loads(result.stdout)["code"], code)


class ProviderHealthTests(unittest.TestCase):
    """A provider that is installed but cannot speak must never read "ready".

    This is the regression that silently disabled every keybinding: kokoro
    passed its probe, was reported ready, was selected as default, and could
    not synthesise a single sample.
    """

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.env = {**os.environ,
                    "XDG_CONFIG_HOME": str(self.home / "config"),
                    "XDG_CACHE_HOME": str(self.home / "cache"),
                    "XDG_RUNTIME_DIR": str(self.home / "run")}
        self.env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
        self.providers = self.home / "config" / "omarchy-tts" / "providers"
        self.providers.mkdir(parents=True)

    def tearDown(self):
        self.temp.cleanup()

    def write_provider(self, name, body, probe="true"):
        path = self.providers / name
        path.write_text("#!/usr/bin/env bash\n"
                        f"# desc: test provider {name}\n"
                        "# kind: local\n"
                        f"# probe: {probe}\n"
                        f"{body}\n")
        path.chmod(0o755)
        return path

    def speak(self, *args):
        return subprocess.run([SPEAK, *args], text=True, capture_output=True,
                              env=self.env, check=False)

    def status_of(self, name):
        info = json.loads(self.speak("--info").stdout)
        for entry in info["providers"]:
            if entry["name"] == name:
                return entry["status"]
        return None

    def test_installed_but_broken_provider_is_not_ready(self):
        self.write_provider("brokentest", "exit 3")
        self.assertEqual(self.status_of("brokentest"), "untested",
                         "an unproven provider must not claim to be ready")
        result = self.speak("--verify", "brokentest")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.status_of("brokentest"), "failing")

    def test_working_provider_becomes_ready_only_after_proof(self):
        self.write_provider("worktest", "cat > /dev/null")
        self.assertEqual(self.status_of("worktest"), "untested")
        result = self.speak("--verify", "worktest")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.status_of("worktest"), "ready")

    def test_absent_provider_reports_missing_not_failing(self):
        # Absence and breakage are different problems with different fixes.
        self.write_provider("absenttest", "cat > /dev/null", probe="false")
        self.assertEqual(self.status_of("absenttest"), "missing")
        result = self.speak("--verify", "absenttest")
        self.assertIn("not installed", result.stdout)

    def test_failure_during_real_speech_is_recorded(self):
        self.write_provider("livetest", "exit 4")
        self.speak("--set", ".provider", "livetest")
        self.speak("Hello there.")
        self.assertEqual(self.status_of("livetest"), "failing",
                         "a real failure should mark the provider without a separate test")


if __name__ == "__main__":
    unittest.main(verbosity=2)
