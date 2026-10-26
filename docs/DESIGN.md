# Design

claude-operator merges nightwatch75/claude-cockpit and lfdominguez/claude-sessions
(both MIT) into one plugin. See `RESEARCH.md` for what each did and what was broken.

Target: noctalia 5.3.0, `plugin_api = 33`. Treat anything the API types mark 34+ as
unavailable until tested.

## Layout

```
claude-operator/            repo root, added to noctalia as a `path` plugin source
  docs/                     RESEARCH.md, DESIGN.md
  claude-operator/          the plugin (dir name = id suffix, community layout)
    plugin.toml
    service.luau            the only entry that reads Claude data or polls
    widget.luau             bar widget, renders state only
    desktop.luau            desktop widget, renders state only
    gauge.luau              lamp board and nested ring gauge, shared by both widgets
    panel.luau              panel shell: header, tabs, keys; one module per tab
    tab-*.luau              panel tabs: live, usage, sessions, claudemd ("Memory"), plugins
    kit.luau                ui building blocks and the keyboard selection model
    plugins.luau            `claude plugin` wrapper for the Plugins tab
    launcher.luau           /co launcher provider
    shared.luau             formatting, pace model, currency, actions
    scripts/                shell helpers the service and panel run
    translations/en.json
```

## Ownership

One service owns every data source. The widget, panel and launcher only watch state
and send commands. Nothing else polls.

| Data | How | When |
| --- | --- | --- |
| Live sessions | Luau reads `<cfg>/sessions/*.json` (`.json` suffix only, never the `.key` files), drops dead pids and reused pids (`procStart` vs field 22 of `/proc/<pid>/stat`) | every 2 s, no processes |
| Session details | `scripts/details.sh`, re-run only when the transcript's size or mtime changes | on change |
| Plan limits | `scripts/limits.sh`, token on curl's stdin, never in argv, never in Luau | every `limits_refresh_minutes`; last result persisted in the data dir |
| Pricing | `scripts/pricing.sh` writes `<data>/pricing.json`: per full model id, plus `max_input_tokens` and currency rates | once a day |
| Usage history | `scripts/usage-stats.sh`: tokens and cost per day / model from the transcripts, no network | every `limits_refresh_minutes` |
| Recent sessions | `scripts/recent.sh` | every minute, and when a session ends |
| Elsewhere | `scripts/remote.sh` (internal endpoint, token on stdin) | every minute per account, if enabled |
| Accounts | `~/.claude`, then `scripts/running.sh` for running processes' config dirs | every minute |
| Session browser, CLAUDE.md, plugins | scripts run by the panel on demand, never polled | panel open / refresh |

Never write `~/.claude/pricing-cache.json` or `~/.claude/usage-cache.json`: those are
claude-cockpit's files.

## State contract

All times are epoch milliseconds (`noctalia.nowMs()`), all costs USD. Every record that
belongs to an account carries `account`, its config dir.

```
accounts  = [{ dir, label, email, default,
               limits = { updated, stale, error, windows = [
                 { id, label, kind, model, percent, resetsAt, durationMs, severity,
                   samples = [{ t, percent }], rate, rateSpanMs } ] } }]
sessions  = [{ pid, account, sessionId, name, cwd, status, waitingFor, since,
               terminal, remote, transcript,  -- remote: claude.ai/code URL or nil
               timeline = [{ t, status }],    -- transitions in the last hour
               d = { title, mode, branch, model, context, contextMax, tool, todos,
                     prompt, cost, turnMs, agents, reply, replyCut,
                     question = [{ question, options }] } }]
             -- sorted waiting > busy > idle, then newest status change first
recent    = [{ account, sessionId, cwd, title, prompt, mtime }]
elsewhere = [{ account, id, url, title, category, needs, detail, model, context,
               maxContext, mode, branch, since }]
usage     = { updated, days = [7 weekday labels, today last], daily = [7], dailyCost = [7],
              todayTokens, todayCost, d7Tokens, d7Cost, d30Tokens, d30Cost,
              d7Messages, d7Sessions, d7Models = { [family] = tokens },
              topSessions = [{ id, cost, tokens, title, cwd }] }   -- rolling, ends today
pricing   = { updated, rates = { GBP = 0.75, ... } }   -- for currency display
index     = [{ account, id, cwd, branch, mtime, title, prompt, model, context,
               empty }]       -- every saved session, newest first; ~190 KB for 490
pins      = [cwd]                                      -- pinned projects
command   = { action = "refresh" | "open" | "reindex" | "pin", cwd?, at }  -- UI -> service
```

