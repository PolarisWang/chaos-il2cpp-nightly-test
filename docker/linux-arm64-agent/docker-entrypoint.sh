#!/bin/bash
set -e

MASTER_URL="${JENKINS_MASTER_URL:-http://chaos-master:8080}"
AGENT_NAME="${JENKINS_AGENT_NAME:-agent}"
AGENT_SECRET="${JENKINS_AGENT_SECRET:-}"
AGENT_LABELS="${AGENT_LABELS:-}"
JENKINS_USER="${JENKINS_ADMIN_ID:-admin}"
JENKINS_PASS="${JENKINS_ADMIN_PASSWORD:-chaos123!}"

echo "Waiting for Jenkins master..."
for i in $(seq 1 60); do
    if curl -fsSL -u "${JENKINS_USER}:${JENKINS_PASS}" \
        "${MASTER_URL}/api/json" -o /dev/null 2>/dev/null; then
        echo "Jenkins ready."
        break
    fi
    if [ "$i" -eq 60 ]; then echo "ERROR: Master unreachable"; exit 1; fi
    sleep 3
done

echo "Downloading agent.jar..."
for i in $(seq 1 10); do
    if curl -fsSL -o /home/jenkins/agent.jar \
        "${MASTER_URL}/jnlpJars/agent.jar" 2>/dev/null; then
        echo "agent.jar ready ($(stat -c%s /home/jenkins/agent.jar) bytes)."
        break
    fi
    sleep 5
done
[ -f /home/jenkins/agent.jar ] || { echo "ERROR: Cannot download agent.jar"; exit 1; }

# Try to get JNLP secret first
if [ -z "${AGENT_SECRET}" ]; then
    echo "Waiting for agent node '${AGENT_NAME}' to be initialized..."
    for i in $(seq 1 30); do
        JNLP_FILE=$(mktemp)
        JNLP_HTTP=$(curl -sSL -u "${JENKINS_USER}:${JENKINS_PASS}" \
            "${MASTER_URL}/computer/${AGENT_NAME}/slave-agent.jnlp" \
            -o "${JNLP_FILE}" -w "%{http_code}" 2>/dev/null || echo "000")

        if [ "${JNLP_HTTP}" = "200" ]; then
            AGENT_SECRET=$(grep -oP '<argument>\K[^<]+' "${JNLP_FILE}" | head -1)
            rm -f "${JNLP_FILE}"
            [ -n "${AGENT_SECRET}" ] && echo "JNLP secret obtained." && break
        fi
        rm -f "${JNLP_FILE}"
        sleep 4
    done
fi

# Connect with secret if available, otherwise use credentials auth
if [ -n "${AGENT_SECRET}" ]; then
    echo "Connecting '${AGENT_NAME}' via JNLP secret..."
    exec java -jar /home/jenkins/agent.jar \
        -url "${MASTER_URL}" \
        -name "${AGENT_NAME}" \
        -secret "${AGENT_SECRET}" \
        -workDir "/home/jenkins"
else
    echo "No JNLP secret found. Trying direct authentication..."
    exec java -jar /home/jenkins/agent.jar \
        -url "${MASTER_URL}" \
        -name "${AGENT_NAME}" \
        -credentials "${JENKINS_USER}:${JENKINS_PASS}" \
        -workDir "/home/jenkins"
fi
