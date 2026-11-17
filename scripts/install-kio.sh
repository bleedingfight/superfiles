#!/usr/bin/env bash
#
# Build + install the KDE integration:
#   1. release `sfiles` CLI  -> ~/.local/bin/sfiles
#   2. kio_superfiles worker -> ~/.local/lib/qt6/plugins/kf6/kio/
#
# After that: restart Dolphin and open `superfiles:///`.
#
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="$HOME/.local"

echo "[1/3] building release sfiles CLI…"
cargo build --release -p sfiles-cli --manifest-path "$repo/Cargo.toml"

mkdir -p "$prefix/bin"
cp -f "$repo/target/release/sfiles" "$prefix/bin/sfiles"
echo "      installed $prefix/bin/sfiles"

echo "[2/3] building KIO worker…"
rm -rf "$repo/target/kio-worker"
cmake -S "$repo/apps/kio-worker" -B "$repo/target/kio-worker" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_INSTALL_LIBDIR=lib >/dev/null
cmake --build "$repo/target/kio-worker" -j"$(nproc)" >/dev/null
cmake --install "$repo/target/kio-worker" >/dev/null
user_so="$prefix/lib/qt6/plugins/kf6/kio/kio_superfiles.so"
echo "      built $user_so"

# KF6 discovers KIO workers ONLY in the compiled-in system plugin dir
# (/usr/lib/qt6/plugins/kf6/kio/) — QT_PLUGIN_PATH is not honored for worker
# discovery. A root copy is the only reliable registration on stock KF6.
worker_dir="/usr/lib/qt6/plugins/kf6/kio"
if cp "$user_so" "$worker_dir/kio_superfiles.so" 2>/dev/null; then
    echo "      installed $worker_dir/kio_superfiles.so"
elif sudo -n cp "$user_so" "$worker_dir/kio_superfiles.so" 2>/dev/null; then
    echo "      installed $worker_dir/kio_superfiles.so (sudo)"
else
    sudo install -m755 "$user_so" "$worker_dir/kio_superfiles.so" \
        || echo "NOTE: run the sudo copy again from an interactive terminal."
fi

echo "[3/3] refreshing service database…"
kbuildsycoca6 --noincremental >/dev/null 2>&1 || kbuildsycoca6 >/dev/null

plugin_dir="$prefix/lib/qt6/plugins"
cat <<EOF

Done.
  - Read-only build: protocol metadata is compiled into the worker plugin;
    after rebuilding just re-run this script to refresh the .so.
  - Open Dolphin and type superfiles:/// in the location bar.
  - Mounts: ~/.config/superfiles/mounts.json (example: apps/kio-worker/mounts.example.json)
EOF
