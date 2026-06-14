FROM jenkins/jenkins:lts-jdk17

# Disable setup wizard
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"
ENV CASC_JENKINS_CONFIG="/usr/share/jenkins/ref/jenkins.yaml"

# Install plugins via plugins.txt
COPY jenkins/plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Copy JCasC config
COPY jenkins/jenkins.yaml /usr/share/jenkins/ref/jenkins.yaml

# Copy Groovy init script for agent registration
COPY jenkins/init.groovy /usr/share/jenkins/ref/init.groovy.d/init.groovy
