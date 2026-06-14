FROM debian:bookworm-slim

LABEL description="chaos-il2cpp Android ARM64 Build Agent (NDK)"

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

ENV ANDROID_NDK_ROOT=/opt/android-ndk
ENV ANDROID_NDK_VERSION=r27c

RUN curl -fsSL -o /tmp/ndk.zip \
    "https://dl.google.com/android/repository/android-ndk-${ANDROID_NDK_VERSION}-linux.zip" && \
    unzip -q /tmp/ndk.zip -d /opt && \
    mv /opt/android-ndk-${ANDROID_NDK_VERSION} ${ANDROID_NDK_ROOT} && \
    rm /tmp/ndk.zip

COPY android-arm64-agent/docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /home/jenkins
ENTRYPOINT ["/entrypoint.sh"]