## Decisions

- **Context** = input + cache read + cache write of the last assistant turn (what fills
  the window). `contextMax` comes from the pricing table per model, default 200k.
- **Pace is a projection, not a deviation.** The old "N% ahead of pace" compared usage
  with burning exactly 100% by the reset, so "on pace" meant "you will max out". Now
  `shared.pace` projects the percent at reset from a burn rate (5-hour window: the last
  hour, from samples the service keeps per window and drops when `resetsAt` moves;
  weekly: the average so far, after 6 hours), the time to 100%, and the budget that
  lasts until the reset. Status: idle, early, ok, tight (85%+ or 100% only just before
  the reset), hit (100% well before), soon (within 1 h / 1 day), limit. Only soon and
  limit are red. `shared.paceText`/`paceShort` are the only wording; every surface uses
  them.
- **Usage periods** roll: today, 7 days and 30 days ending today, so the chart is never a
  lone Monday bar and nothing collides with the plan's own weekly reset.
- **Cost** is priced per full model id, falling back to the newest model of the same
  family, then to nothing (an unknown model adds no cost rather than a wrong one).
- **Expired token**: keep the last limits, set `stale`, log once per transition. The
  plugin never refreshes or writes the token; Claude Code owns it.
- **Focus**: kitty remote control first (exact tab), then walk the process tree to a
  window. Hyprland tries `hl.dsp.focus` (Lua config) before `focuswindow`.
- **Keys**: the panel captures only `up`, `down`, `Return`, `KP_Enter`, so the session
  browser's filter input keeps every letter.
- **Accounts**: data is keyed by config dir from the start; account headers and the
  account picker come later.
- **claude binary**: noctalia's environment often lacks `~/.local/bin`, so
  `shared.claudeBin()` falls back to `~/.local/bin/claude` and `~/.claude/local/claude`.

## Look

The switchboard: sessions are numbered lines with a status lamp (blinking while it needs
you); the bar and desktop widget share one lamp board and one nested ring gauge
(`gauge.luau`); every surface leads with the same status line (`kit.statusLine`).
Rings and the heatmap are SVGs in the data dir, one file per drawn state: the host may
cache images by path. The host also keeps a prop a later render leaves out, so toggled
props (opacity, border, fill) are always set explicitly.

## Efficiency

- The 2 s tick reads small JSON files in Luau and spawns nothing. State is published only
  when its JSON changed, so the widget, panel and launcher re-render on real changes, not
  every tick.
- Transcripts are only re-read when they change: details per size+mtime, the session
  browser and usage history through per-file caches in the data dir (usage: one record
  per message, de-duplicated across files at aggregation, since forks copy messages).
  Measured on 575 transcripts / 427 MB: usage 1.9 s cold, 0.33 s warm; session list
  1.8 s cold, 0.19 s warm; details 17 ms on a 29 MB transcript.
- The panel re-renders every second only on Live and Usage (ages and countdowns).
- `wm.sh` detects the compositor once and reads its window list once per script run.

## Portability

- Window focus: Hyprland, niri, sway and Umbriel (window list carries a pid); tmux panes via
  the attached client; kitty tabs via remote control. Elsewhere `focus.sh` exits 1 and the
  plugin says so. `tests/focus.sh` checks every compositor path with stub CLIs fed each
  compositor's JSON shape, plus a real tmux server; run it after touching `wm.sh` or
  `focus.sh`.
- Terminals: detected from `TERM_PROGRAM` or terminal-specific variables; new sessions open
  as kitty tabs when possible (any compositor), else through the `terminal` setting or
  Noctalia's terminal.
- Claude Code: native (`claude`) and npm (`node .../@anthropic-ai/claude-code/cli.js`)
  processes are both found.

## Credits

- claude-sessions (lfdominguez, MIT): account discovery, details, limits, remote,
  focus and launch scripts, notifications.
- claude-cockpit (nightwatch75, MIT): pid-reuse check, session browser, CLAUDE.md and
  plugin tabs, SVG rings, currency.
- jrohland/noctalia-v5-claudecode (MIT, via cockpit): pace model, plan names, usage
  token counting.
