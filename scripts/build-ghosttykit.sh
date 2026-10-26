#!/usr/bin/env bash
# Builds GhosttyKit.xcframework and Ghostty's runtime resources (themes,
# terminfo, shell integration) from the pinned vendor/ghostty submodule.
#
# Outputs:
#   vendor/ghostty/macos/GhosttyKit.xcframework
#   vendor/ghostty/zig-out/share/ghostty
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/vendor/ghostty"
ZIG="${ZIG:-/opt/homebrew/opt/zig@0.15/bin/zig}"

if [[ ! -f "$GHOSTTY/build.zig" ]]; then
  git -C "$ROOT" submodule update --init vendor/ghostty
fi

required="$(sed -n 's/.*minimum_zig_version = "\(.*\)".*/\1/p' "$GHOSTTY/build.zig.zon")"
if [[ "$("$ZIG" version)" != "$required" ]]; then
  echo "error: Ghostty needs zig $required, $ZIG is $("$ZIG" version)." >&2
  echo "       brew install zig@${required%.*} or set ZIG=/path/to/zig" >&2
  exit 1
fi

# See scripts/toolshim/libtool for why this is needed.
export PATH="$ROOT/scripts/toolshim:$PATH"

# The default install step also builds libghostty-vt, which fails to compile
# against the macOS 27 SDK with zig 0.15 and which we don't use. Let it fail
# and verify the artifacts we do need instead of trusting the exit code.
(cd "$GHOSTTY" && "$ZIG" build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native) || true

lib="$GHOSTTY/macos/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a"
symbols="$(nm -gU "$lib" 2>/dev/null || true)"
for sym in _ghostty_init _ghostty_app_new _ghostty_surface_new _FT_Init_FreeType; do
  if ! grep -q " T $sym\$" <<<"$symbols"; then
    echo "error: $sym missing from $lib" >&2
    exit 1
  fi
done
if [[ ! -f "$GHOSTTY/zig-out/share/terminfo/78/xterm-ghostty" || \
      ! -d "$GHOSTTY/zig-out/share/ghostty/themes" ]]; then
  echo "error: Ghostty resources were not installed to zig-out/share/ghostty" >&2
  exit 1
fi

echo "GhosttyKit ready: $GHOSTTY/macos/GhosttyKit.xcframework"
