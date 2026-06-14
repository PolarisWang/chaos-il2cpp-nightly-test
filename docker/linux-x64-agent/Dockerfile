FROM debian:bookworm-slim

LABEL description="chaos-il2cpp Linux x64 Native Build Agent"

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
        build-essential \
        cmake \
        ninja-build \
        git \
        python3 \
        python3-pip \
        curl \
        ca-certificates \
        unzip \
        openjdk-17-jre-headless \
    && rm -rf /var/lib/apt/lists/*

# Install SonarScanner & Allure CLI
COPY install-ci-tools.sh /tmp/install-ci-tools.sh
RUN bash /tmp/install-ci-tools.sh && rm /tmp/install-ci-tools.sh

COPY linux-x64-agent/docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /home/jenkins
ENTRYPOINT ["/entrypoint.sh"]
