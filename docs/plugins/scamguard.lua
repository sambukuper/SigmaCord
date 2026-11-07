-- @name Scam guard
-- @name:pt Anti-golpe
-- @description Marks in red the classic Discord scams in other people's messages: addresses that imitate Discord or Steam, fake free Nitro and gifts with a link, shortened links with bait, links that show one address and open another. It only looks at messages with a link, in this computer, with no network. Say "Not a scam" on a message and that address is never marked again.
-- @description:pt Marca em vermelho os golpes clássicos de Discord nas mensagens dos outros: endereços que imitam o Discord ou a Steam, Nitro grátis e presentes falsos com link, links encurtados com isca, links que mostram um endereço e abrem outro. Só olha as mensagens com link, neste computador, sem rede nenhuma. Diga "Não é golpe" numa mensagem e aquele endereço nunca mais é marcado.
-- @version 1.0.0
-- @capabilities messages, decorate, menu, panel, storage, settings, notify, timers

local tr = sigma.tr
local MAX_HITS = 100

-- Só onde e quem, nunca o texto de ninguém.
local hits = sigma.storage.get("hits") or {}
local trusted = sigma.storage.get("trusted") or {}
local mark_ip = sigma.storage.get("mark_ip")
if mark_ip == nil then mark_ip = true end
local notify_now = sigma.storage.get("notify") or false

-- O que já está na tela nesta sessão, para não refazer a nota.
local marked = {}
local dismissed = {}
local unseen = 0
local panel_open = false

local REASONS = {
  lookalike = { pt = "imita o endereço do %s com letras trocadas", en = "imitates the %s address with swapped letters" },
  punycode = { pt = "imita o endereço do %s com letras de outro alfabeto", en = "imitates the %s address with letters from another alphabet" },
  brand = { pt = "usa o nome do %s, mas não é o site dele", en = "uses the %s name, but isn't its site" },
  subdomain = { pt = "parece o %s, mas o site de verdade é outro", en = "looks like %s, but the real site is another one" },
  userinfo = { pt = "o que vem antes do @ é disfarce: o site de verdade vem depois", en = "what comes before the @ is a disguise: the real site comes after it" },
  masked = { pt = "o texto mostra um endereço e o link abre outro", en = "the text shows one address and the link opens another" },
  nitro_site = { pt = "site oferecendo Nitro de graça", en = "a site offering free Nitro" },
  bait = { pt = "promessa de presente junto de um link de fora", en = "a promised gift next to an outside link" },
  short = { pt = "link encurtado junto de uma promessa de presente", en = "a shortened link next to a promised gift" },
  ip = { pt = "link direto para um IP, sem nome de site", en = "a direct link to an IP, with no site name" },
}

local function reason_text(key, brand)
  local r = REASONS[key]
  return string.format(tr(r.pt, r.en), brand or "")
end

-- Os endereços oficiais, com todos os subdomínios. Nunca são marcados.
local OFFICIAL = {
  ["discord.com"] = true, ["discord.gg"] = true, ["discordapp.com"] = true, ["discordapp.net"] = true,
  ["discord.media"] = true, ["discordstatus.com"] = true, ["discord.gift"] = true, ["discord.new"] = true,
  ["discord.dev"] = true, ["discord.co"] = true, ["dis.gd"] = true, ["discordcdn.com"] = true,
  ["steampowered.com"] = true, ["steamcommunity.com"] = true, ["steamstatic.com"] = true, ["steamgames.com"] = true,
  ["steam-chat.com"] = true, ["s.team"] = true, ["steamusercontent.com"] = true,
}

-- Sites de terceiros de verdade com nome parecido, que as regras marcariam.
local KNOWN = {
  ["steamgifts.com"] = true, ["steamtrades.com"] = true, ["discord.me"] = true, ["discord.bio"] = true,
  ["discord.st"] = true, ["discord.center"] = true, ["discord.boats"] = true, ["discord.style"] = true,
  ["discord.tools"] = true, ["discords.com"] = true, ["steam.tools"] = true, ["steam.design"] = true, ["steam.pm"] = true,
}

