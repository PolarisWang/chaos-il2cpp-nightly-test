#!/bin/bash
# nightly-orchestrator.sh — Top-level orchestrator for the chaotic-il2cpp nightly build.
#
# Flow:
#   1. Fresh clone booming-il2cpp repo
#   2. CMake configure + build (full linux-x64 preset)
#   3. Run full pipeline (24 DLLs, parallel batches) — fact + bench + hotupdate + memory
#   4. Collect all results into aggregated JSON
#   5. Generate comprehensive HTML nightly report
#   6. Copy report to report-server volume
#   7. Print summary for Jenkins notification
#
# Usage: nightly-orchestrator.sh [--build-config profile] [--clone-dir /path/to/clone]
#                                [--report-server-dir /path/to/reports]
#                                [--fresh-clone true|false]
#                                [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ============================================================
# Defaults
# ============================================================
BUILD_CONFIG="profile"
CLONE_DIR="/tmp/booming-il2cpp-nightly-$(date +%Y%m%d)"
REPO_URL="https://github.com/PolarisWang/booming-il2cpp.git"
REPO_BRANCH="main"
REPORT_SERVER_DIR="${REPORT_SERVER_DIR:-/var/lib/report-server/daily}"
FRESH_CLONE=true
DRY_RUN=false
BUILD_NUMBER="${BUILD_NUMBER:-0}"

# ============================================================
# Parse args
# ============================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-config)     BUILD_CONFIG="$2";     shift 2 ;;
        --clone-dir)        CLONE_DIR="$2";        shift 2 ;;
        --repo-url)         REPO_URL="$2";         shift 2 ;;
        --branch)           REPO_BRANCH="$2";      shift 2 ;;
        --report-server-dir) REPORT_SERVER_DIR="$2"; shift 2 ;;
        --fresh-clone)      FRESH_CLONE="$2";      shift 2 ;;
        --build-number)     BUILD_NUMBER="$2";     shift 2 ;;
        --dry-run)          DRY_RUN=true;          shift ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

DATE_TAG=$(date +%Y%m%d)
ARTIFACTS_DIR="${CLONE_DIR}/artifacts"
FOUNDATION_DIR="${CLONE_DIR}/testing/foundation-dll"
REPORT_FILE_NAME="nightly-report-${DATE_TAG}.html"
DATA_FILE_NAME="nightly-data-${DATE_TAG}.json"

echo "========================================"
echo "  chaos-il2cpp Nightly Orchestrator"
echo "  Date:    ${DATE_TAG}"
echo "  Config:  ${BUILD_CONFIG}"
echo "  Clone:   ${CLONE_DIR}"
echo "  Build #: ${BUILD_NUMBER}"
echo "========================================"

# ============================================================
# Phase 1: Clone
# ============================================================
phase_clone() {
    echo ""
    echo "=== Phase 1: Clone ==="

    if [[ "$FRESH_CLONE" != "true" ]] && [[ -d "$CLONE_DIR" ]]; then
        echo "Using existing clone (FRESH_CLONE=false): ${CLONE_DIR}"
        cd "$CLONE_DIR"
        git fetch origin "$REPO_BRANCH" --depth=1
        git reset --hard "origin/$REPO_BRANCH"
        return
    fi

    # Remove stale clone if fresh
    if [[ -d "$CLONE_DIR" ]]; then
        echo "Removing previous clone: ${CLONE_DIR}"
        rm -rf "$CLONE_DIR"
    fi

    echo "Cloning ${REPO_URL} (branch: ${REPO_BRANCH})..."
    for attempt in 1 2 3; do
        if git clone --depth=1 --branch "$REPO_BRANCH" "$REPO_URL" "$CLONE_DIR" 2>/dev/null; then
            echo "Clone successful (attempt ${attempt})"
            return 0
        else
            echo "Clone failed (attempt ${attempt}). Retrying..."
            [[ -d "$CLONE_DIR" ]] && rm -rf "$CLONE_DIR"
            sleep 5
        fi
    done

    echo "ERROR: Failed to clone after 3 attempts"
    # Fallback: use cached repo
    if [[ -d "/booming-il2cpp" ]]; then
        echo "FALLBACK: Using cached /booming-il2cpp"
        CLONE_DIR="/booming-il2cpp"
        return 0
    fi
    exit 1
}

