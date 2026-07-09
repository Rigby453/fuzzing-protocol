#!/usr/bin/env bash
# build_cov.sh — Build n2n supernode with gcov coverage instrumentation
#
# This build is used ONLY for generating LCOV coverage reports.
# Do NOT use this binary for actual fuzzing — use build_afl/supernode instead.
#
# Usage:
#   cd n2n-fuzzing/
#   bash scripts/build_cov.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
N2N_DIR="$REPO_DIR/../n2n"

echo "═══════════════════════════════════════════════════════"
echo "  n2n supernode — gcov coverage build"
echo "═══════════════════════════════════════════════════════"

# ── Preflight ───────────────────────────────────────────────────────────────

for tool in gcc cmake lcov genhtml; do
    if ! command -v "$tool" &>/dev/null; then
        echo "[ERROR] '$tool' not found."
        echo "  Install with: sudo apt-get install $tool"
        exit 1
    fi
done

if [ ! -d "$N2N_DIR" ]; then
    echo "[ERROR] n2n source not found at $N2N_DIR"
    echo "  Run build_afl.sh first."
    exit 1
fi

cd "$N2N_DIR"

# ── CMake configure ─────────────────────────────────────────────────────────

echo "[+] Configuring coverage build..."

CC=gcc \
CXX=g++ \
cmake -B build_cov \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_C_FLAGS="-g -O0 -DAFL_FUZZING --coverage -fprofile-arcs -ftest-coverage" \
    -DCMAKE_EXE_LINKER_FLAGS="--coverage" \
    -DFUZZING_COVERAGE=ON \
    -DN2N_HAVE_AES=OFF \
    -DN2N_HAVE_OPENSSL=OFF \
    -DBUILD_TESTING=OFF \
    2>&1 | tee "$REPO_DIR/docs/screenshots/cmake_cov_config.log"

# ── Build ───────────────────────────────────────────────────────────────────

echo "[+] Building coverage binary..."
cmake --build build_cov -j"$(nproc)" 2>&1 \
    | tee "$REPO_DIR/docs/screenshots/cmake_cov_build.log"

# ── Baseline coverage (zero run) ────────────────────────────────────────────

echo "[+] Generating baseline (zero) coverage..."
lcov \
    --capture \
    --initial \
    --directory build_cov/ \
    --output-file "$REPO_DIR/results/coverage_baseline.info" \
    --rc lcov_branch_coverage=1 \
    2>/dev/null || true

if [ -f build_cov/supernode ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  [SUCCESS] build_cov/supernode ready"
    echo "  Next: bash scripts/run_fuzzing.sh, then scripts/gen_coverage.sh"
    echo "═══════════════════════════════════════════════════════"
fi
