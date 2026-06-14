#!/bin/bash
# sonar-scan.sh — SonarScanner wrapper with multi-platform support
# Usage: sonar-scan.sh --platform <name> --src <dir> [--build-config <config>]

set -euo pipefail

PLATFORM=""
SRC_DIR=""
BUILD_CONFIG="profile"
SONAR_HOST="${SONAR_HOST_URL:-http://sonarqube:9000}"
SONAR_TOKEN="${SONAR_TOKEN:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)     PLATFORM="$2";     shift 2 ;;
        --src)          SRC_DIR="$2";      shift 2 ;;
        --build-config) BUILD_CONFIG="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [[ -z "$PLATFORM" || -z "$SRC_DIR" ]]; then
    echo "Usage: $0 --platform <name> --src <dir> [--build-config <config>]"
    exit 1
fi

PROJECT_KEY="chaos-il2cpp"

SONAR_ARGS=(
    "-Dsonar.projectKey=${PROJECT_KEY}"
    "-Dsonar.sources=${SRC_DIR}"
    "-Dsonar.host.url=${SONAR_HOST}"
    "-Dsonar.projectVersion=${BUILD_CONFIG}"
    "-Dsonar.cfamily.build-wrapper-output=${SRC_DIR}/bw-output"
    "-Dsonar.sourceEncoding=UTF-8"
)

if [[ -n "$SONAR_TOKEN" ]]; then
    SONAR_ARGS+=("-Dsonar.login=${SONAR_TOKEN}")
fi

# Platform-specific overrides
case "$PLATFORM" in
    linux-x64)
        SONAR_ARGS+=("-Dsonar.projectBaseDir=${SRC_DIR}")
        ;;
    linux-arm64)
        SONAR_ARGS+=("-Dsonar.projectBaseDir=${SRC_DIR}")
        ;;
    android-arm64)
        SONAR_ARGS+=(
            "-Dsonar.projectBaseDir=${SRC_DIR}"
            "-Dsonar.exclusions=**/android/**/*.java"
        )
        ;;
    *)
        echo "Unknown platform: $PLATFORM"
        exit 1
        ;;
esac

echo "=== SonarScanner for ${PLATFORM} ==="
echo "Host: ${SONAR_HOST}"
echo "Project: ${PROJECT_KEY}"

if command -v sonar-scanner &>/dev/null; then
    sonar-scanner "${SONAR_ARGS[@]}"
    echo "SonarQube scan complete for ${PLATFORM}"
else
    echo "WARNING: sonar-scanner CLI not found. Simulating scan."
    cat > "${SRC_DIR}/sonar-report-${PLATFORM}.json" <<-EOF
{
  "projectKey": "${PROJECT_KEY}",
  "platform": "${PLATFORM}",
  "status": "simulated",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
fi
