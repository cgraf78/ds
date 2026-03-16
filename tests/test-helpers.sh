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

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

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

_tmpdir() {
    local d
    d=$(mktemp -d)
    CLEANUP_DIRS+=("$d")
    echo "$d"
}

_cleanup() {
    for d in "${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}"; do
        rm -rf "$d"
    done
}
trap _cleanup EXIT

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
