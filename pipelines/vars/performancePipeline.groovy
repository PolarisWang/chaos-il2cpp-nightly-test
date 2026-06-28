def call(config = [:]) {
    def platform   = config.platform  ?: 'linux-x64'
    def iterations = config.iterations?.toInteger() ?: 3
    def buildConfig = config.buildConfig ?: 'profile'
    def boomingDir = config.boomingDir ?: '/home/debian/agent/booming-il2cpp'
    def artifactsDir = "${WORKSPACE}/perf-${BUILD_NUMBER}"

    stage('Perf: Init') {
        sh "mkdir -p '${artifactsDir}'"
    }

    stage('Perf: Build') {
        node(platform) {
            sh """
                cd '${boomingDir}'
                cmake --preset '${platform}-packaging' \
                      -DROADMAP0_TOOLCHAIN_VALIDATE_ONLY=OFF \
                      -DCMAKE_BUILD_TYPE='${buildConfig}'
                cmake --build --preset '${platform}-packaging' --parallel \$(nproc)
            """
        }
    }

    stage('Perf: Benchmark') {
        node(platform) {
            sh """
                cd '${boomingDir}'
                for i in \$(seq 1 ${iterations}); do
                    echo "--- Iteration \${i}/${iterations} ---"
                    artifacts/presets/${platform}-packaging/bin/run_performance_suite \
                        2>&1 | tee '${artifactsDir}/bench-iter-\${i}.log'
                done
                # Aggregate results
                if command -v python3 &>/dev/null; then
                    python3 ${WORKSPACE}/scripts/aggregate-benchmarks.py \
                        --dir '${artifactsDir}' \
                        --platform '${platform}' \
                        --output '${artifactsDir}/benchmark-report.json'
                fi
            """
        }
    }

    stage('Perf: Report') {
        node('linux-x64') {
            sh """
                scripts/generate-allure.sh \\
                    --input '${artifactsDir}' \\
                    --output '${artifactsDir}/allure-report'
            """
            publishHTML(target: [
                allowMissing: true,
                alwaysLinkToLastBuild: false,
                keepAll: true,
                reportDir: "${artifactsDir}",
                reportFiles: 'allure-report/index.html',
                reportName: "Perf Report #${BUILD_NUMBER}"
            ])
        }
    }

    stage('Perf: Notify') {
        script {
            sh """
                scripts/notify-feishu.sh \\
                    --title "Performance Test #${BUILD_NUMBER} (${platform}, ${iterations} runs)" \\
                    --message "Config: ${buildConfig}\\nIterations: ${iterations}" \\
                    --link "${env.BUILD_URL}" \\
                    --color "green"
            """
        }
    }
}
