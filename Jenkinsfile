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
                    sh """#!/bin/bash
                        set -euo pipefail
                        mkdir -p "${ARTIFACTS_DIR}"
                        cd "${BOOMING_DIR}/testing/foundation-dll"

                        echo "=== [x64] Full Pipeline \u2014 all DLLs ==="

                        # Iterate over every DLL that has chunks
                        for dll_dir in */; do
                            dll_name=\$(basename "\$dll_dir")
                            [[ -d "\${dll_dir}chunks" ]] || continue

                            echo "========== [x64] Processing \${dll_name} =========="
                            python3 -m verification \
                                --assembly "\${dll_name}" \
                                --all-chunks \
                                --stages build,fact,benchmark,hotupdate,profile,coverage-audit,aggregate,reporting \
                                --native-config "${BUILD_CONFIG}" \
                                2>&1 || echo "WARNING: \${dll_name} pipeline had failures"
                        done

                        echo "=== [x64] Collect Results ==="
                        bash "\${WORKSPACE}/scripts/collect-all-results.sh" \
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
                sh """#!/bin/bash
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
                sh """#!/bin/bash
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
                    steps { script { runSonarScan('linux-x64', BOOMING_DIR, BUILD_CONFIG, ARTIFACTS_DIR) } }
                }
                stage('arm64 SonarQube') {
                    agent { label 'linux-arm64' }
                    steps { script { runSonarScan('linux-arm64', BOOMING_DIR, BUILD_CONFIG, ARTIFACTS_DIR) } }
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

                    sh """#!/bin/bash
                        set -euo pipefail
                        echo "=== Generate Nightly Report ==="
                        python3 "\${WORKSPACE}/scripts/generate-nightly-report.py" \
                            --data "${dataFile}" \
                            ${baselineFlag} \
                            --output "${ARTIFACTS_DIR}/nightly-report-${DATE_TAG}.html" \
                            --build-number "\${BUILD_NUMBER}"

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
                sendNightlyNotification(status: 'FAILURE', artifactsDir: ARTIFACTS_DIR)
            }
        }

        success {
            script {
                sendNightlyNotification(status: 'SUCCESS', artifactsDir: ARTIFACTS_DIR)
            }
        }

        always {
            node('linux-x64') {
                archiveArtifacts artifacts: "artifacts/**/*",
                               allowEmptyArchive: true,
                               fingerprint: true
                cleanWs notFailBuild: true, cleanWhenAborted: true,
                        cleanWhenFailure: true, cleanWhenSuccess: true,
                        cleanWhenUnstable: true
            }
        }
    }
}

// ============================================================
// Helper Functions
// ============================================================

def runSonarScan(platform, boomingDir, buildConfig, artifactsDir) {
    try {
        sh """#!/bin/bash
            set -euo pipefail
            mkdir -p "${artifactsDir}"
            sonar-scanner \
                -D sonar.host.url="${SONAR_HOST_URL}" \
                -D sonar.projectKey=chaos-il2cpp \
                -D sonar.projectName="chaos-il2cpp (${platform})" \
                -D sonar.projectVersion=${BUILD_NUMBER} \
                -D sonar.sources="${boomingDir}" \
                -D sonar.language=cs \
                -D sonar.sourceEncoding=UTF-8 \
                -D sonar.exclusions="**/build/**/*,**/native/build/**/*" \
                2>&1 | tee "${artifactsDir}/${platform}-sonar.log"
        """
    } catch (err) {
        echo "${platform}: SonarQube scan failed (non-fatal): ${err.message}"
    }
}

