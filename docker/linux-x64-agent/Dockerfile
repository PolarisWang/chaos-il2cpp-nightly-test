FROM debian:trixie-slim

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
        openjdk-21-jre-headless \
        libnuma1 \
        nodejs \
        npm \
        wget \
    && rm -rf /var/lib/apt/lists/*

# Install .NET SDK 10.0
RUN wget -q https://dot.net/v1/dotnet-install.sh -O /tmp/dotnet-install.sh && \
    chmod +x /tmp/dotnet-install.sh && \
    /tmp/dotnet-install.sh --channel 10.0 --install-dir /usr/share/dotnet && \
    ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet && \
    dotnet --version

# Install .NET SDK 8.0 (needed by TPG TestProjectGenerator net8.0 target)
RUN /tmp/dotnet-install.sh --channel 8.0 --install-dir /usr/share/dotnet && \
    dotnet --list-runtimes | grep "8\.0" && \
    rm /tmp/dotnet-install.sh

RUN npm install -g @anthropic-ai/claude-code && claude --version

# Install SonarScanner & Allure CLI
COPY install-ci-tools.sh /tmp/install-ci-tools.sh
RUN bash /tmp/install-ci-tools.sh && rm /tmp/install-ci-tools.sh

COPY linux-x64-agent/docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /home/jenkins
ENTRYPOINT ["/entrypoint.sh"]
