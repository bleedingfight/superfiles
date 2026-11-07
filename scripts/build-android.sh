#!/usr/bin/env bash
# Build the Rust core for Android and drop the .so files into jniLibs.
#
# Requirements:
#   rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
#   cargo install cargo-ndk
#   ANDROID_NDK_HOME or ANDROID_NDK_ROOT pointing at an installed NDK
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v cargo-ndk >/dev/null; then
    echo "error: cargo-ndk not found. Install it with: cargo install cargo-ndk" >&2
    exit 1
fi

cargo ndk \
    -t arm64-v8a \
    -t armeabi-v7a \
    -t x86_64 \
    -o apps/android/app/src/main/jniLibs \
    build --release -p sfiles-ffi

echo "JNI libraries written to apps/android/app/src/main/jniLibs"
echo "Next: cd apps/android && ./gradlew assembleDebug"
