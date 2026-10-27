# Claude Operator

A [noctalia](https://github.com/noctalia-dev) plugin that puts every Claude Code session on
one switchboard: a bar widget with a lamp per session and a gauge for your plan limits,
a panel to read replies, jump to terminals, resume sessions and see where your usage goes,
and a desktop widget for a second monitor.

![The Live tab: two sessions working, plan limits and where they are heading](claude-operator/images/live.png)

It merges [claude-cockpit](https://github.com/noctalia-dev/community-plugins/tree/main/claude-cockpit)
and [claude-sessions](https://github.com/noctalia-dev/community-plugins/tree/main/claude-sessions)
into one plugin with one data service. The plugin's own [README](claude-operator/README.md)
covers its features, requirements, settings, what it reads and what it sends over the network.

## Install

Claude Operator is submitted to the community catalog in
[noctalia-dev/community-plugins#1176](https://github.com/noctalia-dev/community-plugins/pull/1176).
Once that merges, enable it from the `community` source in noctalia's Plugins settings.

Until then, install it from this repository as a `path` source:

```sh
git clone https://github.com/Edward-Pratt/claude-operator ~/src/claude-operator
```

Add the source to `~/.local/state/noctalia/settings.toml`, then enable
`edward/claude-operator` in the Plugins settings and add the widget to your bar:

```toml
[[plugins.source]]
kind = "path"
location = "/home/you/src/claude-operator"
name = "dev"
```

## Layout

```
claude-operator/   the plugin, in the community-plugins layout (dir name = id suffix)
docs/              DESIGN.md (ownership, state contract), RESEARCH.md (the two plugins it replaces)
tests/focus.sh     window focus on every supported compositor, against stub CLIs
tools/             screenshot helpers for the panel
```

## Development

With the repo added as a `path` source, edits to `.luau` files hot-reload. Some changes
need more:

- A module added after a failed load is picked up only after `touch claude-operator/panel.luau`.
- Changes to `plugin.toml` need the plugin disabled and enabled again.
- A command that may read stdin (such as `claude`) must get `</dev/null`. Noctalia started
  from a console hands its children the login tty, and the command hangs on it.

For editor type checking, put `noctalia.d.luau` from
[noctalia-dev/official-plugins](https://github.com/noctalia-dev/official-plugins) at the
repo root. It is gitignored.

Checks and screenshots:

```sh
tests/focus.sh                     # focus paths for Hyprland, niri, sway, Umbriel and tmux
tools/screen.sh OUT.png [TAB]      # screenshot exactly the panel, opened on a secondary output
tools/shot.sh NAME [TAB]           # quicker capture, found by diffing the header strip
```

Both screenshot tools open the panel on `HDMI-A-1` by default (set `OUTPUT` to change it),
so the main display stays free. Wait for "Reloaded script" toasts to clear before taking one.

### Publishing an update

`main` is the development branch. A stable version is a `vX.Y.Z` tag, and the community catalog carries only
tagged versions. The catalog copy lives on the `claude-operator` branch of a fork of community-plugins:

1. Tag the release with update-server's `scripts/release.sh patch` (or `minor`, `major`). It sets `version` in
   `claude-operator/plugin.toml` through `.github/bump-version`, commits, tags and pushes, and
   `.github/workflows/release.yml` publishes the GitHub release.
2. Sync the fork with upstream.
3. Copy the tag's `claude-operator/` over the branch's `claude-operator/` and push.

## License

MIT, see [LICENSE](LICENSE). Portions derive from claude-cockpit (nightwatch75),
claude-sessions (lfdominguez) and noctalia-v5-claudecode (jrohland), all MIT.
