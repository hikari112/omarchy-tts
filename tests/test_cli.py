#!/usr/bin/env python3
"""Small integration checks for the public CLI/config boundary."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
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

    def test_invalid_config_is_preserved_before_recovery(self):
        config = Path(self.temp.name, "omarchy-tts", "config.json")
        config.parent.mkdir(parents=True)
        config.write_text('{"provider":')
        result = self.run_speak("--info")
        self.assertEqual(json.loads(result.stdout)["provider"], "piper")
        preserved = list(config.parent.glob("config.json.invalid.*"))
        self.assertEqual(len(preserved), 1)
        self.assertEqual(preserved[0].read_text(), '{"provider":')

    def test_command_line_overrides_are_validated(self):
        for args in (("--rate", "fast", "hello"),
                     ("--rate", "3", "hello"),
                     ("--max-chars", "-1", "hello"),
                     ("--provider", "../bad", "hello")):
            self.assertNotEqual(self.run_speak(*args, check=False).returncode, 0)

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

    def test_binding_manager_rejects_non_chord_input(self):
        result = subprocess.run(
            [BINDINGS, "set", "selection", 'SUPER + E\n")\nos.execute("bad")'],
            env=self.env, capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)

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

    def test_superseded_speech_cannot_erase_the_new_owner(self):
        self.write_provider(
            "slowtest",
            "trap 'exit 143' TERM INT\ncat > /dev/null\nsleep 30",
        )
        self.speak("--set", ".provider", "slowtest")
        first = subprocess.Popen([SPEAK, "first"], text=True,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 env=self.env)
        pid_file = self.home / "run" / "omarchy-tts" / "pgid"
        for _ in range(100):
            if pid_file.exists():
                break
            time.sleep(0.02)
        second = subprocess.Popen([SPEAK, "second"], text=True,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  env=self.env)
        for _ in range(100):
            if pid_file.exists() and first.poll() is not None:
                break
            time.sleep(0.02)
        self.assertEqual(self.speak("--status").stdout.strip(), "speaking")
        self.assertTrue(pid_file.exists())
        self.speak("--stop")
        first.wait(timeout=3)
        second.wait(timeout=3)


class CloudProviderPrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.args = self.root / "curl-args"
        fake_curl = self.bin / "curl"
        fake_curl.write_text(
            "#!/usr/bin/env bash\n"
            "printf '%s\\n' \"$@\" > \"$FAKE_CURL_ARGS\"\n"
            "while [[ $# -gt 0 ]]; do\n"
            "  if [[ $1 == --output ]]; then printf fake-audio > \"$2\"; exit 0; fi\n"
            "  shift\n"
            "done\n"
        )
        fake_curl.chmod(0o755)
        self.config = self.root / "config.json"
        self.config.write_text("{}")

    def tearDown(self):
        self.temp.cleanup()

    def test_cloud_secrets_and_text_stay_out_of_curl_arguments(self):
        secret = "secret-key-that-must-not-leak"
        spoken = "private highlighted text that must not leak"
        for provider, variable in (("openai", "OPENAI_API_KEY"),
                                   ("elevenlabs", "ELEVENLABS_API_KEY")):
            env = {**os.environ,
                   "PATH": f"{self.bin}:{os.environ['PATH']}",
                   "FAKE_CURL_ARGS": str(self.args),
                   "TTS_PLUGIN_DIR": str(ROOT),
                   "TTS_CONFIG": str(self.config),
                   "TTS_SILENT": "1",
                   variable: secret}
            result = subprocess.run([ROOT / "providers" / provider], input=spoken,
                                    text=True, capture_output=True, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            arguments = self.args.read_text()
            self.assertNotIn(secret, arguments)
            self.assertNotIn(spoken, arguments)


class BindingAdoptionTests(unittest.TestCase):
    """Shortcuts a user set up by hand are ours to adopt, not to duplicate."""

    LUA = """-- Personal keybindings
o.bind("SUPER + SHIFT + S", "Screenshot", "omarchy-capture-screenshot")
o.bind("SUPER + ALT + P", "Unrelated", "/usr/bin/speaker-test --nonsense")
o.bind("SUPER + ALT + E", "Speak selection", "/home/someone/.local/bin/speak --toggle")
o.bind("SUPER + ALT + X", "Stop speaking", "speak --stop")
"""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        (self.home / "hypr").mkdir(parents=True)
        (self.home / "omarchy-tts").mkdir(parents=True)
        self.lua = self.home / "hypr" / "bindings.lua"
        self.lua.write_text(self.LUA)
        self.env = {**os.environ, "XDG_CONFIG_HOME": str(self.home)}
        self.env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)

    def tearDown(self):
        self.temp.cleanup()

    def run_bindings(self, *args):
        return subprocess.run([BINDINGS, *args], text=True, capture_output=True,
                              env=self.env, check=False)

    def test_hand_written_bindings_are_adoptable_not_conflicts(self):
        state = json.loads(self.run_bindings("status").stdout)
        self.assertFalse(state["installed"])
        self.assertEqual(state["conflicts"], [])
        self.assertIn("SUPER + ALT + E", state["adoptable"])
        self.assertTrue(state["canInstall"], "adoption must not be a dead end")

    def test_install_adopts_without_duplicating(self):
        self.run_bindings("install")
        text = self.lua.read_text()
        self.assertEqual(text.count("SUPER + ALT + E"), 1, "chord bound twice")
        self.assertIn("Screenshot", text, "unrelated binding was removed")

    def test_similarly_named_program_is_left_alone(self):
        # speaker-test is not speak; adopting it would break the user's setup.
        self.run_bindings("install")
        self.assertIn("speaker-test", self.lua.read_text())

    def test_genuine_conflict_still_refuses_and_changes_nothing(self):
        self.lua.write_text('o.bind("SUPER + ALT + E", "Open editor", "code")\n')
        before = self.lua.read_text()
        state = json.loads(self.run_bindings("status").stdout)
        self.assertEqual(state["conflicts"], ["SUPER + ALT + E"])
        self.assertFalse(state["canInstall"])
        result = self.run_bindings("install")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.lua.read_text(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
