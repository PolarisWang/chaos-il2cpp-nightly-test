FROM jenkins/jenkins:lts-jdk17

# Disable setup wizard
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"
ENV CASC_JENKINS_CONFIG="/usr/share/jenkins/ref/jenkins.yaml"

# Install plugins via plugins.txt
COPY jenkins/plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Install Allure CLI (needed by the allure() Jenkins step which runs on master)
USER root
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*
RUN ALLURE_VERSION=2.30.0 && \
    curl -fsSL "https://github.com/allure-framework/allure2/releases/download/${ALLURE_VERSION}/allure-${ALLURE_VERSION}.tgz" -o /tmp/allure.tgz && \
    tar xzf /tmp/allure.tgz -C /opt && \
    ln -sf "/opt/allure-${ALLURE_VERSION}/bin/allure" /usr/local/bin/allure && \
    rm -f /tmp/allure.tgz
USER jenkins

# Copy JCasC config
COPY jenkins/jenkins.yaml /usr/share/jenkins/ref/jenkins.yaml

# Copy Groovy init script for agent registration
COPY jenkins/init.groovy /usr/share/jenkins/ref/init.groovy.d/init.groovy
