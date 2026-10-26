--!nonstrict
-- Sessions tab: every saved session grouped by project. Filter, sort by date or name,
-- show only the empty ones (opened and closed before a prompt), resume, preview,
-- delete one, or delete every empty one. Loaded on show and on refresh, never polled;
-- scripts/list-sessions.sh caches each transcript's summary by size and mtime.
-- Ported from claude-cockpit's Sessions tab (nightwatch75, MIT).
local shared = require("./shared.luau")
local kit = require("./kit.luau")
local M = {}
M.nav = kit.nav()

local SCRIPT = noctalia.pluginDir() .. "/scripts/list-sessions.sh"
local CACHE = (noctalia.pluginDataDir() or "/tmp") .. "/sessions"

local data = { loading = false, error = nil, projects = nil }
local search = ""
local expanded = {} -- cwd -> true
local preview = nil -- session id whose prompt preview is open
local confirmDelete = nil -- session id
local confirmClean = false
local sortBy, sortAsc = "date", false
local emptyOnly = false

-- A Claude Code worktree reads as its repo: ".../burrow/.claude/worktrees/gtk-5" -> "burrow › gtk-5".
local function basename(p)
  local repo, tree = string.match(p, "([^/]+)/%.claude/worktrees/([^/]+)/?$")
  if repo then return `{repo} › {tree}` end
  return string.match(p, "([^/]+)/?$") or p
end

