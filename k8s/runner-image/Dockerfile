FROM ghcr.io/falcondev-oss/actions-runner:latest

USER root

# Build toolchain (Rust/cgo/etc need cc + linker + pkg-config + ssl headers)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        libssl-dev \
        ca-certificates \
        git \
        rsync \
        zip \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# Node.js 24
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Playwright + Chromium
RUN npx --yes playwright@latest install --with-deps chromium \
    && rm -rf /tmp/* /root/.cache /var/lib/apt/lists/*

USER runner
