# Architecture and review handoff

This branch implements the full settings-panel design while retaining the
newer OCR work. The panel now has Provider, Voice, Text, Screen and Keys tabs.

## Ownership boundaries

- `bin/speak` is the public speech and settings API.
- `lib/config.sh` owns schema migration, validation and atomic config writes.
- `lib/sanitize.py` is the one sanitizer used for speech and live preview.
- provider executables declare small metadata headers consumed by `--info`.
- `bin/speak-voice` owns Piper catalogue/download lifecycle.
- `bin/speak-bindings` owns only the text between its markers in
  `~/.config/hypr/bindings.lua`; it backs up and validates every write.
- `components/TtsController.qml` is the async bridge from QML to those CLIs.
- `Panel.qml` owns presentation and transient interaction state.

QML uses argv arrays for user-controlled values. Shell interpretation is
limited to reviewed provider install commands opened visibly in a terminal.
Cloud keys are entered in a terminal and stored with Secret Service; the key
never returns to QML or appears in a process argument.

## Configuration

`config.json` schema version 2 is additive and backwards compatible. Startup
fills missing defaults without replacing existing values. Writes are limited
to an allowlist and use an atomic rename with mode 0600.

## Deliberate design changes

- Screen is retained as a fifth tab.
- Keys use Omarchy's current Lua configuration, not the obsolete `.conf` file
  in the original mockup.
- Provider installs use reviewed Omarchy/uv commands and require confirmation.
- API keys use the system keyring rather than a plaintext keys file.
- Live speed changes apply to the next utterance because current providers do
  not expose safe in-place playback speed updates.

## Suggested reviewer path

1. `lib/config.sh` and `bin/speak --info/--set`
2. `components/TtsController.qml`
3. the five sections in `Panel.qml`
4. `bin/speak-bindings` safety/rollback behavior
5. provider metadata and voice download behavior

Run `python3 tests/test_sanitize.py`, `python3 tests/test_cli.py`, and the
ShellCheck command from the README. A live QML review requires omarchy-shell.
