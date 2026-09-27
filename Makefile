PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
SYSTEMDDIR ?= /etc/systemd/system

.PHONY: all test lint install uninstall help

all: help

help:
	@echo "linux-systems-toolkit management:"
	@echo "  make test      Run automated test suite"
	@echo "  make lint      Run shellcheck on all shell scripts"
	@echo "  make install   Install binaries and systemd units (requires root)"
	@echo "  make uninstall Remove installed files"

test:
	@./tests/test_sys_health_audit.sh

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck bin/* tests/*.sh; \
		echo "All scripts passed ShellCheck!"; \
	else \
		echo "shellcheck not installed; skipping lint"; \
	fi

install:
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 bin/sys-health-audit $(DESTDIR)$(BINDIR)/sys-health-audit
	install -d $(DESTDIR)$(SYSTEMDDIR)
	install -m 0644 systemd/sys-health-audit.service $(DESTDIR)$(SYSTEMDDIR)/
	install -m 0644 systemd/sys-health-audit.timer $(DESTDIR)$(SYSTEMDDIR)/
	@echo "Installed successfully to $(DESTDIR)$(PREFIX)"

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/sys-health-audit
	rm -f $(DESTDIR)$(SYSTEMDDIR)/sys-health-audit.service
	rm -f $(DESTDIR)$(SYSTEMDDIR)/sys-health-audit.timer
	@echo "Uninstalled."
