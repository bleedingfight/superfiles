#!/usr/bin/env bash
# Build the Rust core for iOS and produce SuperFilesCore.xcframework.
#
# Requirements (macOS only):
#   xcode-select --install
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
#   brew install xcodegen    # optional, only to (re)generate the Xcode project
set -euo pipefail
cd "$(dirname "$0")/.."

# 1. Bindings produced by scripts/gen-bindings.sh (committed under bindings/).
mkdir -p apps/ios/Generated
rm -f apps/ios/Generated/*
cp bindings/swift/SuperFilesCore.swift apps/ios/Generated/
cp bindings/swift/SuperFilesCoreFFI.h apps/ios/Generated/
cp bindings/swift/SuperFilesCoreFFI.modulemap apps/ios/Generated/

# 2. Static libraries for device + both simulator architectures.
cargo build --release -p sfiles-ffi --target aarch64-apple-ios
cargo build --release -p sfiles-ffi --target aarch64-apple-ios-sim
cargo build --release -p sfiles-ffi --target x86_64-apple-ios

mkdir -p target/ios-sim target/ios-headers
lipo -create \
    target/aarch64-apple-ios-sim/release/libsuperfiles.a \
    target/x86_64-apple-ios/release/libsuperfiles.a \
    -output target/ios-sim/libsuperfiles.a

cp apps/ios/Generated/SuperFilesCoreFFI.h target/ios-headers/
cp apps/ios/Generated/SuperFilesCoreFFI.modulemap target/ios-headers/module.modulemap

# 3. Package as an xcframework so Xcode picks the right slice per platform.
rm -rf apps/ios/Frameworks/SuperFilesCore.xcframework
mkdir -p apps/ios/Frameworks
xcodebuild -create-xcframework \
    -library target/aarch64-apple-ios/release/libsuperfiles.a \
    -headers target/ios-headers \
    -library target/ios-sim/libsuperfiles.a \
    -headers target/ios-headers \
    -output apps/ios/Frameworks/SuperFilesCore.xcframework

# 4. Generate the Xcode project if XcodeGen is available.
if command -v xcodegen >/dev/null; then
    (cd apps/ios && xcodegen generate)
    echo "Xcode project generated: apps/ios/SuperFilesApp.xcodeproj"
fi

echo "Done. Open apps/ios/SuperFilesApp.xcodeproj (set your signing team first)."
