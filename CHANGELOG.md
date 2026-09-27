# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [2.0.0] - Unreleased

### Added
- `sys-backup-rotate`: tar + zstd/gzip archives with SHA-256 sidecars, atomic
  writes, `--verify`, and borg-style GFS retention (7 daily / 4 weekly / 3 monthly).
- `net-socket-triage`: TCP state counts with CLOSE-WAIT / SYN-RECV / TIME-WAIT
  analysis, listening-port allowlist audit, DNS resolver latency benchmark.
- `sys-log-pruner`: threshold-triggered journal vacuum and rotated-log cleanup.
- `sys-cis-audit`: read-only 32-check hardening audit aligned with CIS Level 1.
- `lib/common.sh` shared by all tools; hardened systemd units and timers for
  the backup and log-pruning tools; example configs in `etc/`.
- Fixture-based test suites for every tool (`LST_ROOT` + command stubs), CI
  matrix on Ubuntu 24.04, AlmaLinux 10 and Arch Linux, `make verify-units`.

### Changed (breaking)
- `sys-health-audit --json` now prints one line; disk entries are grouped per
  filesystem with numeric `*_kib` sizes and merged inode data; keys renamed
  (`overall_status` → `status`, `cores` → `count`, …).
- Usage errors exit 3 (UNKNOWN) instead of 2 (CRITICAL).
- Thresholds accept `WARN:CRIT` (e.g. `--disk 80:90`); new `--swap` and `--ssh`.

### Fixed
- The hourly service failed on WARN/CRIT, so the next run reported its own
  unit as failed and latched the host at CRIT (`SuccessExitStatus=1 2`).
- `Persistent=true` had no effect with `OnUnitActiveSec=`; the timer now uses
  `OnCalendar=hourly`. The service no longer has an `[Install]` section.
- Service ran as full root with an unneeded `CAP_NET_ADMIN`; it now uses
  `DynamicUser` with no capabilities (exposure score 6.0 → 1.1).
- Zombie detection broke on process names containing spaces, and a process
  exiting mid-scan could crash the script.
- Unit names with `\x2d` escapes and hostnames with quotes produced invalid JSON.
- SSH failures missed OpenSSH ≥ 9.8 (`sshd-session`), double counted PAM
  lines, and reported 0 when the journal was unreadable.
- A missing option argument crashed with "unbound variable".
- btrfs subvolumes were reported once per mount; `/boot/efi` (vfat) was not checked.
- Colored and plain output were misaligned.
- CI ignored `systemd-analyze verify` failures (`|| true`).

## [1.0.0] - 2026-09-27

### Added
- `sys-health-audit` with text and JSON output, systemd service and timer,
  test script, CI workflow and bilingual README.
