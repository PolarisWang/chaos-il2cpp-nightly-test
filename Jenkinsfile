/*
 * chaos-il2cpp Nightly Multi-Platform Build, Test & Report Pipeline
 *
 * Self-contained pipeline (no shared library dependency).
 * Dispatches to other pipelines (code-review, pr-review, etc.) based on JOB_NAME.
 *
 * Triggered by:
 *   - cron: every day at 3:00 AM and 12:15 PM
 *   - cron: code-review job every 30 minutes (separate job XML)
 *   - manual: with BUILD_CONFIG and BOOMING_REPO parameters
 *
 * Nightly Pipeline:
 *   1. linux-x64: Full pipeline (fact → benchmark → hotupdate → collect → report)
 *   2. linux-arm64: Fact verification for key DLLs
 *   3. android-arm64: Build verification
 *   4. SonarQube analysis
 *   5. Generate Allure + Nightly Report → Archive → Notify
 */

def BOOMING_DIR   = params.BOOMING_REPO ?: '/home/debian/agent/booming-il2cpp'
def BUILD_CONFIG  = params.BUILD_CONFIG ?: 'profile'
def ARTIFACTS_DIR = ""
def DATE_TAG      = new Date().format('yyyyMMdd')
def RUN_TAG       = (new Date().format('HH') as int) < 8 ? 'run1' : 'run2'
def FAILED_PLATFORMS = []

