# Super Files build entry points. `just` alone builds; `just --list` shows this menu.

# compile the debug workspace
build:
    cargo build

# run all workspace tests (live NAS matrix tests are env-gated, see tests/*_live.rs)
test:
    cargo test

# quality gate: formatting + warnings-as-errors lints
check:
    cargo fmt --all -- --check
    cargo clippy --all-targets -- -D warnings

# auto-format everything
fmt:
    cargo fmt --all

# regenerate Swift/Kotlin bindings from the UniFFI exports
bindings:
    ./scripts/gen-bindings.sh

# build + smoke-run the desktop CLI
cli: build
    ./target/debug/sfiles --help

# Rust -> jniLibs for Android (needs SDK 35 + NDK 27, see README)
android:
    ./scripts/build-android.sh

# Linux: build + install the Dolphin KIO worker (superfiles://), see apps/kio-worker
kio:
    ./scripts/install-kio.sh

# Rust -> xcframework + Xcode project (needs macOS)
ios:
    ./scripts/build-ios.sh

# Rust -> OHOS .so files (needs command-line-tools, see apps/ohos/README.md)
ohos:
    ./scripts/build-ohos.sh

# build + sign + install + launch the HarmonyOS app on the attached phone
ohos-run:
    ./scripts/run-ohos.sh

# two-way source sync with macmini:~/super-files (add -n for a dry run)
sync:
    ./scripts/sync-macmini.sh

# cargo clean + drop generated iOS artifacts
clean:
    cargo clean
    rm -rf apps/ios/Generated apps/ios/Frameworks apps/ios/SuperFilesApp.xcodeproj
