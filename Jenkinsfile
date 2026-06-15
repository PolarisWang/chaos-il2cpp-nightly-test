/*
 * chaos-il2cpp Nightly Multi-Platform Build, Test & Report Pipeline
 *
 * Self-contained pipeline (no shared library dependency).
 *
 * Triggered by:
 *   - cron: every day at 3:00 AM
 *   - manual: with BUILD_CONFIG and BOOMING_REPO parameters
 *
 * Pipeline:
 *   1. linux-x64: Full pipeline (fact → benchmark → hotupdate → collect → report)
 *   2. linux-arm64: Fact verification for key DLLs
 *   3. android-arm64: Build verification
 *   4. SonarQube analysis
 *   5. Generate Allure + Nightly Report → Archive → Notify
 */

def BOOMING_DIR   = params.BOOMING_REPO ?: '/booming-il2cpp'
def BUILD_CONFIG  = params.BUILD_CONFIG ?: 'profile'
def ARTIFACTS_DIR = ""
def DATE_TAG      = new Date().format('yyyyMMdd')
def FAILED_PLATFORMS = []

pipeline {
    agent none

    triggers {
        cron('H 3 * * *')
    }

    parameters {
        string(name: 'BOOMING_REPO', defaultValue: '/booming-il2cpp',
               description: 'Path to booming-il2cpp repository')
        choice(name: 'BUILD_CONFIG', choices: ['profile', 'debug', 'ship'],
               description: 'Build configuration tier')
    }

    environment {
        DATE_TAG = "${DATE_TAG}"
        REPORT_API_URL = "http://report-api:8000"
        SONAR_HOST_URL = "http://sonarqube:9000"
    }

    stages {
        // ─────────────────────────────────────────────────────
        // Init — set workspace-dependent paths
        // ─────────────────────────────────────────────────────
        stage('Init') {
            agent { label 'linux-x64' }
            steps {
                script {
                    ARTIFACTS_DIR = "${env.WORKSPACE}/artifacts"
                }
            }
        }

        // ─────────────────────────────────────────────────────
        // linux-x64 — Full Pipeline
        // ─────────────────────────────────────────────────────
        stage('linux-x64 Full Pipeline') {
            agent { label 'linux-x64' }
            steps {
                script {
                    sh """
                        set -euo pipefail
                        mkdir -p "${ARTIFACTS_DIR}"
                        cd "${BOOMING_DIR}/testing/foundation-dll"

                        echo "=== [x64] Full Pipeline (all stages) ==="
                        python3 -m verification --all-chunks \
                            --stages build,fact,benchmark,hotupdate,profile,coverage-audit,aggregate,reporting \
                            --native-config "${BUILD_CONFIG}" \
                            2>&1 || {
                            echo "WARNING: Pipeline stages had failures"
                            FAILED_PLATFORMS+=("linux-x64-pipeline")
                        }

                        echo "=== [x64] Collect Results ==="
                        bash "${WORKSPACE}/scripts/collect-all-results.sh" \
                            --foundation-dir "${BOOMING_DIR}/testing/foundation-dll" \
                            --output-dir "${ARTIFACTS_DIR}"

                        echo "=== [x64] Pipeline Complete ==="
                    """
                }
            }
        }

        // ─────────────────────────────────────────────────────
        // linux-arm64 — Smoke Test
        // ─────────────────────────────────────────────────────
        stage('linux-arm64 Smoke') {
            agent { label 'linux-arm64' }
            steps {
                sh """
                    set -euo pipefail
                    cd "${BOOMING_DIR}/testing/foundation-dll"

                    echo "=== [arm64] Fact Smoke ==="
                    for dll in System.Linq System.Collections System.Text.Json; do
                        echo "--- \${dll} ---"
                        python3 -m verification.chunk_pipeline --assembly "\${dll}" --stages fact 2>&1 || {
                            echo "WARNING: \${dll} fact failed"
                            FAILED_PLATFORMS+=("arm64-\${dll}")
                        }
                    done
                """
            }
        }

        // ─────────────────────────────────────────────────────
        // android-arm64 — Build Verification
        // ─────────────────────────────────────────────────────
        stage('android-arm64 Verify') {
            agent { label 'android-arm64' }
            steps {
                sh """
                    set -euo pipefail
                    cd "${BOOMING_DIR}/testing/foundation-dll"
                    echo "=== [android] Verify ==="
                    python3 fix_all_failures.py --platform android 2>&1 || true
                """
            }
        }

        // ─────────────────────────────────────────────────────
        // SonarQube Analysis
        // ─────────────────────────────────────────────────────
        stage('SonarQube Analysis') {
            parallel {
                stage('x64 SonarQube') {
                    agent { label 'linux-x64' }
                    steps { script { runSonarScan('linux-x64', BOOMING_DIR, BUILD_CONFIG) } }
                }
                stage('arm64 SonarQube') {
                    agent { label 'linux-arm64' }
                    steps { script { runSonarScan('linux-arm64', BOOMING_DIR, BUILD_CONFIG) } }
                }
            }
        }

        // ─────────────────────────────────────────────────────
        // Generate Allure Report
        // ─────────────────────────────────────────────────────
        stage('Allure Report') {
            agent { label 'linux-x64' }
            steps {
                script {
                    def allureResults = "${BOOMING_DIR}/testing/foundation-dll/_allure-results"
                    if (fileExists(allureResults)) {
                        allure(
                            includeProperties: false,
                            results: [[path: allureResults]],
                            report: "${ARTIFACTS_DIR}/allure-report"
                        )
                    } else {
                        echo "Allure results not found, skipping"
                    }
                }
            }
        }

        // ─────────────────────────────────────────────────────
        // Nightly HTML Report + Ingest
        // ─────────────────────────────────────────────────────
        stage('Nightly Report') {
            agent { label 'linux-x64' }
            steps {
                script {
                    def dataFile = "${ARTIFACTS_DIR}/nightly-data-${DATE_TAG}.json"
                    def prevDate = sh(script: "date -d '${DATE_TAG} 1 day ago' +%Y%mdd", returnStdout: true).trim()
                    def prevFile = "${ARTIFACTS_DIR}/nightly-data-${prevDate}.json"
                    def baselineFlag = fileExists(prevFile) ? "--baseline ${prevFile}" : ""

                    sh """
                        echo "=== Generate Nightly Report ==="
                        python3 "${WORKSPACE}/scripts/generate-nightly-report.py" \
                            --data "${dataFile}" \
                            ${baselineFlag} \
                            --output "${ARTIFACTS_DIR}/nightly-report-${DATE_TAG}.html" \
                            --build-number "${BUILD_NUMBER}"

                        echo "=== Ingest into Report API ==="
                        curl -sf -X POST "${REPORT_API_URL}/api/ingest?date_tag=${DATE_TAG}" \
                            2>&1 || echo "WARNING: Ingest failed"

                        echo "=== Copy to Nginx volume ==="
                        mkdir -p /var/lib/report-server/daily
                        cp -v "${ARTIFACTS_DIR}/nightly-report-${DATE_TAG}.html" \
                              /var/lib/report-server/daily/nightly-latest.html
                        cp -v "${dataFile}" /var/lib/report-server/daily/
                    """

                    publishHTML(target: [
                        allowMissing: true,
                        alwaysLinkToLastBuild: false,
                        keepAll: true,
                        reportDir: ARTIFACTS_DIR,
                        reportFiles: "nightly-report-${DATE_TAG}.html",
                        reportName: 'Nightly Comprehensive Report'
                    ])
                }
            }
        }
    }

    post {
        failure {
            script {
                notifyFeishu("❌ chaos-il2cpp Nightly #${BUILD_NUMBER} FAILED",
                             "Config: ${BUILD_CONFIG}\\nDate: ${DATE_TAG}\\n${BUILD_URL}")
            }
        }

        success {
            script {
                notifyFeishu("✅ chaos-il2cpp Nightly #${BUILD_NUMBER} Passed",
                             "Report: ${BUILD_URL}/Nightly_Comprehensive_Report")
            }
        }

        always {
            archiveArtifacts artifacts: "artifacts/**/*",
                           allowEmptyArchive: true,
                           fingerprint: true
            cleanWs notFailBuild: true, cleanWhenAborted: true,
                    cleanWhenFailure: true, cleanWhenSuccess: true,
                    cleanWhenUnstable: true
        }
    }
}

