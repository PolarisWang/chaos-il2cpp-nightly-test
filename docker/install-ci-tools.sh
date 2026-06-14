#!/bin/bash
# install-ci-tools.sh — Install SonarScanner, Allure CLI, and MinIO client on Debian-based agents
# Usage: install-ci-tools.sh [--allure-version 2.30.0] [--sonar-version 5.0.1.4966]

set -euo pipefail

ALLURE_VERSION="${ALLURE_VERSION:-2.30.0}"
SONAR_VERSION="${SONAR_VERSION:-4.8.0.2856}"

# The binaries.sonarsource.com URL only works for versions <= 4.8.x
# For newer versions, see: https://github.com/SonarSource/sonar-scanner-cli/releases
SONAR_URL="https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_VERSION}-linux.zip"

# Install Allure CLI
if ! command -v allure &>/dev/null; then
    echo "Installing Allure CLI ${ALLURE_VERSION}..."
    curl -fsSL "https://github.com/allure-framework/allure2/releases/download/${ALLURE_VERSION}/allure-${ALLURE_VERSION}.tgz" \
        -o /tmp/allure.tgz
    tar xzf /tmp/allure.tgz -C /opt
    ln -sf "/opt/allure-${ALLURE_VERSION}/bin/allure" /usr/local/bin/allure
    rm -f /tmp/allure.tgz
    echo "Allure CLI installed: $(allure --version)"
else
    echo "Allure CLI already installed: $(allure --version)"
fi

# Install SonarScanner
if ! command -v sonar-scanner &>/dev/null; then
    echo "Installing SonarScanner ${SONAR_VERSION}..."
    curl -fsSL "${SONAR_URL}" \
        -o /tmp/sonar-scanner.zip
    unzip -q /tmp/sonar-scanner.zip -d /opt
    ln -sf "/opt/sonar-scanner-${SONAR_VERSION}/bin/sonar-scanner" /usr/local/bin/sonar-scanner
    rm -f /tmp/sonar-scanner.zip
    echo "SonarScanner installed: $(sonar-scanner --version 2>&1 | head -1)"
else
    echo "SonarScanner already installed: $(sonar-scanner --version 2>&1 | head -1)"
fi

# Install MinIO client (mc)
if ! command -v mc &>/dev/null; then
    echo "Installing MinIO client (mc)..."
    curl -fsSL "https://dl.min.io/client/mc/release/linux-amd64/mc" \
        -o /usr/local/bin/mc
    chmod +x /usr/local/bin/mc
    echo "MinIO client installed: $(mc --version 2>&1 | head -1)"
else
    echo "MinIO client already installed: $(mc --version 2>&1 | head -1)"
fi
