--!nonstrict
-- Usage tab: each plan window with where the current rate takes it by the reset, then
-- token use and estimated cost (today, 7 days, 30 days), the last 7 days day by day,
-- the costliest sessions and the models used. Layout after claude-cockpit (nightwatch75,
-- MIT) and jrohland/noctalia-v5-claudecode (MIT); the projection model is new.
local shared = require("./shared.luau")
local kit = require("./kit.luau")
local M = {}

local hoveredDay = nil

function M.opened() hoveredDay = nil end

local function windowTitle(w)
  if w.kind == "session" then return "5-hour session" end
  if w.model then return `{w.model} · weekly` end
  return "Weekly · all models"
end

local function windowCard(w)
  local p = shared.pace(w)
  local color = shared.paceColor(p.status, "primary")
  local headline, detail = shared.paceText(w, p)
  local right = p.status == "idle" and kit.muted("idle", 13)
    or ui.label({ text = `{shared.round(w.percent)}%`, fontSize = 18, fontWeight = "bold", color = color })
  local rows = {
    ui.row({ align = "center", gap = 8 }, {
      kit.heading(windowTitle(w)),
      ui.spacer({ flexGrow = 1 }),
      right,
    }),
    kit.paceBar(p, color, 8, true),
    ui.label({ text = headline, fontSize = 12, color = color == "primary" and "on_surface" or color, maxLines = 1 }),
  }
  if detail then rows[#rows + 1] = kit.muted(detail, 11, { maxLines = 1 }) end
  return kit.card(rows, { gap = 6 })
end

local function metric(label, tokens, cost, rates)
  return ui.column({ gap = 2, align = "center", flexGrow = 1 }, {
    kit.muted(label, 11),
    ui.label({ text = shared.money(cost, rates), fontSize = 17, fontWeight = "bold", color = "primary" }),
    kit.muted(shared.tokens(tokens) .. " tokens", 11),
  })
end

local function dailyChart(ctx, u)
  local daily, costs, labels = u.daily or {}, u.dailyCost or {}, u.days or {}
  local maxVal = 1
  for _, v in ipairs(daily) do maxVal = math.max(maxVal, tonumber(v) or 0) end
  local barH = 70
  local cols = {}
  for i = 1, 7 do
    local v = tonumber(daily[i]) or 0
    local h = v > 0 and math.max(3, math.floor(v / maxVal * barH)) or 0
    local isToday, isHover = i == 7, i == hoveredDay
    local fill = isToday and "primary" or "on_surface/0.18"
    if isHover then fill = isToday and "primary/0.75" or "on_surface/0.4" end
    cols[#cols + 1] = ui.column({
      key = `day-{i}`, flexGrow = 1, gap = 4, align = "center",
      onHover = function(state)
        if state == "true" then hoveredDay = i elseif hoveredDay == i then hoveredDay = nil else return end
        ctx.markDirty()
      end,
    }, {
      ui.column({ height = barH, justify = "end", align = "center" }, {
        ui.box({ width = isHover and 24 or 20, height = h, radius = 3, fill = fill }),
      }),
      ui.label({ text = isToday and "Today" or (labels[i] or ""), fontSize = 10,
        color = (isToday or isHover) and "primary" or "on_surface_variant" }),
    })
  end
  local i = hoveredDay or 7
  local detail = `{i == 7 and "Today" or labels[i] or ""}: {shared.money(costs[i], ctx.rates())} · {shared.tokens(daily[i])} tokens`
  return kit.card({
    ui.row({ align = "center", gap = 8 }, {
      kit.heading("Last 7 days"),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = detail, fontSize = 11, color = hoveredDay and "primary" or "on_surface_variant", maxLines = 1 }),
    }),
    ui.row({ gap = 6, align = "end" }, cols),
  })
end

