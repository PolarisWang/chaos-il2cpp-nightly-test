#!/bin/bash
# send-code-review-card.sh — Shell wrapper for code-review-card.py
#
# Invoked by Jenkinsfile's runCodeReview stage (replacing the old inline python
# that was triple-nested in Groovy sh triplequote + the python -c string + shell
# escapes).
#
# Sets the env vars the python script reads (CARD_* prefix for its own params,
# plus standard Jenkins env vars for others), then invokes the script from
# the same location.  Stdout is fully visible in the Jenkins build log as plain
# shell output — no more inline-python echo hiding the card-send result.
#
# Usage:
#   send-code-review-card.sh \
#       --repo-dir    <path>  \
#       --workspace   <path>  \
#       --findings    <path>  \
#       --jenkins-url <url>   \
#       --job         <name>  \
#       --build-num   <num>   \
#       --date-tag    <tag>

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

export CARD_BOOMING_DIR="$REPO_DIR"
export CARD_FINDINGS="$FINDINGS"
export CARD_OUTDIR="/var/lib/report-server/daily"
export JENKINS_EXT_URL="$JENKINS_URL"
export JOB_NAME="$JOB_NAME"
export BUILD_NUMBER="$BUILD_NUM"
export DATE_TAG="$DATE_TAG"
# REVIEW_FROM/REVIEW_TO/REVIEW_PR_* are passed by Jenkins as env vars already
# via the trigger-script (trigger-code-review.sh or trigger-pr-review.sh set
# them in the buildWithParameters call), so they arrive naturally.

exec python3 "$SCRIPT_DIR/code-review-card.py"