-- @name Snippets
-- @name:pt Trechos
-- @description Save texts you use often and put them in the message box as you type (;name), with one click or with /snip name. It never sends anything: you still press Enter.
-- @description:pt Guarde textos que você usa sempre e ponha na caixa de mensagem enquanto digita (;nome), com um clique ou com /snip nome. Nunca envia nada: quem aperta Enter é você.
-- @version 1.1.0
-- @capabilities panel, storage, composer, menu, notify, completions

local tr = sigma.tr
local items = sigma.storage.get("items") or {}
local draft_name, draft_text = "", ""

local function save()
  sigma.storage.set("items", items)
end

local function find(name)
  local low = name:lower()
  for i, it in ipairs(items) do
    if it.name:lower() == low then return i end
  end
end

-- A lista fica com a interface: digitar ";" não chama este plugin.
local function publish()
  local list = {}
  for _, it in ipairs(items) do
    if #list == 256 then break end
    list[#list + 1] = { name = it.name, text = it.text }
  end
  sigma.completions(";", list)
end

local render

local function add(name, text)
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" or text == "" then
    sigma.notify(tr("O trecho precisa de nome e texto", "A snippet needs a name and text"))
    return false
  end
  local i = find(name)
  if i then
    items[i].text = text
  else
    if #items >= 200 then
      sigma.notify(tr("Trechos demais: até 200", "Too many snippets: up to 200"))
      return false
    end
    items[#items + 1] = { name = name, text = text }
    table.sort(items, function(a, b) return a.name:lower() < b.name:lower() end)
  end
  save()
  publish()
  return true
end

local function commit()
  if add(draft_name, draft_text) then
    draft_name, draft_text = "", ""
  end
  render()
end

render = function()
  local list = {}
  for _, it in ipairs(items) do
    list[#list + 1] = {
      title = it.name,
      subtitle = it.text,
      key = it.name,
      on_click = function() sigma.insert(it.text) end,
      actions = { { label = tr("Tirar", "Remove"), style = "danger", key = "rm" .. it.name, on_click = function()
        local i = find(it.name)
        if i then table.remove(items, i) end
        save()
        publish()
        render()
      end } },
    }
  end
  sigma.panel.set({
    title = tr("Trechos", "Snippets"),
    { type = "text", text = tr("Clique para pôr na caixa de mensagem, ou digite ;nome nela.", "Click to put it in the message box, or type ;name there."), style = "muted" },
    { type = "list", key = "items", items = list, empty = tr("Nenhum trecho ainda.", "No snippets yet.") },
    { type = "separator" },
    { type = "heading", text = tr("Novo trecho", "New snippet") },
    { type = "input", key = "name", placeholder = tr("Nome", "Name"), value = draft_name, on_change = function(v) draft_name = v end },
    { type = "input", key = "text", placeholder = tr("Texto", "Text"), value = draft_text, on_change = function(v) draft_text = v end,
      on_submit = function(v)
        draft_text = v
        commit()
      end },
    { type = "row",
      { type = "button", label = tr("Guardar", "Save"), key = "add", style = "accent", on_click = commit },
    },
  })
end

sigma.command("/snip", function(args)
  if args == "" then
    render()
    sigma.panel.open()
    return
  end
  local i = find(args)
  if i then
    sigma.insert(items[i].text)
  else
    sigma.notify(tr("Não há trecho com esse nome: ", "No snippet with that name: ") .. args)
  end
end)

sigma.menu("message", { pt = "Guardar como trecho", en = "Save as snippet" }, function(m)
  draft_text = m.content
  draft_name = ""
  render()
  sigma.panel.open()
end)

sigma.on("lang", render)
publish()
render()
