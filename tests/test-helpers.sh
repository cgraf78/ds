#!/usr/bin/env bash
# Older ShellCheck releases misclassify test helpers invoked by name.
# shellcheck disable=SC2317
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

# Hook callers can export repository selectors and command-scope config that
# override git -C and a fixture's local settings. Keep both Git fixtures on
# their own repositories with system and global configuration disabled.
while IFS= read -r _ds_test_env_name; do
  case "$_ds_test_env_name" in GIT_*) unset "$_ds_test_env_name" ;; esac
done < <(compgen -e)
unset _ds_test_env_name
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

PASS=0
FAIL=0
CLEANUP_DIRS=()
CLEANUP_FILES=()
CLEANUP_PIDS=()
CLEANUP_PID_IDENTITIES=()
TEST_TREE_PIDS=()
TEST_TREE_IDENTITIES=()
TEST_PS_DIR=""
TEST_PS_FILE=""
TEST_SUITE_TMP_BASE="${TMPDIR:-/tmp}"
# Fixture programs are prepended to PATH. A colon would split their directory
# into unrelated search entries and could make a test execute the host tool.
if [[ "$TEST_SUITE_TMP_BASE" == *:* ]]; then
  TEST_SUITE_TMP_BASE=/tmp
  # Termux's system temporary directory lives under its prefix.
  if [[ ! -w /tmp && ${PREFIX:-} == /* && ${PREFIX:-} != *:* && -w "$PREFIX/tmp" ]]; then
    TEST_SUITE_TMP_BASE="$PREFIX/tmp"
  fi
fi
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

_test_recorded_identity() {
  local target=$1 destination=${2:-} index
  for ((index = 0; index < ${#CLEANUP_PIDS[@]}; index++)); do
    if [[ "${CLEANUP_PIDS[index]}" == "$target" ]]; then
      if [[ -n "$destination" ]]; then
        printf -v "$destination" '%s' "${CLEANUP_PID_IDENTITIES[index]}"
      fi
      return 0
    fi
  done
  return 1
}

_snapshot_test_forest() {
  local index pid parent child weekday month day clock year extra progress
  local -a process_pids=() tree_pids=() ordered_pids=() ordered_identities=()
  local -A parents=() identities=() recorded=() selected=() ordered=()
  TEST_TREE_PIDS=()
  TEST_TREE_IDENTITIES=()
  (($# > 0)) || return 0
  # If the snapshot fails, callers may still act on their exact tracked roots.
  TEST_TREE_PIDS=("$@")
  if ! _test_ps_output_file || ! LC_ALL=C ps -axo pid=,ppid=,lstart= >"$TEST_PS_FILE"; then
    printf 'test cleanup: could not read a complete process snapshot\n' >&2
    return 1
  fi
  while read -r child parent weekday month day clock year extra; do
    [[ "$child" =~ ^[0-9]+$ && "$parent" =~ ^[0-9]+$ && -n "$year" &&
      -z "$extra" ]] || continue
    process_pids+=("$child")
    parents[$child]=$parent
    identities[$child]="$weekday $month $day $clock $year"
  done <"$TEST_PS_FILE"
  for ((index = 0; index < ${#CLEANUP_PIDS[@]}; index++)); do
    recorded[${CLEANUP_PIDS[index]}]=${CLEANUP_PID_IDENTITIES[index]}
  done
  # Anchor an owned tree to start times from the same snapshot as its edges.
  # A reused PID cannot authorize traversing the process that replaced it.
  for pid in "$@"; do
    if [[ -n "${recorded[$pid]-}" && "${recorded[$pid]}" == "${identities[$pid]-}" ]]; then
      tree_pids+=("$pid")
      selected[$pid]=1
    fi
  done
  for ((index = 0; index < ${#tree_pids[@]}; index++)); do
    parent=${tree_pids[index]}
    for child in "${process_pids[@]}"; do
      [[ "${parents[$child]}" == "$parent" && -z "${selected[$child]-}" ]] || continue
      [[ "${recorded[$child]-${identities[$child]}}" == "${identities[$child]}" ]] || continue
      tree_pids+=("$child")
      selected[$child]=1
    done
  done
  # Registration order is arbitrary; derive a parent-before-child signal order
  # from the same process snapshot used to discover descendants.
  while ((${#ordered_pids[@]} < ${#tree_pids[@]})); do
    progress=0
    for child in "${tree_pids[@]}"; do
      [[ -z "${ordered[$child]-}" ]] || continue
      parent=${parents[$child]}
      if [[ -z "${selected[$parent]-}" || -n "${ordered[$parent]-}" ]]; then
        ordered_pids+=("$child")
        ordered_identities+=("${identities[$child]}")
        ordered[$child]=1
        progress=1
      fi
    done
    if ((! progress)); then
      printf 'test cleanup: could not order the process snapshot\n' >&2
      return 1
    fi
  done
  TEST_TREE_PIDS=("${ordered_pids[@]+"${ordered_pids[@]}"}")
  TEST_TREE_IDENTITIES=("${ordered_identities[@]+"${ordered_identities[@]}"}")
}

_record_test_tree() {
  local index child
  for ((index = 0; index < ${#TEST_TREE_PIDS[@]}; index++)); do
    child=${TEST_TREE_PIDS[index]}
    _test_recorded_identity "$child" && continue
    CLEANUP_PIDS+=("$child")
    CLEANUP_PID_IDENTITIES+=("${TEST_TREE_IDENTITIES[index]}")
  done
}

_track_test_tree() {
  _test_recorded_identity "$1" || _track_test_pid "$1" || return
  _snapshot_test_forest "$1" || return
  _record_test_tree
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
  local pid="$1" identity
  _test_recorded_identity "$pid" identity || return
  _test_pid_still_live "$pid" "$identity"
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
  local index attempt pid any_live job_pid snapshot_status=0
  _ingest_test_pid_ledger || return 1
  if _snapshot_test_forest "${CLEANUP_PIDS[@]+"${CLEANUP_PIDS[@]}"}"; then
    _record_test_tree
  else
    # Keep recorded identities when no trustworthy tree was available.
    snapshot_status=$?
  fi
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
  return "$snapshot_status"
}

_terminate_test_tree() {
  local root="$1" signal_name="${2:-TERM}" pid snapshot_status=0
  _test_recorded_identity "$root" || _track_test_pid "$root" || return
  if _snapshot_test_forest "$root"; then
    _record_test_tree
  else
    snapshot_status=$?
  fi
  for pid in "${TEST_TREE_PIDS[@]+"${TEST_TREE_PIDS[@]}"}"; do
    _test_tracked_pid_still_live "$pid" || continue
    kill -s "$signal_name" "$pid" 2>/dev/null || true
  done
  return "$snapshot_status"
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
trap '_cleanup || exit "$?"' EXIT
trap '_cleanup || :; exit 129' HUP
trap '_cleanup || :; exit 130' INT
trap '_cleanup || :; exit 143' TERM

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
