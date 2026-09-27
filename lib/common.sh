# shellcheck shell=bash
# shellcheck disable=SC2034  # variables defined here are consumed by the tools
# ==============================================================================
# lib/common.sh — shared helpers for linux-systems-toolkit
#
# Sourced by every tool in bin/; not meant to be executed directly.
# Author: Leo Darshan (@leodarshantech)
# License: MIT
# ==============================================================================

LST_VERSION="2.0.0"
LST_PROG="${0##*/}"

# Prefix for every /proc, /sys, /etc and /run read. Empty in production; the
# test suite points it at a fixture tree to get deterministic results.
LST_ROOT="${LST_ROOT:-}"

# Exit codes for monitoring checks (Nagios / Zabbix plugin convention).
LST_EXIT_OK=0
LST_EXIT_WARN=1
LST_EXIT_CRIT=2
LST_EXIT_UNKNOWN=3

# Exit code for bad command-line usage. Checks keep 3 (UNKNOWN) so a typo is
# never mistaken for a CRITICAL; action tools override it with 2.
LST_USAGE_EXIT=$LST_EXIT_UNKNOWN

# ------------------------------------------------------------------------------
# Terminal output
# ------------------------------------------------------------------------------

# lst_colors <0|1>: define the C_* escape variables. Color is emitted only when
# enabled, stdout is a terminal and NO_COLOR (https://no-color.org) is unset.
lst_colors() {
    if [[ "${1:-1}" -eq 1 && -t 1 && -z "${NO_COLOR:-}" ]]; then
        C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m'
        C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_CYAN=$'\e[36m'
    else
        C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_CYAN=''
    fi
}
lst_colors 1

# lst_badge <status>: fixed-width (8 column) colored status badge.
lst_badge() {
    case "$1" in
        OK)   printf '%s[  OK  ]%s' "$C_GREEN" "$C_RESET" ;;
        PASS) printf '%s[ PASS ]%s' "$C_GREEN" "$C_RESET" ;;
        INFO) printf '%s[ INFO ]%s' "$C_CYAN" "$C_RESET" ;;
        SKIP) printf '%s[ SKIP ]%s' "$C_DIM" "$C_RESET" ;;
        WARN) printf '%s[ WARN ]%s' "$C_YELLOW" "$C_RESET" ;;
        FAIL) printf '%s%s[ FAIL ]%s' "$C_RED" "$C_BOLD" "$C_RESET" ;;
        CRIT) printf '%s%s[ CRIT ]%s' "$C_RED" "$C_BOLD" "$C_RESET" ;;
        *)    printf '[ ???? ]' ;;
    esac
}

# lst_row <status> <label> <detail>: one aligned report line.
lst_row() {
    printf '%s %-18s %s\n' "$(lst_badge "$1")" "$2" "$3"
}

# lst_tree <line>...: print lines as branches under the preceding row.
lst_tree() {
    local i branch
    for (( i = 1; i <= $#; i++ )); do
        if (( i == $# )); then branch='└─'; else branch='├─'; fi
        printf '         %s%s%s %s\n' "$C_DIM" "$branch" "$C_RESET" "${!i}"
    done
}

# lst_rule [char]: 78-column horizontal rule.
lst_rule() {
    local line
    printf -v line '%78s' ''
    printf '%s%s%s\n' "$C_BOLD" "${line// /${1:-=}}" "$C_RESET"
}

# lst_header <title>: boxed, centered report title.
lst_header() {
    local pad=$(( (78 - ${#1}) / 2 ))
    lst_rule '='
    printf '%s%*s%s%s\n' "$C_BOLD" "$pad" '' "$1" "$C_RESET"
    lst_rule '='
}

# lst_status_color <status>: print status text in its badge color.
lst_status_color() {
    case "$1" in
        OK|PASS) printf '%s%s%s' "$C_GREEN" "$1" "$C_RESET" ;;
        WARN)    printf '%s%s%s' "$C_YELLOW" "$1" "$C_RESET" ;;
        CRIT|FAIL) printf '%s%s%s%s' "$C_RED" "$C_BOLD" "$1" "$C_RESET" ;;
        *)       printf '%s' "$1" ;;
    esac
}

# lst_fmt_kib <kib>: human-readable IEC size.
lst_fmt_kib() {
    awk -v k="$1" 'BEGIN {
        split("KiB MiB GiB TiB PiB", unit); i = 1
        while (k >= 1024 && i < 5) { k /= 1024; i++ }
        if (i == 1) printf "%d %s", k, unit[i]; else printf "%.1f %s", k, unit[i]
    }'
}

# lst_fmt_bytes <bytes>: human-readable IEC size.
lst_fmt_bytes() {
    if (( $1 < 1024 )); then
        printf '%d B' "$1"
    else
        lst_fmt_kib "$(( $1 / 1024 ))"
    fi
}

# ------------------------------------------------------------------------------
# Status handling
# ------------------------------------------------------------------------------

# lst_worse <var> <status>: raise the status held in <var> to <status> if that
# is more severe. Order: OK < WARN < CRIT (INFO and SKIP never raise).
lst_worse() {
    local -n lst_ref_="$1"
    case "$2:${lst_ref_}" in
        CRIT:*) lst_ref_=CRIT ;;
        WARN:OK) lst_ref_=WARN ;;
    esac
}

# lst_exit_code <status>: map OK/WARN/CRIT to the monitoring exit code.
lst_exit_code() {
    case "$1" in
        OK)   echo "$LST_EXIT_OK" ;;
        WARN) echo "$LST_EXIT_WARN" ;;
        CRIT) echo "$LST_EXIT_CRIT" ;;
        *)    echo "$LST_EXIT_UNKNOWN" ;;
    esac
}

