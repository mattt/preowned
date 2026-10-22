SHELL := /bin/bash

DESTDIR ?=
PREFIX = /usr/local
BINDIR = $(PREFIX)/bin

INSTALL := install -m 0755
INSTALL_PROGRAM := $(INSTALL)

SWIFT := swift

SOURCES := $(shell find Sources -name '*.swift')

default: all

.PHONY: all
all: preowned

preowned: $(SOURCES) Package.swift
	$(SWIFT) build -c release --disable-sandbox
	cp .build/release/preowned $@

.PHONY: build
build:
	$(SWIFT) build

.PHONY: test
test:
	$(SWIFT) test

.PHONY: lint
lint:
	$(SWIFT) format lint --strict --recursive .

.PHONY: format
format:
	$(SWIFT) format --in-place --recursive .

.PHONY: install
install: preowned
	$(INSTALL_PROGRAM) -d $(DESTDIR)$(BINDIR)
	$(INSTALL_PROGRAM) preowned $(DESTDIR)$(BINDIR)/preowned

.PHONY: uninstall
uninstall:
	rm -f $(DESTDIR)$(BINDIR)/preowned

.PHONY: clean
clean:
	$(SWIFT) package clean
	rm -f preowned
	rm -rf .build

.PHONY: serve
serve: preowned
	./preowned serve
