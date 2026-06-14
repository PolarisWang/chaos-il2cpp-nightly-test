/*
 * chaos-il2cpp Nightly Multi-Platform Build & Test Pipeline
 *
 * References:
 *   @Library('chaos-pipelines') — shared library in pipelines/vars/
 *
 * Triggered by:
 *   - cron: every day at 3:00 AM (nightly)
 *   - manual: with BUILD_CONFIG parameter
 *
 * Pipeline stages:
 *   Compile → Test (Allure) → SonarQube Scan → Aggregate Report → Notify
 */

@Library('chaos-pipelines') _

def BOOMING_DIR  = params.BOOMING_REPO ?: '/booming-il2cpp'
def BUILD_CONFIG = params.BUILD_CONFIG ?: 'profile'
def ARTIFACTS_DIR = "${WORKSPACE}/artifacts"
def TIMESTAMP     = new Date().format('yyyyMMdd-HHmmss')

def PLATFORMS = [
    [name: 'linux-x64',     label: 'linux-x64',     preset: 'linux-x64-packaging',      test: true,  benchmark: true,  sonar: true],
    [name: 'linux-arm64',   label: 'linux-arm64',   preset: 'linux-arm64-smoke',         test: true,  benchmark: false, sonar: true],
    [name: 'android-arm64', label: 'android-arm64', preset: 'android-arm64-smoke',        test: false, benchmark: false, sonar: true],
    // FUTURE:
    // [name: 'windows-x64',   label: 'windows-x64',   preset: 'windows-x64-reference',   test: true,  benchmark: true,  sonar: false],
    // [name: 'macos-arm64',   label: 'macos-arm64',   preset: 'macos-arm64-packaging',    test: true,  benchmark: true,  sonar: false],
]

pipeline {
    agent none

    triggers {
        cron('H 3 * * *')          // Nightly at 3:00 AM
    }

    parameters {
        string(name: 'BOOMING_REPO', defaultValue: '/booming-il2cpp',
               description: 'Path to booming-il2cpp repository')
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
                        buildConfig:  BUILD_CONFIG
                    )
                }
            }
        }
    }

    post {
        success {
            script {
                // Publish Allure test report
                allure(
                    includeProperties: false,
                    results: [[path: "${ARTIFACTS_DIR}/allure-report"]]
                )

                // Publish JUnit XMLs
                junit allowEmptyResults: true,
                      keepLongStdio: true,
                      testResults: "${ARTIFACTS_DIR}/**/*-test-report.xml"

                // Publish HTML daily report
                publishHTML(target: [
                    allowMissing: true,
                    alwaysLinkToLastBuild: false,
                    keepAll: true,
                    reportDir: ARTIFACTS_DIR,
                    reportFiles: "daily-report-*.html",
                    reportName: 'Daily Report'
                ])

                // Archive all artifacts
                archiveArtifacts artifacts: "artifacts/**/*",
                               allowEmptyArchive: true,
                               fingerprint: true
            }
        }

        always {
            script {
                // Notify: Feishu + Email
                notification('nightlySummary', buildConfig: BUILD_CONFIG,
                             failedPlatforms: FAILED_PLATFORMS ?: [])
            }
            cleanWs notFailBuild: true, cleanWhenAborted: true,
                    cleanWhenFailure: true, cleanWhenSuccess: true,
                    cleanWhenUnstable: true
        }
    }
}
