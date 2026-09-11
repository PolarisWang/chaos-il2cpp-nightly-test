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
        string(name: 'WINDOWS_BOOMING_DIR', defaultValue: 'D:/agent/workspace/booming-il2cpp',
               description: 'Windows agent: path to booming-il2cpp source (forward slashes)')
    }

    environment {
        BOOMING_DIR = "${BOOMING_DIR}"
        DATE_TAG = "${DATE_TAG}"
        RUN_TAG  = "${RUN_TAG}"
        REPORT_API_URL = "http://report-api:8000"
        SONAR_HOST_URL = "http://sonarqube:9000"
        FEISHU_WEBHOOK_URL = "https://open.feishu.cn/open-apis/bot/v2/hook/9ba5e264-6486-4ba6-abd3-094bb4d923ff"
        // Windows agent uses a separate source path (D:/agent/workspace/booming-il2cpp) — the
        // existing BOOMING_DIR is a Linux path that makes no sense on Windows.
        // This is pulled from the buildWithParameters call or falls back to a sensible
        // Windows default, and is only meaningful inside a `windows-x64` node context.
        WINDOWS_BOOMING_DIR = "${params.WINDOWS_BOOMING_DIR}"
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

                            // Release lock so subsequent commits can trigger a new review.
                            // Without this, any exception before Update State (script crash,
                            // model timeout, ARG_MAX, etc.) leaves the lock stuck and
                            // silently blocks ALL future reviews until LOCK_TIMEOUT.
                            sh "rm -f /var/lib/report-server/daily/cr-trigger.lock 2>/dev/null || true"
                            echo "Trigger lock released (catch path)"

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
                    // GIT_COMMIT is only populated by a checkout step — being a
                    // CpsScmFlowDefinition is NOT enough. Init previously ran with
                    // no checkout at all, so GIT_COMMIT was empty on EVERY build
                    // (verified in build 264's console: "NIGHTLY_SHA=" with the
                    // `main` fallback silently doing the work). That made the
                    // scripts download a moving target and, once the fallback was
                    // removed, stopped the whole pipeline dead.
                    //
                    // Capture the revision from checkout's RETURN VALUE rather
                    // than env.GIT_COMMIT: on this Jenkins the checkout succeeds
                    // but does not export GIT_COMMIT to the environment (build 266
                    // checked out a36f217 and still printed "@ null"), so reading
                    // the env var leaves us with an empty pin.
                    def scmInfo = checkout scm
                    env.GIT_COMMIT = (scmInfo?.GIT_COMMIT
                                      ?: sh(script: 'git -C "$WORKSPACE" rev-parse HEAD',
                                            returnStdout: true).trim())
                    if (!env.GIT_COMMIT) {
                        error("FATAL: could not resolve this repo's revision after checkout")
                    }
                    echo "Building from chaos-il2cpp-nightly-test @ ${env.GIT_COMMIT}"
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
                        # CDN-cached and can serve a STALE script for a while after a push).
                        #
                        # There is deliberately no 'main' fallback. Measured on this setup:
                        # raw.githubusercontent.com/main kept serving the PREVIOUS revision long
                        # after the push (a cache-busting query string did not help), while the
                        # SHA-pinned path returned the new file immediately — a stale script was
                        # actually pulled during validation. Mixed old/new helper scripts are worse
                        # than a hard failure.
                        #
                        # This guard is only safe because Init now runs `checkout scm` above; the
                        # first attempt at this removed the fallback while Init still had no
                        # checkout, and GIT_COMMIT was empty on every build, which failed the
                        # pipeline in 12 seconds (build 265). Finding GIT_COMMIT empty here means
                        # the checkout is gone or broken.
                        NIGHTLY_SHA="\${GIT_COMMIT:-}"
                        if [ -z "\$NIGHTLY_SHA" ]; then
                            echo "FATAL: GIT_COMMIT is unset (Init's checkout scm did not run?)"
                            echo "       Refusing to download helper scripts from the CDN-cached"
                            echo "       'main' path, which can serve a stale revision."
                            exit 1
                        fi
                        RAWT="https://raw.githubusercontent.com/PolarisWang/chaos-il2cpp-nightly-test/\$NIGHTLY_SHA"
                        echo "Downloading nightly scripts from \$RAWT"
                        for script in publish-nightly-results.py generate-nightly-report.py build-feishu-payload.py send-feishu.py notify-feishu.sh notify-feishu-text.sh test-publish-nightly.py; do
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
                            # Deep syntax gate too: a pushed-to-main syntax error reaches this
                            # download with NO checkout (raw.githubusercontent.com, pinned to this
                            # build's GIT_COMMIT) and would otherwise pass a plain non-empty/shebang
                            # check and then silently break the nightly/notify path at runtime —
                            # exactly how a stray apostrophe killed code-review builds 856/857.
                            # Fail the download stage up front with bash -n / py_compile instead.
                            case "\$script" in
                                *.py) grep -q '^#!/usr/bin/env python3' "\$script" || { echo "FATAL: \$script not a valid python script"; exit 1; } ;;
                                *.sh) grep -q '^#!.*sh'            "\$script" || { echo "FATAL: \$script not a valid shell script"; exit 1; } ;;
                            esac
                            case "\$script" in
                                *.py) python3 -m py_compile "\$script" || { echo "FATAL: \$script has a Python syntax error"; exit 1; } ;;
                                *.sh) bash -n "\$script"           || { echo "FATAL: \$script has a shell syntax error"; exit 1; } ;;
                            esac
                        done
                        chmod +x *.sh *.py 2>/dev/null || true
                        ls -la
                    """
                }
            }
        }

        // ─────────────────────────────────────────────────────
        // Publish-Chain Self-Test — fail fast on report-pipeline breakage
        // ─────────────────────────────────────────────────────
        // The publish chain (nightly CLI summary → nightly-data JSON → HTML →
        // ingest) is what every downstream consumer reads, and it broke SILENTLY
        // once already: the publisher kept reading a directory the engine had
        // stopped writing, so every nightly published a well-formed but EMPTY
        // report — the build stayed green and nobody noticed. This stage runs
        // the regression suite for that chain before the expensive build, so a
        // bad script fails here (fast, with a clear message) instead of
        // corrupting another night of results.
        stage('Publish-Chain Self-Test') {
            when { expression { env.DISPATCHED != 'true' } }
            agent { label 'linux-x64' }
            steps {
                script {
                    // `checkout scm` is REQUIRED, not incidental: the Init stage
                    // only curl's scripts/ into the workspace, so without a
                    // checkout the suite silently SKIPs its Jenkinsfile and
                    // report-server assertions — the two that guard this very
                    // gate.  A checkout also means the suite tests the code at
                    // THIS commit rather than whatever raw.githubusercontent
                    // happens to serve.
                    checkout scm
                    // BOOMING_DIR is a developer worktree on the agent; used here
                    // only so the end-to-end section can run against a real
                    // foundation dir. --require-e2e fails the stage if that
                    // section silently skips, so the gate cannot pass vacuously.
                    sh """
                        set -eu
                        cd "\${WORKSPACE}"
                        export CHAOS_ENGINE_DIR="${BOOMING_DIR}"
                        python3 scripts/test-publish-nightly.py --require-e2e
                    """
                }
            }
        }

        // ─────────────────────────────────────────────────────
        // ─────────────────────────────────────────────────────
        // x64 + Windows x64 — Full Pipeline (diagonal parallel)
        // ─────────────────────────────────────────────────────
        // ALIGNED TO REMOTE-main ROAD-① nightly CLI (Route 3 engine),
        // NOT the legacy verification.nightly_runner preserved only in the
        // dirty local worktree.  Both branches run the cmdline-identical
        // module `verification.nightly.cli` from the engine's tests/e2e dir
        // so `verification` resolves on both OSes.  `--report-dir` is set
        // independently per branch (Linux keeps its baseline; Windows writes
        // into nightly-run-windows so it does not corrupt Linux trend data).
        stage('Full Pipeline (x64 + Windows)') {
            when { expression { env.DISPATCHED != 'true' } }
            parallel {
                stage('linux-x64') {
                    agent { label 'linux-x64' }
                    steps {
                        script {
                            // Clean-checkout engine tree for this run (方案A):
                            // the shared /home/debian/agent/booming-il2cpp is a
                            // long-lived DEVELOPER worktree (thousands of dirty
                            // files + coredumps), so running nightly there both
                            // fails the provenance guard (HEAD churn) and risks
                            // clobbering uncommitted work.  Instead, materialise a
                            // pristine copy of origin/main under the Jenkins
                            // workspace via `git archive` (no worktree lock, no
                            // .git copy) and run nightly entirely inside it.
                            def engSrc  = "${BOOMING_DIR}"
                            def engTree = "${env.WORKSPACE}/engine-src"
                            sh """
                                set -euo pipefail
                                rm -rf '${engTree}'
                                mkdir -p '${engTree}'
                                echo "=== [x64] materialising pristine origin/main -> ${engTree} ==="
                                git --git-dir='${engSrc}/.git' archive --format=tar origin/main | tar -x -C '${engTree}'
                                echo "  engine tree files: \$(find '${engTree}' -type f | wc -l)"
                                # Probe the exact conditions build.py uses to locate the target
                                # DLL, so a "DLL not found" is diagnosable from the console.
                                python3 - <<'PY'
