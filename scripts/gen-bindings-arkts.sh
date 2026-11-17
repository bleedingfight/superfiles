#!/usr/bin/env bash
# Regenerate the HarmonyOS (ArkTS) bindings from the Rust core.
#
# Requires ohos-rs/uniffi-bindgen-arkts, patched for UniFFI 0.32 (upstream
# pins 0.31 and its released CLI cannot read 0.32 metadata):
#
#   git clone https://github.com/ohos-rs/uniffi-bindgen-arkts
#   cd uniffi-bindgen-arkts
#   # 1. Cargo.toml: uniffi / uniffi_bindgen / uniffi_build -> "0.32.2",
#   #    cargo_metadata -> "0.23" (match uniffi_bindgen's own dep)
#   # 2. src/arkts/mod.rs: BindgenLoader::new(paths, GlobalConfig::default())
#   #    (+ import uniffi_bindgen::GlobalConfig)
#   # 3. src/bindings/api/{render,support}.rs: add Type::Box/Type::Set match
#   #    arms (Box recurses into inner_type, Set renders like Sequence)
#   # 4. src/bindings/native_render.rs: FfiType::Float32 -> "f64" in
#   #    render_rust_ffi_napi_type; callback input lets: UInt64 -> u64_to_bigint,
#   #    Float32 -> `as f64` (napi-ohos has no f32 conversions)
#   cargo build --release
#   export UNIFFI_BINDGEN_ARKTS=$PWD/target/release/uniffi-bindgen-arkts
#
# Unlike the swift/kotlin bindings, the ArkTS output also contains a native
# N-API adapter crate (bindings/arkts/native) that must be cross-compiled for
# aarch64-unknown-linux-ohos (see scripts/build-ohos.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="${UNIFFI_BINDGEN_ARKTS:-}"
if [[ -z "$BIN" ]]; then
  BIN="$(command -v uniffi-bindgen-arkts || true)"
fi
if [[ -z "$BIN" ]]; then
  echo "error: uniffi-bindgen-arkts not found (set UNIFFI_BINDGEN_ARKTS)" >&2
  exit 1
fi

cargo build -p sfiles-ffi

LIB="target/debug/libsuperfiles.so"
[[ -f "$LIB" ]] || { echo "error: $LIB not built" >&2; exit 1; }

rm -rf bindings/arkts

# Config (package/module/abi) comes from [bindings.arkts] in uniffi.toml.
"$BIN" generate "$LIB" \
  --manifest-path crates/sfiles-ffi/Cargo.toml \
  --out-dir bindings/arkts \
  --no-stage-library

# --- post-generation patches (reapplied on every regen) --------------------
# 1. The adapter calls UniFFI FFI symbols from the core cdylib; its uniffi
#    version must match the workspace.
sed -i 's/^uniffi = "0.31.0"$/uniffi = "0.32.2"/' bindings/arkts/native/Cargo.toml
# 2. The adapter crate lives inside this repo's cargo workspace tree but must
#    stay a standalone project (own lockfile, OHOS toolchain).
cat >> bindings/arkts/native/Cargo.toml <<'EOF'

# Standalone crate: lives under the super-files workspace tree but must not
# join it (different target/toolchain settings, build.rs-driven linking).
[workspace]
EOF

# 3. HarmonyOS TextEncoder.encodeInto("") returns undefined, so the NAPI
#    adapter throws "Get TypedArray info failed" for empty strings.
python3 - <<'PATCH'
p = "bindings/arkts/src/main/ets/runtime/ffi-converters.ets"
s = open(p).read()
old = '  static lower(value: string): Uint8Array { return new util.TextEncoder().encodeInto(value); }'
new = '''  static lower(value: string): Uint8Array {
    const bytes = new util.TextEncoder().encodeInto(value);
    // HarmonyOS: encodeInto("") returns undefined; NAPI then fails with
    // "Get TypedArray info failed". Always hand it a real typed array.
    return bytes === undefined ? new Uint8Array(0) : bytes;
  }'''
if old in s:
    open(p, "w").write(s.replace(old, new))
PATCH

# 4. The generic `mountCloud` FFI method is newer than the pinned generator
#    patches; re-inject it (no-op if already present).
python3 scripts/patch-arkts-mountcloud.py
python3 scripts/patch-arkts-mounts3.py

echo "ArkTS -> bindings/arkts (native adapter crate included)"