# ============================================================
# Phase 2: CMake Configure & Build
# ============================================================
phase_build() {
    echo ""
    echo "=== Phase 2: Build ==="
    cd "$CLONE_DIR"

    mkdir -p "$ARTIFACTS_DIR"

    echo "CMake configure — preset: linux-x64-packaging"
    if $DRY_RUN; then
        echo "  [DRY-RUN] cmake --preset linux-x64-packaging -DCMAKE_BUILD_TYPE=${BUILD_CONFIG}"
        return
    fi

    cmake --preset linux-x64-packaging \
        -DROADMAP0_TOOLCHAIN_VALIDATE_ONLY=OFF \
        -DCMAKE_BUILD_TYPE="${BUILD_CONFIG}" \
        2>&1 | tee "${ARTIFACTS_DIR}/cmake-configure.log"

    echo "CMake build — parallel $(nproc)"
    cmake --build --preset linux-x64-packaging \
        --parallel "$(nproc)" \
        2>&1 | tee "${ARTIFACTS_DIR}/cmake-build.log"

    echo "Build complete."
}

# ============================================================
# Phase 3: Full Pipeline (24 DLLs)
# ============================================================
phase_pipeline() {
    echo ""
    echo "=== Phase 3: Foundation-DLL Pipeline ==="

    if $DRY_RUN; then
        echo "  [DRY-RUN] run-full-pipeline.sh --foundation-dir ${FOUNDATION_DIR} --native-config ${BUILD_CONFIG}"
        return
    fi

    # Run from the nightly test repo's scripts
    PIPELINE_SCRIPT="${REPO_ROOT}/scripts/run-full-pipeline.sh"
    if [[ ! -f "$PIPELINE_SCRIPT" ]]; then
        echo "ERROR: Pipeline script not found: ${PIPELINE_SCRIPT}"
        exit 1
    fi

    bash "$PIPELINE_SCRIPT" \
        --foundation-dir "$FOUNDATION_DIR" \
        --native-config "$BUILD_CONFIG" \
        --batch-size 4

    echo "Pipeline complete."
}

# ============================================================
# Phase 4: Collect All Results
# ============================================================
phase_collect() {
    echo ""
    echo "=== Phase 4: Collect Results ==="

    if $DRY_RUN; then
        echo "  [DRY-RUN] collect-all-results.sh --foundation-dir ${FOUNDATION_DIR} --output-dir ${ARTIFACTS_DIR}"
        return
    fi

    COLLECT_SCRIPT="${REPO_ROOT}/scripts/collect-all-results.sh"
    bash "$COLLECT_SCRIPT" \
        --foundation-dir "$FOUNDATION_DIR" \
        --output-dir "$ARTIFACTS_DIR"

    echo "Collection complete."
}

# ============================================================
# Phase 5: Generate Report (with baseline regression comparison)
# ============================================================
phase_report() {
    echo ""
    echo "=== Phase 5: Generate Report ==="

    DATA_FILE="${ARTIFACTS_DIR}/${DATA_FILE_NAME}"
    if [[ ! -f "$DATA_FILE" ]]; then
        echo "WARNING: Data file not found: ${DATA_FILE}"
        echo "Skipping report generation."
        return
    fi

    # Auto-discover the previous night's data for benchmark regression comparison
    BASELINE=""
    PREV_DATE=$(date -d 'yesterday' '+%Y%m%d' 2>/dev/null || echo "")
    if [[ -n "$PREV_DATE" ]]; then
        PREV_DATA="${ARTIFACTS_DIR}/nightly-data-${PREV_DATE}.json"
        if [[ -f "$PREV_DATA" ]]; then
            BASELINE="$PREV_DATA"
            echo "Baseline found: ${PREV_DATA}"
        else
            # Also search in report-server
            for dir in "${REPORT_SERVER_DIR}" "${ARTIFACTS_DIR}"; do
                FOUND=$(ls -t "${dir}"/nightly-data-*.json 2>/dev/null | head -1)
                if [[ -n "$FOUND" && "$FOUND" != "$DATA_FILE" ]]; then
                    BASELINE="$FOUND"
                    echo "Baseline found (auto): ${BASELINE}"
                    break
                fi
            done
        fi
    fi

    if $DRY_RUN; then
        echo "  [DRY-RUN] generate-nightly-report.py --data ${DATA_FILE} --build-number ${BUILD_NUMBER} ${BASELINE:+--baseline $BASELINE}"
        return
    fi

    REPORT_SCRIPT="${REPO_ROOT}/scripts/generate-nightly-report.py"
    python3 "$REPORT_SCRIPT" \
        --data "$DATA_FILE" \
        ${BASELINE:+--baseline "$BASELINE"} \
        --output "${ARTIFACTS_DIR}/${REPORT_FILE_NAME}" \
        --build-number "$BUILD_NUMBER"

    echo "Report generated: ${ARTIFACTS_DIR}/${REPORT_FILE_NAME}"
}