-- Flat records -> { { cwd, sessions, last } }, newest first.
local function group(records)
  local by, order = {}, {}
  for _, r in ipairs(records) do
    local cwd = r.cwd ~= "" and r.cwd or "(unknown project)"
    local g = by[cwd]
    if not g then
      g = { cwd = cwd, sessions = {}, last = 0 }
      by[cwd], order[#order + 1] = g, g
    end
    r.label = r.title ~= "" and r.title or r.prompt ~= "" and (#r.prompt > 80 and string.sub(r.prompt, 1, 80) .. "…" or r.prompt)
      or `untitled · {string.sub(r.id, 1, 8)}`
    g.sessions[#g.sessions + 1] = r
    g.last = math.max(g.last, r.mtime)
  end
  return order
end

function M.load(ctx)
  if data.loading then return end
  data.loading, data.error = true, nil
  local argv = { "bash", SCRIPT, CACHE }
  for _, a in ipairs(ctx.S.accounts) do argv[#argv + 1] = a.dir end
  if #argv == 3 then argv[#argv + 1] = noctalia.expandPath("~/.claude") end
  local started = noctalia.runAsync(argv, function(r)
    data.loading = false
    local list = r.exitCode == 0 and noctalia.json.decode(r.stdout or "") or nil
    if type(list) == "table" then
      local first = data.projects == nil
      data.projects = group(list)
      -- First load: open the most recent project, so there is something to pick at once.
      if first then
        table.sort(data.projects, function(a, b) return a.last > b.last end)
        if data.projects[1] then expanded[data.projects[1].cwd] = true end
      end
    else
      data.error = "Could not list sessions" .. (r.timedOut and " (timed out)" or "")
    end
    ctx.render()
  end, 60000)
  if not started then data.loading, data.error = false, "Could not start the session lister" end
  ctx.render()
end

function M.show(ctx) if not data.projects then M.load(ctx) end end
function M.projects() return data.projects end
function M.refresh(ctx) M.load(ctx) end
function M.busy() return data.loading end
function M.closed() confirmDelete, confirmClean = nil, false end

local function liveIds(ctx)
  local ids = {}
  for _, s in ipairs(ctx.S.sessions) do ids[s.sessionId] = true end
  return ids
end

-- Deletes the transcript and its subagent dir. Only a path inside a known account's
-- projects dir, named after a session id, is ever passed to rm.
local function delete(ctx, s, done)
  local ok = string.match(s.id, "^[%x-]+$") and string.sub(s.path, 1, #s.account + 10) == s.account .. "/projects/"
    and string.sub(s.path, -#s.id - 6) == s.id .. ".jsonl"
  if not ok then done(false) return end
  local started = noctalia.runAsync({ "rm", "-rf", "--", s.path, string.sub(s.path, 1, -7) }, function(r) done(r.exitCode == 0) end)
  if not started then done(false) end
end

local function deletableEmpty(ctx)
  local running, list = liveIds(ctx), {}
  for _, g in ipairs(data.projects or {}) do
    for _, s in ipairs(g.sessions) do
      -- A running session has no prompt yet either; never pull its file away.
      if s.empty and not running[s.id] then list[#list + 1] = s end
    end
  end
  return list
end

local function cleanEmpty(ctx)
  confirmClean = false
  local list = deletableEmpty(ctx)
  local pending, failed = #list, 0
  if pending == 0 then ctx.render() return end
  for _, s in ipairs(list) do
    delete(ctx, s, function(ok)
      pending -= 1
      if not ok then failed += 1 end
      if pending == 0 then
        if failed > 0 then noctalia.notifyError("Claude Operator", `{failed} empty sessions could not be deleted`) end
        M.load(ctx)
      end
    end)
  end
end

local function resume(ctx, s)
  if s.empty then return end -- nothing to resume: claude would exit at once
  shared.resume(s.account, s.cwd, s.id)
  ctx.close()
end

local function sessionRow(ctx, s, selected, isLive)
  local meta = { os.date("%Y-%m-%d %H:%M", s.mtime // 1000), shared.ago(s.mtime) .. " ago" }
  if s.empty then meta[#meta + 1] = "empty" end
  if s.branch ~= "" then meta[#meta + 1] = s.branch end
  if s.model ~= "" then meta[#meta + 1] = s.model end
  if s.context > 0 then meta[#meta + 1] = shared.tokens(s.context) .. " context" end
  if shared.multiAccount() then meta[#meta + 1] = shared.accountLabel(s.account) end

  local md = s.cwd .. "/CLAUDE.md"
  local buttons = kit.compact(
    -- Fixed-width slot, so live and saved sessions line up.
    ui.column({ width = 14, align = "center" }, { isLive and ui.glyph({ name = "activity", size = 14, color = "primary" }) or ui.spacer({}) }),
    ui.button({ text = s.label, variant = "ghost", contentAlign = "start", flexGrow = 1, controlSize = "sm",
      selected = selected, tooltip = s.empty and "Empty session: nothing to resume" or "Resume in a terminal",
      onClick = function() resume(ctx, s) end }),
    string.sub(s.cwd, 1, 1) == "/" and kit.iconButton("brain", noctalia.fileExists(md) and "Open CLAUDE.md" or "Create CLAUDE.md",
      function() shared.openInEditor(md) end) or nil,
    kit.iconButton(preview == s.id and "eye-off" or "eye", "Preview", function()
      preview = preview ~= s.id and s.id or nil
      ctx.render()
    end),
    kit.iconButton("trash", "Delete session", function() confirmDelete = s.id; ctx.render() end)
  )
  local blocks = {
    ui.row({ gap = 6, align = "center" }, buttons),
    kit.muted(table.concat(meta, " · "), 10, { maxLines = 1 }),
  }
  if confirmDelete == s.id then
    blocks[#blocks + 1] = kit.confirmStrip("del-" .. s.id, "Delete this session's transcript for good?", "Delete", function()
      delete(ctx, s, function(ok)
        confirmDelete = nil
        if not ok then noctalia.notifyError("Claude Operator", "Could not delete the session") end
        M.load(ctx)
      end)
    end, function() confirmDelete = nil; ctx.render() end)
  end
  if preview == s.id then
    blocks[#blocks + 1] = kit.muted(s.prompt ~= "" and s.prompt or "No prompt", 11, { maxLines = 6 })
  end
  return ui.column({ key = "sess-" .. s.id, gap = 3, align = "stretch", paddingH = 20 }, blocks)
end

local function groupHeader(ctx, g, count, selected, hasLive)
  local open = expanded[g.cwd] == true
  local function toggle() expanded[g.cwd] = not open; ctx.render() end
  return ui.row({ key = "grp-" .. g.cwd, gap = 8, align = "center", onClick = toggle }, kit.compact(
    ui.glyph({ name = open and "chevron-down" or "chevron-right", size = 14, color = "on_surface_variant" }),
    ui.glyph({ name = "folder", size = 14, color = "on_surface_variant" }),
    hasLive and ui.glyph({ name = "activity", size = 14, color = "primary" }) or nil,
    ui.button({ text = basename(g.cwd), variant = "ghost", contentAlign = "start", flexGrow = 1, controlSize = "sm",
      fontSize = 13, tooltip = shared.projectPath(g.cwd), selected = selected, onClick = toggle }),
    kit.muted(`{count} · {shared.ago(g.last)} ago`, 11)
  ))
end

local function sorter(valueOf)
  return function(a, b)
    local x, y = valueOf(a), valueOf(b)
    if x == y then return false end
    if sortAsc then return x < y end
    return x > y
  end
end

local function sortButton(ctx, key, label)
  return ui.button({ key = "sort-" .. key, text = label .. (sortBy == key and (sortAsc and " ↑" or " ↓") or ""),
    variant = "ghost", controlSize = "sm", selected = sortBy == key,
    onClick = function()
      if sortBy == key then sortAsc = not sortAsc else sortBy, sortAsc = key, key == "name" end
      M.nav:reset()
      ctx.render()
    end })
end

function M.render(ctx)
  local emptyCount = 0
  for _, g in ipairs(data.projects or {}) do
    for _, s in ipairs(g.sessions) do if s.empty then emptyCount += 1 end end
  end
  local deletable = #deletableEmpty(ctx)
  local rows = {
    ui.row({ key = "sess-tools", gap = 6, align = "center" }, {
      ui.input({ key = "sess-search", value = search, placeholder = "Filter by title, prompt or path", flexGrow = 1,
        onChange = function(v) search = v; M.nav:reset(); ctx.render() end }),
      kit.iconButton("chevrons-down", "Expand all", function()
        for _, g in ipairs(data.projects or {}) do expanded[g.cwd] = true end
        ctx.render()
      end),
      kit.iconButton("chevrons-up", "Collapse all", function() expanded = {}; M.nav:reset(); ctx.render() end),
    }),
    ui.row({ key = "sess-sort", gap = 6, align = "center" }, {
      sortButton(ctx, "date", "Date"),
      sortButton(ctx, "name", "Name"),
      ui.button({ key = "sort-empty", text = `Empty ({emptyCount})`, variant = "ghost", controlSize = "sm", selected = emptyOnly,
        tooltip = "Only sessions closed before a prompt was sent",
        onClick = function() emptyOnly = not emptyOnly; M.nav:reset(); ctx.render() end }),
      ui.spacer({ flexGrow = 1 }),
      kit.iconButton("trash-x", "Delete every empty session", function() confirmClean = true; ctx.render() end, { enabled = deletable > 0 }),
    }),
  }
  if confirmClean then
    rows[#rows + 1] = kit.confirmStrip("clean", `Delete {deletable} empty sessions? Running sessions are kept.`, "Delete",
      function() cleanEmpty(ctx) end, function() confirmClean = false; ctx.render() end)
  end

  M.nav:begin()
  if data.error then
    rows[#rows + 1] = ui.label({ text = data.error, color = "error" })
  elseif not data.projects then
    rows[#rows + 1] = kit.muted("Reading sessions…")
  else
    local needle = string.lower(noctalia.string.trim(search))
    local running = liveIds(ctx)
    local shown = {}
    for _, g in ipairs(data.projects) do
      local matches = {}
      for _, s in ipairs(g.sessions) do
        local hit = needle == "" or string.find(string.lower(s.label), needle, 1, true)
          or string.find(string.lower(s.prompt), needle, 1, true) or string.find(string.lower(g.cwd), needle, 1, true)
        if hit and (not emptyOnly or s.empty) then matches[#matches + 1] = s end
      end
      if #matches > 0 then
        table.sort(matches, sorter(function(s) return sortBy == "name" and string.lower(s.label) or s.mtime end))
        shown[#shown + 1] = { g = g, matches = matches }
      end
    end
    table.sort(shown, sorter(function(e) return sortBy == "name" and string.lower(basename(e.g.cwd)) or e.g.last end))
    for _, e in ipairs(shown) do
      local g = e.g
      local hasLive = false
      for _, s in ipairs(g.sessions) do hasLive = hasLive or running[s.id] == true end
      -- While filtering, every matching project is open.
      local open = expanded[g.cwd] == true or needle ~= ""
      local sel = M.nav:add("grp-" .. g.cwd, function() expanded[g.cwd] = not expanded[g.cwd]; ctx.render() end)
      rows[#rows + 1] = groupHeader(ctx, g, #e.matches, sel, hasLive)
      if open then
        for _, s in ipairs(e.matches) do
          rows[#rows + 1] = sessionRow(ctx, s, M.nav:add("sess-" .. s.id, function() resume(ctx, s) end), running[s.id] == true)
        end
      end
    end
    if #shown == 0 then rows[#rows + 1] = kit.muted("No sessions match") end
  end
  return ui.scroll({ key = "sessions-scroll", flexGrow = 1, gap = 6, align = "stretch", revealKey = M.nav.reveal }, rows)
end

return M
