import jenkins.model.*
import hudson.security.*
import com.cloudbees.plugins.credentials.*
import com.cloudbees.plugins.credentials.domains.*
import com.cloudbees.plugins.credentials.impl.*

println "=== init.groovy: Setting up agent nodes and credentials ==="
sleep(15000)

// ================================================================
// 1. Register Agent Nodes
// ================================================================
def agents = [
    [name:"linux-x64",     labels:"linux x64 native",           executors:2, remoteFS:"/home/jenkins"],
    [name:"linux-arm64",   labels:"linux arm64 qemu",           executors:1, remoteFS:"/home/jenkins"],
    [name:"android-arm64", labels:"android arm64 ndk",          executors:1, remoteFS:"/home/jenkins"],
    [name:"linux-x64-cr",  labels:"linux-x64-cr code-review",   executors:1, remoteFS:"/home/jenkins"],
    [name:"windows-x64",   labels:"windows-x64 windows x64 msvc", executors:2, remoteFS:"D:\\agent\\workspace"],
]

def nodesDir = new File(Jenkins.instance.getRootDir(), "nodes")
nodesDir.mkdirs()

agents.each { a ->
    if (Jenkins.instance.getNode(a.name) == null) {
        def agentDir = new File(nodesDir, a.name)
        agentDir.mkdirs()

        def configXml = """<?xml version='1.1' encoding='UTF-8'?>
<slave>
  <name>${a.name}</name>
  <description>${a.name} build agent</description>
  <remoteFS>${a.remoteFS}</remoteFS>
  <numExecutors>${a.executors}</numExecutors>
  <mode>NORMAL</mode>
  <retentionStrategy class="hudson.slaves.RetentionStrategy\$Always"/>
  <launcher class="hudson.slaves.JNLPLauncher"/>
  <label>${a.labels}</label>
  <nodeProperties/>
</slave>"""

        new File(agentDir, "config.xml").text = configXml
        println "Wrote config for ${a.name}"
    } else {
        // The node exists. Reconcile the settings that live in the agents list
        // above, so editing that list actually takes effect.
        //
        // This used to be a bare "already exists" log, which meant `executors`
        // and `labels` were write-once: any change made here after the first
        // container start was silently ignored, and the live node kept its
        // original values forever.  Raising windows-x64 from 1 to 2 executors
        // (needed so a comparison build can run alongside the nightly) looked
        // applied in this file while the node still reported 1.
        //
        // Only numExecutors and label are reconciled — deliberately NOT
        // remoteFS or the launcher: rewriting remoteFS on a live node whose
        // workspace is already populated would strand its checkout, and the
        // launcher/JNLP secret is managed by the agent itself.
        def cfgFile = new File(agentDir, "config.xml")
        if (cfgFile.exists()) {
            def txt = cfgFile.text
            def before = txt
            txt = txt.replaceAll(/<numExecutors>\d+<\/numExecutors>/,
                                 "<numExecutors>${a.executors}</numExecutors>")
            txt = txt.replaceAll(/<label>[^<]*<\/label>/,
                                 "<label>${a.labels}</label>")
            if (txt != before) {
                cfgFile.text = txt
                println "Reconciled ${a.name}: executors=${a.executors} labels='${a.labels}'"
            } else {
                println "Agent ${a.name} already exists (config matches)"
            }
        } else {
            println "Agent ${a.name} already exists but has no config.xml — leaving as is"
        }
    }
}

// ================================================================
// 2. Create SonarQube Credential
// ================================================================
def sonarToken = System.getenv('SONAR_TOKEN') ?: ''

if (sonarToken) {
    def creds = CredentialsProvider.lookupCredentials(
        UsernamePasswordCredentialsImpl,
        Jenkins.instance,
        null,
        null
    )

    def exists = creds.any { it.id == 'sonarqube-token' }
    if (!exists) {
        def domain = Domain.global()
        def store = Jenkins.instance.getExtensionList(
            'com.cloudbees.plugins.credentials.SystemCredentialsProvider'
        )[0].getStore()

        def credential = new StringCredentialsImpl(
            CredentialsScope.GLOBAL,
            'sonarqube-token',
            'SonarQube authentication token',
            sonarToken
        )

        store.addCredentials(domain, credential)
        println "Created SonarQube credential: sonarqube-token"
    } else {
        println "SonarQube credential already exists"
    }
} else {
    println "WARNING: SONAR_TOKEN not set. SonarQube credential will not be created."
}

// ================================================================
// 3. Reload Configuration
// ================================================================
println "Reloading Jenkins configuration..."
Jenkins.instance.reload()
println "=== init.groovy: Setup complete ==="
