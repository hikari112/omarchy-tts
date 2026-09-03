# shellcheck shell=bash
# Configuration helpers shared by the CLI tools.  All writers go through an
# atomic replace so the QML panel can never observe half-written JSON.

tts_with_config_lock() { # function [args...]
  local lock_fd rc
  mkdir -p "$(dirname "$CONFIG")"
  exec {lock_fd}>"${CONFIG}.lock" || return 1
  flock "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  "$@"; rc=$?
  flock -u "$lock_fd"
  exec {lock_fd}>&-
  return "$rc"
}

tts_config_init() {
  tts_with_config_lock tts_config_init_unlocked
}

tts_config_init_unlocked() {
  if [[ -e "$CONFIG" ]] && ! jq -e 'type == "object"' "$CONFIG" >/dev/null 2>&1; then
    local invalid
    invalid="${CONFIG}.invalid.$(date +%Y%m%dT%H%M%S).$$"
    mv "$CONFIG" "$invalid" || return 1
    chmod 600 "$invalid" || return 1
    printf 'speak: preserved invalid configuration as %s\n' "$invalid" >&2
  fi
  if [[ ! -s "$CONFIG" ]]; then
    local tmp
    tmp="$(mktemp "${CONFIG}.XXXXXX")" || return 1
    cat >"$tmp" <<'JSON'
{
  "schemaVersion": 2,
  "provider": "piper",
  "rate": 1.0,
  "maxChars": 0,
  "piper": { "voice": "en_US-amy-medium" },
  "openai": { "voice": "alloy", "model": "gpt-4o-mini-tts" },
  "elevenlabs": { "model": "eleven_turbo_v2_5" },
  "kokoro": { "voice": "af_heart" },
  "ocr": { "engine": "tesseract", "langs": "eng", "minConfidence": 60 },
  "sanitizer": {
    "urls": "domain",
    "inlineCode": true,
    "announceCodeBlocks": true,
    "stripMarkdown": true,
    "expandUnits": true
  },
  "ui": {
    "lastTab": 0,
    "sampleText": "Highlight any text and press the key. This is how it sounds right now."
  }
}
JSON
    chmod 600 "$tmp"
    mv "$tmp" "$CONFIG"
  fi

  # Additive migration. User values always win.
  local tmp
  tmp="$(mktemp "${CONFIG}.XXXXXX")" || return 1
  if jq '
    .schemaVersion = 2
    | .provider //= "piper"
    | .rate //= 1.0
    | .maxChars //= 0
    | .piper //= {}
    | .piper.voice //= "en_US-amy-medium"
    | .openai //= {}
    | .openai.voice //= "alloy"
    | .openai.model //= "gpt-4o-mini-tts"
    | .elevenlabs //= {}
    | .elevenlabs.model //= "eleven_turbo_v2_5"
    | .kokoro //= {}
    | .kokoro.voice //= "af_heart"
    | .ocr //= {}
    | .ocr.engine //= "tesseract"
    | .ocr.langs //= "eng"
    | .ocr.tesseract //= {}
    | .ocr.tesseract.langs //= .ocr.langs
    | .ocr.easyocr //= {}
    | .ocr.easyocr.langs //= "eng"
    | .ocr.openai //= {}
    | .ocr.openai.model //= "gpt-4.1-mini"
    | .ocr.minConfidence //= 60
    | .sanitizer //= {}
    | .sanitizer.urls //= "domain"
    | .sanitizer.inlineCode //= true
    | .sanitizer.announceCodeBlocks //= true
    | .sanitizer.stripMarkdown //= true
    | .sanitizer.expandUnits //= true
    | .ui //= {}
    | .ui.lastTab //= 0
    | .ui.sampleText //= "Highlight any text and press the key. This is how it sounds right now."
    | .rate = (if (.rate|type)=="number" and .rate>=0.5 and .rate<=2 then .rate else 1.0 end)
    | .maxChars = (if (.maxChars|type)=="number" and .maxChars>=0 then (.maxChars|floor) else 0 end)
    | .ocr.minConfidence = (if (.ocr.minConfidence|type)=="number" and .ocr.minConfidence>=0 and .ocr.minConfidence<=100 then (.ocr.minConfidence|floor) else 60 end)
    | .ui.lastTab = (if (.ui.lastTab|type)=="number" and .ui.lastTab>=0 and .ui.lastTab<=4 then (.ui.lastTab|floor) else 0 end)
  ' "$CONFIG" >"$tmp" && chmod 600 "$tmp" && mv "$tmp" "$CONFIG"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

tts_config_set() { # jq path, JSON-or-string value
  tts_with_config_lock tts_config_set_unlocked "$@"
}

tts_config_set_unlocked() { # jq path, JSON-or-string value
  local path="$1" value="$2" tmp
  case "$path" in
    .provider|.rate|.maxChars|.piper.voice|.openai.voice|.elevenlabs.voiceId|.kokoro.voice|\
    .espeak.voice|.spd.voice|.ocr.engine|.ocr.langs|.ocr.tesseract.langs|.ocr.easyocr.langs|.ocr.minConfidence|\
    .sanitizer.urls|.sanitizer.inlineCode|.sanitizer.announceCodeBlocks|\
    .sanitizer.stripMarkdown|.sanitizer.expandUnits|.ui.lastTab|.ui.sampleText) ;;
    *) return 2 ;;
  esac
  case "$path" in
    .provider) [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || return 3 ;;
    .piper.voice|.openai.voice|.elevenlabs.voiceId|.kokoro.voice|.espeak.voice|.spd.voice)
      [[ "$value" =~ ^[A-Za-z0-9._+-]+$ ]] || return 3 ;;
    .rate) awk -v value="$value" 'BEGIN { exit !(value >= 0.5 && value <= 2.0) }' || return 3 ;;
    .maxChars) [[ "$value" =~ ^[0-9]+$ ]] || return 3 ;;
    .ocr.minConfidence) [[ "$value" =~ ^[0-9]+$ ]] && [[ "$value" -le 100 ]] || return 3 ;;
    .ocr.engine) [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || return 3 ;;
    .ocr.langs|.ocr.tesseract.langs|.ocr.easyocr.langs) [[ "$value" =~ ^[A-Za-z0-9_+.-]+$ ]] || return 3 ;;
    .sanitizer.urls) [[ "$value" == domain || "$value" == link ]] || return 3 ;;
    .sanitizer.inlineCode|.sanitizer.announceCodeBlocks|.sanitizer.stripMarkdown|.sanitizer.expandUnits)
      [[ "$value" == true || "$value" == false ]] || return 3 ;;
    .ui.lastTab) [[ "$value" =~ ^[0-4]$ ]] || return 3 ;;
  esac
  tmp="$(mktemp "${CONFIG}.XXXXXX")" || return 1
  if [[ "$value" =~ ^-?[0-9]+([.][0-9]+)?$ || "$value" == true || "$value" == false ]]; then
    jq --argjson value "$value" "$path = \$value" "$CONFIG" >"$tmp"
  else
    jq --arg value "$value" "$path = \$value" "$CONFIG" >"$tmp"
  fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp"
  mv "$tmp" "$CONFIG"
}