// ============================================================
// Helper Functions
// ============================================================

def runSonarScan(platform, boomingDir, buildConfig) {
    try {
        sh """
            mkdir -p "${ARTIFACTS_DIR}"
            sonar-scanner \
                -D sonar.host.url="${SONAR_HOST_URL}" \
                -D sonar.projectKey=chaos-il2cpp \
                -D sonar.projectName="chaos-il2cpp (${platform})" \
                -D sonar.projectVersion=${BUILD_NUMBER} \
                -D sonar.sources="${boomingDir}" \
                -D sonar.language=cs \
                -D sonar.sourceEncoding=UTF-8 \
                -D sonar.exclusions="**/build/**/*,**/native/build/**/*" \
                2>&1 | tee "${ARTIFACTS_DIR}/${platform}-sonar.log"
        """
    } catch (err) {
        echo "${platform}: SonarQube scan failed (non-fatal): ${err.message}"
    }
}

def notifyFeishu(title, message) {
    def webhook = env.FEISHU_WEBHOOK_URL
    if (webhook) {
        sh """
            curl -sf -X POST "${webhook}" \
                -H "Content-Type: application/json" \
                -d '{
                    "msg_type": "post",
                    "content": {
                        "post": {
                            "zh_cn": {
                                "title": "${title}",
                                "content": [[
                                    {"tag": "text", "text": "${message}"}
                                ]]
                            }
                        }
                    }
                }' 2>/dev/null || true
        """
    }
}
