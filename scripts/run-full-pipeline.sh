#!/bin/bash
# run-full-pipeline.sh — Run the full verification pipeline for ALL foundation-dll assemblies
# in parallel batches, collecting fact/benchmark/hotupdate/memory data.
#
# Usage: run-full-pipeline.sh [--stages "build,fact,..."] [--native-config profile] [--batch-size 4]
#                            [--foundation-dir /path/to/testing/foundation-dll] [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ============================================================
# Defaults
# ============================================================
STAGES="build,fact,profile,benchmark,managed_benchmark,benchmark_report,hotupdate,coverage-audit,aggregate"
NATIVE_CONFIG="profile"
BATCH_SIZE=4
FOUNDATION_DIR=""  # auto-detect from booming-il2cpp repo
DRY_RUN=false

# ============================================================
# Parse args
# ============================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stages)         STAGES="$2";         shift 2 ;;
        --native-config)  NATIVE_CONFIG="$2";  shift 2 ;;
        --batch-size)     BATCH_SIZE="$2";     shift 2 ;;
        --foundation-dir) FOUNDATION_DIR="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=true;        shift ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# ============================================================
# Discover foundation-dll directory
# ============================================================
if [[ -z "$FOUNDATION_DIR" ]]; then
    # Search common locations
    for candidate in \
        "${REPO_ROOT}/testing/foundation-dll" \
        "${REPO_ROOT}/../booming-il2cpp/testing/foundation-dll" \
        "/home/debian/agent/booming-il2cpp/testing/foundation-dll"; do
        if [[ -d "$candidate" ]]; then
            FOUNDATION_DIR="$candidate"
            break
        fi
    done
fi

if [[ -z "$FOUNDATION_DIR" || ! -d "$FOUNDATION_DIR" ]]; then
    echo "ERROR: foundation-dll directory not found. Specify with --foundation-dir"
    exit 1
fi

cd "$FOUNDATION_DIR"
echo "=== Foundation-dll directory: ${FOUNDATION_DIR} ==="

