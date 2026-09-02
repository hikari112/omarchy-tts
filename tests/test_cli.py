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
        self.env.pop("OPENAI_API_KEY", None)
        self.env.pop("ELEVENLABS_API_KEY", None)

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

    def test_concurrent_config_updates_do_not_overwrite_each_other(self):
        self.run_speak("--info")
        for _ in range(5):
            first = subprocess.Popen([SPEAK, "--set", ".rate", "1.25"],
                                     env=self.env, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
            second = subprocess.Popen([SPEAK, "--set", ".maxChars", "321"],
                                      env=self.env, stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL)
            self.assertEqual(first.wait(timeout=3), 0)
            self.assertEqual(second.wait(timeout=3), 0)
            info = json.loads(self.run_speak("--info").stdout)
            self.assertEqual((info["rate"], info["maxChars"]), (1.25, 321))

    def test_set_accepts_known_path_and_rejects_unknown_path(self):
        self.run_speak("--set", ".rate", "1.25")
        self.assertEqual(json.loads(self.run_speak("--info").stdout)["rate"], 1.25)
        result = self.run_speak("--set", ".apiKeys.openai", "secret", check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_plaintext_config_api_keys_are_not_accepted(self):
        self.run_speak("--info")
        config = Path(self.temp.name, "omarchy-tts", "config.json")
        data = json.loads(config.read_text())
        data["apiKeys"] = {"openai": "plaintext-must-not-be-used"}
        config.write_text(json.dumps(data))
        info = json.loads(self.run_speak("--info").stdout)
        openai = next(item for item in info["providers"] if item["name"] == "openai")
        # The property under test is that a plaintext key is never the source,
        # not that no key exists. Asserting "none" only held on a machine with
        # an empty keyring: it passed in CI and failed for anyone who had
        # actually stored a key, which is precisely who this protects.
        self.assertNotEqual(openai["keySource"], "config",
                            "a plaintext key in config.json was accepted")
        self.assertIn(openai["keySource"], ("none", "keyring", "env"))
        if openai["keySource"] == "none":
            self.assertEqual(openai["status"], "nokey")

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

    def test_binding_remove_is_idempotent_and_does_not_create_a_file(self):
        target = Path(self.temp.name, "hypr", "bindings.lua")
        subprocess.run([BINDINGS, "remove"], env=self.env, check=True,
                       capture_output=True, text=True)
        self.assertFalse(target.exists())

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
        for chord in ('SUPER + E\n")\nos.execute("bad")',
                      "SUPER + A + B", "SUPER + SUPER + E", "SUPER"):
            result = subprocess.run(
                [BINDINGS, "set", "selection", chord],
                env=self.env, capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)

    def test_binding_config_persists_choices_not_derived_commands(self):
        config = Path(self.temp.name, "omarchy-tts", "bindings.json")
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(json.dumps({
            "selection": {"chord": "SUPER + ALT + Q",
                          "label": "stale", "command": "/old/plugin/speak --toggle"}
        }))
        status = subprocess.run([BINDINGS, "status"], env=self.env, check=True,
                                capture_output=True, text=True)
        binding = json.loads(status.stdout)["bindings"]["selection"]
        self.assertEqual(binding["chord"], "SUPER + ALT + Q")
        self.assertNotEqual(binding["command"], "/old/plugin/speak --toggle")
        subprocess.run([BINDINGS, "set", "selection", "SUPER + ALT + Z"],
                       env=self.env, check=True, capture_output=True, text=True)
        stored = json.loads(config.read_text())
        self.assertEqual(stored["selection"], {"chord": "SUPER + ALT + Z"})

    def test_binding_manager_detects_active_default_conflicts(self):
        tools = Path(self.temp.name, "tools")
        tools.mkdir()
        hyprctl = tools / "hyprctl"
        hyprctl.write_text(
            "#!/usr/bin/env bash\n"
            "if [[ $1 == binds ]]; then\n"
            "  printf '%s\\n' '[{\"modmask\":72,\"key\":\"E\",\"dispatcher\":\"exec\",\"arg\":\"editor\"}]'\n"
            "else exit 0; fi\n"
        )
        hyprctl.chmod(0o755)
        self.env["PATH"] = f"{tools}:{self.env['PATH']}"
        self.env["HYPRLAND_INSTANCE_SIGNATURE"] = "test"
        status = subprocess.run([BINDINGS, "status"], env=self.env,
                                capture_output=True, text=True, check=True)
        self.assertIn("SUPER + ALT + E", json.loads(status.stdout)["conflicts"])

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

    def test_temporary_provider_limit_does_not_poison_health(self):
        for name, code in (("quotatest", 69), ("networktest", 74), ("ratetest", 75)):
            self.write_provider(name, f"exit {code}")
            self.speak("--set", ".provider", name)
            self.speak("Hello there.")
            self.assertEqual(self.status_of(name), "untested")

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

    def test_stale_speech_identity_cannot_signal_a_reused_pid(self):
        sleeper = subprocess.Popen(["sleep", "30"], start_new_session=True)
        try:
            state = self.home / "run" / "omarchy-tts"
            state.mkdir(parents=True, exist_ok=True)
            (state / "pgid").write_text(f"{sleeper.pid} definitely-wrong\n")
            (state / "status").write_text("speaking\n")
            self.assertEqual(self.speak("--status").stdout.strip(), "idle")
            self.speak("--stop")
            self.assertIsNone(sleeper.poll())
        finally:
            sleeper.terminate()
            sleeper.wait(timeout=3)


class CloudProviderPrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.args = self.root / "curl-args"
        self.body = self.root / "curl-body"
        self.headers = self.root / "curl-headers"
        self.response_headers = self.root / "response-headers"
        self.response_headers.write_text(
            "HTTP/2 200\r\nx-request-id: req_private_test\r\n"
            "x-ratelimit-limit-requests: 100\r\n"
            "x-ratelimit-remaining-requests: 99\r\n"
            "x-ratelimit-reset-requests: 1s\r\ncharacter-cost: 7\r\n\r\n"
        )
        fake_curl = self.bin / "curl"
        fake_curl.write_text(
            "#!/usr/bin/env bash\n"
            "printf '%s\\n' \"$@\" > \"$FAKE_CURL_ARGS\"\n"
            "[[ ${FAKE_CURL_EXIT:-0} == 0 ]] || exit \"$FAKE_CURL_EXIT\"\n"
            "output=\n"
            "dump=\n"
            "writeout=\n"
            "while [[ $# -gt 0 ]]; do\n"
            "  if [[ $1 == --output ]]; then output=$2; shift; fi\n"
            "  if [[ $1 == --dump-header ]]; then dump=$2; shift; fi\n"
            "  if [[ $1 == --write-out ]]; then writeout=$2; shift; fi\n"
            "  shift\n"
            "done\n"
            "cat > \"$FAKE_CURL_BODY\"\n"
            "cat <&3 > \"$FAKE_CURL_HEADERS\"\n"
            "[[ -z $dump ]] || cp \"$FAKE_RESPONSE_HEADERS\" \"$dump\"\n"
            "[[ ${FAKE_EMPTY_AUDIO:-0} == 1 ]] || printf fake-audio > \"$output\"\n"
            "[[ -z $writeout ]] || printf 200\n"
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
                   "FAKE_CURL_BODY": str(self.body),
                   "FAKE_CURL_HEADERS": str(self.headers),
                   "FAKE_RESPONSE_HEADERS": str(self.response_headers),
                   "XDG_RUNTIME_DIR": str(self.root),
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
            payload = json.loads(self.body.read_text())
            self.assertEqual(payload["input" if provider == "openai" else "text"], spoken)
            self.assertIn(secret, self.headers.read_text())

    def test_cloud_telemetry_contains_counts_and_limits_but_no_content(self):
        metrics = self.root / "metrics.json"
        metrics.write_text("not json")
        spoken = "private words"
        env = {**os.environ,
               "PATH": f"{self.bin}:{os.environ['PATH']}",
               "FAKE_CURL_ARGS": str(self.args), "FAKE_CURL_BODY": str(self.body),
               "FAKE_CURL_HEADERS": str(self.headers),
               "FAKE_RESPONSE_HEADERS": str(self.response_headers),
               "XDG_RUNTIME_DIR": str(self.root), "TTS_PLUGIN_DIR": str(ROOT),
               "TTS_CONFIG": str(self.config), "TTS_SILENT": "1",
               "TTS_INPUT_CHARS": str(len(spoken)), "TTS_METRICS_FILE": str(metrics),
               "OPENAI_API_KEY": "secret-key-that-must-not-leak"}
        result = subprocess.run([ROOT / "providers" / "openai"], input=spoken,
                                text=True, capture_output=True, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(metrics.read_text())
        self.assertEqual(data["localObserved"],
                         {"requests": 1, "characters": len(spoken), "billedUnits": 0})
        self.assertEqual(data["rateLimits"]["requests"]["remaining"], "99")
        self.assertNotIn(spoken, metrics.read_text())
        self.assertEqual(metrics.stat().st_mode & 0o777, 0o600)

    def test_network_failure_is_reported_as_temporary(self):
        env = {**os.environ,
               "PATH": f"{self.bin}:{os.environ['PATH']}",
               "FAKE_CURL_ARGS": str(self.args), "FAKE_CURL_BODY": str(self.body),
               "FAKE_CURL_HEADERS": str(self.headers),
               "FAKE_RESPONSE_HEADERS": str(self.response_headers),
               "FAKE_CURL_EXIT": "28", "XDG_RUNTIME_DIR": str(self.root),
               "TTS_PLUGIN_DIR": str(ROOT), "TTS_CONFIG": str(self.config),
               "TTS_SILENT": "1", "OPENAI_API_KEY": "safe-test-key"}
        result = subprocess.run([ROOT / "providers" / "openai"], input="hello",
                                text=True, capture_output=True, env=env)
        self.assertEqual(result.returncode, 74)
        self.assertIn("network request failed", result.stderr)

    def test_empty_success_response_is_rejected(self):
        env = {**os.environ,
               "PATH": f"{self.bin}:{os.environ['PATH']}",
               "FAKE_CURL_ARGS": str(self.args), "FAKE_CURL_BODY": str(self.body),
               "FAKE_CURL_HEADERS": str(self.headers),
               "FAKE_RESPONSE_HEADERS": str(self.response_headers),
               "FAKE_EMPTY_AUDIO": "1", "XDG_RUNTIME_DIR": str(self.root),
               "TTS_PLUGIN_DIR": str(ROOT), "TTS_CONFIG": str(self.config),
               "TTS_SILENT": "1", "OPENAI_API_KEY": "safe-test-key"}
        result = subprocess.run([ROOT / "providers" / "openai"], input="hello",
                                text=True, capture_output=True, env=env)
        self.assertEqual(result.returncode, 74)
        self.assertIn("returned no audio", result.stderr)


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