def sendNightlyNotification(Map params) {
    def status     = params.status ?: 'SUCCESS'
    def artifacts  = params.artifactsDir ?: "${env.WORKSPACE}/artifacts"
    def dataFile   = "${artifacts}/nightly-data-${DATE_TAG}.json"
    def webhook    = env.FEISHU_WEBHOOK_URL

    if (!webhook) {
        echo "FEISHU_WEBHOOK_URL not set, skipping notification"
        return
    }

    def color = status == 'SUCCESS' ? 'green' : 'red'
    def icon  = status == 'SUCCESS' ? '✅' : '❌'
    def title = "${icon} chaos-il2cpp Nightly #${BUILD_NUMBER} — ${DATE_TAG}"

    def reportLink = "${env.BUILD_URL}Nightly_Comprehensive_Report"
    def message = ""

    try {
        // Try Pipeline Utility Steps plugin first; fall back to Python
        def summary = [:]
        def dlls = [:]
        def totalDlls = 0
        def dataDlls = 0

        try {
            def dataStr = sh(script: "cat '${dataFile}' 2>/dev/null || echo '{}'", returnStdout: true).trim()
            def data = readJSON text: dataStr
            summary = data.summary ?: [:]
            dlls = data.dlls ?: [:]
            totalDlls = data.total_dlls ?: dlls.size()
            dataDlls = data.data_dlls ?: 0
        } catch (err) {
            echo "readJSON failed, falling back to Python: ${err.message}"
            def result = sh(script: """python3 -c "
import json, sys
try:
    with open('${dataFile}') as f:
        d = json.load(f)
    s = d.get('summary', {})
    sys.stdout.write(json.dumps({
        'factPassed': s.get('fact_passed', 0),
        'factTotal': s.get('fact_total', 0),
        'bmkMethods': s.get('benchmark_methods', 0),
        'hotPassed': s.get('hotupdate_passed', 0),
        'hotTotal': s.get('hotupdate_total', 0),
        'memMethods': s.get('memory_methods_profiled', 0),
        'memAlloc': s.get('memory_alloc_bytes', 0),
        'memGcPause': s.get('memory_gc_pause_ns', 0),
        'totalDlls': d.get('total_dlls', len(d.get('dlls', {}))),
        'dataDlls': d.get('data_dlls', 0),
        'failedDlls': [k for k, v in d.get('dlls', {}).items()
                       if any(c.get('fact', {}).get('status', '') not in ('passed', '')
                              for c in v.get('chunks', {}).values())],
    }))
except Exception:
    sys.stdout.write('{}')
" 2>/dev/null""", returnStdout: true).trim()
            def parsed = readJSON text: result
            summary.fact_passed  = parsed.factPassed
            summary.fact_total   = parsed.factTotal
            summary.benchmark_methods = parsed.bmkMethods
            summary.hotupdate_passed  = parsed.hotPassed
            summary.hotupdate_total   = parsed.hotTotal
            summary.memory_methods_profiled = parsed.memMethods
            summary.memory_alloc_bytes = parsed.memAlloc
            summary.memory_gc_pause_ns = parsed.memGcPause
            totalDlls = parsed.totalDlls
            dataDlls  = parsed.dataDlls
        }

        def factPassed  = summary.fact_passed         ?: 0
        def factTotal   = summary.fact_total          ?: 0
        def bmkMethods  = summary.benchmark_methods   ?: 0
        def hotPassed   = summary.hotupdate_passed    ?: 0
        def hotTotal    = summary.hotupdate_total     ?: 0
        def memMethods  = summary.memory_methods_profiled ?: 0
        def memAlloc    = summary.memory_alloc_bytes  ?: 0
        def memGcPause  = summary.memory_gc_pause_ns  ?: 0

        def factPct = factTotal > 0 ? String.format("%.1f%%", (double) factPassed / factTotal * 100) : "N/A"
        def hotPct  = hotTotal  > 0 ? String.format("%.1f%%", (double) hotPassed  / hotTotal  * 100) : "N/A"
        def memAllocStr = memAlloc > 0 ? String.format("%.1f MB", memAlloc / (1024 * 1024.0)) : "N/A"
        def memGcStr    = memGcPause > 0 ? String.format("%.1f ms", memGcPause / 1_000_000.0) : "N/A"

        // Count failed DLLs (chunks with fact errors)
        def failedDlls = []
        def dllResults = [:]
        dlls.each { dllName, dllData ->
            def chunkResults = []
            (dllData.chunks ?: [:]).each { slug, chunk ->
                def fact  = chunk.fact ?: [:]
                def bmk   = chunk.benchmark ?: [:]
                def hot   = chunk.hotupdate ?: [:]
                def stages = []
                if (fact.status && fact.status != "passed") { stages.add("fact:${fact.status}") }
                if (bmk.status && bmk.status != "passed")  { stages.add("bmk:${bmk.status}") }
                if (hot.status && hot.status != "passed")  { stages.add("hu:${hot.status}") }
                if (stages) {
                    chunkResults.add("${slug} [${stages.join(', ')}]")
                }
            }
            if (chunkResults) {
                dllResults[dllName] = chunkResults
            }
        }

        def failSummary = ""
        if (dllResults) {
            def failLines = dllResults.collect { k, v -> "${k}: ${v.size()} failed chunk(s)" }
            if (failLines.size() <= 10) {
                failSummary = "\n**失败详情:**\n" + failLines.join("\n")
            } else {
                failSummary = "\n**失败详情:** ${failLines.size()} DLL(s) 有失败"
            }
        }

        message = """**构建配置:** ${BUILD_CONFIG}
**状态:** ${status}

**覆盖范围:** ${dataDlls}/${totalDlls} DLLs 有数据
**正确率 (Fact):** ${factPassed}/${factTotal} (${factPct})
**基准测试:** ${bmkMethods} 方法
**热更新:** ${hotPassed}/${hotTotal} (${hotPct})
**内存 Profile:** ${memMethods} 方法, Nursery=${memAllocStr}, GC=${memGcStr}${failSummary}

🔗 [查看完整报告](${reportLink})
🔗 [Jenkins Build](${env.BUILD_URL})"""
    } catch (err) {
        echo "Failed to read nightly data for notification: ${err.message}"
        message = """**构建配置:** ${BUILD_CONFIG}
**状态:** ${status}

🔗 [Jenkins Build](${env.BUILD_URL})"""
    }

    sh """
        scripts/notify-feishu.sh \\
            --title  '${title}' \\
            --message '${message}' \\
            --link   '${reportLink}' \\
            --color  '${color}'
    """
}