-- Sites grandes: um deles junto de "nitro grátis" é conversa, não isca.
local COMMON = {
  ["youtube.com"] = true, ["youtu.be"] = true, ["github.com"] = true, ["githubusercontent.com"] = true,
  ["reddit.com"] = true, ["redd.it"] = true, ["wikipedia.org"] = true, ["x.com"] = true, ["twitter.com"] = true,
  ["twitch.tv"] = true, ["tenor.com"] = true, ["giphy.com"] = true, ["imgur.com"] = true, ["google.com"] = true,
  ["spotify.com"] = true, ["instagram.com"] = true, ["tiktok.com"] = true, ["facebook.com"] = true,
  ["microsoft.com"] = true, ["apple.com"] = true, ["amazon.com"] = true, ["store.epicgames.com"] = true,
  ["epicgames.com"] = true, ["gog.com"] = true, ["xbox.com"] = true, ["playstation.com"] = true, ["nintendo.com"] = true,
  ["krebsonsecurity.com"] = true, ["bleepingcomputer.com"] = true,
}

local SHORTENERS = {
  ["bit.ly"] = true, ["tinyurl.com"] = true, ["cutt.ly"] = true, ["goo.su"] = true, ["rb.gy"] = true, ["is.gd"] = true,
  ["shorturl.at"] = true, ["ow.ly"] = true, ["v.gd"] = true, ["clck.ru"] = true, ["u.to"] = true, ["t.ly"] = true,
  ["tiny.cc"] = true, ["rebrand.ly"] = true, ["bl.ink"] = true, ["s.id"] = true, ["t.co"] = true, ["lnkd.in"] = true,
  ["short.link"] = true, ["adf.ly"] = true, ["shorte.st"] = true, ["bit.do"] = true,
}

-- As marcas e o nome que aparece na nota. As longas aceitam mais erro de digitação:
-- com "steam", uma letra de diferença já é "stream" ou "team".
local BRANDS = {
  { name = "discord", show = "Discord", typos = 1 },
  { name = "discordapp", show = "Discord", typos = 1 },
  { name = "steam", show = "Steam", typos = 0 },
  { name = "steamcommunity", show = "Steam", typos = 2 },
  { name = "steampowered", show = "Steam", typos = 2 },
}

-- Palavras de verdade, a uma letra de "discord".
local NOT_TYPOS = { discard = true, discards = true, discord = true, discordia = true, discorde = true, accord = true, record = true }

-- Colada na marca, faz o endereço ser golpe: discord-nitro, discordgift, steam-login.
local BAIT_WORDS = {
  nitro = true, gift = true, gifts = true, free = true, airdrop = true, promo = true, promos = true, claim = true,
  drop = true, drops = true, login = true, auth = true, verify = true, secure = true, support = true, app = true,
  apps = true, event = true, give = true, giveaway = true, boost = true, boosts = true, premium = true, reward = true,
  rewards = true, billing = true, security = true, team = true, staff = true, appeal = true, wallet = true, card = true,
  cards = true, trade = true, trades = true, community = true, powered = true, skins = true, offer = true, offers = true,
  gratis = true, presente = true, oficial = true, official = true,
}

-- Letras que se passam por outras: cirílico e grego parecem iguais na tela, os acentos
-- passam batido, os números são os de sempre e o "l" está aqui por causa do "dlscord".
local HOMOGLYPHS = { ["0"] = "o", ["1"] = "i", l = "i", ["3"] = "e", ["4"] = "a", ["5"] = "s", ["7"] = "t" }
for letter, codes in pairs({
  a = { 0x430, 0x3B1, 0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0x101, 0x103, 0x105 },
  b = { 0x44C },
  c = { 0x441, 0x3F2, 0xE7, 0x107, 0x10D },
  d = { 0x501, 0x10F, 0x111 },
  e = { 0x435, 0x451, 0x3B5, 0xE8, 0xE9, 0xEA, 0xEB, 0x113, 0x119, 0x11B },
  g = { 0x261, 0x11F, 0x121 },
  h = { 0x4BB },
  i = { 0x456, 0x457, 0x4CF, 0x3B9, 0x131, 0xEC, 0xED, 0xEE, 0xEF, 0x12B },
  j = { 0x458 },
  k = { 0x43A, 0x3BA },
  m = { 0x43C },
  n = { 0x578, 0x3B7, 0xF1, 0x144 },
  o = { 0x43E, 0x3BF, 0x585, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF8, 0x14D },
  p = { 0x440, 0x3C1 },
  r = { 0x433, 0x155, 0x159 },
  s = { 0x455, 0x15B, 0x15F, 0x161 },
  t = { 0x442, 0x3C4, 0x165 },
  u = { 0x3C5, 0xF9, 0xFA, 0xFB, 0xFC, 0x16B, 0x16F },
  v = { 0x3BD },
  w = { 0x51D },
  x = { 0x445 },
  y = { 0x443, 0xFD, 0xFF },
}) do
  for _, code in ipairs(codes) do HOMOGLYPHS[utf8.char(code)] = letter end
