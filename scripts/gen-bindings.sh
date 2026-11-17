#!/usr/bin/env bash
# Regenerate Swift + Kotlin bindings from the Rust core.
#
# Requires nothing but a working Rust toolchain. Swift/ktlint formatting is
# skipped on purpose (see --no-format) so generation is reproducible anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."

cargo build -p sfiles-ffi

LIB="target/debug/libsuperfiles.so"
if [[ ! -f "$LIB" ]]; then
    LIB="target/debug/libsuperfiles.dylib"
fi
if [[ ! -f "$LIB" ]]; then
    echo "error: could not find the built core library under target/debug" >&2
    exit 1
fi

rm -rf bindings/swift bindings/kotlin
mkdir -p bindings/swift bindings/kotlin

cargo run -q -p sfiles-bindgen -- generate "$LIB" \
    --language swift --out-dir bindings/swift --no-format

cargo run -q -p sfiles-bindgen -- generate "$LIB" \
    --language kotlin --out-dir bindings/kotlin --no-format

echo "Swift  -> bindings/swift"
echo "Kotlin -> bindings/kotlin"
echo
echo "ArkTS  -> ./scripts/gen-bindings-arkts.sh (HarmonyOS, separate tool)"
