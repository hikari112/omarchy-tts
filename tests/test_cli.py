#!/usr/bin/env python3
"""Small integration checks for the public CLI/config boundary."""
import json
import os
from pathlib import Path
import select
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
                    "XDG_CACHE_HOME": self.temp.name,
                    "XDG_DATA_HOME": self.temp.name,
                    "XDG_RUNTIME_DIR": self.temp.name,
                    "DBUS_SESSION_BUS_ADDRESS": "unix:path=/nonexistent"}
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
        settings = json.loads(config.read_text())
        self.assertEqual(info["provider"], "piper")
        self.assertTrue(info["sanitizer"]["stripMarkdown"])
        self.assertNotIn("voiceId", settings["elevenlabs"])
        self.assertEqual(config.stat().st_mode & 0o777, 0o600)

    def test_partial_provider_objects_receive_missing_defaults(self):
        config = Path(self.temp.name, "omarchy-tts", "config.json")
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({"openai": {"voice": "nova"},
                                      "elevenlabs": {}}))
        self.run_speak("--info")
        settings = json.loads(config.read_text())
        self.assertEqual(settings["openai"]["voice"], "nova")
        self.assertEqual(settings["openai"]["model"], "gpt-4o-mini-tts")
        self.assertEqual(settings["elevenlabs"]["model"], "eleven_turbo_v2_5")
        self.assertNotIn("voiceId", settings["elevenlabs"])

    def test_help_does_not_require_or_create_writable_state(self):
        blocked = Path(self.temp.name, "blocked")
        blocked.write_text("not a directory")
        env = {**self.env, "XDG_CONFIG_HOME": str(blocked),
               "XDG_CACHE_HOME": str(blocked), "XDG_RUNTIME_DIR": str(blocked)}
        result = subprocess.run([SPEAK, "--help"], env=env, check=True,
                                text=True, capture_output=True)
        self.assertIn("Usage: speak", result.stdout)

    def test_combined_state_watch_emits_initial_and_config_changes(self):
        watcher = subprocess.Popen(
            [SPEAK, "--watch-state"], env=self.env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            self.assertTrue(select.select([watcher.stdout], [], [], 3)[0])
            initial = json.loads(watcher.stdout.readline())
            self.assertEqual(initial, {"status": "idle", "provider": "piper"})

            self.run_speak("--set", ".provider", "espeak-ng")
            self.assertTrue(select.select([watcher.stdout], [], [], 3)[0])
            changed = json.loads(watcher.stdout.readline())
            self.assertEqual(changed["provider"], "espeak-ng")
        finally:
            watcher.terminate()
            watcher.wait(timeout=3)
            watcher.stdout.close()
            watcher.stderr.close()

    def test_info_never_contacts_a_cloud_provider(self):
        marker = Path(self.temp.name, "curl-was-run")
        tools = Path(self.temp.name, "tools")
        tools.mkdir()
        curl = tools / "curl"
        curl.write_text(f"#!/usr/bin/env bash\nprintf touched > {marker}\nexit 99\n")
        curl.chmod(0o755)
        self.env["PATH"] = f"{tools}:{self.env['PATH']}"
        self.env["ELEVENLABS_API_KEY"] = "safe-test-key"
        self.run_speak("--info")
        self.assertFalse(marker.exists(), "a read-only state query made a network request")

    def test_cloud_voice_refresh_is_explicit_private_and_normalized(self):
        providers = Path(self.temp.name, "omarchy-tts", "providers")
        providers.mkdir(parents=True)
        provider = providers / "cloudtest"
        provider.write_text(
            "#!/usr/bin/env bash\n"
            "# desc: test cloud voice catalogue\n"
            "# kind: cloud\n"
            "[[ ${1:-} == --voices ]] || exit 2\n"
            "printf '%s\\n' '[{\"value\":\"b\",\"label\":\"Zulu\"},"
            "{\"value\":\"a\",\"label\":\"alpha\"},"
            "{\"value\":\"a\",\"label\":\"duplicate\"}]'\n"
        )
        provider.chmod(0o755)

        result = self.run_speak("--refresh-voices", "cloudtest")
        self.assertEqual(json.loads(result.stdout),
                         {"provider": "cloudtest", "count": 2})
        cache = Path(self.temp.name, "omarchy-tts", "voices", "cloudtest.json")
        self.assertEqual(cache.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(cache.read_text()), [
            {"value": "a", "label": "alpha"},
            {"value": "b", "label": "Zulu"},
        ])

    def test_first_elevenlabs_refresh_selects_an_account_voice_once(self):
        providers = Path(self.temp.name, "omarchy-tts", "providers")
        providers.mkdir(parents=True)
        provider = providers / "elevenlabs"
        provider.write_text(
            "#!/usr/bin/env bash\n"
            "# desc: account voices\n# kind: cloud\n# voices: remote\n"
            "[[ ${1:-} == --voices ]] || exit 2\n"
            "printf '%s\\n' '[{\"value\":\"voice-z\",\"label\":\"Zulu\"},"
            "{\"value\":\"voice-a\",\"label\":\"Alpha\"}]'\n"
        )
        provider.chmod(0o755)

        self.run_speak("--refresh-voices", "elevenlabs")
        config = Path(self.temp.name, "omarchy-tts", "config.json")
        self.assertEqual(json.loads(config.read_text())["elevenlabs"]["voiceId"],
                         "voice-a")
        self.run_speak("--set", ".elevenlabs.voiceId", "voice-z")
        self.run_speak("--refresh-voices", "elevenlabs")
        self.assertEqual(json.loads(config.read_text())["elevenlabs"]["voiceId"],
                         "voice-z", "refresh replaced an explicit user choice")

    def test_openai_static_metadata_does_not_require_a_key(self):
        provider_env = {**self.env,
                        "TTS_PLUGIN_DIR": str(ROOT),
                        "TTS_CONFIG": str(Path(self.temp.name, "missing.json")),
                        "TTS_METRICS_FILE": str(Path(self.temp.name, "missing-metrics.json"))}
        empty_path = Path(self.temp.name, "empty-path")
        empty_path.mkdir()
        provider_env["PATH"] = f"{empty_path}:/usr/bin:/bin"
        # A fake failing curl proves these local metadata operations never
        # attempt to invoke it; curl itself may exist in the base test image.
        fake_curl = empty_path / "curl"
        fake_curl.write_text("#!/usr/bin/env bash\nexit 99\n")
        fake_curl.chmod(0o755)
        voices = subprocess.run([ROOT / "providers" / "openai", "--voices"],
                                env=provider_env, check=True, text=True,
                                capture_output=True)
        self.assertIn("cedar", {item["value"] for item in json.loads(voices.stdout)})
        usage = subprocess.run([ROOT / "providers" / "openai", "--usage"],
                               env=provider_env, check=True, text=True,
                               capture_output=True)
        self.assertEqual(json.loads(usage.stdout)["account"]["source"],
                         "request_headers")

    def test_image_only_clipboard_is_ocrd_before_speech(self):
        tools = Path(self.temp.name, "tools")
        providers = Path(self.temp.name, "omarchy-tts", "providers")
        ocr = Path(self.temp.name, "omarchy-tts", "ocr")
        tools.mkdir()
        providers.mkdir(parents=True)
        ocr.mkdir(parents=True)
        captured = Path(self.temp.name, "spoken-text")

        wl_paste = tools / "wl-paste"
        wl_paste.write_text(
            "#!/usr/bin/env bash\n"
            "if [[ ${1:-} == --list-types ]]; then\n"
            "  [[ ${MIXED_CLIPBOARD:-0} == 1 ]] && printf 'text/plain;charset=utf-8\\n'\n"
            "  printf 'image/png\\n'\n"
            "elif [[ $* == *text/plain* ]]; then printf 'Preferred clipboard text.'\n"
            "else printf 'fake-png-bytes'; fi\n"
        )
        wl_paste.chmod(0o755)
        ocr_bin = ocr / "testocr"
        ocr_bin.write_text(
            "#!/usr/bin/env bash\n# desc: test OCR\ncat >/dev/null\n"
            "printf 'Words recovered from the image.\\n'\n"
        )
        ocr_bin.chmod(0o755)
        provider = providers / "capturetest"
        provider.write_text(
            "#!/usr/bin/env bash\n# desc: capture speech input\n# kind: local\n"
            "cat > \"$CAPTURED_TEXT\"\n"
        )
        provider.chmod(0o755)
        self.env["PATH"] = f"{tools}:{self.env['PATH']}"
        self.env["CAPTURED_TEXT"] = str(captured)
        self.run_speak("--set", ".ocr.engine", "testocr")

        self.run_speak("--clipboard", "--provider", "capturetest")
        self.assertEqual(captured.read_text().strip(),
                         "Words recovered from the image.")

        self.env["MIXED_CLIPBOARD"] = "1"
        self.run_speak("--clipboard", "--provider", "capturetest")
        self.assertEqual(captured.read_text().strip(),
                         "Preferred clipboard text.")

    def test_invalid_config_is_preserved_before_recovery(self):
        config = Path(self.temp.name, "omarchy-tts", "config.json")
        config.parent.mkdir(parents=True)
        config.write_text('{"provider":')
        result = self.run_speak("--info")
        self.assertEqual(json.loads(result.stdout)["provider"], "piper")
        preserved = list(config.parent.glob("config.json.invalid.*"))
        self.assertEqual(len(preserved), 1)
        self.assertEqual(preserved[0].read_text(), '{"provider":')
        self.assertEqual(preserved[0].stat().st_mode & 0o777, 0o600)

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

    def test_managed_bindings_follow_the_stable_plugin_symlink(self):
        plugin = Path(self.temp.name, "omarchy", "plugins",
                      "io.github.hikari112.tts")
        first = Path(self.temp.name, "checkout-a")
        second = Path(self.temp.name, "checkout-b")
        for checkout in (first, second):
            (checkout / "bin").mkdir(parents=True)
            (checkout / "bin" / "speak").write_text("#!/bin/sh\n")
        plugin.parent.mkdir(parents=True)
        plugin.symlink_to(first, target_is_directory=True)

        subprocess.run([BINDINGS, "install"], env=self.env, check=True,
                       capture_output=True, text=True)
        target = Path(self.temp.name, "hypr", "bindings.lua")
        rendered = target.read_text()
        self.assertIn(str(plugin / "bin" / "speak"), rendered)
        self.assertNotIn(str(first / "bin" / "speak"), rendered)

        plugin.unlink()
        plugin.symlink_to(second, target_is_directory=True)
        self.assertEqual((plugin / "bin" / "speak").resolve(),
                         (second / "bin" / "speak").resolve())
        self.assertIn(str(plugin / "bin" / "speak"), target.read_text())

    def test_binding_backups_are_bounded(self):
        target = Path(self.temp.name, "hypr", "bindings.lua")
        target.parent.mkdir()
        target.write_text("-- Personal keybindings\n")
        for _ in range(6):
            subprocess.run([BINDINGS, "install"], env=self.env, check=True,
                           capture_output=True, text=True)
        self.assertEqual(len(list(target.parent.glob("bindings.lua.tts.bak.*"))), 3)

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

    def test_concurrent_binding_edits_preserve_both_choices(self):
        first = subprocess.Popen(
            [BINDINGS, "set", "selection", "SUPER + ALT + Z"],
            env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            text=True,
        )
        second = subprocess.Popen(
            [BINDINGS, "set", "clipboard", "SUPER + ALT + V"],
            env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            text=True,
        )
        first_rc = first.wait(timeout=3)
        second_rc = second.wait(timeout=3)
        first_error = first.stderr.read()
        second_error = second.stderr.read()
        first.stderr.close()
        second.stderr.close()
        self.assertEqual(first_rc, 0, first_error)
        self.assertEqual(second_rc, 0, second_error)
        config = Path(self.temp.name, "omarchy-tts", "bindings.json")
        stored = json.loads(config.read_text())
        self.assertEqual(stored["selection"]["chord"], "SUPER + ALT + Z")
        self.assertEqual(stored["clipboard"]["chord"], "SUPER + ALT + V")

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

    def test_failed_voice_catalogue_refresh_preserves_the_cache(self):
        tools = Path(self.temp.name, "catalogue-tools")
        tools.mkdir()
        curl = tools / "curl"
        curl.write_text("#!/usr/bin/env bash\nexit 22\n")
        curl.chmod(0o755)
        self.env["PATH"] = f"{tools}:{self.env['PATH']}"
        catalogue = Path(self.temp.name, "omarchy-tts", "voices.json")
        catalogue.parent.mkdir(parents=True, exist_ok=True)
        original = '{"preserved": {}}\n'
        catalogue.write_text(original)

        result = subprocess.run([ROOT / "bin" / "speak-voice", "refresh"],
                                env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("existing cache was kept", result.stderr)
        self.assertEqual(catalogue.read_text(), original)

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

    def test_setup_cleanup_requires_explicit_confirmation(self):
        result = subprocess.run([SETUP, "cleanup"], env=self.env, text=True,
                                capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["code"],
                         "confirmation_required")

    def test_engine_setup_pins_packages_and_supported_kokoro_python(self):
        source = SETUP.read_text()
        self.assertIn('PIPER_PACKAGE = "piper-tts==1.7.0"', source)
        self.assertIn('KOKORO_PACKAGES = ("kokoro==0.9.4", "soundfile==0.14.0")',
                      source)
        self.assertIn('KOKORO_PYTHON = "3.12"', source)

    def test_runtime_directory_symlinks_are_rejected(self):
        runtime = Path(self.temp.name, "omarchy-tts")
        destination = Path(self.temp.name, "runtime-destination")
        destination.mkdir()
        runtime.symlink_to(destination, target_is_directory=True)
        commands = ([SPEAK, "--status"], [ROOT / "bin" / "speak-voice", "list"],
                    [SETUP, "status"])
        for command in commands:
            result = subprocess.run(command, env=self.env, text=True,
                                    capture_output=True)
            self.assertNotEqual(result.returncode, 0, command)
            self.assertIn("symlink", result.stderr.lower(), command)

    def test_direct_providers_honour_silent_verification(self):
        tools = Path(self.temp.name, "silent-tools")
        tools.mkdir()
        marker = Path(self.temp.name, "provider-args")
        for command in ("espeak-ng", "spd-say"):
            tool = tools / command
            tool.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$*\" > \"$SILENT_MARKER\"\n"
                "cat >/dev/null\n"
            )
            tool.chmod(0o755)
        env = {**self.env, "PATH": f"{tools}:{self.env['PATH']}",
               "TTS_PLUGIN_DIR": str(ROOT), "TTS_SILENT": "1",
               "TTS_RATE": "1.0", "TTS_VOICE": "",
               "SILENT_MARKER": str(marker)}

        subprocess.run([ROOT / "providers" / "espeak-ng"], input="Test.",
                       env=env, text=True, check=True, capture_output=True)
        self.assertIn("--stdout --stdin", marker.read_text())
        subprocess.run([ROOT / "providers" / "spd"], input="Test.",
                       env=env, text=True, check=True, capture_output=True)
        self.assertEqual(marker.read_text().strip(), "--list-output-modules")

    def test_every_bundled_provider_has_a_silent_verification_path(self):
        for provider in (ROOT / "providers").iterdir():
            if not provider.is_file():
                continue
            source = provider.read_text()
            self.assertTrue(
                "TTS_SILENT" in source or "play_raw" in source or "play_file" in source,
                f"{provider.name} bypasses the non-audible verification contract",
            )

    def test_elevenlabs_verify_initializes_voice_for_environment_keys(self):
        providers = Path(self.temp.name, "omarchy-tts", "providers")
        providers.mkdir(parents=True, exist_ok=True)
        provider = providers / "elevenlabs"
        provider.write_text(
            "#!/usr/bin/env bash\n# kind: cloud\n"
            "if [[ ${1:-} == --voices ]]; then\n"
            "  printf '%s\\n' '[{\"value\":\"account-voice\",\"label\":\"Account voice\"}]'\n"
            "  exit 0\n"
            "fi\n"
            "[[ ${TTS_VOICE:-} == account-voice ]] || exit 3\n"
            "cat >/dev/null\n"
        )
        provider.chmod(0o755)
        result = self.run_speak("--verify", "elevenlabs")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = Path(self.temp.name, "omarchy-tts", "config.json")
        self.assertEqual(json.loads(config.read_text())["elevenlabs"]["voiceId"],
                         "account-voice")

    def test_test_dock_uses_the_same_sanitizer_as_normal_speech(self):
        controller = (ROOT / "components" / "TtsController.qml").read_text()
        speak_line = next(line for line in controller.splitlines()
                          if "function speak(text)" in line)
        self.assertNotIn("--raw", speak_line)

    def test_setup_registers_worker_identity_before_reporting_started(self):
        tools = Path(self.temp.name, "setup-tools")
        tools.mkdir()
        for name, body in {
            "pkexec": "exit 0",
            "pacman": "exit 0",
            "espeak-ng": "cat >/dev/null",
        }.items():
            tool = tools / name
            tool.write_text(f"#!/usr/bin/env bash\n{body}\n")
            tool.chmod(0o755)
        self.env["PATH"] = f"{tools}:{self.env['PATH']}"

        started = subprocess.run([SETUP, "start", "espeak-ng"], env=self.env,
                                 check=True, capture_output=True, text=True)
        payload = json.loads(started.stdout)
        self.assertTrue(payload["ok"])
        state = Path(self.temp.name, "omarchy-tts", "setup.json")
        registered = json.loads(state.read_text())
        self.assertEqual(registered["pid"], payload["pid"])
        self.assertTrue(registered["processIdentity"])

        for _ in range(100):
            current = json.loads(state.read_text())
            if current["status"] in {"done", "error"}:
                break
            time.sleep(0.02)
        self.assertEqual(current["status"], "done", current)


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

    def test_health_writer_recovers_a_truncated_cache_atomically(self):
        health = self.home / "cache" / "omarchy-tts" / "health.json"
        health.parent.mkdir(parents=True)
        health.write_text('{"worktest":')
        self.write_provider("worktest", "cat > /dev/null")
        result = self.speak("--verify", "worktest")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(health.read_text())["worktest"]["status"], "ok")
        self.assertEqual(health.stat().st_mode & 0o777, 0o600)

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
        status_file = self.home / "run" / "omarchy-tts" / "status"
        self.assertEqual(pid_file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(status_file.stat().st_mode & 0o777, 0o600)
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
            "x-ratelimit-reset-requests: 1s\r\nretry-after: 2s\r\n"
            "character-cost: 7\r\n\r\n"
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
            "[[ -z $writeout ]] || printf '%s' \"${FAKE_HTTP_STATUS:-200}\"\n"
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
                   "TTS_VOICE": "test-voice",
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

    def test_paid_provider_limits_are_normalized_and_actionable(self):
        metrics = self.root / "limits.json"
        base = {**os.environ,
                "PATH": f"{self.bin}:{os.environ['PATH']}",
                "FAKE_CURL_ARGS": str(self.args), "FAKE_CURL_BODY": str(self.body),
                "FAKE_CURL_HEADERS": str(self.headers),
                "FAKE_RESPONSE_HEADERS": str(self.response_headers),
                "XDG_RUNTIME_DIR": str(self.root), "TTS_PLUGIN_DIR": str(ROOT),
                "TTS_CONFIG": str(self.config), "TTS_SILENT": "1",
                "TTS_METRICS_FILE": str(metrics),
                "OPENAI_API_KEY": "safe-test-key"}
        for status, returncode, error_code, message in (
            ("429", 75, "rate_limit", "rate or concurrency limit"),
            ("402", 69, "quota", "billing limit"),
            ("401", 77, "auth", "API key was rejected"),
        ):
            result = subprocess.run(
                [ROOT / "providers" / "openai"], input="hello", text=True,
                capture_output=True, env={**base, "FAKE_HTTP_STATUS": status},
            )
            self.assertEqual(result.returncode, returncode, result.stderr)
            self.assertIn(message, result.stderr)
            telemetry = json.loads(metrics.read_text())
            self.assertEqual(telemetry["lastRequest"]["errorCode"], error_code)
            self.assertEqual(telemetry["lastRequest"]["retryAfter"], "2s")

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


class CancelledSpeechTests(unittest.TestCase):
    """Stopping speech must never be recorded as a broken provider.

    A provider that execs a player does not necessarily die by the signal sent
    to it. mpv catches SIGTERM and exits 4, so stopping cloud speech marked the
    backend failing, the panel then offered only "Replace key", and the
    provider could not be selected again.
    """

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.env = {**os.environ,
                    "XDG_CONFIG_HOME": str(self.home / "config"),
                    "XDG_CACHE_HOME": str(self.home / "cache"),
                    "XDG_RUNTIME_DIR": str(self.home / "run")}
        self.env.pop("HYPRLAND_INSTANCE_SIGNATURE", None)
        (self.home / "run").mkdir(parents=True)
        self.providers = self.home / "config" / "omarchy-tts" / "providers"
        self.providers.mkdir(parents=True)

    def tearDown(self):
        self.temp.cleanup()

    def write_provider(self, name, body):
        path = self.providers / name
        path.write_text("#!/usr/bin/env bash\n"
                        f"# desc: test provider {name}\n"
                        "# kind: local\n"
                        "# probe: true\n"
                        f"{body}\n")
        path.chmod(0o755)

    def status_of(self, name):
        info = json.loads(subprocess.run([SPEAK, "--info"], text=True,
                                         capture_output=True, env=self.env).stdout)
        return next(p["status"] for p in info["providers"] if p["name"] == name)

    def test_stopping_a_signal_translating_provider_is_not_a_failure(self):
        # Exits 4 on SIGTERM instead of dying by signal, exactly as mpv does.
        self.write_provider("mpvlike",
                            'trap "exit 4" TERM\ncat > /dev/null\nsleep 30 &\nwait $!')
        speaking = subprocess.Popen([SPEAK, "--provider", "mpvlike"],
                                    stdin=subprocess.PIPE, text=True, env=self.env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        speaking.stdin.write("Interrupt me.\n")
        speaking.stdin.close()
        time.sleep(1.5)
        subprocess.run([SPEAK, "--stop"], env=self.env, capture_output=True)
        speaking.wait(timeout=30)
        self.assertNotEqual(self.status_of("mpvlike"), "failing",
                            "a stopped provider was recorded as broken")

    def test_a_genuine_failure_is_still_recorded(self):
        self.write_provider("brokenlike", "cat > /dev/null; exit 4")
        subprocess.run([SPEAK, "--provider", "brokenlike"], input="Hello.",
                       text=True, env=self.env, capture_output=True)
        self.assertEqual(self.status_of("brokenlike"), "failing",
                         "an uncancelled failure must still mark the provider")


if __name__ == "__main__":
    unittest.main(verbosity=2)