end

local function skeleton(label)
  -- Primeiro as duas letras que na tela viram uma: stearn, discorcl.
  local two = label:gsub("rn", "m"):gsub("cl", "d"):gsub("vv", "w")
  local out = {}
  for ch in two:gmatch(utf8.charpattern) do
    out[#out + 1] = HOMOGLYPHS[ch] or ch
  end
  return table.concat(out)
end

-- Punycode (RFC 3492): xn--dscord-3ta vira as letras de verdade.
local function punycode(label)
  local input = label:sub(5)
  local at = input:find("%-[^%-]*$")
  local out = {}
  if at then
    for ch in input:sub(1, at - 1):gmatch(".") do out[#out + 1] = utf8.char(ch:byte()) end
    input = input:sub(at + 1)
  end
  local n, i, bias = 128, 0, 72
  local pos = 1
  while pos <= #input do
    local old_i, w, k = i, 1, 36
    while true do
      local c = input:byte(pos)
      if not c then return nil end
      pos = pos + 1
      local digit
      if c >= 48 and c <= 57 then digit = c - 22
      elseif c >= 97 and c <= 122 then digit = c - 97
      else return nil end
      i = i + digit * w
      local t = k <= bias and 1 or (k >= bias + 26 and 26 or k - bias)
      if digit < t then break end
      w = w * (36 - t)
      k = k + 36
    end
    local size = #out + 1
    local delta = old_i == 0 and (i - old_i) // 700 or (i - old_i) // 2
    delta = delta + delta // size
    local k2 = 0
    while delta > 455 do
      delta = delta // 35
      k2 = k2 + 36
    end
    bias = k2 + 36 * delta // (delta + 38)
    n = n + i // size
    i = i % size
    if n > 0x10FFFF then return nil end
    table.insert(out, i + 1, utf8.char(n))
    i = i + 1
    if #out > 63 then return nil end
  end
  return table.concat(out)
end

-- Distância de edição, contando a troca de duas letras vizinhas como um erro só.
local function distance(a, b, limit)
  local la, lb = #a, #b
  if math.abs(la - lb) > limit then return limit + 1 end
  local prev2, prev, cur = {}, {}, {}
  for j = 0, lb do prev[j] = j end
  for i = 1, la do
    cur[0] = i
    for j = 1, lb do
      local cost = a:byte(i) == b:byte(j) and 0 or 1
      local d = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
      if i > 1 and j > 1 and a:byte(i) == b:byte(j - 1) and a:byte(i - 1) == b:byte(j) then
        d = math.min(d, prev2[j - 2] + 1)
      end
      cur[j] = d
    end
    prev2, prev, cur = prev, cur, prev2
  end
  return prev[lb]
end

local function split_labels(host)
  local labels = {}
  for l in host:gmatch("[^%.]+") do labels[#labels + 1] = l end
  return labels
end

-- Terminações de dois pedaços: em "site.com.br", o nome é "site".
local TWO_PART = {
  ["com.br"] = true, ["net.br"] = true, ["org.br"] = true, ["co.uk"] = true, ["org.uk"] = true, ["com.au"] = true,
  ["co.jp"] = true, ["com.ru"] = true, ["com.tr"] = true, ["com.ar"] = true, ["com.mx"] = true, ["co.in"] = true,
  ["co.kr"] = true, ["com.ua"] = true, ["com.cn"] = true,
}

-- A posição do nome registrado do site entre os pedaços do endereço.
local function registrable_at(labels)
  local n = #labels
  if n >= 3 and TWO_PART[labels[n - 1] .. "." .. labels[n]] then return n - 2 end
  return n - 1
end

-- Igual ou subdomínio de alguém da lista.
local function in_list(host, list)
  local h = host
  while h do
    if list[h] then return true end
    h = h:match("^[^%.]+%.(.+)$")
  end
  return false
end

local function is_trusted(host)
  for _, d in ipairs(trusted) do
    if host == d or host:sub(-#d - 1) == "." .. d then return true end
  end
  return false
end

local function public_ip(host)
  -- Número puro ou em hexadecimal também é IP para o navegador.
  if host:match("^%d+$") or host:match("^0x%x+$") then return true end
  if host:sub(1, 1) == "[" then return host ~= "[::1]" end
  local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return false end
  a, b = tonumber(a), tonumber(b)
  if a == 10 or a == 127 or a == 0 then return false end
  if a == 192 and b == 168 then return false end
  if a == 172 and b >= 16 and b <= 31 then return false end
  if a == 169 and b == 254 then return false end
  return true
end

-- O pedaço (sem xn--, em letras "de verdade") parece uma marca? Devolve o motivo e a marca.
local function label_lookalike(raw, decoded)
  local why = decoded and "punycode" or "lookalike"
  local plain = decoded or raw
  local sk = skeleton(plain)
  local squeezed = sk:gsub("%-", "")
  for _, b in ipairs(BRANDS) do
    if (sk == b.name or squeezed == b.name) and raw ~= b.name then return why, b.show end
    if b.typos > 0 and not NOT_TYPOS[squeezed] and squeezed ~= b.name and distance(squeezed, b.name, b.typos) <= b.typos then
      return why, b.show
    end
  end
  return nil
end

-- A marca colada numa palavra de isca: discord-nitro, discordgift, nitro-steam.
local BAIT
local function brand_with_bait(label)
  if not BAIT then
    BAIT = {}
    for w in pairs(BAIT_WORDS) do BAIT[skeleton(w)] = true end
  end
  local parts = {}
  for p in label:gmatch("[^%-]+") do parts[#parts + 1] = skeleton(p) end
  for _, b in ipairs(BRANDS) do
    for i, part in ipairs(parts) do
      local a, z = part:find(b.name, 1, true)
      if a then
        local rest = part:sub(1, a - 1) .. part:sub(z + 1)
        if BAIT[rest] then return b.show end
        for k, other in ipairs(parts) do
          if k ~= i and BAIT[other] then return b.show end
        end
      end
    end
  end
  return nil
end

local function nitro_site(label)
  local sk = skeleton(label):gsub("%-", "")
  if not sk:find("nitro", 1, true) then return false end
  for _, w in ipairs({ "free", "gift", "claim", "drop", "gratis", "promo" }) do
    if sk:find(skeleton(w), 1, true) then return true end
  end
  return false
end

local function fold(text)
  -- Minúsculas e sem acento: "GRÁTIS" e "gratis" são a mesma isca.
  local low = text:lower():gsub("\xC3[\x80-\xBF]", function(ch)
    local b = ch:byte(2)
    if b >= 0x80 and b <= 0x85 or b >= 0xA0 and b <= 0xA5 then return "a" end
    if b >= 0x88 and b <= 0x8B or b >= 0xA8 and b <= 0xAB then return "e" end
    if b >= 0x8C and b <= 0x8F or b >= 0xAC and b <= 0xAF then return "i" end
    if b >= 0x92 and b <= 0x96 or b >= 0xB2 and b <= 0xB6 then return "o" end
    if b >= 0x99 and b <= 0x9C or b >= 0xB9 and b <= 0xBC then return "u" end
    if b == 0x87 or b == 0xA7 then return "c" end
    return ch
  end)
  return low
end

-- A promessa, em frases que quem conversa sobre Nitro não usa à toa. "steam gift card"
-- sozinho é conversa de quem compra: precisa do "de graça".
local BAIT_PHRASES = {
  "free nitro", "nitro free", "nitro for free", "free discord nitro", "nitro gratis", "nitro de graca", "ganhe nitro",
  "ganhar nitro", "nitro gift", "gift nitro", "presente de nitro", "nitro de presente", "discord nitro gift", "claim your nitro",
  "nitro for 3 months", "3 months of nitro", "1 month of nitro", "free steam", "steam gratis", "steam de graca",
  "$50 steam", "50$ steam", "$25 steam", "25$ steam", "free skins", "skins gratis", "skin gratis", "free csgo", "free cs2",
  "free airdrop", "claim your gift", "claim your reward", "resgate seu presente", "resgate agora", "you won a", "voce ganhou",
  "ganhou um presente", "i accidentally reported", "denunciei sem querer",
}

-- Mais fracas: só contam com um link encurtado, que esconde para onde vai.
local WEAK_BAIT = { "nitro", "gift", "free", "gratis", "presente", "steam", "claim", "promo", "boost" }

local function has_any(text, list)
  for _, w in ipairs(list) do
    if text:find(w, 1, true) then return true end
  end
  return false
end

-- Só o nome do endereço, em minúsculas. Devolve também o que veio antes do @.
local function parse_url(url)
  local rest = url:match("^%a+://(.+)$")
  if not rest then return nil end
  local authority = rest:match("^[^/%?#]*")
  local user, host = authority:match("^(.*)@(.*)$")
  host = host or authority
  if host:sub(1, 1) ~= "[" then host = host:gsub(":%d*$", "") end
  return host:lower(), user
end

-- Terminações de site de verdade. README.md, main.py e foto.png são nomes de arquivo.
local SITE_ENDINGS = {
  com = true, net = true, org = true, gg = true, gift = true, io = true, ru = true, xyz = true, br = true, co = true,
  app = true, dev = true, site = true, online = true, shop = true, info = true, top = true, link = true, club = true,
  store = true, click = true, live = true, pro = true, cc = true, tk = true,
}

local function looks_like_domain(text)
  local low = text:lower()
  local schemed = low:match("^%a+://") ~= nil
  local t = low:gsub("^%a+://", ""):match("^[^%s/%?#]+") or ""
  local ending = t:match("%.([%a\x80-\xFF][%w\x80-\xFF%-]+)$")
  if not ending then return nil end
  if schemed or t:match("^www%.") or SITE_ENDINGS[ending] then return t end
  return nil
end

-- A primeira coisa errada neste link. Devolve o motivo, a marca e o endereço.
local function check_url(url, label, text)
  local host, user = parse_url(url)
  if not host or host == "" then return nil end
  if is_trusted(host) or in_list(host, OFFICIAL) or in_list(host, KNOWN) then return nil end
  -- O texto do link diz um site e o link abre outro.
  if label then
    local shown = looks_like_domain(label)
    if shown then
      local a, b = shown:gsub("^www%.", ""), host:gsub("^www%.", "")
      local same = a == b or b:sub(-#a - 1) == "." .. a or a:sub(-#b - 1) == "." .. b
      if not same and not (in_list(a, COMMON) and in_list(b, COMMON)) then
        return "masked", nil, host
      end
    end
  end
  if user and user:find(".", 1, true) then return "userinfo", nil, host end
  if public_ip(host) then
    if mark_ip then return "ip", nil, host end
    return nil
  end
  local labels = split_labels(host)
  local n = #labels
  if n < 2 then return nil end
  -- discord.com.golpe.ru, store.steampowered.com.golpe.ru
  local dotted = "." .. host .. "."
  for official in pairs(OFFICIAL) do
    if dotted:find("." .. official .. ".", 1, true) then
      return "subdomain", official, host
    end
  end
  local reg = registrable_at(labels)
  for i = 1, reg do
    local raw = labels[i]
    local decoded
    if raw:sub(1, 4) == "xn--" then
      decoded = punycode(raw)
      if not decoded then decoded = raw end
    end
    local why, brand = label_lookalike(raw, decoded)
    -- Um subdomínio com letras trocadas é golpe; igual à marca (discord.projeto.org), não.
    if why then return why, brand, host end
  end
  local name = labels[reg]
  local plain = name
  if name:sub(1, 4) == "xn--" then plain = punycode(name) or name end
  -- O nome certo no lugar errado: discord.ru, steamcommunity.xyz.
  for _, b in ipairs(BRANDS) do
    if plain == b.name then return "brand", b.show, host end
  end
  local show = brand_with_bait(plain)
  if show then return "brand", show, host end
  if nitro_site(plain) then return "nitro_site", nil, host end
  if not in_list(host, COMMON) then
    if has_any(text, BAIT_PHRASES) then return "bait", nil, host end
    if in_list(host, SHORTENERS) and has_any(text, WEAK_BAIT) then return "short", nil, host end
  end
  return nil
end

-- O primeiro problema da mensagem. nil = limpa.
local function analyze(content)
  content = content:gsub("```.-```", " "):gsub("`[^`]*`", " ")
  local text = fold(content)
  -- Links com texto primeiro: [o que aparece](o que abre).
  local masked = {}
  for label, url in content:gmatch("%[([^%]]*)%]%((%a+://[^%s%)]+)%)") do
    masked[url] = true
    local key, brand, host = check_url(url, label, text)
    if key then return key, brand, host end
  end
  for raw in content:gmatch("%a+://[^%s<>\"%)]+") do
    local url = raw:gsub("[%.,;:!%?'%*_~|`]+$", "")
    if not masked[url] and url:match("^[hH][tT][tT][pP][sS]?://") then
      local key, brand, host = check_url(url, nil, text)
      if key then return key, brand, host end
    end
  end
  return nil
end

local function save()
  sigma.storage.set("hits", hits)
  sigma.storage.set("trusted", trusted)
end

local function when(t)
  if os.date("%Y%m%d", t) == os.date("%Y%m%d") then return os.date("%H:%M", t) end
  return os.date(sigma.lang() == "pt" and "%d/%m %H:%M" or "%b %d %H:%M", t)
end

local render

local function forget_host(host)
  local keep = {}
  for _, h in ipairs(hits) do
    if h.host == host or h.host:sub(-#host - 1) == "." .. host then
      if marked[h.id] then
        marked[h.id] = nil
        sigma.undecorate(h.id)
      end
    else
      keep[#keep + 1] = h
    end
  end
  hits = keep
end

local function trust(host)
  for _, d in ipairs(trusted) do
    if d == host then return end
  end
  if #trusted >= 200 then table.remove(trusted, 1) end
  trusted[#trusted + 1] = host
  forget_host(host)
  save()
  render()
end

local function find_hit(id)
  for i, h in ipairs(hits) do
    if h.id == id then return i, h end
  end
end

-- Olha a mensagem e deixa a nota e a lista como devem estar.
local function examine(m, live)
  if m.mine or m.ignored or dismissed[m.id] then return end
  local key, brand, host = analyze(m.content)
  local at = find_hit(m.id)
  if not key then
    -- Uma edição pode ter tirado o link.
    if at then
      table.remove(hits, at)
      save()
      render()
    end
    if marked[m.id] then
      marked[m.id] = nil
      sigma.undecorate(m)
    end
    return
  end
  local note = "⚠ " .. tr("Possível golpe: ", "Possible scam: ") .. reason_text(key, brand) .. " (" .. host .. ")"
  if marked[m.id] ~= note then
    marked[m.id] = note
    sigma.decorate(m, { note = note, style = "danger" })
  end
  if not at then
    table.insert(hits, 1, { id = m.id, channel = m.channel.id, channel_name = m.channel.name, author = m.author.name,
      host = host, why = key, brand = brand, time = m.time })
    if #hits > MAX_HITS then hits[#hits] = nil end
    if live and not panel_open then unseen = unseen + 1 end
    save()
    render()
    if live and notify_now then sigma.notify(note) end
  end
end

-- As já carregadas no canal aberto: golpe chega também com o app fechado.
local waiting = false
local function scan()
  local asked = sigma.messages({ limit = 200, contains = { "://" } }, function(list)
    for _, m in ipairs(list) do examine(m, false) end
  end)
  if not asked and not waiting then
    waiting = true
    sigma.after(0.6, function()
      waiting = false
      scan()
    end)
  end
end

sigma.on("message", function(m) examine(m, true) end, { contains = { "://" } })
sigma.on("edit", function(m) examine(m, false) end)
sigma.on("channel", function()
  scan()
  -- O histórico do canal chega um pouco depois de abrir.
  sigma.after(1.5, scan)
end)

sigma.on("delete", function(d)
  marked[d.id] = nil
  dismissed[d.id] = nil
  local at = find_hit(d.id)
  if at then
    table.remove(hits, at)
    save()
    render()
  end
end)

sigma.on("dismiss", function(d)
  dismissed[d.id] = true
  marked[d.id] = nil
end)

sigma.menu("message", { pt = "Não é golpe", en = "Not a scam" }, function(m)
  local key, _, host = analyze(m.content)
  if not key then
    sigma.notify(tr("Essa mensagem não está marcada", "That message isn't marked"))
    return
  end
  trust(host)
  marked[m.id] = nil
  sigma.undecorate(m)
  sigma.notify(tr("Não vou mais marcar ", "I won't mark this again: ") .. host)
end)

render = function()
  local items = {}
  for _, h in ipairs(hits) do
    items[#items + 1] = {
      title = h.host,
      subtitle = reason_text(h.why, h.brand) .. "  ·  " .. h.author .. "  ·  #" .. h.channel_name,
      meta = when(h.time),
      key = h.id,
      on_click = function() sigma.jump(h.channel, h.id) end,
      actions = { { label = tr("Não é golpe", "Not a scam"), key = "ok" .. h.id, on_click = function() trust(h.host) end } },
    }
  end
  local tree = {
    title = tr("Anti-golpe", "Scam guard"),
    badge = unseen > 0 and tostring(unseen) or nil,
    { type = "list", key = "hits", items = items,
      empty = tr("Nada suspeito por enquanto. As mensagens marcadas aparecem aqui.", "Nothing suspicious so far. Marked messages show up here.") },
  }
  if #hits > 0 then
    tree[#tree + 1] = { type = "row",
      { type = "button", label = tr("Limpar a lista", "Clear the list"), key = "clear", on_click = function()
        hits = {}
        unseen = 0
        save()
        render()
      end },
    }
  end
  if #trusted > 0 then
    local rows = {}
    for i, d in ipairs(trusted) do
      rows[#rows + 1] = {
        title = d, key = "trust" .. i,
        actions = { { label = tr("Marcar de novo", "Mark again"), key = "untrust" .. i, on_click = function()
          table.remove(trusted, i)
          save()
          render()
        end } },
      }
    end
    tree[#tree + 1] = { type = "heading", text = tr("Endereços que não são golpe", "Addresses that aren't scams") }
    tree[#tree + 1] = { type = "list", key = "trusted", items = rows }
  end
  sigma.panel.set(tree)
end

sigma.on("panel", function(open)
  panel_open = open
  if open and unseen > 0 then
    unseen = 0
    render()
  end
end)

sigma.command("/scam", function()
  render()
  sigma.panel.open()
end)

local function options()
  sigma.settings.set({
    { type = "toggle", key = "mark_ip", label = tr("Marcar links para um IP", "Mark links to an IP"),
      hint = tr("Em servidores de segurança isso é comum: desligue se atrapalhar. Rede local nunca é marcada.", "It's common in security servers: turn it off if it gets in the way. Local networks are never marked."),
      value = mark_ip,
      on_change = function(on)
        mark_ip = on
        sigma.storage.set("mark_ip", on)
      end },
    { type = "toggle", key = "notify", label = tr("Avisar na hora", "Notify right away"),
      hint = tr("Sem isto, só a nota na mensagem e o número no painel.", "Without this, just the note on the message and the number on the panel."),
      value = notify_now,
      on_change = function(on)
        notify_now = on
        sigma.storage.set("notify", on)
      end },
  })
end

sigma.on("lang", function()
  options()
  render()
  scan()
end)
options()
render()
sigma.after(1, scan)
