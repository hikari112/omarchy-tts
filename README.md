# hikari.tts — speak highlighted text

On-demand text-to-speech for Omarchy. Highlight anything, press a key, hear it.
Works in any app that supports the Wayland primary selection — terminal,
browser, PDF viewer — because it never touches AT-SPI.

## Keys

| Key | Action |
|-----|--------|
| `SUPER+ALT+S` | Speak the highlighted text (press again to stop) |
| `SUPER+ALT+C` | Speak the clipboard |
| `SUPER+ALT+X` | Stop immediately |

Bar widget: left-click speaks the selection, right-click cycles providers.

## CLI

```bash
speak "hello world"           # speak an argument
cat notes.md | speak          # speak stdin
journalctl -n 20 | speak      # speak command output
speak --selection             # speak the highlighted text
speak --stop                  # stop
speak --list                  # list providers
speak --provider espeak-ng    # override for one run
```

## Voices

```bash
speak-voice list              # installed voices
speak-voice add en_GB-alba-medium
speak-voice use en_GB-alba-medium
speak-voice browse            # sample the catalogue
```

## Providers

Bundled, all optional except piper:

| Provider | Kind | Notes |
|----------|------|-------|
| `piper` | local | **default** — neural, fast, ~60 MB/voice |
| `espeak-ng` | local | robotic but instant; `omarchy pkg add espeak-ng` |
| `spd` | local | speech-dispatcher, the standard a11y stack |
| `kokoro` | local | best quality, slow cold start, opt-in |
| `openai` | cloud | opt-in; **text leaves your machine** |
| `elevenlabs` | cloud | opt-in; **text leaves your machine** |

### Bring your own

A provider is any executable that reads text on stdin and plays it. Drop one
in `~/.config/omarchy-tts/providers/` and it shadows the bundled provider of
the same name.

```bash
#!/usr/bin/env bash
# desc: my custom voice
exec my-tts-engine --voice "${TTS_VOICE:-default}" --speed "${TTS_RATE:-1.0}"
```

Environment given to providers: `TTS_VOICE`, `TTS_RATE`, `TTS_PLUGIN_DIR`,
`TTS_CONFIG`.

### Cloud API keys

Never stored in plaintext by default. Resolution order is env var, then
system keyring, then config file:

```bash
secret-tool store --label='openai' service omarchy-tts key openai
```

## Config

`~/.config/omarchy-tts/config.json` — `provider`, `rate`, `maxChars`
(0 = unlimited), plus per-provider voice settings.

## The sanitizer

`lib/sanitize.py` is what makes this bearable. It strips ANSI escapes, Nerd
Font glyphs, and box drawing; flattens markdown tables into readable rows;
shortens paths to basenames; replaces hashes and UUIDs with a word; and
turns line breaks into sentence pauses. Selecting a 64-character SHA256 gets
you the word "hash", not thirty seconds of hex.

Test it standalone:

```bash
cat something.md | python3 ~/.config/omarchy/plugins/hikari.tts/lib/sanitize.py
```
