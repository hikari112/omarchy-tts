# shellcheck shell=bash
# Shared playback helpers for TTS providers. Sourced, not executed.

audio_is_mp3() { # file
  local file="$1" first=0 second=0
  [[ -s "$file" ]] || return 1
  [[ "$(LC_ALL=C head -c 3 "$file")" == ID3 ]] && return 0
  read -r first second < <(od -An -tu1 -N2 "$file")
  [[ "$first" -eq 255 && $((second & 224)) -eq 224 ]]
}

audio_is_wav() { # file
  local file="$1"
  [[ -s "$file" ]] || return 1
  [[ "$(LC_ALL=C head -c 4 "$file")" == RIFF ]] || return 1
  [[ "$(LC_ALL=C tail -c +9 "$file" | head -c 4)" == WAVE ]]
}

# play_raw <rate> <channels> — raw s16le PCM on stdin to the default sink.
play_raw() {
  local rate="${1:-22050}" ch="${2:-1}"
  [[ "$rate" =~ ^[0-9]+$ && "$rate" -ge 8000 && "$rate" -le 384000 ]] || {
    echo "speak: invalid raw-audio sample rate" >&2; return 65;
  }
  [[ "$ch" =~ ^[0-9]+$ && "$ch" -ge 1 && "$ch" -le 8 ]] || {
    echo "speak: invalid raw-audio channel count" >&2; return 65;
  }
  # Verification drives a provider end to end; it must not be audible.
  if [[ "${TTS_SILENT:-0}" == "1" ]]; then exec cat > /dev/null; fi

  if command -v pw-cat >/dev/null 2>&1; then
    exec pw-cat --playback --format=s16 --rate="$rate" --channels="$ch" --raw -
  elif command -v aplay >/dev/null 2>&1; then
    exec aplay -q -f S16_LE -r "$rate" -c "$ch" -
  else
    echo "speak: no raw audio player (need pipewire or alsa-utils)" >&2
    return 1
  fi
}

# play_file <path> — a container file (wav/mp3/etc).
play_file() {
  local f="$1"
  [[ -f "$f" && -s "$f" ]] || {
    echo "speak: audio file is missing or empty" >&2; return 65;
  }
  if [[ "${TTS_SILENT:-0}" == "1" ]]; then return 0; fi
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
