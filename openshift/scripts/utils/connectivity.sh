#!/bin/bash
#==============================================================================
# connectivity.sh
#==============================================================================
# Bounded retry handling for transient OpenShift/Kubernetes API transport
# failures. Callers must only retry read-only or idempotent commands.
#
# The command itself is deliberately never logged: arguments may contain an
# OpenShift token or secret material. Callers provide a safe human-readable
# label instead.
#==============================================================================

api_transient_error_reason() {
  local message="$1"
  local lowered
  lowered=$(printf '%s' "$message" | LC_ALL=C tr '[:upper:]' '[:lower:]')

  case "$lowered" in
    *"i/o timeout"*|*"connection timed out"*)
      printf '%s\n' "the API connection timed out"
      ;;
    *"tls handshake timeout"*)
      printf '%s\n' "the TLS handshake timed out"
      ;;
    *"connection refused"*)
      printf '%s\n' "the API endpoint refused the connection"
      ;;
    *"unable to connect to the server"*)
      printf '%s\n' "the client could not connect to the API server"
      ;;
    *"context deadline exceeded"*)
      printf '%s\n' "the API request exceeded its deadline"
      ;;
    *"connection reset"*|*"http2: client connection lost"*|*"transport is closing"*|*"stream error"*)
      printf '%s\n' "the API connection was interrupted"
      ;;
    *"unexpected eof"*|*" eof"*)
      printf '%s\n' "the API connection ended unexpectedly"
      ;;
    *"no route to host"*|*"network is unreachable"*|*"temporary failure in name resolution"*)
      printf '%s\n' "the API endpoint was unreachable"
      ;;
    *"too many requests"*|*"service unavailable"*|*"server is currently unable to handle"*|*"gateway timeout"*)
      printf '%s\n' "the API server reported a temporary availability problem"
      ;;
    *)
      return 1
      ;;
  esac
}

_api_retry_log_warn() {
  if [[ "$(type -t log_warn)" == "function" ]]; then
    log_warn "$*"
  else
    printf 'WARNING: %s\n' "$*" >&2
  fi
}

_api_retry_log_error() {
  if [[ "$(type -t log_error)" == "function" ]]; then
    log_error "$*"
  else
    printf 'ERROR: %s\n' "$*" >&2
  fi
}

# Usage: run_with_api_retry "safe operation label" command arg ...
#
# Standard output is returned only when the command succeeds. This prevents a
# failed secret-reading command from accidentally echoing partial secret data.
run_with_api_retry() {
  if [[ $# -lt 2 ]]; then
    _api_retry_log_error "run_with_api_retry requires a label and a command"
    return 2
  fi

  local operation_label="$1"
  shift

  local max_attempts="${API_RETRY_MAX_ATTEMPTS:-5}"
  local delay_seconds="${API_RETRY_INITIAL_DELAY_SECONDS:-2}"
  local max_delay_seconds="${API_RETRY_MAX_DELAY_SECONDS:-30}"
  local attempt=1
  local return_code
  local failure_text
  local failure_reason
  local stdout_file
  local stderr_file
  local temp_root="${TMPDIR:-/tmp}"

  case "$max_attempts" in ''|*[!0-9]*) max_attempts=5 ;; esac
  case "$delay_seconds" in ''|*[!0-9]*) delay_seconds=2 ;; esac
  case "$max_delay_seconds" in ''|*[!0-9]*) max_delay_seconds=30 ;; esac
  [[ "$max_attempts" -lt 1 ]] && max_attempts=1

  stdout_file=$(mktemp "$temp_root/moodle-api-retry.stdout.XXXXXX") || {
    _api_retry_log_error "Could not create a temporary file for $operation_label"
    return 1
  }
  stderr_file=$(mktemp "$temp_root/moodle-api-retry.stderr.XXXXXX") || {
    rm -f "$stdout_file"
    _api_retry_log_error "Could not create a temporary file for $operation_label"
    return 1
  }
  if ! chmod 600 "$stdout_file" "$stderr_file"; then
    rm -f "$stdout_file" "$stderr_file"
    _api_retry_log_error "Could not protect temporary files for $operation_label"
    return 1
  fi

  while [[ "$attempt" -le "$max_attempts" ]]; do
    : >"$stdout_file"
    : >"$stderr_file"

    if "$@" >"$stdout_file" 2>"$stderr_file"; then
      cat "$stdout_file"
      [[ -s "$stderr_file" ]] && cat "$stderr_file" >&2
      rm -f "$stdout_file" "$stderr_file"
      return 0
    else
      return_code=$?
    fi

    failure_text=$(cat "$stderr_file" "$stdout_file")
    if failure_reason=$(api_transient_error_reason "$failure_text"); then
      if [[ "$attempt" -lt "$max_attempts" ]]; then
        _api_retry_log_warn "$operation_label failed because $failure_reason (attempt $attempt/$max_attempts); retrying in ${delay_seconds}s"
        [[ "$delay_seconds" -gt 0 ]] && sleep "$delay_seconds"
        delay_seconds=$((delay_seconds * 2))
        [[ "$delay_seconds" -gt "$max_delay_seconds" ]] && delay_seconds="$max_delay_seconds"
        attempt=$((attempt + 1))
        continue
      fi

      _api_retry_log_error "$operation_label failed after $max_attempts attempts because $failure_reason"
    else
      _api_retry_log_error "$operation_label failed with a non-retryable error (exit $return_code)"
    fi

    [[ -s "$stderr_file" ]] && cat "$stderr_file" >&2
    rm -f "$stdout_file" "$stderr_file"
    return "$return_code"
  done
}
