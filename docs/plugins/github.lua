-- @name GitHub cards
-- @name:pt Cartões do GitHub
-- @description owner/repo#123 and links to GitHub issues, pull requests and repositories get a note with the title, the state and the stars. Only the name of the repository and the number go to api.github.com, and only after you approve the host below. Public repositories only, no login: GitHub allows few requests per hour without one, so each answer is kept for a while, and past the limit the notes just wait.
-- @description:pt dono/repo#123 e links para issues, pull requests e repositórios do GitHub ganham uma nota com o título, o estado e as estrelas. Só o nome do repositório e o número vão para api.github.com, e só depois de aprovar o host aqui embaixo. Só repositórios públicos, sem login: o GitHub deixa poucos pedidos por hora sem ele, então cada resposta fica guardada por um tempo, e passado o limite as notas só esperam.
-- @version 1.0.0
-- @capabilities messages, decorate, http, storage, timers
-- @hosts api.github.com

local tr = sigma.tr
local HOST = "api.github.com"
local MAX_CACHE = 300
local MAX_QUEUE = 32
local MAX_REFS = 3
local MAX_TRACKED = 1000
local IN_FLIGHT = 2
-- O GitHub dá 60 por hora, por computador, sem login. Sobra para o resto da máquina.
local PER_HOUR = 30
local HOUR = 3600
-- Limite estourado: não adianta insistir antes disso.
local BLOCKED = 15 * 60
-- Estado de issue muda, estrela muda devagar, e o que não existe quase nunca passa a existir.
local TTL = { repo = 6 * HOUR, issue = HOUR, pr = HOUR, none = 24 * HOUR }

-- Só dados públicos do GitHub: nada do que foi escrito na mensagem.
local cache = sigma.storage.get("cache") or {}
local queue = {}
local queued = {}
local flying = 0
local paused = false
local spent = 0
local spent_from = os.time()
-- Mensagens esperando resposta, por referência, e as referências de cada mensagem.
local waiting = {}
local on_message = {}
local order = {}
local dismissed = {}
local save_timer = nil

-- Primeiro pedaço de github.com/... que não é um dono de repositório.
local RESERVED = {
  about = true, apps = true, collections = true, contact = true, customer = true, enterprise = true, explore = true,
  features = true, issues = true, join = true, login = true, marketplace = true, notifications = true, orgs = true,
  organizations = true, pricing = true, pulls = true, readme = true, search = true, security = true, settings = true,
  site = true, sponsors = true, stars = true, team = true, topics = true, trending = true, users = true,
}

