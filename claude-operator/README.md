# Claude Operator

Every Claude Code session on one switchboard. The bar shows which sessions are working
and which need you, next to your plan limits. The panel lets you jump to any session's
terminal, resume old ones, follow usage and cost, and manage CLAUDE.md files and Claude
Code plugins.

Claude Operator merges [claude-cockpit](https://github.com/noctalia-dev/community-plugins/tree/main/claude-cockpit)
(nightwatch75) and [claude-sessions](https://github.com/noctalia-dev/community-plugins/tree/main/claude-sessions)
(lfdominguez) into one plugin with one data service, and fixes several bugs they had.

## Plugin

| Field | Value |
| --- | --- |
| ID | `edward/claude-operator` |
| Entries | Bar widget: `widget`; panel: `panel`; service: `service`; launcher provider: `search` |
| Launcher Prefix | `/co` |

## Requirements

- Claude Code 2.1 or newer, logged in. It writes the per-session state files this
  plugin reads, and its OAuth token gives the plan limits.
- `claude` itself, found on `PATH` or in `~/.local/bin`, for resuming sessions and the
  Plugins tab.
- `bash`, `jq` and `curl`.
- Standard tools every distribution ships: `find`, `grep`, `sed`, `awk`, `tac`, `stat`,
  `sort`, `head`, `tail`, `tr`, `xargs`, `date`, `basename`, `dirname`, `readlink`, `cat`,
  `mkdir`, `mv`, `rm`, `pgrep`, `kill`.
- `xdg-open` to open folders, transcripts and claude.ai links.
- Optional: kitty with remote control, to land on the exact tab of a session and to open
  new or resumed sessions as kitty tabs. Add to `kitty.conf` and restart kitty:

  ```conf
  allow_remote_control socket-only
  listen_on unix:@kitty-{kitty_pid}
  ```

- Optional: `hyprctl` (Hyprland, Lua or classic config), `niri` or `swaymsg` to focus a
  session's window. On other compositors everything else works.
- Optional: `code` or `zed` to open CLAUDE.md files, or set **Editor command**.

## Usage

### Bar widget

Add **Claude Operator** from the bar's widget picker. It shows:

- The glyph, which turns into a red bell while a session waits for a permission or an
  answer (on this machine or, through Remote Control, on another one).
- One dot per running session: red needs you, accent is working, grey is idle. After 8
  it shows `+N`. Set **Bar style** to *Counts* for `waiting busy/total` instead.
- The 5-hour and 7-day plan windows (pick others with **Bar limits**) as rings, bars or
  plain percentages. A window changes colour when you use it faster than the clock, and red
  at the limit. Numbers kept from before an expired token are dimmed.

Hover it for every session, the plan, each window's reset time and today's and this
week's cost. Click it to open the panel.

### Panel

```sh
noctalia msg panel-toggle edward/claude-operator:panel
```

- **Live**: plan limits, then running sessions grouped into *Needs you*, *Working* and
  *Idle*. A card shows the title, folder and branch, the tool it is running or what it
  waits for, todo progress, your last prompt, and chips for terminal, model, permission
  mode, context use, cost, subagents and last turn time. Click a card to jump to its
  terminal. Hover it, or select it with the keyboard, for its actions: open on claude.ai
  (Remote Control), open a shell there, open the folder, copy a resume command, open
  the transcript, and stop the session (click twice). *Elsewhere* lists your Remote
  Control sessions on other machines. *Recent* lists closed sessions to resume.
  **New session** starts Claude in a recent project.
- **Usage**: each plan window with its pace (how far ahead of or behind the clock you
  are) and reset time, tokens and cost for today, this week and this month, daily
  activity, and the models used this week.
- **Sessions**: every saved session, grouped by project (worktrees read as
  `repo › worktree`). Filter by title, prompt or path, sort by date or name, show only
  empty sessions. Click a session to resume it. Each row can open or create the
  project's CLAUDE.md, preview the prompt, or delete the session. The bin button deletes
  every empty session; running ones are always kept.
- **Memory**: the global `~/.claude/CLAUDE.md`, every CLAUDE.md under your home folder,
  and a row to create one for each project that has sessions but no file.
- **Plugins**: installed Claude Code plugins by marketplace, plus bare skill folders in
  `~/.claude/skills`. Enable, disable, update or uninstall a plugin; refresh or remove a
  marketplace; **Check updates** marks newer versions without installing them. The
  install box takes `plugin@marketplace`, `owner/repo`, a git URL or a path. Restart
  Claude Code to apply plugin changes.

Keys: `↑` / `↓` select a card or row (hold to repeat), `Return` activates it, `Esc`
closes. Letters always go to the text fields.

### Launcher

Type `/co` and part of a session title or project path, for example `/co burrow`. Live
sessions come first: activating one jumps to its terminal. Then Remote Control sessions
elsewhere, which open on claude.ai, then recent sessions, which resume in a terminal.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `notify_waiting` | `bool` | `true` | Notify when a session starts waiting for a permission or an answer. |
| `notify_finished` | `bool` | `true` | Notify when a session goes from working to idle. |
| `finished_min_minutes` | `int` | `2` | Only notify about finished turns at least this many minutes long. |
| `show_elsewhere` | `bool` | `true` | List your live Remote Control sessions on other machines, checked once a minute. |
| `hide_idle_hours` | `int` | `0` | Hide live sessions idle longer than this many hours. `0` shows all. |
| `recent_count` | `int` | `8` | Closed sessions offered under Recent and in the launcher. `0` turns Recent off. |
| `limits_refresh_minutes` | `int` | `5` | Minutes between plan-limit and usage refreshes (2–30). |
| `currency` | `select` | `usd` | Currency for cost estimates: `usd`, `eur`, `gbp`, `jpy`, `cny`, `chf`, `aud`, `cad`, `inr`. |
| `currency_api_url` | `string` | `https://api.frankfurter.dev/v1/latest` | Exchange-rate API for non-USD currencies. *(Advanced)* |
| `terminal` | `string` | empty | Terminal for new and resumed sessions, e.g. `ghostty`. Empty opens a kitty tab when kitty remote control is on, else Noctalia's terminal. |
| `editor_command` | `string` | empty | Command that opens a CLAUDE.md. Empty tries `code`, then `zed`. |
| `work_root` | `folder` | empty | Project paths under this folder are shown relative to it. |
| `glyph` | `glyph` | `headset` | Bar widget glyph. |
| `bar_style` | `select` | `dots` | `dots`: one dot per session. `counts`: waiting count, then busy/total. |
| `bar_limits` | `select` | `5h_7d` | Windows on the bar: `5h`, `7d`, `5h_7d`, `all` (includes per-model weeks such as Fable) or `none`. |
| `bar_limits_style` | `select` | `ring` | How each window is drawn: `ring`, `bar` or `text`. |

## IPC

```sh
# Refresh limits, usage, Recent and Remote Control now
noctalia msg plugin edward/claude-operator:service all refresh

# Switch the panel to a tab: live, usage, sessions, claudemd or plugins
noctalia msg plugin edward/claude-operator:panel all tab sessions

# Toggle the panel from the widget on the focused output (for a keybind)
noctalia msg plugin edward/claude-operator:widget focused click
```

## Notes

### What it reads

| What | Where from | How often |
| --- | --- | --- |
| Running sessions | `<config dir>/sessions/<pid>.json`, written by Claude Code. Files of crashed sessions, or whose pid was reused, are skipped. The `.key` files beside them are never read. | every 2 s, in Luau, no processes |
| Session details | The session's transcript in `<config dir>/projects/`, by `scripts/details.sh` | only when the transcript changes |
| Terminal | The session process's environment (`/proc/<pid>/environ`), checked once for `KITTY_WINDOW_ID` and `TERM_PROGRAM`. Nothing else from it is kept. | once per session |
| Accounts | `~/.claude`, plus the `CLAUDE_CONFIG_DIR` of running `claude` processes (or a dir bind-mounted over `~/.claude`, from `/proc/<pid>/mountinfo`), by `scripts/running.sh`. The account email comes from `.claude.json`. | every minute |
| Recent sessions, usage history | Transcripts in `<config dir>/projects/` | every minute / every `limits_refresh_minutes` |
| Session browser | Transcripts, summarised once per size and mtime into the data dir | when the Sessions tab opens or refreshes |
| CLAUDE.md files | Your home folder, skipping VCS, dependency and cache dirs, hidden tool dirs, Claude Code worktrees and remote mounts | when the Memory tab opens or refreshes |

### Network

- `https://api.anthropic.com/api/oauth/usage`: plan limits, every
  `limits_refresh_minutes`, with the account's own OAuth token from
  `<config dir>/.credentials.json`.
- `https://api.anthropic.com/v1/code/sessions`: your Remote Control sessions on other
  machines, once a minute per account, if `show_elsewhere` is on. This is the internal
  endpoint Claude Code uses for its own session list, not a public API, so an update
  can break it; the *Elsewhere* group then disappears and the reason goes to the log.
- The LiteLLM price table on `raw.githubusercontent.com` and the exchange-rate API, once
  a day, with no credentials.

The OAuth token is only read, never refreshed or written: Claude Code owns it. It is
passed to `curl` on stdin, so it never appears in the process list, and it never
reaches the plugin's Luau code or the log. While it is expired (Claude Code refreshes
it on its next start), the last known limits stay visible, dimmed, with their age.

### Files written

In the plugin data dir (`~/.local/state/noctalia/plugins/data/edward/claude-operator/`):
`pricing.json` (prices and exchange rates), `limits.json` (last known limits),
`accounts.json` (config dirs seen), `sessions/` (session browser cache) and `rings/`
(bar ring images). Nothing is written under `~/.claude`.

### Processes and deletes

It runs its own `scripts/` through `bash`, `kitty @`, `hyprctl`, `niri msg` or `swaymsg`
to focus windows and open tabs (window ids and pids only), `claude --resume` and
`claude plugin`, your editor, and `xdg-open`. Stopping a session sends it `kill -TERM`.
Deleting a session removes its transcript and its subagent folder, always after an
inline confirm.

### Cost

Costs are estimates from token counts and public per-model prices, for subscription
users a measure of value rather than a bill.

### Troubleshooting

- **Clicking a kitty session does not switch tabs**: kitty remote control is off for
  that kitty. Add the two lines above and restart kitty.
- **Limits are dimmed with "OAuth token expired"**: start Claude Code once; it refreshes
  the token and the next refresh picks it up.
- **Logs**: `~/.cache/noctalia/noctalia.log`, lines starting `claude-operator:`.

## License

MIT. Portions derived from claude-cockpit (nightwatch75), claude-sessions (lfdominguez)
and noctalia-v5-claudecode (jrohland), all MIT; see [LICENSE](LICENSE).
