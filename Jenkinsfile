/*
 * chaos-il2cpp Nightly Multi-Platform Build & Test Pipeline
 *
 * Triggers: Daily at 3:00 AM (Jenkins cron: H 3 * *)
 * Manual: Can be triggered with BUILD_CONFIG parameter
 *
 * Platform matrix:
 *   linux-x64     — native build + test (Jenkins agent label: linux-x64)
 *   linux-arm64   — cross-compile + QEMU test (Jenkins agent label: linux-arm64)
 *   android-arm64 — NDK cross-compile (Jenkins agent label: android-arm64)
 *   windows-x64   — FUTURE: requires Windows agent
 *   ios-arm64     — FUTURE: requires macOS agent
 */

def BOOMING_DIR = params.BOOMING_REPO ?: '/booming-il2cpp'
def BUILD_CONFIG = params.BUILD_CONFIG ?: 'profile'
def ARTIFACTS_DIR = "${WORKSPACE}/artifacts"
def TIMESTAMP = new Date().format('yyyyMMdd-HHmmss')

def PLATFORMS = [
    [
        name: 'linux-x64',
        label: 'linux-x64',
        preset: 'linux-x64-packaging',
        test: true,
        benchmark: true
    ],
    [
        name: 'linux-arm64',
        label: 'linux-arm64',
        preset: 'linux-arm64-smoke',
        test: true,
        benchmark: false
    ],
    [
        name: 'android-arm64',
        label: 'android-arm64',
        preset: 'android-arm64-smoke',
        test: false,
        benchmark: false
    ]
    // FUTURE:
    // [name: 'windows-x64', label: 'windows-x64', preset: 'windows-x64-reference', ...]
    // [name: 'ios-arm64',   label: 'ios-arm64',   preset: 'ios-arm64-packaging', ...]
]

def FAILED_PLATFORMS = []

pipeline {
    agent none

    triggers {
        // Nightly at 3:00 AM
        cron('H 3 * * *')
    }

    parameters {
        string(name: 'BOOMING_REPO', defaultValue: '/booming-il2cpp',
               description: 'Path to booming-il2cpp repository')
        choice(name: 'BUILD_CONFIG', choices: ['profile', 'debug', 'ship'],
               description: 'Build configuration tier')
    }

    stages {
        stage('Init') {
            agent { label 'linux-x64' }
            steps {
                script {
                    sh """
                        mkdir -p "${ARTIFACTS_DIR}"
                        echo "Build started at: $(date)"
                        echo "Platforms: ${PLATFORMS*.name}"
                        echo "Config: ${BUILD_CONFIG}"
                        echo "Timestamp: ${TIMESTAMP}"
                    """
                }
            }
            post {
                success {
                    script {
                        currentBuild.displayName = "#${BUILD_NUMBER} (${BUILD_CONFIG})"
                    }
                }
            }
        }

        stage('Multi-Platform Build & Test') {
            parallel {
                script {
                    PLATFORMS.each { platform ->
                        "${platform.name}"(platform)
                    }
                }
            }
            post {
                failure {
                    script {
                        echo "Some platforms failed. See summary for details."
                    }
                }
            }
        }

        stage('Report') {
            agent { label 'linux-x64' }
            steps {
                script {
                    def summary = buildSummary()
                    writeFile file: "${ARTIFACTS_DIR}/build-summary.json", text: summary

                    // Generate HTML summary
                    def html = buildHtmlSummary()
                    writeFile file: "${ARTIFACTS_DIR}/build-summary.html", text: html
                }
            }
            post {
                success {
                    // Archive all artifacts
                    archiveArtifacts artifacts: "artifacts/**/*",
                                   allowEmptyArchive: true,
                                   fingerprint: true

                    // Publish HTML report
                    publishHTML(target: [
                        allowMissing: true,
                        alwaysLinkToLastBuild: false,
                        keepAll: true,
                        reportDir: 'artifacts',
                        reportFiles: 'build-summary.html',
                        reportName: 'Nightly Build Summary'
                    ])

                    // Publish JUnit test results
                    junit allowEmptyResults: true,
                          keepLongStdio: true,
                          testResults: "artifacts/**/*-test-report.xml"

                    // Publish performance/benchmark results
                    // (future: integrate with Performance plugin)
                }
            }
        }
    }

    post {
        always {
            script {
                if (FAILED_PLATFORMS) {
                    echo """
                        ========================================
                        NIGHTLY BUILD SUMMARY
                        ========================================
                        Failed platforms: ${FAILED_PLATFORMS.join(', ')}
                        Build: ${currentBuild.result ?: 'SUCCESS'}
                        ========================================
                    """
                }

                // Cleanup workspace
                cleanWs notFailBuild: true, cleanWhenAborted: true,
                        cleanWhenFailure: true, cleanWhenSuccess: true,
                        cleanWhenUnstable: true
            }
        }

        failure {
            // Notify on failure
            script {
                def subject = "[chaos-nightly] Build FAILED: ${BUILD_CONFIG} (${FAILED_PLATFORMS.join(', ')})"
                echo "NOTIFICATION: ${subject}"
                // TODO: Email/Slack/Webhook notification
                // mail to: 'team@example.com', subject: subject, body: "..."
            }
        }

        success {
            script {
                echo "All platforms passed. Build complete."
            }
        }

        unstable {
            script {
                echo "Build unstable. Some tests failed."
            }
        }
    }
}

