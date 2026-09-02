# Changelog

All notable changes are documented here. This project follows Semantic
Versioning.

## Unreleased

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

## 1.1.0 - 2026-09-02

- Add a complete five-tab settings panel and live speech controls.
- Add graphical first-run setup, provider installation, and keyring entry.
- Add searchable, cancellable Piper voice downloads with integrity checks.
- Add safe shortcut capture, conflict detection, backup, and rollback.
- Add local OCR modes and configurable text sanitization.
- Keep plugin engines and voices in an isolated data directory.

## 1.0.0

- Initial release.
