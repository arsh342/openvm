#!/bin/sh
# Builds and runs the Linux agent test for the file service.
set -eu
cd "$(dirname "$0")/../.."
OVM_TEST_DIR=$(mktemp -d /tmp/openvm-file-agent.XXXXXX)
trap 'rm -rf "$OVM_TEST_DIR"' EXIT
clang -std=c11 -Wall -Wextra -Werror -Wno-unused-function -pthread -I tools \
    -DOPENVM_SHARE_PARENT="\"$OVM_TEST_DIR\"" \
    -DOPENVM_SHARE_NAME='"share"' \
    tools/test/test-file-agent.c -o "$OVM_TEST_DIR/file-agent-test"
"$OVM_TEST_DIR/file-agent-test"
