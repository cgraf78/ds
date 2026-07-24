#!/usr/bin/env bash
# test-helpers.sh — shared test framework for ds tests.
#
# Source this file from test scripts to get assertion helpers,
# temp directory management, and a summary reporter.
#
# Usage:
#   . "$(dirname "$0")/test-helpers.sh"
#   _assert_eq "description" "expected" "actual"
#   ...
#   _test_summary  # prints results, exits 0 or 1

PASS=0
FAIL=0
CLEANUP_DIRS=()
CLEANUP_FILES=()
CLEANUP_PIDS=()
CLEANUP_PID_IDENTITIES=()
TEST_TREE_PIDS=()
TEST_PS_DIR=""
TEST_PS_FILE=""
TEST_SUITE_TMP_BASE="${TMPDIR:-/tmp}"
TEST_SUITE_TMP_BASE="${TEST_SUITE_TMP_BASE%/}"
TEST_SUITE_TMP_ROOT=""
TEST_PID_LEDGER=""

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

_pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
_fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1" >&2
}

_assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    _pass "$desc"
  else
    _fail "$desc (expected '$expected', got '$actual')"
  fi
}

_assert_contains() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    _pass "$desc"
  else
    _fail "$desc (expected to contain '$expected', got '$actual')"
  fi
}

_assert_not_contains() {
  local desc="$1" unexpected="$2" actual="$3"
  if [[ "$actual" != *"$unexpected"* ]]; then
    _pass "$desc"
  else
    _fail "$desc (should not contain '$unexpected')"
  fi
}

_assert_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" -eq "$actual" ]]; then
    _pass "$desc"
  else
    _fail "$desc (expected exit $expected, got $actual)"
  fi
}

_assert_file_exists() {
  local desc="$1" path="$2"
  if [[ -f "$path" ]]; then
    _pass "$desc"
  else
    _fail "$desc (file not found: $path)"
  fi
}

_assert_file_missing() {
  local desc="$1" path="$2"
  if [[ ! -f "$path" ]]; then
    _pass "$desc"
  else
    _fail "$desc (file should not exist: $path)"
  fi
}

_assert_file_content() {
  local desc="$1" expected="$2" path="$3"
  if [[ -f "$path" ]]; then
    local actual
    actual=$(cat "$path")
    if [[ "$actual" == "$expected" ]]; then
      _pass "$desc"
    else
      _fail "$desc (expected content '$expected', got '$actual')"
    fi
  else
    _fail "$desc (file not found: $path)"
  fi
}

# ---------------------------------------------------------------------------
# Temp directory management
# ---------------------------------------------------------------------------

_init_test_suite_root() {
  local attempt candidate forced="${DS_TEST_SUITE_TMP_ROOT_CANDIDATE:-}"
  [[ -z "$forced" || "$forced" == "$TEST_SUITE_TMP_BASE"/ds-test-suite.* ]] ||
    forced=""
  for ((attempt = 0; attempt < 100; attempt++)); do
    if ((attempt == 0)) && [[ -n "$forced" ]]; then
      candidate="$forced"
    else
      candidate="$TEST_SUITE_TMP_BASE/ds-test-suite.$$.$RANDOM.$RANDOM"
    fi
    mkdir -m 700 "$candidate" 2>/dev/null || continue
    if chmod 700 "$candidate" && [[ -d "$candidate" && ! -L "$candidate" ]]; then
      TEST_SUITE_TMP_ROOT="$candidate"
      return 0
    fi
    rm -rf "$candidate"
  done
  return 1
}

