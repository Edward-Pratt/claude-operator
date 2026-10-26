--!nonstrict
-- Helpers shared by the widget, panel and launcher: formatting, the pace model and the
-- actions a session card or launcher result can take. No state of its own.
--
-- pace and planName are ported from jrohland/noctalia-v5-claudecode via claude-cockpit
-- (MIT); focus, launch and resume from claude-sessions (lfdominguez, MIT).
local M = {}
local PLUGIN = noctalia.pluginDir()
local SCRIPTS = PLUGIN .. "/scripts"
local HOME = noctalia.getenv("HOME") or ""
local DEFAULT_DIR = HOME .. "/.claude"

M.HOUR_MS = 3600000
M.DAY_MS = 86400000

local function trim(v) return noctalia.string.trim(tostring(v or "")) end

-- ── Paths ───────────────────────────────────────────────────────────────────

local function workPrefix()
  local root = trim(noctalia.getConfig("work_root"))
  return root ~= "" and (string.gsub(noctalia.expandPath(root), "/+$", "") .. "/") or nil
end

-- Paths under the projects folder show relative to it, anything under $HOME as ~/...
function M.projectPath(p)
  p = p or ""
  local work = workPrefix()
  if work and string.sub(p, 1, #work) == work then return string.sub(p, #work + 1) end
  if HOME ~= "" and string.sub(p, 1, #HOME + 1) == HOME .. "/" then return "~" .. string.sub(p, #HOME + 1) end
  return p
end

function M.workRoot()
  local work = workPrefix()
  return work and string.sub(work, 1, -2) or HOME
end

function M.transcript(account, cwd, sid)
  return `{account or DEFAULT_DIR}/projects/{(string.gsub(cwd, "[^%w]", "-"))}/{sid}.jsonl`
end

-- ── Formatting ──────────────────────────────────────────────────────────────

function M.round(x) return math.floor((tonumber(x) or 0) + 0.5) end

function M.dur(s)
  s = math.max(0, math.floor(s))
  if s < 60 then return `{s}s` elseif s < 3600 then return `{s // 60}m` elseif s < 86400 then return `{s // 3600}h` end
  return `{s // 86400}d`
end

function M.ago(ms) return M.dur((noctalia.nowMs() - ms) / 1000) end

-- Time until `ms`, coarse enough for a tooltip column: "4d 2h", "3h 12m", "8m".
function M.countdown(ms)
  if not ms then return nil end
  local left = math.floor((ms - noctalia.nowMs()) / 60000)
  if left <= 0 then return "resetting" end
  if left >= 1440 then return `{left // 1440}d {left % 1440 // 60}h` end
  if left >= 60 then return `{left // 60}h {left % 60}m` end
  return `{left}m`
end

-- Wall-clock time of `ms` in the shell's time format, with the weekday when it is
-- more than a day away.
function M.clock(ms)
  if not ms then return nil end
  local fmt = "%H:%M"
  local ok, shellFmt = pcall(noctalia.timeFormat)
  local inner = ok and type(shellFmt) == "string" and string.match(shellFmt, "{:(.-)}") or nil
  if inner and inner ~= "" then fmt = inner end
  local secs = math.floor(ms / 1000)
  if ms - noctalia.nowMs() >= M.DAY_MS then fmt = "%a " .. fmt end
  return os.date(fmt, secs)
end

function M.tokens(n)
  n = tonumber(n) or 0
  if n >= 1e9 then return string.format("%.1fB", n / 1e9) end
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1e3 then return string.format("%.0fk", n / 1e3) end
  return tostring(math.floor(n + 0.5))
end

local CURRENCY = {
  usd = { "$", "" }, eur = { "", " €" }, gbp = { "£", "" }, jpy = { "¥", "" }, cny = { "CN¥", "" },
  chf = { "", " CHF" }, aud = { "A$", "" }, cad = { "C$", "" }, inr = { "₹", "" },
}

-- A USD amount in the configured currency. `rates` is the published pricing.rates; with
-- no rate yet the amount stays in USD, symbol included.
function M.money(usd, rates)
  local n = tonumber(usd) or 0
  local code = noctalia.getConfig("currency")
  local sym = CURRENCY.usd
  if CURRENCY[code] and code ~= "usd" and type(rates) == "table" then
    local rate = tonumber(rates[string.upper(code)])
    if rate and rate > 0 then n, sym = n * rate, CURRENCY[code] end
  end
  local text
  if n >= 1000 then text = string.format("%.1fk", n / 1000)
  elseif n >= 100 then text = tostring(math.floor(n + 0.5))
  elseif n >= 10 then text = string.format("%.1f", n)
  else text = string.format("%.2f", n) end
  return sym[1] .. text .. sym[2]
end

-- ── Plan and pace ───────────────────────────────────────────────────────────

local PLAN_WORDS = { free = "Free", pro = "Pro", max = "Max", team = "Team", enterprise = "Enterprise", business = "Business" }

-- "team" + "default_claude_max_5x" -> "Claude Team 5x".
function M.planName(subscription, tier)
  local function clean(v)
    if type(v) ~= "string" then return nil end
    v = string.lower(v)
    return (v ~= "" and v ~= "unknown") and v or nil
  end
  subscription, tier = clean(subscription), clean(tier)
  if not subscription and not tier then return "Claude" end
  local rest = string.gsub(string.gsub(string.gsub(tier or "", "^default_", ""), "^t%d+_", ""), "^claude_", "")
  local words, multiplier, family = {}, nil, nil
  for word in string.gmatch(rest, "[^_]+") do
    if string.match(word, "^%d+x$") then
      multiplier = word
    else
      if PLAN_WORDS[word] and not family then family = word end
      words[#words + 1] = word
    end
  end
  local plan = PLAN_WORDS[subscription or ""] or (family and PLAN_WORDS[family])
  if not plan then
    local shown = {}
    for _, w in ipairs(words) do shown[#shown + 1] = string.upper(string.sub(w, 1, 1)) .. string.sub(w, 2) end
    plan = #shown > 0 and table.concat(shown, " ") or subscription
  end
  local parts = { "Claude" }
  if plan and plan ~= "" then parts[#parts + 1] = plan end
  if multiplier then parts[#parts + 1] = multiplier end
  return table.concat(parts, " ")
end

M.PACE_MARGIN = 5
M.SEVERITY = { unknown = 0, under = 0, on = 0, over = 1, over_quota = 2 }

-- Is the window being used faster than the clock? Windows are treated as fixed-length
-- with elapsed time derived from the reset time: an approximation of the rolling
-- limits, good enough as a cue. The service's own `severity` wins when it is worse.
function M.pace(w)
  local util = tonumber(w.percent) or 0
  local p
  if not w.resetsAt then
    p = util >= 100 and { timeFrac = 1, delta = util, status = "over_quota" } or { status = "unknown" }
  else
    local dur = w.durationMs or 7 * M.DAY_MS
    local frac = math.max(0, math.min(1, (dur - (w.resetsAt - noctalia.nowMs())) / dur))
    local delta = util - frac * 100
    local status = util >= 100 and "over_quota" or delta >= M.PACE_MARGIN and "over"
      or delta <= -M.PACE_MARGIN and "under" or "on"
    p = { timeFrac = frac, delta = delta, status = status }
  end
  local vendor = w.severity == "critical" and "over_quota" or w.severity == "high" and "over" or nil
  if vendor and M.SEVERITY[vendor] > M.SEVERITY[p.status] then p.status = vendor end
  return p
end

function M.paceLabel(p)
  if p.status == "over_quota" then return "limit reached" end
  if p.status == "over" then return `{M.round(p.delta)}% ahead of pace` end
  if p.status == "under" then return `{M.round(-p.delta)}% under pace` end
  if p.status == "on" then return "on pace" end
  return nil
end

function M.paceColor(status, calm)
  if status == "over_quota" then return "error" end
  if status == "over" then return "tertiary" end
  return calm
end

-- ── Accounts ────────────────────────────────────────────────────────────────

function M.accounts() return noctalia.state.get("accounts") or {} end

function M.multiAccount() return #M.accounts() > 1 end

function M.accountLabel(dir)
  for _, a in ipairs(M.accounts()) do if a.dir == dir then return a.label end end
  return dir and (string.match(dir, "([^/]+)$") or dir) or "default"
end

-- ── Actions ─────────────────────────────────────────────────────────────────

function M.quote(s) return "'" .. string.gsub(s, "'", "'\\''") .. "'" end

-- The claude binary. Noctalia's environment often lacks ~/.local/bin, where the native
-- installer puts it, so look there and in the older ~/.claude/local before giving up.
function M.claudeBin()
  if noctalia.commandExists("claude") then return "claude" end
  for _, p in ipairs({ HOME .. "/.local/bin/claude", HOME .. "/.claude/local/claude" }) do
    if noctalia.fileExists(p) then return p end
  end
  return nil
end

-- argv running claude (plus args) under the given account.
function M.claudeArgv(account, ...)
  local argv = {}
  if account and account ~= DEFAULT_DIR then argv = { "env", "CLAUDE_CONFIG_DIR=" .. account } end
  argv[#argv + 1] = M.claudeBin() or "claude"
  for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
  return argv
end

function M.open(target) return noctalia.runAsync({ "xdg-open", target }) end

-- Brings the session's terminal to the front (the exact kitty tab when kitty remote
-- control is on). A Remote Control session with no window, e.g. a headless
-- `claude remote-control`, opens on claude.ai instead.
function M.focus(s)
  noctalia.runAsync({ "bash", SCRIPTS .. "/focus.sh", tostring(s.pid) }, function(r)
    if r.exitCode ~= 0 and s.remote then M.open(s.remote) end
  end, 10000)
end

-- A configured terminal is wired the way the host does it: `<term> -e sh -lc <cmd>`,
-- with `--` for the GTK terminals that need it.
local function inTerminal(cmd)
  local term = trim(noctalia.getConfig("terminal"))
  if term == "" then return noctalia.runInTerminal(cmd) end
  local bin = string.match(string.match(term, "^%S+") or term, "([^/]+)$") or term
  local sep = (bin == "gnome-terminal" or bin == "kgx" or bin == "ptyxis") and "--" or "-e"
  return noctalia.runAsync(term .. " " .. sep .. " sh -lc " .. M.quote(cmd))
end

-- Runs argv (or a shell when empty) in dir: a new tab in the most recently focused kitty
-- when no terminal is configured and kitty remote control is on, else in a terminal.
function M.launch(dir, argv)
  argv = argv or {}
  local function fallback()
    local words = {}
    for _, a in ipairs(argv) do words[#words + 1] = M.quote(a) end
    local run = #words > 0 and table.concat(words, " ") or "exec \"${SHELL:-sh}\""
    inTerminal(`cd {M.quote(dir)} && {run}`)
  end
  if trim(noctalia.getConfig("terminal")) ~= "" then return fallback() end
  local cmd = { "bash", SCRIPTS .. "/launch.sh", dir }
  for _, a in ipairs(argv) do cmd[#cmd + 1] = a end
  if not noctalia.runAsync(cmd, function(r) if r.exitCode ~= 0 then fallback() end end, 15000) then fallback() end
end

function M.resume(account, cwd, sid) M.launch(cwd, M.claudeArgv(account, "--resume", sid)) end

function M.resumeCommand(account, cwd, sid)
  local env = account and account ~= DEFAULT_DIR and `CLAUDE_CONFIG_DIR={M.quote(account)} ` or ""
  return `cd {M.quote(cwd)} && {env}claude --resume {sid}`
end

-- The configured editor, else the first of code / zed that is installed. No $EDITOR
-- fallback: that is usually a terminal editor, which fails without a tty.
function M.openInEditor(path)
  local configured = trim(noctalia.getConfig("editor_command"))
  local bin = configured ~= "" and configured
    or noctalia.commandExists("code") and "code" or noctalia.commandExists("zed") and "zed" or nil
  if not bin then
    noctalia.notifyError("Claude Operator", "No editor found: set Editor command in the plugin settings.")
    return false
  end
  local argv = {}
  for word in string.gmatch(bin, "%S+") do argv[#argv + 1] = word end
  argv[#argv + 1] = path
  return noctalia.runAsync(argv)
end

-- Ask the service to refresh everything now (the panel's refresh button).
function M.requestRefresh(action)
  noctalia.state.set("command", { action = action or "refresh", at = noctalia.nowMs() })
end

return M
