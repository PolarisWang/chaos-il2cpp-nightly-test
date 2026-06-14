#!/bin/bash
# Creates agent nodes via Jenkins REST API
# Called from Jenkins init.groovy after startup

set -e

MASTER_URL="${1:-http://localhost:8080}"
JENKINS_USER="${JENKINS_ADMIN_ID:-admin}"
JENKINS_PASS="${JENKINS_ADMIN_PASSWORD:-chaos123!}"

echo "Waiting for Jenkins to be fully ready..."
for i in $(seq 1 60); do
    if curl -fsSL -u "${JENKINS_USER}:${JENKINS_PASS}" \
        "${MASTER_URL}/api/json" -o /dev/null 2>/dev/null; then
        echo "Jenkins ready."
        break
    fi
    sleep 3
done

COOKIE_JAR=$(mktemp)

create_agent() {
    local name="$1"
    local labels="$2"
    local executors="$3"

    echo "Setting up agent: ${name}..."

    # Get CSRF crumb (use cookie jar to keep session)
    CRUMB=$(curl -s -c "${COOKIE_JAR}" -b "${COOKIE_JAR}" \
        -u "${JENKINS_USER}:${JENKINS_PASS}" \
        "${MASTER_URL}/crumbIssuer/api/xml?xpath=//crumb" | \
        grep -oP "<crumb>\K[^<]+" || echo "")

    if [ -z "${CRUMB}" ]; then
        echo "  WARNING: Could not get CSRF crumb, trying without..."
    fi

    # Check if node exists
    HTTP_CODE=$(curl -s -b "${COOKIE_JAR}" \
        -u "${JENKINS_USER}:${JENKINS_PASS}" \
        -o /dev/null -w "%{http_code}" \
        "${MASTER_URL}/computer/${name}/api/json" 2>/dev/null || echo "000")

    if [ "${HTTP_CODE}" = "200" ]; then
        echo "  Agent '${name}' already exists"
        return 0
    fi

    # Create node via API
    NODE_XML=$(cat <<ENDXML
<slave>
  <name>${name}</name>
  <remoteFS>/home/jenkins</remoteFS>
  <numExecutors>${executors}</numExecutors>
  <mode>NORMAL</mode>
  <retentionStrategy class="hudson.slaves.RetentionStrategy\$Always"/>
  <launcher class="hudson.slaves.JNLPLauncher"/>
  <label>${labels}</label>
  <nodeProperties/>
</slave>
ENDXML
    )

    if [ -n "${CRUMB}" ]; then
        HTTP=$(curl -s -b "${COOKIE_JAR}" \
            -u "${JENKINS_USER}:${JENKINS_PASS}" \
            -H "Content-Type: application/xml" \
            -H "Jenkins-Crumb: ${CRUMB}" \
            -d "${NODE_XML}" \
            -o /dev/null -w "%{http_code}" \
            "${MASTER_URL}/computer/doCreateItem" 2>/dev/null)
    else
        HTTP=$(curl -s -b "${COOKIE_JAR}" \
            -u "${JENKINS_USER}:${JENKINS_PASS}" \
            -H "Content-Type: application/xml" \
            -d "${NODE_XML}" \
            -o /dev/null -w "%{http_code}" \
            "${MASTER_URL}/computer/doCreateItem" 2>/dev/null)
    fi

    if [ "${HTTP}" = "200" ]; then
        echo "  Agent '${name}' created (HTTP ${HTTP})"
    else
        echo "  Agent '${name}' creation returned HTTP ${HTTP}"
    fi
}

create_agent "linux-x64"     "linux x64 native"     2
create_agent "linux-arm64"   "linux arm64 qemu"     1
create_agent "android-arm64" "android arm64 ndk"    1

rm -f "${COOKIE_JAR}"
echo "All agents configured."
