--!nonstrict
-- Plugins tab: installed Claude Code plugins (skills and mods) grouped by marketplace,
-- plus bare ~/.claude/skills folders. Enable/disable, update and uninstall per plugin,
-- refresh or remove a marketplace, check for updates, and install by name, repo or path.
-- Everything goes through `claude plugin`. Ported from claude-cockpit's Skills/Mods tab
-- (nightwatch75, MIT).
local plugins = require("./plugins.luau")
local kit = require("./kit.luau")
local M = {}

local data = { loading = false, error = nil, groups = nil, localSkills = nil }
local busy = {} -- action key -> true while its `claude plugin` run is in flight
local confirming = nil -- "plugin:<id>" | "market:<name>" | "local:<name>"
local installText, installRev = "", 0
local RESTART = "Restart Claude Code to apply."

function M.load(ctx)
  if data.loading then return end
  if not plugins.available() then data.error = "Claude Code not found (looked on PATH and in ~/.local/bin)" ctx.render() return end
  data.loading, data.error = true, nil
  ctx.render()
  plugins.refresh(function(result, err)
    data.loading, data.error = false, err
    if result then
      data.groups = plugins.groupByMarketplace(result.plugins, result.marketplaces)
      data.localSkills = result.localSkills
    end
    ctx.render()
  end)
end

function M.show(ctx) if not data.groups then M.load(ctx) end end
function M.refresh(ctx) M.load(ctx) end
function M.busy() return data.loading end
function M.closed() confirming = nil end

-- Runs one plugins.* action under `key`: its button spins, the outcome becomes a
-- notification, and the lists reload.
local function run(ctx, key, label, action, arg, after)
  busy[key], confirming = true, nil
  ctx.render()
  action(arg, function(ok, message)
    busy[key] = nil
    if ok then
      noctalia.notify("Claude Operator", `{label}: done.` .. (after and (" " .. after) or ""))
    else
      noctalia.notifyError("Claude Operator", message ~= "" and message or `{label}: failed`)
    end
    M.load(ctx)
  end)
end

local function actionButton(key, glyph, tooltip, onClick)
  return kit.iconButton(busy[key] and "loader-2" or glyph, tooltip, onClick, { enabled = not busy[key] })
end

local function ask(ctx, key) return function() confirming = key; ctx.render() end end
local function cancel(ctx) return function() confirming = nil; ctx.render() end end

local function linkButton(url)
  if not url then return nil end
  return kit.iconButton(string.match(url, "^https://github%.com/") and "brand-github" or "external-link", url,
    function() plugins.openUrl(url) end)
end

local function pluginRow(ctx, p, rows)
  local key = "plugin:" .. p.id
  local meta = p.version .. (p.newVersion and (" → " .. p.newVersion) or "") .. (p.enabled and "" or " · disabled")
  rows[#rows + 1] = ui.row({ key = "row-" .. key, gap = 8, align = "center", paddingH = 20 }, kit.compact(
    ui.glyph({ name = "puzzle", size = 14, color = p.enabled and "primary" or "on_surface_variant" }),
    ui.column({ gap = 0, flexGrow = 1 }, {
      ui.label({ text = p.name, fontSize = 13, maxLines = 1 }),
      kit.muted(meta, 10, { color = p.newVersion and "primary" or "on_surface_variant" }),
    }),
    linkButton(p.url),
    actionButton("toggle:" .. p.id, p.enabled and "toggle-right" or "toggle-left", p.enabled and "Disable" or "Enable",
      function() run(ctx, "toggle:" .. p.id, p.name, plugins.setEnabled, p, RESTART) end),
    actionButton("update:" .. p.id, p.newVersion and "circle-arrow-up" or "download", p.newVersion and "Update available" or "Update",
      function() run(ctx, "update:" .. p.id, p.name, plugins.updatePlugin, p, RESTART) end),
    actionButton(key, "trash", "Uninstall", ask(ctx, key))
  ))
  if confirming == key then
    rows[#rows + 1] = kit.confirmStrip(key, `Uninstall {p.name}?`, "Uninstall",
      function() run(ctx, key, p.name, plugins.uninstallPlugin, p, RESTART) end, cancel(ctx))
  end
end

