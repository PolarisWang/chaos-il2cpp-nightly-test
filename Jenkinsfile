/*
 * chaos-il2cpp Nightly Multi-Platform Build, Test & Report Pipeline
 *
 * Triggered by:
 *   - cron: every day at 3:00 AM
 *   - manual: with BUILD_CONFIG and BOOMING_REPO parameters
 *
 * Pipeline:
 *   1. linux-x64: Fresh clone → build → 24 DLL full pipeline → SonarQube → Nightly Report
 *   2. linux-arm64: Build + fact verification smoke
 *   3. android-arm64: Build verification
 *   4. Aggregate → Archive → Notify (Feishu + Email)
 */

@Library('chaos-pipelines') _

def BOOMING_DIR   = params.BOOMING_REPO ?: '/booming-il2cpp-nightly'
def BUILD_CONFIG  = params.BUILD_CONFIG ?: 'profile'
def ARTIFACTS_DIR = "${WORKSPACE}/artifacts"
def DATE_TAG      = new Date().format('yyyyMMdd')
def TIMESTAMP     = new Date().format('yyyyMMdd-HHmmss')
def FAILED_PLATFORMS = []

def PLATFORMS = [
    [name: 'linux-x64',     label: 'linux-x64',     preset: 'linux-x64-packaging',   test: true,  benchmark: true,  sonar: true],
    [name: 'linux-arm64',   label: 'linux-arm64',   preset: 'linux-arm64-smoke',      test: true,  benchmark: false, sonar: true],
    [name: 'android-arm64', label: 'android-arm64', preset: 'android-arm64-smoke',     test: false, benchmark: false, sonar: true],
]

pipeline {
    agent none

    triggers {
        cron('H 3 * * *')
    }

    parameters {
        string(name: 'BOOMING_REPO', defaultValue: '/booming-il2cpp-nightly',
               description: 'Path to booming-il2cpp repository (cloned fresh each nightly)')
        choice(name: 'BUILD_CONFIG', choices: ['profile', 'debug', 'ship'],
               description: 'Build configuration tier')
    }

    stages {
        stage('Nightly Pipeline') {
            steps {
                script {
                    currentBuild.displayName = "#${BUILD_NUMBER} (${BUILD_CONFIG})"

                    def result = nightlyPipeline(
                        platforms:    PLATFORMS,
                        artifactsDir: ARTIFACTS_DIR,
                        boomingDir:   BOOMING_DIR,
                        buildConfig:  BUILD_CONFIG,
                        freshClone:   true
                    )

                    if (result?.failedPlatforms) {
                        FAILED_PLATFORMS.addAll(result.failedPlatforms)
                    }
                }
            }
        }

        stage('SonarQube Analysis') {
            parallel PLATFORMS.findAll { p -> p.sonar != false }.collectEntries { p ->
                [p.name, sonarScanPlatform(p, ARTIFACTS_DIR, BOOMING_DIR, BUILD_CONFIG)]
            }
        }

        stage('Generate Allure Report') {
            generateAllureReport(ARTIFACTS_DIR, BOOMING_DIR)
        }

        stage('Archive Nightly Report') {
            agent { label 'linux-x64' }
            steps {
                script {
                    // Find the generated nightly report
                    def reportFile = findFiles(glob: "${ARTIFACTS_DIR}/nightly-report-*.html")
                    if (reportFile) {
                        // Publish the comprehensive nightly HTML report
                        publishHTML(target: [
                            allowMissing: true,
                            alwaysLinkToLastBuild: false,
                            keepAll: true,
                            reportDir: ARTIFACTS_DIR,
                            reportFiles: "nightly-report-*.html",
                            reportName: 'Nightly Comprehensive Report'
                        ])
                    } else {
                        echo "WARNING: Nightly report not found. Check orchestrator output."
                    }

                    // Archive all build artifacts
                    archiveArtifacts artifacts: "artifacts/**/*",
                                   allowEmptyArchive: true,
                                   fingerprint: true
                }
            }
        }
    }

    post {
        success {
            script {
                notification('nightlySummary',
                    buildConfig:     BUILD_CONFIG,
                    failedPlatforms: FAILED_PLATFORMS ?: [],
                    dateTag:         DATE_TAG
                )
            }
        }

        failure {
            script {
                notification('feishu',
                    title:   "❌ Nightly Build #${BUILD_NUMBER} FAILED",
                    message: "Config: ${BUILD_CONFIG}\\nDate: ${DATE_TAG}\\nCheck Jenkins for details.",
                    link:    "${env.BUILD_URL}",
                    color:   "red"
                )
            }
        }

        always {
            cleanWs notFailBuild: true, cleanWhenAborted: true,
                    cleanWhenFailure: true, cleanWhenSuccess: true,
                    cleanWhenUnstable: true
        }
    }
}

// ============================================================
// Helper Functions
// ============================================================

def sonarScanPlatform(platform, artifactsDir, boomingDir, buildConfig) {
    return {
        node(platform.label) {
            try {
                stage("${platform.name}: SonarQube") {
                    sh """
                        bash '${env.WORKSPACE}/scripts/sonar-scan.sh' \
                            --platform '${platform.name}' \
                            --src '${boomingDir}' \
                            --build-config '${buildConfig}' \
                            2>&1 | tee '${artifactsDir}/${platform.name}-sonar.log'
                    """
                }
            } catch (err) {
                echo "${platform.name}: SonarQube scan failed (non-fatal): ${err.message}"
            }
        }
    }
}

def generateAllureReport(artifactsDir, boomingDir) {
    node('linux-x64') {
        script {
            sh """
                bash '${env.WORKSPACE}/scripts/generate-allure.sh' \
                    --input '${artifactsDir}' \
                    --output '${artifactsDir}/allure-report'
            """
            allure(
                includeProperties: false,
                results: [[path: "${artifactsDir}/allure-report"]]
            )
        }
    }
}
