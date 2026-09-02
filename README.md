# omarchy-tts — speak highlighted text

[![CI](https://github.com/hikari112/omarchy-tts/actions/workflows/ci.yml/badge.svg)](https://github.com/hikari112/omarchy-tts/actions/workflows/ci.yml)

On-demand text-to-speech for Omarchy. Highlight anything, press a key, hear it —
or drag a box over text that cannot be selected at all and hear that instead.
Works in any app, because it reads the Wayland selection and the screen itself
rather than AT-SPI, which Hyprland does not implement.

## Install

```bash
omarchy plugin add https://github.com/hikari112/omarchy-tts.git --enable
```

Click the speaker in the bar. The welcome screen installs the recommended
local engine and voice; the **Keys** tab installs the shortcuts. Both are
guided, cancellable operations—no terminal setup or manual config editing.

## Requirements

`wl-clipboard`, `jq`, `python3`, `flock` (util-linux), and PipeWire or ALSA. For the OCR modes:
`tesseract`, `grim`, `slurp`, and optionally `hyprpicker`. All ship with Omarchy.

## Keys

| Key | Action |
|-----|--------|
| `SUPER+ALT+E` | Speak the highlighted text (press again to stop) |
| `SUPER+ALT+A` | Speak the clipboard |
| `SUPER+ALT+X` | Stop immediately |
| `SUPER+ALT+R` | **Drag a box, hear the text in it** (OCR) |
| `SUPER+ALT+W` | Read the focused window — no pointer needed |
| `SUPER+ALT+SHIFT+R` | Read the whole screen — no pointer needed |

Bar widget: left-click opens settings; right-click speaks the selection or
stops the current speech.

## CLI

```bash
speak "hello world"           # speak an argument
cat notes.md | speak          # speak stdin
journalctl -n 20 | speak      # speak command output
speak --selection             # speak the highlighted text
speak --snip                  # drag a region, OCR it, speak it
speak --window                # read the focused window
speak --stop                  # stop
speak --list                  # list providers
speak --provider espeak-ng    # override for one run
speak --usage elevenlabs      # refresh paid-plan usage (JSON)
```

## Voices

```bash
speak-voice list                  # installed voices
speak-voice available             # all 175, installed first
speak-voice available --json      # same, for scripting
speak-voice add en_GB-alba-medium # download (--async to background it)
speak-voice use en_GB-alba-medium # make it the default
speak-voice remove <voice>        # delete one
speak-voice status                # progress of a download in flight
speak-voice refresh               # re-fetch the catalogue
speak-voice browse                # listen to samples in a browser
```

## Settings panel

Click the speaker in the bar. Right-click it to speak the selection without
opening anything.

Five tabs, and a Test dock that stays visible on all of them so you can hear
a change straight after making it:

- **Provider** — all six at once, each showing whether it actually works on
  this machine. Cloud providers carry a standing note that text leaves the
  machine, and the Test dock says `runs locally` or names the vendor.
- **Voice** — installed voice, speed, length limit, and **Browse all voices**:
  every one of the 175 downloadable voices across 51 languages, showing which
  are installed, with size and a one-click download that reports progress and
  verifies the md5 before installing.
- **Text** — live before/after sanitizer preview and readability rules.
- **Screen** — OCR confidence floor and language selection.
- **Keys** — capture, install, update, or remove the plugin-owned shortcuts.

Settings write on change; there is no Save button. Configuration is created
on first use, migrated additively, written atomically, and kept mode 0600.
Everything the panel shows
comes from `speak --info`, and everything it changes goes through
`speak --set`, so the panel is a front-end to the CLI rather than a second
implementation of it.

## Reading the screen (OCR)

Text in an image, a scanned PDF, a locked menu, a paused video frame — none of
it can be selected, so none of it can be read by conventional means. `--snip`
drags a box over it, runs OCR, and speaks the result.

```bash
speak --snip       # drag a region                  (pointer)
speak --window     # the focused window             (no pointer)
speak --screen     # the focused monitor            (no pointer)
```

Two of the three need no pointer at all, which matters if dragging a box is
not an option for you.

OCR engines live in `ocr/` and follow the same contract as voice providers: an
executable reading a PNG on stdin and writing text on stdout. `~/.config/omarchy-tts/ocr/`
shadows the bundled ones.

**Low-confidence words are discarded.** Tesseract reports a per-word confidence
score, and anything below `ocr.minConfidence` (default 60) is dropped rather
than spoken. Someone using this to read a screen they cannot check has no way
to notice an invented word, so silence is preferred to noise. Set it to `0` to
keep everything.

OCR text is also reflowed before speaking: wrapped lines are rejoined into
paragraphs, words split across a line break are put back together, and stray
characters from neighbouring columns are dropped. Without that, a paragraph is
read back as one. short. burst. per. line.

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

Add or remove keys from the **Provider** tab. They are entered in a masked
field and stored in the system keyring, never in the plugin settings or logs.
The panel clearly marks providers that send text off the machine. Paid
providers also show the configured model, locally observed request/character
counts, last request status, and rate-limit headers. **Refresh usage** reads
ElevenLabs plan usage and reset time directly from its subscription API.
OpenAI request and token limits update from response headers; organization-wide
usage is deliberately not queried with the normal speech key because that API
requires a separate organization admin key.

Cloud telemetry is stored mode 0600 under `~/.cache/omarchy-tts/cloud/` and
contains counts, timestamps, request IDs, limits, and normalized error codes.
It never contains API keys, selected text, or provider response bodies.

## Remove

Remove the plugin from Omarchy's plugin manager. Before removing it, use
**Keys → Remove TTS bindings** so no shortcuts are left behind. API keys can
be removed individually from the Provider tab. Voice models and engines live
under `~/.local/share/omarchy-tts` so any remaining downloaded data is easy to
identify and remove.

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
cat something.md | python3 ~/.config/omarchy/plugins/io.github.hikari112.tts/lib/sanitize.py
```

## Development

```bash
python3 tests/test_sanitize.py
python3 tests/test_cli.py
python3 -m py_compile bin/speak-bindings bin/speak-setup
shellcheck -x bin/speak bin/speak-voice providers/* ocr/* lib/*.sh
```

Because the repo is symlinked into `~/.config/omarchy/plugins/`, saving any
file reloads the widget in the bar immediately.

## License

MIT — see [LICENSE](LICENSE).
