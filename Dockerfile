FROM node:22-bookworm-slim

ARG ZIGCSS_VERSION=0.6.0-rc.1
LABEL org.opencontainers.image.title="ZigCSS" \
      org.opencontainers.image.version="${ZIGCSS_VERSION}" \
      org.opencontainers.image.source="https://github.com/vyakymenko/zigcss"

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

# ── Install docs dependencies OUTSIDE /app ───────────────────────────────────
# These live at /deps so that the bind mount at /app doesn't clobber them.
# The entrypoint creates symlinks from /app/docs/node_modules → /deps/docs/node_modules.
WORKDIR /deps
COPY package.json package-lock.json install.js index.js ./
COPY docs/package.json docs/package-lock.json ./docs/
RUN cd docs && npm ci

# ── Create cache directories for Zig volumes ────────────────────────────────
RUN mkdir -p /cache/zig-cache /cache/zig-out /cache/dot-zig-cache

WORKDIR /app

# ── Copy everything (used when running without bind mount) ───────────────────
COPY . .

# ── Entrypoint creates symlinks after bind mount ─────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5173

ENTRYPOINT ["/entrypoint.sh"]
CMD ["node", "dev.js"]
