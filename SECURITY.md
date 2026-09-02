# Security policy

Please report vulnerabilities privately through GitHub Security Advisories.
Do not include API keys, selected text, clipboard contents, or screenshots in
a report.

The project supports the latest release. Cloud-provider keys are stored in the
desktop keyring. Diagnostic output intentionally excludes spoken and selected
text. Local providers and OCR remain on-device; cloud providers are opt-in and
are labelled in the interface.

Cloud request telemetry is restricted to mode 0600 cache files. It records
counts, timestamps, provider request IDs, normalized error codes, and returned
limit headers; it never records selected text, credentials, or response bodies.
Provider errors shown to users are normalized rather than echoing remote bodies,
which can contain request details.
