# shellcheck shell=bash
# API key resolution for cloud providers, most-secure source first.
#   1. environment variable
#   2. secret-tool / system keyring   (recommended)
#   3. apiKeys.<name> in config.json  (plaintext - last resort)
get_key() { # get_key <ENV_NAME> <keyring-name>
  local envname="$1" keyname="$2" v=""
  v="${!envname:-}"
  [[ -n "$v" && "$v" != *$'\n'* && "$v" != *$'\r'* ]] && { printf '%s' "$v"; return 0; }
  if command -v secret-tool >/dev/null 2>&1; then
    v="$(secret-tool lookup service omarchy-tts key "$keyname" 2>/dev/null)"
    [[ -n "$v" && "$v" != *$'\n'* && "$v" != *$'\r'* ]] && { printf '%s' "$v"; return 0; }
  fi
  v="$(jq -r --arg k "$keyname" '.apiKeys[$k] // empty' "$TTS_CONFIG" 2>/dev/null)"
  [[ -n "$v" && "$v" != "null" && "$v" != *$'\n'* && "$v" != *$'\r'* ]] &&
    { printf '%s' "$v"; return 0; }
  echo "speak: no API key for $keyname." >&2
  echo "  Store one:  secret-tool store --label='$keyname' service omarchy-tts key $keyname" >&2
  echo "  Or export:  $envname=..." >&2
  command -v notify-send >/dev/null 2>&1 &&
    notify-send -a "Speak" "No API key" "Set $envname or store '$keyname' in your keyring." 2>/dev/null
  return 1
}
