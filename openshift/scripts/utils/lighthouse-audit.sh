#!/bin/bash
# =============================================================================
# Lighthouse Audit — CI Wrapper
# =============================================================================
# Orchestrates the Lighthouse performance audit step in CI:
#   1. Verifies the environment (Node, npm, config, modules)
#   2. Sources lighthouse.sh and calls run_lighthouse_audit()
#   3. Maps exit codes to GITHUB_OUTPUT variables (LHSTATUS, LHERROR)
#
# Usage:
#   source openshift/scripts/utils/lighthouse-audit.sh
#   execute_lighthouse_audit <target_url> <config_dir> <output_dir> \
#                            [username] [password] [debug_level]
#
# Outputs (via GITHUB_OUTPUT if available):
#   LHSTATUS: "success" | "failure (<error>)"
#   LHERROR:  error details on failure
#
# See: openshift/scripts/utils/lighthouse.sh (core functions)
# =============================================================================

_AUDIT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

execute_lighthouse_audit() {
  local target_url="${1:?Usage: execute_lighthouse_audit <url> <config_dir> <output_dir> [user] [pass] [debug_level]}"
  local config_dir="${2:-config/lighthouse}"
  local output_dir="${3:-tmp/artifacts}"
  local auth_username="${4:-}"
  local auth_password="${5:-}"
  local debug_level="${6:-INFO}"

  # ── Optional TRACE-level command tracing ──
  if [ "$debug_level" = "TRACE" ]; then
    set -x
    echo "🔬 TRACE mode enabled - full command tracing active"
  fi

  echo "================================================"
  echo "🚦 LIGHTHOUSE AUDIT EXECUTION"
  echo "================================================"

  # ── Verify environment ──
  echo "Node version: $(node --version)"
  echo "NPM version: $(npm --version)"
  echo "Current directory: $(pwd)"
  echo "Config directory exists: $(test -d "$config_dir" && echo YES || echo NO)"
  echo "node_modules exists: $(test -d "$config_dir/node_modules" && echo YES || echo NO)"
  echo "lighthouse-auth.js exists: $(test -f "$config_dir/lighthouse-auth.js" && echo YES || echo NO)"

  # ── Source the core lighthouse utility ──
  echo "Sourcing lighthouse.sh..."
  if ! source "$_AUDIT_SCRIPT_DIR/lighthouse.sh"; then
    echo "❌ Failed to source lighthouse.sh"
    return 1
  fi
  echo "✅ lighthouse.sh sourced successfully"

  echo "Target URL: $target_url"
  echo ""
  echo "🚀 Running Lighthouse audit for: $target_url"
  echo ""

  # ── Execute audit ──
  echo "Calling run_lighthouse_audit function..."
  local lighthouse_result lighthouse_exit
  lighthouse_result=$(run_lighthouse_audit "$target_url" "$config_dir" "$output_dir" "$auth_username" "$auth_password")
  lighthouse_exit=$?

  echo ""
  echo "Function returned with exit code: $lighthouse_exit"
  echo "Function output: $lighthouse_result"
  echo ""

  # ── Set GitHub outputs ──
  if [ $lighthouse_exit -eq 0 ]; then
    _audit_output "LHSTATUS" "$lighthouse_result"
    echo "✅ Lighthouse audit completed: $lighthouse_result"
  else
    _audit_output "LHSTATUS" "failure ($lighthouse_result)"
    echo "❌ Lighthouse audit failed: $lighthouse_result"

    # Save error details (multiline)
    if [ -n "$GITHUB_OUTPUT" ]; then
      {
        echo "LHERROR<<EOF"
        echo "$lighthouse_result"
        echo "EOF"
      } >> "$GITHUB_OUTPUT"
    fi
  fi

  return $lighthouse_exit
}

# ── Internal helper ──
_audit_output() {
  local key="$1" value="$2"
  if [ -n "$GITHUB_OUTPUT" ]; then
    echo "$key=$value" >> "$GITHUB_OUTPUT"
  fi
}
