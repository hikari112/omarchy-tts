#!/usr/bin/env bash
# Shared, privacy-preserving telemetry for paid cloud providers.
# Never pass selected text or credentials here; only counts and HTTP metadata.
umask 077

cloud_header() { # cloud_header <headers-file> <name>
  awk -v wanted="${2,,}" '
    BEGIN { IGNORECASE=1 }
    { sub(/\r$/, "") }
    index($0, ":") { name=tolower(substr($0,1,index($0,":")-1)); if (name==wanted) { value=substr($0,index($0,":")+1); sub(/^[[:space:]]+/,"",value); found=value } }
    END { printf "%s", found }
  ' "$1" 2>/dev/null
}

cloud_ensure_metrics() { # caller holds the metrics lock
  if jq -e 'type == "object"' "$TTS_METRICS_FILE" >/dev/null 2>&1; then return 0; fi
  local repair
  repair="$(mktemp "${TTS_METRICS_FILE}.repair.XXXXXX")" || return 1
  if ! printf '{}\n' > "$repair" || ! chmod 600 "$repair" ||
      ! mv "$repair" "$TTS_METRICS_FILE"; then
    rm -f "$repair"
    return 1
  fi
}

cloud_error_code() { # cloud_error_code <http-status> <response-file>
  local code
  code="$(jq -r '
    .error.status // .error.code // .error.type
    // .responses[0].error.status // .responses[0].error.code
    // .detail.status // .detail.code // empty
  ' "$2" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  # Persist only our fixed vocabulary. Remote strings are response content and
  # do not belong in a long-lived cache even when a vendor calls them a code.
  case "$code" in
    *concurrent*) printf concurrency_limit; return ;;
    *rate_limit*) printf rate_limit; return ;;
    *quota*|*credit*|*payment*|*resource_exhausted*) printf quota; return ;;
    *auth*|*api_key*|*permission*) printf auth; return ;;
    *unavailable*|*internal*|*server*) printf service; return ;;
  esac
  case "$1" in 401) printf auth ;; 402) printf quota ;; 403) printf forbidden ;;
    429) printf rate_limit ;; 5??) printf service ;; *) printf http_error ;; esac
}

