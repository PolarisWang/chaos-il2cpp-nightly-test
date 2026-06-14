import jenkins.model.*

println "=== init.groovy: Delaying for Jenkins init ==="
sleep(60000)
println "=== init.groovy: Setting up agent nodes ==="

def agents = [
    [name:"linux-x64",     labels:"linux x64 native",     executors:2],
    [name:"linux-arm64",   labels:"linux arm64 qemu",     executors:1],
    [name:"android-arm64", labels:"android arm64 ndk",    executors:1],
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
  <remoteFS>/home/jenkins</remoteFS>
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
        println "Agent ${a.name} already exists"
    }
}

// Reload configuration to pick up new nodes
println "Reloading Jenkins configuration..."
Jenkins.instance.reload()
println "=== init.groovy: Agent setup complete ==="
