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
    panel.luau              panel shell: header, tabs, keys; one module per tab
    tab-*.luau              panel tabs
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
                 { id, label, kind, model, percent, resetsAt, durationMs, severity } ] } }]
sessions  = [{ pid, account, sessionId, name, cwd, status, waitingFor, since,
               terminal, remote,            -- remote: claude.ai/code URL or nil
               d = { title, mode, branch, model, context, contextMax, tool, todos,
                     prompt, cost, turnMs, agents } }]
             -- sorted waiting > busy > idle, then newest status change first
recent    = [{ account, sessionId, cwd, title, prompt, mtime }]
elsewhere = [{ account, id, url, title, category, needs, detail, model, context,
               maxContext, mode, branch, since }]
usage     = { updated, daily = [7], dailyCost = [7], todayTokens, todayCost,
              weekTokens, weekCost, monthTokens, monthCost, weekMessages,
              weekSessions, weekModels = { [family] = tokens } }
pricing   = { updated, rates = { GBP = 0.75, ... } }   -- for currency display
command   = { action = "refresh", at }                 -- panel -> service
```

## Decisions

- **Context** = input + cache read + cache write of the last assistant turn (what fills
  the window). `contextMax` comes from the pricing table per model, default 200k.
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

## Credits

- claude-sessions (lfdominguez, MIT): account discovery, details, limits, remote,
  focus and launch scripts, notifications.
- claude-cockpit (nightwatch75, MIT): pid-reuse check, session browser, CLAUDE.md and
  plugin tabs, SVG rings, currency.
- jrohland/noctalia-v5-claudecode (MIT, via cockpit): pace model, plan names, usage
  token counting.