cloud_record() { # provider model chars http-status headers response [units] [forced-error]
  [[ -n "${TTS_METRICS_FILE:-}" ]] || return 0
  local provider="$1" model="$2" chars="$3" status="$4" headers="$5" body="$6" units="${7:-0}" forced_error="${8:-}"
  local request_id retry_after error_code="" outcome=ok now tmp lock_fd
  request_id="$(cloud_header "$headers" x-request-id)"
  [[ -n "$request_id" ]] || request_id="$(cloud_header "$headers" request-id)"
  [[ -n "$request_id" ]] || request_id="$(cloud_header "$headers" x-trace-id)"
  retry_after="$(cloud_header "$headers" retry-after)"
  if [[ -n "$forced_error" ]]; then
    outcome=error; error_code="$forced_error"
  elif [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
    outcome=error; error_code="$(cloud_error_code "$status" "$body")"
  fi
  now="$(date -Is)"
  mkdir -p "$(dirname "$TTS_METRICS_FILE")" || return 0
  exec {lock_fd}>"${TTS_METRICS_FILE}.lock" || return 0
  flock "$lock_fd" || { exec {lock_fd}>&-; return 0; }
  cloud_ensure_metrics || { flock -u "$lock_fd"; exec {lock_fd}>&-; return 0; }
  tmp="$(mktemp "${TTS_METRICS_FILE}.XXXXXX")" || { flock -u "$lock_fd"; exec {lock_fd}>&-; return 0; }
  if jq --arg provider "$provider" --arg model "$model" --arg now "$now" \
    --arg status "$status" --arg outcome "$outcome" --arg error "$error_code" \
    --arg requestId "$request_id" --arg retryAfter "$retry_after" \
    --arg limitRequests "$(cloud_header "$headers" x-ratelimit-limit-requests)" \
    --arg remainingRequests "$(cloud_header "$headers" x-ratelimit-remaining-requests)" \
    --arg resetRequests "$(cloud_header "$headers" x-ratelimit-reset-requests)" \
    --arg limitTokens "$(cloud_header "$headers" x-ratelimit-limit-tokens)" \
    --arg remainingTokens "$(cloud_header "$headers" x-ratelimit-remaining-tokens)" \
    --arg resetTokens "$(cloud_header "$headers" x-ratelimit-reset-tokens)" \
    --argjson chars "${chars:-0}" --argjson units "${units:-0}" '
      .provider=$provider | .model=$model | .updatedAt=$now |
      .lastRequest={at:$now,httpStatus:$status,outcome:$outcome,
        errorCode:(if $error=="" then null else $error end),
        requestId:(if $requestId=="" then null else $requestId end),
        retryAfter:(if $retryAfter=="" then null else $retryAfter end)} |
      .localObserved.requests=((.localObserved.requests // 0)+1) |
      .localObserved.characters=((.localObserved.characters // 0)+$chars) |
      .localObserved.billedUnits=((.localObserved.billedUnits // 0)+$units) |
      .rateLimits={requests:{limit:$limitRequests,remaining:$remainingRequests,reset:$resetRequests},
        tokens:{limit:$limitTokens,remaining:$remainingTokens,reset:$resetTokens}} |
      .rateLimits |= with_entries(.value |= with_entries(select(.value != ""))) |
      .rateLimits |= with_entries(select(.value | length > 0))
    ' "$TTS_METRICS_FILE" > "$tmp" 2>/dev/null; then
    if ! chmod 600 "$tmp" || ! mv "$tmp" "$TTS_METRICS_FILE"; then rm -f "$tmp"; fi
  else
    rm -f "$tmp"
  fi
  flock -u "$lock_fd"; exec {lock_fd}>&-
}

cloud_store_account() { # normalized-account-json-file
  [[ -n "${TTS_METRICS_FILE:-}" ]] || return 0
  local account="$1" tmp lock_fd
  mkdir -p "$(dirname "$TTS_METRICS_FILE")" || return 1
  exec {lock_fd}>"${TTS_METRICS_FILE}.lock" || return 1
  flock "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  cloud_ensure_metrics || { flock -u "$lock_fd"; exec {lock_fd}>&-; return 1; }
  tmp="$(mktemp "${TTS_METRICS_FILE}.XXXXXX")" || { flock -u "$lock_fd"; exec {lock_fd}>&-; return 1; }
  if jq --slurpfile account "$account" '.account=$account[0] | .updatedAt=(now|todateiso8601)' \
      "$TTS_METRICS_FILE" > "$tmp" 2>/dev/null; then
    if ! chmod 600 "$tmp" || ! mv "$tmp" "$TTS_METRICS_FILE"; then
      rm -f "$tmp"; flock -u "$lock_fd"; exec {lock_fd}>&-; return 1
    fi
  else
    rm -f "$tmp"; flock -u "$lock_fd"; exec {lock_fd}>&-; return 1
  fi
  flock -u "$lock_fd"; exec {lock_fd}>&-
}

cloud_transport_fail() { # provider curl-exit
  printf '%s: network request failed (curl exit %s)\n' "$1" "$2" >&2
  return 74
}

cloud_fail() { # provider http-status response headers
  local provider="$1" status="$2" body="$3" headers="$4" code retry
  code="$(cloud_error_code "$status" "$body")"; retry="$(cloud_header "$headers" retry-after)"
  case "$code:$status" in
    auth:*|forbidden:*|*:401|*:403) printf '%s: API key was rejected (%s)\n' "$provider" "$code" >&2; return 77 ;;
    quota:*|*:402) printf '%s: quota, credits, or billing limit exhausted\n' "$provider" >&2; return 69 ;;
    rate_limit:*|concurrency_limit:*|*:429) printf '%s: rate or concurrency limit reached%s\n' "$provider" "${retry:+; retry after $retry}" >&2; return 75 ;;
    service:*|*:408|*:425|*:5??) printf '%s: service temporarily unavailable (HTTP %s)\n' "$provider" "$status" >&2; return 74 ;;
    *) printf '%s: request failed (HTTP %s, %s)\n' "$provider" "${status:-unknown}" "$code" >&2; return 1 ;;
  esac
}
