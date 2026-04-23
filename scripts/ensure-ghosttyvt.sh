#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

hash_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    sha256sum "$path" | awk '{print $1}'
  fi
}

if [[ ! -d "$PROJECT_DIR/ghostty" ]]; then
  echo "error: ghostty submodule is missing. Run ./scripts/setup.sh first." >&2
  exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
  echo "error: zig is not installed." >&2
  echo "install via: brew install zig" >&2
  exit 1
fi

GHOSTTY_SHA="$(git -C ghostty rev-parse HEAD)"
GHOSTTY_KEY="$GHOSTTY_SHA"
UNTRACKED_FILES="$(git -C ghostty ls-files --others --exclude-standard)"
if ! git -C ghostty diff --quiet --ignore-submodules=all HEAD -- || [[ -n "$UNTRACKED_FILES" ]]; then
  DIRTY_HASH="$(
    {
      printf 'head=%s\n' "$GHOSTTY_SHA"
      git -C ghostty diff --binary HEAD -- .
      if [[ -n "$UNTRACKED_FILES" ]]; then
        printf '\n--untracked--\n'
        while IFS= read -r path; do
          [[ -n "$path" ]] || continue
          printf 'path=%s\n' "$path"
          hash_file "$PROJECT_DIR/ghostty/$path"
        done <<< "$UNTRACKED_FILES"
      fi
    } | hash_stdin
  )"
  GHOSTTY_KEY="${GHOSTTY_SHA}-dirty-${DIRTY_HASH}"
fi

CACHE_ROOT="${CMUX_GHOSTTYVT_CACHE_DIR:-$HOME/.cache/cmux/ghosttyvt}"
CACHE_DIR="$CACHE_ROOT/$GHOSTTY_KEY"
CACHE_XCFRAMEWORK="$CACHE_DIR/GhosttyVt.xcframework"
CACHE_STATIC_LIB="$CACHE_XCFRAMEWORK/macos-arm64_x86_64/libghostty-vt.a"
CACHE_HEADERS_DIR="$CACHE_XCFRAMEWORK/macos-arm64_x86_64/Headers"
INCLUDES_ROOT="$PROJECT_DIR/GhosttyVtIncludes"
LOCAL_XCFRAMEWORK="$PROJECT_DIR/ghostty/zig-out/lib/ghostty-vt.xcframework"
LOCK_DIR="$CACHE_ROOT/$GHOSTTY_KEY.lock"

mkdir -p "$CACHE_ROOT"

LOCK_TIMEOUT=300
LOCK_START=$SECONDS
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  if (( SECONDS - LOCK_START > LOCK_TIMEOUT )); then
    echo "==> GhosttyVt lock stale (>${LOCK_TIMEOUT}s), removing and retrying..."
    rmdir "$LOCK_DIR" 2>/dev/null || rm -rf "$LOCK_DIR"
    continue
  fi
  echo "==> Waiting for GhosttyVt cache lock for $GHOSTTY_KEY..."
  sleep 1
done
trap 'rmdir "$LOCK_DIR" >/dev/null 2>&1 || true' EXIT

if [[ -d "$CACHE_XCFRAMEWORK" ]]; then
  echo "==> Reusing cached GhosttyVt.xcframework"
else
  echo "==> Building GhosttyVt.xcframework..."
  (
    cd ghostty
    zig build -Demit-lib-vt -Doptimize=ReleaseFast
  )

  if [[ ! -d "$LOCAL_XCFRAMEWORK" ]]; then
    echo "error: GhosttyVt.xcframework not found at $LOCAL_XCFRAMEWORK" >&2
    exit 1
  fi

  TMP_DIR="$(mktemp -d "$CACHE_ROOT/.ghosttyvt-tmp.XXXXXX")"
  mkdir -p "$CACHE_DIR"
  cp -R "$LOCAL_XCFRAMEWORK" "$TMP_DIR/GhosttyVt.xcframework"
  rm -rf "$CACHE_XCFRAMEWORK"
  mv "$TMP_DIR/GhosttyVt.xcframework" "$CACHE_XCFRAMEWORK"
  rmdir "$TMP_DIR"
  echo "==> Cached GhosttyVt.xcframework at $CACHE_XCFRAMEWORK"
fi

if [[ ! -f "$CACHE_STATIC_LIB" ]]; then
  echo "error: built GhosttyVt archive not found at $CACHE_STATIC_LIB" >&2
  exit 1
fi

if [[ ! -d "$CACHE_HEADERS_DIR" ]]; then
  echo "error: built GhosttyVt headers not found at $CACHE_HEADERS_DIR" >&2
  exit 1
fi

rm -f GhosttyVt.xcframework
echo "==> Creating symlink for libghostty-vt.a..."
ln -sfn "$CACHE_STATIC_LIB" libghostty-vt.a
echo "==> Creating symlink for GhosttyVtHeaders..."
ln -sfn "$CACHE_HEADERS_DIR" GhosttyVtHeaders
echo "==> Creating plain include mirror for GhosttyVt..."
mkdir -p "$INCLUDES_ROOT"
ln -sfn "$CACHE_HEADERS_DIR/ghostty" "$INCLUDES_ROOT/ghostty"
