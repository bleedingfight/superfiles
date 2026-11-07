.PHONY: build test bindings cli check fmt clean

build:
	cargo build

test:
	cargo test

check:
	cargo fmt --all -- --check
	cargo clippy --all-targets -- -D warnings

fmt:
	cargo fmt --all

bindings:
	./scripts/gen-bindings.sh

cli: build
	./target/debug/sfiles --help

android:
	./scripts/build-android.sh

ios:
	./scripts/build-ios.sh

clean:
	cargo clean
	rm -rf apps/ios/Generated apps/ios/Frameworks apps/ios/SuperFilesApp.xcodeproj
