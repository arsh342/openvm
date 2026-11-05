#!/bin/sh
# End-to-end conformance: golden byte streams into the built mock guest,
# exact hex comparison of the replies. Prints both dumps on any mismatch.
set -e
cd "$(dirname "$0")/../.."
swift build -c debug >/dev/null 2>&1
BIN=.build/debug/openvm-mockguest

# HELLO {product:"openVM",version:1,id:1} + ECHO_REQUEST {id:7}
IN="4f564d430001000100000000001da36770726f64756374666f70656e564d6776657273696f6e01626964014f564d4300010003000000000005a162696407"
# expected replies: HELLO_REPLY {accepted:true,version:1,id:1} + ECHO_REPLY {id:7}
EXPECTED="4f564d4300010002000000000018a3686163636570746564f56776657273696f6e01626964014f564d4300010004000000000005a162696407"

ACTUAL=$(printf '%s' "$IN" | xxd -r -p | "$BIN" | xxd -p | tr -d '\n')
if [ "$ACTUAL" = "$EXPECTED" ]; then
  echo "conformance: PASS (mock guest replies match the catalogue bit-for-bit)"
else
  echo "conformance: FAIL"
  echo "$EXPECTED" | fold -w 96 | sed 's/^/expected: /'
  echo "$ACTUAL"   | fold -w 96 | sed 's/^/actual:   /'
  exit 1
fi
