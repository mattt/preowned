SHELL := /bin/bash

DESTDIR ?=
PREFIX = /usr/local
BINDIR = $(PREFIX)/bin

INSTALL := install -m 0755
INSTALL_PROGRAM := $(INSTALL)

# Xcode's Swift, which has the macOS 27 SDK that the build needs.
SWIFT := xcrun swift

# The server that `make smoke` tests.
# Start it first, for example with `make serve` in another terminal.
SMOKE_BASE_URL ?= http://127.0.0.1:8027/v1

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

.PHONY: smoke
smoke:
	uv run Scripts/smoke.py --base-url $(SMOKE_BASE_URL)

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

.PHONY: help
help:
	@echo "make            Build the release binary ./preowned"
	@echo "make build      Build a debug binary in .build/debug"
	@echo "make test       Run the tests (no Apple Intelligence needed)"
	@echo "make lint       Check formatting with swift format"
	@echo "make format     Format the sources in place"
	@echo "make smoke      Test a running server with the OpenAI Python SDK;"
	@echo "                start the server first, and set SMOKE_BASE_URL"
	@echo "                if it is not at $(SMOKE_BASE_URL)"
	@echo "make serve      Build and start the server on port 8027"
	@echo "make install    Install preowned in $(BINDIR)"
	@echo "make uninstall  Remove preowned from $(BINDIR)"
	@echo "make clean      Remove build products"
