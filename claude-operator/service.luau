--!nonstrict
-- Claude Operator service: the only entry that reads Claude Code's files or the network.
-- The widget, panel and launcher render what it publishes (shapes in docs/DESIGN.md).
--
-- Every account is a Claude config dir (~/.claude, or whatever CLAUDE_CONFIG_DIR points
-- at). Claude Code writes <dir>/sessions/<pid>.json per running session (status
-- busy|idle|waiting, waitingFor, bridgeSessionId while Remote Control is on). Those are
-- read here every 2 s without spawning anything; everything heavier runs as a script
-- only when its input changed or its interval came round.
--
-- Account discovery, notifications, limits and Remote Control are derived from
-- claude-sessions (lfdominguez, MIT); the pid-reuse check from claude-cockpit
-- (nightwatch75, MIT).
--
-- Force a refresh: noctalia msg plugin edward/claude-operator:service all refresh

local PLUGIN = noctalia.pluginDir()
local SCRIPTS = PLUGIN .. "/scripts"
local HOME = noctalia.getenv("HOME") or ""
local DEFAULT_DIR = HOME .. "/.claude"
local DATA = noctalia.pluginDataDir()
local PRICING = DATA .. "/pricing.json"
local SAVED_ACCOUNTS = DATA .. "/accounts.json"
local SAVED_LIMITS = DATA .. "/limits.json"

local TICK_MS = 2000
local SLOW_MS = 60000 -- account discovery, Recent, Remote Control
local RANK = { waiting = 0, busy = 1, idle = 2 }
local HOUR_MS, DAY_MS = 3600000, 86400000

local accounts = {} -- dir -> { dir, label, email, limits, limitsAt, limitsPending, limitsErr, remote = { list, at, pending, err } }
local details = {} -- pid -> { key, data, pending }
local terminals = {} -- pid -> terminal name; a process's environment never changes
local tracked = {} -- pid -> { status, busySince }
local current = {} -- the published, sorted live sessions
local localBridges = {} -- claude.ai/code ids of Remote Control sessions running here
local remoteSeen = {} -- remote id -> last status category, for notifications
local lastSlow = -math.huge
local recentPending, usagePending, pricingPending = false, false, false
local usageAt = -math.huge

local function cfg(key, fallback)
  local v = noctalia.getConfig(key)
  if v == nil then return fallback end
  return v
end

local function minutes(key, fallback) return (tonumber(cfg(key, fallback)) or fallback) * 60000 end

local function decode(text)
  local v = noctalia.json.decode(text or "")
  return type(v) == "table" and v or nil
end

-- Runs a script with argv, decodes its JSON stdout and hands it to done(value, result);
-- value is nil on a failed run or bad JSON. Returns false when the process did not start.
local function runJson(argv, timeoutMs, done)
  return noctalia.runAsync(argv, function(r)
    done(r.exitCode == 0 and decode(r.stdout) or nil, r)
  end, timeoutMs)
end

local function script(name, ...)
  local argv = { "bash", SCRIPTS .. "/" .. name }
  for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
  return argv
end

-- "2026-10-01T20:29:59.766+00:00" -> epoch ms, honouring the offset.
local function isoToMs(iso)
  local y, mo, d, h, mi, sec, sign, oh, om = string.match(iso or "",
    "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)[%.%d]*([%+%-]?)(%d*):?(%d*)")
  if not y then return nil end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  -- days since epoch (Howard Hinnant's days_from_civil)
  if mo <= 2 then y -= 1 end
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * ((mo + 9) % 12) + 2) // 5 + d - 1
  local days = era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
  local secs = days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
  if sign ~= "" and oh ~= "" then
    local off = tonumber(oh) * 3600 + (tonumber(om) or 0) * 60
    secs = sign == "+" and secs - off or secs + off
  end
  return secs * 1000
end

-- ── Accounts ────────────────────────────────────────────────────────────────

local function normDir(dir)
  if type(dir) ~= "string" or dir == "" then return nil end
  return (string.gsub(noctalia.expandPath(dir), "/+$", ""))
end

-- "~/.claude" -> "default", "~/.claude-work" -> "work".
local function labelFor(dir)
  if dir == DEFAULT_DIR then return "default" end
  local base = string.match(dir, "([^/]+)$") or dir
  local name = string.gsub(string.gsub(base, "^%.", ""), "^claude[%-_%.]?", "")
  return name ~= "" and name or base
end

