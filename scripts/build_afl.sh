#!/usr/bin/env bash
# build_afl.sh — Build n2n supernode with AFL++ instrumentation
#
# Prerequisites:
#   - AFL++ installed (afl-clang-fast in PATH)
#   - n2n source cloned to ../n2n/ (relative to this script)
#   - Patches applied: see patches/
#
# Usage:
#   cd n2n-fuzzing/
#   bash scripts/build_afl.sh
#
# Output:
#   n2n/build_afl/supernode   — AFL-instrumented binary

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
N2N_DIR="$REPO_DIR/../n2n"

echo "═══════════════════════════════════════════════════════"
echo "  n2n supernode — AFL++ instrumented build"
echo "═══════════════════════════════════════════════════════"

# ── Preflight checks ────────────────────────────────────────────────────────

check_tool() {
    if ! command -v "$1" &>/dev/null; then
        echo "[ERROR] '$1' not found. Please install AFL++."
        exit 1
    fi
}

check_tool afl-clang-fast
check_tool cmake

echo "[+] AFL++ found: $(afl-clang-fast --version 2>&1 | head -1)"

# ── Clone n2n if not present ────────────────────────────────────────────────

if [ ! -d "$N2N_DIR" ]; then
    echo "[+] Cloning n2n..."
    git clone https://github.com/ntop/n2n.git "$N2N_DIR"
fi

cd "$N2N_DIR"
git checkout 3.0-stable 2>/dev/null || git checkout main

# ── Apply patches ───────────────────────────────────────────────────────────

echo "[+] Applying fuzzing patches..."
for patch in "$REPO_DIR/patches/"*.patch; do
    if git apply --check "$patch" 2>/dev/null; then
        git apply "$patch"
        echo "    Applied: $(basename "$patch")"
    else
        echo "    Skipped (already applied): $(basename "$patch")"
    fi
done

# ── CMake configure ─────────────────────────────────────────────────────────

echo "[+] Configuring with AFL++ clang-fast..."

CC=afl-clang-fast \
CXX=afl-clang-fast++ \
AFL_USE_ASAN=1 \
cmake -B build_afl \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_C_FLAGS="-g -O0 -DAFL_FUZZING" \
    -DAFL_FUZZING_BUILD=ON \
    -DN2N_HAVE_AES=OFF \
    -DN2N_HAVE_OPENSSL=OFF \
    -DBUILD_TESTING=OFF \
    2>&1 | tee "$REPO_DIR/docs/screenshots/cmake_afl_config.log"

# ── Build ───────────────────────────────────────────────────────────────────

echo "[+] Building ($(nproc) cores)..."

cmake --build build_afl -j"$(nproc)" 2>&1 \
    | tee "$REPO_DIR/docs/screenshots/cmake_afl_build.log"

# ── Verify ──────────────────────────────────────────────────────────────────

if [ -f build_afl/supernode ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  [SUCCESS] build_afl/supernode ready"
    echo "  Size: $(du -sh build_afl/supernode | cut -f1)"
    echo "  AFL instrumentation: $(strings build_afl/supernode | grep -c '__afl' || true) references"
    echo "═══════════════════════════════════════════════════════"
else
    echo "[ERROR] Build failed — supernode binary not found"
    exit 1
fi

# ── Set up environment hints ─────────────────────────────────────────────────

echo ""
echo "Next step: bash scripts/run_fuzzing.sh"
