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
    // Declared BEFORE the branch: Groovy's `def` is block-scoped, so a
    // declaration inside the `if` would be invisible to the `else` that
    // reconciles existing nodes (`MissingPropertyException: agentDir`).
    def agentDir = new File(nodesDir, a.name)

    if (Jenkins.instance.getNode(a.name) == null) {
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
//
// Deliberately REFLECTION-BASED, and wrapped so it can never break node
// registration above.
//
// The previous version used a direct `new StringCredentialsImpl(...)`.  Groovy
// resolves class names at COMPILE time, and init.groovy is compiled very early
// in Jenkins startup — before plugin classes contributed by
// `plain-credentials` are on the script's classpath.  The result was not a
// runtime failure of this block but a compilation failure of the WHOLE FILE:
//
//   unable to resolve class StringCredentialsImpl
//   org.codehaus.groovy.control.MultipleCompilationErrorsException
//
// Jenkins dropped init.groovy entirely, so the agent-node reconciliation above
// never ran either — a credential helper silently disabled node management.
// Because the image copy of this script was never live (JENKINS_HOME kept a
// stale 3-node version), the breakage stayed invisible until the mount made
// this file authoritative.
//
// Class.forName + newInstance defers resolution to runtime, where the plugin is
// loaded, and the try/catch keeps any future edit here from taking the node
// definitions down with it.
def sonarToken = System.getenv('SONAR_TOKEN') ?: ''

if (!sonarToken) {
    println "WARNING: SONAR_TOKEN not set. SonarQube credential will not be created."
} else {
    try {
        def credClass = Class.forName(
            'com.cloudbees.plugins.credentials.impl.StringCredentialsImpl')
        def scopeClass = Class.forName(
            'com.cloudbees.plugins.credentials.CredentialsScope')

        def store = Jenkins.instance.getExtensionList(
            'com.cloudbees.plugins.credentials.SystemCredentialsProvider'
        )[0].getStore()

        def existing = store.getCredentials(
            Class.forName('com.cloudbees.plugins.credentials.domains.Domain').global())
        def already = existing.any { it.id == 'sonarqube-token' }

        if (already) {
            println "SonarQube credential already exists"
        } else {
            def credential = credClass.getConstructor(
                scopeClass, String, String, String
            ).newInstance(
                scopeClass.getField('GLOBAL').get(null),
                'sonarqube-token',
                'SonarQube authentication token',
                sonarToken
            )
            store.addCredentials(
                Class.forName('com.cloudbees.plugins.credentials.domains.Domain').global(),
                credential)
            println "Created SonarQube credential: sonarqube-token"
        }
    } catch (Throwable t) {
        // Never fatal: a missing plugin or an API shift must not stop Jenkins
        // from starting, and must not undo the node reconciliation above.
        println "WARNING: SonarQube credential setup skipped (${t.class.simpleName}: ${t.message})"
    }
}

// ================================================================
// 3. Reload Configuration
// ================================================================
println "Reloading Jenkins configuration..."
Jenkins.instance.reload()
println "=== init.groovy: Setup complete ==="
