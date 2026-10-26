--!nonstrict
-- Temporary probe: session count and limits, to check the service's state.
local sessions = noctalia.state.get("sessions") or {}
local accounts = noctalia.state.get("accounts") or {}

local function render()
  local a = accounts[1]
  local lim = {}
  for _, w in ipairs(a and a.limits and a.limits.windows or {}) do lim[#lim + 1] = `{w.label} {math.floor(w.percent + 0.5)}%` end
  barWidget.render(ui.row({ gap = 4, align = "center" }, {
    ui.glyph({ name = noctalia.getConfig("glyph") or "headset", size = 16 }),
    ui.label({ text = `{#sessions} · {table.concat(lim, " ")}` }),
  }))
end

noctalia.state.watch("sessions", function(v) sessions = v or {}; render() end)
noctalia.state.watch("accounts", function(v) accounts = v or {}; render() end)
render()
