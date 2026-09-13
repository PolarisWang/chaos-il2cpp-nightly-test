#!/bin/bash
# send-code-review-card.sh — findings.json → Notice → Feishu card
#
# Invoked by Jenkinsfile's runCodeReview stage. Builds a Notice via the
# unified feishu/ engine (sources/review.py), then sends via engine.send().
#
# Usage: see --help flags below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

REPO_DIR=""
WORKSPACE=""
FINDINGS=""
JENKINS_URL=""
JOB_NAME=""
BUILD_NUM=""
DATE_TAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-dir)    REPO_DIR="$2";    shift 2 ;;
        --workspace)   WORKSPACE="$2";   shift 2 ;;
        --findings)    FINDINGS="$2";    shift 2 ;;
        --jenkins-url) JENKINS_URL="$2"; shift 2 ;;
        --job)         JOB_NAME="$2";    shift 2 ;;
        --build-num)   BUILD_NUM="$2";   shift 2 ;;
        --date-tag)    DATE_TAG="$2";    shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

BUILD_URL="${JENKINS_URL}/job/${JOB_NAME}/${BUILD_NUM}"

# File SHA for blob links — prefer env, fall back to git HEAD
FILE_SHA="${CARD_FILE_SHA:-}"
if [ -z "$FILE_SHA" ] && [ -n "$REPO_DIR" ]; then
    FILE_SHA=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo "")
fi

exec python3 -c "
import sys, os
sys.path.insert(0, '${SCRIPT_DIR}')

from feishu.sources.review import to_notice
from feishu.engine import send

n = to_notice(
    '${FINDINGS}',
    build_url='${BUILD_URL}',
    date_tag='${DATE_TAG}',
    file_sha='${FILE_SHA}',
    is_pr=os.environ.get('CARD_IS_PR', '') == 'true',
    pr_number=os.environ.get('REVIEW_PR_NUMBER', ''),
    pr_title=os.environ.get('REVIEW_PR_TITLE', ''),
    from_commit=os.environ.get('REVIEW_FROM', ''),
    to_commit=os.environ.get('REVIEW_TO', ''),
    booming_dir='${REPO_DIR}',
    color_override=os.environ.get('CARD_COLOR', ''),
    coverage_done=os.environ.get('REVIEW_COVERAGE_DONE', ''),
    coverage_total=os.environ.get('REVIEW_COVERAGE_TOTAL', ''),
    skipped_files=os.environ.get('REVIEW_SKIPPED_FILES', ''),
)
result = send(n, os.environ.get('FEISHU_WEBHOOK_URL', ''), force=True)
sys.exit(0 if result == 'sent' else 1 if result == 'failed' else 0)
" 2>&1