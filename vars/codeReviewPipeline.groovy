def call(Map params = [:]) {
    def repoUrl    = params.repoUrl    ?: 'https://github.com/PolarisWang/booming-il2cpp.git'
    def branch     = params.branch     ?: 'main'
    def stateFile  = params.stateFile  ?: '/var/lib/report-server/daily/last-reviewed-commit.json'
    def workspaceDir = "${env.WORKSPACE}/code-review"
    def boomingDir   = "${workspaceDir}/booming-il2cpp"
    def findingsFile = "${workspaceDir}/findings.json"
    def SCRIPT_DIR   = "${env.WORKSPACE}/scripts"

    stage('Code Review: Init') {
        node('linux-x64') {
            sh "mkdir -p '${workspaceDir}'"
            echo "Code review workspace: ${workspaceDir}"
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
            checkout([
                $class: 'GitSCM',
                branches: [[name: "*/${branch}"]],
                userRemoteConfigs: [[url: repoUrl]],
                changelog: true,
                poll: false
            ])
            script {
                env.CURRENT_COMMIT = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
            }
            echo "Checked out ${repoUrl} @ ${env.CURRENT_COMMIT}"
        }
    }

    stage('Code Review: Compute Diff') {
        node('linux-x64') {
            script {
                def fromCommit = env.LAST_REVIEWED_COMMIT ?: "${env.CURRENT_COMMIT}~5"
                echo "Diff range: ${fromCommit}..${env.CURRENT_COMMIT}"

                def commitCount = sh(
                    script: "cd '${env.WORKSPACE}' && git rev-list --count '${fromCommit}'..'${env.CURRENT_COMMIT}' 2>/dev/null || echo '0'",
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
        when { expression { env.REVIEW_SKIPPED == 'false' } }
        node('linux-x64') {
            script {
                sh """
                    bash '${SCRIPT_DIR}/review-with-claude.sh' \
                        --repo-dir    '${env.WORKSPACE}' \
                        --from-commit '${env.REVIEW_FROM}' \
                        --to-commit   '${env.CURRENT_COMMIT}' \
                        --output      '${findingsFile}'
                """

                // Parse findings summary from the JSON output
                def summaryStr = sh(
                    script: """python3 -c "
                import json
                try:
                    with open('${findingsFile}') as f:
                        d = json.load(f)
                    s = d.get('summary', {})
                    print(json.dumps({
                        'critical': s.get('critical', 0),
                        'high': s.get('high', 0),
                        'medium': s.get('medium', 0),
                        'low': s.get('low', 0),
                        'total': s.get('total_findings', 0),
                    }))
                except Exception as e:
                    print(json.dumps({'critical': 0, 'high': 0, 'medium': 0, 'low': 0, 'total': 0, 'error': str(e)}))
                " 2>/dev/null""",
                    returnStdout: true
                ).trim()

                def parsed = readJSON text: summaryStr
                env.FINDINGS_CRIT = parsed.critical.toString()
                env.FINDINGS_HIGH = parsed.high.toString()
                env.FINDINGS_MED  = parsed.medium.toString()
                env.FINDINGS_LOW  = parsed.low.toString()
                env.FINDINGS_TOTAL = parsed.total.toString()

                echo "Findings: ${env.FINDINGS_CRIT} CRITICAL · ${env.FINDINGS_HIGH} HIGH · ${env.FINDINGS_MED} MEDIUM · ${env.FINDINGS_LOW} LOW"
                archiveArtifacts artifacts: 'code-review/findings.json', allowEmptyArchive: true
            }
        }
    }

    stage('Code Review: Notify Feishu') {
        when {
            expression {
                env.REVIEW_SKIPPED == 'false' &&
                (env.FINDINGS_CRIT.toInteger() > 0 || env.FINDINGS_HIGH.toInteger() > 0)
            }
        }
        node('linux-x64') {
            script {
                def critCount = env.FINDINGS_CRIT.toInteger()
                def highCount = env.FINDINGS_HIGH.toInteger()
                def medCount  = env.FINDINGS_MED.toInteger()
                def totalFindings = env.FINDINGS_TOTAL.toInteger()

                // Get commits list and findings detail from the JSON
                def detail = sh(
                    script: """python3 -c "
                import json

                with open('${findingsFile}') as f:
                    d = json.load(f)

                # Build commit list
                commits = d.get('commits', [])
                commit_lines = []
                for c in commits[:5]:
                    sha = c.get('sha', '')[:7]
                    msg = c.get('message', '')
                    url = 'https://github.com/PolarisWang/booming-il2cpp/commit/' + c.get('sha', '')
                    commit_lines.append(f'  • {sha} {msg}')
                    commit_lines.append(f'    {url}')
                commits_text = chr(10).join(commit_lines) if commit_lines else '  (see Jenkins for details)'

                # Build findings list (top 10)
                findings = d.get('findings', [])
                finding_lines = []
                severity_icon = {'CRITICAL': 'CRITICAL', 'HIGH': 'HIGH   ', 'MEDIUM': 'MEDIUM ', 'LOW': 'LOW    '}
                for f in findings[:10]:
                    sev = f.get('severity', 'LOW')
                    icon = severity_icon.get(sev, 'LOW')
                    fp = f.get('file', '')
                    ln = f.get('line', 0)
                    msg = f.get('message', '')
                    finding_lines.append(f'  {icon} | {fp}:{ln} — {msg}')
                if len(findings) > 10:
                    finding_lines.append(f'  ... +{len(findings) - 10} more')
                findings_text = chr(10).join(finding_lines) if finding_lines else '  (no detailed findings parsed)'

                # Determine title icon
                title_icon = 'CRITICAL' if ${critCount} > 0 else 'HIGH'

                # Build full message
                build_url = '${env.BUILD_URL}'
                lines = [
                    f'{title_icon} booming-il2cpp Code Review — {${critCount} + ${highCount}} high-risk findings',
                    '',
                    f'New commits ({len(commits)}):',
                    commits_text,
                    '',
                    f'Risk overview: ${critCount} CRITICAL  ${highCount} HIGH  ${medCount} MEDIUM',
                    '',
                    'Problem list:',
                    findings_text,
                    '',
                    f'Full report: {build_url}',
                ]
                msg = chr(10).join(lines)
                print(msg)
                " 2>/dev/null""",
                    returnStdout: true
                ).trim()

                def title = "chaos-il2cpp Code Review — ${totalFindings} findings"
                sh """
                    bash '${SCRIPT_DIR}/notify-feishu-text.sh' \
                        --title    '${title}' \
                        --message  '${detail}'
                """
            }
        }
    }

    stage('Code Review: Update State') {
        when { expression { env.REVIEW_SKIPPED == 'false' } }
        node('linux-x64') {
            script {
                sh """#!/bin/bash
                    TMPFILE="${stateFile}.tmp"
                    python3 -c "
                import json, datetime
                data = {
                    'repo': '${repoUrl}',
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
                "
                    mv "${stateFile}.tmp" "${stateFile}"
                    echo "State updated: ${stateFile}"
                """
            }
        }
    }
}
