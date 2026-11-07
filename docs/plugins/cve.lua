-- @name CVE radar
-- @name:pt Radar de CVE
-- @description Finds CVE-2021-44228 and the like in messages and shows the severity, the CVSS score and a short summary under them, from the official CVE record. Only the CVE number goes to cveawg.mitre.org, and only after you approve the host below. Each one is asked once and kept for days. /cve CVE-2021-44228 looks one up by hand.
-- @description:pt Acha CVE-2021-44228 e afins nas mensagens e mostra embaixo a severidade, a nota CVSS e um resumo curto, do registro oficial de CVEs. Só o número do CVE vai para cveawg.mitre.org, e só depois de aprovar o host aqui embaixo. Cada um é pedido uma vez e fica guardado por dias. /cve CVE-2021-44228 consulta um na mão.
-- @version 1.0.0
-- @capabilities messages, decorate, http, storage, panel, links, notify, timers
-- @hosts cveawg.mitre.org

local tr = sigma.tr
local HOST = "cveawg.mitre.org"
local MAX_CACHE = 400
local MAX_QUEUE = 64
local MAX_TRACKED = 1000
local IN_FLIGHT = 2
local DAY = 86400
-- O registro de um CVE muda pouco. O que ainda não existe pode passar a existir.
local TTL_OK = 14 * DAY
local TTL_NONE = DAY
-- Quanto esperar quando o serviço (ou o limite daqui) manda parar.
local BACKOFF = 60

-- Só dados públicos do registro: nada do que foi escrito na mensagem.
local cache = sigma.storage.get("cache") or {}
local queue = {}
local queued = {}
local flying = 0
local paused = false
-- Mensagens esperando resposta, por CVE, e os CVEs de cada mensagem.
local waiting = {}
local on_message = {}
local order = {}
local dismissed = {}
-- Os vistos nesta sessão, para o painel.
local seen = {}
local seen_at = {}
local save_timer = nil
local panel_open = false

local SEVERITY = {
  CRITICAL = { pt = "CRÍTICA", en = "CRITICAL" },
  HIGH = { pt = "ALTA", en = "HIGH" },
  MEDIUM = { pt = "MÉDIA", en = "MEDIUM" },
  MODERATE = { pt = "MÉDIA", en = "MEDIUM" },
  LOW = { pt = "BAIXA", en = "LOW" },
  NONE = { pt = "NENHUMA", en = "NONE" },
  IMPORTANT = { pt = "ALTA", en = "HIGH" },
}

local function severity_of_score(score)
  if score >= 9 then return "CRITICAL" end
  if score >= 7 then return "HIGH" end
  if score >= 4 then return "MEDIUM" end
  if score > 0 then return "LOW" end
  return "NONE"
end

