import jenkins.model.*
import hudson.model.*
import hudson.slaves.*
import jenkins.slaves.*

def masterUrl = System.getenv("JENKINS_MASTER_URL") ?: "http://chaos-master:8080"

agents = [
    "linux-x64":     ["linux", "x64", "native"],
    "linux-arm64":   ["linux", "arm64", "qemu"],
    "android-arm64": ["android", "arm64", "ndk"]
]

agents.each { name, labels ->
    def existing = Jenkins.instance.getNode(name)
    if (existing == null) {
        println "Registering agent: ${name} (labels: ${labels.join(' ')})"

        def launcher = new JNLPLauncher()
        def slave = new Slave(
            name,                  // name
            "${name} build agent", // description
            "/agent",              // remote FS root
            "1",                   // num executors
            Mode.NORMAL,           // mode
            labels.join(" "),      // labels
            launcher               // launcher
        )
        Jenkins.instance.addNode(slave)
        println "Agent ${name} registered successfully"
    } else {
        println "Agent ${name} already exists, skipping"
    }
}