// ============================================================
// Helper functions
// ============================================================

def call(platform) {
    return {
        node(platform.label) {
            stage("${platform.name}: Configure") {
                script {
                    try {
                        checkout scm

                        // Symlink or clone booming-il2cpp
                        if (!fileExists(BOOMING_DIR)) {
                            dir(BOOMING_DIR) {
                                checkout([
                                    $class: 'GitSCM',
                                    branches: [[name: '*/main']],
                                    userRemoteConfigs: [[url: 'https://github.com/PolarisWang/booming-il2cpp.git']]
                                ])
                            }
                        }

                        sh """
                            cd "${BOOMING_DIR}"
                            cmake --preset "${platform.preset}" \
                                  -DROADMAP0_TOOLCHAIN_VALIDATE_ONLY=OFF \
                                  -DCMAKE_BUILD_TYPE="${BUILD_CONFIG}"
                        """
                    } catch (err) {
                        FAILED_PLATFORMS.add(platform.name)
                        unstable("${platform.name}: Configure failed")
                        throw err
                    }
                }
            }

            stage("${platform.name}: Build") {
                steps {
                    script {
                        try {
                            sh """
                                cd "${BOOMING_DIR}"
                                cmake --build --preset "${platform.preset}" \
                                      --parallel \$(nproc) 2>&1 | tee "${ARTIFACTS_DIR}/${platform.name}-build.log"
                            """
                        } catch (err) {
                            FAILED_PLATFORMS.add(platform.name)
                            unstable("${platform.name}: Build failed")
                            throw err
                        }
                    }
                }
            }

            stage("${platform.name}: Test") {
                when {
                    expression { platform.test }
                }
                steps {
                    script {
                        try {
                            def testDir = "${BOOMING_DIR}/artifacts/presets/${platform.preset}"
                            sh """
                                cd "${BOOMING_DIR}"

                                # Run native test suites if available
                                for suite in native-abi-smoke native-common-test native-runtime-core-test; do
                                    if [ -d "artifacts/\${suite}" ]; then
                                        echo "Running test suite: \${suite}"
                                        # Run with ctest or direct binary execution
                                        if [ -f "artifacts/presets/${platform.preset}/bin/run_\${suite}" ]; then
                                            "artifacts/presets/${platform.preset}/bin/run_\${suite}" \
                                                2>&1 | tee "${ARTIFACTS_DIR}/${platform.name}-\${suite}.log"
                                        elif [ -f "${testDir}/bin/run_\${suite}" ]; then
                                            "${testDir}/bin/run_\${suite}" \
                                                2>&1 | tee "${ARTIFACTS_DIR}/${platform.name}-\${suite}.log"
                                        fi
                                    fi
                                done

                                # Also try ctest
                                if [ -f "${testDir}/CTestTestfile.cmake" ]; then
                                    cd "${testDir}"
                                    ctest --output-on-failure -j\$(nproc) \
                                        2>&1 | tee "${ARTIFACTS_DIR}/${platform.name}-ctest.log"
                                fi
                            """
                        } catch (err) {
                            FAILED_PLATFORMS.add(platform.name)
                            unstable("${platform.name}: Tests failed")
                        }
                    }
                }
            }

            stage("${platform.name}: Benchmark") {
                when {
                    expression { platform.benchmark }
                }
                steps {
                    script {
                        try {
                            sh """
                                cd "${BOOMING_DIR}"

                                # Run managed benchmarks if available
                                if [ -d "artifacts/managed_bench" ]; then
                                    # Process benchmark results
                                    if [ -f "benchmark-full-report.json" ]; then
                                        cp benchmark-full-report.json \
                                           "${ARTIFACTS_DIR}/${platform.name}-benchmark.json"
                                    fi
                                fi
                            """
                        } catch (err) {
                            echo "${platform.name}: Benchmark step encountered issues (non-fatal)"
                        }
                    }
                }
            }

            post {
                always {
                    script {
                        // Collect preset artifacts
                        sh """
                            mkdir -p "${ARTIFACTS_DIR}/${platform.name}"
                            if [ -d "${BOOMING_DIR}/artifacts/presets/${platform.preset}" ]; then
                                cp -r "${BOOMING_DIR}/artifacts/presets/${platform.preset}/bin" \
                                   "${ARTIFACTS_DIR}/${platform.name}/" 2>/dev/null || true
                                # Copy test reports
                                find "${BOOMING_DIR}/artifacts" -name "*.xml" \
                                    -exec cp {} "${ARTIFACTS_DIR}/" \\; 2>/dev/null || true
                            fi
                        """
                    }
                }
            }
        }
    }
}

