#!/usr/bin/env bash
# Tests for bin/sys-log-pruner
# shellcheck disable=SC2016  # stub bodies are single-quoted on purpose
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$BIN/sys-log-pruner"
LOGS="$WORK/log"

# df: successive calls return successive values from $FAKE_DF_PCT ("95 80"
# = 95% before pruning, 80% after).
stub df '
state="$FAKE_DF_STATE"; n=$(( $(cat "$state" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$state"
read -ra seq <<< "$FAKE_DF_PCT"; pct="${seq[n-1]:-${seq[-1]}}"
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 1000000 1 1 ${pct}% /var/log"'
# journalctl: record the call so tests can assert on it.
stub journalctl '
echo "$*" >> "$FAKE_JOURNAL_CALLS"
echo "Vacuuming done, freed 1.2G of archived journals from /var/log/journal/abc."'

export FAKE_DF_STATE="$WORK/df-state" FAKE_JOURNAL_CALLS="$WORK/journal-calls"

reset_logs() {
    rm -rf "$LOGS" "$FAKE_DF_STATE" "$FAKE_JOURNAL_CALLS"
    mkdir -p "$LOGS/nginx" "$LOGS/journal/machine-id"
    local f
    for f in syslog syslog.1 syslog.2.gz messages-20260801 nginx/access.log nginx/access.log.1 \
             nginx/error.log.14.xz journal/machine-id/system@0001.journal~ fresh.log.1.gz; do
        echo data > "$LOGS/$f"
    done
    # Everything is old except fresh.log.1.gz and the active nginx log.
    for f in syslog syslog.1 syslog.2.gz messages-20260801 nginx/access.log.1 \
             nginx/error.log.14.xz journal/machine-id/system@0001.journal~; do
        touch -d '30 days ago' "$LOGS/$f"
    done
}

remaining() {
    (cd "$LOGS" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ')
}

prune() {
    run with_stubs "$TOOL" --log-dir "$LOGS" "$@"
}

# ------------------------------------------------------------------------------
section 'CLI'
run "$TOOL" --help
assert_rc 0 '--help exits 0'
run "$TOOL" --threshold 0
assert_rc 2 '--threshold 0 is a usage error'
run "$TOOL" --journal-size lots
assert_rc 2 'bad --journal-size is a usage error'

# ------------------------------------------------------------------------------
section 'Below threshold'
reset_logs
before="$(remaining)"
FAKE_DF_PCT='50' prune
assert_rc 0 'exit 0'
assert_eq "$before" "$(remaining)" 'nothing deleted'
assert_contains "$ERR" 'nothing to do' 'logs why it did nothing'
assert_absent "$FAKE_JOURNAL_CALLS" 'journal not vacuumed'

# ------------------------------------------------------------------------------
section 'Above threshold, recovers'
reset_logs
FAKE_DF_PCT='95 70' prune
assert_rc 0 'exit 0 once usage drops below the threshold'
assert_eq 'fresh.log.1.gz journal/machine-id/system@0001.journal~ nginx/access.log syslog ' \
    "$(remaining)" 'only old rotated logs deleted; active logs and journal kept'
assert_contains "$(cat "$FAKE_JOURNAL_CALLS")" '--vacuum-size=500M' 'journal vacuumed to the default size'
assert_contains "$ERR" 'freed 1.2G' 'journalctl result logged'
assert_contains "$ERR" 'now at 70% (was 95%)' 'before/after usage logged'

# ------------------------------------------------------------------------------
section 'Above threshold, still full'
reset_logs
FAKE_DF_PCT='97 96' prune --journal-size 1G
assert_rc 1 'exit 1 so the systemd unit fails and gets noticed'
assert_contains "$(cat "$FAKE_JOURNAL_CALLS")" '--vacuum-size=1G' '--journal-size honored'
assert_contains "$ERR" 'still at 96%' 'failure explained'

# ------------------------------------------------------------------------------
section 'Dry run, force, options'
reset_logs
before="$(remaining)"
FAKE_DF_PCT='99' prune --dry-run
assert_rc 0 'dry run exits 0'
assert_eq "$before" "$(remaining)" '--dry-run deletes nothing'
assert_not_contains "$(cat "$FAKE_JOURNAL_CALLS" 2>/dev/null)" '--vacuum' '--dry-run does not vacuum the journal'
assert_contains "$ERR" 'would delete' 'dry run lists candidates'

reset_logs
FAKE_DF_PCT='10' prune --force --no-journal
assert_rc 0 '--force prunes below the threshold'
assert_not_contains "$(remaining)" 'syslog.1' 'old rotated log deleted with --force'
assert_absent "$FAKE_JOURNAL_CALLS" '--no-journal skips journalctl'

reset_logs
FAKE_DF_PCT='10' prune --force --no-journal --max-age 60
assert_contains "$(remaining)" 'syslog.1' '--max-age keeps logs younger than N days'

finish
