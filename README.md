# workspaces

Workspace identity for an [Omarchy](https://omarchy.org) 4 desktop that runs
tmux in every terminal. The idea is one name for one piece of work: the tmux
session is named after the Hyprland workspace it lives on, the name is hashed
to a colour with [colorhash](https://github.com/interslice-systems/colorhash),
and the same pill shows up in the top bar, in the tmux status line, and (with
[operator](https://github.com/interslice-systems/operator)) on a macropad's
LEDs. Rename in any one place and the others follow. Links opened from inside
a session land in a Firefox tab group named and coloured after that session.

Three parts, all in this repo:

- **a bar widget** (`Workspaces.qml` and friends) — the host capsule doubles as
  the Omarchy menu button, then one entry per workspace as `id·name`, the
  focused one a filled pill in its colorhash colour, urgent ones with a bell.
  Right-click a workspace for its window menu; SUPER+ALT+N opens a rename
  dialog with a live preview of the pill you are about to get.
- **`bin/`** — the scripts the widget, the keybinds, and tmux hooks call.
- **`lib/`** — the shared name/colour contract they all source.

Built for one desk. Shared in case it's useful on yours. No warranty, no
promises, no roadmap — but if it breaks in an interesting way, an issue is
welcome.

## Requires

- Omarchy 4 (the QML uses Omarchy's own shell components; it will not run on
  Omarchy 3 or bare Quickshell), Hyprland, `jq`
- tmux, with the status bar reading the `@wsid_*` options this writes (ours is
  in the author's dotfiles; the option names are documented in
  `bin/wsid-tmux-colors`)
- [colorhash](https://github.com/interslice-systems/colorhash) installed per
  its README, so `~/.config/colorhash/palette.json` exists. Without it every
  script still works; the bar falls back to the theme foreground and tmux to
  ANSI colours.
- For `ws-open`: Firefox and
  [omarchy-firefox-bridge](https://github.com/interslice-systems/omarchy-firefox-bridge)
  for the tab-group routing. Without the bridge, links fall through to plain
  Firefox.

## Install

```sh
omarchy plugin add https://github.com/interslice-systems/workspaces --enable
R=~/.config/omarchy/plugins/interslice.workspaces
mkdir -p ~/.local/bin ~/.local/lib
for f in "$R"/bin/*; do ln -sfn "$f" ~/.local/bin/; done
ln -sfn "$R"/lib/workspace-identity-lib ~/.local/lib/
ln -sfn "$R"/lib/ws-browser-lib.bash   ~/.local/lib/
```

The scripts source the lib from `~/.local/lib` and read
`~/.config/colorhash/palette.json`. tmux picks up the colours if your status
bar calls `~/.local/bin/wsid-tmux-colors` — ours does, guarded so a box
without it keeps its plain colours:

```tmux
if-shell -b "test -x ~/.local/bin/wsid-tmux-colors" {
	run-shell -b ~/.local/bin/wsid-tmux-colors
	set-hook -g window-renamed 'run-shell -b "~/.local/bin/wsid-tmux-colors -w \"#{hook_window}\" -n \"#{hook_window_name}\""'
	set-hook -g window-linked  'run-shell -b "~/.local/bin/wsid-tmux-colors -w \"#{hook_window}\" -n \"#{hook_window_name}\""'
	set-hook -ag session-renamed 'run-shell -b ~/.local/bin/wsid-tmux-colors'
}
if-shell -b "test -x ~/.local/bin/ws-rename-workspace" {
	set-hook -g session-renamed 'run-shell -b "~/.local/bin/ws-rename-workspace \"#{hook_session_name}\""'
}
```

Keybinds, in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + RETURN", "Tmux (ws-attach)", os.getenv("HOME") .. "/.local/bin/ws-attach")
o.bind("SUPER + ALT + N",      "Rename workspace", os.getenv("HOME") .. "/.local/bin/ws-rename")
```

URL routing is opt-in: install a desktop entry whose `Exec` is
`~/.local/bin/ws-browser %u` with `MimeType=x-scheme-handler/http;x-scheme-handler/https;`,
and point `~/.config/mimeapps.list` at it. Nothing runs `ws-open` unless a
machine's mimeapps says so.

## ws-blackbox (optional): remember what disappeared

`bin/ws-blackbox` records every tmux window, its panes, and the Claude Code session in each
pane once a minute (a systemd user timer; nothing stays resident). When a window or a whole
workspace disappears -- closed, crashed, OOM-killed, rebooted -- the bar keeps it: a greyed
`gone` row in the workspace menu, or an outlined pill for a vanished workspace. ↺ rebuilds it
and **types** `claude --resume <id>` at the prompt without pressing Enter; ✕ forgets it.

```sh
ln -sfn "$R"/bin/ws-blackbox ~/.local/bin/
for u in "$R"/systemd/*; do ln -sfn "$u" ~/.config/systemd/user/; done
systemctl --user daemon-reload && systemctl --user enable --now ws-blackbox.timer
ws-blackbox status   # is it recording
ws-blackbox what     # what is gone, why (journald), and the resume lines
```

State lives in `~/.local/state/ws-blackbox/` (0700). It stores window names, working
directories, Claude session ids and short command names -- never full command lines. Nothing
is pruned automatically: an entry leaves only when you dismiss or restore it. Without the
timer installed the widget looks exactly as it did.

Workspace restore asks Hyprland to launch the terminal, so the terminal (and any tmux server
it starts) is Hyprland's child whoever ran the restore. `ws-blackbox` itself only ever talks
to tmux with `-N`, never renames or switches sessions, and never sends Enter.

## The commands

| Command | What it does |
|---|---|
| `ws-attach` | Open or focus the terminal+tmux pair for the active workspace. The session name is derived from the workspace name; an existing local terminal is found by tmux client ancestry |
| `ws-rename` | Rename the active workspace through its tmux session when one is attached here. With no args it summons the bar's rename dialog and falls back to `omarchy-menu-input` when the shell is down; `--apply <raw>` is the dialog's callback |
| `ws-rename-workspace <session>` | Mirror a tmux session rename onto the Hyprland workspace it lives on. Wired to tmux's `session-renamed` hook |
| `ws-name-suggest` | Print a candidate name for the active workspace (the git repo containing the focused pane's cwd), for the dialog to prefill |
| `ws-open <url>` | Route an http(s) URL to the Firefox window on the workspace of the tmux session it came from, into a tab group named and coloured after that session. No session, plain Firefox |
| `ws-browser` | The browser-facing adapter behind the desktop entry: normal or private launch, or hand off to `ws-open` |
| `wsid-tmux-colors` | Stamp colorhash colours into tmux user options (`@wsid_ok`, host, per-session, per-window) |
| `tmux-local-clients` | JSON of tmux sessions attached from local terminal windows, resolved by process ancestry (kitty, foot, ghostty) |
| `tmux-rename [window\|session]` | Rename the current tmux window or session in a popup |

`lib/workspace-identity-lib` owns `wsid_session_name` (the one sanitizer every
path uses), `wsid_reject_name`, and the colorhash accessors. Names are stored
exactly; NFC normalization is only for the hash.

## The widget

| Action | Result |
|---|---|
| Left click on the host capsule | Omarchy menu |
| Right click on the host capsule | a terminal |
| Left click on a workspace | focus it |
| Right click on a workspace | its window menu (`WsMenu.qml`) |
| `omarchy-shell shell summon interslice.workspaces` | the rename dialog (what `ws-rename` calls) |

The widget reads `~/.config/colorhash/palette.json` through a `FileView`, so
swapping the palette recolours the bar live. Urgency comes straight from
Hyprland's per-window urgent hint (a BEL in any terminal on the workspace),
and clears when you focus the workspace.

## Tests

```sh
for t in test/test-*; do bash "$t"; done
/usr/lib/qt6/bin/qmltestrunner -input tests/tst_WorkspaceMenuModel.qml
```

Every suite is hermetic — hyprctl, tmux, the prompt and the notifier are all
stubbed — except that the two colour suites read the installed palette and
skip when it is absent. `test/test-ws-blackbox` runs a real tmux, but on a private
server (`TMUX_TMPDIR` points at a temp dir, and the suite checks the socket path
before touching anything). `tests/tst_WorkspaceMenuModel.qml` is a Qt Quick Test
for the window-menu model.

## Known behaviour

- Editing through a symlinked plugin folder needs `omarchy restart shell`;
  the shell's file watcher does not follow the symlink and a first-compile
  error sticks in Qt's cache until a restart.
- Hyprland permits two workspaces with the same name. `ws-rename` refuses
  that, because two workspaces would then fight over one tmux session.

## License

MIT. See `LICENSE`.