_tmpdir() {
  local attempt candidate forced="${TEST_TMPDIR_CANDIDATE:-}"
  [[ -n "$TEST_SUITE_TMP_ROOT" && -d "$TEST_SUITE_TMP_ROOT" &&
    ! -L "$TEST_SUITE_TMP_ROOT" ]] || return 1
  [[ -z "$forced" || "$forced" == "$TEST_SUITE_TMP_ROOT"/fixture.* ]] ||
    forced=""
  for ((attempt = 0; attempt < 100; attempt++)); do
    if ((attempt == 0)) && [[ -n "$forced" ]]; then
      candidate="$forced"
    else
      candidate="$TEST_SUITE_TMP_ROOT/fixture.$$.$RANDOM.$RANDOM"
    fi
    mkdir -m 700 "$candidate" 2>/dev/null || continue
    if chmod 700 "$candidate" && [[ -d "$candidate" && ! -L "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    rm -rf "$candidate"
  done
  return 1
}

if ! _init_test_suite_root; then
  printf '%s\n' "cannot create private test-suite temporary root" >&2
  if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 1
  fi
  exit 1
fi

_init_test_pid_ledger() {
  local old_umask
  TEST_PID_LEDGER="$TEST_SUITE_TMP_ROOT/process-ledger"
  old_umask=$(umask)
  umask 077
  if ! mkdir -m 700 "$TEST_PID_LEDGER" 2>/dev/null ||
    ! chmod 700 "$TEST_PID_LEDGER" ||
    [[ ! -d "$TEST_PID_LEDGER" || -L "$TEST_PID_LEDGER" ]]; then
    umask "$old_umask"
    return 1
  fi
  umask "$old_umask"
  export DS_TEST_PID_LEDGER="$TEST_PID_LEDGER"
}

if ! _init_test_pid_ledger; then
  printf '%s\n' "cannot create private test process ledger" >&2
  if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 1
  fi
  exit 1
fi

_test_pid_identity() {
  local pid="$1" target="$2" weekday month day clock year extra
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  _test_ps_output_file || return 1
  if ! LC_ALL=C ps -o lstart= -p "$pid" >"$TEST_PS_FILE" 2>/dev/null ||
    ! {
      read -r weekday month day clock year extra &&
        [[ -n "$weekday" && -n "$month" && -n "$day" &&
          -n "$clock" && -n "$year" && -z "$extra" ]] &&
        ! IFS= read -r
    } <"$TEST_PS_FILE"; then
    return 1
  fi
  printf -v "$target" '%s %s %s %s %s' \
    "$weekday" "$month" "$day" "$clock" "$year"
}

_test_ps_output_file() {
  local attempt candidate
  if [[ -n "$TEST_PS_DIR" && -d "$TEST_PS_DIR" && ! -L "$TEST_PS_DIR" &&
    "$TEST_PS_FILE" == "$TEST_PS_DIR/processes" &&
    -f "$TEST_PS_FILE" && ! -L "$TEST_PS_FILE" ]]; then
    return 0
  fi
  TEST_PS_DIR=""
  TEST_PS_FILE=""
  for ((attempt = 0; attempt < 100; attempt++)); do
    candidate="$TEST_SUITE_TMP_ROOT/process-snapshot.$RANDOM.$RANDOM"
    mkdir -m 700 "$candidate" 2>/dev/null || continue
    if ! chmod 700 "$candidate" || [[ ! -d "$candidate" || -L "$candidate" ]]; then
      rm -rf "$candidate"
      continue
    fi
    TEST_PS_DIR="$candidate"
    TEST_PS_FILE="$TEST_PS_DIR/processes"
    if ! : >"$TEST_PS_FILE" || ! chmod 600 "$TEST_PS_FILE" ||
      [[ ! -f "$TEST_PS_FILE" || -L "$TEST_PS_FILE" ]]; then
      rm -rf "$TEST_PS_DIR"
      TEST_PS_DIR=""
      TEST_PS_FILE=""
      continue
    fi
    CLEANUP_DIRS+=("$TEST_PS_DIR")
    CLEANUP_FILES+=("$TEST_PS_FILE")
    return 0
  done
  return 1
}

_track_test_pid() {
  local pid="$1" _ttp_identity="" index
  _test_pid_identity "$pid" _ttp_identity || return 1
  for ((index = 0; index < ${#CLEANUP_PIDS[@]}; index++)); do
    if [[ "${CLEANUP_PIDS[index]}" == "$pid" ]]; then
      CLEANUP_PID_IDENTITIES[index]="$_ttp_identity"
      return 0
    fi
  done
  CLEANUP_PIDS+=("$pid")
  CLEANUP_PID_IDENTITIES+=("$_ttp_identity")
}

_ingest_test_pid_ledger() {
  local entry pid weekday month day clock year extra identity index seen current
  # Detached parents can exit before cleanup discovers their children, so
  # fixtures record PID plus start time while ownership is still known.
  [[ "$TEST_PID_LEDGER" == "$TEST_SUITE_TMP_ROOT/process-ledger" &&
    -d "$TEST_PID_LEDGER" && ! -L "$TEST_PID_LEDGER" ]] || return 1
  for entry in "$TEST_PID_LEDGER"/*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    pid=${entry##*/}
    [[ "$pid" =~ ^[0-9]+$ && -f "$entry" && ! -L "$entry" ]] || return 1
    read -r weekday month day clock year extra <"$entry" || return 1
    [[ -n "$weekday" && -n "$month" &&
      -n "$day" && -n "$clock" && -n "$year" && -z "$extra" ]] || return 1
    identity="$weekday $month $day $clock $year"
    seen=0
    for ((index = 0; index < ${#CLEANUP_PIDS[@]}; index++)); do
      if [[ "${CLEANUP_PIDS[index]}" == "$pid" ]]; then
        current=""
        if ! _test_pid_identity "$pid" current ||
          [[ "$current" != "${CLEANUP_PID_IDENTITIES[index]}" ]]; then
          CLEANUP_PID_IDENTITIES[index]="$identity"
        fi
        seen=1
      fi
    done
    if ((seen == 0)); then
      CLEANUP_PIDS+=("$pid")
      CLEANUP_PID_IDENTITIES+=("$identity")
    fi
  done
}

_snapshot_test_forest() {
  local index parent child child_index seen progress parent_in_tree parent_ordered
  local -a process_pids=() process_parents=() ordered_pids=()
  TEST_TREE_PIDS=("$@")
  _test_ps_output_file || return 1
  if ! LC_ALL=C ps -axo pid=,ppid= >"$TEST_PS_FILE"; then
    return 1
  fi
  while read -r child parent; do
    [[ "$child" =~ ^[0-9]+$ && "$parent" =~ ^[0-9]+$ ]] || continue
    process_pids+=("$child")
    process_parents+=("$parent")
  done <"$TEST_PS_FILE"
  for ((index = 0; index < ${#TEST_TREE_PIDS[@]}; index++)); do
    parent=${TEST_TREE_PIDS[index]}
    for ((child_index = 0; child_index < ${#process_pids[@]}; child_index++)); do
      if [[ "${process_parents[child_index]}" == "$parent" ]]; then
        child=${process_pids[child_index]}
        seen=0
        for parent in "${TEST_TREE_PIDS[@]}"; do
          [[ "$parent" != "$child" ]] || seen=1
        done
        ((seen)) || TEST_TREE_PIDS+=("$child")
      fi
    done
  done
  # Registration order is arbitrary; derive a parent-before-child signal order
  # from the same process snapshot used to discover descendants.
  while ((${#ordered_pids[@]} < ${#TEST_TREE_PIDS[@]})); do
    progress=0
    for child in "${TEST_TREE_PIDS[@]}"; do
      seen=0
      for parent in "${ordered_pids[@]+"${ordered_pids[@]}"}"; do
        [[ "$parent" != "$child" ]] || seen=1
      done
      ((seen == 0)) || continue
      parent=""
      for ((index = 0; index < ${#process_pids[@]}; index++)); do
        if [[ "${process_pids[index]}" == "$child" ]]; then
          parent=${process_parents[index]}
          break
        fi
      done
      parent_in_tree=0
      parent_ordered=0
      for ((index = 0; index < ${#TEST_TREE_PIDS[@]}; index++)); do
        [[ "${TEST_TREE_PIDS[index]}" != "$parent" ]] || parent_in_tree=1
      done
      for ((index = 0; index < ${#ordered_pids[@]}; index++)); do
        [[ "${ordered_pids[index]}" != "$parent" ]] || parent_ordered=1
      done
      if ((parent_in_tree == 0 || parent_ordered)); then
        ordered_pids+=("$child")
        progress=1
      fi
    done
    ((progress)) || return 1
  done
  TEST_TREE_PIDS=("${ordered_pids[@]}")
}

_track_test_tree() {
  local child
  _snapshot_test_forest "$1"
  for child in "${TEST_TREE_PIDS[@]}"; do
    _track_test_pid "$child" || true
  done
}

_test_pid_still_owned() {
  local pid="$1" expected="$2" actual=""
  _test_pid_identity "$pid" actual && [[ "$actual" == "$expected" ]]
}

_test_pid_still_live() {
  local pid="$1" expected="$2" status
  _test_pid_still_owned "$pid" "$expected" || return 1
  _test_ps_output_file || return 1
  if ! LC_ALL=C ps -o stat= -p "$pid" >"$TEST_PS_FILE" 2>/dev/null ||
    ! IFS= read -r status <"$TEST_PS_FILE"; then
    return 1
  fi
  [[ "$status" != *Z* ]]
}

_test_tracked_pid_still_live() {
  local pid="$1" index
  for ((index = 0; index < ${#CLEANUP_PIDS[@]}; index++)); do
    if [[ "${CLEANUP_PIDS[index]}" == "$pid" ]]; then
      _test_pid_still_live "$pid" "${CLEANUP_PID_IDENTITIES[index]}"
      return
    fi
  done
  return 1
}

_wait_for_test_pid_exit() {
  local pid="$1" expected="$2" attempt
  for ((attempt = 0; attempt < 500; attempt++)); do
    _test_pid_still_live "$pid" "$expected" || return 0
    sleep 0.01
  done
  ! _test_pid_still_live "$pid" "$expected"
}

_cleanup_test_pids() {
  local index attempt pid child any_live job_pid
  _ingest_test_pid_ledger || return 1
  _snapshot_test_forest "${CLEANUP_PIDS[@]+"${CLEANUP_PIDS[@]}"}"
  for child in "${TEST_TREE_PIDS[@]+"${TEST_TREE_PIDS[@]}"}"; do
    _track_test_pid "$child" || true
  done
  # Stop parents first so a loop cannot replace an enumerated child.
  for pid in "${TEST_TREE_PIDS[@]+"${TEST_TREE_PIDS[@]}"}"; do
    _test_tracked_pid_still_live "$pid" || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  for ((attempt = 0; attempt < 100; attempt++)); do
    any_live=0
    for ((index = 0; index < ${#CLEANUP_PIDS[@]}; index++)); do
      if _test_pid_still_live \
        "${CLEANUP_PIDS[index]}" "${CLEANUP_PID_IDENTITIES[index]}"; then
        any_live=1
        break
      fi
    done
    ((any_live)) || break
    sleep 0.01
  done
  for pid in "${TEST_TREE_PIDS[@]+"${TEST_TREE_PIDS[@]}"}"; do
    _test_tracked_pid_still_live "$pid" || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
  _test_ps_output_file || return 1
  jobs -pr >"$TEST_PS_FILE"
  while IFS= read -r job_pid; do
    [[ "$job_pid" =~ ^[0-9]+$ ]] || continue
    wait "$job_pid" 2>/dev/null || true
  done <"$TEST_PS_FILE"
  CLEANUP_PIDS=()
  CLEANUP_PID_IDENTITIES=()
}

_terminate_test_tree() {
  local root="$1" signal_name="${2:-TERM}" index pid identity cleanup_index
  _snapshot_test_forest "$root"
  for pid in "${TEST_TREE_PIDS[@]}"; do
    _track_test_pid "$pid" || true
  done
  for ((index = 0; index < ${#TEST_TREE_PIDS[@]}; index++)); do
    pid=${TEST_TREE_PIDS[index]}
    identity=""
    for ((cleanup_index = 0; cleanup_index < ${#CLEANUP_PIDS[@]}; cleanup_index++)); do
      if [[ "${CLEANUP_PIDS[cleanup_index]}" == "$pid" ]]; then
        identity=${CLEANUP_PID_IDENTITIES[cleanup_index]}
        break
      fi
    done
    [[ -n "$identity" ]] || continue
    _test_pid_still_live "$pid" "$identity" || continue
    kill -s "$signal_name" "$pid" 2>/dev/null || true
  done
}

_cleanup() {
  local rc=$? cleanup_rc=0
  trap - EXIT HUP INT TERM
  _cleanup_test_pids || cleanup_rc=1
  for d in "${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}"; do
    rm -rf "$d"
  done
  for d in "${CLEANUP_FILES[@]+"${CLEANUP_FILES[@]}"}"; do
    rm -f "$d"
  done
  if [[ -n "$TEST_SUITE_TMP_ROOT" &&
    "$TEST_SUITE_TMP_ROOT" == "$TEST_SUITE_TMP_BASE"/ds-test-suite.* ]]; then
    if [[ -L "$TEST_SUITE_TMP_ROOT" ]]; then
      rm -f "$TEST_SUITE_TMP_ROOT" || cleanup_rc=1
    elif [[ -d "$TEST_SUITE_TMP_ROOT" ]]; then
      rm -rf "$TEST_SUITE_TMP_ROOT" || cleanup_rc=1
    fi
  else
    cleanup_rc=1
  fi
  ((rc != 0 || cleanup_rc == 0)) || rc=1
  return "$rc"
}
trap _cleanup EXIT
trap '_cleanup; exit 129' HUP
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM

# ---------------------------------------------------------------------------
# Common test setup
# ---------------------------------------------------------------------------

# Create a mock HOME, saving the original. Sets TEST_HOME, REAL_HOME, HOME.
_mock_home() {
  # shellcheck disable=SC2034  # REAL_HOME is used by callers
  REAL_HOME="$HOME"
  TEST_HOME=$(_tmpdir)
  export HOME="$TEST_HOME"
}

# Create a temp bin directory prepended to PATH for mock commands.
# Prints the path; callers create scripts there directly.
_mock_bin() {
  local d
  d=$(_tmpdir)
  export PATH="$d:$PATH"
  echo "$d"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

_test_summary() {
  echo ""
  echo "================================"
  echo "Results: $PASS passed, $FAIL failed"
  echo "================================"
  [[ $FAIL -eq 0 ]] && exit 0 || exit 1
}