local function short(text, max)
  text = text:gsub("%s+", " "):gsub("^ ", "")
  if #text <= max then return text end
  local cut = max
  while cut > 0 and (text:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end
  return text:sub(1, cut) .. "…"
end

local function stars_text(n)
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if n >= 10000 then return string.format("%.0fk", n / 1000) end
  if n >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(n)
end

-- Dono e repositório só com o que o GitHub aceita: é o que vai na URL.
local function valid_name(owner, repo)
  return #owner <= 39 and #repo <= 100 and owner:match("^[%w%-]+$") and repo:match("^[%w%-_%.]+$")
    and repo ~= "." and repo ~= ".."
end

-- As referências da mensagem, sem repetir. Código fica de fora: lá não é um pedido.
local function refs_in(content)
  local text = content:gsub("```.-```", " "):gsub("`[^`]*`", " ")
  local refs, have = {}, {}
  local function add(owner, repo, num)
    if #refs >= MAX_REFS or RESERVED[owner:lower()] or not valid_name(owner, repo) then return end
    local key = (owner .. "/" .. repo):lower() .. (num and "#" .. num or "")
    if have[key] then return end
    have[key] = true
    refs[#refs + 1] = { key = key, owner = owner, repo = repo, num = num }
  end
  for url in text:gmatch("[Hh][Tt][Tt][Pp][Ss]?://[^%s<>\"%)]+") do
    local host, path = url:match("^%a+://([^/]+)/(.+)$")
    if host and (host:lower() == "github.com" or host:lower() == "www.github.com") then
      local owner, repo, rest = path:match("^([^/%?#]+)/([^/%?#]+)(.*)$")
      if owner then
        repo = repo:gsub("%.git$", ""):gsub("[%.,;:!'%*_~|`]+$", "")
        add(owner, repo, rest:match("^/issues/(%d+)") or rest:match("^/pull/(%d+)"))
      end
    end
  end
  -- dono/repo#123, começando numa palavra e fora de qualquer link.
  local plain = "\n" .. text:gsub("%a+://%S+", " ")
  for owner, repo, num in plain:gmatch("[%s%(%[,;:]([%w%-]+)/([%w%-_%.]+)#(%d+)") do
    -- "e/ou#1" é conversa.
    if #owner >= 2 and #repo >= 2 then add(owner, repo, num) end
  end
  return refs
end

local function fresh(entry)
  if not entry then return false end
  return os.time() - (entry.at or 0) < (TTL[entry.k] or HOUR)
end

local function save_soon()
  if save_timer then return end
  save_timer = sigma.after(3, function()
    save_timer = nil
    sigma.storage.set("cache", cache)
  end)
end

local function remember(key, entry)
  entry.at = os.time()
  cache[key] = entry
  local n, oldest, oldest_at = 0, nil, nil
  for k, e in pairs(cache) do
    n = n + 1
    if not oldest_at or (e.at or 0) < oldest_at then oldest, oldest_at = k, e.at or 0 end
  end
  if n > MAX_CACHE then cache[oldest] = nil end
  save_soon()
end

local function read_answer(body, ref)
  local ok, d = pcall(sigma.json.decode, body)
  if not ok or type(d) ~= "table" then return nil end
  if ref.num then
    if type(d.title) ~= "string" then return nil end
    local pr = type(d.pull_request) == "table"
    return {
      k = pr and "pr" or "issue",
      title = short(d.title, 160),
      state = type(d.state) == "string" and d.state or "open",
      why = type(d.state_reason) == "string" and d.state_reason or nil,
      merged = pr and type(d.pull_request.merged_at) == "string" or nil,
      draft = d.draft == true or nil,
    }
  end
  if type(d.full_name) ~= "string" then return nil end
  return {
    k = "repo",
    name = d.full_name,
    stars = type(d.stargazers_count) == "number" and d.stargazers_count or nil,
    lang = type(d.language) == "string" and d.language or nil,
    about = type(d.description) == "string" and short(d.description, 140) or nil,
    archived = d.archived == true or nil,
  }
end

local function state_text(e)
  if e.k == "pr" then
    if e.merged then return tr("mesclado", "merged") end
    if e.draft and e.state == "open" then return tr("rascunho", "draft") end
    return e.state == "open" and tr("aberto", "open") or tr("fechado", "closed")
  end
  if e.state == "open" then return tr("aberta", "open") end
  if e.why == "not_planned" then return tr("fechada sem correção", "closed as not planned") end
  return tr("fechada", "closed")
end

local function describe(ref)
  local e = cache[ref.key]
  if not e or e.k == "none" then return nil end
  if e.k == "repo" then
    local parts = { "📦 " .. e.name }
    if e.stars then parts[#parts + 1] = "★ " .. stars_text(e.stars) end
    if e.lang then parts[#parts + 1] = e.lang end
    if e.archived then parts[#parts + 1] = tr("arquivado", "archived") end
    if e.about then parts[#parts + 1] = e.about end
    return table.concat(parts, " · ")
  end
  local icon = e.k == "pr" and "🔀 " or "🐞 "
  return icon .. ref.owner .. "/" .. ref.repo .. "#" .. ref.num .. " · " .. state_text(e) .. " · " .. e.title
end

local function paint(msg_id)
  if dismissed[msg_id] then return end
  local tracked = on_message[msg_id]
  if not tracked then return end
  local notes = {}
  for _, ref in ipairs(tracked.refs) do
    local text = describe(ref)
    if text then notes[#notes + 1] = text end
  end
  if #notes == 0 then return end
  local note = table.concat(notes, "  |  ")
  if tracked.note == note then return end
  tracked.note = note
  sigma.decorate(msg_id, { note = note })
end

local function settle(key)
  queued[key] = nil
  local list = waiting[key]
  waiting[key] = nil
  if list then
    for msg_id in pairs(list) do paint(msg_id) end
  end
end

local pump

local function pause_for(seconds)
  if paused then return end
  paused = true
  sigma.after(seconds, function()
    paused = false
    pump()
  end)
end

local function url_of(ref)
  local base = "https://" .. HOST .. "/repos/" .. ref.owner .. "/" .. ref.repo
  return ref.num and base .. "/issues/" .. ref.num or base
end

local OPTS = { headers = { Accept = "application/vnd.github+json" } }

local function answer(ref, res, moved)
  flying = flying - 1
  if res.error == "rate_limited" then
    table.insert(queue, 1, ref)
    pause_for(60)
  elseif res.status == 403 or res.status == 429 then
    -- O limite por hora do GitHub. O aviso dele nunca aparece: a nota só espera.
    table.insert(queue, 1, ref)
    pause_for(BLOCKED)
  elseif (res.status == 301 or res.status == 302 or res.status == 307) and not moved then
    -- Repositório que mudou de nome: o endereço novo vem na resposta, e é uma vez só.
    local ok, d = pcall(sigma.json.decode, res.body)
    local to = ok and type(d) == "table" and d.url
    if type(to) == "string" and to:sub(1, #HOST + 9) == "https://" .. HOST .. "/" then
      flying = flying + 1
      spent = spent + 1
      sigma.http.get(to, OPTS, function(again) answer(ref, again, true) end)
      return
    end
    remember(ref.key, { k = "none" })
    settle(ref.key)
  elseif res.status == 404 or res.status == 410 or res.status == 451 then
    remember(ref.key, { k = "none" })
    settle(ref.key)
  elseif res.ok then
    local entry = read_answer(res.body, ref)
    if entry then remember(ref.key, entry) end
    settle(ref.key)
  else
    -- Sem rede ou erro do serviço: nada guardado, e pede de novo da próxima vez.
    settle(ref.key)
  end
  pump()
end

pump = function()
  while not paused and flying < IN_FLIGHT and #queue > 0 do
    if not sigma.http.allowed(HOST) then return end
    local now = os.time()
    if now - spent_from >= HOUR then
      spent_from = now
      spent = 0
    end
    if spent >= PER_HOUR then
      pause_for(HOUR - (now - spent_from))
      return
    end
    spent = spent + 1
    flying = flying + 1
    local ref = table.remove(queue, 1)
    sigma.http.get(url_of(ref), OPTS, function(res) answer(ref, res, false) end)
  end
end

local function ask(ref, msg_id)
  local list = waiting[ref.key] or {}
  list[msg_id] = true
  waiting[ref.key] = list
  if queued[ref.key] or #queue >= MAX_QUEUE then return end
  queued[ref.key] = true
  queue[#queue + 1] = ref
  pump()
end

local function examine(m)
  if m.ignored then return end
  local refs = refs_in(m.content)
  local old = on_message[m.id]
  if #refs == 0 then
    if old then
      on_message[m.id] = nil
      sigma.undecorate(m)
    end
    return
  end
  if not old then
    order[#order + 1] = m.id
    if #order > MAX_TRACKED then
      on_message[table.remove(order, 1)] = nil
    end
  end
  on_message[m.id] = { refs = refs, note = old and old.note or nil }
  for _, ref in ipairs(refs) do
    if not fresh(cache[ref.key]) then ask(ref, m.id) end
  end
  paint(m.id)
end

-- As últimas do canal aberto: sem gastar o limite do GitHub com o histórico inteiro.
local again = false
local function scan()
  local asked = sigma.messages({ limit = 50, contains = { "github.com/", "#" } }, function(list)
    for _, m in ipairs(list) do examine(m) end
  end)
  if not asked and not again then
    again = true
    sigma.after(0.6, function()
      again = false
      scan()
    end)
  end
end

sigma.on("message", examine, { contains = { "github.com/", "#" } })
sigma.on("edit", examine)
sigma.on("channel", function()
  scan()
  sigma.after(1.5, scan)
end)
sigma.on("hosts", function()
  pump()
  scan()
end)
sigma.on("delete", function(d)
  on_message[d.id] = nil
  dismissed[d.id] = nil
end)
sigma.on("dismiss", function(d)
  dismissed[d.id] = true
end)
sigma.on("lang", function()
  for msg_id, tracked in pairs(on_message) do
    tracked.note = nil
    paint(msg_id)
  end
end)

sigma.after(1, scan)
