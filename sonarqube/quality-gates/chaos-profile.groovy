// chaos-il2cpp Quality Gate Definition
// Apply via SonarQube web UI → Quality Gates → Create
// This Groovy script is a reference; execute with sonar-quality-gate-api.groovy if using API automation

qualityGate {
    name "chaos-profile"
    conditions {
        // Coverage
        condition {
            metric "coverage"
            op "LT"
            threshold "60"
            period 1
        }
        // Duplications
        condition {
            metric "duplicated_lines_density"
            op "GT"
            threshold "5"
            period 1
        }
        // Reliability
        condition {
            metric "reliability_rating"
            op "GT"
            threshold "3"
        }
        // Security
        condition {
            metric "security_rating"
            op "GT"
            threshold "3"
        }
        // Maintainability
        condition {
            metric "sqale_rating"
            op "GT"
            threshold "3"
        }
    }
}
