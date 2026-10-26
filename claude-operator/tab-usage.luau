--!nonstrict
-- Usage tab: every plan window with its pace against the clock, token use and cost for
-- today / this week / this month, daily activity and the models used this week.
-- Layout ported from claude-cockpit (nightwatch75, MIT), itself from
-- jrohland/noctalia-v5-claudecode (MIT).
local shared = require("./shared.luau")
local kit = require("./kit.luau")
local M = {}

local DAYS = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
local hoveredDay = nil

function M.opened() hoveredDay = nil end

local function windowCard(w)
  local p = shared.pace(w)
  local fill = shared.paceColor(p.status, "primary")
  local rows = {
    ui.row({ align = "center", justify = "space_between" }, {
      kit.heading(w.kind == "session" and "Current session (5h)" or w.model and `{w.model} this week` or "This week"),
      ui.label({ text = `{shared.round(w.percent)}% used`, fontSize = 14, color = fill }),
    }),
    ui.progress({ progress = math.max(0, math.min(1, w.percent / 100)), fill = fill, track = "on_surface/0.14", radius = 4, height = 8 }),
  }
  -- The thin bar under it is how much of the window's time has passed.
  if p.timeFrac then
    rows[#rows + 1] = ui.progress({ progress = p.timeFrac, fill = "on_surface/0.45", track = "on_surface/0.10", radius = 2, height = 3 })
  end
  local caption = shared.paceLabel(p)
  local left = shared.countdown(w.resetsAt)
  if left then
    local at = shared.clock(w.resetsAt)
    local resets = `resets in {left}` .. (at and ` ({at})` or "")
    caption = caption and `{caption} · {resets}` or resets
  end
  if caption then rows[#rows + 1] = kit.muted(caption, 11) end
  return kit.card(rows)
end

local function metric(label, tokens, cost, rates)
  return ui.column({ gap = 2, align = "center", flexGrow = 1 }, {
    kit.muted(label, 12),
    ui.label({ text = shared.tokens(tokens), fontSize = 16, fontWeight = "bold", color = "primary" }),
    kit.muted(shared.money(cost, rates), 11),
  })
end

local function dailyChart(ctx, u)
  local daily, costs = u.daily or {}, u.dailyCost or {}
  local maxVal = 1
  for _, v in ipairs(daily) do maxVal = math.max(maxVal, tonumber(v) or 0) end
  local t = os.date("*t")
  local today = t.wday == 1 and 7 or t.wday - 1
  local barH = 64
  local cols = {}
  for i = 1, 7 do
    local v = tonumber(daily[i]) or 0
    local h = v > 0 and math.max(3, math.floor(v / maxVal * barH)) or 0
    local isToday, isHover = i == today, i == hoveredDay
    local fill = isToday and "primary" or "on_surface/0.14"
    if isHover then fill = isToday and "primary/0.75" or "on_surface/0.35" end
    cols[#cols + 1] = ui.column({
      key = `day-{i}`, flexGrow = 1, gap = 4, align = "center",
      onHover = function(state)
        if state == "true" then hoveredDay = i elseif hoveredDay == i then hoveredDay = nil else return end
        ctx.markDirty()
      end,
    }, {
      ui.column({ height = barH, justify = "end", align = "center" }, {
        ui.box({ width = isHover and 22 or 18, height = h, radius = 3, fill = fill }),
      }),
      ui.label({ text = DAYS[i], fontSize = 10, color = (isToday or isHover) and "primary" or "on_surface_variant" }),
    })
  end
  local detail = hoveredDay and `{DAYS[hoveredDay]}: {shared.tokens(daily[hoveredDay])} · {shared.money(costs[hoveredDay], ctx.rates())}` or ""
  return kit.card({
    ui.row({ align = "center", justify = "space_between" }, {
      kit.heading("Daily activity"),
      ui.label({ text = detail, fontSize = 11, color = "primary", maxLines = 1 }),
    }),
    ui.row({ gap = 6, align = "end" }, cols),
  })
end

local function modelsCard(u)
  local list = {}
  for name, tokens in pairs(u.weekModels or {}) do list[#list + 1] = { name = name, tokens = tonumber(tokens) or 0 } end
  if #list == 0 then return nil end
  table.sort(list, function(a, b) return a.tokens > b.tokens end)
  local total = tonumber(u.weekTokens) or 0
  local rows = { kit.heading("Models this week") }
  for _, m in ipairs(list) do
    local share = total > 0 and math.min(1, m.tokens / total) or 0
    rows[#rows + 1] = ui.column({ gap = 2, align = "stretch" }, {
      ui.row({ align = "center", justify = "space_between" }, {
        ui.label({ text = string.upper(string.sub(m.name, 1, 1)) .. string.sub(m.name, 2), fontSize = 12 }),
        kit.muted(`{shared.tokens(m.tokens)} · {shared.round(share * 100)}%`, 12),
      }),
      ui.progress({ progress = share, fill = "primary", track = "on_surface/0.14", height = 5, radius = 2 }),
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
    local line = shared.planName(limits.subscription, limits.tier)
    if limits.stale then line = `{line} · limits updated {shared.ago(limits.updated)} ago` .. (limits.error and ` ({limits.error})` or "") end
    cards[#cards + 1] = kit.muted(line, 11, { color = limits.stale and "tertiary" or "on_surface_variant" })
    for _, w in ipairs(limits.windows or {}) do cards[#cards + 1] = windowCard(w) end
  end
  if type(u) == "table" then
    local rates = ctx.rates()
    cards[#cards + 1] = kit.card({
      kit.heading("Token use"),
      ui.row({ gap = 8, align = "start" }, {
        metric("Today", u.todayTokens, u.todayCost, rates),
        metric("This week", u.weekTokens, u.weekCost, rates),
        metric("This month", u.monthTokens, u.monthCost, rates),
      }),
      kit.muted(`{u.weekMessages or 0} messages in {u.weekSessions or 0} sessions this week · cost is an estimate from public prices`, 10),
    })
    cards[#cards + 1] = dailyChart(ctx, u)
    local models = modelsCard(u)
    if models then cards[#cards + 1] = models end
  end
  if #cards == 0 then return kit.notice("chart-bar", "Loading usage…") end
  return ui.scroll({ key = "usage-scroll", flexGrow = 1, gap = 10, align = "stretch" }, cards)
end

return M
