-- @name Highlights
-- @name:pt Destaques
-- @description Pick words to watch across all channels. When someone writes one you get a notification, the panel shows how many you haven't seen, and its history takes you to the message. You can mute a channel, and choose below whether it also uses desktop notifications.
-- @description:pt Escolha palavras para acompanhar em todos os canais. Quando alguém escreve uma, você recebe um aviso, o painel mostra quantas você ainda não viu, e o histórico leva à mensagem. Dá para silenciar um canal, e escolher aqui embaixo se também usa as notificações do sistema.
-- @version 1.1.0
-- @capabilities messages, panel, storage, notify, decorate, settings

local tr = sigma.tr
local MAX_HITS = 200
local words = sigma.storage.get("words") or {}
-- Guardado no disco: onde e quem, nunca o texto de ninguém.
local hits = sigma.storage.get("hits") or {}
-- Canais silenciados: id -> nome.
local muted = sigma.storage.get("muted") or {}
local desktop = sigma.storage.get("desktop") or false
-- O trecho da mensagem fica só na memória, e sai se ela for apagada.
local snippets = {}
-- Quantas chegaram desde a última vez que o painel abriu.
local unread = 0
local panel_open = false

local function fold(s)
  -- Minúsculas, inclusive as letras acentuadas.
  return (s:lower():gsub("\xC3([\x80-\x9E])", function(c) return "\xC3" .. string.char(c:byte() + 32) end))
end

-- Palavra inteira: nem "pizzaria" conta como "pizza", nem "c" dentro de "c++".
local function is_word(b)
  return b and (b >= 0x80 or b == 95 or (b >= 48 and b <= 57) or (b >= 97 and b <= 122))
end

local function has_word(text, w)
  local from = 1
  while true do
    local a, z = text:find(w, from, true)
    if not a then return false end
    if (not is_word(w:byte(1)) or not is_word(text:byte(a - 1))) and (not is_word(w:byte(-1)) or not is_word(text:byte(z + 1))) then
      return true
    end
    from = a + 1
  end
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function save()
  sigma.storage.set("words", words)
  sigma.storage.set("hits", hits)
  sigma.storage.set("muted", muted)
end

local function when(t)
  if os.date("%Y%m%d", t) == os.date("%Y%m%d") then return os.date("%H:%M", t) end
  return os.date(sigma.lang() == "pt" and "%d/%m %H:%M" or "%b %d %H:%M", t)
end

