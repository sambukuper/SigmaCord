-- @name Bookmarks
-- @name:pt Favoritos
-- @description Right-click a message to save it. The panel lists what you saved, with search, and takes you back to the message. Everything stays on this computer.
-- @description:pt Botão direito numa mensagem para guardar. O painel lista o que você guardou, com busca, e leva de volta à mensagem. Tudo fica neste computador.
-- @version 1.0.0
-- @capabilities menu, panel, storage, decorate, messages, notify

local tr = sigma.tr
local MAX = 500
local items = sigma.storage.get("items") or {}
local query = ""

local function save()
  sigma.storage.set("items", items)
end

local function find(id)
  for i, it in ipairs(items) do
    if it.id == id then return i end
  end
end

-- O que fica guardado é uma prévia curta, sem as marcas de menção e emoji.
local function preview(text)
  text = text:gsub("<a?:([%w_]+):%d+>", ":%1:"):gsub("<@[!&]?%d+>", "@…"):gsub("<#%d+>", "#…"):gsub("%s+", " ")
  if #text > 300 then
    local cut = 300
    while cut > 0 and (text:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end
    text = text:sub(1, cut) .. "…"
  end
  return text
end

local function date(t)
  return os.date(sigma.lang() == "pt" and "%d/%m/%Y %H:%M" or "%b %d, %Y %H:%M", t)
end

local render

local function remove(id)
  local i = find(id)
  if not i then return end
  table.remove(items, i)
  sigma.undecorate(id)
  save()
  render()
end

local function matches(it)
  if query == "" then return true end
  local q = query:lower()
  return (it.text or ""):lower():find(q, 1, true) or it.author:lower():find(q, 1, true) or it.where:lower():find(q, 1, true)
end

render = function()
  local list = {}
  for _, it in ipairs(items) do
    if matches(it) then
      list[#list + 1] = {
        title = it.author .. "  ·  " .. it.where,
        subtitle = it.gone and tr("(mensagem apagada)", "(message deleted)") or (it.text ~= "" and it.text or tr("(sem texto)", "(no text)")),
        meta = date(it.time),
        key = it.id,
        on_click = function() sigma.jump(it.channel, it.id) end,
        actions = {
          { label = tr("Remover", "Remove"), style = "danger", key = "rm" .. it.id, on_click = function() remove(it.id) end },
        },
      }
    end
  end
  sigma.panel.set({
    title = tr("Favoritos", "Bookmarks"),
    { type = "input", key = "search", placeholder = tr("Buscar nos favoritos…", "Search bookmarks…"), value = query,
      on_change = function(v) query = v; render() end },
    { type = "list", key = "items", items = list,
      empty = query ~= "" and tr("Nada encontrado.", "Nothing found.")
        or tr("Nada guardado ainda. Botão direito numa mensagem → Salvar nos favoritos.", "Nothing saved yet. Right-click a message → Bookmark.") },
  })
end

sigma.menu("message", { pt = "Salvar nos favoritos", en = "Bookmark" }, function(m)
  if find(m.id) then
    remove(m.id)
    sigma.notify(tr("Tirado dos favoritos", "Removed from bookmarks"))
    return
  end
  if #items >= MAX then
    sigma.notify(tr("Favoritos cheios: até 500", "Bookmarks are full: up to 500"))
    return
  end
  local where = "#" .. m.channel.name
  if m.guild then where = where .. "  ·  " .. m.guild.name end
  table.insert(items, 1, { id = m.id, channel = m.channel.id, author = m.author.name, where = where, text = preview(m.content), time = m.time })
  save()
  sigma.decorate(m, { badge = "🔖" })
  render()
  sigma.notify(tr("Salvo nos favoritos", "Bookmarked"))
end)

sigma.command("/bookmarks", function()
  render()
  sigma.panel.open()
end)

-- Quem apagou a mensagem levou o texto junto: aqui fica só o lugar.
sigma.on("delete", function(d)
  local i = find(d.id)
  if not i then return end
  items[i].text = ""
  items[i].gone = true
  save()
  render()
end)

sigma.on("lang", render)

for _, it in ipairs(items) do sigma.decorate(it.id, { badge = "🔖" }) end
render()
