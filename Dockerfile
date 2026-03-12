FROM node:22-bookworm-slim

# ── Install Zig ──────────────────────────────────────────────────────────────
ARG ZIG_VERSION=0.15.2
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils && \
    ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
      amd64) ZIG_ARCH=x86_64 ;; \
      arm64) ZIG_ARCH=aarch64 ;; \
      *) echo "Unsupported arch: $ARCH" && exit 1 ;; \
    esac && \
    curl -fSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
      -o /tmp/zig.tar.xz && \
    mkdir -p /usr/local/zig && \
    tar -xf /tmp/zig.tar.xz -C /usr/local/zig --strip-components=1 && \
    ln -s /usr/local/zig/zig /usr/local/bin/zig && \
    rm /tmp/zig.tar.xz && \
    apt-get purge -y curl xz-utils && apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ── Copy root package files (needed by docs' `zigcss: file:..`) ─────────────
COPY package.json package-lock.json install.js index.js ./

# ── Install docs dependencies (cached layer) ────────────────────────────────
COPY docs/package.json docs/package-lock.json ./docs/
RUN cd docs && npm ci

# ── Copy everything else ────────────────────────────────────────────────────
COPY . .

EXPOSE 5173

CMD ["node", "dev.js"]
