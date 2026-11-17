#!/usr/bin/env bash
# One-shot on Linux (no DevEco Studio): Rust core -> HAP -> sign -> install -> launch.
#
# Usage:
#   ./scripts/run-ohos.sh                 # everything
#   ./scripts/run-ohos.sh --no-rust       # skip the .so cross-build (ArkTS-only change)
#   ./scripts/run-ohos.sh --no-install    # build + sign only, leave the hap on disk
#
# Env: BUNDLE (default com.superfiles.app), ABILITY (default EntryAbility),
#      KEY_PASSWORD (keystore password, see signature/README.md)
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE=${BUNDLE:-com.superfiles.app}
ABILITY=${ABILITY:-EntryAbility}
BUILD_RUST=1
INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --no-rust) BUILD_RUST=0 ;;
    --no-install) INSTALL=0 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

export DEVECO_SDK_HOME=${DEVECO_SDK_HOME:-$HOME/command-line-tools/sdk}
export PATH="$HOME/command-line-tools/bin:$DEVECO_SDK_HOME/default/openharmony/toolchains:$PATH"

if (( BUILD_RUST )); then
  echo "== rust core (aarch64-unknown-linux-ohos)"
  ./scripts/build-ohos.sh
fi

echo "== hvigor assembleHap"
(cd apps/ohos && hvigorw assembleHap --mode module -p product=default --no-daemon | tail -3)

if (( INSTALL )); then
  ./scripts/sign-ohos.sh --install
  echo "== launch $BUNDLE/$ABILITY"
  hdc shell aa force-stop "$BUNDLE" >/dev/null 2>&1 || true
  hdc shell aa start -a "$ABILITY" -b "$BUNDLE"
else
  ./scripts/sign-ohos.sh
fi
