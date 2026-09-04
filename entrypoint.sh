#!/bin/sh
set -eu

source_root=/workspace
application_root=/app
docs_root=/app/docs
dependency_root="$docs_root/node_modules"
marker="$dependency_root/.zigcss-docs-inputs.sha256"

if [ ! -d "$source_root" ] || [ -L "$source_root" ]; then
  echo "ZigCSS dev container: /workspace must be a real read-only source directory" >&2
  exit 1
fi

link_live_directory() {
  relative=$1
  source="$source_root/$relative"
  target="$application_root/$relative"
  if [ ! -d "$source" ] || [ -L "$source" ]; then
    echo "ZigCSS dev container: $relative must be a real source directory" >&2
    exit 1
  fi
  rm -rf "$target"
  ln -s "$source" "$target"
}

link_live_file() {
  relative=$1
  source="$source_root/$relative"
  target="$application_root/$relative"
  if [ ! -f "$source" ] || [ -L "$source" ]; then
    echo "ZigCSS dev container: $relative must be a regular source file" >&2
    exit 1
  fi
  rm -rf "$target"
  ln -s "$source" "$target"
}

# Keep this inventory finite. In particular, never link /workspace/docs over
# /app/docs because that would hide the isolated node_modules volume.
link_live_directory src
link_live_directory docs/public
link_live_directory docs/src
link_live_file build.zig
link_live_file build.zig.zon
link_live_file build_helpers.zig
link_live_file docs/index.html
link_live_file docs/package.json
link_live_file docs/package-lock.json

expected="$(
  cd "$docs_root"
  sha256sum package.json package-lock.json | sha256sum | awk '{print $1}'
)"
actual=
if [ -f "$marker" ] && [ ! -L "$marker" ]; then
  IFS= read -r actual < "$marker" || true
fi

if [ "$actual" != "$expected" ]; then
  echo "ZigCSS dev container: refreshing the lockfile-bound documentation dependencies"
  (
    cd "$docs_root"
    npm ci --ignore-scripts
  )
  temporary="$(mktemp "$dependency_root/.zigcss-docs-inputs.XXXXXX")"
  printf '%s\n' "$expected" > "$temporary"
  mv -f "$temporary" "$marker"
fi

exec "$@"
