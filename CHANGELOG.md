# Changelog

All notable changes are documented here. This project follows Semantic
Versioning.

## Unreleased

## 1.3.0 - 2026-09-03

- Add selectable EasyOCR, OpenAI Vision, and Google Cloud Vision recognition
  engines, with per-engine language state, explicit language discovery, and
  safe Tesseract language-pack installation.
- Add Gemini and Google Cloud Text-to-Speech providers, account-backed Google
  and ElevenLabs voice browsing, and metadata-driven refresh/usage actions.
- Expand the settings panel to six scrollable views, add filtered cloud voice
  browsing, make inline controls keyboard-safe, and clearly distinguish local
  processing, cloud disclosure, key sources, and environment-key remediation.
- Preserve `espeak-ng` and Speech Dispatcher configurations across upgrades as
  hidden compatibility providers while steering new configurations to Piper.
- Bind readiness to the exact adapter, relevant configuration, and credential
  source so stale health results cannot survive an upgrade, voice/language
  change, or key mutation; bound provider probes that do not return.
- Close setup and voice-download cancellation races by withholding cancellable
  state until the worker publishes a verified PID identity, and reconcile jobs
  that terminate unexpectedly.
- Accept fully non-Latin selections, keep sanitizer output within its exact
  configured limit, and enforce Google Cloud's 5,000-byte UTF-8 request limit
  before sending text.
- Normalize embedded Google Vision failures without echoing remote response
  details, record HTTP-200 error envelopes accurately, and reject invalid
  Gemini API-host settings before any network request.
- Pin EasyOCR and the Kokoro spaCy model artifact, bound installer-log memory,
  make cleanup failures truthful, and invalidate both speech and OCR health for
  shared Google/OpenAI credential changes.
- Run the complete regression suite on staging pushes as well as main, pin CI
  actions to current Node 24 releases, and add static UI contracts for worker
  identity, key purpose, scrolling, focus, and metadata-driven actions.
- Make configuration migration type-safe at every nested boundary, preserve
  malformed inputs for recovery, serialize no-op-aware atomic writes, retain
  valid symlink targets, and reject dangling or non-regular destinations.
- Give selection, capture, OCR, playback, setup, and download jobs verified
  process ownership so Stop/Cancel cannot signal a reused PID or lose a handoff;
  require detached workers to inherit their held job locks, and recover engine
  and voice publication after abrupt termination.
- Bound speech input, captures, catalogues, model artifacts, remote metadata,
  JSON responses, and audio responses; require HTTPS across redirects and
  reject ambiguous or invalid download metadata before network access; keep
  runtime and cache publication from traversing reserved special-file nodes.
- Publish Piper models and sidecars as one verified generation under a shared
  reader/writer lock, repair incomplete installations non-destructively, and
  keep the active voice protected from removal.
- Harden API-key validation and error separation, keep request bodies and keys
  out of argv and logs, normalize remote failure output, and retain only
  privacy-safe, owner-readable telemetry.
- Make speed controls provider-capability-aware, reject unsupported explicit
  overrides, clamp cross-provider persisted preferences safely, improve
  keyboard and assistive labels, render user/service strings as plain text, and
  keep all panel process input JSON-safe.

## 1.2.3 - 2026-09-02

- Add a root `preview.png` for marketplace listing cards.
- Fall back to an owner-only `$XDG_STATE_HOME` directory instead of shared
  `/tmp` when no session runtime directory exists, so runtime PID state is
  never placed where another user could pre-populate it.

## 1.2.2 - 2026-09-02

- Make provider verification silent for every bundled backend and document the
  complete provider environment contract.
- Select ElevenLabs voices from the user's account instead of shipping a stale
  global voice identifier, while preserving existing user choices.
- Keep managed shortcuts attached to the stable Omarchy plugin path when a
  development symlink is retargeted, and retain only the newest three backups.
- Harden runtime-directory, configured-provider, voice-id, and URL-path
  boundaries against symlink and traversal mistakes.
- Apply the configured sanitizer to settings-panel test speech and remove
  redundant long-running status work.
- Consolidate OpenAI voice metadata, reduce `--info` subprocess work, and make
  OCR provider environments consistent across every capture source.
- Require explicit confirmation before cleanup removes shortcuts and API keys.
- Pin direct engine dependencies, keep Kokoro on its supported Python runtime,
  recover truncated health state, serialize concurrent shortcut edits, and
  preserve the voice catalogue when a forced refresh fails.
- Refresh the README, contributor workflow, security guidance, screenshots,
  and marketplace-facing release documentation.

## 1.2.1 - 2026-09-02

- Add local OCR for image-only clipboard content while preferring text when
  both clipboard representations are available.
- Reframe the public documentation around truthful on-demand, local-first
  desktop reading and explicitly distinguish it from a structural screen reader.
- Complete the Quattro bar-widget lifecycle contract and test it in CI.
- Make CLI help and OpenAI's local metadata independent of writable state and
  network tooling.
- Close the setup-worker cancellation race by requiring a verified process
  identity before reporting that installation started.
- Propagate private telemetry write failures instead of reporting stale data as
  a successful account refresh.
- Make settings-state reads network-free and cloud voice refresh explicit.
- Use ElevenLabs' current paginated v2 voice API, with bounded pagination and
  private, atomic account-voice caching.
- Isolate CLI tests from the user's real cache, keyring, and session bus.

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
