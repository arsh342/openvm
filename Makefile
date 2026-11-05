# openvm — developer entry points.
#
# The only reason this file exists is `make test`. On a machine with only the
# Command Line Tools installed (no full Xcode), swift-frontend does not
# auto-load the swift-testing macro plugin, so a bare `swift test` fails with
#
#   external macro implementation type 'TestingMacros.TestDeclarationMacro'
#   could not be found for macro 'Test'
#
# which looks like a broken test target and is not. The plugin is present; it
# just has to be named. `make test` finds it and passes it through, and falls
# back to a plain `swift test` on toolchains that do not need the hint.

SHELL := /bin/sh

# Where the swift-testing macro plugin lives, per toolchain layout.
# Command Line Tools puts it under the active developer dir; a full Xcode puts
# it inside the macOS platform directory.
PLUGIN_NAME := libTestingMacros.dylib
DEV_DIR     := $(shell xcode-select -p 2>/dev/null)
PLUGIN      := $(firstword $(wildcard \
	$(DEV_DIR)/usr/lib/swift/host/plugins/testing/$(PLUGIN_NAME) \
	$(DEV_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/testing/$(PLUGIN_NAME) \
	$(DEV_DIR)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/$(PLUGIN_NAME)))

# Only add the flag when the plugin was actually found, so a toolchain that
# resolves it on its own is not handed a redundant (or stale) path.
ifeq ($(PLUGIN),)
TEST_FLAGS :=
else
TEST_FLAGS := -Xswiftc -load-plugin-library -Xswiftc $(PLUGIN)
endif

.PHONY: all build test guest-tests format check windows-smoke clean

all: check

build:
	swift build

## Run the Swift suite, with the macro plugin named when the toolchain needs it.
test:
	swift test $(TEST_FLAGS)

## The guest-agent checks that do not need a guest: C compile + codec round-trip.
guest-tests:
	sh tools/test/test-windows-agent.sh
	sh tools/test/test-file-agent.sh
	sh tools/test/test-shared-agent.sh
	sh tools/test/test-suspend-agent.sh
	sh tools/test/test-timesync-agent.sh
	sh tools/test/test-printer-agent.sh
	sh tools/test/test-drag-agent.sh
	sh tools/test/test-audio-agent.sh
	sh tools/test/conformance.sh

## Format Swift and C in place (needs clang-format).
format:
	swift format -i -r Sources Tests Package.swift tools/test/host-output-running.swift
	git ls-files 'tools/*.c' 'tools/*.h' | xargs clang-format -i

## Everything that can be checked on this machine without booting a guest.
check: build test guest-tests

## A real Windows guest, about 30 minutes: make windows-smoke ISO=<windows-iso>
windows-smoke: build
	sh tools/test/windows-smoke.sh "$(ISO)"

clean:
	swift package clean
