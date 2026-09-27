# shellcheck shell=bash
# shellcheck disable=SC2034  # BIN, OUT, ERR, RC are read by the test files
# ==============================================================================
# tests/lib.sh — minimal test harness shared by tests/test_*.sh
#
# Tools read /proc, /sys and /etc through $LST_ROOT and external commands
# (df, ss, systemctl, journalctl, dig) through $PATH, so every test builds a
# fixture tree plus command stubs and gets the same result on any machine.
# ==============================================================================

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/bin"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lst-test.XXXXXX")"
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
trap 'rm -rf "$WORK"' EXIT

export NO_COLOR=1
unset JOURNAL_STREAM

PASSED=0
FAILED=0

pass() { PASSED=$(( PASSED + 1 )); printf '  ok   %s\n' "$1"; }
fail() { FAILED=$(( FAILED + 1 )); printf '  FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '       %s\n' "$2"; }

section() { printf '\n%s\n' "$1"; }

# run <cmd> [args...]: capture stdout in OUT, stderr in ERR, status in RC.
run() {
    set +e
    OUT="$("$@" 2> "$WORK/stderr")"
    RC=$?
    set -e
    ERR="$(< "$WORK/stderr")"
}

assert_eq() {  # <expected> <actual> <name>
    if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3" "expected '$1', got '$2'"; fi
}

assert_rc() {  # <expected exit code> <name>
    assert_eq "$1" "$RC" "$2"
}

assert_contains() {  # <haystack> <needle> <name>
    if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3" "missing '$2'"; fi
}

assert_not_contains() {  # <haystack> <needle> <name>
    if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3" "unexpected '$2'"; fi
}

assert_absent() {  # <path> <name>
    if [[ ! -e "$1" ]]; then pass "$2"; else fail "$2" "$1 exists"; fi
}

# json_get <json> <python expression on d>: evaluate against parsed JSON.
json_get() {
    python3 -c 'import json, sys
d = json.loads(sys.argv[1])
v = eval(sys.argv[2])
print(json.dumps(v) if isinstance(v, (dict, list, bool)) or v is None else v)' "$1" "$2"
}

assert_json() {  # <json> <name>
    if python3 -c 'import json, sys; json.loads(sys.argv[1])' "$1" 2>/dev/null; then
        pass "$2"
    else
        fail "$2" "invalid JSON: ${1:0:200}"
    fi
}

# stub <name> <script body>: create an executable stub command in $STUBS.
stub() {
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$STUBS/$1"
    chmod +x "$STUBS/$1"
}

# with_stubs <cmd> [args...]: run with stubs first in PATH.
with_stubs() {
    PATH="$STUBS:$PATH" "$@"
}

finish() {
    printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
    (( FAILED == 0 ))
}