pipeline {
    agent none

    triggers {
        cron('''
            15 4 * * *
            0 19 * * *
        ''')
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timeout(time: 6, unit: 'HOURS')
        skipDefaultCheckout(true)
    }

    parameters {
        string(name: 'BOOMING_REPO', defaultValue: '/home/debian/agent/booming-il2cpp',
               description: 'Path to booming-il2cpp repository')
        choice(name: 'BUILD_CONFIG', choices: ['profile', 'debug', 'ship'],
               description: 'Build configuration tier')
        // PR-review params — set by trigger-pr-review.sh when reviewing a pull request
        // (base..head). Empty = normal main-branch commit review.
        string(name: 'REVIEW_BASE', defaultValue: '', description: 'PR base SHA (base of diff)')
        string(name: 'REVIEW_HEAD', defaultValue: '', description: 'PR head SHA (head of diff)')
        string(name: 'REVIEW_PR_NUMBER', defaultValue: '', description: 'GitHub PR number')
        string(name: 'REVIEW_PR_TITLE', defaultValue: '', description: 'GitHub PR title')
    }

    environment {
        BOOMING_DIR = "${BOOMING_DIR}"
        DATE_TAG = "${DATE_TAG}"
        RUN_TAG  = "${RUN_TAG}"
        REPORT_API_URL = "http://report-api:8000"
        SONAR_HOST_URL = "http://sonarqube:9000"
        FEISHU_WEBHOOK_URL = "https://open.feishu.cn/open-apis/bot/v2/hook/9ba5e264-6486-4ba6-abd3-094bb4d923ff"
    }

    stages {
        // ─────────────────────────────────────────────────────
        // Dispatch — route to the correct pipeline based on job name
        // ─────────────────────────────────────────────────────
        stage('Dispatch') {
            agent { label 'linux-x64-cr' }
            steps {
                script {
                    if (env.JOB_NAME?.contains('code-review')) {
                        // No cron trigger — host trigger-code-review.sh / trigger-pr-review.sh
                        // check and trigger via API, optionally with PR base/head params.
                        // Set DISPATCHED BEFORE running the review: whatever happens (even an
                        // error), the nightly pipeline stages below must never run for a
                        // code-review job. Previously it was set after runCodeReview() returned,
                        // so any review error fell through into the full build + SonarQube.
                        env.DISPATCHED = 'true'
                        try {
                            runCodeReview(
                                repoUrl: '/home/debian/agent/booming-il2cpp',
                                branch: params.BOOMING_BRANCH ?: 'main',
                                prBase:   params.REVIEW_BASE   ?: '',
                                prHead:   params.REVIEW_HEAD   ?: '',
                                prNumber: params.REVIEW_PR_NUMBER ?: '',
                                prTitle:  params.REVIEW_PR_TITLE  ?: ''
                            )
                        } catch (err) {
                            // Review failed — fail the build here, but DO NOT let the error
                            // cascade into the untouched nightly stages. Rethrow so the job
                            // turns red with the actual review cause visible.
                            echo "Code review failed: ${err.message}"
                            throw err
                        }
                    }
                }
            }
        }

        // ─────────────────────────────────────────────────────
        // Init — set workspace-dependent paths
        // ─────────────────────────────────────────────────────
        stage('Init') {
            when { expression { env.DISPATCHED != 'true' } }
            agent { label 'linux-x64' }
            steps {
                script {
                    ARTIFACTS_DIR = "${env.WORKSPACE}/artifacts"
                    // Find dotnet binary and add its directory to pipeline PATH
                    def dotnetDir = sh(script: '''#!/bin/bash
                        set -euo pipefail
                        for c in /usr/local/bin/dotnet /usr/share/dotnet/dotnet /usr/bin/dotnet; do
                            if [ -x "$c" ]; then dirname "$c"; exit 0; fi
                        done
                        echo ""
                    ''', returnStdout: true).trim()
                    if (!dotnetDir) {
                        error("FATAL: dotnet not found — install dotnet SDK 8.0+10.0 on this agent")
                    }
                    env.PATH = "${dotnetDir}:${env.PATH}"
                    sh 'dotnet --version'
                    sh """
                        set -eu
                        mkdir -p "\${WORKSPACE}/scripts"
                        cd "\${WORKSPACE}/scripts"
                        # Download the helper scripts, pinning to this build's own GIT_COMMIT so the
                        # download is consistent (raw.githubusercontent.com's bare 'main' path is
                        # CDN-cached and can serve a STALE script for a while after a push). Fall back
                        # to 'main' if GIT_COMMIT is unset. See the P0-1 note in runCodeReview too.
                        NIGHTLY_SHA="\${GIT_COMMIT:-}"
                        if [ -n "\$NIGHTLY_SHA" ]; then
                            RAWT="https://raw.githubusercontent.com/PolarisWang/chaos-il2cpp-nightly-test/\$NIGHTLY_SHA"
                        else
                            RAWT="https://raw.githubusercontent.com/PolarisWang/chaos-il2cpp-nightly-test/main"
                        fi
                        echo "Downloading nightly scripts from \$RAWT"
                        for script in publish-nightly-results.py generate-nightly-report.py send-feishu.py notify-feishu.sh notify-feishu-text.sh; do
                            # curl can return rc=0 even on a GnuTLS handshake failure (this box's flaky
                            # link to GitHub), so ALWAYS sanity-check the downloaded content rather than
                            # trusting rc alone. A corrupt/empty script would otherwise silently break
                            # publishing under the old || echo WARNING pattern.
                            ok=0
                            for attempt in 1 2 3; do
                                rm -f "\$script"
                                curl -sfL --max-time 60 -o "\$script" "\$RAWT/scripts/\$script" && \\
                                    [ -s "\$script" ] && ok=1 && break
                                echo "download attempt \$attempt/3 failed for \$script (retry)"
                                sleep 2
                            done
                            if [ "\$ok" != "1" ]; then
                                echo "FATAL: failed to download \$script after 3 attempts"
                                exit 1
                            fi
                            # Generic content sanity: it should look like the script type expected.
                            case "\$script" in
                                *.py) grep -q '^#!/usr/bin/env python3' "\$script" || { echo "FATAL: \$script not a valid python script"; exit 1; } ;;
                                *.sh) grep -q '^#!.*sh'            "\$script" || { echo "FATAL: \$script not a valid shell script"; exit 1; } ;;
                            esac
                        done
                        chmod +x *.sh *.py 2>/dev/null || true
                        ls -la
                    """
                }
            }
        }

        // ─────────────────────────────────────────────────────
        // linux-x64 — Full Pipeline
        // ─────────────────────────────────────────────────────
        stage('linux-x64 Full Pipeline') {
            when { expression { env.DISPATCHED != 'true' } }
            agent { label 'linux-x64' }
            steps {
                script {
sh """
                        set -euo pipefail
                        mkdir -p "${ARTIFACTS_DIR}"
                        cd "${BOOMING_DIR}/testing/foundation-dll"

                        echo "=== [x64] Full Pipeline \u2014 nightly_runner (parallel) ==="

                        python3 -m verification.nightly_runner.main \
                            --report-dir "${ARTIFACTS_DIR}/nightly-run" \
                            --max-workers 4 \
                            --bench-workers 2 \
                            --native-config "${BUILD_CONFIG}" \
                            --stage-timeout 600 \
                            2>&1 || echo "WARNING: nightly_runner had failures"

                        echo "=== [x64] Publish Results ==="
                        python3 "\${WORKSPACE}/scripts/publish-nightly-results.py" \
                            --report-dir "${ARTIFACTS_DIR}/nightly-run/latest" \
                            --foundation-dir "${BOOMING_DIR}/testing/foundation-dll" \
                            --output-dir "${ARTIFACTS_DIR}" \
                            --date-tag "${DATE_TAG}" \
                            --run-tag "${RUN_TAG}" \
                            --build-number "\${BUILD_NUMBER}" \
                            --skip-ingest \
                            --skip-minio \
                            2>&1 || echo "WARNING: publish-nightly-results had failures"

                        echo "=== [x64] Pipeline Complete ==="
                    """
                }
            }
        }

        // ─────────────────────────────────────────────────────
        // linux-arm64 — Smoke Test
        // ─────────────────────────────────────────────────────
        stage('linux-arm64 Smoke') {
            when { expression { env.DISPATCHED != 'true' } }
            agent { label 'linux-arm64' }
            steps {
                script {
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
        }

        // ─────────────────────────────────────────────────────
        // android-arm64 — Build Verification
        // ─────────────────────────────────────────────────────
        stage('android-arm64 Verify') {
            when { expression { env.DISPATCHED != 'true' } }
            agent { label 'android-arm64' }
            steps {
                sh '''#!/bin/bash
                    set -euo pipefail
                    cd "${BOOMING_DIR}/testing/foundation-dll"
                    echo "=== [android] Verify ==="
                    python3 fix_all_failures.py --platform android 2>&1 || true
                '''
            }
        }

        // ─────────────────────────────────────────────────────
        // SonarQube Analysis
        // ─────────────────────────────────────────────────────
        stage('SonarQube Analysis') {
            when { expression { env.DISPATCHED != 'true' } }
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
            when { expression { env.DISPATCHED != 'true' } }
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
            when { expression { env.DISPATCHED != 'true' } }
            agent { label 'linux-x64' }
            steps {
                script {
                    def dataFile = "${ARTIFACTS_DIR}/nightly-data-${DATE_TAG}-${RUN_TAG}.json"

                    // Find previous run's data for baseline comparison
                    def prevFile = ""
                    if (RUN_TAG == 'run2') {
                        // Noon run: compare against this morning's run
                        prevFile = "${ARTIFACTS_DIR}/nightly-data-${DATE_TAG}-run1.json"
                    } else {
                        // Morning run: compare against yesterday's last run
                        def yesterday = sh(script: "date -d '${DATE_TAG} 1 day ago' +%Y%mdd", returnStdout: true).trim()
                        prevFile = "${ARTIFACTS_DIR}/nightly-data-${yesterday}-run2.json"
                        if (!fileExists(prevFile)) {
                            prevFile = "${ARTIFACTS_DIR}/nightly-data-${yesterday}-run1.json"
                        }
                    }
                    def baselineFlag = fileExists(prevFile) ? "--baseline ${prevFile}" : ""

                    sh """
                        set -euo pipefail
                        echo "=== Generate Nightly Report ==="
                        python3 "\${WORKSPACE}/scripts/generate-nightly-report.py" \
                            --data "${dataFile}" \
                            ${baselineFlag} \
                            --output "${ARTIFACTS_DIR}/nightly-report-${DATE_TAG}-${RUN_TAG}.html" \
                            --build-number "\${BUILD_NUMBER}"

                        echo "=== Ingest into Report API ==="
                        curl -sf -X POST "${REPORT_API_URL}/api/ingest?date_tag=${DATE_TAG}" \
                            2>&1 || echo "WARNING: Ingest failed"

                        echo "=== Copy to Nginx volume ==="
                        mkdir -p /var/lib/report-server/daily
                        cp -v "${ARTIFACTS_DIR}/nightly-report-${DATE_TAG}-${RUN_TAG}.html" \
                              /var/lib/report-server/daily/nightly-latest.html
                        cp -v "${dataFile}" /var/lib/report-server/daily/
                    """

                    publishHTML(target: [
                        allowMissing: true,
                        alwaysLinkToLastBuild: false,
                        keepAll: true,
                        reportDir: ARTIFACTS_DIR,
                        reportFiles: "nightly-report-${DATE_TAG}-${RUN_TAG}.html",
                        reportName: 'Nightly Comprehensive Report'
                    ])
                }
            }
        }
    }

    post {
        always {
            script {
                def nodeLabel = env.JOB_NAME?.contains('code-review') ? 'linux-x64-cr' : 'linux-x64'
                node(nodeLabel) {
                    // Send notification based on build result (must be inside node for file access)
                    if (env.JOB_NAME?.contains('nightly')) {
                        def buildStatus = currentBuild.result ?: 'SUCCESS'
                        sendNightlyNotification(status: buildStatus, artifactsDir: ARTIFACTS_DIR)
                    }

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
                -D sonar.login="${SONAR_LOGIN:-admin}" \
                -D sonar.password="${SONAR_PASSWORD:-admin}" \
                2>&1 | tee "${artifactsDir}/${platform}-sonar.log"
        """
    } catch (err) {
        echo "${platform}: SonarQube scan failed (non-fatal): ${err.message}"
    }
}

def sendNightlyNotification(Map params) {
    def status     = params.status ?: 'SUCCESS'
    def artifacts  = params.artifactsDir ?: "${env.WORKSPACE}/artifacts"
    def dataFile   = "${artifacts}/nightly-data-${DATE_TAG}-${RUN_TAG}.json"
    def webhook    = env.FEISHU_WEBHOOK_URL

    if (!webhook) {
        echo "FEISHU_WEBHOOK_URL not set, skipping notification"
        return
    }

    // External URLs — hardcoded to internal IP for container-external access
    def JENKINS_EXT_URL = 'http://10.10.1.173:8080'
    def REPORT_EXT_URL  = 'http://10.10.1.173:8081'

    def color = status == 'SUCCESS' ? 'green' : 'red'
    def icon  = status == 'SUCCESS' ? '✅' : '❌'
    def runLabel  = RUN_TAG == 'run2' ? '午后' : '凌晨'
    def title = "${icon} chaos-il2cpp Nightly #${BUILD_NUMBER} — ${DATE_TAG} (${runLabel})"

    def buildLink  = "${JENKINS_EXT_URL}/job/chaos-il2cpp-nightly/${BUILD_NUMBER}"
    def reportLink = "${REPORT_EXT_URL}/?build=${BUILD_NUMBER}&date=${DATE_TAG}"
    def message = ""

    try {
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

        // Collect failed DLL/chunk details
        def dllResults = [:]
        dlls.each { dllName, dllData ->
            def chunkResults = []
            (dllData.chunks ?: [:]).each { slug, chunk ->
                def stages = []
                if (chunk.fact?.status && chunk.fact.status != "passed")        { stages.add("fact:${chunk.fact.status}") }
                if (chunk.benchmark?.status && chunk.benchmark.status != "passed") { stages.add("bmk:${chunk.benchmark.status}") }
                if (chunk.hotupdate?.status && chunk.hotupdate.status != "passed") { stages.add("hu:${chunk.hotupdate.status}") }
                if (stages) {
                    chunkResults.add("${slug} [${stages.join(', ')}]")
                }
            }
            if (chunkResults) {
                dllResults[dllName] = chunkResults
            }
        }

        // Build fail lines (ASCII-safe: DLL names and chunk slugs are ASCII)
        def failLines = ""
        if (dllResults) {
            def lines = dllResults.collect { k, v -> "* ${k}: ${v.size()} failed chunk(s)" }
            failLines = lines.join("||")
            if (lines.size() > 10) {
                failLines = "__MANY__${lines.size()}"
            }
        }

        def dataJson = groovy.json.JsonOutput.toJson([
            status: status,
            color: color,
            build_num: "${BUILD_NUMBER}",
            date_tag: DATE_TAG,
            run_tag: RUN_TAG,
            build_config: BUILD_CONFIG,
            build_link: buildLink,
            report_link: reportLink,
            data_dlls: dataDlls,
            total_dlls: totalDlls,
            fact_passed: factPassed,
            fact_total: factTotal,
            fact_pct: factPct,
            bmk_methods: bmkMethods,
            hot_passed: hotPassed,
            hot_total: hotTotal,
            hot_pct: hotPct,
            mem_methods: memMethods,
            mem_alloc: memAllocStr,
            mem_gc: memGcStr,
            fail_lines: failLines,
        ])
        sendFeishuCard(dataJson, webhook)
    } catch (err) {
        echo "Failed to read nightly data for notification: ${err.message}"
        def dataJson = groovy.json.JsonOutput.toJson([
            status: status,
            color: color,
            build_num: "${BUILD_NUMBER}",
            date_tag: DATE_TAG,
            run_tag: RUN_TAG,
            build_config: BUILD_CONFIG,
            build_link: buildLink,
            report_link: reportLink,
            data_dlls: 0,
            total_dlls: 0,
            fact_passed: 0,
            fact_total: 0,
            fact_pct: "N/A",
            bmk_methods: 0,
            hot_passed: 0,
            hot_total: 0,
            hot_pct: "N/A",
            mem_methods: 0,
            mem_alloc: "N/A",
            mem_gc: "N/A",
            fail_lines: "",
        ])
        sendFeishuCard(dataJson, webhook)
    }
}

def sendFeishuCard(dataJson, webhook) {
    sh "mkdir -p '${WORKSPACE}/.notify'"
    writeFile file: "${WORKSPACE}/.notify/feishu-data.json", text: dataJson
    writeFile file: "${WORKSPACE}/.notify/feishu-webhook.txt", text: webhook
    writeFile file: "${WORKSPACE}/.notify/send-feishu-card.py", text: """#!/usr/bin/env python3
import json, os, sys
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

data_dir = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(data_dir, 'feishu-data.json')) as f:
    data = json.load(f)
with open(os.path.join(data_dir, 'feishu-webhook.txt')) as f:
    webhook_url = f.read().strip()

if not webhook_url:
    print('WARNING: FEISHU_WEBHOOK_URL not set')
    sys.exit(0)

status = data.get('status', 'UNKNOWN')
color = data.get('color', 'green')
build_num = data.get('build_num', '?')
date_tag = data.get('date_tag', '')
run_tag = data.get('run_tag', 'run1')
build_link = data.get('build_link', '')
report_link = data.get('report_link', '')

run_label = '午后' if run_tag == 'run2' else '凌晨'
icon = '✅' if status == 'SUCCESS' else '❌'
title = f'{icon} chaos-il2cpp Nightly #{build_num} — {date_tag} ({run_label})'

parts = [
    f'**构建配置:** {data.get("build_config", "")}',
    f'**状态:** {status}',
    '',
    f'**覆盖范围:** {data.get("data_dlls", 0)}/{data.get("total_dlls", 0)} DLLs',
    f'**正确率:** {data.get("fact_passed", 0)}/{data.get("fact_total", 0)} ({data.get("fact_pct", "N/A")})',
    f'**基准测试:** {data.get("bmk_methods", 0)} 方法',
    f'**热更新:** {data.get("hot_passed", 0)}/{data.get("hot_total", 0)} ({data.get("hot_pct", "N/A")})',
    f'**内存Profile:** {data.get("mem_methods", 0)} 方法',
]
fail_lines = data.get('fail_lines', '')
if fail_lines:
    if fail_lines.startswith('__MANY__'):
        count = fail_lines.replace('__MANY__', '')
        parts.append('')
        parts.append(f'**失败详情:** {count} DLL(s) 有失败')
    else:
        detail = fail_lines.replace('||', chr(10))
        parts.append('')
        parts.append('**失败详情:**')
        parts.append(detail)
message = chr(10).join(parts)

elements = [
    {'tag': 'div', 'text': {'tag': 'lark_md', 'content': message}},
    {'tag': 'hr'},
]
actions = []
if report_link:
    actions.append({
        'tag': 'button', 'text': {'tag': 'plain_text', 'content': '📊 查看报告'},
        'url': report_link, 'type': 'default',
    })
if build_link:
    actions.append({
        'tag': 'button', 'text': {'tag': 'plain_text', 'content': '🔧 Jenkins Build'},
        'url': build_link, 'type': 'default',
    })
if actions:
    elements.append({'tag': 'action', 'actions': actions})
    elements.append({'tag': 'hr'})
elements.append({
    'tag': 'note',
    'elements': [{'tag': 'plain_text', 'content': 'chaos-il2cpp CI'}],
})

payload = json.dumps({
    'msg_type': 'interactive',
    'card': {
        'header': {'title': {'tag': 'plain_text', 'content': title}, 'template': color if color in ('red','blue','green') else 'green'},
        'elements': elements,
    },
}, ensure_ascii=False).encode('utf-8')

req = Request(webhook_url, data=payload, headers={'Content-Type': 'application/json; charset=utf-8'})
try:
    resp = urlopen(req, timeout=30)
    print(f'Feishu notification sent (HTTP {resp.status})')
    resp.close()
except HTTPError as e:
    print(f'WARNING: Feishu webhook returned HTTP {e.code}')
    sys.exit(1)
except URLError as e:
    print(f'WARNING: Feishu webhook error: {e.reason}')
    sys.exit(1)
"""
    def notifyExit = sh(script: "python3 '${WORKSPACE}/.notify/send-feishu-card.py'", returnStatus: true)
    if (notifyExit != 0) {
        echo "WARNING: inline notification failed with exit ${notifyExit}"
    }
}

// ============================================================
// Code Review Pipeline — for chaos-il2cpp-code-review job
// ============================================================

def runCodeReview(Map params = [:]) {
    def repoUrl    = params.repoUrl    ?: '/home/debian/agent/booming-il2cpp'
    def branch     = params.branch     ?: 'main'
    def stateFile  = params.stateFile  ?: '/var/lib/report-server/daily/last-reviewed-commit.json'
    def prStateFile = '/var/lib/report-server/daily/pr-reviewed-head.json'
    def workspaceDir = "${env.WORKSPACE}/code-review"
    def repoCache    = "/home/jenkins/booming-il2cpp-cache"        // Persist across builds
    def boomingDir   = repoCache                                   // Use cached repo
    def findingsFile = "${workspaceDir}/findings.json"
    def SCRIPT_DIR   = "${workspaceDir}/scripts"

    // PR-review mode: when REVIEW_HEAD is set, this build reviews PR base..head and
    // posts a PR-titled card, then records the reviewed head in pr-reviewed-head.json.
    def prBase   = (params.prBase   ?: '').trim()
    def prHead   = (params.prHead   ?: '').trim()
    def prNumber = (params.prNumber ?: '').trim()
    def prTitle  = (params.prTitle  ?: '').trim()
    def isPrReview = prHead != ''
    echo "runCodeReview mode: ${isPrReview ? 'PR #' + prNumber + ' ' + prBase + '..' + prHead : 'main-branch commits'}"

    // NOTE: no node() blocks inside — runCodeReview is already called from
    // inside a node('linux-x64') in the Dispatch stage. Nested node() calls
    // consume extra executors and cause deadlock (zombie executor state).

    stage('Code Review: Check') {
        script {
            // Init
            sh "mkdir -p '${workspaceDir}' '${SCRIPT_DIR}'"
            echo "Code review workspace: ${workspaceDir}"
            sh """
                set -euo pipefail
                mkdir -p '${SCRIPT_DIR}'
                echo "Downloading review scripts from GitHub..."
                # Prefer a pin to this repo's own checked-out SHA (GIT_COMMIT), so the
                # download is consistent: raw.githubusercontent.com's bare 'main' path is
                # CDN-cached and can serve a STALE script for a while after a push (e.g.
                # missing the docs-only review). Fall back to 'main' if GIT_COMMIT is unset.
                NIGHTLY_SHA="\${GIT_COMMIT:-}"
                if [ -n "\$NIGHTLY_SHA" ]; then
                    RAWT="https://raw.githubusercontent.com/PolarisWang/chaos-il2cpp-nightly-test/\$NIGHTLY_SHA"
                else
                    RAWT="https://raw.githubusercontent.com/PolarisWang/chaos-il2cpp-nightly-test/main"
                fi
                echo "Downloading from \$RAWT"
                curl -sL --max-time 30 -o '${SCRIPT_DIR}/review-with-claude.sh' \
                    "\$RAWT/scripts/review-with-claude.sh"
                curl -sL --max-time 30 -o '${SCRIPT_DIR}/notify-feishu-text.sh' \
                    "\$RAWT/scripts/notify-feishu-text.sh"
                curl -sL --max-time 30 -o '${SCRIPT_DIR}/notify-feishu.sh' \
                    "\$RAWT/scripts/notify-feishu.sh"
                chmod +x '${SCRIPT_DIR}/'*.sh
                # Sanity: the review script must carry the docs-reviewable marker (the
                # EXTS_KEEP-with-.md fix that makes the docs path actually run). Without it
                # a docs-only range still falls through to the all-excluded early exit.
                grep -Fq 'DOCS_REVIEWABLE_VERSION_MARKER' '${SCRIPT_DIR}/review-with-claude.sh' || {
                    echo "WARNING: review script lacks docs marker (stale download?); re-pulling from main"
                    curl -sL --max-time 30 -o '${SCRIPT_DIR}/review-with-claude.sh' \
                        'https://raw.githubusercontent.com/PolarisWang/chaos-il2cpp-nightly-test/main/scripts/review-with-claude.sh'
                    chmod +x '${SCRIPT_DIR}/review-with-claude.sh'
                    grep -Fq 'DOCS_REVIEWABLE_VERSION_MARKER' '${SCRIPT_DIR}/review-with-claude.sh' || {
                        echo "ERROR: review script still lacks docs marker after re-pull"
                        exit 1
                    }
                }
                echo "Scripts synced to ${SCRIPT_DIR}"
            """

            // Fetch State
            env.LAST_REVIEWED_COMMIT = ''
            env.REVIEW_SKIPPED = 'false'
            try {
                def stateStr = sh(script: "cat '${stateFile}' 2>/dev/null || echo '{}'", returnStdout: true).trim()
                def state = readJSON text: stateStr
                env.LAST_REVIEWED_COMMIT = state.last_reviewed_commit ?: ''
                echo "Last reviewed commit: ${env.LAST_REVIEWED_COMMIT ?: '(none - first run)'}"
            } catch (err) {
                echo "State file not found or invalid, treating as first run"
            }

            // Quick skip check: compare local HEAD vs last reviewed (main-branch mode only;
            // PR mode keeps its own per-PR head tracking in pr-reviewed-head.json).
            if (!isPrReview && env.LAST_REVIEWED_COMMIT) {
                def localHead = sh(
                    script: "cd '${repoUrl}' && git rev-parse HEAD 2>/dev/null || echo ''",
                    returnStdout: true
                ).trim()
                if (localHead && localHead == env.LAST_REVIEWED_COMMIT) {
                    echo "No new commits — skipping"
                    env.REVIEW_SKIPPED = 'true'
                    currentBuild.result = 'SUCCESS'
                }
            }

            if (env.REVIEW_SKIPPED == 'true') {
                return
            }

            // Checkout — incremental fetch instead of full clone
            sh """
                set -euo pipefail
                if [ -d '${repoCache}/.git' ]; then
                    cd '${repoCache}'
                    git remote set-url origin '${repoUrl}' 2>/dev/null || true
                    git fetch origin '${branch}' 2>&1 || {
                        echo 'WARNING: fetch failed, re-initializing cache'
                        cd / && rm -rf '${repoCache}'
                        git init '${repoCache}'
                        cd '${repoCache}'
                        git remote add origin '${repoUrl}'
                        git fetch origin '${branch}' 2>&1
                    }
                    git checkout FETCH_HEAD 2>&1
                else
                    rm -rf '${repoCache}'
                    git init '${repoCache}'
                    cd '${repoCache}'
                    git remote add origin '${repoUrl}'
                    git fetch origin '${branch}' 2>&1
                    git checkout FETCH_HEAD 2>&1
                fi
            """
            env.CURRENT_COMMIT = sh(
                script: "cd '${boomingDir}' && git rev-parse HEAD",
                returnStdout: true
            ).trim()
            echo "Repo synced @ ${env.CURRENT_COMMIT}"

            // Compute Diff
            def fromCommit
            def toCommit = env.CURRENT_COMMIT
            if (isPrReview) {
                // Pull the PR head + base refs (created as real refs/heads/pr-<N> and
                // refs/heads/pr-<N>-base branches in the shared booming clone by
                // trigger-pr-review.sh) into this cache so review-with-claude.sh can diff
                // base..head. Local-path fetch = no TLS flakiness. Both must be fetched
                // because a fresh cache may not hold the base SHA.
                sh """
                    cd '${boomingDir}'
                    git fetch origin 'refs/heads/pr-${prNumber}:refs/remotes/origin/pr-${prNumber}' 2>/dev/null || true
                    git fetch origin 'refs/heads/pr-${prNumber}-base:refs/remotes/origin/pr-${prNumber}-base' 2>/dev/null || true
                """
                fromCommit = prBase
                toCommit   = prHead
                echo "PR review range: ${fromCommit}..${toCommit} (PR #${prNumber})"
                // Guard: both endpoints must be resolvable in the cache, else fail loudly.
                def ok = sh(returnStatus: true, script: """\
cd '${boomingDir}'
git rev-parse --verify --quiet '${fromCommit}^{commit}' >/dev/null && \\
git rev-parse --verify --quiet '${toCommit}^{commit}' >/dev/null
""")
                if (ok != 0) {
                    error "PR range endpoints not both present locally: ${fromCommit}..${toCommit}"
                }
            } else {
                fromCommit = env.LAST_REVIEWED_COMMIT
                if (!fromCommit) {
                    fromCommit = sh(
                        script: "cd '${boomingDir}' && git rev-list --max-parents=0 HEAD 2>/dev/null || echo ''",
                        returnStdout: true
                    ).trim()
                }
                echo "Diff range: ${fromCommit}..${env.CURRENT_COMMIT}"
            }
            def commitCount = sh(
                script: "cd '${boomingDir}' && git rev-list --count '${fromCommit}'..'${toCommit}' 2>/dev/null || echo '0'",
                returnStdout: true
            ).trim()
            if (commitCount == '0') {
                currentBuild.result = 'SUCCESS'
                echo "No commits in ${fromCommit}..${toCommit} — skipping"
                env.REVIEW_SKIPPED = 'true'
                return
            }
            env.REVIEW_SKIPPED = 'false'
            env.REVIEW_FROM = fromCommit
            env.REVIEW_TO = toCommit
            echo "New commits: ${commitCount}"
        }
    }
    stage('Code Review: Review with Claude') {
        script {
                if (env.REVIEW_SKIPPED != 'false') {
                    echo "Review skipped, no Claude invocation needed"
                    return
                }
                sh """
                    bash '${SCRIPT_DIR}/review-with-claude.sh' \
                        --repo-dir    '${boomingDir}' \
                        --from-commit '${env.REVIEW_FROM}' \
                        --to-commit   '${env.REVIEW_TO}' \
                        --output      '${findingsFile}'
                """

                def summaryStr = ''
                try {
                    summaryStr = sh(
                        script: "python3 -c \"import json; print(json.dumps(json.load(open('${findingsFile}'))['summary']))\" || echo '{\"严重\":0,\"中\":0,\"轻\":0,\"建议\":0,\"total_findings\":0}'",
                        returnStdout: true
                    ).trim()
                } catch (err) {
                    echo "WARNING: findings parsing failed (${err.message}), using defaults"
                    summaryStr = '{"严重":0,"中":0,"轻":0,"建议":0,"total_findings":0}'
                }

                def parsed = readJSON text: summaryStr
                env.FINDINGS_SEV   = (parsed['严重'] ?: 0).toString()
                env.FINDINGS_MED   = (parsed['中'] ?: 0).toString()
                env.FINDINGS_LIGHT = (parsed['轻'] ?: 0).toString()
                env.FINDINGS_ADV   = (parsed['建议'] ?: 0).toString()
                env.FINDINGS_TOTAL = (parsed.total_findings ?: 0).toString()

                // low_confidence / incomplete flags — set by review-with-claude.sh.
                // low_confidence = substantive diff came back 0 findings (model glitch
                // possible) OR some chunks were skipped; incomplete = one or more
                // chunks failed to review entirely (model glitch). Surface both so a
                // partial/unreliable review is never presented as a clean pass or a
                // hard build failure.
                def lowConf = false
                def inComplete = false
                def docsOnly = false
                try {
                    def full = readJSON text: readFile("${findingsFile}").trim()
                    lowConf = (full.low_confidence == true)
                    inComplete = (full.incomplete == true)
                    docsOnly = (full.docs_only == true)
                } catch (err) {
                    lowConf = false
                    inComplete = false
                    docsOnly = false
                }
                // Interpolate as 1/0 (not .toString() "true"/"false") so the flag is a
                // valid Python int literal when spliced into the Feishu card python below
                // — "false" (lowercase) would raise NameError. See commit 2542ba8.
                env.REVIEW_LOW_CONF = lowConf ? '1' : '0'
                env.REVIEW_INCOMPLETE = inComplete ? '1' : '0'
                env.REVIEW_DOCS_ONLY = docsOnly ? '1' : '0'

                echo "Findings: ${env.FINDINGS_SEV} 严重 · ${env.FINDINGS_MED} 中 · ${env.FINDINGS_LIGHT} 轻 · ${env.FINDINGS_ADV} 建议${docsOnly ? " · docs-only" : ""}${lowConf ? " · low-confidence" : ""}${inComplete ? " · INCOMPLETE" : ""}"

                // Feishu notification — same node() block, no @2 workspace mismatch
                def safeInt = { s -> (s != null && s != 'null' && s != '') ? s.toInteger() : 0 }
                def sevCount  = safeInt(env.FINDINGS_SEV)
                def medCount  = safeInt(env.FINDINGS_MED)
                def lightCount = safeInt(env.FINDINGS_LIGHT)
                def advCount  = safeInt(env.FINDINGS_ADV)
                def totalFindings = safeInt(env.FINDINGS_TOTAL)

                def colorTag = sevCount > 0 || medCount > 0 ? 'red' : (lightCount > 0 ? 'blue' : (docsOnly || lowConf || inComplete ? 'orange' : 'green'))
                def riskWord = totalFindings > 0 ? "${totalFindings} 个问题" : "无问题"
                def feishuTitle = isPrReview ? "chaos-il2cpp PR #${prNumber} 代码审查 — ${riskWord}" : "chaos-il2cpp 代码审查 — ${riskWord}"
                def JENKINS_EXT_URL = 'http://10.10.1.173:8080'

                sh """
set -euo pipefail
python3 -c "
import json, os, urllib.request, subprocess


# Extract commits from git log (not findings JSON — Claude may omit them)
booming_dir = '${boomingDir}'
from_commit = '${env.REVIEW_FROM}'
to_commit = '${env.REVIEW_TO}'
is_pr = '${isPrReview}' == 'true'
pr_number = '${prNumber}'
pr_title = '${prTitle}'
# Blob links should point at the PR head's code, not main's CURRENT_COMMIT.
file_sha = '${isPrReview ? prHead : env.CURRENT_COMMIT}'
commits = []
try:
    # Capture the FULL commit message (subject + body), not just %s title.
    # Emit each commit as <sha40> NUL <full-message> NUL (NUL = ASCII 0x00). Splitting
    # on NUL is safe because git forbids NUL bytes inside messages, and %B strips the
    # trailing newline, so parts come out [sha1, msg1, sha2, msg2, ...]. NOTE: this block
    # lives inside a Groovy sh triple-quote string, so NO literal backslash may appear
    # here (Groovy would turn it into an escape and break the build). We use chr(0) /
    # chr(10) / splitlines() instead of backslash escapes on purpose — stable + safe.
    result = subprocess.run(
        ['git', '-C', booming_dir, 'log',
         '--format=%H%x00%B%x00',
         from_commit + '..' + to_commit],
        capture_output=True, timeout=30
    )
    out = result.stdout.decode('utf-8', errors='replace')
    parts = out.split(chr(0))
    i = 0
    n = len(parts)
    while i + 1 < n:
        sha = parts[i].strip()
        full_msg = parts[i + 1].strip()
        i += 2
        if not sha or not full_msg:
            continue
        lines = full_msg.splitlines()
        subject = lines[0].strip() if lines else full_msg
        body_lines = lines[1:]
        # Strip a git TRALER block (Co-Authored-By / Signed-off-by / Reviewed-by, ...).
        # Real git trailers are a trailing run of `Key: value` lines that git parses ONLY
        # because they are separated from the message prose by a blank line. We mirror git:
        #   * walk body_lines from the END;
        #   * collect the contiguous trailing run of `Key: value` lines;
        #   * if that run is empty, or it is NOT preceded by a blank separator, keep everything.
        # This avoids dropping ordinary prose that merely ends in `foo: bar` with no blank above.
        def is_trailer_line(s):
            if ':' not in s:
                return False
            head = s.split(':', 1)[0].strip()
            return bool(head) and all(c.isalnum() or c in '-/_' for c in head)
        trailing = 0
        for ln in reversed(body_lines):
            if is_trailer_line(ln.strip()):
                trailing += 1
            else:
                break
        if trailing > 0:
            j = len(body_lines) - trailing - 1
            separated = (j >= 0 and body_lines[j].strip() == '')   # blank right before the run
            preceded_by_header = (trailing == len(body_lines))      # subject-only + trailers
            if separated or preceded_by_header:
                body_lines = body_lines[:j + 1] if j >= 0 else []
        body = chr(10).join(l.strip() for l in body_lines if l.strip())
        commits.append({'sha': sha, 'subject': subject, 'body': body})
except Exception:
    pass

# Also read findings JSON for finding details
try:
    with open('${findingsFile}') as f:
        d = json.load(f)
except Exception:
    d = {}
flist = d.get('findings', [])

# ── Render commit list (shared between PR mode and main-branch mode) ──
# Priorities substantive commits (those with a body worth explaining); pure
# changelog/chore commits that carry no body are NOT given their own slot (they'd
# crowd out real changes) but are folded into a compact single trailing line. This
# keeps the card readable while making every commit discoverable via its link.
MAX_COMMITS = 5            # max individually-rendered substantive commits
MAX_BODY_LINES_PER_COMMIT = 3
MAX_BODY_LINES_TOTAL = 15
MAX_NOBODY_CHAINED = 5     # up to 5 body-less commits shown on the fold line
def render_commit_lines(commits, prefix='  • '):
    substantives = [c for c in commits if (c.get('body') or '').strip()]
    nobodies     = [c for c in commits if not (c.get('body') or '').strip()]
    out = []
    budget = MAX_BODY_LINES_TOTAL
    # Render substantive commits first, each with up to 3 body lines within the budget.
    for c in substantives[:MAX_COMMITS]:
        sha = c.get('sha', '')[:7]
        subj = c.get('subject', '')
        url = 'https://github.com/PolarisWang/booming-il2cpp/commit/' + c.get('sha', '')
        out.append(prefix + u'[[' + sha + u'] ' + subj + u'](' + url + u')')
        blines = (c.get('body') or '').splitlines()
        keep = min(len(blines), MAX_BODY_LINES_PER_COMMIT, budget)
        for bl in blines[:keep]:
            out.append('       ' + bl.strip())
        budget -= keep
        if budget <= 0:
            break
    # Fold body-less commits into one compact line (they have no prose to show).
    shown_nobodies = nobodies[:MAX_NOBODY_CHAINED]
    if shown_nobodies:
        parts = []
        for c in shown_nobodies:
            u = 'https://github.com/PolarisWang/booming-il2cpp/commit/' + c.get('sha', '')
            parts.append(u'[[' + c.get('sha', '')[:7] + u'] ' + (c.get('subject') or '') + u'](' + u + u')')
        line = u'  • ' + u' ; '.join(parts)
        if len(nobodies) > MAX_NOBODY_CHAINED:
            line = u'  • ' + ' ; '.join(parts) + u' … (+%d)' % (len(nobodies) - MAX_NOBODY_CHAINED)
        out.append(line)
    return out

# PR mode: show the PR header + individual commits with full messages.
if is_pr and pr_number:
    pr_url = 'https://github.com/PolarisWang/booming-il2cpp/pull/' + pr_number
    pr_header = u'• [PR #' + pr_number + u'] ' + (pr_title or '') + u'  —  ' + pr_url
    cl = [pr_header] + render_commit_lines(commits, prefix='    • ')
else:
    cl = render_commit_lines(commits, prefix='  • ')
ct = chr(10).join(cl) if cl else ('  （无新提交）' if not is_pr else '  PR #' + pr_number)

# Build findings list — rage-standard 4-tier lines: #N [严重] [Repo] file:line_range
severity_icons = {'严重': '🔴', '中': '🟠', '轻': '⚪', '建议': '🟢'}
sel_order = {'严重': 0, '中': 1, '轻': 2, '建议': 3}
# severity-sort (严重 first), stable
flist_sorted = sorted(flist, key=lambda f: sel_order.get(f.get('severity', '建议'), 9))
flines = []
for ndx, fx in enumerate(flist_sorted, start=1):
    sev = fx.get('severity') or '建议'
    icon = severity_icons.get(sev, '⚪')
    repo = fx.get('repo', 'il2cpp')
    fp = fx.get('file', '')
    ln = fx.get('line', 0)
    lr = fx.get('line_range') or (str(ln) if ln else '')
    loc = ':' + str(lr) if lr else ''
    msg = fx.get('message', '')
    fname = fp.split('/')[-1] if '/' in fp else fp
    furl = 'https://github.com/PolarisWang/booming-il2cpp/blob/' + file_sha + '/' + fp + ('#L' + str(lr.split('-')[0]) if lr else '')
    # rage line: #N [严重] [il2cpp] fname:line_range — filename is the Feishu link
    flines.append('{0} **#{1} [{2}] [{3}]** [{4}]({5}) — {6}'.format(
        icon, ndx, sev, repo, fname + loc, furl, msg))
ft = chr(10).join(flines) if flines else '  ✅ 未发现问题'

bu = '${JENKINS_EXT_URL}/job/${env.JOB_NAME}/${env.BUILD_NUMBER}/'

# Build risk overview line with emoji icons (rage 4-tier: 严重 中 轻 建议)
risk_line = ''
total = ${totalFindings}
if total > 0:
    parts = []
    if ${sevCount} > 0:
        parts.append('🔴 **' + str(${sevCount}) + '** 严重')
    if ${medCount} > 0:
        parts.append('🟠 **' + str(${medCount}) + '** 中')
    if ${lightCount} > 0:
        parts.append('⚪ **' + str(${lightCount}) + '** 轻')
    if ${advCount} > 0:
        parts.append('🟢 **' + str(${advCount}) + '** 建议')
    risk_line = '  '.join(parts) if parts else '⚪ 未发现问题'
else:
    if ${env.REVIEW_DOCS_ONLY}:
        risk_line = '📄 **纯文档变更**（本次仅改动 .md/.txt 文档，已按文档维度审查；如有代码改动请单独 review code 变更）'
    elif ${env.REVIEW_INCOMPLETE}:
        risk_line = '⚠️ **审查不完整**（部分文件因模型异常未能覆盖，建议稍后重跑以获得完整结果）'
    elif ${env.REVIEW_LOW_CONF}:
        risk_line = '⚠️ **0 发现 — 低置信**（在实质性代码上得到 0 条，可能是模型异常，建议人工复核）'
    else:
        risk_line = '✅ 本次未发现代码问题'

commit_count = len(commits)
if is_pr and pr_number:
    scope_line = '📋 **审查范围:** PR #' + pr_number + '（' + str(commit_count) + ' 个提交）' + (' — ' + pr_title if pr_title else '')
else:
    scope_line = '📋 **审查范围:** ' + str(commit_count) + ' 个提交'
lines = [
    scope_line,
    '',
    '**新提交:**',
    ct,
    '',
    '**风险概览:**',
    risk_line,
    '',
]
if flines:
    lines.append('**问题列表:**')
    lines.append(ft)
lines.append('')
lines.append('🔗 [查看完整报告](' + bu + ')')

msg = chr(10).join(lines)

with open('${workspaceDir}/feishu_card_msg.txt', 'w') as f:
    f.write(msg)

# Build and send Feishu card directly from Python
webhook = os.environ.get('FEISHU_WEBHOOK_URL', '')
card_color = '${colorTag}'

card = {
    'msg_type': 'interactive',
    'card': {
        'header': {
            'title': {'tag': 'plain_text', 'content': '${feishuTitle}'},
            'template': card_color
        },
        'elements': [
            {'tag': 'div', 'text': {'tag': 'lark_md', 'content': msg}},
            {'tag': 'hr'},
            {
                'tag': 'action',
                'actions': [
                    {
                        'tag': 'button',
                        'text': {'tag': 'plain_text', 'content': '🔧 查看完整报告'},
                        'url': '${JENKINS_EXT_URL}/job/${env.JOB_NAME}/${env.BUILD_NUMBER}/',
                        'type': 'default'
                    }
                ]
            },
            {'tag': 'hr'},
            {
                'tag': 'note',
                'elements': [
                    {'tag': 'plain_text', 'content': 'chaos-il2cpp Code Review · ${DATE_TAG}'}
                ]
            }
        ]
    }
}

payload = json.dumps(card, ensure_ascii=False).encode('utf-8')
if webhook:
    req = urllib.request.Request(
        webhook, data=payload,
        headers={'Content-Type': 'application/json'},
        method='POST')
    try:
        resp = urllib.request.urlopen(req, timeout=30)
        print('Feishu card sent (HTTP ' + str(resp.status) + ')')
    except Exception as e:
        print('WARNING: Feishu webhook failed: ' + str(e))
else:
    print('WARNING: FEISHU_WEBHOOK_URL not set')

print('ok')
"
"""
            }
    }

    stage('Code Review: Notify Feishu') {
        script {
            if (env.REVIEW_SKIPPED != 'false') {
                echo "Skipped, no notification needed"
                return
            }
            echo "Notification already sent from Review stage"
        }
    }

    stage('Code Review: Update State') {
        script {
            if (env.REVIEW_SKIPPED != 'false') {
                echo "Skipped, no state update needed"
                return
            }
            if (isPrReview) {
                // PR mode: record the reviewed head per PR so the poller stops re-triggering.
                def prState = [:]
                try {
                    def s = sh(script: "cat '${prStateFile}' 2>/dev/null || echo '{}'", returnStdout: true).trim()
                    prState = readJSON(text: s)
                } catch (err) {
                    prState = [:]
                }
                prState["${prNumber}"] = prHead
                // Ensure state directory exists before write
                sh "mkdir -p '/var/lib/report-server/daily'"
                writeJSON(file: prStateFile, json: prState, pretty: 2)
                echo "PR state updated: #${prNumber} -> ${prHead} (${prStateFile})"
                // Release the PR poller lock so the next PR/update can be picked up.
                sh "rm -f /var/lib/report-server/daily/cr-pr-trigger.lock"
                echo "PR trigger lock removed"
                // Clean up the temporary refs/heads/pr-* branches created by
                // trigger-pr-review.sh — they accumulate over time and slow down
                // git operations. Delete is safe here because the review has
                // already completed and the state file now records the reviewed head.
                sh """
                    cd '${boomingDir}'
                    git update-ref -d 'refs/heads/pr-${prNumber}' 2>/dev/null || true
                    git update-ref -d 'refs/heads/pr-${prNumber}-base' 2>/dev/null || true
                    echo "Cleanup: removed tmp branches for PR #${prNumber}"
                """
            } else {
                def stateData = [
                        repo: '/home/debian/agent/booming-il2cpp',
                        branch: branch,
                        last_reviewed_commit: env.CURRENT_COMMIT,
                        last_reviewed_at: new Date().format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
                        findings_last_run: [
                            '严重': env.FINDINGS_SEV.toInteger(),
                            '中': env.FINDINGS_MED.toInteger(),
                            '轻': env.FINDINGS_LIGHT.toInteger(),
                            '建议': env.FINDINGS_ADV.toInteger()
                        ]
                    ]
                    // Ensure state directory exists before write
                    sh "mkdir -p '/var/lib/report-server/daily'"
                    writeJSON(file: stateFile, json: stateData, pretty: 2)
                    echo "State updated: ${stateFile}"

                    // Remove trigger lock so next commit detection can fire
                    sh "rm -f /var/lib/report-server/daily/cr-trigger.lock"
                    echo "Trigger lock removed"
            }
        }
    }
}

