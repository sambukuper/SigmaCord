-- @name Translate
-- @name:pt Traduzir
-- @description Right-click a message, or use the 🌐 on its toolbar, to see a translation under it. "Translate to…" picks another language for one message, the options below set the default, and /tr es hello puts a translation in the message box. The text goes to api.mymemory.translated.net (a free public service) only when you ask, and only after you approve the host below.
-- @description:pt Botão direito numa mensagem, ou o 🌐 na barra dela, para ver a tradução embaixo. "Traduzir para…" escolhe outro idioma só para aquela mensagem, as opções abaixo definem o padrão, e /tr es olá põe uma tradução na caixa de mensagem. O texto vai para api.mymemory.translated.net (um serviço público e gratuito) só quando você pede, e só depois de aprovar o host aqui embaixo.
-- @version 1.1.0
-- @capabilities menu, decorate, http, notify, storage, settings, composer
-- @hosts api.mymemory.translated.net

local tr = sigma.tr
local HOST = "api.mymemory.translated.net"
-- O serviço aceita até 500 bytes de cada vez.
local MAX = 480

-- Os códigos foram conferidos no próprio serviço.
local LANGS = {
  { code = "pt", pt = "Português", en = "Portuguese" },
  { code = "en", pt = "Inglês", en = "English" },
  { code = "es", pt = "Espanhol", en = "Spanish" },
  { code = "fr", pt = "Francês", en = "French" },
  { code = "de", pt = "Alemão", en = "German" },
  { code = "it", pt = "Italiano", en = "Italian" },
  { code = "nl", pt = "Holandês", en = "Dutch" },
  { code = "pl", pt = "Polonês", en = "Polish" },
  { code = "ru", pt = "Russo", en = "Russian" },
  { code = "uk", pt = "Ucraniano", en = "Ukrainian" },
  { code = "tr", pt = "Turco", en = "Turkish" },
  { code = "ar", pt = "Árabe", en = "Arabic" },
  { code = "ja", pt = "Japonês", en = "Japanese" },
  { code = "ko", pt = "Coreano", en = "Korean" },
  { code = "zh-CN", pt = "Chinês", en = "Chinese" },
}

local by_code = { zh = "zh-CN" }
for _, l in ipairs(LANGS) do by_code[l.code:lower()] = l.code end

-- "auto": o idioma do app, e descobrir sozinho o idioma de origem.
local target = sigma.storage.get("target") or "auto"
local source = sigma.storage.get("source") or "auto"

local function target_code()
  return target == "auto" and sigma.lang() or target
end

local function cut(text)
  if #text <= MAX then return text, false end
  local n = MAX
  while n > 0 and (text:byte(n + 1) or 0) & 0xC0 == 0x80 do n = n - 1 end
  return text:sub(1, n), true
end

-- Sem as marcas de menção e emoji, que o serviço só estragaria.
local function clean(text)
  return (text:gsub("<a?:([%w_]+):%d+>", ":%1:"):gsub("<@[!&]?%d+>", "@…"):gsub("<#%d+>", "#…"))
end

-- O serviço às vezes devolve marcas de formatação e entidades de HTML na tradução.
local ENTITIES = { ["&#39;"] = "'", ["&quot;"] = '"', ["&lt;"] = "<", ["&gt;"] = ">", ["&amp;"] = "&" }

local function tidy(text)
  return (text:gsub("</?g[^>]*>", ""):gsub("&#?%w+;", ENTITIES))
end

-- Chama done(tradução), ou done(nil, "same") ou done(nil, "fail", detalhe).
local function fetch(text, code, done)
  local from = source == "auto" and "Autodetect" or source
  local url = "https://" .. HOST .. "/get?q=" .. sigma.urlencode(text) .. "&langpair=" .. sigma.urlencode(from .. "|" .. code)
  sigma.http.get(url, function(res)
    local data = res.ok and sigma.json.decode(res.body) or nil
    local out = data and data.responseData and data.responseData.translatedText
    -- O serviço responde 200 até quando recusa: o motivo fica em responseStatus, e
    -- o aviso dele vem no lugar da tradução. Nunca é para mostrar esse aviso.
    local refused = data and data.responseStatus ~= nil and tostring(data.responseStatus) ~= "200"
    if refused and type(out) == "string" and out:find("DISTINCT LANGUAGES", 1, true) then
      return done(nil, "same")
    end
    if refused or type(out) ~= "string" or out == "" then
      return done(nil, "fail", res.error)
    end
    done(tidy(out))
  end)
