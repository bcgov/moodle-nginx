#!/bin/bash

set -u
set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/moodle-credential-guard-tests.XXXXXX") || exit 1

cleanup() {
  case "$TEST_TMP" in
    "${TMPDIR:-/tmp}"/moodle-credential-guard-tests.*) rm -rf "$TEST_TMP" ;;
  esac
}
trap cleanup EXIT

log_error() { printf 'ERROR: %s\n' "$*" >&2; }
log_warn() { printf 'WARN: %s\n' "$*" >&2; }
log_info() { printf 'INFO: %s\n' "$*"; }
log_success() { printf 'SUCCESS: %s\n' "$*"; }
log_debug() { :; }

source "$SCRIPTS_DIR/utils/connectivity.sh"
source "$SCRIPTS_DIR/utils/database.sh"

API_RETRY_INITIAL_DELAY_SECONDS=0
API_RETRY_MAX_DELAY_SECONDS=0
API_RETRY_MAX_ATTEMPTS=1

tests_run=0
tests_failed=0

pass() {
  tests_run=$((tests_run + 1))
  printf 'ok %d - %s\n' "$tests_run" "$1"
}

fail() {
  tests_run=$((tests_run + 1))
  tests_failed=$((tests_failed + 1))
  printf 'not ok %d - %s\n' "$tests_run" "$1"
}

increment_counter() {
  local counter_file="$1"
  local count=0
  [[ -f "$counter_file" ]] && count=$(cat "$counter_file")
  count=$((count + 1))
  printf '%s\n' "$count" >"$counter_file"
  printf '%s\n' "$count"
}

flaky_read() {
  local count
  count=$(increment_counter "$1")
  if [[ "$count" -lt 3 ]]; then
    printf 'Unable to connect to the server: i/o timeout\n' >&2
    return 1
  fi
  printf 'recovered\n'
}

permanent_failure() {
  increment_counter "$1" >/dev/null
  printf 'Error from server (Forbidden): access denied\n' >&2
  return 1
}

assert_accepts() {
  local mode="$1"
  local desired="$2"
  local description="$3"
  OC_TEST_MODE="$mode"
  : >"$OC_CALL_LOG"
  if galera_guard_credentials_unchanged \
      mariadb-galera moodle-secrets test-namespace \
      "$desired" "$desired" "$desired" \
      >"$TEST_TMP/guard.stdout" 2>"$TEST_TMP/guard.stderr"; then
    pass "$description"
  else
    fail "$description"
  fi
}

assert_rejects() {
  local mode="$1"
  local desired="$2"
  local description="$3"
  OC_TEST_MODE="$mode"
  : >"$OC_CALL_LOG"
  if galera_guard_credentials_unchanged \
      mariadb-galera moodle-secrets test-namespace \
      "$desired" "$desired" "$desired" \
      >"$TEST_TMP/guard.stdout" 2>"$TEST_TMP/guard.stderr"; then
    fail "$description"
  else
    pass "$description"
  fi
}

ORIGINAL_TMPDIR="${TMPDIR:-}"
TMPDIR="$TEST_TMP"

API_RETRY_MAX_ATTEMPTS=3
flaky_counter="$TEST_TMP/flaky-counter"
if retry_output=$(run_with_api_retry "Test transient read" flaky_read "$flaky_counter" 2>"$TEST_TMP/retry.stderr") &&
   [[ "$retry_output" == "recovered" && "$(cat "$flaky_counter")" == "3" ]]; then
  pass "transient API reads retry until recovery"
else
  fail "transient API reads retry until recovery"
fi

API_RETRY_MAX_ATTEMPTS=3
permanent_counter="$TEST_TMP/permanent-counter"
if run_with_api_retry "Test permanent failure" permanent_failure "$permanent_counter" \
    >"$TEST_TMP/permanent.stdout" 2>"$TEST_TMP/permanent.stderr"; then
  fail "non-transient API failures are not retried"
elif [[ "$(cat "$permanent_counter")" == "1" ]]; then
  pass "non-transient API failures are not retried"
else
  fail "non-transient API failures are not retried"
fi

if compgen -G "$TEST_TMP/moodle-api-retry.*" >/dev/null; then
  fail "API retry helper removes credential-capable temporary files"
else
  pass "API retry helper removes credential-capable temporary files"
fi

if [[ -n "$ORIGINAL_TMPDIR" ]]; then
  TMPDIR="$ORIGINAL_TMPDIR"
else
  unset TMPDIR
fi
API_RETRY_MAX_ATTEMPTS=1

OC_TEST_MODE=""
OC_CALL_LOG="$TEST_TMP/oc-calls"

