-- @name Links and files
-- @name:pt Links e arquivos
-- @description Every link and file in the messages loaded in the open channel, newest first: search, open, copy, or go to the message. It only looks when you open the panel, and keeps nothing on disk.
-- @description:pt Todos os links e arquivos das mensagens carregadas no canal aberto, dos mais novos para os mais antigos: busque, abra, copie, ou vá até a mensagem. Só olha quando você abre o painel, e não guarda nada no disco.
-- @version 1.0.0
-- @capabilities messages, panel, links, timers

local tr = sigma.tr
local MAX_ITEMS = 200

-- Só existe enquanto o painel está aberto. Fechou: some da memória.
local found = {}
local open = false
local query = ""
local kind = "all"
local waiting = false

local function when(t)
  if os.date("%Y%m%d", t) == os.date("%Y%m%d") then return os.date("%H:%M", t) end
  return os.date(sigma.lang() == "pt" and "%d/%m %H:%M" or "%b %d %H:%M", t)
end

local function size_text(n)
  if not n or n <= 0 then return "" end
  if n < 1024 * 1024 then return string.format("%.0f KB", n / 1024) end
  return string.format("%.1f MB", n / (1024 * 1024))
end

-- A pontuação logo depois é da frase, não do link.
local function trim_url(url)
  url = url:gsub("[%.,;:!%?'%*_~|`]+$", "")
  if url:sub(-1) == ")" and not url:find("(", 1, true) then url = url:sub(1, -2) end
  return url
end

local function host_of(url)
  return url:match("^https?://([^/?#]+)") or url
end

local function matches(it)
  if kind ~= "all" and it.kind ~= kind then return false end
  if query == "" then return true end
  return (it.title .. " " .. it.url .. " " .. it.by):lower():find(query, 1, true) ~= nil
end

local render = function() end

local function collect(list)
  found = {}
  local seen = {}
  -- Da mais nova para a mais antiga: o mesmo link repetido fica com a mais recente.
  for i = #list, 1, -1 do
    local m = list[i]
    if #found >= MAX_ITEMS then break end
    local function add(k, title, url, size)
      if seen[url] or #found >= MAX_ITEMS then return end
      seen[url] = true
      found[#found + 1] = { kind = k, title = title, url = url, size = size, by = m.author.name, time = m.time, id = m.id, channel = m.channel.id }
    end
    for _, f in ipairs(m.files or {}) do add("file", f.name, f.url, f.size) end
    for raw in m.content:gmatch("https?://[^%s<>\"]+") do
      local url = trim_url(raw)
      add("link", host_of(url), url)
    end
  end
  render()
end

local function scan()
  if not open then return end
  if sigma.messages({ limit = 500, files = true }, collect) then
    waiting = false
  elseif not waiting then
    -- Pediu cedo demais: tenta de novo daqui a pouco.
    waiting = true
    sigma.after(0.6, function()
      waiting = false
      scan()
    end)
  end
end

render = function()
  local items = {}
  for i, it in ipairs(found) do
    if matches(it) then
      local sub = it.url
      if it.kind == "file" then
        local size = size_text(it.size)
        sub = size ~= "" and it.by .. "  ·  " .. size or it.by
      end
      items[#items + 1] = {
        title = it.title,
        subtitle = sub,
        meta = when(it.time),
        key = "i" .. i,
        on_click = function() sigma.jump(it.channel, it.id) end,
        actions = {
          { label = tr("Abrir", "Open"), key = "open" .. i, on_click = function() sigma.open(it.url) end },
          { label = tr("Copiar", "Copy"), key = "copy" .. i, on_click = function() sigma.copy(it.url) end },
        },
      }
    end
  end
  sigma.panel.set({
    title = tr("Links e arquivos", "Links and files"),
    { type = "input", key = "search", placeholder = tr("Buscar", "Search"), value = query, on_change = function(v)
      query = v:lower()
      render()
    end },
    { type = "select", key = "kind", label = tr("Mostrar", "Show"), value = kind,
      options = {
        { value = "all", label = tr("Tudo", "Everything") },
        { value = "link", label = tr("Só links", "Links only") },
        { value = "file", label = tr("Só arquivos", "Files only") },
      },
      on_change = function(v)
        kind = v
        render()
      end },
    { type = "row",
      { type = "button", label = tr("Atualizar", "Refresh"), key = "refresh", on_click = scan },
    },
    { type = "list", key = "found", items = items,
      empty = tr("Nada por aqui nas mensagens carregadas.", "Nothing here in the loaded messages.") },
  })
end

sigma.on("panel", function(state)
  open = state
  if open then
    scan()
  else
    found = {}
    render()
  end
end)

sigma.on("channel", scan)

-- Editaram: o que estava na lista pode nem existir mais.
sigma.on("edit", scan)

-- Apagaram: sai na hora, sem guardar o link de ninguém.
sigma.on("delete", function(d)
  if not open then return end
  local keep = {}
  for _, it in ipairs(found) do
    if it.id ~= d.id then keep[#keep + 1] = it end
  end
  if #keep ~= #found then
    found = keep
    render()
  end
end)

sigma.command("/links", function()
  sigma.panel.open()
end)

sigma.on("lang", function() render() end)
render()
