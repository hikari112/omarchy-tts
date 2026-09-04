# Architecture and review guide

The plugin has a six-tab settings panel: Provider, Voice, Text, Screen,
Languages, and Keys. Its command-line boundary remains independently useful
and testable.

## Ownership boundaries

- `bin/speak` is the public speech and settings API.
- `lib/config.sh` owns schema migration, validation and atomic config writes.
- `lib/health.sh` owns shared, atomic health-cache invalidation.
- `lib/sanitize.py` is the one sanitizer used for speech and live preview.
- provider executables declare small metadata headers consumed by `--info`.
- `bin/speak-voice` owns Piper catalogue/download lifecycle.
- `bin/speak-bindings` owns only the text between its markers in
  `~/.config/hypr/bindings.lua`; it backs up and validates every write. Its
  private JSON stores only chord choices—labels, commands, and installation
  paths are always derived from the current plugin.
- `components/TtsController.qml` is the async bridge from QML to those CLIs.
- `Panel.qml` owns presentation and transient interaction state.

QML uses argv arrays for user-controlled values. Shell interpretation is
limited to a fixed allowlist handled by the graphical setup backend.
Cloud keys are entered in a masked panel field and stored with Secret Service;
the key never returns to QML or appears in a process argument.

## Configuration

`config.json` schema version 4 is additive and backwards compatible. Startup
fills missing defaults without replacing existing values. ElevenLabs has no
global default voice: the first successful account-voice refresh selects one
only when the user has not already made a choice. Schema 3 migrates the former
ElevenLabs default model to `eleven_flash_v2_5`; schema 4 standardizes Gemini
on the Google AI Developer API. Invalid JSON, oversized files, and unsafe
nested shapes are preserved with an `.invalid.<timestamp>` suffix before
type-safe defaults are restored. Writes are limited to an allowlist, serialized,
and use an atomic rename with mode 0600. Existing config symlinks keep pointing
to the same target, while dangling symlinks are rejected.

Runtime state is stored in a private, user-owned directory. Speech and
background jobs record both process ownership and identity; callers must only
clear state they still own, and the UI does not expose cancellation until that
identity is confirmed. Provider/OCR health entries carry fingerprints of the
adapter, relevant configuration, and credential source, so old proof becomes
untested after meaningful changes. QML settings writes are serialized, with
redundant pending writes to the same property coalesced.

Provider headers are the capability boundary consumed by `speak --info`.
Alongside descriptive fields, adapters can declare byte/character limits,
credential names and environment variables, deprecation, account voice
refresh, and usage refresh. The panel acts on those normalized fields instead
of inferring behavior from a filename.

Speech preparation and playback have separate, identity-checked ownership
records. A new utterance atomically hands off under the speech lock; Stop can
cancel selection, capture, OCR, provider preparation, or playback without PID
reuse races. Public text and capture inputs, catalogue records, downloads, and
cloud responses all have explicit size ceilings.

Managed engine setup and Piper voice publication are transactions. Engine
activation records a private recovery journal before replacing a proven
generation; voice repair stages and verifies both the model and sidecar before
publishing the pair under the same lock Piper holds while reading them. A later
invocation repairs artifacts left by abrupt process death or power loss.

## Deliberate design changes

- Screen remains a dedicated tab, with recognition languages separated into
  their own focused browser.
- Keys use Omarchy's current Lua configuration, not the obsolete `.conf` file
  in the original mockup.
- Provider installs use reviewed Omarchy/uv commands and require confirmation.
- Direct engine packages are release-pinned; Kokoro deliberately uses an
  isolated Python 3.12 because its published metadata excludes newer Python.
- API keys use the system keyring rather than a plaintext keys file.
- Live speed changes apply to the next utterance because current providers do
  not expose safe in-place playback speed updates.

## Suggested reviewer path

1. `lib/config.sh` and `bin/speak --info/--set`
2. `components/TtsController.qml`
3. the six sections in `Panel.qml`
4. `bin/speak-setup` transaction and recovery behavior
5. `bin/speak-voice` catalogue, verification, publication, and recovery
6. `bin/speak-bindings` safety and coupled rollback behavior
7. provider/OCR request construction, bounds, and error normalization

Run `python3 -m unittest discover -s tests -v` and the ShellCheck command from
the README. The suite includes static QML interaction contracts; a full visual
review still requires omarchy-shell.

## Re-pinning Piper voices

Voices download from one immutable revision of `rhasspy/piper-voices`, and
every model and sidecar is verified against `lib/piper-voices.sha256`. To move
to a newer upstream revision:

```bash
tools/pin-piper-voices <40-hex revision>
```

It rewrites `lib/piper-voices.json`, `lib/piper-voices.sha256`, and the
`PIPER_VOICES_REV` constant in `bin/speak-voice`. Review the diff like any
other dependency bump; the digests are the trust root for every download.
