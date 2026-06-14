#!/bin/bash
# generate-allure.sh — Merge Allure results from multi-platform test runs
# Usage: generate-allure.sh --input <dir> --output <dir>

set -euo pipefail

INPUT_DIR=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input)  INPUT_DIR="$2";  shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$INPUT_DIR" || -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 --input <dir> --output <dir>"
    exit 1
fi

RESULTS_DIR="${INPUT_DIR}/allure-results"
mkdir -p "$RESULTS_DIR" "$OUTPUT_DIR"

# Collect all allure-result.json files from subdirectories
shopt -s nullglob
for result in "$INPUT_DIR"/**/allure-result.json; do
    cp "$result" "$RESULTS_DIR/"
done

# Check if there are results to process
if ! ls "$RESULTS_DIR"/*.json 1>/dev/null 2>&1; then
    echo "WARNING: No Allure result files found in $INPUT_DIR"
    echo "{}" > "$OUTPUT_DIR/index.html"
    echo "<html><body><h1>No Allure Results</h1></body></html>" > "$OUTPUT_DIR/index.html"
    exit 0
fi

# Generate Allure report
if command -v allure &>/dev/null; then
    allure generate "$RESULTS_DIR" --output "$OUTPUT_DIR" --clean
    echo "Allure report generated at: $OUTPUT_DIR/index.html"
else
    echo "WARNING: allure CLI not found. Copying raw results only."
    cp -r "$RESULTS_DIR" "$OUTPUT_DIR/raw"
fi
