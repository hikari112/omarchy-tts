# shellcheck shell=bash
# API key resolution for cloud providers, most-secure source first.
#   1. environment variable
#   2. secret-tool / system keyring
key_value_valid() { # key_value_valid <value>
  local LC_ALL=C value="$1"
  [[ ${#value} -ge 8 && ${#value} -le 4096 ]] || return 1
  # API credentials are printable, non-whitespace ASCII tokens. Besides
  # catching pasted whitespace, this keeps legacy keyring entries from ever
  # becoming malformed HTTP headers.
  [[ "$value" != *[![:graph:]]* ]]
}

get_key() { # get_key <ENV_NAME> <keyring-name>
  local envname="$1" keyname="$2" v="" error_file="" rc=0
  v="${!envname:-}"
  key_value_valid "$v" && { printf '%s' "$v"; return 0; }
  if ! command -v secret-tool >/dev/null 2>&1; then
    echo "speak: the system keyring helper (secret-tool) is unavailable." >&2
    echo "  Install libsecret, or export:  $envname=..." >&2
    return 1
  fi
  error_file="$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/omarchy-tts-key.XXXXXX")" || {
    echo "speak: the system keyring is unavailable." >&2; return 1;
  }
  v="$(timeout --kill-after=1s 5s secret-tool lookup \
    service omarchy-tts key "$keyname" 2>"$error_file")" || rc=$?
  if [[ $rc -eq 0 ]] && key_value_valid "$v"; then
    rm -f "$error_file"; printf '%s' "$v"; return 0
  fi
  if [[ $rc -eq 0 && -n "$v" ]]; then
    v=""
    rm -f "$error_file"
    echo "speak: the stored API key has an invalid format; replace it in the TTS panel." >&2
    return 1
  fi
  v=""
  if [[ $rc -ne 1 || -s "$error_file" ]]; then
    rm -f "$error_file"
    echo "speak: the system keyring did not respond; unlock it and try again." >&2
    return 1
  fi
  rm -f "$error_file"
  echo "speak: no API key for $keyname." >&2
  echo "  Store one:  secret-tool store --label='$keyname' service omarchy-tts key $keyname" >&2
  echo "  Or export:  $envname=..." >&2
  command -v notify-send >/dev/null 2>&1 &&
    notify-send -a "Speak" "No API key" "Set $envname or store '$keyname' in your keyring." 2>/dev/null
  return 1
}
