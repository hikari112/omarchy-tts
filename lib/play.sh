# shellcheck shell=bash
# Shared playback helpers for TTS providers. Sourced, not executed.

# play_raw <rate> <channels> — raw s16le PCM on stdin to the default sink.
play_raw() {
  local rate="${1:-22050}" ch="${2:-1}"
  if command -v pw-cat >/dev/null 2>&1; then
    exec pw-cat --playback --format=s16 --rate="$rate" --channels="$ch" --raw -
  elif command -v aplay >/dev/null 2>&1; then
    exec aplay -q -f S16_LE -r "$rate" -c "$ch" -
  else
    echo "speak: no raw audio player (need pipewire or alsa-utils)" >&2
    exit 1
  fi
}

# play_file <path> — a container file (wav/mp3/etc).
play_file() {
  local f="$1"
  if command -v mpv >/dev/null 2>&1; then
    exec mpv --really-quiet --no-video --audio-display=no "$f"
  elif command -v ffplay >/dev/null 2>&1; then
    exec ffplay -nodisp -autoexit -loglevel quiet "$f"
  elif command -v pw-play >/dev/null 2>&1; then
    exec pw-play "$f"
  elif command -v paplay >/dev/null 2>&1; then
    exec paplay "$f"
  else
    echo "speak: no audio player found (install mpv)" >&2
    exit 1
  fi
}

# need <cmd> <install hint> — fail loudly and usefully.
need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "speak: '$1' not found — $2" >&2
  command -v notify-send >/dev/null 2>&1 &&
    notify-send -a "Speak" "Provider unavailable" "$1 not installed. $2" 2>/dev/null
  exit 127
}
