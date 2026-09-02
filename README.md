# omarchy-tts — speak highlighted text

[![CI](https://github.com/hikari112/omarchy-tts/actions/workflows/ci.yml/badge.svg)](https://github.com/hikari112/omarchy-tts/actions/workflows/ci.yml)

On-demand text-to-speech for Omarchy. Highlight anything, press a key, hear it —
or drag a box over text that cannot be selected at all and hear that instead.
Works in any app, because it reads the Wayland selection and the screen itself
rather than AT-SPI, which Hyprland does not implement.

## Install

```bash
omarchy plugin add https://github.com/hikari112/omarchy-tts
omarchy plugin enable io.github.hikari112.tts right
```

Then install the speech engine and a voice (no root needed):

```bash
uv tool install piper-tts
speak-voice add en_US-amy-medium
```

Add the keybindings to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + E", "Speak selection", "speak --toggle")
o.bind("SUPER + ALT + A", "Speak clipboard", "speak --clipboard")
o.bind("SUPER + ALT + X", "Stop speaking", "speak --stop")
o.bind("SUPER + ALT + R", "Speak screen region", "speak --snip")
o.bind("SUPER + ALT + W", "Speak focused window", "speak --window")
o.bind("SUPER + ALT + SHIFT + R", "Speak whole screen", "speak --screen")
```

## Requirements

`wl-clipboard`, `jq`, `python3`, and PipeWire or ALSA. For the OCR modes:
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

Bar widget: left-click speaks the selection, right-click cycles providers.

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
```

## Voices

```bash
speak-voice list              # installed voices
speak-voice add en_GB-alba-medium
speak-voice use en_GB-alba-medium
speak-voice browse            # sample the catalogue
```

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
cat something.md | python3 ~/.config/omarchy/plugins/io.github.hikari112.tts/lib/sanitize.py
```

## Development

```bash
python3 tests/test_sanitize.py      # 23 sanitizer tests
shellcheck -x bin/* providers/*     # lint
```

Because the repo is symlinked into `~/.config/omarchy/plugins/`, saving any
file reloads the widget in the bar immediately.

## License

MIT — see [LICENSE](LICENSE).
