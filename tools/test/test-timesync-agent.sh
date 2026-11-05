#!/bin/sh
# Builds and runs the Linux agent test for the clock push.
set -eu
cd "$(dirname "$0")/../.."
OVM_TEST_DIR=$(mktemp -d /tmp/openvm-timesync-agent.XXXXXX)
trap 'rm -rf "$OVM_TEST_DIR"' EXIT
# A throwaway zoneinfo root: the harness must never touch the host's
# /etc/localtime or /usr/share/zoneinfo.
mkdir -p "$OVM_TEST_DIR/zoneinfo/Europe"
: >"$OVM_TEST_DIR/zoneinfo/Europe/Berlin"
clang -std=c11 -Wall -Wextra -Werror -Wno-unused-function -pthread -I tools \
    -DOPENVM_TZINFO_DIR="\"$OVM_TEST_DIR/zoneinfo\"" \
    -DOPENVM_LOCALTIME_PATH="\"$OVM_TEST_DIR/localtime\"" \
    tools/test/test-timesync-agent.c -o "$OVM_TEST_DIR/timesync-agent-test"
"$OVM_TEST_DIR/timesync-agent-test"
