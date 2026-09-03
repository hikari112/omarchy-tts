# Security policy

Please [report vulnerabilities privately](https://github.com/hikari112/omarchy-tts/security/advisories/new)
through GitHub Security Advisories. Do not include API keys, selected text,
clipboard contents, or screenshots in a report.

The project supports the latest release. Cloud-provider keys are stored in the
desktop keyring. Diagnostic output intentionally excludes spoken and selected
text. Local providers and OCR remain on-device; cloud providers are opt-in and
are labelled in the interface.

Environment variables can supply cloud keys and deliberately take precedence
over the keyring. Key material is validated before use, passed to bundled
providers through private descriptors or standard input rather than URL or
command arguments, and never written to configuration.

Cloud request telemetry is restricted to mode 0600 cache files. It records
counts, timestamps, provider request IDs, normalized error codes, and returned
limit headers; it never records selected text, credentials, or response bodies.
Provider errors shown to users are normalized rather than echoing remote bodies,
which can contain request details.

Account-specific cloud voice metadata is fetched only by an explicit refresh,
stored in a mode 0600 cache, and never printed by the refresh command. Opening
the settings panel is a local-only operation and does not contact cloud APIs.

Public speech input is capped at 1 MiB and captured images at 50 MiB before
provider or OCR processing. Bundled network adapters require HTTPS across
redirects, use finite connection and request timeouts, cap response/audio
sizes, and enforce advertised service limits before upload. Piper catalogue
entries, models, and sidecars have independent size bounds; downloads are
published only after exact-size and available digest verification.

Configuration, runtime ownership, health, telemetry, setup journals, and job
state use private permissions and atomic replacement. Runtime directories must
be owned by the current user and cannot be symlinks. Config symlink targets are
preserved deliberately, dangling targets are rejected, and interrupted engine
or voice replacement is recovered transactionally on the next operation.