local function topSessionsCard(ctx, u)
  local list = u.topSessions or {}
  if #list == 0 then return nil end
  local rows = { kit.heading("Costliest sessions · 7 days") }
  local top = tonumber(list[1].cost) or 0
  for _, s in ipairs(list) do
    local title = (s.title or "") ~= "" and s.title or `session {string.sub(s.id, 1, 8)}`
    rows[#rows + 1] = ui.column({ gap = 3 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = title, fontSize = 12, maxLines = 1, flexGrow = 1 }),
        ui.label({ text = shared.money(s.cost, ctx.rates()), fontSize = 12, fontWeight = "bold" }),
      }),
      ui.row({ gap = 8, align = "center" }, {
        ui.progress({ progress = top > 0 and (tonumber(s.cost) or 0) / top or 0, height = 4, flexGrow = 1,
          fill = "secondary", track = "on_surface/0.10" }),
        kit.muted(`{shared.projectPath(s.cwd or "")} · {shared.tokens(s.tokens)}`, 10, { maxLines = 1 }),
      }),
    })
  end
  return kit.card(rows)
end

local function modelsCard(u)
  local list = {}
  for name, tokens in pairs(u.d7Models or {}) do list[#list + 1] = { name = name, tokens = tonumber(tokens) or 0 } end
  if #list == 0 then return nil end
  table.sort(list, function(a, b) return a.tokens > b.tokens end)
  local total = tonumber(u.d7Tokens) or 0
  local rows = { kit.heading("Models · 7 days") }
  for _, m in ipairs(list) do
    local share = total > 0 and math.min(1, m.tokens / total) or 0
    rows[#rows + 1] = ui.column({ gap = 2, align = "stretch" }, {
      ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = string.upper(string.sub(m.name, 1, 1)) .. string.sub(m.name, 2), fontSize = 12, flexGrow = 1 }),
        kit.muted(`{shared.tokens(m.tokens)} · {shared.round(share * 100)}%`, 11),
      }),
      ui.progress({ progress = share, fill = "primary", track = "on_surface/0.12", height = 5, radius = 2 }),
    })
  end
  return kit.card(rows)
end

function M.render(ctx)
  local S = ctx.S
  local limits = S.accounts[1] and S.accounts[1].limits
  local u = S.usage
  local cards = {}
  if limits then
    if limits.stale then
      cards[#cards + 1] = kit.iconLine("clock-exclamation",
        `Limits from {shared.ago(limits.updated)} ago` .. (limits.error and ` · {limits.error}` or ""), "tertiary", 11)
    end
    for _, w in ipairs(limits.windows or {}) do cards[#cards + 1] = windowCard(w) end
    cards[#cards + 1] = kit.muted("Bars: used, then where the current rate gets you by the reset. The tick marks how much of the window has passed.", 10, { maxLines = 2 })
  end
  if type(u) == "table" then
    local rates = ctx.rates()
    cards[#cards + 1] = kit.card({
      ui.row({ gap = 8, align = "center" }, {
        kit.heading("Estimated cost"),
        ui.spacer({ flexGrow = 1 }),
        kit.muted(`{u.d7Messages or 0} replies in {u.d7Sessions or 0} sessions`, 10),
      }),
      ui.row({ gap = 8, align = "start" }, {
        metric("Today", u.todayTokens, u.todayCost, rates),
        metric("7 days", u.d7Tokens, u.d7Cost, rates),
        metric("30 days", u.d30Tokens, u.d30Cost, rates),
      }),
      kit.muted("What these tokens would cost at API prices; a subscription is billed flat.", 10),
    })
    cards[#cards + 1] = dailyChart(ctx, u)
    local top = topSessionsCard(ctx, u)
    if top then cards[#cards + 1] = top end
    local models = modelsCard(u)
    if models then cards[#cards + 1] = models end
  end
  if #cards == 0 then return kit.notice("chart-bar", "Loading usage…") end
  return ui.scroll({ key = "usage-scroll", flexGrow = 1, gap = 10, align = "stretch" }, cards)
end

return M
