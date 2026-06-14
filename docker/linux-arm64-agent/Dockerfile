FROM debian:bookworm-slim

LABEL description="chaos-il2cpp Linux ARM64 Cross-Compile Build Agent (QEMU)"

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
        gcc-aarch64-linux-gnu \
        g++-aarch64-linux-gnu \
        binutils-aarch64-linux-gnu \
        qemu-user \
        binfmt-support \
        libc6-arm64-cross \
    && rm -rf /var/lib/apt/lists/*

# Install SonarScanner & Allure CLI
COPY install-ci-tools.sh /tmp/install-ci-tools.sh
RUN bash /tmp/install-ci-tools.sh && rm /tmp/install-ci-tools.sh

ENV QEMU_LD_PREFIX=/usr/aarch64-linux-gnu

COPY linux-arm64-agent/docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /home/jenkins
ENTRYPOINT ["/entrypoint.sh"]
