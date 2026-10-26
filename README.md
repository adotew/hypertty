# Codecave

A keyboard-driven terminal workspace for macOS, built on libghostty.

Currently: Ghostty terminals in vertical tabs and splits, using your
Ghostty config (`~/.config/ghostty/config`), themes, shaders and keybinds.

## Keys

Tab shortcuts are your Ghostty keybinds (defaults shown): `⌘T` new tab,
`⌘W` close, `⌘1`–`⌘8` go to tab, `⌘9` last tab, `⌃Tab` / `⌘⇧]` next,
`⌃⇧Tab` / `⌘⇧[` previous. `move_tab` and `prompt_tab_title`
work too if you bind them.

Splits use Ghostty's keybinds too: `⌘D` / `⌘⇧D` split right / down,
`⌘[` / `⌘]` previous / next split, `⌘⌥←↑↓→` go to split, `⌘⌃←↑↓→`
resize, `⌘⌃=` equalize, `⌘⇧⏎` zoom, `⌘W` closes the focused split.
Panes are rounded cards separated by gaps; drag a gap to resize.
`unfocused-split-opacity` and `unfocused-split-fill` dim unfocused panes,
and `split-divider-color` (if set) colors the card borders.

Codecave adds `⌘B` (toggle sidebar) and `⌘S` (focus sidebar). In the
focused sidebar:

| key | action |
|---|---|
| `j` / `k` | next / previous tab |
| `g` / `G` | first / last tab |
| `1`–`9` | go to tab and focus it |
| `J` / `K` | move tab down / up |
| `n` | new tab |
| `x` | close tab |
| `r` | rename (empty resets to the shell title) |
| `l`, `⏎`, `esc` | back to the terminal |

`⌘S` with the sidebar hidden peeks it open; it hides again when you return
to the terminal.

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
- `Codecave/Sources/Workspace`: windows, tabs, splits and the sidebar.

## Debug snapshot

Debug builds can dump the rendered frame and screen text, which is handy
for checking rendering without screen-recording permission:

```sh
open -n -W --env CODECAVE_SNAPSHOT=/tmp/shot --env 'CODECAVE_SNAPSHOT_INPUT=ls' \
  --env 'CODECAVE_SNAPSHOT_ACTIONS=new_tab;@focusTabSidebar:;key:k' \
  build/Build/Products/Debug/Codecave.app
# -> /tmp/shot.png, /tmp/shot.txt (see DebugSnapshot.swift for step syntax)
```
