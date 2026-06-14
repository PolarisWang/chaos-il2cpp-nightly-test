#!/bin/bash
# setup.sh — Register a macOS machine as a Jenkins agent
# Run this on the macOS build machine to connect to Jenkins master
# Usage: ./setup.sh [--master-url URL] [--agent-name NAME] [--secret SECRET]

set -euo pipefail

MASTER_URL="${JENKINS_MASTER_URL:-http://chaos-master:8080}"
AGENT_NAME="${JENKINS_AGENT_NAME:-macos-arm64}"
AGENT_SECRET="${JENKINS_AGENT_SECRET:-}"
WORK_DIR="${HOME}/jenkins-agent"
LABELS="${AGENT_LABELS:-macos arm64 native}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --master-url) MASTER_URL="$2"; shift 2 ;;
        --agent-name) AGENT_NAME="$2"; shift 2 ;;
        --secret)     AGENT_SECRET="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

echo "=== Setting up macOS Jenkins Agent ==="
echo "Master: ${MASTER_URL}"
echo "Agent:  ${AGENT_NAME}"

# Install pre-requisites
if command -v brew &>/dev/null; then
    brew install --quiet openjdk cmake ninja 2>/dev/null || true
fi

# Create working directory
mkdir -p "${WORK_DIR}"

# Determine JENKINS_URL for downloading agent.jar
JENKINS_URL="${MASTER_URL}"

# Download agent.jar
AGENT_JAR="${WORK_DIR}/agent.jar"
if [[ ! -f "$AGENT_JAR" ]]; then
    echo "Downloading agent.jar from ${JENKINS_URL}/jnlpJars/agent.jar"
    curl -sSL "${JENKINS_URL}/jnlpJars/agent.jar" -o "$AGENT_JAR"
fi

# Write launch script
LAUNCH_SCRIPT="${WORK_DIR}/launch-agent.sh"
cat > "$LAUNCH_SCRIPT" << SCRIPTEOF
#!/bin/bash
# Launch Jenkins agent (run in tmux/screen or as LaunchDaemon)
cd "${WORK_DIR}"
java -jar agent.jar \\
    -url "${JENKINS_URL}" \\
    -name "${AGENT_NAME}" \\
    -secret "${AGENT_SECRET}" \\
    -workDir "${WORK_DIR}" \\
    -labels "${LABELS}"
SCRIPTEOF
chmod +x "$LAUNCH_SCRIPT"

echo ""
echo "=== Setup Complete ==="
echo "To start the agent manually:"
echo "  ${LAUNCH_SCRIPT}"
echo ""
echo "To register as LaunchDaemon (auto-start on boot):"
echo "  sudo cp ${WORK_DIR}/com.jenkins.agent.plist /Library/LaunchDaemons/"
echo "  sudo launchctl load /Library/LaunchDaemons/com.jenkins.agent.plist"
echo ""
echo "NOTE: Set JENKINS_AGENT_SECRET from Jenkins master → Manage Nodes → ${AGENT_NAME}"