# ============================================================
# Phase 6: Upload to Report Server
# ============================================================
phase_upload() {
    echo ""
    echo "=== Phase 6: Upload to Report Server ==="

    REPORT_FILE="${ARTIFACTS_DIR}/${REPORT_FILE_NAME}"
    if [[ ! -f "$REPORT_FILE" ]]; then
        echo "WARNING: Report not found, skipping upload."
        return
    fi

    if $DRY_RUN; then
        echo "  [DRY-RUN] cp ${REPORT_FILE} ${REPORT_SERVER_DIR}/"
        return
    fi

    mkdir -p "$REPORT_SERVER_DIR"
    cp "$REPORT_FILE" "${REPORT_SERVER_DIR}/"
    cp "$DATA_FILE" "${REPORT_SERVER_DIR}/"

    # Also symlink as latest
    ln -sf "${REPORT_FILE_NAME}" "${REPORT_SERVER_DIR}/nightly-latest.html"
    echo "Uploaded to ${REPORT_SERVER_DIR}/"
}

# ============================================================
# Phase 7: Print Summary
# ============================================================
phase_summary() {
    echo ""
    echo "=== Phase 7: Summary ==="

    DATA_FILE="${ARTIFACTS_DIR}/${DATA_FILE_NAME}"
    REPORT_FILE="${ARTIFACTS_DIR}/${REPORT_FILE_NAME}"

    if [[ -f "$DATA_FILE" ]]; then
        echo "Data: ${DATA_FILE}"
        python3 -c "
import json
with open('${DATA_FILE}') as f:
    d = json.load(f)
s = d.get('summary', {})
fact_pct = (s.get('fact_passed',0)/s.get('fact_total',1)*100) if s.get('fact_total',0) > 0 else 0
print(f'  DLLs:       {d.get(\"total_dlls\",0)}')
print(f'  Fact:       {s.get(\"fact_passed\",0)}/{s.get(\"fact_total\",0)} ({fact_pct:.1f}%)')
print(f'  Benchmark:  {s.get(\"benchmark_methods\",0)} methods')
print(f'  HotUpdate:  {s.get(\"hotupdate_passed\",0)}/{s.get(\"hotupdate_total\",0)}')
print(f'  Memory:     {s.get(\"memory_methods_profiled\",0)} methods profiled')
"
    fi

    if [[ -f "$REPORT_FILE" ]]; then
        REPORT_SIZE=$(stat -c%s "$REPORT_FILE" 2>/dev/null || stat -f%z "$REPORT_FILE" 2>/dev/null)
        echo "Report: ${REPORT_FILE} ($(( REPORT_SIZE / 1024 )) KB)"
    fi

    echo ""
    echo "Nightly build #${BUILD_NUMBER} complete."
}

# ============================================================
# Main
# ============================================================
OVERALL_START=$(date +%s)

phase_clone
phase_build
phase_pipeline
phase_collect
phase_report
phase_upload
phase_summary

OVERALL_ELAPSED=$(( $(date +%s) - OVERALL_START ))
echo ""
echo "Total elapsed: $((OVERALL_ELAPSED / 3600))h $(((OVERALL_ELAPSED % 3600) / 60))m $((OVERALL_ELAPSED % 60))s"