local function short(text, max)
  text = text:gsub("%s+", " "):gsub("^ ", "")
  if #text <= max then return text end
  -- Até o fim da primeira frase, se couber.
  local stop = text:sub(1, max):find("%. [%u%d]")
  if stop and stop > 40 then return text:sub(1, stop) end
  local cut = max
  while cut > 0 and (text:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end
  return text:sub(1, cut) .. "…"
end

-- A nota CVSS mais comum que o registro tiver, de quem publicou e depois dos
-- complementos (o CISA costuma pôr a nota nos CVEs que vieram sem).
local CVSS_ORDER = { "cvssV3_1", "cvssV4_0", "cvssV3_0", "cvssV2_0" }

local function find_cvss(containers)
  for _, version in ipairs(CVSS_ORDER) do
    for _, c in ipairs(containers) do
      if type(c.metrics) == "table" then
        for _, m in ipairs(c.metrics) do
          local v = m[version]
          if type(v) == "table" and type(v.baseScore) == "number" then return v end
        end
      end
    end
  end
end

-- Sem CVSS, às vezes só um "critical" em texto.
local function find_rating(containers)
  for _, c in ipairs(containers) do
    if type(c.metrics) == "table" then
      for _, m in ipairs(c.metrics) do
        local o = m.other
        local content = type(o) == "table" and o.content
        local word = type(content) == "table" and (content.value or content.other)
        if type(word) == "string" and SEVERITY[word:upper()] then return word:upper() end
      end
    end
  end
end

local function english_text(list)
  if type(list) ~= "table" then return nil end
  local first
  for _, d in ipairs(list) do
    if type(d) == "table" and type(d.value) == "string" then
      first = first or d.value
      if type(d.lang) == "string" and d.lang:sub(1, 2) == "en" then return d.value end
    end
  end
  return first
end

-- O registro em JSON vira só o que a nota usa. nil = não é um registro.
local function read_record(body)
  local ok, data = pcall(sigma.json.decode, body)
  if not ok or type(data) ~= "table" then return nil end
  local meta = data.cveMetadata
  local conts = data.containers
  if type(meta) ~= "table" or type(conts) ~= "table" then return nil end
  local cna = type(conts.cna) == "table" and conts.cna or {}
  if meta.state == "REJECTED" then
    return { st = "rejected", t = short(english_text(cna.rejectedReasons) or "", 180) }
  end
  local all = { cna }
  if type(conts.adp) == "table" then
    for _, a in ipairs(conts.adp) do
      if type(a) == "table" then all[#all + 1] = a end
    end
  end
  local entry = { st = "ok" }
  local cvss = find_cvss(all)
  if cvss then
    entry.s = cvss.baseScore
    local sev = type(cvss.baseSeverity) == "string" and cvss.baseSeverity:upper() or nil
    entry.v = SEVERITY[sev or ""] and sev or severity_of_score(cvss.baseScore)
  else
    entry.v = find_rating(all)
  end
  local title = type(cna.title) == "string" and cna.title or nil
  local text = title or english_text(cna.descriptions) or ""
  -- Registros antigos e reservados têm um aviso no lugar do resumo.
  entry.t = short(text, 180)
  return entry
end

local function fresh(entry)
  if not entry then return false end
  local ttl = entry.st == "ok" and TTL_OK or TTL_NONE
  return os.time() - (entry.at or 0) < ttl
end

local function save_soon()
  if save_timer then return end
  -- Várias respostas seguidas gravam uma vez só.
  save_timer = sigma.after(3, function()
    save_timer = nil
    sigma.storage.set("cache", cache)
  end)
end

local function remember(id, entry)
  entry.at = os.time()
  cache[id] = entry
  local n, oldest, oldest_at = 0, nil, nil
  for k, e in pairs(cache) do
    n = n + 1
    if not oldest_at or (e.at or 0) < oldest_at then oldest, oldest_at = k, e.at or 0 end
  end
  if n > MAX_CACHE then cache[oldest] = nil end
  save_soon()
end

local function describe(id)
  local e = cache[id]
  if not e then return nil end
  if e.st == "none" then return "🛡 " .. id .. " · " .. tr("não existe no registro", "not in the record") end
  if e.st == "rejected" then return "🛡 " .. id .. " · " .. tr("rejeitado pelo registro", "rejected by the record") end
  local parts = { "🛡 " .. id }
  if e.v and SEVERITY[e.v] then parts[#parts + 1] = tr(SEVERITY[e.v].pt, SEVERITY[e.v].en) end
  if e.s then
    parts[#parts + 1] = "CVSS " .. string.format("%.1f", e.s)
  else
    parts[#parts + 1] = tr("sem nota CVSS", "no CVSS score")
  end
  if e.t and e.t ~= "" then parts[#parts + 1] = e.t end
  return table.concat(parts, " · ")
end

local function is_critical(id)
  local e = cache[id]
  return e and e.st == "ok" and (e.v == "CRITICAL" or (e.s and e.s >= 9))
end

-- A nota da mensagem, com todos os CVEs dela que já têm resposta.
local function paint(msg_id)
  if dismissed[msg_id] then return end
  local ref = on_message[msg_id]
  if not ref then return end
  local notes = {}
  local danger = false
  for _, id in ipairs(ref.ids) do
    local text = describe(id)
    if text then notes[#notes + 1] = text end
    if is_critical(id) then danger = true end
  end
  if #notes == 0 then return end
  local note = table.concat(notes, "  |  ")
  if ref.note == note then return end
  ref.note = note
  sigma.decorate(msg_id, { note = note, style = danger and "danger" or nil })
end

local render = function() end

local function settle(id)
  queued[id] = nil
  local list = waiting[id]
  waiting[id] = nil
  if list then
    for msg_id in pairs(list) do paint(msg_id) end
  end
  if panel_open then render() end
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

pump = function()
  while not paused and flying < IN_FLIGHT and #queue > 0 do
    if not sigma.http.allowed(HOST) then return end
    local id = table.remove(queue, 1)
    flying = flying + 1
    sigma.http.get("https://" .. HOST .. "/api/cve/" .. id, function(res)
      flying = flying - 1
      if res.error == "rate_limited" or res.status == 429 or res.status == 503 then
        -- Volta para o começo da fila: é só esperar.
        table.insert(queue, 1, id)
        pause_for(BACKOFF)
      elseif res.status == 404 or res.status == 400 then
        remember(id, { st = "none" })
        settle(id)
      elseif res.ok then
        -- Corpo vazio ou esquisito conta como "não existe", e por pouco tempo.
        remember(id, read_record(res.body) or { st = "none" })
        settle(id)
      else
        -- Sem rede ou erro do serviço: nada guardado, e pede de novo da próxima vez.
        settle(id)
      end
      pump()
    end)
  end
end

local function ask(id, msg_id)
  if msg_id then
    local list = waiting[id] or {}
    list[msg_id] = true
    waiting[id] = list
  end
  if queued[id] then return end
  if #queue >= MAX_QUEUE then return end
  queued[id] = true
  queue[#queue + 1] = id
  pump()
end

local function note_seen(id, m)
  if not seen_at[id] then
    table.insert(seen, 1, id)
    if #seen > 100 then
      seen_at[seen[#seen]] = nil
      seen[#seen] = nil
    end
  end
  seen_at[id] = m and { channel = m.channel.id, id = m.id } or seen_at[id] or {}
end

-- Os CVEs da mensagem (até 4), sem repetir. Em código também: é onde costumam vir.
local function ids_in(text)
  local out, have = {}, {}
  for year, num in text:gmatch("[Cc][Vv][Ee]%-(%d%d%d%d)%-(%d%d%d%d%d*)") do
    local id = "CVE-" .. year .. "-" .. num
    if not have[id] and #num <= 8 then
      have[id] = true
      out[#out + 1] = id
      if #out == 4 then break end
    end
  end
  return out
end

local function examine(m)
  if m.ignored then return end
  local ids = ids_in(m.content)
  local old = on_message[m.id]
  if #ids == 0 then
    -- Uma edição tirou o CVE do texto.
    if old then
      on_message[m.id] = nil
      sigma.undecorate(m)
    end
    return
  end
  if not old then
    -- Um canal de alertas pode citar milhares: as mais antigas saem daqui (a nota fica).
    order[#order + 1] = m.id
    if #order > MAX_TRACKED then
      on_message[table.remove(order, 1)] = nil
    end
  end
  on_message[m.id] = { ids = ids, note = old and old.note or nil }
  for _, id in ipairs(ids) do
    note_seen(id, m)
    if not fresh(cache[id]) then ask(id, m.id) end
  end
  paint(m.id)
  if panel_open then render() end
end

-- As já carregadas no canal aberto.
local again = false
local function scan()
  local asked = sigma.messages({ limit = 200, contains = { "cve-" } }, function(list)
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

sigma.on("message", examine, { contains = { "cve-" } })
sigma.on("edit", examine)
sigma.on("channel", function()
  scan()
  -- O histórico do canal chega um pouco depois de abrir.
  sigma.after(1.5, scan)
end)

-- Acabou de aprovar o host: o que estava esperando sai agora, e o canal aberto é olhado.
sigma.on("hosts", function()
  pump()
  scan()
end)

sigma.on("delete", function(d)
  on_message[d.id] = nil
  dismissed[d.id] = nil
  for _, ref in pairs(seen_at) do
    if ref.id == d.id then
      ref.id = nil
      ref.channel = nil
    end
  end
  if panel_open then render() end
end)

sigma.on("dismiss", function(d)
  dismissed[d.id] = true
end)

sigma.command("/cve", function(args)
  local ids = ids_in(args)
  if #ids == 0 then
    sigma.notify(tr("Use assim: /cve CVE-2021-44228", "Use it like this: /cve CVE-2021-44228"))
    return
  end
  for _, id in ipairs(ids) do
    note_seen(id, nil)
    if not fresh(cache[id]) then ask(id) end
  end
  render()
  sigma.panel.open()
end)

local function rank(id)
  local e = cache[id]
  if not e then return -1 end
  return e.s or (e.v == "CRITICAL" and 9.5) or (e.v == "HIGH" and 8) or (e.v == "MEDIUM" and 5) or (e.v == "LOW" and 2) or 0
end

render = function()
  local tree = { title = tr("Radar de CVE", "CVE radar") }
  if not sigma.http.allowed(HOST) then
    tree[#tree + 1] = { type = "text", style = "danger", text = tr(
      "Aprove " .. HOST .. " em Configurações → Plugins para ver as notas. Até lá, nada sai daqui.",
      "Approve " .. HOST .. " in Settings → Plugins to see the scores. Until then, nothing goes out.") }
  end
  local ids = {}
  for _, id in ipairs(seen) do ids[#ids + 1] = id end
  -- O mais grave primeiro.
  table.sort(ids, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then return ra > rb end
    return a > b
  end)
  local items = {}
  for _, id in ipairs(ids) do
    local e = cache[id]
    local ref = seen_at[id] or {}
    local meta = ""
    if e and e.s then
      meta = string.format("%.1f", e.s)
    elseif e and e.st == "none" then
      meta = tr("não existe", "not found")
    elseif e and e.st == "rejected" then
      meta = tr("rejeitado", "rejected")
    elseif not e then
      meta = "…"
    end
    local sev = e and e.v and SEVERITY[e.v] and tr(SEVERITY[e.v].pt, SEVERITY[e.v].en) or ""
    local sub = tr("Esperando a resposta…", "Waiting for the answer…")
    if e and e.st == "none" then
      sub = tr("Esse número não existe no registro.", "That number isn't in the record.")
    elseif e and e.t and e.t ~= "" then
      sub = e.t
    elseif e then
      sub = ""
    end
    items[#items + 1] = {
      title = sev ~= "" and (id .. " · " .. sev) or id,
      subtitle = sub,
      meta = meta,
      key = id,
      on_click = ref.id and function() sigma.jump(ref.channel, ref.id) end or nil,
      actions = { { label = tr("Abrir o registro", "Open the record"), key = "open" .. id, on_click = function()
        sigma.open("https://www.cve.org/CVERecord?id=" .. id)
      end } },
    }
  end
  tree[#tree + 1] = { type = "list", key = "seen", items = items,
    empty = tr("Nenhum CVE visto ainda. Use /cve CVE-2021-44228 para consultar um.", "No CVEs seen yet. Use /cve CVE-2021-44228 to look one up.") }
  sigma.panel.set(tree)
end

sigma.on("panel", function(open)
  panel_open = open
  if open then render() end
end)

sigma.on("lang", function()
  for msg_id, ref in pairs(on_message) do
    ref.note = nil
    paint(msg_id)
  end
  render()
end)

render()
sigma.after(1, scan)