end

local function can_ask()
  if sigma.http.allowed(HOST) then return true end
  sigma.notify(tr("Aprove " .. HOST .. " em Configurações → Plugins", "Approve " .. HOST .. " in Settings → Plugins"))
  return false
end

-- Com nota agora: clicar em "Traduzir" de novo tira.
local shown = {}
-- O pedido mais novo de cada mensagem: uma resposta atrasada não pisa nele.
local asked = {}
local serial = 0

-- O × da nota: da próxima vez, "Traduzir" traduz de novo em vez de só tirar.
sigma.on("dismiss", function(d)
  shown[d.id] = nil
  asked[d.id] = nil
end)

local function already(code)
  if target == "auto" and code == sigma.lang() then
    return tr("Essa mensagem já está no seu idioma", "That message is already in your language")
  end
  return tr("Essa mensagem já está nesse idioma", "That message is already in that language")
end

local function request(m, code)
  if not can_ask() then return end
  local text, partial = cut(clean(m.content))
  if text:gsub("%s", "") == "" then
    sigma.notify(tr("Essa mensagem não tem texto", "That message has no text"))
    return
  end
  serial = serial + 1
  local mine = serial
  asked[m.id] = mine
  sigma.decorate(m, { note = tr("Traduzindo…", "Translating…") })
  fetch(text, code, function(out, why, detail)
    if asked[m.id] ~= mine then return end
    asked[m.id] = nil
    if why == "same" then
      shown[m.id] = true
      sigma.decorate(m, { note = already(code) })
    elseif why then
      shown[m.id] = nil
      sigma.decorate(m, { note = tr("Não consegui traduzir", "Couldn't translate") .. (detail and " (" .. detail .. ")" or "") })
    else
      shown[m.id] = true
      if partial then out = out .. " […]" end
      -- O idioma só aparece quando não é o de sempre.
      local tag = code ~= sigma.lang() and code:upper() .. " · " or ""
      sigma.decorate(m, { note = "🌐 " .. tag .. out })
    end
  end)
end

sigma.menu("message", { pt = "Traduzir", en = "Translate" }, function(m)
  if shown[m.id] or asked[m.id] then
    shown[m.id] = nil
    asked[m.id] = nil
    sigma.undecorate(m)
    return
  end
  request(m, target_code())
end, { toolbar = "🌐" })

local choices = {}
for _, l in ipairs(LANGS) do
  choices[#choices + 1] = { value = l.code, pt = l.pt, en = l.en }
end

-- Só esta mensagem: a escolha da página continua como está.
sigma.menu("message", { pt = "Traduzir para…", en = "Translate to…" }, function(m, code)
  request(m, code)
end, { choices = choices })

-- /tr es bom dia: a tradução vai para a caixa, e quem envia é você.
sigma.command("/tr", function(args)
  local first, rest = args:match("^(%S+)%s+(.+)$")
  local code = first and by_code[first:lower()]
  local text = code and rest or args
  if text == "" then
    sigma.notify(tr("Use assim: /tr es bom dia", "Use it like this: /tr es good morning"))
    return
  end
  if not can_ask() then return end
  fetch(cut(clean(text)), code or target_code(), function(out, why, detail)
    if why == "same" then
      sigma.notify(tr("Esse texto já está nesse idioma", "That text is already in that language"))
    elseif why then
      sigma.notify(tr("Não consegui traduzir", "Couldn't translate") .. (detail and " (" .. detail .. ")" or ""))
    else
      sigma.insert(out)
    end
  end)
end)

local function options()
  local to = { { value = "auto", label = tr("Idioma do app", "App language") } }
  local from = { { value = "auto", label = tr("Detectar sozinho", "Detect automatically") } }
  for _, l in ipairs(LANGS) do
    local label = tr(l.pt, l.en)
    to[#to + 1] = { value = l.code, label = label }
    from[#from + 1] = { value = l.code, label = label }
  end
  sigma.settings.set({
    { type = "select", key = "target", label = tr("Traduzir para", "Translate to"), value = target, options = to,
      on_change = function(v)
        target = v
        sigma.storage.set("target", v)
      end },
    { type = "select", key = "source", label = tr("Idioma original", "Original language"), value = source, options = from,
      on_change = function(v)
        source = v
        sigma.storage.set("source", v)
      end },
  })
end

sigma.on("lang", options)
options()
