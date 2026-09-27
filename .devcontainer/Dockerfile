# Linux dev container for the Rust workspace (native/), the Blender extension's Python tests and
# headless Blender integration tests. The iOS app needs macOS and Xcode and can't be built here.
FROM mcr.microsoft.com/devcontainers/python:3.13-bookworm

ARG INSTALL_BLENDER=true
ARG BLENDER_VERSION=5.2.2
ARG BLENDER_SERIES=5.2

# nasm and cmake: turbojpeg-sys builds libjpeg-turbo (with x86-64 SIMD) from source.
# The X/GL libraries are the ones CI installs so headless Blender starts (ci.yml, blender-smoke).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential pkg-config cmake nasm curl xz-utils unzip \
        libx11-6 libxi6 libxxf86vm1 libxfixes3 libxrender1 libxkbcommon0 libsm6 libgl1 libegl1 \
    && rm -rf /var/lib/apt/lists/*

# Blender only publishes x86-64 Linux builds; on arm64 hosts the Blender tests stay on CI.
RUN if [ "${INSTALL_BLENDER}" = "true" ] && [ "$(dpkg --print-architecture)" = "amd64" ]; then \
        curl -fsSL -o /tmp/blender.tar.xz \
          "https://download.blender.org/release/Blender${BLENDER_SERIES}/blender-${BLENDER_VERSION}-linux-x64.tar.xz" \
        && tar -xf /tmp/blender.tar.xz -C /opt \
        && ln -s "/opt/blender-${BLENDER_VERSION}-linux-x64" /opt/blender \
        && rm /tmp/blender.tar.xz; \
    else \
        echo "Skipping Blender (INSTALL_BLENDER=${INSTALL_BLENDER}, arch $(dpkg --print-architecture))"; \
    fi

# Same pins as CI (ci.yml python job, maturin v1.15.0).
RUN pip install --no-cache-dir pytest==9.1.1 pytest-cov==7.1.0 pytest-randomly==5.0.0 ruff==0.16.9 mypy==2.3.1 maturin==1.15.0

USER vscode
# native/rust-toolchain.toml selects the channel and components (rustfmt, clippy) on first use.
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
ENV PATH="/home/vscode/.cargo/bin:${PATH}"
