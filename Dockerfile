# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# Keep each downloadable Zig archive content-addressed. BuildKit selects only
# the stage matching TARGETARCH, so an emulated cross-platform build never
# executes a host-architecture compiler by accident.
FROM node:22.22.0-alpine@sha256:e4bf2a82ad0a4037d28035ae71529873c069b13eb0455466ae0bc13363826e34 AS zig-amd64
ADD --checksum=sha256:02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239 https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz /tmp/zig.tar.xz
RUN test "$(wc -c < /tmp/zig.tar.xz)" -eq 53733924

FROM node:22.22.0-alpine@sha256:e4bf2a82ad0a4037d28035ae71529873c069b13eb0455466ae0bc13363826e34 AS zig-arm64
ADD --checksum=sha256:958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz /tmp/zig.tar.xz
RUN test "$(wc -c < /tmp/zig.tar.xz)" -eq 49471996

ARG TARGETARCH
FROM zig-${TARGETARCH} AS development

ARG ZIGCSS_VERSION=0.7.0-rc.1
ARG ZIG_VERSION=0.15.2
ARG TARGETARCH
LABEL org.opencontainers.image.title="ZigCSS development" \
      org.opencontainers.image.version="${ZIGCSS_VERSION}" \
      org.opencontainers.image.source="https://github.com/vyakymenko/zigcss"

RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64|arm64) ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mkdir -p /usr/local/zig; \
    tar -xJf /tmp/zig.tar.xz -C /usr/local/zig --strip-components=1; \
    test "$(/usr/local/zig/zig version)" = "${ZIG_VERSION}"; \
    ln -s /usr/local/zig/zig /usr/local/bin/zig; \
    rm /tmp/zig.tar.xz

WORKDIR /app

# Seed the dependency volume from an exact lockfile without granting package
# lifecycle authority. The entrypoint revalidates this marker on every start.
RUN mkdir -p \
      /app/docs/node_modules \
      /app/bin \
      /app/zig-cache \
      /app/zig-out \
      /app/.zig-cache \
      /home/node/.cache/zig && \
    chown -R node:node /app /home/node/.cache/zig
COPY --chown=node:node package.json package-lock.json install.js index.js ./
COPY --chown=node:node docs/package.json docs/package-lock.json ./docs/
USER node
RUN cd docs && \
    npm ci --ignore-scripts && \
    sha256sum package.json package-lock.json | sha256sum | awk '{print $1}' \
      > node_modules/.zigcss-docs-inputs.sha256

# Host build products and dependency trees are excluded by .dockerignore.
COPY --chown=node:node . .
COPY --chown=root:root --chmod=0555 entrypoint.sh /entrypoint.sh

ENV NODE_ENV=development
EXPOSE 5173

ENTRYPOINT ["/entrypoint.sh"]
CMD ["node", "dev.js"]
