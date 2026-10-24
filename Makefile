# Install the CaptureAge launcher, desktop entry and icon.
#
#   make install                           # user-local ($HOME/.local)
#   make install PREFIX=/usr/local         # system-wide (needs root)
#   make uninstall                         # remove
#   make check                             # validate the desktop entry

PREFIX   ?= $(HOME)/.local
BINDIR   ?= $(PREFIX)/bin
DATADIR  ?= $(PREFIX)/share
APPDIR   ?= $(DATADIR)/applications
ICONDIR  ?= $(DATADIR)/icons/hicolor/256x256/apps
DESTDIR  ?=

INSTALL  ?= install

.PHONY: all install uninstall check help

all: help

install:
	$(INSTALL) -Dm755 capture-age.sh "$(DESTDIR)$(BINDIR)/capture-age"
	$(INSTALL) -d "$(DESTDIR)$(APPDIR)"
	sed 's|@BINDIR@|$(BINDIR)|g' assets/capture-age.desktop > "$(DESTDIR)$(APPDIR)/capture-age.desktop"
	chmod 644 "$(DESTDIR)$(APPDIR)/capture-age.desktop"
	$(INSTALL) -Dm644 assets/capture-age.png "$(DESTDIR)$(ICONDIR)/capture-age.png"
	@if [ -z "$(DESTDIR)" ] && command -v update-desktop-database >/dev/null 2>&1; then \
		update-desktop-database -q "$(APPDIR)"; fi

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/capture-age" \
	      "$(DESTDIR)$(APPDIR)/capture-age.desktop" \
	      "$(DESTDIR)$(ICONDIR)/capture-age.png"
	@if [ -z "$(DESTDIR)" ] && command -v update-desktop-database >/dev/null 2>&1; then \
		update-desktop-database -q "$(APPDIR)"; fi

check:
	@command -v desktop-file-validate >/dev/null 2>&1 || { echo "desktop-file-validate not installed"; exit 1; }
	@tmp=$$(mktemp --suffix=.desktop) && sed 's|@BINDIR@|$(BINDIR)|g' assets/capture-age.desktop > "$$tmp" && \
		desktop-file-validate "$$tmp"; rc=$$?; rm -f "$$tmp"; exit $$rc

help:
	@echo "Targets:"
	@echo "  install    install capture-age, desktop entry and icon (PREFIX=$(PREFIX))"
	@echo "  uninstall  remove them"
	@echo "  check      validate capture-age.desktop"
	@echo
	@echo "Default (user-local): make install   -> $(BINDIR)"
	@echo "System-wide:         sudo make install PREFIX=/usr/local"
