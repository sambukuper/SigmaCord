-- @name Channel stats
-- @name:pt Estatísticas do canal
-- @description Who talks most and when, counted from the messages already loaded in the open channel. Nothing is downloaded or saved.
-- @description:pt Quem mais fala e quando, contando as mensagens já carregadas no canal aberto. Nada é baixado nem guardado.
-- @version 1.0.0
-- @capabilities messages, panel, timers

local tr = sigma.tr
local open = false
local last = nil
local refresh

local function render()
  local tree = { title = tr("Estatísticas do canal", "Channel stats") }
  local ch = sigma.channel()
  if not ch then
    tree[#tree + 1] = { type = "text", text = tr("Abra um canal para ver.", "Open a channel to see."), style = "muted" }
    sigma.panel.set(tree)
    return
  end
  tree[#tree + 1] = { type = "heading", text = "#" .. ch.name }
  tree[#tree + 1] = { type = "row",
    { type = "button", label = tr("Atualizar", "Refresh"), key = "refresh", on_click = function() refresh() end },
  }
  if not last or last.total == 0 then
    tree[#tree + 1] = { type = "text", text = tr("Nenhuma mensagem carregada ainda.", "No messages loaded yet."), style = "muted" }
  else
    local days = math.max((last.last - last.first) / 86400, 1 / 24)
    local rate = last.total / days
    tree[#tree + 1] = { type = "text", key = "total", text = tr(
      string.format("%d mensagens de %d pessoas, %.0f por dia", last.total, #last.top, rate),
      string.format("%d messages from %d people, %.0f a day", last.total, #last.top, rate)) }
    tree[#tree + 1] = { type = "text", style = "muted", text = tr(
      "De " .. os.date("%d/%m %H:%M", last.first) .. " a " .. os.date("%d/%m %H:%M", last.last),
      "From " .. os.date("%b %d %H:%M", last.first) .. " to " .. os.date("%b %d %H:%M", last.last)) }
    tree[#tree + 1] = { type = "heading", text = tr("Quem mais fala", "Top talkers") }
    for i = 1, math.min(#last.top, 8) do
      local t = last.top[i]
      tree[#tree + 1] = { type = "bar", key = "top" .. i, label = t.name, value = t.n, max = last.top[1].n, text = tostring(t.n) }
    end
    tree[#tree + 1] = { type = "heading", text = tr("Quando", "When") }
    local peak = 1
    for _, n in ipairs(last.hours) do peak = math.max(peak, n) end
    for i, n in ipairs(last.hours) do
      local from = (i - 1) * 4
      tree[#tree + 1] = { type = "bar", key = "h" .. i, label = string.format("%02d–%02dh", from, from + 4), value = n, max = peak, text = tostring(n) }
    end
    if last.attachments > 0 then
      tree[#tree + 1] = { type = "text", style = "muted", text = tr(last.attachments .. " anexos", last.attachments .. " attachments") }
    end
  end
  sigma.panel.set(tree)
end

local function count(list)
  local by = {}
  local result = { total = 0, top = {}, hours = { 0, 0, 0, 0, 0, 0 }, attachments = 0, first = 0, last = 0 }
  for _, m in ipairs(list) do
    result.total = result.total + 1
    if result.first == 0 then result.first = m.time end
    result.last = m.time
    result.attachments = result.attachments + m.attachments
    local who = by[m.author.id]
    if not who then
      who = { name = m.author.name, n = 0 }
      by[m.author.id] = who
      result.top[#result.top + 1] = who
    end
    who.n = who.n + 1
    local slot = tonumber(os.date("%H", m.time)) // 4 + 1
    result.hours[slot] = result.hours[slot] + 1
  end
  table.sort(result.top, function(a, b) return a.n > b.n end)
  return result
end

refresh = function()
  sigma.messages({ limit = 500 }, function(list)
    last = count(list)
    render()
  end)
end

sigma.on("panel", function(is_open)
  open = is_open
  if open then refresh() end
end)

-- Trocou de canal com o painel aberto: as mensagens podem ainda estar chegando.
sigma.on("channel", function()
  if not open then return end
  last = nil
  render()
  sigma.after(0.7, function()
    if open then refresh() end
  end)
end)

sigma.command("/stats", function()
  render()
  sigma.panel.open()
end)

sigma.on("lang", render)
render()
