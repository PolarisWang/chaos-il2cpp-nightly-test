#!/bin/bash
# install-ci-tools.sh — Install SonarScanner and Allure CLI on Debian-based agents
# Usage: install-ci-tools.sh [--allure-version 2.30.0] [--sonar-version 5.0.1.4966]

set -euo pipefail

ALLURE_VERSION="${ALLURE_VERSION:-2.30.0}"
SONAR_VERSION="${SONAR_VERSION:-5.0.1.4966}"

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
    curl -fsSL "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_VERSION}-linux.zip" \
        -o /tmp/sonar-scanner.zip
    unzip -q /tmp/sonar-scanner.zip -d /opt
    ln -sf "/opt/sonar-scanner-${SONAR_VERSION}/bin/sonar-scanner" /usr/local/bin/sonar-scanner
    rm -f /tmp/sonar-scanner.zip
    echo "SonarScanner installed: $(sonar-scanner --version 2>&1 | head -1)"
else
    echo "SonarScanner already installed: $(sonar-scanner --version 2>&1 | head -1)"
fi
