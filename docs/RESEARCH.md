# Research: the two Claude plugins this one replaces

Researched 2026-10-26 against noctalia 5.3.0 (plugin_api 33) and Claude Code 2.1.310.
Installed copies live in `~/.local/state/noctalia/plugins/materialized/community/`.
API types: `noctalia.d.luau` from noctalia-dev/official-plugins (documents API 39+;
anything marked API 34+ is unavailable on 5.3.0 until tested).

## nightwatch75/claude-cockpit 1.1.3 (MIT, plugin_api 33)

Entries: `widget` (bar), `panel` (700x720, 5 tabs), `service`.

- Service runs `get-claude-usage --json` every `usage_refresh_interval` minutes (2-15)
  and polls `live-claude-sessions` every 2 s while someone stamps `live_wanted_at`.
- Live tab: running sessions by waiting / busy / idle, title, branch, last prompt,
  model, context, cost; click focuses the terminal (`focus-claude-session`: walks
  ancestors, niri / Hyprland / Umbriel).
- Usage tab: plan windows with pace model (over/under the clock), tokens, cost,
  daily activity, models. `get-claude-usage` is vendored from jrohland/claudecode (MIT).
- Sessions tab: every past session grouped by project, sort by date/name, filter,
  keyboard nav (`revealKey`), resume in terminal, delete one / delete all empty.
- CLAUDE.md tab: every CLAUDE.md under $HOME, opened in `code`/`zed`.
- Skills/Mods tab: drives `claude plugin` (install, update, enable, uninstall,
  marketplaces) plus bare `~/.claude/skills` folders.
- Bar widget: activity mode (dot per session + SVG rings written to the data dir) or
  classic (glyph + `sNN% wNN%`), pace-tinted.
- Single account only (`~/.claude`). Cost currency conversion (Frankfurter API).

## lfdominguez/claude-sessions 1.6.3 (MIT, plugin_api 24)

Entries: `bar`, `panel` (560x640), `poller` (service), `search` launcher (`/cs`).

- Multi-account: every config dir (`CLAUDE_CONFIG_DIR`, bind mounts via mountinfo,
  `config_dirs`, `workspace_dirs`), remembered in `accounts.json`.
- Live sessions every 2 s; per-session details from `details.sh` (current tool, todos,
  permission mode, subagents, turn time) re-read on transcript mtime change.
- Notifications: "needs you" and "finished" (turns longer than N minutes).
- Remote Control: `remote` chip, open on claude.ai; "Elsewhere" sessions from the
  internal `/v1/code/sessions` endpoint, polled once a minute per account.
- Recent sessions (resume), new session picker, stop session (double-click kill),
  copy resume command, open transcript / folder / shell.
- Focus: kitty remote control lands on the exact tab, else walks to the window
  (Hyprland / niri / sway). New and resumed sessions open as kitty tabs.
- Plan limits from claude-dashboard's cache or `limits.sh` (token on curl stdin).
- Bar: dots or counts, limits as bar or 9x9 box ring, per account.

## Bugs and weak spots found

1. **Token in argv.** `get-claude-usage` runs `curl -H "Authorization: Bearer $token"`,
   visible in `ps`. `limits.sh` does it right (`-K -` on stdin).
2. **Expired token.** claude-sessions logs "OAuth token expired" every minute (14 hits
   in the current log) and the limits go stale; cockpit sends the expired token anyway
   and silently falls back to its stale cache. Neither shows staleness clearly.
3. **Hidden coupling.** claude-sessions prices sessions from `~/.claude/pricing-cache.json`,
   which only cockpit writes: disable cockpit and costs vanish. Its costs are always `$`
   while cockpit honours the `gbp` setting, so the two panels disagree.
4. **Pricing by family.** Both collapse every `claude-opus-*` to the latest Opus price.
   Transcripts here contain opus-4-7, opus-4-8, opus-5 and opus-5-5. claude-sessions'
   `cost.jq` also prices unknown families (e.g. mythos) as Opus.
5. **Fixed context window.** claude-sessions uses a 1M `context_window` setting for every
   model; LiteLLM's `max_input_tokens` gives the real one per model.
6. **Two definitions of context.** cockpit: input + cache read + cache write.
   claude-sessions: the same plus output tokens.
7. **Slow Sessions tab.** `list-claude-sessions` takes 6.6 s for 489 sessions (~6
   processes per file, no cache). `recent.sh` takes 0.1 s.
8. **CLAUDE.md scan.** `find-claude-md` walks all of $HOME (1.7 s, 87 hits) and includes
   `.claude/worktrees` copies.
9. **Duplicate work.** Two services poll `~/.claude/sessions` every 2 s, two transcript
   parsers, two clocks hitting `api/oauth/usage`.
10. **Focus order.** The two focus scripts try the Hyprland dispatch syntaxes in opposite
    order; this machine runs a Lua config (`hyprland.lua`), so `hl.dsp.focus` first.
11. **Key capture vs input.** claude-sessions captures `n`, `r`, `1`-`9` panel-wide;
    a merged panel with a filter input would lose those keystrokes.
12. **Never read** `~/.claude/sessions/*.key`: they hold `peerToken`.

## Measurements (this machine)

| Script | Time |
| --- | --- |
| `get-claude-usage --json` (cached limits) | 0.96 s |
| `list-claude-sessions` (489 sessions) | 6.6 s |
| `live-claude-sessions` (2 live) | 0.03 s |
| `recent.sh 18` | 0.10 s |
| `find-claude-md ~` | 1.7 s |

`~/.claude/projects` is 427 MB, 490 sessions, 575 transcripts touched in 31 days.

## Current bar setup

`settings.toml`: cockpit widget in `bar.default.end`, claude-sessions as `widget.bar_2`
in `bar.default.start`. Cockpit `currency = "gbp"`. kitty has remote control on
(`allow_remote_control socket-only`, `listen_on unix:@kitty-{kitty_pid}`).
