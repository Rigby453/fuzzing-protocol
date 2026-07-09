#!/usr/bin/env bash
# run_fuzzing.sh — Launch AFLNet in parallel (1 master + 3 workers)
#
# Usage:
#   cd n2n-fuzzing/
#   bash scripts/run_fuzzing.sh [duration_minutes]
#
# Default duration: run until killed (Ctrl+C or kill_fuzzing.sh)
#
# Architecture:
#   master  — stateful, state-aware (-E flag), uses response codes
#   worker1 — stateless mutations, different port
#   worker2 — stateless mutations, different port
#   worker3 — stateless mutations, different port

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
N2N_DIR="$REPO_DIR/../n2n"

# ── Configuration ────────────────────────────────────────────────────────────

OUT_DIR="${REPO_DIR}/results/out"
SEEDS_DIR="${REPO_DIR}/seeds"
SUPERNODE="${N2N_DIR}/build_afl/supernode"

BASE_PORT=7654          # master port
TIMEOUT_MS=5000         # per-test-case timeout (ms)
UDP_DELAY_US=10000      # delay between packets (µs) — important for UDP!
DURATION="${1:-}"       # optional: "30m", "1h", etc.

# ── Colour output ────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Preflight checks ─────────────────────────────────────────────────────────

[ -f "$SUPERNODE" ] || error "supernode not found at $SUPERNODE — run build_afl.sh first"
[ -d "$SEEDS_DIR" ] || error "seeds/ directory not found"
[ "$(ls -A "$SEEDS_DIR"/*.raw 2>/dev/null)" ] || error "No .raw seed files in seeds/"

command -v afl-fuzz &>/dev/null || error "afl-fuzz not found in PATH"

info "Starting n2n supernode fuzzing"
info "  Supernode:  $SUPERNODE"
info "  Seeds:      $SEEDS_DIR"
info "  Output:     $OUT_DIR"
info "  Base port:  $BASE_PORT"
[ -n "$DURATION" ] && info "  Duration:   $DURATION"
echo ""

# ── Kernel setup ─────────────────────────────────────────────────────────────

warn "Configuring kernel for AFL..."
echo core | sudo tee /proc/sys/kernel/core_pattern >/dev/null 2>&1 || true
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || \
    warn "Could not set CPU governor (try running as root)"

# ── Output directory ─────────────────────────────────────────────────────────

mkdir -p "$OUT_DIR"

# Kill any leftover processes from a previous run
pkill -f "supernode -l $BASE_PORT" 2>/dev/null || true
for i in 1 2 3; do
    pkill -f "supernode -l $((BASE_PORT + i))" 2>/dev/null || true
done
sleep 1

# ── Build duration flag ──────────────────────────────────────────────────────

DURATION_FLAG=""
if [ -n "$DURATION" ]; then
    DURATION_FLAG="-V $DURATION"
fi

# ── MASTER process ───────────────────────────────────────────────────────────
#
# Key AFLNet flags:
#   -P UDP       protocol = UDP
#   -D 10000     inter-packet delay (µs) — prevents packet loss on loopback
#   -E           enable state-aware fuzzing (reads response codes)
#   -K           send SIGTERM between runs (triggers our sigterm_handler.patch)
#   -q 3         state selection: round-robin over 3 states
#   -s 3         state skip count: skip first 3 states when exploring
#   -R           enable region-level mutations (AFLNet extension)

info "Starting MASTER (port $BASE_PORT)..."

AFL_SKIP_CPUFREQ=1 \
AFL_NO_UI=0 \
afl-fuzz \
    -i "$SEEDS_DIR" \
    -o "$OUT_DIR" \
    -M master \
    -P UDP \
    -D $UDP_DELAY_US \
    -E -K \
    -q 3 -s 3 \
    -t $TIMEOUT_MS \
    $DURATION_FLAG \
    -- "$SUPERNODE" -l $BASE_PORT -f \
    > "$OUT_DIR/master.log" 2>&1 &

MASTER_PID=$!
echo $MASTER_PID > "$OUT_DIR/master.pid"
info "  Master PID: $MASTER_PID"

sleep 5  # Wait for master to initialise before starting workers

# ── WORKER processes ─────────────────────────────────────────────────────────

for i in 1 2 3; do
    PORT=$((BASE_PORT + i))
    info "Starting WORKER$i (port $PORT)..."

    AFL_SKIP_CPUFREQ=1 \
    AFL_NO_UI=1 \
    afl-fuzz \
        -i "$SEEDS_DIR" \
        -o "$OUT_DIR" \
        -S "worker${i}" \
        -P UDP \
        -D $UDP_DELAY_US \
        -E -K \
        -t $TIMEOUT_MS \
        $DURATION_FLAG \
        -- "$SUPERNODE" -l $PORT -f \
        > "$OUT_DIR/worker${i}.log" 2>&1 &

    PID=$!
    echo $PID > "$OUT_DIR/worker${i}.pid"
    info "  Worker$i PID: $PID"
    sleep 2
done

# ── Monitoring ───────────────────────────────────────────────────────────────

echo ""
info "All processes started. Monitor with:"
echo "    watch -n5 afl-whatsup $OUT_DIR"
echo ""
info "To stop all fuzzers:"
echo "    bash scripts/kill_fuzzing.sh"
echo ""
info "Waiting for results... (Ctrl+C to stop watching but keep fuzzing)"

# Live stats loop
if [ -z "$DURATION" ]; then
    echo ""
    echo "Press Ctrl+C to stop monitoring (fuzzing continues in background)"
    sleep infinity
else
    # Wait for master to finish
    wait $MASTER_PID 2>/dev/null || true
    info "Fuzzing complete. Running coverage generation..."
    bash "$SCRIPT_DIR/gen_coverage.sh"
fi
