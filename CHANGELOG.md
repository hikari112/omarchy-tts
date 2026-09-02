# Changelog

All notable changes are documented here. This project follows Semantic
Versioning.

## Unreleased

## 1.2.0 - 2026-09-02

- Add privacy-safe paid-provider telemetry, live ElevenLabs subscription usage,
  OpenAI rate-limit windows, actionable quota/rate errors, and panel refresh.
- Preserve provider health across transient rate, quota, and service failures,
  and enforce OpenAI's documented 4096-character request boundary locally.
- Make speech replacement race-safe so an older process cannot erase the
  active process's stop/status state.
- Preserve malformed configuration files before recovering with defaults.
- Keep runtime state private and reject runtime directories owned by another
  user.
- Serialize settings writes and foreground actions from the settings panel.
- Validate CLI overrides and captured shortcut syntax at their boundaries.
- Prevent concurrent voice downloads and verify both model size and digest.
- Keep cloud keys and spoken text out of process arguments, keep API errors
  out of the audio path, and bound network waits.
- Pass Kokoro text outside the process environment to support large input and
  reduce exposure through process inspection.
- Refine first-run and provider-selection states around proven readiness.
- Validate process start identities before stopping speech, serialize config
  and health writers, and force-kill providers that ignore verification
  timeouts.
- Serialize setup and voice-download jobs, make repeated voice installation
  non-destructive, and remove progress/completion state races.
- Detect shortcut conflicts against active Hyprland defaults and persist only
  user-owned chord choices so plugin moves cannot leave stale command paths.
- Match Omarchy's bar popout handoff contract and broaden keyboard shortcut
  capture to function, navigation, and punctuation keys.
- Enforce structurally valid one-key shortcuts, stream cloud request text
  without temporary plaintext files, and reject plaintext configuration keys
  so key storage matches the documented keyring-only policy.

## 1.1.0 - 2026-09-02

- Add a complete five-tab settings panel and live speech controls.
- Add graphical first-run setup, provider installation, and keyring entry.
- Add searchable, cancellable Piper voice downloads with integrity checks.
- Add safe shortcut capture, conflict detection, backup, and rollback.
- Add local OCR modes and configurable text sanitization.
- Keep plugin engines and voices in an isolated data directory.

## 1.0.0

- Initial release.
