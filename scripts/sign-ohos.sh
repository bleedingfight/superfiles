#!/usr/bin/env bash
# Sign a HarmonyOS NEXT HAP with hap-sign-tool (no DevEco Studio needed).
#
# Required material (see signature/README.md), by default read from ./signature:
#   superfiles.p12   keystore containing the private key
#   superfiles.cer   debug/release certificate exported from AppGallery Connect
#   superfiles.p7b   profile bound to com.superfiles.app + device UDID
#
# Usage:
#   SIGN_KEY_PWD=<keystore-password> ./scripts/sign-ohos.sh [--install] [<in.hap>]
#
# Env overrides:
#   SIGN_KEYSTORE  SIGN_CERT  SIGN_PROFILE
#   SIGN_KEY_ALIAS (default: superfiles)
#   SIGN_KEY_PWD   (default: $KEY_PASSWORD, exported from ~/.config/fish/config.fish)
#   DEVECO_SDK_HOME (default: ~/command-line-tools/sdk)
set -euo pipefail
cd "$(dirname "$0")/.."

SDK_HOME=${DEVECO_SDK_HOME:-$HOME/command-line-tools/sdk}
SIGN_TOOL="$SDK_HOME/default/openharmony/toolchains/lib/hap-sign-tool.jar"
HDC="${HDC:-$SDK_HOME/default/openharmony/toolchains/hdc}"
KEYSTORE=${SIGN_KEYSTORE:-signature/superfiles.p12}
CERT=${SIGN_CERT:-signature/superfiles.cer}
PROFILE=${SIGN_PROFILE:-signature/superfiles.p7b}
ALIAS=${SIGN_KEY_ALIAS:-superfiles}
PWD_=${SIGN_KEY_PWD:-${KEY_PASSWORD:-}}

DO_INSTALL=0
IN=""
for arg in "$@"; do
  case "$arg" in
    --install) DO_INSTALL=1 ;;
    -*) echo "unknown arg: $arg" >&2; exit 2 ;;
    *) IN=$arg ;;
  esac
done
IN=${IN:-apps/ohos/entry/build/default/outputs/default/entry-default-unsigned.hap}
OUT=${IN%-unsigned.hap}-signed.hap

for f in "$SIGN_TOOL" "$KEYSTORE" "$CERT" "$PROFILE" "$IN"; do
  [[ -e $f ]] || { echo "missing: $f" >&2; exit 1; }
done
if [[ -z $PWD_ ]]; then
  read -r -s -p "keystore password: " PWD_
  echo
fi

java -jar "$SIGN_TOOL" sign-app \
  -mode localSign \
  -keyAlias "$ALIAS" \
  -signAlg SHA256withECDSA \
  -keystoreFile "$KEYSTORE" -keystorePwd "$PWD_" \
  -keyPwd "$PWD_" \
  -appCertFile "$CERT" \
  -profileFile "$PROFILE" \
  -inFile "$IN" -outFile "$OUT"

echo "signed: $OUT"

if (( DO_INSTALL )); then
  "$HDC" install -r "$OUT"
fi