oc() {
  printf '%s\n' "$*" >>"$OC_CALL_LOG"

  if [[ "$OC_TEST_MODE" == "state-read-failure" && "$*" == get\ statefulset* ]]; then
    printf 'Unable to connect to the server: i/o timeout\n' >&2
    return 1
  fi

  if [[ "$*" == get\ statefulset* ]]; then
    [[ "$OC_TEST_MODE" == "fresh" ]] || printf 'statefulset.apps/mariadb-galera\n'
    return 0
  fi

  if [[ "$*" == get\ pvc* ]]; then
    [[ "$OC_TEST_MODE" == "fresh" ]] || printf 'persistentvolumeclaim/data-mariadb-galera-0\n'
    return 0
  fi

  if [[ "$*" == get\ secret\ mariadb-galera* ]]; then
    case "$OC_TEST_MODE" in
      missing-db-secret)
        return 0
        ;;
      missing-db-key)
        printf '%s\n' '{"data":{"mariadb-root-password":"c2FtZQ==","mariadb-password":"c2FtZQ=="}}'
        ;;
      root-drift)
        printf '%s\n' '{"data":{"mariadb-root-password":"b3RoZXI=","mariadb-password":"c2FtZQ==","mariadb-galera-mariabackup-password":"c2FtZQ=="}}'
        ;;
      galera-app-drift)
        printf '%s\n' '{"data":{"mariadb-root-password":"c2FtZQ==","mariadb-password":"b3RoZXI=","mariadb-galera-mariabackup-password":"c2FtZQ=="}}'
        ;;
      backup-drift)
        printf '%s\n' '{"data":{"mariadb-root-password":"c2FtZQ==","mariadb-password":"c2FtZQ==","mariadb-galera-mariabackup-password":"b3RoZXI="}}'
        ;;
      *)
        printf '%s\n' '{"data":{"mariadb-root-password":"c2FtZQ==","mariadb-password":"c2FtZQ==","mariadb-galera-mariabackup-password":"c2FtZQ=="}}'
        ;;
    esac
    return 0
  fi

  if [[ "$*" == get\ secret\ moodle-secrets* ]]; then
    case "$OC_TEST_MODE" in
      moodle-app-drift)
        printf '%s\n' '{"data":{"database-password":"b3RoZXI="}}'
        ;;
      missing-app-secret)
        return 0
        ;;
      missing-app-key)
        printf '%s\n' '{"data":{}}'
        ;;
      *)
        printf '%s\n' '{"data":{"database-password":"c2FtZQ=="}}'
        ;;
    esac
    return 0
  fi

  printf 'Unexpected oc call: %s\n' "$*" >&2
  return 1
}

if [[ "$(type -t galera_guard_credentials_unchanged)" == "function" ]]; then
  pass "credential guard function is available"
else
  fail "credential guard function is available"
fi

assert_accepts matching same "matching credentials allow an idempotent deployment"

if grep -Eq '^(apply|create|delete|patch|replace|scale|set) ' "$OC_CALL_LOG"; then
  fail "matching check performs no OpenShift mutation"
else
  pass "matching check performs no OpenShift mutation"
fi

assert_rejects root-drift same "changed Galera root credential is rejected"
assert_rejects galera-app-drift same "changed Galera application credential is rejected"
assert_rejects backup-drift same "changed MariaBackup credential is rejected"
assert_rejects moodle-app-drift same "changed Moodle application credential is rejected"
assert_rejects state-read-failure same "unreadable initialized state is rejected"
assert_rejects missing-db-secret same "missing initialized-cluster Secret is rejected"
assert_rejects missing-db-key same "missing credential key is rejected"
assert_rejects missing-app-secret same "missing Moodle application Secret is rejected"
assert_rejects missing-app-key same "missing Moodle credential key is rejected"
assert_accepts fresh new "verified fresh cluster may create initial credentials"

if grep -q '^get secret ' "$OC_CALL_LOG"; then
  fail "fresh-cluster path does not read stale Secrets"
else
  pass "fresh-cluster path does not read stale Secrets"
fi

DB_DEPLOY_SCRIPT="$SCRIPTS_DIR/deploy-mariadb-galera.sh"
guard_line=$(awk '/galera_guard_credentials_unchanged/ { print NR; exit }' "$DB_DEPLOY_SCRIPT")
render_line=$(awk '/oc create secret generic "\$DB_DEPLOYMENT_NAME"/ { print NR; exit }' "$DB_DEPLOY_SCRIPT")
if [[ -n "$guard_line" && -n "$render_line" && "$guard_line" -lt "$render_line" ]]; then
  pass "database deployment guards credentials before Secret rendering"
else
  fail "database deployment guards credentials before Secret rendering"
fi

if grep -q 'credentials_manifest=' "$DB_DEPLOY_SCRIPT" &&
   ! grep -q -- '--save-config -o yaml | oc apply -f -' "$DB_DEPLOY_SCRIPT"; then
  pass "database Secret rendering is fail-closed"
else
  fail "database Secret rendering is fail-closed"
fi

DEPLOY_WORKFLOW="$REPO_ROOT/.github/workflows/deploy.yml"
preflight_line=$(awk '/name: Guard database credentials before maintenance/ { print NR; exit }' "$DEPLOY_WORKFLOW")
maintenance_line=$(awk '/name: Deploy\/Enable Maintenance Messaging/ { print NR; exit }' "$DEPLOY_WORKFLOW")
if [[ -n "$preflight_line" && -n "$maintenance_line" && "$preflight_line" -lt "$maintenance_line" ]]; then
  pass "workflow guard runs before maintenance-mode mutation"
