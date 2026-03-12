#!/bin/sh
set -e

# Create symlinks from /app subdirectories to external volume mounts.
# The bind mount at /app provides the live source code for hot-reload,
# but build artifacts and dependencies live in persistent volumes
# OUTSIDE /app so they don't get clobbered by the bind mount.

ln -sfn /deps/docs/node_modules /app/docs/node_modules
ln -sfn /cache/zig-cache        /app/zig-cache
ln -sfn /cache/zig-out           /app/zig-out
ln -sfn /cache/dot-zig-cache     /app/.zig-cache

exec "$@"
