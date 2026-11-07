-- @name What did I miss
-- @name:pt O que perdi
-- @description /missed or the panel: sums up the unread messages in the open channel (or the last ones): how many from each person, mentions of you, questions left unanswered, links and files, each with a click to the message. It only looks when you ask, and keeps nothing on disk.
-- @description:pt /perdi ou o painel: resume as mensagens não lidas do canal aberto (ou as últimas): quantas de cada pessoa, menções a você, perguntas sem resposta, links e arquivos, cada um com um clique até a mensagem. Só olha quando você pede, e não guarda nada no disco.
-- @version 1.0.0
-- @capabilities messages, panel, timers

local tr = sigma.tr
local MAX_LIST = 20
local MAX_PEOPLE = 8
-- Alguém escreveu até tanto tempo depois: a pergunta provavelmente foi respondida.
local ANSWER_WINDOW = 600

-- Só existe com o painel aberto. Fechou: some da memória.
local report = nil
local open = false
local mode = "unread"
local waiting = false

local function when(t)
  if os.date("%Y%m%d", t) == os.date("%Y%m%d") then return os.date("%H:%M", t) end
  return os.date(sigma.lang() == "pt" and "%d/%m %H:%M" or "%b %d %H:%M", t)
end

local function short(text, max)
  text = text:gsub("%s+", " "):gsub("^ ", "")
  -- Sem o código das menções e dos emojis, que na lista só atrapalham.
  text = text:gsub("<a?:([%w_]+):%d+>", ":%1:"):gsub("<@[!&]?%d+>", "@…"):gsub("<#%d+>", "#…")
  if #text <= max then return text end
  local cut = max
  while cut > 0 and (text:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end
  return text:sub(1, cut) .. "…"
end

-- IDs são textos: o mais longo é o maior, e no mesmo tamanho vale a ordem das letras.
local function id_after(a, b)
  if #a ~= #b then return #a > #b end
  return a > b
end

local function without_links_and_code(text)
  return (text:gsub("```.-```", " "):gsub("`[^`]*`", " "):gsub("%a+://%S+", " "))
end

local function host_of(url)
  return url:match("^https?://([^/?#]+)") or url
end

local function trim_url(url)
  url = url:gsub("[%.,;:!%?'%*_~|`]+$", "")
  if url:sub(-1) == ")" and not url:find("(", 1, true) then url = url:sub(1, -2) end
  return url
end

-- Uma pergunta sem resposta: ninguém respondeu a ela, e ninguém mais escreveu logo depois.
local function unanswered(list, i, replied)
  local m = list[i]
  if replied[m.id] then return false end
  for k = i + 1, #list do
    local later = list[k]
    if later.time - m.time > ANSWER_WINDOW then break end
    if later.author.id ~= m.author.id then return false end
  end
  return true
end

local function summarize(all, last_read)
  local list = all
  local from_unread = false
  if mode == "unread" then
    local fresh = {}
    if last_read then
      for _, m in ipairs(all) do
        if id_after(m.id, last_read) and not m.mine then fresh[#fresh + 1] = m end
      end
    end
    if #fresh > 0 then
      list = {}
      for _, m in ipairs(all) do
        if id_after(m.id, last_read) then list[#list + 1] = m end
      end
      from_unread = true
    else
      -- Nada novo: as últimas 100, para o painel não ficar vazio.
      list = {}
      for i = math.max(#all - 99, 1), #all do list[#list + 1] = all[i] end
    end
  else
    local n = tonumber(mode)
    list = {}
    for i = math.max(#all - n + 1, 1), #all do list[#list + 1] = all[i] end
  end

  local r = { total = 0, from_unread = from_unread, people = {}, mentions = {}, questions = {}, links = {} }
  local counts, order = {}, {}
  local replied = {}
  for _, m in ipairs(list) do
    if m.reply_to then replied[m.reply_to] = true end
  end
  local seen_url = {}
  for i = #list, 1, -1 do
    local m = list[i]
    if not m.mine then
      r.total = r.total + 1
      local who = m.author.name
      if not counts[who] then
        counts[who] = 0
        order[#order + 1] = who
      end
      counts[who] = counts[who] + 1
      if m.mentions_me and #r.mentions < MAX_LIST then
        r.mentions[#r.mentions + 1] = m
      end
      if without_links_and_code(m.content):find("?", 1, true) and #r.questions < MAX_LIST and unanswered(list, i, replied) then
        r.questions[#r.questions + 1] = m
      end
    end
    for _, f in ipairs(m.files or {}) do
      if #r.links < MAX_LIST and not seen_url[f.url] then
        seen_url[f.url] = true
        r.links[#r.links + 1] = { title = f.name, by = m.author.name, m = m }
      end
    end
    for raw in m.content:gmatch("https?://[^%s<>\"]+") do
      local url = trim_url(raw)
      if #r.links < MAX_LIST and not seen_url[url] then
        seen_url[url] = true
        r.links[#r.links + 1] = { title = host_of(url), sub = url, by = m.author.name, m = m }
      end
    end
  end
  table.sort(order, function(a, b)
    if counts[a] ~= counts[b] then return counts[a] > counts[b] end
    return a < b
  end)
  for i = 1, math.min(#order, MAX_PEOPLE) do
    r.people[i] = { name = order[i], n = counts[order[i]] }
  end
  r.others = math.max(#order - MAX_PEOPLE, 0)
  r.n_people = #order
  return r
end

local function msg_item(m, key)
  return {
    title = m.author.name,
    subtitle = short(m.content, 160),
    meta = when(m.time),
    key = key,
    on_click = function() sigma.jump(m.channel.id, m.id) end,
  }
end

local render

local function scan()
  if not open then return end
  local asked = sigma.messages({ limit = 500, files = true }, function(list)
    if not open then return end
    report = summarize(list, list.last_read)
    render()
  end)
  if not asked and not waiting then
    waiting = true
    sigma.after(0.6, function()
      waiting = false
      scan()
    end)
  end
end

local function count_text(r)
  local lead = r.from_unread and tr("não lidas", "unread") or tr("olhadas", "looked at")
  return r.total .. " " .. lead .. ", " .. tr("de ", "from ") .. r.n_people .. " " .. (r.n_people == 1 and tr("pessoa", "person") or tr("pessoas", "people"))
end

render = function()
  local tree = {
    title = tr("O que perdi", "What did I miss"),
    { type = "select", key = "mode", label = tr("Olhar", "Look at"), value = mode,
      options = {
        { value = "unread", label = tr("As não lidas", "The unread ones") },
        { value = "50", label = tr("As últimas 50", "The last 50") },
        { value = "100", label = tr("As últimas 100", "The last 100") },
        { value = "200", label = tr("As últimas 200", "The last 200") },
        { value = "500", label = tr("As últimas 500", "The last 500") },
      },
      on_change = function(v)
        mode = v
        scan()
      end },
    { type = "row",
      { type = "button", label = tr("Atualizar", "Refresh"), key = "refresh", on_click = scan },
    },
  }
  local r = report
  if not r then
    tree[#tree + 1] = { type = "text", style = "muted", text = tr("Abra este painel num canal, ou use /perdi.", "Open this panel in a channel, or use /missed.") }
    sigma.panel.set(tree)
    return
  end
  if mode == "unread" and not r.from_unread then
    tree[#tree + 1] = { type = "text", style = "muted", key = "nothing-new",
      text = tr("Nenhuma mensagem nova neste canal: estas são as últimas.", "No new messages in this channel: these are the last ones.") }
  end
  tree[#tree + 1] = { type = "heading", text = count_text(r) }
  local top = r.people[1] and r.people[1].n or 1
  for i, p in ipairs(r.people) do
    tree[#tree + 1] = { type = "bar", key = "person" .. i, label = p.name, value = p.n, max = top, text = tostring(p.n) }
  end
  if r.others > 0 then
    tree[#tree + 1] = { type = "text", style = "muted", text = tr("e mais ", "and ") .. r.others .. tr(" pessoas", " more people") }
  end
  local function section(title, key, rows, empty)
    tree[#tree + 1] = { type = "heading", text = title .. " (" .. #rows .. ")" }
    tree[#tree + 1] = { type = "list", key = key, items = rows, empty = empty }
  end
  local mentions = {}
  for i, m in ipairs(r.mentions) do mentions[i] = msg_item(m, "mention" .. i) end
  section(tr("Menções a você", "Mentions of you"), "mentions", mentions, tr("Ninguém chamou você.", "Nobody called you."))
  local questions = {}
  for i, m in ipairs(r.questions) do questions[i] = msg_item(m, "question" .. i) end
  section(tr("Perguntas sem resposta", "Unanswered questions"), "questions", questions, tr("Nenhuma ficou no ar.", "None left hanging."))
  local links = {}
  for i, l in ipairs(r.links) do
    local m = l.m
    links[i] = {
      title = l.title,
      subtitle = l.sub or l.by,
      meta = when(m.time),
      key = "link" .. i,
      on_click = function() sigma.jump(m.channel.id, m.id) end,
    }
  end
  section(tr("Links e arquivos", "Links and files"), "links", links, tr("Nenhum.", "None."))
  sigma.panel.set(tree)
end

sigma.on("panel", function(state)
  open = state
  if open then
    scan()
  else
    report = nil
    render()
  end
end)

sigma.on("channel", scan)

-- Apagaram ou editaram: nada de mostrar o texto de antes.
local function refresh_if_open()
  if open then scan() end
end
sigma.on("delete", refresh_if_open)
sigma.on("edit", refresh_if_open)

local function show()
  sigma.panel.open()
  scan()
end
sigma.command("/perdi", show)
sigma.command("/missed", show)

sigma.on("lang", function() render() end)
render()
