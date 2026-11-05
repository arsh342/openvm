#!/bin/sh
# Builds and runs the Linux agent test for the suspend handshake.
set -eu
cd "$(dirname "$0")/../.."
OVM_TEST_DIR=$(mktemp -d /tmp/openvm-suspend-agent.XXXXXX)
trap 'rm -rf "$OVM_TEST_DIR"' EXIT
clang -std=c11 -Wall -Wextra -Werror -Wno-unused-function -pthread -I tools \
    tools/test/test-suspend-agent.c -o "$OVM_TEST_DIR/suspend-agent-test"
"$OVM_TEST_DIR/suspend-agent-test"
