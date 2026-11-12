#!/bin/sh
# build-windows-agent.sh — cross-compile the Windows guest agent for ARM64.
#
# zig carries the mingw-w64 headers, CRT and ARM64 import libraries, so the
# agent builds on macOS with no Windows SDK. The result runs against the UCRT
# that ships with Windows 10 and later.
#
# usage: build-windows-agent.sh [out-dir]   (default .build/windows-agent)
set -eu

cd "$(dirname "$0")/../.."
command -v zig >/dev/null || {
    echo "build-windows-agent: needs zig (brew install zig) for the mingw-w64 ARM64 toolchain" >&2
    exit 1
}
OUT=${1:-.build/windows-agent}
mkdir -p "$OUT"
# OPENVM_AGENT_CFLAGS: -DOPENVM_AGENT_TRACE builds the diagnosis agent.
zig cc -target aarch64-windows-gnu -std=c99 -O2 ${OPENVM_AGENT_CFLAGS:-} \
    -Wall -Wextra -Werror -Wno-unused-function \
    -Itools/guest -o "$OUT/openvm-tools-win.exe" tools/guest/openvm-tools-win.c \
    -lws2_32 -luser32 -ladvapi32 -lwtsapi32 -lwinspool -lgdi32 -lwinmm -lshcore -lshell32 -lole32 -luserenv -lsetupapi
rm -f "$OUT/openvm-tools-win.pdb"
echo "$OUT/openvm-tools-win.exe"
