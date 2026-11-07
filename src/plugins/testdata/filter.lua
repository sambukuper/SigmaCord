-- @name Local filter
-- @name:pt Filtro local
-- @description Collapse messages by word or by person, on this computer only: nobody finds out, and each one has a "show" button.
-- @description:pt Recolhe mensagens por palavra ou por pessoa, só neste computador: ninguém fica sabendo, e cada uma tem um "mostrar".
-- @version 1.0.0
-- @capabilities menu, panel, storage, decorate, notify

local tr = sigma.tr
local words = sigma.storage.get("words") or {}
local users = sigma.storage.get("users") or {}
local paused = sigma.storage.get("paused") or false

local function save()
  sigma.storage.set("words", words)
  sigma.storage.set("users", users)
  sigma.storage.set("paused", paused)
end

-- As regras ficam com o app: o plugin não é chamado a cada mensagem.
local function apply()
  local rules = {}
  if not paused then
    local label = tr("Recolhida pelo filtro local", "Collapsed by the local filter")
    for _, w in ipairs(words) do rules[#rules + 1] = { word = w, collapse = true, label = label } end
    for _, u in ipairs(users) do rules[#rules + 1] = { user = u.id, collapse = true, label = label } end
  end
  sigma.rules(rules)
end

local render

local function changed()
  save()
  apply()
  render()
end

local function add_user(id, name)
  for _, u in ipairs(users) do
    if u.id == id then return end
  end
  users[#users + 1] = { id = id, name = name }
  changed()
  sigma.notify(tr("Recolhendo as mensagens de ", "Collapsing messages from ") .. name)
end

render = function()
  local word_items = {}
  for i, w in ipairs(words) do
    word_items[#word_items + 1] = { title = w, key = "w" .. i,
      actions = { { label = tr("Tirar", "Remove"), style = "danger", key = "rmw" .. i, on_click = function()
        table.remove(words, i)
        changed()
      end } } }
  end
  local user_items = {}
  for i, u in ipairs(users) do
    user_items[#user_items + 1] = { title = u.name, key = "u" .. i,
      actions = { { label = tr("Tirar", "Remove"), style = "danger", key = "rmu" .. i, on_click = function()
        table.remove(users, i)
        changed()
      end } } }
  end
  sigma.panel.set({
    title = tr("Filtro local", "Local filter"),
    { type = "input", key = "new", placeholder = tr("Palavra ou expressão (Enter)", "Word or phrase (Enter)"), clear = true,
      on_submit = function(v)
        v = v:gsub("^%s+", ""):gsub("%s+$", "")
        if v == "" then return end
        for _, w in ipairs(words) do
          if w:lower() == v:lower() then return end
        end
        if #words + #users >= 250 then
          sigma.notify(tr("Filtro cheio: até 250", "Filter is full: up to 250"))
          return
        end
        words[#words + 1] = v
        changed()
      end },
    { type = "heading", text = tr("Palavras", "Words") },
    { type = "list", key = "words", items = word_items, empty = tr("Nenhuma.", "None.") },
    { type = "heading", text = tr("Pessoas", "People") },
    { type = "list", key = "users", items = user_items,
      empty = tr("Nenhuma. Botão direito numa pessoa → Recolher mensagens.", "None. Right-click someone → Collapse messages.") },
    { type = "separator" },
    { type = "row",
      { type = "button", label = paused and tr("Retomar filtro", "Resume filter") or tr("Pausar filtro", "Pause filter"), key = "pause",
        on_click = function() paused = not paused; changed() end },
    },
  })
end

sigma.menu("user", { pt = "Recolher mensagens", en = "Collapse messages" }, function(u) add_user(u.id, u.name) end)
sigma.menu("message", { pt = "Recolher desta pessoa", en = "Collapse this person" }, function(m)
  if not m.mine then add_user(m.author.id, m.author.name) end
end)

sigma.command("/filter", function()
  render()
  sigma.panel.open()
end)

sigma.on("lang", function()
  apply()
  render()
end)

apply()
render()
