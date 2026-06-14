def call(config = [:]) {
    def repoUrl  = config.repoUrl  ?: 'https://github.com/PolarisWang/booming-il2cpp.git'
    def branch   = config.branch   ?: env.CHANGE_BRANCH ?: env.BRANCH_NAME
    def changeId = config.changeId ?: env.CHANGE_ID
    def artifactsDir = "${WORKSPACE}/pr-review"

    stage('PR Review: Init') {
        sh "mkdir -p '${artifactsDir}'"
    }

    stage('PR Review: Checkout') {
        checkout([
            $class: 'GitSCM',
            branches: [[name: "*/${branch}"]],
            userRemoteConfigs: [[url: repoUrl]],
            changelog: true,
            poll: false
        ])
    }

    stage('PR Review: Static Analysis') {
        sh """
            sonar-scanner \\
                -Dsonar.projectKey=booming-il2cpp \\
                -Dsonar.sources=. \\
                -Dsonar.host.url=${env.SONAR_HOST_URL ?: 'http://sonarqube:9000'} \\
                -Dsonar.login=${env.SONAR_TOKEN ?: ''} \\
                -Dsonar.pullrequest.key=${changeId} \\
                -Dsonar.pullrequest.branch=${branch} \\
                -Dsonar.pullrequest.base=main \\
                -Dsonar.pullrequest.provider=github \\
                -Dsonar.pullrequest.github.repository=PolarisWang/booming-il2cpp \\
                2>&1 | tee '${artifactsDir}/sonar-pr.log'
        """
    }

    stage('PR Review: Quality Gate') {
        // Wait for SonarQube quality gate result
        sh """
            sonar-quality-gate-check.sh \\
                --host ${env.SONAR_HOST_URL ?: 'http://sonarqube:9000'} \\
                --token ${env.SONAR_TOKEN ?: ''} \\
                --project booming-il2cpp \\
                --timeout 120 \\
                2>&1 | tee '${artifactsDir}/quality-gate.log'
        """
    }

    stage('PR Review: Build Smoke Test') {
        sh """
            cmake --preset linux-x64-smoke \\
                -DROADMAP0_TOOLCHAIN_VALIDATE_ONLY=OFF \\
                -DCMAKE_BUILD_TYPE=profile
            cmake --build --preset linux-x64-smoke --parallel \$(nproc)
        """
    }

    stage('PR Review: Notify Feishu') {
        script {
            def sonarResult = readFile("${artifactsDir}/quality-gate.log").trim()
            def message = """
PR Review Complete: ${env.CHANGE_TITLE ?: branch}
SonarQube: ${sonarResult}
Review URL: ${env.BUILD_URL}
Commit: ${env.GIT_COMMIT}
"""
            sh """
                scripts/notify-feishu.sh \\
                    --title "PR Review: ${env.CHANGE_TITLE ?: branch}" \\
                    --message '${message}' \\
                    --link "${env.BUILD_URL}" \\
                    --color "blue"
            """
        }
    }
}
