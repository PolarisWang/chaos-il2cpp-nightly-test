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

def BOOMING_DIR   = params.BOOMING_REPO ?: '/booming-il2cpp'
def BUILD_CONFIG  = params.BUILD_CONFIG ?: 'profile'
def ARTIFACTS_DIR = ""
def DATE_TAG      = new Date().format('yyyyMMdd')
def RUN_TAG       = (new Date().format('HH') as int) < 8 ? 'run1' : 'run2'
def FAILED_PLATFORMS = []

pipeline {
    agent none

    options {
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timeout(time: 6, unit: 'HOURS')
        skipDefaultCheckout(true)
    }

    parameters {
        string(name: 'BOOMING_REPO', defaultValue: '/booming-il2cpp',
               description: 'Path to booming-il2cpp repository')
        choice(name: 'BUILD_CONFIG', choices: ['profile', 'debug', 'ship'],
               description: 'Build configuration tier')
    }

    environment {
        DATE_TAG = "${DATE_TAG}"
        RUN_TAG  = "${RUN_TAG}"
        REPORT_API_URL = "http://report-api:8000"
        SONAR_HOST_URL = "http://sonarqube:9000"
    }

    stages {
        // ─────────────────────────────────────────────────────
        // Dispatch — route to the correct pipeline based on job name
        // ─────────────────────────────────────────────────────
        stage('Dispatch') {
            agent { label 'linux-x64' }
            steps {
                script {
                    if (env.JOB_NAME?.contains('code-review')) {
                        runCodeReview(
                            repoUrl: '/booming-il2cpp',
                            branch: params.BOOMING_BRANCH ?: 'main'
                        )
                        env.DISPATCHED = 'true'
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
#!/bin/bash
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
            when { expression { env.DISPATCHED != 'true' } }
            agent { label 'linux-arm64' }
            steps {
                sh """
#!/bin/bash
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
            when { expression { env.DISPATCHED != 'true' } }
            agent { label 'android-arm64' }
            steps {
                sh """
#!/bin/bash
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
#!/bin/bash
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
        failure {
            script {
                if (env.JOB_NAME?.contains('nightly')) {
                    sendNightlyNotification(status: 'FAILURE', artifactsDir: ARTIFACTS_DIR)
                }
            }
        }

        success {
            script {
                if (env.JOB_NAME?.contains('nightly')) {
                    sendNightlyNotification(status: 'SUCCESS', artifactsDir: ARTIFACTS_DIR)
                }
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
        sh """
#!/bin/bash
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
    def dataFile   = "${artifacts}/nightly-data-${DATE_TAG}-${RUN_TAG}.json"
    def webhook    = env.FEISHU_WEBHOOK_URL

    if (!webhook) {
        echo "FEISHU_WEBHOOK_URL not set, skipping notification"
        return
    }

    // External URLs from container environment (set in docker-compose.yml)
    def JENKINS_EXT_URL = env.JENKINS_URL ?: 'http://10.10.1.173:8080'
    def REPORT_EXT_URL  = env.REPORT_URL  ?: 'http://10.10.1.173:8081'

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

        def failSummary = ""
        if (dllResults) {
            def failLines = dllResults.collect { k, v -> "• ${k}: ${v.size()} failed chunk(s)" }
            if (failLines.size() <= 10) {
                failSummary = "\n\n**失败详情:**\n" + failLines.join("\n")
            } else {
                failSummary = "\n\n**失败详情:** ${failLines.size()} DLL(s) 有失败"
            }
        }

        message = """**构建配置:** ${BUILD_CONFIG}
**状态:** ${status}

**覆盖范围:** ${dataDlls}/${totalDlls} DLLs 有数据
**正确率 (Fact):** ${factPassed}/${factTotal} (${factPct})
**基准测试:** ${bmkMethods} 方法
**热更新:** ${hotPassed}/${hotTotal} (${hotPct})
**内存 Profile:** ${memMethods} 方法 · Nursery=${memAllocStr} · GC=${memGcStr}${failSummary}"""
    } catch (err) {
        echo "Failed to read nightly data for notification: ${err.message}"
        message = """**构建配置:** ${BUILD_CONFIG}
**状态:** ${status}"""
    }

    sh """
        scripts/notify-feishu.sh \\
            --title       '${title}' \\
            --message     '${message}' \\
            --report-link '${reportLink}' \\
            --build-link  '${buildLink}' \\
            --color       '${color}'
    """
}

// ============================================================
// Code Review Pipeline — for chaos-il2cpp-code-review job
// ============================================================

def runCodeReview(Map params = [:]) {
    def repoUrl    = params.repoUrl    ?: '/booming-il2cpp'
    def branch     = params.branch     ?: 'main'
    def stateFile  = params.stateFile  ?: '/var/lib/report-server/daily/last-reviewed-commit.json'
    def workspaceDir = "${env.WORKSPACE}/code-review"
    def boomingDir   = "${workspaceDir}/booming-il2cpp"  // Fresh clone each run
    def findingsFile = "${workspaceDir}/findings.json"
    def SCRIPT_DIR   = "${workspaceDir}/scripts"

    stage('Code Review: Init') {
        node('linux-x64') {
            sh "mkdir -p '${workspaceDir}' '${SCRIPT_DIR}'"
            echo "Code review workspace: ${workspaceDir}"
            // Download required scripts from GitHub (public repo)
            sh """
#!/bin/bash
                if [[ ! -f '${SCRIPT_DIR}/review-with-claude.sh' ]]; then
                    curl -sL -o '${SCRIPT_DIR}/review-with-claude.sh' \
                        'https://raw.githubusercontent.com/PolarisWang/chaos-il2cpp-nightly-test/main/scripts/review-with-claude.sh'
                    curl -sL -o '${SCRIPT_DIR}/notify-feishu-text.sh' \
                        'https://raw.githubusercontent.com/PolarisWang/chaos-il2cpp-nightly-test/main/scripts/notify-feishu-text.sh'
                    curl -sL -o '${SCRIPT_DIR}/notify-feishu.sh' \
                        'https://raw.githubusercontent.com/PolarisWang/chaos-il2cpp-nightly-test/main/scripts/notify-feishu.sh'
                    chmod +x '${SCRIPT_DIR}/'*.sh
                    echo "Scripts downloaded to ${SCRIPT_DIR}"
                else
                    echo "Scripts already exist at ${SCRIPT_DIR}"
                fi
            """
        }
    }

    stage('Code Review: Fetch State') {
        node('linux-x64') {
            script {
                env.LAST_REVIEWED_COMMIT = ''
                try {
                    def stateStr = sh(script: "cat '${stateFile}' 2>/dev/null || echo '{}'", returnStdout: true).trim()
                    def state = readJSON text: stateStr
                    env.LAST_REVIEWED_COMMIT = state.last_reviewed_commit ?: ''
                    echo "Last reviewed commit: ${env.LAST_REVIEWED_COMMIT ?: '(none — first run)'}"
                } catch (err) {
                    echo "State file not found or invalid (${err.message}), treating as first run"
                    env.LAST_REVIEWED_COMMIT = ''
                }
            }
        }
    }

    stage('Code Review: Checkout') {
        node('linux-x64') {
            // Fresh shallow clone from local repo (fast, avoids polluting shared repo)
            sh """
#!/bin/bash
                set -euo pipefail

                # Remove old clone if present
                rm -rf '${workspaceDir}/booming-il2cpp'

                # Fresh shallow clone from local upstream
                git clone --depth 50 '${repoUrl}' '${workspaceDir}/booming-il2cpp' 2>&1
                cd '${workspaceDir}/booming-il2cpp'

                # Fetch latest from origin
                git fetch origin 2>&1 || echo "WARNING: fetch failed, using local HEAD"
                git checkout '${branch}' 2>&1 || git checkout FETCH_HEAD 2>&1 || true
                echo "Now at: \$(git log --oneline -1)"
            """
            script {
                env.CURRENT_COMMIT = sh(
                    script: "cd '${workspaceDir}/booming-il2cpp' && git rev-parse HEAD",
                    returnStdout: true
                ).trim()
            }
            echo "Fresh clone: ${workspaceDir}/booming-il2cpp @ ${env.CURRENT_COMMIT}"
        }
    }

    stage('Code Review: Compute Diff') {
        node('linux-x64') {
            script {
                def fromCommit = env.LAST_REVIEWED_COMMIT ?: "${env.CURRENT_COMMIT}~5"
                echo "Diff range: ${fromCommit}..${env.CURRENT_COMMIT}"

                def commitCount = sh(
                    script: "cd '${boomingDir}' && git rev-list --count '${fromCommit}'..'${env.CURRENT_COMMIT}' 2>/dev/null || echo '0'",
                    returnStdout: true
                ).trim()

                if (commitCount == '0') {
                    currentBuild.result = 'SUCCESS'
                    echo "No new commits since last review (${fromCommit}) — skipping"
                    env.REVIEW_SKIPPED = 'true'
                } else {
                    env.REVIEW_SKIPPED = 'false'
                    env.REVIEW_FROM = fromCommit
                    echo "New commits found: ${commitCount}"
                }
            }
        }
    }

    stage('Code Review: Review with Claude') {
        node('linux-x64') {
            script {
                if (env.REVIEW_SKIPPED != 'false') {
                    echo "Review skipped, no Claude invocation needed"
                    return
                }
                sh """
                    bash '${SCRIPT_DIR}/review-with-claude.sh' \
                        --repo-dir    '${boomingDir}' \
                        --from-commit '${env.REVIEW_FROM}' \
                        --to-commit   '${env.CURRENT_COMMIT}' \
                        --output      '${findingsFile}'
                """

                def summaryStr = ''
                try {
                    summaryStr = sh(
                        script: "python3 -c \"import json; print(json.dumps(json.load(open('${findingsFile}'))['summary']))\" || echo '{\"critical\":0,\"high\":0,\"medium\":0,\"low\":0,\"total_findings\":0}'",
                        returnStdout: true
                    ).trim()
                } catch (err) {
                    echo "WARNING: findings parsing failed (${err.message}), using defaults"
                    summaryStr = '{"critical":0,"high":0,"medium":0,"low":0,"total_findings":0}'
                }

                def parsed = readJSON text: summaryStr
                env.FINDINGS_CRIT = parsed.critical.toString()
                env.FINDINGS_HIGH = parsed.high.toString()
                env.FINDINGS_MED  = parsed.medium.toString()
                env.FINDINGS_LOW  = parsed.low.toString()
                env.FINDINGS_TOTAL = parsed.total.toString()

                echo "Findings: ${env.FINDINGS_CRIT} CRITICAL · ${env.FINDINGS_HIGH} HIGH · ${env.FINDINGS_MED} MEDIUM · ${env.FINDINGS_LOW} LOW"

                // Feishu notification — same node() block, no @2 workspace mismatch
                def safeInt = { s -> (s != null && s != 'null' && s != '') ? s.toInteger() : 0 }
                def critCount = safeInt(env.FINDINGS_CRIT)
                def highCount = safeInt(env.FINDINGS_HIGH)
                def medCount  = safeInt(env.FINDINGS_MED)
                def lowCount  = safeInt(env.FINDINGS_LOW)
                def totalFindings = safeInt(env.FINDINGS_TOTAL)

                def colorTag = critCount > 0 || highCount > 0 ? 'red' : (medCount > 0 ? 'blue' : 'green')
                def riskWord = totalFindings > 0 ? "${totalFindings} 个问题" : "无问题"
                def feishuTitle = "chaos-il2cpp 代码审查 — ${riskWord}"

                sh """
#!/bin/bash
python3 -c "
import json, os, urllib.request

try:
    with open('${findingsFile}') as f:
        d = json.load(f)
except Exception:
    d = {}
    d['commits'] = []
    d['findings'] = []

commits = d.get('commits', [])
flist = d.get('findings', [])

# Build commit list with emoji + links
cl = []
for c in commits[:5]:
    sha = c.get('sha', '')[:7]
    msg = c.get('message', '')
    url = 'https://github.com/PolarisWang/booming-il2cpp/commit/' + c.get('sha', '')
    cl.append('  • [' + sha + '] ' + msg)
    cl.append('    ' + url)
ct = chr(10).join(cl) if cl else '  （无新提交）'

# Build findings list with emoji per severity
severity_icons = {'CRITICAL': '🔴', 'HIGH': '🟠', 'MEDIUM': '🔵', 'LOW': '⚪'}
severity_labels = {'CRITICAL': '严重', 'HIGH': '高危', 'MEDIUM': '中等', 'LOW': '低危'}
flines = []
for fx in flist[:10]:
    sev = fx.get('severity', 'LOW')
    icon = severity_icons.get(sev, '⚪')
    label = severity_labels.get(sev, '低危')
    fp = fx.get('file', '')
    ln = fx.get('line', 0)
    msg = fx.get('message', '')
    flines.append('  ' + icon + ' **[' + label + ']** ' + fp + ':' + str(ln))
    flines.append('  > ' + msg)
if len(flist) > 10:
    flines.append('  … 还有 ' + str(len(flist) - 10) + ' 个问题')
ft = chr(10).join(flines) if flines else '  ✅ 未发现问题'

bu = '${env.BUILD_URL}'

# Build risk overview line with emoji icons
risk_line = ''
total = ${totalFindings}
if total > 0:
    parts = []
    if ${critCount} > 0:
        parts.append('🔴 **' + str(${critCount}) + '** 严重')
    if ${highCount} > 0:
        parts.append('🟠 **' + str(${highCount}) + '** 高危')
    if ${medCount} > 0:
        parts.append('🔵 **' + str(${medCount}) + '** 中等')
    if ${lowCount} > 0:
        parts.append('⚪ **' + str(${lowCount}) + '** 低危')
    risk_line = '  '.join(parts) if parts else '⚪ 未发现问题'
else:
    risk_line = '✅ 本次未发现代码问题'

commit_count = len(commits)
lines = [
    '📋 **审查范围:** ' + str(commit_count) + ' 个提交',
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
                        'url': '${env.BUILD_URL}',
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
            }
        }
    }

    stage('Code Review: Notify Feishu') {
        node('linux-x64') {
            script {
                if (env.REVIEW_SKIPPED != 'false') {
                    echo "Skipped, no notification needed"
                    return
                }
                echo "Notification already sent from Review stage (same node() block)"
            }
        }
    }

    stage('Code Review: Update State') {
        node('linux-x64') {
            script {
                if (env.REVIEW_SKIPPED != 'false') {
                    echo "Skipped, no state update needed"
                    return
                }
                sh """
#!/bin/bash
                    TMPFILE="${stateFile}.tmp"
python3 << 'PYEOF'
import json, datetime
data = {
    'repo': '/booming-il2cpp',
    'branch': '${branch}',
    'last_reviewed_commit': '${env.CURRENT_COMMIT}',
    'last_reviewed_at': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'findings_last_run': {
        'critical': ${env.FINDINGS_CRIT},
        'high': ${env.FINDINGS_HIGH},
        'medium': ${env.FINDINGS_MED},
        'low': ${env.FINDINGS_LOW},
    }
}
with open('${stateFile}.tmp', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PYEOF
                    mv "${stateFile}.tmp" "${stateFile}"
                    echo "State updated: ${stateFile}"
                """
            }
        }
    }
}
