# shellcheck shell=bash
# Shared mutations for the provider/OCR health cache. Readers decide whether
# an entry's fingerprint is still current; credential changes delete affected
# entries eagerly so every process observes the transition immediately.

tts_health_invalidate() { # health-file key [key...]
  local health="$1" keys tmp lock_fd
  shift
  [[ $# -gt 0 && ! -L "$health" && -s "$health" &&
     "$(stat -c%s "$health" 2>/dev/null || printf 1048577)" -le 1048576 ]] || return 0
  keys="$(printf '%s\n' "$@")"
  mkdir -p "$(dirname "$health")" || return 1
  exec {lock_fd}>>"${health}.lock" || return 1
  flock "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  if ! jq -e 'type == "object"' "$health" >/dev/null 2>&1; then
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return 0
  fi
  tmp="$(mktemp "${health}.XXXXXX")" || {
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return 1
  }
  if jq --arg keys "$keys" \
      '($keys | split("\n")) as $stale | with_entries(select(.key as $key | $stale | index($key) | not))' \
      "$health" >"$tmp" && chmod 600 "$tmp" && mv -T -- "$tmp" "$health"; then
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return 0
  fi
  rm -f "$tmp"
  flock -u "$lock_fd"
  exec {lock_fd}>&-
  return 1
}
