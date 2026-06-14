def call(config) {
    def PLATFORMS = config.platforms
    def ARTIFACTS_DIR = config.artifactsDir
    def BOOMING_DIR = config.boomingDir
    def BUILD_CONFIG = config.buildConfig
    def FAILED_PLATFORMS = []

    stage('Init') {
        echo "Nightly Pipeline — ${BUILD_CONFIG}"
        sh "mkdir -p '${ARTIFACTS_DIR}'"
    }

    stage('Multi-Platform Build & Test') {
        def branches = [:]
        PLATFORMS.each { platform ->
            branches[platform.name] = buildAndTestPlatform(platform, ARTIFACTS_DIR, BOOMING_DIR, BUILD_CONFIG, FAILED_PLATFORMS)
        }
        parallel branches
    }

    stage('SonarQube Analysis') {
        parallel PLATFORMS.findAll { p -> p.sonar != false }.collectEntries { p ->
            [p.name, sonarScanPlatform(p, ARTIFACTS_DIR, BOOMING_DIR, BUILD_CONFIG)]
        }
    }

    stage('Generate Allure Report') {
        generateAllureReport(ARTIFACTS_DIR, BOOMING_DIR)
    }

    stage('Generate Daily Report') {
        generateDailyReport(ARTIFACTS_DIR, PLATFORMS, FAILED_PLATFORMS, BUILD_CONFIG)
    }

    return [failedPlatforms: FAILED_PLATFORMS, artifactsDir: ARTIFACTS_DIR]
}

def buildAndTestPlatform(platform, artifactsDir, boomingDir, buildConfig, failedPlatforms) {
    return {
        node(platform.label) {
            try {
                checkout scm
                ensureRepo(boomingDir)

                stage("${platform.name}: Configure") {
                    sh """
                        cd '${boomingDir}'
                        cmake --preset '${platform.preset}' \
                              -DROADMAP0_TOOLCHAIN_VALIDATE_ONLY=OFF \
                              -DCMAKE_BUILD_TYPE='${buildConfig}'
                    """
                }

                stage("${platform.name}: Build") {
                    sh """
                        cd '${boomingDir}'
                        cmake --build --preset '${platform.preset}' \
                              --parallel \$(nproc) 2>&1 | tee '${artifactsDir}/${platform.name}-build.log'
                    """
                }

                if (platform.test) {
                    stage("${platform.name}: Test") {
                        runTests(platform, artifactsDir, boomingDir)
                    }
                }

                if (platform.benchmark) {
                    stage("${platform.name}: Benchmark") {
                        runBenchmarks(platform, artifactsDir, boomingDir)
                    }
                }

            } catch (err) {
                failedPlatforms.add(platform.name)
                unstable("${platform.name}: Step failed — ${err.message}")
            } finally {
                collectArtifacts(platform, artifactsDir, boomingDir)
            }
        }
    }
}

def ensureRepo(boomingDir) {
    if (!fileExists(boomingDir)) {
        dir(boomingDir) {
            checkout([
                $class: 'GitSCM',
                branches: [[name: '*/main']],
                userRemoteConfigs: [[url: 'https://github.com/PolarisWang/booming-il2cpp.git']]
            ])
        }
    }
}

def runTests(platform, artifactsDir, boomingDir) {
    sh """
        cd '${boomingDir}'
        for suite in native-abi-smoke native-common-test native-runtime-core-test; do
            if [ -d "artifacts/\${suite}" ]; then
                runner="artifacts/presets/${platform.preset}/bin/run_\${suite}"
                if [ -f "\${runner}" ]; then
                    "\${runner}" 2>&1 | tee '${artifactsDir}/${platform.name}-\${suite}.log'
                fi
            fi
        done
        if [ -f "artifacts/presets/${platform.preset}/CTestTestfile.cmake" ]; then
            cd "artifacts/presets/${platform.preset}"
            ctest --output-on-failure -j\$(nproc) \
                2>&1 | tee '${artifactsDir}/${platform.name}-ctest.log'
        fi
    """
    // Allure results are produced alongside test XMLs; they get collected in collectArtifacts
}

def runBenchmarks(platform, artifactsDir, boomingDir) {
    sh """
        cd '${boomingDir}'
        if [ -d "artifacts/managed_bench" ]; then
            if [ -f "benchmark-full-report.json" ]; then
                cp benchmark-full-report.json '${artifactsDir}/${platform.name}-benchmark.json'
            fi
        fi
    """
}

def collectArtifacts(platform, artifactsDir, boomingDir) {
    sh """
        mkdir -p '${artifactsDir}/${platform.name}'
        # Copy built binaries
        cp -r '${boomingDir}/artifacts/presets/${platform.preset}/bin' \
           '${artifactsDir}/${platform.name}/' 2>/dev/null || true
        # Collect all test reports (XML for JUnit, JSON for Allure)
        find '${boomingDir}/artifacts' -name '*.xml' -o -name 'allure-result.json' \
            -exec cp {} '${artifactsDir}/' \\; 2>/dev/null || true
    """
}

def generateAllureReport(artifactsDir, boomingDir) {
    node('linux-x64') {
        sh """
            mkdir -p '${artifactsDir}/allure-report'
            if ls '${artifactsDir}'/allure-result.json 1>/dev/null 2>&1; then
                allure generate '${artifactsDir}' \
                    --output '${artifactsDir}/allure-report' \
                    --clean 2>&1 | tee '${artifactsDir}/allure-generate.log'
            else
                echo "No Allure results found; skipping report generation."
            fi
        """
    }
}

def generateDailyReport(artifactsDir, platforms, failedPlatforms, buildConfig) {
    node('linux-x64') {
        script {
            def summary = [
                buildNumber: BUILD_NUMBER,
                timestamp  : new Date().format('yyyyMMdd-HHmmss'),
                config     : buildConfig,
                result     : currentBuild.result ?: 'SUCCESS',
                platforms  : platforms.collect { p -> [
                    name  : p.name,
                    status: (p.name in failedPlatforms) ? 'FAILED' : 'PASSED'
                ]}
            ]
            writeFile file: "${artifactsDir}/build-summary.json",
                      text: groovy.json.JsonOutput.toJson(summary)
        }

        sh """
            # Delegate to script for the full HTML collage
            scripts/build-html-daily.sh \\
                '${artifactsDir}' \\
                '${BUILD_NUMBER}' \\
                '${buildConfig}'
        """
    }
}
