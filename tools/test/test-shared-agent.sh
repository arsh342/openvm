#!/bin/sh
# Builds and runs the Linux agent test for shared folder requests.
set -eu
cd "$(dirname "$0")/../.."
OVM_TEST_DIR=$(mktemp -d /tmp/openvm-shared-agent.XXXXXX)
trap 'rm -rf "$OVM_TEST_DIR"' EXIT
# The handler mkdir -p's the mount path before mounting; keep it in a throwaway
# directory so this host never grows a stray mount point.
mkdir -p "$OVM_TEST_DIR/mnt"
clang -std=c11 -Wall -Wextra -Werror -Wno-unused-function -pthread -I tools \
    tools/test/test-shared-agent.c -o "$OVM_TEST_DIR/shared-agent-test"
OVM_TEST_MOUNT_PATH="$OVM_TEST_DIR/mnt" "$OVM_TEST_DIR/shared-agent-test"