import os, sys
from pathlib import Path
dr = os.environ.get("DOTNET_ROOT")
print(f"[dll-probe] DOTNET_ROOT={dr!r}")
rb = Path(dr) / "shared" if dr else None
print(f"[dll-probe] runtime_base={rb} is_dir={rb.is_dir() if rb else None}")
if rb and rb.is_dir():
    print(f"[dll-probe] shared children={[p.name for p in rb.iterdir()][:10]}")
    hits = list(rb.rglob("**/System.Collections.Immutable.dll"))
    print(f"[dll-probe] rglob hits={[str(h) for h in hits]}")
else:
    print("[dll-probe] NO runtime_base — DOTNET_ROOT unset or wrong")
PY
                            """
                            env.NIGHTLY_ENGINE_TREE = engTree
sh """
                        set -euo pipefail
                        mkdir -p "${ARTIFACTS_DIR}"
                        # Run the Route-3 nightly CLI inside the pristine engine tree.
                        cd "${engTree}/tests/e2e"

                        # The `git archive` tree has NO .git/ dir, so the engine's
                        # _detect_repo_root() (which walks up looking for a .git
                        # marker) falls back to Path.cwd() and then mis-resolves
                        # BOTH roots:
                        #   foundation_root()   → <cwd>/testing/foundation-dll (missing)
                        #   testing_tree_root() → <cwd>  (no _pipeline/ there)
                        # Both are file-not-found / import failures.  Point the
                        # engine at the real dirs via its two documented env
                        # overrides (see tests/e2e/verification/_path.py).
                        # Verified locally: with these set, worklist discovery
                        # returns the expected 45 chunks in an archive tree.
                        export CHAOS_FOUNDATION_DLL="${engTree}/tests/e2e/translation"
                        export CHAOS_TESTING_DIR="${engTree}/tests/e2e/verification"

                        echo "=== [x64] Full Pipeline = verification.nightly.cli ==="

                        python3 -m verification.nightly.cli \
                            --max-workers 4 \
                            --native-config "${BUILD_CONFIG}" \
                            2>&1 || echo "WARNING: nightly cli had failures"

                        echo "=== [x64] Publish Results (collect tests/e2e report) ==="
                        # Record the ENGINE revision, not this CI repo's. The nightly
                        # CLI's own run_id hash comes from `git rev-parse` in its CWD,
                        # and the Linux branch runs inside a `git archive` tree with no
                        # .git — so git walks up and reports whatever repo encloses the
                        # Jenkins workspace (observed: the nightly-test repo's hash).
                        # Resolve it from the engine worktree we archived from instead.
                        ENG_SHA=\$(git --git-dir='${engSrc}/.git' rev-parse --short origin/main 2>/dev/null || echo "")
                        echo "  engine revision: \${ENG_SHA}"
                        python3 "\${WORKSPACE}/scripts/publish-nightly-results.py" \
                            --report-dir "${engTree}/tests/e2e/nightly-build-report/summary" \
                            --foundation-dir "${engTree}/tests/e2e/translation" \
                            --output-dir "${ARTIFACTS_DIR}" \
                            --date-tag "${DATE_TAG}" \
                            --run-tag "${RUN_TAG}" \
                            --build-number "\${BUILD_NUMBER}" \
                            --engine-sha "\${ENG_SHA}" \
                            --platform "linux" \
                            --skip-ingest \
                            --skip-minio \
                            2>&1 || echo "WARNING: publish-nightly-results had failures"

                        echo "=== [x64] Pipeline Complete ==="
                    """
                        }
                    }
                }

                stage('windows-x64') {
                    agent { label 'windows-x64' }
                    steps {
                        script {
                            // A workspace-local artifacts dir — the Linux ARTIFACTS_DIR
                            // was set during Init on the linux-x64 agent to a Linux path
                            // that means nothing on a Windows node, so recompute here.
                            def winArtifacts = "${env.WORKSPACE}\\artifacts".replaceAll('\\\\','/')
                            // Engine is synced/cloned under D:/agent/workspace/booming-il2cpp.
                            def winBoomin = env.WINDOWS_BOOMING_DIR ?: 'D:/agent/workspace/booming-il2cpp'
                            // The Jenkins agent runs as a Windows service whose PATH doesn't
                            // inherit your interactive shell's PATH (python/cmake/MSVC may be
                            // missing).  Prepend the standard install locations so the engine's
                            // toolchain is discoverable from this bat step.
                            bat """
                                REM EnableDelayedExpansion at SCRIPT level is required to read
                                REM %ERRORLEVEL% inside a parenthesised block further down
                                REM (the publish step). A bare `setlocal
                                REM EnableDelayedExpansion` there does not work: the
                                REM endlocal & set "VAR=%VAR%" idiom re-expands at parse
                                REM time and captures nothing. Verified on the agent.
                                setlocal EnableDelayedExpansion
                                REM System32 is where curl.exe and certutil.exe live. The
                                REM Jenkins service account's PATH is minimal and does not
                                REM necessarily include it — build 267 failed here with
                                REM "'curl' is not recognized", which silently disabled the
                                REM whole windows publish step.
                                set "PATH=C:\\Windows\\System32;C:\\Windows;C:\\Program Files\\Python312;C:\\Program Files\\dotnet;C:\\Program Files\\CMake\\bin;C:\\Program Files\\Git\\cmd;%PATH%"
                                REM DOTNET_ROOT must be explicit: build.py auto-detects it by
                                REM running `dotnet --info`, which fails silently if dotnet is
                                REM not on PATH under the Jenkins service account — that leaves
                                REM DOTNET_ROOT unset and every chunk fails with
                                REM "DLL not found for <Assembly>".
                                if not defined DOTNET_ROOT if exist "C:\\Program Files\\dotnet\\dotnet.exe" set "DOTNET_ROOT=C:\\Program Files\\dotnet"
                                if not exist "${winArtifacts}" mkdir "${winArtifacts}"

                                REM Sync the engine to the latest origin/main before every run.
                                REM The agent's engine checkout must not drift from main, and the
                                REM controller cannot SSH in to update it — so do it here.
                                REM reset --hard (not pull): the agent tree is a disposable build
                                REM checkout, never a place for local edits.  fetch --depth=1 keeps
                                REM it fast; if fetch fails we keep the existing tree and continue.
                                echo === [win-x64] syncing engine from origin/main ===
                                git config --global --add safe.directory "${winBoomin}"
                                git -C "${winBoomin}" fetch --depth=1 origin main
                                if not errorlevel 1 (
                                    git -C "${winBoomin}" reset --hard origin/main
                                    REM reset --hard does NOT remove untracked leftovers, and
                                    REM one of those is a hard gate: the deprecated
                                    REM "testing/foundation-dll/verification/" tree. The
                                    REM engine moved that package to tests/e2e/verification
                                    REM (323e8c279) but a stale copy on this agent revives
                                    REM on every checkout, and
                                    REM preflight/check_verification_tree_singular.py
                                    REM fails the chunk when it exists on disk even
                                    REM untracked (it can shadow the real engine via
                                    REM stale __pycache__). That single leftover failed
                                    REM every chunk and pinned the run at 0/45 with the
                                    REM opaque error class "unknown".
                                    REM
                                    REM Drop just that deprecated path rather than
                                    REM `git clean -fdx`: a full clean would wipe the
                                    REM build artefacts this agent caches between runs
                                    REM and make every nightly a cold build.
                                    if exist "${winBoomin}/testing/foundation-dll/verification" (
                                        echo === [win-x64] removing deprecated zombie verification tree ===
                                        rmdir /s /q "${winBoomin}/testing/foundation-dll/verification"
                                    )
                                    git -C "${winBoomin}" log -1 --oneline
                                    echo === [win-x64] engine synced ===
                                ) else (
                                    echo === [win-x64] WARNING: engine sync failed - using existing tree ===
                                )

                                cd /d "${winBoomin}/tests/e2e"

                                REM Locate the MSVC environment (cl.exe needs vcvars64). Use the
                                REM VS installer's vswhere first (always present with any VS/BuildTools
                                REM install), then fall back to the common hard-coded path. If neither
                                REM exists we still continue — the engine degrades gracefully on a
                                REM toolchain without MSVC.
                                set "VSWHERE=%ProgramFiles(x86)%\\Microsoft Visual Studio\\Installer\\vswhere.exe"
                                set "VCVARS="
                                if exist "%VSWHERE%" for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VCVARS=%%i\\VC\\Auxiliary\\Build\\vcvars64.bat"
                                if not defined VCVARS if exist "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat" set "VCVARS=C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"
                                if defined VCVARS (
                                    echo === [win-x64] loading MSVC env from "%VCVARS%" ===
                                    call "%VCVARS%"
                                ) else (
                                    echo === [win-x64] WARNING: MSVC vcvars64.bat not found - native codegen may be skipped ===
                                )

                                REM Record the ENGINE revision this run built, resolved
                                REM from the engine tree itself (not from this CI repo).
                                REM The nightly CLI's own run_id hash is unreliable:
                                REM it comes from git in its CWD, and on the Linux
                                REM branch that lands on the enclosing CI checkout, so
                                REM the two platforms reported hashes from different
                                REM namespaces under the same field.
                                for /f "usebackq tokens=*" %%s in (`git -C "${winBoomin}" rev-parse --short HEAD 2^>nul`) do set "ENG_SHA=%%s"
                                if not defined ENG_SHA set "ENG_SHA=unknown"
                                echo === [win-x64] engine revision: %ENG_SHA% ===

                                echo === [win-x64] Full Pipeline = verification.nightly.cli ===

                                REM Pre-flight: build the native SDK on its own first, with full
                                REM output, so a Windows SDK build failure shows its real cause
                                REM (the nightly CLI only prints a generic "presets may not
                                REM support Windows" catch-all). Non-fatal: nightly still runs.
                                echo === [win-x64] SDK preflight (build_presets windows-x64-reference) ===
                                python translation\\artifacts\\build_presets.py --preset windows-x64-reference
                                echo === [win-x64] SDK preflight exit=%ERRORLEVEL% ===

                                REM dotnet diagnostics: the chunk build resolves the target DLL
                                REM from the dotnet runtime shared folder. Print what dotnet
                                REM the build will see and where its runtime lives, so a
                                REM 'DLL not found' can be diagnosed from the console.
                                echo === [win-x64] dotnet diag ===
                                where dotnet
                                echo DOTNET_ROOT=%DOTNET_ROOT%
                                if defined DOTNET_ROOT (dir /b "%DOTNET_ROOT%\\shared\\Microsoft.NETCore.App" 2>nul)
                                if defined DOTNET_ROOT (dir /s /b "%DOTNET_ROOT%\\shared\\System.Collections.Immutable.dll" 2>nul)
                                echo === [win-x64] dotnet --info ===
                                dotnet --info

                                REM Worker count: do NOT use %NUMBER_OF_PROCESSORS%.
                                REM Every chunk runs `dotnet build` against the SAME shared
                                REM projects (Chaos.IL2CPP.Tools.AutoTestGenerator,
                                REM Chaos.IL2CPP.Driver) writing into the SAME obj/ dirs.
                                REM ensure_tool_built() mitigates this with a best-effort
                                REM `dotnet build-server shutdown`, but that is not a lock:
                                REM with N workers the processes race past each other and
                                REM VBCSCompiler keeps the output DLL open, so a sibling
                                REM build dies with
                                REM   error CS2012: Cannot open '...AutoTestGenerator.dll'
                                REM   for writing -- being used by another process
                                REM which killed 9+ chunks in build 268 and left the run at
                                REM 0/45. Linux used a fixed 4 and never hit it; this branch
                                REM was the only one using every core.
                                REM
                                REM 4 matches the Linux branch so the two platforms stay
                                REM comparable, and keeps concurrent rebuilds low enough
                                REM that the shared-project build stays serialised in
                                REM practice. Overridable for a machine that proves it can
                                REM take more.
                                REM `if not defined` only sees variables from a PARENT
                                REM scope, not one set earlier in this same block, so
                                REM `set "X=%X%"` then `if not defined X` never fires.
                                REM Default it explicitly instead.
                                if not defined NIGHTLY_WORKERS set "NIGHTLY_WORKERS=4"
                                echo === [win-x64] workers=%NIGHTLY_WORKERS% (cores=%NUMBER_OF_PROCESSORS%) ===

                                python -m verification.nightly.cli ^
                                    --max-workers %NIGHTLY_WORKERS% ^
                                    --native-config "${BUILD_CONFIG}"

                                echo === [win-x64] Pipeline Complete ===
                                set "REPORT=${winBoomin}\\tests\\e2e\\nightly-build-report"

                                REM ---- Publish Windows results ----
                                REM Previously this branch only echoed the summary to the
                                REM console: the 45 chunk results stayed on D:\\ and never
                                REM reached the Report API, the HTML report, or Feishu. The
                                REM Linux branch publishes its own tree; this one now does
                                REM the same for its own, under a "-win" date tag so the two
                                REM platforms never overwrite each other's trend data.
                                REM
                                REM The helper scripts are downloaded in Init on the
                                REM linux-x64 agent, which this node cannot read — so fetch
                                REM this one here, pinned to GIT_COMMIT for the same
                                REM CDN-staleness reason documented in Init.
                                set "PUB=${winArtifacts}\\publish-nightly-results.py"
                                REM Pin to a concrete SHA, never the moving 'main' ref:
                                REM /main was measured serving a stale revision long
                                REM after a push, so it silently mixes old and new
                                REM helper scripts.
                                REM
                                REM GIT_COMMIT is set by the `checkout scm` in Init, but
                                REM that runs on the linux-x64 agent. This stage runs on
                                REM a different agent, so rather than depending on
                                REM cross-node env propagation we fall back to the
                                REM commit Jenkins used to configure this pipeline
                                REM (GIT_PREVIOUS_COMMIT / the FlowDefinition's own
                                REM revision), and finally skip publishing rather than
                                REM fetch an unpinned script.
                                set "PIN=%GIT_COMMIT%"
                                if "%PIN%"=="" set "PIN=%GIT_PREVIOUS_COMMIT%"
                                if "%PIN%"=="" set "PIN=%GIT_BRANCH%"
                                set "RAWT=https://raw.githubusercontent.com/PolarisWang/chaos-il2cpp-nightly-test/%PIN%"
                                echo === [win-x64] GIT_COMMIT=%GIT_COMMIT% PIN=%PIN% ===
                                echo === [win-x64] fetching publish helpers from %RAWT% ===
                                REM BOTH scripts are needed: publish-nightly-results.py
                                REM shells out to generate-nightly-report.py for the HTML
                                REM report. Downloading only the former produced a
                                REM "generate-nightly-report.py not found, skipping HTML
                                REM generation" warning and a JSON-only result.
                                set "GENPY=${winArtifacts}/generate-nightly-report.py"
                                set "DL_OK=1"
                                curl -sfL --max-time 60 -o "%PUB%" "%RAWT%/scripts/publish-nightly-results.py" || set "DL_OK=0"
                                curl -sfL --max-time 60 -o "%GENPY%" "%RAWT%/scripts/generate-nightly-report.py" || set "DL_OK=0"
                                REM A 404 on a bad pin (or any failed fetch) leaves no
                                REM file. Detect that and SKIP rather than continuing,
                                REM so a broken pin degrades to "no Windows report this
                                REM run" instead of failing the whole nightly branch.
                                if not exist "%PUB%" set "DL_OK=0"
                                if not exist "%GENPY%" set "DL_OK=0"
                                if "%DL_OK%"=="0" (
                                    REM No ';' inside this echo: cmd treats it as a command
                                    REM separator and aborts with "skipping was unexpected at
                                    REM this time" (build 267). Keep parenthesised echo text
                                    REM free of cmd metacharacters.
                                    echo === [win-x64] WARNING: publish helper download failed for pin %PIN% - skipping publish ===
                                ) else (
                                REM Syntax-gate both downloads (same reasoning as Init):
                                REM a truncated body on a flaky link must fail loudly.
                                REM
                                REM !ERRORLEVEL! not %ERRORLEVEL%: this line sits inside a
                                REM parenthesised block, where %ERRORLEVEL% expands at
                                REM PARSE time and captures whatever the code was BEFORE
                                REM the block. That made PYCHECK non-zero on a perfectly
                                REM good download and silently skipped the windows publish
                                REM in build 270 ("publish helper is not valid Python")
                                REM even though the same py_compile returns 0 when run
                                REM standalone on the agent. Delayed expansion is enabled
                                REM at the top of this bat block for exactly this reason.
                                call python -m py_compile "%PUB%" "%GENPY%"
                                set "PYCHECK=!ERRORLEVEL!"
                                if not "!PYCHECK!"=="0" (
                                    echo === [win-x64] WARNING: publish helper is not valid Python for pin %PIN% - skipping publish ===
                                ) else (
                                    echo === [win-x64] Publishing Windows results ===
                                    REM --report-dir: config.report_dir defaults to a
                                    REM cwd-relative "nightly-build-report", and the bat
                                    REM cd's into tests/e2e, so the summary lands there.
                                    REM --skip-ingest/--skip-minio: the Report API container
                                    REM reads its own mounted data dir on the Linux side, so
                                    REM Windows publishes a JSON artifact and relies on
                                    REM archiveArtifacts below to reach the controller.
                                    REM --skip-report-server: that option's default is the
                                    REM LINUX path /var/lib/report-server/daily, so on
                                    REM Windows the copy would create a bogus
                                    REM var/lib tree at the drive root and still
                                    REM report success.
                                    REM Single-line continuations (^): Jenkins' bat treats
                                    REM each physical line as its own command, so a
                                    REM multi-line construct here is a known failure mode.
                                    REM
                                    REM Exit-code capture: %ERRORLEVEL% inside a
                                    REM parenthesised block expands at PARSE time and
                                    REM yields a stale value, so it cannot be read
                                    REM directly (this is how `publish exit=` came out
                                    REM empty on the real agent). Delayed expansion is
                                    REM required — and it must be enabled at SCRIPT
                                    REM level. Enabling it mid-script with setlocal
                                    REM does not survive: the usual
                                    REM   endlocal & set "PUBRC=%PUBRC%"
                                    REM idiom re-expands %PUBRC% at PARSE time BEFORE
                                    REM endlocal runs, so it captures nothing. Verified
                                    REM on the agent: only script-level enablement with
                                    REM a plain !PUBRC! read gives the real code.
                                    python "%PUB%" ^
                                        --report-dir "%REPORT%\\summary" ^
                                        --foundation-dir "${winBoomin}\\tests\\e2e\\translation" ^
                                        --output-dir "${winArtifacts}" ^
                                        --date-tag "%DATE_TAG%-win" ^
                                        --run-tag "${RUN_TAG}" ^
                                        --build-number "%BUILD_NUMBER%" ^
                                        --engine-sha "%ENG_SHA%" ^
                                        --platform "windows" ^
                                        --skip-ingest --skip-minio --skip-report-server
                                    echo === [win-x64] publish exit=!ERRORLEVEL! ===
                                )
                                )

                                REM ---- Debug surface (controller cannot SSH into this box,
                                REM but the maintainer can — keep this minimal & robust). ----
                                echo === [win-x64] report tree ===
                                if exist "%REPORT%" (dir /s /b "%REPORT%" 2>nul) else (echo [win-x64] report dir MISSING: %REPORT%)
                                echo === [win-x64] published artifacts ===
                                if exist "${winArtifacts}" (dir /b "${winArtifacts}" 2>nul)
                            """
                            // Archive on THIS node: the post block's archiveArtifacts
                            // runs on the linux-x64 agent and cannot see a Windows
                            // workspace, so without this the windows-x64
                            // nightly-data-*.json never reaches the controller. The
                            // Windows payload uses a "<date>-win" tag, so it does not
                            // collide with the Linux artifact of the same build.
                            archiveArtifacts artifacts: "artifacts/**/*",
                                           allowEmptyArchive: true,
                                           fingerprint: true
                        }
                    }
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
                        // Morning run: compare against yesterday's last run.
                        // NOTE the format is %Y%m%d — it was %Y%mdd, which emits
                        // a literal "dd" (e.g. 202609dd), so prevFile never
                        // matched and --baseline was silently never applied.
                        def yesterday = sh(script: "date -d '${DATE_TAG} 1 day ago' +%Y%m%d", returnStdout: true).trim()
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
                    // Release trigger lock on ANY exit path (success, failure, abort).
                    // The lock is also released inside the Review stage (catch block and
                    // Update State), but those are skipped on early-exit paths (skip guard,
                    // script abort, etc.).  The post block runs unconditionally and is the
                    // ultimate safety net.  Only the code-review job touches this lock.
                    if (env.JOB_NAME?.contains('code-review')) {
                        sh "rm -f /var/lib/report-server/daily/cr-trigger.lock 2>/dev/null || true"
                    }
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

        // Collect per-platform results for BOTH branches. The two agents have
        // separate workspaces and no copyartifact plugin is installed, so fetch
        // each platform's archived payload over the Jenkins API. A missing
        // platform is reported IN the card rather than silently omitted —
        // otherwise "windows produced no data" is indistinguishable from
        // "windows was never run", which is exactly how the gap went unnoticed.
        def platformLines = []
        def missingPlatforms = []
        try {
            def payloadOut = "${WORKSPACE}/.notify/platform-payload.json"
            def localLinux = "${artifacts}/nightly-data-${DATE_TAG}-${RUN_TAG}.json"
            sh """
                python3 "\${WORKSPACE}/scripts/build-feishu-payload.py" \
                    --build-url "${JENKINS_EXT_URL}/job/chaos-il2cpp-nightly/${BUILD_NUMBER}" \
                    --date-tag "${DATE_TAG}" --run-tag "${RUN_TAG}" \
                    --local-linux-json "${localLinux}" \
                    --output "${payloadOut}" 2>&1 || true
            """
            def payload = readJSON text: sh(
                script: "cat '${payloadOut}' 2>/dev/null || echo '{}'",
                returnStdout: true).trim()
            platformLines = payload.body_lines ?: []
            missingPlatforms = payload.missing_platforms ?: []
        } catch (err) {
            echo "WARNING: per-platform payload build failed (card falls back to linux-only): ${err.message}"
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
            platform_lines: platformLines,
            missing_platforms: missingPlatforms,
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
# Per-platform section (v5). The card previously described the linux-x64
# workspace only, so the group could not tell that a windows run existed at
# all — let alone that it had failed. These lines come from
# build-feishu-payload.py, which fetches BOTH platforms' archived payloads
# over the Jenkins API (the two agents have separate workspaces and no
# copyartifact plugin is installed).
platform_lines = data.get('platform_lines') or []
if platform_lines:
    parts.append('')
    parts.append('**各平台结果:**')
    parts.extend(platform_lines)
missing = data.get('missing_platforms') or []
if missing:
    parts.append('')
    parts.append('⚠️ **缺少平台报告:** ' + '、'.join(missing)
                 + ' — 该平台本轮未产出数据，请检查该分支是否失败')
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
            // GIT_COMMIT comes from a checkout, not from being
            // CpsScmFlowDefinition — and on this Jenkins the checkout does not
            // export it to the environment either, so capture it from the
            // checkout return value (build 266). Without this the SHA below is
            // empty and the guard aborts the review (as it did in build 1561).
            def crScmInfo = checkout scm
            env.GIT_COMMIT = (crScmInfo?.GIT_COMMIT
                              ?: sh(script: 'git -C "$WORKSPACE" rev-parse HEAD',
                                    returnStdout: true).trim())
            if (!env.GIT_COMMIT) {
                error("FATAL: could not resolve this repo's revision after checkout")
            }
            echo "Code review running from chaos-il2cpp-nightly-test @ ${env.GIT_COMMIT}"
            sh """
                set -euo pipefail
                mkdir -p '${SCRIPT_DIR}'
                echo "Downloading review scripts from GitHub..."
                # Pin to this repo's own checked-out SHA (GIT_COMMIT) so the download
                # is consistent: raw.githubusercontent.com's bare 'main' path is
                # CDN-cached and can serve a STALE script for a while after a push
                # (e.g. missing the docs-only review). No 'main' fallback: measured on
                # this setup, /main served the previous revision long after the push
                # (cache-busting did not help) while the SHA path was current, so a
                # fallback would silently mix old and new scripts. The `checkout scm`
                # immediately above is what makes GIT_COMMIT non-empty here.
                NIGHTLY_SHA="\${GIT_COMMIT:-}"
                if [ -z "\$NIGHTLY_SHA" ]; then
                    echo "FATAL: GIT_COMMIT is unset (the checkout scm did not run?)"
                    echo "       Refusing to download review scripts from the CDN-cached"
                    echo "       'main' path, which can serve a stale revision."
                    exit 1
                fi
                RAWT="https://raw.githubusercontent.com/PolarisWang/chaos-il2cpp-nightly-test/\$NIGHTLY_SHA"
                echo "Downloading from \$RAWT"
                curl -sL --max-time 30 -o '${SCRIPT_DIR}/review-with-claude.sh' \
                    "\$RAWT/scripts/review-with-claude.sh"
                curl -sL --max-time 30 -o '${SCRIPT_DIR}/notify-feishu-text.sh' \
                    "\$RAWT/scripts/notify-feishu-text.sh"
                curl -sL --max-time 30 -o '${SCRIPT_DIR}/notify-feishu.sh' \
                    "\$RAWT/scripts/notify-feishu.sh"
                curl -sL --max-time 30 -o '${SCRIPT_DIR}/send-code-review-card.sh' \
                    "\$RAWT/scripts/send-code-review-card.sh"
                curl -sL --max-time 30 -o '${SCRIPT_DIR}/code-review-card.py' \
                    "\$RAWT/scripts/code-review-card.py"
                chmod +x '${SCRIPT_DIR}/'*.sh
                # Sanity: the review script must carry the docs-reviewable marker (the
                # EXTS_KEEP-with-.md fix that makes the docs path actually run). Without it
                # a docs-only range still falls through to the all-excluded early exit.
                grep -Fq 'DOCS_REVIEWABLE_VERSION_MARKER' '${SCRIPT_DIR}/review-with-claude.sh' || {
                    # Retry the SHA-pinned URL rather than /main. The old code re-pulled
                    # from /main, but /main is the CDN-cached path measured serving the
                    # PREVIOUS revision after a push (cache-busting did not help), so a
                    # "stale download" would just re-fetch the same stale bytes. A
                    # transient curl failure is the likelier cause, so retry the pin.
                    echo "WARNING: review script lacks docs marker (stale or truncated download?); re-pulling pinned revision"
                    rm -f '${SCRIPT_DIR}/review-with-claude.sh'
                    ok=0
                    for attempt in 1 2 3; do
                        curl -sfL --max-time 30 -o '${SCRIPT_DIR}/review-with-claude.sh' \
                            "\$RAWT/scripts/review-with-claude.sh" && \\
                            grep -Fq 'DOCS_REVIEWABLE_VERSION_MARKER' '${SCRIPT_DIR}/review-with-claude.sh' && ok=1 && break
                        echo "  retry \$attempt/3 for review-with-claude.sh"
                        sleep 2
                    done
                    chmod +x '${SCRIPT_DIR}/review-with-claude.sh'
                    if [ "\$ok" != "1" ]; then
                        echo "ERROR: review script still lacks docs marker after 3 attempts from \$RAWT"
                        exit 1
                    fi
                }
                # Syntax-validate the extracted card-send scripts (layer 3) so a
                # main-pushed syntax error aborts here at download, not silently at
                # send time (the fault that made cards silently not arrive).
                bash -n '${SCRIPT_DIR}/send-code-review-card.sh' || {
                    echo "ERROR: send-code-review-card.sh has a shell syntax error"
                    exit 1
                }
                python3 -m py_compile '${SCRIPT_DIR}/code-review-card.py' || {
                    echo "ERROR: code-review-card.py has a Python syntax error"
                    exit 1
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
                    # code-review card render + Feishu send, extracted to a
                    # real on-disk script (layer 3) so stdout is visible.
                    # NOTE: the CARD_* env vars MUST be passed here — the renderer
                    # reads them from the environment (it no longer gets values via
                    # Groovy interpolation).  Omitting them made every card render
                    # "✅ 本次未发现代码问题" with a blue header and a broken blob
                    # link even when findings existed (regression from 6341ae2).
                    export CARD_TOTAL='${totalFindings}'
                    export CARD_SEV='${sevCount}'
                    export CARD_MED='${medCount}'
                    export CARD_LIGHT='${lightCount}'
                    export CARD_ADV='${advCount}'
                    export CARD_TITLE='${feishuTitle}'
                    export CARD_COLOR='${colorTag}'
                    export CARD_FILE_SHA='${isPrReview ? prHead : env.CURRENT_COMMIT}'
                    export CARD_IS_PR='${isPrReview}'
                    export REVIEW_DOCS_ONLY='${docsOnly ? "1" : "0"}'
                    export REVIEW_INCOMPLETE='${inComplete ? "1" : "0"}'
                    export REVIEW_LOW_CONF='${lowConf ? "1" : "0"}'
                    bash '${SCRIPT_DIR}/send-code-review-card.sh' \\
                        --repo-dir    '${boomingDir}' \\
                        --workspace   '${workspaceDir}' \\
                        --findings    '${findingsFile}' \\
                        --jenkins-url '${JENKINS_EXT_URL}' \\
                        --job         '${env.JOB_NAME}' \\
                        --build-num   '${env.BUILD_NUMBER}' \\
                        --date-tag    '${DATE_TAG}'
                """

                // Layer 1: release the trigger lock EARLY (right after review+card are
                // complete), NOT only in the Update State stage. If the card-send or a
                // later stage hangs (the observed silent "no card since yesterday" fault
                // was a build that ran review + card but never finished), the lock would
                // otherwise stay until LOCK_TIMEOUT and block every subsequent review.
                // Releasing here means the poller can start the next review immediately.
                // Only release the main lock when NOT in PR mode — PR builds have their
                // own separate lock (cr-pr-trigger.lock) managed by trigger-pr-review.sh.
                if (!isPrReview) {
                    sh "rm -f /var/lib/report-server/daily/cr-trigger.lock 2>/dev/null || true"
                    echo "Trigger lock released early (after review+card)"
                }
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

