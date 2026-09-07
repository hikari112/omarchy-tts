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

## Supply chain

Everything the plugin installs after the initial `omarchy plugin add` is fixed
by the reviewed commit:

- **Engine code**: `lib/engines/<engine>.lock` is the complete dependency
  closure for Linux x86_64 / Python 3.12 with a SHA-256 for every wheel,
  compiled reproducibly (`lib/engines/EXCLUDE_NEWER`); the installer applies it
  with `uv pip sync --require-hashes --only-binary :all:`, so nothing outside
  the lock can be installed and no source build can run. A dependency that
  publishes no wheel is shipped as a reviewed, reproducibly built wheel in
  `lib/engines/wheels` (digests in `SHA256SUMS`, checked before `uv` runs).
- **Model artefacts**: `lib/engines/models.json` (EasyOCR, Kokoro) and
  `lib/piper-voices.sha256` (Piper voices) name fixed sources and digests:
  Kokoro and Piper files come from one immutable repository revision; EasyOCR
  archives come from fixed GitHub release-asset URLs, whose content is bound
  by the shipped digest (a re-uploaded asset fails closed). Downloads that do
  not match are discarded; files are verified again before every load; library
  downloaders are never enabled and the Hugging Face hub client runs offline.
- **Engines from earlier releases**: each environment records the digest of
  the lock that built it; probes, status and the engines themselves treat an
  environment without this release's digest as not installed.
- **Privilege boundary**: `pkexec` and `pacman` are used at fixed canonical
  paths, verified root-owned and unwritable by others up to `/`, immediately
  before each call. Only `uv` and `tesseract-data-*` packages are ever
  installed this way, and only after an explicit click.

Residual trust roots, stated so they can be judged: `uv` is used only at
`/usr/bin/uv` from the distribution's repository (installed through the
privileged path if absent), runs with `--no-config` and without `UV_*`/`PIP_*`
overrides, and provides the Python 3.12 interpreter - one already on the
system or a python-build-standalone build it downloads and verifies against
checksums compiled into `uv`; a distribution-installed `piper` on `PATH` is
accepted when no managed engine exists; hash-locked wheels come from PyPI and
model artefacts from GitHub and Hugging Face, but every one of those is bound
by a digest in this repository, so those services can withhold a file, never
substitute one.

`tools/pin-engines` and `tools/pin-piper-voices` regenerate these files so a
bump is a reviewable diff, and CI proves the locks apply and reproduce.
