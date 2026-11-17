#!/usr/bin/env bash
# Cross-build the Rust core (sfiles-ffi) for HarmonyOS NEXT (aarch64).
#
# Prerequisites:
#   1. rustup target add aarch64-unknown-linux-ohos
#   2. HarmonyOS command-line-tools (contains the NDK) — set OHOS_SDK to its
#      directory, e.g. ~/command-line-tools/sdk/default/openharmony
#
# Usage:
#   ./scripts/build-ohos.sh [--release|--debug]
#
# Output: apps/ohos/entry/libs/<abi>/{libsuperfiles.so, libsuperfiles_arkts.so}
#         (both are packaged into the HAP by DevEco)
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE=release
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) PROFILE=debug ;;
    --release) PROFILE=release ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# --- locate the OHOS SDK (NDK) ---------------------------------------------
SDK="${OHOS_SDK:-${DEVECO_SDK_HOME:-}}"
# DEVECO_SDK_HOME points at the sdk root (…/sdk), the NDK lives one level down.
if [[ -n "$SDK" && ! -f "$SDK/native/llvm/bin/clang" && -f "$SDK/default/openharmony/native/llvm/bin/clang" ]]; then
  SDK="$SDK/default/openharmony"
fi
if [[ -z "$SDK" ]]; then
  for cand in \
    "$HOME/command-line-tools/sdk/default/openharmony" \
    "$HOME/OpenHarmony/Sdk/default/openharmony" \
    "/opt/command-line-tools/sdk/default/openharmony" \
    "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony"; do
    if [[ -f "$cand/native/llvm/bin/clang" ]]; then SDK="$cand"; break; fi
  done
fi
if [[ -z "$SDK" || ! -f "$SDK/native/llvm/bin/clang" ]]; then
  cat >&2 <<'EOF'
error: HarmonyOS SDK (NDK) not found.
Install DevEco Studio / command-line-tools, then either:
  export OHOS_SDK=<path>/sdk/default/openharmony
EOF
  exit 1
fi
echo "OHOS SDK: $SDK"

CLANG="$SDK/native/llvm/bin/clang"
SYSROOT="$SDK/native/sysroot"
ABI=arm64-v8a
TARGET=aarch64-unknown-linux-ohos

# cc crate picks these up when compiling C dependencies (SQLite, ring asm).
export CC_${TARGET//-/_}="$CLANG"
export CXX_${TARGET//-/_}="$CLANG++"
export AR_${TARGET//-/_}="$SDK/native/llvm/bin/llvm-ar"
export AS_${TARGET//-/_}="$CLANG"
# Ensure C builds use the OHOS sysroot even if a stray CFLAGS leaks in.
export CFLAGS_${TARGET//-/_}="--target=$TARGET --sysroot=$SYSROOT"

ARGS=(--target "$TARGET" "--config" "target.$TARGET.linker=\"$CLANG\"")
ARGS+=("--config" "target.$TARGET.rustflags=[\"-Clink-arg=--target=$TARGET\",\"-Clink-arg=--sysroot=$SYSROOT\",\"-Clink-arg=-fuse-ld=lld\"]")

if [[ $PROFILE == release ]]; then
  cargo build -p sfiles-ffi --release "${ARGS[@]}"
  LIB="target/$TARGET/release/libsuperfiles.so"
else
  cargo build -p sfiles-ffi "${ARGS[@]}"
  LIB="target/$TARGET/debug/libsuperfiles.so"
fi
[[ -f "$LIB" ]] || { echo "error: $LIB not produced" >&2; exit 1; }

# --- native N-API adapter (bindings/arkts/native) ---------------------------
# The ArkTS package calls libsuperfiles_arkts.so, which forwards to the core
# libsuperfiles.so over the UniFFI C ABI. Both must ship in the HAP.
if [[ -f bindings/arkts/native/Cargo.toml ]]; then
  CORE_LIB_DIR="$(dirname "$LIB")"
  # The adapter is a standalone cargo workspace → its own target dir.
  UNIFFI_ARKTS_LINK_SEARCH_DIR="$PWD/$CORE_LIB_DIR" \
    cargo build --manifest-path bindings/arkts/native/Cargo.toml --profile "$([[ $PROFILE == release ]] && echo release || echo dev)" "${ARGS[@]}"
  ADAPTER="bindings/arkts/native/target/$TARGET/$PROFILE/libsuperfiles_arkts.so"
  [[ -f "$ADAPTER" ]] || { echo "error: $ADAPTER not produced" >&2; exit 1; }
else
  echo "error: bindings/arkts/native missing — run ./scripts/gen-bindings-arkts.sh first" >&2
  exit 1
fi

mkdir -p "apps/ohos/entry/libs/$ABI"
cp "$LIB" "apps/ohos/entry/libs/$ABI/libsuperfiles.so"
cp "$ADAPTER" "apps/ohos/entry/libs/$ABI/libsuperfiles_arkts.so"
echo
echo "OK -> apps/ohos/entry/libs/$ABI/{libsuperfiles.so, libsuperfiles_arkts.so}"

# Sanity: the .so must only depend on system libraries shipped on-device.
if command -v "$SDK/native/llvm/bin/llvm-readelf" >/dev/null; then
  echo "--- NEEDED ---"
  "$SDK/native/llvm/bin/llvm-readelf" -d "$LIB" | grep NEEDED || true
fi
