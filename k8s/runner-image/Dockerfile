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

# GitHub CLI (used by workflow scripts that call `gh pr list`, etc)
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Node.js 24
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Playwright + Chromium
RUN npx --yes playwright@latest install --with-deps chromium \
    && rm -rf /tmp/* /root/.cache /var/lib/apt/lists/*

# Preloaded image tars — loaded into DinD by the preload-images init container
# at pod startup. Populated by build.sh. Eliminates cold-start image pulls
# under heavy parallel load. See CLAUDE.md gotcha #13.
COPY preloaded-images/ /opt/preloaded-images/

USER runner