# lst_threshold <value> <warn> <crit>: classify an integer value.
lst_threshold() {
    if (( $1 >= $3 )); then
        echo CRIT
    elif (( $1 >= $2 )); then
        echo WARN
    else
        echo OK
    fi
}

# ------------------------------------------------------------------------------
# Argument validation
# ------------------------------------------------------------------------------

lst_usage_error() {
    printf '%s: %s\nTry '\''%s --help'\'' for more information.\n' \
        "$LST_PROG" "$*" "$LST_PROG" >&2
    exit "$LST_USAGE_EXIT"
}

# lst_need_arg <option> [value]: fail unless the option received a value.
lst_need_arg() {
    [[ $# -ge 2 && -n "$2" ]] || lst_usage_error "option '$1' requires an argument"
}

lst_is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# lst_uint <option> <value> <var>: validate a non-negative integer into <var>.
lst_uint() {
    local -n lst_out_="$3"
    lst_is_uint "$2" || lst_usage_error "$1 expects a non-negative integer, got '$2'"
    lst_out_=$(( 10#$2 ))
}

# lst_thresholds <option> <spec> <warn_var> <crit_var>: parse "WARN[:CRIT]"
# percentages. A lone WARN above the current CRIT also raises CRIT to WARN.
lst_thresholds() {
    local -n lst_warn_="$3" lst_crit_="$4"
    local warn="${2%%:*}" crit="$lst_crit_"
    [[ "$2" == *:* ]] && crit="${2#*:}"

    if ! lst_is_uint "$warn" || ! lst_is_uint "$crit" \
        || (( 10#$warn > 100 || 10#$crit > 100 )); then
        lst_usage_error "$1 expects PCT or WARN:CRIT (0-100), got '$2'"
    fi
    warn=$(( 10#$warn )) crit=$(( 10#$crit ))

    if (( warn > crit )); then
        [[ "$2" == *:* ]] && lst_usage_error "$1: warning ($warn) exceeds critical ($crit)"
        crit=$warn
    fi
    lst_warn_=$warn lst_crit_=$crit
}

# ------------------------------------------------------------------------------
# JSON
# ------------------------------------------------------------------------------

# lst_json_str <string>: print <string> as a quoted, escaped JSON string.
lst_json_str() {
    local LC_ALL=C s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    s="${s//[$'\001'-$'\037']/}"
    printf '"%s"' "$s"
}

# lst_json_strs <string>...: print a JSON array of strings.
lst_json_strs() {
    local out='' s
    for s in "$@"; do
        out+="${out:+,}$(lst_json_str "$s")"
    done
    printf '[%s]' "$out"
}

# lst_json_join <json>...: print a JSON array of already-encoded values.
lst_json_join() {
    local IFS=,
    printf '[%s]' "$*"
}

# ------------------------------------------------------------------------------
# Logging (action tools)
# ------------------------------------------------------------------------------

LST_QUIET=0

# Under systemd, prefix log lines with sd-daemon(3) priorities so journald
# records the right level and `journalctl -p warning` works.
LST_JOURNAL=0
if [[ -n "${JOURNAL_STREAM:-}" ]] \
    && [[ "$(stat -L -c '%d:%i' /dev/stderr 2>/dev/null)" == "$JOURNAL_STREAM" ]]; then
    LST_JOURNAL=1
fi

# lst_log <INFO|WARN|ERROR> <message>...: log to stderr.
lst_log() {
    local level="$1" prio
    shift
    case "$level" in
        ERROR) prio=3 ;;
        WARN)  prio=4 ;;
        *)     prio=6; (( LST_QUIET )) && return 0 ;;
    esac
    if (( LST_JOURNAL )); then
        printf '<%d>%s\n' "$prio" "$*" >&2
    else
        printf '%s %s[%d]: %-5s %s\n' "$(date '+%F %T')" "$LST_PROG" "$$" "$level" "$*" >&2
    fi
}

lst_die() {
    lst_log ERROR "$*"
    exit 1
}

# ------------------------------------------------------------------------------
# Host facts
# ------------------------------------------------------------------------------

lst_hostname() {
    local name=''
    read -r name 2>/dev/null < "${LST_ROOT}/proc/sys/kernel/hostname" || name="$(uname -n)"
    printf '%s' "$name"
}

lst_timestamp() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# lst_systemd_booted: true when PID 1 is systemd (same test as sd_booted(3)).
lst_systemd_booted() {
    [[ -d "${LST_ROOT}/run/systemd/system" ]] && command -v systemctl >/dev/null 2>&1
}
