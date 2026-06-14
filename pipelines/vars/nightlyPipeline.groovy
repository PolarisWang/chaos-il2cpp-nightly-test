def call(config) {
    def PLATFORMS = config.platforms
    def ARTIFACTS_DIR = config.artifactsDir
    def BOOMING_DIR = config.boomingDir
    def BUILD_CONFIG = config.buildConfig
    def FRESH_CLONE = config.freshClone ?: true
    def FAILED_PLATFORMS = []
    def ORCHESTRATOR_SCRIPT = "${env.WORKSPACE}/scripts/nightly-orchestrator.sh"

    stage('Nightly: Main Platform (linux-x64) — Full Pipeline') {
        node('linux-x64') {
            try {
                checkout scm

                sh """
                    # Run the full nightly orchestrator on the primary platform
                    bash '${ORCHESTRATOR_SCRIPT}' \
                        --build-config '${BUILD_CONFIG}' \
                        --clone-dir '${BOOMING_DIR}' \
                        --fresh-clone '${FRESH_CLONE}' \
                        --build-number '${BUILD_NUMBER}'
                """
            } catch (err) {
                FAILED_PLATFORMS.add('linux-x64')
                unstable("linux-x64: Orchestrator failed — ${err.message}")
            }
        }
    }

    stage('Nightly: Secondary Platforms') {
        def branches = [:]

        // Only run non-primary platforms as secondary
        PLATFORMS.findAll { p -> p.name != 'linux-x64' }.each { platform ->
            branches[platform.name] = secondaryPlatformBuild(platform, ARTIFACTS_DIR, BOOMING_DIR, BUILD_CONFIG, FAILED_PLATFORMS)
        }

        if (branches) {
            parallel branches
        }
    }

    return [failedPlatforms: FAILED_PLATFORMS, artifactsDir: ARTIFACTS_DIR]
}

def secondaryPlatformBuild(platform, artifactsDir, boomingDir, buildConfig, failedPlatforms) {
    return {
        node(platform.label) {
            try {
                checkout scm

                // On secondary platforms, ensure the repo exists (skip clone if already there from primary)
                if (!fileExists(boomingDir)) {
                    dir(boomingDir) {
                        checkout([
                            $class: 'GitSCM',
                            branches: [[name: '*/main']],
                            userRemoteConfigs: [[url: 'https://github.com/PolarisWang/booming-il2cpp.git']]
                        ])
                    }
                }

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

                // linux-arm64: run fact verification (subset) to cross-validate correctness
                if (platform.name == 'linux-arm64' && platform.test) {
                    stage("${platform.name}: Fact Verification") {
                        sh """
                            cd '${boomingDir}/testing/foundation-dll'
                            python -m verification.chunk_pipeline \
                                --assembly System.Private.CoreLib \
                                --chunk numerics \
                                --stages "build,fact" \
                                --native-config "${buildConfig}" \
                                2>&1 | tee '${artifactsDir}/${platform.name}-fact.log'
                        """
                    }
                }

            } catch (err) {
                failedPlatforms.add(platform.name)
                unstable("${platform.name}: Step failed — ${err.message}")
            }
        }
    }
}
