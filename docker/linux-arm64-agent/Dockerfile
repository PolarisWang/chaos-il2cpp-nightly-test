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
        wget \
    && rm -rf /var/lib/apt/lists/*

# Install .NET SDK 10.0 (x64 — runs under QEMU user mode for dotnet build/MSBuild)
# Note: arm64 dotnet binaries cannot execute under QEMU user mode (ld-linux-aarch64.so.1
# not available in build context). x64 dotnet binaries work fine via QEMU binfmt.
RUN wget -q https://dot.net/v1/dotnet-install.sh -O /tmp/dotnet-install.sh && \
    chmod +x /tmp/dotnet-install.sh && \
    /tmp/dotnet-install.sh --channel 10.0 --install-dir /usr/share/dotnet && \
    ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet || true

# Install .NET SDK 8.0 (x64)
RUN /tmp/dotnet-install.sh --channel 8.0 --install-dir /usr/share/dotnet && \
    rm /tmp/dotnet-install.sh || true

# Pre-warm .NET SDK (runs under QEMU — may fail silently, that's OK)
RUN dotnet help >/dev/null 2>&1 || true

# Install SonarScanner & Allure CLI
COPY install-ci-tools.sh /tmp/install-ci-tools.sh
RUN bash /tmp/install-ci-tools.sh && rm /tmp/install-ci-tools.sh

ENV QEMU_LD_PREFIX=/usr/aarch64-linux-gnu

COPY linux-arm64-agent/docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /home/jenkins
ENTRYPOINT ["/entrypoint.sh"]
