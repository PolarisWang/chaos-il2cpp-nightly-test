#!/bin/bash
# Debug CSRF agent creation
CRUMB=$(curl -s -c /tmp/cookies -u "qa004:abcd@1234" \
  "http://localhost:8080/crumbIssuer/api/xml?xpath=//crumb" | grep -oP "<crumb>\K[^<]+")
echo "Crumb: ${CRUMB}"

NODEXML='<slave><name>test-agent3</name><remoteFS>/tmp</remoteFS><numExecutors>1</numExecutors><mode>NORMAL</mode><retentionStrategy class="hudson.slaves.RetentionStrategy$Always"/><launcher class="hudson.slaves.JNLPLauncher"/></slave>'

HTTP=$(curl -s -b /tmp/cookies -u "qa004:abcd@1234" \
  -H "Content-Type: application/xml" \
  -H "Jenkins-Crumb: ${CRUMB}" \
  -d "${NODEXML}" \
  -o /dev/null -w "%{http_code}" \
  "http://localhost:8080/computer/doCreateItem" 2>/dev/null)
echo "Create result: HTTP ${HTTP}"

echo "Nodes after:"
curl -s -b /tmp/cookies -u "qa004:abcd@1234" \
  "http://localhost:8080/computer/api/json" | grep -oP '"displayName":"[^"]*"'
