# Codecave

A keyboard-driven terminal workspace for macOS, built on libghostty.

Currently: one Ghostty terminal per window, using your Ghostty config
(`~/.config/ghostty/config`), themes, shaders and keybinds.

## Build

Requirements: Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen),
and the Zig version Ghostty pins (`brew install zig@0.15` for Ghostty v1.3.1).

```sh
git submodule update --init
make ghostty   # builds GhosttyKit.xcframework (~5 min the first time)
make run       # generates the Xcode project, builds and opens the app
```

## Layout

- `vendor/ghostty`: Ghostty, pinned to a release tag. libghostty's
  embedding API isn't stable, so bump it deliberately.
- `scripts/build-ghosttykit.sh`: builds the xcframework and resources.
  `scripts/toolshim/libtool` works around Xcode 27's libtool dropping
  Zig-produced archive members.
- `Codecave/Sources/Ghostty`: the libghostty embedding (runtime callbacks,
  the terminal NSView and its keyboard/IME/mouse handling).

## Debug snapshot

Debug builds can dump the rendered frame and screen text, which is handy
for checking rendering without screen-recording permission:

```sh
open -n -W --env CODECAVE_SNAPSHOT=/tmp/shot --env 'CODECAVE_SNAPSHOT_INPUT=ls' \
  build/Build/Products/Debug/Codecave.app
# -> /tmp/shot.png, /tmp/shot.txt
```
