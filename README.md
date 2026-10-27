# Codecave

A keyboard-driven terminal workspace for macOS, built on libghostty.

Currently: Ghostty terminals in vertical tabs and splits, plus the git
changes of the current project, using your Ghostty config (`~/.config/ghostty/config`), themes,
shaders and keybinds.

## Keys

Tab shortcuts are your Ghostty keybinds (defaults shown): `⌘T` new tab,
`⌘W` close, `⌘1`–`⌘8` go to tab, `⌘9` last tab, `⌃Tab` / `⌘⇧]` next,
`⌃⇧Tab` / `⌘⇧[` previous. `move_tab` and `prompt_tab_title`
work too if you bind them.

Splits use Ghostty's keybinds too: `⌘D` / `⌘⇧D` split right / down,
`⌘[` / `⌘]` previous / next split, `⌘⌥←↑↓→` go to split, `⌘⌃←↑↓→`
resize, `⌘⌃=` equalize, `⌘⇧⏎` zoom, `⌘W` closes the focused split.
Panes are Liquid Glass cards (AppKit's `NSGlassEffectView`) on a solid
background, separated by gaps; drag a gap to resize. Each card is filled
with your terminal `background`. `unfocused-split-opacity` and
`unfocused-split-fill` dim unfocused panes.

Codecave adds `⌘B` (toggle sidebar), `⌘S` (focus the tab list) and `⌘⇧E`
(focus the changes). `⇥` switches between the two in the sidebar. In
the tab list:

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

The sidebar header shows the project (git work tree or directory) of the
focused pane and its branch, so it follows `cd` and pane switches. Below
the tabs, the changes list shows `git status`: staged files, then
unstaged and untracked ones, updated as files change.

| key | action |
|---|---|
| `j` / `k` | next / previous file |
| `g` / `G` | first / last file |
| `l`, `⏎` | open the file in a split to the right |
| `t` | open the file in a new tab |
| `s` | stage / unstage |
| `y` | copy the path |
| `esc` | back to the terminal |

Files open in `$EDITOR` (`nvim` if unset), run from an interactive login
shell so your PATH applies. File icons are JetBrains' New UI icons (see
`Codecave/Resources/FileIcons/NOTICE.md`).

`⌘S` / `⌘⇧E` with the sidebar hidden peek it open; it hides again when you
return to the terminal.

## Build

Requirements: macOS 26+, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen),
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
- `Codecave/Sources/Workspace`: windows, tabs, splits and the sidebar
  (tab list and file tree).
- `Codecave/Resources/FileIcons`: file type icons.

## Debug snapshot

Debug builds can dump the rendered frame and screen text, which is handy
for checking rendering without screen-recording permission:

```sh
open -n -W --env CODECAVE_SNAPSHOT=/tmp/shot --env 'CODECAVE_SNAPSHOT_INPUT=ls' \
  --env 'CODECAVE_SNAPSHOT_ACTIONS=new_tab;@focusTabSidebar:;key:k' \
  build/Build/Products/Debug/Codecave.app
# -> /tmp/shot.png, /tmp/shot.txt (see DebugSnapshot.swift for step syntax)
```

To try Ghostty settings without editing your config, debug builds load
`CODECAVE_EXTRA_CONFIG=/path/to/file` on top of it.