-- Account metadata lives in .claude.json: inside the config dir, or beside ~/.claude for
-- the default one. It grows to hundreds of KB, so it is decoded only when it changed.
local function refreshEmail(a)
  local file = a.dir == DEFAULT_DIR and HOME .. "/.claude.json" or a.dir .. "/.claude.json"
  local info = noctalia.fileInfo(file)
  local stamp = info and `{info.size}:{info.mtime}` or nil
  if stamp == a.infoStamp then return end
  a.infoStamp = stamp
  local meta = decode(noctalia.readFile(file))
  a.email = meta and type(meta.oauthAccount) == "table" and meta.oauthAccount.emailAddress or nil
end

local savedLimits = decode(noctalia.readFile(SAVED_LIMITS)) or {}

local function addAccount(dir)
  dir = normDir(dir)
  if not dir or accounts[dir] or not noctalia.fileExists(dir) then return false end
  local saved = savedLimits[dir]
  if type(saved) == "table" then saved.stale = true end
  accounts[dir] = {
    dir = dir, label = labelFor(dir),
    -- Last known limits survive a restart; marked stale until the next fetch lands.
    limits = type(saved) == "table" and saved or nil,
    limitsAt = -math.huge,
    remote = { list = {}, at = -math.huge },
  }
  refreshEmail(accounts[dir])
  return true
end