local function short(content)
  local s = content:gsub("%s+", " ")
  if #s <= 200 then return s end
  local cut = 200
  while cut > 0 and (s:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end
  return s:sub(1, cut) .. "…"
end

local render
local listen

local function add_word(w)
  w = fold(trim(w))
  if w == "" then return end
  for _, x in ipairs(words) do
    if x == w then return end
  end
  if #words >= 64 then
    sigma.notify(tr("Palavras demais: até 64", "Too many words: up to 64"))
    return
  end
  words[#words + 1] = w
  save()
  listen()
  render()
end

render = function()
  local word_items = {}
  for i, w in ipairs(words) do
    word_items[#word_items + 1] = {
      title = w, key = "w" .. i,
      actions = { { label = tr("Tirar", "Remove"), style = "danger", key = "rmw" .. i, on_click = function()
        table.remove(words, i)
        save()
        render()
      end } },
    }
  end
  local hit_items = {}
  for _, h in ipairs(hits) do
    hit_items[#hit_items + 1] = {
      title = h.author .. "  ·  #" .. h.channel_name,
      subtitle = snippets[h.id] or ("“" .. h.word .. "”"),
      meta = when(h.time),
      key = h.id,
      on_click = function() sigma.jump(h.channel, h.id) end,
    }
  end
  local tree = {
    title = tr("Destaques", "Highlights"),
    badge = unread > 0 and tostring(unread) or nil,
    { type = "input", key = "new", placeholder = tr("Nova palavra (Enter)", "New word (Enter)"), clear = true,
      on_submit = function(v) add_word(v) end },
    { type = "list", key = "words", items = word_items,
      empty = tr("Nenhuma palavra ainda. Escreva uma acima.", "No words yet. Type one above.") },
    { type = "row",
      { type = "button", label = tr("Silenciar este canal", "Mute this channel"), key = "mute", on_click = function()
        local ch = sigma.channel()
        if not ch then return end
        muted[ch.id] = ch.name
        save()
        render()
      end },
    },
  }
  local mute_items = {}
  for id, name in pairs(muted) do
    mute_items[#mute_items + 1] = {
      title = "#" .. name, key = "muted" .. id,
      actions = { { label = tr("Reativar", "Unmute"), key = "unmute" .. id, on_click = function()
        muted[id] = nil
        save()
        render()
      end } },
    }
  end
  if #mute_items > 0 then
    table.sort(mute_items, function(a, b) return a.title < b.title end)
    tree[#tree + 1] = { type = "heading", text = tr("Canais silenciados", "Muted channels") }
    tree[#tree + 1] = { type = "list", key = "muted", items = mute_items }
  end
  tree[#tree + 1] = { type = "heading", text = tr("Histórico", "History") }
  tree[#tree + 1] = { type = "list", key = "hits", items = hit_items, empty = tr("Nada por enquanto.", "Nothing so far.") }
  if #hits > 0 then
    tree[#tree + 1] = { type = "row",
      { type = "button", label = tr("Limpar histórico", "Clear history"), key = "clear", on_click = function()
        hits = {}
        snippets = {}
        unread = 0
        save()
        render()
      end },
    }
  end
  sigma.panel.set(tree)
end

local function word_in(content)
  local text = fold(content)
  for _, w in ipairs(words) do
    if has_word(text, w) then return w end
  end
end

local function take(m)
  if m.mine or m.ignored or #words == 0 or m.content == "" or muted[m.channel.id] then return end
  local w = word_in(m.content)
  if not w then return end
  snippets[m.id] = short(m.content)
  table.insert(hits, 1, { id = m.id, channel = m.channel.id, channel_name = m.channel.name, author = m.author.name, word = w, time = m.time })
  if #hits > MAX_HITS then
    snippets[hits[#hits].id] = nil
    hits[#hits] = nil
  end
  if not panel_open then unread = unread + 1 end
  save()
  render()
  sigma.decorate(m, { badge = "★ " .. w })
  sigma.notify("★ " .. w .. ": " .. m.author.name .. " #" .. m.channel.name, { desktop = desktop })
end

-- Editaram: o trecho acompanha o texto novo, e sem a palavra sai da lista. Uma edição
-- que passa a ter a palavra conta como nova.
local function edited(m)
  for i, h in ipairs(hits) do
    if h.id == m.id then
      if word_in(m.content) then
        snippets[m.id] = short(m.content)
      else
        table.remove(hits, i)
        snippets[m.id] = nil
        sigma.undecorate(m)
        save()
      end
      render()
      return
    end
  end
  take(m)
end

-- Só escuta as mensagens quando tem palavra para procurar: até lá, nenhuma delas
-- chega perto deste plugin.
local listening = false
listen = function()
  if listening or #words == 0 then return end
  listening = true
  sigma.on("message", take)
  sigma.on("edit", edited)
end

sigma.command("/highlights", function(args)
  if args ~= "" then add_word(args) end
  render()
  sigma.panel.open()
end)

-- Apagaram: sai da lista, com o texto.
sigma.on("delete", function(d)
  snippets[d.id] = nil
  for i, h in ipairs(hits) do
    if h.id == d.id then
      table.remove(hits, i)
      save()
      render()
      return
    end
  end
end)

sigma.on("panel", function(open)
  panel_open = open
  if open and unread > 0 then
    unread = 0
    render()
  end
end)

local function options()
  sigma.settings.set({
    { type = "toggle", key = "desktop", label = tr("Notificação do sistema", "Desktop notification"),
      hint = tr("Também com a janela em foco. Sem isto, só um aviso no app, e a notificação quando você está longe.", "Even with the window focused. Without this, just a notice in the app, and the notification when you're away."),
      value = desktop,
      on_change = function(on)
        desktop = on
        sigma.storage.set("desktop", on)
      end },
  })
end

sigma.on("lang", function()
  options()
  render()
end)
listen()
options()
render()