else
  fail "workflow guard runs before maintenance-mode mutation"
fi

if grep -Fq 'name: Deploy Backups via Helm' "$DEPLOY_WORKFLOW"; then
  fail "deprecated backup deployment is absent from the application workflow"
else
  pass "deprecated backup deployment is absent from the application workflow"
fi

if grep -q 'connectivity.sh' "$SCRIPTS_DIR/_utils.sh"; then
  pass "deployment utility loader includes the retry dependency"
else
  fail "deployment utility loader includes the retry dependency"
fi

if bash -c '
    DEBUG_LEVEL=INFO
    source "$1"
    [[ "$(type -t run_with_api_retry)" == "function" ]] &&
      [[ "$(type -t galera_guard_credentials_unchanged)" == "function" ]]
  ' _ "$SCRIPTS_DIR/_utils.sh" >/dev/null 2>&1; then
  pass "workflow-style Bash loading exposes the guard and retry helper"
else
  fail "workflow-style Bash loading exposes the guard and retry helper"
fi

BUILD_WORKFLOW="$REPO_ROOT/.github/workflows/build.yml"
if grep -Fq 'run: bash ./openshift/scripts/tests/test-credential-guard.sh' "$BUILD_WORKFLOW"; then
  pass "focused credential guard test is wired into CI"
else
  fail "focused credential guard test is wired into CI"
fi

# Regression coverage for the Galera false-negative seen in dev on 2026-09-03.
# The old cluster check queried every pod twice. A transport timeout in the
# first query could mark a pod unhealthy even when the second query immediately
# proved that the same pod was Synced and in the Primary component.
GALERA_HEALTH_MODE="all-healthy"
GALERA_STATUS_QUERY_LOG="$TEST_TMP/galera-status-queries"
GALERA_LEGACY_PROBE_LOG="$TEST_TMP/galera-legacy-probes"
: >"$GALERA_STATUS_QUERY_LOG"
: >"$GALERA_LEGACY_PROBE_LOG"

oc() {
  if [[ "$1" == "get" && "$2" == "pods" ]]; then
    printf '%s\n' 'mariadb-galera-0 mariadb-galera-1 mariadb-galera-2'
    return 0
  fi

  printf 'Unexpected Galera health-test oc call: %s\n' "$*" >&2
  return 1
}

get_mariadb_env_vars() {
  MARIADB_USER="root"
  MARIADB_PASSWORD="same"
  export MARIADB_USER MARIADB_PASSWORD
  return 0
}

# This represents the obsolete first snapshot. Pod 2 appears unreachable here,
# while the complete status query below succeeds for every pod.
check_galera_pod_ready() {
  printf '%s\n' "$1" >>"$GALERA_LEGACY_PROBE_LOG"
  [[ "$1" != "mariadb-galera-2" ]]
}

galera_exec_status() {
  local pod_name="$2"
  local local_state="Synced"
  printf '%s\n' "$pod_name" >>"$GALERA_STATUS_QUERY_LOG"

  if [[ "$GALERA_HEALTH_MODE" == "one-unsynced" && "$pod_name" == "mariadb-galera-2" ]]; then
    local_state="Donor/Desynced"
  fi

  printf 'wsrep_cluster_state_uuid\ttest-cluster-uuid\n'
  printf 'wsrep_cluster_size\t3\n'
  printf 'wsrep_local_state_comment\t%s\n' "$local_state"
  printf 'wsrep_cluster_status\tPrimary\n'
}

send_notification() { :; }

DB_PASSWORD="same"
if check_galera_cluster_health \
    'app.kubernetes.io/name=mariadb-galera' test-namespace 3 \
    >"$TEST_TMP/galera-healthy.stdout" 2>"$TEST_TMP/galera-healthy.stderr"; then
  galera_health_rc=0
else
  galera_health_rc=$?
fi

galera_query_count=$(wc -l <"$GALERA_STATUS_QUERY_LOG" | tr -d ' ')
galera_legacy_probe_count=$(wc -l <"$GALERA_LEGACY_PROBE_LOG" | tr -d ' ')
if [[ "$galera_health_rc" -eq 0 && "$galera_query_count" -eq 3 && "$galera_legacy_probe_count" -eq 0 ]]; then
  pass "Galera cluster health uses one coherent status snapshot per pod"
else
  fail "Galera cluster health uses one coherent status snapshot per pod"
fi

GALERA_HEALTH_MODE="one-unsynced"
: >"$GALERA_STATUS_QUERY_LOG"
: >"$GALERA_LEGACY_PROBE_LOG"
if check_galera_cluster_health \
    'app.kubernetes.io/name=mariadb-galera' test-namespace 3 \
    >"$TEST_TMP/galera-unsynced.stdout" 2>"$TEST_TMP/galera-unsynced.stderr"; then
  fail "Galera cluster health rejects a genuinely unsynced pod"
else
  pass "Galera cluster health rejects a genuinely unsynced pod"
fi

printf '1..%d\n' "$tests_run"
exit "$tests_failed"
