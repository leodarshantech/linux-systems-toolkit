#!/usr/bin/env bash
# ==============================================================================
# Automated Test Suite for sys-health-audit
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${SCRIPT_DIR}/../bin/sys-health-audit"

PASSED=0
FAILED=0

assert_equal() {
    local expected="$1"
    local actual="$2"
    local test_name="$3"

    if [[ "$expected" == "$actual" ]]; then
        echo "  [PASS] ${test_name}"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] ${test_name} (Expected: '${expected}', Got: '${actual}')"
        FAILED=$((FAILED + 1))
    fi
}

echo "Running Test Suite for sys-health-audit..."

# Test 1: Binary executable
echo "[1] Checking executable..."
if [[ -x "$BIN" ]]; then
    assert_equal 0 0 "Binary is executable"
else
    assert_equal 0 1 "Binary is not executable"
fi

# Test 2: --help flag
echo "[2] Testing --help flag..."
HELP_OUT="$("$BIN" --help)"
if echo "$HELP_OUT" | grep -q "USAGE:"; then
    assert_equal 0 0 "--help displays usage manual"
else
    assert_equal 0 1 "--help failed to display usage"
fi

# Test 3: --version flag
echo "[3] Testing --version flag..."
VERSION_OUT="$("$BIN" --version)"
if echo "$VERSION_OUT" | grep -q "v1.0.0"; then
    assert_equal 0 0 "--version displays correct version string"
else
    assert_equal 0 1 "--version output unexpected"
fi

# Test 4: --json output validity
echo "[4] Testing JSON generation..."
JSON_RAW="$("$BIN" --json || true)"
if python3 -m json.tool <<< "$JSON_RAW" >/dev/null 2>&1; then
    assert_equal 0 0 "--json generates valid, parseable JSON"
else
    assert_equal 0 1 "--json produced malformed JSON"
fi

# Test 5: --quiet flag
echo "[5] Testing --quiet mode..."
QUIET_OUT="$("$BIN" --quiet || true)"
assert_equal "" "$QUIET_OUT" "--quiet produces zero stdout"

# Test 6: Threshold escalation (setting CPU or Disk threshold to 1% should force WARN/CRIT)
echo "[6] Testing threshold alert escalation..."
set +e
"$BIN" --quiet --cpu 1 --disk 1 --mem 1
TRIGGER_STATUS=$?
set -e
if [[ "$TRIGGER_STATUS" -eq 1 ]] || [[ "$TRIGGER_STATUS" -eq 2 ]]; then
    assert_equal 0 0 "Low threshold successfully triggers WARN (1) or CRIT (2)"
else
    assert_equal 0 1 "Threshold did not escalate status (Exit: $TRIGGER_STATUS)"
fi

echo "=================================================="
echo "Tests Passed: ${PASSED} | Tests Failed: ${FAILED}"
echo "=================================================="

if [[ "$FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
