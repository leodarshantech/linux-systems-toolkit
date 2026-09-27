PREFIX     ?= /usr/local
BINDIR     ?= $(PREFIX)/bin
LIBDIR     ?= $(PREFIX)/lib/linux-systems-toolkit
SYSCONFDIR ?= /etc
UNITDIR    ?= /etc/systemd/system
BACKUPDIR  ?= /var/backups/sys-backup-rotate

TOOLS := sys-health-audit sys-backup-rotate net-socket-triage sys-log-pruner sys-cis-audit
UNITS := $(notdir $(wildcard systemd/*.service systemd/*.timer))
TESTS := $(wildcard tests/test_*.sh)

.PHONY: all help check lint test verify-units install uninstall

all: help

help:
	@echo "linux-systems-toolkit"
	@echo "  make check         lint + test"
	@echo "  make lint          ShellCheck every script"
	@echo "  make test          Run the test suites"
	@echo "  make verify-units  systemd-analyze verify + security score for the units"
	@echo "  make install       Install tools, library, units and example configs (root)"
	@echo "  make uninstall     Remove installed files (configs and backups are kept)"

check: lint test

lint:
	shellcheck bin/* lib/*.sh tests/*.sh

test:
	@failed=0; \
	for t in $(TESTS); do \
		echo "=== $$t"; \
		bash "$$t" || failed=1; \
	done; \
	exit $$failed

# Units reference /usr/local/bin; point them at this checkout so verify can
# resolve ExecStart without installing anything.
verify-units:
	@tmp="$$(mktemp -d)"; trap 'rm -rf "$$tmp"' EXIT; \
	for u in $(UNITS); do sed "s|/usr/local/bin|$(CURDIR)/bin|g" "systemd/$$u" > "$$tmp/$$u"; done; \
	systemd-analyze verify "$$tmp"/*; \
	for s in "$$tmp"/*.service; do systemd-analyze security --offline=yes --no-pager "$$s" | tail -n 1; done

install:
	install -d $(DESTDIR)$(BINDIR) $(DESTDIR)$(LIBDIR) $(DESTDIR)$(UNITDIR)
	install -m 0644 lib/common.sh $(DESTDIR)$(LIBDIR)/common.sh
	for t in $(TOOLS); do install -m 0755 bin/$$t $(DESTDIR)$(BINDIR)/$$t; done
	for u in $(UNITS); do \
		sed 's|/usr/local/bin|$(BINDIR)|g' systemd/$$u > $(DESTDIR)$(UNITDIR)/$$u; \
		chmod 0644 $(DESTDIR)$(UNITDIR)/$$u; \
	done
	install -d $(DESTDIR)$(SYSCONFDIR)
	[ -e $(DESTDIR)$(SYSCONFDIR)/sys-backup-rotate.conf ] || \
		install -m 0644 etc/sys-backup-rotate.conf $(DESTDIR)$(SYSCONFDIR)/sys-backup-rotate.conf
	[ -e $(DESTDIR)$(SYSCONFDIR)/net-socket-triage.allow ] || \
		install -m 0644 etc/net-socket-triage.allow $(DESTDIR)$(SYSCONFDIR)/net-socket-triage.allow
	install -d -m 0700 $(DESTDIR)$(BACKUPDIR)
	@echo
	@echo "Installed. Next steps:"
	@echo "  systemctl daemon-reload"
	@echo "  systemctl enable --now sys-health-audit.timer sys-log-pruner.timer sys-backup-rotate.timer"

uninstall:
	for t in $(TOOLS); do rm -f $(DESTDIR)$(BINDIR)/$$t; done
	rm -rf $(DESTDIR)$(LIBDIR)
	for u in $(UNITS); do rm -f $(DESTDIR)$(UNITDIR)/$$u; done
	@echo "Removed. Kept $(SYSCONFDIR)/sys-backup-rotate.conf, $(SYSCONFDIR)/net-socket-triage.allow and $(BACKUPDIR)."