-- Non-default accounts are remembered so their Recent sessions survive a restart.
local function saveAccounts()
  local dirs = {}
  for dir in pairs(accounts) do if dir ~= DEFAULT_DIR then dirs[#dirs + 1] = dir end end
  table.sort(dirs)
  noctalia.writeFile(SAVED_ACCOUNTS, noctalia.json.encode(dirs))
end

-- Known accounts: ~/.claude, dirs seen before, and (async, via running.sh) the config
-- dirs of running claude processes, including bind mounts over ~/.claude.
local function discoverAccounts()
  local added = addAccount(DEFAULT_DIR)
  for _, d in ipairs(decode(noctalia.readFile(SAVED_ACCOUNTS)) or {}) do added = addAccount(d) or added end
  for dir, a in pairs(accounts) do
    if noctalia.fileExists(dir) then refreshEmail(a) else accounts[dir] = nil; added = true end
  end
  if added then saveAccounts() end
  noctalia.runAsync(script("running.sh"), function(r)
    local found = false
    for line in string.gmatch(r.stdout or "", "[^\n]+") do found = addAccount(line) or found end
    if found then saveAccounts() end
  end, 10000)
end

-- Default first, then by label.
local function accountList()
  local list = {}
  for _, a in pairs(accounts) do list[#list + 1] = a end
  table.sort(list, function(x, y)
    if (x.dir == DEFAULT_DIR) ~= (y.dir == DEFAULT_DIR) then return x.dir == DEFAULT_DIR end
    return x.label < y.label
  end)
  return list
end

local function publishAccounts()
  local out = {}
  for _, a in ipairs(accountList()) do
    out[#out + 1] = { dir = a.dir, label = a.label, email = a.email, default = a.dir == DEFAULT_DIR, limits = a.limits }
  end
  noctalia.state.set("accounts", out)
end

-- ── Plan limits ─────────────────────────────────────────────────────────────

local WINDOW_MS = { session = 5 * HOUR_MS }

local function windowLabel(w)
  if w.kind == "session" then return "5h" end
  if w.kind == "weekly_all" then return "7d" end
  return (w.model or w.kind or "?") .. (w.group == "weekly" and " 7d" or "")
end

local function shapeLimits(raw)
  local windows = {}
  for _, w in ipairs(type(raw.windows) == "table" and raw.windows or {}) do
    if type(w) == "table" and tonumber(w.percent) then
      windows[#windows + 1] = {
        id = `{w.kind or "window"}:{w.model or ""}`, label = windowLabel(w),
        kind = w.kind, group = w.group, model = w.model,
        percent = tonumber(w.percent), resetsAt = isoToMs(w.resets_at),
        durationMs = WINDOW_MS[w.kind] or 7 * DAY_MS, severity = w.severity,
      }
    end
  end
  return { updated = noctalia.nowMs(), stale = false, subscription = raw.subscription, tier = raw.tier, windows = windows }
end

local function saveLimits()
  local out = {}
  for dir, a in pairs(accounts) do if a.limits then out[dir] = a.limits end end
  noctalia.writeFile(SAVED_LIMITS, noctalia.json.encode(out))
end

-- An expired token (Claude Code refreshes it on its next start) keeps the last limits,
-- marked stale with the reason; the reason is logged once per change, not every fetch.
local function fetchLimits(a)
  if a.limitsPending then return end
  a.limitsPending, a.limitsAt = true, noctalia.nowMs()
  local started = runJson(script("limits.sh", a.dir), 20000, function(raw, r)
    a.limitsPending = false
    local err = nil
    if raw then
      a.limits = shapeLimits(raw)
      saveLimits()
    else
      err = noctalia.string.trim(r.stderr or "")
      if err == "" then err = r.timedOut and "timed out" or `exit {r.exitCode}` end
      if a.limits then a.limits.stale, a.limits.error = true, err end
    end
    if err ~= a.limitsErr and err then noctalia.log(`claude-operator: limits ({a.label}): {err}`) end
    a.limitsErr = err
    publishAccounts()
  end)
  if not started then a.limitsPending = false end
end

-- ── Pricing and usage history ───────────────────────────────────────────────

local function publishPricing()
  local p = decode(noctalia.readFile(PRICING))
  noctalia.state.set("pricing", p and { updated = p.updated, rates = p.rates } or nil)
end

-- Once a day (the file records the date it was fetched); callback runs either way.
local function refreshPricing(done)
  local p = decode(noctalia.readFile(PRICING))
  if (p and p.updated == os.date("%Y-%m-%d")) or pricingPending then done() return end
  pricingPending = true
  local url = noctalia.string.trim(tostring(cfg("currency_api_url", "")))
  if url == "" then url = "https://api.frankfurter.dev/v1/latest" end
  local started = noctalia.runAsync(script("pricing.sh", PRICING, url), function(r)
    pricingPending = false
    for _, d in pairs(details) do d.key = nil end
    if r.exitCode ~= 0 then noctalia.log("claude-operator: pricing refresh failed: " .. noctalia.string.trim(r.stderr or "")) end
    publishPricing()
    done()
  end, 40000)
  if not started then pricingPending = false; done() end
end

local function refreshUsage()
  if usagePending then return end
  usagePending, usageAt = true, noctalia.nowMs()
  refreshPricing(function()
    local argv = script("usage-stats.sh", PRICING)
    for _, a in ipairs(accountList()) do argv[#argv + 1] = a.dir end
    local started = runJson(argv, 60000, function(usage, r)
      usagePending = false
      if usage then
        usage.updated = noctalia.nowMs()
        noctalia.state.set("usage", usage)
      else
        noctalia.log("claude-operator: usage stats failed: " .. noctalia.string.trim(r.stderr or ""))
      end
    end)
    if not started then usagePending = false end
  end)
end

-- ── Remote Control sessions elsewhere ───────────────────────────────────────

-- Every account's live Remote Control sessions, minus the ones running here.
local function publishElsewhere()
  local out, alive = {}, {}
  local on = cfg("show_elsewhere", true)
  local multi = #accountList() > 1
  for _, a in pairs(accounts) do
    for _, r in ipairs(on and a.remote.list or {}) do
      if not localBridges[r.id] then
        r.account, r.url, r.since = a.dir, "https://claude.ai/code/" .. r.id, isoToMs(r.lastEventAt) or 0
        out[#out + 1] = r
        alive[r.id] = true
        local was = remoteSeen[r.id]
        if was and was ~= "need_input" and r.category == "need_input" and cfg("notify_waiting", true) then
          noctalia.notify("Claude needs you (elsewhere)",
            (multi and `[{a.label}] ` or "") .. r.title .. (r.needs ~= "" and (": " .. r.needs) or ""))
        end
        remoteSeen[r.id] = r.category or ""
      end
    end
  end
  for id in pairs(remoteSeen) do if not alive[id] then remoteSeen[id] = nil end end
  table.sort(out, function(x, y)
    if (x.category == "need_input") ~= (y.category == "need_input") then return x.category == "need_input" end
    return x.since > y.since
  end)
  noctalia.state.set("elsewhere", out)
end

local function fetchRemote(a)
  local rem = a.remote
  if rem.pending then return end
  rem.pending, rem.at = true, noctalia.nowMs()
  local started = runJson(script("remote.sh", a.dir), 20000, function(list, r)
    rem.pending = false
    local err = nil
    if list then
      rem.list = list
    else
      err = noctalia.string.trim(r.stderr or "")
      if err == "" then err = `exit {r.exitCode}` end
    end
    if err ~= rem.err and err then noctalia.log(`claude-operator: remote sessions ({a.label}): {err}`) end
    rem.err = err
    publishElsewhere()
  end)
  if not started then rem.pending = false end
end

-- ── Live sessions ───────────────────────────────────────────────────────────

-- Which terminal hosts the session; kitty gets exact tab focusing (see focus.sh).
local function terminalOf(pid)
  local t = terminals[pid]
  if t then return t end
  local env = noctalia.readFile("/proc/" .. tostring(pid) .. "/environ") or ""
  if string.find(env, "KITTY_WINDOW_ID=", 1, true) then
    t = "kitty"
  else
    -- Plain find + anchored match: an unanchored pattern over a ~15 KB environment
    -- costs ~10 ms in the shell's runtime, enough to blow the callback budget.
    local _, e = string.find(env, "TERM_PROGRAM=", 1, true)
    t = e and string.match(env, "^[^%z]+", e + 1) or "terminal"
  end
  terminals[pid] = t
  return t
end

-- A state file whose pid now belongs to another process is a crash leftover: Claude
-- Code records the process start time (field 22 of /proc/<pid>/stat) as procStart.
local function alive(s)
  local stat = noctalia.readFile("/proc/" .. tostring(s.pid) .. "/stat")
  if not stat then return false end
  if not s.procStart then return true end
  local rest = string.match(stat, "^.*%)%s*(.*)$") or ""
  local i = 3 -- the remainder starts at field 3 (state); comm may hold spaces or parens
  for field in string.gmatch(rest, "%S+") do
    if i == 22 then return field == tostring(s.procStart) end
    i += 1
  end
  return false
end

-- Claude Code files a transcript under the dir the session started in, encoded; a
-- session that later moved (cd, worktree) has a cwd that no longer matches, so a miss
-- falls back to one search by session id, remembered for the session's lifetime.
local function findTranscript(s, d)
  if d.path and noctalia.fileExists(d.path) then return d.path end
  local guess = `{s.account}/projects/{(string.gsub(s.cwd, "[^%w]", "-"))}/{s.sessionId}.jsonl`
  if noctalia.fileExists(guess) then d.path = guess return guess end
  if not d.searching and s.sessionId:match("^[%x-]+$") then
    d.searching = true
    noctalia.runAsync({ "find", s.account .. "/projects", "-mindepth", "2", "-maxdepth", "2",
      "-name", s.sessionId .. ".jsonl", "-print", "-quit" }, function(r)
      d.searching = false
      local found = string.match(r.stdout or "", "[^\n]+")
      if found then d.path = found end
    end, 10000)
  end
  return nil
end

local function publishSessions()
  for _, s in ipairs(current) do
    local d = details[s.pid]
    s.d = d and d.data or nil
    s.transcript = d and d.path or nil
  end
  noctalia.state.set("sessions", current)
end

-- details.sh re-runs only when the transcript's size or mtime changed.
local function refreshDetails(s)
  -- Without prices the cost and context window would be cached wrong until the
  -- transcript next changes; refreshPricing re-queues every session when it lands.
  if not noctalia.fileExists(PRICING) then return end
  local d = details[s.pid] or {}
  details[s.pid] = d
  local path = findTranscript(s, d)
  local info = path and noctalia.fileInfo(path)
  if not info then return end
  local key = `{info.size}:{info.mtime}`
  if d.pending or d.key == key then return end
  d.pending = true
  local started = runJson(script("details.sh", path, PRICING), 15000, function(data)
    d.pending = false
    if data then
      d.key, d.data = key, data
      publishSessions()
    end
  end)
  if not started then d.pending = false end
end

local function readSessions(a, into)
  local dir = a.dir .. "/sessions"
  for _, name in ipairs(noctalia.listDir(dir) or {}) do
    local path = string.find(name, "/") and name or dir .. "/" .. name
    -- Only <pid>.json: the <pid>.<hash>.key files beside them hold a peer token.
    if string.match(path, "/%d+%.json$") then
      local s = decode(noctalia.readFile(path))
      if s and tonumber(s.pid) and alive(s) then
        into[#into + 1] = {
          pid = s.pid,
          account = a.dir,
          sessionId = s.sessionId or "",
          name = s.name or tostring(s.pid),
          cwd = s.cwd or "",
          status = RANK[s.status] and s.status or "idle",
          waitingFor = s.waitingFor or "",
          since = s.statusUpdatedAt or s.updatedAt or s.startedAt or 0,
          terminal = terminalOf(s.pid),
          remote = type(s.bridgeSessionId) == "string" and "https://claude.ai/code/" .. s.bridgeSessionId or nil,
        }
      end
    end
  end
end

local function label(s)
  local d = details[s.pid]
  local title = d and d.data and d.data.title or s.name
  local a = accounts[s.account]
  return #accountList() > 1 and a and `[{a.label}] {title}` or title
end

local function dur(ms)
  local m = math.floor(ms / 60000)
  if m < 60 then return `{m}m` end
  return `{m // 60}h {m % 60}m`
end

-- Notifications and bookkeeping. Returns true when a session ended (Recent is stale).
local function track(sessions)
  local seen, gone = {}, false
  for _, s in ipairs(sessions) do
    seen[s.pid] = true
    local t = tracked[s.pid]
    if t then
      if t.status ~= "waiting" and s.status == "waiting" and cfg("notify_waiting", true) then
        noctalia.notify("Claude needs you", label(s) .. (s.waitingFor ~= "" and (": " .. s.waitingFor) or ""))
      elseif t.status == "busy" and s.status == "idle" and cfg("notify_finished", true) and t.busySince then
        local took = s.since - t.busySince
        if took >= minutes("finished_min_minutes", 2) then
          noctalia.notify("Claude finished", `{label(s)} · {dur(took)}`)
        end
      end
    else
      t = {}
      tracked[s.pid] = t
    end
    if s.status == "busy" and t.status ~= "busy" and t.status ~= "waiting" then t.busySince = s.since end
    t.status = s.status
  end
  for pid in pairs(tracked) do
    if not seen[pid] then tracked[pid] = nil; details[pid] = nil; terminals[pid] = nil; gone = true end
  end
  return gone
end

local function refreshRecent()
  local count = tonumber(cfg("recent_count", 8)) or 8
  if count <= 0 then noctalia.state.set("recent", {}) return end
  if recentPending then return end
  recentPending = true
  local argv = script("recent.sh", tostring(count + 10))
  for _, a in ipairs(accountList()) do argv[#argv + 1] = a.dir end
  local started = runJson(argv, 15000, function(list)
    recentPending = false
    if not list then return end
    local live = {}
    for _, s in ipairs(current) do live[s.sessionId] = true end
    local out = {}
    for _, x in ipairs(list) do
      if not live[x.sessionId] and #out < count then out[#out + 1] = x end
    end
    noctalia.state.set("recent", out)
  end)
  if not started then recentPending = false end
end

-- ── Tick ────────────────────────────────────────────────────────────────────

local function poll()
  local now = noctalia.nowMs()
  local slow = now - lastSlow >= SLOW_MS
  if slow then lastSlow = now; discoverAccounts() end

  local sessions = {}
  for _, a in pairs(accounts) do
    readSessions(a, sessions)
    if now - a.limitsAt >= minutes("limits_refresh_minutes", 5) then fetchLimits(a) end
    if cfg("show_elsewhere", true) and now - a.remote.at >= SLOW_MS then fetchRemote(a) end
  end
  if now - usageAt >= minutes("limits_refresh_minutes", 5) then refreshUsage() end

  localBridges = {}
  for _, s in ipairs(sessions) do
    if s.remote then localBridges[string.match(s.remote, "[^/]+$")] = true end
  end
  local gone = track(sessions)

  local hideMs = (tonumber(cfg("hide_idle_hours", 0)) or 0) * HOUR_MS
  local shown = {}
  for _, s in ipairs(sessions) do
    if not (hideMs > 0 and s.status == "idle" and now - s.since > hideMs) then shown[#shown + 1] = s end
  end
  table.sort(shown, function(x, y)
    if RANK[x.status] ~= RANK[y.status] then return RANK[x.status] < RANK[y.status] end
    return x.since > y.since
  end)
  current = shown
  for _, s in ipairs(sessions) do refreshDetails(s) end
  publishAccounts()
  publishSessions()
  publishElsewhere()
  if gone or slow then refreshRecent() end
end

-- Refresh everything that runs on a timer, now.
local function refreshAll()
  lastSlow, usageAt = -math.huge, -math.huge
  for _, a in pairs(accounts) do a.limitsAt, a.remote.at = -math.huge, -math.huge end
  poll()
end

-- "refresh": the panel's refresh button. "open": the panel opened, so re-check the cheap,
-- fast-moving sources (Remote Control, Recent) without spending a plan-limits request.
noctalia.state.watch("command", function(v)
  if type(v) ~= "table" then return end
  if v.action == "refresh" then
    refreshAll()
  elseif v.action == "open" then
    lastSlow = -math.huge
    for _, a in pairs(accounts) do a.remote.at = -math.huge end
    poll()
  end
end)
function update() poll() end
function onIpc(event) if event == "refresh" then refreshAll() end end
function onConfigChanged() refreshAll() end

noctalia.mkdirAll(DATA)
publishPricing()
noctalia.setUpdateInterval(TICK_MS)
poll()