local function marketRow(ctx, g, rows)
  local key = "market:" .. g.name
  rows[#rows + 1] = ui.row({ key = "row-" .. key, gap = 8, align = "center" }, kit.compact(
    ui.glyph({ name = "building-store", size = 14, color = "on_surface_variant" }),
    ui.column({ gap = 0, flexGrow = 1 }, {
      ui.label({ text = g.name, fontSize = 13, fontWeight = "medium", maxLines = 1 }),
      kit.muted(g.source or "", 10),
    }),
    linkButton(g.url),
    actionButton("mupdate:" .. g.name, "refresh", "Refresh marketplace",
      function() run(ctx, "mupdate:" .. g.name, g.name, plugins.updateMarketplace, g.name) end),
    actionButton(key, "trash", "Remove marketplace", ask(ctx, key))
  ))
  if confirming == key then
    -- `marketplace remove` also uninstalls every plugin installed from it.
    local text = #g.plugins > 0 and `Remove {g.name} and uninstall its {#g.plugins} plugins?` or `Remove {g.name}?`
    rows[#rows + 1] = kit.confirmStrip(key, text, "Remove",
      function() run(ctx, key, g.name, plugins.removeMarketplace, g.name) end, cancel(ctx))
  end
end

local function localRow(ctx, skill, rows)
  local key = "local:" .. skill.name
  rows[#rows + 1] = ui.row({ key = "row-" .. key, gap = 8, align = "center", paddingH = 20 }, kit.compact(
    ui.glyph({ name = "file-text", size = 14, color = "primary" }),
    ui.label({ text = skill.name, fontSize = 13, flexGrow = 1, maxLines = 1 }),
    linkButton(skill.url),
    actionButton(key, "trash", "Remove", ask(ctx, key))
  ))
  if confirming == key then
    rows[#rows + 1] = kit.confirmStrip(key, `Remove the {skill.name} skill folder? A symlink loses only the link.`, "Remove",
      function() run(ctx, key, skill.name, plugins.removeLocalSkill, skill.name) end, cancel(ctx))
  end
end

local function submitInstall(ctx)
  local text = noctalia.string.trim(installText)
  if not plugins.classifySource(text) then
    noctalia.notifyError("Claude Operator", "Type plugin@marketplace, owner/repo, a git URL or a path")
    return
  end
  installText, installRev = "", installRev + 1
  run(ctx, "install", text, plugins.install, text, RESTART)
end

function M.render(ctx)
  local checking = busy.check == true
  local rows = {
    ui.row({ key = "plugins-tools", gap = 8, align = "center" }, {
      kit.muted("Check updates fetches every marketplace and marks newer versions. It installs nothing.", 11, { flexGrow = 1, maxLines = 2 }),
      ui.button({ glyph = checking and "loader-2" or "cloud-search", text = "Check updates", variant = "ghost", controlSize = "sm",
        enabled = not checking, onClick = function() run(ctx, "check", "Check updates", plugins.checkUpdates, nil) end }),
    }),
  }
  if data.error then
    rows[#rows + 1] = ui.label({ text = data.error, color = "error" })
  elseif not data.groups then
    rows[#rows + 1] = kit.muted("Reading plugins…")
  else
    for _, g in ipairs(data.groups) do
      marketRow(ctx, g, rows)
      for _, p in ipairs(g.plugins) do pluginRow(ctx, p, rows) end
    end
    if #data.localSkills > 0 then
      rows[#rows + 1] = ui.row({ key = "local-hdr", gap = 8, align = "center" }, {
        ui.glyph({ name = "folder", size = 14, color = "on_surface_variant" }),
        ui.label({ text = "Local skills", fontSize = 13, fontWeight = "medium", flexGrow = 1 }),
        kit.muted(plugins.LOCAL_SKILLS_DIR, 10),
      })
      for _, s in ipairs(data.localSkills) do localRow(ctx, s, rows) end
    end
    if #data.groups == 0 and #data.localSkills == 0 then rows[#rows + 1] = kit.muted("No plugins installed") end
  end
  local installing = busy.install == true
  return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, {
    ui.scroll({ key = "plugins-scroll", flexGrow = 1, gap = 8, align = "stretch" }, rows),
    kit.card({
      kit.heading("Install"),
      ui.row({ gap = 6, align = "center" }, {
        ui.input({ key = "install-" .. installRev, value = installText, placeholder = "plugin@marketplace, owner/repo, URL or path",
          flexGrow = 1, onChange = function(v) installText = v end,
          onSubmit = function(v) installText = v; submitInstall(ctx) end }),
        kit.iconButton(installing and "loader-2" or "plus", "Install", function() submitInstall(ctx) end, { enabled = not installing }),
      }),
    }),
  })
end

return M