def buildSummary() {
    def summary = [
        buildNumber: BUILD_NUMBER,
        timestamp: TIMESTAMP,
        config: BUILD_CONFIG,
        result: currentBuild.result ?: 'SUCCESS',
        platforms: PLATFORMS.collect { p -> [
            name: p.name,
            status: (p.name in FAILED_PLATFORMS) ? 'FAILED' : 'PASSED'
        ]}
    ]
    return groovy.json.JsonOutput.toJson(summary)
}

def buildHtmlSummary() {
    def rows = PLATFORMS.collect { p ->
        def status = (p.name in FAILED_PLATFORMS) ? '❌ FAILED' : '✅ PASSED'
        def testInfo = p.test ? "Yes" : "N/A"
        def benchInfo = p.benchmark ? "Yes" : "N/A"
        """
        <tr>
            <td>${p.name}</td>
            <td>${status}</td>
            <td>${testInfo}</td>
            <td>${benchInfo}</td>
            <td><a href="${p.name}-build.log">build.log</a></td>
        </tr>
        """
    }.join('\n')

    return """
    <!DOCTYPE html>
    <html>
    <head>
        <title>Nightly Build #${BUILD_NUMBER}</title>
        <style>
            body { font-family: monospace; margin: 20px; }
            h1 { color: #333; }
            .pass { color: green; }
            .fail { color: red; }
            table { border-collapse: collapse; width: 100%; }
            th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
            th { background-color: #f5f5f5; }
        </style>
    </head>
    <body>
        <h1>chaos-il2cpp Nightly Build #${BUILD_NUMBER}</h1>
        <p>Config: <strong>${BUILD_CONFIG}</strong> | Date: ${TIMESTAMP}</p>
        <table>
            <tr><th>Platform</th><th>Status</th><th>Tests</th><th>Benchmark</th><th>Logs</th></tr>
            ${rows}
        </table>
    </body>
    </html>
    """
}
