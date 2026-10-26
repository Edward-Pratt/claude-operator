--!nonstrict
-- Bar widget: one dot per live session (red needs you, accent working, grey idle) and
-- the plan windows picked in its settings, tinted by pace. Renders published state
-- only; left click is a [widget.actions] default in plugin.toml.
--
-- Rings are tiny SVGs written once per (percent, colors) into the data dir and shown
-- with ui.image, colored through noctalia.getColor so they follow the theme (the
-- approach is claude-cockpit's, nightwatch75, MIT).
local shared = require("./shared.luau")

local sessions = noctalia.state.get("sessions") or {}
local accounts = noctalia.state.get("accounts") or {}
local elsewhere = noctalia.state.get("elsewhere") or {}
local usage = noctalia.state.get("usage")
local pricing = noctalia.state.get("pricing")
local open = noctalia.state.get("panel_open") == true

local MAX_DOTS = 8
local RING = 15
local DOT = { waiting = "error", busy = "primary", idle = "on_surface_variant/0.55" }
local SHOWN = {
  ["5h"] = { session = true }, ["7d"] = { weekly_all = true },
  ["5h_7d"] = { session = true, weekly_all = true },
}
local ringDir = (noctalia.pluginDataDir() or "") .. "/rings"

local function setting(key, fallback) return noctalia.getConfig(key) or fallback end

local function ringImage(percent, role)
  local fill, track = noctalia.getColor(role), noctalia.getColor("on_surface")
  if not fill or not track then return nil end
  local pct = math.max(0, math.min(100, shared.round(percent)))
  local path = `{ringDir}/ring-{pct}-{(string.gsub(fill, "#", ""))}-{(string.gsub(track, "#", ""))}.svg`
  if not noctalia.fileExists(path) then
    noctalia.mkdirAll(ringDir)
    local r, c = 14, 2 * math.pi * 14
    local arc = pct > 0 and string.format(
      '<circle cx="18" cy="18" r="%d" fill="none" stroke="%s" stroke-width="6" stroke-linecap="round" stroke-dasharray="%.2f %.2f" transform="rotate(-90 18 18)"/>',
      r, fill, c * pct / 100, c) or ""
    noctalia.writeFile(path, string.format(
      '<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 36 36"><circle cx="18" cy="18" r="%d" fill="none" stroke="%s" stroke-opacity="0.25" stroke-width="6"/>%s</svg>',
      r, track, arc))
  end
  return path
end

-- Short bar label: "5h", "7d", or the model's initial for a per-model week ("F7d").
local function shortLabel(w)
  if w.kind == "session" then return "5h" end
  if w.kind == "weekly_all" then return "7d" end
  return string.sub(w.model or "?", 1, 1) .. "7d"
end

local function limitNodes(limits, vertical)
  local mode = setting("bar_limits", "5h_7d")
  local style = setting("bar_limits_style", "ring")
  local nodes = {}
  if mode == "none" or not limits then return nodes end
  for _, w in ipairs(limits.windows or {}) do
    if mode == "all" or (SHOWN[mode] and SHOWN[mode][w.kind]) then
      local status = shared.pace(w).status
      local color = shared.paceColor(status, "on_surface")
      local kids = { ui.label({ text = shortLabel(w), fontSize = 9, color = "on_surface_variant" }) }
      if style == "ring" then
        local img = ringImage(w.percent, shared.paceColor(status, "primary"))
        if img then kids[#kids + 1] = ui.image({ path = img, width = RING, height = RING }) end
      elseif style == "bar" then
        kids[#kids + 1] = ui.progress({ progress = math.max(0, math.min(100, w.percent)) / 100,
          width = vertical and 16 or 26, height = 4, fill = shared.paceColor(status, "primary"), track = "on_surface/0.18" })
      end
      kids[#kids + 1] = ui.label({ text = `{shared.round(w.percent)}%`, fontSize = 11, color = color })
      -- Last known numbers stay visible while the token is expired, dimmed.
      local props = { gap = 3, align = "center", opacity = limits.stale and 0.5 or 1 }
      nodes[#nodes + 1] = vertical and ui.column(props, kids) or ui.row(props, kids)
    end
  end
  return nodes
end

local function tooltip(waiting)
  local rows = {}
  local function row(key, value) rows[#rows + 1] = { key = key, value = value } end
  for _, s in ipairs(sessions) do
    local d = s.d or {}
    row(d.title or s.name, s.status == "waiting" and ("needs you" .. (s.waitingFor ~= "" and (" · " .. s.waitingFor) or ""))
      or s.status == "busy" and (d.tool or "working") or "idle")
  end
  for _, r in ipairs(elsewhere) do
    row(r.title .. " (elsewhere)", r.category == "need_input" and ("needs you" .. (r.needs ~= "" and (" · " .. r.needs) or "")) or "remote")
  end
  if #rows == 0 then row("Claude", "no sessions running") end

  local limits = accounts[1] and accounts[1].limits
  if limits then
    row("Plan", shared.planName(limits.subscription, limits.tier))
    for _, w in ipairs(limits.windows or {}) do
      local value = `{shared.round(w.percent)}%`
      local left, at = shared.countdown(w.resetsAt), shared.clock(w.resetsAt)
      if left then value = `{value}  ·  {left}` .. (at and ` ({at})` or "") end
      row(w.label, value)
    end
    if limits.stale then row("Limits", `updated {shared.ago(limits.updated)} ago` .. (limits.error and ` · {limits.error}` or "")) end
  end
  if type(usage) == "table" then
    local rates = type(pricing) == "table" and pricing.rates or nil
    row("Today", `{shared.tokens(usage.todayTokens)}  ({shared.money(usage.todayCost, rates)})`)
    row("This week", `{shared.tokens(usage.weekTokens)}  ({shared.money(usage.weekCost, rates)})`)
  end
  return rows
end

local function render()
  local vertical = barWidget.isVertical()
  local busy, waiting = 0, 0
  for _, s in ipairs(sessions) do
    if s.status == "busy" then busy += 1 elseif s.status == "waiting" then waiting += 1 end
  end
  -- Remote Control sessions on other machines ring the bell but get no dot.
  for _, r in ipairs(elsewhere) do if r.category == "need_input" then waiting += 1 end end

  local children = {
    ui.glyph({ name = waiting > 0 and "bell-ringing" or setting("glyph", "headset"), size = 16,
      color = waiting > 0 and "error" or (open or busy > 0) and "primary" or "on_surface" }),
  }
  if setting("bar_style", "dots") == "counts" then
    if waiting > 0 then children[#children + 1] = ui.label({ text = tostring(waiting), fontSize = 11, fontWeight = "bold", color = "error" }) end
    if #sessions > 0 then
      children[#children + 1] = ui.label({ text = `{busy}/{#sessions}`, fontSize = 11, color = busy > 0 and "primary" or "on_surface_variant" })
    end
  else
    for i, s in ipairs(sessions) do
      if i > MAX_DOTS then
        children[#children + 1] = ui.label({ text = `+{#sessions - MAX_DOTS}`, fontSize = 10, color = "on_surface_variant" })
        break
      end
      children[#children + 1] = ui.box({ width = 7, height = 7, radius = 4, fill = DOT[s.status] or DOT.idle })
    end
  end

  local limits = limitNodes(accounts[1] and accounts[1].limits, vertical)
  if #limits > 0 and #children > 1 then
    children[#children + 1] = ui.box({ width = vertical and 10 or 1, height = vertical and 1 or 10, fill = "outline/0.6" })
  end
  for _, n in ipairs(limits) do children[#children + 1] = n end

  local props = { gap = 5, align = "center" }
  barWidget.render(vertical and ui.column(props, children) or ui.row(props, children))
  barWidget.setTooltip(tooltip(waiting))
end

noctalia.state.watch("sessions", function(v) sessions = v or {}; render() end)
noctalia.state.watch("accounts", function(v) accounts = v or {}; render() end)
noctalia.state.watch("elsewhere", function(v) elsewhere = v or {}; render() end)
noctalia.state.watch("usage", function(v) usage = v; render() end)
noctalia.state.watch("pricing", function(v) pricing = v; render() end)
noctalia.state.watch("panel_open", function(v) open = v == true; render() end)
function onConfigChanged() render() end
-- `noctalia msg plugin edward/claude-operator:widget focused click` toggles the panel.
function onIpc(event) if event == "click" then noctalia.togglePanel("edward/claude-operator:panel") end end
-- Countdowns in the tooltip and pace tints move with the clock.
function update() render() end
noctalia.setUpdateInterval(60000)
render()
