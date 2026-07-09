#!/usr/bin/env bash
# quickstart.sh — Full setup and 30-minute fuzzing run
#
# Run this on a fresh Ubuntu 22.04 to reproduce the complete experiment:
#   bash scripts/quickstart.sh
#
# Steps performed:
#   1. Install dependencies
#   2. Install AFL++
#   3. Clone and patch n2n
#   4. Build AFL and coverage binaries
#   5. Generate seed corpus
#   6. Run 30-min default fuzzing
#   7. Run 30-min custom mutator fuzzing
#   8. Generate LCOV coverage report

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
step() { echo -e "\n${BOLD}${GREEN}══ $* ══${NC}\n"; }
info() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

# ═══════════════════════════════════════════════════════════════════════════
step "Step 0: Install system dependencies"
# ═══════════════════════════════════════════════════════════════════════════

sudo apt-get update -qq
sudo apt-get install -y \
    git cmake build-essential \
    clang llvm lld \
    libssl-dev \
    tcpdump python3 python3-pip \
    lcov \
    screen

pip3 install scapy --quiet || true

# ═══════════════════════════════════════════════════════════════════════════
step "Step 1: Install AFL++"
# ═══════════════════════════════════════════════════════════════════════════

if ! command -v afl-fuzz &>/dev/null; then
    info "Building AFL++ from source..."
    cd /tmp
    git clone --depth=1 https://github.com/AFLplusplus/AFLplusplus.git afl++
    cd afl++
    make distrib -j"$(nproc)"
    sudo make install
    cd "$REPO_DIR"
    info "AFL++ installed: $(afl-fuzz --version 2>&1 | head -1)"
else
    info "AFL++ already installed: $(afl-fuzz --version 2>&1 | head -1)"
fi

# ═══════════════════════════════════════════════════════════════════════════
step "Step 2: Clone and patch n2n"
# ═══════════════════════════════════════════════════════════════════════════

bash "$SCRIPT_DIR/build_afl.sh"

# ═══════════════════════════════════════════════════════════════════════════
step "Step 3: Build coverage binary"
# ═══════════════════════════════════════════════════════════════════════════

bash "$SCRIPT_DIR/build_cov.sh"

# ═══════════════════════════════════════════════════════════════════════════
step "Step 4: Build custom mutator"
# ═══════════════════════════════════════════════════════════════════════════

make -C "$REPO_DIR/mutator/"

# ═══════════════════════════════════════════════════════════════════════════
step "Step 5: Generate seed corpus"
# ═══════════════════════════════════════════════════════════════════════════

python3 "$SCRIPT_DIR/gen_seeds.py"

# ═══════════════════════════════════════════════════════════════════════════
step "Step 6 & 7: Fuzzing comparison (30 min × 2)"
# ═══════════════════════════════════════════════════════════════════════════

bash "$SCRIPT_DIR/run_fuzzing_custom.sh"

# ═══════════════════════════════════════════════════════════════════════════
step "Step 8: Generate LCOV report"
# ═══════════════════════════════════════════════════════════════════════════

# Use the custom mutator results (higher coverage)
ln -sfn "$REPO_DIR/results/out_custom_30m" "$REPO_DIR/results/out" 2>/dev/null || true
bash "$SCRIPT_DIR/gen_coverage.sh"

echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Experiment complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo ""
echo "  Results:       $REPO_DIR/results/"
echo "  Crashes:       $REPO_DIR/results/out/master/crashes/"
echo "  Coverage HTML: $REPO_DIR/coverage_html/index.html"
echo "  Comparison:    $REPO_DIR/results/comparison_30m.txt"
echo ""
