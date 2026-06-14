def call(action, Map params = [:]) {
    switch(action) {
        case 'feishu':
            feishu(params)
            break
        case 'email':
            email(params)
            break
        case 'all':
            feishu(params)
            email(params)
            break
        case 'nightlySummary':
            nightlySummary(params)
            break
        default:
            echo "Unknown notification action: ${action}"
    }
}

def feishu(Map params) {
    def title   = params.title   ?: "Build #${BUILD_NUMBER}"
    def message = params.message ?: ''
    def link    = params.link    ?: env.BUILD_URL
    def color   = params.color   ?: 'green'

    sh """
        scripts/notify-feishu.sh \\
            --title '${title}' \\
            --message '${message}' \\
            --link '${link}' \\
            --color '${color}'
    """
}

def email(Map params) {
    def subject = params.subject ?: "Build #${BUILD_NUMBER} Report"
    def body    = params.body    ?: 'See Jenkins for details.'
    def to      = params.to      ?: 'team@example.com'

    mail(
        to: to,
        subject: subject,
        body: body,
        mimeType: 'text/html'
    )
}

def nightlySummary(Map params) {
    def buildConfig     = params.buildConfig     ?: 'profile'
    def failedPlatforms = params.failedPlatforms ?: []
    def dateTag         = params.dateTag         ?: new Date().format('yyyyMMdd')
    def reportUrl       = "${env.BUILD_URL}allure-report"

    def resultIcon = currentBuild.result == 'SUCCESS' ? '✅' : '❌'
    def title = "${resultIcon} Nightly Build #${BUILD_NUMBER} — ${dateTag}"
    def platformStatus = failedPlatforms ? "Failed: ${failedPlatforms.join(', ')}" : "All platforms passed"
    def message = """
Config: ${buildConfig}
Date: ${dateTag}
Status: ${currentBuild.result ?: 'SUCCESS'}
${platformStatus}

Report: ${reportUrl}
"""

    feishu(
        title: title,
        message: message,
        link: reportUrl,
        color: currentBuild.result == 'SUCCESS' ? 'green' : 'red'
    )

    // Only send email on failure (reduce noise)
    if (currentBuild.result != 'SUCCESS') {
        email(
            subject: "[chaos-nightly] ${currentBuild.result} Build #${BUILD_NUMBER}",
            body: """
<h2>${title}</h2>
<p>Config: <strong>${buildConfig}</strong></p>
<p><strong>Failed Platforms:</strong> ${failedPlatforms ? failedPlatforms.join(', ') : 'None'}</p>
<p>Result: ${currentBuild.result}</p>

<h3>Links</h3>
<ul>
  <li><a href="${env.BUILD_URL}">Jenkins Build</a></li>
  <li><a href="${reportUrl}">Allure Test Report</a></li>
  <li><a href="${env.BUILD_URL}/artifact/artifacts/nightly-report-${dateTag}.html">Nightly Report</a></li>
</ul>

<h3>Platform Results</h3>
<ul>
""",
            to: 'team@example.com'
        )
    }
}