# ============================================================
# Discover all DLL assemblies (those that have a chunks/ dir)
# ============================================================
ALL_DLLS=()
for d in "${FOUNDATION_DIR}"/*/; do
    dll_name="$(basename "$d")"
    if [[ -d "${d}/chunks" ]]; then
        ALL_DLLS+=("$dll_name")
    fi
done

TOTAL=${#ALL_DLLS[@]}
echo "=== Discovered ${TOTAL} DLL assemblies ==="
printf '  %s\n' "${ALL_DLLS[@]}"

if [[ "$TOTAL" -eq 0 ]]; then
    echo "ERROR: No DLL assemblies found (no directories with chunks/ subdir)"
    exit 1
fi

# ============================================================
# Run pipeline per DLL in parallel batches
# ============================================================
OVERALL_START=$(date +%s)
PASSED=0
FAILED=0
TIMEOUTS=0
FAILED_DLLS=()
RESULTS_DIR="${FOUNDATION_DIR}/output/nightly-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo ""
echo "============================================"
echo "Starting full pipeline: ${TOTAL} DLLs, batch size ${BATCH_SIZE}"
echo "Stages: ${STAGES}"
echo "Native config: ${NATIVE_CONFIG}"
echo "Output: ${RESULTS_DIR}"
echo "============================================"

for ((i=0; i<TOTAL; i+=BATCH_SIZE)); do
    BATCH_START=$SECONDS
    BATCH=("${ALL_DLLS[@]:i:BATCH_SIZE}")
    BATCH_NUM=$((i / BATCH_SIZE + 1))
    BATCH_TOTAL=$(( (TOTAL + BATCH_SIZE - 1) / BATCH_SIZE ))
    echo ""
    echo "--- Batch ${BATCH_NUM}/${BATCH_TOTAL} ---"

    # Launch parallel processes
    PID_LIST=()
    DLL_LIST=()
    for dll in "${BATCH[@]}"; do
        echo "  Starting: ${dll}"

        if $DRY_RUN; then
            echo "  [DRY-RUN] Would run: python -m verification.chunk_pipeline \\"
            echo "    --assembly \"${dll}\" --all-chunks \\"
            echo "    --stages \"${STAGES}\" --native-config \"${NATIVE_CONFIG}\""
            continue
        fi

        LOG_FILE="${RESULTS_DIR}/${dll}.log"
        python -m verification.chunk_pipeline \
            --assembly "$dll" \
            --all-chunks \
            --stages "$STAGES" \
            --native-config "$NATIVE_CONFIG" \
            > "$LOG_FILE" 2>&1 &
        PID_LIST+=($!)
        DLL_LIST+=("$dll")
    done

    if $DRY_RUN; then
        echo "  [DRY-RUN] Batch complete."
        continue
    fi

    # Wait for all processes in this batch
    for idx in "${!PID_LIST[@]}"; do
        pid="${PID_LIST[$idx]}"
        dll="${DLL_LIST[$idx]}"
        LOG_FILE="${RESULTS_DIR}/${dll}.log"

        # Wait with timeout (7200s per DLL)
        set +e
        wait "$pid" 2>/dev/null
        EXIT_CODE=$?
        set -e

        # Check exit status
        DURATION=$((SECONDS - BATCH_START))
        if [[ $EXIT_CODE -eq 0 ]]; then
            echo "  [PASS] ${dll} (exit=0, ${DURATION}s)"
            PASSED=$((PASSED + 1))
        elif [[ $EXIT_CODE -eq 124 ]]; then
            echo "  [TIMEOUT] ${dll} (exceeded limit)"
            TIMEOUTS=$((TIMEOUTS + 1))
            FAILED_DLLS+=("${dll}")
        else
            echo "  [FAIL] ${dll} (exit=${EXIT_CODE}, ${DURATION}s)"
            FAILED=$((FAILED + 1))
            FAILED_DLLS+=("${dll}")
            # Print last 10 lines of log
            tail -10 "$LOG_FILE" 2>/dev/null | sed 's/^/    /'
        fi
    done

    BATCH_ELAPSED=$((SECONDS - BATCH_START))
    echo "  Batch ${BATCH_NUM} finished in ${BATCH_ELAPSED}s"
done

OVERALL_ELAPSED=$(( $(date +%s) - OVERALL_START ))

# ============================================================
# Write summary
# ============================================================
SUMMARY_FILE="${RESULTS_DIR}/pipeline-summary.json"
cat > "$SUMMARY_FILE" << SUMMARYEOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "total": ${TOTAL},
  "passed": ${PASSED},
  "failed": ${FAILED},
  "timeouts": ${TIMEOUTS},
  "elapsed_seconds": ${OVERALL_ELAPSED},
  "stages": "${STAGES}",
  "native_config": "${NATIVE_CONFIG}",
  "failed_dlls": [$(printf '"%s",' "${FAILED_DLLS[@]}" | sed 's/,$//')],
  "output_dir": "${RESULTS_DIR}"
}
SUMMARYEOF

echo ""
echo "============================================"
echo "  Pipeline Complete"
echo "  Total:  ${TOTAL}"
echo "  Passed: ${PASSED}"
echo "  Failed: ${FAILED}"
echo "  Timeouts: ${TIMEOUTS}"
echo "  Elapsed: $((OVERALL_ELAPSED / 60))m $((OVERALL_ELAPSED % 60))s"
echo "============================================"

if [[ ${#FAILED_DLLS[@]} -gt 0 ]]; then
    echo "Failed DLLs:"
    printf '  - %s\n' "${FAILED_DLLS[@]}"
fi

echo ""
echo "Results: ${RESULTS_DIR}"
echo "Summary: ${SUMMARY_FILE}"
echo ""

exit $((${#FAILED_DLLS[@]} > 0 ? 1 : 0))
